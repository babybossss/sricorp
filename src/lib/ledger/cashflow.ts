/**
 * งบกระแสเงินสด **วิธีตรง** (direct method)
 *
 * อินพุตคือ **รายการที่อ่านมาจากสมุด** ไม่ใช่สิ่งที่ฟอร์มกรอก —
 * ไฟล์นี้จึงไม่เรียก `buildPosting()` และไม่สร้างบรรทัดบัญชีใดๆ เลย
 *
 * ============================================================
 * **อ่านของที่เก็บไว้ ห้ามคำนวณใหม่จากตารางกฎ**
 * ============================================================
 * แพทเทิร์นเดียวกับ `reversal.ts` และด้วยเหตุผลเดียวกัน:
 * ตารางกฎเปลี่ยนได้ตามเวลา แต่สิ่งที่เกิดขึ้นในอดีตเปลี่ยนไม่ได้
 *
 * - **ส่วน** (ดำเนินงาน/ลงทุน/จัดหาเงิน) มาจาก `cfCategory` ที่เก็บไว้ในบรรทัดเงินสด
 * - **ชื่อบรรทัด** มาจากโครงงบ `cashflowLineOf(subCode)` (`src/lib/rules/statements.ts`)
 *   ยกเว้น **ขาของรายการข้ามผู้ถือ** ที่ใช้ `cashflowLineOfLeg(nature, side)` เพราะคีย์
 *   คนละชุด (หมวดเป็น `trf.internal` ที่ `cashflow: "none"` แต่เงินเคลื่อนจริงของแต่ละฝ่าย)
 *   และ `side` ตัดสินจาก **บัญชีคู่** เทียบกับ `INTERCOMPANY_RULES` ไม่ใช่จากทิศของเงิน
 * - ถ้าสองอย่างนี้ **ขัดกัน** → ยึดของที่เก็บไว้ (ประวัติชนะ) **แต่ต้องรายงานเป็น
 *   ความผิดปกติ** ห้ามเลือกข้างเงียบๆ เพราะข้างที่เลือกผิดคือกระแสเงินสดจากการ
 *   ดำเนินงาน ซึ่งเป็นตัวเลขที่ใช้ตัดสินว่าธุรกิจเลี้ยงตัวเองได้หรือไม่
 *
 * ## กฎที่ไฟล์นี้บังคับ
 *
 * 1. นับเฉพาะ `status = 'posted'` · `void` ตัดออกจากงบ (D-098 คำสั่งลูกพี่)
 *    **แต่ใบกลับรายการ (`source = 'reverse'`) นับ** เพราะเป็นขาที่ทำให้สุทธิเป็นศูนย์
 *    (D-097 เตือนตรงๆ ว่าห้ามกรองออก) — ไฟล์นี้จึง **ไม่อ่าน `source` เพื่อกรองเลย**
 * 2. วันที่ที่ตัดสินว่าอยู่งวดไหนคือ **`cashDate` ไม่ใช่ `docDate`**
 *    `cashDate = null` คือ "เงินยังไม่เคลื่อน" (ค้างรับ-ค้างจ่าย) → ไม่เข้างบ
 * 3. จำนวนเงินของบรรทัด = **ยอดสุทธิของบรรทัดเงินสด (11xx) ของรายการนั้นทั้งก้อน**
 *    ห้ามแบ่งตามบัญชีคู่ — ขายอสังหา 8 ล้าน (ตัดทรัพย์ 6 + กำไร 2) คือ 8 ล้าน
 *    ในกิจกรรมลงทุน ไม่ใช่ 6 ลงทุน + 2 ดำเนินงาน
 *    ใครคือบรรทัดเงินสดตัดสินด้วย `isCashAccount()` ตัวเดียวกับที่ทั้งระบบใช้
 * 4. **สองมุมมอง** — งบรายผู้ถือเห็นการโอนข้ามผู้ถือทั้งสองฝ่าย (เงินออก/เข้าจริง)
 *    ส่วนงบรวมตัดออก **เฉพาะเมื่อผู้ถืออีกฝ่ายอยู่ในชุดที่กำลังรวมด้วย**
 *    ถ้าอีกฝ่ายอยู่นอกชุด เงินออกจากกลุ่มนั้นจริง → **ห้ามตัด**
 *    (ตัดสินจาก `ownerIds` ที่ผู้เรียกส่งมา ชุดเดียวจึงใช้ได้ทั้งสองมุมมอง)
 *
 * ## ด่านกระทบยอด — สำคัญที่สุดในไฟล์นี้
 *
 * ผลรวมสามส่วนต้องเท่ากับ **เงินสดปลายงวด − เงินสดต้นงวด** ซึ่งคำนวณจาก
 * **บรรทัด 11xx ทั้งหมด คนละทางกับงบ**: ไม่สนใจ `cfCategory` · ไม่สนใจ `subCode` ·
 * ไม่ตัดรายการระหว่างกัน · และลงวันที่ด้วย `cashDate ?? docDate` (คือวันที่ยอดเงินสด
 * ในงบดุลขยับจริง)
 *
 * ด่านนี้มีไว้จับรูแบบที่เจอเมื่อ 09/10: **ใบกลับรายการที่ไม่มี `cashDate`** ทำให้
 * งบดุลหักกันหมดแต่งบกระแสเงินสดค้างยอดไว้ตลอดกาล (งบดุล 0.00 · CF +5,000)
 * รูแบบอื่นที่ด่านเดียวกันจับได้: บรรทัดเงินสดที่ `cfCategory = 'none'` ทั้งที่เงิน
 * เคลื่อนจริงข้างเดียว · การตัดรายการระหว่างกันที่เงินสดสองขาไม่หักกันเป็นศูนย์
 *
 * **ไม่กระทบยอด = คืน `reconciled: false` + `difference` + `anomalies`**
 * ห้ามโยน error ทิ้งทั้งงบ (งบที่ลงไม่ตรงยังต้องดูได้เพื่อหาสาเหตุ)
 * และห้ามคืนตัวเลขเฉยๆ เหมือนไม่มีอะไรเกิดขึ้น
 *
 * ## เศษสตางค์
 * บวกกันบน **จำนวนเต็มสตางค์** ทั้งหมด แล้วแปลงเป็นบาทตอนคืนค่าเท่านั้น
 * (แพทเทิร์นเดียวกับ `cost-basis.ts`) จึงเป็นการ **ปัดยอดรวม ไม่ใช่ปัดทีละบรรทัด
 * แล้วบวก** — ผลรวมของบรรทัดจึงเท่ากับยอดรวมเสมอ ไม่มี 0.1 + 0.2 = 0.30000000000000004
 */

