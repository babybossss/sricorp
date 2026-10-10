import type { TxTypeKey } from "@/lib/rules/tx-rules";
import type { PostedClearing } from "@/lib/ledger/types";

/**
 * ไฟล์หลักฐานในข้อมูลจำลอง — ต้องเป็น **path ของไฟล์ใน Storage** เหมือนของจริง
 * (`<owner_id>/<uploader_id>/<uuid>.<ext>` ดู `src/lib/storage/path.ts`)
 *
 * ตั้งแต่ D-095 ด่าน corporate_strict นับเฉพาะไฟล์ที่อัปโหลดจริง ชื่อไฟล์อย่าง
 * `"สลิป.jpg"` จึงไม่ใช่หลักฐานอีก · แถวจำลองเหล่านี้สมมุติว่า "อัปโหลดไว้ก่อนแล้ว"
 * ชื่อสำหรับแสดงไม่ได้เก็บไว้ที่ไหน (ตั้งใจ) หน้าจอจึงแสดงเป็น "ไฟล์หลักฐาน n"
 */
const MOCK_REF_OWNER = "00000000-0000-4000-8000-000000000001";
const MOCK_REF_UPLOADER = "00000000-0000-4000-8000-000000000002";
export const mockEvidenceRef = (n: number): string =>
  `${MOCK_REF_OWNER}/${MOCK_REF_UPLOADER}/00000000-0000-4000-8000-${String(n).padStart(12, "0")}.pdf`;

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

/**
 * ยืนยันรับ-จ่าย · จับคู่กับ statement
 *
 * กลุ่มผูกกับ **รหัสบัญชี** (`bankAccountId`) ไม่ใช่ชื่อธนาคาร — ชื่อเป็นแค่สิ่งที่แสดง
 * หน้าจอหาชื่อจาก resolver ตอนวาด ไม่เก็บชื่อไว้ที่นี่ เพราะชื่อเปลี่ยนได้ รหัสไม่เปลี่ยน
 * (ผูกกับสตริงชื่อ = เงินลอยไม่รู้ว่าเข้าบัญชีไหนจริง ขัด Money Invariant 2)
 * ทุกแถวถือรหัสบัญชีของตัวเองด้วย เพราะแถวคือสิ่งที่ส่งเข้า `buildClearing()` — มีทดสอบกันไม่ให้แถวกับกลุ่มขัดกัน
 *
 * ยอดที่ยังค้างอยู่ไม่เก็บเป็นข้อความในแถว (เดิมมี `partial: "รับบางส่วน คงค้าง ฿ 15,000"`)
 * เพราะคือยอดที่ engine เป็นคนตัดสิน — ข้อความที่พิมพ์ไว้จะขัดกับ engine เมื่อไรก็ได้
 */
