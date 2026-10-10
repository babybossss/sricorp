/**
 * Backlog ข้อ 1 — ตารางกฎเดียวที่ระบบอ้างอิง
 *
 * ประเภทรายการ → หมวดย่อยที่อนุญาต → คู่บัญชี → ผลกระทบต่องบ
 *
 * กฎสำคัญ: หมวดย่อยไม่ใช่ dropdown อิสระ — เลือกได้เฉพาะที่ผูกกับประเภทรายการเท่านั้น
 * เช่น "กู้เงินเพิ่ม" อยู่ใต้ประเภท `finance_in` (จัดหาเงิน) เท่านั้น
 * จะเลือกจากประเภท `income` (รายได้) ไม่ได้ เพราะเงินเข้าบัญชีแต่ไม่ใช่รายได้
 *
 * ผลกระทบต่องบ (P&L / งบดุล) **คำนวณจากคู่บัญชี `dr`/`cr`** ไม่ได้พิมพ์มือ
 * จึงไม่มีทางที่คำอธิบายกับการลงบัญชีจริงจะไม่ตรงกัน
 *
 * ผังบัญชีและหมวดย่อยตรวจทานกับของจริงใน SRI_Transaction_ERP.xlsx (ชีท Setup)
 */

import { coa, coaLabel, isCashAccount, type CoaAccount } from "./coa";

export type TxTypeKey =
  | "income"
  | "expense"
  | "invest_buy"
  | "invest_sell"
  | "finance_in"
  | "finance_out"
  | "transfer"
  | "adjust";

/**
 * ทิศทางเงินสดของรายการ
 *
 * `none` = **ไม่มีขาเงินสดเลย** (รายการปรับปรุงทางบัญชี เช่น ตั้งค่าเผื่อ · ตัดหนี้สูญ)
 * ต่างจาก `both` ที่เงินเคลื่อนสองขาแต่ยอดรวมไม่เปลี่ยน (โอนระหว่างบัญชีตัวเอง)
 * ความต่างนี้มีผลจริง: `both` ยังต้องมีบัญชีธนาคารและ `cash_date`, `none` ต้องไม่มีทั้งคู่
 */
export type CashDirection = "in" | "out" | "both" | "none";

/** หมวดของงบกระแสเงินสด — `none` = โอนภายใน ตัดทิ้งตอน consolidate */
export type CashflowSection = "operating" | "investing" | "financing" | "none";

export type PLEffect = { line: string; kind: "revenue" | "expense" };

export type BSEffect = {
  line: string;
  side: "asset" | "liability" | "equity";
  direction: "increase" | "decrease";
};

/** สิ่งที่ฟอร์มต้องบังคับเก็บเพิ่มสำหรับหมวดย่อยนี้ */
export type FormRequirement =
  | "contact" // ต้องผูกผู้ติดต่อ (เช่น ยืมจากใคร / ให้ใครยืม)
  | "asset" // ต้องผูกทรัพย์
  | "loanTerms" // ต้องเปิดฟอร์มเงื่อนไขสัญญา (Backlog ข้อ 2)
  | "capitalGain" // ต้องคำนวณกำไร/ขาดทุนจากการขาย (Backlog ข้อ 4)
  | "principalInterestSplit" // ต้องแยกเงินต้น/ดอกเบี้ย (Backlog ข้อ 5)
  | "transferTarget"; // ต้องระบุบัญชีปลายทาง (และลักษณะรายการถ้าข้ามผู้ถือ)

export type SubCategory = {
  code: string;
  label: string;
  /** ศัพท์เทคนิคภาษาอังกฤษกำกับเล็กๆ ตาม brief */
  en?: string;
  /** อธิบายเป็นภาษาคน ว่าระบบจะลงบัญชีให้อย่างไร */
  plain: string;
  cash: CashDirection;
  cashflow: CashflowSection;
  /** รหัสบัญชีฝั่งเดบิต (รหัสจาก `coa.ts`) */
  dr: string;
  /** รหัสบัญชีฝั่งเครดิต */
  cr: string;
  /**
   * บัญชีรับรู้กำไรจากการขาย (เฉพาะหมวดที่ `requires: capitalGain`)
   * แยกตามชนิดทรัพย์ เพราะกำไรขายอสังหาฯ กับขายหลักทรัพย์ไปคนละบรรทัดใน P&L
   */
  gainCoa?: string;
  /** บัญชีรับรู้ขาดทุนจากการขาย */
  lossCoa?: string;
  /**
   * บัญชีค้างรับ/ค้างจ่ายของหมวดนี้ — ใช้เมื่อผู้ใช้ติ๊ก "ยังไม่ได้รับ/จ่ายเงิน"
   *
   * ไม่มีค่านี้ = หมวดนี้ตั้งค้างไม่ได้ ระบบจะปฏิเสธแทนที่จะเดาบัญชีให้
   * (เดาผิด = ลูกหนี้ไปโผล่ผิดบรรทัดในงบดุล ซึ่งไม่มีทางเห็นจากหน้าจอ)
   */
  accrualCoa?: string;
  /** บัญชีดอกเบี้ยจ่าย (เฉพาะหมวดที่ `requires: principalInterestSplit`) */
  interestCoa?: string;
  requires?: FormRequirement[];
  /** หมายเหตุกฎ — แสดงในหน้าตารางกฎเพื่อกันการลงผิดหมวด */
  caution?: string;
};

export type TxType = {
  key: TxTypeKey;
  label: string;
  desc: string;
  /** สีป้ายประเภท ใช้โทเคนชุดเดียวกับ Style Guide */
  tone: "inc" | "exp" | "inv" | "fin" | "trf";
  cash: CashDirection;
  subs: SubCategory[];
};

const CASH = "1100"; // เงินสดและเงินฝากธนาคาร

