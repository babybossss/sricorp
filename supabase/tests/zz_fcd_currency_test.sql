-- ============================================================
-- SRI OS · เทสต์บัญชีเงินฝากสกุลต่างประเทศ (FCD)
--   migration ที่คุม: 20261025000004_fcd_bank_currency.sql (+ seed 20261024181010)
--
-- ที่มา: ลูกพี่ยืนยัน 25/10 ว่ามีบัญชี FCD จริง แต่ `bank_accounts` ไม่มีคอลัมน์
--   สกุลเงินเลย → บัญชีที่ถือ USD ถูกนับเป็นบาททั้งก้อน **ยอดเงินสดในงบผิดเงียบๆ**
--   (เคส F7 วัดส่วนต่างจริงเมื่อถอดด่านออก)
--
-- หลักที่ลูกพี่วางไว้และไฟล์นี้ต้องพิสูจน์:
--   - กำไร/ขาดทุนค่าเงิน **ที่ยังไม่ได้แลก** เข้าส่วนของเจ้าของ (3410) **P&L ห้ามขยับ**
--   - **แลกเป็นบาทจริง** จึงเข้า P&L (4330/5930) และ 3410 ของสกุลนั้นต้องเหลือศูนย์พอดี
--   - functional currency = บาท → **Σ debit = Σ credit ในบาทเสมอ**
--
-- เคส (ไล่จาก "ถ้าถอดการแก้ออกแล้วต้องแดง"):
--   F1 โครงสร้าง (คอลัมน์ · constraint · FK · trigger · ประเภทบัญชี 3410)
--   F2 บัญชี USD + มีอัตรา → ยอดบาทถูก · Σ debit = Σ credit ในบาท · ยอดเงินตราถูก
--   F3 บัญชี USD + **ไม่ส่งอัตรา → ปฏิเสธ** (และเคสยอดบาทไม่ตรงอัตรา · บัญชีบาทแนบอัตรา)
--   F4 ตีมูลค่าสิ้นเดือน → ผลต่างเข้า **ส่วนของเจ้าของ** · **P&L ไม่ขยับเลย** + MUTATION
--   F5 แลกเป็นบาทจริง → ผลต่าง **เข้า P&L 10,000** · 3410 เหลือ **ศูนย์พอดี** + MUTATION
--   F6 บัญชีบาทเดิมยังลงได้ปกติ (ของเดิมต้องไม่พัง)
--   F7 **MUTATION** ถอดด่านอัตราออก → ลงบัญชี USD เป็นบาทได้ และยอดเพี้ยนเท่าที่วัดไว้
--
-- ทุกใบลงผ่าน `sri_os.fn_post_entry()` เท่านั้น · ทั้งไฟล์ rollback ปิดท้าย
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
create temporary table t_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_uid(label) values ('mgmt');
insert into auth.users(id) select id from t_uid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, 'fcd@local', 'mgmt', 'management', true from t_uid u;
select set_config('test.uid', (select id::text from t_uid where label = 'mgmt'), true);

insert into sri_os.user_owner_access(user_id, owner_id)
select (select id from t_uid where label = 'mgmt'), o.id from sri_os.owners o;

-- บัญชีบาท + บัญชี USD ของผู้ถือเดียวกัน
insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name, currency)
values ('00000000-0000-0000-0000-00000005b001',
        (select id from sri_os.owners where code = 'THANAKORN'),
        'BBL', 'ธนากร', 'ธนากร - BBL (บาท)', 'THB'),
       ('00000000-0000-0000-0000-00000005b002',
        (select id from sri_os.owners where code = 'THANAKORN'),
        'BBL', 'ธนากร FCD', 'ธนากร - BBL (FCD USD)', 'USD');

insert into sri_os.contacts(id, first_name, types)
values ('00000000-0000-0000-0000-00000005c001', 'ผู้เช่า FCD', array['tenant']);

insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, currency)
select '00000000-0000-0000-0000-00000005a001', 'FCD-RENT', 'คอนโดให้เช่า (FCD)',
       cat.class_id, cat.id, (select id from sri_os.owners where code = 'THANAKORN'), 'THB'
  from (select id, class_id from sri_os.asset_categories order by id limit 1) cat;

