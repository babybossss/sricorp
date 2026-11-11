-- ============================================================
-- SRI OS · เทสต์ของ supabase/migrations/20261008000007_assign_and_contract_tiers.sql
--
--   A* · ข้อ 1 — สิทธิ์ `asset.assign_manager` (มอบหมายผู้บริหารทรัพย์)
--        Management ทำได้ · Super Admin ทำได้ · **Manager ไม่ได้** · **Staff ไม่ได้**
--        และ **เหตุผลเดิมต้องยังอยู่**: Manager แจกสิทธิ์เห็นมูลค่าให้ตัวเองไม่ได้
--        พร้อมยืนยันว่าเราไม่ได้แก้ด้วยการขยาย users.manage (Management ยังย้ายตำแหน่ง
--        คน / แจกสิทธิ์เห็น Entity ไม่ได้)
--
--   B* · ข้อ 2 — ด่านตารางงวดสองชั้นตาม Entity Policy
--        ชั้น (ก) blocking  → บล็อกทุกผู้ถือ
--        ชั้น (ข) document  → บล็อกเฉพาะ corporate_strict · ฝั่งบุคคลเป็นธง Data health
--        + ปิดประตูหลังฝั่ง UPDATE ของ contracts
--        + เกณฑ์มาจาก settings · settings ว่าง = ค่าตั้งต้นที่เข้ม · ตั้งค่าผิด = พัง
--
--   G* · เส้นทางที่ถูกต้องต้องยังทำได้ (บทเรียนข้อ 7 · "กันแน่นเกินก็คือพัง")
--   M* · mutation ในไฟล์ — ถอดการแก้ออกทีละชิ้นแล้วเทสต์ต้องแดง
--
-- รันในเครื่อง (ต้องมี migration ใหม่ใน UNDER_TEST ด้วย):
--   UNDER_TEST="... 20261008000006_approval_integrity.sql 20261008000007_assign_and_contract_tiers.sql" \
--     bash scripts/test-rls-local.sh
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ rollback ปิดท้าย · เจอข้อผิด = raise exception
--
-- สามแบบของการ "ถูกปฏิเสธ" ที่ต้องแยกให้ออก ไม่งั้นเทสต์ผ่านฟรีๆ:
--   RLS ไม่มี policy / WITH CHECK ไม่ผ่านตอน UPDATE → บางกรณี **0 แถว ไม่ error**
--   ไม่มี grant → insufficient_privilege · trigger ปฏิเสธ → raise_exception
-- ทุกข้อที่เป็น UPDATE จึงนับแถวด้วย ไม่เชื่อแค่ "ไม่ error"
--
-- สิ่งที่ไฟล์นี้ต้องจับได้ (ไล่จาก "ถ้าถอดการแก้ออกแล้วต้องแดง"):
--   N1 ไม่เพิ่มสิทธิ์ใหม่ / fn_asset_assign_ok ยังถาม users.manage → A2 A3 แดง
--   N2 แก้ด้วยการให้ users.manage แก่ Management                  → A7 แดง
--   N3 ให้สิทธิ์ใหม่แก่ Manager/Staff ด้วย                        → A4 A5 A6 แดง
--   N4 ด่านตารางงวดยังเป็นชั้นเดียว (ครบ 6 ทุกผู้ถือ)              → B1 แดง
--   N5 คลายทั้งใบ (เลิกบังคับเอกสารกับนิติบุคคล)                  → B2 แดง
--   N6 คลายชั้น (ก) ด้วย (ให้บุคคลข้าม principal/rate/วันที่ได้)     → B3 แดง
--   N7 ไม่ครอบ UPDATE ของ contracts (ประตูหลัง)                   → B5 แดง
--   N8 hard-code เกณฑ์ ไม่อ่าน settings                           → B7 แดง
--   N9 settings ว่าง/ผิดรูป = ไม่บังคับอะไรเลย                     → B8 B9 แดง
--   N10 ไม่มีธง Data health (ฝั่งบุคคลผ่านแบบเงียบ)                → B1b แดง
--   N11 กันแน่นเกินจนแก้สัญญา/เลื่อนงวด/ปิดสัญญาไม่ได้            → G* แดง
--
-- เคส "ไม่ส่งข้อมูล" (บทเรียนข้อ 3) อยู่ที่
--   A8  — มอบหมายโดยไม่ส่ง manager_user_id (null) และทรัพย์ที่ยังไม่มีแถว (ตอน INSERT)
--   A9  — ผู้ใช้ที่ไม่มีแถวใน app_users / ไม่ล็อกอิน
--   B3  — สัญญาที่ไม่ส่ง principal/rate/วันที่
--   B4  — สัญญาเปล่าทั้งใบ (ไม่ส่งอะไรเลยนอกจากคอลัมน์บังคับ)
--   B6  — แก้สัญญาที่ฟิลด์เงินว่างอยู่แล้ว (ข้อความปฏิเสธต้องไม่ล้มเพราะ null)
--   B9  — settings ที่ใส่มาไม่ครบคีย์ / เป็น array ว่าง
-- ============================================================

begin;

-- ---------- fixtures: ผู้ใช้ ----------
create temporary table t_auid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_auid(label) values
  ('a_super'), ('a_mgmt'), ('a_mgr'), ('a_mgr2'), ('a_staff'), ('a_ghost');
insert into auth.users(id) select id from t_auid;

insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, u.label || '@gate.local', u.label, x.role, true
  from t_auid u
  join (values ('a_super', 'super_admin'), ('a_mgmt', 'management'),
               ('a_mgr', 'manager'), ('a_mgr2', 'manager'),
               ('a_staff', 'staff')) as x(label, role)   -- 'a_ghost' ไม่มีแถวโดยตั้งใจ
    on x.label = u.label;

create or replace function pg_temp.auid(p_label text) returns uuid
language sql stable as $fn$ select id from t_auid where label = p_label $fn$;

create or replace function pg_temp.alogin(p_label text) returns void
language sql as $fn$
  select set_config('test.uid', coalesce((select id::text from t_auid where label = p_label), ''), true);
$fn$;

create or replace function pg_temp.afail(p_label text, p_sql text) returns void
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

create or replace function pg_temp.apass(p_label text, p_sql text) returns void
language plpgsql as $fn$
begin
  execute p_sql;
exception when others then
  raise exception 'FAIL: % — คำสั่งควรสำเร็จแต่ล้ม (%) · sql: %', p_label, sqlerrm, p_sql;
end $fn$;

create or replace function pg_temp.arows(p_label text, p_sql text, p_expect int) returns void
language plpgsql as $fn$
declare n int;
begin
  execute p_sql;
  get diagnostics n = row_count;
  if n <> p_expect then
    raise exception 'FAIL: % — คาดว่ากระทบ % แถว แต่ได้ % แถว · sql: %', p_label, p_expect, n, p_sql;
  end if;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: % — คำสั่งล้ม (%) ทั้งที่คาดว่าจะกระทบ % แถว · sql: %',
    p_label, sqlerrm, p_expect, p_sql;
end $fn$;

-- "ถูกปฏิเสธแบบใดก็ได้" ไม่พอสำหรับ UPDATE — ต้องยืนยันว่าค่าในแถว **ไม่เปลี่ยนจริง**
-- เพราะ RLS ปฏิเสธ UPDATE แบบเงียบ (0 แถว ไม่ error) และ WITH CHECK ก็ raise
--
-- สำคัญ: การ **ตรวจค่า** ต้องทำนอกสายตาของ RLS (reset role ชั่วคราว)
--   ไม่งั้นเทสต์จะผ่านฟรีเมื่อผู้ใช้คนนั้นอ่านแถวไม่เห็น — subquery คืน NULL
--   แล้วเงื่อนไขแบบ "... is null" จะเป็นจริงทั้งตอนค่าเป็น null จริง
--   และตอน "มองไม่เห็นแถว" ซึ่งเป็นสองเรื่องที่ต่างกันคนละอย่าง
create or replace function pg_temp.a_no_change(p_label text, p_sql text, p_check text) returns void
language plpgsql as $fn$
declare v boolean;
begin
  begin execute p_sql; exception when others then null; end;
  execute 'reset role';
  execute 'select ' || p_check into v;
  execute 'set local role authenticated';
  if not coalesce(v, false) then
    raise exception 'FAIL: % — แถวถูกเปลี่ยนจริงทั้งที่ควรถูกปฏิเสธ · sql: % · เงื่อนไข: %',
      p_label, p_sql, p_check;
  end if;
