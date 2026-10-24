import { describe, it, expect } from "vitest";
import { cashNet, groupLedgerRows, UNKNOWN_COA, type LedgerViewRow } from "../ledger-entries";

const COA = { c1100: "1100", c4200: "4200", c1200: "1200" };

const row = (o: Partial<LedgerViewRow>): LedgerViewRow => ({
  transaction_id: "t1",
  owner_id: "o1",
  txn_type_code: "inc.rent",
  doc_date: "2026-10-24",
  cash_date: "2026-10-24",
  doc_no: null,
  txn_asset_id: null,
  contact_id: null,
  counter_owner_id: null,
  intercompany_nature: null,
  txn_memo: null,
  attachments: null,
  source: "manual",
  reverses_id: null,
  created_at: "2026-10-24T01:00:00Z",
  coa_id: "c1100",
  bank_account_id: "b1",
  debit: "12000.00",
  credit: "0.00",
  cf_category: "operating",
  line_asset_id: null,
  line_memo: null,
  ...o,
});

describe("groupLedgerRows · จัดบรรทัดของ v_ledger_posted กลับเป็นรายการ", () => {
  const rows = [
    row({}),
    row({ coa_id: "c4200", bank_account_id: null, debit: 0, credit: "12000.00", cf_category: null }),
    row({ transaction_id: "t2", coa_id: "c1200", debit: "500", credit: 0, cash_date: null, bank_account_id: null }),
    row({ transaction_id: "t2", coa_id: "c4200", debit: 0, credit: "500", cash_date: null, bank_account_id: null }),
  ];

  it("หนึ่ง transaction ต่อหนึ่งรายการ คงลำดับ และแปลงตัวเลขจากข้อความเป็นตัวเลข", () => {
    const list = groupLedgerRows(rows, COA);
    expect(list.map((e) => e.id)).toEqual(["t1", "t2"]);
    expect(list[0].lines).toHaveLength(2);
    expect(list[0].lines[0]).toMatchObject({ coaCode: "1100", debit: 12000, credit: 0 });
    expect(list[0].attachments).toEqual([]);
  });

  it("ถูกตัดที่เพดานบรรทัด → ทิ้งรายการสุดท้าย (อาจได้บรรทัดไม่ครบ) ไม่โชว์รายการที่เดบิตไม่เท่าเครดิต", () => {
    const list = groupLedgerRows(rows, COA, true);
    expect(list.map((e) => e.id)).toEqual(["t1"]);
  });

  it("รหัสบัญชีที่ไม่รู้จักแสดงเป็นไม่รู้จัก ไม่เดา", () => {
    const list = groupLedgerRows([row({ coa_id: "zzz" })], COA);
    expect(list[0].lines[0].coaCode).toBe(UNKNOWN_COA);
  });

  it("ใบกลับรายการอยู่ในรายการด้วย (ห้ามกรองออก — D-097) และบอกว่ากลับใบไหน", () => {
    const list = groupLedgerRows([row({ transaction_id: "r1", source: "reverse", reverses_id: "t1" })], COA);
    expect(list[0].source).toBe("reverse");
    expect(list[0].reversesId).toBe("t1");
  });
});

describe("cashNet · เงินเข้า/ออกจากบรรทัดเงินสดที่บันทึกจริง", () => {
  const entry = (lines: { coaCode: string; debit: number; credit: number }[]) =>
    ({ lines: lines.map((l) => ({ ...l, bankAccountId: null, assetId: null, cfCategory: null, memo: null })) });

  it("เงินเข้า = บวก · เงินออก = ลบ", () => {
    expect(cashNet(entry([{ coaCode: "1100", debit: 100, credit: 0 }, { coaCode: "4200", debit: 0, credit: 100 }]))).toBe(100);
    expect(cashNet(entry([{ coaCode: "1100", debit: 0, credit: 70 }, { coaCode: "5100", debit: 70, credit: 0 }]))).toBe(-70);
  });

  it("ไม่มีบรรทัดเงินสด (ค้างรับ/ปรับปรุง) → null ไม่ใช่ 0", () => {
    expect(cashNet(entry([{ coaCode: "1200", debit: 100, credit: 0 }, { coaCode: "4200", debit: 0, credit: 100 }]))).toBeNull();
  });
});
