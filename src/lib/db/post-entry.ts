import {
  FX_TRANSLATION_DIFF_COA,
  isCashAccount,
  REALISED_FX_GAIN,
  REALISED_FX_LOSS,
} from "@/lib/rules/coa";
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
  /* ---- เงินตราต่างประเทศต่อบรรทัด (FCD · 20261025000004 + 20261025000005) ----
   * `debit`/`credit` เป็นบาทเสมอ · สี่ช่องนี้คือข้อมูลประกอบที่ทำให้ตรวจย้อนได้
   * **ต้องส่งต่อให้ครบทั้งสี่** — ด่าน `fn_assert_line_fx` ปฏิเสธบรรทัดที่ส่งมาไม่ครบ
   * (เช่นขา 3410 ที่ไม่มีสกุล = ด่านล้างผลต่างมองไม่เห็น แล้วกำไรถูกนับสองครั้ง)
   * และประตู `fn_post_entry` ปฏิเสธช่องที่ไม่รู้จักทั้งใบ จึงชื่อต้องตรงกับคอลัมน์ */
  currency?: string;
  amount_original?: number;
  fx_rate?: number;
  fx_rate_date?: string;
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
  /** ใบล้างยอดค้างใช้เก็บเลขอ้างอิงการยืนยัน `<id รายการต้นทาง>-clr-<n>` — ที่มาของประวัติการล้าง */
  source_ref?: string;
  /** ภาษีหัก ณ ที่จ่าย (D-111) — ต้องส่งคู่กันทั้งอัตราและยอด · ใบที่มีบรรทัด 1800 แต่หัวรายการว่าง DB ปฏิเสธทั้งใบ */
  wht_rate?: number;
  wht_amount?: number;
  wht_certificate_no?: string;
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
  header: { docDate: string; cashDate: string | null; sourceRef?: string }
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
    source_ref: blank(header.sourceRef),
    // ส่งเมื่อ input บอกว่าถูกหักภาษีเท่านั้น (engine ตรวจแล้วว่าสอดคล้องกับบรรทัด 1800 ที่สร้าง)
    wht_rate: input.wht ? input.wht.rate : undefined,
    wht_amount: input.wht ? input.wht.amount : undefined,
    wht_certificate_no: blank(input.wht?.certificateNo),
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
        /**
         * บรรทัดบาท (ของเดิมทุกใบ) **ไม่มีสี่ช่องนี้เลย** — ใส่คีย์ที่ค่าเป็น
         * `undefined` ไม่ได้ เพราะ check constraint `transaction_lines_fx_shape`
         * ยอมแค่ "ครบทั้งสี่" หรือ "ไม่มีเลย" และประตูเทียบรายชื่อช่องจากคีย์ที่ส่งมา
         * ส่งต่อตามที่ engine สร้างอย่างเดียว ไม่เติมและไม่ตัดค่า
         */
        ...(l.currency === undefined
          ? {}
          : {
              currency: l.currency,
              amount_original: l.amountOriginal,
              fx_rate: l.fxRate,
              fx_rate_date: l.fxRateDate,
            }),
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
 *
 * และกั้นจาก **คู่บัญชีในตารางกฎ** (ไม่ได้เช็ครหัสหมวด) สำหรับหมวดอัตราแลกเปลี่ยน:
 *
 * **สิ่งที่ปิดแล้ว (20261025000005 + engine)** — ไม่ใช่เหตุของด่านนี้อีกต่อไป:
 *   1. ขา 3410 ต้องมีสกุลกำกับ และด่านล้างผลต่างไม่พึ่งสกุลบนขานั้นอีก (กำไรไม่ถูกนับซ้ำ)
 *   2. แปลงค่าบน **บัญชีบาท** ถูกปฏิเสธทั้งที่ engine และ DB (เงินสดไม่โผล่จากอากาศ)
 *      และ `fxEffect` ในงบกระแสเงินสดกลืนใบที่ไม่มีบรรทัดเงินตราจริงไม่ได้แล้ว
 *   3. `trf.fx_convert` มีเส้นทางของตัวเองใน engine แล้ว — สร้างขากำไร/ขาดทุน
 *      ขาล้าง 3410 ตามสัดส่วน และ `currency`/`fx_rate` ต่อบรรทัดครบ
 *      (แลกขาดทุน 5,000 แสดง 5,000 ไม่ใช่ 0 อีกแล้ว · ดู `fx-posting.test.ts`)
 *
 * **เหตุที่ด่านนี้ยังอยู่**: เป็นเรื่องของ **หน้าจอ** ไม่ใช่เครื่องยนต์ —
 * ฟอร์มยังไม่มีช่องให้กรอกอัตราตามบัญชี · อัตราสิ้นงวด/อัตราที่แลกได้จริง ·
 * ยอดเงินตราคงเหลือ และผลต่างที่ค้างอยู่ (`PostingInput.fxTranslation` /
 * `fxConversion`) ซึ่งทุกช่องต้องอ่านจาก **สมุดที่ post แล้วจริง** ไม่ใช่จาก state ของฟอร์ม
 * ถ้าปลดด่านตอนนี้ หมวดจะโผล่ให้กดได้แต่ engine ปฏิเสธทุกครั้งเพราะข้อมูลไม่ครบ
 * = เปิดฟีเจอร์ครึ่งเดียว (บทเรียนข้อ 7) · **ปลดด่านนี้พร้อมกับตอนต่อช่องในฟอร์ม**
 */
