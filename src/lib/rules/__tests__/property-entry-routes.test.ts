/**
 * **เส้นทาง "เข้า" ของอสังหาฯ เพื่อการขาย (1520)** — ปิดช่องสุดท้ายต่อจาก `f0322a4`
 *
 * `f0322a4` เปิดเส้นทาง **ออก** ให้ 1520 (ขายตรงได้ ตัดค่ารีโนเวทได้) แต่เส้นทาง
 * **เข้า** ยังเหลืออยู่สองทาง และทั้งสองเดบิต `1500` ตายตัว:
 *   `inv.buy_re` (ซื้อเข้า) · `opn.property` (ยอดตั้งต้น)
 * ผลคือทรัพย์ที่ซื้อมา**เพื่อขาย** ต้องลงบัญชี**เพื่อการเช่า**ก่อนแล้วย้ายอีกใบ
 * → **งบดุลระหว่างนั้นบอกว่าเป็นของให้เช่า** ซึ่งผิดความจริงตั้งแต่ใบแรก
 * และเหตุผลที่ลูกพี่สั่งแยกบัญชี (อยากเห็นว่าของรอขายมีเท่าไร) ก็หายไปทั้งก้อน
 *
 * ไฟล์นี้ล็อกสี่อย่าง
 *   1. **ทุกบัญชีในชุด `PROPERTY_COA` มีเส้นทางเข้าครบทั้งสองทาง** (ซื้อ + ยอดยกมา)
 *      — ขาดทางใดทางหนึ่งคือเปิดฟีเจอร์ครึ่งเดียว (บทเรียน mace-windu ข้อ 7)
 *   2. หมวดใหม่ขนานกับตัวเดิม **ทุกช่อง ต่างแค่ `dr`**
 *   3. `caution` บอก **เส้นแบ่ง** ว่าเลือกบัญชีไหนตอนไหน และถ้าเปลี่ยนใจภายหลัง
 *      ให้ใช้หมวดโอนเปลี่ยนประเภท **ไม่ใช่ลงใหม่** (ลงใหม่ = ต้นทุนซ้ำสองบัญชี)
 *   4. โครงงบกระแสเงินสดครอบหมวดใหม่ครบ (`findCashflowLayoutGaps()` ว่าง)
 *      และตารางเทียบของการนำเข้ายอดตั้งต้นรู้จัก 1520 แล้ว
 *
 * **เทสต์กลายพันธุ์** (แบบเดียวกับ P5 ของ `zz_property_coa_set_test.sql`) อยู่ท้ายไฟล์:
 * ใส่บัญชีอสังหาฯ ตัวที่สามเข้าชุดแล้วด่านข้อ 1 ต้องแดงทันที — ถ้ายังเขียว
 * แปลว่าข้อ 1 ไม่ได้อ่านชุดจริง (วัดของผิด)
 */

import { describe, expect, it } from "vitest";

import { PROPERTY_COA, RENOVATION_COA, RETAINED_EARNINGS_COA, coa, isCashAccount } from "../coa";
import { TX_TYPES, canAccrueFromForm, findSub, isOpeningBalanceSub, type SubCategory } from "../tx-rules";
import { cashflowLineOf, findCashflowLayoutGaps, statementOf } from "../statements";
import { openingSubByAccount } from "@/lib/db/import/opening-post";

/** ชื่อหมวดที่ไฟล์นี้ล็อกไว้ */
const BUY_HELD_FOR_SALE = "inv.buy_re_held_for_sale";
const OPEN_HELD_FOR_SALE = "opn.property_held_for_sale";

const sub = (code: string): SubCategory => {
  const found = findSub(code);
  expect(found, `ไม่มีหมวด ${code} ในตารางกฎ`).toBeTruthy();
  return found!.sub;
};

const allSubs = (): SubCategory[] => TX_TYPES.flatMap((t) => t.subs);

/** หมวด "ซื้อเข้า" ของบัญชีหนึ่ง = เดบิตบัญชีนั้น · เครดิตเงินสด · เข้ากิจกรรมลงทุน */
const buyRoutes = (code: string): SubCategory[] =>
  allSubs().filter((s) => s.dr === code && isCashAccount(s.cr) && s.cashflow === "investing");

