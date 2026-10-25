-- ============================================================
-- SRI OS · **ร่างหนึ่งใบลงสมุดได้ครั้งเดียวตลอดกาล** (C-1 · เรื่องเงิน)
--
-- ------------------------------------------------------------
-- **รูที่ปิด**
--
-- `draft_entries` ไม่มีด่านอะไรเลยว่า `status = 'approved'` ต้องมี `posted_txn_id`
-- และ policy `draft_review` ให้ใครที่มี `ledger.approve` **UPDATE แถวได้อิสระ**
-- → เส้นทางของแอปคือ "โพสต์เข้าสมุด แล้วค่อยอัปเดตร่าง" ซึ่งเป็น **อ่านก่อนเขียน**:
--
--   ผู้อนุมัติ A อ่านร่าง (pending) → โพสต์ใบที่ 1
--   ผู้อนุมัติ B อ่านร่าง (pending เหมือนกัน) → โพสต์ใบที่ 2
--   ทั้งคู่อัปเดตร่าง → `posted_txn_id` เหลือใบเดียว **แต่สมุดมีสองใบ**
--   = **ยอดเกินจริงเท่าตัว** และใบที่ถูกเขียนทับกลายเป็นใบกำพร้าที่ไม่มีร่างชี้ถึง
--
-- นี่คือรูปเดียวกับที่ด่านล้างยอดเกินแพ้สามชั้นติด (D-115): **ชั้นที่เป็น
-- "อ่านแล้วเขียน" แพ้จังหวะพร้อมกันทุกครั้ง** ต้องเป็นการ **ล็อกแถว** หรือ
-- **ข้อจำกัดระดับฐานข้อมูล** ซึ่งเป็นสองอย่างที่จังหวะปลอมไม่ได้
--
-- ------------------------------------------------------------
-- **สี่ชั้นที่ไฟล์นี้วาง — แต่ละชั้นกันคนละรูป**
--
-- 1. **CHECK `approved ⟺ posted_txn_id`** — ร่างที่อนุมัติแล้วต้องชี้ใบในสมุด
--    และร่างที่ยัง pending/rejected ต้องไม่ชี้ใบไหน · กันสภาพ "อนุมัติแล้วแต่
--    ไม่มีอะไรลงสมุด" (ซึ่งคือสภาพที่ทำให้คนกดอนุมัติซ้ำโดยสุจริต)
--
-- 2. **unique index บน `posted_txn_id`** — ใบในสมุดใบหนึ่งมีร่างชี้ถึงได้ไม่เกิน
--    หนึ่งร่าง · เป็นข้อจำกัดระดับดัชนี **จังหวะปลอมไม่ได้** (ไม่ใช่การอ่านก่อนเขียน)
--
-- 3. **trigger ตรึงแถวที่ตัดสินแล้ว** — `status <> 'pending'` = **แถวตาย**
--    แก้คอลัมน์ใดก็ไม่ได้อีก → "อนุมัติครั้งเดียวตลอดกาล" เป็นจริงข้ามธุรกรรม
--    และตอน `pending → approved` บังคับว่าใบที่ชี้ต้อง
--      (ก) เป็นใบที่ **post แล้ว** · (ข) ผู้ถือและหมวดตรงกับร่าง
--          (อ่านจากแถวในสมุด ไม่ใช่จากค่าที่ผู้เรียกส่ง · D-115)
--      (ค) **ถูกเขียนในธุรกรรมฐานข้อมูลเดียวกันกับการอนุมัติ**
--          (`write_txn_id = pg_current_xact_id()` ซึ่งระบบตั้งให้ ปลอมไม่ได้)
--          → การ "โพสต์ไว้ก่อนแล้วมาอัปเดตร่างทีหลัง" **ลงไม่ได้เลย**
--          ซึ่งเป็นการตัดรูปของการแข่งกันทิ้งที่โครงสร้าง ไม่ใช่ที่จังหวะ
--
-- 4. **`fn_approve_draft()` — ปากทางเดียวที่ล็อกแถวก่อนทำอะไร**
--    `select ... for update` แล้วจึงอ่านสถานะ **หลังได้ล็อก** → เซสชันที่สอง
--    ถูกบล็อกจริง ไม่ใช่เห็นสภาพเก่าแล้วเดินต่อ · โพสต์กับอัปเดตร่างอยู่ใน
--    ธุรกรรมเดียวโดยโครงสร้าง (ชั้นที่ 3 บังคับอีกชั้นว่าต้องเป็นอย่างนั้น)
--
-- **ทำไมต้องมีทั้งชั้น 3 และ 4**: ชั้น 4 ทำให้เส้นทางที่ถูกต้องเป็นอะตอมมิก
-- ชั้น 3 ทำให้เส้นทางที่ **ไม่** ผ่านปากทาง (UPDATE ตรงผ่าน API ซึ่ง policy ยอม)
-- ล้มเสียงดัง · มีชั้น 4 อย่างเดียวคือกันแค่คนที่ใช้ประตู (D-115 บอกว่าเท่ากับไม่กัน)
--
-- ------------------------------------------------------------
-- **ที่ยังไม่ครอบในไฟล์นี้ (บอกไว้ให้ชัด)**
--
-- เนื้อหาของ payload ที่โพสต์ **ยังไม่ถูกบังคับให้ตรงกับร่างทุกช่อง** —
-- ตรวจแค่ผู้ถือ · หมวด · และ "ธุรกรรมเดียวกัน" · ยอดเงินยังไม่เทียบเพราะ
-- `draft_entries.amount` เป็นยอดที่ผู้ใช้กรอก (เช่นเงินที่รับสุทธิ) ซึ่ง
-- **ไม่เท่ากับผลรวมเดบิตของใบ** ในหลายหมวด (ขายทรัพย์ · หักภาษี ณ ที่จ่าย ·
-- ล้างส่วนเกินทุน) การเทียบตรงๆ จะปฏิเสธใบที่ถูกต้อง
-- → การบังคับให้ร่างกับใบเล่าเรื่องเดียวกันทุกช่อง ต้องมาพร้อม **ประตูสร้างร่าง
--   ที่ตรวจเหมือน `fn_post_entry`** (C-3) ซึ่งเป็นงานถัดไป
--
-- ------------------------------------------------------------
-- ลำดับ: ต้องรันหลัง 20260917000002 (ตาราง) · 20261007000000 (`write_txn_id`) ·
--        20261008000011 (`fn_post_entry`) · guard หัวไฟล์ตรวจให้
--
-- idempotent: `add constraint` หลัง `drop constraint if exists` ·
--        `create unique index if not exists` · `create or replace function`
--
-- ย้อนกลับ (rollback):
--   -- drop trigger if exists trg_draft_post_once on sri_os.draft_entries;
--   -- drop function if exists sri_os.fn_approve_draft(uuid, jsonb);
--   -- drop function if exists sri_os.fn_assert_draft_post_once();
--   -- drop index if exists sri_os.draft_entries_posted_txn_uniq;
--   -- alter table sri_os.draft_entries drop constraint if exists draft_entries_posted_iff_approved;
--   ⚠ ถอดแล้ว **ผู้อนุมัติสองคนกดพร้อมกันลงสมุดสองใบจากร่างใบเดียวได้อีก**
--     (ยอดเกินจริงเท่าตัว · งบดุลยังดุลทั้งสองใบ จึงไม่มีอะไรฟ้อง)
-- ============================================================

