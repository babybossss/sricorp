-- ============================================================
-- SRI OS · เทสต์ Storage policy ของ bucket `attachments`
--   ทดสอบ: supabase/migrations/20261008000009_storage_policies.sql
--   รัน:   bash scripts/test-storage-local.sh
--
-- ขอบเขตที่พิสูจน์ได้ที่นี่ = ชั้น DB (policy + trigger) เท่านั้น ไม่ใช่ Storage API
--
-- ไล่ "ถ้าถอดการแก้ออกแล้วต้องแดง" (ลองจริงด้วย mutation ดู scripts/test-storage-local.sh
--   ตัวแปร STORAGE_MIGRATION):
--   M1 bucket public                                   → B1
--   M2 select ไม่ผูกกับ fn_can_see_owner                → V16b
--   M3 select นับ "มีใครอ้าง" แทน "ผู้อ่านเห็นแถวที่อ้าง"  → V5c V6b V7b
--   M4 select ไม่เทียบ uploader กับ created_by           → V10 V14b
--   M5 select ไม่เทียบ owner ใน path กับ owner ของแถว     → V17
--   M6 insert ไม่บังคับ uploader = auth.uid()            → I3
--   M7 insert ไม่บังคับ owner ที่เห็น                      → I4
--   M8 ไม่บังคับ regex path                               → I6
--   M9 มี policy update                                  → U1
--   M10 delete policy ไม่เช็ค in_use                      → D2 (trigger ยังกันไว้ → 'blocked')
--   M11 ไม่มี trigger กันลบ                               → D4 D5 D6 E3
--   M12 fn_attachment_in_use ถามใต้ RLS (ไม่ใช่ definer)   → D3
--
-- เคส "ไม่ส่งข้อมูล" (บทเรียนข้อ 3): path ว่าง · bucket ว่าง · ไม่ล็อกอิน (uid ว่าง) ·
--   ไม่มีแถว app_users · ลบโดยไม่ใส่ WHERE · scope ผิด · ไฟล์ที่ไม่มีแถวใดอ้างถึง
-- ============================================================
begin;

-- service_role ของ Supabase มี BYPASSRLS (RLS ไม่มีผลกับมัน) · harness สร้าง role เปล่าที่ไม่มี
-- ถ้าไม่ใส่ D5 จะ "ผ่านฟรี" เพราะ RLS กรองแถวออกก่อนที่ trigger จะได้ทำงาน (rollback ท้ายไฟล์)
alter role service_role bypassrls;

-- ---------- fixtures ----------
create temporary table t_su (label text primary key, id uuid not null default gen_random_uuid());
insert into t_su(label) values
  ('maker'), ('staff2'), ('mgr'), ('mgr_asset'), ('mgmt'), ('sut_staff'), ('sut_mgr'), ('nobody'),
  ('maker2'), ('dual');
insert into auth.users(id) select id from t_su;

insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, u.label || '@st.local', u.label, x.role, true
  from t_su u
  join (values ('maker', 'staff'), ('staff2', 'staff'), ('mgr', 'manager'), ('mgr_asset', 'manager'),
               ('mgmt', 'management'), ('sut_staff', 'staff'), ('sut_mgr', 'manager'),
               ('maker2', 'staff'), ('dual', 'manager')) as x(label, role)
    on x.label = u.label;                     -- 'nobody' ไม่มีแถวโดยตั้งใจ

insert into sri_os.user_owner_access(user_id, owner_id)
select u.id, o.id from t_su u cross join sri_os.owners o
 where (u.label in ('maker', 'staff2', 'mgr', 'mgr_asset') and o.code = 'SRI_CORP')
    or (u.label in ('sut_staff', 'sut_mgr') and o.code = 'SUTEE')
    or (u.label in ('maker2', 'dual') and o.code in ('SRI_CORP', 'SUTEE'))   -- เห็นสองผู้ถือ (V17)
on conflict do nothing;

create or replace function pg_temp.su(p_label text) returns uuid
language sql stable as $fn$ select id from t_su where label = p_label $fn$;
create or replace function pg_temp.own(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.owners where code = p_code $fn$;

-- path ตามรูปแบบ <owner>/<uploader>/<uuid>.<ext> · tag เดียวกัน = path เดียวกัน
create or replace function pg_temp.pth(p_owner text, p_uploader text, p_tag text, p_ext text default 'jpg')
returns text language sql stable as $fn$
  select pg_temp.own(p_owner)::text || '/' || pg_temp.su(p_uploader)::text || '/' || md5(p_tag)::uuid::text || '.' || p_ext
$fn$;

-- ทรัพย์ที่ mgr_asset ดูแล (ทางเดียวที่ Manager จะเห็นรายการของคนอื่น)
insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, manager_user_id)
select '00000000-0000-0000-0000-0000000057a1', 'ST-A1', 'ทรัพย์เทสต์ Storage',
       (select class_id from sri_os.asset_categories order by code limit 1),
       (select id       from sri_os.asset_categories order by code limit 1),
       pg_temp.own('SRI_CORP'), pg_temp.su('mgr_asset');

-- ---------- ตัวช่วย: ทำงานในฐานะผู้ใช้ แล้วคืน role ----------
-- label 'anon' = role anon · label ที่ไม่มีใน t_su (เช่น '__nobody__') = authenticated แต่ auth.uid() ว่าง
create or replace function pg_temp.as_role(p_label text) returns void
language plpgsql as $fn$
begin
  perform set_config('test.uid', coalesce((select id::text from t_su where label = p_label), ''), true);
  if p_label = 'anon' then set local role anon; else set local role authenticated; end if;
end $fn$;

create or replace function pg_temp.put(p_label text, p_bucket text, p_name text) returns text
language plpgsql as $fn$
begin
  perform pg_temp.as_role(p_label);
  insert into storage.objects(bucket_id, name, metadata) values (p_bucket, p_name, '{"size": 100}');
  reset role;
  return 'ok';
exception when insufficient_privilege then
  reset role;
  return 'denied';
end $fn$;

create or replace function pg_temp.sees(p_label text, p_name text) returns boolean
language plpgsql as $fn$
declare n int;
begin
  perform pg_temp.as_role(p_label);
  select count(*) into n from storage.objects where bucket_id = 'attachments' and name = p_name;
  reset role;
  return n > 0;
