-- ============================================================
-- SRI OS · เทสต์ตารางสิทธิ์ + fn_can() + RLS ที่แปลงแล้ว (D-072 · D-073)
--
-- รันในเครื่อง:  bash scripts/test-rls-local.sh
-- รันกับ DB อื่น: psql -v ON_ERROR_STOP=1 -f supabase/tests/roles_permissions_test.sql
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ **rollback ปิดท้าย** จึงไม่ทิ้งข้อมูลทดสอบไว้
-- เจอข้อผิด = raise exception = psql หยุดด้วย exit code ไม่ศูนย์
--
-- หมายเหตุ: ไฟล์นี้พึ่ง auth.uid() อ่านจาก GUC `test.uid` (ของจำลองในเครื่อง)
--   ถ้ารันกับ Supabase จริง auth.uid() อ่านจาก JWT — เทสต์ส่วน fn_can จะได้ false หมด
--   ให้ใช้ scripts/test-rls-local.sh ซึ่งสร้าง stub ให้ครบ
-- ============================================================

begin;

-- ---------- fixtures ----------
create temporary table t_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_uid(label) values
  ('super'), ('mgmt'), ('mgr'), ('staff'), ('mgr_inactive'), ('ghost');

insert into auth.users(id) select id from t_uid;

insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, u.label || '@test.local', u.label, x.role, x.active
  from t_uid u
  join (values
    ('super',        'super_admin', true),
    ('mgmt',         'management',  true),
    ('mgr',          'manager',     true),
    ('staff',        'staff',       true),
    ('mgr_inactive', 'manager',     false)   -- 'ghost' ไม่มีแถวใน app_users โดยตั้งใจ
  ) as x(label, role, active) on x.label = u.label;

create or replace function pg_temp.uid(p_label text) returns uuid
language sql stable as $fn$ select id from t_uid where label = p_label $fn$;

create or replace function pg_temp.login(p_label text) returns void
language sql as $fn$
  select set_config('test.uid', coalesce((select id::text from t_uid where label = p_label), ''), true);
$fn$;

create or replace function pg_temp.expect_can(p_label text, p_perm text, p_expect boolean) returns void
language plpgsql as $fn$
declare v boolean;
begin
  perform pg_temp.login(p_label);
  v := sri_os.fn_can(p_perm);
  if v is distinct from p_expect then
    raise exception 'FAIL: % · fn_can(%) = % แต่ต้องได้ %', p_label, p_perm, v, p_expect;
  end if;
end $fn$;

-- ============================================================
-- 1 · ตารางสิทธิ์ต้องตรงกับ D-072 ทุกช่อง (เขียนคาดหวังไว้ที่นี่ ไม่อ่านจาก seed)
-- ============================================================
do $$
declare r record; n int := 0;
begin
  for r in
    select * from (values
      -- permission        super  mgmt   mgr    staff
      ('txn.create',       true,  true,  true,  true),
      ('ledger.approve',   true,  true,  true,  false),
      ('cash.confirm',     true,  true,  false, false),  -- ← หัวใจการแยกหน้าที่
      ('txn.void',         true,  true,  false, false),
      ('period.reopen',    true,  true,  false, false),
      ('settings.manage',  true,  true,  false, false),
      ('users.manage',     true,  false, false, false),
      ('owner.view_all',   true,  true,  false, false)
    ) as m(perm, super, mgmt, mgr, staff)
  loop
    perform pg_temp.expect_can('super', r.perm, r.super);
    perform pg_temp.expect_can('mgmt',  r.perm, r.mgmt);
    perform pg_temp.expect_can('mgr',   r.perm, r.mgr);
    perform pg_temp.expect_can('staff', r.perm, r.staff);
    n := n + 4;
  end loop;
  raise notice 'ok 1 · ตารางสิทธิ์ตรงทั้ง % ช่อง', n;
end $$;

-- ============================================================
-- 2 · Manager อนุมัติได้ แต่ยืนยันเงินไม่ได้ · Staff ไม่ได้ทั้งคู่
-- ============================================================
do $$
begin
  perform pg_temp.expect_can('mgr',   'ledger.approve', true);
  perform pg_temp.expect_can('mgr',   'cash.confirm',   false);
  perform pg_temp.expect_can('staff', 'ledger.approve', false);
  perform pg_temp.expect_can('staff', 'cash.confirm',   false);
  raise notice 'ok 2 · Manager อนุมัติ Ledger ได้ แต่ยืนยันเงินไม่ได้ · Staff ไม่ได้ทั้งสอง';
