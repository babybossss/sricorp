/**
 * ผังบัญชีจริงของ SRI — ตั้งต้นจากชีท Setup ใน SRI_Transaction_ERP.xlsx (41 รหัส)
 * แล้วเพิ่มตามที่แม่บทและงบตั้งต้นต้องใช้
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
};

/**
 * บรรทัดในงบที่บัญชีนี้ไปโผล่ **ไม่ได้อยู่ที่นี่** — อยู่ใน `statements.ts`
 * เคยมีฟิลด์ `plLine` ซ้อนอยู่ในไฟล์นี้ แล้วมันไม่ตรงกับ PL_LAYOUT จริง
 * (5400 ดอกเบี้ยจ่าย เขียนไว้ว่า "ต้นทุนทางการเงิน" แต่ในงบเป็นบรรทัด "ดอกเบี้ยจ่าย")
 * กฎเดียวกันเขียนสองที่แล้วไม่ตรงกัน = ต้องเหลือที่เดียว
 */

export const COA: CoaAccount[] = [
  // ---------- สินทรัพย์ 1xxx ----------
  { code: "1100", nameTh: "เงินสดและเงินฝากธนาคาร", nameEn: "Cash & bank", type: "asset" },
  { code: "1200", nameTh: "ลูกหนี้ค่าเช่า", nameEn: "Rent receivable", type: "asset" },
  { code: "1210", nameTh: "ลูกหนี้ดอกเบี้ย", nameEn: "Interest receivable", type: "asset" },
  // บัญชีพักของทุกหมวดที่เงินยังไม่เข้า แต่ไม่ใช่ค่าเช่าหรือดอกเบี้ย (D-069)
  // ขายทองคำแล้วยังไม่ได้เงิน = คนซื้อเป็นหนี้เรา — เป็นลูกหนี้ ไม่ใช่ "เงินระหว่างทาง"
  { code: "1220", nameTh: "ลูกหนี้อื่น (รอรับเงิน)", nameEn: "Other receivable", type: "asset" },
  { code: "1300", nameTh: "เงินให้กู้ยืม - เงินต้น", nameEn: "Loan principal receivable", type: "asset" },
  { code: "1400", nameTh: "เงินลงทุนขายฝาก - เงินต้น", nameEn: "Redemption principal", type: "asset" },
  { code: "1410", nameTh: "เงินลงทุนจำนอง - เงินต้น", nameEn: "Mortgage principal", type: "asset" },
  { code: "1500", nameTh: "อสังหาริมทรัพย์เพื่อการลงทุน", nameEn: "Investment property", type: "asset" },
  { code: "1510", nameTh: "ค่ารีโนเวท (บันทึกเป็นทุน)", nameEn: "Renovation capitalised", type: "asset" },
  { code: "1600", nameTh: "เงินมัดจำจ่าย", nameEn: "Deposits paid", type: "asset" },
  // เพิ่มจากแม่บท: พอร์ตหลักทรัพย์ยังไม่มีรหัสใน Excel เดิม
  { code: "1700", nameTh: "เงินลงทุนในหลักทรัพย์", nameEn: "Investment in securities", type: "asset" },
  // แยกจาก 1700 เพราะทองคำและคริปโตเป็นคนละหมวดใหญ่ (Commodity & Cash ไม่ใช่ Paper Asset)
  // ถ้าใช้บัญชีเดียวกับหุ้น จะแยกสองหมวดนี้ออกจากกันในรายงานไม่ได้เลย
  { code: "1720", nameTh: "เงินลงทุนในทองคำและสินทรัพย์ทางเลือก", nameEn: "Gold & alternative assets", type: "asset" },
  // รายการระหว่างกันในกองกลาง — แยกจากพอร์ตจริง ไม่งั้นต้นทุนเฉลี่ยและ NAV เพี้ยน
  { code: "1310", nameTh: "ลูกหนี้ระหว่างกัน (ในกองกลาง)", nameEn: "Intercompany receivable", type: "asset" },
  { code: "1710", nameTh: "เงินลงทุนในบริษัทในเครือ", nameEn: "Investment in related company", type: "asset" },

  // ---------- หนี้สิน 2xxx ----------
  { code: "2100", nameTh: "เจ้าหนี้การค้า-เจ้าหนี้อื่น", nameEn: "Trade & other payables", type: "liability" },
  { code: "2200", nameTh: "เงินมัดจำรับจากผู้เช่า", nameEn: "Tenant deposits received", type: "liability" },
  { code: "2300", nameTh: "เงินกู้ยืมกรรมการ", nameEn: "Director loan", type: "liability" },
  { code: "2400", nameTh: "เงินกู้ยืมอื่น", nameEn: "Other loans", type: "liability" },
  // เพิ่มจากแม่บท: แยกเงินกู้ธนาคารออกจากเงินกู้ยืมอื่น
  { code: "2410", nameTh: "เงินกู้ธนาคาร", nameEn: "Bank borrowing", type: "liability" },
  { code: "2310", nameTh: "เจ้าหนี้ระหว่างกัน (ในกองกลาง)", nameEn: "Intercompany payable", type: "liability" },

  // ---------- ส่วนของเจ้าของ 3xxx ----------
  { code: "3100", nameTh: "ทุนตั้งต้น", nameEn: "Paid-in capital", type: "equity" },
  { code: "3200", nameTh: "เงินถอนของเจ้าของ", nameEn: "Drawings", type: "equity" },
  // ตั้งยอดตั้งต้นไม่ได้ถ้าไม่มีบัญชีนี้ — กำไรที่สะสมมาก่อนวันตัดยอดไม่ใช่ "ทุนที่ใส่เข้ามา"
  // ยัดรวมกันจะอ่านไม่ออกว่าเงินส่วนไหนลงทุนไป ส่วนไหนหามาได้
  { code: "3300", nameTh: "กำไรสะสม", nameEn: "Retained earnings", type: "equity" },

  // ---------- รายได้ 4xxx ----------
  { code: "4100", nameTh: "ดอกเบี้ยรับ - ขายฝาก", nameEn: "Interest income - Redemption", type: "income" },
  { code: "4110", nameTh: "ดอกเบี้ยรับ - จำนอง", nameEn: "Interest income - Mortgage", type: "income" },
  { code: "4120", nameTh: "ดอกเบี้ยรับ - เงินให้กู้ยืม", nameEn: "Interest income - Loan", type: "income" },
  { code: "4200", nameTh: "รายได้ค่าเช่า", nameEn: "Rental income", type: "income" },
  { code: "4210", nameTh: "รายได้ค่าเช่าซื้อ", nameEn: "Hire-purchase income", type: "income" },
  { code: "4300", nameTh: "กำไรจากการขายทรัพย์", nameEn: "Gain on sale of property", type: "income" },
  { code: "4310", nameTh: "เงินกินเปล่า", nameEn: "Key money", type: "income" },
  { code: "4400", nameTh: "ค่าคอมมิชชั่น-ค่าธรรมเนียมรับ", nameEn: "Fee & commission income", type: "income" },
  { code: "4900", nameTh: "รายได้อื่น", nameEn: "Other income", type: "income" },
  // เพิ่มจากแม่บท: เงินปันผลรับจากพอร์ตหลักทรัพย์
  { code: "4410", nameTh: "เงินปันผลรับ", nameEn: "Dividend income", type: "income" },

  // ---------- ค่าใช้จ่าย 5xxx ----------
  { code: "5100", nameTh: "ค่าส่วนกลาง", nameEn: "Common area fee", type: "expense" },
  { code: "5110", nameTh: "ค่าน้ำ-ค่าไฟ", nameEn: "Utilities", type: "expense" },
  { code: "5120", nameTh: "ค่าซ่อมแซม-บำรุงรักษา", nameEn: "Repair & maintenance", type: "expense" },
  { code: "5130", nameTh: "ค่าตกแต่ง-เฟอร์นิเจอร์", nameEn: "Furnishing & fit-out", type: "expense" },
  { code: "5140", nameTh: "ค่าแม่บ้าน-ทำความสะอาด", nameEn: "Cleaning & housekeeping", type: "expense" },
  { code: "5200", nameTh: "ค่าคอมมิชชั่นจ่าย", nameEn: "Commission expense", type: "expense" },
  { code: "5210", nameTh: "ค่านายหน้า-ค่าแนะนำ", nameEn: "Referral fee", type: "expense" },
  { code: "5220", nameTh: "ค่าการตลาด-โฆษณา", nameEn: "Marketing & advertising", type: "expense" },
  { code: "5300", nameTh: "ค่าธรรมเนียมกรมที่ดิน", nameEn: "Land office fees", type: "expense" },
  { code: "5310", nameTh: "ภาษีและอากรแสตมป์", nameEn: "Taxes & stamp duty", type: "expense" },
  { code: "5320", nameTh: "ค่าทนาย-ค่าทำสัญญา", nameEn: "Legal & contract fees", type: "expense" },
  { code: "5330", nameTh: "ค่าธรรมเนียมธนาคาร", nameEn: "Bank charges", type: "expense" },
  { code: "5400", nameTh: "ดอกเบี้ยจ่าย", nameEn: "Interest expense", type: "expense" },
  { code: "5500", nameTh: "เงินเดือน-ค่าแรง", nameEn: "Salary & wages", type: "expense" },
  { code: "5510", nameTh: "ค่าเดินทาง-น้ำมัน", nameEn: "Travel & fuel", type: "expense" },
  { code: "5520", nameTh: "ค่าใช้จ่ายสำนักงาน", nameEn: "Office expenses", type: "expense" },
  { code: "5900", nameTh: "ค่าใช้จ่ายอื่น", nameEn: "Other expenses", type: "expense" },
  // คู่ตรงข้ามของ 4300 — เดิมขาดทุนจากการขายไปกองใน "ค่าใช้จ่ายอื่น"
  // ทำให้อ่านงบไม่ออกว่าขาดทุนจากการขายจริงเท่าไร ปนกับค่าใช้จ่ายจรทั่วไป
  { code: "5910", nameTh: "ขาดทุนจากการขายทรัพย์", nameEn: "Loss on sale of property", type: "expense" },
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