export const CASH_GROUPS: {
  bankAccountId: string;
  system: number;
  stmt: string;
  match: string;
  matched: boolean;
  rows: PendingCashRow[];
}[] = [
  {
    bankAccountId: "b1",
    system: 2340120,
    stmt: "2,340,120.00",
    match: "ตรงกัน",
    matched: true,
    rows: [
      { id: "cc1", name: "ดอกเบี้ยขายฝาก งวด 9", sub: "ทาวน์โฮมตัวอย่าง B", ownerId: "corp", typeKey: "income", subCode: "inc.interest_srr", accruedAmount: 36000, postedClearings: [], assetId: "th_b", contactId: "c2", bankAccountId: "b1", attachments: [mockEvidenceRef(1)], due: "16/09/2026", actual: "36,000.00", date: "16/09/2026", checked: true },
      { id: "cc2", name: "ค่าน้ำ-ไฟส่วนกลาง", sub: "SRI Corporation", ownerId: "corp", typeKey: "expense", subCode: "exp.common", accruedAmount: 8600, postedClearings: [], assetId: "rent2", contactId: "c2", bankAccountId: "b1", attachments: [mockEvidenceRef(2)], due: "15/09/2026", actual: "8,600.00", date: "15/09/2026", checked: true },
      // ตั้งใจไม่มีหลักฐาน — นิติบุคคลต้องแนบสลิปก่อนจึงยืนยันได้ ห้ามเติมให้ผ่าน
      { id: "cc3", name: "ค่าเช่าอาคารพาณิชย์ E", sub: "SRI Corporation", ownerId: "corp", typeKey: "income", subCode: "inc.rent", accruedAmount: 45000, postedClearings: [], assetId: "rent3", contactId: "c2", bankAccountId: "b1", due: "05/09/2026", actual: "30,000.00", date: "12/09/2026" },
    ],
  },
  {
    bankAccountId: "b4",
    system: 1286500,
    stmt: "1,274,500.00",
    match: "ต่าง ฿ 12,000",
    matched: false,
    rows: [
      { id: "cc4", name: "ค่าเช่าคอนโดตัวอย่าง C", sub: "คุณสมชาย (ผู้เช่า)", ownerId: "thanakorn", typeKey: "income", subCode: "inc.rent", accruedAmount: 12000, postedClearings: [], assetId: "rent1", contactId: "c1", bankAccountId: "b4", due: "01/09/2026", actual: "12,000.00", date: "03/09/2026", checked: true },
      { id: "cc5", name: "ค่าส่วนกลาง Q3", sub: "คอนโดตัวอย่าง C", ownerId: "thanakorn", typeKey: "expense", subCode: "exp.common", accruedAmount: 9800, postedClearings: [], assetId: "rent1", bankAccountId: "b4", due: "05/09/2026", actual: "9,800.00", date: "05/09/2026" },
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
  /** ทรัพย์ที่ผูก — บางหมวดย่อยบังคับ ถ้าไม่มีจะพรีวิวบรรทัดบัญชีไม่ได้ */
  assetId?: string;
  /** คู่ค้า — ฝั่งนิติบุคคลบังคับทุกรายการ */
  contactId?: string;
  /**
   * ยังไม่ได้รับ/จ่ายเงินจริง ณ ตอนที่คีย์
   *
   * ต้องเก็บมากับตัวรายการ ไม่ใช่ให้แผงตรวจเดาจากว่าหมวดนี้ตั้งค้างได้ไหม —
   * ไม่งั้นสิ่งที่คนอนุมัติเห็น กับสิ่งที่คนคีย์ตั้งใจ จะเป็นคนละอย่างได้
   */
  notYetPaid?: boolean;
  /**
   * บัญชีธนาคารที่คนคีย์เลือก — รับเข้าหรือจ่ายออกตามประเภทรายการ
   *
   * ต้องเก็บมากับตัวรายการ ไม่ใช่ให้แผงตรวจหยิบ "บัญชีแรกที่เปิดอยู่ของผู้ถือ" มาแสดง —
   * ไม่งั้นสิ่งที่คนอนุมัติเห็น กับสิ่งที่คนคีย์เลือกจริง จะเป็นคนละบัญชีได้
   *
   * เว้นว่างได้เฉพาะรายการค้างรับ-ค้างจ่าย (`notYetPaid`) ที่ยังไม่มีขาเงินสด
   * รายการที่มีขาเงินสดแต่ไม่มีบัญชี = ข้อมูลไม่ครบ ต้องปฏิเสธ ห้ามเดา
   * (ใครตัดสินว่าพอไหม: `buildPostingDraft()` ไม่ใช่หน้าจอ)
   */
  bankAccountId?: string;
  /**
   * ไฟล์หลักฐาน (ใบเสร็จ/ใบแจ้งหนี้/สัญญา) ที่ผู้คีย์แนบมา
   *
   * ต้องเก็บมากับตัวรายการ ไม่ใช่ให้แผงตรวจเดาหรือละไว้ — ฝั่ง `corporate_strict`
   * กติกาของ `buildPosting()` ใช้ตัดสินว่าบันทึกได้ไหม ถ้าไม่มีฟิลด์นี้ทุกรายการของนิติบุคคล
   * จะถูกอนุมัติโดยไม่มีหลักฐาน = override กติกาที่ห้าม override
   *
   * ฝั่งบุคคล (`personal_flexible`) เว้นว่างได้ — ใครบังคับหรือไม่บังคับ engine เป็นคนตัดสิน
   */
  attachments?: string[];
};

// a4 (นิติบุคคล) ตั้งใจไม่มีหลักฐาน — ให้เห็นว่าระบบปฏิเสธจริง ห้ามเติมให้ผ่าน
// a3 (ฝั่งบุคคล) ไม่มีหลักฐานโดยปกติ และต้องอนุมัติได้
export const APPROVALS: Approval[] = [
  { id: "a1", typeKey: "expense", subCode: "exp.repair", detail: "ค่าซ่อมแอร์ 2 ห้อง", source: "คีย์มือ · คอนโดตัวอย่าง A", ownerId: "corp", amount: -12400, by: "มาวิน", date: "10/09/2026", assetId: "rent2", contactId: "c2", bankAccountId: "b1", attachments: [mockEvidenceRef(3)] },
  { id: "a2", typeKey: "expense", subCode: "exp.common", detail: "ค่าน้ำ-ไฟส่วนกลาง", source: "ตารางงวด", ownerId: "corp", amount: -8600, by: "ระบบ", date: "11/09/2026", assetId: "rent2", contactId: "c2", notYetPaid: true, attachments: [mockEvidenceRef(4)] },
  { id: "a3", typeKey: "income", subCode: "inc.rent", detail: "ค่าเช่าเดือน ก.ย.", source: "ตารางงวด · คอนโดตัวอย่าง C", ownerId: "thanakorn", amount: 12000, by: "ระบบ", date: "11/09/2026", assetId: "rent1", contactId: "c2", notYetPaid: true, bankAccountId: "b4" },
  { id: "a4", typeKey: "expense", subCode: "exp.travel", detail: "เบิกค่าเดินทางดูทรัพย์", source: "เบิกจ่าย", ownerId: "corp", amount: -3500, by: "แพทตี้", date: "12/09/2026", contactId: "c2", bankAccountId: "b1" },
  { id: "a5", typeKey: "expense", subCode: "exp.salary", detail: "เงินเดือนทีมดูแลอาคาร", source: "เงินเดือน", ownerId: "corp", amount: -96000, by: "ระบบ", date: "15/09/2026", contactId: "c2", bankAccountId: "b1", attachments: [mockEvidenceRef(5)] },
  { id: "a6", typeKey: "expense", subCode: "exp.land_office", detail: "ค่าธรรมเนียมจดจำนอง", source: "คีย์มือ · ที่ดินตัวอย่าง D", ownerId: "corp", amount: -18000, by: "มาวิน", date: "15/09/2026", assetId: "land_d", contactId: "c2", bankAccountId: "b1", attachments: [mockEvidenceRef(6)] },
  { id: "a7", typeKey: "income", subCode: "inc.interest_srr", detail: "ดอกเบี้ยขายฝาก งวด 9", source: "ตารางงวด · ทาวน์โฮมตัวอย่าง B", ownerId: "corp", amount: 36000, by: "ระบบ", date: "16/09/2026", assetId: "th_b", contactId: "c2", notYetPaid: true, bankAccountId: "b1", attachments: [mockEvidenceRef(7)] },
];

/**
 * รายการค้างรับ-ค้างจ่ายที่รอยืนยันว่าเงินเคลื่อนจริง
 *
 * ขั้นยืนยันเป็นขั้นที่ทำให้งบกระแสเงินสดวิ่ง จึงต้องรู้บัญชีเสมอ — รายการที่คีย์ตอนยังไม่มีขาเงินสด
 * ไม่มีบัญชีมาด้วย (`bankAccountId` ว่าง) ต้องให้เลือกตอนยืนยัน
 * `ownerId` ใช้กรองตัวเลือก: เงินของคนหนึ่งจะไปโผล่ในบัญชีของอีกคนไม่ได้
 *
 * **ข้อมูลที่กติกาใช้ตัดสินต้องเดินทางมากับตัวรายการ** (เหตุผลเดียวกับ `Approval.notYetPaid` /
 * `bankAccountId` / `attachments`) — ไม่ใช่ให้ตัวยืนยันเดาจากชื่อรายการหรือจากข้อความที่แสดง:
 * - `typeKey` / `subCode`  ตารางกฎใช้หาบัญชีพักและทางล้าง · เดาผิดคือล้างผิดบัญชี
 * - `accruedAmount`        ยอดที่ตั้งค้างไว้ตอนต้นทาง (บวกเสมอ) ทิศทางรับ/จ่ายอ่านจากตารางกฎ ไม่เก็บเครื่องหมายซ้ำ
 * - `postedClearings`      ประวัติการยืนยันที่ post แล้ว · engine ใช้กันยืนยันซ้ำและล้างเกิน
 *                          ห้ามให้หน้าจอสรุปเป็น "ยอดที่เคยล้าง" ส่งไปเอง ถ้าละไว้ engine ต้องปฏิเสธ ไม่ใช่เดาว่า []
 * - `attachments`          ฝั่ง `corporate_strict` กติกาของ `buildClearing()` ใช้ตัดสินว่ายืนยันได้ไหม
 *                          ไม่มีฟิลด์นี้ทุกรายการของนิติบุคคลจะถูกยืนยันโดยไม่มีหลักฐาน = override กติกาที่ห้าม override
 *                          ฝั่งบุคคลเว้นว่างได้ — ใครบังคับหรือไม่ engine เป็นคนตัดสิน
 * - `assetId` / `contactId` บัญชีย่อยรายทรัพย์และกติกาคู่ค้าของนิติบุคคล
 */
export type PendingCashRow = {
  id: string;
  name: string;
  sub: string;
  ownerId: string;
  due: string;
  typeKey: TxTypeKey;
  subCode: string;
  accruedAmount: number;
  postedClearings: PostedClearing[];
  assetId?: string;
  contactId?: string;
  /**
   * รหัสบัญชีที่เงินเข้า-ออก — ไม่ใช่ชื่อ · ว่างได้เฉพาะรายการที่ยังไม่เคยระบุบัญชี (ต้องเลือกตอนยืนยัน)
   * ถ้าไม่ว่าง ใช้ค่านี้เสมอ ไม่ให้ช่องเลือกบัญชีทับ
   */
  bankAccountId?: string;
  attachments?: string[];
  /** ค่าเริ่มต้นของช่องกรอก — ผู้ใช้แก้ได้ */
  actual: string;
  date: string;
  checked?: boolean;
};

export const UNASSIGNED_CASH_ROWS: PendingCashRow[] = [
  { id: "cu1", name: "ค่าน้ำ-ไฟส่วนกลาง", sub: "คอนโดตัวอย่าง A · ตั้งค้างจ่ายไว้", ownerId: "corp", typeKey: "expense", subCode: "exp.common", accruedAmount: 8600, postedClearings: [], assetId: "rent2", contactId: "c2", attachments: [mockEvidenceRef(8)], due: "30/09/2026", actual: "8,600.00", date: "30/09/2026" },
  { id: "cu2", name: "ค่าเช่าคอนโดตัวอย่าง C เดือน ก.ย.", sub: "คุณสมชาย (ผู้เช่า) · ตั้งค้างรับไว้", ownerId: "thanakorn", typeKey: "income", subCode: "inc.rent", accruedAmount: 12000, postedClearings: [], assetId: "rent1", contactId: "c1", due: "01/09/2026", actual: "12,000.00", date: "03/09/2026" },
];
