-- ============================================================
-- SRI OS · เทสต์ของ 20261020000000_column_exposure.sql (D-089)
--   "RLS ซ่อนแถวได้ ซ่อนคอลัมน์ไม่ได้" + เงื่อนไขบังคับก่อนสร้างบัญชี Staff
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ rollback ปิดท้าย · เจอข้อผิด = raise exception
-- รันด้วย scripts/test-rls-local.sh (ไฟล์ลงท้าย _test.sql ถูกหยิบไปรันเอง)
--
-- สิ่งที่ไฟล์นี้ต้องพิสูจน์ (ไม่ใช่แค่ "เรียกได้ไม่ error")
--   C1 ด่านปิดได้ทุกทาง: select * · ระบุชื่อคอลัมน์ · where/order by · returning · view
--   C2 ทางเข้าของระดับที่มีสิทธิ์ยังอ่านได้ และ **คนไม่มีสิทธิ์ได้ NULL ไม่ใช่ค่าจริง**
--   C3 เคสข้อมูลขาด: ไม่มีแถวใน app_users · ระดับที่ไม่มีสิทธิ์เลย → ต้องไม่ fail open
--   C4 guard ของ P4: เพิ่มคอลัมน์/ตารางปลอมแล้ว guard ต้องพัง (พิสูจน์ว่า guard ทำงานจริง)
--   C5 เงื่อนไขก่อนสร้างบัญชี Staff: ด่านพัง = สร้างไม่ได้ · ด่านดี = สร้างได้
--   C6 โครงสร้างของด่านเอง: role เจ้าของทางเข้าไม่ใช่ทางข้าม RLS · ทะเบียนเขียนไม่ได้
-- ============================================================

begin;

-- ---------- C00 · ด่านต้องเรียบร้อยก่อนเริ่ม ----------
-- ต้องเป็นเคสแรกสุด เพราะ fixtures ข้างล่างสร้างบัญชีระดับ staff ซึ่ง trigger ของ
-- 20261020000000 จะปฏิเสธถ้าด่านพัง → ถ้าไม่ตรวจก่อน เทสต์จะแดงด้วย error ดิบๆ
-- ที่อ่านไม่รู้ว่าสาเหตุคืออะไร
do $$
begin
  begin
    perform sri_os.fn_column_exposure_guard();
  exception when others then
    raise exception 'FAIL: C00 ด่านคอลัมน์ไม่เรียบร้อยก่อนเทสต์จะเริ่ม → เคสอื่นในไฟล์นี้เชื่อไม่ได้ · สาเหตุ: %', sqlerrm;
  end;
  raise notice 'ok C00 · ด่านคอลัมน์เรียบร้อยก่อนเริ่มเทสต์';
end $$;

-- ---------- fixtures: ผู้ใช้ 4 ระดับ + ไม่มีสิทธิ์เลย + ไม่มีแถวใน app_users ----------
-- ตารางช่วยอยู่ใน temp schema โดยเจตนา: ตารางใหม่ใน sri_os จะถูก guard ของไฟล์นี้
-- จับว่า "ยังไม่จัดประเภท" ทันที (ซึ่งถูกต้อง) แล้วเคส C5 จะแดงด้วยสาเหตุที่ไม่ใช่ของมัน
create temporary table zz_ce_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into zz_ce_uid(label) values
  ('super'), ('mgmt'), ('mgr'), ('mgr2'), ('staff'), ('nobody'), ('ghost');
insert into auth.users(id) select id from zz_ce_uid;

-- role authenticated ต้องเรียกตัวช่วยใน temp schema ได้ (แพทเทิร์นเดียวกับเทสต์ไฟล์อื่น)
do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.zz_ce_uid to authenticated', s);
end $$;

-- ระดับที่ไม่มีสิทธิ์อะไรเลย (ไม่มีแถวใน role_permissions) — เคส "ไม่ส่งข้อมูล" ของตารางสิทธิ์
insert into sri_os.roles(key, label, rank_order) values ('zz_nobody', 'ทดสอบ · ไม่มีสิทธิ์เลย', 99);

insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, u.label || '@ce.local', u.label, x.role, true
  from zz_ce_uid u
  join (values
    ('super',  'super_admin'),
    ('mgmt',   'management'),
    ('mgr',    'manager'),
    ('mgr2',   'manager'),
    ('staff',  'staff'),
    ('nobody', 'zz_nobody')      -- 'ghost' ไม่มีแถวใน app_users โดยตั้งใจ
  ) as x(label, role) on x.label = u.label;

