-- ============================================================
-- SRI OS · ภาษีหัก ณ ที่จ่ายลงจริงให้ได้ (D-111 ข้อ 1) — ปิดสี่ทางตันที่ผู้ตรวจพิสูจน์แล้ว
--
-- 20261024000001 สร้างคอลัมน์ `transactions.wht_*` · บัญชี 1800 · และด่าน
-- `fn_assert_wht_gross` ไว้ครบ **แต่ไม่มีทางลงจริงได้เลย**:
--
--   (1) `fn_post_entry()` ไม่รับและไม่เขียน wht_rate / wht_amount / wht_certificate_no
--       → ลงบรรทัด 1800 แล้วหัวรายการเป็น null → ด่านปฏิเสธตอน commit
--       → ใส่ลง payload ก็เด้ง "มีช่องที่ยังไม่รู้จัก" · **ทุกทางตัน**
--   (2) หัวรายการที่ถูกหักภาษีแก้ย้อนหลังได้โดยไม่มีด่านไหนตรวจ (ดูข้อ 4 ล่าง)
--   (3) ค่าเช่าที่ตั้งค้างรับไว้แล้วถูกหักภาษีตอนผู้เช่าจ่าย (เกิดขึ้นจริงทุกเดือน:
--       ออกใบแจ้งหนี้ → ตั้งลูกหนี้ → ผู้เช่าจ่ายแล้วหัก 5%) ลงไม่ได้ทุกทาง
--       เพราะ `fn_txn_type_can_withhold()` ยอมเฉพาะหมวดที่ **ขาเครดิตเป็นบัญชีรายได้**
--   (4) ด่าน `trg_assert_wht_gross` ผูกแต่ `transaction_lines`
--       → UPDATE `transactions.wht_amount` ของใบที่ post แล้ว **ไม่มีอะไรตรวจ**
--       ฝั่ง personal แก้ตัวเลขภาษีย้อนหลังได้โดยไม่มีใครจับ
--
-- ------------------------------------------------------------
-- **ข้อ 3 แก้ที่กฎ ไม่ใช่ที่ด่าน** — เพิ่มเงื่อนไขที่สองให้ "หมวดนี้ถูกหักภาษีได้ไหม"
--
-- ภาษีหัก ณ ที่จ่ายผูกกับ **เงินได้** ซึ่งมีสองรูปในสมุดของเรา:
--   (ก) ใบที่รับรู้รายได้พร้อมรับเงิน      → Dr เงินสด / Cr บัญชีรายได้
--   (ข) ใบที่รับชำระลูกหนี้ซึ่ง **รับรู้รายได้ยอดเต็มไปแล้วตอนตั้งค้าง**
--       → Dr เงินสด / Cr บัญชีลูกหนี้ที่เป็น `accrual_coa_code` ของหมวดรายได้
--
-- (ข) ไม่ใช่ข้อยกเว้นที่พิมพ์ชื่อหมวดไว้ — **คำนวณจากตารางกฎ**: บัญชีขาเครดิต
--   ของหมวดนั้นต้องเป็นบัญชีค้างรับของหมวดที่ขาเครดิตเป็นรายได้และอยู่หมวด
--   กระแสเงินสดดำเนินงาน · หมวดรับชำระค้างรับตัวใหม่จึงรองรับเองทันที
--   และ `inv.wht_refund` (Cr 1800) ยังไม่เข้าเกณฑ์ เพราะ 1800 ไม่ใช่บัญชีค้างรับ
--   ของหมวดรายได้ใด = การขอคืนภาษีไม่ถูกหักภาษีอีกชั้น (ซึ่งถูก)
--
-- สมการ "รายได้ต้องเป็นยอดเต็ม" จึงกว้างขึ้นเป็น **"ยอดเต็มของเงินได้"**:
--       เครดิตบัญชีรายได้ (หรือเครดิตบัญชีลูกหนี้ที่กำลังล้าง) = เดบิตเงินสด + เดบิต 1800
--   ค่าเช่า 100,000 ที่ตั้งค้างไว้ ผู้เช่าจ่าย 95,000 + ใบหัก 5,000 → ลูกหนี้ลง 100,000
--   **ยอดเต็ม** ลูกหนี้จึงปิดพอดีและไม่มีเศษค้างเท่าภาษีที่ถูกหัก (ซึ่งถ้าเกิดขึ้น
--   จะไม่มีทางล้างเลย เพราะไม่มีใครมาจ่ายส่วนนั้นอีก)
--
-- ------------------------------------------------------------
-- **ข้อ 4 แก้ด้วยการย้ายกฎไปอยู่ที่เดียว แล้วผูกสองตาราง**
--   เนื้อกฎย้ายไปอยู่ใน `fn_assert_wht_gross_for(uuid)` ตัวเดียว
--   แล้วมี trigger สองตัวเรียกมัน (บรรทัด + หัวรายการ) — ไม่ใช่เขียนกฎสองสำเนา
--   ที่วันหนึ่งจะคิดต่างกัน (บทเรียน mace-windu ข้อ 5)
--
-- ------------------------------------------------------------
-- ลำดับ: **ต้องรันหลัง 20261024000001_wht_and_fx.sql** (ใช้คอลัมน์ wht_* · บัญชี 1800
--   · เขียนทับ fn_txn_type_can_withhold และ fn_assert_wht_gross ของไฟล์นั้น)
--   และ **หลัง 20261008000013_drop_redundant_door_checks.sql**
--   (เขียนทับ fn_post_entry **รุ่นของ 013 ไม่ใช่ของ 011** — 013 ถอดด่านคู่บัญชี
--    กับด่าน bank ออกจากประตูไปแล้วเพราะเป็นกฎที่สอง (zz_line_guards G0 บังคับไว้)
--    ไฟล์นี้ยกเนื้อของ 013 มาครบทุกบรรทัด เพิ่มเฉพาะสามช่อง wht_* ไม่ได้ผ่อนอะไรเลย
--    และ **ไม่เอาด่านคู่บัญชีกลับเข้าประตู** — บรรทัด 1800/3400 ถูกยอมรับที่
--    trg_lines_rule_coa (fn_assert_line_coa_in_rules) ซึ่งเป็นด่านเดียวของกฎนั้น)
--   และ **ก่อน 20261020000003_replay_end_state_guard.sql** (ไฟล์สุดท้ายเสมอ)
--   ลงทะเบียนใน supabase/migration-order.txt + UNDER_TEST ของ scripts/test-rls-local.sh
--
-- idempotent: create or replace function · drop trigger if exists ก่อน create ·
--   ไม่มี DDL ที่ทำซ้ำไม่ได้ → replay ซ้ำได้ตลอด
--
-- ย้อนกลับ (rollback) — เรียงจากหลังมาหน้า:
--   -- drop trigger  if exists trg_assert_wht_gross_txn on sri_os.transactions;
--   -- drop function if exists sri_os.fn_assert_wht_gross_txn();
--   -- รัน 20261024000001_wht_and_fx.sql ซ้ำ (คืน fn_txn_type_can_withhold ·
--   --   fn_assert_wht_gross รุ่นก่อนไฟล์นี้)
--   -- รัน 20261008000013_drop_redundant_door_checks.sql ซ้ำ (คืน fn_post_entry
--   --   รุ่นก่อนไฟล์นี้ · **ห้ามรัน 011 แทน** ไม่งั้นด่านคู่บัญชีกลับเข้าประตู
--   --   แล้ว zz_line_guards G0 แดงทันที)
--   -- drop function if exists sri_os.fn_assert_wht_gross_for(uuid);
--   -- ย้อนแล้วได้สภาพเดิมคือ **บันทึกการถูกหักภาษี ณ ที่จ่ายไม่ได้เลย**
--   --   และแก้ยอดภาษีของใบที่ post แล้วย้อนหลังได้ — ไม่แนะนำให้ย้อน
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 1 · fn_txn_type_can_withhold — เพิ่มเส้นทาง "รับชำระลูกหนี้ที่รับรู้รายได้ไปแล้ว"
--
-- **สำเนาฝั่ง SQL ของ canWithholdTax() ใน src/lib/rules/tx-rules.ts**
-- อ่านฟิลด์ชุดเดียวกันจาก txn_types (ซึ่ง seed มาจากตารางกฎในโค้ด)
-- `zz_wht_and_fx_test.sql` (W1) เขียนเงื่อนไขซ้ำอย่างอิสระแล้วเทียบทุกแถว
-- ============================================================
create or replace function fn_txn_type_can_withhold(p_code text) returns boolean
language sql stable security definer set search_path = '' as $fn$
  select exists (
    select 1
      from sri_os.txn_types t
     where t.code = p_code
       -- 1. เงินเข้า — ไม่มีใครหักภาษีจากเงินที่เราจ่ายออก
       and t.cash_direction = 'in'
       -- 2. ขาเดบิตเป็นเงินสด — ยอดที่เข้าบัญชีคือยอดสุทธิที่ต้องแยกเป็นสองขา
       and t.dr_coa_code ~ '^11[0-9][0-9]$'
       -- 3. กระแสเงินสดหมวดดำเนินงาน — ให้ทางล้าง (inv.wht_refund) อยู่หมวดเดียวกัน
       and t.cf_group = 'operating'
       and (
         -- 4ก. ขาเครดิตเป็นบัญชี **รายได้** — รับรู้รายได้ยอดเต็มในใบเดียวกัน
         exists (select 1 from sri_os.chart_of_accounts c
                  where c.code = t.cr_coa_code and c.type = 'income')
         -- 4ข. ขาเครดิตเป็น **บัญชีค้างรับของหมวดรายได้** — รายได้รับรู้ยอดเต็ม
         --      ไปแล้วตอนตั้งค้าง · ผู้จ่ายหักภาษีตอนจ่ายเงินจริง (ข้อ 3 ของผู้ตรวจ)
         or exists (
           select 1
             from sri_os.txn_types a
             join sri_os.chart_of_accounts ci on ci.code = a.cr_coa_code
            where a.accrual_coa_code = t.cr_coa_code
              and ci.type = 'income'
              and a.cf_group = 'operating')
       )
  );