set search_path = sri_os, public;

do $$
begin
  if to_regclass('sri_os.draft_entries') is null then
    raise exception 'ไม่มีตาราง draft_entries → ต้องรัน 20260917000002_ledger.sql ก่อนไฟล์นี้';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'sri_os' and table_name = 'transactions'
                    and column_name = 'write_txn_id') then
    raise exception 'ไม่มีคอลัมน์ transactions.write_txn_id → ต้องรัน 20261007000000_line_integrity_and_view_rls.sql ก่อนไฟล์นี้ (ด่าน "ธุรกรรมเดียวกัน" ต้องใช้)';
  end if;
  if to_regprocedure('sri_os.fn_post_entry(jsonb)') is null then
    raise exception 'ไม่มี fn_post_entry → ต้องรัน 20261008000011_post_entry_hardening.sql ก่อนไฟล์นี้';
  end if;
end $$;

-- ============================================================
-- 1 · CHECK · อนุมัติแล้ว ⟺ ชี้ใบในสมุด
-- ============================================================
do $$
declare n int; v text;
begin
  select count(*) into n from sri_os.draft_entries
   where (status = 'approved') <> (posted_txn_id is not null);
  if n > 0 then
    select string_agg(id::text, ', ') into v from sri_os.draft_entries
     where (status = 'approved') <> (posted_txn_id is not null);
    -- **ห้ามข้ามเงียบๆ** — ถ้ามีแถวที่ขัดกับกฎอยู่ก่อน ต้องรู้และตัดสินทีละแถว
    raise exception 'มีร่าง % แถวที่สถานะกับ posted_txn_id ไม่สอดคล้องกัน: % — ตัดสินทีละแถวก่อน (ร่างที่ approved แต่ไม่มีใบในสมุด = ยอดนั้นไม่เคยถูกลง · ร่างที่ยัง pending แต่ชี้ใบ = ลงไปแล้วแต่คิวยังค้าง)',
      n, v;
  end if;
