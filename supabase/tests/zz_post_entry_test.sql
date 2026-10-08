-- ============================================================
-- SRI OS · เทสต์ fn_post_entry() — RPC ที่เขียนผล buildPosting() ลง ledger จริง
--   (migration 20261008000008_post_entry_rpc.sql)
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ **rollback** ปิดท้าย
--   ต่างจาก zz_line_integrity_test.sql ที่ต้อง commit เพื่อพิสูจน์ "ต่างธุรกรรม"
--   ไฟล์นี้พิสูจน์สิ่งตรงข้าม: หัวรายการ + บรรทัด ลงใน **ธุรกรรมเดียวกัน** ได้จริง
--   ซึ่งทดสอบในธุรกรรมเดียวได้ และต้องไม่ทิ้งรายการเงินปลอมไว้ใน DB
--
-- ทุกเคสที่ตรวจสิทธิ์/RLS รันด้วย `set local role authenticated` + GUC test.uid
--   เพราะ superuser ข้าม RLS → ถ้าลืม จะกลายเป็นเทสต์ที่ไม่ได้ตรวจอะไร (เทสต์ T0f กันไว้)
--
-- หมายเหตุเรื่องเวลา: now() คงที่ทั้งธุรกรรม → เคสที่ต้อง "พ้นหน้าต่างกันกดซ้ำ"
--   ทำด้วยการย้อน created_at ของแถว fingerprint ในฐานะ superuser (ดู T17c)
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
create temporary table t_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_uid(label) values ('super'), ('mgmt'), ('mgr'), ('staff'), ('ghost'), ('dead');
insert into auth.users(id) select id from t_uid;

insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, u.label || '@post.local', u.label, x.role, x.active
  from t_uid u
  join (values
    ('super', 'super_admin', true),
    ('mgmt',  'management',  true),
    ('mgr',   'manager',     true),
    ('staff', 'staff',       true),
    ('dead',  'manager',     false)     -- 'ghost' ไม่มีแถวใน app_users โดยตั้งใจ
  ) as x(label, role, active) on x.label = u.label;

create or replace function pg_temp.uid(p_label text) returns uuid
language sql stable as $fn$ select id from t_uid where label = p_label $fn$;

create or replace function pg_temp.login(p_label text) returns void
language sql as $fn$
  select set_config('test.uid', coalesce((select id::text from t_uid where label = p_label), ''), true);
$fn$;

-- ขอบเขต owner ของ mgr: เห็น ธนากร + สุธี แต่ **ไม่เห็น เบ็ญจพร** (ใช้ในเคส T16)
insert into sri_os.user_owner_access(user_id, owner_id)
select pg_temp.uid('mgr'), o.id from sri_os.owners o
 where o.code in ('THANAKORN', 'SUTEE', 'SRI_CORP');
insert into sri_os.user_owner_access(user_id, owner_id)
select pg_temp.uid('staff'), o.id from sri_os.owners o where o.code = 'THANAKORN';

-- บัญชีธนาคาร: เปิด 3 บัญชี (ธนากร · สุธี · SRI Corp) + ปิด 1 บัญชี (ธนากร)
insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name, is_active)
values
  ('00000000-0000-0000-0000-0000000b0001', (select id from sri_os.owners where code='THANAKORN'),
   'BBL', 'ธนากร', 'ธนากร - BBL 888', true),
  ('00000000-0000-0000-0000-0000000b0002', (select id from sri_os.owners where code='SUTEE'),
   'KBANK', 'สุธี', 'สุธี - KBANK 111', true),
  ('00000000-0000-0000-0000-0000000b0003', (select id from sri_os.owners where code='SRI_CORP'),
   'SCB', 'SRI Corporation', 'SRI - SCB 222', true),
  ('00000000-0000-0000-0000-0000000b0009', (select id from sri_os.owners where code='THANAKORN'),
   'TTB', 'ธนากร (ปิดแล้ว)', 'ธนากร - TTB ปิดแล้ว', false);

insert into sri_os.contacts(id, first_name, types)
values ('00000000-0000-0000-0000-0000000c0001', 'ผู้เช่าตัวอย่าง', array['tenant']);

-- ตัวช่วย
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

-- ปฏิเสธ **และ** ข้อความต้องมีคำที่ผู้ใช้อ่านรู้เรื่อง (ไม่ใช่ error ดิบจาก Postgres)
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

-- payload มาตรฐานของรายการค่าเช่าหนึ่งใบ (ธนากร · personal_flexible)
create or replace function pg_temp.rent_payload(p_memo text default 'ค่าเช่า ก.ย.')
returns jsonb language sql stable as $fn$
  select jsonb_build_object(
    'txn_type_code', 'inc.rent',
    'doc_date', '2026-09-01',
    'cash_date', '2026-09-03',
    'memo', p_memo,
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', (select id from sri_os.owners where code = 'THANAKORN'),
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code', '1100', 'bank_account_id',
                           '00000000-0000-0000-0000-0000000b0001',
                           'debit', 12000, 'credit', 0, 'cf_category', 'operating'),
        jsonb_build_object('coa_code', '4200', 'debit', 0, 'credit', 12000,
                           'cf_category', 'operating')
      )
    ))
  );
$fn$;

-- role authenticated ต้องเรียกตัวช่วยใน temp schema ได้
do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.t_uid to authenticated', s);
end $$;