end $$;

-- ============================================================
-- 3 · is_active = false → false ทุกสิทธิ์ (แม้ role เดิมจะมีสิทธิ์นั้น)
--     และผู้ใช้ที่ไม่มีแถวใน app_users / ไม่ได้ล็อกอิน → false ไม่ใช่ error
-- ============================================================
do $$
declare p text;
begin
  for p in select key from sri_os.permissions loop
    perform pg_temp.expect_can('mgr_inactive', p, false);
    perform pg_temp.expect_can('ghost',        p, false);
    perform pg_temp.expect_can('__nobody__',   p, false);   -- auth.uid() = null
  end loop;
  raise notice 'ok 3 · ผู้ใช้ปิดใช้งาน / ไม่มีแถว / ไม่ล็อกอิน = false ทุกสิทธิ์ ไม่ error';
end $$;

-- ============================================================
-- 4 · ห้ามมี permission ที่สื่อถึงการข้ามกฎเงิน (D-073)
-- ============================================================
do $$
declare v text;
begin
  select string_agg(key, ', ') into v
    from sri_os.permissions
   where key ~* '(invariant|evidence|bypass|skip|waive|override|force|posted|unlock|exempt|disable)';
  if v is not null then
    raise exception 'FAIL: มี permission ที่สื่อถึงการข้ามกฎเงิน: %', v;
  end if;
  raise notice 'ok 4 · ไม่มี permission ที่สื่อถึงการข้ามกฎเงิน';
end $$;

-- CHECK ต้องกันการ "เผลอเพิ่ม" ด้วย ไม่ใช่แค่ตอน seed
do $$
declare bad text; blocked int := 0;
begin
  for bad in select * from unnest(array[
      'invariant.skip', 'evidence.waive', 'delete.posted',
      'ledger.override', 'double_entry.disable', 'period.unlock', 'trigger.bypass'
    ])
  loop
    begin
      insert into sri_os.permissions(key, label) values (bad, 'ของต้องห้าม');
      raise exception 'FAIL: เพิ่ม permission ต้องห้าม "%" ได้ = เปิดช่องปลดกฎเงิน', bad;
    exception when check_violation then
      blocked := blocked + 1;
    end;
  end loop;
  raise notice 'ok 4b · CHECK กันสิทธิ์ปลดกฎเงินได้ % คีย์', blocked;
end $$;

-- ============================================================
-- 5 · ไม่มี policy ไหนเหลือการฮาร์ดโค้ดชื่อ role
-- ============================================================
do $$
declare v text;
begin
  select string_agg(schemaname || '.' || tablename || ' · ' || policyname, E'\n')
    into v
    from pg_policies
   where schemaname = 'sri_os'
     and (coalesce(qual, '') || coalesce(with_check, '')) ~ 'fn_is_management|fn_my_role';
  if v is not null then
    raise exception 'FAIL: ยังมี policy ที่เรียกฟังก์ชันระดับ role:\n%', v;
  end if;

  select string_agg(schemaname || '.' || tablename || ' · ' || policyname, E'\n')
    into v
    from pg_policies
   where schemaname = 'sri_os'
     and (coalesce(qual, '') || coalesce(with_check, '')) ~* '''(management|manager|staff|super_admin)''';
  if v is not null then
    raise exception 'FAIL: ยังมี policy ที่เทียบชื่อ role ตรงๆ:\n%', v;
  end if;
  raise notice 'ok 5 · ไม่มี policy ที่ผูกกับชื่อ role';
end $$;

-- fn_is_management() ยังอยู่เป็น wrapper (ของเก่าต้องไม่พัง) และให้ผลเท่า owner.view_all
do $$
begin
  perform pg_temp.login('mgmt');
  if not sri_os.fn_is_management() then raise exception 'FAIL: wrapper ต้อง true สำหรับ Management'; end if;
  perform pg_temp.login('mgr');
  if sri_os.fn_is_management() then raise exception 'FAIL: wrapper ต้อง false สำหรับ Manager'; end if;
  raise notice 'ok 5b · fn_is_management() เป็น wrapper ของ fn_can(owner.view_all)';
end $$;

