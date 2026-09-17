
> sri-os@0.1.0 sync:rules
> tsx scripts/sync-txn-types.ts

-- ============================================================
-- SRI OS · seed ตารางกฎประเภทรายการ
--
-- ไฟล์นี้ generate จาก src/lib/rules/tx-rules.ts — **ห้ามแก้ด้วยมือ**
-- แก้ที่ตารางกฎในโค้ดแล้วรัน `npm run sync:rules` ใหม่
--
-- ทำอะไร: sync 50 หมวดย่อยลงตาราง txn_types ให้ SQL อ้างกฎเดียวกับหน้าจอ
-- ย้อนกลับ: delete from sri_os.txn_types;
-- ============================================================

set search_path = sri_os, public;

insert into sri_os.txn_types (
  code, group_code, name_th, name_en, cf_group, direction,
  dr_coa_code, cr_coa_code, affects_pl, pl_line,
  requires_asset, requires_contact, requires_loan_terms,
  requires_capital_gain, requires_principal_split,
  plain_th, caution_th, sort_order
) values
  ('inc.rent', 'income', 'ค่าเช่า', 'Rental income', 'operating'::sri_os.cf_group, 1, '1100', '4200', true, 'รายได้ค่าเช่า', true, true, false, false, false, 'เงินเข้าบัญชีเพิ่มขึ้น และรายได้ค่าเช่าเพิ่มขึ้น', null, 100),
  ('inc.hire_purchase', 'income', 'ค่าเช่าซื้อ', 'Hire-purchase income', 'operating'::sri_os.cf_group, 1, '1100', '4210', true, 'รายได้ค่าเช่าซื้อ', true, true, false, false, false, 'เงินเข้าบัญชีเพิ่มขึ้น และรายได้ค่าเช่าซื้อเพิ่มขึ้น', null, 101),
  ('inc.interest_srr', 'income', 'ดอกเบี้ยรับ — ขายฝาก', 'Interest income · Redemption', 'operating'::sri_os.cf_group, 1, '1100', '4100', true, 'ดอกเบี้ยรับ - ขายฝาก', false, true, false, false, false, 'เงินเข้าบัญชีเพิ่มขึ้น และดอกเบี้ยรับขายฝากเพิ่มขึ้น — เงินต้นยังไม่ลด', 'ถ้ารับเงินต้นคืนด้วย ให้แยกบันทึกเงินต้นที่ ลงทุน (ขาย/รับคืน) › รับคืนเงินต้นขายฝาก', 102),
  ('inc.interest_mortgage', 'income', 'ดอกเบี้ยรับ — จำนอง', 'Interest income · Mortgage', 'operating'::sri_os.cf_group, 1, '1100', '4110', true, 'ดอกเบี้ยรับ - จำนอง', false, true, false, false, false, 'เงินเข้าบัญชีเพิ่มขึ้น และดอกเบี้ยรับจำนองเพิ่มขึ้น — เงินต้นยังไม่ลด', 'ถ้ารับเงินต้นคืนด้วย ให้แยกบันทึกเงินต้นที่ ลงทุน (ขาย/รับคืน) › รับคืนเงินต้นจำนอง', 103),
  ('inc.interest_loan', 'income', 'ดอกเบี้ยรับ — เงินให้กู้ยืม', 'Interest income · Loan', 'operating'::sri_os.cf_group, 1, '1100', '4120', true, 'ดอกเบี้ยรับ - เงินให้กู้ยืม', false, true, false, false, false, 'เงินเข้าบัญชีเพิ่มขึ้น และดอกเบี้ยรับเงินให้กู้ยืมเพิ่มขึ้น', null, 104),
  ('inc.dividend', 'income', 'เงินปันผลรับ', 'Dividend income', 'operating'::sri_os.cf_group, 1, '1100', '4410', true, 'เงินปันผลรับ', false, false, false, false, false, 'เงินเข้าบัญชีเพิ่มขึ้น และเงินปันผลรับเพิ่มขึ้น', null, 105),
  ('inc.key_money', 'income', 'เงินกินเปล่า', 'Key money', 'operating'::sri_os.cf_group, 1, '1100', '4310', true, 'เงินกินเปล่า', true, true, false, false, false, 'เงินเข้าบัญชีเพิ่มขึ้น และรายได้เงินกินเปล่าเพิ่มขึ้น', null, 106),
  ('inc.fee', 'income', 'ค่าคอมมิชชั่น / ค่าธรรมเนียมรับ', 'Fee & commission income', 'operating'::sri_os.cf_group, 1, '1100', '4400', true, 'ค่าคอมมิชชั่น-ค่าธรรมเนียมรับ', false, true, false, false, false, 'เงินเข้าบัญชีเพิ่มขึ้น และรายได้ค่าธรรมเนียมเพิ่มขึ้น', null, 107),
  ('inc.other', 'income', 'รายได้อื่น', 'Other income', 'operating'::sri_os.cf_group, 1, '1100', '4900', true, 'รายได้อื่น', false, false, false, false, false, 'เงินเข้าบัญชีเพิ่มขึ้น และรายได้อื่นเพิ่มขึ้น', 'ฝั่ง Corporate ห้ามใช้หมวดนี้แบบไม่ระบุ ต้องเลือกหมวดที่ตรงกว่าเสมอ', 108),
  ('exp.common', 'expense', 'ค่าส่วนกลาง', 'Common area fee', 'operating'::sri_os.cf_group, -1, '5100', '1100', true, 'ค่าส่วนกลาง', true, false, false, false, false, 'เงินออกจากบัญชี และค่าส่วนกลางเพิ่มขึ้น', null, 200),
  ('exp.utilities', 'expense', 'ค่าน้ำ-ค่าไฟ', 'Utilities', 'operating'::sri_os.cf_group, -1, '5110', '1100', true, 'ค่าน้ำ-ค่าไฟ', true, false, false, false, false, 'เงินออกจากบัญชี และค่าน้ำ-ค่าไฟเพิ่มขึ้น', null, 201),
  ('exp.repair', 'expense', 'ค่าซ่อมแซม-บำรุงรักษา', 'Repair & maintenance', 'operating'::sri_os.cf_group, -1, '5120', '1100', true, 'ค่าซ่อมแซม-บำรุงรักษา', true, false, false, false, false, 'เงินออกจากบัญชี และค่าซ่อมบำรุงเพิ่มขึ้น', 'ถ้าเป็นการปรับปรุงที่ทำให้มูลค่าทรัพย์เพิ่ม ให้ลงที่ ลงทุน (ซื้อ/ปล่อยเงิน) › ค่ารีโนเวท แทน', 202),
  ('exp.furnishing', 'expense', 'ค่าตกแต่ง-เฟอร์นิเจอร์', 'Furnishing & fit-out', 'operating'::sri_os.cf_group, -1, '5130', '1100', true, 'ค่าตกแต่ง-เฟอร์นิเจอร์', true, false, false, false, false, 'เงินออกจากบัญชี และค่าตกแต่งเพิ่มขึ้น', 'ของที่อายุใช้งานยาวและมูลค่าสูง ควรลงเป็นค่ารีโนเวท (บันทึกเป็นทุน) แทน', 203),
  ('exp.cleaning', 'expense', 'ค่าแม่บ้าน-ทำความสะอาด', 'Cleaning & housekeeping', 'operating'::sri_os.cf_group, -1, '5140', '1100', true, 'ค่าแม่บ้าน-ทำความสะอาด', true, false, false, false, false, 'เงินออกจากบัญชี และค่าแม่บ้านเพิ่มขึ้น', null, 204),
  ('exp.commission', 'expense', 'ค่าคอมมิชชั่นจ่าย', 'Commission expense', 'operating'::sri_os.cf_group, -1, '5200', '1100', true, 'ค่าคอมมิชชั่นจ่าย', false, true, false, false, false, 'เงินออกจากบัญชี และค่าคอมมิชชั่นจ่ายเพิ่มขึ้น', null, 205),
  ('exp.referral', 'expense', 'ค่านายหน้า-ค่าแนะนำ', 'Referral fee', 'operating'::sri_os.cf_group, -1, '5210', '1100', true, 'ค่านายหน้า-ค่าแนะนำ', false, true, false, false, false, 'เงินออกจากบัญชี และค่านายหน้าเพิ่มขึ้น', null, 206),
  ('exp.marketing', 'expense', 'ค่าการตลาด-โฆษณา', 'Marketing & advertising', 'operating'::sri_os.cf_group, -1, '5220', '1100', true, 'ค่าการตลาด-โฆษณา', false, false, false, false, false, 'เงินออกจากบัญชี และค่าการตลาดเพิ่มขึ้น', null, 207),
  ('exp.land_office', 'expense', 'ค่าธรรมเนียมกรมที่ดิน', 'Land office fees', 'operating'::sri_os.cf_group, -1, '5300', '1100', true, 'ค่าธรรมเนียมกรมที่ดิน', true, false, false, false, false, 'เงินออกจากบัญชี และค่าธรรมเนียมกรมที่ดินเพิ่มขึ้น', 'ค่าธรรมเนียมที่เกิดตอนซื้อทรัพย์ ควรรวมเป็นต้นทุนทรัพย์ (ลงทุน) ไม่ใช่ค่าใช้จ่ายงวดนี้', 208),
  ('exp.tax', 'expense', 'ภาษีและอากรแสตมป์', 'Taxes & stamp duty', 'operating'::sri_os.cf_group, -1, '5310', '1100', true, 'ภาษีและอากรแสตมป์', false, false, false, false, false, 'เงินออกจากบัญชี และภาษี/อากรแสตมป์เพิ่มขึ้น', null, 209),
  ('exp.legal', 'expense', 'ค่าทนาย-ค่าทำสัญญา', 'Legal & contract fees', 'operating'::sri_os.cf_group, -1, '5320', '1100', true, 'ค่าทนาย-ค่าทำสัญญา', false, false, false, false, false, 'เงินออกจากบัญชี และค่าทนาย/ค่าทำสัญญาเพิ่มขึ้น', null, 210),
  ('exp.bank_charge', 'expense', 'ค่าธรรมเนียมธนาคาร', 'Bank charges', 'operating'::sri_os.cf_group, -1, '5330', '1100', true, 'ค่าธรรมเนียมธนาคาร', false, false, false, false, false, 'เงินออกจากบัญชี และค่าธรรมเนียมธนาคารเพิ่มขึ้น', null, 211),
  ('exp.salary', 'expense', 'เงินเดือน-ค่าแรง', 'Salary & wages', 'operating'::sri_os.cf_group, -1, '5500', '1100', true, 'เงินเดือน-ค่าแรง', false, false, false, false, false, 'เงินออกจากบัญชี และเงินเดือน-ค่าแรงเพิ่มขึ้น', null, 212),
  ('exp.travel', 'expense', 'ค่าเดินทาง-น้ำมัน', 'Travel & fuel', 'operating'::sri_os.cf_group, -1, '5510', '1100', true, 'ค่าเดินทาง-น้ำมัน', false, false, false, false, false, 'เงินออกจากบัญชี และค่าเดินทางเพิ่มขึ้น', null, 213),
  ('exp.office', 'expense', 'ค่าใช้จ่ายสำนักงาน', 'Office expenses', 'operating'::sri_os.cf_group, -1, '5520', '1100', true, 'ค่าใช้จ่ายสำนักงาน', false, false, false, false, false, 'เงินออกจากบัญชี และค่าใช้จ่ายสำนักงานเพิ่มขึ้น', null, 214),
  ('exp.other', 'expense', 'ค่าใช้จ่ายอื่น', 'Other expenses', 'operating'::sri_os.cf_group, -1, '5900', '1100', true, 'ค่าใช้จ่ายอื่น', false, false, false, false, false, 'เงินออกจากบัญชี และค่าใช้จ่ายอื่นเพิ่มขึ้น', 'ฝั่ง Corporate ห้ามใช้หมวดนี้แบบไม่ระบุ ต้องเลือกหมวดที่ตรงกว่าเสมอ', 215),
  ('inv.buy_re', 'invest_buy', 'ซื้ออสังหาริมทรัพย์', 'Acquire real estate', 'investing'::sri_os.cf_group, -1, '1500', '1100', false, null, true, false, false, false, false, 'เงินออกจากบัญชี แต่ไม่ใช่ค่าใช้จ่าย — ทรัพย์ในงบดุลเพิ่มขึ้นตามต้นทุน', 'ไม่กระทบกำไรขาดทุน เป็นการเปลี่ยนรูปของสินทรัพย์เท่านั้น', 300),
  ('inv.capex', 'invest_buy', 'ค่ารีโนเวท (บันทึกเป็นทุน)', 'Renovation capitalised', 'investing'::sri_os.cf_group, -1, '1510', '1100', false, null, true, false, false, false, false, 'เงินออกจากบัญชี และต้นทุนทรัพย์เพิ่มขึ้น — ไม่ลงเป็นค่าซ่อมบำรุง', 'ซ่อมให้กลับมาใช้ได้เหมือนเดิม = ค่าใช้จ่าย · ปรับปรุงให้ดีขึ้น/อายุยาวขึ้น = ลงทุน', 301),
  ('inv.srr_out', 'invest_buy', 'ปล่อยเงินขายฝาก', 'Sale with right of redemption', 'investing'::sri_os.cf_group, -1, '1400', '1100', false, null, true, true, true, false, false, 'เงินออกจากบัญชี และเงินลงทุนขายฝาก (เงินต้น) เพิ่มขึ้น — ไม่ใช่ค่าใช้จ่าย', 'ต้องกรอกเงื่อนไขสัญญาเพื่อสร้างตารางงวดรับดอกเบี้ย (Backlog ข้อ 2)', 302),
  ('inv.mortgage_out', 'invest_buy', 'ปล่อยเงินจำนอง', 'Mortgage lending', 'investing'::sri_os.cf_group, -1, '1410', '1100', false, null, true, true, true, false, false, 'เงินออกจากบัญชี และเงินลงทุนจำนอง (เงินต้น) เพิ่มขึ้น — ไม่ใช่ค่าใช้จ่าย', 'ต้องกรอกเงื่อนไขสัญญาเพื่อสร้างตารางงวดรับดอกเบี้ย (Backlog ข้อ 2)', 303),
  ('inv.lend', 'invest_buy', 'ให้กู้ยืมออกไป', 'Loan out', 'investing'::sri_os.cf_group, -1, '1300', '1100', false, null, false, true, true, false, false, 'เงินออกจากบัญชี และลูกหนี้เงินให้กู้ยืมเพิ่มขึ้น — ไม่ใช่ค่าใช้จ่าย', 'เงินที่เราปล่อยออกไปเป็น Investing ไม่ใช่ Financing — Financing คือเรากู้เขา', 304),
  ('inv.buy_securities', 'invest_buy', 'ซื้อหลักทรัพย์ / กองทุน', 'Buy securities', 'investing'::sri_os.cf_group, -1, '1700', '1100', false, null, false, false, false, false, false, 'เงินออกจากบัญชี และเงินลงทุนในหลักทรัพย์เพิ่มขึ้นตามต้นทุน', null, 305),
  ('inv.deposit_paid', 'invest_buy', 'เงินมัดจำจ่าย', 'Deposit paid', 'operating'::sri_os.cf_group, -1, '1600', '1100', false, null, false, true, false, false, false, 'เงินออกจากบัญชี และเงินมัดจำจ่าย (สินทรัพย์) เพิ่มขึ้น — ไม่ใช่ค่าใช้จ่าย เพราะได้คืน', 'เงินมัดจำที่เราจ่ายคือสิทธิที่จะได้คืน จึงเป็นสินทรัพย์ ไม่ใช่ค่าใช้จ่าย', 306),
  ('inv.sell_re', 'invest_sell', 'ขายอสังหาริมทรัพย์', 'Dispose real estate', 'investing'::sri_os.cf_group, 1, '1100', '1500', false, null, true, false, false, true, false, 'ตัดทรัพย์ออกตามต้นทุน รับเงินเข้าบัญชี และรับรู้กำไร/ขาดทุนจากการขายใน P&L', 'กำไรยังไม่รับรู้ (unrealized) ของทรัพย์ชิ้นนี้ต้องถูกล้างออกพร้อมกัน (Backlog ข้อ 4)', 400),
  ('inv.srr_redeem', 'invest_sell', 'รับไถ่ถอนขายฝาก (เงินต้น)', 'Redemption received', 'investing'::sri_os.cf_group, 1, '1100', '1400', false, null, true, true, false, false, false, 'เงินเข้าบัญชีเพิ่มขึ้น และเงินลงทุนขายฝากลดลง — ไม่ใช่รายได้', 'ส่วนที่เป็นดอกเบี้ยให้แยกบันทึกที่ รายได้ › ดอกเบี้ยรับ — ขายฝาก', 401),
  ('inv.mortgage_redeem', 'invest_sell', 'รับไถ่ถอนจำนอง (เงินต้น)', 'Mortgage redeemed', 'investing'::sri_os.cf_group, 1, '1100', '1410', false, null, true, true, false, false, false, 'เงินเข้าบัญชีเพิ่มขึ้น และเงินลงทุนจำนองลดลง — ไม่ใช่รายได้', 'ส่วนที่เป็นดอกเบี้ยให้แยกบันทึกที่ รายได้ › ดอกเบี้ยรับ — จำนอง', 402),
  ('inv.loan_back', 'invest_sell', 'รับคืนเงินให้กู้ยืม (เงินต้น)', 'Loan principal repaid', 'investing'::sri_os.cf_group, 1, '1100', '1300', false, null, false, true, false, false, false, 'เงินเข้าบัญชีเพิ่มขึ้น และลูกหนี้เงินให้กู้ยืมลดลง — ไม่ใช่รายได้', 'ส่วนที่เป็นดอกเบี้ยให้แยกบันทึกที่ รายได้ › ดอกเบี้ยรับ — เงินให้กู้ยืม', 403),
  ('inv.sell_securities', 'invest_sell', 'ขายหลักทรัพย์ / กองทุน', 'Sell securities', 'investing'::sri_os.cf_group, 1, '1100', '1700', false, null, false, false, false, true, false, 'ตัดเงินลงทุนออกตามต้นทุน รับเงินเข้าบัญชี และรับรู้กำไร/ขาดทุนจากการขาย', null, 404),
  ('inv.deposit_returned', 'invest_sell', 'รับคืนเงินมัดจำที่จ่ายไว้', 'Deposit paid refunded', 'operating'::sri_os.cf_group, 1, '1100', '1600', false, null, false, true, false, false, false, 'เงินเข้าบัญชีเพิ่มขึ้น และเงินมัดจำจ่ายลดลง — ไม่ใช่รายได้', null, 405),
  ('fin.loan_bank', 'finance_in', 'กู้เงินธนาคาร', 'Bank borrowing', 'financing'::sri_os.cf_group, 1, '1100', '2410', false, null, false, true, true, false, false, 'เงินเข้าบัญชีเพิ่มขึ้น และหนี้สินเงินกู้ธนาคารเพิ่มขึ้น — ไม่ใช่รายได้', 'เงินเข้าบัญชีแต่ไม่ใช่รายได้ ห้ามลงหมวด รายได้ เด็ดขาด', 500),
  ('fin.loan_director', 'finance_in', 'กู้ยืมกรรมการ / คนในครอบครัว', 'Director loan', 'financing'::sri_os.cf_group, 1, '1100', '2300', false, null, false, true, true, false, false, 'เงินเข้าบัญชีเพิ่มขึ้น และหนี้สินเงินกู้ยืมกรรมการเพิ่มขึ้น — ไม่ใช่รายได้', 'เงินเข้าบัญชีแต่ไม่ใช่รายได้ ห้ามลงหมวด รายได้ เด็ดขาด', 501),
  ('fin.loan_other', 'finance_in', 'กู้ยืมอื่น', 'Other borrowing', 'financing'::sri_os.cf_group, 1, '1100', '2400', false, null, false, true, true, false, false, 'เงินเข้าบัญชีเพิ่มขึ้น และหนี้สินเงินกู้ยืมอื่นเพิ่มขึ้น — ไม่ใช่รายได้', null, 502),
  ('fin.capital', 'finance_in', 'เพิ่มทุน', 'Capital injection', 'financing'::sri_os.cf_group, 1, '1100', '3100', false, null, false, true, false, false, false, 'เงินเข้าบัญชีเพิ่มขึ้น และส่วนของเจ้าของเพิ่มขึ้น — ไม่ใช่รายได้', 'เงินทุนจากอากงต้องแยกจากเงินกู้ยืมกรรมการ ห้ามรวมเป็นก้อนเดียว', 503),
  ('fin.deposit_received', 'finance_in', 'รับเงินมัดจำจากผู้เช่า', 'Tenant deposit received', 'operating'::sri_os.cf_group, 1, '1100', '2200', false, null, true, true, false, false, false, 'เงินเข้าบัญชีเพิ่มขึ้น และหนี้สินเงินมัดจำเพิ่มขึ้น — ต้องคืนภายหลัง จึงไม่ใช่รายได้', null, 504),
  ('fin.repay_bank', 'finance_out', 'ชำระคืนเงินกู้ธนาคาร (เงินต้น)', 'Bank loan principal repaid', 'financing'::sri_os.cf_group, -1, '2410', '1100', false, null, false, true, false, false, true, 'เงินออกจากบัญชี และหนี้สินเงินกู้ธนาคารลดลง — เงินต้นไม่ใช่ค่าใช้จ่าย', 'เงินต้นไม่ใช่ค่าใช้จ่าย ต้องแยกออกจากดอกเบี้ยเสมอ (Backlog ข้อ 5)', 600),
  ('fin.repay_director', 'finance_out', 'ชำระคืนเงินกู้ยืมกรรมการ (เงินต้น)', 'Director loan repaid', 'financing'::sri_os.cf_group, -1, '2300', '1100', false, null, false, true, false, false, true, 'เงินออกจากบัญชี และหนี้สินเงินกู้ยืมกรรมการลดลง — ไม่ใช่ค่าใช้จ่าย', 'เงินต้นไม่ใช่ค่าใช้จ่าย ต้องแยกออกจากดอกเบี้ยเสมอ (Backlog ข้อ 5)', 601),
  ('fin.interest_paid', 'finance_out', 'จ่ายดอกเบี้ย', 'Interest paid', 'financing'::sri_os.cf_group, -1, '5400', '1100', true, 'ดอกเบี้ยจ่าย', false, true, false, false, false, 'เงินออกจากบัญชี และดอกเบี้ยจ่ายเพิ่มขึ้น — หนี้สินเงินต้นไม่เปลี่ยน', null, 602),
  ('fin.drawings', 'finance_out', 'ถอนทุน / จ่ายปันผล', 'Drawings', 'financing'::sri_os.cf_group, -1, '3200', '1100', false, null, false, true, false, false, false, 'เงินออกจากบัญชี และส่วนของเจ้าของลดลง — ไม่ใช่ค่าใช้จ่ายใน P&L', 'เงินปันผลจ่ายลดส่วนของเจ้าของ ไม่ใช่ค่าใช้จ่าย จึงไม่กระทบกำไรสุทธิ', 603),
  ('fin.deposit_refund', 'finance_out', 'คืนเงินมัดจำผู้เช่า', 'Tenant deposit refunded', 'operating'::sri_os.cf_group, -1, '2200', '1100', false, null, false, true, false, false, false, 'เงินออกจากบัญชี และหนี้สินเงินมัดจำลดลง — ไม่ใช่ค่าใช้จ่าย', null, 604),
  ('fin.pay_payable', 'finance_out', 'จ่ายเจ้าหนี้ค้างจ่าย', 'Pay trade payable', 'operating'::sri_os.cf_group, -1, '2100', '1100', false, null, false, true, false, false, false, 'เงินออกจากบัญชี และเจ้าหนี้ค้างจ่ายลดลง — ค่าใช้จ่ายรับรู้ไปแล้วตอนตั้งหนี้', 'ถ้ายังไม่เคยตั้งหนี้ไว้ ให้ลงเป็นค่าใช้จ่ายตรงๆ แทน ไม่งั้นค่าใช้จ่ายจะหาย', 605),
  ('trf.internal', 'transfer', 'โอนระหว่างบัญชีในกองกลาง', 'Internal transfer', 'transfer'::sri_os.cf_group, 0, '1100', '1100', false, null, false, false, false, false, false, 'เงินย้ายจากบัญชีหนึ่งไปอีกบัญชี ยอดรวมกองกลางไม่เปลี่ยน', 'ไม่นับในงบกระแสเงินสด และตัดออกจากงบรวม จึงไม่กระทบกำไรขาดทุนและ NAV', 700)
