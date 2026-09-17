import type { TxTypeKey } from "@/lib/rules/tx-rules";

export type LedgerStatus = "wait" | "saved" | "done" | "late" | "off";

export type LedgerRow = {
  id: string;
  docDate: string;
  cashDate: string;
  typeKey: TxTypeKey;
  subCode: string;
  detail: string;
  assetName: string;
  ownerId: string;
  accountName: string;
  inAmt: number | null;
  outAmt: number | null;
  status: LedgerStatus;
  hasFile: boolean;
  contactId?: string;
};

export const STATUS_LABEL: Record<LedgerStatus, string> = {
  wait: "รออนุมัติ",
  saved: "บันทึกแล้ว",
  done: "รับ/จ่ายแล้ว",
  late: "ค้าง",
  off: "ยกเลิก",
};

export const LEDGER: LedgerRow[] = [
  { id: "l1", docDate: "01/09/2026", cashDate: "03/09/2026", typeKey: "income", subCode: "inc.rent", detail: "ค่าเช่า ก.ย.", assetName: "คอนโดตัวอย่าง C", ownerId: "thanakorn", accountName: "ธนากร - BBL 888", inAmt: 12000, outAmt: null, status: "done", hasFile: true, contactId: "c1" },
  { id: "l2", docDate: "02/09/2026", cashDate: "02/09/2026", typeKey: "income", subCode: "inc.interest_srr", detail: "ดอกเบี้ยขายฝาก งวด 8", assetName: "ทาวน์โฮมตัวอย่าง B", ownerId: "corp", accountName: "SRI - SCB", inAmt: 45000, outAmt: null, status: "done", hasFile: true, contactId: "c4" },
  { id: "l3", docDate: "04/09/2026", cashDate: "—", typeKey: "income", subCode: "inc.rent", detail: "ค่าเช่า ก.ย. (ยังไม่ได้รับ)", assetName: "คอนโดตัวอย่าง A", ownerId: "corp", accountName: "SRI - SCB", inAmt: 31500, outAmt: null, status: "late", hasFile: false, contactId: "c2" },
  { id: "l4", docDate: "05/09/2026", cashDate: "05/09/2026", typeKey: "expense", subCode: "exp.common", detail: "ค่าส่วนกลาง Q3", assetName: "คอนโดตัวอย่าง C", ownerId: "thanakorn", accountName: "ธนากร - BBL 888", inAmt: null, outAmt: 9800, status: "done", hasFile: true },
  { id: "l5", docDate: "08/09/2026", cashDate: "08/09/2026", typeKey: "invest_buy", subCode: "inv.lend", detail: "ปล่อยเงินขายฝากรายใหม่", assetName: "ที่ดินตัวอย่าง D", ownerId: "corp", accountName: "SRI - SCB", inAmt: null, outAmt: 1800000, status: "saved", hasFile: true, contactId: "c4" },
  { id: "l6", docDate: "10/09/2026", cashDate: "—", typeKey: "expense", subCode: "exp.repair", detail: "ค่าซ่อมแอร์ 2 ห้อง", assetName: "คอนโดตัวอย่าง A", ownerId: "corp", accountName: "SRI - SCB", inAmt: null, outAmt: 12400, status: "wait", hasFile: true, contactId: "c5" },
  { id: "l7", docDate: "12/09/2026", cashDate: "12/09/2026", typeKey: "finance_in", subCode: "fin.loan_director", detail: "เงินกู้ยืมกรรมการเพิ่ม", assetName: "—", ownerId: "corp", accountName: "SRI - SCB", inAmt: 70000, outAmt: null, status: "saved", hasFile: false, contactId: "c4" },
  { id: "l8", docDate: "15/09/2026", cashDate: "15/09/2026", typeKey: "transfer", subCode: "trf.internal", detail: "โอนเข้าบัญชีบริษัท", assetName: "—", ownerId: "thanawin", accountName: "ธนวินท์ - KBANK", inAmt: null, outAmt: 20000, status: "saved", hasFile: true },
];

/** งบกำไรขาดทุนรายเดือน 12 เดือน (หน่วยบาท) */
const k = (arr: number[]) => arr.map((v) => v * 1000);

export const PL_SERIES = {
  rent: k([412, 412, 424, 424, 436, 436, 448, 448, 486, 486, 486, 486]),
  interest: k([180, 180, 195, 195, 210, 210, 225, 225, 240, 240, 240, 240]),
  dividend: k([0, 0, 64, 0, 0, 72, 0, 0, 68, 0, 0, 80]),
  gain: k([0, 0, 0, 320, 0, 0, 0, 0, 0, 0, 0, 0]),
  admin: k([-180, -180, -186, -186, -192, -192, -198, -198, -204, -204, -204, -204]),
  repair: k([-42, -38, -51, -47, -62, -58, -44, -49, -66, -52, -48, -55]),
  interestExp: k([-310, -310, -310, -305, -305, -305, -300, -300, -300, -295, -295, -295]),
  tax: k([-28, -28, -34, -31, -36, -38, -33, -35, -40, -37, -36, -39]),
};

