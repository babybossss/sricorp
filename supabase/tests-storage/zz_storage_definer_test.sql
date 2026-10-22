-- ============================================================
-- SRI OS · เทสต์ของ 20261020000004_storage_definer_allowlist.sql — ฝั่งที่ **มี** storage
--   รัน: bash scripts/test-storage-local.sh   (harness นี้จำลองสคีมา storage ให้)
--   ฝั่งที่ไม่มี storage (การไล่ callee ของด่าน) อยู่ที่ supabase/tests/zz_storage_definer_test.sql
--
-- ทำไมเคสฝั่ง **บวก** ถึงสำคัญ (บทเรียนที่ทำให้บั๊กนี้มองไม่เห็น)
--   เทสต์เดิมมีแต่ "anon เรียกไม่ได้" → ตอน 20261007000007 ถอน execute ของ
--   fn_attachment_in_use ไปทั้งตัว **ไม่มีอะไรฟ้องเลย** ทั้งที่ลบไฟล์แนบไม่ได้แล้ว
--   เทสต์ที่ตรวจแต่ฝั่งปฏิเสธ จะไม่มีวันจับการปฏิเสธที่มากเกินไป
--
-- ไล่ "ถอดการแก้ออกแล้วต้องแดง" (mutation):
--   S1 ถอด grant execute (เนื้อใน fn_storage_function_acl_apply)  → G1 G6 G7
--   S2 ถอด allow-list 3 แถวของ fn_attachment_in_use               → G8
--   S4 ถอดเงื่อนไข settings.manage ใน fn_attachment_orphans        → G4 (พฤติกรรม) · G9 (ด่าน)
--   ถอด perform fn_storage_definer_guard() ใน fn_column_exposure_guard() → G7d G9c
-- ============================================================
begin;

-- ---------- fixtures ----------
create temporary table zz_sd_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into zz_sd_uid(label) values ('maker'), ('mgmt');
insert into auth.users(id) select id from zz_sd_uid;

insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, u.label || '@sd.local', u.label, x.role, true
  from zz_sd_uid u
  join (values ('maker', 'staff'), ('mgmt', 'management')) as x(label, role) on x.label = u.label;

insert into sri_os.user_owner_access(user_id, owner_id)
select u.id, o.id from zz_sd_uid u cross join sri_os.owners o where o.code = 'SRI_CORP'
on conflict do nothing;

