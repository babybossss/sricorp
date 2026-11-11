-- ============================================================
-- SRI OS · seed ตารางกฎทั้งชุด (ผังบัญชี · ประเภทรายการ · คู่บัญชีระหว่างกัน)
--
-- ไฟล์นี้ generate จาก src/lib/rules/{coa,tx-rules,intercompany}.ts — **ห้ามแก้ด้วยมือ**
-- แก้ที่ตารางกฎในโค้ดแล้วรัน `npm run sync:rules` ใหม่
-- ตรวจว่าตรงกันด้วย `npm run check:sync` (พังถ้าไม่ตรง)
--
-- ทำอะไร (เรียงตามลำดับที่จำเป็น เพราะ FK):
--   1 · 53 รหัสลงตาราง chart_of_accounts
--   2 · 59 หมวดย่อยลงตาราง txn_types (ในนั้น 23 หมวดตั้งค้างรับ-ค้างจ่ายได้)
--   3 · 4 คู่บัญชีระหว่างกันลงฟังก์ชัน fn_intercompany_pairs()
--
-- ผังบัญชีต้องมาก่อน txn_types เสมอ — dr/cr/gain/loss/interest/accrual_coa_code
-- เป็น FK เข้า chart_of_accounts · ถ้าบัญชีที่กฎอ้างยังไม่มี ทั้งชุดจะ rollback
-- และต้องรันหลัง migration ที่เพิ่มคอลัมน์ can_accrue และ cash_direction ด้วย
--   (cash_direction อยู่ใน 20261009000003_txn_types_cash_direction.sql ซึ่งชื่อไฟล์
--    เรียงมาก่อนไฟล์นี้เสมอ เพราะไฟล์นี้ตั้งชื่อจากเวลาที่รัน sync:rules)
--
-- **ไม่ลบรหัสบัญชีที่หายไปจาก coa.ts** — บัญชีที่มีรายการอ้างอยู่ลบไม่ได้
-- และการลบเงียบๆ จะทำให้ยอดในรายงานเก่าหาย → รายงานเป็น warning ให้คนตัดสิน
--
-- ย้อนกลับ: ทั้งไฟล์เป็น upsert / create or replace → replay ซ้ำได้
--   ถอน txn_types ทั้งชุด: delete from sri_os.txn_types;
--     (ลบไม่ได้ถ้ามี transactions/draft_entries อ้างอยู่)
--   คืน fn_intercompany_pairs() รุ่นก่อน: รัน migration ก่อนหน้าที่ define มันซ้ำ
--   ผังบัญชี: ไฟล์นี้ไม่ลบอะไร จึงไม่มีอะไรต้องกู้
-- ============================================================

set search_path = sri_os, public;

-- ------------------------------------------------------------
-- 1 · ผังบัญชี (src/lib/rules/coa.ts)
-- ------------------------------------------------------------
insert into sri_os.chart_of_accounts (code, name_th, name_en, type, sort_order) values
  ('1100', 'เงินสดและเงินฝากธนาคาร', 'Cash & bank', 'asset', 110),
  ('1200', 'ลูกหนี้ค่าเช่า', 'Rent receivable', 'asset', 120),
  ('1210', 'ลูกหนี้ดอกเบี้ย', 'Interest receivable', 'asset', 121),
  ('1220', 'ลูกหนี้อื่น (รอรับเงิน)', 'Other receivable', 'asset', 122),
  ('1290', 'ค่าเผื่อหนี้สงสัยจะสูญ', 'Allowance for doubtful accounts', 'asset', 129),
  ('1300', 'เงินให้กู้ยืม - เงินต้น', 'Loan principal receivable', 'asset', 130),
  ('1400', 'เงินลงทุนขายฝาก - เงินต้น', 'Redemption principal', 'asset', 140),
  ('1410', 'เงินลงทุนจำนอง - เงินต้น', 'Mortgage principal', 'asset', 141),
  ('1500', 'อสังหาริมทรัพย์เพื่อการลงทุน', 'Investment property', 'asset', 150),
  ('1510', 'ค่ารีโนเวท (บันทึกเป็นทุน)', 'Renovation capitalised', 'asset', 151),
  ('1600', 'เงินมัดจำจ่าย', 'Deposits paid', 'asset', 160),
  ('1700', 'เงินลงทุนในหลักทรัพย์', 'Investment in securities', 'asset', 170),
  ('1720', 'เงินลงทุนในทองคำและสินทรัพย์ทางเลือก', 'Gold & alternative assets', 'asset', 172),
  ('1310', 'ลูกหนี้ระหว่างกัน (ในกองกลาง)', 'Intercompany receivable', 'asset', 131),
  ('1710', 'เงินลงทุนในบริษัทในเครือ', 'Investment in related company', 'asset', 171),
  ('2100', 'เจ้าหนี้การค้า-เจ้าหนี้อื่น', 'Trade & other payables', 'liability', 210),
  ('2200', 'เงินมัดจำรับจากผู้เช่า', 'Tenant deposits received', 'liability', 220),
  ('2300', 'เงินกู้ยืมกรรมการ', 'Director loan', 'liability', 230),
  ('2400', 'เงินกู้ยืมอื่น', 'Other loans', 'liability', 240),
  ('2410', 'เงินกู้ธนาคาร', 'Bank borrowing', 'liability', 241),
  ('2310', 'เจ้าหนี้ระหว่างกัน (ในกองกลาง)', 'Intercompany payable', 'liability', 231),
  ('3100', 'ทุนตั้งต้น', 'Paid-in capital', 'equity', 310),
  ('3200', 'เงินถอนของเจ้าของ', 'Drawings', 'equity', 320),
  ('3300', 'กำไรสะสม', 'Retained earnings', 'equity', 330),
  ('4100', 'ดอกเบี้ยรับ - ขายฝาก', 'Interest income - Redemption', 'income', 410),
  ('4110', 'ดอกเบี้ยรับ - จำนอง', 'Interest income - Mortgage', 'income', 411),
  ('4120', 'ดอกเบี้ยรับ - เงินให้กู้ยืม', 'Interest income - Loan', 'income', 412),
  ('4200', 'รายได้ค่าเช่า', 'Rental income', 'income', 420),
  ('4210', 'รายได้ค่าเช่าซื้อ', 'Hire-purchase income', 'income', 421),
  ('4300', 'กำไรจากการขายทรัพย์', 'Gain on sale of property', 'income', 430),
  ('4310', 'เงินกินเปล่า', 'Key money', 'income', 431),
  ('4400', 'ค่าคอมมิชชั่น-ค่าธรรมเนียมรับ', 'Fee & commission income', 'income', 440),
  ('4900', 'รายได้อื่น', 'Other income', 'income', 490),
  ('4410', 'เงินปันผลรับ', 'Dividend income', 'income', 441),
  ('5100', 'ค่าส่วนกลาง', 'Common area fee', 'expense', 510),
  ('5110', 'ค่าน้ำ-ค่าไฟ', 'Utilities', 'expense', 511),
  ('5120', 'ค่าซ่อมแซม-บำรุงรักษา', 'Repair & maintenance', 'expense', 512),
  ('5130', 'ค่าตกแต่ง-เฟอร์นิเจอร์', 'Furnishing & fit-out', 'expense', 513),
  ('5140', 'ค่าแม่บ้าน-ทำความสะอาด', 'Cleaning & housekeeping', 'expense', 514),
  ('5200', 'ค่าคอมมิชชั่นจ่าย', 'Commission expense', 'expense', 520),
  ('5210', 'ค่านายหน้า-ค่าแนะนำ', 'Referral fee', 'expense', 521),
  ('5220', 'ค่าการตลาด-โฆษณา', 'Marketing & advertising', 'expense', 522),
  ('5300', 'ค่าธรรมเนียมกรมที่ดิน', 'Land office fees', 'expense', 530),
  ('5310', 'ภาษีและอากรแสตมป์', 'Taxes & stamp duty', 'expense', 531),
  ('5320', 'ค่าทนาย-ค่าทำสัญญา', 'Legal & contract fees', 'expense', 532),
  ('5330', 'ค่าธรรมเนียมธนาคาร', 'Bank charges', 'expense', 533),
  ('5400', 'ดอกเบี้ยจ่าย', 'Interest expense', 'expense', 540),
  ('5500', 'เงินเดือน-ค่าแรง', 'Salary & wages', 'expense', 550),
  ('5510', 'ค่าเดินทาง-น้ำมัน', 'Travel & fuel', 'expense', 551),
  ('5520', 'ค่าใช้จ่ายสำนักงาน', 'Office expenses', 'expense', 552),
  ('5900', 'ค่าใช้จ่ายอื่น', 'Other expenses', 'expense', 590),
  ('5910', 'ขาดทุนจากการขายทรัพย์', 'Loss on sale of property', 'expense', 591),
  ('5920', 'หนี้สงสัยจะสูญ', 'Doubtful debt expense', 'expense', 592)
