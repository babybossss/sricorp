-- ============================================================
-- SRI OS · เพิ่ม 1220 ลูกหนี้อื่น (รอรับเงิน)
--
-- ทำอะไร: insert บัญชี 1220 เข้า sri_os.chart_of_accounts (idempotent · upsert)
--
-- ทำไม (D-069): D-068 บังคับว่า "ยังไม่ยืนยันเงินเข้า-ออก = ไม่มีบรรทัดเงินสดเลย"
--   ยอดต้องไปพักที่ลูกหนี้/เจ้าหนี้ · 1200 ลูกหนี้ค่าเช่า และ 1210 ลูกหนี้ดอกเบี้ย
--   ครอบแค่รายได้จากการดำเนินงาน · เงินที่ยังไม่เข้าจากการขายทรัพย์ รับไถ่ถอน
--   เงินกู้ที่อนุมัติแล้ว ฯลฯ ไม่มีบัญชีพักของตัวเอง → หมวดพวกนั้นตกไปเส้นทางเดิม
--   คือลงเงินสดตรง ซึ่งคือการเปิดกฎครึ่งเดียว (อันตรายกว่าไม่เปิด)
--
--   ไม่ตั้งบัญชี "เงินระหว่างทาง" แยก — ทุกเคสเป็นลูกหนี้หรือเจ้าหนี้ได้หมด
--   และเป็นการลงบัญชีที่ตรงความจริงกว่า (ขายทองแล้วยังไม่ได้เงิน = คนซื้อเป็นหนี้เรา)
--
-- **ต้องรันก่อน seed txn_types รอบใหม่** เพราะ txn_types.accrual_coa_code
-- เป็น FK เข้าตารางนี้ · seed ก่อนจะติด foreign key violation และ 29 หมวด
-- ที่ชี้มาที่ 1220/2100 จะ sync ไม่ผ่านทั้งชุด
--
-- ย้อนกลับ:
--   update sri_os.txn_types set accrual_coa_code = null where accrual_coa_code = '1220';
--   delete from sri_os.chart_of_accounts where code = '1220';
--   (ลบไม่ได้ถ้ามี journal_lines อ้างอยู่แล้ว — กรณีนั้นให้ปล่อยบัญชีไว้
--    เพราะยอดที่ลงไปแล้วต้องมีที่อยู่ ห้ามทำให้งบดุลไม่สมดุล)
-- ============================================================

set search_path = sri_os, public;

insert into sri_os.chart_of_accounts (code, name_th, name_en, type, sort_order) values
  ('1220', 'ลูกหนี้อื่น (รอรับเงิน)', 'Other receivable', 'asset', 122)
on conflict (code) do update set
  name_th    = excluded.name_th,
  name_en    = excluded.name_en,
  type       = excluded.type,
  sort_order = excluded.sort_order;

comment on column sri_os.chart_of_accounts.code is
  'รหัสบัญชี 4 หลัก — 1xxx สินทรัพย์ · 2xxx หนี้สิน · 3xxx ส่วนของเจ้าของ · 4xxx รายได้ · 5xxx ค่าใช้จ่าย';