-- อัตราสามวัน: ซื้อ 36.50 · สิ้นเดือน 37.00 · วันแลก 37.50
insert into sri_os.fx_rates(currency, rate_date, thb_per_unit, source, note)
values ('USD', '2026-10-31', 36.5,  'manual', 'วันที่โอนเข้าบัญชี FCD'),
       ('USD', '2026-11-30', 37.0,  'manual', 'อัตราสิ้นเดือน พ.ย.'),
       ('USD', '2026-12-31', 37.5,  'manual', 'อัตราวันที่แลกเป็นบาท'),
       ('THB', '2026-10-31', 1,     'manual', 'สกุลตั้งต้น');

create or replace function pg_temp.owner() returns uuid
language sql stable as $fn$ select id from sri_os.owners where code = 'THANAKORN' $fn$;

/** บรรทัด: ยอดบาทอยู่ที่ debit/credit เสมอ · ข้อมูลสกุลเดิมเป็นชุดสี่ช่อง */
create or replace function pg_temp.ln(p_code text, p_dr numeric, p_cr numeric,
                                     p_cf text default null, p_bank uuid default null,
                                     p_ccy text default null, p_orig numeric default null,
                                     p_rate numeric default null, p_rate_date date default null,
                                     p_asset uuid default null) returns jsonb
language sql immutable as $fn$
  select jsonb_strip_nulls(jsonb_build_object(
    'coa_code', p_code, 'debit', p_dr, 'credit', p_cr,
    'cf_category', p_cf, 'bank_account_id', p_bank, 'asset_id', p_asset,
    'currency', p_ccy, 'amount_original', p_orig,
    'fx_rate', p_rate, 'fx_rate_date', case when p_rate_date is null then null else p_rate_date::text end));
$fn$;

create or replace function pg_temp.entry(p_type text, p_memo text, p_lines jsonb,
                                        p_doc date default '2026-10-31',
                                        p_cash date default '2026-10-31')
