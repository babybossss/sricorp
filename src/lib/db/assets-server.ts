import { createClient } from "@/lib/supabase/server";
import { getAccess } from "@/lib/auth/session";
import { loadReference } from "./reference";
import { fetchAllPages } from "./paged";
import type { Reference, RefOwner } from "./reference-types";
import {
  buildAssetReports,
  linesOfAsset,
  toAssetLedgerLines,
  toAssetRow,
  toAssetView,
  toDraftView,
  type AssetLedgerLine,
  type AssetLedgerViewRow,
  type AssetReport,
  type AssetView,
  type AssetVisibleRow,
  type CategoryRow,
  type ClassRow,
  type DraftDbRow,
  type DraftView,
  type LatestValue,
  type Taxonomy,
  type ValuationRow,
} from "./assets-model";

/**
 * ตัวอ่านทะเบียนทรัพย์จาก `sri_os` จริง — **ฝั่ง server เท่านั้น** (ใช้ session ของผู้ใช้ ผ่าน RLS)
 *
 * หลักที่ตั้งใจ (อ่านก่อนแก้):
 *  - **ใครเห็นทรัพย์ไหน ให้ DB ตัดสิน** — อ่านทรัพย์ผ่าน `fn_assets_visible()` ไม่มีเงื่อนไขกรองสิทธิ์ใน TS
 *    ช่องที่ผู้ดูไม่มีสิทธิ์เห็น DB คืน null มาเอง
 *  - **ไม่มีตัวเลขที่เก็บไว้** (D-113) — ต้นทุนมาจาก `fn_asset_cost_basis()` ทุกครั้ง ค่าปรับปรุง/ค่าซ่อม/รายได้
 *    รวมจาก `v_ledger_posted` ทุกครั้ง · ไม่อ่านตารางฐาน `transactions` (D-107)
 *  - **ทุก query แบบรายการอ่านผ่าน `fetchAllPages`** (PostgREST ตัดผลที่ 1,000 แถวเงียบๆ)
 *  - ล้มเหลว = `{ ok: false, error }` พร้อมเหตุผล **ไม่แสดงตัวเลขครึ่งเดียว** และไม่ตกไปใช้ข้อมูลจำลอง
 *  - ผู้ที่ไม่มี `ledger.read` ไม่ถูกถามตัวเลขเงินเลย (`reports = null`) — หน้าจอต้องบอกว่า "ไม่มีสิทธิ์ดู"
 *    ไม่ใช่แสดง 0 (RLS จะคืน 0 แถวให้อยู่แล้ว และ 0 ที่มาจากการมองไม่เห็นหลอกคนอ่านว่าทรัพย์ไม่มีต้นทุน)
 */

type Db = Awaited<ReturnType<typeof createClient>>;

const ASSET_LINE_COLUMNS =
  "line_id, transaction_id, owner_id, txn_type_code, doc_date, source, coa_id, debit, credit, line_asset_id, txn_asset_id";

const COST_CONCURRENCY = 8;

export type RegisterData = {
  ok: true;
  assets: AssetView[];
  taxonomy: Taxonomy;
  owners: RefOwner[];
  /** ผู้ดูอ่านสมุดได้ (`ledger.read`) — false = ตัวเลขเงินทุกช่องต้องขึ้นว่าไม่มีสิทธิ์ดู */
  ledgerAccess: boolean;
  /** null = ไม่มีสิทธิ์อ่านสมุด */
  reports: Record<string, AssetReport> | null;
  unclassifiedLines: number;
  values: Record<string, LatestValue>;
  drafts: DraftView[];
};

export type RegisterResult = RegisterData | { ok: false; error: string };

type Fail = { ok: false; error: string };
const fail = (what: string, message: string): Fail => ({ ok: false, error: `อ่าน${what}จากฐานข้อมูลไม่สำเร็จ (${message})` });

/** รันทีละไม่เกิน n งานพร้อมกัน — คงลำดับผลลัพธ์ตามอินพุต */
export async function mapLimit<T, R>(items: readonly T[], n: number, fn: (x: T) => Promise<R>): Promise<R[]> {
  const out = new Array<R>(items.length);
  let next = 0;
  const worker = async () => {
    for (;;) {
      const i = next++;
      if (i >= items.length) return;
      out[i] = await fn(items[i]);
    }
  };
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, worker));
  return out;
}

