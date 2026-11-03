/**
 * หน้า "งบดุล & ทรัพย์สิน" กับสมุดจริงใน Postgres (role authenticated · RLS บังคับ)
 *
 * พิสูจน์ว่าตัวเลขที่หน้านี้แสดง (ต้นไม้ · NAV รายผู้ถือ) ตรงกับสมุดที่ DB บันทึก — เทียบกับ SQL รวมยอดเองโดยไม่ผ่านตัวสร้างงบ
 * และตรงกับงบที่ /reports ใช้ (`buildBalanceSheet`) ตัวต่อตัว · ผู้ถือที่ไม่มีรายการต้องเป็น "ไม่มีรายการ" ไม่ใช่ 0
 */
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { createTestDb, pgAvailable, type TestDb } from "@/lib/db/import/__tests__/pg-harness";
import { pgClient } from "@/lib/db/import/__tests__/pg-client";

const h = vi.hoisted(() => ({ client: null as unknown, perms: new Set<string>(), uid: "" }));
vi.mock("next/cache", () => ({ revalidatePath: vi.fn() }));
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => h.client }));
vi.mock("@/lib/auth/session", () => ({
  getAccess: async () => ({ user: { id: h.uid, email: "bal@local" }, permissions: h.perms, profile: null, error: null }),
}));

import { postEntry } from "../post-entry";
import { loadStatementData } from "@/lib/db/statements-server";
import { buildBalanceSheet, ownersInView } from "@/lib/db/statements";
import { allocation, buildBalanceTree, hasLedgerData, navByOwner, type BalanceNode } from "@/lib/db/balance-tree";
import { findSub } from "@/lib/rules/tx-rules";

const UID = "0000000b-0000-4000-8000-0000000000b1";
const YEAR = new Date().getUTCFullYear();
const flat = (nodes: BalanceNode[]): BalanceNode[] => nodes.flatMap((x) => [x, ...flat(x.children ?? [])]);

