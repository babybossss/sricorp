import { createClient } from "@/lib/supabase/server";
import { loadReference } from "./reference";
import { fetchAllPages } from "./paged";
import { toApprovalItem, type ApprovalItem, type DraftEntryRow } from "./approvals-model";
import { contactFullName, type Reference, type RefOwner } from "./reference-types";

/**
 * คิวอนุมัติจาก `sri_os.draft_entries` จริง — **ฝั่ง server เท่านั้น** (session ผู้ใช้ · ผ่าน RLS `draft_entries_by_owner`)
 *
 * - อ่านเฉพาะ `status = 'pending'` · ร่างที่อนุมัติ/ปฏิเสธแล้วไม่อยู่ในคิว
 * - ใครเห็นร่างไหน ให้ RLS ตัดสิน (ledger.read เห็นทั้งขอบเขตผู้ถือ · draft.read_own เห็นของตัวเอง) ไม่กรองสิทธิ์ใน TS
 * - ผ่าน `fetchAllPages` (PostgREST ตัดผลที่ 1,000 แถวเงียบๆ) · ล้มเหลว = `{ ok:false }` ไม่แสดงคิวครึ่งเดียว
 * - **ไม่มียอดสรุปที่เก็บไว้** — ยอดรวมของคิวคำนวณจากแถวตอนแสดงทุกครั้ง
 */
type Db = Awaited<ReturnType<typeof createClient>>;

const COLUMNS =
  "id, owner_id, txn_type_code, doc_date, cash_date, amount, asset_id, contact_id, contract_id, memo, attachments, status, reject_reason, due_date, source, source_ref, posted_txn_id, created_by, reviewed_by, reviewed_at, created_at";

export type ApprovalData =
  | {
      ok: true;
      items: ApprovalItem[];
      owners: RefOwner[];
      assetNames: Record<string, string>;
      contactNames: Record<string, string>;
    }
  | { ok: false; error: string };

export async function loadApprovalsFrom(db: Db, ref: Reference): Promise<ApprovalData> {
  const fetched = await fetchAllPages<DraftEntryRow>(
    () =>
      db
        .from("draft_entries")
        .select(COLUMNS)
        .eq("status", "pending")
        .order("created_at", { ascending: true })
        .order("id", { ascending: true }) as never
  );
  if (!fetched.ok) return { ok: false, error: `อ่านคิวอนุมัติจากฐานข้อมูลไม่สำเร็จ (${fetched.error})` };

  const ids = [...new Set(fetched.rows.map((r) => r.created_by).filter((x): x is string => !!x))];
  const names = new Map<string, string>();
  for (let i = 0; i < ids.length; i += 100) {
    const { data, error } = await db.from("app_users").select("id, display_name").in("id", ids.slice(i, i + 100));
    if (error) return { ok: false, error: `อ่านชื่อผู้สร้างร่างไม่สำเร็จ (${error.message})` };
    for (const u of (data ?? []) as { id: string; display_name: string }[]) names.set(u.id, u.display_name);
  }
  // หาชื่อไม่เจอ = บอกตามจริง ไม่ใช้ id ดิบและไม่เดา
  const nameOf = (id: string) => names.get(id) ?? "ไม่ทราบชื่อผู้ใช้";

  return {
    ok: true,
    items: fetched.rows.map((r) => toApprovalItem(r, nameOf)),
    owners: ref.owners,
    assetNames: Object.fromEntries(ref.assets.map((a) => [a.id, `${a.name} (${a.code})`])),
    contactNames: Object.fromEntries(ref.contacts.map((c) => [c.id, contactFullName(c)])),
  };
}

export async function loadApprovals(): Promise<ApprovalData> {
  const refState = await loadReference();
  if (!refState.ok) return { ok: false, error: refState.error };
  let db: Db;
  try {
    db = await createClient();
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
  return loadApprovalsFrom(db, refState.ref);
}