end $fn$;

-- ลบในฐานะผู้ใช้ · คืนจำนวนแถวที่หายไป หรือ 'blocked' ถ้า trigger ปฏิเสธ
create or replace function pg_temp.del(p_label text, p_name text) returns text
language plpgsql as $fn$
declare n int;
begin
  perform pg_temp.as_role(p_label);
  delete from storage.objects where bucket_id = 'attachments' and name = p_name;
  get diagnostics n = row_count;
  reset role;
  return n::text;
exception when restrict_violation then
  reset role;
  return 'blocked';
end $fn$;

create or replace function pg_temp.exists_obj(p_name text) returns boolean
language sql stable as $fn$ select exists (select 1 from storage.objects where bucket_id = 'attachments' and name = p_name) $fn$;

create or replace function pg_temp.expect(p_label text, p_actual text, p_expect text) returns void
language plpgsql as $fn$
begin
  if p_actual is distinct from p_expect then
    raise exception 'FAIL: % · ได้ % แต่ต้องได้ %', p_label, coalesce(p_actual, '(null)'), p_expect;
  end if;
end $fn$;

do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated, anon', s);
  execute format('grant select on %I.t_su to authenticated, anon', s);
end $$;

-- ---------- B · bucket ----------
do $$
declare b record;
begin
  select * into b from storage.buckets where id = 'attachments';
  if b.id is null then raise exception 'FAIL: B0 ไม่มี bucket attachments'; end if;
  if b.public is distinct from false then raise exception 'FAIL: B1 bucket ต้อง private (public = %)', b.public; end if;
  if b.file_size_limit is null or b.file_size_limit > 5 * 1024 * 1024 then
    raise exception 'FAIL: B2 bucket ต้องจำกัดขนาด (ได้ %)', b.file_size_limit;
  end if;
  if b.allowed_mime_types is null or cardinality(b.allowed_mime_types) = 0 then
    raise exception 'FAIL: B3 bucket ต้องจำกัดชนิดไฟล์';
  end if;
  if b.allowed_mime_types && array['image/svg+xml', 'text/html', 'application/javascript'] then
    raise exception 'FAIL: B4 bucket รับชนิดไฟล์ที่รันสคริปต์ได้';
  end if;
  raise notice 'ok B · bucket private · จำกัดขนาด % ไบต์ · % ชนิด', b.file_size_limit, cardinality(b.allowed_mime_types);
end $$;

-- ---------- I · insert ----------
do $$
declare p text := pg_temp.pth('SRI_CORP', 'maker', 'i-main');
begin
  perform pg_temp.expect('I1 ผู้อัปโหลดชอบธรรม', pg_temp.put('maker', 'attachments', p), 'ok');
  perform pg_temp.expect('I2 เหมือนกันแต่ staff ที่ไม่ได้ owner นี้ (คนละผู้ถือ)',
    pg_temp.put('sut_staff', 'attachments', pg_temp.pth('SRI_CORP', 'sut_staff', 'i-x')), 'denied');
  perform pg_temp.expect('I3 ปลอมเป็นผู้อัปโหลดคนอื่น (path ชี้ staff2 แต่ล็อกอินเป็น maker)',
    pg_temp.put('maker', 'attachments', pg_temp.pth('SRI_CORP', 'staff2', 'i-forge')), 'denied');
  perform pg_temp.expect('I4 อัปโหลดเข้าผู้ถือที่ตัวเองไม่เห็น (maker → SUTEE)',
    pg_temp.put('maker', 'attachments', pg_temp.pth('SUTEE', 'maker', 'i-other-owner')), 'denied');
  perform pg_temp.expect('I5 ไม่ล็อกอิน (authenticated แต่ uid ว่าง)',
    pg_temp.put('__nobody__', 'attachments', pg_temp.pth('SRI_CORP', 'maker', 'i-nouid')), 'denied');
  perform pg_temp.expect('I5b ผู้ใช้ที่ไม่มีแถว app_users',
    pg_temp.put('nobody', 'attachments', pg_temp.pth('SRI_CORP', 'nobody', 'i-ghost')), 'denied');
  perform pg_temp.expect('I5c anon',
    pg_temp.put('anon', 'attachments', pg_temp.pth('SRI_CORP', 'maker', 'i-anon')), 'denied');

  -- I6 รูปแบบ path ที่ผิด — ชื่อที่ผู้ใช้ตั้งเองต้องไม่เคยเป็น path
  perform pg_temp.expect('I6a ชื่อไฟล์ตรงๆ', pg_temp.put('maker', 'attachments', 'slip.jpg'), 'denied');
  perform pg_temp.expect('I6b path traversal',
    pg_temp.put('maker', 'attachments', pg_temp.own('SRI_CORP')::text || '/../' || pg_temp.su('maker')::text || '/x.jpg'), 'denied');
  perform pg_temp.expect('I6c ../ ต้น path', pg_temp.put('maker', 'attachments', '../etc/passwd'), 'denied');
  perform pg_temp.expect('I6d ชื่อไทย',
    pg_temp.put('maker', 'attachments', pg_temp.own('SRI_CORP')::text || '/' || pg_temp.su('maker')::text || '/สลิป.jpg'), 'denied');
  perform pg_temp.expect('I6e ชื่อยาวมาก',
    pg_temp.put('maker', 'attachments', pg_temp.own('SRI_CORP')::text || '/' || pg_temp.su('maker')::text || '/' || repeat('a', 3000) || '.jpg'), 'denied');
  perform pg_temp.expect('I6f นามสกุลที่ไม่อนุญาต (.exe)', pg_temp.put('maker', 'attachments', pg_temp.pth('SRI_CORP', 'maker', 'i-exe', 'exe')), 'denied');
  perform pg_temp.expect('I6g .svg (รันสคริปต์ได้)', pg_temp.put('maker', 'attachments', pg_temp.pth('SRI_CORP', 'maker', 'i-svg', 'svg')), 'denied');
  perform pg_temp.expect('I6h ซ้อนโฟลเดอร์เกิน',
    pg_temp.put('maker', 'attachments', pg_temp.own('SRI_CORP')::text || '/' || pg_temp.su('maker')::text || '/x/' || md5('i-deep')::uuid::text || '.jpg'), 'denied');
  perform pg_temp.expect('I6i UUID ตัวพิมพ์ใหญ่ (สะกดต่างจาก auth.uid())',
    pg_temp.put('maker', 'attachments', upper(pg_temp.pth('SRI_CORP', 'maker', 'i-upper'))), 'denied');
  perform pg_temp.expect('I6j path ว่าง', pg_temp.put('maker', 'attachments', ''), 'denied');
  perform pg_temp.expect('I6k owner ไม่ใช่ uuid',
    pg_temp.put('maker', 'attachments', 'not-a-uuid/' || pg_temp.su('maker')::text || '/' || md5('i-nu')::uuid::text || '.jpg'), 'denied');
  perform pg_temp.expect('I6l null byte / newline ท้ายชื่อ',
    pg_temp.put('maker', 'attachments', pg_temp.pth('SRI_CORP', 'maker', 'i-nl') || E'\n'), 'denied');

  -- I7 bucket อื่น: ไม่มี policy ของเรา → ต้องไม่เปิดช่อง
  insert into storage.buckets(id, name, public) values ('other', 'other', false);
  perform pg_temp.expect('I7 bucket อื่น', pg_temp.put('maker', 'other', p || '.x'), 'denied');

  -- I8 เขียนทับ path เดิม = ชนกัน (unique) ไม่ใช่ทับ
  begin
    perform pg_temp.put('maker', 'attachments', p);
    raise exception 'FAIL: I8 อัปโหลดซ้ำ path เดิมต้องไม่สำเร็จ';
  exception when unique_violation then null;
  end;
  reset role;
  raise notice 'ok I · insert: ปลอมผู้อัปโหลด/ข้ามผู้ถือ/path แปลกๆ/ไม่ล็อกอิน ถูกปฏิเสธครบ';