-- ============================================================
-- T0 · โครงสร้าง — ไล่จาก catalog จริง ไม่ใช่ไล่ไฟล์
-- ============================================================
do $$
declare v text; n int;
begin
  -- T0a ฟังก์ชันมีจริงและ **ไม่ใช่ SECURITY DEFINER** (definer = ทางข้าม RLS)
  if to_regprocedure('sri_os.fn_post_entry(jsonb)') is null then
    raise exception 'FAIL: ไม่มีฟังก์ชัน sri_os.fn_post_entry(jsonb)';
  end if;
  if (select p.prosecdef from pg_proc p where p.oid = 'sri_os.fn_post_entry(jsonb)'::regprocedure) then
    raise exception 'FAIL: fn_post_entry เป็น SECURITY DEFINER = ประตูหลังข้าม RLS ต้องเป็น invoker';
  end if;
  -- T0b ACL: authenticated เรียกได้ · public/anon เรียกไม่ได้
  if not has_function_privilege('authenticated', 'sri_os.fn_post_entry(jsonb)', 'execute') then
    raise exception 'FAIL: authenticated เรียก fn_post_entry ไม่ได้ → หน้าจอใช้ไม่ได้';
  end if;
  if has_function_privilege('public', 'sri_os.fn_post_entry(jsonb)', 'execute')
     or has_function_privilege('anon', 'sri_os.fn_post_entry(jsonb)', 'execute') then
    raise exception 'FAIL: public/anon เรียก fn_post_entry ได้';
  end if;
  -- T0c trigger function กันบัญชีปิด ต้องเรียกตรงไม่ได้ และต้องไม่ถามสิทธิ์
  if has_function_privilege('public', 'sri_os.fn_assert_bank_account_open()', 'execute')
     or has_function_privilege('authenticated', 'sri_os.fn_assert_bank_account_open()', 'execute') then
    raise exception 'FAIL: fn_assert_bank_account_open เรียกตรงได้';
  end if;
  select p.prosrc into v from pg_proc p where p.oid = 'sri_os.fn_assert_bank_account_open()'::regprocedure;
  if v ~* 'fn_can' then
    raise exception 'FAIL: trigger กันบัญชีปิดเรียก fn_can → ปิดกฎได้จากหน้า Settings';
  end if;
  -- T0d trigger ผูกกับ transaction_lines จริง
  if not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                  where tg.tgrelid = 'sri_os.transaction_lines'::regclass
                    and p.proname = 'fn_assert_bank_account_open'
                    and (tg.tgtype & 4) <> 0 and (tg.tgtype & 2) <> 0) then
    raise exception 'FAIL: ไม่มี trigger before insert กันบัญชีปิดบน transaction_lines';
  end if;
  -- T0e ตาราง fingerprint: RLS เปิด + audit ครบสามคำสั่ง + ไม่มี policy DELETE
  if not (select c.relrowsecurity from pg_class c
           where c.oid = 'sri_os.post_entry_requests'::regclass) then
    raise exception 'FAIL: post_entry_requests ไม่ได้เปิด RLS';
  end if;
  if not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                  where tg.tgrelid = 'sri_os.post_entry_requests'::regclass
                    and p.proname in ('fn_audit', 'fn_audit_keyed')
                    and (tg.tgtype & 4) <> 0 and (tg.tgtype & 16) <> 0 and (tg.tgtype & 8) <> 0
                    and (tg.tgtype & 2) = 0 and (tg.tgtype & 1) <> 0) then
    raise exception 'FAIL: post_entry_requests ไม่มี audit ครอบ insert+update+delete (เทสต์ X9 จะแดงด้วย)';
  end if;
  select string_agg(policyname || ' (' || cmd || ')', ', ') into v from pg_policies
   where schemaname = 'sri_os' and tablename = 'post_entry_requests' and cmd in ('DELETE', 'ALL');
  if v is not null then
    raise exception 'FAIL: post_entry_requests มี policy ที่ลบ/กว้างเกินไป: %', v;
  end if;
  select count(*) into n from pg_policies
   where schemaname = 'sri_os' and tablename = 'post_entry_requests';
  if n < 3 then
    raise exception 'FAIL: post_entry_requests มี policy แค่ % ตัว (ต้องมี select/insert/update)', n;
  end if;
  -- TRUNCATE ล้างทั้งตารางได้ในคำสั่งเดียวโดยไม่ยิง row trigger = ล้างการกันซ้ำทั้งหมด
  -- (เทสต์ H8 ของ zz_history_guards ก็จับ แต่ไฟล์นี้ต้องยืนได้ด้วยตัวเอง)
  if not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                  where tg.tgrelid = 'sri_os.post_entry_requests'::regclass
                    and p.proname = 'fn_forbid_truncate' and (tg.tgtype & 32) <> 0) then
    raise exception 'FAIL: post_entry_requests ไม่มี trigger กัน TRUNCATE';
  end if;
  -- ชั้น GRANT ต้องครบสี่ (RLS เป็นด่านเดียว) และต้องไม่มี TRUNCATE
  select count(*) into n from information_schema.role_table_grants g
   where g.table_schema = 'sri_os' and g.table_name = 'post_entry_requests'
     and g.grantee = 'authenticated'
     and g.privilege_type in ('SELECT', 'INSERT', 'UPDATE', 'DELETE');
  if n <> 4 then
    raise exception 'FAIL: authenticated ต้องมี DML ครบสี่ตัวบน post_entry_requests (ได้ %)', n;
  end if;
  if has_table_privilege('authenticated', 'sri_os.post_entry_requests', 'truncate') then
    raise exception 'FAIL: authenticated มีสิทธิ์ TRUNCATE บน post_entry_requests';
  end if;
  raise notice 'ok T0 · fn_post_entry เป็น invoker · ACL แคบ · trigger บัญชีปิดผูกแล้ว · ตาราง fingerprint มี RLS+audit';
end $$;

-- T0f · กันเทสต์ที่ไม่ได้ตรวจอะไร: ต้องพิสูจน์ว่า role authenticated **ไม่ข้าม RLS**
set local role authenticated;
select pg_temp.login('ghost');
do $$
declare n int;
begin
  select count(*) into n from sri_os.transactions;
  if n <> 0 then
    raise exception 'FAIL: ghost (ไม่มีแถวใน app_users) อ่าน transactions ได้ % แถว → RLS ไม่ทำงานในเทสต์นี้', n;
  end if;
  raise notice 'ok T0f · session ของเทสต์อยู่ใต้ RLS จริง (ghost เห็น 0 แถว)';
end $$;
reset role;

-- ============================================================
-- T1 · รายรับปกติ → หัวรายการ 1 + บรรทัด 2 สมดุล · อ่านกลับได้
-- ============================================================
set local role authenticated;
select pg_temp.login('mgr');
do $$
declare
  v_out jsonb;
  v_ids uuid[];
  v_id  uuid;
  v_dr numeric; v_cr numeric; v_n int;
  v_row sri_os.transactions;
