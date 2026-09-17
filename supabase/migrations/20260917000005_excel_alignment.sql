-- ============================================================
-- SRI OS · 005 ปรับตาม Excel จริง + seed ผังบัญชี
--
-- ทำอะไร: เติมคอลัมน์ที่พบใน Asset Register จริง และ seed ผังบัญชี 41+ รหัส
-- ที่มา: SRI_Transaction_ERP.xlsx (ชีท Setup), SRI_Balance_Sheet_Asset_Register.xlsx
-- ย้อนกลับ: alter table ... drop column ...; delete from chart_of_accounts;
-- ============================================================

set search_path = sri_os, public;

-- ---------- คอลัมน์ที่ Excel มีแต่ schema ยังไม่มี ----------

-- Asset Register มี "สัดส่วน (Own %)" แยกจากผู้ถือกรรมสิทธิ์
alter table assets add column if not exists ownership_pct numeric(5,4) not null default 1
  check (ownership_pct > 0 and ownership_pct <= 1);

-- Asset Register มี "แหล่งเงินทุน" เช่น "เงินหมุนจากเปรมสิริ", "ทุนป๊า (สุธี)"
-- PLAN.md หัวข้อ 5.1 ก็บังคับให้เก็บแหล่งเงินตอนเลือก owner
alter table assets add column if not exists funding_source text;

-- Asset Register แยก "ประเภททรัพย์" (คอนโด/บ้าน/ที่ดิน) ออกจากหมวดหมู่
alter table assets add column if not exists property_type text;
alter table assets add column if not exists size_note text;

-- เหตุผลที่เลือก owner รายนี้ (PLAN.md 5.1 บังคับ)
alter table transactions add column if not exists owner_reason text;
alter table transactions add column if not exists funding_source text;

-- บัญชีธนาคารต้องรองรับกระเป๋าที่ไม่ใช่ธนาคารด้วย (เงินสดในมือ/แคชเชียร์เช็ค/บัตรเครดิต)
alter table bank_accounts add column if not exists channel_type text not null default 'bank'
  check (channel_type in ('bank', 'petty_cash', 'cashier_cheque', 'credit_card', 'other'));

-- Asset Management sheet มี "ผู้ดูแล" แยกจากผู้ถือกรรมสิทธิ์ — มี manager_user_id แล้ว
-- และมี "เบอร์ติดต่อ" ของคู่สัญญา — อยู่ใน contacts แล้ว

-- ---------- seed ผังบัญชี ----------
-- ถ้ามีอยู่แล้วให้อัปเดตชื่อ ไม่สร้างซ้ำ
insert into chart_of_accounts (code, name_th, name_en, type, sort_order) values
  ('1100', 'เงินสดและเงินฝากธนาคาร',            'Cash & bank',                  'asset',     100),
  ('1200', 'ลูกหนี้ค่าเช่า',                     'Rent receivable',              'asset',     120),
  ('1210', 'ลูกหนี้ดอกเบี้ย',                    'Interest receivable',          'asset',     121),
  ('1300', 'เงินให้กู้ยืม - เงินต้น',            'Loan principal receivable',    'asset',     130),
  ('1400', 'เงินลงทุนขายฝาก - เงินต้น',          'Redemption principal',         'asset',     140),
  ('1410', 'เงินลงทุนจำนอง - เงินต้น',           'Mortgage principal',           'asset',     141),
  ('1500', 'อสังหาริมทรัพย์เพื่อการลงทุน',        'Investment property',          'asset',     150),
  ('1510', 'ค่ารีโนเวท (บันทึกเป็นทุน)',          'Renovation capitalised',       'asset',     151),
  ('1600', 'เงินมัดจำจ่าย',                      'Deposits paid',                'asset',     160),
  ('1700', 'เงินลงทุนในหลักทรัพย์',              'Investment in securities',     'asset',     170),
  ('2100', 'เจ้าหนี้การค้า-เจ้าหนี้อื่น',         'Trade & other payables',       'liability', 210),
  ('2200', 'เงินมัดจำรับจากผู้เช่า',              'Tenant deposits received',     'liability', 220),
  ('2300', 'เงินกู้ยืมกรรมการ',                  'Director loan',                'liability', 230),
  ('2400', 'เงินกู้ยืมอื่น',                     'Other loans',                  'liability', 240),
  ('2410', 'เงินกู้ธนาคาร',                      'Bank borrowing',               'liability', 241),
  ('3100', 'ทุนตั้งต้น',                         'Paid-in capital',              'equity',    310),
  ('3200', 'เงินถอนของเจ้าของ',                  'Drawings',                     'equity',    320),
  ('4100', 'ดอกเบี้ยรับ - ขายฝาก',               'Interest income - Redemption', 'income',    410),
  ('4110', 'ดอกเบี้ยรับ - จำนอง',                'Interest income - Mortgage',   'income',    411),
  ('4120', 'ดอกเบี้ยรับ - เงินให้กู้ยืม',         'Interest income - Loan',       'income',    412),
  ('4200', 'รายได้ค่าเช่า',                      'Rental income',                'income',    420),
  ('4210', 'รายได้ค่าเช่าซื้อ',                  'Hire-purchase income',         'income',    421),
  ('4300', 'กำไรจากการขายทรัพย์',                'Gain on sale of property',     'income',    430),
  ('4310', 'เงินกินเปล่า',                       'Key money',                    'income',    431),
  ('4400', 'ค่าคอมมิชชั่น-ค่าธรรมเนียมรับ',       'Fee & commission income',      'income',    440),
  ('4410', 'เงินปันผลรับ',                       'Dividend income',              'income',    441),
  ('4900', 'รายได้อื่น',                         'Other income',                 'income',    490),
  ('5100', 'ค่าส่วนกลาง',                        'Common area fee',              'expense',   510),
  ('5110', 'ค่าน้ำ-ค่าไฟ',                       'Utilities',                    'expense',   511),
  ('5120', 'ค่าซ่อมแซม-บำรุงรักษา',              'Repair & maintenance',         'expense',   512),
  ('5130', 'ค่าตกแต่ง-เฟอร์นิเจอร์',             'Furnishing & fit-out',         'expense',   513),
  ('5140', 'ค่าแม่บ้าน-ทำความสะอาด',             'Cleaning & housekeeping',      'expense',   514),
  ('5200', 'ค่าคอมมิชชั่นจ่าย',                  'Commission expense',           'expense',   520),
  ('5210', 'ค่านายหน้า-ค่าแนะนำ',                'Referral fee',                 'expense',   521),
  ('5220', 'ค่าการตลาด-โฆษณา',                   'Marketing & advertising',      'expense',   522),
  ('5300', 'ค่าธรรมเนียมกรมที่ดิน',              'Land office fees',             'expense',   530),
  ('5310', 'ภาษีและอากรแสตมป์',                  'Taxes & stamp duty',           'expense',   531),
  ('5320', 'ค่าทนาย-ค่าทำสัญญา',                 'Legal & contract fees',        'expense',   532),
  ('5330', 'ค่าธรรมเนียมธนาคาร',                 'Bank charges',                 'expense',   533),
  ('5400', 'ดอกเบี้ยจ่าย',                       'Interest expense',             'expense',   540),
  ('5500', 'เงินเดือน-ค่าแรง',                   'Salary & wages',               'expense',   550),
  ('5510', 'ค่าเดินทาง-น้ำมัน',                  'Travel & fuel',                'expense',   551),
  ('5520', 'ค่าใช้จ่ายสำนักงาน',                 'Office expenses',              'expense',   552),
  ('5900', 'ค่าใช้จ่ายอื่น',                     'Other expenses',               'expense',   590)
