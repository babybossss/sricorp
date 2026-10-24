import type { SupabaseClient } from "@supabase/supabase-js";
import { createClient } from "@/lib/supabase/server";
import { loadReference } from "./reference";
import type { LedgerViewRow } from "./ledger-entries";
import { derivePendingAccruals, type PendingAccrual } from "./pending-accruals";

/** คอลัมน์ของ `v_ledger_posted` ที่ต้องใช้ — เขียนชื่อตรงๆ ไม่ใช้ `*` (คอลัมน์ใหม่ต้องไม่ไหลเข้าเองเงียบๆ) */
const COLUMNS =
  "transaction_id, owner_id, txn_type_code, doc_date, cash_date, doc_no, txn_asset_id, contact_id, " +
  "counter_owner_id, intercompany_nature, txn_memo, attachments, source, source_ref, reverses_id, created_at, " +
  "coa_id, bank_account_id, debit, credit, cf_category, line_asset_id, line_memo";

/** เพดานบรรทัดต่อคำถาม — ชนเพดาน = ปฏิเสธ ไม่ตัดเงียบ (ตัดแล้วยอดค้างบางรายการจะหาย/ประวัติการล้างจะขาด) */
const LINE_LIMIT = 5000;

export type PendingAccrualsState =
  | { ok: true; pending: PendingAccrual[]; clearedIds: string[] }
  | { ok: false; error: string };

type Db = Pick<SupabaseClient, "from">;

/** อ่านเป็นก้อนเดียวจาก `v_ledger_posted` เท่านั้น (D-107) */
async function fetchRows(
  db: Db,
  build: (q: any) => any // eslint-disable-line @typescript-eslint/no-explicit-any
): Promise<{ rows: LedgerViewRow[] } | { error: string }> {
  const q = build(db.from("v_ledger_posted").select(COLUMNS)).limit(LINE_LIMIT);
  const { data, error } = await q;
  if (error) return { error: error.message as string };
  const rows = (data ?? []) as LedgerViewRow[];
  if (rows.length >= LINE_LIMIT) {
    return { error: "มีรายการมากเกินกว่าจะอ่านครบในครั้งเดียว — ปฏิเสธแทนที่จะแสดงยอดค้างที่อาจไม่ครบ" };
  }
  return { rows };
}

/**
 * ยอดค้างทั้งหมด + ประวัติการล้างจริง จาก DB — ใช้ทั้งหน้า "ยืนยันรับ-จ่าย" และตอนกดยืนยัน
 * (`onlySourceId` = อ่านเฉพาะรายการเดียว สำหรับตอนกดยืนยัน: ประวัติต้องสดจาก DB เสมอ ไม่เชื่อสิ่งที่ browser ส่งมา)
 */
export async function readPendingAccruals(
  db: Db,
  coaCodeById: Record<string, string>,
  onlySourceId?: string
): Promise<{ ok: true; items: PendingAccrual[] } | { ok: false; error: string }> {
  const [cand, clr, rev] = await Promise.all([
    fetchRows(db, (q) => (onlySourceId ? q.eq("transaction_id", onlySourceId) : q.is("cash_date", null))),
    fetchRows(db, (q) => q.like("source_ref", onlySourceId ? `${onlySourceId}-clr-%` : "%-clr-%")),
    fetchRows(db, (q) => q.not("reverses_id", "is", null)),
  ]);
  for (const r of [cand, clr, rev]) if ("error" in r) return { ok: false, error: `อ่านยอดค้างไม่สำเร็จ (${r.error})` };
  const c = cand as { rows: LedgerViewRow[] };
  const k = clr as { rows: LedgerViewRow[] };
  const v = rev as { rows: LedgerViewRow[] };
  return {
    ok: true,
    items: derivePendingAccruals({ candidates: c.rows, clearings: k.rows, reversals: v.rows }, coaCodeById),
  };
}

export async function loadPendingAccruals(): Promise<PendingAccrualsState> {
  const refState = await loadReference();
  if (!refState.ok) return { ok: false, error: refState.error };
  let supabase;
  try {
    supabase = await createClient();
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
  const r = await readPendingAccruals(supabase, refState.ref.coaCodeById);
  if (!r.ok) return r;
  return {
    ok: true,
    pending: r.items.filter((p) => p.outstanding > 0),
    clearedIds: r.items.filter((p) => p.outstanding <= 0).map((p) => p.id),
  };
}
