-- ============================================================
-- SRI OS · "อนุมัติแล้ว" ต้องเป็นจริงเสมอ + สถานะงวดต้องตามรายการที่ไม่มีผลแล้ว
--          + ร่องรอยของตารางกฎและผังบัญชี
--
-- ปิดข้อบกพร่อง 4 ข้อที่ผู้ตรวจรายงาน (ของ 20261008000000_asset_permissions.sql
--   และ 20261008000005_access_audit.sql) · ไฟล์เดิม **ไม่ถูกแตะ** (apply แล้ว)
--   ทุกการแก้ทำด้วย create or replace / create trigger ... if exists ในไฟล์นี้
--
-- ------------------------------------------------------------
-- (1) อนุมัติร่างแล้วแต่ patch ไม่ถูกนำไปใช้ — เงียบที่สุด
--     policy asset_drafts_review (20261008000000:654) ให้ผู้อนุมัติ UPDATE
--     status='approved' + applied_asset_id ได้ตรงๆ โดยไม่ผ่าน fn_apply_asset_draft()
--     → Manager อนุมัติร่างที่มี patch {"location":"..."} ได้ โดย assets.location
--       ไม่เปลี่ยน · คิวขึ้น approved · ไม่มีอะไรบอกใคร
--     ขัดกับ CHECK asset_drafts_applied_iff_approved และคอมเมนต์ของไฟล์เดียวกัน
--     (บรรทัด 216-218 / 248-249: "อนุมัติ ⇔ มีทรัพย์ที่ถูกสร้าง/แก้จริง")
--
--     **วิธีที่เลือก: ตรวจ "ผล" ไม่ใช่ "เส้นทาง"**
--       fn_asset_draft_frozen() เทียบ patch กับแถวใน assets ทุกคีย์ ตอนเปลี่ยนเป็น
--       approved · ไม่ตรงแม้ช่องเดียว = ปฏิเสธ
--     ทำไมไม่ปิด UPDATE ตรงแล้วบังคับให้ผ่านฟังก์ชันเดียว: "ผ่านฟังก์ชันไหน" พิสูจน์
--       ที่ DB ไม่ได้แบบปลอมไม่ได้ (marker ใน GUC ผู้ใช้ตั้งเองได้ · PG_CONTEXT
--       ขึ้นกับชื่อที่ format ออกมา) ส่วน "ผลลัพธ์ตรงกับร่างไหม" พิสูจน์ได้ 100%
--       จากแถวจริง และยังปิดเส้นทางที่เรายังไม่รู้จักในอนาคตด้วย
--     การปฏิเสธร่าง (reject) ไม่ถูกแตะ — เงื่อนไขใหม่อยู่ในสาขา status='approved'
--     เท่านั้น · policy asset_drafts_review / asset_drafts_update_own คงเดิม
--
-- ------------------------------------------------------------
-- (2) ร่าง kind='create' ที่ชี้ไปทรัพย์ที่มีอยู่ก่อน = เลี่ยงกฎ "ทรัพย์ชิ้นใหม่ต้อง
--     Management อนุมัติ" · Manager คัดลอก name/class_id/category_id จากทรัพย์ที่ตน
--     บริหารมาเป็นร่าง แล้วอนุมัติโดยชี้ applied_asset_id กลับไปที่ทรัพย์เดิมนั้น
--     → เช็ค name/class/category ของไฟล์เดิมผ่านหมด แต่ไม่มีทรัพย์ใหม่เกิดขึ้น
--
--     **ข้อพิสูจน์ว่า "เกิดจากร่างนี้จริง" ที่ปลอมไม่ได้ สองชั้น**
--       ก. assets.created_at = now() (= transaction_timestamp ของธุรกรรมที่อนุมัติ)
--          + trigger ใหม่ trg_asset_created_at_immutable ทำให้ created_at แก้ไม่ได้
--       ข. audit_log ต้องมีแถว action='insert' ของทรัพย์นั้นที่ at = now()
--          audit_log **ไม่มี policy INSERT** และ append-only (20261008000004)
--          → authenticated ปลอมแถวนี้ไม่ได้ · ถึง Management จะ insert ทรัพย์ด้วย
--            created_at ย้อนหลัง/ล่วงหน้าเอง ชั้น (ข) ก็ยังไม่ผ่าน
--       ค. unique index บางส่วน: ทรัพย์หนึ่งชิ้นถูก "อ้างว่าเกิดจากร่าง" ได้ครั้งเดียว
--          (เฉพาะ kind='create' — ร่างแก้ไขหลายใบของทรัพย์เดียวกันต้องอนุมัติได้ต่อ)
--     ไม่ใช้ FK assets → asset_drafts เพราะ guard 9g ของ 20261008000000 ห้าม
--       (ADR 0001: ร่างต้องถูกอ้างถึงไม่ได้ในทางโครงสร้าง)
--
-- ------------------------------------------------------------
-- (3) **กระทบตัวเลขเงิน** · void รายการแล้ว schedules.status ยังเป็น 'received'
--     fn_schedule_status_mirror (20261008000000:477) คืนค่าออกก่อนเมื่อสถานะไม่เปลี่ยน
--     และ **ไม่มีใครเลยที่อัปเดต schedules เมื่อ ledger เปลี่ยน** → ยอดค้างรับต่ำกว่าจริง
--
--     เส้นทางที่ทำให้รายการ "ไม่มีผลแล้ว" มีสองทาง ไม่ใช่ทางเดียว:
--       - status → 'void'
--       - มีรายการกลับรายการ (reverses_id ชี้มา) ที่ยังไม่ถูก void
--         (ของเดิมไม่บังคับให้ต้นฉบับกลายเป็น void ด้วย — ดู fn_reverse_link_ok)
--     และกลับทางได้: รายการกลับรายการที่ลงผิดแล้ว void ทิ้ง → ต้นฉบับมีผลอีกครั้ง
--
--     **ไม่เดาค่า**: สถานะงวดคำนวณจากสูตรเดียว fn_schedule_ledger_status() ที่ใช้
--     เงื่อนไขชุดเดียวกับที่ fn_schedule_status_mirror ใช้ตรวจอยู่แล้ว →
--     ค่าที่เขียนกลับจึงผ่านการตรวจของ mirror ได้เสมอโดยนิยาม ไม่ใช่เพราะเลือกค่าที่ดูเข้าท่า
--       ร่างยังรออนุมัติ                     → 'drafted'
--       รายการ posted + มีใบยืนยันเงินแล้ว   → 'received'
--       รายการ posted ยังไม่มีใบยืนยัน        → 'approved'
--       ไม่มีรายการที่มีผล (void/ถูกกลับรายการ/ร่างถูกปฏิเสธ/ยังไม่ post)
--                                            → 'overdue' ถ้าเลยกำหนด · ไม่งั้น 'upcoming'
--       'waived' (ยกเว้นงวด = การตัดสินใจเชิงธุรกิจ) → **ไม่แตะ**
--       งวดที่ไม่มี draft_entry_id            → **ไม่แตะ** (ไม่มีข้อมูลให้สรุป)
--     งวดเดียวผูกหลายรายการ: ตามสคีมา งวดชี้ draft_entry เดียว แต่ draft_entry เดียว
--       ถูกหลายงวดชี้ได้ (จ่ายก้อนเดียวหลายงวด) → trigger ไล่ **ทุกงวด** ที่กระทบ
--     void แล้ว post ใหม่: งวดถูกชี้ไป draft ใหม่ → mirror ตรวจรอบใหม่ตามปกติ
--
--     คู่กันนี้ยังอุดรูข้างเคียงของ mirror: เดิมคืนค่าออกก่อนเมื่อ "สถานะไม่เปลี่ยน"
--     ทำให้สลับ draft_entry_id ใต้แถวที่เป็น 'received' ได้โดยไม่ถูกตรวจ
--     → เพิ่มเงื่อนไขว่า draft_entry_id ต้องไม่เปลี่ยนด้วย จึงจะข้ามการตรวจได้
--
-- ------------------------------------------------------------
-- (4) ตารางกฎ + ผังบัญชี 7 ตารางยังไม่มี audit
--     allow-list c_read_only ของ 20261008000005 ยกเว้นไว้ด้วยเหตุผล "แอปเขียนไม่ได้
--     เส้นทางเดียวคือ migration ใน git" · เหตุผลนั้นไม่พอ เพราะ
--       - authenticated **มี grant INSERT/UPDATE/DELETE บนทั้ง 7 ตารางอยู่แล้ว**
--         (20261007000001_grants.sql) · RLS เป็นด่านเดียว
--       - service_role จริงมี bypassrls · `alter table ... disable row level security`
--         ครั้งเดียว หรือการเขียนด้วย service key = เขียนคู่บัญชีของทุกรายการใน
--         อนาคตใหม่ได้โดยไม่เหลือร่องรอย
--     → ติด audit ทั้ง 7 ตาราง และ **ถอนออกจาก allow-list** โดยรัน guard เดิมซ้ำ
--       ด้วย allow-list ที่เหลือแค่กลุ่ม append-only (ข้อ 6 ท้ายไฟล์)
--
-- ------------------------------------------------------------
-- trigger ทุกตัวในไฟล์นี้ **ไม่เรียก fn_can** (เทสต์ข้อ 10 ของ roles_permissions_test
--   อ่าน pg_proc ยืนยัน) · SECURITY DEFINER ทุกตัวตั้ง search_path = '' และถูก
--   revoke execute จาก public/anon/authenticated (ข้อ 5)
--
-- ย้อนกลับ (rollback) — ลำดับสำคัญ:
--   -- 1. trigger ใหม่
--   -- drop trigger if exists trg_asset_created_at_immutable on sri_os.assets;
--   -- drop trigger if exists trg_schedule_sync_from_txn on sri_os.transactions;
--   -- drop trigger if exists trg_audit_chart_of_accounts on sri_os.chart_of_accounts;
--   -- drop trigger if exists trg_audit_asset_classes     on sri_os.asset_classes;
--   -- drop trigger if exists trg_audit_asset_categories  on sri_os.asset_categories;
--   -- drop trigger if exists trg_audit_txn_types         on sri_os.txn_types;
--   -- drop trigger if exists trg_audit_roles             on sri_os.roles;
--   -- drop trigger if exists trg_audit_permissions       on sri_os.permissions;
--   -- drop trigger if exists trg_audit_role_permissions  on sri_os.role_permissions;
--   -- 2. index
--   -- drop index if exists sri_os.asset_drafts_applied_create_uniq;
--   -- 3. ฟังก์ชันใหม่
--   -- drop function if exists sri_os.fn_asset_created_at_immutable();
--   -- drop function if exists sri_os.fn_schedule_sync_from_txn();
--   -- drop function if exists sri_os.fn_schedule_ledger_status(uuid);
--   -- 4. คืนฟังก์ชันที่ replace: รัน 20261008000000_asset_permissions.sql ส่วน
--   --    fn_asset_draft_frozen() และ fn_schedule_status_mirror() ซ้ำ (ไฟล์นั้นยังอยู่)
--   -- ** ย้อนแล้วกลับไปสู่สภาพที่ "อนุมัติแล้วแต่ไม่มีผล" ทำได้ และยอดค้างรับ
--   --    ต่ำกว่าจริงหลัง void · ไม่แนะนำ **
--
-- idempotent: create or replace function · drop trigger if exists ก่อน create ·
--   create unique index if not exists · ไม่เพิ่ม/ลบคอลัมน์ · ไม่แตะ policy ·
--   ไม่แตะข้อมูล · รันซ้ำได้ไม่จำกัดครั้ง
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 1 · assets.created_at แก้ไม่ได้
--     เป็นเงื่อนไขที่รองรับข้อพิสูจน์ (2ก) · และเป็นกฎที่ถูกต้องในตัวเอง
--     (เทียบ trg_txn_created_at_immutable ของ 20261008000004 ที่ทำอย่างเดียวกัน
--      กับ transactions) · assets.created_at อยู่ใน deny-list ของ patch อยู่แล้ว
--     แต่ **policy assets_update ไม่กรองคอลัมน์** → เขียนทับได้ตรงๆ ก่อนไฟล์นี้
--     ไม่เรียก fn_can · ไม่อ่าน/เขียนตาราง ledger
-- ============================================================
create or replace function fn_asset_created_at_immutable() returns trigger
language plpgsql set search_path = '' as $fn$
begin
  if new.created_at is distinct from old.created_at then
    raise exception 'ทรัพย์ %: created_at แก้ไม่ได้ (ของเดิม % · ที่ส่งมา %) · วันเกิดของแถวคือหลักฐานว่าทรัพย์ชิ้นนี้เกิดจากการอนุมัติครั้งไหน',
      old.id, old.created_at, new.created_at;
  end if;
  if new.id is distinct from old.id then
    raise exception 'ทรัพย์ %: id แก้ไม่ได้ (ย้าย id = ย้ายประวัติทั้งเส้นไปหาแถวอื่น)', old.id;
  end if;
  return new;
