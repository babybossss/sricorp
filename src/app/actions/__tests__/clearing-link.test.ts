import "./mocks";
import { beforeEach, describe, expect, it } from "vitest";
import { ctx, resetCtx } from "./ctx";
import { ASSET, BANK, CONTACT, COA_BY_ID, OWNER } from "./fake-db";
import { postEntry, type PostEntryRequest } from "../post-entry";
import { listOpenSources } from "../open-sources";
import { readPendingAccruals } from "@/lib/db/pending-accruals-server";
import { humanizeDbError } from "@/lib/db/post-entry";
import { accrualReductionsOf } from "@/lib/db/clearing-link";
import type { PostingInput } from "@/lib/ledger/types";
import { findSub } from "@/lib/rules/tx-rules";

/**
 * ใบที่ลดลูกหนี้/เจ้าหนี้ต้องบอกได้ว่าล้างของใบไหน (DB: 20261025000007)
 * fake-db จำลองด่านนั้นไว้ (`fn_accrual_open_sources` + `fn_assert_clearing_not_over_for`)
 * เทสต์จึงแดงทั้งเมื่อแอปไม่ส่งลิงก์ และเมื่อแอปบังคับเลือกเกินจำเป็น
 */

const accrual = (amount: number, docDate: string): Promise<string> =>
  postEntry({
    input: { typeKey: "income", subCode: "inc.rent", amount, ownerId: OWNER.tk, assetId: ASSET, contactId: CONTACT, notYetPaid: true },
    docDate,
    cashDate: "",
  }).then((o) => {
    if (!o.ok) throw new Error(o.message);
    return o.transactionIds[0];
  });

const collect = (amount: number, clearsSourceId?: string): Promise<Awaited<ReturnType<typeof postEntry>>> => {
  const found = findSub("inv.collect_rent")!;
  const input: PostingInput = {
    typeKey: found.type.key,
    subCode: "inv.collect_rent",
    amount,
    ownerId: OWNER.tk,
    bankAccountId: BANK.tk,
    assetId: ASSET,
    contactId: CONTACT,
  };
  const req: PostEntryRequest = { input, docDate: "20/10/2026", cashDate: "20/10/2026", clearsSourceId };
  return postEntry(req);
};

const outstanding = async (id: string) => {
  const r = await readPendingAccruals(ctx.db.client as never, COA_BY_ID);
  if (!r.ok) throw new Error(r.error);
  return r.items.find((p) => p.id === id)?.outstanding ?? 0;
};

beforeEach(resetCtx);

