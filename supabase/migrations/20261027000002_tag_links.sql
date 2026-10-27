-- ============================================================
-- SRI OS · **ลิงก์ tag ↔ ใบในสมุด** (ADR 0002 หัวข้อ 3.3 — หัวใจของเรื่องนี้)
--
-- ตารางนี้คือที่เดียวที่ "tag ของกองกลาง" มาเจอ "ใบของผู้ถือ" → จึงเป็นที่เดียว
-- ในเรื่อง tag ที่กฎเหล็กข้อ 1 และข้อ 3 บังคับเต็มรูปแบบ
--
-- ------------------------------------------------------------
-- **สิ่งที่ไฟล์นี้ทำให้เป็นความจริงเดียว**
--
-- 1. **ทุกแถวมี `owner_id` และเป็นสำเนาจากใบ** (กฎเหล็กข้อ 3)
--    trigger **อ่านผู้ถือจาก `transactions` เอง** ไม่เชื่อค่าที่ส่งมา
--    (บทเรียนข้อ 2 ของ mace-windu: อย่าเชื่อฟิลด์ที่ผู้ใช้เว้นได้)
--    ส่งมาไม่ตรง = **ปฏิเสธ** ไม่ใช่ทับให้เงียบๆ (ทับเงียบๆ ซ่อนบั๊กของผู้เรียก)
--    แก้ย้อนหลังไม่ได้ · 1 แถวลิงก์ = 1 ใบ = 1 ผู้ถือ (บทเรียนข้อ 4)
--
-- 2. **ห้าม DELETE ทุกทาง** (กฎเหล็กข้อ 1) — ถอด tag = UPDATE เติม
--    `untagged_at/by/untag_reason` และ **เหตุผลว่างไม่ได้** (เงื่อนไขสองทาง
--    เหมือน `void_reason` ของ D-098) · ถ้าใช้ tag ตรวจย้อนหลังแล้วถอดได้เงียบๆ
--    ก็เชื่อผลการตรวจไม่ได้เลย · ไม่มี policy DELETE + trigger กันถึงเจ้าของฐานข้อมูล
--
-- 3. `tagged_by` มาจาก **`auth.uid()` ที่ trigger ตั้งให้** (แพทเทิร์น
--    `fn_txn_system_columns`) · ส่งชื่อคนอื่นมา = ปฏิเสธ → โยนความผิดให้คนอื่นไม่ได้
--
-- 4. **ห้ามมีคอลัมน์จำนวนเงิน/สัดส่วนในตารางนี้เด็ดขาด** (ADR 0002 หัวข้อ 4.3
--    ทางเลือก C ถูกปฏิเสธ **เชิงโครงสร้าง**) · guard ท้ายไฟล์ไล่
--    `information_schema.columns` แล้วพังถ้าเจอ `numeric/money/double/real`
--    น้ำหนัก 60/40 ของ ADR 0003 อยู่ใน **ตารางแยก** `tag_allocations` (ชิ้น A2)
--    เหตุผล: ถ้าน้ำหนักมาอยู่ที่นี่ tag จะกลายเป็นตัวเลขที่เข้าสู่รายงานเงิน
--    และทุก view ที่ join ตารางนี้จะหยิบตัวคูณไปใช้ได้โดยไม่มีใครตัดสิน
--
-- 5. trigger ของตารางนี้ **ห้ามเขียน `transactions` / `transaction_lines`**
--    (ADR 0002 หัวข้อ 5 ข้อ 4-5) · guard ท้ายไฟล์ไล่ `prosrc` ของ trigger function
--    ทุกตัวของตารางนี้ แล้วพังถ้าเจอคำสั่งเขียนสองตารางนั้น
--    → **ติด tag เปลี่ยนตัวเลขในงบไม่ได้เชิงโครงสร้าง** ไม่ใช่เพราะวันนี้ไม่มีใครเขียน
--
-- 6. `tag_link_single_uq` — คานของทางเลือก B: partial unique index ที่ predicate
--    อ่านจาก **สำเนาคอนฟิก** (`single_per_txn`) ไม่ใช่จากชื่อชนิดที่พิมพ์ในโค้ด
--    วันนี้ `single_per_txn = false` ทุกแถว → index มีอยู่แต่ไม่กันอะไร
--    (ตรงตามคำสั่ง 26/10 "ติดได้หลายอัน") · วันที่พลิกคอนฟิก migration backfill
--    จะพังทันทีถ้ามีใบที่ติด project เกินหนึ่งอัน — **นั่นคือพฤติกรรมที่ถูก**
--
-- ------------------------------------------------------------
-- **งวดที่ปิดแล้ว** (ADR 0002 หัวข้อ 5 ข้อ 3)
--   default = ยังติด/ถอด tag ได้ (tag ไม่ใช่ตัวเลข ไม่กระทบงบที่ล็อก) แต่
--   **ต้องมีเหตุผลทั้งขาติดและขาถอด** · สวิตช์อยู่ `settings` key
--   `tags.lock_with_period` (default false) ตามกฎเหล็กข้อ 5 — ไม่ hard-code
--   ค่าที่สะกดผิด/ไม่ใช่ boolean = **ปฏิเสธ** ไม่ใช่เดาว่าปิด (ปลอดภัยไว้ก่อน ·
--   แพทเทิร์นเดียวกับสวิตช์ของ 20261025000018)
--
-- **สิ่งที่ไฟล์นี้ไม่ทำ** (ชิ้นถัดไปตาม ADR 0002 หัวข้อ 6)
--   `fn_post_entry(tag_ids)` · `fn_tag_transaction()` / `fn_untag_transaction()` ·
--   `v_ledger_tagged` · `v_tag_touch_totals` · `v_tag_coverage` ·
--   `fn_assert_tag_read_path()` — ทั้งหมดอยู่ในชิ้น 3 · ไฟล์นี้วางของที่พวกนั้นยืนบน
--
-- ลำดับ: **ต้องรันหลัง 20261027000001** (`tags` · `tag_kinds` · สิทธิ์) ·
--   **หลัง 20260917000002** (`transactions` · `period_closes`) ·
--   **หลัง 20261020000000** (ด่านคอลัมน์)
--   → วางต่อท้าย `20261027000001_tag_catalog.sql` ก่อน `20261027000003_tag_draft_links.sql`
--
-- idempotent: create table if not exists · add constraint แบบ drop if exists ก่อน ·
--   create index if not exists · create or replace function ·
--   drop policy/trigger if exists ก่อน create · insert ... on conflict do nothing
--
-- ย้อนกลับ (rollback) — เรียงจากหลังมาหน้า:
--   -- delete from sri_os.column_exposure       where table_name = 'transaction_tags';
--   -- delete from sri_os.column_exposure_tables where table_name = 'transaction_tags';
--   -- select sri_os.fn_apply_column_exposure();
--   -- ** ก่อนย้อน: dump ตารางนี้ทั้งตาราง ** (ADR 0002 หัวข้อ 7) —
--   --   ข้อมูลที่ติดไว้หายถาวรและการกรองย้อนหลังหายไปทั้งฟีเจอร์
--   -- drop table if exists sri_os.transaction_tags;
--   -- drop function if exists sri_os.fn_tag_link_system_columns(), sri_os.fn_tag_link_no_delete();
--   -- delete from sri_os.settings where key = 'tags.lock_with_period';
--   -- drop index if exists sri_os.transactions_contact_date_idx;
--   -- ไม่มีตัวเลขในงบเปลี่ยนแม้บาทเดียวจากการย้อน (tag ไม่ใช่เงิน) แต่ร่องรอย
--   --   "ใครติด/ถอด tag อะไรเพราะอะไร" หายไปด้วย → ตรวจย้อนหลังตามโจทย์ไม่ได้
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 0 · pre-flight
-- ============================================================
do $$
begin
  if to_regclass('sri_os.tags') is null or to_regclass('sri_os.tag_kinds') is null then
    raise exception 'ไม่มีแค็ตตาล็อก tag → ต้องรัน 20261027000001_tag_catalog.sql ก่อน (ลิงก์คัดลอกชนิดและคอนฟิกมาจากที่นั่น)';
  end if;
  if to_regclass('sri_os.transactions') is null or to_regclass('sri_os.period_closes') is null then
    raise exception 'ไม่มี transactions/period_closes → ต้องรัน 20260917000002_ledger.sql ก่อน';
  end if;
  if not exists (select 1 from sri_os.permissions where key = 'tag.assign') then
    raise exception 'ไม่มีสิทธิ์ tag.assign ในตารางสิทธิ์ → 20261027000001 ไม่ได้ลงหรือถูกย้อน (policy อ่านสิทธิ์จากตาราง)';
  end if;
  if to_regprocedure('sri_os.fn_can_read_txn(uuid,uuid,uuid)') is null
     or to_regprocedure('sri_os.fn_can_see_owner(uuid)') is null then
    raise exception 'ไม่มี fn_can_read_txn/fn_can_see_owner → ต้องรัน 20261006190000 ก่อน (ขอบเขตของลิงก์ต้องใช้ฟังก์ชันตัวเดียวกับสมุด ห้ามเขียนกฎขอบเขตซ้ำ)';
  end if;
  if to_regclass('sri_os.column_exposure_tables') is null
     or to_regprocedure('sri_os.fn_apply_column_exposure()') is null then
    raise exception 'ไม่มีทะเบียนด่านคอลัมน์ → ต้องรัน 20261020000000 ก่อน (D-089)';
  end if;
