-- ============================================================
-- SRI OS · ปิด D-095 — corporate_strict ต้องมี "ไฟล์จริงใน Storage" ไม่ใช่ชื่อไฟล์ที่พิมพ์เอง
--   เทสต์: supabase/tests-storage/evidence_real_files_test.sql
--   รัน:   bash scripts/test-storage-local.sh   (ต้องมีสคีมา storage จริง — ดูหมายเหตุ harness)
--
-- ------------------------------------------------------------
-- ปัญหาที่ปิด (D-095)
-- ------------------------------------------------------------
--   fn_corporate_requires_evidence เช็คแค่ `cardinality(new.attachments) = 0`
--   (สร้างที่ 20260917000002 · แทนที่ที่ 20261007000000)
--   → นิติบุคคลพิมพ์ 'สลิป.jpg' ที่ไม่มีไฟล์จริงอยู่เบื้องหลังก็ผ่าน
--   กติกาที่ CLAUDE.md เขียนว่า **ห้าม override** จึงกลายเป็นของที่ตรวจของปลอมได้
--
-- ------------------------------------------------------------
-- กติกาใหม่ · ไฟล์แนบนับเป็นหลักฐานได้ต้องครบ **สามข้อ**
-- ------------------------------------------------------------
--   1. รูปแบบ path ถูกตามนิยาม  <owner_id>/<uploader_id>/<uuid>.<ext>
--      (กฎเดียวกับ regex ใน policy ของ 20261008000009 และ src/lib/storage/path.ts
--       — ที่นี่เขียนเป็นฟังก์ชัน fn_attachment_path_re() ให้เทสต์เทียบสองฝั่งได้
--       ไม่ใช่กฎชุดที่สองที่เพี้ยนจากกันเงียบๆ)
--   2. ส่วน <owner_id> ของ path = transactions.owner_id ของแถวนั้น
--      → ยืมไฟล์ของผู้ถืออื่นมาอ้างเป็นหลักฐานของตัวเองไม่ได้
--   3. มีแถวจริงใน storage.objects ที่ name ตรงกับ path และอยู่ใน bucket 'attachments'
--   นับซ้ำไม่ได้: path เดียวกันสองช่อง = 1 ไฟล์ (distinct)
--
--   corporate_strict ต้องมีไฟล์ที่ผ่านสามข้อ **อย่างน้อย 1 ไฟล์**
--   ข้อยกเว้นเดิมของ **ใบกลับรายการที่พิสูจน์ได้** (fn_reverse_link_ok) **คงไว้ทั้งดุ้น**
--   (หลักฐานของใบกลับรายการคือใบต้นฉบับซึ่งมีหลักฐานอยู่แล้ว) · เงื่อนไขอ่านจาก
--   fn_reverse_link_ok เสมอ **ไม่เชื่อคำว่า source = 'reverse'** ลอยๆ
--
-- ------------------------------------------------------------
-- ตรวจไม่ได้ = ปฏิเสธ (ข้อบังคับที่สำคัญที่สุดของไฟล์นี้)
-- ------------------------------------------------------------
--   ถ้าไม่มีสคีมา storage (หรือตาราง objects หาย) **ห้ามปล่อยผ่านเด็ดขาด** —
--   fn_real_evidence_count() จะ raise ทันที ด่านจึงปฏิเสธ ไม่ใช่เงียบ
--   ด่านที่เงียบเมื่อตรวจไม่ได้ = ด่านที่ไม่มีอยู่ (รูปแบบความผิดที่แพงที่สุดของโปรเจกต์นี้)
--   เทสต์ Z ใน evidence_real_files_test.sql drop สคีมา storage จริงแล้วยืนยันว่าถูกปฏิเสธ
--
-- ------------------------------------------------------------
-- ทำไมมี **สอง** trigger (trg_corporate_evidence + trg_corporate_evidence_real_files)
-- ------------------------------------------------------------
--   ไม่ใช่กฎสองชุด — การตัดสินอยู่ที่ fn_corporate_evidence_ok() **ที่เดียว**
--   ทั้งสอง trigger เรียกตัวเดียวกัน ต่างกันแค่ข้อความและเรื่องคู่ค้า
--
--   เหตุผลที่ต้องมีตัวที่สอง: `fn_corporate_requires_evidence` ถูก **create or replace
--   โดยไฟล์เก่า** (20260917000002 · 20261007000000) ถ้าวันหนึ่งมีใคร replay ไฟล์เก่าทับ
--   (harness · การกู้คืน · การ apply ย้อนลำดับ) ด่านจะกลับไปเป็นบั๊ก D-095 แบบเงียบๆ
--   trigger ตัวที่สองมีชื่อที่ไฟล์เก่าไม่รู้จัก → ไม่มีไฟล์ไหนลบล้างได้โดยไม่ตั้งใจ
--   (scripts/test-storage-local.sh รัน 20261007000000 ทับไฟล์นี้จริงตามลำดับ UNDER_TEST
--    ตัวที่สองคือเหตุผลที่กติกายังแน่นทั้งที่ลำดับไม่เป็นใจ)
--
-- ------------------------------------------------------------
-- SECURITY DEFINER (ตั้งใจ ไม่ใช่เผลอ)
-- ------------------------------------------------------------
--   ต้องอ่าน storage.objects ซึ่งเปิด RLS และ **ไม่มี policy สำหรับ role ของผู้ลงรายการ**
--   ที่ครอบไฟล์ของคนอื่น → ถ้าอ่านตามสิทธิ์ผู้เรียก ไฟล์ที่มีจริงจะถูกนับเป็น "ไม่มี"
--   = ปฏิเสธรายการที่ถูกต้องทั้งหมด (fail closed แต่ใช้งานไม่ได้)
--   ทุกตัวเป็น read-only + raise เท่านั้น · search_path = '' + ชื่อเต็มทุกชื่อ
--   (เงื่อนไขที่ 20261007000007 บังคับ) · revoke execute จาก public/anon/authenticated
--   trigger function ไม่ต้องมี execute ให้ใคร — Postgres ไม่เช็ค EXECUTE ตอน trigger ยิง
--   จึงไม่มีสายพึ่ง ACL ที่ sweep ในอนาคตจะตัดขาดได้
--
-- ------------------------------------------------------------
-- ก่อน apply กับ project จริง
-- ------------------------------------------------------------
--   1. backup ก่อนเสมอ
--   2. ต้องมีสคีมา storage · ไม่มี = migration หยุด (ข้อ 0)
--   3. role ที่รันต้องอ่าน storage.objects ข้าม RLS ได้ (superuser / BYPASSRLS / เจ้าของตาราง)
--      ไม่ผ่าน = migration หยุดที่ข้อ 0b **ห้ามข้าม** เพราะถ้าข้ามไป ฟังก์ชันจะนับได้ 0 เสมอ
--      แล้วรายการนิติบุคคลทุกใบถูกปฏิเสธ (ปลอดภัยแต่ใช้งานไม่ได้) → บอกลูกพี่
--   4. รายการนิติบุคคลที่ **ลงไว้ก่อนหน้านี้ด้วยชื่อไฟล์จำลอง** จะยัง post อยู่ (ไฟล์นี้ไม่ไล่ย้อนหลัง)
--      แต่ **แก้ (UPDATE) ไม่ได้อีกจนกว่าจะมีไฟล์จริง** — ตั้งใจ: การแก้คือการยืนยันใหม่
--      ทางที่ถูกคือ reverse + ลงใหม่พร้อมไฟล์จริง
--
-- ------------------------------------------------------------
-- ย้อนกลับ (rollback)
-- ------------------------------------------------------------
--   -- drop trigger   if exists trg_corporate_evidence_real_files on sri_os.transactions;
--   -- drop function  if exists sri_os.fn_assert_real_evidence();
--   -- drop function  if exists sri_os.fn_corporate_evidence_ok(uuid, uuid, sri_os.txn_source, uuid, text[]);
--   -- drop function  if exists sri_os.fn_real_evidence_count(uuid, text[]);
--   -- drop function  if exists sri_os.fn_real_evidence_refs(uuid, text[]);
--   -- drop function  if exists sri_os.fn_attachment_path_re();
--   -- แล้วรัน 20261007000000_line_integrity_and_view_rls.sql ซ้ำ เพื่อคืน
--   --   fn_corporate_requires_evidence ตัวเดิม (= ยอมรับกลับไปมีบั๊ก D-095 โดยรู้ตัว)
--
-- หมายเหตุ harness: scripts/test-rls-local.sh ไม่มีสคีมา storage → ไฟล์นี้ขึ้น SKIP ที่นั่น
--   (รูปแบบเดียวกับ 20261008000009 · ตั้งใจให้ดังไม่เงียบ) ใช้ scripts/test-storage-local.sh
--
-- idempotent: create or replace · drop trigger if exists ก่อน create · revoke ซ้ำได้
-- ============================================================

