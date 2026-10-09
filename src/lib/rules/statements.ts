/**
 * โครงงบดุล · งบกำไรขาดทุน · งบกระแสเงินสด — บรรทัดไหนอยู่ส่วนไหน และรวมอะไร
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
import { TX_TYPES, type CashflowSection } from "./tx-rules";
import { INTERCOMPANY_RULES, type IntercompanyNature } from "./intercompany";

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
      // แยกบรรทัดจากลูกหนี้ค่าเช่า/ดอกเบี้ยโดยตั้งใจ — 1220 คือเงินที่ยังไม่เข้าจาก
      // รายการลงทุน/จัดหาเงิน (ขายทรัพย์ · รับไถ่ถอน · กู้ที่อนุมัติแล้ว) ซึ่งไม่ใช่
      // ลูกหนี้จากการดำเนินงาน รวมบรรทัดกันจะอ่านงบไม่ออกว่าค้างจากอะไร
      { line: "ลูกหนี้อื่น", codes: ["1220"] },
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

/* ------------------------------------------------------------------ *
 * งบกระแสเงินสด — **วิธีตรง**
 *
 * ต่างจากงบดุล/งบกำไรขาดทุนตรงที่ **จัดกลุ่มตามหมวดรายการ ไม่ใช่ตามรหัสบัญชี**
 *
 * เหตุผล: เงินสดหนึ่งก้อนของรายการหนึ่งต้องอยู่บรรทัดเดียว
 *   ขายอสังหา 8 ล้าน = ตัดทรัพย์ 6 ล้าน + กำไร 2 ล้าน
 *   ถ้าจัดกลุ่มตามบัญชีคู่ เงิน 8 ล้านจะถูกแยกเป็น 6 ล้าน (ลงทุน) + 2 ล้าน (ดำเนินงาน)
 *   ซึ่ง **ผิด** — เงินที่รับมาจากการขายทรัพย์คือ 8 ล้านทั้งก้อน อยู่ในกิจกรรมลงทุน
 *
 * ส่วน (ดำเนินงาน/ลงทุน/จัดหาเงิน) มาจาก `cf_category` ที่ **เก็บไว้ในบรรทัด**
 * ไม่ใช่คำนวณใหม่จากตารางกฎ — เหตุผลเดียวกับใบกลับรายการ (ดู `lib/ledger/reversal.ts`):
 * ตารางกฎเปลี่ยนได้ แต่สิ่งที่เกิดขึ้นในอดีตเปลี่ยนไม่ได้
 *
 * **ห้ามเดาส่วนจาก prefix ของรหัสหมวด** — ของจริงไม่ตรงกัน:
 *   `fin.pay_payable` · `fin.deposit_received` · `fin.deposit_refund` = **ดำเนินงาน**
 *   `inv.deposit_paid` · `inv.deposit_returned` · `inv.collect_rent` = **ดำเนินงาน**
 * มีเทสต์บังคับว่าทุกหมวดต้องอยู่ในส่วนที่ตรงกับ `cashflow` ของตัวเอง
 * ------------------------------------------------------------------ */

/**
 * ขาของรายการข้ามผู้ถือ — ฝ่ายจ่ายกับฝ่ายรับอยู่ **ส่วนต่างกัน** ของงบ
 * (เงินทดรอง/กู้ยืม/เพิ่มทุน: จ่าย = ลงทุน · รับ = จัดหาเงิน · ปันผลสลับกัน)
 */
export type IntercompanyLeg = { nature: IntercompanyNature; side: "payer" | "receiver" };

export type CfLine = {
  line: string;
  /** รหัส **หมวดรายการ** (ไม่ใช่รหัสบัญชี) ที่รวมอยู่ในบรรทัดนี้ */
  subCodes: string[];
  /**
   * ขาของรายการข้ามผู้ถือที่รวมอยู่ในบรรทัดนี้
   *
   * **ต้องแยกจาก `subCodes` เพราะคีย์ไม่เหมือนกัน** — รายการข้ามผู้ถือใช้
   * หมวด `trf.internal` ซึ่งตารางกฎตั้ง `cashflow: "none"` (โอนระหว่างบัญชี
   * ตัวเองไม่ใช่กระแสเงินสด) แต่พอข้ามผู้ถือ **มันเป็นกระแสเงินสดจริงของแต่ละฝ่าย**
   * และหมวดมาจาก `intercompany.ts` ไม่ใช่จากตารางกฎ
   *
   * เคยพลาดเพราะตรงนี้: ตัวตรวจช่องว่างดูแต่ตารางกฎ จึงพอใจว่า `trf.internal`
   * เป็น "none" แล้วไม่ต้องอยู่ในโครงงบ ทั้งที่ของจริงสร้างกระแสเงินสดอยู่
   * (จุดบอดเดียวกับที่ `sync:rules` พลาด `intercompany.ts` — ดู D-096)
   */
  legs?: IntercompanyLeg[];
};

