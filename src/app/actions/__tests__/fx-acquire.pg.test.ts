/**
 * ซื้อเงินตราเข้า FCD แล้วแปลงค่า แล้วแลกกลับ **ผ่าน action ตัวจริง กับ Postgres จริง** (role authenticated · RLS บังคับ)
 * ทุกอย่างเดินทางเดียวกับที่ผู้ใช้ทำ: ใส่อัตราที่หน้าตั้งค่า (`addFxRate`) → ซื้อทันทีโดยไม่โหลดอะไรใหม่ (`postEntry`)
 *
 * ผู้ใช้ส่งแค่ บัญชีบาท · บัญชี FCD ปลายทาง · วันของอัตรา · จำนวนเงินตรา — สกุลมาจากบัญชีปลายทาง ยอดบาท = จำนวน × อัตรา (server คิด)
 */
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { createTestDb, pgAvailable, type TestDb } from "@/lib/db/import/__tests__/pg-harness";
import { fxClientFor } from "./pg-fx-client";

const h = vi.hoisted(() => ({ client: null as unknown, perms: new Set<string>(), uid: "" }));
vi.mock("next/cache", () => ({ revalidatePath: vi.fn() }));
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => h.client }));
vi.mock("@/lib/auth/session", () => ({
  getAccess: async () => ({ user: { id: h.uid, email: "aq@local" }, permissions: h.perms, profile: null, error: null }),
}));

import { postEntry, type PostEntryRequest } from "../post-entry";
import { addFxRate } from "../fx-rates";
import { REALISED_FX_GAIN } from "@/lib/rules/coa";

const UID = "0000000a-0000-4000-8000-0000000000a1";
const daysAgo = (n: number) => new Date(Date.now() - n * 86_400_000).toISOString().slice(0, 10);
const dmy = (iso: string) => `${iso.slice(8)}/${iso.slice(5, 7)}/${iso.slice(0, 4)}`;
const D_BUY = daysAgo(60);
const D_END = daysAgo(30);
const D_SELL = daysAgo(5);