/** หมวด "ยอดยกมา" ของบัญชีหนึ่ง = เดบิตบัญชีนั้น คู่กับกำไรสะสม */
const openingRoutes = (code: string): SubCategory[] =>
  allSubs().filter((s) => isOpeningBalanceSub(s) && s.dr === code);

/**
 * บัญชีในชุดที่ยัง "เข้าไม่ได้" — อ่าน **ชุด** ไม่ใช่รหัสเดียว
 * คืนรายการเพื่อให้เทสต์กลายพันธุ์ท้ายไฟล์เรียกซ้ำได้
 */
function accountsWithoutEntryRoute(): { code: string; missing: string[] }[] {
  const out: { code: string; missing: string[] }[] = [];
  for (const code of PROPERTY_COA) {
    const missing: string[] = [];
    if (buyRoutes(code).length === 0) missing.push("ซื้อเข้า");
    if (openingRoutes(code).length === 0) missing.push("ยอดยกมา");
    if (missing.length) out.push({ code, missing });
  }
  return out;
}

/* ================================================================== *
 * 1 · ทุกบัญชีอสังหาฯ ต้องเข้าได้ทั้งสองทาง — ห้ามเปิดครึ่งเดียว
 * ================================================================== */

describe("1 · เส้นทางเข้าของทุกบัญชีในชุด PROPERTY_COA", () => {
  it("ทุกรหัสในชุดมีทั้งหมวดซื้อเข้าและหมวดยอดยกมาของตัวเอง", () => {
    expect(
      accountsWithoutEntryRoute(),
      "บัญชีอสังหาฯ ที่ซื้อเข้าตรงไม่ได้ หรือลงยอดตั้งต้นตรงไม่ได้ = ต้องลงบัญชีอื่นก่อนแล้วย้าย ซึ่งงบดุลระหว่างนั้นผิด"
    ).toEqual([]);
  });

  it("แต่ละบัญชีมีทางเข้าทางละ **หนึ่งหมวด** ไม่ใช่สองหมวดให้คนเลือกเอง", () => {
    // สองหมวดที่ลงบัญชีเดียวกัน = ยอดขึ้นกับคนกรอก ไม่ใช่ขึ้นกับความจริง
    for (const code of PROPERTY_COA) {
      expect(buyRoutes(code).map((s) => s.code), `หมวดซื้อเข้าของ ${code}`).toHaveLength(1);
      expect(openingRoutes(code).map((s) => s.code), `หมวดยอดยกมาของ ${code}`).toHaveLength(1);
    }
  });

  it("**ทางกลับ** — ไม่มีหมวดซื้อ/ยอดยกมาที่ลงบัญชีอสังหาฯ นอกชุด", () => {
    const property = new Set<string>(PROPERTY_COA);
    const re = allSubs().filter(
      (s) => s.dr !== RENOVATION_COA && coa(s.dr).type === "asset" && /^15\d\d$/.test(s.dr)
    );
    expect(
      re.filter((s) => !property.has(s.dr)).map((s) => `${s.code}→${s.dr}`),
      "มีหมวดที่ลงบัญชีกลุ่ม 15xx ซึ่งไม่อยู่ในชุดและไม่ใช่ค่ารีโนเวท → ด่านค่ารีโนเวทจะไม่ครอบมัน"
    ).toEqual([]);
  });

  it("ค่ารีโนเวท (1510) ยังมีหมวดของตัวเองทางละหนึ่ง และ **ไม่ผูกกับบัญชีอสังหาฯ ตัวใดตัวหนึ่ง**", () => {
    // ค่ารีโนเวทเดบิต 1510 เครดิตเงินสด — ไม่เอ่ยถึง 1500/1520 เลย
    // จึงลงบนทรัพย์ที่อยู่บัญชีไหนก็ได้ (ความผูกพันอยู่ที่ `asset_id`)
    const capex = sub("inv.capex");
    expect(capex.dr).toBe(RENOVATION_COA);
    expect(isCashAccount(capex.cr)).toBe(true);
    for (const code of PROPERTY_COA) {
      expect([capex.dr, capex.cr], `หมวดค่ารีโนเวทไปผูกกับ ${code} = รีโนเวทของรอขายลงไม่ได้`).not.toContain(code);
    }
    const open = sub("opn.renovation");
    expect(open.dr).toBe(RENOVATION_COA);
    expect(open.cr).toBe(RETAINED_EARNINGS_COA);
  });
});