export const TX_TYPES: TxType[] = [
  {
    key: "income",
    label: "รายได้",
    desc: "ค่าเช่า ดอกเบี้ยรับ เงินปันผล",
    tone: "inc",
    cash: "in",
    subs: [
      {
        code: "inc.rent",
        label: "ค่าเช่า",
        en: "Rental income",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และรายได้ค่าเช่าเพิ่มขึ้น",
        cash: "in",
        cashflow: "operating",
        dr: CASH,
        cr: "4200",
        accrualCoa: "1200",
        requires: ["asset", "contact"],
      },
      {
        code: "inc.hire_purchase",
        label: "ค่าเช่าซื้อ",
        en: "Hire-purchase income",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และรายได้ค่าเช่าซื้อเพิ่มขึ้น",
        cash: "in",
        cashflow: "operating",
        dr: CASH,
        cr: "4210",
        accrualCoa: "1200",
        requires: ["asset", "contact"],
      },
      {
        code: "inc.interest_srr",
        label: "ดอกเบี้ยรับ — ขายฝาก",
        en: "Interest income · Redemption",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และดอกเบี้ยรับขายฝากเพิ่มขึ้น — เงินต้นยังไม่ลด",
        cash: "in",
        cashflow: "operating",
        dr: CASH,
        cr: "4100",
        accrualCoa: "1210",
        requires: ["contact"],
        caution: "ถ้ารับเงินต้นคืนด้วย ให้แยกบันทึกเงินต้นที่ ลงทุน (ขาย/รับคืน) › รับคืนเงินต้นขายฝาก",
      },
      {
        code: "inc.interest_mortgage",
        label: "ดอกเบี้ยรับ — จำนอง",
        en: "Interest income · Mortgage",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และดอกเบี้ยรับจำนองเพิ่มขึ้น — เงินต้นยังไม่ลด",
        cash: "in",
        cashflow: "operating",
        dr: CASH,
        cr: "4110",
        accrualCoa: "1210",
        requires: ["contact"],
        caution: "ถ้ารับเงินต้นคืนด้วย ให้แยกบันทึกเงินต้นที่ ลงทุน (ขาย/รับคืน) › รับคืนเงินต้นจำนอง",
      },
      {
        code: "inc.interest_loan",
        label: "ดอกเบี้ยรับ — เงินให้กู้ยืม",
        en: "Interest income · Loan",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และดอกเบี้ยรับเงินให้กู้ยืมเพิ่มขึ้น",
        cash: "in",
        cashflow: "operating",
        dr: CASH,
        cr: "4120",
        accrualCoa: "1210",
        requires: ["contact"],
      },
      {
        code: "inc.dividend",
        label: "เงินปันผลรับ",
        en: "Dividend income",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และเงินปันผลรับเพิ่มขึ้น",
        cash: "in",
        cashflow: "operating",
        dr: CASH,
        cr: "4410",
        accrualCoa: "1220",
      },
      {
        code: "inc.key_money",
        label: "เงินกินเปล่า",
        en: "Key money",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และรายได้เงินกินเปล่าเพิ่มขึ้น",
        cash: "in",
        cashflow: "operating",
        dr: CASH,
        cr: "4310",
        accrualCoa: "1220",
        requires: ["asset", "contact"],
      },
      {
        code: "inc.fee",
        label: "ค่าคอมมิชชั่น / ค่าธรรมเนียมรับ",
        en: "Fee & commission income",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และรายได้ค่าธรรมเนียมเพิ่มขึ้น",
        cash: "in",
        cashflow: "operating",
        dr: CASH,
        cr: "4400",
        accrualCoa: "1220",
        requires: ["contact"],
      },
      /**
       * หนี้สูญได้รับคืน — ลูกหนี้ที่ **ตัดหนี้สูญไปแล้ว** จ่ายเงินมาทีหลัง
       *
       * ก่อนมีหมวดนี้ ทางเดียวที่ผู้ใช้มีคือ `inv.collect_rent` (Dr 1100 / Cr 1200)
       * ซึ่งผ่านทุกด่านแล้วทำให้ **ลูกหนี้ติดลบ** เท่ายอดที่เก็บคืนได้ และ P&L ไม่ขยับ
       * = รายได้ขาดไปเท่านั้น และไม่มี trigger ไหนฟ้องเพราะใบยังสมดุลทุกบรรทัด
       *
       * **รับรู้เป็นรายได้ ไม่ใช่ปลุกลูกหนี้กลับมา** (ตัดสินแล้ว · ข้อ 2 ของผู้ตรวจ):
       * ลูกหนี้ตัวนั้นถูกตัดออกจากสมุดไปแล้ว การปลุกกลับมาแล้วล้างทันทีได้ผลเท่ากัน
       * แต่เพิ่มสองบรรทัดที่ไม่มีใครอ่าน และเสี่ยงลงครึ่งทางแล้วค้าง
       *
       * **ไม่มี `accrualCoa` โดยตั้งใจ** (D-106 · เคยมี `"1220"` แล้วเป็นช่องปั๊มรายได้)
       *
       * `accrualCoa` ไม่ได้แค่เปิดให้ฟอร์มติ๊ก "ยังไม่ได้รับเงิน" — มันเข้าไปอยู่ใน
       * `txn_types.accrual_coa_code` ซึ่งเป็น **ชุดบัญชีที่ด่านระดับบรรทัดฝั่ง DB
       * (`fn_assert_line_coa_in_rules`) ยอมให้หมวดนี้ลงได้** → ใบ **Dr 1220 / Cr 4320**
       * ผ่านทุกด่าน = ปลุกลูกหนี้ของหนี้ที่ตัดออกจากสมุดไปแล้วขึ้นมาใหม่โดยไม่มีเงินเข้า
       * แล้ววนเป็นวง: ลูกหนี้ปลอมดัน cap ของค่าเผื่อ → ตั้งค่าเผื่อ → ตัดหนี้สูญ
       * → **ยอดตัดหนี้สูญสะสมสูงขึ้น** → เพดานของ 4320 สูงขึ้น → รับคืนได้อีก
       * (ผู้ตรวจรันแล้ว 4 รอบ → 4320 = 150,000 จากหนี้จริง 30,000 · ไม่มีอะไรฟ้อง)
       *
       * ตั้งค้างของหมวดนี้ **ไม่มีความหมายทางบัญชี** อยู่แล้ว: ลูกหนี้ก้อนนั้นออกจาก
       * สมุดไปแล้ว สิ่งที่รับรู้ได้คือเงินที่ **เข้ามาจริง** ไม่ใช่สิทธิ์ที่จะได้รับ
       * → หมวดนี้จึงอยู่ในรายการข้อยกเว้นของกฎ "หมวดที่เงินเคลื่อนต้องมีบัญชีพัก"
       *   (`accrual-coverage.test.ts` · ข้อยกเว้นเขียนชื่อตรงๆ ให้เห็นใน diff)
       */
      {
        code: "inc.bad_debt_recovered",
        label: "หนี้สูญได้รับคืน",
        en: "Bad debt recovered",
        plain:
          "เงินเข้าบัญชีเพิ่มขึ้น และรับรู้เป็นรายได้ หนี้สูญได้รับคืน — " +
          "ไม่กลับไปเพิ่มลูกหนี้ที่ตัดออกจากสมุดไปแล้ว",
        cash: "in",
        cashflow: "operating",
        dr: CASH,
        cr: "4320",
        requires: ["contact"],
        caution:
          "ใช้หมวดนี้เฉพาะหนี้ที่ **ตัดหนี้สูญไปแล้ว** · ถ้าลูกหนี้ยังอยู่ในสมุด " +
          "ให้ลงที่ ลงทุน (ขาย/รับคืน) › รับชำระค่าเช่าค้างรับ เพื่อให้ลูกหนี้ลดลงจริง " +
          "· ถ้าตัดหนี้สูญไปแล้วแต่ลงเป็นรับชำระค้างรับ ลูกหนี้จะติดลบและรายได้จะขาดไปเท่ายอดที่เก็บคืนได้",
      },
      {
        code: "inc.other",
        label: "รายได้อื่น",
        en: "Other income",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และรายได้อื่นเพิ่มขึ้น",
        cash: "in",
        cashflow: "operating",
        dr: CASH,
        cr: "4900",
        accrualCoa: "1220",
        caution: "ฝั่ง Corporate ห้ามใช้หมวดนี้แบบไม่ระบุ ต้องเลือกหมวดที่ตรงกว่าเสมอ",
      },
    ],
  },
  {
    key: "expense",
    label: "ค่าใช้จ่าย",
    desc: "ซ่อมบำรุง ค่าส่วนกลาง ค่าบริหาร",
    tone: "exp",
    cash: "out",
    subs: [
      {
        code: "exp.common",
        label: "ค่าส่วนกลาง",
        en: "Common area fee",
        plain: "เงินออกจากบัญชี และค่าส่วนกลางเพิ่มขึ้น",
        cash: "out",
        cashflow: "operating",
        dr: "5100",
        cr: CASH,
        accrualCoa: "2100",
        requires: ["asset"],
      },
      {
        code: "exp.utilities",
        label: "ค่าน้ำ-ค่าไฟ",
        en: "Utilities",
        plain: "เงินออกจากบัญชี และค่าน้ำ-ค่าไฟเพิ่มขึ้น",
        cash: "out",
        cashflow: "operating",
        dr: "5110",
        cr: CASH,
        accrualCoa: "2100",
        requires: ["asset"],
      },
      {
        code: "exp.repair",
        label: "ค่าซ่อมแซม-บำรุงรักษา",
        en: "Repair & maintenance",
        plain: "เงินออกจากบัญชี และค่าซ่อมบำรุงเพิ่มขึ้น",
        cash: "out",
        cashflow: "operating",
        dr: "5120",
        cr: CASH,
        accrualCoa: "2100",
        requires: ["asset"],
        caution: "ถ้าเป็นการปรับปรุงที่ทำให้มูลค่าทรัพย์เพิ่ม ให้ลงที่ ลงทุน (ซื้อ/ปล่อยเงิน) › ค่ารีโนเวท แทน",
      },
      {
        code: "exp.furnishing",
        label: "ค่าตกแต่ง-เฟอร์นิเจอร์",
        en: "Furnishing & fit-out",
        plain: "เงินออกจากบัญชี และค่าตกแต่งเพิ่มขึ้น",
        cash: "out",
        cashflow: "operating",
        dr: "5130",
        cr: CASH,
        accrualCoa: "2100",
        requires: ["asset"],
        caution: "ของที่อายุใช้งานยาวและมูลค่าสูง ควรลงเป็นค่ารีโนเวท (บันทึกเป็นทุน) แทน",
      },
      {
        code: "exp.cleaning",
        label: "ค่าแม่บ้าน-ทำความสะอาด",
        en: "Cleaning & housekeeping",
        plain: "เงินออกจากบัญชี และค่าแม่บ้านเพิ่มขึ้น",
        cash: "out",
        cashflow: "operating",
        dr: "5140",
        cr: CASH,
        accrualCoa: "2100",
        requires: ["asset"],
      },
      {
        code: "exp.commission",
        label: "ค่าคอมมิชชั่นจ่าย",
        en: "Commission expense",
        plain: "เงินออกจากบัญชี และค่าคอมมิชชั่นจ่ายเพิ่มขึ้น",
        cash: "out",
        cashflow: "operating",
        dr: "5200",
        cr: CASH,
        accrualCoa: "2100",
        requires: ["contact"],
      },
      {
        code: "exp.referral",
        label: "ค่านายหน้า-ค่าแนะนำ",
        en: "Referral fee",
        plain: "เงินออกจากบัญชี และค่านายหน้าเพิ่มขึ้น",
        cash: "out",
        cashflow: "operating",
        dr: "5210",
        cr: CASH,
        accrualCoa: "2100",
        requires: ["contact"],
      },
      {
        code: "exp.marketing",
        label: "ค่าการตลาด-โฆษณา",
        en: "Marketing & advertising",
        plain: "เงินออกจากบัญชี และค่าการตลาดเพิ่มขึ้น",
        cash: "out",
        cashflow: "operating",
        dr: "5220",
        cr: CASH,
        accrualCoa: "2100",
      },
      {
        code: "exp.land_office",
        label: "ค่าธรรมเนียมกรมที่ดิน",
        en: "Land office fees",
        plain: "เงินออกจากบัญชี และค่าธรรมเนียมกรมที่ดินเพิ่มขึ้น",
        cash: "out",
        cashflow: "operating",
        dr: "5300",
        cr: CASH,
        accrualCoa: "2100",
        requires: ["asset"],
        caution: "ค่าธรรมเนียมที่เกิดตอนซื้อทรัพย์ ควรรวมเป็นต้นทุนทรัพย์ (ลงทุน) ไม่ใช่ค่าใช้จ่ายงวดนี้",
      },
      {
        code: "exp.tax",
        label: "ภาษีและอากรแสตมป์",
        en: "Taxes & stamp duty",
        plain: "เงินออกจากบัญชี และภาษี/อากรแสตมป์เพิ่มขึ้น",
        cash: "out",
        cashflow: "operating",
        dr: "5310",
        cr: CASH,
        accrualCoa: "2100",
      },
      {
        code: "exp.legal",
        label: "ค่าทนาย-ค่าทำสัญญา",
        en: "Legal & contract fees",
        plain: "เงินออกจากบัญชี และค่าทนาย/ค่าทำสัญญาเพิ่มขึ้น",
        cash: "out",
        cashflow: "operating",
        dr: "5320",
        cr: CASH,
        accrualCoa: "2100",
      },
      {
        code: "exp.bank_charge",
        label: "ค่าธรรมเนียมธนาคาร",
        en: "Bank charges",
        plain: "เงินออกจากบัญชี และค่าธรรมเนียมธนาคารเพิ่มขึ้น",
        cash: "out",
        cashflow: "operating",
        dr: "5330",
        cr: CASH,
        accrualCoa: "2100",
      },
      {
        code: "exp.salary",
        label: "เงินเดือน-ค่าแรง",
        en: "Salary & wages",
        plain: "เงินออกจากบัญชี และเงินเดือน-ค่าแรงเพิ่มขึ้น",
        cash: "out",
        cashflow: "operating",
        dr: "5500",
        cr: CASH,
        accrualCoa: "2100",
      },
      {
        code: "exp.travel",
        label: "ค่าเดินทาง-น้ำมัน",
        en: "Travel & fuel",
        plain: "เงินออกจากบัญชี และค่าเดินทางเพิ่มขึ้น",
        cash: "out",
        cashflow: "operating",
        dr: "5510",
        cr: CASH,
        accrualCoa: "2100",
      },
      {
        code: "exp.office",
        label: "ค่าใช้จ่ายสำนักงาน",
        en: "Office expenses",
        plain: "เงินออกจากบัญชี และค่าใช้จ่ายสำนักงานเพิ่มขึ้น",
        cash: "out",
        cashflow: "operating",
        dr: "5520",
        cr: CASH,
        accrualCoa: "2100",
      },
      {
        code: "exp.other",
        label: "ค่าใช้จ่ายอื่น",
        en: "Other expenses",
        plain: "เงินออกจากบัญชี และค่าใช้จ่ายอื่นเพิ่มขึ้น",
        cash: "out",
        cashflow: "operating",
        dr: "5900",
        cr: CASH,
        accrualCoa: "2100",
        caution: "ฝั่ง Corporate ห้ามใช้หมวดนี้แบบไม่ระบุ ต้องเลือกหมวดที่ตรงกว่าเสมอ",
      },
    ],
  },
  {
    key: "invest_buy",
    label: "ลงทุน (ซื้อ/ปล่อยเงิน)",
    desc: "ซื้อทรัพย์ ปล่อยเงินขายฝาก ให้กู้",
    tone: "inv",
    cash: "out",
    subs: [
      {
        code: "inv.buy_re",
        label: "ซื้ออสังหาริมทรัพย์",
        en: "Acquire real estate",
        plain: "เงินออกจากบัญชี แต่ไม่ใช่ค่าใช้จ่าย — ทรัพย์ในงบดุลเพิ่มขึ้นตามต้นทุน",
        cash: "out",
        cashflow: "investing",
        dr: "1500",
        cr: CASH,
        accrualCoa: "2100",
        requires: ["asset"],
        caution: "ไม่กระทบกำไรขาดทุน เป็นการเปลี่ยนรูปของสินทรัพย์เท่านั้น",
      },
      {
        code: "inv.capex",
        label: "ค่ารีโนเวท (บันทึกเป็นทุน)",
        en: "Renovation capitalised",
        plain: "เงินออกจากบัญชี และต้นทุนทรัพย์เพิ่มขึ้น — ไม่ลงเป็นค่าซ่อมบำรุง",
        cash: "out",
        cashflow: "investing",
        dr: "1510",
        cr: CASH,
        accrualCoa: "2100",
        requires: ["asset"],
        caution: "ซ่อมให้กลับมาใช้ได้เหมือนเดิม = ค่าใช้จ่าย · ปรับปรุงให้ดีขึ้น/อายุยาวขึ้น = ลงทุน",
      },
      {
        code: "inv.srr_out",
        label: "ปล่อยเงินขายฝาก",
        en: "Sale with right of redemption",
        plain: "เงินออกจากบัญชี และเงินลงทุนขายฝาก (เงินต้น) เพิ่มขึ้น — ไม่ใช่ค่าใช้จ่าย",
        cash: "out",
        cashflow: "investing",
        dr: "1400",
        cr: CASH,
        accrualCoa: "2100",
        requires: ["asset", "contact", "loanTerms"],
        caution: "ต้องกรอกเงื่อนไขสัญญาเพื่อสร้างตารางงวดรับดอกเบี้ย (Backlog ข้อ 2)",
      },
      {
        code: "inv.mortgage_out",
        label: "ปล่อยเงินจำนอง",
        en: "Mortgage lending",
        plain: "เงินออกจากบัญชี และเงินลงทุนจำนอง (เงินต้น) เพิ่มขึ้น — ไม่ใช่ค่าใช้จ่าย",
        cash: "out",
        cashflow: "investing",
        dr: "1410",
        cr: CASH,
        accrualCoa: "2100",
        requires: ["asset", "contact", "loanTerms"],
        caution: "ต้องกรอกเงื่อนไขสัญญาเพื่อสร้างตารางงวดรับดอกเบี้ย (Backlog ข้อ 2)",
      },
      {
        code: "inv.lend",
        label: "ให้กู้ยืมออกไป",
        en: "Loan out",
        plain: "เงินออกจากบัญชี และลูกหนี้เงินให้กู้ยืมเพิ่มขึ้น — ไม่ใช่ค่าใช้จ่าย",
        cash: "out",
        cashflow: "investing",
        dr: "1300",
        cr: CASH,
        accrualCoa: "2100",
        requires: ["contact", "loanTerms"],
        caution: "เงินที่เราปล่อยออกไปเป็น Investing ไม่ใช่ Financing — Financing คือเรากู้เขา",
      },
      {
        code: "inv.buy_securities",
        label: "ซื้อหลักทรัพย์ / กองทุน",
        en: "Buy securities",
        plain: "เงินออกจากบัญชี และเงินลงทุนในหลักทรัพย์เพิ่มขึ้นตามต้นทุน",
        cash: "out",
        cashflow: "investing",
        dr: "1700",
        cr: CASH,
        accrualCoa: "2100",
        // ไม่ผูกทะเบียนตอนซื้อ = ไม่มีล็อตให้ตัดต้นทุนแบบ FIFO ตอนขาย (D-038 · D-058 ข้อ 1)
        // ย้อนหลังทำไม่ได้เพราะข้อมูลล็อต (วันที่ · จำนวน · ราคา) หายไปแล้ว
        requires: ["asset"],
      },
      {
        /**
         * ซื้อทองคำ / สินทรัพย์ทางเลือก
         *
         * เงินเข้าหรือออก: **ออก**
         * กระทบ P&L: **ไม่กระทบ** — แค่เปลี่ยนรูปสินทรัพย์จากเงินสดเป็นทอง
         * งบดุล: สินทรัพย์ 1720 เพิ่ม · เงินสดลด (รวมไม่เปลี่ยน)
         * กระแสเงินสด: **Investing −** (เอาเงินไปวางในสินทรัพย์)
         * บังคับกรอกเพิ่ม: ไม่มี (ทองคำไม่ต้องผูกทะเบียนทรัพย์เหมือนอสังหาฯ)
         *
         * ใช้ 1720 ไม่ใช่ 1700 เพราะทองคำอยู่หมวดใหญ่ Commodity & Cash
         * ส่วนหลักทรัพย์อยู่ Paper Asset — ถ้าใช้บัญชีเดียวกันจะแยกสองหมวดไม่ได้
         */
        code: "inv.buy_commodity",
        label: "ซื้อทองคำ / สินทรัพย์ทางเลือก",
        en: "Buy gold & alternatives",
        plain: "เงินออกจากบัญชี และเงินลงทุนในทองคำเพิ่มขึ้นตามต้นทุน — ไม่ใช่ค่าใช้จ่าย",
        cash: "out",
        cashflow: "investing",
        dr: "1720",
        cr: CASH,
        accrualCoa: "2100",
        // เหตุผลเดียวกับซื้อหลักทรัพย์ — FIFO ครอบทั้ง 1700 และ 1720 (LEDGER_RULES §6 ข้อ 1)
        requires: ["asset"],
        caution: "ทองคำและคริปโตใช้หมวดนี้ ไม่ใช่หมวดซื้อหลักทรัพย์ ไม่งั้นจะไปรวมอยู่ใน Paper Asset",
      },
      {
        code: "inv.deposit_paid",
        label: "เงินมัดจำจ่าย",
        en: "Deposit paid",
        plain: "เงินออกจากบัญชี และเงินมัดจำจ่าย (สินทรัพย์) เพิ่มขึ้น — ไม่ใช่ค่าใช้จ่าย เพราะได้คืน",
        cash: "out",
        cashflow: "operating",
        dr: "1600",
        cr: CASH,
        accrualCoa: "2100",
        requires: ["contact"],
        caution: "เงินมัดจำที่เราจ่ายคือสิทธิที่จะได้คืน จึงเป็นสินทรัพย์ ไม่ใช่ค่าใช้จ่าย",
      },
    ],
  },
  {
    key: "invest_sell",
    label: "ลงทุน (ขาย/รับคืน)",
    desc: "ขายทรัพย์ รับไถ่ถอน รับคืนเงินต้น",
    tone: "inv",
    cash: "in",
    subs: [
      {
        code: "inv.sell_re",
        label: "ขายอสังหาริมทรัพย์",
        en: "Dispose real estate",
        plain: "ตัดทรัพย์ออกตามต้นทุน รับเงินเข้าบัญชี และรับรู้กำไร/ขาดทุนจากการขายใน P&L",
        cash: "in",
        cashflow: "investing",
        dr: CASH,
        cr: "1500",
        accrualCoa: "1220",
        gainCoa: "4300",
        lossCoa: "5910",
        requires: ["asset", "capitalGain"],
        caution: "ส่วนต่างจากการตีราคาที่เคยบันทึกไว้ต้องถูกล้างออกพร้อมกัน — ทั้งตอนตีขึ้นและตีลง (ขายขาดทุนเกิดขึ้นจริง)",
      },
      {
        code: "inv.srr_redeem",
        label: "รับไถ่ถอนขายฝาก (เงินต้น)",
        en: "Redemption received",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และเงินลงทุนขายฝากลดลง — ไม่ใช่รายได้",
        cash: "in",
        cashflow: "investing",
        dr: CASH,
        cr: "1400",
        accrualCoa: "1220",
        // ดอกเบี้ยรับเป็น "รายได้" ไม่ใช่ค่าใช้จ่าย — engine จะลงเป็นเครดิต
        interestCoa: "4100",
        requires: ["asset", "contact", "principalInterestSplit"],
        caution: "รับพร้อมดอกเบี้ยได้ในรายการเดียว แต่ต้องแยกยอดให้ชัด — เงินต้นลดลูกหนี้ ดอกเบี้ยเป็นรายได้",
      },
      {
        code: "inv.mortgage_redeem",
        label: "รับไถ่ถอนจำนอง (เงินต้น)",
        en: "Mortgage redeemed",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และเงินลงทุนจำนองลดลง — ไม่ใช่รายได้",
        cash: "in",
        cashflow: "investing",
        dr: CASH,
        cr: "1410",
        accrualCoa: "1220",
        interestCoa: "4110",
        requires: ["asset", "contact", "principalInterestSplit"],
        caution: "รับพร้อมดอกเบี้ยได้ในรายการเดียว แต่ต้องแยกยอดให้ชัด — เงินต้นลดลูกหนี้ ดอกเบี้ยเป็นรายได้",
      },
      {
        code: "inv.loan_back",
        label: "รับคืนเงินให้กู้ยืม (เงินต้น)",
        en: "Loan principal repaid",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และลูกหนี้เงินให้กู้ยืมลดลง — ไม่ใช่รายได้",
        cash: "in",
        cashflow: "investing",
        dr: CASH,
        cr: "1300",
        accrualCoa: "1220",
        interestCoa: "4120",
        requires: ["contact", "principalInterestSplit"],
        caution: "รับพร้อมดอกเบี้ยได้ในรายการเดียว แต่ต้องแยกยอดให้ชัด — เงินต้นลดลูกหนี้ ดอกเบี้ยเป็นรายได้",
      },
      {
        code: "inv.sell_securities",
        label: "ขายหลักทรัพย์ / กองทุน",
        en: "Sell securities",
        plain: "ตัดเงินลงทุนออกตามต้นทุน รับเงินเข้าบัญชี และรับรู้กำไร/ขาดทุนจากการขาย",
        cash: "in",
        cashflow: "investing",
        dr: CASH,
        cr: "1700",
        accrualCoa: "1220",
        gainCoa: "4900",
        lossCoa: "5910",
        requires: ["capitalGain"],
      },
      {
        /**
         * ขายทองคำ / สินทรัพย์ทางเลือก
         *
         * เงินเข้าหรือออก: **เข้า**
         * กระทบ P&L: **เฉพาะกำไร/ขาดทุนจากการขาย** ไม่ใช่ทั้งก้อน
         *   กำไร → 4900 รายได้อื่น · ขาดทุน → 5910 ขาดทุนจากการขายทรัพย์
         * งบดุล: สินทรัพย์ 1720 ลดตาม**ต้นทุน** · เงินสดเพิ่มตามเงินที่ได้จริง
         * กระแสเงินสด: **Investing +**
         * บังคับกรอกเพิ่ม: `capitalGain` — ไม่รู้ต้นทุนก็ตัดบัญชีผิดและกำไรผิด
         *
         * ทองคำใช้ FIFO เหมือนหลักทรัพย์ (ลูกพี่ตัดสิน D-038) ต้นทุนจึงต้องมาจากล็อต
         */
        code: "inv.sell_commodity",
        label: "ขายทองคำ / สินทรัพย์ทางเลือก",
        en: "Sell gold & alternatives",
        plain: "ตัดเงินลงทุนในทองคำออกตามต้นทุน รับเงินเข้าบัญชี และรับรู้กำไร/ขาดทุนจากการขาย",
        cash: "in",
        cashflow: "investing",
        dr: CASH,
        cr: "1720",
        accrualCoa: "1220",
        gainCoa: "4900",
        lossCoa: "5910",
        requires: ["capitalGain"],
        caution: "ขายขาดทุนเกิดขึ้นได้จริง — ต้นทุนต้องมาจากล็อตที่ซื้อจริง (FIFO) ไม่ใช่ราคาเฉลี่ย",
      },
      {
        code: "inv.deposit_returned",
        label: "รับคืนเงินมัดจำที่จ่ายไว้",
        en: "Deposit paid refunded",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และเงินมัดจำจ่ายลดลง — ไม่ใช่รายได้",
        cash: "in",
        cashflow: "operating",
        dr: CASH,
        cr: "1600",
        accrualCoa: "1220",
        requires: ["contact"],
      },
      // คู่ของการตั้งค้างรับ — ไม่มีสองหมวดนี้ ลูกหนี้ที่ตั้งไว้จะค้างในงบดุลตลอดไป
      // และผู้ใช้จะเผลอลงรายได้ซ้ำตอนเงินเข้าจริง
      {
        code: "inv.collect_rent",
        label: "รับชำระค่าเช่าค้างรับ",
        en: "Rent receivable collected",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และลูกหนี้ค่าเช่าลดลง — ไม่ใช่รายได้ใหม่ รับรู้ไปแล้วตอนตั้งค้าง",
        cash: "in",
        cashflow: "operating",
        dr: CASH,
        cr: "1200",
        requires: ["contact"],
        caution: "ถ้ายังไม่เคยตั้งค้างรับไว้ ให้ลงเป็นรายได้ › ค่าเช่า ตรงๆ แทน ไม่งั้นรายได้จะหาย",
      },
      {
        code: "inv.collect_interest",
        label: "รับชำระดอกเบี้ยค้างรับ",
        en: "Interest receivable collected",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และลูกหนี้ดอกเบี้ยลดลง — ไม่ใช่รายได้ใหม่ รับรู้ไปแล้วตอนตั้งค้าง",
        cash: "in",
        cashflow: "operating",
        dr: CASH,
        cr: "1210",
        requires: ["contact"],
        caution: "ถ้ายังไม่เคยตั้งค้างรับไว้ ให้ลงเป็นรายได้ › ดอกเบี้ยรับ ตรงๆ แทน ไม่งั้นรายได้จะหาย",
      },
    ],
  },
  {
    key: "finance_in",
    label: "กู้/เพิ่มทุน",
    desc: "เงินกู้ธนาคาร กรรมการ เพิ่มทุน",
    tone: "fin",
    cash: "in",
    subs: [
      {
        code: "fin.loan_bank",
        label: "กู้เงินธนาคาร",
        en: "Bank borrowing",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และหนี้สินเงินกู้ธนาคารเพิ่มขึ้น — ไม่ใช่รายได้",
        cash: "in",
        cashflow: "financing",
        dr: CASH,
        cr: "2410",
        accrualCoa: "1220",
        requires: ["contact", "loanTerms"],
        caution: "เงินเข้าบัญชีแต่ไม่ใช่รายได้ ห้ามลงหมวด รายได้ เด็ดขาด",
      },
      {
        code: "fin.loan_director",
        label: "กู้ยืมกรรมการ / คนในครอบครัว",
        en: "Director loan",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และหนี้สินเงินกู้ยืมกรรมการเพิ่มขึ้น — ไม่ใช่รายได้",
        cash: "in",
        cashflow: "financing",
        dr: CASH,
        cr: "2300",
        accrualCoa: "1220",
        requires: ["contact", "loanTerms"],
        caution: "เงินเข้าบัญชีแต่ไม่ใช่รายได้ ห้ามลงหมวด รายได้ เด็ดขาด",
      },
      {
        code: "fin.loan_other",
        label: "กู้ยืมอื่น",
        en: "Other borrowing",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และหนี้สินเงินกู้ยืมอื่นเพิ่มขึ้น — ไม่ใช่รายได้",
        cash: "in",
        cashflow: "financing",
        dr: CASH,
        cr: "2400",
        accrualCoa: "1220",
        requires: ["contact", "loanTerms"],
      },
      {
        code: "fin.capital",
        label: "เพิ่มทุน",
        en: "Capital injection",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และส่วนของเจ้าของเพิ่มขึ้น — ไม่ใช่รายได้",
        cash: "in",
        cashflow: "financing",
        dr: CASH,
        cr: "3100",
        accrualCoa: "1220",
        requires: ["contact"],
        caution: "เงินทุนจากอากงต้องแยกจากเงินกู้ยืมกรรมการ ห้ามรวมเป็นก้อนเดียว",
      },
      {
        code: "fin.deposit_received",
        label: "รับเงินมัดจำจากผู้เช่า",
        en: "Tenant deposit received",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และหนี้สินเงินมัดจำเพิ่มขึ้น — ต้องคืนภายหลัง จึงไม่ใช่รายได้",
        cash: "in",
        cashflow: "operating",
        dr: CASH,
        cr: "2200",
        accrualCoa: "1220",
        requires: ["contact", "asset"],
      },
    ],
  },
  {
    key: "finance_out",
    label: "คืนเงินกู้/จ่ายผลตอบแทน",
    desc: "ชำระเงินต้น ดอกเบี้ย ปันผล",
    tone: "fin",
    cash: "out",
    subs: [
      {
        code: "fin.repay_bank",
        label: "ชำระคืนเงินกู้ธนาคาร (เงินต้น)",
        en: "Bank loan principal repaid",
        plain: "เงินออกจากบัญชี และหนี้สินเงินกู้ธนาคารลดลง — เงินต้นไม่ใช่ค่าใช้จ่าย",
        cash: "out",
        cashflow: "financing",
        dr: "2410",
        cr: CASH,
        accrualCoa: "2100",
        interestCoa: "5400",
        requires: ["contact", "principalInterestSplit"],
        caution: "เงินต้นไม่ใช่ค่าใช้จ่าย ต้องแยกออกจากดอกเบี้ยเสมอ (Backlog ข้อ 5)",
      },
      {
        code: "fin.repay_director",
        label: "ชำระคืนเงินกู้ยืมกรรมการ (เงินต้น)",
        en: "Director loan repaid",
        plain: "เงินออกจากบัญชี และหนี้สินเงินกู้ยืมกรรมการลดลง — ไม่ใช่ค่าใช้จ่าย",
        cash: "out",
        cashflow: "financing",
        dr: "2300",
        cr: CASH,
        accrualCoa: "2100",
        interestCoa: "5400",
        requires: ["contact", "principalInterestSplit"],
        caution: "เงินต้นไม่ใช่ค่าใช้จ่าย ต้องแยกออกจากดอกเบี้ยเสมอ (Backlog ข้อ 5)",
      },
      {
        code: "fin.interest_paid",
        label: "จ่ายดอกเบี้ย",
        en: "Interest paid",
        plain: "เงินออกจากบัญชี และดอกเบี้ยจ่ายเพิ่มขึ้น — หนี้สินเงินต้นไม่เปลี่ยน",
        cash: "out",
        cashflow: "financing",
        dr: "5400",
        cr: CASH,
        accrualCoa: "2100",
        requires: ["contact"],
      },
      {
        code: "fin.drawings",
        label: "ถอนทุน / จ่ายปันผล",
        en: "Drawings",
        plain: "เงินออกจากบัญชี และส่วนของเจ้าของลดลง — ไม่ใช่ค่าใช้จ่ายใน P&L",
        cash: "out",
        cashflow: "financing",
        dr: "3200",
        cr: CASH,
        accrualCoa: "2100",
        requires: ["contact"],
        caution: "เงินปันผลจ่ายลดส่วนของเจ้าของ ไม่ใช่ค่าใช้จ่าย จึงไม่กระทบกำไรสุทธิ",
      },
      {
        code: "fin.deposit_refund",
        label: "คืนเงินมัดจำผู้เช่า",
        en: "Tenant deposit refunded",
        plain: "เงินออกจากบัญชี และหนี้สินเงินมัดจำลดลง — ไม่ใช่ค่าใช้จ่าย",
        cash: "out",
        cashflow: "operating",
        dr: "2200",
        cr: CASH,
        accrualCoa: "2100",
        requires: ["contact"],
      },
      {
        code: "fin.pay_payable",
        label: "จ่ายเจ้าหนี้ค้างจ่าย",
        en: "Pay trade payable",
        plain: "เงินออกจากบัญชี และเจ้าหนี้ค้างจ่ายลดลง — ค่าใช้จ่ายรับรู้ไปแล้วตอนตั้งหนี้",
        cash: "out",
        cashflow: "operating",
        dr: "2100",
        cr: CASH,
        requires: ["contact"],
        caution: "ถ้ายังไม่เคยตั้งหนี้ไว้ ให้ลงเป็นค่าใช้จ่ายตรงๆ แทน ไม่งั้นค่าใช้จ่ายจะหาย",
      },
    ],
  },
  {
    key: "transfer",
    label: "โอนระหว่างบัญชี",
    desc: "ย้ายเงินในกลุ่ม ไม่กระทบกำไร",
    tone: "trf",
    cash: "both",
    subs: [
      {
        code: "trf.internal",
        label: "โอนระหว่างบัญชีในกองกลาง",
        en: "Internal transfer",
        plain: "เงินย้ายจากบัญชีหนึ่งไปอีกบัญชี ยอดรวมกองกลางไม่เปลี่ยน",
        cash: "both",
        cashflow: "none",
        requires: ["transferTarget"],
        dr: CASH,
        cr: CASH,
        caution: "ไม่นับในงบกระแสเงินสด และตัดออกจากงบรวม จึงไม่กระทบกำไรขาดทุนและ NAV",
      },
    ],
  },
  /**
   * ปรับปรุงทางบัญชี — **ไม่มีเงินเคลื่อนเลย** (`cash: "none"`)
   *
   * แยกเป็นประเภทของตัวเองโดยตั้งใจ ห้ามยัดลงประเภท "ค่าใช้จ่าย":
   * ทั้งประเภทนั้นเป็น `cash: "out"` → ฟอร์มจะถามบัญชีธนาคารและวันที่เงินออก
   * ทั้งที่ไม่มีเงินออกจากที่ไหน แล้วถ้าผู้ใช้เลือกบัญชีมา มันจะติดไปกับรายการ
   * ที่ไม่มีขาเงินสด (ขยะที่ไม่มีใครเห็น และถูกใช้ต่อตอนยืนยันรับ-จ่าย)
   *
   * **วิธีที่ใช้คือวิธีค่าเผื่อ (allowance method)**:
   *   ค่าใช้จ่ายรับรู้ตอน **ตั้งค่าเผื่อ** ครั้งเดียว (Dr 5920 / Cr 1290)
   *   ตอน **ตัดหนี้สูญจริง** เป็นการล้างบัญชีคู่กัน (Dr 1290 / Cr ลูกหนี้) **ไม่แตะ P&L**
   * ถ้าตัดลง 5920 อีกรอบ = ค่าใช้จ่ายซ้ำสองเท่า กำไรต่ำกว่าจริง และงบดุลยังสมดุลอยู่
   * จึงไม่มีอะไรฟ้อง — นี่คือเหตุผลที่ `caution` ของทุกหมวดตัดหนี้สูญพูดเรื่องนี้
   *
   * **ด่านของจริงอยู่ที่ DB** (`20261009000002_allowance_and_writeoff.sql`) เพราะทั้งสามด่าน
   * ต้องอ่านยอดสะสมจากสมุด ซึ่งเครื่องยนต์มองไม่เห็น:
   *   1 · ค่าเผื่อรวมต่อผู้ถือ ห้ามเกินลูกหนี้รวม (1200+1210+1220)
   *   2 · ตัดหนี้สูญห้ามเกินค่าเผื่อคงเหลือ
   *   3 · กลับค่าเผื่อห้ามเกินค่าเผื่อคงเหลือ
   */
  {
    key: "adjust",
    label: "ปรับปรุงทางบัญชี (ไม่มีเงินเคลื่อน)",
    desc: "ค่าเผื่อหนี้สงสัยจะสูญ · ตัดหนี้สูญ — ไม่ใช้บัญชีธนาคาร",
    tone: "exp",
    cash: "none",
    subs: [
      {
        code: "adj.doubtful",
        label: "ตั้งค่าเผื่อหนี้สงสัยจะสูญ",
        en: "Provide for doubtful accounts",
        plain:
          "ค่าใช้จ่ายหนี้สงสัยจะสูญเพิ่มขึ้น และค่าเผื่อโต ทำให้ลูกหนี้สุทธิในงบดุลลดลง — ไม่มีเงินเข้าออกบัญชี",
        cash: "none",
        cashflow: "none",
        dr: "5920",
        cr: "1290",
        requires: ["contact"],
        caution:
          "นี่คือจุดเดียวที่รับรู้ค่าใช้จ่าย · ตอนตัดหนี้สูญจริงจะไม่มีค่าใช้จ่ายอีก " +
          "ถ้าหนี้จริงมากกว่าค่าเผื่อที่ตั้งไว้ ต้องตั้งเพิ่มที่หมวดนี้ก่อนจึงตัดได้",
      },
      {
        code: "adj.doubtful_release",
        label: "กลับค่าเผื่อที่ตั้งไว้เกิน",
        en: "Reverse excess allowance",
        plain:
          "ค่าเผื่อลดลง ลูกหนี้สุทธิในงบดุลกลับเพิ่มขึ้น และค่าใช้จ่ายหนี้สงสัยจะสูญลดลง — ไม่มีเงินเข้าออกบัญชี",
        cash: "none",
        cashflow: "none",
        dr: "1290",
        cr: "5920",
        requires: ["contact"],
        caution:
          "กลับได้ไม่เกินค่าเผื่อคงเหลือของผู้ถือรายนี้ — กลับเกินกว่าที่ตั้งไว้คือสร้างรายได้จากอากาศ (DB ปฏิเสธ)",
      },
      {
        code: "adj.writeoff_rent",
        label: "ตัดหนี้สูญ — ค่าเช่า",
        en: "Write off rent receivable",
        plain: "ล้างลูกหนี้ค่าเช่าออกจากงบดุลโดยหักกับค่าเผื่อที่ตั้งไว้ — ไม่มีค่าใช้จ่ายใหม่และไม่มีเงินเข้าออก",
        cash: "none",
        cashflow: "none",
        dr: "1290",
        cr: "1200",
        requires: ["contact"],
        caution:
          "ค่าใช้จ่ายรับรู้ไปแล้วตอนตั้งค่าเผื่อ หมวดนี้จึงไม่แตะกำไรขาดทุน · " +
          "ตัดได้ไม่เกินค่าเผื่อคงเหลือ ถ้าไม่พอให้ไปตั้งค่าเผื่อเพิ่มก่อน (DB ปฏิเสธ)",
      },
      {
        code: "adj.writeoff_interest",
        label: "ตัดหนี้สูญ — ดอกเบี้ย",
        en: "Write off interest receivable",
        plain: "ล้างลูกหนี้ดอกเบี้ยออกจากงบดุลโดยหักกับค่าเผื่อที่ตั้งไว้ — ไม่มีค่าใช้จ่ายใหม่และไม่มีเงินเข้าออก",
        cash: "none",
        cashflow: "none",
        dr: "1290",
        cr: "1210",
        requires: ["contact"],
        caution:
          "ค่าใช้จ่ายรับรู้ไปแล้วตอนตั้งค่าเผื่อ หมวดนี้จึงไม่แตะกำไรขาดทุน · " +
          "ตัดได้ไม่เกินค่าเผื่อคงเหลือ ถ้าไม่พอให้ไปตั้งค่าเผื่อเพิ่มก่อน (DB ปฏิเสธ)",
      },
      {
        code: "adj.writeoff_other",
        label: "ตัดหนี้สูญ — ลูกหนี้อื่น",
        en: "Write off other receivable",
        plain: "ล้างลูกหนี้อื่นออกจากงบดุลโดยหักกับค่าเผื่อที่ตั้งไว้ — ไม่มีค่าใช้จ่ายใหม่และไม่มีเงินเข้าออก",
        cash: "none",
        cashflow: "none",
        dr: "1290",
        cr: "1220",
        requires: ["contact"],
        caution:
          "ค่าใช้จ่ายรับรู้ไปแล้วตอนตั้งค่าเผื่อ หมวดนี้จึงไม่แตะกำไรขาดทุน · " +
          "ตัดได้ไม่เกินค่าเผื่อคงเหลือ ถ้าไม่พอให้ไปตั้งค่าเผื่อเพิ่มก่อน (DB ปฏิเสธ)",
      },
    ],
  },
];

