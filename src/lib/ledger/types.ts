import type { CashflowSection, TxTypeKey } from "@/lib/rules/tx-rules";

/** บรรทัดบัญชีหนึ่งบรรทัด — ตรงกับตาราง `transaction_lines` */
export type PostingLine = {
  coaCode: string;
  /** บังคับสำหรับบรรทัดเงินสด/ธนาคาร (Money Invariant 2) */
  bankAccountId?: string;
  assetId?: string;
  debit: number;
  credit: number;
  cfCategory?: CashflowSection;
  memo?: string;
};

export type PostingInput = {
  typeKey: TxTypeKey;
  subCode: string;
  /** จำนวนเงินที่เคลื่อนไหวจริง (บวกเสมอ) */
  amount: number;
  ownerId: string;
  bankAccountId: string;
  assetId?: string;
  contactId?: string;
  memo?: string;
  /** ไฟล์หลักฐาน — ฝั่ง corporate_strict บังคับต้องมีอย่างน้อยหนึ่งไฟล์ */
  attachments?: string[];

  /** ขายทรัพย์ (Backlog ข้อ 4) — ถ้าไม่ส่ง จะลงแบบไม่มีกำไร/ขาดทุน */
  disposal?: {
    costBasis: number;
    salePrice: number;
    sellingCosts?: number;
  };

  /** คืนเงินกู้ (Backlog ข้อ 5) — แยกเงินต้น/ดอกเบี้ย */
  repayment?: {
    principal: number;
    interest: number;
  };

  /** โอนระหว่างบัญชี — ต้องมีบัญชีปลายทาง */
  transferToBankAccountId?: string;
  /**
   * ลักษณะของรายการข้ามผู้ถือ — บังคับเมื่อบัญชีปลายทางเป็นของคนละผู้ถือ
   * ผู้ถือปลายทางอ่านจากบัญชีเอง ไม่รับจาก input เพราะผู้ใช้เว้นได้
   */
  intercompanyNature?: IntercompanyNature;
};

export type IntercompanyNature = "advance" | "loan" | "capital" | "dividend";

/**
 * ส่วนของรายการที่ฟอร์มรู้อยู่แล้วก่อนถึงแผงเฉพาะทาง
 *
 * แผงขายทรัพย์/คืนเงินกู้จะเติม `disposal` หรือ `repayment` ให้ครบเอง
 * แล้วส่งเข้า engine ตัวจริง — ไม่มีใครประกอบคู่บัญชีเองในคอมโพเนนต์
 */
export type PostingContext = Omit<PostingInput, "disposal" | "repayment">;

/**
 * หนึ่ง transaction = หนึ่งผู้ถือกรรมสิทธิ์
 * ตรงกับ schema: `sri_os.transactions.owner_id` อยู่ระดับหัวรายการ
 * ส่วน `transaction_lines` ไม่มีคอลัมน์ owner
 *
 * รายการข้ามผู้ถือจึงต้องเป็น **สอง transaction คู่กัน** ไม่ใช่สองบรรทัดในรายการเดียว
 * ไม่งั้นเงินสดของอีกฝ่ายจะไปโผล่ในงบของฝ่ายแรก
 */
export type PostingTransaction = {
  ownerId: string;
  lines: PostingLine[];
  /** ผู้ถืออีกฝ่าย (เฉพาะรายการข้ามผู้ถือ) */
  counterOwnerId?: string;
  intercompanyNature?: IntercompanyNature;
};

export type PostingResult = {
  /** ปกติหนึ่งรายการ · ข้ามผู้ถือจะได้สองรายการคู่กัน */
  transactions: PostingTransaction[];
  /** คำอธิบายภาษาคน ใช้โชว์ก่อนยืนยันและใน audit */
  summary: string[];
};

/** ข้อผิดพลาดที่กันไม่ให้ส่งรายการที่ DB จะปฏิเสธอยู่ดี */
export class PostingError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PostingError";
  }
}
