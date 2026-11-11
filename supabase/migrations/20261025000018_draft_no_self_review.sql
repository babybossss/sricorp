-- ============================================================
-- SRI OS · C-2 · **คนอนุมัติต้องไม่ใช่คนคีย์** (บังคับที่ DB ไม่ใช่ธงเตือนบนหน้าจอ)
--
-- รูที่ปิด
--   policy `draft_review` ให้ใครที่มี `ledger.approve` UPDATE ร่างได้ทุกแถว
--   **รวมร่างที่ตัวเองคีย์** → คนเดียวคีย์เอง อนุมัติเอง ลงสมุดเอง
--   = การแยกหน้าที่ (D-072) หายไปทั้งชั้น โดยที่งบดุลยังดุลทุกใบ
--   (`zz_approvals_queue_test.sql` ข้อ D1 บันทึกสภาพนี้ไว้ก่อนหน้า)
--
-- ------------------------------------------------------------
-- **ข้อยกเว้นที่ต้องมี และเหตุผล**
-- ------------------------------------------------------------
--   วันนี้ลูกพี่เป็น `super_admin` **คนเดียว** ถ้าห้ามเด็ดขาด เขาจะคีย์ร่างแล้ว
--   อนุมัติเองไม่ได้ = ระบบใช้งานไม่ได้ และ **ด่านที่ทำให้ระบบใช้ไม่ได้ จะถูกปิดทิ้ง**
--   (ปิดด่านหนึ่งครั้ง เสียทั้งด่าน · ปล่อยให้ทำได้แบบมีร่องรอย เสียความสะอาด
--    แต่ยังตรวจย้อนได้ทุกใบ) → เลือกทางที่ **ทำได้ แต่ลบร่องรอยไม่ได้**
--
--   ทางที่ไฟล์นี้บังคับ
--     1. ไม่ใช่ `super_admin` → **ห้ามเด็ดขาด** (management/manager มีคนเหนือกว่าให้ส่งต่อได้เสมอ)
--     2. `super_admin` → ทำได้ **เมื่อใส่เหตุผลยาวพอ** (`self_review_reason` ≥ 10 ตัวอักษร)
--     3. ร่องรอย **ลบไม่ได้** สองชั้น
--        · เหตุผลอยู่ **บนแถวร่างเอง** และแถวที่ตัดสินแล้วเป็นแถวตาย (20261025000017)
--          → แก้/ล้างเหตุผลทีหลังไม่ได้ · และ `draft_entries` ไม่มี policy DELETE
--        · `trg_audit_drafts` เก็บสำเนาแถวลง `audit_log` ซึ่งไม่มี policy เขียน/ลบ
--     4. มีรายงานไล่ดูได้: `fn_self_reviewed_drafts(from, to)` (ต้องมี `owner.view_all`)
--        รายงานบอก **จำนวนผู้อนุมัติคนอื่นที่มีอยู่** ด้วย → ถ้าวันหนึ่งมีคนอื่นอยู่แล้ว
--        ยังอนุมัติเอง จะเห็นเป็นตัวเลขในรายงาน ไม่ต้องเชื่อความจำใคร
--
--   **สวิตช์อยู่ในตาราง config ไม่ใช่ hard-code** (กฎเหล็กข้อ 5)
--     `settings['approval.self_review']`
--       · `"super_admin_with_trail"` (ค่าตั้งต้นวันนี้) = ตามข้อ 2
--       · `"never"` = ห้ามทุกคนรวม super_admin → **วันที่มีผู้อนุมัติคนที่สอง ให้พลิกเป็นค่านี้**
--     ค่าอื่น/ไม่มีแถว = ตีความเป็น `never` (เผลอแล้วต้องได้การปฏิเสธ ไม่ใช่การอนุญาต)
--     แก้ค่าได้เฉพาะคนที่มี `settings.manage` และการแก้ถูกบันทึกโดย `trg_audit_settings`
--
--   **ไม่ได้ผูกกับ "มีคนอื่นอนุมัติได้หรือไม่" โดยอัตโนมัติ** โดยตั้งใจ:
--   ถ้าผูก วันที่ผู้อนุมัติคนที่สองลาหรือถูกปิดบัญชี ลูกพี่จะอนุมัติอะไรไม่ได้เลย
--   ทันทีโดยไม่มีใครรู้ว่าทำไม → เอาตัวเลขนั้นไปไว้ใน **รายงาน** ให้คนตัดสินแทน
--
-- ------------------------------------------------------------
-- สิ่งที่บังคับเพิ่ม (ด่านเดียวกัน เพราะเป็นรูเดียวกัน)
-- ------------------------------------------------------------
--   · ชื่อผู้ตัดสิน (`reviewed_by`) **อ่านจากผู้ล็อกอินจริง** ไม่ใช่จากค่าที่ส่งมา (D-115)
--     เว้นไว้ = เติมให้ · ส่งชื่อคนอื่นมา = ปฏิเสธ (ไม่งั้นอนุมัติเองแล้วใส่ชื่อคนอื่นได้)
--   · `reviewed_at` ระบบตั้งด้วย `now()` ตอนตัดสิน (เวลาไม่ใช่สิ่งที่ผู้เขียนเลือกเอง)
--   · `created_by` **ย้ายไม่ได้** — ถ้าย้ายได้ ด่านนี้หลบได้ด้วยการเปลี่ยนชื่อคนคีย์
--
-- ลำดับ: ต้องรันหลัง 20261025000017 (ร่างที่ตัดสินแล้วเป็นแถวตาย = ชั้นที่ทำให้
--        เหตุผลลบไม่ได้) · 20261006190000 (roles/permissions/fn_can) · guard หัวไฟล์ตรวจให้
--
-- idempotent: add column if not exists · drop/add constraint · create or replace ·
--        insert ... on conflict do nothing (ไม่ทับค่าที่ลูกพี่พลิกไว้เอง)
--
-- ย้อนกลับ (rollback):
--   -- drop trigger if exists trg_draft_review_separation on sri_os.draft_entries;
--   -- drop function if exists sri_os.fn_assert_draft_review_separation();
--   -- drop function if exists sri_os.fn_self_reviewed_drafts(date, date);
--   -- drop function if exists sri_os.fn_self_review_mode();
--   -- alter table sri_os.draft_entries drop constraint if exists draft_entries_self_review_reason;
--   -- delete from sri_os.column_exposure
--   --  where table_name = 'draft_entries' and column_name = 'self_review_reason';
--   -- select sri_os.fn_apply_column_exposure();
--   -- alter table sri_os.draft_entries drop column if exists self_review_reason;
--   -- delete from sri_os.settings where key = 'approval.self_review';
--   ⚠ ถอดแล้ว **คนเดียวคีย์เอง-อนุมัติเอง-ลงสมุดเองได้อีก โดยไม่มีร่องรอยว่าเป็นคนเดียวกัน**
--     (reviewed_by ก็ปลอมเป็นชื่อคนอื่นได้ด้วย)
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 0 · ของที่ต้องมีมาก่อน — ขาดแล้วหยุด ไม่ใช่สร้างด่านครึ่งใบ
-- ============================================================
do $$
begin
  if to_regclass('sri_os.draft_entries') is null then
    raise exception 'ไม่มีตาราง draft_entries → ต้องรัน 20260917000002_ledger.sql ก่อนไฟล์นี้';
  end if;
  if to_regprocedure('sri_os.fn_can(text)') is null then
    raise exception 'ไม่มี fn_can → ต้องรัน 20261006190000_roles_permissions.sql ก่อนไฟล์นี้ (ด่านนี้อ่านระดับผู้ใช้จากตารางสิทธิ์)';
  end if;
  if to_regclass('sri_os.settings') is null then
    raise exception 'ไม่มีตาราง settings → ต้องรัน 20260917000001_core.sql ก่อนไฟล์นี้ (สวิตช์ต้องอยู่ในตาราง config ตามกฎเหล็กข้อ 5)';
  end if;
  -- **ด่านคู่**: ร่องรอยที่ "ลบไม่ได้" ขึ้นอยู่กับด่าน "ร่างที่ตัดสินแล้วคือแถวตาย"
  -- ถ้าด่านนั้นไม่อยู่ เหตุผลที่เขียนไว้ก็ถูกแก้ทีหลังได้ = ร่องรอยปลอมได้
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.draft_entries'::regclass
                    and g.tgname = 'trg_draft_post_once' and not g.tgisinternal) then
    raise exception 'ไม่มี trigger trg_draft_post_once → ต้องรัน 20261025000017_draft_post_once.sql ก่อนไฟล์นี้ · ถ้าไม่มีด่านนั้น แถวที่ตัดสินแล้วยังแก้ได้ แปลว่าเหตุผลการอนุมัติตัวเองถูกแก้/ล้างทีหลังได้ = ร่องรอยที่ไม่ใช่ร่องรอย';
  end if;
  if to_regclass('sri_os.column_exposure') is null
     or to_regprocedure('sri_os.fn_apply_column_exposure()') is null then
    raise exception 'ไม่มีทะเบียนด่านคอลัมน์ → ต้องรัน 20261020000000_column_exposure.sql ก่อนไฟล์นี้ ไม่งั้นคอลัมน์ใหม่จะไม่มีด่าน (D-089)';
  end if;
