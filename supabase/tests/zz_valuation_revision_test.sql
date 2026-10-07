-- ============================================================
-- SRI OS · เทสต์ asset_valuations.revision + "มูลค่าล่าสุด" (W2 · §7 ข้อ 8)
--
-- รันในเครื่อง:  bash scripts/test-rls-local.sh
-- ทั้งไฟล์อยู่ใน transaction เดียวและ rollback ปิดท้าย · เจอข้อผิด = raise exception
--
-- สิ่งที่ไฟล์นี้ต้องจับได้ (ไล่จาก "ถ้าถอดการแก้ออกแล้วต้องแดง"):
--   M1 ไม่ย้าย unique มารวม revision        → T1 แดง
--   M2 วิวไม่กรอง revision สูงสุดต่อกลุ่ม    → T2 · T4 แดง (นับซ้ำ/เลือกแถวเก่า)
--   M3 ออกเลข revision ข้าม method          → T4 แดง
--   M4 วิวเรียง revision/created_at ก่อน as_of → T3 แดง
--   M5 วิวไม่ left join assets               → T5 แดง (ทรัพย์ที่ไม่เคยตีราคาหายจากรายงาน)
--   M6 วิวไม่ตั้ง security_invoker            → T7 แดง · และ T6 แดงด้วยตัวเอง
--      (ลอง reset เฉยๆ **ไม่สำเร็จ** เพราะ event trigger ตั้งคืนให้ทันที
--       ต้อง drop event trigger ก่อนจึงเกิดสภาพนี้ได้ = สภาพของ cluster ที่สร้าง
--       event trigger ไม่สำเร็จ · ตอนนั้น Manager รวมได้ 9,000,830 แทน 830)
--   M7 ไม่มี trigger ออกเลข revision          → T1 แดง (revision เป็น null)
--
-- หมายเหตุเรื่อง created_at: ข้อมูลทดสอบ **ตั้ง created_at เอง** ให้สวนทางกับลำดับ
--   revision โดยตั้งใจ เพราะ `now()` ในธุรกรรมเดียวเท่ากันทุกแถว (เวลาเริ่มธุรกรรม)
--   ถ้าปล่อยให้เท่ากันหมด เทสต์จะผ่านทั้งที่วิวเรียงด้วยนาฬิกา = ไม่ได้พิสูจน์อะไร
-- ============================================================

begin;

-- ---------- fixtures ----------
create temporary table t_vuid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_vuid(label) values ('v_mgmt'), ('v_mgr'), ('v_staff');
insert into auth.users(id) select id from t_vuid;

insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, u.label || '@test.local', u.label, x.role, true
  from t_vuid u
  join (values ('v_mgmt', 'management'), ('v_mgr', 'manager'), ('v_staff', 'staff'))
    as x(label, role) on x.label = u.label;

create or replace function pg_temp.vuid(p_label text) returns uuid
language sql stable as $fn$ select id from t_vuid where label = p_label $fn$;

create or replace function pg_temp.vlogin(p_label text) returns void
language sql as $fn$
  select set_config('test.uid', coalesce((select id::text from t_vuid where label = p_label), ''), true);
$fn$;

-- Manager และ Staff ต้องเห็น Entity นี้ ไม่งั้นเทสต์ RLS ผ่านเพราะมองไม่เห็นอะไรเลย
insert into sri_os.user_owner_access(user_id, owner_id)
select u.id, o.id from t_vuid u cross join sri_os.owners o
 where u.label in ('v_mgr', 'v_staff') and o.code = 'SRI_CORP'
on conflict do nothing;