import { isCashAccount } from "@/lib/rules/coa";
import { INTERCOMPANY_RULES, type IntercompanyNature } from "@/lib/rules/intercompany";
import { CF_LAYOUT, CF_SECTION_TH, cashflowLineOf, cashflowLineOfLeg } from "@/lib/rules/statements";
import type { CashflowSection } from "@/lib/rules/tx-rules";
import { assertIsoDate, round2 } from "./guards";
import type { TxnStatus } from "./reversal";
import { PostingError } from "./types";

/** ส่วนของงบกระแสเงินสด — `none` ไม่ใช่ส่วน แต่คือ "ไม่เข้างบนี้" */
export type CfSectionKey = Exclude<CashflowSection, "none">;

/** ที่มาของรายการ — ชนิดเดียวกับ `sri_os.txn_source` */
export type TxnSource = "manual" | "schedule" | "payroll" | "reimburse" | "import" | "reverse";

/** ฝ่ายของขารายการข้ามผู้ถือ — ตัดสินจาก **บัญชีคู่** ห้ามตัดสินจากทิศของเงิน */
export type LegSide = "payer" | "receiver";

const TXN_SOURCES: TxnSource[] = ["manual", "schedule", "payroll", "reimburse", "import", "reverse"];
const IC_NATURES = Object.keys(INTERCOMPANY_RULES) as IntercompanyNature[];
const TXN_STATUSES: TxnStatus[] = ["posted", "void"];
const CF_CATEGORIES: CashflowSection[] = ["operating", "investing", "financing", "none"];

/**
 * บรรทัดบัญชีตามที่ **เก็บอยู่จริงในสมุด** (`transaction_lines`)
 *
 * `cfCategory` **บังคับ** ไม่ใช่ optional — บรรทัดในสมุดมีค่านี้เสมอ และถ้าปล่อยให้เว้นได้
 * ผู้เรียกจะเว้น แล้วรายการนั้นจะหลุดจากงบเงียบๆ (บทเรียน `mace-windu` ข้อ 2–3)
 */
export type CashflowSourceLine = {
  coaCode: string;
  debit: number;
  credit: number;
  cfCategory: CashflowSection;
};

/**
 * รายการหนึ่งใบตามที่อ่านมาจากสมุด — **ทุกฟิลด์บังคับ ไม่มี optional เลย**
 *
 * ค่าที่ "ไม่มี" ต้องส่ง `null` มาตรงๆ (`cashDate` · `counterOwnerId`) เพื่อให้
 * "ยังไม่ได้ตั้งค่า" กับ "ตั้งใจว่าไม่มี" แยกกันออก — ฟิลด์ที่หายไปทั้งคีย์คือ
 * ข้อมูลไม่ครบ ต้องปฏิเสธ ไม่ใช่แปลว่า null
 */
