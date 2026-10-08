-- ============================================================
-- SRI OS · เทสต์การปิดรูของ fn_post_entry() 7 ข้อ
--   (migration 20261008000011_post_entry_hardening.sql)
--
-- โครงเหมือน zz_post_entry_test.sql: ทั้งไฟล์อยู่ใน transaction เดียวและ rollback ปิดท้าย
--   ทุกเคสที่ตรวจสิทธิ์/RLS รันด้วย `set local role authenticated` + GUC test.uid
--   (superuser ข้าม RLS → ถ้าลืม จะกลายเป็นเทสต์ที่ไม่ได้ตรวจอะไร · H0 กันไว้)
--
-- ไฟล์นี้เขียน **ก่อน** แก้ migration (test-first) และทุกเคส H1-H7 คือสิ่งที่ผู้ตรวจ
--   ยิงสำเร็จจริงมาแล้ว (attack.sql · attack3.sql · attack5.sql ใน scratchpad)
--
-- โครงสร้างของไฟล์
--   H0        โครงสร้าง/ACL ของด่านใหม่ (ไล่จาก catalog จริง ไม่ใช่ไล่ไฟล์)
--   H1        บัญชีธนาคารต้องเป็นของผู้ถือของรายการ (ทั้งทางประตูและ INSERT ตรง)
--   H2        ข้ามผู้ถือต้องครบคู่ + บัญชีระหว่างกันต้องจับคู่กัน
--   H3        คู่บัญชีต้องตรงกับตารางกฎ (เงินกู้ห้ามกลายเป็นรายได้)
--   H4        กันกดซ้ำ: ทุกรูปของค่าเดียวกันต้องได้ fingerprint เดียวกัน
--   H5        created_by ปลอมไม่ได้
--   H7        bank_account_id ติดได้เฉพาะขาเงินสด
--   H8        **เส้นทางที่ถูกต้องต้องยังทำได้** (ถ้ากันแน่นเกินจนใช้งานไม่ได้ = พัง)
--   H9        เคส "ไม่ส่งข้อมูล" ของกฎใหม่ทุกข้อ
--   H10       สิ่งที่ไฟล์นี้ยัง **ไม่** ปิด — พิมพ์ออกมาให้เห็น ไม่ซ่อน
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
create temporary table t_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_uid(label) values ('mgmt'), ('mgr'), ('victim');
insert into auth.users(id) select id from t_uid;

insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, u.label || '@hard.local', u.label, x.role, true
  from t_uid u
  join (values ('mgmt', 'management'), ('mgr', 'manager'), ('victim', 'manager')) as x(label, role)
    on x.label = u.label;

create or replace function pg_temp.uid(p_label text) returns uuid
language sql stable as $fn$ select id from t_uid where label = p_label $fn$;

create or replace function pg_temp.login(p_label text) returns void
language sql as $fn$
  select set_config('test.uid', coalesce((select id::text from t_uid where label = p_label), ''), true);
$fn$;

-- mgr เห็น ธนากร + สุธี + SRI Corp (ไม่เห็น เบ็ญจพร)
insert into sri_os.user_owner_access(user_id, owner_id)
select pg_temp.uid('mgr'), o.id from sri_os.owners o
 where o.code in ('THANAKORN', 'SUTEE', 'SRI_CORP');

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name, is_active)
values
  ('00000000-0000-0000-0000-0000000d0001', (select id from sri_os.owners where code='THANAKORN'),
   'BBL', 'ธนากร', 'ธนากร - BBL 888', true),
  ('00000000-0000-0000-0000-0000000d0002', (select id from sri_os.owners where code='SUTEE'),
   'KBANK', 'สุธี', 'สุธี - KBANK 111', true),
  ('00000000-0000-0000-0000-0000000d0003', (select id from sri_os.owners where code='SRI_CORP'),
   'SCB', 'SRI Corporation', 'SRI - SCB 222', true);

insert into sri_os.contacts(id, first_name, types)
values ('00000000-0000-0000-0000-0000000e0001', 'ผู้เช่าตัวอย่าง', array['tenant']);

create or replace function pg_temp.must_fail(p_label text, p_sql text) returns void
language plpgsql as $fn$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    return;
  end;
  raise exception 'FAIL: % — คำสั่งควรถูกปฏิเสธแต่สำเร็จ · sql: %', p_label, p_sql;
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

/**
 * payload ของรายการค่าเช่าใบหนึ่ง — คุมได้ทั้งยอด (เป็น **ข้อความ** เพื่อทดสอบรูปตัวเลข)
 * บัญชี และผู้ถือ · ใช้ซ้ำทุกเคสเพื่อให้ความต่างในเทสต์คือสิ่งที่ตั้งใจทดสอบเท่านั้น
 */
create or replace function pg_temp.rent(p_memo text, p_amt_json text default '12000',
                                        p_bank uuid default '00000000-0000-0000-0000-0000000d0001',
                                        p_owner text default 'THANAKORN')
returns jsonb language sql stable as $fn$
  select format($j$
    {"txn_type_code":"inc.rent","doc_date":"2026-09-01","cash_date":"2026-09-03","memo":%s,
     "transactions":[{"owner_id":"%s","lines":[
       {"coa_code":"1100","bank_account_id":"%s","debit":%s,"credit":0,"cf_category":"operating"},
       {"coa_code":"4200","debit":0,"credit":%s,"cf_category":"operating"}]}]}
  $j$, to_jsonb(p_memo)::text, (select id from sri_os.owners where code = p_owner),
       p_bank, p_amt_json, p_amt_json)::jsonb;
$fn$;

do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.t_uid to authenticated', s);
end $$;

