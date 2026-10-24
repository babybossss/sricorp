-- ============================================================
-- SRI OS · ปิดสามรูของ FCD ที่ผู้ตรวจ BLOCK (+ สอง WARN) — ตัวเลขผิดจริงทั้งหมด
--
-- ทั้งสามหลุดด้วยเหตุเดียวกัน: **เทสต์รอบก่อนส่งข้อมูลครบทุกเคส** จึงไม่เคยแตะ
-- เส้นทางที่ข้อมูลขาด (บทเรียน mace-windu ข้อ 3) · เคส "ไม่ส่งข้อมูล" ทั้งห้า
-- อยู่ใน `supabase/tests/zz_fcd_currency_test.sql` (F8–F12) **เขียนก่อนแก้** และ
-- วัดสภาพก่อนแก้ได้ดังนี้ (รันบน PG16 ของจริง):
--
--   BLOCK 1 · ขา `3410` **ไม่ส่ง `currency` ได้** (โค้ดคืน `new` ก่อนถึงด่าน)
--     แต่ `fn_assert_fx_unrealized_cleared_for` กรองด้วย `v.currency = v_ccy`
--     → **มองขานั้นไม่เห็น** · วัดได้: ซื้อ USD 10,000@36.50 → แปลงค่า@37.00
--       (cr 3410 5,000 ไม่มีสกุล) → **แลกหมดโดยไม่ล้าง 3410 ผ่านฉลุย**
--       ผล: USD 0 · FCD 0 บาท · **3410 ค้าง 5,000** ขณะที่ 4330 รับรู้กำไร 5,000
--       = **ก้อนเดียวถูกนับสองครั้ง**
--
--   BLOCK 2 · `trf.fx_translate_up` บน **บัญชีบาท** ไม่มีด่านเลย
--     `dr 1100(THB) 1,000,000 / cr 3410 1,000,000` ผ่าน → วัดได้: บัญชีบาท
--     จาก −36,500 เป็น **963,500** = **เงินสดโผล่จากอากาศ 1,000,000**
--     และ `cashflow.ts` ยัดเข้า `fxEffect` → `reconciled = true`
--     **ปิดเสียง `cashOutsideStatement`** = ตัวจับความผิดปกติที่สร้างมาเพื่อจับ
--     เรื่องนี้ ถูกทำให้เงียบด้วยของที่เพิ่งเพิ่มเอง (แก้ที่ฝั่งโค้ดคู่กับไฟล์นี้)
--
--   WARN 1 · ด่านล้าง 3410 ยิงเฉพาะหมวดที่ประกาศ 4330/5930 → **เงินตราออกทาง
--     `trf.internal` หรือข้ามผู้ถือ ทิ้ง 3410 ค้างได้** · วัดได้: USD 0 · 3410 ค้าง 5,000
--
--   WARN 2 · FK เทียบแค่ (สกุล, วัน) ไม่เทียบ `thb_per_unit` → วัดได้: ลงบรรทัด
--     ด้วยอัตรา **36.60** ได้ ทั้งที่ตารางอัตราของวันนั้นประกาศ **36.50**
--
--   WARN 3 · เดิมยอม ±0.01 ต่อบรรทัด → ใบที่มีหลายบรรทัดสะสมได้ไม่จำกัด
--     (n บรรทัด = ±0.01n) **ไฟล์นี้ตัดเป็นศูนย์**: ยอดบาทต้องเท่ากับ
--     `round(ยอดสกุลเดิม × อัตรา, 2)` **พอดี** — ทั้งสองฝั่งคิดด้วยนิพจน์เดียวกัน
--     บน `numeric` (ไม่ใช่ float) จึงไม่มีเหตุให้ต้องยอมเศษ
--
-- ------------------------------------------------------------
-- **ไม่แก้ไฟล์ 20261025000004 ที่ apply แล้ว** — กู้ด้วยไฟล์ใหม่ทั้งหมด
--   เขียนทับสองฟังก์ชันของไฟล์นั้น (`fn_assert_line_fx` ·
--   `fn_assert_fx_unrealized_cleared_for`) ด้วย `create or replace`
--   **ไม่สร้างด่านที่สอง** (บทเรียนข้อ 5: กฎเดียวกันห้ามมีสองเวอร์ชัน)
--
-- ลำดับ: **ต้องรันหลัง 20261025000004_fcd_bank_currency.sql** · ก่อน
--   `20261020000003_replay_end_state_guard.sql` (ไฟล์สุดท้ายเสมอ)
--   → วางต่อท้าย 20261025000004 · ผมไม่แก้ migration-order.txt / UNDER_TEST เอง
--
-- idempotent: create or replace function เท่านั้น (ไม่มี DDL ของ schema)
--   → replay ซ้ำได้ตลอด และไม่มีสภาพครึ่งๆ แม้รันผิดลำดับ
--
-- ย้อนกลับ (rollback): รัน 20261025000004_fcd_bank_currency.sql ซ้ำทั้งไฟล์
--   → คืนสองฟังก์ชันรุ่นก่อนไฟล์นี้ · ย้อนแล้วได้สภาพเดิมคือ **กำไรถูกนับซ้ำ
--   และเงินสดโผล่จากอากาศได้** — ไม่แนะนำให้ย้อน
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 0 · pre-flight — ต้องมีของจาก 20261025000004 ก่อน
-- ============================================================
do $$
begin
  if to_regprocedure('sri_os.fn_assert_line_fx()') is null
     or to_regprocedure('sri_os.fn_assert_fx_unrealized_cleared_for(uuid)') is null then
    raise exception 'ไฟล์นี้เขียนทับสองฟังก์ชันของ 20261025000004_fcd_bank_currency.sql ซึ่งยังไม่มีในฐานข้อมูล — ต้องรันหลังไฟล์นั้น (ลงทะเบียนลำดับใน supabase/migration-order.txt และ UNDER_TEST ของ scripts/test-rls-local.sh)';
  end if;