begin
  v_out := sri_os.fn_post_entry(pg_temp.rent_payload());
  if v_out is null then raise exception 'FAIL: fn_post_entry คืน null'; end if;
  if (v_out ->> 'replayed')::boolean then raise exception 'FAIL: ครั้งแรกไม่ควรเป็น replay'; end if;
  select array_agg(x::uuid) into v_ids
    from jsonb_array_elements_text(v_out -> 'transaction_ids') x;
  if cardinality(v_ids) <> 1 then
    raise exception 'FAIL: ต้องได้ 1 รายการ แต่ได้ %', cardinality(v_ids);
  end if;
  v_id := v_ids[1];

  -- อ่านกลับมาได้ด้วยสิทธิ์ของคนที่ลงเอง (RETURNING/SELECT ต้องผ่าน policy)
  select * into v_row from sri_os.transactions where id = v_id;
  if not found then raise exception 'FAIL: อ่านรายการที่เพิ่งลงไม่เจอ'; end if;
  if v_row.owner_id <> (select id from sri_os.owners where code='THANAKORN') then
    raise exception 'FAIL: owner_id ผิด';
  end if;
  if v_row.txn_type_code <> 'inc.rent' then raise exception 'FAIL: txn_type_code ผิด'; end if;
  if v_row.doc_date <> '2026-09-01'::date or v_row.cash_date <> '2026-09-03'::date then
    raise exception 'FAIL: วันที่ผิด (doc % cash %)', v_row.doc_date, v_row.cash_date;
  end if;
  if v_row.created_by <> pg_temp.uid('mgr') then
    raise exception 'FAIL: created_by ต้องเป็น auth.uid() ของคนที่กด แต่ได้ %', v_row.created_by;
  end if;
  if v_row.status <> 'posted' then raise exception 'FAIL: status ต้องเป็น posted'; end if;
  if v_row.is_intercompany then raise exception 'FAIL: รายการธรรมดาไม่ใช่ intercompany'; end if;

  select coalesce(sum(debit),0), coalesce(sum(credit),0), count(*) into v_dr, v_cr, v_n
    from sri_os.transaction_lines where transaction_id = v_id;
  if v_n <> 2 then raise exception 'FAIL: ต้องมี 2 บรรทัด แต่ได้ %', v_n; end if;
  if v_dr <> 12000 or v_cr <> 12000 then
    raise exception 'FAIL: บรรทัดไม่สมดุล/ยอดผิด (dr % cr %)', v_dr, v_cr;
  end if;
  -- บรรทัดเงินสดต้องผูกบัญชีจริง และหมวดกระแสเงินสดต้องมาตามที่เครื่องยนต์ส่ง
  if not exists (select 1 from sri_os.transaction_lines l
                  join sri_os.chart_of_accounts c on c.id = l.coa_id
                 where l.transaction_id = v_id and c.code = '1100'
                   and l.bank_account_id = '00000000-0000-0000-0000-0000000b0001'
                   and l.cf_category = 'operating' and l.debit = 12000) then
    raise exception 'FAIL: บรรทัดเงินสดไม่ตรงกับที่ส่งมา (บัญชี/หมวด CF/ยอด)';
  end if;
  if not exists (select 1 from sri_os.transaction_lines l
                  join sri_os.chart_of_accounts c on c.id = l.coa_id
                 where l.transaction_id = v_id and c.code = '4200' and l.credit = 12000) then
    raise exception 'FAIL: บรรทัดรายได้ไม่ตรงกับที่ส่งมา';
  end if;
  -- memo ของหัวรายการ
  if v_row.memo is null then raise exception 'FAIL: memo หาย'; end if;
  raise notice 'ok T1 · รายรับปกติ: หัวรายการ 1 + บรรทัด 2 สมดุล · อ่านกลับได้ · created_by = ผู้กด';
end $$;

-- ============================================================
-- T2 · รายจ่ายปกติ (ไม่ผูกคู่ค้า ไม่ผูกทรัพย์) → ลงได้
-- ============================================================
do $$
declare v_out jsonb; v_id uuid; v_n int;
begin
  v_out := sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code', 'exp.common',
    'doc_date', '2026-09-05',
    'cash_date', '2026-09-05',
    'doc_no', 'CM-2026-09',
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', (select id from sri_os.owners where code='THANAKORN'),
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code','5100','debit',9800,'credit',0,'cf_category','operating'),
        jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000b0001',
                           'debit',0,'credit',9800,'cf_category','operating')
      )))));
  v_id := ((v_out -> 'transaction_ids') ->> 0)::uuid;
  select count(*) into v_n from sri_os.transaction_lines where transaction_id = v_id;
  if v_n <> 2 then raise exception 'FAIL: รายจ่ายควรมี 2 บรรทัด ได้ %', v_n; end if;
  if (select doc_no from sri_os.transactions where id = v_id) <> 'CM-2026-09' then
    raise exception 'FAIL: doc_no ไม่ถูกเก็บ';
  end if;
  raise notice 'ok T2 · รายจ่ายปกติลงได้ · doc_no เก็บครบ';
end $$;

-- ============================================================
-- T3 · ค้างรับ — ไม่มีบรรทัดเงินสด ไม่มีบัญชีธนาคาร cash_date ว่าง → ลงได้
-- ============================================================
do $$
declare v_out jsonb; v_id uuid; v_row sri_os.transactions; v_n int;
begin
  v_out := sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code', 'inc.rent',
    'doc_date', '2026-09-04',
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', (select id from sri_os.owners where code='THANAKORN'),
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code','1200','debit',31500,'credit',0,'cf_category','none'),
        jsonb_build_object('coa_code','4200','debit',0,'credit',31500,'cf_category','none')
      )))));
  v_id := ((v_out -> 'transaction_ids') ->> 0)::uuid;
  select * into v_row from sri_os.transactions where id = v_id;
  if v_row.cash_date is not null then
    raise exception 'FAIL: รายการค้างรับต้องมี cash_date = null (ไม่งั้นงบกระแสเงินสดนับเงินที่ยังไม่เคลื่อน)';
  end if;
  select count(*) into v_n from sri_os.transaction_lines
   where transaction_id = v_id and bank_account_id is not null;
  if v_n <> 0 then raise exception 'FAIL: รายการค้างรับไม่ควรมีบรรทัดผูกบัญชีธนาคาร'; end if;
  raise notice 'ok T3 · ค้างรับลงได้โดยไม่มีบรรทัดเงินสดและไม่มีบัญชีธนาคาร · cash_date ว่าง';
end $$;

-- T3b · มีบรรทัดเงินสดแต่ไม่ส่ง cash_date → ปฏิเสธ (เคส "ไม่ส่งข้อมูล")
-- T3c · ไม่มีบรรทัดเงินสดแต่ส่ง cash_date → ปฏิเสธ (CF จะนับเงินที่ยังไม่เคลื่อน)
do $$
begin
  perform pg_temp.must_fail_like('T3b ไม่ส่ง cash_date ทั้งที่มีบรรทัดเงินสด', $q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code','inc.rent','doc_date','2026-09-01',
      'transactions', jsonb_build_array(jsonb_build_object(
        'owner_id', (select id from sri_os.owners where code='THANAKORN'),
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000b0001','debit',100,'credit',0),
          jsonb_build_object('coa_code','4200','debit',0,'credit',100))))))
  $q$, 'cash_date');
  perform pg_temp.must_fail_like('T3c ส่ง cash_date ทั้งที่ไม่มีบรรทัดเงินสด', $q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code','inc.rent','doc_date','2026-09-01','cash_date','2026-09-01',
      'transactions', jsonb_build_array(jsonb_build_object(
        'owner_id', (select id from sri_os.owners where code='THANAKORN'),
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1200','debit',100,'credit',0),
          jsonb_build_object('coa_code','4200','debit',0,'credit',100))))))
  $q$, 'cash_date');
  raise notice 'ok T3b/T3c · cash_date ต้องสอดคล้องกับ "มีบรรทัดเงินสดหรือไม่" ทั้งสองทาง';
