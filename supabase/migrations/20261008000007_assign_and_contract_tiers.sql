-- ============================================================
-- SRI OS · (1) สิทธิ์ `asset.assign_manager` สำหรับการมอบหมายผู้บริหารทรัพย์
--          (2) ด่านสร้างตารางงวด **สองชั้นตาม Entity Policy** + ปิดประตูหลังฝั่ง UPDATE
--
-- ไฟล์ migration เดิม **ไม่ถูกแตะ** (apply แล้วทั้งหมด) · ทุกการแก้ทำด้วย
-- create or replace function / drop trigger if exists ... create trigger ในไฟล์นี้
--
-- ------------------------------------------------------------
-- ย้อนกลับ (rollback note) — ทำทั้งสองข้อแยกกันได้
--
-- ข้อ 1 · คืนการมอบหมายผู้บริหารให้เฉพาะ users.manage (super_admin):
--   -- create or replace function sri_os.fn_asset_assign_ok(p_asset uuid, p_manager uuid, p_owner uuid)
--   -- returns boolean language sql stable security definer set search_path = '' as $fn$
--   --   select coalesce(
--   --     (select (a.manager_user_id is not distinct from p_manager or sri_os.fn_can('users.manage'))
--   --         and (a.owner_id        is not distinct from p_owner   or sri_os.fn_can('settings.manage'))
--   --        from sri_os.assets a where a.id = p_asset),
--   --     p_manager is null or sri_os.fn_can('users.manage'));
--   -- $fn$;
--   -- delete from sri_os.role_permissions where permission_key = 'asset.assign_manager';
--   -- delete from sri_os.permissions      where key            = 'asset.assign_manager';
--   -- (ลบคีย์ออกจาก union ใน src/lib/auth/permissions.ts ด้วย ไม่งั้น check:permissions พัง)
--
-- ข้อ 2 · คืนด่านเดิม "ครบ 6 เกณฑ์ทุกผู้ถือ เฉพาะตอน INSERT":
--   -- drop trigger if exists trg_contract_gate_no_backdoor on sri_os.contracts;
--   -- create or replace function sri_os.fn_schedule_requires_complete_contract() returns trigger
--   -- language plpgsql set search_path = sri_os, public as $fn$
--   -- begin
--   --   if fn_contract_completeness(new.contract_id) < 100 then
--   --     raise exception 'สัญญา % ข้อมูลยังไม่ครบ (กรอกครบ % เปอร์เซ็นต์) สร้างตารางงวดไม่ได้',
--   --       new.contract_id, fn_contract_completeness(new.contract_id);
--   --   end if;
--   --   return new;
--   -- end $fn$;
--   -- drop view if exists sri_os.v_contract_data_health;
--   -- drop function if exists sri_os.fn_contract_gate_unmet(sri_os.contracts);
--   -- drop function if exists sri_os.fn_contract_gate_missing(sri_os.contracts, text);
--   -- drop function if exists sri_os.fn_contract_gate_fields(text);
--   -- drop function if exists sri_os.fn_contract_gate_no_backdoor();
--   -- delete from sri_os.settings where key = 'contract.schedule_gate';
--   -- **ย้อนแล้วเงินกู้ในบ้านที่ไม่มีสัญญาเป็นกระดาษจะสร้างตารางงวดไม่ได้อีก**
--   --   = ไม่มีค้างรับในระบบ ซึ่งแย่กว่ามีข้อมูลไม่ครบ (เหตุผลที่ไฟล์นี้มีอยู่)
--
-- idempotent: insert ... on conflict · create or replace function ·
--   drop trigger if exists ก่อน create trigger · drop view if exists ก่อน create view ·
--   grant/revoke ซ้ำได้ · ไม่มี insert into settings (ค่าเกณฑ์เป็นของผู้ใช้ ไม่ใช่ของ migration)
-- ============================================================

set search_path = sri_os, public;

