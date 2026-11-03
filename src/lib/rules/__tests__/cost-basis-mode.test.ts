/**
 * **ใครเฉลี่ยต้นทุนได้ ใครห้าม** — ลูกพี่สั่งเอง 25/10 (ย้ำสองรอบ)
 *
 * > "ห้ามเฉลี่ยต้นทุนในทุกทรัพย์สิน อสังหา และ อื่นๆ **มีเฉพาะหุ้น หรือ คริปโต
 * >  เท่านั้นที่เฉลี่ยในตลาดเท่านั้น หุ้นบริษัทนอกตลาดไม่เกี่ยว**"
 * > ยืนยันเพิ่ม: **ทองคำเฉลี่ยได้**
 *
 * ไฟล์นี้ล็อกสามอย่าง
 *   1. รายชื่อหมวดที่เฉลี่ยได้ = **หุ้นในตลาด · คริปโต · ทองคำ** เท่านั้น
 *   2. ค่าตั้งต้นของ "ไม่รู้" = `whole_item` (เข้มที่สุด) ไม่ใช่ `average`
 *   3. **ค่าในโค้ดกับค่าใน migration ตรงกันตัวต่อตัว** — อ่านไฟล์ migration
 *      มาเทียบจริง ไม่ใช่เขียนรายชื่อซ้ำสองที่แล้วหวังว่าจะตรงกัน
 *      (กฎ CLAUDE.md: ของใน DB เป็นสำเนาของตารางกฎ · ห้ามเขียนกฎสองที่)
 */

import { describe, it, expect } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import {
  ASSET_CLASSES,
  allCategories,
  averagingCategoryCodes,
  canAverageCategory,
  categoryCodesByCostBasis,
  costBasisModeOfCategory,
  type CostBasisMode,
} from "../asset-classes";

/** รายชื่อที่ลูกพี่อนุญาต — เขียนตรงๆ ที่นี่ที่เดียวเพื่อเป็นหลักยึดของเทสต์ */
const BOSS_ALLOWS_AVERAGING = ["COM_CRYPTO", "COM_GOLD", "PAPER_STOCK_LISTED"];

const MIGRATION_DIR = join(process.cwd(), "supabase", "migrations");

function costBasisMigration(): string {
  const names = readdirSync(MIGRATION_DIR).filter((n) => n.includes("asset_cost_basis_mode"));
  // อ่านไม่ออก = พัง ไม่ยอมผ่านด้วยชุดว่าง (กฎเดียวกับ check:rules-sync)
  expect(names, "ไม่พบ migration ของเส้นแบ่งวิธีคิดต้นทุน — เทสต์นี้จะไม่ได้ตรวจอะไร").toHaveLength(1);
  return readFileSync(join(MIGRATION_DIR, names[0]), "utf8");
}

/** ดึงรายชื่อหมวดที่ migration ตั้งเป็นโหมดหนึ่งๆ ออกมาจาก SQL จริง */
function codesSetTo(mode: CostBasisMode): string[] {
  const sql = costBasisMigration();
  const re = new RegExp(
    String.raw`set\s+cost_basis_mode\s*=\s*'${mode}'\s*\n\s*where\s+code\s+in\s*\(([^)]*)\)`,
    "g",
  );
  const out = new Set<string>();
  let m: RegExpExecArray | null;
  while ((m = re.exec(sql)) !== null) {
    for (const raw of m[1].split(",")) {
      const code = raw.replace(/--.*$/gm, "").trim().replace(/^'|'$/g, "");
      if (code) out.add(code);
    }
  }
  return [...out].sort();
}