on conflict (code) do update set
  name_th = excluded.name_th,
  name_en = excluded.name_en,
  type    = excluded.type;
  -- sort_order ไม่อยู่ในนี้โดยตั้งใจ (ดูคอมเมนต์ในสคริปต์ที่ generate ไฟล์นี้)

do $do$
declare v text;
begin
  select string_agg(c.code, ', ' order by c.code) into v
    from sri_os.chart_of_accounts c
   where c.code <> all (array['1100', '1200', '1210', '1220', '1290', '1300', '1400', '1410', '1500', '1510', '1600', '1700', '1720', '1310', '1710', '2100', '2200', '2300', '2400', '2410', '2310', '3100', '3200', '3300', '4100', '4110', '4120', '4200', '4210', '4300', '4310', '4400', '4900', '4410', '5100', '5110', '5120', '5130', '5140', '5200', '5210', '5220', '5300', '5310', '5320', '5330', '5400', '5500', '5510', '5520', '5900', '5910', '5920']);
  if v is not null then
    raise warning 'ผังบัญชีใน DB มีรหัสที่ไม่อยู่ใน src/lib/rules/coa.ts: % — ไฟล์นี้ไม่ลบให้ (อาจมีรายการอ้างอยู่) ให้คนตัดสินว่าจะถอนหรือเพิ่มกลับในโค้ด', v;
  end if;
end $do$;

