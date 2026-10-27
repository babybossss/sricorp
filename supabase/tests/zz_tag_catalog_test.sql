-- ============================================================
-- SRI OS · เทสต์ **แค็ตตาล็อก tag** (20261027000001_tag_catalog.sql · ADR 0002/0003)
--
-- ก่อนไฟล์นั้น: ไม่มีที่เก็บ project/label เลย → ติด tag ให้รายการไม่ได้ และ
-- "Filter มาดูทุก Transaction เวลาตรวจย้อนหลัง" (คำสั่งลูกพี่ 26/10) ทำไม่ได้
--
-- สิ่งที่ไฟล์นี้พิสูจน์:
--   T0 · โครงสร้าง — ไม่มี owner_id/parent_id/merged_into_id · ไม่มีคอลัมน์เงิน ·
--        ไม่มี policy DELETE · RLS เปิด · สิทธิ์สองตัวอยู่ในตารางสิทธิ์
--   T1 · seed สองชนิด + **requires_allocation ของ project = true · label = false**
--        (ADR 0003 หัวข้อ 3.1) · ประโยคกำกับว่างไม่ได้ · เงื่อนไขสองทางของ
--        allocation_note_th
--   T2 · รหัส tag: รูปผิด/ซ้ำ/ชื่อว่าง → ปฏิเสธ
--   T3 · โทเคนสี: **hex ไม่ได้** · โทเคนที่ไม่อยู่ใน settings ไม่ได้ · คอนฟิกหาย = ปฏิเสธ
--   T4 · รหัสและชนิดแช่แข็ง (แก้ย้อนหลังไม่ได้)
--   T5 · **ปิดได้ ห้ามลบ** — delete ปฏิเสธถึงชั้น superuser · ปิดแล้วร่องรอยครบเอง
--   T6 · RLS — tag.catalog เท่านั้นที่สร้าง/แก้ได้ · **manager ไม่มี** · ทุกคนอ่านได้
--
-- รันในฐานะ superuser = ข้าม RLS แต่ **trigger/constraint ยังทำงานทุกเส้นทาง**
--   (กฎร่องรอยต้องไม่ขึ้นกับสิทธิ์) · T6 เดินเส้นทางจริงด้วย role authenticated
--
-- mutation ที่ต้องทำให้เทสต์แดง (ถ้าไม่แดง = เทสต์ยังไม่ครอบ):
--   M1 ถอด trigger trg_tags_no_delete          → T5a แดง
--   M2 ยอมให้แก้ code ย้อนหลัง                  → T4a แดง
--   M3 ให้ seed ของ project.requires_allocation
--      เป็น false                               → T1b แดง
--   M4 ให้ color_token รับ hex                  → T3a แดง
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures · ผู้ใช้สามระดับ (management / manager / staff)
-- ------------------------------------------------------------
create temporary table t_tuid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_tuid(label) values ('t_mgmt'), ('t_mgr'), ('t_staff');
insert into auth.users(id) select id from t_tuid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select id, label || '@tagcat.local', label,
       case label when 't_mgmt' then 'management'
                  when 't_mgr'  then 'manager'
                  else 'staff' end,
       true
  from t_tuid;

create or replace function pg_temp.tuid(p_label text) returns uuid
language sql stable as $fn$ select id from t_tuid where label = p_label $fn$;

create or replace function pg_temp.tlogin(p_label text) returns void
language sql as $fn$
  select set_config('test.uid', coalesce((select id::text from t_tuid where label = p_label), ''), true);
$fn$;

create or replace function pg_temp.must_fail_like(p_label text, p_sql text, p_needle text) returns void
language plpgsql as $fn$
declare v text;
begin
  begin
    execute p_sql;
    raise exception 'TAG_UNEXPECTED_SUCCESS';
  exception when others then
    v := sqlerrm;
    if v = 'TAG_UNEXPECTED_SUCCESS' then
      raise exception 'FAIL: % — คำสั่งควรถูกปฏิเสธแต่สำเร็จ', p_label;
    end if;
    if v like 'FAIL:%' then raise; end if;
    if position(p_needle in v) = 0 then
      raise exception 'FAIL: % — ปฏิเสธถูกแต่ข้อความไม่มี "%" · ได้: %', p_label, p_needle, v;
    end if;
  end;