-- ทรัพย์ 5 ตัว · A2 ไม่มีผู้ดูแล = Manager ต้องมองไม่เห็นทั้งตัวทรัพย์และมูลค่า
insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, manager_user_id)
select x.id, x.code, x.name, cat.class_id, cat.id, o.id, x.mgr
  from (values
    ('00000000-0000-0000-0000-0000000d0001'::uuid, 'VAL-A1', 'แก้ราคาวันเดิม',   pg_temp.vuid('v_mgr')),
    ('00000000-0000-0000-0000-0000000d0002'::uuid, 'VAL-A2', 'ไม่มีผู้ดูแล',      null),
    ('00000000-0000-0000-0000-0000000d0003'::uuid, 'VAL-A3', 'ยังไม่เคยตีราคา',  pg_temp.vuid('v_mgr')),
    ('00000000-0000-0000-0000-0000000d0004'::uuid, 'VAL-A4', 'หลายวัน',          pg_temp.vuid('v_mgr')),
    ('00000000-0000-0000-0000-0000000d0005'::uuid, 'VAL-A5', 'หลายวิธี',          pg_temp.vuid('v_mgr'))
  ) as x(id, code, name, mgr)
  cross join (select id, class_id from sri_os.asset_categories order by id limit 1) cat
  cross join (select id from sri_os.owners where code = 'SRI_CORP') o;

-- ============================================================
-- T0 · โครงสร้าง: unique ต้องรวม revision และของเดิม 3 คอลัมน์ต้องไม่เหลืออยู่
--      (ถ้าเหลือ ฟีเจอร์นี้ "เปิดแล้วแต่ใช้ไม่ได้" ซึ่งอันตรายกว่าไม่เปิด)
-- ============================================================
do $$
declare v text; n int;
begin
  select count(*) into n
    from pg_constraint con
   where con.conrelid = 'sri_os.asset_valuations'::regclass
     and con.contype in ('u', 'p')
     and (select array_agg(a.attname::text order by a.attname)
            from unnest(con.conkey) k
            join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k)
         = array['as_of', 'asset_id', 'method'];
  if n > 0 then
    raise exception 'FAIL: unique (asset_id, as_of, method) เดิมยังอยู่ → แก้ราคาวันเดิมยังทำไม่ได้';
  end if;

  select count(*) into n
    from pg_index i
   where i.indrelid = 'sri_os.asset_valuations'::regclass
     and i.indisunique
     and (select array_agg(a.attname::text order by a.attname)
            from unnest(string_to_array(i.indkey::text, ' ')::int2[]) k
            join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k)
         = array['as_of', 'asset_id', 'method', 'revision'];
  if n <> 1 then
    raise exception 'FAIL: ต้องมี unique (asset_id, as_of, method, revision) หนึ่งตัว (เจอ %)', n;
  end if;

  select string_agg(column_name, ',') into v
    from information_schema.columns
   where table_schema = 'sri_os' and table_name = 'asset_valuations'
     and column_name = 'revision' and is_nullable = 'NO';
  if v is null then
    raise exception 'FAIL: asset_valuations.revision ต้องเป็น not null';
  end if;
  raise notice 'ok T0 · unique ย้ายมารวม revision แล้ว · revision เป็น not null';
end $$;

-- ============================================================
-- T1 · ตีราคา "วันเดิม วิธีเดิม" สองครั้ง → ได้ทั้งสองแถว + revision 1, 2
--      นี่คือข้อที่ W2 มีอยู่เพื่อแก้
--      **ไม่ส่ง revision มาเลยทั้งสองครั้ง** (เส้นทางจริงของผู้ใช้/ฟอร์ม)
-- ============================================================
insert into sri_os.asset_valuations(asset_id, as_of, method, value, created_at)
values ('00000000-0000-0000-0000-0000000d0001', current_date - 3, 'appraisal', 100,
        (current_date - 3)::timestamptz + interval '10 hour'),
       -- revision 2 มี created_at **เก่ากว่า** revision 1 โดยตั้งใจ (ดูหมายเหตุหัวไฟล์)
       ('00000000-0000-0000-0000-0000000d0001', current_date - 3, 'appraisal', 180,
        (current_date - 3)::timestamptz + interval '8 hour');

do $$
declare n int; v text;
begin
  select count(*), string_agg(revision::text || ':' || value::bigint::text, ',' order by revision)
    into n, v
    from sri_os.asset_valuations
   where asset_id = '00000000-0000-0000-0000-0000000d0001';
  if n <> 2 then
    raise exception 'FAIL: ตีราคาวันเดิมวิธีเดิมสองครั้งต้องเหลือทั้งสองแถว (ได้ % แถว)', n;
  end if;
  if v <> '1:100,2:180' then
    raise exception 'FAIL: revision ต้องเป็น 1 แล้ว 2 ตามลำดับที่ลง (ได้ %)', v;
  end if;
  raise notice 'ok T1 · แก้ราคาของวันเดิมด้วยวิธีเดิมได้ โดยไม่ลบของเดิม (revision 1 → 2)';
