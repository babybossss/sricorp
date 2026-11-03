-- ============================================================
-- SRI OS · **ชุดบัญชีอสังหาริมทรัพย์ แทนรหัสเดียวที่เขียนตายไว้** —
--            ปิดช่องที่ทำให้ "อสังหาฯ เพื่อการขาย (1520)" ขายตรงไม่ได้
--
-- **ที่มา (ช่องที่เหลือจาก commit 7ad740e)**
--   27/10 แยกอสังหาฯ เพื่อการลงทุนเป็น **เพื่อการเช่า (1500)** กับ
--   **เพื่อการขาย (1520)** แต่ด่านของ `20261025000011` ตัดสินสิทธิ์ลงบรรทัด
--   **1510 ค่ารีโนเวท** จาก `cr_coa_code = '1500'` คือ **รหัสเดียว**
--   → หมวดขายที่เครดิต 1520 ลงบรรทัด 1510 ไม่ได้
--   → ขายคอนโดที่เคยรีโนเวทจากบัญชีเพื่อการขาย = ต้นทุนส่วนรีโนเวทค้างในงบดุล
--     เป็นทรัพย์ผี และกำไรจากการขายสูงกว่าจริงเท่าค่ารีโนเวทสะสม
--     (รูปเดียวกับบั๊กที่ 20261025000011 แก้ไว้ กลับมาอีกรอบในบัญชีตัวใหม่)
--
--   ทางออกที่เคยเขียนไว้คือ "ย้ายกลับ 1500 ก่อนขายหนึ่งใบ" ซึ่ง **ใช้ไม่ได้จริง**:
--   ของที่ตั้งใจขายแล้วต้องขายจากบัญชีของตัวเองได้ ไม่งั้นคือแยกบัญชีได้แต่ขายไม่ได้
--   = เปิดฟีเจอร์ครึ่งเดียว (บทเรียน mace-windu ข้อ 7)
--
-- **สิ่งที่เปลี่ยน**
--   1. เพิ่ม `fn_property_coas()` คืน array ของบัญชีอสังหาฯ ที่ค่ารีโนเวทเกาะได้
--      แพทเทิร์นเดียวกับ `fn_unrealised_equity_coas()` (20261025000004):
--      **ชุดอยู่ที่เดียว ด่านทุกตัวอ่านจากที่นั้น** ไม่ใช่พิมพ์รหัสซ้ำในแต่ละด่าน
--   2. เขียนทับ `fn_assert_line_coa_in_rules()` ทั้งฟังก์ชัน (ลายเซ็นเดิม ·
--      trigger `trg_lines_rule_coa` ยังผูกกับชื่อเดิม) เปลี่ยนเงื่อนไขเดียว:
--      จาก `cr_coa_code = '1500'` เป็น `cr_coa_code = any(fn_property_coas())`
--      **ไม่แตะกฎอื่นเลย** (1800 ภาษีหัก ณ ที่จ่าย · 3400 ส่วนเกินทุนจากการตีราคา ·
--      3410 ผลต่างอัตราแลกเปลี่ยน · รหัสตรงของขาข้ามผู้ถือ ยังเหมือนเดิมทุกข้อ)
--
--   **ห้ามแก้ไฟล์ 20261025000011 เดิม** — ลงไป DB จริงแล้ว · ไฟล์นี้เขียนทับ
--   ของเดิมตามลำดับ (รูปเดียวกับที่ 0011 เขียนทับ 20261025000004)
--
-- **สำเนาสองฝั่งต้องตรงกัน** — `fn_property_coas()` เป็น **สำเนาฝั่ง DB** ของ
--   `PROPERTY_COA` ใน `src/lib/rules/coa.ts` · ไม่ตรงกัน = กฎเดียวอยู่สองที่
--   (บทเรียนข้อ 5) → เทสต์ `src/lib/rules/__tests__/property-coa-set.test.ts`
--   อ่านไฟล์นี้มาเทียบรายชื่อตัวต่อตัว และ guard ท้ายไฟล์พังถ้าด่านกลับไป
--   เทียบรหัสเดียว · ฝั่ง SQL มี `supabase/tests/zz_property_coa_set_test.sql`
--
-- **ไม่ได้ทำให้ด่านหลวมลง** — 1510 ยังลงได้เฉพาะหมวดที่เครดิตบัญชีอสังหาฯ
--   **ที่อยู่ในชุด** เท่านั้น · หมวดขายหุ้น/ทองคำ/ขายฝาก ยังลง 1510 ไม่ได้
--   และ 1510 เองไม่อยู่ในชุด (ไม่งั้นใบที่เครดิต 1510 จะได้สิทธิ์เป็นวงกลม)
--
-- ลำดับ: **ต้องรันหลัง** 20261025000011 (เจ้าของฟังก์ชันรุ่นก่อนไฟล์นี้)
--        และหลัง seed ตารางกฎรุ่นที่มีหมวดขายของ 1520 — guard หัว/ท้ายไฟล์ตรวจให้
--
-- idempotent: `create or replace` สองตัว + `do` block ที่ตรวจอย่างเดียว · รันซ้ำได้ผลเดิม
--
-- ย้อนกลับ (rollback):
--   -- 1. รัน supabase/migrations/20261025000011_sell_re_clears_renovation.sql ซ้ำ
--   --    (idempotent) เพื่อคืน fn_assert_line_coa_in_rules() เป็นรุ่นก่อนไฟล์นี้
--   -- 2. fn_property_coas() ปล่อยค้างไว้ได้ ไม่มีใครเรียกแล้ว (ถอดด้วย
--   --    `drop function sri_os.fn_property_coas()` ถ้าต้องการให้สะอาด)
--   ⚠ ถอดแล้ว **ขายอสังหาฯ เพื่อการขาย (1520) ที่เคยรีโนเวทไม่ได้เลย** —
--     ต้องถอดหมวด `inv.sell_re_held_for_sale` ออกจากตารางกฎคู่กัน ไม่งั้นหมวดนั้น
--     จะอยู่ในฟอร์มแต่ลงบรรทัดค่ารีโนเวทไม่ผ่าน = เปิดครึ่งเดียวในทิศกลับ
-- ============================================================

