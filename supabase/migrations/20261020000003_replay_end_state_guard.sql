-- ============================================================
-- SRI OS · ด่านตรวจสภาพปลายทางของตารางกฎ หลัง apply ครบทุกไฟล์
--
-- ทำไมต้องมี: `20260918000002a_capital_gain_bootstrap.sql` **ปลดธง
--   requires_capital_gain ชั่วคราว** เพื่อให้ constraint ของ `20260918000003`
--   ใส่ได้ตอน replay จาก DB เปล่า · ไฟล์ seed ตัวจริงที่มาทีหลังตั้งธงคืน
--   **แต่ถ้าไฟล์ seed นั้นไม่ได้รัน DB จะค้างกฎที่ผิดแบบเงียบๆ** คือ
--   "ขายอสังหาฯ / ขายหลักทรัพย์ ไม่ต้องรับรู้กำไรขาดทุน" ซึ่งแปลว่า
--   กำไรจากการขายจะไม่ถูกบันทึกเลย และไม่มีอะไรฟ้อง
--
--   รูปแบบความผิด "เปิดช่องชั่วคราวแล้วลืมปิด" คือสิ่งที่โปรเจกต์นี้โดนซ้ำที่สุด
--   → ไฟล์นี้ทำให้มันกลายเป็น **การ apply ที่พังเสียงดัง** แทนที่จะเป็น
--   ตัวเลขที่ผิดอย่างเงียบเชียบ
--
-- **ไฟล์นี้ต้องอยู่คู่กับ `20260918000002a` เสมอ** ถ้าวันหนึ่งเลิกใช้ bootstrap
--   ให้ลบทั้งคู่พร้อมกัน · ถ้าลบตัวกันไว้ตัวเดียวคือเปิดรูที่เพิ่งปิด
--
-- ต้องรัน **ท้ายสุด หลังไฟล์ seed ทุกตัว** → ลงทะเบียนใน
--   `supabase/migration-order.txt` ไม่ใช่พึ่งลำดับชื่อไฟล์
--
-- ไฟล์นี้ไม่สร้างและไม่แก้อะไร ตรวจแล้วพังหรือผ่านเท่านั้น (รันซ้ำได้ตลอด)
-- ============================================================

set search_path = sri_os, public;

do $$
declare
  n_gain      int;
  n_gain_bad  int;
  n_int_bad   int;
  missing     text;
begin
  -- 1. ธงต้องไม่ถูกปลดค้างไว้ทั้งตาราง
  select count(*) into n_gain
    from sri_os.txn_types where requires_capital_gain;
  if n_gain = 0 then
    raise exception 'ไม่มีหมวดใดใน txn_types ที่ requires_capital_gain = true เลย — '
      'แปลว่าไฟล์ seed ตัวจริงไม่ได้รันหลัง 20260918000002a_capital_gain_bootstrap.sql '
      'ซึ่งปลดธงนี้ไว้ชั่วคราว · DB กำลังถือกฎที่ผิด (ขายทรัพย์ไม่รับรู้กำไร/ขาดทุน) '
      'ให้ apply ไฟล์ seed_rules ให้ครบก่อน';
  end if;

  -- 2. ทุกหมวดที่ต้องรับรู้กำไร ต้องมีบัญชีทั้งสองข้าง
  select count(*) into n_gain_bad
    from sri_os.txn_types
   where requires_capital_gain
     and (gain_coa_code is null or loss_coa_code is null);
  if n_gain_bad > 0 then
    raise exception 'มี % หมวดที่ requires_capital_gain = true แต่ขาดบัญชีกำไรหรือขาดทุน', n_gain_bad;
  end if;

  -- 3. ธง requires_principal_split ก็ถูกปลดชั่วคราวเหมือนกัน ต้องไม่ค้างทั้งตาราง
  if (select count(*) from sri_os.txn_types where requires_principal_split) = 0 then
    raise exception 'ไม่มีหมวดใดใน txn_types ที่ requires_principal_split = true เลย — '
      'ไฟล์ seed ตัวจริงไม่ได้รันหลัง 20260918000002a_capital_gain_bootstrap.sql '
      'ซึ่งปลดธงนี้ไว้ชั่วคราว · DB กำลังถือกฎที่ผิด (รับชำระหนี้ไม่ต้องแยกเงินต้นกับดอกเบี้ย '
      'ซึ่งทำให้ดอกเบี้ยถูกนับเป็นเงินต้น) ให้ apply ไฟล์ seed_rules ให้ครบก่อน';
  end if;

  -- 4. ทุกหมวดที่ต้องแยกเงินต้น/ดอกเบี้ย ต้องรู้ว่าดอกเบี้ยลงบัญชีไหน
  select count(*) into n_int_bad
    from sri_os.txn_types
   where requires_principal_split and interest_coa_code is null;
  if n_int_bad > 0 then
    raise exception 'มี % หมวดที่ requires_principal_split = true แต่ไม่มี interest_coa_code', n_int_bad;
  end if;

  -- 5. constraint ทั้งสองต้องมีจริงและ **validate แล้ว**
  --    (`not valid` = มีชื่ออยู่แต่ไม่เคยตรวจแถวเดิม ซึ่งเท่ากับไม่มีด่าน)
  select string_agg(want, ', ') into missing
    from (values ('txn_types_gain_loss_pair'), ('txn_types_interest_required')) as t(want)
   where not exists (
     select 1 from pg_constraint
      where conrelid = 'sri_os.txn_types'::regclass
        and conname  = t.want
        and convalidated
   );
  if missing is not null then
    raise exception 'constraint ของตารางกฎหายไปหรือยังไม่ validate: % — '
      'ไฟล์ที่ควรใส่คือ 20260918000003 และ 20261007000002', missing;
  end if;

  -- 6. ชื่อบัญชีชั่วคราวของ `20260918000005a_coa_commodity_fk_target.sql` ต้องถูกเขียนทับแล้ว
  --    (ไฟล์นั้นใส่แถว 1720 ไว้ล่วงหน้าเพื่อให้ FK ของไฟล์ seed ที่เรียงก่อนผังบัญชีผ่าน)
  --    ถ้ายังค้าง = ไฟล์ seed_rules ตัวจริงไม่ได้รัน → ผังบัญชีใน DB ถือชื่อปลอม
  select string_agg(code, ', ' order by code) into missing
    from sri_os.chart_of_accounts
   where name_th like '%[[BOOTSTRAP]]%';
  if missing is not null then
    raise exception 'ผังบัญชียังค้างชื่อชั่วคราวจากไฟล์ bootstrap ที่รหัส: % — '
      'แปลว่าไฟล์ seed_rules ตัวจริงไม่ได้รันหลัง '
      '20260918000005a_coa_commodity_fk_target.sql · apply ไฟล์ seed_rules ให้ครบก่อน', missing;
  end if;
end $$;