/* ================================================================== *
 * 2 · หมวดใหม่ขนานกับตัวเดิมทุกช่อง ต่างแค่ dr
 * ================================================================== */

describe("2 · ซื้ออสังหาฯ เพื่อขาย ขนานกับ inv.buy_re", () => {
  it("อยู่ใต้ประเภทเดียวกัน (invest_buy)", () => {
    expect(findSub(BUY_HELD_FOR_SALE)!.type.key).toBe(findSub("inv.buy_re")!.type.key);
  });

  it("ทุกช่องเหมือน inv.buy_re ยกเว้น dr (1500 → 1520)", () => {
    const rental = sub("inv.buy_re");
    const held = sub(BUY_HELD_FOR_SALE);
    expect(held.dr).toBe("1520");
    expect(rental.dr).toBe("1500");
    expect(held.cr).toBe(rental.cr);
    expect(held.cash).toBe(rental.cash);
    expect(held.cashflow).toBe(rental.cashflow);
    expect(held.gainCoa).toBe(rental.gainCoa);
    expect(held.lossCoa).toBe(rental.lossCoa);
    expect(held.interestCoa).toBe(rental.interestCoa);
    expect(held.accrualCoa).toBe(rental.accrualCoa);
    expect([...(held.requires ?? [])].sort()).toEqual([...(rental.requires ?? [])].sort());
  });

  it("คำตอบเรื่อง **ตั้งค้างจ่าย** ต้องเท่ากันทั้งสองบัญชี — ไม่ใช่หมวดใหม่ได้สิทธิ์ที่ตัวเดิมไม่มี", () => {
    // ตอนนี้ทั้งคู่ตั้งค้างจ่ายไม่ได้ (บัญชีล้าง 2100 อยู่หมวดดำเนินงาน แต่รายการอยู่หมวดลงทุน)
    // สิ่งที่ล็อกคือ **ความเท่ากัน** ไม่ใช่ค่า เพราะวันที่เปิดให้ตั้งค้างได้ ต้องเปิดพร้อมกันทั้งคู่
    expect(canAccrueFromForm(sub(BUY_HELD_FOR_SALE))).toBe(canAccrueFromForm(sub("inv.buy_re")));
    expect(canAccrueFromForm(sub(OPEN_HELD_FOR_SALE))).toBe(canAccrueFromForm(sub("opn.property")));
  });
});

describe("3 · ยอดยกมาอสังหาฯ เพื่อขาย ขนานกับ opn.property", () => {
  it("อยู่ใต้ประเภทเดียวกัน (opening) และคู่กับกำไรสะสม", () => {
    expect(findSub(OPEN_HELD_FOR_SALE)!.type.key).toBe("opening");
    expect(sub(OPEN_HELD_FOR_SALE).cr).toBe(RETAINED_EARNINGS_COA);
    expect(isOpeningBalanceSub(sub(OPEN_HELD_FOR_SALE))).toBe(true);
  });

  it("ทุกช่องเหมือน opn.property ยกเว้น dr (1500 → 1520)", () => {
    const rental = sub("opn.property");
    const held = sub(OPEN_HELD_FOR_SALE);
    expect(held.dr).toBe("1520");
    expect(rental.dr).toBe("1500");
    expect(held.cr).toBe(rental.cr);
    expect(held.cash).toBe(rental.cash);
    expect(held.cashflow).toBe(rental.cashflow);
    expect(held.gainCoa).toBe(rental.gainCoa);
    expect(held.lossCoa).toBe(rental.lossCoa);
    expect(held.interestCoa).toBe(rental.interestCoa);
    expect(held.accrualCoa).toBe(rental.accrualCoa);
    expect([...(held.requires ?? [])].sort()).toEqual([...(rental.requires ?? [])].sort());
  });

  it("ไม่กระทบเงินสดและไม่เข้างบกระแสเงินสด (เหมือนยอดยกมาทุกตัว)", () => {
    expect(sub(OPEN_HELD_FOR_SALE).cash).toBe("none");
    expect(sub(OPEN_HELD_FOR_SALE).cashflow).toBe("none");
  });
});

