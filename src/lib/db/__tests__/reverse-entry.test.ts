/**
 * เทสต์ของตัวต่อ "สมุด → engine กลับรายการ → payload" (`src/lib/db/reverse-entry.ts`)
 *
 * เน้นสองเรื่องที่พลาดแล้วตัวเลขผิดเงียบๆ
 *   1. **ด่านที่ engine มองไม่เห็น** (ถูกล้างแล้ว · ข้ามผู้ถือ · ภาษีถูกหัก · ใบกลับรายการซ้อน)
 *   2. **รูปของ payload** — คีย์ที่ไม่ควรมีต้องไม่มี (DB เทียบรายชื่อช่องและเทียบ multiset ของบรรทัด)
 */
import { describe, expect, it } from "vitest";
// รหัสบัญชีอ่านจากผังบัญชีที่เดียว เหมือนที่โค้ดจริงทำ — ถ้าเทสต์ประกาศเอง
// มันจะยังเขียวต่อไปแม้ผังบัญชีเปลี่ยน (บทเรียนข้อ 5)
import { WHT_COA } from "@/lib/rules/coa";
import {
  clearedByFromRows,
  entryFromRows,
  isReversalEntry,
  knownNature,
  reverseBlocker,
  sourceOf,
  voidBlocker,
  toReversalPayload,
  type ReverseContext,
} from "../reverse-entry";
import { groupLedgerRows, type LedgerViewRow } from "../ledger-entries";
import { buildReversal } from "@/lib/ledger/reversal";

const COA = { c1100: "1100", c4100: "4100", c1200: "1200", c1800: WHT_COA, c1310: "1310" };
const SRC = "aaaaaaaa-0000-4000-8000-000000000001";
const CLR = "bbbbbbbb-0000-4000-8000-000000000002";

const row = (o: Partial<LedgerViewRow>): LedgerViewRow => ({
  transaction_id: SRC,
  owner_id: "owner-tk",
  txn_type_code: "inc.rent",
  doc_date: "2026-10-20",
  cash_date: "2026-10-20",
  doc_no: null,
  txn_asset_id: "asset-condo",
  contact_id: "contact-tenant",
  counter_owner_id: null,
  intercompany_nature: null,
  txn_memo: "ค่าเช่าตุลาคม",
  attachments: ["owner-tk/slip.pdf"],
  source: "manual",
  source_ref: null,
  reverses_id: null,
  created_at: "2026-10-20T03:00:00Z",
  coa_id: "c1100",
  bank_account_id: "bank-kbank",
  debit: "30000.00",
  credit: "0.00",
  cf_category: "operating",
  line_asset_id: null,
  line_memo: null,
  ...o,
});

/** ค่าเช่ารับปกติ: Dr 1100 / Cr 4100 */
const rentRows = (o: Partial<LedgerViewRow> = {}): LedgerViewRow[] => [
  row(o),
  row({ coa_id: "c4100", bank_account_id: null, debit: "0.00", credit: "30000.00", line_asset_id: "asset-condo", ...o }),
];

const ctxOf = (rows: LedgerViewRow[], over: Partial<ReverseContext> = {}): ReverseContext => ({
  entry: groupLedgerRows(rows, COA)[0],
  hasLiveReversal: false,
  clearedBy: [],
  ...over,
});

