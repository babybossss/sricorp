/**
 * ตัวต่อระหว่างหน้าจอ/server action กับ `lib/ledger/reversal.ts` — **ไม่มีกติกาบัญชีในไฟล์นี้**
 *
 * หน้าที่มีสามอย่างเท่านั้น
 *   1. แปลงแถวของ `v_ledger_posted` เป็น `ReversalSource` ที่ engine ต้องการ
 *   2. ตอบว่า "ใบนี้กลับรายการจากหน้าจอได้ไหม" สำหรับกรณีที่ **ด่านฝั่ง DB ปิดอยู่**
 *      — ปฏิเสธพร้อมบอกทางออก ดีกว่าปล่อยให้ผู้ใช้เจอ error ดิบของ Postgres
 *   3. แปลงใบที่ engine สะท้อนมาแล้วเป็น payload ของ `fn_post_entry`
 *
 * บรรทัดบัญชีทั้งหมดมาจาก `buildReversal()` ไฟล์นี้ไม่สร้าง ไม่แก้ ไม่ตัดบรรทัดใดเลย
 *
 * ============================================================
 * ด่านฝั่ง DB ที่ **ยังปิดอยู่** และทำให้บางใบกลับรายการไม่ได้ (รายงานให้ลูกพี่แล้ว)
 * ============================================================
 * ทั้งสองข้อนี้ **ไม่ใช่ข้อจำกัดที่เลือกเอง** แต่เป็นสภาพของ schema วันนี้
 * แก้ได้ด้วย migration เท่านั้น ซึ่งงานนี้ไม่มีสิทธิ์เขียน จึงปฏิเสธพร้อมเหตุผล
 * **ห้ามหาทางอ้อม** — ทางอ้อมทุกทางที่ลองแล้วทำให้ตัวเลขผิดเงียบๆ (ดูเหตุผลในแต่ละข้อ)
 *
 * (ก) **รายการข้ามผู้ถือ (สองใบคู่กัน)**
 *     `fn_post_entry` รับ `reverses_id` เป็นช่องของ**หัวคำขอ** แล้วเขียนค่าเดียวกันลงทุกใบ
 *     ในคำขอนั้น · แต่ `fn_reverse_link_ok` บังคับว่าใบกลับรายการต้องชี้ไปต้นฉบับ
 *     **ของผู้ถือเดียวกัน** → ส่งสองขาในคำขอเดียวจึงถูกปฏิเสธที่ขาที่สอง
 *     และแยกเป็นสองคำขอก็ไม่ได้ เพราะ `fn_assert_intercompany_pair` บังคับว่าขาคู่ต้องอยู่
 *     ใน **ธุรกรรมฐานข้อมูลเดียวกัน** (`write_txn_id` เท่ากัน) ซึ่ง RPC สองครั้งไม่เท่ากัน
 *     ทางอ้อมที่ **ห้ามทำ**: ลงใบกลับรายการโดยไม่ใส่ `counter_owner_id` (จะผ่านทั้งสองด่าน
 *     เพราะกลายเป็นใบธรรมดา) — แต่งบกระแสเงินสดหาบรรทัดของขาข้ามผู้ถือจาก
 *     `intercompanyNature` ถ้าหายไป เงินก้อนนั้นจะไม่เข้าบรรทัดใดในงบ (`cashflow.ts`)
 *     และงบรวมจะตัดรายการระหว่างกันไม่ลง = ผิดเงียบๆ ทั้งที่ทุกใบสมดุล
 *     **สิ่งที่ต้องแก้**: ย้าย `reverses_id` ไปเป็นช่องระดับ `transactions[]` ของ payload
 *
 * (ข) **ใบที่ถูกหักภาษี ณ ที่จ่าย (มีบรรทัด 1800)**
 *     ใบกลับรายการต้องสะท้อนบรรทัดครบทุกบรรทัด (`fn_assert_reverse_mirrors` เทียบ multiset)
 *     → มีบรรทัด 1800 ด้านกลับ → `fn_assert_wht_gross_for` บังคับว่า `wht_amount` ที่หัวรายการ
 *     ต้องเท่ากับยอดในบรรทัด 1800 ซึ่งของใบกลับรายการเป็น **ค่าลบ** แต่ check constraint
 *     `transactions` บังคับ `wht_amount > 0` → ไม่มีค่าใดที่ผ่านทั้งสองด่านพร้อมกัน
 *     (และ `v_ledger_posted` ยังไม่เปิดคอลัมน์ `wht_*` ให้อ่านด้วย)
 *     ทางอ้อมที่ **ห้ามทำ**: ตัดบรรทัด 1800 ออกจากใบกลับรายการ — สินทรัพย์ภาษีจะค้างใน
 *     สมุดตลอดกาลทั้งที่รายได้ถูกกลับไปแล้ว แล้วเครดิตภาษีที่ยื่นจะไม่ตรงใบรับรอง
 */