/* ================================================================== *
 * 4 · caution ต้องบอกเส้นแบ่ง และบอกว่าเปลี่ยนใจให้ย้าย ไม่ใช่ลงใหม่
 * ================================================================== */

describe("4 · คำเตือนบอกเส้นแบ่งและทางแก้เมื่อเปลี่ยนใจ", () => {
  it("หมวดใหม่ทั้งสองบอกว่าใช้กับของที่ถือไว้ **ขาย** และอ้างบัญชี 1520", () => {
    for (const code of [BUY_HELD_FOR_SALE, OPEN_HELD_FOR_SALE]) {
      const c = sub(code).caution ?? "";
      expect(c, `${code} ไม่มีคำเตือน`).not.toBe("");
      expect(c, `${code} ไม่บอกว่าใช้ตอนไหน`).toMatch(/ขาย/);
      expect(c, `${code} ไม่อ้างบัญชีของตัวเอง`).toMatch(/1520/);
      expect(c, `${code} ไม่บอกเส้นแบ่งกับฝั่งเช่า`).toMatch(/1500|เช่า/);
    }
  });

  it("หมวดเดิมทั้งสองบอกเส้นแบ่งกลับมาที่ 1520 ด้วย — ไม่ใช่บอกข้างเดียว", () => {
    for (const code of ["inv.buy_re", "opn.property"]) {
      const c = sub(code).caution ?? "";
      expect(c, `${code} ไม่บอกว่าของที่ซื้อมาเพื่อขายต้องลงบัญชีอื่น`).toMatch(/1520/);
    }
  });

  it("**เปลี่ยนใจภายหลัง = ใช้หมวดย้ายวัตถุประสงค์ ไม่ใช่ลงใหม่**", () => {
    // ลงใหม่ = ต้นทุนของทรัพย์ชิ้นเดียวค้างอยู่สองบัญชี แล้วงบดุลบวมเท่าต้นทุน
    for (const code of [BUY_HELD_FOR_SALE, OPEN_HELD_FOR_SALE]) {
      const c = sub(code).caution ?? "";
      expect(c, `${code} ไม่บอกทางแก้เมื่อเปลี่ยนใจ`).toMatch(/ย้ายวัตถุประสงค์/);
      expect(c, `${code} ไม่ห้ามลงใหม่`).toMatch(/ไม่ใช่ลงใหม่|ห้ามลงใหม่/);
    }
  });

  it("หมวดยอดยกมาเดิมไม่บอกให้ลง 1520 ที่บรรทัด 1500 แล้วย้ายอีกใบอีกแล้ว", () => {
    const c = sub("opn.property").caution ?? "";
    expect(c, "คำเตือนค้างอยู่ = คู่มือในโค้ดขัดกับของจริง").not.toMatch(/นำเข้าที่บรรทัดนี้เหมือนกัน/);
  });

  it("หมวดย้ายวัตถุประสงค์ยังมีครบสองทิศ (เปลี่ยนใจได้ทั้งขึ้นและลง)", () => {
    expect(sub("adj.reclass_re_to_sale").dr).toBe("1520");
    expect(sub("adj.reclass_re_to_sale").cr).toBe("1500");
    expect(sub("adj.reclass_re_to_rental").dr).toBe("1500");
    expect(sub("adj.reclass_re_to_rental").cr).toBe("1520");
  });
});

/* ================================================================== *
 * 5 · โครงงบและตารางเทียบนำเข้า
 * ================================================================== */