describe("ของค้าง 2 ใบ", () => {
  it("ลงรับชำระโดยไม่เลือกใบ → ปฏิเสธด้วยข้อความที่คนอ่านรู้เรื่อง และไม่เขียนอะไรเลย", async () => {
    await accrual(10000, "01/10/2026");
    await accrual(20000, "05/10/2026");
    const before = ctx.db.rpcCalls.length;

    const out = await collect(10000);
    expect(out.ok).toBe(false);
    if (!out.ok) {
      expect(out.message).toMatch(/มีของค้างหลายใบ ต้องเลือกว่าชำระใบไหน/);
      expect(out.message).not.toMatch(/fn_|violates|ERROR/);
    }
    expect(ctx.db.rpcCalls).toHaveLength(before);
    expect(ctx.db.balance("1200")).toBe(30000);
    expect(ctx.db.balance("1100")).toBe(0);
  });

  it("เลือกใบแล้ว → ลงได้ ยอดของใบนั้นลด ใบอื่นไม่ขยับ", async () => {
    const older = await accrual(10000, "01/10/2026");
    const newer = await accrual(20000, "05/10/2026");

    const out = await collect(10000, older);
    expect(out.ok, JSON.stringify(out)).toBe(true);
    expect(ctx.db.rpcCalls[ctx.db.rpcCalls.length - 1].source_ref).toBe(`${older}-clr-1`);

    expect(await outstanding(older)).toBe(0);
    expect(await outstanding(newer)).toBe(20000); // ใบอื่นไม่ขยับ
    expect(ctx.db.balance("1200")).toBe(20000);
    expect(ctx.db.balance("1100")).toBe(10000);
  });

  it("เลือกใบที่ใหม่กว่าแล้วชำระบางส่วน → ใบเก่าไม่ถูกแตะ (ไม่ใช่ FIFO เงียบๆ)", async () => {
    const older = await accrual(10000, "01/10/2026");
    const newer = await accrual(20000, "05/10/2026");

    expect((await collect(5000, newer)).ok).toBe(true);
    expect(await outstanding(newer)).toBe(15000);
    expect(await outstanding(older)).toBe(10000);
    // ชำระงวดสองของใบเดิม: เลขอ้างอิงนับต่อจากประวัติใน DB
    expect((await collect(5000, newer)).ok).toBe(true);
    expect(ctx.db.rpcCalls[ctx.db.rpcCalls.length - 1].source_ref).toBe(`${newer}-clr-2`);
    expect(await outstanding(newer)).toBe(10000);
  });

  it("ชำระเกินยอดค้างของใบที่เลือก → ปฏิเสธ แม้ยอดรวมของผู้ถือยังพอ (รูเดิม)", async () => {
    const older = await accrual(10000, "01/10/2026");
    await accrual(20000, "05/10/2026");
    const out = await collect(10001, older);
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.message).toMatch(/เกินยอดค้างคงเหลือ/);
    expect(ctx.db.balance("1200")).toBe(30000);
  });

  it("เลือกใบที่ไม่มียอดค้าง/ไม่ใช่ของผู้ถือ → ปฏิเสธ", async () => {
    await accrual(10000, "01/10/2026");
    await accrual(20000, "05/10/2026");
    const out = await collect(100, "99999999-9999-4999-8999-999999999999");
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.message).toMatch(/ไม่มียอดค้างเหลือแล้ว/);
  });

  it("listOpenSources ให้รายการที่เลือกได้ พร้อมยอดคงเหลือจาก DB (เรียงเก่า → ใหม่)", async () => {
    const older = await accrual(10000, "01/10/2026");
    const newer = await accrual(20000, "05/10/2026");
    await collect(4000, older);
    const out = await listOpenSources({ ownerId: OWNER.tk, account: "1200" });
    expect(out.ok).toBe(true);
    if (out.ok) {
      expect(out.items.map((i) => [i.id, i.outstanding, i.clearedCount])).toEqual([
        [older, 6000, 1],
        [newer, 20000, 0],
      ]);
    }
  });

  it("ตัดหนี้สูญ (ลดลูกหนี้ ไม่มีเงินสด) ก็ต้องเลือกใบเหมือนกัน และลิงก์ถูกต้อง", async () => {
    const a = await accrual(10000, "01/10/2026");
    const b = await accrual(20000, "05/10/2026");
    const wo = (id?: string) =>
      postEntry({
        input: { typeKey: "adjust", subCode: "adj.writeoff_rent", amount: 4000, ownerId: OWNER.tk, contactId: CONTACT },
        docDate: "20/10/2026",
        cashDate: "",
        clearsSourceId: id,
      });
    const before = ctx.db.rpcCalls.length;
    const none = await wo();
    expect(none.ok).toBe(false);
    if (!none.ok) expect(none.message).toMatch(/มีของค้างหลายใบ/);
    expect(ctx.db.rpcCalls).toHaveLength(before);

    const ok = await wo(b);
    expect(ok.ok, JSON.stringify(ok)).toBe(true);
    expect(ctx.db.rpcCalls[ctx.db.rpcCalls.length - 1].source_ref).toBe(`${b}-clr-1`);
    expect(await outstanding(b)).toBe(16000);
    expect(await outstanding(a)).toBe(10000);
  });
});