-- ============================================================
-- 6 · app_users.role เป็น FK เข้า roles(key) · รับ 4 ค่าใหม่ ไม่รับ 'user'
-- ============================================================
do $$
declare r text; v uuid;
begin
  for r in select key from sri_os.roles loop
    v := gen_random_uuid();
    insert into auth.users(id) values (v);
    insert into sri_os.app_users(id, email, display_name, role) values (v, r || '@t', r, r);
  end loop;

  begin
    insert into auth.users(id) values ('00000000-0000-0000-0000-0000000000aa');
    insert into sri_os.app_users(id, email, display_name, role)
    values ('00000000-0000-0000-0000-0000000000aa', 'old@t', 'old', 'user');
    raise exception 'FAIL: role ''user'' ต้องใช้ไม่ได้แล้ว (เปลี่ยนเป็น staff)';
  exception when foreign_key_violation then null;
  end;
  raise notice 'ok 6 · app_users.role = FK roles(key) · รับ 4 ค่าใหม่ ปฏิเสธ ''user''';
end $$;

-- ============================================================
-- 7 · RLS จริง — รันในฐานะ role authenticated
-- ============================================================
-- fixtures ที่ต้องมีก่อนเปลี่ยน role
insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
select '00000000-0000-0000-0000-0000000000b1', id, 'KBANK', 'ทดสอบ', 'ทดสอบ'
  from sri_os.owners where code = 'SRI_CORP';

insert into sri_os.draft_entries(id, owner_id, txn_type_code, doc_date, amount, created_by)
select '00000000-0000-0000-0000-0000000000d1', o.id, 'inc.other', current_date, 1000, pg_temp.uid('staff')
  from sri_os.owners o where o.code = 'SRI_CORP';

insert into sri_os.period_closes(owner_id, period, closed_by)
select o.id, date_trunc('month', current_date)::date, pg_temp.uid('mgmt')
  from sri_os.owners o where o.code = 'SRI_CORP';

-- manager/staff ได้สิทธิ์เห็น SRI_CORP + SUTEE (ไม่มี owner.view_all)
insert into sri_os.user_owner_access(user_id, owner_id)
select pg_temp.uid(l), o.id from unnest(array['mgr','staff']) l, sri_os.owners o
 where o.code in ('SRI_CORP', 'SUTEE');

-- ตัวช่วยของเทสต์อยู่ใน schema ชั่วคราวของ session · role authenticated ต้องเรียกได้
do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.t_uid to authenticated', s);
end $$;

set local role authenticated;

-- 7.1 Manager ยืนยันเงินไม่ได้ (นี่คือข้อที่ทำให้มีคนที่สอง)
do $$
begin
  perform pg_temp.login('mgr');
  begin
    insert into sri_os.cash_confirmations(draft_entry_id, bank_account_id, expected_amount)
    values ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000b1', 1000);
    raise exception 'FAIL: Manager ยืนยันรับ-จ่ายเงินได้ = การแยกหน้าที่หลุด';
  exception when insufficient_privilege then null;
  end;

  perform pg_temp.login('mgmt');
  insert into sri_os.cash_confirmations(draft_entry_id, bank_account_id, expected_amount)
  values ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000b1', 1000);
  raise notice 'ok 7.1 · Manager ยืนยันเงินไม่ได้ · Management ได้';
end $$;

-- 7.2 Staff คีย์ร่างได้ แต่อนุมัติไม่ได้ · Manager อนุมัติได้
do $$
declare n int;
begin
  perform pg_temp.login('staff');
  insert into sri_os.draft_entries(owner_id, txn_type_code, doc_date, amount, created_by)
  select o.id, 'inc.other', current_date, 500, pg_temp.uid('staff')
    from sri_os.owners o where o.code = 'SRI_CORP';

  update sri_os.draft_entries set status = 'approved'
   where id = '00000000-0000-0000-0000-0000000000d1';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL: Staff อนุมัติร่างได้ % แถว', n; end if;

  perform pg_temp.login('mgr');
  update sri_os.draft_entries set status = 'approved'
   where id = '00000000-0000-0000-0000-0000000000d1';
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL: Manager อนุมัติร่างไม่ได้ (% แถว)', n; end if;
  raise notice 'ok 7.2 · Staff คีย์ร่างได้ อนุมัติไม่ได้ · Manager อนุมัติได้';
end $$;

