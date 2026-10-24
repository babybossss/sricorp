import type { SupabaseClient } from "@supabase/supabase-js";
import { createClient } from "@/lib/supabase/server";
import { loadReference } from "./reference";
import type { LedgerViewRow } from "./ledger-entries";
import { fetchAllPages } from "./paged";
import { accrualAccountCodes, derivePendingAccruals, type PendingAccrual } from "./pending-accruals";

/** คอลัมน์ของ `v_ledger_posted` ที่ต้องใช้ — เขียนชื่อตรงๆ ไม่ใช้ `*` (คอลัมน์ใหม่ต้องไม่ไหลเข้าเองเงียบๆ) */
const COLUMNS =
  "transaction_id, owner_id, txn_type_code, doc_date, cash_date, doc_no, txn_asset_id, contact_id, " +
  "counter_owner_id, intercompany_nature, txn_memo, attachments, source, source_ref, reverses_id, created_at, " +
  "line_id, coa_id, bank_account_id, debit, credit, cf_category, line_asset_id, line_memo";

export type PendingAccrualsState =
  | { ok: true; pending: PendingAccrual[]; clearedIds: string[] }
  | { ok: false; error: string };

type Db = Pick<SupabaseClient, "from">;

/**
 * อ่านทุกหน้าจาก `v_ledger_posted` เท่านั้น (D-107) — แบ่งหน้าเพราะ PostgREST ตัดที่ 1,000 แถวเงียบๆ
 * (เดิมใช้ `.limit(5000)` ซึ่งได้แค่ 1,000 โดยไม่มี error → ยอดค้างและประวัติการล้างขาด)
 */
async function fetchRows(
  db: Db,
  build: (q: any) => any // eslint-disable-line @typescript-eslint/no-explicit-any
): Promise<{ rows: LedgerViewRow[] } | { error: string }> {
  const r = await fetchAllPages<LedgerViewRow>(() =>
    build(db.from("v_ledger_posted").select(COLUMNS)).order("line_id", { ascending: true })
  );
  return r.ok ? { rows: r.rows } : { error: r.error };
}

/**
 * ยอดค้างทั้งหมด + ประวัติการล้างจริง + ยอดคงเหลือจริงของบัญชีพัก จาก DB
 *
 * อ่านทุกต้นทางเสมอ แม้ตอนกดยืนยันรายการเดียว: การตัดสินว่าต้นทางไหนถูกลดนอกแท็บ (FIFO ต่อผู้ถือ+บัญชีพัก)
 * ต้องเห็นต้นทางข้างเคียงทั้งหมด ถ้าอ่านเฉพาะใบเดียวจะไม่รู้ยอดรวมของกลุ่ม
 */
export async function readPendingAccruals(
  db: Db,
  coaCodeById: Record<string, string>
): Promise<{ ok: true; items: PendingAccrual[] } | { ok: false; error: string }> {
  const accountIds = Object.entries(coaCodeById)
    .filter(([, code]) => accrualAccountCodes().includes(code))
    .map(([id]) => id);
  if (accountIds.length === 0) {
    return { ok: false, error: "หา id ของบัญชีลูกหนี้/เจ้าหนี้ในผังบัญชีไม่เจอ — ปฏิเสธแทนที่จะแสดงยอดค้างที่ตรวจกับยอดจริงไม่ได้" };
  }
  const [cand, clr, rev, acc] = await Promise.all([
    fetchRows(db, (q) => q.is("cash_date", null)),
    fetchRows(db, (q) => q.like("source_ref", "%-clr-%")),
    fetchRows(db, (q) => q.not("reverses_id", "is", null)),
    fetchRows(db, (q) => q.in("coa_id", accountIds)),
  ]);
  for (const r of [cand, clr, rev, acc]) if ("error" in r) return { ok: false, error: `อ่านยอดค้างไม่สำเร็จ (${r.error})` };
  const rows = (r: unknown) => (r as { rows: LedgerViewRow[] }).rows;
  return {
    ok: true,
    items: derivePendingAccruals(
      { candidates: rows(cand), clearings: rows(clr), reversals: rows(rev), accountLines: rows(acc) },
      coaCodeById
    ),
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