$fn$;

comment on function fn_txn_type_can_withhold(text) is
  'D-111 ข้อ 1 · สำเนาฝั่ง DB ของ canWithholdTax() ใน src/lib/rules/tx-rules.ts · คำนวณจากคู่บัญชีและทิศเงินของ txn_types ไม่ใช่คอลัมน์ธง · ยอมสองเส้นทาง: ขาเครดิตเป็นบัญชีรายได้ (รับรู้รายได้พร้อมรับเงิน) หรือเป็นบัญชีค้างรับของหมวดรายได้ (ค่าเช่าที่ตั้งค้างแล้วผู้เช่าจ่ายโดยหักภาษี — ข้อ 3 ของผู้ตรวจ)';

revoke all on function fn_txn_type_can_withhold(text) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_txn_type_can_withhold(text) from anon';
  execute 'grant execute on function sri_os.fn_txn_type_can_withhold(text) to authenticated';
end $$;

-- ============================================================
-- 2 · "เงินได้ต้องเป็นยอดเต็ม" — กฎอยู่ใน fn_assert_wht_gross_for() ตัวเดียว
--     แล้วผูกสองตาราง: transaction_lines (ของเดิม) + transactions (ข้อ 4 ของผู้ตรวจ)
-- ============================================================
create or replace function fn_assert_wht_gross_for(p_txn uuid) returns void
language plpgsql security definer set search_path = '' as $fn$
declare
  v_type     text;
  v_rate     numeric;
  v_amount   numeric;
  v_clear    text;
  v_wht      numeric;
  v_cash     numeric;
  v_gross    numeric;
  v_expected numeric;
  v_label    text;
