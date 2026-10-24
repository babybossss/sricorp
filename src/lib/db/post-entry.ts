import { isCashAccount } from "@/lib/rules/coa";
import type { SubCategory } from "@/lib/rules/tx-rules";
import type { PostingInput, PostingResult } from "@/lib/ledger/types";

/**
 * แปลงผลลัพธ์ของ `buildPosting()` เป็น payload ของ RPC `sri_os.fn_post_entry` (D-091)
 *
 * **ไฟล์นี้ไม่คิดบัญชี** — ทุกบรรทัดมาจาก `PostingResult` ที่ engine คืนมาตรงๆ แปลงชื่อช่องเป็น snake_case
 * เท่านั้น ห้ามเพิ่ม/ตัด/แก้บรรทัดที่นี่ (ถ้าต้องแก้คู่บัญชี แก้ที่ตารางกฎ + engine)
 *
 * ช่องของหัวรายการที่ engine ไม่ได้คืน (วันที่ · หมวดย่อย · ผู้ติดต่อ · ทรัพย์ · ไฟล์แนบ · หมายเหตุ)
 * มาจาก `PostingInput` ที่ใช้สร้างผลลัพธ์นั้นเอง — ไม่ได้มาจาก state ของฟอร์ม
 *
 * สัญญาของ RPC: ช่องที่ไม่อยู่ในรายการ = ปฏิเสธทั้งใบ (supabase/migrations/20261008000011)
 */

export type PostEntryLine = {
  coa_code: string;
  bank_account_id?: string;
  asset_id?: string;
  debit: number;
  credit: number;
  cf_category?: string;
  memo?: string;
};

export type PostEntryTransaction = {
  owner_id: string;
  counter_owner_id?: string;
  intercompany_nature?: string;
  lines: PostEntryLine[];
};

export type PostEntryPayload = {
  txn_type_code: string;
  doc_date: string;
  cash_date: string | null;
  memo?: string;
  attachments?: string[];
  asset_id?: string;
  contact_id?: string;
  source: "manual";
  transactions: PostEntryTransaction[];
};

/** ข้อมูลที่ประกอบ payload ไม่ได้ — ข้อความอ่านรู้เรื่อง ไม่ใช่ error ดิบ */
export class PayloadError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PayloadError";
  }
}

const blank = (s: string | undefined | null): string | undefined => (s && s.trim() !== "" ? s : undefined);

export function toPostEntryPayload(
  input: PostingInput,
  result: PostingResult,
  header: { docDate: string; cashDate: string | null }
): PostEntryPayload {
  if (!result.transactions.length) {
    throw new PayloadError("เครื่องยนต์บัญชีไม่ได้คืนรายการเลย — ไม่ส่งอะไรไปฐานข้อมูล");
  }

  // กฎของ DB (ตรงกับ trigger cash_date): มีบรรทัดเงินสด 11xx ⟺ ต้องมี cash_date
  // ตัดสินจาก **บรรทัดที่ engine ส่งมา** ไม่ใช่จากธงในฟอร์ม (บทเรียนข้อ 2)
  const hasCashLine = result.transactions.some((t) => t.lines.some((l) => isCashAccount(l.coaCode)));
  if (hasCashLine && !header.cashDate) {
    throw new PayloadError("รายการนี้มีเงินเข้า/ออกบัญชีจริง — ต้องระบุวันที่เงินเข้า/ออกจริงให้ถูกต้อง");
  }

  return {
    txn_type_code: input.subCode,
    doc_date: header.docDate,
    cash_date: hasCashLine ? header.cashDate : null,
    memo: blank(input.memo),
    attachments: input.attachments?.length ? [...input.attachments] : undefined,
    asset_id: blank(input.assetId),
    contact_id: blank(input.contactId),
    source: "manual",
    transactions: result.transactions.map((t) => ({
      owner_id: t.ownerId,
      counter_owner_id: t.counterOwnerId,
      intercompany_nature: t.intercompanyNature,
      lines: t.lines.map((l) => ({
        coa_code: l.coaCode,
        bank_account_id: l.bankAccountId,
        asset_id: l.assetId,
        debit: l.debit,
        credit: l.credit,
        cf_category: l.cfCategory,
        memo: l.memo,
      })),
    })),
  };
}