// ============================================================
// ผลกระทบต่องบ — คำนวณจากคู่บัญชี ไม่ได้พิมพ์มือ
// ============================================================

const SIDE_TH: Record<"asset" | "liability" | "equity", string> = {
  asset: "สินทรัพย์",
  liability: "หนี้สิน",
  equity: "ส่วนของเจ้าของ",
};

/**
 * ป้ายทิศทางเงินของรายการ — **switch ครบทุกเคสโดยตั้งใจ**
 *
 * เขียนเป็น switch ไม่ใช่ ternary ที่มี fallback: เพิ่มค่าใหม่ใน `CashDirection`
 * แล้ว TypeScript จะฟ้องที่นี่ ไม่ใช่ตกไปใช้คำของค่าอื่นเงียบๆ
 * (ก่อนหน้านี้ `cash === "in" ? ... : cash === "out" ? ... : "ย้ายระหว่างบัญชี"`
 *  ทำให้รายการที่ไม่มีเงินเคลื่อนโชว์ว่า "ย้ายระหว่างบัญชี" ซึ่งผิดความหมาย)
 */
export function cashDirectionLabel(cash: CashDirection): string {
  switch (cash) {
    case "in":
      return "เงินเข้า";
    case "out":
      return "เงินออก";
    case "both":
      return "ย้ายระหว่างบัญชี";
    case "none":
      return "ไม่มีเงินเคลื่อน";
  }
}

