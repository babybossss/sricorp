import { describe, it, expect } from "vitest";
import { UNASSIGNED_CASH_ROWS } from "@/lib/mock/ledger";
import { MOCK_RESOLVER } from "@/lib/mock/resolver";
import { confirmBankError } from "../confirm-gate";

const corpRow = UNASSIGNED_CASH_ROWS.find((r) => r.ownerId === "corp")!;

describe("confirmBankError — ยืนยันเงินเข้า-ออกต้องมีบัญชีเสมอ", () => {
  it("ไม่ส่งบัญชีมา → ยืนยันไม่ได้", () => {
    expect(confirmBankError(corpRow, undefined, MOCK_RESOLVER)).toContain("เลือกบัญชี");
  });
  it("บัญชีว่างเปล่า → ยืนยันไม่ได้", () => {
    expect(confirmBankError(corpRow, "", MOCK_RESOLVER)).not.toBeNull();
  });
  it("บัญชีที่ไม่มีในระบบ → ยืนยันไม่ได้", () => {
    expect(confirmBankError(corpRow, "b-ghost", MOCK_RESOLVER)).toContain("b-ghost");
  });
  it("บัญชีของคนอื่น → ยืนยันไม่ได้ (เงินจะไปโผล่ในงบของคนอื่น)", () => {
    expect(confirmBankError(corpRow, "b4", MOCK_RESOLVER)).toContain("ไม่ใช่ของ");
  });
  it("บัญชีของผู้ถือรายการนั้น → ยืนยันได้", () => {
    expect(confirmBankError(corpRow, "b1", MOCK_RESOLVER)).toBeNull();
  });
  it("ทุกรายการที่ยังไม่มีบัญชีในข้อมูลจำลอง ยืนยันไม่ได้จนกว่าจะเลือก", () => {
    for (const r of UNASSIGNED_CASH_ROWS) expect(confirmBankError(r, undefined, MOCK_RESOLVER)).not.toBeNull();
  });
});
