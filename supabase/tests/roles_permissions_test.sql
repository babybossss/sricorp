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

-- 7.6 user_owner_access: การแจกสิทธิ์ดู Entity = users.manage (super_admin เท่านั้น)
--     เคส Management คือตัวจับ policy เก่า `access_manage` ที่ค้างอยู่ —
--     ของเก่ากั้นด้วย fn_is_management() ซึ่ง Management ผ่าน · policy OR กัน
--     ถ้า migration ไม่ลบของเก่า ข้อจำกัดใหม่จะไม่มีผลเลย
do $$
declare v_owner uuid; n int;
begin
  select id into v_owner from sri_os.owners where code = 'SRI_HOLDING';

  perform pg_temp.login('mgr');
  begin
    insert into sri_os.user_owner_access(user_id, owner_id) values (pg_temp.uid('mgr'), v_owner);
    raise exception 'FAIL: Manager เพิ่มสิทธิ์ดู owner ให้ตัวเองได้';
  exception when insufficient_privilege then null;
  end;

  perform pg_temp.login('mgmt');
  begin
    insert into sri_os.user_owner_access(user_id, owner_id) values (pg_temp.uid('staff'), v_owner);
    raise exception 'FAIL: Management ยังแจกสิทธิ์ดู Entity ได้ = policy เก่าค้างและ OR ทับของใหม่';
  exception when insufficient_privilege then null;
  end;

  -- ขาบวก: super_admin ต้องทำได้ ไม่งั้นแปลว่าปิดตายทั้งตาราง
  perform pg_temp.login('super');
  insert into sri_os.user_owner_access(user_id, owner_id) values (pg_temp.uid('staff'), v_owner);
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL: super_admin แจกสิทธิ์ดู Entity ไม่ได้'; end if;
  raise notice 'ok 7.6 · แจกสิทธิ์ดู Entity ได้เฉพาะ users.manage (Management ก็ไม่ได้)';
end $$;

-- 7.6b ปิดงวด = settings.manage · เปิดงวด = period.reopen (คนละสิทธิ์)
do $$
declare v_owner uuid; n int;
begin
  select id into v_owner from sri_os.owners where code = 'SUTEE';
  perform pg_temp.login('mgr');
  begin
    insert into sri_os.period_closes(owner_id, period)
    values (v_owner, date_trunc('month', current_date)::date);
    raise exception 'FAIL: Manager ปิดงวดได้';
  exception when insufficient_privilege then null;
  end;

  perform pg_temp.login('mgmt');
  delete from sri_os.period_closes;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'FAIL: Management เปิดงวดที่ปิดแล้วไม่ได้ (มี period.reopen)'; end if;
  raise notice 'ok 7.6b · Manager ปิดงวดไม่ได้ · Management เปิดงวดได้';
end $$;