returns jsonb language sql stable as $fn$
  select jsonb_strip_nulls(jsonb_build_object(
    'txn_type_code', p_type,
    'doc_date', p_doc::text,
    'cash_date', case when p_cash is null then null else p_cash::text end,
    'memo', p_memo,
    'contact_id', '00000000-0000-0000-0000-00000005c001',
    'attachments', jsonb_build_array('หลักฐาน.pdf'),
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', pg_temp.owner(), 'lines', p_lines))));
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

/** ยอด **บาท** ของบัญชีธนาคารหนึ่งบัญชีตามสมุด */
create or replace function pg_temp.thb(p_bank uuid) returns numeric
language sql stable as $fn$
  select coalesce(sum(v.debit - v.credit), 0)
    from sri_os.v_ledger_posted v where v.bank_account_id = p_bank;
$fn$;

/** ยอด **เงินตรา** ของบัญชีธนาคารหนึ่งบัญชี (ทิศจากด้านที่ลง) */
create or replace function pg_temp.fx(p_bank uuid) returns numeric
language sql stable as $fn$
  select coalesce(sum(case when v.debit > 0 then v.amount_original else -v.amount_original end), 0)
    from sri_os.v_ledger_posted v
   where v.bank_account_id = p_bank and v.amount_original is not null;
$fn$;

/** ยอดคงเหลือของบัญชีหนึ่งรหัส (เครดิตเป็นบวกสำหรับ equity/income) */
create or replace function pg_temp.bal(p_code text) returns numeric
language sql stable as $fn$
  select coalesce(sum(v.credit - v.debit), 0)
    from sri_os.v_ledger_posted v
    join sri_os.chart_of_accounts c on c.id = v.coa_id
   where c.code = p_code;
$fn$;

/** ผลกระทบต่องบกำไรขาดทุนทั้งสมุด (รายได้ − ค่าใช้จ่าย) */
create or replace function pg_temp.pl() returns numeric
language sql stable as $fn$
  select coalesce(sum(case when c.type::text = 'income' then v.credit - v.debit
                           else v.debit - v.credit end), 0)
    from sri_os.v_ledger_posted v
    join sri_os.chart_of_accounts c on c.id = v.coa_id
   where c.type::text in ('income', 'expense');
$fn$;

-- ============================================================
-- F1 · โครงสร้าง — ไล่จาก catalog จริง
-- ============================================================
do $$
declare v text; n int;
begin
  -- คอลัมน์ครบทั้งสองตาราง
  select string_agg(x.col, ', ') into v
    from (values ('bank_accounts', 'currency'),
                 ('transaction_lines', 'currency'),
                 ('transaction_lines', 'amount_original'),
                 ('transaction_lines', 'fx_rate'),
                 ('transaction_lines', 'fx_rate_date')) x(tbl, col)
   where not exists (select 1 from pg_attribute a
                      where a.attrelid = ('sri_os.' || x.tbl)::regclass
                        and a.attname = x.col and a.attnum > 0 and not a.attisdropped);
  if v is not null then
    raise exception 'FAIL: คอลัมน์หายไป: %', v;
  end if;

  -- **ประเภทบัญชีคือตัวบังคับกฎ** — 3410 ต้องเป็น equity ไม่ใช่ income/expense
  if (select c.type::text from sri_os.chart_of_accounts c where c.code = '3410') <> 'equity' then
    raise exception 'FAIL: 3410 ต้องเป็น equity — ถ้าเป็น income/expense ผลต่างที่ยังไม่เกิดจริงจะไหลเข้างบกำไรขาดทุนโดยไม่มีใครกันได้';
  end if;
  if (select c.type::text from sri_os.chart_of_accounts c where c.code = '4330') <> 'income'
     or (select c.type::text from sri_os.chart_of_accounts c where c.code = '5930') <> 'expense' then
    raise exception 'FAIL: 4330/5930 ต้องเป็น income/expense (กำไรที่เกิดขึ้นจริงต้องเข้า P&L)';
  end if;

  -- constraint + FK + trigger
  select string_agg(x.want, ', ') into v
    from (values ('bank_accounts_currency_allowed'), ('transaction_lines_fx_shape'),
                 ('transaction_lines_fx_rate_fk')) x(want)
   where not exists (select 1 from pg_constraint c where c.conname = x.want and c.convalidated);
  if v is not null then
    raise exception 'FAIL: constraint หายไปหรือยังไม่ validate: %', v;
  end if;
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.transaction_lines'::regclass
                    and g.tgname = 'trg_lines_fx_shape' and not g.tgisinternal) then
    raise exception 'FAIL: ไม่มี trigger trg_lines_fx_shape';
  end if;
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.transaction_lines'::regclass
                    and g.tgname = 'trg_assert_fx_unrealized_cleared' and not g.tgisinternal
                    and g.tgdeferrable and g.tginitdeferred) then
    raise exception 'FAIL: ไม่มี constraint trigger แบบ deferred ของการล้างผลต่าง';
  end if;

  -- บัญชีเดิมทั้งหมดเป็นบาท (ของเดิมไม่พัง)
  select count(*) into n from sri_os.bank_accounts where currency is null;
  if n > 0 then raise exception 'FAIL: มีบัญชีที่ไม่มีสกุลเงิน % แถว', n; end if;

  -- สกุลเงินจำกัดชุดเดียวกับ currency.ts (ไม่มีรายการชุดที่สอง)
  begin
    update sri_os.bank_accounts set currency = 'EUR'
     where id = '00000000-0000-0000-0000-00000005b002';
    raise exception 'FAIL: ตั้งสกุล EUR ให้บัญชีได้ (ชุดสกุลเงินไม่ตรงกับ currency.ts)';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if position('bank_accounts_currency_allowed' in sqlerrm) = 0 then
      raise exception 'FAIL: ปฏิเสธด้วยเหตุอื่น: %', sqlerrm;
    end if;
  end;

  -- ฟังก์ชันด่านต้องเรียกตรงไม่ได้ (D-089)
  foreach v in array array['sri_os.fn_assert_line_fx()',
                           'sri_os.fn_assert_fx_unrealized_cleared_for(uuid)',
                           'sri_os.fn_bank_account_currency(uuid)'] loop
    if has_function_privilege('authenticated', v, 'execute')
       or has_function_privilege('anon', v, 'execute') then
      raise exception 'FAIL: % เรียกตรงได้ = ทางข้าม policy', v;
    end if;
  end loop;

  raise notice 'ok F1 · คอลัมน์ครบทั้งสองตาราง · 3410 เป็น equity · 4330/5930 เป็น P&L · constraint/FK/trigger ครบ · สกุลเงินจำกัดชุดเดียวกับ currency.ts · ฟังก์ชันด่านปิด';
end $$;

