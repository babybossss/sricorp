/**
 * หน้าจัดการอัตราแลกเปลี่ยน **ผ่าน server action ตัวจริง กับ Postgres จริง** (role authenticated · RLS บังคับ)
 *
 * พิสูจน์: (1) อัตราที่เพิ่มแล้วหน้าแลกเงินเห็นทันที (อ่านจาก DB) (2) คนไม่มี settings.manage ถูก RLS ปฏิเสธ — ไม่ใช่แค่ซ่อนปุ่ม
 * (3) อัตราที่มีรายการอ้างถึงแล้วลบไม่ได้ / แถวเดิมไม่ถูกเขียนทับ (4) ค่าที่ไม่ควรรับถูกปฏิเสธและไม่มีอะไรถูกเขียน
 *
 * ตัวแทน PostgREST (insert/delete) อยู่ที่ pg-fx-client.ts เพราะตัวกลางของทีม (pg-client.ts) รองรับแค่ select/rpc
 */
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { createTestDb, pgAvailable, type TestDb } from "@/lib/db/import/__tests__/pg-harness";
import { fxClientFor } from "./pg-fx-client";

const h = vi.hoisted(() => ({ client: null as unknown, uid: "" }));
vi.mock("next/cache", () => ({ revalidatePath: vi.fn() }));
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => h.client }));
vi.mock("@/lib/auth/session", () => ({
  getAccess: async () => ({ user: { id: h.uid, email: "fx@local" }, permissions: new Set<string>(), profile: null, error: null }),
}));

import { addFxRate, deleteFxRate, listFxRates } from "../fx-rates";
import { loadFxContext } from "../fx-context";

const U = {
  mgmt: "0000000e-0000-4000-8000-0000000000e1",
  mgr: "0000000e-0000-4000-8000-0000000000e2",
  staff: "0000000e-0000-4000-8000-0000000000e3",
};

/** วันที่ (ISO) ย้อนหลัง n วันจากวันนี้ — เทสต์ใช้วันจริงของเครื่อง เพราะหน้านี้ปฏิเสธอัตราของอนาคต */
const daysAgo = (n: number) => new Date(Date.now() - n * 86_400_000).toISOString().slice(0, 10);
const dmy = (iso: string) => `${iso.slice(8)}/${iso.slice(5, 7)}/${iso.slice(0, 4)}`;

