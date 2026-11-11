"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getAccess } from "@/lib/auth/session";
import { loadReference } from "@/lib/db/reference";
import { humanizeDbError, readPostResult } from "@/lib/db/post-entry";
import {
  clearedByFromRows,
  entryFromRows,
  reverseBlocker,
  sourceOf,
  toReversalPayload,
  voidBlocker,
  type ReverseContext,
} from "@/lib/db/reverse-entry";
import type { LedgerViewRow } from "@/lib/db/ledger-entries";
import { buildReversal } from "@/lib/ledger/reversal";
import { PostingError } from "@/lib/ledger/types";
import { isCashAccount } from "@/lib/rules/coa";
import { dmyToIso, todayDmy } from "@/lib/format";
import type { Permission } from "@/lib/auth/permissions";

/**
 * **ทางเดียวที่หน้าจอแก้รายการที่ post แล้วได้** (กฎเหล็กข้อ 1: ห้าม DELETE)
 *
 * D-097 — สองกลไก ใช้ต่างสถานการณ์ **ห้ามปนกัน**
 *
 * | | `voidEntry()` | `reverseEntry()` |
 * |---|---|---|
 * | ใช้เมื่อ | งวด**ยังไม่ปิด** (ลงผิดแล้วรู้ตัวเลย) | งวด**ปิดแล้ว** / ส่งงบไปแล้ว |
 * | ต้นฉบับ | → `void` **ไม่นับในงบ** (แถวยังอยู่ · D-098) | ยัง `posted` **นับต่อไป** |
 * | ใบใหม่ | **ไม่มี** | มี · วันที่วันนี้ · `posted` · ผูกด้วย `reverses_id` |
 * | ยอดสุทธิ | ต้นฉบับหายจากงบ | ต้นฉบับ + ใบกลับรายการ = 0 |
 * | งบเดือนเก่า | แก้ให้ถูก | **ไม่ขยับ** (ยื่นไปแล้ว) |
 *
 * **ทั้งสองทางไม่ลบอะไร** และทั้งสองทางบังคับ "เหตุผล" เพราะนั่นคือสิ่งเดียวที่ทำให้
 * ร่องรอยที่เก็บไว้มีประโยชน์ (ผู้สอบบัญชีถามว่าทำไมตัวเลขเดือนนั้นเปลี่ยน)
 *
 * ของที่ไฟล์นี้ **ไม่ทำ**
 * - ไม่สร้างบรรทัดบัญชีเอง — `buildReversal()` สะท้อนบรรทัดที่เก็บอยู่ในสมุดให้
 *   (เหตุผลที่ไม่เรียก `buildPosting()` อยู่หัวไฟล์ `src/lib/ledger/reversal.ts`:
 *    ตารางกฎของวันนี้ไม่ใช่ตารางกฎของวันที่ลงต้นฉบับ สองใบจะหักกันไม่หมด)
 * - ไม่รับบรรทัด วันที่ หรือยอดจาก browser เลย — คำขอมีแค่ "ใบไหน" กับ "เพราะอะไร"
 *   วันที่ของใบใหม่ใช้ **วันนี้ฝั่งเซิร์ฟเวอร์** (D-097) ผู้เรียกกำหนดไม่ได้
 * - ไม่เดาเมื่อข้อมูลไม่ครบ — ปฏิเสธพร้อมบอกว่ายังไม่ได้แก้อะไรในสมุด
 *
 * ด่านจริงอยู่ที่ DB (`fn_reverse_link_ok` · `fn_assert_reverse_mirrors` ·
 * `fn_void_is_terminal` · `fn_void_blocked_by_reverse` · `fn_period_locked_on_void`)
 * ที่นี่กันไว้ก่อนเพื่อให้ผู้ใช้เห็นข้อความที่อ่านรู้เรื่อง **ไม่ใช่ตัวกั้นสุดท้าย**
 */

export type ReverseEntryRequest = {
  /** id ของรายการที่ลงผิด */
  transactionId: string;
  /** เหตุผล — บังคับทั้งสองกลไก */
  reason: string;
};

export type ReverseEntryOutcome =
  | { ok: true; transactionIds: string[]; replayed: boolean; summary: string[] }
  | { ok: false; message: string };

export type VoidEntryOutcome = { ok: true; transactionId: string } | { ok: false; message: string };

