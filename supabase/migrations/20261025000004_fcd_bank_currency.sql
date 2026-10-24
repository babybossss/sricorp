-- ============================================================
-- SRI OS · บัญชีเงินฝากสกุลต่างประเทศ (FCD) — สกุลเงินที่บัญชีและที่บรรทัดบัญชี
--
-- **รูที่ปิด** ลูกพี่ยืนยัน 25/10 ว่ามีบัญชี FCD จริง แต่ `sri_os.bank_accounts`
--   **ไม่มีคอลัมน์สกุลเงินเลย** ขณะที่ `assets` มีครบตั้งแต่ D-111 ข้อ 2
--   → บัญชีที่ถือ USD ถูกนับเป็นบาททั้งก้อน **ยอดเงินสดในงบผิดเงียบๆ
--   ไม่มีด่านไหนจับได้** และถ้ากรอกยอดตั้งต้นเป็นบาทไปแล้ว ข้อมูลว่าจริงๆ
--   เป็นเงินตราเท่าไร **หายถาวร ย้อนไม่ได้** (ปัญหาเดียวกับต้นทุนรายล็อต)
--
-- ------------------------------------------------------------
-- **เก็บที่ระดับไหน — ตัดสินจากสคีมาที่มีอยู่ ไม่คิดรูปที่สาม**
--
--   `asset_valuations` เก็บ `currency` · `value_original` · `fx_rate` · `fx_rate_date`
--   แล้วให้ `value` เป็น **ยอดบาทเสมอ** (20261024000001 ข้อ 3)
--   → ไฟล์นี้ใช้รูปเดียวกันกับ `transaction_lines`:
--       `currency` · `amount_original` · `fx_rate` · `fx_rate_date`
--     และ `debit`/`credit` ยัง**เป็นบาทเสมอ** เหมือนเดิมทุกบรรทัด
--
--   **ที่ระดับบรรทัด ไม่ใช่ที่หัวรายการ** เพราะสกุลเงินเป็นคุณสมบัติของ
--   **บัญชีที่บรรทัดนั้นลง** ไม่ใช่ของเอกสาร: ใบแลกเงินใบเดียวมีขา USD กับขา THB
--   อยู่ด้วยกัน (และใบเดียวมีขา 3410 ที่เป็นผลต่างของสกุลนั้นอีกขา)
--   ถ้าเก็บที่หัวรายการ ใบนั้นจะต้องเลือกสกุลเดียวให้ทั้งใบ = เก็บไม่ได้เลย
--   (รูปเดียวกับที่ `bank_account_id` อยู่ที่บรรทัด ไม่ใช่ที่หัวรายการ)
--
--   **functional currency ยังเป็นบาท** — `Σ debit = Σ credit` ตรวจที่ยอดบาท
--   เหมือนเดิมทุกบรรทัด (ไม่แตะ trg_assert_balanced เลย) · ยอดสกุลเดิมเป็น
--   **ข้อมูลประกอบ** สำหรับกระทบยอดกับ statement ของธนาคารที่เป็นสกุลนั้น
--
-- ------------------------------------------------------------
-- **บัญชีที่เพิ่มในผังบัญชี** (seed มาจาก src/lib/rules/coa.ts · 20261024181010)
--   `3410` ผลต่างอัตราแลกเปลี่ยนจากการแปลงค่า (ยังไม่เกิดขึ้นจริง) · **equity**
--   `4330` กำไรจากอัตราแลกเปลี่ยน (เกิดขึ้นจริง) · income
--   `5930` ขาดทุนจากอัตราแลกเปลี่ยน (เกิดขึ้นจริง) · expense
--
--   **ห้ามใช้รหัส 11xx** เพราะ `isCashAccount()` = `^11\d\d$` จะอ่านว่าเป็นเงินสด
--   (เหตุผลเดียวกับที่ 1290 ค่าเผื่อหนี้สงสัยจะสูญเลือกรหัสนอกช่วงนั้น)
--
--   ประเภทบัญชีคือตัวบังคับกฎของลูกพี่ (*กำไร/ขาดทุนค่าเงินที่ยังไม่เกิดจริง
--   ห้ามเข้า P&L เด็ดขาด*): 3410 เป็น `equity` → `effectOf()` ไม่มีทางพามันเข้า
--   งบกำไรขาดทุนได้เลย ไม่ใช่การกันที่ชั้นรายงาน
--
-- ------------------------------------------------------------
-- **ด่านที่ไฟล์นี้เพิ่ม (ไม่ใช่แค่คอลัมน์)**
--
--   (ก) `fn_assert_line_fx()` — บรรทัดเงินสดของบัญชีที่ **ไม่ใช่บาท** ต้องมี
--       สกุล + ยอดสกุลเดิม + อัตรา + วันของอัตรา **ครบทุกช่อง** ไม่งั้น **ปฏิเสธ**
--       ไม่ใช่สมมติว่าอัตรา = 1 (บทเรียนข้อ 1: ข้อมูลไม่ครบต้องปฏิเสธ)
--       และยอดบาทต้องเท่ากับ `round(ยอดสกุลเดิม × อัตรา, 2)` — ยอดบาทที่ไม่ได้
--       มาจากอัตราคือตัวเลขที่ไม่มีใครตรวจย้อนได้ว่ามาจากไหน
--   (ข) FK `(currency, fx_rate_date)` → `fx_rates` — **อัตราต้องมีอยู่จริงในตาราง**
--       (รูปเดียวกับ asset_valuations) → เดาอัตราเองไม่ได้ที่ชั้นฐานข้อมูล
--   (ค) `fn_assert_revaluation_no_pl()` + `fn_assert_revaluation_type_stays_clean()`
--       ขยายให้ครอบ 3410 ด้วย (เดิมครอบแต่ 3400) → หมวดแปลงค่า **แตะบัญชี
--       รายได้/ค่าใช้จ่ายไม่ได้เลยแม้แต่บรรทัดเดียว** และแก้ตารางกฎให้แตะก็ไม่ได้
--   (ง) `fn_assert_line_coa_in_rules()` ยอมให้บรรทัด 3410 ลงได้บนหมวดที่
--       **ประกาศบัญชีกำไร/ขาดทุนค่าเงินไว้** (คือหมวดแลกเป็นบาทจริง) —
--       รูปเดียวกับที่ยอมให้ 3400 ลงได้บนหมวดที่รับรู้กำไรจากการขายทรัพย์
--   (จ) `fn_assert_fx_unrealized_cleared()` — แลกเงินตราออกหมดแล้ว
--       **3410 ของสกุลนั้นต้องเหลือศูนย์พอดี** ไม่งั้นผลต่างค้างในส่วนของเจ้าของ
--       ตลอดไปและถูกนับซ้ำกับกำไรที่รับรู้ (บทเรียนข้อ 7 ในรูปของค่าเงิน)
--
--   **บัญชี FCD ยังเป็นเงินสด (11xx) ตามเดิม** → ด่าน cash_date · Money Invariant 2
--   (ไม่มีเงินลอย) · งบกระแสเงินสด ทำงานเหมือนเดิมทุกอย่าง
--   ส่วนยอดบาทที่ขยับเพราะอัตรา `cashflow.ts` เก็บเป็นบรรทัด
--   "ผลกระทบของอัตราแลกเปลี่ยนต่อเงินสด" (IAS 7.28) ไม่ใช่กระแสเงินสดของงวด
--
-- ------------------------------------------------------------
-- **ของเดิมต้องไม่พัง** `bank_accounts.currency` มี `default 'THB'` และ
--   `not null` → แถวที่มีอยู่ได้ THB ทั้งหมดในคำสั่งเดียว (backfill โดย default)
--   บรรทัดบัญชีของบัญชีบาทต้อง **ไม่มี** ข้อมูลอัตรา (ด่าน ก ข้อ 2) จึงลงได้
--   เหมือนเดิมทุกใบโดยไม่ต้องแก้อะไรฝั่งเรียก
--
-- ลำดับ: **ต้องรันหลัง 20261024000001_wht_and_fx.sql** (ใช้ตาราง `fx_rates` ·
--   เขียนทับ fn_assert_revaluation_no_pl / fn_assert_revaluation_type_stays_clean /
--   fn_assert_line_coa_in_rules ของไฟล์นั้น) · **หลัง 20261020000002** (ด่านคอลัมน์
--   ของสมุดเงิน — ไฟล์นี้เพิ่มคอลัมน์ให้ตารางที่ถูกจัดประเภทแล้ว) ·
--   **หลัง 20261024181010_seed_rules.sql** (ต้องมีรหัส 3410/4330/5930 ในผังบัญชี
--   และหมวด trf.fx_* ในตารางกฎ ไม่งั้น guard ท้ายไฟล์ดัง) ·
--   และ **ก่อน 20261020000003_replay_end_state_guard.sql** (ไฟล์สุดท้ายเสมอ)
--   → วางต่อท้าย 20261025000003 ได้เลย · ผมไม่แก้ migration-order.txt / UNDER_TEST เอง
--
-- idempotent: add column if not exists · drop constraint/trigger if exists ก่อน add ·
--   create or replace function · insert ... on conflict do update → replay ซ้ำได้ตลอด
--
-- ย้อนกลับ (rollback) — เรียงจากหลังมาหน้า:
--   -- drop trigger  if exists trg_assert_fx_unrealized_cleared on sri_os.transaction_lines;
--   -- drop function if exists sri_os.fn_assert_fx_unrealized_cleared();
--   -- drop function if exists sri_os.fn_assert_fx_unrealized_cleared_for(uuid);
--   -- drop trigger  if exists trg_lines_fx_shape on sri_os.transaction_lines;
--   -- drop function if exists sri_os.fn_assert_line_fx();
--   -- drop function if exists sri_os.fn_bank_account_currency(uuid);
--   -- รัน 20261024000001_wht_and_fx.sql ซ้ำ (คืน fn_assert_revaluation_no_pl ·
--   --   fn_assert_revaluation_type_stays_clean รุ่นที่ครอบแต่ 3400)
--   -- รัน 20261025000001_wht_post_entry.sql ซ้ำ ถ้าต้องการคืน fn_assert_line_coa_in_rules
--   --   รุ่นก่อนไฟล์นี้ (รุ่นนั้นไม่รู้จัก 3410)
--   -- delete from sri_os.column_exposure where (table_name = 'transaction_lines'
--   --   and column_name in ('currency','amount_original','fx_rate','fx_rate_date'))
--   --   or (table_name = 'bank_accounts' and column_name = 'currency');
--   -- select sri_os.fn_apply_column_exposure();
--   -- alter table sri_os.transaction_lines drop constraint if exists transaction_lines_fx_shape;
--   -- alter table sri_os.transaction_lines drop constraint if exists transaction_lines_fx_rate_fk;
--   -- alter table sri_os.transaction_lines drop column if exists fx_rate_date,
--   --   drop column if exists fx_rate, drop column if exists amount_original,
--   --   drop column if exists currency;                  -- (ลบคอลัมน์ = ลบข้อมูลสกุลเดิมถาวร)
--   -- alter table sri_os.bank_accounts drop constraint if exists bank_accounts_currency_allowed;
--   -- alter table sri_os.bank_accounts drop column if exists currency;
--   -- ย้อนแล้วได้สภาพเดิมคือ **บัญชี USD ถูกนับเป็นบาททั้งก้อน** — ไม่แนะนำให้ย้อน
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 0 · pre-flight — **ดังก่อนแตะอะไรเลย** ถ้าลำดับยังไม่ถูกลงทะเบียน
--
-- ไฟล์นี้พึ่งของสามอย่างที่มาจากไฟล์อื่น: ตาราง `fx_rates` (20261024000001) ·
-- รหัส 3410/4330/5930 ในผังบัญชี และหมวด trf.fx_* (ไฟล์ seed ที่ generate ด้วย
-- npm run sync:rules) · ตัวจริงที่ apply ของจริงใช้ `--single-transaction`
-- จึงไม่มีสภาพครึ่งๆ แต่ harness ในเครื่องรันทีละคำสั่ง → ถ้าไฟล์นี้ล้มกลางทาง
-- จะเหลือ `bank_accounts.currency` ที่ยังไม่ได้จัดประเภทในด่านคอลัมน์ แล้ว
-- **ไฟล์อื่นพังตามเป็นลูกโซ่** ด้วยข้อความที่ชี้ผิดจุด
-- → ตรวจของที่ต้องมีทั้งหมดก่อน แล้วค่อยแตะ schema
-- ============================================================
do $$
declare v text;
begin
  if to_regclass('sri_os.fx_rates') is null then
    raise exception 'ยังไม่มีตาราง sri_os.fx_rates — ไฟล์นี้ต้องรันหลัง 20261024000001_wht_and_fx.sql · ลงทะเบียนลำดับใน supabase/migration-order.txt และ UNDER_TEST ของ scripts/test-rls-local.sh ก่อน (ไฟล์นี้วางต่อท้าย 20261025000003)';
  end if;

  select string_agg(x.code, ', ' order by x.code) into v
    from unnest(array['3410', '4330', '5930']) x(code)
   where not exists (select 1 from sri_os.chart_of_accounts c where c.code = x.code);
  if v is not null then
    raise exception 'ผังบัญชีใน DB ยังไม่มีรหัส % — apply ไฟล์ seed_rules ที่ generate ด้วย npm run sync:rules ก่อน (ไฟล์นี้เป็นด่าน ไม่ใช่ที่เก็บแถวของตารางกฎ)', v;
  end if;

  select string_agg(x.code, ', ' order by x.code) into v
    from unnest(array['trf.fx_translate_up', 'trf.fx_translate_down', 'trf.fx_convert']) x(code)
   where not exists (select 1 from sri_os.txn_types t where t.code = x.code);
  if v is not null then
    raise exception 'ตารางกฎใน DB ยังไม่มีหมวด % — apply ไฟล์ seed_rules ก่อน', v;
  end if;

  if to_regclass('sri_os.v_ledger_posted') is null then
    raise exception 'ยังไม่มีวิว sri_os.v_ledger_posted — ไฟล์นี้ต้องรันหลัง 20261020000001_void_columns_and_views.sql';
  end if;
