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

import { coa, type CoaAccount } from "./coa";

export type TxTypeKey =
  | "income"
  | "expense"
  | "invest_buy"
  | "invest_sell"
  | "finance_in"
  | "finance_out"
  | "transfer";

/** ทิศทางเงินสดของรายการ */
export type CashDirection = "in" | "out" | "both";

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
  | "principalInterestSplit"; // ต้องแยกเงินต้น/ดอกเบี้ย (Backlog ข้อ 5)

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
        requires: ["contact"],
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
        requires: ["asset", "capitalGain"],
        caution: "กำไรยังไม่รับรู้ (unrealized) ของทรัพย์ชิ้นนี้ต้องถูกล้างออกพร้อมกัน (Backlog ข้อ 4)",
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
        requires: ["asset", "contact"],
        caution: "ส่วนที่เป็นดอกเบี้ยให้แยกบันทึกที่ รายได้ › ดอกเบี้ยรับ — ขายฝาก",
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
        requires: ["asset", "contact"],
        caution: "ส่วนที่เป็นดอกเบี้ยให้แยกบันทึกที่ รายได้ › ดอกเบี้ยรับ — จำนอง",
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
        requires: ["contact"],
        caution: "ส่วนที่เป็นดอกเบี้ยให้แยกบันทึกที่ รายได้ › ดอกเบี้ยรับ — เงินให้กู้ยืม",
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
        requires: ["capitalGain"],
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
        requires: ["contact"],
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
        dr: CASH,
        cr: CASH,
        caution: "ไม่นับในงบกระแสเงินสด และตัดออกจากงบรวม จึงไม่กระทบกำไรขาดทุนและ NAV",
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
    case "equity": {
      // 3200 เงินถอนของเจ้าของ เป็น contra-equity: เดบิตแล้วส่วนของเจ้าของ "ลด"
      const isContra = account.code === "3200";
      const increase = isContra ? side === "cr" : side === "cr";
      return { bs: { line: account.nameTh, side: "equity", direction: increase ? "increase" : "decrease" } };
    }
  }
}

export type SubEffects = { pl?: PLEffect; bs: BSEffect[] };

/** ผลกระทบต่องบของหมวดย่อยนี้ คำนวณจาก dr/cr */
export function effectsOf(sub: SubCategory): SubEffects {
  const d = effectOf(coa(sub.dr), "dr");
  const c = effectOf(coa(sub.cr), "cr");
  const bs = [d.bs, c.bs].filter(Boolean) as BSEffect[];
  return { pl: d.pl ?? c.pl, bs };
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
  const { pl, bs } = effectsOf(sub);
  const out: string[] = [];

  for (const b of bs) {
    out.push(`งบดุล · ${SIDE_TH[b.side]} — ${b.line} ${b.direction === "increase" ? "เพิ่มขึ้น" : "ลดลง"}`);
  }

  out.push(
    pl
      ? `กำไรขาดทุน · ${pl.kind === "revenue" ? "รายได้" : "ค่าใช้จ่าย"} — ${pl.line}`
      : "กำไรขาดทุน · ไม่กระทบ"
  );

  const dir = sub.cash === "in" ? "เงินเข้า" : sub.cash === "out" ? "เงินออก" : "ย้ายระหว่างบัญชี";
  out.push(`กระแสเงินสด · ${CF_TH[sub.cashflow]} — ${dir}`);

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
};

export const CASHFLOW_LABEL = CF_TH;
export const SIDE_LABEL = SIDE_TH;