/**
 * รายการนี้มีขาเงินสดไหม — **ที่เดียวที่ตอบคำถามนี้**
 *
 * ทั้งฟอร์ม (จะโชว์ช่องบัญชีธนาคารไหม) และเครื่องยนต์ (จะยอมรับบัญชีไหม)
 * ต้องอ่านจากตัวนี้ ไม่ใช่เช็ค `sub.cash !== "none"` กันเอง — กฎเดียวกันห้ามเขียนสองที่
 *
 * มีเทสต์บังคับว่าคำตอบของมันตรงกับคู่บัญชีจริง (`isCashAccount(dr) || isCashAccount(cr)`)
 * ธงที่ขัดกับคู่บัญชี = ฟอร์มถามบัญชีกับรายการที่ไม่มีขาเงินสด หรือแย่กว่า: ไม่ถามกับรายการที่มี
 */
export function movesCash(sub: SubCategory): boolean {
  switch (sub.cash) {
    case "in":
    case "out":
    case "both":
      return true;
    case "none":
      return false;
  }
}

const CF_TH: Record<CashflowSection, string> = {
  operating: "ดำเนินงาน",
  investing: "ลงทุน",
  financing: "จัดหาเงิน",
  none: "ไม่นับ (ตัดออกจากงบรวม)",
};