end $fn$;

comment on function fn_asset_created_at_immutable() is
  'assets.created_at / id แก้ไม่ได้ · รองรับข้อพิสูจน์ของ 20261008000006 ว่าทรัพย์ที่ร่าง kind=create อ้างว่าสร้าง เกิดในธุรกรรมที่อนุมัติจริง';

drop trigger if exists trg_asset_created_at_immutable on assets;
create trigger trg_asset_created_at_immutable
  before update on assets
  for each row execute function fn_asset_created_at_immutable();

-- ============================================================
-- 2 · ทรัพย์หนึ่งชิ้นถูกอ้างว่า "เกิดจากร่าง" ได้ครั้งเดียว
--     เฉพาะ kind='create' · ร่าง kind='update' หลายใบของทรัพย์เดียวกันต้องอนุมัติได้
--     ต่อไป (applied_asset_id = target_asset_id ซ้ำกันได้โดยเจตนา)
-- ============================================================
create unique index if not exists asset_drafts_applied_create_uniq
  on asset_drafts(applied_asset_id)
  where kind = 'create' and applied_asset_id is not null;

comment on index sri_os.asset_drafts_applied_create_uniq is
  'ร่างสร้างทรัพย์สองใบชี้ทรัพย์ชิ้นเดียวกันไม่ได้ · กันการ "อนุมัติหลายใบแต่มีทรัพย์ชิ้นเดียว" ซึ่งคิวจะนับงานที่ไม่เกิดขึ้น';