import { parseClearingRef } from "./pending-accruals";
import { groupLedgerRows, type CoaCodeLookup, type LedgerEntry, type LedgerViewRow } from "./ledger-entries";
import type { ReversalSource, ReversalTransaction } from "@/lib/ledger/reversal";
import type { IntercompanyNature } from "@/lib/rules/intercompany";
import { INTERCOMPANY_RULES } from "@/lib/rules/intercompany";
import type { PostEntryPayload } from "./post-entry";
// รหัสบัญชีมาจากผังบัญชีที่เดียว — ประกาศซ้ำที่นี่คือรหัสที่วันหนึ่งจะไม่ตรงกัน
// (บทเรียนข้อ 5 · กฎตารางกฎ: ห้ามพิมพ์รหัสบัญชีกระจาย)
import { WHT_COA } from "@/lib/rules/coa";

/**
 * รายการที่อ่านมาจากสมุด + ข้อเท็จจริงรอบตัวที่ engine มองไม่เห็น
 * **ทุกฟิลด์บังคับ** — ฟิลด์ที่เว้นได้ ผู้เรียกจะเว้น แล้วด่านที่พึ่งฟิลด์นั้นก็ผ่านเงียบๆ
 */
export type ReverseContext = {
  /** รายการต้นฉบับตามที่อยู่ใน `v_ledger_posted` */
  entry: LedgerEntry;
  /**
   * มีใบกลับรายการที่ยัง `posted` ชี้มาที่ใบนี้แล้วหรือไม่
   * (ทุกแถวใน `v_ledger_posted` คือ `posted` → เจอ = ยังมีผลอยู่)
   */
  hasLiveReversal: boolean;
  /** id ของใบล้างยอดค้าง (`source_ref` = `<id ต้นฉบับ>-clr-<n>`) ที่ยัง posted */
  clearedBy: string[];
};

/** รายการที่อ่านมาเป็นใบกลับรายการอยู่แล้วหรือไม่ — ดูทั้งสองช่อง ไม่ใช่ช่องเดียว */
export const isReversalEntry = (e: Pick<LedgerEntry, "source" | "reversesId">): boolean =>
  e.source === "reverse" || e.reversesId !== null;

/** ลักษณะข้ามผู้ถือที่ `src/lib/rules/intercompany.ts` รู้จัก — ค่าที่ไม่รู้จักคืน `undefined` (ไม่เดา) */
export function knownNature(v: string | null): IntercompanyNature | undefined {
  if (v === null) return undefined;
  return v in INTERCOMPANY_RULES ? (v as IntercompanyNature) : undefined;
}

/**
 * เหตุผลที่ "กลับรายการใบนี้จากหน้าจอไม่ได้" — `null` = ทำได้
 *
 * ด่านที่ engine ตรวจอยู่แล้ว (ยอดไม่สมดุล · บรรทัดน้อยกว่าสอง · กลับซ้ำ · วันที่)
 * **ไม่ทำซ้ำที่นี่** เพื่อไม่ให้มีกฎเดียวกันสองที่ที่วันหนึ่งจะคิดต่างกัน
 * ที่นี่มีเฉพาะเรื่องที่ engine มองไม่เห็นเพราะมันอยู่ใน DB หรืออยู่ใน schema
 */
