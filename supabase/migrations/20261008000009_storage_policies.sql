-- ============================================================
-- SRI OS · Supabase Storage สำหรับไฟล์หลักฐาน (สลิป/บิล/สัญญา) — bucket `attachments`
--   เทสต์: supabase/tests-storage/storage_policies_test.sql
--   รัน:   bash scripts/test-storage-local.sh   (ต้องใช้ตัวนี้ — ดูหมายเหตุ harness ด้านล่าง)
--
-- **ยังไม่ apply กับ project จริง** — ออกแบบให้ apply ได้ ดู "ก่อน apply" ท้ายหัวไฟล์
--
-- ------------------------------------------------------------
-- หลักคิด
-- ------------------------------------------------------------
--   สลิปธนาคารคือหลักฐานการเงิน ถ้าใครก็เปิดได้ = เห็นเงินคนอื่นผ่านประตูหลัง
--   ชั้นที่กั้นจริงคือ RLS ใน DB (storage.objects) ไม่ใช่หน้าจอ — ใช้หลักเดียวกับ ledger
--
--   1. bucket **ไม่ public** (ถ้า public ลิงก์ถาวรเปิดได้โดยไม่ผ่าน RLS เลย)
--   2. path บังคับรูปแบบ  <owner_id>/<uploader_id>/<uuid>.<ext>  โดย policy (regex)
--        owner_id    = ผู้ถือที่ไฟล์สังกัด → ตัดสินสิทธิ์ด้วย fn_can_see_owner()
--        uploader_id = ต้องเป็น auth.uid() ตอน insert → ปลอมเป็นคนอื่นไม่ได้
--        uuid        = สุ่มฝั่ง server → เดาไม่ได้ ไม่ชนกัน ชื่อที่ผู้ใช้ตั้งไม่เคยเป็น path
--   3. อ่านได้เมื่อ (ต้องเห็น owner นั้นก่อนเสมอ) และอย่างใดอย่างหนึ่ง:
--        ก. เป็นผู้อัปโหลดเอง (ไฟล์ที่ยังไม่ผูกรายการ ต้องเปิดดูเองได้)
--        ข. มีรายการ (transactions) ที่ **ผู้อ่านมองเห็นได้ตาม RLS ของตารางนั้น** อ้างถึงไฟล์นี้
--           และ owner ของรายการ = owner ใน path  ← ขอบเขตเดียวกับ fn_can_read_txn
--           ผ่าน subquery ที่รันใต้ RLS ของผู้อ่านเอง ไม่ได้เขียนกฎซ้ำ
--        ค. มีร่าง (draft_entries) ที่ผู้อ่านมองเห็นได้ตาม RLS อ้างถึง + owner ตรง
--      "เห็นไฟล์ได้ ⊆ เห็นรายการที่ไฟล์ผูกอยู่ได้" ยกเว้นผู้อัปโหลดเองที่เห็นไฟล์ของตัวเอง
--   4. ผูกรายการต้องเป็น "ผู้อัปโหลดของไฟล์" เท่านั้นที่ทำให้ลิงก์มีผล:
--        ร่าง: draft.created_by = uploader (created_by ถูก policy draft_insert บังคับ = auth.uid())
--        รายการ: txn.created_by = uploader หรือมีร่างต้นทาง (posted_txn_id) ที่ created_by = uploader
--      ปิดช่อง "เอา path ของคนอื่นไปแปะในร่างของตัวเองแล้วอ่านผ่านลิงก์"
--      **ช่องที่ปิดไม่สนิท (รายงานไว้ ไม่ปล่อยเงียบ):** txn_insert ไม่บังคับ created_by = auth.uid()
--      ผู้มี ledger.approve จึงปลอม created_by ได้ — แต่ต้อง "รู้ path ทั้งเส้น" (uuid 122 บิต)
--      ซึ่งปรากฏเฉพาะในแถวที่คนนั้นอ่านได้อยู่แล้ว จึงไม่ใช่ช่องที่ใช้ขโมยได้จริงนอกจากรั่ว path
--      ทางปิดเด็ดขาดคือ trigger ตรวจ attachments ตอน insert/update รายการ (ดูท้ายไฟล์ · รอลูกพี่ตัดสิน)
--   5. ไม่มี policy UPDATE → เขียนทับ/ย้ายไฟล์ไม่ได้ (หลักฐานแก้ไม่ได้ ต้องอัปโหลดใหม่)
--   6. ลบ: ได้เฉพาะผู้อัปโหลดเอง และเฉพาะไฟล์ที่ **ไม่มีแถวใดอ้างถึง** (ร่างที่ยังไม่ส่ง = ยังไม่มีแถว)
--      ไฟล์ที่ transactions / draft_entries / contracts อ้างอยู่ ลบไม่ได้ **ทุกคนทุก role**
--      บังคับด้วย trigger บน storage.objects (ไม่ใช่แค่ policy) เหตุผลเดียวกับ 20261008000003:
--      RLS มีผลกับ authenticated เท่านั้น เจ้าของ DB / service_role ข้ามได้ แต่ trigger ไม่ถามสิทธิ์
--      → ลบไฟล์หลักฐานแล้วรายการ post แล้วไม่มีหลักฐาน = override corporate_strict ทางอ้อม
--
-- ------------------------------------------------------------
-- ไฟล์ลอย (อัปโหลดแล้วแต่บันทึกรายการไม่สำเร็จ)
-- ------------------------------------------------------------
--   ไฟล์ลอย = ไฟล์ใน bucket ที่ไม่มีแถวใดอ้างถึง · ไม่ปล่อยสะสมเงียบ ด้วยสามชั้น:
--     (1) ฝั่งแอป: บันทึกล้ม/เอาไฟล์ออกจากฟอร์ม → ลบทันที (src/lib/storage · best effort)
--     (2) ผู้อัปโหลดกวาดของตัวเองที่เก่ากว่า settings.attachments.orphan_grace_hours (ค่าเริ่มต้น 24)
--         ผ่าน Storage API ด้วยสิทธิ์ตัวเอง — fn_attachment_orphans('mine')
--     (3) มองเห็นได้: fn_attachment_orphans('all') สำหรับ settings.manage (รายการ path+ขนาด+อายุ
--         ไม่ใช่เนื้อไฟล์) ให้ health check/หน้าตั้งค่านับได้ · ของคนที่ไม่กลับมาอีก
--         ลบได้ด้วย Dashboard/service_role เพราะ trigger อนุญาตการลบไฟล์ที่ไม่มีใครอ้าง
--   **ห้ามลบด้วย SQL ตรงบน storage.objects** — แถวหายแต่ไฟล์จริงค้างใน object store (ลอยแบบมองไม่เห็น)
--
-- ------------------------------------------------------------
-- ก่อน apply (ผมไม่ได้แตะ project จริง)
-- ------------------------------------------------------------
--   1. backup ก่อนเสมอ (กติกา migration ขึ้น production)
--   2. migration นี้ **หยุดทันที** ถ้ามี policy อื่นบน storage.objects ที่ไม่จำกัด bucket_id
--      หรือเอ่ยถึง 'attachments' — policy แบบ permissive OR กัน หนึ่งตัวลบล้างทั้งไฟล์
--      (วิธีเดียวกับ SWEEP ใน 20261006190000) · ชื่อ policy จะถูกพิมพ์ใน error
--   3. ต้องรันด้วยบทบาท postgres (SQL editor / supabase db push) — สร้าง trigger บน
--      storage.objects ได้เฉพาะ role ที่มีสิทธิ์ · ถ้า CREATE TRIGGER ล้มด้วย "must be owner"
--      ให้บอกผม **อย่า** ข้ามไป เพราะ policy ล้วนกันแค่ authenticated ไม่กัน service_role
--   4. ต้องมีสคีมา storage (project Supabase มีให้เอง) · ไม่มี = migration หยุด
--
-- ------------------------------------------------------------
-- หมายเหตุ harness: scripts/test-rls-local.sh ไม่มีสคีมา storage → ไฟล์นี้จะขึ้น SKIP ที่นั่น
--   (ตั้งใจให้ดังไม่เงียบ) · ใช้ scripts/test-storage-local.sh ซึ่งจำลอง storage ครบ
--
-- ------------------------------------------------------------
-- ย้อนกลับ (rollback)
-- ------------------------------------------------------------
--   -- drop trigger if exists trg_guard_attachment_delete on storage.objects;
--   -- drop trigger if exists trg_guard_attachment_move   on storage.objects;
--   -- drop policy  if exists attachments_insert on storage.objects;
--   -- drop policy  if exists attachments_select on storage.objects;
--   -- drop policy  if exists attachments_delete on storage.objects;
--   -- drop function if exists sri_os.fn_guard_attachment_objects();
--   -- drop function if exists sri_os.fn_attachment_in_use(text);
--   -- drop function if exists sri_os.fn_attachment_orphans(text);
--   -- (bucket ไม่ drop — มีไฟล์หลักฐานจริงอยู่ · ถ้า drop policy แล้ว bucket เปิดไม่ได้เลย = ปลอดภัยไว้ก่อน)
--
-- idempotent: on conflict · create or replace · drop ... if exists ก่อน create
-- ============================================================

