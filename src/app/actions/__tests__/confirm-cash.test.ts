import "./mocks";
import { beforeEach, describe, expect, it } from "vitest";
import { ctx, resetCtx } from "./ctx";
import { ASSET, BANK, CONTACT, COA_BY_ID, OWNER } from "./fake-db";
import { postEntry } from "../post-entry";
import { confirmCash, type ConfirmCashItem } from "../confirm-cash";
import { readPendingAccruals } from "@/lib/db/pending-accruals-server";
import type { PostingInput } from "@/lib/ledger/types";
import { findSub } from "@/lib/rules/tx-rules";

/** ตั้งค้างรับค่าเช่า (ยังไม่ได้รับเงิน) ของธนากร — เส้นทางเดียวกับที่ฟอร์มส่ง */
const accrual = (amount = 12000, over: Partial<PostingInput> = {}): PostingInput => ({
  typeKey: "income",
  subCode: "inc.rent",
  amount,
  ownerId: OWNER.tk,
  assetId: ASSET,
  contactId: CONTACT,
  notYetPaid: true,
  ...over,
});
async function postAccrual(amount = 12000, over: Partial<PostingInput> = {}) {
  const out = await postEntry({ input: accrual(amount, over), docDate: "01/10/2026", cashDate: "" });
  if (!out.ok) throw new Error(`ตั้งค้างไม่ได้: ${out.message}`);
  return out.transactionIds[0];
}

const item = (sourceId: string, over: Partial<ConfirmCashItem> = {}): ConfirmCashItem => ({
  sourceId,
  amount: "12,000.00",
  date: "24/10/2026",
  bankAccountId: BANK.tk,
  slips: [],
  expectedClearedCount: 0,
  ...over,
});

const pendingNow = async () => {
  const r = await readPendingAccruals(ctx.db.client as never, COA_BY_ID);
  if (!r.ok) throw new Error(r.error);
  return r.items;
};
const outstandingOf = async (id: string) => (await pendingNow()).find((p) => p.id === id)?.outstanding ?? 0;
const revenueCredited = () =>
  ctx.db.rows.filter((r) => /^4/.test(COA_BY_ID[r.coa_id])).reduce((t, r) => t + Number(r.credit) - Number(r.debit), 0);

beforeEach(resetCtx);