end $fn$;

-- ---------- fixtures: ขอบเขตผู้ถือ ----------
insert into sri_os.user_owner_access(user_id, owner_id)
select pg_temp.auid(l), o.id
  from unnest(array['a_mgr', 'a_mgr2', 'a_staff']) l, sri_os.owners o
 where o.code in ('SRI_CORP', 'SUTEE');

-- ---------- fixtures: ทรัพย์ ----------
insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, manager_user_id)
select x.id, x.code, x.name,
       (select class_id from sri_os.asset_categories order by code limit 1),
       (select id       from sri_os.asset_categories order by code limit 1),
       (select id from sri_os.owners where code = 'SRI_CORP'),
       x.mgr
  from (values
    ('00000000-0000-0000-0000-0000000a9001'::uuid, 'GT-A1', 'ของ a_mgr',     pg_temp.auid('a_mgr')),
    ('00000000-0000-0000-0000-0000000a9002'::uuid, 'GT-A2', 'ยังไม่มอบหมาย', null::uuid),
    ('00000000-0000-0000-0000-0000000a9003'::uuid, 'GT-A3', 'ยังไม่มอบหมาย', null::uuid)
  ) as x(id, code, name, mgr);

-- role authenticated ต้องเรียกตัวช่วยใน temp schema ได้
do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.t_auid to authenticated', s);
end $$;

-- ############################################################
-- A · ข้อ 1 — asset.assign_manager
-- ############################################################

-- ------------------------------------------------------------
-- A1 · สิทธิ์ใหม่ผูกกับตำแหน่งตามที่ลูกพี่สั่ง: Management + Super Admin เท่านั้น
-- ------------------------------------------------------------
do $$
declare r record; v boolean;
begin
  for r in select * from (values
      ('a_super', true), ('a_mgmt', true), ('a_mgr', false), ('a_staff', false)
    ) as m(label, expect)
  loop
    perform pg_temp.alogin(r.label);
    v := sri_os.fn_can('asset.assign_manager');
    if v is distinct from r.expect then
      raise exception 'FAIL A1: % · fn_can(asset.assign_manager) = % แต่ต้องได้ %', r.label, v, r.expect;
    end if;
  end loop;

  -- เคส "ไม่ส่งข้อมูล": ไม่มีแถวใน app_users · ไม่ได้ล็อกอิน → false ไม่ใช่ error
  perform pg_temp.alogin('a_ghost');
  if sri_os.fn_can('asset.assign_manager') then raise exception 'FAIL A1: ghost มีสิทธิ์'; end if;
  perform pg_temp.alogin('__nobody__');
  if sri_os.fn_can('asset.assign_manager') then raise exception 'FAIL A1: ไม่ล็อกอินมีสิทธิ์'; end if;

  -- สิทธิ์ใหม่ต้อง **ไม่** พ่วง users.manage มาให้ Management (นั่นคือสิ่งที่เราเลี่ยง)
  perform pg_temp.alogin('a_mgmt');
  if sri_os.fn_can('users.manage') then
    raise exception 'FAIL A1: Management ได้ users.manage มาด้วย = ขยายสิทธิ์เกินที่ลูกพี่สั่ง';
  end if;
  raise notice 'ok A1 · asset.assign_manager = Management + Super Admin · Manager/Staff/ghost ไม่มี · ไม่พ่วง users.manage';
end $$;

set local role authenticated;

-- ------------------------------------------------------------
-- A2 · Management มอบหมายผู้บริหารได้ (คำสั่งลูกพี่ 08/10) ทั้ง UPDATE และ INSERT
-- ------------------------------------------------------------
do $$
declare v_own uuid; v_cat uuid; v_cls uuid;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;

  perform pg_temp.alogin('a_mgmt');
  perform pg_temp.arows('Management มอบหมายผู้บริหาร (update)', format(
    'update sri_os.assets set manager_user_id = %L where id = %L',
    pg_temp.auid('a_mgr'), '00000000-0000-0000-0000-0000000a9002'), 1);
  perform pg_temp.arows('Management ย้ายผู้บริหารไปอีกคน', format(
    'update sri_os.assets set manager_user_id = %L where id = %L',
    pg_temp.auid('a_mgr2'), '00000000-0000-0000-0000-0000000a9002'), 1);
  perform pg_temp.arows('Management ถอนการมอบหมาย (ล้างเป็น null)',
    'update sri_os.assets set manager_user_id = null where id = ''00000000-0000-0000-0000-0000000a9002''', 1);
  perform pg_temp.apass('Management ตั้งผู้บริหารตอนสร้างทรัพย์', format(
    'insert into sri_os.assets(code, name, class_id, category_id, owner_id, manager_user_id) values (''GT-NEW1'', ''x'', %L, %L, %L, %L)',
    v_cls, v_cat, v_own, pg_temp.auid('a_mgr')));
  raise notice 'ok A2 · Management ตั้ง/ย้าย/ถอนผู้บริหารได้ ทั้งตอน update และตอน insert';
end $$;

-- ------------------------------------------------------------
-- A3 · Super Admin ยังทำได้ (ไม่ได้ย้ายสิทธิ์ออกจากเขา)
-- ------------------------------------------------------------
do $$
begin
  perform pg_temp.alogin('a_super');
  perform pg_temp.arows('Super Admin มอบหมายผู้บริหาร', format(
    'update sri_os.assets set manager_user_id = %L where id = %L',
    pg_temp.auid('a_mgr'), '00000000-0000-0000-0000-0000000a9003'), 1);
  raise notice 'ok A3 · Super Admin มอบหมายผู้บริหารได้';
end $$;

-- ------------------------------------------------------------
-- A4 · **Manager ไม่ได้** — เหตุผลเดิมของข้อจำกัดยังจริง:
--      Manager แจกสิทธิ์เห็นมูลค่า (asset.view_assigned) ให้ตัวเองไม่ได้
-- ------------------------------------------------------------
do $$
declare v_own uuid; v_cat uuid; v_cls uuid;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;

  perform pg_temp.alogin('a_mgr');
  -- ทรัพย์ที่ตนบริหารอยู่ (เห็นได้ แก้ช่องอื่นได้) แต่ย้าย manager_user_id ไม่ได้
  perform pg_temp.a_no_change('Manager ย้ายผู้บริหารของทรัพย์ตนไปให้ Manager อีกคน', format(
    'update sri_os.assets set manager_user_id = %L where id = %L',
    pg_temp.auid('a_mgr2'), '00000000-0000-0000-0000-0000000a9001'),
    format('(select manager_user_id from sri_os.assets where id = %L) = %L',
      '00000000-0000-0000-0000-0000000a9001', pg_temp.auid('a_mgr')));
  perform pg_temp.a_no_change('Manager ถอนการมอบหมายของทรัพย์ตน',
    'update sri_os.assets set manager_user_id = null where id = ''00000000-0000-0000-0000-0000000a9001''',
    format('(select manager_user_id from sri_os.assets where id = %L) = %L',
      '00000000-0000-0000-0000-0000000a9001', pg_temp.auid('a_mgr')));
  -- หัวใจของเหตุผลเดิม: แจกสิทธิ์เห็นมูลค่าให้ "ตัวเอง" ไม่ได้
  --   (ทรัพย์ที่ยังไม่มอบหมาย Manager มองไม่เห็นด้วย → ถูกปฏิเสธสองชั้น)
  perform pg_temp.a_no_change('Manager มอบหมายทรัพย์ที่ยังไม่มีผู้บริหารให้ตัวเอง', format(
    'update sri_os.assets set manager_user_id = %L where id = %L',
    pg_temp.auid('a_mgr'), '00000000-0000-0000-0000-0000000a9002'),
    '(select manager_user_id from sri_os.assets where id = ''00000000-0000-0000-0000-0000000a9002'') is null');
  -- และทรัพย์ที่ตนบริหารอยู่ ก็ย้ายให้ "คนอื่น" ไม่ได้ (ข้างบน) · ตั้งทับค่าเดิมไม่นับเป็นการมอบหมาย
  perform pg_temp.arows('Manager เขียนค่าเดิมทับ (ไม่ใช่การมอบหมาย จึงผ่านได้)', format(
    'update sri_os.assets set manager_user_id = %L where id = %L',
    pg_temp.auid('a_mgr'), '00000000-0000-0000-0000-0000000a9001'), 1);
  perform pg_temp.afail('Manager สร้างทรัพย์แล้วตั้งตัวเองเป็นผู้บริหาร', format(
    'insert into sri_os.assets(code, name, class_id, category_id, owner_id, manager_user_id) values (''GT-MGR1'', ''x'', %L, %L, %L, %L)',
    v_cls, v_cat, v_own, pg_temp.auid('a_mgr')));
  raise notice 'ok A4 · Manager มอบหมายไม่ได้ทุกทาง (ย้าย/ล้าง/ให้ตัวเอง/ตอนสร้าง) — เหตุผลเดิมของ §3.2 ยังจริง';
