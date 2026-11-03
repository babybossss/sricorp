-- ============================================================
-- SRI OS · เทสต์สองช่องที่ W2 รายงานไว้แต่ยังไม่ได้ปิด
--   (1) ประวัติการตีราคา `asset_valuations` ลบได้ด้วยสิทธิ์เจ้าของฐานข้อมูล
--       (RLS กันแต่ authenticated · ไม่มี trigger → postgres/service_role ลบได้)
--   (2) `fn_health_check` ไม่เคยเตือนทรัพย์ที่ "ยังไม่เคยตีราคาเลย"
--       (is_stale = NULL → `where is_stale` คัดทิ้งเงียบๆ)
-- ปิดด้วย supabase/migrations/20261008000002_valuation_delete_guard.sql
--
-- รันในเครื่อง:  bash scripts/test-rls-local.sh
--   ไฟล์ใหม่ต้องอยู่ใน UNDER_TEST ด้วย ไม่งั้น 20261007000007 จะทับ fn_health_check
--   กลับเป็นรุ่น 4 ข้อ แล้วเทสต์ G7–G12 แดงโดยไม่เกี่ยวกับโค้ด:
--   UNDER_TEST="... 20261008000001_valuation_revision.sql 20261008000002_valuation_delete_guard.sql" \
--     bash scripts/test-rls-local.sh
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ rollback ปิดท้าย · เจอข้อผิด = raise exception
--
-- สามแบบของการ "ถูกปฏิเสธ" ที่ต้องแยกให้ออก ไม่งั้นเทสต์ผ่านฟรีๆ:
--   RLS ไม่มี policy DELETE → **0 แถว ไม่ใช่ error** → ต้องเช็ค row_count
--   ไม่มี grant               → insufficient_privilege (ไม่ได้แตะ trigger เลย)
--   trigger ปฏิเสธ            → raise_exception + **แถวต้องยังอยู่**
-- ทุกข้อจึงนับแถวก่อน/หลังด้วย ไม่เชื่อแค่ข้อความ error
--
-- สิ่งที่ไฟล์นี้ต้องจับได้ (ไล่จาก "ถ้าถอดการแก้ออกแล้วต้องแดง"):
--   M1 ไม่มี trigger กัน DELETE                → G1 G2 G3 G5 แดง
--   M2 กัน DELETE ด้วย RLS/revoke แทน trigger   → G2 แดง (role ที่ bypassrls + มี grant)
--   M3 ไม่กัน TRUNCATE                         → G4 แดง
--   M4 fn_health_check ยัง 4 ข้อ (ไม่มีธงใหม่)   → G7 G8 G11 แดง
--   M5 ยุบ "ไม่เคยตีราคา" รวมกับธง "ราคาเก่า"    → G8 G9 G10 แดง (แยกธงไม่ออก)
--   M6 ธงใหม่ใช้ `where is_stale` (ของเดิม)      → G8 แดง (ทรัพย์ที่ไม่เคยตีราคาเงียบอีก)
--   M7 เอาด่านสิทธิ์ใน fn_health_check ออก       → G12 แดง
--   M8 ลืม revoke execute ของ trigger function  → G0 แดง
-- ============================================================

begin;

-- ---------- fixtures ----------
create temporary table t_guid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_guid(label) values ('g_super'), ('g_mgmt'), ('g_mgr'), ('g_staff'), ('g_ghost');
insert into auth.users(id) select id from t_guid;

insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, u.label || '@guard.local', u.label, x.role, true
  from t_guid u
  join (values ('g_super', 'super_admin'), ('g_mgmt', 'management'),
               ('g_mgr', 'manager'), ('g_staff', 'staff')) as x(label, role)
    on x.label = u.label;   -- 'g_ghost' ไม่มีแถวใน app_users โดยตั้งใจ

create or replace function pg_temp.guid(p_label text) returns uuid
language sql stable as $fn$ select id from t_guid where label = p_label $fn$;

create or replace function pg_temp.glogin(p_label text) returns void
language sql as $fn$
  select set_config('test.uid', coalesce((select id::text from t_guid where label = p_label), ''), true);
$fn$;

do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.t_guid to authenticated', s);
end $$;

-- Manager/Staff ต้องเห็น Entity นี้ ไม่งั้นเทสต์ RLS ผ่านเพราะมองไม่เห็นอะไรเลย
insert into sri_os.user_owner_access(user_id, owner_id)
select u.id, o.id from t_guid u cross join sri_os.owners o
 where u.label in ('g_mgr', 'g_staff') and o.code = 'SRI_CORP'