describe("ตั้งค้าง → ล้าง: ยอดลูกหนี้กลับเป็นศูนย์ และรายได้ถูกนับครั้งเดียว", () => {
  it("ล้างเต็มยอด", async () => {
    const id = await postAccrual(12000);

    // หลังตั้งค้าง: ลูกหนี้ค้าง 12,000 · รายได้นับแล้ว 12,000 · เงินสดยังไม่ขยับ
    expect(ctx.db.balance("1200")).toBe(12000);
    expect(revenueCredited()).toBe(12000);
    expect(ctx.db.balance("1100")).toBe(0);
    expect(await outstandingOf(id)).toBe(12000);

    const out = await confirmCash({ items: [item(id)] });
    expect(out.ok).toBe(true);

    // หลังล้าง: ลูกหนี้เป็นศูนย์ · เงินเข้าบัญชี 12,000 · **รายได้ยังเท่าเดิม ไม่ถูกนับซ้ำ**
    expect(ctx.db.balance("1200")).toBe(0);
    expect(ctx.db.balance("1100")).toBe(12000);
    expect(revenueCredited()).toBe(12000);

    // รายการหายจากรายการค้าง เพราะอ่านจาก DB ใหม่ (ไม่ใช่ลบออกจาก state)
    const items = await pendingNow();
    expect(items.find((p) => p.id === id)?.outstanding).toBe(0);
    expect(items.filter((p) => p.outstanding > 0)).toHaveLength(0);
  });

  it("ล้างเป็นงวด: ค้างลดลงตามที่ล้างจริง และครบแล้วลูกหนี้เป็นศูนย์", async () => {
    const id = await postAccrual(12000);
    expect((await confirmCash({ items: [item(id, { amount: "5000" })] })).ok).toBe(true);
    expect(await outstandingOf(id)).toBe(7000);
    expect(ctx.db.balance("1200")).toBe(7000);

    expect((await confirmCash({ items: [item(id, { amount: "7000", expectedClearedCount: 1 })] })).ok).toBe(true);
    expect(await outstandingOf(id)).toBe(0);
    expect(ctx.db.balance("1200")).toBe(0);
    expect(ctx.db.balance("1100")).toBe(12000);
    expect(revenueCredited()).toBe(12000);
  });

  it("ค้างจ่าย (ค่าใช้จ่าย): เจ้าหนี้กลับเป็นศูนย์ ค่าใช้จ่ายนับครั้งเดียว", async () => {
    const id = await postAccrual(8600, { typeKey: "expense", subCode: "exp.common", contactId: CONTACT });
    expect(ctx.db.balance("2100")).toBe(-8600);
    const out = await confirmCash({ items: [item(id, { amount: "8600" })] });
    expect(out.ok).toBe(true);
    expect(ctx.db.balance("2100")).toBe(0);
    expect(ctx.db.balance("1100")).toBe(-8600);
    const expense = ctx.db.rows.filter((r) => /^5/.test(COA_BY_ID[r.coa_id])).reduce((t, r) => t + Number(r.debit) - Number(r.credit), 0);
    expect(expense).toBe(8600);
  });

  it("ใบล้างใช้เลขอ้างอิง <id ต้นทาง>-clr-<n> และกลับรายการใบล้างแล้วยอดค้างกลับมา", async () => {
    const id = await postAccrual(12000);
    const out = await confirmCash({ items: [item(id)] });
    expect(out.ok).toBe(true);
    const clearing = ctx.db.rpcCalls[ctx.db.rpcCalls.length - 1];
    expect(clearing.source_ref).toBe(`${id}-clr-1`);

    // กลับรายการใบล้าง (สะท้อนบรรทัดด้านตรงข้าม) — ใบล้างเดิมต้องไม่ถูกนับเป็นประวัติอีก
    const clearingId = (out as { results: { transactionId: string }[] }).results[0].transactionId;
    const rev = await ctx.db.client.rpc("fn_post_entry", {
      p_payload: {
        txn_type_code: clearing.txn_type_code as string,
        doc_date: "2026-10-25",
        cash_date: "2026-10-25",
        source: "reverse",
        reverses_id: clearingId,
        transactions: [
          {
            owner_id: OWNER.tk,
            lines: [
              { coa_code: "1200", debit: 12000, credit: 0 },
              { coa_code: "1100", bank_account_id: BANK.tk, debit: 0, credit: 12000 },
            ],
          },
        ],
      },
    });
    expect(rev.error).toBeNull();
    expect(ctx.db.balance("1200")).toBe(12000);
    expect(await outstandingOf(id)).toBe(12000);
  });
});

