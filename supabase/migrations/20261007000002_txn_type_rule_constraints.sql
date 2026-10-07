-- ============================================================
-- SRI OS · กู้ constraint ของตารางกฎที่หายไปจาก drift (ไม่ใช่ของใหม่)
--
-- ทำไม: `20260918000003_txn_type_rule_columns.sql` เพิ่มคอลัมน์ได้ แต่ **ล้มตอน add constraint**
--   เมื่อ replay จาก DB เปล่า เพราะตอนนั้น seed ที่เติม gain/loss/interest ยังไม่ได้รัน
--   (ลำดับ seed ของ project จริงต่างจากลำดับชื่อไฟล์) · psql autocommit ทีละคำสั่ง
--   → ได้คอลัมน์ครบแต่ **ไม่มี constraint** และ harness ก็ "SKIP" ไฟล์นั้นเงียบๆ
--   ผลคือเทสต์ทั้งชุดรันบน schema ที่ไม่เหมือนของจริงอีกจุดหนึ่ง
--   ห้ามแก้ไฟล์ 20260918000003 (apply แล้ว) → กู้ด้วยไฟล์ใหม่ที่รันหลัง seed ทุกตัว
--
-- บน project จริง constraint สองตัวนี้อาจมีอยู่แล้ว → drop if exists ก่อน add ทำให้ผลเท่ากัน
-- ถ้าข้อมูลขัดกับกฎ **ให้ล้มพร้อมบอกว่าแถวไหน** ไม่ใช่ปล่อยผ่านเงียบๆ
-- (ตารางกฎที่ไม่ครบ = engine กับ DB ถือกฎไม่เหมือนกัน ซึ่งเป็นเหตุผลที่ไฟล์ 000003 มีมา)
--
-- ย้อนกลับ:
--   -- alter table sri_os.txn_types drop constraint if exists txn_types_gain_loss_pair;
--   -- alter table sri_os.txn_types drop constraint if exists txn_types_interest_required;
--
-- idempotent: drop if exists → add · do block ตรวจข้อมูลก่อน
-- ============================================================

set search_path = sri_os, public;

do $$
declare v text;
begin
  select string_agg(code, ', ') into v from txn_types
   where requires_capital_gain and (gain_coa_code is null or loss_coa_code is null);
  if v is not null then
    raise exception 'หมวดที่ต้องรับรู้กำไรแต่ยังไม่มีบัญชีกำไร/ขาดทุน: % · เติมด้วย npm run sync:rules ก่อนรัน migration นี้', v;
  end if;

  select string_agg(code, ', ') into v from txn_types
   where requires_principal_split and interest_coa_code is null;
  if v is not null then
    raise exception 'หมวดที่ต้องแยกเงินต้น/ดอกเบี้ยแต่ยังไม่มีบัญชีดอกเบี้ย: % · เติมด้วย npm run sync:rules ก่อนรัน migration นี้', v;
  end if;
end $$;

alter table txn_types drop constraint if exists txn_types_gain_loss_pair;
alter table txn_types
  add constraint txn_types_gain_loss_pair
  check (requires_capital_gain = false or (gain_coa_code is not null and loss_coa_code is not null));

alter table txn_types drop constraint if exists txn_types_interest_required;
alter table txn_types
  add constraint txn_types_interest_required
  check (requires_principal_split = false or interest_coa_code is not null);