const fail = (message: string) => ({ ok: false as const, message });

/** คอลัมน์ที่ต้องอ่านจาก `v_ledger_posted` — ขอให้ครบตั้งแต่แรก ขาดคอลัมน์ = สะท้อนบรรทัดไม่ครบ */
const LEDGER_COLS =
  "transaction_id, owner_id, txn_type_code, doc_date, cash_date, doc_no, txn_asset_id, contact_id, " +
  "counter_owner_id, intercompany_nature, txn_memo, attachments, source, source_ref, reverses_id, created_at, " +
  "coa_id, bank_account_id, debit, credit, cf_category, line_asset_id, line_memo";

/** เหตุผลที่ผู้ใช้พิมพ์ — ว่าง/ช่องว่างล้วน = ไม่ได้ให้เหตุผล */
function cleanReason(v: unknown): string {
  return typeof v === "string" ? v.trim() : "";
}

const MISSING_REASON =
  "ต้องใส่เหตุผลก่อน — การแก้รายการที่บันทึกแล้วคือการเขียนตัวเลขเข้าสมุด " +
  "เหตุผลหนึ่งบรรทัดคือสิ่งที่ผู้สอบบัญชีและสรรพากรจะถามว่าทำไมตัวเลขเดือนนั้นเปลี่ยน · ยังไม่ได้แก้อะไรในสมุด";

type Loaded =
  | { ok: true; ctx: ReverseContext; supabase: Awaited<ReturnType<typeof createClient>> }
  | { ok: false; message: string };

/**
 * อ่านต้นฉบับ + ข้อเท็จจริงรอบตัวจากสมุด **สดทุกครั้ง** (ไม่เชื่อสแนปช็อตในหน้าจอ)
 *
 * สามคำถามที่เครื่องยนต์ตอบเองไม่ได้เพราะต้องถามสมุด:
 *   1. บรรทัดของต้นฉบับคืออะไร (อ่านจาก `v_ledger_posted` ไม่ใช่รันตารางกฎใหม่)
 *   2. มีใบกลับรายการที่ยังนับอยู่ชี้มาที่ใบนี้แล้วหรือยัง
 *   3. มีใบล้างยอดค้างของใบนี้แล้วหรือยัง
 */