describe("กันล้างซ้ำ (กดซ้ำ · เน็ตหลุดแล้วลองใหม่ · ข้อมูลหน้าจอเก่า)", () => {
  it("ลองส่งคำขอเดิมซ้ำหลังสำเร็จแล้ว → ปฏิเสธ ไม่ล้างรอบสอง ไม่เขียน DB เพิ่ม", async () => {
    const id = await postAccrual(12000);
    expect((await confirmCash({ items: [item(id)] })).ok).toBe(true);
    const callsAfterFirst = ctx.db.rpcCalls.length;

    const retry = await confirmCash({ items: [item(id)] });
    expect(retry.ok).toBe(false);
    expect(ctx.db.rpcCalls).toHaveLength(callsAfterFirst);
    expect(ctx.db.balance("1100")).toBe(12000);
    expect(ctx.db.balance("1200")).toBe(0);
  });

  it("หน้าจอเก่าที่ยังเห็นว่า 'ไม่เคยล้าง' (ตัวนับไม่ตรง DB) → ปฏิเสธ", async () => {
    const id = await postAccrual(12000);
    await confirmCash({ items: [item(id, { amount: "5000" })] });
    const stale = await confirmCash({ items: [item(id, { amount: "5000", expectedClearedCount: 0 })] });
    expect(stale.ok).toBe(false);
    if (!stale.ok) expect(stale.message).toMatch(/ข้อมูลเปลี่ยนไป/);
    expect(await outstandingOf(id)).toBe(7000);
  });

  it("ประวัติที่ browser แนบมาเองไม่ถูกเชื่อ — ใช้ประวัติจาก DB เท่านั้น", async () => {
    const id = await postAccrual(12000);
    await confirmCash({ items: [item(id)] });
    const forged = { ...item(id, { expectedClearedCount: 1 }), postedClearings: [], accruedAmount: 999999 };
    const out = await confirmCash({ items: [forged as ConfirmCashItem] });
    expect(out.ok).toBe(false);
    expect(ctx.db.balance("1100")).toBe(12000);
  });

  it("ล้างเกินยอดค้าง → engine ปฏิเสธ", async () => {
    const id = await postAccrual(12000);
    const out = await confirmCash({ items: [item(id, { amount: "12000.01" })] });
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.message).toMatch(/เกินยอดค้างคงเหลือ/);
    expect(ctx.db.rpcCalls).toHaveLength(1); // มีแค่ตอนตั้งค้าง
  });

  it("รายการเดียวกันซ้ำในคำขอเดียว → ปฏิเสธทั้งคำขอ", async () => {
    const id = await postAccrual(12000);
    const out = await confirmCash({ items: [item(id, { amount: "5000" }), item(id, { amount: "5000" })] });
    expect(out.ok).toBe(false);
    expect(ctx.db.rpcCalls).toHaveLength(1);
  });
});

describe("ข้อมูลขาด ต้องปฏิเสธ ไม่เดา (บทเรียนข้อ 3)", () => {
  let id: string;
  beforeEach(async () => {
    id = await postAccrual(12000);
  });
  const refused = async (items: unknown, needle?: RegExp) => {
    const before = ctx.db.rpcCalls.length;
    const out = await confirmCash({ items } as never);
    expect(out.ok).toBe(false);
    if (!out.ok && needle) expect(out.message).toMatch(needle);
    expect(ctx.db.rpcCalls).toHaveLength(before);
    expect(ctx.db.balance("1100")).toBe(0);
  };

  it("ไม่ส่งรายการ / ไม่ส่ง items / sourceId ไม่ใช่ uuid", async () => {
    await refused([], /ไม่ได้เลือก/);
    await refused(undefined, /ไม่ได้เลือก/);
    await refused([item("not-a-uuid")], /ไม่ถูกต้อง/);
    await refused([null], /ไม่ถูกต้อง/);
  });

  it("ไม่ส่งบัญชี → engine ปฏิเสธ (ไม่ตกไปบัญชีอื่น)", async () => {
    await refused([item(id, { bankAccountId: "" })], /บัญชี/);
    await refused([{ ...item(id), bankAccountId: undefined }], /บัญชี/);
  });

  it("ไม่ส่งยอด / ยอดอ่านไม่ออก / ยอดเป็นศูนย์", async () => {
    await refused([item(id, { amount: "" })]);
    await refused([item(id, { amount: "abc" })]);
    await refused([item(id, { amount: "0" })]);
  });

  it("ไม่ส่งวันที่ / วันที่ไม่จริง", async () => {
    await refused([item(id, { date: "" })], /วันที่/);
    await refused([item(id, { date: "31/02/2026" })], /วันที่/);
  });

  it("ไม่ส่งตัวนับประวัติ (expectedClearedCount) → ปฏิเสธ ไม่เดาว่า 0", async () => {
    await refused([{ ...item(id), expectedClearedCount: undefined }], /จำนวนครั้งที่เคยยืนยัน/);
  });

  it("บัญชีของคนอื่น · บัญชีที่ปิดแล้ว · บัญชีที่ไม่มีอยู่", async () => {
    await refused([item(id, { bankAccountId: BANK.sutee })], /เป็นของ/);
    await refused([item(id, { bankAccountId: BANK.tkClosed })], /ปิดใช้งาน/);
    await refused([item(id, { bankAccountId: "aaaaaaaa-0000-4000-8000-0000000000ff" })], /ไม่พบบัญชี/);
  });

  it("รายการที่ไม่ใช่ยอดค้าง (id ที่ไม่มีในสมุด) → ปฏิเสธ", async () => {
    await refused([item("99999999-9999-4999-8999-999999999999")], /ไม่พบยอดค้าง/);
  });

  it("ไม่มีสิทธิ์อนุมัติเข้าสมุด · ไม่ได้ล็อกอิน", async () => {
    ctx.access.permissions = new Set(["txn.create"]);
    await refused([item(id)], /ลงสมุดบัญชีโดยตรงไม่ได้/);
    ctx.access.permissions = new Set(["ledger.approve"]);
    ctx.access.user = null;
    await refused([item(id)], /หมดอายุ/);
  });

  it("ทั้งหมดหรือไม่มีเลย: แถวหนึ่งผิด → ไม่เขียนแถวที่ถูกด้วย", async () => {
    const id2 = await postAccrual(9000);
    const before = ctx.db.rpcCalls.length;
    const out = await confirmCash({ items: [item(id2, { amount: "9000" }), item(id, { amount: "" })] });
    expect(out.ok).toBe(false);
    expect(ctx.db.rpcCalls).toHaveLength(before);
    expect(await outstandingOf(id2)).toBe(9000);
  });
});