/** ผลของบัญชีหนึ่งฝั่ง: เดบิตเพิ่มสินทรัพย์/ค่าใช้จ่าย · เครดิตเพิ่มหนี้สิน/ทุน/รายได้ */
function effectOf(account: CoaAccount, side: "dr" | "cr"): { pl?: PLEffect; bs?: BSEffect } {
  switch (account.type) {
    case "income":
      // รายได้อยู่ฝั่งเครดิตตามปกติ
      return { pl: { line: account.nameTh, kind: "revenue" } };
    case "expense":
      return { pl: { line: account.nameTh, kind: "expense" } };
    case "asset":
      return { bs: { line: account.nameTh, side: "asset", direction: side === "dr" ? "increase" : "decrease" } };
    case "liability":
      return { bs: { line: account.nameTh, side: "liability", direction: side === "cr" ? "increase" : "decrease" } };
    case "equity":
      /**
       * เครดิตเพิ่มส่วนของเจ้าของ เดบิตลด — ใช้ได้กับบัญชี contra ด้วย
       *
       * 3200 เงินถอนของเจ้าของ เป็น contra-equity: เดบิตแล้ว**ยอดถอนโต** ซึ่งก็คือ
       * ส่วนของเจ้าของ**ลด** พอดี จึงไม่ต้องแยกเคส
       * (เดิมมีตัวแปร `isContra` ที่สองฝั่งของ ternary เหมือนกันเป๊ะ — ไม่ได้ทำอะไรเลย
       * แต่ทำให้คนอ่านคิดว่ามีการจัดการ contra อยู่ ซึ่งอันตรายกว่าไม่มี)
       *
       * การจัดกลุ่มในงบว่าบรรทัดไหนต้อง "หัก" อยู่ที่ `statements.ts` (`contra: true`)
       */
      return {
        bs: { line: account.nameTh, side: "equity", direction: side === "cr" ? "increase" : "decrease" },
      };
  }
}

