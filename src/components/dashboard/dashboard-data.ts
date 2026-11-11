import { createClient } from "@/lib/supabase/server";
import { getAccess } from "@/lib/auth/session";
import { loadReference } from "@/lib/db/reference";
import { fetchAllPages } from "@/lib/db/paged";
import { toStmtLines, ownersInView, parseFiscalYear, type StatementViewRow, type StmtLine } from "@/lib/db/statements";
import { readPendingAccruals } from "@/lib/db/pending-accruals-server";
import type { PendingAccrual } from "@/lib/db/pending-accruals";
import type { Reference } from "@/lib/db/reference-types";
import { dmyToIso, isoToDmy, todayDmy } from "@/lib/format";
import { buildDashboard, buildTodos, daysBetween, type ContractDue, type DashboardFigures, type Todo } from "./dashboard-model";

/**
 * อ่านข้อมูลหน้าแรกจาก DB จริง — **ฝั่ง server เท่านั้น** (session ผู้ใช้ · ผ่าน RLS)
 *
 *  - สมุด: `v_ledger_posted` ผ่าน `fetchAllPages` (ไม่อ่านตารางฐาน · ไม่ตัดที่ 1,000 แถวเงียบๆ)
 *  - ผู้ที่ไม่มี `ledger.read` ไม่ถูกถามสมุด (RLS จะคืน 0 แถว และ 0 ที่มาจากการมองไม่เห็นหลอกคนอ่านว่าไม่มีเงิน)
 *  - ล้มเหลวสักส่วน = `{ ok:false }` พร้อมเหตุผล ไม่แสดงตัวเลขครึ่งเดียว
 *  - ไม่มีตัวเลขที่เก็บไว้ — คำนวณใหม่ทุกครั้งที่เปิดหน้า
 */
type Db = Awaited<ReturnType<typeof createClient>>;

const STMT_COLUMNS =
  "line_id, transaction_id, owner_id, txn_type_code, doc_date, cash_date, source, counter_owner_id, " +
  "intercompany_nature, coa_id, debit, credit, cf_category, currency";

/** สัญญาที่ครบกำหนดภายในกี่วันถึงจะขึ้นเป็นงานที่ต้องทำ (ที่เลยกำหนดแล้วแต่ยังเปิดอยู่ขึ้นเสมอ) */
export const CONTRACT_HORIZON_DAYS = 90;

export type DashboardData =
  | {
      ok: true;
      ledgerAccess: boolean;
      figures: DashboardFigures | null;
      todos: Todo[];
      /** ร่างรออนุมัติในมุมมองที่เลือก (0 และ canSeeApprovals=false เมื่อผู้ดูไม่มีสิทธิ์อนุมัติ) */
      pendingApprovals: { count: number; total: number };
      canSeeApprovals: boolean;
      contractsDue: ContractDue[];
      owners: Reference["owners"];
      view: string;
      year: number;
      years: number[];
      today: string;
    }
  | { ok: false; error: string };

const CONTRACT_KIND: Record<string, string> = {
  lease: "สัญญาเช่า",
  sale_leaseback: "สัญญาขายฝาก",
  mortgage: "สัญญาจำนอง",
  loan_payable: "สัญญากู้ยืม",
  loan_receivable: "สัญญาให้กู้ยืม",
  service: "สัญญาบริการ",
};

type ContractRow = { id: string; type: string; asset_id: string | null; owner_id: string; end_date: string | null; redemption_deadline: string | null; status: string };