set search_path = sri_os, public;

-- ------------------------------------------------------------
-- guard หัวไฟล์ — ของที่ต้องมีอยู่ก่อน ไม่งั้นเขียนทับรุ่นผิดหรือครอบของว่าง
-- ------------------------------------------------------------
do $$
begin
  if to_regprocedure('sri_os.fn_assert_line_coa_in_rules()') is null then
    raise exception 'ไม่มี fn_assert_line_coa_in_rules → ต้องรัน 20261008000012 + 20261024000001 + 20261025000011 ก่อนไฟล์นี้';
  end if;
  if to_regprocedure('sri_os.fn_txn_type_can_withhold(text)') is null then
    raise exception 'ไม่มี fn_txn_type_can_withhold → ต้องรัน 20261024000001 ก่อนไฟล์นี้ (ไฟล์นี้เขียนทับฟังก์ชันที่เรียกมัน)';
  end if;
  if to_regprocedure('sri_os.fn_intercompany_coa(text)') is null then
    raise exception 'ไม่มี fn_intercompany_coa → ต้องรัน 20261008000010_coa_intercompany.sql ก่อนไฟล์นี้';
  end if;
  -- กฎของ FCD ต้องมีอยู่ก่อน ไม่งั้นแปลว่าเราจะเขียนทับรุ่นที่เก่ากว่าของจริง
  -- (กับดักเดิมของ 20261025000011: ลอกจากรุ่นที่จำได้ แล้วกฎของ FCD หายไปทั้งก้อน)
  if not exists (select 1 from sri_os.chart_of_accounts where code = '3410') then
    raise exception 'ไม่มีรหัส 3410 ในผังบัญชี → ต้องรัน 20261024000001 + 20261025000004 ก่อนไฟล์นี้ ไม่งั้นการเขียนทับฟังก์ชันจะทำกฎของบัญชี FCD หาย';
  end if;
  if not exists (select 1 from sri_os.chart_of_accounts where code = '1510') then
    raise exception 'ไม่มีรหัส 1510 ค่ารีโนเวทในผังบัญชี → seed ผังบัญชีก่อน';
  end if;
  if not exists (select 1 from sri_os.chart_of_accounts where code = '1520') then
    raise exception 'ไม่มีรหัส 1520 อสังหาฯ เพื่อการขายในผังบัญชี → seed ผังบัญชีรุ่น 27/10 ก่อน (npm run sync:rules)';
  end if;
