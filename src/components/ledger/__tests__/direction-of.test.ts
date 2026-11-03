import { describe, it, expect } from "vitest";
import { TX_TYPES, type CashDirection } from "@/lib/rules/tx-rules";
import { directionOf } from "../confirm-flow";

/**
 * ข้อ 5 ของผู้ตรวจ · `directionOf` ยัง **ยุบ `both` กับ `none` เป็น `null`**
 * — ternary ที่เหลืออยู่ที่เดียวหลัง D-102
 *
 * วันนี้ยังไม่ถึงเพราะ `accrualCheck` ตัดหมวด `none` ออกก่อนจะมาถึงแถวยืนยันรับ-จ่าย
 * **แต่พึ่งลำดับการตรวจไม่ได้**: วันที่ลำดับเปลี่ยน (หรือมีคนเรียกฟังก์ชันนี้
 * จากหน้าอื่น) "ไม่มีเงินเคลื่อน" จะกลายเป็นคำตอบเดียวกับ "ไม่รู้จักหมวด"
 * แล้วหน้าจอจะแสดงยอดและป้ายบัญชีของกรณีที่ไม่ใช่
 *
 * `null` ต้องสงวนไว้สำหรับ **หมวดที่ไม่มีในตารางกฎ** เท่านั้น (D-102 บทเรียน:
 * union type กันของตกหล่นได้เฉพาะที่ map ครบเคส · ternary + fallback รับค่าใหม่เงียบๆ)
 */

const allSubs = TX_TYPES.flatMap((t) => t.subs);

describe("directionOf ตอบครบทุกค่าของ CashDirection ไม่ยุบเป็น null", () => {
  it("ทุกหมวดในตารางกฎได้คำตอบตรงกับ `cash` ของตัวเอง — ไม่มีหมวดไหนได้ null", () => {
    expect(allSubs.length).toBeGreaterThan(0);
    for (const s of allSubs) {
      expect(directionOf({ subCode: s.code }), `${s.code} (cash: ${s.cash})`).toBe(s.cash);
    }
  });

  it("ครอบทั้งสี่ค่าจริง ไม่ใช่เผอิญมีแต่ in/out ให้ทดสอบ", () => {
    const seen = new Set(allSubs.map((s) => s.cash));
    for (const d of ["in", "out", "both", "none"] as CashDirection[]) {
      expect(seen, `ตารางกฎไม่มีหมวดที่ cash = ${d} ให้ทดสอบ`).toContain(d);
    }
  });

  it("`none` กับ `both` ต้องเป็นคำตอบคนละตัว และทั้งคู่ไม่ใช่ null", () => {
    // เคสของ mutation P6 ตรงๆ: คืน ternary ที่ยุบ none/both เป็น null แล้วต้องแดงที่นี่
    const none = directionOf({ subCode: "adj.doubtful" });
    const both = directionOf({ subCode: "trf.internal" });
    expect(none).toBe("none");
    expect(both).toBe("both");
    expect(none).not.toBe(both);
    expect(none).not.toBeNull();
    expect(both).not.toBeNull();
  });

  it("รับ-จ่ายยังตอบเหมือนเดิม (ไม่ได้แก้จนของที่ใช้งานอยู่เปลี่ยนความหมาย)", () => {
    expect(directionOf({ subCode: "inc.rent" })).toBe("in");
    expect(directionOf({ subCode: "exp.common" })).toBe("out");
  });

  it("null สงวนไว้สำหรับหมวดที่ไม่มีในตารางกฎเท่านั้น", () => {
    expect(directionOf({ subCode: "ghost" })).toBeNull();
    expect(directionOf({ subCode: "" })).toBeNull();
    expect(directionOf({ subCode: undefined as unknown as string })).toBeNull();
  });
});