end $$;

-- ---------- V · ใครเห็นไฟล์ ----------
-- ชุดไฟล์:
--   f_unlinked  maker อัปโหลด ยังไม่ผูกอะไร
--   f_draft     maker อัปโหลด ผูกกับร่างของ maker (pending)
--   f_txn       maker อัปโหลด ผูกกับรายการ post แล้ว (created_by = maker, ไม่ผูกทรัพย์)
--   f_asset     maker อัปโหลด ผูกกับรายการ post แล้วที่ผูกทรัพย์ของ mgr_asset
--   f_sut       sut_staff อัปโหลด เป็นของ SUTEE (ผูกร่างของ SUTEE)
do $$
begin
  perform pg_temp.put('maker', 'attachments', pg_temp.pth('SRI_CORP', 'maker', 'f_unlinked'));
  perform pg_temp.put('maker', 'attachments', pg_temp.pth('SRI_CORP', 'maker', 'f_draft'));
  perform pg_temp.put('maker', 'attachments', pg_temp.pth('SRI_CORP', 'maker', 'f_txn'));
  perform pg_temp.put('maker', 'attachments', pg_temp.pth('SRI_CORP', 'maker', 'f_asset'));
  perform pg_temp.put('sut_staff', 'attachments', pg_temp.pth('SUTEE', 'sut_staff', 'f_sut'));
  reset role;
  if (select count(*) from storage.objects where bucket_id = 'attachments') < 6 then
    raise exception 'FAIL: fixture ไฟล์ไม่ครบ — เทสต์ต่อไปจะผ่านฟรีเพราะไม่มีอะไรให้เห็น';
  end if;
end $$;

insert into sri_os.draft_entries(id, owner_id, txn_type_code, doc_date, amount, created_by, attachments)
values ('00000000-0000-0000-0000-0000000057d1', pg_temp.own('SRI_CORP'), 'inc.other', current_date, 100,
        pg_temp.su('maker'), array[pg_temp.pth('SRI_CORP', 'maker', 'f_draft')]),
       ('00000000-0000-0000-0000-0000000057d2', pg_temp.own('SUTEE'), 'inc.other', current_date, 100,
        pg_temp.su('sut_staff'), array[pg_temp.pth('SUTEE', 'sut_staff', 'f_sut')]);

insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, attachments, created_by)
values ('00000000-0000-0000-0000-0000000057e1', pg_temp.own('SRI_CORP'), 'inc.other', current_date,
        array[pg_temp.pth('SRI_CORP', 'maker', 'f_txn')], pg_temp.su('maker'));
insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, attachments, created_by, asset_id)
values ('00000000-0000-0000-0000-0000000057e2', pg_temp.own('SRI_CORP'), 'inc.other', current_date,
        array[pg_temp.pth('SRI_CORP', 'maker', 'f_asset')], pg_temp.su('maker'),
        '00000000-0000-0000-0000-0000000057a1');

do $$
declare
  f_unl text := pg_temp.pth('SRI_CORP', 'maker', 'f_unlinked');
  f_dr  text := pg_temp.pth('SRI_CORP', 'maker', 'f_draft');
  f_tx  text := pg_temp.pth('SRI_CORP', 'maker', 'f_txn');
  f_as  text := pg_temp.pth('SRI_CORP', 'maker', 'f_asset');
  f_su  text := pg_temp.pth('SUTEE', 'sut_staff', 'f_sut');
  r record;