end $$;

alter table draft_entries drop constraint if exists draft_entries_posted_iff_approved;
alter table draft_entries
  add constraint draft_entries_posted_iff_approved
  check ((status = 'approved') = (posted_txn_id is not null));

comment on constraint draft_entries_posted_iff_approved on draft_entries is
  'ร่างที่อนุมัติแล้วต้องชี้ใบในสมุด และร่างที่ยัง pending/rejected ต้องไม่ชี้ใบไหน · สภาพ "อนุมัติแล้วแต่ไม่มีอะไรลงสมุด" คือสภาพที่ทำให้คนกดอนุมัติซ้ำโดยสุจริต';

-- ============================================================
-- 2 · unique index · ใบในสมุดใบหนึ่งมีร่างชี้ถึงได้ไม่เกินหนึ่งร่าง
--     ข้อจำกัดระดับดัชนี = **จังหวะพร้อมกันปลอมไม่ได้** (ต่างจากการอ่านก่อนเขียน)
-- ============================================================
create unique index if not exists draft_entries_posted_txn_uniq
  on draft_entries (posted_txn_id)
  where posted_txn_id is not null;

comment on index sri_os.draft_entries_posted_txn_uniq is
  'ใบในสมุดใบหนึ่งถูกอ้างเป็นผลของร่างได้ไม่เกินหนึ่งร่าง · เป็นข้อจำกัดระดับดัชนีจึงกันจังหวะพร้อมกันได้จริง ไม่ใช่การอ่านแล้วเขียน (รูปเดียวกับ asset_drafts_applied_create_uniq)';

