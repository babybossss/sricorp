-- ============================================================
-- SRI OS · smoke test ของ 20261008000000_asset_permissions.sql (งาน W1)
--
-- ขอบเขต: พิสูจน์เฉพาะสิ่งที่ migration ของ W1 รับผิดชอบ
--   **ชุดเต็ม 22 เคสเป็นงาน W5** (supabase/tests/asset_permissions_test.sql)
--   ไฟล์นี้ตั้งใจชื่อไม่ลงท้าย `_test.sql` → `scripts/test-rls-local.sh` **ไม่หยิบไปรันเอง**
--   รันเอง: psql -v ON_ERROR_STOP=1 -d <db> -f supabase/tests/zz_asset_permissions_smoke.sql
--   (ต้องเป็น DB ที่สร้างจาก migration ครบและมี stub auth.uid() อ่านจาก GUC test.uid)
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ rollback ปิดท้าย · เจอข้อผิด = raise exception
-- ============================================================

begin;

-- ---------- fixtures: ผู้ใช้ ----------
create temporary table t_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_uid(label) values
  ('super'), ('mgmt'), ('mgr'), ('mgr2'), ('staff'), ('inactive'), ('ghost');
insert into auth.users(id) select id from t_uid;

insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, u.label || '@smoke.local', u.label, x.role, x.active
  from t_uid u
  join (values
    ('super',    'super_admin', true),
    ('mgmt',     'management',  true),
    ('mgr',      'manager',     true),
    ('mgr2',     'manager',     true),
    ('staff',    'staff',       true),
    ('inactive', 'manager',     false)   -- 'ghost' ไม่มีแถวใน app_users โดยตั้งใจ
  ) as x(label, role, active) on x.label = u.label;

create or replace function pg_temp.uid(p_label text) returns uuid
language sql stable as $fn$ select id from t_uid where label = p_label $fn$;

create or replace function pg_temp.login(p_label text) returns void
language sql as $fn$
  select set_config('test.uid', coalesce((select id::text from t_uid where label = p_label), ''), true);
$fn$;

-- ตัวช่วย: "คำสั่งนี้ต้องล้ม" / "ต้องสำเร็จ" / "ต้องกระทบ N แถว"
-- RLS ปฏิเสธ UPDATE/DELETE แบบ **เงียบ** (0 แถว ไม่ใช่ error) จึงต้องมีตัวนับแถวด้วย
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

create or replace function pg_temp.must_pass(p_label text, p_sql text) returns void
language plpgsql as $fn$
begin
  execute p_sql;
exception when others then
  raise exception 'FAIL: % — คำสั่งควรสำเร็จแต่ล้ม (%) · sql: %', p_label, sqlerrm, p_sql;
end $fn$;

create or replace function pg_temp.must_rows(p_label text, p_sql text, p_expect int) returns void
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
  raise exception 'FAIL: % — คำสั่งล้มด้วย error (%) ทั้งที่คาดว่าจะกระทบ % แถว · sql: %',
    p_label, sqlerrm, p_expect, p_sql;
end $fn$;

-- ---------- fixtures: ขอบเขตผู้ถือ ----------
insert into sri_os.user_owner_access(user_id, owner_id)
select pg_temp.uid(l), o.id
  from unnest(array['mgr', 'mgr2', 'staff', 'inactive']) l, sri_os.owners o
 where o.code in ('SRI_CORP');

-- ---------- fixtures: ทรัพย์ 3 ตัว ----------
insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, manager_user_id)
select x.id, x.code, x.name,
       (select class_id from sri_os.asset_categories order by code limit 1),
       (select id       from sri_os.asset_categories order by code limit 1),
       (select id from sri_os.owners where code = 'SRI_CORP'),
       x.mgr
  from (values
    ('00000000-0000-0000-0000-00000000e001'::uuid, 'SMK-A1', 'ของ mgr',       pg_temp.uid('mgr')),
    ('00000000-0000-0000-0000-00000000e002'::uuid, 'SMK-A2', 'ของ mgr2',      pg_temp.uid('mgr2')),
    ('00000000-0000-0000-0000-00000000e003'::uuid, 'SMK-A3', 'ยังไม่มอบหมาย', null)
  ) as x(id, code, name, mgr);

insert into sri_os.asset_valuations(asset_id, as_of, method, value) values
  ('00000000-0000-0000-0000-00000000e001', current_date, 'manual', 1000000),
  ('00000000-0000-0000-0000-00000000e002', current_date, 'manual', 2000000);

-- รายการเงินที่ post แล้ว ผูกกับ A1 (ใช้พิสูจน์ว่า owner_id ของทรัพย์ย้ายไม่ได้)
insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, asset_id, attachments, created_by)
select '00000000-0000-0000-0000-00000000e9f1',
       (select id from sri_os.owners where code = 'SRI_CORP'),
       'inc.other', current_date, '00000000-0000-0000-0000-00000000e001', array['smoke.pdf'],
       pg_temp.uid('mgmt');
insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit, asset_id)
select '00000000-0000-0000-0000-00000000e9f1', c.id,
       case when c.rn = 1 then 700 else 0 end,
       case when c.rn = 2 then 700 else 0 end,
       '00000000-0000-0000-0000-00000000e001'
  from (select id, row_number() over (order by code) rn
          from sri_os.chart_of_accounts where code not like '11%' order by code limit 2) c;

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
select '00000000-0000-0000-0000-00000000eb01', id, 'KBANK', 'smoke', 'smoke'
  from sri_os.owners where code = 'SRI_CORP';

-- role authenticated ต้องเรียกตัวช่วยใน temp schema ได้
do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.t_uid to authenticated', s);
end $$;