describe("5 · โครงงบกระแสเงินสดและตารางเทียบนำเข้าครอบหมวดใหม่", () => {
  it("findCashflowLayoutGaps() ว่างทั้งเจ็ดช่อง", () => {
    const g = findCashflowLayoutGaps();
    expect(g.missing, "หมวดที่เข้างบ CF ได้แต่โครงงบไม่มี → ยอดหายเงียบๆ").toEqual([]);
    expect(g.duplicated, "หมวดที่อยู่สองบรรทัด → ยอดถูกนับซ้ำ").toEqual([]);
    expect(g.unknown).toEqual([]);
    expect(g.wrongSection, "หมวดที่อยู่ผิดส่วน → กระแสเงินสดดำเนินงานผิด").toEqual([]);
    expect(g.missingLegs).toEqual([]);
    expect(g.duplicatedLegs).toEqual([]);
    expect(g.wrongSectionLegs).toEqual([]);
  });

  it("หมวดซื้อใหม่อยู่บรรทัดเดียวกับซื้ออสังหาฯ ตัวเดิม (เงินที่จ่ายซื้อทรัพย์คือก้อนเดียวกัน)", () => {
    const a = cashflowLineOf("inv.buy_re");
    const b = cashflowLineOf(BUY_HELD_FOR_SALE);
    expect(b.section).toBe("investing");
    expect(b.line).toBe(a.line);
  });

  it("ยอดยกมาของ 1520 ไม่อยู่ในโครงงบกระแสเงินสด (ยอดต้นงวดไม่ใช่กระแสของงวด)", () => {
    expect(() => cashflowLineOf(OPEN_HELD_FOR_SALE)).toThrow();
  });

  it("งบดุลยังแยกบรรทัด 1520 ไว้ของตัวเอง", () => {
    expect(statementOf("1520").statement).toBe("BS");
    expect(statementOf("1520").line).not.toBe(statementOf("1500").line);
  });

  it("ตารางเทียบของการนำเข้ายอดตั้งต้นรู้จัก 1520 แล้ว — ไฟล์ที่มีแถวนี้ไม่ถูกปฏิเสธทั้งไฟล์", () => {
    const map = openingSubByAccount();
    expect(map.get("1520")?.code, "1520 ยังไม่มีหมวดยอดยกมา = ทรัพย์ที่ถือไว้ขายก่อนวันตัดยอดนำเข้าไม่ได้").toBe(
      OPEN_HELD_FOR_SALE
    );
    expect(map.get("1500")?.code).toBe("opn.property");
    expect(map.get("1510")?.code).toBe("opn.renovation");
  });
});

/* ================================================================== *
 * 6 · MUTATION — ด่านข้อ 1 ต้องอ่าน **ชุด** จริง ไม่ใช่รายชื่อที่เขียนไว้ในเทสต์
 * ================================================================== */

describe("6 · เทสต์กลายพันธุ์ · ด่านเส้นทางเข้าอ่านชุดจริง", () => {
  it("ใส่บัญชีอสังหาฯ ตัวที่สามเข้าชุด → ด่าน 'ทุกบัญชีเข้าได้' แดงทันที", () => {
    // ของเดิมต้องเขียวก่อน ไม่งั้นเทสต์นี้แดงเพราะเหตุผลอื่น
    expect(accountsWithoutEntryRoute()).toEqual([]);
    const set = PROPERTY_COA as unknown as string[];
    set.push("1530");
    try {
      expect(
        accountsWithoutEntryRoute(),
        "เพิ่มบัญชีเข้าชุดแล้วด่านยังเขียว → ด่านไม่ได้อ่าน PROPERTY_COA (ข้อ 1 วัดของผิด)"
      ).toEqual([{ code: "1530", missing: ["ซื้อเข้า", "ยอดยกมา"] }]);
    } finally {
      set.pop();
    }
    expect(accountsWithoutEntryRoute(), "คืนชุดไม่สำเร็จ").toEqual([]);
  });

  it("ถอด dr ของหมวดซื้อใหม่กลับเป็น 1500 → ด่านแดงทันที (1520 ซื้อเข้าตรงไม่ได้อีก)", () => {
    const held = sub(BUY_HELD_FOR_SALE);
    const original = held.dr;
    try {
      held.dr = "1500";
      expect(accountsWithoutEntryRoute()).toEqual([{ code: "1520", missing: ["ซื้อเข้า"] }]);
    } finally {
      held.dr = original;
    }
    expect(accountsWithoutEntryRoute()).toEqual([]);
  });

  it("ถอด dr ของหมวดยอดยกมาใหม่กลับเป็น 1500 → ด่านแดงทันที", () => {
    const held = sub(OPEN_HELD_FOR_SALE);
    const original = held.dr;
    try {
      held.dr = "1500";
      expect(accountsWithoutEntryRoute()).toEqual([{ code: "1520", missing: ["ยอดยกมา"] }]);
    } finally {
      held.dr = original;
    }
    expect(accountsWithoutEntryRoute()).toEqual([]);
  });
});