end $$;

-- ============================================================
-- 1 · fn_assert_line_fx — เรียงด่านใหม่ให้ **ไม่มีเส้นทางที่คืนก่อนตรวจ**
--
-- รุ่นก่อน `return new` ทันทีเมื่อ `new.currency is null` → บรรทัดที่ควรต้องมีสกุล
-- (ขา 3410 · ขาเงินสดของหมวดแปลงค่า) หลุดทั้งชุด · รุ่นนี้ตัดสิน **จากสิ่งที่
-- บรรทัดนั้นเป็น** (บัญชีอะไร · หมวดอะไร) ก่อน แล้วจึงดูว่าข้อมูลครบหรือไม่
-- ============================================================
create or replace function fn_assert_line_fx() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_code      text;
  v_bank_ccy  text;
  v_label     text;
  v_thb       numeric;
  v_expected  numeric;
  v_type      text;
  v_is_xlate  boolean := false;
  v_table_rate numeric;
begin
  select c.code into v_code
    from sri_os.chart_of_accounts c where c.id = new.coa_id;
  if v_code is null then
    return new;   -- ด่านคู่บัญชีปฏิเสธด้วยข้อความของมันเอง
  end if;

  v_thb := coalesce(new.debit, 0) + coalesce(new.credit, 0);

  select t.txn_type_code into v_type
    from sri_os.transactions t where t.id = new.transaction_id;
  if v_type is not null then
    -- หมวดนี้คือ **การแปลงค่า** หรือไม่ — อ่านจากคู่บัญชี (แตะ 3410) ไม่ใช่รายชื่อรหัสหมวด
    select exists (select 1 from sri_os.txn_types ty
                    where ty.code = v_type and '3410' in (ty.dr_coa_code, ty.cr_coa_code))
      into v_is_xlate;
  end if;

  -- ---------- (1) ขาเงินสด: สกุลของบรรทัดต้องตรงกับสกุลของบัญชี ----------
  if new.bank_account_id is not null then
    v_bank_ccy := sri_os.fn_bank_account_currency(new.bank_account_id);
    select b.display_name into v_label
      from sri_os.bank_accounts b where b.id = new.bank_account_id;

    /**
     * **BLOCK 2** · การแปลงค่าทำได้เฉพาะบัญชีที่ไม่ใช่บาท
     *
     * ยอดบาทของบัญชี **บาท** ไม่เปลี่ยนเพราะอัตราแลกเปลี่ยน — ใบแปลงค่าบน
     * บัญชีบาทคือการ **สร้างเงินสดขึ้นมาจากอากาศ** (ผู้ตรวจวัดได้ +1,000,000)
     * และไปโผล่เป็น `fxEffect` ในงบกระแสเงินสดซึ่งปิดเสียงด่าน cashOutsideStatement
     */
    if v_is_xlate then
      if v_bank_ccy is null or v_bank_ccy = 'THB' then
        raise exception 'แปลงค่าอัตราแลกเปลี่ยนบนบัญชี "%" ไม่ได้ เพราะเป็นบัญชี**บาท** — ยอดบาทของบัญชีบาทไม่เปลี่ยนตามอัตราแลกเปลี่ยน · การแปลงค่าทำได้เฉพาะบัญชีเงินฝากสกุลต่างประเทศ (bank_accounts.currency <> THB) ไม่งั้นเท่ากับสร้างเงินสดขึ้นมาจากอากาศ และยอดนั้นจะไปซ่อนอยู่ในบรรทัดผลกระทบอัตราแลกเปลี่ยนของงบกระแสเงินสด',
          coalesce(v_label, new.bank_account_id::text);
      end if;
      if new.currency is null then
        raise exception 'บรรทัดเงินสดของใบแปลงค่าต้องระบุสกุลเงิน อัตรา และวันของอัตราให้ครบ (บัญชี "%") — ยอดบาทที่ไม่มีอัตรากำกับตรวจย้อนไม่ได้ว่ามาจากไหน',
          coalesce(v_label, new.bank_account_id::text);
      end if;
    end if;

    if v_bank_ccy is not null and v_bank_ccy <> 'THB' then
      if new.currency is null then
        raise exception 'บัญชี "%" เป็นบัญชีสกุล % — บรรทัดนี้ต้องระบุสกุลเงิน ยอดในสกุลเดิม อัตราแลกเปลี่ยน และวันของอัตราให้ครบ · **ลงเป็นบาทเฉยๆ ไม่ได้** เพราะยอดบาทจะกลายเป็นตัวเลขที่ไม่มีใครรู้ว่ามาจากอัตราไหน และระบบจะนับเงินตราเป็นบาททั้งก้อน (ยอดเงินสดในงบผิดทั้งงวด)',
          coalesce(v_label, new.bank_account_id::text), v_bank_ccy;
      end if;
      if new.currency <> v_bank_ccy then
        raise exception 'บรรทัดนี้ลงบัญชี "%" ซึ่งเป็นสกุล % แต่ระบุสกุล % — สกุลของบรรทัดต้องเป็นสกุลของบัญชีที่เงินเข้าออกจริง',
          coalesce(v_label, new.bank_account_id::text), v_bank_ccy, new.currency;
      end if;
    elsif v_bank_ccy = 'THB' and new.currency is not null then
      raise exception 'บัญชี "%" เป็นบัญชีบาท แต่บรรทัดนี้แนบข้อมูลอัตราแลกเปลี่ยนมา (สกุล %) — ข้อมูลอัตราที่ติดมากับบรรทัดบาทจะทำให้รายงานสกุลเงินนับยอดนี้เป็นเงินตรา',
        coalesce(v_label, new.bank_account_id::text), new.currency;
    end if;
  end if;

  /**
   * ---------- (2) **BLOCK 1** · ขาผลต่าง 3410 ต้องระบุสกุลเงินเสมอ ----------
   *
   * ด่านล้างผลต่าง (`fn_assert_fx_unrealized_cleared_for`) ต้องรู้ว่าผลต่างก้อนนั้น
   * เป็นของสกุลไหน — 3410 ไม่มี `bank_account_id` ได้ (ด่าน fn_assert_line_bank_is_cash
   * ห้ามบัญชีธนาคารบนบรรทัดที่ไม่ใช่เงินสด) **สกุลบนบรรทัดคือตัวเดียวที่บอกได้**
   * ถ้าปล่อยให้ว่าง ด่านนั้นมองก้อนนั้นไม่เห็น แล้วแลกเงินหมดโดยไม่ล้างได้
   * (ผู้ตรวจวัดได้: 3410 ค้าง 5,000 พร้อมกับ 4330 รับรู้ 5,000 = นับซ้ำ)
   */
  if v_code = '3410' and new.currency is null then
    raise exception 'บรรทัดผลต่างอัตราแลกเปลี่ยน (3410) ต้องระบุสกุลเงินของผลต่างก้อนนี้ (พร้อมอัตราและวันของอัตรา) — บรรทัดนี้ไม่มีบัญชีธนาคารให้อ้าง สกุลบนบรรทัดจึงเป็นตัวเดียวที่บอกว่าผลต่างเป็นของสกุลไหน · ถ้าไม่ระบุ ด่าน "แลกหมดแล้วต้องล้างให้เหลือศูนย์" จะมองก้อนนี้ไม่เห็น แล้วกำไรก้อนเดียวจะถูกนับสองครั้ง';
  end if;

  if new.currency is null then
    return new;   -- บรรทัดบาทตรงๆ → ไม่มีอะไรต้องตรวจต่อ (ของเดิมทุกใบมาทางนี้)
  end if;

  -- ---------- (3) **WARN 2** · อัตราต้องเท่ากับอัตราที่ประกาศไว้ของวันนั้น ----------
  -- FK เทียบแค่ (สกุล, วัน) → ใช้อัตราอื่นได้ทั้งที่ตารางประกาศอีกค่า
  select f.thb_per_unit into v_table_rate
    from sri_os.fx_rates f
   where f.currency = new.currency and f.rate_date = new.fx_rate_date;
  if v_table_rate is not null and new.fx_rate <> v_table_rate then
    raise exception 'อัตราในบรรทัดนี้ (%) ไม่เท่ากับอัตราในตารางอัตราแลกเปลี่ยนของ % วันที่ % (ประกาศไว้ %) — อัตราที่ใช้ลงบัญชีต้องเป็นอัตราที่ประกาศไว้ ไม่ใช่ตัวเลขที่พิมพ์เอง · ถ้าอัตราที่ใช้จริงต่างจากนี้ (เช่นเรทที่ธนาคารให้ตอนแลก) ให้บันทึกอัตรานั้นลงตารางอัตราของวันนั้นก่อน แล้วอ้างวันนั้น',
      new.fx_rate, new.currency, new.fx_rate_date, v_table_rate;
  end if;

  -- ---------- (4) มีเงินตราเคลื่อน → ยอดบาทต้องมาจากอัตรา **พอดี** ----------
  -- **WARN 3** · เดิมยอม ±0.01 ต่อบรรทัด = ใบที่มี n บรรทัดสะสมได้ ±0.01n
  -- ทั้งสองฝั่งคิดด้วย round(numeric, 2) เหมือนกัน จึงไม่มีเหตุให้ยอมเศษ
  if new.amount_original > 0 then
    v_expected := round(new.amount_original * new.fx_rate, 2);
    if round(v_thb, 2) <> v_expected then
      raise exception 'ยอดบาทของบรรทัดนี้ (%) ไม่เท่ากับ ยอดสกุลเดิม % × อัตรา % = % พอดี — ยอดบาทต้องมาจากอัตราที่บันทึกไว้ ไม่ใช่ตัวเลขที่พิมพ์แยกกัน (ไม่ยอมเศษแม้สตางค์เดียว เพราะใบที่มีหลายบรรทัดจะสะสมส่วนต่างได้เรื่อยๆ)',
        round(v_thb, 2), new.amount_original, new.fx_rate, v_expected;
    end if;
    return new;
  end if;

  -- ---------- (5) ไม่มีเงินตราเคลื่อนแต่มียอดบาท = **บรรทัดแปลงค่า** ----------
  if v_thb <> 0 and not (v_code = '3410' or v_is_xlate) then
    raise exception 'บรรทัดนี้ไม่มียอดเงินตราเคลื่อน (amount_original = 0) แต่มียอดบาท % — บรรทัดแบบนี้คือ **การแปลงค่า** ซึ่งลงได้เฉพาะหมวดแปลงค่าเงินฝากสกุลต่างประเทศ หรือบรรทัดผลต่างอัตราแลกเปลี่ยน (3410) ของใบแลกเงินจริง · หมวด "%" ไม่ใช่ทั้งสองอย่าง',
      round(v_thb, 2), coalesce(v_type, '(ไม่มีหัวรายการ)');
  end if;

  -- ---------- (6) บรรทัดที่ไม่ใช่เงินสด: แนบสกุลได้เฉพาะขาผลต่าง 3410 ----------
  if new.bank_account_id is null and v_code <> '3410' then
    raise exception 'บรรทัดบัญชี % แนบข้อมูลสกุลเงินมา แต่ไม่ใช่ขาเงินสดของบัญชีสกุลต่างประเทศ และไม่ใช่ขาผลต่างอัตราแลกเปลี่ยน (3410) — ข้อมูลสกุลเงินบนบรรทัดอื่นจะทำให้รายงานยอดเงินตรานับซ้ำ',
      v_code;
  end if;

  return new;