-- 7.7 ตารางสิทธิ์: อ่านได้ทุกตำแหน่ง · **เขียนไม่ได้เลยทุกตำแหน่งรวม Super Admin**
--     แก้โครงสร้างสิทธิ์ได้จาก migration เท่านั้น (20261007000003)
--     RLS ปฏิเสธเงียบๆ (0 แถว ไม่ error) → ต้องเช็ค row_count ไม่ใช่รอ exception
do $$
declare r text; t text; n int;
begin
  -- 7.7a อ่านได้ทุกตำแหน่ง · ถ้าไม่มี read policy หน้าจอจะว่างเปล่าแบบไม่มีอะไรบอกว่าทำไม
  foreach r in array array['staff', 'mgr', 'mgmt', 'super'] loop
    perform pg_temp.login(r);
    if (select count(*) from sri_os.permissions) = 0 then
      raise exception 'FAIL: % อ่านตาราง permissions ไม่ได้ UI จะไม่รู้ว่าปุ่มไหนกดได้ และหน้า "ไม่มีสิทธิ์" จะว่าง', r;
    end if;
    if (select count(*) from sri_os.roles) = 0 then
      raise exception 'FAIL: % อ่านตาราง roles ไม่ได้ · /settings/users จะไม่มีรายการตำแหน่ง', r;
    end if;
    if (select count(*) from sri_os.role_permissions) = 0 then
      raise exception 'FAIL: % อ่านตาราง role_permissions ไม่ได้', r;
    end if;
  end loop;

  -- 7.7b เขียนไม่ได้เลย — เคสที่สำคัญที่สุด เพราะนี่คือทางเลื่อนสิทธิ์ตัวเอง
  foreach r in array array['staff', 'mgr', 'mgmt', 'super'] loop
    perform pg_temp.login(r);

    delete from sri_os.role_permissions where role_key = 'manager' and permission_key = 'ledger.approve';
    get diagnostics n = row_count;
    if n <> 0 then raise exception 'FAIL: % ลบแถวในตารางสิทธิ์ได้ (% แถว)', r, n; end if;

    update sri_os.roles set label = 'แก้ได้' where key = 'staff';
    get diagnostics n = row_count;
    if n <> 0 then raise exception 'FAIL: % แก้ตาราง roles ได้', r; end if;

    foreach t in array array['roles', 'permissions', 'role_permissions'] loop
      begin
        case t
          when 'roles' then
            insert into sri_os.roles(key, label, rank_order) values ('zz_' || r, 'ของปลอม', 99);
          when 'permissions' then
            insert into sri_os.permissions(key, label) values ('zz.' || r, 'ของปลอม');
          else
            insert into sri_os.role_permissions(role_key, permission_key) values (r, 'ledger.post');
        end case;
        raise exception 'FAIL: % เพิ่มแถวในตาราง % ได้ = เปิดสิทธิ์ให้ตัวเองได้', r, t;
      exception when insufficient_privilege then null;
        when raise_exception then if sqlerrm like 'FAIL:%' then raise; end if;
      end;
    end loop;
  end loop;

  -- 7.7c เส้นทางเลื่อนสิทธิ์ที่ชัดที่สุด: Staff แจก portfolio.view_all ให้ตำแหน่งตัวเอง
  perform pg_temp.login('staff');
  begin
    insert into sri_os.role_permissions(role_key, permission_key) values ('staff', 'portfolio.view_all');
    raise exception 'FAIL: Staff แจกสิทธิ์ portfolio.view_all ให้ตำแหน่งตัวเองได้';
  exception when insufficient_privilege then null;
    when raise_exception then if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  perform pg_temp.expect_can('staff', 'portfolio.view_all', false);

  -- 7.7d Staff เลื่อนตัวเองเป็น super_admin ผ่าน app_users (ควรล้มที่ users_write)
  perform pg_temp.login('staff');
  update sri_os.app_users set role = 'super_admin' where id = auth.uid();
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL: Staff เลื่อนตำแหน่งตัวเองเป็น super_admin ได้'; end if;
  perform pg_temp.expect_can('staff', 'users.manage', false);

  -- 7.7e ขาบวก: กลไกของ D-073 ยังอยู่ — fn_can อ่านจากตารางสด ไม่ได้ hard-code
  --      (แก้ตารางต้องทำจาก migration · ที่นี่พิสูจน์ด้วยสิทธิ์ของ cluster superuser)
  reset role;
  delete from sri_os.role_permissions where role_key = 'manager' and permission_key = 'ledger.approve';
  perform pg_temp.expect_can('mgr', 'ledger.approve', false);
  reset role;
  insert into sri_os.role_permissions(role_key, permission_key) values ('manager', 'ledger.approve');
  perform pg_temp.expect_can('mgr', 'ledger.approve', true);

  raise notice 'ok 7.7 · ตารางสิทธิ์: อ่านได้ทุกตำแหน่ง · เขียนไม่ได้เลยรวม Super Admin · เลื่อนสิทธิ์ตัวเองไม่ได้ทั้งสองทาง';
end $$;

reset role;