describe("error จาก DB ต้องถึงผู้ใช้", () => {
  it("DB ปฏิเสธใบล้าง → รายงานเป็นรายแถว ไม่ตอบว่าสำเร็จ และยอดค้างไม่เปลี่ยน", async () => {
    const id = await postAccrual(12000);
    ctx.db.control.rpcError = { message: "บันทึกรายการไม่ได้: งวดนี้ปิดแล้ว", code: "P0001" };
    const out = await confirmCash({ items: [item(id)] });
    expect(out.ok).toBe(false);
    expect(out.results[0]).toMatchObject({ ok: false, message: "บันทึกรายการไม่ได้: งวดนี้ปิดแล้ว" });
    ctx.db.control.rpcError = null;
    expect(await outstandingOf(id)).toBe(12000);
  });
});

/** ผู้ใช้ล้างลูกหนี้เองด้วยการลงใบรับชำระ (ไม่ผ่านแท็บยืนยัน → ไม่มีเลขอ้างอิง -clr-n) */
async function collectRentByHand(amount: number, over: Partial<PostingInput> = {}) {
  const found = findSub("inv.collect_rent")!;
  const out = await postEntry({
    input: {
      typeKey: found.type.key,
      subCode: "inv.collect_rent",
      amount,
      ownerId: OWNER.tk,
      bankAccountId: BANK.tk,
      assetId: ASSET,
      contactId: CONTACT,
      ...over,
    },
    docDate: "20/10/2026",
    cashDate: "20/10/2026",
  });
  if (!out.ok) throw new Error(`ลงใบรับชำระเองไม่ได้: ${out.message}`);
}