export type CashflowTxn = {
  txnId: string;
  ownerId: string;
  status: TxnStatus;
  /** `'reverse'` คือใบกลับรายการ — **มีไว้ให้รายงานแสดง ไม่ใช่ให้กรองออก** (D-097) */
  source: TxnSource;
  /** รหัสหมวดย่อยที่บันทึกไว้ — ใช้หา **ชื่อบรรทัด** เท่านั้น ไม่ใช้หาส่วน */
  subCode: string;
  /** วันที่เอกสาร (YYYY-MM-DD) — **ไม่ใช่** ตัวตัดสินงวดของงบนี้ */
  docDate: string;
  /** วันที่เงินเคลื่อนจริง · `null` = เงินยังไม่เคลื่อน (ค้างรับ-ค้างจ่าย) */
  cashDate: string | null;
  lines: CashflowSourceLine[];
  /** ผู้ถืออีกฝ่าย ถ้าใบนี้เป็นขาหนึ่งของรายการข้ามผู้ถือ · `null` ถ้าไม่ใช่ */
  counterOwnerId: string | null;
  /**
   * ลักษณะของรายการข้ามผู้ถือจากหัวรายการ · `null` ถ้าไม่ใช่รายการข้ามผู้ถือ
   *
   * **จำเป็น** เพราะขาข้ามผู้ถือใช้หมวด `trf.internal` ที่ตารางกฎตั้ง `cashflow: "none"`
   * บรรทัดในงบจึงหาด้วย `cashflowLineOfLeg(nature, side)` ไม่ใช่ `cashflowLineOf(subCode)`
   * และ `advance` กับ `loan` ใช้บัญชีคู่เดียวกัน (1310/2310) จึงแยกกันได้ด้วยฟิลด์นี้เท่านั้น
   */
  intercompanyNature: IntercompanyNature | null;
};

export type CashflowInput = {
  /**
   * รายการจากสมุด — ต้องรวม **รายการก่อนงวด** มาด้วย
   * เพราะเงินสดต้นงวดคำนวณจากบรรทัด 11xx ที่เกิดก่อนวันเริ่มงวด
   */
  txns: CashflowTxn[];
  /** YYYY-MM-DD · รวมวันนี้ */
  periodStart: string;
  /** YYYY-MM-DD · รวมวันนี้ */
  periodEnd: string;
  /**
   * ผู้ถือที่อยู่ในงบนี้ — หนึ่งคน = งบรายผู้ถือ · หลายคน = งบรวมของชุดนั้น
   * ชุดนี้คือตัวตัดสินว่ารายการข้ามผู้ถือจะถูกตัดหรือไม่ (ดูกฎข้อ 4 ด้านบน)
   */
  ownerIds: string[];
};

export type CashflowStatementLine = {
  line: string;
  /** หมวดที่โครงงบจัดไว้ให้บรรทัดนี้ · ว่างสำหรับบรรทัดที่โครงงบไม่มี */
  subCodes: string[];
  /** บาท · เงินเข้าเป็นบวก เงินออกเป็นลบ */
  amount: number;
  /** `false` = บรรทัดที่งอกขึ้นเพราะข้อมูลไม่ตรงโครงงบ (มี anomaly คู่กันเสมอ) */
  inLayout: boolean;
};

export type CashflowStatementSection = {
  section: CfSectionKey;
  title: string;
  /** ชื่อสั้นภาษาไทย จาก `CF_SECTION_TH` */
  sectionTh: string;
  lines: CashflowStatementLine[];
  total: number;
};

/**
 * ชนิดของความผิดปกติ — ทุกชนิดคือ "เงินกับงบไม่เล่าเรื่องเดียวกัน"
 *
 * `cashWithoutCashDate`      มีบรรทัดเงินสดแต่ไม่มี `cashDate` → งบดุลขยับ งบ CF ไม่ขยับ
 * `cashDateWithoutCashLine`  มี `cashDate` แต่ไม่มีบรรทัดเงินสด → วันที่เงินเคลื่อนของอะไร
 * `subCodeNotInLayout`       โครงงบไม่มีบรรทัดรองรับหมวด/ขานี้ → ยอดไปอยู่บรรทัดรวม
 * `intercompanySideUnknown`  ขาข้ามผู้ถือที่บัญชีคู่ไม่ตรงกับฝ่ายจ่ายหรือฝ่ายรับ → เดาฝ่ายไม่ได้
 * `sectionConflict`          `cfCategory` ที่เก็บไว้ขัดกับส่วนที่โครงงบบอก
 * `mixedCfCategory`          บรรทัดเงินสดของใบเดียวกันอยู่คนละส่วน
 * `cashOutsideStatement`     บรรทัดเงินสด `cfCategory = 'none'` ที่ไม่หักกันเป็นศูนย์
 * `intercompanyNotNetted`    คู่รายการระหว่างกันที่ตัดออกแล้วเงินสดไม่หักกันเป็นศูนย์
 * `unreconciled`             ด่านกระทบยอดไม่ผ่าน (สรุปรวม)
 */
export type CashflowAnomalyKind =
  | "cashWithoutCashDate"
  | "cashDateWithoutCashLine"
  | "subCodeNotInLayout"
  | "intercompanySideUnknown"
  | "sectionConflict"
  | "mixedCfCategory"
  | "cashOutsideStatement"
  | "intercompanyNotNetted"
  | "unreconciled";