begin
  select t.txn_type_code, t.wht_rate, t.wht_amount
    into v_type, v_rate, v_amount
    from sri_os.transactions t where t.id = p_txn;
  if v_type is null then
    return;   -- หัวรายการถูกลบไปแล้ว (cascade) → ไม่มีอะไรให้ตรวจ
  end if;

  -- ยังไม่มีบรรทัดเลย (ระหว่างสร้าง) → ปล่อยผ่าน เหมือน trg_assert_balanced
  if not exists (select 1 from sri_os.transaction_lines l where l.transaction_id = p_txn) then
    return;
  end if;

  /**
   * บัญชีลูกหนี้ที่ใบนี้กำลังล้าง — มีค่าเฉพาะหมวดแบบ (ข) ของข้อ 1
   * (ขาเครดิตเป็นบัญชีค้างรับของหมวดรายได้) · หมวดแบบ (ก) ได้ null
   * เพราะขาเครดิตเป็นบัญชีรายได้อยู่แล้ว ซึ่งนับใน v_gross ทางเดิม
   * → ไม่มีทางนับซ้ำสองรอบ
   */
  select t.cr_coa_code into v_clear
    from sri_os.txn_types t
    join sri_os.chart_of_accounts c on c.code = t.cr_coa_code
   where t.code = v_type
     and c.type <> 'income'
     and exists (
       select 1 from sri_os.txn_types a
         join sri_os.chart_of_accounts ci on ci.code = a.cr_coa_code
        where a.accrual_coa_code = t.cr_coa_code
          and ci.type = 'income'
          and a.cf_group = 'operating');

  select coalesce(sum(case when c.code = '1800' then l.debit - l.credit else 0 end), 0),
         coalesce(sum(case when c.code ~ '^11[0-9][0-9]$' then l.debit - l.credit else 0 end), 0),
         coalesce(sum(case when c.type::text = 'income'
                             or (v_clear is not null and c.code = v_clear)
                           then l.credit - l.debit else 0 end), 0)
    into v_wht, v_cash, v_gross
    from sri_os.transaction_lines l
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where l.transaction_id = p_txn;

  -- ---------- (ก) มีบรรทัด 1800 → ต้องเป็นหมวดที่หักภาษีได้ ----------
  if v_wht <> 0 and not sri_os.fn_txn_type_can_withhold(v_type) then
    raise exception 'ใบนี้มีบรรทัดภาษีถูกหัก ณ ที่จ่าย (1800) แต่หมวด "%" ถูกหักภาษีไม่ได้ — ภาษีหัก ณ ที่จ่ายหักจากเงินได้เท่านั้น (หรือจากการรับชำระลูกหนี้ที่เคยรับรู้รายได้ยอดเต็มไว้แล้ว) ไม่ใช่จากการรับคืนเงินต้น เงินมัดจำ หรือการโอนเงินตัวเอง',
      v_type;
  end if;

  -- ---------- (ข) หัวรายการกับบรรทัดต้องเล่าเรื่องเดียวกัน ----------
  if v_wht <> 0 and v_amount is null then
    raise exception 'ใบนี้มีบรรทัดภาษีถูกหัก ณ ที่จ่าย % บาท แต่หัวรายการไม่ได้บันทึก wht_amount/wht_rate — ยอดที่ไม่มีอัตรากำกับ ตรวจกับใบรับรองการหักภาษีไม่ได้ และขอเครดิตคืนไม่ได้',
      v_wht;
  end if;
  if v_amount is not null and v_wht = 0 then
    raise exception 'หัวรายการบันทึกว่าถูกหักภาษี % บาท แต่ไม่มีบรรทัด 1800 ในใบเลย — สินทรัพย์ภาษีหายไปจากสมุด ทั้งที่เงินที่เข้าบัญชีไม่เต็มจำนวน',
      v_amount;
  end if;
  if v_amount is not null and round(v_wht, 2) <> round(v_amount, 2) then
    raise exception 'ยอดภาษีที่หัวรายการบันทึก (%) ไม่เท่ากับยอดในบรรทัด 1800 (%) — สองตัวเลขนี้คือยอดเดียวกัน ต่างกันแปลว่ารายงานภาษีกับสมุดบัญชีจะไม่ตรงกัน',
      v_amount, v_wht;
  end if;

  if v_wht = 0 then
    return;   -- ไม่ได้ถูกหักภาษี → ไม่มีอะไรต้องตรวจต่อ
  end if;

  -- ---------- (ค) **เงินได้ต้องเป็นยอดเต็ม** ----------
  -- เงินสดคือยอดสุทธิ · 1800 คือส่วนที่ถูกหักไว้ · รวมกันต้องเท่ายอดเต็มของเงินได้
  -- ซึ่งคือเครดิตบัญชีรายได้ (ใบที่รับรู้รายได้พร้อมรับเงิน) หรือเครดิตบัญชีลูกหนี้
  -- ที่กำลังล้าง (ใบรับชำระค้างรับ — รายได้ยอดเต็มรับรู้ไปแล้วตอนตั้งค้าง)
  v_label := case when v_clear is null then 'รายได้ที่รับรู้'
                  else 'ลูกหนี้ที่ปิดในใบนี้ (' || v_clear || ')' end;
  if round(v_gross, 2) <> round(v_cash + v_wht, 2) then
    raise exception '% (%) ต้องเท่ากับ เงินสดที่เข้าบัญชี (%) + ภาษีที่ถูกหักไว้ (%) = % — **เงินได้ต้องเป็นยอดเต็มก่อนหักภาษีเสมอ** ถ้าลงเป็นยอดสุทธิ รายได้จะต่ำกว่าจริง (หรือลูกหนี้จะค้างเท่าภาษีที่ถูกหักโดยไม่มีใครมาจ่ายส่วนนั้นอีก) และเครดิตภาษีจะไม่ตรงใบรับรอง',
      v_label, v_gross, v_cash, v_wht, round(v_cash + v_wht, 2);
  end if;

  -- ---------- (ง) ยอดที่ถูกหักต้องสอดคล้องกับอัตรา ----------
  -- ยอม 1 สตางค์เพราะใบรับรองบางใบปัดเศษ · ความคลาดจากการกรอกยอดสุทธิจะใหญ่กว่านี้เสมอ
  v_expected := round(v_gross * v_rate / 100, 2);
  if abs(round(v_wht - v_expected, 2)) > 0.01 then
    raise exception 'ภาษีที่ถูกหัก (%) ไม่ตรงกับ % %% ของเงินได้เต็มจำนวน % (ควรเป็น %) — ถ้าตัวเลขในใบรับรองถูก แปลว่ายอดที่ลงไว้ไม่ใช่ยอดเต็ม',
      v_wht, v_rate, v_gross, v_expected;
  end if;
end $fn$;

comment on function fn_assert_wht_gross_for(uuid) is
  'D-111 ข้อ 1 · เนื้อกฎ "เงินได้ต้องเป็นยอดเต็ม" ที่เดียว: เครดิตบัญชีรายได้ (หรือเครดิตบัญชีลูกหนี้ที่ใบนี้ล้าง) = เดบิตเงินสด + เดบิต 1800 · และยอดในหัวรายการต้องตรงกับบรรทัด · เรียกจาก trigger สองตัว (transaction_lines + transactions) เพื่อไม่ให้แก้ยอดภาษีย้อนหลังได้โดยไม่มีใครตรวจ (ข้อ 4 ของผู้ตรวจ)';

revoke all on function fn_assert_wht_gross_for(uuid) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_wht_gross_for(uuid) from anon, authenticated';
end $$;

-- trigger ฝั่งบรรทัด (ของเดิม · ชื่อและรูปเดิมเพื่อให้เทสต์โครงสร้าง W0 ยังจริง)
create or replace function fn_assert_wht_gross() returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  perform sri_os.fn_assert_wht_gross_for(coalesce(new.transaction_id, old.transaction_id));
  return null;
end $fn$;

comment on function fn_assert_wht_gross() is
  'D-111 ข้อ 1 · trigger ฝั่ง transaction_lines ของ fn_assert_wht_gross_for() · constraint trigger แบบ deferred เพราะต้องอ่านทุกบรรทัดของใบ';

revoke all on function fn_assert_wht_gross() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_wht_gross() from anon, authenticated';
end $$;

drop trigger if exists trg_assert_wht_gross on transaction_lines;
create constraint trigger trg_assert_wht_gross
  after insert or update or delete on transaction_lines
  deferrable initially deferred
  for each row execute function fn_assert_wht_gross();

/**
 * trigger ฝั่งหัวรายการ — **ข้อ 4 ของผู้ตรวจ**
 *
 * ของเดิมผูกแต่ `transaction_lines` → `update transactions set wht_amount = 1`
 * ของใบที่ post แล้ว **ไม่มีอะไรตรวจเลย** เพราะไม่มีบรรทัดไหนถูกแตะ
 * ฝั่ง personal_flexible ที่แก้รายการที่ post แล้วได้ (ผ่าน reverse + ลงใหม่
 * เบื้องหลัง แต่ตัว UPDATE ยังผ่านได้ในงวดที่ยังไม่ปิด) จึงแก้ตัวเลขภาษี
 * ย้อนหลังให้ไม่ตรงกับสมุดได้ โดยที่รายงานภาษีกับสมุดแยกจากกันเงียบๆ
 *
 * ยิงเฉพาะตอนที่สามช่องนั้นเปลี่ยนจริง (`when`) — ไม่ใช่ทุก UPDATE ของหัวรายการ
 * เพราะใบที่ไม่เกี่ยวกับภาษีไม่ควรเสียเวลาไล่บรรทัดทั้งใบ
 * INSERT ต้องตรวจด้วย: ลงหัวรายการที่บอกว่าถูกหักภาษีแต่ไม่มีบรรทัด 1800
 * จะถูกจับตอน commit (ใบที่ยังไม่มีบรรทัดเลยปล่อยผ่าน — ดู fn_assert_wht_gross_for)
 */