describe("reverseBlocker · ด่านที่ engine มองไม่เห็น", () => {
  it("ค่าเช่ารับปกติ → ไม่มีอะไรขัด", () => {
    expect(reverseBlocker(ctxOf(rentRows()))).toBeNull();
  });

  it("ใบกลับรายการอยู่แล้ว → ปฏิเสธ พร้อมบอกทางออก (void แล้วลงใหม่) ไม่ใช่ทางตัน", () => {
    const msg = reverseBlocker(ctxOf(rentRows({ source: "reverse", reverses_id: "ใบเดิม" })));
    expect(msg).toMatch(/เป็นใบกลับรายการอยู่แล้ว/);
    expect(msg).toMatch(/ยกเลิก \(void\)/);
    expect(msg).toMatch(/ลงรายการนั้นใหม่/);
  });

  it("ใบที่ source ยังเป็น manual แต่มี reverses_id → ถือเป็นใบกลับรายการเช่นกัน (ดูสองช่อง ไม่ใช่ช่องเดียว)", () => {
    expect(reverseBlocker(ctxOf(rentRows({ reverses_id: "ใบเดิม" })))).toMatch(/เป็นใบกลับรายการอยู่แล้ว/);
    expect(isReversalEntry({ source: "manual", reversesId: "x" })).toBe(true);
    expect(isReversalEntry({ source: "reverse", reversesId: null })).toBe(true);
    expect(isReversalEntry({ source: "manual", reversesId: null })).toBe(false);
  });

  it("ขาข้ามผู้ถือ → ปฏิเสธ และบอกว่าห้ามกลับข้างเดียว (ด่าน DB ยังปิด)", () => {
    const msg = reverseBlocker(ctxOf(rentRows({ counter_owner_id: "owner-corp", intercompany_nature: "advance" })));
    expect(msg).toMatch(/ข้ามผู้ถือ/);
    expect(msg).toMatch(/ห้ามกลับข้างเดียว/);
    expect(msg).toMatch(/ยังไม่ได้แก้อะไรในสมุด/);
  });

  it("ใบที่ถูกหักภาษี ณ ที่จ่าย (มีบรรทัด 1800) → ปฏิเสธ ไม่ใช่ตัดบรรทัดภาษีออกแล้วลง", () => {
    const rows = [
      row({ debit: "28500.00" }),
      row({ coa_id: "c1800", bank_account_id: null, debit: "1500.00", credit: "0.00", cf_category: null }),
      row({ coa_id: "c4100", bank_account_id: null, debit: "0.00", credit: "30000.00" }),
    ];
    expect(reverseBlocker(ctxOf(rows))).toMatch(/ภาษีถูกหัก ณ ที่จ่าย/);
  });

  it("ถูกล้างไปแล้ว → ปฏิเสธ พร้อมบอกว่าต้องกลับใบล้างก่อน และบอกเลขใบล้าง", () => {
    const msg = reverseBlocker(ctxOf(rentRows(), { clearedBy: [CLR] }));
    expect(msg).toMatch(/ต้องกลับรายการใบล้างก่อน/);
    expect(msg).toContain(CLR);
  });

  it("ลำดับการตรวจ: ใบกลับรายการพูดก่อนเรื่องอื่น (ข้อความต้องชี้เหตุที่ใกล้ตัวผู้ใช้ที่สุด)", () => {
    const msg = reverseBlocker(
      ctxOf(rentRows({ source: "reverse", reverses_id: "x", counter_owner_id: "owner-corp", intercompany_nature: "loan" }), {
        clearedBy: [CLR],
      })
    );
    expect(msg).toMatch(/เป็นใบกลับรายการอยู่แล้ว/);
  });
});