end $$;

-- ============================================================
-- T4 · ข้ามผู้ถือ → สอง transaction · ทั้งคู่สมดุลในตัวเอง
-- ============================================================
do $$
declare
  v_out jsonb; v_ids uuid[]; v_a uuid; v_b uuid;
  v_own_t uuid := (select id from sri_os.owners where code='THANAKORN');
  v_own_s uuid := (select id from sri_os.owners where code='SUTEE');
  r record;
begin
  v_out := sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','trf.internal','doc_date','2026-09-15','cash_date','2026-09-15',
    'memo','โอนให้สุธี (กู้ยืมระหว่างกัน)',
    'transactions', jsonb_build_array(
      jsonb_build_object(
        'owner_id', v_own_t, 'counter_owner_id', v_own_s, 'intercompany_nature','loan',
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1300','debit',20000,'credit',0,'cf_category','investing'),
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000b0001',
                             'debit',0,'credit',20000,'cf_category','investing'))),
      jsonb_build_object(
        'owner_id', v_own_s, 'counter_owner_id', v_own_t, 'intercompany_nature','loan',
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000b0002',
                             'debit',20000,'credit',0,'cf_category','financing'),
          jsonb_build_object('coa_code','2400','debit',0,'credit',20000,'cf_category','financing'))))));
  select array_agg(x::uuid order by ord) into v_ids
    from jsonb_array_elements_text(v_out -> 'transaction_ids') with ordinality as t(x, ord);
  if cardinality(v_ids) <> 2 then
    raise exception 'FAIL: รายการข้ามผู้ถือต้องได้ 2 transaction แต่ได้ %', cardinality(v_ids);
  end if;
  v_a := v_ids[1]; v_b := v_ids[2];
  if v_a = v_b then raise exception 'FAIL: ได้ id เดียวกันสองครั้ง'; end if;

  -- ลำดับต้องตรงกับที่ส่งมา (หน้าจอใช้ id ตัวแรกพาไปดูรายการของผู้กด)
  if (select owner_id from sri_os.transactions where id = v_a) <> v_own_t then
    raise exception 'FAIL: ลำดับ transaction_ids ไม่ตรงกับลำดับใน payload';
  end if;

  -- แต่ละขาสมดุลในตัวเอง (Money Invariant 1 ต่อ transaction ไม่ใช่ต่อคำขอ)
  for r in select t.id, t.owner_id, t.is_intercompany, t.counter_owner_id, t.intercompany_nature,
                  (select coalesce(sum(l.debit),0) from sri_os.transaction_lines l where l.transaction_id = t.id) dr,
                  (select coalesce(sum(l.credit),0) from sri_os.transaction_lines l where l.transaction_id = t.id) cr,
                  (select count(*) from sri_os.transaction_lines l where l.transaction_id = t.id) n
             from sri_os.transactions t where t.id = any(v_ids)
  loop
    if r.dr <> 20000 or r.cr <> 20000 or r.n <> 2 then
      raise exception 'FAIL: ขา % ไม่สมดุลในตัวเอง (dr % cr % บรรทัด %)', r.owner_id, r.dr, r.cr, r.n;
    end if;
    if not r.is_intercompany then
      raise exception 'FAIL: ขา % ต้องถูกตั้ง is_intercompany = true', r.owner_id;
    end if;
    if r.counter_owner_id is null or r.intercompany_nature <> 'loan' then
      raise exception 'FAIL: ขา % ไม่มีผู้ถืออีกฝ่าย/ลักษณะรายการ', r.owner_id;
    end if;
  end loop;

  -- ขาทั้งสองต้องเป็นของคนละผู้ถือ และชี้กลับหากัน
  if (select counter_owner_id from sri_os.transactions where id = v_a) <> v_own_s
     or (select counter_owner_id from sri_os.transactions where id = v_b) <> v_own_t then
    raise exception 'FAIL: counter_owner_id ของสองขาไม่ชี้กลับหากัน';
  end if;
  raise notice 'ok T4 · ข้ามผู้ถือได้สอง transaction · สมดุลแยกกัน · ลำดับ id ตรงกับ payload';
end $$;

-- ============================================================
-- T5 · ข้ามผู้ถือที่ขาหนึ่งล้ม → อีกขาต้องไม่ลง (Invariant 3)
--      ขาที่สองเป็นของ เบ็ญจพร ที่ mgr มองไม่เห็น → RLS ปฏิเสธทั้งคำขอ
-- ============================================================
do $$
declare
  v_before int; v_after int;
  v_own_t uuid := (select id from sri_os.owners where code='THANAKORN');
  v_own_x uuid := (select id from sri_os.owners where code='BENJAPORN');
begin
  select count(*) into v_before from sri_os.transactions;
  perform pg_temp.must_fail('T5 ขาที่สองอยู่นอกขอบเขต owner', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code','trf.internal','doc_date','2026-09-16','cash_date','2026-09-16',
      'transactions', jsonb_build_array(
        jsonb_build_object('owner_id', %L, 'counter_owner_id', %L, 'intercompany_nature','loan',
          'lines', jsonb_build_array(
            jsonb_build_object('coa_code','1300','debit',500,'credit',0),
            jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000b0001','debit',0,'credit',500))),
        jsonb_build_object('owner_id', %L, 'counter_owner_id', %L, 'intercompany_nature','loan',
          'lines', jsonb_build_array(
            jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000b0002','debit',500,'credit',0),
            jsonb_build_object('coa_code','2400','debit',0,'credit',500)))))
  $q$, v_own_t, v_own_x, v_own_x, v_own_t));
  select count(*) into v_after from sri_os.transactions;
  if v_after <> v_before then
    raise exception 'FAIL: ขาแรกถูกลงไว้ทั้งที่ขาที่สองล้ม (% → %) = เงินหายไปข้างหนึ่ง', v_before, v_after;
  end if;
  -- และต้องไม่มีขาแรกค้างอยู่จริงๆ (ไม่ใช่แค่ count เท่ากันเพราะมองไม่เห็น)
  if exists (select 1 from sri_os.transactions where doc_date = '2026-09-16') then
    raise exception 'FAIL: พบหัวรายการของคำขอที่ล้มค้างอยู่';
  end if;
  raise notice 'ok T5 · ขาหนึ่งล้ม = ไม่ลงทั้งคำขอ (ไม่มีขาแรกค้าง)';
end $$;

-- ============================================================
-- T6-T11 · รูปผิด / ข้อมูลไม่ครบ → ปฏิเสธทุกเคส
--   ทุกเคสในบล็อกนี้คือ "ไม่ส่งข้อมูล" หรือ "ส่งมาไม่ครบ"
--   (บทเรียนข้อ 3: เทสต์ที่ส่งข้อมูลครบเสมอจะไม่เคยแตะเส้นทางที่ข้อมูลขาด)
-- ============================================================
do $$
declare
  v_own uuid := (select id from sri_os.owners where code='THANAKORN');
  v_before int; v_after int;