on conflict (code) do update set
  group_code = excluded.group_code,
  name_th    = excluded.name_th,
  name_en    = excluded.name_en,
  cf_group   = excluded.cf_group,
  direction  = excluded.direction,
  dr_coa_code = excluded.dr_coa_code,
  cr_coa_code = excluded.cr_coa_code,
  affects_pl = excluded.affects_pl,
  pl_line    = excluded.pl_line,
  requires_asset = excluded.requires_asset,
  requires_contact = excluded.requires_contact,
  requires_loan_terms = excluded.requires_loan_terms,
  requires_capital_gain = excluded.requires_capital_gain,
  requires_principal_split = excluded.requires_principal_split,
  plain_th   = excluded.plain_th,
  caution_th = excluded.caution_th,
  sort_order = excluded.sort_order;

-- ลบหมวดที่ถูกเอาออกจากตารางกฎแล้ว (แต่กันไม่ให้ลบถ้ามีรายการอ้างอยู่)
delete from sri_os.txn_types
 where code not in ('inc.rent', 'inc.hire_purchase', 'inc.interest_srr', 'inc.interest_mortgage', 'inc.interest_loan', 'inc.dividend', 'inc.key_money', 'inc.fee', 'inc.other', 'exp.common', 'exp.utilities', 'exp.repair', 'exp.furnishing', 'exp.cleaning', 'exp.commission', 'exp.referral', 'exp.marketing', 'exp.land_office', 'exp.tax', 'exp.legal', 'exp.bank_charge', 'exp.salary', 'exp.travel', 'exp.office', 'exp.other', 'inv.buy_re', 'inv.capex', 'inv.srr_out', 'inv.mortgage_out', 'inv.lend', 'inv.buy_securities', 'inv.deposit_paid', 'inv.sell_re', 'inv.srr_redeem', 'inv.mortgage_redeem', 'inv.loan_back', 'inv.sell_securities', 'inv.deposit_returned', 'fin.loan_bank', 'fin.loan_director', 'fin.loan_other', 'fin.capital', 'fin.deposit_received', 'fin.repay_bank', 'fin.repay_director', 'fin.interest_paid', 'fin.drawings', 'fin.deposit_refund', 'fin.pay_payable', 'trf.internal')
   and not exists (select 1 from sri_os.transactions x where x.txn_type_code = txn_types.code)
   and not exists (select 1 from sri_os.draft_entries d where d.txn_type_code = txn_types.code);