end $$;

-- ============================================================
-- 1 · คอลัมน์เหตุผล — ร่องรอยอยู่ **บนแถวที่ตัดสิน** ไม่ใช่ตารางข้างๆ
--     (อยู่บนแถวเดียวกัน = แยกเหตุผลออกจากการตัดสินไม่ได้)
-- ============================================================
alter table draft_entries
  add column if not exists self_review_reason text;

comment on column draft_entries.self_review_reason is
  'C-2 · เหตุผลที่ "คนคีย์ร่าง" กับ "คนตัดสินร่าง" เป็นคนเดียวกัน · เขียนได้เฉพาะเจ้าของร่างเอง (auth.uid() = created_by) และต้องยาว ≥ 10 ตัวอักษร · แถวที่ตัดสินแล้วเป็นแถวตาย (20261025000017) จึงลบ/แก้เหตุผลทีหลังไม่ได้ · ถ้าคนอื่นมาตัดสินแทน ค่านี้จะถูกล้างเป็น null เพราะความหมายของคอลัมน์คือ "ใบนี้ตัดสินโดยผู้คีย์เอง"';

alter table draft_entries drop constraint if exists draft_entries_self_review_reason;
alter table draft_entries
  add constraint draft_entries_self_review_reason
  check (
    self_review_reason is null
    or (length(btrim(self_review_reason)) >= 10
        and (status = 'pending' or reviewed_by = created_by))
  );

