-- ============================================================
-- SRI OS · `fn_my_access(text[])` — โปรไฟล์ + คำตอบสิทธิ์ทั้งหน้า **ในคำสั่งเดียว**
--
-- ทำไมต้องมีอีกตัวนอกจาก `fn_can_many`
--   หน้าจอต้องได้สองอย่างต่อการโหลดหนึ่งครั้ง: (1) คำตอบสิทธิ์ทุกตัว
--   (2) โปรไฟล์ไว้แสดงชื่อ/ระดับ และบอกว่า "บัญชีถูกปิดใช้งาน"
--   PostgREST ต่อ RPC กับตารางในคำขอเดียวไม่ได้ → ถ้าแยกสองคำขอ ก็กลับไป
--   เสีย round trip ข้ามทวีปเพิ่มอีกหนึ่ง ซึ่งเป็นสิ่งที่เรากำลังแก้
--   ไฟล์นี้จึงรวมให้เป็นคำขอเดียว **โดยไม่คัดลอกเกณฑ์สิทธิ์มาไว้ที่ไหนใหม่**
--
-- **กฎยังอยู่ที่เดียว**
--   คำตอบสิทธิ์มาจาก `fn_can_many()` → ซึ่งเรียก `fn_can()` → ซึ่งอ่าน
--   `app_users` + `role_permissions` · ตัวนี้ **ไม่ตัดสินสิทธิ์เอง** แตะตาราง
--   `app_users`/`roles` เฉพาะเพื่อดึง **ชื่อที่เอาไปแสดง** (display_name · label)
--   และธง `is_active` ไว้บอกผู้ใช้ว่าทำไมทุกอย่างเป็น false
--   guard ท้ายไฟล์บังคับว่าต้องไม่มีคำว่า `role_permissions` ในตัวมันเอง
--
-- `security invoker` (ค่าปริยาย) โดยตั้งใจ:
--   โปรไฟล์อ่านผ่าน RLS ของ `app_users` (`users_read`: เห็นแถวของตัวเอง) →
--   ผู้ใช้คนหนึ่งถามโปรไฟล์ของคนอื่นไม่ได้ · definer จะเปิดช่องนั้นทันที
--
-- รูปคำตอบ (jsonb ก้อนเดียว)
--   { "user_id": uuid | null,
--     "profile": { "display_name", "role_key", "role_label", "is_active" } | null,
--     "permissions": { "<ชื่อสิทธิ์>": true|false, ... } }
--   · ไม่ล็อกอิน / ไม่มีแถวใน `app_users` → `profile` เป็น null และทุกสิทธิ์ false
--   · `is_active = false` → มี `profile` (หน้าจอต้องอธิบายได้) แต่ทุกสิทธิ์ false
--     (มาจาก `fn_can` เอง ไม่ใช่เงื่อนไขที่เขียนซ้ำที่นี่)
--   · ส่งชื่อสิทธิ์ที่ไม่มีอยู่จริง → `false` ไม่ใช่ error (หน้าจอจะได้ไม่ล่มทั้งหน้า
--     เพราะสะกดผิดตัวเดียว · เหตุผลเดียวกับ `fn_can_many`)
--
-- ลำดับ: ต้องรันหลัง 20261025000022_fn_can_many.sql · guard หัวไฟล์ตรวจให้
-- idempotent: create or replace function เท่านั้น
--
-- ย้อนกลับ (rollback):
--   -- drop function if exists sri_os.fn_my_access(text[]);
--   ⚠ ถอดแล้วหน้าจอต้องถามสองคำขอ (สิทธิ์ + โปรไฟล์) · **ห้ามแก้ด้วยการอ่าน
--     `role_permissions` เองที่ฝั่งแอป** นั่นคือกฎสองที่ซึ่งเป็นต้นเรื่องของไฟล์นี้
-- ============================================================

set search_path = sri_os, public;

do $$
begin
  if to_regprocedure('sri_os.fn_can_many(text[])') is null then
    raise exception 'ไม่มี fn_can_many(text[]) → ต้องรัน 20261025000022_fn_can_many.sql ก่อนไฟล์นี้ (ไฟล์นี้ต้องได้คำตอบสิทธิ์จากที่นั่น ห้ามคิดเอง)';
  end if;
  if to_regclass('sri_os.roles') is null or to_regclass('sri_os.app_users') is null then
    raise exception 'ไม่มีตาราง roles/app_users → ต้องรัน 20261006190000_roles_permissions.sql ก่อนไฟล์นี้';
  end if;
end $$;

create or replace function fn_my_access(p_permissions text[])
returns jsonb
language sql stable set search_path = sri_os, public as $fn$
  select jsonb_build_object(
    'user_id', auth.uid(),
    -- โปรไฟล์ = **ชื่อที่เอาไปแสดง** เท่านั้น (ผ่าน RLS ของ app_users: แถวของตัวเอง)
    'profile', (
      select jsonb_build_object(
               'display_name', u.display_name,
               'role_key',     u.role,
               'role_label',   r.label,
               'is_active',    u.is_active)
        from app_users u
        left join roles r on r.key = u.role
       where u.id = auth.uid()),
    -- คำตอบสิทธิ์ = **จาก fn_can_many ทั้งหมด** (ซึ่งเรียก fn_can ตัวเดิม)
    'permissions', coalesce(
      (select jsonb_object_agg(m.permission, m.allowed)
         from fn_can_many(p_permissions) m
        where m.permission is not null),
      '{}'::jsonb));
$fn$;