describe("voidBlocker · ด่านของการยกเลิกใบ (คนละชุดกับการกลับรายการ · D-097)", () => {
  it("ค่าเช่ารับปกติ → ยกเลิกได้", () => {
    expect(voidBlocker(ctxOf(rentRows()))).toBeNull();
  });

  it("ใบกลับรายการที่ลงผิด → **ยกเลิกได้** (D-097 เปิดทางไว้ ไม่ใช่ทางตัน)", () => {
    expect(voidBlocker(ctxOf(rentRows({ source: "reverse", reverses_id: "ใบเดิม" })))).toBeNull();
  });

  it("ใบที่ถูกหักภาษี ณ ที่จ่าย → ยกเลิกได้ (เปลี่ยนสถานะไม่ได้แก้บรรทัด ยอดภาษียังตรงกับบรรทัด 1800)", () => {
    const rows = [
      row({ debit: "28500.00" }),
      row({ coa_id: "c1800", bank_account_id: null, debit: "1500.00", credit: "0.00", cf_category: null }),
      row({ coa_id: "c4100", bank_account_id: null, debit: "0.00", credit: "30000.00" }),
    ];
    expect(voidBlocker(ctxOf(rows))).toBeNull();
  });

  it("ขาข้ามผู้ถือ → ปฏิเสธ (ยกเลิกข้างเดียว = ลูกหนี้ระหว่างกันค้างข้างเดียว และหาขาคู่แน่ชัดไม่ได้)", () => {
    const msg = voidBlocker(ctxOf(rentRows({ counter_owner_id: "owner-corp", intercompany_nature: "loan" })));
    expect(msg).toMatch(/ข้ามผู้ถือ/);
    expect(msg).toMatch(/ยังไม่ได้แก้อะไรในสมุด/);
  });

  it("ถูกล้างไปแล้ว → ปฏิเสธ (ไม่มีด่านฝั่ง DB กันเรื่องนี้ตอนเปลี่ยนสถานะ)", () => {
    expect(voidBlocker(ctxOf(rentRows(), { clearedBy: [CLR] }))).toMatch(/ใบล้าง/);
  });

  it("ใบที่มีใบกลับรายการอยู่ → ไม่ปฏิเสธที่ชั้นนี้ (ปล่อยให้ fn_void_blocked_by_reverse พูด — กฎเดียวห้ามมีสองข้อความ)", () => {
    expect(voidBlocker(ctxOf(rentRows(), { hasLiveReversal: true }))).toBeNull();
  });
});

describe("knownNature · ลักษณะข้ามผู้ถือที่ไม่รู้จักต้องไม่ถูกเดา", () => {
  it("รู้จัก → คืนค่า · ไม่รู้จัก/ว่าง → undefined", () => {
    expect(knownNature("advance")).toBe("advance");
    expect(knownNature("dividend")).toBe("dividend");
    expect(knownNature("ลักษณะที่ไม่มีในตารางกฎ")).toBeUndefined();
    expect(knownNature(null)).toBeUndefined();
  });
});

describe("entryFromRows / clearedByFromRows", () => {
  it("หยิบรายการที่ขอมาใบเดียว · ไม่เจอ = null (ไม่หยิบใบอื่นมาแทน)", () => {
    const rows = [...rentRows(), row({ transaction_id: CLR, coa_id: "c1200" })];
    expect(entryFromRows(rows, SRC, COA)?.id).toBe(SRC);
    expect(entryFromRows(rows, "ไม่มีใบนี้", COA)).toBeNull();
  });

  it("ใบล้างหาจาก source_ref ไม่ใช่เดาจากยอด · เลขอ้างอิงของใบอื่นไม่นับ", () => {
    const rows = [
      ...rentRows(),
      row({ transaction_id: CLR, source_ref: `${SRC}-clr-1` }),
      row({ transaction_id: "cccccccc-0000-4000-8000-000000000003", source_ref: `${CLR}-clr-1` }),
      row({ transaction_id: "dddddddd-0000-4000-8000-000000000004", source_ref: "ข้อความที่ไม่ใช่เลขอ้างอิง" }),
    ];
    expect(clearedByFromRows(rows, SRC)).toEqual([CLR]);
  });

  it("ตัวพิมพ์ใหญ่-เล็กของ id ไม่ทำให้ใบล้างหลุดการนับ", () => {
    const rows = [row({ transaction_id: CLR, source_ref: `${SRC.toUpperCase()}-clr-1` })];
    expect(clearedByFromRows(rows, SRC)).toEqual([CLR]);
  });
});