-- ============================================================
-- 3 · fn_asset_draft_frozen() · **replace** ของ 20261008000000
--     ส่วนเดิมคงไว้ครบทุกข้อ (ร่างที่พิจารณาแล้วแก้ไม่ได้ · คอลัมน์ที่ห้ามแก้ ·
--     reviewed_by ต้องเป็นผู้ทำจริง · applied_asset_id ต้องตั้งตอน approved ·
--     ร่างแก้ไขต้องชี้ทรัพย์เดิม · ทรัพย์ต้องมีจริงและผู้ถือตรง · create ต้องตรง
--     ชื่อ/หมวดใหญ่/หมวดย่อย)
--     เพิ่มสามข้อ: patch ต้องถูกนำไปใช้จริง · ทรัพย์ของ kind=create ต้องเกิดใน
--     ธุรกรรมนี้ · มีร่องรอยการสร้างในธุรกรรมนี้
--
--     security definer เหมือนเดิม (ต้องอ่าน assets/audit_log ให้ครบจริง ไม่ใช่
--     เท่าที่ผู้อนุมัติมองเห็น — ถ้าอ่านไม่เห็นแล้ว exists() เป็น false กฎจะกลับด้าน)
--     **ห้ามเรียก fn_can**
-- ============================================================
create or replace function fn_asset_draft_frozen() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  a      sri_os.assets;
  v_want jsonb;
  v_got  jsonb;
  v_diff text;
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

  -- "อนุมัติแต่ไม่ชี้ทรัพย์" = ข้อมูลไม่ครบ → ปฏิเสธ ไม่ใช่ตกไปเส้นทางปกติ
  -- (CHECK asset_drafts_applied_iff_approved กันอยู่อีกชั้น · ตรวจซ้ำที่นี่เพื่อให้
  --  error บอกเหตุผลจริง และเพื่อไม่ขึ้นกับว่า CHECK ยังอยู่)
  if new.status = 'approved' and new.applied_asset_id is null then
    raise exception 'ร่าง %: ตั้งสถานะ approved โดยไม่ชี้ทรัพย์ที่ถูกสร้าง/แก้ไม่ได้ · อนุมัติที่ไม่มีผล = คิวกับทะเบียนไม่ตรงกันเงียบๆ', old.id;
  end if;

  if new.applied_asset_id is not null then
    if new.status <> 'approved' then
      raise exception 'ร่าง %: applied_asset_id ตั้งได้เฉพาะตอนสถานะ approved', old.id;
    end if;
    if new.kind = 'update' and new.applied_asset_id is distinct from new.target_asset_id then
      raise exception 'ร่างแก้ไข %: applied_asset_id ต้องเป็นทรัพย์เดิมที่ร่างชี้ไว้', old.id;
    end if;

    select * into a from sri_os.assets where id = new.applied_asset_id and owner_id = new.owner_id;
    if not found then
      raise exception 'ร่าง %: applied_asset_id ต้องชี้ทรัพย์ที่มีอยู่จริงและเป็นของผู้ถือเดียวกับร่าง · ตั้งสถานะ approved โดยไม่สร้าง/ไม่แก้ทรัพย์ไม่ได้ (อนุมัติที่ไม่มีผล = ทะเบียนกับคิวไม่ตรงกันเงียบๆ)',
        old.id;
    end if;

    if new.kind = 'create' then
      if a.name is distinct from new.name
      or a.class_id is distinct from new.class_id
      or a.category_id is distinct from new.category_id then
        raise exception 'ร่างสร้างทรัพย์ %: ทรัพย์ที่อ้างว่าสร้างจากร่างนี้ไม่ตรงกับร่าง (ชื่อ/หมวดใหญ่/หมวดย่อย) · ใช้ fn_apply_asset_draft() เท่านั้น', old.id;
      end if;

      -- (2ก) ทรัพย์ต้องเกิดในธุรกรรมที่อนุมัตินี้ · created_at แก้ไม่ได้ (ข้อ 1)
      if a.created_at is distinct from now() then
        raise exception 'ร่างสร้างทรัพย์ %: ทรัพย์ % มีอยู่ก่อนการอนุมัติครั้งนี้ (created_at % · ธุรกรรมนี้เริ่ม %) · ร่าง kind=''create'' ต้องทำให้เกิดทรัพย์ชิ้นใหม่จริง ไม่ใช่ชี้ทรัพย์ที่มีอยู่แล้ว (ไม่งั้นเลี่ยงกฎ "ทรัพย์ชิ้นใหม่ต้อง Management อนุมัติ" ได้) · ใช้ fn_apply_asset_draft()',
          old.id, a.id, a.created_at, now();
      end if;

      -- (2ข) ร่องรอยการ **insert** ทรัพย์นี้ต้องอยู่ในธุรกรรมเดียวกัน
      --      audit_log ไม่มี policy INSERT และ append-only → ปลอมแถวนี้ไม่ได้
      if not exists (
        select 1 from sri_os.audit_log al
         where al.table_name = 'assets'
           and al.row_id     = new.applied_asset_id
           and al.action     = 'insert'
           and al.at         = now()
      ) then
        raise exception 'ร่างสร้างทรัพย์ %: ไม่มีร่องรอยการสร้างทรัพย์ % ในธุรกรรมที่อนุมัตินี้ · อนุมัติร่างสร้างทรัพย์ต้องสร้างทรัพย์จริงผ่าน fn_apply_asset_draft()',
          old.id, new.applied_asset_id;
      end if;
    end if;

    -- ★ หัวใจของข้อ (1): patch ต้องถูกนำไปใช้กับแถวจริงแล้ว
    --   เทียบด้วย jsonb_populate_record เพื่อให้สองฝั่งผ่านชนิดข้อมูลของคอลัมน์จริง
    --   ตัวเดียวกัน (วิธีเดียวกับที่ fn_apply_asset_draft ใช้เขียน) → "100" กับ 100
    --   หรือ 100 กับ 100.00 ไม่กลายเป็นความต่างปลอม
    if new.patch <> '{}'::jsonb then
      v_want := to_jsonb(jsonb_populate_record(null::sri_os.assets, new.patch));
      v_got  := to_jsonb(a);
      select string_agg(
               format('%s (ร่างขอ %s · ทะเบียนเป็น %s)', k,
                      coalesce(v_want ->> k, '(ว่าง)'), coalesce(v_got ->> k, '(ว่าง)')),
               ' · ' order by k)
        into v_diff
        from jsonb_object_keys(new.patch) as k
       where (v_want -> k) is distinct from (v_got -> k);
      if v_diff is not null then
        raise exception 'ร่าง %: อนุมัติแล้วแต่ข้อมูลที่เสนอแก้ยังไม่ถูกนำไปใช้กับทรัพย์ % → % · "อนุมัติแล้ว" ต้องหมายความว่าทะเบียนเปลี่ยนจริง · ใช้ fn_apply_asset_draft() อย่าตั้ง status/applied_asset_id ตรงๆ',
          old.id, a.id, v_diff;
      end if;
    end if;
  end if;

  return new;
