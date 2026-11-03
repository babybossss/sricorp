-- ============================================================
-- SRI OS · ล้างยอดค้างเกินไม่ได้ **แม้คำขอมาถึงพร้อมกัน** (ปิดรูที่ผู้ตรวจวัดได้)
--
-- **รูที่ปิด**
--   เส้นทางล้างของค้าง (`src/app/actions/confirm-cash.ts`) กันล้างซ้ำสามชั้น
--   แต่ทั้งสามชั้นเป็น **"อ่านก่อนเขียน"** จึงแพ้จังหวะพร้อมกันทั้งชุด:
--     คำขอล้าง 7,000 กับ 6,000 บนของค้าง 12,000 มาถึงพร้อมกัน
--     → ทั้งคู่อ่านยอดคงเหลือเห็น 12,000 → ผ่าน engine ทั้งคู่
--     → ล้างไป 13,000 · **ลูกหนี้ติดลบ 1,000** · เงินสดไม่ตรง statement
--   fingerprint ไม่จับ (payload ต่างกัน) · `expectedClearedCount` ไม่จับ
--   (ทั้งคู่อ่านค่าเดิมคือ 0) · `buildClearing()` ไม่จับ (ประวัติที่อ่านมายังว่าง)
--
--   **กฎนี้จึงต้องให้ฐานข้อมูลเป็นคนตัดสิน ไม่ใช่โค้ดฝั่งแอป** (บทเรียนข้อ 6
--   ในรูปที่ยากที่สุด: ไม่ใช่ "ฟอร์มไม่ใช่ที่กั้น" แต่เป็น "การอ่านแล้วเขียน
--   ในสองธุรกรรมที่ไม่เห็นกันไม่ใช่ที่กั้น")
--
-- ------------------------------------------------------------
-- **สามข้อที่ต้องอ่านโค้ดจริงก่อนเลือกรูปแบบ index — ผลที่อ่านได้**
--
--   (1) `source_ref` อยู่ที่ **ระดับ payload** (`fn_post_entry`: `p_payload ->> 'source_ref'`)
--       → ถูกเขียนลง **ทุก transaction** ที่ใบนั้นสร้าง
--       รายการข้ามผู้ถือสร้างสอง transaction จากใบเดียว (`posting.ts` สาขา
--       intercompany) และทั้งคู่ได้ `source_ref` เดียวกัน
--       → **unique index บน `source_ref` เดี่ยวๆ ฆ่ารายการข้ามผู้ถือทั้งหมด**
--       แต่สองขานั้น **`owner_id` ต่างกันเสมอ** (ขาที่ owner เดียวกันไม่เคยถูกแตก
--       เป็นสองรายการ — การโอนในกระเป๋าตัวเองลงเป็นใบเดียว)
--       → คีย์จึงเป็น **`(source_ref, owner_id)`**
--
--   (2) **เส้นทางกลับรายการยังไม่คัดลอก `source_ref`** — วันนี้ไม่มีเส้นทางแอป
--       ที่ post ใบกลับรายการเลย (`toPostEntryPayload()` ไม่มีช่อง `reverses_id`
--       และ fix `source: "manual"`) ส่วนเครื่องยนต์ (`reversal.ts`) ไม่พา
--       `source_ref` ไปด้วย · **แต่ index ยังยกเว้น `reverses_id is not null`**
--       เพราะวันที่เส้นทางนั้นเกิดขึ้น การกลับรายการใบล้างย่อมอ้างเลขเดิม
--       และ **ห้ามมีด่านของเราไปบล็อกการกลับรายการ** (กฎเหล็กข้อ 1: แก้ของที่ผิด
--       ได้ทางเดียวคือ reverse + ลงใหม่ · ปิดทางนั้น = แก้ของที่ลงผิดไม่ได้เลย)
--
--   (3) **ยังไม่มี automation / import ที่เขียน `source_ref` ลงสมุด** — ผู้ใช้
--       `source_ref` รายเดียวในวันนี้คือใบล้าง (`clearingRefFor()` ใน
--       `src/lib/db/pending-accruals.ts` รูป `<uuid ต้นทาง>-clr-<n>`)
--       ส่วน `draft_entries.source_ref` เป็นคอลัมน์ของอีกตาราง ไม่เกี่ยวกัน
--       → **ห้ามบังคับ unique กับ `source_ref` ทุกค่า** เพราะมันเป็นช่องข้อความอิสระ
--       ที่ตัวนำเข้าในอนาคตอาจใช้ซ้ำโดยเจตนา (เลขแบตช์ · ชื่อไฟล์นำเข้า)
--       → index เป็น **partial** คุมเฉพาะค่าที่มี **รูปของเลขอ้างอิงการล้าง**
--
-- ------------------------------------------------------------
-- **สองชั้นที่ไฟล์นี้เพิ่ม และทำไมต้องมีทั้งคู่**
--
--   ชั้น A · `transactions_clearing_ref_once` (partial unique index)
--     ปิดจังหวะพร้อมกันของ **เลขอ้างอิงเดียวกัน** ซึ่งเป็นกรณีที่เกิดบ่อยที่สุด
--     (กดรัว · สองแท็บ · เน็ตหลุดแล้วลองใหม่ — ทั้งคู่อ่าน n = 0 แล้วได้ `-clr-1`)
--     และยัง **กันประวัติการล้างพัง**: `pending-accruals.ts` อ่านประวัติจาก
--     `source_ref` ถ้ามีสองแถวเลขเดียวกัน ยอดที่ล้างแล้วจะนับผิดตลอดไป
--     ทำได้เพราะ index เป็นด่านที่ **ไม่ต้องอ่านก่อนเขียน** (ผู้ชนะคนเดียวตามนิยาม)
--
--   ชั้น B · `trg_assert_clearing_not_over` (constraint trigger + **ล็อกแถวต้นทาง**)
--     ชั้น A ไม่พอ: คำขอที่อ่านประวัติได้ต่างกัน (ตัวหนึ่งเห็น 0 ตัวหนึ่งเห็น 1)
--     จะได้ `-clr-1` กับ `-clr-2` → เลขไม่ซ้ำ index ไม่ติด แต่ยอดรวมยังเกิน
--     ชั้นนี้จึง **ล็อกแถวรายการต้นทาง (`select ... for update`) ก่อนคิดยอด**
--     → คำขอที่สองรอคำขอแรก commit แล้วอ่านใหม่ (READ COMMITTED ให้ snapshot ใหม่
--       ต่อคำสั่ง) เห็นยอดที่ล้างไปแล้วจริง แล้วถูกปฏิเสธด้วยตัวเลข
--     นี่คือจุดที่ "DB เป็นคนตัดสิน" จริงๆ: ไม่มีทางที่สองคำขอจะคิดยอดจาก
--     สมุดเดียวกันพร้อมกันได้อีก
--
--   **ยอดที่นับ วัดจากบัญชีพัก (`txn_types.accrual_coa_code`) ไม่ใช่จากขาเงินสด**
--     เพราะใบล้างที่ถูกหักภาษี ณ ที่จ่าย (D-111) ปิดลูกหนี้ **ยอดเต็ม** 100,000
--     ด้วยเงินสด 95,000 + ภาษี 5,000 — ถ้านับขาเงินสด ด่านจะคิดว่ายังเหลือ 5,000
--     ให้ล้าง แล้วเปิดช่องให้ลูกหนี้ติดลบเท่าภาษีที่ถูกหักทุกใบ
--     (หมายเหตุสำหรับงานหน้าจอ: `pending-accruals.ts` **ยังอ่านยอดจากขาเงินสด**
--      จึงจะโชว์ว่าเหลือค้าง 5,000 ทั้งที่ลูกหนี้ปิดแล้ว · ด่านนี้จะปฏิเสธการล้าง
--      ส่วนนั้นเสียงดัง ไม่ใช่ปล่อยให้ติดลบ — ต้องแก้ฝั่งนั้นด้วย ดูรายงาน)
--
--   **บัญชีพักมาจากตารางกฎ ไม่มีรหัสบัญชีพิมพ์มือในไฟล์นี้** (`accrual_coa_code`
--   ของหมวดต้นทาง) → หมวดใหม่ที่ตั้งค้างได้ถูกคุมเองทันทีที่ seed ลงมา
--
-- ------------------------------------------------------------
-- **ที่ไม่ได้เลือก และเหตุผล**
--   - unique index บน `(source_ref)` เดี่ยว → ฆ่ารายการข้ามผู้ถือ (ข้อ 1)
--   - unique index บนทุกค่าของ `source_ref` (ไม่ partial) → ผูกความหมายให้ช่อง
--     ข้อความอิสระที่ยังไม่มีสัญญา (ข้อ 3) · ตัวนำเข้าในอนาคตจะพังโดยไม่มีใครรู้ล่วงหน้า
--   - ตรวจในฟังก์ชัน `fn_post_entry` อย่างเดียว → **ไม่พอ** เพราะเป็นการอ่านก่อนเขียน
--     ในธุรกรรมที่ไม่เห็นกัน (รูเดิมอยู่ตรงนี้เป๊ะ) และ REST ที่เขียนตรงก็เลี่ยงได้
--   - advisory lock บน hash ของ source id → ได้ผลคล้ายชั้น B แต่ล็อกที่ **ไม่ผูกกับแถว**
--     หลุดทันทีที่มีคนลืมเรียก และอ่านย้อนไม่ได้ว่าใครถืออยู่ · ล็อกแถวต้นทางเป็น
--     ของที่ trigger บังคับเองทุกเส้นทาง รวม REST ที่เขียนตรงเข้าตาราง
--
-- ------------------------------------------------------------
-- ลำดับ: **ต้องรันหลัง 20261020000001_void_columns_and_views.sql** (อ่าน
--   `v_ledger_posted`) และ **หลัง 20261006000003_txn_types_can_accrue.sql**
--   (ใช้ `txn_types.accrual_coa_code`) · วางต่อท้าย 20261025000002 ได้เลย
--   และต้อง **ก่อน 20261020000003_replay_end_state_guard.sql** (ไฟล์สุดท้ายเสมอ)
--   ผมไม่แก้ migration-order.txt / UNDER_TEST เอง — ลงทะเบียนให้ตามนี้
--
-- idempotent: create index if not exists · create or replace function ·
--   drop trigger if exists ก่อน create · ไม่มีการแก้ข้อมูล → replay ซ้ำได้ตลอด
--
-- ย้อนกลับ (rollback) — เรียงจากหลังมาหน้า:
--   -- drop trigger  if exists trg_assert_clearing_not_over_txn on sri_os.transactions;
--   -- drop trigger  if exists trg_assert_clearing_not_over on sri_os.transaction_lines;
--   -- drop function if exists sri_os.fn_assert_clearing_not_over_txn();
--   -- drop function if exists sri_os.fn_assert_clearing_not_over();
--   -- drop function if exists sri_os.fn_assert_clearing_not_over_for(uuid);
--   -- drop index    if exists sri_os.transactions_clearing_ref_once;
--   -- drop function if exists sri_os.fn_clearing_ref_source(text);
--   -- ย้อนแล้วได้สภาพเดิมคือ **ล้างยอดเกินได้ด้วยคำขอสองใบที่มาพร้อมกัน**
--   --   ลูกหนี้/เจ้าหนี้ติดลบ และเงินสดไม่ตรง statement — ไม่แนะนำให้ย้อน
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 1 · fn_clearing_ref_source — **ที่เดียวฝั่ง DB ที่รู้รูปของเลขอ้างอิงการล้าง**
--
-- สำเนาของ `parseClearingRef()` ใน `src/lib/db/pending-accruals.ts`
-- (`<uuid ของรายการต้นทาง>-clr-<n>`) · คืน null ถ้าไม่ใช่รูปนั้น
-- → "ใบนี้เป็นใบล้างหรือไม่" ตัดสินจากรูปของเลขอ้างอิงที่เดียว ไม่กระจายเป็น regex
-- ซ้ำในหลาย trigger (ซึ่งวันหนึ่งจะแก้ไม่ครบ)
--
-- immutable + ไม่แตะตารางใดเลย → ใช้ในเงื่อนไขของ index ได้ และไม่เป็น
-- ทางอ้อมอ่านสมุดเงิน (D-089)
-- ============================================================
create or replace function fn_clearing_ref_source(p_ref text) returns uuid
language sql immutable set search_path = '' as $fn$
  select case
    when p_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-clr-[0-9]+$'
    then lower(left(p_ref, 36))::uuid
  end;
$fn$;

comment on function fn_clearing_ref_source(text) is
  'คืน id ของรายการต้นทางจากเลขอ้างอิงการล้าง `<uuid>-clr-<n>` · null = ไม่ใช่ใบล้าง · สำเนาฝั่ง DB ของ parseClearingRef() ใน src/lib/db/pending-accruals.ts · ที่เดียวที่รู้รูปของเลขนี้';

revoke all on function fn_clearing_ref_source(text) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_clearing_ref_source(text) from anon';
  execute 'grant execute on function sri_os.fn_clearing_ref_source(text) to authenticated';
end $$;

-- ============================================================
-- 2 · ชั้น A · เลขอ้างอิงการล้างเดียวกันของผู้ถือเดียวกัน **มีได้ครั้งเดียว**
--
-- ก่อนสร้าง index ต้องตรวจของที่มีอยู่แล้ว: ถ้ามีเลขซ้ำอยู่ในสมุดจริง
-- แปลว่า **การล้างซ้ำเกิดขึ้นไปแล้ว** และต้องแก้ด้วย reverse ก่อน
-- (create index จะล้มเองก็จริง แต่ข้อความของ Postgres ไม่บอกว่าต้องทำอะไรต่อ)
-- ============================================================
do $$
declare v text; n int;
begin
  select count(*), string_agg(x.source_ref || ' (ผู้ถือ ' || x.owner_id::text || ' · ' || x.n || ' ใบ)', ', ')
    into n, v
    from (
      select t.source_ref, t.owner_id, count(*) as n
        from sri_os.transactions t
       where t.reverses_id is null
         and t.status = 'posted'
         and sri_os.fn_clearing_ref_source(t.source_ref) is not null
       group by t.source_ref, t.owner_id
      having count(*) > 1
    ) x;
  if coalesce(n, 0) > 0 then
    raise exception 'มีใบล้างที่ใช้เลขอ้างอิงเดียวกันซ้ำอยู่ในสมุดแล้ว % กลุ่ม: % — แปลว่าการล้างซ้ำเกิดขึ้นไปแล้วและยอดลูกหนี้/เจ้าหนี้เพี้ยนอยู่ตอนนี้ · ต้อง **กลับรายการ (reverse) ใบที่เกิน** ให้เหลือใบละหนึ่งก่อน แล้วรันไฟล์นี้อีกครั้ง (ห้ามลบแถว · กฎเหล็กข้อ 1)',
      n, v;
  end if;
end $$;

/**
 * **partial unique index** — คุมเฉพาะแถวที่ `source_ref` มีรูปของเลขอ้างอิงการล้าง
 *   · ยกเว้นใบกลับรายการ (`reverses_id is not null`) → กลับรายการได้เสมอ
 *   · คีย์รวม `owner_id` → รายการข้ามผู้ถือ (สองขา source_ref เดียวกัน) ยังลงได้
 *   · ไม่คุมค่า `source_ref` รูปอื่น → ตัวนำเข้า/automation ในอนาคตไม่พัง
 */
create unique index if not exists transactions_clearing_ref_once
  on transactions (source_ref, owner_id)
  where reverses_id is null
    and source_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-clr-[0-9]+$';

comment on index transactions_clearing_ref_once is
  'ชั้น A ของการกันล้างซ้ำ · เลขอ้างอิงการล้าง `<uuid>-clr-<n>` ของผู้ถือหนึ่งราย มีได้ครั้งเดียว · partial + รวม owner_id โดยตั้งใจ: รายการข้ามผู้ถือใช้ source_ref เดียวกันสองขา และใบกลับรายการต้องทำได้เสมอ · ไม่คุม source_ref รูปอื่นเพราะเป็นช่องข้อความอิสระ';

-- ============================================================
-- 3 · ชั้น B · ยอดที่ล้างทั้งหมดห้ามเกินยอดค้างของรายการต้นทาง
--     **ล็อกแถวต้นทางก่อนคิดยอด** → คำขอที่มาพร้อมกันถูกบังคับให้เรียงคิว
-- ============================================================
create or replace function fn_assert_clearing_not_over_for(p_txn uuid) returns void
language plpgsql security definer set search_path = '' as $fn$
declare
  v_ref      text;
  v_rev      uuid;
  v_source   uuid;
  v_type     text;
  v_accrual  text;
  v_accrued  numeric;
  v_cleared  numeric;
  v_sign     numeric;
  v_memo     text;
begin
  select t.source_ref, t.reverses_id into v_ref, v_rev
    from sri_os.transactions t where t.id = p_txn;

  v_source := sri_os.fn_clearing_ref_source(v_ref);
  if v_source is null then
    return;   -- ไม่ใช่ใบล้าง → ด่านนี้ไม่เกี่ยว
  end if;

  /**
   * ใบกลับรายการที่อ้างเลขเดิม = การ **คืนยอด** ไม่ใช่การล้างเพิ่ม
   * ยอดของมันถูกนับหักกลบในสมการข้างล่างอยู่แล้ว (ดูชุด "ใบล้างทั้งหมด")
   * ถ้าตรวจมันด้วยจะกลายเป็นด่านที่ห้ามแก้ของที่ลงผิด (กฎเหล็กข้อ 1)
   */
  if v_rev is not null then
    return;
  end if;

  /**
   * **ล็อกแถวรายการต้นทาง — บรรทัดที่ปิดรูทั้งหมดของเรื่องนี้**
   *
   * ทุกใบล้างของต้นทางเดียวกันต้องผ่านบรรทัดนี้ → คำขอที่สองรอคำขอแรก commit
   * แล้วค่อยคิดยอดจากสมุดที่รวมใบของคำขอแรกแล้ว (READ COMMITTED ให้ snapshot
   * ใหม่ต่อคำสั่ง จึงเห็นของที่เพิ่ง commit) · ถ้าอยู่ใน REPEATABLE READ
   * คำขอที่สองจะได้ serialization error ซึ่งก็คือ "ไม่สำเร็จ" เหมือนกัน
   * ไม่มีทางที่ทั้งคู่จะคิดยอดจากสมุดเดียวกันแล้วผ่านทั้งคู่
   *
   * ล็อก **แถวของต้นทาง** ไม่ใช่ advisory lock เพราะ trigger บังคับได้ทุกเส้นทาง
   * รวมการเขียนตรงเข้าตารางผ่าน REST และอ่านย้อนได้ว่าใครถืออยู่ (pg_locks)
   */
  perform 1 from sri_os.transactions t where t.id = v_source for update;

  select t.txn_type_code, t.memo into v_type, v_memo
    from sri_os.transactions t where t.id = v_source;
  if v_type is null then
    raise exception 'ใบล้างนี้อ้างเลขอ้างอิง "%" แต่ไม่มีรายการต้นทาง % อยู่ในสมุด — ล้างยอดค้างของรายการที่ไม่มีอยู่ไม่ได้ (เลขอ้างอิงถูกประกอบเองหรือรายการต้นทางถูกลบ)',
      v_ref, v_source;
  end if;

  select ty.accrual_coa_code into v_accrual
    from sri_os.txn_types ty where ty.code = v_type;
  if v_accrual is null then
    raise exception 'รายการต้นทาง % เป็นหมวด "%" ซึ่งตารางกฎไม่ได้ระบุบัญชีพัก (accrual_coa_code) ไว้ — หมวดนี้ไม่ใช่รายการค้างรับ-ค้างจ่าย จึงไม่มียอดค้างให้ล้าง',
      v_source, v_type;
  end if;

  -- ยอดค้างของต้นทาง: บรรทัดบัญชีพักของใบต้นทาง **บวกใบที่กลับรายการต้นทางนั้น**
  -- → ต้นทางที่ถูกกลับรายการแล้วจะได้ 0 แล้วการล้างถูกปฏิเสธ (ยอดค้างไม่มีอยู่แล้ว)
  select coalesce(sum(v.debit - v.credit), 0) into v_accrued
    from sri_os.v_ledger_posted v
    join sri_os.chart_of_accounts c on c.id = v.coa_id
   where c.code = v_accrual
     and (v.transaction_id = v_source or v.reverses_id = v_source);

  if round(v_accrued, 2) = 0 then
    raise exception 'รายการต้นทาง % ไม่มียอดค้างในบัญชีพัก % เหลืออยู่ (อาจถูกกลับรายการไปแล้ว หรือใบนั้นไม่ได้ตั้งค้างไว้) — ล้างต่อจะทำให้ลูกหนี้/เจ้าหนี้ติดลบและเงินสดไม่ตรง statement',
      v_source, v_accrual;
  end if;

  -- ใบล้างทั้งหมดของต้นทางนี้ (รวมใบนี้) **บวกใบที่กลับรายการใบล้าง**
  -- → ใบล้างที่ถูกกลับรายการหักกลบเป็นศูนย์เอง ยอดค้างจึงกลับมาให้ล้างใหม่ได้
  select coalesce(sum(v.debit - v.credit), 0) into v_cleared
    from sri_os.v_ledger_posted v
    join sri_os.chart_of_accounts c on c.id = v.coa_id
   where c.code = v_accrual
     and (
       sri_os.fn_clearing_ref_source(v.source_ref) = v_source
       or v.reverses_id in (
            select v2.transaction_id from sri_os.v_ledger_posted v2
             where sri_os.fn_clearing_ref_source(v2.source_ref) = v_source)
     );

  -- ทิศ: ลูกหนี้ (สินทรัพย์) ตั้งค้างด้วยเดบิต · เจ้าหนี้ (หนี้สิน) ด้วยเครดิต
  -- การล้างอยู่ตรงข้ามกับการตั้งค้างเสมอ → คิดเป็นยอดบวกด้วยเครื่องหมายของต้นทาง
  v_sign    := sign(v_accrued);
  v_accrued := abs(v_accrued);
  v_cleared := -v_sign * v_cleared;

  if round(v_cleared, 2) > round(v_accrued, 2) + 0.005 then
    raise exception 'ล้างยอดค้างเกิน: รายการต้นทาง "%" (%) ตั้งค้างไว้ % บาท แต่ใบล้างทั้งหมดรวมใบนี้เป็น % บาท (เกิน % บาท) — ล้างเกินทำให้ลูกหนี้/เจ้าหนี้ติดลบและเงินสดในระบบไม่ตรงกับยอดธนาคาร · ถ้าเก็บเงินได้มากกว่าที่เขาเป็นหนี้ ส่วนเกินคือเงินรับล่วงหน้า (เจ้าหนี้) ต้องลงเป็นรายการของตัวเอง ไม่ใช่ล้างยอดค้างเกิน',
      coalesce(v_memo, v_source::text), v_accrual, round(v_accrued, 2), round(v_cleared, 2),
      round(v_cleared - v_accrued, 2);
  end if;
end $fn$;

comment on function fn_assert_clearing_not_over_for(uuid) is
  'ชั้น B ของการกันล้างซ้ำ · ยอดที่ล้างทั้งหมด (วัดจากบัญชีพักของหมวดต้นทาง ไม่ใช่จากขาเงินสด) ห้ามเกินยอดค้างของรายการต้นทาง · **ล็อกแถวต้นทางก่อนคิดยอด** จึงกันคำขอที่มาถึงพร้อมกันได้ ซึ่งการอ่านก่อนเขียนฝั่งแอปกันไม่ได้เลย · ใบกลับรายการและใบที่ถูกกลับรายการหักกลบกันในสมการ';

-- เรียกตรงไม่ได้ทุก role — definer ที่อ่าน transactions/transaction_lines (D-089)
revoke all on function fn_assert_clearing_not_over_for(uuid) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_clearing_not_over_for(uuid) from anon, authenticated';
end $$;

/**
 * ฝั่งบรรทัด — **constraint trigger แบบ deferred** เพราะต้องอ่านทุกบรรทัดของใบ
 * (ใบล้างมีขาเงินสดกับขาบัญชีพัก และอาจมีขาภาษีถูกหัก ณ ที่จ่ายด้วย)
 * ถ้ายิงตอนใส่บรรทัดแรก ใบที่ถูกต้องจะถูกปฏิเสธเพราะยอดยังไม่ครบ
 */
create or replace function fn_assert_clearing_not_over() returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  perform sri_os.fn_assert_clearing_not_over_for(coalesce(new.transaction_id, old.transaction_id));
  return null;
end $fn$;

comment on function fn_assert_clearing_not_over() is
  'trigger ฝั่ง transaction_lines ของ fn_assert_clearing_not_over_for()';

revoke all on function fn_assert_clearing_not_over() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_clearing_not_over() from anon, authenticated';
end $$;

drop trigger if exists trg_assert_clearing_not_over on transaction_lines;
create constraint trigger trg_assert_clearing_not_over
  after insert or update or delete on transaction_lines
  deferrable initially deferred
  for each row execute function fn_assert_clearing_not_over();

/**
 * ฝั่งหัวรายการ — **ยิงทันที ไม่เลื่อน** (รูปเดียวกับ trg_assert_wht_gross_txn)
 *
 * ปิดสองทางที่ฝั่งบรรทัดปิดไม่ได้:
 *   1. ชี้ `source_ref` ของใบที่ post แล้วไปที่ต้นทางอื่น (หรือเปลี่ยนเลขลำดับ)
 *      = ล้างเกินโดยไม่ต้องแตะบรรทัดเลย — ไม่มีบรรทัดไหนถูกแก้ ด่านฝั่งบรรทัดจึงเงียบ
 *   2. จับ **ตอน INSERT หัวรายการ** ซึ่งเกิดก่อนบรรทัด → ได้ล็อกแถวต้นทางเร็วขึ้น
 *      และถ้ายอดค้างหมดแล้ว ผู้กดได้คำตอบทันทีแทนที่จะได้ตอน commit
 *      (ตอนนั้นใบยังไม่มีบรรทัด ยอดที่นับได้จึงเป็น 0 ซึ่งผ่านเสมอ — ไม่ใช่ด่านซ้ำ
 *       แต่เป็นจุดที่คิวถูกจัด)
 */
create or replace function fn_assert_clearing_not_over_txn() returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  perform sri_os.fn_assert_clearing_not_over_for(coalesce(new.id, old.id));
  return null;
end $fn$;

comment on function fn_assert_clearing_not_over_txn() is
  'trigger ฝั่ง transactions ของ fn_assert_clearing_not_over_for() · ยิงทันทีตอน insert และตอนแก้ source_ref ของใบที่ post แล้ว (ชี้ไปต้นทางอื่น = ล้างเกินโดยไม่แตะบรรทัด)';

revoke all on function fn_assert_clearing_not_over_txn() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_clearing_not_over_txn() from anon, authenticated';
end $$;

drop trigger if exists trg_assert_clearing_not_over_txn on transactions;
create trigger trg_assert_clearing_not_over_txn
  after insert or update of source_ref on transactions
  for each row execute function fn_assert_clearing_not_over_txn();

-- ============================================================
-- 4 · guard ท้ายไฟล์ — ดังตอน migrate ไม่ใช่ตอนผู้ใช้กดปุ่ม
-- ============================================================
do $$
declare v text; n int;
begin
  -- (ก) ฟังก์ชันครบ
  select string_agg(x.want, ', ') into v
    from (values ('sri_os.fn_clearing_ref_source(text)'),
                 ('sri_os.fn_assert_clearing_not_over_for(uuid)'),
                 ('sri_os.fn_assert_clearing_not_over()'),
                 ('sri_os.fn_assert_clearing_not_over_txn()')) x(want)
   where to_regprocedure(x.want) is null;
  if v is not null then
    raise exception 'ฟังก์ชันหายไป: %', v;
  end if;

  -- (ข) ตัวแยกเลขอ้างอิงต้องตอบถูกทั้งสองทิศ (ของจริงกับของปลอม)
  if sri_os.fn_clearing_ref_source('00000000-0000-0000-0000-00000000000a-clr-2')
     is distinct from '00000000-0000-0000-0000-00000000000a'::uuid then
    raise exception 'fn_clearing_ref_source อ่านเลขอ้างอิงการล้างไม่ออก → ด่านทั้งไฟล์นี้จะไม่คุมอะไรเลย';
  end if;
  select count(*) into n from unnest(array[
    null, '', 'abc', '00000000-0000-0000-0000-00000000000a',
    '00000000-0000-0000-0000-00000000000a-clr-', 'x0000000-0000-0000-0000-00000000000a-clr-1',
    '00000000-0000-0000-0000-00000000000a-clr-1-clr-2']) x(ref)
   where sri_os.fn_clearing_ref_source(x.ref) is not null;
  if n > 0 then
    raise exception 'fn_clearing_ref_source รับค่าที่ไม่ใช่เลขอ้างอิงการล้าง % แบบ — ด่านจะไปคุมใบที่ไม่เกี่ยว แล้วรายการปกติพัง', n;
  end if;

  -- (ค) index ต้องมีจริง · เป็น unique · เป็น partial · และคีย์มี owner_id
  --     (ทั้งสามข้อคือเหตุผลที่เลือกรูปนี้ ถ้าหลุดข้อใดข้อหนึ่งคือพังคนละแบบ)
  if not exists (select 1 from pg_class i
                  join pg_namespace ns on ns.oid = i.relnamespace
                 where ns.nspname = 'sri_os' and i.relname = 'transactions_clearing_ref_once'
                   and i.relkind = 'i') then
    raise exception 'ไม่มี index transactions_clearing_ref_once';
  end if;
  select pg_get_indexdef(i.oid) into v from pg_class i
    join pg_namespace ns on ns.oid = i.relnamespace
   where ns.nspname = 'sri_os' and i.relname = 'transactions_clearing_ref_once';
  if v !~ 'UNIQUE' then
    raise exception 'transactions_clearing_ref_once ไม่ใช่ unique index → ไม่ได้กันเลขอ้างอิงซ้ำเลย (%)', v;
  end if;
  if v !~ 'WHERE' or v !~ 'clr' then
    raise exception 'transactions_clearing_ref_once ไม่ใช่ partial index ตามรูปของเลขอ้างอิง → ไปบังคับ unique กับ source_ref ของตัวนำเข้า/automation ด้วย (%)', v;
  end if;
  if v !~ 'owner_id' then
    raise exception 'transactions_clearing_ref_once ไม่มี owner_id ในคีย์ → **รายการข้ามผู้ถือจะลงไม่ได้ทั้งหมด** เพราะสองขาใช้ source_ref เดียวกัน (%)', v;
  end if;
  if v !~ 'reverses_id IS NULL' then
    raise exception 'transactions_clearing_ref_once ไม่ได้ยกเว้นใบกลับรายการ → กลับรายการใบล้างไม่ได้ ซึ่งแปลว่าแก้ของที่ลงผิดไม่ได้เลย (%)', v;
  end if;

  -- (ง) trigger ต้องผูกทั้งสองตาราง · ฝั่งบรรทัดเลื่อน · ฝั่งหัวรายการยิงทันที
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.transaction_lines'::regclass
                    and g.tgname = 'trg_assert_clearing_not_over'
                    and not g.tgisinternal and g.tgdeferrable and g.tginitdeferred) then
    raise exception 'trg_assert_clearing_not_over บน transaction_lines หายไปหรือไม่ใช่ constraint trigger แบบ deferred';
  end if;
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.transactions'::regclass
                    and g.tgname = 'trg_assert_clearing_not_over_txn'
                    and not g.tgisinternal and not g.tgdeferrable
                    and (g.tgtype & 1) <> 0 and (g.tgtype & 4) <> 0 and (g.tgtype & 16) <> 0) then
    raise exception 'trg_assert_clearing_not_over_txn บน transactions หายไป หรือถูกทำเป็น deferred → แก้ source_ref ย้อนหลังได้โดยไม่มีใครตรวจ';
  end if;

  -- (จ) ล็อกแถวต้นทางต้องยังอยู่ในโค้ด — **หัวใจของการกันจังหวะพร้อมกัน**
  --     ถอดบรรทัดนี้ออกแล้วด่านยังเขียวทุกเทสต์ที่รันทีละคำสั่ง (จับได้แค่ด้วย
  --     เทสต์สองเซสชัน) จึงตรวจจากตัวโค้ดตรงๆ
  if pg_get_functiondef('sri_os.fn_assert_clearing_not_over_for(uuid)'::regprocedure)
     !~* 'for update' then
    raise exception 'fn_assert_clearing_not_over_for ไม่ได้ล็อกแถวรายการต้นทาง (select ... for update) → คำขอล้างสองใบที่มาพร้อมกันจะคิดยอดจากสมุดเดียวกันแล้วผ่านทั้งคู่ = ล้างเกินเหมือนเดิม';
  end if;

  -- (ฉ) definer ของด่านต้องเรียกตรงไม่ได้ (D-089) · ตัวแยกเลขเรียกได้ (แอปใช้แสดงผล)
  select string_agg(x.f, ', ') into v
    from unnest(array['sri_os.fn_assert_clearing_not_over_for(uuid)',
                      'sri_os.fn_assert_clearing_not_over()',
                      'sri_os.fn_assert_clearing_not_over_txn()']) x(f)
   where has_function_privilege('authenticated', x.f, 'execute')
      or has_function_privilege('anon', x.f, 'execute');
  if v is not null then
    raise exception 'ฟังก์ชันด่านที่เป็น definer ยังเรียกตรงได้: % = ทางข้าม policy ของสมุดเงิน', v;
  end if;

  -- (ช) ต้องมีหมวดที่ตั้งค้างได้จริงอยู่ในตารางกฎ ไม่งั้นด่านนี้ไม่ได้คุมอะไรเลย
  select count(*) into n from sri_os.txn_types t where t.accrual_coa_code is not null;
  if n = 0 then
    raise exception 'ไม่มีหมวดใดในตารางกฎที่มีบัญชีพัก (accrual_coa_code) → ไม่มียอดค้างให้ล้าง และด่านนี้ไม่ได้คุมอะไร';
  end if;

  raise notice 'ล้างยอดค้างเกินไม่ได้แล้ว: index เลขอ้างอิงซ้ำ (partial · มี owner_id · ยกเว้นใบกลับรายการ) + ด่านยอดรวมที่ล็อกแถวต้นทาง · หมวดที่ตั้งค้างได้ % หมวด', n;
end $$;