-- ยอดอ้างอิง "ก่อน" (วัดในฐานะ superuser = เห็นทุกแถวจริง ไม่ใช่เท่าที่ RLS ปล่อย)
create temporary table t_before as
select (select count(*) from sri_os.assets)                                as n_assets,
       (select count(*) from sri_os.asset_valuations)                      as n_val,
       (select coalesce(sum(value), 0) from sri_os.v_asset_latest_value)   as nav,
       (select sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000000e001')) as cost_a1,
       (select count(*) from sri_os.transactions)                          as n_txn,
       (select count(*) from sri_os.transaction_lines)                     as n_lines,
       (select count(*) from sri_os.draft_entries)                         as n_drafts;

set local role authenticated;

-- ============================================================
-- S1 · สิทธิ์ใหม่ 3 ตัวผูกกับตำแหน่งตามเอกสาร §1.2
-- ============================================================
do $$
declare r record;
begin
  for r in
    select * from (values
      ('asset.draft',  true, true, true,  true),
      ('asset.manage', true, true, true,  false),
      ('asset.value',  true, true, false, false)
    ) as m(perm, super, mgmt, mgr, staff)
  loop
    perform pg_temp.login('super'); if sri_os.fn_can(r.perm) <> r.super then raise exception 'FAIL: super % ผิด', r.perm; end if;
    perform pg_temp.login('mgmt');  if sri_os.fn_can(r.perm) <> r.mgmt  then raise exception 'FAIL: mgmt % ผิด', r.perm; end if;
    perform pg_temp.login('mgr');   if sri_os.fn_can(r.perm) <> r.mgr   then raise exception 'FAIL: mgr % ผิด', r.perm; end if;
    perform pg_temp.login('staff'); if sri_os.fn_can(r.perm) <> r.staff then raise exception 'FAIL: staff % ผิด', r.perm; end if;
  end loop;
  -- ผู้ใช้ปิดใช้งาน / ไม่มีแถวใน app_users → ไม่มีสิทธิ์อะไรเลย (ไม่ใช่ error)
  perform pg_temp.login('inactive');
  if sri_os.fn_can('asset.draft') or sri_os.fn_can('asset.manage') then raise exception 'FAIL: ผู้ใช้ปิดใช้งานยังมีสิทธิ์'; end if;
  perform pg_temp.login('ghost');
  if sri_os.fn_can('asset.draft') then raise exception 'FAIL: ผู้ใช้ที่ไม่มีแถวใน app_users มีสิทธิ์'; end if;
  raise notice 'ok S1 · asset.draft/manage/value ผูกตำแหน่งถูก · inactive + ghost ไม่มีสิทธิ์';
end $$;

-- ============================================================
-- S2 · เส้นทางที่ถูกต้องต้องยังทำได้ (บทเรียนข้อ 7 · กันแน่นเกินจนใช้ไม่ได้ก็คือพัง)
-- ============================================================
do $$
declare v_cat uuid; v_cls uuid; v_own uuid;
begin
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;
  select id into v_own from sri_os.owners where code = 'SRI_CORP';

  -- Management เพิ่มทรัพย์ได้ (นี่คือบั๊กที่ migration นี้แก้)
  perform pg_temp.login('mgmt');
  perform pg_temp.must_pass('Management เพิ่มทรัพย์', format(
    'insert into sri_os.assets(code, name, class_id, category_id, owner_id) values (%L, %L, %L, %L, %L)',
    'SMK-NEW1', 'ทรัพย์ใหม่ของ Management', v_cls, v_cat, v_own));

  -- Management เพิ่มบัญชีธนาคาร (settings.manage) + สัญญา
  perform pg_temp.must_pass('Management เพิ่มบัญชีธนาคาร', format(
    'insert into sri_os.bank_accounts(owner_id, bank, account_name, display_name) values (%L, ''SCB'', ''ใหม่'', ''ใหม่'')', v_own));
  perform pg_temp.must_pass('Management เพิ่มสัญญา', format(
    'insert into sri_os.contracts(owner_id, asset_id, type) values (%L, %L, ''lease'')',
    v_own, '00000000-0000-0000-0000-00000000e001'));

  -- Management ตีราคาได้ (asset.value)
  perform pg_temp.must_pass('Management ตีราคา', format(
    'insert into sri_os.asset_valuations(asset_id, as_of, method, value) values (%L, %L, ''appraisal'', 1234)',
    '00000000-0000-0000-0000-00000000e001', current_date));

  -- Manager แก้ทรัพย์ที่ตนบริหารได้ · Manager เพิ่มสัญญาของทรัพย์ตนได้
  perform pg_temp.login('mgr');
  perform pg_temp.must_rows('Manager แก้ทรัพย์ของตน',
    'update sri_os.assets set location = ''ที่ใหม่'' where id = ''00000000-0000-0000-0000-00000000e001''', 1);
  perform pg_temp.must_pass('Manager เพิ่มสัญญาของทรัพย์ตน', format(
    'insert into sri_os.contracts(owner_id, asset_id, type) values (%L, %L, ''lease'')',
    v_own, '00000000-0000-0000-0000-00000000e001'));

  -- ทุกตำแหน่งอ่านข้อมูลอ้างอิงได้ (ฟอร์มต้องมีรายการให้เลือก)
  perform pg_temp.login('staff');
  if (select count(*) from sri_os.asset_classes) = 0 then raise exception 'FAIL: Staff อ่าน asset_classes ไม่ได้'; end if;
  if (select count(*) from sri_os.asset_categories) = 0 then raise exception 'FAIL: Staff อ่าน asset_categories ไม่ได้'; end if;
  if (select count(*) from sri_os.assets where owner_id = v_own) = 0 then raise exception 'FAIL: Staff อ่านสาขาอ้างอิงของ assets ไม่ได้ (คีย์ข้อมูลไม่ได้)'; end if;
  raise notice 'ok S2 · Management เพิ่มทรัพย์/บัญชีธนาคาร/สัญญา/ตีราคาได้ · Manager แก้ทรัพย์ตนได้ · Staff อ่านอ้างอิงได้';
end $$;

-- ============================================================
-- S3 · Staff ร่างได้เฉพาะ assets · แตะอีก 4 ตารางล้มทุกตาราง
-- ============================================================
do $$
declare v_own uuid; v_cat uuid; v_cls uuid; v_ctr uuid;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;
  select id into v_ctr from sri_os.contracts order by created_at limit 1;

  perform pg_temp.login('staff');
  -- เขียน assets ตรงไม่ได้
  perform pg_temp.must_fail('Staff insert assets ตรง', format(
    'insert into sri_os.assets(code, name, class_id, category_id, owner_id) values (''SMK-STF'', ''x'', %L, %L, %L)',
    v_cls, v_cat, v_own));
  perform pg_temp.must_rows('Staff update assets ตรง',
    'update sri_os.assets set location = ''แอบแก้'' where id = ''00000000-0000-0000-0000-00000000e001''', 0);

  -- แต่ร่างได้ · patch = '{}' ต้องสำเร็จ (D-083 ข้อ 3: 4 ช่องพอ)
  perform pg_temp.must_pass('Staff ร่างสร้างทรัพย์ patch ว่าง', format(
    'insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id) values (''create'', %L, ''ร่างของ staff'', %L, %L)',
    v_own, v_cls, v_cat));

  -- อีก 4 ตารางแตะไม่ได้เลย
  perform pg_temp.must_fail('Staff insert asset_valuations', format(
    'insert into sri_os.asset_valuations(asset_id, as_of, method, value) values (%L, %L, ''manual'', 1)',
    '00000000-0000-0000-0000-00000000e001', current_date + 1));
  perform pg_temp.must_fail('Staff insert contracts', format(
    'insert into sri_os.contracts(owner_id, asset_id, type) values (%L, %L, ''lease'')',
    v_own, '00000000-0000-0000-0000-00000000e001'));
  perform pg_temp.must_fail('Staff insert schedules', format(
    'insert into sri_os.schedules(contract_id, period, due_date, expected_amount, principal_amount) values (%L, 1, %L, 10, 10)',
    v_ctr, current_date));
  perform pg_temp.must_fail('Staff insert bank_accounts', format(
    'insert into sri_os.bank_accounts(owner_id, bank, account_name, display_name) values (%L, ''X'', ''x'', ''x'')', v_own));
  perform pg_temp.must_rows('Staff update bank_accounts',
    'update sri_os.bank_accounts set display_name = ''แอบแก้'' where id = ''00000000-0000-0000-0000-00000000eb01''', 0);
  raise notice 'ok S3 · Staff ร่างได้เฉพาะ assets · asset_valuations/contracts/schedules/bank_accounts ล้มทุกตาราง';
end $$;

-- ============================================================
-- S4 · Manager: แก้ได้เฉพาะทรัพย์ที่ตนบริหาร · ตีราคาไม่ได้ · แจกสิทธิ์มองเห็นไม่ได้
-- ============================================================
do $$
declare v_own uuid;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  perform pg_temp.login('mgr');

  perform pg_temp.must_rows('Manager แก้ทรัพย์ของคนอื่น',
    'update sri_os.assets set location = ''แอบแก้'' where id = ''00000000-0000-0000-0000-00000000e002''', 0);
  -- "ไม่มีใครดูแล" ไม่ใช่ "ของทุกคน"
  perform pg_temp.must_rows('Manager แก้ทรัพย์ที่ไม่มีผู้บริหาร',
    'update sri_os.assets set location = ''แอบแก้'' where id = ''00000000-0000-0000-0000-00000000e003''', 0);

  -- ตีราคาไม่ได้ แม้เป็นทรัพย์ที่ตนบริหาร (§4.2 · Q2)
  perform pg_temp.must_fail('Manager ตีราคาทรัพย์ของตน', format(
    'insert into sri_os.asset_valuations(asset_id, as_of, method, value) values (%L, %L, ''manual'', 99)',
    '00000000-0000-0000-0000-00000000e001', current_date + 2));

  -- แจกสิทธิ์มองเห็น: ย้าย manager_user_id ของทรัพย์ตัวเองให้คนอื่น → ถูกปฏิเสธ
  perform pg_temp.must_fail('Manager ย้าย manager_user_id ให้คนอื่น', format(
    'update sri_os.assets set manager_user_id = %L where id = %L',
    pg_temp.uid('mgr2'), '00000000-0000-0000-0000-00000000e001'));
  perform pg_temp.must_fail('Manager ล้าง manager_user_id ของทรัพย์ตน', format(
    'update sri_os.assets set manager_user_id = null where id = %L', '00000000-0000-0000-0000-00000000e001'));

  -- ย้ายผู้ถือก็ไม่ได้ (ไม่มี settings.manage)
  perform pg_temp.must_fail('Manager ย้ายผู้ถือของทรัพย์ตน', format(
    'update sri_os.assets set owner_id = (select id from sri_os.owners where code = ''SUTEE'') where id = %L',
    '00000000-0000-0000-0000-00000000e001'));

  -- Manager เขียน bank_accounts ไม่ได้เลย (§4.5)
  perform pg_temp.must_fail('Manager insert bank_accounts', format(
    'insert into sri_os.bank_accounts(owner_id, bank, account_name, display_name) values (%L, ''X'', ''x'', ''x'')', v_own));
  raise notice 'ok S4 · Manager แก้ได้เฉพาะทรัพย์ตน · ตีราคาไม่ได้ · ย้าย manager_user_id/owner_id ไม่ได้ · bank_accounts ไม่แตะ';
end $$;

-- ============================================================
-- S5 · การมอบหมายผู้บริหาร = การแจกสิทธิ์มองเห็น → users.manage เท่านั้น
--      (Management มี portfolio.view_all แต่ไม่มี users.manage → ทำไม่ได้)
-- ============================================================
do $$
declare v_own uuid; v_cat uuid; v_cls uuid;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;

  perform pg_temp.login('mgmt');
  perform pg_temp.must_fail('Management ย้าย manager_user_id', format(
    'update sri_os.assets set manager_user_id = %L where id = %L',
    pg_temp.uid('mgmt'), '00000000-0000-0000-0000-00000000e003'));
  perform pg_temp.must_fail('Management ตั้ง manager_user_id ตอนสร้างทรัพย์', format(
    'insert into sri_os.assets(code, name, class_id, category_id, owner_id, manager_user_id) values (''SMK-ASG'', ''x'', %L, %L, %L, %L)',
    v_cls, v_cat, v_own, pg_temp.uid('mgr')));

  perform pg_temp.login('super');
  perform pg_temp.must_rows('Super Admin มอบหมายผู้บริหาร', format(
    'update sri_os.assets set manager_user_id = %L where id = %L',
    pg_temp.uid('mgr'), '00000000-0000-0000-0000-00000000e003'), 1);
  raise notice 'ok S5 · มอบหมายผู้บริหารได้เฉพาะ users.manage (Management ทำไม่ได้ ทั้งตอน insert และ update)';
end $$;

-- ============================================================
-- S6 · owner_id ของทรัพย์ห้ามเปลี่ยนถ้ามี transaction_lines ผูกอยู่ (trigger)
--      ถ้ายังไม่มีบรรทัดบัญชี settings.manage ย้ายได้
-- ============================================================
do $$
declare v_sutee uuid; v_free uuid;
begin
  select id into v_sutee from sri_os.owners where code = 'SUTEE';
  select id into v_free from sri_os.assets where code = 'SMK-NEW1';

  perform pg_temp.login('super');
  perform pg_temp.must_fail('ย้ายผู้ถือของทรัพย์ที่มีบรรทัดบัญชี', format(
    'update sri_os.assets set owner_id = %L where id = %L', v_sutee, '00000000-0000-0000-0000-00000000e001'));
  -- ขาบวก: ทรัพย์ที่ยังไม่มีบรรทัดบัญชี ย้ายได้ (ไม่ล็อกแน่นเกินไป)
  perform pg_temp.must_rows('ย้ายผู้ถือของทรัพย์ที่ยังไม่มีบรรทัดบัญชี', format(
    'update sri_os.assets set owner_id = %L where id = %L', v_sutee, v_free), 1);
  raise notice 'ok S6 · owner_id ล็อกเมื่อมีบรรทัดบัญชี · ทรัพย์ที่ยังไม่มีย้ายได้';
end $$;

-- ============================================================
-- S7 · patch whitelist — ยัดช่องที่ไม่อยู่ใน whitelist ต้องล้ม
-- ============================================================
do $$
declare v_own uuid; v_cat uuid; v_cls uuid; k text;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;
  perform pg_temp.login('staff');

  foreach k in array array['owner_id', 'manager_user_id', 'code', 'status', 'id', 'created_at', 'ไม่มีช่องนี้'] loop
    perform pg_temp.must_fail('Staff ยัด ' || k || ' ลง patch', format(
      'insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id, patch) values (''create'', %L, ''x'', %L, %L, %L::jsonb)',
      v_own, v_cls, v_cat, jsonb_build_object(k, 'โกง')::text));
  end loop;

  -- ช่องที่อยู่ใน whitelist ต้องผ่าน
  perform pg_temp.must_pass('Staff ร่างช่องที่อนุญาต', format(
    'insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id, patch) values (''create'', %L, ''มี patch'', %L, %L, %L::jsonb)',
    v_own, v_cls, v_cat, jsonb_build_object('location', 'สุขุมวิท', 'ticker', 'ABC')::text));

  -- kind='create' ห้ามส่ง 4 ช่องบังคับซ้ำใน patch (สองแหล่งของค่าเดียวกัน)
  perform pg_temp.must_fail('Staff ส่ง name ซ้ำใน patch', format(
    'insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id, patch) values (''create'', %L, ''x'', %L, %L, ''{"name":"ซ้ำ"}''::jsonb)',
    v_own, v_cls, v_cat));

  -- whitelist ⊆ คอลัมน์ของ assets (เทียบ information_schema)
  if exists (
    select 1 from unnest(sri_os.fn_asset_draft_patch_keys()) k2
     where not exists (select 1 from information_schema.columns c
                        where c.table_schema = 'sri_os' and c.table_name = 'assets' and c.column_name = k2)
  ) then
    raise exception 'FAIL: whitelist อ้างช่องที่ไม่มีคอลัมน์รองรับใน assets';
  end if;
  raise notice 'ok S7 · patch whitelist ปฏิเสธ owner_id/manager_user_id/code/status/id/created_at/ช่องที่ไม่มีจริง · ช่องที่อนุญาตผ่าน';
end $$;

-- ============================================================
-- S8 · เคส "ไม่ส่งข้อมูล" ทุกจุด (บทเรียน mace-windu ข้อ 3)
-- ============================================================
do $$
declare v_own uuid; v_cat uuid; v_cls uuid;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;
  perform pg_temp.login('staff');

  perform pg_temp.must_fail('ร่าง create ไม่ส่ง class_id', format(
    'insert into sri_os.asset_drafts(kind, owner_id, name, category_id) values (''create'', %L, ''x'', %L)', v_own, v_cat));
  perform pg_temp.must_fail('ร่าง create ไม่ส่ง category_id', format(
    'insert into sri_os.asset_drafts(kind, owner_id, name, class_id) values (''create'', %L, ''x'', %L)', v_own, v_cls));
  perform pg_temp.must_fail('ร่าง create ไม่ส่ง name', format(
    'insert into sri_os.asset_drafts(kind, owner_id, class_id, category_id) values (''create'', %L, %L, %L)', v_own, v_cls, v_cat));
  perform pg_temp.must_fail('ร่าง update ที่ target_asset_id เป็น null', format(
    'insert into sri_os.asset_drafts(kind, owner_id, patch) values (''update'', %L, ''{"location":"x"}''::jsonb)', v_own));
  perform pg_temp.must_fail('ร่าง update ที่ patch ว่าง', format(
    'insert into sri_os.asset_drafts(kind, owner_id, target_asset_id, patch) values (''update'', %L, %L, ''{}''::jsonb)',
    v_own, '00000000-0000-0000-0000-00000000e001'));
  perform pg_temp.must_fail('ร่าง create ที่ส่ง target_asset_id มาด้วย', format(
    'insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id, target_asset_id) values (''create'', %L, ''x'', %L, %L, %L)',
    v_own, v_cls, v_cat, '00000000-0000-0000-0000-00000000e001'));
  perform pg_temp.must_fail('ร่างที่ไม่ส่ง owner_id', format(
    'insert into sri_os.asset_drafts(kind, name, class_id, category_id) values (''create'', ''x'', %L, %L)', v_cls, v_cat));
  perform pg_temp.must_fail('ร่างที่สวมชื่อคนอื่นเป็นคนคีย์', format(
    'insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id, created_by) values (''create'', %L, ''x'', %L, %L, %L)',
    v_own, v_cls, v_cat, pg_temp.uid('mgmt')));
  perform pg_temp.must_fail('ร่างที่เกิดมาพร้อมสถานะ approved', format(
    'insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id, status) values (''create'', %L, ''x'', %L, %L, ''approved'')',
    v_own, v_cls, v_cat));
  perform pg_temp.must_fail('fn_apply_asset_draft(null)', 'select sri_os.fn_apply_asset_draft(null::uuid)');
  perform pg_temp.must_fail('fn_apply_asset_draft(ร่างที่ไม่มีจริง)',
    'select sri_os.fn_apply_asset_draft(''00000000-0000-0000-0000-0000000fffff''::uuid)');

  -- ปฏิเสธร่างโดยไม่บอกเหตุผล
  perform pg_temp.login('mgmt');
  perform pg_temp.must_fail('ปฏิเสธร่างโดยไม่ใส่เหตุผล', format(
    'update sri_os.asset_drafts set status = ''rejected'', reviewed_by = %L, reviewed_at = now() where name = ''ร่างของ staff''',
    pg_temp.uid('mgmt')));
  raise notice 'ok S8 · เคสข้อมูลไม่ครบถูกปฏิเสธทุกจุด (ไม่เติมค่าเริ่มต้นให้ ไม่ตกไปเส้นทางปกติ)';
end $$;

-- ============================================================
-- S9 · ร่างต้องไม่ถูกนับในมูลค่าพอร์ต/งบดุล และอ้างถึงไม่ได้ในทางโครงสร้าง
--      วัดยอด "ก่อน/หลัง" ในเทสต์เดียวกัน
-- ============================================================
reset role;
do $$
declare
  v_own uuid; v_cat uuid; v_cls uuid; v_draft uuid;
  b record; a record;
begin
  select * into b from t_before;
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;
  select id into v_own from sri_os.owners where code = 'SRI_CORP';

  -- วัดใหม่ "ก่อนสร้างร่าง" (S2/S3 เพิ่มทรัพย์/ตีราคาไปแล้ว จึงวัดสดอีกรอบ)
  create temporary table t_pre as
  select (select count(*) from sri_os.assets) n_assets,
         (select coalesce(sum(value), 0) from sri_os.v_asset_latest_value) nav,
         (select sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000000e001')) cost_a1,
         (select count(*) from sri_os.transactions) n_txn,
         (select count(*) from sri_os.transaction_lines) n_lines,
         (select count(*) from sri_os.draft_entries) n_de;

  insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id, created_by, patch)
  values ('create', v_own, 'ร่างที่ต้องไม่ถูกนับ', v_cls, v_cat, (select id from t_uid where label = 'staff'),
          '{"units": 999999, "location": "ไม่ควรโผล่"}'::jsonb)
  returning id into v_draft;

  select * into a from (
    select (select count(*) from sri_os.assets) n_assets,
           (select coalesce(sum(value), 0) from sri_os.v_asset_latest_value) nav,
           (select sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000000e001')) cost_a1,
           (select count(*) from sri_os.transactions) n_txn,
           (select count(*) from sri_os.transaction_lines) n_lines,
           (select count(*) from sri_os.draft_entries) n_de
  ) x;

  if a.n_assets <> (select n_assets from t_pre) then
    raise exception 'FAIL: สร้างร่างแล้วจำนวนแถวใน assets เปลี่ยน (% → %)', (select n_assets from t_pre), a.n_assets;
  end if;
  if a.nav <> (select nav from t_pre) then
    raise exception 'FAIL: สร้างร่างแล้วมูลค่าพอร์ตเปลี่ยน (% → %)', (select nav from t_pre), a.nav;
  end if;
  if a.cost_a1 <> (select cost_a1 from t_pre) then
    raise exception 'FAIL: สร้างร่างแล้ว fn_asset_cost_basis เปลี่ยน';
  end if;
  if a.n_txn <> (select n_txn from t_pre) or a.n_lines <> (select n_lines from t_pre)
     or a.n_de <> (select n_de from t_pre) then
    raise exception 'FAIL: สร้างร่างแล้วตาราง ledger ขยับ';
  end if;

  -- ร่างถูกอ้างถึงไม่ได้ในทางโครงสร้าง: ตีราคาร่าง → FK ปฏิเสธ
  begin
    insert into sri_os.asset_valuations(asset_id, as_of, method, value)
    values (v_draft, current_date, 'manual', 50000000);
    raise exception 'FAIL: ตีราคาให้ร่างได้ = ร่างหลุดเข้ามูลค่าพอร์ตได้';
  exception when foreign_key_violation then null;
    when raise_exception then if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  -- ลงบัญชีให้ร่าง → FK ปฏิเสธเช่นกัน
  begin
    insert into sri_os.transactions(owner_id, txn_type_code, doc_date, asset_id, attachments)
    values (v_own, 'inc.other', current_date, v_draft, array['x.pdf']);
    raise exception 'FAIL: ลงบัญชีผูกกับร่างได้';
  exception when foreign_key_violation then null;
    when raise_exception then if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  raise notice 'ok S9 · สร้างร่างแล้ว assets/NAV/cost basis/ledger ไม่ขยับเลย · ตีราคา/ลงบัญชีให้ร่างถูก FK ปฏิเสธ';
end $$;

-- ============================================================
-- S10 · อนุมัติร่าง: assets +1 แถว · ตาราง ledger +0 แถว (กฎเหล็กข้อ 6)
--       และอนุมัติซ้ำครั้งที่สองต้องล้ม (ไม่สร้างทรัพย์ซ้ำ)
-- ============================================================
set local role authenticated;
do $$
declare
  v_own uuid; v_cat uuid; v_cls uuid; v_draft uuid; v_asset uuid;
  n_assets_0 bigint; n_txn_0 bigint; n_lines_0 bigint; n_de_0 bigint;
  n_assets_1 bigint; n_txn_1 bigint; n_lines_1 bigint; n_de_1 bigint;
  v_units numeric; v_loc text; v_code text;
begin
  perform pg_temp.login('mgmt');
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;
  select id into v_own from sri_os.owners where code = 'SRI_CORP';

  insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id, patch)
  values ('create', v_own, 'ทรัพย์จากร่าง', v_cls, v_cat, '{"units": 12.5, "location": "อโศก"}'::jsonb)
  returning id into v_draft;

  select count(*) into n_assets_0 from sri_os.assets;
  select count(*) into n_txn_0    from sri_os.transactions;
  select count(*) into n_lines_0  from sri_os.transaction_lines;
  select count(*) into n_de_0     from sri_os.draft_entries;

  v_asset := sri_os.fn_apply_asset_draft(v_draft);
  if v_asset is null then raise exception 'FAIL: fn_apply_asset_draft คืน null'; end if;

  select count(*) into n_assets_1 from sri_os.assets;
  select count(*) into n_txn_1    from sri_os.transactions;
  select count(*) into n_lines_1  from sri_os.transaction_lines;
  select count(*) into n_de_1     from sri_os.draft_entries;

  if n_assets_1 <> n_assets_0 + 1 then
    raise exception 'FAIL: อนุมัติร่างแล้ว assets ควร +1 แต่ % → %', n_assets_0, n_assets_1;
  end if;
  if n_txn_1 <> n_txn_0 or n_lines_1 <> n_lines_0 or n_de_1 <> n_de_0 then
    raise exception 'FAIL: อนุมัติร่างแล้วตาราง ledger ขยับ (txn %→% · lines %→% · drafts %→%) = กฎเหล็กข้อ 6 หลุด',
      n_txn_0, n_txn_1, n_lines_0, n_lines_1, n_de_0, n_de_1;
  end if;

  -- patch ถูกนำไปใช้ และรหัสออกตอนอนุมัติ
  select units, location, code into v_units, v_loc, v_code from sri_os.assets where id = v_asset;
  if v_units <> 12.5 or v_loc <> 'อโศก' then
    raise exception 'FAIL: patch ไม่ถูกนำไปใช้ (units=% location=%)', v_units, v_loc;
  end if;
  if v_code is null or v_code !~ '^[A-Z_]+-[0-9]{4}$' then
    raise exception 'FAIL: รหัสทรัพย์ที่ออกตอนอนุมัติผิดรูป: %', coalesce(v_code, '(null)');
  end if;
  if (select status from sri_os.asset_drafts where id = v_draft) <> 'approved'
     or (select applied_asset_id from sri_os.asset_drafts where id = v_draft) <> v_asset
     or (select reviewed_by from sri_os.asset_drafts where id = v_draft) <> pg_temp.uid('mgmt') then
    raise exception 'FAIL: ร่างไม่ได้ถูกบันทึกว่าอนุมัติแล้วพร้อม reviewed_by';
  end if;

  -- อนุมัติซ้ำ → ล้ม ไม่สร้างทรัพย์ซ้ำ
  perform pg_temp.must_fail('อนุมัติร่างเดิมรอบที่สอง', format('select sri_os.fn_apply_asset_draft(%L)', v_draft));
  if (select count(*) from sri_os.assets) <> n_assets_1 then
    raise exception 'FAIL: อนุมัติซ้ำแล้วมีทรัพย์เพิ่ม';
  end if;

  -- ร่างที่พิจารณาแล้วแก้ไม่ได้อีก · RLS ปฏิเสธ**เงียบ** (0 แถว) จึงต้องนับแถว
  perform pg_temp.must_rows('แก้ร่างที่อนุมัติแล้ว (ชั้น RLS)', format(
    'update sri_os.asset_drafts set note = ''แอบแก้'' where id = %L', v_draft), 0);
  -- และ trigger ต้องกันได้ด้วย แม้เป็น superuser ที่ RLS ไม่มีผล (กฎที่ policy ในอนาคตเขียนทับไม่ได้)
  execute 'reset role';
  perform pg_temp.must_fail('แก้ร่างที่อนุมัติแล้ว (ชั้น trigger · superuser)', format(
    'update sri_os.asset_drafts set note = ''แอบแก้'' where id = %L', v_draft));
  execute 'set local role authenticated';

  -- ตั้งสถานะ approved เองโดยไม่สร้างทรัพย์ → ล้ม (อนุมัติที่ไม่มีผล)
  insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id)
  values ('create', v_own, 'ร่างที่จะถูกอนุมัติปลอม', v_cls, v_cat) returning id into v_draft;
  perform pg_temp.must_fail('ตั้ง approved เองโดยไม่สร้างทรัพย์', format(
    'update sri_os.asset_drafts set status = ''approved'', reviewed_by = %L, reviewed_at = now() where id = %L',
    pg_temp.uid('mgmt'), v_draft));
  perform pg_temp.must_fail('ตั้ง approved พร้อมชี้ทรัพย์ที่ไม่ตรงกับร่าง', format(
    'update sri_os.asset_drafts set status = ''approved'', applied_asset_id = %L, reviewed_by = %L, reviewed_at = now() where id = %L',
    '00000000-0000-0000-0000-00000000e001', pg_temp.uid('mgmt'), v_draft));

  raise notice 'ok S10 · อนุมัติร่าง: assets +1 · ledger +0 แถว · patch ถูกใช้ · รหัสออกตอนอนุมัติ · อนุมัติซ้ำล้ม · อนุมัติปลอมล้ม';