export function reverseBlocker(ctx: ReverseContext): string | null {
  const e = ctx.entry;

  // ---- ใบกลับรายการของใบกลับรายการ: **ไม่ให้** ----
  //
  // เหตุผล (ตัดสินแล้ว · ลูกพี่/mace-windu veto ได้): ผลของมันในสมุดคือ
  // "ยอดเดิมกลับมาอีกครั้ง" ซึ่งอ่านแยกจาก "ลงรายการนั้นใหม่" ไม่ออก แต่ใบที่ได้
  // **ไม่มีคู่ค้า ไม่มีหลักฐาน และไม่มีลิงก์ล้างยอดค้าง** ของต้นฉบับติดมาด้วย
  // (ใบกลับรายการได้รับการยกเว้นหลักฐานของนิติบุคคลโดย `fn_corporate_evidence_ok`
  //  → ถ้าให้กลับซ้อนกันได้ จะเป็นทางเขียนเงินเข้าสมุดโดยไม่ต้องมีหลักฐานกี่ชั้นก็ได้
  //  ซึ่งเป็นรูปแบบเดียวกับรูที่ D-097 ข้อ 1 ปิดไป)
  // และสายโยง `reverses_id` จะกลายเป็นลูกโซ่ที่ตอบไม่ได้ว่าสุทธิของกลุ่มคือเท่าไร
  //
  // **ไม่ใช่ทางตัน**: ใบกลับรายการที่ลงผิดให้ยกเลิก (void) ใบนั้น แล้วถ้ายังต้องการ
  // ตัวเลขเดิมกลับมา ให้ลงรายการนั้นใหม่ตามปกติ (มีหลักฐาน มีคู่ค้า ครบตามกติกา)
  if (isReversalEntry(e)) {
    return (
      "ใบนี้เป็นใบกลับรายการอยู่แล้ว จึงกลับรายการซ้อนอีกชั้นไม่ได้ — " +
      "ถ้าใบกลับรายการนี้ลงผิด ให้ยกเลิก (void) ใบนี้ แล้วถ้าต้องการตัวเลขเดิมกลับมา " +
      "ให้ลงรายการนั้นใหม่ตามปกติ (จะได้หลักฐานและคู่ค้าครบตามกติกา)"
    );
  }

  // ---- ข้ามผู้ถือ: ด่าน DB ปิดอยู่ (เหตุผลข้อ (ก) ที่หัวไฟล์) ----
  if (e.counterOwnerId !== null) {
    return (
      "ใบนี้เป็นขาหนึ่งของรายการข้ามผู้ถือ (สองใบคู่กัน) ซึ่งต้องกลับทั้งคู่พร้อมกัน — " +
      "ฐานข้อมูลวันนี้ยังรับคำขอแบบนั้นไม่ได้ (ช่อง reverses_id อยู่ระดับหัวคำขอ จึงชี้ต้นฉบับได้ใบเดียว " +
      "ขณะที่ขาคู่ต้องลงในคำขอเดียวกัน) · ยังไม่ได้แก้อะไรในสมุด — แจ้งผู้ดูแลระบบให้เปิดด่านนี้ก่อน " +
      "ห้ามกลับข้างเดียว เพราะลูกหนี้/เจ้าหนี้ระหว่างกันจะไม่ตรงกันตลอดไป"
    );
  }

  // ---- ถูกหักภาษี ณ ที่จ่าย: ด่าน DB ปิดอยู่ (เหตุผลข้อ (ข) ที่หัวไฟล์) ----
  if (e.lines.some((l) => l.coaCode === WHT_COA)) {
    return (
      `ใบนี้มีบรรทัดภาษีถูกหัก ณ ที่จ่าย (${WHT_COA}) ซึ่งยังกลับรายการจากหน้าจอไม่ได้ — ` +
      "ใบกลับรายการต้องสะท้อนบรรทัดนั้นด้วย แล้วยอดภาษีที่หัวรายการจะต้องเป็นค่าลบ " +
      "ซึ่งฐานข้อมูลไม่รับ · ยังไม่ได้แก้อะไรในสมุด — แจ้งผู้ดูแลระบบ"
    );
  }

  // ---- ถูกล้างไปแล้ว: ต้องกลับใบล้างก่อน ----
  //
  // กลับต้นฉบับทิ้งโดยที่ใบล้างยังอยู่ = บัญชีพัก (ลูกหนี้/เจ้าหนี้) ถูกลดสองครั้ง
  // จากการตั้งค้างครั้งเดียว → ลูกหนี้ติดลบ และเงินสดที่ใบล้างบันทึกไว้ก็ลอยอยู่
  // โดยไม่มีรายได้/ลูกหนี้ต้นทางรองรับ
  if (ctx.clearedBy.length > 0) {
    return (
      `ใบนี้ถูกล้างไปแล้ว ${ctx.clearedBy.length === 1 ? "1 ใบ" : `${ctx.clearedBy.length} ใบ`} ` +
      "(มีการรับ/จ่ายเงินตามยอดค้างของใบนี้) — ต้องกลับรายการใบล้างก่อน แล้วค่อยกลับใบนี้ " +
      `· ใบล้าง: ${ctx.clearedBy.join(" · ")} · ยังไม่ได้แก้อะไรในสมุด`
    );
  }

  return null;
}