export type CfSection = {
  section: Exclude<CashflowSection, "none">;
  title: string;
  lines: CfLine[];
};

export const CF_LAYOUT: CfSection[] = [
  {
    section: "operating",
    title: "กระแสเงินสดจากกิจกรรมดำเนินงาน",
    lines: [
      // การรับชำระค้างรับอยู่บรรทัดเดียวกับรายได้ที่ตั้งค้างไว้โดยตั้งใจ —
      // เงินที่เข้าจริงจากค่าเช่าคือก้อนเดียวกัน ไม่ว่าจะเข้าทันทีหรือเข้าทีหลัง
      { line: "เงินสดรับจากค่าเช่าและค่าเช่าซื้อ", subCodes: ["inc.rent", "inc.hire_purchase", "inv.collect_rent"] },
      { line: "เงินสดรับจากดอกเบี้ย", subCodes: ["inc.interest_srr", "inc.interest_mortgage", "inc.interest_loan", "inv.collect_interest"] },
      { line: "เงินสดรับจากเงินปันผล", subCodes: ["inc.dividend"] },
      { line: "เงินสดรับอื่น", subCodes: ["inc.key_money", "inc.fee", "inc.other"] },
      { line: "เงินสดจ่ายค่าใช้จ่ายเกี่ยวกับทรัพย์สิน", subCodes: ["exp.common", "exp.utilities", "exp.repair", "exp.furnishing", "exp.cleaning"] },
      { line: "เงินสดจ่ายค่าใช้จ่ายในการขาย", subCodes: ["exp.commission", "exp.referral", "exp.marketing"] },
      { line: "เงินสดจ่ายค่าใช้จ่ายบริหาร", subCodes: ["exp.land_office", "exp.tax", "exp.legal", "exp.bank_charge", "exp.salary", "exp.travel", "exp.office", "exp.other"] },
      { line: "เงินสดจ่ายเจ้าหนี้ค้างจ่าย", subCodes: ["fin.pay_payable"] },
      { line: "เงินมัดจำจ่ายและรับคืน", subCodes: ["inv.deposit_paid", "inv.deposit_returned"] },
      { line: "เงินมัดจำผู้เช่า รับและคืน", subCodes: ["fin.deposit_received", "fin.deposit_refund"] },
      // แยกจาก "เงินสดรับจากเงินปันผล" โดยตั้งใจ — ตัวนี้ถูกตัดออกในงบกองกลางรวม
      // ถ้ารวมบรรทัดกัน จะมองไม่ออกว่ายอดไหนหายไปเพราะการตัดรายการระหว่างกัน
      { line: "เงินปันผลรับจากกิจการในกองกลาง", subCodes: [], legs: [{ nature: "dividend", side: "receiver" }] },
    ],
  },
  {
    section: "investing",
    title: "กระแสเงินสดจากกิจกรรมลงทุน",
    lines: [
      { line: "ซื้ออสังหาริมทรัพย์และปรับปรุง", subCodes: ["inv.buy_re", "inv.capex"] },
      { line: "ขายอสังหาริมทรัพย์", subCodes: ["inv.sell_re"] },
      { line: "ปล่อยเงินขายฝาก จำนอง และให้กู้", subCodes: ["inv.srr_out", "inv.mortgage_out", "inv.lend"] },
      // เงินต้นที่รับคืน **ไม่ใช่รายได้** — ดอกเบี้ยอยู่ฝั่งดำเนินงานคนละบรรทัด
      { line: "รับคืนเงินต้น ขายฝาก จำนอง และเงินให้กู้", subCodes: ["inv.srr_redeem", "inv.mortgage_redeem", "inv.loan_back"] },
      { line: "ซื้อหลักทรัพย์และทองคำ", subCodes: ["inv.buy_securities", "inv.buy_commodity"] },
      { line: "ขายหลักทรัพย์และทองคำ", subCodes: ["inv.sell_securities", "inv.sell_commodity"] },
      { line: "เงินจ่ายให้กิจการในกองกลาง (ทดรอง กู้ยืม เพิ่มทุน)", subCodes: [],
        legs: [{ nature: "advance", side: "payer" }, { nature: "loan", side: "payer" }, { nature: "capital", side: "payer" }] },
    ],
  },
  {
    section: "financing",
    title: "กระแสเงินสดจากกิจกรรมจัดหาเงิน",
    lines: [
      { line: "เงินกู้รับ", subCodes: ["fin.loan_bank", "fin.loan_director", "fin.loan_other"] },
      { line: "ชำระคืนเงินต้น", subCodes: ["fin.repay_bank", "fin.repay_director"] },
      // ดอกเบี้ยจ่ายอยู่ฝั่งจัดหาเงินตามที่ตารางกฎจัดไว้ ไม่ใช่ฝั่งดำเนินงาน
      // **เป็นทางเลือกนโยบาย ไม่ใช่ข้อเท็จจริง** และทำให้กระแสเงินสดจากการ
      // ดำเนินงานดูดีกว่าแบบที่จัดไว้ฝั่งดำเนินงาน · ถ้าจะย้าย ต้องย้ายที่ตารางกฎ
      // (`cashflow` ของ `fin.interest_paid`) ไม่ใช่ย้ายที่นี่ ไม่งั้นกฎจะอยู่สองที่
      { line: "ดอกเบี้ยจ่าย", subCodes: ["fin.interest_paid"] },
      { line: "เพิ่มทุน", subCodes: ["fin.capital"] },
      { line: "ถอนทุน / จ่ายปันผล", subCodes: ["fin.drawings"] },
      { line: "เงินรับจากกิจการในกองกลาง (ทดรอง กู้ยืม เพิ่มทุน)", subCodes: [],
        legs: [{ nature: "advance", side: "receiver" }, { nature: "loan", side: "receiver" }, { nature: "capital", side: "receiver" }] },
      { line: "จ่ายปันผลให้กิจการในกองกลาง", subCodes: [], legs: [{ nature: "dividend", side: "payer" }] },
    ],
  },
];