end $$;

-- ------------------------------------------------------------
-- A5 · **Staff ไม่ได้** (ไม่มีทั้ง asset.manage และ asset.assign_manager)
-- ------------------------------------------------------------
do $$
declare v_own uuid; v_cat uuid; v_cls uuid;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;

  perform pg_temp.alogin('a_staff');
  perform pg_temp.a_no_change('Staff มอบหมายผู้บริหารให้ตัวเอง',  format(
    'update sri_os.assets set manager_user_id = %L where id = %L',
    pg_temp.auid('a_staff'), '00000000-0000-0000-0000-0000000a9002'),
    '(select manager_user_id from sri_os.assets where id = ''00000000-0000-0000-0000-0000000a9002'') is null');
  perform pg_temp.afail('Staff สร้างทรัพย์พร้อมตั้งผู้บริหาร', format(
    'insert into sri_os.assets(code, name, class_id, category_id, owner_id, manager_user_id) values (''GT-STF1'', ''x'', %L, %L, %L, %L)',
    v_cls, v_cat, v_own, pg_temp.auid('a_staff')));
  raise notice 'ok A5 · Staff มอบหมายผู้บริหารไม่ได้';
end $$;

-- ------------------------------------------------------------
-- A6 · คนไม่มีตำแหน่ง (ไม่มีแถวใน app_users) / ไม่ล็อกอิน → ทำไม่ได้
-- ------------------------------------------------------------
do $$
begin
  perform pg_temp.alogin('a_ghost');
  perform pg_temp.a_no_change('คนไม่มีตำแหน่งมอบหมายผู้บริหาร', format(
    'update sri_os.assets set manager_user_id = %L where id = %L',
    pg_temp.auid('a_mgr2'), '00000000-0000-0000-0000-0000000a9002'),
    '(select manager_user_id from sri_os.assets where id = ''00000000-0000-0000-0000-0000000a9002'') is null');
  perform pg_temp.a_no_change('คนไม่มีตำแหน่งย้ายผู้บริหารของทรัพย์ที่มอบหมายแล้ว', format(
    'update sri_os.assets set manager_user_id = %L where id = %L',
    pg_temp.auid('a_mgr2'), '00000000-0000-0000-0000-0000000a9003'),
    format('(select manager_user_id from sri_os.assets where id = %L) = %L',
      '00000000-0000-0000-0000-0000000a9003', pg_temp.auid('a_mgr')));
  perform pg_temp.alogin('__nobody__');
  perform pg_temp.a_no_change('ไม่ล็อกอินมอบหมายผู้บริหาร', format(
    'update sri_os.assets set manager_user_id = %L where id = %L',
    pg_temp.auid('a_mgr2'), '00000000-0000-0000-0000-0000000a9002'),
    '(select manager_user_id from sri_os.assets where id = ''00000000-0000-0000-0000-0000000a9002'') is null');
  raise notice 'ok A6 · คนไม่มีตำแหน่ง / ไม่ล็อกอิน มอบหมายไม่ได้ (ไม่ error เงียบๆ ว่าสำเร็จ)';
end $$;

-- ------------------------------------------------------------
-- A7 · เราไม่ได้แก้ด้วยการขยาย users.manage — Management ยังทำของที่กว้างกว่าไม่ได้
--      (ถ้าใครเผลอแก้ด้วยการให้ users.manage แก่ Management ข้อนี้จะแดง)
-- ------------------------------------------------------------
do $$
declare v_o uuid;
begin
  select id into v_o from sri_os.owners where code = 'SRI_CORP';
  perform pg_temp.alogin('a_mgmt');
  perform pg_temp.a_no_change('Management เลื่อนตำแหน่งคน (app_users.role)', format(
    'update sri_os.app_users set role = ''super_admin'' where id = %L', pg_temp.auid('a_staff')),
    format('(select role from sri_os.app_users where id = %L) = ''staff''', pg_temp.auid('a_staff')));
  perform pg_temp.afail('Management แจกสิทธิ์เห็น Entity (user_owner_access)', format(
    'insert into sri_os.user_owner_access(user_id, owner_id) values (%L, %L)',
    pg_temp.auid('a_ghost'), v_o));
  perform pg_temp.afail('Management ติ๊ก role_permissions ให้ตัวเอง',
    'insert into sri_os.role_permissions(role_key, permission_key) values (''management'', ''users.manage'')');
  raise notice 'ok A7 · Management ยังย้ายตำแหน่งคน / แจกสิทธิ์เห็น Entity / ติ๊กสิทธิ์เองไม่ได้ = สิทธิ์ใหม่แคบจริง';
end $$;

-- ------------------------------------------------------------
-- A8 · เคส "ไม่ส่งข้อมูล" ที่ตัวฟังก์ชัน: ทรัพย์ที่ยังไม่มีแถว (สาขา INSERT)
--      ไม่ส่งผู้บริหาร (null) = ไม่มีการมอบหมาย → ใครก็ผ่าน
--      ส่งผู้บริหารมา = ต้องมีสิทธิ์ ถึงจะยังไม่มีแถวในตาราง
-- ------------------------------------------------------------
do $$
declare v_fake uuid := gen_random_uuid();
begin
  perform pg_temp.alogin('a_mgr');
  if not sri_os.fn_asset_assign_ok(v_fake, null, null) then
    raise exception 'FAIL A8: ไม่ส่งผู้บริหารเลยแต่ถูกปฏิเสธ → สร้างทรัพย์แบบไม่มอบหมายจะทำไม่ได้';
  end if;
  if sri_os.fn_asset_assign_ok(v_fake, pg_temp.auid('a_mgr'), null) then
    raise exception 'FAIL A8: Manager ตั้งผู้บริหารบนทรัพย์ที่ยังไม่มีแถวได้ (สาขา INSERT หลุด)';
  end if;
  perform pg_temp.alogin('a_mgmt');
  if not sri_os.fn_asset_assign_ok(v_fake, pg_temp.auid('a_mgr'), null) then
    raise exception 'FAIL A8: Management ตั้งผู้บริหารตอน INSERT ไม่ได้';
  end if;
  raise notice 'ok A8 · สาขา "ยังไม่มีแถว": ไม่ส่งผู้บริหาร = ผ่านทุกคน · ส่งมา = ต้องมีสิทธิ์';
end $$;

-- ------------------------------------------------------------
-- A9 · owner_id ยังเป็นเรื่องของ settings.manage ไม่ได้ถูกเหมารวมเข้าสิทธิ์ใหม่
-- ------------------------------------------------------------
do $$
begin
  perform pg_temp.alogin('a_mgr');
  perform pg_temp.a_no_change('Manager ย้ายผู้ถือของทรัพย์ตน',
    'update sri_os.assets set owner_id = (select id from sri_os.owners where code = ''SUTEE'') where id = ''00000000-0000-0000-0000-0000000a9001''',
    '(select o.code from sri_os.assets a join sri_os.owners o on o.id = a.owner_id where a.id = ''00000000-0000-0000-0000-0000000a9001'') = ''SRI_CORP''');
  raise notice 'ok A9 · การย้ายผู้ถือยังต้อง settings.manage (สิทธิ์ใหม่ไม่เหมารวม)';
end $$;

reset role;

-- ############################################################
-- B · ข้อ 2 — ด่านตารางงวดสองชั้น
-- ############################################################