export function notWiredReason(
  sub: Pick<SubCategory, "label" | "requires" | "dr" | "cr" | "gainCoa" | "lossCoa"> | undefined
): string | null {
  // กั้นหมวดอัตราแลกเปลี่ยนก่อน เพราะ `trf.fx_convert` มี requires เหมือนการโอนธรรมดา
  // จึงแยกด้วยธง requires ไม่ได้ ต้องดูจากคู่บัญชีที่ตารางกฎประกาศไว้
  const touches = [sub?.dr, sub?.cr, sub?.gainCoa, sub?.lossCoa].filter((c): c is string => !!c);
  if (
    touches.includes(FX_TRANSLATION_DIFF_COA) ||
    touches.includes(REALISED_FX_GAIN) ||
    touches.includes(REALISED_FX_LOSS)
  ) {
    return `หมวด "${sub?.label}" ต้องกรอกอัตราตามบัญชี อัตราที่ใช้ใหม่ ยอดเงินตราคงเหลือ และผลต่างที่ค้างอยู่ ซึ่งหน้าจอยังไม่มีช่องให้กรอก — ยังบันทึกจริงไม่ได้ในรอบนี้ (ระบบบัญชีสร้างบรรทัดผลต่างและบรรทัดล้างให้ครบแล้ว แต่ถ้าไม่มีอัตราที่อ่านจากสมุดจริง ยอดบาทจะเป็นตัวเลขที่ตรวจย้อนไม่ได้)`;
  }
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

/**
 * ผู้ถือที่ payload แตะจริงต้องเป็น `active` — ตรวจทั้ง `owner_id` และ `counter_owner_id`
 *
 * อ่านจากสิ่งที่ engine คืนมา (รวมปลายทางที่ engine หามาจากบัญชี) ไม่เชื่อช่องที่ผู้ใช้เว้นได้
 * ฟอร์มซ่อน `planned` ไว้แล้ว แต่คำขอที่แก้เองข้ามหน้าจอได้ → ต้องกันฝั่งเซิร์ฟเวอร์ด้วย
 * คืนข้อความปฏิเสธ หรือ `null` ถ้าผ่าน
 */
export function refuseInactiveOwners(
  payload: Pick<PostEntryPayload, "transactions">,
  owners: readonly { id: string; name: string; status: string }[]
): string | null {
  const byId = new Map(owners.map((o) => [o.id, o]));
  for (const t of payload.transactions) {
    for (const id of [t.owner_id, t.counter_owner_id]) {
      if (!id) continue;
      const o = byId.get(id);
      if (!o) return "ไม่รู้จักผู้ถือที่รายการนี้อ้างถึง — ยังไม่ได้บันทึกอะไร";
      if (o.status === "planned") {
        return `"${o.name}" ยังไม่ได้จดทะเบียน จึงยังเป็นเจ้าของรายการไม่ได้ — ยังไม่ได้บันทึกอะไร`;
      }
      if (o.status !== "active") {
        return `"${o.name}" ไม่ได้ใช้งานอยู่ จึงเป็นเจ้าของรายการใหม่ไม่ได้ — ยังไม่ได้บันทึกอะไร`;
      }
    }
  }
  return null;
}

/** อ่านผลของ `fn_post_entry` — ตอบสำเร็จได้ก็ต่อเมื่อ DB คืน id ครบทุกก้อนที่ส่งไป */
export function readPostResult(
  data: unknown,
  expected: number
): { ok: true; transactionIds: string[]; replayed: boolean } | { ok: false; message: string } {
  const out = data as { transaction_ids?: unknown; replayed?: unknown } | null;
  const ids = Array.isArray(out?.transaction_ids)
    ? (out!.transaction_ids as unknown[]).filter((x): x is string => typeof x === "string")
    : [];
  if (ids.length !== expected) {
    return {
      ok: false,
      message: "ฐานข้อมูลตอบกลับไม่ครบ — ยังยืนยันไม่ได้ว่ารายการถูกบันทึก ให้เปิดหน้าสมุดบัญชีตรวจก่อนกดบันทึกซ้ำ",
    };
  }
  return { ok: true, transactionIds: ids, replayed: out?.replayed === true };
}