export const CF_SECTION_TH: Record<Exclude<CashflowSection, "none">, string> = {
  operating: "ดำเนินงาน",
  investing: "ลงทุน",
  financing: "จัดหาเงิน",
};

/** รหัสหมวดทั้งหมดที่โครงงบกระแสเงินสดอ้างถึง */
export function cfSubCodes(): string[] {
  return CF_LAYOUT.flatMap((s) => s.lines.flatMap((l) => l.subCodes));
}

/** บรรทัดในงบกระแสเงินสดที่หมวดนี้ไปโผล่ */
export function cashflowLineOf(subCode: string): { section: Exclude<CashflowSection, "none">; title: string; line: string } {
  for (const s of CF_LAYOUT) {
    for (const l of s.lines) {
      if (l.subCodes.includes(subCode)) return { section: s.section, title: s.title, line: l.line };
    }
  }
  throw new Error(
    `หมวด ${subCode} ไม่อยู่ในโครงงบกระแสเงินสด — เพิ่มใน CF_LAYOUT ก่อน ` +
      `(ถ้าหมวดนี้ไม่ควรเข้างบกระแสเงินสด ให้ตั้ง cashflow: "none" ในตารางกฎ)`,
  );
}

/**
 * บรรทัดในงบของขารายการข้ามผู้ถือ
 *
 * ฝั่งผู้เรียกรู้ `nature` จากหัวรายการ และรู้ `side` จากบัญชีคู่ของขานั้น
 * (`INTERCOMPANY_RULES[nature].payer.coa` vs `.receiver.coa`)
 * **ห้ามตัดสิน side จากทิศของเงิน** เพราะใบกลับรายการสลับทิศ แล้วยอดจะไปลง
 * บรรทัดของฝ่ายตรงข้าม ทำให้ต้นฉบับกับใบกลับรายการไม่หักกันในบรรทัดเดียว
 */
export function cashflowLineOfLeg(
  nature: IntercompanyNature,
  side: "payer" | "receiver",
): { section: Exclude<CashflowSection, "none">; title: string; line: string } {
  for (const s of CF_LAYOUT) {
    for (const l of s.lines) {
      if (l.legs?.some((g) => g.nature === nature && g.side === side)) {
        return { section: s.section, title: s.title, line: l.line };
      }
    }
  }
  throw new Error(
    `ขารายการข้ามผู้ถือ ${nature}/${side} ไม่อยู่ในโครงงบกระแสเงินสด — เพิ่มใน CF_LAYOUT ก่อน`,
  );
}