end $fn$;

create or replace function pg_temp.must_pass(p_label text, p_sql text) returns void
language plpgsql as $fn$
begin
  execute p_sql;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: % — เส้นทางที่ถูกต้องถูกปฏิเสธ (กันแน่นเกิน): %', p_label, sqlerrm;
end $fn$;

select pg_temp.tlogin('t_mgmt');

-- ============================================================
-- T0 · โครงสร้าง — ไล่จาก catalog จริง ไม่ใช่ไล่ไฟล์
-- ============================================================
do $$
declare v text;
begin
  if to_regclass('sri_os.tag_kinds') is null or to_regclass('sri_os.tags') is null then
    raise exception 'FAIL: T0 — ยังไม่มีตารางแค็ตตาล็อก tag (migration ไม่ถูก apply?) เทสต์นี้จะไม่ได้ตรวจอะไร';
  end if;

  -- (ก) ของที่ ADR 0002 ตัดสินว่า "ไม่ทำในรอบนี้" ต้องไม่โผล่มาเงียบๆ
  select string_agg(a.attname, ', ') into v
    from pg_attribute a
   where a.attrelid = 'sri_os.tags'::regclass and a.attnum > 0 and not a.attisdropped
     and a.attname in ('owner_id', 'parent_id', 'merged_into_id');
  if v is not null then
    raise exception 'FAIL: T0 — tags มีคอลัมน์ที่ยังไม่มี ADR รองรับ: % · owner_id = แค็ตตาล็อกเลิกเป็นของกองกลางแล้วต้องสร้าง tag ซ้ำทุกผู้ถือ · parent_id/merged_into_id = ยังไม่มีกฎว่ายอดของชั้นแม่-ลูกหรือของที่ merge แล้วจะนับยังไง', v;
  end if;

  -- (ข) แค็ตตาล็อกห้ามมีตัวเลขเงิน (tag ต้องไม่มีน้ำหนักต่อตัวเลขในงบ)
  select string_agg(c.table_name || '.' || c.column_name, ', ') into v
    from information_schema.columns c
   where c.table_schema = 'sri_os' and c.table_name in ('tags', 'tag_kinds')
     and c.data_type in ('numeric', 'money', 'double precision', 'real');
  if v is not null then
    raise exception 'FAIL: T0 — แค็ตตาล็อก tag มีคอลัมน์ตัวเลขเงิน: % · น้ำหนัก 60/40 ของ ADR 0003 ต้องอยู่ใน tag_allocations ตารางแยก', v;
  end if;

  -- (ค) ไม่มี policy DELETE และ RLS เปิดทั้งสองตาราง
  select string_agg(p.polname || '/' || p.polcmd::text, ', ') into v
    from pg_policy p
   where p.polrelid in ('sri_os.tags'::regclass, 'sri_os.tag_kinds'::regclass)
     and p.polcmd in ('d', '*');
  if v is not null then
    raise exception 'FAIL: T0 — มี policy DELETE/ALL บนแค็ตตาล็อก tag: %', v;
  end if;
  select string_agg(c.relname, ', ') into v from pg_class c
   where c.oid in ('sri_os.tags'::regclass, 'sri_os.tag_kinds'::regclass)
     and not c.relrowsecurity;
  if v is not null then raise exception 'FAIL: T0 — RLS ยังปิดอยู่: %', v; end if;

  -- (ง) สิทธิ์สองตัวต้องอยู่ในตาราง และ manager ต้องไม่มี tag.catalog
  select string_agg(k, ', ') into v
    from unnest(array['tag.assign', 'tag.catalog']) k
   where not exists (select 1 from sri_os.permissions p where p.key = k);
  if v is not null then raise exception 'FAIL: T0 — ไม่มีสิทธิ์ % ในตารางสิทธิ์', v; end if;
  if exists (select 1 from sri_os.role_permissions
              where permission_key = 'tag.catalog' and role_key = 'manager') then
    raise exception 'FAIL: T0 — manager ได้ tag.catalog (ADR 0002 หัวข้อ 7 ว่า management ขึ้นไป)';
  end if;
  if not exists (select 1 from sri_os.role_permissions
                  where permission_key = 'tag.assign' and role_key = 'staff') then
    raise exception 'FAIL: T0 — staff ไม่ได้ tag.assign (ADR 0002 หัวข้อ 7 ว่าทุกตำแหน่งติด tag ได้)';
  end if;

  raise notice 'ok T0 · โครงสร้างแค็ตตาล็อก: ไม่มี owner_id/parent_id/merged_into_id · ไม่มีคอลัมน์เงิน · ไม่มี policy DELETE · RLS เปิด · สิทธิ์สองตัวอยู่ในตารางสิทธิ์และ manager ไม่มี tag.catalog';