on conflict (code) do update
  set name_th = excluded.name_th,
      name_en = excluded.name_en,
      type    = excluded.type,
      sort_order = excluded.sort_order;

-- ---------- seed หมวดทรัพย์ ----------
insert into asset_classes (code, name_th, sort_order) values
  ('RE',        'Real Estate', 10),
  ('FINANCE',   'Finance',     20),
  ('INVESTMENT','Investment',  30),
  ('BUSINESS',  'Business',    40)
on conflict (code) do nothing;

insert into asset_categories (class_id, code, name_th, sort_order)
select c.id, v.code, v.name_th, v.sort_order
  from (values
    ('RE',         'RE_FOR_SALE',  'รอขาย',                    10),
    ('RE',         'RE_RENTAL',    'ปล่อยเช่า',                 20),
    ('RE',         'RE_SRR',       'รับจำนอง-ขายฝาก',           30),
    ('RE',         'RE_PROJECT',   'Project',                  40),
    ('RE',         'RE_RENOVATE',  'รอปรับปรุง',                50),
    ('FINANCE',    'FIN_BUSINESS', 'Business',                 10),
    ('FINANCE',    'FIN_BOND',     'Bond',                     20),
    ('FINANCE',    'FIN_LOAN',     'Loan Agreement',           30),
    ('INVESTMENT', 'INV_STOCK',    'Stock',                    10),
    ('INVESTMENT', 'INV_ETF',      'ETF',                      20),
    ('INVESTMENT', 'INV_FUND',     'Fund',                     30),
    ('INVESTMENT', 'INV_CRYPTO',   'Crypto',                   40),
    ('INVESTMENT', 'INV_GOLD',     'Gold',                     50)
  ) as v(class_code, code, name_th, sort_order)
  join asset_classes c on c.code = v.class_code
on conflict (code) do nothing;

-- ---------- seed owners ----------
-- ตาม PLAN.md: Corporate 3 + Personal 3
-- ⚠ Excel จริงมีบุคคลมากกว่านี้ (สุธี สุดจิตต์ ชลานุช นิภาพร สมาน นุช)
--   ยังไม่ seed เพราะต้องยืนยันก่อนว่าเป็น owner หรือเป็นแค่ contact — ดู docs/DECISIONS.md Q-A
insert into owners (code, type, policy, name_th, name_en, status, color, sort_order) values
  ('SRI_CORP',    'company', 'corporate_strict',  'SRI Corporation', 'SRI Corporation Co., Ltd.', 'active',  '#004AAD', 10),
  ('SRI_HOLDING', 'company', 'corporate_strict',  'SRI Holding',     'SRI Holding',               'planned', '#004AAD', 20),
  ('SRI_CAPITAL', 'company', 'corporate_strict',  'SRI Capital',     'SRI Capital',               'planned', '#004AAD', 30),
  ('THANAKORN',   'person',  'personal_flexible', 'ธนากร',           'Thanakorn',                 'active',  '#7A5AF8', 40),
  ('THANAWIN',    'person',  'personal_flexible', 'ธนวินท์',          'Thanawin',                  'active',  '#7A5AF8', 50),
  ('BENJAPORN',   'person',  'personal_flexible', 'เบ็ญจพร',         'Benjaporn',                 'active',  '#7A5AF8', 60)
on conflict (code) do update
  set name_th = excluded.name_th, policy = excluded.policy, status = excluded.status;