end $$;

-- ============================================================
-- T2 · "มูลค่าล่าสุด" = revision ล่าสุด (ไม่ใช่ revision แรก ไม่ใช่แถวที่นาฬิกาใหม่สุด)
-- ============================================================
do $$
declare r record; n int;
begin
  select * into r from sri_os.v_asset_latest_value
   where asset_id = '00000000-0000-0000-0000-0000000d0001';
  if r.value <> 180 or r.revision <> 2 then
    raise exception 'FAIL: มูลค่าล่าสุดของ A1 ต้องเป็น revision 2 = 180 (ได้ revision % = %) → วิวเลือกแถวผิด มูลค่าพอร์ตจะผิดเงียบๆ',
      r.revision, r.value;
  end if;
  if r.method <> 'appraisal' or r.as_of <> current_date - 3 then
    raise exception 'FAIL: A1 ต้องได้ (appraisal, %) แต่ได้ (%, %)', current_date - 3, r.method, r.as_of;
  end if;
  if r.is_stale is not false then
    raise exception 'FAIL: ราคาอายุ 3 วันต้องไม่ stale (ได้ %)', r.is_stale;
  end if;

  -- revision ที่ถูกแก้แล้วต้องไม่โผล่ในวิว ไม่งั้นผลรวมนับซ้ำเท่าจำนวนครั้งที่แก้
  select count(*) into n from sri_os.v_asset_valuation_current
   where asset_id = '00000000-0000-0000-0000-0000000d0001';
  if n <> 1 then
    raise exception 'FAIL: A1 ต้องมีราคาที่ยังมีผล 1 แถว (ได้ %) → รวมยอดจะนับซ้ำ', n;
  end if;
  raise notice 'ok T2 · มูลค่าล่าสุด = revision ล่าสุด · revision เก่าเป็นประวัติ ไม่นับในผลรวม';
end $$;

-- ============================================================
-- T3 · หลายวันหลาย revision ปนกัน → วันล่าสุดมาก่อน แล้วค่อย revision ล่าสุดในวันนั้น
--      แถวของวันเก่าถูกลงทีหลังสุด (created_at ใหม่สุด) และมี revision สูงสุด
--      → จับทั้งบั๊ก "เรียง revision ก่อนวัน" และ "เรียงนาฬิกาก่อนวัน"
-- ============================================================
insert into sri_os.asset_valuations(asset_id, as_of, method, value, created_at)
values ('00000000-0000-0000-0000-0000000d0004', current_date - 3, 'manual', 10,
        (current_date - 3)::timestamptz + interval '9 hour'),
       ('00000000-0000-0000-0000-0000000d0004', current_date - 3, 'manual', 20,
        (current_date - 3)::timestamptz + interval '10 hour'),
       ('00000000-0000-0000-0000-0000000d0004', current_date,     'manual', 150,
        current_date::timestamptz + interval '8 hour'),
       -- ลงทีหลังสุด แต่เป็นการแก้ราคาของ "วันเก่า" → ต้องไม่ชนะวันล่าสุด
       ('00000000-0000-0000-0000-0000000d0004', current_date - 3, 'manual', 999,
        current_date::timestamptz + interval '23 hour');

do $$
declare r record;
begin
  select * into r from sri_os.v_asset_latest_value
   where asset_id = '00000000-0000-0000-0000-0000000d0004';
  if r.as_of <> current_date then
    raise exception 'FAIL: ต้องเลือกวันล่าสุด (%) ก่อน แต่ได้วัน %', current_date, r.as_of;
  end if;
  if r.revision <> 1 or r.value <> 150 then
    raise exception 'FAIL: วันล่าสุดมี revision เดียว = 150 แต่ได้ revision % = % (เรียง revision/นาฬิกาก่อนวันที่?)',
      r.revision, r.value;
  end if;
  -- ยืนยันว่าแถว 999 เป็น revision 3 ของวันเก่าจริง (ประวัติยังอยู่ครบ)
  if (select revision from sri_os.asset_valuations
       where asset_id = '00000000-0000-0000-0000-0000000d0004' and value = 999) <> 3 then
    raise exception 'FAIL: การแก้ราคาครั้งที่สามของวันเก่าต้องได้ revision 3';
  end if;
  raise notice 'ok T3 · วันล่าสุดมาก่อน revision ล่าสุด (วันเก่าที่ถูกแก้ทีหลังไม่แย่งตำแหน่ง)';