-- ============================================================
-- H0 · โครงสร้างของด่านใหม่ — ไล่จาก catalog จริง
-- ============================================================
do $$
declare v text;
begin
  -- (ก) ประตูยังต้องเป็น invoker (definer = ประตูหลังข้าม RLS ทุกตาราง)
  if (select p.prosecdef from pg_proc p
       where p.oid = 'sri_os.fn_post_entry(jsonb)'::regprocedure) then
    raise exception 'FAIL: fn_post_entry กลายเป็น SECURITY DEFINER';
  end if;

  -- (ข) กฎ "บัญชีต้องเป็นของผู้ถือ" ต้องเป็น **trigger บนตาราง** ไม่ใช่ด่านในประตู
  --     (ถ้าอยู่แต่ในประตู การ INSERT ตรงผ่าน PostgREST จะเลี่ยงได้ — บทเรียนข้อ 6)
  if not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                  where tg.tgrelid = 'sri_os.transaction_lines'::regclass
                    and p.proname = 'fn_assert_line_bank_owner'
                    and (tg.tgtype & 4) <> 0 and (tg.tgtype & 2) <> 0 and (tg.tgtype & 16) <> 0) then
    raise exception 'FAIL: ไม่มี trigger before insert or update กันบัญชีผิดผู้ถือบน transaction_lines';
  end if;

  -- (ค) กฎ "ข้ามผู้ถือต้องครบคู่" ต้องเป็น constraint trigger แบบ deferred
  --     (ตอนลงขาแรก ขาที่สองยังไม่เกิด → ตรวจทันทีไม่ได้)
  if not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                  where tg.tgrelid = 'sri_os.transactions'::regclass
                    and p.proname = 'fn_assert_intercompany_pair'
                    and tg.tgdeferrable and tg.tginitdeferred) then
    raise exception 'FAIL: ไม่มี constraint trigger (deferred) กันข้ามผู้ถือขาเดียว';
  end if;

  -- (ง) กฎเงินห้ามขึ้นกับสิทธิ์ — ด่านใหม่ต้องไม่เรียก fn_can (ไม่งั้นปิดได้จากหน้า Settings)
  select string_agg(p.proname, ', ') into v from pg_proc p
   where p.oid in ('sri_os.fn_assert_line_bank_owner()'::regprocedure,
                   'sri_os.fn_assert_intercompany_pair()'::regprocedure)
     and p.prosrc ~* 'fn_can';
  if v is not null then
    raise exception 'FAIL: ด่านเงิน % เรียก fn_can', v;
  end if;

  -- (จ) trigger function เรียกตรงไม่ได้ · ฟังก์ชันช่วยของประตูเปิดให้ authenticated
  --     (ประตูเป็น invoker → ถ้าปิด fn_canonical_payload ประตูจะพังทุกครั้ง)
  if has_function_privilege('authenticated', 'sri_os.fn_assert_line_bank_owner()', 'execute')
     or has_function_privilege('authenticated', 'sri_os.fn_assert_intercompany_pair()', 'execute')
     or has_function_privilege('public', 'sri_os.fn_assert_intercompany_pair()', 'execute') then
    raise exception 'FAIL: trigger function ของด่านเงินเรียกตรงได้';
  end if;
  if not has_function_privilege('authenticated', 'sri_os.fn_canonical_payload(jsonb)', 'execute') then
    raise exception 'FAIL: authenticated เรียก fn_canonical_payload ไม่ได้ → ประตูพังทุกครั้ง';
  end if;
  if has_function_privilege('anon', 'sri_os.fn_canonical_payload(jsonb)', 'execute') then
    raise exception 'FAIL: anon เรียก fn_canonical_payload ได้';
  end if;

  -- (ฉ) ข้อ 5 ต้องอยู่ในโค้ดจริง ไม่ใช่อยู่ในคอมเมนต์
  select p.prosrc into v from pg_proc p
   where p.oid = 'sri_os.fn_txn_system_columns()'::regprocedure;
  if v !~ 'created_by\s*:=\s*auth\.uid\(\)' then
    raise exception 'FAIL: fn_txn_system_columns ไม่ได้ตั้ง created_by = auth.uid()';
  end if;

  raise notice 'ok H0 · ประตูเป็น invoker · ด่านบัญชีผิดผู้ถือเป็น trigger · ด่านคู่ข้ามผู้ถือเป็น constraint trigger · ACL แคบ';
end $$;

-- H0b · superuser ข้าม RLS → ถ้าเทสต์ทั้งไฟล์รันเป็น superuser จะไม่ได้ตรวจอะไร
set local role authenticated;
select pg_temp.login('mgr');
do $$ begin
  if current_user = 'postgres' then raise exception 'FAIL: เทสต์รันเป็น superuser'; end if;
  if auth.uid() is null then raise exception 'FAIL: ไม่ได้ล็อกอินใน GUC test.uid'; end if;
  raise notice 'ok H0b · เทสต์รันในฐานะ authenticated จริง (ไม่ใช่ superuser)';
end $$;

-- ============================================================
-- H1 · ข้อ 1 ของผู้ตรวจ — บัญชีธนาคารต้องเป็นของผู้ถือของรายการนั้น
--      ก่อนมีด่านนี้: mgr ลง Dr 1100 70,000 เข้า SRI-SCB ของ SRI Corporation
--      ในรายการของธนากรได้สำเร็จ · เงินไปอยู่ในบัญชีของผู้ถือที่ตัวเองมองไม่เห็นด้วยซ้ำ
-- ============================================================
do $$
declare v_n int;
begin
  -- (ก) บัญชีของผู้ถือที่ "เห็นได้" แต่ไม่ใช่ผู้ถือของรายการ
  perform pg_temp.must_fail_like('H1a บัญชีของสุธีในรายการของธนากร',
    $q$ select sri_os.fn_post_entry(pg_temp.rent('H1a', '50000', '00000000-0000-0000-0000-0000000d0002')) $q$,
    'ผู้ถืออื่น');

  -- (ข) บัญชีของผู้ถือที่ตัวเอง **มองไม่เห็น** (เคส A6b ของผู้ตรวจ)
  perform pg_temp.must_fail_like('H1b บัญชีของ SRI Corp ในรายการของธนากร',
    $q$ select sri_os.fn_post_entry(pg_temp.rent('H1b', '70000', '00000000-0000-0000-0000-0000000d0003')) $q$,
    'ผู้ถืออื่น');

  -- (ค) บัญชีที่ไม่มีอยู่จริง ต้องปฏิเสธ ไม่ใช่ลงเป็นเงินลอย
  perform pg_temp.must_fail('H1c บัญชีที่ไม่มีอยู่จริง',
    $q$ select sri_os.fn_post_entry(pg_temp.rent('H1c', '100', '00000000-0000-0000-0000-00000000dead')) $q$);

  reset role;
  select count(*) into v_n from sri_os.transactions where memo in ('H1a', 'H1b', 'H1c');
  set local role authenticated;
  if v_n <> 0 then raise exception 'FAIL: เคส H1 ที่ถูกปฏิเสธทิ้งรายการไว้ % แถว', v_n; end if;
  raise notice 'ok H1 · ลงเงินเข้าบัญชีของผู้ถืออื่นไม่ได้ (ทั้งที่เห็นและไม่เห็น) และไม่ทิ้งแถวไว้';
end $$;

-- H1d · ด่านนี้ต้องกัน **การ INSERT ตรงเข้าตาราง** ด้วย ไม่ใช่กันแค่ที่ประตู
--       (ผ่าน PostgREST ทำได้จริง — ถ้ากันแค่ในประตู รูเดิมยังเปิดอยู่)
do $$
declare v_txn uuid := gen_random_uuid(); v_own uuid;
begin
  select id into v_own from sri_os.owners where code = 'THANAKORN';
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, cash_date, memo)
  values (v_txn, v_own, 'inc.rent', '2026-09-01', '2026-09-03', 'H1d');

  perform pg_temp.must_fail_like('H1d INSERT ตรงด้วยบัญชีของผู้ถืออื่น', format($q$
    insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id, debit, credit)
    values (%L, (select id from sri_os.chart_of_accounts where code = '1100'),
            '00000000-0000-0000-0000-0000000d0003', 100, 0)
  $q$, v_txn), 'ผู้ถืออื่น');

  -- บัญชีของผู้ถือเดียวกัน = ต้องลงได้ (ด่านต้องไม่กันของที่ถูก)
  insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id, debit, credit)
  values (v_txn, (select id from sri_os.chart_of_accounts where code = '1100'),
          '00000000-0000-0000-0000-0000000d0001', 100, 0);
  insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
  values (v_txn, (select id from sri_os.chart_of_accounts where code = '4200'), 0, 100);
  raise notice 'ok H1d · ด่านอยู่ที่ตาราง ไม่ใช่แค่ในประตู (INSERT ตรงก็ถูกกัน) · บัญชีของผู้ถือเดียวกันยังลงได้';
