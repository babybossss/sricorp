/**
 * `reverseEntry()` / `voidEntry()` — ทางเดียวที่หน้าจอแก้รายการที่ post แล้วได้ (กฎเหล็กข้อ 1)
 *
 * เคสที่ตั้งใจให้มีเยอะกว่าปกติคือ **เคสที่ข้อมูลขาด** และ **เคสที่ต้องปฏิเสธ**
 * (บทเรียน `mace-windu` ข้อ 3: เทสต์ที่ส่งข้อมูลครบเสมอ จะไม่มีวันแตะเส้นทางที่ข้อมูลขาด)
 *
 * ด่านจริงอยู่ที่ DB (trigger) — ที่นี่พิสูจน์ว่า action **ไม่ส่งของที่ DB จะปฏิเสธ**
 * และปฏิเสธเองพร้อมข้อความที่อ่านรู้เรื่องก่อนแตะสมุด (`ctx.db.rpcCalls` ต้องไม่ยาวขึ้น)
 */
import "./mocks";
import { beforeEach, describe, expect, it } from "vitest";
import { ctx, resetCtx } from "./ctx";
import { ASSET, BANK, CONTACT, OWNER } from "./fake-db";
import { postEntry } from "../post-entry";
import { reverseEntry, voidEntry } from "../reverse-entry";
import type { PostingInput } from "@/lib/ledger/types";

const REASON = "ลงผิดห้อง ที่ถูกคือคอนโดอีกห้อง";

/** ไฟล์หลักฐานที่ "อัปโหลดจริง" ของผู้ถือ — path รูปแบบเดียวกับ Storage (ผ่านด่านนิติบุคคลของ engine) */
const evidence = (ownerId: string) =>
  `${ownerId}/cccccccc-3333-4333-8333-cccccccccccc/dddddddd-4444-4444-8444-000000000001.pdf`;

const rent = (over: Partial<PostingInput> = {}): PostingInput => ({
  typeKey: "income",
  subCode: "inc.rent",
  amount: 30000,
  ownerId: OWNER.tk,
  bankAccountId: BANK.tk,
  assetId: ASSET,
  contactId: CONTACT,
  ...over,
});

async function postRent(over: Partial<PostingInput> = {}, cashDate = "20/10/2026") {
  const out = await postEntry({ input: rent(over), docDate: "20/10/2026", cashDate });
  if (!out.ok) throw new Error(`ลงรายการต้นฉบับไม่ได้: ${out.message}`);
  return out.transactionIds[0];
}

/** ตั้งค้างรับ (ไม่มีขาเงินสด) */
async function postAccrual() {
  const out = await postEntry({ input: rent({ amount: 12000, notYetPaid: true, bankAccountId: undefined }), docDate: "01/10/2026", cashDate: "" });
  if (!out.ok) throw new Error(`ตั้งค้างไม่ได้: ${out.message}`);
  return out.transactionIds[0];
}

const calls = () => ctx.db.rpcCalls.length;
const headOf = (id: string) => ctx.db.heads.get(id);

beforeEach(() => {
  resetCtx();
  // แก้รายการที่ post แล้ว = txn.void (RLS policy txn_update) · ลงใบใหม่ = ledger.approve
  ctx.access.permissions = new Set(["ledger.approve", "txn.create", "txn.void"]);
});

