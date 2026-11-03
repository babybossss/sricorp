-- ============================================================
-- SRI OS · สิทธิ์โมดูลบริหารสินทรัพย์ + ตารางร่างทะเบียน `asset_drafts`
-- ปิด D-083 · ตามเอกสาร docs/DESIGN_ASSET_PERMISSIONS.md §7 ข้อ 1–7
--            + ADR docs/adr/0001-asset-draft-table.md
--
-- ปัญหาที่ไฟล์นี้แก้:
--   5 ตาราง (assets · bank_accounts · contracts · asset_valuations · schedules)
--   มีแต่ policy SELECT · **ไม่มี policy เขียนเลย** → ไม่มีใครเพิ่มทรัพย์/บัญชีธนาคาร/
--   สัญญาได้ แม้แต่ Management (RLS ที่ไม่มี policy สำหรับคำสั่งใด = ปฏิเสธคำสั่งนั้น)
--
-- ทำอะไร:
--   1. สิทธิ์ใหม่ 3 ตัว (12 → 15): asset.draft · asset.manage · asset.value
--      + การจับคู่ตำแหน่งตาม §1.2 · **insert จาก migration เท่านั้น** เพราะ
--      20261007000003 ถอน write policy ของ permissions/role_permissions ไว้แล้ว
--   2. enum asset_draft_status + ตาราง asset_drafts (4 ช่องบังคับเป็นคอลัมน์จริง ·
--      ที่เหลืออยู่ใน patch jsonb + whitelist trigger) · kind ∈ ('create','update')
--   3. policy ฝั่งเขียนของทั้ง 6 ตาราง · **แยกคำสั่งทุกตัว ไม่มี FOR ALL**
--      และ **ไม่มี policy DELETE บนทั้ง 5 ตาราง** (§5.4)
--   4. trigger กันขอบเขตเลื่อนเอง + สถานะงวดที่สะท้อน ledger + coa ของบัญชีธนาคาร
--   5. fn_apply_asset_draft() แบบ **security invoker** (ไม่ใช่ definer — definer
--      = ประตูหลังข้าม RLS · ADR ข้อ "การตัดสิน")
--   6. guard ท้ายไฟล์: ขยายการตรวจของ 11c ให้ครอบทั้ง 5 ตาราง · ตรวจว่าทุกตาราง
--      ใน sri_os เปิด RLS และมี policy (ครอบ asset_drafts ที่เพิ่มใหม่) ·
--      ตรวจว่าไม่มี FOR ALL / DELETE policy · ตรวจว่า trigger ไม่เรียก fn_can
--
-- ============================================================
-- ส่วนที่ **ต่างจากเอกสารออกแบบ** และเหตุผล (อ่านก่อนรีวิว)
-- ============================================================
-- ก) §7 ข้อ 5 ขอ `trg_asset_assign_guard` ให้เช็ค "เปลี่ยน manager_user_id ต้องมี
--    users.manage · เปลี่ยน owner_id ต้องมี settings.manage" **ที่ trigger**
--    → ทำที่ trigger ไม่ได้ เพราะเทสต์ข้อ 10 ของ roles_permissions_test.sql อ่าน
--      pg_proc แล้ว **พังทันทีถ้า trigger function ตัวใดอ้างถึง fn_can** (กฎเงินต้องไม่
--      ขึ้นกับตารางสิทธิ์) · trigger จึงเช็คสิทธิ์ไม่ได้เลยในสคีมานี้
--    → ย้ายส่วนที่เป็น "สิทธิ์" ไปอยู่ใน WITH CHECK ของ policy ผ่าน
--      fn_asset_assign_ok() ซึ่งอ่านค่า**เดิม**ของแถวจาก snapshot ของคำสั่ง
--      (กลไกเดียวกับที่ fn_can_see_asset() ใช้อยู่แล้วใน policy เดิม)
--      → ได้ผลเท่ากัน และ **ดีกว่า** ในแง่ "RLS เป็นด่านเดียว" ตามเจตนาของ ADR
--    → ส่วนที่เป็น "ข้อมูล" (owner_id เปลี่ยนไม่ได้ถ้ามี transaction_lines ผูกอยู่)
--      ยังเป็น trigger `trg_asset_assign_guard` ตามเอกสาร เพราะไม่พึ่งตารางสิทธิ์
--    หมายเหตุ: trigger นั้น **อ่าน** transaction_lines เพื่อเช็คว่ามีบรรทัดผูกอยู่ไหม
--      **ไม่เขียน** ตาราง ledger ใดๆ (กฎเหล็กข้อ 6) · เทสต์ที่ยืนยันข้อนี้ต้องดูว่า
--      "เขียน" ไม่ใช่ "เอ่ยชื่อตาราง" ไม่งั้นจะ false positive กับ trigger ตัวนี้
--
-- ข) §1.2 + คำตอบ Q3 บอกว่า Manager อนุมัติร่างทะเบียนของตัวเองได้ · แต่ §7 ข้อ 3
--    ให้ `assets_insert` ต้องมี `portfolio.view_all` (Manager ไม่มี) และ
--    fn_apply_asset_draft() เป็น **security invoker** จึงต้องผ่าน policy เดียวกัน
--    → ผลที่ตามมาตามตรรกะของเอกสารเอง: **Manager อนุมัติร่าง kind='create' ไม่ได้**
--      (อนุมัติ kind='update' ของทรัพย์ที่ตนบริหารได้) · ไม่ได้ผ่อนให้ เพราะทรัพย์ที่
--      เพิ่งสร้างยังไม่มี manager_user_id → Manager ที่สร้างก็มองไม่เห็นผลงานตัวเองอยู่ดี
--      (ทรัพย์ที่ไม่มีใครดูแล ≠ ของทุกคน) · ฟังก์ชันจึงคืน error ที่อ่านรู้เรื่องแทน
--      ข้อความ RLS ดิบ · **ถ้าลูกพี่ต้องการให้ Manager สร้างทรัพย์ได้จริง ต้องแก้
--      §7 ข้อ 3 (ถอด portfolio.view_all ออกจาก assets_insert) ไม่ใช่แก้ที่นี่**
--
-- ค) การตั้ง/ย้าย manager_user_id ต้องมี `users.manage` **ตั้งแต่ตอน INSERT** ไม่ใช่
--    เฉพาะตอน UPDATE · เอกสาร §3.2 พูดถึง "เปลี่ยน" แต่ถ้าปล่อยให้ตั้งตอน insert ได้
--    Management จะแจกสิทธิ์มองเห็นให้ Manager คนไหนก็ได้โดยไม่มี users.manage
--    = ช่องเดียวกันกับที่ §3.2 ตั้งใจปิด · เส้นทางที่ยังทำได้: สร้างทรัพย์แบบไม่มอบหมาย
--    แล้ว Super Admin มอบหมายภายหลัง (เหมือน user_owner_access ซึ่งเป็น users.manage)
--
-- ย้อนกลับ (rollback) — ลำดับสำคัญ:
--   -- 1. policy (ไม่มี DELETE policy ให้ถอน)
--   -- drop policy if exists assets_insert on sri_os.assets;
--   -- drop policy if exists assets_update on sri_os.assets;
--   -- drop policy if exists valuations_insert on sri_os.asset_valuations;
--   -- drop policy if exists contracts_insert on sri_os.contracts;
--   -- drop policy if exists contracts_update on sri_os.contracts;
--   -- drop policy if exists schedules_insert on sri_os.schedules;
--   -- drop policy if exists schedules_update on sri_os.schedules;
--   -- drop policy if exists bank_accounts_insert on sri_os.bank_accounts;
--   -- drop policy if exists bank_accounts_update on sri_os.bank_accounts;
--   -- 2. trigger
--   -- drop trigger if exists trg_asset_assign_guard on sri_os.assets;
--   -- drop trigger if exists trg_audit_assets on sri_os.assets;
--   -- drop trigger if exists trg_bank_account_coa_immutable on sri_os.bank_accounts;
--   -- drop trigger if exists trg_audit_bank_accounts on sri_os.bank_accounts;
--   -- drop trigger if exists trg_schedule_status_mirror on sri_os.schedules;
--   -- 3. ตารางร่าง (policy/trigger หายไปกับตาราง)
--   -- drop table if exists sri_os.asset_drafts;
--   -- drop type  if exists sri_os.asset_draft_status;
--   -- 4. ฟังก์ชัน
--   -- drop function if exists sri_os.fn_apply_asset_draft(uuid);
--   -- drop function if exists sri_os.fn_next_asset_code(uuid);
--   -- drop function if exists sri_os.fn_asset_assign_ok(uuid, uuid, uuid);
--   -- drop function if exists sri_os.fn_can_write_contract(uuid, uuid);
--   -- drop function if exists sri_os.fn_can_write_schedule(uuid);
--   -- drop function if exists sri_os.fn_asset_draft_patch_keys();
--   -- drop function if exists sri_os.fn_asset_draft_patch_whitelist();
--   -- drop function if exists sri_os.fn_asset_draft_frozen();
--   -- drop function if exists sri_os.fn_asset_assign_guard();
--   -- drop function if exists sri_os.fn_bank_account_coa_immutable();
--   -- drop function if exists sri_os.fn_schedule_status_mirror();
--   -- 5. สิทธิ์ (ลบ role_permissions ก่อนเพราะ FK)
--   -- delete from sri_os.role_permissions where permission_key in ('asset.draft','asset.manage','asset.value');
--   -- delete from sri_os.permissions     where key            in ('asset.draft','asset.manage','asset.value');
--   -- ** ย้อนแล้วกลับไปสู่สภาพที่ไม่มีใครเพิ่มทรัพย์/บัญชีธนาคาร/สัญญาได้เลย **
--   --    และต้องถอน 3 คีย์ออกจาก src/lib/auth/permissions.ts ด้วย ไม่งั้น
--   --    npm run check:permissions พัง
--
-- idempotent: create type ใน do block ที่เช็คก่อน · create table if not exists ·
--   add constraint แบบ drop if exists ก่อน · insert ... on conflict ·
--   create or replace function · drop policy/trigger if exists ก่อน create
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 1 · สิทธิ์ใหม่ 3 ตัว (§1.2) — 12 → 15
--     ชื่อคีย์ต้องผ่าน CHECK permissions_no_money_bypass (regex กันคีย์ปิดกฎเงิน)
--     ทั้งสามตัวผ่าน: ไม่มีคำว่า skip/waive/bypass/... และไม่ขึ้นต้นด้วย delete.
-- ============================================================
insert into permissions (key, label, note) values
  ('asset.draft',  'เสนอข้อมูลทะเบียนทรัพย์เป็นร่าง',
   'ทุกตำแหน่งมี · สร้าง/แก้/ยกเลิกร่างของตัวเองที่ยัง pending · ร่างอยู่ในตาราง asset_drafts ไม่ใช่ assets จึงไม่ถูกนับในงบ/พอร์ตโดยโครงสร้าง (ADR 0001)'),
  ('asset.manage', 'เขียนทะเบียนทรัพย์/สัญญา + อนุมัติร่าง',
   'ขอบเขตจำกัดด้วย fn_can_see_owner() + fn_can_see_asset() · **Staff ไม่มี** · ไม่ให้สิทธิ์ post อะไรเลย (§5.2)'),
  ('asset.value',  'ตีราคาทรัพย์ (asset_valuations)',
   'Management ขึ้นไป · **Manager ไม่มี** เพราะราคาประเมินเข้า NAV และเป็นฐานการตัดสินใจโดยไม่มี double-entry คอยจับ (§4.2) · ตารางเป็น append-only ไม่มี policy UPDATE/DELETE')
