import { createClient } from "@/lib/supabase/server";
import { loadReference } from "./reference";
import { fetchAllPages } from "./paged";
import { toStmtLines, type StatementViewRow, type StmtLine } from "./statements";
import type { RefOwner } from "./reference-types";

/** คอลัมน์ของ `v_ledger_posted` ที่งบต้องใช้ — ระบุชื่อตรงๆ ไม่ใช้ `*` */
const COLUMNS =
  "line_id, transaction_id, owner_id, txn_type_code, doc_date, cash_date, source, counter_owner_id, " +
  "intercompany_nature, coa_id, debit, credit, cf_category, currency";

export type StatementData =
  | { ok: true; lines: StmtLine[]; owners: RefOwner[] }
  | { ok: false; error: string };

/**
 * อ่านบรรทัดที่ post แล้วทั้งหมดที่ผู้ใช้เห็น (ผ่าน RLS) จาก `v_ledger_posted` — **ห้ามอ่านตาราง `transactions` ตรง** (D-107)
 * งบแสดงฐานะการเงินและกระแสเงินสดต้องการประวัติทั้งหมดจนถึงสิ้นปี (ยอดสะสม · เงินสดต้นงวด)
 * ไม่ตัดแล้วบอกว่าครบ: เกินเพดานแถว = ปฏิเสธ
 */
export async function loadStatementData(): Promise<StatementData> {
  const refState = await loadReference();
  if (!refState.ok) return { ok: false, error: refState.error };

  let supabase;
  try {
    supabase = await createClient();
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }

  const fetched = await fetchAllPages<StatementViewRow>(
    () =>
      supabase.from("v_ledger_posted").select(COLUMNS).order("line_id", { ascending: true }) as never,
    { maxRows: 200_000 }
  );
  if (!fetched.ok) return { ok: false, error: `อ่านสมุดบัญชีไม่สำเร็จ (${fetched.error})` };

  return { ok: true, lines: toStmtLines(fetched.rows, refState.ref.coaCodeById), owners: refState.ref.owners };
}