-- 7.3 post เข้า ledger: Staff ไม่ได้ · Manager ได้
do $$
declare v_owner uuid;
begin
  select id into v_owner from sri_os.owners where code = 'SUTEE';
  perform pg_temp.login('staff');
  begin
    insert into sri_os.transactions(owner_id, txn_type_code, doc_date)
    values (v_owner, 'inc.other', current_date);
    raise exception 'FAIL: Staff post เข้า ledger ได้';
  exception when insufficient_privilege then null;
  end;

  -- ขาบวก: ถ้า Manager ก็ post ไม่ได้ เทสต์ข้างบนจะผ่านทั้งที่ policy ปิดทุกคน
  perform pg_temp.login('mgr');
  insert into sri_os.transactions(owner_id, txn_type_code, doc_date)
  values (v_owner, 'inc.other', current_date);
  raise notice 'ok 7.3 · Staff post เข้า ledger ไม่ได้ · Manager ได้';
end $$;

-- 7.4 เปิดงวดที่ปิดแล้ว: Manager ลบแถวปิดงวดไม่ได้ · Super Admin ได้
do $$
declare n int;
begin
  perform pg_temp.login('mgr');
  delete from sri_os.period_closes;
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL: Manager เปิดงวดที่ปิดแล้วได้ % แถว', n; end if;
  raise notice 'ok 7.4 · Manager เปิดงวดที่ปิดแล้วไม่ได้';
end $$;

-- 7.5 การล็อกงวดต้องยังทำงานหลังเปิด RLS บน period_closes
--     (trigger เป็น security definer จึงเห็นแถวปิดงวดเสมอ ไม่ขึ้นกับสิทธิ์อ่านของคนคีย์)
do $$
declare v_owner uuid;
begin
  select id into v_owner from sri_os.owners where code = 'SRI_CORP';
  perform pg_temp.login('mgr');
  begin
    insert into sri_os.transactions(owner_id, txn_type_code, doc_date, attachments)
    values (v_owner, 'inc.other', current_date, array['slip.pdf']);
    raise exception 'FAIL: ลงรายการในงวดที่ปิดแล้วของ corporate_strict ได้ = การล็อกงวดหลุด';
  exception when raise_exception then
    if sqlerrm not like '%ปิดแล้ว%' then raise; end if;
  end;
  raise notice 'ok 7.5 · การล็อกงวดยังบังคับได้หลังเปิด RLS บน period_closes';
end $$;

-- 7.6 user_owner_access: ใครก็เพิ่มสิทธิ์ดู owner ให้ตัวเองไม่ได้
do $$
declare v_owner uuid;
begin
  select id into v_owner from sri_os.owners where code = 'SRI_HOLDING';
  perform pg_temp.login('mgr');
  begin
    insert into sri_os.user_owner_access(user_id, owner_id) values (pg_temp.uid('mgr'), v_owner);
    raise exception 'FAIL: Manager เพิ่มสิทธิ์ดู owner ให้ตัวเองได้';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok 7.6 · เพิ่มสิทธิ์ดู owner ให้ตัวเองไม่ได้ (ต้องมี users.manage)';
end $$;

-- 7.7 ตารางสิทธิ์: อ่านได้ทุกคน · แก้ได้เฉพาะ users.manage (Management ก็แก้ไม่ได้)
do $$
declare n int;
begin
  perform pg_temp.login('mgmt');
  if (select count(*) from sri_os.permissions) = 0 then
    raise exception 'FAIL: อ่านตาราง permissions ไม่ได้ UI จะไม่รู้ว่าปุ่มไหนกดได้';
  end if;
  delete from sri_os.role_permissions where role_key = 'manager' and permission_key = 'ledger.approve';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL: Management แก้ตารางสิทธิ์ได้ (ต้องเป็น users.manage)'; end if;

  perform pg_temp.login('super');
  delete from sri_os.role_permissions where role_key = 'manager' and permission_key = 'ledger.approve';
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL: Super Admin แก้ตารางสิทธิ์ไม่ได้'; end if;

  -- ย้ายสิทธิ์แล้วมีผลทันทีโดยไม่ต้องแก้โค้ด = เหตุผลทั้งหมดของ D-073
  perform pg_temp.expect_can('mgr', 'ledger.approve', false);
  raise notice 'ok 7.7 · แก้ตารางสิทธิ์ได้เฉพาะ users.manage และมีผลทันที';
end $$;

reset role;

do $$ begin raise notice '=== ผ่านทั้งหมด ==='; end $$;

rollback;
