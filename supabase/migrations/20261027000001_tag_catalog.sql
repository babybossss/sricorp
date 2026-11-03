-- ============================================================
-- SRI OS · **แค็ตตาล็อก tag** (ADR 0002 หัวข้อ 3.1-3.2 + ADR 0003 หัวข้อ 3.1)
--
-- คำสั่งต้นเรื่อง (ลูกพี่ 26/10): "ในทุก transaction อย่าลืมสร้าง function ที่สามารถ
-- tag project หรือ label ... สามารถ Filter มาดูทุก Transaction เวลาตรวจย้อนหลัง"
--
-- ------------------------------------------------------------
-- **สิ่งที่ไฟล์นี้ทำให้เป็นความจริงเดียว**
--
-- 1. `tag_kinds` = คอนฟิกของ "ชนิด tag" (กฎเหล็กข้อ 5) · **เป็นตาราง ไม่ใช่ enum**
--    เพราะวันที่ลูกพี่เปลี่ยนใจให้ `project` ติดได้อันเดียว มันคือการแก้แถวคอนฟิก
--    + migration backfill ไม่ใช่การรื้อ schema (ADR 0002 หัวข้อ 4.3 ทางเลือก B)
--    `requires_allocation` / `allocation_note_th` ของ ADR 0003 **อยู่ในไฟล์นี้เลย**
--    ไม่รอ migration ตามมาแก้ตารางที่เพิ่งสร้าง (seed: project = true · label = false)
--
-- 2. `tags` = แค็ตตาล็อก **ของกองกลาง** · **ไม่มี `owner_id`** เหมือน
--    `chart_of_accounts` / `txn_types` / `contacts` — project ของบ้านนี้ข้ามผู้ถือจริง
--    (ทรัพย์เล็กอยู่ชื่อบุคคล ทรัพย์ใหญ่อยู่บริษัท ใบของ project เดียวกันจึงอยู่คนละผู้ถือ)
--    ถ้าผูก tag กับ owner จะต้องสร้าง tag ชื่อเดียวกัน 8 ชุด = ปัญหาพิมพ์ผิดกลับมา
--    ทางหลังบ้าน ซึ่งคือเหตุผลที่ลูกพี่สั่งให้ "ตั้งไว้ก่อนแล้วเลือก" ตั้งแต่ต้น
--    กฎเหล็กข้อ 3 ไม่ถูกละเมิด เพราะมันใช้กับ **แถวที่มีความเป็นเจ้าของ/มีเงิน** —
--    แถวที่มีเงินคือ `transaction_tags` (ไฟล์ถัดไป) ซึ่ง **ทุกแถวมี `owner_id`**
--
-- 3. **ปิดได้ · ห้ามลบ** ทั้งสองตาราง (`is_active = false` + `archived_at/by`)
--    ลบ tag ที่เคยใช้ = ลิงก์เก่าชี้ไปหาของที่ไม่มีอยู่ → **การกรองย้อนหลังไม่ครบ
--    โดยไม่มีใครรู้** ซึ่งคือความพังที่โจทย์ของลูกพี่กลัวตั้งแต่ต้น
--    (ตัวกรองในรายงานต้องแสดง tag ที่ปิดแล้วในกลุ่ม "ปิดใช้งาน" ไม่ใช่ให้หายไป)
--
-- 4. **tag ไม่ใช่กฎบัญชี** → ห้ามเข้า `src/lib/rules/` และ `sync:rules` /
--    `check:sync` ไม่เกี่ยวกับ tag เลย (ADR 0002 หัวข้อ 5 ข้อ 6)
--    ถ้าเอาเข้าไป ทุกครั้งที่ลูกพี่เพิ่ม project จะต้องเขียน migration
--    → ไฟล์นี้ **ไม่ seed project/label ตัวอย่างแม้แถวเดียว** · seed แค่ `tag_kinds` 2 แถว
--
-- 5. สิทธิ์ใหม่สองตัว `tag.assign` / `tag.catalog` เข้า `permissions` +
--    `role_permissions` · **ไม่มีชื่อ role ใน policy** (D-073 · กฎเหล็กข้อ 5)
--
-- ------------------------------------------------------------
-- **สิ่งที่ไฟล์นี้ตั้งใจไม่ทำ**
--   ไม่มี `parent_id` (tag ซ้อนชั้น) · ไม่มี `merged_into_id` (merge tag) ·
--   ไม่มี `owner_id` — ทั้งสามข้อเป็นความเสี่ยงที่ ADR 0002 หัวข้อ 8 ยอมรับไว้
--   และ **ห้ามเติมเงียบๆ** (บทเรียนข้อ 7 ของ mace-windu: เปิดฟีเจอร์ครึ่งเดียว
--   อันตรายกว่าไม่เปิด) · guard ท้ายไฟล์พังถ้ามีคอลัมน์สามชื่อนั้นโผล่มา
--
-- ลำดับ: **ต้องรันหลัง 20261006190000** (`permissions` · `fn_can`) ·
--   **หลัง 20261008000005** (`fn_audit` · `fn_audit_keyed`) ·
--   **หลัง 20261020000000** (ทะเบียนด่านคอลัมน์ D-089)
--   → วางต่อท้าย `20261026094500_catch_all_accounts_guard.sql`
--   ก่อน `20261027000002_tag_links.sql`
--
-- idempotent: create table if not exists · add constraint แบบ drop if exists ก่อน ·
--   insert ... on conflict · create or replace function ·
--   drop policy/trigger if exists ก่อน create (รันซ้ำได้ทั้ง DB เปล่าและ DB ที่ลงแล้ว)
--
-- ย้อนกลับ (rollback) — เรียงจากหลังมาหน้า:
--   -- delete from sri_os.column_exposure       where table_name in ('tags','tag_kinds');
--   -- delete from sri_os.column_exposure_tables where table_name in ('tags','tag_kinds');
--   -- select sri_os.fn_apply_column_exposure();
--   -- drop table if exists sri_os.tags;       (** แค็ตตาล็อกหายถาวร — ต้อง dump ก่อน **)
--   -- drop table if exists sri_os.tag_kinds;
--   -- drop function if exists sri_os.fn_tag_catalog_columns(), sri_os.fn_tag_kind_columns(),
--   --   sri_os.fn_tag_catalog_no_delete();
--   -- delete from sri_os.settings where key = 'tags.color_tokens';
--   -- delete from sri_os.role_permissions where permission_key in ('tag.assign','tag.catalog');
--   -- delete from sri_os.permissions     where key            in ('tag.assign','tag.catalog');
--   -- ** ต้องถอนสองคีย์ออกจาก src/lib/auth/permissions.ts ด้วย ไม่งั้น
--   --    npm run check:permissions พัง **
--   -- ย้อนแล้วได้สภาพเดิมคือ **ไม่มีที่เก็บ project/label เลย** และการกรองย้อนหลัง
--   --   ตามโจทย์ของลูกพี่ทำไม่ได้ · ไม่มีตัวเลขในงบเปลี่ยนแม้บาทเดียว (tag ไม่ใช่เงิน)
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 0 · pre-flight — ดังก่อนแตะอะไรเลยถ้าลำดับไม่ถูก
-- ============================================================
do $$
begin
  if to_regclass('sri_os.permissions') is null or to_regclass('sri_os.role_permissions') is null
     or to_regprocedure('sri_os.fn_can(text)') is null then
    raise exception 'ไม่มีตารางสิทธิ์/fn_can → ต้องรัน 20261006190000_roles_permissions.sql ก่อน (policy ของแค็ตตาล็อกอ่านสิทธิ์จากตาราง ไม่ใช่จากชื่อ role)';
  end if;
  if to_regprocedure('sri_os.fn_audit()') is null
     or to_regprocedure('sri_os.fn_audit_keyed()') is null
     or to_regprocedure('sri_os.fn_forbid_truncate()') is null then
    raise exception 'ไม่มี fn_audit/fn_audit_keyed/fn_forbid_truncate → ต้องรัน 20261008000004/20261008000005 ก่อน (ตารางใหม่ที่ไม่มีร่องรอยและกัน TRUNCATE ไม่ได้ = guard ทั้งระบบแดง)';
  end if;
  if to_regclass('sri_os.column_exposure_tables') is null
     or to_regprocedure('sri_os.fn_apply_column_exposure()') is null then
    raise exception 'ไม่มีทะเบียนด่านคอลัมน์ → ต้องรัน 20261020000000 ก่อน (ตารางใหม่ที่ไม่ขึ้นทะเบียน = guard D-089 แดง)';
  end if;
  if to_regclass('sri_os.settings') is null or to_regclass('sri_os.app_users') is null then
    raise exception 'ไม่มี settings/app_users → ต้องรัน 20260917000001_core.sql ก่อน';
  end if;
