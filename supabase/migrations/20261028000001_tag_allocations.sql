-- ============================================================
-- SRI OS · **น้ำหนักของ tag ต่อใบ (60/40)** — ADR 0003 ข้อ 3.2 · 3.3 · 4.1 (ชิ้น A2)
--
-- ตารางนี้คือที่เดียวที่ "ใบในสมุด" ได้ **ตัวคูณ** ติดตัว → จึงเป็นที่เดียวในเรื่อง tag
-- ที่ตัวเลขในรายงานเงินขึ้นอยู่กับข้อมูลที่คนกรอก และต้องกันแน่นที่สุด
--
-- ------------------------------------------------------------
-- **สิ่งที่ไฟล์นี้ทำให้เป็นความจริงเดียว**
--
-- 1. **ตารางแยก ไม่ใช่คอลัมน์ใน `transaction_tags`** (ADR 0002 ข้อ 4.3 สั่งทางนี้ไว้เอง
--    และ guard ท้ายไฟล์ 20261027000002 บังคับอยู่: ตารางลิงก์ห้ามมีคอลัมน์ตัวเลขเงิน)
--    ผูกกับ **ลิงก์** (`transaction_tag_id`) ไม่ใช่กับ (ใบ + tag) ตรงๆ
--    → ถอด tag แล้วน้ำหนักตามไปด้วยโดยไม่ต้องซิงก์สองที่
--
-- 2. **ห้ามมีคอลัมน์จำนวนเงินเด็ดขาด** · guard ท้ายไฟล์ไล่ `information_schema.columns`
--    แล้วพังถ้ามีคอลัมน์ numeric/money/float ที่ **scale ≠ 6** (ไล่จาก `numeric_scale`
--    ไม่ใช่จากชื่อ ตาม ADR 0003 ข้อ 3.2) · จำนวนเงินมาจากสมุดเสมอ ตารางนี้ถือแต่ตัวคูณ
--
-- 3. **`weight > 0`** — น้ำหนักศูนย์ไม่มีความหมายและอันตราย: มันคือการติด tag ไว้
--    แล้วบอกว่าไม่เกี่ยว ซึ่งถ้าอยากได้แบบนั้นให้ถอด tag (มีร่องรอยชัดกว่า) ·
--    ปล่อยให้มี 0 ได้ = มีแถวที่โผล่ในรายการ tag แต่ไม่โผล่ในยอด = คนอ่านจะคิดว่าระบบลืมนับ
--
-- 4. **append-only + ปิดด้วยร่องรอย** (เหตุผลเดียวกับกฎเหล็กข้อ 1): กำไรต่อ project
--    ที่เคยรายงานไปแล้วคิดจากน้ำหนักชุดเดิม ถ้าแก้ทับโดยไม่มีร่องรอย จะไม่มีใคร
--    อธิบายได้ว่าทำไมตัวเลขเดือนที่แล้วเปลี่ยน · `supersede_reason` **บังคับ** (ว่างไม่ได้)
--    `weight` **UPDATE ทับไม่ได้** · **DELETE ไม่ได้ทุกทาง** (ไม่มี policy + trigger)
--
-- 5. **`allocated_by` มาจาก `auth.uid()` ที่ trigger ตั้งให้** (แพทเทิร์น
--    `fn_tag_link_system_columns`) → โยนความผิดเรื่องสัดส่วนให้คนอื่นไม่ได้
--
-- 6. **น้ำหนักติดได้เฉพาะชนิดที่ `tag_kinds.requires_allocation`** (คอนฟิก ไม่ใช่
--    ชื่อ `'project'` ที่พิมพ์ในโค้ด · กฎเหล็กข้อ 5) · ใส่น้ำหนักให้ `label` = ปฏิเสธ
--    เพราะจะทำให้ **touch กับ allocated ปนกัน** ซึ่ง ADR 0003 ข้อ 5 ห้ามเด็ดขาด
--
-- 7. **ทุกแถวมี `owner_id` และเป็นสำเนาที่ trigger บังคับ** (กฎเหล็กข้อ 3 —
--    "ทุกแถวมี owner_id และรายงานทุกหน้ากรอง Entity ได้") · แพทเทิร์นเดียวกับ
--    `transaction_tags` ของ ADR 0002 เป๊ะ: trigger **อ่านผู้ถือจากลิงก์เอง**
--    (`transaction_tags.owner_id` ซึ่งเองก็เป็นสำเนาที่อ่านจากใบ) · **ไม่รับค่าจาก
--    ผู้เรียก** (D-115: ด่านห้ามอ่านฟิลด์ที่ผู้เรียกเลือกได้) · ส่งมาไม่ตรง =
--    **ปฏิเสธ** ไม่ใช่ทับให้เงียบๆ (ทับเงียบๆ ซ่อนบั๊กของผู้เรียก) · **ย้ายไม่ได้**
--    (UPDATE owner_id = ปฏิเสธทุกกรณี)
--    เหตุผลที่ตารางนี้ต้องมีเหมือนตารางลิงก์ ไม่ใช่ "join ผ่านลิงก์ก็ได้":
--    ตารางนี้คือตารางที่ **รายงานเงินพึ่งพาโดยตรง** (ตัวคูณของยอดต่อ Entity)
--    → RLS/รายงานต้องกรอง Entity ได้ที่ตัวแถวเอง และกฎเหล็กข้อ 3 ไม่เจาะข้อยกเว้น
--    ให้ความสะดวกของการ join
--
-- ------------------------------------------------------------
-- **ด่าน Σ น้ำหนัก = 1.000000 พอดี** (ADR 0003 ข้อ 4.1)
--
--   `fn_assert_tag_allocation_complete()` · **constraint trigger · deferrable
--   initially deferred** (แพทเทิร์นเดียวกับด่าน Money Invariants) ยิงตอน commit
--   จึงยอมให้ระหว่างธุรกรรมมีสภาพกลางที่ยังไม่ครบ 100%
--
--   ผูกไว้ **สองตาราง** และนั่นคือเรื่องสำคัญที่สุดของไฟล์นี้:
--     `tag_allocations`  → `trg_assert_tag_allocation_complete`
--     `transaction_tags` → `trg_assert_tag_allocation_links`
--   ถ้าผูกแต่ตารางน้ำหนัก **การติด project แล้วไม่ใส่น้ำหนักเลยจะผ่านเงียบ**
--   (ไม่มีแถวในตารางน้ำหนัก = ไม่มี trigger ยิง) แล้วยอดของใบนั้นจะหายไปจาก
--   ทุกรายงานต่อ project โดยไม่มีตัวเลขไหนโป่งให้สังเกต — เปิดฟีเจอร์ครึ่งเดียว
--   อันตรายกว่าไม่เปิด (บทเรียน mace-windu ข้อ 7) · เทสต์ M2 วัดความเสียหายไว้แล้ว
--
--   ตรวจต่อ (`transaction_id`, `tag_kind`) ที่ `requires_allocation` สามข้อ:
--     (1) ทุกลิงก์ที่ยังใช้อยู่ **ต้องมี** น้ำหนักที่ยังใช้อยู่ → ไม่ใส่ = **ปฏิเสธ**
--         ไม่ใช่เดาให้เป็น 100% (ข้อมูลไม่ครบต้องปฏิเสธ · บทเรียน mace-windu ข้อ 1)
--         **ข้อยกเว้นของ "ติด project อันเดียว → เติม 1.000000"** อยู่ที่ **ประตู**
--         (ชิ้น A4) ไม่ใช่ที่ด่านนี้ — ด่านตัดสินจากสภาพที่ลงไปแล้วเท่านั้น
--     (2) `sum(weight) = 1.000000` **พอดี** เทียบแบบ exact ไม่มี tolerance
--         (`numeric` เป็นทศนิยมแม่นตรง และน้ำหนักเป็นค่าที่คนกรอก ไม่ใช่ผลหาร)
--     (3) ไม่มีน้ำหนักที่ยังใช้อยู่ ผูกกับลิงก์ที่ถูกถอดไปแล้ว (กันแถวกำพร้า)
--
--   ข้อความ error บอก **ยอดที่ขาด/เกิน** และ **รายชื่อ tag พร้อมน้ำหนักปัจจุบัน**
--   ไม่ใช่แค่ "ไม่ถึง 100%" — คนแก้ต้องรู้ว่าจะไปเติมที่ไหน (ข้อ 4.1)
--
-- ------------------------------------------------------------
-- ลำดับ: ต้องรัน **หลัง 20261027000001** (`tag_kinds.requires_allocation` · `tags`) ·
--        **หลัง 20261027000002** (`transaction_tags`) · หลัง 20261020000000 (ด่านคอลัมน์)
--        → วางต่อท้าย `20261027161500_asset_account_balance_nonneg.sql`
--        ก่อน `20261020000003_replay_end_state_guard.sql`
--        ลงทะเบียนใน `supabase/migration-order.txt` และ UNDER_TEST ของ
--        `scripts/test-rls-local.sh`
--
-- idempotent: `create table if not exists` · `create or replace function` ·
--   `create index if not exists` · ผูก trigger/policy เฉพาะเมื่อยังไม่มี (do block
--   ที่ไล่ `pg_trigger` / `pg_policy`) · `insert ... on conflict`
--   **ไฟล์นี้ไม่มีคำสั่งถอนของ และห้ามมีคำนั้นแม้ในคอมเมนต์** เพราะตัวตรวจของ
--   MCP `apply_migration` อ่านจากข้อความดิบแล้ว timeout ทุกครั้ง (ดู CLAUDE.md)
--   → ใช้รูปแบบ `do $$ … if not exists (select 1 from pg_trigger …) then execute … end if; end $$;`
--   แบบเดียวกับ `20261027161500_asset_account_balance_nonneg.sql`
--
-- ย้อนกลับ (rollback):
--   -- 1. ปิดด่านชั่วคราว (เปิดคืนด้วย enable trigger):
--   --    alter table sri_os.tag_allocations  disable trigger trg_assert_tag_allocation_complete;
--   --    alter table sri_os.transaction_tags disable trigger trg_assert_tag_allocation_links;
--   -- 2. ถอนตาราง/ฟังก์ชันออกถาวร ต้องทำใน migration ใหม่ (ไฟล์นี้เขียนคำสั่งถอน
--   --    ไม่ได้ด้วยเหตุผลข้างบน) + ล้างทะเบียนด่านคอลัมน์:
--   --    delete from sri_os.column_exposure        where table_name = 'tag_allocations';
--   --    delete from sri_os.column_exposure_tables where table_name = 'tag_allocations';
--   --    select sri_os.fn_apply_column_exposure();
--   ** ก่อนย้อน: ต้องสำรองตารางนี้ทั้งตาราง ** (ADR 0003 ข้อ 8) — น้ำหนักที่คนกรอกไว้
--   หายถาวร และใบที่เคยแบ่ง 60/40 จะกลับไปถูกนับเต็มจำนวนในทั้งสอง project **เงียบๆ**
--   → รายงานกำไรต่อ project ที่เคยออกไปจะอธิบายไม่ตรงกับของใหม่
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 0 · pre-flight — ของที่ต้องมีอยู่ก่อน ไม่งั้นด่านจะครอบของว่างแบบเงียบๆ
-- ============================================================
do $$
begin
  if to_regclass('sri_os.transaction_tags') is null then
    raise exception 'ไม่มี transaction_tags → ต้องรัน 20261027000002_tag_links.sql ก่อน (น้ำหนักผูกกับลิงก์ ไม่ใช่กับใบ+tag ตรงๆ)';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'sri_os' and table_name = 'tag_kinds'
                    and column_name = 'requires_allocation') then
    raise exception 'tag_kinds ไม่มีคอลัมน์ requires_allocation → ต้องรัน 20261027000001_tag_catalog.sql รุ่น 27/10 ก่อน (ด่านนี้อ่านว่าชนิดไหนปันส่วนจากคอนฟิก ไม่ใช่จากชื่อ project ที่พิมพ์ในโค้ด · กฎเหล็กข้อ 5)';
  end if;
  if not exists (select 1 from sri_os.tag_kinds where requires_allocation) then
    raise exception 'ไม่มีชนิด tag ใดที่ requires_allocation = true เลย → ด่าน Σ น้ำหนัก = 100%% จะครอบของว่าง (seed ของ 20261027000001 ตั้ง project = true)';
  end if;
  if to_regprocedure('sri_os.fn_can_read_txn(uuid,uuid,uuid)') is null
     or to_regprocedure('sri_os.fn_can_see_owner(uuid)') is null then
    raise exception 'ไม่มี fn_can_read_txn/fn_can_see_owner → ขอบเขตของน้ำหนักต้องใช้ฟังก์ชันตัวเดียวกับสมุดและลิงก์ ห้ามเขียนกฎขอบเขตซ้ำ';
  end if;
  if not exists (select 1 from sri_os.permissions where key = 'tag.assign') then
    raise exception 'ไม่มีสิทธิ์ tag.assign ในตารางสิทธิ์ → 20261027000001 ไม่ได้ลง (policy อ่านสิทธิ์จากตาราง ไม่ hard-code role)';
  end if;
  if to_regclass('sri_os.column_exposure_tables') is null
     or to_regprocedure('sri_os.fn_apply_column_exposure()') is null then
    raise exception 'ไม่มีทะเบียนด่านคอลัมน์ → ต้องรัน 20261020000000 ก่อน (D-089)';
  end if;