set search_path = sri_os, public;

-- ---------- 0 · ต้องมี storage (ไม่มี = หยุด ห้ามสร้างด่านที่ตรวจอะไรไม่ได้) ----------
do $$
begin
  if to_regclass('storage.objects') is null or to_regclass('storage.buckets') is null then
    raise exception 'ไม่พบสคีมา storage (storage.objects / storage.buckets) · กติกาหลักฐานของ corporate_strict ต้องถามไฟล์จริง จึงรันได้เฉพาะบน Supabase (หรือ harness ที่จำลอง storage: scripts/test-storage-local.sh)';
  end if;
end $$;

-- ---------- 0b · ต้องอ่าน storage.objects ข้าม RLS ได้ ----------
-- ถ้าอ่านไม่ได้ ฟังก์ชันจะนับ 0 เสมอ = ปฏิเสธรายการนิติบุคคลทุกใบ · ต้องดังตอน apply ไม่ใช่ตอนลูกพี่ลงรายการ
do $$
declare
  v_owner text;
  v_priv  boolean;
begin
  select rolsuper or rolbypassrls into v_priv from pg_roles where rolname = current_user;
  select tableowner into v_owner from pg_tables where schemaname = 'storage' and tablename = 'objects';
  if not coalesce(v_priv, false) and not coalesce(pg_has_role(current_user, v_owner, 'USAGE'), false) then
    raise exception 'role % อ่าน storage.objects ข้าม RLS ไม่ได้ (ไม่ใช่ superuser/BYPASSRLS และไม่ใช่เจ้าของตาราง %) · ถ้าปล่อยผ่าน ฟังก์ชันนับหลักฐานจะได้ 0 เสมอ แล้วรายการนิติบุคคลทุกใบถูกปฏิเสธ · รันด้วยบทบาท postgres หรือบอกลูกพี่ **ห้ามข้าม**',
      current_user, coalesce(v_owner, '(ไม่พบตาราง)');
  end if;