end $fn$;

comment on function fn_asset_draft_frozen() is
  'ร่างที่พิจารณาแล้วแก้ไม่ได้ + **อนุมัติ ⇔ ทะเบียนเปลี่ยนจริง** · ตรวจผลลัพธ์ไม่ใช่เส้นทาง: patch ทุกคีย์ต้องตรงกับแถวใน assets แล้ว · kind=create ต้องมีทรัพย์ที่เกิดในธุรกรรมนี้ (created_at = now() + ร่องรอย insert ใน audit_log) · ปฏิเสธร่างไม่ถูกแตะ · ห้ามเรียก fn_can';

drop trigger if exists trg_asset_draft_frozen on asset_drafts;
create trigger trg_asset_draft_frozen
  before update on asset_drafts
  for each row execute function fn_asset_draft_frozen();

-- ============================================================
-- 4 · สถานะงวดต้องตามรายการที่ "ไม่มีผลแล้ว" (ข้อ 3 · กระทบตัวเลขเงิน)
-- ============================================================

-- ---------- 4.1 สูตรเดียวของ "งวดนี้ควรอยู่สถานะอะไรตาม ledger" ----------
-- ใช้เงื่อนไขชุดเดียวกับที่ fn_schedule_status_mirror ตรวจอยู่ → ค่าที่คืนมาผ่าน
--   การตรวจของ mirror ได้เสมอ **โดยนิยาม** ไม่ใช่เพราะเลือกค่าที่ดูเข้าท่า
-- คืน null = "ไม่มีข้อมูลพอจะสรุป" → ผู้เรียกต้องไม่แตะงวดนั้น (ห้ามเดา)
-- security definer: ต้องอ่าน ledger ให้ครบจริง ไม่ใช่เท่าที่คนกด void มองเห็น
--   (ถ้าอ่านไม่เห็น เงื่อนไข exists จะเป็น false แล้วกฎกลับด้าน = ตัวเลขผิด)
create or replace function fn_schedule_ledger_status(p_schedule uuid)
returns text
language sql stable security definer set search_path = '' as $fn$
  select case
    -- การยกเว้นงวดเป็นการตัดสินใจเชิงธุรกิจ · ledger ไม่มีสิทธิ์เขียนทับ
    when s.status = 'waived'       then null
    -- ไม่มีร่างผูกอยู่ = ไม่มีข้อมูลให้สรุป (upcoming/overdue/waived ที่คนตั้งเอง)
    when s.draft_entry_id is null  then null
    when de.id is null             then null
    when de.status = 'pending'     then 'drafted'
    when de.status = 'rejected'    then (case when s.due_date < current_date then 'overdue' else 'upcoming' end)
    when de.posted_txn_id is null  then (case when s.due_date < current_date then 'overdue' else 'upcoming' end)
    -- รายการถูก void = ไม่มีผล
    when not exists (select 1 from sri_os.transactions t
                      where t.id = de.posted_txn_id and t.status = 'posted')
      then (case when s.due_date < current_date then 'overdue' else 'upcoming' end)
    -- ถูกกลับรายการด้วยรายการที่ยังไม่ถูก void = ไม่มีผล (เงื่อนไขเดียวกับ
    -- fn_reverse_link_ok: ตัวที่ void แล้วไม่นับ → กลับรายการผิดแล้ว void ทิ้ง
    -- ต้องทำให้งวดกลับมาเป็น received ได้อีก)
    when exists (select 1 from sri_os.transactions r
                  where r.reverses_id = de.posted_txn_id and r.status <> 'void')
      then (case when s.due_date < current_date then 'overdue' else 'upcoming' end)
    when de.status <> 'approved'   then null
    when exists (select 1 from sri_os.cash_confirmations c
                  where c.transaction_id = de.posted_txn_id and c.confirmed_at is not null)
      then 'received'
    else 'approved'
  end
  from sri_os.schedules s
  left join sri_os.draft_entries de on de.id = s.draft_entry_id
 where s.id = p_schedule;