end $$;

-- ============================================================
-- H2 · ข้อ 2 ของผู้ตรวจ — ข้ามผู้ถือขาเดียวลงได้
--      1310 ค้างข้างเดียวไม่มี 2310 คู่ → งบรวมตัดรายการระหว่างกันไม่ลง
--      และเงินสดรวม ≠ ผลรวมบัญชี (Invariant 3/6)
-- ============================================================
do $$
declare
  v_t uuid := (select id from sri_os.owners where code='THANAKORN');
  v_s uuid := (select id from sri_os.owners where code='SUTEE');
  v_n int;
begin
  -- (ก) ขาเดียว (เคส A1 ของผู้ตรวจ)
  perform pg_temp.must_fail_like('H2a ข้ามผู้ถือขาเดียว', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code','trf.internal','doc_date','2026-09-10','cash_date','2026-09-10','memo','H2a',
      'transactions', jsonb_build_array(jsonb_build_object(
        'owner_id', %L, 'counter_owner_id', %L, 'intercompany_nature','loan',
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1310','debit',100000,'credit',0,'cf_category','investing'),
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',0,'credit',100000,'cf_category','investing'))))))
  -- needle มีคำว่า "บันทึกรายการไม่ได้" โดยตั้งใจ: ผู้กดต้องได้ข้อความจาก **ประตู**
  -- ก่อนที่อะไรจะถูกเขียน · ถ้าเหลือแต่ด่าน trigger ข้อความจะไม่มีคำนี้ (คนละชั้น)
  $q$, v_t, v_s), 'บันทึกรายการไม่ได้: รายการข้ามผู้ถือต้องมาครบคู่');

  -- (ข) สองขาแต่ยอดไม่เท่ากัน = ไม่ใช่คู่กันจริง
  perform pg_temp.must_fail_like('H2b สองขายอดไม่เท่ากัน', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code','trf.internal','doc_date','2026-09-10','cash_date','2026-09-10','memo','H2b',
      'transactions', jsonb_build_array(
        jsonb_build_object('owner_id', %L, 'counter_owner_id', %L, 'intercompany_nature','loan',
          'lines', jsonb_build_array(
            jsonb_build_object('coa_code','1310','debit',500,'credit',0),
            jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',0,'credit',500))),
        jsonb_build_object('owner_id', %L, 'counter_owner_id', %L, 'intercompany_nature','loan',
          'lines', jsonb_build_array(
            jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0002','debit',400,'credit',0),
            jsonb_build_object('coa_code','2310','debit',0,'credit',400))))))
  $q$, v_t, v_s, v_s, v_t), 'ครบคู่');

  -- (ค) สามขา: ขาที่สามจับคู่กับขาเดิมซ้ำ → ถ้านับด้วย exists จะหลุด
  perform pg_temp.must_fail_like('H2c สามขา (จับคู่ซ้ำ)', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code','trf.internal','doc_date','2026-09-10','cash_date','2026-09-10','memo','H2c',
      'transactions', jsonb_build_array(
        jsonb_build_object('owner_id', %L, 'counter_owner_id', %L, 'intercompany_nature','loan',
          'lines', jsonb_build_array(
            jsonb_build_object('coa_code','1310','debit',500,'credit',0),
            jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',0,'credit',500))),
        jsonb_build_object('owner_id', %L, 'counter_owner_id', %L, 'intercompany_nature','loan',
          'lines', jsonb_build_array(
            jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0002','debit',500,'credit',0),
            jsonb_build_object('coa_code','2310','debit',0,'credit',500))),
        jsonb_build_object('owner_id', %L, 'counter_owner_id', %L, 'intercompany_nature','loan',
          'lines', jsonb_build_array(
            jsonb_build_object('coa_code','1310','debit',500,'credit',0),
            jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',0,'credit',500))))))
  $q$, v_t, v_s, v_s, v_t, v_t, v_s), 'ครบคู่');

  -- (ง) ครบคู่แต่ **บัญชีระหว่างกันไม่จับคู่กัน**: 1310 ทั้งสองข้าง ไม่มี 2310 เลย
  --     เดิมเคสนี้ใช้ 2400 (เงินกู้ยืมอื่น) ฝั่งผู้รับ — ตั้งแต่ 20261008000012
  --     บัญชีระหว่างกันถูกล็อกเป็น **รหัสตรง** ที่ trg_lines_rule_coa → 2400 ถูกปฏิเสธ
  --     ก่อนถึงด่านจับคู่ ทำให้เคสนี้ไม่ได้ทดสอบ "การจับคู่" อีก (เคส 2400 ย้ายไป
  --     zz_line_guards_test.sql) · ใช้ 1310 ทั้งสองข้างแทน ซึ่งเป็นรหัสที่ลงได้
  --     แต่ **หักกลบกันไม่ได้** → ยังพิสูจน์ด่านจับคู่บัญชีระหว่างกันตามเจตนาเดิม
  perform pg_temp.must_fail_like('H2d 1310 ไม่มี 2310 คู่', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code','trf.internal','doc_date','2026-09-10','cash_date','2026-09-10','memo','H2d',
      'transactions', jsonb_build_array(
        jsonb_build_object('owner_id', %L, 'counter_owner_id', %L, 'intercompany_nature','loan',
          'lines', jsonb_build_array(
            jsonb_build_object('coa_code','1310','debit',500,'credit',0),
            jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',0,'credit',500))),
        jsonb_build_object('owner_id', %L, 'counter_owner_id', %L, 'intercompany_nature','loan',
          'lines', jsonb_build_array(
            jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0002','debit',500,'credit',0),
            jsonb_build_object('coa_code','1310','debit',0,'credit',500))))))
  $q$, v_t, v_s, v_s, v_t), 'จับคู่');

  -- (จ) ผู้ถืออีกฝ่ายเป็นคนเดียวกับผู้ถือของรายการ = ไม่ใช่รายการข้ามผู้ถือ
  perform pg_temp.must_fail('H2e counter_owner = owner', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code','trf.internal','doc_date','2026-09-10','cash_date','2026-09-10','memo','H2e',
      'transactions', jsonb_build_array(jsonb_build_object(
        'owner_id', %L, 'counter_owner_id', %L, 'intercompany_nature','loan',
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1310','debit',500,'credit',0),
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',0,'credit',500))))))
  $q$, v_t, v_t));

  reset role;
  select count(*) into v_n from sri_os.transactions where memo like 'H2%';
  set local role authenticated;
  if v_n <> 0 then raise exception 'FAIL: เคส H2 ที่ถูกปฏิเสธทิ้งรายการไว้ % แถว', v_n; end if;
  raise notice 'ok H2 · ข้ามผู้ถือขาเดียว/ยอดไม่เท่า/สามขา/บัญชีระหว่างกันไม่จับคู่ → ปฏิเสธครบ และไม่ทิ้งแถวไว้';
end $$;

-- H2f · เคสเดียวกันแต่ยิง **INSERT ตรงเข้าตาราง** (ไม่ผ่านประตู)
--       พิสูจน์ว่าด่านจริงอยู่ที่ constraint trigger และ **นับคู่ให้เท่ากัน** ไม่ใช่ exists
--       (ถ้าใช้ exists ขาที่สามจะจับคู่กับขาเดิมซ้ำได้ แล้วเงินข้างหนึ่งหายโดยทุกใบยังสมดุล)
do $$
declare
  v_t uuid := (select id from sri_os.owners where code='THANAKORN');
  v_s uuid := (select id from sri_os.owners where code='SUTEE');
  v_a uuid := gen_random_uuid(); v_b uuid := gen_random_uuid(); v_c uuid := gen_random_uuid();
  v_leg uuid; v_bank uuid; v_ic text;
begin
  begin
    foreach v_leg in array array[v_a, v_b, v_c] loop
      -- ขา a/c = ฝ่ายจ่าย (ธนากร) · ขา b = ฝ่ายรับ (สุธี)
      if v_leg = v_b then
        v_bank := '00000000-0000-0000-0000-0000000d0002'; v_ic := '2310';
      else
        v_bank := '00000000-0000-0000-0000-0000000d0001'; v_ic := '1310';
      end if;
      insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, cash_date, memo,
                                      is_intercompany, counter_owner_id, intercompany_nature)
      values (v_leg,
              case when v_leg = v_b then v_s else v_t end,
              'trf.internal', '2026-09-25', '2026-09-25', 'H2f',
              true,
              case when v_leg = v_b then v_t else v_s end,
              'loan');
      insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id, debit, credit)
      values (v_leg, (select id from sri_os.chart_of_accounts where code = v_ic), null,
              case when v_leg = v_b then 0 else 500 end,
              case when v_leg = v_b then 500 else 0 end),
             (v_leg, (select id from sri_os.chart_of_accounts where code = '1100'), v_bank,
              case when v_leg = v_b then 500 else 0 end,
              case when v_leg = v_b then 0 else 500 end);
    end loop;
    -- ยิงด่านที่เลื่อนไว้ตอนนี้ (ของจริงยิงตอน commit)
    set constraints all immediate;
    raise exception 'FAIL: H2f สามขาถูก INSERT ตรงเข้าตารางได้ — ด่านคู่ข้ามผู้ถือจับคู่ซ้ำ';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if position('ครบคู่' in sqlerrm) = 0 then
      raise exception 'FAIL: H2f ปฏิเสธถูกแต่ข้อความไม่ใช่เรื่องคู่ข้ามผู้ถือ · ได้: %', sqlerrm;
    end if;
  end;
  set constraints all deferred;
  raise notice 'ok H2f · INSERT ตรงสามขาถูกปฏิเสธที่ constraint trigger (นับคู่ให้เท่ากัน ไม่ใช่ exists)';
end $$;

-- ============================================================
-- H3 · ข้อ 3 ของผู้ตรวจ — คู่บัญชีไม่ตรงตารางกฎ
--      fin.loan_bank ลง Cr 4200 รายได้ค่าเช่า 900,000 สำเร็จ = **เงินกู้กลายเป็นรายได้**
--      (ข้อแรกของ LEDGER_RULES.md §3 และข้อที่ CLAUDE.md เตือนไว้เอง)
-- ============================================================
do $$
declare
  v_t uuid := (select id from sri_os.owners where code='THANAKORN');
  v_s uuid := (select id from sri_os.owners where code='SUTEE');
  v_n int;
begin
  -- (ก) เงินกู้เข้าบัญชี ลงเป็นรายได้ค่าเช่า
  perform pg_temp.must_fail_like('H3a เงินกู้ลงเป็นรายได้', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code','fin.loan_bank','doc_date','2026-09-11','cash_date','2026-09-11','memo','H3a',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',900000,'credit',0,'cf_category','financing'),
          jsonb_build_object('coa_code','4200','debit',0,'credit',900000,'cf_category','operating'))))))
  $q$, v_t), 'ตารางกฎ');

  -- (ข) ทางกลับ: ค่าเช่าลงเป็นเงินกู้ (รายได้หาย หนี้สินบวม)
  perform pg_temp.must_fail_like('H3b ค่าเช่าลงเป็นเงินกู้', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code','inc.rent','doc_date','2026-09-11','cash_date','2026-09-11','memo','H3b',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',12000,'credit',0,'cf_category','operating'),
          jsonb_build_object('coa_code','2410','debit',0,'credit',12000,'cf_category','operating'))))))
  $q$, v_t), 'ตารางกฎ');

  -- (ค) จ่ายปันผลลงเป็นค่าใช้จ่าย (กำไรสุทธิผิด)
  perform pg_temp.must_fail_like('H3c ปันผลลงเป็นค่าใช้จ่าย', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code','fin.drawings','doc_date','2026-09-11','cash_date','2026-09-11','memo','H3c',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','5900','debit',5000,'credit',0,'cf_category','financing'),
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',0,'credit',5000,'cf_category','financing'))))))
  $q$, v_t), 'ตารางกฎ');

  -- (ง) บัญชีกำไรของหมวดอื่น (4300 เป็นของขายอสังหาฯ ไม่ใช่ของค่าเช่า)
  perform pg_temp.must_fail_like('H3d บัญชีกำไรของหมวดอื่น', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code','inc.rent','doc_date','2026-09-11','cash_date','2026-09-11','memo','H3d',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',100,'credit',0,'cf_category','operating'),
          jsonb_build_object('coa_code','4300','debit',0,'credit',100,'cf_category','operating'))))))
  $q$, v_t), 'ตารางกฎ');

  -- (จ) ขาข้ามผู้ถือก็ยังถูกคุม: ลักษณะ "กู้ยืม" ลงบัญชีรายได้ไม่ได้
  perform pg_temp.must_fail_like('H3e ขาข้ามผู้ถือลงบัญชีรายได้', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code','trf.internal','doc_date','2026-09-11','cash_date','2026-09-11','memo','H3e',
      'transactions', jsonb_build_array(
        jsonb_build_object('owner_id', %L, 'counter_owner_id', %L, 'intercompany_nature','loan',
          'lines', jsonb_build_array(
            jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',500,'credit',0),
            jsonb_build_object('coa_code','4200','debit',0,'credit',500))),
        jsonb_build_object('owner_id', %L, 'counter_owner_id', %L, 'intercompany_nature','loan',
          'lines', jsonb_build_array(
            jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0002','debit',500,'credit',0),
            jsonb_build_object('coa_code','2310','debit',0,'credit',500))))))
  $q$, v_t, v_s, v_s, v_t), 'ตารางกฎ');

  reset role;
  select count(*) into v_n from sri_os.transactions where memo like 'H3%';
  set local role authenticated;
  if v_n <> 0 then raise exception 'FAIL: เคส H3 ที่ถูกปฏิเสธทิ้งรายการไว้ % แถว', v_n; end if;
  raise notice 'ok H3 · คู่บัญชีที่ไม่ตรงตารางกฎถูกปฏิเสธทุกทิศ (เงินกู้↔รายได้ · ปันผล↔ค่าใช้จ่าย · บัญชีกำไรข้ามหมวด · ขาข้ามผู้ถือ)';