end $$;

-- ============================================================
-- 1 · สิทธิ์ใหม่สองตัว (ADR 0002 หัวข้อ 2 ข้อ 10 · หัวข้อ 5 ข้อ 7)
--
--     ชื่อคีย์ต้องผ่าน CHECK permissions_no_money_bypass (regex กันคีย์ปิดกฎเงิน)
--     ทั้งสองตัวผ่าน: ไม่มีคำว่า skip/waive/bypass/override/... และไม่ขึ้นต้นด้วย delete.
--     **tag ไม่ใช่ช่องปลดกฎเงิน** — ติด tag เปลี่ยนคู่บัญชีไม่ได้เลยเชิงโครงสร้าง
--     (ตารางแยก · `buildPosting()` ไม่รับและไม่คืน tag · ADR 0002 หัวข้อ 5 ข้อ 4)
-- ============================================================
insert into permissions (key, label, note) values
  ('tag.assign', 'ติด/ถอด tag บนรายการและร่าง',
   'ทุกตำแหน่งมี (ADR 0002 หัวข้อ 7) · ติดได้เฉพาะ tag ที่มีในแค็ตตาล็อกและยังเปิดใช้งาน · ถอดต้องมีเหตุผล · ขอบเขตยังถูกจำกัดด้วย fn_can_see_owner + policy ของใบเสมอ · สิทธิ์นี้ไม่ให้สิทธิ์แก้ตัวเลขหรือสร้าง tag ใหม่'),
  ('tag.catalog', 'ตั้งค่าแค็ตตาล็อก tag (tag_kinds · tags)',
   'Management ขึ้นไป · **Manager ไม่มี** เพราะชื่อ/รหัส tag เป็นแกนของการกรองย้อนหลังทั้งระบบ และ tag ซ้ำความหมาย (ไอริส235 กับ iris-235) แก้ย้อนหลังไม่ได้ในรอบนี้ (ไม่มี merge · ADR 0002 หัวข้อ 8 ข้อ 1) · พิมพ์สร้าง tag จากฟอร์มรายการไม่ได้ทุกตำแหน่ง')
on conflict (key) do update
  set label = excluded.label, note = excluded.note;

-- การจับคู่ตั้งต้นตาม ADR 0002 หัวข้อ 7 (staff ติด tag ได้ · manager ตั้งแค็ตตาล็อกไม่ได้)
-- on conflict do nothing = รัน migration ซ้ำไม่ทับของที่ปรับไว้ภายหลังด้วย migration อื่น
insert into role_permissions (role_key, permission_key)
select r.key, p.key
  from (values
    -- permission     super_admin  management  manager  staff
    ('tag.assign',   true,  true,  true,  true),
    ('tag.catalog',  true,  true,  false, false)
  ) as p(key, super_admin, management, manager, staff)
  cross join lateral (values
    ('super_admin', p.super_admin),
    ('management',  p.management),
    ('manager',     p.manager),
    ('staff',       p.staff)
  ) as r(key, allowed)
 where r.allowed
on conflict (role_key, permission_key) do nothing;

-- ============================================================
-- 2 · โทเคนสีของ chip — **เก็บชื่อโทเคน ไม่เก็บ hex** (กติกา UI)
--     รายชื่อที่อนุญาตอยู่ใน `settings` (กฎเหล็กข้อ 5) ไม่ hard-code ใน trigger
--     ของจริงมาจาก `tailwind.config.ts` → หน้าจอแปลงชื่อโทเคนเป็น class เอง
--     ถ้าเก็บ hex: สีของ chip จะหลุดออกจากชุดสีของระบบทีละอัน และโหมดตัวใหญ่/
--     คอนทราสต์ที่ตั้งไว้ในโทเคนจะใช้ไม่ได้ (ผู้ใช้มีผู้สูงอายุ · ห้ามลดมาตรฐาน)
-- ============================================================
insert into settings (key, value) values
  ('tags.color_tokens',
   '["brand", "ink", "pos", "neg", "warn", "info", "holder.corp", "holder.person", "holder.group"]'::jsonb)
on conflict (key) do nothing;