create or replace function pg_temp.uid(p_label text) returns uuid
language sql stable as $fn$ select id from zz_ce_uid where label = p_label $fn$;

create or replace function pg_temp.login(p_label text) returns void
language sql as $fn$
  select set_config('test.uid',
    coalesce((select id::text from zz_ce_uid where label = p_label), gen_random_uuid()::text), true);
$fn$;

-- "ต้องถูกปฏิเสธเพราะสิทธิ์" — ต้องเป็น insufficient_privilege (42501) เท่านั้น
-- error อื่น (พิมพ์ SQL ผิด/คอลัมน์ไม่มี) ต้องไม่นับว่าผ่าน ไม่งั้นเทสต์ผ่านฟรีๆ
create or replace function pg_temp.must_deny(p_label text, p_sql text) returns void
language plpgsql as $fn$
begin
  execute p_sql;
  raise exception 'FAIL: % — ควรถูกปฏิเสธที่ชั้นสิทธิ์คอลัมน์ แต่สำเร็จ · sql: %', p_label, p_sql;
exception
  when insufficient_privilege then return;
  when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    raise exception 'FAIL: % — ถูกปฏิเสธด้วยสาเหตุอื่น (% / %) ไม่ใช่สิทธิ์คอลัมน์ · sql: %',
      p_label, sqlstate, sqlerrm, p_sql;
end $fn$;

create or replace function pg_temp.must_pass(p_label text, p_sql text) returns void
language plpgsql as $fn$
begin
  execute p_sql;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: % — ควรสำเร็จแต่ล้ม (% / %) · sql: %', p_label, sqlstate, sqlerrm, p_sql;
end $fn$;

create or replace function pg_temp.must_raise(p_label text, p_sql text, p_needle text) returns void
language plpgsql as $fn$
begin
  execute p_sql;
  raise exception 'FAIL: % — ควร raise แต่ผ่านไปเฉยๆ · sql: %', p_label, p_sql;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  if position(p_needle in sqlerrm) = 0 then
    raise exception 'FAIL: % — raise แล้วแต่ข้อความไม่ใช่เรื่องที่ตั้งใจตรวจ (ต้องมี "%") · ได้: %',
      p_label, p_needle, sqlerrm;
  end if;
end $fn$;

-- ---------- fixtures: ผู้ถือ · ทรัพย์ · บัญชีธนาคาร · ผู้ติดต่อ ----------
insert into sri_os.owners(code, type, policy, name_th, tax_id_last4, status)
values ('ZZCE1', 'person', 'personal_flexible', 'ผู้ถือทดสอบ D-089', '1234', 'active');

insert into sri_os.user_owner_access(user_id, owner_id)
select u.id, o.id from zz_ce_uid u, sri_os.owners o
 where o.code = 'ZZCE1' and u.label in ('mgr', 'mgr2', 'staff', 'nobody');

insert into sri_os.assets(code, name, owner_id, class_id, category_id, status,
                          units, ticker, ownership_pct, location, manager_user_id)
select 'ZZCE_A1', 'ทรัพย์ของ mgr', o.id, ct.class_id, ct.id, 'active',
       100, 'ZZTICK', 0.5500, 'กรุงเทพ', pg_temp.uid('mgr')
  from sri_os.owners o, sri_os.asset_categories ct
 where o.code = 'ZZCE1' and ct.code = 'RE_RENTAL';

insert into sri_os.bank_accounts(owner_id, bank, account_name, display_name,
                                 account_no_last4, coa_id, opening_balance, opening_date)
select o.id, 'kbank', 'บัญชีทดสอบ', 'กสิกร ทดสอบ', '9999',
       (select id from sri_os.chart_of_accounts where is_active order by code limit 1),
       250000, current_date
  from sri_os.owners o where o.code = 'ZZCE1';

insert into sri_os.contacts(first_name, last_name, tax_id_last4, note)
values ('ผู้ติดต่อ', 'ทดสอบ', '5678', 'บันทึกที่ไม่ควรให้คนลงข้อมูลอ่าน');

-- view ที่อ่านคอลัมน์ปิด (ต้องพิสูจน์ว่า "ผ่าน view" ก็ไม่หลุด · event trigger ของ
-- 20261007000000 บังคับ security_invoker = true ให้ view ใหม่ทุกตัวอยู่แล้ว)
create view sri_os.zz_ce_leak_view as
  select id, code, units, ownership_pct from sri_os.assets;
grant select on sri_os.zz_ce_leak_view to authenticated;