end $$;

-- ---------- 1 · กฎรูปแบบ path (ชุดเดียวกับ policy ของ 20261008000009 · src/lib/storage/path.ts) ----------
create or replace function fn_attachment_path_re() returns text
language sql immutable set search_path = '' as $fn$
  select '^' || u || '/' || u || '/' || u || '\.(jpg|png|webp|heic|pdf)$'
    from (select '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' as u) q;
$fn$;
comment on function fn_attachment_path_re() is
  'regex ของ path ไฟล์แนบ <owner_id>/<uploader_id>/<uuid>.<ext> · ชุดเดียวกับ policy ใน 20261008000009 และ src/lib/storage/path.ts (เทสต์ X ใน evidence_real_files_test.sql เทียบให้)';

-- ---------- 2 · ไฟล์ที่นับเป็นหลักฐานได้ของผู้ถือรายนี้ ----------
-- สามข้อครบ: รูปแบบ path ถูก · owner ใน path = ผู้ถือของรายการ · มีแถวจริงใน bucket attachments
-- distinct → path ซ้ำนับเป็นหนึ่ง · null/สตริงว่าง/'..'/ตัวพิมพ์ใหญ่ ตกที่ regex
-- bucket 'attachments' ต้องตรงกับ 20261008000009 (เทสต์ X เทียบกับ policy ให้)
create or replace function fn_real_evidence_refs(p_owner uuid, p_attachments text[])
returns setof text
language sql stable security definer set search_path = '' as $fn$
  select distinct a
    from unnest(coalesce(p_attachments, array[]::text[])) as a
   where p_owner is not null
     and a is not null
     and a ~ sri_os.fn_attachment_path_re()
     and split_part(a, '/', 1) = p_owner::text
     and exists (
           select 1 from storage.objects o
            where o.bucket_id = 'attachments' and o.name = a
         );