end $$;

-- ============================================================
-- 1 · สวิตช์ "งวดปิดแล้วล็อกการติด tag ด้วยหรือไม่" (กฎเหล็กข้อ 5)
-- ============================================================
insert into settings (key, value) values ('tags.lock_with_period', 'false'::jsonb)
on conflict (key) do nothing;

-- ============================================================
-- 2 · ตารางลิงก์
-- ============================================================
create table if not exists transaction_tags (
  /** surrogate เพราะต้องรองรับ "ถอดแล้วติดใหม่" โดยเก็บของเก่าไว้ทั้งแถว */
  id             uuid primary key default gen_random_uuid(),
  /** on delete restrict — ไม่ cascade: ลบใบแล้วให้ร่องรอยหายไปด้วยไม่ได้ */
  transaction_id uuid not null references transactions(id) on delete restrict,
  /** on delete restrict — tag ที่ถูกใช้แล้วลบไม่ออก (คู่กับ trigger ของแค็ตตาล็อก) */
  tag_id         uuid not null references tags(id) on delete restrict,
  /** **สำเนาจากใบ** · trigger บังคับ = transactions.owner_id · แก้ไม่ได้ (กฎเหล็กข้อ 3) */
  owner_id       uuid not null references owners(id),
  /** สำเนาจาก tags.kind · trigger บังคับให้ตรง (ใช้ใน predicate ของ index) */
  tag_kind       text not null references tag_kinds(key) on update cascade,
  /** สำเนาของ `not tag_kinds.allows_multi` · วันนี้ = false ทุกแถว */
  single_per_txn boolean not null,
  tagged_at      timestamptz not null default now(),
  tagged_by      uuid not null references app_users(id),
  /** เหตุผลตอนติด — ไม่บังคับ **ยกเว้นงวดที่ปิดแล้ว** (ADR 0002 หัวข้อ 5 ข้อ 3) */
  tag_note       text,
  untagged_at    timestamptz,
  untagged_by    uuid references app_users(id),
  untag_reason   text
);

comment on table transaction_tags is
  'ลิงก์ tag ↔ ใบในสมุด (ADR 0002 หัวข้อ 3.3) · **append-only + ปิดด้วยร่องรอย** ไม่มี DELETE · owner_id เป็นสำเนาจากใบที่ trigger บังคับให้ตรงเสมอ (กฎเหล็กข้อ 3) · tagged_by มาจาก auth.uid() ปลอมไม่ได้ · **ห้ามมีคอลัมน์จำนวนเงิน/สัดส่วน** (น้ำหนักของ ADR 0003 อยู่ใน tag_allocations ตารางแยก) · ยอดต่อ tag เป็น touch บวกข้าม tag ไม่ได้';
comment on column transaction_tags.owner_id is
  'สำเนาของ transactions.owner_id · trigger อ่านจากใบเองไม่เชื่อค่าที่ส่งมา และปฏิเสธถ้าส่งมาไม่ตรง · มีไว้เพื่อให้ RLS/รายงานกรอง Entity ได้โดยไม่ต้อง join ใบ (กฎเหล็กข้อ 3)';
