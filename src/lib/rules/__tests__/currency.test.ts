import { describe, it, expect } from "vitest";
import {
  BASE_CURRENCY,
  CURRENCIES,
  FX_RATE_SOURCES,
  fxCheck,
  isCurrency,
  toThb,
} from "../currency";

/**
 * ขอบเขตสกุลเงินที่ลูกพี่ยืนยัน (D-111 ข้อ 2) — THB เป็นค่าตั้งต้น · USD · JPY · CNY
 *
 * เขียนจำนวนและรายชื่อตรงๆ โดยตั้งใจ: การเพิ่มสกุลเงินต้องเป็นการตัดสินใจที่เห็นใน diff
 * ไม่ใช่ของที่ไหลเข้ามาเพราะมีคนเติม array (ทุกสกุลที่เพิ่มต้องมีอัตราป้อนเข้ามาทุกเดือน
 * ไม่งั้นการตีราคาสิ้นเดือนของทรัพย์สกุลนั้นจะทำไม่ได้ และยอดจะค้างที่อัตราเก่าเงียบๆ)
 */
describe("สกุลเงินที่อนุญาต", () => {
  it("มีสี่สกุลเท่านั้น และบาทเป็นสกุลตั้งต้น", () => {
    expect([...CURRENCIES]).toEqual(["THB", "USD", "JPY", "CNY"]);
    expect(BASE_CURRENCY).toBe("THB");
    expect(CURRENCIES).toContain(BASE_CURRENCY);
  });

  it("ปฏิเสธสกุลที่ไม่อยู่ในรายการ และปฏิเสธค่าว่าง", () => {
    expect(isCurrency("USD")).toBe(true);
    expect(isCurrency("EUR")).toBe(false);
    // ตัวพิมพ์เล็กไม่ผ่าน — ถ้ายอมให้ผ่าน คอลัมน์ใน DB จะมีสองรูปของสกุลเดียวกัน
    // แล้วการ join กับตารางอัตราแลกเปลี่ยนจะไม่เจอแถว แล้วตีราคาไม่ได้
    expect(isCurrency("usd")).toBe(false);
    expect(isCurrency("")).toBe(false);
    expect(isCurrency(undefined)).toBe(false);
  });

  it("แหล่งอัตราแยกคนใส่ออกจากระบบดึง", () => {
    // D-111: ตัวดึงจาก ธปท. เป็นงานแยก · ต้องแยกออกได้ทีหลังว่าแถวไหนมาจากใคร
    expect([...FX_RATE_SOURCES]).toEqual(["manual", "bot_api"]);
  });
});

/**
 * เคส "ข้อมูลขาด" ของฝั่งอัตราแลกเปลี่ยน — ต้อง **ปฏิเสธ ไม่ใช่เดา**
 * เดาอัตราผิดหนึ่งตัวแปลว่ามูลค่าทรัพย์ในงบดุลผิดทั้งก้อน โดยไม่มีอะไรฟ้อง
 */
describe("fxCheck — ข้อมูลไม่ครบต้องปฏิเสธ", () => {
  const ok = { currency: "USD", thbPerUnit: 36.5, rateDate: "2026-10-31", source: "manual" };

  it("ครบถ้วนแล้วผ่าน", () => {
    const r = fxCheck(ok);
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.rate.thbPerUnit).toBe(36.5);
  });

  it("ไม่ส่งสกุลเงิน → ปฏิเสธ", () => {
    const r = fxCheck({ ...ok, currency: undefined });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.why).toMatch(/สกุลเงิน/);
  });

  it("ไม่ส่งอัตรา → ปฏิเสธ (ไม่ใช่ถือว่า 1)", () => {
    const r = fxCheck({ ...ok, thbPerUnit: undefined });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.why).toMatch(/อัตรา/);
  });

  it("อัตราเป็นศูนย์ ติดลบ หรือไม่ใช่ตัวเลข → ปฏิเสธ", () => {
    for (const bad of [0, -1, Number.NaN, Number.POSITIVE_INFINITY]) {
      const r = fxCheck({ ...ok, thbPerUnit: bad });
      expect(r.ok, `อัตรา ${bad}`).toBe(false);
    }
  });

  it("บาทต้องมีอัตรา 1 เท่านั้น", () => {
    expect(fxCheck({ ...ok, currency: "THB", thbPerUnit: 1 }).ok).toBe(true);
    // อัตราของบาทที่ไม่ใช่ 1 = ยอดบาทจะถูกแปลงสองรอบ
    const r = fxCheck({ ...ok, currency: "THB", thbPerUnit: 36.5 });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.why).toMatch(/บาท/);
  });

  it("ไม่ส่งวันที่ของอัตรา หรือวันที่ไม่มีจริง → ปฏิเสธ", () => {
    expect(fxCheck({ ...ok, rateDate: undefined }).ok).toBe(false);
    expect(fxCheck({ ...ok, rateDate: "2026-02-30" }).ok).toBe(false);
  });

  it("ไม่ส่งแหล่งที่มา หรือแหล่งที่ไม่รู้จัก → ปฏิเสธ", () => {
    const r = fxCheck({ ...ok, source: undefined });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.why).toMatch(/แหล่ง/);
    expect(fxCheck({ ...ok, source: "ลูกพี่บอกมา" }).ok).toBe(false);
  });
});

describe("toThb — ปัดสองตำแหน่งที่เดียว", () => {
  it("แปลงแล้วปัดเป็นสตางค์", () => {
    expect(toThb(1000, 36.5)).toBe(36500);
    expect(toThb(3, 0.2345)).toBe(0.7);
  });

  it("ค่าที่คำนวณต่อไม่ได้ต้องโยน ไม่ใช่คืน NaN", () => {
    expect(() => toThb(Number.NaN, 1)).toThrow();
    expect(() => toThb(1, Number.NaN)).toThrow();
  });
});