-- ------------------------------------------------------------
-- 2 · ประเภทรายการ (src/lib/rules/tx-rules.ts)
-- ------------------------------------------------------------
insert into sri_os.txn_types (
  code, group_code, name_th, name_en, cf_group, direction, cash_direction,
  dr_coa_code, cr_coa_code, affects_pl, pl_line,
  requires_asset, requires_contact, requires_loan_terms,
  requires_capital_gain, requires_principal_split, requires_transfer_target,
  gain_coa_code, loss_coa_code, interest_coa_code, accrual_coa_code, can_accrue,
  plain_th, caution_th, sort_order
) values
  ('inc.rent', 'income', 'ค่าเช่า', 'Rental income', 'operating'::sri_os.cf_group, 1, 'in', '1100', '4200', true, 'รายได้ค่าเช่า', true, true, false, false, false, false, null, null, null, '1200', true, 'เงินเข้าบัญชีเพิ่มขึ้น และรายได้ค่าเช่าเพิ่มขึ้น', null, 100),
  ('inc.hire_purchase', 'income', 'ค่าเช่าซื้อ', 'Hire-purchase income', 'operating'::sri_os.cf_group, 1, 'in', '1100', '4210', true, 'รายได้ค่าเช่าซื้อ', true, true, false, false, false, false, null, null, null, '1200', true, 'เงินเข้าบัญชีเพิ่มขึ้น และรายได้ค่าเช่าซื้อเพิ่มขึ้น', null, 101),
  ('inc.interest_srr', 'income', 'ดอกเบี้ยรับ — ขายฝาก', 'Interest income · Redemption', 'operating'::sri_os.cf_group, 1, 'in', '1100', '4100', true, 'ดอกเบี้ยรับ - ขายฝาก', false, true, false, false, false, false, null, null, null, '1210', true, 'เงินเข้าบัญชีเพิ่มขึ้น และดอกเบี้ยรับขายฝากเพิ่มขึ้น — เงินต้นยังไม่ลด', 'ถ้ารับเงินต้นคืนด้วย ให้แยกบันทึกเงินต้นที่ ลงทุน (ขาย/รับคืน) › รับคืนเงินต้นขายฝาก', 102),
  ('inc.interest_mortgage', 'income', 'ดอกเบี้ยรับ — จำนอง', 'Interest income · Mortgage', 'operating'::sri_os.cf_group, 1, 'in', '1100', '4110', true, 'ดอกเบี้ยรับ - จำนอง', false, true, false, false, false, false, null, null, null, '1210', true, 'เงินเข้าบัญชีเพิ่มขึ้น และดอกเบี้ยรับจำนองเพิ่มขึ้น — เงินต้นยังไม่ลด', 'ถ้ารับเงินต้นคืนด้วย ให้แยกบันทึกเงินต้นที่ ลงทุน (ขาย/รับคืน) › รับคืนเงินต้นจำนอง', 103),
  ('inc.interest_loan', 'income', 'ดอกเบี้ยรับ — เงินให้กู้ยืม', 'Interest income · Loan', 'operating'::sri_os.cf_group, 1, 'in', '1100', '4120', true, 'ดอกเบี้ยรับ - เงินให้กู้ยืม', false, true, false, false, false, false, null, null, null, '1210', true, 'เงินเข้าบัญชีเพิ่มขึ้น และดอกเบี้ยรับเงินให้กู้ยืมเพิ่มขึ้น', null, 104),
  ('inc.dividend', 'income', 'เงินปันผลรับ', 'Dividend income', 'operating'::sri_os.cf_group, 1, 'in', '1100', '4410', true, 'เงินปันผลรับ', false, false, false, false, false, false, null, null, null, '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และเงินปันผลรับเพิ่มขึ้น', null, 105),
  ('inc.key_money', 'income', 'เงินกินเปล่า', 'Key money', 'operating'::sri_os.cf_group, 1, 'in', '1100', '4310', true, 'เงินกินเปล่า', true, true, false, false, false, false, null, null, null, '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และรายได้เงินกินเปล่าเพิ่มขึ้น', null, 106),
  ('inc.fee', 'income', 'ค่าคอมมิชชั่น / ค่าธรรมเนียมรับ', 'Fee & commission income', 'operating'::sri_os.cf_group, 1, 'in', '1100', '4400', true, 'ค่าคอมมิชชั่น-ค่าธรรมเนียมรับ', false, true, false, false, false, false, null, null, null, '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และรายได้ค่าธรรมเนียมเพิ่มขึ้น', null, 107),
  ('inc.other', 'income', 'รายได้อื่น', 'Other income', 'operating'::sri_os.cf_group, 1, 'in', '1100', '4900', true, 'รายได้อื่น', false, false, false, false, false, false, null, null, null, '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และรายได้อื่นเพิ่มขึ้น', 'ฝั่ง Corporate ห้ามใช้หมวดนี้แบบไม่ระบุ ต้องเลือกหมวดที่ตรงกว่าเสมอ', 108),
  ('exp.common', 'expense', 'ค่าส่วนกลาง', 'Common area fee', 'operating'::sri_os.cf_group, -1, 'out', '5100', '1100', true, 'ค่าส่วนกลาง', true, false, false, false, false, false, null, null, null, '2100', true, 'เงินออกจากบัญชี และค่าส่วนกลางเพิ่มขึ้น', null, 200),
  ('exp.utilities', 'expense', 'ค่าน้ำ-ค่าไฟ', 'Utilities', 'operating'::sri_os.cf_group, -1, 'out', '5110', '1100', true, 'ค่าน้ำ-ค่าไฟ', true, false, false, false, false, false, null, null, null, '2100', true, 'เงินออกจากบัญชี และค่าน้ำ-ค่าไฟเพิ่มขึ้น', null, 201),
  ('exp.repair', 'expense', 'ค่าซ่อมแซม-บำรุงรักษา', 'Repair & maintenance', 'operating'::sri_os.cf_group, -1, 'out', '5120', '1100', true, 'ค่าซ่อมแซม-บำรุงรักษา', true, false, false, false, false, false, null, null, null, '2100', true, 'เงินออกจากบัญชี และค่าซ่อมบำรุงเพิ่มขึ้น', 'ถ้าเป็นการปรับปรุงที่ทำให้มูลค่าทรัพย์เพิ่ม ให้ลงที่ ลงทุน (ซื้อ/ปล่อยเงิน) › ค่ารีโนเวท แทน', 202),
  ('exp.furnishing', 'expense', 'ค่าตกแต่ง-เฟอร์นิเจอร์', 'Furnishing & fit-out', 'operating'::sri_os.cf_group, -1, 'out', '5130', '1100', true, 'ค่าตกแต่ง-เฟอร์นิเจอร์', true, false, false, false, false, false, null, null, null, '2100', true, 'เงินออกจากบัญชี และค่าตกแต่งเพิ่มขึ้น', 'ของที่อายุใช้งานยาวและมูลค่าสูง ควรลงเป็นค่ารีโนเวท (บันทึกเป็นทุน) แทน', 203),
  ('exp.cleaning', 'expense', 'ค่าแม่บ้าน-ทำความสะอาด', 'Cleaning & housekeeping', 'operating'::sri_os.cf_group, -1, 'out', '5140', '1100', true, 'ค่าแม่บ้าน-ทำความสะอาด', true, false, false, false, false, false, null, null, null, '2100', true, 'เงินออกจากบัญชี และค่าแม่บ้านเพิ่มขึ้น', null, 204),
  ('exp.commission', 'expense', 'ค่าคอมมิชชั่นจ่าย', 'Commission expense', 'operating'::sri_os.cf_group, -1, 'out', '5200', '1100', true, 'ค่าคอมมิชชั่นจ่าย', false, true, false, false, false, false, null, null, null, '2100', true, 'เงินออกจากบัญชี และค่าคอมมิชชั่นจ่ายเพิ่มขึ้น', null, 205),
  ('exp.referral', 'expense', 'ค่านายหน้า-ค่าแนะนำ', 'Referral fee', 'operating'::sri_os.cf_group, -1, 'out', '5210', '1100', true, 'ค่านายหน้า-ค่าแนะนำ', false, true, false, false, false, false, null, null, null, '2100', true, 'เงินออกจากบัญชี และค่านายหน้าเพิ่มขึ้น', null, 206),
  ('exp.marketing', 'expense', 'ค่าการตลาด-โฆษณา', 'Marketing & advertising', 'operating'::sri_os.cf_group, -1, 'out', '5220', '1100', true, 'ค่าการตลาด-โฆษณา', false, false, false, false, false, false, null, null, null, '2100', true, 'เงินออกจากบัญชี และค่าการตลาดเพิ่มขึ้น', null, 207),
  ('exp.land_office', 'expense', 'ค่าธรรมเนียมกรมที่ดิน', 'Land office fees', 'operating'::sri_os.cf_group, -1, 'out', '5300', '1100', true, 'ค่าธรรมเนียมกรมที่ดิน', true, false, false, false, false, false, null, null, null, '2100', true, 'เงินออกจากบัญชี และค่าธรรมเนียมกรมที่ดินเพิ่มขึ้น', 'ค่าธรรมเนียมที่เกิดตอนซื้อทรัพย์ ควรรวมเป็นต้นทุนทรัพย์ (ลงทุน) ไม่ใช่ค่าใช้จ่ายงวดนี้', 208),
  ('exp.tax', 'expense', 'ภาษีและอากรแสตมป์', 'Taxes & stamp duty', 'operating'::sri_os.cf_group, -1, 'out', '5310', '1100', true, 'ภาษีและอากรแสตมป์', false, false, false, false, false, false, null, null, null, '2100', true, 'เงินออกจากบัญชี และภาษี/อากรแสตมป์เพิ่มขึ้น', null, 209),
  ('exp.legal', 'expense', 'ค่าทนาย-ค่าทำสัญญา', 'Legal & contract fees', 'operating'::sri_os.cf_group, -1, 'out', '5320', '1100', true, 'ค่าทนาย-ค่าทำสัญญา', false, false, false, false, false, false, null, null, null, '2100', true, 'เงินออกจากบัญชี และค่าทนาย/ค่าทำสัญญาเพิ่มขึ้น', null, 210),
  ('exp.bank_charge', 'expense', 'ค่าธรรมเนียมธนาคาร', 'Bank charges', 'operating'::sri_os.cf_group, -1, 'out', '5330', '1100', true, 'ค่าธรรมเนียมธนาคาร', false, false, false, false, false, false, null, null, null, '2100', true, 'เงินออกจากบัญชี และค่าธรรมเนียมธนาคารเพิ่มขึ้น', null, 211),
  ('exp.salary', 'expense', 'เงินเดือน-ค่าแรง', 'Salary & wages', 'operating'::sri_os.cf_group, -1, 'out', '5500', '1100', true, 'เงินเดือน-ค่าแรง', false, false, false, false, false, false, null, null, null, '2100', true, 'เงินออกจากบัญชี และเงินเดือน-ค่าแรงเพิ่มขึ้น', null, 212),
  ('exp.travel', 'expense', 'ค่าเดินทาง-น้ำมัน', 'Travel & fuel', 'operating'::sri_os.cf_group, -1, 'out', '5510', '1100', true, 'ค่าเดินทาง-น้ำมัน', false, false, false, false, false, false, null, null, null, '2100', true, 'เงินออกจากบัญชี และค่าเดินทางเพิ่มขึ้น', null, 213),
  ('exp.office', 'expense', 'ค่าใช้จ่ายสำนักงาน', 'Office expenses', 'operating'::sri_os.cf_group, -1, 'out', '5520', '1100', true, 'ค่าใช้จ่ายสำนักงาน', false, false, false, false, false, false, null, null, null, '2100', true, 'เงินออกจากบัญชี และค่าใช้จ่ายสำนักงานเพิ่มขึ้น', null, 214),
  ('exp.other', 'expense', 'ค่าใช้จ่ายอื่น', 'Other expenses', 'operating'::sri_os.cf_group, -1, 'out', '5900', '1100', true, 'ค่าใช้จ่ายอื่น', false, false, false, false, false, false, null, null, null, '2100', true, 'เงินออกจากบัญชี และค่าใช้จ่ายอื่นเพิ่มขึ้น', 'ฝั่ง Corporate ห้ามใช้หมวดนี้แบบไม่ระบุ ต้องเลือกหมวดที่ตรงกว่าเสมอ', 215),
  ('inv.buy_re', 'invest_buy', 'ซื้ออสังหาริมทรัพย์', 'Acquire real estate', 'investing'::sri_os.cf_group, -1, 'out', '1500', '1100', false, null, true, false, false, false, false, false, null, null, null, '2100', false, 'เงินออกจากบัญชี แต่ไม่ใช่ค่าใช้จ่าย — ทรัพย์ในงบดุลเพิ่มขึ้นตามต้นทุน', 'ไม่กระทบกำไรขาดทุน เป็นการเปลี่ยนรูปของสินทรัพย์เท่านั้น', 300),
  ('inv.capex', 'invest_buy', 'ค่ารีโนเวท (บันทึกเป็นทุน)', 'Renovation capitalised', 'investing'::sri_os.cf_group, -1, 'out', '1510', '1100', false, null, true, false, false, false, false, false, null, null, null, '2100', false, 'เงินออกจากบัญชี และต้นทุนทรัพย์เพิ่มขึ้น — ไม่ลงเป็นค่าซ่อมบำรุง', 'ซ่อมให้กลับมาใช้ได้เหมือนเดิม = ค่าใช้จ่าย · ปรับปรุงให้ดีขึ้น/อายุยาวขึ้น = ลงทุน', 301),
  ('inv.srr_out', 'invest_buy', 'ปล่อยเงินขายฝาก', 'Sale with right of redemption', 'investing'::sri_os.cf_group, -1, 'out', '1400', '1100', false, null, true, true, true, false, false, false, null, null, null, '2100', false, 'เงินออกจากบัญชี และเงินลงทุนขายฝาก (เงินต้น) เพิ่มขึ้น — ไม่ใช่ค่าใช้จ่าย', 'ต้องกรอกเงื่อนไขสัญญาเพื่อสร้างตารางงวดรับดอกเบี้ย (Backlog ข้อ 2)', 302),
  ('inv.mortgage_out', 'invest_buy', 'ปล่อยเงินจำนอง', 'Mortgage lending', 'investing'::sri_os.cf_group, -1, 'out', '1410', '1100', false, null, true, true, true, false, false, false, null, null, null, '2100', false, 'เงินออกจากบัญชี และเงินลงทุนจำนอง (เงินต้น) เพิ่มขึ้น — ไม่ใช่ค่าใช้จ่าย', 'ต้องกรอกเงื่อนไขสัญญาเพื่อสร้างตารางงวดรับดอกเบี้ย (Backlog ข้อ 2)', 303),
  ('inv.lend', 'invest_buy', 'ให้กู้ยืมออกไป', 'Loan out', 'investing'::sri_os.cf_group, -1, 'out', '1300', '1100', false, null, false, true, true, false, false, false, null, null, null, '2100', false, 'เงินออกจากบัญชี และลูกหนี้เงินให้กู้ยืมเพิ่มขึ้น — ไม่ใช่ค่าใช้จ่าย', 'เงินที่เราปล่อยออกไปเป็น Investing ไม่ใช่ Financing — Financing คือเรากู้เขา', 304),
  ('inv.buy_securities', 'invest_buy', 'ซื้อหลักทรัพย์ / กองทุน', 'Buy securities', 'investing'::sri_os.cf_group, -1, 'out', '1700', '1100', false, null, true, false, false, false, false, false, null, null, null, '2100', false, 'เงินออกจากบัญชี และเงินลงทุนในหลักทรัพย์เพิ่มขึ้นตามต้นทุน', null, 305),
  ('inv.buy_commodity', 'invest_buy', 'ซื้อทองคำ / สินทรัพย์ทางเลือก', 'Buy gold & alternatives', 'investing'::sri_os.cf_group, -1, 'out', '1720', '1100', false, null, true, false, false, false, false, false, null, null, null, '2100', false, 'เงินออกจากบัญชี และเงินลงทุนในทองคำเพิ่มขึ้นตามต้นทุน — ไม่ใช่ค่าใช้จ่าย', 'ทองคำและคริปโตใช้หมวดนี้ ไม่ใช่หมวดซื้อหลักทรัพย์ ไม่งั้นจะไปรวมอยู่ใน Paper Asset', 306),
  ('inv.deposit_paid', 'invest_buy', 'เงินมัดจำจ่าย', 'Deposit paid', 'operating'::sri_os.cf_group, -1, 'out', '1600', '1100', false, null, false, true, false, false, false, false, null, null, null, '2100', true, 'เงินออกจากบัญชี และเงินมัดจำจ่าย (สินทรัพย์) เพิ่มขึ้น — ไม่ใช่ค่าใช้จ่าย เพราะได้คืน', 'เงินมัดจำที่เราจ่ายคือสิทธิที่จะได้คืน จึงเป็นสินทรัพย์ ไม่ใช่ค่าใช้จ่าย', 307),
  ('inv.sell_re', 'invest_sell', 'ขายอสังหาริมทรัพย์', 'Dispose real estate', 'investing'::sri_os.cf_group, 1, 'in', '1100', '1500', true, 'กำไรจากการขายทรัพย์ / ขาดทุนจากการขายทรัพย์', true, false, false, true, false, false, '4300', '5910', null, '1220', false, 'ตัดทรัพย์ออกตามต้นทุน รับเงินเข้าบัญชี และรับรู้กำไร/ขาดทุนจากการขายใน P&L', 'ส่วนต่างจากการตีราคาที่เคยบันทึกไว้ต้องถูกล้างออกพร้อมกัน — ทั้งตอนตีขึ้นและตีลง (ขายขาดทุนเกิดขึ้นจริง)', 400),
  ('inv.srr_redeem', 'invest_sell', 'รับไถ่ถอนขายฝาก (เงินต้น)', 'Redemption received', 'investing'::sri_os.cf_group, 1, 'in', '1100', '1400', true, 'ดอกเบี้ยรับ - ขายฝาก', true, true, false, false, true, false, null, null, '4100', '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และเงินลงทุนขายฝากลดลง — ไม่ใช่รายได้', 'รับพร้อมดอกเบี้ยได้ในรายการเดียว แต่ต้องแยกยอดให้ชัด — เงินต้นลดลูกหนี้ ดอกเบี้ยเป็นรายได้', 401),
  ('inv.mortgage_redeem', 'invest_sell', 'รับไถ่ถอนจำนอง (เงินต้น)', 'Mortgage redeemed', 'investing'::sri_os.cf_group, 1, 'in', '1100', '1410', true, 'ดอกเบี้ยรับ - จำนอง', true, true, false, false, true, false, null, null, '4110', '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และเงินลงทุนจำนองลดลง — ไม่ใช่รายได้', 'รับพร้อมดอกเบี้ยได้ในรายการเดียว แต่ต้องแยกยอดให้ชัด — เงินต้นลดลูกหนี้ ดอกเบี้ยเป็นรายได้', 402),
  ('inv.loan_back', 'invest_sell', 'รับคืนเงินให้กู้ยืม (เงินต้น)', 'Loan principal repaid', 'investing'::sri_os.cf_group, 1, 'in', '1100', '1300', true, 'ดอกเบี้ยรับ - เงินให้กู้ยืม', false, true, false, false, true, false, null, null, '4120', '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และลูกหนี้เงินให้กู้ยืมลดลง — ไม่ใช่รายได้', 'รับพร้อมดอกเบี้ยได้ในรายการเดียว แต่ต้องแยกยอดให้ชัด — เงินต้นลดลูกหนี้ ดอกเบี้ยเป็นรายได้', 403),
  ('inv.sell_securities', 'invest_sell', 'ขายหลักทรัพย์ / กองทุน', 'Sell securities', 'investing'::sri_os.cf_group, 1, 'in', '1100', '1700', true, 'รายได้อื่น / ขาดทุนจากการขายทรัพย์', false, false, false, true, false, false, '4900', '5910', null, '1220', false, 'ตัดเงินลงทุนออกตามต้นทุน รับเงินเข้าบัญชี และรับรู้กำไร/ขาดทุนจากการขาย', null, 404),
  ('inv.sell_commodity', 'invest_sell', 'ขายทองคำ / สินทรัพย์ทางเลือก', 'Sell gold & alternatives', 'investing'::sri_os.cf_group, 1, 'in', '1100', '1720', true, 'รายได้อื่น / ขาดทุนจากการขายทรัพย์', false, false, false, true, false, false, '4900', '5910', null, '1220', false, 'ตัดเงินลงทุนในทองคำออกตามต้นทุน รับเงินเข้าบัญชี และรับรู้กำไร/ขาดทุนจากการขาย', 'ขายขาดทุนเกิดขึ้นได้จริง — ต้นทุนต้องมาจากล็อตที่ซื้อจริง (FIFO) ไม่ใช่ราคาเฉลี่ย', 405),
  ('inv.deposit_returned', 'invest_sell', 'รับคืนเงินมัดจำที่จ่ายไว้', 'Deposit paid refunded', 'operating'::sri_os.cf_group, 1, 'in', '1100', '1600', false, null, false, true, false, false, false, false, null, null, null, '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และเงินมัดจำจ่ายลดลง — ไม่ใช่รายได้', null, 406),
  ('inv.collect_rent', 'invest_sell', 'รับชำระค่าเช่าค้างรับ', 'Rent receivable collected', 'operating'::sri_os.cf_group, 1, 'in', '1100', '1200', false, null, false, true, false, false, false, false, null, null, null, null, false, 'เงินเข้าบัญชีเพิ่มขึ้น และลูกหนี้ค่าเช่าลดลง — ไม่ใช่รายได้ใหม่ รับรู้ไปแล้วตอนตั้งค้าง', 'ถ้ายังไม่เคยตั้งค้างรับไว้ ให้ลงเป็นรายได้ › ค่าเช่า ตรงๆ แทน ไม่งั้นรายได้จะหาย', 407),
  ('inv.collect_interest', 'invest_sell', 'รับชำระดอกเบี้ยค้างรับ', 'Interest receivable collected', 'operating'::sri_os.cf_group, 1, 'in', '1100', '1210', false, null, false, true, false, false, false, false, null, null, null, null, false, 'เงินเข้าบัญชีเพิ่มขึ้น และลูกหนี้ดอกเบี้ยลดลง — ไม่ใช่รายได้ใหม่ รับรู้ไปแล้วตอนตั้งค้าง', 'ถ้ายังไม่เคยตั้งค้างรับไว้ ให้ลงเป็นรายได้ › ดอกเบี้ยรับ ตรงๆ แทน ไม่งั้นรายได้จะหาย', 408),
  ('fin.loan_bank', 'finance_in', 'กู้เงินธนาคาร', 'Bank borrowing', 'financing'::sri_os.cf_group, 1, 'in', '1100', '2410', false, null, false, true, true, false, false, false, null, null, null, '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และหนี้สินเงินกู้ธนาคารเพิ่มขึ้น — ไม่ใช่รายได้', 'เงินเข้าบัญชีแต่ไม่ใช่รายได้ ห้ามลงหมวด รายได้ เด็ดขาด', 500),
  ('fin.loan_director', 'finance_in', 'กู้ยืมกรรมการ / คนในครอบครัว', 'Director loan', 'financing'::sri_os.cf_group, 1, 'in', '1100', '2300', false, null, false, true, true, false, false, false, null, null, null, '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และหนี้สินเงินกู้ยืมกรรมการเพิ่มขึ้น — ไม่ใช่รายได้', 'เงินเข้าบัญชีแต่ไม่ใช่รายได้ ห้ามลงหมวด รายได้ เด็ดขาด', 501),
  ('fin.loan_other', 'finance_in', 'กู้ยืมอื่น', 'Other borrowing', 'financing'::sri_os.cf_group, 1, 'in', '1100', '2400', false, null, false, true, true, false, false, false, null, null, null, '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และหนี้สินเงินกู้ยืมอื่นเพิ่มขึ้น — ไม่ใช่รายได้', null, 502),
  ('fin.capital', 'finance_in', 'เพิ่มทุน', 'Capital injection', 'financing'::sri_os.cf_group, 1, 'in', '1100', '3100', false, null, false, true, false, false, false, false, null, null, null, '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และส่วนของเจ้าของเพิ่มขึ้น — ไม่ใช่รายได้', 'เงินทุนจากอากงต้องแยกจากเงินกู้ยืมกรรมการ ห้ามรวมเป็นก้อนเดียว', 503),
  ('fin.deposit_received', 'finance_in', 'รับเงินมัดจำจากผู้เช่า', 'Tenant deposit received', 'operating'::sri_os.cf_group, 1, 'in', '1100', '2200', false, null, true, true, false, false, false, false, null, null, null, '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และหนี้สินเงินมัดจำเพิ่มขึ้น — ต้องคืนภายหลัง จึงไม่ใช่รายได้', null, 504),
  ('fin.repay_bank', 'finance_out', 'ชำระคืนเงินกู้ธนาคาร (เงินต้น)', 'Bank loan principal repaid', 'financing'::sri_os.cf_group, -1, 'out', '2410', '1100', true, 'ดอกเบี้ยจ่าย', false, true, false, false, true, false, null, null, '5400', '2100', false, 'เงินออกจากบัญชี และหนี้สินเงินกู้ธนาคารลดลง — เงินต้นไม่ใช่ค่าใช้จ่าย', 'เงินต้นไม่ใช่ค่าใช้จ่าย ต้องแยกออกจากดอกเบี้ยเสมอ (Backlog ข้อ 5)', 600),
  ('fin.repay_director', 'finance_out', 'ชำระคืนเงินกู้ยืมกรรมการ (เงินต้น)', 'Director loan repaid', 'financing'::sri_os.cf_group, -1, 'out', '2300', '1100', true, 'ดอกเบี้ยจ่าย', false, true, false, false, true, false, null, null, '5400', '2100', false, 'เงินออกจากบัญชี และหนี้สินเงินกู้ยืมกรรมการลดลง — ไม่ใช่ค่าใช้จ่าย', 'เงินต้นไม่ใช่ค่าใช้จ่าย ต้องแยกออกจากดอกเบี้ยเสมอ (Backlog ข้อ 5)', 601),
  ('fin.interest_paid', 'finance_out', 'จ่ายดอกเบี้ย', 'Interest paid', 'financing'::sri_os.cf_group, -1, 'out', '5400', '1100', true, 'ดอกเบี้ยจ่าย', false, true, false, false, false, false, null, null, null, '2100', false, 'เงินออกจากบัญชี และดอกเบี้ยจ่ายเพิ่มขึ้น — หนี้สินเงินต้นไม่เปลี่ยน', null, 602),
  ('fin.drawings', 'finance_out', 'ถอนทุน / จ่ายปันผล', 'Drawings', 'financing'::sri_os.cf_group, -1, 'out', '3200', '1100', false, null, false, true, false, false, false, false, null, null, null, '2100', false, 'เงินออกจากบัญชี และส่วนของเจ้าของลดลง — ไม่ใช่ค่าใช้จ่ายใน P&L', 'เงินปันผลจ่ายลดส่วนของเจ้าของ ไม่ใช่ค่าใช้จ่าย จึงไม่กระทบกำไรสุทธิ', 603),
  ('fin.deposit_refund', 'finance_out', 'คืนเงินมัดจำผู้เช่า', 'Tenant deposit refunded', 'operating'::sri_os.cf_group, -1, 'out', '2200', '1100', false, null, false, true, false, false, false, false, null, null, null, '2100', true, 'เงินออกจากบัญชี และหนี้สินเงินมัดจำลดลง — ไม่ใช่ค่าใช้จ่าย', null, 604),
  ('fin.pay_payable', 'finance_out', 'จ่ายเจ้าหนี้ค้างจ่าย', 'Pay trade payable', 'operating'::sri_os.cf_group, -1, 'out', '2100', '1100', false, null, false, true, false, false, false, false, null, null, null, null, false, 'เงินออกจากบัญชี และเจ้าหนี้ค้างจ่ายลดลง — ค่าใช้จ่ายรับรู้ไปแล้วตอนตั้งหนี้', 'ถ้ายังไม่เคยตั้งหนี้ไว้ ให้ลงเป็นค่าใช้จ่ายตรงๆ แทน ไม่งั้นค่าใช้จ่ายจะหาย', 605),
  ('trf.internal', 'transfer', 'โอนระหว่างบัญชีในกองกลาง', 'Internal transfer', 'transfer'::sri_os.cf_group, 0, 'both', '1100', '1100', false, null, false, false, false, false, false, true, null, null, null, null, false, 'เงินย้ายจากบัญชีหนึ่งไปอีกบัญชี ยอดรวมกองกลางไม่เปลี่ยน', 'ไม่นับในงบกระแสเงินสด และตัดออกจากงบรวม จึงไม่กระทบกำไรขาดทุนและ NAV', 700),
  ('adj.doubtful', 'adjust', 'ตั้งค่าเผื่อหนี้สงสัยจะสูญ', 'Provide for doubtful accounts', 'transfer'::sri_os.cf_group, 0, 'none', '5920', '1290', true, 'หนี้สงสัยจะสูญ', false, true, false, false, false, false, null, null, null, null, false, 'ค่าใช้จ่ายหนี้สงสัยจะสูญเพิ่มขึ้น และค่าเผื่อโต ทำให้ลูกหนี้สุทธิในงบดุลลดลง — ไม่มีเงินเข้าออกบัญชี', 'นี่คือจุดเดียวที่รับรู้ค่าใช้จ่าย · ตอนตัดหนี้สูญจริงจะไม่มีค่าใช้จ่ายอีก ถ้าหนี้จริงมากกว่าค่าเผื่อที่ตั้งไว้ ต้องตั้งเพิ่มที่หมวดนี้ก่อนจึงตัดได้', 800),
  ('adj.doubtful_release', 'adjust', 'กลับค่าเผื่อที่ตั้งไว้เกิน', 'Reverse excess allowance', 'transfer'::sri_os.cf_group, 0, 'none', '1290', '5920', true, 'หนี้สงสัยจะสูญ', false, true, false, false, false, false, null, null, null, null, false, 'ค่าเผื่อลดลง ลูกหนี้สุทธิในงบดุลกลับเพิ่มขึ้น และค่าใช้จ่ายหนี้สงสัยจะสูญลดลง — ไม่มีเงินเข้าออกบัญชี', 'กลับได้ไม่เกินค่าเผื่อคงเหลือของผู้ถือรายนี้ — กลับเกินกว่าที่ตั้งไว้คือสร้างรายได้จากอากาศ (DB ปฏิเสธ)', 801),
  ('adj.writeoff_rent', 'adjust', 'ตัดหนี้สูญ — ค่าเช่า', 'Write off rent receivable', 'transfer'::sri_os.cf_group, 0, 'none', '1290', '1200', false, null, false, true, false, false, false, false, null, null, null, null, false, 'ล้างลูกหนี้ค่าเช่าออกจากงบดุลโดยหักกับค่าเผื่อที่ตั้งไว้ — ไม่มีค่าใช้จ่ายใหม่และไม่มีเงินเข้าออก', 'ค่าใช้จ่ายรับรู้ไปแล้วตอนตั้งค่าเผื่อ หมวดนี้จึงไม่แตะกำไรขาดทุน · ตัดได้ไม่เกินค่าเผื่อคงเหลือ ถ้าไม่พอให้ไปตั้งค่าเผื่อเพิ่มก่อน (DB ปฏิเสธ)', 802),
  ('adj.writeoff_interest', 'adjust', 'ตัดหนี้สูญ — ดอกเบี้ย', 'Write off interest receivable', 'transfer'::sri_os.cf_group, 0, 'none', '1290', '1210', false, null, false, true, false, false, false, false, null, null, null, null, false, 'ล้างลูกหนี้ดอกเบี้ยออกจากงบดุลโดยหักกับค่าเผื่อที่ตั้งไว้ — ไม่มีค่าใช้จ่ายใหม่และไม่มีเงินเข้าออก', 'ค่าใช้จ่ายรับรู้ไปแล้วตอนตั้งค่าเผื่อ หมวดนี้จึงไม่แตะกำไรขาดทุน · ตัดได้ไม่เกินค่าเผื่อคงเหลือ ถ้าไม่พอให้ไปตั้งค่าเผื่อเพิ่มก่อน (DB ปฏิเสธ)', 803),
  ('adj.writeoff_other', 'adjust', 'ตัดหนี้สูญ — ลูกหนี้อื่น', 'Write off other receivable', 'transfer'::sri_os.cf_group, 0, 'none', '1290', '1220', false, null, false, true, false, false, false, false, null, null, null, null, false, 'ล้างลูกหนี้อื่นออกจากงบดุลโดยหักกับค่าเผื่อที่ตั้งไว้ — ไม่มีค่าใช้จ่ายใหม่และไม่มีเงินเข้าออก', 'ค่าใช้จ่ายรับรู้ไปแล้วตอนตั้งค่าเผื่อ หมวดนี้จึงไม่แตะกำไรขาดทุน · ตัดได้ไม่เกินค่าเผื่อคงเหลือ ถ้าไม่พอให้ไปตั้งค่าเผื่อเพิ่มก่อน (DB ปฏิเสธ)', 804)