export type CashflowAnomaly = {
  kind: CashflowAnomalyKind;
  /** `null` เมื่อเป็นความผิดปกติระดับงบ ไม่ใช่ของใบใดใบหนึ่ง */
  txnId: string | null;
  subCode: string | null;
  /** บาท · ยอดที่เกี่ยวข้องกับความผิดปกตินี้ */
  amount: number;
  /** ข้อความที่เอาไปขึ้นจอได้ตรงๆ */
  message: string;
};

export type EliminatedLeg = {
  txnId: string;
  ownerId: string;
  counterOwnerId: string;
  /** บาท · ยอดเงินสดสุทธิของขานี้ที่ถูกตัดออกจากงบรวม */
  amount: number;
};

export type CashflowStatement = {
  periodStart: string;
  periodEnd: string;
  ownerIds: string[];
  /** งบของผู้ถือมากกว่าหนึ่งราย = งบรวม (ตัดรายการระหว่างกันในชุดออก) */
  consolidated: boolean;
  sections: CashflowStatementSection[];
  /** ผลรวมสามส่วน = เงินสดเปลี่ยนแปลงสุทธิตามงบ */
  netChange: number;
  openingCash: number;
  closingCash: number;
  /** `netChange − (closingCash − openingCash)` · 0 = กระทบยอดลงตัว */
  difference: number;
  reconciled: boolean;
  /** ขาของรายการข้ามผู้ถือที่ถูกตัดออกจากงบรวม — ไว้ให้หน้าจอกดดูได้ */
  eliminated: EliminatedLeg[];
  anomalies: CashflowAnomaly[];
};

/** บรรทัดรวมของยอดที่โครงงบยังไม่มีที่ให้ลง — ต้องไม่ใช่ชื่อเดียวกับบรรทัดในโครงงบ */
export const CF_UNMAPPED_LINE = "รายการที่โครงงบยังไม่มีบรรทัดรองรับ";

const fail = (message: string): never => {
  throw new PostingError(message);
};

/* ------------------------------------------------------------------ *
 * ด่านข้อมูล — ข้อมูลไม่ครบต้องปฏิเสธ ไม่ใช่เดา
 * (บทเรียน `mace-windu` ข้อ 1: เดาแล้วตัวเลขผิดเงียบๆ)
 * ------------------------------------------------------------------ */

function has(o: Record<string, unknown>, key: string): boolean {
  return Object.prototype.hasOwnProperty.call(o, key);
}

function requireString(o: Record<string, unknown>, key: string, label: string): string {
  if (!has(o, key)) fail(`${label} ไม่ได้ส่งมา — อ่านงบกระแสเงินสดจากข้อมูลที่ไม่ครบไม่ได้`);
  const v = o[key];
  if (typeof v !== "string" || v.trim() === "") fail(`${label} ต้องมีค่า (ได้ ${JSON.stringify(v)})`);
  return (v as string).trim();
}

/** ค่าที่ "ไม่มี" ต้องเป็น `null` ที่ส่งมาตรงๆ · คีย์ที่หายไปคือข้อมูลไม่ครบ */
function requireNullableString(o: Record<string, unknown>, key: string, label: string): string | null {
  if (!has(o, key)) {
    fail(`${label} ไม่ได้ส่งมา — ถ้าไม่มีค่าต้องส่ง null มาตรงๆ ไม่ใช่เว้นคีย์ไว้`);
  }
  const v = o[key];
  if (v === null) return null;
  if (typeof v !== "string" || v.trim() === "") fail(`${label} ต้องเป็นข้อความหรือ null (ได้ ${JSON.stringify(v)})`);
  return (v as string).trim();
}

/** จำนวนเงินเป็นจำนวนเต็มสตางค์ — ติดลบไม่ได้ (เครื่องหมายมาจากเดบิต/เครดิต) */
function satangOf(v: unknown, label: string): number {
  if (typeof v !== "number" || !Number.isFinite(v)) fail(`${label} ต้องเป็นตัวเลขที่ระบุได้ (ได้ ${JSON.stringify(v)})`);
  const n = v as number;
  if (n < 0) fail(`${label} ติดลบไม่ได้ — เงินเข้าหรือออกตัดสินจากเดบิต/เครดิต`);
  return Math.round(round2(n) * 100);
}

const toBaht = (satang: number): number => round2(satang / 100);

function assertLine(raw: unknown, txnId: string, index: number): CashflowSourceLine {
  if (typeof raw !== "object" || raw === null) {
    fail(`บรรทัดที่ ${index + 1} ของรายการ ${txnId} ไม่ใช่ข้อมูลบรรทัดบัญชี`);
  }
  const o = raw as Record<string, unknown>;
  const where = `บรรทัดที่ ${index + 1} ของรายการ ${txnId}`;
  const coaCode = requireString(o, "coaCode", `รหัสบัญชีของ${where}`);

  if (!has(o, "cfCategory")) {
    fail(
      `${where} ไม่มี cfCategory — ส่วนของงบกระแสเงินสดต้องอ่านจากที่เก็บไว้ ` +
        "ห้ามคำนวณใหม่จากตารางกฎ จึงเดาแทนไม่ได้"
    );
  }
  const cfCategory = o.cfCategory as CashflowSection;
  if (!CF_CATEGORIES.includes(cfCategory)) {
    fail(`${where} มี cfCategory ที่ไม่รู้จัก: ${JSON.stringify(o.cfCategory)}`);
  }

  return {
    coaCode,
    debit: satangOf(has(o, "debit") ? o.debit : undefined, `เดบิตของ${where}`) / 100,
    credit: satangOf(has(o, "credit") ? o.credit : undefined, `เครดิตของ${where}`) / 100,
    cfCategory,
  };
}