on conflict do nothing;

-- ทรัพย์ของชุด DELETE (G1–G6) · ทรัพย์ของชุด health check อยู่ใน G7+ (สร้างทีละตัว
-- เพื่อคุมสภาพให้เห็นว่าแต่ละธงขึ้นจากอะไร)
insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, manager_user_id)
select x.id, x.code, x.name, cat.class_id, cat.id, o.id, pg_temp.guid('g_mgr')
  from (values
    ('00000000-0000-0000-0000-0000000e0001'::uuid, 'GRD-D1', 'มีประวัติตีราคา'),
    ('00000000-0000-0000-0000-0000000e0002'::uuid, 'GRD-D2', 'ไม่มีประวัติตีราคา')
  ) as x(id, code, name)
  cross join (select id, class_id from sri_os.asset_categories order by id limit 1) cat
  cross join (select id from sri_os.owners where code = 'SRI_CORP') o;

-- ประวัติสามแถวของทรัพย์ D1: วันเดิมวิธีเดิมสองครั้ง (revision 1,2) + อีกวิธีหนึ่ง
insert into sri_os.asset_valuations(asset_id, as_of, method, value)
values ('00000000-0000-0000-0000-0000000e0001', current_date - 2, 'appraisal', 100),
       ('00000000-0000-0000-0000-0000000e0001', current_date - 2, 'appraisal', 180),
       ('00000000-0000-0000-0000-0000000e0001', current_date - 2, 'manual',    170);

-- กันเทสต์เปล่า: ถ้า fixture ไม่ครบ ทุกข้อข้างล่าง "ลบได้ 0 แถว" แล้วผ่านฟรีๆ
do $$
declare n int;
begin
  select count(*) into n from sri_os.asset_valuations
   where asset_id = '00000000-0000-0000-0000-0000000e0001';
  if n <> 3 then
    raise exception 'FAIL: fixture ประวัติตีราคาต้องมี 3 แถว (ได้ %) — เทสต์ DELETE จะไม่ได้ตรวจอะไร', n;
  end if;
end $$;

-- ============================================================
-- G0 · โครงสร้าง: trigger กัน DELETE ต้องมีอยู่จริงบน asset_valuations
--      ไล่จาก pg_trigger ไม่ใช่เชื่อว่าไฟล์ migration รันแล้ว
--      และ trigger function ต้องเรียกจากข้างนอกไม่ได้ (ของใหม่ต้องไม่หลวมกว่าของเดิม)
-- ============================================================
do $$
declare v text; n int;
begin
  select count(*) into n
    from pg_trigger tg
    join pg_proc p on p.oid = tg.tgfoid
   where tg.tgrelid = 'sri_os.asset_valuations'::regclass
     and not tg.tgisinternal
     and (tg.tgtype & 8) <> 0      -- DELETE
     and (tg.tgtype & 2) <> 0      -- BEFORE
     and (tg.tgtype & 1) <> 0;     -- FOR EACH ROW
  if n < 1 then
    raise exception 'FAIL: ไม่มี before delete for each row trigger บน asset_valuations → เจ้าของฐานข้อมูลลบประวัติราคาได้';
  end if;

  -- TRUNCATE ไม่ยิง row trigger → ต้องมี statement trigger ของตัวเองด้วย
  select count(*) into n
    from pg_trigger tg
   where tg.tgrelid = 'sri_os.asset_valuations'::regclass
     and not tg.tgisinternal
     and (tg.tgtype & 32) <> 0;    -- TRUNCATE
  if n < 1 then
    raise exception 'FAIL: ไม่มี truncate trigger บน asset_valuations → ล้างประวัติราคาทั้งตารางได้ในคำสั่งเดียว';
  end if;

  -- ฟังก์ชันกัน DELETE ต้องไม่เปิดให้เรียกตรง และต้องไม่เป็น SECURITY DEFINER
  -- (การห้ามลบไม่ต้องอ่านตารางอะไรเลย จึงไม่มีเหตุให้ยกสิทธิ์)
  -- เช็คเฉพาะ trigger ของไฟล์นี้: fn_valuation_revision เป็น SECURITY DEFINER
  -- โดยเจตนา (ต้องนับ max(revision) ข้าม RLS — ดู 20261008000001)
  select string_agg(p.proname, ', ') into v
    from pg_trigger tg
    join pg_proc p on p.oid = tg.tgfoid
   where tg.tgrelid = 'sri_os.asset_valuations'::regclass
     and tg.tgname = 'trg_forbid_delete_valuation'
     and (has_function_privilege('public', p.oid, 'execute')
       or has_function_privilege('anon', p.oid, 'execute')
       or has_function_privilege('authenticated', p.oid, 'execute')
       or p.prosecdef);
  if v is not null then
    raise exception 'FAIL: ฟังก์ชันกัน DELETE เปิดให้เรียกตรง/เป็น SECURITY DEFINER: %', v;
  end if;

  -- ชื่อ trigger ต้องตรงกับที่ guard ข้างบนใช้ ไม่งั้นเช็ค ACL ข้างบนเงียบ
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'sri_os.asset_valuations'::regclass
                    and tgname = 'trg_forbid_delete_valuation') then
    raise exception 'FAIL: ไม่มี trigger ชื่อ trg_forbid_delete_valuation → เช็ค ACL ข้างบนไม่ได้ตรวจอะไร';
  end if;
  raise notice 'ok G0 · มี trigger กัน DELETE + TRUNCATE บน asset_valuations · ACL ปิดถูก';
