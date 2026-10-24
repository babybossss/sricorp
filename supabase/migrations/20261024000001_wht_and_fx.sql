-- ============================================================
-- SRI OS · ภาษีหัก ณ ที่จ่าย (WHT) + หลายสกุลเงินฝั่งการลงทุน (D-111 ข้อ 1 และ 2)
--
-- ของในโค้ดที่ไฟล์นี้เป็น "ด่านฝั่ง DB" ให้:
--   src/lib/rules/coa.ts        → 1800 ภาษีถูกหักรอเครดิต · 3400 ส่วนเกินทุนจากการตีราคา
--   src/lib/rules/tx-rules.ts   → inv.wht_refund · adj.revalue_* (4 หมวด)
--   src/lib/rules/currency.ts   → THB · USD · JPY · CNY (ไม่ได้ sync อัตโนมัติ ดูข้อ 2)
--   src/lib/ledger/posting.ts   → คู่บัญชีสามบรรทัดของ WHT · คู่บัญชีตีราคา
--   src/lib/ledger/mark-to-market.ts → การกลับรายการตีราคาของเดือนก่อน
--
-- **แถวของตารางกฎไม่ได้อยู่ในไฟล์นี้** — มาจาก 20261024152156_seed_rules.sql
-- ที่ generate ด้วย `npm run sync:rules` (ห้ามเขียนคู่บัญชีลง migration ด้วยมือ)
-- ไฟล์นี้มีแต่ schema + ด่าน ซึ่งไม่ใช่สิ่งที่ sync ได้จากตารางกฎ
--
-- ------------------------------------------------------------
-- ลำดับ: **ต้องรันหลัง 20261020000002_column_exposure_ledger.sql**
--   และ **ก่อน 20261020000003_replay_end_state_guard.sql**
--   ลงทะเบียนใน supabase/migration-order.txt (ห้ามพึ่งลำดับชื่อไฟล์)
--
-- ทำไมต้องหลัง column_exposure: ไฟล์นี้เพิ่มคอลัมน์ให้ตารางที่ถูกจัดประเภทแล้ว
--   (transactions · asset_valuations) และสร้างตารางใหม่ (fx_rates)
--   `fn_column_exposure_guard()` พังทันทีถ้ามีคอลัมน์/ตารางที่ยังไม่จัดประเภท
--   → ถ้ารันก่อน จะไปทำให้ 20261020000000 พังที่ guard ท้ายไฟล์ของมันเอง
-- ทำไมต้องหลัง 20261007000007: ไฟล์นั้น `create or replace fn_asset_cost_basis`
--   ไฟล์นี้เขียนมันใหม่ (ข้อ 8) ถ้ารันก่อน จะถูกเขียนทับกลับเป็นรุ่นที่นับ
--   บรรทัดตีราคาเป็นต้นทุน แล้วกำไรจากการขายตาม FIFO จะต่ำกว่าจริงทุกใบ
-- ทำไมต้องหลัง 20261006190000: บล็อก SWEEP ของไฟล์นั้นลบ policy ที่ไม่อยู่ใน
--   allow-list ทิ้งทั้งหมด → policy ของ fx_rates ที่สร้างก่อนหน้านั้นจะหายเงียบๆ
-- ------------------------------------------------------------
-- idempotent: add column if not exists · create table if not exists ·
--   drop constraint if exists ก่อน add · create or replace function ·
--   drop policy/trigger if exists ก่อน create · insert ... on conflict do update
--   → replay ซ้ำได้ตลอด ไม่มีขั้นตอนที่ต้องรันครั้งเดียว
--
-- ย้อนกลับ (rollback) — เรียงจากหลังมาหน้า:
--   -- 1. ด่าน
--   -- drop trigger if exists trg_lines_s_revaluation_no_pl on sri_os.transaction_lines;
--   -- drop trigger if exists trg_assert_wht_gross on sri_os.transaction_lines;
--   -- drop function if exists sri_os.fn_assert_revaluation_no_pl();
--   -- drop function if exists sri_os.fn_assert_wht_gross();
--   -- drop function if exists sri_os.fn_txn_type_can_withhold(text);
--   -- 2. คู่บัญชีที่บรรทัดลงได้ + ต้นทุนทรัพย์ → รัน 20261008000012 และ 20261007000007 ซ้ำ
--   --    (ทั้งคู่เป็น create or replace จึงคืนรุ่นก่อนไฟล์นี้ได้ตรงๆ)
--   -- 3. ทะเบียนด่านคอลัมน์
--   -- delete from sri_os.column_exposure where table_name = 'fx_rates'
--   --    or (table_name = 'transactions' and column_name like 'wht\_%')
--   --    or (table_name = 'asset_valuations' and column_name in ('currency','value_original','fx_rate','fx_rate_date'));
--   -- delete from sri_os.column_exposure_tables where table_name = 'fx_rates';
--   -- select sri_os.fn_apply_column_exposure();
--   -- 4. คอลัมน์และตาราง (ทำได้เฉพาะตอนยังไม่มีข้อมูลจริง — ลบคอลัมน์ = ลบตัวเลขเงิน)
--   -- alter table sri_os.asset_valuations drop constraint if exists asset_valuations_fx_shape;
--   -- alter table sri_os.asset_valuations drop column if exists fx_rate_date, drop column if exists fx_rate,
--   --   drop column if exists value_original, drop column if exists currency;
--   -- alter table sri_os.transactions drop column if exists wht_certificate_no,
--   --   drop column if exists wht_amount, drop column if exists wht_rate;
--   -- drop table if exists sri_os.fx_rates;
--   -- alter table sri_os.assets drop constraint if exists assets_currency_allowed;
--   -- (รหัส 1800/3400 ในผังบัญชีไม่ลบ — บัญชีที่มีรายการอ้างอยู่ลบไม่ได้
--   --  และไฟล์ seed ไม่ลบรหัสที่หายไปจาก coa.ts อยู่แล้ว ดูหัวไฟล์ seed)
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 0 · ของที่ต้องมีก่อน — รันสลับลำดับต้องพังให้เห็น ไม่ใช่เดา
-- ============================================================
do $$
declare v text;
begin
  if to_regclass('sri_os.column_exposure') is null
     or to_regclass('sri_os.column_exposure_tables') is null then
    raise exception 'ไม่มีทะเบียนด่านคอลัมน์ → ต้องรัน 20261020000000_column_exposure.sql ก่อนไฟล์นี้ (ดู supabase/migration-order.txt)';
  end if;

  if not exists (select 1 from sri_os.column_exposure_tables t
                  where t.table_name = 'transactions' and t.review_state = 'classified') then
    raise exception 'ตาราง transactions ยังไม่ถูกจัดประเภท → ต้องรัน 20261020000002_column_exposure_ledger.sql ก่อนไฟล์นี้ ไม่งั้นคอลัมน์ wht_* ที่เพิ่มในไฟล์นี้จะไม่มีด่านคอลัมน์';
  end if;

  -- ผังบัญชีต้องมีสองรหัสใหม่แล้ว (มาจากไฟล์ seed ที่ generate จาก coa.ts)
  select string_agg(x.code, ', ') into v
    from unnest(array['1800', '3400']) x(code)
   where not exists (select 1 from sri_os.chart_of_accounts c where c.code = x.code);
  if v is not null then
    raise exception 'ผังบัญชีใน DB ยังไม่มีรหัส % → ต้อง apply ไฟล์ seed_rules ที่ generate จาก src/lib/rules/coa.ts ก่อน (npm run sync:rules) ไม่งั้นด่านในไฟล์นี้อ้างบัญชีที่ไม่มีจริง', v;
  end if;

  -- ประเภทบัญชีต้องเป็นอย่างที่ด่านทั้งไฟล์นี้พึ่ง
  if (select type::text from sri_os.chart_of_accounts where code = '1800') <> 'asset' then
    raise exception '1800 ต้องเป็นบัญชีสินทรัพย์ — ภาษีที่ถูกหักไว้ยังเป็นเงินของเรา ถ้าเป็นค่าใช้จ่าย กำไรจะต่ำกว่าจริงและเครดิตภาษีจะหายไปจากงบดุล';
  end if;
  if (select type::text from sri_os.chart_of_accounts where code = '3400') <> 'equity' then
    raise exception '3400 ต้องเป็นบัญชีส่วนของเจ้าของ — ลูกพี่สั่ง 24/10 ว่ากำไร/ขาดทุนจากการตีราคาที่ยังไม่ได้ขาย ห้ามเข้างบกำไรขาดทุนเด็ดขาด ถ้าเป็น income/expense กฎนั้นถูกละเมิดตั้งแต่ผังบัญชี';
  end if;

  -- 1800 ห้ามอยู่ในช่วงเงินสด (เหตุผลเดียวกับ 1290) — ถ้าอยู่ งบกระแสเงินสดจะเพี้ยน
  if '1800' ~ '^11[0-9][0-9]$' then
    raise exception 'รหัส 1800 ตกอยู่ในช่วงบัญชีเงินสด (11xx) → ภาษีที่ถูกหักจะถูกนับเป็นเงินเข้าบัญชี';
  end if;