begin
  select count(*) into v_before from sri_os.transactions;

  -- T6 ไม่สมดุล
  perform pg_temp.must_fail_like('T6 ไม่สมดุล', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code','inc.rent','doc_date','2026-09-01','cash_date','2026-09-01',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000b0001','debit',100,'credit',0),
          jsonb_build_object('coa_code','4200','debit',0,'credit',90))))))
  $q$, v_own), 'สมดุล');

  -- T7 บรรทัดเดียว
  perform pg_temp.must_fail_like('T7 บรรทัดเดียว', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code','inc.rent','doc_date','2026-09-01','cash_date','2026-09-01',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000b0001','debit',100,'credit',0))))))
  $q$, v_own), 'สองบรรทัด');

  -- T8 payload ว่าง/ไม่ส่ง
  perform pg_temp.must_fail_like('T8a payload null', 'select sri_os.fn_post_entry(null::jsonb)', 'ไม่ได้ส่ง');
  perform pg_temp.must_fail_like('T8b payload = {}', 'select sri_os.fn_post_entry(''{}''::jsonb)', 'txn_type_code');
  perform pg_temp.must_fail_like('T8c payload เป็น array', 'select sri_os.fn_post_entry(''[]''::jsonb)', 'รูปแบบ');
  perform pg_temp.must_fail_like('T8d payload เป็น json null', 'select sri_os.fn_post_entry(''null''::jsonb)', 'ไม่ได้ส่ง');
  perform pg_temp.must_fail_like('T8e transactions = []', $q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-01',
      'transactions', '[]'::jsonb))
  $q$, 'ไม่มีรายการ');
  perform pg_temp.must_fail_like('T8f ไม่ส่ง transactions เลย', $q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-01'))
  $q$, 'transactions');
  perform pg_temp.must_fail_like('T8g lines = []', format($q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-01',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L, 'lines', '[]'::jsonb))))
  $q$, v_own), 'สองบรรทัด');
  perform pg_temp.must_fail_like('T8h ไม่ส่ง lines เลย', format($q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-01',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L))))
  $q$, v_own), 'lines');

  -- T9 ไม่มี owner
  perform pg_temp.must_fail_like('T9a ไม่ส่ง owner_id', $q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-01',
      'transactions', jsonb_build_array(jsonb_build_object(
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1200','debit',100,'credit',0),
          jsonb_build_object('coa_code','4200','debit',0,'credit',100))))))
  $q$, 'owner_id');
  perform pg_temp.must_fail_like('T9b owner_id = null', $q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-01',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', null,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1200','debit',100,'credit',0),
          jsonb_build_object('coa_code','4200','debit',0,'credit',100))))))
  $q$, 'owner_id');

  -- T10 ช่องบังคับอื่นที่ "ไม่ส่ง"
  perform pg_temp.must_fail_like('T10a ไม่ส่ง txn_type_code', format($q$
    select sri_os.fn_post_entry(jsonb_build_object('doc_date','2026-09-01',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1200','debit',100,'credit',0),
          jsonb_build_object('coa_code','4200','debit',0,'credit',100))))))
  $q$, v_own), 'txn_type_code');
  perform pg_temp.must_fail_like('T10b ไม่ส่ง doc_date', format($q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1200','debit',100,'credit',0),
          jsonb_build_object('coa_code','4200','debit',0,'credit',100))))))
  $q$, v_own), 'doc_date');
  perform pg_temp.must_fail_like('T10c ไม่ส่ง coa_code', format($q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-01',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('debit',100,'credit',0),
          jsonb_build_object('coa_code','4200','debit',0,'credit',100))))))
  $q$, v_own), 'coa_code');
  perform pg_temp.must_fail_like('T10d ไม่ส่งทั้ง debit และ credit', format($q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-01',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1200'),
          jsonb_build_object('coa_code','4200','debit',0,'credit',100))))))
  $q$, v_own), 'เดบิต');
  perform pg_temp.must_fail_like('T10e ทั้งเดบิตและเครดิตในบรรทัดเดียว', format($q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-01',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1200','debit',100,'credit',100),
          jsonb_build_object('coa_code','4200','debit',0,'credit',100))))))
  $q$, v_own), 'ด้านเดียว');
  perform pg_temp.must_fail_like('T10f ยอดติดลบ', format($q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-01',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1200','debit',-100,'credit',0),
          jsonb_build_object('coa_code','4200','debit',0,'credit',-100))))))
  $q$, v_own), 'ติดลบ');
  perform pg_temp.must_fail_like('T10g coa_code ไม่มีในผังบัญชี', format($q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-01',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','9999','debit',100,'credit',0),
          jsonb_build_object('coa_code','4200','debit',0,'credit',100))))))
  $q$, v_own), 'ผังบัญชี');
  perform pg_temp.must_fail_like('T10h ประเภทรายการไม่มีในตารางกฎ', format($q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.ไม่มีจริง','doc_date','2026-09-01',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1200','debit',100,'credit',0),
          jsonb_build_object('coa_code','4200','debit',0,'credit',100))))))
  $q$, v_own), 'ตารางกฎ');

  -- T11 คีย์แปลกปลอม — ฟิลด์ที่ RPC ไม่รู้จักต้องพังให้เห็น ไม่ใช่ทิ้งเงียบๆ
  perform pg_temp.must_fail_like('T11a คีย์แปลกที่หัวรายการ', format($q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-01',
      'cash_date','2026-09-01','status','posted',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000b0001','debit',100,'credit',0),
          jsonb_build_object('coa_code','4200','debit',0,'credit',100))))))
  $q$, v_own), 'ไม่รู้จัก');
  perform pg_temp.must_fail_like('T11b คีย์แปลกในรายการ', format($q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-01',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L, 'ownerId', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1200','debit',100,'credit',0),
          jsonb_build_object('coa_code','4200','debit',0,'credit',100))))))
  $q$, v_own, v_own), 'ไม่รู้จัก');
  perform pg_temp.must_fail_like('T11c คีย์แปลกในบรรทัด (camelCase)', format($q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-01',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coaCode','1200','debit',100,'credit',0),
          jsonb_build_object('coa_code','4200','debit',0,'credit',100))))))
  $q$, v_own), 'ไม่รู้จัก');

  -- T11d lines ไม่ใช่ array · T11e transactions ไม่ใช่ array
  perform pg_temp.must_fail_like('T11d lines ไม่ใช่ array', format($q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-01',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L, 'lines', '"x"'::jsonb))))
  $q$, v_own), 'lines');
  perform pg_temp.must_fail_like('T11e transactions ไม่ใช่ array', $q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-01',
      'transactions', '"x"'::jsonb))
  $q$, 'transactions');

  -- T11f เงินลอย: บรรทัดเงินสดไม่ผูกบัญชี (trigger เดิมต้องยังทำงานผ่าน RPC)
  perform pg_temp.must_fail_like('T11f เงินลอย', format($q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-01',
      'cash_date','2026-09-01',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1100','debit',100,'credit',0),
          jsonb_build_object('coa_code','4200','debit',0,'credit',100))))))
  $q$, v_own), 'Money Invariant 2');

  -- T11g ลักษณะรายการข้ามผู้ถือไม่ครบคู่
  perform pg_temp.must_fail_like('T11g counter_owner_id ไม่มี nature', format($q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-01',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L, 'counter_owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1200','debit',100,'credit',0),
          jsonb_build_object('coa_code','4200','debit',0,'credit',100))))))
  $q$, v_own, (select id from sri_os.owners where code='SUTEE')), 'ลักษณะ');
  perform pg_temp.must_fail_like('T11h nature ไม่มี counter_owner_id', format($q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-01',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L, 'intercompany_nature','loan',
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1200','debit',100,'credit',0),
          jsonb_build_object('coa_code','4200','debit',0,'credit',100))))))
  $q$, v_own), 'ผู้ถืออีกฝ่าย');

  -- ทุกเคสข้างบนต้องไม่ทิ้งอะไรไว้เลย
  select count(*) into v_after from sri_os.transactions;
  if v_after <> v_before then
    raise exception 'FAIL: เคสที่ถูกปฏิเสธทิ้งหัวรายการไว้ % แถว', v_after - v_before;
  end if;
  raise notice 'ok T6-T11 · รูปผิด/ข้อมูลขาด/คีย์แปลก/เงินลอย ปฏิเสธครบ และไม่ทิ้งแถวไว้';