end $$;

-- ============================================================
-- G1 · superuser ของคลัสเตอร์ (เจ้าของตาราง · ข้าม RLS) ลบไม่ได้
--      นี่คือช่องที่ W2 รายงานไว้ตรงๆ · RLS กันไม่ถึงชั้นนี้
--      และต้อง **ยืนยันว่าแถวยังอยู่** ไม่ใช่แค่ได้ error
-- ============================================================
reset role;
do $$
declare n_before int; n_after int; v_msg text := '';
begin
  select count(*) into n_before from sri_os.asset_valuations;

  begin
    delete from sri_os.asset_valuations
     where asset_id = '00000000-0000-0000-0000-0000000e0001' and value = 100;
    raise exception 'FAIL: superuser ลบประวัติการตีราคาได้ → แก้ไม่ได้แต่ลบได้ = แก้ได้ (ลบแล้วใส่ใหม่)';
  exception
    when raise_exception then
      if sqlerrm like 'FAIL:%' then raise; end if;
      v_msg := sqlerrm;
  end;

  -- "ไม่ส่งเงื่อนไข" — ลบทั้งตารางรวดเดียวก็ต้องล้มเหมือนกัน
  begin
    delete from sri_os.asset_valuations;
    raise exception 'FAIL: superuser ลบประวัติการตีราคาทั้งตารางได้';
  exception
    when raise_exception then
      if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  select count(*) into n_after from sri_os.asset_valuations;
  if n_after <> n_before or n_before = 0 then
    raise exception 'FAIL: จำนวนแถวเปลี่ยนจาก % เป็น % (หรือ fixture ว่าง) → error ขึ้นแต่ของหายจริง', n_before, n_after;
  end if;
  if not exists (select 1 from sri_os.asset_valuations
                  where asset_id = '00000000-0000-0000-0000-0000000e0001' and value = 100) then
    raise exception 'FAIL: แถวเป้าหมายหายไปแล้ว ทั้งที่ขึ้น error';
  end if;
  raise notice 'ok G1 · superuser ลบไม่ได้ทั้งแบบระบุแถวและแบบไม่ใส่เงื่อนไข · แถวยังอยู่ครบ % แถว (%)',
    n_after, left(v_msg, 60);
end $$;

