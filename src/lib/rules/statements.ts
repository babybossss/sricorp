/**
 * โครงงบดุลและงบกำไรขาดทุน — บรรทัดไหนอยู่ส่วนไหน และรวมบัญชีอะไร
 *
 * แยกจาก `coa.ts` เพราะเป็นเรื่องคนละชั้น:
 * - `coa.ts` บอกว่า "มีบัญชีอะไร"
 * - ไฟล์นี้บอกว่า "บัญชีนั้นไปโผล่บรรทัดไหนในงบ"
 *
 * ทั้งหน้ารายงานและไฟล์ที่ export ไปให้กรอก ต้องอ่านจากที่นี่ที่เดียว
 * ไม่งั้นงบบนจอกับงบใน Excel จะจัดกลุ่มไม่เหมือนกัน แล้วกระทบยอดกันไม่ได้
 *
 * มีเทสต์บังคับว่า **ทุกบัญชีในผังต้องอยู่ในงบใดงบหนึ่ง ครั้งเดียวเท่านั้น**
 * เพิ่มบัญชีใหม่แล้วลืมใส่ในโครงงบ = เทสต์พัง ไม่ใช่ยอดหายจากรายงานเงียบๆ
 */

import { COA, type CoaType } from "./coa";

export type BsSide = "asset" | "liability" | "equity";

export type BsLine = {
  /** บรรทัดที่แสดงในงบดุล */
  line: string;
  /** รหัสบัญชีที่รวมอยู่ในบรรทัดนี้ */
  codes: string[];
  /**
   * บรรทัดที่เอาไป **หัก** ออกจากกลุ่ม (contra)
   * เงินถอนของเจ้าของลดส่วนของเจ้าของ ไม่ใช่เพิ่ม
   */
  contra?: boolean;
};

export type BsGroup = {
  side: BsSide;
  group: string;
  lines: BsLine[];
};

export type PlLine = {
  line: string;
  codes: string[];
};

export type PlSection = {
  /** รายได้บวก ค่าใช้จ่ายหัก */
  kind: "revenue" | "expense";
  section: string;
  lines: PlLine[];
};

export const BS_LAYOUT: BsGroup[] = [
  {
    side: "asset",
    group: "สินทรัพย์หมุนเวียน",
    lines: [
      { line: "เงินสดและเงินฝากธนาคาร", codes: ["1100"] },
      { line: "ลูกหนี้ค่าเช่าและดอกเบี้ย", codes: ["1200", "1210"] },
      { line: "เงินมัดจำจ่าย", codes: ["1600"] },
    ],
  },
  {
    side: "asset",
    group: "เงินให้กู้และลงทุนตามสัญญา",
    lines: [
      { line: "เงินให้กู้ยืม", codes: ["1300"] },
      { line: "เงินลงทุนขายฝาก", codes: ["1400"] },
      { line: "เงินลงทุนจำนอง", codes: ["1410"] },
    ],
  },
  {
    side: "asset",
    group: "อสังหาริมทรัพย์เพื่อการลงทุน",
    lines: [{ line: "อสังหาริมทรัพย์และค่ารีโนเวท", codes: ["1500", "1510"] }],
  },
  {
    side: "asset",
    group: "เงินลงทุน",
    lines: [
      { line: "เงินลงทุนในหลักทรัพย์", codes: ["1700"] },
      { line: "ทองคำและสินทรัพย์ทางเลือก", codes: ["1720"] },
      { line: "เงินลงทุนในบริษัทในเครือ", codes: ["1710"] },
    ],
  },
  {
    side: "asset",
    // ตัดออกตอนทำงบรวม ไม่งั้นนับสินทรัพย์ซ้ำทั้งสองฝ่าย
    group: "รายการระหว่างกัน (ตัดออกในงบรวม)",
    lines: [{ line: "ลูกหนี้ระหว่างกัน", codes: ["1310"] }],
  },
  {
    side: "liability",
    group: "หนี้สินหมุนเวียน",
    lines: [
      { line: "เจ้าหนี้การค้าและเจ้าหนี้อื่น", codes: ["2100"] },
      { line: "เงินมัดจำรับจากผู้เช่า", codes: ["2200"] },
    ],
  },
  {
    side: "liability",
    group: "เงินกู้",
    lines: [
      { line: "เงินกู้ธนาคาร", codes: ["2410"] },
      { line: "เงินกู้ยืมกรรมการ", codes: ["2300"] },
      { line: "เงินกู้ยืมอื่น", codes: ["2400"] },
    ],
  },
  {
    side: "liability",
    group: "รายการระหว่างกัน (ตัดออกในงบรวม)",
    lines: [{ line: "เจ้าหนี้ระหว่างกัน", codes: ["2310"] }],
  },
  {
    side: "equity",
    group: "ส่วนของเจ้าของ",
    lines: [
      { line: "ทุนตั้งต้น", codes: ["3100"] },
      { line: "กำไรสะสม", codes: ["3300"] },
      { line: "หัก เงินถอนของเจ้าของ", codes: ["3200"], contra: true },
    ],
  },
];