/**
 * หมวดที่เส้นทางบันทึกยังต่อไม่ครบ → คืนเหตุผล · ต้องกั้นก่อนบันทึก ไม่ใช่บันทึกครึ่งเดียว
 *
 * อ่านจากธง `requires` ในตารางกฎ (ไม่ได้เช็ครหัสหมวด):
 * - `loanTerms` — ต้องสร้างสัญญา + ตารางงวดใน `contracts`/`schedules` ด้วย ซึ่งยังไม่ได้ต่อ
 *   ถ้าลงแต่บัญชี สัญญาจะไม่มีตัวตนและหน้ายืนยันรับ-จ่ายไม่มีงวดให้ดึง
 * - `capitalGain` — ส่วนเกินทุนจากการตีราคาที่ค้างใน 3400 ต้องอ่านจากยอดที่ post แล้วจริง
 *   (types.ts: `unrealizedAdjustment`) ฟอร์มยังส่งค่านี้ให้ engine ไม่ได้ ถ้าปล่อยผ่านจะค้างในส่วนของเจ้าของ
 */
export function notWiredReason(sub: Pick<SubCategory, "label" | "requires"> | undefined): string | null {
  if (!sub?.requires) return null;
  if (sub.requires.includes("loanTerms")) {
    return `หมวด "${sub.label}" ต้องสร้างสัญญาและตารางงวดในฐานข้อมูลด้วย ซึ่งยังไม่ได้ต่อ — ยังบันทึกจริงไม่ได้ในรอบนี้ (ระบบไม่ลงบัญชีครึ่งเดียว)`;
  }
  if (sub.requires.includes("capitalGain")) {
    return `หมวด "${sub.label}" ต้องอ่านส่วนเกินทุนจากการตีราคาที่บันทึกไว้แล้วมาล้างพร้อมการขาย ซึ่งยังไม่ได้ต่อ — ยังบันทึกจริงไม่ได้ในรอบนี้ (ไม่งั้นยอดจะค้างในส่วนของเจ้าของ)`;
  }
  return null;
}

type DbErrorLike = { message?: string; code?: string; details?: string | null; hint?: string | null };

const HAS_THAI = /[฀-๿]/;

/**
 * ข้อความของ error จาก DB ที่คนอ่านรู้เรื่อง
 *
 * ด่านใน DB คืนข้อความไทยมาอยู่แล้ว (`บันทึกรายการไม่ได้: …` · `Money Invariant …`) → ส่งต่อตามนั้น
 * ไม่ตัด ไม่แปลงเป็น "เกิดข้อผิดพลาด" กลางๆ · เฉพาะ error ของ Postgres/PostgREST ที่ไม่มีข้อความไทยเท่านั้น
 * ที่แปลให้ พร้อมแนบข้อความเดิมไว้ท้ายเพื่อให้ผู้ดูแลตามต่อได้
 */
export function humanizeDbError(err: DbErrorLike | null | undefined): string {
  const message = (err?.message ?? "").trim();
  const code = err?.code ?? "";
  const tail = message ? ` (รายละเอียดทางเทคนิค: ${[code, message].filter(Boolean).join(" · ")})` : "";

  if (message && HAS_THAI.test(message)) return message;

  if (code === "42501" || /row-level security|permission denied/i.test(message)) {
    return `บัญชีของคุณไม่มีสิทธิ์ทำรายการนี้ — ฐานข้อมูลปฏิเสธตามสิทธิ์ (การลงสมุดบัญชีต้องมีสิทธิ์อนุมัติเข้าสมุด และต้องเห็นผู้ถือรายนี้ในขอบเขตของคุณ)${tail}`;
  }
  if (code === "23505") return `ฐานข้อมูลบอกว่ามีรายการนี้อยู่แล้ว ไม่ได้บันทึกซ้ำ${tail}`;
  if (code === "23503") return `รายการอ้างถึงข้อมูลที่ไม่มีอยู่ในฐานข้อมูล (เช่น ผู้ติดต่อ ทรัพย์ หรือบัญชีที่ถูกลบ) ให้โหลดหน้าใหม่แล้วเลือกใหม่${tail}`;
  if (/JWT|not authenticated|session/i.test(message)) return `เข้าสู่ระบบหมดอายุ — ให้เข้าสู่ระบบใหม่แล้วบันทึกอีกครั้ง${tail}`;
  if (/fetch failed|network|ECONN|timeout/i.test(message)) {
    return `ติดต่อฐานข้อมูลไม่ได้ — ยังไม่ทราบว่ารายการถูกบันทึกหรือไม่ ให้เปิดหน้าสมุดบัญชีตรวจก่อนกดบันทึกซ้ำ${tail}`;
  }
  return `ฐานข้อมูลไม่รับรายการนี้ ยังไม่มีรายการถูกบันทึก${tail}`;
}