async function loadContext(id: string): Promise<Loaded> {
  const refState = await loadReference();
  if (!refState.ok) return fail(`โหลดข้อมูลอ้างอิงจากฐานข้อมูลไม่ได้ ยังไม่ได้แก้อะไรในสมุด (${refState.error})`);

  let supabase;
  try {
    supabase = await createClient();
  } catch (e) {
    return fail(e instanceof Error ? e.message : String(e));
  }

  const posted = await supabase.from("v_ledger_posted").select(LEDGER_COLS).eq("transaction_id", id);
  if (posted.error) return fail(`อ่านรายการจากสมุดไม่สำเร็จ ยังไม่ได้แก้อะไรในสมุด (${posted.error.message})`);

  const entry = entryFromRows((posted.data ?? []) as unknown as LedgerViewRow[], id, refState.ref.coaCodeById);
  if (!entry) {
    // แยก "ถูกยกเลิกไปแล้ว" ออกจาก "ไม่มี/มองไม่เห็น" — สองอย่างนี้ผู้ใช้ต้องทำต่างกัน
    const voided = await supabase.from("v_ledger_voided").select("transaction_id").eq("transaction_id", id);
    if (!voided.error && (voided.data ?? []).length > 0) {
      return fail(
        "ใบนี้ถูกยกเลิก (void) ไปแล้ว จึงไม่ถูกนับในงบอยู่แล้ว — ไม่ต้องกลับรายการอีก " +
          "ถ้าต้องการตัวเลขที่ถูก ให้ลงรายการใหม่ · ยังไม่ได้แก้อะไรในสมุด"
      );
    }
    return fail(
      "ไม่พบรายการนี้ในสมุด (อาจถูกยกเลิกไปแล้ว หรืออยู่นอกขอบเขตที่บัญชีของคุณมองเห็น) — " +
        "โหลดหน้าใหม่แล้วลองอีกครั้ง · ยังไม่ได้แก้อะไรในสมุด"
    );
  }

  const reversals = await supabase.from("v_ledger_posted").select("transaction_id").eq("reverses_id", id);
  if (reversals.error) {
    // ตรวจไม่ได้ = ปฏิเสธ · ห้ามถือว่า "ยังไม่มีใบกลับรายการ" เพราะถ้าเดาผิดคือหักสองรอบ
    return fail(`ตรวจไม่ได้ว่าใบนี้ถูกกลับรายการไปแล้วหรือยัง จึงไม่ดำเนินการต่อ (${reversals.error.message})`);
  }

  // `source_ref` เป็นข้อความ จึงเทียบแบบ case-sensitive ต่างจาก `transaction_id` (uuid)
  // ที่ Postgres เทียบให้เอง — ไม่ lower ก่อน ด่าน "ถูกล้างแล้ว" จะเงียบและผ่าน
  // เมื่อผู้เรียกส่ง id ตัวพิมพ์ใหญ่มา (UI ไม่ส่ง แต่ server action ยิงตรงได้)
  const clearings = await supabase
    .from("v_ledger_posted")
    .select("transaction_id, source_ref")
    .like("source_ref", `${id.toLowerCase()}-clr-%`);
  if (clearings.error) {
    return fail(`ตรวจไม่ได้ว่าใบนี้ถูกล้างยอดค้างไปแล้วหรือยัง จึงไม่ดำเนินการต่อ (${clearings.error.message})`);
  }

  const clearedBy = clearedByFromRows((clearings.data ?? []) as unknown as LedgerViewRow[], id);

  /**
   * **ใบล้างที่ถูกกลับรายการไปแล้ว ต้องไม่นับเป็นตัวบล็อกอีก**
   *
   * ข้อความปฏิเสธบอกผู้ใช้ว่า "ให้กลับรายการใบล้างก่อน แล้วค่อยกลับใบนี้" —
   * ถ้าไม่หักใบล้างที่ถูกกลับแล้วออก ใบล้างเดิมยัง `posted` และยังมี `source_ref`
   * เดิมอยู่ → บล็อกเดิมยิงซ้ำตลอดไป **ต้นฉบับกลับรายการไม่ได้ถาวร**
   * = เปิดฟีเจอร์ครึ่งเดียว (บทเรียนข้อ 7) ซึ่งอันตรายกว่าไม่เปิด เพราะผู้ใช้
   * ทำตามที่ระบบบอกแล้วยังติดอยู่ที่เดิม และไม่มีอะไรบอกว่าทำไม
   *
   * ฝั่ง DB หักให้แล้ว (`fn_assert_clearing_not_over_for` ดู `reverses_id`)
   * ฝั่งแอปต้องหักด้วย ไม่งั้นสองฝั่งตอบคนละอย่าง
   *
   * ใช้แพทเทิร์นเดียวกับ `hasLiveReversal` — ทุกแถวใน `v_ledger_posted` คือ
   * `posted` อยู่แล้ว เจอ = ใบกลับรายการนั้นยังมีผล
   */
  let liveClearedBy = clearedBy;
  if (clearedBy.length > 0) {
    const reversedClearings = await supabase
      .from("v_ledger_posted")
      .select("reverses_id")
      .in("reverses_id", clearedBy);
    if (reversedClearings.error) {
      // ตรวจไม่ได้ = ปฏิเสธ · เดาว่า "ยังไม่ถูกกลับ" แล้วบล็อกค้าง ยังพอทน
      // แต่เดาว่า "ถูกกลับแล้ว" จะปล่อยให้กลับต้นฉบับทั้งที่ยอดยังถูกล้างอยู่
      return fail(
        `ตรวจไม่ได้ว่าใบล้างถูกกลับรายการไปแล้วหรือยัง จึงไม่ดำเนินการต่อ (${reversedClearings.error.message})`
      );
    }
    const reversed = new Set(
      (reversedClearings.data ?? []).map((r) => String((r as { reverses_id: string }).reverses_id).toLowerCase())
    );
    liveClearedBy = clearedBy.filter((c) => !reversed.has(c.toLowerCase()));
  }

  return {
    ok: true,
    supabase,
    ctx: {
      entry,
      hasLiveReversal: (reversals.data ?? []).length > 0,
      clearedBy: liveClearedBy,
    },
  };
}