-- ---------- fixtures: สัญญา 6 ใบ ----------
-- ct1 นิติบุคคล ครบทั้งสองชั้น        ct2 นิติบุคคล ครบชั้น ก ขาดเอกสาร
-- ct3 บุคคล    ครบชั้น ก ขาดเอกสาร   ct4 บุคคล    ขาดชั้น ก
-- ct5 นิติบุคคล เปล่าทั้งใบ            ct6 บุคคล    ครบทั้งสองชั้น
insert into sri_os.contacts(id, first_name, last_name, types) values
  ('00000000-0000-0000-0000-0000000af001', 'คู่สัญญา', 'ทดสอบ', array['borrower']);

insert into sri_os.contracts(id, code, owner_id, type, counterparty_contact_id,
                             principal, rate, rate_period, interest_method,
                             start_date, end_date, installments, payment_day, file_urls)
select x.id, x.code,
       (select id from sri_os.owners where code = x.owner_code),
       'loan_receivable', x.contact,
       x.principal, x.rate, 'month', 'simple',
       x.start_date, x.end_date, x.installments, 5, x.files
  from (values
    ('00000000-0000-0000-0000-0000000ac001'::uuid, 'GT-CT1', 'SRI_CORP',
       '00000000-0000-0000-0000-0000000af001'::uuid, 1000000::numeric, 1.25::numeric,
       current_date - 30, current_date + 300, 12, array['ct1.pdf']),
    ('00000000-0000-0000-0000-0000000ac002'::uuid, 'GT-CT2', 'SRI_CORP',
       null::uuid, 1000000::numeric, 1.25::numeric,
       current_date - 30, current_date + 300, 12, '{}'::text[]),
    ('00000000-0000-0000-0000-0000000ac003'::uuid, 'GT-CT3', 'SUTEE',
       null::uuid, 500000::numeric, 1.00::numeric,
       current_date - 30, null::date, 10, '{}'::text[]),
    ('00000000-0000-0000-0000-0000000ac004'::uuid, 'GT-CT4', 'SUTEE',
       '00000000-0000-0000-0000-0000000af001'::uuid, null::numeric, null::numeric,
       null::date, null::date, null::int, array['ct4.pdf']),
    ('00000000-0000-0000-0000-0000000ac006'::uuid, 'GT-CT6', 'SUTEE',
       '00000000-0000-0000-0000-0000000af001'::uuid, 700000::numeric, 1.10::numeric,
       current_date - 10, current_date + 200, 8, array['ct6.pdf'])
  ) as x(id, code, owner_code, contact, principal, rate, start_date, end_date, installments, files);

-- เคส "ไม่ส่งข้อมูล" ของตารางนี้: ส่งแค่คอลัมน์บังคับ
insert into sri_os.contracts(id, code, owner_id, type)
select '00000000-0000-0000-0000-0000000ac005', 'GT-CT5',
       (select id from sri_os.owners where code = 'SRI_CORP'), 'loan_receivable';

create or replace function pg_temp.sched(p_contract uuid, p_period int) returns text
language sql immutable as $fn$
  select format('insert into sri_os.schedules(contract_id, period, due_date, expected_amount, principal_amount, interest_amount) values (%L, %s, current_date + %s, 1000, 900, 100)',
                p_contract, p_period, p_period * 30);
$fn$;

-- ------------------------------------------------------------
-- B1 · สัญญา**บุคคล**ที่ไม่มีไฟล์/คู่ค้า → สร้างงวดได้ (หัวใจของข้อ 2)
-- ------------------------------------------------------------
do $$
begin
  perform pg_temp.apass('สัญญาบุคคลไม่มีไฟล์/คู่ค้า สร้างงวดได้',
    pg_temp.sched('00000000-0000-0000-0000-0000000ac003', 1));
  raise notice 'ok B1 · สัญญาบุคคลที่ขาดเอกสารสร้างตารางงวดได้ (เงินกู้ในบ้านมีค้างรับในระบบแล้ว)';
end $$;

-- ------------------------------------------------------------
-- B1b · ...แต่ต้องขึ้น **ธง Data health** ไม่ใช่ผ่านแบบเงียบ
-- ------------------------------------------------------------
do $$
declare r record;
begin
  select * into r from sri_os.v_contract_data_health where contract_id = '00000000-0000-0000-0000-0000000ac003';
  if r.contract_id is null then raise exception 'FAIL B1b: ไม่มีแถวใน v_contract_data_health'; end if;
  if r.blocks_schedule then raise exception 'FAIL B1b: ธงบอกว่าบล็อก ทั้งที่ชั้น ก ครบ'; end if;
  if not r.doc_health_flag then
    raise exception 'FAIL B1b: สัญญาบุคคลที่ขาดเอกสารไม่ขึ้นธง Data health = ผ่านแบบเงียบ';
  end if;
  if not (r.missing_document @> array['counterparty_contact_id', 'file_urls']) then
    raise exception 'FAIL B1b: ธงไม่ได้บอกว่าขาดอะไร (missing_document = %)', r.missing_document;
  end if;
  if not r.has_schedule then raise exception 'FAIL B1b: has_schedule ไม่ตรงความจริง'; end if;

  -- สัญญาที่ครบทั้งสองชั้นต้องไม่ติดธง (ธงที่ขึ้นทุกใบ = ไม่มีใครดู)
  select * into r from sri_os.v_contract_data_health where contract_id = '00000000-0000-0000-0000-0000000ac001';
  if r.doc_health_flag or r.blocks_schedule then
    raise exception 'FAIL B1b: สัญญาที่ครบติดธง (blocks=% doc=%)', r.blocks_schedule, r.doc_health_flag;
  end if;
  raise notice 'ok B1b · ธง Data health ขึ้นเฉพาะใบที่ขาดจริง และบอกว่าขาดช่องไหน';
end $$;

-- ------------------------------------------------------------
-- B2 · สัญญา**นิติบุคคล**ที่ไม่มีไฟล์/คู่ค้า → สร้างงวด**ไม่ได้** (corporate_strict ไม่หลวมลง)
-- ------------------------------------------------------------
do $$
declare v_msg text; n_before int; n_after int;
begin
  select count(*) into n_before from sri_os.schedules;
  begin
    execute pg_temp.sched('00000000-0000-0000-0000-0000000ac002', 1);
    raise exception 'FAIL B2: สัญญานิติบุคคลที่ขาดเอกสารสร้างงวดได้ = ปลด corporate_strict';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    v_msg := sqlerrm;
  end;
  if v_msg not like '%counterparty_contact_id%' or v_msg not like '%file_urls%' then
    raise exception 'FAIL B2: ข้อความปฏิเสธไม่บอกว่าขาดอะไร (%)', v_msg;
  end if;
  select count(*) into n_after from sri_os.schedules;
  if n_after <> n_before then raise exception 'FAIL B2: trigger raise แต่แถวเข้าไปแล้ว'; end if;
  raise notice 'ok B2 · นิติบุคคลที่ขาดเอกสารสร้างงวดไม่ได้ และข้อความบอกว่าขาดช่องไหน';
end $$;

-- ------------------------------------------------------------
-- B3 · ขาดชั้น (ก) → สร้างงวดไม่ได้ **ทุกผู้ถือ** (บุคคลก็ไม่ได้ — ไม่ใช่เรื่องนโยบาย)
--      เคส "ไม่ส่งข้อมูล": principal/rate/วันที่ไม่ได้ส่งมา
-- ------------------------------------------------------------
do $$
declare v_msg text;
begin
  begin
    execute pg_temp.sched('00000000-0000-0000-0000-0000000ac004', 1);
    raise exception 'FAIL B3: สัญญาบุคคลที่ขาด principal/rate/วันที่ สร้างงวดได้';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    v_msg := sqlerrm;
  end;
  if v_msg not like '%principal%' or v_msg not like '%rate%' or v_msg not like '%start_date%' or v_msg not like '%term%' then
    raise exception 'FAIL B3: ข้อความไม่ครบว่าขาดอะไร (%)', v_msg;
  end if;
  -- ชั้น ก ไม่ใช่เรื่องเอกสาร → ใบนี้มีไฟล์+คู่ค้าครบแต่ก็ยังไม่ผ่าน
  if (select cardinality(file_urls) from sri_os.contracts where id = '00000000-0000-0000-0000-0000000ac004') = 0 then
    raise exception 'FAIL B3: fixture เพี้ยน — ใบนี้ควรมีไฟล์ครบเพื่อพิสูจน์ว่าชั้น ก ไม่เกี่ยวกับเอกสาร';
  end if;
  raise notice 'ok B3 · ขาด principal/rate/วันที่ = สร้างงวดไม่ได้แม้เป็นฝั่งบุคคลและเอกสารครบ';