end $$;

-- ============================================================
-- 1 · transactions · อัตราที่ถูกหักและเลขที่ใบรับรอง (D-111 ข้อ 1)
--
-- วางไว้ที่หัวรายการ **ไม่ใช่ตารางแยก** ด้วยเหตุผลเดียวกับ vat_rate/tax_invoice_no
-- ที่มีอยู่แล้ว: หนึ่งใบมีการหักภาษีได้ครั้งเดียว (ผู้จ่ายรายเดียว อัตราเดียว
-- ใบรับรองใบเดียว) ตารางแยกจะเปิดช่องให้มีสองแถวต่อใบ ซึ่งไม่มีความหมายทางบัญชี
-- และทำให้ด่าน "ยอดในสมุดต้องเท่ายอดในใบรับรอง" ต้องรวมหลายแถวก่อนเทียบ
-- ============================================================
alter table transactions
  add column if not exists wht_rate           numeric(5,2),
  add column if not exists wht_amount         numeric(18,2),
  add column if not exists wht_certificate_no text;

comment on column transactions.wht_rate is
  'อัตราภาษีหัก ณ ที่จ่ายที่ผู้จ่ายหักไว้ (ร้อยละ) · null = ไม่ได้ถูกหัก · D-111 ข้อ 1';
comment on column transactions.wht_amount is
  'ยอดภาษีที่ถูกหักไว้ตามใบรับรอง (บาท) · ต้องเท่ากับยอดเดบิตบรรทัด 1800 ของใบนี้ (trg_assert_wht_gross)';
comment on column transactions.wht_certificate_no is
  'เลขที่ใบรับรองการหักภาษี ณ ที่จ่าย · ฝั่ง corporate_strict บังคับ (assertEvidencePolicy) เพราะไม่มีใบ = เครดิตภาษีใช้ไม่ได้ตอนยื่น';

alter table transactions drop constraint if exists transactions_wht_shape;
alter table transactions
  add constraint transactions_wht_shape check (
    -- อัตราต้องอยู่ในช่วงที่มีความหมาย · 0 หรือ 100 ไม่ใช่การหักภาษี
    (wht_rate is null or (wht_rate > 0 and wht_rate < 100))
    -- ยอดที่ถูกหักต้องเป็นบวก (ไม่มีการ "หักติดลบ")
    and (wht_amount is null or wht_amount > 0)
    -- **อัตรากับยอดต้องมาคู่กันเสมอ** — มียอดแต่ไม่มีอัตรา = ตรวจกับใบรับรองไม่ได้
    --   มีอัตราแต่ไม่มียอด = ไม่รู้ว่าสินทรัพย์ภาษีเป็นเท่าไร
    and ((wht_rate is null) = (wht_amount is null))
    -- เลขที่ใบรับรองมีได้เฉพาะใบที่ถูกหักภาษีจริง (กันค่าขยะที่ติดมากับใบอื่น)
    and (wht_certificate_no is null or wht_amount is not null)
    and (wht_certificate_no is null or length(btrim(wht_certificate_no)) > 0)
  );

-- ============================================================
-- 2 · สกุลเงินที่อนุญาต (D-111 ข้อ 2)
--
-- **สำเนาของ `CURRENCIES` ใน src/lib/rules/currency.ts** — เพิ่มสกุลที่นั่น
-- ต้องออก migration ใหม่ด้วย ไม่งั้น DB ปฏิเสธทรัพย์สกุลใหม่ตอนผู้ใช้กดบันทึก
-- (ไฟล์นั้นไม่ได้อยู่ในชุดที่ `npm run sync:rules` คัดลอก เพราะไม่ใช่คู่บัญชี
--  เทสต์ zz_wht_and_fx_test.sql ตรวจว่า DB รู้จักสี่สกุลนี้พอดี ไม่ขาดไม่เกิน)
--
-- **สมุดบัญชียังเป็นบาทล้วน** — ไม่มีคอลัมน์สกุลเงินใน transaction_lines
-- และห้ามเพิ่ม (functional currency = บาท ซึ่งถูกต้องสำหรับนิติบุคคลไทย)
-- ของต่างประเทศเข้าสมุดในรูป "ทรัพย์ที่ตีมูลค่าเป็นบาท" เท่านั้น
-- ============================================================
alter table assets drop constraint if exists assets_currency_allowed;
alter table assets
  add constraint assets_currency_allowed check (currency in ('THB', 'USD', 'JPY', 'CNY'));