end $$;

-- ============================================================
-- T1 · seed สองชนิด + คอนฟิกการปันส่วน (ADR 0003 หัวข้อ 3.1)
-- ============================================================
do $$
declare n int;
begin
  select count(*) into n from sri_os.tag_kinds;
  if n <> 2 then
    raise exception 'FAIL: T1a — ต้องมีชนิด tag 2 แถว (project · label) แต่ได้ % · ถ้ามีมากกว่านี้ ให้ตรวจว่าใครเพิ่มและมี ADR รองรับไหม', n;
  end if;

  -- T1b · คานของ ADR 0003: project ปันส่วน · label เป็น touch
  if not (select requires_allocation from sri_os.tag_kinds where key = 'project') then
    raise exception 'FAIL: T1b — project.requires_allocation ต้องเป็น true (ADR 0003 หัวข้อ 3.1) · ถ้าเป็น false ด่าน Σ น้ำหนัก = 100%% จะไม่ครอบ project แล้วยอดต่อ project จะซ้อนกันโดยไม่มีใครรู้';
  end if;
  if (select requires_allocation from sri_os.tag_kinds where key = 'label') then
    raise exception 'FAIL: T1b — label.requires_allocation ต้องเป็น false · ถ้าเป็น true ป้ายกำกับทุกอันจะต้องกรอกน้ำหนักให้ครบ 100%% ซึ่งไม่มีความหมาย';
  end if;
  if not (select bool_and(allows_multi) from sri_os.tag_kinds) then
    raise exception 'FAIL: T1b — allows_multi ต้องเป็น true ทั้งสองชนิดตามคำสั่ง 26/10 (เลือกได้หลายอัน)';
  end if;

  -- T1c · ประโยคกำกับ (ชั้น 3 ของ ADR 0002 หัวข้อ 4) ว่างไม่ได้
  perform pg_temp.must_fail_like('T1c ชนิดใหม่ที่ประโยคกำกับว่าง', $q$
    insert into sri_os.tag_kinds(key, name_th, name_en, allows_multi, aggregate_note_th)
    values ('blank', 'ว่าง', 'Blank', true, '  ') $q$,
    'tag_kinds_note_not_blank');

  -- T1d · เงื่อนไขสองทางของ allocation_note_th
  perform pg_temp.must_fail_like('T1d ชนิดที่ปันส่วนแต่ไม่มีประโยคของตัวเอง', $q$
    insert into sri_os.tag_kinds(key, name_th, name_en, allows_multi, aggregate_note_th,
                                 requires_allocation)
    values ('cost_center', 'ศูนย์ต้นทุน', 'Cost center', true,
            'ยอดที่แตะ tag นี้ · บวกข้าม tag ไม่ได้ · ดูยอดรวมที่ชุดที่กรอง', true) $q$,
    'tag_kinds_allocation_note_both_ways');
  perform pg_temp.must_fail_like('T1d ชนิดที่ไม่ปันส่วนแต่มีประโยคของการปันส่วนค้างไว้', $q$
    insert into sri_os.tag_kinds(key, name_th, name_en, allows_multi, aggregate_note_th,
                                 requires_allocation, allocation_note_th)
    values ('cost_center', 'ศูนย์ต้นทุน', 'Cost center', true,
            'ยอดที่แตะ tag นี้ · บวกข้าม tag ไม่ได้ · ดูยอดรวมที่ชุดที่กรอง', false,
            'ส่วนแบ่งตามน้ำหนัก (ข้อความค้างที่ไม่มีใครใช้ แต่หยิบไปแสดงผิดบริบทได้)') $q$,
    'tag_kinds_allocation_note_both_ways');

  -- T1e · คีย์ของชนิดต้องเป็นรูปที่ใช้เป็นสำเนาในแถวลิงก์ได้
  perform pg_temp.must_fail_like('T1e คีย์ชนิดรูปผิด', $q$
    insert into sri_os.tag_kinds(key, name_th, name_en, allows_multi, aggregate_note_th)
    values ('Project-X', 'x', 'x', true,
            'ยอดที่แตะ tag นี้ · บวกข้าม tag ไม่ได้ · ดูยอดรวมที่ชุดที่กรอง') $q$,
    'tag_kinds_key_shape');

  raise notice 'ok T1 · seed 2 ชนิด · project ปันส่วน (requires_allocation = true) · label เป็น touch · allows_multi = true ทั้งคู่ · ประโยคกำกับว่างไม่ได้ · allocation_note_th เป็นเงื่อนไขสองทาง';