on conflict (code) do update set
  group_code = excluded.group_code,
  name_th    = excluded.name_th,
  name_en    = excluded.name_en,
  cf_group   = excluded.cf_group,
  direction  = excluded.direction,
  cash_direction = excluded.cash_direction,
  dr_coa_code = excluded.dr_coa_code,
  cr_coa_code = excluded.cr_coa_code,
  affects_pl = excluded.affects_pl,
  pl_line    = excluded.pl_line,
  requires_asset = excluded.requires_asset,
  requires_contact = excluded.requires_contact,
  requires_loan_terms = excluded.requires_loan_terms,
  requires_capital_gain = excluded.requires_capital_gain,
  requires_principal_split = excluded.requires_principal_split,
  requires_transfer_target = excluded.requires_transfer_target,
  gain_coa_code     = excluded.gain_coa_code,
  loss_coa_code     = excluded.loss_coa_code,
  interest_coa_code = excluded.interest_coa_code,
  accrual_coa_code  = excluded.accrual_coa_code,
  can_accrue        = excluded.can_accrue,
  plain_th   = excluded.plain_th,
  caution_th = excluded.caution_th,
  sort_order = excluded.sort_order;

-- ลบหมวดที่ถูกเอาออกจากตารางกฎแล้ว (แต่กันไม่ให้ลบถ้ามีรายการอ้างอยู่)
delete from sri_os.txn_types
 where code not in ('inc.rent', 'inc.hire_purchase', 'inc.interest_srr', 'inc.interest_mortgage', 'inc.interest_loan', 'inc.dividend', 'inc.key_money', 'inc.fee', 'inc.other', 'exp.common', 'exp.utilities', 'exp.repair', 'exp.furnishing', 'exp.cleaning', 'exp.commission', 'exp.referral', 'exp.marketing', 'exp.land_office', 'exp.tax', 'exp.legal', 'exp.bank_charge', 'exp.salary', 'exp.travel', 'exp.office', 'exp.other', 'inv.buy_re', 'inv.capex', 'inv.srr_out', 'inv.mortgage_out', 'inv.lend', 'inv.buy_securities', 'inv.buy_commodity', 'inv.deposit_paid', 'inv.sell_re', 'inv.srr_redeem', 'inv.mortgage_redeem', 'inv.loan_back', 'inv.sell_securities', 'inv.sell_commodity', 'inv.deposit_returned', 'inv.collect_rent', 'inv.collect_interest', 'fin.loan_bank', 'fin.loan_director', 'fin.loan_other', 'fin.capital', 'fin.deposit_received', 'fin.repay_bank', 'fin.repay_director', 'fin.interest_paid', 'fin.drawings', 'fin.deposit_refund', 'fin.pay_payable', 'trf.internal', 'adj.doubtful', 'adj.doubtful_release', 'adj.writeoff_rent', 'adj.writeoff_interest', 'adj.writeoff_other')
   and not exists (select 1 from sri_os.transactions x where x.txn_type_code = txn_types.code)
   and not exists (select 1 from sri_os.draft_entries d where d.txn_type_code = txn_types.code);