end $$;

-- ============================================================
-- S11 · ร่างแก้ไข (kind='update') · Manager อนุมัติร่างแก้ของทรัพย์ตนได้
--       แต่ร่างสร้างทรัพย์อนุมัติไม่ได้ (assets_insert ต้องมี portfolio.view_all)
-- ============================================================
do $$
declare v_own uuid; v_cat uuid; v_cls uuid; v_draft uuid; v_asset uuid;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;

  -- Manager ร่างแก้ทรัพย์ของตน แล้วอนุมัติเอง (Q3 = ทำได้)
  perform pg_temp.login('mgr');
  insert into sri_os.asset_drafts(kind, owner_id, target_asset_id, patch)
  values ('update', v_own, '00000000-0000-0000-0000-00000000e001', '{"location": "เอกมัย", "size_note": "80 ตร.ม."}'::jsonb)
  returning id into v_draft;
  v_asset := sri_os.fn_apply_asset_draft(v_draft);
  if v_asset <> '00000000-0000-0000-0000-00000000e001' then
    raise exception 'FAIL: ร่างแก้ไขควรคืน target_asset_id เดิม';
  end if;
  if (select location from sri_os.assets where id = v_asset) <> 'เอกมัย' then
    raise exception 'FAIL: ร่างแก้ไขอนุมัติแล้วแต่ค่าไม่เปลี่ยน';
  end if;

  -- Manager ร่างแก้ทรัพย์ของคนอื่นไม่ได้ (ชั้นขอบเขตทรัพย์ตอน insert ร่าง)
  perform pg_temp.must_fail('Manager ร่างแก้ทรัพย์ของคนอื่น', format(
    'insert into sri_os.asset_drafts(kind, owner_id, target_asset_id, patch) values (''update'', %L, %L, ''{"location":"x"}''::jsonb)',
    v_own, '00000000-0000-0000-0000-00000000e002'));

  -- Manager อนุมัติร่างสร้างทรัพย์ไม่ได้ · ต้องเป็น error ที่อ่านรู้เรื่อง
  perform pg_temp.login('mgmt');
  insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id)
  values ('create', v_own, 'ร่างที่ Manager อนุมัติไม่ได้', v_cls, v_cat) returning id into v_draft;
  perform pg_temp.login('mgr');
  begin
    perform sri_os.fn_apply_asset_draft(v_draft);
    raise exception 'FAIL: Manager อนุมัติร่างสร้างทรัพย์ได้ ทั้งที่ assets_insert ต้องมี portfolio.view_all';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if sqlerrm not like '%portfolio.view_all%' then
      raise exception 'FAIL: error ของการอนุมัติที่ไม่มีสิทธิ์ควรอ่านรู้เรื่อง แต่ได้: %', sqlerrm;
    end if;
  when insufficient_privilege then
    raise exception 'FAIL: ได้ข้อความ RLS ดิบ ไม่ใช่ error ที่อ่านรู้เรื่อง';
  end;
  raise notice 'ok S11 · Manager ร่าง+อนุมัติร่างแก้ของทรัพย์ตนได้ · ร่างแก้ทรัพย์คนอื่นล้ม · อนุมัติร่างสร้างทรัพย์ล้มด้วย error ที่อ่านรู้เรื่อง';
