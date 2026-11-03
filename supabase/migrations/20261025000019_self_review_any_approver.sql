-- ============================================================
-- SRI OS · C-2 (แก้ตามที่ลูกพี่ตัดสิน 25/10) · **ผู้อนุมัติอนุมัติร่างของตัวเองได้**
--
-- คำสั่งของลูกพี่
--   "ระดับ management คีย์เองได้ อนุมัติของตัวเองได้ · Manager ก็อนุมัติได้ คีย์เองได้"
--   → ทุกคนที่มีสิทธิ์อนุมัติ (`ledger.approve`) อนุมัติร่างที่ตัวเองคีย์ได้
--     **โดยไม่ต้องเขียนเหตุผล** (กองกลางครอบครัวที่คนคีย์กับคนอนุมัติเป็นคนเดียวกัน
--     เป็นเรื่องปกติ · และด่านที่ทำให้ระบบใช้ไม่ได้จะถูกปิดทิ้งในที่สุด)
--
-- ------------------------------------------------------------
-- **ไม่รื้อกลไกทิ้ง — เพิ่มโหมดที่สามแล้วพลิกสวิตช์** (กฎเหล็กข้อ 5)
-- ------------------------------------------------------------
--   `settings['approval.self_review']`
--     · `never`                  ห้ามทุกคน
--     · `super_admin_with_trail` เฉพาะ super_admin + ต้องมีเหตุผล
--     · `any_approver`           **ใหม่ · ค่าปัจจุบัน** ทุกคนที่มีสิทธิ์อนุมัติ ทำได้
--                                ไม่ต้องมีเหตุผล (ใส่ก็ได้ ไม่ใส่ก็ได้)
--   วันที่มีทีมบัญชีหลายคนแล้วอยากเปิดด่านกลับ = พลิกค่าในตาราง ไม่ต้องแก้โค้ด
--   (ถ้าลบกลไกทิ้งวันนี้ วันนั้นต้องเขียนใหม่ทั้งชุด)
--
-- ------------------------------------------------------------
-- **"อนุญาต" ไม่เท่ากับ "ไม่บันทึก"** — สิ่งที่คงไว้ทุกโหมด
-- ------------------------------------------------------------
--   1. `reviewed_by` ตั้งจากผู้ล็อกอินจริง · ส่งชื่อคนอื่นมา = ปฏิเสธ
--      (ไม่งั้นประวัติว่า "ใครอนุมัติ" โกหกได้ ซึ่งไม่เกี่ยวกับการแยกหน้าที่เลย)
--   2. `created_by` ย้ายไม่ได้ (ไม่งั้นประวัติว่า "ใครคีย์" โกหกได้)
--   3. ไม่มีผู้ล็อกอิน = ปฏิเสธ (กฎเหล็กข้อ 6)
--   4. ร่างที่ตัดสินแล้วแก้ไม่ได้ (20261025000017)
--   5. รายงาน `fn_self_reviewed_drafts()` **ยังทำงานทุกโหมด**
--
--   **เปลี่ยนวิธีที่รายงานรู้ว่าเป็นการอนุมัติตัวเอง** (จุดสำคัญของไฟล์นี้):
--     เดิมดูจาก `self_review_reason is not null` — ใช้ไม่ได้อีกแล้ว เพราะเหตุผล
--     กลายเป็น "ใส่ก็ได้" → ถ้าไม่เปลี่ยน รายงานจะว่างเปล่าทั้งที่มีการอนุมัติตัวเอง
--     ทุกวัน (เงียบสนิท = แย่กว่าไม่มีรายงาน เพราะทำให้เชื่อว่าไม่มี)
--     ใหม่ดูจาก **`reviewed_by = created_by`** ซึ่งเป็นสองคอลัมน์ที่ระบบตรึงเอง
--     ปลอมไม่ได้ และไม่ขึ้นกับว่าใครขยันพิมพ์เหตุผล (D-115)
--
-- ลำดับ: ต้องรันหลัง 20261025000018 (ไฟล์นี้เขียนทับของในไฟล์นั้น) · guard หัวไฟล์ตรวจให้
--        **ไม่แก้ `...0018`** — ของที่ commit แล้วกู้ด้วยไฟล์ใหม่เสมอ
--        ⚠ ถ้าวันหนึ่งมีใครรัน `...0018` ซ้ำ **หลัง** ไฟล์นี้ ค่าสวิตช์จะไม่ถูกแตะ
--          (ไฟล์นั้น insert ... do nothing) แต่ guard ของไฟล์นั้นจะปฏิเสธค่า
--          `any_approver` → ต้องรันไฟล์นี้ตามหลังอีกรอบ (ทั้งสองไฟล์ idempotent)
--
-- idempotent: create or replace · update ที่ระบุค่าเดิม · insert ... on conflict do nothing
--
-- ย้อนกลับ (rollback):
--   -- update sri_os.settings set value = '"super_admin_with_trail"'::jsonb
--   --  where key = 'approval.self_review';
--   -- -- แล้วรัน 20261025000018_draft_no_self_review.sql ซ้ำ (idempotent)
--   ⚠ ย้อนแล้ว **ขัดคำสั่งลูกพี่ 25/10** — management/manager จะอนุมัติร่างตัวเองไม่ได้
--     ทั้งที่เขาสั่งว่าได้ · ย้อนเฉพาะกรณีที่เขาสั่งใหม่
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 0 · ของที่ต้องมีมาก่อน
-- ============================================================
do $$
begin
  if to_regprocedure('sri_os.fn_self_review_mode()') is null
     or to_regprocedure('sri_os.fn_self_reviewed_drafts(date, date)') is null then
    raise exception 'ไม่มี fn_self_review_mode / fn_self_reviewed_drafts → ต้องรัน 20261025000018_draft_no_self_review.sql ก่อนไฟล์นี้ (ไฟล์นี้เขียนทับของในไฟล์นั้น)';
  end if;
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.draft_entries'::regclass
                    and g.tgname = 'trg_draft_review_separation' and not g.tgisinternal) then
    raise exception 'ไม่มี trigger trg_draft_review_separation → ต้องรัน 20261025000018 ก่อนไฟล์นี้';
  end if;
  -- ด่านคู่: ข้อ 4 ของ "สิ่งที่คงไว้" คือร่างที่ตัดสินแล้วแก้ไม่ได้ ซึ่งอยู่ใน C-1
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.draft_entries'::regclass
                    and g.tgname = 'trg_draft_post_once' and not g.tgisinternal) then
    raise exception 'ไม่มี trigger trg_draft_post_once → ต้องรัน 20261025000017 ก่อนไฟล์นี้ · ถ้าไม่มีด่านนั้น ประวัติการอนุมัติ (ใครอนุมัติ เมื่อไหร่) ถูกแก้ย้อนหลังได้';
  end if;