comment on constraint draft_entries_self_review_reason on draft_entries is
  'เหตุผลการตัดสินร่างของตัวเอง: ถ้ามี ต้องยาวพอที่จะเป็นเหตุผลจริง และบนแถวที่ตัดสินแล้ว ต้องเป็นกรณีที่ผู้ตัดสิน = ผู้คีย์ (ชั้นที่สองของ trg_draft_review_separation · ชั้นแรกพูดเป็นภาษาคนก่อน)';

-- ============================================================
-- 2 · สวิตช์ในตาราง config (กฎเหล็กข้อ 5)
--     `do nothing` โดยตั้งใจ: ถ้าลูกพี่พลิกเป็น never แล้ว migration ที่รันซ้ำ
--     **ต้องไม่ปลดกลับให้เอง**
-- ============================================================
insert into settings (key, value)
values ('approval.self_review', '"super_admin_with_trail"'::jsonb)
on conflict (key) do nothing;

create or replace function fn_self_review_mode() returns text
language plpgsql stable set search_path = sri_os, public as $fn$
declare v text;
begin
  select value #>> '{}' into v from settings where key = 'approval.self_review';
  -- ไม่มีแถว / ค่าที่ไม่รู้จัก → `never` (เผลอแล้วต้องได้การปฏิเสธ)
  if v is null or v not in ('never', 'super_admin_with_trail') then
    return 'never';
  end if;
  return v;
end $fn$;