-- ============================================================
-- G2 · role ที่มี grant ครบ + BYPASSRLS (เท่ากับ service_role ของจริง)
--      ต้องลบไม่ได้เหมือนกัน — ถ้ากันด้วย RLS/grant เพียงอย่างเดียวจะหลุดที่ข้อนี้
--      harness ในเครื่องสร้าง service_role แบบไม่มี grant และไม่มี bypassrls
--      → ถ้าทดสอบด้วย service_role ตรงๆ จะได้ insufficient_privilege แล้วผ่านฟรีๆ
--      จึงสร้าง role ที่ "แรงเท่าของจริง" ขึ้นมาเองในธุรกรรมนี้ (rollback ทิ้งท้ายไฟล์)
-- ============================================================
do $$
declare r_name text := 'guard_svc_' || pg_backend_pid(); n_before int; n_after int;
begin
  execute format('create role %I bypassrls', r_name);
  execute format('grant usage on schema sri_os to %I', r_name);
  execute format('grant select, insert, update, delete on sri_os.asset_valuations to %I', r_name);
  select count(*) into n_before from sri_os.asset_valuations;

  execute format('set local role %I', r_name);
  begin
    -- ขาบวกของ fixture: role นี้ต้อง **มองเห็น** แถวจริง (ไม่งั้น 0 แถวแล้วผ่านฟรีๆ)
    if (select count(*) from sri_os.asset_valuations) <> n_before then
      raise exception 'FAIL: role ที่ bypassrls มองไม่เห็นแถว — เทสต์นี้ไม่ได้ตรวจอะไร';
    end if;
    delete from sri_os.asset_valuations where value = 180;
    raise exception 'FAIL: role ที่มี grant + bypassrls ลบประวัติการตีราคาได้';
  exception
    when raise_exception then
      reset role;
      if sqlerrm like 'FAIL:%' then raise; end if;
    when insufficient_privilege then
      reset role;
      raise exception 'FAIL: ถูกปฏิเสธด้วย insufficient_privilege (grant) ไม่ใช่ trigger → เทสต์นี้ไม่ได้พิสูจน์ว่ามี trigger';
  end;
  reset role;

  select count(*) into n_after from sri_os.asset_valuations;
  if n_after <> n_before then
    raise exception 'FAIL: แถวหายไป % แถว', n_before - n_after;
  end if;
  execute format('revoke all on sri_os.asset_valuations from %I', r_name);
  execute format('revoke usage on schema sri_os from %I', r_name);
  execute format('drop role %I', r_name);
  raise notice 'ok G2 · role ที่แรงเท่า service_role (grant ครบ + bypassrls) ลบไม่ได้ · แถวยังอยู่ครบ';
end $$;

-- ============================================================
-- G3 · ทุกตำแหน่งในแอป (รวม super_admin) ลบไม่ได้
--      ชั้นนี้ RLS กันอยู่แล้ว = **0 แถว ไม่ใช่ error** → ต้องเช็ค row_count
--      (ไม่ถดถอยจาก S13 ของ zz_asset_permissions_test)
-- ============================================================
set local role authenticated;
do $$
declare r text; n int; n_before int; n_after int;
begin
  perform pg_temp.glogin('g_mgmt');
  select count(*) into n_before from sri_os.asset_valuations;
  if n_before = 0 then
    raise exception 'FAIL: management มองไม่เห็นประวัติราคาเลย — เทสต์ G3 ไม่ได้ตรวจอะไร';
  end if;

  foreach r in array array['g_staff', 'g_mgr', 'g_mgmt', 'g_super'] loop
    perform pg_temp.glogin(r);
    begin
      delete from sri_os.asset_valuations
       where asset_id = '00000000-0000-0000-0000-0000000e0001';
      get diagnostics n = row_count;
      if n <> 0 then
        raise exception 'FAIL: % ลบประวัติการตีราคาได้ % แถว', r, n;
      end if;
    exception
      when insufficient_privilege then null;
      when raise_exception then
        if sqlerrm like 'FAIL:%' then raise; end if;   -- trigger ปฏิเสธก็ถือว่าผ่าน
    end;
  end loop;

  perform pg_temp.glogin('g_mgmt');
  select count(*) into n_after from sri_os.asset_valuations;
  if n_after <> n_before then
    raise exception 'FAIL: แถวหายไป % แถว', n_before - n_after;
  end if;
  raise notice 'ok G3 · ทุกตำแหน่งรวม super_admin ลบไม่ได้ · แถวยังอยู่ครบ % แถว', n_after;
end $$;
reset role;

-- ============================================================
-- G4 · TRUNCATE (ไม่ยิง row trigger ไม่ผ่าน RLS) ต้องล้มในฐานะ superuser
-- ============================================================
do $$
declare n_before int; n_after int;
begin
  select count(*) into n_before from sri_os.asset_valuations;
  begin
    truncate table sri_os.asset_valuations cascade;
    raise exception 'FAIL: TRUNCATE asset_valuations สำเร็จ = ล้างประวัติราคาทั้งตารางได้รวดเดียว';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  select count(*) into n_after from sri_os.asset_valuations;
  if n_after <> n_before or n_after = 0 then
    raise exception 'FAIL: แถวเหลือ % จาก % → TRUNCATE ลงไปแล้ว', n_after, n_before;
  end if;
  raise notice 'ok G4 · TRUNCATE ล้ม · แถวยังอยู่ครบ % แถว', n_after;
end $$;

