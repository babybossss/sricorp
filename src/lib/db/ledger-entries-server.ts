import { createClient } from "@/lib/supabase/server";
import { loadReference } from "./reference";
import { groupLedgerRows, type LedgerEntry, type LedgerViewRow } from "./ledger-entries";

/** เพดานบรรทัดที่อ่านต่อครั้ง (ประมาณ 300-500 รายการ) — เกินแล้วบอกผู้ใช้ ไม่ตัดเงียบ */
export const LEDGER_LINE_LIMIT = 2000;

export type LedgerListState =
  | { ok: true; entries: LedgerEntry[]; truncated: boolean }
  | { ok: false; error: string };

/**
 * อ่านสมุดบัญชีล่าสุดจาก `v_ledger_posted` (ผ่าน RLS ของผู้ใช้) — ห้ามอ่าน `transactions` ตรง
 * ล้มเหลว = คืนเหตุผล ไม่ตกกลับไปใช้ข้อมูลจำลอง
 */
export async function loadLedgerEntries(): Promise<LedgerListState> {
  const refState = await loadReference();
  if (!refState.ok) return { ok: false, error: refState.error };

  let supabase;
  try {
    supabase = await createClient();
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }

  const { data, error } = await supabase
    .from("v_ledger_posted")
    .select(
      "transaction_id, owner_id, txn_type_code, doc_date, cash_date, doc_no, txn_asset_id, contact_id, " +
        "counter_owner_id, intercompany_nature, txn_memo, attachments, source, reverses_id, created_at, " +
        "coa_id, bank_account_id, debit, credit, cf_category, line_asset_id, line_memo"
    )
    .order("doc_date", { ascending: false })
    .order("created_at", { ascending: false })
    .order("transaction_id", { ascending: true })
    .order("debit", { ascending: false })
    .limit(LEDGER_LINE_LIMIT);

  if (error) return { ok: false, error: `อ่านสมุดบัญชีไม่สำเร็จ (${error.message})` };

  const rows = (data ?? []) as unknown as LedgerViewRow[];
  const truncated = rows.length >= LEDGER_LINE_LIMIT;
  return { ok: true, entries: groupLedgerRows(rows, refState.ref.coaCodeById, truncated), truncated };
}