end $$;

-- ============================================================
-- T2 · รหัสและชื่อของ tag
-- ============================================================
do $$
begin
  perform pg_temp.must_pass('T2 tag ที่ถูกต้อง', $q$
    insert into sri_os.tags(kind, code, name_th, name_en, color_token)
    values ('project', 'iris-235', 'ไอริส 235', 'Iris 235', 'brand') $q$);

  perform pg_temp.must_fail_like('T2a รหัสตัวใหญ่', $q$
    insert into sri_os.tags(kind, code, name_th) values ('project', 'Iris-236', 'x') $q$,
    'tags_code_shape');
  perform pg_temp.must_fail_like('T2b รหัสมีช่องว่าง', $q$
    insert into sri_os.tags(kind, code, name_th) values ('project', 'iris 236', 'x') $q$,
    'tags_code_shape');
  perform pg_temp.must_fail_like('T2c รหัสขึ้นต้นด้วยขีด', $q$
    insert into sri_os.tags(kind, code, name_th) values ('project', '-iris', 'x') $q$,
    'tags_code_shape');
  perform pg_temp.must_fail_like('T2d รหัสซ้ำ', $q$
    insert into sri_os.tags(kind, code, name_th) values ('label', 'iris-235', 'ซ้ำ') $q$,
    'tags_code_uq');
  perform pg_temp.must_fail_like('T2e ชื่อไทยว่าง', $q$
    insert into sri_os.tags(kind, code, name_th) values ('project', 'iris-237', '   ') $q$,
    'tags_name_not_blank');
  perform pg_temp.must_fail_like('T2f ชนิดที่ไม่มีในคอนฟิก', $q$
    insert into sri_os.tags(kind, code, name_th) values ('cost_center', 'cc-1', 'x') $q$,
    'tags_kind_fkey');

  raise notice 'ok T2 · รหัสตัวใหญ่/มีช่องว่าง/ขึ้นต้นผิด/ซ้ำ · ชื่อว่าง · ชนิดที่ไม่มีในคอนฟิก → ปฏิเสธทั้งหมด';
end $$;