end $$;

-- ============================================================
-- T12 · corporate_strict: ไม่มีไฟล์หลักฐาน → ปฏิเสธ · ครบ → ผ่าน
--       (ด่าน trg_corporate_evidence ต้องยังทำงานเมื่อ post ผ่าน RPC)
-- ============================================================
do $$
declare
  v_corp uuid := (select id from sri_os.owners where code='SRI_CORP');
  v_out jsonb; v_id uuid;
begin
  perform pg_temp.must_fail_like('T12a นิติบุคคลไม่แนบหลักฐาน', format($q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-02',
      'cash_date','2026-09-02','contact_id','00000000-0000-0000-0000-0000000c0001',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000b0003','debit',45000,'credit',0),
          jsonb_build_object('coa_code','4200','debit',0,'credit',45000))))))
  $q$, v_corp), 'หลักฐาน');

  perform pg_temp.must_fail_like('T12b นิติบุคคลแนบหลักฐานแต่ไม่มีคู่ค้า', format($q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-02',
      'cash_date','2026-09-02','attachments', to_jsonb(array['slip.pdf']),
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000b0003','debit',45000,'credit',0),
          jsonb_build_object('coa_code','4200','debit',0,'credit',45000))))))
  $q$, v_corp), 'คู่ค้า');

  v_out := sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','inc.rent','doc_date','2026-09-02','cash_date','2026-09-02',
    'attachments', to_jsonb(array['slip.pdf','invoice.pdf']),
    'contact_id','00000000-0000-0000-0000-0000000c0001',
    'transactions', jsonb_build_array(jsonb_build_object('owner_id', v_corp,
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000b0003','debit',45000,'credit',0),
        jsonb_build_object('coa_code','4200','debit',0,'credit',45000))))));
  v_id := ((v_out -> 'transaction_ids') ->> 0)::uuid;
  if (select cardinality(attachments) from sri_os.transactions where id = v_id) <> 2 then
    raise exception 'FAIL: ไฟล์แนบไม่ถูกเก็บครบ';
  end if;
  if (select contact_id from sri_os.transactions where id = v_id)
     <> '00000000-0000-0000-0000-0000000c0001' then
    raise exception 'FAIL: contact_id ไม่ถูกเก็บ';
  end if;
  raise notice 'ok T12 · นิติบุคคล: ไม่มีไฟล์/ไม่มีคู่ค้า → ปฏิเสธ · ครบ → ผ่าน และเก็บครบ';
end $$;

-- ============================================================
-- T13 · บัญชีที่ปิดใช้งาน → ปฏิเสธ · ยกเว้นรายการกลับรายการ (D-092)
-- ============================================================
do $$
declare
  v_own uuid := (select id from sri_os.owners where code='THANAKORN');
  v_out jsonb; v_src uuid; v_rev uuid;
