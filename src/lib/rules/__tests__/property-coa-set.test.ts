/**
 * **ชุดบัญชีอสังหาฯ ที่ค่ารีโนเวทเกาะได้** — ปิดช่องที่เหลือจาก commit 7ad740e
 *
 * ที่มา: 1520 (อสังหาฯ เพื่อการขาย) **ขายตรงไม่ได้** เพราะรหัส `1500` ถูกเขียนตาย
 * ไว้สามที่ (posting.ts · tx-rules.ts · ด่านของ 20261025000011) แล้วคำเตือนบอกให้
 * "ย้ายกลับ 1500 ก่อนขาย" ซึ่งคือ **แยกบัญชีได้แต่ขายไม่ได้** (บทเรียนข้อ 7)
 *
 * ไฟล์นี้ล็อกสี่อย่าง
 *   1. ชุดบัญชีอยู่ที่ `coa.ts` ที่เดียว และมีฟังก์ชันถาม (แพทเทิร์น `CATCH_ALL_COA`)
 *   2. **ทุกบัญชีในชุดต้องมีหมวดขายของตัวเอง** — ขาดตัวใดตัวหนึ่ง = เปิดครึ่งเดียว
 *   3. หมวดขายของ 1520 ขนานกับ `inv.sell_re` ทุกช่อง ต่างแค่ `cr`
 *   4. **สำเนาฝั่ง DB (`fn_property_coas()`) ตรงกับชุดในโค้ดตัวต่อตัว** —
 *      อ่านไฟล์ migration มาเทียบจริง ไม่ใช่เขียนรายชื่อซ้ำสองที่แล้วหวังว่าจะตรง
 *      (บทเรียนข้อ 5: กฎเดียวกันห้ามเขียนสองที่)
 */

import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import { propertyCoasFromSql } from "../../../../scripts/rules-db-sync";
import { PROPERTY_COA, RENOVATION_COA, coa, isPropertyAccount } from "../coa";
import { TX_TYPES, findSub, type SubCategory } from "../tx-rules";

const sub = (code: string): SubCategory => {
  const found = findSub(code);
  expect(found, `ไม่มีหมวด ${code} ในตารางกฎ`).toBeTruthy();
  return found!.sub;
};

const allSubs = (): SubCategory[] => TX_TYPES.flatMap((t) => t.subs);

/** หมวดขายอสังหาฯ ของ 1520 — ชื่อที่ไฟล์นี้ล็อกไว้ */
const SELL_HELD_FOR_SALE = "inv.sell_re_held_for_sale";

describe("1 · ชุดบัญชีอสังหาฯ อยู่ที่ coa.ts ที่เดียว", () => {
  it("ชุด = 1500 (เพื่อการเช่า) + 1520 (เพื่อการขาย) ไม่ขาดไม่เกิน", () => {
    expect([...PROPERTY_COA]).toEqual(["1500", "1520"]);
  });

  it("ทุกรหัสในชุดมีอยู่ในผังบัญชีจริง และเป็นสินทรัพย์", () => {
    for (const code of PROPERTY_COA) expect(coa(code).type, code).toBe("asset");
  });

  it("ฟังก์ชันถามตอบตรงกับชุด · ค่ารีโนเวทเองไม่ใช่บัญชีอสังหาฯ · บัญชีอื่นไม่ใช่", () => {
    for (const code of PROPERTY_COA) expect(isPropertyAccount(code), code).toBe(true);
    // 1510 เป็น **ต้นทุนที่เกาะ** บัญชีอสังหาฯ ไม่ใช่ตัวบัญชีอสังหาฯ เอง
    // ถ้าอยู่ในชุดด้วย ใบขายจะได้สิทธิ์ลง 1510 จากตัวมันเองเป็นวงกลม
    expect(isPropertyAccount(RENOVATION_COA)).toBe(false);
    for (const code of ["1400", "1410", "1700", "1900", "1950"]) expect(isPropertyAccount(code), code).toBe(false);
  });
});