begin
  -- V1 ผู้อัปโหลดเห็นของตัวเองทุกไฟล์
  perform pg_temp.expect('V1', (pg_temp.sees('maker', f_unl) and pg_temp.sees('maker', f_dr)
                                 and pg_temp.sees('maker', f_tx) and pg_temp.sees('maker', f_as))::text, 'true');

  -- V2 ไฟล์ที่ยังไม่ผูกรายการ: เห็นเฉพาะผู้อัปโหลด (แม้ Management ก็ไม่เห็น — ของที่ยังไม่ส่ง)
  perform pg_temp.expect('V2a staff2 (owner เดียวกัน)', pg_temp.sees('staff2', f_unl)::text, 'false');
  perform pg_temp.expect('V2b mgr',                      pg_temp.sees('mgr', f_unl)::text, 'false');
  perform pg_temp.expect('V2c mgmt',                     pg_temp.sees('mgmt', f_unl)::text, 'false');

  -- V3/V4 ข้ามผู้ถือ — ลองทุกคนที่ไม่มีสิทธิ์เห็นผู้ถือนั้น
  perform pg_temp.expect('V3a sut_staff เปิดไฟล์ SRI_CORP (ผูกร่าง)', pg_temp.sees('sut_staff', f_dr)::text, 'false');
  perform pg_temp.expect('V3b sut_mgr เปิดไฟล์ SRI_CORP (ผูกร่าง)',   pg_temp.sees('sut_mgr', f_dr)::text, 'false');
  perform pg_temp.expect('V3c sut_mgr เปิดไฟล์ SRI_CORP (ผูกรายการ)', pg_temp.sees('sut_mgr', f_tx)::text, 'false');
  perform pg_temp.expect('V3d sut_mgr เปิดไฟล์ SRI_CORP (ผูกทรัพย์)',  pg_temp.sees('sut_mgr', f_as)::text, 'false');
  perform pg_temp.expect('V4a maker เปิดไฟล์ SUTEE',  pg_temp.sees('maker', f_su)::text, 'false');
  perform pg_temp.expect('V4b mgr เปิดไฟล์ SUTEE',    pg_temp.sees('mgr', f_su)::text, 'false');
  perform pg_temp.expect('V4c mgr_asset เปิดไฟล์ SUTEE', pg_temp.sees('mgr_asset', f_su)::text, 'false');
  perform pg_temp.expect('V4d ผู้ใช้ไม่มีแถว app_users', (pg_temp.sees('nobody', f_dr) or pg_temp.sees('nobody', f_tx))::text, 'false');
  perform pg_temp.expect('V4e anon', (pg_temp.sees('anon', f_dr) or pg_temp.sees('anon', f_tx) or pg_temp.sees('anon', f_unl))::text, 'false');
  perform pg_temp.expect('V4f ไม่ล็อกอิน (uid ว่าง)', (pg_temp.sees('__nobody__', f_dr) or pg_temp.sees('__nobody__', f_tx))::text, 'false');

  -- V5 ร่าง: คนที่มี ledger.read ในผู้ถือนั้น (draft_entries_by_owner) เห็น · staff ที่ไม่ใช่เจ้าของร่างไม่เห็น
  perform pg_temp.expect('V5a mgr เห็นไฟล์ของร่าง',   pg_temp.sees('mgr', f_dr)::text, 'true');
  perform pg_temp.expect('V5b mgmt เห็นไฟล์ของร่าง',  pg_temp.sees('mgmt', f_dr)::text, 'true');
  perform pg_temp.expect('V5c staff2 ไม่เห็นไฟล์ของร่างคนอื่น', pg_temp.sees('staff2', f_dr)::text, 'false');
  perform pg_temp.expect('V5d mgmt เห็นไฟล์ SUTEE (เห็นทุกผู้ถือ)', pg_temp.sees('mgmt', f_su)::text, 'true');
  perform pg_temp.expect('V5e sut_mgr เห็นไฟล์ SUTEE', pg_temp.sees('sut_mgr', f_su)::text, 'true');

  -- V6/V7 รายการที่ post แล้ว: ขอบเขตเดียวกับ fn_can_read_txn
  perform pg_temp.expect('V6a mgmt (portfolio.view_all)', pg_temp.sees('mgmt', f_tx)::text, 'true');
  perform pg_temp.expect('V6b mgr (ledger.read แต่ไม่ใช่ของตัวเอง/ไม่ผูกทรัพย์) ต้องไม่เห็น', pg_temp.sees('mgr', f_tx)::text, 'false');
  perform pg_temp.expect('V6c staff2 (ไม่มี ledger.read) ต้องไม่เห็น', pg_temp.sees('staff2', f_tx)::text, 'false');
  perform pg_temp.expect('V7a mgr_asset เห็นไฟล์ของรายการที่ผูกทรัพย์ตัวเองดูแล', pg_temp.sees('mgr_asset', f_as)::text, 'true');
  perform pg_temp.expect('V7b mgr (ไม่ได้ดูแลทรัพย์นั้น) ต้องไม่เห็น', pg_temp.sees('mgr', f_as)::text, 'false');
  perform pg_temp.expect('V7c mgr_asset ไม่เห็นไฟล์ของรายการที่ไม่ผูกทรัพย์', pg_temp.sees('mgr_asset', f_tx)::text, 'false');

  -- V8 สมมูล: "เห็นไฟล์ที่ผูกรายการ" ⇔ "เห็นรายการ" สำหรับทุกคน (ยกเว้นผู้อัปโหลดเอง)
  for r in select label from t_su where label not in ('maker') loop
    perform set_config('test.uid', (select id::text from t_su where label = r.label), true);
    set local role authenticated;
    declare
      sees_txn boolean; sees_file boolean;
    begin
      select exists (select 1 from sri_os.transactions where id = '00000000-0000-0000-0000-0000000057e1') into sees_txn;
      select exists (select 1 from storage.objects where bucket_id = 'attachments' and name = f_tx) into sees_file;
      reset role;
      if sees_txn is distinct from sees_file then
        raise exception 'FAIL: V8 % · เห็นรายการ=% แต่เห็นไฟล์=% (ต้องเท่ากัน)', r.label, sees_txn, sees_file;
      end if;
    end;
    perform set_config('test.uid', (select id::text from t_su where label = r.label), true);
    set local role authenticated;
    declare sees_txn2 boolean; sees_file2 boolean;
    begin
      select exists (select 1 from sri_os.transactions where id = '00000000-0000-0000-0000-0000000057e2') into sees_txn2;
      select exists (select 1 from storage.objects where bucket_id = 'attachments' and name = f_as) into sees_file2;
      reset role;
      if sees_txn2 is distinct from sees_file2 then
        raise exception 'FAIL: V8b % · เห็นรายการ(ผูกทรัพย์)=% แต่เห็นไฟล์=%', r.label, sees_txn2, sees_file2;
      end if;
    end;
  end loop;
  reset role;
  raise notice 'ok V · การเห็นไฟล์: ข้ามผู้ถือไม่ได้ · ตรงกับการเห็นรายการ (7 คน × 2 รายการ) · ไฟล์ที่ยังไม่ผูกเห็นเฉพาะผู้อัปโหลด';