-- ============================================================
-- 3 · `tag_kinds` — คอนฟิกของชนิด tag
-- ============================================================
create table if not exists tag_kinds (
  key                 text primary key,
  name_th             text not null,
  name_en             text not null,
  /** ติดได้หลายอันต่อใบหรือไม่ · **seed = true ทั้งสองชนิด** (คำสั่ง 26/10) */
  allows_multi        boolean not null,
  /**
   * ประโยคที่ทุกตาราง/การ์ด/export ต่อ tag **ต้อง** แสดง (ADR 0002 หัวข้อ 4 ชั้น 3)
   * มาจาก DB ไม่ใช่จากหน้าจอ → ลืมใส่ = component โยน error ตอน dev
   * ไม่ใช่เลขเปลือยตอนผู้ใช้อ่าน
   */
  aggregate_note_th   text not null,
  /** ADR 0003 · ชนิดนี้ต้องถ่วงน้ำหนักให้ Σ = 100% ต่อใบหรือไม่ (project = true) */
  requires_allocation boolean not null default false,
  /** ADR 0003 · ประโยคกำกับของวิวที่ปันส่วนแล้ว (ใช้แทน aggregate_note_th) */
  allocation_note_th  text,
  sort_order          integer not null default 100,
  is_active           boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

comment on table tag_kinds is
  'คอนฟิกของชนิด tag (ADR 0002 หัวข้อ 3.1 + ADR 0003 หัวข้อ 3.1) · **เป็นตาราง ไม่ใช่ enum** ตามกฎเหล็กข้อ 5 · allows_multi/requires_allocation เป็นคานที่พลิกได้ด้วยคอนฟิก + migration backfill ไม่ใช่การรื้อ schema · aggregate_note_th คือประโยคที่ทุกตารางต่อ tag ต้องแสดง (ห้ามพิมพ์ในหน้าจอ)';
comment on column tag_kinds.allows_multi is
  'false = ใบหนึ่งติด tag ชนิดนี้ได้อันเดียว · บังคับด้วย partial unique index tag_link_single_uq ที่ predicate อ่านจากสำเนาคอนฟิกในแถวลิงก์ ไม่ใช่จากชื่อชนิดที่พิมพ์ในโค้ด';
comment on column tag_kinds.requires_allocation is
  'ADR 0003 · true = ต้องมีน้ำหนักที่ Σ = 1.000000 พอดีต่อ (ใบ × ชนิด) → ยอดต่อ tag บวกกันได้ · false = ยอดเป็น touch บวกข้าม tag ไม่ได้';

-- ประโยคกำกับว่างไม่ได้ — ชั้น 3 ของ ADR 0002 หัวข้อ 4 จะกลายเป็นข้อความเปล่า
-- แล้วผู้ใช้จะเห็นยอดต่อ tag โดยไม่มีอะไรบอกว่าบวกกันไม่ได้
alter table tag_kinds drop constraint if exists tag_kinds_note_not_blank;
alter table tag_kinds add constraint tag_kinds_note_not_blank
  check (length(btrim(aggregate_note_th)) >= 20);

alter table tag_kinds drop constraint if exists tag_kinds_names_not_blank;
alter table tag_kinds add constraint tag_kinds_names_not_blank
  check (btrim(name_th) <> '' and btrim(name_en) <> '');

-- **เงื่อนไขสองทาง** ของ ADR 0003: ชนิดที่ปันส่วนต้องมีประโยคกำกับของตัวเอง
-- และชนิดที่ไม่ปันส่วนต้องไม่มี (ข้อความค้างไว้ = วันหนึ่งมีคนหยิบไปแสดงผิดบริบท)
alter table tag_kinds drop constraint if exists tag_kinds_allocation_note_both_ways;
alter table tag_kinds add constraint tag_kinds_allocation_note_both_ways check (
  (requires_allocation
     and allocation_note_th is not null and length(btrim(allocation_note_th)) >= 20)
  or (not requires_allocation and allocation_note_th is null)
);

-- คีย์ของชนิดใช้ในชื่อคอลัมน์สำเนา (`transaction_tags.tag_kind`) และใน URL
alter table tag_kinds drop constraint if exists tag_kinds_key_shape;
alter table tag_kinds add constraint tag_kinds_key_shape
  check (key ~ '^[a-z][a-z0-9_]{1,30}$');

-- ---------- seed สองชนิด (ADR 0002 หัวข้อ 5 ข้อ 6: มีแค่นี้ ไม่มี project ตัวอย่าง) ----------
insert into tag_kinds (key, name_th, name_en, allows_multi, aggregate_note_th,
                       requires_allocation, allocation_note_th, sort_order, is_active) values
  ('project', 'โปรเจกต์', 'Project', true,
   'ยอดที่แตะ tag นี้ · ใบที่ติดหลาย tag ถูกนับในทุก tag ที่ติด — เอายอดของแต่ละ tag มาบวกกันไม่ได้ · ยอดรวมที่ถูกดูที่ "ยอดรวมของชุดที่กรอง"',
   true,
   -- **ประโยคนี้ผู้ใช้เห็นในฟอร์มและในทุกตารางต่อ tag** จึงต้องตรงกับกฎที่ระบบบังคับจริง
   -- รุ่นแรกเขียนว่า "เศษจากการปัดตกที่โปรเจกต์ที่น้ำหนักมากที่สุด" ซึ่ง **ผิด** และ
   -- ADR 0003 ข้อ 4.2 มีตารางพิสูจน์ไว้เอง: การปัดรายบรรทัดทำให้ double entry
   -- **ต่อ tag ไม่ดุล** (เดบิต 0.06 / เครดิต 0.05) ขณะที่ยอดรวมทั้งสมุดยังตรง
   -- → ไม่มีด่านไหนฟ้อง · กฎจริงคือ **ไม่ปัดตอนปันส่วน** ปัดเฉพาะตอนแสดงผล (ข้อ 4.2.1)
   'ส่วนแบ่งของโปรเจกต์นี้ตามน้ำหนักที่บันทึกไว้ (Σ น้ำหนัก = 100% ต่อใบ) · ยอดของทุกโปรเจกต์บวกกันได้และเท่ากับยอดในสมุดพอดี · ระบบ **ไม่ปัดเศษตอนปันส่วน** (ปัดเฉพาะตัวเลขก้อนสุดท้ายที่แสดงบนหน้าจอ และยอดที่แสดงยังบวกกันได้เท่ายอดจริง) จึงทำให้งบของแต่ละโปรเจกต์ยังดุลทั้งสองฝั่ง',
   10, true),
  ('label', 'ป้ายกำกับ', 'Label', true,
   'ยอดที่แตะ tag นี้ · ใบที่ติดหลาย tag ถูกนับในทุก tag ที่ติด — เอายอดของแต่ละ tag มาบวกกันไม่ได้ · ยอดรวมที่ถูกดูที่ "ยอดรวมของชุดที่กรอง"',
   false, null, 20, true)
on conflict (key) do update
  set name_th             = excluded.name_th,
      name_en             = excluded.name_en,
      aggregate_note_th   = excluded.aggregate_note_th,
      allocation_note_th  = excluded.allocation_note_th,
      sort_order          = excluded.sort_order
  -- **ไม่ทับ** allows_multi / requires_allocation / is_active: สามค่านี้เป็นคานที่มี
  -- ผลต่อการนับซ้ำและต่อสำเนาในแถวลิงก์ · ถ้า migration ซ้ำมาทับค่าที่ migration
  -- ภายหลัง backfill ไว้ ลิงก์ที่มีอยู่จะขัดกับคอนฟิกเงียบๆ (ADR 0002 หัวข้อ 4.3)
  where tag_kinds.allows_multi = excluded.allows_multi
    and tag_kinds.requires_allocation = excluded.requires_allocation;

-- ============================================================
-- 4 · `tags` — แค็ตตาล็อก (ของกองกลาง · ไม่มี owner_id)
-- ============================================================
create table if not exists tags (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null references tag_kinds(key) on update cascade on delete restrict,
  /** รหัสคงที่ ใช้ใน URL/filter · unique ทั้งระบบ (กัน tag ซ้ำความหมายได้บางส่วน) */
  code        text not null,
  name_th     text not null,
  name_en     text,
  description text,
  /** ชื่อโทเคนสีจาก tailwind.config.ts · **ห้ามเก็บ hex** (ตรวจที่ trigger จาก settings) */
  color_token text,
  is_active   boolean not null default true,
  archived_at timestamptz,
  archived_by uuid references app_users(id),
  created_at  timestamptz not null default now(),
  created_by  uuid references app_users(id),
  updated_at  timestamptz not null default now()
);

comment on table tags is
  'แค็ตตาล็อก tag (ADR 0002 หัวข้อ 3.2) · **ของกองกลาง ไม่มี owner_id** เหมือน chart_of_accounts/txn_types เพราะ project ของบ้านนี้ข้ามผู้ถือจริง · **ปิดได้ ห้ามลบ** (ลบแล้วการกรองย้อนหลังไม่ครบโดยไม่มีใครรู้) · ไม่มี parent_id และไม่มี merged_into_id ในรอบนี้ (ADR 0002 หัวข้อ 8 — ห้ามเติมเงียบๆ ต้องมี ADR ใหม่)';
comment on column tags.code is
  'รหัสคงที่ตัวเล็ก ใช้ใน URL และตัวกรอง · **แก้ย้อนหลังไม่ได้** (trigger) เพราะลิงก์/บุ๊กมาร์ก/ไฟล์ export ที่ออกไปแล้วอ้างค่านี้';
comment on column tags.is_active is
  'false = ซ่อนจาก **ตัวเลือกตอนติด tag เท่านั้น** · ลิงก์เก่าไม่ถูกแตะ และตัวกรองในรายงานต้องแสดง tag ที่ปิดแล้วในกลุ่ม "ปิดใช้งาน" ไม่ใช่ให้หายไป';

alter table tags drop constraint if exists tags_code_shape;
alter table tags add constraint tags_code_shape
  check (code ~ '^[a-z0-9][a-z0-9._-]{1,48}$');

alter table tags drop constraint if exists tags_code_uq;
do $$
begin
  if not exists (select 1 from pg_class where relname = 'tags_code_uq'
                   and relnamespace = 'sri_os'::regnamespace) then
    create unique index tags_code_uq on tags (code);
  end if;
end $$;

alter table tags drop constraint if exists tags_name_not_blank;
alter table tags add constraint tags_name_not_blank
  check (btrim(name_th) <> '');

-- **เงื่อนไขสองทาง** เหมือน void_reason ของ D-098: ปิดแล้วต้องรู้ว่าใครปิดเมื่อไหร่
-- และยังเปิดอยู่ก็ต้องไม่มีร่องรอยการปิดค้างไว้ (ไม่งั้นมี tag ที่ดูเหมือนปิดแต่ยังเลือกได้)
alter table tags drop constraint if exists tags_archive_both_ways;
alter table tags add constraint tags_archive_both_ways check (
      (is_active = false) = (archived_at is not null)
  and (is_active = false) = (archived_by is not null)
);

-- สีต้องเป็นชื่อโทเคน ไม่ใช่ hex — ชั้น constraint กันรูป ชั้น trigger กันว่ามีจริงใน settings
alter table tags drop constraint if exists tags_color_token_shape;
alter table tags add constraint tags_color_token_shape
  check (color_token is null or color_token ~ '^[a-z][a-z0-9]*(\.[a-z0-9]+)?$');

create index if not exists tags_by_kind_idx on tags (kind, code);
create index if not exists tags_active_idx on tags (is_active, kind, code);

-- ============================================================
-- 5 · คอลัมน์ที่ระบบตั้งเอง + ของที่แก้ย้อนหลังไม่ได้
--
--     แพทเทิร์นเดียวกับ `fn_txn_system_columns` (20261008000011):
--     ทับ `created_by` ด้วย `auth.uid()` **เฉพาะคำขอที่อยู่ใต้ RLS** เพื่อไม่ปิดทาง
--     migration/fixture ที่ตั้งค่าเป็นของผู้ใช้คนอื่นโดยตั้งใจ (ซึ่งเป็นไฟล์ใน git อยู่แล้ว)
-- ============================================================
create or replace function fn_tag_catalog_columns() returns trigger
language plpgsql set search_path = '' as $fn$
declare
  v_uid    uuid := auth.uid();
  v_rls    boolean := pg_catalog.row_security_active('sri_os.tags'::regclass);
  v_tokens jsonb;
begin
  if tg_op = 'INSERT' then
    new.created_at := now();
    new.updated_at := now();
    if v_uid is not null and v_rls then
      new.created_by := v_uid;
    end if;
  else
    -- รหัสและชนิดแช่แข็ง: `code` อยู่ใน URL/ไฟล์ export ที่ออกไปแล้ว ·
    -- `kind` ถูกคัดลอกไว้ในทุกแถวลิงก์ (`transaction_tags.tag_kind`) → เปลี่ยนที่นี่
    -- ทีหลังแปลว่าสำเนาในลิงก์เก่ากับของจริงเล่าเรื่องคนละเรื่อง
    if new.code is distinct from old.code then
      raise exception 'แก้รหัส tag ย้อนหลังไม่ได้ (% → %) · รหัสอยู่ใน URL ตัวกรอง และไฟล์ export ที่ออกไปแล้ว · ถ้ารหัสผิดให้ปิดตัวเดิม (is_active = false) แล้วสร้างตัวใหม่',
        old.code, new.code;
    end if;
    if new.kind is distinct from old.kind then
      raise exception 'ย้ายชนิดของ tag ย้อนหลังไม่ได้ (% → %) · ชนิดถูกคัดลอกไว้ในทุกแถวลิงก์ (transaction_tags.tag_kind) และเป็นตัวตัดสินว่าใบนั้นต้องถ่วงน้ำหนักหรือไม่ — ย้ายแล้วลิงก์เก่าจะขัดกับคอนฟิกเงียบๆ',
        old.kind, new.kind;
    end if;
    new.id         := old.id;
    new.created_at := old.created_at;
    new.updated_at := now();
    if v_rls then
      new.created_by := old.created_by;
    end if;

    -- ปิด/เปิดใช้งาน: เติมร่องรอยให้เอง (คนที่ทำคือคนที่ล็อกอินอยู่ · ปลอมไม่ได้)
    if old.is_active and not new.is_active then
      new.archived_at := coalesce(new.archived_at, now());
      if v_uid is not null then
        new.archived_by := v_uid;
      end if;
    elsif not old.is_active and new.is_active then
      -- เปิดคืนได้ (ปิดผิดตัวเกิดขึ้นจริง) และร่องรอยการปิดครั้งก่อนอยู่ใน audit_log
      new.archived_at := null;
      new.archived_by := null;
    elsif not new.is_active then
      -- ปิดอยู่แล้ว: ร่องรอยการปิดแช่แข็ง (แพทเทิร์น fn_void_audit_columns)
      new.archived_at := old.archived_at;
      new.archived_by := old.archived_by;
    end if;
  end if;

  -- สีต้องเป็นโทเคนที่ประกาศไว้ใน settings (กฎเหล็กข้อ 5 · ไม่ hard-code ที่นี่)
  if new.color_token is not null then
    select s.value into v_tokens from sri_os.settings s where s.key = 'tags.color_tokens';
    if v_tokens is null or jsonb_typeof(v_tokens) <> 'array' then
      raise exception 'ไม่มีรายชื่อโทเคนสีใน settings (key = tags.color_tokens) หรือค่าไม่ใช่ array → ตั้งสีของ tag ไม่ได้ · ค่านี้เป็นคอนฟิกตามกฎเหล็กข้อ 5 ไม่ได้ hard-code ในโค้ด';
    end if;
    if not (v_tokens ? new.color_token) then
      raise exception 'โทเคนสี "%" ไม่อยู่ในรายชื่อที่อนุญาต (settings.tags.color_tokens = %) · chip ต้องใช้โทเคนจาก tailwind.config.ts เท่านั้น **ห้ามเก็บ hex** ไม่งั้นสีจะหลุดออกจากชุดสีของระบบทีละอันและคอนทราสต์ที่ตั้งไว้เพื่อผู้ใช้สูงอายุจะใช้ไม่ได้',
        new.color_token, v_tokens::text;
    end if;
  end if;

  return new;
end $fn$;

comment on function fn_tag_catalog_columns() is
  'คอลัมน์ที่ระบบตั้งเองของ tags: created_at/updated_at · created_by = auth.uid() (เฉพาะคำขอใต้ RLS) · code/kind/id/created_* แก้ย้อนหลังไม่ได้ · ร่องรอยการปิดใช้งานเติมเองและแช่แข็ง · โทเคนสีต้องอยู่ใน settings.tags.color_tokens (ห้าม hex)';

revoke all on function fn_tag_catalog_columns() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_tag_catalog_columns() from anon, authenticated';
exception when undefined_object then null;   -- เครื่องที่ไม่มี role ของ Supabase
end $$;

drop trigger if exists trg_tag_catalog_columns on tags;
create trigger trg_tag_catalog_columns
  before insert or update on tags
  for each row execute function fn_tag_catalog_columns();

-- ------------------------------------------------------------
-- คอนฟิกของชนิด: คีย์แช่แข็ง · และ **พลิกคานด้วย UPDATE เฉยๆ ไม่ได้**
--
-- `allows_multi` / `requires_allocation` เป็นค่าที่ถูก **คัดลอก** ไว้ในแถวลิงก์
-- (`single_per_txn`) และเป็นเงื่อนไขของด่านน้ำหนัก → พลิกค่าตอนที่มีลิงก์อยู่แล้ว
-- โดยไม่ backfill = ใบเก่าขัดกับคอนฟิกเงียบๆ (ADR 0002 หัวข้อ 4.3 สั่งให้
-- การพลิกมาพร้อม migration backfill) · ด่านนี้บังคับให้เป็นอย่างนั้น
-- ------------------------------------------------------------
create or replace function fn_tag_kind_columns() returns trigger
language plpgsql set search_path = '' as $fn$
declare n int;
begin
  if tg_op = 'INSERT' then
    new.created_at := now();
    new.updated_at := now();
    return new;
  end if;

  new.key        := old.key;
  new.created_at := old.created_at;
  new.updated_at := now();

  if (new.allows_multi is distinct from old.allows_multi
      or new.requires_allocation is distinct from old.requires_allocation)
     and to_regclass('sri_os.transaction_tags') is not null then
    execute 'select count(*) from sri_os.transaction_tags l join sri_os.tags t on t.id = l.tag_id'
            || ' where t.kind = $1 and l.untagged_at is null'
      into n using old.key;
    if n > 0 then
      raise exception 'พลิกคอนฟิกของชนิด "%" ตอนที่ยังมีลิงก์ที่ใช้งานอยู่ % แถวไม่ได้ (allows_multi % → % · requires_allocation % → %) · ค่าสองตัวนี้ถูกคัดลอกไว้ในแถวลิงก์และเป็นเงื่อนไขของด่านน้ำหนัก → ต้องพลิกใน **migration ที่ backfill ลิงก์ทั้งตารางพร้อมกัน** (ADR 0002 หัวข้อ 4.3) · ถ้ามีใบที่ติด tag ชนิดนี้เกินหนึ่งอันอยู่ migration นั้นจะพังที่ index ซึ่งถูกแล้ว — ต้องตัดสินว่าจะเอาอันไหน ไม่ใช่ให้ระบบเลือกเงียบๆ',
        old.key, n, old.allows_multi, new.allows_multi,
        old.requires_allocation, new.requires_allocation;
    end if;
  end if;

  return new;
end $fn$;

comment on function fn_tag_kind_columns() is
  'คอนฟิกชนิด tag: key แช่แข็ง · updated_at ตั้งเอง · **พลิก allows_multi/requires_allocation ด้วย UPDATE เฉยๆ ไม่ได้เมื่อมีลิงก์ที่ใช้งานอยู่** (ต้องมาพร้อม migration ที่ backfill — ไม่งั้นใบเก่าขัดกับคอนฟิกเงียบๆ)';

revoke all on function fn_tag_kind_columns() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_tag_kind_columns() from anon, authenticated';
exception when undefined_object then null;
end $$;

drop trigger if exists trg_tag_kind_columns on tag_kinds;
create trigger trg_tag_kind_columns
  before insert or update on tag_kinds
  for each row execute function fn_tag_kind_columns();

-- ============================================================
-- 6 · **ปิดได้ ห้ามลบ** — กันถึงชั้นเจ้าของฐานข้อมูล ไม่ใช่แค่ไม่มี policy
--
--     FK `on delete restrict` ของ `transaction_tags.tag_id` กันแค่ tag ที่ถูกใช้แล้ว
--     ส่วนตัวที่ยังไม่ถูกใช้ ถ้าลบได้ **รหัสจะถูกนำกลับมาใช้ใหม่ได้** แล้ว URL/
--     ไฟล์ export เก่าที่อ้างรหัสนั้นจะชี้ไปหา tag คนละตัวโดยไม่มีอะไรฟ้อง
-- ============================================================
create or replace function fn_tag_catalog_no_delete() returns trigger
language plpgsql set search_path = '' as $fn$
begin
  raise exception 'ลบแถวของ %I ไม่ได้ทุกกรณีทุกผู้ใช้ (รวมเจ้าของฐานข้อมูล) · แค็ตตาล็อก tag **ปิดได้ ห้ามลบ**: ใช้ is_active = false แล้วมันจะหายจากตัวเลือกตอนติด tag แต่ยังโผล่ในตัวกรองย้อนหลังในกลุ่ม "ปิดใช้งาน" · ลบทิ้งแปลว่าการกรองย้อนหลังไม่ครบโดยไม่มีใครรู้ และรหัสเดิมถูกนำกลับมาใช้กับของคนละตัวได้',
    tg_table_name;
end $fn$;

comment on function fn_tag_catalog_no_delete() is
  'แค็ตตาล็อก tag ลบไม่ได้ทุกทาง (ปิดด้วย is_active = false แทน) · กันทางเจ้าของฐานข้อมูลด้วย เหมือนกฎเงินอื่น';

revoke all on function fn_tag_catalog_no_delete() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_tag_catalog_no_delete() from anon, authenticated';
exception when undefined_object then null;
end $$;

drop trigger if exists trg_tags_no_delete on tags;
create trigger trg_tags_no_delete
  before delete on tags
  for each row execute function fn_tag_catalog_no_delete();

drop trigger if exists trg_tag_kinds_no_delete on tag_kinds;
create trigger trg_tag_kinds_no_delete
  before delete on tag_kinds
  for each row execute function fn_tag_catalog_no_delete();

-- ============================================================
-- 7 · RLS — อ่านได้ทุกคนที่ล็อกอิน (ชื่อ tag ไม่ใช่ตัวเลขเงิน) · เขียน = tag.catalog
--
--     ความเสี่ยงที่ ADR 0002 หัวข้อ 5 ข้อ 2 ยอมรับไว้ตรงๆ:
--     **ชื่อ project ทุกคนที่ล็อกอินเห็น** · ถ้าวันหนึ่งมี project ที่ชื่อเป็นความลับ
--     ต้องทำ ADR ใหม่ — **ห้ามแอบเติม `owner_id` ลง `tags` ครึ่งทาง** (บทเรียนข้อ 7)
--     **ไม่มี policy DELETE เลย** (คู่กับ trigger ข้อ 6)
-- ============================================================
alter table tag_kinds enable row level security;
alter table tags      enable row level security;

drop policy if exists tag_kinds_read on tag_kinds;
create policy tag_kinds_read on tag_kinds
  for select to authenticated
  using (true);

drop policy if exists tag_kinds_write on tag_kinds;
create policy tag_kinds_write on tag_kinds
  for update to authenticated
  using (fn_can('tag.catalog'))
  with check (fn_can('tag.catalog'));

drop policy if exists tag_kinds_insert on tag_kinds;
create policy tag_kinds_insert on tag_kinds
  for insert to authenticated
  with check (fn_can('tag.catalog'));

drop policy if exists tags_read on tags;
create policy tags_read on tags
  for select to authenticated
  using (true);

drop policy if exists tags_insert on tags;
create policy tags_insert on tags
  for insert to authenticated
  with check (fn_can('tag.catalog'));

drop policy if exists tags_update on tags;
create policy tags_update on tags
  for update to authenticated
  using (fn_can('tag.catalog'))
  with check (fn_can('tag.catalog'));

-- ชั้น GRANT: DML สี่ตัวต้องครบทุกตาราง (เทสต์ P1 ของ zz_line_integrity_test
-- ไล่จาก information_schema) · ตัวที่กันการลบจริงคือ trigger + ไม่มี policy DELETE
-- `alter default privileges` ของ 20261007000001 ครอบให้แล้วถ้า role เดียวกัน —
-- ที่นี่เขียนซ้ำให้ชัดเพื่อไม่ต้องเชื่อว่า migration ทุกไฟล์รันด้วย role เดิม
grant select, insert, update, delete on tag_kinds, tags to authenticated;
do $$
begin
  execute 'revoke all on table sri_os.tag_kinds, sri_os.tags from anon';
exception when undefined_object then null;
end $$;

-- ============================================================
-- 8 · ร่องรอย (audit) + ห้าม TRUNCATE — กฎทั้งระบบ ไม่ใช่ทางเลือก
--
--     `tags` มี `id` แบบ uuid → ใช้ `fn_audit`
--     `tag_kinds` ไม่มี → ต้องใช้ `fn_audit_keyed('key')` ให้ตรงกับ primary key
--     (ด่านของ 20261008000005 ตรวจทั้งสองข้อนี้จาก pg_trigger จริง)
-- ============================================================
drop trigger if exists trg_audit_tags on tags;
create trigger trg_audit_tags
  after insert or update or delete on tags
  for each row execute function fn_audit();

drop trigger if exists trg_audit_tag_kinds on tag_kinds;
create trigger trg_audit_tag_kinds
  after insert or update or delete on tag_kinds
  for each row execute function fn_audit_keyed('key');

drop trigger if exists trg_forbid_truncate on tags;
create trigger trg_forbid_truncate
  before truncate on tags
  for each statement execute function fn_forbid_truncate();

drop trigger if exists trg_forbid_truncate on tag_kinds;
create trigger trg_forbid_truncate
  before truncate on tag_kinds
  for each statement execute function fn_forbid_truncate();

-- ============================================================
-- 9 · ด่านคอลัมน์ (D-089) — ตารางใหม่ที่ไม่ขึ้นทะเบียน = guard แดง
--
--     ทุกคอลัมน์เป็น `open` **โดยเจตนา**: แค็ตตาล็อกเป็นของกองกลางที่ทุกคนที่
--     ล็อกอินต้องอ่านได้เพื่อเลือก tag และเพื่อกรองย้อนหลัง · ไม่มีตัวเลขเงิน
--     ไม่มี owner_id และไม่มีข้อความที่ผู้ใช้เขียนเกี่ยวกับใบใดใบหนึ่ง
--     (แพทเทิร์นเดียวกับ chart_of_accounts / asset_categories / period_closes)
--     **ข้อความที่อ้างถึงใบและยอด** อยู่ใน `transaction_tags.tag_note` /
--     `untag_reason` ซึ่งไฟล์ถัดไปจัดเป็น `row` + `ledger.read`
-- ============================================================
insert into column_exposure_tables (table_name, review_state, reason) values
  ('tag_kinds', 'classified',
   'คอนฟิกชนิด tag (ADR 0002) · ไม่มีตัวเลขเงินและไม่ใช่ข้อมูลของผู้ถือใดผู้ถือหนึ่ง · อ่านได้ทุกคนที่ล็อกอินตามเจตนา เขียนได้เฉพาะ tag.catalog'),
  ('tags', 'classified',
   'แค็ตตาล็อก tag ของกองกลาง (ADR 0002 หัวข้อ 5 ข้อ 2) · ไม่มี owner_id และไม่มีตัวเลขเงิน · ยอมรับไว้ตรงๆ ว่าชื่อ project ทุกคนที่ล็อกอินเห็น ถ้าต้องเป็นความลับต้องทำ ADR ใหม่')
on conflict (table_name) do update
  set review_state = excluded.review_state, reason = excluded.reason;

insert into column_exposure (table_name, column_name, exposure, min_permission, rationale)
select t.tbl, c, 'open', null, t.why
  from (values
    ('tag_kinds', array[
      'key', 'name_th', 'name_en', 'allows_multi', 'aggregate_note_th',
      'requires_allocation', 'allocation_note_th', 'sort_order', 'is_active',
      'created_at', 'updated_at'
    ], 'คอนฟิกชนิด tag · aggregate_note_th/allocation_note_th **ต้องอ่านได้ทุกคน** เพราะทุกตารางต่อ tag บังคับแสดงประโยคนี้ (ADR 0002 หัวข้อ 4 ชั้น 3) ปิดแล้วหน้าจอจะแสดงยอดเปลือยหรือพัง'),
    ('tags', array[
      'id', 'kind', 'code', 'name_th', 'name_en', 'description', 'color_token',
      'is_active', 'archived_at', 'archived_by', 'created_at', 'created_by', 'updated_at'
    ], 'แค็ตตาล็อกที่ฟอร์มใช้เลือก tag และที่ตัวกรองย้อนหลังต้องใช้ (รวม tag ที่ปิดแล้ว ไม่งั้นการกรองย้อนหลังไม่ครบ) · ไม่มีตัวเลขเงิน ไม่มี owner_id · archived_* บอกว่าใครปิดเมื่อไหร่ ต้องอ่านคู่กับ is_active ที่มันอธิบาย')
  ) as t(tbl, cols, why), unnest(t.cols) c
on conflict (table_name, column_name) do update
  set exposure = excluded.exposure, min_permission = excluded.min_permission,
      rationale = excluded.rationale;

select fn_apply_column_exposure();

-- ============================================================
-- 10 · guard ท้ายไฟล์ — ดังตอน migrate ไม่ใช่ตอนผู้ใช้กด
-- ============================================================
do $$
declare v text; n int;
begin
  -- (ก) ตารางและ seed ต้องอยู่จริง
  if to_regclass('sri_os.tag_kinds') is null or to_regclass('sri_os.tags') is null then
    raise exception 'ตารางแค็ตตาล็อก tag ไม่ถูกสร้าง';
  end if;

  select count(*) into n from sri_os.tag_kinds;
  if n < 2 then
    raise exception 'seed ชนิด tag ไม่ครบ (เจอ % จาก 2: project · label)', n;
  end if;
  if not exists (select 1 from sri_os.tag_kinds where key = 'project' and requires_allocation)
     or exists (select 1 from sri_os.tag_kinds where key = 'label' and requires_allocation) then
    raise exception 'seed ของ requires_allocation ไม่ตรง ADR 0003 หัวข้อ 3.1 (project = true · label = false) → ด่าน Σ น้ำหนัก = 100%% จะครอบผิดชนิด';
  end if;

  -- (ข) ประโยคกำกับว่างไม่ได้ (ชั้น 3 ของ ADR 0002 หัวข้อ 4)
  select string_agg(key, ', ') into v from sri_os.tag_kinds
   where aggregate_note_th is null or length(btrim(aggregate_note_th)) < 20;
  if v is not null then
    raise exception 'ชนิด tag ที่ประโยคกำกับว่าง/สั้นเกิน: % · ทุกตารางต่อ tag บังคับแสดงประโยคนี้ ถ้าว่าง ผู้ใช้จะเห็นยอดต่อ tag โดยไม่มีอะไรบอกว่าบวกกันไม่ได้', v;
  end if;

  -- (ค) **ไม่มี owner_id / parent_id / merged_into_id ใน tags** (ADR 0002 หัวข้อ 3.2 · 8)
  select string_agg(a.attname, ', ') into v
    from pg_attribute a
   where a.attrelid = 'sri_os.tags'::regclass and a.attnum > 0 and not a.attisdropped
     and a.attname in ('owner_id', 'parent_id', 'merged_into_id');
  if v is not null then
    raise exception 'tags มีคอลัมน์ที่ ADR 0002 ตัดสินว่าไม่ทำในรอบนี้: % · owner_id = แค็ตตาล็อกเลิกเป็นของกองกลาง (ต้องมี ADR ใหม่) · parent_id = tag ซ้อนชั้นที่ยังไม่ได้ตัดสินเรื่องการนับซ้ำของชั้นแม่-ลูก · merged_into_id = merge ที่ยังไม่มีกฎว่ายอดเก่าจะย้ายไปไหน — ห้ามเติมเงียบๆ', v;
  end if;

  -- (ง) แค็ตตาล็อกห้ามมีคอลัมน์จำนวนเงิน (tag ไม่ใช่ตัวเลขที่เข้าสู่รายงานเงิน)
  select string_agg(c.relname || '.' || a.attname || ' (' || format_type(a.atttypid, null) || ')', ', ')
    into v
    from pg_class c
    join pg_attribute a on a.attrelid = c.oid
   where c.oid in ('sri_os.tags'::regclass, 'sri_os.tag_kinds'::regclass)
     and a.attnum > 0 and not a.attisdropped
     and a.atttypid in ('numeric'::regtype, 'money'::regtype,
                        'double precision'::regtype, 'real'::regtype);
  if v is not null then
    raise exception 'แค็ตตาล็อก tag มีคอลัมน์ชนิดตัวเลขเงิน: % · tag ต้องไม่มีน้ำหนักต่อตัวเลขในงบ (ADR 0002 หัวข้อ 5 ข้อ 4) · น้ำหนักของ ADR 0003 อยู่ใน tag_allocations ตารางแยก', v;
  end if;

  -- (จ) trigger ครบ (ไล่จาก pg_trigger จริง ไม่ใช่ไล่ไฟล์)
  select string_agg(x.rel || '/' || x.want, ', ') into v
    from (values ('tags', 'trg_tag_catalog_columns'), ('tags', 'trg_tags_no_delete'),
                 ('tags', 'trg_audit_tags'), ('tags', 'trg_forbid_truncate'),
                 ('tag_kinds', 'trg_tag_kind_columns'), ('tag_kinds', 'trg_tag_kinds_no_delete'),
                 ('tag_kinds', 'trg_audit_tag_kinds'), ('tag_kinds', 'trg_forbid_truncate')
         ) x(rel, want)
   where not exists (select 1 from pg_trigger g
                      where g.tgrelid = ('sri_os.' || x.rel)::regclass
                        and g.tgname = x.want and not g.tgisinternal);
  if v is not null then raise exception 'trigger หายไปจากแค็ตตาล็อก tag: %', v; end if;

  -- (ฉ) **ไม่มี policy DELETE** ของทั้งสองตาราง (ปิดได้ ห้ามลบ ที่ชั้น RLS ด้วย)
  select string_agg(p.polname, ', ') into v
    from pg_policy p
   where p.polrelid in ('sri_os.tags'::regclass, 'sri_os.tag_kinds'::regclass)
     and p.polcmd in ('d', '*');
  if v is not null then
    raise exception 'มี policy DELETE/ALL ของแค็ตตาล็อก tag (%) — ต้องไม่มี · ปิดด้วย is_active = false เท่านั้น', v;
  end if;

  -- (ช) RLS เปิดจริงทั้งสองตาราง (ปิดอยู่ = ไม่มีด่านเลย เพราะ grants ให้ DML ครบ)
  select string_agg(c.relname, ', ') into v
    from pg_class c
   where c.oid in ('sri_os.tags'::regclass, 'sri_os.tag_kinds'::regclass)
     and not c.relrowsecurity;
  if v is not null then raise exception 'RLS ยังปิดอยู่: %', v; end if;

  -- (ซ) สิทธิ์ใหม่ต้องอยู่ในตารางและผูกกับระดับแล้ว (ไม่มีชื่อ role ใน policy)
  select string_agg(k, ', ') into v
    from unnest(array['tag.assign', 'tag.catalog']) k
   where not exists (select 1 from sri_os.permissions p where p.key = k)
      or not exists (select 1 from sri_os.role_permissions rp where rp.permission_key = k);
  if v is not null then
    raise exception 'สิทธิ์ของ tag ยังไม่ครบในตารางสิทธิ์: % · policy อ่านสิทธิ์จากตาราง ถ้าไม่มีแถว ทุกคนจะติด tag ไม่ได้เลย', v;
  end if;
  if exists (select 1 from sri_os.role_permissions
              where permission_key = 'tag.catalog' and role_key = 'manager') then
    raise exception 'manager ได้ tag.catalog — ADR 0002 หัวข้อ 7 ตัดสินว่าแค็ตตาล็อกเป็นของ management ขึ้นไป (manager ติด/ถอด tag ได้ แต่สร้าง tag ไม่ได้)';
  end if;

  -- (ฌ) ด่านคอลัมน์ต้องไม่มีของค้างจากสองตารางนี้
  select string_agg(u.object_name || ': ' || u.problem, ' · ') into v
    from sri_os.fn_column_exposure_unclassified() u
   where u.object_name like 'tag%';
  if v is not null then
    raise exception 'ด่านคอลัมน์ยังมีของค้างจากแค็ตตาล็อก tag (D-089): %', v;
  end if;
  select string_agg(b.object_name || ': ' || b.problem, ' · ') into v
    from sri_os.fn_column_exposure_breaches() b
   where b.object_name like 'tag%';
  if v is not null then
    raise exception 'ด่านคอลัมน์ของแค็ตตาล็อก tag ไม่ติดจริง: %', v;
  end if;

  -- (ญ) ไม่มี tag ตัวอย่างหลุดมากับ migration (ADR 0002 หัวข้อ 5 ข้อ 6)
  select count(*) into n from sri_os.tags;
  if n > 0 then
    raise warning 'มี tag % แถวในแค็ตตาล็อกแล้ว · ไฟล์นี้ไม่ seed tag ตัวอย่างเลย (ตั้งที่หน้าตั้งค่าโดยสิทธิ์ tag.catalog) — ถ้ามาจาก migration ให้ตรวจว่าใครใส่', n;
  end if;

  raise notice 'แค็ตตาล็อก tag พร้อม: tag_kinds 2 ชนิด (project ปันส่วน · label touch) · tags ของกองกลางไม่มี owner_id · ปิดได้ห้ามลบทั้ง RLS และ trigger · รหัส/ชนิดแช่แข็ง · โทเคนสีมาจาก settings (ห้าม hex) · สิทธิ์ tag.assign/tag.catalog อยู่ในตารางสิทธิ์ · **ไม่มี tag ตัวอย่างแม้แถวเดียว**';
end $$;