begin
  perform pg_temp.must_fail_like('T13a บัญชีปิด', format($q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-20',
      'cash_date','2026-09-20',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000b0009','debit',100,'credit',0),
          jsonb_build_object('coa_code','4200','debit',0,'credit',100))))))
  $q$, v_own), 'ปิดใช้งาน');

  -- รายการเก่าที่อยู่ในบัญชีซึ่งต่อมาถูกปิด: ต้อง reverse ได้ตลอดกาล (กฎเหล็กข้อ 1)
  -- ลงรายการต้นทางด้วยบัญชีที่ยังเปิด แล้วปิดบัญชีทีหลัง = สภาพจริง
  v_out := sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','inc.rent','doc_date','2026-09-21','cash_date','2026-09-21',
    'transactions', jsonb_build_array(jsonb_build_object('owner_id', v_own,
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000b0001','debit',700,'credit',0),
        jsonb_build_object('coa_code','4200','debit',0,'credit',700))))));
  v_src := ((v_out -> 'transaction_ids') ->> 0)::uuid;

  -- ปิดบัญชีในฐานะ superuser (ของจริงใช้ settings.manage)
  reset role;
  update sri_os.bank_accounts set is_active = false
   where id = '00000000-0000-0000-0000-0000000b0001';
  set local role authenticated;

  perform pg_temp.must_fail_like('T13b ลงรายการใหม่เข้าบัญชีที่เพิ่งปิด', format($q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-22',
      'cash_date','2026-09-22',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000b0001','debit',100,'credit',0),
          jsonb_build_object('coa_code','4200','debit',0,'credit',100))))))
  $q$, v_own), 'ปิดใช้งาน');

  -- กลับรายการเข้าบัญชีที่ปิดแล้ว = ต้องทำได้
  v_out := sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','inc.rent','doc_date','2026-09-22','cash_date','2026-09-22',
    'source','reverse','reverses_id', v_src,
    'transactions', jsonb_build_array(jsonb_build_object('owner_id', v_own,
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code','4200','debit',700,'credit',0),
        jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000b0001','debit',0,'credit',700))))));
  v_rev := ((v_out -> 'transaction_ids') ->> 0)::uuid;
  if (select reverses_id from sri_os.transactions where id = v_rev) <> v_src then
    raise exception 'FAIL: reverses_id ไม่ถูกเก็บ';
  end if;

  -- แต่ "source = reverse" ที่ไม่ชี้ไปรายการจริง ต้องยังล้ม (ไม่ใช่ทางลัดปลดบัญชีปิด)
  perform pg_temp.must_fail_like('T13c อ้างว่า reverse แต่ไม่มี reverses_id', format($q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-23',
      'cash_date','2026-09-23','source','reverse',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','4200','debit',100,'credit',0),
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-0000000b0001','debit',0,'credit',100))))))
  $q$, v_own), 'กลับรายการ');

  reset role;
  update sri_os.bank_accounts set is_active = true
   where id = '00000000-0000-0000-0000-0000000b0001';
  set local role authenticated;
  raise notice 'ok T13 · บัญชีปิดลงใหม่ไม่ได้ · กลับรายการได้ · อ้างว่า reverse ลอยๆ ไม่ได้';
end $$;

-- ============================================================
-- T14 · Staff ลงตรงเข้า posted → ปฏิเสธ · แต่เส้นทางร่างยังทำได้
-- ============================================================
select pg_temp.login('staff');
do $$
declare v_own uuid := (select id from sri_os.owners where code='THANAKORN'); v_n int;
begin
  perform pg_temp.must_fail('T14a staff post ตรง', 'select sri_os.fn_post_entry(pg_temp.rent_payload(''staff ลอง post''))');
  -- เส้นทางที่ถูกต้องของ Staff = คีย์ร่าง
  insert into sri_os.draft_entries(owner_id, txn_type_code, doc_date, amount, memo)
  values (v_own, 'inc.rent', '2026-09-01', 12000, 'ร่างของ staff');
  select count(*) into v_n from sri_os.draft_entries where memo = 'ร่างของ staff';
  if v_n <> 1 then raise exception 'FAIL: staff คีย์ร่างไม่ได้ (เส้นทางที่ควรเปิดกลับปิด)'; end if;
  raise notice 'ok T14 · Staff post ตรงไม่ได้ (ต้องผ่านคิวร่าง) · คีย์ร่างได้';
end $$;

-- ============================================================
-- T15 · ผู้ใช้ที่ไม่มีแถวใน app_users / ถูกปิดใช้งาน → ทำอะไรไม่ได้
-- ============================================================
select pg_temp.login('ghost');
do $$ begin
  perform pg_temp.must_fail_like('T15a ghost', 'select sri_os.fn_post_entry(pg_temp.rent_payload(''ghost''))', 'ตำแหน่ง');
end $$;
select pg_temp.login('dead');
do $$ begin
  perform pg_temp.must_fail_like('T15b ผู้ใช้ปิดใช้งาน', 'select sri_os.fn_post_entry(pg_temp.rent_payload(''dead''))', 'ตำแหน่ง');
end $$;
-- ไม่ล็อกอินเลย (auth.uid() = null)
select set_config('test.uid', '', true);
do $$ begin
  perform pg_temp.must_fail_like('T15c ไม่ล็อกอิน', 'select sri_os.fn_post_entry(pg_temp.rent_payload(''anon''))', 'ล็อกอิน');
  raise notice 'ok T15 · ghost · ผู้ใช้ปิดใช้งาน · ไม่ล็อกอิน → ปฏิเสธทั้งสามแบบ';
end $$;

-- ============================================================
-- T16 · ลงรายการของผู้ถือที่ตัวเองไม่มีสิทธิ์เห็น → ปฏิเสธ
-- ============================================================
select pg_temp.login('mgr');
do $$
declare v_x uuid := (select id from sri_os.owners where code='BENJAPORN'); v_n int;
begin
  perform pg_temp.must_fail('T16 owner นอกขอบเขต', format($q$
    select sri_os.fn_post_entry(jsonb_build_object('txn_type_code','inc.rent','doc_date','2026-09-25',
      'transactions', jsonb_build_array(jsonb_build_object('owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1200','debit',100,'credit',0),
          jsonb_build_object('coa_code','4200','debit',0,'credit',100))))))
  $q$, v_x));
  reset role;
  select count(*) into v_n from sri_os.transactions where owner_id = v_x;
  set local role authenticated;
  if v_n <> 0 then raise exception 'FAIL: ลงรายการของ owner นอกขอบเขตได้ % แถว', v_n; end if;
  raise notice 'ok T16 · ลงรายการของผู้ถือที่มองไม่เห็นไม่ได้ (ตรวจด้วยสายตา superuser แล้วว่า 0 แถว)';
end $$;

-- ============================================================
-- T17 · กดซ้ำ payload เดิม → ไม่เกิดรายการซ้ำ
-- ============================================================
do $$
declare
  v1 jsonb; v2 jsonb; v3 jsonb; v_n_before int; v_n_after int;
begin
  reset role; select count(*) into v_n_before from sri_os.transactions; set local role authenticated;

  v1 := sri_os.fn_post_entry(pg_temp.rent_payload('กดซ้ำ'));
  v2 := sri_os.fn_post_entry(pg_temp.rent_payload('กดซ้ำ'));   -- payload เดิมเป๊ะ = กดรัวสองครั้ง

  if (v1 -> 'transaction_ids') <> (v2 -> 'transaction_ids') then
    raise exception 'FAIL: กดซ้ำได้ id ชุดใหม่ (% vs %) = ลงสองรายการ',
      v1 -> 'transaction_ids', v2 -> 'transaction_ids';
  end if;
  if (v1 ->> 'replayed')::boolean then raise exception 'FAIL: ครั้งแรกไม่ควร replayed'; end if;
  if not (v2 ->> 'replayed')::boolean then
    raise exception 'FAIL: ครั้งที่สองต้องบอกว่าเป็น replay เพื่อให้หน้าจอรู้ว่าไม่ได้ลงใหม่';
  end if;

  reset role; select count(*) into v_n_after from sri_os.transactions; set local role authenticated;
  if v_n_after <> v_n_before + 1 then
    raise exception 'FAIL: กดสองครั้งเกิด % รายการ (ต้อง 1)', v_n_after - v_n_before;
  end if;

  -- T17b payload ที่ต่างกันแม้นิดเดียว = เจตนาใหม่ → ลงได้
  v3 := sri_os.fn_post_entry(pg_temp.rent_payload('กดซ้ำ แต่ memo ต่าง'));
  if (v3 -> 'transaction_ids') = (v1 -> 'transaction_ids') then
    raise exception 'FAIL: payload ต่างกันแต่ถูกมองเป็นรายการเดิม';
  end if;
  raise notice 'ok T17 · กดรัวสองครั้ง = รายการเดียว (replayed=true) · payload ต่าง = ลงใหม่ได้';