end $$;

-- ============================================================
-- H4 · ข้อ 4 ของผู้ตรวจ — กันกดซ้ำหลุดด้วย "รูป" ของค่าเดียวกัน
--      12000 vs 12000.0 เคยลงสองใบ · ไล่รูปอื่นให้ครบด้วย
-- ============================================================
do $$
declare
  v_first jsonb; v_n int;
  v_forms text[] := array['12000', '12000.0', '12000.00', '1.2e4', '0.12e5'];
  f text;
begin
  v_first := sri_os.fn_post_entry(pg_temp.rent('H4', '12000'));
  if (v_first ->> 'replayed')::boolean then raise exception 'FAIL: ใบแรกไม่ควรเป็น replay'; end if;

  foreach f in array v_forms loop
    if not (sri_os.fn_post_entry(pg_temp.rent('H4', f)) ->> 'replayed')::boolean then
      raise exception 'FAIL: ยอดรูป "%" ถูกมองเป็นคำขอใหม่ → กดซ้ำได้สองใบ', f;
    end if;
  end loop;

  -- ช่องว่าง + ลำดับคีย์ (jsonb ทำให้เท่ากันอยู่แล้ว · ตรวจไว้กันการถอยหลัง)
  if not (sri_os.fn_post_entry(((pg_temp.rent('H4', '12000')::text) || '   ')::jsonb) ->> 'replayed')::boolean then
    raise exception 'FAIL: ช่องว่างท้าย payload ทำให้กันกดซ้ำหลุด';
  end if;

  -- null vs ไม่ส่งคีย์ · สตริงว่าง vs ไม่ส่งคีย์ (ฟังก์ชันอ่านด้วย nullif(x,'') อยู่แล้ว)
  if not (sri_os.fn_post_entry(pg_temp.rent('H4', '12000') || '{"doc_no":null}'::jsonb) ->> 'replayed')::boolean then
    raise exception 'FAIL: doc_no = null ถูกมองเป็นคำขอใหม่ (ควรเท่ากับไม่ส่งคีย์)';
  end if;
  if not (sri_os.fn_post_entry(pg_temp.rent('H4', '12000') || '{"doc_no":""}'::jsonb) ->> 'replayed')::boolean then
    raise exception 'FAIL: doc_no = "" ถูกมองเป็นคำขอใหม่ (ควรเท่ากับไม่ส่งคีย์)';
  end if;

  -- uuid ตัวใหญ่/ตัวเล็ก = บัญชีเดียวกันจริงๆ
  if not (sri_os.fn_post_entry(
            (replace(pg_temp.rent('H4', '12000')::text,
                     '0000000d0001', '0000000D0001'))::jsonb) ->> 'replayed')::boolean then
    raise exception 'FAIL: uuid ตัวใหญ่ถูกมองเป็นคำขอใหม่ → กดซ้ำได้สองใบ';
  end if;

  -- วันที่รูปต่างกันแต่วันเดียวกัน
  if not (sri_os.fn_post_entry(
            (replace(pg_temp.rent('H4', '12000')::text,
                     '"2026-09-01"', '"2026-9-1"'))::jsonb) ->> 'replayed')::boolean then
    raise exception 'FAIL: วันที่รูป 2026-9-1 ถูกมองเป็นคำขอใหม่';
  end if;

  -- source ที่ไม่ส่ง = 'manual' เท่ากัน
  if not (sri_os.fn_post_entry(pg_temp.rent('H4', '12000') || '{"source":"manual"}'::jsonb) ->> 'replayed')::boolean then
    raise exception 'FAIL: source = manual (ค่าปริยาย) ถูกมองเป็นคำขอใหม่';
  end if;

  reset role;
  select count(*) into v_n from sri_os.transactions where memo = 'H4';
  set local role authenticated;
  if v_n <> 1 then raise exception 'FAIL: รูปต่างๆ ของคำขอเดียวกันลงไป % ใบ (ต้อง 1)', v_n; end if;

  -- **ต้องไม่กันแน่นเกินไป**: คำขอที่ต่างกันจริงต้องยังลงได้
  if (sri_os.fn_post_entry(pg_temp.rent('H4', '12001')) ->> 'replayed')::boolean then
    raise exception 'FAIL: ยอดต่างกันจริง (12001) ถูกมองเป็นกดซ้ำ → ใบที่สองหายเงียบๆ';
  end if;
  if (sri_os.fn_post_entry(pg_temp.rent('H4 ใบที่สอง', '12000')) ->> 'replayed')::boolean then
    raise exception 'FAIL: memo ต่างกันถูกมองเป็นกดซ้ำ';
  end if;
  raise notice 'ok H4 · 12000 · 12000.0 · 12000.00 · 1.2e4 · 0.12e5 · ช่องว่าง · null/"" · uuid ตัวใหญ่ · วันที่ย่อ · source ปริยาย = ใบเดียว · ของที่ต่างจริงยังลงได้';