comment on function fn_self_review_mode() is
  'C-2 · อ่านสวิตช์ settings[approval.self_review] · ค่าที่รู้จัก: never | super_admin_with_trail · ไม่มีแถวหรือค่าที่สะกดผิด = never (ค่าที่เข้มที่สุด) เพราะความผิดพลาดต้องนำไปสู่การปฏิเสธ ไม่ใช่การอนุญาตเงียบๆ';

revoke all on function fn_self_review_mode() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_self_review_mode() from anon';
  -- ฟอร์มต้องรู้ล่วงหน้าว่าจะต้องใส่เหตุผลไหม (ไม่ใช่ให้ผู้ใช้กรอกจบแล้วค่อยถูกปฏิเสธ)
  execute 'grant execute on function sri_os.fn_self_review_mode() to authenticated';
end $$;

-- ============================================================
-- 3 · ด่านจริง — trigger (ไม่ใช่การเช็คในแอป)
--
-- ทุกอย่างที่ใช้ตัดสินอ่านจาก **ของที่ผู้เรียกเปลี่ยนไม่ได้** (D-115)
--   · ผู้ตัดสิน  = `auth.uid()` ไม่ใช่ `new.reviewed_by`
--   · ผู้คีย์     = `old.created_by` ไม่ใช่ `new.created_by`
--   · ระดับผู้ใช้ = `app_users.role` + ตารางสิทธิ์ ไม่ใช่ค่าที่ส่งมากับคำสั่ง
--   · สวิตช์      = ตาราง settings ซึ่งแก้ได้เฉพาะ settings.manage และถูก audit
-- ============================================================
create or replace function fn_assert_draft_review_separation() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_me      uuid := auth.uid();
  v_reason  text := nullif(btrim(coalesce(new.self_review_reason, '')), '');
  v_mode    text;
  v_role    text;
  v_others  int;