end $$;

-- ---------- V9-V12 โจมตี: เอา path ของคนอื่นไปแปะ ----------
do $$
declare
  f_tx text := pg_temp.pth('SRI_CORP', 'maker', 'f_txn');
  f_unl text := pg_temp.pth('SRI_CORP', 'maker', 'f_unlinked');
  f_su text := pg_temp.pth('SUTEE', 'sut_staff', 'f_sut');
  n int;
begin
  -- V9 staff2 รู้ path ของ maker (สมมุติรั่ว) แล้วสร้างร่างของตัวเองที่อ้าง path นั้น
  perform set_config('test.uid', pg_temp.su('staff2')::text, true);
  set local role authenticated;
  insert into sri_os.draft_entries(owner_id, txn_type_code, doc_date, amount, created_by, attachments)
  values (pg_temp.own('SRI_CORP'), 'inc.other', current_date, 1, pg_temp.su('staff2'), array[f_unl, f_tx]);
  select count(*) into n from storage.objects where bucket_id = 'attachments' and name in (f_unl, f_tx);
  reset role;
  if n <> 0 then raise exception 'FAIL: V10 แปะ path ของคนอื่นในร่างตัวเอง แล้วอ่านไฟล์ได้ % ไฟล์', n; end if;

  -- V11 เหมือนกัน แต่ staff2 ปลอมเป็นเจ้าของร่าง maker ไม่ได้ (policy draft_insert บังคับ created_by)
  begin
    perform set_config('test.uid', pg_temp.su('staff2')::text, true);
    set local role authenticated;
    insert into sri_os.draft_entries(owner_id, txn_type_code, doc_date, amount, created_by, attachments)
    values (pg_temp.own('SRI_CORP'), 'inc.other', current_date, 1, pg_temp.su('maker'), array[f_unl]);
    reset role;
    raise exception 'FAIL: V11 staff2 สร้างร่างโดยอ้าง created_by = maker ได้';
  exception when insufficient_privilege then reset role;
  end;

  -- V12 ผู้ใช้ SUTEE แปะ path ของ SRI_CORP ในร่างของ SUTEE → owner ใน path ไม่ตรง
  perform set_config('test.uid', pg_temp.su('sut_staff')::text, true);
  set local role authenticated;
  insert into sri_os.draft_entries(owner_id, txn_type_code, doc_date, amount, created_by, attachments)
  values (pg_temp.own('SUTEE'), 'inc.other', current_date, 1, pg_temp.su('sut_staff'), array[f_tx]);
  select count(*) into n from storage.objects where bucket_id = 'attachments' and name = f_tx;
  reset role;
  if n <> 0 then raise exception 'FAIL: V12 ข้ามผู้ถือด้วยการแปะ path ในร่างของผู้ถือตัวเอง (เห็น % ไฟล์)', n; end if;

  -- V13 กลับทิศ: maker (เห็นแค่ SRI_CORP) แปะ path ของ SUTEE ในร่าง SRI_CORP
  perform set_config('test.uid', pg_temp.su('maker')::text, true);
  set local role authenticated;
  insert into sri_os.draft_entries(owner_id, txn_type_code, doc_date, amount, created_by, attachments)
  values (pg_temp.own('SRI_CORP'), 'inc.other', current_date, 1, pg_temp.su('maker'), array[f_su]);
  select count(*) into n from storage.objects where bucket_id = 'attachments' and name = f_su;
  reset role;
  if n <> 0 then raise exception 'FAIL: V13 แปะ path ของ SUTEE ในร่าง SRI_CORP แล้วอ่านได้'; end if;

  -- V14 รายการที่ created_by ไม่ใช่ผู้อัปโหลด และไม่มีร่างต้นทาง → ลิงก์ไม่มีผลกับ mgmt
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, attachments, created_by)
  values ('00000000-0000-0000-0000-0000000057e3', pg_temp.own('SRI_CORP'), 'inc.other', current_date,
          array[pg_temp.pth('SRI_CORP', 'staff2', 'f_forged')], pg_temp.su('mgr'));
  perform pg_temp.put('staff2', 'attachments', pg_temp.pth('SRI_CORP', 'staff2', 'f_forged'));
  perform pg_temp.expect('V14a ผู้อัปโหลดเห็นไฟล์ตัวเอง', pg_temp.sees('staff2', pg_temp.pth('SRI_CORP', 'staff2', 'f_forged'))::text, 'true');
  perform pg_temp.expect('V14b รายการที่ created_by ≠ ผู้อัปโหลด ไม่ใช่ทางเปิดไฟล์ (mgmt)',
    pg_temp.sees('mgmt', pg_temp.pth('SRI_CORP', 'staff2', 'f_forged'))::text, 'false');

  -- V15 ร่างที่ถูกอนุมัติเป็นรายการ (created_by รายการ = ผู้อนุมัติ) → เปิดผ่านร่างต้นทางได้
  perform pg_temp.put('maker', 'attachments', pg_temp.pth('SRI_CORP', 'maker', 'f_posted_from_draft'));
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, attachments, created_by)
  values ('00000000-0000-0000-0000-0000000057e4', pg_temp.own('SRI_CORP'), 'inc.other', current_date,
          array[pg_temp.pth('SRI_CORP', 'maker', 'f_posted_from_draft')], pg_temp.su('mgr'));
  insert into sri_os.draft_entries(owner_id, txn_type_code, doc_date, amount, created_by, attachments, status, posted_txn_id)
  values (pg_temp.own('SRI_CORP'), 'inc.other', current_date, 1, pg_temp.su('maker'),
          array[pg_temp.pth('SRI_CORP', 'maker', 'f_posted_from_draft')], 'approved',
          '00000000-0000-0000-0000-0000000057e4');
  perform pg_temp.expect('V15 mgmt เห็นไฟล์ของรายการที่ post จากร่าง', pg_temp.sees('mgmt', pg_temp.pth('SRI_CORP', 'maker', 'f_posted_from_draft'))::text, 'true');
  raise notice 'ok V9-V15 · แปะ path ของคนอื่น / ข้ามผู้ถือ / ปลอม created_by ถูกกันได้ตามที่ออกแบบ';