export type SubEffects = {
  pl?: PLEffect;
  bs: BSEffect[];
  /**
   * กระทบ P&L เฉพาะบางกรณี — ขายทรัพย์กระทบก็ต่อเมื่อมีกำไรหรือขาดทุน
   * และการคืนเงินกู้กระทบเฉพาะส่วนดอกเบี้ย ส่วนเงินต้นไม่กระทบ
   */
  conditionalPl?: PLEffect & {
    when: string;
    /** บางกรณีเป็นได้ทั้งสองทาง — ขายทรัพย์เป็นรายได้ถ้ากำไร เป็นค่าใช้จ่ายถ้าขาดทุน */
    kindAlt?: PLEffect["kind"];
  };
};

/** ผลกระทบต่องบของหมวดย่อยนี้ คำนวณจาก dr/cr ไม่ได้พิมพ์มือ */
export function effectsOf(sub: SubCategory): SubEffects {
  const d = effectOf(coa(sub.dr), "dr");
  const c = effectOf(coa(sub.cr), "cr");
  const bs = [d.bs, c.bs].filter(Boolean) as BSEffect[];
  const pl = d.pl ?? c.pl;

  // บรรทัดที่ engine เพิ่มให้เฉพาะบางกรณี ไม่ได้อยู่ในคู่บัญชีหลัก
  let conditionalPl: SubEffects["conditionalPl"];
  if (sub.gainCoa) {
    // ขายทรัพย์ลงบัญชีกำไรเมื่อได้กำไร และลงบัญชีขาดทุนเมื่อขาดทุน — บอกทั้งสองทาง ไม่ใช่ทางเดียว
    conditionalPl = {
      line: `${coa(sub.gainCoa).nameTh} / ${coa(sub.lossCoa ?? sub.gainCoa).nameTh}`,
      kind: "revenue",
      kindAlt: sub.lossCoa ? "expense" : undefined,
      when: "เมื่อขายได้กำไรหรือขาดทุน",
    };
  } else if (sub.interestCoa) {
    // รับดอกเบี้ยเป็น "รายได้" · จ่ายดอกเบี้ยเป็น "ค่าใช้จ่าย" — อ่านจากประเภทบัญชี ไม่เดาจากทิศเงิน
    conditionalPl = {
      line: coa(sub.interestCoa).nameTh,
      kind: coa(sub.interestCoa).type === "income" ? "revenue" : "expense",
      when: "เฉพาะส่วนดอกเบี้ย เงินต้นไม่กระทบ",
    };
  }

  return { pl, bs, conditionalPl };
}