-- ============================================================
-- T3 · โทเคนสี — **เก็บชื่อโทเคน ไม่เก็บ hex** (กติกา UI · ผู้ใช้มีผู้สูงอายุ)
-- ============================================================
do $$
declare v_id uuid;
begin
  -- T3a · hex ตรงๆ → ปฏิเสธ (trigger พูดก่อนเพราะเป็น BEFORE · ชั้น constraint
  --       ยังอยู่ข้างใต้และตรวจแยกด้านล่าง — สองชั้นเพราะ trigger ถอดได้ constraint ถอดยาก)
  perform pg_temp.must_fail_like('T3a สีเป็น hex', $q$
    insert into sri_os.tags(kind, code, name_th, color_token)
    values ('label', 'hex-1', 'สี hex', '#004AAD') $q$,
    'ห้ามเก็บ hex');
  if not exists (select 1 from pg_constraint
                  where conrelid = 'sri_os.tags'::regclass
                    and conname = 'tags_color_token_shape' and convalidated) then
    raise exception 'FAIL: T3a — ชั้น constraint ของโทเคนสีหายไป · เหลือแต่ trigger ซึ่งถอดง่ายกว่า';
  end if;

  -- T3b · โทเคนที่ไม่อยู่ในรายชื่อของ settings → ปฏิเสธที่ชั้น trigger
  perform pg_temp.must_fail_like('T3b โทเคนที่ไม่มีในคอนฟิก', $q$
    insert into sri_os.tags(kind, code, name_th, color_token)
    values ('label', 'tok-1', 'โทเคนมั่ว', 'rainbow') $q$,
    'ไม่อยู่ในรายชื่อที่อนุญาต');

  -- T3c · คอนฟิกหาย = **ปฏิเสธ** ไม่ใช่ปล่อยผ่าน (ด่านที่ไม่รู้จะถามอะไรห้ามตอบว่าผ่าน)
  update sri_os.settings set value = '"not-an-array"'::jsonb where key = 'tags.color_tokens';
  perform pg_temp.must_fail_like('T3c คอนฟิกโทเคนสีเพี้ยน', $q$
    insert into sri_os.tags(kind, code, name_th, color_token)
    values ('label', 'tok-2', 'คอนฟิกเพี้ยน', 'brand') $q$,
    'ไม่มีรายชื่อโทเคนสีใน settings');
  update sri_os.settings
     set value = '["brand", "ink", "pos", "neg", "warn", "info", "holder.corp", "holder.person", "holder.group"]'::jsonb
   where key = 'tags.color_tokens';

  -- T3d · ไม่ใส่สีเลยได้ (ไม่บังคับ) และใส่โทเคนที่มีจริงได้
  perform pg_temp.must_pass('T3d ไม่ใส่สี', $q$
    insert into sri_os.tags(kind, code, name_th) values ('label', 'urgent', 'เร่งด่วน') $q$);
  perform pg_temp.must_pass('T3d โทเคนซ้อนชั้น', $q$
    insert into sri_os.tags(kind, code, name_th, color_token)
    values ('label', 'corp-side', 'ฝั่งบริษัท', 'holder.corp') $q$);

  raise notice 'ok T3 · hex ปฏิเสธที่ constraint · โทเคนมั่วปฏิเสธที่ trigger · คอนฟิกเพี้ยน = ปฏิเสธไม่ใช่ปล่อยผ่าน · ไม่ใส่สีได้';
end $$;

