/**
 * DB จำลองสำหรับเทสต์หน้าทรัพย์ — **ไม่ใช่ Postgres**
 *
 * ห่อ `createFakeDb()` ของ server action (สมุดบัญชี + `fn_post_entry` จำลอง) แล้วเติมตารางของโมดูลทรัพย์
 * พร้อม **RLS จำลองตามนโยบายจริง** (`20261006190000_roles_permissions.sql` · `20261008000000_asset_permissions.sql`):
 *   - ทรัพย์ที่เห็น  = เห็นผู้ถือ และ (เห็นทั้งพอร์ต หรือเป็นผู้บริหารทรัพย์นั้น หรือคนคีย์รายการที่ไม่มี asset.view_assigned)
 *   - บรรทัดสมุด     = ledger.read + เห็นผู้ถือ + (เห็นทั้งพอร์ต หรือรายการผูกทรัพย์ที่เห็น)
 *   - ช่องปิดของ assets ผ่าน `fn_assets_visible()` คืน null ถ้าไม่มีสิทธิ์
 *   - ร่าง           = asset.draft+ของตัวเอง หรือ asset.manage ในขอบเขต
 *
 * **ข้อจำกัดที่ต้องรู้**: RLS ในนี้เขียนโดยผู้เขียนเทสต์ → พิสูจน์ได้ว่า "โค้ดหน้าจอไม่กรองสิทธิ์เอง แต่เชื่อสิ่งที่ DB คืน"
 * ไม่ได้พิสูจน์ว่า policy ใน Postgres ถูก — ส่วนนั้นพิสูจน์กับ Postgres ในเครื่องที่ `sql/assets-rls-probe.sql`
 * และ `fn_asset_cost_basis` ในนี้เป็น test double (ฟังก์ชันจริงอยู่ใน DB · เทียบกันที่ probe)
 */
import { createFakeDb, COA_BY_ID, OWNER, ASSET, type FakeDb } from "@/app/actions/__tests__/fake-db";
import { accrualAccountCodes } from "@/lib/db/pending-accruals";
import { coa, isCashAccount } from "@/lib/rules/coa";
import { findSub, isRevaluationSub } from "@/lib/rules/tx-rules";

export type Viewer = {
  id: string;
  perms: ReadonlySet<string>;
  /** ผู้ถือที่เห็น · "all" = owner.view_all */
  owners: readonly string[] | "all";
};

type Row = Record<string, unknown>;

export const CLASS = { RE: "c0000000-0000-4000-8000-000000000001", PAPER: "c0000000-0000-4000-8000-000000000002" };
export const CAT = {
  RE_RENTAL: "ca000000-0000-4000-8000-000000000001",
  RE_FOR_SALE: "ca000000-0000-4000-8000-000000000002",
  PAPER_STOCK: "ca000000-0000-4000-8000-000000000003",
};
export const ASSETS = {
  roomA: ASSET, // คอนโดห้อง A (ธนากร) — ใช้ id เดียวกับที่ fake ledger รู้จัก
  roomB: "bbbbbbbb-0000-4000-8000-000000000002", // คอนโดห้อง B ตึกเดียวกัน (ธนากร)
  houseC: "bbbbbbbb-0000-4000-8000-000000000003", // บ้าน (สุธี)
  stockD: "bbbbbbbb-0000-4000-8000-000000000004", // หุ้น (SRI Corporation)
};
export const USERS = {
  admin: "u0000000-0000-4000-8000-000000000001",
  manager: "u0000000-0000-4000-8000-000000000002",
  staff: "u0000000-0000-4000-8000-000000000003",
  other: "u0000000-0000-4000-8000-000000000004",
};

const PORTFOLIO = "portfolio.view_all";