-- ############################################################
-- ข้อ 1 · การมอบหมายผู้บริหารทรัพย์แยกออกจาก users.manage
-- ############################################################
--
-- ปัญหา: fn_asset_assign_ok() (20261008000000:541) เช็ค `users.manage` ซึ่งมีแต่
--   super_admin → Management ตั้ง assets.manager_user_id ไม่ได้เลย ขัดคำสั่งลูกพี่ (08/10)
--
-- ทำไม**ไม่**แก้ด้วยการให้ users.manage แก่ Management:
--   users.manage คุม "ใครอยู่ตำแหน่งไหน" (app_users.role) + ติ๊ก role_permissions +
--   แจกสิทธิ์เห็น owner (user_owner_access) ด้วย → กว้างกว่าที่สั่งมาก และจะทำให้
--   Management เลื่อนตำแหน่งคน/ขยายขอบเขตการเห็นได้ทั้งองค์กรในคราวเดียว
--
-- เหตุผลเดิมของข้อจำกัดนี้ **ยังอยู่ครบ**: การมอบหมายผู้บริหาร = การแจกสิทธิ์เห็นมูลค่า
--   (asset.view_assigned ผูกกับ assets.manager_user_id) → ถ้า Manager/Staff ทำได้
--   จะแจกสิทธิ์ให้ตัวเองได้ · สิทธิ์ใหม่ให้ **Management ขึ้นไปเท่านั้น** เหตุผลจึงยังจริง
--   และ Manager/Staff ยังทำไม่ได้เหมือนเดิม (มีเทสต์ยืนยันทั้งสองตำแหน่ง)
--
-- ชื่อคีย์: `asset.assign_manager` (ไม่ใช่ `asset.assign` เฉยๆ) เพราะในตารางนี้มี
--   "การมอบหมาย" สองแบบที่ต้องแยกกันให้ชัด: ย้าย manager_user_id (คีย์นี้) กับ
--   ย้าย owner_id (settings.manage) · ชื่อที่ไม่บอกว่ามอบหมายอะไรจะถูกเข้าใจผิดแน่
--
-- ขอบเขตที่ **ไม่** เปลี่ยน (ตรวจแล้วทีละจุดที่เช็ค users.manage · ไม่เปลี่ยนเหมา):
--   · app_users_read / users_write          — ใครอยู่ตำแหน่งไหน → users.manage ตามเดิม
--   · owner_access_read / owner_access_write — แจกสิทธิ์เห็น Entity → users.manage ตามเดิม
--   · roles / permissions / role_permissions — migration เท่านั้น (20261007000003) ตามเดิม
--   · assets.owner_id                        — settings.manage ตามเดิม
--   เหลือจุดเดียวที่เป็นเรื่อง "มอบหมายผู้บริหารทรัพย์" คือ fn_asset_assign_ok()

insert into permissions (key, label, note) values
  ('asset.assign_manager', 'มอบหมายผู้บริหารทรัพย์',
   'ตั้ง/ย้าย/ล้าง assets.manager_user_id เท่านั้น · Management ขึ้นไป (ลูกพี่สั่ง 08/10) · **ไม่**รวมย้ายผู้ถือ (settings.manage) และ**ไม่**รวมจัดการคน/ตำแหน่ง/ขอบเขตการเห็น Entity (users.manage) · Manager/Staff ไม่มี เพราะการมอบหมาย = การแจกสิทธิ์เห็นมูลค่า ถ้าให้ Manager จะแจกให้ตัวเองได้')
on conflict (key) do update
  set label = excluded.label, note = excluded.note;

insert into role_permissions (role_key, permission_key)
select r.key, p.key
  from (values
    -- permission               super_admin  management  manager  staff
    ('asset.assign_manager',    true,  true,  false, false)
  ) as p(key, super_admin, management, manager, staff)
  cross join lateral (values
    ('super_admin', p.super_admin),
    ('management',  p.management),
    ('manager',     p.manager),
    ('staff',       p.staff)
  ) as r(key, allowed)
 where r.allowed
on conflict (role_key, permission_key) do nothing;

-- โครงเดิมทุกบรรทัด เปลี่ยนเฉพาะคีย์ที่ถาม (users.manage → asset.assign_manager)
-- ลายเซ็นเหมือนเดิม → ACL ที่ 20261008000000 ตั้งไว้ และ policy assets_insert/assets_update
-- ที่เรียกฟังก์ชันนี้ ไม่ต้องแก้อะไรเลย
create or replace function fn_asset_assign_ok(p_asset uuid, p_manager uuid, p_owner uuid)
returns boolean
language sql stable security definer set search_path = '' as $fn$
  select coalesce(
    (select (a.manager_user_id is not distinct from p_manager or sri_os.fn_can('asset.assign_manager'))
        and (a.owner_id        is not distinct from p_owner   or sri_os.fn_can('settings.manage'))
       from sri_os.assets a
      where a.id = p_asset),
    p_manager is null or sri_os.fn_can('asset.assign_manager')
  );