end $$;

-- ============================================================
-- 1 · โหมดที่สาม + พลิกค่าเป็นค่าปัจจุบัน
--     `update` ระบุค่าเดิมไว้ → **ไม่ทับค่าที่ลูกพี่ตั้งเองภายหลัง**
--     (ถ้าวันหนึ่งเขาพลิกเป็น never แล้ว migration รันซ้ำ ต้องไม่ปลดกลับให้เอง)
-- ============================================================
insert into settings (key, value)
values ('approval.self_review', '"any_approver"'::jsonb)
on conflict (key) do nothing;

do $$
declare n int;
begin
  update settings set value = '"any_approver"'::jsonb
   where key = 'approval.self_review'
     and value = '"super_admin_with_trail"'::jsonb;
  get diagnostics n = row_count;
  if n = 0 then
    raise notice 'settings[approval.self_review] ไม่ได้ถูกเปลี่ยนโดยไฟล์นี้ (ค่าปัจจุบัน = %) — ถ้าเป็นค่าที่ตั้งไว้เองก็ถูกแล้ว',
      (select value #>> '{}' from settings where key = 'approval.self_review');
  end if;
end $$;

create or replace function fn_self_review_mode() returns text
language plpgsql stable set search_path = sri_os, public as $fn$
declare v text;
begin
  select value #>> '{}' into v from settings where key = 'approval.self_review';
  -- ไม่มีแถว / ค่าที่ไม่รู้จัก → `never` (เผลอแล้วต้องได้การปฏิเสธ ไม่ใช่การอนุญาต)
  if v is null or v not in ('never', 'super_admin_with_trail', 'any_approver') then
    return 'never';
  end if;
  return v;
end $fn$;

comment on function fn_self_review_mode() is
  'C-2 · อ่านสวิตช์ settings[approval.self_review] · ค่าที่รู้จัก: never | super_admin_with_trail | any_approver (ค่าปัจจุบันตามคำสั่งลูกพี่ 25/10 = any_approver คือผู้อนุมัติทุกคนอนุมัติร่างตัวเองได้ ไม่ต้องมีเหตุผล) · ไม่มีแถวหรือค่าที่สะกดผิด = never (ค่าที่เข้มที่สุด)';

revoke all on function fn_self_review_mode() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_self_review_mode() from anon';
  execute 'grant execute on function sri_os.fn_self_review_mode() to authenticated';
end $$;

-- ============================================================
-- 2 · ด่าน — โหมด `any_approver` ปล่อยผ่าน แต่ **ของที่ไม่เกี่ยวกับการแยกหน้าที่
--     ยังบังคับทุกโหมด** (ชื่อผู้ตัดสิน · ชื่อคนคีย์ · ต้องมีผู้ล็อกอิน)
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
   * (ก) เหตุผลเขียนได้เฉพาะ **เจ้าของร่าง** (ใส่ก็ได้ ไม่ใส่ก็ได้ ตั้งแต่ 25/10)
   * policy `draft_review` ปล่อยให้ผู้อนุมัติทุกคนเขียนทุกคอลัมน์ของร่างได้ →
   * ถ้าไม่กัน ผู้อนุมัติคนอื่นเขียนเหตุผลใส่ปากเจ้าของร่างได้
   */
  if new.self_review_reason is distinct from old.self_review_reason
     and v_reason is not null
     and v_me is distinct from old.created_by then
    raise exception 'เหตุผลกำกับของร่าง % เขียนได้เฉพาะคนที่คีย์ร่างนั้นเอง — คุณไม่ใช่คนคีย์ร่างนี้',
      old.id;
  end if;

  -- ยังไม่ใช่การตัดสิน (แก้เนื้อร่างตอน pending) → ไม่ใช่เรื่องของด่านนี้
  -- แถวที่ตัดสินแล้วมี trg_draft_post_once กันไว้อีกชั้น (แก้อะไรไม่ได้เลย)
  if old.status <> 'pending' or new.status = old.status then
    return new;
  end if;

  -- ---------- ตั้งแต่บรรทัดนี้ = pending → approved/rejected ----------

  -- (ข) กฎเหล็กข้อ 6: ไม่มีผู้ล็อกอิน = ปฏิเสธ (เครื่องอัตโนมัติสร้างได้แค่ร่าง)
  if v_me is null then
    raise exception 'ตัดสินร่าง % โดยไม่รู้ว่าใครเป็นคนตัดสินไม่ได้ — การอนุมัติต้องมีชื่อคนรับผิดชอบเสมอ (กฎเหล็กข้อ 6: automation ไม่เคย post เอง)',
      old.id;
  end if;

  /**
   * (ค) **ย้ายชื่อคนคีย์ไม่ได้** — ไม่เกี่ยวกับการแยกหน้าที่ แต่เป็นความซื่อของประวัติ
   * ถ้าย้ายได้ คำถาม "ใครคีย์ใบนี้" ตอบไม่ได้ และรายงานอนุมัติตัวเองก็หลบได้ด้วย
   */
  if new.created_by is distinct from old.created_by then
    raise exception 'ย้ายชื่อคนคีย์ร่าง % จาก % เป็น % ไม่ได้ — ประวัติว่าใครคีย์ร่างต้องแก้ไม่ได้ (และถ้าย้ายได้ รายงานการอนุมัติร่างตัวเองก็หลบได้ด้วยคำสั่งเดียว)',
      old.id, coalesce(old.created_by::text, '(ไม่มี)'), coalesce(new.created_by::text, '(ไม่มี)');
  end if;

  /**
   * (ง) ชื่อผู้ตัดสินและเวลา **ระบบตั้งให้** ไม่ใช่ค่าที่ส่งมา (D-115)
   * เว้นไว้ = เติมให้ · ส่งชื่อคนอื่น = ปฏิเสธ
   * ไม่งั้นอนุมัติเองแล้วลงชื่อเพื่อนร่วมงานเป็นผู้อนุมัติได้ = ประวัติโกหก
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
    -- เหตุผลกำกับมีความหมายเฉพาะกรณี "ผู้คีย์ตัดสินเอง" → ใบนี้ไม่ใช่ จึงต้องว่าง
    new.self_review_reason := null;
    return new;
  end if;

  -- ---------- คนเดียวกัน = ตัดสินร่างของตัวเอง ----------
  -- **บันทึกไว้ทุกโหมด** (reviewed_by = created_by ซึ่งตรึงแล้วด้านบน) →
  -- รายงาน fn_self_reviewed_drafts() เห็นทุกใบไม่ว่าจะมีเหตุผลหรือไม่
  v_mode := sri_os.fn_self_review_mode();
  if v_mode = 'any_approver' then
    new.self_review_reason := v_reason;   -- ใส่ก็ได้ ไม่ใส่ก็ได้
    return new;
  end if;

  select u.role into v_role
    from sri_os.app_users u where u.id = v_me and u.is_active;
  select count(*) into v_others
    from sri_os.app_users u
    join sri_os.role_permissions rp on rp.role_key = u.role
   where rp.permission_key = 'ledger.approve' and u.is_active and u.id <> v_me;

  if v_mode = 'never' then
    raise exception 'ร่าง % คีย์โดยคุณเอง และระบบตั้งไว้ว่า "ห้ามอนุมัติร่างของตัวเองทุกกรณี" (settings[approval.self_review] = never) — ให้ผู้อนุมัติคนอื่นเป็นคนกด (ตอนนี้มีอยู่ %s คน)',
      old.id, v_others;
  end if;

  -- เหลือโหมด super_admin_with_trail
  if v_role is distinct from 'super_admin' then
    raise exception 'ร่าง % คีย์โดยคุณเอง และระบบตั้งไว้ว่ามีเพียงผู้ดูแลระบบสูงสุดที่อนุมัติร่างของตัวเองได้ (settings[approval.self_review] = super_admin_with_trail) — ให้ผู้อนุมัติคนอื่นเป็นคนกด (ตอนนี้มีอยู่ %s คน)',
      old.id, v_others;
  end if;
  if v_reason is null or length(v_reason) < 10 then
    raise exception 'ร่าง % เป็นร่างที่คุณคีย์เอง · อนุมัติเองได้ แต่โหมดนี้ **ต้องเขียนเหตุผลกำกับ** ลงช่อง self_review_reason อย่างน้อย 10 ตัวอักษรก่อน (ผู้อนุมัติคนอื่นที่มีอยู่ตอนนี้: %s คน)',
      old.id, v_others;
  end if;

  new.self_review_reason := v_reason;
  return new;
end $fn$;

comment on function fn_assert_draft_review_separation() is
  'C-2 (25/10) · โหมดจาก settings[approval.self_review]: any_approver = ผู้อนุมัติทุกคนอนุมัติร่างตัวเองได้ ไม่ต้องมีเหตุผล (ค่าปัจจุบันตามคำสั่งลูกพี่) · super_admin_with_trail = เฉพาะ super_admin + ต้องมีเหตุผล · never = ห้ามทุกคน · **บังคับทุกโหมด**: ต้องมีผู้ล็อกอิน · reviewed_by/reviewed_at ระบบตั้งจาก auth.uid() (ส่งชื่อคนอื่น = ปฏิเสธ) · created_by ย้ายไม่ได้ — สามข้อนี้ไม่เกี่ยวกับการแยกหน้าที่ แต่เป็นความซื่อของประวัติการอนุมัติ';

revoke all on function fn_assert_draft_review_separation() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_draft_review_separation() from anon, authenticated';
end $$;

-- ============================================================
-- 3 · รายงาน — รู้จาก **`reviewed_by = created_by`** ไม่ใช่จากการมีเหตุผล
--     (เหตุผลกลายเป็น "ใส่ก็ได้" → ถ้ายังดูจากเหตุผล รายงานจะว่างเปล่าเงียบๆ)
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
     where d.status <> 'pending'
       and d.reviewed_by is not null
       and d.reviewed_by = d.created_by
       and (p_from is null or d.reviewed_at >= p_from::timestamptz)
       and (p_to is null or d.reviewed_at < (p_to + 1)::timestamptz)
     order by d.reviewed_at desc;
end $fn$;

comment on function fn_self_reviewed_drafts(date, date) is
  'C-2 (25/10) · รายงานร่างที่ "คนคีย์ = คนตัดสิน" ทุกใบ · เงื่อนไขอ่านจาก reviewed_by = created_by ซึ่งระบบตรึงเองทั้งสองคอลัมน์ (ไม่ขึ้นกับว่าใครขยันพิมพ์เหตุผล · D-115) · ลูกพี่อนุญาตให้ทำได้แล้ว แต่ "อนุญาต" ไม่เท่ากับ "ไม่บันทึก" → ยังไล่ดูได้ว่าใครอนุมัติร่างตัวเองเมื่อไหร่ · ต้องมี owner.view_all';

revoke all on function fn_self_reviewed_drafts(date, date) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_self_reviewed_drafts(date, date) from anon';
  execute 'grant execute on function sri_os.fn_self_reviewed_drafts(date, date) to authenticated';
end $$;

-- ============================================================
-- 4 · guard ท้ายไฟล์
-- ============================================================
do $$
declare v text; v_mode text;
begin
  -- (ก) สวิตช์ต้องรู้จักทั้งสามโหมด และตอนนี้ต้องเป็น any_approver
  if sri_os.fn_self_review_mode() <> 'any_approver' then
    raise exception 'ค่าสวิตช์ตอนนี้เป็น "%" ไม่ใช่ any_approver — คำสั่งลูกพี่ 25/10 คือผู้อนุมัติทุกคนอนุมัติร่างตัวเองได้',
      sri_os.fn_self_review_mode();
  end if;
  -- ทั้งสามค่าต้อง "ผ่าน" ตัวอ่าน (ไม่ถูกตีกลับเป็น never) · คืนค่าเดิมทุกเส้นทาง
  begin
    foreach v in array array['never', 'super_admin_with_trail', 'any_approver'] loop
      update sri_os.settings set value = to_jsonb(v) where key = 'approval.self_review';
      v_mode := sri_os.fn_self_review_mode();
      if v_mode <> v then
        raise exception 'โหมด "%" ถูกตีความเป็น "%" — สวิตช์สามทางต้องพลิกได้จริงทั้งสามทาง', v, v_mode;
      end if;
    end loop;
    -- ค่าที่สะกดผิดต้องเป็น never (เผลอแล้วต้องปฏิเสธ)
    update sri_os.settings set value = '"ANY"'::jsonb where key = 'approval.self_review';
    v_mode := sri_os.fn_self_review_mode();
  exception when others then
    update sri_os.settings set value = '"any_approver"'::jsonb where key = 'approval.self_review';
    raise;
  end;
  update sri_os.settings set value = '"any_approver"'::jsonb where key = 'approval.self_review';
  if v_mode <> 'never' then
    raise exception 'ค่าสวิตช์ที่ไม่รู้จักถูกตีความเป็น "%" ไม่ใช่ never', v_mode;
  end if;

  -- (ข) สามข้อที่ต้องคงไว้ทุกโหมด — ตรวจบน prosrc ที่ตัดคอมเมนต์ออกแล้ว
  select regexp_replace(
           regexp_replace(p.prosrc, '/\*.*?\*/', ' ', 'gs'),
           '--[^\n]*', ' ', 'g')
    into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_assert_draft_review_separation';
  if v is null then
    raise exception 'อ่าน prosrc ของด่านไม่ได้ — ไม่ยอมผ่านด้วยชุดว่าง';
  end if;
  if v !~ 'auth\.uid\(\)' then
    raise exception 'ด่านไม่ได้อ่านผู้ตัดสินจาก auth.uid() → เชื่อค่าที่ผู้เรียกส่งมา (D-115)';
  end if;
  if v !~ 'new\.reviewed_by\s*(<>|is null)' then
    raise exception 'ด่านไม่ได้ตรวจ/ปัก new.reviewed_by → ประวัติการอนุมัติปลอมได้';
  end if;
  if v !~ 'new\.created_by is distinct from old\.created_by' then
    raise exception 'ด่านไม่ได้กันการย้าย created_by → ประวัติว่าใครคีย์ปลอมได้';
  end if;
  if v !~ 'v_me is null' then
    raise exception 'ด่านไม่ได้ปฏิเสธกรณีไม่มีผู้ล็อกอิน (กฎเหล็กข้อ 6)';
  end if;

  -- (ค) รายงานต้องรู้จาก reviewed_by = created_by ไม่ใช่จากการมีเหตุผล
  select pg_get_functiondef('sri_os.fn_self_reviewed_drafts(date, date)'::regprocedure) into v;
  if v !~ 'reviewed_by\s*=\s*d?\.?created_by' then
    raise exception 'รายงานไม่ได้ใช้เงื่อนไข reviewed_by = created_by → ถ้ายังดูจาก self_review_reason รายงานจะว่างเปล่าเงียบๆ เพราะเหตุผลกลายเป็นช่องที่ไม่บังคับ';
  end if;
  if v ~ 'self_review_reason is not null' then
    raise exception 'รายงานยังกรองด้วย self_review_reason is not null → ใบที่อนุมัติเองโดยไม่ใส่เหตุผลจะหายไปจากรายงาน';
  end if;
  if v !~ 'owner\.view_all' then
    raise exception 'รายงานไม่ได้ถาม owner.view_all → ใครก็เรียกดูได้';
  end if;
  if v ~* 'security\s+definer' then
    raise exception 'รายงานเป็น definer → กลายเป็นทางข้ามสิทธิ์ของ draft_entries (D-089)';
  end if;

  raise notice 'C-2 (25/10) ok · โหมด any_approver: ผู้อนุมัติทุกคนอนุมัติร่างตัวเองได้ ไม่ต้องมีเหตุผล · ชื่อผู้ตัดสิน/ชื่อคนคีย์/การต้องมีผู้ล็อกอิน ยังบังคับทุกโหมด · รายงานยังเห็นทุกใบจาก reviewed_by = created_by';
end $$;