end $$;

-- ============================================================
-- T4 · หลาย method ปนกัน → revision นับแยกต่อ method (ไม่ปนกัน)
--      manual ไปถึง revision 3 แล้ว แต่ appraisal ตัวแรกต้องเป็น revision 1 ไม่ใช่ 4
-- ============================================================
insert into sri_os.asset_valuations(asset_id, as_of, method, value, created_at)
values ('00000000-0000-0000-0000-0000000d0005', current_date, 'manual', 10,
        current_date::timestamptz + interval '9 hour'),
       ('00000000-0000-0000-0000-0000000d0005', current_date, 'manual', 20,
        current_date::timestamptz + interval '10 hour'),
       ('00000000-0000-0000-0000-0000000d0005', current_date, 'manual', 30,
        current_date::timestamptz + interval '11 hour'),
       ('00000000-0000-0000-0000-0000000d0005', current_date, 'appraisal', 500,
        current_date::timestamptz + interval '12 hour');

do $$
declare v text; r record;
begin
  select string_agg(method || ':' || revision::text || ':' || value::bigint::text, ' | ' order by method, revision)
    into v
    from sri_os.asset_valuations
   where asset_id = '00000000-0000-0000-0000-0000000d0005';
  if v <> 'appraisal:1:500 | manual:1:10 | manual:2:20 | manual:3:30' then
    raise exception 'FAIL: revision ต้องนับแยกต่อ method · ได้ %', v;
  end if;

  -- ราคาที่ยังมีผล = revision สูงสุด **ของแต่ละ method** → สองแถว ไม่ใช่สี่ ไม่ใช่หนึ่ง
  select string_agg(method || ':' || revision::text || ':' || value::bigint::text, ' | ' order by method)
    into v
    from sri_os.v_asset_valuation_current
   where asset_id = '00000000-0000-0000-0000-0000000d0005';
  if v <> 'appraisal:1:500 | manual:3:30' then
    raise exception 'FAIL: ราคาที่ยังมีผลของ A5 ต้องเป็น appraisal rev1 + manual rev3 · ได้ %', v;
  end if;

  -- มูลค่าล่าสุดต่อทรัพย์ = หนึ่งแถวเสมอ และ (method, revision, value) ต้องมาจากแถวเดียวกัน
  select * into r from sri_os.v_asset_latest_value
   where asset_id = '00000000-0000-0000-0000-0000000d0005';
  if not exists (
    select 1 from sri_os.asset_valuations v
     where v.asset_id = '00000000-0000-0000-0000-0000000d0005'
       and v.as_of = r.as_of and v.method = r.method
       and v.revision = r.revision and v.value = r.value
  ) then
    raise exception 'FAIL: มูลค่าล่าสุดของ A5 ปนกันข้ามแถว (%, rev %, %) ไม่ตรงกับแถวใดในตาราง',
      r.method, r.revision, r.value;
  end if;
  if (r.method, r.revision, r.value) is distinct from ('appraisal', 1, 500::numeric) then
    raise exception 'FAIL: วิธีที่ลงล่าสุดของวันล่าสุดต้องชนะ (appraisal rev1 = 500) · ได้ (%, %, %)',
      r.method, r.revision, r.value;
  end if;
  raise notice 'ok T4 · revision แยกต่อ method · ไม่ปนกันข้าม method · ผลลัพธ์มาจากแถวเดียวกันทั้งแถว';
end $$;