comment on column assets.currency is
  'สกุลเงินของทรัพย์ · จำกัดไว้ THB/USD/JPY/CNY (D-111 ข้อ 2) · สำเนาของ CURRENCIES ใน src/lib/rules/currency.ts';

-- ------------------------------------------------------------
-- ตารางอัตราแลกเปลี่ยน · เฟสนี้ป้อนมือ ตัวดึงจาก ธปท. เป็นงานแยก
--
-- `source` มีตั้งแต่แถวแรกโดยเจตนา: วันที่ตัวดึงอัตโนมัติเข้ามา เราต้องแยกออกได้
-- ว่าอัตราไหนคนพิมพ์และอัตราไหนระบบดึง · เติมย้อนหลังให้แถวเก่าไม่ได้เพราะ
-- ไม่มีใครจำได้แล้วว่าตัวเลขนั้นมาจากไหน
--
-- คีย์เป็น (currency, rate_date) เพื่อให้ `asset_valuations` อ้างด้วย FK ได้
-- → **การตีราคาที่ไม่มีอัตราในตารางนี้ ถูกปฏิเสธที่ DB** ไม่ใช่แค่ที่ application
-- ------------------------------------------------------------
create table if not exists fx_rates (
  currency     text not null check (currency in ('THB', 'USD', 'JPY', 'CNY')),
  rate_date    date not null,
  -- บาทต่อหนึ่งหน่วย · ทิศเดียวในระบบ กันการคูณกลับทิศ (เยนอัตรา 0.23 หารแล้วยังดูเป็นไปได้)
  thb_per_unit numeric(18,8) not null check (thb_per_unit > 0),
  source       text not null check (source in ('manual', 'bot_api')),
  note         text,
  created_by   uuid references app_users(id),
  created_at   timestamptz not null default now(),
  primary key (currency, rate_date),
  -- บาทต่อบาทต้องเป็น 1 เท่านั้น ไม่งั้นยอดบาทถูกแปลงสองรอบ
  constraint fx_rates_base_currency_is_one check (currency <> 'THB' or thb_per_unit = 1)
);

comment on table fx_rates is
  'อัตราแลกเปลี่ยนรายวัน (ปกติใช้วันสิ้นเดือน) · บาทต่อหนึ่งหน่วย · source แยกอัตราที่คนป้อนออกจากอัตราที่ระบบดึงจาก ธปท. (D-111 ข้อ 2) · asset_valuations อ้างด้วย FK จึงตีราคาโดยไม่มีอัตราไม่ได้';
comment on column fx_rates.thb_per_unit is
  'บาทต่อหนึ่งหน่วยของสกุลนั้น · ทิศเดียวในระบบ (บาท = จำนวน × อัตรา) ห้ามเก็บทิศกลับ';
comment on column fx_rates.source is
  'manual = คนป้อน · bot_api = ระบบดึงจาก ธปท. (ยังไม่ได้ทำ · D-111 บอกว่าเป็นงานแยก)';

create index if not exists fx_rates_date_idx on fx_rates(rate_date desc);

-- อัตราแลกเปลี่ยนไม่ใช่ข้อมูลของใครคนใดคนหนึ่ง → อ่านได้ทุกคนที่ล็อกอิน
-- แต่ **แก้ได้เฉพาะคนที่มี settings.manage** เพราะอัตราผิดหนึ่งตัว = มูลค่าทรัพย์
-- ในงบดุลผิดทั้งก้อน · ไม่ hard-code ชื่อ role (กฎข้อ 5 / D-073)
alter table fx_rates enable row level security;

drop policy if exists fx_rates_read on fx_rates;
create policy fx_rates_read on fx_rates
  for select to authenticated using (true);

drop policy if exists fx_rates_write on fx_rates;
create policy fx_rates_write on fx_rates
  for all to authenticated
  using (sri_os.fn_can('settings.manage'))
  with check (sri_os.fn_can('settings.manage'));

grant select, insert, update, delete on fx_rates to authenticated;

-- ร่องรอยการแก้อัตรา — อัตราที่เปลี่ยนย้อนหลังทำให้การตีราคาเดือนก่อนเปลี่ยนตาม
drop trigger if exists trg_audit_fx_rates on fx_rates;
create trigger trg_audit_fx_rates
  after insert or update or delete on fx_rates
  for each row execute function fn_audit_keyed('currency', 'rate_date');

drop trigger if exists trg_forbid_truncate on fx_rates;
create trigger trg_forbid_truncate before truncate on fx_rates
  for each statement execute function fn_forbid_truncate();

-- ============================================================
-- 3 · asset_valuations · เก็บ **มูลค่าสกุลเดิม + อัตรา + ยอดบาท** (D-111 ข้อ 2)
--
-- ลูกพี่สั่งตรงๆ ว่า "ห้ามเก็บแต่ยอดบาทสุดท้าย ไม่งั้นตรวจย้อนไม่ได้ว่าอัตราไหนถูกใช้"
-- `value` (ที่มีอยู่เดิม) ยังเป็น **ยอดบาท** เสมอ — ทุกรายงานอ่านคอลัมน์นั้นได้ต่อ
-- โดยไม่ต้องรู้เรื่องสกุลเงิน · สามคอลัมน์ใหม่คือ "ที่มาของยอดบาทนั้น"
-- ============================================================
alter table asset_valuations
  add column if not exists currency       text,
  add column if not exists value_original numeric(18,6),
  add column if not exists fx_rate        numeric(18,8),
  add column if not exists fx_rate_date   date;

comment on column asset_valuations.currency is
  'สกุลของ value_original · null = ตีราคาเป็นบาทตรงๆ (ทรัพย์ในประเทศ)';
comment on column asset_valuations.value_original is
  'มูลค่าตลาดในสกุลเดิม · คู่กับ fx_rate เป็นที่มาของ value (ยอดบาท) · D-111 ข้อ 2';
comment on column asset_valuations.fx_rate is
  'อัตราที่ใช้แปลงเป็นบาท (บาทต่อหน่วย) · ต้องตรงกับแถวใน fx_rates ตาม FK';
