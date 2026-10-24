-- ============================================================
-- SRI OS · **ยอดยกมา (ตั้งต้นระบบ)** — ฝั่งฐานข้อมูล
--   ตารางกฎ: ประเภท `opening` · 16 หมวดย่อย (seed จาก src/lib/rules/tx-rules.ts)
--
-- ก่อนมีประเภทนี้ **นำเข้ายอดตั้งต้นไม่ได้เลย**: `fn_post_entry` รับเฉพาะหมวดที่
-- ตารางกฎประกาศ และด่านระดับบรรทัด (`fn_assert_line_coa_in_rules`) ยอมเฉพาะ
-- บัญชีที่หมวดนั้นประกาศไว้ → ทุกคำขอถูกปฏิเสธด้วย "ไม่รู้จักหมวด"
--
-- ไฟล์นี้พิสูจน์สามเรื่องที่ถ้าผิดแล้วตัวเลขผิดเงียบๆ:
--   O1 · ลงยอดตั้งต้นสามผู้ถือ → **งบดุลดุลทุกผู้ถือและมุมมองรวม**
--        (สินทรัพย์ = หนี้สิน + ส่วนของเจ้าของ · คิดจากประเภทบัญชีในผังบัญชี)
--   O2 · **ไม่มีบรรทัดไหนเข้างบกำไรขาดทุน** และ cf_group ของทุกหมวดเป็น none
--        → งบกระแสเงินสดของงวดไม่ขยับ (เงินสดยกมาคือยอดต้นงวด)
--   O3 · ลงบัญชีที่หมวดนั้นไม่ได้ประกาศไว้ → **ปฏิเสธ** (คู่บัญชีอยู่ในตารางกฎเท่านั้น)
--   O4 · **MUTATION** — แก้ตารางกฎให้ขาคู่เป็นบัญชีรายได้ แล้ววัดว่ากำไรปลอมเท่าไร
--
-- ทุกใบเดินผ่าน `fn_post_entry` เท่านั้น (ไม่เขียนตารางตรง) เพราะนั่นคือประตูจริง
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
create temporary table o_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into o_uid(label) values ('mgmt');
insert into auth.users(id) select id from o_uid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, 'opening@local', 'mgmt', 'management', true from o_uid u;
select set_config('test.uid', (select id::text from o_uid where label = 'mgmt'), true);

insert into sri_os.user_owner_access(user_id, owner_id)
select (select id from o_uid where label = 'mgmt'), o.id from sri_os.owners o;

-- บัญชีเงินฝากของสามผู้ถือ (ยอดยกมาเงินสดต้องลงทีละบัญชี)
insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
values ('00000000-0000-0000-0000-00000009b001',
        (select id from sri_os.owners where code = 'THANAKORN'), 'BBL', 'ธนากร', 'ธนากร - BBL (ยอดยกมา)'),
       ('00000000-0000-0000-0000-00000009b002',
        (select id from sri_os.owners where code = 'SUTEE'), 'KBANK', 'สุธี', 'สุธี - KBANK (ยอดยกมา)'),
       ('00000000-0000-0000-0000-00000009b003',
        (select id from sri_os.owners where code = 'SUDJIT'), 'SCB', 'สุดจิตต์', 'สุดจิตต์ - SCB (ยอดยกมา)');

insert into sri_os.contacts(id, first_name, types)
values ('00000000-0000-0000-0000-00000009c001', 'ผู้เช่า (ยอดยกมา)', array['tenant']);