describe("sourceOf → buildReversal → toReversalPayload", () => {
  const build = (rows: LedgerViewRow[]) =>
    buildReversal({
      originals: [sourceOf(ctxOf(rows))],
      reason: "ลงผิดห้อง",
      docDate: "2026-11-11",
      cashDate: "2026-11-11",
    });

  it("มิติที่ต้นฉบับไม่มีต้องไม่มีคีย์ (null ไม่เท่ากับ ไม่มีคีย์ ตอน DB เทียบ multiset)", () => {
    const src = sourceOf(ctxOf(rentRows()));
    const revenue = src.lines[1];
    expect("bankAccountId" in revenue).toBe(false);
    expect(revenue.assetId).toBe("asset-condo");
    expect(revenue.cfCategory).toBe("operating");
  });

  it("payload: source = reverse · มี reverses_id · ใบเดียวต่อหนึ่งผู้ถือ · บรรทัดสลับข้าง", () => {
    const { transactions } = build(rentRows());
    const p = toReversalPayload(transactions[0], { txnTypeCode: "inc.rent", contactId: "contact-tenant", assetId: "asset-condo" });
    expect(p.source).toBe("reverse");
    expect(p.reverses_id).toBe(SRC);
    expect(p.txn_type_code).toBe("inc.rent");
    expect(p.transactions).toHaveLength(1);
    expect(p.transactions[0].owner_id).toBe("owner-tk");
    expect(p.transactions[0].lines[0]).toMatchObject({ coa_code: "1100", debit: 0, credit: 30000, bank_account_id: "bank-kbank" });
    expect(p.transactions[0].lines[1]).toMatchObject({ coa_code: "4100", debit: 30000, credit: 0 });
    const dr = p.transactions[0].lines.reduce((t, l) => t + l.debit, 0);
    const cr = p.transactions[0].lines.reduce((t, l) => t + l.credit, 0);
    expect(dr).toBe(cr);
  });

  it("payload: ไม่พาไฟล์แนบและไม่พาเลขอ้างอิงการล้างของต้นฉบับไปด้วย", () => {
    const { transactions } = build(rentRows({ source_ref: `${SRC}-clr-1` }));
    const p = toReversalPayload(transactions[0], { txnTypeCode: "inc.rent", contactId: null, assetId: null });
    expect(p.attachments).toBeUndefined();
    expect(p.source_ref).toBeUndefined();
    expect(p.wht_rate).toBeUndefined();
    expect(p.wht_amount).toBeUndefined();
  });

  it("payload: เหตุผลลงไปใน memo และอ้างถึงใบต้นฉบับ (ร่องรอยที่ผู้สอบบัญชีจะถาม)", () => {
    const { transactions } = build(rentRows());
    const p = toReversalPayload(transactions[0], { txnTypeCode: "inc.rent", contactId: null, assetId: null });
    expect(p.memo).toContain("ลงผิดห้อง");
    expect(p.memo).toContain(SRC);
  });

  it("payload: ค้างรับ (ไม่มีบรรทัดเงินสด) → cash_date เป็น null ไม่ใช่วันที่ของใบ", () => {
    const accrual = [
      row({ coa_id: "c1200", bank_account_id: null, cash_date: null, debit: "30000.00", credit: "0.00", cf_category: null }),
      row({ coa_id: "c4100", bank_account_id: null, cash_date: null, debit: "0.00", credit: "30000.00", cf_category: null }),
    ];
    const built = buildReversal({ originals: [sourceOf(ctxOf(accrual))], reason: "ตั้งค้างผิด", docDate: "2026-11-11" });
    const p = toReversalPayload(built.transactions[0], { txnTypeCode: "inc.rent_accrue", contactId: null, assetId: null });
    expect(p.cash_date).toBeNull();
  });

  it("payload: บรรทัดบาทต้องไม่มีคีย์สกุลเงินเลย (check constraint ยอมแค่ครบสี่หรือไม่มี)", () => {
    const { transactions } = build(rentRows());
    const p = toReversalPayload(transactions[0], { txnTypeCode: "inc.rent", contactId: null, assetId: null });
    for (const l of p.transactions[0].lines) {
      for (const k of ["currency", "amount_original", "fx_rate", "fx_rate_date"]) {
        expect(k in l, `บรรทัดบาทต้องไม่มีคีย์ ${k}`).toBe(false);
      }
    }
  });

  it("ส่งต่อ hasLiveReversal ให้ engine — กลับซ้ำสองรอบถูกปฏิเสธ", () => {
    expect(() =>
      buildReversal({
        originals: [sourceOf(ctxOf(rentRows(), { hasLiveReversal: true }))],
        reason: "กลับอีกรอบ",
        docDate: "2026-11-11",
        cashDate: "2026-11-11",
      })
    ).toThrow(/หักสองรอบ/);
  });
});