export function createAssetsFakeDb() {
  const base: FakeDb = createFakeDb();
  let viewer: Viewer = { id: USERS.admin, perms: new Set(), owners: "all" };
  let seq = 0;
  const id = () => `00000000-1111-4111-8111-${String(++seq).padStart(12, "0")}`;

  const tables: Record<string, Row[]> = {
    asset_classes: [
      { id: CLASS.RE, code: "RE", name_th: "อสังหาริมทรัพย์", sort_order: 20 },
      { id: CLASS.PAPER, code: "PAPER", name_th: "สินทรัพย์กระดาษ", sort_order: 30 },
    ],
    asset_categories: [
      { id: CAT.RE_RENTAL, class_id: CLASS.RE, code: "RE_RENTAL", name_th: "ปล่อยเช่า", is_active: true, sort_order: 1 },
      { id: CAT.RE_FOR_SALE, class_id: CLASS.RE, code: "RE_FOR_SALE", name_th: "รอขาย", is_active: true, sort_order: 2 },
      { id: CAT.PAPER_STOCK, class_id: CLASS.PAPER, code: "PAPER_STOCK", name_th: "หุ้น", is_active: true, sort_order: 3 },
    ],
    assets: [],
    asset_valuations: [],
    asset_drafts: [],
    contracts: [],
    draft_entries: [],
    app_users: [
      { id: USERS.admin, email: "admin@x", display_name: "ผู้ดูแล", role: "super_admin", is_active: true, created_at: "2026-01-01T00:00:00Z" },
      { id: USERS.manager, email: "mgr@x", display_name: "ผู้จัดการ", role: "manager", is_active: true, created_at: "2026-01-02T00:00:00Z" },
      { id: USERS.staff, email: "staff@x", display_name: "พนักงาน", role: "staff", is_active: true, created_at: "2026-01-03T00:00:00Z" },
      { id: USERS.other, email: "other@x", display_name: "คนอื่น", role: "staff", is_active: true, created_at: "2026-01-04T00:00:00Z" },
    ],
    roles: [
      { key: "super_admin", label: "Super Admin", rank_order: 1 },
      { key: "management", label: "Management", rank_order: 2 },
      { key: "manager", label: "Manager", rank_order: 3 },
      { key: "staff", label: "Staff", rank_order: 4 },
    ],
    user_owner_access: [],
  };

  const has = (p: string) => viewer.perms.has(p);
  const seesOwner = (o: unknown) => viewer.owners === "all" || viewer.owners.includes(String(o));
  /** fn_can_see_asset */
  const seesAssetScope = (a: Row) => has(PORTFOLIO) || (has("asset.view_assigned") && a.manager_user_id === viewer.id);
  const assetById = (aid: unknown) => tables.assets.find((a) => a.id === aid);

  /** policy assets_by_owner */
  const visibleAssets = () =>
    tables.assets.filter((a) => seesOwner(a.owner_id) && (seesAssetScope(a) || (has("txn.create") && !has("asset.view_assigned"))));
  const strictVisibleAsset = (aid: unknown) => {
    const a = assetById(aid);
    return !!a && seesOwner(a.owner_id) && seesAssetScope(a);
  };

  /** ชุดบรรทัดที่ผู้ดูอ่านได้ — fn_can_read_txn (บรรทัดไม่มีทรัพย์ = เห็นเฉพาะทั้งพอร์ต เพราะ fake ไม่เก็บ created_by) */
  const visibleLedger = () =>
    base.rows.filter(
      (r) =>
        has("ledger.read") &&
        seesOwner(r.owner_id) &&
        (has(PORTFOLIO) || (r.txn_asset_id !== null && strictVisibleAsset(r.txn_asset_id)))
    );

  function hideColumns(a: Row): Row {
    const view = has("asset.view_assigned");
    const all = has(PORTFOLIO);
    const o: Row = { ...a };
    for (const c of ["units", "ticker", "holding_nature", "location", "size_note", "property_type", "acquired_date", "disposed_date", "manager_user_id", "tags"])
      if (!view) o[c] = null;
    for (const c of ["ownership_pct", "beneficiary_id", "funding_source"]) if (!all) o[c] = null;
    return o;
  }

  /** test double ของ fn_asset_cost_basis — ต้นทุน = บรรทัดสินทรัพย์ที่ไม่ใช่เงินสด/ลูกหนี้พัก/1800 ของใบที่ไม่ใช่ใบตีราคา */
  function costBasis(assetId: string): number {
    const accrual = new Set(accrualAccountCodes());
    let sum = 0;
    for (const r of visibleLedger()) {
      if (r.line_asset_id !== assetId) continue;
      const code = COA_BY_ID[r.coa_id];
      if (!code) continue; // รหัสนอกผัง: ฟังก์ชันจริงเชื่อมผังไม่ได้ก็ไม่นับ
      if (coa(code).type !== "asset" || isCashAccount(code) || code === "1800" || accrual.has(code)) continue;
      const sub = findSub(r.txn_type_code);
      if (sub && isRevaluationSub(sub.sub)) continue;
      sum += Math.round((Number(r.debit) - Number(r.credit)) * 100);
    }
    return sum / 100;
  }

  type Result = { data: Row[] | null; error: { message: string; code?: string } | null };

  function builder(source: () => Row[], hooks: { insert?: (row: Row) => Result; update?: (patch: Row, rows: Row[]) => Result } = {}) {
    let mode: "select" | "insert" | "update" = "select";
    let payload: Row = {};
    const preds: ((r: Row) => boolean)[] = [];
    const orders: { col: string; asc: boolean }[] = [];
    let sel: string[] | null = null;
    let cap = Infinity;
    let range: [number, number] | null = null;
    const project = (r: Row): Row => (sel ? Object.fromEntries(sel.map((c) => [c, r[c]])) : { ...r });

    function run(): Result {
      if (mode === "insert") return hooks.insert ? hooks.insert(payload) : { data: null, error: { message: "ไม่รองรับ insert" } };
      let rows = source().filter((r) => preds.every((p) => p(r)));
      if (mode === "update") return hooks.update ? hooks.update(payload, rows) : { data: null, error: { message: "ไม่รองรับ update" } };
      for (const o of [...orders].reverse())
        rows = [...rows].sort((a, b) => {
          const x = a[o.col] as never, y = b[o.col] as never;
          return (x < y ? -1 : x > y ? 1 : 0) * (o.asc ? 1 : -1);
        });
      // PostgREST ตัดผลที่ 1,000 แถวต่อคำขอเงียบๆ — จำลองให้เทสต์จับโค้ดที่ไม่แบ่งหน้าได้
      const max = 1000;
      const [from, to] = range ?? [0, max - 1];
      rows = rows.slice(from, Math.min(to, from + max - 1) + 1).slice(0, cap);
      return { data: rows.map(project), error: null };
    }

    const q: Record<string, unknown> = {
      select: (cols?: string) => {
        if (mode === "select") sel = cols && cols !== "*" ? cols.split(",").map((c) => c.trim()) : null;
        else if (cols) sel = cols.split(",").map((c) => c.trim());
        return q;
      },
      insert: (row: Row) => ((mode = "insert"), (payload = row), q),
      update: (patch: Row) => ((mode = "update"), (payload = patch), q),
      eq: (c: string, v: unknown) => (preds.push((r) => r[c] === v), q),
      in: (c: string, vals: unknown[]) => (preds.push((r) => vals.includes(r[c])), q),
      is: (c: string, v: null) => (preds.push((r) => (r[c] ?? null) === v), q),
      like: (c: string, pat: string) => {
        const re = new RegExp("^" + pat.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/%/g, ".*") + "$");
        preds.push((r) => re.test(String(r[c] ?? "")));
        return q;
      },
      not: (c: string, op: string, v: null) => {
        if (op !== "is") throw new Error("fake รองรับ not(..., 'is', null) เท่านั้น");
        preds.push((r) => (r[c] ?? null) !== v);
        return q;
      },
      // รองรับเฉพาะรูปที่หน้าทรัพย์ใช้: "a.not.is.null,b.not.is.null" และ "a.eq.X,b.eq.X"
      or: (expr: string) => {
        const terms = expr.split(",").map((t) => {
          const m = /^(\w+)\.(not\.is\.null|eq\.(.+))$/.exec(t);
          if (!m) throw new Error(`fake รองรับ or() ไม่ครบรูป: ${t}`);
          return (r: Row) => (m[2] === "not.is.null" ? r[m[1]] !== null : r[m[1]] === m[3]);
        });
        preds.push((r) => terms.some((t) => t(r)));
        return q;
      },
      order: (col: string, o?: { ascending?: boolean }) => (orders.push({ col, asc: o?.ascending !== false }), q),
      limit: (n: number) => ((cap = n), q),
      range: (from: number, to: number) => ((range = [from, to]), q),
      single: async () => {
        const r = run();
        if (r.error) return { data: null, error: r.error };
        return r.data && r.data.length === 1 ? { data: r.data[0], error: null } : { data: null, error: { message: "JSON object requested, multiple (or no) rows returned", code: "PGRST116" } };
      },
      maybeSingle: async () => {
        const r = run();
        if (r.error) return { data: null, error: r.error };
        return { data: r.data?.[0] ?? null, error: null };
      },
      then: (resolve: (v: Result) => unknown, reject?: (e: unknown) => unknown) => {
        try {
          return Promise.resolve(run()).then(resolve, reject);
        } catch (e) {
          return Promise.reject(e).then(resolve, reject);
        }
      },
    };
    return q;
  }

  /** ฟังก์ชันที่คืนชุดแถว (set-returning) — builder เดียวกัน เรียก .eq/.order/.range ต่อได้ */
  const rpcBuilders: Record<string, (args: Row) => ReturnType<typeof builder> | Promise<{ data: unknown; error: { message: string; code?: string } | null }>> = {
    fn_assets_visible: () => builder(() => visibleAssets().map(hideColumns)),
    fn_asset_cost_basis: async (args) => ({ data: costBasis(String(args.p_asset)), error: null }),
    fn_apply_asset_draft: async (args) => {
      const d = tables.asset_drafts.find((x) => x.id === args.p_draft && draftVisible(x));
      if (!d) return { data: null, error: { message: "ไม่พบร่างทะเบียนทรัพย์หรือไม่มีสิทธิ์เห็นร่างนี้" } };
      if (d.status !== "pending") return { data: null, error: { message: `ร่างอยู่สถานะ ${d.status} แล้ว อนุมัติซ้ำไม่ได้` } };
      if (!has("asset.manage") || !seesOwner(d.owner_id)) return { data: null, error: { message: "ไม่มีสิทธิ์อนุมัติร่างนี้", code: "42501" } };
      let assetId: string;
      if (d.kind === "create") {
        if (!has(PORTFOLIO)) return { data: null, error: { message: "อนุมัติร่างสร้างทรัพย์ต้องมี portfolio.view_all", code: "42501" } };
        assetId = id();
        tables.assets.push({
          id: assetId, code: `RE-${String(tables.assets.length + 1).padStart(4, "0")}`, name: d.name, class_id: d.class_id, category_id: d.category_id,
          owner_id: d.owner_id, status: "active", currency: "THB", holding_nature: "beneficial", tags: [], created_at: "2026-10-25T00:00:00Z",
          manager_user_id: null, ownership_pct: 1, beneficiary_id: null, funding_source: null, property_type: null, size_note: null,
          location: null, ticker: null, units: null, acquired_date: null, disposed_date: null, ...(d.patch as Row),
        });
      } else {
        assetId = String(d.target_asset_id);
        const a = assetById(assetId);
        if (!a || !strictVisibleAsset(assetId)) return { data: null, error: { message: "แก้ทรัพย์ไม่ได้ (ไม่มีสิทธิ์ในขอบเขตทรัพย์นี้)", code: "42501" } };
        Object.assign(a, d.patch as Row);
      }
      Object.assign(d, { status: "approved", applied_asset_id: assetId, reviewed_by: viewer.id, reviewed_at: "2026-10-25T01:00:00Z" });
      return { data: assetId, error: null };
    },
  };

  const draftVisible = (d: Row) =>
    seesOwner(d.owner_id) &&
    ((has("asset.draft") && d.created_by === viewer.id) || (has("asset.manage") && (d.target_asset_id === null || strictVisibleAsset(d.target_asset_id))));

  const writes: { table: string; op: string; payload: unknown }[] = [];
  /** สวิตช์ทำให้การเขียนล้ม — ไว้ทดสอบเส้นทาง error */
  const control = { failDraftUpdate: false };

  function from(table: string) {
    switch (table) {
      case "v_ledger_posted":
        return builder(() => visibleLedger() as unknown as Row[]);
      case "v_asset_latest_value":
        return builder(() =>
          visibleAssets().map((a) => {
            const vals = tables.asset_valuations
              .filter((v) => v.asset_id === a.id && strictVisibleAsset(a.id))
              .sort((x, y) => (String(x.as_of) < String(y.as_of) ? 1 : -1) || (String(x.created_at) < String(y.created_at) ? 1 : -1));
            const cur = vals[0];
            const asOf = cur ? String(cur.as_of) : null;
            return {
              asset_id: a.id, as_of: asOf, method: cur?.method ?? null, value: cur?.value ?? null,
              is_stale: asOf ? (Date.parse("2026-10-25") - Date.parse(asOf)) / 86400000 > 7 : null,
            };
          })
        );
      case "asset_valuations":
        return builder(() => tables.asset_valuations.filter((v) => strictVisibleAsset(v.asset_id)), {
          insert: (row) => {
            writes.push({ table, op: "insert", payload: row });
            if (!has("asset.value") || !strictVisibleAsset(row.asset_id))
              return { data: null, error: { code: "42501", message: 'new row violates row-level security policy for table "asset_valuations"' } };
            tables.asset_valuations.push({ id: id(), revision: 1, created_at: new Date(2026, 9, 25, 9, 0, ++seq).toISOString(), ...row });
            return { data: [row], error: null };
          },
        });
      case "contracts":
        return builder(() => (has("ledger.read") ? tables.contracts.filter((c) => seesOwner(c.owner_id) && (has(PORTFOLIO) || strictVisibleAsset(c.asset_id))) : []));
      case "asset_drafts":
        return builder(() => tables.asset_drafts.filter(draftVisible), {
          insert: (row) => {
            writes.push({ table, op: "insert", payload: row });
            const ok =
              has("asset.draft") && seesOwner(row.owner_id) && row.created_by === viewer.id &&
              (row.target_asset_id == null || assetById(row.target_asset_id)?.owner_id === row.owner_id);
            if (!ok) return { data: null, error: { code: "42501", message: 'new row violates row-level security policy for table "asset_drafts"' } };
            const created = { id: id(), status: "pending", applied_asset_id: null, reviewed_by: null, reviewed_at: null, reject_reason: null,
              created_at: new Date(2026, 9, 25, 8, 0, ++seq).toISOString(), target_asset_id: null, name: null, class_id: null, category_id: null, note: null, ...row };
            tables.asset_drafts.push(created);
            return { data: [created], error: null };
          },
          update: (patch, rows) => {
            writes.push({ table, op: "update", payload: patch });
            // asset_drafts_update_own / asset_drafts_review — แถวที่ไม่เข้านโยบาย = ไม่ถูกแก้ (ไม่ error)
            const hit = rows.filter((d) => {
              if (d.status !== "pending") return false;
              if (patch.status === "cancelled") return has("asset.draft") && d.created_by === viewer.id;
              if (patch.status === "rejected") return has("asset.manage") && seesOwner(d.owner_id);
              return false;
            });
            for (const d of hit) Object.assign(d, patch);
            return { data: hit.map((d) => ({ ...d })), error: null };
          },
        });
      case "app_users":
        // users_read: ตัวเอง / users.manage / owner.view_all · users_write: users.manage
        return builder(() => tables.app_users.filter((u) => u.id === viewer.id || has("users.manage") || has("owner.view_all")), {
          update: (patch, rows) => {
            writes.push({ table, op: "update", payload: patch });
            if (!tables.roles.some((r) => r.key === patch.role)) return { data: null, error: { code: "23503", message: "violates foreign key app_users_role_fkey" } };
            const hit = rows.filter(() => has("users.manage"));
            for (const u of hit) Object.assign(u, patch);
            return { data: hit.map((u) => ({ ...u })), error: null };
          },
        });
      case "draft_entries":
        // draft_entries_by_owner / draft_review / draft_insert
        return builder(
          () => tables.draft_entries.filter((d) => seesOwner(d.owner_id) && (has("ledger.read") || (has("draft.read_own") && d.created_by === viewer.id))),
          {
            update: (patch, rows) => {
              writes.push({ table, op: "update", payload: patch });
              if (control.failDraftUpdate) return { data: null, error: { message: "boom: update draft_entries" } };
              const hit = rows.filter((d) => has("ledger.approve") && d.status === "pending");
              for (const d of hit) Object.assign(d, patch);
              return { data: hit.map((d) => ({ ...d })), error: null };
            },
          }
        );
      case "assets":
        return builder(visibleAssets, {
          update: (patch, rows) => {
            writes.push({ table, op: "update", payload: patch });
            const hit = rows.filter((a) => has("asset.manage") && seesOwner(a.owner_id) && seesAssetScope(a));
            for (const a of hit) Object.assign(a, patch);
            return { data: hit.map((a) => ({ ...a })), error: null };
          },
        });
      default:
        if (table in tables) return builder(() => tables[table]);
        // อื่นๆ (owners · bank_accounts · contacts · chart_of_accounts) ให้ fake ของ action ตอบ
        return (base.client.from as (t: string) => unknown)(table) as ReturnType<typeof builder>;
    }
  }

  const client = {
    from,
    rpc: (fn: string, args: Row = {}) => {
      if (fn === "fn_post_entry") return base.client.rpc(fn, args as never);
      const f = rpcBuilders[fn];
      if (!f) throw new Error(`ไม่รู้จัก rpc ${fn}`);
      return f(args);
    },
  };

  return {
    client,
    base,
    tables,
    writes,
    control,
    setViewer: (v: Viewer) => {
      viewer = v;
    },
    get viewer() {
      return viewer;
    },
    /** เพิ่มทรัพย์ (ค่าเริ่มต้นครบทุกช่องของ fn_assets_visible) */
    addAsset(over: Row & { id: string; name: string; owner_id: string }) {
      tables.assets.push({
        code: `RE-${String(tables.assets.length + 1).padStart(4, "0")}`, class_id: CLASS.RE, category_id: CAT.RE_RENTAL, holding_nature: "beneficial",
        beneficiary_id: null, status: "active", acquired_date: null, disposed_date: null, location: null, ticker: null, units: null, currency: "THB",
        manager_user_id: null, tags: [], created_at: new Date(2026, 0, ++seq).toISOString(), ownership_pct: 1, funding_source: null, property_type: null, size_note: null,
        ...over,
      });
    },
  };
}

