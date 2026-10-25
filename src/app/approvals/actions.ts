"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getAccess } from "@/lib/auth/session";
import { humanizeDbError } from "@/lib/db/post-entry";
import { approvalInput, toApprovalItem, type DraftEntryRow } from "@/lib/db/approvals-model";
import { isoToDmy } from "@/lib/format";
import { postEntry } from "@/app/actions/post-entry";

/**
 * อนุมัติ / ไม่อนุมัติ ร่างรายการ (`draft_entries`) — **ที่เดียวที่ร่างกลายเป็นรายการบัญชีจริง** (กฎเหล็กข้อ 6)
 *
 * อนุมัติ = เรียก `postEntry()` (→ `buildPosting()` ตัวจริง → `fn_post_entry`) แล้วจึงปิดร่าง
 *   ไม่เขียนตาราง `transactions` / `transaction_lines` ตรงๆ เด็ดขาด · ไม่ส่งบรรทัดบัญชีจากหน้าจอ
 *   ลำดับ "ลงสมุดก่อน แล้วปิดร่าง": ถ้าปิดร่างไม่สำเร็จ ร่างยัง pending และกดอนุมัติซ้ำได้ —
 *   คำขอเดียวกันถูก DB ตอบ replay (ไม่ลงซ้ำ) แล้วจึงปิดร่างต่อ
 * ไม่อนุมัติ = แก้เฉพาะแถวร่าง (status · reject_reason · reviewed_*) **ไม่แตะสมุดเลย**
 *
 * ด่านสิทธิ์คือ RLS (`txn_insert` · `draft_review` ต้องมี ledger.approve) ไม่ใช่โค้ดนี้
 *
 * ข้อจำกัดฝั่ง DB ที่รายงานลูกพี่แล้ว (ไม่บังคับแค่ที่หน้าจอ · D-115):
 *   1. policy `draft_review` ไม่ห้ามผู้อนุมัติเป็นคนเดียวกับผู้สร้างร่าง — หน้าจอ **แสดงธง** ไม่ได้ **กั้น**
 *   2. ไม่มีด่านใน DB ว่า status=approved ต้องมี posted_txn_id · ผู้อนุมัติสองคนพร้อมกันมีช่องลงซ้ำ (fingerprint กันเฉพาะคำขอเดียวกันของคนเดียวกัน)
 */

export type ApprovalOutcome = { ok: true; message: string; transactionIds?: string[] } | { ok: false; message: string };

type Db = Awaited<ReturnType<typeof createClient>>;

const COLUMNS =
  "id, owner_id, txn_type_code, doc_date, cash_date, amount, asset_id, contact_id, contract_id, memo, attachments, status, reject_reason, due_date, source, source_ref, posted_txn_id, created_by, reviewed_by, reviewed_at, created_at";

async function open(): Promise<{ ok: true; db: Db; userId: string } | { ok: false; message: string }> {
  const access = await getAccess();
  if (!access.user) return { ok: false, message: "เข้าสู่ระบบหมดอายุ — ให้เข้าสู่ระบบใหม่แล้วลองอีกครั้ง" };
  try {
    return { ok: true, db: await createClient(), userId: access.user.id };
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : String(e) };
  }
}

async function readPending(db: Db, id: string): Promise<{ ok: true; row: DraftEntryRow } | { ok: false; message: string }> {
  const { data, error } = await db.from("draft_entries").select(COLUMNS).eq("id", id).maybeSingle();
  if (error) return { ok: false, message: humanizeDbError(error) };
  // มองไม่เห็นกับไม่มีอยู่ตอบเหมือนกัน (RLS)
  if (!data) return { ok: false, message: "ไม่พบร่างนี้ หรือคุณไม่มีสิทธิ์เห็นร่างนี้ ยังไม่ได้ทำอะไร" };
  const row = data as unknown as DraftEntryRow;
  if (row.status !== "pending") return { ok: false, message: `ร่างนี้อยู่สถานะ ${row.status} แล้ว ทำซ้ำไม่ได้ ยังไม่ได้ทำอะไร` };
  return { ok: true, row };
}

function refresh() {
  revalidatePath("/approvals");
  revalidatePath("/ledger");
  revalidatePath("/dashboard");
}

