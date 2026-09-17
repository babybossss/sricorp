/**
 * ผังบัญชีจริงของ SRI — 41 รหัส ตรงกับชีท Setup ใน SRI_Transaction_ERP.xlsx
 *
 * ตารางกฎ (`tx-rules.ts`) อ้างรหัสจากที่นี่ เพื่อให้หมวดย่อยผูกกับผังบัญชีจริง
 * ไม่ใช่ชื่อบรรทัดลอยๆ ตอน seed ลง Supabase ใช้ไฟล์นี้เป็นแหล่งความจริง
 */

export type CoaType = "asset" | "liability" | "equity" | "income" | "expense";

export type CoaAccount = {
  code: string;
  nameTh: string;
  nameEn: string;
  type: CoaType;
  /** บรรทัดที่ไปโผล่ในงบกำไรขาดทุน (เฉพาะ income/expense) */
  plLine?: string;
};

export const COA: CoaAccount[] = [
  // ---------- สินทรัพย์ 1xxx ----------
  { code: "1100", nameTh: "เงินสดและเงินฝากธนาคาร", nameEn: "Cash & bank", type: "asset" },
  { code: "1200", nameTh: "ลูกหนี้ค่าเช่า", nameEn: "Rent receivable", type: "asset" },
  { code: "1210", nameTh: "ลูกหนี้ดอกเบี้ย", nameEn: "Interest receivable", type: "asset" },
  { code: "1300", nameTh: "เงินให้กู้ยืม - เงินต้น", nameEn: "Loan principal receivable", type: "asset" },
  { code: "1400", nameTh: "เงินลงทุนขายฝาก - เงินต้น", nameEn: "Redemption principal", type: "asset" },
  { code: "1410", nameTh: "เงินลงทุนจำนอง - เงินต้น", nameEn: "Mortgage principal", type: "asset" },
  { code: "1500", nameTh: "อสังหาริมทรัพย์เพื่อการลงทุน", nameEn: "Investment property", type: "asset" },
  { code: "1510", nameTh: "ค่ารีโนเวท (บันทึกเป็นทุน)", nameEn: "Renovation capitalised", type: "asset" },
  { code: "1600", nameTh: "เงินมัดจำจ่าย", nameEn: "Deposits paid", type: "asset" },
  // เพิ่มจากแม่บท: พอร์ตหลักทรัพย์ยังไม่มีรหัสใน Excel เดิม
  { code: "1700", nameTh: "เงินลงทุนในหลักทรัพย์", nameEn: "Investment in securities", type: "asset" },

  // ---------- หนี้สิน 2xxx ----------
  { code: "2100", nameTh: "เจ้าหนี้การค้า-เจ้าหนี้อื่น", nameEn: "Trade & other payables", type: "liability" },
  { code: "2200", nameTh: "เงินมัดจำรับจากผู้เช่า", nameEn: "Tenant deposits received", type: "liability" },
  { code: "2300", nameTh: "เงินกู้ยืมกรรมการ", nameEn: "Director loan", type: "liability" },
  { code: "2400", nameTh: "เงินกู้ยืมอื่น", nameEn: "Other loans", type: "liability" },
  // เพิ่มจากแม่บท: แยกเงินกู้ธนาคารออกจากเงินกู้ยืมอื่น
  { code: "2410", nameTh: "เงินกู้ธนาคาร", nameEn: "Bank borrowing", type: "liability" },

  // ---------- ส่วนของเจ้าของ 3xxx ----------
  { code: "3100", nameTh: "ทุนตั้งต้น", nameEn: "Paid-in capital", type: "equity" },
  { code: "3200", nameTh: "เงินถอนของเจ้าของ", nameEn: "Drawings", type: "equity" },

  // ---------- รายได้ 4xxx ----------
  { code: "4100", nameTh: "ดอกเบี้ยรับ - ขายฝาก", nameEn: "Interest income - Redemption", type: "income", plLine: "รายได้ดอกเบี้ย" },
  { code: "4110", nameTh: "ดอกเบี้ยรับ - จำนอง", nameEn: "Interest income - Mortgage", type: "income", plLine: "รายได้ดอกเบี้ย" },
  { code: "4120", nameTh: "ดอกเบี้ยรับ - เงินให้กู้ยืม", nameEn: "Interest income - Loan", type: "income", plLine: "รายได้ดอกเบี้ย" },
  { code: "4200", nameTh: "รายได้ค่าเช่า", nameEn: "Rental income", type: "income", plLine: "รายได้ค่าเช่า" },
  { code: "4210", nameTh: "รายได้ค่าเช่าซื้อ", nameEn: "Hire-purchase income", type: "income", plLine: "รายได้ค่าเช่า" },
  { code: "4300", nameTh: "กำไรจากการขายทรัพย์", nameEn: "Gain on sale of property", type: "income", plLine: "กำไรจากการขายทรัพย์" },
  { code: "4310", nameTh: "เงินกินเปล่า", nameEn: "Key money", type: "income", plLine: "รายได้อื่น" },
  { code: "4400", nameTh: "ค่าคอมมิชชั่น-ค่าธรรมเนียมรับ", nameEn: "Fee & commission income", type: "income", plLine: "รายได้อื่น" },
  { code: "4900", nameTh: "รายได้อื่น", nameEn: "Other income", type: "income", plLine: "รายได้อื่น" },
  // เพิ่มจากแม่บท: เงินปันผลรับจากพอร์ตหลักทรัพย์
  { code: "4410", nameTh: "เงินปันผลรับ", nameEn: "Dividend income", type: "income", plLine: "รายได้อื่น" },

  // ---------- ค่าใช้จ่าย 5xxx ----------
  { code: "5100", nameTh: "ค่าส่วนกลาง", nameEn: "Common area fee", type: "expense", plLine: "ค่าใช้จ่ายเกี่ยวกับทรัพย์สิน" },
  { code: "5110", nameTh: "ค่าน้ำ-ค่าไฟ", nameEn: "Utilities", type: "expense", plLine: "ค่าใช้จ่ายเกี่ยวกับทรัพย์สิน" },
  { code: "5120", nameTh: "ค่าซ่อมแซม-บำรุงรักษา", nameEn: "Repair & maintenance", type: "expense", plLine: "ค่าใช้จ่ายเกี่ยวกับทรัพย์สิน" },
  { code: "5130", nameTh: "ค่าตกแต่ง-เฟอร์นิเจอร์", nameEn: "Furnishing & fit-out", type: "expense", plLine: "ค่าใช้จ่ายเกี่ยวกับทรัพย์สิน" },
  { code: "5140", nameTh: "ค่าแม่บ้าน-ทำความสะอาด", nameEn: "Cleaning & housekeeping", type: "expense", plLine: "ค่าใช้จ่ายเกี่ยวกับทรัพย์สิน" },
  { code: "5200", nameTh: "ค่าคอมมิชชั่นจ่าย", nameEn: "Commission expense", type: "expense", plLine: "ค่าใช้จ่ายในการขาย" },
  { code: "5210", nameTh: "ค่านายหน้า-ค่าแนะนำ", nameEn: "Referral fee", type: "expense", plLine: "ค่าใช้จ่ายในการขาย" },
  { code: "5220", nameTh: "ค่าการตลาด-โฆษณา", nameEn: "Marketing & advertising", type: "expense", plLine: "ค่าใช้จ่ายในการขาย" },
  { code: "5300", nameTh: "ค่าธรรมเนียมกรมที่ดิน", nameEn: "Land office fees", type: "expense", plLine: "ค่าใช้จ่ายบริหาร" },
  { code: "5310", nameTh: "ภาษีและอากรแสตมป์", nameEn: "Taxes & stamp duty", type: "expense", plLine: "ค่าใช้จ่ายบริหาร" },
  { code: "5320", nameTh: "ค่าทนาย-ค่าทำสัญญา", nameEn: "Legal & contract fees", type: "expense", plLine: "ค่าใช้จ่ายบริหาร" },
  { code: "5330", nameTh: "ค่าธรรมเนียมธนาคาร", nameEn: "Bank charges", type: "expense", plLine: "ค่าใช้จ่ายบริหาร" },
  { code: "5400", nameTh: "ดอกเบี้ยจ่าย", nameEn: "Interest expense", type: "expense", plLine: "ต้นทุนทางการเงิน" },
  { code: "5500", nameTh: "เงินเดือน-ค่าแรง", nameEn: "Salary & wages", type: "expense", plLine: "ค่าใช้จ่ายบริหาร" },
  { code: "5510", nameTh: "ค่าเดินทาง-น้ำมัน", nameEn: "Travel & fuel", type: "expense", plLine: "ค่าใช้จ่ายบริหาร" },
  { code: "5520", nameTh: "ค่าใช้จ่ายสำนักงาน", nameEn: "Office expenses", type: "expense", plLine: "ค่าใช้จ่ายบริหาร" },
  { code: "5900", nameTh: "ค่าใช้จ่ายอื่น", nameEn: "Other expenses", type: "expense", plLine: "ค่าใช้จ่ายอื่น" },
];

const BY_CODE = new Map(COA.map((a) => [a.code, a]));

export function coa(code: string): CoaAccount {
  const a = BY_CODE.get(code);
  if (!a) throw new Error(`ไม่พบรหัสบัญชี ${code} ในผังบัญชี`);
  return a;
}

export function coaLabel(code: string): string {
  const a = coa(code);
  return `${a.code} ${a.nameTh}`;
}

/** บรรทัดเงินสด/ธนาคาร — Money Invariant 2 บังคับว่าต้องผูก bank_account */
export const CASH_COA = "1100";
export function isCashAccount(code: string): boolean {
  return /^11\d\d$/.test(code);
}