end $$;

-- ============================================================
-- 1 · bank_accounts.currency — **สำเนาของ CURRENCIES ใน src/lib/rules/currency.ts**
--     (ชุดเดียวกับที่ assets.currency ใช้ · ไม่สร้างรายการสกุลเงินชุดที่สอง)
-- ============================================================
alter table bank_accounts add column if not exists currency text not null default 'THB';

alter table bank_accounts drop constraint if exists bank_accounts_currency_allowed;
alter table bank_accounts
  add constraint bank_accounts_currency_allowed check (currency in ('THB', 'USD', 'JPY', 'CNY'));

comment on column bank_accounts.currency is
  'สกุลเงินของบัญชี · ค่าตั้งต้น THB (แถวเดิมทั้งหมดได้ค่านี้) · บัญชีเงินฝากสกุลต่างประเทศ (FCD) ต้องตั้งเป็นสกุลจริง ไม่งั้นยอดเงินสดในงบจะนับเงินตราเป็นบาททั้งก้อน · สำเนาของ CURRENCIES ใน src/lib/rules/currency.ts ชุดเดียวกับ assets.currency';

-- ============================================================
-- 2 · transaction_lines · สกุลเดิม + ยอดสกุลเดิม + อัตรา + วันของอัตรา
--     **ยอดบาทยังอยู่ที่ debit/credit เหมือนเดิม** (functional currency = บาท)
-- ============================================================
alter table transaction_lines
  add column if not exists currency        text,
  add column if not exists amount_original numeric(18,6),
  add column if not exists fx_rate         numeric(18,8),
  add column if not exists fx_rate_date    date;

comment on column transaction_lines.currency is
  'สกุลของยอดสกุลเดิมของบรรทัดนี้ · null = บรรทัดบาทตรงๆ (บัญชีบาททุกบัญชีและทุกบรรทัดที่ไม่เกี่ยวกับเงินตรา)';
comment on column transaction_lines.amount_original is
  'ยอดในสกุลเดิมของบรรทัดนี้ (ไม่มีเครื่องหมาย · ทิศมาจาก debit/credit เหมือนยอดบาท) · **0 = ไม่มีเงินตราเคลื่อน** ซึ่งเกิดได้เฉพาะบรรทัดของการแปลงค่า (ยอดบาทขยับเพราะอัตรา) — ด่าน fn_assert_line_fx บังคับ';
comment on column transaction_lines.fx_rate is
  'อัตราที่ใช้แปลงเป็นบาท (บาทต่อหน่วย · ทิศเดียวในระบบ) · ยอดบาทต้องเท่ากับ round(amount_original × fx_rate, 2) เมื่อมีเงินตราเคลื่อน';
comment on column transaction_lines.fx_rate_date is
  'วันของอัตราที่ใช้ · ต้องมีแถวใน fx_rates ตาม FK → เดาอัตราเองไม่ได้';

-- รูปร่าง: ครบทั้งชุดหรือไม่มีเลย · บาทต้องอัตรา 1 · ยอดสกุลเดิมติดลบไม่ได้
alter table transaction_lines drop constraint if exists transaction_lines_fx_shape;
alter table transaction_lines
  add constraint transaction_lines_fx_shape check (
    (currency is null and amount_original is null and fx_rate is null and fx_rate_date is null)
    or (
      currency is not null
      and amount_original is not null and amount_original >= 0
      and fx_rate is not null and fx_rate > 0
      and fx_rate_date is not null
      and (currency <> 'THB' or fx_rate = 1)
    )
  );

-- อัตราต้องมีอยู่จริงในตารางอัตรา (รูปเดียวกับ asset_valuations_fx_rate_fk)
alter table transaction_lines drop constraint if exists transaction_lines_fx_rate_fk;
alter table transaction_lines
  add constraint transaction_lines_fx_rate_fk
  foreign key (currency, fx_rate_date) references fx_rates(currency, rate_date);

-- ============================================================
-- 2b · วิวสมุดเงินต้องเห็นคอลัมน์ใหม่ด้วย
--
-- `v_ledger_posted` / `v_ledger_voided` ประกาศคอลัมน์ไว้ **ทีละชื่อ** (D-098)
-- → คอลัมน์ที่เพิ่มเข้าตารางไม่โผล่ในวิวเอง และทุกอย่างที่อ่านสมุดต้องอ่านผ่านวิว
--   (ด่าน D-098 ห้าม view/ฟังก์ชันรายงานอ่านตารางฐานตรงๆ)
-- ถ้าไม่เติมที่นี่ ด่านของไฟล์นี้เอง (`fn_assert_fx_unrealized_cleared_for`)
-- และรายงานยอดเงินตราทุกตัว **อ่านยอดสกุลเดิมไม่ได้เลย** (คอลัมน์ไม่มีในวิว)
--
-- เติม **ต่อท้าย** เท่านั้น: `create or replace view` เปลี่ยนชื่อ/ชนิด/ลำดับของ
-- คอลัมน์เดิมไม่ได้ และผู้เรียกทุกตัวอ่านด้วยชื่อคอลัมน์ จึงไม่กระทบของเดิม
-- ============================================================
create or replace view v_ledger_posted with (security_invoker = true) as
select
  t.id                  as transaction_id,
  t.owner_id,
  t.txn_type_code,
  t.doc_date,
  t.cash_date,
  t.doc_no,
  t.status,
  t.asset_id            as txn_asset_id,
  t.contact_id,
  t.contract_id,
  t.is_intercompany,
  t.counter_owner_id,
  t.intercompany_nature,
  t.memo                as txn_memo,
  t.attachments,
  t.source,
  t.source_ref,
  t.reverses_id,
  t.created_by,
  t.approved_by,
  t.created_at,
  l.id                  as line_id,
  l.coa_id,
  l.bank_account_id,
  l.debit,
  l.credit,
  l.cf_category,
  l.asset_id            as line_asset_id,
  l.memo                as line_memo,
  -- FCD (25/10) · ข้อมูลสกุลเดิมของบรรทัด — **ต่อท้ายคอลัมน์เดิมเท่านั้น**
  -- (`create or replace view` เพิ่มคอลัมน์ได้แค่ท้ายสุด และห้ามเปลี่ยนชื่อ/ชนิดของเดิม)
  l.currency,
  l.amount_original,
  l.fx_rate,
  l.fx_rate_date
from transactions t
join transaction_lines l on l.transaction_id = t.id
-- allow-list ไม่ใช่ <> 'void' — เหตุผลอยู่หัวไฟล์ (ค่าสถานะใหม่ต้องไม่ไหลเข้างบเอง)
where t.status = 'posted';

alter view v_ledger_posted set (security_invoker = true);

create or replace view v_ledger_voided with (security_invoker = true) as
select
  t.id                  as transaction_id,
  t.owner_id,
  t.txn_type_code,
  t.doc_date,
  t.cash_date,
  t.doc_no,
  t.status,
  t.asset_id            as txn_asset_id,
  t.contact_id,
  t.contract_id,
  t.is_intercompany,
  t.counter_owner_id,
  t.intercompany_nature,
  t.memo                as txn_memo,
  t.attachments,
  t.source,
  t.source_ref,
  t.reverses_id,
  t.created_by,
  t.approved_by,
  t.created_at,
  t.voided_at,
  t.voided_by,
  t.void_reason,
  l.id                  as line_id,
  l.coa_id,
  l.bank_account_id,
  l.debit,
  l.credit,
  l.cf_category,
  l.asset_id            as line_asset_id,
  l.memo                as line_memo,
  -- FCD (25/10) · ข้อมูลสกุลเดิมของบรรทัด — **ต่อท้ายคอลัมน์เดิมเท่านั้น**
  -- (`create or replace view` เพิ่มคอลัมน์ได้แค่ท้ายสุด และห้ามเปลี่ยนชื่อ/ชนิดของเดิม)
  l.currency,
  l.amount_original,
  l.fx_rate,
  l.fx_rate_date
from transactions t
join transaction_lines l on l.transaction_id = t.id
where t.status = 'void';

alter view v_ledger_voided set (security_invoker = true);

-- สิทธิ์: create or replace view ไม่ล้าง ACL เดิม แต่ย้ำไว้ให้ไฟล์นี้รันเองได้
revoke all on v_ledger_posted from public;
revoke all on v_ledger_voided from public;
do $$
begin
  execute 'revoke all on sri_os.v_ledger_posted from anon';
  execute 'revoke all on sri_os.v_ledger_voided from anon';
  execute 'grant select on sri_os.v_ledger_posted to authenticated';
  execute 'grant select on sri_os.v_ledger_voided to authenticated';
end $$;

-- ============================================================
-- 3 · fn_bank_account_currency — สกุลของบัญชีธนาคาร (ถามที่เดียว)
--     security definer: ด่านต้องได้ **คำตอบจริง** ไม่ใช่ null เพราะผู้เรียก
--     มองแถวบัญชีนั้นไม่เห็น (เหตุผลเดียวกับ fn_assert_line_bank_owner)
-- ============================================================
create or replace function fn_bank_account_currency(p_bank uuid) returns text
language sql stable security definer set search_path = '' as $fn$
  select b.currency from sri_os.bank_accounts b where b.id = p_bank;