/** กระทบงบกำไรขาดทุนไหม — รวมกรณีที่กระทบเฉพาะบางเงื่อนไข */
export function affectsPL(sub: SubCategory): boolean {
  const { pl, conditionalPl } = effectsOf(sub);
  return !!pl || !!conditionalPl;
}

const TYPE_BY_KEY = new Map(TX_TYPES.map((t) => [t.key, t]));
const SUB_BY_CODE = new Map(
  TX_TYPES.flatMap((t) => t.subs.map((s) => [s.code, { type: t, sub: s }] as const))
);

export function getTxType(key: TxTypeKey): TxType {
  const t = TYPE_BY_KEY.get(key);
  if (!t) throw new Error(`ไม่พบประเภทรายการ: ${key}`);
  return t;
}

/** หมวดย่อยที่อนุญาตของประเภทรายการนี้ — ใช้ป้อน dropdown ในฟอร์ม */
export function allowedSubs(key: TxTypeKey): SubCategory[] {
  return getTxType(key).subs;
}

export function findSub(code: string): { type: TxType; sub: SubCategory } | undefined {
  return SUB_BY_CODE.get(code);
}

/**
 * ตรวจว่าคู่ (ประเภท, หมวดย่อย) ถูกต้องตามตารางกฎหรือไม่
 * ใช้กันการบันทึกผิดหมวด เช่น เงินกู้ที่ถูกลงเป็นรายได้
 */
export function isValidPair(key: TxTypeKey, code: string): boolean {
  return getTxType(key).subs.some((s) => s.code === code);
}

/** คำอธิบายผลกระทบต่องบ แบบภาษาคน สำหรับแสดงก่อนยืนยันในฟอร์ม */
export function impactLines(sub: SubCategory): string[] {
  const { pl, bs, conditionalPl } = effectsOf(sub);
  const out: string[] = [];
  const plWord = (k: PLEffect["kind"]) => (k === "revenue" ? "รายได้" : "ค่าใช้จ่าย");

  for (const b of bs) {
    out.push(`งบดุล · ${SIDE_TH[b.side]} — ${b.line} ${b.direction === "increase" ? "เพิ่มขึ้น" : "ลดลง"}`);
  }

  if (pl) {
    out.push(`กำไรขาดทุน · ${plWord(pl.kind)} — ${pl.line}`);
  } else if (conditionalPl) {
    // ขายทรัพย์/คืนเงินกู้ไม่มีบัญชี P&L ในคู่หลัก แต่ engine เติมบรรทัดให้เสมอเมื่อเข้าเงื่อนไข
    // ถ้าขึ้นว่า "ไม่กระทบ" ผู้ใช้จะเข้าใจผิดว่าขายทรัพย์แล้วกำไรไม่เข้างบ
    const kinds = conditionalPl.kindAlt
      ? `${plWord(conditionalPl.kind)}หรือ${plWord(conditionalPl.kindAlt)}`
      : plWord(conditionalPl.kind);
    out.push(`กำไรขาดทุน · ${kinds} — ${conditionalPl.line} (${conditionalPl.when})`);
  } else {
    out.push("กำไรขาดทุน · ไม่กระทบ");
  }

  /**
   * บรรทัดกระแสเงินสด — รายการที่ไม่มีเงินเคลื่อนต้องพูดตรงๆ
   *
   * เดิมประโยคนี้เป็น ternary ที่ตกไปเป็น "ย้ายระหว่างบัญชี" ทุกค่าที่ไม่ใช่ in/out
   * → รายการปรับปรุงทางบัญชีจะโชว์ว่า "ไม่นับ (ตัดออกจากงบรวม) — ย้ายระหว่างบัญชี"
   *   ซึ่งอ่านแล้วเข้าใจว่ามีเงินย้ายกระเป๋า ทั้งที่ไม่มีเงินขยับเลย
   * ตอนนี้คำมาจาก `cashDirectionLabel()` ที่เป็น switch ครบเคส
   */
  out.push(
    movesCash(sub)
      ? `กระแสเงินสด · ${CF_TH[sub.cashflow]} — ${cashDirectionLabel(sub.cash)}`
      : `กระแสเงินสด · ไม่กระทบ — ${cashDirectionLabel(sub.cash)} (รายการปรับปรุงทางบัญชี)`
  );

  return out;
}

/** คู่บัญชีแบบข้อความ สำหรับหน้าตารางกฎ */
export function entryLine(sub: SubCategory): string {
  return `Dr ${sub.dr} ${coa(sub.dr).nameTh} / Cr ${sub.cr} ${coa(sub.cr).nameTh}`;
}

/** ป้ายอธิบายว่าต้องกรอกอะไรเพิ่มสำหรับหมวดย่อยนี้ */
export const REQUIREMENT_LABEL: Record<FormRequirement, string> = {
  contact: "ต้องระบุผู้ติดต่อ",
  asset: "ต้องผูกทรัพย์",
  loanTerms: "ต้องกรอกเงื่อนไขสัญญา",
  capitalGain: "คำนวณกำไร/ขาดทุนจากการขาย",
  principalInterestSplit: "ต้องแยกเงินต้น/ดอกเบี้ย",
  transferTarget: "ต้องระบุบัญชีปลายทาง",
};

export const CASHFLOW_LABEL = CF_TH;
export const SIDE_LABEL = SIDE_TH;

/**
 * ขาที่ **ลดยอด** บัญชีพักตัวนี้ และอีกขาเป็นเงินสด — คือรูปร่างของการล้างยอดจริง
 *
 * ทิศสำคัญกว่าที่คิด: นับแค่ "แตะบัญชีเดียวกัน" จะได้ขาที่ **ตั้ง** ยอดมาด้วย
 * (เช่น `fin.deposit_received` เครดิต 2200 = ตั้งหนี้เงินมัดจำ ไม่ใช่ล้าง)
 * แล้วระบบจะเชื่อว่าบัญชีนั้นล้างได้ ทั้งที่ยอดมีแต่โตขึ้นเรื่อยๆ
 *
 * ลูกหนี้ (สินทรัพย์) ลดเมื่ออยู่ฝั่งเครดิต · เจ้าหนี้ (หนี้สิน) ลดเมื่ออยู่ฝั่งเดบิต
 * อ่านข้างจากประเภทบัญชีในผัง ไม่ใช่เดาจากรหัส
 */
function reducesAccrual(sub: SubCategory, accrualCoa: string): boolean {
  const type = coa(accrualCoa).type;
  // บัญชีพักที่เป็นรายได้/ค่าใช้จ่ายคือการพักใน P&L ซึ่งห้ามอยู่แล้ว — ไม่มีทางล้างให้
  if (type !== "asset" && type !== "liability") return false;
  const reducingSide: "dr" | "cr" = type === "asset" ? "cr" : "dr";
  if (sub[reducingSide] !== accrualCoa) return false;
  const otherLeg = reducingSide === "cr" ? sub.dr : sub.cr;
  return isCashAccount(otherLeg);
}