$fn$;
comment on function fn_real_evidence_refs(uuid, text[]) is
  'ไฟล์แนบที่นับเป็นหลักฐานได้ของผู้ถือรายนี้ (รูปแบบ path ถูก + owner ใน path ตรง + มีไฟล์จริงใน bucket attachments) · นับซ้ำไม่ได้ · DEFINER เพราะ storage.objects เปิด RLS';

create or replace function fn_real_evidence_count(p_owner uuid, p_attachments text[])
returns integer
language plpgsql stable security definer set search_path = '' as $fn$
declare n integer;
begin
  -- ตรวจไม่ได้ = ปฏิเสธ · ห้ามคืน 0 เงียบๆ (0 แปลว่า "ไม่มีหลักฐาน" ซึ่งคนละเรื่องกับ "ตรวจไม่ได้")
  if to_regclass('storage.objects') is null then
    raise exception 'ตรวจไฟล์หลักฐานไม่ได้: ไม่พบ storage.objects → ปฏิเสธไว้ก่อน (ด่านที่เงียบเมื่อตรวจไม่ได้ = ด่านที่ไม่มีอยู่)'
      using errcode = 'insufficient_resources';
  end if;
  select count(*) into n from sri_os.fn_real_evidence_refs(p_owner, p_attachments);
  return coalesce(n, 0);
end $fn$;
comment on function fn_real_evidence_count(uuid, text[]) is
  'จำนวนไฟล์หลักฐานจริงของผู้ถือรายนี้ · ไม่มีสคีมา storage = raise (ปฏิเสธ) ไม่ใช่คืน 0';

-- ---------- 3 · การตัดสินกติกาหลักฐาน — **ที่เดียว** ที่ทั้งสอง trigger ใช้ ----------
create or replace function fn_corporate_evidence_ok(
  p_id uuid, p_owner uuid, p_source txn_source, p_reverses uuid, p_attachments text[]
) returns boolean
language plpgsql stable security definer set search_path = '' as $fn$
declare v_policy sri_os.owner_policy;
begin
  select o.policy into v_policy from sri_os.owners o where o.id = p_owner;
  -- ไม่รู้จักผู้ถือ = ตรวจนโยบายไม่ได้ → ไม่ผ่าน (ห้ามตกไปเส้นทาง "ไม่ใช่นิติบุคคล")
  if v_policy is null then return false; end if;
  if v_policy <> 'corporate_strict' then return true; end if;

  -- ข้อยกเว้นเดิม: ใบกลับรายการ **ที่พิสูจน์ได้** เท่านั้น (ไม่เชื่อคำว่า 'reverse' ลอยๆ)
  if p_source = 'reverse' and sri_os.fn_reverse_link_ok(p_id, p_owner, p_reverses) then
    return true;
  end if;

  return sri_os.fn_real_evidence_count(p_owner, p_attachments) > 0;
end $fn$;
comment on function fn_corporate_evidence_ok(uuid, uuid, txn_source, uuid, text[]) is
  'รายการนี้ผ่านกติกาหลักฐานของผู้ถือหรือยัง · แหล่งความจริงเดียว ใช้ทั้ง trg_corporate_evidence และ trg_corporate_evidence_real_files · ผู้ถือที่ไม่รู้จัก/ตรวจไม่ได้ = ไม่ผ่าน';

-- ---------- 4 · ด่านเดิม: แทนที่การนับความยาวอาร์เรย์ด้วยการนับไฟล์จริง ----------
-- โครงเดิมคงไว้ครบ (นโยบายผู้ถือ · ข้อยกเว้นใบกลับรายการ · คู่ค้าตาม txn_types.requires_contact)
create or replace function fn_corporate_requires_evidence() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_policy sri_os.owner_policy;
  v_needs_contact boolean;