describe("ลูกหนี้ถูกลดนอกแท็บ (ลงใบรับชำระเอง) — เงินสดผีต้องเกิดไม่ได้", () => {
  it("ล้างครบด้วยใบใหม่เอง → ลูกหนี้เป็นศูนย์ → รายการหายจากรายการค้าง และกดยืนยันซ้ำไม่ได้", async () => {
    const id = await postAccrual(100000);
    await collectRentByHand(100000);
    expect(ctx.db.balance("1200")).toBe(0);
    expect(ctx.db.balance("1100")).toBe(100000);

    // รายการค้างต้องหายไปแม้ไม่มีเลขอ้างอิง -clr-n เลย
    expect(await outstandingOf(id)).toBe(0);

    const before = ctx.db.rpcCalls.length;
    const again = await confirmCash({ items: [item(id, { amount: "100000" })] });
    expect(again.ok).toBe(false);
    if (!again.ok) expect(again.message).toMatch(/ปิดครบแล้ว/);
    // เงินสดผีต้องไม่เกิด: ไม่เขียนอะไรเพิ่ม ลูกหนี้ไม่ติดลบ เงินสดไม่เพิ่มเป็น 200,000
    expect(ctx.db.rpcCalls).toHaveLength(before);
    expect(ctx.db.balance("1200")).toBe(0);
    expect(ctx.db.balance("1100")).toBe(100000);
  });

  it("ล้างบางส่วนเอง → ยอดค้างที่โชว์ = ยอดคงเหลือจริง (ไม่ใช่ยอดเต็ม) และล้างได้ไม่เกินนั้น", async () => {
    const id = await postAccrual(100000);
    await collectRentByHand(40000);
    expect(ctx.db.balance("1200")).toBe(60000);
    expect(await outstandingOf(id)).toBe(60000);

    const over = await confirmCash({ items: [item(id, { amount: "60000.01" })] });
    expect(over.ok).toBe(false);
    if (!over.ok) expect(over.message).toMatch(/เกินยอดค้างคงเหลือ/);
    expect(ctx.db.balance("1200")).toBe(60000);

    const ok = await confirmCash({ items: [item(id, { amount: "60000" })] });
    expect(ok.ok).toBe(true);
    expect(ctx.db.balance("1200")).toBe(0);
    expect(ctx.db.balance("1100")).toBe(100000); // 40,000 เอง + 60,000 ผ่านแท็บ = ไม่เกินยอดจริง
  });

  it("ผสม: ล้างผ่านแท็บ 30,000 + ลงเอง 50,000 → เหลือ 20,000 พอดี", async () => {
    const id = await postAccrual(100000);
    await confirmCash({ items: [item(id, { amount: "30000" })] });
    await collectRentByHand(50000);
    expect(ctx.db.balance("1200")).toBe(20000);
    expect(await outstandingOf(id)).toBe(20000);
  });

  it("หลายใบค้างในกลุ่มเดียวกัน: ลดนอกแท็บถูกหักจากใบเก่าสุดก่อน (FIFO) และยอดรวมค้าง = ยอดจริงของบัญชี", async () => {
    const older = await postAccrual(10000);
    const newer = await postAccrual(20000);
    await collectRentByHand(10000);
    expect(await outstandingOf(older)).toBe(0);
    expect(await outstandingOf(newer)).toBe(20000);
    expect(ctx.db.balance("1200")).toBe(20000);
  });

  it("ยอดคงเหลือสูงกว่ายอดตามเลขอ้างอิง (มียอดอื่นในบัญชีเดียวกัน) ไม่ทำให้ยอดค้างเกินยอดตั้งค้าง", async () => {
    const id = await postAccrual(1000);
    expect(await outstandingOf(id)).toBe(1000);
    expect(ctx.db.balance("1200")).toBe(1000);
  });
});