comment on column asset_valuations.value is
  'มูลค่าเป็น **บาท** เสมอ · ทรัพย์สกุลต่างประเทศต้องเท่ากับ round(value_original × fx_rate, 2) (asset_valuations_fx_shape)';

-- FK เข้า fx_rates → **ไม่มีอัตราในตาราง = ตีราคาไม่ได้** (ปฏิเสธ ไม่ใช่เดาอัตรา)
alter table asset_valuations drop constraint if exists asset_valuations_fx_rate_fk;
alter table asset_valuations
  add constraint asset_valuations_fx_rate_fk
  foreign key (currency, fx_rate_date) references fx_rates(currency, rate_date);

alter table asset_valuations drop constraint if exists asset_valuations_fx_shape;
alter table asset_valuations
  add constraint asset_valuations_fx_shape check (
    -- ไม่ระบุสกุล = ตีราคาเป็นบาท → ต้องไม่มีอัตราและมูลค่าสกุลเดิมค้างมา
    (currency is null and value_original is null and fx_rate is null and fx_rate_date is null)
    -- ระบุสกุล = ต้องครบทั้งชุด **และยอดบาทต้องคูณกันลงตัว**
    or (
      currency is not null
      and value_original is not null and value_original > 0
      and fx_rate is not null and fx_rate > 0
      and fx_rate_date is not null
      and (currency <> 'THB' or fx_rate = 1)
      and value = round(value_original * fx_rate, 2)
    )
  );

-- ============================================================
-- 4 · fn_txn_type_can_withhold · หมวดไหนถูกหักภาษี ณ ที่จ่ายได้
--
-- **สำเนาฝั่ง SQL ของ `canWithholdTax()` ใน src/lib/rules/tx-rules.ts**
-- อ่านฟิลด์ชุดเดียวกันจาก txn_types (ซึ่ง seed มาจากตารางกฎในโค้ด) จึงไม่ใช่
-- "กฎที่สองที่คนพิมพ์แยก" แต่เป็นการอ่านข้อมูลชุดเดียวกันด้วยนิพจน์เดียวกัน
-- `zz_wht_and_fx_test.sql` ตรวจว่าตอบตรงกับกฎทุกแถว (เขียนเงื่อนไขซ้ำอย่างอิสระ)
--
-- ทำเป็นนิพจน์คำนวณ ไม่ใช่คอลัมน์ธง เพราะคอลัมน์ธงกับคู่บัญชีแยกจากกันได้
-- (ธงเป็น true แต่ขาเครดิตไม่ใช่บัญชีรายได้ = ด่านยอมให้ลง 1800 กับรายการที่ไม่ใช่เงินได้)
-- ============================================================
create or replace function fn_txn_type_can_withhold(p_code text) returns boolean
language sql stable security definer set search_path = '' as $fn$
  select exists (
    select 1
      from sri_os.txn_types t
      join sri_os.chart_of_accounts c on c.code = t.cr_coa_code
     where t.code = p_code
       -- 1. เงินเข้า — ไม่มีใครหักภาษีจากเงินที่เราจ่ายออก
       and t.cash_direction = 'in'
       -- 2. ขาเดบิตเป็นเงินสด — ยอดที่เข้าบัญชีคือยอดสุทธิที่ต้องแยกเป็นสองขา
       and t.dr_coa_code ~ '^11[0-9][0-9]$'
       -- 3. ขาเครดิตเป็นบัญชีรายได้ — ภาษีหัก ณ ที่จ่ายหักจากเงินได้เท่านั้น
       and c.type = 'income'
       -- 4. กระแสเงินสดหมวดดำเนินงาน — ให้ทางล้าง (inv.wht_refund) อยู่หมวดเดียวกัน
       and t.cf_group = 'operating'
  );
$fn$;

comment on function fn_txn_type_can_withhold(text) is
  'D-111 ข้อ 1 · สำเนาฝั่ง DB ของ canWithholdTax() ใน src/lib/rules/tx-rules.ts · คำนวณจากคู่บัญชีและทิศเงินของ txn_types ไม่ใช่คอลัมน์ธง · ใช้โดย fn_assert_line_coa_in_rules เพื่อยอมให้บรรทัด 1800 ลงได้เฉพาะหมวดที่หักได้จริง';

revoke all on function fn_txn_type_can_withhold(text) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_txn_type_can_withhold(text) from anon';
  execute 'grant execute on function sri_os.fn_txn_type_can_withhold(text) to authenticated';
end $$;

-- ============================================================
-- 5 · ขยายด่านคู่บัญชีระดับบรรทัด (ของเดิมอยู่ใน 20261008000012)
--
-- ของเดิมอนุญาตเฉพาะ dr/cr/gain/loss/interest/accrual ของหมวดนั้น
-- ซึ่งทำให้ **สองบรรทัดที่ถูกต้องตามกฎใหม่ถูกปฏิเสธ**:
--   1. บรรทัด 1800 ของรายการที่ถูกหักภาษี (ตารางกฎไม่มีคอลัมน์ wht_coa โดยเจตนา
--      เพราะ "หักได้ไหม" คำนวณจากคู่บัญชี ดูข้อ 4)
--   2. บรรทัด 3400 ตอนขายทรัพย์ ซึ่งล้างส่วนเกินทุนจากการตีราคาออกพร้อมกัน
--      (ไม่ล้าง = ส่วนเกินค้างในส่วนของเจ้าของตลอดไป และบัญชีทรัพย์ไม่กลับเป็นศูนย์)
--
-- **เขียนทับทั้งฟังก์ชัน ไม่ใช่สร้างด่านที่สอง** — trigger ยังผูกอยู่กับชื่อฟังก์ชันเดิม
-- และกฎเดียวกันห้ามมีสองเวอร์ชัน (บทเรียนข้อ 5)
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
         t.requires_capital_gain
    into v_allowed, v_capgain
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

  if not (v_code = any (v_allowed)) then
    raise exception 'หมวด "%" ลงบัญชี % ไม่ได้ — ตารางกฎระบุบัญชีของหมวดนี้ไว้เฉพาะ % · คู่บัญชีที่ไม่ตรงหมวดทำให้ผิดทั้งงบ (เช่น เงินกู้กลายเป็นรายได้)',
      v_type, v_code, array_to_string(v_allowed, ', ');
  end if;

  return new;
end $fn$;