export const PL_LAYOUT: PlSection[] = [
  {
    kind: "revenue",
    section: "รายได้",
    lines: [
      { line: "รายได้ค่าเช่า", codes: ["4200", "4210"] },
      { line: "รายได้ดอกเบี้ย", codes: ["4100", "4110", "4120"] },
      { line: "กำไรจากการขายทรัพย์", codes: ["4300"] },
      { line: "รายได้อื่น", codes: ["4310", "4400", "4410", "4900"] },
    ],
  },
  {
    kind: "expense",
    section: "ค่าใช้จ่าย",
    lines: [
      { line: "ค่าใช้จ่ายเกี่ยวกับทรัพย์สิน", codes: ["5100", "5110", "5120", "5130", "5140"] },
      { line: "ค่าใช้จ่ายในการขาย", codes: ["5200", "5210", "5220"] },
      { line: "ค่าใช้จ่ายบริหาร", codes: ["5300", "5310", "5320", "5330", "5500", "5510", "5520"] },
      { line: "ขาดทุนจากการขายทรัพย์", codes: ["5910"] },
      { line: "ค่าใช้จ่ายอื่น", codes: ["5900"] },
    ],
  },
  {
    kind: "expense",
    section: "ต้นทุนทางการเงิน",
    lines: [{ line: "ดอกเบี้ยจ่าย", codes: ["5400"] }],
  },
];

/**
 * บัญชีนี้อยู่งบดุลหรืองบกำไรขาดทุน
 *
 * เขียนเป็น switch ครบทุกเคสโดยตั้งใจ — เพิ่ม `CoaType` ใหม่แล้ว TypeScript จะฟ้องที่นี่
 * ถ้าใช้ `includes()` ประเภทใหม่จะเงียบๆ ตกไปเป็น P&L ซึ่งผิดโดยไม่มีอะไรเตือน
 */
export function isBalanceSheetType(type: CoaType): boolean {
  switch (type) {
    case "asset":
    case "liability":
    case "equity":
      return true;
    case "income":
    case "expense":
      return false;
  }
}

/** รหัสบัญชีทั้งหมดที่โครงงบดุลอ้างถึง */
export function bsCodes(): string[] {
  return BS_LAYOUT.flatMap((g) => g.lines.flatMap((l) => l.codes));
}

/** รหัสบัญชีทั้งหมดที่โครงงบกำไรขาดทุนอ้างถึง */
export function plCodes(): string[] {
  return PL_LAYOUT.flatMap((s) => s.lines.flatMap((l) => l.codes));
}

/** บัญชีในผังที่เป็นงบดุล เรียงตามที่แสดงในงบ */
export function bsAccounts(): { side: BsSide; group: string; line: string; code: string; contra: boolean }[] {
  return BS_LAYOUT.flatMap((g) =>
    g.lines.flatMap((l) =>
      l.codes.map((code) => ({ side: g.side, group: g.group, line: l.line, code, contra: !!l.contra }))
    )
  );
}

/** บรรทัดในงบที่บัญชีนี้ไปโผล่ — ใช้ตอน export และตอนแสดงรายงาน */
export function statementOf(code: string): { statement: "BS" | "PL"; group: string; line: string } {
  for (const g of BS_LAYOUT) {
    for (const l of g.lines) {
      if (l.codes.includes(code)) return { statement: "BS", group: g.group, line: l.line };
    }
  }
  for (const s of PL_LAYOUT) {
    for (const l of s.lines) {
      if (l.codes.includes(code)) return { statement: "PL", group: s.section, line: l.line };
    }
  }
  throw new Error(`บัญชี ${code} ไม่อยู่ในโครงงบใดเลย — เพิ่มใน statements.ts ก่อน`);
}

/** ชื่อไทยของฝั่งงบดุล ใช้เป็นหัวข้อในรายงานและไฟล์ export */
export const BS_SIDE_TH: Record<BsSide, string> = {
  asset: "สินทรัพย์",
  liability: "หนี้สิน",
  equity: "ส่วนของเจ้าของ",
};

/** ตรวจว่าโครงงบครอบคลุมผังบัญชีครบ — เรียกในเทสต์และตอน build ไฟล์ export */
export function findLayoutGaps(): { missing: string[]; duplicated: string[]; unknown: string[] } {
  const all = [...bsCodes(), ...plCodes()];
  const seen = new Map<string, number>();
  for (const c of all) seen.set(c, (seen.get(c) ?? 0) + 1);

  const coaCodes = new Set(COA.map((a) => a.code));
  return {
    missing: COA.filter((a) => !seen.has(a.code)).map((a) => a.code),
    duplicated: [...seen.entries()].filter(([, n]) => n > 1).map(([c]) => c),
    unknown: [...seen.keys()].filter((c) => !coaCodes.has(c)),
  };
}