export async function approveDraftEntry(draftId: string): Promise<ApprovalOutcome> {
  const s = await open();
  if (!s.ok) return s;
  const d = await readPending(s.db, draftId);
  if (!d.ok) return d;

  const item = toApprovalItem(d.row, () => "");
  const input = approvalInput(item);
  if (!input) return { ok: false, message: `ไม่รู้จักหมวดย่อย "${item.subCode}" ในตารางกฎ — ระบบไม่เดาประเภทรายการให้ จึงอนุมัติไม่ได้ ยังไม่ได้บันทึกอะไร` };

  // ลงสมุดผ่านเส้นทางเดียวกับหน้าบันทึกรายการ (engine ตัวจริง + fn_post_entry)
  const posted = await postEntry({
    input,
    docDate: isoToDmy(item.docDate),
    cashDate: item.cashDate ? isoToDmy(item.cashDate) : "",
  });
  if (!posted.ok) return { ok: false, message: `${posted.message} — ร่างยังรออนุมัติ ไม่มีอะไรถูกบันทึก` };

  const { data, error } = await s.db
    .from("draft_entries")
    .update({
      status: "approved",
      posted_txn_id: posted.transactionIds[0] ?? null,
      reviewed_by: s.userId,
      reviewed_at: new Date().toISOString(),
    })
    .eq("id", draftId)
    .eq("status", "pending")
    .select("id");
  if (error || !data || data.length === 0) {
    return {
      ok: false,
      message:
        "ลงสมุดบัญชีแล้ว แต่ปิดร่างนี้ไม่สำเร็จ" +
        (error ? ` (${humanizeDbError(error)})` : " (ฐานข้อมูลไม่แก้แถวร่างให้)") +
        " — ร่างยังขึ้นรออนุมัติ ห้ามลงรายการนี้ซ้ำด้วยมือ ให้กดอนุมัติอีกครั้ง ระบบจะรู้ว่าเป็นรายการเดิมและไม่ลงซ้ำ",
    };
  }
  refresh();
  return { ok: true, message: posted.replayed ? "อนุมัติแล้ว (รายการนี้เคยลงสมุดไว้แล้ว ไม่ลงซ้ำ)" : "อนุมัติแล้ว — ลงสมุดบัญชีเรียบร้อย", transactionIds: posted.transactionIds };
}

export async function rejectDraftEntry(draftId: string, reason: string): Promise<ApprovalOutcome> {
  const s = await open();
  if (!s.ok) return s;
  // ปฏิเสธโดยไม่บอกเหตุผล = ผู้สร้างแก้ไม่ถูก
  const why = String(reason ?? "").trim();
  if (!why) return { ok: false, message: "ต้องใส่เหตุผลที่ไม่อนุมัติ — ผู้สร้างร่างจะเห็นข้อความนี้ ยังไม่ได้ทำอะไร" };
  const d = await readPending(s.db, draftId);
  if (!d.ok) return d;

  const { data, error } = await s.db
    .from("draft_entries")
    .update({ status: "rejected", reject_reason: why, reviewed_by: s.userId, reviewed_at: new Date().toISOString() })
    .eq("id", draftId)
    .eq("status", "pending")
    .select("id");
  if (error) return { ok: false, message: humanizeDbError(error) };
  if (!data || data.length === 0) {
    return { ok: false, message: "ไม่มีสิทธิ์ไม่อนุมัติร่างนี้ — ฐานข้อมูลไม่แก้ให้ ยังไม่มีอะไรเปลี่ยน" };
  }
  refresh();
  return { ok: true, message: "ส่งกลับให้ผู้สร้างแก้ไขแล้ว — ไม่มีอะไรถูกบันทึกลงสมุด" };
}

export type BulkOutcome = { ok: true; approved: number; failed: { id: string; message: string }[] } | { ok: false; message: string };

/** อนุมัติทีละใบตามลำดับ — ใบที่ติดไม่ดับทั้งคิว แต่ทุกใบที่ข้ามต้องบอกเหตุผล */
export async function approveDraftEntries(ids: string[]): Promise<BulkOutcome> {
  if (!Array.isArray(ids) || ids.length === 0) return { ok: false, message: "ไม่ได้เลือกรายการ ยังไม่ได้ทำอะไร" };
  const unique = [...new Set(ids)];
  let approved = 0;
  const failed: { id: string; message: string }[] = [];
  for (const id of unique) {
    const r = await approveDraftEntry(id);
    if (r.ok) approved++;
    else failed.push({ id, message: r.message });
  }
  return { ok: true, approved, failed };
}

export async function rejectDraftEntries(ids: string[], reason: string): Promise<BulkOutcome> {
  if (!Array.isArray(ids) || ids.length === 0) return { ok: false, message: "ไม่ได้เลือกรายการ ยังไม่ได้ทำอะไร" };
  if (!String(reason ?? "").trim()) return { ok: false, message: "ต้องใส่เหตุผลที่ไม่อนุมัติ — ผู้สร้างร่างจะเห็นข้อความนี้ ยังไม่ได้ทำอะไร" };
  const unique = [...new Set(ids)];
  let done = 0;
  const failed: { id: string; message: string }[] = [];
  for (const id of unique) {
    const r = await rejectDraftEntry(id, reason);
    if (r.ok) done++;
    else failed.push({ id, message: r.message });
  }
  return { ok: true, approved: done, failed };
}