/**
 * เหตุผลที่ "ยกเลิกใบนี้ (void) จากหน้าจอไม่ได้" — `null` = ทำได้
 *
 * D-097: `void` กับ `reverse` เป็นสองกลไก ด่านจึง **ไม่ใช่ชุดเดียวกัน**
 *   - ใบกลับรายการที่ลงผิด **ยกเลิกได้** (D-097 เปิดทางไว้โดยตั้งใจ ไม่ใช่ทางตัน)
 *     จึงไม่มีด่าน `isReversalEntry` ที่นี่
 *   - ใบที่ถูกหักภาษี ณ ที่จ่าย **ยกเลิกได้** — การเปลี่ยนสถานะไม่ได้เพิ่ม/แก้บรรทัด
 *     ยอดภาษีกับบรรทัด 1800 ยังเล่าเรื่องเดียวกัน (ด่าน `fn_assert_wht_gross_for` ยังจริง)
 *   - สิ่งที่ยังปฏิเสธคือสองเรื่องที่ทำให้ **ยอดในสมุดผิดโดยไม่มีด่านไหนจับ**
 */
export function voidBlocker(ctx: ReverseContext): string | null {
  const e = ctx.entry;

  // ---- ข้ามผู้ถือ: ยกเลิกข้างเดียวไม่ได้ และยังระบุขาคู่อย่างแน่ชัดไม่ได้ ----
  //
  // `fn_assert_intercompany_pair` **นับขาคู่โดยไม่ดูสถานะ** → ยกเลิกขาเดียวผ่านฉลุย
  // แล้วลูกหนี้/เจ้าหนี้ระหว่างกันค้างข้างเดียว งบรวมตัดรายการระหว่างกันไม่ลง (Invariant 6)
  // ยกเลิกทั้งคู่ในคำสั่งเดียวทำได้ (update ... in (idA, idB) เป็นคำสั่งเดียว อะตอมมิก)
  // **แต่หาขาคู่อย่างแน่ชัดยังไม่ได้**: `write_txn_id` คือสิ่งที่ผูกสองขาเข้าด้วยกันจริง
  // และ `v_ledger_posted` ยังไม่เปิดคอลัมน์นั้นให้อ่าน · จับคู่จากวันที่/หมวด/ยอด
  // เป็นการ **เดา** ซึ่งถ้าเดาผิดจะยกเลิกใบของคนอื่นไปด้วย → ปฏิเสธ
  if (e.counterOwnerId !== null) {
    return (
      "ใบนี้เป็นขาหนึ่งของรายการข้ามผู้ถือ (สองใบคู่กัน) ซึ่งต้องยกเลิกทั้งคู่พร้อมกัน — " +
      "ระบบยังระบุขาคู่ของใบนี้จากข้อมูลที่อ่านได้อย่างแน่ชัดไม่ได้ จึงไม่ยกเลิกให้ (เดาผิดคือยกเลิกใบของคนอื่น) " +
      "· ยังไม่ได้แก้อะไรในสมุด — แจ้งผู้ดูแลระบบ"
    );
  }

  // ---- ถูกล้างไปแล้ว: ยกเลิกต้นฉบับทิ้งทำให้ใบล้างลอย ----
  //
  // ไม่มีด่านฝั่ง DB กันเรื่องนี้ (`fn_assert_clearing_not_over_for` ยิงตอน**ลง**บรรทัด
  // ไม่ใช่ตอนเปลี่ยนสถานะ) → ยกเลิกต้นฉบับแล้วบัญชีพักจะเหลือแต่ขาที่ใบล้างลดไว้
  // = ลูกหนี้ติดลบ และเงินสดที่ใบล้างบันทึกไว้ไม่มีรายได้/ลูกหนี้ต้นทางรองรับ
  if (ctx.clearedBy.length > 0) {
    return (
      `ใบนี้ถูกล้างไปแล้ว ${ctx.clearedBy.length === 1 ? "1 ใบ" : `${ctx.clearedBy.length} ใบ`} ` +
      "(มีการรับ/จ่ายเงินตามยอดค้างของใบนี้) — ต้องจัดการใบล้างก่อน แล้วค่อยยกเลิกใบนี้ " +
      `· ใบล้าง: ${ctx.clearedBy.join(" · ")} · ยังไม่ได้แก้อะไรในสมุด`
    );
  }

  return null;
}