function assertTxn(raw: unknown): CashflowTxn {
  if (typeof raw !== "object" || raw === null) fail("รายการในสมุดต้องเป็นข้อมูลรายการ");
  const o = raw as Record<string, unknown>;

  const txnId = requireString(o, "txnId", "id ของรายการ");
  const ownerId = requireString(o, "ownerId", `ผู้ถือของรายการ ${txnId}`);

  const status = requireString(o, "status", `สถานะของรายการ ${txnId}`) as TxnStatus;
  if (!TXN_STATUSES.includes(status)) {
    fail(`รายการ ${txnId} มีสถานะ "${status}" ซึ่งไม่ใช่สถานะของรายการในสมุด`);
  }
  const source = requireString(o, "source", `ที่มาของรายการ ${txnId}`) as TxnSource;
  if (!TXN_SOURCES.includes(source)) fail(`รายการ ${txnId} มีที่มา "${source}" ที่ไม่รู้จัก`);

  const subCode = requireString(o, "subCode", `หมวดย่อยของรายการ ${txnId}`);
  const docDate = assertIsoDate(
    requireString(o, "docDate", `วันที่เอกสารของรายการ ${txnId}`),
    `วันที่เอกสารของรายการ ${txnId}`
  );
  const rawCashDate = requireNullableString(o, "cashDate", `วันที่เงินเคลื่อนของรายการ ${txnId}`);
  const cashDate =
    rawCashDate === null ? null : assertIsoDate(rawCashDate, `วันที่เงินเคลื่อนของรายการ ${txnId}`);
  const counterOwnerId = requireNullableString(o, "counterOwnerId", `ผู้ถืออีกฝ่ายของรายการ ${txnId}`);

  const rawNature = requireNullableString(o, "intercompanyNature", `ลักษณะรายการข้ามผู้ถือของรายการ ${txnId}`);
  const intercompanyNature = rawNature === null ? null : (rawNature as IntercompanyNature);
  if (intercompanyNature !== null && !IC_NATURES.includes(intercompanyNature)) {
    fail(`รายการ ${txnId} มีลักษณะรายการข้ามผู้ถือ "${rawNature}" ที่ไม่มีใน intercompany.ts`);
  }
  // ขาข้ามผู้ถือต้องมาเป็นคู่เสมอ (1 transaction = 1 owner) — มีลักษณะแต่ไม่มีอีกฝ่าย
  // แปลว่าข้อมูลหัวรายการไม่ครบ ตัดสินไม่ได้ว่าจะตัดในงบรวมหรือไม่ จึงต้องปฏิเสธ
  if (intercompanyNature !== null && counterOwnerId === null) {
    fail(`รายการ ${txnId} ระบุลักษณะรายการข้ามผู้ถือ (${intercompanyNature}) แต่ไม่มีผู้ถืออีกฝ่าย`);
  }

  if (!has(o, "lines") || !Array.isArray(o.lines) || o.lines.length === 0) {
    fail(`รายการ ${txnId} ไม่มีบรรทัดบัญชี — รายการในสมุดต้องมีอย่างน้อยสองบรรทัด`);
  }
  const lines = (o.lines as unknown[]).map((l, i) => assertLine(l, txnId, i));

  return {
    txnId,
    ownerId,
    status,
    source,
    subCode,
    docDate,
    cashDate,
    lines,
    counterOwnerId,
    intercompanyNature,
  };
}

function assertOwnerIds(raw: unknown): string[] {
  if (!Array.isArray(raw) || raw.length === 0) {
    fail("ต้องระบุผู้ถืออย่างน้อยหนึ่งราย — ชุดผู้ถือคือตัวตัดสินว่าตัดรายการระหว่างกันหรือไม่");
  }
  const ids = (raw as unknown[]).map((v, i) => {
    if (typeof v !== "string" || v.trim() === "") fail(`ผู้ถือลำดับที่ ${i + 1} ไม่มีค่า`);
    return (v as string).trim();
  });
  const dup = ids.filter((id, i) => ids.indexOf(id) !== i);
  if (dup.length > 0) fail(`ผู้ถือซ้ำในชุดที่รวม: ${[...new Set(dup)].join(", ")} — ยอดจะถูกนับซ้ำ`);
  return ids;
}

/* ------------------------------------------------------------------ *
 * ถังยอดของแต่ละบรรทัด — เริ่มจากโครงงบทั้งใบ เพื่อให้บรรทัดที่ยอดเป็นศูนย์ยังแสดง
 * ------------------------------------------------------------------ */