end $$;

-- ---------- V16-V17 ----------
do $$
declare
  f_a text := pg_temp.pth('SRI_CORP', 'maker2', 'f_cross');
  f_own text := pg_temp.pth('SRI_CORP', 'maker', 'f_revoked');
begin
  -- V16 ผู้อัปโหลดที่ถูกถอนสิทธิ์เห็นผู้ถือนั้นแล้ว ต้องเปิดไฟล์ตัวเองไม่ได้อีก
  --     (ไม่งั้นพนักงานที่ลาออก/ย้ายงาน เก็บสิทธิ์ไว้กับไฟล์ที่เคยอัปโหลด)
  perform pg_temp.put('maker', 'attachments', f_own);
  perform pg_temp.expect('V16a ก่อนถอนสิทธิ์', pg_temp.sees('maker', f_own)::text, 'true');
  delete from sri_os.user_owner_access
   where user_id = pg_temp.su('maker') and owner_id = pg_temp.own('SRI_CORP');
  perform pg_temp.expect('V16b หลังถอนสิทธิ์เห็นผู้ถือ', pg_temp.sees('maker', f_own)::text, 'false');
  insert into sri_os.user_owner_access(user_id, owner_id) values (pg_temp.su('maker'), pg_temp.own('SRI_CORP'));

  -- V17 ไฟล์ของ SRI_CORP ที่ถูกแปะในร่างของ SUTEE (ผู้อัปโหลดเห็นทั้งสองผู้ถือ)
  --     ผู้ที่เห็นทั้งสองผู้ถือ (dual) ต้องไม่ได้สิทธิ์เปิดไฟล์นั้นผ่านร่างข้ามผู้ถือ
  --     — ลิงก์มีผลเฉพาะรายการที่ owner เดียวกับ path
  perform pg_temp.put('maker2', 'attachments', f_a);
  perform set_config('test.uid', pg_temp.su('maker2')::text, true);
  set local role authenticated;
  insert into sri_os.draft_entries(owner_id, txn_type_code, doc_date, amount, created_by, attachments)
  values (pg_temp.own('SUTEE'), 'inc.other', current_date, 1, pg_temp.su('maker2'), array[f_a]);
  reset role;
  perform pg_temp.expect('V17 dual (เห็นทั้งสองผู้ถือ) เปิดไฟล์ SRI_CORP ผ่านร่างของ SUTEE', pg_temp.sees('dual', f_a)::text, 'false');
  raise notice 'ok V16-V17 · ถอนสิทธิ์ผู้ถือแล้วไฟล์ตัวเองก็เปิดไม่ได้ · ลิงก์ข้ามผู้ถือไม่ให้สิทธิ์';
end $$;

-- ---------- U · update/ย้าย ----------
do $$
declare n int; f text := pg_temp.pth('SRI_CORP', 'maker', 'f_unlinked');
begin
  perform set_config('test.uid', pg_temp.su('maker')::text, true);
  set local role authenticated;
  update storage.objects set name = name || 'x' where bucket_id = 'attachments' and name = f;   -- ผู้อัปโหลดเอง
  get diagnostics n = row_count;
  reset role;
  if n <> 0 then raise exception 'FAIL: U1 ผู้ใช้ย้าย/เปลี่ยนชื่อไฟล์ตัวเองได้ (% แถว)', n; end if;
  perform set_config('test.uid', pg_temp.su('mgmt')::text, true);
  set local role authenticated;
  update storage.objects set metadata = '{}' where bucket_id = 'attachments';                   -- ไม่ใส่ WHERE
  get diagnostics n = row_count;
  reset role;
  if n <> 0 then raise exception 'FAIL: U1b UPDATE ทั้ง bucket (mgmt) แก้ได้ % แถว', n; end if;
  raise notice 'ok U · ไม่มี policy update: ย้าย/เขียนทับ/แก้ metadata ไม่ได้ แม้ Management';
end $$;

-- ---------- D · ลบ ----------
do $$
declare
  f_unl text := pg_temp.pth('SRI_CORP', 'maker', 'f_unlinked');
  f_dr  text := pg_temp.pth('SRI_CORP', 'maker', 'f_draft');
  f_tx  text := pg_temp.pth('SRI_CORP', 'maker', 'f_txn');
  n_before int; n_after int; n_expect int;