/**
 * แปลงรายการต้นฉบับเป็น `ReversalSource` ของ engine
 *
 * `status` เป็น `"posted"` คงที่โดยตั้งใจ: แถวทุกแถวใน `v_ledger_posted` คือ `posted`
 * (view กรองด้วย allow-list) ถ้าวันหนึ่งอ่านมาจากที่อื่น ต้องส่ง `status` จริงเข้ามา
 * ไม่ใช่ปล่อยค่าคงที่นี้ไว้ — จึงบังคับให้ผู้เรียกส่ง `ReverseContext` ทั้งก้อน
 */
export function sourceOf(ctx: ReverseContext): ReversalSource {
  const e = ctx.entry;
  const src: ReversalSource = {
    txnId: e.id,
    ownerId: e.ownerId,
    status: "posted",
    docDate: e.docDate,
    hasLiveReversal: ctx.hasLiveReversal,
    lines: e.lines.map((l) => ({
      coaCode: l.coaCode,
      debit: l.debit,
      credit: l.credit,
      // มิติที่ต้นฉบับไม่มีต้อง **ไม่มีคีย์** ไม่ใช่คีย์ที่เป็น null —
      // ฝั่ง DB เทียบ multiset ของบรรทัด ถ้ารูปไม่ตรงกัน ด่านสะท้อนจะปฏิเสธ
      ...(l.bankAccountId === null ? {} : { bankAccountId: l.bankAccountId }),
      ...(l.assetId === null ? {} : { assetId: l.assetId }),
      ...(l.cfCategory === null ? {} : { cfCategory: l.cfCategory as never }),
    })),
  };
  // ข้ามผู้ถือถูกปฏิเสธที่ `reverseBlocker()` ไปแล้ว — ส่งต่อไว้เพื่อให้ engine
  // ปฏิเสธอีกชั้นถ้ามีใครเรียกไฟล์นี้โดยไม่ผ่านด่าน (ไม่ใช่เงียบแล้วกลับข้างเดียว)
  const nature = knownNature(e.intercompanyNature);
  if (e.counterOwnerId !== null) src.counterOwnerId = e.counterOwnerId;
  if (nature !== undefined) src.intercompanyNature = nature;
  return src;
}

/** แถวของ view → รายการเดียวที่ขอมา · ไม่เจอ/เจอหลายใบ = คืน `null` (ไม่เดา) */
export function entryFromRows(rows: LedgerViewRow[], id: string, coaCodeById: CoaCodeLookup): LedgerEntry | null {
  const entries = groupLedgerRows(
    rows.filter((r) => r.transaction_id === id),
    coaCodeById
  );
  return entries.length === 1 ? entries[0] : null;
}

/** ใบล้างที่ยัง posted ของต้นฉบับใบนี้ — อ่านจาก `source_ref` ไม่ได้เดาจากยอด */
export function clearedByFromRows(rows: LedgerViewRow[], sourceId: string): string[] {
  const ids = new Set<string>();
  for (const r of rows) {
    const ref = parseClearingRef(r.source_ref);
    if (ref && ref.sourceId === sourceId.toLowerCase()) ids.add(r.transaction_id);
  }
  return [...ids].sort();
}