type Bucket = { line: string; subCodes: string[]; inLayout: boolean; satang: number };

/** คีย์ของบรรทัดที่งอกขึ้นเอง ต้องไม่ชนกับบรรทัดในโครงงบที่ชื่อเดียวกัน */
const extraKey = (line: string) => `\u0000extra\u0000${line}`;

function seedBuckets(): Map<CfSectionKey, Map<string, Bucket>> {
  const out = new Map<CfSectionKey, Map<string, Bucket>>();
  for (const sec of CF_LAYOUT) {
    const m = new Map<string, Bucket>();
    for (const l of sec.lines) {
      m.set(l.line, { line: l.line, subCodes: [...l.subCodes], inLayout: true, satang: 0 });
    }
    out.set(sec.section, m);
  }
  return out;
}

function addTo(
  buckets: Map<CfSectionKey, Map<string, Bucket>>,
  section: CfSectionKey,
  line: string,
  inLayout: boolean,
  satang: number
): void {
  const m = buckets.get(section);
  if (!m) throw new Error(`โครงงบกระแสเงินสดไม่มีส่วน ${section}`);
  const key = inLayout ? line : extraKey(line);
  const existing = m.get(key);
  if (existing) existing.satang += satang;
  else m.set(key, { line, subCodes: [], inLayout, satang });
}

type LineTarget = { section: CfSectionKey; line: string };

/** โครงงบรู้จักหมวดนี้ไหม — `cashflowLineOf()` โยนเมื่อไม่รู้จัก จึงห่อไว้ที่เดียว */
function layoutOf(subCode: string): LineTarget | null {
  try {
    const l = cashflowLineOf(subCode);
    return { section: l.section, line: l.line };
  } catch {
    return null;
  }
}

/** บรรทัดของขารายการข้ามผู้ถือ — คีย์คนละชุดกับหมวดย่อย (ดู `CfLine.legs`) */
function legLayoutOf(nature: IntercompanyNature, side: LegSide): LineTarget | null {
  try {
    const l = cashflowLineOfLeg(nature, side);
    return { section: l.section, line: l.line };
  } catch {
    return null;
  }
}

/**
 * ขานี้เป็นฝ่ายจ่ายหรือฝ่ายรับ — ตัดสินจาก **บัญชีคู่** ของขานั้น
 *
 * **ห้ามตัดสินจากทิศของเงิน** เพราะใบกลับรายการสลับทิศ ยอดจะไปลงบรรทัดของ
 * ฝ่ายตรงข้าม แล้วต้นฉบับกับใบกลับรายการจะไม่หักกันในบรรทัดเดียว (งบรวมยังเป็นศูนย์
 * แต่สองบรรทัดค้างยอดหักกลบกัน ซึ่งอ่านงบไม่รู้เรื่อง)
 *
 * `advance` กับ `loan` ใช้บัญชีคู่เดียวกัน (1310/2310) — แยกกันได้เพราะ `nature`
 * มาจากหัวรายการ ไม่ได้เดาจากบัญชี · ภายใน `nature` เดียว บัญชีของสองฝ่ายต่างกันเสมอ
 *
 * คืน `null` เมื่อบัญชีคู่ไม่ตรงกับทั้งสองฝ่าย หรือตรงทั้งคู่ → **เดาไม่ได้ ต้องดัง**
 */
function sideOfLeg(nature: IntercompanyNature, lines: CashflowSourceLine[]): LegSide | null {
  const rule = INTERCOMPANY_RULES[nature];
  const codes = new Set(lines.filter((l) => !isCashAccount(l.coaCode)).map((l) => l.coaCode));
  const isPayer = codes.has(rule.payer.coa);
  const isReceiver = codes.has(rule.receiver.coa);
  if (isPayer === isReceiver) return null;
  return isPayer ? "payer" : "receiver";
}

/* ------------------------------------------------------------------ *
 * ตัวคำนวณ
 * ------------------------------------------------------------------ */

