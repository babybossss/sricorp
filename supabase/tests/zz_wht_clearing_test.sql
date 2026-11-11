-- ============================================================
-- SRI OS · **ล้างเครดิตภาษีถูกหัก ณ ที่จ่ายได้จริง** (20261025000021)
--
-- **รูที่พิสูจน์** — ด่าน gross-up คิดยอดบัญชี 1800 เป็น **ยอดสุทธิ**
-- (debit − credit) → ใบล้าง (เดบิตเงินสด / เครดิต 1800) ได้ค่าติดลบ แล้วเข้า
-- เงื่อนไข "มีบรรทัด 1800 แต่หมวดนี้ถูกหักภาษีไม่ได้" → **ถูกปฏิเสธทุกใบ**
-- ผล: ยอด 1800 โตขึ้นตลอดไป · เครดิตภาษีที่ขอคืนได้จริงไม่มีทางหายจากงบดุล
-- (เจอจากการไล่ทุกหมวดในเทสต์ประตูร่าง C-3 · guard เดิมตรวจแค่ว่า "มีหมวด
--  สำหรับล้างอยู่ในตารางกฎ" ไม่ได้ตรวจว่า "ลงได้จริง")
--
-- **ทุกเคสรันเป็น role `authenticated`**
--
--   W1 · รับค่าเช่าที่ถูกหักภาษี → 1800 = +600 (เส้นทางเดิมยังทำได้)
--   W2 · **ขอคืน/ใช้เครดิตภาษี → 1800 กลับเป็น 0** (ก่อนแก้: ลงไม่ได้เลย)
--   W3 · หมวดอื่นเครดิต 1800 → ปฏิเสธ (สินทรัพย์ภาษีหายโดยไม่มีเงินเข้าแทน)
--   W4 · ใบเดียวมีทั้งถูกหักและล้าง → ปฏิเสธ (ต้องแยกใบ)
--   **WM · MUTATION** — ใส่ตรรกะรุ่นก่อน (ยอดสุทธิ) กลับไป → ใบล้างถูกปฏิเสธ
--        และ **1800 ค้างอยู่ 600 บาทตลอดไป**
-- ============================================================

\set ON_ERROR_STOP 1

begin;

create temporary table w_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into w_uid(label) values ('mgmt');
insert into auth.users(id) select id from w_uid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select id, label || '@wht.local', label, 'management', true from w_uid;
insert into sri_os.user_owner_access(user_id, owner_id)
select u.id, o.id from w_uid u, sri_os.owners o;

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
select '00000000-0000-0000-0000-0000000bb0b1'::uuid, id, 'KBANK', 'บัญชีบาท', 'บัญชีบาท'
  from sri_os.owners where code = 'THANAKORN';
insert into sri_os.contacts(id, first_name, types)
values ('00000000-0000-0000-0000-0000000ccc01', 'ผู้เช่าที่หักภาษี', array['tenant']);
insert into sri_os.assets(id, code, name, class_id, category_id, owner_id)
select '00000000-0000-0000-0000-0000000aaa01', 'WH-1', 'ห้องเช่าทดสอบภาษี', k.class_id, k.id, o.id
  from (select class_id, id from sri_os.asset_categories order by code limit 1) k,
       sri_os.owners o where o.code = 'THANAKORN';

create or replace function pg_temp.own(p text) returns uuid
language sql stable as $fn$ select id from sri_os.owners where code = p $fn$;
create or replace function pg_temp.login(p text) returns void
language sql as $fn$ select set_config('test.uid', (select id::text from w_uid where label = p), true) $fn$;
create or replace function pg_temp.wht1800() returns numeric
language sql stable as $fn$
  select coalesce(sum(v.debit - v.credit), 0)
    from sri_os.v_ledger_posted v
    join sri_os.chart_of_accounts c on c.id = v.coa_id
   where c.code = '1800'
$fn$;
create or replace function pg_temp.must_fail_like(p_label text, p_sql text, p_needle text)
returns void language plpgsql as $fn$
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

do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.w_uid to authenticated', s);
end $$;

-- ============================================================
-- W1 + W2 · ถูกหักภาษี แล้ว **ล้างได้**
-- ============================================================
do $$
begin
  set local role authenticated;
  perform pg_temp.login('mgmt');

  -- W1 · ค่าเช่า 12,000 ถูกหักภาษี 5% = 600 → เงินเข้า 11,400
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code', 'inc.rent', 'doc_date', '2026-04-01', 'cash_date', '2026-04-01',
    'memo', 'W1 ค่าเช่าที่ถูกหักภาษี', 'wht_rate', 5, 'wht_amount', 600,
    'asset_id', '00000000-0000-0000-0000-0000000aaa01',
    'contact_id', '00000000-0000-0000-0000-0000000ccc01',
    'attachments', jsonb_build_array('ใบรับรองหักภาษี.pdf'),
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', pg_temp.own('THANAKORN'),
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code', '1100', 'debit', 11400, 'credit', 0,
                           'cf_category', 'operating',
                           'bank_account_id', '00000000-0000-0000-0000-0000000bb0b1'),
        jsonb_build_object('coa_code', '1800', 'debit', 600, 'credit', 0,
                           'cf_category', 'operating'),
        jsonb_build_object('coa_code', '4200', 'debit', 0, 'credit', 12000,
                           'cf_category', 'operating'))))));
  if pg_temp.wht1800() <> 600 then
    raise exception 'FAIL: W1 — เครดิตภาษีต้องเป็น 600 แต่ได้ %', pg_temp.wht1800();
  end if;

  -- W2 · ใช้เครดิตภาษี/ขอคืน → 1800 กลับเป็น 0
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code', 'inv.wht_refund', 'doc_date', '2026-05-01', 'cash_date', '2026-05-01',
    'memo', 'W2 ได้รับคืนภาษีที่ถูกหักไว้',
    'attachments', jsonb_build_array('หนังสือคืนภาษี.pdf'),
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', pg_temp.own('THANAKORN'),
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code', '1100', 'debit', 600, 'credit', 0,
                           'cf_category', 'operating',
                           'bank_account_id', '00000000-0000-0000-0000-0000000bb0b1'),
        jsonb_build_object('coa_code', '1800', 'debit', 0, 'credit', 600,
                           'cf_category', 'operating'))))));
  if pg_temp.wht1800() <> 0 then
    raise exception 'FAIL: W2 — ล้างเครดิตภาษีแล้วต้องเหลือ 0 แต่ได้ % (ก่อนแก้ ใบนี้ลงไม่ได้เลย)',
      pg_temp.wht1800();
  end if;

  reset role;
  raise notice 'ok W1-W2 · ถูกหักภาษี 600 → เครดิตภาษี 600 · ขอคืนแล้ว **กลับเป็น 0** (ก่อน 20261025000021 ใบขอคืนถูกปฏิเสธทุกใบ → 600 ค้างตลอดไป)';