describe.skipIf(!pgAvailable)("จัดการอัตราแลกเปลี่ยน ผ่าน action → Postgres จริง", { timeout: 120_000 }, () => {
  let db: TestDb;
  const owner = () => db.su(`select id from sri_os.owners where code='THANAKORN'`);
  const rateRows = () => db.rows<{ currency: string; rate_date: string; thb_per_unit: number; note: string | null; source: string; created_by: string | null }>(
    `select currency, rate_date::text, thb_per_unit::float8, note, source, created_by::text from sri_os.fx_rates order by currency, rate_date`
  );
  const count = () => db.num("select count(*) from sri_os.fx_rates");

  const as = (who: keyof typeof U) => {
    h.uid = U[who];
    h.client = fxClientFor(db, U[who]);
  };

  const input = (over: Partial<{ currency: string; rateDate: string; rate: string; note: string }> = {}) => ({
    currency: "USD",
    rateDate: dmy(daysAgo(30)),
    rate: "36.50",
    note: "Google Finance",
    ...over,
  });

  beforeAll(() => {
    db = createTestDb();
    db.su(`
      insert into auth.users(id) values ('${U.mgmt}'), ('${U.mgr}'), ('${U.staff}');
      insert into sri_os.app_users(id, email, display_name, role, is_active) values
        ('${U.mgmt}', 'm@local', 'mgmt', 'management', true),
        ('${U.mgr}', 'g@local', 'mgr', 'manager', true),
        ('${U.staff}', 's@local', 'stf', 'staff', true);
      insert into sri_os.user_owner_access(user_id, owner_id) select u.id, o.id from sri_os.owners o cross join (values ('${U.mgmt}'::uuid), ('${U.mgr}'::uuid), ('${U.staff}'::uuid)) u(id);
      insert into sri_os.bank_accounts(owner_id, bank, account_name, display_name, currency)
      select o.id, b.bank, b.nm, b.dn, b.ccy from sri_os.owners o join (values
        ('THANAKORN', 'BBL', 'ธนากร', 'tk-thb', 'THB'), ('THANAKORN', 'BBL', 'ธนากร FCD', 'tk-fcd', 'USD')) b(code, bank, nm, dn, ccy) on b.code = o.code;
    `);
  }, 240_000);

  afterAll(() => db?.drop());

  it("F0 · ตั้งต้น: ไม่มีอัตราในตาราง · หน้าอ่านได้ว่าง (ไม่มีอัตราจำลอง)", async () => {
    as("mgmt");
    expect(count()).toBe(0);
    expect(await listFxRates()).toEqual({ ok: true, rows: [] });
  });

  it("F1 · เพิ่ม USD 36.50 → แถวจริงใน DB (ป้อนมือ · ที่มาใน note · ผู้บันทึก) · หน้ารายการเห็นทันที · หน้าแลกเงิน (loadFxContext) เห็นอัตราเดียวกันทันที", async () => {
    as("mgmt");
    const d1 = daysAgo(30);
    const r = await addFxRate(input({ rateDate: dmy(d1) }));
    expect(r.ok, JSON.stringify(r)).toBe(true);
    expect(rateRows()).toEqual([{ currency: "USD", rate_date: d1, thb_per_unit: 36.5, note: "Google Finance", source: "manual", created_by: U.mgmt }]);

    const list = await listFxRates();
    expect(list.ok && list.rows.map((x) => [x.currency, x.rateDate, x.thbPerUnit, x.note])).toEqual([["USD", d1, 36.5, "Google Finance"]]);

    // ฝากเงินตรา 10,000 USD @36.50 ลงบัญชี FCD (fixture: ทางเข้าเงินตราผ่านแอปยังไม่มี) แล้วให้ฟอร์มแลกเงินอ่านอัตรา
    const tk = owner();
    const thb = db.su(`select id from sri_os.bank_accounts where display_name = 'tk-thb'`);
    const fcd = db.su(`select id from sri_os.bank_accounts where display_name = 'tk-fcd'`);
    db.su(`begin; set local "test.uid" = '${U.mgmt}';
      select sri_os.fn_post_entry(jsonb_build_object('txn_type_code', 'trf.internal', 'doc_date', '${d1}', 'cash_date', '${d1}', 'memo', 'fixture: ซื้อ USD 10,000 @36.50',
        'transactions', jsonb_build_array(jsonb_build_object('owner_id', '${tk}', 'lines', jsonb_build_array(
          jsonb_build_object('coa_code', '1100', 'bank_account_id', '${fcd}', 'debit', 365000, 'credit', 0, 'cf_category', 'none', 'currency', 'USD', 'amount_original', 10000, 'fx_rate', 36.5, 'fx_rate_date', '${d1}'),
          jsonb_build_object('coa_code', '1100', 'bank_account_id', '${thb}', 'debit', 0, 'credit', 365000, 'cf_category', 'none'))))));
      commit;`);
    // อัตราใหม่ของวันถัดมาเพิ่มผ่านหน้าตั้งค่า → ฟอร์มแลกเงินต้องเห็นโดยไม่ต้อง deploy / แก้โค้ดใด
    const d2 = daysAgo(10);
    expect((await addFxRate(input({ rateDate: dmy(d2), rate: "35.75", note: "ธปท. อัตราขาย" }))).ok).toBe(true);
    const ctx = await loadFxContext({ ownerId: tk, bankAccountId: fcd });
    expect(ctx.ok, JSON.stringify(ctx)).toBe(true);
    if (!ctx.ok) return;
    expect(ctx.ctx.rates.map((x) => [x.rateDate, x.thbPerUnit])).toEqual([[d2, 35.75], [d1, 36.5]]);
    expect(ctx.ctx).toMatchObject({ units: 10000, bookThb: 365000, bookRate: 36.5 });
  });

  it("F2 · RLS: ผู้จัดการ (ไม่มี settings.manage) เพิ่ม/ลบอัตราไม่ได้ — DB ปฏิเสธ ไม่ใช่ซ่อนปุ่ม · ตารางไม่ขยับแม้แต่แถวเดียว", async () => {
    for (const who of ["mgr", "staff"] as const) {
      as(who);
      const before = rateRows();
      const add = await addFxRate(input({ rateDate: dmy(daysAgo(5)), rate: "99.00", note: "ปลอม" }));
      expect(add.ok, who).toBe(false);
      if (!add.ok) expect(add.message).toMatch(/ไม่มีสิทธิ์จัดการอัตราแลกเปลี่ยน/);
      const del = await deleteFxRate({ currency: "USD", rateDate: daysAgo(10) });
      expect(del.ok, who).toBe(false);
      if (!del.ok) expect(del.message).toMatch(/ไม่มีอะไรถูกลบ/);
      expect(rateRows(), who).toEqual(before);
      // อ่านได้ (อัตราไม่ใช่ความลับ — ฟอร์มแลกเงินของทุกคนต้องเห็น)
      const list = await listFxRates();
      expect(list.ok && list.rows.length, who).toBe(2);
    }
    expect(count()).toBe(2);
  });

  it("F3 · อัตราที่มีรายการอ้างถึงแล้ว (USD @36.50 ที่ใช้ฝาก 10,000 USD = 365,000 บาท) → ลบไม่ได้ ค่ายังเดิม · อัตราที่ไม่มีใครใช้ลบได้", async () => {
    as("mgmt");
    const d1 = daysAgo(30);
    const used = await deleteFxRate({ currency: "USD", rateDate: d1 });
    expect(used.ok).toBe(false);
    if (!used.ok) expect(used.message).toMatch(/ลบอัตรานี้ไม่ได้/);
    expect(rateRows().find((r) => r.rate_date === d1)?.thb_per_unit).toBe(36.5);
    // ยอดบาทของรายการเดิมยังตรงกับอัตราในตาราง: 10,000 × 36.50 = 365,000
    expect(db.num(`select sum(l.debit) from sri_os.transaction_lines l where l.currency = 'USD'`)).toBe(365_000);

    const unused = await deleteFxRate({ currency: "USD", rateDate: daysAgo(10) });
    expect(unused.ok, JSON.stringify(unused)).toBe(true);
    expect(count()).toBe(1);
    // ลบซ้ำ → ไม่มีอะไรถูกลบ บอกตรงๆ
    const again = await deleteFxRate({ currency: "USD", rateDate: daysAgo(10) });
    expect(again.ok).toBe(false);
  });

  it("F4 · เพิ่มซ้ำ (สกุล+วันเดิม) → ปฏิเสธ ไม่เขียนทับ: 36.50 ยังเป็น 36.50 แม้ส่ง 40.00 (แก้ค่าแถวเดิมไม่มีเส้นทาง)", async () => {
    as("mgmt");
    const r = await addFxRate(input({ rateDate: dmy(daysAgo(30)), rate: "40.00", note: "พยายามแก้ทับ" }));
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.message).toMatch(/มีอัตราของสกุลและวันที่นี้อยู่แล้ว/);
    expect(rateRows()).toHaveLength(1);
    expect(rateRows()[0]).toMatchObject({ thb_per_unit: 36.5, note: "Google Finance" });
  });

  it("F5 · ค่าที่ไม่ควรรับ: ศูนย์ · ติดลบ · วันอนาคต · บาท · ทศนิยม 9 ตำแหน่ง · ไม่ระบุที่มา · วันที่ไม่จริง → ปฏิเสธทุกข้อ ไม่มีแถวถูกเขียน", async () => {
    as("mgmt");
    const tomorrow = dmy(new Date(Date.now() + 2 * 86_400_000).toISOString().slice(0, 10));
    const cases: [string, ReturnType<typeof input>][] = [
      ["ศูนย์", input({ rateDate: dmy(daysAgo(3)), rate: "0" })],
      ["ติดลบ", input({ rateDate: dmy(daysAgo(3)), rate: "-36.5" })],
      ["ติดลบวงเล็บ", input({ rateDate: dmy(daysAgo(3)), rate: "(36.5)" })],
      ["วันอนาคต", input({ rateDate: tomorrow })],
      ["บาท", input({ currency: "THB", rateDate: dmy(daysAgo(3)), rate: "1" })],
      ["สกุลแปลก", input({ currency: "EUR", rateDate: dmy(daysAgo(3)) })],
      ["ทศนิยมเกิน", input({ rateDate: dmy(daysAgo(3)), rate: "36.123456789" })],
      ["ไม่มีที่มา", input({ rateDate: dmy(daysAgo(3)), note: "" })],
      ["วันที่ไม่จริง", input({ rateDate: "31/02/2026" })],
    ];
    for (const [label, req] of cases) {
      const r = await addFxRate(req);
      expect(r.ok, label).toBe(false);
      if (!r.ok) expect(r.fieldErrors, label).toBeTruthy();
    }
    expect(count()).toBe(1);
  });

  it("F6 · เพิ่ม JPY ทศนิยมสูง 0.23456789 → เก็บตรงตามที่พิมพ์ (ไม่ปัด) และผู้ใช้ที่ไม่มีสิทธิ์ไม่เห็นผลต่างจากเดิม", async () => {
    as("mgmt");
    const r = await addFxRate(input({ currency: "JPY", rateDate: dmy(daysAgo(2)), rate: "0.23456789", note: "ธปท." }));
    expect(r.ok, JSON.stringify(r)).toBe(true);
    expect(rateRows().find((x) => x.currency === "JPY")?.thb_per_unit).toBe(0.23456789);
  });

  /**
   * DB ปิดช่องแล้ว (20261025000015): แถวที่มีรายการอ้างถึงห้ามแก้ค่า/สกุล/วันที่/ประเภท · แถวที่ไม่มีใครใช้แก้ได้ · note แก้ได้ตลอด
   * ตัดสินจาก query จริง ไม่ใช่ป้าย (เดิมเทสต์นี้ mark ไว้เป็น it.fails จนกว่า DB จะปิดช่อง)
   */
  it("F7 · UPDATE ค่าอัตราของแถวที่ถูกอ้างถึงแล้วผ่าน API ตรงๆ ถูกปฏิเสธ (ถ้ายอม: ยอดบาท 365,000 ไม่ตรงอัตรา 40.00 ผลต่าง 35,000) · note แก้ได้", () => {
    const d1 = daysAgo(30);
    expect(() => db.as(U.mgmt, `update sri_os.fx_rates set thb_per_unit = 40.00 where currency = 'USD' and rate_date = '${d1}';`)).toThrow();
    expect(rateRows().find((r) => r.rate_date === d1)?.thb_per_unit).toBe(36.5);
    // note แก้ได้ตลอด (ไม่กระทบยอดบาท)
    db.as(U.mgmt, `update sri_os.fx_rates set note = 'Google Finance (ตรวจแล้ว)' where currency = 'USD' and rate_date = '${d1}';`);
    expect(rateRows().find((r) => r.rate_date === d1)?.note).toBe("Google Finance (ตรวจแล้ว)");
  });
});
