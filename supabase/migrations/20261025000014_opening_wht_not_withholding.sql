-- ============================================================
-- SRI OS · **ยอดยกมาของภาษีถูกหัก ณ ที่จ่าย (1800) ลงได้** — ด่าน gross-up
--            ต้องไม่ครอบใบยอดยกมา
--
-- ------------------------------------------------------------
-- **ที่มา (เจอตอนเพิ่มหมวด `opn.*` ที่ขาด 25/10)**
--
-- ไฟล์ยอดตั้งต้นของลูกพี่มีรหัส `1800` แน่นอน (ผู้เช่าหักภาษีจากค่าเช่าทุกเดือน
-- ยอดสะสมที่ยังไม่ได้ใช้เครดิตค้างอยู่ ณ วันตัดยอด · D-111 ข้อ 1)
-- เพิ่มหมวด `opn.wht_credit` (dr 1800 / cr 3300) แล้ว **ลงไม่ได้**:
--
--   ใบนี้มีบรรทัดภาษีถูกหัก ณ ที่จ่าย (1800) แต่หมวด "opn.wht_credit"
--   ถูกหักภาษีไม่ได้ — ...
--
-- `fn_assert_wht_gross_for()` ข้อ (ก) ปฏิเสธ **ทุกใบที่มีบรรทัด 1800**
-- ถ้าหมวดนั้นไม่ `can_withhold` · ซึ่งถูกสำหรับใบที่อ้างว่าถูกหักภาษี
-- แต่ **ไม่ตรงเรื่อง** สำหรับใบยอดยกมา: ใบยอดยกมาไม่ได้อ้างว่าถูกหักภาษี
-- มันแค่ยกยอดสินทรัพย์ภาษีที่ค้างอยู่เข้ามา และ**ไม่มีเงินได้ในใบ**
-- (ขาคู่เป็นกำไรสะสม) สมการ gross-up จึงไม่มีความหมายกับมันเลย
--
-- **ทางเลือกที่ทิ้ง**: ตั้งให้ `opn.wht_credit` เป็นหมวดที่ `can_withhold`
--   → ผิดความหมาย และจะเปิดทางให้ใบยอดยกมา "หักภาษี" ได้ ซึ่งไม่มีอยู่จริง
--   (และ `fn_txn_type_can_withhold` คำนวณจากคู่บัญชี ไม่ใช่ธงที่ตั้งได้)
--
-- **สิ่งที่เปลี่ยน** — เขียนทับ `fn_assert_wht_gross_for()` ทั้งฟังก์ชัน
--   (ลายเซ็นเดิม · `trg_assert_wht_gross` ยังผูกอยู่กับ `fn_assert_wht_gross()`
--    ที่เรียกตัวนี้) เพิ่ม **early return เดียว**: ใบที่หมวดอยู่ในกลุ่ม
--   `opening` ข้ามด่านนี้ · อ่านจาก `txn_types.group_code` **ไม่ใช่รหัสหมวด**
--   → หมวดยอดยกมาตัวใหม่ได้พฤติกรรมเดียวกันโดยไม่ต้องแก้ด่านนี้อีก
--
--   **ฐานที่เขียนทับคือรุ่น `20261025000001_wht_post_entry.sql`** ซึ่งเป็นรุ่น
--   ล่าสุดของฟังก์ชันนี้ (ตรวจแล้วว่าไม่มีไฟล์อื่นเขียนทับหลังจากนั้น) —
--   บทเรียนจาก 20261025000011 ที่เคยลอกจากรุ่นเก่าแล้วทำกฎของ FCD หาย
--
-- ลำดับ: **ต้องรันหลัง** 20261025000001 · guard หัวไฟล์ตรวจให้
--
-- idempotent: `create or replace` ตัวเดียว
--
-- ย้อนกลับ (rollback):
--   -- รัน supabase/migrations/20261025000001_wht_post_entry.sql ซ้ำ (idempotent)
--   ⚠ ถอดแล้ว **ลงยอดยกมาของ 1800 ไม่ได้** → นำเข้าไฟล์จริงของลูกพี่ไม่ได้
--     (และถ้าถอดแต่ยังเก็บหมวด `opn.wht_credit` ไว้ จะเป็นหมวดที่กดแล้วพังทุกครั้ง)
-- ============================================================

set search_path = sri_os, public;

do $$
begin
  if to_regprocedure('sri_os.fn_assert_wht_gross_for(uuid)') is null then
    raise exception 'ไม่มี fn_assert_wht_gross_for → ต้องรัน 20261025000001_wht_post_entry.sql ก่อนไฟล์นี้';
  end if;
  if to_regprocedure('sri_os.fn_txn_type_can_withhold(text)') is null then
    raise exception 'ไม่มี fn_txn_type_can_withhold → ต้องรัน 20261024000001_wht_and_fx.sql ก่อนไฟล์นี้';
  end if;
  if not exists (select 1 from sri_os.txn_types where group_code = 'opening') then
    raise exception 'ตารางกฎยังไม่มีหมวดกลุ่ม opening → sync ด้วย npm run sync:rules ก่อน';
  end if;