describe("reverseEntry · เส้นทางที่ถูก", () => {
  it("กลับรายการค่าเช่า → ยอดทุกบัญชีกลับเป็นศูนย์ และต้นฉบับยังอยู่ในสมุด", async () => {
    const id = await postRent();
    expect(ctx.db.balance("1100")).toBe(30000);
    expect(ctx.db.balance("4200")).toBe(-30000);

    const out = await reverseEntry({ transactionId: id, reason: REASON });
    expect(out.ok, JSON.stringify(out)).toBe(true);

    // นี่คือคุณสมบัติที่ทั้งหมดนี้มีไว้เพื่อ: หักกันหมดจริง
    expect(ctx.db.balance("1100")).toBe(0);
    expect(ctx.db.balance("4200")).toBe(0);
    // ต้นฉบับ **ไม่ถูกลบ ไม่ถูกซ่อน** — ยังเป็น posted และยังอยู่ในวิวของงบ
    expect(headOf(id)!.status).toBe("posted");
    expect(ctx.db.rows.some((r) => r.transaction_id === id)).toBe(true);
    // และไม่มีการลบอะไรเลยในทุกเส้นทาง
    expect(ctx.db.writes.some((w) => w.op === "delete")).toBe(false);
  });

  it("payload ที่ส่งไป DB: source = reverse · reverses_id ชี้ต้นฉบับ · หมวดเดิม · ไม่พาไฟล์แนบไป", async () => {
    const id = await postRent();
    await reverseEntry({ transactionId: id, reason: REASON });
    const p = ctx.db.rpcCalls[ctx.db.rpcCalls.length - 1];
    expect(p.source).toBe("reverse");
    expect(p.reverses_id).toBe(id);
    expect(p.txn_type_code).toBe("inc.rent");
    expect(p.attachments).toBeUndefined();
    expect(String(p.memo)).toContain(REASON);
    // 1 transaction = 1 owner
    expect((p.transactions as unknown[]).length).toBe(1);
  });

  it("ใบกลับรายการสมดุลในตัวเอง (Σ เดบิต = Σ เครดิต)", async () => {
    const id = await postRent();
    await reverseEntry({ transactionId: id, reason: REASON });
    const p = ctx.db.rpcCalls[ctx.db.rpcCalls.length - 1];
    for (const t of p.transactions as { lines: { debit: number; credit: number }[] }[]) {
      const dr = t.lines.reduce((s, l) => s + Number(l.debit), 0);
      const cr = t.lines.reduce((s, l) => s + Number(l.credit), 0);
      expect(dr).toBe(cr);
      expect(dr).toBeGreaterThan(0);
    }
  });

  it("ค้างรับที่ยังไม่ถูกล้าง: กลับรายการได้ และ cash_date ต้องเป็น null (ไม่มีเงินสดผี)", async () => {
    const id = await postAccrual();
    const out = await reverseEntry({ transactionId: id, reason: "ตั้งค้างผิด" });
    expect(out.ok, JSON.stringify(out)).toBe(true);
    const p = ctx.db.rpcCalls[ctx.db.rpcCalls.length - 1];
    expect(p.cash_date).toBeNull();
    expect(ctx.db.balance("1200")).toBe(0);
    expect(ctx.db.balance("4200")).toBe(0);
  });

  it("นิติบุคคล: ใบกลับรายการไม่ต้องแนบหลักฐานใหม่ แต่ยังพาคู่ค้าของต้นฉบับไปด้วย", async () => {
    const out0 = await postEntry({
      // `inc.other` ไม่บังคับทรัพย์ (ทรัพย์ในชุดทดสอบเป็นของธนากร ไม่ใช่ของนิติบุคคล)
      input: rent({ subCode: "inc.other", ownerId: OWNER.corp, bankAccountId: BANK.corp, assetId: undefined, attachments: [evidence(OWNER.corp)] }),
      docDate: "20/10/2026",
      cashDate: "20/10/2026",
    });
    expect(out0.ok, JSON.stringify(out0)).toBe(true);
    const id = (out0 as { transactionIds: string[] }).transactionIds[0];

    const out = await reverseEntry({ transactionId: id, reason: REASON });
    expect(out.ok, JSON.stringify(out)).toBe(true);
    const p = ctx.db.rpcCalls[ctx.db.rpcCalls.length - 1];
    expect(p.attachments).toBeUndefined();
    expect(p.contact_id).toBe(CONTACT);
  });
});

describe("reverseEntry · ข้อมูลไม่ครบต้องปฏิเสธ ไม่ใช่เดา", () => {
  it("ไม่ส่งเหตุผล → ปฏิเสธ และยังไม่แตะสมุดเลย", async () => {
    const id = await postRent();
    const before = calls();
    const out = await reverseEntry({ transactionId: id, reason: "   " });
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.message).toMatch(/เหตุผล/);
    expect(calls()).toBe(before);
    expect(ctx.db.balance("1100")).toBe(30000);
  });

  it("ไม่ส่ง id ของรายการ → ปฏิเสธ", async () => {
    const out = await reverseEntry({ transactionId: "", reason: REASON });
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.message).toMatch(/ไม่ได้ระบุว่าจะกลับรายการใบไหน/);
  });

  it("ไม่ส่งคำขอมาเลย → ปฏิเสธ ไม่ใช่พัง", async () => {
    const out = await reverseEntry(undefined as never);
    expect(out.ok).toBe(false);
  });

  it("id ที่ไม่มีในสมุด → ปฏิเสธ พร้อมบอกว่าอาจถูกยกเลิกไปแล้ว", async () => {
    await postRent();
    const before = calls();
    const out = await reverseEntry({ transactionId: "00000000-0000-4000-8000-00000000ffff", reason: REASON });
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.message).toMatch(/ไม่พบรายการ/);
    expect(calls()).toBe(before);
  });

  it("ไม่มีสิทธิ์แก้รายการที่ post แล้ว → ปฏิเสธ", async () => {
    const id = await postRent();
    ctx.access.permissions = new Set(["ledger.approve", "txn.create"]);
    const out = await reverseEntry({ transactionId: id, reason: REASON });
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.message).toMatch(/สิทธิ์/);
  });

  it("เข้าสู่ระบบหมดอายุ → ปฏิเสธ", async () => {
    const id = await postRent();
    ctx.access.user = null;
    const out = await reverseEntry({ transactionId: id, reason: REASON });
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.message).toMatch(/เข้าสู่ระบบ/);
  });
});

