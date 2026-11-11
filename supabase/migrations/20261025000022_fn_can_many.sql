-- ============================================================
-- SRI OS · `fn_can_many(text[])` — ถามสิทธิ์หลายตัว **ใน round trip เดียว**
--
-- ปัญหาที่แก้ (ของจริง วัดแล้ว): `getAccess()` ยิง `fn_can` 16 ครั้งแยกกันทุกครั้ง
-- ที่โหลดหน้า · DB อยู่สิงคโปร์ เว็บรันอเมริกา → เสียเวลา 3-4 วินาทีกับการเช็คสิทธิ์
-- สิ่งที่แพงคือ **round trip ข้ามทวีป** ไม่ใช่การวนลูปในฐานข้อมูล
--
-- ------------------------------------------------------------
-- **กฎอยู่ที่เดียว** — นี่คือเหตุผลทั้งหมดที่ไฟล์นี้มีอยู่
-- ------------------------------------------------------------
--   ตัวนี้ **เรียก `fn_can()` ตัวเดิม** ต่อหนึ่งสิทธิ์ ไม่ได้เขียนตรรกะใหม่
--   (ไม่ได้อ่าน `app_users` / `role_permissions` เองเลย)
--   → ถ้าวันหนึ่งใครแก้เกณฑ์ใน `fn_can` ตัวนี้เปลี่ยนตามทันทีโดยไม่ต้องมีใครจำ
--   **ดริฟต์เป็นไปไม่ได้โดยโครงสร้าง** ไม่ใช่เพราะมีเทสต์เทียบไว้
--   (เทสต์ที่เทียบสองแหล่งจับได้แค่ตอนรัน · ของที่เรียกแหล่งเดียวผิดไม่ได้ตั้งแต่ต้น)
--
--   การวนลูปในฐานข้อมูลยอมรับได้: 16 ครั้งของ `fn_can` เป็น index scan บน
--   `role_permissions` ในกระบวนการเดียวกัน — เทียบกับ 16 round trip ข้ามทวีป
--   คือคนละอันดับความเร็ว · และราคาที่จ่ายคือ "ช้าขึ้นไม่กี่ไมโครวินาที"
--   แลกกับ "กฎไม่แตกเป็นสองที่" ซึ่งเป็นสิ่งที่เราเจ็บมาแล้ว
--
-- `security invoker` (ค่าปริยาย) โดยตั้งใจ — **ห้ามทำเป็น definer**:
--   `fn_can` เองเป็น definer และตัดสินจาก `auth.uid()` อยู่แล้ว · การห่อด้วย
--   definer อีกชั้นไม่ได้เพิ่มอะไรนอกจากทางข้ามสิทธิ์ที่ต้องมาตรวจกันใหม่
--
-- พฤติกรรมที่ตั้งใจ (เหมือน `fn_can` ทุกข้อ เพราะเป็นตัวเดียวกัน)
--   · ไม่ล็อกอิน / ไม่มีแถวใน `app_users` / `is_active = false` → **false ทุกตัว**
--   · สิทธิ์ที่ไม่มีอยู่จริงในตาราง `permissions` → **false ไม่ใช่ error**
--     (ฝั่งแอปจะได้ "ทำไม่ได้" ซึ่งเป็นคำตอบที่ปลอดภัย · ถ้า error ทั้งหน้าจะล่ม
--      เพราะสะกดชื่อสิทธิ์ผิดตัวเดียว)
--   · อาร์เรย์ว่าง / null → คืน 0 แถว ไม่พัง
--   · คืน **หนึ่งแถวต่อหนึ่งสมาชิกที่ส่งมา** ตามลำดับเดิม (ส่งซ้ำได้แถวซ้ำ)
--     ฝั่งแอปจึง map ชื่อ → boolean ได้ตรงๆ โดยไม่ต้องเดาว่าตัวไหนหายไป
--
-- ลำดับ: ต้องรันหลัง 20261006190000_roles_permissions.sql · guard หัวไฟล์ตรวจให้
-- idempotent: create or replace function เท่านั้น (ไม่แตะตาราง/policy)
--
-- ย้อนกลับ (rollback):
--   -- drop function if exists sri_os.fn_can_many(text[]);
--   ⚠ ถอดแล้วหน้าจอกลับไปยิง `fn_can` ทีละตัว (ช้า แต่ถูกต้อง) ·
--     **ห้ามแก้ด้วยการเขียนตรรกะสิทธิ์ซ้ำใน TypeScript** นั่นคือกฎสองที่
-- ============================================================