-- ============================================================
-- F2 · โอนบาทไปซื้อ USD 10,000 ที่อัตรา 36.50 → บัญชี FCD มี 365,000 บาท
--      Σ debit = Σ credit **ในบาท** (functional currency ยังเป็นบาท)
-- ============================================================
do $$
declare t uuid; v_dr numeric; v_cr numeric;
begin
  t := pg_temp.post(pg_temp.entry('trf.internal', 'F2 โอนบาทเข้าบัญชี FCD ซื้อ USD 10,000 @36.50',
    jsonb_build_array(
      pg_temp.ln('1100', 365000, 0, 'none', '00000000-0000-0000-0000-00000005b002',
                 'USD', 10000, 36.5, '2026-10-31'),
      pg_temp.ln('1100', 0, 365000, 'none', '00000000-0000-0000-0000-00000005b001'))));

  select coalesce(sum(l.debit), 0), coalesce(sum(l.credit), 0) into v_dr, v_cr
    from sri_os.transaction_lines l where l.transaction_id = t;
  if v_dr <> v_cr or v_dr <> 365000 then
    raise exception 'FAIL: F2 — Σ debit (%) ต้องเท่ากับ Σ credit (%) ในบาท และเท่ากับ 365,000', v_dr, v_cr;
  end if;

  if pg_temp.thb('00000000-0000-0000-0000-00000005b002') <> 365000 then
    raise exception 'FAIL: F2 — ยอดบาทของบัญชี FCD ควรเป็น 365,000 (10,000 × 36.50) แต่ได้ %',
      pg_temp.thb('00000000-0000-0000-0000-00000005b002');
  end if;
  if pg_temp.fx('00000000-0000-0000-0000-00000005b002') <> 10000 then
    raise exception 'FAIL: F2 — ยอดเงินตราของบัญชี FCD ควรเป็น 10,000 USD แต่ได้ %',
      pg_temp.fx('00000000-0000-0000-0000-00000005b002');
  end if;
  if pg_temp.thb('00000000-0000-0000-0000-00000005b001') <> -365000 then
    raise exception 'FAIL: F2 — บัญชีบาทควรลดลง 365,000 แต่ได้ %',
      pg_temp.thb('00000000-0000-0000-0000-00000005b001');
  end if;
  if pg_temp.pl() <> 0 then
    raise exception 'FAIL: F2 — การซื้อเงินตราไม่ใช่รายได้/ค่าใช้จ่าย แต่ P&L ขยับ %', pg_temp.pl();
  end if;

  raise notice 'ok F2 · บัญชี USD + อัตราครบ → ยอดบาท 365,000 = 10,000 × 36.50 · ยอดเงินตรา 10,000 USD · Σ debit = Σ credit ในบาท · P&L ไม่ขยับ';
end $$;