end $$;

-- T17c · พ้นหน้าต่างกันกดซ้ำ (อ่านจากตาราง settings) → ลงใหม่ได้
do $$
declare v1 jsonb; v2 jsonb;
begin
  v1 := sri_os.fn_post_entry(pg_temp.rent_payload('พ้นหน้าต่าง'));
  -- ย้อนเวลาของแถว fingerprint 1 วินาที (now() คงที่ในธุรกรรมเดียว จึงทดสอบด้วยการย้อน)
  reset role;
  update sri_os.post_entry_requests set created_at = now() - interval '1 second';
  set local role authenticated;

  -- หน้าต่างปกติ (60 วิ) → ยังเป็น replay
  v2 := sri_os.fn_post_entry(pg_temp.rent_payload('พ้นหน้าต่าง'));
  if not (v2 ->> 'replayed')::boolean then
    raise exception 'FAIL: ย้อนเวลาแค่ 1 วินาที ยังอยู่ในหน้าต่าง 60 วิ ต้องเป็น replay';
  end if;

  -- ตั้งหน้าต่าง = 0 วิ แล้วยิงซ้ำ → ต้องลงใหม่ (พิสูจน์ว่าค่าอ่านจาก settings จริง)
  reset role;
  update sri_os.settings set value = '0'::jsonb where key = 'ledger.post_dedupe_seconds';
  update sri_os.post_entry_requests set created_at = now() - interval '1 second';
  set local role authenticated;
  v2 := sri_os.fn_post_entry(pg_temp.rent_payload('พ้นหน้าต่าง'));
  if (v2 ->> 'replayed')::boolean then
    raise exception 'FAIL: หน้าต่าง 0 วิ แล้วยังเป็น replay → ค่าไม่ได้อ่านจาก settings';
  end if;
  if (v2 -> 'transaction_ids') = (v1 -> 'transaction_ids') then
    raise exception 'FAIL: พ้นหน้าต่างแล้วควรได้รายการใหม่ แต่ได้ id เดิม';
  end if;

  reset role;
  update sri_os.settings set value = '60'::jsonb where key = 'ledger.post_dedupe_seconds';
  set local role authenticated;
  raise notice 'ok T17c · หน้าต่างกันกดซ้ำอ่านจาก settings จริง (0 วิ = ลงใหม่ได้ · 60 วิ = replay)';
end $$;

-- ============================================================
-- T18 · fingerprint แยกตามผู้ใช้ — คนละคนส่ง payload เดียวกันต้องไม่ถูกมองเป็นกดซ้ำ
-- ============================================================
do $$
declare v1 jsonb; v2 jsonb;
begin
  perform pg_temp.login('mgr');
  v1 := sri_os.fn_post_entry(pg_temp.rent_payload('คนละคน'));
  perform pg_temp.login('mgmt');
  v2 := sri_os.fn_post_entry(pg_temp.rent_payload('คนละคน'));
  if (v1 -> 'transaction_ids') = (v2 -> 'transaction_ids') then
    raise exception 'FAIL: คนละคนส่ง payload เดียวกันถูกมองเป็นกดซ้ำ = รายการของคนที่สองหายเงียบๆ';
  end if;
  if (v2 ->> 'replayed')::boolean then raise exception 'FAIL: คนที่สองไม่ควรเป็น replay'; end if;
  raise notice 'ok T18 · fingerprint ผูกกับผู้ใช้ · คนละคนไม่กวนกัน';
end $$;

-- ============================================================
-- T19 · ไม่มีใครลบแถว fingerprint / รายการที่ลงแล้วได้ (กฎเหล็กข้อ 1)
-- ============================================================
select pg_temp.login('super');
do $$
declare n_before int; n_after int;
begin
  execute 'reset role';
  select count(*) into n_before from sri_os.post_entry_requests;
  execute 'set local role authenticated';
  -- DELETE: ชั้น GRANT เปิดตามแบบแผน (RLS เป็นด่านเดียว) → RLS ปฏิเสธแบบ **เงียบ** 0 แถว
  -- จึงต้องนับแถว ไม่ใช่รอ error (นี่คือเหตุที่เทสต์ชุดนี้มีตัวนับแถวทุกที่)
  delete from sri_os.post_entry_requests;
  -- TRUNCATE: ไม่ยิง row trigger → ต้องถูกกันด้วย statement trigger ให้ error จริง
  perform pg_temp.must_fail('T19b truncate fingerprint', 'truncate sri_os.post_entry_requests');
  execute 'reset role';
  select count(*) into n_after from sri_os.post_entry_requests;
  execute 'set local role authenticated';
  if n_after <> n_before or n_before = 0 then
    raise exception 'FAIL: ร่องรอยคำขอหายไป (% → %)', n_before, n_after;
  end if;
  raise notice 'ok T19 · super_admin ลบ/ล้างร่องรอยคำขอไม่ได้ (% แถวยังอยู่ครบ)', n_after;
end $$;

reset role;

-- ============================================================
-- T20 · ผลรวม: ทุกรายการที่ไฟล์นี้ลงไว้ต้องสมดุลและมีบรรทัด ≥ 2 ทั้งหมด
--       (ตรวจด้วยสายตา superuser ครั้งเดียวท้ายไฟล์ — จับกรณีที่หลุดไปทุกเคส)
-- ============================================================
do $$
declare v text; n int;
begin
  select count(*) into n from sri_os.transactions;
  if n < 8 then
    raise exception 'FAIL: มีรายการแค่ % แถว — เทสต์นี้อาจไม่ได้ลงอะไรเลย', n;
  end if;
  select string_agg(t.id::text, ', ') into v
    from sri_os.transactions t
   where (select coalesce(sum(l.debit),0) from sri_os.transaction_lines l where l.transaction_id = t.id)
      <> (select coalesce(sum(l.credit),0) from sri_os.transaction_lines l where l.transaction_id = t.id)
      or (select count(*) from sri_os.transaction_lines l where l.transaction_id = t.id) < 2;
  if v is not null then
    raise exception 'FAIL: มีรายการที่ไม่สมดุล/บรรทัดไม่ครบหลงเข้าไป: %', v;
  end if;
  -- หัวรายการกับบรรทัดต้องลงในธุรกรรมเดียวกันจริง (write_txn_id ของหัวรายการถูกตั้ง)
  if exists (select 1 from sri_os.transactions where write_txn_id is null) then
    raise exception 'FAIL: มีหัวรายการที่ write_txn_id ว่าง';
  end if;
  raise notice 'ok T20 · ทุกรายการที่ลงผ่าน RPC (% แถว) สมดุลและมีบรรทัดครบ', n;
end $$;

do $$ begin raise notice '=== fn_post_entry ผ่านทั้งหมด ==='; end $$;

rollback;