create or replace function fn_assert_wht_gross_txn() returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  perform sri_os.fn_assert_wht_gross_for(coalesce(new.id, old.id));
  return null;
end $fn$;

comment on function fn_assert_wht_gross_txn() is
  'ข้อ 4 ของผู้ตรวจ · trigger ฝั่ง transactions ของ fn_assert_wht_gross_for() · ปิดช่องที่แก้ wht_rate/wht_amount/wht_certificate_no ของใบที่ post แล้วได้โดยไม่มีด่านไหนตรวจ (ด่านเดิมผูกแต่ transaction_lines)';

revoke all on function fn_assert_wht_gross_txn() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_wht_gross_txn() from anon, authenticated';
end $$;

drop trigger if exists trg_assert_wht_gross_txn on transactions;
create constraint trigger trg_assert_wht_gross_txn
  after insert or update of wht_rate, wht_amount, wht_certificate_no on transactions
  deferrable initially deferred
  for each row execute function fn_assert_wht_gross_txn();

-- ============================================================
-- 3 · fn_post_entry — รับสามช่องของภาษีหัก ณ ที่จ่าย
--
-- **เนื้อในยกมาจาก 20261008000013 ครบทุกบรรทัด** (ตรวจรูปของ payload · ช่องที่ไม่รู้จัก
-- ปฏิเสธทั้งใบ · ข้ามผู้ถือครบคู่ · cash_date ตามบรรทัดที่เครื่องยนต์ส่งมา ·
-- fingerprint จาก payload ที่ normalise แล้ว) สิ่งที่เพิ่มคือ **สามช่องเท่านั้น**:
--   'wht_rate' · 'wht_amount' · 'wht_certificate_no' ในรายการช่องที่รู้จัก
--   + ตรวจรูป (อัตรากับยอดมาคู่กัน) + เขียนลงหัวรายการจริง
--
-- **ไม่เอาด่านคู่บัญชี/ด่าน bank กลับเข้าประตู** (013 ถอดออกเพราะเป็นกฎที่สอง)
-- บรรทัด 1800 และ 3400 ถูกยอมรับที่ trg_lines_rule_coa ซึ่งอ่าน
-- fn_txn_type_can_withhold() ตัวที่ข้อ 1 เพิ่งขยาย → หมวดรับชำระค้างรับ
-- จึงลงบรรทัด 1800 ได้ทันทีโดยไม่ต้องแก้ด่านนั้นเลย
-- ============================================================
create or replace function fn_post_entry(p_payload jsonb) returns jsonb
language plpgsql set search_path = '' as $fn$
declare
  c_header constant text[] := array[
    'txn_type_code', 'doc_date', 'cash_date', 'doc_no', 'memo', 'attachments',
    'asset_id', 'contact_id', 'contract_id', 'owner_reason', 'funding_source',
    'source', 'source_ref', 'reverses_id',
    -- D-111 ข้อ 1 · ภาษีหัก ณ ที่จ่าย — **สามช่องนี้คือสิ่งที่ไฟล์นี้เพิ่ม**
    -- ก่อนหน้านี้ส่งมาไม่ได้เลย (เด้ง "ช่องที่ยังไม่รู้จัก") และถ้าไม่ส่ง
    -- หัวรายการจะเป็น null แล้ว fn_assert_wht_gross ปฏิเสธตอน commit
    -- → บันทึกการถูกหักภาษี **ตันทั้งสองทาง**
    'wht_rate', 'wht_amount', 'wht_certificate_no',
    'transactions'];
  c_txn    constant text[] := array['owner_id', 'counter_owner_id', 'intercompany_nature', 'lines'];
  c_line   constant text[] := array['coa_code', 'bank_account_id', 'asset_id',
                                    'debit', 'credit', 'cf_category', 'memo'];
  v_bad      text;
  v_source   text;
  v_has_cash boolean := false;
  v_i        int := 0;
  v_j        int;
  v_dr       numeric;
  v_cr       numeric;
  v_txn      jsonb;
  v_line     jsonb;
  v_coa      uuid;
  v_txn_id   uuid;
  v_ids      uuid[] := '{}';
  v_prev     uuid[];
  v_fp       text;
  v_canon    jsonb;
  v_secs     numeric;
  v_req      uuid;
  v_doc      date;
  v_cash     date;
  v_wht_rate numeric;
  v_wht_amt  numeric;
  v_wht_cert text;
  v_allowed  text[];
  v_nature   text;