-- ============================================================
-- T5 · ทรัพย์ที่ยังไม่เคยตีราคา → ยังอยู่ในรายงาน และเป็น NULL ไม่ใช่ 0
--      "ยังไม่เคยตี" กับ "ตีแล้วได้ศูนย์" คนละเรื่อง ห้ามกลายเป็นเรื่องเดียวกันเงียบๆ
-- ============================================================
insert into sri_os.asset_valuations(asset_id, as_of, method, value)
values ('00000000-0000-0000-0000-0000000d0002', current_date, 'manual', 9000000);

do $$
declare r record; n int;
begin
  select count(*) into n from sri_os.v_asset_latest_value
   where asset_id = '00000000-0000-0000-0000-0000000d0003';
  if n <> 1 then
    raise exception 'FAIL: ทรัพย์ที่ยังไม่เคยตีราคาหายไปจากรายงาน (เจอ % แถว)', n;
  end if;

  select * into r from sri_os.v_asset_latest_value
   where asset_id = '00000000-0000-0000-0000-0000000d0003';
  if r.value is not null then
    raise exception 'FAIL: ทรัพย์ที่ยังไม่เคยตีราคาต้องได้ value = NULL ไม่ใช่ % (0 = ตีแล้วได้ศูนย์)', r.value;
  end if;
  if r.as_of is not null or r.method is not null or r.revision is not null then
    raise exception 'FAIL: ทรัพย์ที่ยังไม่เคยตีราคาต้องไม่มี as_of/method/revision';
  end if;
  if r.is_stale is not null then
    raise exception 'FAIL: is_stale ของทรัพย์ที่ไม่เคยตีราคาต้องเป็น NULL (ได้ %) → fn_health_check จะเปลี่ยนความหมาย', r.is_stale;
  end if;

  -- ทรัพย์ทุกตัวต้องมีแถวเดียวเท่ากัน (ไม่ขาด ไม่ซ้ำ)
  select count(*) into n from sri_os.v_asset_latest_value lv
    join sri_os.assets a on a.id = lv.asset_id
   where a.code like 'VAL-%';
  if n <> 5 then
    raise exception 'FAIL: ทรัพย์ทดสอบห้าตัวต้องได้ห้าแถวพอดี (ได้ %)', n;
  end if;
  raise notice 'ok T5 · ทรัพย์ที่ไม่เคยตีราคายังอยู่ในรายงาน ด้วย NULL ไม่ใช่ 0 · หนึ่งทรัพย์หนึ่งแถว';
end $$;