end $$;

-- ------------------------------------------------------------
-- B4 · สัญญาเปล่าทั้งใบ (นิติบุคคล) → ขาดทั้งสองชั้น
-- ------------------------------------------------------------
do $$
declare v_msg text;
begin
  begin
    execute pg_temp.sched('00000000-0000-0000-0000-0000000ac005', 1);
    raise exception 'FAIL B4: สัญญาเปล่าสร้างงวดได้';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    v_msg := sqlerrm;
  end;
  if v_msg not like '%principal%' or v_msg not like '%file_urls%' then
    raise exception 'FAIL B4: ข้อความไม่ได้รวมทั้งสองชั้น (%)', v_msg;
  end if;
  -- งวดที่ชี้ไปสัญญาที่ไม่มีอยู่ ต้องถูกปฏิเสธ (FK) ไม่ใช่ปล่อยผ่าน
  perform pg_temp.afail('งวดที่ชี้สัญญาที่ไม่มีอยู่', pg_temp.sched(gen_random_uuid(), 1));
  raise notice 'ok B4 · สัญญาเปล่าทั้งใบขาดทั้งสองชั้น · งวดที่ชี้สัญญาไม่มีอยู่ถูกปฏิเสธ';
end $$;

-- ------------------------------------------------------------
-- B5 · **ประตูหลัง**: ครบ → ใส่งวด → ลบ contact/ไฟล์ทีหลัง ต้องถูกปฏิเสธ
-- ------------------------------------------------------------
do $$
begin
  perform pg_temp.apass('สัญญานิติบุคคลที่ครบ ใส่งวดได้',
    pg_temp.sched('00000000-0000-0000-0000-0000000ac001', 1));

  perform pg_temp.afail('ลบไฟล์หลักฐานทีหลัง',
    'update sri_os.contracts set file_urls = ''{}'' where id = ''00000000-0000-0000-0000-0000000ac001''');
  perform pg_temp.afail('ลบคู่สัญญาทีหลัง',
    'update sri_os.contracts set counterparty_contact_id = null where id = ''00000000-0000-0000-0000-0000000ac001''');
  perform pg_temp.afail('ล้างเงินต้นทีหลัง (ชั้น ก)',
    'update sri_os.contracts set principal = null where id = ''00000000-0000-0000-0000-0000000ac001''');
  perform pg_temp.afail('ล้างทั้ง end_date และ installments ทีหลัง (term)',
    'update sri_os.contracts set end_date = null, installments = null where id = ''00000000-0000-0000-0000-0000000ac001''');
  perform pg_temp.afail('ลบสองช่องพร้อมกัน',
    'update sri_os.contracts set file_urls = ''{}'', counterparty_contact_id = null where id = ''00000000-0000-0000-0000-0000000ac001''');

  if (select cardinality(file_urls) from sri_os.contracts where id = '00000000-0000-0000-0000-0000000ac001') = 0
     or (select counterparty_contact_id from sri_os.contracts where id = '00000000-0000-0000-0000-0000000ac001') is null
     or (select principal from sri_os.contracts where id = '00000000-0000-0000-0000-0000000ac001') is null then
    raise exception 'FAIL B5: trigger raise แต่ค่าถูกเปลี่ยนจริง';
  end if;

  -- ฝั่งบุคคลก็ยังติดชั้น ก (ย้อนไม่ได้) แต่ชั้น ข ไม่บล็อกตามนโยบาย
  perform pg_temp.afail('ล้างเงินต้นของสัญญาบุคคลที่มีงวดแล้ว',
    'update sri_os.contracts set principal = null where id = ''00000000-0000-0000-0000-0000000ac003''');
  raise notice 'ok B5 · ใส่งวดแล้วถอน contact/ไฟล์/เงินต้น/term ทีหลังไม่ได้ (ปิดประตูหลัง BEFORE UPDATE)';
end $$;

-- ------------------------------------------------------------
-- B5b · ...แต่ **ซ่อมให้ดีขึ้นต้องทำได้เสมอ** และสัญญาที่ยังไม่มีงวดแก้ได้อิสระ
--       (ถ้าใช้เกณฑ์ "ต้องครบ" แทน "ไม่ขาดเพิ่ม" ข้อนี้จะแดง = กันแน่นเกิน)
-- ------------------------------------------------------------
do $$
begin
  perform pg_temp.arows('เติมคู่สัญญาให้ใบบุคคลที่มีงวดแล้ว (ซ่อมให้ดีขึ้น)', format(
    'update sri_os.contracts set counterparty_contact_id = %L where id = %L',
    '00000000-0000-0000-0000-0000000af001', '00000000-0000-0000-0000-0000000ac003'), 1);
  perform pg_temp.arows('เติมไฟล์ให้ใบบุคคลที่มีงวดแล้ว',
    'update sri_os.contracts set file_urls = array[''pers.pdf''] where id = ''00000000-0000-0000-0000-0000000ac003''', 1);
  perform pg_temp.arows('แก้เงื่อนไขอื่นของใบที่มีงวดแล้ว (อัตรา/วิธีคิด)',
    'update sri_os.contracts set rate = 1.75, interest_method = ''effective'' where id = ''00000000-0000-0000-0000-0000000ac001''', 1);
  -- สัญญาที่ยังไม่มีงวด: แก้ให้ว่างได้ (เคส "คีย์ผิดแล้วอยากล้าง" · ข้อความต้องไม่ล้มเพราะ null)
  perform pg_temp.arows('ล้างเงินต้นของสัญญาที่ยังไม่มีงวด',
    'update sri_os.contracts set principal = null, rate = null where id = ''00000000-0000-0000-0000-0000000ac002''', 1);
  perform pg_temp.arows('ปิดสัญญาเปล่าด้วย status',
    'update sri_os.contracts set status = ''closed'' where id = ''00000000-0000-0000-0000-0000000ac005''', 1);
  raise notice 'ok B5b · ซ่อมให้ครบขึ้นได้ · แก้เงื่อนไขอื่นได้ · สัญญาที่ยังไม่มีงวดแก้/ล้าง/ปิดได้อิสระ';
end $$;

-- ------------------------------------------------------------
-- B6 · ฝั่งบุคคลที่ชั้น ข ขาดอยู่แล้ว ต้องยัง **แก้แถวนั้นได้** (ไม่ถูกล็อกตลอดไป)
-- ------------------------------------------------------------
do $$
begin
  -- ใบนี้ (ct6 บุคคล ครบทั้งสองชั้น) ใส่งวดแล้วถอนไฟล์ได้ เพราะชั้น ข ไม่บล็อกฝั่งบุคคล
  -- → กลายเป็นธง Data health ไม่ใช่ error (ตัดสินตาม LEDGER_RULES §4)
  perform pg_temp.apass('ใส่งวดให้สัญญาบุคคลที่ครบ',
    pg_temp.sched('00000000-0000-0000-0000-0000000ac006', 1));
  perform pg_temp.arows('ถอนไฟล์ของสัญญาบุคคลที่มีงวดแล้ว → ไม่บล็อก แต่ขึ้นธง',
    'update sri_os.contracts set file_urls = ''{}'' where id = ''00000000-0000-0000-0000-0000000ac006''', 1);
  if not (select doc_health_flag from sri_os.v_contract_data_health
           where contract_id = '00000000-0000-0000-0000-0000000ac006') then
    raise exception 'FAIL B6: ถอนไฟล์ฝั่งบุคคลแล้วไม่ขึ้นธง = เงียบ';
  end if;
  raise notice 'ok B6 · ฝั่งบุคคล: เอกสารขาดได้ ไม่บล็อก แต่ขึ้นธง (override ตาม LEDGER_RULES §4)';
end $$;