end $$;

-- ============================================================
-- 1 · ชุดบัญชีอสังหาริมทรัพย์ที่ค่ารีโนเวท (1510) เกาะได้ — **ที่เดียว**
--
--   แพทเทิร์นเดียวกับ fn_unrealised_equity_coas(): ด่านทุกตัวอ่านชุดจากที่นี่
--   แทนที่จะพิมพ์รหัสซ้ำ · เพิ่มบัญชีอสังหาฯ ตัวที่สามแก้ที่นี่ที่เดียว
--   (และต้องแก้ PROPERTY_COA ใน src/lib/rules/coa.ts ให้ตรงกัน — เทสต์เทียบให้)
-- ============================================================
create or replace function fn_property_coas() returns text[]
language sql immutable set search_path = '' as $fn$
  -- 1500 อสังหาฯ เพื่อการลงทุน **เพื่อการเช่า** · 1520 **เพื่อการขาย** (27/10)
  -- ค่ารีโนเวท (1510) ใช้บัญชีเดียวร่วมกันทั้งสองวัตถุประสงค์โดยตั้งใจ
  -- → คำถาม "ใบนี้ตัด 1510 ได้ไหม" คือ "เครดิตบัญชีอสังหาฯ ตัวใดตัวหนึ่งหรือเปล่า"
  --   ไม่ใช่ "เครดิต 1500 หรือเปล่า"
  -- **1510 เองไม่อยู่ในชุด** — มันคือต้นทุนที่เกาะ ไม่ใช่ตัวบัญชีอสังหาฯ
  --   ถ้าอยู่ในชุด ใบที่เครดิต 1510 จะได้สิทธิ์ลง 1510 จากตัวมันเองเป็นวงกลม
  select array['1500', '1520'];
$fn$;

comment on function fn_property_coas() is
  'บัญชีอสังหาริมทรัพย์เพื่อการลงทุนที่ **ค่ารีโนเวท (1510) เกาะได้** (1500 เพื่อการเช่า · 1520 เพื่อการขาย) · สำเนาฝั่ง DB ของ PROPERTY_COA ใน src/lib/rules/coa.ts · ด่านที่ตัดสินสิทธิ์ลงบรรทัดค่ารีโนเวทอ่านชุดนี้ที่เดียว ห้ามเทียบรหัสเดียว (27/10)';

revoke all on function fn_property_coas() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_property_coas() from anon';
  execute 'grant execute on function sri_os.fn_property_coas() to authenticated';
end $$;

-- ============================================================
-- 2 · ด่านคู่บัญชีระดับบรรทัด — เขียนทับทั้งฟังก์ชันจากรุ่น 20261025000011
--
--   ต่างจากรุ่นเดิม **บรรทัดเดียว**: เงื่อนไขสิทธิ์ลง 1510 อ่านจาก
--   fn_property_coas() แทนการเทียบ cr_coa_code = '1500'
-- ============================================================
create or replace function fn_assert_line_coa_in_rules() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_type    text;
  v_nature  text;
  v_code    text;
  v_allowed text[];
  v_pair    text[];
  v_capgain boolean;
  v_gain    text;
  v_loss    text;