create or replace function pg_temp.own(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.owners where code = p_code $fn$;

create or replace function pg_temp.bank(p_code text) returns uuid
language sql stable as $fn$
  select id from sri_os.bank_accounts
   where owner_id = pg_temp.own(p_code) and display_name like '%ยอดยกมา%'
$fn$;

/** บรรทัด — ยอดยกมาไม่ผูกทรัพย์/คู่ค้า (ไฟล์ยอดตั้งต้นเป็นบัญชีคุม) */
create or replace function pg_temp.ln(p_code text, p_dr numeric, p_cr numeric,
                                     p_bank uuid default null) returns jsonb
language sql immutable as $fn$
  select jsonb_strip_nulls(jsonb_build_object(
    'coa_code', p_code, 'debit', p_dr, 'credit', p_cr,
    'cf_category', 'none', 'bank_account_id', p_bank));
$fn$;

/** ใบยอดยกมาหนึ่งใบของผู้ถือหนึ่งคน · `p_cash` = null เมื่อไม่มีบรรทัดเงินสด */
create or replace function pg_temp.open_entry(p_owner text, p_type text, p_memo text,
                                              p_lines jsonb, p_cash date default null)
returns jsonb language sql stable as $fn$
  select jsonb_strip_nulls(jsonb_build_object(
    'txn_type_code', p_type,
    'doc_date', '2026-01-01',
    'cash_date', case when p_cash is null then null else p_cash::text end,
    'memo', p_memo,
    'attachments', jsonb_build_array('ยอดตั้งต้น.pdf'),
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', pg_temp.own(p_owner), 'lines', p_lines))));
$fn$;

create or replace function pg_temp.post(p_payload jsonb) returns uuid
language plpgsql as $fn$
declare v jsonb;
begin
  v := sri_os.fn_post_entry(p_payload);
  if (v ->> 'replayed')::boolean then
    raise exception 'FAIL: fn_post_entry ถือว่าใบนี้เป็นการกดซ้ำ (memo ต้องไม่ซ้ำกัน)';
  end if;
  return ((v -> 'transaction_ids') ->> 0)::uuid;
end $fn$;

create or replace function pg_temp.must_fail_like(p_label text, p_sql text, p_needle text) returns void
language plpgsql as $fn$
declare v text;
begin
  begin
    execute p_sql;
  exception when others then
    v := sqlerrm;
    if v like 'FAIL:%' then raise; end if;
    if position(p_needle in v) = 0 then
      raise exception 'FAIL: % — ปฏิเสธถูกแต่ข้อความไม่มี "%" · ได้: %', p_label, p_needle, v;
    end if;
    return;
  end;
  raise exception 'FAIL: % — คำสั่งควรถูกปฏิเสธแต่สำเร็จ', p_label;
end $fn$;

create or replace function pg_temp.must_pass(p_label text, p_sql text) returns void
language plpgsql as $fn$
begin
  execute p_sql;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: % — เส้นทางที่ถูกต้องถูกปฏิเสธ (กันแน่นเกิน): %', p_label, sqlerrm;
end $fn$;

/**
 * สมการบัญชีของผู้ถือหนึ่งคน (บาท) — **คิดจากประเภทบัญชีในผังบัญชี**
 *   สินทรัพย์ − (หนี้สิน + ส่วนของเจ้าของ) ต้องเป็น 0
 * สินทรัพย์อ่านฝั่งเดบิต · หนี้สิน/ทุน/รายได้อ่านฝั่งเครดิต · ค่าใช้จ่ายอ่านฝั่งเดบิต
 * (รายได้ − ค่าใช้จ่าย เป็นส่วนหนึ่งของส่วนของเจ้าของในสมการนี้)
 */
create or replace function pg_temp.equation(p_owner text default null) returns numeric
language sql stable as $fn$
  select round(coalesce(sum(
           case c.type
             when 'asset'     then v.debit - v.credit
             when 'liability' then -(v.credit - v.debit)
             when 'equity'    then -(v.credit - v.debit)
             when 'income'    then -(v.credit - v.debit)
             when 'expense'   then -(v.debit - v.credit)
           end), 0), 2)
    from sri_os.v_ledger_posted v
    join sri_os.chart_of_accounts c on c.id = v.coa_id
   where p_owner is null or v.owner_id = pg_temp.own(p_owner);
$fn$;

/** ยอดของบัญชีหนึ่ง (ฝั่งเดบิตเป็นบวก) ต่อผู้ถือ หรือรวมทุกผู้ถือ */
create or replace function pg_temp.bal(p_code text, p_owner text default null) returns numeric
language sql stable as $fn$
  select round(coalesce(sum(v.debit - v.credit), 0), 2)
    from sri_os.v_ledger_posted v
    join sri_os.chart_of_accounts c on c.id = v.coa_id
   where c.code = p_code and (p_owner is null or v.owner_id = pg_temp.own(p_owner));
$fn$;

/** กำไรขาดทุนของงวด (รายได้ − ค่าใช้จ่าย) — ยอดยกมาต้องไม่ขยับค่านี้เลย */
create or replace function pg_temp.pl() returns numeric
language sql stable as $fn$
  select round(coalesce(sum(case when c.type = 'income' then v.credit - v.debit
                                 when c.type = 'expense' then -(v.debit - v.credit) end), 0), 2)
    from sri_os.v_ledger_posted v
    join sri_os.chart_of_accounts c on c.id = v.coa_id
   where c.type in ('income', 'expense');
$fn$;

-- ============================================================
-- O0 · ตารางกฎต้องมีประเภทนี้จริง และทุกหมวดต้อง `cf_group = none`
--      (ไล่จากตารางในฐานข้อมูล ไม่ใช่ไล่ไฟล์ — ถ้า seed ไม่ถูก apply ต้องดัง)
-- ============================================================
do $$
declare n int; v text;
begin
  select count(*) into n from sri_os.txn_types where group_code = 'opening';
  if n < 10 then
    raise exception 'FAIL: O0 — ตารางกฎมีหมวดยอดยกมาแค่ % หมวด (seed ยังไม่ถูก apply?) เทสต์นี้จะไม่ได้ตรวจอะไร', n;
  end if;

  /**
   * cf_group ต้อง **ไม่เข้างบสามส่วน** ทุกหมวด ไม่งั้นงวดแรกจะมีเงินสดรับก้อนใหญ่
   * ที่ไม่มีอยู่จริง · ฝั่ง TypeScript เขียนว่า `none` แต่ enum ฝั่ง DB สะกดว่า
   * **`transfer`** (ตัวแปลงอยู่ใน scripts/sync-txn-types.ts ที่เดียว) → เทียบด้วย
   * "ไม่ใช่สามส่วนของงบ" ไม่ใช่เทียบกับคำว่า none ตรงๆ ซึ่งจะพลาดทั้งชุด
   */
  select string_agg(t.code || '=' || t.cf_group::text, ', ') into v
    from sri_os.txn_types t
   where t.group_code = 'opening'
     and t.cf_group in ('operating', 'investing', 'financing');
  if v is not null then
    raise exception 'FAIL: O0 — หมวดยอดยกมาที่เข้างบกระแสเงินสด: %', v;
  end if;

  -- ขาคู่ต้องเป็นส่วนของเจ้าของทุกหมวด (กำไรสะสม) — ไม่ใช่รายได้/ค่าใช้จ่าย
  select string_agg(t.code, ', ') into v
    from sri_os.txn_types t
   where t.group_code = 'opening'
     and '3300' not in (coalesce(t.dr_coa_code, ''), coalesce(t.cr_coa_code, ''));
  if v is not null then
    raise exception 'FAIL: O0 — หมวดยอดยกมาที่ขาคู่ไม่ใช่กำไรสะสม: %', v;
  end if;

  -- และห้ามหมวดไหนประกาศบัญชีพัก (จะกลายเป็นชุดบัญชีที่ด่านยอมให้ลงลูกหนี้ปลอม)
  select string_agg(t.code, ', ') into v
    from sri_os.txn_types t where t.group_code = 'opening' and t.accrual_coa_code is not null;
  if v is not null then
    raise exception 'FAIL: O0 — หมวดยอดยกมาที่มีบัญชีพัก: %', v;
  end if;

  raise notice 'ok O0 · ตารางกฎมีประเภทยอดยกมา % หมวด · cf_group = none ทุกหมวด · ขาคู่เป็นกำไรสะสม · ไม่มีบัญชีพัก', n;
end $$;

-- ------------------------------------------------------------
-- ฐานก่อนลง — **วัดเป็นส่วนต่าง ไม่ใช่ยอดดิบ**
--
-- harness รันทุกไฟล์เทสต์บนฐานข้อมูลเดียวกัน และบางไฟล์ commit ข้อมูลทิ้งไว้
-- (เจอจริง: สุธีมียอดค้างอยู่ −280 จากไฟล์อื่นตอนรันทั้งชุด) → ถ้าเทียบยอดดิบ
-- เทสต์นี้จะแดงเพราะของคนอื่น ไม่ใช่เพราะของที่มันตรวจ
-- ส่วนต่างตอบคำถามที่เราถามจริง: **ใบยอดยกมาทำให้สมการเพี้ยนไหม**
-- ------------------------------------------------------------
create temporary table o_base (label text primary key, value numeric not null);
insert into o_base(label, value) values
  ('eq_all',   pg_temp.equation()),
  ('eq_tk',    pg_temp.equation('THANAKORN')),
  ('eq_st',    pg_temp.equation('SUTEE')),
  ('eq_sj',    pg_temp.equation('SUDJIT')),
  ('pl',       pg_temp.pl()),
  ('tk_1100',  pg_temp.bal('1100', 'THANAKORN')),
  ('tk_1200',  pg_temp.bal('1200', 'THANAKORN')),
  ('tk_1500',  pg_temp.bal('1500', 'THANAKORN')),
  ('tk_1510',  pg_temp.bal('1510', 'THANAKORN')),
  ('tk_2410',  pg_temp.bal('2410', 'THANAKORN')),
  ('tk_2100',  pg_temp.bal('2100', 'THANAKORN')),
  ('tk_3100',  pg_temp.bal('3100', 'THANAKORN')),
  ('tk_3300',  pg_temp.bal('3300', 'THANAKORN'));

create or replace function pg_temp.base(p_label text) returns numeric
language sql stable as $fn$ select value from o_base where label = p_label $fn$;

-- ============================================================
-- O1 · ลงยอดตั้งต้นสามผู้ถือ → งบดุลดุลทุกผู้ถือและมุมมองรวม
--
-- ฉาก (ตัวเลขเลือกให้ตรวจด้วยตาได้):
--   ธนากร  : เงินฝาก 1,000,000 · ลูกหนี้ค่าเช่า 80,000 · อสังหาฯ 5,000,000
--             ค่ารีโนเวท 300,000 · เงินกู้ธนาคาร 2,000,000 · เจ้าหนี้ 120,000
--             แยกทุนตั้งต้น 3,000,000 ออกจากกำไรสะสม
--   สุธี    : เงินฝาก 250,000 · เงินให้กู้ยืม 1,500,000 · ดอกเบี้ยค้างรับ 45,000
--   สุดจิตต์: เงินฝาก 90,000 · หลักทรัพย์ 700,000 · ทองคำ/ทางเลือก 180,000
--             เงินกู้ยืมกรรมการ 500,000
-- ============================================================
do $$
begin
  -- ---------- ธนากร ----------
  perform pg_temp.must_pass('O1 ธนากร เงินฝากยกมา 1,000,000', $q$
    select pg_temp.post(pg_temp.open_entry('THANAKORN', 'opn.cash', 'O1 เงินฝากยกมา ธนากร',
      jsonb_build_array(
        pg_temp.ln('1100', 1000000, 0, pg_temp.bank('THANAKORN')),
        pg_temp.ln('3300', 0, 1000000)), '2026-01-01')) $q$);

  perform pg_temp.must_pass('O1 ธนากร ลูกหนี้ค่าเช่ายกมา 80,000', $q$
    select pg_temp.post(pg_temp.open_entry('THANAKORN', 'opn.receivable_rent', 'O1 ลูกหนี้ค่าเช่ายกมา',
      jsonb_build_array(
        pg_temp.ln('1200', 80000, 0),
        pg_temp.ln('3300', 0, 80000)))) $q$);

  perform pg_temp.must_pass('O1 ธนากร อสังหาฯ ยกมา 5,000,000 (ต้นทุน)', $q$
    select pg_temp.post(pg_temp.open_entry('THANAKORN', 'opn.property', 'O1 อสังหาฯ ยกมา',
      jsonb_build_array(
        pg_temp.ln('1500', 5000000, 0),
        pg_temp.ln('3300', 0, 5000000)))) $q$);

  perform pg_temp.must_pass('O1 ธนากร ค่ารีโนเวทสะสมยกมา 300,000', $q$
    select pg_temp.post(pg_temp.open_entry('THANAKORN', 'opn.renovation', 'O1 ค่ารีโนเวทยกมา',
      jsonb_build_array(
        pg_temp.ln('1510', 300000, 0),
        pg_temp.ln('3300', 0, 300000)))) $q$);

  perform pg_temp.must_pass('O1 ธนากร เงินกู้ธนาคารยกมา 2,000,000', $q$
    select pg_temp.post(pg_temp.open_entry('THANAKORN', 'opn.loan_bank', 'O1 เงินกู้ธนาคารยกมา',
      jsonb_build_array(
        pg_temp.ln('3300', 2000000, 0),
        pg_temp.ln('2410', 0, 2000000)))) $q$);

  perform pg_temp.must_pass('O1 ธนากร เจ้าหนี้ยกมา 120,000', $q$
    select pg_temp.post(pg_temp.open_entry('THANAKORN', 'opn.payable', 'O1 เจ้าหนี้ยกมา',
      jsonb_build_array(
        pg_temp.ln('3300', 120000, 0),
        pg_temp.ln('2100', 0, 120000)))) $q$);

  perform pg_temp.must_pass('O1 ธนากร แยกทุนตั้งต้น 3,000,000', $q$
    select pg_temp.post(pg_temp.open_entry('THANAKORN', 'opn.capital', 'O1 แยกทุนตั้งต้น',
      jsonb_build_array(
        pg_temp.ln('3300', 3000000, 0),
        pg_temp.ln('3100', 0, 3000000)))) $q$);

  -- ---------- สุธี ----------
  perform pg_temp.must_pass('O1 สุธี เงินฝากยกมา 250,000', $q$
    select pg_temp.post(pg_temp.open_entry('SUTEE', 'opn.cash', 'O1 เงินฝากยกมา สุธี',
      jsonb_build_array(
        pg_temp.ln('1100', 250000, 0, pg_temp.bank('SUTEE')),
        pg_temp.ln('3300', 0, 250000)), '2026-01-01')) $q$);

  perform pg_temp.must_pass('O1 สุธี เงินให้กู้ยืมยกมา 1,500,000', $q$
    select pg_temp.post(pg_temp.open_entry('SUTEE', 'opn.loan_principal', 'O1 เงินให้กู้ยืมยกมา',
      jsonb_build_array(
        pg_temp.ln('1300', 1500000, 0),
        pg_temp.ln('3300', 0, 1500000)))) $q$);

  perform pg_temp.must_pass('O1 สุธี ดอกเบี้ยค้างรับยกมา 45,000', $q$
    select pg_temp.post(pg_temp.open_entry('SUTEE', 'opn.receivable_interest', 'O1 ดอกเบี้ยค้างรับยกมา',
      jsonb_build_array(
        pg_temp.ln('1210', 45000, 0),
        pg_temp.ln('3300', 0, 45000)))) $q$);

  -- ---------- สุดจิตต์ ----------
  perform pg_temp.must_pass('O1 สุดจิตต์ เงินฝากยกมา 90,000', $q$
    select pg_temp.post(pg_temp.open_entry('SUDJIT', 'opn.cash', 'O1 เงินฝากยกมา สุดจิตต์',
      jsonb_build_array(
        pg_temp.ln('1100', 90000, 0, pg_temp.bank('SUDJIT')),
        pg_temp.ln('3300', 0, 90000)), '2026-01-01')) $q$);

  perform pg_temp.must_pass('O1 สุดจิตต์ หลักทรัพย์ยกมา 700,000 (ต้นทุน)', $q$
    select pg_temp.post(pg_temp.open_entry('SUDJIT', 'opn.securities', 'O1 หลักทรัพย์ยกมา',
      jsonb_build_array(
        pg_temp.ln('1700', 700000, 0),
        pg_temp.ln('3300', 0, 700000)))) $q$);

  perform pg_temp.must_pass('O1 สุดจิตต์ ทองคำ/ทางเลือกยกมา 180,000 (ต้นทุน)', $q$
    select pg_temp.post(pg_temp.open_entry('SUDJIT', 'opn.gold_alt', 'O1 ทองคำยกมา',
      jsonb_build_array(
        pg_temp.ln('1720', 180000, 0),
        pg_temp.ln('3300', 0, 180000)))) $q$);

  perform pg_temp.must_pass('O1 สุดจิตต์ เงินกู้ยืมกรรมการยกมา 500,000', $q$
    select pg_temp.post(pg_temp.open_entry('SUDJIT', 'opn.loan_director', 'O1 เงินกู้กรรมการยกมา',
      jsonb_build_array(
        pg_temp.ln('3300', 500000, 0),
        pg_temp.ln('2300', 0, 500000)))) $q$);

  raise notice 'ok O1 · ลงยอดตั้งต้นครบสามผู้ถือผ่าน fn_post_entry (14 ใบ)';
end $$;

-- ------------------------------------------------------------
-- O1b · **งบดุลต้องดุลทุกผู้ถือและมุมมองรวม** และยอดแต่ละบัญชีต้องตรงที่กรอก
-- ------------------------------------------------------------
do $$
begin
  -- สมการบัญชีต้องไม่เพี้ยนไปจากฐานเลยทั้งสามผู้ถือและมุมมองรวม
  if pg_temp.equation('THANAKORN') - pg_temp.base('eq_tk') <> 0 then
    raise exception 'FAIL: O1b — งบดุลของธนากรเพี้ยนไปจากฐาน %', pg_temp.equation('THANAKORN') - pg_temp.base('eq_tk');
  end if;
  if pg_temp.equation('SUTEE') - pg_temp.base('eq_st') <> 0 then
    raise exception 'FAIL: O1b — งบดุลของสุธีเพี้ยนไปจากฐาน %', pg_temp.equation('SUTEE') - pg_temp.base('eq_st');
  end if;
  if pg_temp.equation('SUDJIT') - pg_temp.base('eq_sj') <> 0 then
    raise exception 'FAIL: O1b — งบดุลของสุดจิตต์เพี้ยนไปจากฐาน %', pg_temp.equation('SUDJIT') - pg_temp.base('eq_sj');
  end if;
  if pg_temp.equation() - pg_temp.base('eq_all') <> 0 then
    raise exception 'FAIL: O1b — งบดุลมุมมองรวมเพี้ยนไปจากฐาน %', pg_temp.equation() - pg_temp.base('eq_all');
  end if;

  -- ยอดที่กรอกต้องเป็นยอดที่ได้ (ไม่ใช่แค่ดุลแล้วจบ) — เทียบเป็นส่วนต่างจากฐาน
  if pg_temp.bal('1100', 'THANAKORN') - pg_temp.base('tk_1100') <> 1000000
     or pg_temp.bal('1200', 'THANAKORN') - pg_temp.base('tk_1200') <> 80000
     or pg_temp.bal('1500', 'THANAKORN') - pg_temp.base('tk_1500') <> 5000000
     or pg_temp.bal('1510', 'THANAKORN') - pg_temp.base('tk_1510') <> 300000 then
    raise exception 'FAIL: O1b — ยอดสินทรัพย์ของธนากรไม่ตรง (1100 % · 1200 % · 1500 % · 1510 %)',
      pg_temp.bal('1100', 'THANAKORN') - pg_temp.base('tk_1100'),
      pg_temp.bal('1200', 'THANAKORN') - pg_temp.base('tk_1200'),
      pg_temp.bal('1500', 'THANAKORN') - pg_temp.base('tk_1500'),
      pg_temp.bal('1510', 'THANAKORN') - pg_temp.base('tk_1510');
  end if;
  -- หนี้สินอ่านฝั่งเครดิต → ส่วนต่างติดลบ
  if pg_temp.bal('2410', 'THANAKORN') - pg_temp.base('tk_2410') <> -2000000
     or pg_temp.bal('2100', 'THANAKORN') - pg_temp.base('tk_2100') <> -120000 then
    raise exception 'FAIL: O1b — หนี้สินของธนากรไม่ตรง (2410 % · 2100 %)',
      pg_temp.bal('2410', 'THANAKORN') - pg_temp.base('tk_2410'),
      pg_temp.bal('2100', 'THANAKORN') - pg_temp.base('tk_2100');
  end if;
  -- ทุนตั้งต้นถูกแยกออกจากกำไรสะสมแล้ว · ยอดรวมส่วนของเจ้าของไม่เปลี่ยน
  if pg_temp.bal('3100', 'THANAKORN') - pg_temp.base('tk_3100') <> -3000000 then
    raise exception 'FAIL: O1b — ทุนตั้งต้นของธนากรควรเพิ่ม 3,000,000 (ฝั่งเครดิต) แต่ได้ %',
      -(pg_temp.bal('3100', 'THANAKORN') - pg_temp.base('tk_3100'));
  end if;
  -- กำไรสะสม = สินทรัพย์ − หนี้สิน − ทุนตั้งต้น = 6,380,000 − 2,120,000 − 3,000,000 = 1,260,000
  if pg_temp.bal('3300', 'THANAKORN') - pg_temp.base('tk_3300') <> -1260000 then
    raise exception 'FAIL: O1b — กำไรสะสมของธนากรควรเพิ่ม 1,260,000 (ฝั่งเครดิต) แต่ได้ %',
      -(pg_temp.bal('3300', 'THANAKORN') - pg_temp.base('tk_3300'));
  end if;

  raise notice 'ok O1b · ใบยอดยกมาไม่ทำให้สมการบัญชีเพี้ยนเลยทั้งสามผู้ถือและมุมมองรวม (ส่วนต่าง 0) · ทุนตั้งต้น 3,000,000 แยกออกจากกำไรสะสม 1,260,000 ของธนากร';
end $$;

-- ============================================================
-- O2 · ยอดยกมา **ไม่แตะงบกำไรขาดทุน** และไม่เข้างบกระแสเงินสดของงวด
-- ============================================================
do $$
declare v text;
begin
  if pg_temp.pl() - pg_temp.base('pl') <> 0 then
    raise exception 'FAIL: O2 — ยอดยกมาทำให้งบกำไรขาดทุนขยับ % (ต้องเป็น 0 เพราะเป็นผลของอดีตก่อนระบบ)',
      pg_temp.pl() - pg_temp.base('pl');
  end if;

  -- ไม่มีบรรทัดไหนของใบยอดยกมาที่ cf_category ไม่ใช่ none
  select string_agg(distinct v2.cf_category::text, ', ') into v
    from sri_os.v_ledger_posted v2
    join sri_os.transactions t on t.id = v2.transaction_id
   where t.txn_type_code like 'opn.%'
     and v2.cf_category in ('operating', 'investing', 'financing');
  if v is not null then
    raise exception 'FAIL: O2 — บรรทัดของใบยอดยกมาเข้างบกระแสเงินสด (%) → งวดแรกจะมีเงินสดรับที่ไม่มีอยู่จริง', v;
  end if;

  -- และบัญชีรายได้/ค่าใช้จ่ายต้องไม่ถูกแตะโดยใบยอดยกมาเลยแม้แต่บรรทัดเดียว
  select string_agg(c.code, ', ') into v
    from sri_os.v_ledger_posted v2
    join sri_os.transactions t on t.id = v2.transaction_id
    join sri_os.chart_of_accounts c on c.id = v2.coa_id
   where t.txn_type_code like 'opn.%' and c.type in ('income', 'expense');
  if v is not null then
    raise exception 'FAIL: O2 — ใบยอดยกมาแตะบัญชีรายได้/ค่าใช้จ่าย: %', v;
  end if;

  raise notice 'ok O2 · กำไรขาดทุนยังเป็น 0 · ทุกบรรทัดของใบยอดยกมาเป็น cf_category = none (งบกระแสเงินสดของงวดไม่ขยับ)';
end $$;

-- ============================================================
-- O3 · คู่บัญชีอยู่ใน **ตารางกฎ** เท่านั้น — ลงบัญชีอื่นไม่ได้
--      (ถ้ายอมให้ผู้เรียกเลือกบัญชีเอง นั่นคือย้ายคู่บัญชีออกจากตารางกฎ · D-115)
-- ============================================================
do $$
begin
  -- ขาคู่เป็นรายได้ → ด่านระดับบรรทัดปฏิเสธ (บัญชีไม่อยู่ในชุดของหมวด)
  perform pg_temp.must_fail_like('O3 ยอดยกมาคู่กับบัญชีรายได้', $q$
    select pg_temp.post(pg_temp.open_entry('THANAKORN', 'opn.cash', 'O3 ยอดยกมาคู่รายได้',
      jsonb_build_array(
        pg_temp.ln('1100', 500, 0, pg_temp.bank('THANAKORN')),
        pg_temp.ln('4200', 0, 500)), '2026-01-01')) $q$,
    'ตารางกฎระบุบัญชีของหมวดนี้ไว้เฉพาะ');

  -- ลงบัญชีสินทรัพย์คนละตัวกับที่หมวดประกาศ (เอาหมวดเงินฝากไปลงหลักทรัพย์)
  perform pg_temp.must_fail_like('O3 ใช้หมวดเงินฝากลงบัญชีหลักทรัพย์', $q$
    select pg_temp.post(pg_temp.open_entry('THANAKORN', 'opn.cash', 'O3 หมวดผิดบัญชี',
      jsonb_build_array(
        pg_temp.ln('1700', 500, 0),
        pg_temp.ln('3300', 0, 500)))) $q$,
    'ตารางกฎระบุบัญชีของหมวดนี้ไว้เฉพาะ');

  -- หมวดที่ไม่มีในตารางกฎเลย
  perform pg_temp.must_fail_like('O3 หมวดยอดยกมาที่ไม่มีในตารางกฎ', $q$
    select pg_temp.post(pg_temp.open_entry('THANAKORN', 'opn.whatever', 'O3 หมวดไม่มีจริง',
      jsonb_build_array(
        pg_temp.ln('1100', 500, 0, pg_temp.bank('THANAKORN')),
        pg_temp.ln('3300', 0, 500)), '2026-01-01')) $q$,
    'ไม่มีหมวด');

  -- เงินฝากยกมาโดยไม่ระบุวันที่เงินเคลื่อน → ด่าน cash_date ปฏิเสธ
  perform pg_temp.must_fail_like('O3 เงินฝากยกมาไม่มีวันที่เงินเคลื่อน', $q$
    select pg_temp.post(pg_temp.open_entry('THANAKORN', 'opn.cash', 'O3 ไม่มี cash_date',
      jsonb_build_array(
        pg_temp.ln('1100', 500, 0, pg_temp.bank('THANAKORN')),
        pg_temp.ln('3300', 0, 500)))) $q$,
    'cash_date');

  -- ยอดต้องไม่ขยับจากเคสที่ถูกปฏิเสธ
  if pg_temp.equation() - pg_temp.base('eq_all') <> 0
     or pg_temp.bal('1100', 'THANAKORN') - pg_temp.base('tk_1100') <> 1000000 then
    raise exception 'FAIL: O3 — ใบที่ถูกปฏิเสธทิ้งผลไว้ (สมการเพี้ยน % · เงินฝากขยับ %)',
      pg_temp.equation() - pg_temp.base('eq_all'),
      pg_temp.bal('1100', 'THANAKORN') - pg_temp.base('tk_1100');
  end if;

  raise notice 'ok O3 · ลงบัญชีนอกคู่ที่ตารางกฎประกาศไม่ได้ · หมวดที่ไม่มีในตารางกฎไม่ได้ · เงินฝากยกมาต้องมีวันที่เงินเคลื่อน';
end $$;

-- ============================================================
-- O4 · **MUTATION** — แก้ตารางกฎให้ขาคู่ของยอดยกมาเป็นบัญชีรายได้
--      แล้ววัดว่ากำไรปลอมเท่าไร (ถ้าเคสนี้ไม่แดง แปลว่า O2 ไม่ได้พิสูจน์อะไร)
-- ============================================================
savepoint before_opening_mutation;
do $$
declare v_pl numeric;
begin
  set constraints all immediate;
  update sri_os.txn_types set cr_coa_code = '4900' where code = 'opn.cash';
  set constraints all deferred;

  perform pg_temp.post(pg_temp.open_entry('SUTEE', 'opn.cash', 'O4 ยอดยกมาคู่รายได้ (mutation)',
    jsonb_build_array(
      pg_temp.ln('1100', 2000000, 0, pg_temp.bank('SUTEE')),
      pg_temp.ln('4900', 0, 2000000)), '2026-01-01'));

  v_pl := pg_temp.pl() - pg_temp.base('pl');
  if v_pl <> 2000000 then
    raise exception 'FAIL: O4 — กลายพันธุ์ไม่สำเร็จ (กำไรขยับ % ควรเป็น 2,000,000) เคสนี้จึงไม่ได้พิสูจน์อะไร', v_pl;
  end if;
  raise notice 'ok O4 · MUTATION · ถ้าขาคู่ของยอดยกมาเป็นบัญชีรายได้ → งวดแรกมี **กำไรปลอม 2,000,000** ทั้งที่งบดุลยังดุล (สมการเพี้ยน %) = ตัวเลขผิดเงียบๆ ที่ตารางกฎกันไว้',
    pg_temp.equation() - pg_temp.base('eq_all');
end $$;
rollback to savepoint before_opening_mutation;

do $$
begin
  if (select cr_coa_code from sri_os.txn_types where code = 'opn.cash') <> '3300' then
    raise exception 'FAIL: O4b — ตารางกฎยังค้างสภาพกลายพันธุ์หลัง rollback';
  end if;
  if pg_temp.pl() - pg_temp.base('pl') <> 0 then
    raise exception 'FAIL: O4b — ใบของ mutation ยังค้างในสมุด (กำไรเพี้ยน %)', pg_temp.pl() - pg_temp.base('pl');
  end if;
  raise notice 'ok O4b · ตารางกฎกลับมาเป็น 3300 และไม่มีใบของ mutation ค้างในสมุด';
end $$;

-- ---------- สรุป: ทุกใบที่ไฟล์นี้สร้างต้องผ่านด่านที่เลื่อนไว้จริง ----------
do $$
declare n int;
begin
  set constraints all immediate;
  select count(*) into n from sri_os.transactions where txn_type_code like 'opn.%';
  if n < 14 then
    raise exception 'FAIL: นับใบยอดยกมาที่ลงได้แค่ % ใบ — เทสต์อาจไม่ได้ลงอะไรเลย', n;
  end if;
  raise notice 'ok O · ทั้ง % ใบของไฟล์นี้ผ่านด่านที่เลื่อนไว้ (เคสปฏิเสธไม่ทิ้งใบเสียรูปไว้)', n;
end $$;

do $$ begin raise notice '=== ยอดยกมา (ตั้งต้นระบบ) ผ่านทั้งหมด ==='; end $$;

rollback;
