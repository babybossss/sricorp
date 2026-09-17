/**
 * Backlog ข้อ 1 — ตารางกฎเดียวที่ระบบอ้างอิง
 *
 * ประเภทรายการ → หมวดย่อยที่อนุญาต → ผลกระทบต่องบ (P&L / งบดุล / กระแสเงินสด)
 *
 * กฎสำคัญ: หมวดย่อยไม่ใช่ dropdown อิสระ — เลือกได้เฉพาะที่ผูกกับประเภทรายการเท่านั้น
 * เช่น "กู้เงินเพิ่ม" อยู่ใต้ประเภท `finance_in` (จัดหาเงิน) เท่านั้น
 * จะเลือกจากประเภท `income` (รายได้) ไม่ได้ เพราะเงินเข้าบัญชีแต่ไม่ใช่รายได้
 */

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

/** หมวดของงบกระแสเงินสด */
export type CashflowSection = "operating" | "investing" | "financing";

/** ผลกระทบต่องบกำไรขาดทุน */
export type PLEffect = {
  /** ชื่อบรรทัดใน P&L — ต้องตรงกับหัวข้อในหน้า Ledger › กำไรขาดทุน */
  line: string;
  kind: "revenue" | "expense";
};

/** ผลกระทบต่องบดุล */
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
  pl?: PLEffect;
  bs?: BSEffect[];
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
        pl: { line: "รายได้ค่าเช่า", kind: "revenue" },
        bs: [{ line: "เงินสดและเงินฝาก", side: "asset", direction: "increase" }],
        requires: ["asset", "contact"],
      },
      {
        code: "inc.interest",
        label: "ดอกเบี้ยรับ",
        en: "Interest income",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และดอกเบี้ยรับเพิ่มขึ้น (เงินต้นยังไม่ลด)",
        cash: "in",
        cashflow: "operating",
        pl: { line: "ดอกเบี้ยรับ", kind: "revenue" },
        bs: [{ line: "เงินสดและเงินฝาก", side: "asset", direction: "increase" }],
        requires: ["contact"],
        caution: "ถ้าเป็นการรับคืนเงินต้นด้วย ให้แยกบันทึกเงินต้นที่ ลงทุน (ขาย/รับคืน)",
      },
      {
        code: "inc.dividend",
        label: "เงินปันผลรับ",
        en: "Dividend income",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และเงินปันผลรับเพิ่มขึ้น",
        cash: "in",
        cashflow: "operating",
        pl: { line: "เงินปันผล", kind: "revenue" },
        bs: [{ line: "เงินสดและเงินฝาก", side: "asset", direction: "increase" }],
      },
      {
        code: "inc.other",
        label: "รายได้อื่น",
        en: "Other income",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และรายได้อื่นเพิ่มขึ้น",
        cash: "in",
        cashflow: "operating",
        pl: { line: "รายได้อื่น", kind: "revenue" },
        bs: [{ line: "เงินสดและเงินฝาก", side: "asset", direction: "increase" }],
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
        code: "exp.admin",
        label: "ค่าบริหารจัดการ",
        en: "Admin expense",
        plain: "เงินออกจากบัญชี และค่าบริหารจัดการเพิ่มขึ้น",
        cash: "out",
        cashflow: "operating",
        pl: { line: "ค่าบริหารจัดการ", kind: "expense" },
        bs: [{ line: "เงินสดและเงินฝาก", side: "asset", direction: "decrease" }],
      },
      {
        code: "exp.repair",
        label: "ซ่อมบำรุง",
        en: "Repair & maintenance",
        plain: "เงินออกจากบัญชี และค่าซ่อมบำรุงเพิ่มขึ้น",
        cash: "out",
        cashflow: "operating",
        pl: { line: "ซ่อมบำรุง", kind: "expense" },
        bs: [{ line: "เงินสดและเงินฝาก", side: "asset", direction: "decrease" }],
        requires: ["asset"],
        caution: "ถ้าเป็นการปรับปรุงที่ทำให้มูลค่าทรัพย์เพิ่ม ให้ลงที่ ลงทุน (ซื้อ/ปล่อยเงิน) แทน",
      },
      {
        code: "exp.common",
        label: "ค่าส่วนกลาง / สาธารณูปโภค",
        en: "Common area & utilities",
        plain: "เงินออกจากบัญชี และค่าส่วนกลางเพิ่มขึ้น",
        cash: "out",
        cashflow: "operating",
        pl: { line: "ค่าบริหารจัดการ", kind: "expense" },
        bs: [{ line: "เงินสดและเงินฝาก", side: "asset", direction: "decrease" }],
        requires: ["asset"],
      },
      {
        code: "exp.tax",
        label: "ภาษี & ค่าธรรมเนียม",
        en: "Tax & fees",
        plain: "เงินออกจากบัญชี และภาษี/ค่าธรรมเนียมเพิ่มขึ้น",
        cash: "out",
        cashflow: "operating",
        pl: { line: "ภาษี & ค่าธรรมเนียม", kind: "expense" },
        bs: [{ line: "เงินสดและเงินฝาก", side: "asset", direction: "decrease" }],
      },
      {
        code: "exp.salary",
        label: "เงินเดือน & ค่าแรง",
        en: "Payroll",
        plain: "เงินออกจากบัญชี และค่าบริหารจัดการเพิ่มขึ้น",
        cash: "out",
        cashflow: "operating",
        pl: { line: "ค่าบริหารจัดการ", kind: "expense" },
        bs: [{ line: "เงินสดและเงินฝาก", side: "asset", direction: "decrease" }],
      },
    ],
  },
  {
    key: "invest_buy",
    label: "ลงทุน (ซื้อ/ปล่อยเงิน)",
    desc: "ซื้อทรัพย์ ปล่อยเงินขายฝาก",
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
        bs: [
          { line: "เงินสดและเงินฝาก", side: "asset", direction: "decrease" },
          { line: "Real Estate", side: "asset", direction: "increase" },
        ],
        requires: ["asset"],
        caution: "ไม่กระทบกำไรขาดทุน เป็นการย้ายรูปของสินทรัพย์เท่านั้น",
      },
      {
        code: "inv.buy_securities",
        label: "ซื้อหลักทรัพย์ / กองทุน",
        en: "Buy securities",
        plain: "เงินออกจากบัญชี และเงินลงทุนในงบดุลเพิ่มขึ้นตามต้นทุน",
        cash: "out",
        cashflow: "investing",
        bs: [
          { line: "เงินสดและเงินฝาก", side: "asset", direction: "decrease" },
          { line: "Investment", side: "asset", direction: "increase" },
        ],
      },
      {
        code: "inv.lend",
        label: "ให้กู้ / ปล่อยเงินขายฝาก",
        en: "Loan receivable issued",
        plain: "เงินออกจากบัญชี และลูกหนี้เงินให้กู้เพิ่มขึ้น — ไม่ใช่ค่าใช้จ่าย",
        cash: "out",
        cashflow: "investing",
        bs: [
          { line: "เงินสดและเงินฝาก", side: "asset", direction: "decrease" },
          { line: "RE รับจำนอง-ขายฝาก (ลูกหนี้)", side: "asset", direction: "increase" },
        ],
        requires: ["contact", "loanTerms"],
        caution: "ต้องกรอกเงื่อนไขสัญญาเพื่อสร้างตารางงวดรับดอกเบี้ย (Backlog ข้อ 2)",
      },
      {
        code: "inv.capex",
        label: "ปรับปรุงทรัพย์ (เพิ่มมูลค่า)",
        en: "Capital expenditure",
        plain: "เงินออกจากบัญชี และต้นทุนทรัพย์เพิ่มขึ้น — ไม่ลงเป็นค่าซ่อมบำรุง",
        cash: "out",
        cashflow: "investing",
        bs: [
          { line: "เงินสดและเงินฝาก", side: "asset", direction: "decrease" },
          { line: "Real Estate", side: "asset", direction: "increase" },
        ],
        requires: ["asset"],
      },
    ],
  },
  {
    key: "invest_sell",
    label: "ลงทุน (ขาย/รับคืน)",
    desc: "ขายทรัพย์ รับคืนเงินต้น",
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
        pl: { line: "กำไรจากการขายทรัพย์", kind: "revenue" },
        bs: [
          { line: "เงินสดและเงินฝาก", side: "asset", direction: "increase" },
          { line: "Real Estate", side: "asset", direction: "decrease" },
        ],
        requires: ["asset", "capitalGain"],
        caution: "กำไรยังไม่รับรู้ (unrealized) ของทรัพย์ชิ้นนี้ต้องถูกล้างออกพร้อมกัน (Backlog ข้อ 4)",
      },
      {
        code: "inv.sell_securities",
        label: "ขายหลักทรัพย์ / กองทุน",
        en: "Sell securities",
        plain: "ตัดเงินลงทุนออกตามต้นทุน รับเงินเข้าบัญชี และรับรู้กำไร/ขาดทุนจากการขาย",
        cash: "in",
        cashflow: "investing",
        pl: { line: "กำไรจากการขายทรัพย์", kind: "revenue" },
        bs: [
          { line: "เงินสดและเงินฝาก", side: "asset", direction: "increase" },
          { line: "Investment", side: "asset", direction: "decrease" },
        ],
        requires: ["capitalGain"],
      },
      {
        code: "inv.principal_back",
        label: "รับคืนเงินต้นที่ให้กู้",
        en: "Loan principal repaid",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และลูกหนี้เงินให้กู้ลดลง — ไม่ใช่รายได้",
        cash: "in",
        cashflow: "investing",
        bs: [
          { line: "เงินสดและเงินฝาก", side: "asset", direction: "increase" },
          { line: "RE รับจำนอง-ขายฝาก (ลูกหนี้)", side: "asset", direction: "decrease" },
        ],
        requires: ["contact"],
        caution: "ส่วนที่เป็นดอกเบี้ยให้แยกบันทึกที่ รายได้ › ดอกเบี้ยรับ",
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
        bs: [
          { line: "เงินสดและเงินฝาก", side: "asset", direction: "increase" },
          { line: "เงินกู้ธนาคาร", side: "liability", direction: "increase" },
        ],
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
        bs: [
          { line: "เงินสดและเงินฝาก", side: "asset", direction: "increase" },
          { line: "เงินกู้ยืมกรรมการ", side: "liability", direction: "increase" },
        ],
        requires: ["contact", "loanTerms"],
        caution: "เงินเข้าบัญชีแต่ไม่ใช่รายได้ ห้ามลงหมวด รายได้ เด็ดขาด",
      },
      {
        code: "fin.capital",
        label: "เพิ่มทุน",
        en: "Capital injection",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และส่วนของเจ้าของเพิ่มขึ้น — ไม่ใช่รายได้",
        cash: "in",
        cashflow: "financing",
        bs: [
          { line: "เงินสดและเงินฝาก", side: "asset", direction: "increase" },
          { line: "ทุน", side: "equity", direction: "increase" },
        ],
        requires: ["contact"],
      },
      {
        code: "fin.deposit_received",
        label: "รับเงินมัดจำ / ประกันจากผู้เช่า",
        en: "Security deposit received",
        plain: "เงินเข้าบัญชีเพิ่มขึ้น และหนี้สินเงินมัดจำเพิ่มขึ้น — ต้องคืนภายหลัง จึงไม่ใช่รายได้",
        cash: "in",
        cashflow: "financing",
        bs: [
          { line: "เงินสดและเงินฝาก", side: "asset", direction: "increase" },
          { line: "เงินมัดจำผู้เช่า", side: "liability", direction: "increase" },
        ],
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
        code: "fin.repay",
        label: "ชำระคืนเงินกู้ (เงินต้น + ดอกเบี้ย)",
        en: "Loan repayment",
        plain: "เงินออกจากบัญชี · ส่วนเงินต้นลดหนี้สินในงบดุล · ส่วนดอกเบี้ยเป็นค่าใช้จ่ายใน P&L",
        cash: "out",
        cashflow: "financing",
        pl: { line: "ดอกเบี้ยจ่าย", kind: "expense" },
        bs: [
          { line: "เงินสดและเงินฝาก", side: "asset", direction: "decrease" },
          { line: "เงินกู้ธนาคาร", side: "liability", direction: "decrease" },
        ],
        requires: ["contact", "principalInterestSplit"],
        caution: "เงินต้นไม่ใช่ค่าใช้จ่าย ต้องแยกออกจากดอกเบี้ยเสมอ (Backlog ข้อ 5)",
      },
      {
        code: "fin.interest_only",
        label: "จ่ายดอกเบี้ยอย่างเดียว",
        en: "Interest payment",
        plain: "เงินออกจากบัญชี และดอกเบี้ยจ่ายเพิ่มขึ้น — หนี้สินเงินต้นไม่เปลี่ยน",
        cash: "out",
        cashflow: "financing",
        pl: { line: "ดอกเบี้ยจ่าย", kind: "expense" },
        bs: [{ line: "เงินสดและเงินฝาก", side: "asset", direction: "decrease" }],
        requires: ["contact"],
      },
      {
        code: "fin.dividend_paid",
        label: "จ่ายเงินปันผล / ถอนทุน",
        en: "Dividend paid",
        plain: "เงินออกจากบัญชี และส่วนของเจ้าของลดลง — ไม่ใช่ค่าใช้จ่ายใน P&L",
        cash: "out",
        cashflow: "financing",
        bs: [
          { line: "เงินสดและเงินฝาก", side: "asset", direction: "decrease" },
          { line: "กำไรสะสม", side: "equity", direction: "decrease" },
        ],
        requires: ["contact"],
        caution: "เงินปันผลจ่ายลดส่วนของเจ้าของ ไม่ใช่ค่าใช้จ่าย",
      },
      {
        code: "fin.deposit_refund",
        label: "คืนเงินมัดจำผู้เช่า",
        en: "Security deposit refunded",
        plain: "เงินออกจากบัญชี และหนี้สินเงินมัดจำลดลง — ไม่ใช่ค่าใช้จ่าย",
        cash: "out",
        cashflow: "financing",
        bs: [
          { line: "เงินสดและเงินฝาก", side: "asset", direction: "decrease" },
          { line: "เงินมัดจำผู้เช่า", side: "liability", direction: "decrease" },
        ],
        requires: ["contact"],
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
        cashflow: "operating",
        bs: [{ line: "เงินสดและเงินฝาก", side: "asset", direction: "increase" }],
        caution: "ตัดออกจากงบรวม (eliminate) จึงไม่กระทบกำไรขาดทุนและ NAV",
      },
    ],
  },
];