-- ============================================================
-- T4 · รหัสและชนิดแช่แข็ง · updated_at ตั้งเอง
-- ============================================================
do $$
declare v_id uuid; v_u1 timestamptz; v_cb uuid;
begin
  select id, updated_at, created_by into v_id, v_u1 from sri_os.tags where code = 'iris-235';

  if (select created_by from sri_os.tags where id = v_id) is distinct from pg_temp.tuid('t_mgmt')
     and (select created_by from sri_os.tags where id = v_id) is not null then
    raise exception 'FAIL: T4 — created_by ของ tag ไม่ใช่ค่าที่คาด';
  end if;

  perform pg_temp.must_fail_like('T4a แก้รหัสย้อนหลัง', format($q$
    update sri_os.tags set code = 'iris-235-new' where id = %L $q$, v_id),
    'แก้รหัส tag ย้อนหลังไม่ได้');

  perform pg_temp.must_fail_like('T4b ย้ายชนิด', format($q$
    update sri_os.tags set kind = 'label' where id = %L $q$, v_id),
    'ย้ายชนิดของ tag ย้อนหลังไม่ได้');

  -- แก้ชื่อ/คำอธิบาย/สี ได้ (เส้นทางที่ถูกต้องห้ามถูกกัน)
  -- และ `updated_at` ที่ส่งมา **ถูกทับด้วยเวลาจริง** — ปลอมเวลาแก้ไม่ได้
  -- (เทียบกับ now() ไม่ใช่กับค่าก่อนหน้า เพราะ now() คงที่ทั้งธุรกรรมในเทสต์นี้)
  perform pg_temp.must_pass('T4c แก้ชื่อและสี', format($q$
    update sri_os.tags
       set name_th = 'ไอริส 235 (เฟส 2)', color_token = 'info',
           updated_at = '2000-01-01'::timestamptz
     where id = %L $q$, v_id));
  if (select updated_at from sri_os.tags where id = v_id) <> now() then
    raise exception 'FAIL: T4c — updated_at ที่ส่งมาไม่ถูกทับด้วยเวลาจริง (ได้ %) → ปลอมเวลาที่แก้ได้',
      (select updated_at from sri_os.tags where id = v_id);
  end if;
  if (select name_th from sri_os.tags where id = v_id) <> 'ไอริส 235 (เฟส 2)' then
    raise exception 'FAIL: T4c — แก้ชื่อไม่ติด';
  end if;

  raise notice 'ok T4 · รหัสและชนิดแช่แข็ง · แก้ชื่อ/สีได้และ updated_at ขยับเอง';
end $$;

-- ============================================================
-- T5 · **ปิดได้ ห้ามลบ**
-- ============================================================
do $$
declare v_id uuid;
begin
  select id into v_id from sri_os.tags where code = 'urgent';

  -- T5a · ลบไม่ได้ **แม้รันในฐานะ superuser** (กฎร่องรอยไม่ขึ้นกับสิทธิ์)
  perform pg_temp.must_fail_like('T5a ลบ tag ที่ยังไม่ถูกใช้', format($q$
    delete from sri_os.tags where id = %L $q$, v_id),
    'ปิดได้ ห้ามลบ');
  perform pg_temp.must_fail_like('T5b ลบชนิด tag', $q$
    delete from sri_os.tag_kinds where key = 'label' $q$,
    'ปิดได้ ห้ามลบ');

  -- T5c · ปิดใช้งาน: ร่องรอยถูกเติมให้เอง (ใครปิด เมื่อไหร่)
  perform pg_temp.must_pass('T5c ปิดใช้งาน', format($q$
    update sri_os.tags set is_active = false where id = %L $q$, v_id));
  if (select archived_at from sri_os.tags where id = v_id) is null
     or (select archived_by from sri_os.tags where id = v_id) is distinct from pg_temp.tuid('t_mgmt') then
    raise exception 'FAIL: T5c — ปิด tag แล้วไม่มีร่องรอยว่าใครปิดเมื่อไหร่ (archived_at/by) → ปิดเงียบๆ ได้';
  end if;

  -- T5d · แปะร่องรอยการปิดบนตัวที่ยังเปิดอยู่ไม่ได้ (เงื่อนไขสองทาง)
  perform pg_temp.must_fail_like('T5d tag ที่เกิดมาปิดแต่ไม่มีร่องรอย', $q$
    insert into sri_os.tags(kind, code, name_th, is_active)
    values ('label', 'born-off', 'เกิดมาปิด', false) $q$,
    'tags_archive_both_ways');

  -- T5e · เปิดคืนได้และร่องรอยถูกล้าง (ปิดผิดตัวเกิดขึ้นจริง · audit_log เก็บไว้แล้ว)
  perform pg_temp.must_pass('T5e เปิดคืน', format($q$
    update sri_os.tags set is_active = true where id = %L $q$, v_id));
  if (select archived_at from sri_os.tags where id = v_id) is not null then
    raise exception 'FAIL: T5e — เปิดคืนแล้วยังมี archived_at ค้าง → แถวที่ดูเหมือนปิดแต่เลือกได้';
  end if;

  raise notice 'ok T5 · ลบไม่ได้ทั้ง tag และชนิด (แม้ superuser) · ปิดแล้วร่องรอยเติมเอง · เกิดมาปิดโดยไม่มีร่องรอยไม่ได้ · เปิดคืนได้';