end $$;

-- H4b · fn_canonical_payload ต้องไม่ "รวม" ของที่ต่างกันจริง (ตรวจตรงๆ ที่ฟังก์ชัน)
do $$ begin
  if sri_os.fn_canonical_payload('{"a":1}'::jsonb) = sri_os.fn_canonical_payload('{"a":2}'::jsonb)
     or sri_os.fn_canonical_payload('[1,2]'::jsonb) = sri_os.fn_canonical_payload('[2,1]'::jsonb)
     or sri_os.fn_canonical_payload('{"a":{"b":1}}'::jsonb) = sri_os.fn_canonical_payload('{"a":{"c":1}}'::jsonb) then
    raise exception 'FAIL: fn_canonical_payload รวมคำขอที่ต่างกันจริงเข้าด้วยกัน';
  end if;
  if sri_os.fn_canonical_payload('{"a":true}'::jsonb) is distinct from sri_os.fn_canonical_payload('{"a":"true"}'::jsonb) then
    raise exception 'FAIL: true กับ "true" ลงค่าเดียวกันแต่ fingerprint ต่างกัน';
  end if;
  if sri_os.fn_canonical_payload(null) is not null then
    raise exception 'FAIL: canonical ของ null ต้องเป็น null (เคสไม่ส่งข้อมูล)';
  end if;
  raise notice 'ok H4b · canonical แยกของที่ต่างจริง · รวมของที่เหมือนจริง · ไม่พังกับ null';
end $$;

-- ============================================================
-- H5 · ข้อ 5 ของผู้ตรวจ — created_by ปลอมได้
-- ============================================================
select pg_temp.login('mgmt');
do $$
declare
  v_corp uuid := (select id from sri_os.owners where code='SRI_CORP');
  v_txn  uuid := gen_random_uuid();
  v_who  uuid;