const TYPE_BY_KEY = new Map(TX_TYPES.map((t) => [t.key, t]));
const SUB_BY_CODE = new Map(TX_TYPES.flatMap((t) => t.subs.map((s) => [s.code, { type: t, sub: s }] as const)));

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
  const out: string[] = [];
  for (const b of sub.bs ?? []) {
    const side = { asset: "สินทรัพย์", liability: "หนี้สิน", equity: "ส่วนของเจ้าของ" }[b.side];
    out.push(`งบดุล · ${side} — ${b.line} ${b.direction === "increase" ? "เพิ่มขึ้น" : "ลดลง"}`);
  }
  if (sub.pl) {
    out.push(`กำไรขาดทุน · ${sub.pl.kind === "revenue" ? "รายได้" : "ค่าใช้จ่าย"} — ${sub.pl.line}`);
  } else {
    out.push("กำไรขาดทุน · ไม่กระทบ");
  }
  const cf = { operating: "ดำเนินงาน", investing: "ลงทุน", financing: "จัดหาเงิน" }[sub.cashflow];
  out.push(`กระแสเงินสด · ${cf} — เงิน${sub.cash === "in" ? "เข้า" : sub.cash === "out" ? "ออก" : "ย้ายระหว่างบัญชี"}`);
  return out;
}

/** ป้ายอธิบายว่าต้องกรอกอะไรเพิ่มสำหรับหมวดย่อยนี้ */
export const REQUIREMENT_LABEL: Record<FormRequirement, string> = {
  contact: "ต้องระบุผู้ติดต่อ",
  asset: "ต้องผูกทรัพย์",
  loanTerms: "ต้องกรอกเงื่อนไขสัญญา",
  capitalGain: "คำนวณกำไร/ขาดทุนจากการขาย",
  principalInterestSplit: "ต้องแยกเงินต้น/ดอกเบี้ย",
};