begin
  select o.policy into v_policy from sri_os.owners o where o.id = new.owner_id;
  if v_policy is distinct from 'corporate_strict' then return new; end if;

  if not sri_os.fn_corporate_evidence_ok(new.id, new.owner_id, new.source, new.reverses_id, new.attachments) then
    raise exception 'Corporate strict: ต้องมีไฟล์หลักฐานที่อัปโหลดขึ้น Storage จริงของผู้ถือนี้อย่างน้อย 1 ไฟล์ (txn_type % · ไฟล์แนบ % ช่อง) · ชื่อไฟล์ที่พิมพ์เองไม่นับ และไฟล์ของผู้ถืออื่นไม่นับ',
      new.txn_type_code, coalesce(cardinality(new.attachments), 0);
  end if;

  select t.requires_contact into v_needs_contact from sri_os.txn_types t where t.code = new.txn_type_code;
  if coalesce(v_needs_contact, false) and new.contact_id is null then
    raise exception 'Corporate strict: ประเภทรายการนี้ต้องระบุคู่ค้า (txn_type %)', new.txn_type_code;
  end if;

  return new;
end $fn$;
comment on function fn_corporate_requires_evidence() is
  'ด่านเอกสารของ corporate_strict · หลักฐาน = ไฟล์จริงใน Storage ของผู้ถือนั้น (D-095) ไม่ใช่จำนวนช่องใน attachments';

drop trigger if exists trg_corporate_evidence on transactions;
create trigger trg_corporate_evidence
  before insert or update on transactions
  for each row execute function fn_corporate_requires_evidence();

-- ---------- 5 · ด่านที่ไฟล์เก่า replay ทับไม่ได้ (ดูหัวไฟล์ "ทำไมมีสอง trigger") ----------
create or replace function fn_assert_real_evidence() returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  if not sri_os.fn_corporate_evidence_ok(new.id, new.owner_id, new.source, new.reverses_id, new.attachments) then
    raise exception 'ผู้ถือที่เป็นนิติบุคคลต้องมีไฟล์หลักฐานจริงใน Storage อย่างน้อย 1 ไฟล์ และไฟล์นั้นต้องเป็นของผู้ถือรายนี้ (txn_type %) · กติกานี้ override ไม่ได้ (D-095)',
      new.txn_type_code;
  end if;
  return new;
end $fn$;
comment on function fn_assert_real_evidence() is
  'ด่านหลักฐานจริงของ corporate_strict (D-095) · ชื่อที่ไฟล์เก่าไม่รู้จัก จึงไม่ถูก create or replace ทับโดยไม่ตั้งใจ · เรียก fn_corporate_evidence_ok ตัวเดียวกับด่านเดิม';

drop trigger if exists trg_corporate_evidence_real_files on transactions;
create trigger trg_corporate_evidence_real_files
  before insert or update on transactions
  for each row execute function fn_assert_real_evidence();

-- ---------- 6 · ACL: ปิดทั้งหมด (ไม่มีใครต้องเรียกตรง) ----------
revoke all on function fn_attachment_path_re()                                           from public, anon, authenticated;
revoke all on function fn_real_evidence_refs(uuid, text[])                               from public, anon, authenticated;
revoke all on function fn_real_evidence_count(uuid, text[])                              from public, anon, authenticated;
revoke all on function fn_corporate_evidence_ok(uuid, uuid, txn_source, uuid, text[])    from public, anon, authenticated;
revoke all on function fn_corporate_requires_evidence()                                  from public, anon, authenticated;
revoke all on function fn_assert_real_evidence()                                         from public, anon, authenticated;

-- ---------- 7 · ยืนยันสภาพสุดท้าย (ไม่ผ่าน = migration ล้ม ไม่ใช่เงียบ) ----------
do $$
declare
  n int;
  v_owner uuid;
  v_fake text;