$fn$;

comment on function fn_bank_account_currency(uuid) is
  'สกุลเงินของบัญชีธนาคาร · ใช้โดยด่าน fn_assert_line_fx เพื่อบังคับว่าบรรทัดของบัญชีที่ไม่ใช่บาทต้องมีอัตราแลกเปลี่ยนครบ';

revoke all on function fn_bank_account_currency(uuid) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_bank_account_currency(uuid) from anon, authenticated';
end $$;

-- ============================================================
-- 4 · ด่าน: บรรทัดของบัญชีที่ไม่ใช่บาท **ต้องมีอัตรา** และยอดบาทต้องมาจากอัตรา
-- ============================================================
create or replace function fn_assert_line_fx() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_code     text;
  v_bank_ccy text;
  v_label    text;
  v_thb      numeric;
  v_expected numeric;
  v_type     text;
  v_is_xlate boolean;
begin
  select c.code into v_code
    from sri_os.chart_of_accounts c where c.id = new.coa_id;
  if v_code is null then
    return new;   -- ด่านคู่บัญชีปฏิเสธด้วยข้อความของมันเอง
  end if;

  v_thb := coalesce(new.debit, 0) + coalesce(new.credit, 0);

  -- ---------- (1) บัญชีที่ไม่ใช่บาท: ต้องมีข้อมูลอัตราครบ และสกุลต้องตรงกับบัญชี ----------
  if new.bank_account_id is not null then
    v_bank_ccy := sri_os.fn_bank_account_currency(new.bank_account_id);
    select b.display_name into v_label
      from sri_os.bank_accounts b where b.id = new.bank_account_id;

    if v_bank_ccy is not null and v_bank_ccy <> 'THB' then
      if new.currency is null then
        raise exception 'บัญชี "%" เป็นบัญชีสกุล % — บรรทัดนี้ต้องระบุสกุลเงิน ยอดในสกุลเดิม อัตราแลกเปลี่ยน และวันของอัตราให้ครบ · **ลงเป็นบาทเฉยๆ ไม่ได้** เพราะยอดบาทจะกลายเป็นตัวเลขที่ไม่มีใครรู้ว่ามาจากอัตราไหน และระบบจะนับเงินตราเป็นบาททั้งก้อน (ยอดเงินสดในงบผิดทั้งงวด)',
          coalesce(v_label, new.bank_account_id::text), v_bank_ccy;
      end if;
      if new.currency <> v_bank_ccy then
        raise exception 'บรรทัดนี้ลงบัญชี "%" ซึ่งเป็นสกุล % แต่ระบุสกุล % — สกุลของบรรทัดต้องเป็นสกุลของบัญชีที่เงินเข้าออกจริง',
          coalesce(v_label, new.bank_account_id::text), v_bank_ccy, new.currency;
      end if;
    elsif v_bank_ccy = 'THB' and new.currency is not null then
      raise exception 'บัญชี "%" เป็นบัญชีบาท แต่บรรทัดนี้แนบข้อมูลอัตราแลกเปลี่ยนมา (สกุล %) — ข้อมูลอัตราที่ติดมากับบรรทัดบาทจะทำให้รายงานสกุลเงินนับยอดนี้เป็นเงินตรา',
        coalesce(v_label, new.bank_account_id::text), new.currency;
    end if;
  end if;

  if new.currency is null then
    return new;   -- บรรทัดบาทตรงๆ → ไม่มีอะไรต้องตรวจต่อ (ของเดิมทุกใบมาทางนี้)
  end if;

  -- ---------- (2) มีเงินตราเคลื่อน → ยอดบาทต้องมาจากอัตรา ----------
  if new.amount_original > 0 then
    v_expected := round(new.amount_original * new.fx_rate, 2);
    if abs(round(v_thb - v_expected, 2)) > 0.01 then
      raise exception 'ยอดบาทของบรรทัดนี้ (%) ไม่เท่ากับ ยอดสกุลเดิม % × อัตรา % = % — ยอดบาทต้องมาจากอัตราที่บันทึกไว้ ไม่ใช่ตัวเลขที่พิมพ์แยกกัน (ยอม 1 สตางค์จากการปัดเศษ)',
        round(v_thb, 2), new.amount_original, new.fx_rate, v_expected;
    end if;
    return new;
  end if;

  -- ---------- (3) ไม่มีเงินตราเคลื่อนแต่มียอดบาท = **บรรทัดแปลงค่า** ----------
  -- ลงได้เฉพาะหมวดที่คู่บัญชีแตะ 3410 (หมวดแปลงค่า) หรือตัวบรรทัด 3410 เอง
  -- (ขาผลต่างของใบแลกเงินจริง) ไม่งั้นใครก็ปั๊มยอดบาทขึ้นมาจากอากาศได้
  if v_thb <> 0 then
    select t.txn_type_code into v_type
      from sri_os.transactions t where t.id = new.transaction_id;
    v_is_xlate := v_code = '3410' or exists (
      select 1 from sri_os.txn_types ty
       where ty.code = v_type and '3410' in (ty.dr_coa_code, ty.cr_coa_code));
    if not v_is_xlate then
      raise exception 'บรรทัดนี้ไม่มียอดเงินตราเคลื่อน (amount_original = 0) แต่มียอดบาท % — บรรทัดแบบนี้คือ **การแปลงค่า** ซึ่งลงได้เฉพาะหมวดแปลงค่าเงินฝากสกุลต่างประเทศ หรือบรรทัดผลต่างอัตราแลกเปลี่ยน (3410) ของใบแลกเงินจริง · หมวด "%" ไม่ใช่ทั้งสองอย่าง',
        round(v_thb, 2), coalesce(v_type, '(ไม่มีหัวรายการ)');
    end if;
  end if;

  -- ---------- (4) บรรทัดที่ไม่ใช่เงินสด: แนบสกุลได้เฉพาะขาผลต่าง 3410 ----------
  -- (ขาเงินสดถูกครอบด้วยข้อ 1 ไปแล้ว · ขากำไร/ขาดทุนไม่ต้องมีสกุล เพราะเป็นบาทจริง)
  if new.bank_account_id is null and v_code <> '3410' then
    raise exception 'บรรทัดบัญชี % แนบข้อมูลสกุลเงินมา แต่ไม่ใช่ขาเงินสดของบัญชีสกุลต่างประเทศ และไม่ใช่ขาผลต่างอัตราแลกเปลี่ยน (3410) — ข้อมูลสกุลเงินบนบรรทัดอื่นจะทำให้รายงานยอดเงินตรานับซ้ำ',
      v_code;
  end if;

  return new;
end $fn$;

comment on function fn_assert_line_fx() is
  'FCD · บรรทัดเงินสดของบัญชีที่ไม่ใช่บาทต้องมีสกุล+ยอดสกุลเดิม+อัตรา+วันของอัตราครบ (ไม่ครบ = ปฏิเสธ ไม่ใช่สมมติอัตรา 1) · ยอดบาทต้องเท่ากับ round(ยอดสกุลเดิม × อัตรา, 2) · บรรทัดที่ไม่มีเงินตราเคลื่อนแต่มียอดบาท (การแปลงค่า) ลงได้เฉพาะหมวดแปลงค่าและขา 3410 · บัญชีบาทต้องไม่มีข้อมูลอัตราติดมา';

revoke all on function fn_assert_line_fx() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_line_fx() from anon, authenticated';
end $$;

-- ชื่อ trg_lines_f* → ยิงก่อนชุด trg_lines_r* (คู่บัญชี) ไม่ได้ แต่ลำดับไม่สำคัญที่นี่
-- เพราะสองด่านตรวจเรื่องต่างกันและข้อความชี้จุดต่างกันชัดเจน
drop trigger if exists trg_lines_fx_shape on transaction_lines;
create trigger trg_lines_fx_shape
  before insert or update on transaction_lines
  for each row execute function fn_assert_line_fx();

-- ============================================================
-- 5 · ด่าน "ยังไม่เกิดจริง ห้ามเข้า P&L" — ขยายจาก 3400 ให้ครอบ 3410 ด้วย
--
--   **เขียนทับทั้งฟังก์ชัน ไม่สร้างด่านที่สอง** (เหมือนที่ 20261024000001 ทำกับ
--   fn_assert_line_coa_in_rules) — กฎเดียวกันห้ามมีสองเวอร์ชัน (บทเรียนข้อ 5)
--   พฤติกรรมกับ 3400 **เหมือนเดิมทุกข้อ** ชุดบัญชีที่ถือว่า "ยังไม่เกิดจริง"
--   ย้ายไปอยู่ที่ `fn_unrealised_equity_coas()` ที่เดียว
-- ============================================================
create or replace function fn_unrealised_equity_coas() returns text[]
language sql immutable set search_path = '' as $fn$
  -- 3400 ส่วนเกินทุนจากการตีราคาทรัพย์ (D-111 ข้อ 2) · 3410 ผลต่างอัตราแลกเปลี่ยน (FCD)
  -- สองก้อนนี้คือ "กำไร/ขาดทุนที่ยังไม่เกิดขึ้นจริง" ทั้งหมดของระบบ
  select array['3400', '3410'];
$fn$;

comment on function fn_unrealised_equity_coas() is
  'บัญชีส่วนของเจ้าของที่เก็บกำไร/ขาดทุน **ที่ยังไม่เกิดขึ้นจริง** (3400 ตีราคาทรัพย์ · 3410 อัตราแลกเปลี่ยนของเงินฝาก) · ด่าน "ห้ามเข้า P&L" ทุกตัวอ่านชุดนี้ที่เดียว';

revoke all on function fn_unrealised_equity_coas() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_unrealised_equity_coas() from anon';
  execute 'grant execute on function sri_os.fn_unrealised_equity_coas() to authenticated';
end $$;

create or replace function fn_assert_revaluation_no_pl() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_type text;
  v_code text;
  v_kind text;
  v_acct text;
begin
  select t.txn_type_code into v_type
    from sri_os.transactions t where t.id = new.transaction_id;
  if v_type is null then
    return new;   -- ไม่มีหัวรายการ → ด่านอื่นปฏิเสธด้วยข้อความของมันเอง
  end if;

  -- ใบนี้เป็นรายการตีราคา/แปลงค่าหรือไม่ — อ่านจากคู่บัญชีของหมวด
  select x.coa into v_acct
    from unnest(sri_os.fn_unrealised_equity_coas()) x(coa)
   where exists (select 1 from sri_os.txn_types ty
                  where ty.code = v_type and x.coa in (ty.dr_coa_code, ty.cr_coa_code))
   limit 1;
  if v_acct is null then
    return new;
  end if;

  select c.code, c.type::text into v_code, v_kind
    from sri_os.chart_of_accounts c where c.id = new.coa_id;

  if v_kind in ('income', 'expense') then
    raise exception 'รายการตีราคา (หมวด %) ลงบัญชี % ซึ่งเป็นบัญชี% ไม่ได้ — กำไร/ขาดทุนที่ยังไม่เกิดขึ้นจริง (ตีราคาทรัพย์ หรือแปลงค่าเงินตรา) ห้ามเข้างบกำไรขาดทุนเด็ดขาด (ลูกพี่สั่ง 24/10 และย้ำ 25/10) ต้องลงที่ % ในส่วนของเจ้าของเท่านั้น · รับรู้เข้างบกำไรขาดทุนได้เฉพาะตอนขายจริง/แลกเป็นบาทจริง',
      v_type, v_code, case v_kind when 'income' then 'รายได้' else 'ค่าใช้จ่าย' end, v_acct;
  end if;

  return new;
end $fn$;

