/**
 * ขายทรัพย์ชิ้นเดียว (`whole_item`) **ผ่าน `postEntry` ตัวจริง กับ Postgres จริง** (role authenticated · RLS บังคับ)
 *
 * สิ่งที่พิสูจน์: ผู้ใช้ส่งแค่ "ทรัพย์ + ราคาขาย + ค่าใช้จ่ายในการขาย" → server อ่านต้นทุนทั้งก้อน ค่ารีโนเวทสะสม (1510)
 * และส่วนเกินทุนที่ค้าง (3400) จากสมุดเอง → engine ประกอบบรรทัด → DB ตรวจ invariant · ตัวเลขทุกตัวอ่านจากสมุดที่ DB บันทึก
 *
 * ตัวเลขหลัก (ลูกพี่): คอนโด 3,000,000 + รีโนเวท 500,000 ขาย 4,000,000 → กำไร 500,000 (ไม่ใช่ 1,000,000) และ 1500/1510 เหลือ 0
 */
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { createTestDb, pgAvailable, type TestDb } from "@/lib/db/import/__tests__/pg-harness";
import { pgClient } from "@/lib/db/import/__tests__/pg-client";

const h = vi.hoisted(() => ({ client: null as unknown, perms: new Set<string>(), uid: "" }));
vi.mock("next/cache", () => ({ revalidatePath: vi.fn() }));
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => h.client }));
vi.mock("@/lib/auth/session", () => ({
  getAccess: async () => ({ user: { id: h.uid, email: "sale@local" }, permissions: h.perms, profile: null, error: null }),
}));

import { postEntry, type PostEntryRequest } from "../post-entry";
import { loadDisposalContext } from "../disposal-context";
import { findSub } from "@/lib/rules/tx-rules";

const UID = "0000000d-0000-4000-8000-0000000000d1";
const DAY = "30/11/2026";