-- ============================================================
-- 8 · ตารางที่ migration ดูแล ต้องมี policy เท่าที่ตั้งใจ ไม่เกินไม่ขาด
--     policy เป็น permissive และ OR กัน · ของเก่าที่ค้างอยู่หนึ่งตัวลบล้างสิทธิ์ใหม่ได้
--     (รายการนี้เขียนซ้ำในเทสต์โดยตั้งใจ ไม่ได้อ่านจาก migration)
-- ============================================================
do $$
declare v_extra text; v_missing text; v_dup text;
begin
  create temporary table t_expect(tbl text, pol text) on commit drop;
  insert into t_expect values
    ('owners','owners_read'),('owners','owners_write'),
    -- ตารางกฎ + ผังบัญชี: **อ่านอย่างเดียว** ไม่มี *_write โดยตั้งใจ (20261007000004)
    -- เป็นสำเนาของ src/lib/rules/{coa,tx-rules}.ts → แก้ได้จาก migration เท่านั้น
    ('chart_of_accounts','chart_of_accounts_read'),
    ('txn_types','txn_types_read'),
    ('contacts','contacts_read'),('contacts','contacts_insert'),('contacts','contacts_update'),
    ('contact_links','contact_links_read'),('contact_links','contact_links_write'),
    ('transactions','transactions_by_owner'),('transactions','txn_insert'),('transactions','txn_update'),
    ('transaction_lines','lines_by_txn'),('transaction_lines','lines_insert'),
    ('transaction_lines','lines_update'),('transaction_lines','lines_delete'),
    ('draft_entries','draft_entries_by_owner'),('draft_entries','draft_insert'),('draft_entries','draft_review'),
    ('cash_confirmations','confirmations_read'),('cash_confirmations','confirmations_write'),
    ('cash_confirmations','confirmations_update'),
    ('audit_log','audit_read'),
    ('app_users','users_read'),('app_users','users_write'),
    ('settings','settings_read'),('settings','settings_write'),
    ('user_owner_access','owner_access_read'),('user_owner_access','owner_access_write'),
    ('period_closes','period_closes_read'),('period_closes','period_closes_insert'),
    ('period_closes','period_closes_reopen'),
    -- ตารางสิทธิ์: **อ่านอย่างเดียว** ไม่มี *_write โดยตั้งใจ (20261007000003)
    -- ถ้ามีใครเพิ่มกลับมา ข้อ "policy เกินที่ตั้งใจ" จะจับได้
    ('roles','roles_read'),
    ('permissions','permissions_read'),
    ('role_permissions','role_permissions_read'),
    -- taxonomy ทรัพย์: เปิด RLS แล้ว (20261007000006) · อ่านอย่างเดียวเช่นกัน
    ('asset_classes','asset_classes_read'),
    ('asset_categories','asset_categories_read');

  select string_agg(p.tablename || '.' || p.policyname, ', ') into v_extra
    from pg_policies p
   where p.schemaname = 'sri_os'
     and p.tablename in (select tbl from t_expect)
     and not exists (select 1 from t_expect e where e.tbl = p.tablename and e.pol = p.policyname);
  if v_extra is not null then
    raise exception 'FAIL: มี policy เกินที่ตั้งใจ (จะ OR ทับสิทธิ์ใหม่): %', v_extra;
  end if;

  select string_agg(e.tbl || '.' || e.pol, ', ') into v_missing
    from t_expect e
   where not exists (
     select 1 from pg_policies p
      where p.schemaname = 'sri_os' and p.tablename = e.tbl and p.policyname = e.pol);
  if v_missing is not null then
    raise exception 'FAIL: policy ที่ต้องมีหายไป (ตารางอาจเข้าถึงไม่ได้เลย): %', v_missing;
  end if;

  -- ห้ามมี policy ของ cmd เดียวกันซ้อนกันบนตารางเดียว
  select string_agg(tablename || ' · ' || cmd || ' ซ้อน ' || c::text || ' ตัว', ', ') into v_dup
    from (
      select tablename, cmd, count(*) c
        from pg_policies
       where schemaname = 'sri_os' and permissive = 'PERMISSIVE'
         and tablename in (select tbl from t_expect)
       group by tablename, cmd
    ) x where c > 1;
  if v_dup is not null then
    raise exception 'FAIL: policy ซ้อน cmd เดียวกัน: %', v_dup;
  end if;

  raise notice 'ok 8 · ตารางที่ดูแลมี policy ครบและไม่เกิน (% ตัว) ไม่มี cmd ซ้อน',
    (select count(*) from t_expect);
end $$;

-- ============================================================
-- 9 · ชั้นการมองเห็น — Manager เห็นแค่ทรัพย์ที่ตัวเองบริหาร · Staff อ่าน ledger ไม่ได้
-- ============================================================

-- ผู้จัดการคนที่สอง เพื่อพิสูจน์ว่าไม่เห็นข้ามกัน
insert into t_uid(label) values ('mgr2');
insert into auth.users(id) select id from t_uid where label = 'mgr2';
insert into sri_os.app_users(id, email, display_name, role)
values (pg_temp.uid('mgr2'), 'mgr2@test.local', 'mgr2', 'manager');
insert into sri_os.user_owner_access(user_id, owner_id)
select pg_temp.uid('mgr2'), id from sri_os.owners where code = 'SRI_CORP';