end $$;

-- ============================================================
-- S12 · รหัสทรัพย์ชนของเดิม → error ที่อ่านรู้เรื่อง ไม่ใช่ 23505 เปล่าๆ
-- ============================================================
reset role;
do $$
declare v_own uuid; v_cat uuid; v_cls uuid; v_draft uuid; v_next text;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;

  -- จองรหัสที่ฟังก์ชัน "จะออกให้ครั้งถัดไป" ไว้ก่อน (superuser ข้าม RLS จึงจัดฉากได้)
  -- หมายเหตุ: ชนรหัสจริงในเซสชันเดียวทำให้เกิดไม่ได้โดยโครงสร้าง เพราะ
  --   fn_next_asset_code() ไล่เลขจาก max() ของที่มีอยู่ → พอจองไปแล้วเลขถัดไปก็เลื่อนตาม
  --   ตัวจับ unique_violation ใน fn_apply_asset_draft มีไว้สำหรับ **การอนุมัติพร้อมกัน
  --   สองเซสชัน** ซึ่งพิสูจน์ด้วย psql เดียวไม่ได้ (รูปแบบเดียวกับ test-two-session-local.sh)
  -- เทสต์นี้จึงพิสูจน์ "ขาบวก": มีตัวจองรหัสอยู่แล้ว การอนุมัติต้องยังสำเร็จ ไม่ใช่ล้ม
  v_next := sri_os.fn_next_asset_code(v_cls);
  insert into sri_os.assets(code, name, class_id, category_id, owner_id)
  values (v_next, 'ตัวจองรหัส', v_cls, v_cat, v_own);
  insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id, created_by)
  values ('create', v_own, 'ร่างที่รหัสจะชน', v_cls, v_cat, (select id from t_uid where label = 'mgmt'))
  returning id into v_draft;

  -- ขาบวก: รหัสถัดไปต้องไม่ชนแล้ว (ฟังก์ชันไล่เลขจาก max) → อนุมัติได้
  set local role authenticated;
  perform pg_temp.login('mgmt');
  if sri_os.fn_apply_asset_draft(v_draft) is null then
    raise exception 'FAIL: อนุมัติร่างหลังมีทรัพย์จองรหัสอยู่ไม่สำเร็จ = ไล่เลขรหัสไม่ทำงาน';
  end if;
  reset role;
  raise notice 'ok S12 · รหัสทรัพย์ไล่เลขจากของที่มีอยู่ ไม่ชนกับตัวจองรหัส (% คือรหัสที่จองไว้)', v_next;
