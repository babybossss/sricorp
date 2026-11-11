import { createClient } from "@/lib/supabase/server";
import { loadReference } from "./reference";
import { fetchAllPages } from "./paged";
import {
  groupLedgerRows,
  groupVoidedRows,
  type LedgerPeriod,
  type LedgerEntry,
  type LedgerViewRow,
  type VoidedEntry,
  type VoidedViewRow,
} from "./ledger-entries";

/** เพดานบรรทัดที่อ่านต่อครั้ง (ประมาณ 300-500 รายการ) — เกินแล้วบอกผู้ใช้ ไม่ตัดเงียบ */
export const LEDGER_LINE_LIMIT = 2000;

export type LedgerListState =
  | { ok: true; entries: LedgerEntry[]; truncated: boolean }
  | { ok: false; error: string };

/**
 * อ่านสมุดบัญชีในช่วงที่เลือกจาก `v_ledger_posted` (ผ่าน RLS ของผู้ใช้) — ห้ามอ่าน `transactions` ตรง
 * ล้มเหลว = คืนเหตุผล ไม่ตกกลับไปใช้ข้อมูลจำลอง
 */
export async function loadLedgerEntries(period: LedgerPeriod): Promise<LedgerListState> {
  const refState = await loadReference();
  if (!refState.ok) return { ok: false, error: refState.error };

  let supabase;
  try {
    supabase = await createClient();
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }

  const fetched = await fetchAllPages<LedgerViewRow>(
    () =>
      supabase
        .from("v_ledger_posted")
        .select(
          "transaction_id, owner_id, txn_type_code, doc_date, cash_date, doc_no, txn_asset_id, contact_id, " +
            "counter_owner_id, intercompany_nature, txn_memo, attachments, source, source_ref, reverses_id, created_at, " +
            "coa_id, bank_account_id, debit, credit, cf_category, line_asset_id, line_memo"
        )
        // กรองตามวันที่เอกสาร (ดูเหตุผลที่ ledgerPeriod) · เรียงใหม่→เก่า เพดานจึงตัดฝั่งเก่าของช่วงนั้น
        .gte("doc_date", period.start)
        .lte("doc_date", period.end)
        .order("doc_date", { ascending: false })
        .order("created_at", { ascending: false })
        .order("transaction_id", { ascending: true })
        .order("debit", { ascending: false })
        .order("line_id", { ascending: true }) as never,
    { stopAfter: LEDGER_LINE_LIMIT }
  );
  if (!fetched.ok) return { ok: false, error: `อ่านสมุดบัญชีไม่สำเร็จ (${fetched.error})` };

  const rows = fetched.rows;
  const truncated = fetched.truncated;
  return { ok: true, entries: groupLedgerRows(rows, refState.ref.coaCodeById, truncated), truncated };
}

export type VoidedListState =
  | { ok: true; entries: VoidedEntry[]; truncated: boolean }
  | { ok: false; error: string };

/**
 * รายการที่ยกเลิก (void) ในช่วงที่เลือก — อ่านจาก `v_ledger_voided` เท่านั้น
 *
 * D-098 บังคับว่าใบที่ยกเลิกต้อง **ยังเห็นได้** และอยู่ **แยกที่** จากสมุดปกติ
 * วิวแยกให้แล้ว ฟังก์ชันนี้คือฝั่งที่ทำให้มัน "เห็นได้" จริง
 * ล้มเหลว = คืนเหตุผล ไม่ตกกลับไปใช้ข้อมูลจำลอง (เหมือน `loadLedgerEntries`)
 */
export async function loadVoidedEntries(period: LedgerPeriod): Promise<VoidedListState> {
  const refState = await loadReference();
  if (!refState.ok) return { ok: false, error: refState.error };

  let supabase;
  try {
    supabase = await createClient();
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }

  const fetched = await fetchAllPages<VoidedViewRow>(
    () =>
      supabase
        .from("v_ledger_voided")
        .select(
          "transaction_id, owner_id, txn_type_code, doc_date, cash_date, doc_no, txn_asset_id, contact_id, " +
            "counter_owner_id, intercompany_nature, txn_memo, attachments, source, source_ref, reverses_id, created_at, " +
            "voided_at, voided_by, void_reason, " +
            "coa_id, bank_account_id, debit, credit, cf_category, line_asset_id, line_memo"
        )
        .gte("doc_date", period.start)
        .lte("doc_date", period.end)
        .order("voided_at", { ascending: false })
        .order("transaction_id", { ascending: true })
        .order("line_id", { ascending: true }) as never,
    { stopAfter: LEDGER_LINE_LIMIT }
  );
  if (!fetched.ok) return { ok: false, error: `อ่านรายการที่ยกเลิกไม่สำเร็จ (${fetched.error})` };

  // ชื่อผู้ยกเลิก — อ่านไม่ได้ (สิทธิ์/ขอบเขต) ก็ยังแสดงรายการได้ แต่ **ห้ามโชว์ uuid**
  // (แพทเทิร์นเดียวกับชื่อผู้สร้างร่างใน `assets-server.ts`)
  const ids = [...new Set(fetched.rows.map((r) => r.voided_by).filter((x): x is string => !!x))];
  const names = new Map<string, string>();
  for (let i = 0; i < ids.length; i += 100) {
    const { data } = await supabase.from("app_users").select("id, display_name").in("id", ids.slice(i, i + 100));
    for (const u of (data ?? []) as { id: string; display_name: string }[]) names.set(u.id, u.display_name);
  }

  return {
    ok: true,
    entries: groupVoidedRows(fetched.rows, refState.ref.coaCodeById, fetched.truncated, (id) => names.get(id) ?? null),
    truncated: fetched.truncated,
  };
}