on conflict (key) do update
  set label = excluded.label, note = excluded.note;

-- การจับคู่ตั้งต้นตาม §1.2 + คำตอบของลูกพี่ (Q2 = Management ตีให้ · Q4 = Staff ไม่แตะสัญญา)
-- on conflict do nothing = รัน migration ซ้ำไม่ทับของที่ปรับไว้ภายหลังด้วย migration อื่น
insert into role_permissions (role_key, permission_key)
select r.key, p.key
  from (values
    -- permission       super_admin  management  manager  staff
    ('asset.draft',    true,  true,  true,  true),
    ('asset.manage',   true,  true,  true,  false),
    ('asset.value',    true,  true,  false, false)
  ) as p(key, super_admin, management, manager, staff)
  cross join lateral (values
    ('super_admin', p.super_admin),
    ('management',  p.management),
    ('manager',     p.manager),
    ('staff',       p.staff)
  ) as r(key, allowed)
 where r.allowed
on conflict (role_key, permission_key) do nothing;

-- guard ของ 20261007000003: ตารางสิทธิ์ต้องไม่มี policy ที่ไม่ใช่ SELECT
-- (ไฟล์นี้ใส่สิทธิ์ด้วย insert ตรงจาก migration จึงไม่ต้องมี write policy — ย้ำให้พังถ้ามีคนเพิ่มกลับมา)
do $$
declare v text;
begin
  select string_agg(tablename || '.' || policyname || ' (' || cmd || ')', ', ') into v
    from pg_policies
   where schemaname = 'sri_os'
     and tablename in ('roles', 'permissions', 'role_permissions')
     and cmd <> 'SELECT';
  if v is not null then
    raise exception 'พบ policy เขียนบนตารางสิทธิ์: % · ตารางพวกนี้แก้ได้จาก migration เท่านั้น (20261007000003)', v;
  end if;
end $$;

-- ============================================================
-- 2 · ตารางร่างทะเบียนทรัพย์ (§2.4 · ADR 0001)
--     **ไม่ใช้ draft_status ของ ledger ซ้ำ** เพราะกฎเหล็กข้อ 4: ถอดโมดูลทรัพย์ทิ้ง
--     ต้องไม่กระทบ core ledger
-- ============================================================
do $$
begin
  if not exists (
    select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
     where n.nspname = 'sri_os' and t.typname = 'asset_draft_status'
  ) then
    create type sri_os.asset_draft_status as enum ('pending', 'approved', 'rejected', 'cancelled');
  end if;
end $$;

create table if not exists asset_drafts (
  id              uuid primary key default gen_random_uuid(),
  kind            text not null check (kind in ('create', 'update')),
  -- kind='update' ชี้ทรัพย์จริง · kind='create' ยังไม่มีแถวใน assets ให้ชี้
  target_asset_id uuid references assets(id),
  -- ชั้นขอบเขตแรก: fn_can_see_owner()
  owner_id        uuid not null references owners(id),
  -- 4 ช่องบังคับของ D-083 เป็นคอลัมน์จริง (ใช้เฉพาะ kind='create')
  name            text,
  class_id        uuid references asset_classes(id),
  category_id     uuid references asset_categories(id),
  -- ช่องที่เหลือ · whitelist ด้วย trigger ที่อ้างชื่อคอลัมน์จริงของ assets
  patch           jsonb not null default '{}',
  note            text,
  status          asset_draft_status not null default 'pending',
  reject_reason   text,
  -- ตั้งได้จาก fn_apply_asset_draft() เท่านั้น (บังคับด้วย trg_asset_draft_frozen)
  applied_asset_id uuid references assets(id),
  created_by      uuid not null default auth.uid() references app_users(id),
  reviewed_by     uuid references app_users(id),
  reviewed_at     timestamptz,
  created_at      timestamptz not null default now()
);

-- constraint แยกจาก create table เพื่อให้รันซ้ำได้กับตารางที่มีอยู่แล้ว
do $$
declare
  r record;
  defs text[][] := array[
    -- (kind='create') = (target_asset_id is null) — ทั้งสองทางพร้อมกัน ไม่ใช่ข้างเดียว
    array['asset_drafts_kind_target',
          $c$((kind = 'create') = (target_asset_id is null))$c$],
    -- D-083 ข้อ 3: ลงทะเบียนด้วย 4 ช่องก่อน · **ไม่เติมค่าเริ่มต้นให้** ถ้าไม่ส่งมา
    array['asset_drafts_create_required',
          $c$(kind <> 'create' or (name is not null and class_id is not null and category_id is not null))$c$],
    -- kind='update' ต้องส่งทุกอย่างผ่าน patch · ห้ามมีสองแหล่งของช่องเดียวกัน
    array['asset_drafts_update_uses_patch',
          $c$(kind <> 'update' or (name is null and class_id is null and category_id is null))$c$],
    array['asset_drafts_patch_object',
          $c$(jsonb_typeof(patch) = 'object')$c$],
    -- ร่างแก้ไขที่ไม่มีช่องให้แก้ = ไม่มีข้อมูล → ปฏิเสธ ไม่ใช่ปล่อยผ่าน
    array['asset_drafts_update_has_patch',
          $c$(kind <> 'update' or patch <> '{}'::jsonb)$c$],
    -- ปฏิเสธร่างโดยไม่บอกเหตุผล = คนคีย์แก้ไม่ถูก
    array['asset_drafts_reject_reason',
          $c$(status <> 'rejected' or reject_reason is not null)$c$],
    -- อนุมัติ ⇔ มีทรัพย์ที่ถูกสร้าง/แก้จริง · กัน "อนุมัติแล้วแต่ไม่มีผล"
    array['asset_drafts_applied_iff_approved',
          $c$((status = 'approved') = (applied_asset_id is not null))$c$],
    -- ความเสี่ยงข้อ 1 ของ §6: ต้องบันทึก reviewed_by ทุกครั้งที่ออกจาก pending
    array['asset_drafts_reviewed_pair',
          $c$((status = 'pending') = (reviewed_by is null and reviewed_at is null))$c$]
  ];
  i int;