$fn$;

comment on function fn_schedule_ledger_status(uuid) is
  'สถานะที่งวดควรเป็นตามสถานะจริงของ ledger · แหล่งความจริงเดียว ใช้ทั้งที่ trigger คืนสถานะหลัง void/กลับรายการ และฝั่งรายงานค้างรับ · คืน null = ไม่มีข้อมูลพอจะสรุป (waived · ไม่มีร่างผูก) → ห้ามเดาค่าให้';

-- ---------- 4.2 trigger ฝั่ง ledger · จับทั้ง void และการกลับรายการ ----------
-- อยู่บน transactions เพราะเหตุการณ์เกิดที่นั่น · แต่เขียนเฉพาะ sri_os.schedules
-- (ไม่เขียนตาราง ledger ใดเลย · ไม่สร้าง transaction ใหม่ = กฎเหล็กข้อ 6 ยังอยู่)
-- กฎเหล็กข้อ 4 (ถอดโมดูลทรัพย์ได้โดยไม่แตะ core ledger): ฟังก์ชันเช็ค to_regclass
--   ก่อน → ถอดตาราง schedules/draft_entries ทิ้งแล้ว trigger นี้กลายเป็น no-op
--   ไม่ใช่ทำให้ post/void รายการพังทั้งระบบ
-- security definer: คนที่มี txn.void อาจไม่มีสิทธิ์เขียน schedules — แต่ตัวเลข
--   ค้างรับต้องถูกต้องเสมอ ไม่ขึ้นกับว่าใครกดปุ่ม
create or replace function fn_schedule_sync_from_txn() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare r record; v_want text; n int := 0;
begin
  if to_regclass('sri_os.schedules') is null
  or to_regclass('sri_os.draft_entries') is null then
    return null;   -- ถอดโมดูลทรัพย์ไปแล้ว
  end if;

  -- ยิงเฉพาะเหตุการณ์ที่ทำให้ "มีผล/ไม่มีผล" เปลี่ยน · ไม่ใช่ทุก update
  if tg_op = 'UPDATE'
     and new.status is not distinct from old.status
     and new.reverses_id is not distinct from old.reverses_id then
    return null;
  end if;
  if tg_op = 'INSERT' and new.reverses_id is null then
    return null;   -- รายการใหม่ปกติยังไม่มีงวดใดชี้มาถึง
  end if;

  for r in
    select s.id, s.status
      from sri_os.schedules s
      join sri_os.draft_entries de on de.id = s.draft_entry_id
     where de.posted_txn_id = new.id
        or (new.reverses_id is not null and de.posted_txn_id = new.reverses_id)
  loop
    v_want := sri_os.fn_schedule_ledger_status(r.id);
    -- null = สรุปไม่ได้ → ไม่แตะ (ห้ามเดา)
    if v_want is not null and v_want <> r.status then
      update sri_os.schedules set status = v_want where id = r.id;
      n := n + 1;
    end if;
  end loop;

  if n > 0 then
    raise notice 'คืนสถานะงวดตาม ledger % งวด (รายการ % · %)', n, new.id, new.status;
  end if;
  return null;
end $fn$;

comment on function fn_schedule_sync_from_txn() is
  'void หรือกลับรายการแล้วตารางงวดต้องไม่บอกว่า "รับเงินแล้ว" ต่อไป (ยอดค้างรับต่ำกว่าจริง) · ครอบทั้ง status→void และการมี/ไม่มีรายการกลับรายการ รวมทางกลับเมื่อรายการกลับรายการถูก void · ค่าที่เขียนมาจาก fn_schedule_ledger_status ที่เดียว · เขียนเฉพาะ schedules ไม่แตะตาราง ledger · ห้ามเรียก fn_can';

drop trigger if exists trg_schedule_sync_from_txn on transactions;
create trigger trg_schedule_sync_from_txn
  after insert or update on transactions
  for each row execute function fn_schedule_sync_from_txn();