end $fn$;

comment on function fn_assert_line_fx() is
  'FCD · (1) สกุลของบรรทัดต้องตรงกับสกุลของบัญชี และ **การแปลงค่าทำได้เฉพาะบัญชีที่ไม่ใช่บาท** (BLOCK 2: แปลงค่าบนบัญชีบาท = สร้างเงินสดจากอากาศ) · (2) **ขา 3410 ต้องระบุสกุลเสมอ** (BLOCK 1: ไม่ระบุ = ด่านล้างผลต่างมองไม่เห็น แล้วกำไรถูกนับซ้ำ) · (3) อัตราต้องเท่ากับ fx_rates.thb_per_unit ของวันนั้น (WARN 2) · (4) ยอดบาท = round(ยอดสกุลเดิม × อัตรา, 2) **พอดี ไม่ยอมเศษ** (WARN 3) · (5) บรรทัดที่ไม่มีเงินตราเคลื่อนแต่มียอดบาท ลงได้เฉพาะการแปลงค่า';

revoke all on function fn_assert_line_fx() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_line_fx() from anon, authenticated';
end $$;

-- ============================================================
-- 2 · fn_assert_fx_unrealized_cleared_for — **เลิกผูกกับหมวด** (WARN 1)
--
-- รุ่นก่อนตรวจเฉพาะใบที่ประกาศ 4330/5930 → เงินตราออกทาง `trf.internal`
-- หรือทางรายการข้ามผู้ถือ ทิ้งผลต่างค้างได้ (ผู้ตรวจวัดได้ 3410 ค้าง 5,000)
--
-- รุ่นนี้ตรวจ **ทุกใบที่แตะเงินตรา** ไม่ว่าหมวดอะไร: ถ้าหลังใบนี้ยอดเงินตรา
-- ของผู้ถือในสกุลนั้นเหลือศูนย์ ผลต่างใน 3410 ของสกุลนั้นต้องเหลือศูนย์พอดี
-- ============================================================
create or replace function fn_assert_fx_unrealized_cleared_for(p_txn uuid) returns void
language plpgsql security definer set search_path = '' as $fn$
declare
  v_owner  uuid;
  v_ccy    text;
  v_fx     numeric;
  v_unreal numeric;
  v_blind  numeric;