begin
  for i in 1 .. array_length(defs, 1) loop
    execute format('alter table sri_os.asset_drafts drop constraint if exists %I', defs[i][1]);
    execute format('alter table sri_os.asset_drafts add constraint %I check %s', defs[i][1], defs[i][2]);
  end loop;
  -- กันเทสต์/guard เปล่า: ถ้าวันหนึ่ง loop ไม่ทำอะไรต้องรู้
  select count(*) into i from pg_constraint c
    join pg_class cl on cl.oid = c.conrelid
    join pg_namespace ns on ns.oid = cl.relnamespace
   where ns.nspname = 'sri_os' and cl.relname = 'asset_drafts' and c.contype = 'c';
  if i < 8 then
    raise exception 'ใส่ CHECK ของ asset_drafts ได้แค่ % ตัว — ตรวจบล็อกนี้', i;
  end if;
  raise notice 'asset_drafts: CHECK constraint ครบ % ตัว', i;
end $$;

create index if not exists asset_drafts_queue_idx    on asset_drafts(status, created_at);
create index if not exists asset_drafts_creator_idx  on asset_drafts(created_by, status);
create index if not exists asset_drafts_target_idx   on asset_drafts(target_asset_id);

comment on table asset_drafts is
  'ร่างทะเบียนทรัพย์ (ADR 0001) · แยกจาก assets **โดยตั้งใจ** เพื่อให้ร่างไม่ถูกนับในงบ/พอร์ตในทางโครงสร้าง ไม่ใช่เพราะมีใครจำกรอง · FK ทุกตัว (transactions/contracts/asset_valuations) ชี้ assets(id) ซึ่งยังไม่มีแถว → ตีราคา/ลงบัญชีให้ร่างไม่ได้';
comment on column asset_drafts.patch is
  'ช่องที่เหลือของ assets · คีย์ต้องอยู่ใน fn_asset_draft_patch_keys() (trigger บังคับตอน insert ไม่ใช่เงียบตอนอนุมัติ) · **ไม่มี** owner_id · manager_user_id · code · status · id · created_at';
comment on column asset_drafts.applied_asset_id is
  'ทรัพย์ที่เกิดจากการอนุมัติร่างนี้ · ตั้งได้จาก fn_apply_asset_draft() เท่านั้น — trg_asset_draft_frozen ตรวจว่าแถวใน assets ตรงกับร่างจริง จึงตั้งสถานะ approved แบบไม่สร้างทรัพย์ไม่ได้';

alter table asset_drafts enable row level security;

-- ============================================================
-- 3 · whitelist ของช่องที่ร่างได้ — **แหล่งความจริงเดียว** ฝั่ง DB
--     ฝั่ง TS (src/lib/assets/draft-rules.ts · งาน W4) ต้องเทียบกับฟังก์ชันนี้
--     ห้ามให้ฟอร์มมีรายชื่อช่องของตัวเอง (กฎ "กฎเดียวกันห้ามเขียนสองที่")
-- ============================================================
create or replace function fn_asset_draft_patch_keys() returns text[]
language sql immutable set search_path = '' as $fn$
  select array[
    'name', 'class_id', 'category_id',
    'holding_nature', 'beneficiary_id',
    'acquired_date', 'disposed_date',
    'location', 'ticker', 'units', 'currency', 'tags',
    -- คอลัมน์จาก 20260917000005 (Excel alignment) — ข้อมูลประกอบทะเบียนล้วน
    -- CHECK ของ ownership_pct (0 < x <= 1) ยังบังคับอยู่ที่ตาราง ร่างที่ใส่ค่าเพี้ยน
    -- จะพังตอนอนุมัติ ไม่ใช่เข้าไปเงียบๆ
    'ownership_pct', 'funding_source', 'property_type', 'size_note'
  ]::text[];
$fn$;
comment on function fn_asset_draft_patch_keys() is
  'ช่องของ assets ที่เสนอแก้ผ่านร่างได้ · ที่ไม่อยู่ในนี้โดยตั้งใจ: id · code (ออกตอนอนุมัติ) · owner_id + manager_user_id (= การแจกสิทธิ์มองเห็น ต้อง users.manage/settings.manage) · status (สถานะทรัพย์กระทบรายงาน) · created_at';

-- guard: whitelist ⊆ คอลัมน์จริงของ assets · และคอลัมน์ของ assets ต้องถูกตัดสินทุกตัว
--   (อยู่ใน whitelist หรืออยู่ใน deny-list ที่เขียนเหตุผลไว้) → เพิ่มคอลัมน์ใหม่ใน assets
--   แล้วไม่ตัดสินว่าร่างได้หรือไม่ = พังให้เห็นที่นี่ ไม่ใช่เงียบ (§6 ความเสี่ยงข้อ 2)
do $$
declare
  v_deny text[] := array['id', 'code', 'owner_id', 'manager_user_id', 'status', 'created_at'];
  v_missing text;
  v_undecided text;
begin
  select string_agg(k, ', ' order by k) into v_missing
    from unnest(fn_asset_draft_patch_keys()) k
   where not exists (
     select 1 from information_schema.columns c
      where c.table_schema = 'sri_os' and c.table_name = 'assets' and c.column_name = k
   );
  if v_missing is not null then
    raise exception 'whitelist ของร่างอ้างช่องที่ไม่มีคอลัมน์รองรับใน assets: % · ร่างจะพังตอนอนุมัติ ไม่ใช่ตอน insert', v_missing;
  end if;

  select string_agg(c.column_name, ', ' order by c.column_name) into v_undecided
    from information_schema.columns c
   where c.table_schema = 'sri_os' and c.table_name = 'assets'
     and c.column_name <> all (fn_asset_draft_patch_keys())
     and c.column_name <> all (v_deny);
  if v_undecided is not null then
    raise exception 'คอลัมน์ของ assets ที่ยังไม่ตัดสินว่าร่างได้หรือไม่: % · เพิ่มเข้า fn_asset_draft_patch_keys() หรือเข้า deny-list ในไฟล์นี้พร้อมเหตุผล', v_undecided;
  end if;
  raise notice 'whitelist ของร่าง: % ช่อง · deny-list % ช่อง · ครอบคอลัมน์ของ assets ครบ',
    cardinality(fn_asset_draft_patch_keys()), cardinality(v_deny);
end $$;

-- ---------- trigger · patch whitelist ----------
-- ไม่ใช่ security definer และไม่อ่านตารางใด → ไม่ต้องข้าม RLS
create or replace function fn_asset_draft_patch_whitelist() returns trigger
language plpgsql set search_path = '' as $fn$
declare v_bad text;
begin
  -- "ไม่ส่งข้อมูล" ต้องปฏิเสธ ไม่ใช่เดาให้ (คอลัมน์ not null กันอยู่ชั้นหนึ่งแล้ว
  -- แต่ค่า null ที่ยัดมาตรงๆ ด้วย update ก็ต้องตกที่นี่)
  if new.patch is null then
    raise exception 'ร่างทะเบียนทรัพย์: patch เป็น null ไม่ได้ · ถ้าไม่มีช่องเพิ่มให้ใช้ ''{}''';
  end if;

  select string_agg(k, ', ' order by k) into v_bad
    from jsonb_object_keys(new.patch) as k
   where k <> all (sri_os.fn_asset_draft_patch_keys());
  if v_bad is not null then
    raise exception 'ร่างทะเบียนทรัพย์: ช่องที่เสนอแก้ผ่านร่างไม่ได้ (%) · ช่องที่อนุญาต: % · owner_id/manager_user_id = การแจกสิทธิ์มองเห็น · code ออกตอนอนุมัติ · status กระทบรายงาน',
      v_bad, array_to_string(sri_os.fn_asset_draft_patch_keys(), ', ');
  end if;

  -- kind='create' มีคอลัมน์จริงของ 4 ช่องบังคับอยู่แล้ว → ห้ามซ้ำใน patch
  if new.kind = 'create' then
    select string_agg(k, ', ' order by k) into v_bad
      from jsonb_object_keys(new.patch) as k
     where k in ('name', 'class_id', 'category_id');
    if v_bad is not null then
      raise exception 'ร่างสร้างทรัพย์: ช่อง % อยู่ในคอลัมน์ของร่างแล้ว ห้ามส่งซ้ำใน patch (สองแหล่งของค่าเดียวกัน)', v_bad;
    end if;
  end if;

  return new;
end $fn$;

drop trigger if exists trg_asset_draft_patch_whitelist on asset_drafts;
create trigger trg_asset_draft_patch_whitelist
  before insert or update on asset_drafts
  for each row execute function fn_asset_draft_patch_whitelist();

