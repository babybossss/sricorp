import { describe, it, expect } from "vitest";
import { COA, coa } from "../coa";
import {
  BS_LAYOUT,
  PL_LAYOUT,
  bsCodes,
  plCodes,
  findLayoutGaps,
  isBalanceSheetType,
  statementOf,
} from "../statements";

/**
 * บัญชีที่ไม่อยู่ในโครงงบ = ยอดหายจากรายงานโดยไม่มีอะไรฟ้อง
 * ซึ่งแย่กว่ายอดผิด เพราะงบยังดู "ลงตัว" อยู่
 */
describe("โครงงบต้องครอบคลุมผังบัญชีครบ", () => {
  it("ทุกบัญชีอยู่ในงบใดงบหนึ่ง ครั้งเดียว", () => {
    const { missing, duplicated, unknown } = findLayoutGaps();
    expect(missing, "บัญชีที่ยังไม่อยู่ในโครงงบ").toEqual([]);
    expect(duplicated, "บัญชีที่ถูกนับสองรอบ").toEqual([]);
    expect(unknown, "โครงงบอ้างรหัสที่ไม่มีในผังบัญชี").toEqual([]);
  });

  it("บัญชีงบดุลอยู่ในงบดุล · บัญชีรายได้-ค่าใช้จ่ายอยู่ใน P&L", () => {
    for (const a of COA) {
      const where = statementOf(a.code);
      expect(where.statement, `${a.code} ${a.nameTh}`).toBe(isBalanceSheetType(a.type) ? "BS" : "PL");
    }
  });

  it("ฝั่งของบรรทัดในงบดุลตรงกับประเภทบัญชี", () => {
    for (const g of BS_LAYOUT) {
      for (const l of g.lines) {
        for (const code of l.codes) {
          expect(coa(code).type, `${code} อยู่ใต้ ${g.group}`).toBe(g.side);
        }
      }
    }
  });

  it("ส่วนรายได้มีแต่บัญชีรายได้ · ส่วนค่าใช้จ่ายมีแต่ค่าใช้จ่าย", () => {
    for (const s of PL_LAYOUT) {
      for (const l of s.lines) {
        for (const code of l.codes) {
          expect(coa(code).type, `${code} อยู่ใต้ ${s.section}`).toBe(
            s.kind === "revenue" ? "income" : "expense"
          );
        }
      }
    }
  });

  it("เงินถอนของเจ้าของเป็น contra ไม่ใช่บรรทัดบวก", () => {
    // 3200 เป็นเครดิตลดส่วนของเจ้าของ ถ้าบวกเข้าไปทุนจะบวมเท่าที่ถอนออก
    const eq = BS_LAYOUT.find((g) => g.side === "equity")!;
    const drawings = eq.lines.find((l) => l.codes.includes("3200"))!;
    expect(drawings.contra).toBe(true);
  });

  it("ไม่มีบรรทัดว่าง และไม่มีชื่อบรรทัดซ้ำในงบเดียวกัน", () => {
    for (const g of BS_LAYOUT) for (const l of g.lines) expect(l.codes.length).toBeGreaterThan(0);
    for (const s of PL_LAYOUT) for (const l of s.lines) expect(l.codes.length).toBeGreaterThan(0);

    const bsLines = BS_LAYOUT.flatMap((g) => g.lines.map((l) => `${g.side}·${l.line}`));
    expect(new Set(bsLines).size).toBe(bsLines.length);
    const plLines = PL_LAYOUT.flatMap((s) => s.lines.map((l) => l.line));
    expect(new Set(plLines).size).toBe(plLines.length);
  });

  it("จำนวนรหัสในโครงงบรวมกันเท่ากับจำนวนบัญชีในผัง", () => {
    expect(bsCodes().length + plCodes().length).toBe(COA.length);
  });
});