end $$;

-- ============================================================
-- T6 · RLS — เส้นทางจริงด้วย role authenticated
--      แค็ตตาล็อกอ่านได้ทุกคน · สร้าง/แก้ได้เฉพาะ tag.catalog
-- ============================================================
do $$
declare n int;
begin
  -- (ก) management (มี tag.catalog) สร้างได้
  perform pg_temp.tlogin('t_mgmt');
  set local role authenticated;
  insert into sri_os.tags(kind, code, name_th) values ('project', 'reno-2026', 'รีโนเวต 2026');
  reset role;

  -- (ข) manager (ไม่มี tag.catalog) สร้างไม่ได้ — ADR 0002 หัวข้อ 7
  perform pg_temp.tlogin('t_mgr');
  begin
    set local role authenticated;
    insert into sri_os.tags(kind, code, name_th) values ('project', 'mgr-made', 'manager สร้าง');
    reset role;
    raise exception 'FAIL: T6b — manager สร้าง tag ได้ ทั้งที่ไม่มีสิทธิ์ tag.catalog';
  exception when insufficient_privilege then
    reset role;
  when others then
    reset role;
    if sqlerrm like 'FAIL:%' then raise; end if;
    raise exception 'FAIL: T6b — manager ถูกปฏิเสธด้วย error ที่ไม่ใช่เรื่องสิทธิ์: %', sqlerrm;
  end;

  -- (ค) staff อ่านแค็ตตาล็อกได้ (ต้องเลือก tag ตอนคีย์ร่างได้)
  perform pg_temp.tlogin('t_staff');
  set local role authenticated;
  select count(*) into n from sri_os.tags;
  if n < 1 then
    raise exception 'FAIL: T6c — staff อ่านแค็ตตาล็อกไม่เห็นเลย → เลือก tag ตอนคีย์ร่างไม่ได้';
  end if;
  select count(*) into n from sri_os.tag_kinds;
  if n <> 2 then
    raise exception 'FAIL: T6c — staff อ่าน tag_kinds ได้ % แถว (ต้อง 2) → ประโยคกำกับที่หน้าจอบังคับแสดงจะหายไป', n;
  end if;
  reset role;

  -- (ง) staff แก้แค็ตตาล็อกไม่ได้
  begin
    set local role authenticated;
    update sri_os.tags set name_th = 'staff แก้' where code = 'reno-2026';
    reset role;
    if (select name_th from sri_os.tags where code = 'reno-2026') = 'staff แก้' then
      raise exception 'FAIL: T6d — staff แก้ชื่อ tag ได้ ทั้งที่ไม่มีสิทธิ์ tag.catalog';
    end if;
  exception when insufficient_privilege then
    reset role;
  when others then
    reset role;
    if sqlerrm like 'FAIL:%' then raise; end if;
    raise exception 'FAIL: T6d — error ที่ไม่คาด: %', sqlerrm;
  end;

  perform pg_temp.tlogin('t_mgmt');
  raise notice 'ok T6 · management สร้าง/แก้ได้ · **manager สร้างไม่ได้** · staff อ่านได้ทั้งสองตารางแต่แก้ไม่ได้';
end $$;

-- ---------- สรุป ----------
do $$
declare n int;
begin
  select count(*) into n from sri_os.tags;
  if n < 4 then
    raise exception 'FAIL: นับ tag ที่สร้างได้แค่ % — เทสต์อาจไม่ได้สร้างอะไรเลย', n;
  end if;
  raise notice 'ok T · แค็ตตาล็อก tag % แถวผ่านด่านทั้งหมด', n;
end $$;

do $$ begin raise notice '=== แค็ตตาล็อก tag ผ่านทั้งหมด ==='; end $$;

rollback;