-- ============================================================
-- T8 · เคส "ไม่ส่งข้อมูล" และเคสที่ต้องถูกปฏิเสธ
--      (บทเรียน mace-windu ข้อ 3: เทสต์ที่ส่งข้อมูลครบเสมอ จะไม่แตะเส้นทางที่ข้อมูลขาด)
--      วางไว้ก่อน T6/T7 เพราะยังรันเป็น superuser อยู่
-- ============================================================
do $$
declare v_id uuid;
begin
  -- 8.1 ไม่ส่ง revision = เส้นทางปกติ ต้องได้เลขถัดไปให้เอง (ไม่ใช่ error ไม่ใช่ null)
  insert into sri_os.asset_valuations(asset_id, as_of, method, value)
  values ('00000000-0000-0000-0000-0000000d0001', current_date - 3, 'appraisal', 181)
  returning id into v_id;
  if (select revision from sri_os.asset_valuations where id = v_id) <> 3 then
    raise exception 'FAIL: ไม่ส่ง revision มา ต้องได้ 3 (ต่อจาก 2)';
  end if;

  -- 8.2 ส่ง revision มาเอง = ปฏิเสธ (ไม่งั้นส่งเลขต่ำกว่าเดิมได้ แล้ว "ล่าสุด" ชี้ไปแถวเก่า)
  begin
    insert into sri_os.asset_valuations(asset_id, as_of, method, value, revision)
    values ('00000000-0000-0000-0000-0000000d0001', current_date - 3, 'appraisal', 1, 1);
    raise exception 'FAIL: ส่ง revision มาเองได้';
  exception when check_violation then null;
  end;

  -- 8.3 ไม่ส่ง value (จำนวนเงิน) = ปฏิเสธ ห้ามเดาเป็น 0
  begin
    insert into sri_os.asset_valuations(asset_id, as_of, method)
    values ('00000000-0000-0000-0000-0000000d0001', current_date, 'manual');
    raise exception 'FAIL: ลงราคาโดยไม่ส่ง value ได้ → ทรัพย์จะมีมูลค่า 0 แบบเงียบๆ';
  exception when not_null_violation then null;
  end;

  -- 8.4 ไม่ส่ง as_of = ปฏิเสธ (ไม่รู้ว่าเป็นราคาของวันไหน → เทียบ "ล่าสุด" ไม่ได้)
  begin
    insert into sri_os.asset_valuations(asset_id, method, value)
    values ('00000000-0000-0000-0000-0000000d0001', 'manual', 5);
    raise exception 'FAIL: ลงราคาโดยไม่ส่ง as_of ได้';
  exception when not_null_violation then null;
  end;

  -- 8.5 ไม่ส่ง method = ปฏิเสธ (revision นับต่อ method → ไม่มี method ก็นับไม่ได้)
  begin
    insert into sri_os.asset_valuations(asset_id, as_of, value)
    values ('00000000-0000-0000-0000-0000000d0001', current_date, 5);
    raise exception 'FAIL: ลงราคาโดยไม่ส่ง method ได้';
  exception when not_null_violation then null;
  end;

  -- 8.6 แก้ราคาทับแถวเดิม = ปฏิเสธ (ต้องลงแถวใหม่ ประวัติต้องอยู่)
  begin
    update sri_os.asset_valuations set value = 777
     where asset_id = '00000000-0000-0000-0000-0000000d0001' and revision = 1;
    raise exception 'FAIL: update ราคาทับแถวเดิมได้ → ประวัติหาย เท่ากับลบทับ';
  exception when check_violation then null;
  end;

  -- 8.7 ขยับ revision ของแถวเก่า = ปฏิเสธ (ไม่งั้นสลับลำดับประวัติได้)
  begin
    update sri_os.asset_valuations set revision = 99
     where asset_id = '00000000-0000-0000-0000-0000000d0001' and revision = 1;
    raise exception 'FAIL: แก้ revision ของแถวเดิมได้';
  exception when check_violation then null;
  end;

  -- คืนสภาพให้ T6 นับยอดได้ตรง (ลบแถว 8.1 ออก — ยังเป็น superuser จึงทำได้)
  delete from sri_os.asset_valuations where id = v_id;
  raise notice 'ok T8 · ไม่ส่ง revision = ระบบออกให้ · ส่งมาเอง/ไม่ส่ง value,as_of,method/update = ปฏิเสธทุกทาง';
end $$;

-- ============================================================
-- T7 · โครงสร้าง: วิวทั้งสองตัวต้องตั้ง security_invoker = true
--      (event trigger ตั้งให้อัตโนมัติ แต่สร้าง event trigger ได้เฉพาะ superuser
--       → ยืนยันผลลัพธ์จริงจาก pg_class ไม่ใช่เชื่อว่ามี trigger)
-- ============================================================
do $$
declare v text;
begin
  select string_agg(c.relname, ', ') into v
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os'
     and c.relname in ('v_asset_latest_value', 'v_asset_valuation_current')
     and not coalesce(array_to_string(c.reloptions, ',') ilike '%security_invoker=true%', false);
  if v is not null then
    raise exception 'FAIL: วิวที่ไม่ได้ตั้ง security_invoker: % → รันด้วยสิทธิ์เจ้าของวิว = มูลค่าทั้งพอร์ตรั่ว', v;
  end if;
  if (select count(*) from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
       where ns.nspname = 'sri_os'
         and c.relname in ('v_asset_latest_value', 'v_asset_valuation_current')) <> 2 then
    raise exception 'FAIL: ไม่เจอวิวทั้งสองตัว — เทสต์นี้อาจไม่ได้ตรวจอะไรเลย';
  end if;
  raise notice 'ok T7 · วิวทั้งสองตัวตั้ง security_invoker = true';
end $$;

-- ============================================================
-- T6 · วิวเคารพ RLS — คนที่เห็นทรัพย์ไม่ได้ ต้องไม่เห็นมูลค่า
--      A1 180 · A4 150 · A5 500 (ของ Manager) · A2 9,000,000 (ไม่มีผู้ดูแล) · A3 ไม่มีราคา
-- ============================================================
-- ตัวช่วยของเทสต์อยู่ใน schema ชั่วคราวของ session · role authenticated ต้องเรียกได้
do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.t_vuid to authenticated', s);
end $$;

