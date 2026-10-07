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
  /**
   * ยังไม่ได้รับ/จ่ายเงินจริง — ลงเป็นลูกหนี้/เจ้าหนี้แทนเงินสด
   *
   * ถ้าไม่มีธงนี้แล้วลงเงินสดทั้งที่เงินยังไม่เคลื่อน ยอดธนาคารในระบบจะไม่ตรง statement
   * และกระทบยอดกับธนาคารไม่ได้ (Money Invariant 5)
   */
  notYetPaid?: boolean;

  /**
   * รายการนี้คือ **การกลับรายการ** ของรายการที่ post ไปแล้ว (D-092)
   *
   * ผลเดียวที่ธงนี้มี: ปลดการกันบัญชีที่ปิดใช้งาน — กฎเหล็กข้อ 1 ห้าม DELETE
   * รายการที่ post แล้ว ทางเดียวที่แก้ได้คือ reverse + ลงใหม่ ถ้ากันบัญชีที่ปิด
   * แบบไม่มีข้อยกเว้น รายการเก่าของบัญชีที่ปิดจะแก้ไม่ได้ตลอดกาล
   *
   * **ต้องเป็นเจตนาที่ผู้เรียกบอกมาตรงๆ เท่านั้น** ห้าม engine เดาเองจาก
   * เครื่องหมายยอดเงินหรือจากหมวดย่อย — เดาผิดแปลว่าปิดบัญชีไปแล้ว
   * ยังลงรายการใหม่เข้าไปได้ ซึ่งคือช่องที่ D-092 ปิด
   *
   * ธงนี้ไม่ปลดกติกาอื่นเลย (เอกสารนิติบุคคล · ผู้ถือของบัญชี · Money Invariants)
   */
  reversal?: true;

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

/* ------------------------------------------------------------------ *
 * Resolver — ทางเดียวที่ engine รู้จักผู้ถือและบัญชีธนาคาร
 *
 * engine ไม่ import ข้อมูลผู้ถือ/บัญชีจากที่ไหนเลย ผู้เรียกต้องส่งเข้ามา
 * (ตอนนี้ชั้นนอกสร้างจาก `src/lib/mock/resolver.ts` · ของจริงจะอ่านจาก
 *  `sri_os.owners` / `sri_os.bank_accounts` แล้วสลับที่ชั้นนั้น ไม่ต้องแตะ engine)
 *
 * **ห้ามทำเป็นตัวแปรระดับโมดูลที่สลับได้** เพราะนั่นคือสถานะซ่อน
 * ที่ทำให้เทสต์สองตัวรบกวนกัน และตอบไม่ได้จากการอ่านโค้ดว่าใช้ข้อมูลชุดไหน
 * ------------------------------------------------------------------ */

/** ผู้ถือกรรมสิทธิ์ — เท่าที่ engine ต้องรู้ ไม่เอาสี/กลุ่มที่เป็นเรื่องของหน้าจอ */
export type OwnerInfo = {
  id: string;
  name: string;
  /** ตรงกับคอลัมน์ `policy` ในตาราง `sri_os.owners` */
  policy: "corporate_strict" | "personal_flexible";
  /** "SRI Family (รวมทุกชื่อ)" เป็นมุมมองรวม เลือกเป็นผู้ถือไม่ได้ */
  selectableAsHolder: boolean;
};

/**
 * บัญชีธนาคาร/กระเป๋าเงินสด — `ownerId` คือความจริงเรื่องผู้ถือของบัญชีนั้น
 *
 * `isActive` **บังคับ ไม่ใช่ optional** (D-092) เพราะ optional แปลว่า resolver
 * ตัวที่ลืมส่งจะถูกตีความว่า "เปิดใช้งาน" เงียบๆ แล้วการกันบัญชีปิดหายไปทั้งระบบ
 * resolver ต้องคืนบัญชีที่ปิดด้วย (ไม่ใช่คืน null) เพราะรายการย้อนหลังต้องแสดงและ reverse ได้
 */
export type BankInfo = {
  id: string;
  name: string;
  ownerId: string;
  /** ปิดใช้งาน = ลงรายการใหม่เข้าบัญชีนี้ไม่ได้ · ยังอ้างถึงได้ในรายการกลับรายการ */
  isActive: boolean;
};

export type LedgerResolver = {
  /** หาไม่เจอให้คืน null — engine จะแปลงเป็น PostingError เอง ห้าม throw ดิบ ห้ามเดา */
  owner(id: string): OwnerInfo | null;
  bankAccount(id: string): BankInfo | null;
};