/**
 * ใบที่ engine สะท้อนมาแล้ว → payload ของ `fn_post_entry`
 *
 * **ไม่แตะบรรทัด** แปลงชื่อช่องเป็น snake_case เท่านั้น (แพทเทิร์นเดียวกับ `toPostEntryPayload`)
 *
 * ช่องของหัวรายการที่คัดลอกจากต้นฉบับและ **เหตุผล**:
 *   - `txn_type_code` — ด่าน `trg_lines_rule_coa` เทียบบัญชีของบรรทัดกับ **ชุด**บัญชีของหมวดนั้น
 *     ใช้หมวดอื่นแล้วบรรทัดที่สะท้อนมาจะหลุดชุด (และสมุดจะอ่านไม่รู้เรื่องว่ากลับอะไร)
 *   - `contact_id` — นิติบุคคลที่หมวดนั้น `requires_contact` ยังบังคับคู่ค้าเสมอ
 *     (ข้อยกเว้นของใบกลับรายการครอบแค่ **ไฟล์หลักฐาน** ไม่ได้ครอบคู่ค้า)
 *   - `asset_id` — รายงานรายทรัพย์ต้องเห็นว่าใบนี้กลับของทรัพย์ชิ้นไหน
 *
 * ช่องที่ **ไม่** คัดลอกและเหตุผล:
 *   - `attachments` — ใบกลับรายการมีเหตุผลของตัวเองใน `memo` และ
 *     `fn_corporate_evidence_ok` ยกเว้นไฟล์หลักฐานให้ใบกลับรายการที่พิสูจน์ได้แล้ว
 *     คัดลอกไฟล์ของต้นฉบับมาแปะจะอ่านว่า "ใบนี้มีเอกสารของตัวเอง" ซึ่งไม่จริง
 *   - `source_ref` — เลขอ้างอิงการล้างเป็นของใบล้าง ไม่ใช่ของใบกลับรายการ
 *     ติดมาด้วยจะถูกนับเป็นการล้างอีกครั้ง (ยอดค้างเพี้ยน)
 *   - `wht_*` — ใบที่มีภาษีถูกหักถูกปฏิเสธที่ `reverseBlocker()` ไปแล้วทั้งใบ
 */
export function toReversalPayload(
  txn: ReversalTransaction,
  header: { txnTypeCode: string; contactId: string | null; assetId: string | null }
): PostEntryPayload {
  const blank = (s: string | null) => (s && s.trim() !== "" ? s : undefined);
  return {
    txn_type_code: header.txnTypeCode,
    doc_date: txn.docDate,
    cash_date: txn.cashDate,
    memo: txn.memo,
    asset_id: blank(header.assetId),
    contact_id: blank(header.contactId),
    // `source` ต้องเป็น 'reverse' **ตัวอักษรนี้** — `fn_corporate_evidence_ok` และ
    // `fn_assert_bank_account_open` (D-092) ตัดสินจากค่านี้คู่กับ `reverses_id`
    source: "reverse",
    reverses_id: txn.reversesId,
    transactions: [
      {
        owner_id: txn.ownerId,
        ...(txn.counterOwnerId === undefined ? {} : { counter_owner_id: txn.counterOwnerId }),
        ...(txn.intercompanyNature === undefined ? {} : { intercompany_nature: txn.intercompanyNature }),
        lines: txn.lines.map((l) => ({
          coa_code: l.coaCode,
          bank_account_id: l.bankAccountId,
          asset_id: l.assetId,
          debit: l.debit,
          credit: l.credit,
          cf_category: l.cfCategory,
          memo: l.memo,
          // บรรทัดบาทต้องไม่มีสี่ช่องนี้เลย (check constraint ยอมแค่ "ครบสี่" หรือ "ไม่มี")
          ...(l.currency === undefined
            ? {}
            : { currency: l.currency, amount_original: l.amountOriginal, fx_rate: l.fxRate, fx_rate_date: l.fxRateDate }),
        })),
      },
    ],
  };
}