/** สิทธิ์ — ความสะดวก · ด่านจริงคือ RLS (`txn_insert` ต้องมี ledger.approve · `txn_update` ต้องมี txn.void) */
async function gate(need: readonly Permission[]) {
  const access = await getAccess();
  if (!access.user) return fail("เข้าสู่ระบบหมดอายุ — ให้เข้าสู่ระบบใหม่แล้วลองอีกครั้ง");
  if (access.error) return fail(`ตรวจสิทธิ์ไม่สำเร็จ ยังไม่ได้แก้อะไรในสมุด (${access.error})`);
  for (const p of need) {
    if (!access.permissions.has(p)) {
      return fail("บัญชีนี้ไม่มีสิทธิ์แก้รายการที่บันทึกเข้าสมุดแล้ว — ต้องมีสิทธิ์ยกเลิก/กลับรายการ · ยังไม่ได้แก้อะไรในสมุด");
    }
  }
  return { ok: true as const, userId: access.user.id };
}

/**
 * **กลับรายการ** — ลงใบใหม่ที่สะท้อนบรรทัดของต้นฉบับแบบสลับข้าง ผูกด้วย `reverses_id`
 * ต้นฉบับยังอยู่ในสมุดและยังถูกนับ · ใบใหม่คือขาที่ทำให้ยอดสุทธิเป็นศูนย์
 */
export async function reverseEntry(req: ReverseEntryRequest): Promise<ReverseEntryOutcome> {
  const g = await gate(["ledger.approve", "txn.void"]);
  if (!g.ok) return g;

  if (!req || typeof req !== "object") return fail("ไม่ได้รับข้อมูลคำขอ — ยังไม่ได้แก้อะไรในสมุด");
  const id = typeof req.transactionId === "string" ? req.transactionId.trim() : "";
  if (id === "") return fail("ไม่ได้ระบุว่าจะกลับรายการใบไหน — ยังไม่ได้แก้อะไรในสมุด");
  const reason = cleanReason(req.reason);
  if (reason === "") return fail(MISSING_REASON);

  const loaded = await loadContext(id);
  if (!loaded.ok) return loaded;
  const { ctx, supabase } = loaded;

  const blocked = reverseBlocker(ctx);
  if (blocked) return fail(blocked);

  // ---- engine: สะท้อนบรรทัดที่เก็บไว้ (ไม่รันตารางกฎใหม่ · ไม่คำนวณยอดใหม่) ----
  //
  // วันที่ของใบกลับรายการ = **วันนี้** (D-097: งวดที่ปิดแล้วห้ามขยับ)
  // `cashDate` ส่งเฉพาะเมื่อมีบรรทัดเงินสดจริง — ส่งตอนไม่มีคือเงินสดผี
  // และไม่ส่งตอนที่มีคือยอดค้างในงบกระแสเงินสดตลอดกาล (engine ปฏิเสธทั้งสองทาง)
  const today = dmyToIso(todayDmy());
  if (!today) return fail("อ่านวันที่ของวันนี้จากระบบไม่ได้ จึงไม่ลงใบกลับรายการ — แจ้งผู้ดูแลระบบ");
  const hasCash = ctx.entry.lines.some((l) => isCashAccount(l.coaCode));

  let built;
  try {
    built = buildReversal({
      originals: [sourceOf(ctx)],
      reason,
      docDate: today,
      ...(hasCash ? { cashDate: today } : {}),
    });
  } catch (e) {
    if (e instanceof PostingError) return fail(`${e.message} · ยังไม่ได้แก้อะไรในสมุด`);
    console.error("reverseEntry: unexpected error while mirroring the original entry", e);
    return fail("ระบบประกอบใบกลับรายการไม่สำเร็จด้วยเหตุที่ไม่คาดคิด ยังไม่ได้แก้อะไรในสมุด — แจ้งผู้ดูแลระบบ");
  }

  // ข้ามผู้ถือถูกปฏิเสธไปแล้วข้างบน → ที่นี่ต้องได้ใบเดียวเสมอ
  // ถ้าได้มากกว่านั้นแปลว่ามีเส้นทางใหม่ที่ยังไม่ได้คิดเรื่อง `reverses_id` ต่อใบ → หยุด
  if (built.transactions.length !== 1) {
    return fail(
      `ใบนี้ต้องกลับรายการ ${built.transactions.length} ใบพร้อมกัน ซึ่งประตูบันทึกยังรับไม่ได้ ` +
        "(reverses_id เป็นช่องระดับหัวคำขอ) · ยังไม่ได้แก้อะไรในสมุด — แจ้งผู้ดูแลระบบ"
    );
  }

  const payload = toReversalPayload(built.transactions[0], {
    txnTypeCode: ctx.entry.subCode,
    contactId: ctx.entry.contactId,
    assetId: ctx.entry.assetId,
  });

  const { data, error } = await supabase.rpc("fn_post_entry", { p_payload: payload });
  if (error) return fail(humanizeDbError(error));

  const read = readPostResult(data, 1);
  if (!read.ok) return fail(read.message);

  revalidatePath("/ledger");
  revalidatePath("/dashboard");
  revalidatePath("/reports");
  return { ok: true, transactionIds: read.transactionIds, replayed: read.replayed, summary: built.summary };
}