-- ============================================================
-- F3 · **ไม่ส่งอัตรา → ปฏิเสธ** (เคส "ข้อมูลไม่ครบ" ที่ต้องมี · บทเรียนข้อ 1)
-- ============================================================
do $$
begin
  -- (ก) ลงบัญชี USD เป็นบาทเฉยๆ ไม่มีสกุล/อัตราเลย
  perform pg_temp.must_fail_like('F3a บัญชี USD แต่ไม่ส่งอัตราเลย',
    $q$ select pg_temp.post(pg_temp.entry('trf.internal', 'F3a ลงบัญชี FCD เป็นบาทเฉยๆ',
          jsonb_build_array(
            pg_temp.ln('1100', 365000, 0, 'none', '00000000-0000-0000-0000-00000005b002'),
            pg_temp.ln('1100', 0, 365000, 'none', '00000000-0000-0000-0000-00000005b001')))) $q$,
    'ต้องระบุสกุลเงิน');

  -- (ข) ส่งสกุลแต่ยอดบาทไม่ได้มาจากอัตรา (พิมพ์ยอดบาทแยกกัน)
  perform pg_temp.must_fail_like('F3b ยอดบาทไม่ตรงกับอัตรา',
    $q$ select pg_temp.post(pg_temp.entry('trf.internal', 'F3b ยอดบาทไม่ตรงอัตรา',
          jsonb_build_array(
            pg_temp.ln('1100', 300000, 0, 'none', '00000000-0000-0000-0000-00000005b002',
                       'USD', 10000, 36.5, '2026-10-31'),
            pg_temp.ln('1100', 0, 300000, 'none', '00000000-0000-0000-0000-00000005b001')))) $q$,
    'ไม่เท่ากับ');

  -- (ค) สกุลของบรรทัดไม่ตรงกับสกุลของบัญชี
  perform pg_temp.must_fail_like('F3c สกุลของบรรทัดไม่ตรงกับบัญชี',
    $q$ select pg_temp.post(pg_temp.entry('trf.internal', 'F3c สกุลไม่ตรงบัญชี',
          jsonb_build_array(
            pg_temp.ln('1100', 2350, 0, 'none', '00000000-0000-0000-0000-00000005b002',
                       'JPY', 10000, 0.235, '2026-10-31'),
            pg_temp.ln('1100', 0, 2350, 'none', '00000000-0000-0000-0000-00000005b001')))) $q$,
    'สกุลของบรรทัดต้องเป็นสกุลของบัญชี');

  -- (ง) บัญชีบาทแต่แนบข้อมูลอัตรามา
  perform pg_temp.must_fail_like('F3d บัญชีบาทแนบอัตรามา',
    $q$ select pg_temp.post(pg_temp.entry('trf.internal', 'F3d บัญชีบาทแนบอัตรา',
          jsonb_build_array(
            pg_temp.ln('1100', 365000, 0, 'none', '00000000-0000-0000-0000-00000005b002',
                       'USD', 10000, 36.5, '2026-10-31'),
            pg_temp.ln('1100', 0, 365000, 'none', '00000000-0000-0000-0000-00000005b001',
                       'USD', 10000, 36.5, '2026-10-31')))) $q$,
    'เป็นบัญชีบาท');

  -- (จ) อัตราที่ไม่มีอยู่ในตารางอัตรา (เดาอัตราเอง)
  perform pg_temp.must_fail_like('F3e อัตราที่ไม่มีในตาราง fx_rates',
    $q$ select pg_temp.post(pg_temp.entry('trf.internal', 'F3e เดาอัตราเอง',
          jsonb_build_array(
            pg_temp.ln('1100', 380000, 0, 'none', '00000000-0000-0000-0000-00000005b002',
                       'USD', 10000, 38, '2026-09-30'),
            pg_temp.ln('1100', 0, 380000, 'none', '00000000-0000-0000-0000-00000005b001')))) $q$,
    'transaction_lines_fx_rate_fk');

  -- (ฉ) ส่งสกุลมาครึ่งๆ (ไม่มีอัตรา) → constraint รูปร่าง
  perform pg_temp.must_fail_like('F3f ส่งสกุลแต่ไม่ส่งอัตรา',
    $q$ select pg_temp.post(pg_temp.entry('trf.internal', 'F3f สกุลไม่มีอัตรา',
          jsonb_build_array(
            pg_temp.ln('1100', 365000, 0, 'none', '00000000-0000-0000-0000-00000005b002',
                       'USD', 10000, null, null),
            pg_temp.ln('1100', 0, 365000, 'none', '00000000-0000-0000-0000-00000005b001')))) $q$,
    'transaction_lines_fx_shape');

  -- ยอดต้องไม่ขยับจากใบที่ถูกปฏิเสธทั้งหก
  if pg_temp.thb('00000000-0000-0000-0000-00000005b002') <> 365000 then
    raise exception 'FAIL: F3 — ใบที่ถูกปฏิเสธทิ้งผลไว้ในสมุด (ยอดบาทของบัญชี FCD %)',
      pg_temp.thb('00000000-0000-0000-0000-00000005b002');
  end if;

  raise notice 'ok F3 · ลงบัญชีสกุลต่างประเทศโดยไม่มีอัตราถูกปฏิเสธ (ไม่ใช่สมมติว่าอัตรา = 1) · ยอดบาทต้องมาจากอัตรา · สกุลต้องตรงกับบัญชี · บัญชีบาทห้ามมีอัตราติดมา · อัตราต้องมีอยู่จริงในตาราง';
end $$;

-- ============================================================
-- F4 · ตีมูลค่าสิ้นเดือน 36.50 → 37.00 · ผลต่าง 5,000 บาท
--      **เข้าส่วนของเจ้าของ (3410) · P&L ไม่ขยับเลย**
-- ============================================================
do $$
declare v_pl_before numeric;
begin
  v_pl_before := pg_temp.pl();

  perform pg_temp.post(pg_temp.entry('trf.fx_translate_up', 'F4 แปลงค่าสิ้นเดือน 36.50 → 37.00',
    jsonb_build_array(
      pg_temp.ln('1100', 5000, 0, 'none', '00000000-0000-0000-0000-00000005b002',
                 'USD', 0, 37.0, '2026-11-30'),
      pg_temp.ln('3410', 0, 5000, 'none', null, 'USD', 0, 37.0, '2026-11-30')),
    '2026-11-30', '2026-11-30'));

  if pg_temp.thb('00000000-0000-0000-0000-00000005b002') <> 370000 then
    raise exception 'FAIL: F4 — ยอดบาทของบัญชี FCD ควรเป็น 370,000 (10,000 × 37.00) แต่ได้ %',
      pg_temp.thb('00000000-0000-0000-0000-00000005b002');
  end if;
  if pg_temp.fx('00000000-0000-0000-0000-00000005b002') <> 10000 then
    raise exception 'FAIL: F4 — จำนวนเงินตราต้องไม่เปลี่ยน (10,000 USD) แต่ได้ %',
      pg_temp.fx('00000000-0000-0000-0000-00000005b002');
  end if;
  if pg_temp.bal('3410') <> 5000 then
    raise exception 'FAIL: F4 — ผลต่างในส่วนของเจ้าของ (3410) ควรเป็น 5,000 แต่ได้ %', pg_temp.bal('3410');
  end if;
  if pg_temp.pl() <> v_pl_before then
    raise exception 'FAIL: F4 — **P&L ขยับ** จาก % เป็น % ทั้งที่ยังไม่ได้แลกเงิน (ลูกพี่สั่งห้ามเด็ดขาด)',
      v_pl_before, pg_temp.pl();
  end if;

  raise notice 'ok F4 · แปลงค่าสิ้นเดือน: ยอดบาท 365,000 → 370,000 · ผลต่าง 5,000 เข้า 3410 (ส่วนของเจ้าของ) · **P&L = % ไม่ขยับเลย** · จำนวนเงินตราเท่าเดิม 10,000 USD', pg_temp.pl();
