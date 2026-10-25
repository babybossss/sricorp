/**
 * แปลงค่าเงินฝากสกุลต่างประเทศ + แลกเป็นบาท **ผ่าน `postEntry` ตัวจริง กับ Postgres จริง** (role authenticated · RLS บังคับ)
 *
 * สิ่งที่พิสูจน์: ฟอร์มส่งแค่ "วันของอัตราที่เลือกจากตาราง + จำนวนเงินตราที่แลก" → server อ่านยอดเงินตรา อัตราที่ยอดบาทตั้งอยู่
 * และผลต่างที่ค้างใน 3410 จากสมุดเอง → engine ประกอบบรรทัด → DB ตรวจ invariant ทั้งหมด · ตัวเลขทุกตัวอ่านจากสมุดที่ DB บันทึก
 *
 * ทางเข้าเงินตราเข้าบัญชี FCD ยังไม่มีในแอป (engine ไม่มีหมวด "รับเงินตรา") จึงตั้งยอดเริ่มต้นด้วย `fn_post_entry` ตรงๆ แบบเดียวกับ
 * `supabase/tests/zz_fcd_currency_test.sql` (นั่นคือ fixture ของเทสต์ ไม่ใช่ส่วนที่ทดสอบ)
 */
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { createTestDb, pgAvailable, type TestDb } from "@/lib/db/import/__tests__/pg-harness";
import { pgClient } from "@/lib/db/import/__tests__/pg-client";

const h = vi.hoisted(() => ({ client: null as unknown, perms: new Set<string>(), uid: "" }));
vi.mock("next/cache", () => ({ revalidatePath: vi.fn() }));
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => h.client }));
vi.mock("@/lib/auth/session", () => ({
  getAccess: async () => ({ user: { id: h.uid, email: "fx@local" }, permissions: h.perms, profile: null, error: null }),
}));

import { postEntry, type PostEntryRequest } from "../post-entry";
import { loadFxContext } from "../fx-context";
import { findSub } from "@/lib/rules/tx-rules";
import { REALISED_FX_GAIN, REALISED_FX_LOSS } from "@/lib/rules/coa";

const UID = "0000000f-0000-4000-8000-0000000000f1";
const dmy = (iso: string) => `${iso.slice(8)}/${iso.slice(5, 7)}/${iso.slice(0, 4)}`;