-- ============================================================
-- 3 · trigger · แถวที่ตัดสินแล้วคือแถวตาย · และการอนุมัติต้องอยู่ธุรกรรมเดียวกับการโพสต์
-- ============================================================
create or replace function fn_assert_draft_post_once() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  t record;
begin
  /**
   * (ก) **แถวที่ตัดสินแล้ว = แถวตาย** — อนุมัติหรือปฏิเสธไปแล้วแก้อะไรไม่ได้อีก
   * ทำให้ "ร่างหนึ่งใบลงได้ครั้งเดียวตลอดกาล" เป็นจริง **ข้ามธุรกรรม**
   * (ถ้ายอมให้แก้กลับเป็น pending ได้ การกดสองครั้งก็กลับมาได้ทันที)
   */
  if old.status <> 'pending' then
    if new is distinct from old then
      raise exception 'ร่าง % ถูก%ไปแล้ว (เมื่อ %) จึงแก้อะไรไม่ได้อีก — ร่างที่ตัดสินแล้วคือร่างตาย · ถ้าลงผิด ให้**กลับรายการใบในสมุด**แล้วคีย์ร่างใหม่ (กฎเหล็กข้อ 1: ห้ามแก้ของที่ post แล้ว) ไม่ใช่ปลุกร่างเดิมกลับมาอนุมัติซ้ำ',
        old.id,
        case old.status when 'approved' then 'อนุมัติ' else 'ปฏิเสธ' end,
        coalesce(old.reviewed_at::text, '-');
    end if;
    return new;
  end if;

  -- ยังไม่เปลี่ยนสถานะ (แก้เนื้อร่างตอนยัง pending) → ไม่ใช่เรื่องของด่านนี้
  if new.status = 'pending' then
    if new.posted_txn_id is not null then
      raise exception 'ร่าง % ยังไม่ได้อนุมัติ แต่ชี้ใบในสมุด % — ใบที่ลงแล้วโดยที่ร่างยัง pending แปลว่าคิวอนุมัติยังค้างอยู่ทั้งที่เงินลงไปแล้ว แล้วจะมีคนกดอนุมัติซ้ำ',
        old.id, new.posted_txn_id;
    end if;
    return new;
  end if;

  if new.status = 'rejected' then
    return new;   -- CHECK บังคับว่า posted_txn_id ต้องเป็น null อยู่แล้ว
  end if;

  -- ---------- pending → approved ----------
  if new.posted_txn_id is null then
    raise exception 'อนุมัติร่าง % โดยไม่มีใบในสมุดไม่ได้ — การอนุมัติคือการลงสมุด ต้องลงใบแล้วชี้ใบนั้นในคำสั่งเดียวกัน (ใช้ sri_os.fn_approve_draft)',
      old.id;
  end if;

  select tx.owner_id, tx.txn_type_code, tx.status::text as st, tx.write_txn_id
    into t
    from sri_os.transactions tx where tx.id = new.posted_txn_id;
  if t is null then
    raise exception 'ร่าง % ชี้ใบ % ที่ไม่มีอยู่ในสมุด', old.id, new.posted_txn_id;
  end if;

  if t.st <> 'posted' then
    raise exception 'ร่าง % ชี้ใบ % ที่สถานะ "%" ไม่ใช่ posted — ร่างที่อนุมัติแล้วต้องมีเงินลงสมุดจริง',
      old.id, new.posted_txn_id, t.st;
  end if;

  /**
   * (ข) ผู้ถือและหมวดต้องตรงกับร่าง — **อ่านจากแถวในสมุด** ไม่ใช่จากค่าที่ผู้เรียกส่ง
   * (D-115) · กันการอนุมัติร่างของผู้ถือหนึ่งโดยชี้ใบของผู้ถืออื่น
   */
  if t.owner_id <> old.owner_id then
    raise exception 'ร่าง % เป็นของผู้ถือ % แต่ชี้ใบในสมุดของผู้ถือ % — อนุมัติร่างแล้วไปชี้ใบของคนอื่นไม่ได้',
      old.id, old.owner_id, t.owner_id;
  end if;
  if t.txn_type_code <> old.txn_type_code then
    raise exception 'ร่าง % เป็นหมวด "%" แต่ชี้ใบในสมุดหมวด "%" — คู่บัญชีของสองหมวดนี้ไม่เหมือนกัน ร่างกับใบต้องเล่าเรื่องเดียวกัน',
      old.id, old.txn_type_code, t.txn_type_code;
  end if;

  /**
   * (ค) **ใบต้องถูกเขียนในธุรกรรมฐานข้อมูลเดียวกันกับการอนุมัติ**
   *
   * `write_txn_id` ระบบตั้งให้ด้วย `pg_current_xact_id()` (ค่าปริยายของคอลัมน์)
   * **ผู้เรียกปลอมไม่ได้** — และข้อนี้ตัดรูปของการแข่งกันทิ้งที่โครงสร้าง:
   * เส้นทาง "โพสต์ก่อน แล้วค่อยมาอัปเดตร่างในคำสั่งถัดไป" ซึ่งเป็นรูปที่
   * ผู้อนุมัติสองคนแข่งกันได้ **ลงไม่ได้เลย** ไม่ใช่แค่แพ้จังหวะบางครั้ง
   * (D-116: ต้องมีด่านที่ตรวจ **ผลลัพธ์ปลายทาง** ไม่ใช่ตรวจแต่ขั้นตอน)
   */
  if t.write_txn_id is distinct from pg_current_xact_id() then
    raise exception 'ใบ % ถูกลงสมุดในธุรกรรมอื่น ไม่ใช่ธุรกรรมเดียวกับการอนุมัติร่าง % — การลงสมุดกับการอนุมัติต้องเป็นคำสั่งเดียว (ใช้ sri_os.fn_approve_draft) · ถ้าแยกสองคำสั่ง ผู้อนุมัติสองคนที่กดพร้อมกันจะลงสมุดสองใบจากร่างใบเดียว = ยอดเกินจริงเท่าตัว โดยที่งบดุลยังดุลทั้งสองใบ',
      new.posted_txn_id, old.id;
  end if;

  return new;
end $fn$;

comment on function fn_assert_draft_post_once() is
  'C-1 · ร่างที่ตัดสินแล้วคือแถวตาย (แก้อะไรไม่ได้อีก) · pending → approved ต้องชี้ใบที่ post แล้ว ผู้ถือ/หมวดตรงกับร่าง (อ่านจากสมุด ไม่ใช่จากค่าที่ส่งมา · D-115) และ **ใบนั้นต้องถูกเขียนในธุรกรรมเดียวกับการอนุมัติ** (write_txn_id = pg_current_xact_id() ซึ่งระบบตั้งให้) → เส้นทาง "โพสต์ก่อนแล้วอัปเดตร่างทีหลัง" ที่ทำให้สองคนลงสมุดสองใบจากร่างเดียว ลงไม่ได้เลย';