set search_path = sri_os, public;

-- ---------- 0 · ต้องมี storage ----------
do $$
begin
  if to_regclass('storage.objects') is null or to_regclass('storage.buckets') is null then
    raise exception 'ไม่พบสคีมา storage (storage.objects / storage.buckets) · migration นี้รันได้เฉพาะบน Supabase (หรือ harness ที่จำลอง storage: scripts/test-storage-local.sh)';
  end if;
end $$;

-- ---------- 1 · bucket (private) ----------
-- ค่า 4194304 / รายการชนิดไฟล์ ต้องตรงกับ src/lib/storage/config.ts — เทสต์ drift ตรวจให้
-- (4 MB = เพดานที่ route handler บน Vercel รับ body ได้ ~4.5 MB · ใหญ่กว่านี้ฝั่งแอปย่อรูปก่อน)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('attachments', 'attachments', false, 4194304,
        array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif', 'application/pdf'])
on conflict (id) do update
  set public             = false,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ---------- 2 · ค่าตั้งได้ (กฎเหล็กข้อ 5) ----------
insert into settings (key, value)
values ('attachments.orphan_grace_hours', '24'::jsonb)
on conflict (key) do nothing;

-- ---------- 3 · ดัชนีสำหรับ "ไฟล์นี้มีใครอ้างไหม" ----------
create index if not exists transactions_attachments_gin on transactions using gin (attachments);
create index if not exists draft_entries_attachments_gin on draft_entries using gin (attachments);
create index if not exists contracts_file_urls_gin on contracts using gin (file_urls);

-- ---------- 4 · ฟังก์ชัน ----------
-- มีแถวใดอ้างถึง path นี้ไหม — SECURITY DEFINER เพราะต้องมองเห็น **ทุกแถว** ไม่ใช่เฉพาะที่ผู้เรียกเห็น
-- (ถ้าถามใต้ RLS ผู้เรียก: รายการที่ตัวเองมองไม่เห็นจะถูกนับเป็น "ไม่มีใครอ้าง" → ลบหลักฐานได้)
-- คืนแค่ boolean · path เป็น uuid เดาไม่ได้ จึงใช้เป็นช่องสืบ path ของคนอื่นไม่ได้
-- contracts.file_urls รวมไว้ในฝั่ง "ห้ามลบ" แม้ policy อ่านยังไม่ผูกกับสัญญา (กันลบ ไม่ใช่เปิดอ่าน)
create or replace function fn_attachment_in_use(p_path text) returns boolean
language sql stable security definer set search_path = '' as $fn$
  select p_path is not null and (
       exists (select 1 from sri_os.transactions  where attachments @> array[p_path])
    or exists (select 1 from sri_os.draft_entries where attachments @> array[p_path])
    or exists (select 1 from sri_os.contracts     where file_urls   @> array[p_path])
  );
$fn$;
comment on function fn_attachment_in_use(text) is
  'ไฟล์ใน bucket attachments มีแถวอ้างถึงไหม (transactions · draft_entries · contracts) · DEFINER = เห็นทุกแถวข้าม RLS · ใช้ใน policy ลบและ trigger กันลบ · null → false ไม่ใช่ error';

-- trigger: ห้ามลบ/ย้ายไฟล์ที่มีแถวอ้างถึง **ทุก role** (รวม service_role และเจ้าของ DB)
create or replace function fn_guard_attachment_objects() returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  if tg_op = 'DELETE' then
    if old.bucket_id = 'attachments' and sri_os.fn_attachment_in_use(old.name) then
      raise exception 'ลบไฟล์หลักฐานไม่ได้: % ถูกอ้างถึงโดยรายการ/ร่าง/สัญญาแล้ว · ลบไฟล์ = รายการที่ post แล้วไม่มีหลักฐาน (override corporate_strict ทางอ้อม) · ผิดไฟล์ให้แนบไฟล์ใหม่ + บันทึกรายการกลับ', old.name
        using errcode = 'restrict_violation';
    end if;
    return old;
  end if;
  -- UPDATE ของ name / bucket_id = ย้ายหรือเปลี่ยนชื่อ → ลิงก์ในรายการชี้ไปที่ไม่มีแล้ว
  if old.bucket_id = 'attachments'
     and (new.name is distinct from old.name or new.bucket_id is distinct from old.bucket_id)
     and sri_os.fn_attachment_in_use(old.name) then
    raise exception 'ย้าย/เปลี่ยนชื่อไฟล์หลักฐานไม่ได้: % ถูกอ้างถึงแล้ว', old.name
      using errcode = 'restrict_violation';
  end if;
  return new;
end $fn$;
comment on function fn_guard_attachment_objects() is
  'กันลบ/ย้ายไฟล์หลักฐานที่ถูกอ้าง · ไม่ถามสิทธิ์ (ห้ามลบเท่ากันทุกตำแหน่ง) · DEFINER เพื่ออ่านตาราง sri_os ได้เมื่อถูกยิงจาก role ของ Storage';

-- ไฟล์ลอย: ไม่มีแถวใดอ้าง และเก่ากว่าช่วงผ่อนผัน
--   'mine' = ของผู้เรียกเอง (ใช้กวาดเอง)
--   'all'  = ทุกไฟล์ในขอบเขต owner ที่เห็น · ต้องมี settings.manage (ได้แค่ path+ขนาด+อายุ ไม่ได้สิทธิ์เปิดไฟล์)
create or replace function fn_attachment_orphans(p_scope text default 'mine')
returns table (path text, owner_id uuid, uploader_id uuid, size_bytes bigint, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_grace numeric;
begin
  if p_scope not in ('mine', 'all') then
    raise exception 'p_scope ต้องเป็น mine หรือ all (ได้ %)', p_scope;
  end if;
  if auth.uid() is null then
    raise exception 'ต้องล็อกอิน';
  end if;
  if p_scope = 'all' and not sri_os.fn_can('settings.manage') then
    raise exception 'ดูรายการไฟล์ลอยของทุกคนต้องมีสิทธิ์ settings.manage';
  end if;

  select coalesce((select (s.value #>> '{}')::numeric from sri_os.settings s
                    where s.key = 'attachments.orphan_grace_hours'), 24)
    into v_grace;

  return query
  select o.name,
         ((storage.foldername(o.name))[1])::uuid,
         ((storage.foldername(o.name))[2])::uuid,
         coalesce((o.metadata ->> 'size')::bigint, 0),
         o.created_at
    from storage.objects o
   where o.bucket_id = 'attachments'
     and o.name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/'
     and o.created_at < now() - make_interval(secs => v_grace * 3600)
     and not sri_os.fn_attachment_in_use(o.name)
     and (
          (p_scope = 'mine' and (storage.foldername(o.name))[2] = auth.uid()::text)
       or (p_scope = 'all'
           and sri_os.fn_can_see_owner(((storage.foldername(o.name))[1])::uuid))
     )
   order by o.created_at;
end $fn$;
comment on function fn_attachment_orphans(text) is
  'ไฟล์ลอยใน bucket attachments (ไม่มีแถวอ้าง + เก่ากว่า settings.attachments.orphan_grace_hours) · mine = ของตัวเอง · all = ต้อง settings.manage · คืนเฉพาะ metadata ไม่ให้สิทธิ์เปิดไฟล์';

-- ACL: ปิดทั้งหมดแล้วเปิดเท่าที่ต้องใช้ (หลักเดียวกับ 20261007000007)
revoke all on function fn_attachment_in_use(text)          from public, anon, authenticated;
revoke all on function fn_attachment_orphans(text)         from public, anon, authenticated;
revoke all on function fn_guard_attachment_objects()       from public, anon, authenticated;
grant execute on function fn_attachment_in_use(text)       to authenticated;   -- policy ลบเรียก
grant execute on function fn_attachment_orphans(text)      to authenticated;   -- เช็คสิทธิ์ในตัวฟังก์ชัน

-- trigger บน storage.objects
drop trigger if exists trg_guard_attachment_delete on storage.objects;
create trigger trg_guard_attachment_delete
  before delete on storage.objects
  for each row execute function sri_os.fn_guard_attachment_objects();

drop trigger if exists trg_guard_attachment_move on storage.objects;
create trigger trg_guard_attachment_move
  before update of name, bucket_id on storage.objects
  for each row execute function sri_os.fn_guard_attachment_objects();

-- ---------- 5 · หยุดถ้ามี policy อื่นที่เปิดช่อง ----------
do $$
declare
  r record;
  v_bad text := '';
begin
  for r in
    select policyname, coalesce(qual, '') as q, coalesce(with_check, '') as w
      from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and policyname not in ('attachments_insert', 'attachments_select', 'attachments_delete')
  loop
    if (r.q || r.w) !~ 'bucket_id' or (r.q || r.w) ~ 'attachments' then
      v_bad := v_bad || ' · ' || r.policyname;
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'พบ policy อื่นบน storage.objects ที่ไม่จำกัด bucket หรือแตะ attachments:% · policy แบบ permissive OR กัน หนึ่งตัวลบล้างขอบเขตทั้งหมด · ตรวจแล้วลบ/แก้เองก่อน apply (ผมไม่ลบให้เพราะมองของจริงไม่เห็นว่าใครพึ่งมันอยู่)', v_bad;
  end if;
end $$;

-- ---------- 6 · policy ----------
-- regex path เขียนครั้งเดียวที่นี่ แล้ว format ลง policy (กันสามที่เขียนไม่ตรงกัน)
do $$
declare
  u  constant text := '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
  re constant text := '^' || u || '/' || u || '/' || u || '\.(jpg|png|webp|heic|pdf)$';
  -- ชิ้นที่ใช้ซ้ำ: เคส when กันการ cast เป็น uuid ก่อนผ่าน regex (SQL ไม่รับประกันลำดับ AND)
  own   constant text := '((storage.foldername(objects.name))[1])::uuid';
  upl   constant text := '(storage.foldername(objects.name))[2]';
begin
  -- 6.1 insert: ต้องมีสิทธิ์คีย์รายการ + เห็น owner นั้น + ผู้อัปโหลดใน path = ตัวเอง
  --     ไม่มี upsert (ไม่มี policy update) → เขียนทับไม่ได้
  execute 'drop policy if exists attachments_insert on storage.objects';
  execute format($p$
    create policy attachments_insert on storage.objects
      for insert to authenticated
      with check (
        bucket_id = 'attachments'
        and case when objects.name ~ %1$L then
              (sri_os.fn_can('txn.create') or sri_os.fn_can('ledger.approve'))
              and sri_os.fn_can_see_owner(%2$s)
              and %3$s = (select auth.uid())::text
            else false end
      )$p$, re, own, upl);

  -- 6.2 select: ต้องเห็น owner + (ผู้อัปโหลดเอง หรือ รายการ/ร่างที่ตัวเองมองเห็นอ้างถึง)
  --     subquery รันใต้ RLS ของผู้อ่าน → ขอบเขต = fn_can_read_txn / draft_entries_by_owner
  execute 'drop policy if exists attachments_select on storage.objects';
  execute format($p$
    create policy attachments_select on storage.objects
      for select to authenticated
      using (
        bucket_id = 'attachments'
        and case when objects.name ~ %1$L then
              sri_os.fn_can_see_owner(%2$s)
              and (
                   %3$s = (select auth.uid())::text
                or exists (
                     select 1 from sri_os.draft_entries d
                      where d.owner_id::text = (storage.foldername(objects.name))[1]
                        and d.attachments @> array[objects.name]
                        and d.created_by::text = (storage.foldername(objects.name))[2]
                   )
                or exists (
                     select 1 from sri_os.transactions t
                      where t.owner_id::text = (storage.foldername(objects.name))[1]
                        and t.attachments @> array[objects.name]
                        and (
                             t.created_by::text = (storage.foldername(objects.name))[2]
                          or exists (
                               select 1 from sri_os.draft_entries d2
                                where d2.posted_txn_id = t.id
                                  and d2.owner_id = t.owner_id
                                  and d2.attachments @> array[objects.name]
                                  and d2.created_by::text = (storage.foldername(objects.name))[2]
                             )
                        )
                   )
              )
            else false end
      )$p$, re, own, upl);

  -- 6.3 delete: เฉพาะของตัวเอง และเฉพาะที่ไม่มีแถวใดอ้าง (trigger กันซ้ำอีกชั้นสำหรับ role อื่น)
  execute 'drop policy if exists attachments_delete on storage.objects';
  execute format($p$
    create policy attachments_delete on storage.objects
      for delete to authenticated
      using (
        bucket_id = 'attachments'
        and case when objects.name ~ %1$L then
              %3$s = (select auth.uid())::text
              and sri_os.fn_can_see_owner(%2$s)
              and not sri_os.fn_attachment_in_use(objects.name)
            else false end
      )$p$, re, own, upl);
end $$;

-- ---------- 7 · ยืนยันสภาพสุดท้าย (ไม่ผ่าน = migration ล้ม ไม่ใช่เงียบ) ----------
do $$
declare v_public boolean; n int;
begin
  select public into v_public from storage.buckets where id = 'attachments';
  if v_public is distinct from false then
    raise exception 'bucket attachments ต้อง private (public = %)', v_public;
  end if;

  select count(*) into n from pg_policies
   where schemaname = 'storage' and tablename = 'objects'
     and policyname in ('attachments_insert', 'attachments_select', 'attachments_delete');
  if n <> 3 then raise exception 'policy ของ attachments ต้องมี 3 ตัว (พบ %)', n; end if;

  -- ไม่มี policy UPDATE ของ bucket นี้เลย (ไฟล์หลักฐานแก้/ย้าย/เขียนทับไม่ได้)
  select count(*) into n from pg_policies
   where schemaname = 'storage' and tablename = 'objects' and cmd in ('UPDATE', 'ALL')
     and (coalesce(qual, '') || coalesce(with_check, '')) ~ 'attachments';
  if n <> 0 then raise exception 'ห้ามมี policy UPDATE/ALL ที่แตะ attachments (พบ %)', n; end if;

  -- ไม่มี policy ของเราที่ให้ anon
  select count(*) into n from pg_policies
   where schemaname = 'storage' and tablename = 'objects'
     and policyname like 'attachments\_%' and not ('authenticated' = any(roles));
  if n <> 0 then raise exception 'policy ของ attachments ต้องให้เฉพาะ authenticated'; end if;
end $$;

-- ============================================================
-- ที่ยังไม่ทำ (รอลูกพี่ตัดสิน — บอกไว้ ไม่ปล่อยเงียบ)
-- ============================================================
--   A. trigger ตรวจ attachments ตอน insert/update ของ transactions / draft_entries:
--      ทุกสมาชิกที่หน้าตาเป็น storage path ต้อง (1) มีไฟล์จริงใน bucket (2) owner ใน path =
--      owner_id ของแถว (3) ผู้เขียนเป็นผู้อัปโหลด หรือไฟล์ถูกร่างที่ตัวเองเห็นอ้างอยู่แล้ว
--      → ปิดช่องปลอม created_by ข้างบนเด็ดขาด
--   B. corporate_strict นับเฉพาะ "ไฟล์จริงใน Storage" เป็นหลักฐาน — ตอนนี้
--      fn_corporate_requires_evidence เช็คแค่ cardinality(attachments) > 0 ดังนั้น
--      DB ยังรับ 'สลิป.jpg' ที่ไม่มีไฟล์จริง · ไม่แก้เพราะเทสต์เดิมหลายไฟล์ใส่ชื่อจำลอง
--      และไม่ควรแก้ก่อนหน้าจอเลิกใช้ mock (บทเรียนข้อ 7: เปิดครึ่งเดียวอันตราย)