$fn$;
comment on function fn_asset_assign_ok(uuid, uuid, uuid) is
  '§3.2 (แก้ 08/10) · manager_user_id เปลี่ยน/ตั้งได้เฉพาะคนที่มี asset.assign_manager (Management + Super Admin) · owner_id เฉพาะ settings.manage · เรียกจาก WITH CHECK ของ assets_insert/assets_update ไม่ใช่จาก trigger (trigger ห้ามเรียก fn_can)';

-- กันตกหล่น: ถ้าวันหนึ่งมีคนย้าย asset.assign_manager ไปให้ manager/staff ใน
-- role_permissions ไฟล์นี้จะไม่รู้ตัว → guard ตรวจ ณ ตอน migrate ว่าตั้งต้นถูก
do $$
declare v text;
begin
  select string_agg(role_key, ', ' order by role_key) into v
    from role_permissions
   where permission_key = 'asset.assign_manager'
     and role_key in ('manager', 'staff');
  if v is not null then
    raise exception 'asset.assign_manager ถูกผูกกับ % · ตำแหน่งนั้นจะแจกสิทธิ์เห็นมูลค่าให้ตัวเองได้ (เหตุผลเดิมของข้อจำกัด §3.2)', v;
  end if;
end $$;

-- ############################################################
-- ข้อ 2 · ด่านสร้างตารางงวดสองชั้นตาม Entity Policy
-- ############################################################
--
-- ปัญหา: fn_schedule_requires_complete_contract (20260917000003:203) บล็อกจนสัญญา
--   ครบ 6 เกณฑ์ → **เงินกู้ในบ้านที่ไม่มีสัญญาเป็นกระดาษ สร้างตารางงวดไม่ได้เลย**
--   = ไม่มีค้างรับในระบบ ซึ่งแย่กว่ามีข้อมูลไม่ครบ และขัด LEDGER_RULES.md §4
--   ที่ personal_flexible ให้ override เรื่องไฟล์หลักฐาน/ไม่ผูก contact ได้
--
-- ชั้น (ก) `blocking` — ขาดแล้ว **คำนวณงวดไม่ได้จริง** → บล็อกทุกผู้ถือ
--   principal · rate · start_date · term (= end_date หรือ installments อย่างน้อยหนึ่ง)
--   ไม่ใช่เรื่องนโยบาย แต่เป็นเรื่องเลขคำนวณไม่ออก จึงไม่มีใครได้ override
--
-- ชั้น (ข) `document` — เอกสาร → บล็อกเฉพาะ corporate_strict
--   counterparty_contact_id · file_urls
--   ฝั่งบุคคลผ่านได้ แต่ขึ้น **ธง Data health** (warning ตอนเขียน + view ให้หน้าจออ่าน)
--   ไม่ใช่เงียบ — "ไม่บล็อก" ไม่เท่ากับ "ไม่บอก"
--
-- ค่าตั้งต้นสองชั้นรวมกัน = เกณฑ์ 6 ข้อเดิมพอดี → **corporate_strict ไม่หลวมลงแม้แต่นิด**
--   สิ่งที่คลายคือฝั่งบุคคลเท่านั้น ตามที่ลูกพี่สั่ง
--
-- ด่านเดิมเป็นทางเดียว (BEFORE INSERT บน schedules): ใส่งวดตอนสัญญาครบ แล้วไปลบ
--   contact/ไฟล์ทีหลังได้ → ไฟล์นี้เพิ่ม trigger BEFORE UPDATE บน contracts ด้วย