-- ============================================================
-- G5 · ทางอ้อม: asset_valuations.asset_id มี ON DELETE CASCADE
--      ลบทรัพย์ทิ้ง = ประวัติราคาหายตามไปด้วยโดยไม่ต้องสั่ง DELETE ตรงๆ
--      → ต้องล้มด้วย และทรัพย์ต้องยังอยู่
-- ============================================================
do $$
declare n int;
begin
  begin
    delete from sri_os.assets where id = '00000000-0000-0000-0000-0000000e0001';
    raise exception 'FAIL: ลบทรัพย์ที่มีประวัติราคาได้ → cascade ล้างประวัติราคาไปเงียบๆ';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  if not exists (select 1 from sri_os.assets where id = '00000000-0000-0000-0000-0000000e0001') then
    raise exception 'FAIL: ทรัพย์หายไปแล้ว ทั้งที่ขึ้น error';
  end if;
  select count(*) into n from sri_os.asset_valuations
   where asset_id = '00000000-0000-0000-0000-0000000e0001';
  if n <> 3 then
    raise exception 'FAIL: ประวัติราคาเหลือ % แถว (ต้อง 3)', n;
  end if;
  raise notice 'ok G5 · ลบทรัพย์ที่มีประวัติราคาไม่ได้ (cascade ชนด่านเดียวกัน) · ประวัติยังครบ 3 แถว';
end $$;

-- ============================================================
-- G6 · ไม่ถดถอย: UPDATE ยังถูกปฏิเสธ · INSERT revision ใหม่ยังทำได้
--      "ลบไม่ได้" ต้องไม่กลายเป็น "แก้ไม่ได้ ลงใหม่ก็ไม่ได้" = เปิดครึ่งเดียว
--      + เคสไม่ส่งข้อมูล: DELETE ที่ไม่ตรงแถวไหนเลย = 0 แถว ไม่ error (ไม่มีอะไรหาย)
-- ============================================================
do $$
declare v_rev int; n int;
begin
  -- UPDATE ยังล้ม (20261008000001 · append-only)
  begin
    update sri_os.asset_valuations set value = 777
     where asset_id = '00000000-0000-0000-0000-0000000e0001' and value = 100;
    raise exception 'FAIL: update ราคาทับแถวเดิมได้ → ถดถอยจาก 20261008000001';
  exception when check_violation then null;
  end;

  -- INSERT revision ถัดไปยังทำได้ (ทางออกที่ถูกต้องของราคาที่ตีผิด)
  insert into sri_os.asset_valuations(asset_id, as_of, method, value)
  values ('00000000-0000-0000-0000-0000000e0001', current_date - 2, 'appraisal', 190)
  returning revision into v_rev;
  if v_rev <> 3 then
    raise exception 'FAIL: ลง revision ถัดไปได้ % (ต้อง 3) → ทางออกแทนการลบใช้ไม่ได้', v_rev;
  end if;
  -- เทียบที่ v_asset_valuation_current (ต่อวัน/ต่อวิธี) เพราะเป็นข้อรับประกันจริง
  -- ไม่เทียบที่ v_asset_latest_value: ทรัพย์นี้มีสองวิธีในวันเดียวกันและ created_at
  -- เท่ากันหมด (ธุรกรรมเดียว) → ตัวชนะมาจาก tie-break ท้ายๆ ที่ห้ามพึ่งพา
  if (select value from sri_os.v_asset_valuation_current
       where asset_id = '00000000-0000-0000-0000-0000000e0001'
         and method = 'appraisal' and as_of = current_date - 2) <> 190 then
    raise exception 'FAIL: ราคาที่ยังมีผลของ (วันนั้น, appraisal) ไม่ใช่ revision ใหม่';
  end if;

  -- DELETE ที่ไม่ตรงแถวไหนเลย: trigger เป็น for each row → ไม่มีแถว = ไม่มี error
  -- เขียนไว้ให้ชัดว่าเป็นพฤติกรรมที่รู้ตัว ไม่ใช่ช่อง (ไม่มีแถวไหนหาย)
  delete from sri_os.asset_valuations where value = -1;
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'FAIL: ลบแถวที่ไม่มีอยู่ได้ % แถว', n;
  end if;
  if (select count(*) from sri_os.asset_valuations
       where asset_id = '00000000-0000-0000-0000-0000000e0001') <> 4 then
    raise exception 'FAIL: จำนวนประวัติราคาไม่ใช่ 4 แถวหลังลง revision ใหม่';
  end if;
  raise notice 'ok G6 · UPDATE ยังล้ม · INSERT revision ใหม่ยังได้ (ทางออกแทนการลบ) · DELETE ที่ไม่ตรงแถว = 0 แถวเงียบๆ';