describe.skipIf(!pgAvailable)("ขายทรัพย์ชิ้นเดียว ผ่านฟอร์ม → postEntry → Postgres จริง", { timeout: 120_000 }, () => {
  let db: TestDb;
  let bankId = "";
  const asset = new Map<string, string>();
  const owner = () => db.su(`select id from sri_os.owners where code='THANAKORN'`);

  const counts = () => ({
    txns: db.num("select count(*) from sri_os.transactions"),
    lines: db.num("select count(*) from sri_os.transaction_lines"),
  });
  /** ยอดสุทธิ (เดบิต − เครดิต) ของบัญชีหนึ่ง — ของทรัพย์ชิ้นเดียว หรือของผู้ถือทั้งหมดถ้าไม่ระบุทรัพย์ */
  const net = (coa: string, assetCode?: string) =>
    db.num(
      `select coalesce(sum(v.debit - v.credit), 0) from sri_os.v_ledger_posted v join sri_os.chart_of_accounts c on c.id = v.coa_id
        where c.code = '${coa}' and v.owner_id = '${owner()}' ${assetCode ? `and v.line_asset_id = '${asset.get(assetCode)}'` : ""}`
    );
  /** กำไรสุทธิตามสมุด (รายได้ − ค่าใช้จ่าย) */
  const pl = () =>
    db.num(
      `select coalesce(sum(v.credit - v.debit), 0) from sri_os.v_ledger_posted v join sri_os.chart_of_accounts c on c.id = v.coa_id
        where c.type::text in ('income', 'expense') and v.owner_id = '${owner()}'`
    );

  /** คำขอเหมือนที่ฟอร์มส่ง — มีแค่ทรัพย์ + ราคาขาย + ค่าใช้จ่าย (ไม่มีต้นทุน ไม่มีรีโนเวท ไม่มีส่วนเกินทุน) */
  const sell = (subCode: string, assetCode: string | null, salePrice: number | undefined, sellingCosts = 0): PostEntryRequest => ({
    input: {
      typeKey: findSub(subCode)!.type.key,
      subCode,
      amount: salePrice === undefined ? 1 : salePrice - sellingCosts,
      ownerId: owner(),
      bankAccountId: bankId,
      ...(assetCode ? { assetId: asset.get(assetCode)! } : {}),
      contactId: undefined,
      disposal: salePrice === undefined ? undefined : { costBasis: 0, salePrice, sellingCosts },
    },
    docDate: DAY,
    cashDate: DAY,
  });
  const buy = (subCode: string, assetCode: string, amount: number, memo: string): PostEntryRequest => ({
    input: {
      typeKey: findSub(subCode)!.type.key,
      subCode,
      amount,
      ownerId: owner(),
      bankAccountId: bankId,
      assetId: asset.get(assetCode)!,
      memo,
    },
    docDate: "01/10/2026",
    cashDate: "01/10/2026",
  });
  const mustPost = async (r: PostEntryRequest) => {
    const out = await postEntry(r);
    expect(out.ok, JSON.stringify(out)).toBe(true);
  };

  beforeAll(async () => {
    db = createTestDb();
    h.uid = UID;
    h.perms = new Set(["ledger.approve", "txn.create"]);
    h.client = pgClient(db, UID);
    db.su(`
      insert into auth.users(id) values ('${UID}');
      insert into sri_os.app_users(id, email, display_name, role, is_active) values ('${UID}', 'sale@local', 'mgmt', 'management', true);
      insert into sri_os.user_owner_access(user_id, owner_id) select '${UID}', id from sri_os.owners;
      insert into sri_os.bank_accounts(owner_id, bank, account_name, display_name)
        select id, 'BBL', 'ธนากร', 'tk-thb' from sri_os.owners where code = 'THANAKORN';
      insert into sri_os.assets(code, name, class_id, category_id, owner_id, currency)
      select x.code, x.name, ct.class_id, ct.id, (select id from sri_os.owners where code = 'THANAKORN'), 'THB'
        from (values
          ('CONDO-1', 'คอนโด ห้อง 1', 'RE_RENTAL'), ('CONDO-2', 'คอนโด ห้อง 2', 'RE_RENTAL'),
          ('WATCH', 'นาฬิกาสะสม', 'COM_ALT'), ('GOLD', 'ทองคำแท่ง', 'COM_GOLD')
        ) x(code, name, cat) join sri_os.asset_categories ct on ct.code = x.cat;
    `);
    bankId = db.su(`select id from sri_os.bank_accounts where display_name = 'tk-thb'`);
    for (const c of ["CONDO-1", "CONDO-2", "WATCH", "GOLD"]) asset.set(c, db.su(`select id from sri_os.assets where code = '${c}'`));

    // เงินตั้งต้นในบัญชี (fixture · ไม่ใช่ส่วนที่ทดสอบ)
    db.su(`begin; set local "test.uid" = '${UID}';
      select sri_os.fn_post_entry(jsonb_build_object('txn_type_code', 'inc.other', 'doc_date', '2026-09-01', 'cash_date', '2026-09-01', 'memo', 'fixture: เงินตั้งต้น',
        'transactions', jsonb_build_array(jsonb_build_object('owner_id', '${owner()}', 'lines', jsonb_build_array(
          jsonb_build_object('coa_code', '1100', 'bank_account_id', '${bankId}', 'debit', 20000000, 'credit', 0, 'cf_category', 'operating'),
          jsonb_build_object('coa_code', '4900', 'debit', 0, 'credit', 20000000, 'cf_category', 'operating'))))));
      commit;`);
    // ฐานกำไรเริ่มต้น = 20,000,000 ที่ลงเป็นรายได้ใน fixture · เทสต์ด้านล่างวัดเป็นส่วนต่างจากค่านี้
    await mustPost(buy("inv.buy_re", "CONDO-1", 3_000_000, "ซื้อคอนโด 1"));
    await mustPost(buy("inv.capex", "CONDO-1", 500_000, "รีโนเวทคอนโด 1"));
    await mustPost(buy("inv.buy_re", "CONDO-2", 2_000_000, "ซื้อคอนโด 2"));
    await mustPost(buy("inv.capex", "CONDO-2", 100_000, "รีโนเวทคอนโด 2"));
    await mustPost(buy("inv.buy_commodity", "WATCH", 1_000_000, "ซื้อนาฬิกา"));
    await mustPost(buy("inv.buy_commodity", "GOLD", 700_000, "ซื้อทองคำ"));
    // ตีราคานาฬิกาขึ้น 460,000 → 3400 (fixture · รายการตีราคาขึ้นตรงๆ เพราะฟอร์มตีราคายังไม่ใช่ขอบเขตของเทสต์นี้)
    db.su(`begin; set local "test.uid" = '${UID}';
      select sri_os.fn_post_entry(jsonb_build_object('txn_type_code', 'adj.revalue_commodity_up', 'doc_date', '2026-10-31', 'memo', 'fixture: ตีราคานาฬิกาขึ้น 460,000',
        'asset_id', '${asset.get("WATCH")}',
        'transactions', jsonb_build_array(jsonb_build_object('owner_id', '${owner()}', 'lines', jsonb_build_array(
          jsonb_build_object('coa_code', '1720', 'debit', 460000, 'credit', 0, 'asset_id', '${asset.get("WATCH")}', 'cf_category', 'none'),
          jsonb_build_object('coa_code', '3400', 'debit', 0, 'credit', 460000, 'asset_id', '${asset.get("WATCH")}', 'cf_category', 'none'))))));
      commit;`);
  }, 240_000);

  afterAll(() => db?.drop());

  const BASE_PL = 20_000_000;

  it("S0 · ตั้งต้น: คอนโด 1 ต้นทุน 3,000,000 + รีโนเวท 500,000 · นาฬิกา 1,000,000 + ส่วนเกินทุน 460,000 · กำไรสะสมตามสมุด = ฐาน fixture", () => {
    expect(net("1500", "CONDO-1")).toBe(3_000_000);
    expect(net("1510", "CONDO-1")).toBe(500_000);
    expect(net("1720", "WATCH")).toBe(1_460_000);
    expect(net("3400", "WATCH")).toBe(-460_000);
    expect(pl()).toBe(BASE_PL);
  });

  it("S1 · ฟอร์มอ่านต้นทุนจากสมุดได้ (loadDisposalContext): ต้นทุนรวม 3,500,000 · รีโนเวท 500,000 · ไม่มีส่วนเกินทุน · โหมด whole_item", async () => {
    const r = await loadDisposalContext({ ownerId: owner(), assetId: asset.get("CONDO-1")! });
    expect(r.ok, JSON.stringify(r)).toBe(true);
    if (!r.ok) return;
    expect(r.ctx).toMatchObject({ mode: "whole_item", costBasis: 3_500_000, renovation: 500_000, priorSurplus: 0 });
    const w = await loadDisposalContext({ ownerId: owner(), assetId: asset.get("WATCH")! });
    expect(w.ok && w.ctx).toMatchObject({ mode: "whole_item", costBasis: 1_000_000, renovation: 0, priorSurplus: 460_000 });
    const g = await loadDisposalContext({ ownerId: owner(), assetId: asset.get("GOLD")! });
    expect(g.ok && g.ctx.mode).toBe("average");
  });

  it("S2 · ไม่ส่งข้อมูล: ไม่เลือกทรัพย์ / ไม่ใส่ราคาขาย / ไม่ส่ง disposal เลย → ปฏิเสธ ไม่มีอะไรถูกเขียน", async () => {
    const before = counts();
    const noAsset = await postEntry(sell("inv.sell_re", null, 4_000_000));
    expect(noAsset.ok).toBe(false);
    if (!noAsset.ok) expect(noAsset.message).toMatch(/ต้องเลือกทรัพย์ที่ขาย/);
    const noPrice = await postEntry(sell("inv.sell_re", "CONDO-1", undefined));
    expect(noPrice.ok).toBe(false);
    if (!noPrice.ok) expect(noPrice.message).toMatch(/กรอกราคาขายจริง/);
    const zero = await postEntry(sell("inv.sell_re", "CONDO-1", 0));
    expect(zero.ok).toBe(false);
    expect(counts()).toEqual(before);
  });

  it("S3 · ทรัพย์ที่ถัวเฉลี่ยได้ (ทองคำ) → ปฏิเสธ พร้อมเหตุผล ไม่มีอะไรถูกเขียน (ต้องตัดล็อตพร้อมใบขาย — ต้องมี RPC ฝั่ง DB)", async () => {
    const before = counts();
    const r = await postEntry(sell("inv.sell_commodity", "GOLD", 800_000));
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.message).toMatch(/ขายทรัพย์ชนิดนี้ผ่านฟอร์มยังไม่ได้/);
    expect(counts()).toEqual(before);
  });

  it("S4 · ต้นทุน/รีโนเวท/ส่วนเกินทุนที่ browser แต่งมาไม่ถูกเชื่อ: ส่งต้นทุน 1 บาท + รีโนเวท 0 → ใช้ค่าจากสมุด (คอนโด 2: 2,100,000)", async () => {
    const forged = sell("inv.sell_re", "CONDO-2", 2_500_000);
    forged.input.disposal = { costBasis: 1, salePrice: 2_500_000, sellingCosts: 0, renovationBasis: 0, unrealizedAdjustment: 999_999, assetCostBefore: 1, priorSurplus: 5 };
    const before = pl();
    await mustPost(forged);
    // ต้นทุนจริง 2,000,000 + 100,000 → กำไร 400,000 (ถ้าเชื่อค่าแต่ง จะได้ 2,499,999)
    expect(pl() - before).toBe(400_000);
    expect(net("1500", "CONDO-2")).toBe(0);
    expect(net("1510", "CONDO-2")).toBe(0);
    expect(net("3400", "CONDO-2")).toBe(0);
  });

  it("S5 · ตัวเลขของลูกพี่: คอนโด 3,000,000 + รีโนเวท 500,000 ขาย 4,000,000 → กำไร 500,000 (ไม่ใช่ 1,000,000) · 1500 และ 1510 เหลือ 0 · เงินเข้า 4,000,000", async () => {
    const before = { pl: pl(), cash: net("1100") };
    await mustPost(sell("inv.sell_re", "CONDO-1", 4_000_000));
    expect(pl() - before.pl).toBe(500_000);
    expect(net("1500", "CONDO-1")).toBe(0);
    expect(net("1510", "CONDO-1")).toBe(0);
    expect(net("1100") - before.cash).toBe(4_000_000);
    expect(net("4300")).toBe(-900_000); // กำไรจากขายอสังหาฯ สะสม = คอนโด 2 (400,000) + คอนโด 1 (500,000)
  });

  it("S6 · ขายคอนโด 1 ซ้ำ (ขายไปแล้ว) → ปฏิเสธ ไม่มีต้นทุนเหลือให้ตัด", async () => {
    const before = counts();
    const r = await postEntry(sell("inv.sell_re", "CONDO-1", 4_000_000));
    expect(r.ok).toBe(false);
    expect(counts()).toEqual(before);
  });

  it("S7 · ทรัพย์ที่เคยตีราคาขึ้น 460,000: ขาย 1,500,000 ค่านายหน้า 50,000 → กำไร 450,000 จากต้นทุนเดิม · 3400 ถูกล้างทั้งก้อน (ไม่นับซ้ำ) · 1720 เหลือ 0", async () => {
    const before = pl();
    await mustPost(sell("inv.sell_commodity", "WATCH", 1_500_000, 50_000));
    expect(pl() - before).toBe(450_000); // (1,500,000 − 50,000) − 1,000,000 · ส่วนเกินทุน 460,000 ไม่เข้ากำไร
    expect(net("3400", "WATCH")).toBe(0);
    expect(net("1720", "WATCH")).toBe(0);
  });

  it("S8 · ไม่มีสิทธิ์ลงสมุด (ledger.approve) → ปฏิเสธก่อนอ่านสมุด", async () => {
    const keep = h.perms;
    h.perms = new Set(["txn.create"]);
    try {
      const before = counts();
      const r = await postEntry(sell("inv.sell_re", "CONDO-2", 1));
      expect(r.ok).toBe(false);
      expect(counts()).toEqual(before);
    } finally {
      h.perms = keep;
    }
  });
});