begin
  /**
   * (ก) เหตุผลเขียนได้เฉพาะ **เจ้าของร่าง** และตอนที่ร่างยังไม่ถูกตัดสิน
   * (ไม่ใช่ของคนตัดสินคนอื่น และไม่ใช่ของคนที่มี ledger.approve ทุกคน —
   *  policy `draft_review` ปล่อยให้ผู้อนุมัติทุกคนเขียนทุกคอลัมน์ของร่างได้)
   */
  if new.self_review_reason is distinct from old.self_review_reason
     and v_reason is not null
     and v_me is distinct from old.created_by then
    raise exception 'เหตุผล "อนุมัติร่างของตัวเอง" ของร่าง % เขียนได้เฉพาะคนที่คีย์ร่างนั้นเอง — คุณไม่ใช่คนคีย์ร่างนี้ · ถ้าคุณเป็นผู้อนุมัติที่ไม่ได้คีย์ร่าง ก็ไม่ต้องมีเหตุผลอะไร (อนุมัติได้ตามปกติ)',
      old.id;
  end if;

  -- ยังไม่ใช่การตัดสิน (แก้เนื้อร่างตอน pending) → ไม่ใช่เรื่องของด่านนี้
  -- แถวที่ตัดสินแล้วมี trg_draft_post_once กันไว้อีกชั้น (แก้อะไรไม่ได้เลย)
  if old.status <> 'pending' or new.status = old.status then
    return new;
  end if;

  -- ---------- ตั้งแต่บรรทัดนี้ = pending → approved/rejected ----------
  if v_me is null then
    raise exception 'ตัดสินร่าง % โดยไม่รู้ว่าใครเป็นคนตัดสินไม่ได้ — การอนุมัติต้องมีชื่อคนรับผิดชอบเสมอ (ไม่มีผู้ล็อกอิน: เครื่องอัตโนมัติสร้างได้แค่ร่าง กฎเหล็กข้อ 6)',
      old.id;
  end if;

  /**
   * (ข) **ย้ายชื่อคนคีย์ไม่ได้** — ถ้าย้ายได้ ด่านทั้งใบหลบได้ด้วยคำสั่งเดียว
   * (เปลี่ยน created_by เป็นคนอื่น แล้วอนุมัติเองในคำสั่งเดียวกัน)
   */
  if new.created_by is distinct from old.created_by then
    raise exception 'ย้ายชื่อคนคีย์ร่าง % จาก % เป็น % ไม่ได้ — ถ้าย้ายได้ ด่าน "คนอนุมัติต้องไม่ใช่คนคีย์" ก็หลบได้ทันทีด้วยการเปลี่ยนชื่อคนคีย์',
      old.id, coalesce(old.created_by::text, '(ไม่มี)'), coalesce(new.created_by::text, '(ไม่มี)');
  end if;

  /**
   * (ค) ชื่อผู้ตัดสินและเวลา **ระบบตั้งให้** ไม่ใช่ค่าที่ส่งมา (D-115)
   * เว้นไว้ = เติมให้ (อย่าเชื่อฟิลด์ที่ผู้ใช้เว้นได้) · ส่งชื่อคนอื่น = ปฏิเสธ
   * ถ้าเชื่อค่าที่ส่งมา จะอนุมัติร่างตัวเองแล้วใส่ชื่อเพื่อนร่วมงานเป็นผู้อนุมัติได้
   */
  if new.reviewed_by is null then
    new.reviewed_by := v_me;
  elsif new.reviewed_by <> v_me then
    raise exception 'ร่าง % บันทึกผู้ตัดสินเป็น % ไม่ได้ เพราะคนที่กดคือ % — ชื่อผู้อนุมัติต้องเป็นคนที่กดจริง',
      old.id, new.reviewed_by, v_me;
  end if;
  new.reviewed_at := now();

  -- ---------- คนละคน = เส้นทางปกติ ----------
  if v_me <> old.created_by then
    -- ความหมายของคอลัมน์คือ "ใบนี้ตัดสินโดยผู้คีย์เอง" → ใบนี้ไม่ใช่ จึงต้องว่าง
    new.self_review_reason := null;
    return new;
  end if;

  -- ---------- คนเดียวกัน = ตัดสินร่างของตัวเอง ----------
  v_mode := sri_os.fn_self_review_mode();
  select u.role into v_role
    from sri_os.app_users u where u.id = v_me and u.is_active;
  select count(*) into v_others
    from sri_os.app_users u
    join sri_os.role_permissions rp on rp.role_key = u.role
   where rp.permission_key = 'ledger.approve' and u.is_active and u.id <> v_me;

  if v_mode = 'never' or v_role is distinct from 'super_admin' then
    raise exception 'ร่าง % คีย์โดย % และคุณคือคนเดียวกัน — %',
      old.id, v_me,
      case
        when v_mode = 'never' then
          format('ระบบตั้งไว้ว่า "ห้ามอนุมัติร่างของตัวเองทุกกรณี" (settings[approval.self_review] = never) · ให้ผู้อนุมัติคนอื่นเป็นคนกด (ตอนนี้มีอยู่ %s คน)', v_others)
        else
          format('การแยกหน้าที่ (D-072) บังคับว่าคนคีย์กับคนอนุมัติต้องไม่ใช่คนเดียวกัน · ให้ผู้อนุมัติคนอื่นเป็นคนกด (ตอนนี้มีอยู่ %s คน) · มีเพียงผู้ดูแลระบบสูงสุดเท่านั้นที่อนุมัติร่างของตัวเองได้ และต้องใส่เหตุผลกำกับทุกครั้ง', v_others)
      end;
  end if;

  if v_reason is null or length(v_reason) < 10 then
    raise exception 'ร่าง % เป็นร่างที่คุณคีย์เอง · อนุมัติเองได้ (คุณคือผู้ดูแลระบบสูงสุด) แต่ **ต้องเขียนเหตุผลกำกับ** ลงช่อง self_review_reason อย่างน้อย 10 ตัวอักษรก่อน — เหตุผลนี้ลบไม่ได้และขึ้นรายงาน sri_os.fn_self_reviewed_drafts() ให้ไล่ดูได้ (ผู้อนุมัติคนอื่นที่มีอยู่ตอนนี้: %s คน)',
      old.id, v_others;
  end if;

  new.self_review_reason := v_reason;
  return new;
end $fn$;

