-- ============================================================
-- SRI OS · เติมคอลัมน์ที่ตารางกฎฝั่งโค้ดมี แต่ฝั่ง DB ยังไม่มี
--
-- ทำอะไร: เพิ่มบัญชีกำไร/ขาดทุนจากการขาย บัญชีดอกเบี้ย บัญชีค้างรับ-ค้างจ่าย
--         และธงบัญชีปลายทางของการโอน ลงตาราง sri_os.txn_types
--
-- ทำไม: `src/lib/rules/tx-rules.ts` เพิ่มฟิลด์พวกนี้ไปแล้ว แต่ seed ฝั่ง DB ไม่มีที่เก็บ
--       ตารางกฎสองฝั่งจึงไม่ตรงกัน — รายงานฝั่ง SQL จะอ้างกฎที่ไม่ครบ
--       เช่น ไม่รู้ว่ากำไรจากการขายหลักทรัพย์เข้า 4900 ไม่ใช่ 4300
--
-- ย้อนกลับ:
--   alter table sri_os.txn_types
--     drop column gain_coa_code, drop column loss_coa_code,
--     drop column interest_coa_code, drop column accrual_coa_code,
--     drop column requires_transfer_target;
-- ============================================================

set search_path = sri_os, public;

alter table sri_os.txn_types
  add column if not exists gain_coa_code     text references chart_of_accounts(code),
  add column if not exists loss_coa_code     text references chart_of_accounts(code),
  add column if not exists interest_coa_code text references chart_of_accounts(code),
  add column if not exists accrual_coa_code  text references chart_of_accounts(code),
  add column if not exists requires_transfer_target boolean not null default false;

comment on column sri_os.txn_types.gain_coa_code is
  'บัญชีรับรู้กำไรจากการขาย — ขายอสังหาฯ กับขายหลักทรัพย์ลงคนละบรรทัด';
comment on column sri_os.txn_types.loss_coa_code is
  'บัญชีรับรู้ขาดทุนจากการขาย';
comment on column sri_os.txn_types.interest_coa_code is
  'บัญชีดอกเบี้ยของหมวดที่ต้องแยกเงินต้น/ดอกเบี้ย — ขาเข้าเป็นรายได้ ขาออกเป็นค่าใช้จ่าย';
comment on column sri_os.txn_types.accrual_coa_code is
  'บัญชีลูกหนี้/เจ้าหนี้เมื่อยังไม่ได้รับ-จ่ายเงินจริง · null = หมวดนี้ตั้งค้างไม่ได้';
comment on column sri_os.txn_types.requires_transfer_target is
  'ต้องระบุบัญชีปลายทาง (และลักษณะรายการถ้าข้ามผู้ถือ)';

-- กติกาที่ engine บังคับอยู่แล้ว ย้ำไว้ที่ DB ด้วย: หมวดที่ต้องรับรู้กำไรต้องมีทั้งสองบัญชี
alter table sri_os.txn_types
  drop constraint if exists txn_types_gain_loss_pair;
alter table sri_os.txn_types
  add constraint txn_types_gain_loss_pair
  check (requires_capital_gain = false or (gain_coa_code is not null and loss_coa_code is not null));

-- หมวดที่ต้องแยกเงินต้น/ดอกเบี้ย ต้องรู้ว่าดอกเบี้ยลงบัญชีไหน
alter table sri_os.txn_types
  drop constraint if exists txn_types_interest_required;
alter table sri_os.txn_types
  add constraint txn_types_interest_required
  check (requires_principal_split = false or interest_coa_code is not null);