begin
  select t.owner_id into v_owner
    from sri_os.transactions t where t.id = p_txn;
  if v_owner is null then
    return;
  end if;

  /**
   * ขา 3410 ที่ไม่มีสกุล = ด่านนี้มองไม่เห็น → **ปฏิเสธทั้งใบ** ไม่ใช่เงียบ
   * (ด่านระดับบรรทัดกันไว้แล้ว ที่นี่กันซ้ำเพราะเป็นตัวที่ *พึ่ง* ข้อมูลนั้น
   *  ถ้าวันหนึ่งมีเส้นทางเขียนตรงเข้าตารางที่ข้ามด่านบรรทัดได้ ด่านนี้ต้องยังจับได้)
   */
  select coalesce(sum(abs(v.debit - v.credit)), 0) into v_blind
    from sri_os.v_ledger_posted v
    join sri_os.chart_of_accounts c on c.id = v.coa_id
   where v.owner_id = v_owner and c.code = '3410' and v.currency is null;
  if v_blind <> 0 then
    raise exception 'มีบรรทัดผลต่างอัตราแลกเปลี่ยน (3410) ของผู้ถือนี้ที่ไม่ระบุสกุลเงิน รวม % บาท — ด่าน "แลกหมดแล้วต้องล้างให้เหลือศูนย์" ตัดสินจากสกุลบนบรรทัด ถ้ามีก้อนที่ไม่ระบุสกุล ด่านจะมองไม่เห็นและกำไรจะถูกนับซ้ำ · ต้องกลับรายการใบนั้นแล้วลงใหม่พร้อมระบุสกุล',
      v_blind;
  end if;

  -- ทุกสกุลที่ใบนี้แตะ (ไม่สนว่าหมวดอะไร — WARN 1)
  for v_ccy in
    select distinct l.currency
      from sri_os.transaction_lines l
     where l.transaction_id = p_txn and l.currency is not null and l.currency <> 'THB'
  loop
    -- ยอด **เงินตรา** คงเหลือของผู้ถือในสกุลนี้ (ทิศจากด้านที่ลง)
    select coalesce(sum(case when v.debit > 0 then v.amount_original else -v.amount_original end), 0)
      into v_fx
      from sri_os.v_ledger_posted v
      join sri_os.chart_of_accounts c on c.id = v.coa_id
     where v.owner_id = v_owner and v.currency = v_ccy
       and c.code ~ '^11[0-9][0-9]$';

    -- ผลต่างที่ยังค้างในส่วนของเจ้าของของสกุลนี้ (เครดิต = บวก)
    select coalesce(sum(v.credit - v.debit), 0) into v_unreal
      from sri_os.v_ledger_posted v
      join sri_os.chart_of_accounts c on c.id = v.coa_id
     where v.owner_id = v_owner and v.currency = v_ccy and c.code = '3410';

    if round(v_fx, 6) = 0 and round(v_unreal, 2) <> 0 then
      raise exception 'เงินตราสกุล % ของผู้ถือนี้ออกหมดแล้ว (ยอดคงเหลือ 0) แต่ยังมีผลต่างอัตราแลกเปลี่ยนค้างในส่วนของเจ้าของ (3410) อยู่ % บาท — ต้องล้างออกให้เหลือศูนย์พอดีในใบเดียวกับที่เงินตราออก ไม่งั้นผลต่างค้างตลอดไปทั้งที่เงินตราไม่อยู่แล้ว และถูกนับซ้ำกับกำไร/ขาดทุนที่รับรู้ · **ใช้หมวด "แลกเงินตราต่างประเทศเป็นบาท" ที่ล้างให้ครบ** ไม่ใช่หมวดโอนธรรมดา',
        v_ccy, round(v_unreal, 2);
    end if;

    if round(v_fx, 6) < 0 then
      raise exception 'ยอดเงินตราสกุล % ของผู้ถือนี้ติดลบ (%) — จ่ายเงินตราออกมากกว่าที่มีอยู่ในบัญชีไม่ได้ · ถ้ามีเงินเข้าที่ยังไม่ได้ลง ต้องลงใบนั้นก่อน',
        v_ccy, round(v_fx, 6);
    end if;
  end loop;
