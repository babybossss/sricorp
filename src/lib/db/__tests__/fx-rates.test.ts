import { describe, expect, it } from "vitest";
import { FX_RATE_CURRENCIES, humanizeFxRateError, validateFxRate, type FxRateInput } from "../fx-rates";

const TODAY = "2026-10-25";
const good: FxRateInput = { currency: "USD", rateDate: "24/10/2026", rate: "36.50", note: "Google Finance 24/10/2026" };
const bad = (over: Partial<FxRateInput>) => validateFxRate({ ...good, ...over }, TODAY);

describe("validateFxRate · อัตราที่ผู้ดูแลป้อนมือ", () => {
  it("ข้อมูลครบ → แปลงเป็นแถวของ fx_rates (วันที่ ISO · ตัวเลข · สกุลตัวพิมพ์ใหญ่ · note ตัดช่องว่าง)", () => {
    const r = validateFxRate({ currency: " usd ", rateDate: "24/10/2026", rate: "1,036.50", note: "  Google  " }, TODAY);
    expect(r).toMatchObject({ ok: true, row: { currency: "USD", rate_date: "2026-10-24", thb_per_unit: 1036.5, note: "Google" } });
  });

  it("วันนี้ผ่าน · พรุ่งนี้ไม่ผ่าน (อัตราอนาคตใช้ไม่ได้)", () => {
    expect(bad({ rateDate: "25/10/2026" }).ok).toBe(true);
    const r = bad({ rateDate: "26/10/2026" });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.errors.rateDate).toMatch(/อนาคต/);
  });

  it("อัตราศูนย์ / ติดลบ / ว่าง / ไม่ใช่ตัวเลข → ปฏิเสธ (รวมติดลบแบบวงเล็บและเครื่องหมายลบยูนิโคด)", () => {
    for (const rate of ["0", "0.00", "-36.5", "(36.5)", "−36.5", "", "  ", "abc", "36.5.1", "1.000,50"]) {
      const r = bad({ rate });
      expect(r.ok, `rate=${JSON.stringify(rate)}`).toBe(false);
      if (!r.ok) expect(r.errors.rate).toBeTruthy();
    }
  });

  it("ทศนิยมเกิน 8 ตำแหน่ง → ปฏิเสธ (ไม่ปัดเงียบๆ) · 8 ตำแหน่งพอดีผ่าน", () => {
    expect(bad({ rate: "0.123456789" }).ok).toBe(false);
    expect(bad({ rate: "0.12345678" }).ok).toBe(true);
  });

  it("อัตราสูงผิดปกติ (น่าจะกลับทิศ) → ปฏิเสธ", () => {
    expect(bad({ rate: "1000000" }).ok).toBe(false);
    expect(bad({ rate: "999999.99" }).ok).toBe(true);
  });

  it("บาท / สกุลที่ไม่รู้จัก / ไม่เลือก → ปฏิเสธ · สกุลที่รับ = USD JPY CNY", () => {
    expect(FX_RATE_CURRENCIES).toEqual(["USD", "JPY", "CNY"]);
    for (const currency of ["THB", "EUR", "", "  "]) expect(bad({ currency }).ok, currency).toBe(false);
    for (const currency of ["USD", "JPY", "CNY"]) expect(bad({ currency }).ok, currency).toBe(true);
  });

  it("วันที่ไม่จริง / ปี พ.ศ. / ว่าง → ปฏิเสธ ไม่แปลงให้เอง", () => {
    for (const rateDate of ["31/02/2026", "24/10/2569", "2026", "", "ไม่รู้"]) expect(bad({ rateDate }).ok, rateDate).toBe(false);
  });

  it("ไม่ระบุที่มา / ที่มายาวเกิน 200 → ปฏิเสธ", () => {
    expect(bad({ note: "" }).ok).toBe(false);
    expect(bad({ note: "   " }).ok).toBe(false);
    expect(bad({ note: "ก".repeat(201) }).ok).toBe(false);
    expect(bad({ note: "ก".repeat(200) }).ok).toBe(true);
  });

  it("ผิดหลายช่อง → บอกทุกช่องพร้อมกัน (ไม่ให้แก้ทีละรอบ)", () => {
    const r = validateFxRate({ currency: "THB", rateDate: "99/99/2026", rate: "-1", note: "" }, TODAY);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(Object.keys(r.errors).sort()).toEqual(["currency", "note", "rate", "rateDate"]);
  });
});

describe("humanizeFxRateError", () => {
  it("แยกสิทธิ์ / ซ้ำ / ถูกอ้างถึง ออกเป็นข้อความที่ต่างกันและไม่พูดถึงการลงสมุด", () => {
    const perm = humanizeFxRateError({ code: "42501", message: "new row violates row-level security policy" }, "add");
    const dup = humanizeFxRateError({ code: "23505", message: "duplicate key" }, "add");
    const ref = humanizeFxRateError({ code: "23503", message: "violates foreign key" }, "delete");
    expect(perm).toMatch(/ไม่มีสิทธิ์จัดการอัตราแลกเปลี่ยน/);
    expect(dup).toMatch(/ไม่เขียนทับ/);
    expect(ref).toMatch(/ลบอัตรานี้ไม่ได้/);
    expect(new Set([perm, dup, ref]).size).toBe(3);
  });
});