-- ทรัพย์สามตัว: ของ mgr · ของ mgr2 · ยังไม่มอบหมาย
insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, manager_user_id)
select x.id, x.code, x.name,
       (select class_id from sri_os.asset_categories limit 1),
       (select id from sri_os.asset_categories limit 1),
       (select id from sri_os.owners where code = 'SRI_CORP'),
       x.mgr
  from (values
    ('00000000-0000-0000-0000-00000000a001'::uuid, 'TST-A1', 'ทรัพย์ของ mgr',  pg_temp.uid('mgr')),
    ('00000000-0000-0000-0000-00000000a002'::uuid, 'TST-A2', 'ทรัพย์ของ mgr2', pg_temp.uid('mgr2')),
    ('00000000-0000-0000-0000-00000000a003'::uuid, 'TST-A3', 'ยังไม่มอบหมาย',  null)
  ) as x(id, code, name, mgr);

insert into sri_os.asset_valuations(asset_id, as_of, method, value)
values ('00000000-0000-0000-0000-00000000a001', current_date, 'manual', 1000000),
       ('00000000-0000-0000-0000-00000000a002', current_date, 'manual', 9000000);

-- รายการเงิน 4 แบบ · ทุกอันลงโดย Management (ยกเว้น T4 ที่ mgr ลงเอง)
insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, asset_id, attachments, created_by)
select x.id, (select id from sri_os.owners where code = 'SUTEE'),
       'inc.other', current_date, x.asset_id, array['e.pdf'], x.creator
  from (values
    ('00000000-0000-0000-0000-00000000c001'::uuid, '00000000-0000-0000-0000-00000000a001'::uuid, pg_temp.uid('mgmt')),
    ('00000000-0000-0000-0000-00000000c002'::uuid, '00000000-0000-0000-0000-00000000a002'::uuid, pg_temp.uid('mgmt')),
    ('00000000-0000-0000-0000-00000000c003'::uuid, null,                                          pg_temp.uid('mgmt')),
    ('00000000-0000-0000-0000-00000000c004'::uuid, null,                                          pg_temp.uid('mgr'))
  ) as x(id, asset_id, creator);

-- บรรทัดบัญชี: คู่เดบิต/เครดิตที่ไม่ใช่บัญชีเงินสด (เลี่ยง invariant บรรทัดเงินสด)
insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
select t.id, c.id,
       case when c.rn = 1 then t.amt else 0 end,
       case when c.rn = 2 then t.amt else 0 end
  from (values
    ('00000000-0000-0000-0000-00000000c001'::uuid, 100),
    ('00000000-0000-0000-0000-00000000c002'::uuid, 900),
    ('00000000-0000-0000-0000-00000000c003'::uuid,  10),
    ('00000000-0000-0000-0000-00000000c004'::uuid,   7)
  ) as t(id, amt)
  cross join (
    select id, row_number() over (order by code) rn
      from sri_os.chart_of_accounts
     where code not like '11%' order by code limit 2
  ) c;

-- ใบยืนยันรับ-จ่ายเงิน = ยอดเงินเข้า-ออกจริง · ผูกกับรายการของทรัพย์คนละตัว
insert into sri_os.cash_confirmations(transaction_id, bank_account_id, expected_amount, actual_amount)
values ('00000000-0000-0000-0000-00000000c001', '00000000-0000-0000-0000-0000000000b1', 123456, 123456),
       ('00000000-0000-0000-0000-00000000c002', '00000000-0000-0000-0000-0000000000b1', 999999, 999999);

-- สัญญา + ตารางงวด ผูกทรัพย์คนละตัว (ต้องกรอกครบ ไม่งั้น trg_schedule_complete ปฏิเสธ)
insert into sri_os.contacts(id, first_name, last_name)
values ('00000000-0000-0000-0000-00000000f001', 'คู่สัญญา', 'ทดสอบ');

insert into sri_os.contracts(id, code, asset_id, owner_id, type, counterparty_contact_id,
                             principal, rate, start_date, end_date, file_urls)