end $$;

-- ============================================================
-- ชุดที่สอง · fn_health_check ต้องเตือนทรัพย์ที่ "ยังไม่เคยตีราคาเลย"
--
-- สภาพตั้งต้นที่ยกมาจากชุดแรก (ตั้งใจใช้ต่อ ไม่สร้างใหม่):
--   GRD-D1 = ตีราคาแล้ว as_of = วันนี้-2 → ไม่เก่า (เกณฑ์เก่า = > 7 วัน)
--   GRD-D2 = ยังไม่เคยตีราคาเลย         → ต้องขึ้นธง "ไม่เคยตี" แต่ **ไม่ใช่** ธง "เก่า"
-- ============================================================
create or replace function pg_temp.hc_ok(p_name text) returns boolean
language plpgsql as $fn$
declare v boolean;
begin
  select ok into v from sri_os.fn_health_check() where check_name = p_name;
  if not found then
    raise exception 'FAIL: fn_health_check ไม่มีข้อ "%" → ธงนี้ไม่มีอยู่ในรายงานเลย', p_name;
  end if;
  return v;
end $fn$;

create or replace function pg_temp.hc_detail(p_name text) returns text
language sql as $fn$
  select detail from sri_os.fn_health_check() where check_name = p_name;
$fn$;

set local role authenticated;

-- ============================================================
-- G7 · รูปผลลัพธ์: 4 ข้อเดิมต้องอยู่ตำแหน่งเดิม + ธงใหม่ต่อท้าย
--      (ของเดิมที่เรียกใช้ต้องไม่พัง · ธงใหม่ต้องเป็น "อีกข้อหนึ่ง" ไม่ใช่ข้อเดิมที่ถูกแก้ความหมาย)
-- ============================================================
do $$
declare v text; n int;
begin
  perform pg_temp.glogin('g_mgmt');
  select count(*), string_agg(check_name, ',' order by ord) into n, v
    from (select check_name, row_number() over () as ord from sri_os.fn_health_check()) x;
  if v <> 'transactions_balanced,no_floating_cash,contracts_complete,valuations_fresh,valuations_present' then
    raise exception 'FAIL: รายชื่อ/ลำดับข้อของ fn_health_check เปลี่ยนเป็น % → หน้า Data health และเทสต์เดิมพัง', v;
  end if;
  if n <> 5 then
    raise exception 'FAIL: fn_health_check คืน % ข้อ (ต้อง 5)', n;
  end if;
  raise notice 'ok G7 · fn_health_check = 4 ข้อเดิม (ตำแหน่งเดิม) + valuations_present ต่อท้าย';
end $$;

-- ============================================================
-- G8 · ทรัพย์ที่ยังไม่เคยตีราคา → เตือน และเป็น **ธงแยก** จาก "ราคาเก่า"
--      นี่คือช่องที่ W2 รายงานไว้: is_stale = NULL ถูก `where is_stale` คัดทิ้งเงียบๆ
-- ============================================================
do $$
declare v_detail text;
begin
  perform pg_temp.glogin('g_mgmt');
  if pg_temp.hc_ok('valuations_present') then
    raise exception 'FAIL: มีทรัพย์ที่ยังไม่เคยตีราคา (GRD-D2) แต่ fn_health_check บอกว่าปกติ → เงียบหายจากรายงาน';
  end if;
  if not pg_temp.hc_ok('valuations_fresh') then
    raise exception 'FAIL: ไม่มีทรัพย์ที่ราคาเก่าเลย แต่ธง valuations_fresh แดง → สองเรื่องถูกยุบเป็นธงเดียว (วิธีแก้ต่างกัน)';
  end if;
  v_detail := pg_temp.hc_detail('valuations_present');
  if v_detail not like '%GRD-D2%' then
    raise exception 'FAIL: detail ของธงใหม่ไม่บอกว่าทรัพย์ตัวไหน (ได้ "%") → รู้ว่าแดงแต่ตามแก้ไม่ได้', v_detail;
  end if;
  if v_detail like '%GRD-D1%' then
    raise exception 'FAIL: detail นับทรัพย์ที่ตีราคาแล้ว (GRD-D1) ด้วย: "%"', v_detail;
  end if;
  raise notice 'ok G8 · ทรัพย์ที่ไม่เคยตีราคาขึ้นธง valuations_present (แดง) · ธง valuations_fresh ยังเขียว · detail บอกรหัสทรัพย์';