begin
  -- หัวรายการ + บรรทัด สองคำสั่งในธุรกรรมเดียว (เคส A13b ของผู้ตรวจ)
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, cash_date, memo,
                                  attachments, contact_id, created_by)
  values (v_txn, v_corp, 'inc.rent', '2026-09-12', '2026-09-12', 'H5',
          array['slip.pdf'], '00000000-0000-0000-0000-0000000e0001', pg_temp.uid('victim'));
  insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id, debit, credit)
  values (v_txn, (select id from sri_os.chart_of_accounts where code='1100'),
          '00000000-0000-0000-0000-0000000d0003', 1000, 0),
         (v_txn, (select id from sri_os.chart_of_accounts where code='4200'), null, 0, 1000);
  -- ยิงด่านที่เลื่อนไว้ให้ทำงานตอนนี้ แล้ว **คืนสภาพ deferred** เหมือนที่ fn_post_entry ทำ
  -- (ถ้าไม่คืน เคสถัดไปจะโดน trg_txn_needs_lines ตอน INSERT หัวรายการ ทั้งที่ยังไม่ลงบรรทัด)
  set constraints all immediate;
  set constraints all deferred;

  select created_by into v_who from sri_os.transactions where id = v_txn;
  if v_who <> pg_temp.uid('mgmt') then
    raise exception 'FAIL: created_by = % (ควรเป็นคนที่ล็อกอินอยู่) → ปลอมคนคีย์ได้', v_who;
  end if;

  raise notice 'ok H5 · created_by = ผู้ที่ล็อกอินอยู่ ไม่ใช่ค่าที่ส่งมา (ปลอมตอน INSERT สองคำสั่งไม่ได้)';
end $$;

-- H5b · แก้ย้อนหลังด้วย UPDATE ก็ไม่ได้
--       ใช้รายการของ **บุคคล** โดยตั้งใจ: รายการของนิติบุคคลที่ post แล้วแก้ไม่ได้อยู่แล้ว
--       (trg_corporate_immutable) → ถ้าทดสอบกับนิติบุคคล เคสนี้จะผ่านฟรีๆ โดยไม่ได้แตะด่านนี้เลย
--       จึงต้องยืนยันว่า UPDATE **สำเร็จจริง 1 แถว** ด้วย ไม่ใช่ผ่านเพราะไม่มีอะไรเกิดขึ้น
do $$
declare
  v_t   uuid := (select id from sri_os.owners where code='THANAKORN');
  v_out jsonb; v_id uuid; v_n int; v_who uuid;
begin
  v_out := sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','inc.rent','doc_date','2026-09-12','cash_date','2026-09-12','memo','H5b',
    'transactions', jsonb_build_array(jsonb_build_object('owner_id', v_t,
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',100,'credit',0,'cf_category','operating'),
        jsonb_build_object('coa_code','4200','debit',0,'credit',100,'cf_category','operating'))))));
  v_id := ((v_out -> 'transaction_ids') ->> 0)::uuid;

  update sri_os.transactions set created_by = pg_temp.uid('victim') where id = v_id;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'FAIL: H5b UPDATE ไม่ได้แตะแถวเลย (% แถว) → เคสนี้ไม่ได้ทดสอบด่าน created_by', v_n;
  end if;

  select created_by into v_who from sri_os.transactions where id = v_id;
  if v_who <> pg_temp.uid('mgmt') then
    raise exception 'FAIL: created_by ถูกแก้ย้อนหลังเป็น %', v_who;
  end if;
  raise notice 'ok H5b · UPDATE แตะแถวได้จริง (1 แถว) แต่ created_by ถูก pin ไว้ที่คนคีย์เดิม';
end $$;

-- ============================================================
-- H7 · ข้อ 7 ของผู้ตรวจ — bank_account_id ติดได้เฉพาะบรรทัดเงินสด 11xx
-- ============================================================
select pg_temp.login('mgr');
do $$
declare v_t uuid := (select id from sri_os.owners where code='THANAKORN'); v_n int;
begin
  -- (ก) ผูกบัญชีไว้กับบรรทัดรายได้ (เคส A7 ของผู้ตรวจ)
  perform pg_temp.must_fail_like('H7a bank_account บนบรรทัดรายได้', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code','inc.rent','doc_date','2026-09-13','memo','H7a',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1200','debit',500,'credit',0,'cf_category','none'),
          jsonb_build_object('coa_code','4200','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',0,'credit',500,'cf_category','none'))))))
  $q$, v_t), 'ขาเงินสด');

  -- (ข) ค้างรับที่แนบบัญชีของผู้ถืออื่นมาด้วย — ต้องถูกปฏิเสธ (ไม่ใช่เก็บไว้เงียบๆ
  --     แล้วไปโผล่ตอนยืนยันเงินเข้าในบัญชีของคนอื่น)
  perform pg_temp.must_fail('H7b ค้างรับแนบบัญชีของผู้ถืออื่น', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code','inc.rent','doc_date','2026-09-13','memo','H7b',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1200','bank_account_id','00000000-0000-0000-0000-0000000d0003','debit',500,'credit',0,'cf_category','none'),
          jsonb_build_object('coa_code','4200','debit',0,'credit',500,'cf_category','none'))))))
  $q$, v_t));

  reset role;
  select count(*) into v_n from sri_os.transactions where memo like 'H7%';
  set local role authenticated;
  if v_n <> 0 then raise exception 'FAIL: เคส H7 ที่ถูกปฏิเสธทิ้งรายการไว้ % แถว', v_n; end if;
  raise notice 'ok H7 · bank_account_id ติดได้เฉพาะขาเงินสด 11xx · ค้างรับที่แนบบัญชีมาด้วยถูกปฏิเสธ';
end $$;

-- ============================================================
-- H8 · **เส้นทางที่ถูกต้องต้องยังทำได้** — กันแน่นเกินจนใช้งานไม่ได้ก็คือพัง
-- ============================================================
do $$
declare
  v_t uuid := (select id from sri_os.owners where code='THANAKORN');
  v_s uuid := (select id from sri_os.owners where code='SUTEE');
  v_corp uuid := (select id from sri_os.owners where code='SRI_CORP');
  v_out jsonb; v_ids uuid[]; v_src uuid; v_n int;