-- ---------- trigger · ร่างที่พิจารณาแล้วแก้ไม่ได้อีก + applied_asset_id ต้องมีผลจริง ----------
-- security definer เพราะต้องอ่าน assets เพื่อยืนยันว่าทรัพย์ที่อ้างถึงตรงกับร่างจริง
-- (ถ้าเป็น invoker แล้วผู้อนุมัติมองไม่เห็นแถวนั้น exists() จะเป็น false แล้วกฎจะกลับด้าน)
-- **ห้ามเรียก fn_can** — เทสต์ข้อ 10 ของ roles_permissions_test.sql อ่าน pg_proc ยืนยัน
create or replace function fn_asset_draft_frozen() returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  if old.status <> 'pending' then
    raise exception 'ร่างทะเบียนทรัพย์ % อยู่สถานะ % แล้ว แก้ไม่ได้อีก · แก้ด้วยการสร้างร่างใหม่ (รูปแบบเดียวกับกฎเหล็กข้อ 1)',
      old.id, old.status;
  end if;

  if new.id          is distinct from old.id
  or new.kind        is distinct from old.kind
  or new.target_asset_id is distinct from old.target_asset_id
  or new.created_by  is distinct from old.created_by
  or new.created_at  is distinct from old.created_at then
    raise exception 'ร่าง %: แก้ id · kind · target_asset_id · created_by · created_at ไม่ได้ (ร่างคนละใบคือร่างใหม่)', old.id;
  end if;

  if new.status <> 'pending' and new.reviewed_by is distinct from auth.uid() then
    raise exception 'ร่าง %: การเปลี่ยนสถานะต้องบันทึก reviewed_by = ผู้ใช้ที่ทำจริง (ได้ %) · หน้าคิวต้องแสดงได้ว่าคนคีย์กับคนอนุมัติเป็นคนเดียวกันหรือไม่',
      old.id, coalesce(new.reviewed_by::text, '(ว่าง)');
  end if;

  if new.applied_asset_id is not null then
    if new.status <> 'approved' then
      raise exception 'ร่าง %: applied_asset_id ตั้งได้เฉพาะตอนสถานะ approved', old.id;
    end if;
    if new.kind = 'update' and new.applied_asset_id is distinct from new.target_asset_id then
      raise exception 'ร่างแก้ไข %: applied_asset_id ต้องเป็นทรัพย์เดิมที่ร่างชี้ไว้', old.id;
    end if;
    if not exists (
      select 1 from sri_os.assets a
       where a.id = new.applied_asset_id and a.owner_id = new.owner_id
    ) then
      raise exception 'ร่าง %: applied_asset_id ต้องชี้ทรัพย์ที่มีอยู่จริงและเป็นของผู้ถือเดียวกับร่าง · ตั้งสถานะ approved โดยไม่สร้าง/ไม่แก้ทรัพย์ไม่ได้ (อนุมัติที่ไม่มีผล = ทะเบียนกับคิวไม่ตรงกันเงียบๆ)',
        old.id;
    end if;
    if new.kind = 'create' and not exists (
      select 1 from sri_os.assets a
       where a.id = new.applied_asset_id
         and a.name = new.name and a.class_id = new.class_id and a.category_id = new.category_id
    ) then
      raise exception 'ร่างสร้างทรัพย์ %: ทรัพย์ที่อ้างว่าสร้างจากร่างนี้ไม่ตรงกับร่าง (ชื่อ/หมวดใหญ่/หมวดย่อย) · ใช้ fn_apply_asset_draft() เท่านั้น', old.id;
    end if;
  end if;

  return new;
end $fn$;

drop trigger if exists trg_asset_draft_frozen on asset_drafts;
create trigger trg_asset_draft_frozen
  before update on asset_drafts
  for each row execute function fn_asset_draft_frozen();

drop trigger if exists trg_audit_asset_drafts on asset_drafts;
create trigger trg_audit_asset_drafts
  after insert or update or delete on asset_drafts
  for each row execute function fn_audit();

-- ============================================================
-- 4 · trigger ของ assets · bank_accounts · schedules
--     ทุกตัว security definer + search_path = '' เพราะต้องอ่านตารางการเงินให้ครบจริง
--     ทุกตัว **ไม่เรียก fn_can** (เทสต์ข้อ 10) และ **ไม่เขียน** ตาราง ledger (กฎเหล็กข้อ 6)
-- ============================================================

-- §3.2 ข้อ 2 · ย้ายผู้ถือของทรัพย์ที่มีบรรทัดบัญชีผูกอยู่ = ต้นทุนในบัญชีคุมของผู้ถือเดิม
--   ไม่ตรงกับทะเบียนทันที (DESIGN_ASSET_ERP_LINK เส้นที่ 1) · ส่วน "ใครเปลี่ยนได้"
--   อยู่ใน policy ผ่าน fn_asset_assign_ok() ดูหัวไฟล์ข้อ (ก)
create or replace function fn_asset_assign_guard() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare v_lines bigint;
begin
  if new.id is distinct from old.id then
    raise exception 'เปลี่ยน assets.id ไม่ได้ (FK ของ transaction_lines/contracts/asset_valuations ชี้อยู่)';
  end if;

  if new.owner_id is distinct from old.owner_id then
    select count(*) into v_lines
      from sri_os.transaction_lines l where l.asset_id = old.id;
    if v_lines > 0 then
      raise exception 'ย้ายผู้ถือของทรัพย์ % ไม่ได้: มีบรรทัดบัญชีผูกอยู่ % แถว · ต้นทุนที่ลงไว้ในบัญชีคุมของผู้ถือเดิมจะไม่ตรงกับทะเบียนทันที · การเปลี่ยนมือต้องลงเป็นรายการเงิน (ขาย/โอน) ไม่ใช่แก้ทะเบียน',
        old.code, v_lines;
    end if;
  end if;

  return new;
end $fn$;

drop trigger if exists trg_asset_assign_guard on assets;
create trigger trg_asset_assign_guard
  before update on assets
  for each row execute function fn_asset_assign_guard();

drop trigger if exists trg_audit_assets on assets;
create trigger trg_audit_assets
  after insert or update or delete on assets
  for each row execute function fn_audit();

-- §4.5 · เปลี่ยน coa_id/owner_id ของบัญชีธนาคารที่มีรายการแล้ว = ย้ายยอดเงินสด
--   ข้ามบัญชีในผัง/ข้ามผู้ถือย้อนหลัง · ปิดบัญชี = is_active = false เท่านั้น
create or replace function fn_bank_account_coa_immutable() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare v_lines bigint;
begin
  if new.coa_id is distinct from old.coa_id or new.owner_id is distinct from old.owner_id then
    select count(*) into v_lines
      from sri_os.transaction_lines l where l.bank_account_id = old.id;
    if v_lines > 0 then
      raise exception 'บัญชี % มีบรรทัดบัญชีผูกอยู่ % แถว: เปลี่ยน coa_id/owner_id ไม่ได้ = ย้ายยอดเงินสดข้ามบัญชีในผัง/ข้ามผู้ถือย้อนหลัง · ปิดบัญชีใช้ is_active = false',
        old.display_name, v_lines;
    end if;
  end if;
  return new;
end $fn$;

drop trigger if exists trg_bank_account_coa_immutable on bank_accounts;
create trigger trg_bank_account_coa_immutable
  before update on bank_accounts
  for each row execute function fn_bank_account_coa_immutable();

drop trigger if exists trg_audit_bank_accounts on bank_accounts;
create trigger trg_audit_bank_accounts
  after insert or update or delete on bank_accounts
  for each row execute function fn_audit();