set search_path = sri_os, public;

do $$
begin
  if to_regprocedure('sri_os.fn_can(text)') is null then
    raise exception 'ไม่มี fn_can(text) → ต้องรัน 20261006190000_roles_permissions.sql ก่อนไฟล์นี้ (ไฟล์นี้เป็นเพียงตัวห่อของฟังก์ชันนั้น)';
  end if;
  if to_regclass('sri_os.permissions') is null or to_regclass('sri_os.role_permissions') is null then
    raise exception 'ไม่มีตารางสิทธิ์ → ต้องรัน 20261006190000_roles_permissions.sql ก่อนไฟล์นี้';
  end if;
end $$;

create or replace function fn_can_many(p_permissions text[])
returns table (permission text, allowed boolean)
language sql stable set search_path = sri_os, public as $fn$
  -- **ตรรกะทั้งหมดอยู่ใน fn_can** — ที่นี่มีแค่การวนรายการที่ส่งมา
  select p::text, sri_os.fn_can(p)
    from unnest(coalesce(p_permissions, '{}'::text[])) as p;
$fn$;

comment on function fn_can_many(text[]) is
  'ถามสิทธิ์หลายตัวใน round trip เดียว (หน้าจอหนึ่งหน้าเช็ค 16 สิทธิ์ · DB อยู่คนละทวีปกับเว็บ) · **เรียก fn_can() ตัวเดิมข้างใน ไม่ได้เขียนเกณฑ์ใหม่** จึงดริฟต์จาก fn_can ไม่ได้โดยโครงสร้าง (ห้ามเขียนตรรกะสิทธิ์ซ้ำที่ฝั่ง TypeScript) · security invoker · คืนหนึ่งแถวต่อหนึ่งสมาชิกที่ส่งมา · ไม่ล็อกอิน/ปิดใช้งาน/สิทธิ์ที่ไม่มีอยู่จริง = false ไม่ใช่ error';

revoke all on function fn_can_many(text[]) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_can_many(text[]) from anon';
  execute 'grant execute on function sri_os.fn_can_many(text[]) to authenticated';
end $$;