comment on function fn_assert_revaluation_no_pl() is
  'D-111 ข้อ 2 + FCD (25/10) · รายการที่คู่บัญชีแตะบัญชี "ยังไม่เกิดขึ้นจริง" (fn_unrealised_equity_coas: 3400 · 3410) ห้ามมีบรรทัดในบัญชีรายได้/ค่าใช้จ่าย · ที่นี่เป็นด่านที่เขียนตรงเข้าตารางก็ข้ามไม่ได้';

revoke all on function fn_assert_revaluation_no_pl() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_revaluation_no_pl() from anon, authenticated';
end $$;

create or replace function fn_assert_revaluation_type_stays_clean() returns trigger
language plpgsql set search_path = sri_os, public as $fn$
declare
  v text;
  v_acct text;
begin
  -- (ก) หมวดที่เคยเป็นหมวดตีราคา/แปลงค่า ห้ามถอดบัญชีนั้นออกจากคู่บัญชี
  select x.coa into v_acct
    from unnest(sri_os.fn_unrealised_equity_coas()) x(coa)
   where tg_op = 'UPDATE'
     and x.coa in (old.dr_coa_code, old.cr_coa_code)
     and x.coa not in (new.dr_coa_code, new.cr_coa_code)
   limit 1;
  if v_acct is not null then
    -- **ข้อความต้องมีวลี "จะเปลี่ยนให้ไม่แตะ <รหัส> ไม่ได้" เหมือนรุ่น 20261024000001**
    -- เทสต์ R2b ของไฟล์นั้นจับวลีนี้ตรงๆ — ลดคุณภาพข้อความลงไม่ได้แม้ตอนขยายกฎ
    raise exception 'หมวด "%" เป็นหมวดตีราคา/แปลงค่า (คู่บัญชีแตะ %) จะเปลี่ยนให้ไม่แตะ % ไม่ได้ — ด่าน "ยังไม่เกิดจริงห้ามเข้างบกำไรขาดทุน" ชี้หมวดจากคู่บัญชีนี้ ถอดออกแล้วด่านเลิกคุมหมวดนี้เงียบๆ · ถ้าต้องการหมวดใหม่ ให้เพิ่มหมวดใหม่ ไม่ใช่แก้หมวดเดิม',
      new.code, v_acct, v_acct;
  end if;

  -- (ข) หมวดตีราคา/แปลงค่า ห้ามประกาศบัญชีรายได้/ค่าใช้จ่ายไว้ในช่องใดเลย
  select x.coa into v_acct
    from unnest(sri_os.fn_unrealised_equity_coas()) x(coa)
   where x.coa in (new.dr_coa_code, new.cr_coa_code)
   limit 1;
  if v_acct is not null then
    select string_agg(c.code || ' ' || c.name_th, ', ') into v
      from sri_os.chart_of_accounts c
     where c.code in (new.dr_coa_code, new.cr_coa_code,
                      coalesce(new.gain_coa_code, ''), coalesce(new.loss_coa_code, ''),
                      coalesce(new.interest_coa_code, ''), coalesce(new.accrual_coa_code, ''))
       and c.type::text in ('income', 'expense');
    if v is not null then
      raise exception 'หมวดตีราคา/แปลงค่า "%" ประกาศบัญชีรายได้/ค่าใช้จ่ายไว้ (%) — กำไร/ขาดทุนที่ยังไม่เกิดขึ้นจริง ห้ามเข้างบกำไรขาดทุนเด็ดขาด (ลูกพี่สั่ง 24/10) · ทุกช่องบัญชีของหมวดนี้ต้องเป็นสินทรัพย์หรือส่วนของเจ้าของเท่านั้น เพราะบรรทัดลงได้ทุกช่องที่ประกาศไว้ ไม่ใช่แค่ dr/cr',
        new.code, v;
    end if;
  end if;

  return new;
end $fn$;

comment on function fn_assert_revaluation_type_stays_clean() is
  'D-111 ข้อ 2 + FCD (25/10) · กันสองทางที่ปลดด่าน "ยังไม่เกิดจริงห้ามแตะ P&L" ได้: ถอดบัญชี 3400/3410 ออกจากหมวด (ด่านเลิกมองหมวดนั้น) และตั้งบัญชี P&L ไว้ในช่อง gain/loss/interest/accrual (บรรทัดลงได้ทุกช่องที่ประกาศไว้)';

revoke all on function fn_assert_revaluation_type_stays_clean() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_revaluation_type_stays_clean() from anon, authenticated';
end $$;

-- ============================================================
-- 6 · ด่านคู่บัญชีระดับบรรทัด — ยอมให้ขาผลต่าง 3410 ลงบนใบ **แลกเป็นบาทจริง**
--     (รูปเดียวกับที่ยอม 3400 บนใบขายทรัพย์ · เนื้อที่เหลือยกมาจาก 20261024000001)
-- ============================================================
create or replace function fn_assert_line_coa_in_rules() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_type    text;
  v_nature  text;
  v_code    text;
  v_allowed text[];
  v_pair    text[];
  v_capgain boolean;
  v_gain    text;
  v_loss    text;
begin
  select t.txn_type_code, nullif(t.intercompany_nature, '')
    into v_type, v_nature
    from sri_os.transactions t
   where t.id = new.transaction_id;
  if v_type is null then
    return new;   -- ไม่มีหัวรายการให้เทียบ → FK/ด่านอื่นปฏิเสธด้วยข้อความของมันเอง
  end if;

  select c.code into v_code
    from sri_os.chart_of_accounts c where c.id = new.coa_id;
  if v_code is null then
    raise exception 'บรรทัดบัญชีชี้รหัสบัญชีที่ไม่มีอยู่ในผังบัญชี (coa_id %)', new.coa_id;
  end if;

  select array_remove(array[t.dr_coa_code, t.cr_coa_code, t.gain_coa_code,
                            t.loss_coa_code, t.interest_coa_code, t.accrual_coa_code], null),
         t.requires_capital_gain, t.gain_coa_code, t.loss_coa_code
    into v_allowed, v_capgain, v_gain, v_loss
    from sri_os.txn_types t where t.code = v_type;
  if v_allowed is null or cardinality(v_allowed) = 0 then
    raise exception 'ตารางกฎ (txn_types) ไม่ได้ระบุบัญชีของหมวด "%" เลย — sync ด้วย npm run sync:rules ก่อน ห้ามเดาคู่บัญชีแทน',
      v_type;
  end if;

  if v_nature is not null then
    v_pair := sri_os.fn_intercompany_coa(v_nature);
    if v_pair is null then
      raise exception 'ลักษณะรายการข้ามผู้ถือ "%" ยังไม่มีคู่บัญชีระหว่างกันในฝั่งฐานข้อมูล — เพิ่มใน fn_intercompany_pairs() ให้ตรงกับ src/lib/rules/intercompany.ts ก่อนใช้',
        v_nature;
    end if;
    -- ขาเงินสดกับ **รหัสตรง** ของลักษณะนั้นใช้ได้บนขาข้ามผู้ถือ
    v_allowed := v_allowed || array['1100'] || v_pair;
  end if;

  -- D-111 ข้อ 1 · บรรทัดภาษีถูกหัก ณ ที่จ่าย — เฉพาะหมวดที่หักได้จริง
  if sri_os.fn_txn_type_can_withhold(v_type) then
    v_allowed := v_allowed || array['1800'];
  end if;

  -- D-111 ข้อ 2 · บรรทัดล้างส่วนเกินทุนจากการตีราคา — เฉพาะหมวดที่รับรู้กำไร/ขาดทุนจากการขาย
  -- (หมวดตีราคาเองมี 3400 อยู่ใน dr/cr แล้ว จึงไม่ต้องเติมให้)
  if coalesce(v_capgain, false) then
    v_allowed := v_allowed || array['3400'];
  end if;

  -- FCD (25/10) · บรรทัดล้างผลต่างอัตราแลกเปลี่ยนที่ยังไม่เกิดจริง — เฉพาะหมวดที่
  -- **ประกาศบัญชีกำไร/ขาดทุนอัตราแลกเปลี่ยนไว้** (คือหมวดแลกเป็นบาทจริง)
  -- หมวดแปลงค่าเองมี 3410 อยู่ใน dr/cr แล้ว
  if v_gain = '4330' or v_loss = '5930' then
    v_allowed := v_allowed || array['3410'];
  end if;

  if not (v_code = any (v_allowed)) then
    raise exception 'หมวด "%" ลงบัญชี % ไม่ได้ — ตารางกฎระบุบัญชีของหมวดนี้ไว้เฉพาะ % · คู่บัญชีที่ไม่ตรงหมวดทำให้ผิดทั้งงบ (เช่น เงินกู้กลายเป็นรายได้)',
      v_type, v_code, array_to_string(v_allowed, ', ');
  end if;

  return new;
end $fn$;

comment on function fn_assert_line_coa_in_rules() is
  'ทุกบรรทัดต้องใช้บัญชีที่ตารางกฎ (sri_os.txn_types) ระบุของหมวดนั้น · ขาข้ามผู้ถือล็อกเป็นรหัสตรงจาก fn_intercompany_pairs() · บวก 1800 ให้หมวดที่หักภาษี ณ ที่จ่ายได้ (D-111 ข้อ 1) · 3400 ให้หมวดที่รับรู้กำไร/ขาดทุนจากการขาย (D-111 ข้อ 2) · 3410 ให้หมวดที่ประกาศบัญชีกำไร/ขาดทุนอัตราแลกเปลี่ยน (FCD · 25/10) ซึ่งต้องล้างผลต่างที่ค้างพร้อมกัน';

revoke all on function fn_assert_line_coa_in_rules() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_line_coa_in_rules() from anon, authenticated';
end $$;

-- ============================================================
-- 7 · ด่าน: แลกเงินตราออกหมดแล้ว **3410 ของสกุลนั้นต้องเหลือศูนย์พอดี**
--
-- รูปเดียวกับ "ขายทรัพย์หมดแล้ว 3400 ของทรัพย์นั้นต้องเป็นศูนย์"
-- (fn_assert_asset_cost_sane ข้อ ค) · ถ้าไม่ล้าง ผลต่างค้างในส่วนของเจ้าของ
-- ตลอดไปทั้งที่เงินตราไม่อยู่แล้ว และถูกนับซ้ำกับกำไรที่รับรู้ไปแล้ว
--
-- วัด **ต่อผู้ถือ + ต่อสกุล** เพราะ 3410 ผูกกับสกุลเงิน ไม่ได้ผูกกับบัญชีใดบัญชีหนึ่ง
-- (บรรทัด 3410 ไม่มี bank_account_id ได้ — ด่าน fn_assert_line_bank_is_cash
--  ห้ามบัญชีธนาคารบนบรรทัดที่ไม่ใช่เงินสด) · สกุลของบรรทัด 3410 คือตัวที่บอกว่า
-- ผลต่างก้อนนั้นเป็นของสกุลไหน
-- ============================================================
create or replace function fn_assert_fx_unrealized_cleared_for(p_txn uuid) returns void
language plpgsql security definer set search_path = '' as $fn$
declare
  v_owner  uuid;
  v_type   text;
  v_ccy    text;
  v_fx     numeric;
  v_unreal numeric;