comment on function fn_my_access(text[]) is
  'โปรไฟล์ + คำตอบสิทธิ์ทุกตัวในคำขอเดียว (หน้าจอหนึ่งหน้าเช็ค 16 สิทธิ์ และ DB อยู่คนละทวีปกับเว็บ) · **คำตอบสิทธิ์มาจาก fn_can_many → fn_can เท่านั้น** ตัวนี้ไม่ตัดสินสิทธิ์เอง อ่าน app_users/roles แค่ชื่อที่เอาไปแสดงกับธง is_active · security invoker → โปรไฟล์ของคนอื่นถามไม่ได้ (RLS users_read) · ไม่ล็อกอิน/ไม่มีแถว = profile null + ทุกสิทธิ์ false';

revoke all on function fn_my_access(text[]) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_my_access(text[]) from anon';
  execute 'grant execute on function sri_os.fn_my_access(text[]) to authenticated';
end $$;

-- ============================================================
-- guard ท้ายไฟล์
-- ============================================================
do $$
declare v text; n int; j jsonb;
begin
  -- (ก) ต้องเป็น invoker · เรียกได้เฉพาะ authenticated
  if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
              where ns.nspname = 'sri_os' and p.proname = 'fn_my_access' and p.prosecdef) then
    raise exception 'fn_my_access เป็น security definer — จะกลายเป็นทางอ่านโปรไฟล์ของผู้ใช้คนอื่น (ต้องให้ RLS ของ app_users ทำงาน)';
  end if;
  if not has_function_privilege('authenticated', 'sri_os.fn_my_access(text[])'::regprocedure, 'execute') then
    raise exception 'authenticated เรียก fn_my_access ไม่ได้ → หน้าจอใช้ไม่ได้';
  end if;
  foreach v in array array['anon', 'public'] loop
    if has_function_privilege(v, 'sri_os.fn_my_access(text[])'::regprocedure, 'execute') then
      raise exception '% เรียก fn_my_access ได้ — ต้องให้เฉพาะ authenticated', v;
    end if;
  end loop;

  /**
   * (ข) **กฎอยู่ที่เดียว** — ต้องถาม `fn_can_many` และ **ห้ามอ่านตารางสิทธิ์เอง**
   * (`app_users`/`roles` อ่านได้ เพราะเอาแค่ชื่อไปแสดง · `role_permissions`
   *  คือตารางที่ตัดสินว่าใครทำอะไรได้ → แตะไม่ได้)
   */
  select regexp_replace(regexp_replace(p.prosrc, '/\*.*?\*/', ' ', 'gs'), '--[^\n]*', ' ', 'g')
    into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_my_access';
  if v is null then
    raise exception 'อ่าน prosrc ของ fn_my_access ไม่ได้ — ไม่ยอมผ่านด้วยชุดว่าง';
  end if;
  if v !~ 'fn_can_many\s*\(' then
    raise exception 'fn_my_access ไม่ได้เรียก fn_can_many → เกณฑ์สิทธิ์กลายเป็นที่ที่สอง';
  end if;
  if v ~ 'role_permissions' then
    raise exception 'fn_my_access อ่าน role_permissions เอง → กฎสองที่ (ต้องได้คำตอบจาก fn_can_many เท่านั้น)';
  end if;

  -- (ค) พฤติกรรมตอนไม่มีผู้ล็อกอิน (เคส fail-closed ที่ migration ตรวจได้จริง)
  select sri_os.fn_my_access((select array_agg(key order by key) from sri_os.permissions)) into j;
  if j -> 'profile' <> 'null'::jsonb then
    raise exception 'ไม่มีผู้ล็อกอิน แต่ fn_my_access คืนโปรไฟล์มา: %', j -> 'profile';
  end if;
  select count(*) into n from jsonb_each(j -> 'permissions') where value::text = 'true';
  if n <> 0 then
    raise exception 'ไม่มีผู้ล็อกอิน แต่มีสิทธิ์ที่เป็น true อยู่ % ตัว', n;
  end if;
  -- ต้องตอบ **ครบทุกสิทธิ์ที่ถาม** (ขาดไปแปลว่าฝั่งแอปจะเดาเองว่าตัวที่หายคืออะไร)
  if (select count(*) from jsonb_each(j -> 'permissions')) <> (select count(*) from sri_os.permissions) then
    raise exception 'จำนวนสิทธิ์ที่ตอบ (%) ไม่เท่าจำนวนที่ถาม (%)',
      (select count(*) from jsonb_each(j -> 'permissions')),
      (select count(*) from sri_os.permissions);
  end if;

  -- (ง) เคสขอบ: อาร์เรย์ว่าง/null ต้องไม่พัง และสิทธิ์ที่ไม่มีจริงต้องได้ false
  if sri_os.fn_my_access(array[]::text[]) -> 'permissions' <> '{}'::jsonb then
    raise exception 'ถามด้วยอาร์เรย์ว่างต้องได้ permissions ว่าง';
  end if;
  if sri_os.fn_my_access(null) -> 'permissions' <> '{}'::jsonb then
    raise exception 'ถามด้วย null ต้องได้ permissions ว่าง ไม่ใช่ error';
  end if;
  if (sri_os.fn_my_access(array['ไม่มีสิทธิ์นี้อยู่จริง']) -> 'permissions' -> 'ไม่มีสิทธิ์นี้อยู่จริง')
     <> 'false'::jsonb then
    raise exception 'สิทธิ์ที่ไม่มีอยู่จริงต้องได้ false (ไม่ใช่หายไปหรือ error)';
  end if;

  raise notice 'ok · fn_my_access พร้อมใช้ · โปรไฟล์ + % สิทธิ์ในคำขอเดียว · คำตอบสิทธิ์มาจาก fn_can_many → fn_can (กฎอยู่ที่เดียว) · invoker · authenticated เท่านั้น',
    (select count(*) from sri_os.permissions);
end $$;