describe("ของค้าง 1 ใบ — ห้ามบังคับเลือก (ห้ามกันแน่นเกิน)", () => {
  it("ไม่เลือกก็ลงได้ และ server ผูกลิงก์ให้เอง", async () => {
    const only = await accrual(10000, "01/10/2026");
    const out = await collect(10000);
    expect(out.ok, JSON.stringify(out)).toBe(true);
    expect(ctx.db.rpcCalls[ctx.db.rpcCalls.length - 1].source_ref).toBe(`${only}-clr-1`);
    expect(await outstanding(only)).toBe(0);
    expect(ctx.db.balance("1200")).toBe(0);
  });

  it("ไม่มีของค้างเลย → ปฏิเสธด้วยข้อความที่บอกทางออก", async () => {
    const out = await collect(100);
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.message).toMatch(/ไม่มีของค้างเหลืออยู่เลย/);
    expect(ctx.db.rpcCalls).toHaveLength(0);
  });

  it("รายการที่ไม่ลดลูกหนี้ (ค่าเช่าที่รับเงินสดทันที) ไม่ต้องเลือกอะไรเลย แม้มีของค้างหลายใบ", async () => {
    await accrual(10000, "01/10/2026");
    await accrual(20000, "05/10/2026");
    const out = await postEntry({
      input: { typeKey: "income", subCode: "inc.rent", amount: 500, ownerId: OWNER.tk, bankAccountId: BANK.tk, assetId: ASSET, contactId: CONTACT },
      docDate: "20/10/2026",
      cashDate: "20/10/2026",
    });
    expect(out.ok).toBe(true);
    expect(ctx.db.rpcCalls[ctx.db.rpcCalls.length - 1].source_ref).toBeUndefined();
  });
});

describe("fake-db จำลองด่านของ DB จริง (ไม่งั้นเทสต์ข้างบนพิสูจน์อะไรไม่ได้)", () => {
  const raw = (src?: string) =>
    ctx.db.client.rpc("fn_post_entry", {
      p_payload: {
        txn_type_code: "inv.collect_rent",
        doc_date: "2026-10-20",
        cash_date: "2026-10-20",
        asset_id: ASSET,
        contact_id: CONTACT,
        source: "manual",
        source_ref: src,
        transactions: [
          {
            owner_id: OWNER.tk,
            lines: [
              { coa_code: "1100", bank_account_id: BANK.tk, debit: 100, credit: 0, cf_category: "operating" },
              { coa_code: "1200", asset_id: ASSET, debit: 0, credit: 100, cf_category: "operating" },
            ],
          },
        ],
      },
    });

  it("ส่งตรงเข้า DB โดยไม่มีลิงก์ตอนมี 2 ใบ → DB ปฏิเสธ; แอปแปลเป็นข้อความที่อ่านรู้เรื่อง", async () => {
    await accrual(10000, "01/10/2026");
    await accrual(20000, "05/10/2026");
    const r = await raw();
    expect(r.error?.message).toMatch(/ไม่มีทางรู้ว่าล้างของใบไหน/);
    expect(humanizeDbError(r.error)).toMatch(/มีของค้างหลายใบ ต้องเลือกว่าชำระใบไหน/);
    expect(ctx.db.balance("1100")).toBe(0);
  });

  it("DB ปฏิเสธล้างเกินแม้ส่งลิงก์ถูก และตอนมี 1 ใบ ใบที่ไม่มีลิงก์ผ่านได้", async () => {
    const only = await accrual(50, "01/10/2026");
    const over = await raw(`${only}-clr-1`); // ล้าง 100 บนของค้าง 50
    expect(over.error?.message).toMatch(/ล้างยอดค้างเกิน/);
    expect(ctx.db.balance("1200")).toBe(50);
    const small = await accrual(500, "02/10/2026"); // ตอนนี้เปิด 2 ใบ
    expect(small).toBeTruthy();
    expect((await raw()).error?.message).toMatch(/ไม่มีทางรู้/);
  });

  it("ตรวจหาใบที่ลดบัญชีพักจากบรรทัดที่ engine คืน — ไม่ดูรหัสหมวด", () => {
    const lines = (cr: number, dr = 0) => [{ ownerId: "o", lines: [{ coaCode: "1200", debit: dr, credit: cr }, { coaCode: "1100", debit: cr, credit: dr }] }];
    expect(accrualReductionsOf(lines(100))).toEqual([{ ownerId: "o", account: "1200", amount: 100 }]);
    expect(accrualReductionsOf(lines(0, 100))).toEqual([]); // ตั้งค้างเพิ่ม ไม่ใช่การลด
    expect(accrualReductionsOf([{ ownerId: "o", lines: [{ coaCode: "2100", debit: 80, credit: 0 }, { coaCode: "1100", debit: 0, credit: 80 }] }])).toEqual([
      { ownerId: "o", account: "2100", amount: 80 }, // เจ้าหนี้ลดด้วยเดบิต
    ]);
  });
});
