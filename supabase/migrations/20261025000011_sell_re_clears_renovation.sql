-- ============================================================
-- SRI OS · **ขายอสังหาฯ ที่เคยรีโนเวทแล้วตัด 1510 ออกได้** — ปิดช่องที่ทำให้
--            ด่าน "ทรัพย์ชิ้นเดียวต้องตัดต้นทุนทั้งก้อน" ห้ามสิ่งที่ต้องทำ
--
-- **ที่มา (เจอตอนทำ 20261025000010)**
--   `fn_asset_cost_basis()` นับทุกบัญชีสินทรัพย์ที่ผูกทรัพย์ชิ้นนั้น ซึ่งรวม
--   **1510 ค่ารีโนเวท (บันทึกเป็นทุน)** ที่ `inv.capex` / `opn.renovation` ลงไว้
--   แต่ `fn_assert_line_coa_in_rules()` อนุญาตเฉพาะบัญชีที่ตารางกฎระบุของหมวดนั้น
--   และ `inv.sell_re` ระบุไว้แค่ `1500` → **ใบขายลงบรรทัด 1510 ไม่ได้**
--
--   ผลที่วัดได้ (เทสต์ `zz_asset_cost_basis_mode_test.sql` R1):
--     คอนโดต้นทุน 3,000,000 + รีโนเวท 500,000 = 3,500,000
--     ขาย 4,000,000 → ก่อนไฟล์นี้ ตัดได้แค่ 1500 (3,000,000)
--       → **กำไรโชว์ 1,000,000 ทั้งที่ของจริง 500,000** (สูงกว่าจริงเท่าค่ารีโนเวท)
--       → และ 1510 ค้างในงบดุล 500,000 เป็นทรัพย์ที่ขายไปแล้ว
--     หลังไฟล์นี้: ตัดทั้ง 1500 + 1510 ในใบเดียว → กำไร 500,000 · งบดุลสะอาด
--
--   เรื่องนี้ **เป็นบั๊กอยู่ก่อนแล้ว** ด่านของ 20261025000010 แค่ทำให้มันดัง:
--   มันบังคับว่าหลังขายทรัพย์ชิ้นเดียว ต้นทุนคงเหลือต้องเป็นศูนย์
--   ซึ่งเป็นไปไม่ได้ถ้าบรรทัด 1510 ลงไม่ได้ → ต้องปิดช่องนี้คู่กัน
--   (บทเรียน mace-windu ข้อ 7: เปิดครึ่งเดียวอันตรายกว่าไม่เปิด — ที่นี่คือ
--    "ตั้งต้นทุนเป็นทุนได้ แต่ตัดออกไม่ได้" รูปเดียวกับ "ตั้งค้างได้แต่ล้างไม่ได้")
--
-- **สิ่งที่เปลี่ยน** — เขียนทับ `fn_assert_line_coa_in_rules()` ทั้งฟังก์ชัน
--   (ลายเซ็นเดิม · trigger `trg_lines_rule_coa` ยังผูกอยู่กับชื่อเดิม) และเพิ่ม
--   เงื่อนไขเดียว: หมวดที่ **เครดิต 1500** (จำหน่ายอสังหาฯ เพื่อการลงทุน)
--   ลงบรรทัด **1510** ได้ด้วย เพราะ 1510 เป็นส่วนหนึ่งของต้นทุนทรัพย์ชิ้นเดียวกัน
--
--   **อ่านจากตารางกฎ (`txn_types.cr_coa_code`) ไม่ใช่เช็ครหัสหมวดตรงๆ** ตามกฎ
--   ของ CLAUDE.md → หมวดจำหน่ายอสังหาฯ ตัวใหม่ในอนาคตได้สิทธิ์นี้เองโดยไม่ต้องแก้ด่าน
--
--   **ไม่ได้ทำให้ด่านหลวมลงในทางอื่น**: 1510 ยังลงได้เฉพาะหมวดที่เครดิต 1500
--   และยังถูกด่านอื่นคุมครบ (ผูกทรัพย์ · สมดุล · ต้นทุนติดลบไม่ได้ ·
--   ทรัพย์ชิ้นเดียวต้องตัดทั้งก้อน · ล้าง 3400 ทั้งก้อน)
--
-- **ฐานที่เขียนทับคือรุ่นล่าสุด (`20261025000004_fcd_bank_currency.sql`) ไม่ใช่รุ่นแรก**
--   ฟังก์ชันนี้ถูกเขียนทับมาแล้วสี่รอบ (0008000012 → 0008000013 → 1024000001 →
--   1025000004) · ครั้งแรกที่เขียนไฟล์นี้ผมลอกจากรุ่น `20261024000001` ซึ่ง
--   **ทำให้กฎของ FCD หายไป** (บรรทัด 3410 ของ `trf.fx_convert` ลงไม่ได้) และเทสต์
--   `zz_fcd_currency_test.sql` แดงทันที — บันทึกไว้เพราะเป็นกับดักของการ
--   "เขียนทับทั้งฟังก์ชัน": ต้องลอกจากรุ่นที่ apply ล่าสุด ไม่ใช่รุ่นที่จำได้
--
-- ลำดับ: **ต้องรันหลัง** 20261025000004 (เจ้าของฟังก์ชันรุ่นล่าสุด) และควรรันคู่กับ
--        20261025000010 · guard หัวไฟล์ตรวจให้
--
-- idempotent: `create or replace` ตัวเดียว · รันซ้ำได้ผลเดิม
--
-- ย้อนกลับ (rollback):
--   -- รัน supabase/migrations/20261024000001_wht_and_fx.sql ซ้ำ (idempotent)
--   --   เพื่อคืน fn_assert_line_coa_in_rules() เป็นรุ่นก่อนไฟล์นี้
--   ⚠ ถอดแล้ว **ขายคอนโดที่เคยรีโนเวทไม่ได้เลย** เพราะด่านของ 20261025000010
--     บังคับให้ตัดต้นทุนทั้งก้อน แต่บรรทัด 1510 ลงไม่ได้ → ต้องถอดสองไฟล์คู่กัน
-- ============================================================