export const CF_GROUPS = [
  {
    name: "ดำเนินงาน",
    total: 480000,
    items: [
      { name: "รับค่าเช่าและดอกเบี้ย", amount: 1126500 },
      { name: "ค่าบริหาร & ซ่อมบำรุง", amount: -316500 },
      { name: "ดอกเบี้ยจ่าย & ภาษี", amount: -330000 },
    ],
  },
  { name: "ลงทุน", total: -1800000, items: [{ name: "ปล่อยเงินขายฝากรายใหม่", amount: -1800000 }] },
  { name: "จัดหาเงิน", total: 70000, items: [{ name: "เงินกู้ยืมกรรมการเพิ่ม", amount: 70000 }] },
];

export const CF_ACCOUNTS = [
  { name: "SRI - SCB", open: 4102120, in: 146500, out: -1908500, close: 2340120 },
  { name: "ธนากร - BBL 888", open: 1284300, in: 12000, out: -9800, close: 1286500 },
  { name: "ธนวินท์ - KBANK", open: 612400, in: 0, out: -20000, close: 592400 },
  { name: "เบ็ญจพร - BBL", open: 318900, in: 8000, out: 0, close: 326900 },
];

/** ยืนยันรับ-จ่าย · จับคู่กับ statement */
export const CASH_GROUPS = [
  {
    bank: "SRI - SCB",
    system: 2340120,
    stmt: "2,340,120.00",
    match: "ตรงกัน",
    matched: true,
    rows: [
      { id: "cc1", name: "ดอกเบี้ยขายฝาก งวด 9", sub: "ทาวน์โฮมตัวอย่าง B", due: "16/09/2026", expect: 36000, actual: "36,000.00", date: "16/09/2026", checked: true, partial: "" },
      { id: "cc2", name: "ค่าน้ำ-ไฟส่วนกลาง", sub: "SRI Corporation", due: "15/09/2026", expect: -8600, actual: "8,600.00", date: "15/09/2026", checked: true, partial: "" },
      { id: "cc3", name: "ค่าเช่าอาคารพาณิชย์ E", sub: "SRI Corporation", due: "05/09/2026", expect: 45000, actual: "30,000.00", date: "12/09/2026", checked: false, partial: "รับบางส่วน คงค้าง ฿ 15,000" },
    ],
  },
  {
    bank: "ธนากร - BBL 888",
    system: 1286500,
    stmt: "1,274,500.00",
    match: "ต่าง ฿ 12,000",
    matched: false,
    rows: [
      { id: "cc4", name: "ค่าเช่าคอนโดตัวอย่าง C", sub: "คุณสมชาย (ผู้เช่า)", due: "01/09/2026", expect: 12000, actual: "12,000.00", date: "03/09/2026", checked: true, partial: "" },
      { id: "cc5", name: "ค่าส่วนกลาง Q3", sub: "คอนโดตัวอย่าง C", due: "05/09/2026", expect: -9800, actual: "9,800.00", date: "05/09/2026", checked: false, partial: "" },
    ],
  },
];

export type Approval = {
  id: string;
  typeKey: TxTypeKey;
  subCode: string;
  detail: string;
  source: string;
  ownerId: string;
  amount: number;
  by: string;
  date: string;
};

export const APPROVALS: Approval[] = [
  { id: "a1", typeKey: "expense", subCode: "exp.repair", detail: "ค่าซ่อมแอร์ 2 ห้อง", source: "คีย์มือ · คอนโดตัวอย่าง A", ownerId: "corp", amount: -12400, by: "มาวิน", date: "10/09/2026" },
  { id: "a2", typeKey: "expense", subCode: "exp.common", detail: "ค่าน้ำ-ไฟส่วนกลาง", source: "ตารางงวด", ownerId: "corp", amount: -8600, by: "ระบบ", date: "11/09/2026" },
  { id: "a3", typeKey: "income", subCode: "inc.rent", detail: "ค่าเช่าเดือน ก.ย.", source: "ตารางงวด · คอนโดตัวอย่าง C", ownerId: "thanakorn", amount: 12000, by: "ระบบ", date: "11/09/2026" },
  { id: "a4", typeKey: "expense", subCode: "exp.travel", detail: "เบิกค่าเดินทางดูทรัพย์", source: "เบิกจ่าย", ownerId: "corp", amount: -3500, by: "แพทตี้", date: "12/09/2026" },
  { id: "a5", typeKey: "expense", subCode: "exp.salary", detail: "เงินเดือนทีมดูแลอาคาร", source: "เงินเดือน", ownerId: "corp", amount: -96000, by: "ระบบ", date: "15/09/2026" },
  { id: "a6", typeKey: "expense", subCode: "exp.land_office", detail: "ค่าธรรมเนียมจดจำนอง", source: "คีย์มือ · ที่ดินตัวอย่าง D", ownerId: "corp", amount: -18000, by: "มาวิน", date: "15/09/2026" },
  { id: "a7", typeKey: "income", subCode: "inc.interest_srr", detail: "ดอกเบี้ยขายฝาก งวด 9", source: "ตารางงวด · ทาวน์โฮมตัวอย่าง B", ownerId: "corp", amount: 36000, by: "ระบบ", date: "16/09/2026" },
];