exception when others then
  reset role; raise;
end $$;

-- ============================================================
-- W3 + W4 · เครดิต 1800 ได้เฉพาะทางล้างตามตารางกฎ
-- ============================================================
do $$
begin
  set local role authenticated;
  perform pg_temp.login('mgmt');

  -- W3 · หมวดรายได้เครดิต 1800 (ลบสินทรัพย์ภาษีทิ้งโดยไม่มีเงินเข้ามาแทน)
  perform pg_temp.must_fail_like('W3 หมวดอื่นเครดิต 1800', $q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code', 'inc.rent', 'doc_date', '2026-06-01', 'cash_date', '2026-06-01',
      'memo', 'W3 แอบล้างเครดิตภาษีจากหมวดรายได้',
      'asset_id', '00000000-0000-0000-0000-0000000aaa01',
      'contact_id', '00000000-0000-0000-0000-0000000ccc01',
      'attachments', jsonb_build_array('x.pdf'),
      'transactions', jsonb_build_array(jsonb_build_object(
        'owner_id', (select id from sri_os.owners where code = 'THANAKORN'),
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code', '1100', 'debit', 12600, 'credit', 0,
                             'cf_category', 'operating',
                             'bank_account_id', '00000000-0000-0000-0000-0000000bb0b1'),
          jsonb_build_object('coa_code', '4200', 'debit', 0, 'credit', 12000,
                             'cf_category', 'operating'),
          jsonb_build_object('coa_code', '1800', 'debit', 0, 'credit', 600,
                             'cf_category', 'operating'))))))
    $q$,
    'ไม่ใช่หมวดสำหรับล้างเครดิตภาษี');

  -- W4 · ใบเดียวมีทั้งถูกหักและล้าง → แยกใบ
  perform pg_temp.must_fail_like('W4 ใบเดียวมีทั้งสองด้าน', $q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code', 'inv.wht_refund', 'doc_date', '2026-06-02', 'cash_date', '2026-06-02',
      'memo', 'W4 ทั้งถูกหักและล้างในใบเดียว',
      'attachments', jsonb_build_array('x.pdf'),
      'transactions', jsonb_build_array(jsonb_build_object(
        'owner_id', (select id from sri_os.owners where code = 'THANAKORN'),
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code', '1100', 'debit', 600, 'credit', 0,
                             'cf_category', 'operating',
                             'bank_account_id', '00000000-0000-0000-0000-0000000bb0b1'),
          jsonb_build_object('coa_code', '1800', 'debit', 100, 'credit', 0,
                             'cf_category', 'operating'),
          jsonb_build_object('coa_code', '1800', 'debit', 0, 'credit', 700,
                             'cf_category', 'operating'))))))
    $q$,
    'ต้องแยกใบ');

  if pg_temp.wht1800() <> 0 then
    raise exception 'FAIL: W3-W4 — ทุกเคสถูกปฏิเสธ เครดิตภาษีต้องยังเป็น 0 แต่ได้ %',
      pg_temp.wht1800();
  end if;

  reset role;
  raise notice 'ok W3-W4 · หมวดอื่นเครดิต 1800 ไม่ได้ · ใบเดียวมีทั้งถูกหักและล้างไม่ได้ · ยอดเครดิตภาษียังเป็น 0';