end $fn$;

comment on function fn_assert_fx_unrealized_cleared_for(uuid) is
  'FCD · ตรวจ **ทุกใบที่แตะเงินตรา** (ไม่ผูกกับหมวด — WARN 1: เงินตราออกทาง trf.internal/ข้ามผู้ถือ ทิ้ง 3410 ค้างได้): เงินตราของผู้ถือในสกุลนั้นออกหมดแล้ว ผลต่างใน 3410 ของสกุลนั้นต้องเหลือศูนย์พอดี · ยอดเงินตราติดลบไม่ได้ · และปฏิเสธถ้ามีขา 3410 ที่ไม่ระบุสกุล (BLOCK 1 · ด่านจะมองก้อนนั้นไม่เห็น)';

revoke all on function fn_assert_fx_unrealized_cleared_for(uuid) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_fx_unrealized_cleared_for(uuid) from anon, authenticated';
end $$;

-- ============================================================
-- 3 · guard ท้ายไฟล์ — ดังตอน migrate ไม่ใช่ตอนผู้ใช้กดบันทึก
-- ============================================================
do $$
declare v text; n int;
begin
  -- (ก) ด่านทั้งสองต้องเป็นรุ่นของไฟล์นี้ (ไล่จากเนื้อฟังก์ชันจริงใน catalog)
  v := pg_get_functiondef('sri_os.fn_assert_line_fx()'::regprocedure);
  if v !~ 'เป็นบัญชี\*\*บาท\*\*' then
    raise exception 'fn_assert_line_fx ไม่ใช่รุ่นที่กันการแปลงค่าบนบัญชีบาท (BLOCK 2) — มีไฟล์อื่นเขียนทับหลังไฟล์นี้';
  end if;
  if v !~ 'ต้องระบุสกุลเงินของผลต่างก้อนนี้' then
    raise exception 'fn_assert_line_fx ไม่ใช่รุ่นที่บังคับสกุลบนขา 3410 (BLOCK 1)';
  end if;
  if v !~ 'ไม่เท่ากับอัตราในตารางอัตราแลกเปลี่ยน' then
    raise exception 'fn_assert_line_fx ไม่ได้เทียบอัตรากับตารางอัตรา (WARN 2)';
  end if;
  if v ~ 'ยอม 1 สตางค์' then
    raise exception 'fn_assert_line_fx ยังยอมเศษสตางค์ต่อบรรทัด (WARN 3)';
  end if;

  v := pg_get_functiondef('sri_os.fn_assert_fx_unrealized_cleared_for(uuid)'::regprocedure);
  if v ~ 'gain_coa_code' or v ~ '4330' then
    raise exception 'fn_assert_fx_unrealized_cleared_for ยังผูกกับหมวดที่ประกาศบัญชีกำไร FX (WARN 1) — เงินตราออกทางหมวดอื่นจะทิ้งผลต่างค้างได้';
  end if;
  if v !~ 'ไม่ระบุสกุลเงิน รวม' then
    raise exception 'fn_assert_fx_unrealized_cleared_for ไม่ได้กันขา 3410 ที่ไม่ระบุสกุล (BLOCK 1 ชั้นที่สอง)';
  end if;

  -- (ข) trigger ต้องยังผูกอยู่ (ฟังก์ชันที่ไม่ได้ผูกกับตารางไม่ได้กันอะไร)
  select string_agg(x.want, ', ') into v
    from (values ('trg_lines_fx_shape'), ('trg_assert_fx_unrealized_cleared')) x(want)
   where not exists (select 1 from pg_trigger g
                      where g.tgrelid = 'sri_os.transaction_lines'::regclass
                        and g.tgname = x.want and not g.tgisinternal);
  if v is not null then
    raise exception 'trigger หายไปจาก transaction_lines: %', v;
  end if;

  -- (ค) ฟังก์ชันด่านต้องเรียกตรงไม่ได้ (D-089)
  select string_agg(x.f, ', ') into v
    from unnest(array['sri_os.fn_assert_line_fx()',
                      'sri_os.fn_assert_fx_unrealized_cleared_for(uuid)']) x(f)
   where has_function_privilege('authenticated', x.f, 'execute')
      or has_function_privilege('anon', x.f, 'execute');
  if v is not null then
    raise exception 'ฟังก์ชันด่านยังเรียกตรงได้: % = ทางข้าม policy ของสมุดเงิน', v;
  end if;

  -- (ง) ของเดิมในสมุดต้องไม่ละเมิดกฎใหม่ (ถ้ามี ต้องรู้ตอน migrate ไม่ใช่ตอนผู้ใช้กด)
  select count(*) into n
    from sri_os.transaction_lines l
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where c.code = '3410' and l.currency is null;
  if n > 0 then
    raise exception 'มีบรรทัด 3410 ที่ไม่ระบุสกุลเงินอยู่ในสมุดแล้ว % บรรทัด — ผลต่างก้อนนั้นด่านมองไม่เห็น ต้องกลับรายการแล้วลงใหม่พร้อมระบุสกุล (ห้ามแก้แถวตรงๆ · กฎเหล็กข้อ 1)', n;
  end if;
  select count(*) into n
    from sri_os.transaction_lines l
    join sri_os.transactions t on t.id = l.transaction_id
    join sri_os.txn_types ty on ty.code = t.txn_type_code
    join sri_os.bank_accounts b on b.id = l.bank_account_id
   where '3410' in (ty.dr_coa_code, ty.cr_coa_code) and b.currency = 'THB';
  if n > 0 then
    raise exception 'มีใบแปลงค่าที่ลงบนบัญชีบาทอยู่ในสมุดแล้ว % บรรทัด — ยอดเงินสดของบัญชีนั้นสูงกว่าจริง ต้องกลับรายการ', n;
  end if;

  raise notice 'ปิดสามรูของ FCD แล้ว: ขา 3410 ต้องมีสกุล (กำไรไม่ถูกนับซ้ำ) · แปลงค่าได้เฉพาะบัญชีที่ไม่ใช่บาท (เงินสดไม่โผล่จากอากาศ) · ด่านล้างผลต่างไม่ผูกกับหมวดอีกแล้ว · อัตราต้องตรงตารางและยอดบาทต้องพอดีไม่มีเศษ';
end $$;