-- ------------------------------------------------------------
-- 3 · คู่บัญชีระหว่างกัน (src/lib/rules/intercompany.ts)
--
-- เป็น **ฟังก์ชัน** ไม่ใช่ตาราง: แอปแก้ไม่ได้เลย เปลี่ยนได้เฉพาะด้วย migration
-- ที่อยู่ใน git · trigger ของบรรทัดบัญชีกับประตู fn_post_entry อ่านจากที่นี่ที่เดียว
-- ------------------------------------------------------------
create or replace function fn_intercompany_pairs()
  returns table (nature text, payer_coa text, receiver_coa text)
language sql immutable as $fn$
  -- ฝ่ายจ่าย | ฝ่ายรับ — generate จาก INTERCOMPANY_RULES
  values ('advance', '1310', '2310'),
         ('loan', '1310', '2310'),
         ('capital', '1710', '3100'),
         ('dividend', '3200', '4410')
$fn$;

comment on function fn_intercompany_pairs() is
  'สำเนาเดียวในฝั่ง DB ของคู่บัญชีระหว่างกัน · generate จาก src/lib/rules/intercompany.ts ด้วย npm run sync:rules · ตรวจว่าตรงกันด้วย npm run check:sync';

revoke all on function fn_intercompany_pairs() from public;
do $do$
begin
  execute 'revoke all on function sri_os.fn_intercompany_pairs() from anon';
  execute 'grant execute on function sri_os.fn_intercompany_pairs() to authenticated';