do $$
begin
  if coalesce(array_to_string((select reloptions from pg_class
                                where oid = 'sri_os.zz_ce_leak_view'::regclass), ','), '')
     not ilike '%security_invoker=true%' then
    raise exception 'FAIL: view ใหม่ไม่ได้ security_invoker = true → event trigger ของ 20261007000000 หายไป แปลว่า view กลายเป็นทางข้าม RLS/สิทธิ์คอลัมน์ได้อีก';
  end if;
  raise notice 'ok C0 · fixtures พร้อม · view ใหม่ถูกบังคับเป็น security_invoker';
end $$;

-- ============================================================
-- C1 · ด่านต้องปิดได้ทุกทาง · ไล่ทีละระดับจากทะเบียนจริง
--      **ระบุชื่อคอลัมน์ตรงๆ มาก่อน select *** โดยเจตนา:
--      ถ้าวันหนึ่งด่านเหลือแค่ครอบ select * เคสแรกนี้ต้องแดงก่อน
-- ============================================================
set local role authenticated;

select pg_temp.login('staff');
do $$
declare r record; n int := 0;
begin
  -- คอลัมน์ที่จัดประเภทเป็น grant ทุกแถวในทะเบียน ต้องอ่านไม่ได้ทั้งสองรูปแบบ
  for r in select table_name, column_name from sri_os.column_exposure
            where exposure = 'grant' order by table_name, column_name
  loop
    perform pg_temp.must_deny(
      format('C1a staff ระบุชื่อคอลัมน์ %s.%s', r.table_name, r.column_name),
      format('select %I from sri_os.%I', r.column_name, r.table_name));
    perform pg_temp.must_deny(
      format('C1b staff ใช้คอลัมน์ใน where %s.%s', r.table_name, r.column_name),
      format('select 1 from sri_os.%I where %I is not null', r.table_name, r.column_name));
    perform pg_temp.must_deny(
      format('C1c staff ใช้คอลัมน์ใน order by %s.%s', r.table_name, r.column_name),
      format('select 1 from sri_os.%I order by %I', r.table_name, r.column_name));
    n := n + 1;
  end loop;
  if n < 15 then
    raise exception 'FAIL: ทะเบียนบอกว่ามีคอลัมน์ปิดแค่ % คอลัมน์ — เทสต์นี้แทบไม่ได้ตรวจอะไร', n;
  end if;
  -- select * ของตารางที่มีคอลัมน์ปิด ต้องล้มทั้งตาราง
  for r in select distinct table_name from sri_os.column_exposure where exposure = 'grant'
  loop
    perform pg_temp.must_deny(format('C1d staff select * ของ %s', r.table_name),
                              format('select * from sri_os.%I', r.table_name));
  end loop;
  raise notice 'ok C1 · ปิดครบ % คอลัมน์ ทั้งแบบระบุชื่อ · where · order by · select *', n;
end $$;

-- ทางผ่าน view
select pg_temp.must_deny('C1e staff อ่านคอลัมน์ปิดผ่าน view',
  'select units from sri_os.zz_ce_leak_view');
select pg_temp.must_deny('C1f staff select * ผ่าน view',
  'select * from sri_os.zz_ce_leak_view');

-- ทางผ่าน RETURNING (insert ผ่าน policy ได้ แต่ห้ามอ่านคอลัมน์ปิดกลับมา)
select pg_temp.must_deny('C1g staff insert ... returning คอลัมน์ปิด',
  $$insert into sri_os.contacts(first_name) values ('ทดสอบ returning') returning tax_id_last4$$);
select pg_temp.must_pass('C1h staff insert ปกติ (ไม่ returning คอลัมน์ปิด) ต้องยังได้',
  $$insert into sri_os.contacts(first_name) values ('ทดสอบ insert ปกติ') returning id$$);

-- เส้นทางที่ต้องไม่พัง: คอลัมน์ที่เปิด ต้องอ่านได้ตามปกติ (P2)
select pg_temp.must_pass('C1i staff อ่านคอลัมน์ที่เปิดของ assets',
  'select id, code, name, class_id, owner_id, status from sri_os.assets');
select pg_temp.must_pass('C1j staff อ่านคอลัมน์ที่เปิดของ bank_accounts (ฟอร์มต้องใช้ coa_id)',
  'select id, display_name, short_label, coa_id, is_active from sri_os.bank_accounts');
select pg_temp.must_pass('C1k staff อ่าน owners/contacts ตามปกติ',
  'select o.code, o.name_th, o.policy, c.first_name, c.phone from sri_os.owners o, sri_os.contacts c');