end $$;

-- ============================================================
-- 1 · ตารางน้ำหนัก
-- ============================================================
create table if not exists tag_allocations (
  /** surrogate — ต้องรองรับ "แก้สัดส่วนแล้วเก็บของเก่าไว้" (ข้อ 3.3) */
  id                 uuid primary key default gen_random_uuid(),
  /**
   * ผูกกับ **ลิงก์** ไม่ใช่กับ (ใบ + tag) ตรงๆ → ถอด tag แล้วน้ำหนักตามไปด้วย
   * โดยไม่ต้องซิงก์สองที่ · on delete restrict — ลิงก์ที่มีน้ำหนักลบไม่ออก
   * (ลิงก์เองก็ลบไม่ออกอยู่แล้ว แต่ FK นี้ทำให้ไม่มีทางลบได้ทางอ้อมด้วย)
   */
  transaction_tag_id uuid not null references transaction_tags(id) on delete restrict,
  /**
   * **สำเนาผู้ถือจากลิงก์** (กฎเหล็กข้อ 3) · trigger อ่านจาก
   * `transaction_tags.owner_id` เองและบังคับให้ตรงเสมอ · ส่งมาไม่ตรง = ปฏิเสธ ·
   * ย้ายไม่ได้ · มีไว้เพื่อให้ RLS/รายงานกรอง Entity ได้ **ที่ตัวแถวเอง**
   * ไม่ต้อง join ลิงก์กับใบ — แพทเทิร์นเดียวกับ transaction_tags เป๊ะ
   */
  owner_id           uuid not null references owners(id),
  /**
   * **สัดส่วน ไม่ใช่จำนวนเงิน** · 0.600000 = 60% · ตัวคูณมาจากที่นี่
   * ตัวตั้งมาจากสมุดเสมอ (ข้อ 3.2) · scale = 6 คือสิ่งที่ guard ใช้แยก
   * "ตัวคูณ" ออกจาก "จำนวนเงิน" → อย่าเปลี่ยน scale โดยไม่แก้ guard พร้อมกัน
   */
  weight             numeric(9,6) not null,
  allocated_at       timestamptz not null default now(),
  /** trigger ตั้งจาก auth.uid() · ปลอมไม่ได้ (แพทเทิร์น fn_tag_link_system_columns) */
  allocated_by       uuid not null references app_users(id),
  /** **เงื่อนไขสองทาง** เหมือน untagged_* ของ ADR 0002 · เหตุผลว่างไม่ได้ */
  superseded_at      timestamptz,
  superseded_by      uuid references app_users(id),
  supersede_reason   text
);

-- ---------- ตารางที่ถูกสร้างไว้ก่อนรุ่นนี้ยังไม่มี `owner_id` ----------
-- `create table if not exists` ข้างบนไม่เติมคอลัมน์ให้ตารางที่มีอยู่แล้ว →
-- ถ้าเคยรันรุ่นก่อนหน้าของไฟล์นี้ไว้ (เครื่องใครเครื่องมัน) ตารางจะขาดคอลัมน์
-- ที่กฎเหล็กข้อ 3 บังคับโดยไม่มีอะไรฟ้อง · เติมโดย **อ่านจากลิงก์** เท่านั้น
-- (ไม่มีทางเดาผู้ถือจากที่อื่น) และถ้าเติมไม่ครบ = พังเสียงดัง ไม่ปล่อย null ไว้
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'sri_os' and table_name = 'tag_allocations'
                    and column_name = 'owner_id') then
    execute 'alter table sri_os.tag_allocations add column owner_id uuid';
    execute 'update sri_os.tag_allocations a
                set owner_id = l.owner_id
               from sri_os.transaction_tags l
              where l.id = a.transaction_tag_id and a.owner_id is null';
    if exists (select 1 from sri_os.tag_allocations where owner_id is null) then
      raise exception 'เติม owner_id ให้ tag_allocations ไม่ครบ (ยังมีแถวที่หาลิงก์ไม่เจอ) → ปฏิเสธ ไม่ปล่อยให้คอลัมน์ที่กฎเหล็กข้อ 3 บังคับเป็น null · แถวกำพร้าแบบนี้เกิดไม่ได้ (FK ไป transaction_tags) ถ้าเจอแปลว่าฐานข้อมูลเสียหายและต้องตรวจมือ';
    end if;
    execute 'alter table sri_os.tag_allocations alter column owner_id set not null';
    execute 'alter table sri_os.tag_allocations
               add constraint tag_allocations_owner_id_fkey
               foreign key (owner_id) references sri_os.owners(id)';
  end if;