-- ------------------------------------------------------------
-- B7 · เกณฑ์อยู่ใน settings · เปลี่ยนแล้ว **มีผลจริง** ทั้งสองทิศ
-- ------------------------------------------------------------
do $$
begin
  perform pg_temp.alogin('a_super');

  -- (ก) เข้มขึ้น: ใบเดียวกัน ก่อน/หลังเปลี่ยนเกณฑ์ ต้องให้ผลต่างกัน
  --     ใบนี้ฝั่งบุคคล ชั้น ก ครบตามค่าตั้งต้น แต่ **ไม่มี payment_day**
  insert into sri_os.contracts(id, code, owner_id, type, principal, rate, rate_period,
                               interest_method, start_date, installments, payment_day, file_urls)
  select '00000000-0000-0000-0000-0000000ac008', 'GT-CT8',
         (select id from sri_os.owners where code = 'SUTEE'), 'loan_receivable',
         400000, 1.2, 'month', 'simple', current_date, 10, null, '{}'::text[];
  perform pg_temp.apass('ก่อนเปลี่ยนเกณฑ์: ใบที่ไม่มี payment_day ใส่งวดได้',
    pg_temp.sched('00000000-0000-0000-0000-0000000ac008', 1));

  insert into sri_os.settings(key, value) values ('contract.schedule_gate',
    '{"blocking": ["principal", "rate", "start_date", "term", "payment_day"], "document": ["file_urls"]}'::jsonb)
  on conflict (key) do update set value = excluded.value;
  perform pg_temp.afail('หลังเพิ่ม payment_day เข้าชั้น ก: ใบเดิมใส่งวดเพิ่มไม่ได้',
    pg_temp.sched('00000000-0000-0000-0000-0000000ac008', 2));
  if not (select blocks_schedule from sri_os.v_contract_data_health
           where contract_id = '00000000-0000-0000-0000-0000000ac008') then
    raise exception 'FAIL B7: เกณฑ์ใหม่มีผลที่ trigger แต่ธง Data health ไม่ขยับตาม (กฎเดียวกันเขียนสองที่)';
  end if;

  -- ...และแถวที่ "ตกเกณฑ์ใหม่" ต้องยัง **แก้ได้** ไม่ถูกล็อกตลอดไป
  --    นี่คือเหตุผลที่ด่านฝั่ง UPDATE ใช้เกณฑ์ "ไม่ขาดเพิ่ม" ไม่ใช่ "ต้องครบ"
  --    (เกณฑ์เข้มขึ้นภายหลัง = แถวเก่าทุกแถวจะกลายเป็นแถวที่แก้อะไรไม่ได้ทันที)
  perform pg_temp.arows('ใบที่ตกเกณฑ์ใหม่ยังปิดสัญญาได้',
    'update sri_os.contracts set status = ''closed'' where id = ''00000000-0000-0000-0000-0000000ac008''', 1);
  perform pg_temp.arows('ใบที่ตกเกณฑ์ใหม่ยังเลื่อนงวดได้',
    'update sri_os.schedules set due_date = due_date + 7 where contract_id = ''00000000-0000-0000-0000-0000000ac008''', 1);
  perform pg_temp.afail('แต่ใบที่ตกเกณฑ์ใหม่ยังถอนเงินต้นไม่ได้',
    'update sri_os.contracts set principal = null where id = ''00000000-0000-0000-0000-0000000ac008''');
  perform pg_temp.arows('ใบที่ตกเกณฑ์ใหม่ซ่อมให้ครบได้ (เติม payment_day)',
    'update sri_os.contracts set payment_day = 5, status = ''active'' where id = ''00000000-0000-0000-0000-0000000ac008''', 1);
  perform pg_temp.apass('ซ่อมแล้วใส่งวดเพิ่มได้ตามเกณฑ์ใหม่',
    pg_temp.sched('00000000-0000-0000-0000-0000000ac008', 3));

  -- (ข) หลวมลง: ถอด counterparty_contact_id ออกจากชั้น ข → ใบนิติบุคคลที่มีแต่ไฟล์ผ่าน
  insert into sri_os.contracts(id, code, owner_id, type, principal, rate, rate_period,
                               interest_method, start_date, installments, payment_day, file_urls)
  select '00000000-0000-0000-0000-0000000ac007', 'GT-CT7',
         (select id from sri_os.owners where code = 'SRI_CORP'), 'loan_payable',
         200000, 2.0, 'month', 'simple', current_date, 6, 5, array['ct7.pdf'];
  perform pg_temp.apass('ถอด counterparty ออกจากชั้น ข แล้วใบที่มีแต่ไฟล์ผ่าน',
    pg_temp.sched('00000000-0000-0000-0000-0000000ac007', 1));

  -- (ค) เกณฑ์ที่อ่านมา ต้องเป็นของใน settings จริง ไม่ใช่ค่าตั้งต้น
  if sri_os.fn_contract_gate_fields('document') <> array['file_urls'] then
    raise exception 'FAIL B7: เกณฑ์ไม่ได้มาจาก settings (ได้ %)', sri_os.fn_contract_gate_fields('document');
  end if;

  delete from sri_os.settings where key = 'contract.schedule_gate';
  raise notice 'ok B7 · เกณฑ์อยู่ใน settings · เข้มขึ้นก็มีผล หลวมลงก็มีผล · ไม่ hard-code';
end $$;

-- ------------------------------------------------------------
-- B8 · settings ว่าง → ค่าตั้งต้นที่ **เข้ม** (= 6 เกณฑ์เดิม) ห้ามแปลว่าไม่บังคับอะไร
-- ------------------------------------------------------------
do $$
begin
  if exists (select 1 from sri_os.settings where key = 'contract.schedule_gate') then
    raise exception 'FAIL B8: fixture เพี้ยน — ข้อนี้ต้องทดสอบตอน settings ไม่มีคีย์นี้';
  end if;
  if sri_os.fn_contract_gate_fields('blocking') <> array['principal', 'rate', 'start_date', 'term'] then
    raise exception 'FAIL B8: ค่าตั้งต้นชั้น ก เพี้ยน (%)', sri_os.fn_contract_gate_fields('blocking');
  end if;
  if sri_os.fn_contract_gate_fields('document') <> array['counterparty_contact_id', 'file_urls'] then
    raise exception 'FAIL B8: ค่าตั้งต้นชั้น ข เพี้ยน (%)', sri_os.fn_contract_gate_fields('document');
  end if;
  -- และต้องบังคับจริงด้วย ไม่ใช่แค่คืนค่าสวย
  perform pg_temp.afail('settings ว่าง: นิติบุคคลที่ขาดเอกสารยังสร้างงวดไม่ได้',
    pg_temp.sched('00000000-0000-0000-0000-0000000ac005', 2));
  raise notice 'ok B8 · settings ว่าง = ค่าตั้งต้นเข้มเท่าเกณฑ์ 6 ข้อเดิม และบังคับจริง';
end $$;

-- ------------------------------------------------------------
-- B9 · settings ที่ตั้งผิด = **พัง** ไม่ใช่คลายให้เอง
--      (ทุกเคสต้องจบที่ "สร้างงวดไม่ได้" ไม่ใช่ "สร้างได้เพราะไม่รู้จะบังคับอะไร")
-- ------------------------------------------------------------
do $$
declare r record;
begin
  perform pg_temp.alogin('a_super');
  for r in select * from (values
      ('ไม่ครบคีย์ (ขาด document)', '{"blocking": ["principal"]}'),
      ('ไม่ใช่ object',             '"principal"'),
      ('ชั้นเป็น object ไม่ใช่ array', '{"blocking": {"principal": true}, "document": ["file_urls"]}'),
      ('ชั้น ก ว่าง',               '{"blocking": [], "document": ["file_urls"]}'),
      ('ชั้น ข ว่าง',               '{"blocking": ["principal"], "document": []}'),
      ('ชื่อช่องสะกดผิด',           '{"blocking": ["principle"], "document": ["file_urls"]}'),
      ('ชื่อช่องที่ไม่มีในตาราง',     '{"blocking": ["principal"], "document": ["signature"]}')
    ) as m(label, cfg)
  loop
    insert into sri_os.settings(key, value) values ('contract.schedule_gate', r.cfg::jsonb)
    on conflict (key) do update set value = excluded.value;
    perform pg_temp.afail('settings ผิด (' || r.label || ') ต้องไม่ทำให้ด่านคลาย',
      pg_temp.sched('00000000-0000-0000-0000-0000000ac005', 3));
    -- สัญญาที่ครบทุกอย่างก็ต้องตกด้วย = พังดังๆ ไม่ใช่เดาให้
    perform pg_temp.afail('settings ผิด (' || r.label || ') แม้สัญญาครบก็ต้องพังให้เห็น',
      pg_temp.sched('00000000-0000-0000-0000-0000000ac001', 4));
  end loop;
  delete from sri_os.settings where key = 'contract.schedule_gate';
  raise notice 'ok B9 · settings ผิดรูป/ชั้นว่าง/ชื่อช่องไม่รู้จัก = raise ทุกเคส (ไม่มีทางหลวมลงเงียบๆ)';