revoke all on function fn_assert_draft_post_once() from public;
do $$ begin execute 'revoke all on function sri_os.fn_assert_draft_post_once() from anon, authenticated'; end $$;

drop trigger if exists trg_draft_post_once on draft_entries;
create trigger trg_draft_post_once
  before update on draft_entries
  for each row execute function fn_assert_draft_post_once();

-- ============================================================
-- 4 · ปากทางเดียวของการอนุมัติ — **ล็อกแถวก่อนอ่านสถานะ**
--
-- `security invoker` โดยตั้งใจ (รูปเดียวกับ `fn_post_entry` / `fn_reimport_opening`):
--   ทุกการเขียนไปผ่าน RLS ด้วยสิทธิ์ของผู้เรียกจริง · definer จะกลายเป็นทางข้ามสิทธิ์
-- ============================================================
create or replace function fn_approve_draft(p_draft uuid, p_payload jsonb) returns jsonb
language plpgsql set search_path = sri_os, public as $fn$
declare
  d      record;
  v_out  jsonb;
  v_txn  uuid;
begin
  if p_draft is null then
    raise exception 'ต้องระบุร่างที่จะอนุมัติ';
  end if;

  /**
   * **ล็อกแถวก่อนทำอะไรทั้งนั้น** — `for update` แล้วจึงอ่านสถานะ
   *
   * เซสชันที่สองจะ **ถูกบล็อกที่บรรทัดนี้** จนเซสชันแรก commit แล้วจึงอ่านสถานะ
   * ใหม่ (READ COMMITTED อ่านแถวรุ่นล่าสุดหลังได้ล็อก) → เห็น `approved`
   * แล้วปฏิเสธ · ต่างจากการอ่านก่อนแล้วเขียน ซึ่งทั้งสองเซสชันเห็น `pending`
   * พร้อมกันแล้วเดินต่อทั้งคู่ (นี่คือรูปที่แพ้สามชั้นติดในด่านล้างยอดเกิน)
   *
   * `nowait`/`skip locked` **ไม่ใช้** โดยตั้งใจ: เราต้องการให้เซสชันที่สอง *รอ*
   * แล้วเห็นความจริงหลังจากนั้น ไม่ใช่ล้มทันทีโดยยังไม่รู้ผลของเซสชันแรก
   */
  select * into d from draft_entries where id = p_draft for update;
  if d.id is null then
    raise exception 'ไม่พบร่าง % (หรือไม่มีสิทธิ์เห็นร่างนี้)', p_draft;
  end if;

  if d.status <> 'pending' then
    raise exception 'ร่าง % ถูก%ไปแล้ว%s — อนุมัติซ้ำไม่ได้ · ถ้าต้องแก้ ให้กลับรายการใบในสมุดแล้วคีย์ร่างใหม่',
      p_draft,
      case d.status when 'approved' then 'อนุมัติ' else 'ปฏิเสธ' end,
      case when d.posted_txn_id is not null
           then format(' (ลงสมุดเป็นใบ %s)', d.posted_txn_id) else '' end;
  end if;

  -- ลงสมุดในธุรกรรมเดียวกัน (ประตูเดิมตรวจคู่บัญชี/สิทธิ์/ด่านเงินทั้งชุดให้)
  v_out := fn_post_entry(p_payload);

  if coalesce((v_out ->> 'replayed')::boolean, false) then
    /**
     * ประตูมองว่าเป็นการกดซ้ำ → **ปฏิเสธทั้งคำสั่ง** ไม่เดินต่อ (D-116)
     * ถ้าเดินต่อ เราจะผูกร่างนี้กับใบของใครก็ไม่รู้ที่ลงไว้ก่อนหน้า
     */
    raise exception 'ประตูลงรายการถือว่าคำขอนี้เป็นการกดซ้ำของใบที่ลงไปแล้ว — ไม่ผูกร่าง % กับใบนั้น เพราะใบนั้นอาจเป็นผลของร่างอื่น · ตรวจว่ากดอนุมัติซ้ำหรือไม่',
      p_draft;
  end if;

  v_txn := ((v_out -> 'transaction_ids') ->> 0)::uuid;
  if v_txn is null then
    raise exception 'ประตูลงรายการไม่คืนเลขใบมา — ไม่ผูกร่าง % กับอะไรทั้งนั้น', p_draft;
  end if;

  update draft_entries
     set status = 'approved',
         posted_txn_id = v_txn,
         reviewed_by = auth.uid(),
         reviewed_at = now()
   where id = p_draft;

  return jsonb_build_object(
    'draft_id', p_draft,
    'posted_txn_id', v_txn,
    'transaction_ids', v_out -> 'transaction_ids');