begin
  select t.txn_type_code, nullif(t.intercompany_nature, '')
    into v_type, v_nature
    from sri_os.transactions t
   where t.id = new.transaction_id;
  if v_type is null then
    return new;   -- ไม่มีหัวรายการให้เทียบ → FK/ด่านอื่นปฏิเสธด้วยข้อความของมันเอง
  end if;

  select c.code into v_code
    from sri_os.chart_of_accounts c where c.id = new.coa_id;
  if v_code is null then
    raise exception 'บรรทัดบัญชีชี้รหัสบัญชีที่ไม่มีอยู่ในผังบัญชี (coa_id %)', new.coa_id;
  end if;

  select array_remove(array[t.dr_coa_code, t.cr_coa_code, t.gain_coa_code,
                            t.loss_coa_code, t.interest_coa_code, t.accrual_coa_code], null),
         t.requires_capital_gain, t.gain_coa_code, t.loss_coa_code
    into v_allowed, v_capgain, v_gain, v_loss
    from sri_os.txn_types t where t.code = v_type;
  if v_allowed is null or cardinality(v_allowed) = 0 then
    raise exception 'ตารางกฎ (txn_types) ไม่ได้ระบุบัญชีของหมวด "%" เลย — sync ด้วย npm run sync:rules ก่อน ห้ามเดาคู่บัญชีแทน',
      v_type;
  end if;

  if v_nature is not null then
    v_pair := sri_os.fn_intercompany_coa(v_nature);
    if v_pair is null then
      raise exception 'ลักษณะรายการข้ามผู้ถือ "%" ยังไม่มีคู่บัญชีระหว่างกันในฝั่งฐานข้อมูล — เพิ่มใน fn_intercompany_pairs() ให้ตรงกับ src/lib/rules/intercompany.ts ก่อนใช้',
        v_nature;
    end if;
    -- ขาเงินสดกับ **รหัสตรง** ของลักษณะนั้นใช้ได้บนขาข้ามผู้ถือ
    v_allowed := v_allowed || array['1100'] || v_pair;
  end if;

  -- D-111 ข้อ 1 · บรรทัดภาษีถูกหัก ณ ที่จ่าย — เฉพาะหมวดที่หักได้จริง
  if sri_os.fn_txn_type_can_withhold(v_type) then
    v_allowed := v_allowed || array['1800'];
  end if;

  -- D-111 ข้อ 2 · บรรทัดล้างส่วนเกินทุนจากการตีราคา — เฉพาะหมวดที่รับรู้กำไร/ขาดทุนจากการขาย
  -- (หมวดตีราคาเองมี 3400 อยู่ใน dr/cr แล้ว จึงไม่ต้องเติมให้)
  if coalesce(v_capgain, false) then
    v_allowed := v_allowed || array['3400'];
  end if;

  -- FCD (25/10) · บรรทัดล้างผลต่างอัตราแลกเปลี่ยนที่ยังไม่เกิดจริง — เฉพาะหมวดที่
  -- **ประกาศบัญชีกำไร/ขาดทุนอัตราแลกเปลี่ยนไว้** (คือหมวดแลกเป็นบาทจริง)
  -- หมวดแปลงค่าเองมี 3410 อยู่ใน dr/cr แล้ว
  if v_gain = '4330' or v_loss = '5930' then
    v_allowed := v_allowed || array['3410'];
  end if;

  /**
   * **ค่ารีโนเวทที่บันทึกเป็นทุน (1510) ต้องถูกตัดออกในใบขายเดียวกับตัวทรัพย์**
   *
   * 1510 ไม่ใช่ทรัพย์ชิ้นใหม่ — เป็น **ส่วนหนึ่งของต้นทุนของอสังหาฯ ชิ้นเดียวกัน**
   * (`inv.capex` / `opn.renovation` ลงที่ 1510 โดยผูก `asset_id` เดียวกับตัวทรัพย์)
   * ถ้าใบขายลง 1510 ไม่ได้ ต้นทุนส่วนนั้นค้างในงบดุลเป็นทรัพย์ผี และกำไรจาก
   * การขายสูงกว่าจริงเท่าค่ารีโนเวทสะสม · ด่าน "ทรัพย์ชิ้นเดียวต้องตัดต้นทุน
   * ทั้งก้อน" (20261025000010) จะบังคับสิ่งที่ทำไม่ได้
   *
   * **เทียบกับชุด ไม่ใช่รหัสเดียว** (27/10) — รุ่นก่อนหน้า (20261025000011)
   * เทียบ `cr_coa_code = '1500'` ตอนที่อสังหาฯ เพื่อการลงทุนมีบัญชีเดียว
   * พอแยกเป็นเพื่อการเช่า (1500) กับเพื่อการขาย (1520) เงื่อนไขรหัสเดียว
   * **ทำให้ขายของที่ตั้งใจขายไม่ได้** · ชุดอยู่ที่ `fn_property_coas()` ที่เดียว
   * → บัญชีอสังหาฯ ตัวใหม่ในอนาคตได้สิทธิ์นี้โดยแก้ชุด ไม่ต้องแก้ด่าน
   *
   * **อ่านจากตารางกฎ ไม่ใช่เช็ครหัสหมวดตรงๆ** ตามกฎของ CLAUDE.md: เงื่อนไขคือ
   * "หมวดนี้ **จำหน่าย** บัญชีอสังหาฯ ออกทางเครดิต" ซึ่งเป็นจริงกับหมวดจำหน่าย
   * อสังหาฯ ทุกหมวดที่จะเพิ่มในอนาคตโดยไม่ต้องแก้ด่านนี้อีก
   *
   * **ต้องมี `requires_capital_gain` ด้วย** (ผู้ตรวจข้อ 4 · 27/10) — เงื่อนไข
   * "เครดิตบัญชีอสังหาฯ" อย่างเดียว **กว้างเกินไปหนึ่งขั้น** เพราะหมวดย้าย
   * วัตถุประสงค์ (`adj.reclass_re_to_sale` เครดิต 1500 · `adj.reclass_re_to_rental`
   * เครดิต 1520) ก็เครดิตบัญชีในชุดเหมือนกัน แต่ **ไม่ใช่การขาย**
   *
   * ค่ารีโนเวท (1510) เป็นบัญชี **ร่วม** ของทั้งเพื่อการเช่าและเพื่อการขาย
   * และผูกกับทรัพย์ชิ้นนั้นด้วย `asset_id` อยู่แล้ว → การย้ายวัตถุประสงค์
   * **ไม่ต้องย้าย 1510** · ถ้าปล่อยให้ใบย้ายลง 1510 ได้ จะเกิดใบที่ย้ายค่ารีโนเวท
   * ไปอีกบัญชีหนึ่งโดยที่ตัวทรัพย์ยังอยู่ที่เดิม = ต้นทุนของทรัพย์ชิ้นเดียว
   * กระจายอยู่สองที่แบบที่ไม่มีด่านไหนจับ (ยอดรวมหมวดยังเท่าเดิม)
   *
   * สิทธิ์ลง 1510 จึงให้เฉพาะหมวดที่ **ตัดทรัพย์ออกจริง** ซึ่งคือหมวดที่ตารางกฎ
   * บอกว่าต้องคำนวณกำไร/ขาดทุนจากการขาย — เงื่อนไขนี้ยังอ่านจากตารางกฎทั้งคู่
   */
  if exists (select 1 from sri_os.txn_types t
              where t.code = v_type
                and t.cr_coa_code = any (sri_os.fn_property_coas())
                and t.requires_capital_gain) then
    v_allowed := v_allowed || array['1510'];
  end if;

  if not (v_code = any (v_allowed)) then
    raise exception 'หมวด "%" ลงบัญชี % ไม่ได้ — ตารางกฎระบุบัญชีของหมวดนี้ไว้เฉพาะ % · คู่บัญชีที่ไม่ตรงหมวดทำให้ผิดทั้งงบ (เช่น เงินกู้กลายเป็นรายได้)',
      v_type, v_code, array_to_string(v_allowed, ', ');
  end if;

  return new;