-- §4.4 · สถานะงวดที่สะท้อน ledger แก้มือไม่ได้
--   ถ้าแก้มือได้ ทะเบียนจะบอกว่า "รับเงินแล้ว" ขณะที่ไม่มีใบยืนยันและไม่มีบรรทัดบัญชี
--   สถานะที่แก้มือได้: upcoming · overdue · waived (การยกเว้นงวดเป็นการตัดสินใจเชิงธุรกิจ)
create or replace function fn_schedule_status_mirror() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare v_draft text; v_txn uuid;
begin
  if tg_op = 'UPDATE' and new.status = old.status then
    return new;
  end if;
  if new.status in ('upcoming', 'overdue', 'waived') then
    return new;
  end if;

  -- "ไม่ส่งข้อมูล" = ไม่มีร่างผูกอยู่ → ปฏิเสธ ไม่ใช่ปล่อยผ่าน
  if new.draft_entry_id is null then
    raise exception 'งวดที่ % ของสัญญา %: ตั้งสถานะ % เองไม่ได้เพราะยังไม่มีร่างรายการผูกอยู่ (draft_entry_id ว่าง) · สถานะที่แก้มือได้คือ upcoming · overdue · waived',
      new.period, new.contract_id, new.status;
  end if;

  select de.status::text, de.posted_txn_id into v_draft, v_txn
    from sri_os.draft_entries de where de.id = new.draft_entry_id;
  if v_draft is null then
    raise exception 'งวดที่ %: draft_entry_id % ชี้ร่างที่ไม่มีอยู่', new.period, new.draft_entry_id;
  end if;

  if new.status = 'drafted' and v_draft <> 'pending' then
    raise exception 'งวดที่ %: สถานะ drafted ต้องมีร่างที่ยังรออนุมัติ (ร่างอยู่สถานะ %)', new.period, v_draft;
  end if;

  if new.status in ('approved', 'received') then
    if v_draft <> 'approved' or v_txn is null then
      raise exception 'งวดที่ %: สถานะ % ต้องมีรายการที่อนุมัติเข้า ledger แล้ว (ร่างอยู่สถานะ % · posted_txn_id %)',
        new.period, new.status, v_draft, coalesce(v_txn::text, '(ว่าง)');
    end if;
    if not exists (
      select 1 from sri_os.transactions t where t.id = v_txn and t.status = 'posted'
    ) then
      raise exception 'งวดที่ %: รายการที่ผูกอยู่ไม่ได้อยู่สถานะ posted (void แล้ว?) ตั้งสถานะ % ไม่ได้', new.period, new.status;
    end if;
  end if;

  if new.status = 'received' and not exists (
    select 1 from sri_os.cash_confirmations c
     where c.transaction_id = v_txn and c.confirmed_at is not null
  ) then
    raise exception 'งวดที่ %: สถานะ received ต้องมีใบยืนยันรับ-จ่ายเงินจริงที่ยืนยันแล้ว (cash.confirm) · แก้มือไม่ได้ ไม่งั้นทะเบียนบอกว่ารับเงินแล้วแต่ไม่มีบรรทัดบัญชี',
      new.period;
  end if;

  return new;
end $fn$;

drop trigger if exists trg_schedule_status_mirror on schedules;
create trigger trg_schedule_status_mirror
  before insert or update on schedules
  for each row execute function fn_schedule_status_mirror();

-- ============================================================
-- 5 · ฟังก์ชันที่ policy เรียก (ไม่ใช่ trigger จึงเรียก fn_can ได้)
-- ============================================================

-- การมอบหมายผู้บริหารทรัพย์ = **การแจกสิทธิ์มองเห็น** ธรรมชาติเดียวกับ user_owner_access
-- (§3.2 ข้อ 1) → users.manage · การย้ายผู้ถือ → settings.manage
--
-- ทำไมอ่านค่าเดิมได้: ฟังก์ชัน stable ใช้ snapshot ของคำสั่งที่เรียกมัน ซึ่ง **ยังไม่เห็น**
--   การเปลี่ยนแปลงของคำสั่ง UPDATE ที่กำลังทำอยู่ → subquery คืนค่า**เดิม**ของแถว
--   ส่วนพารามิเตอร์ที่ส่งเข้ามาคือค่า**ใหม่** (WITH CHECK อ่านแถวใหม่)
--   = เทียบเก่า/ใหม่ได้ใน policy ซึ่ง RLS ทำเองไม่ได้ (D-089 กรองคอลัมน์ไม่ได้)
-- ตอน INSERT ยังไม่มีแถวใน snapshot → ตกไปสาขา "ตั้ง manager ตอนสร้างต้องมี users.manage"
--   (ดูหัวไฟล์ข้อ ค) · security definer เพราะต้องอ่านค่าเดิมให้ครบจริง ไม่ใช่ตามที่ผู้เรียกเห็น
create or replace function fn_asset_assign_ok(p_asset uuid, p_manager uuid, p_owner uuid)
returns boolean
language sql stable security definer set search_path = '' as $fn$
  select coalesce(
    (select (a.manager_user_id is not distinct from p_manager or sri_os.fn_can('users.manage'))
        and (a.owner_id        is not distinct from p_owner   or sri_os.fn_can('settings.manage'))
       from sri_os.assets a
      where a.id = p_asset),
    p_manager is null or sri_os.fn_can('users.manage')
  );
$fn$;
comment on function fn_asset_assign_ok(uuid, uuid, uuid) is
  '§3.2 · manager_user_id เปลี่ยน/ตั้งได้เฉพาะคนที่มี users.manage · owner_id เฉพาะ settings.manage · เรียกจาก WITH CHECK ของ assets_insert/assets_update ไม่ใช่จาก trigger (trigger ห้ามเรียก fn_can — เทสต์ข้อ 10)';

-- สัญญา: Manager ได้เฉพาะสัญญาของทรัพย์ที่ตนบริหาร · สัญญาที่ไม่ผูกทรัพย์ต้อง portfolio.view_all
-- (รูปร่างเดียวกับ fn_can_read_contract ที่ใช้ฝั่งอ่าน เพื่อให้ "เห็นอะไร" กับ "เขียนอะไร" ไม่เลื่อนจากกัน)
create or replace function fn_can_write_contract(p_owner uuid, p_asset uuid) returns boolean
language sql stable set search_path = '' as $fn$
  select sri_os.fn_can('asset.manage')
     and sri_os.fn_can_see_owner(p_owner)
     and case when p_asset is null
              then sri_os.fn_can('portfolio.view_all')
              else sri_os.fn_can_see_asset(p_asset)
         end;
$fn$;
comment on function fn_can_write_contract(uuid, uuid) is
  'ขอบเขตการเขียนสัญญา (§4.3) · Staff ตกที่ asset.manage · สัญญาที่ไม่ผูกทรัพย์เขียนได้เฉพาะคนที่มี portfolio.view_all';

-- ตารางงวดตามสัญญาแม่ · definer เพราะต้องอ่าน owner/asset ของสัญญาให้ครบจริง
-- ไม่ใช่ตามที่ policy อ่านของผู้เรียกจะมองเห็น (ไม่งั้นกฎจะกลับด้านเมื่ออ่านไม่เห็น)
create or replace function fn_can_write_schedule(p_contract uuid) returns boolean
language sql stable security definer set search_path = '' as $fn$
  select coalesce(
    (select sri_os.fn_can_write_contract(c.owner_id, c.asset_id)
       from sri_os.contracts c where c.id = p_contract),
    false   -- สัญญาไม่มีอยู่ → ปฏิเสธ ไม่ใช่ปล่อยผ่าน
  );
$fn$;

-- ============================================================
-- 6 · policy ฝั่งเขียน · **แยกคำสั่งทุกตัว ไม่มี FOR ALL** (§5.4)
--     ไม่มี policy DELETE บนทั้ง 5 ตาราง + asset_drafts → ลบไม่ได้ทุกตำแหน่งรวม super_admin
--     policy SELECT เดิมทุกตัว **ไม่ถูกแตะ** (assets_by_owner · valuations_by_asset ·
--     contracts_by_owner · schedules_by_contract · bank_accounts_by_owner)
-- ============================================================

-- ---------- assets ----------
-- INSERT ตรง = Management ขึ้นไป (asset.manage + portfolio.view_all) · Manager/Staff ผ่านร่าง
drop policy if exists assets_insert on assets;
create policy assets_insert on assets
  for insert to authenticated
  with check (
        fn_can('asset.manage')
    and fn_can('portfolio.view_all')
    and fn_can_see_owner(owner_id)
    and fn_asset_assign_ok(id, manager_user_id, owner_id)
  );

-- UPDATE: USING = แถวเดิม · WITH CHECK = แถวใหม่ · ต้องผ่านทั้งคู่
-- ไม่งั้น Manager ย้ายทรัพย์ออกนอกขอบเขตตัวเองแล้วแก้ต่อได้ (หรือกลับกัน)
drop policy if exists assets_update on assets;
create policy assets_update on assets
  for update to authenticated
  using      (fn_can('asset.manage') and fn_can_see_owner(owner_id) and fn_can_see_asset(id))
  with check (fn_can('asset.manage') and fn_can_see_owner(owner_id) and fn_can_see_asset(id)
              and fn_asset_assign_ok(id, manager_user_id, owner_id));

-- ---------- asset_drafts ----------
-- อ่าน: Staff เห็นเฉพาะร่างของตัวเอง (จึงไม่มีปัญหา "RLS กรองคอลัมน์ไม่ได้" ตาม §5.3)
--       คนที่มี asset.manage เห็นคิวในขอบเขตผู้ถือ · ร่างแก้ไขจำกัดด้วยขอบเขตทรัพย์อีกชั้น
drop policy if exists asset_drafts_read on asset_drafts;
create policy asset_drafts_read on asset_drafts
  for select to authenticated
  using (
    fn_can_see_owner(owner_id)
    and (
         (fn_can('asset.draft') and created_by = auth.uid())
      or (fn_can('asset.manage')
          and (target_asset_id is null or fn_can_see_asset(target_asset_id)))
    )
  );

