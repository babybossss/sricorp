-- ============================================================
-- SRI OS · seed ตารางกฎทั้งชุด (ผังบัญชี · ประเภทรายการ · คู่บัญชีระหว่างกัน)
--
-- ไฟล์นี้ generate จาก src/lib/rules/{coa,tx-rules,intercompany}.ts — **ห้ามแก้ด้วยมือ**
-- แก้ที่ตารางกฎในโค้ดแล้วรัน `npm run sync:rules` ใหม่
-- ตรวจว่าตรงกันด้วย `npm run check:sync` (พังถ้าไม่ตรง)
--
-- ทำอะไร (เรียงตามลำดับที่จำเป็น เพราะ FK):
--   1 · 66 รหัสลงตาราง chart_of_accounts
--   2 · 111 หมวดย่อยลงตาราง txn_types (ในนั้น 26 หมวดตั้งค้างรับ-ค้างจ่ายได้)
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
  ('1320', 'เงินให้กู้ยืมแบบมีสินทรัพย์ค้ำประกัน - เงินต้น', 'Secured loan principal receivable', 'asset', 132),
  ('1400', 'เงินลงทุนขายฝาก - เงินต้น', 'Redemption principal', 'asset', 140),
  ('1410', 'เงินลงทุนจำนอง - เงินต้น', 'Mortgage principal', 'asset', 141),
  ('1500', 'อสังหาริมทรัพย์เพื่อการลงทุน เพื่อการเช่า', 'Investment property - rental', 'asset', 150),
  ('1510', 'ค่ารีโนเวท (บันทึกเป็นทุน)', 'Renovation capitalised', 'asset', 151),
  ('1520', 'อสังหาริมทรัพย์เพื่อการลงทุน เพื่อการขาย', 'Investment property - held for sale', 'asset', 152),
  ('1600', 'เงินมัดจำจ่าย', 'Deposits paid', 'asset', 160),
  ('1700', 'เงินลงทุนในหุ้นและหลักทรัพย์', 'Investment in shares & securities', 'asset', 170),
  ('1720', 'เงินลงทุนในทองคำ คริปโต และสินทรัพย์ทางเลือก', 'Gold, crypto & alternative assets', 'asset', 172),
  ('1310', 'ลูกหนี้ระหว่างกัน (ในกองกลาง)', 'Intercompany receivable', 'asset', 131),
  ('1710', 'เงินลงทุนในบริษัทในเครือ', 'Investment in related company', 'asset', 171),
  ('1800', 'ภาษีถูกหัก ณ ที่จ่ายรอเครดิต', 'Withholding tax credit', 'asset', 180),
  ('1900', 'สินทรัพย์หมุนเวียนอื่น', 'Other current assets', 'asset', 190),
  ('1950', 'สินทรัพย์ไม่หมุนเวียน', 'Non-current assets', 'asset', 195),
  ('2100', 'เจ้าหนี้การค้า-เจ้าหนี้อื่น', 'Trade & other payables', 'liability', 210),
  ('2200', 'เงินมัดจำรับจากผู้เช่า', 'Tenant deposits received', 'liability', 220),
  ('2300', 'เงินกู้ยืมกรรมการ', 'Director loan', 'liability', 230),
  ('2400', 'เงินกู้ยืมอื่น', 'Other loans', 'liability', 240),
  ('2410', 'เงินกู้ธนาคาร', 'Bank borrowing', 'liability', 241),
  ('2310', 'เจ้าหนี้ระหว่างกัน (ในกองกลาง)', 'Intercompany payable', 'liability', 231),
  ('2500', 'หนี้สินหมุนเวียนอื่น', 'Other current liabilities', 'liability', 250),
  ('2600', 'หนี้สินไม่หมุนเวียน', 'Non-current liabilities', 'liability', 260),
  ('3100', 'ทุนตั้งต้น', 'Paid-in capital', 'equity', 310),
  ('3200', 'เงินถอนของเจ้าของ', 'Drawings', 'equity', 320),
  ('3300', 'กำไรสะสม', 'Retained earnings', 'equity', 330),
  ('3400', 'ส่วนเกินทุนจากการตีราคา (ยังไม่เกิดขึ้นจริง)', 'Unrealised revaluation surplus', 'equity', 340),
  ('3410', 'ผลต่างอัตราแลกเปลี่ยนจากการแปลงค่า (ยังไม่เกิดขึ้นจริง)', 'Unrealised FX translation difference', 'equity', 341),
  ('4100', 'ดอกเบี้ยรับ - ขายฝาก', 'Interest income - Redemption', 'income', 410),
  ('4110', 'ดอกเบี้ยรับ - จำนอง', 'Interest income - Mortgage', 'income', 411),
  ('4120', 'ดอกเบี้ยรับ - เงินให้กู้ยืม', 'Interest income - Loan', 'income', 412),
  ('4130', 'ดอกเบี้ยรับ - เงินให้กู้ยืมมีหลักประกัน', 'Interest income - Secured loan', 'income', 413),
  ('4200', 'รายได้ค่าเช่า', 'Rental income', 'income', 420),
  ('4210', 'รายได้ค่าเช่าซื้อ', 'Hire-purchase income', 'income', 421),
  ('4300', 'กำไรจากการขายทรัพย์', 'Gain on sale of property', 'income', 430),
  ('4310', 'เงินกินเปล่า', 'Key money', 'income', 431),
  ('4330', 'กำไรจากอัตราแลกเปลี่ยน (เกิดขึ้นจริง)', 'Realised FX gain', 'income', 433),
  ('4320', 'หนี้สูญได้รับคืน', 'Bad debt recovered', 'income', 432),
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
  ('5920', 'หนี้สงสัยจะสูญ', 'Doubtful debt expense', 'expense', 592),
  ('5930', 'ขาดทุนจากอัตราแลกเปลี่ยน (เกิดขึ้นจริง)', 'Realised FX loss', 'expense', 593)
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
   where c.code <> all (array['1100', '1200', '1210', '1220', '1290', '1300', '1320', '1400', '1410', '1500', '1510', '1520', '1600', '1700', '1720', '1310', '1710', '1800', '1900', '1950', '2100', '2200', '2300', '2400', '2410', '2310', '2500', '2600', '3100', '3200', '3300', '3400', '3410', '4100', '4110', '4120', '4130', '4200', '4210', '4300', '4310', '4330', '4320', '4400', '4900', '4410', '5100', '5110', '5120', '5130', '5140', '5200', '5210', '5220', '5300', '5310', '5320', '5330', '5400', '5500', '5510', '5520', '5900', '5910', '5920', '5930']);
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
  ('inc.interest_loan', 'income', 'ดอกเบี้ยรับ — เงินให้กู้ยืม', 'Interest income · Loan', 'operating'::sri_os.cf_group, 1, 'in', '1100', '4120', true, 'ดอกเบี้ยรับ - เงินให้กู้ยืม', false, true, false, false, false, false, null, null, null, '1210', true, 'เงินเข้าบัญชีเพิ่มขึ้น และดอกเบี้ยรับเงินให้กู้ยืมเพิ่มขึ้น', 'ใช้กับเงินให้กู้ที่ **ไม่มี** สินทรัพย์ค้ำประกัน · มีของค้ำที่ไม่ใช่อสังหาฯ (รถ ทอง เครื่องจักร หุ้น) ให้ใช้หมวดดอกเบี้ยรับเงินให้กู้ยืมมีหลักประกัน (4130) · หลักประกันเป็นที่ดินหรือสิ่งปลูกสร้าง ให้ใช้หมวดขายฝาก (4100) หรือจำนอง (4110)', 104),
  ('inc.interest_loan_secured', 'income', 'ดอกเบี้ยรับ — เงินให้กู้ยืมมีหลักประกัน', 'Interest income · Secured loan', 'operating'::sri_os.cf_group, 1, 'in', '1100', '4130', true, 'ดอกเบี้ยรับ - เงินให้กู้ยืมมีหลักประกัน', false, true, false, false, false, false, null, null, null, '1210', true, 'เงินเข้าบัญชีเพิ่มขึ้น และดอกเบี้ยรับเงินให้กู้ยืมมีหลักประกันเพิ่มขึ้น — เงินต้นยังไม่ลด', 'ใช้กับหลักประกันที่ **ไม่ใช่อสังหาริมทรัพย์** (รถ ทอง เครื่องจักร หุ้น) · หลักประกันเป็นที่ดินหรือสิ่งปลูกสร้างต้องลงดอกเบี้ยขายฝาก (4100) หรือจำนอง (4110) ไม่ใช่หมวดนี้ · ถ้ารับเงินต้นคืนด้วย ให้แยกบันทึกเงินต้นที่ ลงทุน (ขาย/รับคืน) › รับคืนเงินให้กู้ยืมมีหลักประกัน', 105),
  ('inc.dividend', 'income', 'เงินปันผลรับ', 'Dividend income', 'operating'::sri_os.cf_group, 1, 'in', '1100', '4410', true, 'เงินปันผลรับ', false, false, false, false, false, false, null, null, null, '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และเงินปันผลรับเพิ่มขึ้น', null, 106),
  ('inc.key_money', 'income', 'เงินกินเปล่า', 'Key money', 'operating'::sri_os.cf_group, 1, 'in', '1100', '4310', true, 'เงินกินเปล่า', true, true, false, false, false, false, null, null, null, '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และรายได้เงินกินเปล่าเพิ่มขึ้น', null, 107),
  ('inc.fee', 'income', 'ค่าคอมมิชชั่น / ค่าธรรมเนียมรับ', 'Fee & commission income', 'operating'::sri_os.cf_group, 1, 'in', '1100', '4400', true, 'ค่าคอมมิชชั่น-ค่าธรรมเนียมรับ', false, true, false, false, false, false, null, null, null, '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และรายได้ค่าธรรมเนียมเพิ่มขึ้น', null, 108),
  ('inc.bad_debt_recovered', 'income', 'หนี้สูญได้รับคืน', 'Bad debt recovered', 'operating'::sri_os.cf_group, 1, 'in', '1100', '4320', true, 'หนี้สูญได้รับคืน', false, true, false, false, false, false, null, null, null, null, false, 'เงินเข้าบัญชีเพิ่มขึ้น และรับรู้เป็นรายได้ หนี้สูญได้รับคืน — ไม่กลับไปเพิ่มลูกหนี้ที่ตัดออกจากสมุดไปแล้ว', 'ใช้หมวดนี้เฉพาะหนี้ที่ **ตัดหนี้สูญไปแล้ว** · ถ้าลูกหนี้ยังอยู่ในสมุด ให้ลงที่ ลงทุน (ขาย/รับคืน) › รับชำระค่าเช่าค้างรับ เพื่อให้ลูกหนี้ลดลงจริง · ถ้าตัดหนี้สูญไปแล้วแต่ลงเป็นรับชำระค้างรับ ลูกหนี้จะติดลบและรายได้จะขาดไปเท่ายอดที่เก็บคืนได้', 109),
  ('inc.other', 'income', 'รายได้อื่น', 'Other income', 'operating'::sri_os.cf_group, 1, 'in', '1100', '4900', true, 'รายได้อื่น', false, false, false, false, false, false, null, null, null, '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และรายได้อื่นเพิ่มขึ้น', 'ฝั่ง Corporate ห้ามใช้หมวดนี้แบบไม่ระบุ ต้องเลือกหมวดที่ตรงกว่าเสมอ', 110),
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
  ('inv.lend', 'invest_buy', 'ให้กู้ยืมออกไป', 'Loan out', 'investing'::sri_os.cf_group, -1, 'out', '1300', '1100', false, null, false, true, true, false, false, false, null, null, null, '2100', false, 'เงินออกจากบัญชี และลูกหนี้เงินให้กู้ยืมเพิ่มขึ้น — ไม่ใช่ค่าใช้จ่าย', 'เงินที่เราปล่อยออกไปเป็น Investing ไม่ใช่ Financing — Financing คือเรากู้เขา · ถ้ามีสินทรัพย์ค้ำประกัน ให้ใช้หมวด ให้กู้ยืมแบบมีหลักประกัน (1320) แทน', 304),
  ('inv.lend_secured', 'invest_buy', 'ให้กู้ยืมออกไป — มีสินทรัพย์ค้ำประกัน', 'Secured loan out', 'investing'::sri_os.cf_group, -1, 'out', '1320', '1100', false, null, false, true, true, false, false, false, null, null, null, '2100', false, 'เงินออกจากบัญชี และลูกหนี้เงินให้กู้ยืมแบบมีสินทรัพย์ค้ำประกันเพิ่มขึ้น — ไม่ใช่ค่าใช้จ่าย', 'ใช้กับหลักประกันที่ **ไม่ใช่อสังหาริมทรัพย์** (รถ ทอง เครื่องจักร หุ้น) · หลักประกันเป็นที่ดินหรือสิ่งปลูกสร้างต้องใช้หมวดขายฝาก (1400) หรือจำนอง (1410) ไม่ใช่หมวดนี้ ไม่งั้นความเสี่ยงที่อิงอสังหาฯ จะไปโผล่ในหมวดการลงทุนผิดประเภท · เงินที่เราปล่อยออกไปเป็น Investing ไม่ใช่ Financing', 305),
  ('inv.buy_securities', 'invest_buy', 'ซื้อหลักทรัพย์ / กองทุน', 'Buy securities', 'investing'::sri_os.cf_group, -1, 'out', '1700', '1100', false, null, true, false, false, false, false, false, null, null, null, '2100', false, 'เงินออกจากบัญชี และเงินลงทุนในหลักทรัพย์เพิ่มขึ้นตามต้นทุน', null, 306),
  ('inv.buy_commodity', 'invest_buy', 'ซื้อทองคำ / สินทรัพย์ทางเลือก', 'Buy gold & alternatives', 'investing'::sri_os.cf_group, -1, 'out', '1720', '1100', false, null, true, false, false, false, false, false, null, null, null, '2100', false, 'เงินออกจากบัญชี และเงินลงทุนในทองคำเพิ่มขึ้นตามต้นทุน — ไม่ใช่ค่าใช้จ่าย', 'ทองคำและคริปโตใช้หมวดนี้ ไม่ใช่หมวดซื้อหลักทรัพย์ ไม่งั้นจะไปรวมอยู่ใน Paper Asset', 307),
  ('inv.deposit_paid', 'invest_buy', 'เงินมัดจำจ่าย', 'Deposit paid', 'operating'::sri_os.cf_group, -1, 'out', '1600', '1100', false, null, false, true, false, false, false, false, null, null, null, '2100', true, 'เงินออกจากบัญชี และเงินมัดจำจ่าย (สินทรัพย์) เพิ่มขึ้น — ไม่ใช่ค่าใช้จ่าย เพราะได้คืน', 'เงินมัดจำที่เราจ่ายคือสิทธิที่จะได้คืน จึงเป็นสินทรัพย์ ไม่ใช่ค่าใช้จ่าย', 308),
  ('inv.other_current_asset', 'invest_buy', 'จ่ายเงิน — สินทรัพย์หมุนเวียนอื่น', 'Pay into other current assets', 'operating'::sri_os.cf_group, -1, 'out', '1900', '1100', false, null, false, true, false, false, false, false, null, null, null, '2100', true, 'เงินออกจากบัญชี และสินทรัพย์หมุนเวียนอื่นเพิ่มขึ้น — ไม่ใช่ค่าใช้จ่าย เพราะยังเป็นสิทธิของเรา', 'ใช้เฉพาะของที่**ไม่มีบัญชีเฉพาะของตัวเอง** · ถ้าเป็นเงินมัดจำให้ใช้หมวดเงินมัดจำจ่าย ถ้าเป็นค่าใช้จ่ายที่จ่ายแล้วหมดไปเลย **ต้องลงเป็นค่าใช้จ่าย ไม่ใช่สินทรัพย์** ไม่งั้นกำไรจะสูงกว่าจริงเท่ายอดที่ซุกไว้ในสินทรัพย์', 309),
  ('inv.other_noncurrent_asset', 'invest_buy', 'จ่ายเงิน — สินทรัพย์ไม่หมุนเวียน', 'Pay into non-current assets', 'investing'::sri_os.cf_group, -1, 'out', '1950', '1100', false, null, false, true, false, false, false, false, null, null, null, '2100', false, 'เงินออกจากบัญชี และสินทรัพย์ไม่หมุนเวียนเพิ่มขึ้น — ไม่ใช่ค่าใช้จ่าย', '**ไม่ใช่บัญชีรวมของสินทรัพย์ไม่หมุนเวียนทั้งหมด** — ซื้ออสังหาฯ ใช้หมวดซื้ออสังหาฯ ซื้อหุ้น/ทองคำใช้หมวดของมัน ไม่งั้นทะเบียนทรัพย์กับต้นทุนรายล็อตจะไม่ตรงกับงบดุล', 310),
  ('inv.sell_re', 'invest_sell', 'ขายอสังหาริมทรัพย์', 'Dispose real estate', 'investing'::sri_os.cf_group, 1, 'in', '1100', '1500', true, 'กำไรจากการขายทรัพย์ / ขาดทุนจากการขายทรัพย์', true, false, false, true, false, false, '4300', '5910', null, '1220', false, 'ตัดทรัพย์ออกตามต้นทุน รับเงินเข้าบัญชี และรับรู้กำไร/ขาดทุนจากการขายใน P&L', 'ส่วนต่างจากการตีราคาที่เคยบันทึกไว้ต้องถูกล้างออกพร้อมกัน — ทั้งตอนตีขึ้นและตีลง (ขายขาดทุนเกิดขึ้นจริง) · ใช้กับทรัพย์ที่อยู่บัญชี**เพื่อการเช่า (1500)** ถ้าทรัพย์ถูกย้ายไปบัญชีเพื่อการขาย (1520) แล้ว ให้ใช้หมวดขายของบัญชีนั้น', 400),
  ('inv.sell_re_held_for_sale', 'invest_sell', 'ขายอสังหาริมทรัพย์ (ที่ถือไว้เพื่อขาย)', 'Dispose real estate held for sale', 'investing'::sri_os.cf_group, 1, 'in', '1100', '1520', true, 'กำไรจากการขายทรัพย์ / ขาดทุนจากการขายทรัพย์', true, false, false, true, false, false, '4300', '5910', null, '1220', false, 'ตัดทรัพย์ออกจากบัญชีอสังหาฯ เพื่อการขายตามต้นทุน รับเงินเข้าบัญชี และรับรู้กำไร/ขาดทุนจากการขายใน P&L', 'ส่วนต่างจากการตีราคาที่เคยบันทึกไว้ต้องถูกล้างออกพร้อมกัน — ทั้งตอนตีขึ้นและตีลง (ขายขาดทุนเกิดขึ้นจริง) · ใช้กับทรัพย์ที่อยู่บัญชี**เพื่อการขาย (1520)** เท่านั้น ถ้าทรัพย์ยังปล่อยเช่าอยู่ (1500) ให้ใช้หมวดขายอสังหาริมทรัพย์ตัวหลัก · **ห้ามย้ายวัตถุประสงค์ในใบเดียวกับการขาย** เลือกหมวดให้ตรงกับบัญชีที่ทรัพย์อยู่จริง ไม่งั้นบัญชีหนึ่งจะติดลบและอีกบัญชีค้างเป็นทรัพย์ผี', 401),
  ('inv.srr_redeem', 'invest_sell', 'รับไถ่ถอนขายฝาก (เงินต้น)', 'Redemption received', 'investing'::sri_os.cf_group, 1, 'in', '1100', '1400', true, 'ดอกเบี้ยรับ - ขายฝาก', true, true, false, false, true, false, null, null, '4100', '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และเงินลงทุนขายฝากลดลง — ไม่ใช่รายได้', 'รับพร้อมดอกเบี้ยได้ในรายการเดียว แต่ต้องแยกยอดให้ชัด — เงินต้นลดลูกหนี้ ดอกเบี้ยเป็นรายได้', 402),
  ('inv.mortgage_redeem', 'invest_sell', 'รับไถ่ถอนจำนอง (เงินต้น)', 'Mortgage redeemed', 'investing'::sri_os.cf_group, 1, 'in', '1100', '1410', true, 'ดอกเบี้ยรับ - จำนอง', true, true, false, false, true, false, null, null, '4110', '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และเงินลงทุนจำนองลดลง — ไม่ใช่รายได้', 'รับพร้อมดอกเบี้ยได้ในรายการเดียว แต่ต้องแยกยอดให้ชัด — เงินต้นลดลูกหนี้ ดอกเบี้ยเป็นรายได้', 403),
  ('inv.loan_back', 'invest_sell', 'รับคืนเงินให้กู้ยืม (เงินต้น)', 'Loan principal repaid', 'investing'::sri_os.cf_group, 1, 'in', '1100', '1300', true, 'ดอกเบี้ยรับ - เงินให้กู้ยืม', false, true, false, false, true, false, null, null, '4120', '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และลูกหนี้เงินให้กู้ยืมลดลง — ไม่ใช่รายได้', 'รับพร้อมดอกเบี้ยได้ในรายการเดียว แต่ต้องแยกยอดให้ชัด — เงินต้นลดลูกหนี้ ดอกเบี้ยเป็นรายได้', 404),
  ('inv.loan_back_secured', 'invest_sell', 'รับคืนเงินให้กู้ยืมมีหลักประกัน (เงินต้น)', 'Secured loan principal repaid', 'investing'::sri_os.cf_group, 1, 'in', '1100', '1320', true, 'ดอกเบี้ยรับ - เงินให้กู้ยืมมีหลักประกัน', false, true, false, false, true, false, null, null, '4130', '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และลูกหนี้เงินให้กู้ยืมแบบมีสินทรัพย์ค้ำประกันลดลง — ไม่ใช่รายได้', 'รับพร้อมดอกเบี้ยได้ในรายการเดียว แต่ต้องแยกยอดให้ชัด — เงินต้นลดลูกหนี้ ดอกเบี้ยเป็นรายได้ที่บัญชีของเงินกู้มีหลักประกัน (4130) ไม่ใช่ 4120 · หลักประกันเป็นที่ดินหรือสิ่งปลูกสร้างต้องใช้หมวดรับไถ่ถอนขายฝาก/จำนอง', 405),
  ('inv.sell_securities', 'invest_sell', 'ขายหลักทรัพย์ / กองทุน', 'Sell securities', 'investing'::sri_os.cf_group, 1, 'in', '1100', '1700', true, 'รายได้อื่น / ขาดทุนจากการขายทรัพย์', false, false, false, true, false, false, '4900', '5910', null, '1220', false, 'ตัดเงินลงทุนออกตามต้นทุน รับเงินเข้าบัญชี และรับรู้กำไร/ขาดทุนจากการขาย', null, 406),
  ('inv.sell_commodity', 'invest_sell', 'ขายทองคำ / สินทรัพย์ทางเลือก', 'Sell gold & alternatives', 'investing'::sri_os.cf_group, 1, 'in', '1100', '1720', true, 'รายได้อื่น / ขาดทุนจากการขายทรัพย์', false, false, false, true, false, false, '4900', '5910', null, '1220', false, 'ตัดเงินลงทุนในทองคำออกตามต้นทุน รับเงินเข้าบัญชี และรับรู้กำไร/ขาดทุนจากการขาย', 'ขายขาดทุนเกิดขึ้นได้จริง — ต้นทุนต้องมาจากล็อตที่ซื้อจริง (FIFO) ไม่ใช่ราคาเฉลี่ย', 407),
  ('inv.deposit_returned', 'invest_sell', 'รับคืนเงินมัดจำที่จ่ายไว้', 'Deposit paid refunded', 'operating'::sri_os.cf_group, 1, 'in', '1100', '1600', false, null, false, true, false, false, false, false, null, null, null, '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และเงินมัดจำจ่ายลดลง — ไม่ใช่รายได้', null, 408),
  ('inv.other_current_asset_back', 'invest_sell', 'รับคืน — สินทรัพย์หมุนเวียนอื่น', 'Other current assets recovered', 'operating'::sri_os.cf_group, 1, 'in', '1100', '1900', false, null, false, true, false, false, false, false, null, null, null, '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และสินทรัพย์หมุนเวียนอื่นลดลง — ไม่ใช่รายได้', 'ถ้าได้เงินมา**มากกว่า**ยอดที่ลงบัญชีไว้ ส่วนเกินคือกำไร ต้องลงเป็นรายได้แยกบรรทัด ห้ามลงทั้งก้อนในหมวดนี้ ไม่งั้นกำไรจะหายไปจากงบกำไรขาดทุน', 409),
  ('inv.other_noncurrent_asset_back', 'invest_sell', 'รับคืน — สินทรัพย์ไม่หมุนเวียน', 'Non-current assets recovered', 'investing'::sri_os.cf_group, 1, 'in', '1100', '1950', false, null, false, true, false, false, false, false, null, null, null, '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และสินทรัพย์ไม่หมุนเวียนลดลง — ไม่ใช่รายได้', 'ถ้าได้เงินมา**มากกว่า**ยอดที่ลงบัญชีไว้ ส่วนเกินคือกำไร ต้องลงเป็นรายได้แยกบรรทัด ห้ามลงทั้งก้อนในหมวดนี้ ไม่งั้นกำไรจะหายไปจากงบกำไรขาดทุน', 410),
  ('inv.collect_rent', 'invest_sell', 'รับชำระค่าเช่าค้างรับ', 'Rent receivable collected', 'operating'::sri_os.cf_group, 1, 'in', '1100', '1200', false, null, false, true, false, false, false, false, null, null, null, null, false, 'เงินเข้าบัญชีเพิ่มขึ้น และลูกหนี้ค่าเช่าลดลง — ไม่ใช่รายได้ใหม่ รับรู้ไปแล้วตอนตั้งค้าง', 'ถ้ายังไม่เคยตั้งค้างรับไว้ ให้ลงเป็นรายได้ › ค่าเช่า ตรงๆ แทน ไม่งั้นรายได้จะหาย', 411),
  ('inv.collect_interest', 'invest_sell', 'รับชำระดอกเบี้ยค้างรับ', 'Interest receivable collected', 'operating'::sri_os.cf_group, 1, 'in', '1100', '1210', false, null, false, true, false, false, false, false, null, null, null, null, false, 'เงินเข้าบัญชีเพิ่มขึ้น และลูกหนี้ดอกเบี้ยลดลง — ไม่ใช่รายได้ใหม่ รับรู้ไปแล้วตอนตั้งค้าง', 'ถ้ายังไม่เคยตั้งค้างรับไว้ ให้ลงเป็นรายได้ › ดอกเบี้ยรับ ตรงๆ แทน ไม่งั้นรายได้จะหาย', 412),
  ('inv.wht_refund', 'invest_sell', 'รับคืนภาษีถูกหัก ณ ที่จ่าย', 'Withholding tax refunded', 'operating'::sri_os.cf_group, 1, 'in', '1100', '1800', false, null, false, true, false, false, false, false, null, null, null, null, false, 'เงินเข้าบัญชีเพิ่มขึ้น และภาษีถูกหัก ณ ที่จ่ายรอเครดิตลดลง — ไม่ใช่รายได้ใหม่ รายได้รับรู้เต็มจำนวนไปแล้วตอนถูกหัก', 'ใช้ตอนได้รับคืนภาษีจากกรมสรรพากร หรือตอนนำเครดิตไปหักภาษีที่ต้องชำระจริง · ถ้ายังไม่เคยมีรายการที่ถูกหักภาษีไว้ หมวดนี้จะทำให้ยอดเครดิตติดลบ', 413),
  ('fin.loan_bank', 'finance_in', 'กู้เงินธนาคาร', 'Bank borrowing', 'financing'::sri_os.cf_group, 1, 'in', '1100', '2410', false, null, false, true, true, false, false, false, null, null, null, '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และหนี้สินเงินกู้ธนาคารเพิ่มขึ้น — ไม่ใช่รายได้', 'เงินเข้าบัญชีแต่ไม่ใช่รายได้ ห้ามลงหมวด รายได้ เด็ดขาด', 500),
  ('fin.loan_director', 'finance_in', 'กู้ยืมกรรมการ / คนในครอบครัว', 'Director loan', 'financing'::sri_os.cf_group, 1, 'in', '1100', '2300', false, null, false, true, true, false, false, false, null, null, null, '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และหนี้สินเงินกู้ยืมกรรมการเพิ่มขึ้น — ไม่ใช่รายได้', 'เงินเข้าบัญชีแต่ไม่ใช่รายได้ ห้ามลงหมวด รายได้ เด็ดขาด', 501),
  ('fin.loan_other', 'finance_in', 'กู้ยืมอื่น', 'Other borrowing', 'financing'::sri_os.cf_group, 1, 'in', '1100', '2400', false, null, false, true, true, false, false, false, null, null, null, '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และหนี้สินเงินกู้ยืมอื่นเพิ่มขึ้น — ไม่ใช่รายได้', null, 502),
  ('fin.capital', 'finance_in', 'เพิ่มทุน', 'Capital injection', 'financing'::sri_os.cf_group, 1, 'in', '1100', '3100', false, null, false, true, false, false, false, false, null, null, null, '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และส่วนของเจ้าของเพิ่มขึ้น — ไม่ใช่รายได้', 'เงินทุนจากอากงต้องแยกจากเงินกู้ยืมกรรมการ ห้ามรวมเป็นก้อนเดียว', 503),
  ('fin.deposit_received', 'finance_in', 'รับเงินมัดจำจากผู้เช่า', 'Tenant deposit received', 'operating'::sri_os.cf_group, 1, 'in', '1100', '2200', false, null, true, true, false, false, false, false, null, null, null, '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และหนี้สินเงินมัดจำเพิ่มขึ้น — ต้องคืนภายหลัง จึงไม่ใช่รายได้', null, 504),
  ('fin.other_current_liability_in', 'finance_in', 'รับเงิน — หนี้สินหมุนเวียนอื่น', 'Other current liability received', 'operating'::sri_os.cf_group, 1, 'in', '1100', '2500', false, null, false, true, false, false, false, false, null, null, null, '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และหนี้สินหมุนเวียนอื่นเพิ่มขึ้น — ต้องคืนภายหลัง จึงไม่ใช่รายได้', 'เงินที่**ไม่ต้องคืน**ไม่ใช่หนี้สิน ต้องลงเป็นรายได้ · ลงผิดเป็นหนี้สินจะทำให้รายได้ต่ำกว่าจริง และมีหนี้ผีค้างในงบดุลที่ไม่มีใครมาทวง', 505),
  ('fin.other_noncurrent_liability_in', 'finance_in', 'รับเงิน — หนี้สินไม่หมุนเวียน', 'Non-current liability received', 'financing'::sri_os.cf_group, 1, 'in', '1100', '2600', false, null, false, true, false, false, false, false, null, null, null, '1220', false, 'เงินเข้าบัญชีเพิ่มขึ้น และหนี้สินไม่หมุนเวียนเพิ่มขึ้น — ต้องคืนภายหลัง จึงไม่ใช่รายได้', 'ถ้าเป็นเงินกู้ให้ใช้หมวดเงินกู้ของมัน (ธนาคาร/กรรมการ/อื่น) ซึ่งบังคับกรอกเงื่อนไขเงินกู้ และแยกเงินต้นกับดอกเบี้ยตอนคืนให้ · ลงที่นี่แทนจะไม่มีใครรู้ว่าต้องจ่ายดอกเท่าไรและครบกำหนดเมื่อไร', 506),
  ('fin.repay_bank', 'finance_out', 'ชำระคืนเงินกู้ธนาคาร (เงินต้น)', 'Bank loan principal repaid', 'financing'::sri_os.cf_group, -1, 'out', '2410', '1100', true, 'ดอกเบี้ยจ่าย', false, true, false, false, true, false, null, null, '5400', '2100', false, 'เงินออกจากบัญชี และหนี้สินเงินกู้ธนาคารลดลง — เงินต้นไม่ใช่ค่าใช้จ่าย', 'เงินต้นไม่ใช่ค่าใช้จ่าย ต้องแยกออกจากดอกเบี้ยเสมอ (Backlog ข้อ 5)', 600),
  ('fin.repay_director', 'finance_out', 'ชำระคืนเงินกู้ยืมกรรมการ (เงินต้น)', 'Director loan repaid', 'financing'::sri_os.cf_group, -1, 'out', '2300', '1100', true, 'ดอกเบี้ยจ่าย', false, true, false, false, true, false, null, null, '5400', '2100', false, 'เงินออกจากบัญชี และหนี้สินเงินกู้ยืมกรรมการลดลง — ไม่ใช่ค่าใช้จ่าย', 'เงินต้นไม่ใช่ค่าใช้จ่าย ต้องแยกออกจากดอกเบี้ยเสมอ (Backlog ข้อ 5)', 601),
  ('fin.interest_paid', 'finance_out', 'จ่ายดอกเบี้ย', 'Interest paid', 'financing'::sri_os.cf_group, -1, 'out', '5400', '1100', true, 'ดอกเบี้ยจ่าย', false, true, false, false, false, false, null, null, null, '2100', false, 'เงินออกจากบัญชี และดอกเบี้ยจ่ายเพิ่มขึ้น — หนี้สินเงินต้นไม่เปลี่ยน', null, 602),
  ('fin.drawings', 'finance_out', 'ถอนทุน / จ่ายปันผล', 'Drawings', 'financing'::sri_os.cf_group, -1, 'out', '3200', '1100', false, null, false, true, false, false, false, false, null, null, null, '2100', false, 'เงินออกจากบัญชี และส่วนของเจ้าของลดลง — ไม่ใช่ค่าใช้จ่ายใน P&L', 'เงินปันผลจ่ายลดส่วนของเจ้าของ ไม่ใช่ค่าใช้จ่าย จึงไม่กระทบกำไรสุทธิ', 603),
  ('fin.deposit_refund', 'finance_out', 'คืนเงินมัดจำผู้เช่า', 'Tenant deposit refunded', 'operating'::sri_os.cf_group, -1, 'out', '2200', '1100', false, null, false, true, false, false, false, false, null, null, null, '2100', true, 'เงินออกจากบัญชี และหนี้สินเงินมัดจำลดลง — ไม่ใช่ค่าใช้จ่าย', null, 604),
  ('fin.other_current_liability_out', 'finance_out', 'จ่ายคืน — หนี้สินหมุนเวียนอื่น', 'Other current liability settled', 'operating'::sri_os.cf_group, -1, 'out', '2500', '1100', false, null, false, true, false, false, false, false, null, null, null, '2100', true, 'เงินออกจากบัญชี และหนี้สินหมุนเวียนอื่นลดลง — ไม่ใช่ค่าใช้จ่าย เพราะเป็นการคืนเงินต้น', 'ถ้าจ่ายรวมดอกเบี้ยหรือค่าปรับมาด้วย **ต้องแยกลงเป็นค่าใช้จ่ายคนละบรรทัด** ลงรวมทั้งก้อนที่นี่จะทำให้หนี้ลดเกินจริงและค่าใช้จ่ายหายไปจากงบกำไรขาดทุน', 605),
  ('fin.other_noncurrent_liability_out', 'finance_out', 'จ่ายคืน — หนี้สินไม่หมุนเวียน', 'Non-current liability settled', 'financing'::sri_os.cf_group, -1, 'out', '2600', '1100', false, null, false, true, false, false, false, false, null, null, null, '2100', false, 'เงินออกจากบัญชี และหนี้สินไม่หมุนเวียนลดลง — ไม่ใช่ค่าใช้จ่าย เพราะเป็นการคืนเงินต้น', 'ถ้าจ่ายรวมดอกเบี้ยมาด้วย **ต้องแยกดอกเบี้ยลงเป็นค่าใช้จ่ายคนละบรรทัด** ลงรวมทั้งก้อนที่นี่จะทำให้หนี้ลดเกินจริงและค่าใช้จ่ายดอกเบี้ยหายไปจากงบกำไรขาดทุน', 606),
  ('fin.pay_payable', 'finance_out', 'จ่ายเจ้าหนี้ค้างจ่าย', 'Pay trade payable', 'operating'::sri_os.cf_group, -1, 'out', '2100', '1100', false, null, false, true, false, false, false, false, null, null, null, null, false, 'เงินออกจากบัญชี และเจ้าหนี้ค้างจ่ายลดลง — ค่าใช้จ่ายรับรู้ไปแล้วตอนตั้งหนี้', 'ถ้ายังไม่เคยตั้งหนี้ไว้ ให้ลงเป็นค่าใช้จ่ายตรงๆ แทน ไม่งั้นค่าใช้จ่ายจะหาย', 607),
  ('trf.internal', 'transfer', 'โอนระหว่างบัญชีในกองกลาง', 'Internal transfer', 'transfer'::sri_os.cf_group, 0, 'both', '1100', '1100', false, null, false, false, false, false, false, true, null, null, null, null, false, 'เงินย้ายจากบัญชีหนึ่งไปอีกบัญชี ยอดรวมกองกลางไม่เปลี่ยน', 'ไม่นับในงบกระแสเงินสด และตัดออกจากงบรวม จึงไม่กระทบกำไรขาดทุนและ NAV', 700),
  ('trf.fx_translate_up', 'transfer', 'แปลงค่าเงินฝากสกุลต่างประเทศ — ยอดบาทเพิ่ม', 'Translate FCD balance up', 'transfer'::sri_os.cf_group, 1, 'in', '1100', '3410', false, null, false, false, false, false, false, false, null, null, null, null, false, 'ยอดบาทของบัญชีเงินฝากสกุลต่างประเทศเพิ่มขึ้นตามอัตราสิ้นเดือน และผลต่างอัตราแลกเปลี่ยนในส่วนของเจ้าของเพิ่มขึ้น — จำนวนเงินตราเท่าเดิม ไม่มีเงินเข้าออก และไม่เข้างบกำไรขาดทุน', 'กำไรค่าเงินที่ยังไม่ได้แลกไม่ใช่กำไรจริง ห้ามนำไปจ่ายปันผล · ต้องระบุอัตราสิ้นเดือนที่มีอยู่ในตารางอัตราแลกเปลี่ยน (DB ปฏิเสธถ้าไม่มี) · ลงได้เฉพาะบัญชีเงินฝากสกุลต่างประเทศ — บัญชีบาทไม่ขยับตามอัตราแลกเปลี่ยน (ทั้งเครื่องยนต์และ DB ปฏิเสธ เพราะเท่ากับสร้างเงินสดขึ้นมาจากอากาศ)', 701),
  ('trf.fx_translate_down', 'transfer', 'แปลงค่าเงินฝากสกุลต่างประเทศ — ยอดบาทลด', 'Translate FCD balance down', 'transfer'::sri_os.cf_group, -1, 'out', '3410', '1100', false, null, false, false, false, false, false, false, null, null, null, null, false, 'ผลต่างอัตราแลกเปลี่ยนในส่วนของเจ้าของลดลง และยอดบาทของบัญชีเงินฝากสกุลต่างประเทศลดลงตามอัตราสิ้นเดือน — จำนวนเงินตราเท่าเดิม ไม่มีเงินเข้าออก และไม่เข้างบกำไรขาดทุน', 'ขาดทุนค่าเงินที่ยังไม่ได้แลกยังไม่เกิดขึ้นจริง จึงไม่เป็นค่าใช้จ่าย · ยอดผลต่างติดลบได้ (บาทแข็งค่า) และต้องแสดงในวงเล็บ · ต้องใช้หมวดให้ตรงทิศของอัตรา — อัตราที่ทำให้ยอดบาทเพิ่มต้องใช้หมวดยอดบาทเพิ่ม (เครื่องยนต์ปฏิเสธถ้าทิศไม่ตรง ไม่กลับเครื่องหมายให้เอง)', 702),
  ('trf.fx_acquire', 'transfer', 'ซื้อเงินตราต่างประเทศเข้าบัญชีสกุลต่างประเทศ', 'Buy foreign currency into FCD account', 'transfer'::sri_os.cf_group, 0, 'both', '1100', '1100', false, null, false, false, false, false, false, true, null, null, null, null, false, 'เงินบาทออกจากบัญชีบาท และเงินตราเข้าบัญชีสกุลต่างประเทศตามอัตราที่ซื้อได้จริง — ยอดบาทที่จ่ายไปคือต้นทุนของเงินตราก้อนนั้น ไม่ใช่กำไรหรือขาดทุน และไม่เข้างบกำไรขาดทุน', 'ซื้อเข้า **ไม่มีกำไรขาดทุน** และ **ไม่ตั้งผลต่างใน 3410** — ผลต่างเกิดตอนอัตราขยับหลังถือไว้ (ใช้หมวดแปลงค่าสิ้นเดือน) และรับรู้จริงตอนแลกกลับเป็นบาท · ต้องใช้อัตราที่ประกาศไว้ในตารางอัตราของวันนั้น (DB ปฏิเสธถ้าไม่มี) และยอดบาทต้องเท่ากับ จำนวนเงินตรา × อัตรา พอดี ไม่ยอมเศษแม้สตางค์เดียว · ปลายทางต้องเป็นบัญชีสกุลต่างประเทศของผู้ถือเดียวกัน (ข้ามผู้ถือให้โอนเป็นอีกรายการ)', 703),
  ('trf.fx_convert', 'transfer', 'แลกเงินตราต่างประเทศเป็นบาท', 'Convert foreign currency to baht', 'transfer'::sri_os.cf_group, 0, 'both', '1100', '1100', true, 'กำไรจากอัตราแลกเปลี่ยน (เกิดขึ้นจริง) / ขาดทุนจากอัตราแลกเปลี่ยน (เกิดขึ้นจริง)', false, false, false, false, false, true, '4330', '5930', null, null, false, 'เงินตราออกจากบัญชีสกุลต่างประเทศ บาทเข้าบัญชีบาท และผลต่างระหว่างอัตราตามบัญชีกับอัตราที่แลกได้จริงรับรู้เป็นกำไร/ขาดทุนอัตราแลกเปลี่ยน พร้อมล้างผลต่างที่ค้างในส่วนของเจ้าของออก', 'ต้องล้างผลต่างที่ค้างในส่วนของเจ้าของ (3410) ของสกุลนั้นพร้อมกัน ไม่งั้นนับซ้ำ · แลกหมดบัญชีแล้ว 3410 ของสกุลนั้นต้องเหลือศูนย์พอดี (DB ปฏิเสธถ้าไม่) · เครื่องยนต์สร้างบรรทัดกำไร/ขาดทุนและบรรทัดล้างตามสัดส่วนที่แลกออกให้เอง จากอัตราตามบัญชีกับอัตราที่แลกได้จริง — ต้องกรอกทั้งสองอัตรา ไม่งั้นปฏิเสธ · ปลายทางต้องเป็นบัญชีบาทของผู้ถือเดียวกัน', 704),
  ('adj.doubtful', 'adjust', 'ตั้งค่าเผื่อหนี้สงสัยจะสูญ', 'Provide for doubtful accounts', 'transfer'::sri_os.cf_group, 0, 'none', '5920', '1290', true, 'หนี้สงสัยจะสูญ', false, true, false, false, false, false, null, null, null, null, false, 'ค่าใช้จ่ายหนี้สงสัยจะสูญเพิ่มขึ้น และค่าเผื่อโต ทำให้ลูกหนี้สุทธิในงบดุลลดลง — ไม่มีเงินเข้าออกบัญชี', 'นี่คือจุดเดียวที่รับรู้ค่าใช้จ่าย · ตอนตัดหนี้สูญจริงจะไม่มีค่าใช้จ่ายอีก ถ้าหนี้จริงมากกว่าค่าเผื่อที่ตั้งไว้ ต้องตั้งเพิ่มที่หมวดนี้ก่อนจึงตัดได้', 800),
  ('adj.doubtful_release', 'adjust', 'กลับค่าเผื่อที่ตั้งไว้เกิน', 'Reverse excess allowance', 'transfer'::sri_os.cf_group, 0, 'none', '1290', '5920', true, 'หนี้สงสัยจะสูญ', false, true, false, false, false, false, null, null, null, null, false, 'ค่าเผื่อลดลง ลูกหนี้สุทธิในงบดุลกลับเพิ่มขึ้น และค่าใช้จ่ายหนี้สงสัยจะสูญลดลง — ไม่มีเงินเข้าออกบัญชี', 'กลับได้ไม่เกินค่าเผื่อคงเหลือของผู้ถือรายนี้ — กลับเกินกว่าที่ตั้งไว้คือสร้างรายได้จากอากาศ (DB ปฏิเสธ)', 801),
  ('adj.writeoff_rent', 'adjust', 'ตัดหนี้สูญ — ค่าเช่า', 'Write off rent receivable', 'transfer'::sri_os.cf_group, 0, 'none', '1290', '1200', false, null, false, true, false, false, false, false, null, null, null, null, false, 'ล้างลูกหนี้ค่าเช่าออกจากงบดุลโดยหักกับค่าเผื่อที่ตั้งไว้ — ไม่มีค่าใช้จ่ายใหม่และไม่มีเงินเข้าออก', 'ค่าใช้จ่ายรับรู้ไปแล้วตอนตั้งค่าเผื่อ หมวดนี้จึงไม่แตะกำไรขาดทุน · ตัดได้ไม่เกินค่าเผื่อคงเหลือ ถ้าไม่พอให้ไปตั้งค่าเผื่อเพิ่มก่อน (DB ปฏิเสธ)', 802),
  ('adj.writeoff_interest', 'adjust', 'ตัดหนี้สูญ — ดอกเบี้ย', 'Write off interest receivable', 'transfer'::sri_os.cf_group, 0, 'none', '1290', '1210', false, null, false, true, false, false, false, false, null, null, null, null, false, 'ล้างลูกหนี้ดอกเบี้ยออกจากงบดุลโดยหักกับค่าเผื่อที่ตั้งไว้ — ไม่มีค่าใช้จ่ายใหม่และไม่มีเงินเข้าออก', 'ค่าใช้จ่ายรับรู้ไปแล้วตอนตั้งค่าเผื่อ หมวดนี้จึงไม่แตะกำไรขาดทุน · ตัดได้ไม่เกินค่าเผื่อคงเหลือ ถ้าไม่พอให้ไปตั้งค่าเผื่อเพิ่มก่อน (DB ปฏิเสธ)', 803),
  ('adj.writeoff_other', 'adjust', 'ตัดหนี้สูญ — ลูกหนี้อื่น', 'Write off other receivable', 'transfer'::sri_os.cf_group, 0, 'none', '1290', '1220', false, null, false, true, false, false, false, false, null, null, null, null, false, 'ล้างลูกหนี้อื่นออกจากงบดุลโดยหักกับค่าเผื่อที่ตั้งไว้ — ไม่มีค่าใช้จ่ายใหม่และไม่มีเงินเข้าออก', 'ค่าใช้จ่ายรับรู้ไปแล้วตอนตั้งค่าเผื่อ หมวดนี้จึงไม่แตะกำไรขาดทุน · ตัดได้ไม่เกินค่าเผื่อคงเหลือ ถ้าไม่พอให้ไปตั้งค่าเผื่อเพิ่มก่อน (DB ปฏิเสธ)', 804),
  ('adj.reclass_re_to_sale', 'adjust', 'ย้ายวัตถุประสงค์อสังหาฯ — จากเพื่อการเช่า ไปเพื่อการขาย', 'Reclassify investment property · rental → held for sale', 'transfer'::sri_os.cf_group, 0, 'none', '1520', '1500', false, null, true, false, false, false, false, false, null, null, null, null, false, 'ย้ายต้นทุนทรัพย์จากบัญชีอสังหาฯ เพื่อการเช่า ไปบัญชีเพื่อการขาย ด้วยต้นทุนเดิม — สินทรัพย์รวมเท่าเดิม ไม่มีเงินเข้าออก และไม่เข้างบกำไรขาดทุน', 'การย้ายวัตถุประสงค์ **ไม่ใช่การขาย** จึงไม่มีกำไรเกิดขึ้นและไม่กระทบงบกำไรขาดทุน · ย้ายด้วย **ต้นทุนเดิม** เท่านั้น ห้ามตีราคาใหม่ในใบเดียวกัน (ตีราคาต้องเป็นอีกใบ เข้า 3400 ไม่เข้า P&L) · ค่ารีโนเวท (1510) ไม่ต้องย้าย เพราะใช้บัญชีเดียวกันทั้งสองวัตถุประสงค์และผูกกับทรัพย์ชิ้นนั้นอยู่แล้ว · **ย้ายแล้วขายจากบัญชีเพื่อการขายได้เลย** ด้วยหมวด "ขายอสังหาริมทรัพย์ (ที่ถือไว้เพื่อขาย)" ซึ่งตัดค่ารีโนเวทสะสมออกพร้อมทรัพย์ได้เหมือนฝั่งเช่า ไม่ต้องย้ายกลับก่อน', 805),
  ('adj.reclass_re_to_rental', 'adjust', 'ย้ายวัตถุประสงค์อสังหาฯ — จากเพื่อการขาย กลับไปเพื่อการเช่า', 'Reclassify investment property · held for sale → rental', 'transfer'::sri_os.cf_group, 0, 'none', '1500', '1520', false, null, true, false, false, false, false, false, null, null, null, null, false, 'ย้ายต้นทุนทรัพย์จากบัญชีอสังหาฯ เพื่อการขาย กลับไปบัญชีเพื่อการเช่า ด้วยต้นทุนเดิม — สินทรัพย์รวมเท่าเดิม ไม่มีเงินเข้าออก และไม่เข้างบกำไรขาดทุน', 'การย้ายวัตถุประสงค์ **ไม่ใช่การขาย** จึงไม่มีกำไรเกิดขึ้นและไม่กระทบงบกำไรขาดทุน · ย้ายด้วย **ต้นทุนเดิม** เท่านั้น ห้ามตีราคาใหม่ในใบเดียวกัน (ตีราคาต้องเป็นอีกใบ เข้า 3400 ไม่เข้า P&L) · ใช้ตอน **เลิกขายแล้วกลับไปปล่อยเช่า** เท่านั้น · **ไม่ต้องใช้เพื่อเตรียมขาย** — ของที่อยู่บัญชีเพื่อการขาย (1520) ขายจากบัญชีของตัวเองได้เลย ด้วยหมวด "ขายอสังหาริมทรัพย์ (ที่ถือไว้เพื่อขาย)" · ย้ายเพื่อขายจะทำให้ประวัติวัตถุประสงค์ของทรัพย์อ่านไม่ออก', 806),
  ('adj.revalue_securities_up', 'adjust', 'ตีราคาหลักทรัพย์ขึ้น (ยังไม่ขาย)', 'Revalue securities up', 'transfer'::sri_os.cf_group, 0, 'none', '1700', '3400', false, null, true, false, false, false, false, false, null, null, null, null, false, 'มูลค่าเงินลงทุนในหลักทรัพย์เพิ่มขึ้น และส่วนเกินทุนจากการตีราคาในส่วนของเจ้าของเพิ่มขึ้น — ไม่เข้างบกำไรขาดทุน และไม่มีเงินเข้าออกบัญชี', 'กำไรจากการตีราคาไม่ใช่กำไรที่เกิดขึ้นจริง ห้ามนำไปจ่ายปันผล · เดือนถัดไปต้องกลับรายการของเดือนนี้ก่อนลงยอดใหม่ ไม่ใช่ลงทับกัน', 807),
  ('adj.revalue_securities_down', 'adjust', 'ตีราคาหลักทรัพย์ลง (ยังไม่ขาย)', 'Revalue securities down', 'transfer'::sri_os.cf_group, 0, 'none', '3400', '1700', false, null, true, false, false, false, false, false, null, null, null, null, false, 'ส่วนเกินทุนจากการตีราคาลดลง และมูลค่าเงินลงทุนในหลักทรัพย์ลดลง — ไม่เข้างบกำไรขาดทุน และไม่มีเงินเข้าออกบัญชี', 'ขาดทุนจากการตีราคายังไม่เกิดขึ้นจริง จึงไม่เป็นค่าใช้จ่าย · ยอดส่วนเกินทุนติดลบได้ (ทรัพย์ต่ำกว่าทุน) และต้องแสดงในวงเล็บ', 808),
  ('adj.revalue_commodity_up', 'adjust', 'ตีราคาทองคำ/คริปโตขึ้น (ยังไม่ขาย)', 'Revalue gold & alternative assets up', 'transfer'::sri_os.cf_group, 0, 'none', '1720', '3400', false, null, true, false, false, false, false, false, null, null, null, null, false, 'มูลค่าทองคำและสินทรัพย์ทางเลือกเพิ่มขึ้น และส่วนเกินทุนจากการตีราคาในส่วนของเจ้าของเพิ่มขึ้น — ไม่เข้างบกำไรขาดทุน และไม่มีเงินเข้าออกบัญชี', 'คริปโตแกว่งแรงมาก ยอดส่วนเกินทุนจะกลับทิศได้ทุกเดือน · เดือนถัดไปต้องกลับรายการของเดือนนี้ก่อนลงยอดใหม่', 809),
  ('adj.revalue_commodity_down', 'adjust', 'ตีราคาทองคำ/คริปโตลง (ยังไม่ขาย)', 'Revalue gold & alternative assets down', 'transfer'::sri_os.cf_group, 0, 'none', '3400', '1720', false, null, true, false, false, false, false, false, null, null, null, null, false, 'ส่วนเกินทุนจากการตีราคาลดลง และมูลค่าทองคำและสินทรัพย์ทางเลือกลดลง — ไม่เข้างบกำไรขาดทุน และไม่มีเงินเข้าออกบัญชี', 'ขาดทุนจากการตีราคายังไม่เกิดขึ้นจริง จึงไม่เป็นค่าใช้จ่าย · ตอนขายจริงถึงรับรู้กำไร/ขาดทุนเข้างบกำไรขาดทุน พร้อมล้างส่วนเกินทุนของทรัพย์ชิ้นนั้นออก', 810),
  ('opn.cash', 'opening', 'ยอดยกมา — เงินสดและเงินฝาก', 'Opening cash & bank', 'transfer'::sri_os.cf_group, 1, 'in', '1100', '3300', false, null, false, false, false, false, false, false, null, null, null, null, false, 'ยอดคงเหลือในบัญชีธนาคาร/เงินสด ณ วันตัดยอด เข้ามาอยู่ในสมุด คู่กับกำไรสะสม — ไม่ใช่เงินรับของงวด จึงไม่เข้างบกระแสเงินสด แต่ไปเป็นยอดเงินสดต้นงวด', 'ต้องลงทีละบัญชีธนาคารตามยอดใน statement ของวันตัดยอด — ยอดรวมก้อนเดียวจะกระทบยอดกับธนาคารไม่ได้ · วันที่เงินเข้า-ออกให้ใช้วันตัดยอด (ด่านฝั่ง DB บังคับว่าบรรทัดเงินสดต้องมีวันที่เงินเคลื่อน) · ไม่เข้างบกระแสเงินสด — ถ้าเข้า งวดแรกจะโชว์เงินสดรับก้อนใหญ่ที่ไม่มีอยู่จริง', 900),
  ('opn.receivable_rent', 'opening', 'ยอดยกมา — ลูกหนี้ค่าเช่า', 'Opening rent receivable', 'transfer'::sri_os.cf_group, 0, 'none', '1200', '3300', false, null, false, false, false, false, false, false, null, null, null, null, false, 'ค่าเช่าที่ค้างรับอยู่ ณ วันตัดยอด เข้ามาเป็นลูกหนี้ คู่กับกำไรสะสม', 'ยอดนี้กลายเป็น **ของค้างที่เปิดอยู่** ทันที → ตอนเก็บเงินได้ให้ใช้หมวดรับชำระค้างรับ และอ้างใบยอดยกมานี้เป็นรายการต้นทาง (ด่านกันล้างเกินคุมต่อรายการต้นทาง)', 901),
  ('opn.receivable_interest', 'opening', 'ยอดยกมา — ลูกหนี้ดอกเบี้ย', 'Opening interest receivable', 'transfer'::sri_os.cf_group, 0, 'none', '1210', '3300', false, null, false, false, false, false, false, false, null, null, null, null, false, 'ดอกเบี้ยที่ค้างรับอยู่ ณ วันตัดยอด เข้ามาเป็นลูกหนี้ คู่กับกำไรสะสม', null, 902),
  ('opn.receivable_other', 'opening', 'ยอดยกมา — ลูกหนี้อื่น (รอรับเงิน)', 'Opening other receivables', 'transfer'::sri_os.cf_group, 0, 'none', '1220', '3300', false, null, false, false, false, false, false, false, null, null, null, null, false, 'ยอดที่รอรับเงินอยู่ ณ วันตัดยอด (ไม่ใช่ค่าเช่าหรือดอกเบี้ย) เข้ามาเป็นลูกหนี้ คู่กับกำไรสะสม', 'ยอดนี้กลายเป็น **ของค้างที่เปิดอยู่** ทันที → ตอนเงินเข้าจริงให้ใช้หมวดรับชำระค้างรับ และอ้างใบยอดยกมานี้เป็นรายการต้นทาง · ถ้าเป็นค่าเช่า/ดอกเบี้ยให้ใช้หมวดของมันเอง ไม่งั้นรายงานอายุลูกหนี้แยกประเภทไม่ออก', 903),
  ('opn.allowance', 'opening', 'ยอดยกมา — ค่าเผื่อหนี้สงสัยจะสูญ', 'Opening allowance for doubtful accounts', 'transfer'::sri_os.cf_group, 0, 'none', '3300', '1290', false, null, false, false, false, false, false, false, null, null, null, null, false, 'ค่าเผื่อหนี้สงสัยจะสูญที่ตั้งไว้แล้ว ณ วันตัดยอด เข้ามาหักจากลูกหนี้ คู่กับกำไรสะสม — ลูกหนี้สุทธิจึงตรงกับที่ประเมินไว้', 'ใส่ยอด **ค่าเผื่อ** (จำนวนที่คาดว่าจะเก็บไม่ได้) ไม่ใช่ยอดลูกหนี้ · ต้องลงคู่กับหมวดลูกหนี้ให้ครบ ไม่งั้นค่าเผื่อจะมากกว่าลูกหนี้ที่มีอยู่', 904),
  ('opn.intercompany_receivable', 'opening', 'ยอดยกมา — ลูกหนี้ระหว่างกัน (ในกองกลาง)', 'Opening intercompany receivable', 'transfer'::sri_os.cf_group, 0, 'none', '1310', '3300', false, null, false, false, false, false, false, false, null, null, null, null, false, 'ยอดที่ผู้ถืออื่นในกองกลางค้างอยู่กับผู้ถือนี้ ณ วันตัดยอด คู่กับกำไรสะสม — ตัดออกในงบรวม', 'ลงทีละผู้ถือได้ (ไม่บังคับให้มาครบคู่ในใบเดียว) **แต่เมื่อนำเข้าครบทุกผู้ถือแล้ว ยอดลูกหนี้ระหว่างกันรวมต้องเท่ากับยอดเจ้าหนี้ระหว่างกันรวมพอดี** — ตรวจด้วยรายงานกระทบยอดรายการระหว่างกัน ถ้าไม่เท่า งบรวมจะตัดกันไม่ลง', 905),
  ('opn.loan_principal', 'opening', 'ยอดยกมา — เงินให้กู้ยืม (เงินต้นคงเหลือ)', 'Opening loans receivable', 'transfer'::sri_os.cf_group, 0, 'none', '1300', '3300', false, null, false, false, false, false, false, false, null, null, null, null, false, 'เงินต้นคงเหลือของเงินที่ปล่อยกู้ไว้ ณ วันตัดยอด คู่กับกำไรสะสม — ดอกเบี้ยค้างรับลงแยกบรรทัด', 'ใส่เฉพาะ **เงินต้นคงเหลือ** ไม่ใช่วงเงินตามสัญญา และไม่ใช่เงินต้นบวกดอกเบี้ยค้าง', 906),
  ('opn.loan_secured_principal', 'opening', 'ยอดยกมา — เงินให้กู้ยืมมีหลักประกัน (เงินต้นคงเหลือ)', 'Opening secured loans receivable', 'transfer'::sri_os.cf_group, 0, 'none', '1320', '3300', false, null, false, false, false, false, false, false, null, null, null, null, false, 'เงินต้นคงเหลือของเงินกู้ที่มีสินทรัพย์ค้ำประกัน ณ วันตัดยอด คู่กับกำไรสะสม — ดอกเบี้ยค้างรับลงแยกบรรทัด', 'ใส่เฉพาะ **เงินต้นคงเหลือ** ไม่ใช่วงเงินตามสัญญา และไม่ใช่เงินต้นบวกดอกเบี้ยค้าง · หลักประกันเป็นที่ดินหรือสิ่งปลูกสร้างต้องลงที่ยอดยกมาขายฝาก (1400) หรือจำนอง (1410)', 907),
  ('opn.srr_principal', 'opening', 'ยอดยกมา — เงินลงทุนขายฝาก (เงินต้นคงเหลือ)', 'Opening sale-with-right-of-redemption', 'transfer'::sri_os.cf_group, 0, 'none', '1400', '3300', false, null, false, false, false, false, false, false, null, null, null, null, false, 'เงินต้นคงเหลือของการขายฝาก ณ วันตัดยอด คู่กับกำไรสะสม', null, 908),
  ('opn.mortgage_principal', 'opening', 'ยอดยกมา — เงินลงทุนจำนอง (เงินต้นคงเหลือ)', 'Opening mortgage investment', 'transfer'::sri_os.cf_group, 0, 'none', '1410', '3300', false, null, false, false, false, false, false, false, null, null, null, null, false, 'เงินต้นคงเหลือของการรับจำนอง ณ วันตัดยอด คู่กับกำไรสะสม', null, 909),
  ('opn.property', 'opening', 'ยอดยกมา — อสังหาริมทรัพย์เพื่อการลงทุน (เพื่อการเช่า)', 'Opening investment property (rental)', 'transfer'::sri_os.cf_group, 0, 'none', '1500', '3300', false, null, false, false, false, false, false, false, null, null, null, null, false, 'ต้นทุนอสังหาริมทรัพย์ที่ถืออยู่ ณ วันตัดยอด (ราคาซื้อ ไม่ใช่ราคาตลาด) คู่กับกำไรสะสม', 'ใส่ **ต้นทุน** ไม่ใช่ราคาประเมิน/ราคาตลาด — ส่วนต่างราคาตลาดลงด้วยหมวดตีราคา (เข้า 3400 ไม่เข้า P&L) · ค่ารีโนเวทสะสมแยกบรรทัด 1510 ตามคู่มือนำเข้า · ทรัพย์ที่ถืออยู่เพื่อขาย (1520) นำเข้าที่บรรทัดนี้เหมือนกัน แล้วย้ายวัตถุประสงค์หนึ่งใบด้วย ปรับปรุงทางบัญชี › ย้ายวัตถุประสงค์อสังหาฯ (ย้ายด้วยต้นทุนเดิม ไม่กระทบงบใด)', 910),
  ('opn.renovation', 'opening', 'ยอดยกมา — ค่ารีโนเวทสะสม', 'Opening capitalised renovation', 'transfer'::sri_os.cf_group, 0, 'none', '1510', '3300', false, null, false, false, false, false, false, false, null, null, null, null, false, 'ค่ารีโนเวทที่บันทึกเป็นทุนสะสมไว้ ณ วันตัดยอด คู่กับกำไรสะสม', null, 911),
  ('opn.deposit_paid', 'opening', 'ยอดยกมา — เงินมัดจำจ่าย', 'Opening deposits paid', 'transfer'::sri_os.cf_group, 0, 'none', '1600', '3300', false, null, false, false, false, false, false, false, null, null, null, null, false, 'เงินมัดจำที่จ่ายไว้และยังไม่ได้คืน ณ วันตัดยอด คู่กับกำไรสะสม', null, 912),
  ('opn.securities', 'opening', 'ยอดยกมา — เงินลงทุนในหลักทรัพย์ (ต้นทุน)', 'Opening securities at cost', 'transfer'::sri_os.cf_group, 0, 'none', '1700', '3300', false, null, false, false, false, false, false, false, null, null, null, null, false, 'ต้นทุนรวมของหลักทรัพย์ที่ถืออยู่ ณ วันตัดยอด คู่กับกำไรสะสม — รายล็อตอยู่ในทะเบียนย่อย', 'ใส่ **ต้นทุน** ไม่ใช่มูลค่าตลาด · ยอดนี้ต้องเท่ากับผลรวมของทะเบียนรายล็อต (ถ้าไม่เท่า แปลว่ามีล็อตที่ลืมใส่ หรือมีต้นทุนที่ไม่รู้ว่ามาจากไหน)', 913),
  ('opn.gold_alt', 'opening', 'ยอดยกมา — ทองคำและสินทรัพย์ทางเลือก (ต้นทุน)', 'Opening gold & alternatives at cost', 'transfer'::sri_os.cf_group, 0, 'none', '1720', '3300', false, null, false, false, false, false, false, false, null, null, null, null, false, 'ต้นทุนรวมของทองคำ/คริปโต/ทางเลือกอื่นที่ถืออยู่ ณ วันตัดยอด คู่กับกำไรสะสม', 'ใส่ **ต้นทุน** ไม่ใช่มูลค่าตลาด · ของที่ซื้อเป็นสกุลต่างประเทศให้คิดด้วยอัตราวันซื้อ', 914),
  ('opn.related_investment', 'opening', 'ยอดยกมา — เงินลงทุนในบริษัทในเครือ', 'Opening investment in related company', 'transfer'::sri_os.cf_group, 0, 'none', '1710', '3300', false, null, false, false, false, false, false, false, null, null, null, null, false, 'ต้นทุนเงินลงทุนในบริษัทในเครือ ณ วันตัดยอด คู่กับกำไรสะสม — ตัดออกในงบรวม', 'ใส่ **ต้นทุนที่ลงทุนไป** ไม่ใช่มูลค่าตามส่วนได้เสียหรือราคาประเมิน · หุ้นบริษัทนอกตลาด **ห้ามถัวเฉลี่ยต้นทุน** (ลูกพี่สั่ง 25/10) ซื้อหลายครั้งต้องเก็บเป็นล็อตและระบุล็อตตอนขาย', 915),
  ('opn.wht_credit', 'opening', 'ยอดยกมา — ภาษีถูกหัก ณ ที่จ่ายรอเครดิต', 'Opening withholding tax credit', 'transfer'::sri_os.cf_group, 0, 'none', '1800', '3300', false, null, false, false, false, false, false, false, null, null, null, null, false, 'ภาษีที่ถูกผู้จ่ายหักไว้และยังไม่ได้ใช้เครดิต ณ วันตัดยอด เข้ามาเป็นสินทรัพย์ คู่กับกำไรสะสม — ไม่ใช่ค่าใช้จ่าย', 'เป็น **เงินของเราที่กรมสรรพากรถือไว้** รอหักกับภาษีที่ต้องจ่าย ไม่ใช่ค่าใช้จ่ายและไม่ใช่การลงทุน · ยอดต้องตรงกับผลรวมหนังสือรับรองการหักภาษี (50 ทวิ) ที่ยังไม่ได้ใช้', 916),
  ('opn.other_current_asset', 'opening', 'ยอดยกมา — สินทรัพย์หมุนเวียนอื่น', 'Opening other current assets', 'transfer'::sri_os.cf_group, 0, 'none', '1900', '3300', false, null, false, false, false, false, false, false, null, null, null, null, false, 'สินทรัพย์หมุนเวียนที่ไม่เข้าพวกบัญชีเฉพาะ ณ วันตัดยอด คู่กับกำไรสะสม', 'ใช้เฉพาะของที่**ไม่มีบัญชีเฉพาะของตัวเอง** — ลูกหนี้ค่าเช่า/ดอกเบี้ย เงินมัดจำจ่าย ภาษีถูกหัก ณ ที่จ่าย มีบัญชีของตัวเองแล้ว ต้องใช้ตัวนั้น · ถ้าเทของลงบัญชีรองรับ รายงานจะแยกไม่ออกว่าเงินไปอยู่กับอะไร', 917),
  ('opn.other_noncurrent_asset', 'opening', 'ยอดยกมา — สินทรัพย์ไม่หมุนเวียน', 'Opening non-current assets', 'transfer'::sri_os.cf_group, 0, 'none', '1950', '3300', false, null, false, false, false, false, false, false, null, null, null, null, false, 'สินทรัพย์ระยะยาวที่ไม่เข้าพวกบัญชีเฉพาะ ณ วันตัดยอด คู่กับกำไรสะสม', '**ไม่ใช่บัญชีรวมของสินทรัพย์ไม่หมุนเวียนทั้งหมด** — อสังหาฯ เพื่อการลงทุน (1500) ค่ารีโนเวท (1510) หุ้นและหลักทรัพย์ (1700) บริษัทในเครือ (1710) ทองคำ/คริปโต (1720) ก็ไม่หมุนเวียนเหมือนกันแต่มีบัญชีของตัวเอง ต้องใช้ตัวนั้น', 918),
  ('opn.payable', 'opening', 'ยอดยกมา — เจ้าหนี้', 'Opening payables', 'transfer'::sri_os.cf_group, 0, 'none', '3300', '2100', false, null, false, false, false, false, false, false, null, null, null, null, false, 'ยอดที่ค้างจ่ายอยู่ ณ วันตัดยอด เข้ามาเป็นเจ้าหนี้ คู่กับกำไรสะสม', 'ยอดนี้กลายเป็น **ของค้างที่เปิดอยู่** ทันที → ตอนจ่ายให้ใช้หมวดจ่ายเจ้าหนี้ และอ้างใบยอดยกมานี้เป็นรายการต้นทาง', 919),
  ('opn.tenant_deposit', 'opening', 'ยอดยกมา — เงินมัดจำรับจากผู้เช่า', 'Opening tenant deposits received', 'transfer'::sri_os.cf_group, 0, 'none', '3300', '2200', false, null, false, false, false, false, false, false, null, null, null, null, false, 'เงินมัดจำที่รับจากผู้เช่าและยังถืออยู่ ณ วันตัดยอด เข้ามาเป็นหนี้สิน คู่กับกำไรสะสม — ไม่ใช่รายได้', 'เงินมัดจำเป็น **หนี้ที่ต้องคืน** → ตอนคืนให้ใช้หมวดคืนมัดจำ ไม่ใช่ลงเป็นค่าใช้จ่าย · ยอดต้องตรงกับที่ระบุในสัญญาเช่าที่ยังมีผลทุกฉบับรวมกัน', 920),
  ('opn.intercompany_payable', 'opening', 'ยอดยกมา — เจ้าหนี้ระหว่างกัน (ในกองกลาง)', 'Opening intercompany payable', 'transfer'::sri_os.cf_group, 0, 'none', '3300', '2310', false, null, false, false, false, false, false, false, null, null, null, null, false, 'ยอดที่ผู้ถือนี้ค้างอยู่กับผู้ถืออื่นในกองกลาง ณ วันตัดยอด คู่กับกำไรสะสม — ตัดออกในงบรวม', 'ลงทีละผู้ถือได้ (ไม่บังคับให้มาครบคู่ในใบเดียว) **แต่เมื่อนำเข้าครบทุกผู้ถือแล้ว ยอดเจ้าหนี้ระหว่างกันรวมต้องเท่ากับยอดลูกหนี้ระหว่างกันรวมพอดี** — ตรวจด้วยรายงานกระทบยอดรายการระหว่างกัน', 921),
  ('opn.loan_director', 'opening', 'ยอดยกมา — เงินกู้ยืมกรรมการ (เงินต้นคงเหลือ)', 'Opening director loans', 'transfer'::sri_os.cf_group, 0, 'none', '3300', '2300', false, null, false, false, false, false, false, false, null, null, null, null, false, 'เงินต้นคงเหลือของเงินกู้จากกรรมการ ณ วันตัดยอด คู่กับกำไรสะสม', null, 922),
  ('opn.loan_other', 'opening', 'ยอดยกมา — เงินกู้ยืมอื่น (เงินต้นคงเหลือ)', 'Opening other loans', 'transfer'::sri_os.cf_group, 0, 'none', '3300', '2400', false, null, false, false, false, false, false, false, null, null, null, null, false, 'เงินต้นคงเหลือของเงินกู้อื่น ณ วันตัดยอด คู่กับกำไรสะสม', null, 923),
  ('opn.loan_bank', 'opening', 'ยอดยกมา — เงินกู้ธนาคาร (เงินต้นคงเหลือ)', 'Opening bank loans', 'transfer'::sri_os.cf_group, 0, 'none', '3300', '2410', false, null, false, false, false, false, false, false, null, null, null, null, false, 'เงินต้นคงเหลือของเงินกู้ธนาคาร ณ วันตัดยอด คู่กับกำไรสะสม', 'ใส่ **เงินต้นคงเหลือ** ตาม statement ของธนาคาร ไม่ใช่วงเงินกู้ และไม่รวมดอกเบี้ยที่ยังไม่ถึงกำหนด', 924),
  ('opn.other_current_liability', 'opening', 'ยอดยกมา — หนี้สินหมุนเวียนอื่น', 'Opening other current liabilities', 'transfer'::sri_os.cf_group, 0, 'none', '3300', '2500', false, null, false, false, false, false, false, false, null, null, null, null, false, 'หนี้สินระยะสั้นที่ไม่เข้าพวกบัญชีเฉพาะ ณ วันตัดยอด คู่กับกำไรสะสม', 'ใช้เฉพาะของที่**ไม่มีบัญชีเฉพาะของตัวเอง** — เจ้าหนี้ (2100) เงินมัดจำรับจากผู้เช่า (2200) มีบัญชีของตัวเองแล้ว ต้องใช้ตัวนั้น ไม่งั้นรายงานอายุเจ้าหนี้แยกไม่ออก', 925),
  ('opn.other_noncurrent_liability', 'opening', 'ยอดยกมา — หนี้สินไม่หมุนเวียน', 'Opening non-current liabilities', 'transfer'::sri_os.cf_group, 0, 'none', '3300', '2600', false, null, false, false, false, false, false, false, null, null, null, null, false, 'หนี้สินระยะยาวที่ไม่เข้าพวกบัญชีเฉพาะ ณ วันตัดยอด คู่กับกำไรสะสม', '**ไม่ใช่บัญชีรวมของหนี้สินไม่หมุนเวียนทั้งหมด** — เงินกู้ธนาคาร (2410) เงินกู้ยืมกรรมการ (2300) เงินกู้ยืมอื่น (2400) มีบัญชีของตัวเองแล้ว ต้องใช้ตัวนั้น ไม่งั้นดูไม่ออกว่าหนี้ก้อนไหนเป็นของใครและครบกำหนดเมื่อไร', 926),
  ('opn.capital', 'opening', 'ยอดยกมา — แยกทุนตั้งต้นออกจากกำไรสะสม', 'Opening capital reclassification', 'transfer'::sri_os.cf_group, 0, 'none', '3300', '3100', false, null, false, false, false, false, false, false, null, null, null, null, false, 'ย้ายส่วนที่เป็นทุนตั้งต้นออกจากกำไรสะสม — ยอดรวมของส่วนของเจ้าของไม่เปลี่ยน แค่แยกให้ตรงกับที่ประกาศไว้ในไฟล์ยอดตั้งต้น', 'ลงใบนี้เป็นใบสุดท้ายของการนำเข้า — ทุกบรรทัดสินทรัพย์/หนี้สินลงคู่กับกำไรสะสมก่อน แล้วใบนี้ค่อยแยกส่วนที่เป็นทุนตั้งต้นออก · ยอดรวมส่วนของเจ้าของไม่เปลี่ยน งบดุลจึงยังดุล', 927)
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
 where code not in ('inc.rent', 'inc.hire_purchase', 'inc.interest_srr', 'inc.interest_mortgage', 'inc.interest_loan', 'inc.interest_loan_secured', 'inc.dividend', 'inc.key_money', 'inc.fee', 'inc.bad_debt_recovered', 'inc.other', 'exp.common', 'exp.utilities', 'exp.repair', 'exp.furnishing', 'exp.cleaning', 'exp.commission', 'exp.referral', 'exp.marketing', 'exp.land_office', 'exp.tax', 'exp.legal', 'exp.bank_charge', 'exp.salary', 'exp.travel', 'exp.office', 'exp.other', 'inv.buy_re', 'inv.capex', 'inv.srr_out', 'inv.mortgage_out', 'inv.lend', 'inv.lend_secured', 'inv.buy_securities', 'inv.buy_commodity', 'inv.deposit_paid', 'inv.other_current_asset', 'inv.other_noncurrent_asset', 'inv.sell_re', 'inv.sell_re_held_for_sale', 'inv.srr_redeem', 'inv.mortgage_redeem', 'inv.loan_back', 'inv.loan_back_secured', 'inv.sell_securities', 'inv.sell_commodity', 'inv.deposit_returned', 'inv.other_current_asset_back', 'inv.other_noncurrent_asset_back', 'inv.collect_rent', 'inv.collect_interest', 'inv.wht_refund', 'fin.loan_bank', 'fin.loan_director', 'fin.loan_other', 'fin.capital', 'fin.deposit_received', 'fin.other_current_liability_in', 'fin.other_noncurrent_liability_in', 'fin.repay_bank', 'fin.repay_director', 'fin.interest_paid', 'fin.drawings', 'fin.deposit_refund', 'fin.other_current_liability_out', 'fin.other_noncurrent_liability_out', 'fin.pay_payable', 'trf.internal', 'trf.fx_translate_up', 'trf.fx_translate_down', 'trf.fx_acquire', 'trf.fx_convert', 'adj.doubtful', 'adj.doubtful_release', 'adj.writeoff_rent', 'adj.writeoff_interest', 'adj.writeoff_other', 'adj.reclass_re_to_sale', 'adj.reclass_re_to_rental', 'adj.revalue_securities_up', 'adj.revalue_securities_down', 'adj.revalue_commodity_up', 'adj.revalue_commodity_down', 'opn.cash', 'opn.receivable_rent', 'opn.receivable_interest', 'opn.receivable_other', 'opn.allowance', 'opn.intercompany_receivable', 'opn.loan_principal', 'opn.loan_secured_principal', 'opn.srr_principal', 'opn.mortgage_principal', 'opn.property', 'opn.renovation', 'opn.deposit_paid', 'opn.securities', 'opn.gold_alt', 'opn.related_investment', 'opn.wht_credit', 'opn.other_current_asset', 'opn.other_noncurrent_asset', 'opn.payable', 'opn.tenant_deposit', 'opn.intercompany_payable', 'opn.loan_director', 'opn.loan_other', 'opn.loan_bank', 'opn.other_current_liability', 'opn.other_noncurrent_liability', 'opn.capital')
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

  raise notice 'seed ตารางกฎครบ: ผังบัญชี 66 รหัส · ประเภทรายการ 111 หมวด · คู่บัญชีระหว่างกัน 4 ลักษณะ';
end $do$;