end $$;

comment on table tag_allocations is
  'น้ำหนักของ tag ต่อใบ (ADR 0003 ข้อ 3.2) · **ทุกแถวมี owner_id ที่เป็นสำเนาจากลิงก์ซึ่ง trigger บังคับให้ตรงเสมอและย้ายไม่ได้ (กฎเหล็กข้อ 3)** → รายงานกรอง Entity ได้ที่ตัวแถวเอง · **ตารางแยกตามที่ ADR 0002 ข้อ 4.3 สั่ง ไม่ใช่คอลัมน์ในตารางลิงก์** · ถือ **ตัวคูณ** เท่านั้น ห้ามมีคอลัมน์จำนวนเงิน (guard ไล่ numeric_scale ≠ 6) · append-only + ปิดด้วยร่องรอย ไม่มี DELETE และ weight แก้ทับไม่ได้ (กำไรต่อ project ที่รายงานไปแล้วคิดจากน้ำหนักชุดเดิม) · Σ ต่อ (ใบ × ชนิดที่ปันส่วน) = 1.000000 พอดี บังคับด้วย constraint trigger แบบ deferred บนตารางนี้ **และบนตารางลิงก์**';
comment on column tag_allocations.owner_id is
  'สำเนาของ transaction_tags.owner_id (ซึ่งเองเป็นสำเนาของ transactions.owner_id) · trigger อ่านจากลิงก์เองไม่เชื่อค่าที่ส่งมา (D-115) และปฏิเสธถ้าส่งมาไม่ตรง · ย้ายไม่ได้ · มีไว้เพื่อให้ RLS/รายงานกรอง Entity ได้โดยไม่ต้อง join ลิงก์กับใบ (กฎเหล็กข้อ 3)';
comment on column tag_allocations.weight is
  'สัดส่วน 0 < w <= 1 · numeric(9,6) → 0.600000 = 60% · **ไม่ใช่จำนวนเงิน** · w = 0 ห้ามโดยเจตนา (ติด tag ไว้แล้วบอกว่าไม่เกี่ยว = แถวที่โผล่ในรายการแต่ไม่โผล่ในยอด คนอ่านจะคิดว่าระบบลืมนับ ถ้าไม่เกี่ยวให้ถอด tag ซึ่งมีร่องรอยชัดกว่า)';
comment on column tag_allocations.transaction_tag_id is
  'ผูกกับแถวลิงก์ใน transaction_tags · ผู้ถือ/ใบ/tag อ่านผ่านลิงก์ (ไม่คัดลอกมาซ้ำเพื่อให้ไม่มีทางเพี้ยนกันสองที่) · ลิงก์ที่ถูกถอดแล้วต้องไม่มีน้ำหนักที่ยังใช้อยู่ (ด่านข้อ 3)';