-- ============================================================
-- C2 · ทางเข้าของระดับที่มีสิทธิ์ · ค่าจริงต้องมาตามสิทธิ์ · ไม่มีสิทธิ์ต้องได้ NULL
--      และ **RLS ต้องยังกรองแถว** (ไม่ใช่ว่าพอผ่านฟังก์ชันแล้วเห็นทั้งตาราง)
-- ============================================================
do $$
declare
  v_units numeric; v_pct numeric; v_rows int; v_tax text; v_open numeric;
begin
  -- staff: เห็นแถวทรัพย์ได้ (ทางผ่านของคนคีย์รายการ) แต่คอลัมน์ปิดต้องเป็น NULL
  perform pg_temp.login('staff');
  select count(*), max(units), max(ownership_pct) into v_rows, v_units, v_pct
    from sri_os.fn_assets_visible() where code = 'ZZCE_A1';
  if v_rows <> 1 then
    raise exception 'FAIL: C2a staff ควรเห็นแถวทรัพย์ในขอบเขตผู้ถือ (ฟอร์มต้องเลือกทรัพย์ได้) แต่ได้ % แถว', v_rows;
  end if;
  if v_units is not null or v_pct is not null then
    raise exception 'FAIL: C2a staff ได้ค่าจริงของคอลัมน์ปิดจากทางเข้า (units=% · pct=%)', v_units, v_pct;
  end if;

  -- manager: มี asset.view_assigned → เห็น units ของทรัพย์ที่ตัวเองบริหาร
  --          ไม่มี portfolio.view_all → ownership_pct ต้องเป็น NULL
  perform pg_temp.login('mgr');
  select count(*), max(units), max(ownership_pct) into v_rows, v_units, v_pct
    from sri_os.fn_assets_visible() where code = 'ZZCE_A1';
  if v_rows <> 1 or v_units is null then
    raise exception 'FAIL: C2b ผู้บริหารทรัพย์ควรอ่าน units ของทรัพย์ที่ตัวเองดูแลได้ (แถว % · units %)', v_rows, v_units;
  end if;
  if v_pct is not null then
    raise exception 'FAIL: C2b Manager อ่าน ownership_pct ได้ (= ภาพรวมการถือ) ซึ่งลูกพี่สั่งห้าม · ได้ %', v_pct;
  end if;

  -- manager คนที่สอง: ไม่ได้ถูกมอบหมายทรัพย์นี้ → RLS ต้องกรองแถวทิ้งทั้งแถว
  perform pg_temp.login('mgr2');
  select count(*) into v_rows from sri_os.fn_assets_visible() where code = 'ZZCE_A1';
  if v_rows <> 0 then
    raise exception 'FAIL: C2c ทางเข้าคืนแถวทรัพย์ที่ Manager คนนี้ไม่ได้ดูแล % แถว → ฟังก์ชัน definer ข้าม RLS', v_rows;
  end if;

  -- management: เห็นครบ
  perform pg_temp.login('mgmt');
  select max(units), max(ownership_pct) into v_units, v_pct
    from sri_os.fn_assets_visible() where code = 'ZZCE_A1';
  if v_units is null or v_pct is null then
    raise exception 'FAIL: C2d ผู้บริหารอ่านคอลัมน์ปิดไม่ได้ (units % · pct %) → เส้นทางที่ถูกต้องพัง', v_units, v_pct;
  end if;
  select max(opening_balance) into v_open from sri_os.fn_bank_accounts_visible();
  if v_open is null then
    raise exception 'FAIL: C2d ผู้บริหารอ่าน opening_balance ไม่ได้ → หน้างบ/ยอดธนาคารจะพัง';
  end if;
  select max(tax_id_last4) into v_tax from sri_os.fn_owners_visible() where code = 'ZZCE1';
  if v_tax is null then
    raise exception 'FAIL: C2d คนที่มี settings.manage อ่าน tax_id_last4 ไม่ได้';
  end if;

  -- manager/staff กับยอดยกมา: ต้องเป็น NULL ทั้งคู่ (คนละเหตุผลเดียวกัน)
  perform pg_temp.login('mgr');
  if (select max(opening_balance) from sri_os.fn_bank_accounts_visible()) is not null then
    raise exception 'FAIL: C2e Manager อ่าน opening_balance ได้ (ไม่มี portfolio.view_all)';
  end if;
  perform pg_temp.login('staff');
  if (select max(opening_balance) from sri_os.fn_bank_accounts_visible()) is not null then
    raise exception 'FAIL: C2e Staff อ่าน opening_balance ได้';
  end if;
  if (select max(tax_id_last4) from sri_os.fn_owners_visible()) is not null then
    raise exception 'FAIL: C2e Staff อ่าน owners.tax_id_last4 ได้';
  end if;
  if (select max(note) from sri_os.fn_contacts_visible()) is not null then
    raise exception 'FAIL: C2e Staff อ่าน contacts.note ได้';
  end if;
  raise notice 'ok C2 · ทางเข้าให้ค่าตามสิทธิ์จริง และ RLS ยังกรองแถวใน definer';
