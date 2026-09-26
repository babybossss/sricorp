-- ============================================================
-- SRI OS · เพิ่ม 3300 กำไรสะสม และ 5910 ขาดทุนจากการขายทรัพย์
--
-- ทำอะไร: insert สองบัญชีเข้า sri_os.chart_of_accounts
--
-- ทำไม:
--   3300 — ไม่มีบัญชีนี้แล้วตั้งยอดตั้งต้นไม่ได้ กำไรที่สะสมมาก่อนวันตัดยอด
--          ต้องไปกองรวมกับ 3100 ทุนตั้งต้น ซึ่งอ่านไม่ออกว่าเงินส่วนไหนใส่เข้ามา
--          ส่วนไหนหามาได้
--   5910 — `txn_types.loss_coa_code` ชี้มาที่บัญชีนี้ (ขายอสังหาฯ และขายหลักทรัพย์)
--          เดิมชี้ไป 5900 "ค่าใช้จ่ายอื่น" ทำให้ขาดทุนจากการขายปนกับค่าใช้จ่ายจร
--
-- **ต้องรันก่อน seed txn_types รอบใหม่** เพราะ loss_coa_code เป็น FK เข้าตารางนี้
-- ถ้า seed ก่อน จะติด foreign key violation และขายขาดทุนจะ post ไม่ได้เลย
--
-- ย้อนกลับ:
--   ชี้ loss_coa_code กลับไป '5900' ก่อน แล้วจึง
--   delete from sri_os.chart_of_accounts where code in ('3300','5910');
-- ============================================================

set search_path = sri_os, public;

insert into sri_os.chart_of_accounts (code, name_th, name_en, type, sort_order) values
  ('3300', 'กำไรสะสม',                'Retained earnings',        'equity',  330),
  ('5910', 'ขาดทุนจากการขายทรัพย์',   'Loss on sale of property', 'expense', 591)
on conflict (code) do update set
  name_th    = excluded.name_th,
  name_en    = excluded.name_en,
  type       = excluded.type,
  sort_order = excluded.sort_order;

comment on column sri_os.chart_of_accounts.code is
  'รหัสบัญชี 4 หลัก — 1xxx สินทรัพย์ · 2xxx หนี้สิน · 3xxx ส่วนของเจ้าของ · 4xxx รายได้ · 5xxx ค่าใช้จ่าย';