-- ---------- 4.3 mirror เดิม · อุดรูของ "คืนค่าออกก่อนเมื่อสถานะไม่เปลี่ยน" ----------
-- ของเดิมคงไว้ทุกบรรทัด เปลี่ยนเฉพาะเงื่อนไขการข้ามการตรวจ: สลับ draft_entry_id
-- ใต้แถวที่เป็น 'received' ต้องถูกตรวจใหม่ ไม่ใช่ผ่านเพราะสถานะไม่ขยับ
create or replace function fn_schedule_status_mirror() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare v_draft text; v_txn uuid;
begin
  if tg_op = 'UPDATE'
     and new.status = old.status
     and new.draft_entry_id is not distinct from old.draft_entry_id then
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
    -- รายการที่ถูกกลับรายการแล้วก็ "ไม่มีผล" เท่ากับ void (เงื่อนไขเดียวกับ
    -- fn_schedule_ledger_status · ของเดิมดูแต่ status จึงยังตั้ง received ได้)
    if exists (
      select 1 from sri_os.transactions r
       where r.reverses_id = v_txn and r.status <> 'void'
    ) then
      raise exception 'งวดที่ %: รายการที่ผูกอยู่ถูกกลับรายการแล้ว (reverse) ตั้งสถานะ % ไม่ได้ · ถ้ารับเงินจริงให้ลงรายการใหม่แล้วผูกงวดกับร่างใบใหม่',
        new.period, new.status;
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

comment on function fn_schedule_status_mirror() is
  'สถานะงวดที่สะท้อน ledger แก้มือไม่ได้ · ข้ามการตรวจได้เฉพาะเมื่อทั้ง status และ draft_entry_id ไม่เปลี่ยน (ของเดิมดูแต่ status → สลับร่างใต้แถว received ได้) · รายการที่ถูกกลับรายการนับว่าไม่มีผลเท่ากับ void';

drop trigger if exists trg_schedule_status_mirror on schedules;
create trigger trg_schedule_status_mirror
  before insert or update on schedules
  for each row execute function fn_schedule_status_mirror();

-- ============================================================
-- 5 · ACL ของฟังก์ชันใหม่ — ปิดทั้งหมด (ไม่มีตัวไหนที่หน้าจอหรือ policy เรียก)
--     ฟังก์ชันที่สร้างใหม่ติด ACL เริ่มต้น = PUBLIC EXECUTE · ถ้าไม่ปิด anon เรียกได้
--     และ SECURITY DEFINER ที่เปิด PUBLIC = ข้าม RLS
-- ============================================================
do $$
declare r record; n int := 0;
begin
  for r in
    select p.oid::regprocedure::text as sig
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'sri_os'
       and p.proname in ('fn_asset_created_at_immutable', 'fn_schedule_sync_from_txn',
                         'fn_schedule_ledger_status', 'fn_asset_draft_frozen',
                         'fn_schedule_status_mirror')
  loop
    execute format('revoke all on function %s from public', r.sig);
    begin
      execute format('revoke all on function %s from anon, authenticated', r.sig);
    exception when undefined_object then
      raise notice 'ไม่มี role anon/authenticated ในคลัสเตอร์นี้ — ข้าม revoke';
    end;
    n := n + 1;
  end loop;
  if n < 5 then
    raise exception 'ปิด execute ได้แค่ % ตัว จาก 5 ตัว — ชื่อฟังก์ชันเปลี่ยนหรือสร้างไม่สำเร็จ', n;
  end if;
  raise notice 'ปิด execute ของฟังก์ชันในไฟล์นี้ % ตัว (ไม่มีตัวไหนเปิดให้ authenticated)', n;
end $$;

-- ============================================================
-- 6 · ร่องรอยของตารางกฎและผังบัญชี (ข้อ 4)
--     3 ตารางมี id uuid → fn_audit · 4 ตารางคีย์ธรรมชาติ → fn_audit_keyed
--     คีย์ที่ส่งต้องตรงกับ PK จริง (guard ข้อ 5(ง) ของ 20261008000005 ตรวจให้
--      ทุกครั้งที่ไฟล์นั้นถูก replay · และ guard ของไฟล์นี้ตรวจซ้ำ)
-- ============================================================
drop trigger if exists trg_audit_chart_of_accounts on chart_of_accounts;
create trigger trg_audit_chart_of_accounts
  after insert or update or delete on chart_of_accounts
  for each row execute function fn_audit();

comment on trigger trg_audit_chart_of_accounts on chart_of_accounts is
  'ผังบัญชีคือปลายทางของทุกบรรทัดบัญชี · authenticated มี grant เขียนอยู่แล้วและ RLS เป็นด่านเดียว · service_role มี bypassrls → ต้องมีร่องรอยไม่ว่าใครเขียน';

drop trigger if exists trg_audit_asset_classes on asset_classes;
create trigger trg_audit_asset_classes
  after insert or update or delete on asset_classes
  for each row execute function fn_audit();

drop trigger if exists trg_audit_asset_categories on asset_categories;
create trigger trg_audit_asset_categories
  after insert or update or delete on asset_categories
  for each row execute function fn_audit();

drop trigger if exists trg_audit_txn_types on txn_types;
create trigger trg_audit_txn_types
  after insert or update or delete on txn_types
  for each row execute function fn_audit_keyed('code');

comment on trigger trg_audit_txn_types on txn_types is
  'ตารางกฎ = คู่บัญชีของทุกรายการในอนาคต · npm run sync:rules เขียนตารางนี้ด้วย service key → ร่องรอยคือสิ่งเดียวที่บอกได้ว่าคู่บัญชีถูกเปลี่ยนเมื่อไหร่โดยใคร · PK = code ไม่มี id uuid จึงใช้ fn_audit_keyed';

drop trigger if exists trg_audit_roles on roles;
create trigger trg_audit_roles
  after insert or update or delete on roles
  for each row execute function fn_audit_keyed('key');

drop trigger if exists trg_audit_permissions on permissions;
create trigger trg_audit_permissions
  after insert or update or delete on permissions
  for each row execute function fn_audit_keyed('key');

