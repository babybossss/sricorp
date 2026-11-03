import { describe, it, expect } from "vitest";
import { money, parseAmount, parseAmountOrNull } from "../format";
import { EMPTY_DISPOSAL, signedUnrealized } from "@/components/form/disposal-value";

/**
 * ฟังก์ชันนี้แปลงทุกช่องเงินของทั้งระบบ และเคย**สลับเครื่องหมาย**มาตลอด
 * เพราะไม่มีเทสต์คุม — ผู้ใช้ก๊อปตัวเลขจากหน้าจอมาวางแล้วติดลบกลายเป็นบวก
 * (กติกา CLAUDE.md ข้อ 3: test-first ทุกอย่างที่แตะเงิน)
 */
describe("อ่านตัวเลขเงินจากช่องกรอก", () => {
  it("วงเล็บคือติดลบ — เป็นรูปแบบที่ money() แสดงออกมาเอง", () => {
    expect(parseAmountOrNull("(300,000.00)")).toBe(-300000);
    expect(parseAmountOrNull("(0.01)")).toBe(-0.01);
  });

  it("เครื่องหมายลบยูนิโคดทุกแบบที่หน้าจอผลิตได้", () => {
    expect(parseAmountOrNull("−300000"), "U+2212 minus").toBe(-300000);
    expect(parseAmountOrNull("–300000"), "en dash").toBe(-300000);
    expect(parseAmountOrNull("—300000"), "em dash").toBe(-300000);
    expect(parseAmountOrNull("-300000"), "ASCII hyphen").toBe(-300000);
  });

  it("จุลภาค ช่องว่าง และสัญลักษณ์บาท ไม่ทำให้อ่านพลาด", () => {
    expect(parseAmountOrNull("12,000.00")).toBe(12000);
    expect(parseAmountOrNull("  1,234.50  ")).toBe(1234.5);
    expect(parseAmountOrNull("฿ 5,000")).toBe(5000);
    expect(parseAmountOrNull("- 500")).toBe(-500);
  });

  it("อ่านไม่ออกต้องคืน null ไม่ใช่ 0", () => {
    // 0 ที่ระบบเดาเอง แยกไม่ออกจาก 0 ที่ผู้ใช้ตั้งใจใส่
    for (const bad of ["300000-", "(1,000", "1e3", "๑๒๓", "abc", "", "   ", "--5", "1-2"]) {
      expect(parseAmountOrNull(bad), JSON.stringify(bad)).toBeNull();
    }
  });

  it("รูปแบบยุโรป 1.000,50 ต้องปฏิเสธ ไม่ใช่อ่านเป็น 1.0005", () => {
    // ตัดจุลภาคทิ้งดื้อๆ จะผิดไปพันเท่าโดยไม่มีอะไรฟ้อง
    expect(parseAmountOrNull("1.000,50")).toBeNull();
    expect(parseAmountOrNull("1.234.567,89")).toBeNull();
  });

  it("ยอดย่อแบบ 6.4M อ่านไม่ได้ ต้องไม่เดา", () => {
    expect(parseAmountOrNull("฿ 6.4M")).toBeNull();
  });

  it("สิ่งที่ money() พิมพ์ออกมา ต้องอ่านกลับได้ค่าเดิม", () => {
    for (const n of [1, -1, 1234.5, -1234.5, 84415920, -0.01, 0]) {
      const shown = money(n, { dash: false });
      expect(parseAmountOrNull(shown), `${n} -> "${shown}"`).toBe(n);
    }
  });

  it("parseAmount คืน 0 เมื่ออ่านไม่ออก ส่วน parseAmountOrNull คืน null", () => {
    expect(parseAmount("abc")).toBe(0);
    expect(parseAmountOrNull("abc")).toBeNull();
    expect(parseAmount("(1,000.00)")).toBe(-1000);
  });
});

/**
 * ทิศทางของส่วนต่างจากการตีราคามาจาก**ปุ่ม** ไม่ใช่เครื่องหมายที่พิมพ์
 * วางค่าติดลบมาก็ต้องไม่ทำให้ทิศกลับด้าน
 */
describe("ส่วนต่างจากการตีราคา — ทิศมาจากปุ่ม", () => {
  const withAmount = (unrealizedAmount: string, unrealizedDirection: "up" | "down") => ({
    ...EMPTY_DISPOSAL,
    unrealizedAmount,
    unrealizedDirection,
  });

  it("ตีราคาขึ้นได้ค่าบวก · ตีราคาลงได้ค่าลบ", () => {
    expect(signedUnrealized(withAmount("300000", "up"))).toBe(300000);
    expect(signedUnrealized(withAmount("300000", "down"))).toBe(-300000);
  });

  it("วางค่าติดลบมาแล้วเลือก 'ตีราคาขึ้น' ต้องได้บวก ไม่ใช่ลบซ้อนลบ", () => {
    expect(signedUnrealized(withAmount("(300,000)", "up"))).toBe(300000);
    expect(signedUnrealized(withAmount("-300000", "up"))).toBe(300000);
    expect(signedUnrealized(withAmount("(300,000)", "down"))).toBe(-300000);
  });

  it("ยังไม่กรอกถือเป็นศูนย์ ไม่ใช่ error", () => {
    expect(signedUnrealized(EMPTY_DISPOSAL)).toBe(0);
  });
});