end $$;

-- ------------------------------------------------------------
-- B10 · ไม่พบผู้ถือ = ถือว่า corporate_strict (fail closed)
-- ------------------------------------------------------------
do $$
declare v_row sri_os.contracts; v text[];
begin
  -- ใบนี้เป็นของ **ฝั่งบุคคล** และชั้น ข ขาดอยู่ → ปกติ unmet ต้องว่าง
  select c.* into v_row from sri_os.contracts c where c.id = '00000000-0000-0000-0000-0000000ac008';
  v := sri_os.fn_contract_gate_unmet(v_row);
  if cardinality(v) <> 0 then
    raise exception 'FAIL B10: fixture เพี้ยน — ใบบุคคลนี้ควรไม่ติดอะไร (unmet = %)', v;
  end if;
  v_row.owner_id := gen_random_uuid();   -- ผู้ถือที่ไม่มีอยู่
  v := sri_os.fn_contract_gate_unmet(v_row);
  if not (v @> array['counterparty_contact_id', 'file_urls']) then
    raise exception 'FAIL B10: ไม่พบผู้ถือแล้วด่านคลาย (unmet = %) — ต้องเข้มที่สุด', v;
  end if;
  raise notice 'ok B10 · ไม่พบผู้ถือ → ใช้เกณฑ์ corporate_strict (fail closed ไม่ fail open)';
end $$;