comment on function fn_assert_line_coa_in_rules() is
  'ข้อ 3 ของผู้ตรวจ · ทุกบรรทัดต้องใช้บัญชีที่ตารางกฎ (sri_os.txn_types) ระบุของหมวดนั้น · ขาข้ามผู้ถือล็อกเป็นรหัสตรงจาก fn_intercompany_pairs() · บวก 1800 ให้หมวดที่หักภาษี ณ ที่จ่ายได้ (D-111 ข้อ 1) และ 3400 ให้หมวดที่รับรู้กำไร/ขาดทุนจากการขาย ซึ่งต้องล้างส่วนเกินทุนจากการตีราคาพร้อมกัน (D-111 ข้อ 2)';

-- ============================================================
-- 6 · ด่าน: รายการตีราคา **ห้ามแตะบัญชีรายได้/ค่าใช้จ่ายเลย**
--
-- ลูกพี่สั่ง 24/10: *"จะไม่นับ Unrealized PL มาเข้ากำไรขาดทุนเด็ดขาด
-- จะ Book PL เมื่อขายจริงเท่านั้น"* — คำว่า "เด็ดขาด" ทำให้นี่เป็นกติกาชั้นเดียวกับ
-- Money Invariants → **ต้องบังคับที่ DB ด้วย trigger ไม่ใช่แค่ที่ application**
--
-- ตัดสินว่า "ใบนี้เป็นรายการตีราคา" จาก **คู่บัญชีของหมวดใน txn_types** (แตะ 3400)
-- ไม่ใช่จากรายชื่อรหัสหมวด → หมวดตีราคาตัวใหม่ถูกคุมเองทันทีที่ seed ลงมา
--
-- ใบขายทรัพย์ (ที่แตะ 3400 เพื่อล้างส่วนเกินทุน) **ไม่ติดด่านนี้** เพราะหมวดของมัน
-- ไม่ได้มี 3400 อยู่ใน dr/cr — ซึ่งถูก: ใบนั้นต้องรับรู้กำไร/ขาดทุนจริงเข้า P&L
-- ============================================================
create or replace function fn_assert_revaluation_no_pl() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_type text;
  v_code text;
  v_kind text;
begin
  select t.txn_type_code into v_type
    from sri_os.transactions t where t.id = new.transaction_id;
  if v_type is null then
    return new;   -- ไม่มีหัวรายการ → ด่านอื่นปฏิเสธด้วยข้อความของมันเอง
  end if;

  -- ใบนี้เป็นรายการตีราคาหรือไม่ — อ่านจากคู่บัญชีของหมวด
  if not exists (
    select 1 from sri_os.txn_types ty
     where ty.code = v_type
       and '3400' in (ty.dr_coa_code, ty.cr_coa_code)
  ) then
    return new;
  end if;

  select c.code, c.type::text into v_code, v_kind
    from sri_os.chart_of_accounts c where c.id = new.coa_id;

  if v_kind in ('income', 'expense') then
    raise exception 'รายการตีราคา (หมวด %) ลงบัญชี % ซึ่งเป็นบัญชี% ไม่ได้ — กำไร/ขาดทุนจากการตีราคาที่ยังไม่ได้ขาย ห้ามเข้างบกำไรขาดทุนเด็ดขาด (ลูกพี่สั่ง 24/10) ต้องลงที่ 3400 ส่วนเกินทุนจากการตีราคาในส่วนของเจ้าของเท่านั้น · รับรู้กำไร/ขาดทุนจริงได้เฉพาะตอนขายจริง',
      v_type, v_code, case v_kind when 'income' then 'รายได้' else 'ค่าใช้จ่าย' end;
  end if;

  return new;
end $fn$;

comment on function fn_assert_revaluation_no_pl() is
  'D-111 ข้อ 2 · รายการตีราคา (หมวดที่คู่บัญชีแตะ 3400) ห้ามมีบรรทัดในบัญชีรายได้/ค่าใช้จ่าย · คู่กับ assertNoProfitAndLoss() ฝั่ง lib/ledger ซึ่งมีเทสต์ mutation ยืนยันว่าแดงจริง · ที่นี่เป็นด่านที่เขียนตรงเข้าตารางก็ข้ามไม่ได้';

/**
 * **เรียกตรงไม่ได้ทุก role** — รูปเดียวกับ fn_assert_line_coa_in_rules (20261008000012)
 *
 * ฟังก์ชันนี้เป็น security definer ที่อ่าน `transactions` ตรงๆ ซึ่งถูกจัดประเภทเป็น
 * `row` ด้วย ledger.read · ถ้า PUBLIC เรียกได้ มันคือ **ทางข้าม policy ของสมุดเงิน**
 * (ด่าน D-089 ข้อ `row_escape` จับได้และพังตอน migrate — ซึ่งถูกแล้ว)
 * trigger ยังยิงได้ตามปกติ เพราะ trigger ไม่ได้เรียกผ่านสิทธิ์ของผู้คีย์
 */
revoke all on function fn_assert_revaluation_no_pl() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_revaluation_no_pl() from anon, authenticated';
end $$;

-- ชื่อขึ้นต้น trg_lines_s* เพื่อให้ยิง **หลัง** ด่านชุด trg_lines_r* (คู่บัญชีตรงตารางกฎ)
-- ข้อความที่ผู้ใช้เห็นจะได้ชี้สาเหตุที่ตรงที่สุดก่อน
drop trigger if exists trg_lines_s_revaluation_no_pl on transaction_lines;
create trigger trg_lines_s_revaluation_no_pl
  before insert or update on transaction_lines
  for each row execute function fn_assert_revaluation_no_pl();

-- ============================================================
-- 7 · ด่าน: ถูกหักภาษี ณ ที่จ่ายแล้ว **รายได้ต้องเป็นยอดเต็ม**
--
-- ด่านใจกลางของ D-111 ข้อ 1 ฝั่ง DB · ต้องอ่านทุกบรรทัดของใบจึงเป็น
-- **constraint trigger แบบ deferred** เหมือน trg_assert_balanced
-- (ตรวจตอน commit ไม่ใช่ตอนใส่บรรทัดแรก ซึ่งใบยังไม่ครบ)
--
-- สิ่งที่กัน: ใบที่มีบรรทัด 1800 แต่รายได้ลงเป็น **ยอดสุทธิ**
-- ใบนั้น **สมดุลทุกบรรทัด** และผ่านด่านอื่นทั้งหมด — จับได้ด้วยสมการนี้เท่านั้น:
--     เครดิตบัญชีรายได้ = เดบิตเงินสด + เดบิต 1800
-- ============================================================
create or replace function fn_assert_wht_gross() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_txn      uuid := coalesce(new.transaction_id, old.transaction_id);
  v_type     text;
  v_rate     numeric;
  v_amount   numeric;
  v_wht      numeric;
  v_cash     numeric;
  v_income   numeric;
  v_expected numeric;