end $do$;

-- ------------------------------------------------------------
-- guard ท้ายไฟล์ — ดังตอน migrate ไม่ใช่ตอนผู้ใช้กดบันทึก
-- ------------------------------------------------------------
do $do$
declare v text;
begin
  -- ทุกรหัสที่คู่บัญชีระหว่างกันใช้ ต้องมีในผังบัญชี
  select string_agg(x.code, ', ' order by x.code) into v
    from (select p.payer_coa as code from sri_os.fn_intercompany_pairs() p
          union select p.receiver_coa from sri_os.fn_intercompany_pairs() p) x
   where not exists (select 1 from sri_os.chart_of_accounts c where c.code = x.code);
  if v is not null then
    raise exception 'ผังบัญชีขาดรหัสที่คู่บัญชีระหว่างกันใช้: % — รายการข้ามผู้ถือจะถูกปฏิเสธตอนผู้ใช้กดบันทึก', v;
  end if;

  -- ลักษณะที่ตาราง transactions อนุญาต ต้องมีคู่บัญชีครบ และไม่เกิน
  select pg_get_constraintdef(oid) into v from pg_constraint
   where conrelid = 'sri_os.transactions'::regclass
     and conname = 'transactions_intercompany_nature_check';
  if v is null then
    raise exception 'ไม่มี constraint transactions_intercompany_nature_check — ลักษณะข้ามผู้ถือจะรับค่าอะไรก็ได้';
  end if;
  if exists (select 1 from sri_os.fn_intercompany_pairs() p
              where position('''' || p.nature || '''' in v) = 0) then
    raise exception 'fn_intercompany_pairs() มีลักษณะที่ตาราง transactions ไม่อนุญาต (constraint: %) — เพิ่มใน constraint ด้วย migration ก่อน', v;
  end if;
  if exists (
    select 1 from (select (regexp_matches(v, '''([a-z_]+)''::text', 'g'))[1] as nature) x
     where not exists (select 1 from sri_os.fn_intercompany_pairs() p where p.nature = x.nature)) then
    raise exception 'ตาราง transactions อนุญาตลักษณะที่ไม่มีคู่บัญชีใน fn_intercompany_pairs() (constraint: %) — ผู้ใช้เลือกแล้วกดบันทึกไม่ได้', v;
  end if;

  raise notice 'seed ตารางกฎครบ: ผังบัญชี 53 รหัส · ประเภทรายการ 59 หมวด · คู่บัญชีระหว่างกัน 4 ลักษณะ';
end $do$;