set search_path = sri_os, public;

do $$
begin
  if to_regprocedure('sri_os.fn_assert_line_coa_in_rules()') is null then
    raise exception 'ไม่มี fn_assert_line_coa_in_rules → ต้องรัน 20261008000012 + 20261024000001 ก่อนไฟล์นี้';
  end if;
  if to_regprocedure('sri_os.fn_txn_type_can_withhold(text)') is null then
    raise exception 'ไม่มี fn_txn_type_can_withhold → ต้องรัน 20261024000001 ก่อนไฟล์นี้ (ไฟล์นี้เขียนทับฟังก์ชันที่เรียกมัน)';
  end if;
  -- กฎของ FCD ต้องมีอยู่ก่อน ไม่งั้นแปลว่าเราจะเขียนทับรุ่นที่เก่ากว่าของจริง
  if not exists (select 1 from sri_os.chart_of_accounts where code = '3410') then
    raise exception 'ไม่มีรหัส 3410 ในผังบัญชี → ต้องรัน 20261024000001 + 20261025000004 ก่อนไฟล์นี้ ไม่งั้นการเขียนทับฟังก์ชันจะทำกฎของบัญชี FCD หาย';
  end if;
  if to_regprocedure('sri_os.fn_intercompany_coa(text)') is null then
    raise exception 'ไม่มี fn_intercompany_coa → ต้องรัน 20261008000010_coa_intercompany.sql ก่อนไฟล์นี้';
  end if;
  if not exists (select 1 from sri_os.chart_of_accounts where code = '1510') then
    raise exception 'ไม่มีรหัส 1510 ในผังบัญชี → seed ผังบัญชีก่อน';
  end if;