end $$;

-- ============================================================
-- S13 · DELETE ทั้ง 6 ตาราง ทุกตำแหน่ง รวม super_admin → ปฏิเสธทั้งหมด
-- ============================================================
set local role authenticated;
-- เลือกแถวที่ **ไม่มี FK ตัวอื่นชี้อยู่** โดยตั้งใจ: ถ้าลองลบแถวที่มีลูก FK จะล้ม
-- ด้วย foreign_key_violation ซึ่งอ่านไม่ออกว่า "RLS กัน" หรือ "FK กัน"
-- → mutation ที่เพิ่ม policy DELETE กลับมาจะหลุดได้ (พิสูจน์แล้วว่าหลุดจริง)
do $$
declare r text; m record; n int; n_before bigint; n_after bigint; v text;
begin
  -- โครงสร้าง: ต้องไม่มี policy DELETE บนทั้ง 6 ตารางเลย
  select string_agg(tablename || '.' || policyname, ', ') into v
    from pg_policies
   where schemaname = 'sri_os'
     and tablename in ('assets', 'asset_valuations', 'contracts', 'schedules', 'bank_accounts', 'asset_drafts')
     and cmd in ('DELETE', 'ALL');
  if v is not null then
    raise exception 'FAIL: โมดูลทรัพย์มี policy DELETE/ALL: % (DELETE ต้องไม่มีใครได้)', v;
  end if;

  -- พฤติกรรม: ลองลบจริงทุกตำแหน่ง บนแถวที่ไม่มีลูก FK
  foreach r in array array['staff', 'mgr', 'mgmt', 'super'] loop
    perform pg_temp.login(r);
    for m in select * from (values
        ('assets',           'delete from sri_os.assets where code = ''SMK-A3'''),
        ('asset_valuations', 'delete from sri_os.asset_valuations where value = 2000000'),
        ('contracts',        'delete from sri_os.contracts where id in (select id from sri_os.contracts where principal is null)'),
        ('schedules',        'delete from sri_os.schedules'),
        ('bank_accounts',    'delete from sri_os.bank_accounts where bank = ''SCB'''),
        ('asset_drafts',     'delete from sri_os.asset_drafts')
      ) as x(tbl, sql)
    loop
      begin
        execute m.sql;
        get diagnostics n = row_count;
        if n <> 0 then
          raise exception 'FAIL: % ลบแถวใน % ได้ % แถว (ไม่ควรมี policy DELETE เลย)', r, m.tbl, n;
        end if;
      exception when insufficient_privilege then null;
        when raise_exception then if sqlerrm like 'FAIL:%' then raise; end if;
      end;
    end loop;
  end loop;

  -- กันเทสต์เปล่า: แถวเป้าหมายต้องมีอยู่จริง ไม่งั้น "ลบได้ 0 แถว" ไม่ได้พิสูจน์อะไร
  execute 'reset role';
  if (select count(*) from sri_os.assets where code = 'SMK-A3') <> 1
     or (select count(*) from sri_os.asset_drafts) = 0
     or (select count(*) from sri_os.bank_accounts where bank = 'SCB') = 0 then
    raise exception 'FAIL: แถวเป้าหมายของเทสต์ DELETE ไม่มีอยู่ — เทสต์นี้ไม่ได้ตรวจอะไร';
  end if;
  execute 'set local role authenticated';
  raise notice 'ok S13 · ไม่มี policy DELETE/ALL บน 6 ตาราง · ลบจริงไม่ได้ทุกตำแหน่งรวม super_admin';