end $$;

-- ============================================================
-- C3 · เคสข้อมูลขาด · ต้องไม่ fail open
--      (บทเรียน mace-windu ข้อ 3: เทสต์ที่ส่งข้อมูลครบเสมอจะไม่แตะเส้นทางที่ข้อมูลขาด)
-- ============================================================
do $$
declare v_rows int; v_tax text; v_units numeric;
begin
  -- ghost: ไม่มีแถวใน app_users เลย (auth.uid() มีค่า แต่ไม่รู้จักในระบบ)
  perform pg_temp.login('ghost');
  select count(*) into v_rows from sri_os.fn_assets_visible();
  if v_rows <> 0 then
    raise exception 'FAIL: C3a ผู้ใช้ที่ไม่มีแถวใน app_users เห็นทรัพย์ % แถว', v_rows;
  end if;
  select count(*), max(tax_id_last4) into v_rows, v_tax from sri_os.fn_owners_visible();
  if v_tax is not null then
    raise exception 'FAIL: C3a ผู้ใช้ที่ไม่มีแถวใน app_users อ่าน tax_id_last4 ได้';
  end if;

  -- nobody: มีแถวใน app_users แต่ระดับไม่มีสิทธิ์อะไรเลย
  perform pg_temp.login('nobody');
  select count(*), max(units) into v_rows, v_units from sri_os.fn_assets_visible();
  if v_units is not null then
    raise exception 'FAIL: C3b ระดับที่ไม่มีสิทธิ์เลยอ่าน units ได้';
  end if;
  if (select max(tax_id_last4) from sri_os.fn_owners_visible()) is not null
     or (select max(note) from sri_os.fn_contacts_visible()) is not null
     or (select max(opening_balance) from sri_os.fn_bank_accounts_visible()) is not null then
    raise exception 'FAIL: C3b ระดับที่ไม่มีสิทธิ์เลยอ่านคอลัมน์ปิดได้ = fail open';
  end if;

  -- ไม่ได้ล็อกอินเลย (auth.uid() = null)
  perform set_config('test.uid', '', true);
  if (select count(*) from sri_os.fn_assets_visible()) <> 0 then
    raise exception 'FAIL: C3c ไม่ล็อกอินก็ยังเห็นแถวทรัพย์';
  end if;
  if (select max(tax_id_last4) from sri_os.fn_owners_visible()) is not null then
    raise exception 'FAIL: C3c ไม่ล็อกอินก็อ่าน tax_id_last4 ได้';
  end if;
  raise notice 'ok C3 · ไม่มีแถวใน app_users · ไม่มีสิทธิ์เลย · ไม่ล็อกอิน → ไม่ fail open';
end $$;

-- ทะเบียนต้องเขียนไม่ได้จากแอป (ไม่งั้นเปลี่ยนด่านเองได้)
select pg_temp.login('super');
do $$
begin
  -- ไม่มี policy เขียน = RLS ปฏิเสธด้วย 42501 "violates row-level security policy"
  -- (แม้แต่คนที่มี settings.manage · เปลี่ยนด่านได้จาก migration เท่านั้น)
  begin
    insert into sri_os.column_exposure(table_name, column_name, exposure, rationale)
      values ('assets', 'zz_ce_จากแอป', 'open', 'พยายามเปิดคอลัมน์ปิดจากฝั่งแอป');
    raise exception 'FAIL: C3d แอปเขียนทะเบียนด่านคอลัมน์ได้ (ต้องแก้ได้จาก migration เท่านั้น)';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if sqlstate <> '42501' then
      raise exception 'FAIL: C3d ถูกปฏิเสธด้วยสาเหตุอื่น (% · %)', sqlstate, sqlerrm;
    end if;
  end;
  begin
    update sri_os.column_exposure set exposure = 'open' where table_name = 'assets';
    if (select exposure from sri_os.column_exposure
         where table_name = 'assets' and column_name = 'units') = 'open' then
      raise exception 'FAIL: C3d แอปแก้ทะเบียนด่านคอลัมน์ได้';
    end if;
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if sqlstate <> '42501' then
      raise exception 'FAIL: C3d update ถูกปฏิเสธด้วยสาเหตุอื่น (% · %)', sqlstate, sqlerrm;
    end if;
  end;
  raise notice 'ok C3d · ทะเบียนด่านคอลัมน์เขียนจากแอปไม่ได้ (ไม่มี policy เขียน)';