begin
  select t.owner_id, t.txn_type_code into v_owner, v_type
    from sri_os.transactions t where t.id = p_txn;
  if v_owner is null then
    return;
  end if;

  -- ตรวจเฉพาะใบที่ **รับรู้กำไร/ขาดทุนอัตราแลกเปลี่ยนจริง** (ใบแลกเป็นบาท)
  if not exists (
    select 1 from sri_os.txn_types ty
     where ty.code = v_type and ('4330' = ty.gain_coa_code or '5930' = ty.loss_coa_code)
  ) then
    return;
  end if;

  -- ทุกสกุลที่ใบนี้แตะ
  for v_ccy in
    select distinct l.currency
      from sri_os.transaction_lines l
     where l.transaction_id = p_txn and l.currency is not null and l.currency <> 'THB'
  loop
    -- ยอด **เงินตรา** คงเหลือของผู้ถือในสกุลนี้ (ทิศจากด้านที่ลง)
    select coalesce(sum(case when v.debit > 0 then v.amount_original else -v.amount_original end), 0)
      into v_fx
      from sri_os.v_ledger_posted v
      join sri_os.chart_of_accounts c on c.id = v.coa_id
     where v.owner_id = v_owner and v.currency = v_ccy
       and c.code ~ '^11[0-9][0-9]$';

    -- ผลต่างที่ยังค้างในส่วนของเจ้าของของสกุลนี้ (เครดิต = บวก)
    select coalesce(sum(v.credit - v.debit), 0) into v_unreal
      from sri_os.v_ledger_posted v
      join sri_os.chart_of_accounts c on c.id = v.coa_id
     where v.owner_id = v_owner and v.currency = v_ccy and c.code = '3410';

    if round(v_fx, 6) = 0 and round(v_unreal, 2) <> 0 then
      raise exception 'แลกเงินสกุล % ออกหมดแล้ว (ยอดเงินตราคงเหลือ 0) แต่ยังมีผลต่างอัตราแลกเปลี่ยนค้างในส่วนของเจ้าของ (3410) อยู่ % บาท — ต้องล้างออกให้เหลือศูนย์พอดีในใบเดียวกับการแลก ไม่งั้นผลต่างค้างตลอดไปทั้งที่เงินตราไม่อยู่แล้ว และถูกนับซ้ำกับกำไร/ขาดทุนที่รับรู้ไปแล้ว',
        v_ccy, round(v_unreal, 2);
    end if;

    if round(v_fx, 6) < 0 then
      raise exception 'ยอดเงินตราสกุล % ของผู้ถือนี้ติดลบ (%) — แลกออกมากกว่าที่มีอยู่ในบัญชีไม่ได้ · ถ้ามีเงินเข้าที่ยังไม่ได้ลง ต้องลงใบนั้นก่อน',
        v_ccy, round(v_fx, 6);
    end if;
  end loop;
end $fn$;

comment on function fn_assert_fx_unrealized_cleared_for(uuid) is
  'FCD (25/10) · ใบแลกเงินตราเป็นบาท: ถ้าแลกออกหมดแล้ว (ยอดเงินตราคงเหลือของผู้ถือในสกุลนั้น = 0) ผลต่างที่ค้างใน 3410 ของสกุลนั้นต้องเหลือศูนย์พอดี · และยอดเงินตราคงเหลือติดลบไม่ได้ · รูปเดียวกับ "ขายทรัพย์หมดแล้ว 3400 ต้องเป็นศูนย์"';

revoke all on function fn_assert_fx_unrealized_cleared_for(uuid) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_fx_unrealized_cleared_for(uuid) from anon, authenticated';
end $$;

create or replace function fn_assert_fx_unrealized_cleared() returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  perform sri_os.fn_assert_fx_unrealized_cleared_for(coalesce(new.transaction_id, old.transaction_id));
  return null;
end $fn$;

comment on function fn_assert_fx_unrealized_cleared() is
  'trigger ฝั่ง transaction_lines ของ fn_assert_fx_unrealized_cleared_for() · constraint trigger แบบ deferred เพราะต้องอ่านทุกบรรทัดของใบ (ขาเงินตรา ขาบาท ขากำไร/ขาดทุน และขาล้างผลต่าง)';

revoke all on function fn_assert_fx_unrealized_cleared() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_fx_unrealized_cleared() from anon, authenticated';
end $$;

drop trigger if exists trg_assert_fx_unrealized_cleared on transaction_lines;
create constraint trigger trg_assert_fx_unrealized_cleared
  after insert or update or delete on transaction_lines
  deferrable initially deferred
  for each row execute function fn_assert_fx_unrealized_cleared();

-- ============================================================
-- 8 · fn_post_entry — รับสี่ช่องของสกุลเดิมที่ระดับ **บรรทัด**
--
-- **เนื้อในยกมาจาก 20261025000001 ครบทุกบรรทัด** (ซึ่งยกมาจาก 20261008000013
-- ที่ถอดด่านคู่บัญชี/bank ออกจากประตูไปแล้ว — ห้ามเอากลับเข้ามา)
-- สิ่งที่เพิ่มคือ **สี่ช่องของบรรทัด** เท่านั้น:
--   'currency' · 'amount_original' · 'fx_rate' · 'fx_rate_date'
--   + ตรวจชนิดข้อมูลให้ได้ข้อความภาษาคน + เขียนลงบรรทัดจริง
--
-- ถ้าไม่เพิ่ม: ส่งข้อมูลอัตรามา ประตูเด้ง "ช่องที่ยังไม่รู้จัก" · ไม่ส่งมา
-- ด่าน trg_lines_fx_shape ปฏิเสธเพราะบัญชีไม่ใช่บาท → **ลงบัญชี FCD ไม่ได้เลย
-- ทั้งสองทาง** (รูปเดียวกับทางตันของ wht_* ที่ปิดไปใน 20261025000001)
--
-- **กฎบัญชีไม่อยู่ในประตู**: "บัญชีไม่ใช่บาทต้องมีอัตรา" และ "ยอดบาทต้องมาจาก
-- อัตรา" อยู่ที่ trg_lines_fx_shape ที่เดียว (ประตูตรวจแค่ชนิดข้อมูล)
-- ============================================================
create or replace function fn_post_entry(p_payload jsonb) returns jsonb
language plpgsql set search_path = '' as $fn$
declare
  c_header constant text[] := array[
    'txn_type_code', 'doc_date', 'cash_date', 'doc_no', 'memo', 'attachments',
    'asset_id', 'contact_id', 'contract_id', 'owner_reason', 'funding_source',
    'source', 'source_ref', 'reverses_id',
    -- D-111 ข้อ 1 · ภาษีหัก ณ ที่จ่าย — **สามช่องนี้คือสิ่งที่ไฟล์นี้เพิ่ม**
    -- ก่อนหน้านี้ส่งมาไม่ได้เลย (เด้ง "ช่องที่ยังไม่รู้จัก") และถ้าไม่ส่ง
    -- หัวรายการจะเป็น null แล้ว fn_assert_wht_gross ปฏิเสธตอน commit
    -- → บันทึกการถูกหักภาษี **ตันทั้งสองทาง**
    'wht_rate', 'wht_amount', 'wht_certificate_no',
    'transactions'];
  c_txn    constant text[] := array['owner_id', 'counter_owner_id', 'intercompany_nature', 'lines'];
  c_line   constant text[] := array['coa_code', 'bank_account_id', 'asset_id',
                                    'debit', 'credit', 'cf_category', 'memo',
                                    -- FCD (25/10) · ข้อมูลสกุลเดิมของบรรทัด
                                    -- ยอดบาทยังอยู่ที่ debit/credit เหมือนเดิมทุกบรรทัด
                                    'currency', 'amount_original', 'fx_rate', 'fx_rate_date'];
  v_bad      text;
  v_source   text;
  v_has_cash boolean := false;
  v_i        int := 0;
  v_j        int;
  v_dr       numeric;
  v_cr       numeric;
  v_txn      jsonb;
  v_line     jsonb;
  v_coa      uuid;
  v_txn_id   uuid;
  v_ids      uuid[] := '{}';
  v_prev     uuid[];
  v_fp       text;
  v_canon    jsonb;
  v_secs     numeric;
  v_req      uuid;
  v_doc      date;
  v_cash     date;
  v_wht_rate numeric;
  v_wht_amt  numeric;
  v_wht_cert text;
  v_num      text;
  v_fxdate   date;
  v_allowed  text[];
  v_nature   text;