begin
  select t.txn_type_code, t.wht_rate, t.wht_amount
    into v_type, v_rate, v_amount
    from sri_os.transactions t where t.id = v_txn;
  if v_type is null then
    return null;   -- หัวรายการถูกลบไปแล้ว (cascade) → ไม่มีอะไรให้ตรวจ
  end if;

  select coalesce(sum(case when c.code = '1800' then l.debit - l.credit else 0 end), 0),
         coalesce(sum(case when c.code ~ '^11[0-9][0-9]$' then l.debit - l.credit else 0 end), 0),
         coalesce(sum(case when c.type::text = 'income' then l.credit - l.debit else 0 end), 0)
    into v_wht, v_cash, v_income
    from sri_os.transaction_lines l
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where l.transaction_id = v_txn;

  -- ยังไม่มีบรรทัดเลย (ระหว่างสร้าง) → ปล่อยผ่าน เหมือน trg_assert_balanced
  if not exists (select 1 from sri_os.transaction_lines l where l.transaction_id = v_txn) then
    return null;
  end if;

  -- ---------- (ก) มีบรรทัด 1800 → ต้องเป็นหมวดที่หักภาษีได้ ----------
  if v_wht <> 0 and not sri_os.fn_txn_type_can_withhold(v_type) then
    raise exception 'ใบนี้มีบรรทัดภาษีถูกหัก ณ ที่จ่าย (1800) แต่หมวด "%" ถูกหักภาษีไม่ได้ — ภาษีหัก ณ ที่จ่ายหักจากเงินได้เท่านั้น ไม่ใช่จากการรับคืนเงินต้น เงินมัดจำ หรือการโอนเงินตัวเอง',
      v_type;
  end if;

  -- ---------- (ข) หัวรายการกับบรรทัดต้องเล่าเรื่องเดียวกัน ----------
  if v_wht <> 0 and v_amount is null then
    raise exception 'ใบนี้มีบรรทัดภาษีถูกหัก ณ ที่จ่าย % บาท แต่หัวรายการไม่ได้บันทึก wht_amount/wht_rate — ยอดที่ไม่มีอัตรากำกับ ตรวจกับใบรับรองการหักภาษีไม่ได้ และขอเครดิตคืนไม่ได้',
      v_wht;
  end if;
  if v_amount is not null and v_wht = 0 then
    raise exception 'หัวรายการบันทึกว่าถูกหักภาษี % บาท แต่ไม่มีบรรทัด 1800 ในใบเลย — สินทรัพย์ภาษีหายไปจากสมุด ทั้งที่เงินที่เข้าบัญชีไม่เต็มจำนวน',
      v_amount;
  end if;
  if v_amount is not null and round(v_wht, 2) <> round(v_amount, 2) then
    raise exception 'ยอดภาษีที่หัวรายการบันทึก (%) ไม่เท่ากับยอดในบรรทัด 1800 (%) — สองตัวเลขนี้คือยอดเดียวกัน ต่างกันแปลว่ารายงานภาษีกับสมุดบัญชีจะไม่ตรงกัน',
      v_amount, v_wht;
  end if;

  if v_wht = 0 then
    return null;   -- ไม่ได้ถูกหักภาษี → ไม่มีอะไรต้องตรวจต่อ
  end if;

  -- ---------- (ค) **รายได้ต้องเป็นยอดเต็ม** ----------
  -- เงินสดคือยอดสุทธิ · 1800 คือส่วนที่ถูกหักไว้ · รวมกันต้องเท่ารายได้ที่รับรู้
  -- ใบที่ลงรายได้เป็นยอดสุทธิจะไม่ผ่านสมการนี้ ทั้งที่ยังสมดุลทุกบรรทัด
  if round(v_income, 2) <> round(v_cash + v_wht, 2) then
    raise exception 'รายได้ที่รับรู้ (%) ต้องเท่ากับ เงินสดที่เข้าบัญชี (%) + ภาษีที่ถูกหักไว้ (%) = % — **รายได้ต้องเป็นยอดเต็มก่อนหักภาษีเสมอ** ถ้าลงรายได้เป็นยอดสุทธิ รายได้จะต่ำกว่าจริงและเครดิตภาษีจะไม่ตรงใบรับรอง',
      v_income, v_cash, v_wht, round(v_cash + v_wht, 2);
  end if;

  -- ---------- (ง) ยอดที่ถูกหักต้องสอดคล้องกับอัตรา ----------
  -- ยอม 1 สตางค์เพราะใบรับรองบางใบปัดเศษ · ความคลาดจากการกรอกยอดสุทธิจะใหญ่กว่านี้เสมอ
  v_expected := round(v_income * v_rate / 100, 2);
  if abs(round(v_wht - v_expected, 2)) > 0.01 then
    raise exception 'ภาษีที่ถูกหัก (%) ไม่ตรงกับ % %% ของรายได้เต็มจำนวน % (ควรเป็น %) — ถ้าตัวเลขในใบรับรองถูก แปลว่ายอดรายได้ที่ลงไว้ไม่ใช่ยอดเต็ม',
      v_wht, v_rate, v_income, v_expected;
  end if;

  return null;
end $fn$;

comment on function fn_assert_wht_gross() is
  'D-111 ข้อ 1 · ใบที่มีบรรทัด 1800 ต้องมีรายได้เป็น **ยอดเต็ม**: เครดิตบัญชีรายได้ = เดบิตเงินสด + เดบิต 1800 · และยอดในหัวรายการต้องตรงกับบรรทัด · ใบที่ลงรายได้เป็นยอดสุทธิยังสมดุลทุกบรรทัด จับได้ด้วยสมการนี้เท่านั้น';

-- เรียกตรงไม่ได้ทุก role — เหตุผลเดียวกับ fn_assert_revaluation_no_pl ข้างบน
-- (ตัวนี้อ่านทั้ง transactions และ transaction_lines ซึ่งเป็น row ทั้งคู่)
revoke all on function fn_assert_wht_gross() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_wht_gross() from anon, authenticated';
end $$;

drop trigger if exists trg_assert_wht_gross on transaction_lines;
create constraint trigger trg_assert_wht_gross
  after insert or update or delete on transaction_lines
  deferrable initially deferred
  for each row execute function fn_assert_wht_gross();

