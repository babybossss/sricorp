import { describe, expect, it } from "vitest";
import { disposalFor, isCostBasisMode, type DisposalContext } from "../disposal-context";

const ctx = (over: Partial<DisposalContext> = {}): DisposalContext => ({
  assetId: "a1",
  mode: "whole_item",
  costBasis: 3_500_000,
  renovation: 500_000,
  priorSurplus: 0,
  ...over,
});

describe("disposalFor · ประกอบ disposal ของ engine จากสมุด (ผู้ใช้กรอกแค่ราคาขายกับค่าใช้จ่าย)", () => {
  it("คอนโด 3,000,000 + รีโนเวท 500,000 ขาย 4,000,000 → ต้นทุนที่ตัด 3,500,000 · รีโนเวท 500,000 · ทั้งก้อน (assetCostBefore = ต้นทุน)", () => {
    const r = disposalFor(ctx(), { salePrice: 4_000_000 });
    expect(r).toEqual({
      ok: true,
      disposal: { costBasis: 3_500_000, salePrice: 4_000_000, sellingCosts: 0, renovationBasis: 500_000, assetCostBefore: 3_500_000, priorSurplus: 0 },
    });
  });

  it("ส่วนเกินทุนที่ค้างอยู่ (บวก/ลบ) ไปกับ priorSurplus ตามที่อ่านจากสมุด", () => {
    for (const s of [460_000, -270_000]) {
      const r = disposalFor(ctx({ costBasis: 1_000_000, renovation: 0, priorSurplus: s }), { salePrice: 1_500_000, sellingCosts: 50_000 });
      expect(r.ok && r.disposal).toMatchObject({ costBasis: 1_000_000, sellingCosts: 50_000, priorSurplus: s, assetCostBefore: 1_000_000 });
    }
  });

  it("ไม่มีข้อมูลต้นทุน (ctx = null) → ปฏิเสธ ไม่เดา", () => {
    const r = disposalFor(null, { salePrice: 1 });
    expect(r.ok).toBe(false);
  });

  it("ราคาขายไม่ส่ง / 0 / ติดลบ / ไม่ใช่ตัวเลข → ปฏิเสธ", () => {
    for (const sp of [undefined, 0, -1, Number.NaN, Number.POSITIVE_INFINITY]) {
      const r = disposalFor(ctx(), { salePrice: sp as number });
      expect(r.ok, String(sp)).toBe(false);
    }
  });

  it("ค่าใช้จ่ายในการขายติดลบ → ปฏิเสธ · ไม่ส่ง = 0", () => {
    expect(disposalFor(ctx(), { salePrice: 10, sellingCosts: -1 }).ok).toBe(false);
    const r = disposalFor(ctx(), { salePrice: 10 });
    expect(r.ok && r.disposal.sellingCosts).toBe(0);
  });

  it("ทรัพย์ที่ถัวเฉลี่ยได้ / ขายรายล็อต → ปฏิเสธพร้อมเหตุผลว่าต้องตัดล็อตพร้อมใบขาย (ทั้งที่ข้อมูลอื่นครบ)", () => {
    for (const mode of ["average", "specific_lot"] as const) {
      const r = disposalFor(ctx({ mode }), { salePrice: 4_000_000 });
      expect(r.ok).toBe(false);
      if (!r.ok) expect(r.message).toMatch(/ตัดล็อต/);
    }
  });

  it("ต้นทุนในสมุดเป็น 0 / รีโนเวทมากกว่าต้นทุน / รีโนเวทติดลบ → ปฏิเสธ", () => {
    expect(disposalFor(ctx({ costBasis: 0, renovation: 0 }), { salePrice: 1 }).ok).toBe(false);
    expect(disposalFor(ctx({ renovation: 3_500_001 }), { salePrice: 1 }).ok).toBe(false);
    expect(disposalFor(ctx({ renovation: -1 }), { salePrice: 1 }).ok).toBe(false);
  });

  it("ค่าที่ DB ตอบมาแปลกๆ ไม่ใช่โหมดที่รู้จัก → isCostBasisMode ปฏิเสธ (ไม่ตกเป็นค่าตั้งต้น)", () => {
    expect(isCostBasisMode("whole_item")).toBe(true);
    for (const v of ["", "AVERAGE", "fifo", null, undefined, 1]) expect(isCostBasisMode(v)).toBe(false);
  });
});