end $$;

reset role;

-- ============================================================
-- C4 · guard ของ P4 ต้องจับของใหม่ได้จริง — ไม่ใช่ผ่านเพราะวันนี้ครบ
--      พิสูจน์ด้วยการ **เพิ่มคอลัมน์ปลอม** และ **เพิ่มตารางปลอม**
-- ============================================================
do $$
declare n int;
begin
  -- ของจริงวันนี้ต้องสะอาดก่อน ไม่งั้นเคสถัดไปแดงด้วยสาเหตุอื่น
  perform sri_os.fn_column_exposure_guard();

  -- (ก) คอลัมน์ปลอมในตารางที่จัดประเภทแล้ว
  alter table sri_os.assets add column zz_ce_probe text;
  select count(*) into n from sri_os.fn_column_exposure_unclassified()
   where object_name = 'assets.zz_ce_probe';
  if n <> 1 then
    raise exception 'FAIL: C4a คำถามที่ใช้หา "คอลัมน์ที่ยังไม่จัดประเภท" หาคอลัมน์ใหม่ไม่เจอ → guard ผ่านฟรีๆ';
  end if;
  perform pg_temp.must_raise('C4a guard ต้องพังเมื่อมีคอลัมน์ใหม่',
    'select sri_os.fn_column_exposure_guard()', 'ยังไม่จัดประเภท');
  -- และคอลัมน์ใหม่ต้อง **อ่านไม่ได้เอง** เพราะตารางไม่มี select ระดับตารางอีกแล้ว
  if has_column_privilege('authenticated', 'sri_os.assets'::regclass, 'zz_ce_probe', 'select') then
    raise exception 'FAIL: C4a คอลัมน์ใหม่ของตารางที่มีด่าน อ่านได้ทันทีโดยไม่มีใครจัดประเภท (deny by default หาย)';
  end if;
  alter table sri_os.assets drop column zz_ce_probe;
  perform sri_os.fn_column_exposure_guard();

  -- (ข) ตารางปลอม
  create table sri_os.zz_ce_probe_table (id uuid primary key default gen_random_uuid());
  select count(*) into n from sri_os.fn_column_exposure_unclassified()
   where object_name = 'zz_ce_probe_table';
  if n < 1 then
    raise exception 'FAIL: C4b guard หาตารางใหม่ที่ยังไม่อยู่ในทะเบียนไม่เจอ';
  end if;
  perform pg_temp.must_raise('C4b guard ต้องพังเมื่อมีตารางใหม่',
    'select sri_os.fn_column_exposure_guard()', 'ยังไม่จัดประเภท');
  drop table sri_os.zz_ce_probe_table;
  perform sri_os.fn_column_exposure_guard();

  -- (ค) ทะเบียนที่อ้างของที่ไม่มีจริง (เปลี่ยนชื่อคอลัมน์ = ด่านที่คิดว่ามีแต่ไม่มี)
  insert into sri_os.column_exposure(table_name, column_name, exposure, min_permission, rationale)
    values ('assets', 'zz_ce_ไม่มีจริง', 'grant', 'portfolio.view_all', 'แถวทดสอบว่า guard จับของที่ไม่มีจริงได้');
  perform pg_temp.must_raise('C4c guard ต้องพังเมื่อทะเบียนอ้างคอลัมน์ที่ไม่มี',
    'select sri_os.fn_column_exposure_guard()', 'ยังไม่จัดประเภท');
  delete from sri_os.column_exposure where column_name = 'zz_ce_ไม่มีจริง';

  -- (ง) ด่านถูกถอด (U1) → guard ต้องพังด้วยข้อความเรื่องด่านไม่ติด ไม่ใช่เงียบ
  grant select on sri_os.assets to authenticated;
  perform pg_temp.must_raise('C4d guard ต้องพังเมื่อมีใคร grant select ระดับตารางคืน',
    'select sri_os.fn_column_exposure_guard()', 'ไม่ติดจริง');
  perform sri_os.fn_apply_column_exposure();
  perform sri_os.fn_column_exposure_guard();

  -- (จ) เหตุผลของการจัดประเภทแบบ row ตาย → ต้องแดง
  --     (ผ่อน policy ของ contracts ให้กว้างขึ้นแล้วตรวจ)
  create policy zz_ce_wide_read on sri_os.contracts for select to authenticated using (true);
  perform pg_temp.must_raise('C4e guard ต้องพังเมื่อ policy ที่เป็นเหตุผลของ row ถูกผ่อน',
    'select sri_os.fn_column_exposure_guard()', 'ไม่ติดจริง');
  drop policy zz_ce_wide_read on sri_os.contracts;
  perform sri_os.fn_column_exposure_guard();

  -- (ฉ) ทางเข้ากลายเป็นทางข้าม RLS (เจ้าของเป็นเจ้าของตาราง) → ต้องแดง
  alter function sri_os.fn_owners_visible() owner to current_user;
  perform pg_temp.must_raise('C4f guard ต้องพังเมื่อเจ้าของฟังก์ชันทางเข้าเป็นเจ้าของตาราง',
    'select sri_os.fn_column_exposure_guard()', 'ไม่ติดจริง');
  perform sri_os.fn_apply_column_exposure();
  perform sri_os.fn_column_exposure_guard();

  raise notice 'ok C4 · guard พังจริงทั้ง 6 เคส (คอลัมน์ใหม่ · ตารางใหม่ · ทะเบียนค้าง · ด่านถูกถอด · policy ถูกผ่อน · ทางเข้าถูกยกสิทธิ์)';
