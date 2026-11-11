import { describe, expect, it } from "vitest";
import { subCodeForType } from "../use-tx-form";
import { TX_TYPES, allowedSubs, isValidPair } from "@/lib/rules/tx-rules";

/**
 * ด่านกัน "ระบบเลือกหมวดย่อยให้เอง"
 *
 * หมวดย่อยคือสิ่งที่ตัดสินคู่บัญชี (ดู tx-rules) ถ้าระบบเลือกให้เอง
 * ผู้ใช้ที่ไม่ได้มองช่องนั้นจะได้คู่บัญชีที่ระบบเดาให้ แล้วตัวเลขผิดเงียบๆ
 *
 * ของเดิมหยิบ `allowedSubs(typeKey)[0]` ซึ่งวัดแล้วว่า **ทุกประเภทยกเว้นยอดยกมา**
 * ตัวแรกเป็นหมวดที่มีเงื่อนไขพิเศษทั้งนั้น ทำให้ตอนระบบยังไม่มีทรัพย์
 * ฟอร์มกดบันทึกไม่ได้โดยไม่บอกสาเหตุที่แท้จริง
 */
describe("subCodeForType", () => {
  it.each(TX_TYPES.map((t) => [t.key, t.label] as const))(
    "เลือกประเภท %s (%s) จากฟอร์มเปล่า → หมวดย่อยยังว่าง ไม่ถูกเลือกให้",
    (key) => {
      expect(subCodeForType(key, "")).toBe("");
    }
  );

  it.each(TX_TYPES.map((t) => [t.key, t.label] as const))(
    "%s (%s) ไม่คืนหมวดตัวแรกของประเภท",
    (key) => {
      expect(subCodeForType(key, "")).not.toBe(allowedSubs(key)[0].code);
    }
  );

  it("หมวดเดิมใช้กับประเภทใหม่ได้ → คงไว้ ไม่ล้างทิ้ง", () => {
    for (const t of TX_TYPES) {
      const sub = allowedSubs(t.key)[0].code;
      expect(subCodeForType(t.key, sub)).toBe(sub);
    }
  });

  it("หมวดเดิมใช้กับประเภทใหม่ไม่ได้ → ล้างเป็นค่าว่าง ไม่ค้างข้ามประเภท", () => {
    // หาคู่ (ประเภท, หมวดของประเภทอื่น) จริงจากตารางกฎ ไม่สมมติรหัสขึ้นมาเอง
    let checked = 0;
    for (const t of TX_TYPES) {
      for (const other of TX_TYPES) {
        if (other.key === t.key) continue;
        const foreign = allowedSubs(other.key).find((s) => !isValidPair(t.key, s.code));
        if (!foreign) continue;
        expect(subCodeForType(t.key, foreign.code)).toBe("");
        checked++;
        break;
      }
    }
    // ถ้าไม่เจอคู่ไหนเลย เทสต์นี้จะผ่านโดยไม่ได้ตรวจอะไร — กันไว้
    expect(checked).toBe(TX_TYPES.length);
  });

  it("รหัสที่ไม่มีในตารางกฎ → ล้างเป็นค่าว่าง ไม่ส่งต่อค่าที่ใช้ไม่ได้", () => {
    expect(subCodeForType("expense", "ไม่มีรหัสนี้")).toBe("");
  });
});