end $fn$;

comment on function fn_assert_line_coa_in_rules() is
  'ข้อ 3 ของผู้ตรวจ · ทุกบรรทัดต้องใช้บัญชีที่ตารางกฎ (sri_os.txn_types) ระบุของหมวดนั้น · ขาข้ามผู้ถือล็อกเป็นรหัสตรงจาก fn_intercompany_pairs() · บวก 1800 ให้หมวดที่หักภาษี ณ ที่จ่ายได้ (D-111 ข้อ 1) · บวก 3400 ให้หมวดที่รับรู้กำไร/ขาดทุนจากการขาย ซึ่งต้องล้างส่วนเกินทุนจากการตีราคาพร้อมกัน (D-111 ข้อ 2) · บวก 3410 ให้หมวดที่ประกาศบัญชีกำไร/ขาดทุนอัตราแลกเปลี่ยนไว้ (FCD) · บวก **1510 ค่ารีโนเวท** ให้หมวดที่เครดิตบัญชีอสังหาฯ **ตัวใดตัวหนึ่งใน fn_property_coas()** (1500 เพื่อการเช่า · 1520 เพื่อการขาย) **และ requires_capital_gain** เพราะค่ารีโนเวทเป็นส่วนหนึ่งของต้นทุนอสังหาฯ ชิ้นเดียวกัน ต้องถูกตัดออกในใบขายเดียวกัน ไม่ใช่ค้างเป็นทรัพย์ผี · ธง requires_capital_gain กันหมวด**ย้ายวัตถุประสงค์** (เครดิตบัญชีในชุดเหมือนกันแต่ไม่ได้ตัดทรัพย์ออก) ไม่ให้ลง 1510 ซึ่งจะทำให้ต้นทุนของทรัพย์ชิ้นเดียวกระจายอยู่สองบัญชีโดยยอดรวมหมวดยังเท่าเดิม (25/10 · แก้เป็นชุดแทนรหัสเดียว 27/10 · แคบลงด้วย requires_capital_gain 27/10)';