comment on column tag_allocations.supersede_reason is
  'เหตุผลตอนปิดชุดน้ำหนักเดิม **บังคับ** (btrim <> '''') เหมือน untag_reason/void_reason · แก้สัดส่วนย้อนหลังแล้วกำไรที่เคยรายงานเปลี่ยนเงียบๆ = ไม่มีใครอธิบายตัวเลขเดือนที่แล้วได้';

-- ---------- ช่วงของน้ำหนัก ----------
-- idempotent แบบ "เพิ่มเฉพาะเมื่อยังไม่มี" (ไม่ใช่รูปแบบถอนก่อนใส่) เพราะไฟล์นี้
-- ห้ามมีคำสั่งถอนของแม้ในคอมเมนต์ — ตัวตรวจของ MCP apply_migration อ่านข้อความดิบ
do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'sri_os.tag_allocations'::regclass
                    and conname = 'tag_alloc_weight_range') then
    execute 'alter table sri_os.tag_allocations add constraint tag_alloc_weight_range
               check (weight > 0 and weight <= 1)';
  end if;
end $$;
comment on constraint tag_alloc_weight_range on tag_allocations is
  'ADR 0003 ข้อ 3.2 · น้ำหนักเป็นสัดส่วน ไม่ใช่จำนวนเงิน · 0 ห้าม (เหตุผลที่คอลัมน์ weight) · เกิน 1 คือสัดส่วนที่ใบเดียวให้ project เกินตัวมันเอง';

-- ---------- ปิดครึ่งเดียวไม่ได้ ----------
do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'sri_os.tag_allocations'::regclass
                    and conname = 'tag_alloc_supersede_both') then
    execute $c$alter table sri_os.tag_allocations add constraint tag_alloc_supersede_both check (
            (superseded_at is not null) = (superseded_by is not null)
        and (superseded_at is not null) = (supersede_reason is not null
                                           and btrim(supersede_reason) <> ''))$c$;
  end if;
end $$;
comment on constraint tag_alloc_supersede_both on tag_allocations is
  'มีเวลาแต่ไม่มีคน/ไม่มีเหตุผล = ร่องรอยที่อธิบายอะไรไม่ได้ · และแปะเหตุผลไว้บนน้ำหนักที่ยังใช้อยู่ก็ไม่ได้ (ดูเหมือนปิดแล้วแต่ยังเข้าวิว)';

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'sri_os.tag_allocations'::regclass
                    and conname = 'tag_alloc_supersede_order') then
    execute 'alter table sri_os.tag_allocations add constraint tag_alloc_supersede_order
               check (superseded_at is null or superseded_at >= allocated_at)';
  end if;
end $$;

-- ---------- หนึ่งลิงก์ = หนึ่งน้ำหนักที่ใช้อยู่ ----------
create unique index if not exists tag_alloc_active_uq
  on tag_allocations (transaction_tag_id) where superseded_at is null;

-- วิว/ด่านไล่จากลิงก์มาหาน้ำหนักเสมอ
create index if not exists tag_alloc_by_link
  on tag_allocations (transaction_tag_id, superseded_at);

-- รายงานทุกหน้ากรอง Entity ได้ (กฎเหล็กข้อ 3) → ต้องมี index ของผู้ถือเหมือน
-- `tag_link_by_owner` ของตารางลิงก์ ไม่ใช่ให้ไปไล่ทั้งตารางทุกครั้งที่กรองผู้ถือ
create index if not exists tag_alloc_by_owner
  on tag_allocations (owner_id, transaction_tag_id) where superseded_at is null;

-- ============================================================
-- 2 · ด่านของแถว — ตั้งค่าระบบเอง · แก้ทับไม่ได้ · ลบไม่ได้
--
-- **security definer** โดยเจตนา (เหตุผลเดียวกับ `fn_tag_link_system_columns`):
--   ต้องอ่านลิงก์/ชนิด/คอนฟิก **ตัวจริง** ไม่ใช่สิ่งที่ผู้เรียกมองเห็น · ถ้าเป็น invoker
--   แล้วผู้เรียกมองลิงก์ไม่เห็น select จะได้ 0 แถว แล้วเราจะตัดสินไม่ได้ว่า
--   "ไม่มีลิงก์" หรือ "มีแต่มองไม่เห็น" → ต้องปฏิเสธด้วยเหตุผลที่ถูก
-- **ไม่เรียก `fn_can()` หรือฟังก์ชันตรวจสิทธิ์ใดๆ** — กฎร่องรอยต้องเท่ากันทุกตำแหน่ง
--   และปิดจากหน้า Settings ไม่ได้ · ใครใส่น้ำหนักได้ = RLS ตัดสิน
-- ============================================================
create or replace function fn_tag_alloc_system_columns() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_uid     uuid := auth.uid();
  v_link    record;
begin
  -- ======================= INSERT =======================
  if tg_op = 'INSERT' then
    if new.superseded_at is not null or new.superseded_by is not null
       or new.supersede_reason is not null then
      raise exception 'สร้างน้ำหนักที่ปิดไว้แล้วตรงๆ ไม่ได้ · ร่องรอยการปิดต้องเกิดจากการปิดจริงบนแถวที่มีอยู่ (UPDATE) ไม่ใช่เขียนประวัติย้อนหลังเข้ามาทั้งก้อน';
    end if;

    -- เวลา/คนทำ = ของระบบ · ส่งมาเอง = ปฏิเสธ (ไม่ใช่ทับให้เงียบๆ ซึ่งซ่อนบั๊กของผู้เรียก)
    if v_uid is null then
      raise exception 'ใส่น้ำหนัก tag ไม่ได้: ยังไม่ได้ล็อกอิน (allocated_by มาจาก auth.uid() เท่านั้น)';
    end if;
    if new.allocated_by is not null and new.allocated_by <> v_uid then
      raise exception 'allocated_by ของน้ำหนักต้องเป็นผู้ที่ล็อกอินอยู่ (%) ไม่ใช่ % · สัดส่วนเป็นตัวเลขที่เข้าสู่รายงานเงิน ใส่ชื่อคนอื่นเป็นคนกรอกไม่ได้',
        v_uid, new.allocated_by;
    end if;
    new.allocated_by := v_uid;
    new.allocated_at := now();

    -- ลิงก์ต้องมีจริง · ยังใช้อยู่ · และเป็นชนิดที่ **ปันส่วน**
    select l.id, l.tag_kind, l.untagged_at, l.owner_id,
           k.requires_allocation, t.code as tag_code
      into v_link
      from sri_os.transaction_tags l
      join sri_os.tag_kinds k on k.key = l.tag_kind
      join sri_os.tags t      on t.id  = l.tag_id
     where l.id = new.transaction_tag_id;
    if v_link.id is null then
      raise exception 'ไม่มีลิงก์ tag id % → ใส่น้ำหนักไม่ได้ · น้ำหนักผูกกับลิงก์ ต้องติด tag ก่อนแล้วจึงใส่สัดส่วน',
        new.transaction_tag_id;
    end if;
    if v_link.untagged_at is not null then
      raise exception 'ลิงก์ tag "%" ถูกถอดไปแล้ว → ใส่น้ำหนักใหม่ไม่ได้ · ถ้าจะให้ tag นี้กลับมามีสัดส่วน ต้องติด tag ใหม่ (แถวใหม่) แล้วใส่น้ำหนักให้แถวนั้น',
        v_link.tag_code;
    end if;
    -- **ผู้ถือ = สำเนาจากลิงก์** (กฎเหล็กข้อ 3 · แพทเทิร์นเดียวกับ
    -- fn_tag_link_system_columns ที่อ่าน owner_id จากใบเอง)
    -- อ่านจากต้นทางเอง **ไม่เชื่อค่าที่ส่งมา** (D-115) · ส่งมาไม่ตรง = ปฏิเสธ
    -- ไม่ใช่ทับให้เงียบๆ: ส่งมาไม่ตรงคือสัญญาณว่าผู้เรียกเข้าใจผิดว่าสัดส่วนนี้
    -- เป็นของใคร และถ้าทับเงียบๆ บั๊กของผู้เรียกจะอยู่ต่อไปโดยไม่มีใครรู้
    if new.owner_id is not null and new.owner_id <> v_link.owner_id then
      raise exception 'ผู้ถือของน้ำหนัก (%) ไม่ตรงกับผู้ถือของลิงก์ tag (%) · owner_id ของแถวนี้เป็น **สำเนาจากลิงก์** (กฎเหล็กข้อ 3) ระบบอ่านจากลิงก์เองและไม่ทับค่าที่ส่งมาเงียบๆ — ส่งมาไม่ตรงคือสัญญาณว่าผู้เรียกเข้าใจผิดว่าใบนี้เป็นของใคร แล้วรายงานที่กรอง Entity จะนับสัดส่วนนี้ให้ผู้ถือผิดคน',
        new.owner_id, v_link.owner_id;
    end if;
    new.owner_id := v_link.owner_id;

    if not v_link.requires_allocation then
      raise exception 'ชนิด tag "%" ไม่ใช่ชนิดที่ **ปันส่วน** (tag_kinds.requires_allocation = false) → ใส่น้ำหนักให้ไม่ได้ · ยอดของชนิดนี้เป็น "ยอดที่แตะ tag" (touch) ซึ่งบวกข้าม tag ไม่ได้ · ถ้าเอาน้ำหนักมาใส่ จะมีวิวที่เอา touch ไปบวกกับ allocated แล้วไม่มีใครรู้ว่าตัวเลขไหนหมายถึงอะไร (ADR 0003 ข้อ 5) · ถ้าวันหนึ่งชนิดนี้ต้องปันส่วนจริง ให้พลิกคอนฟิกพร้อม migration ที่ backfill ไม่ใช่แอบใส่น้ำหนักให้บางใบ',
        v_link.tag_kind;
    end if;
    return new;
  end if;

  -- ======================= UPDATE =======================
  if tg_op = 'UPDATE' then
    -- **ย้ายผู้ถือไม่ได้** (กฎเหล็กข้อ 3 · เหมือน owner_id ของ transaction_tags)
    -- แยกข้อความออกมาเพราะอาการต่างกับการแก้ weight: ย้าย owner_id คือการย้าย
    -- ส่วนแบ่งของเงินก้อนหนึ่งไปอยู่กับผู้ถืออีกคน **โดยที่ยอดในสมุดไม่เปลี่ยนเลย**
    -- → รายงานต่อ Entity สองรุ่นของงวดเดียวกันจะต่างกันแบบอธิบายไม่ได้
    if new.owner_id is distinct from old.owner_id then
      raise exception 'ย้ายผู้ถือของน้ำหนัก tag ไม่ได้ (% → %) · owner_id เป็น **สำเนาจากลิงก์** ที่แช่แข็งตั้งแต่ตอนลง (กฎเหล็กข้อ 3) · ถ้าสัดส่วนนี้ควรเป็นของผู้ถืออีกคน แปลว่ามันผูกกับลิงก์ผิดใบ ให้ปิดชุดนี้ด้วยเหตุผลแล้วใส่น้ำหนักให้ลิงก์ของใบที่ถูก ไม่ใช่ย้ายผู้ถือของแถวเดิมซึ่งไม่เหลือร่องรอยว่าเคยนับให้ใคร',
        old.owner_id, new.owner_id;
    end if;

    if new.id <> old.id
       or new.transaction_tag_id <> old.transaction_tag_id
       or new.weight <> old.weight
       or new.allocated_at <> old.allocated_at
       or new.allocated_by <> old.allocated_by then
      raise exception 'แก้น้ำหนักทับไม่ได้ (weight % → % · ลิงก์/เวลา/คนกรอกก็แช่แข็ง) · การแก้สัดส่วนย้อนหลังคือ **ปิดแถวเดิม (superseded_*) แล้ว insert แถวใหม่ในธุรกรรมเดียว** ผ่านประตู sri_os.fn_reallocate_tags(...) · เหตุผลเดียวกับกฎเหล็กข้อ 1: กำไรต่อ project ที่รายงานไปแล้วคิดจากน้ำหนักชุดเดิม ถ้าแก้ทับโดยไม่มีร่องรอยจะไม่มีใครอธิบายได้ว่าทำไมตัวเลขเดือนที่แล้วเปลี่ยน',
        old.weight, new.weight;
    end if;

    -- ปิดแล้วแช่แข็ง (แพทเทิร์น fn_void_audit_columns)
    if old.superseded_at is not null then
      if new.superseded_at is distinct from old.superseded_at
         or new.superseded_by is distinct from old.superseded_by
         or new.supersede_reason is distinct from old.supersede_reason then
        raise exception 'น้ำหนักแถวนี้ถูกปิดไปแล้วเมื่อ % → ร่องรอยการปิดแก้ย้อนหลังไม่ได้',
          old.superseded_at;
      end if;
      return new;
    end if;

    -- เปิดอยู่ → ยอมแค่ "ปิด" และคนปิดต้องเป็นผู้ที่ล็อกอินอยู่
    if new.superseded_at is null then
      raise exception 'UPDATE บน tag_allocations มีไว้เพื่อ **ปิดชุดน้ำหนักเดิม** เท่านั้น (ต้องเติม superseded_at/by/reason ให้ครบ)';
    end if;
    if v_uid is null then
      raise exception 'ปิดชุดน้ำหนักไม่ได้: ยังไม่ได้ล็อกอิน (superseded_by มาจาก auth.uid() เท่านั้น)';
    end if;
    if new.superseded_by is not null and new.superseded_by <> v_uid then
      raise exception 'superseded_by ต้องเป็นผู้ที่ล็อกอินอยู่ (%) ไม่ใช่ %', v_uid, new.superseded_by;
    end if;
    new.superseded_by := v_uid;
    return new;
  end if;

  return new;
end $fn$;

comment on function fn_tag_alloc_system_columns() is
  'ADR 0003 ข้อ 3.2/3.3 · ตั้ง allocated_at/by จาก auth.uid() (ปลอมไม่ได้) · **owner_id อ่านจาก transaction_tags.owner_id เอง ไม่รับจากผู้เรียก ส่งมาไม่ตรง = ปฏิเสธ และย้ายย้อนหลังไม่ได้ (กฎเหล็กข้อ 3)** · weight/ลิงก์/เวลา/คนกรอก **แช่แข็ง** (แก้สัดส่วน = ปิด + เปิดใหม่ผ่าน fn_reallocate_tags) · UPDATE ยอมแค่การปิด และปิดแล้วแช่แข็ง · น้ำหนักติดได้เฉพาะลิงก์ที่ยังใช้อยู่ของชนิดที่ requires_allocation (อ่านจากคอนฟิก ไม่ใช่ชื่อ project ในโค้ด) · ไม่เรียกฟังก์ชันตรวจสิทธิ์เลย — ใครใส่ได้เป็นเรื่องของ RLS กฎร่องรอยต้องเท่ากันทุกตำแหน่ง';

revoke all on function fn_tag_alloc_system_columns() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_tag_alloc_system_columns() from anon, authenticated';
exception when undefined_object then null;
end $$;

do $$
begin
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.tag_allocations'::regclass
                    and g.tgname = 'trg_tag_alloc_system_columns' and not g.tgisinternal) then
    execute 'create trigger trg_tag_alloc_system_columns
               before insert or update on sri_os.tag_allocations
               for each row execute function sri_os.fn_tag_alloc_system_columns()';
  end if;
end $$;

-- ---------- ลบไม่ได้ทุกทาง (กันถึงเจ้าของฐานข้อมูล · กฎเหล็กข้อ 1) ----------
create or replace function fn_tag_alloc_no_delete() returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  raise exception 'ลบน้ำหนักของ tag ไม่ได้ (ลิงก์ % · น้ำหนัก %) · การแก้สัดส่วนคือ **ปิดแถวเดิมด้วย superseded_at/by/reason แล้ว insert แถวใหม่** ผ่าน sri_os.fn_reallocate_tags(...) · ถ้าลบได้ กำไรต่อ project ที่รายงานไปแล้วจะอธิบายไม่ได้เลยว่าคิดจากสัดส่วนชุดไหน (กฎเหล็กข้อ 1)',
    old.transaction_tag_id, old.weight;
end $fn$;

comment on function fn_tag_alloc_no_delete() is
  'กันการลบน้ำหนักถึงระดับ trigger (ไม่ใช่แค่ไม่มี policy DELETE) · เหตุผลเดียวกับ fn_tag_link_no_delete ของ ADR 0002';

revoke all on function fn_tag_alloc_no_delete() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_tag_alloc_no_delete() from anon, authenticated';
exception when undefined_object then null;
end $$;

do $$
begin
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.tag_allocations'::regclass
                    and g.tgname = 'trg_tag_alloc_no_delete' and not g.tgisinternal) then
    execute 'create trigger trg_tag_alloc_no_delete
               before delete on sri_os.tag_allocations
               for each row execute function sri_os.fn_tag_alloc_no_delete()';
  end if;
end $$;

-- ============================================================
-- 3 · **ด่าน Σ น้ำหนัก = 1.000000 พอดี** (ADR 0003 ข้อ 4.1)
-- ============================================================
create or replace function fn_assert_tag_allocation_complete() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_txn    uuid;
  v_kind   text;
  v_sum    numeric;
  v_list   text;
  v_miss   text;
  v_orphan text;
begin
  -- ---------- ใบที่ต้องตรวจ ----------
  if tg_table_name = 'tag_allocations' then
    select l.transaction_id into v_txn
      from sri_os.transaction_tags l
     where l.id = coalesce(new.transaction_tag_id, old.transaction_tag_id);
  else
    v_txn := coalesce(new.transaction_id, old.transaction_id);
  end if;
  if v_txn is null then
    return null;   -- ลิงก์/ใบหายไปแล้ว → ไม่มีอะไรให้ตรวจ
  end if;

  -- ---------- (3) แถวกำพร้า: น้ำหนักที่ยังใช้อยู่บนลิงก์ที่ถูกถอดไปแล้ว ----------
  select string_agg(t.code || ' = ' || a.weight::text, ' · ' order by t.code) into v_orphan
    from sri_os.tag_allocations a
    join sri_os.transaction_tags l on l.id = a.transaction_tag_id
    join sri_os.tags t on t.id = l.tag_id
   where l.transaction_id = v_txn
     and a.superseded_at is null
     and l.untagged_at is not null;
  if v_orphan is not null then
    raise exception 'ใบนี้มี **น้ำหนักที่ยังใช้อยู่ค้างบน tag ที่ถูกถอดไปแล้ว**: % · ถอด tag ต้องปิดน้ำหนักของมันในธุรกรรมเดียวกัน (superseded_at/by/reason) ไม่งั้นแถวกำพร้าจะยังเข้าวิวที่ปันส่วนแล้ว แล้วยอดต่อ project จะรวมส่วนแบ่งของ tag ที่ไม่ได้ติดอยู่อีกต่อไป (ADR 0003 ข้อ 4.1 ข้อย่อย 3)',
      v_orphan;
  end if;

  -- ---------- ไล่ทุกชนิดที่ปันส่วนและมีลิงก์ที่ยังใช้อยู่บนใบนี้ ----------
  for v_kind in
    select distinct l.tag_kind
      from sri_os.transaction_tags l
      join sri_os.tag_kinds k on k.key = l.tag_kind
     where l.transaction_id = v_txn
       and l.untagged_at is null
       and k.requires_allocation
  loop
    -- ---------- (1) ทุกลิงก์ที่ยังใช้อยู่ต้องมีน้ำหนักที่ยังใช้อยู่ ----------
    select string_agg(t.code, ' · ' order by t.code) into v_miss
      from sri_os.transaction_tags l
      join sri_os.tags t on t.id = l.tag_id
     where l.transaction_id = v_txn
       and l.tag_kind = v_kind
       and l.untagged_at is null
       and not exists (select 1 from sri_os.tag_allocations a
                        where a.transaction_tag_id = l.id and a.superseded_at is null);
    if v_miss is not null then
      raise exception 'ใบนี้ติด tag ชนิด "%" ไว้แต่ **ยังไม่ได้ใส่น้ำหนัก** ให้: % · ชนิดนี้ตั้งค่าไว้ว่าต้องปันส่วน (tag_kinds.requires_allocation) จึงต้องรู้ว่าแต่ละ tag ได้ส่วนแบ่งเท่าไร · ข้อมูลไม่ครบต้อง **ปฏิเสธ** ไม่ใช่เดาให้เป็น 100%% หรือแบ่งเท่ากันเอง เพราะเดาผิดแปลว่ายอดต่อ project ผิดเงียบๆ · ถ้าใบนี้ควรเป็นของ tag เดียวทั้งก้อน ให้ส่งน้ำหนัก 1.000000 มาตรงๆ (ประตู fn_post_entry เติมให้เองได้เฉพาะกรณีที่ติดอันเดียวบนใบนั้น ซึ่งมีคำตอบที่ถูกได้คำตอบเดียว)',
        v_kind, v_miss;
    end if;

    -- ---------- (2) Σ = 1.000000 พอดี (exact · ไม่มี tolerance) ----------
    select sum(a.weight),
           string_agg(t.code || ' = ' || to_char(a.weight, 'FM0.000000'), ' · ' order by t.code)
      into v_sum, v_list
      from sri_os.tag_allocations a
      join sri_os.transaction_tags l on l.id = a.transaction_tag_id
      join sri_os.tags t on t.id = l.tag_id
     where l.transaction_id = v_txn
       and l.tag_kind = v_kind
       and l.untagged_at is null
       and a.superseded_at is null;

    if v_sum is distinct from 1.000000::numeric then
      raise exception 'ยอดรวมน้ำหนักของ tag ชนิด "%" บนใบนี้เป็น % ซึ่งต้องเป็น 1.000000 พอดี (% ไป %) · น้ำหนักปัจจุบัน: % · ถ้า Σ ไม่เท่า 1 ยอดที่ปันส่วนของทุก tag จะไม่เท่ากับยอดในสมุด (Σ น้อยกว่า 1 = เงินหายไปจากทุกรายงานต่อ project · Σ มากกว่า 1 = กำไรที่ไม่จริงออกมา) **โดยที่งบดุลยังดุลสนิทและไม่มีตัวเลขในสมุดผิดเลย** จึงไม่มีด่านอื่นจับได้ (ADR 0003 ข้อ 4.1)',
        v_kind,
        to_char(coalesce(v_sum, 0), 'FM0.000000'),
        case when coalesce(v_sum, 0) < 1 then 'ขาด' else 'เกิน' end,
        to_char(abs(coalesce(v_sum, 0) - 1), 'FM0.000000'),
        coalesce(v_list, '(ยังไม่มีน้ำหนักเลย)');
    end if;
  end loop;

  return null;
end $fn$;

comment on function fn_assert_tag_allocation_complete() is
  'ADR 0003 ข้อ 4.1 · ต่อ (ใบ × ชนิดที่ requires_allocation): ทุกลิงก์ที่ยังใช้อยู่ต้องมีน้ำหนักที่ยังใช้อยู่ · sum(weight) = 1.000000 **พอดี** (exact ไม่มี tolerance เพราะ numeric เป็นทศนิยมแม่นตรงและน้ำหนักเป็นค่าที่คนกรอก) · ไม่มีน้ำหนักค้างบนลิงก์ที่ถอดแล้ว · ผูกเป็น constraint trigger แบบ deferred **ทั้งบน tag_allocations และบน transaction_tags** — ถ้าผูกแต่ตารางแรก การติด project แล้วไม่ใส่น้ำหนักเลยจะผ่านเงียบและยอดของใบนั้นหายไปจากทุกรายงานต่อ project · ข้อความบอกยอดที่ขาด/เกินและรายชื่อ tag พร้อมน้ำหนักปัจจุบันเสมอ';

-- definer ที่อ่านตารางที่จัดประเภทเป็น row → เรียกตรงไม่ได้ทุก role (D-089)
revoke all on function fn_assert_tag_allocation_complete() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_tag_allocation_complete() from anon, authenticated';
exception when undefined_object then null;
end $$;

do $$
begin
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.tag_allocations'::regclass
                    and g.tgname = 'trg_assert_tag_allocation_complete'
                    and not g.tgisinternal) then
    execute 'create constraint trigger trg_assert_tag_allocation_complete
               after insert or update or delete on sri_os.tag_allocations
               deferrable initially deferred
               for each row execute function sri_os.fn_assert_tag_allocation_complete()';
  end if;

  -- **ตัวที่สำคัญที่สุด**: ติด tag ชนิดที่ปันส่วนแล้วไม่ใส่น้ำหนักเลย ต้องไม่ผ่านเงียบ
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.transaction_tags'::regclass
                    and g.tgname = 'trg_assert_tag_allocation_links'
                    and not g.tgisinternal) then
    execute 'create constraint trigger trg_assert_tag_allocation_links
               after insert or update on sri_os.transaction_tags
               deferrable initially deferred
               for each row execute function sri_os.fn_assert_tag_allocation_complete()';
  end if;
end $$;

-- ============================================================
-- 4 · RLS — ขอบเขตเดียวกับลิงก์และสมุด **ด้วยฟังก์ชันตัวเดียวกัน**
--
-- อ่าน: `fn_can_read_txn` ตัวเดียวกับ `transactions_by_owner` / `tag_links_by_txn`
--   **ไม่เขียนกฎขอบเขตซ้ำที่นี่** (บทเรียน mace-windu ข้อ 5) · ทางเดียวที่สอง
--   ตารางเพี้ยนกันไม่ได้คือเรียกฟังก์ชันเดียวกัน
--   ทำไมต้องแคบเท่าใบ ไม่ใช่แค่ `fn_can_see_owner`: น้ำหนัก + ยอดที่เห็นจากที่อื่น
--   = ยอดของ project · และ `supersede_reason` เป็นข้อความที่คนเขียนถึงใบใดใบหนึ่ง
--
-- เขียน: insert = `tag.assign` + ขอบเขต (สิทธิ์เดียวกับการติด tag — น้ำหนักเป็นส่วนหนึ่ง
--   ของการติด tag ชนิดที่ปันส่วน ไม่ใช่สิทธิ์ใหม่) · update = **ปิดได้ทางเดียว** ·
--   **delete: ไม่มี policy เลย**
-- ============================================================
alter table tag_allocations enable row level security;

do $$
begin
  if not exists (select 1 from pg_policy p
                  where p.polrelid = 'sri_os.tag_allocations'::regclass
                    and p.polname = 'tag_allocs_by_txn') then
    execute $p$
      create policy tag_allocs_by_txn on sri_os.tag_allocations
        for select to authenticated
        using (exists (
          select 1 from sri_os.transaction_tags l
            join sri_os.transactions t on t.id = l.transaction_id
           where l.id = transaction_tag_id
             and sri_os.fn_can_read_txn(t.owner_id, t.asset_id, t.created_by)))
    $p$;
  end if;

  if not exists (select 1 from pg_policy p
                  where p.polrelid = 'sri_os.tag_allocations'::regclass
                    and p.polname = 'tag_allocs_insert') then
    execute $p$
      create policy tag_allocs_insert on sri_os.tag_allocations
        for insert to authenticated
        with check (
          sri_os.fn_can('tag.assign')
          -- สำเนาผู้ถือบนแถวต้องอยู่ในขอบเขตของผู้เรียก **จากตัวแถวเอง**
          -- (เหมือน policy tag_links_insert ของ transaction_tags) · RLS ตรวจ
          -- หลัง BEFORE trigger เติมค่าให้แล้ว → ค่าที่ถูกตรวจคือค่าที่อ่านจากลิงก์
          and sri_os.fn_can_see_owner(owner_id)
          and exists (
            select 1 from sri_os.transaction_tags l
              join sri_os.transactions t on t.id = l.transaction_id
             where l.id = transaction_tag_id
               and sri_os.fn_can_see_owner(t.owner_id)
               and sri_os.fn_can_read_txn(t.owner_id, t.asset_id, t.created_by)))
    $p$;
  end if;

  -- UPDATE มีไว้เพื่อ "ปิดชุดเดิม" เท่านั้น: using = แถวต้องยังใช้อยู่ ·
  -- with check = แถวหลังแก้ต้องถูกปิดแล้ว → ชั้น RLS เองก็ยอมแค่การปิด
  if not exists (select 1 from pg_policy p
                  where p.polrelid = 'sri_os.tag_allocations'::regclass
                    and p.polname = 'tag_allocs_supersede') then
    execute $p$
      create policy tag_allocs_supersede on sri_os.tag_allocations
        for update to authenticated
        using (
          sri_os.fn_can('tag.assign')
          and superseded_at is null
          and exists (
            select 1 from sri_os.transaction_tags l
              join sri_os.transactions t on t.id = l.transaction_id
             where l.id = transaction_tag_id
               and sri_os.fn_can_read_txn(t.owner_id, t.asset_id, t.created_by)))
        with check (
          sri_os.fn_can('tag.assign')
          and superseded_at is not null
          and exists (
            select 1 from sri_os.transaction_tags l
              join sri_os.transactions t on t.id = l.transaction_id
             where l.id = transaction_tag_id
               and sri_os.fn_can_read_txn(t.owner_id, t.asset_id, t.created_by)))
    $p$;
  end if;
end $$;

-- ชั้น GRANT: DML สี่ตัวต้องครบเหมือนตารางอื่น · ตัวที่กันการลบจริงคือ trigger + ไม่มี policy
grant select, insert, update, delete on tag_allocations to authenticated;
do $$
begin
  execute 'revoke all on table sri_os.tag_allocations from anon';
exception when undefined_object then null;
end $$;

-- ============================================================
-- 5 · ร่องรอย + ห้าม TRUNCATE
--     TRUNCATE ไม่ยิง row trigger → ล้างน้ำหนักทั้งตารางได้ในคำสั่งเดียว
--     แล้วทุกใบจะกลายเป็น "ติด project แต่ไม่มีน้ำหนัก" พร้อมกันทั้งสมุด
-- ============================================================
do $$
begin
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.tag_allocations'::regclass
                    and g.tgname = 'trg_audit_tag_allocations' and not g.tgisinternal) then
    execute 'create trigger trg_audit_tag_allocations
               after insert or update or delete on sri_os.tag_allocations
               for each row execute function sri_os.fn_audit()';
  end if;
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.tag_allocations'::regclass
                    and g.tgname = 'trg_forbid_truncate' and not g.tgisinternal) then
    execute 'create trigger trg_forbid_truncate
               before truncate on sri_os.tag_allocations
               for each statement execute function sri_os.fn_forbid_truncate()';
  end if;
end $$;

-- ============================================================
-- 6 · ด่านคอลัมน์ (D-089)
--     ทุกคอลัมน์เป็น `row` + `ledger.read` เหมือน `transaction_tags`
--     **ไม่มีคอลัมน์ไหนเป็น `open`**: สัดส่วนของใบ + ยอดที่เห็นจากที่อื่น = ยอดของ project
-- ============================================================
insert into column_exposure_tables (table_name, review_state, reason) values
  ('tag_allocations', 'classified',
   'น้ำหนักของ tag ต่อใบ (ADR 0003) · แถวถูกกรองด้วย fn_can_read_txn ตัวเดียวกับหัวรายการ บรรทัดบัญชี และลิงก์ tag (เขียนที่เดียวเพื่อให้ขอบเขตเพี้ยนกันไม่ได้) · ไม่มีคอลัมน์จำนวนเงิน มีแต่ตัวคูณ numeric(9,6) ตัวเดียว (guard ไล่ numeric_scale)')
on conflict (table_name) do update
  set review_state = excluded.review_state, reason = excluded.reason;

insert into column_exposure (table_name, column_name, exposure, min_permission, rationale)
select 'tag_allocations', c, 'row', 'ledger.read', t.why
  from (values
    (array['id', 'transaction_tag_id', 'owner_id', 'weight'],
     'สัดส่วนที่ใบหนึ่งถูกแบ่งให้แต่ละ project · ไม่ใช่จำนวนเงินแต่เป็น **ตัวคูณของจำนวนเงิน** → ใครอ่านค่านี้พร้อมยอดของใบ ก็อ่านยอดของ project ได้ · owner_id เป็นสำเนาจากลิงก์ที่ trigger บังคับ มีไว้ให้รายงานกรอง Entity ได้ที่ตัวแถวเอง (กฎเหล็กข้อ 3) และบอกว่าเงินก้อนนี้เป็นของผู้ถือใด · ต้องมี ledger.read + ขอบเขตของใบ (fn_can_read_txn) ถึงจะเห็น'),
    (array['allocated_at', 'allocated_by', 'superseded_at', 'superseded_by', 'supersede_reason'],
     'ร่องรอยการตั้ง/แก้สัดส่วน (ใคร เมื่อไหร่ ทำไม) · supersede_reason เป็นข้อความที่ผู้ใช้เขียนถึงใบใดใบหนึ่งและมักอ้างยอด/ช่วงเวลา → ใช้สิทธิ์เดียวกับแถวที่มันอธิบาย')
  ) as t(cols, why), unnest(t.cols) c
on conflict (table_name, column_name) do update
  set exposure = excluded.exposure, min_permission = excluded.min_permission,
      rationale = excluded.rationale;

select fn_apply_column_exposure();

-- ============================================================
-- 7 · guard ท้ายไฟล์ — ดังตอน migrate ไม่ใช่ตอนผู้ใช้กด
-- ============================================================
do $$
declare v text; n int;
begin
  if to_regclass('sri_os.tag_allocations') is null then
    raise exception 'ตาราง tag_allocations ไม่ถูกสร้าง';
  end if;

  -- (ก) **ห้ามมีคอลัมน์จำนวนเงิน** — ยอมเฉพาะตัวเลขที่ scale = 6 (ADR 0003 ข้อ 3.2)
  select string_agg(c.column_name || ' (' || c.data_type
                    || ' scale ' || coalesce(c.numeric_scale::text, '-') || ')', ', '), count(*)
    into v, n
    from information_schema.columns c
   where c.table_schema = 'sri_os' and c.table_name = 'tag_allocations'
     and c.data_type in ('numeric', 'money', 'double precision', 'real')
     and (c.numeric_scale is distinct from 6);
  if n > 0 then
    raise exception 'tag_allocations มีคอลัมน์ตัวเลขที่ scale ≠ 6 จำนวน % คอลัมน์: % · ตารางนี้ถือ **ตัวคูณ** เท่านั้น จำนวนเงินมาจากสมุดเสมอ · ถ้ามีคอลัมน์จำนวนเงินมาอยู่ที่นี่ จะมีคนกรอกยอดเองแล้วยอดต่อ project ไม่ตรงกับสมุดโดยไม่มีด่านไหนฟ้อง (ADR 0003 ข้อ 3.2)',
      n, v;
  end if;
  if not exists (select 1 from information_schema.columns c
                  where c.table_schema = 'sri_os' and c.table_name = 'tag_allocations'
                    and c.column_name = 'weight' and c.data_type = 'numeric'
                    and c.numeric_precision = 9 and c.numeric_scale = 6) then
    raise exception 'คอลัมน์ weight ต้องเป็น numeric(9,6) · scale 6 คือสิ่งที่ guard ข้อ (ก) ใช้แยกตัวคูณออกจากจำนวนเงิน — เปลี่ยน scale ต้องแก้ guard พร้อมกัน';
  end if;

  -- (ก2) **ทุกแถวมี owner_id** (กฎเหล็กข้อ 3) — คอลัมน์ not null + FK ไปที่ owners
  if not exists (select 1 from information_schema.columns c
                  where c.table_schema = 'sri_os' and c.table_name = 'tag_allocations'
                    and c.column_name = 'owner_id'
                    and c.data_type = 'uuid' and c.is_nullable = 'NO') then
    raise exception 'tag_allocations ไม่มีคอลัมน์ owner_id แบบ uuid not null → ละเมิดกฎเหล็กข้อ 3 ("ทุกแถวมี owner_id และรายงานทุกหน้ากรอง Entity ได้") · ตารางนี้คือตารางที่รายงานเงินพึ่งพาโดยตรง (ตัวคูณของยอดต่อ Entity) การ join ผ่านลิงก์ไม่ใช่ข้อยกเว้นที่กฎเหล็กเจาะให้';
  end if;
  if not exists (select 1 from pg_constraint con
                  where con.conrelid = 'sri_os.tag_allocations'::regclass
                    and con.contype = 'f'
                    and con.confrelid = 'sri_os.owners'::regclass
                    and con.conkey = array[(select a.attnum from pg_attribute a
                                             where a.attrelid = con.conrelid
                                               and a.attname = 'owner_id')]) then
    raise exception 'owner_id ของ tag_allocations ไม่มี FK ไปที่ owners → ชี้ผู้ถือที่ไม่มีตัวตนได้';
  end if;
  if not exists (select 1 from pg_index x join pg_class i on i.oid = x.indexrelid
                  where x.indrelid = 'sri_os.tag_allocations'::regclass
                    and i.relname = 'tag_alloc_by_owner') then
    raise exception 'ไม่มี index tag_alloc_by_owner → การกรอง Entity ของรายงานต้องไล่ทั้งตาราง (กฎเหล็กข้อ 3 บังคับให้กรองได้ ไม่ใช่กรองได้แบบช้าจนไม่มีใครใช้)';
  end if;
  -- สำเนาต้องตรงกับต้นทางทุกแถว **เดี๋ยวนี้** (ไม่ใช่เชื่อว่า trigger ทำงานถูก)
  select count(*) into n
    from sri_os.tag_allocations a
    join sri_os.transaction_tags l on l.id = a.transaction_tag_id
   where a.owner_id is distinct from l.owner_id;
  if n > 0 then
    raise exception 'มี % แถวใน tag_allocations ที่ owner_id ไม่ตรงกับผู้ถือของลิงก์ → สำเนาเพี้ยนจากต้นทาง แปลว่ารายงานที่กรอง Entity นับสัดส่วนให้ผู้ถือผิดคน', n;
  end if;

  -- (ข) constraint + index ตาม ADR 0003 ข้อ 3.2
  select string_agg(x.want, ', ') into v
    from (values ('tag_alloc_weight_range'), ('tag_alloc_supersede_both'),
                 ('tag_alloc_supersede_order')) x(want)
   where not exists (select 1 from pg_constraint con
                      where con.conrelid = 'sri_os.tag_allocations'::regclass
                        and con.conname = x.want and con.convalidated);
  if v is not null then
    raise exception 'constraint ของน้ำหนัก tag หายไป/ยังไม่ validate: %', v;
  end if;
  if not exists (select 1 from pg_index x join pg_class i on i.oid = x.indexrelid
                  where x.indrelid = 'sri_os.tag_allocations'::regclass
                    and i.relname = 'tag_alloc_active_uq'
                    and x.indisunique and x.indpred is not null) then
    raise exception 'tag_alloc_active_uq ไม่ใช่ partial unique index · ไม่ unique = ลิงก์เดียวมีน้ำหนักที่ใช้อยู่สองแถวแล้ว Σ เพี้ยนทันที · ไม่มี predicate = แก้สัดส่วนย้อนหลังไม่ได้ตลอดกาล (ชุดเดิมที่ปิดแล้วจะกันชุดใหม่)';
  end if;

  -- (ค) ด่าน Σ = 1 ต้องผูก **ทั้งสองตาราง** แบบ deferrable initially deferred
  select string_agg(x.rel || '.' || x.trg, ', ') into v
    from (values ('tag_allocations',  'trg_assert_tag_allocation_complete'),
                 ('transaction_tags', 'trg_assert_tag_allocation_links')) x(rel, trg)
   where not exists (select 1 from pg_trigger g join pg_proc p on p.oid = g.tgfoid
                      where g.tgrelid = ('sri_os.' || x.rel)::regclass
                        and g.tgname = x.trg
                        and p.proname = 'fn_assert_tag_allocation_complete'
                        and g.tgdeferrable and g.tginitdeferred and not g.tgisinternal);
  if v is not null then
    raise exception 'ด่าน Σ น้ำหนัก = 1 ไม่ได้ผูกครบ/ไม่ deferred: % · ขาดตัวบน transaction_tags = ติด project แล้วไม่ใส่น้ำหนักเลยจะผ่านเงียบ แล้วยอดของใบนั้นหายไปจากทุกรายงานต่อ project โดยไม่มีตัวเลขไหนโป่งให้สังเกต (เปิดฟีเจอร์ครึ่งเดียวอันตรายกว่าไม่เปิด)', v;
  end if;

  -- (ง) trigger ของแถวครบ + ไม่มี policy DELETE + RLS เปิด
  select string_agg(x.want, ', ') into v
    from (values ('trg_tag_alloc_system_columns'), ('trg_tag_alloc_no_delete'),
                 ('trg_audit_tag_allocations'), ('trg_forbid_truncate')) x(want)
   where not exists (select 1 from pg_trigger g
                      where g.tgrelid = 'sri_os.tag_allocations'::regclass
                        and g.tgname = x.want and not g.tgisinternal);
  if v is not null then raise exception 'trigger หายไปจาก tag_allocations: %', v; end if;

  select string_agg(p.polname || '/' || p.polcmd::text, ', ') into v
    from pg_policy p
   where p.polrelid = 'sri_os.tag_allocations'::regclass and p.polcmd in ('d', '*');
  if v is not null then
    raise exception 'มี policy DELETE/ALL บน tag_allocations (%) — ต้องไม่มีเลย · แก้สัดส่วนด้วยการปิด + เปิดใหม่เท่านั้น', v;
  end if;
  if not (select c.relrowsecurity from pg_class c where c.oid = 'sri_os.tag_allocations'::regclass) then
    raise exception 'RLS ของ tag_allocations ยังปิดอยู่ = ไม่มีด่านเลย (grants ให้ DML ครบทุกตาราง)';
  end if;

  select string_agg(x.want, ', ') into v
    from (values ('tag_allocs_by_txn'), ('tag_allocs_insert'), ('tag_allocs_supersede')) x(want)
   where not exists (select 1 from pg_policy p
                      where p.polrelid = 'sri_os.tag_allocations'::regclass
                        and p.polname = x.want);
  if v is not null then raise exception 'policy ของ tag_allocations หายไป: %', v; end if;

  if not sri_os.fn_policy_requires_permission('tag_allocations', 'ledger.read') then
    raise exception 'policy อ่านของ tag_allocations ไม่ได้บังคับ ledger.read ทุกตัว → สัดส่วนของใบเปิดกว้างกว่าใบที่มันอธิบาย (น้ำหนัก + ยอดที่เห็นจากที่อื่น = ยอดของ project)';
  end if;

  -- (จ) ด่านของแถวต้องไม่เรียกฟังก์ชันตรวจสิทธิ์ (กฎร่องรอยห้ามปิดจากหน้า Settings)
  v := pg_get_functiondef('sri_os.fn_tag_alloc_system_columns()'::regprocedure);
  if v ~ '\mfn_can\M' or v ~ 'fn_is_management' then
    raise exception 'ด่านของน้ำหนัก tag เรียกฟังก์ชันตรวจสิทธิ์ → ปลดกฎร่องรอยได้ด้วยการแก้ตารางสิทธิ์ · ใครใส่น้ำหนักได้เป็นเรื่องของ RLS';
  end if;
  -- และต้องอ่าน **ผู้ถือจากลิงก์เอง** ไม่ใช่เชื่อค่าที่ส่งมา (กฎเหล็กข้อ 3 · D-115)
  if v !~ 'from sri_os\.transaction_tags' or v !~ '\mowner_id\M' then
    raise exception 'ด่านของน้ำหนัก tag ไม่ได้อ่าน owner_id จาก sri_os.transaction_tags → มีไฟล์อื่นเขียนทับหลังไฟล์นี้ · ถ้าเชื่อค่าที่ส่งมา แถวน้ำหนักจะชี้ผู้ถือผิดได้ทั้งที่ FK ผ่าน แล้วรายงานที่กรอง Entity จะนับส่วนแบ่งให้ผู้ถือผิดคนโดยไม่มีตัวเลขไหนในสมุดผิดเลย (กฎเหล็กข้อ 3)';
  end if;
  -- และต้องอ่านคอนฟิก "ชนิดไหนปันส่วน" จากตาราง ไม่ใช่เทียบชื่อ 'project' ในโค้ด
  if v !~ 'requires_allocation' then
    raise exception 'ด่านของน้ำหนัก tag ไม่ได้อ่าน tag_kinds.requires_allocation → มีไฟล์อื่นเขียนทับหลังไฟล์นี้ · ถ้าตัดสินจากชื่อชนิดที่พิมพ์ในโค้ด การเปลี่ยนคอนฟิกวันหน้าจะไม่มีผล (กฎเหล็กข้อ 5)';
  end if;
  v := pg_get_functiondef('sri_os.fn_assert_tag_allocation_complete()'::regprocedure);
  if v !~ 'requires_allocation' then
    raise exception 'ด่าน Σ น้ำหนัก ไม่ได้อ่าน tag_kinds.requires_allocation → จะครอบผิดชนิด';
  end if;
  -- ด่านนี้ห้ามเขียนสมุด (ADR 0002 ข้อ 5 ข้อ 5 ขยายมาถึงน้ำหนัก)
  if v ~* '(insert\s+into|update|delete\s+from)\s+(sri_os\.)?"?transaction(s|_lines)"?' then
    raise exception 'ด่าน Σ น้ำหนัก เขียน transactions/transaction_lines → น้ำหนัก tag ต้องแตะตัวเลขในงบไม่ได้เชิงโครงสร้าง';
  end if;

  -- (ฉ) ด่านคอลัมน์ไม่มีของค้าง และติดจริง
  select string_agg(u.object_name || ': ' || u.problem, ' · ') into v
    from sri_os.fn_column_exposure_unclassified() u
   where u.object_name like 'tag_allocations%';
  if v is not null then
    raise exception 'ด่านคอลัมน์ยังมีของค้างจาก tag_allocations (D-089): %', v;
  end if;
  select string_agg(b.object_name || ': ' || b.problem, ' · ') into v
    from sri_os.fn_column_exposure_breaches() b
   where b.object_name like 'tag_allocations%';
  if v is not null then
    raise exception 'ด่านคอลัมน์ของ tag_allocations ไม่ติดจริง: %', v;
  end if;

  -- (ช) ตารางลิงก์ต้องยังไม่มีคอลัมน์ตัวเลขเงิน (ย้ำว่าไฟล์นี้ไม่ได้เติมเข้าไปที่นั่น)
  select count(*) into n
    from information_schema.columns c
   where c.table_schema = 'sri_os' and c.table_name = 'transaction_tags'
     and c.data_type in ('numeric', 'money', 'double precision', 'real');
  if n > 0 then
    raise exception 'transaction_tags มีคอลัมน์ตัวเลขเงิน/สัดส่วน % คอลัมน์ · น้ำหนักต้องอยู่ใน tag_allocations ตารางแยกเท่านั้น (ADR 0002 ข้อ 4.3)', n;
  end if;

  raise notice 'ok · ตารางน้ำหนัก tag พร้อม: ทุกแถวมี owner_id ที่เป็นสำเนาจากลิงก์และย้ายไม่ได้ (กฎเหล็กข้อ 3) · ถือแต่ตัวคูณ numeric(9,6) ตัวเดียว · 0 < w <= 1 · append-only (แก้ทับ/ลบไม่ได้) · ปิดต้องมีเหตุผล · หนึ่งลิงก์หนึ่งน้ำหนักที่ใช้อยู่ · ด่าน Σ = 1.000000 พอดี ผูกทั้ง tag_allocations และ transaction_tags แบบ deferred · RLS ใช้ fn_can_read_txn ตัวเดียวกับสมุด';
end $$;