-- สร้างร่าง: ทุกตำแหน่งที่มี asset.draft · ร่างเกิดใหม่ต้อง pending และยังไม่มีผล
-- ร่างแก้ไขต้องชี้ทรัพย์ที่ผู้ร่างมองเห็นจริงและผู้ถือต้องตรงกัน
-- (อ่านผ่าน policy SELECT ของ assets โดยตั้งใจ → Manager ร่างแก้ได้เฉพาะทรัพย์ที่ตนบริหาร)
drop policy if exists asset_drafts_insert on asset_drafts;
create policy asset_drafts_insert on asset_drafts
  for insert to authenticated
  with check (
        fn_can('asset.draft')
    and fn_can_see_owner(owner_id)
    and created_by = auth.uid()
    and status = 'pending'
    and applied_asset_id is null
    and reviewed_by is null
    and (
      target_asset_id is null
      or exists (select 1 from assets a where a.id = target_asset_id and a.owner_id = asset_drafts.owner_id)
    )
  );

-- คนคีย์แก้/ยกเลิกร่างของตัวเองที่ยัง pending ได้ · อนุมัติเองผ่าน policy นี้ไม่ได้
drop policy if exists asset_drafts_update_own on asset_drafts;
create policy asset_drafts_update_own on asset_drafts
  for update to authenticated
  using      (fn_can('asset.draft') and created_by = auth.uid() and status = 'pending')
  with check (fn_can('asset.draft') and created_by = auth.uid()
              and status in ('pending', 'cancelled')
              and applied_asset_id is null);

-- อนุมัติ/ปฏิเสธ: asset.manage ในขอบเขตผู้ถือ (+ ขอบเขตทรัพย์ถ้าเป็นร่างแก้ไข)
-- ความเสี่ยงข้อ 1 ของ §6: Manager อนุมัติร่างของตัวเองได้ **ยอมรับไว้** แต่ reviewed_by
-- ต้องเป็นตัวเองเสมอ → หน้าคิวแสดงได้ว่าคนคีย์กับคนอนุมัติเป็นคนเดียวกัน
drop policy if exists asset_drafts_review on asset_drafts;
create policy asset_drafts_review on asset_drafts
  for update to authenticated
  using (
        fn_can('asset.manage') and fn_can_see_owner(owner_id) and status = 'pending'
    and (target_asset_id is null or fn_can_see_asset(target_asset_id))
  )
  with check (
        fn_can('asset.manage') and fn_can_see_owner(owner_id)
    and status in ('approved', 'rejected')
    and reviewed_by = auth.uid()
  );

-- ---------- asset_valuations · append-only (§4.2) ----------
-- ไม่มี policy UPDATE/DELETE → แก้ราคาประเมิน = ใส่แถวใหม่
drop policy if exists valuations_insert on asset_valuations;
create policy valuations_insert on asset_valuations
  for insert to authenticated
  with check (
    fn_can('asset.value')
    and exists (
      select 1 from assets a
       where a.id = asset_id and fn_can_see_owner(a.owner_id) and fn_can_see_asset(a.id)
    )
  );

-- ---------- contracts (§4.3) ----------
drop policy if exists contracts_insert on contracts;
create policy contracts_insert on contracts
  for insert to authenticated
  with check (fn_can_write_contract(owner_id, asset_id));

drop policy if exists contracts_update on contracts;
create policy contracts_update on contracts
  for update to authenticated
  using      (fn_can_write_contract(owner_id, asset_id))
  with check (fn_can_write_contract(owner_id, asset_id));

-- ---------- schedules (§4.4) ----------
drop policy if exists schedules_insert on schedules;
create policy schedules_insert on schedules
  for insert to authenticated
  with check (fn_can_write_schedule(contract_id));

drop policy if exists schedules_update on schedules;
create policy schedules_update on schedules
  for update to authenticated
  using      (fn_can_write_schedule(contract_id))
  with check (fn_can_write_schedule(contract_id));

-- ---------- bank_accounts (§4.5) — ไม่ใช่ทรัพย์สิน จึงเป็น settings.manage ----------
drop policy if exists bank_accounts_insert on bank_accounts;
create policy bank_accounts_insert on bank_accounts
  for insert to authenticated
  with check (fn_can('settings.manage') and fn_can_see_owner(owner_id));

drop policy if exists bank_accounts_update on bank_accounts;
create policy bank_accounts_update on bank_accounts
  for update to authenticated
  using      (fn_can('settings.manage') and fn_can_see_owner(owner_id))
  with check (fn_can('settings.manage') and fn_can_see_owner(owner_id));

-- ============================================================
-- 7 · การอนุมัติร่าง (§2.4 · §7 ข้อ 6)
--     **security invoker** โดยตั้งใจ: INSERT/UPDATE ที่ฟังก์ชันยิงยังต้องผ่าน policy
--     ของ assets → RLS ยังเป็นด่านเดียว ไม่มีสองชุดกฎที่อาจไม่ตรงกัน
--     ฟังก์ชันนี้ **ไม่เขียน** transactions · transaction_lines · draft_entries เลย
--     (กฎเหล็กข้อ 6: Automation ไม่เคย post เอง)
-- ============================================================

-- รหัสทรัพย์ออก**ตอนอนุมัติ** ไม่จองตอนร่าง (ADR เหตุผลข้อ 3)
-- definer เพราะการไล่เลขต้องเห็นทรัพย์ทุกแถวจริง ไม่ใช่เท่าที่ผู้เรียกมองเห็น
-- (ไม่งั้นคนที่เห็นไม่ครบจะได้รหัสที่ชนของที่มองไม่เห็น) · คืนแค่ text ไม่คืนข้อมูลทรัพย์
create or replace function fn_next_asset_code(p_class uuid) returns text
language plpgsql stable security definer set search_path = '' as $fn$
declare v_prefix text; v_n int;
begin
  if p_class is null then
    raise exception 'ออกรหัสทรัพย์ไม่ได้: ไม่ได้ระบุหมวดใหญ่ (class_id)';
  end if;
  select k.code into v_prefix from sri_os.asset_classes k where k.id = p_class;
  if v_prefix is null then
    raise exception 'ออกรหัสทรัพย์ไม่ได้: ไม่พบหมวดใหญ่ %', p_class;
  end if;
  select coalesce(max((regexp_match(a.code, '^' || v_prefix || '-([0-9]+)$'))[1]::int), 0) + 1
    into v_n from sri_os.assets a;
  return v_prefix || '-' || lpad(v_n::text, 4, '0');
end $fn$;

create or replace function fn_apply_asset_draft(p_draft uuid) returns uuid
language plpgsql set search_path = '' as $fn$
declare
  d        sri_os.asset_drafts;
  v_asset  uuid;
  v_code   text;
  v_bad    text;
  v_set    text;
  v_src    text;
  v_rows   int;