export type AssetsFakeDb = ReturnType<typeof createAssetsFakeDb>;
export { OWNER };

export const VIEW = {
  /** Management/Super Admin — เห็นทั้งพอร์ตและสมุด */
  management: (): Viewer => ({
    id: USERS.admin,
    owners: "all",
    perms: new Set(["owner.view_all", "ledger.read", PORTFOLIO, "asset.view_assigned", "asset.manage", "asset.draft", "asset.value", "txn.create", "ledger.approve"]),
  }),
  /** Super Admin — ระดับเดียวที่จัดการผู้ใช้ได้ (users.manage) */
  superAdmin: (): Viewer => {
    const m = VIEW.management();
    return { ...m, perms: new Set([...m.perms, "users.manage", "settings.manage"]) };
  },
  /** Manager — เห็นเฉพาะทรัพย์ที่บริหาร ตีราคาไม่ได้ */
  manager: (owners: string[] = [OWNER.tk, OWNER.sutee, OWNER.corp]): Viewer => ({
    id: USERS.manager,
    owners,
    perms: new Set(["ledger.read", "ledger.approve", "asset.view_assigned", "asset.manage", "asset.draft", "txn.create"]),
  }),
  /** Staff — เห็นชื่อทรัพย์ (ไว้คีย์) แต่ไม่เห็นสมุด/มูลค่า */
  staff: (owners: string[] = [OWNER.tk, OWNER.sutee, OWNER.corp]): Viewer => ({
    id: USERS.staff,
    owners,
    perms: new Set(["asset.draft", "txn.create"]),
  }),
};