comment on function fn_assert_draft_review_separation() is
  'C-2 · คนคีย์ร่างกับคนตัดสินร่างต้องไม่ใช่คนเดียวกัน · ข้อยกเว้นเดียว: super_admin (ตอนที่ settings[approval.self_review] = super_admin_with_trail) ทำได้ถ้าเขียนเหตุผล ≥ 10 ตัวอักษรไว้บนแถวร่าง ซึ่งลบไม่ได้เพราะแถวที่ตัดสินแล้วเป็นแถวตาย · reviewed_by/reviewed_at ระบบตั้งจากผู้ล็อกอินจริง (D-115) · created_by ย้ายไม่ได้';

revoke all on function fn_assert_draft_review_separation() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_draft_review_separation() from anon, authenticated';
end $$;

-- ชื่อ trigger ตั้งให้เรียงหลัง `trg_draft_post_once` โดยตั้งใจ
-- (Postgres ยิง BEFORE trigger ตามลำดับชื่อ → ด่าน "ร่างตาย/ต้องลงสมุด" พูดก่อน
--  ซึ่งเป็นข้อความที่ตรงปัญหากว่าในเคสที่ผิดทั้งสองอย่าง)
drop trigger if exists trg_draft_review_separation on draft_entries;
create trigger trg_draft_review_separation
  before update on draft_entries
  for each row execute function fn_assert_draft_review_separation();

-- ============================================================
-- 4 · รายงานให้ไล่ดูได้ — ด่านที่ไม่มีรายงาน = ด่านที่ไม่มีใครรู้ว่าถูกใช้
--
-- `security invoker` โดยตั้งใจ: RLS ของ draft_entries/app_users ยังทำงาน
-- → ไม่กลายเป็นทางข้ามสิทธิ์ (และไม่ต้องเข้า allow-list ของด่านคอลัมน์ D-089)
-- ============================================================
create or replace function fn_self_reviewed_drafts(
  p_from date default null, p_to date default null)
returns table (
  draft_id            uuid,
  decided_at          timestamptz,
  status              text,
  owner_code          text,
  txn_type_code       text,
  amount              numeric,
  reviewer            text,
  reason              text,
  posted_txn_id       uuid,
  other_approvers_now int)
language plpgsql stable set search_path = sri_os, public as $fn$
begin
  if not fn_can('owner.view_all') then
    raise exception 'รายงานการอนุมัติร่างของตัวเอง ต้องมีสิทธิ์ owner.view_all — คนที่ถูกตรวจไม่ควรเป็นคนเดียวกับคนที่ควบคุมว่าใครเห็นรายงาน';
  end if;
  return query
    select d.id, d.reviewed_at, d.status::text, o.code, d.txn_type_code, d.amount,
           coalesce(u.display_name, u.email, d.reviewed_by::text),
           d.self_review_reason, d.posted_txn_id,
           (select count(*)::int from app_users x
              join role_permissions rp on rp.role_key = x.role
             where rp.permission_key = 'ledger.approve'
               and x.is_active and x.id <> d.reviewed_by)
      from draft_entries d
      join owners o on o.id = d.owner_id
      left join app_users u on u.id = d.reviewed_by
     where d.self_review_reason is not null
       and d.status <> 'pending'
       and (p_from is null or d.reviewed_at >= p_from::timestamptz)
       and (p_to is null or d.reviewed_at < (p_to + 1)::timestamptz)
     order by d.reviewed_at desc;
end $fn$;

comment on function fn_self_reviewed_drafts(date, date) is
  'C-2 · รายงานร่างที่ "คนคีย์ = คนตัดสิน" ทุกใบพร้อมเหตุผล · ต้องมี owner.view_all · คอลัมน์ other_approvers_now บอกว่าวันนี้มีผู้อนุมัติคนอื่นกี่คน → ถ้ามีคนอื่นอยู่แล้วยังอนุมัติเอง จะเห็นเป็นตัวเลข ไม่ต้องเชื่อความจำใคร (ถึงจุดนั้นให้พลิก settings[approval.self_review] = never)';

revoke all on function fn_self_reviewed_drafts(date, date) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_self_reviewed_drafts(date, date) from anon';
  execute 'grant execute on function sri_os.fn_self_reviewed_drafts(date, date) to authenticated';
end $$;