end $$;

-- ============================================================
-- C5 · เงื่อนไขบังคับก่อนสร้างบัญชี Staff (D-089)
--      ระดับที่ไม่มี ledger.read = "ลงข้อมูลได้แต่อ่านสมุดไม่ได้" → ต้องมีด่านก่อน
-- ============================================================
do $$
declare v_id uuid := gen_random_uuid();
begin
  insert into auth.users(id) values (v_id);

  -- ด่านดี → สร้างได้
  insert into sri_os.app_users(id, email, display_name, role, is_active)
    values (v_id, 'zz_ce_staff@ce.local', 'staff ใหม่', 'staff', true);
  delete from sri_os.app_users where id = v_id;

  -- ทำให้ด่านพัง (คอลัมน์ใหม่ที่ยังไม่จัดประเภท) → ห้ามสร้างบัญชีระดับนั้น
  alter table sri_os.bank_accounts add column zz_ce_probe text;
  perform pg_temp.must_raise('C5a สร้างบัญชี staff ตอนด่านพัง',
    format($q$insert into sri_os.app_users(id, email, display_name, role, is_active)
             values (%L, 'zz_ce_staff2@ce.local', 'staff ใหม่', 'staff', true)$q$, v_id),
    'D-089');

  -- ระดับที่มี ledger.read ยังสร้างได้ (เงื่อนไขนี้ไม่ใช่ล็อกทั้งระบบ)
  insert into sri_os.app_users(id, email, display_name, role, is_active)
    values (v_id, 'zz_ce_mgr@ce.local', 'manager ใหม่', 'manager', true);

  -- ย้ายระดับลงมาเป็น staff ตอนด่านพัง = เท่ากับสร้างบัญชี staff → ต้องถูกปฏิเสธ
  perform pg_temp.must_raise('C5b ย้ายระดับลงเป็น staff ตอนด่านพัง',
    format('update sri_os.app_users set role = ''staff'' where id = %L', v_id), 'D-089');

  -- ปิดใช้งานไว้ก่อนได้ (ไม่ใช่บัญชีที่ใช้งานอยู่) — ไม่ควรล็อกงานที่ไม่เกี่ยว
  perform pg_temp.must_pass('C5c ปิดใช้งานบัญชีได้ตอนด่านพัง',
    format('update sri_os.app_users set is_active = false where id = %L', v_id));

  alter table sri_os.bank_accounts drop column zz_ce_probe;
  perform sri_os.fn_column_exposure_guard();

  -- ด่านกลับมาดี → ย้ายเป็น staff ได้
  perform pg_temp.must_pass('C5d ด่านดีแล้วย้ายเป็น staff ได้',
    format('update sri_os.app_users set role = ''staff'', is_active = true where id = %L', v_id));
  delete from sri_os.app_users where id = v_id;
  raise notice 'ok C5 · เงื่อนไขก่อนสร้างบัญชี Staff บังคับที่ DB จริง และไม่ล็อกเส้นทางอื่น';
end $$;