end $fn$;

comment on function fn_approve_draft(uuid, jsonb) is
  'C-1 · ปากทางเดียวของการอนุมัติร่าง: **ล็อกแถวร่างด้วย for update ก่อนอ่านสถานะ** แล้วลงสมุดและอัปเดตร่างในธุรกรรมเดียว → ผู้อนุมัติสองคนที่กดพร้อมกัน คนที่สองถูกบล็อกจนคนแรก commit แล้วเห็น approved และถูกปฏิเสธ (ไม่ใช่เห็น pending พร้อมกันแล้วลงสมุดสองใบ) · security invoker → RLS เป็นด่านเดียว · ประตูตอบว่า replayed = ปฏิเสธทั้งคำสั่ง (D-116)';

revoke all on function fn_approve_draft(uuid, jsonb) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_approve_draft(uuid, jsonb) from anon';
  execute 'grant execute on function sri_os.fn_approve_draft(uuid, jsonb) to authenticated';
end $$;

-- ============================================================
-- 5 · guard ท้ายไฟล์
-- ============================================================
do $$
declare v text;
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'draft_entries_posted_iff_approved') then
    raise exception 'ไม่มี CHECK draft_entries_posted_iff_approved';
  end if;
  if not exists (select 1 from pg_class where relname = 'draft_entries_posted_txn_uniq') then
    raise exception 'ไม่มี unique index draft_entries_posted_txn_uniq';
  end if;
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.draft_entries'::regclass
                    and g.tgname = 'trg_draft_post_once' and not g.tgisinternal) then
    raise exception 'ไม่มี trigger trg_draft_post_once';
  end if;

  -- ปากทางต้องเป็น invoker (definer = ทางข้ามสิทธิ์ทั้งชุด)
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'sri_os' and p.proname = 'fn_approve_draft' and p.prosecdef) then
    raise exception 'fn_approve_draft เป็น security definer — ต้องเป็น invoker เพื่อให้ RLS บังคับจริง';
  end if;

  -- **ต้องล็อกแถว ไม่ใช่อ่านแล้วเขียน** (บทเรียนจากด่านล้างยอดเกิน)
  v := pg_get_functiondef('sri_os.fn_approve_draft(uuid, jsonb)'::regprocedure);
  if v !~ 'for update' then
    raise exception 'fn_approve_draft ไม่ได้ล็อกแถวร่างด้วย for update — เส้นทางอ่านก่อนเขียนแพ้จังหวะพร้อมกันทุกครั้ง';
  end if;
  if v !~ 'fn_post_entry' then
    raise exception 'fn_approve_draft ไม่ได้ลงสมุดผ่าน fn_post_entry';
  end if;
  if v !~ 'replayed' then
    raise exception 'fn_approve_draft ไม่ได้ตรวจคำตอบ replayed ของประตู — ร่างจะถูกผูกกับใบของร่างอื่นได้ (D-116)';
  end if;

  -- ด่าน "ธุรกรรมเดียวกัน" ต้องอยู่ใน trigger จริง ไม่ใช่หวังว่าปากทางจะทำให้
  v := pg_get_functiondef('sri_os.fn_assert_draft_post_once()'::regprocedure);
  if v !~ 'pg_current_xact_id' then
    raise exception 'trigger ไม่ได้บังคับว่าใบต้องถูกเขียนในธุรกรรมเดียวกับการอนุมัติ — UPDATE ตรงผ่าน API จะยังแข่งกันได้';
  end if;

  raise notice 'ok · ร่างหนึ่งใบลงสมุดได้ครั้งเดียวตลอดกาล: CHECK + unique index + trigger ตรึงแถวที่ตัดสินแล้ว + ปากทางที่ล็อกแถวก่อนอ่าน';
end $$;