-- ============================================================
-- 8 · ต้นทุนทรัพย์ต้องเป็น **ต้นทุนเดิม** ไม่ใช่มูลค่าที่ตีราคาไว้
--
-- `fn_asset_cost_basis()` รวมทุกบรรทัดบัญชีสินทรัพย์ที่ผูกทรัพย์ชิ้นนั้น
-- → บรรทัดตีราคา (Dr 1700 / Cr 3400) จะถูกนับเป็น **ต้นทุน** ทันที
-- แล้วกำไรจากการขายตาม FIFO (D-038) จะต่ำกว่าจริงเท่าส่วนที่ตีราคาไว้
-- และถ้าใบขายล้างส่วนเกินทุนด้วย (ซึ่งต้องทำ) จะเป็นการนับซ้ำรอบที่สอง
--
-- แก้ที่ฟังก์ชัน ไม่ใช่ที่การผูกทรัพย์: ขา 3400 **ต้อง** ผูกทรัพย์ ไม่งั้นตอนขาย
-- จะไม่รู้ว่าส่วนเกินทุนที่ค้างเป็นของทรัพย์ชิ้นไหน แล้วล้างไม่ได้
-- (เนื้อฟังก์ชันที่เหลือคงเดิมจาก 20261007000007 · เพิ่มเงื่อนไขเดียว)
-- ============================================================
create or replace function fn_asset_cost_basis(p_asset uuid)
returns numeric
language sql stable set search_path = '' as $fn$
  select coalesce(sum(l.debit - l.credit), 0)
    from sri_os.transaction_lines l
    join sri_os.transactions t on t.id = l.transaction_id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where l.asset_id = p_asset
     and t.status = 'posted'
     and c.type = 'asset'
     -- ไม่นับบรรทัดเงินสด เพราะเป็นอีกขาของรายการเดียวกัน
     and c.code !~ '^11[0-9][0-9]$'
     -- D-111 ข้อ 2 · ไม่นับใบตีราคา — ต้นทุนต้องเป็นต้นทุนเดิมตาม FIFO (D-038)
     and not exists (
       select 1 from sri_os.txn_types ty
        where ty.code = t.txn_type_code
          and '3400' in (ty.dr_coa_code, ty.cr_coa_code)
     );
$fn$;

comment on function fn_asset_cost_basis is
  'ต้นทุนของทรัพย์ คำนวณสดจาก ledger ใช้เป็นฐานคำนวณ Cap Gain/Loss ตอนขาย · **ไม่นับใบตีราคา** (D-111 ข้อ 2) เพราะต้นทุนต้องเป็นต้นทุนเดิมตาม FIFO (D-038) ไม่ใช่มูลค่าตลาดที่ตีไว้';

revoke all on function fn_asset_cost_basis(uuid) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_asset_cost_basis(uuid) from anon';
  execute 'grant execute on function sri_os.fn_asset_cost_basis(uuid) to authenticated';
end $$;

-- ============================================================
-- 9 · ทะเบียนด่านคอลัมน์ (D-089) · ของใหม่ต้องไม่หลุดเงียบ
-- ============================================================
insert into column_exposure_tables (table_name, review_state, reason) values
  ('fx_rates', 'classified',
   'อัตราแลกเปลี่ยน = ข้อมูลอ้างอิง ไม่ใช่ข้อมูลของใครคนใดคนหนึ่งและไม่ใช่ตัวเลขเงินของบ้าน · อ่านได้ทุกคนที่ล็อกอิน เขียนได้เฉพาะ settings.manage')
on conflict (table_name) do update
  set review_state = excluded.review_state, reason = excluded.reason;

insert into column_exposure (table_name, column_name, exposure, min_permission, rationale)
select 'fx_rates', c, 'open', null,
       'อัตราแลกเปลี่ยนเป็นตัวเลขสาธารณะ (ธปท. ประกาศเอง) · รู้ว่าบาทต่อดอลลาร์เท่าไรไม่ได้บอกว่าบ้านนี้ถืออะไรหรือเท่าไร · หลักเดียวกับผังบัญชีและตาราง permissions'
  from unnest(array['currency', 'rate_date', 'thb_per_unit', 'source', 'note',
                    'created_by', 'created_at']) c
on conflict (table_name, column_name) do update
  set exposure = excluded.exposure, min_permission = excluded.min_permission,
      rationale = excluded.rationale;

-- transactions · คอลัมน์ภาษีหัก ณ ที่จ่าย — ชั้นเดียวกับ vat_rate/tax_invoice_no
insert into column_exposure (table_name, column_name, exposure, min_permission, rationale) values
  ('transactions', 'wht_rate', 'row', 'ledger.read',
   'อัตราภาษีที่ถูกหักไว้ · เป็นตัวเลขของรายการเงิน · fn_can_read_txn กันทั้งแถวอยู่แล้ว เหตุผลเดียวกับ vat_rate'),
  ('transactions', 'wht_amount', 'row', 'ledger.read',
   'ยอดภาษีที่ถูกหักไว้ = ตัวเลขเงิน และบอกขนาดรายได้ของรายการนั้นย้อนกลับได้ (ยอด ÷ อัตรา) · ชั้นเดียวกับ vat_amount'),
  ('transactions', 'wht_certificate_no', 'row', 'ledger.read',
   'เลขที่ใบรับรองการหักภาษี ณ ที่จ่าย · เป็นเลขเอกสารภาษีของรายการ · ชั้นเดียวกับ tax_invoice_no')
on conflict (table_name, column_name) do update
  set exposure = excluded.exposure, min_permission = excluded.min_permission,
      rationale = excluded.rationale;

-- asset_valuations · ที่มาของยอดบาท
-- `value_original` และ `fx_rate` อยู่ชั้นเดียวกับ `value`/`unit_price` ที่มีอยู่แล้ว
-- (เป็นตัวเลขมูลค่า) ส่วน `currency`/`fx_rate_date` เป็นเมทาดาตาของการตีราคา
insert into column_exposure (table_name, column_name, exposure, min_permission, rationale) values
  ('asset_valuations', 'value_original', 'row', 'asset.view_assigned',
   'มูลค่าในสกุลเดิม · เป็นตัวเลขมูลค่าเหมือน value · แถวถูกกรองด้วย fn_can_see_asset'),
  ('asset_valuations', 'fx_rate', 'row', 'asset.view_assigned',
   'อัตราที่ใช้แปลงเป็นบาท · คู่กับ value_original แล้วได้มูลค่าทรัพย์ จึงต้องอยู่ชั้นเดียวกัน'),
  ('asset_valuations', 'currency', 'row', 'asset.view_assigned',
   'สกุลเงินของการตีราคา · บอกว่าทรัพย์ชิ้นนี้เป็นของต่างประเทศ ซึ่งเป็นข้อมูลโครงสร้างพอร์ต'),
  ('asset_valuations', 'fx_rate_date', 'row', 'asset.view_assigned',
   'วันของอัตราที่ใช้ · ใช้ตรวจย้อนว่าอัตราไหนถูกใช้ จึงต้องอ่านได้คู่กับอัตรา')