begin
  -- D1 ของคนอื่น (ยังไม่ผูก): ลบไม่ได้ · เห็นไม่ได้อยู่แล้วจึงเป็น 0 แถว ไม่ใช่ error
  perform pg_temp.expect('D1a staff2 ลบไฟล์ลอยของ maker', pg_temp.del('staff2', f_unl), '0');
  perform pg_temp.expect('D1b mgmt ลบไฟล์ลอยของ maker',   pg_temp.del('mgmt', f_unl), '0');
  perform pg_temp.expect('D1c ไฟล์ยังอยู่', pg_temp.exists_obj(f_unl)::text, 'true');

  -- D2/D3 ไฟล์ที่ถูกอ้าง: ผู้อัปโหลดเองก็ลบไม่ได้ (policy กรองออก → 0 แถว)
  perform pg_temp.expect('D2 maker ลบไฟล์ที่ผูกร่าง',     pg_temp.del('maker', f_dr), '0');
  perform pg_temp.expect('D3 maker ลบไฟล์ที่ผูกรายการที่ post แล้ว', pg_temp.del('maker', f_tx), '0');
  perform pg_temp.expect('D3b ไฟล์ยังอยู่', (pg_temp.exists_obj(f_dr) and pg_temp.exists_obj(f_tx))::text, 'true');

  -- D4-D6 ชั้น trigger: ผู้ที่ข้าม RLS ได้ (superuser / service_role) ก็ลบไม่ได้
  begin
    delete from storage.objects where bucket_id = 'attachments' and name = f_tx;
    raise exception 'FAIL: D4 superuser ลบไฟล์ของรายการที่ post แล้วได้';
  exception when restrict_violation then null; end;
  begin
    set local role service_role;
    delete from storage.objects where bucket_id = 'attachments' and name = f_dr;
    reset role;
    raise exception 'FAIL: D5 service_role ลบไฟล์ของร่างที่ส่งแล้วได้';
  exception when restrict_violation then reset role; end;
  begin
    delete from storage.objects where bucket_id = 'attachments';      -- ไม่ใส่ WHERE
    raise exception 'FAIL: D6 ลบทั้ง bucket ได้ทั้งที่มีไฟล์ที่ถูกอ้าง';
  exception when restrict_violation then null; end;
  perform pg_temp.expect('D6b ไม่มีไฟล์หายไปจากความพยายามข้างบน', (pg_temp.exists_obj(f_dr) and pg_temp.exists_obj(f_tx) and pg_temp.exists_obj(f_unl))::text, 'true');

  -- D6c ย้าย/เปลี่ยนชื่อไฟล์ที่ถูกอ้างด้วยสิทธิ์สูง → trigger กัน · ไฟล์ลอยย้ายได้
  begin
    update storage.objects set name = name || '.moved' where bucket_id = 'attachments' and name = f_tx;
    raise exception 'FAIL: D6c superuser เปลี่ยนชื่อไฟล์ที่ถูกอ้างได้ → ลิงก์ในรายการชี้ที่ว่าง';
  exception when restrict_violation then null; end;

  -- D7 ผู้อัปโหลดลบไฟล์ลอยของตัวเอง (แนบผิดไฟล์ในร่างที่ยังไม่ส่ง) ได้
  --    (f_unl ใช้ไม่ได้ — V9 ให้ staff2 แปะ path นี้ในร่างของตัวเองแล้ว จึง "ถูกอ้าง" ตามจริง)
  perform pg_temp.put('maker', 'attachments', pg_temp.pth('SRI_CORP', 'maker', 'f_free'));
  perform pg_temp.expect('D7 maker ลบไฟล์ลอยของตัวเอง', pg_temp.del('maker', pg_temp.pth('SRI_CORP', 'maker', 'f_free')), '1');
  perform pg_temp.expect('D7b ไฟล์หายจริง', pg_temp.exists_obj(pg_temp.pth('SRI_CORP', 'maker', 'f_free'))::text, 'false');
  perform pg_temp.expect('D7c ไฟล์ที่คนอื่นแปะ path ไว้ในร่างตัวเอง ลบไม่ได้ (ถูกอ้างแล้ว)', pg_temp.del('maker', f_unl), '0');

  -- D8 ไฟล์ลอยไม่ใช่ของตัวเอง แต่อยู่ owner เดียวกัน ลบไม่ได้ (ทดสอบกับ staff2 ที่เห็น owner เดียวกัน)
  perform pg_temp.put('maker', 'attachments', pg_temp.pth('SRI_CORP', 'maker', 'f_float2'));
  perform pg_temp.expect('D8 staff2 ลบไฟล์ลอยของ maker', pg_temp.del('staff2', pg_temp.pth('SRI_CORP', 'maker', 'f_float2')), '0');

  -- D9 ไม่ล็อกอิน/anon ลบไม่ได้
  perform pg_temp.expect('D9a anon',  pg_temp.del('anon', pg_temp.pth('SRI_CORP', 'maker', 'f_float2')), '0');
  perform pg_temp.expect('D9b uid ว่าง', pg_temp.del('__nobody__', pg_temp.pth('SRI_CORP', 'maker', 'f_float2')), '0');

  -- D10 ลบโดยไม่ใส่ WHERE ในฐานะ maker: หายเฉพาะไฟล์ลอยของตัวเอง ไฟล์ที่ถูกอ้างเหลือครบ
  select count(*) into n_before from storage.objects where bucket_id = 'attachments';
  select count(*) into n_expect from storage.objects
   where bucket_id = 'attachments' and (storage.foldername(name))[2] = pg_temp.su('maker')::text
     and not sri_os.fn_attachment_in_use(name);
  if n_expect < 2 then raise exception 'FAIL: D10 fixture: ต้องมีไฟล์ลอยของ maker อย่างน้อย 2 ไฟล์ (พบ %)', n_expect; end if;
  perform set_config('test.uid', pg_temp.su('maker')::text, true);
  set local role authenticated;
  delete from storage.objects where bucket_id = 'attachments';
  reset role;
  select count(*) into n_after from storage.objects where bucket_id = 'attachments';
  if not (pg_temp.exists_obj(f_dr) and pg_temp.exists_obj(f_tx)) then
    raise exception 'FAIL: D10 ลบทั้ง bucket ในฐานะผู้ใช้แล้วไฟล์ที่ถูกอ้างหาย';
  end if;
  if n_before - n_after <> n_expect then
    raise exception 'FAIL: D10 ควรหายเฉพาะไฟล์ลอยของ maker (% ไฟล์) แต่หาย % ไฟล์', n_expect, n_before - n_after;
  end if;

  -- D11 ร่างถูกปฏิเสธแล้วไฟล์ยังถูกอ้าง → ยังลบไม่ได้ (ประวัติ)
  update sri_os.draft_entries set status = 'rejected', reject_reason = 'test' where id = '00000000-0000-0000-0000-0000000057d1';
  perform pg_temp.expect('D11 ไฟล์ของร่างที่ถูกปฏิเสธ', pg_temp.del('maker', f_dr), '0');

  -- D12 สัญญาอ้างไฟล์ (contracts.file_urls) → ห้ามลบด้วย
  perform pg_temp.put('maker', 'attachments', pg_temp.pth('SRI_CORP', 'maker', 'f_contract'));
  insert into sri_os.contracts(id, code, owner_id, type, file_urls, status)
  values ('00000000-0000-0000-0000-0000000057c1', 'ST-C1', pg_temp.own('SRI_CORP'), 'loan_receivable',
          array[pg_temp.pth('SRI_CORP', 'maker', 'f_contract')], 'draft');
  perform pg_temp.expect('D12 ไฟล์ที่สัญญาอ้าง', pg_temp.del('maker', pg_temp.pth('SRI_CORP', 'maker', 'f_contract')), '0');
  begin
    delete from storage.objects where bucket_id = 'attachments' and name = pg_temp.pth('SRI_CORP', 'maker', 'f_contract');
    raise exception 'FAIL: D12b superuser ลบไฟล์ที่สัญญาอ้างได้';
  exception when restrict_violation then null; end;
  raise notice 'ok D · ลบ: ไฟล์ลอยของตัวเองลบได้ · ไฟล์ที่รายการ/ร่าง/สัญญาอ้างลบไม่ได้ทุกชั้น (policy + trigger รวม service_role)';