/**
 * **ยกเลิกใบ (void)** — ต้นฉบับเปลี่ยนสถานะเป็น `void` แถวยังอยู่ที่เดิม (D-098)
 * ไม่มีใบใหม่ · งบอ่านจาก `v_ledger_posted` ที่กรองเฉพาะ `posted` จึงไม่นับใบนี้อีก
 *
 * **ไม่ใช่กลไกเดียวกับกลับรายการ** และปนกันไม่ได้ (D-097 ข้อ 2):
 * ถ้าต้นฉบับ `void` (ไม่นับ) ขณะที่ใบกลับรายการยัง `posted` (นับ) สมุดจะผิดไป −ต้นฉบับ
 * → `fn_void_blocked_by_reverse` ปฏิเสธให้ และไฟล์นี้ส่งข้อความนั้นต่อโดยไม่กลืน
 */
export async function voidEntry(req: ReverseEntryRequest): Promise<VoidEntryOutcome> {
  const g = await gate(["txn.void"]);
  if (!g.ok) return g;

  if (!req || typeof req !== "object") return fail("ไม่ได้รับข้อมูลคำขอ — ยังไม่ได้แก้อะไรในสมุด");
  const id = typeof req.transactionId === "string" ? req.transactionId.trim() : "";
  if (id === "") return fail("ไม่ได้ระบุว่าจะยกเลิกใบไหน — ยังไม่ได้แก้อะไรในสมุด");
  const reason = cleanReason(req.reason);
  if (reason === "") return fail(MISSING_REASON);

  const loaded = await loadContext(id);
  if (!loaded.ok) return loaded;
  const { ctx, supabase } = loaded;

  const blocked = voidBlocker(ctx);
  if (blocked) return fail(blocked);

  // เขียนทั้งสามคอลัมน์พร้อมกับสถานะในคำสั่งเดียว — check constraint ของ DB บังคับสองทาง
  // (`status = 'void'` ⟺ ครบทั้งสามคอลัมน์) จึงแยกเป็นสองคำสั่งไม่ได้อยู่แล้ว
  // `eq("status", "posted")` ทำให้การกดซ้ำไม่แตะแถวที่ยกเลิกแล้ว (และ `fn_void_is_terminal` กันอีกชั้น)
  const { data, error } = await supabase
    .from("transactions")
    .update({
      status: "void",
      void_reason: reason,
      voided_by: g.userId,
      voided_at: new Date().toISOString(),
    })
    .eq("id", id)
    .eq("status", "posted")
    .select("id");

  if (error) return fail(humanizeDbError(error));
  // ไม่มีแถวถูกแตะ = RLS กรองออก หรือสถานะเปลี่ยนไปแล้วระหว่างทาง → **ห้ามตอบว่าสำเร็จ**
  if (!Array.isArray(data) || data.length !== 1) {
    return fail(
      "ยกเลิกไม่สำเร็จ — ฐานข้อมูลไม่ได้แก้แถวใด (อาจไม่มีสิทธิ์ยกเลิกรายการของผู้ถือรายนี้ " +
        "หรือใบนี้ถูกยกเลิก/เปลี่ยนสถานะไปแล้วระหว่างทาง) · เปิดหน้าสมุดบัญชีตรวจก่อนลองอีกครั้ง"
    );
  }

  revalidatePath("/ledger");
  revalidatePath("/dashboard");
  revalidatePath("/reports");
  return { ok: true, transactionId: id };
}