begin
  -- (ก) รายการปกติ
  v_out := sri_os.fn_post_entry(pg_temp.rent('H8 ปกติ'));
  v_src := ((v_out -> 'transaction_ids') ->> 0)::uuid;
  if (v_out ->> 'replayed')::boolean then raise exception 'FAIL: รายการปกติถูกมองเป็น replay'; end if;

  -- (ข) ค้างรับ (ไม่มีขาเงินสด ไม่มี cash_date)
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','inc.rent','doc_date','2026-09-14','memo','H8 ค้างรับ',
    'transactions', jsonb_build_array(jsonb_build_object('owner_id', v_t,
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code','1200','debit',31500,'credit',0,'cf_category','none'),
        jsonb_build_object('coa_code','4200','debit',0,'credit',31500,'cf_category','none'))))));

  -- (ค) ล้างยอดค้าง (หมวดทางล้างของตารางกฎ: inv.collect_rent 1100/1200)
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','inv.collect_rent','doc_date','2026-09-15','cash_date','2026-09-15','memo','H8 ล้างค้างรับ',
    'transactions', jsonb_build_array(jsonb_build_object('owner_id', v_t,
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',31500,'credit',0,'cf_category','operating'),
        jsonb_build_object('coa_code','1200','debit',0,'credit',31500,'cf_category','operating'))))));

  -- (ง) ข้ามผู้ถือสองขาด้วยบัญชีระหว่างกันที่เครื่องยนต์สร้างจริง (1310 ↔ 2310)
  v_out := sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','trf.internal','doc_date','2026-09-16','cash_date','2026-09-16','memo','H8 ข้ามผู้ถือ',
    'transactions', jsonb_build_array(
      jsonb_build_object('owner_id', v_t, 'counter_owner_id', v_s, 'intercompany_nature','loan',
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1310','debit',20000,'credit',0,'cf_category','investing'),
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',0,'credit',20000,'cf_category','investing'))),
      jsonb_build_object('owner_id', v_s, 'counter_owner_id', v_t, 'intercompany_nature','loan',
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0002','debit',20000,'credit',0,'cf_category','financing'),
          jsonb_build_object('coa_code','2310','debit',0,'credit',20000,'cf_category','financing'))))));
  select array_agg(x::uuid order by ord) into v_ids
    from jsonb_array_elements_text(v_out -> 'transaction_ids') with ordinality as t(x, ord);
  if cardinality(v_ids) <> 2 then
    raise exception 'FAIL: ข้ามผู้ถือต้องได้ 2 transaction แต่ได้ %', cardinality(v_ids);
  end if;

  -- (จ) เพิ่มทุนระหว่างกัน (1710 ↔ 3100) — ลักษณะอื่นของคู่บัญชีระหว่างกันต้องใช้ได้ด้วย
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','trf.internal','doc_date','2026-09-16','cash_date','2026-09-16','memo','H8 เพิ่มทุน',
    'transactions', jsonb_build_array(
      jsonb_build_object('owner_id', v_t, 'counter_owner_id', v_s, 'intercompany_nature','capital',
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1710','debit',5000,'credit',0,'cf_category','investing'),
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',0,'credit',5000,'cf_category','investing'))),
      jsonb_build_object('owner_id', v_s, 'counter_owner_id', v_t, 'intercompany_nature','capital',
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0002','debit',5000,'credit',0,'cf_category','financing'),
          jsonb_build_object('coa_code','3100','debit',0,'credit',5000,'cf_category','financing'))))));

  -- (ฉ) กลับรายการ (รหัสเดิม สลับด้าน) — ถ้าตรวจ "ขาไหนต้องเดบิต" เคสนี้จะลงไม่ได้
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','inc.rent','doc_date','2026-09-17','cash_date','2026-09-17','memo','H8 กลับรายการ',
    'source','reverse','reverses_id', v_src,
    'transactions', jsonb_build_array(jsonb_build_object('owner_id', v_t,
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code','4200','debit',12000,'credit',0,'cf_category','operating'),
        jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',0,'credit',12000,'cf_category','operating'))))));

  -- (ช) ขายทรัพย์ มีกำไร (ใช้บัญชีกำไรจากตารางกฎ)
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','inv.sell_re','doc_date','2026-09-18','cash_date','2026-09-18','memo','H8 ขายได้กำไร',
    'transactions', jsonb_build_array(jsonb_build_object('owner_id', v_t,
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',1200000,'credit',0,'cf_category','investing'),
        jsonb_build_object('coa_code','1500','debit',0,'credit',1000000,'cf_category','investing'),
        jsonb_build_object('coa_code','4300','debit',0,'credit',200000,'cf_category','none'))))));

  -- (ซ) ขายทรัพย์ ขาดทุน (บัญชีขาดทุนจากตารางกฎ)
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','inv.sell_re','doc_date','2026-09-18','cash_date','2026-09-18','memo','H8 ขายขาดทุน',
    'transactions', jsonb_build_array(jsonb_build_object('owner_id', v_t,
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',800000,'credit',0,'cf_category','investing'),
        jsonb_build_object('coa_code','5910','debit',200000,'credit',0,'cf_category','none'),
        jsonb_build_object('coa_code','1500','debit',0,'credit',1000000,'cf_category','investing'))))));

  -- (ฌ) แยกเงินต้น-ดอกเบี้ย (เงินเข้า: เงินต้น Investing · ดอกเบี้ย Operating)
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','inv.loan_back','doc_date','2026-09-19','cash_date','2026-09-19','memo','H8 รับคืนเงินต้น+ดอกเบี้ย',
    'transactions', jsonb_build_array(jsonb_build_object('owner_id', v_t,
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',10000,'credit',0,'cf_category','investing'),
        jsonb_build_object('coa_code','1300','debit',0,'credit',10000,'cf_category','investing'),
        jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',500,'credit',0,'cf_category','operating'),
        jsonb_build_object('coa_code','4120','debit',0,'credit',500,'cf_category','operating'))))));

  -- (ญ) แยกเงินต้น-ดอกเบี้ย ขาจ่าย (เงินต้นลดหนี้สิน · ดอกเบี้ยเป็นค่าใช้จ่าย)
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','fin.repay_bank','doc_date','2026-09-19','cash_date','2026-09-19','memo','H8 คืนเงินกู้',
    'transactions', jsonb_build_array(jsonb_build_object('owner_id', v_t,
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code','2410','debit',9000,'credit',0,'cf_category','financing'),
        jsonb_build_object('coa_code','5400','debit',1000,'credit',0,'cf_category','financing'),
        jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',0,'credit',10000,'cf_category','financing'))))));

  -- (ฎ) นิติบุคคล + ไฟล์แนบ + คู่ค้า (corporate_strict)
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','inc.rent','doc_date','2026-09-20','cash_date','2026-09-20','memo','H8 นิติบุคคล',
    'attachments', to_jsonb(array['slip.pdf']), 'contact_id','00000000-0000-0000-0000-0000000e0001',
    'transactions', jsonb_build_array(jsonb_build_object('owner_id', v_corp,
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0003','debit',45000,'credit',0,'cf_category','operating'),
        jsonb_build_object('coa_code','4200','debit',0,'credit',45000,'cf_category','operating'))))));

  -- ทุกใบที่ลงไว้ต้องสมดุลและมีบรรทัดครบ
  reset role;
  select count(*) into v_n from sri_os.transactions where memo like 'H8%';
  -- 13 = 11 เหตุการณ์ โดยข้ามผู้ถือสองเคสนับเป็นสองใบต่อเคส (1 transaction = 1 ผู้ถือ)
  if v_n <> 13 then raise exception 'FAIL: เส้นทางที่ถูกต้องลงได้ % ใบ (ต้อง 13)', v_n; end if;
  if exists (select 1 from sri_os.transactions t where t.memo like 'H8%'
              and ((select coalesce(sum(l.debit),0) from sri_os.transaction_lines l where l.transaction_id = t.id)
                <> (select coalesce(sum(l.credit),0) from sri_os.transaction_lines l where l.transaction_id = t.id)
               or (select count(*) from sri_os.transaction_lines l where l.transaction_id = t.id) < 2)) then
    raise exception 'FAIL: มีใบที่ไม่สมดุล/บรรทัดไม่ครบในเส้นทางที่ถูกต้อง';
  end if;
  set local role authenticated;
  raise notice 'ok H8 · ปกติ · ค้างรับ · ล้างค้าง · ข้ามผู้ถือ 2 ขา (กู้ยืม+เพิ่มทุน) · กลับรายการ · กำไร · ขาดทุน · แยกเงินต้น-ดอกเบี้ยสองทาง · นิติบุคคลแนบไฟล์ = ลงได้ครบ 13 ใบ (11 เหตุการณ์ · ข้ามผู้ถือนับสองใบ)';