end $$;

-- ---------- O · ไฟล์ลอย ----------
do $$
declare
  f_old  text := pg_temp.pth('SRI_CORP', 'maker', 'f_old_orphan');
  f_new  text := pg_temp.pth('SRI_CORP', 'maker', 'f_new_orphan');
  f_oldl text := pg_temp.pth('SRI_CORP', 'maker', 'f_old_linked');
  n int;
begin
  perform pg_temp.put('maker', 'attachments', f_old);
  perform pg_temp.put('maker', 'attachments', f_new);
  perform pg_temp.put('maker', 'attachments', f_oldl);
  insert into sri_os.draft_entries(owner_id, txn_type_code, doc_date, amount, created_by, attachments)
  values (pg_temp.own('SRI_CORP'), 'inc.other', current_date, 1, pg_temp.su('maker'), array[f_oldl]);
  update storage.objects set created_at = now() - interval '3 days' where name in (f_old, f_oldl);

  perform set_config('test.uid', pg_temp.su('maker')::text, true);
  set local role authenticated;
  select count(*) into n from sri_os.fn_attachment_orphans('mine') where path = f_old;
  if n <> 1 then raise exception 'FAIL: O1 ไฟล์ลอยเก่าไม่ถูกรายงาน (%)', n; end if;
  select count(*) into n from sri_os.fn_attachment_orphans('mine') where path in (f_new, f_oldl);
  if n <> 0 then raise exception 'FAIL: O2 รายงานไฟล์ที่ยังอยู่ในช่วงผ่อนผัน/ไฟล์ที่ถูกอ้างเป็นไฟล์ลอย (%)', n; end if;
  reset role;

  perform set_config('test.uid', pg_temp.su('staff2')::text, true);
  set local role authenticated;
  select count(*) into n from sri_os.fn_attachment_orphans('mine');
  if n <> 0 then raise exception 'FAIL: O3 staff2 เห็นไฟล์ลอยของคนอื่นใน mine (%)', n; end if;
  begin
    perform * from sri_os.fn_attachment_orphans('all');
    raise exception 'FAIL: O4 staff2 ขอรายงาน all ได้';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  begin
    perform * from sri_os.fn_attachment_orphans('whatever');
    raise exception 'FAIL: O5 scope แปลกๆ ผ่าน';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  reset role;

  perform set_config('test.uid', pg_temp.su('mgmt')::text, true);
  set local role authenticated;
  select count(*) into n from sri_os.fn_attachment_orphans('all') where path = f_old;
  if n <> 1 then raise exception 'FAIL: O6 mgmt ไม่เห็นไฟล์ลอยใน all (%)', n; end if;
  -- รายงานให้แค่ metadata: เปิดไฟล์ไม่ได้
  if exists (select 1 from storage.objects where name = f_old) then
    raise exception 'FAIL: O7 รายงานไฟล์ลอยกลายเป็นช่องเปิดไฟล์ที่ยังไม่ส่ง';
  end if;
  reset role;

  -- O8 anon เรียกฟังก์ชันไม่ได้
  begin
    set local role anon;
    perform * from sri_os.fn_attachment_orphans('mine');
    reset role;
    raise exception 'FAIL: O8 anon เรียก fn_attachment_orphans ได้';
  exception when insufficient_privilege then reset role; end;
  begin
    set local role anon;
    perform sri_os.fn_attachment_in_use('x');
    reset role;
    raise exception 'FAIL: O9 anon เรียก fn_attachment_in_use ได้';
  exception when insufficient_privilege then reset role; end;
  -- O10 trigger function เรียกตรงไม่ได้
  begin
    set local role authenticated;
    perform sri_os.fn_guard_attachment_objects();
    reset role;
    raise exception 'FAIL: O10 authenticated เรียก trigger function ตรงได้';
  exception when insufficient_privilege then reset role; end;

  -- O11 เมื่อผู้อัปโหลดกวาดของตัวเอง (ตามรายงาน) → หาย 1 ไฟล์ ไฟล์ที่ถูกอ้างอยู่ครบ
  perform pg_temp.expect('O11 กวาดไฟล์ลอยเก่า', pg_temp.del('maker', f_old), '1');
  perform pg_temp.expect('O11b ไฟล์ที่ถูกอ้างยังอยู่', pg_temp.exists_obj(f_oldl)::text, 'true');
  raise notice 'ok O · ไฟล์ลอย: รายงานเฉพาะที่ไม่มีใครอ้าง+พ้นช่วงผ่อนผัน · เห็นของตัวเอง/management เห็นทั้งหมดแบบ metadata · กวาดแล้วของที่ถูกอ้างไม่หาย';
end $$;

-- ---------- E · สภาพ policy ----------
do $$
declare n int;
begin
  select count(*) into n from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'attachments\_%';
  if n <> 3 then raise exception 'FAIL: E1 ต้องมี policy 3 ตัว (insert/select/delete) พบ %', n; end if;
  select count(*) into n from pg_policies
   where schemaname = 'storage' and tablename = 'objects' and policyname like 'attachments\_%'
     and ('anon' = any(roles) or 'public' = any(roles));
  if n <> 0 then raise exception 'FAIL: E2 policy ของ attachments เปิดให้ anon/public'; end if;
  select count(*) into n from pg_trigger where tgrelid = 'storage.objects'::regclass and tgname like 'trg_guard_attachment%' and not tgisinternal;
  if n <> 2 then raise exception 'FAIL: E3 trigger กันลบ/ย้ายต้องมี 2 ตัว พบ %', n; end if;
  raise notice 'ok E · policy 3 ตัวให้เฉพาะ authenticated · trigger กัน 2 ตัว';
end $$;

rollback;