end $$;

-- ------------------------------------------------------------
-- F4b · **MUTATION** — ให้หมวดแปลงค่าประกาศบัญชี P&L แล้วลองพาผลต่างเข้า P&L
--        ต้องถูกปฏิเสธที่ trigger ของบรรทัด (ไม่ใช่แค่เพราะคู่บัญชีไม่ตรงหมวด)
-- ------------------------------------------------------------
savepoint before_pl_mutation;
do $$
begin
  -- แก้ตารางกฎโดยตรงต้องถูกปฏิเสธก่อน (ด่านที่ตัวกฎ)
  perform pg_temp.must_fail_like('F4b1 ตั้งบัญชีรายได้ไว้ในช่อง gain ของหมวดแปลงค่า',
    $q$ update sri_os.txn_types set gain_coa_code = '4900' where code = 'trf.fx_translate_up' $q$,
    'ห้ามเข้างบกำไรขาดทุนเด็ดขาด');

  -- ปิด trigger ของตารางกฎชั่วคราวเพื่อกลายพันธุ์ให้สำเร็จ แล้วพิสูจน์ด่านของบรรทัด
  set constraints all immediate;
  alter table sri_os.txn_types disable trigger trg_txn_types_revaluation_clean;
  update sri_os.txn_types set gain_coa_code = '4900' where code = 'trf.fx_translate_up';
  alter table sri_os.txn_types enable trigger trg_txn_types_revaluation_clean;
  set constraints all deferred;

  if (select gain_coa_code from sri_os.txn_types where code = 'trf.fx_translate_up') <> '4900' then
    raise exception 'FAIL: F4b — กลายพันธุ์ไม่สำเร็จ เคสนี้จึงไม่ได้พิสูจน์อะไร';
  end if;

  perform pg_temp.must_fail_like('F4b2 แปลงค่าแล้วพาผลต่างเข้า P&L',
    $q$ select pg_temp.post(pg_temp.entry('trf.fx_translate_up', 'F4b แปลงค่าเข้า P&L',
          jsonb_build_array(
            pg_temp.ln('1100', 5000, 0, 'none', '00000000-0000-0000-0000-00000005b002',
                       'USD', 0, 37.0, '2026-11-30'),
            pg_temp.ln('4900', 0, 5000, 'none')),
          '2026-11-30', '2026-11-30')) $q$,
    'ห้ามเข้างบกำไรขาดทุนเด็ดขาด');

  raise notice 'ok F4b · MUTATION · ตารางกฎปฏิเสธการประกาศบัญชี P&L ให้หมวดแปลงค่า และถึงกลายพันธุ์สำเร็จ ด่านของบรรทัดก็ยังปฏิเสธ';
end $$;
rollback to savepoint before_pl_mutation;

do $$
begin
  if (select gain_coa_code from sri_os.txn_types where code = 'trf.fx_translate_up') is not null then
    raise exception 'FAIL: F4b — ตารางกฎยังค้างสภาพกลายพันธุ์หลัง rollback';
  end if;
  raise notice 'ok F4c · ตารางกฎกลับเป็นของจริงหลัง rollback';
end $$;