describe.skipIf(!pgAvailable)("แปลงค่า/แลกเงินตรา ผ่านฟอร์ม → postEntry → Postgres จริง", { timeout: 120_000 }, () => {
  let db: TestDb;
  const bank = new Map<string, string>(); // ชื่อย่อ → id
  const owner = (code: string) => db.su(`select id from sri_os.owners where code='${code}'`);

  const counts = () => ({
    txns: db.num("select count(*) from sri_os.transactions"),
    lines: db.num("select count(*) from sri_os.transaction_lines"),
  });
  /** จำนวนเงินตราและยอดบาทของบัญชีหนึ่ง (สูตรเดียวกับที่ด่านของ DB รวม) */
  const position = (b: string) =>
    db.rows<{ units: number; thb: number }>(
      `select coalesce(sum(case when debit > 0 then amount_original else -amount_original end), 0)::float8 units,
              coalesce(sum(debit - credit), 0)::float8 thb
         from sri_os.v_ledger_posted where bank_account_id = '${bank.get(b)}'`
    )[0];
  const bal = (ownerCode: string, coaCode: string) =>
    db.num(
      `select coalesce(sum(v.credit - v.debit), 0) from sri_os.v_ledger_posted v join sri_os.chart_of_accounts c on c.id = v.coa_id
        where c.code = '${coaCode}' and v.owner_id = '${owner(ownerCode)}'`
    );
  /** กำไรสุทธิตามสมุด (รายได้ − ค่าใช้จ่าย) ของผู้ถือ */
  const pl = (ownerCode: string) =>
    db.num(
      `select coalesce(sum(v.credit - v.debit), 0) from sri_os.v_ledger_posted v join sri_os.chart_of_accounts c on c.id = v.coa_id
        where c.type::text in ('income', 'expense') and v.owner_id = '${owner(ownerCode)}'`
    );

  /** ฝากเงินตรา = fixture (ไม่มีทางทำผ่านแอป) : บาทออกจากบัญชีบาท เงินตราเข้า FCD ที่อัตราที่ระบุ */
  function deposit(ownerCode: string, usd: number, rate: number, rateDate: string, thbBank: string, fcdBank: string) {
    const thb = Math.round(usd * rate * 100) / 100;
    db.su(`begin; set local "test.uid" = '${UID}';
      select sri_os.fn_post_entry(jsonb_build_object(
        'txn_type_code', 'trf.internal', 'doc_date', '${rateDate}', 'cash_date', '${rateDate}',
        'memo', 'fixture: ซื้อ USD ${usd} @${rate} (${ownerCode})',
        'transactions', jsonb_build_array(jsonb_build_object('owner_id', '${owner(ownerCode)}', 'lines', jsonb_build_array(
          jsonb_build_object('coa_code', '1100', 'bank_account_id', '${bank.get(fcdBank)}', 'debit', ${thb}, 'credit', 0, 'cf_category', 'none',
                             'currency', 'USD', 'amount_original', ${usd}, 'fx_rate', ${rate}, 'fx_rate_date', '${rateDate}'),
          jsonb_build_object('coa_code', '1100', 'bank_account_id', '${bank.get(thbBank)}', 'debit', 0, 'credit', ${thb}, 'cf_category', 'none'))))));
      commit;`);
  }

  /** คำขอเหมือนที่ฟอร์มส่ง — ไม่มีตัวเลขอัตรา ไม่มียอดคงเหลือ ไม่มีผลต่างที่ค้าง */
  const req = (ownerCode: string, subCode: string, amount: number, fcd: string, atDate: string, fx: PostEntryRequest["fx"], thbDest?: string): PostEntryRequest => ({
    input: {
      typeKey: findSub(subCode)!.type.key,
      subCode,
      amount,
      ownerId: owner(ownerCode),
      bankAccountId: bank.get(fcd)!,
      ...(thbDest ? { transferToBankAccountId: bank.get(thbDest)! } : {}),
    },
    docDate: dmy(atDate),
    cashDate: dmy(atDate),
    fx,
  });

  beforeAll(() => {
    db = createTestDb();
    h.uid = UID;
    h.perms = new Set(["ledger.approve", "txn.create"]);
    h.client = pgClient(db, UID);
    db.su(`
      insert into auth.users(id) values ('${UID}');
      insert into sri_os.app_users(id, email, display_name, role, is_active) values ('${UID}', 'fx@local', 'mgmt', 'management', true);
      insert into sri_os.user_owner_access(user_id, owner_id) select '${UID}', id from sri_os.owners;
      insert into sri_os.bank_accounts(owner_id, bank, account_name, display_name, currency)
      select o.id, b.bank, b.nm, b.dn, b.ccy from sri_os.owners o join (values
        ('THANAKORN', 'BBL', 'ธนากร', 'tk-thb', 'THB'), ('THANAKORN', 'BBL', 'ธนากร FCD', 'tk-fcd', 'USD'),
        ('SUTEE', 'KBANK', 'สุธี', 'st-thb', 'THB'), ('SUTEE', 'KBANK', 'สุธี FCD', 'st-fcd', 'USD'),
        ('SUDJIT', 'SCB', 'สุดจิตต์', 'sj-thb', 'THB'), ('SUDJIT', 'SCB', 'สุดจิตต์ FCD', 'sj-fcd', 'USD')) b(code, bank, nm, dn, ccy) on b.code = o.code;
      insert into sri_os.fx_rates(currency, rate_date, thb_per_unit, source, note) values
        ('USD', '2026-10-31', 36.50, 'manual', 'ซื้อ / อัตราต่ำ'),
        ('USD', '2026-11-30', 37.00, 'manual', 'สิ้นเดือน พ.ย.'),
        ('USD', '2026-12-15', 36.50, 'manual', 'วันแลก (บาทแข็ง)'),
        ('USD', '2026-12-31', 37.50, 'manual', 'วันแลก / สิ้นปี');
    `);
    for (const n of ["tk-thb", "tk-fcd", "st-thb", "st-fcd", "sj-thb", "sj-fcd"]) bank.set(n, db.su(`select id from sri_os.bank_accounts where display_name = '${n}'`));
    // ธนากร: ซื้อ 10,000 USD @36.50 · สุตี: ซื้อ 10,000 USD @37.00 · สุดจิตต์: 10,000 @36.50 แล้วอีก 10,000 @37.00 (ฝากสองครั้งต่างอัตรา)
    deposit("THANAKORN", 10000, 36.5, "2026-10-31", "tk-thb", "tk-fcd");
    deposit("SUTEE", 10000, 37.0, "2026-11-30", "st-thb", "st-fcd");
    deposit("SUDJIT", 10000, 36.5, "2026-10-31", "sj-thb", "sj-fcd");
    deposit("SUDJIT", 10000, 37.0, "2026-11-30", "sj-thb", "sj-fcd");
  }, 240_000);

  afterAll(() => db?.drop());

  it("X0 · ตั้งต้น: ธนากร 10,000 USD = 365,000 บาท · สุธี 370,000 · สุดจิตต์ 20,000 USD = 735,000 · 3410 ว่าง · P&L = 0", () => {
    expect(position("tk-fcd")).toEqual({ units: 10000, thb: 365000 });
    expect(position("st-fcd")).toEqual({ units: 10000, thb: 370000 });
    expect(position("sj-fcd")).toEqual({ units: 20000, thb: 735000 });
    for (const o of ["THANAKORN", "SUTEE", "SUDJIT"]) {
      expect(bal(o, "3410")).toBe(0);
      expect(pl(o)).toBe(0);
    }
  });

  it("X1 · ฟอร์มอ่านข้อมูลเงินตราจากสมุดได้ (loadFxContext): ยอด · อัตราตามบัญชีที่เป็นแถวจริงในตาราง · ผลต่างที่ค้าง · รายการอัตรา", async () => {
    const r = await loadFxContext({ ownerId: owner("THANAKORN"), bankAccountId: bank.get("tk-fcd")! });
    expect(r.ok, JSON.stringify(r)).toBe(true);
    if (!r.ok) return;
    expect(r.ctx).toMatchObject({ currency: "USD", units: 10000, bookThb: 365000, bookRate: 36.5, unrealized: 0 });
    expect(r.ctx.bookRateRow).toEqual({ currency: "USD", rateDate: "2026-10-31", thbPerUnit: 36.5 });
    expect(r.ctx.rates.map((x) => x.rateDate)).toEqual(["2026-12-31", "2026-12-15", "2026-11-30", "2026-10-31"]);
    // สุดจิตต์ฝากสองอัตรา → ยอดบาทไม่ได้ตั้งอยู่ที่อัตราใดในตาราง (36.75 ไม่มีในตาราง)
    const sj = await loadFxContext({ ownerId: owner("SUDJIT"), bankAccountId: bank.get("sj-fcd")! });
    expect(sj.ok && sj.ctx.bookRate).toBe(36.75);
    expect(sj.ok && sj.ctx.bookRateRow).toBeNull();
    // บัญชีบาท / บัญชีของคนอื่น → ปฏิเสธ
    const thb = await loadFxContext({ ownerId: owner("THANAKORN"), bankAccountId: bank.get("tk-thb")! });
    expect(thb.ok).toBe(false);
    const other = await loadFxContext({ ownerId: owner("SUTEE"), bankAccountId: bank.get("tk-fcd")! });
    expect(other.ok).toBe(false);
  });

  it("X2 · ไม่ส่งข้อมูล: ไม่เลือกอัตรา / อัตราไม่มีในตาราง / ไม่ส่ง fx เลย → ปฏิเสธ ไม่มีอะไรถูกเขียน", async () => {
    const before = counts();
    const sub = "trf.fx_translate_up";
    const none = await postEntry(req("THANAKORN", sub, 5000, "tk-fcd", "2026-11-30", undefined));
    expect(none.ok).toBe(false);
    if (!none.ok) expect(none.message).toMatch(/ต้องเลือกอัตรา/);
    const noDate = await postEntry(req("THANAKORN", sub, 5000, "tk-fcd", "2026-11-30", {}));
    expect(noDate.ok).toBe(false);
    if (!noDate.ok) expect(noDate.message).toMatch(/เลือกอัตราสิ้นงวด/);
    const missing = await postEntry(req("THANAKORN", sub, 5000, "tk-fcd", "2026-11-30", { newRateDate: "2026-11-29" }));
    expect(missing.ok).toBe(false);
    if (!missing.ok) expect(missing.message).toMatch(/ไม่มีอัตรา USD ของวันที่ 2026-11-29/);
    const noBank = await postEntry({ ...req("THANAKORN", sub, 5000, "tk-fcd", "2026-11-30", { newRateDate: "2026-11-30" }), input: { ...req("THANAKORN", sub, 5000, "tk-fcd", "2026-11-30", {}).input, bankAccountId: "" } });
    expect(noBank.ok).toBe(false);
    expect(counts()).toEqual(before);
  });

  it("X3 · ค่าที่ browser แต่งมา (ยอดคงเหลือ · อัตรา · ผลต่าง) ไม่ถูกเชื่อ — server อ่านจากสมุดเอง · ยอดผิดถูก engine ปฏิเสธ", async () => {
    const before = counts();
    const forged = req("THANAKORN", "trf.fx_translate_up", 5000, "tk-fcd", "2026-11-30", { newRateDate: "2026-11-30" });
    forged.input.fxTranslation = {
      currency: "USD", balanceOriginal: 1_000_000, bookRateToThb: 1, bookRateDate: "2026-10-31", newRateToThb: 99, newRateDate: "2026-11-30",
    };
    // ยอดที่แต่งไม่ตรงกับสมุด → ถ้าเชื่อค่าแต่ง ผลต่างจะเป็นหลายล้าน · ที่ถูกคือ 5,000 และใบนี้ต้องผ่านด้วยค่าจากสมุด
    // (ลงจริงในเคสถัดไป · ที่นี่พิสูจน์ด้านลบ: ยอดเงินที่ผู้ใช้ "เห็น" ไม่ตรงกับสมุด → ปฏิเสธ)
    const wrongAmount = await postEntry({ ...forged, input: { ...forged.input, amount: 1_000_000 } });
    expect(wrongAmount.ok).toBe(false);
    if (!wrongAmount.ok) expect(wrongAmount.message).toMatch(/ผลต่างจากการแปลงค่าคือ 5,000 บาท/);
    expect(counts()).toEqual(before);

    const ok = await postEntry(forged);
    expect(ok.ok, JSON.stringify(ok)).toBe(true);
    // ผลคือค่าจากสมุด: ยอดบาท = 10,000 USD × 37.00 = 370,000 ไม่ใช่ 1,000,000 × 99
    expect(position("tk-fcd")).toEqual({ units: 10000, thb: 370000 });
    expect(bal("THANAKORN", "3410")).toBe(5000);
  });

  it("X4 · แปลงค่า (ยอดบาทเพิ่ม) ที่ 36.50→37.00: ผลต่าง 5,000 เข้า 3410 · เงินตราเท่าเดิม · P&L ไม่ขยับ · บรรทัดมีสกุล/อัตรา/วันที่ครบ", () => {
    expect(position("tk-fcd")).toEqual({ units: 10000, thb: 370000 });
    expect(bal("THANAKORN", "3410")).toBe(5000);
    expect(pl("THANAKORN")).toBe(0);
    const lines = db.rows<Record<string, unknown>>(
      `select c.code, l.debit::float8 dr, l.credit::float8 cr, l.currency, l.amount_original::float8 ao, l.fx_rate::float8 fx, l.fx_rate_date::text d
         from sri_os.transaction_lines l join sri_os.chart_of_accounts c on c.id = l.coa_id
         join sri_os.transactions t on t.id = l.transaction_id where t.txn_type_code = 'trf.fx_translate_up' order by c.code`
    );
    expect(lines).toEqual([
      { code: "1100", dr: 5000, cr: 0, currency: "USD", ao: 0, fx: 37, d: "2026-11-30" },
      { code: "3410", dr: 0, cr: 5000, currency: "USD", ao: 0, fx: 37, d: "2026-11-30" },
    ]);
  });

  it("X5 · ใช้หมวดผิดทิศ (ยอดบาทเพิ่มแต่เลือกหมวด 'ลด') → ปฏิเสธ ไม่กลับเครื่องหมายให้ · สมุดไม่ขยับ", async () => {
    const before = counts();
    // สุธี: 370,000 → ตีที่ 37.50 ยอดบาทเพิ่ม 5,000 แต่เลือกหมวด 'ลด'
    const r = await postEntry(req("SUTEE", "trf.fx_translate_down", 5000, "st-fcd", "2026-12-31", { newRateDate: "2026-12-31" }));
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.message).toMatch(/ต้องใช้หมวดให้ตรงทิศ/);
    expect(counts()).toEqual(before);
  });

  it("X6 · แลกบางส่วน: 4,000 USD @37.50 → กำไรจริง 4,000 เข้า P&L (4330) · ล้าง 3410 ตามสัดส่วน 2,000 · เหลือ 3,000 · บัญชีเหลือ 6,000 USD", async () => {
    const r = await postEntry(req("THANAKORN", "trf.fx_convert", 150_000, "tk-fcd", "2026-12-31", { dealRateDate: "2026-12-31", amountOriginal: 4000 }, "tk-thb"));
    expect(r.ok, JSON.stringify(r)).toBe(true);
    expect(position("tk-fcd")).toEqual({ units: 6000, thb: 222_000 }); // 370,000 − 4,000×37.00
    expect(position("tk-thb")).toEqual({ units: 0, thb: -365_000 + 150_000 });
    expect(bal("THANAKORN", "3410")).toBe(3000); // 5,000 − 5,000×4,000/10,000
    expect(bal("THANAKORN", REALISED_FX_GAIN)).toBe(4000); // 4,000 × (37.50 − 36.50)
    expect(pl("THANAKORN")).toBe(4000);
  });

  it("X7 · แลกส่วนที่เหลือทั้งหมด: กำไรรวม 10,000 (= 10,000 × (37.50 − 36.50)) · 3410 เหลือศูนย์พอดี · บัญชี FCD เหลือ 0 ทั้งเงินตราและบาท", async () => {
    const r = await postEntry(req("THANAKORN", "trf.fx_convert", 225_000, "tk-fcd", "2026-12-31", { dealRateDate: "2026-12-31", amountOriginal: 6000 }, "tk-thb"));
    expect(r.ok, JSON.stringify(r)).toBe(true);
    expect(position("tk-fcd")).toEqual({ units: 0, thb: 0 });
    expect(bal("THANAKORN", "3410")).toBe(0);
    expect(pl("THANAKORN")).toBe(10_000);
    expect(position("tk-thb").thb).toBe(-365_000 + 150_000 + 225_000); // บาทที่จ่ายซื้อ 365,000 → ได้คืน 375,000 → +10,000
  });

  it("X8 · แลก USD 10,000 ที่ถือ @37.00 ออกที่ 36.50 → ขาดทุน 5,000 เข้า P&L (5930) · 3410 เป็น 0 ไม่ติดลบ · บัญชีเหลือ 0 (ตัวเลขของลูกพี่)", async () => {
    expect(bal("SUTEE", "3410")).toBe(0);
    const r = await postEntry(req("SUTEE", "trf.fx_convert", 365_000, "st-fcd", "2026-12-15", { dealRateDate: "2026-12-15", amountOriginal: 10000 }, "st-thb"));
    expect(r.ok, JSON.stringify(r)).toBe(true);
    expect(pl("SUTEE")).toBe(-5000);
    expect(bal("SUTEE", REALISED_FX_LOSS)).toBe(-5000); // เดบิต 5,000 ในบัญชีขาดทุน
    expect(bal("SUTEE", "3410")).toBe(0);
    expect(position("st-fcd")).toEqual({ units: 0, thb: 0 });
    expect(position("st-thb")).toEqual({ units: 0, thb: -370_000 + 365_000 });
  });

  it("X9 · ยอดบาทของบัญชีไม่ตั้งอยู่ที่อัตราใดในตาราง (ฝากสองอัตรา) → แลกไม่ได้ ต้องแปลงค่าก่อน · แล้วแปลงค่าได้ · แล้วแลกได้", async () => {
    const before = counts();
    const refused = await postEntry(req("SUDJIT", "trf.fx_convert", 187_500, "sj-fcd", "2026-12-31", { dealRateDate: "2026-12-31", amountOriginal: 5000 }, "sj-thb"));
    expect(refused.ok).toBe(false);
    if (!refused.ok) expect(refused.message).toMatch(/ให้ลงรายการ “แปลงค่า” เป็นอัตราหนึ่งก่อน/);
    expect(counts()).toEqual(before);

    // แปลงค่าไปที่ 37.50: 20,000 × 37.50 = 750,000 (เดิม 735,000) → ผลต่าง 15,000
    const tr = await postEntry(req("SUDJIT", "trf.fx_translate_up", 15_000, "sj-fcd", "2026-12-31", { newRateDate: "2026-12-31" }));
    expect(tr.ok, JSON.stringify(tr)).toBe(true);
    expect(position("sj-fcd")).toEqual({ units: 20000, thb: 750_000 });
    expect(bal("SUDJIT", "3410")).toBe(15_000);

    // แลก 5,000 @37.50: บาทเข้า 187,500 · ตัดตามบัญชี 187,500 · ล้าง 3410 = 15,000×5,000/20,000 = 3,750 → กำไรจริง 3,750 (= 5,000 × (37.50 − 36.75))
    const cv = await postEntry(req("SUDJIT", "trf.fx_convert", 187_500, "sj-fcd", "2026-12-31", { dealRateDate: "2026-12-31", amountOriginal: 5000 }, "sj-thb"));
    expect(cv.ok, JSON.stringify(cv)).toBe(true);
    expect(position("sj-fcd")).toEqual({ units: 15000, thb: 562_500 });
    expect(bal("SUDJIT", "3410")).toBe(11_250);
    expect(pl("SUDJIT")).toBe(3750);
  });

  it("X10 · แลกมากกว่ายอดคงเหลือ / ไม่ใส่จำนวนที่แลก / จำนวนติดลบ / ปลายทางไม่ใช่บัญชีบาท → ปฏิเสธ ไม่เขียนอะไร", async () => {
    const before = counts();
    const base = (fx: PostEntryRequest["fx"], dest = "sj-thb") => req("SUDJIT", "trf.fx_convert", 1, "sj-fcd", "2026-12-31", fx, dest);
    const over = await postEntry(base({ dealRateDate: "2026-12-31", amountOriginal: 15_001 }));
    expect(over.ok).toBe(false);
    if (!over.ok) expect(over.message).toMatch(/มากกว่ายอดคงเหลือ/);
    const noAmt = await postEntry(base({ dealRateDate: "2026-12-31" }));
    expect(noAmt.ok).toBe(false);
    if (!noAmt.ok) expect(noAmt.message).toMatch(/กรอกจำนวน USD ที่จะแลก/);
    const neg = await postEntry(base({ dealRateDate: "2026-12-31", amountOriginal: -5 }));
    expect(neg.ok).toBe(false);
    const toFcd = await postEntry(base({ dealRateDate: "2026-12-31", amountOriginal: 10 }, "tk-fcd"));
    expect(toFcd.ok).toBe(false);
    expect(counts()).toEqual(before);
  });

  it("X11 · ไม่มีสิทธิ์ลงสมุด (ledger.approve) → ปฏิเสธก่อนอ่านสมุด", async () => {
    const keep = h.perms;
    h.perms = new Set(["txn.create"]);
    try {
      const before = counts();
      const r = await postEntry(req("SUTEE", "trf.fx_translate_up", 1, "st-fcd", "2026-12-31", { newRateDate: "2026-12-31" }));
      expect(r.ok).toBe(false);
      expect(counts()).toEqual(before);
    } finally {
      h.perms = keep;
    }
  });
});