end $$;

-- ============================================================
-- S14 · ผู้ใช้ปิดใช้งาน / ไม่มีแถวใน app_users → ทำอะไรไม่ได้เลย
-- ============================================================
do $$
declare r text; v_own uuid; v_cat uuid; v_cls uuid;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;
  foreach r in array array['inactive', 'ghost'] loop
    perform pg_temp.login(r);
    perform pg_temp.must_fail(r || ' สร้างร่าง', format(
      'insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id) values (''create'', %L, ''x'', %L, %L)',
      v_own, v_cls, v_cat));
    perform pg_temp.must_fail(r || ' เพิ่มทรัพย์', format(
      'insert into sri_os.assets(code, name, class_id, category_id, owner_id) values (''SMK-'' || %L, ''x'', %L, %L, %L)',
      r, v_cls, v_cat, v_own));
    perform pg_temp.must_rows(r || ' แก้ทรัพย์',
      'update sri_os.assets set location = ''x'' where code = ''SMK-A1''', 0);
    if (select count(*) from sri_os.asset_drafts) <> 0 then
      raise exception 'FAIL: % อ่านร่างได้ % ใบ', r, (select count(*) from sri_os.asset_drafts);
    end if;
  end loop;
  raise notice 'ok S14 · inactive + ghost: สร้างร่าง/เพิ่มทรัพย์/แก้ทรัพย์/อ่านร่าง ไม่ได้เลย';