values ('00000000-0000-0000-0000-00000000e001', 'TST-CT1',
        '00000000-0000-0000-0000-00000000a001',
        (select id from sri_os.owners where code = 'SRI_CORP'), 'loan_receivable',
        '00000000-0000-0000-0000-00000000f001', 1000000, 5, current_date,
        current_date + 365, array['ct1.pdf']),
       ('00000000-0000-0000-0000-00000000e002', 'TST-CT2',
        '00000000-0000-0000-0000-00000000a002',
        (select id from sri_os.owners where code = 'SRI_CORP'), 'loan_receivable',
        '00000000-0000-0000-0000-00000000f001', 9000000, 5, current_date,
        current_date + 365, array['ct2.pdf']);

insert into sri_os.schedules(contract_id, period, due_date, expected_amount, principal_amount)
values ('00000000-0000-0000-0000-00000000e001', 1, current_date, 1000000, 1000000),
       ('00000000-0000-0000-0000-00000000e002', 1, current_date, 9000000, 9000000);

set local role authenticated;

-- 9.1 assets: Manager เห็นเฉพาะของตัวเอง · ไม่เห็นของ Manager อีกคน · ไม่เห็นที่ยังไม่มอบหมาย
do $$
declare v text;
begin
  perform pg_temp.login('mgr');
  select string_agg(code, ',' order by code) into v
    from sri_os.assets where code like 'TST-%';
  if v is distinct from 'TST-A1' then
    raise exception 'FAIL: Manager ควรเห็นเฉพาะ TST-A1 แต่เห็น %', coalesce(v, '(ไม่เห็นอะไร)');
  end if;

  perform pg_temp.login('mgr2');
  select string_agg(code, ',' order by code) into v
    from sri_os.assets where code like 'TST-%';
  if v is distinct from 'TST-A2' then
    raise exception 'FAIL: Manager คนที่สองควรเห็นเฉพาะ TST-A2 แต่เห็น %', coalesce(v, '(ไม่เห็นอะไร)');
  end if;

  perform pg_temp.login('mgmt');
  if (select count(*) from sri_os.assets where code like 'TST-%') <> 3 then
    raise exception 'FAIL: Management ต้องเห็นทรัพย์ทั้งพอร์ต';
  end if;
  raise notice 'ok 9.1 · Manager เห็นแค่ทรัพย์ที่ตัวเองบริหาร · ทรัพย์ที่ยังไม่มอบหมายไม่เห็น';
end $$;

-- 9.1b ตารางที่การอ่านถูกจำกัดขอบเขต ห้ามมี policy แบบ FOR ALL
--      policy ALL เอา USING ไปใช้กับ SELECT ด้วย = ขอบเขตการอ่านถูกยกเลิกเงียบๆ
--      (lines_write เดิมเป็น ALL/ledger.approve ทำให้ Manager รวมยอดทั้งพอร์ตได้)
do $$
declare v text;
begin
  select string_agg(tablename || '.' || policyname, ', ') into v
    from pg_policies
   where schemaname = 'sri_os'
     and cmd = 'ALL'
     and tablename in ('transactions', 'transaction_lines', 'assets',
                       'asset_valuations', 'draft_entries');
  if v is not null then
    raise exception 'FAIL: policy FOR ALL บนตารางที่การอ่านถูกจำกัดขอบเขต: % → USING จะปล่อย SELECT ทุกแถว', v;
  end if;
  raise notice 'ok 9.1b · ไม่มี policy FOR ALL บนตารางที่การอ่านถูกจำกัดขอบเขต';
end $$;