describe("2 · ทุกบัญชีในชุดต้องขายได้ — ห้ามเปิดครึ่งเดียว (บทเรียนข้อ 7)", () => {
  it("ทุกรหัสในชุดมีหมวดจำหน่ายที่เครดิตมันอยู่จริง", () => {
    for (const code of PROPERTY_COA) {
      const routes = allSubs().filter((s) => s.cr === code && s.requires?.includes("capitalGain"));
      expect(
        routes.map((s) => s.code),
        `บัญชีอสังหาฯ ${code} ไม่มีหมวดขายที่เครดิตมันเลย = แยกบัญชีได้แต่ขายไม่ได้`
      ).not.toEqual([]);
    }
  });

  it("ทุกหมวดขายอสังหาฯ ตัดค่ารีโนเวทได้ครบ (gain/loss/accrual ครบทุกตัว)", () => {
    for (const code of PROPERTY_COA) {
      for (const s of allSubs().filter((x) => x.cr === code && x.requires?.includes("capitalGain"))) {
        expect(s.gainCoa, `${s.code} ไม่มีบัญชีรับรู้กำไร`).toBeTruthy();
        expect(s.lossCoa, `${s.code} ไม่มีบัญชีรับรู้ขาดทุน`).toBeTruthy();
        expect(s.accrualCoa, `${s.code} ตั้งค้างรับไม่ได้ = ขายแล้วยังไม่ได้เงินลงไม่ได้`).toBeTruthy();
      }
    }
  });
});

describe("3 · หมวดขาย 1520 ขนานกับ inv.sell_re ทุกช่อง ต่างแค่ cr", () => {
  it("มีหมวดขายของ 1520 อยู่ใต้ประเภท invest_sell", () => {
    expect(findSub(SELL_HELD_FOR_SALE)!.type.key).toBe("invest_sell");
  });

  it("ทุกช่องเหมือน inv.sell_re ยกเว้น cr (1500 → 1520) · label/plain/caution ต่างได้", () => {
    const rental = sub("inv.sell_re");
    const held = sub(SELL_HELD_FOR_SALE);
    expect(held.cr).toBe("1520");
    expect(rental.cr).toBe("1500");
    expect(held.dr).toBe(rental.dr);
    expect(held.cash).toBe(rental.cash);
    expect(held.cashflow).toBe(rental.cashflow);
    expect(held.gainCoa).toBe(rental.gainCoa);
    expect(held.lossCoa).toBe(rental.lossCoa);
    expect(held.interestCoa).toBe(rental.interestCoa);
    expect(held.accrualCoa).toBe(rental.accrualCoa);
    expect([...(held.requires ?? [])].sort()).toEqual([...(rental.requires ?? [])].sort());
  });

  it("คำเตือนของหมวดย้ายวัตถุประสงค์ **ไม่บอกให้ย้ายกลับก่อนขาย** อีกแล้ว", () => {
    for (const code of ["adj.reclass_re_to_sale", "adj.reclass_re_to_rental"]) {
      const c = sub(code).caution ?? "";
      // "ไม่ต้องย้ายกลับ" ผ่านได้ · "ต้องย้ายกลับ...ก่อนขาย" ผ่านไม่ได้
      expect(c, `${code} ยังบอกให้ย้ายกลับก่อนขาย ซึ่งใช้ไม่ได้จริงแล้ว`).not.toMatch(/(?<!ไม่)ต้องย้ายกลับ/);
      expect(c, `${code} ยังอ้างว่าหมวดขายอสังหาฯ มีหมวดเดียว`).not.toMatch(/หมวดเดียวที่ตัดค่ารีโนเวท/);
    }
  });

  it("คำอธิบายของ 1520 ในผังบัญชีไม่ค้างข้อความ 'ยังขายตรงจากบัญชีนี้ไม่ได้'", () => {
    const src = readFileSync(join(process.cwd(), "src", "lib", "rules", "coa.ts"), "utf8");
    expect(src, "คอมเมนต์ค้างอยู่ = เอกสารในโค้ดขัดกับของจริง").not.toMatch(/ยังขายตรงจากบัญชีนี้ไม่ได้/);
  });
});

/* ================================================================== *
 * 4 · สำเนาฝั่ง DB ต้องตรงกับชุดในโค้ด — อ่าน migration จริงมาเทียบ
 * ================================================================== */

const MIGRATION_DIR = join(process.cwd(), "supabase", "migrations");

/**
 * migration ที่ **นิยามฟังก์ชันนั้นอยู่ล่าสุด** — ไม่ใช่ไฟล์แรกที่ชื่อเข้าเค้า
 *
 * เดิมหาจาก **ชื่อไฟล์** ที่มีคำว่า `property_coa_set` แล้วบังคับว่าต้องมีไฟล์เดียว
 * วันที่เพิ่มบัญชีอสังหาฯ ตัวที่สาม (migration ใหม่ที่ `create or replace` ทับ)
 * เทสต์จะแดงด้วยเหตุผลผิด — และถ้าใครแก้ให้เป็น `names[0]` มันจะไป**ตรวจไฟล์เก่า
 * ที่ถูกเขียนทับไปแล้ว** คือบอกว่าผ่านทั้งที่ของจริงใน DB เป็นอีกชุด
 *
 * จึงไล่จาก **เนื้อไฟล์** (ใครนิยามฟังก์ชันนี้) แล้วเอาไฟล์ท้ายสุดตามลำดับชื่อ
 * ซึ่งเป็นกฎเดียวกับที่ `effectivePropertyCoas()` ใช้ตอน `check:rules-sync`
 * ไม่พบเลย = พัง ไม่ยอมผ่านด้วยชุดว่าง
 */