begin
  -- 7.1 trigger ทั้งสองตัวต้องอยู่
  select count(*) into n from pg_trigger t
   where t.tgrelid = 'sri_os.transactions'::regclass and not t.tgisinternal
     and t.tgname in ('trg_corporate_evidence', 'trg_corporate_evidence_real_files');
  if n <> 2 then raise exception 'ต้องมี trigger หลักฐาน 2 ตัว (พบ %)', n; end if;

  -- 7.2 ด่านต้องไปจบที่ storage.objects จริง ไม่ใช่การนับความยาวอาร์เรย์ (กัน D-095 กลับมา)
  if (select p.prosrc from pg_proc p join pg_namespace s on s.oid = p.pronamespace
       where s.nspname = 'sri_os' and p.proname = 'fn_real_evidence_refs') not like '%storage.objects%' then
    raise exception 'fn_real_evidence_refs ไม่ได้ถาม storage.objects';
  end if;

  -- 7.3 probe จริง: ของปลอมต้องนับได้ 0 ทุกแบบ (ไม่ใช่เชื่อว่าโค้ดถูก)
  select id into v_owner from sri_os.owners where policy = 'corporate_strict' order by sort_order limit 1;
  if v_owner is null then raise exception 'ไม่พบผู้ถือ corporate_strict — probe กติกาหลักฐานไม่ได้'; end if;
  v_fake := v_owner::text || '/00000000-0000-4000-8000-000000000000/11111111-1111-4111-8111-111111111111.pdf';
  if sri_os.fn_real_evidence_count(v_owner, array['สลิป.jpg', 'slip.pdf', '']) <> 0 then
    raise exception 'ชื่อไฟล์ที่ผู้ใช้พิมพ์ยังถูกนับเป็นหลักฐาน (บั๊ก D-095)';
  end if;
  if sri_os.fn_real_evidence_count(v_owner, array[v_fake, v_fake]) <> 0 then
    raise exception 'path รูปแบบถูกแต่ไม่มีไฟล์จริงยังถูกนับเป็นหลักฐาน';
  end if;
  if sri_os.fn_real_evidence_count(v_owner, array[null]::text[]) <> 0
     or sri_os.fn_real_evidence_count(v_owner, null) <> 0
     or sri_os.fn_real_evidence_count(null, array[v_fake]) <> 0 then
    raise exception 'ข้อมูลขาดยังถูกนับเป็นหลักฐาน';
  end if;

  -- 7.4 SECURITY DEFINER ของไฟล์นี้ต้องตั้ง search_path = '' ทุกตัว (เงื่อนไขของ 20261007000007)
  -- เงื่อนไขเดียวกับบล็อกตรวจของ 20261007000007 (ห้ามเขียนเกณฑ์ใหม่ที่หลวมกว่า)
  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'sri_os' and p.prosecdef
     and p.proname in ('fn_real_evidence_refs', 'fn_real_evidence_count', 'fn_corporate_evidence_ok',
                       'fn_corporate_requires_evidence', 'fn_assert_real_evidence')
     and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c
                      where c in ('search_path=', 'search_path=""'));
  if n <> 0 then raise exception 'SECURITY DEFINER ของไฟล์นี้ % ตัว search_path ไม่แน่น', n; end if;

  -- 7.5 ต้องไม่มีใครเรียกตรงได้ (ข้าม RLS) — เงื่อนไขของ 20261007000007 ข้อ 5
  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'sri_os' and p.prosecdef
     and p.proname in ('fn_real_evidence_refs', 'fn_real_evidence_count', 'fn_corporate_evidence_ok',
                       'fn_corporate_requires_evidence', 'fn_assert_real_evidence')
     and (has_function_privilege('public', p.oid, 'execute')
       or has_function_privilege('authenticated', p.oid, 'execute')
       or has_function_privilege('anon', p.oid, 'execute'));
  if n <> 0 then raise exception 'ฟังก์ชันกติกาหลักฐาน % ตัวยังเรียกตรงได้จาก public/anon/authenticated', n; end if;

  raise notice 'ok · corporate_strict นับเฉพาะไฟล์จริงใน Storage ของผู้ถือนั้น (D-095 ปิด) · ข้อยกเว้นใบกลับรายการที่พิสูจน์ได้คงไว้ · ตรวจไม่ได้ = ปฏิเสธ';
end $$;