-- 9.2 Manager รวมยอดทั้งพอร์ตไม่ได้ — ข้อนี้คือหัวใจ กั้นที่ row ไม่ใช่ที่หน้าจอ
do $$
declare v_txn text; v_sum numeric;
begin
  perform pg_temp.login('mgr');
  select string_agg(right(id::text, 4), ',' order by id) into v_txn
    from sri_os.transactions where id::text like '00000000-0000-0000-0000-00000000c%';
  -- c001 = ทรัพย์ที่ดูแล · c004 = ที่ตัวเองลง · c002 (ทรัพย์คนอื่น) และ c003 (ไม่ผูกทรัพย์ คนอื่นลง) ต้องไม่เห็น
  if v_txn is distinct from 'c001,c004' then
    raise exception 'FAIL: Manager ควรเห็น c001,c004 แต่เห็น %', coalesce(v_txn, '(ไม่เห็นอะไร)');
  end if;

  select coalesce(sum(debit), 0) into v_sum from sri_os.transaction_lines;
  if v_sum <> 107 then
    raise exception 'FAIL: Manager รวมยอดได้ % ซึ่งไม่ใช่ 107 (= เฉพาะ c001 + c004) → รวมยอดทั้งพอร์ตได้', v_sum;
  end if;

  if (select count(*) from sri_os.asset_valuations) <> 1 then
    raise exception 'FAIL: Manager เห็นมูลค่าทรัพย์ของคนอื่น';
  end if;

  -- ขาบวก: Management ต้องรวมได้ทั้งพอร์ต ไม่งั้นเทสต์ข้างบนผ่านเพราะปิดตายทุกคน
  perform pg_temp.login('mgmt');
  select coalesce(sum(debit), 0) into v_sum from sri_os.transaction_lines;
  if v_sum < 1017 then
    raise exception 'FAIL: Management รวมยอดทั้งพอร์ตไม่ได้ (ได้ %)', v_sum;
  end if;
  raise notice 'ok 9.2 · Manager รวมยอดได้แค่ส่วนของตัวเอง (107) · Management ได้ทั้งพอร์ต (%)', v_sum;
end $$;

-- 9.3 Staff: อ่าน ledger ไม่ได้เลย แต่อ่านข้อมูลอ้างอิงเพื่อคีย์ได้
do $$
begin
  perform pg_temp.login('staff');
  if (select count(*) from sri_os.transactions) <> 0 then
    raise exception 'FAIL: Staff อ่าน transactions ได้ (ต้องได้ 0 แถวเสมอ)';
  end if;
  if (select count(*) from sri_os.transaction_lines) <> 0 then
    raise exception 'FAIL: Staff อ่าน transaction_lines ได้ = รวมยอดเองได้';
  end if;
  if (select count(*) from sri_os.asset_valuations) <> 0 then
    raise exception 'FAIL: Staff เห็นมูลค่าทรัพย์';
  end if;
  if (select count(*) from sri_os.bank_accounts) = 0 then
    raise exception 'FAIL: Staff อ่านชื่อบัญชีธนาคารไม่ได้ = คีย์รายการไม่ได้';
  end if;
  if (select count(*) from sri_os.assets where code like 'TST-%') <> 3 then
    raise exception 'FAIL: Staff อ่านชื่อทรัพย์ไม่ได้ = เลือกทรัพย์ตอนคีย์ไม่ได้';
  end if;
  if (select count(*) from sri_os.txn_types) = 0 or (select count(*) from sri_os.owners) = 0
     or (select count(*) from sri_os.chart_of_accounts) = 0 then
    raise exception 'FAIL: Staff อ่านตารางอ้างอิงไม่ได้';
  end if;
  raise notice 'ok 9.3 · Staff อ่าน ledger/มูลค่าไม่ได้ แต่อ่านข้อมูลอ้างอิงเพื่อคีย์ได้';
end $$;

-- 9.4 ผู้ใช้ที่ปิดใช้งานต้องไม่ได้สาขาอ้างอิงของ assets ไปด้วย
do $$
begin
  perform pg_temp.login('mgr_inactive');
  if (select count(*) from sri_os.assets) <> 0 then
    raise exception 'FAIL: ผู้ใช้ที่ปิดใช้งานยังเห็นทรัพย์';
  end if;
  raise notice 'ok 9.4 · ผู้ใช้ที่ปิดใช้งานไม่เห็นอะไรเลย';
end $$;

-- 9.5 ร่าง: คนที่ไม่มี ledger.read เห็นแค่ของตัวเอง
do $$
declare n_staff int; n_mgr int;
begin
  perform pg_temp.login('staff');
  select count(*) into n_staff from sri_os.draft_entries;
  if n_staff = 0 then raise exception 'FAIL: Staff ไม่เห็นร่างของตัวเอง'; end if;
  if exists (select 1 from sri_os.draft_entries where created_by is distinct from pg_temp.uid('staff')) then
    raise exception 'FAIL: Staff เห็นร่างของคนอื่น';
  end if;

  perform pg_temp.login('mgr');
  select count(*) into n_mgr from sri_os.draft_entries;
  if n_mgr < n_staff then raise exception 'FAIL: Manager เห็นคิวร่างไม่ครบ (มี ledger.read)'; end if;
  raise notice 'ok 9.5 · Staff เห็นร่างแค่ของตัวเอง · Manager เห็นคิวทั้งขอบเขต owner';