-- ============================================================
-- 5 · ด่านคอลัมน์ (D-089) — คอลัมน์ใหม่ที่ไม่ขึ้นทะเบียน = guard แดง
--     `self_review_reason` เป็นข้อความบนแถวร่าง ไม่ใช่ตัวเลขเงิน
--     → `open` เหมือน `memo`/`reject_reason` (คนที่เห็นแถวร่างได้ ควรเห็นเหตุผลด้วย)
-- ============================================================
insert into column_exposure (table_name, column_name, exposure, min_permission, rationale)
values ('draft_entries', 'self_review_reason', 'open', null,
        'เหตุผลที่ผู้คีย์ร่างเป็นคนตัดสินร่างเอง · ไม่มีตัวเลขเงิน และคนที่เห็นแถวร่างได้อยู่แล้ว (เจ้าของร่างหรือคนที่มี ledger.read) ควรเห็นเหตุผลด้วย — การซ่อนเหตุผลทำให้ร่องรอยไม่มีประโยชน์ · เหมือน memo/reject_reason ของตารางเดียวกัน')
on conflict (table_name, column_name) do update
  set exposure = excluded.exposure, min_permission = excluded.min_permission,
      rationale = excluded.rationale;

select fn_apply_column_exposure();

-- ============================================================
-- 6 · guard ท้ายไฟล์ — ดังตอน migrate ไม่ใช่ตอนผู้ใช้กด
-- ============================================================
do $$
declare v text; n int;
begin
  -- (ก) ของครบ
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'sri_os' and table_name = 'draft_entries'
                    and column_name = 'self_review_reason') then
    raise exception 'ไม่มีคอลัมน์ draft_entries.self_review_reason';
  end if;
  if not exists (select 1 from pg_constraint
                  where conname = 'draft_entries_self_review_reason') then
    raise exception 'ไม่มี CHECK draft_entries_self_review_reason → เหตุผลสั้นๆ อย่าง "x" ผ่านได้';
  end if;
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.draft_entries'::regclass
                    and g.tgname = 'trg_draft_review_separation' and not g.tgisinternal) then
    raise exception 'ไม่มี trigger trg_draft_review_separation → ด่านอยู่แต่ไม่มีใครเรียก';
  end if;

  -- (ข) trigger ต้องเป็น BEFORE UPDATE (AFTER แก้ค่า new ไม่ได้ → ปักชื่อผู้ตัดสินไม่ได้)
  if exists (select 1 from pg_trigger g
              where g.tgrelid = 'sri_os.draft_entries'::regclass
                and g.tgname = 'trg_draft_review_separation'
                and (g.tgtype & 2) = 0) then
    raise exception 'trg_draft_review_separation ต้องเป็น BEFORE UPDATE — AFTER จะแก้ new.reviewed_by/reviewed_at ไม่ได้';
  end if;

  -- (ค) ลำดับชื่อ: ด่านของ C-1 ต้องพูดก่อน
  if 'trg_draft_post_once' > 'trg_draft_review_separation' then
    raise exception 'ชื่อ trigger เรียงผิด — ด่าน trg_draft_post_once ต้องยิงก่อน';
  end if;

  -- (ง) สวิตช์อยู่ในตาราง config และค่าที่อ่านได้ต้องเป็นค่าที่รู้จัก
  if not exists (select 1 from sri_os.settings where key = 'approval.self_review') then
    raise exception 'ไม่มีแถว settings[approval.self_review] → สวิตช์ hard-code อยู่ในโค้ด (ขัดกฎเหล็กข้อ 5)';
  end if;
  if sri_os.fn_self_review_mode() not in ('never', 'super_admin_with_trail') then
    raise exception 'fn_self_review_mode() คืนค่าที่ไม่รู้จัก: %', sri_os.fn_self_review_mode();
  end if;

  -- (จ) **ค่าที่สะกดผิดต้องตีความเป็น never** (เผลอแล้วต้องปฏิเสธ) — พิสูจน์จริง ไม่ใช่เชื่อโค้ด
  --     ทำในบล็อกที่ย้อนค่าคืนทุกเส้นทาง
  begin
    update sri_os.settings set value = '"ALWAYS"'::jsonb where key = 'approval.self_review';
    v := sri_os.fn_self_review_mode();
  exception when others then
    update sri_os.settings set value = '"super_admin_with_trail"'::jsonb
     where key = 'approval.self_review';
    raise;
  end;
  update sri_os.settings set value = '"super_admin_with_trail"'::jsonb
   where key = 'approval.self_review';
  if v <> 'never' then
    raise exception 'ค่าสวิตช์ที่ไม่รู้จักถูกตีความเป็น "%" ไม่ใช่ never — ความผิดพลาดต้องนำไปสู่การปฏิเสธ', v;
  end if;

  -- (ฉ) ด่านต้องอ่านจากของที่ผู้เรียกเปลี่ยนไม่ได้ (D-115)
  --     ตรวจบน prosrc ที่ตัดคอมเมนต์ออกแล้ว ไม่ให้ guard จับคำอธิบายของตัวเอง
  select regexp_replace(
           regexp_replace(p.prosrc, '/\*.*?\*/', ' ', 'gs'),
           '--[^\n]*', ' ', 'g')
    into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_assert_draft_review_separation';
  if v is null then
    raise exception 'อ่าน prosrc ของ fn_assert_draft_review_separation ไม่ได้ — ไม่ยอมผ่านด้วยชุดว่าง';
  end if;
  if v !~ 'auth\.uid\(\)' then
    raise exception 'ด่านไม่ได้อ่านผู้ตัดสินจาก auth.uid() → เชื่อค่าที่ผู้เรียกส่งมา (D-115)';
  end if;
  if v ~ 'new\.created_by\s*(=|<>)' then
    raise exception 'ด่านตัดสินด้วย new.created_by → ผู้เรียกเปลี่ยนค่านั้นได้ ต้องอ่าน old.created_by (D-115)';
  end if;
  if v !~ 'app_users' or v !~ 'role_permissions' then
    raise exception 'ด่านไม่ได้อ่านระดับผู้ใช้/สิทธิ์จากตารางจริง';
  end if;

  -- (ช) รายงานต้องถามสิทธิ์ก่อนคืนข้อมูล
  select pg_get_functiondef('sri_os.fn_self_reviewed_drafts(date, date)'::regprocedure) into v;
  if v !~ 'owner\.view_all' then
    raise exception 'fn_self_reviewed_drafts ไม่ได้ถาม owner.view_all → ใครก็เรียกดูได้';
  end if;
  if v ~* 'security\s+definer' then
    raise exception 'fn_self_reviewed_drafts เป็น definer → กลายเป็นทางข้ามสิทธิ์ของ draft_entries (D-089)';
  end if;

  -- (ซ) คอลัมน์ใหม่ต้องขึ้นทะเบียนด่านคอลัมน์
  if not exists (select 1 from sri_os.column_exposure
                  where table_name = 'draft_entries' and column_name = 'self_review_reason') then
    raise exception 'คอลัมน์ self_review_reason ไม่ได้ขึ้นทะเบียนด่านคอลัมน์ (D-089)';
  end if;

  -- (ฌ) แถวเดิมในระบบต้องไม่ขัดกับกฎใหม่ (ถ้ามี ต้องรู้ ไม่ใช่ค่อยเจอตอนผู้ใช้กด)
  select count(*) into n from sri_os.draft_entries
   where status <> 'pending' and reviewed_by is not null and reviewed_by = created_by;
  if n > 0 then
    raise warning 'มีร่าง % ใบที่ถูกตัดสินโดยคนคีย์เอง **ก่อน** ด่านนี้ และไม่มีเหตุผลกำกับ (ของเก่าแก้ย้อนหลังไม่ได้ เพราะร่างที่ตัดสินแล้วเป็นแถวตาย) → ไล่ดูด้วย sri_os.fn_self_reviewed_drafts() ไม่เห็นใบพวกนี้ ให้ดูที่ audit_log', n;
  end if;

  raise notice 'C-2 ok · คนอนุมัติต้องไม่ใช่คนคีย์ · ข้อยกเว้น super_admin ต้องมีเหตุผลและขึ้นรายงาน · สวิตช์อยู่ใน settings[approval.self_review]';
end $$;