end $$;

-- ============================================================
-- S15 · ขอบเขตการอ่านร่าง: Staff เห็นเฉพาะของตัวเอง
-- ============================================================
do $$
declare n_staff bigint; n_mgmt bigint;
begin
  perform pg_temp.login('staff');
  select count(*) into n_staff from sri_os.asset_drafts;
  if exists (select 1 from sri_os.asset_drafts where created_by <> pg_temp.uid('staff')) then
    raise exception 'FAIL: Staff เห็นร่างของคนอื่น';
  end if;
  if n_staff = 0 then raise exception 'FAIL: Staff ไม่เห็นร่างของตัวเองเลย (เทสต์นี้ไม่ได้ตรวจอะไร)'; end if;

  perform pg_temp.login('mgmt');
  select count(*) into n_mgmt from sri_os.asset_drafts;
  if n_mgmt <= n_staff then
    raise exception 'FAIL: Management ควรเห็นคิวร่างมากกว่า Staff (staff % · mgmt %)', n_staff, n_mgmt;
  end if;
  raise notice 'ok S15 · Staff เห็นร่าง % ใบ (ของตัวเองเท่านั้น) · Management เห็น % ใบ', n_staff, n_mgmt;
end $$;

-- ============================================================
-- S16 · สถานะงวดที่สะท้อน ledger แก้มือไม่ได้ (§4.4)
-- ============================================================
do $$
declare v_own uuid; v_ctr uuid; v_sch uuid; v_contact uuid;
begin
  reset role;
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  insert into sri_os.contacts(first_name) values ('คู่สัญญาทดสอบ') returning id into v_contact;
  insert into sri_os.contracts(owner_id, asset_id, type, principal, rate, start_date, installments,
                               counterparty_contact_id, file_urls)
  values (v_own, '00000000-0000-0000-0000-00000000e001', 'lease', 100000, 0.05, current_date, 12,
          v_contact, array['c.pdf'])
  returning id into v_ctr;
  insert into sri_os.schedules(contract_id, period, due_date, expected_amount, principal_amount)
  values (v_ctr, 1, current_date, 1000, 1000) returning id into v_sch;

  -- สถานะที่แก้มือได้
  perform pg_temp.must_rows('งวด → overdue', format('update sri_os.schedules set status = ''overdue'' where id = %L', v_sch), 1);
  perform pg_temp.must_rows('งวด → waived',  format('update sri_os.schedules set status = ''waived''  where id = %L', v_sch), 1);
  -- สถานะที่สะท้อน ledger แก้มือไม่ได้ (ไม่มี draft_entry_id ผูกอยู่)
  perform pg_temp.must_fail('งวด → drafted โดยไม่มีร่าง',  format('update sri_os.schedules set status = ''drafted''  where id = %L', v_sch));
  perform pg_temp.must_fail('งวด → approved โดยไม่มีร่าง', format('update sri_os.schedules set status = ''approved'' where id = %L', v_sch));
  perform pg_temp.must_fail('งวด → received โดยไม่มีร่าง', format('update sri_os.schedules set status = ''received'' where id = %L', v_sch));
  raise notice 'ok S16 · งวด: upcoming/overdue/waived แก้มือได้ · drafted/approved/received แก้มือไม่ได้';