comment on column transaction_tags.untag_reason is
  'เหตุผลตอนถอด **บังคับ** (btrim <> '''') เหมือน void_reason ของ D-098 · ถอด tag ได้เงียบๆ = ผลการตรวจย้อนหลังด้วย tag เชื่อไม่ได้';
comment on column transaction_tags.single_per_txn is
  'สำเนาของ not tag_kinds.allows_multi ณ เวลาที่ติด · เป็น predicate ของ tag_link_single_uq → "project ติดได้อันเดียว" บังคับได้ด้วยการพลิกคอนฟิก + migration backfill ไม่ต้องรื้อ schema (ADR 0002 หัวข้อ 4.3 ทางเลือก B)';

-- ---------- เงื่อนไขสองทาง: ปิดแล้วต้องครบสามช่อง · ยังไม่ปิดต้องว่างทั้งสาม ----------
alter table transaction_tags drop constraint if exists tag_link_close_both_ways;
alter table transaction_tags add constraint tag_link_close_both_ways check (
      (untagged_at is not null) = (untagged_by is not null)
  and (untagged_at is not null) = (untag_reason is not null and btrim(untag_reason) <> '')
);
comment on constraint tag_link_close_both_ways on transaction_tags is
  'ปิดครึ่งเดียวไม่ได้: มีเวลาแต่ไม่มีคน/ไม่มีเหตุผล = ร่องรอยที่อธิบายอะไรไม่ได้ · และแปะเหตุผลไว้บนลิงก์ที่ยังใช้อยู่ก็ไม่ได้ (ดูเหมือนถอดแล้วแต่ยังโผล่ในรายงาน)';

alter table transaction_tags drop constraint if exists tag_link_close_order;
alter table transaction_tags add constraint tag_link_close_order
  check (untagged_at is null or untagged_at >= tagged_at);

-- ---------- index ตาม ADR 0002 หัวข้อ 3.3 ----------
-- ติด tag เดิมซ้ำบนใบเดียวไม่ได้ (เฉพาะที่ยังใช้อยู่ → ถอดแล้วติดใหม่ได้)
create unique index if not exists tag_link_active_uq
  on transaction_tags (transaction_id, tag_id) where untagged_at is null;

-- คานของทางเลือก B · predicate อ่านจากสำเนาคอนฟิก ไม่ใช่จากชื่อชนิดในโค้ด
create unique index if not exists tag_link_single_uq
  on transaction_tags (transaction_id, tag_kind)
  where untagged_at is null and single_per_txn;

create index if not exists tag_link_by_tag
  on transaction_tags (tag_id, owner_id) where untagged_at is null;
create index if not exists tag_link_by_owner
  on transaction_tags (owner_id, tag_id) where untagged_at is null;
create index if not exists tag_link_by_txn
  on transaction_tags (transaction_id) where untagged_at is null;

-- ตัวกรองครบชุดของ ADR 0002 หัวข้อ 5 ต้องมี index บน `transactions` ด้วย
-- **ตรวจก่อนแล้วว่ามีอะไรอยู่** (20260917000002): `transactions_owner_date_idx`
-- (owner_id, doc_date desc) มีแล้ว · `transactions_cash_date_idx` (cash_date) มีแล้ว ·
-- `transactions_asset_idx` (asset_id) มีแล้ว → **ไม่สร้างซ้ำ**
-- ที่ยังไม่มีคือคู่ (contact_id, doc_date) ซึ่งตัวกรอง "รับ/จ่ายใคร + ช่วงวันที่" ต้องใช้
create index if not exists transactions_contact_date_idx on transactions (contact_id, doc_date);

-- ============================================================
-- 3 · ด่านของลิงก์ — สำเนาต้องตรงกับต้นฉบับเสมอ และปลอมคนทำไม่ได้
--
-- **security definer** โดยเจตนา: ต้องอ่านผู้ถือ/สถานะของใบจาก `transactions`
-- **ตัวจริง** ไม่ใช่จากสิ่งที่ผู้เรียกมองเห็น (ถ้าเป็น invoker แล้วผู้เรียกมองใบ
-- ไม่เห็น การ select จะได้ 0 แถว แล้วเราจะตัดสินไม่ได้ว่า "ไม่มีใบ" หรือ
-- "มีแต่มองไม่เห็น" → ข้อมูลไม่ครบต้องปฏิเสธ แต่ต้องปฏิเสธด้วยเหตุผลที่ถูก)
-- **ไม่เรียก `fn_can()` หรือฟังก์ชันตรวจสิทธิ์ใดๆ** — กฎร่องรอยต้องเท่ากันทุกตำแหน่ง
-- และปิดจากหน้า Settings ไม่ได้ (หลักเดียวกับ 20261008000004) · ใครติดได้ = RLS ตัดสิน
-- ============================================================
create or replace function fn_tag_link_system_columns() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_uid      uuid := auth.uid();
  v_owner    uuid;
  v_status   text;
  v_doc_date date;
  v_kind     text;
  v_active   boolean;
  v_multi    boolean;
  v_lock     jsonb;
  v_closed   boolean;
begin
  -- ======================= INSERT =======================
  if tg_op = 'INSERT' then
    -- ติดลิงก์ที่ "ถอดแล้ว" เข้ามาตรงๆ ไม่ได้ (= ปลอมร่องรอยทั้งก้อน)
    if new.untagged_at is not null or new.untagged_by is not null
       or new.untag_reason is not null then
      raise exception 'สร้างลิงก์ tag ที่ถอดไว้แล้วตรงๆ ไม่ได้ · ร่องรอยการถอดต้องเกิดจากการถอดจริงบนลิงก์ที่มีอยู่ (UPDATE) ไม่ใช่เขียนประวัติย้อนหลังเข้ามาทั้งก้อน';
    end if;

    -- (ก) ผู้ถือ + สถานะของใบ — **อ่านจากใบเอง** ไม่เชื่อค่าที่ส่งมา
    select t.owner_id, t.status::text, t.doc_date
      into v_owner, v_status, v_doc_date
      from sri_os.transactions t where t.id = new.transaction_id;
    if v_owner is null then
      raise exception 'ไม่มีใบ id % ในสมุด → ติด tag ไม่ได้', new.transaction_id;
    end if;
    if new.owner_id is not null and new.owner_id <> v_owner then
      raise exception 'ผู้ถือของลิงก์ (%) ไม่ตรงกับผู้ถือของใบ (%) · owner_id ของแถวนี้เป็น **สำเนาจากใบ** (กฎเหล็กข้อ 3) ระบบอ่านจากใบเองและไม่ทับค่าที่ส่งมาเงียบๆ — ส่งมาไม่ตรงคือสัญญาณว่าผู้เรียกเข้าใจผิดว่าใบนี้เป็นของใคร',
        new.owner_id, v_owner;
    end if;
    new.owner_id := v_owner;

    -- ใบที่ยกเลิกแล้วติด tag ใหม่ไม่ได้ (ลิงก์เก่าของมันยังอยู่เป็นร่องรอย
    -- แต่โผล่ในงบไม่ได้เพราะ v_ledger_posted กรอง status แบบ allow-list)
    if v_status <> 'posted' then
      raise exception 'ใบ % สถานะ % → ติด tag ใหม่ไม่ได้ · ลิงก์ที่ติดไว้ก่อนยกเลิกยังอยู่เป็นร่องรอย (ไม่ถูกลบ) แต่การเพิ่ม tag ให้ใบที่ยกเลิกแล้วคือการแก้ของที่จบแล้ว',
        new.transaction_id, v_status;
    end if;

    -- (ข) ชนิด + คอนฟิก — สำเนาจากแค็ตตาล็อก
    select t.kind, t.is_active into v_kind, v_active
      from sri_os.tags t where t.id = new.tag_id;
    if v_kind is null then
      raise exception 'ไม่มี tag id % ในแค็ตตาล็อก → ติดไม่ได้ · tag ต้องตั้งไว้ก่อนแล้วเลือก (คำสั่ง 26/10) พิมพ์สร้างจากฟอร์มรายการไม่ได้', new.tag_id;
    end if;
    if not v_active then
      raise exception 'tag นี้ปิดใช้งานแล้ว → ติดใหม่ไม่ได้ (ลิงก์เก่าไม่ถูกแตะ และยังกรองย้อนหลังเจอ) · ถ้าต้องใช้ต่อ ให้เปิดคืนที่หน้าตั้งค่าด้วยสิทธิ์ tag.catalog';
    end if;
    if new.tag_kind is not null and new.tag_kind <> v_kind then
      raise exception 'ชนิดที่ส่งมา (%) ไม่ตรงกับชนิดของ tag ในแค็ตตาล็อก (%) · คอลัมน์นี้เป็นสำเนา ห้ามส่งค่าที่ขัดกับต้นฉบับ (predicate ของ index อ่านจากคอลัมน์นี้ ถ้าเพี้ยน คานที่ควรกันจะไม่กัน)',
        new.tag_kind, v_kind;
    end if;
    new.tag_kind := v_kind;

    select k.allows_multi into v_multi from sri_os.tag_kinds k where k.key = v_kind;
    if v_multi is null then
      raise exception 'ชนิด tag % ไม่มีในคอนฟิก (tag_kinds) → ตัดสินไม่ได้ว่าติดได้กี่อันต่อใบ', v_kind;
    end if;
    if new.single_per_txn is not null and new.single_per_txn <> (not v_multi) then
      raise exception 'single_per_txn ที่ส่งมา (%) ไม่ตรงกับคอนฟิกของชนิด % (allows_multi = %) · ค่านี้เป็นสำเนาของคอนฟิก ส่งค่าเองได้เท่ากับปลดคานที่กัน "project ติดได้อันเดียว" ต่อแถว',
        new.single_per_txn, v_kind, v_multi;
    end if;
    new.single_per_txn := not v_multi;

    -- (ค) คนติดและเวลา — ตั้งจาก auth.uid() ปลอมไม่ได้
    new.tagged_at := now();
    if v_uid is not null then
      if new.tagged_by is not null and new.tagged_by <> v_uid then
        raise exception 'tagged_by (%) ไม่ใช่ผู้ใช้ที่กำลังติด tag (%) · บันทึกว่าคนอื่นเป็นคนติดไม่ได้',
          new.tagged_by, v_uid;
      end if;
      new.tagged_by := v_uid;
    end if;
    -- v_uid เป็น null ได้เฉพาะงานระบบ/migration ซึ่งยังต้องชี้ตัวคนที่รับผิดชอบ
    -- ผ่าน NOT NULL + FK app_users (เดาว่าใครทำแย่กว่าบอกว่าเป็นงานระบบของใคร)

    -- (ง) งวดที่ปิดแล้ว
    v_closed := exists (
      select 1 from sri_os.period_closes p
       where p.owner_id = v_owner
         and p.period = date_trunc('month', v_doc_date)::date);
    if v_closed then
      select s.value into v_lock from sri_os.settings s where s.key = 'tags.lock_with_period';
      if v_lock is null or jsonb_typeof(v_lock) <> 'boolean' then
        raise exception 'ค่า settings "tags.lock_with_period" หายไปหรือไม่ใช่ boolean (ได้ %) → ตัดสินไม่ได้ว่างวดที่ปิดแล้วติด tag ได้หรือไม่ · **ปฏิเสธไว้ก่อน** ไม่ใช่เดาค่า (แพทเทิร์นเดียวกับสวิตช์ของ 20261025000018)',
          coalesce(v_lock::text, 'ไม่มีแถว');
      end if;
      if (v_lock)::text::boolean then
        raise exception 'งวด % ของผู้ถือนี้ปิดแล้ว และค่าตั้งค่า tags.lock_with_period = true → ติด tag ไม่ได้ · ถ้าต้องติดจริงให้ปลดสวิตช์ที่หน้าตั้งค่า (สิทธิ์ settings.manage) ซึ่งเป็นการตัดสินใจที่มีร่องรอย ไม่ใช่ข้อยกเว้นรายใบ',
          to_char(v_doc_date, 'MM/YYYY');
      end if;
      if new.tag_note is null or btrim(new.tag_note) = '' then
        raise exception 'งวด % ของผู้ถือนี้ปิดแล้ว → ติด tag ได้แต่ **ต้องเขียนเหตุผล** (tag_note) · งบของงวดนั้นถูกส่งออกไปแล้ว ถ้ามีการจัดกลุ่มใหม่ย้อนหลังต้องมีคำอธิบายว่าทำไม ไม่งั้นรายงานสองรุ่นของงวดเดียวกันจะต่างกันโดยไม่มีใครอธิบายได้',
          to_char(v_doc_date, 'MM/YYYY');
      end if;
    end if;

    return new;
  end if;

  -- ======================= UPDATE =======================
  -- ค่าที่ลงแล้วแช่แข็งทั้งหมด (ADR 0002 หัวข้อ 5 ข้อ 3)
  if new.id is distinct from old.id
     or new.transaction_id is distinct from old.transaction_id
     or new.tag_id is distinct from old.tag_id
     or new.owner_id is distinct from old.owner_id
     or new.tag_kind is distinct from old.tag_kind
     or new.single_per_txn is distinct from old.single_per_txn
     or new.tagged_at is distinct from old.tagged_at
     or new.tagged_by is distinct from old.tagged_by
     or new.tag_note is distinct from old.tag_note then
    raise exception 'แก้ลิงก์ tag ย้อนหลังไม่ได้ทุกกรณีทุกผู้ใช้ (รวมเจ้าของฐานข้อมูล · กฎเหล็กข้อ 1) · ใบ/tag/ผู้ถือ/ชนิด/คนติด/เวลา/เหตุผลตอนติด แก้ไม่ได้ · ทำได้อย่างเดียวคือ **ถอด** (เติม untagged_at/by/untag_reason) แล้วติดใหม่ — audit_log เก็บ before-after ไว้ให้แล้ว';
  end if;

  -- ถอดแล้ว = แช่แข็งถาวร (คู่กับ "ห้าม DELETE")
  if old.untagged_at is not null then
    if new.untagged_at is distinct from old.untagged_at
       or new.untagged_by is distinct from old.untagged_by
       or new.untag_reason is distinct from old.untag_reason then
      raise exception 'ร่องรอยการถอด tag แก้ย้อนหลังไม่ได้ (เวลา % -> % · ผู้ถอด % -> % · เหตุผล % -> %) · ถ้าเหตุผลที่บันทึกไว้ผิด ให้บันทึกคำอธิบายเพิ่มที่อื่น ไม่ใช่เขียนทับหลักฐานเดิม · ถ้าต้องใช้ tag นี้อีก ให้ติดใหม่เป็นแถวใหม่',
        old.untagged_at, new.untagged_at, old.untagged_by, new.untagged_by,
        old.untag_reason, new.untag_reason;
    end if;
    return new;
  end if;

  -- ลิงก์ที่ยังใช้อยู่: UPDATE ทำได้ทางเดียวคือ **ปิด**
  if new.untagged_at is null then
    raise exception 'UPDATE บนลิงก์ tag ที่ยังใช้อยู่ทำได้ทางเดียวคือการถอด (ต้องเติม untagged_at/untagged_by/untag_reason พร้อมกัน) · ไม่มีการแก้ค่าอื่นของลิงก์ที่ลงแล้ว';
  end if;
  if new.untag_reason is null or btrim(new.untag_reason) = '' then
    raise exception 'ถอด tag ต้องเขียนเหตุผล (untag_reason) · บังคับทุกผู้ถือ ไม่ใช่แค่นิติบุคคล เหมือน void_reason ของ D-098 — ถ้าใช้ tag ตรวจย้อนหลังแล้วถอดได้เงียบๆ ผลการตรวจก็เชื่อไม่ได้ (ผู้สอบบัญชีถามว่าทำไมใบนี้หลุดจาก project แล้วตอบไม่ได้)';
  end if;

  new.untagged_at := now();   -- ทับค่าที่ส่งมา: ปลอมเวลาถอดให้ย้อนเข้างวดก่อนไม่ได้
  if v_uid is not null then
    if new.untagged_by is not null and new.untagged_by <> v_uid then
      raise exception 'untagged_by (%) ไม่ใช่ผู้ใช้ที่กำลังถอด tag (%) · บันทึกว่าคนอื่นเป็นคนถอดไม่ได้',
        new.untagged_by, v_uid;
    end if;
    new.untagged_by := v_uid;
  end if;

  -- งวดที่ปิดแล้ว: ขาถอดก็ต้องมีเหตุผล (บังคับอยู่แล้วข้างบน) และสวิตช์ล็อกยังมีผล
  select t.owner_id, t.doc_date into v_owner, v_doc_date
    from sri_os.transactions t where t.id = old.transaction_id;
  if exists (select 1 from sri_os.period_closes p
              where p.owner_id = v_owner
                and p.period = date_trunc('month', v_doc_date)::date) then
    select s.value into v_lock from sri_os.settings s where s.key = 'tags.lock_with_period';
    if v_lock is null or jsonb_typeof(v_lock) <> 'boolean' then
      raise exception 'ค่า settings "tags.lock_with_period" หายไปหรือไม่ใช่ boolean (ได้ %) → ตัดสินไม่ได้ว่างวดที่ปิดแล้วถอด tag ได้หรือไม่ · ปฏิเสธไว้ก่อน',
        coalesce(v_lock::text, 'ไม่มีแถว');
    end if;
    if (v_lock)::text::boolean then
      raise exception 'งวด % ของผู้ถือนี้ปิดแล้ว และค่าตั้งค่า tags.lock_with_period = true → ถอด tag ไม่ได้',
        to_char(v_doc_date, 'MM/YYYY');
    end if;
  end if;

  return new;
end $fn$;

comment on function fn_tag_link_system_columns() is
  'ด่านของลิงก์ tag: owner_id/tag_kind/single_per_txn เป็นสำเนาที่อ่านจากต้นฉบับเอง (ส่งมาไม่ตรง = ปฏิเสธ ไม่ใช่ทับเงียบๆ) · tagged_by/untagged_by = auth.uid() ปลอมไม่ได้ · ติด tag ให้ใบที่ยกเลิกแล้วหรือ tag ที่ปิดแล้วไม่ได้ · UPDATE ทำได้ทางเดียวคือถอดพร้อมเหตุผท · ถอดแล้วแช่แข็งถาวร · งวดที่ปิดแล้วต้องมีเหตุผลทั้งขาติดและขาถอด และเคารพสวิตช์ settings.tags.lock_with_period (ค่าเพี้ยน = ปฏิเสธ)';

revoke all on function fn_tag_link_system_columns() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_tag_link_system_columns() from anon, authenticated';
exception when undefined_object then null;
end $$;

drop trigger if exists trg_tag_link_system_columns on transaction_tags;
create trigger trg_tag_link_system_columns
  before insert or update on transaction_tags
  for each row execute function fn_tag_link_system_columns();

-- ------------------------------------------------------------
-- ห้าม DELETE — กันถึงชั้นเจ้าของฐานข้อมูล ไม่ใช่แค่ "ไม่มี policy"
-- ------------------------------------------------------------
create or replace function fn_tag_link_no_delete() returns trigger
language plpgsql set search_path = '' as $fn$
begin
  raise exception 'ลบลิงก์ tag ไม่ได้ทุกกรณีทุกผู้ใช้ (รวมเจ้าของฐานข้อมูล · กฎเหล็กข้อ 1) · ถอด tag = UPDATE เติม untagged_at/untagged_by/untag_reason ซึ่งทิ้งร่องรอยว่าใครถอดเมื่อไหร่เพราะอะไร · การลบแถวคือการทำให้ "ใบนี้เคยอยู่ใน project นี้" หายไปโดยไม่มีใครรู้ แล้วรายงานย้อนหลังสองรุ่นจะต่างกันแบบอธิบายไม่ได้ (id % · ใบ % · tag %)',
    old.id, old.transaction_id, old.tag_id;
end $fn$;

comment on function fn_tag_link_no_delete() is
  'ลิงก์ tag ลบไม่ได้ทุกทาง · ถอดด้วย untagged_at/by/untag_reason เท่านั้น (ADR 0002 หัวข้อ 5 ข้อ 3)';

revoke all on function fn_tag_link_no_delete() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_tag_link_no_delete() from anon, authenticated';
exception when undefined_object then null;
end $$;

drop trigger if exists trg_tag_link_no_delete on transaction_tags;
create trigger trg_tag_link_no_delete
  before delete on transaction_tags
  for each row execute function fn_tag_link_no_delete();

-- ============================================================
-- 4 · RLS — ขอบเขตเดียวกับสมุด **ด้วยฟังก์ชันตัวเดียวกัน**
--
-- อ่าน: `fn_can_read_txn` ตัวเดียวกับ `transactions_by_owner` / `lines_by_txn`
--   **ไม่เขียนกฎขอบเขตซ้ำที่นี่** (บทเรียนข้อ 5: กฎเดียวกันห้ามเขียนสองที่) ·
--   ADR 0002 หัวข้อ 5 ข้อ 2 เตือนเองว่า "วันหนึ่ง policy สองตารางเพี้ยนไม่เท่ากัน = รั่ว"
--   → ทางเดียวที่เพี้ยนไม่ได้คือเรียกฟังก์ชันเดียวกัน
--   เหตุผลที่ไม่ใช้แค่ `fn_can_see_owner(owner_id)` ตามตัวอักษรของ ADR:
--   `tag_note` / `untag_reason` เป็นข้อความที่ผู้ใช้เขียนถึงใบใดใบหนึ่ง และ dialog
--   ที่ ADR ออกแบบไว้เองใส่ **วันที่และยอดเงิน** ลงในประโยค ("เอา tag «ไอริส 235»
--   ออกจากรายการวันที่ 12/09 ยอด 45,000 บาท · เพราะอะไร") → ใครอ่านลิงก์ได้
--   ก็อ่านยอดของใบนั้นได้ จึงต้องเป็นขอบเขตเดียวกับใบ ไม่ใช่กว้างกว่า
--   ผลที่ตามมาโดยเจตนา: ตำแหน่งที่ไม่มี `ledger.read` (Staff วันนี้) ติด tag
--   **บนใบในสมุด** ไม่ได้ แต่ยังติดได้ **ตอนคีย์ร่าง** (ไฟล์ถัดไป) ซึ่งเป็นที่ที่
--   ตำแหน่งนั้นทำงานจริงอยู่แล้ว
--
-- เขียน: insert = `tag.assign` + ขอบเขต · update = **ปิดได้ทางเดียว** ·
--   **delete: ไม่มี policy เลย**
-- ============================================================
alter table transaction_tags enable row level security;

drop policy if exists tag_links_by_txn on transaction_tags;
create policy tag_links_by_txn on transaction_tags
  for select to authenticated
  using (exists (
    select 1 from transactions t
     where t.id = transaction_id
       and fn_can_read_txn(t.owner_id, t.asset_id, t.created_by)
  ));

drop policy if exists tag_links_insert on transaction_tags;
create policy tag_links_insert on transaction_tags
  for insert to authenticated
  with check (
    fn_can('tag.assign')
    and fn_can_see_owner(owner_id)
    and exists (
      select 1 from transactions t
       where t.id = transaction_id
         and fn_can_read_txn(t.owner_id, t.asset_id, t.created_by)
    )
  );

-- UPDATE มีไว้เพื่อ "ถอด" เท่านั้น: using = แถวต้องยังใช้อยู่ ·
-- with check = แถวหลังแก้ต้องถูกปิดแล้ว → ชั้น RLS เองก็ยอมแค่การปิด
-- (trigger กันซ้ำอีกชั้นและกันถึง role ที่ไม่อยู่ใต้ RLS)
drop policy if exists tag_links_untag on transaction_tags;
create policy tag_links_untag on transaction_tags
  for update to authenticated
  using (
    fn_can('tag.assign')
    and untagged_at is null
    and exists (
      select 1 from transactions t
       where t.id = transaction_id
         and fn_can_read_txn(t.owner_id, t.asset_id, t.created_by)
    )
  )
  with check (
    fn_can('tag.assign')
    and untagged_at is not null
    and exists (
      select 1 from transactions t
       where t.id = transaction_id
         and fn_can_read_txn(t.owner_id, t.asset_id, t.created_by)
    )
  );

-- ชั้น GRANT: DML สี่ตัวต้องครบ (เทสต์ P1) · ตัวที่กันการลบจริงคือ trigger + ไม่มี policy
grant select, insert, update, delete on transaction_tags to authenticated;
do $$
begin
  execute 'revoke all on table sri_os.transaction_tags from anon';
exception when undefined_object then null;
end $$;

-- ============================================================
-- 5 · ร่องรอย + ห้าม TRUNCATE (มี id uuid → fn_audit)
--     TRUNCATE ไม่ยิง row trigger → ล้างประวัติ tag ทั้งตารางได้ในคำสั่งเดียว
--     และ audit ที่ควรบันทึกการลบจะไม่มีอะไรเลย
-- ============================================================
drop trigger if exists trg_audit_transaction_tags on transaction_tags;
create trigger trg_audit_transaction_tags
  after insert or update or delete on transaction_tags
  for each row execute function fn_audit();

drop trigger if exists trg_forbid_truncate on transaction_tags;
create trigger trg_forbid_truncate
  before truncate on transaction_tags
  for each statement execute function fn_forbid_truncate();

-- ============================================================
-- 6 · ด่านคอลัมน์ (D-089)
--     ทุกคอลัมน์เป็น `row` + `ledger.read` เหมือน `transactions`/`transaction_lines`
--     **ไม่มีคอลัมน์ไหนเป็น `open`** โดยเจตนา: แถวนี้บอกว่าใบไหนอยู่ใน project ไหน
--     และข้อความของผู้ใช้อ้างถึงยอดของใบนั้นได้
-- ============================================================
insert into column_exposure_tables (table_name, review_state, reason) values
  ('transaction_tags', 'classified',
   'ลิงก์ tag ↔ ใบ (ADR 0002) · แถวถูกกรองด้วย fn_can_read_txn ตัวเดียวกับหัวรายการและบรรทัดบัญชี (เขียนที่เดียวเพื่อให้ขอบเขตสองตารางเพี้ยนกันไม่ได้) · ไม่มีคอลัมน์จำนวนเงินเลย (guard ไล่ information_schema)')
on conflict (table_name) do update
  set review_state = excluded.review_state, reason = excluded.reason;

insert into column_exposure (table_name, column_name, exposure, min_permission, rationale)
select 'transaction_tags', c, 'row', 'ledger.read', t.why
  from (values
    (array['id', 'transaction_id', 'tag_id', 'owner_id', 'tag_kind', 'single_per_txn'],
     'คีย์และความเชื่อมโยงของลิงก์ · บอกว่าใบไหนอยู่ใน project/ป้ายไหนและเป็นของผู้ถือใด = จังหวะเงินและการจัดกลุ่มของบ้าน · ต้องมี ledger.read + ขอบเขตของใบ (fn_can_read_txn) ถึงจะเห็น'),
    (array['tagged_at', 'tagged_by', 'tag_note', 'untagged_at', 'untagged_by', 'untag_reason'],
     'ร่องรอยการติด/ถอด (ใคร เมื่อไหร่ ทำไม) · tag_note/untag_reason เป็นข้อความที่ผู้ใช้เขียนถึงใบใดใบหนึ่งและมักมีวันที่/ยอดอยู่ในประโยคตาม dialog ที่ ADR ออกแบบไว้ → ใช้สิทธิ์เดียวกับแถวที่มันอธิบาย')
  ) as t(cols, why), unnest(t.cols) c
on conflict (table_name, column_name) do update
  set exposure = excluded.exposure, min_permission = excluded.min_permission,
      rationale = excluded.rationale;

select fn_apply_column_exposure();

-- ============================================================
-- 7 · guard ท้ายไฟล์
-- ============================================================
do $$
declare v text; n int;
begin
  if to_regclass('sri_os.transaction_tags') is null then
    raise exception 'ตาราง transaction_tags ไม่ถูกสร้าง';
  end if;

  -- (ก) **ห้ามมีคอลัมน์จำนวนเงิน/สัดส่วน** (ADR 0002 หัวข้อ 3.3 · 4.3 ทางเลือก C)
  --     ไล่จาก information_schema.columns ตามที่ ADR ระบุ
  select string_agg(c.column_name || ' (' || c.data_type || ')', ', '), count(*)
    into v, n
    from information_schema.columns c
   where c.table_schema = 'sri_os' and c.table_name = 'transaction_tags'
     and c.data_type in ('numeric', 'money', 'double precision', 'real');
  if n > 0 then
    raise exception 'transaction_tags มีคอลัมน์ชนิดตัวเลขเงิน/สัดส่วน % คอลัมน์: % · ทางเลือก C (ถ่วงน้ำหนักในตารางลิงก์) ถูกปฏิเสธ **เชิงโครงสร้าง** — น้ำหนักของ ADR 0003 ต้องอยู่ในตารางแยก (tag_allocations) เพราะต้องมีร่องรอยตอนแก้สัดส่วนย้อนหลัง ต้องบังคับ Σ = 100%% ต่อใบต่อชนิด และต้องตัดสินว่าคิดรายใบหรือรายบรรทัด · ถ้าน้ำหนักมาอยู่ที่นี่ ทุก view ที่ join ตารางนี้จะหยิบตัวคูณไปใช้ได้โดยไม่มีใครตัดสิน',
      n, v;
  end if;

  -- (ข) trigger ของตารางนี้ **ห้ามเขียน transactions / transaction_lines**
  --     (อ่านได้ — ต้องอ่าน owner_id จากใบ — แต่เขียนไม่ได้เด็ดขาด)
  select string_agg(p.proname, ', ') into v
    from pg_trigger g join pg_proc p on p.oid = g.tgfoid
   where g.tgrelid = 'sri_os.transaction_tags'::regclass and not g.tgisinternal
     and p.prosrc ~* '(insert\s+into|update|delete\s+from)\s+(sri_os\.)?"?transaction(s|_lines)"?';
  if v is not null then
    raise exception 'trigger ของ transaction_tags เขียน transactions/transaction_lines: % · ติด tag ต้องไม่แตะตัวเลขในงบเชิงโครงสร้าง (ADR 0002 หัวข้อ 5 ข้อ 5) ไม่ใช่เพราะวันนี้ยังไม่มีใครเขียน', v;
  end if;

  -- (ค) index/constraint ตาม ADR 0002 หัวข้อ 3.3 ต้องมีจริง
  select string_agg(x.want, ', ') into v
    from (values ('tag_link_active_uq'), ('tag_link_single_uq'), ('tag_link_by_tag'),
                 ('tag_link_by_owner'), ('tag_link_by_txn')) x(want)
   where not exists (select 1 from pg_class i
                      where i.relname = x.want and i.relnamespace = 'sri_os'::regnamespace);
  if v is not null then raise exception 'index ของลิงก์ tag หายไป: %', v; end if;

  -- partial unique index ต้องเป็น unique จริงและมี predicate จริง
  -- (ถ้าวันหนึ่งใครสร้างใหม่โดยลืม where ลิงก์ที่ถอดแล้วจะติดใหม่ไม่ได้ตลอดกาล)
  select string_agg(i.relname, ', ') into v
    from pg_index x join pg_class i on i.oid = x.indexrelid
   where x.indrelid = 'sri_os.transaction_tags'::regclass
     and i.relname in ('tag_link_active_uq', 'tag_link_single_uq')
     and (not x.indisunique or x.indpred is null);
  if v is not null then
    raise exception 'index % ไม่ใช่ partial unique ตามที่ ADR 0002 หัวข้อ 3.3 กำหนด · ไม่ unique = ติด tag เดิมซ้ำบนใบเดียวได้ (ยอด touch จะนับใบเดียวสองครั้ง) · ไม่มี predicate = ถอดแล้วติดใหม่ไม่ได้ตลอดกาล', v;
  end if;

  select string_agg(x.want, ', ') into v
    from (values ('tag_link_close_both_ways'), ('tag_link_close_order')) x(want)
   where not exists (select 1 from pg_constraint con
                      where con.conrelid = 'sri_os.transaction_tags'::regclass
                        and con.conname = x.want and con.convalidated);
  if v is not null then raise exception 'constraint ของลิงก์ tag หายไป/ยังไม่ validate: %', v; end if;

  -- (ง) trigger ครบ + **ไม่มี policy DELETE**
  select string_agg(x.want, ', ') into v
    from (values ('trg_tag_link_system_columns'), ('trg_tag_link_no_delete'),
                 ('trg_audit_transaction_tags'), ('trg_forbid_truncate')) x(want)
   where not exists (select 1 from pg_trigger g
                      where g.tgrelid = 'sri_os.transaction_tags'::regclass
                        and g.tgname = x.want and not g.tgisinternal);
  if v is not null then raise exception 'trigger หายไปจาก transaction_tags: %', v; end if;

  select string_agg(p.polname || '/' || p.polcmd::text, ', ') into v
    from pg_policy p
   where p.polrelid = 'sri_os.transaction_tags'::regclass and p.polcmd in ('d', '*');
  if v is not null then
    raise exception 'มี policy DELETE/ALL บน transaction_tags (%) — ต้องไม่มีเลย (ADR 0002 หัวข้อ 5 ข้อ 2) · ถอด tag ด้วย UPDATE พร้อมเหตุผลเท่านั้น', v;
  end if;

  if not (select c.relrowsecurity from pg_class c where c.oid = 'sri_os.transaction_tags'::regclass) then
    raise exception 'RLS ของ transaction_tags ยังปิดอยู่ = ไม่มีด่านเลย (grants ให้ DML ครบทุกตาราง)';
  end if;

  -- (จ) ด่านของลิงก์ต้องไม่เรียกฟังก์ชันตรวจสิทธิ์ (กฎร่องรอยห้ามปิดจากหน้า Settings)
  v := pg_get_functiondef('sri_os.fn_tag_link_system_columns()'::regprocedure);
  if v ~ '\mfn_can\M' or v ~ 'fn_is_management' then
    raise exception 'ด่านของลิงก์ tag เรียกฟังก์ชันตรวจสิทธิ์ → ปลดกฎร่องรอยได้ด้วยการแก้ตารางสิทธิ์ · ใครติดได้เป็นเรื่องของ RLS กฎร่องรอยต้องเท่ากันทุกตำแหน่ง';
  end if;
  -- และต้องอ่านผู้ถือจากใบจริง ไม่ใช่เชื่อค่าที่ส่งมา
  if v !~ 'from sri_os\.transactions' then
    raise exception 'ด่านของลิงก์ tag ไม่ได้อ่าน owner_id จาก sri_os.transactions → มีไฟล์อื่นเขียนทับหลังไฟล์นี้ · ถ้าเชื่อค่าที่ส่งมา แถวลิงก์จะชี้ผู้ถือผิดได้ทั้งที่ FK ผ่าน (กฎเหล็กข้อ 3)';
  end if;

  -- (ฉ) ด่านคอลัมน์ไม่มีของค้าง และติดจริง
  select string_agg(u.object_name || ': ' || u.problem, ' · ') into v
    from sri_os.fn_column_exposure_unclassified() u
   where u.object_name like 'transaction_tags%';
  if v is not null then
    raise exception 'ด่านคอลัมน์ยังมีของค้างจาก transaction_tags (D-089): %', v;
  end if;
  select string_agg(b.object_name || ': ' || b.problem, ' · ') into v
    from sri_os.fn_column_exposure_breaches() b
   where b.object_name like 'transaction_tags%';
  if v is not null then
    raise exception 'ด่านคอลัมน์ของ transaction_tags ไม่ติดจริง: %', v;
  end if;
  if not sri_os.fn_policy_requires_permission('transaction_tags', 'ledger.read') then
    raise exception 'policy อ่านของ transaction_tags ไม่ได้บังคับ ledger.read ทุกตัว → ลิงก์เปิดกว้างกว่าใบที่มันอธิบาย (ยอดในข้อความเหตุผลจะรั่วไปถึงตำแหน่งที่อ่านสมุดไม่ได้)';
  end if;

  -- (ช) สวิตช์งวดต้องมีจริงและเป็น boolean (ไม่งั้นด่านจะปฏิเสธทุกการติด tag ในงวดที่ปิด)
  if not exists (select 1 from sri_os.settings
                  where key = 'tags.lock_with_period' and jsonb_typeof(value) = 'boolean') then
    raise exception 'settings "tags.lock_with_period" ไม่มีหรือไม่ใช่ boolean → งวดที่ปิดแล้วจะติด tag ไม่ได้เลยโดยไม่มีใครรู้ว่าเพราะคอนฟิกหาย';
  end if;

  raise notice 'ลิงก์ tag พร้อม: owner_id เป็นสำเนาจากใบที่อ่านเองและแก้ไม่ได้ (กฎเหล็กข้อ 3) · ห้าม DELETE ทั้ง RLS และ trigger · ถอดต้องมีเหตุผลและแช่แข็งหลังถอด · tagged_by มาจาก auth.uid() · **ไม่มีคอลัมน์จำนวนเงินแม้คอลัมน์เดียว** · partial unique index สองตัวตาม ADR 0002 หัวข้อ 3.3 · ขอบเขตอ่านใช้ fn_can_read_txn ตัวเดียวกับสมุด';
end $$;