begin
  -- ========== 0 · ไม่ส่งข้อมูลมาเลย = ปฏิเสธ ห้ามตกไปเส้นทางปกติ (บทเรียนข้อ 1) ==========
  if p_payload is null or jsonb_typeof(p_payload) = 'null' then
    raise exception 'บันทึกรายการไม่ได้: ไม่ได้ส่งข้อมูลรายการมาเลย';
  end if;
  if jsonb_typeof(p_payload) <> 'object' then
    raise exception 'บันทึกรายการไม่ได้: รูปแบบข้อมูลไม่ถูกต้อง — ต้องเป็น object ของทั้งใบ ไม่ใช่ %',
      jsonb_typeof(p_payload);
  end if;

  select string_agg(k, ', ' order by k) into v_bad
    from jsonb_object_keys(p_payload) as k where k <> all (c_header);
  if v_bad is not null then
    raise exception 'บันทึกรายการไม่ได้: มีช่องที่ยังไม่รู้จัก (%) — RPC ปฏิเสธทั้งใบแทนที่จะทิ้งช่องนั้นเงียบๆ · ช่องที่รับคือ %',
      v_bad, array_to_string(c_header, ', ');
  end if;

  -- ========== 1 · ผู้เรียกต้องมีตัวตนในระบบ ==========
  if auth.uid() is null then
    raise exception 'บันทึกรายการไม่ได้: ยังไม่ได้ล็อกอิน';
  end if;
  if not exists (select 1 from sri_os.app_users u where u.id = auth.uid() and u.is_active) then
    raise exception 'บันทึกรายการไม่ได้: ผู้ใช้นี้ยังไม่ได้ถูกตั้งตำแหน่งในระบบ หรือถูกปิดใช้งานแล้ว';
  end if;

  -- ========== 2 · ช่องบังคับของหัวรายการ ==========
  if nullif(p_payload ->> 'txn_type_code', '') is null then
    raise exception 'บันทึกรายการไม่ได้: ไม่ได้ส่ง txn_type_code (หมวดย่อยของรายการ)';
  end if;
  if not exists (select 1 from sri_os.txn_types t where t.code = p_payload ->> 'txn_type_code') then
    raise exception 'บันทึกรายการไม่ได้: ไม่มีหมวด "%" ในตารางกฎ (txn_types) — ตารางกฎคือแหล่งความจริงเดียว ถ้าเพิ่มหมวดใหม่ให้ sync ด้วย npm run sync:rules',
      p_payload ->> 'txn_type_code';
  end if;
  if nullif(p_payload ->> 'doc_date', '') is null then
    raise exception 'บันทึกรายการไม่ได้: ไม่ได้ส่ง doc_date (วันที่เอกสาร)';
  end if;

  -- วันที่: แปลงที่นี่ครั้งเดียว เพื่อให้ได้ข้อความภาษาคนแทน error ดิบของการ cast
  -- และเพื่อให้ "2026-09-01" กับรูปอื่นของวันเดียวกันได้ fingerprint เดียวกัน (ข้อ 4)
  begin
    v_doc := (p_payload ->> 'doc_date')::date;
  exception when others then
    raise exception 'บันทึกรายการไม่ได้: doc_date "%" ไม่ใช่วันที่ที่อ่านได้ (ต้องเป็น YYYY-MM-DD)',
      p_payload ->> 'doc_date';
  end;
  if nullif(p_payload ->> 'cash_date', '') is not null then
    begin
      v_cash := (p_payload ->> 'cash_date')::date;
    exception when others then
      raise exception 'บันทึกรายการไม่ได้: cash_date "%" ไม่ใช่วันที่ที่อ่านได้ (ต้องเป็น YYYY-MM-DD)',
        p_payload ->> 'cash_date';
    end;
  end if;

  v_source := coalesce(nullif(p_payload ->> 'source', ''), 'manual');
  if not exists (
       select 1 from pg_catalog.pg_enum e
         join pg_catalog.pg_type t on t.oid = e.enumtypid
         join pg_catalog.pg_namespace n on n.oid = t.typnamespace
        where n.nspname = 'sri_os' and t.typname = 'txn_source' and e.enumlabel = v_source) then
    raise exception 'บันทึกรายการไม่ได้: source "%" ไม่รู้จัก', v_source;
  end if;

  if p_payload -> 'attachments' is not null
     and jsonb_typeof(p_payload -> 'attachments') <> 'array' then
    raise exception 'บันทึกรายการไม่ได้: attachments ต้องเป็น array ของชื่อไฟล์';
  end if;

  -- ========== 2.1 · ภาษีหัก ณ ที่จ่าย (D-111 ข้อ 1) ==========
  -- ตรวจ **รูปของข้อมูล** ที่นี่เพื่อให้ได้ข้อความภาษาคนแทน error ดิบของ constraint
  -- ส่วนกฎบัญชี ("เงินได้ต้องเป็นยอดเต็ม") อยู่ที่ fn_assert_wht_gross_for() ที่เดียว
  -- ซึ่งอ่านทุกบรรทัดของใบตอน commit — **ไม่ได้ทำสำเนากฎไว้ในประตู** (บทเรียนข้อ 5)
  if (p_payload -> 'wht_rate') is not null
     and jsonb_typeof(p_payload -> 'wht_rate') not in ('number', 'null') then
    raise exception 'บันทึกรายการไม่ได้: wht_rate ต้องเป็นตัวเลข (ร้อยละ) ไม่ใช่ %',
      jsonb_typeof(p_payload -> 'wht_rate');
  end if;
  if (p_payload -> 'wht_amount') is not null
     and jsonb_typeof(p_payload -> 'wht_amount') not in ('number', 'null') then
    raise exception 'บันทึกรายการไม่ได้: wht_amount ต้องเป็นตัวเลข (บาท) ไม่ใช่ %',
      jsonb_typeof(p_payload -> 'wht_amount');
  end if;
  v_wht_rate := (p_payload ->> 'wht_rate')::numeric;
  v_wht_amt  := (p_payload ->> 'wht_amount')::numeric;
  v_wht_cert := nullif(btrim(coalesce(p_payload ->> 'wht_certificate_no', '')), '');

  -- อัตรากับยอดต้องมาคู่กันเสมอ (constraint transactions_wht_shape กันไว้อีกชั้น
  -- แต่ข้อความของ constraint อ่านไม่รู้เรื่องสำหรับคนกดปุ่ม)
  if (v_wht_rate is null) <> (v_wht_amt is null) then
    raise exception 'บันทึกรายการไม่ได้: ภาษีหัก ณ ที่จ่ายต้องส่งทั้งอัตรา (wht_rate) และยอดที่ถูกหัก (wht_amount) คู่กัน — มียอดแต่ไม่มีอัตราจะตรวจกับใบรับรองไม่ได้ · มีอัตราแต่ไม่มียอดจะไม่รู้ว่าสินทรัพย์ภาษีเป็นเท่าไร';
  end if;
  if v_wht_cert is not null and v_wht_amt is null then
    raise exception 'บันทึกรายการไม่ได้: ส่งเลขที่ใบรับรองการหักภาษีมาแต่ใบนี้ไม่ได้ถูกหักภาษี — เลขที่ใบรับรองติดได้เฉพาะใบที่ถูกหักจริง';
  end if;

  if p_payload -> 'transactions' is null then
    raise exception 'บันทึกรายการไม่ได้: ไม่ได้ส่ง transactions (ผลลัพธ์จาก buildPosting)';
  end if;
  if jsonb_typeof(p_payload -> 'transactions') <> 'array' then
    raise exception 'บันทึกรายการไม่ได้: transactions ต้องเป็น array (หนึ่งสมาชิก = หนึ่งผู้ถือ)';
  end if;
  if jsonb_array_length(p_payload -> 'transactions') = 0 then
    raise exception 'บันทึกรายการไม่ได้: ไม่มีรายการใน transactions เลย';
  end if;

  -- ========== 3 · ตรวจรูปของทุกรายการ/ทุกบรรทัด **ก่อนเขียนอะไรลงไป** ==========
  for v_txn in select value from jsonb_array_elements(p_payload -> 'transactions') loop
    v_i := v_i + 1;
    if jsonb_typeof(v_txn) <> 'object' then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ต้องเป็น object', v_i;
    end if;

    select string_agg(k, ', ' order by k) into v_bad
      from jsonb_object_keys(v_txn) as k where k <> all (c_txn);
    if v_bad is not null then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % มีช่องที่ยังไม่รู้จัก (%) · ช่องที่รับคือ %',
        v_i, v_bad, array_to_string(c_txn, ', ');
    end if;

    if nullif(v_txn ->> 'owner_id', '') is null then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ไม่ได้ส่ง owner_id (ผู้ถือ) — หนึ่งรายการ = หนึ่งผู้ถือ เดาแทนไม่ได้', v_i;
    end if;

    -- ข้ามผู้ถือต้องมาเป็นคู่: ขาดข้างใดข้างหนึ่งแปลว่าข้อมูลไม่ครบ ไม่ใช่รายการธรรมดา
    if nullif(v_txn ->> 'counter_owner_id', '') is not null
       and nullif(v_txn ->> 'intercompany_nature', '') is null then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % เป็นรายการข้ามผู้ถือ ต้องระบุลักษณะ (intercompany_nature: advance/loan/capital/dividend)', v_i;
    end if;
    if nullif(v_txn ->> 'intercompany_nature', '') is not null
       and nullif(v_txn ->> 'counter_owner_id', '') is null then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ระบุลักษณะข้ามผู้ถือแต่ไม่มีผู้ถืออีกฝ่าย (counter_owner_id)', v_i;
    end if;
    if nullif(v_txn ->> 'counter_owner_id', '') is not null
       and (v_txn ->> 'counter_owner_id') = (v_txn ->> 'owner_id') then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ระบุผู้ถืออีกฝ่ายเป็นคนเดียวกับผู้ถือของรายการ — ถ้าเป็นการย้ายกระเป๋าในคนเดียวกัน ไม่ใช่รายการข้ามผู้ถือ', v_i;
    end if;

    if v_txn -> 'lines' is null or jsonb_typeof(v_txn -> 'lines') <> 'array' then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ไม่ได้ส่ง lines เป็น array', v_i;
    end if;
    if jsonb_array_length(v_txn -> 'lines') < 2 then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % มีบรรทัดบัญชี % บรรทัด — บัญชีสองด้านต้องมีอย่างน้อยสองบรรทัด',
        v_i, jsonb_array_length(v_txn -> 'lines');
    end if;

    -- ---------- 3.1 ชุดบัญชีที่หมวดนี้ใช้ได้ — อ่านจากตารางกฎ ไม่ได้คิดเอง (ข้อ 3) ----------
    select array_remove(array[t.dr_coa_code, t.cr_coa_code, t.gain_coa_code,
                              t.loss_coa_code, t.interest_coa_code, t.accrual_coa_code], null)
      into v_allowed
      from sri_os.txn_types t where t.code = p_payload ->> 'txn_type_code';
    if v_allowed is null or cardinality(v_allowed) = 0 then
      raise exception 'บันทึกรายการไม่ได้: ตารางกฎ (txn_types) ไม่ได้ระบุบัญชีของหมวด "%" เลย — sync ด้วย npm run sync:rules ก่อน ห้ามเดาคู่บัญชีแทน',
        p_payload ->> 'txn_type_code';
    end if;

    -- ---------- 3.2 ลักษณะข้ามผู้ถือต้องเป็นลักษณะที่ฝั่ง DB รู้จัก (ห้ามเดา) ----------
    -- **ไม่มีสำเนาคู่บัญชีในฟังก์ชันนี้แล้ว** — อ่านจาก fn_intercompany_pairs() ที่เดียว
    --   ด่าน "ขาข้ามผู้ถือต้องเป็นรหัสตรงของลักษณะนั้น" อยู่ที่ trg_lines_rule_coa
    --   ที่นี่เหลือแค่การปฏิเสธลักษณะที่ไม่รู้จัก **ก่อนเขียนอะไรลงไป** เพื่อให้ได้
    --   ข้อความภาษาคน ไม่ใช่ error ดิบของ check constraint
    v_nature := nullif(v_txn ->> 'intercompany_nature', '');
    if v_nature is not null and sri_os.fn_intercompany_coa(v_nature) is null then
      raise exception 'บันทึกรายการไม่ได้: ลักษณะรายการข้ามผู้ถือ "%" ไม่รู้จัก (ที่รับคือ %)',
        v_nature,
        coalesce((select string_agg(p.nature, '/' order by p.nature)
                    from sri_os.fn_intercompany_pairs() p), '(ยังไม่มีลักษณะใดในฝั่ง DB)');
    end if;

    v_j := 0;
    for v_line in select value from jsonb_array_elements(v_txn -> 'lines') loop
      v_j := v_j + 1;
      if jsonb_typeof(v_line) <> 'object' then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % ต้องเป็น object', v_i, v_j;
      end if;

      select string_agg(k, ', ' order by k) into v_bad
        from jsonb_object_keys(v_line) as k where k <> all (c_line);
      if v_bad is not null then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % มีช่องที่ยังไม่รู้จัก (%) · ช่องที่รับคือ %',
          v_i, v_j, v_bad, array_to_string(c_line, ', ');
      end if;

      if nullif(v_line ->> 'coa_code', '') is null then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % ไม่ได้ส่ง coa_code', v_i, v_j;
      end if;
      select c.id into v_coa
        from sri_os.chart_of_accounts c where c.code = v_line ->> 'coa_code';
      if v_coa is null then
        raise exception 'บันทึกรายการไม่ได้: ไม่มีรหัส "%" ในผังบัญชี (chart_of_accounts) — ผังบัญชีในฐานข้อมูลอาจยังไม่ sync กับ src/lib/rules/coa.ts',
          v_line ->> 'coa_code';
      end if;

      if (v_line -> 'debit') is null and (v_line -> 'credit') is null then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % ไม่ได้ส่งทั้งเดบิตและเครดิต', v_i, v_j;
      end if;
      if (v_line -> 'debit') is not null and jsonb_typeof(v_line -> 'debit') not in ('number', 'null') then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % เดบิตต้องเป็นตัวเลข', v_i, v_j;
      end if;
      if (v_line -> 'credit') is not null and jsonb_typeof(v_line -> 'credit') not in ('number', 'null') then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % เครดิตต้องเป็นตัวเลข', v_i, v_j;
      end if;
      v_dr := coalesce((v_line ->> 'debit')::numeric, 0);
      v_cr := coalesce((v_line ->> 'credit')::numeric, 0);
      if v_dr < 0 or v_cr < 0 then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % มียอดติดลบ (เดบิต % เครดิต %) — ทิศทางมาจากด้านที่ลง ไม่ใช่จากเครื่องหมาย',
          v_i, v_j, v_dr, v_cr;
      end if;
      if not ((v_dr > 0 and v_cr = 0) or (v_cr > 0 and v_dr = 0)) then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % ต้องลงด้านเดียวและมากกว่า 0 (เดบิต % เครดิต %)',
          v_i, v_j, v_dr, v_cr;
      end if;

      if nullif(v_line ->> 'cf_category', '') is not null
         and not exists (
           select 1 from pg_catalog.pg_enum e
             join pg_catalog.pg_type t on t.oid = e.enumtypid
             join pg_catalog.pg_namespace n on n.oid = t.typnamespace
            where n.nspname = 'sri_os' and t.typname = 'cf_group'
              and e.enumlabel = v_line ->> 'cf_category') then
        raise exception 'บันทึกรายการไม่ได้: หมวดกระแสเงินสด "%" ไม่รู้จัก', v_line ->> 'cf_category';
      end if;

      -- ---------- FCD (25/10) · รูปของข้อมูลสกุลเดิม ----------
      -- กฎบัญชี (ต้องมีอัตราถ้าบัญชีไม่ใช่บาท · ยอดบาทต้องมาจากอัตรา) อยู่ที่
      -- trg_lines_fx_shape ที่เดียว — ที่นี่ตรวจแค่ชนิดข้อมูลเพื่อให้ได้ข้อความภาษาคน
      -- แทน error ดิบของการ cast (ไม่ได้ทำสำเนากฎไว้ในประตู · บทเรียนข้อ 5)
      foreach v_num in array array['amount_original', 'fx_rate'] loop
        if (v_line -> v_num) is not null
           and jsonb_typeof(v_line -> v_num) not in ('number', 'null') then
          raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % ช่อง % ต้องเป็นตัวเลข ไม่ใช่ %',
            v_i, v_j, v_num, jsonb_typeof(v_line -> v_num);
        end if;
      end loop;
      if nullif(v_line ->> 'fx_rate_date', '') is not null then
        begin
          v_fxdate := (v_line ->> 'fx_rate_date')::date;
        exception when others then
          raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % fx_rate_date "%" ไม่ใช่วันที่ที่อ่านได้ (ต้องเป็น YYYY-MM-DD)',
            v_i, v_j, v_line ->> 'fx_rate_date';
        end;
      end if;

      -- ผังบัญชี 1100-1199 = เงินสดและเงินฝาก (เกณฑ์เดียวกับ fn_assert_no_floating_cash)
      if (v_line ->> 'coa_code') ~ '^11[0-9][0-9]$' then v_has_cash := true; end if;
    end loop;
  end loop;

  -- ========== 3.4 · ข้ามผู้ถือต้องมาครบคู่ในคำขอเดียว (ข้อ 2 · ข้อความที่อ่านรู้เรื่อง) ==========
  -- ด่านจริงคือ trg_intercompany_pair (constraint trigger) ที่ครอบ REST ตรงด้วย
  -- ที่นี่ตรวจซ้ำเพื่อให้ผู้กดได้ข้อความก่อนที่อะไรจะถูกเขียน ไม่ใช่กฎที่สองที่คิดต่างกัน
  with legs as (
    select (x.value ->> 'owner_id') as o,
           nullif(x.value ->> 'counter_owner_id', '') as c,
           nullif(x.value ->> 'intercompany_nature', '') as n,
           (select coalesce(sum(coalesce((l.value ->> 'debit')::numeric, 0)), 0)
              from jsonb_array_elements(x.value -> 'lines') as l) as amt
      from jsonb_array_elements(p_payload -> 'transactions') as x
  )
  select string_agg(distinct a.o, ', ') into v_bad
    from legs a
   where a.c is not null
     and (select count(*) from legs b
           where b.o = a.o and b.c = a.c and b.n = a.n and b.amt = a.amt)
      <> (select count(*) from legs b
           where b.o = a.c and b.c = a.o and b.n = a.n and b.amt = a.amt);
  if v_bad is not null then
    raise exception 'บันทึกรายการไม่ได้: รายการข้ามผู้ถือต้องมาครบคู่ในคำขอเดียว (ขาออกของผู้ถือหนึ่ง + ขาเข้าของอีกผู้ถือ ยอดเท่ากัน) — ขาของผู้ถือ % ไม่มีขาคู่ · ขาเดียวแปลว่าเงินหายไปข้างหนึ่งและงบรวมตัดรายการระหว่างกันไม่ลง',
      v_bad;
  end if;

  -- ========== 4 · cash_date ต้องสอดคล้องกับบรรทัดที่เครื่องยนต์ส่งมา ==========
  if v_has_cash and v_cash is null then
    raise exception 'บันทึกรายการไม่ได้: รายการนี้มีบรรทัดเงินสด/เงินฝาก แต่ไม่ได้ส่ง cash_date (วันที่เงินเข้า-ออกจริง) — ถ้าเงินยังไม่เคลื่อน ต้องลงเป็นลูกหนี้/เจ้าหนี้ ไม่ใช่เงินสด';
  end if;
  if not v_has_cash and v_cash is not null then
    raise exception 'บันทึกรายการไม่ได้: รายการนี้ไม่มีบรรทัดเงินสดเลย (ค้างรับ-ค้างจ่าย) cash_date ต้องเป็น null ไม่งั้นงบกระแสเงินสดจะนับเงินที่ยังไม่เคลื่อน';
  end if;

  -- ========== 5 · กันกดปุ่มซ้ำ — ล็อกแถว fingerprint ก่อนลงรายการ ==========
  select coalesce((s.value #>> '{}')::numeric, 60) into v_secs
    from sri_os.settings s where s.key = 'ledger.post_dedupe_seconds';
  v_secs := greatest(coalesce(v_secs, 60), 0);

  -- ข้อ 4: normalise ก่อนคิด fingerprint · วันที่/source ใช้ค่าที่ฟังก์ชันจะใช้จริง
  v_canon := sri_os.fn_canonical_payload(p_payload);
  v_canon := jsonb_set(v_canon, '{doc_date}', to_jsonb(v_doc::text));
  if v_cash is null then
    v_canon := v_canon - 'cash_date';
  else
    v_canon := jsonb_set(v_canon, '{cash_date}', to_jsonb(v_cash::text));
  end if;
  v_canon := jsonb_set(v_canon, '{source}', to_jsonb(v_source));

  v_fp := encode(sha256(convert_to(auth.uid()::text || '|' || v_canon::text, 'UTF8')), 'hex');

  insert into sri_os.post_entry_requests as r (fingerprint)
  values (v_fp)
      on conflict (fingerprint) do update
         set created_at = now(), transaction_ids = '{}'::uuid[]
       where r.created_at < now() - make_interval(secs => v_secs::double precision)
  returning r.id into v_req;

  if v_req is null then
    -- คำขอเดิมซ้ำในหน้าต่าง = กดรัว · คืน id ชุดเดิมโดยไม่ลงใหม่
    select r.transaction_ids into v_prev
      from sri_os.post_entry_requests r where r.fingerprint = v_fp;
    return jsonb_build_object(
      'transaction_ids', coalesce(to_jsonb(v_prev), '[]'::jsonb),
      'replayed', true,
      'fingerprint', v_fp);
  end if;

  -- ========== 6 · เขียนลงจริง — หัวรายการ + บรรทัด ในธุรกรรมเดียวกัน (D-091) ==========
  -- created_by ไม่อยู่ในรายการคอลัมน์โดยตั้งใจ: trigger ตั้งเป็น auth.uid() ให้ (ข้อ 5)
  for v_txn in select value from jsonb_array_elements(p_payload -> 'transactions') loop
    insert into sri_os.transactions (
      owner_id, txn_type_code, doc_date, cash_date, doc_no, memo, attachments,
      asset_id, contact_id, contract_id, owner_reason, funding_source,
      source, source_ref, reverses_id,
      wht_rate, wht_amount, wht_certificate_no,
      is_intercompany, counter_owner_id, intercompany_nature)
    values (
      (v_txn ->> 'owner_id')::uuid,
      p_payload ->> 'txn_type_code',
      v_doc,
      v_cash,
      nullif(p_payload ->> 'doc_no', ''),
      nullif(p_payload ->> 'memo', ''),
      coalesce((select array_agg(a) from jsonb_array_elements_text(p_payload -> 'attachments') as a),
               '{}'::text[]),
      (nullif(p_payload ->> 'asset_id', ''))::uuid,
      (nullif(p_payload ->> 'contact_id', ''))::uuid,
      (nullif(p_payload ->> 'contract_id', ''))::uuid,
      nullif(p_payload ->> 'owner_reason', ''),
      nullif(p_payload ->> 'funding_source', ''),
      v_source::sri_os.txn_source,
      nullif(p_payload ->> 'source_ref', ''),
      (nullif(p_payload ->> 'reverses_id', ''))::uuid,
      v_wht_rate, v_wht_amt, v_wht_cert,
      nullif(v_txn ->> 'counter_owner_id', '') is not null,
      (nullif(v_txn ->> 'counter_owner_id', ''))::uuid,
      nullif(v_txn ->> 'intercompany_nature', ''))
    returning id into v_txn_id;

    for v_line in select value from jsonb_array_elements(v_txn -> 'lines') loop
      insert into sri_os.transaction_lines (
        transaction_id, coa_id, bank_account_id, debit, credit, cf_category, asset_id, memo,
        currency, amount_original, fx_rate, fx_rate_date)
      values (
        v_txn_id,
        (select c.id from sri_os.chart_of_accounts c where c.code = v_line ->> 'coa_code'),
        (nullif(v_line ->> 'bank_account_id', ''))::uuid,
        coalesce((v_line ->> 'debit')::numeric, 0),
        coalesce((v_line ->> 'credit')::numeric, 0),
        (nullif(v_line ->> 'cf_category', ''))::sri_os.cf_group,
        (nullif(v_line ->> 'asset_id', ''))::uuid,
        nullif(v_line ->> 'memo', ''),
        nullif(v_line ->> 'currency', ''),
        (nullif(v_line ->> 'amount_original', ''))::numeric,
        (nullif(v_line ->> 'fx_rate', ''))::numeric,
        (nullif(v_line ->> 'fx_rate_date', ''))::date);
    end loop;

    v_ids := v_ids || v_txn_id;
  end loop;

  update sri_os.post_entry_requests r
     set transaction_ids = v_ids
   where r.id = v_req;

  -- ด่านสมดุล/บรรทัดครบ/คู่ข้ามผู้ถือเป็น constraint trigger แบบ deferred (ยิงตอน commit)
  -- → บังคับให้ยิง **ตอนนี้** เพื่อให้คนกดปุ่มได้ข้อความที่อ่านรู้เรื่องทันที
  --   นี่คือการทำให้ด่าน **เข้มขึ้น (เร็วขึ้น)** ไม่ใช่ผ่อน · แล้วคืนสภาพ deferred ให้เหมือนเดิม
  set constraints all immediate;
  set constraints all deferred;

  return jsonb_build_object(
    'transaction_ids', to_jsonb(v_ids),
    'replayed', false,
    'fingerprint', v_fp);
end $fn$;

comment on function fn_post_entry(jsonb) is
  'ปากทางเดียวที่เขียนผลลัพธ์ของ buildPosting() ลง transactions + transaction_lines ในธุรกรรมเดียว (D-091) · **security invoker** → RLS เป็นด่านเดียว · **ไม่มีด่านคู่บัญชี/bank ซ้ำในประตูอีกแล้ว** ด่านนั้นอยู่ที่ trg_lines_rule_coa และ trg_lines_rule_bank_cash บนตาราง (กันการ INSERT ตรงด้วย) · **กฎ cash_date (มีบรรทัด 11xx ⟺ cash_date ไม่เป็น null) ของจริงอยู่ที่ trg_txn_cash_date_matches_lines บนตารางแล้ว (20261009000001)** ด่านในประตู (หัวข้อ 4) เหลือไว้เพื่อให้ error ถึงผู้ใช้ก่อนถึง commit เท่านั้น ห้ามถือว่าเป็นแหล่งความจริง · ประตูยังหลวมกว่า trigger ในมิติเดียว: มันอ่าน cash_date ระดับ payload ใบเดียวแล้วใช้กับทุกขา และรวม v_has_cash ข้ามทุกขา → รายการข้ามผู้ถือที่ขาหนึ่งมีเงินสดขาหนึ่งไม่มี ลงผ่านประตูไม่ได้ (ต้องแก้รอบหน้า) · ประตูเหลือด่านของข้อมูลที่ยังไม่ถูกเขียน: หมวดที่ตารางกฎไม่ระบุบัญชี · รหัสที่ไม่มีในผังบัญชี · ลักษณะข้ามผู้ถือที่ไม่รู้จัก (อ่านจาก fn_intercompany_pairs() ไม่มีสำเนาในฟังก์ชัน) · ข้ามผู้ถือต้องครบคู่ (ข้อ 2) · fingerprint จาก payload ที่ normalise แล้ว (ข้อ 4) · **รับช่อง wht_rate/wht_amount/wht_certificate_no แล้ว (D-111 ข้อ 1 · 20261025000001)** ซึ่งก่อนหน้านี้ทำให้บันทึกการถูกหักภาษี ณ ที่จ่ายไม่ได้เลยทุกทาง (ใส่มาก็เด้ง "ช่องที่ยังไม่รู้จัก" · ไม่ใส่ก็โดน trg_assert_wht_gross ตอน commit) · ประตูตรวจแค่ **รูป** ของสามช่องนั้น (อัตรากับยอดมาคู่กัน · ใบรับรองติดได้เฉพาะใบที่ถูกหักจริง · หมวดต้องหักภาษีได้) ส่วนกฎบัญชี "เงินได้ต้องเป็นยอดเต็ม" อยู่ที่ fn_assert_wht_gross_for() ที่เดียว · **รับสี่ช่องของบรรทัด currency/amount_original/fx_rate/fx_rate_date แล้ว (FCD · 25/10)** ยอดบาทยังอยู่ที่ debit/credit เหมือนเดิม — ประตูตรวจแค่ชนิดข้อมูล ส่วนกฎ "บัญชีไม่ใช่บาทต้องมีอัตรา" และ "ยอดบาทต้องมาจากอัตรา" อยู่ที่ trg_lines_fx_shape ที่เดียว';

revoke all on function fn_post_entry(jsonb) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_post_entry(jsonb) from anon';
  execute 'grant execute on function sri_os.fn_post_entry(jsonb) to authenticated';
end $$;

-- ============================================================
-- 9 · ทะเบียนด่านคอลัมน์ (D-089) · ของใหม่ต้องไม่หลุดเงียบ
-- ============================================================
insert into column_exposure (table_name, column_name, exposure, min_permission, rationale) values
  ('bank_accounts', 'currency', 'open', null,
   'สกุลเงินของบัญชี · ชั้นเดียวกับ assets.currency (open) เพราะฟอร์มคีย์รายการต้องรู้ว่าบัญชีนี้เป็นสกุลอะไรเพื่อถามอัตราแลกเปลี่ยน · รู้ว่าบัญชีเป็น USD ไม่ได้บอกว่ามีเงินเท่าไร'),
  ('transaction_lines', 'currency', 'row', 'ledger.read',
   'สกุลของยอดสกุลเดิมของบรรทัด · เป็นข้อมูลของรายการเงิน ชั้นเดียวกับ debit/credit · policy lines_by_txn กรองทั้งแถวอยู่แล้ว'),
  ('transaction_lines', 'amount_original', 'row', 'ledger.read',
   'ยอดในสกุลเดิม = ตัวเลขเงิน (คู่กับอัตราแล้วได้ยอดบาท) · ชั้นเดียวกับ debit/credit'),
  ('transaction_lines', 'fx_rate', 'row', 'ledger.read',
   'อัตราที่ใช้แปลงเป็นบาท · คู่กับยอดสกุลเดิมแล้วได้ยอดบาท จึงต้องอยู่ชั้นเดียวกัน'),
  ('transaction_lines', 'fx_rate_date', 'row', 'ledger.read',
   'วันของอัตราที่ใช้ · ใช้ตรวจย้อนว่าอัตราไหนถูกใช้ จึงต้องอ่านได้คู่กับอัตรา')
on conflict (table_name, column_name) do update
  set exposure = excluded.exposure, min_permission = excluded.min_permission,
      rationale = excluded.rationale;

select fn_apply_column_exposure();
select fn_column_exposure_guard();

-- ============================================================
-- 10 · guard ท้ายไฟล์ — ดังตอน migrate ไม่ใช่ตอนผู้ใช้กดบันทึก
-- ============================================================
do $$
declare v text; n int;
begin
  -- (ก) ผังบัญชีต้องมีสามรหัสใหม่ และประเภทต้องถูก (ประเภทคือตัวบังคับกฎ)
  select string_agg(x.code || ' (' || coalesce(c.type::text, 'ไม่มีในผังบัญชี') || ')', ', ') into v
    from (values ('3410', 'equity'), ('4330', 'income'), ('5930', 'expense')) x(code, want)
    left join sri_os.chart_of_accounts c on c.code = x.code
   where c.code is null or c.type::text <> x.want;
  if v is not null then
    raise exception 'ผังบัญชีใน DB ยังไม่มีรหัสของเรื่องอัตราแลกเปลี่ยน หรือประเภทไม่ถูก: % — apply ไฟล์ seed_rules ที่ generate ด้วย npm run sync:rules ก่อน (3410 ต้องเป็น equity ไม่ใช่ income/expense ไม่งั้นผลต่างที่ยังไม่เกิดจริงจะไหลเข้างบกำไรขาดทุน)', v;
  end if;

  -- (ข) หมวดของเรื่องนี้ต้อง seed มาแล้ว ไม่งั้นด่านทั้งไฟล์ไม่มีอะไรให้คุม
  select string_agg(x.code, ', ' order by x.code) into v
    from unnest(array['trf.fx_translate_up', 'trf.fx_translate_down', 'trf.fx_convert']) x(code)
   where not exists (select 1 from sri_os.txn_types t where t.code = x.code);
  if v is not null then
    raise exception 'ตารางกฎใน DB ยังไม่มีหมวด % → apply ไฟล์ seed_rules ก่อน', v;
  end if;

  -- (ค) หมวดแปลงค่าต้องไม่ประกาศบัญชี P&L ไว้เลย (ตรวจที่ตัวกฎ ไม่ใช่แค่ที่บรรทัด)
  select count(*) into n
    from sri_os.txn_types t
    join sri_os.chart_of_accounts c
      on c.code in (t.dr_coa_code, t.cr_coa_code,
                    coalesce(t.gain_coa_code, ''), coalesce(t.loss_coa_code, ''),
                    coalesce(t.interest_coa_code, ''), coalesce(t.accrual_coa_code, ''))
   where '3410' in (t.dr_coa_code, t.cr_coa_code)
     and c.type::text in ('income', 'expense');
  if n > 0 then
    raise exception 'มีหมวดแปลงค่าที่คู่บัญชีแตะบัญชีรายได้/ค่าใช้จ่าย % จุด — ผลต่างค่าเงินที่ยังไม่ได้แลกห้ามเข้างบกำไรขาดทุน · แก้ที่ src/lib/rules/tx-rules.ts แล้ว sync ใหม่', n;
  end if;

  -- (ง) **3410 ต้องมีทางล้าง** (บทเรียนข้อ 7) — หมวดที่รับรู้กำไร/ขาดทุนค่าเงินจริง
  select count(*) into n from sri_os.txn_types t
   where t.gain_coa_code = '4330' or t.loss_coa_code = '5930';
  if n = 0 then
    raise exception 'ไม่มีหมวดใดที่รับรู้กำไร/ขาดทุนอัตราแลกเปลี่ยนจริงเลย — เปิดให้แปลงค่าได้แต่ล้างไม่ได้ แปลว่าผลต่างใน 3410 โตขึ้นตลอดไปและไม่มีใครรู้ว่ากำไรจริงเท่าไร';
  end if;

  -- (จ) ชุดบัญชี "ยังไม่เกิดจริง" ต้องมีทั้งสองรหัส และด่านต้องอ่านจากฟังก์ชันนั้น
  if not ('3400' = any (sri_os.fn_unrealised_equity_coas()))
     or not ('3410' = any (sri_os.fn_unrealised_equity_coas())) then
    raise exception 'fn_unrealised_equity_coas() ไม่ครบ (ต้องมี 3400 และ 3410) — ด่านห้ามเข้า P&L จะเลิกคุมก้อนที่ขาดไปเงียบๆ';
  end if;
  select count(*) into n
    from unnest(array['fn_assert_revaluation_no_pl', 'fn_assert_revaluation_type_stays_clean']) f(name)
    join pg_proc p on p.proname = f.name
    join pg_namespace ns on ns.oid = p.pronamespace and ns.nspname = 'sri_os'
   where pg_get_functiondef(p.oid) like '%fn_unrealised_equity_coas%';
  if n <> 2 then
    raise exception 'ด่าน "ยังไม่เกิดจริงห้ามแตะ P&L" ไม่ได้อ่านชุดบัญชีจาก fn_unrealised_equity_coas() (% ตัวจาก 2) — ชุดที่สองที่พิมพ์มือจะไม่ตรงกันวันหนึ่ง', n;
  end if;

  -- (ฉ) constraint + FK + trigger ต้องมีจริงและ validate แล้ว
  select string_agg(x.want, ', ') into v
    from (values ('bank_accounts_currency_allowed'), ('transaction_lines_fx_shape'),
                 ('transaction_lines_fx_rate_fk')) x(want)
   where not exists (select 1 from pg_constraint c where c.conname = x.want and c.convalidated);
  if v is not null then
    raise exception 'constraint หายไปหรือยังไม่ validate: % — constraint ที่ไม่ validate เท่ากับไม่มีด่าน', v;
  end if;
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.transaction_lines'::regclass
                    and g.tgname = 'trg_lines_fx_shape' and not g.tgisinternal
                    and (g.tgtype & 1) <> 0 and (g.tgtype & 2) <> 0 and (g.tgtype & 4) <> 0
                    and (g.tgtype & 16) <> 0) then
    raise exception 'ไม่มี trigger before insert or update for each row ของ fn_assert_line_fx';
  end if;
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.transaction_lines'::regclass
                    and g.tgname = 'trg_assert_fx_unrealized_cleared' and not g.tgisinternal
                    and g.tgdeferrable and g.tginitdeferred) then
    raise exception 'ไม่มี constraint trigger แบบ deferred ของ fn_assert_fx_unrealized_cleared — ด่านที่ยิงตอนใส่บรรทัดแรกจะปฏิเสธใบที่ถูกต้อง';
  end if;

  -- (ช) บัญชีเดิมทั้งหมดต้องเป็นบาท (backfill ด้วย default สำเร็จ)
  select count(*) into n from sri_os.bank_accounts where currency is null;
  if n > 0 then
    raise exception 'มีบัญชีธนาคาร % แถวที่ไม่มีสกุลเงิน — backfill ไม่สำเร็จ', n;
  end if;

  -- (ซ) ของเดิมต้องไม่พัง: บรรทัดที่มีอยู่แล้วต้องไม่มีใครติดด่านใหม่
  select count(*) into n from sri_os.transaction_lines l
   where l.currency is not null;
  raise notice 'FCD พร้อม: bank_accounts.currency (ค่าตั้งต้น THB · % บัญชี) · transaction_lines มีสกุล/ยอดสกุลเดิม/อัตรา (% บรรทัดที่เป็นเงินตรา) · 3410 equity + 4330/5930 P&L · ด่าน 2 ตัวบน transaction_lines',
    (select count(*) from sri_os.bank_accounts), n;
end $$;