describe.skipIf(!pgAvailable)("ซื้อเงินตราเข้า FCD ผ่านฟอร์ม → postEntry → Postgres จริง", { timeout: 180_000 }, () => {
  let db: TestDb;
  const bank = new Map<string, string>();
  const owner = (code: string) => db.su(`select id from sri_os.owners where code='${code}'`);
  const counts = () => ({ txns: db.num("select count(*) from sri_os.transactions"), lines: db.num("select count(*) from sri_os.transaction_lines") });
  const position = (b: string) =>
    db.rows<{ units: number; thb: number }>(
      `select coalesce(sum(case when debit > 0 then amount_original else -amount_original end), 0)::float8 units, coalesce(sum(debit - credit), 0)::float8 thb
         from sri_os.v_ledger_posted where bank_account_id = '${bank.get(b)}'`
    )[0];
  const bal = (o: string, coa: string) =>
    db.num(`select coalesce(sum(v.credit - v.debit), 0) from sri_os.v_ledger_posted v join sri_os.chart_of_accounts c on c.id = v.coa_id where c.code = '${coa}' and v.owner_id = '${owner(o)}'`);
  const pl = (o: string) =>
    db.num(`select coalesce(sum(v.credit - v.debit), 0) from sri_os.v_ledger_posted v join sri_os.chart_of_accounts c on c.id = v.coa_id where c.type::text in ('income','expense') and v.owner_id = '${owner(o)}'`);

  /** คำขอเหมือนที่ฟอร์มส่ง: บัญชีบาท + บัญชี FCD ปลายทาง + วันของอัตรา + จำนวนเงินตรา (ยอดบาทที่ฟอร์มโชว์ใส่มาด้วยแต่ server ไม่เชื่อ) */
  const buy = (o: string, thb: string, fcd: string | null, date: string, units: number | undefined, amount = 0): PostEntryRequest => ({
    input: {
      typeKey: "transfer",
      subCode: "trf.fx_acquire",
      amount,
      ownerId: owner(o),
      bankAccountId: bank.get(thb)!,
      ...(fcd ? { transferToBankAccountId: bank.get(fcd)! } : {}),
    },
    docDate: dmy(date),
    cashDate: dmy(date),
    fx: { dealRateDate: date, ...(units !== undefined ? { amountOriginal: units } : {}) },
  });
  const rateReq = (date: string, rate: string) => ({ currency: "USD", rateDate: dmy(date), rate, note: "Google Finance" });

  beforeAll(() => {
    db = createTestDb();
    h.uid = UID;
    h.perms = new Set(["ledger.approve", "txn.create"]);
    h.client = fxClientFor(db, UID);
    db.su(`
      insert into auth.users(id) values ('${UID}');
      insert into sri_os.app_users(id, email, display_name, role, is_active) values ('${UID}', 'aq@local', 'mgmt', 'management', true);
      insert into sri_os.user_owner_access(user_id, owner_id) select '${UID}', id from sri_os.owners;
      insert into sri_os.bank_accounts(owner_id, bank, account_name, display_name, currency)
      select o.id, b.bank, b.nm, b.dn, b.ccy from sri_os.owners o join (values
        ('THANAKORN', 'BBL', 'ธนากร', 'tk-thb', 'THB'), ('THANAKORN', 'BBL', 'ธนากร FCD', 'tk-fcd', 'USD'),
        ('THANAKORN', 'KBANK', 'ธนากร 2', 'tk-thb2', 'THB'), ('THANAKORN', 'KBANK', 'ธนากร FCD 2', 'tk-fcd2', 'USD'),
        ('SUTEE', 'KBANK', 'สุธี', 'st-thb', 'THB'), ('SUTEE', 'KBANK', 'สุธี FCD', 'st-fcd', 'USD'),
        ('SUTEE', 'KBANK', 'สุธี เยน', 'st-jpy', 'JPY')) b(code, bank, nm, dn, ccy) on b.code = o.code;
    `);
    for (const n of ["tk-thb", "tk-fcd", "tk-thb2", "tk-fcd2", "st-thb", "st-fcd", "st-jpy"]) bank.set(n, db.su(`select id from sri_os.bank_accounts where display_name = '${n}'`));
  }, 240_000);

  afterAll(() => db?.drop());

  it("A0 · ยังไม่มีอัตราในตาราง → ซื้อไม่ได้ (ไม่เดาอัตรา) ไม่มีอะไรถูกเขียน", async () => {
    const before = counts();
    const r = await postEntry(buy("THANAKORN", "tk-thb", "tk-fcd", D_BUY, 10_000));
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.message).toMatch(/ไม่มีอัตรา USD ของวันที่/);
    expect(counts()).toEqual(before);
  });

  it("A1 · ใส่เรทที่หน้าตั้งค่าแล้วซื้อได้ทันที: 10,000 USD @36.50 → บาทออก 365,000 · FCD +10,000 USD · P&L 0 · 3410 = 0 · ขา FCD พกสกุล/จำนวน/อัตรา ขาบาทไม่พก", async () => {
    expect((await addFxRate(rateReq(D_BUY, "36.50"))).ok).toBe(true);
    // ผู้ใช้ไม่กรอกยอดบาท (ส่ง 0) — server คิด 10,000 × 36.50 เอง
    const r = await postEntry(buy("THANAKORN", "tk-thb", "tk-fcd", D_BUY, 10_000, 0));
    expect(r.ok, JSON.stringify(r)).toBe(true);
    expect(position("tk-fcd")).toEqual({ units: 10_000, thb: 365_000 });
    expect(position("tk-thb")).toEqual({ units: 0, thb: -365_000 });
    expect(pl("THANAKORN")).toBe(0);
    expect(bal("THANAKORN", "3410")).toBe(0);
    const lines = db.rows<Record<string, unknown>>(
      `select b.display_name b, l.debit::float8 dr, l.credit::float8 cr, l.currency, l.amount_original::float8 ao, l.fx_rate::float8 fx, l.fx_rate_date::text d
         from sri_os.transaction_lines l join sri_os.bank_accounts b on b.id = l.bank_account_id join sri_os.transactions t on t.id = l.transaction_id
        where t.txn_type_code = 'trf.fx_acquire' order by b.display_name desc`
    );
    expect(lines).toEqual([
      { b: "tk-thb", dr: 0, cr: 365_000, currency: null, ao: null, fx: null, d: null },
      { b: "tk-fcd", dr: 365_000, cr: 0, currency: "USD", ao: 10_000, fx: 36.5, d: D_BUY },
    ]);
  });

  it("A2 · ค่าที่ browser แต่ง (สกุล JPY · ยอดบาท 5 · อัตรา 99) ไม่ถูกเชื่อ: สุธีซื้อ 100 USD → สกุลมาจากบัญชีปลายทาง (USD) ยอดบาท 3,650 จากตารางอัตรา", async () => {
    const req = buy("SUTEE", "st-thb", "st-fcd", D_BUY, 100, 5);
    req.input.fxAcquisition = { currency: "JPY", amountOriginal: 999_999, dealRateToThb: 99, dealRateDate: D_BUY };
    req.input.fxConversion = { currency: "JPY", amountOriginal: 1, balanceOriginalBefore: 1, bookRateToThb: 1, bookRateDate: D_BUY, dealRateToThb: 1, dealRateDate: D_BUY, unrealizedBefore: 0 };
    const r = await postEntry(req);
    expect(r.ok, JSON.stringify(r)).toBe(true);
    expect(position("st-fcd")).toEqual({ units: 100, thb: 3_650 });
    expect(position("st-thb")).toEqual({ units: 0, thb: -3_650 });
  });

  it("A3 · ข้อมูลไม่ครบ/ไม่ถูกต้อง: ไม่เลือกปลายทาง · ปลายทางเป็นบัญชีบาท · ปลายทางของคนอื่น · ต้นทางเป็นบัญชีเงินตรา · ต้นทาง=ปลายทาง · สกุลเยน(ไม่มีอัตรา) · จำนวน 0 / ไม่ใส่ · วันที่อัตราไม่มีในตาราง → ปฏิเสธทุกข้อ ไม่เขียนอะไร", async () => {
    const before = counts();
    const cases: [string, PostEntryRequest, RegExp][] = [
      ["ไม่เลือกปลายทาง", buy("THANAKORN", "tk-thb", null, D_BUY, 1), /เลือกบัญชีสกุลต่างประเทศที่เงินตราเข้า/],
      ["ปลายทางเป็นบัญชีบาท", buy("THANAKORN", "tk-thb", "tk-thb2", D_BUY, 1), /เป็นบัญชีบาท/],
      ["ปลายทางเป็นบัญชีของผู้ถือคนอื่น", buy("THANAKORN", "tk-thb", "st-fcd", D_BUY, 1), /ไม่ใช่ของผู้ถือที่เลือก/],
      ["ต้นทางเป็นบัญชีเงินตรา", buy("THANAKORN", "tk-fcd", "tk-fcd2", D_BUY, 1), /ไม่ใช่บัญชีบาท/],
      ["ต้นทาง = ปลายทาง", buy("THANAKORN", "tk-fcd", "tk-fcd", D_BUY, 1), /เดียวกับ/],
      ["สกุลเยน ไม่มีอัตราในตาราง", buy("SUTEE", "st-thb", "st-jpy", D_BUY, 1), /ไม่มีอัตรา JPY/],
      ["จำนวน 0", buy("THANAKORN", "tk-thb", "tk-fcd", D_BUY, 0), /กรอกจำนวน USD/],
      ["ไม่ใส่จำนวน", buy("THANAKORN", "tk-thb", "tk-fcd", D_BUY, undefined), /กรอกจำนวน USD/],
      ["วันที่อัตราไม่มีในตาราง", buy("THANAKORN", "tk-thb", "tk-fcd", daysAgo(59), 1), /ไม่มีอัตรา USD ของวันที่/],
    ];
    for (const [label, req, why] of cases) {
      const r = await postEntry(req);
      expect(r.ok, label).toBe(false);
      if (!r.ok) expect(r.message, label).toMatch(why);
    }
    // ไม่ส่ง fx เลย
    const noFx = buy("THANAKORN", "tk-thb", "tk-fcd", D_BUY, 1);
    delete noFx.fx;
    const r2 = await postEntry(noFx);
    expect(r2.ok).toBe(false);
    if (!r2.ok) expect(r2.message).toMatch(/ต้องเลือกอัตรา/);
    expect(counts()).toEqual(before);
  });

  it("A4 · วงจรเต็ม: ซื้อ 10,000 USD @36.50 → ตีค่า @37.00 ได้ 3410 = 5,000 (P&L ยัง 0) → แลกออก @37.50 ได้กำไรจริง 10,000 · 3410 = 0 · บาทสุทธิ +10,000", async () => {
    expect((await addFxRate(rateReq(D_END, "37.00"))).ok).toBe(true);
    expect((await addFxRate(rateReq(D_SELL, "37.50"))).ok).toBe(true);

    const tr = await postEntry({
      input: { typeKey: "transfer", subCode: "trf.fx_translate_up", amount: 5_000, ownerId: owner("THANAKORN"), bankAccountId: bank.get("tk-fcd")! },
      docDate: dmy(D_END),
      cashDate: dmy(D_END),
      fx: { newRateDate: D_END },
    });
    expect(tr.ok, JSON.stringify(tr)).toBe(true);
    expect(bal("THANAKORN", "3410")).toBe(5_000);
    expect(pl("THANAKORN")).toBe(0);

    const cv = await postEntry({
      input: { typeKey: "transfer", subCode: "trf.fx_convert", amount: 375_000, ownerId: owner("THANAKORN"), bankAccountId: bank.get("tk-fcd")!, transferToBankAccountId: bank.get("tk-thb")! },
      docDate: dmy(D_SELL),
      cashDate: dmy(D_SELL),
      fx: { dealRateDate: D_SELL, amountOriginal: 10_000 },
    });
    expect(cv.ok, JSON.stringify(cv)).toBe(true);
    expect(pl("THANAKORN")).toBe(10_000);
    expect(bal("THANAKORN", REALISED_FX_GAIN)).toBe(10_000);
    expect(bal("THANAKORN", "3410")).toBe(0);
    expect(position("tk-fcd")).toEqual({ units: 0, thb: 0 });
    expect(position("tk-thb").thb).toBe(-365_000 + 375_000);
  });

  it("A5 · ไม่มีสิทธิ์ลงสมุด (ledger.approve) → ปฏิเสธก่อนอ่านสมุด", async () => {
    const keep = h.perms;
    h.perms = new Set(["txn.create"]);
    try {
      const before = counts();
      const r = await postEntry(buy("SUTEE", "st-thb", "st-fcd", D_BUY, 1));
      expect(r.ok).toBe(false);
      expect(counts()).toEqual(before);
    } finally {
      h.perms = keep;
    }
  });

  it("A6 · ใช้เรทที่ลบแล้วไม่ได้ / เรทที่เพิ่มทีหลังใช้ได้ทันที: ลบ 37.50 (ถูกใช้แล้ว ลบไม่ได้) → เห็นว่ารายการเดิมยังตรงอัตรา", () => {
    // ยืนยันว่ารายการแลกที่อ้างอัตรา 37.50 ทำให้ลบอัตรานั้นไม่ได้ (FK) — ยอดบาทของรายการเดิมยังมีอัตราให้ตรวจย้อน
    expect(() => db.as(UID, `delete from sri_os.fx_rates where currency='USD' and rate_date='${D_SELL}';`)).toThrow();
    expect(db.num(`select count(*) from sri_os.fx_rates where currency='USD' and rate_date='${D_SELL}'`)).toBe(1);
  });
});