end $$;

-- ============================================================
-- G9 · ตีราคาให้ครบแล้วธงต้องกลับเขียวเอง (คำนวณสด ไม่ใช่ค่าค้าง)
--      และทรัพย์ที่ตีราคาแล้วไม่นาน **ไม่เตือน** ทั้งสองธง
-- ============================================================
reset role;
insert into sri_os.asset_valuations(asset_id, as_of, method, value)
values ('00000000-0000-0000-0000-0000000e0002', current_date, 'manual', 50);
set local role authenticated;

do $$
begin
  perform pg_temp.glogin('g_mgmt');
  if not pg_temp.hc_ok('valuations_present') then
    raise exception 'FAIL: ตีราคาครบทุกตัวแล้วธง valuations_present ยังแดง: %', pg_temp.hc_detail('valuations_present');
  end if;
  if not pg_temp.hc_ok('valuations_fresh') then
    raise exception 'FAIL: ราคาทุกตัวยังใหม่แต่ธง valuations_fresh แดง: %', pg_temp.hc_detail('valuations_fresh');
  end if;
  raise notice 'ok G9 · ทรัพย์ที่ตีราคาแล้วไม่นาน = ไม่เตือนทั้งสองธง · ธงกลับเขียวเองเมื่อแก้ที่ต้นเหตุ';
end $$;

-- ============================================================
-- G10 · ทรัพย์ที่ตีราคาแล้วนานมาก → เตือนด้วยธง "เก่า" **ไม่ใช่** ธง "ไม่เคยตี"
--       (คนละเรื่อง วิธีแก้ต่างกัน: ตัวนี้ต้องตีราคาใหม่ ไม่ใช่ตีราคาครั้งแรก)
-- ============================================================
reset role;
insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, manager_user_id)
select '00000000-0000-0000-0000-0000000e0003', 'GRD-D3', 'ราคาเก่ามาก',
       cat.class_id, cat.id, o.id, pg_temp.guid('g_mgr')
  from (select id, class_id from sri_os.asset_categories order by id limit 1) cat
  cross join (select id from sri_os.owners where code = 'SRI_CORP') o;
insert into sri_os.asset_valuations(asset_id, as_of, method, value)
values ('00000000-0000-0000-0000-0000000e0003', current_date - 60, 'appraisal', 900);
set local role authenticated;

do $$
declare v_detail text;
begin
  perform pg_temp.glogin('g_mgmt');
  if pg_temp.hc_ok('valuations_fresh') then
    raise exception 'FAIL: มีทรัพย์ราคาเก่า 60 วันแต่ธง valuations_fresh เขียว → ธงเดิมเสียไปตอนเพิ่มธงใหม่';
  end if;
  if not pg_temp.hc_ok('valuations_present') then
    raise exception 'FAIL: ทรัพย์ราคาเก่าไปขึ้นธง "ไม่เคยตีราคา" ด้วย (%) → สองเรื่องปนกัน',
      pg_temp.hc_detail('valuations_present');
  end if;
  v_detail := pg_temp.hc_detail('valuations_fresh');
  if v_detail not like '%1 รายการ%' then
    raise exception 'FAIL: detail ของธงราคาเก่าควรนับ 1 รายการ (ได้ "%")', v_detail;
  end if;
  raise notice 'ok G10 · ราคาเก่า 60 วัน = ธง valuations_fresh แดง · ธง valuations_present ยังเขียว (แยกเรื่องกันจริง)';
end $$;

-- ============================================================
-- G11 · พังทั้งสองเรื่องพร้อมกัน → ต้องได้ **สองธงแดงแยกกัน**
--       ถ้ายุบเป็นธงเดียวจะเห็นแค่ข้อเดียวแล้วแก้ไม่ครบ
-- ============================================================
reset role;
insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, manager_user_id)
select '00000000-0000-0000-0000-0000000e0004', 'GRD-D4', 'ไม่เคยตีราคาอีกตัว',
       cat.class_id, cat.id, o.id, pg_temp.guid('g_mgr')
  from (select id, class_id from sri_os.asset_categories order by id limit 1) cat
  cross join (select id from sri_os.owners where code = 'SRI_CORP') o;
set local role authenticated;