end $$;

-- H8b · คู่ข้ามผู้ถือที่ไม่ได้ใช้บัญชีระหว่างกันเลย (1300/2400 แบบที่เทสต์เดิมใช้)
--       **กลับขั้ว 08/10**: เคสนี้เคยต้องลงได้ เพราะด่านเทียบได้แค่ "ประเภทบัญชี"
--       (1300 ก็เป็นสินทรัพย์เหมือน 1310) และ T4/T5 ที่ apply แล้วใช้ 1300/2400 อยู่
--       ตอนนี้ T4/T5 แก้เป็น 1310/2310 ของจริงแล้ว → 20261008000012 ล็อกเป็น **รหัสตรง**
--       จึงต้อง **ถูกปฏิเสธ** · ถ้าปล่อยไว้ งบรวมจะตัดรายการระหว่างกันไม่ลง
--       เพราะ 1300 (เงินให้กู้ยืม) ไม่ใช่บัญชีที่คู่กับ 2310 เลย
do $$
declare
  v_t uuid := (select id from sri_os.owners where code='THANAKORN');
  v_s uuid := (select id from sri_os.owners where code='SUTEE');
  v_n int;
begin
  perform pg_temp.must_fail_like('H8b ขาข้ามผู้ถือที่ไม่ใช่บัญชีระหว่างกัน', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code','trf.internal','doc_date','2026-09-21','cash_date','2026-09-21','memo','H8b',
      'transactions', jsonb_build_array(
        jsonb_build_object('owner_id', %L, 'counter_owner_id', %L, 'intercompany_nature','loan',
          'lines', jsonb_build_array(
            jsonb_build_object('coa_code','1300','debit',700,'credit',0,'cf_category','investing'),
            jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',0,'credit',700,'cf_category','investing'))),
        jsonb_build_object('owner_id', %L, 'counter_owner_id', %L, 'intercompany_nature','loan',
          'lines', jsonb_build_array(
            jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0002','debit',700,'credit',0,'cf_category','financing'),
            jsonb_build_object('coa_code','2400','debit',0,'credit',700,'cf_category','financing'))))))
  $q$, v_t, v_s, v_s, v_t), 'ตารางกฎ');

  reset role;
  select count(*) into v_n from sri_os.transactions where memo = 'H8b';
  set local role authenticated;
  if v_n <> 0 then raise exception 'FAIL: H8b ที่ถูกปฏิเสธทิ้งรายการไว้ % แถว', v_n; end if;
  raise notice 'ok H8b · ขาข้ามผู้ถือที่ใช้แค่ "บัญชีประเภทเดียวกัน" (1300/2400) ถูกปฏิเสธแล้ว — ล็อกเป็นรหัสตรง 1310/2310 ที่ trg_lines_rule_coa';
end $$;

-- ============================================================
-- H9 · เคส "ไม่ส่งข้อมูล" ของกฎใหม่ทุกข้อ
--      (บทเรียนข้อ 3: เทสต์ที่ส่งข้อมูลครบเสมอ จะไม่มีวันแตะเส้นทางที่ข้อมูลขาด)
-- ============================================================
do $$
declare v_t uuid := (select id from sri_os.owners where code='THANAKORN');
begin
  -- ไม่ส่ง payload เลย
  perform pg_temp.must_fail_like('H9a null payload',
    'select sri_os.fn_post_entry(null::jsonb)', 'ไม่ได้ส่งข้อมูล');
  perform pg_temp.must_fail_like('H9b jsonb null',
    $q$ select sri_os.fn_post_entry('null'::jsonb) $q$, 'ไม่ได้ส่งข้อมูล');

  -- ข้ามผู้ถือที่ส่งมาครึ่งเดียว
  perform pg_temp.must_fail_like('H9c มี counter แต่ไม่มีลักษณะ', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code','trf.internal','doc_date','2026-09-24','cash_date','2026-09-24',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L, 'counter_owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1310','debit',100,'credit',0),
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',0,'credit',100))))))
  $q$, v_t, (select id from sri_os.owners where code='SUTEE')), 'ลักษณะ');

  perform pg_temp.must_fail_like('H9d มีลักษณะแต่ไม่มี counter', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code','trf.internal','doc_date','2026-09-24','cash_date','2026-09-24',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L, 'intercompany_nature','loan',
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1310','debit',100,'credit',0),
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',0,'credit',100))))))
  $q$, v_t), 'counter_owner_id');

  -- ลักษณะที่ตารางกฎไม่รู้จัก (ไม่ใช่ 4 ตัวที่มี) → ปฏิเสธ ไม่ใช่ตกไปเส้นทางปกติ
  perform pg_temp.must_fail('H9e ลักษณะที่ไม่รู้จัก', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code','trf.internal','doc_date','2026-09-24','cash_date','2026-09-24',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L, 'counter_owner_id', %L,
        'intercompany_nature','ของแถม',
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1310','debit',100,'credit',0),
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000d0001','debit',0,'credit',100))))))
  $q$, v_t, (select id from sri_os.owners where code='SUTEE')));

  -- วันที่ที่อ่านไม่ได้ ต้องได้ข้อความภาษาคน ไม่ใช่ error ดิบของการ cast
  perform pg_temp.must_fail_like('H9f doc_date อ่านไม่ได้',
    $q$ select sri_os.fn_post_entry(
          (replace(pg_temp.rent('H9f')::text, '"2026-09-01"', '"ไม่ใช่วันที่"'))::jsonb) $q$,
    'doc_date');

  raise notice 'ok H9 · ไม่ส่ง payload · ข้ามผู้ถือมาครึ่งเดียว · ลักษณะที่ไม่รู้จัก · วันที่อ่านไม่ได้ → ปฏิเสธพร้อมข้อความที่ชี้จุด';
end $$;

-- ============================================================
-- H10 · สิ่งที่ยัง **ไม่** ปิด — ประกาศออกมา ไม่ซ่อนไว้ในคอมเมนต์
--       (ถ้าวันหนึ่งปิดได้ ให้ย้ายขึ้นมาเป็นเคสจริง)
-- ============================================================
do $$ begin
  -- (1) และ (2) **ปิดแล้ว 08/10** ด้วย 20261008000012 (เทสต์อยู่ใน zz_line_guards_test.sql)
  --     เหลือไว้เป็นบันทึกว่าเคยเปิดอยู่และปิดด้วยอะไร ไม่ใช่ลบทิ้งแล้วลืม
  raise notice 'ok H10 · ที่ยังไม่ปิด: (1) D-095 ไฟล์แนบยังเป็นชื่อไฟล์ลอยๆ ตามที่ decision นั้นตั้งใจ · ปิดแล้ว: ด่าน "คู่บัญชีตรงตารางกฎ" + "bank เฉพาะขาเงินสด" เป็น trigger แล้ว (INSERT ตรงก็ถูกกัน) และขาข้ามผู้ถือล็อกเป็นรหัสตรง — ดู supabase/tests/zz_line_guards_test.sql';
end $$;

reset role;

do $$ begin raise notice '=== fn_post_entry hardening ผ่านทั้งหมด ==='; end $$;

rollback;