describe("reverseEntry · กันยอดกลับทิศเกินจริง", () => {
  it("กลับรายการใบเดียวกันสองรอบ → รอบที่สองถูกปฏิเสธ และยอดไม่เกินจริง", async () => {
    const id = await postRent();
    expect((await reverseEntry({ transactionId: id, reason: REASON })).ok).toBe(true);

    const before = calls();
    const again = await reverseEntry({ transactionId: id, reason: "กลับอีกรอบ" });
    expect(again.ok).toBe(false);
    if (!again.ok) expect(again.message).toMatch(/กลับรายการ(ไปแล้ว|ที่ยังมีผลอยู่แล้ว)|หักสองรอบ/);
    expect(calls()).toBe(before); // ไม่ยิงถึง DB เลย
    expect(ctx.db.balance("1100")).toBe(0); // ไม่ใช่ −30,000
    expect(ctx.db.balance("4200")).toBe(0);
  });

  it("กลับรายการ 'ใบกลับรายการ' → ปฏิเสธ พร้อมบอกทางออก (ไม่ใช่ทางตัน)", async () => {
    const id = await postRent();
    const out = await reverseEntry({ transactionId: id, reason: REASON });
    expect(out.ok).toBe(true);
    const revId = (out as { transactionIds: string[] }).transactionIds[0];

    const again = await reverseEntry({ transactionId: revId, reason: "กลับใบกลับรายการ" });
    expect(again.ok).toBe(false);
    if (!again.ok) {
      expect(again.message).toMatch(/เป็นใบกลับรายการอยู่แล้ว/);
      expect(again.message).toMatch(/ยกเลิก \(void\)/);
    }
  });

  it("ใบที่ถูกล้างไปแล้ว → ปฏิเสธ พร้อมบอกว่าต้องกลับใบล้างก่อน", async () => {
    const id = await postAccrual();
    // ใบล้างยอดค้าง (เส้นทางเดียวกับหน้า "ยืนยันรับ-จ่าย": source_ref = <id ต้นทาง>-clr-1)
    const clearing = await ctx.db.client.rpc("fn_post_entry", {
      p_payload: {
        txn_type_code: "inc.collect_rent",
        doc_date: "2026-10-24",
        cash_date: "2026-10-24",
        source_ref: `${id}-clr-1`,
        transactions: [
          {
            owner_id: OWNER.tk,
            lines: [
              { coa_code: "1100", bank_account_id: BANK.tk, debit: 12000, credit: 0, cf_category: "operating" },
              { coa_code: "1200", debit: 0, credit: 12000, cf_category: "operating" },
            ],
          },
        ],
      },
    });
    expect(clearing.error, JSON.stringify(clearing.error)).toBeNull();

    const before = calls();
    const out = await reverseEntry({ transactionId: id, reason: "ตั้งค้างผิด" });
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.message).toMatch(/ต้องกลับรายการใบล้างก่อน/);
    expect(calls()).toBe(before);
  });

  /**
   * **ครึ่งหลังของเคสข้างบน — ที่ขาดไปคือรูจริง** (ผู้ตรวจจับได้ · บทเรียนข้อ 7)
   *
   * เคสข้างบนพิสูจน์แค่ว่าระบบ**บอก**ให้ไปกลับใบล้างก่อน แต่ไม่เคยพิสูจน์ว่า
   * **ทำตามแล้วไปต่อได้จริง** · ถ้าด่านไม่หักใบล้างที่ถูกกลับไปแล้วออก
   * ใบล้างเดิมยัง `posted` และยังมี `source_ref` เดิม → บล็อกเดิมยิงซ้ำตลอดไป
   * **ต้นฉบับกลับรายการไม่ได้ถาวร** ทั้งที่ผู้ใช้ทำตามที่ระบบสั่งทุกขั้น
   *
   * เปิดฟีเจอร์ครึ่งเดียวแบบนี้แย่กว่าไม่เปิด เพราะผู้ใช้เสียเวลากลับใบล้างทิ้งไป
   * แล้วยังติดที่เดิม และไม่มีอะไรบอกว่าทำไม
   */
  it("กลับใบล้างแล้ว ต้นฉบับต้องกลับรายการได้จริง — ไม่ใช่ทางตัน", async () => {
    const id = await postAccrual();
    const clearing = await ctx.db.client.rpc("fn_post_entry", {
      p_payload: {
        txn_type_code: "inc.collect_rent",
        doc_date: "2026-10-24",
        cash_date: "2026-10-24",
        source_ref: `${id}-clr-1`,
        transactions: [
          {
            owner_id: OWNER.tk,
            lines: [
              { coa_code: "1100", bank_account_id: BANK.tk, debit: 12000, credit: 0, cf_category: "operating" },
              { coa_code: "1200", debit: 0, credit: 12000, cf_category: "operating" },
            ],
          },
        ],
      },
    });
    expect(clearing.error, JSON.stringify(clearing.error)).toBeNull();

    // หา id ของใบล้างจากสมุด ไม่เดาจากค่าที่ส่งไป
    const found = await ctx.db.client
      .from("v_ledger_posted")
      .select("transaction_id")
      .eq("source_ref", `${id}-clr-1`);
    expect(found.error, JSON.stringify(found.error)).toBeNull();
    const clearingId = (found.data ?? [])[0]?.transaction_id as string;
    expect(clearingId, "ไม่พบใบล้างในสมุด").toBeTruthy();

    // ขั้นที่ 1 — ทำตามที่ระบบสั่ง: กลับใบล้างก่อน
    const undoClearing = await reverseEntry({ transactionId: clearingId, reason: "ล้างผิดใบ" });
    expect(undoClearing.ok, JSON.stringify(undoClearing)).toBe(true);

    // ขั้นที่ 2 — ต้นฉบับต้องกลับได้แล้ว (ก่อนแก้: ยังโดนบล็อกเดิมซ้ำ = ทางตัน)
    const out = await reverseEntry({ transactionId: id, reason: "ตั้งค้างผิด" });
    expect(out.ok, `ต้นฉบับยังกลับไม่ได้ทั้งที่กลับใบล้างแล้ว: ${JSON.stringify(out)}`).toBe(true);

    // และยอดลูกหนี้ต้องกลับเป็นศูนย์ ไม่ใช่แค่ "คำสั่งผ่าน"
    const lines = await ctx.db.client
      .from("v_ledger_posted")
      .select("coa_code, debit, credit")
      .eq("owner_id", OWNER.tk);
    expect(lines.error, JSON.stringify(lines.error)).toBeNull();
    const net1200 = (lines.data ?? [])
      .filter((l) => (l as { coa_code: string }).coa_code === "1200")
      .reduce((a, l) => a + Number((l as { debit: number }).debit) - Number((l as { credit: number }).credit), 0);
    expect(net1200, "ลูกหนี้ค่าเช่าไม่กลับเป็นศูนย์หลังกลับทั้งสองใบ").toBe(0);
  });

  it("รายการข้ามผู้ถือ → ปฏิเสธทั้งคู่ ไม่กลับข้างเดียว (ด่าน DB ยังปิด)", async () => {
    const out0 = await postEntry({
      input: {
        typeKey: "transfer",
        subCode: "trf.internal",
        amount: 100000,
        ownerId: OWNER.tk,
        bankAccountId: BANK.tk,
        transferToBankAccountId: BANK.sutee,
        intercompanyNature: "advance",
      },
      docDate: "20/10/2026",
      cashDate: "20/10/2026",
    });
    expect(out0.ok, JSON.stringify(out0)).toBe(true);
    const ids = (out0 as { transactionIds: string[] }).transactionIds;
    expect(ids).toHaveLength(2);

    const before = calls();
    for (const id of ids) {
      const out = await reverseEntry({ transactionId: id, reason: REASON });
      expect(out.ok).toBe(false);
      if (!out.ok) expect(out.message).toMatch(/ข้ามผู้ถือ/);
    }
    expect(calls()).toBe(before);
  });
});