/** ต้นทุนรวมของแต่ละทรัพย์จาก DB (`fn_asset_cost_basis`) — ล้มสักชิ้น = ล้มทั้งชุด ไม่คืนชุดที่ไม่ครบ */
async function loadCosts(db: Db, assetIds: readonly string[]): Promise<{ ok: true; costs: Record<string, number> } | Fail> {
  const results = await mapLimit(assetIds, COST_CONCURRENCY, async (id) => {
    const { data, error } = await db.rpc("fn_asset_cost_basis", { p_asset: id });
    return { id, data: data as number | string | null, error };
  });
  const bad = results.find((r) => r.error || r.data === null || r.data === undefined);
  if (bad) return fail("ต้นทุนทรัพย์", bad.error?.message ?? `ไม่ได้ค่าต้นทุนของทรัพย์ ${bad.id}`);
  return { ok: true, costs: Object.fromEntries(results.map((r) => [r.id, Number(r.data)])) };
}

export async function loadTaxonomy(db: Db): Promise<{ ok: true; taxonomy: Taxonomy } | Fail> {
  const [cls, cat] = await Promise.all([
    db.from("asset_classes").select("id, code, name_th, sort_order").order("sort_order", { ascending: true }),
    db.from("asset_categories").select("id, class_id, code, name_th, is_active, sort_order").order("sort_order", { ascending: true }),
  ]);
  if (cls.error) return fail("หมวดใหญ่ของทรัพย์", cls.error.message);
  if (cat.error) return fail("หมวดย่อยของทรัพย์", cat.error.message);
  const classes: ClassRow[] = ((cls.data ?? []) as { id: string; code: string; name_th: string; sort_order: number }[]).map((c) => ({
    id: c.id,
    code: c.code,
    nameTh: c.name_th,
    sortOrder: c.sort_order,
  }));
  const categories: CategoryRow[] = (
    (cat.data ?? []) as { id: string; class_id: string; code: string; name_th: string; is_active: boolean; sort_order: number }[]
  ).map((c) => ({ id: c.id, classId: c.class_id, code: c.code, nameTh: c.name_th, isActive: c.is_active, sortOrder: c.sort_order }));
  return { ok: true, taxonomy: { classes, categories } };
}

export async function loadAssets(db: Db, tax: Taxonomy, filterId?: string): Promise<{ ok: true; assets: AssetView[] } | Fail> {
  const fetched = await fetchAllPages<AssetVisibleRow>(() => {
    let q = db.rpc("fn_assets_visible");
    if (filterId) q = q.eq("id", filterId);
    return q.order("created_at", { ascending: true }).order("id", { ascending: true }) as never;
  });
  if (!fetched.ok) return fail("ทะเบียนทรัพย์", fetched.error);
  return { ok: true, assets: fetched.rows.map((r) => toAssetView(toAssetRow(r), tax)) };
}

type LatestRow = { asset_id: string; as_of: string | null; method: string | null; value: number | string | null; is_stale: boolean | null };

async function loadLatestValues(db: Db, filterId?: string): Promise<{ ok: true; values: Record<string, LatestValue> } | Fail> {
  const fetched = await fetchAllPages<LatestRow>(() => {
    let q = db.from("v_asset_latest_value").select("asset_id, as_of, method, value, is_stale");
    if (filterId) q = q.eq("asset_id", filterId);
    return q.order("asset_id", { ascending: true }) as never;
  });
  if (!fetched.ok) return fail("มูลค่าล่าสุด", fetched.error);
  const values: Record<string, LatestValue> = {};
  for (const r of fetched.rows)
    values[r.asset_id] = {
      assetId: r.asset_id,
      value: r.value === null || r.value === undefined ? null : Number(r.value),
      asOf: r.as_of,
      method: r.method,
      isStale: r.is_stale === true,
    };
  return { ok: true, values };
}