end $$;

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

  /**
   * **ยอดยกมาไม่ใช่ "ใบที่ถูกหักภาษี"** → ด่านนี้ไม่เกี่ยว (25/10)
   *
   * `1800` ภาษีถูกหัก ณ ที่จ่ายรอเครดิต **มียอดยกมาจริง** เพราะผู้เช่าหักภาษี
   * จากค่าเช่าทุกเดือน และยอดสะสมที่ยังไม่ได้ใช้เครดิตค้างอยู่ ณ วันตัดยอด
   * หมวด `opn.wht_credit` จึงต้องมี และมันลงบรรทัด `1800` โดยถูกต้อง
   *
   * ด่านนี้ตรวจ **สมการ gross-up ของใบที่มีเงินได้**: เงินเข้า + ภาษีที่ถูกหัก
   * = ยอดเต็มของรายได้ · แต่ใบยอดยกมา **ไม่มีเงินได้ในใบ** (ขาคู่เป็นกำไรสะสม)
   * สมการจึงไม่มีความหมาย และข้อ (ก) จะปฏิเสธด้วยเหตุผลที่ไม่ตรงเรื่อง
   * ("หมวดนี้ถูกหักภาษีไม่ได้" — จริง แต่ใบนี้ไม่ได้อ้างว่าถูกหักภาษี)
   *
   * **อ่านจากตารางกฎ (`group_code = 'opening'`) ไม่ใช่เช็ครหัสหมวดตรงๆ**
   * → หมวดยอดยกมาตัวใหม่ในอนาคตได้พฤติกรรมเดียวกันโดยไม่ต้องแก้ด่านนี้อีก
   *
   * **ไม่ได้ทำให้ด่านหลวมลงสำหรับใบปกติ**: ใบที่ไม่ใช่ยอดยกมายังถูกตรวจครบทุกข้อ
   * และบรรทัด `1800` บนใบยอดยกมายังถูกคุมด้วยด่านอื่น (สมดุล · คู่บัญชีต้องตรง
   * ตารางกฎ · ขาคู่ต้องเป็นส่วนของเจ้าของ · ลายนิ้วมือของการนำเข้า)
   */
  if exists (select 1 from sri_os.txn_types ty
              where ty.code = v_type and ty.group_code = 'opening') then
    return;
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
  'D-111 ข้อ 1 · ด่าน gross-up ของภาษีถูกหัก ณ ที่จ่าย: มีบรรทัด 1800 ต้องเป็นหมวดที่หักภาษีได้ · หัวรายการกับบรรทัดต้องเล่าเรื่องเดียวกัน · เงินเข้า + ภาษี = ยอดเต็มของรายได้ · **ข้ามกลุ่ม `opening` ทั้งกลุ่ม (25/10)** เพราะใบยอดยกมาไม่มีเงินได้ในใบ (ขาคู่เป็นกำไรสะสม) สมการ gross-up จึงไม่มีความหมาย และ 1800 ของมันคือยอดสะสมที่ยกมา ไม่ใช่ภาษีที่ถูกหักในใบนั้น';

revoke all on function fn_assert_wht_gross_for(uuid) from public;
do $$ begin execute 'revoke all on function sri_os.fn_assert_wht_gross_for(uuid) from anon, authenticated'; end $$;

-- ============================================================
-- guard ท้ายไฟล์
-- ============================================================
do $$
declare v text;
begin
  -- trigger ต้องยังผูกอยู่กับสายเดิม (เราเขียนทับฟังก์ชัน ไม่ได้สร้างตัวใหม่)
  if not exists (select 1 from pg_trigger g
                  join pg_proc p on p.oid = g.tgfoid
                 where g.tgrelid = 'sri_os.transaction_lines'::regclass
                   and p.proname = 'fn_assert_wht_gross'
                   and not g.tgisinternal) then
    raise exception 'ไม่มี trigger ที่เรียก fn_assert_wht_gross บน transaction_lines — ด่าน gross-up หลุดทั้งชุด';
  end if;

  /**
   * เทียบกับ **โค้ดที่ตัดคอมเมนต์ออกแล้ว** เสมอ — ชื่อที่เอ่ยในคอมเมนต์
   * ไม่ใช่การเรียกใช้จริง (หลักเดียวกับ `fn_function_code()` ของ 20261020000004
   * ซึ่งเจอปัญหานี้มาก่อน) · ที่นี่คอมเมนต์อธิบายว่าทำไมหมวด `opn.wht_credit`
   * ต้องลงได้ ถ้าไม่ตัดคอมเมนต์ guard จะฟ้องคำอธิบายของตัวเอง
   */
  select regexp_replace(
           regexp_replace(p.prosrc, '/\*.*?\*/', ' ', 'gs'),
           '--[^' || chr(10) || ']*', ' ', 'g')
    into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_assert_wht_gross_for';

  -- ข้อยกเว้นต้องอ่านจากตารางกฎ ไม่ใช่ไล่รหัสหมวด
  if v !~ 'group_code' then
    raise exception 'ข้อยกเว้นของกลุ่ม opening ไม่ได้อ่านจาก txn_types.group_code — ห้ามเช็ครหัสหมวดตรงๆ';
  end if;
  if v ~ 'opn\.' then
    raise exception 'ด่านนี้เอ่ยรหัสหมวด opn.* ตรงๆ ในโค้ด — ต้องอ่านจาก group_code เพื่อให้หมวดใหม่ได้พฤติกรรมเดียวกันเอง';
  end if;

  -- กฎเดิมต้องยังอยู่ครบ (การเขียนทับทั้งฟังก์ชันคือจุดที่กฎเคยหาย)
  foreach v in array array['fn_txn_type_can_withhold', 'wht_amount', 'wht_rate', '1800'] loop
    if pg_get_functiondef('sri_os.fn_assert_wht_gross_for(uuid)'::regprocedure) !~ v then
      raise exception 'กฎเดิมของด่าน gross-up หายไปจากการเขียนทับ: ไม่พบ "%"', v;
    end if;
  end loop;

  raise notice 'ok · ด่าน gross-up ข้ามกลุ่มยอดยกมา (อ่านจาก group_code) · กฎเดิมของใบปกติยังอยู่ครบ';
end $$;
