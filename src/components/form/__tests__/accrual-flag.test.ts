import { describe, expect, it } from "vitest";
import { accrualFlagFor, subCodeForType } from "../use-tx-form";
import { TX_TYPES, allowedSubs, canAccrueFromForm, findSub } from "@/lib/rules/tx-rules";

/**
 * ด่านของธง "ยังไม่ได้รับ/จ่ายเงิน" (`notYetPaid`)
 *
 * ธงนี้ตัดสินว่ารายการลง **ลูกหนี้/เจ้าหนี้** หรือ **เงินสด** ถ้าพลาดเป็น "จ่ายแล้ว"
 * ระบบจะสร้างขาเงินสดที่ผู้ใช้ไม่เคยยืนยัน = เงินลอยและงบกระแสเงินสดเกินจริง
 *
 * ค่าตั้งต้นคือ `true` (ยังไม่ได้รับ-จ่าย) **โดยตั้งใจ** ไม่ใช่ความสะดวก:
 * ระบบต้องไม่อ้างว่าเงินเคลื่อนจนมีคนยืนยัน
 *
 * ผู้ตรวจชี้ว่าเส้นทางที่อันตรายที่สุดของการเลิกเลือกหมวดย่อยให้เอง
 * (`subCode` เป็นค่าว่างชั่วคราว) เคยพิงเหตุผลล้วนโดยไม่มีเทสต์แม้แต่ตัวเดียว
 */
describe("accrualFlagFor", () => {
  const accruableSubs = TX_TYPES.flatMap((t) => allowedSubs(t.key)).filter((s) => canAccrueFromForm(s));
  const plainSubs = TX_TYPES.flatMap((t) => allowedSubs(t.key)).filter((s) => !canAccrueFromForm(s));

  it("มีหมวดทั้งสองแบบให้ตรวจจริง (กันเทสต์ที่วนชุดว่างแล้วผ่าน)", () => {
    expect(accruableSubs.length).toBeGreaterThan(0);
    expect(plainSubs.length).toBeGreaterThan(0);
  });

  it("หมวดที่ตั้งค้างไม่ได้ → บังคับเป็น false ไม่ว่าค่าเดิมเป็นอะไร", () => {
    for (const s of plainSubs) {
      expect(accrualFlagFor(s.code, "", true)).toBe(false);
      expect(accrualFlagFor(s.code, "", false)).toBe(false);
    }
  });

  /**
   * เส้นทางที่ผู้ตรวจเป็นห่วง: เปลี่ยนประเภท → `subCode` ว่าง → เลือกหมวดใหม่
   * ตอนนั้น `prevSub` คือค่าว่าง ต้องได้ค่าตั้งต้น `true` ไม่ใช่ `false`
   */
  it("มาจาก subCode ว่าง (เพิ่งเปลี่ยนประเภท) → ได้ค่าตั้งต้น ยังไม่ได้รับ-จ่าย", () => {
    for (const s of accruableSubs) {
      expect(accrualFlagFor(s.code, "", false)).toBe(true);
      expect(accrualFlagFor(s.code, "", true)).toBe(true);
    }
  });

  it("ย้ายระหว่างหมวดที่ตั้งค้างได้ทั้งคู่ → คงค่าที่ผู้ใช้ติ๊กไว้", () => {
    const [a, b] = accruableSubs;
    expect(accrualFlagFor(b.code, a.code, false)).toBe(false);
    expect(accrualFlagFor(b.code, a.code, true)).toBe(true);
  });

  it("แวะหมวดที่ตั้งค้างไม่ได้แล้วกลับมา → คืนค่าตั้งต้น ไม่ใช่ false ที่ถูกบังคับทิ้งไว้", () => {
    const accruable = accruableSubs[0];
    const plain = plainSubs[0];
    const afterPlain = accrualFlagFor(plain.code, accruable.code, true);
    expect(afterPlain).toBe(false);
    // กลับมาหมวดที่ตั้งค้างได้ ต้องไม่สืบทอด false ที่ถูกบังคับ
    expect(accrualFlagFor(accruable.code, plain.code, afterPlain)).toBe(true);
  });

  it("รหัสที่ไม่มีในตารางกฎ → false (ไม่มีหมวด = ตั้งค้างไม่ได้)", () => {
    expect(findSub("ไม่มีรหัสนี้")).toBeUndefined();
    expect(accrualFlagFor("ไม่มีรหัสนี้", "", true)).toBe(false);
  });
});

/**
 * ด่านกันคนเอา `subs[0]` กลับใส่ใน hook
 *
 * ผู้ตรวจชี้ช่องว่าง: เทสต์ของ `subCodeForType()` ไม่ได้ยืนยันว่า `pickType` เรียกใช้มันจริง
 * ถ้ามีคนเขียนการเลือกให้เองกลับเข้าไปใน hook ตรงๆ เทสต์ชุดนั้นยังเขียวอยู่
 */
describe("pickType ต้องใช้ subCodeForType เท่านั้น", () => {
  it("ไม่มีการหยิบ allowedSubs(...)[0] มาใส่ subCode ใน hook", async () => {
    const { readFileSync } = await import("node:fs");
    const path = await import("node:path");
    const src = readFileSync(path.join(__dirname, "..", "use-tx-form.ts"), "utf8")
      .replace(/\/\*[\s\S]*?\*\//g, "")
      .replace(/\/\/.*$/gm, "");
    expect(src).toMatch(/subCode = subCodeForType\(typeKey, d\.subCode\)/);
    // ห้ามมี subs[0] / allowedSubs(...)[0] โผล่กลับมาเป็นค่าของ subCode
    expect(src).not.toMatch(/subs\[0\]/);
    expect(src).not.toMatch(/allowedSubs\([^)]*\)\[0\]/);
  });

  it("subCodeForType ยังเป็นตัวที่คืนค่าว่าง ไม่ใช่หมวดแรก", () => {
    for (const t of TX_TYPES) expect(subCodeForType(t.key, "")).toBe("");
  });
});