begin
  -- "ไม่ส่งข้อมูล" ต้องปฏิเสธ ไม่ใช่ตกไปเส้นทางปกติ (บทเรียน mace-windu ข้อ 1)
  if p_draft is null then
    raise exception 'fn_apply_asset_draft: ต้องระบุร่างที่จะอนุมัติ (ได้ null)';
  end if;

  -- อ่านผ่าน RLS โดยตั้งใจ: มองไม่เห็นร่าง = อนุมัติไม่ได้
  select * into d from sri_os.asset_drafts where id = p_draft;
  if not found then
    raise exception 'ไม่พบร่างทะเบียนทรัพย์ % หรือไม่มีสิทธิ์เห็นร่างนี้', p_draft;
  end if;
  if d.status <> 'pending' then
    raise exception 'ร่าง % อยู่สถานะ % แล้ว อนุมัติซ้ำไม่ได้ (ทรัพย์ที่เกิดจากร่างนี้: %) · ไม่สร้างทรัพย์ซ้ำ',
      p_draft, d.status, coalesce(d.applied_asset_id::text, '(ไม่มี)');
  end if;

  -- ตรวจ whitelist อีกรอบที่นี่: ร่างที่ถูกเขียนไว้ก่อน trigger มีผล ต้องไม่หลุดตอนอนุมัติ
  select string_agg(k, ', ' order by k) into v_bad
    from jsonb_object_keys(d.patch) as k
   where k <> all (sri_os.fn_asset_draft_patch_keys());
  if v_bad is not null then
    raise exception 'ร่าง % มีช่องที่เสนอแก้ไม่ได้ (%) อนุมัติไม่ได้', p_draft, v_bad;
  end if;

  if d.kind = 'create' then
    v_code := sri_os.fn_next_asset_code(d.class_id);
    begin
      insert into sri_os.assets (code, name, class_id, category_id, owner_id)
      values (v_code, d.name, d.class_id, d.category_id, d.owner_id)
      returning id into v_asset;
    exception
      when unique_violation then
        raise exception 'อนุมัติร่าง % ไม่สำเร็จ: รหัสทรัพย์ % มีอยู่แล้วในทะเบียน · ลองอนุมัติอีกครั้งเพื่อออกรหัสถัดไป หรือตรวจว่ามีทรัพย์ซ้ำอยู่จริง',
          p_draft, v_code;
      when insufficient_privilege then
        raise exception 'อนุมัติร่างสร้างทรัพย์ % ไม่ได้: ต้องมีสิทธิ์เพิ่มทรัพย์ (asset.manage + portfolio.view_all) ในขอบเขตผู้ถือนี้ · Manager อนุมัติได้เฉพาะร่างแก้ไข (kind=''update'') ของทรัพย์ที่ตนบริหาร',
          p_draft;
    end;
  else
    v_asset := d.target_asset_id;
    if v_asset is null then
      raise exception 'ร่างแก้ไข % ไม่มี target_asset_id (ข้อมูลไม่ครบ) อนุมัติไม่ได้', p_draft;
    end if;
  end if;

  -- ใช้ค่าจาก patch ผ่าน jsonb_populate_record เพื่อให้ได้ชนิดข้อมูลตรงตามคอลัมน์จริง
  -- (ไม่แปลงชนิดเองทีละช่อง = ไม่มีที่ให้พิมพ์ผิด) · ชื่อคอลัมน์ผ่าน %I และผ่าน whitelist แล้ว
  select string_agg(format('%I', k), ', ' order by k),
         string_agg(format('p.%I', k), ', ' order by k)
    into v_set, v_src
    from jsonb_object_keys(d.patch) as k;

  if v_set is not null then
    execute format(
      'update sri_os.assets t set (%s) = (select %s from jsonb_populate_record(null::sri_os.assets, $1) p) where t.id = $2',
      v_set, v_src)
      using d.patch, v_asset;
    get diagnostics v_rows = row_count;
    if v_rows = 0 then
      raise exception 'อนุมัติร่าง % ไม่สำเร็จ: แก้ทรัพย์ % ไม่ได้ (ไม่มีสิทธิ์ asset.manage ในขอบเขตทรัพย์นี้ หรือทรัพย์ถูกลบไปแล้ว)',
        p_draft, v_asset;
    end if;
  end if;

  update sri_os.asset_drafts
     set status           = 'approved',
         applied_asset_id = v_asset,
         reviewed_by      = auth.uid(),
         reviewed_at      = now()
   where id = p_draft and status = 'pending';
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    raise exception 'อนุมัติร่าง % ไม่สำเร็จ: ไม่มีสิทธิ์อนุมัติร่างนี้ (ต้องมี asset.manage + ขอบเขตผู้ถือ/ทรัพย์) · ทรัพย์ที่สร้าง/แก้ไว้ถูกยกเลิกไปกับธุรกรรมนี้',
      p_draft;
  end if;

  return v_asset;
end $fn$;
comment on function fn_apply_asset_draft(uuid) is
  'อนุมัติร่างทะเบียนทรัพย์ · **security invoker** (ไม่ใช่ definer) เพื่อให้ INSERT/UPDATE ยังผ่าน policy ของ assets = RLS เป็นด่านเดียว · ออก assets.code ตอนอนุมัติ ไม่จองตอนร่าง · ไม่เขียนตาราง ledger ใดๆ (กฎเหล็กข้อ 6)';

-- ============================================================
-- 8 · GRANT — ตารางใหม่ + ฟังก์ชันใหม่
--     ฟังก์ชันที่สร้างใหม่ติด ACL เริ่มต้นของ Postgres = PUBLIC EXECUTE
--     → ปิดทุกตัวก่อน แล้วเปิดตาม allow-list (รูปแบบเดียวกับ 20261007000007)
--     ถ้าไม่ปิด anon จะเรียกได้ และ SECURITY DEFINER ที่เปิด PUBLIC = ข้าม RLS
-- ============================================================
grant select, insert, update, delete on sri_os.asset_drafts to authenticated;
revoke all on sri_os.asset_drafts from anon;
-- หมายเหตุ: DELETE ที่ชั้น GRANT มีไว้ให้ครบรูปแบบเดียวกับตารางอื่น · ด่านจริงคือ RLS
--   ที่ **ไม่มี policy DELETE** → ลบไม่ได้ทุกตำแหน่งรวม super_admin (guard ข้อ 9 ตรวจให้)

do $$
declare
  r record;
  n_revoked int := 0;
  allow text[] := array[
    'fn_asset_draft_patch_keys()',   -- trigger (invoker) + ฟอร์มฝั่ง TS ต้องอ่าน whitelist
    'fn_asset_assign_ok(uuid,uuid,uuid)',  -- อยู่ใน WITH CHECK → รันด้วยสิทธิ์ผู้เรียก
    'fn_can_write_contract(uuid,uuid)',    -- อยู่ใน policy
    'fn_can_write_schedule(uuid)',         -- อยู่ใน policy
    'fn_next_asset_code(uuid)',            -- ถูกเรียกจาก fn_apply_asset_draft ที่เป็น invoker
    'fn_apply_asset_draft(uuid)'           -- หน้าจอเรียกตรง (rpc)
  ];
  v text;
begin
  for r in
    select p.oid::regprocedure::text as sig
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'sri_os'
       and p.proname in (
         'fn_asset_draft_patch_keys', 'fn_asset_draft_patch_whitelist', 'fn_asset_draft_frozen',
         'fn_asset_assign_guard', 'fn_asset_assign_ok', 'fn_bank_account_coa_immutable',
         'fn_schedule_status_mirror', 'fn_can_write_contract', 'fn_can_write_schedule',
         'fn_next_asset_code', 'fn_apply_asset_draft'
       )
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    n_revoked := n_revoked + 1;
  end loop;
  raise notice 'ปิด execute ของฟังก์ชันใหม่ % ตัว', n_revoked;

  foreach v in array allow loop
    if to_regprocedure('sri_os.' || v) is null then
      raise exception 'allow-list อ้างฟังก์ชันที่ไม่มีอยู่: sri_os.% · ลายเซ็นเปลี่ยนหรือสะกดผิด → policy จะล้มด้วย permission denied', v;
    end if;
    execute format('grant execute on function sri_os.%s to authenticated', v);
  end loop;
  raise notice 'เปิด execute ให้ authenticated ตาม allow-list % ตัว (trigger function ปิดหมด)', cardinality(allow);
end $$;

-- ============================================================
-- 9 · guard ท้ายไฟล์ — ทุกข้อ "พังให้เห็น" ไม่ใช่ raise notice
-- ============================================================

-- 9a · ขยายการตรวจของ 11c (20261006190000) ให้ครอบทั้ง **5 ตาราง** ไม่ใช่แค่สองตัว
--      policy อ่านที่ค้างอยู่หนึ่งตัวบนตารางเหล่านี้ OR ทับขอบเขตของ Manager ได้ทั้งชุด
--      (§5.4 สั่งให้ขยาย allow-list ให้ครอบ contracts · schedules · bank_accounts)
do $$
declare v text;
begin
  select string_agg(tablename || '.' || policyname || ' (' || cmd || ')', ', ' order by tablename || '.' || policyname) into v
    from pg_policies
   where schemaname = 'sri_os'
     and tablename in ('assets', 'asset_valuations', 'contracts', 'schedules', 'bank_accounts', 'asset_drafts')
     and cmd in ('SELECT', 'ALL')
     and (tablename, policyname) not in (values
           ('assets',           'assets_by_owner'),
           ('asset_valuations', 'valuations_by_asset'),
           ('contracts',        'contracts_by_owner'),
           ('schedules',        'schedules_by_contract'),
           ('bank_accounts',    'bank_accounts_by_owner'),
           ('asset_drafts',     'asset_drafts_read')
         );
  if v is not null then
    raise exception 'พบ policy อ่านที่ค้างอยู่บนตารางโมดูลทรัพย์ จะ OR ทับขอบเขต: % · ให้ตรวจแล้ว drop หรือเพิ่มเข้า allow-list ของไฟล์นี้', v;
  end if;
  raise notice 'guard 9a · policy อ่านของ 6 ตารางมีเท่าที่ประกาศไว้ (ของเดิมไม่ถูกแตะ)';
end $$;