end $$;

-- ============================================================
-- S17 · coa_id/owner_id ของบัญชีธนาคารที่มีรายการแล้วเปลี่ยนไม่ได้ (§4.5)
--       ปิดบัญชีด้วย is_active = false ยังทำได้
-- ============================================================
do $$
declare v_bank uuid; v_coa uuid; v_coa2 uuid;
begin
  reset role;
  select id into v_coa  from sri_os.chart_of_accounts where code = '1100';
  select id into v_coa2 from sri_os.chart_of_accounts where code not like '11%' order by code limit 1;
  update sri_os.bank_accounts set coa_id = v_coa where id = '00000000-0000-0000-0000-00000000eb01';

  -- ยังไม่มีบรรทัดบัญชีผูก → เปลี่ยนได้
  perform pg_temp.must_rows('เปลี่ยน coa_id ของบัญชีที่ยังไม่มีรายการ', format(
    'update sri_os.bank_accounts set coa_id = %L where id = %L', v_coa2, '00000000-0000-0000-0000-00000000eb01'), 1);

  -- ใส่บรรทัดบัญชีที่ผูกบัญชีนี้ แล้วลองเปลี่ยนอีกครั้ง
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, attachments)
  select '00000000-0000-0000-0000-00000000e9f2', id, 'inc.other', current_date, array['b.pdf']
    from sri_os.owners where code = 'SRI_CORP';
  insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit, bank_account_id)
  select '00000000-0000-0000-0000-00000000e9f2', c.id,
         case when c.rn = 1 then 300 else 0 end,
         case when c.rn = 2 then 300 else 0 end,
         case when c.rn = 1 then '00000000-0000-0000-0000-00000000eb01'::uuid else null end
    from (select id, row_number() over (order by code) rn
            from sri_os.chart_of_accounts where code not like '11%' order by code limit 2) c;

  perform pg_temp.must_fail('เปลี่ยน coa_id ของบัญชีที่มีรายการแล้ว', format(
    'update sri_os.bank_accounts set coa_id = %L where id = %L', v_coa, '00000000-0000-0000-0000-00000000eb01'));
  perform pg_temp.must_fail('ย้าย owner_id ของบัญชีที่มีรายการแล้ว', format(
    'update sri_os.bank_accounts set owner_id = (select id from sri_os.owners where code = ''SUTEE'') where id = %L',
    '00000000-0000-0000-0000-00000000eb01'));
  -- ปิดบัญชียังทำได้
  perform pg_temp.must_rows('ปิดบัญชีด้วย is_active = false',
    'update sri_os.bank_accounts set is_active = false where id = ''00000000-0000-0000-0000-00000000eb01''', 1);
  raise notice 'ok S17 · coa_id/owner_id ของบัญชีที่มีรายการล็อก · ปิดบัญชีด้วย is_active ยังทำได้';
end $$;

-- ============================================================
-- S18 · โครงสร้าง: trigger ของโมดูลทรัพย์ไม่เรียก fn_can และไม่เขียนตาราง ledger
-- ============================================================
do $$
declare v text;
begin
  reset role;
  select string_agg(distinct p.proname, ', ') into v
    from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    join pg_proc p on p.oid = tg.tgfoid
   where ns.nspname = 'sri_os' and not tg.tgisinternal and p.prosrc ~* 'fn_can';
  if v is not null then raise exception 'FAIL: trigger function เรียก fn_can: %', v; end if;

  select string_agg(p.proname, ', ') into v
    from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    join pg_proc p on p.oid = tg.tgfoid
   where ns.nspname = 'sri_os' and not tg.tgisinternal
     and c.relname in ('assets', 'asset_drafts')
     and p.prosrc ~* '(insert|update|delete)\s+(into\s+)?(sri_os\.)?(transactions|transaction_lines|draft_entries|cash_confirmations)\M';
  if v is not null then raise exception 'FAIL: trigger บน assets/asset_drafts เขียนตาราง ledger: %', v; end if;

  -- fn_apply_asset_draft ต้องเป็น invoker (definer = ประตูหลังข้าม RLS)
  if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
              where ns.nspname = 'sri_os' and p.proname = 'fn_apply_asset_draft' and p.prosecdef) then
    raise exception 'FAIL: fn_apply_asset_draft เป็น SECURITY DEFINER';
  end if;

  -- SECURITY DEFINER ที่ไฟล์ W1 เพิ่ม ต้องไม่เปิด PUBLIC และ anon ต้องเรียกไม่ได้
  select string_agg(p.oid::regprocedure::text, ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname like 'fn\_%'
     and (has_function_privilege('public', p.oid, 'execute')
       or has_function_privilege('anon', p.oid, 'execute'));
  if v is not null then raise exception 'FAIL: ฟังก์ชันที่ public/anon เรียกได้: %', v; end if;

  -- trigger function ต้องเรียกจากข้างนอกไม่ได้
  select string_agg(p.proname, ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.prorettype = 'trigger'::regtype
     and has_function_privilege('authenticated', p.oid, 'execute');
  if v is not null then raise exception 'FAIL: authenticated เรียก trigger function ได้: %', v; end if;

  raise notice 'ok S18 · trigger ไม่เรียก fn_can · ไม่เขียนตาราง ledger · fn_apply_asset_draft เป็น invoker · ACL ของฟังก์ชันใหม่ปิดถูก';
end $$;

do $$ begin raise notice '=== asset permissions smoke ผ่านทั้งหมด ==='; end $$;

rollback;