export function buildCashflow(input: CashflowInput): CashflowStatement {
  if (typeof input !== "object" || input === null) fail("ต้องส่งข้อมูลนำเข้าของงบกระแสเงินสด");

  const periodStart = assertIsoDate(input.periodStart, "วันเริ่มงวด");
  const periodEnd = assertIsoDate(input.periodEnd, "วันสิ้นงวด");
  if (periodStart > periodEnd) fail(`งวดกลับหัว: ${periodStart} ถึง ${periodEnd}`);
  const ownerIds = assertOwnerIds(input.ownerIds);
  if (!Array.isArray(input.txns)) fail("รายการในสมุดต้องเป็นรายการ (array) — ถ้างวดว่างให้ส่ง []");

  const scope = new Set(ownerIds);
  const buckets = seedBuckets();
  const anomalies: CashflowAnomaly[] = [];
  const eliminated: EliminatedLeg[] = [];

  let openingSatang = 0;
  let closingSatang = 0;
  let eliminatedSatang = 0;

  const note = (
    kind: CashflowAnomalyKind,
    txnId: string | null,
    subCode: string | null,
    satang: number,
    message: string
  ) => anomalies.push({ kind, txnId, subCode, amount: toBaht(satang), message });

  for (const rawTxn of input.txns) {
    const t = assertTxn(rawTxn);

    // นอกชุดผู้ถือที่กำลังดู → ไม่ใช่เงินของงบใบนี้
    if (!scope.has(t.ownerId)) continue;
    // D-098: void ตัดออกจากงบทั้งใบ · **ไม่กรองด้วย `source`** ใบกลับรายการจึงยังนับ
    if (t.status !== "posted") continue;

    const cashLines = t.lines.filter((l) => isCashAccount(l.coaCode));
    const cashSatang = cashLines.reduce(
      (sum, l) => sum + Math.round(round2(l.debit) * 100) - Math.round(round2(l.credit) * 100),
      0
    );

    /* ---- เส้นทางกระทบยอด: บรรทัด 11xx ทั้งหมด ไม่สนใจ cfCategory/subCode ----
       ลงวันที่ด้วย `cashDate ?? docDate` = วันที่ยอดเงินสดในงบดุลขยับจริง
       จึงจับใบที่มีบรรทัดเงินสดแต่ลืม `cashDate` ได้ */
    const bookDate = t.cashDate ?? t.docDate;
    if (bookDate < periodStart) openingSatang += cashSatang;
    if (bookDate <= periodEnd) closingSatang += cashSatang;

    /* ---- เส้นทางงบ: ตัดสินด้วย `cashDate` เท่านั้น ---- */
    if (t.cashDate === null) {
      if (cashLines.length > 0 && t.docDate >= periodStart && t.docDate <= periodEnd) {
        note(
          "cashWithoutCashDate",
          t.txnId,
          t.subCode,
          cashSatang,
          `รายการ ${t.txnId} มีบรรทัดเงินสดแต่ไม่มีวันที่เงินเคลื่อน — ` +
            "ยอดเงินสดในงบดุลขยับแล้วแต่งบกระแสเงินสดไม่เห็น จึงกระทบยอดไม่ลง"
        );
      }
      continue;
    }
    if (t.cashDate < periodStart || t.cashDate > periodEnd) continue;

    if (cashLines.length === 0) {
      note(
        "cashDateWithoutCashLine",
        t.txnId,
        t.subCode,
        0,
        `รายการ ${t.txnId} ระบุวันที่เงินเคลื่อน (${t.cashDate}) แต่ไม่มีบรรทัดเงินสดเลย — ` +
          "ถ้าเป็นรายการค้างรับ-ค้างจ่าย วันที่เงินเคลื่อนต้องเป็น null"
      );
      continue;
    }

    // ตัดรายการระหว่างกัน **เฉพาะเมื่ออีกฝ่ายอยู่ในชุดที่รวมด้วย**
    if (t.counterOwnerId !== null && scope.has(t.counterOwnerId)) {
      eliminated.push({
        txnId: t.txnId,
        ownerId: t.ownerId,
        counterOwnerId: t.counterOwnerId,
        amount: toBaht(cashSatang),
      });
      eliminatedSatang += cashSatang;
      continue;
    }

    // จัดกลุ่มตาม `cfCategory` ที่เก็บไว้ — **ไม่ใช่ตามบัญชีคู่** (เงินก้อนเดียวบรรทัดเดียว)
    const byCategory = new Map<CashflowSection, number>();
    for (const l of cashLines) {
      const d = Math.round(round2(l.debit) * 100) - Math.round(round2(l.credit) * 100);
      byCategory.set(l.cfCategory, (byCategory.get(l.cfCategory) ?? 0) + d);
    }
    const moving = [...byCategory.entries()].filter(([, s]) => s !== 0);

    if (moving.length > 1) {
      note(
        "mixedCfCategory",
        t.txnId,
        t.subCode,
        cashSatang,
        `รายการ ${t.txnId} มีบรรทัดเงินสดอยู่คนละหมวดกระแสเงินสด ` +
          `(${moving.map(([c]) => c).join(" · ")}) — เงินก้อนเดียวของรายการเดียวควรอยู่หมวดเดียว`
      );
    }

    /* ---- บรรทัดของรายการนี้ ----
       ขารายการข้ามผู้ถือใช้คีย์คนละชุดกับหมวดย่อย: หมวดคือ `trf.internal`
       (`cashflow: "none"`) แต่ของจริงเป็นกระแสเงินสดของแต่ละฝ่าย จึงต้องหาบรรทัด
       ด้วย `cashflowLineOfLeg(nature, side)` ไม่ใช่ `cashflowLineOf(subCode)` */
    let target: LineTarget | null;
    let unmappedKind: CashflowAnomalyKind;
    let unmappedWhy: string;
    if (t.intercompanyNature !== null) {
      const side = sideOfLeg(t.intercompanyNature, t.lines);
      if (side === null) {
        target = null;
        unmappedKind = "intercompanySideUnknown";
        unmappedWhy =
          `รายการ ${t.txnId} เป็นขาข้ามผู้ถือลักษณะ ${t.intercompanyNature} ` +
          `แต่บัญชีคู่ไม่ตรงกับฝ่ายจ่าย (${INTERCOMPANY_RULES[t.intercompanyNature].payer.coa}) ` +
          `หรือฝ่ายรับ (${INTERCOMPANY_RULES[t.intercompanyNature].receiver.coa}) — ` +
          "ตัดสินฝ่ายจากบัญชีคู่ไม่ได้ และห้ามเดาจากทิศของเงินเพราะใบกลับรายการสลับทิศ";
      } else {
        target = legLayoutOf(t.intercompanyNature, side);
        unmappedKind = "subCodeNotInLayout";
        unmappedWhy = `ขาข้ามผู้ถือ ${t.intercompanyNature}/${side} ไม่มีบรรทัดในโครงงบกระแสเงินสด`;
      }
    } else {
      target = layoutOf(t.subCode);
      unmappedKind = "subCodeNotInLayout";
      unmappedWhy = `หมวด ${t.subCode} ไม่มีบรรทัดในโครงงบกระแสเงินสด`;
    }

    for (const [category, satang] of moving) {
      if (category === "none") {
        note(
          "cashOutsideStatement",
          t.txnId,
          t.subCode,
          satang,
          `รายการ ${t.txnId} มีเงินสดเคลื่อนสุทธิ ${toBaht(satang)} บาท ` +
            'แต่ cfCategory เป็น "none" (ไม่เข้างบ) — ถ้าไม่ใช่การโอนระหว่างบัญชีตัวเอง ยอดนี้หายจากงบ'
        );
        continue;
      }

      const layout = target;
      if (!layout) {
        note(
          unmappedKind,
          t.txnId,
          t.subCode,
          satang,
          `${unmappedWhy} — ยอดไปรวมที่ "${CF_UNMAPPED_LINE}" ของกิจกรรม${CF_SECTION_TH[category]}`
        );
        addTo(buckets, category, CF_UNMAPPED_LINE, false, satang);
        continue;
      }
      if (layout.section !== category) {
        note(
          "sectionConflict",
          t.txnId,
          t.subCode,
          satang,
          `หมวด ${t.subCode} เก็บไว้เป็นกิจกรรม${CF_SECTION_TH[category]} ` +
            `แต่โครงงบจัดไว้ที่กิจกรรม${CF_SECTION_TH[layout.section]} — ` +
            "ยึดของที่เก็บไว้ (ประวัติเปลี่ยนไม่ได้) แต่ต้องตรวจว่าตารางกฎเปลี่ยนไปหรือลงผิด"
        );
        addTo(buckets, category, layout.line, false, satang);
        continue;
      }
      addTo(buckets, category, layout.line, true, satang);
    }
  }

  if (eliminatedSatang !== 0) {
    note(
      "intercompanyNotNetted",
      null,
      null,
      eliminatedSatang,
      `ตัดรายการระหว่างกันในชุดที่รวมออกแล้ว แต่เงินสดสองขาไม่หักกันเป็นศูนย์ ` +
        `(เหลือ ${toBaht(eliminatedSatang)} บาท) — เงินอาจออกจากกลุ่มจริง หรือส่งขามาไม่ครบคู่`
    );
  }

  const sections: CashflowStatementSection[] = CF_LAYOUT.map((sec) => {
    const m = buckets.get(sec.section)!;
    const lines = [...m.values()].map((b) => ({
      line: b.line,
      subCodes: b.subCodes,
      amount: toBaht(b.satang),
      inLayout: b.inLayout,
    }));
    const totalSatang = [...m.values()].reduce((s, b) => s + b.satang, 0);
    return {
      section: sec.section,
      title: sec.title,
      sectionTh: CF_SECTION_TH[sec.section],
      lines,
      total: toBaht(totalSatang),
    };
  });

  const netSatang = [...buckets.values()]
    .flatMap((m) => [...m.values()])
    .reduce((s, b) => s + b.satang, 0);
  const differenceSatang = netSatang - (closingSatang - openingSatang);
  const reconciled = differenceSatang === 0;

  if (!reconciled) {
    note(
      "unreconciled",
      null,
      null,
      differenceSatang,
      `งบกระแสเงินสดไม่กระทบยอด: ผลรวมสามส่วน ${toBaht(netSatang)} บาท ` +
        `แต่เงินสดปลายงวดลบต้นงวด ${toBaht(closingSatang - openingSatang)} บาท ` +
        `(ต่างกัน ${toBaht(differenceSatang)} บาท) — ตัวเลขในงบยังดูได้ แต่ห้ามส่งออกก่อนหาสาเหตุ`
    );
  }

  return {
    periodStart,
    periodEnd,
    ownerIds,
    consolidated: ownerIds.length > 1,
    sections,
    netChange: toBaht(netSatang),
    openingCash: toBaht(openingSatang),
    closingCash: toBaht(closingSatang),
    difference: toBaht(differenceSatang),
    reconciled,
    eliminated,
    anomalies,
  };
}