-- ------------------------------------------------------------
-- 2.1 · เกณฑ์อยู่ใน settings (กฎข้อ 5 ของ CLAUDE.md) · ว่าง = ใช้ค่าตั้งต้นที่เข้ม
-- ------------------------------------------------------------
-- settings ตอนนี้ว่างและไฟล์นี้เป็น "คนอ่านคนแรก" → การจัดการค่าที่ไม่มีต้องชัด:
--   · ไม่มีแถว            → ค่าตั้งต้นในโค้ด (= 6 เกณฑ์เดิม) **ไม่ใช่ "ไม่บังคับอะไร"**
--   · มีแถวแต่รูปไม่ถูก    → raise (ไม่เดาให้ เพราะเดาผิดทางหลวมคือตัวเลขผิดเงียบๆ)
--   · ชั้นใดชั้นหนึ่งเป็น [] → raise (ปิดทั้งชั้นไม่ได้ · ลบแถวทั้งแถวถ้าจะกลับค่าตั้งต้น)
--   · ชื่อช่องที่ไม่รู้จัก   → raise (แบบเดียวกับ npm run sync:rules ที่พังเมื่อเจอฟิลด์ใหม่)
-- จึงไม่มีทางที่ "ตาราง settings ว่าง" หรือ "ตั้งค่าผิด" จะแปลว่าไม่บังคับอะไรเลย
--
-- security definer: ค่าเกณฑ์ต้องเป็นค่าเดียวกันสำหรับทุกคน ไม่ใช่ขึ้นกับว่าใครอ่าน
--   settings ได้แค่ไหน (ถ้าเป็น invoker แล้ววันหนึ่ง policy settings_read แคบลง
--   ด่านจะคลายเองเงียบๆ ให้คนที่อ่านไม่เห็น = fail open ซึ่งห้าม)
create or replace function fn_contract_gate_fields(p_tier text) returns text[]
language plpgsql stable security definer set search_path = '' as $fn$
declare
  -- ชื่อช่องที่ด่านรู้วิธีตรวจ · เพิ่มที่นี่ต้องเพิ่มวิธีตรวจใน fn_contract_gate_missing ด้วย
  c_vocab text[] := array[
    'principal', 'rate', 'rate_period', 'interest_method', 'start_date',
    'end_date', 'installments', 'term', 'payment_day',
    'counterparty_contact_id', 'file_urls', 'deposit', 'redemption_deadline'];
  v_cfg jsonb;
  v_arr text[];
  v_bad text;
begin
  if p_tier is null or p_tier not in ('blocking', 'document') then
    raise exception 'ชั้นของด่านต้องเป็น blocking หรือ document (ได้ %)', coalesce(p_tier, 'NULL');
  end if;

  select s.value into v_cfg from sri_os.settings s where s.key = 'contract.schedule_gate';

  if v_cfg is null then
    -- ค่าตั้งต้น = 6 เกณฑ์เดิมของ fn_contract_completeness แยกเป็นสองชั้น
    v_arr := case p_tier
               when 'blocking' then array['principal', 'rate', 'start_date', 'term']
               else                 array['counterparty_contact_id', 'file_urls']
             end;
  else
    if jsonb_typeof(v_cfg) <> 'object'
       or not jsonb_exists(v_cfg, 'blocking') or not jsonb_exists(v_cfg, 'document') then
      raise exception 'settings[''contract.schedule_gate''] ต้องเป็น object ที่มีคีย์ blocking และ document ครบทั้งคู่ (ได้ %) · มีแถวแต่ไม่ครบ = ปฏิเสธ ไม่ใช่เติมค่าที่ขาดให้เอง', v_cfg;
    end if;
    if jsonb_typeof(v_cfg -> p_tier) <> 'array' then
      raise exception 'settings[''contract.schedule_gate''].% ต้องเป็น array ของชื่อช่อง (ได้ %)', p_tier, jsonb_typeof(v_cfg -> p_tier);
    end if;
    select array_agg(x order by x) into v_arr
      from jsonb_array_elements_text(v_cfg -> p_tier) x;
    v_arr := coalesce(v_arr, '{}'::text[]);
    if cardinality(v_arr) = 0 then
      raise exception 'settings[''contract.schedule_gate''].% ว่าง · ปิดทั้งชั้นไม่ได้ (blocking ว่าง = สร้างงวดจากสัญญาเปล่าได้ · document ว่าง = ปลดเอกสารของ corporate_strict ซึ่ง LEDGER_RULES §4 ห้าม override) · ลบแถว settings ทั้งแถวถ้าต้องการกลับไปใช้ค่าตั้งต้น', p_tier;
    end if;
  end if;

  select string_agg(x, ', ' order by x) into v_bad
    from unnest(v_arr) x where not (x = any (c_vocab));
  if v_bad is not null then
    raise exception 'เกณฑ์ใน settings อ้างชื่อช่องที่ด่านไม่รู้จัก: % · ที่รู้จักมี: % · พังทันทีแทนที่จะมองข้ามเงียบๆ (ไม่งั้นพิมพ์ชื่อผิดหนึ่งตัว = เกณฑ์นั้นไม่ถูกบังคับเลย)',
      v_bad, array_to_string(c_vocab, ', ');
  end if;

  return v_arr;