async function loadDrafts(db: Db, targetAssetId?: string): Promise<{ ok: true; drafts: DraftView[] } | Fail> {
  const fetched = await fetchAllPages<DraftDbRow>(() => {
    let q = db
      .from("asset_drafts")
      .select(
        "id, kind, target_asset_id, owner_id, name, class_id, category_id, patch, note, status, reject_reason, applied_asset_id, created_by, reviewed_by, reviewed_at, created_at"
      );
    if (targetAssetId) q = q.eq("target_asset_id", targetAssetId);
    return q.order("created_at", { ascending: true }).order("id", { ascending: true }) as never;
  });
  if (!fetched.ok) return fail("ร่างทะเบียนทรัพย์", fetched.error);

  const ids = [...new Set(fetched.rows.flatMap((r) => [r.created_by, r.reviewed_by].filter((x): x is string => !!x)))];
  const names = new Map<string, string>();
  for (let i = 0; i < ids.length; i += 100) {
    const { data, error } = await db.from("app_users").select("id, display_name").in("id", ids.slice(i, i + 100));
    if (error) return fail("ชื่อผู้สร้างร่าง", error.message);
    for (const u of (data ?? []) as { id: string; display_name: string }[]) names.set(u.id, u.display_name);
  }
  // หาชื่อไม่เจอ = แสดงตามจริงว่าไม่ทราบ (ผู้ใช้ที่ปิดใช้งาน/มองไม่เห็น) ไม่เดาและไม่ใช้ id ดิบ
  const nameOf = (id: string) => names.get(id) ?? "ไม่ทราบชื่อผู้ใช้";
  return { ok: true, drafts: fetched.rows.map((r) => toDraftView(r, nameOf)) };
}

async function loadAssetLines(db: Db, coaCodeById: Reference["coaCodeById"], assetId?: string): Promise<{ ok: true; lines: AssetLedgerLine[] } | Fail> {
  const fetched = await fetchAllPages<AssetLedgerViewRow>(
    () => {
      const q = db.from("v_ledger_posted").select(ASSET_LINE_COLUMNS);
      const f = assetId ? q.or(`line_asset_id.eq.${assetId},txn_asset_id.eq.${assetId}`) : q.or("line_asset_id.not.is.null,txn_asset_id.not.is.null");
      return f.order("line_id", { ascending: true }) as never;
    },
    { maxRows: 300_000 }
  );
  if (!fetched.ok) return fail("สมุดบัญชีของทรัพย์", fetched.error);
  return { ok: true, lines: toAssetLedgerLines(fetched.rows, coaCodeById) };
}

/**
 * หน้ารวมทะเบียน — แยกจาก `loadAssetRegister()` เพื่อเทสต์กับ DB จำลองได้ (ส่ง client + ข้อมูลอ้างอิงเข้ามา)
 */
export async function loadRegisterFrom(db: Db, ref: Reference, opts: { ledgerAccess: boolean }): Promise<RegisterResult> {
  const tax = await loadTaxonomy(db);
  if (!tax.ok) return tax;
  const assets = await loadAssets(db, tax.taxonomy);
  if (!assets.ok) return assets;
  const values = await loadLatestValues(db);
  if (!values.ok) return values;
  const drafts = await loadDrafts(db);
  if (!drafts.ok) return drafts;

  let reports: Record<string, AssetReport> | null = null;
  let unclassifiedLines = 0;
  if (opts.ledgerAccess) {
    const costs = await loadCosts(db, assets.assets.map((a) => a.id));
    if (!costs.ok) return costs;
    const lines = await loadAssetLines(db, ref.coaCodeById);
    if (!lines.ok) return lines;
    const built = buildAssetReports(costs.costs, lines.lines);
    reports = built.reports;
    unclassifiedLines = built.unclassifiedLines;
  }

  return {
    ok: true,
    assets: assets.assets,
    taxonomy: tax.taxonomy,
    owners: ref.owners,
    ledgerAccess: opts.ledgerAccess,
    reports,
    unclassifiedLines,
    values: values.values,
    drafts: drafts.drafts,
  };
}