describe("วิธีคิดต้นทุน — เฉลี่ยได้สามอย่างเท่านั้น", () => {
  it("หมวดที่เฉลี่ยได้ = หุ้นในตลาด · คริปโต · ทองคำ (ไม่ขาดไม่เกิน)", () => {
    expect(averagingCategoryCodes()).toEqual(BOSS_ALLOWS_AVERAGING);
  });

  it("**หุ้นบริษัทนอกตลาดห้ามเฉลี่ย** และอยู่รหัสบัญชีเดียวกับหุ้นในตลาด", () => {
    expect(canAverageCategory("PAPER_STOCK_PRIVATE")).toBe(false);
    expect(canAverageCategory("PAPER_STOCK_LISTED")).toBe(true);
    // ทั้งคู่เป็นหุ้นใน Paper Asset — ถ้าแยกด้วยรหัสบัญชีจะแยกไม่ออก
    const listed = allCategories().find((c) => c.code === "PAPER_STOCK_LISTED")!;
    const priv = allCategories().find((c) => c.code === "PAPER_STOCK_PRIVATE")!;
    expect(listed.className).toBe("Paper Asset");
    expect(priv.className).toBe(listed.className);
  });

  it("**ทองคำเฉลี่ยได้ · สินทรัพย์ทางเลือกอื่นห้าม** ทั้งที่อยู่รหัส 1720 เดียวกัน", () => {
    expect(canAverageCategory("COM_GOLD")).toBe(true);
    expect(canAverageCategory("COM_ALT")).toBe(false);
    const gold = allCategories().find((c) => c.code === "COM_GOLD")!;
    const alt = allCategories().find((c) => c.code === "COM_ALT")!;
    expect(gold.coaCodes).toContain("1720");
    expect(gold.className).toBe(alt.className);
    // COM_ALT ต้องไม่ผูกรหัสบัญชีซ้ำกับทอง (ไม่งั้นรายงานจะนับซ้ำ)
    expect(alt.coaCodes).toEqual([]);
  });

  it("อสังหาริมทรัพย์ทุกหมวดเป็นทรัพย์ชิ้นเดียว — คอนโดคนละห้องก็แยก", () => {
    const re = allCategories().filter((c) => c.className === "Real Estate");
    expect(re.length).toBeGreaterThan(0);
    for (const c of re) expect(c.costBasisMode, c.code).toBe("whole_item");
  });

  it("ทุกหมวดต้องระบุโหมด และโหมดต้องเป็นหนึ่งในสามค่า", () => {
    const allowed: CostBasisMode[] = ["average", "specific_lot", "whole_item"];
    for (const c of allCategories()) {
      expect(allowed, `${c.code} = ${c.costBasisMode}`).toContain(c.costBasisMode);
    }
    // ผลรวมของสามโหมด = จำนวนหมวดทั้งหมด (ไม่มีหมวดไหนหลุด)
    const counted = allowed.reduce((n, m) => n + categoryCodesByCostBasis(m).length, 0);
    expect(counted).toBe(allCategories().length);
  });

  it("ไม่รู้จักหมวด / ไม่ส่งหมวด → whole_item (เผลอแล้วได้ 'ห้ามเฉลี่ย')", () => {
    expect(costBasisModeOfCategory("ZZ_NOT_A_CATEGORY")).toBe("whole_item");
    expect(costBasisModeOfCategory("")).toBe("whole_item");
    expect(costBasisModeOfCategory("   ")).toBe("whole_item");
    expect(costBasisModeOfCategory(null)).toBe("whole_item");
    expect(costBasisModeOfCategory(undefined)).toBe("whole_item");
    expect(canAverageCategory(undefined)).toBe(false);
  });

  it("เส้นแบ่งไม่ได้อยู่ที่ชนิดสินทรัพย์กว้างๆ — ในหมวดใหญ่เดียวกันมีทั้งสองคำตอบ", () => {
    for (const className of ["Paper Asset", "Commodity & Cash"]) {
      const inClass = allCategories().filter((c) => c.className === className);
      const modes = new Set(inClass.map((c) => c.costBasisMode));
      expect(modes.size, `${className} ต้องมีมากกว่าหนึ่งโหมด`).toBeGreaterThan(1);
    }
  });

  it("ทุกหมวดใหญ่ยังมีหมวดย่อย และรหัสหมวดไม่ซ้ำหลังเพิ่มหมวดใหม่", () => {
    for (const c of ASSET_CLASSES) expect(c.categories.length, c.name).toBeGreaterThan(0);
    const codes = allCategories().map((c) => c.code);
    expect(new Set(codes).size).toBe(codes.length);
  });
});

describe("ค่าในโค้ดกับค่าใน migration ต้องตรงกันตัวต่อตัว", () => {
  it("หมวดที่ migration ตั้งเป็น average = หมวดที่โค้ดบอกว่า average", () => {
    expect(codesSetTo("average")).toEqual(averagingCategoryCodes());
    expect(codesSetTo("average")).toEqual(BOSS_ALLOWS_AVERAGING);
  });

  it("หมวดที่ migration ตั้งเป็น specific_lot = หมวดที่โค้ดบอกว่า specific_lot", () => {
    expect(codesSetTo("specific_lot")).toEqual(categoryCodesByCostBasis("specific_lot"));
  });

  it("migration ต้องตั้งค่าตั้งต้นเป็น whole_item และ seed หมวดใหม่ครบ", () => {
    const sql = costBasisMigration();
    expect(sql).toMatch(/cost_basis_mode text not null default 'whole_item'/);
    // หมวด whole_item ไม่มีรายชื่อใน migration โดยตั้งใจ — มันคือ "ทุกอย่างที่เหลือ"
    expect(codesSetTo("whole_item")).toEqual([]);
    for (const code of ["PAPER_STOCK_LISTED", "PAPER_STOCK_PRIVATE", "COM_ALT"]) {
      expect(sql, `migration ต้อง seed หมวด ${code}`).toContain(`'${code}'`);
    }
  });

  it("ไม่มีด่านไหนใน migration อ่าน ticker หรือตัดสินจากรหัสบัญชี", () => {
    const sql = costBasisMigration();
    // ห้ามมี ticker ในเงื่อนไขของด่าน · มีในคอมเมนต์ได้ (เราอธิบายไว้ว่าทำไมไม่ใช้)
    // จึงตัดทั้งคอมเมนต์บรรทัด (`--`) และคอมเมนต์บล็อก (`/* */`) ออกก่อนเทียบ
    const code = sql
      .replace(/\/\*[\s\S]*?\*\//g, "")
      .split("\n")
      .filter((l) => !l.trimStart().startsWith("--"))
      .join("\n");
    // เทียบแบบเจาะจงว่า **อ่านคอลัมน์** หรือไม่ — คำว่า ticker ในข้อความอธิบาย
    // (`comment on function ...`) มีได้ และควรมี เพราะเป็นการบอกว่าทำไมไม่ใช้มัน
    expect(code).not.toMatch(/\b(a|assets|new|old|lx|v)\s*\.\s*ticker\b/);
    // และต้องไม่มีการตัดสินโหมดจากรหัสบัญชี (เช่น coa_code in ('1700'))
    expect(code).not.toMatch(/cost_basis_mode\s*=\s*'average'[\s\S]{0,200}c\.code/);
  });
});