end $fn$;
comment on function fn_contract_gate_fields(text) is
  'เกณฑ์ของด่านตารางงวดต่อชั้น · อ่านจาก settings[''contract.schedule_gate''] (กฎข้อ 5) · ไม่มีแถว = ค่าตั้งต้นที่เข้มเท่าเกณฑ์ 6 ข้อเดิม · รูปผิด/ชั้นว่าง/ชื่อช่องไม่รู้จัก = raise ไม่ใช่ปล่อยผ่าน';

-- ------------------------------------------------------------
-- 2.2 · ช่องที่ขาดของสัญญาหนึ่งแถว ต่อชั้น
--       รับ **แถว** ไม่ใช่ id เพราะ trigger ฝั่ง UPDATE ต้องตรวจค่า NEW
--       ที่ยังไม่ถูกเขียนลงตาราง (อ่านจากตารางตอน BEFORE UPDATE จะได้ค่าเก่า)
-- ------------------------------------------------------------
create or replace function fn_contract_gate_missing(p_row sri_os.contracts, p_tier text)
returns text[]
language plpgsql stable set search_path = '' as $fn$
declare f text; v_out text[] := '{}'::text[]; v_miss boolean;
begin
  foreach f in array sri_os.fn_contract_gate_fields(p_tier) loop
    v_miss := case f
      when 'principal'               then p_row.principal is null
      when 'rate'                    then p_row.rate is null
      when 'rate_period'             then p_row.rate_period is null
      when 'interest_method'         then p_row.interest_method is null
      when 'start_date'              then p_row.start_date is null
      when 'end_date'                then p_row.end_date is null
      when 'installments'            then p_row.installments is null
      -- "term" = พอคำนวณงวดได้ ต้องมีอย่างน้อยหนึ่งใน end_date / installments
      when 'term'                    then (p_row.end_date is null and p_row.installments is null)
      when 'payment_day'             then p_row.payment_day is null
      when 'counterparty_contact_id' then p_row.counterparty_contact_id is null
      when 'file_urls'               then coalesce(cardinality(p_row.file_urls), 0) = 0
      when 'deposit'                 then p_row.deposit is null
      when 'redemption_deadline'     then p_row.redemption_deadline is null
      else null   -- ไม่รู้จัก → null → raise ข้างล่าง (ห้ามตีความว่า "ไม่ขาด")
    end;
    if v_miss is null then
      raise exception 'ด่านตารางงวดไม่รู้วิธีตรวจเกณฑ์ % · เพิ่มใน c_vocab แล้วลืมเพิ่มวิธีตรวจ', f;
    end if;
    if v_miss then v_out := v_out || f; end if;
  end loop;
  return v_out;
end $fn$;
comment on function fn_contract_gate_missing(sri_os.contracts, text) is
  'ช่องที่ขาดของสัญญา (รับทั้งแถว จึงใช้ตรวจค่า NEW ตอน BEFORE UPDATE ได้) · ชั้น blocking = คำนวณงวดไม่ได้ · ชั้น document = เอกสาร';

-- ------------------------------------------------------------
-- 2.3 · ช่องที่ขาด **และบล็อกจริง** สำหรับสัญญาแถวนั้น ตาม Entity Policy ของผู้ถือ
--       definer: นโยบายของผู้ถือต้องอ่านได้ครบจริง ไม่ใช่เท่าที่ผู้เขียนมองเห็น
--       ไม่พบผู้ถือ = ถือว่า corporate_strict (เข้มกว่า) ไม่ใช่ปล่อยผ่าน
-- ------------------------------------------------------------
create or replace function fn_contract_gate_unmet(p_row sri_os.contracts) returns text[]
language plpgsql stable security definer set search_path = '' as $fn$
declare v_policy sri_os.owner_policy; v_out text[];
begin
  select o.policy into v_policy from sri_os.owners o where o.id = p_row.owner_id;
  if v_policy is null then v_policy := 'corporate_strict'; end if;

  v_out := sri_os.fn_contract_gate_missing(p_row, 'blocking');
  if v_policy = 'corporate_strict' then
    v_out := v_out || sri_os.fn_contract_gate_missing(p_row, 'document');
  end if;
  return v_out;
end $fn$;
comment on function fn_contract_gate_unmet(sri_os.contracts) is
  'ช่องที่ขาดแล้ว**บล็อก**จริง · ทุกผู้ถือติดชั้น blocking · เฉพาะ corporate_strict ติดชั้น document ด้วย (LEDGER_RULES §4) · ไม่พบผู้ถือ = ถือว่าเข้มที่สุด';