on conflict (table_name, column_name) do update
  set exposure = excluded.exposure, min_permission = excluded.min_permission,
      rationale = excluded.rationale;

-- ติดด่านตามทะเบียนที่เพิ่งเพิ่ม แล้วตรวจว่าไม่มีอะไรค้าง
select fn_apply_column_exposure();
select fn_column_exposure_guard();

-- ============================================================
-- 10 · guard ท้ายไฟล์ — ดังตอน migrate ไม่ใช่ตอนผู้ใช้กดบันทึก
-- ============================================================
do $$
declare
  n int;
  v text;
begin
  -- (ก) หมวดใหม่ต้อง seed มาแล้วครบ ไม่งั้นด่านทั้งไฟล์นี้ไม่มีอะไรให้คุม
  select string_agg(x.code, ', ' order by x.code) into v
    from unnest(array['inv.wht_refund', 'adj.revalue_securities_up', 'adj.revalue_securities_down',
                      'adj.revalue_commodity_up', 'adj.revalue_commodity_down']) x(code)
   where not exists (select 1 from sri_os.txn_types t where t.code = x.code);
  if v is not null then
    raise exception 'ตารางกฎใน DB ยังไม่มีหมวด % → apply ไฟล์ seed_rules ที่ generate ด้วย npm run sync:rules ก่อน', v;
  end if;

  -- (ข) หมวดตีราคาต้องไม่มีบัญชี P&L อยู่ในคู่บัญชีหรือบัญชีกำไร/ขาดทุนเลย
  --     ตรวจที่ **ตัวกฎ** ไม่ใช่แค่ที่บรรทัด — กฎที่ผิดจะทำให้ทุกใบผิดตั้งแต่ต้น
  select count(*) into n
    from sri_os.txn_types t
    join sri_os.chart_of_accounts c
      on c.code in (t.dr_coa_code, t.cr_coa_code,
                    coalesce(t.gain_coa_code, ''), coalesce(t.loss_coa_code, ''),
                    coalesce(t.interest_coa_code, ''), coalesce(t.accrual_coa_code, ''))
   where '3400' in (t.dr_coa_code, t.cr_coa_code)
     and c.type::text in ('income', 'expense');
  if n > 0 then
    raise exception 'มีหมวดตีราคาที่คู่บัญชีแตะบัญชีรายได้/ค่าใช้จ่าย % จุด — ลูกพี่สั่งว่า Unrealized PL ห้ามเข้างบกำไรขาดทุนเด็ดขาด · แก้ที่ src/lib/rules/tx-rules.ts แล้ว sync ใหม่', n;
  end if;

  -- (ค) หมวดตีราคาต้องไม่มีขาเงินสด (ไม่งั้นด่าน cash_date และการกระทบยอดเพี้ยน)
  select count(*) into n
    from sri_os.txn_types t
   where '3400' in (t.dr_coa_code, t.cr_coa_code)
     and (t.dr_coa_code ~ '^11[0-9][0-9]$' or t.cr_coa_code ~ '^11[0-9][0-9]$'
          or t.cash_direction <> 'none');
  if n > 0 then
    raise exception 'มีหมวดตีราคาที่มีขาเงินสดหรือทิศเงินไม่ใช่ none % หมวด — การตีราคาไม่มีเงินเคลื่อน', n;
  end if;

  -- (ง) **1800 ต้องมีทางล้าง** (บทเรียนข้อ 7) — ขาที่เครดิต 1800 คู่กับเงินสด
  select count(*) into n
    from sri_os.txn_types t
   where t.cr_coa_code = '1800' and t.dr_coa_code ~ '^11[0-9][0-9]$';
  if n = 0 then
    raise exception 'ไม่มีหมวดใดที่ล้างบัญชี 1800 ได้เลย — เปิดให้บันทึกการถูกหักภาษีแต่ล้างไม่ได้ แปลว่ายอดเครดิตภาษีโตขึ้นตลอดไปและไม่มีใครรู้ว่าขอคืนได้เท่าไร';
  end if;

  -- (จ) ต้องมีหมวดที่หักภาษีได้จริงอยู่บ้าง ไม่งั้นด่านข้อ 5 และ 7 ไม่ได้คุมอะไรเลย
  select count(*) into n from sri_os.txn_types t where sri_os.fn_txn_type_can_withhold(t.code);
  if n = 0 then
    raise exception 'fn_txn_type_can_withhold() ไม่คืน true กับหมวดใดเลย — ด่านบรรทัด 1800 จะปฏิเสธทุกใบ และผู้ใช้จะบันทึกรายการที่ถูกหักภาษีไม่ได้เลย';
  end if;

  -- (ฉ) ด่านทั้งสองต้องติดอยู่บนตารางจริง ไม่ใช่มีแต่ฟังก์ชัน
  select string_agg(x.want, ', ') into v
    from (values ('trg_lines_s_revaluation_no_pl'), ('trg_assert_wht_gross')) x(want)
   where not exists (
     select 1 from pg_trigger g
      where g.tgrelid = 'sri_os.transaction_lines'::regclass
        and g.tgname = x.want and not g.tgisinternal);
  if v is not null then
    raise exception 'trigger หายไปจาก transaction_lines: % — ฟังก์ชันที่ไม่ได้ผูกกับตารางไม่ได้กันอะไรเลย', v;
  end if;

  -- (ช) constraint ของสองตารางต้องมีจริงและ validate แล้ว
  select string_agg(x.want, ', ') into v
    from (values ('transactions_wht_shape'), ('asset_valuations_fx_shape'),
                 ('asset_valuations_fx_rate_fk'), ('assets_currency_allowed'))  x(want)
   where not exists (
     select 1 from pg_constraint c where c.conname = x.want and c.convalidated);
  if v is not null then
    raise exception 'constraint หายไปหรือยังไม่ validate: % — constraint ที่ไม่ validate เท่ากับไม่มีด่าน', v;
  end if;

  raise notice 'WHT + FX พร้อม: 1800/3400 อยู่ในผังบัญชี · หมวดที่หักภาษีได้ % หมวด · ด่าน 2 ตัวบน transaction_lines · fx_rates พร้อมรับอัตราป้อนมือ', n;
end $$;