-- ------------------------------------------------------------
-- B11 · โครงสร้าง: ด่านอยู่ทั้งสองทาง · search_path รัดแล้ว · ไม่ถามสิทธิ์ · เรียกตรงไม่ได้
-- ------------------------------------------------------------
do $$
declare v text;
begin
  if not exists (select 1 from pg_trigger where tgrelid = 'sri_os.schedules'::regclass
                  and not tgisinternal and tgname = 'trg_schedule_complete'
                  and (tgtype & 4) <> 0 and (tgtype & 2) <> 0 and (tgtype & 1) <> 0) then
    raise exception 'FAIL B11: ไม่มี before insert row trigger trg_schedule_complete';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'sri_os.contracts'::regclass
                  and not tgisinternal and tgname = 'trg_contract_gate_no_backdoor'
                  and (tgtype & 16) <> 0 and (tgtype & 2) <> 0 and (tgtype & 1) <> 0) then
    raise exception 'FAIL B11: ไม่มี before update row trigger บน contracts → ประตูหลังเปิด';
  end if;

  -- search_path ต้องเป็น '' (โจทย์ของรอบนี้) ไม่ใช่ sri_os, public
  select string_agg(p.proname || ' → ' || coalesce(array_to_string(p.proconfig, ','), '(ไม่ตั้ง)'), ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.proname in ('fn_schedule_requires_complete_contract', 'fn_contract_gate_no_backdoor',
                       'fn_contract_gate_fields', 'fn_contract_gate_unmet', 'fn_asset_assign_ok')
     and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c in ('search_path=', 'search_path=""'));
  if v is not null then raise exception 'FAIL B11: search_path ไม่แน่น: %', v; end if;

  -- trigger ของด่านห้ามถามสิทธิ์ (ไม่งั้นปิดกฎได้จากหน้า Settings) และเรียกตรงไม่ได้
  select string_agg(p.proname, ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.proname in ('fn_schedule_requires_complete_contract', 'fn_contract_gate_no_backdoor')
     and (p.prosrc ~* 'fn_can'
       or has_function_privilege('public', p.oid, 'execute')
       or has_function_privilege('anon', p.oid, 'execute')
       or has_function_privilege('authenticated', p.oid, 'execute'));
  if v is not null then raise exception 'FAIL B11: trigger ของด่านหลวม: %', v; end if;

  -- ฟังก์ชันใหม่ทุกตัว: public/anon เรียกไม่ได้
  select string_agg(p.oid::regprocedure::text, ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname like 'fn\_contract\_gate%'
     and (has_function_privilege('public', p.oid, 'execute')
       or has_function_privilege('anon', p.oid, 'execute'));
  if v is not null then raise exception 'FAIL B11: public/anon เรียกได้: %', v; end if;

  -- view ต้องเป็น security_invoker (ไม่งั้นเป็นทางลัดอ่านสัญญาข้ามขอบเขต)
  if not exists (select 1 from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
                  where ns.nspname = 'sri_os' and c.relname = 'v_contract_data_health'
                    and array_to_string(c.reloptions, ',') ilike '%security_invoker=true%') then
    raise exception 'FAIL B11: v_contract_data_health ไม่ได้ตั้ง security_invoker';
  end if;
  raise notice 'ok B11 · ด่านครบทั้ง INSERT งวด + UPDATE สัญญา · search_path = '''' · ไม่ถามสิทธิ์ · เรียกตรงไม่ได้ · view invoker';
end $$;

-- ############################################################
-- G · เส้นทางที่ถูกต้องต้องยังทำได้ (ในฐานะ authenticated จริง ผ่าน grant + RLS + trigger)
-- ############################################################
do $$
declare v_o uuid;
begin
  select id into v_o from sri_os.owners where code = 'SRI_CORP';
  perform pg_temp.alogin('a_super');
  execute 'set local role authenticated';

  -- สร้าง/แก้สัญญา
  perform pg_temp.apass('สร้างสัญญาใหม่', format(
    'insert into sri_os.contracts(code, owner_id, type, principal, rate, rate_period, interest_method, start_date, installments, payment_day, counterparty_contact_id, file_urls) values (''GT-G1'', %L, ''lease'', 300000, 1.5, ''month'', ''simple'', current_date, 6, 1, %L, array[''g1.pdf''])',
    v_o, '00000000-0000-0000-0000-0000000af001'));
  perform pg_temp.arows('แก้เงื่อนไขสัญญา',
    'update sri_os.contracts set rate = 1.60 where code = ''GT-G1''', 1);

  -- ใส่งวด · เลื่อนงวด · แก้ยอด · waive
  perform pg_temp.apass('ใส่งวดให้สัญญาที่ครบ',
    'insert into sri_os.schedules(contract_id, period, due_date, expected_amount, principal_amount, interest_amount) select id, 1, current_date + 30, 1000, 900, 100 from sri_os.contracts where code = ''GT-G1''');
  perform pg_temp.arows('เลื่อนวันครบกำหนดของงวด',
    'update sri_os.schedules set due_date = due_date + 14 where contract_id = (select id from sri_os.contracts where code = ''GT-G1'')', 1);
  perform pg_temp.arows('แก้ยอดงวด (เงินต้น+ดอกเบี้ย = ยอดรวม)',
    'update sri_os.schedules set expected_amount = 1100, principal_amount = 1000, interest_amount = 100 where contract_id = (select id from sri_os.contracts where code = ''GT-G1'')', 1);
  perform pg_temp.arows('waive งวดที่ไม่เกิดจริง',
    'update sri_os.schedules set status = ''waived'' where contract_id = (select id from sri_os.contracts where code = ''GT-G1'')', 1);
  perform pg_temp.arows('ปิดสัญญาด้วย status',
    'update sri_os.contracts set status = ''closed'' where code = ''GT-G1''', 1);

  -- แก้ค่าตั้งค่า (คนที่มี settings.manage)
  perform pg_temp.apass('แก้ค่าตั้งค่าของด่าน',
    'insert into sri_os.settings(key, value) values (''contract.schedule_gate'', ''{"blocking": ["principal", "rate", "start_date", "term"], "document": ["counterparty_contact_id", "file_urls"]}''::jsonb) on conflict (key) do update set value = excluded.value');
  perform pg_temp.arows('ลบค่าตั้งค่ากลับไปใช้ค่าตั้งต้น',
    'delete from sri_os.settings where key = ''contract.schedule_gate''', 1);

  -- อ่านธง Data health ได้
  perform pg_temp.apass('อ่าน v_contract_data_health',
    'select count(*) from sri_os.v_contract_data_health');

  -- ถอนสิทธิ์การเห็น (super_admin มี users.manage) ยังทำได้
  perform pg_temp.arows('ถอนขอบเขตการเห็นผู้ถือ', format(
    'delete from sri_os.user_owner_access where user_id = %L and owner_id = %L', pg_temp.auid('a_staff'), v_o), 1);
  raise notice 'ok G · สร้าง/แก้/ปิดสัญญา · ใส่-เลื่อน-แก้-waive งวด · แก้/ลบค่าตั้งค่า · อ่านธง · ถอนสิทธิ์การเห็น ยังทำได้ครบ';
end $$;
reset role;

-- ############################################################
-- M · mutation — ถอดการแก้ออกทีละชิ้น เทสต์ข้างบนต้องแดง
--     (ทำแบบไม่ก๊อปปี้ body ของฟังก์ชันมาเขียนซ้ำ — กฎเดียวกันห้ามเขียนสองที่)
-- ############################################################

-- M1 · ถอด trigger ฝั่ง UPDATE → ประตูหลังเปิด (ยืนยันว่า B5 มีของจริงให้จับ)
do $$
begin
  drop trigger trg_contract_gate_no_backdoor on sri_os.contracts;
  begin
    update sri_os.contracts set file_urls = '{}' where id = '00000000-0000-0000-0000-0000000ac001';
  exception when others then
    raise exception 'FAIL M1: ถอด trigger แล้วยังถูกปฏิเสธ → B5 อาจผ่านเพราะเหตุอื่น';
  end;
  update sri_os.contracts set file_urls = array['ct1.pdf'] where id = '00000000-0000-0000-0000-0000000ac001';
  create trigger trg_contract_gate_no_backdoor before update on sri_os.contracts
    for each row execute function sri_os.fn_contract_gate_no_backdoor();
  perform pg_temp.afail('ติด trigger คืนแล้วประตูหลังปิดอีกครั้ง',
    'update sri_os.contracts set file_urls = ''{}'' where id = ''00000000-0000-0000-0000-0000000ac001''');
  raise notice 'ok M1 · ถอด trg_contract_gate_no_backdoor → ลบไฟล์ทีหลังสำเร็จ (B5 แดง) · ติดคืน → ปิดอีกครั้ง';
end $$;

-- M2 · ถอด trigger ฝั่ง INSERT งวด → สัญญาเปล่าก็ใส่งวดได้ (ยืนยัน B2/B3/B4)
do $$
begin
  drop trigger trg_schedule_complete on sri_os.schedules;
  begin
    execute pg_temp.sched('00000000-0000-0000-0000-0000000ac005', 50);
  exception when others then
    raise exception 'FAIL M2: ถอด trigger แล้วยังถูกปฏิเสธ → B4 อาจผ่านเพราะเหตุอื่น (%)', sqlerrm;
  end;
  -- ลบงวดไม่ได้ทุกกรณี (กฎเหล็กข้อ 1 · 20261008000004) → ทางออกคือ waived
  -- ข้อนี้จึงยืนยันด้วยตัวมันเองว่า "งวดที่หลุดเข้ามาตอนด่านหาย ลบทิ้งไม่ได้"
  -- = เปิดด่านครึ่งเดียวอันตรายกว่าไม่เปิด (บทเรียนข้อ 7)
  update sri_os.schedules set status = 'waived'
   where contract_id = '00000000-0000-0000-0000-0000000ac005' and period = 50;
  create trigger trg_schedule_complete before insert on sri_os.schedules
    for each row execute function sri_os.fn_schedule_requires_complete_contract();
  perform pg_temp.afail('ติด trigger คืนแล้วสัญญาเปล่าใส่งวดไม่ได้อีก',
    pg_temp.sched('00000000-0000-0000-0000-0000000ac005', 51));
  raise notice 'ok M2 · ถอด trg_schedule_complete → สัญญาเปล่าใส่งวดได้ (B2/B3/B4 แดง) · ติดคืน → ปิดอีกครั้ง';
end $$;

-- M3 · ย้ายสิทธิ์ใหม่ไปให้ Manager ในตาราง → Manager มอบหมายได้ทันที
--      พิสูจน์สองอย่าง: ด่านอ่านจาก role_permissions จริง (ไม่ hard-code ชื่อ role)
--      และ A4 จับของจริง
do $$
begin
  insert into sri_os.role_permissions(role_key, permission_key)
  values ('manager', 'asset.assign_manager') on conflict do nothing;

  perform pg_temp.alogin('a_mgr');
  execute 'set local role authenticated';
  perform pg_temp.arows('ติ๊กสิทธิ์ให้ manager แล้ว Manager มอบหมายได้', format(
    'update sri_os.assets set manager_user_id = %L where id = %L',
    pg_temp.auid('a_mgr'), '00000000-0000-0000-0000-0000000a9001'), 1);
  execute 'reset role';

  delete from sri_os.role_permissions where role_key = 'manager' and permission_key = 'asset.assign_manager';
  perform pg_temp.alogin('a_mgr');
  execute 'set local role authenticated';
  perform pg_temp.a_no_change('ถอนสิทธิ์คืนแล้ว Manager มอบหมายไม่ได้อีก', format(
    'update sri_os.assets set manager_user_id = %L where id = %L',
    pg_temp.auid('a_mgr2'), '00000000-0000-0000-0000-0000000a9001'),
    format('(select manager_user_id from sri_os.assets where id = %L) = %L',
      '00000000-0000-0000-0000-0000000a9001', pg_temp.auid('a_mgr')));
  execute 'reset role';
  raise notice 'ok M3 · ติ๊ก asset.assign_manager ให้ manager → ทำได้ทันที · ถอนคืน → ทำไม่ได้ (ด่านอ่านตาราง ไม่ hard-code role) · A4 จับของจริง';
end $$;

-- M4 · ถอนสิทธิ์ใหม่จาก management → Management มอบหมายไม่ได้ (ยืนยัน A2 จับของจริง)
do $$
begin
  delete from sri_os.role_permissions where role_key = 'management' and permission_key = 'asset.assign_manager';
  perform pg_temp.alogin('a_mgmt');
  execute 'set local role authenticated';
  perform pg_temp.a_no_change('ถอนสิทธิ์จาก management แล้วมอบหมายไม่ได้', format(
    'update sri_os.assets set manager_user_id = %L where id = %L',
    pg_temp.auid('a_mgr2'), '00000000-0000-0000-0000-0000000a9001'),
    format('(select manager_user_id from sri_os.assets where id = %L) = %L',
      '00000000-0000-0000-0000-0000000a9001', pg_temp.auid('a_mgr')));
  execute 'reset role';
  insert into sri_os.role_permissions(role_key, permission_key)
  values ('management', 'asset.assign_manager') on conflict do nothing;
  raise notice 'ok M4 · ถอน asset.assign_manager จาก management → มอบหมายไม่ได้ (A2 แดง)';
end $$;

-- M5 · migration รันซ้ำได้ (idempotent) — รันไฟล์ซ้ำในธุรกรรมนี้ไม่ได้
--      (psql \i ใช้ไม่ได้ใน DO) → ตรวจชิ้นที่เสี่ยงที่สุดแทน: insert ซ้ำ + replace ซ้ำ
do $$
declare n_before int; n_after int;
begin
  select count(*) into n_before from sri_os.permissions;
  insert into sri_os.permissions(key, label, note)
  values ('asset.assign_manager', 'มอบหมายผู้บริหารทรัพย์', 'x')
  on conflict (key) do update set label = excluded.label;
  insert into sri_os.role_permissions(role_key, permission_key)
  values ('super_admin', 'asset.assign_manager'), ('management', 'asset.assign_manager')
  on conflict (role_key, permission_key) do nothing;
  select count(*) into n_after from sri_os.permissions;
  if n_after <> n_before then raise exception 'FAIL M5: insert ซ้ำเพิ่มแถว'; end if;
  if (select count(*) from sri_os.role_permissions where permission_key = 'asset.assign_manager') <> 2 then
    raise exception 'FAIL M5: role_permissions ของสิทธิ์ใหม่ไม่ใช่ 2 แถว';
  end if;
  raise notice 'ok M5 · insert ของ migration รันซ้ำไม่เพิ่ม/ไม่ทับของผู้ใช้';
end $$;

do $$ begin raise notice '=== assign + contract tiers ผ่านทั้งหมด ==='; end $$;

rollback;
