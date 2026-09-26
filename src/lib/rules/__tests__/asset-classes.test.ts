import { describe, it, expect } from "vitest";
import { COA, coa } from "../coa";
import {
  ASSET_CLASSES,
  UNCLASSIFIED_ASSET_COA,
  allCategories,
  classOfCoa,
  findAssetClassGaps,
} from "../asset-classes";

/**
 * หมวดใหญ่ของทรัพย์เป็นคนละแกนกับผังบัญชี แต่ต้องกระทบยอดกันได้
 * บัญชีสินทรัพย์ที่หลุดทั้งสองทาง = ยอดหายจากมุมมองประเภทการลงทุน ทั้งที่งบดุลยังลงตัว
 */
describe("หมวดใหญ่ของทรัพย์", () => {
  it("มี 4 หมวดตามที่ลูกพี่กำหนด", () => {
    expect(ASSET_CLASSES.map((c) => c.name)).toEqual([
      "Businesses",
      "Real Estate",
      "Paper Asset",
      "Commodity & Cash",
    ]);
  });

  it("ทุกบัญชีสินทรัพย์ถูกจัดหมวด หรือระบุไว้ว่าไม่ใช่ประเภทการลงทุน", () => {
    const { missing, duplicated, unknown, bothWays } = findAssetClassGaps();
    expect(missing, "บัญชีสินทรัพย์ที่ยังไม่ได้จัดหมวด").toEqual([]);
    expect(duplicated, "บัญชีที่อยู่สองหมวด").toEqual([]);
    expect(unknown, "หมวดอ้างรหัสที่ไม่มีในผังบัญชี").toEqual([]);
    expect(bothWays, "บัญชีที่ทั้งจัดหมวดและบอกว่าไม่จัดหมวด").toEqual([]);
  });

  it("รหัสหมวดย่อยไม่ซ้ำกัน", () => {
    const codes = allCategories().map((c) => c.code);
    expect(new Set(codes).size).toBe(codes.length);
  });

  it("บัญชีที่จัดหมวดต้องเป็นประเภทสินทรัพย์เท่านั้น", () => {
    // หนี้สินหรือรายได้ไปโผล่ในหมวดทรัพย์ = NAV บวมหรือติดลบแบบไม่มีเหตุผล
    for (const cat of allCategories()) {
      for (const code of cat.coaCodes) {
        expect(coa(code).type, `${cat.code} → ${code}`).toBe("asset");
      }
    }
  });

  it("สัญญาขายฝาก/จำนอง อยู่ใน Real Estate ตามที่ลูกพี่กำหนด", () => {
    // ทางบัญชีเป็นลูกหนี้ (1400/1410) แต่ความเสี่ยงอิงอสังหาฯ
    expect(classOfCoa("1400")?.name).toBe("Real Estate");
    expect(classOfCoa("1410")?.name).toBe("Real Estate");
    const srr = allCategories().find((c) => c.code === "RE_SRR")!;
    expect(srr.coaCodes).toEqual(["1400", "1410"]);
  });

  it("เงินสดอยู่ใน Commodity & Cash · ทองคำแยกจากหลักทรัพย์", () => {
    expect(classOfCoa("1100")?.name).toBe("Commodity & Cash");
    expect(classOfCoa("1720")?.name).toBe("Commodity & Cash");
    // ถ้าทองคำใช้บัญชีเดียวกับหุ้น จะแยก Commodity ออกจาก Paper Asset ไม่ได้
    expect(classOfCoa("1700")?.name).toBe("Paper Asset");
  });

  it("ลูกหนี้ดำเนินงานและรายการระหว่างกันไม่ถูกนับเป็นการลงทุน", () => {
    for (const code of Object.keys(UNCLASSIFIED_ASSET_COA)) {
      expect(classOfCoa(code), code).toBeNull();
      expect(coa(code).type).toBe("asset");
    }
  });

  it("ทุกหมวดใหญ่มีหมวดย่อยอย่างน้อยหนึ่งอัน และลำดับไม่ซ้ำ", () => {
    for (const c of ASSET_CLASSES) expect(c.categories.length, c.name).toBeGreaterThan(0);
    const orders = ASSET_CLASSES.map((c) => c.sortOrder);
    expect(new Set(orders).size).toBe(orders.length);
  });

  it("จำนวนบัญชีสินทรัพย์ = ที่จัดหมวด + ที่ระบุว่าไม่จัดหมวด", () => {
    const assets = COA.filter((a) => a.type === "asset");
    const mapped = allCategories().flatMap((c) => c.coaCodes);
    expect(mapped.length + Object.keys(UNCLASSIFIED_ASSET_COA).length).toBe(assets.length);
  });
});