revoke all on function fn_assert_line_coa_in_rules() from public;
do $$ begin execute 'revoke all on function sri_os.fn_assert_line_coa_in_rules() from anon, authenticated'; end $$;

-- ============================================================
-- guard ท้ายไฟล์ — ดังตอน migrate ไม่ใช่ตอนผู้ใช้กด
-- ============================================================
do $$
declare
  v_set  text[];
  v_src  text;
  v_code text;
  v_subs text;
  v_miss text;
begin
  -- (ก) trigger ต้องยังผูกอยู่กับฟังก์ชันตัวนี้ (เขียนทับฟังก์ชัน ไม่ได้สร้างตัวใหม่)
  if not exists (select 1 from pg_trigger g
                  join pg_proc p on p.oid = g.tgfoid
                 where g.tgrelid = 'sri_os.transaction_lines'::regclass
                   and g.tgname = 'trg_lines_rule_coa'
                   and p.proname = 'fn_assert_line_coa_in_rules'
                   and not g.tgisinternal) then
    raise exception 'trigger trg_lines_rule_coa ไม่ได้ชี้มาที่ fn_assert_line_coa_in_rules — เขียนทับผิดตัว';
  end if;

  -- (ข) ชุดต้องไม่ว่าง และทุกรหัสต้องมีอยู่จริงในผังบัญชี
  v_set := sri_os.fn_property_coas();
  if v_set is null or cardinality(v_set) = 0 then
    raise exception 'fn_property_coas() คืนชุดว่าง — ด่านจะไม่ให้ใครลงบรรทัดค่ารีโนเวทได้เลย';
  end if;
  foreach v_code in array v_set loop
    if not exists (select 1 from sri_os.chart_of_accounts where code = v_code) then
      raise exception 'fn_property_coas() มีรหัส % ที่ไม่อยู่ในผังบัญชี — ชุดกับผังบัญชีไม่ตรงกัน', v_code;
    end if;
  end loop;

  -- (ค) **ด่านต้องอ่านจากชุด ไม่ใช่เทียบรหัสเดียว** — จุดที่พลาดมาแล้วหนึ่งรอบ
  --     ตรวจจาก prosrc ของจริงใน catalog ไม่ใช่จากไฟล์ (ไฟล์กับ DB ต่างกันได้)
  --
  --     **ตัดคอมเมนต์ในตัวฟังก์ชันออกก่อนตรวจ** — คอมเมนต์ในฟังก์ชันคือเอกสาร
  --     กำกับกฎเงิน (pg_dump เก็บไว้จริง) และมันต้องอธิบายเงื่อนไขเดิมที่เลิกใช้
  --     ถ้าไม่ตัด guard จะดังเพราะคำอธิบายของตัวเอง ไม่ใช่เพราะโค้ดผิด
  select p.prosrc into v_src from pg_proc p
   where p.oid = 'sri_os.fn_assert_line_coa_in_rules()'::regprocedure;
  v_src := regexp_replace(v_src, '/\*.*?\*/', ' ', 'g');   -- บล็อกคอมเมนต์ (ไม่ละโมบ)
  v_src := regexp_replace(v_src, '--[^' || chr(10) || ']*', ' ', 'g');
  if v_src not like '%fn_property_coas()%' then
    raise exception 'fn_assert_line_coa_in_rules ไม่ได้อ่าน fn_property_coas() — ด่านกลับไปถือรายชื่อของตัวเอง = กฎเดียวอยู่สองที่';
  end if;
  if v_src ~ 'cr_coa_code\s*=\s*''1[0-9]{3}''' then
    raise exception 'fn_assert_line_coa_in_rules กลับไปเทียบรหัสบัญชีเดียวตรงๆ — บัญชีอสังหาฯ ตัวอื่นในชุดจะขายไม่ได้อีกรอบ (ช่องเดิมของ 7ad740e)';
  end if;

  -- (ค2) **สิทธิ์ลง 1510 ต้องผูกกับการจำหน่าย ไม่ใช่แค่เครดิตบัญชีในชุด**
  --      (ผู้ตรวจข้อ 4 · 27/10) ถ้าเงื่อนไขนี้หลุด หมวดย้ายวัตถุประสงค์จะลง 1510 ได้
  if v_src !~ 'requires_capital_gain' then
    raise exception 'fn_assert_line_coa_in_rules ไม่ได้บังคับ requires_capital_gain ตอนให้สิทธิ์ 1510 — หมวดย้ายวัตถุประสงค์จะย้ายค่ารีโนเวทไปอีกบัญชีได้โดยทรัพย์ยังอยู่ที่เดิม = ต้นทุนของทรัพย์ชิ้นเดียวกระจายสองที่ โดยยอดรวมหมวดยังเท่าเดิม (ไม่มีด่านไหนจับ)';
  end if;

  -- (ค3) **พิสูจน์ผลลัพธ์ ไม่ใช่เชื่อข้อความในโค้ด** — หมวดที่เครดิตบัญชีในชุด
  --      แต่ไม่ใช่การขาย ต้องมีอยู่จริง (หมวดย้ายวัตถุประสงค์) และต้องถูกกันออก
  select string_agg(t.code, ', ' order by t.code) into v_subs
    from sri_os.txn_types t
   where t.cr_coa_code = any (v_set) and not t.requires_capital_gain;
  if v_subs is null then
    raise notice 'ยังไม่มีหมวดที่เครดิตบัญชีอสังหาฯ โดยไม่ใช่การขาย — เงื่อนไข requires_capital_gain ยังไม่มีผลต่างในวันนี้ แต่ต้องคงไว้';
  else
    raise notice 'หมวดที่เครดิตบัญชีอสังหาฯ แต่ไม่ใช่การขาย (%) ถูกกันออกจากสิทธิ์ลง 1510 ตามที่ควรเป็น', v_subs;
  end if;

  -- (ง) **ทุกบัญชีในชุดต้องมีหมวดขายของตัวเอง** — มีบัญชีแต่ขายไม่ได้
  --     คือเปิดฟีเจอร์ครึ่งเดียว (บทเรียน mace-windu ข้อ 7) ซึ่งคือช่องที่ไฟล์นี้ปิด
  v_miss := '';
  foreach v_code in array v_set loop
    if not exists (select 1 from sri_os.txn_types t
                    where t.cr_coa_code = v_code and t.requires_capital_gain) then
      v_miss := v_miss || v_code || ' ';
    end if;
  end loop;
  if v_miss <> '' then
    raise exception 'บัญชีอสังหาฯ ในชุดที่ยังไม่มีหมวดจำหน่ายของตัวเองในตารางกฎ: % — แยกบัญชีได้แต่ขายไม่ได้ · sync ด้วย npm run sync:rules ก่อน', v_miss;
  end if;

  -- ข้อความปิดต้องนับ **เฉพาะหมวดที่ได้สิทธิ์จริง** (เครดิตบัญชีในชุด **และ**
  -- requires_capital_gain) · รุ่นก่อนหน้านับทุกหมวดที่เครดิตบัญชีในชุด แล้วพิมพ์ว่า
  -- หมวดย้ายวัตถุประสงค์ "ลงบรรทัด 1510 ได้" ซึ่ง **ขัดกับด่านที่ไฟล์เดียวกันสร้าง**
  -- — ข้อความที่โกหกเรื่องกฎเงินอันตรายเท่ากฎที่ผิด เพราะคนอ่านแล้วเชื่อ
  select string_agg(t.code, ', ' order by t.code) into v_subs
    from sri_os.txn_types t
   where t.cr_coa_code = any (v_set) and t.requires_capital_gain;
  raise notice 'ok · ชุดบัญชีอสังหาฯ = % · หมวด**จำหน่าย**ที่ลงบรรทัด 1510 ได้: % — ขายได้ทุกวัตถุประสงค์โดยไม่ต้องย้ายบัญชีก่อน',
    array_to_string(v_set, ', '), v_subs;
end $$;