create or replace function pg_temp.su(p_label text) returns uuid
language sql stable as $fn$ select id from zz_sd_uid where label = p_label $fn$;
create or replace function pg_temp.own(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.owners where code = p_code $fn$;
create or replace function pg_temp.pth(p_tag text) returns text
language sql stable as $fn$
  select pg_temp.own('SRI_CORP')::text || '/' || pg_temp.su('maker')::text || '/'
         || md5(p_tag)::uuid::text || '.jpg'
$fn$;

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

-- ลบไฟล์ในฐานะผู้ใช้ · คืนจำนวนแถวที่หาย · 'denied' = ไม่มีสิทธิ์เรียกฟังก์ชันใน policy
create or replace function pg_temp.del(p_label text, p_name text) returns text
language plpgsql as $fn$
declare n int;
begin
  perform set_config('test.uid', (select id::text from zz_sd_uid where label = p_label), true);
  set local role authenticated;
  delete from storage.objects where bucket_id = 'attachments' and name = p_name;
  get diagnostics n = row_count;
  reset role;
  return n::text;
exception
  when insufficient_privilege then reset role; return 'denied';
  when restrict_violation   then reset role; return 'blocked';
end $fn$;

do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated, anon', s);
  execute format('grant select on %I.zz_sd_uid to authenticated, anon', s);
end $$;

-- ไฟล์: f_link ถูกร่างอ้างถึง · f_float ไม่มีใครอ้าง (เก่ากว่าช่วงผ่อนผัน) · f_free ไฟล์ลอยใหม่
insert into storage.objects(bucket_id, name, metadata)
values ('attachments', pg_temp.pth('f_link'),  '{"size": 100}'),
       ('attachments', pg_temp.pth('f_float'), '{"size": 100}'),
       ('attachments', pg_temp.pth('f_free'),  '{"size": 100}');
insert into sri_os.draft_entries(owner_id, txn_type_code, doc_date, amount, created_by, attachments)
values (pg_temp.own('SRI_CORP'), 'inc.other', current_date, 1, pg_temp.su('maker'),
        array[pg_temp.pth('f_link')]);
update storage.objects set created_at = now() - interval '3 days'
 where bucket_id = 'attachments' and name = pg_temp.pth('f_float');

-- ---------- G0 · สภาพตั้งต้น: ด่านเรียบร้อย + allow-list ครบ 6 แถว ----------
do $$
declare n int;
begin
  begin
    perform sri_os.fn_column_exposure_guard();
  exception when others then
    raise exception 'FAIL: G0 ด่านคอลัมน์ไม่เรียบร้อยก่อนเทสต์เริ่ม → เคสอื่นเชื่อไม่ได้ · สาเหตุ: %', sqlerrm;
  end;
  select count(*) into n from sri_os.fn_column_exposure_row_escapes();
  if n <> 0 then
    raise exception 'FAIL: G0b มีทางอ้อมแบบ definer ที่ยังไม่ได้ตัดสิน % รายการ (คือสภาพที่ทำให้สร้างบัญชี Staff ไม่ได้)', n;
  end if;
  select count(*) into n from sri_os.column_exposure_definer_reads
   where function_name = 'fn_attachment_in_use';
  if n <> 3 then
    raise exception 'FAIL: G0c allow-list ของ fn_attachment_in_use ต้องมี 3 แถว (transactions · draft_entries · contracts) พบ %', n;
  end if;
  select count(*) into n from sri_os.column_exposure_definer_reads
   where function_name = 'fn_attachment_orphans';
  if n <> 3 then
    raise exception 'FAIL: G0d allow-list ของ fn_attachment_orphans ต้องมี 3 แถว พบ %', n;
  end if;
  -- ทุกแถวต้องมีเหตุผลที่เขียนให้คนอ่าน ไม่ใช่คำว่า "ok"
  if exists (select 1 from sri_os.column_exposure_definer_reads
              where function_name like 'fn_attachment%' and length(reason) < 60) then
    raise exception 'FAIL: G0e มีแถว allow-list ที่เหตุผลสั้นเกินจะเข้าใจทีหลัง';
  end if;
  perform sri_os.fn_storage_definer_guard();
  raise notice 'ok G0 · ด่านเรียบร้อย · ไม่มีทางอ้อมค้าง · allow-list ไฟล์แนบ 6 แถวพร้อมเหตุผล';
end $$;

-- ---------- G1 · ฝั่งบวก: authenticated เรียก fn_attachment_in_use ได้จริง ----------
do $$
begin
  perform set_config('test.uid', pg_temp.su('maker')::text, true);
  set local role authenticated;
  if not sri_os.fn_attachment_in_use(pg_temp.pth('f_link')) then
    raise exception 'FAIL: G1a ไฟล์ที่ร่างอ้างถึงต้องตอบ true';
  end if;
  if sri_os.fn_attachment_in_use(pg_temp.pth('f_float')) then
    raise exception 'FAIL: G1b ไฟล์ลอยต้องตอบ false';
  end if;
  if sri_os.fn_attachment_in_use(null) is not false then
    raise exception 'FAIL: G1c path ว่างต้องตอบ false ไม่ใช่ null/error';
  end if;
  reset role;
  if not has_function_privilege('authenticated', 'sri_os.fn_attachment_in_use(text)', 'execute') then
    raise exception 'FAIL: G1d authenticated ไม่มี execute → policy attachments_delete จะล้ม';
  end if;
  if not has_function_privilege('authenticated', 'sri_os.fn_attachment_orphans(text)', 'execute') then
    raise exception 'FAIL: G1e authenticated ไม่มี execute ของ fn_attachment_orphans → หน้าจัดการไฟล์ลอยใช้ไม่ได้';
  end if;
  raise notice 'ok G1 · authenticated เรียก fn_attachment_in_use ได้และคำตอบถูก (เคสฝั่งบวกที่เคยไม่มี)';
end $$;

-- ---------- G2 · ฝั่งลบยังต้องแน่น: anon/public เรียกไม่ได้ ----------
do $$
begin
  begin
    set local role anon;
    perform sri_os.fn_attachment_in_use('x');
    reset role;
    raise exception 'FAIL: G2a anon เรียก fn_attachment_in_use ได้';
  exception when insufficient_privilege then reset role; end;
  begin
    set local role anon;
    perform * from sri_os.fn_attachment_orphans('mine');
    reset role;
    raise exception 'FAIL: G2b anon เรียก fn_attachment_orphans ได้';
  exception when insufficient_privilege then reset role; end;
  if has_function_privilege('public', 'sri_os.fn_attachment_in_use(text)', 'execute')
     or has_function_privilege('public', 'sri_os.fn_attachment_orphans(text)', 'execute') then
    raise exception 'FAIL: G2c PUBLIC เรียกฟังก์ชันไฟล์แนบได้';
  end if;
  raise notice 'ok G2 · anon/PUBLIC เรียกไม่ได้';
end $$;

-- ---------- G3 · orphans('mine') ของผู้ใช้ธรรมดา ----------
do $$
declare n int;
begin
  perform set_config('test.uid', pg_temp.su('maker')::text, true);
  set local role authenticated;
  select count(*) into n from sri_os.fn_attachment_orphans('mine');
  if n <> 1 then
    raise exception 'FAIL: G3a maker ต้องเห็นไฟล์ลอยเก่าของตัวเอง 1 ไฟล์ (ได้ %)', n;
  end if;
  select count(*) into n from sri_os.fn_attachment_orphans('mine') where path = pg_temp.pth('f_float');
  if n <> 1 then raise exception 'FAIL: G3b ไฟล์ลอยที่รายงานไม่ใช่ไฟล์ที่ควรเป็น'; end if;
  reset role;
  raise notice 'ok G3 · authenticated เรียก fn_attachment_orphans(mine) ได้';
end $$;

-- ---------- G4 · scope all ต้องมี settings.manage (S4 ต้องแดงที่นี่) ----------
do $$
declare n int;
begin
  perform set_config('test.uid', pg_temp.su('maker')::text, true);
  set local role authenticated;
  begin
    perform * from sri_os.fn_attachment_orphans('all');
    reset role;
    raise exception 'FAIL: G4a staff (ไม่มี settings.manage) ขอรายงาน all ได้ → เห็น path ของทุกผู้ถือ';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  reset role;

  perform set_config('test.uid', pg_temp.su('mgmt')::text, true);
  set local role authenticated;
  select count(*) into n from sri_os.fn_attachment_orphans('all') where path = pg_temp.pth('f_float');
  if n <> 1 then
    raise exception 'FAIL: G4b management (มี settings.manage) เรียก all ไม่ได้/ไม่เห็นของจริง (ได้ %)', n;
  end if;
  reset role;

  -- scope ที่ไม่รู้จัก = ปฏิเสธ ไม่ใช่เดาให้
  perform set_config('test.uid', pg_temp.su('mgmt')::text, true);
  set local role authenticated;
  begin
    perform * from sri_os.fn_attachment_orphans('ทุกอย่าง');
    reset role;
    raise exception 'FAIL: G4c scope ที่ไม่รู้จักผ่าน';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  reset role;
  raise notice 'ok G4 · scope all ต้องมี settings.manage · scope แปลกถูกปฏิเสธ';
end $$;

-- ---------- G5 · ไม่ล็อกอิน (auth.uid() ว่าง) → ปฏิเสธ ----------
do $$
begin
  perform set_config('test.uid', '', true);
  set local role authenticated;
  begin
    perform * from sri_os.fn_attachment_orphans('mine');
    reset role;
    raise exception 'FAIL: G5 ผู้ที่ไม่ได้ล็อกอินขอรายงานไฟล์ลอยได้';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  reset role;
  raise notice 'ok G5 · auth.uid() ว่าง = ปฏิเสธ (definer ที่ข้าม RLS ต้องถามเอง)';
end $$;

-- ---------- G6 · ปลายทางจริง: ลบไฟล์ลอยของตัวเองได้ (policy เรียก fn_attachment_in_use) ----------
do $$
begin
  if pg_temp.del('maker', pg_temp.pth('f_free')) <> '1' then
    raise exception 'FAIL: G6a ผู้อัปโหลดลบไฟล์ลอยของตัวเองไม่ได้ → อาการของข้อขัดแย้ง storage × 20261007000007';
  end if;
  if pg_temp.del('maker', pg_temp.pth('f_link')) <> '0' then
    raise exception 'FAIL: G6b ไฟล์ที่ร่างอ้างถึงกลับลบได้';
  end if;
  raise notice 'ok G6 · ลบไฟล์ลอยของตัวเองได้ · ไฟล์ที่ถูกอ้างลบไม่ได้';
end $$;

-- ============================================================
-- G7 · จำลอง "ลำดับจริง" ที่ 20261007000007 ปิด execute ทีหลัง
--      (harness นี้รันไฟล์ storage ท้ายสุด จึงไม่เจอเองโดยธรรมชาติ)
--      พิสูจน์สองอย่าง: (ก) ถอน execute แล้วลบไฟล์ไม่ได้จริง
--                      (ข) fn_storage_function_acl_apply() ของ migration คืนให้ได้จริง
-- ============================================================
savepoint sp_acl;
revoke all on function sri_os.fn_attachment_in_use(text)  from authenticated;
revoke all on function sri_os.fn_attachment_orphans(text) from authenticated;

do $$
declare v_id uuid := gen_random_uuid();
begin
  -- (ก) อาการที่วัดได้: ลบไฟล์แนบไม่ได้ทั้ง bucket
  insert into storage.objects(bucket_id, name, metadata)
    values ('attachments', pg_temp.pth('f_denied'), '{"size": 100}');
  if pg_temp.del('maker', pg_temp.pth('f_denied')) <> 'denied' then
    raise exception 'FAIL: G7a ถอน execute แล้วยังลบได้ → เทสต์นี้ไม่ได้จำลองอะไรเลย';
  end if;

  -- (ข) ด่านต้องฟ้อง ไม่ใช่รู้ตอนผู้ใช้ลบไฟล์ไม่ได้
  perform pg_temp.must_raise('G7b ด่าน storage',
    'select sri_os.fn_storage_definer_guard()', 'ไม่มีสิทธิ์ execute');
  perform pg_temp.must_raise('G7c ด่านรวมของ D-089',
    'select sri_os.fn_column_exposure_guard()', 'ไม่มีสิทธิ์ execute');

  -- (ค) และต้องฟ้องถึงมือคน: สร้างบัญชี Staff ไม่ได้
  insert into auth.users(id) values (v_id);
  begin
    insert into sri_os.app_users(id, email, display_name, role, is_active)
      values (v_id, 'zz_sd_block@sd.local', 'zz_sd_block', 'staff', true);
    raise exception 'FAIL: G7d ถอน execute ของฟังก์ชันที่ policy เรียก แล้วยังสร้างบัญชี Staff ได้ → ไม่มีอะไรฟ้องเลย (นี่คือเหตุที่บั๊กเดิมมองไม่เห็น)';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  -- (ง) คืนด้วยของจริงจาก migration (ไม่ใช่ grant ที่เทสต์เขียนเอง)
  perform sri_os.fn_storage_function_acl_apply();
  perform sri_os.fn_storage_definer_guard();
  perform sri_os.fn_column_exposure_guard();
  if pg_temp.del('maker', pg_temp.pth('f_denied')) <> '1' then
    raise exception 'FAIL: G7e คืน execute แล้วยังลบไฟล์ลอยไม่ได้';
  end if;
  raise notice 'ok G7 · ถอน execute = ลบไฟล์ไม่ได้ + ด่านแดง + สร้างบัญชี Staff ไม่ได้ · fn_storage_function_acl_apply() คืนให้ได้จริง';
end $$;

rollback to savepoint sp_acl;

-- ============================================================
-- G8 · ถอน allow-list 3 แถวของ fn_attachment_in_use → ด่านต้องแดง (mutation S2)
-- ============================================================
savepoint sp_allow;
delete from sri_os.column_exposure_definer_reads where function_name = 'fn_attachment_in_use';

do $$
declare n int; v_id uuid := gen_random_uuid();
begin
  select count(*) into n from sri_os.fn_column_exposure_row_escapes()
   where function_name = 'fn_attachment_in_use';
  if n <> 3 then
    raise exception 'FAIL: G8a ถอน allow-list แล้วต้องเจอทางอ้อม 3 จุด (transactions · draft_entries · contracts) ได้ %', n;
  end if;
  perform pg_temp.must_raise('G8b ด่านรวมต้องแดง',
    'select sri_os.fn_column_exposure_guard()', 'ไม่ติดจริง');
  insert into auth.users(id) values (v_id);
  begin
    insert into sri_os.app_users(id, email, display_name, role, is_active)
      values (v_id, 'zz_sd_block2@sd.local', 'zz_sd_block2', 'staff', true);
    raise exception 'FAIL: G8c ทางอ้อมแบบ definer 3 จุดค้างอยู่ แต่ยังสร้างบัญชี Staff ได้';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  raise notice 'ok G8 · ถอน allow-list ของ fn_attachment_in_use = ด่านแดง 3 จุด และสร้างบัญชี Staff ไม่ได้';
end $$;

rollback to savepoint sp_allow;

-- ============================================================
-- G9 · ถอดเงื่อนไข settings.manage ใน fn_attachment_orphans → ด่านต้องแดง (mutation S4)
--      เหตุผลใน allow-list อ้างว่า "มันตรวจสิทธิ์ในตัวเอง" → คำกล่าวอ้างนั้นต้องถูกบังคับ
--      ไม่ใช่เชื่อเพราะเขียนไว้ (ถ้าไม่บังคับ allow-list จะกลายเป็นที่ซ่อนรูแทน)
-- ============================================================
savepoint sp_weaken;
create or replace function sri_os.fn_attachment_orphans(p_scope text default 'mine')
returns table (path text, owner_id uuid, uploader_id uuid, size_bytes bigint, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $fn$
begin
  if auth.uid() is null then
    raise exception 'ต้องล็อกอิน';
  end if;
  -- **ถอดเงื่อนไข settings.manage ออก** (จำลอง mutation S4) · ส่วนอื่นคงไว้
  return query
  select o.name, ((storage.foldername(o.name))[1])::uuid,
         ((storage.foldername(o.name))[2])::uuid,
         coalesce((o.metadata ->> 'size')::bigint, 0), o.created_at
    from storage.objects o
   where o.bucket_id = 'attachments'
     and ((storage.foldername(o.name))[2] = auth.uid()::text
          or sri_os.fn_can_see_owner(((storage.foldername(o.name))[1])::uuid));
end $fn$;

do $$
declare v_id uuid := gen_random_uuid();
begin
  perform pg_temp.must_raise('G9a ด่าน storage ต้องจับการถอดเงื่อนไข',
    'select sri_os.fn_storage_definer_guard()', 'settings.manage');
  perform pg_temp.must_raise('G9b ด่านรวมต้องแดงด้วย',
    'select sri_os.fn_column_exposure_guard()', 'settings.manage');
  insert into auth.users(id) values (v_id);
  begin
    insert into sri_os.app_users(id, email, display_name, role, is_active)
      values (v_id, 'zz_sd_block3@sd.local', 'zz_sd_block3', 'staff', true);
    raise exception 'FAIL: G9c ถอดเงื่อนไขในฟังก์ชันที่ allow-list ยอมไว้ แล้วยังสร้างบัญชี Staff ได้';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  raise notice 'ok G9 · ถอดเงื่อนไข settings.manage = ด่านแดง (เหตุผลใน allow-list ถูกบังคับด้วยเครื่อง)';
end $$;

rollback to savepoint sp_weaken;

-- ---------- G10 · กลับสภาพเดิมแล้วทุกด่านต้องเขียว (เทสต์ไม่ทิ้งของเสียไว้) ----------
do $$
declare n int;
begin
  perform sri_os.fn_storage_definer_guard();
  perform sri_os.fn_column_exposure_guard();
  select count(*) into n from sri_os.fn_column_exposure_row_escapes();
  if n <> 0 then raise exception 'FAIL: G10 เหลือทางอ้อมค้าง % รายการหลังเทสต์', n; end if;
  select count(*) into n from sri_os.column_exposure_definer_reads
   where function_name like 'fn_attachment%';
  if n <> 6 then raise exception 'FAIL: G10b allow-list ไม่กลับมาครบ 6 แถว (ได้ %)', n; end if;
  raise notice 'ok G10 · สภาพกลับเป็นเขียวครบหลัง rollback to savepoint ทุกจุด';
end $$;

do $$ begin raise notice '=== storage × ด่านคอลัมน์ (ฝั่งมี storage) ผ่านทั้งหมด ==='; end $$;

rollback;
