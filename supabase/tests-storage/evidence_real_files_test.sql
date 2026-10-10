-- ============================================================
-- SRI OS · เทสต์ D-095 — corporate_strict ต้องมี "ไฟล์จริงใน Storage" เป็นหลักฐาน
--   ทดสอบ: supabase/migrations/20261010000000_evidence_real_files.sql
--   รัน:   bash scripts/test-storage-local.sh   (harness นี้เท่านั้น — ต้องมี storage.objects จริง)
--
-- กติกาที่พิสูจน์ที่นี่: ไฟล์แนบนับเป็นหลักฐานได้ต้องครบ **สามข้อ**
--   1. รูปแบบ path ถูกตามนิยาม  <owner_id>/<uploader_id>/<uuid>.<ext>
--   2. ส่วน owner ของ path = transactions.owner_id  (ยืมไฟล์ผู้ถืออื่นมาอ้างไม่ได้)
--   3. มีแถวจริงใน storage.objects ใน bucket 'attachments'
--
-- ไล่ "ถอดการแก้ออกแล้วต้องแดง" (mutation ที่ต้องถูกจับได้):
--   Q1 ถอดการเช็ค storage.objects (เหลือแค่รูปแบบ path)   → A4 · A5b · X3
--   Q2 ถอดการเช็ค owner ใน path = new.owner_id            → A5 · S3 · X4
--   Q3 "ไม่มีสคีมา storage" = ผ่าน                          → Z1  (ทดสอบด้วยการ drop schema จริง)
--   Q4 กลับไปนับ cardinality(attachments) (บั๊ก D-095)     → A3 · A4 · A5 · S1 · X5
--
-- หมายเหตุลำดับ migration ของ harness: scripts/test-storage-local.sh รัน UNDER_TEST
--   (ซึ่งมี 20261007000000 ที่ create or replace fn_corporate_requires_evidence ตัวเก่า)
--   **ทับ** 20261010000000 ทีหลัง · ด่านที่ยืนยันกติกาตรงนี้จึงเป็น
--   trg_corporate_evidence_real_files ที่ไฟล์เก่าไม่รู้จัก (X6) — ดูหัวไฟล์ migration
--   Q5 ข้อยกเว้นใบกลับรายการครอบทุกใบ ไม่ใช่แค่ที่พิสูจน์ได้  → R3 · R3b · R3c · R5
--      (ถามฟังก์ชันตัดสินตรงๆ — ข้อยกเว้นต้องแน่นด้วยตัวเอง ไม่พึ่งว่า trigger อีกตัวดักให้)
--
-- เคส "ข้อมูลขาด" (บทเรียนข้อ 3): attachments ว่าง · มี null · สตริงว่าง · ' ' · path ที่มี '..' ·
--   owner ใน path เป็น uuid ที่ไม่มีผู้ถือ · ไฟล์อยู่ bucket อื่น · uuid ตัวพิมพ์ใหญ่ · นามสกุลนอกรายการ
-- ============================================================
begin;

-- ---------- fixtures ----------
create temporary table t_u (label text primary key, id uuid not null default gen_random_uuid());
insert into t_u(label) values ('maker'), ('other_up');
insert into auth.users(id) select id from t_u;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select id, label || '@ev.local', label, 'staff', true from t_u;