end $$;

-- 9.6 Manager ต้องอ่านแถวที่ตัวเองเพิ่งลงได้ (insert ... returning ต้องผ่าน policy ฝั่ง select)
do $$
declare v uuid;
begin
  perform pg_temp.login('mgr');
  insert into sri_os.transactions(owner_id, txn_type_code, doc_date)
  select id, 'inc.other', current_date from sri_os.owners where code = 'SUTEE'
  returning id into v;
  if v is null then raise exception 'FAIL: Manager อ่านรายการที่ตัวเองเพิ่งลงไม่ได้'; end if;

  -- เส้นทาง post จริงเขียนบรรทัดบัญชีต่อท้ายและอ่านกลับด้วย ต้องไม่ติด policy
  insert into sri_os.transaction_lines(transaction_id, coa_id, debit)
  select v, id, 50 from sri_os.chart_of_accounts where code not like '11%' order by code limit 1
  returning id into v;
  if v is null then raise exception 'FAIL: Manager อ่านบรรทัดบัญชีที่ตัวเองเพิ่งลงไม่ได้'; end if;
  raise notice 'ok 9.6 · created_by default auth.uid() ทำให้ insert ... returning (หัวรายการ + บรรทัด) ใช้ได้';
end $$;

-- 9.7 view ต้องไม่เป็นทางลัดข้าม RLS — NAV ทั้งพอร์ตเคยรั่วทางนี้
--     A1 = 1,000,000 (ของ mgr) · A2 = 9,000,000 (ของ mgr2)
do $$
declare v_direct numeric; v_view numeric;
begin
  perform pg_temp.login('mgr');
  select coalesce(sum(value), 0) into v_direct from sri_os.asset_valuations;
  select coalesce(sum(value), 0) into v_view   from sri_os.v_asset_latest_value;
  if v_view <> v_direct or v_view <> 1000000 then
    raise exception 'FAIL: Manager อ่าน view ได้ % แต่อ่านตารางตรงๆ ได้ % (ต้องเท่ากันและเป็น 1000000) → NAV รั่วผ่าน view', v_view, v_direct;
  end if;

  perform pg_temp.login('staff');
  select coalesce(sum(value), 0) into v_view from sri_os.v_asset_latest_value;
  if v_view <> 0 then
    raise exception 'FAIL: Staff อ่านมูลค่าผ่าน view ได้ %', v_view;
  end if;

  perform pg_temp.login('mgmt');
  select coalesce(sum(value), 0) into v_view from sri_os.v_asset_latest_value;
  if v_view <> 10000000 then
    raise exception 'FAIL: Management ต้องเห็น NAV ทั้งพอร์ต (ได้ %)', v_view;
  end if;
  raise notice 'ok 9.7 · view เคารพ RLS · Manager 1,000,000 · Staff 0 · Management 10,000,000';
end $$;

-- 9.8 contracts / schedules ต้องมีขอบเขตทรัพย์ ไม่ใช่กั้นแค่ owner
do $$
declare v numeric; v_s numeric;
begin
  perform pg_temp.login('mgr');
  select coalesce(sum(principal), 0) into v from sri_os.contracts where code like 'TST-CT%';
  select coalesce(sum(principal_amount), 0) into v_s from sri_os.schedules;
  if v <> 1000000 or v_s <> 1000000 then
    raise exception 'FAIL: Manager รวมสัญญาได้ % / งวด % (ต้อง 1000000 ทั้งคู่)', v, v_s;
  end if;

  perform pg_temp.login('staff');
  select coalesce(sum(principal), 0) into v from sri_os.contracts;
  select coalesce(sum(principal_amount), 0) into v_s from sri_os.schedules;
  if v <> 0 or v_s <> 0 then
    raise exception 'FAIL: Staff อ่านสัญญา/งวดได้ % / %', v, v_s;
  end if;

  perform pg_temp.login('mgmt');
  select coalesce(sum(principal), 0) into v from sri_os.contracts where code like 'TST-CT%';
  if v <> 10000000 then
    raise exception 'FAIL: Management ต้องเห็นสัญญาทั้งพอร์ต (ได้ %)', v;
  end if;
  raise notice 'ok 9.8 · สัญญา/งวด: Manager 1,000,000 · Staff 0 · Management 10,000,000';