describe("ล้างยอดค้างที่ผู้เช่าหักภาษี ณ ที่จ่าย — ลูกหนี้ต้องปิดด้วยยอดเต็ม", () => {
  const wht = { rate: "5", amount: "5,000.00", certificateNo: "WHT-001" };
  const revenue = () => revenueCredited();

  it("ค้าง 100,000 ผู้เช่าจ่าย 95,000 + ใบหัก 5,000 → ลูกหนี้ 1200 เป็นศูนย์ · เงินสด 95,000 · 1800 = 5,000 · รายได้นับครั้งเดียว", async () => {
    const id = await postAccrual(100000);
    const out = await confirmCash({ items: [item(id, { amount: "100,000.00", wht })] });
    expect(out.ok, JSON.stringify(out)).toBe(true);

    expect(ctx.db.balance("1200")).toBe(0);
    expect(ctx.db.balance("1100")).toBe(95000);
    expect(ctx.db.balance("1800")).toBe(5000);
    expect(revenue()).toBe(100000);
    // ส่ง wht_* ที่หัวรายการด้วย (ไม่งั้น DB ปฏิเสธทั้งใบ) และเก็บเลขอ้างอิงการล้างไว้
    const last = ctx.db.rpcCalls[ctx.db.rpcCalls.length - 1];
    expect(last).toMatchObject({ wht_rate: 5, wht_amount: 5000, wht_certificate_no: "WHT-001", source_ref: `${id}-clr-1` });

    // **ไม่มีเศษค้างเท่าภาษี**: ประวัติการล้างนับยอดเต็ม 100,000 ไม่ใช่ขาเงินสด 95,000
    expect(await outstandingOf(id)).toBe(0);
    const hist = (await pendingNow()).find((p) => p.id === id)!;
    expect(hist.postedClearings).toEqual([{ id: `${id}-clr-1`, amount: 100000 }]);
    expect(hist.clearedOutside).toBe(0); // ไม่ใช่ 5,000 ที่ถูกอนุมานว่า "ลดนอกแท็บ"
    const again = await confirmCash({ items: [item(id, { amount: "5,000.00", expectedClearedCount: 1 })] });
    expect(again.ok).toBe(false);
    expect(ctx.db.balance("1100")).toBe(95000);
  });

  it("ปิดด้วยยอดสุทธิ 95,000 ที่ระบุว่าถูกหัก 5% → ปฏิเสธ (ลูกหนี้จะค้างเท่าภาษีตลอดไป)", async () => {
    const id = await postAccrual(100000);
    const out = await confirmCash({ items: [item(id, { amount: "95,000.00", wht })] });
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.message).toMatch(/ยอดเต็ม/);
    expect(ctx.db.balance("1200")).toBe(100000);
  });

  it("ข้อมูลภาษีที่ส่งมาไม่ครบ (ไม่มีอัตรา/ยอด) → ปฏิเสธทั้งคำขอ ไม่ล้างเป็นไม่หักภาษี", async () => {
    const id = await postAccrual(100000);
    const out = await confirmCash({ items: [item(id, { amount: "100000", wht: { rate: "", amount: "" } })] });
    expect(out.ok).toBe(false);
    expect(ctx.db.balance("1200")).toBe(100000);
    expect(ctx.db.balance("1100")).toBe(0);
  });

  it("หมวดค้างจ่าย (ค่าใช้จ่าย) หักภาษีไม่ได้ → ปฏิเสธ", async () => {
    const id = await postAccrual(8600, { typeKey: "expense", subCode: "exp.common" });
    const out = await confirmCash({ items: [item(id, { amount: "8600", wht: { rate: "3", amount: "258" } })] });
    expect(out.ok).toBe(false);
    expect(ctx.db.balance("2100")).toBe(-8600);
  });

  it("ล้างเป็นงวด งวดแรกถูกหัก 5% (50,000 หัก 2,500) แล้วงวดสอง 50,000 ไม่หัก → ลูกหนี้ศูนย์", async () => {
    const id = await postAccrual(100000);
    const first = await confirmCash({ items: [item(id, { amount: "50,000", wht: { rate: "5", amount: "2500" } })] });
    expect(first.ok, JSON.stringify(first)).toBe(true);
    expect(ctx.db.balance("1200")).toBe(50000);
    expect(await outstandingOf(id)).toBe(50000);
    const second = await confirmCash({ items: [item(id, { amount: "50,000", expectedClearedCount: 1 })] });
    expect(second.ok).toBe(true);
    expect(ctx.db.balance("1200")).toBe(0);
    expect(ctx.db.balance("1100")).toBe(97500);
    expect(ctx.db.balance("1800")).toBe(2500);
  });
});