drop trigger if exists trg_audit_role_permissions on role_permissions;
create trigger trg_audit_role_permissions
  after insert or update or delete on role_permissions
  for each row execute function fn_audit_keyed('role_key', 'permission_key');

comment on trigger trg_audit_role_permissions on role_permissions is
  'การจับคู่ตำแหน่ง → สิทธิ์ · ไม่มี write policy (20261007000003) แต่ grant ยังเปิดและ service_role bypassrls → แถวที่เพิ่ม/ถอนต้องเห็นร่องรอย';

-- ============================================================
-- 7 · guard ท้ายไฟล์ — "พังให้เห็น" ไม่ใช่ raise notice
-- ============================================================

-- 7a · trigger/ฟังก์ชันของไฟล์นี้ติดจริง และเป็นชนิดที่ถูกต้อง
do $$
declare r record; n int := 0;
begin
  for r in
    select * from (values
      ('assets',        'trg_asset_created_at_immutable', 2, 16),   -- BEFORE UPDATE
      ('asset_drafts',  'trg_asset_draft_frozen',         2, 16),
      ('schedules',     'trg_schedule_status_mirror',     2, 0),
      ('transactions',  'trg_schedule_sync_from_txn',     0, 0)     -- AFTER
    ) as t(tbl, trg, before_bit, upd_bit)
  loop
    if not exists (
      select 1 from pg_trigger tg
       where tg.tgrelid = ('sri_os.' || r.tbl)::regclass
         and not tg.tgisinternal and tg.tgname = r.trg
         and (tg.tgtype & 1) <> 0                       -- FOR EACH ROW
         and (tg.tgtype & 2) = r.before_bit             -- BEFORE/AFTER
    ) then
      raise exception 'trigger %.% ไม่ได้ติด หรือชนิดผิด (ต้องเป็น for each row และ before/after ตามที่ประกาศ)', r.tbl, r.trg;
    end if;
    n := n + 1;
  end loop;
  raise notice 'guard 7a · trigger ของไฟล์นี้ติดครบ % ตัว', n;
end $$;

-- 7b · ไม่มี trigger function ตัวใดในสคีมาเรียก fn_can (กฎเงินห้ามขึ้นกับตารางสิทธิ์)
--      และฟังก์ชันของไฟล์นี้ต้องไม่เปิด execute ให้ public/anon/authenticated
do $$
declare v text; n int;
begin
  select string_agg(distinct p.proname, ', ') into v
    from pg_trigger tg
    join pg_class c      on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    join pg_proc p       on p.oid = tg.tgfoid
   where ns.nspname = 'sri_os' and not tg.tgisinternal and p.prosrc ~* 'fn_can';
  if v is not null then
    raise exception 'trigger function อ้างถึง fn_can: % · กฎเงินจะถูกปิดได้จากหน้า Settings', v;
  end if;

  select string_agg(p.oid::regprocedure::text, ', '), count(*) into v, n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.proname in ('fn_asset_created_at_immutable', 'fn_schedule_sync_from_txn',
                       'fn_schedule_ledger_status', 'fn_asset_draft_frozen',
                       'fn_schedule_status_mirror')
     and (has_function_privilege('public', p.oid, 'execute')
       or (exists (select 1 from pg_roles where rolname = 'anon')
           and has_function_privilege('anon', p.oid, 'execute'))
       or (exists (select 1 from pg_roles where rolname = 'authenticated')
           and has_function_privilege('authenticated', p.oid, 'execute')));
  if n > 0 then
    raise exception 'ฟังก์ชันของไฟล์นี้ยังเรียกได้จากข้างนอก % ตัว: %', n, v;
  end if;

  -- SECURITY DEFINER ทุกตัวต้อง search_path แน่น (รวมของไฟล์นี้)
  select string_agg(p.proname, ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.prosecdef
     and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c
                      where c in ('search_path=', 'search_path=""', 'search_path=sri_os'));
  if v is not null then
    raise exception 'SECURITY DEFINER ที่ search_path ไม่แน่น: %', v;
  end if;
  raise notice 'guard 7b · ไม่มี trigger function เรียก fn_can · ฟังก์ชันใหม่ปิด execute ครบ · search_path แน่น';
end $$;