end $$;

-- 9.9 ใบยืนยันรับ-จ่าย = ยอดเงินจริง · เดิมกั้นแค่ owner ของบัญชีธนาคาร → Staff เห็น 123,456
do $$
declare v numeric;
begin
  perform pg_temp.login('staff');
  select coalesce(sum(expected_amount), 0) into v from sri_os.cash_confirmations;
  if v <> 0 then
    raise exception 'FAIL: Staff เห็นยอดเงินเข้า-ออกจริง % (ต้อง 0)', v;
  end if;

  -- Manager เห็นได้เฉพาะของเอกสารที่ตัวเองมองเห็น (ทรัพย์ที่ดูแล) ไม่ใช่ทุกใบในบัญชีเดียวกัน
  perform pg_temp.login('mgr');
  -- นับเฉพาะใบที่ผูกกับรายการเงิน (ใบที่ผูกร่างมีจากเทสต์ 7.1 และ Manager เห็นร่างได้ตามขอบเขต owner)
  select coalesce(sum(expected_amount), 0) into v
    from sri_os.cash_confirmations where transaction_id is not null;
  if v <> 123456 then
    raise exception 'FAIL: Manager เห็นใบยืนยันรวม % (ต้อง 123456 เฉพาะของทรัพย์ที่ดูแล)', v;
  end if;

  perform pg_temp.login('mgmt');
  select coalesce(sum(expected_amount), 0) into v from sri_os.cash_confirmations;
  if v < 1123455 then
    raise exception 'FAIL: Management ต้องเห็นใบยืนยันทั้งหมด (ได้ %)', v;
  end if;
  raise notice 'ok 9.9 · ใบยืนยันรับ-จ่าย: Staff 0 · Manager 123,456 · Management ทั้งหมด';
end $$;

reset role;

-- ============================================================
-- 10 · กฎเงินต้องไม่ขึ้นกับตารางสิทธิ์
--   CHECK กันชื่อคีย์เป็นแค่การกันพลาด (txn.delete · lines.remove ผ่านได้)
--   สิ่งที่กันได้จริงคือ **trigger ที่บังคับกฎเงินไม่เรียก fn_can เลย**
--   ไม่ว่าใครจะสร้างคีย์ชื่ออะไรในตาราง permissions ก็ปิดกฎไม่ได้
-- ============================================================
do $$
declare v text; n int;
begin
  select string_agg(distinct p.proname, ', '), count(distinct p.proname) into v, n
    from pg_trigger tg
    join pg_class c  on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    join pg_proc p   on p.oid = tg.tgfoid
   where ns.nspname = 'sri_os' and not tg.tgisinternal
     and p.prosrc ~* 'fn_can';
  if v is not null then
    raise exception 'FAIL: trigger function อ้างถึง fn_can — กฎเงินจะถูกปิดได้จากหน้า Settings: %', v;
  end if;

  select count(distinct p.proname) into n
    from pg_trigger tg
    join pg_class c  on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    join pg_proc p   on p.oid = tg.tgfoid
   where ns.nspname = 'sri_os' and not tg.tgisinternal;
  if n < 8 then
    raise exception 'FAIL: นับ trigger function ได้แค่ % ตัว เทสต์นี้อาจไม่ได้ตรวจอะไรเลย', n;
  end if;
  raise notice 'ok 10 · trigger function ทั้ง % ตัวไม่มีตัวไหนเรียก fn_can', n;
end $$;

-- ทุก view ในสคีมาต้องตั้ง security_invoker ไม่งั้นเป็นทางลัดข้าม RLS
do $$
declare v text; n int;
begin
  select string_agg(c.relname, ', '), count(*) into v, n
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os' and c.relkind in ('v', 'm')
     and not coalesce(array_to_string(c.reloptions, ',') ilike '%security_invoker=true%', false);
  if v is not null then
    raise exception 'FAIL: view ที่ไม่ได้ตั้ง security_invoker (% ตัว): %', n, v;
  end if;
  raise notice 'ok 10b · view ทุกตัวในสคีมาตั้ง security_invoker แล้ว';
end $$;

do $$ begin raise notice '=== ผ่านทั้งหมด ==='; end $$;

rollback;