/**
 * ช่องว่างของโครงงบกระแสเงินสด — ใช้ในเทสต์
 *
 * `missing`    หมวดที่เข้างบกระแสเงินสดได้ แต่โครงงบไม่มี → ยอดจะหายจากรายงานเงียบๆ
 * `duplicated` หมวดที่อยู่สองบรรทัด → ยอดถูกนับซ้ำ
 * `unknown`    โครงงบอ้างหมวดที่ไม่มีในตารางกฎ → บรรทัดว่างตลอดกาล
 * `wrongSection` หมวดที่อยู่ผิดส่วนจาก `cashflow` ของตัวเอง → **ร้ายแรงสุด**
 *   เพราะยอดรวมของงบยังถูก แต่กระแสเงินสดจากการดำเนินงานผิด ซึ่งเป็นตัวเลข
 *   ที่ใช้ตัดสินว่าธุรกิจเลี้ยงตัวเองได้หรือไม่
 */
export function findCashflowLayoutGaps(): {
  missing: string[];
  duplicated: string[];
  unknown: string[];
  wrongSection: { subCode: string; inLayout: string; inRules: string }[];
  /** ขารายการข้ามผู้ถือที่โครงงบไม่มีบรรทัดรองรับ → ยอดหลุดไปอยู่บรรทัดตกหล่น */
  missingLegs: string[];
  /** ขาที่อยู่สองบรรทัด → ยอดถูกนับซ้ำ */
  duplicatedLegs: string[];
  /** ขาที่อยู่ผิดส่วนจาก `intercompany.ts` → ยอดรวมถูกแต่ส่วนผิด */
  wrongSectionLegs: { leg: string; inLayout: string; inRules: string }[];
} {
  const subs = TX_TYPES.flatMap((t) => t.subs);
  const ruleSection = new Map(subs.map((s) => [s.code, s.cashflow]));

  const seen = new Map<string, number>();
  for (const c of cfSubCodes()) seen.set(c, (seen.get(c) ?? 0) + 1);

  const wrongSection: { subCode: string; inLayout: string; inRules: string }[] = [];
  for (const sec of CF_LAYOUT) {
    for (const l of sec.lines) {
      for (const c of l.subCodes) {
        const r = ruleSection.get(c);
        if (r !== undefined && r !== sec.section) {
          wrongSection.push({ subCode: c, inLayout: sec.section, inRules: r });
        }
      }
    }
  }

  // ---------- ขารายการข้ามผู้ถือ ----------
  // ครอบ `intercompany.ts` ด้วยโดยตั้งใจ · ไฟล์นี้หลุดจากเครื่องตรวจมาแล้วสองครั้ง
  // (D-096 `sync:rules` ไม่ครอบ · และโครงงบนี้ตอนแรกก็ไม่ครอบ)
  const legKey = (n: string, sd: string) => `${n}/${sd}`;
  const ruleLegs = new Map<string, Exclude<CashflowSection, "none">>();
  for (const [nature, rule] of Object.entries(INTERCOMPANY_RULES)) {
    for (const side of ["payer", "receiver"] as const) {
      ruleLegs.set(legKey(nature, side), rule[side].cashflow as Exclude<CashflowSection, "none">);
    }
  }
  const seenLegs = new Map<string, number>();
  const wrongSectionLegs: { leg: string; inLayout: string; inRules: string }[] = [];
  for (const sec of CF_LAYOUT) {
    for (const l of sec.lines) {
      for (const g of l.legs ?? []) {
        const k = legKey(g.nature, g.side);
        seenLegs.set(k, (seenLegs.get(k) ?? 0) + 1);
        const r = ruleLegs.get(k);
        if (r !== undefined && r !== sec.section) {
          wrongSectionLegs.push({ leg: k, inLayout: sec.section, inRules: r });
        }
      }
    }
  }

  return {
    // หมวดที่ cashflow เป็น "none" ต้อง **ไม่** อยู่ในโครงงบ (โอนระหว่างบัญชีตัวเอง)
    missing: subs.filter((s) => s.cashflow !== "none" && !seen.has(s.code)).map((s) => s.code),
    missingLegs: [...ruleLegs.keys()].filter((k) => !seenLegs.has(k)),
    duplicatedLegs: [...seenLegs.entries()].filter(([, n]) => n > 1).map(([k]) => k),
    wrongSectionLegs,
    duplicated: [...seen.entries()].filter(([, n]) => n > 1).map(([c]) => c),
    unknown: [...seen.keys()].filter((c) => !ruleSection.has(c) || ruleSection.get(c) === "none"),
    wrongSection,
  };
}