-- 7c · trigger ของไฟล์นี้ต้องไม่ **เขียน** ตาราง ledger (กฎเหล็กข้อ 6)
--      fn_schedule_sync_from_txn อยู่บน transactions แต่ต้องเขียนแค่ schedules
do $$
declare v text;
begin
  select string_agg(p.proname, ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.proname in ('fn_asset_created_at_immutable', 'fn_schedule_sync_from_txn',
                       'fn_schedule_ledger_status', 'fn_asset_draft_frozen',
                       'fn_schedule_status_mirror')
     and p.prosrc ~* '(insert|update|delete)\s+(into\s+)?(sri_os\.)?(transactions|transaction_lines|draft_entries|cash_confirmations|audit_log)\M';
  if v is not null then
    raise exception 'ฟังก์ชันของไฟล์นี้เขียนตาราง ledger/audit: % · การคืนสถานะงวดต้องไม่กลายเป็นช่องลงบัญชี (กฎเหล็กข้อ 6)', v;
  end if;
  raise notice 'guard 7c · ฟังก์ชันของไฟล์นี้ไม่เขียนตาราง ledger (อ่านได้ เขียนไม่ได้)';
end $$;

-- 7d · **ถอด 7 ตารางออกจาก allow-list ของ guard audit** (ข้อ 4)
--      รันการตรวจของ 20261008000005 ข้อ (จ) ซ้ำ ด้วย allow-list ที่เหลือแต่
--      กลุ่ม append-only → ตารางกฎ/ผังบัญชีต้องมี audit ครบสามคำสั่งแล้ว
do $$
declare
  c_append_only text[] := array['audit_log', 'asset_valuations'];
  c_rules       text[] := array['chart_of_accounts', 'txn_types', 'asset_classes',
                                'asset_categories', 'roles', 'permissions',
                                'role_permissions'];
  v text; n int; r text;
begin
  -- (ก) 7 ตารางของรอบนี้ต้องมี audit ครบสามคำสั่ง · after · for each row
  foreach r in array c_rules loop
    select count(*) into n
      from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
     where tg.tgrelid = ('sri_os.' || r)::regclass and not tg.tgisinternal
       and p.proname in ('fn_audit', 'fn_audit_keyed')
       and (tg.tgtype & 4) <> 0 and (tg.tgtype & 16) <> 0 and (tg.tgtype & 8) <> 0
       and (tg.tgtype & 2) = 0 and (tg.tgtype & 1) <> 0;
    if n <> 1 then
      raise exception 'audit ของ sri_os.% ไม่ครบ: ต้องมี after insert or update or delete for each row พอดี 1 ตัว (เจอ %)', r, n;
    end if;
  end loop;

  -- (ข) ตารางที่ใช้ fn_audit ต้องมี id uuid · ที่ใช้ fn_audit_keyed ต้องไม่มี
  --     และคีย์ของ trigger ต้องตรง PK จริงเรียงตามลำดับ (ร่องรอยชี้ผิดแถว = แย่กว่าไม่มี)
  select string_agg(distinct c.relname, ', ') into v
    from pg_class c
    join pg_namespace ns on ns.oid = c.relnamespace
    join pg_trigger tg on tg.tgrelid = c.oid and not tg.tgisinternal
    join pg_proc p on p.oid = tg.tgfoid
   where ns.nspname = 'sri_os' and c.relkind = 'r' and p.proname = 'fn_audit'
     and not exists (select 1 from pg_attribute a
                      where a.attrelid = c.oid and a.attname = 'id'
                        and a.attnum > 0 and not a.attisdropped
                        and a.atttypid = 'uuid'::regtype);
  if v is not null then
    raise exception 'ตารางที่ติด fn_audit แต่ไม่มี id uuid: % → ทุก mutation ของตารางนั้นจะล้ม 42703', v;
  end if;

  for r in select c.relname from pg_class c
             join pg_namespace ns on ns.oid = c.relnamespace
             join pg_trigger tg on tg.tgrelid = c.oid and not tg.tgisinternal
             join pg_proc p on p.oid = tg.tgfoid
            where ns.nspname = 'sri_os' and p.proname = 'fn_audit_keyed'
            group by c.relname
  loop
    select string_agg(quote_literal(a.attname), ', ' order by k.ord) into v
      from pg_constraint con
      join unnest(con.conkey) with ordinality as k(attnum, ord) on true
      join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum
     where con.conrelid = ('sri_os.' || r)::regclass and con.contype = 'p';
    if v is null then
      raise exception 'sri_os.% ไม่มี primary key → คีย์ของ audit อ้างอะไรไม่ได้', r;
    end if;
    if not exists (select 1 from pg_trigger tg
                    where tg.tgrelid = ('sri_os.' || r)::regclass and not tg.tgisinternal
                      and tg.tgfoid = 'sri_os.fn_audit_keyed'::regproc
                      and pg_get_triggerdef(tg.oid) like '%fn_audit_keyed(' || v || ')') then
      raise exception 'trigger audit ของ sri_os.% ส่งคีย์ไม่ตรง primary key (ต้องเป็น fn_audit_keyed(%))', r, v;
    end if;
  end loop;

  -- (ค) guard หลัก: ทุกตารางใน sri_os ต้องมี audit · allow-list เหลือแต่ append-only
  select string_agg(c.relname, ', ' order by c.relname), count(*) into v, n
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os' and c.relkind = 'r'
     and not (c.relname = any (c_append_only))
     and not exists (
       select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
        where tg.tgrelid = c.oid and not tg.tgisinternal
          and p.proname in ('fn_audit', 'fn_audit_keyed')
          and (tg.tgtype & 4) <> 0 and (tg.tgtype & 16) <> 0 and (tg.tgtype & 8) <> 0
          and (tg.tgtype & 2) = 0 and (tg.tgtype & 1) <> 0);
  if n > 0 then
    raise exception '% ตารางใน sri_os ไม่มี audit ที่ครอบ insert+update+delete: % · allow-list ของรอบนี้เหลือแต่กลุ่ม append-only (audit_log · asset_valuations) ซึ่งแถวเองคือประวัติ', n, v;
  end if;

  select count(*) into n from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os' and c.relkind = 'r';
  if n < 25 then
    raise exception 'นับตารางใน sri_os ได้แค่ % ตาราง — guard นี้อาจไม่ได้ตรวจอะไรเลย', n;
  end if;

  -- (ง) เงื่อนไขของ allow-list ที่เหลือต้องยังจริง (เหตุผล = แถวเองคือประวัติ)
  if not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                  where tg.tgrelid = 'sri_os.audit_log'::regclass
                    and p.proname like 'fn\_forbid%'
                    and (tg.tgtype & 8) <> 0 and (tg.tgtype & 16) <> 0) then
    raise exception 'audit_log ไม่ได้ append-only แล้ว → เหตุผลที่ยกเว้นมันจาก audit ใช้ไม่ได้อีก';
  end if;
  if not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                  where tg.tgrelid = 'sri_os.asset_valuations'::regclass
                    and p.proname like 'fn\_forbid%' and (tg.tgtype & 8) <> 0) then
    raise exception 'asset_valuations ไม่มีด่าน DELETE แล้ว → เหตุผลที่ยกเว้นมันจาก audit ใช้ไม่ได้อีก';
  end if;

  raise notice 'guard 7d · ทุกตารางใน sri_os (% ตาราง) มี audit ครบสามคำสั่ง ยกเว้น append-only 2 ตาราง · ตารางกฎ/ผังบัญชี 7 ตารางถอดจาก allow-list แล้ว', n;
end $$;

do $$ begin raise notice '=== 20261008000006_approval_integrity: ติดตั้งครบ ==='; end $$;