/**
 * ทุกหมวดที่ล้างบัญชีพักตัวนี้ได้ด้วยการคีย์มือ — **ไม่สนว่าลงกระแสเงินสดหมวดไหน**
 *
 * ใช้ตอบคำถามเดียวคือ "บัญชีนี้มีทางออกอยู่บ้างไหม" เพื่อแยกสองสาเหตุที่ต่างกัน
 * ในข้อความปฏิเสธ: ไม่มีทางล้างเลย vs มีทางล้างแต่คนละหมวด CF
 *
 * **อย่าใช้ตัวนี้ตัดสินว่าตั้งค้างได้** — ใช้ `clearingSubsFor()` ที่คุมหมวด CF ด้วย
 */
export function accrualClearingRoutes(accrualCoa: string): SubCategory[] {
  return TX_TYPES.flatMap((t) => t.subs).filter((s) => reducesAccrual(s, accrualCoa));
}

/**
 * ทางล้างบัญชีพักตัวนี้ที่ใช้กับรายการต้นทางซึ่งลงกระแสเงินสดหมวด `cashflow` ได้จริง
 *
 * ใช้ตรวจ invariant ข้อที่พลาดบ่อยที่สุด: ตั้งค้างได้แต่ล้างไม่ได้
 * = ลูกหนี้/เจ้าหนี้ค้างในงบดุลตลอดไป และรายได้ถูกนับซ้ำตอนเงินเข้าจริง (บทเรียนข้อ 7)
 *
 * เงื่อนไขหมวด CF ไม่ใช่เรื่องความสวยงาม: ซื้อทรัพย์ 10 ล้านแบบยังไม่จ่ายพักที่ 2100
 * ทางล้างเดียวที่มีคือ "จ่ายเจ้าหนี้ค้างจ่าย" ซึ่งเป็น Operating → เงิน 10 ล้านจะไปโผล่
 * กระแสเงินสดจากการดำเนินงาน ทั้งที่ต้องเป็น Investing · งบดุลสมดุลทุกบรรทัด
 * และไม่มีอะไรฟ้องเลย จับได้ก็ตอนอ่านงบกระแสเงินสดแล้วตัวเลขไม่เหมือนความจริง
 */
export function clearingSubsFor(accrualCoa: string, cashflow: CashflowSection): SubCategory[] {
  return accrualClearingRoutes(accrualCoa).filter((s) => s.cashflow === cashflow);
}

/**
 * เหตุผลที่หมวดนี้ยังตั้งค้างรับ-ค้างจ่ายจากฟอร์มไม่ได้ — คำนวณที่เดียว
 *
 * ทั้ง engine และฟอร์มอ่านจากตัวนี้ ข้อความปฏิเสธจึงไม่มีทางเพี้ยนจากกฎ
 * (บทเรียนข้อ 5: กฎเดียวกันห้ามเขียนสองที่)
 */
export type AccrualCheck =
  | { ok: true; account: string }
  | {
      ok: false;
      reason: "noCashMovement" | "noAccount" | "specialPath" | "noClearing" | "cashflowMismatch";
      /** เหตุผลภาษาคน ใช้ต่อท้ายข้อความปฏิเสธได้ตรงๆ */
      why: string;
    };

const ACCRUAL_SPECIAL_PATHS: FormRequirement[] = [
  "capitalGain",
  "principalInterestSplit",
  "transferTarget",
];

export function accrualCheck(sub: SubCategory): AccrualCheck {
  /**
   * ไม่มีขาเงินสดเลย → **ไม่มีอะไรให้แปลงเป็นลูกหนี้/เจ้าหนี้**
   *
   * ต้องมาก่อนด่าน `!sub.accrualCoa` เพราะสองเคสนี้คนละเรื่องกัน:
   *   ไม่มี `accrualCoa` = "หมวดนี้ตั้งใจไม่มีบัญชีพัก" (ล้างยอดในตัวเอง หรือยอดค้าง
   *                        ของมันไม่มีความหมายทางบัญชี · D-106)
   *   `cash: "none"`     = "รายการนี้ไม่มีเงินเคลื่อนอยู่แล้ว" (ไม่มีวันตั้งค้างได้)
   * ถ้าปล่อยให้ตกไปข้อความของ `noAccount` ผู้ใช้จะเข้าใจผิดคนละเรื่องกับความจริง
   */
  if (!movesCash(sub)) {
    return {
      ok: false,
      reason: "noCashMovement",
      why: "รายการปรับปรุงทางบัญชีไม่มีเงินเคลื่อน จึงไม่มีขาเงินสดให้เปลี่ยนเป็นลูกหนี้/เจ้าหนี้",
    };
  }

  if (!sub.accrualCoa) {
    return {
      ok: false,
      reason: "noAccount",
      /**
       * **ห้ามเขียนว่า "ยังไม่ได้ระบุ"** — อ่านเหมือนช่องที่ยังทำไม่เสร็จ แล้วรอให้มี
       * คนมาเติม ซึ่งไม่ควรมี: ทุกหมวดที่ไม่มีบัญชีพักวันนี้ **ตั้งใจไม่มี**
       * (หมวดที่ล้างยอดในตัวเองอยู่แล้ว · หมวดที่ตั้งค้างไม่มีความหมายทางบัญชี
       * เช่นการรับคืนหนี้สูญ ซึ่งลูกหนี้ก้อนนั้นออกจากสมุดไปแล้ว · D-106)
       */
      why:
        "ตารางกฎไม่ได้ระบุบัญชีลูกหนี้/เจ้าหนี้ของหมวดนี้ไว้ เพราะยอดค้างของหมวดนี้" +
        "ไม่มีความหมายทางบัญชี — ต้องบันทึกตอนเงินเข้าหรือออกจริง",
    };
  }

  if (sub.requires?.some((r) => ACCRUAL_SPECIAL_PATHS.includes(r))) {
    return {
      ok: false,
      reason: "specialPath",
      why:
        "หมวดที่ต้องแยกเงินต้น/ดอกเบี้ย รับรู้กำไรขาดทุน หรือโอนระหว่างบัญชี " +
        "ต้องบันทึกตอนเงินเคลื่อนจริง",
    };
  }

  const account = sub.accrualCoa;
  if (clearingSubsFor(account, sub.cashflow).length > 0) return { ok: true, account };

  const routes = accrualClearingRoutes(account);
  if (routes.length === 0) {
    return {
      ok: false,
      reason: "noClearing",
      why: `${coaLabel(account)} ยังไม่มีหมวดสำหรับล้าง ตั้งค้างไว้จะค้างในงบดุลตลอดไป`,
    };
  }

  const sections = [...new Set(routes.map((r) => CF_TH[r.cashflow]))].join(" / ");
  return {
    ok: false,
    reason: "cashflowMismatch",
    why:
      `หมวดที่ล้าง ${coaLabel(account)} ได้ ลงกระแสเงินสดหมวด${sections} ` +
      `ไม่ใช่หมวด${CF_TH[sub.cashflow]}ของรายการนี้ — ตอนจ่าย/รับเงินจริง ` +
      "ยอดจะไปโผล่ผิดหมวดในงบกระแสเงินสด",
  };
}

/**
 * ฟอร์มติ๊ก "ยังไม่ได้รับ/จ่ายเงิน" กับหมวดนี้ได้ไหม
 *
 * **ต่างจาก "มี `accrualCoa` ไหม"** และความต่างนี้สำคัญ:
 * `accrualCoa` ตอบว่า "ถ้าเงินยังไม่เคลื่อน ยอดนี้ไปพักที่บัญชีไหน" ซึ่งเป็นข้อมูลที่ถูก
 * สำหรับกลไกยืนยันรับ-จ่าย (C6) ที่จะลงบรรทัดเงินสดด้วย cashflow ของรายการต้นทาง
 * ส่วนฟังก์ชันนี้ตอบว่า "ตอนนี้คีย์ค้างจากฟอร์มได้จริงไหม" ซึ่งแคบกว่า เพราะยังมี
 * สามเงื่อนไขที่ปิดอยู่ (ดู `accrualCheck()` สำหรับเหตุผลรายข้อ):
 *
 * 1. **เส้นทางพิเศษ** (แยกเงินต้น/ดอกเบี้ย · รับรู้กำไรขาดทุน · โอน) engine สร้าง
 *    บรรทัดเงินสดเองหลายบรรทัด ยังไม่รองรับการพัก
 * 2. **บัญชีพักที่ยังไม่มีทางล้างเลย** (`1220` รอกลไก C6) — เปิดให้ตั้งค้างก่อน
 *    แปลว่าสร้างลูกหนี้ที่ไม่มีใครล้างได้
 * 3. **มีทางล้างแต่คนละหมวดกระแสเงินสด** — ล้างได้ แต่เงินไปโผล่ผิดหมวด
 *
 * เงื่อนไขอ่านจากตารางกฎทั้งหมด ไม่ได้ไล่ชื่อรหัสหมวด — เพิ่มหมวดใหม่จึงไม่หลุด
 */
export function canAccrueFromForm(sub: SubCategory): boolean {
  return accrualCheck(sub).ok;
}