-- ------------------------------------------------------------
-- 2.4 · ด่านตอน INSERT งวด (แทนของเดิมทั้งตัว · ชื่อ/ลายเซ็น/trigger เดิม)
--       search_path รัดเป็น '' ตามที่ต้องทำ (เดิมเป็น sri_os, public)
--       definer: ต้องอ่านสัญญา/ผู้ถือให้ครบจริง · **ไม่เรียก fn_can เลย** ตามกฎ
--         "trigger ที่บังคับกฎข้อมูลห้ามถามสิทธิ์" (เทสต์ข้อ 10/16 อ่าน prosrc จริง)
-- ------------------------------------------------------------
create or replace function fn_schedule_requires_complete_contract() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_row sri_os.contracts;
  v_policy sri_os.owner_policy;
  v_unmet text[];
  v_flags text[];
begin
  select c.* into v_row from sri_os.contracts c where c.id = new.contract_id;
  if v_row.id is null then
    raise exception 'สร้างตารางงวดไม่ได้: ไม่พบสัญญา % (ข้อมูลไม่ครบต้องปฏิเสธ ไม่ใช่ปล่อยผ่าน)', new.contract_id;
  end if;

  select o.policy into v_policy from sri_os.owners o where o.id = v_row.owner_id;
  v_unmet := sri_os.fn_contract_gate_unmet(v_row);

  if cardinality(v_unmet) > 0 then
    raise exception 'สัญญา % สร้างตารางงวดไม่ได้: ยังขาด % · นโยบายผู้ถือ = %',
      coalesce(v_row.code, new.contract_id::text),
      array_to_string(v_unmet, ', '),
      coalesce(v_policy::text, 'ไม่พบผู้ถือ (ถือว่า corporate_strict)');
  end if;

  -- ฝั่งบุคคล: เอกสารขาดได้ แต่ต้อง **ไม่เงียบ** → warning ตอนเขียน + v_contract_data_health
  if coalesce(v_policy, 'corporate_strict') <> 'corporate_strict' then
    v_flags := sri_os.fn_contract_gate_missing(v_row, 'document');
    if cardinality(v_flags) > 0 then
      raise warning 'Data health · สัญญา % มีตารางงวดแต่เอกสารยังขาด % (personal_flexible override ได้ตาม LEDGER_RULES §4) → ดูที่ sri_os.v_contract_data_health',
        coalesce(v_row.code, new.contract_id::text), array_to_string(v_flags, ', ');
    end if;
  end if;

  return new;
end $fn$;
comment on function fn_schedule_requires_complete_contract() is
  'ด่านสร้างตารางงวด (แก้ 08/10) · ชั้น blocking บล็อกทุกผู้ถือ · ชั้น document บล็อกเฉพาะ corporate_strict ส่วนฝั่งบุคคลเป็นธง Data health · เกณฑ์มาจาก settings ไม่ hard-code · ไม่เรียก fn_can';

drop trigger if exists trg_schedule_complete on schedules;
create trigger trg_schedule_complete
  before insert on schedules
  for each row execute function fn_schedule_requires_complete_contract();

-- ------------------------------------------------------------
-- 2.5 · ปิดประตูหลัง: แก้สัญญาที่ **มีงวดอยู่แล้ว** ให้แย่ลงไม่ได้
--
--   เกณฑ์ที่ใช้คือ "ไม่ทำให้ขาดเพิ่ม" ไม่ใช่ "ต้องครบ" เพราะ:
--     · สัญญาที่ไม่มีงวด แก้ได้อิสระ (ด่านจริงอยู่ตอนใส่งวด) → ร่าง/เก็บข้อมูลทีหลังได้
--     · สัญญาบุคคลที่ตั้งใจให้เอกสารขาดได้ ต้องยัง **แก้/ปิด/เลื่อน** ได้ตามปกติ
--       ถ้าใช้เกณฑ์ "ต้องครบ" แถวพวกนี้จะแก้อะไรไม่ได้เลยตลอดไป = กันแน่นเกินจนพัง
--     · และยัง **ซ่อมให้ดีขึ้นได้เสมอ** (เติมไฟล์/เติม contact ผ่านได้)
--   ที่ห้ามคือ "ลบของที่เคยมี" ซึ่งเป็นประตูหลังที่ผู้ตรวจชี้ไว้พอดี
-- ------------------------------------------------------------
create or replace function fn_contract_gate_no_backdoor() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare v_new text[]; v_old text[]; v_added text;
begin
  if not exists (select 1 from sri_os.schedules s where s.contract_id = new.id) then
    return new;
  end if;

  v_new := sri_os.fn_contract_gate_unmet(new);
  v_old := sri_os.fn_contract_gate_unmet(old);

  select string_agg(x, ', ' order by x) into v_added
    from unnest(v_new) x where not (x = any (v_old));

  if v_added is not null then
    raise exception 'สัญญา % มีตารางงวดอยู่แล้ว · การแก้นี้ทำให้ขาดเพิ่ม: % · ด่านตอนใส่งวดจะไร้ความหมายถ้าถอนข้อมูลทีหลังได้ (เติมให้ครบขึ้นทำได้ตามปกติ)',
      coalesce(new.code, new.id::text), v_added;
  end if;

  return new;