describe("voidEntry · ยกเลิกใบทั้งใบ (งวดที่ยังไม่ปิด · D-097)", () => {
  it("ยกเลิกแล้วรายการหายจากงบ แต่แถวยังอยู่และบอกได้ว่าใครยกเลิกเพราะอะไร", async () => {
    const id = await postRent();
    const out = await voidEntry({ transactionId: id, reason: REASON });
    expect(out.ok, JSON.stringify(out)).toBe(true);

    const head = headOf(id)!;
    expect(head.status).toBe("void");
    expect(head.void_reason).toBe(REASON);
    expect(head.voided_by).toBe(ctx.access.user!.id);
    expect(head.voided_at).not.toBeNull();
    // ตัดออกจากงบ แต่ไม่ลบแถว (D-098)
    expect(ctx.db.balance("1100")).toBe(0);
    expect(ctx.db.rows.some((r) => r.transaction_id === id)).toBe(true);
    expect(ctx.db.writes.some((w) => w.op === "delete")).toBe(false);
  });

  it("ยกเลิกโดยไม่ใส่เหตุผล → ปฏิเสธ (เหตุผลบังคับทุกผู้ถือ · D-098)", async () => {
    const id = await postRent();
    const out = await voidEntry({ transactionId: id, reason: "" });
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.message).toMatch(/เหตุผล/);
    expect(headOf(id)!.status).toBe("posted");
  });

  it("ยกเลิกซ้ำ → ปฏิเสธ (ใบที่ยกเลิกแล้วไม่อยู่ในงบอยู่แล้ว)", async () => {
    const id = await postRent();
    expect((await voidEntry({ transactionId: id, reason: REASON })).ok).toBe(true);
    const again = await voidEntry({ transactionId: id, reason: REASON });
    expect(again.ok).toBe(false);
    if (!again.ok) expect(again.message).toMatch(/ไม่พบรายการ|ยกเลิก/);
  });

  it("ยกเลิกต้นฉบับที่มีใบกลับรายการอยู่ → DB ปฏิเสธ และข้อความไม่ถูกกลืน", async () => {
    const id = await postRent();
    expect((await reverseEntry({ transactionId: id, reason: REASON })).ok).toBe(true);
    const out = await voidEntry({ transactionId: id, reason: "อยากยกเลิกด้วย" });
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.message).toMatch(/ใบกลับรายการ/);
    expect(headOf(id)!.status).toBe("posted");
  });

  it("ยกเลิก 'ใบกลับรายการ' ที่ลงผิดได้ (D-097 เปิดทางไว้ ไม่ใช่ทางตัน) และยอดกลับไปเป็นของต้นฉบับ", async () => {
    const id = await postRent();
    const rev = await reverseEntry({ transactionId: id, reason: REASON });
    const revId = (rev as { transactionIds: string[] }).transactionIds[0];
    const out = await voidEntry({ transactionId: revId, reason: "ใบกลับรายการนี้ลงผิดวัน" });
    expect(out.ok, JSON.stringify(out)).toBe(true);
    expect(ctx.db.balance("1100")).toBe(30000);
    // และต้นฉบับกลับมากลับรายการใหม่ได้ (ใบกลับรายการที่ void แล้วไม่นับเป็น "ยังมีผลอยู่")
    expect((await reverseEntry({ transactionId: id, reason: "กลับใหม่ให้ถูกวัน" })).ok).toBe(true);
    expect(ctx.db.balance("1100")).toBe(0);
  });

  it("ไม่มีสิทธิ์ → ปฏิเสธ · ไม่ส่ง id มา → ปฏิเสธ", async () => {
    const id = await postRent();
    ctx.access.permissions = new Set(["ledger.approve"]);
    expect((await voidEntry({ transactionId: id, reason: REASON })).ok).toBe(false);
    ctx.access.permissions = new Set(["ledger.approve", "txn.void"]);
    expect((await voidEntry({ transactionId: "", reason: REASON })).ok).toBe(false);
  });

  it("RLS ปฏิเสธการเขียน (ไม่มีแถวถูกแตะ) → ต้องรายงานว่าไม่สำเร็จ ไม่ใช่ตอบว่าสำเร็จ", async () => {
    const id = await postRent();
    ctx.db.control.denyWrites.add("transactions");
    const out = await voidEntry({ transactionId: id, reason: REASON });
    expect(out.ok).toBe(false);
    expect(headOf(id)!.status).toBe("posted");
  });
});