export async function loadDashboardFrom(
  db: Db,
  ref: Reference,
  opts: { ownerParam: string | null; year: number | null; today: string; ledgerAccess: boolean; canSeeApprovals: boolean }
): Promise<DashboardData> {
  const allIds = ref.owners.map((o) => o.id);
  const view = opts.ownerParam && allIds.includes(opts.ownerParam) ? opts.ownerParam : "family";
  const ownerIds = ownersInView(view, allIds);
  const thisYear = Number(opts.today.slice(0, 4));
  const year = opts.year ?? thisYear;

  // ---- งานที่ต้องทำ: ร่างรออนุมัติ · สัญญาใกล้ครบ · ราคาประเมินเก่า ----
  let pendingApprovals = { count: 0, total: 0 };
  if (opts.canSeeApprovals) {
    const d = await fetchAllPages<{ owner_id: string; amount: number | string }>(
      () => db.from("draft_entries").select("owner_id, amount").eq("status", "pending").order("id", { ascending: true }) as never
    );
    if (!d.ok) return { ok: false, error: `อ่านคิวอนุมัติไม่สำเร็จ (${d.error})` };
    const mine = d.rows.filter((r) => ownerIds.includes(r.owner_id));
    pendingApprovals = { count: mine.length, total: mine.reduce((t, r) => t + Math.round(Number(r.amount) * 100), 0) / 100 };
  }

  const cutoff = new Date(Date.parse(`${opts.today}T00:00:00Z`) + CONTRACT_HORIZON_DAYS * 86_400_000).toISOString().slice(0, 10);
  const con = await fetchAllPages<ContractRow>(
    () =>
      db
        .from("contracts")
        .select("id, type, asset_id, owner_id, end_date, redemption_deadline, status")
        .eq("status", "active")
        .order("id", { ascending: true }) as never
  );
  if (!con.ok) return { ok: false, error: `อ่านสัญญาไม่สำเร็จ (${con.error})` };
  const assetName = new Map(ref.assets.map((a) => [a.id, a.name]));
  const contractsDue: ContractDue[] = con.rows
    .filter((c) => ownerIds.includes(c.owner_id))
    .flatMap((c) => {
      // ขายฝากนับกำหนดไถ่ถอน · อื่นๆ นับวันสิ้นสุดสัญญา — ไม่มีวันที่ = ไม่ขึ้น (ไม่เดา)
      const date = c.type === "sale_leaseback" ? (c.redemption_deadline ?? c.end_date) : c.end_date;
      if (!date || date > cutoff) return [];
      return [{ id: c.id, kind: CONTRACT_KIND[c.type] ?? c.type, assetName: c.asset_id ? (assetName.get(c.asset_id) ?? null) : null, date: isoToDmy(date), daysLeft: daysBetween(opts.today, date) }];
    })
    .sort((a, b) => a.daysLeft - b.daysLeft);

  const stale = await fetchAllPages<{ asset_id: string; is_stale: boolean | null }>(
    () => db.from("v_asset_latest_value").select("asset_id, is_stale").eq("is_stale", true).order("asset_id", { ascending: true }) as never
  );
  if (!stale.ok) return { ok: false, error: `อ่านราคาประเมินไม่สำเร็จ (${stale.error})` };
  const assetOwner = new Map(ref.assets.map((a) => [a.id, a.ownerId]));
  const staleValuations = stale.rows.filter((r) => ownerIds.includes(assetOwner.get(r.asset_id) ?? "")).length;

  // ---- ตัวเลขการเงิน: ต้องอ่านสมุดได้ ----
  let figures: DashboardFigures | null = null;
  let aged = { count: 0, total: 0 };
  let years: number[] = [thisYear];
  if (opts.ledgerAccess) {
    const rows = await fetchAllPages<StatementViewRow>(
      () => db.from("v_ledger_posted").select(STMT_COLUMNS).order("line_id", { ascending: true }) as never,
      { maxRows: 200_000 }
    );
    if (!rows.ok) return { ok: false, error: `อ่านสมุดบัญชีไม่สำเร็จ (${rows.error})` };
    const lines: StmtLine[] = toStmtLines(rows.rows, ref.coaCodeById);
    const acc = await readPendingAccruals(db, ref.coaCodeById);
    if (!acc.ok) return { ok: false, error: acc.error };
    const pending: PendingAccrual[] = acc.items;
    figures = buildDashboard({ lines, ownerIds, year, pending, today: opts.today });
    for (const side of [figures.receivable, figures.payable]) {
      const old = side.buckets.filter((b) => b.key !== "d30");
      aged = { count: aged.count + old.reduce((t, b) => t + b.count, 0), total: aged.total + old.reduce((t, b) => t + Math.round(b.amount * 100), 0) / 100 };
    }
    const first = lines.reduce((m, l) => Math.min(m, Number(l.docDate.slice(0, 4))), thisYear);
    years = Array.from({ length: Math.max(thisYear, year) - Math.min(first, year) + 1 }, (_, i) => Math.max(thisYear, year) - i);
  }

  const todos = buildTodos({
    pendingApprovals,
    agedAccruals: aged,
    contractsDue,
    staleValuations,
    canSeeApprovals: opts.canSeeApprovals,
  });

  return { ok: true, ledgerAccess: opts.ledgerAccess, figures, todos, pendingApprovals, canSeeApprovals: opts.canSeeApprovals, contractsDue, owners: ref.owners, view, year, years, today: opts.today };
}

export async function loadDashboard(sp: { owner?: string; year?: string }): Promise<DashboardData> {
  const refState = await loadReference();
  if (!refState.ok) return { ok: false, error: refState.error };
  let db: Db;
  try {
    db = await createClient();
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
  const access = await getAccess();
  return loadDashboardFrom(db, refState.ref, {
    ownerParam: sp.owner ?? null,
    year: parseFiscalYear(sp.year),
    today: dmyToIso(todayDmy()) ?? "",
    ledgerAccess: access.permissions.has("ledger.read"),
    canSeeApprovals: access.permissions.has("ledger.approve"),
  });
}