-- ============================================================
-- guard ท้ายไฟล์
-- ============================================================
do $$
declare v text; n int; v_bad text;
begin
  -- (ก) ต้องไม่เป็น definer (ไม่งั้นเป็นทางข้ามสิทธิ์ที่ต้องมาตรวจกันใหม่)
  if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
              where ns.nspname = 'sri_os' and p.proname = 'fn_can_many' and p.prosecdef) then
    raise exception 'fn_can_many เป็น security definer — ต้องเป็น invoker (fn_can เป็น definer และตัดสินจาก auth.uid() อยู่แล้ว)';
  end if;

  -- (ข) สิทธิ์การเรียกต้องเป็น authenticated เท่านั้น
  if not has_function_privilege('authenticated', 'sri_os.fn_can_many(text[])'::regprocedure, 'execute') then
    raise exception 'authenticated เรียก fn_can_many ไม่ได้ → หน้าจอใช้ไม่ได้';
  end if;
  foreach v in array array['anon', 'public'] loop
    if has_function_privilege(v, 'sri_os.fn_can_many(text[])'::regprocedure, 'execute') then
      raise exception '% เรียก fn_can_many ได้ — ต้องให้เฉพาะ authenticated', v;
    end if;
  end loop;

  /**
   * (ค) **กฎอยู่ที่เดียว ตรวจจากโครงสร้าง ไม่ใช่จากการเทียบผลลัพธ์**
   *
   * ตัวนี้ต้องเรียก `fn_can` และ **ต้องไม่อ่านตารางสิทธิ์เอง**
   * ถ้าวันหนึ่งมีใครมา inline เกณฑ์ลงไปเพื่อ "ให้เร็วขึ้น" migration นี้จะพัง
   * ซึ่งดังกว่าเทสต์ที่เทียบผลลัพธ์ เพราะของที่เรียกแหล่งเดียว **ผิดไม่ได้**
   * ตั้งแต่ต้น ไม่ต้องรอให้มีใครรันเทสต์
   */
  select regexp_replace(regexp_replace(p.prosrc, '/\*.*?\*/', ' ', 'gs'), '--[^\n]*', ' ', 'g')
    into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_can_many';
  if v is null then
    raise exception 'อ่าน prosrc ของ fn_can_many ไม่ได้ — ไม่ยอมผ่านด้วยชุดว่าง';
  end if;
  if v !~ 'fn_can\s*\(' then
    raise exception 'fn_can_many ไม่ได้เรียก fn_can → เกณฑ์สิทธิ์ถูกเขียนซ้ำเป็นที่ที่สอง';
  end if;
  if v ~ 'role_permissions|app_users' then
    raise exception 'fn_can_many อ่านตารางสิทธิ์เอง → กฎสองที่ (ต้องถาม fn_can เท่านั้น)';
  end if;

  /**
   * (ง) **พฤติกรรมต้องตรงกับ `fn_can` ทุกสิทธิ์** — เทียบของจริง ไม่ใช่เชื่อโค้ด
   *
   * ใน migration ไม่มีผู้ล็อกอิน (`auth.uid()` เป็น null) ซึ่งคือเคส fail-closed:
   * ทั้งสองตัวต้องตอบ false เท่ากันทุกสิทธิ์ · ถ้าตัวใหม่ดันตอบ true ตอนไม่มีคน
   * ล็อกอิน นั่นคือรูที่ร้ายแรงที่สุดของฟังก์ชันนี้ และจับได้ที่นี่
   *
   * การเทียบ **ทุกบทบาท × ทุกสิทธิ์** ต้องสวมสิทธิ์ผู้ใช้จริง ซึ่ง migration
   * ทำไม่ได้แบบที่พอร์ตได้ (ของจริง `auth.uid()` อ่านจาก JWT ไม่ใช่ GUC)
   * → อยู่ที่ `supabase/tests/zz_fn_can_many_test.sql` ซึ่งสวมได้ทั้ง 4 บทบาท
   */
  select count(*) into n from sri_os.permissions;
  if n = 0 then
    raise exception 'ตาราง permissions ว่างเปล่า — ด่านข้อนี้จะผ่านฟรีๆ ไม่ยอม';
  end if;
  select string_agg(x.key, ', ') into v_bad
    from (select p.key, sri_os.fn_can(p.key) as one,
                 (select m.allowed from sri_os.fn_can_many(array[p.key]) m) as many
            from sri_os.permissions p) x
   where x.one is distinct from x.many or coalesce(x.many, true) <> false;
  if v_bad is not null then
    raise exception 'fn_can_many ตอบไม่ตรงกับ fn_can (หรือไม่ได้ fail-closed ตอนไม่มีผู้ล็อกอิน) ที่สิทธิ์: %', v_bad;
  end if;

  -- (จ) เคสขอบ: อาร์เรย์ว่าง/null ต้องไม่พัง และสิทธิ์ที่ไม่มีจริงต้องได้ false
  if (select count(*) from sri_os.fn_can_many(array[]::text[])) <> 0 then
    raise exception 'อาร์เรย์ว่างต้องคืน 0 แถว';
  end if;
  if (select count(*) from sri_os.fn_can_many(null)) <> 0 then
    raise exception 'null ต้องคืน 0 แถว ไม่ใช่ error';
  end if;
  if (select m.allowed from sri_os.fn_can_many(array['ไม่มีสิทธิ์นี้อยู่จริง']) m) <> false then
    raise exception 'สิทธิ์ที่ไม่มีอยู่จริงต้องได้ false';
  end if;

  raise notice 'ok · fn_can_many พร้อมใช้ · ถาม % สิทธิ์ได้ใน round trip เดียว · เรียก fn_can ตัวเดิมข้างใน (กฎอยู่ที่เดียว) · invoker · authenticated เท่านั้น',
    n;
end $$;