create or replace function pg_temp.su(p_label text) returns uuid
language sql stable as $fn$ select id from t_u where label = p_label $fn$;
create or replace function pg_temp.own(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.owners where code = p_code $fn$;

-- path ตามรูปแบบจริง · tag เดียวกัน = path เดียวกัน (เทียบ/ใช้ซ้ำได้)
create or replace function pg_temp.pth(p_owner text, p_uploader text, p_tag text, p_ext text default 'jpg')
returns text language sql stable as $fn$
  select pg_temp.own(p_owner)::text || '/' || pg_temp.su(p_uploader)::text || '/'
      || md5(p_tag)::uuid::text || '.' || p_ext
$fn$;

-- อัปโหลดจริง (ในฐานะ postgres — เทสต์นี้พิสูจน์กติกาหลักฐาน ไม่ใช่ policy ของ bucket)
create or replace function pg_temp.putobj(p_name text, p_bucket text default 'attachments')
returns void language plpgsql as $fn$
begin
  insert into storage.buckets(id, name, public) values (p_bucket, p_bucket, false)
  on conflict (id) do nothing;
  insert into storage.objects(bucket_id, name, metadata) values (p_bucket, p_name, '{"size": 100}');
end $fn$;

-- ลงรายการ → 'ok' · 'denied' (ถูกปฏิเสธเพราะเรื่องหลักฐาน) · 'error · ...' (ปฏิเสธด้วยเหตุอื่น = ไม่นับ)
create or replace function pg_temp.ins(
  p_owner text, p_att text[],
  p_source text default 'manual', p_reverses uuid default null, p_contact uuid default null
) returns text language plpgsql as $fn$
begin
  insert into sri_os.transactions(owner_id, txn_type_code, doc_date, attachments, created_by, source, reverses_id, contact_id)
  values (pg_temp.own(p_owner), 'inc.other', current_date, coalesce(p_att, '{}'), pg_temp.su('maker'),
          p_source::sri_os.txn_source, p_reverses, p_contact);
  return 'ok';
exception when others then
  if sqlerrm like '%หลักฐาน%' then return 'denied'; end if;
  return 'error · ' || left(sqlerrm, 90);
end $fn$;

create or replace function pg_temp.expect(p_label text, p_actual text, p_expect text) returns void
language plpgsql as $fn$
begin
  if p_actual is distinct from p_expect then
    raise exception 'FAIL: % · ได้ % แต่ต้องได้ %', p_label, coalesce(p_actual, '(null)'), p_expect;
  end if;
end $fn$;

-- ไฟล์จริงของ SRI_CORP (ผ่านครบสามข้อ) · ไฟล์จริงของ SUTEE (ใช้ทดสอบข้อ 2)
do $$
begin
  perform pg_temp.putobj(pg_temp.pth('SRI_CORP', 'maker', 'real1'));
  perform pg_temp.putobj(pg_temp.pth('SRI_CORP', 'maker', 'real2'));
  perform pg_temp.putobj(pg_temp.pth('SUTEE', 'other_up', 'sutee1'));
  perform pg_temp.putobj(pg_temp.pth('SRI_CORP', 'maker', 'wrongbucket'), 'other');
  if (select count(*) from storage.objects where bucket_id = 'attachments') < 3 then
    raise exception 'FAIL: fixture ไฟล์ไม่ครบ — เคสที่ต้อง "ผ่าน" จะผ่านฟรีไม่ได้';
  end if;
end $$;

-- ---------- A · กติกาหลักของ D-095 ----------
do $$
declare
  real1 text := pg_temp.pth('SRI_CORP', 'maker', 'real1');
  real2 text := pg_temp.pth('SRI_CORP', 'maker', 'real2');
  sutee text := pg_temp.pth('SUTEE', 'other_up', 'sutee1');
begin
  -- A1/A2 ไม่มีไฟล์แนบเลย (เคสเดิมของ corporate_strict ต้องยังปฏิเสธ)
  perform pg_temp.expect('A1 นิติบุคคล + attachments ว่าง',  pg_temp.ins('SRI_CORP', '{}'), 'denied');
  perform pg_temp.expect('A2 นิติบุคคล + attachments null', pg_temp.ins('SRI_CORP', null), 'denied');

  -- A3 **เคสของ D-095 ตรงๆ** — ชื่อไฟล์ที่ผู้ใช้พิมพ์เอง ไม่ใช่ path ของไฟล์จริง
  perform pg_temp.expect('A3 นิติบุคคล + ชื่อไฟล์ที่พิมพ์เอง', pg_temp.ins('SRI_CORP', array['สลิป.jpg']), 'denied');
  perform pg_temp.expect('A3b ชื่อไฟล์ฝรั่ง',                  pg_temp.ins('SRI_CORP', array['slip.pdf']), 'denied');
  perform pg_temp.expect('A3c ชื่อหลายไฟล์แต่ปลอมหมด',
    pg_temp.ins('SRI_CORP', array['สลิป.jpg', 'ใบเสร็จ.pdf', 'สัญญา.pdf']), 'denied');

  -- A4 รูปแบบ path ถูก แต่ไม่มีแถวใน storage.objects (ยังไม่ได้อัปโหลด / อัปโหลดล้ม)
  perform pg_temp.expect('A4 path ถูกแต่ไม่มีไฟล์จริง',
    pg_temp.ins('SRI_CORP', array[pg_temp.pth('SRI_CORP', 'maker', 'ghost')]), 'denied');

  -- A5 path ของ **ผู้ถืออื่น** ที่มีไฟล์จริง → ยืมมาอ้างเป็นหลักฐานของตัวเองไม่ได้
  perform pg_temp.expect('A5 ไฟล์จริงของผู้ถืออื่น', pg_temp.ins('SRI_CORP', array[sutee]), 'denied');
  perform pg_temp.expect('A5b owner ใน path เป็น uuid ที่ไม่มีผู้ถือ',
    pg_temp.ins('SRI_CORP', array['11111111-1111-4111-8111-111111111111/'
      || pg_temp.su('maker')::text || '/' || md5('nobodyowner')::uuid::text || '.jpg']), 'denied');

  -- A6 ครบสามข้อ → ผ่าน
  perform pg_temp.expect('A6 path ถูก + ไฟล์จริง + owner ตรง', pg_temp.ins('SRI_CORP', array[real1]), 'ok');
  perform pg_temp.expect('A6b หลายไฟล์จริง',                    pg_temp.ins('SRI_CORP', array[real1, real2]), 'ok');

  -- A7 ปนของจริงกับของปลอม → นับแค่ของจริง (มี 1 ไฟล์จริงก็พอ)
  perform pg_temp.expect('A7 ปนของปลอม', pg_temp.ins('SRI_CORP', array['สลิป.jpg', real1, sutee]), 'ok');

  -- A8 ผู้ถือที่เป็นบุคคล — นโยบายไม่เปลี่ยน
  perform pg_temp.expect('A8 personal_flexible + ไม่มีไฟล์แนบ', pg_temp.ins('SUTEE', '{}'), 'ok');
  perform pg_temp.expect('A8b personal_flexible + ชื่อไฟล์ปลอม', pg_temp.ins('SUTEE', array['สลิป.jpg']), 'ok');

  raise notice 'ok A · ชื่อไฟล์ที่พิมพ์เอง / path ที่ไม่มีไฟล์ / ไฟล์ของผู้ถืออื่น = ไม่ใช่หลักฐาน · บุคคลไม่เปลี่ยน';
end $$;

-- ---------- F · ข้อมูลขาด-ข้อมูลแปลก (ทุกตัวต้องปฏิเสธ ไม่ใช่ปล่อยผ่าน/ระเบิด) ----------
do $$
declare real1 text := pg_temp.pth('SRI_CORP', 'maker', 'real1');
begin
  perform pg_temp.expect('F1 null ในอาร์เรย์',        pg_temp.ins('SRI_CORP', array[null]::text[]), 'denied');
  perform pg_temp.expect('F1b null ปนกับชื่อปลอม',   pg_temp.ins('SRI_CORP', array[null, 'สลิป.jpg']::text[]), 'denied');
  perform pg_temp.expect('F2 สตริงว่าง',              pg_temp.ins('SRI_CORP', array['']), 'denied');
  perform pg_temp.expect('F2b ช่องว่าง',              pg_temp.ins('SRI_CORP', array['   ']), 'denied');
  perform pg_temp.expect('F3 path ที่มี ..',
    pg_temp.ins('SRI_CORP', array[pg_temp.own('SRI_CORP')::text || '/../' || pg_temp.su('maker')::text || '/x.jpg']), 'denied');
  perform pg_temp.expect('F3b ../ ต้น path',          pg_temp.ins('SRI_CORP', array['../etc/passwd']), 'denied');
  perform pg_temp.expect('F3c path ของไฟล์จริงแต่เติม ..',
    pg_temp.ins('SRI_CORP', array[real1 || '/../' || real1]), 'denied');
  perform pg_temp.expect('F4 uuid ตัวพิมพ์ใหญ่ (สะกดต่างจากของจริง)', pg_temp.ins('SRI_CORP', array[upper(real1)]), 'denied');
  perform pg_temp.expect('F5 ขึ้นต้นด้วยชื่อ bucket',  pg_temp.ins('SRI_CORP', array['attachments/' || real1]), 'denied');
  perform pg_temp.expect('F6 เติมช่องว่างท้าย path',   pg_temp.ins('SRI_CORP', array[real1 || ' ']), 'denied');
  perform pg_temp.expect('F6b เติมบรรทัดใหม่ท้าย path', pg_temp.ins('SRI_CORP', array[real1 || E'\n']), 'denied');
  perform pg_temp.expect('F7 ไฟล์จริงแต่อยู่ bucket อื่น',
    pg_temp.ins('SRI_CORP', array[pg_temp.pth('SRI_CORP', 'maker', 'wrongbucket')]), 'denied');
  -- F8 มีไฟล์จริงใน bucket แต่นามสกุลไม่อยู่ในรายการที่รับ → ไม่ใช่หลักฐาน
  perform pg_temp.putobj(pg_temp.pth('SRI_CORP', 'maker', 'exe1', 'exe'));
  perform pg_temp.expect('F8 นามสกุลนอกรายการ (.exe) ที่มีไฟล์จริง',
    pg_temp.ins('SRI_CORP', array[pg_temp.pth('SRI_CORP', 'maker', 'exe1', 'exe')]), 'denied');
  raise notice 'ok F · ข้อมูลขาด/ปลอม/สะกดเพี้ยน ทุกแบบถูกปฏิเสธ';
end $$;

-- ---------- S · นับซ้ำไม่ได้ · นับแค่ของจริง ----------
do $$
declare
  real1 text := pg_temp.pth('SRI_CORP', 'maker', 'real1');
  real2 text := pg_temp.pth('SRI_CORP', 'maker', 'real2');
  corp  uuid := pg_temp.own('SRI_CORP');
begin
  perform pg_temp.expect('S1 ชื่อปลอมสามตัว → 0',
    sri_os.fn_real_evidence_count(corp, array['สลิป.jpg', 'a.pdf', 'b.png'])::text, '0');
  perform pg_temp.expect('S2 path เดียวกันสองช่อง → 1',
    sri_os.fn_real_evidence_count(corp, array[real1, real1])::text, '1');
  perform pg_temp.expect('S2b สองไฟล์จริงต่างกัน → 2',
    sri_os.fn_real_evidence_count(corp, array[real1, real2])::text, '2');
  perform pg_temp.expect('S3 ปนของจริง 1 + ของปลอม 3 → 1',
    sri_os.fn_real_evidence_count(corp, array['สลิป.jpg', real1, pg_temp.pth('SRI_CORP', 'maker', 'ghost'),
      pg_temp.pth('SUTEE', 'other_up', 'sutee1')])::text, '1');
  perform pg_temp.expect('S4 attachments null → 0', sri_os.fn_real_evidence_count(corp, null)::text, '0');
  perform pg_temp.expect('S5 owner null → 0', sri_os.fn_real_evidence_count(null, array[real1])::text, '0');
  perform pg_temp.expect('S6 รายชื่อไฟล์ที่นับได้ = ของจริงเท่านั้น',
    (select string_agg(r, ',' order by r) from sri_os.fn_real_evidence_refs(corp, array[real1, real1, 'สลิป.jpg']) r),
    real1);
  raise notice 'ok S · นับแค่ไฟล์จริงของผู้ถือนั้น · path ซ้ำนับเป็นหนึ่ง';
end $$;

-- ---------- R · ข้อยกเว้นใบกลับรายการ (ของเดิมต้องไม่หาย และต้องไม่กว้างขึ้น) ----------
do $$
declare
  real1 text := pg_temp.pth('SRI_CORP', 'maker', 'real1');
  corp  uuid := pg_temp.own('SRI_CORP');
  v_orig uuid;
  v_orig2 uuid;
  v_other uuid;
begin
  -- ต้นฉบับสองใบ: มีหลักฐานจริงตามกติกา (ใบที่สองไว้ทดสอบระดับฟังก์ชัน
  -- เพราะ fn_reverse_link_ok ยอมให้ต้นฉบับหนึ่งใบมีใบกลับรายการที่ยังไม่ void ได้ใบเดียว)
  insert into sri_os.transactions(owner_id, txn_type_code, doc_date, attachments, created_by)
  values (corp, 'inc.other', current_date, array[real1], pg_temp.su('maker'))
  returning id into v_orig;
  insert into sri_os.transactions(owner_id, txn_type_code, doc_date, attachments, created_by)
  values (corp, 'inc.other', current_date, array[real1], pg_temp.su('maker'))
  returning id into v_orig2;
  insert into sri_os.transactions(owner_id, txn_type_code, doc_date, created_by)
  values (pg_temp.own('SUTEE'), 'inc.other', current_date, pg_temp.su('maker'))
  returning id into v_other;

  -- R1 ใบกลับรายการที่พิสูจน์ได้ + ไม่มีไฟล์แนบ → ยังผ่าน (หลักฐานของมันคือใบต้นฉบับ)
  perform pg_temp.expect('R1 reverse ที่พิสูจน์ได้ + ไม่มีไฟล์แนบ',
    pg_temp.ins('SRI_CORP', '{}', 'reverse', v_orig), 'ok');

  -- R2 อ้างว่า reverse แต่ไม่มี reverses_id → ด่าน trg_assert_reverse_link ปฏิเสธก่อน (ไม่ใช่เรื่องหลักฐาน)
  perform pg_temp.expect('R2 reverse ที่ไม่มี reverses_id ถูกปฏิเสธที่ด่านลิงก์',
    left(pg_temp.ins('SRI_CORP', '{}', 'reverse', null), 7), 'error ·');

  -- R3-R5 ข้อยกเว้นต้องแน่น **ด้วยตัวเอง** ไม่ใช่เพราะ trigger อีกตัวดักให้
  --   (ถ้ายกเว้นทุกใบที่เขียนว่า 'reverse' = ทางลัดข้ามกติกานิติบุคคล — mutation Q5)
  --   ทดสอบที่ฟังก์ชันตัดสินตรงๆ เพราะปิด trg_assert_reverse_link กลางธุรกรรมไม่ได้
  --   (ALTER TABLE ติด pending trigger events ของ constraint trigger ที่เลื่อนไว้)
  perform pg_temp.expect('R3 reverse ที่ไม่มี reverses_id → ไม่ยกเว้น',
    sri_os.fn_corporate_evidence_ok(gen_random_uuid(), corp, 'reverse', null, '{}')::text, 'false');
  perform pg_temp.expect('R3b reverse ชี้ไปรายการของผู้ถืออื่น → ไม่ยกเว้น',
    sri_os.fn_corporate_evidence_ok(gen_random_uuid(), corp, 'reverse', v_other, '{}')::text, 'false');
  perform pg_temp.expect('R3c reverse ชี้ไปรายการที่ไม่มีอยู่ → ไม่ยกเว้น',
    sri_os.fn_corporate_evidence_ok(gen_random_uuid(), corp, 'reverse', gen_random_uuid(), '{}')::text, 'false');
  perform pg_temp.expect('R4 reverse ที่พิสูจน์ได้ → ยกเว้น (ข้อยกเว้นเดิมต้องไม่หาย)',
    sri_os.fn_corporate_evidence_ok(gen_random_uuid(), corp, 'reverse', v_orig2, '{}')::text, 'true');
  perform pg_temp.expect('R5 ลิงก์ถูกแต่ source ไม่ใช่ reverse → ไม่ยกเว้น',
    sri_os.fn_corporate_evidence_ok(gen_random_uuid(), corp, 'manual', v_orig2, '{}')::text, 'false');

  raise notice 'ok R · ข้อยกเว้นเดิมของใบกลับรายการยังอยู่ · และครอบแค่ใบที่พิสูจน์ได้';
end $$;

-- ---------- U · แก้รายการที่ลงแล้วให้หลักฐานหายไปไม่ได้ ----------
do $$
declare
  real1 text := pg_temp.pth('SRI_CORP', 'maker', 'real1');
  v_id uuid;
  v_msg text;
begin
  insert into sri_os.transactions(owner_id, txn_type_code, doc_date, attachments, created_by)
  values (pg_temp.own('SRI_CORP'), 'inc.other', current_date, array[real1], pg_temp.su('maker'))
  returning id into v_id;

  begin
    update sri_os.transactions set attachments = '{}' where id = v_id;
    raise exception 'FAIL: U1 ลบหลักฐานออกจากรายการนิติบุคคลด้วย UPDATE ได้';
  exception when others then
    v_msg := sqlerrm;
    if v_msg like 'FAIL:%' then raise; end if;
    if v_msg not like '%หลักฐาน%' then raise exception 'FAIL: U1 ถูกปฏิเสธด้วยเหตุอื่น: %', v_msg; end if;
  end;

  begin
    update sri_os.transactions set attachments = array['สลิป.jpg'] where id = v_id;
    raise exception 'FAIL: U2 เปลี่ยนหลักฐานเป็นชื่อไฟล์ที่พิมพ์เองได้';
  exception when others then
    v_msg := sqlerrm;
    if v_msg like 'FAIL:%' then raise; end if;
    if v_msg not like '%หลักฐาน%' then raise exception 'FAIL: U2 ถูกปฏิเสธด้วยเหตุอื่น: %', v_msg; end if;
  end;
  raise notice 'ok U · UPDATE ก็ถูกบังคับเท่ากับ INSERT';
end $$;

-- ---------- X · ไม่มีกฎรูปแบบ path สองชุด (ต้องตรงกับ policy ของ 20261008000009) ----------
do $$
declare
  v_re text := sri_os.fn_attachment_path_re();
  v_pol text;
  n int;
begin
  select coalesce(with_check, '') into v_pol from pg_policies
   where schemaname = 'storage' and tablename = 'objects' and policyname = 'attachments_insert';
  if v_pol is null or v_pol = '' then
    raise exception 'FAIL: X1 ไม่พบ policy attachments_insert — เทียบกฎรูปแบบ path ไม่ได้ (ตรวจไม่ได้ = ไม่ผ่าน)';
  end if;
  if position(v_re in v_pol) = 0 then
    raise exception 'FAIL: X2 กฎรูปแบบ path ของกติกาหลักฐานไม่ตรงกับ policy ของ bucket · evidence=% · policy=%',
      v_re, left(v_pol, 300);
  end if;

  -- X2b bucket ที่ถามหาไฟล์ ต้องเป็น bucket เดียวกับที่ policy คุม
  if position('''attachments''' in v_pol) = 0 then
    raise exception 'FAIL: X2b policy ไม่ได้คุม bucket attachments — ชื่อ bucket อาจเพี้ยนจากกติกาหลักฐาน';
  end if;

  -- X3/X4 โครงสร้างของกติกา: ต้องถาม storage.objects และต้องเทียบ owner ใน path
  if (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'sri_os' and p.proname = 'fn_real_evidence_refs') not like '%storage.objects%' then
    raise exception 'FAIL: X3 กติกาหลักฐานไม่ได้ถาม storage.objects (D-095 กลับมา)';
  end if;
  if (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'sri_os' and p.proname = 'fn_real_evidence_refs') not like '%p_owner%' then
    raise exception 'FAIL: X4 กติกาหลักฐานไม่ได้เทียบ owner ใน path กับผู้ถือของรายการ';
  end if;
  -- X5 การตัดสินต้องอยู่ที่ฟังก์ชันเดียว และต้องไปจบที่การนับไฟล์จริง
  if (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'sri_os' and p.proname = 'fn_corporate_evidence_ok') not like '%fn_real_evidence_count%' then
    raise exception 'FAIL: X5 fn_corporate_evidence_ok ไม่ได้นับไฟล์จริง (บั๊กเดิมของ D-095)';
  end if;
  -- X6 ด่านที่ไฟล์เก่า replay ทับไม่ได้ ต้องยังอยู่ — harness รัน 20261007000000 ทับทีหลังจริง
  select count(*) into n from pg_trigger t
   where t.tgrelid = 'sri_os.transactions'::regclass and not t.tgisinternal
     and t.tgname = 'trg_corporate_evidence_real_files';
  if n <> 1 then raise exception 'FAIL: X6 ไม่พบ trigger trg_corporate_evidence_real_files (พบ %)', n; end if;
  raise notice 'ok X · กฎรูปแบบ path ชุดเดียวกับ policy · ด่านถาม storage.objects จริง · ด่านที่ replay ทับไม่ได้ยังอยู่';
end $$;

-- ---------- Z · ตรวจไม่ได้ = ปฏิเสธ (ห้ามผ่านเงียบๆ) ----------
-- ด่านที่เงียบเมื่อตรวจไม่ได้ = ด่านที่ไม่มีอยู่ · ที่นี่ drop สคีมา storage จริงแล้วลองลงรายการ
do $$
declare real1 text := pg_temp.pth('SRI_CORP', 'maker', 'real1');
begin
  -- ยืนยันก่อนว่าเคสนี้ "ผ่าน" ตอน storage ยังอยู่ → Z1 จึงไม่ใช่การผ่าน/ไม่ผ่านด้วยเหตุอื่น
  perform pg_temp.expect('Z0 ก่อน drop storage: ไฟล์จริงผ่าน', pg_temp.ins('SRI_CORP', array[real1]), 'ok');
end $$;

savepoint before_drop_storage;
drop schema storage cascade;
do $$
declare real1 text := pg_temp.pth('SRI_CORP', 'maker', 'real1');
begin
  if to_regclass('storage.objects') is not null then
    raise exception 'FAIL: Z1 drop สคีมา storage ไม่สำเร็จ — เคสนี้จะผ่านฟรี';
  end if;
  perform pg_temp.expect('Z1 ไม่มีสคีมา storage + path ที่เคยเป็นไฟล์จริง → ต้องปฏิเสธ',
    pg_temp.ins('SRI_CORP', array[real1]), 'denied');
  perform pg_temp.expect('Z1b ไม่มีสคีมา storage + ไม่มีไฟล์แนบ → ปฏิเสธ', pg_temp.ins('SRI_CORP', '{}'), 'denied');
  perform pg_temp.expect('Z1c ไม่มีสคีมา storage + ผู้ถือบุคคล → ยังผ่าน (นโยบายไม่เปลี่ยน)',
    pg_temp.ins('SUTEE', '{}'), 'ok');
  raise notice 'ok Z · ตรวจไม่ได้ = ปฏิเสธ';
end $$;
rollback to savepoint before_drop_storage;

do $$
begin
  if to_regclass('storage.objects') is null then raise exception 'FAIL: Z2 คืนสภาพ storage ไม่ได้'; end if;
  raise notice 'ok ทั้งไฟล์ · D-095 ปิดแล้ว (หลักฐาน = ไฟล์จริงของผู้ถือนั้นใน bucket attachments)';
end $$;

rollback;