export async function loadAssetRegister(): Promise<RegisterResult> {
  const refState = await loadReference();
  if (!refState.ok) return { ok: false, error: refState.error };
  let db: Db;
  try {
    db = await createClient();
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
  const access = await getAccess();
  return loadRegisterFrom(db, refState.ref, { ledgerAccess: access.permissions.has("ledger.read") });
}

/* ------------------------------------------------------------------ *
 * หน้ารายละเอียดทรัพย์ชิ้นเดียว
 * ------------------------------------------------------------------ */

export type ContractView = {
  id: string;
  code: string | null;
  type: string;
  counterpartyContactId: string | null;
  principal: number | null;
  rate: number | null;
  ratePeriod: string | null;
  startDate: string | null;
  endDate: string | null;
  noticeWindowStart: string | null;
  noticeWindowEnd: string | null;
  redemptionDeadline: string | null;
  status: string;
};

export type DetailData = {
  ok: true;
  asset: AssetView;
  taxonomy: Taxonomy;
  owners: RefOwner[];
  ledgerAccess: boolean;
  report: AssetReport | null;
  unclassifiedLines: number;
  latest: LatestValue | null;
  valuations: ValuationRow[];
  contracts: ContractView[];
  /** บรรทัดสมุดที่นับให้ทรัพย์ชิ้นนี้ (ชุดเดียวกับที่รายงานรวม) — ว่างถ้าไม่มีสิทธิ์อ่านสมุด */
  lines: AssetLedgerLine[];
  pendingEditDrafts: number;
};
export type DetailResult = DetailData | { ok: true; asset: null } | Fail;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type ContractRow = {
  id: string; code: string | null; type: string; counterparty_contact_id: string | null; principal: number | string | null;
  rate: number | string | null; rate_period: string | null; start_date: string | null; end_date: string | null;
  notice_window_start: string | null; notice_window_end: string | null; redemption_deadline: string | null; status: string;
};
type ValuationDbRow = {
  id: string; asset_id: string; as_of: string; method: string; value: number | string | null; note: string | null;
  revision: number | null; created_at: string;
};

export async function loadDetailFrom(db: Db, ref: Reference, assetId: string, opts: { ledgerAccess: boolean }): Promise<DetailResult> {
  // id มาจาก URL และถูกต่อเข้าตัวกรอง .or() — ต้องเป็น uuid เท่านั้น ไม่งั้นเป็นช่องฉีดเงื่อนไขกรอง
  if (!UUID.test(assetId)) return { ok: true, asset: null };

  const tax = await loadTaxonomy(db);
  if (!tax.ok) return tax;
  const found = await loadAssets(db, tax.taxonomy, assetId);
  if (!found.ok) return found;
  // มองไม่เห็นกับไม่มีอยู่ตอบเหมือนกัน (RLS) — ไม่บอกว่ามีทรัพย์นี้อยู่
  const asset = found.assets.find((a) => a.id === assetId);
  if (!asset) return { ok: true, asset: null };

  const [latest, vals, cons, drafts] = await Promise.all([
    loadLatestValues(db, assetId),
    db
      .from("asset_valuations")
      .select("id, asset_id, as_of, method, value, note, revision, created_at")
      .eq("asset_id", assetId)
      .order("as_of", { ascending: false })
      .order("created_at", { ascending: false })
      .limit(100),
    db
      .from("contracts")
      .select("id, code, type, counterparty_contact_id, principal, rate, rate_period, start_date, end_date, notice_window_start, notice_window_end, redemption_deadline, status")
      .eq("asset_id", assetId)
      .order("start_date", { ascending: false }),
    loadDrafts(db, assetId),
  ]);
  if (!latest.ok) return latest;
  if (vals.error) return fail("ประวัติตีราคา", vals.error.message);
  if (cons.error) return fail("สัญญาของทรัพย์", cons.error.message);
  if (!drafts.ok) return drafts;

  let report: AssetReport | null = null;
  let lines: AssetLedgerLine[] = [];
  let unclassifiedLines = 0;
  if (opts.ledgerAccess) {
    const costs = await loadCosts(db, [assetId]);
    if (!costs.ok) return costs;
    const l = await loadAssetLines(db, ref.coaCodeById, assetId);
    if (!l.ok) return l;
    const built = buildAssetReports(costs.costs, l.lines);
    report = built.reports[assetId] ?? null;
    unclassifiedLines = built.unclassifiedLines;
    lines = linesOfAsset(assetId, l.lines);
  }

  return {
    ok: true,
    asset,
    taxonomy: tax.taxonomy,
    owners: ref.owners,
    ledgerAccess: opts.ledgerAccess,
    report,
    unclassifiedLines,
    latest: latest.values[assetId] ?? null,
    valuations: ((vals.data ?? []) as ValuationDbRow[]).map((v) => ({
      id: v.id,
      assetId: v.asset_id,
      asOf: v.as_of,
      method: v.method,
      value: v.value === null ? null : Number(v.value),
      note: v.note,
      revision: v.revision,
      createdAt: v.created_at,
    })),
    contracts: ((cons.data ?? []) as ContractRow[]).map((c) => ({
      id: c.id,
      code: c.code,
      type: c.type,
      counterpartyContactId: c.counterparty_contact_id,
      principal: c.principal === null ? null : Number(c.principal),
      rate: c.rate === null ? null : Number(c.rate),
      ratePeriod: c.rate_period,
      startDate: c.start_date,
      endDate: c.end_date,
      noticeWindowStart: c.notice_window_start,
      noticeWindowEnd: c.notice_window_end,
      redemptionDeadline: c.redemption_deadline,
      status: c.status,
    })),
    lines,
    pendingEditDrafts: drafts.drafts.filter((d) => d.status === "pending" && d.kind === "update").length,
  };
}

export async function loadAssetDetail(assetId: string): Promise<DetailResult> {
  const refState = await loadReference();
  if (!refState.ok) return { ok: false, error: refState.error };
  let db: Db;
  try {
    db = await createClient();
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
  const access = await getAccess();
  return loadDetailFrom(db, refState.ref, assetId, { ledgerAccess: access.permissions.has("ledger.read") });
}

/* ------------------------------------------------------------------ *
 * คิวร่าง + ข้อมูลที่ฟอร์มลงทะเบียนต้องใช้ (หมวด · ผู้ถือ) — หน้า /assets/drafts และ /assets/new
 * ------------------------------------------------------------------ */

export type DraftPageData = {
  ok: true;
  drafts: DraftView[];
  /** ทรัพย์ที่ผู้ดูเห็น (ไว้ชื่อ/เทียบของเดิมในร่างแก้ไข) */
  assets: AssetView[];
  taxonomy: Taxonomy;
  owners: RefOwner[];
};
export type DraftPageResult = DraftPageData | Fail;

export async function loadDraftPageFrom(db: Db, ref: Reference): Promise<DraftPageResult> {
  const tax = await loadTaxonomy(db);
  if (!tax.ok) return tax;
  const assets = await loadAssets(db, tax.taxonomy);
  if (!assets.ok) return assets;
  const drafts = await loadDrafts(db);
  if (!drafts.ok) return drafts;
  return { ok: true, drafts: drafts.drafts, assets: assets.assets, taxonomy: tax.taxonomy, owners: ref.owners };
}

export async function loadDraftPage(): Promise<DraftPageResult> {
  const refState = await loadReference();
  if (!refState.ok) return { ok: false, error: refState.error };
  let db: Db;
  try {
    db = await createClient();
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
  return loadDraftPageFrom(db, refState.ref);
}

/* ------------------------------------------------------------------ *
 * ฟอร์มลงทะเบียน — ต้องการแค่หมวดกับผู้ถือที่ใช้งานอยู่
 * ------------------------------------------------------------------ */

export type RegisterFormData = { ok: true; taxonomy: Taxonomy; owners: RefOwner[] } | Fail;

export async function loadRegisterForm(): Promise<RegisterFormData> {
  const refState = await loadReference();
  if (!refState.ok) return { ok: false, error: refState.error };
  let db: Db;
  try {
    db = await createClient();
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
  const tax = await loadTaxonomy(db);
  if (!tax.ok) return tax;
  // ผู้ถือที่ยังเป็น planned (นิติบุคคลที่ยังไม่จดทะเบียน) ลงทะเบียนทรัพย์ไม่ได้ — เหมือนตัวเลือกในฟอร์มบันทึกรายการ
  return { ok: true, taxonomy: tax.taxonomy, owners: refState.ref.owners.filter((o) => o.status === "active") };
}