end $fn$;
comment on function fn_contract_gate_no_backdoor() is
  'กันประตูหลังของด่านตารางงวด · สัญญาที่มีงวดแล้วห้ามแก้ให้ขาดเพิ่ม (ลบ contact/ไฟล์/เงินต้นทีหลัง) · สัญญาที่ยังไม่มีงวดแก้ได้อิสระ · เติมข้อมูลให้ครบขึ้นได้เสมอ · ไม่เรียก fn_can';

drop trigger if exists trg_contract_gate_no_backdoor on contracts;
create trigger trg_contract_gate_no_backdoor
  before update on contracts
  for each row execute function fn_contract_gate_no_backdoor();
comment on trigger trg_contract_gate_no_backdoor on contracts is
  'ด่านเดิมเป็น BEFORE INSERT บน schedules เท่านั้น = ใส่งวดตอนครบแล้วลบ contact/ไฟล์ทีหลังได้ · trigger นี้ปิดประตูหลังนั้น';

-- ------------------------------------------------------------
-- 2.6 · ธง Data health ที่หน้าจออ่านได้ (ชั้น ข ของฝั่งบุคคลต้องไม่หายไปเงียบๆ)
--       security_invoker = ผลถูกกรองด้วย RLS ของผู้เรียกตามเดิม
-- ------------------------------------------------------------
drop view if exists v_contract_data_health;
create view v_contract_data_health with (security_invoker = true) as
select c.id          as contract_id,
       c.code,
       c.owner_id,
       o.policy,
       c.asset_id,
       c.type,
       c.status,
       fn_contract_completeness(c.id)                   as completeness,
       fn_contract_gate_missing(c, 'blocking')          as missing_blocking,
       fn_contract_gate_missing(c, 'document')          as missing_document,
       cardinality(fn_contract_gate_missing(c, 'blocking')) > 0 as blocks_schedule,
       (o.policy <> 'corporate_strict'
         and cardinality(fn_contract_gate_missing(c, 'document')) > 0) as doc_health_flag,
       exists (select 1 from schedules s where s.contract_id = c.id) as has_schedule
  from contracts c
  join owners o on o.id = c.owner_id;
comment on view v_contract_data_health is
  'ธง Data health ของสัญญา · blocks_schedule = ชั้น ก ขาด (สร้างงวดไม่ได้ทุกผู้ถือ) · doc_health_flag = ชั้น ข ขาดในฝั่งบุคคล (สร้างงวดได้แต่ต้องเตือน) · corporate_strict ที่ชั้น ข ขาดจะโผล่ใน missing_document และสร้างงวดไม่ได้อยู่แล้ว';

alter view v_contract_data_health set (security_invoker = true);

-- ------------------------------------------------------------
-- 2.7 · ACL — ฟังก์ชันใหม่ติด PUBLIC EXECUTE มาเองตอน create → ปิดทุกตัวก่อน
--       แล้วเปิดเฉพาะที่ **ผู้เรียก** ต้องใช้จริง (view เป็น security_invoker)
--       trigger function เปิดให้ authenticated ไม่ได้ (เรียกตรงจากข้างนอกต้องไม่ได้)
-- ------------------------------------------------------------
do $$
declare r record; v text;
  allow text[] := array[
    'fn_contract_gate_fields(text)',                        -- view อ่านผ่าน gate_missing
    'fn_contract_gate_missing(sri_os.contracts,text)'       -- view อ่านตรง
  ];
begin
  for r in
    select p.oid::regprocedure::text as sig
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'sri_os'
       and p.proname in ('fn_contract_gate_fields', 'fn_contract_gate_missing',
                         'fn_contract_gate_unmet', 'fn_contract_gate_no_backdoor',
                         'fn_schedule_requires_complete_contract')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
  end loop;

  foreach v in array allow loop
    if to_regprocedure('sri_os.' || v) is null then
      raise exception 'allow-list อ้างฟังก์ชันที่ไม่มีอยู่: sri_os.% · ลายเซ็นเปลี่ยนหรือสะกดผิด → view จะล้มด้วย permission denied', v;
    end if;
    execute format('grant execute on function sri_os.%s to authenticated', v);
  end loop;