end $$;

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
   * ด่านเดิมอนุญาตเฉพาะ dr/cr ของหมวด ซึ่งของ `inv.sell_re` คือ 1500 เท่านั้น
   * → **ใบขายคอนโดที่เคยรีโนเวทลง 1510 ออกไม่ได้เลย** ต้นทุนส่วนนั้นค้างในงบดุล
   *   เป็นทรัพย์ผี และกำไรจากการขายสูงกว่าจริงเท่าค่ารีโนเวทสะสม
   *
   * ค้นพบตอนทำด่าน "ทรัพย์ชิ้นเดียวต้องตัดต้นทุนทั้งก้อน" (20261025000010):
   * ด่านนั้นบังคับให้ต้นทุนคงเหลือเป็นศูนย์หลังขาย ซึ่ง **ทำไม่ได้เลย**
   * ถ้าบรรทัด 1510 ลงไม่ได้ = ด่านที่ห้ามสิ่งที่ต้องทำ
   *
   * **อ่านจากตารางกฎ ไม่ใช่เช็ครหัสหมวดตรงๆ**: เงื่อนไขคือ "หมวดนี้ตัดบัญชี
   * อสังหาฯ เพื่อการลงทุน (1500) ออกทางเครดิต" ซึ่งเป็นจริงกับหมวดจำหน่าย
   * อสังหาฯ ทุกหมวดที่จะเพิ่มในอนาคตโดยไม่ต้องแก้ด่านนี้อีก
   */
  if exists (select 1 from sri_os.txn_types t
              where t.code = v_type and t.cr_coa_code = '1500') then
    v_allowed := v_allowed || array['1510'];
  end if;

  if not (v_code = any (v_allowed)) then
    raise exception 'หมวด "%" ลงบัญชี % ไม่ได้ — ตารางกฎระบุบัญชีของหมวดนี้ไว้เฉพาะ % · คู่บัญชีที่ไม่ตรงหมวดทำให้ผิดทั้งงบ (เช่น เงินกู้กลายเป็นรายได้)',
      v_type, v_code, array_to_string(v_allowed, ', ');
  end if;

  return new;
end $fn$;

comment on function fn_assert_line_coa_in_rules() is
  'ข้อ 3 ของผู้ตรวจ · ทุกบรรทัดต้องใช้บัญชีที่ตารางกฎ (sri_os.txn_types) ระบุของหมวดนั้น · ขาข้ามผู้ถือล็อกเป็นรหัสตรงจาก fn_intercompany_pairs() · บวก 1800 ให้หมวดที่หักภาษี ณ ที่จ่ายได้ (D-111 ข้อ 1) · บวก 3400 ให้หมวดที่รับรู้กำไร/ขาดทุนจากการขาย ซึ่งต้องล้างส่วนเกินทุนจากการตีราคาพร้อมกัน (D-111 ข้อ 2) · บวก 3410 ให้หมวดที่ประกาศบัญชีกำไร/ขาดทุนอัตราแลกเปลี่ยนไว้ (FCD) · บวก **1510 ค่ารีโนเวท** ให้หมวดที่เครดิต 1500 เพราะค่ารีโนเวทเป็นส่วนหนึ่งของต้นทุนอสังหาฯ ชิ้นเดียวกัน ต้องถูกตัดออกในใบขายเดียวกัน ไม่ใช่ค้างเป็นทรัพย์ผี (25/10)';

revoke all on function fn_assert_line_coa_in_rules() from public;
do $$ begin execute 'revoke all on function sri_os.fn_assert_line_coa_in_rules() from anon, authenticated'; end $$;

-- ============================================================
-- guard ท้ายไฟล์ — ดังตอน migrate ไม่ใช่ตอนผู้ใช้กด
-- ============================================================
do $$
declare v text;
begin
  -- trigger ต้องยังผูกอยู่กับฟังก์ชันตัวนี้ (เขียนทับฟังก์ชัน ไม่ได้สร้างตัวใหม่)
  if not exists (select 1 from pg_trigger g
                  join pg_proc p on p.oid = g.tgfoid
                 where g.tgrelid = 'sri_os.transaction_lines'::regclass
                   and g.tgname = 'trg_lines_rule_coa'
                   and p.proname = 'fn_assert_line_coa_in_rules'
                   and not g.tgisinternal) then
    raise exception 'trigger trg_lines_rule_coa ไม่ได้ชี้มาที่ fn_assert_line_coa_in_rules — เขียนทับผิดตัว';
  end if;

  -- หมวดจำหน่ายอสังหาฯ ต้องมีอยู่จริงในตารางกฎ ไม่งั้นเงื่อนไขใหม่ไม่ครอบอะไรเลย
  select string_agg(code, ', ' order by code) into v
    from sri_os.txn_types where cr_coa_code = '1500';
  if v is null then
    raise exception 'ไม่มีหมวดไหนในตารางกฎที่เครดิต 1500 — เงื่อนไขใหม่จะไม่ครอบอะไรเลย · sync ด้วย npm run sync:rules ก่อน';
  end if;

  raise notice 'ok · หมวดที่เครดิต 1500 (%) ลงบรรทัด 1510 ได้แล้ว — ขายอสังหาฯ ที่เคยรีโนเวทตัดต้นทุนครบทั้งก้อนได้', v;
end $$;