begin
  -- ========== 0 · ไม่ส่งข้อมูลมาเลย = ปฏิเสธ ห้ามตกไปเส้นทางปกติ (บทเรียนข้อ 1) ==========
  if p_payload is null or jsonb_typeof(p_payload) = 'null' then
    raise exception 'บันทึกรายการไม่ได้: ไม่ได้ส่งข้อมูลรายการมาเลย';
  end if;
  if jsonb_typeof(p_payload) <> 'object' then
    raise exception 'บันทึกรายการไม่ได้: รูปแบบข้อมูลไม่ถูกต้อง — ต้องเป็น object ของทั้งใบ ไม่ใช่ %',
      jsonb_typeof(p_payload);
  end if;

  select string_agg(k, ', ' order by k) into v_bad
    from jsonb_object_keys(p_payload) as k where k <> all (c_header);
  if v_bad is not null then
    raise exception 'บันทึกรายการไม่ได้: มีช่องที่ยังไม่รู้จัก (%) — RPC ปฏิเสธทั้งใบแทนที่จะทิ้งช่องนั้นเงียบๆ · ช่องที่รับคือ %',
      v_bad, array_to_string(c_header, ', ');
  end if;

  -- ========== 1 · ผู้เรียกต้องมีตัวตนในระบบ ==========
  if auth.uid() is null then
    raise exception 'บันทึกรายการไม่ได้: ยังไม่ได้ล็อกอิน';
  end if;
  if not exists (select 1 from sri_os.app_users u where u.id = auth.uid() and u.is_active) then
    raise exception 'บันทึกรายการไม่ได้: ผู้ใช้นี้ยังไม่ได้ถูกตั้งตำแหน่งในระบบ หรือถูกปิดใช้งานแล้ว';
  end if;

  -- ========== 2 · ช่องบังคับของหัวรายการ ==========
  if nullif(p_payload ->> 'txn_type_code', '') is null then
    raise exception 'บันทึกรายการไม่ได้: ไม่ได้ส่ง txn_type_code (หมวดย่อยของรายการ)';
  end if;
  if not exists (select 1 from sri_os.txn_types t where t.code = p_payload ->> 'txn_type_code') then
    raise exception 'บันทึกรายการไม่ได้: ไม่มีหมวด "%" ในตารางกฎ (txn_types) — ตารางกฎคือแหล่งความจริงเดียว ถ้าเพิ่มหมวดใหม่ให้ sync ด้วย npm run sync:rules',
      p_payload ->> 'txn_type_code';
  end if;
  if nullif(p_payload ->> 'doc_date', '') is null then
    raise exception 'บันทึกรายการไม่ได้: ไม่ได้ส่ง doc_date (วันที่เอกสาร)';
  end if;

  -- วันที่: แปลงที่นี่ครั้งเดียว เพื่อให้ได้ข้อความภาษาคนแทน error ดิบของการ cast
  -- และเพื่อให้ "2026-09-01" กับรูปอื่นของวันเดียวกันได้ fingerprint เดียวกัน (ข้อ 4)
  begin
    v_doc := (p_payload ->> 'doc_date')::date;
  exception when others then
    raise exception 'บันทึกรายการไม่ได้: doc_date "%" ไม่ใช่วันที่ที่อ่านได้ (ต้องเป็น YYYY-MM-DD)',
      p_payload ->> 'doc_date';
  end;
  if nullif(p_payload ->> 'cash_date', '') is not null then
    begin
      v_cash := (p_payload ->> 'cash_date')::date;
    exception when others then
      raise exception 'บันทึกรายการไม่ได้: cash_date "%" ไม่ใช่วันที่ที่อ่านได้ (ต้องเป็น YYYY-MM-DD)',
        p_payload ->> 'cash_date';
    end;
  end if;

  v_source := coalesce(nullif(p_payload ->> 'source', ''), 'manual');
  if not exists (
       select 1 from pg_catalog.pg_enum e
         join pg_catalog.pg_type t on t.oid = e.enumtypid
         join pg_catalog.pg_namespace n on n.oid = t.typnamespace
        where n.nspname = 'sri_os' and t.typname = 'txn_source' and e.enumlabel = v_source) then
    raise exception 'บันทึกรายการไม่ได้: source "%" ไม่รู้จัก', v_source;
  end if;

  if p_payload -> 'attachments' is not null
     and jsonb_typeof(p_payload -> 'attachments') <> 'array' then
    raise exception 'บันทึกรายการไม่ได้: attachments ต้องเป็น array ของชื่อไฟล์';
  end if;

  -- ========== 2.1 · ภาษีหัก ณ ที่จ่าย (D-111 ข้อ 1) ==========
  -- ตรวจ **รูปของข้อมูล** ที่นี่เพื่อให้ได้ข้อความภาษาคนแทน error ดิบของ constraint
  -- ส่วนกฎบัญชี ("เงินได้ต้องเป็นยอดเต็ม") อยู่ที่ fn_assert_wht_gross_for() ที่เดียว
  -- ซึ่งอ่านทุกบรรทัดของใบตอน commit — **ไม่ได้ทำสำเนากฎไว้ในประตู** (บทเรียนข้อ 5)
  if (p_payload -> 'wht_rate') is not null
     and jsonb_typeof(p_payload -> 'wht_rate') not in ('number', 'null') then
    raise exception 'บันทึกรายการไม่ได้: wht_rate ต้องเป็นตัวเลข (ร้อยละ) ไม่ใช่ %',
      jsonb_typeof(p_payload -> 'wht_rate');
  end if;
  if (p_payload -> 'wht_amount') is not null
     and jsonb_typeof(p_payload -> 'wht_amount') not in ('number', 'null') then
    raise exception 'บันทึกรายการไม่ได้: wht_amount ต้องเป็นตัวเลข (บาท) ไม่ใช่ %',
      jsonb_typeof(p_payload -> 'wht_amount');
  end if;
  v_wht_rate := (p_payload ->> 'wht_rate')::numeric;
  v_wht_amt  := (p_payload ->> 'wht_amount')::numeric;
  v_wht_cert := nullif(btrim(coalesce(p_payload ->> 'wht_certificate_no', '')), '');

  -- อัตรากับยอดต้องมาคู่กันเสมอ (constraint transactions_wht_shape กันไว้อีกชั้น
  -- แต่ข้อความของ constraint อ่านไม่รู้เรื่องสำหรับคนกดปุ่ม)
  if (v_wht_rate is null) <> (v_wht_amt is null) then
    raise exception 'บันทึกรายการไม่ได้: ภาษีหัก ณ ที่จ่ายต้องส่งทั้งอัตรา (wht_rate) และยอดที่ถูกหัก (wht_amount) คู่กัน — มียอดแต่ไม่มีอัตราจะตรวจกับใบรับรองไม่ได้ · มีอัตราแต่ไม่มียอดจะไม่รู้ว่าสินทรัพย์ภาษีเป็นเท่าไร';
  end if;
  if v_wht_cert is not null and v_wht_amt is null then
    raise exception 'บันทึกรายการไม่ได้: ส่งเลขที่ใบรับรองการหักภาษีมาแต่ใบนี้ไม่ได้ถูกหักภาษี — เลขที่ใบรับรองติดได้เฉพาะใบที่ถูกหักจริง';
  end if;

  if p_payload -> 'transactions' is null then
    raise exception 'บันทึกรายการไม่ได้: ไม่ได้ส่ง transactions (ผลลัพธ์จาก buildPosting)';
  end if;
  if jsonb_typeof(p_payload -> 'transactions') <> 'array' then
    raise exception 'บันทึกรายการไม่ได้: transactions ต้องเป็น array (หนึ่งสมาชิก = หนึ่งผู้ถือ)';
  end if;
  if jsonb_array_length(p_payload -> 'transactions') = 0 then
    raise exception 'บันทึกรายการไม่ได้: ไม่มีรายการใน transactions เลย';
  end if;

  -- ========== 3 · ตรวจรูปของทุกรายการ/ทุกบรรทัด **ก่อนเขียนอะไรลงไป** ==========
  for v_txn in select value from jsonb_array_elements(p_payload -> 'transactions') loop
    v_i := v_i + 1;
    if jsonb_typeof(v_txn) <> 'object' then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ต้องเป็น object', v_i;
    end if;

    select string_agg(k, ', ' order by k) into v_bad
      from jsonb_object_keys(v_txn) as k where k <> all (c_txn);
    if v_bad is not null then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % มีช่องที่ยังไม่รู้จัก (%) · ช่องที่รับคือ %',
        v_i, v_bad, array_to_string(c_txn, ', ');
    end if;

    if nullif(v_txn ->> 'owner_id', '') is null then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ไม่ได้ส่ง owner_id (ผู้ถือ) — หนึ่งรายการ = หนึ่งผู้ถือ เดาแทนไม่ได้', v_i;
    end if;

    -- ข้ามผู้ถือต้องมาเป็นคู่: ขาดข้างใดข้างหนึ่งแปลว่าข้อมูลไม่ครบ ไม่ใช่รายการธรรมดา
    if nullif(v_txn ->> 'counter_owner_id', '') is not null
       and nullif(v_txn ->> 'intercompany_nature', '') is null then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % เป็นรายการข้ามผู้ถือ ต้องระบุลักษณะ (intercompany_nature: advance/loan/capital/dividend)', v_i;
    end if;
    if nullif(v_txn ->> 'intercompany_nature', '') is not null
       and nullif(v_txn ->> 'counter_owner_id', '') is null then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ระบุลักษณะข้ามผู้ถือแต่ไม่มีผู้ถืออีกฝ่าย (counter_owner_id)', v_i;
    end if;
    if nullif(v_txn ->> 'counter_owner_id', '') is not null
       and (v_txn ->> 'counter_owner_id') = (v_txn ->> 'owner_id') then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ระบุผู้ถืออีกฝ่ายเป็นคนเดียวกับผู้ถือของรายการ — ถ้าเป็นการย้ายกระเป๋าในคนเดียวกัน ไม่ใช่รายการข้ามผู้ถือ', v_i;
    end if;

    if v_txn -> 'lines' is null or jsonb_typeof(v_txn -> 'lines') <> 'array' then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ไม่ได้ส่ง lines เป็น array', v_i;
    end if;
    if jsonb_array_length(v_txn -> 'lines') < 2 then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % มีบรรทัดบัญชี % บรรทัด — บัญชีสองด้านต้องมีอย่างน้อยสองบรรทัด',
        v_i, jsonb_array_length(v_txn -> 'lines');
    end if;

    -- ---------- 3.1 ชุดบัญชีที่หมวดนี้ใช้ได้ — อ่านจากตารางกฎ ไม่ได้คิดเอง (ข้อ 3) ----------
    select array_remove(array[t.dr_coa_code, t.cr_coa_code, t.gain_coa_code,
                              t.loss_coa_code, t.interest_coa_code, t.accrual_coa_code], null)
      into v_allowed
      from sri_os.txn_types t where t.code = p_payload ->> 'txn_type_code';
    if v_allowed is null or cardinality(v_allowed) = 0 then
      raise exception 'บันทึกรายการไม่ได้: ตารางกฎ (txn_types) ไม่ได้ระบุบัญชีของหมวด "%" เลย — sync ด้วย npm run sync:rules ก่อน ห้ามเดาคู่บัญชีแทน',
        p_payload ->> 'txn_type_code';
    end if;

    -- ---------- 3.2 ลักษณะข้ามผู้ถือต้องเป็นลักษณะที่ฝั่ง DB รู้จัก (ห้ามเดา) ----------
    -- **ไม่มีสำเนาคู่บัญชีในฟังก์ชันนี้แล้ว** — อ่านจาก fn_intercompany_pairs() ที่เดียว
    --   ด่าน "ขาข้ามผู้ถือต้องเป็นรหัสตรงของลักษณะนั้น" อยู่ที่ trg_lines_rule_coa
    --   ที่นี่เหลือแค่การปฏิเสธลักษณะที่ไม่รู้จัก **ก่อนเขียนอะไรลงไป** เพื่อให้ได้
    --   ข้อความภาษาคน ไม่ใช่ error ดิบของ check constraint
    v_nature := nullif(v_txn ->> 'intercompany_nature', '');
    if v_nature is not null and sri_os.fn_intercompany_coa(v_nature) is null then
      raise exception 'บันทึกรายการไม่ได้: ลักษณะรายการข้ามผู้ถือ "%" ไม่รู้จัก (ที่รับคือ %)',
        v_nature,
        coalesce((select string_agg(p.nature, '/' order by p.nature)
                    from sri_os.fn_intercompany_pairs() p), '(ยังไม่มีลักษณะใดในฝั่ง DB)');
    end if;

    v_j := 0;
    for v_line in select value from jsonb_array_elements(v_txn -> 'lines') loop
      v_j := v_j + 1;
      if jsonb_typeof(v_line) <> 'object' then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % ต้องเป็น object', v_i, v_j;
      end if;

      select string_agg(k, ', ' order by k) into v_bad
        from jsonb_object_keys(v_line) as k where k <> all (c_line);
      if v_bad is not null then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % มีช่องที่ยังไม่รู้จัก (%) · ช่องที่รับคือ %',
          v_i, v_j, v_bad, array_to_string(c_line, ', ');
      end if;

      if nullif(v_line ->> 'coa_code', '') is null then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % ไม่ได้ส่ง coa_code', v_i, v_j;
      end if;
      select c.id into v_coa
        from sri_os.chart_of_accounts c where c.code = v_line ->> 'coa_code';
      if v_coa is null then
        raise exception 'บันทึกรายการไม่ได้: ไม่มีรหัส "%" ในผังบัญชี (chart_of_accounts) — ผังบัญชีในฐานข้อมูลอาจยังไม่ sync กับ src/lib/rules/coa.ts',
          v_line ->> 'coa_code';
      end if;

      if (v_line -> 'debit') is null and (v_line -> 'credit') is null then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % ไม่ได้ส่งทั้งเดบิตและเครดิต', v_i, v_j;
      end if;
      if (v_line -> 'debit') is not null and jsonb_typeof(v_line -> 'debit') not in ('number', 'null') then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % เดบิตต้องเป็นตัวเลข', v_i, v_j;
      end if;
      if (v_line -> 'credit') is not null and jsonb_typeof(v_line -> 'credit') not in ('number', 'null') then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % เครดิตต้องเป็นตัวเลข', v_i, v_j;
      end if;
      v_dr := coalesce((v_line ->> 'debit')::numeric, 0);
      v_cr := coalesce((v_line ->> 'credit')::numeric, 0);
      if v_dr < 0 or v_cr < 0 then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % มียอดติดลบ (เดบิต % เครดิต %) — ทิศทางมาจากด้านที่ลง ไม่ใช่จากเครื่องหมาย',
          v_i, v_j, v_dr, v_cr;
      end if;
      if not ((v_dr > 0 and v_cr = 0) or (v_cr > 0 and v_dr = 0)) then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % ต้องลงด้านเดียวและมากกว่า 0 (เดบิต % เครดิต %)',
          v_i, v_j, v_dr, v_cr;
      end if;

      if nullif(v_line ->> 'cf_category', '') is not null
         and not exists (
           select 1 from pg_catalog.pg_enum e
             join pg_catalog.pg_type t on t.oid = e.enumtypid
             join pg_catalog.pg_namespace n on n.oid = t.typnamespace
            where n.nspname = 'sri_os' and t.typname = 'cf_group'
              and e.enumlabel = v_line ->> 'cf_category') then
        raise exception 'บันทึกรายการไม่ได้: หมวดกระแสเงินสด "%" ไม่รู้จัก', v_line ->> 'cf_category';
      end if;

      -- ผังบัญชี 1100-1199 = เงินสดและเงินฝาก (เกณฑ์เดียวกับ fn_assert_no_floating_cash)
      if (v_line ->> 'coa_code') ~ '^11[0-9][0-9]$' then v_has_cash := true; end if;
    end loop;
  end loop;

  -- ========== 3.4 · ข้ามผู้ถือต้องมาครบคู่ในคำขอเดียว (ข้อ 2 · ข้อความที่อ่านรู้เรื่อง) ==========
  -- ด่านจริงคือ trg_intercompany_pair (constraint trigger) ที่ครอบ REST ตรงด้วย
  -- ที่นี่ตรวจซ้ำเพื่อให้ผู้กดได้ข้อความก่อนที่อะไรจะถูกเขียน ไม่ใช่กฎที่สองที่คิดต่างกัน
  with legs as (
    select (x.value ->> 'owner_id') as o,
           nullif(x.value ->> 'counter_owner_id', '') as c,
           nullif(x.value ->> 'intercompany_nature', '') as n,
           (select coalesce(sum(coalesce((l.value ->> 'debit')::numeric, 0)), 0)
              from jsonb_array_elements(x.value -> 'lines') as l) as amt
      from jsonb_array_elements(p_payload -> 'transactions') as x
  )
  select string_agg(distinct a.o, ', ') into v_bad
    from legs a
   where a.c is not null
     and (select count(*) from legs b
           where b.o = a.o and b.c = a.c and b.n = a.n and b.amt = a.amt)
      <> (select count(*) from legs b
           where b.o = a.c and b.c = a.o and b.n = a.n and b.amt = a.amt);
  if v_bad is not null then
    raise exception 'บันทึกรายการไม่ได้: รายการข้ามผู้ถือต้องมาครบคู่ในคำขอเดียว (ขาออกของผู้ถือหนึ่ง + ขาเข้าของอีกผู้ถือ ยอดเท่ากัน) — ขาของผู้ถือ % ไม่มีขาคู่ · ขาเดียวแปลว่าเงินหายไปข้างหนึ่งและงบรวมตัดรายการระหว่างกันไม่ลง',
      v_bad;
  end if;

  -- ========== 4 · cash_date ต้องสอดคล้องกับบรรทัดที่เครื่องยนต์ส่งมา ==========
  if v_has_cash and v_cash is null then
    raise exception 'บันทึกรายการไม่ได้: รายการนี้มีบรรทัดเงินสด/เงินฝาก แต่ไม่ได้ส่ง cash_date (วันที่เงินเข้า-ออกจริง) — ถ้าเงินยังไม่เคลื่อน ต้องลงเป็นลูกหนี้/เจ้าหนี้ ไม่ใช่เงินสด';
  end if;
  if not v_has_cash and v_cash is not null then
    raise exception 'บันทึกรายการไม่ได้: รายการนี้ไม่มีบรรทัดเงินสดเลย (ค้างรับ-ค้างจ่าย) cash_date ต้องเป็น null ไม่งั้นงบกระแสเงินสดจะนับเงินที่ยังไม่เคลื่อน';
  end if;

  -- ========== 5 · กันกดปุ่มซ้ำ — ล็อกแถว fingerprint ก่อนลงรายการ ==========
  select coalesce((s.value #>> '{}')::numeric, 60) into v_secs
    from sri_os.settings s where s.key = 'ledger.post_dedupe_seconds';
  v_secs := greatest(coalesce(v_secs, 60), 0);

  -- ข้อ 4: normalise ก่อนคิด fingerprint · วันที่/source ใช้ค่าที่ฟังก์ชันจะใช้จริง
  v_canon := sri_os.fn_canonical_payload(p_payload);
  v_canon := jsonb_set(v_canon, '{doc_date}', to_jsonb(v_doc::text));
  if v_cash is null then
    v_canon := v_canon - 'cash_date';
  else
    v_canon := jsonb_set(v_canon, '{cash_date}', to_jsonb(v_cash::text));
  end if;
  v_canon := jsonb_set(v_canon, '{source}', to_jsonb(v_source));

  v_fp := encode(sha256(convert_to(auth.uid()::text || '|' || v_canon::text, 'UTF8')), 'hex');

  insert into sri_os.post_entry_requests as r (fingerprint)
  values (v_fp)
      on conflict (fingerprint) do update
         set created_at = now(), transaction_ids = '{}'::uuid[]
       where r.created_at < now() - make_interval(secs => v_secs::double precision)
  returning r.id into v_req;

  if v_req is null then
    -- คำขอเดิมซ้ำในหน้าต่าง = กดรัว · คืน id ชุดเดิมโดยไม่ลงใหม่
    select r.transaction_ids into v_prev
      from sri_os.post_entry_requests r where r.fingerprint = v_fp;
    return jsonb_build_object(
      'transaction_ids', coalesce(to_jsonb(v_prev), '[]'::jsonb),
      'replayed', true,
      'fingerprint', v_fp);
  end if;

  -- ========== 6 · เขียนลงจริง — หัวรายการ + บรรทัด ในธุรกรรมเดียวกัน (D-091) ==========
  -- created_by ไม่อยู่ในรายการคอลัมน์โดยตั้งใจ: trigger ตั้งเป็น auth.uid() ให้ (ข้อ 5)
  for v_txn in select value from jsonb_array_elements(p_payload -> 'transactions') loop
    insert into sri_os.transactions (
      owner_id, txn_type_code, doc_date, cash_date, doc_no, memo, attachments,
      asset_id, contact_id, contract_id, owner_reason, funding_source,
      source, source_ref, reverses_id,
      wht_rate, wht_amount, wht_certificate_no,
      is_intercompany, counter_owner_id, intercompany_nature)
    values (
      (v_txn ->> 'owner_id')::uuid,
      p_payload ->> 'txn_type_code',
      v_doc,
      v_cash,
      nullif(p_payload ->> 'doc_no', ''),
      nullif(p_payload ->> 'memo', ''),
      coalesce((select array_agg(a) from jsonb_array_elements_text(p_payload -> 'attachments') as a),
               '{}'::text[]),
      (nullif(p_payload ->> 'asset_id', ''))::uuid,
      (nullif(p_payload ->> 'contact_id', ''))::uuid,
      (nullif(p_payload ->> 'contract_id', ''))::uuid,
      nullif(p_payload ->> 'owner_reason', ''),
      nullif(p_payload ->> 'funding_source', ''),
      v_source::sri_os.txn_source,
      nullif(p_payload ->> 'source_ref', ''),
      (nullif(p_payload ->> 'reverses_id', ''))::uuid,
      v_wht_rate, v_wht_amt, v_wht_cert,
      nullif(v_txn ->> 'counter_owner_id', '') is not null,
      (nullif(v_txn ->> 'counter_owner_id', ''))::uuid,
      nullif(v_txn ->> 'intercompany_nature', ''))
    returning id into v_txn_id;

    for v_line in select value from jsonb_array_elements(v_txn -> 'lines') loop
      insert into sri_os.transaction_lines (
        transaction_id, coa_id, bank_account_id, debit, credit, cf_category, asset_id, memo)
      values (
        v_txn_id,
        (select c.id from sri_os.chart_of_accounts c where c.code = v_line ->> 'coa_code'),
        (nullif(v_line ->> 'bank_account_id', ''))::uuid,
        coalesce((v_line ->> 'debit')::numeric, 0),
        coalesce((v_line ->> 'credit')::numeric, 0),
        (nullif(v_line ->> 'cf_category', ''))::sri_os.cf_group,
        (nullif(v_line ->> 'asset_id', ''))::uuid,
        nullif(v_line ->> 'memo', ''));
    end loop;

    v_ids := v_ids || v_txn_id;
  end loop;

  update sri_os.post_entry_requests r
     set transaction_ids = v_ids
   where r.id = v_req;

  -- ด่านสมดุล/บรรทัดครบ/คู่ข้ามผู้ถือเป็น constraint trigger แบบ deferred (ยิงตอน commit)
  -- → บังคับให้ยิง **ตอนนี้** เพื่อให้คนกดปุ่มได้ข้อความที่อ่านรู้เรื่องทันที
  --   นี่คือการทำให้ด่าน **เข้มขึ้น (เร็วขึ้น)** ไม่ใช่ผ่อน · แล้วคืนสภาพ deferred ให้เหมือนเดิม
  set constraints all immediate;
  set constraints all deferred;

  return jsonb_build_object(
    'transaction_ids', to_jsonb(v_ids),
    'replayed', false,
    'fingerprint', v_fp);
end $fn$;

comment on function fn_post_entry(jsonb) is
  'ปากทางเดียวที่เขียนผลลัพธ์ของ buildPosting() ลง transactions + transaction_lines ในธุรกรรมเดียว (D-091) · **security invoker** → RLS เป็นด่านเดียว · ไม่ตรวจคู่บัญชีเอง (กฎนั้นอยู่ที่ trg_lines_rule_coa ที่เดียว ตั้งแต่ 20261008000013) · **รับช่อง wht_rate/wht_amount/wht_certificate_no แล้ว (D-111 ข้อ 1)** ซึ่งก่อนหน้านี้ทำให้บันทึกการถูกหักภาษี ณ ที่จ่ายไม่ได้เลยทุกทาง · ข้ามผู้ถือต้องครบคู่ · fingerprint คิดจาก payload ที่ normalise แล้ว';

-- ------------------------------------------------------------
-- 4 · ACL — create or replace ไม่ล้าง ACL เดิม แต่ย้ำไว้ให้ไฟล์นี้รันเองได้
-- ------------------------------------------------------------
revoke all on function fn_post_entry(jsonb) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_post_entry(jsonb) from anon';
  execute 'grant execute on function sri_os.fn_post_entry(jsonb) to authenticated';
end $$;

-- ============================================================
-- 5 · guard ท้ายไฟล์ — ดังตอน migrate ไม่ใช่ตอนผู้ใช้กดบันทึก
-- ============================================================
do $$
declare n int; v text; v_src text;
begin
  v_src := pg_get_functiondef('sri_os.fn_post_entry(jsonb)'::regprocedure);

  -- (ก) ประตูต้องรู้จักช่อง wht_* จริง (ไล่จาก catalog ไม่ใช่จากไฟล์)
  select string_agg(x.k, ', ') into v
    from unnest(array['wht_rate', 'wht_amount', 'wht_certificate_no']) x(k)
   where v_src not like '%' || x.k || '%';
  if v is not null then
    raise exception 'fn_post_entry ยังไม่รู้จักช่อง % — ลงรายการที่ถูกหักภาษี ณ ที่จ่ายไม่ได้เลย (มีไฟล์อื่นเขียนทับหลังไฟล์นี้?)', v;
  end if;

  -- (ข) **ห้ามเอาด่านที่ 20261008000013 ถอดออกกลับเข้าประตู** (zz_line_guards G0)
  --     ถ้าไฟล์นี้เผลอยกเนื้อของ 011 มา กฎคู่บัญชีจะมีสองที่อีกครั้ง
  if v_src ~ 'ระบุบัญชีของหมวดนี้ไว้เฉพาะ' or v_src ~ 'ซึ่งไม่ใช่เงินสด/เงินฝาก' then
    raise exception 'ประตู fn_post_entry มีด่านคู่บัญชี/ด่าน bank ของตัวเองอีกแล้ว — กฎเดียวกันสองที่ (ไฟล์นี้ต้องยกเนื้อจาก 20261008000013 ไม่ใช่ 20261008000011)';
  end if;
  if v_src !~ 'txn_types' then
    raise exception 'ประตู fn_post_entry ไม่ได้อ่านตารางกฎแล้ว';
  end if;

  -- (ค) ค่าเช่าที่ตั้งค้างแล้วถูกหักภาษี **ต้องลงได้** (ข้อ 3 ของผู้ตรวจ)
  if not sri_os.fn_txn_type_can_withhold('inv.collect_rent') then
    raise exception 'inv.collect_rent ยังถูกหักภาษี ณ ที่จ่ายไม่ได้ — ค่าเช่าที่ออกใบแจ้งหนี้ไว้แล้วผู้เช่าหัก 5%% ตอนจ่าย จะลงไม่ได้ทุกทาง';
  end if;
  if not sri_os.fn_txn_type_can_withhold('inc.rent') then
    raise exception 'inc.rent ถูกหักภาษีไม่ได้ = เส้นทางหลักหาย';
  end if;
  -- และต้องไม่กว้างเกิน: ขอคืนภาษี/โอนเงินตัวเอง/รับคืนเงินต้น/จ่ายออก ห้ามถูกหักภาษี
  select string_agg(x.code, ', ') into v
    from unnest(array['inv.wht_refund', 'trf.internal', 'inv.srr_redeem',
                      'exp.repair', 'adj.revalue_securities_up']) x(code)
   where sri_os.fn_txn_type_can_withhold(x.code);
  if v is not null then
    raise exception 'หมวดที่ไม่ควรถูกหักภาษี ณ ที่จ่ายกลับผ่านเกณฑ์: % — เกณฑ์กว้างเกินไป แปลว่าบรรทัด 1800 ลงได้กับใบที่ไม่ใช่เงินได้', v;
  end if;

  -- (ง) 1800 ต้องมีทางล้าง (บทเรียนข้อ 7)
  select count(*) into n from sri_os.txn_types t
   where t.cr_coa_code = '1800' and t.dr_coa_code ~ '^11[0-9][0-9]$';
  if n = 0 then
    raise exception 'ไม่มีหมวดใดที่ล้างบัญชี 1800 ได้เลย — เปิดให้บันทึกการถูกหักภาษีแต่ล้างไม่ได้ แปลว่ายอดเครดิตภาษีโตขึ้นตลอดไป';
  end if;

  -- (จ) ด่านต้องผูกทั้งสองตาราง และเป็น constraint trigger แบบ deferred ทั้งคู่
  select string_agg(x.want, ', ') into v
    from (values ('transaction_lines', 'trg_assert_wht_gross'),
                 ('transactions', 'trg_assert_wht_gross_txn')) x(tbl, want)
   where not exists (
     select 1 from pg_trigger g
      where g.tgrelid = ('sri_os.' || x.tbl)::regclass
        and g.tgname = x.want and not g.tgisinternal
        and g.tgdeferrable and g.tginitdeferred);
  if v is not null then
    raise exception 'trigger ของกฎภาษีหัก ณ ที่จ่ายหายไปหรือไม่ใช่ constraint trigger แบบ deferred: % — ด่านที่ผูกแต่ตารางบรรทัด ทำให้แก้ยอดภาษีที่หัวรายการย้อนหลังได้โดยไม่มีใครจับ (ข้อ 4)', v;
  end if;

  -- (ฉ) ฟังก์ชันด่านที่เป็น definer ต้องเรียกตรงไม่ได้ (D-089)
  select string_agg(x.f, ', ') into v
    from unnest(array['sri_os.fn_assert_wht_gross_for(uuid)', 'sri_os.fn_assert_wht_gross()',
                      'sri_os.fn_assert_wht_gross_txn()']) x(f)
   where has_function_privilege('authenticated', x.f, 'execute')
      or has_function_privilege('anon', x.f, 'execute');
  if v is not null then
    raise exception 'ฟังก์ชันด่านที่เป็น definer ยังเรียกตรงได้: % = ทางข้าม policy ของสมุดเงิน', v;
  end if;

  select count(*) into n from sri_os.txn_types t where sri_os.fn_txn_type_can_withhold(t.code);
  raise notice 'WHT ลงจริงได้แล้ว: fn_post_entry รับ wht_* · หมวดที่หักภาษีได้ % หมวด (รวมหมวดรับชำระค้างรับ) · ด่านผูกทั้ง transaction_lines และ transactions', n;
end $$;