exception when others then
  reset role; raise;
end $$;

-- ============================================================
-- WM · **MUTATION** — ใส่ตรรกะรุ่นก่อน (คิด 1800 เป็นยอดสุทธิ) กลับไป
--      แล้ววัดว่าเครดิตภาษีค้างอยู่เท่าไร
-- ============================================================
do $$
declare v_before numeric;
begin
  -- ตั้งยอดเครดิตภาษีขึ้นมาใหม่ 600 ด้วยเส้นทางปกติ
  set local role authenticated;
  perform pg_temp.login('mgmt');
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code', 'inc.rent', 'doc_date', '2026-07-01', 'cash_date', '2026-07-01',
    'memo', 'WM ค่าเช่าที่ถูกหักภาษี', 'wht_rate', 5, 'wht_amount', 600,
    'asset_id', '00000000-0000-0000-0000-0000000aaa01',
    'contact_id', '00000000-0000-0000-0000-0000000ccc01',
    'attachments', jsonb_build_array('ใบรับรองหักภาษี.pdf'),
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', pg_temp.own('THANAKORN'),
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code', '1100', 'debit', 11400, 'credit', 0,
                           'cf_category', 'operating',
                           'bank_account_id', '00000000-0000-0000-0000-0000000bb0b1'),
        jsonb_build_object('coa_code', '1800', 'debit', 600, 'credit', 0,
                           'cf_category', 'operating'),
        jsonb_build_object('coa_code', '4200', 'debit', 0, 'credit', 12000,
                           'cf_category', 'operating'))))));
  v_before := pg_temp.wht1800();
  reset role;

  /**
   * สตับของ **ข้อ (ก) รุ่นก่อน** เท่านั้น (คิด 1800 เป็น debit − credit)
   * ไม่ได้ยกมาทั้งฟังก์ชัน เพราะต้องการวัดผลของ "ยอดสุทธิ" ตัวเดียว
   */
  create or replace function sri_os.fn_assert_wht_gross_for(p_txn uuid) returns void
  language plpgsql security definer set search_path = '' as $stub$
  declare v_type text; v_net numeric;
  begin
    select t.txn_type_code into v_type from sri_os.transactions t where t.id = p_txn;
    if v_type is null then return; end if;
    if exists (select 1 from sri_os.txn_types ty
                where ty.code = v_type and ty.group_code = 'opening') then return; end if;
    select coalesce(sum(case when c.code = '1800' then l.debit - l.credit else 0 end), 0)
      into v_net
      from sri_os.transaction_lines l
      join sri_os.chart_of_accounts c on c.id = l.coa_id
     where l.transaction_id = p_txn;
    if v_net <> 0 and not sri_os.fn_txn_type_can_withhold(v_type) then
      raise exception '(รุ่นก่อน) ใบนี้มีบรรทัด 1800 แต่หมวด "%" ถูกหักภาษีไม่ได้', v_type;
    end if;
  end $stub$;

  set local role authenticated;
  perform pg_temp.login('mgmt');
  perform pg_temp.must_fail_like('WM ใบล้างเครดิตภาษีด้วยตรรกะรุ่นก่อน', $q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code', 'inv.wht_refund', 'doc_date', '2026-08-01', 'cash_date', '2026-08-01',
      'memo', 'WM ขอคืนภาษีตอนใช้ตรรกะรุ่นก่อน',
      'attachments', jsonb_build_array('x.pdf'),
      'transactions', jsonb_build_array(jsonb_build_object(
        'owner_id', (select id from sri_os.owners where code = 'THANAKORN'),
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code', '1100', 'debit', 600, 'credit', 0,
                             'cf_category', 'operating',
                             'bank_account_id', '00000000-0000-0000-0000-0000000bb0b1'),
          jsonb_build_object('coa_code', '1800', 'debit', 0, 'credit', 600,
                             'cf_category', 'operating'))))))
    $q$,
    '(รุ่นก่อน)');
  reset role;

  if pg_temp.wht1800() <> v_before then
    raise exception 'FAIL: WM — ยอดเครดิตภาษีต้องค้างอยู่ที่ % แต่ได้ %', v_before, pg_temp.wht1800();
  end if;

  raise notice 'ok WM (MUTATION) · ด้วยตรรกะรุ่นก่อน (1800 = ยอดสุทธิ) ใบขอคืนถูกปฏิเสธ → เครดิตภาษี **ค้างอยู่ % บาทตลอดไป** ทั้งที่ขอคืนได้จริง · สินทรัพย์ภาษีในงบจึงสูงกว่าความจริงเรื่อยๆ',
    v_before;
exception when others then
  reset role; raise;
end $$;

rollback;

-- ============================================================
-- WMb · สภาพหลัง mutation ต้องกลับมาครบ (ฟังก์ชันตัวจริง ไม่ใช่สตับ)
-- ============================================================
do $$
declare v text;
begin
  select regexp_replace(regexp_replace(p.prosrc, '/\*.*?\*/', ' ', 'gs'), '--[^\n]*', ' ', 'g')
    into v
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'sri_os' and p.proname = 'fn_assert_wht_gross_for';
  if v is null or v !~ 'then l\.credit else 0' or v !~ 'cr_coa_code = ''1800''' then
    raise exception 'FAIL: WMb — ด่านตัวจริงไม่กลับมาหลัง rollback (ยังเป็นสตับของรุ่นก่อน?)';
  end if;
  raise notice 'ok WMb · ด่านตัวจริงกลับมาหลัง rollback';
end $$;

\echo 'zz_wht_clearing_test: ผ่านทุกข้อ'