do $$
declare n_red int; v_detail text;
begin
  perform pg_temp.glogin('g_mgmt');
  select count(*) into n_red from sri_os.fn_health_check()
   where check_name in ('valuations_fresh', 'valuations_present') and not ok;
  if n_red <> 2 then
    raise exception 'FAIL: ทรัพย์ราคาเก่า + ทรัพย์ไม่เคยตีราคา อยู่ด้วยกัน ต้องแดงสองธง (แดง % ธง)', n_red;
  end if;
  v_detail := pg_temp.hc_detail('valuations_present');
  if v_detail not like '%GRD-D4%' or v_detail like '%GRD-D3%' then
    raise exception 'FAIL: detail ธงไม่เคยตีราคาต้องมี GRD-D4 และไม่มี GRD-D3 (ได้ "%")', v_detail;
  end if;
  raise notice 'ok G11 · สองเรื่องพร้อมกัน = สองธงแดงแยกกัน · detail ไม่ปนกัน';
end $$;

-- ============================================================
-- G12 · ไม่ถดถอยจาก 20261007000007: เรียกได้เฉพาะคนที่มี settings.manage
--       "ไม่มีสิทธิ์" ต้องเป็น error ไม่ใช่คืน 0 แถว (แยกจาก "ข้อมูลสุขภาพดี")
--       + เคสไม่ส่งข้อมูล: session ที่ไม่มีแถวใน app_users เลย (g_ghost)
-- ============================================================
do $$
declare r text; n int;
begin
  foreach r in array array['g_ghost', 'g_staff', 'g_mgr'] loop
    perform pg_temp.glogin(r);
    begin
      perform * from sri_os.fn_health_check();
      raise exception 'FAIL: % เรียก fn_health_check ได้ = ดึง transaction_id ข้ามผู้ถือ', r;
    exception when insufficient_privilege then null;
      when raise_exception then
        if sqlerrm like 'FAIL:%' then raise; end if;
        if sqlerrm not like 'ไม่มีสิทธิ์%' then
          raise exception 'FAIL: % ถูกปฏิเสธด้วยเหตุอื่น: %', r, sqlerrm;
        end if;
    end;
  end loop;

  foreach r in array array['g_mgmt', 'g_super'] loop
    perform pg_temp.glogin(r);
    select count(*) into n from sri_os.fn_health_check();
    if n <> 5 then
      raise exception 'FAIL: % เรียก fn_health_check ได้ % ข้อ (ต้อง 5) → หน้า Data health พัง', r, n;
    end if;
  end loop;
  raise notice 'ok G12 · fn_health_check เรียกได้เฉพาะ settings.manage (รวมเคสไม่มีแถวใน app_users) · ขาบวกได้ 5 ข้อ';
end $$;

reset role;

-- ============================================================
-- G13 · โครงสร้างของ fn_health_check ต้องไม่หลวมลงจาก 20261007000007
--       SECURITY DEFINER (ต้องเห็นทุก owner) · search_path ล็อก · public/anon เรียกไม่ได้
-- ============================================================
do $$
declare r record;
begin
  select p.prosecdef, p.proconfig, has_function_privilege('public', p.oid, 'execute') as pub,
         has_function_privilege('authenticated', p.oid, 'execute') as app
    into r
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_health_check';
  if not found then
    raise exception 'FAIL: ไม่มี sri_os.fn_health_check';
  end if;
  if not r.prosecdef then
    raise exception 'FAIL: fn_health_check ไม่ใช่ SECURITY DEFINER แล้ว → รายงานจะเห็นแค่ owner ของคนเรียก = Invariant ระดับระบบเชื่อไม่ได้';
  end if;
  if r.proconfig is null or not (array_to_string(r.proconfig, ',') like '%search_path%') then
    raise exception 'FAIL: fn_health_check ไม่ได้ล็อก search_path';
  end if;
  if r.pub then
    raise exception 'FAIL: public เรียก fn_health_check ได้ = ประตูข้าม RLS';
  end if;
  if not r.app then
    raise exception 'FAIL: authenticated เรียก fn_health_check ไม่ได้เลย → หน้า Data health เรียกไม่ได้ (ด่านสิทธิ์อยู่ในตัวฟังก์ชัน)';
  end if;
  raise notice 'ok G13 · fn_health_check ยังเป็น SECURITY DEFINER + search_path ล็อก + public เรียกไม่ได้ + authenticated เรียกได้';
end $$;

do $$ begin raise notice '=== valuation delete guard + health check ผ่านทั้งหมด ==='; end $$;

rollback;