set local role authenticated;

do $$
declare v_sum numeric; v_direct numeric; n int; n_leak int;
begin
  -- Manager: เห็นแค่ทรัพย์ที่ตัวเองดูแล → 830 ไม่ใช่ 9,000,830
  perform pg_temp.vlogin('v_mgr');
  select coalesce(sum(value), 0) into v_sum from sri_os.v_asset_latest_value;
  select coalesce(sum(value), 0) into v_direct from sri_os.v_asset_valuation_current;
  if v_sum <> 830 then
    raise exception 'FAIL: Manager รวมมูลค่าผ่าน v_asset_latest_value ได้ % (ต้อง 830) → มูลค่าพอร์ตรั่วผ่านวิว', v_sum;
  end if;
  -- v_asset_valuation_current มีหลายแถวต่อทรัพย์ (ต่อวัน/ต่อวิธี) → **ไม่ใช่ NAV**
  -- เขียนตัวเลขต่างกันไว้ตรงนี้โดยตั้งใจ เพื่อให้คนที่เผลอเอาวิวนี้ไปรวมพอร์ตเห็นว่าต่างกันจริง
  -- (830 = มูลค่าล่าสุดต่อทรัพย์ · 1859 = ผลรวมของทุกวัน/ทุกวิธีที่ยังมีผล)
  if v_direct <> 1859 then
    raise exception 'FAIL: Manager รวม v_asset_valuation_current ได้ % (ต้อง 1859 = 180+999+150+30+500) → วิวกรอง revision สูงสุดต่อกลุ่มผิด', v_direct;
  end if;
  if v_direct = v_sum then
    raise exception 'FAIL: สองวิวให้ผลรวมเท่ากัน — เทสต์นี้แยกไม่ออกว่าใครเป็นใคร';
  end if;
  if exists (select 1 from sri_os.v_asset_latest_value
              where asset_id = '00000000-0000-0000-0000-0000000d0002') then
    raise exception 'FAIL: Manager เห็นทรัพย์ที่ไม่มีผู้ดูแล (A2) ในวิวมูลค่า';
  end if;
  select count(*) into n from sri_os.v_asset_latest_value;
  if n <> 4 then
    raise exception 'FAIL: Manager ต้องเห็น 4 ทรัพย์ (A1,A3,A4,A5) ได้ %', n;
  end if;

  -- Staff: เห็นชื่อทรัพย์เพื่อคีย์รายการได้ แต่ต้องไม่เห็นตัวเลขมูลค่าเลย
  perform pg_temp.vlogin('v_staff');
  select count(*) filter (where value is not null), coalesce(sum(value), 0)
    into n_leak, v_sum from sri_os.v_asset_latest_value;
  if n_leak <> 0 or v_sum <> 0 then
    raise exception 'FAIL: Staff เห็นมูลค่าผ่านวิว % แถว รวม %', n_leak, v_sum;
  end if;
  if (select count(*) from sri_os.v_asset_valuation_current) <> 0 then
    raise exception 'FAIL: Staff อ่าน v_asset_valuation_current ได้';
  end if;

  -- ขาบวก: Management ต้องเห็นทั้งพอร์ต ไม่งั้นเทสต์ข้างบนผ่านเพราะปิดตายทุกคน
  perform pg_temp.vlogin('v_mgmt');
  select coalesce(sum(value), 0) into v_sum from sri_os.v_asset_latest_value lv
    join sri_os.assets a on a.id = lv.asset_id where a.code like 'VAL-%';
  if v_sum <> 9000830 then
    raise exception 'FAIL: Management ต้องเห็นมูลค่าทั้งพอร์ต 9,000,830 (ได้ %)', v_sum;
  end if;
  raise notice 'ok T6 · วิวเคารพ RLS · Manager 830 · Staff 0 (เห็นชื่อทรัพย์แต่ไม่เห็นเงิน) · Management 9,000,830';
end $$;

reset role;

rollback;