-- ============================================================
-- F5 · แลกเป็นบาทจริงที่อัตรา 37.50 → **ผลต่างเข้า P&L 10,000**
--      และ 3410 ของสกุลนั้น **เหลือศูนย์พอดี**
--
--   ตัดเงินตรา 10,000 USD ออกตามอัตราตามบัญชี 37.00 = 370,000
--   รับบาทจริง 10,000 × 37.50 = 375,000
--   ล้างผลต่างที่ค้าง 5,000 (Dr 3410) → กำไรที่รับรู้ = 375,000 − 365,000 = 10,000
--   สมดุล: 375,000 + 5,000 = 370,000 + 10,000
-- ============================================================
do $$
declare v_pl_before numeric;
begin
  v_pl_before := pg_temp.pl();

  -- MUTATION ก่อน: **ไม่ล้าง 3410** (ใบยังสมดุล) → ต้องถูกปฏิเสธ
  perform pg_temp.must_fail_like('F5a แลกหมดแต่ไม่ล้างผลต่างที่ค้าง',
    $q$ select pg_temp.post(pg_temp.entry('trf.fx_convert', 'F5a แลกหมดไม่ล้าง 3410',
          jsonb_build_array(
            pg_temp.ln('1100', 375000, 0, 'none', '00000000-0000-0000-0000-00000005b001'),
            pg_temp.ln('1100', 0, 370000, 'none', '00000000-0000-0000-0000-00000005b002',
                       'USD', 10000, 37.0, '2026-11-30'),
            pg_temp.ln('4330', 0, 5000, 'none')),
          '2026-12-31', '2026-12-31')) $q$,
    'เหลือศูนย์พอดี');

  if pg_temp.bal('3410') <> 5000 then
    raise exception 'FAIL: F5a — ใบที่ถูกปฏิเสธทิ้งผลไว้ (3410 = %)', pg_temp.bal('3410');
  end if;

  -- ใบที่ถูกต้อง
  perform pg_temp.post(pg_temp.entry('trf.fx_convert', 'F5 แลก 10,000 USD เป็นบาทที่ 37.50',
    jsonb_build_array(
      pg_temp.ln('1100', 375000, 0, 'none', '00000000-0000-0000-0000-00000005b001'),
      pg_temp.ln('1100', 0, 370000, 'none', '00000000-0000-0000-0000-00000005b002',
                 'USD', 10000, 37.0, '2026-11-30'),
      pg_temp.ln('3410', 5000, 0, 'none', null, 'USD', 0, 37.5, '2026-12-31'),
      pg_temp.ln('4330', 0, 10000, 'none')),
    '2026-12-31', '2026-12-31'));

  if pg_temp.bal('3410') <> 0 then
    raise exception 'FAIL: F5 — แลกหมดแล้ว 3410 ต้องเหลือศูนย์พอดี แต่เหลือ %', pg_temp.bal('3410');
  end if;
  if pg_temp.pl() - v_pl_before <> 10000 then
    raise exception 'FAIL: F5 — กำไรที่รับรู้เข้า P&L ต้องเป็น 10,000 (375,000 − 365,000) แต่ได้ %',
      pg_temp.pl() - v_pl_before;
  end if;
  if pg_temp.fx('00000000-0000-0000-0000-00000005b002') <> 0
     or pg_temp.thb('00000000-0000-0000-0000-00000005b002') <> 0 then
    raise exception 'FAIL: F5 — บัญชี FCD ต้องเหลือ 0 ทั้งเงินตรา (%) และบาท (%)',
      pg_temp.fx('00000000-0000-0000-0000-00000005b002'),
      pg_temp.thb('00000000-0000-0000-0000-00000005b002');
  end if;
  if pg_temp.thb('00000000-0000-0000-0000-00000005b001') <> 10000 then
    raise exception 'FAIL: F5 — บัญชีบาทควรเหลือ +10,000 (จ่าย 365,000 แลกคืนได้ 375,000) แต่ได้ %',
      pg_temp.thb('00000000-0000-0000-0000-00000005b001');
  end if;

  raise notice 'ok F5 · แลกเป็นบาทจริง: กำไรเข้า P&L 10,000 (= 375,000 − 365,000 ต้นทุนจริง) · 3410 เหลือ 0 พอดี · บัญชี FCD เหลือ 0 ทั้งเงินตราและบาท · และใบที่ไม่ล้าง 3410 ถูกปฏิเสธ';
end $$;