-- ============================================================
-- C6 · โครงสร้างของด่านเอง (ไล่จาก catalog ไม่ใช่เชื่อไฟล์ migration)
-- ============================================================
do $$
declare v text; n int;
begin
  -- (ก) ตารางที่มีด่าน ต้องไม่มี select ระดับตารางให้ใครนอกจากเจ้าของ/ตัวอ่าน
  select string_agg(distinct c.relname, ', ') into v
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
    cross join lateral aclexplode(c.relacl) acl
   where ns.nspname = 'sri_os' and c.relkind = 'r' and acl.privilege_type = 'SELECT'
     and acl.grantee <> c.relowner
     and (acl.grantee = 0 or pg_get_userbyid(acl.grantee) <> 'sri_os_column_reader')
     and exists (select 1 from sri_os.column_exposure ce
                  where ce.table_name = c.relname and ce.exposure = 'grant');
  if v is not null then
    raise exception 'FAIL: C6a ตารางที่มีคอลัมน์ปิดยังมี select ระดับตาราง: %', v;
  end if;

  -- (ข) role เจ้าของทางเข้าต้องไม่เป็นทางข้าม: ไม่ login · ไม่ superuser · ไม่ bypassrls
  --     และต้องไม่มีใครเป็นสมาชิกของมัน (ไม่งั้นใช้สิทธิ์ของมันได้โดยไม่ผ่านฟังก์ชัน)
  if (select rolcanlogin or rolsuper or rolbypassrls from pg_roles
       where rolname = 'sri_os_column_reader') then
    raise exception 'FAIL: C6b role เจ้าของทางเข้าแรงเกินไป';
  end if;
  if exists (select 1 from pg_auth_members m join pg_roles g on g.oid = m.roleid
              where g.rolname = 'sri_os_column_reader') then
    raise exception 'FAIL: C6b มี role เป็นสมาชิกของ sri_os_column_reader → ใช้สิทธิ์ของมันได้โดยไม่ผ่านฟังก์ชัน';
  end if;
  if not pg_has_role('sri_os_column_reader', 'authenticated', 'member') then
    raise exception 'FAIL: C6b เจ้าของทางเข้าไม่ได้เป็นสมาชิก authenticated → policy to authenticated ไม่มีผล (ฟังก์ชันจะคืน 0 แถวให้ทุกคน)';
  end if;

  -- (ค) P3 · service_role (มี bypassrls) ต้องยังไม่มีสิทธิ์อะไรใน sri_os
  --     ด่านนี้เป็น "สิทธิ์" ไม่ใช่ RLS จึงครอบ service_role ได้ถ้ามีวันที่ต้อง grant
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    if has_table_privilege('service_role', 'sri_os.assets', 'select')
       or has_column_privilege('service_role', 'sri_os.assets'::regclass, 'units', 'select') then
      raise exception 'FAIL: C6c service_role อ่าน assets ได้ → ต้องทบทวนด่าน (service_role ข้าม RLS)';
    end if;
  end if;

  -- (ง) anon ต้องไม่แตะอะไรเลย รวมฟังก์ชันทางเข้า
  if exists (select 1 from pg_roles where rolname = 'anon') then
    select string_agg(p.proname, ', ') into v
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'sri_os' and p.proname like 'fn\_%\_visible'
       and (has_function_privilege('anon', p.oid, 'execute')
            or has_function_privilege('public', p.oid, 'execute'));
    if v is not null then
      raise exception 'FAIL: C6d ฟังก์ชันทางเข้าเปิดให้ anon/PUBLIC: %', v;
    end if;
  end if;

  -- (จ) ทุกคอลัมน์ของตารางที่จัดประเภทแล้ว ต้องอยู่ในทะเบียนครบ (ไม่ใช่แค่ตารางที่มีด่าน)
  select count(*) into n from sri_os.fn_column_exposure_unclassified();
  if n <> 0 then
    raise exception 'FAIL: C6e ยังมี % รายการที่ไม่ได้จัดประเภท', n;
  end if;
  select count(*) into n from sri_os.column_exposure_tables where review_state = 'deferred';
  raise notice 'ok C6 · โครงสร้างด่านถูกต้อง · ตารางที่ยังเลื่อนการจัดประเภท % ตาราง (ต้องปิดให้ครบเมื่อ D-098 เสร็จ)', n;
end $$;

drop view sri_os.zz_ce_leak_view;

do $$ begin raise notice '=== ด่านคอลัมน์ (D-089) ผ่านทั้งหมด ==='; end $$;

rollback;