describe.skipIf(!pgAvailable)("งบดุล & ทรัพย์สิน ← สมุดจริง", { timeout: 120_000 }, () => {
  let db: TestDb;
  const owner = (code: string) => db.su(`select id from sri_os.owners where code='${code}'`);
  /** รวมยอดตามประเภทบัญชีด้วย SQL ตรงๆ (ไม่ผ่านตัวสร้างงบ) */
  const sqlTotal = (ownerId: string, type: "asset" | "liability") =>
    db.num(
      `select coalesce(sum(${type === "asset" ? "v.debit - v.credit" : "v.credit - v.debit"}), 0) from sri_os.v_ledger_posted v
         join sri_os.chart_of_accounts c on c.id = v.coa_id where c.type::text = '${type}' and v.owner_id = '${ownerId}' and v.doc_date <= '${YEAR}-12-31'`
    );
  const fixture = (ownerCode: string, bankName: string, amount: number, memo: string) => {
    const o = owner(ownerCode);
    const b = db.su(`select id from sri_os.bank_accounts where display_name = '${bankName}'`);
    db.su(`begin; set local "test.uid" = '${UID}';
      select sri_os.fn_post_entry(jsonb_build_object('txn_type_code', 'inc.other', 'doc_date', '${YEAR}-01-05', 'cash_date', '${YEAR}-01-05', 'memo', '${memo}',
        'transactions', jsonb_build_array(jsonb_build_object('owner_id', '${o}', 'lines', jsonb_build_array(
          jsonb_build_object('coa_code', '1100', 'bank_account_id', '${b}', 'debit', ${amount}, 'credit', 0, 'cf_category', 'operating'),
          jsonb_build_object('coa_code', '4900', 'debit', 0, 'credit', ${amount}, 'cf_category', 'operating'))))));
      commit;`);
  };

  beforeAll(async () => {
    db = createTestDb();
    h.uid = UID;
    h.perms = new Set(["ledger.approve", "txn.create"]);
    h.client = pgClient(db, UID);
    db.su(`
      insert into auth.users(id) values ('${UID}');
      insert into sri_os.app_users(id, email, display_name, role, is_active) values ('${UID}', 'bal@local', 'mgmt', 'management', true);
      insert into sri_os.user_owner_access(user_id, owner_id) select '${UID}', id from sri_os.owners;
      insert into sri_os.bank_accounts(owner_id, bank, account_name, display_name)
        select id, 'BBL', 'x', code || '-bank' from sri_os.owners where code in ('THANAKORN', 'SUTEE', 'SUDJIT');
      insert into sri_os.assets(code, name, class_id, category_id, owner_id, currency)
      select 'CONDO-B', 'คอนโดทดสอบงบ', ct.class_id, ct.id, (select id from sri_os.owners where code = 'THANAKORN'), 'THB'
        from sri_os.asset_categories ct where ct.code = 'RE_RENTAL';
    `);
    fixture("THANAKORN", "THANAKORN-bank", 5_000_000, "fixture ธนากร");
    fixture("SUTEE", "SUTEE-bank", 300_000, "fixture สุธี");
    const asset = db.su(`select id from sri_os.assets where code = 'CONDO-B'`);
    const bank = db.su(`select id from sri_os.bank_accounts where display_name = 'THANAKORN-bank'`);
    for (const [sub, amount, memo] of [["inv.buy_re", 3_000_000, "ซื้อคอนโด"], ["inv.capex", 500_000, "รีโนเวท"]] as const) {
      const r = await postEntry({
        input: { typeKey: findSub(sub)!.type.key, subCode: sub, amount, ownerId: owner("THANAKORN"), bankAccountId: bank, assetId: asset, memo },
        docDate: `10/01/${YEAR}`,
        cashDate: `10/01/${YEAR}`,
      });
      expect(r.ok, JSON.stringify(r)).toBe(true);
    }
  }, 240_000);

  afterAll(() => db?.drop());

  it("B1 · ธนากร: สินทรัพย์ในต้นไม้ = SQL รวมยอดเอง = 5,000,000 (เงินสด 1,500,000 + คอนโด 3,000,000 + รีโนเวท 500,000) · หนี้สิน 0", async () => {
    const data = await loadStatementData();
    expect(data.ok).toBe(true);
    if (!data.ok) return;
    const tk = owner("THANAKORN");
    const bs = buildBalanceSheet(data.lines, { year: YEAR, ownerIds: [tk] });
    const tree = buildBalanceTree(bs);
    expect(tree[0].value).toBe(sqlTotal(tk, "asset"));
    expect(tree[0].value).toBe(5_000_000);
    expect(tree[1].value).toBe(sqlTotal(tk, "liability"));
    expect(tree[1].value).toBe(0);
    expect(bs.balanced).toBe(true);
    const lineSum = Math.round(flat([tree[0]]).filter((x) => x.kind === "line").reduce((t, x) => t + x.value * 100, 0)) / 100;
    expect(lineSum).toBe(5_000_000);
  });

  it("B2 · NAV รายผู้ถือตรงกับ SQL: ธนากร 5,000,000 · สุธี 300,000 · ผู้ถือที่ไม่มีรายการ (สุดจิตต์) = ไม่มีรายการ ไม่ใช่ 0 · รวมครอบครัวเท่ากัน", async () => {
    const data = await loadStatementData();
    if (!data.ok) throw new Error(data.error);
    const ids = data.owners.map((o) => o.id);
    const nav = navByOwner(data.lines, ids, YEAR);
    const byName = (code: string) => nav.find((x) => x.ownerId === owner(code))!;
    expect(byName("THANAKORN")).toMatchObject({ nav: 5_000_000, hasData: true, balanced: true });
    expect(byName("SUTEE")).toMatchObject({ nav: 300_000, hasData: true });
    expect(byName("SUDJIT")).toMatchObject({ nav: 0, hasData: false });
    for (const x of nav) expect(x.nav, x.ownerId).toBe(sqlTotal(x.ownerId, "asset") - sqlTotal(x.ownerId, "liability"));

    const family = buildBalanceSheet(data.lines, { year: YEAR, ownerIds: ownersInView("family", ids) });
    expect(family.totalAssets - family.totalLiabilities).toBe(5_300_000);
    expect(nav.reduce((t, x) => t + x.nav, 0)).toBe(5_300_000);
    expect(hasLedgerData(data.lines, [owner("SUDJIT")], YEAR)).toBe(false);
    expect(allocation(family).reduce((t, x) => t + x.value, 0)).toBe(5_300_000);
  });

  it("B3 · รายการคนละปีไม่ปนกัน: ปีก่อนปีที่ลงรายการ ไม่มีรายการ (hasData false) ทุกผู้ถือ", async () => {
    const data = await loadStatementData();
    if (!data.ok) throw new Error(data.error);
    expect(hasLedgerData(data.lines, data.owners.map((o) => o.id), YEAR - 1)).toBe(false);
  });
});