-- ============================================================
-- F6 · บัญชีบาทเดิมยังลงได้ปกติ (ของเดิมต้องไม่พัง)
-- ============================================================
do $$
begin
  perform pg_temp.must_pass('F6 ค่าเช่าเข้าบัญชีบาทตามปกติ',
    $q$ select pg_temp.post(pg_temp.entry('inc.rent', 'F6 ค่าเช่าเข้าบัญชีบาท 50,000',
          jsonb_build_array(
            pg_temp.ln('1100', 50000, 0, 'operating', '00000000-0000-0000-0000-00000005b001'),
            pg_temp.ln('4200', 0, 50000, 'operating', null, null, null, null, null,
                       '00000000-0000-0000-0000-00000005a001')))) $q$);
  if pg_temp.thb('00000000-0000-0000-0000-00000005b001') <> 60000 then
    raise exception 'FAIL: F6 — บัญชีบาทควรเป็น 60,000 แต่ได้ %',
      pg_temp.thb('00000000-0000-0000-0000-00000005b001');
  end if;
  raise notice 'ok F6 · บัญชีบาทลงรายการได้เหมือนเดิมทุกอย่าง (ไม่ต้องส่งข้อมูลอัตราเลย)';
end $$;

-- ============================================================
-- F7 · **MUTATION** — ถอดด่านอัตราออก แล้ววัดว่ายอดเพี้ยนเท่าไร
--      นี่คือสภาพก่อนแก้: บัญชีที่ถือ USD ถูกนับเป็นบาททั้งก้อน
-- ============================================================
savepoint before_fx_mutation;

drop trigger trg_lines_fx_shape on sri_os.transaction_lines;

do $$
declare v_thb numeric; v_fx numeric;
begin
  -- ลงบัญชี USD เป็นบาทเฉยๆ (ก่อนแก้ทำได้) — ฝากเงินตรา 10,000 USD แต่คีย์ยอดเป็น 10,000
  perform pg_temp.post(pg_temp.entry('trf.internal', 'F7 ลงบัญชี FCD เป็นบาท (mutation)',
    jsonb_build_array(
      pg_temp.ln('1100', 10000, 0, 'none', '00000000-0000-0000-0000-00000005b002'),
      pg_temp.ln('1100', 0, 10000, 'none', '00000000-0000-0000-0000-00000005b001'))));

  v_thb := pg_temp.thb('00000000-0000-0000-0000-00000005b002');
  v_fx  := pg_temp.fx('00000000-0000-0000-0000-00000005b002');
  if v_thb <> 10000 then
    raise exception 'FAIL: F7 — ถอดด่านแล้วควรลงได้โดยยอดบาทเป็น 10,000 (นับเงินตราเป็นบาท) แต่ได้ %', v_thb;
  end if;
  if v_fx <> 0 then
    raise exception 'FAIL: F7 — ใบที่ไม่มีข้อมูลสกุลทำให้ยอดเงินตราหายไป (ควรเป็น 0 ได้ %)', v_fx;
  end if;
  -- ของจริงที่อัตรา 36.50 คือ 365,000 → งบขาดไป 355,000 โดยไม่มีใครจับได้
  if 10000 * 36.5 - v_thb <> 355000 then
    raise exception 'FAIL: F7 — ส่วนต่างที่ควรวัดได้คือ 355,000 แต่ได้ %', 10000 * 36.5 - v_thb;
  end if;

  raise notice 'ok F7 · MUTATION · ถอดด่านอัตราออก → ลงบัญชี USD เป็นบาทได้ · 10,000 USD ถูกนับเป็น 10,000 บาท ทั้งที่จริงคือ 365,000 → **ยอดเงินสดในงบขาดไป 355,000 โดยไม่มีด่านไหนจับได้** และยอดเงินตราหายทั้งก้อน (ย้อนไม่ได้)';
end $$;

rollback to savepoint before_fx_mutation;

do $$
begin
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.transaction_lines'::regclass
                    and g.tgname = 'trg_lines_fx_shape' and not g.tgisinternal) then
    raise exception 'FAIL: F7b — ด่านไม่กลับมาหลัง rollback';
  end if;
  if pg_temp.fx('00000000-0000-0000-0000-00000005b002') <> 0
     or pg_temp.thb('00000000-0000-0000-0000-00000005b002') <> 0 then
    raise exception 'FAIL: F7b — ใบของ mutation ยังค้างอยู่หลัง rollback';
  end if;
  raise notice 'ok F7b · ด่านกลับมาและไม่มีใบของ mutation ค้างในสมุด';
end $$;

do $$ begin raise notice '=== FCD (บัญชีเงินฝากสกุลต่างประเทศ) ผ่านทั้งหมด ==='; end $$;

rollback;