-- 9b · ห้าม FOR ALL · ห้าม policy DELETE (§5.4) — ทั้ง 5 ตาราง + ตารางร่าง
do $$
declare v text; n int;
begin
  select string_agg(tablename || '.' || policyname || ' (' || cmd || ')', ', '), count(*) into v, n
    from pg_policies
   where schemaname = 'sri_os'
     and tablename in ('assets', 'asset_valuations', 'contracts', 'schedules', 'bank_accounts', 'asset_drafts')
     and cmd in ('ALL', 'DELETE');
  if n > 0 then
    raise exception 'โมดูลทรัพย์มี policy FOR ALL หรือ DELETE % ตัว: % · FOR ALL เอา USING ไปใช้กับ SELECT ด้วย (เคยทำให้ Manager รวมยอดทั้งพอร์ตได้) · DELETE ต้องไม่มีใครได้', n, v;
  end if;

  -- กัน guard เปล่า: ต้องมี policy เขียนครบตามที่ไฟล์นี้ประกาศ
  select count(*) into n from pg_policies
   where schemaname = 'sri_os'
     and policyname in ('assets_insert', 'assets_update', 'valuations_insert',
                        'contracts_insert', 'contracts_update',
                        'schedules_insert', 'schedules_update',
                        'bank_accounts_insert', 'bank_accounts_update',
                        'asset_drafts_read', 'asset_drafts_insert',
                        'asset_drafts_update_own', 'asset_drafts_review');
  if n <> 13 then
    raise exception 'policy ของโมดูลทรัพย์ควรมี 13 ตัว แต่นับได้ % ตัว', n;
  end if;
  raise notice 'guard 9b · policy เขียนครบ 13 ตัว · ไม่มี FOR ALL · ไม่มี DELETE';
end $$;

-- 9c · ทุกตารางใน sri_os ต้องเปิด RLS **และ** มี policy อย่างน้อยหนึ่งตัว
--      (ขยายการตรวจของ 20261007000006 ให้ครอบ asset_drafts ที่เพิ่งเพิ่ม ·
--       ตารางใหม่ที่ลืมเปิด RLS = ไม่มีด่านเลย เพราะ grants ให้ DML ทุกตาราง ·
--       เปิด RLS แต่ไม่มี policy = ปฏิเสธเงียบๆ 0 แถว ไม่ใช่ error)
do $$
declare v_off text; v_nopol text; n int;
begin
  select string_agg(c.relname, ', ' order by c.relname) into v_off
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os' and c.relkind = 'r' and not c.relrowsecurity;
  if v_off is not null then
    raise exception 'ตารางใน sri_os ที่ยังไม่เปิด RLS: %', v_off;
  end if;

  select string_agg(c.relname, ', ' order by c.relname) into v_nopol
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os' and c.relkind = 'r'
     and not exists (select 1 from pg_policies p
                      where p.schemaname = 'sri_os' and p.tablename = c.relname);
  if v_nopol is not null then
    raise exception 'ตารางที่เปิด RLS แต่ไม่มี policy เลย: % · จะปฏิเสธทุกอย่างเงียบๆ', v_nopol;
  end if;

  select count(*) into n from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os' and c.relkind = 'r';
  if n < 25 then
    raise exception 'นับตารางใน sri_os ได้ % ตาราง (ต้อง >= 25 หลังเพิ่ม asset_drafts) — guard นี้อาจไม่ได้ตรวจอะไร', n;
  end if;
  raise notice 'guard 9c · ทั้ง % ตารางใน sri_os เปิด RLS และมี policy ครบ', n;
end $$;

-- 9d · trigger function **ทุกตัว** ต้องไม่อ้างถึง fn_can
--      กฎที่บังคับด้วย trigger ต้องไม่ปิดได้ด้วยการแก้ตารางสิทธิ์
--      (ย้ำที่นี่เพื่อให้ migration พังทันที ไม่ต้องรอ roles_permissions_test ข้อ 10)
do $$
declare v text; n int;
begin
  select string_agg(distinct p.proname, ', ') into v
    from pg_trigger tg
    join pg_class c      on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    join pg_proc p       on p.oid = tg.tgfoid
   where ns.nspname = 'sri_os' and not tg.tgisinternal
     and p.prosrc ~* 'fn_can';
  if v is not null then
    raise exception 'trigger function อ้างถึง fn_can: % · กฎที่ trigger บังคับจะปิดได้จากตารางสิทธิ์', v;
  end if;

  select count(distinct p.proname) into n
    from pg_trigger tg
    join pg_class c      on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    join pg_proc p       on p.oid = tg.tgfoid
   where ns.nspname = 'sri_os' and not tg.tgisinternal;
  if n < 12 then
    raise exception 'นับ trigger function ได้ % ตัว — guard นี้อาจไม่ได้ตรวจอะไร', n;
  end if;
  raise notice 'guard 9d · trigger function ทั้ง % ตัวไม่เรียก fn_can', n;
end $$;

-- 9e · trigger ของโมดูลทรัพย์ต้องไม่ **เขียน** ตาราง ledger (กฎเหล็กข้อ 6)
--      ตรวจเฉพาะคำสั่งเขียน ไม่ใช่การเอ่ยชื่อตาราง — fn_asset_assign_guard
--      **อ่าน** transaction_lines เพื่อเช็คว่ามีบรรทัดผูกอยู่ ซึ่งถูกต้องและต้องไม่ถูกจับผิด
do $$
declare v text;
begin
  select string_agg(p.proname, ', ') into v
    from pg_trigger tg
    join pg_class c      on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    join pg_proc p       on p.oid = tg.tgfoid
   where ns.nspname = 'sri_os' and not tg.tgisinternal
     and c.relname in ('assets', 'asset_drafts')
     and p.prosrc ~* '(insert|update|delete)\s+(into\s+)?(sri_os\.)?(transactions|transaction_lines|draft_entries|cash_confirmations)\M';
  if v is not null then
    raise exception 'trigger บน assets/asset_drafts เขียนตาราง ledger: % · การอนุมัติทะเบียนต้องไม่กลายเป็นช่องลงบัญชี (กฎเหล็กข้อ 6)', v;
  end if;

  if sri_os.fn_apply_asset_draft(null::uuid) is not null then  -- ไม่ถึงบรรทัดนี้
    raise exception 'unreachable';
  end if;
exception
  when raise_exception then
    -- fn_apply_asset_draft(null) ต้องปฏิเสธ = เส้นทาง "ไม่ส่งข้อมูล" มีจริง
    raise notice 'guard 9e · trigger ของโมดูลทรัพย์ไม่เขียนตาราง ledger · fn_apply_asset_draft(null) ปฏิเสธจริง';
end $$;

-- 9f · SECURITY DEFINER ที่เพิ่มในไฟล์นี้: ห้ามเปิด PUBLIC · search_path ต้องแน่น
do $$
declare v text;
begin
  select string_agg(p.oid::regprocedure::text, ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.prosecdef
     and has_function_privilege('public', p.oid, 'execute');
  if v is not null then
    raise exception 'SECURITY DEFINER ที่ PUBLIC เรียกได้: % · ฟังก์ชันพวกนี้ข้าม RLS', v;
  end if;

  select string_agg(p.proname || ' → ' || array_to_string(p.proconfig, ','), ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.prosecdef
     and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c
                      where c in ('search_path=', 'search_path=""', 'search_path=sri_os'));
  if v is not null then
    raise exception 'SECURITY DEFINER ที่ search_path ไม่แน่น: %', v;
  end if;

  -- fn_apply_asset_draft ต้อง **ไม่** เป็น definer (ADR: definer = ประตูหลังข้าม RLS)
  if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
              where ns.nspname = 'sri_os' and p.proname = 'fn_apply_asset_draft' and p.prosecdef) then
    raise exception 'fn_apply_asset_draft เป็น SECURITY DEFINER = ทางข้าม RLS · ต้องเป็น invoker';
  end if;
  raise notice 'guard 9f · SECURITY DEFINER สะอาด · fn_apply_asset_draft เป็น invoker';
end $$;

-- 9g · ตารางร่างต้องไม่มี FK จากตาราง ledger/มูลค่าชี้มาหา (ADR เหตุผลข้อ 2)
--      ร่างถูกอ้างถึงไม่ได้ในทางโครงสร้าง ไม่ใช่เพราะมีใครจำกรอง
do $$
declare v text;
begin
  select string_agg(cl.relname || '.' || c.conname, ', ') into v
    from pg_constraint c
    join pg_class cl    on cl.oid = c.conrelid
    join pg_class rf    on rf.oid = c.confrelid
    join pg_namespace ns on ns.oid = cl.relnamespace
   where c.contype = 'f' and ns.nspname = 'sri_os' and rf.relname = 'asset_drafts';
  if v is not null then
    raise exception 'มี FK ชี้มาที่ asset_drafts: % · ร่างต้องถูกอ้างถึงไม่ได้ (ADR 0001) ไม่งั้นร่างจะหลุดเข้ามูลค่าพอร์ตได้', v;
  end if;
  raise notice 'guard 9g · ไม่มีตารางใดชี้ FK มาที่ asset_drafts';
end $$;

do $$ begin raise notice '=== 20261008000000_asset_permissions: ติดตั้งครบ ==='; end $$;