end $$;

grant select on v_contract_data_health to authenticated;
revoke insert, update, delete on v_contract_data_health from authenticated;
do $$ begin
  execute 'revoke all on sri_os.v_contract_data_health from anon';
exception when undefined_object then
  raise notice 'ไม่มี role anon ในคลัสเตอร์นี้ — ข้าม revoke';
end $$;

-- ############################################################
-- guard ท้ายไฟล์ — พังให้เห็น ไม่ใช่ raise notice
-- ############################################################

-- (ก) trigger ที่ไฟล์นี้แตะ ต้องไม่ถามสิทธิ์ (กฎเงิน/กฎข้อมูลใช้กับทุกคนเท่ากัน)
--     และเรียกตรงจาก authenticated ไม่ได้
do $$
declare v text;
begin
  select string_agg(p.proname, ', ' order by p.proname) into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.proname in ('fn_schedule_requires_complete_contract', 'fn_contract_gate_no_backdoor')
     and (p.prosrc ~* 'fn_can'
       or has_function_privilege('public', p.oid, 'execute')
       or has_function_privilege('anon', p.oid, 'execute')
       or has_function_privilege('authenticated', p.oid, 'execute'));
  if v is not null then
    raise exception 'trigger function ของด่านตารางงวดหลวม (ถามสิทธิ์ / เรียกตรงได้): %', v;
  end if;
end $$;

-- (ข) SECURITY DEFINER ที่ไฟล์นี้เพิ่ม ต้องล็อก search_path = '' ทุกตัว
do $$
declare v text;
begin
  select string_agg(p.proname || ' → ' || coalesce(array_to_string(p.proconfig, ','), '(ไม่ตั้ง)'), ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.prosecdef
     and p.proname in ('fn_asset_assign_ok', 'fn_contract_gate_fields', 'fn_contract_gate_unmet',
                       'fn_schedule_requires_complete_contract', 'fn_contract_gate_no_backdoor')
     and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c in ('search_path=', 'search_path=""'));
  if v is not null then
    raise exception 'SECURITY DEFINER ที่ search_path ไม่แน่น: %', v;
  end if;
end $$;

-- (ค) ด่านต้องยังอยู่จริงทั้งสองทาง (INSERT งวด + UPDATE สัญญา)
do $$
begin
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'sri_os.schedules'::regclass and not tgisinternal
                    and tgname = 'trg_schedule_complete'
                    and (tgtype & 4) <> 0 and (tgtype & 2) <> 0 and (tgtype & 1) <> 0) then
    raise exception 'หาย: before insert for each row trg_schedule_complete บน schedules';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'sri_os.contracts'::regclass and not tgisinternal
                    and tgname = 'trg_contract_gate_no_backdoor'
                    and (tgtype & 16) <> 0 and (tgtype & 2) <> 0 and (tgtype & 1) <> 0) then
    raise exception 'หาย: before update for each row trg_contract_gate_no_backdoor บน contracts';
  end if;
end $$;

-- (ง) ค่าตั้งต้นเมื่อ settings ไม่มีแถว ต้องเข้มเท่าเกณฑ์ 6 ข้อเดิมพอดี
--     (ตาราง settings ว่าง **ห้าม** แปลว่าไม่บังคับอะไรเลย)
do $$
declare a text[]; b text[];
begin
  if not exists (select 1 from settings where key = 'contract.schedule_gate') then
    a := fn_contract_gate_fields('blocking');
    b := fn_contract_gate_fields('document');
    if a <> array['principal', 'rate', 'start_date', 'term']
       or b <> array['counterparty_contact_id', 'file_urls'] then
      raise exception 'ค่าตั้งต้นของด่านเพี้ยน: blocking=% document=% · รวมกันต้องเท่าเกณฑ์ 6 ข้อเดิม', a, b;
    end if;
    raise notice 'settings ยังไม่มีคีย์ contract.schedule_gate → ใช้ค่าตั้งต้น blocking=% document=%', a, b;
  else
    raise notice 'settings มีคีย์ contract.schedule_gate อยู่แล้ว → ไม่ทับค่าของผู้ใช้';
  end if;
end $$;