function latestMigrationDefining(fnName: string): string {
  const names = readdirSync(MIGRATION_DIR)
    .filter((n) => n.endsWith(".sql"))
    .sort()
    .filter((n) =>
      new RegExp(`create\\s+(?:or\\s+replace\\s+)?function\\s+(?:sri_os\\.)?${fnName}\\s*\\(`, "i").test(
        readFileSync(join(MIGRATION_DIR, n), "utf8")
      )
    );
  expect(
    names.length,
    `ไม่พบ migration ที่นิยาม ${fnName}() เลย — เทสต์นี้จะไม่ได้ตรวจอะไร`
  ).toBeGreaterThan(0);
  return readFileSync(join(MIGRATION_DIR, names[names.length - 1]), "utf8");
}

/** ไฟล์ที่ถือ "ชุดบัญชีอสังหาฯ" ฝั่ง DB อยู่ตอนนี้ */
const propertySetMigration = (): string => latestMigrationDefining("fn_property_coas");

/** ไฟล์ที่ถือ "ด่านคู่บัญชีต้องตรงตารางกฎ" อยู่ตอนนี้ — อาจเป็นไฟล์เดียวกันหรือไม่ก็ได้ */
const lineCoaGuardMigration = (): string => latestMigrationDefining("fn_assert_line_coa_in_rules");

/**
 * ดึงรายชื่อรหัสที่ `fn_property_coas()` คืน — ใช้ตัวอ่าน**ตัวเดียวกับ**
 * `check:rules-sync` (บทเรียนข้อ 5: กฎเดียวกันห้ามเขียนสองที่ · เดิมไฟล์นี้
 * มี regex ของตัวเองอีกชุด ซึ่งแยกกันเดินจากตัวที่ใช้เทียบกับ DB จริงได้)
 */
function dbPropertyCoas(): string[] {
  const codes = propertyCoasFromSql(propertySetMigration());
  expect(codes, "อ่าน fn_property_coas() จาก migration ไม่ออก").toBeTruthy();
  return codes!;
}

describe("4 · fn_property_coas() ฝั่ง DB = PROPERTY_COA ฝั่งโค้ด", () => {
  it("รายชื่อตรงกันตัวต่อตัว (กฎเดียวกันห้ามอยู่สองที่แบบที่ไม่มีใครเทียบ)", () => {
    expect(dbPropertyCoas()).toEqual([...PROPERTY_COA].sort());
  });

  it("ด่านอ่านจากฟังก์ชัน **ไม่ใช่เทียบรหัสเดียว** — ห้ามมี cr_coa_code = '1500' กลับมา", () => {
    // ตัดคอมเมนต์ออกก่อน — หัวไฟล์ **ต้อง** พูดถึงเงื่อนไขเดิมเพื่ออธิบายที่มา
    // สิ่งที่ห้ามคือโค้ดที่รันจริง ไม่ใช่คำอธิบาย
    const code = lineCoaGuardMigration()
      .split("\n")
      .filter((l) => !/^\s*(--|\*|\/\*)/.test(l))
      .join("\n");
    expect(code, "ด่านกลับไปเทียบรหัสเดียว = 1520 ขายไม่ได้อีกรอบ").not.toMatch(
      /cr_coa_code\s*=\s*'1[0-9]{3}'/
    );
    expect(code).toMatch(/cr_coa_code\s*=\s*any\s*\(\s*sri_os\.fn_property_coas\(\)\s*\)/);
  });

  it("เขียนทับ fn_assert_line_coa_in_rules() ตัวเดิม ไม่สร้างด่านตัวที่สอง", () => {
    expect(lineCoaGuardMigration()).toMatch(/create or replace function fn_assert_line_coa_in_rules\(\)/);
  });

  it("ไฟล์ 0011 เดิมไม่ถูกแก้ (ลงไป DB จริงแล้ว) — ยังเทียบรหัสเดียวอยู่เหมือนเดิม", () => {
    const old = readFileSync(join(MIGRATION_DIR, "20261025000011_sell_re_clears_renovation.sql"), "utf8");
    expect(old).toMatch(/cr_coa_code\s*=\s*'1500'/);
  });
});
