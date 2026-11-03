-- ============================================================
-- SRI OS · เปลี่ยนหมวดใหญ่ของทรัพย์เป็น 4 หมวดที่ลูกพี่กำหนด (26/09)
--
--   Businesses · Real Estate · Paper Asset · Commodity & Cash
--
-- ของเดิมคือ RE / FINANCE / INVESTMENT / BUSINESS ซึ่งเป็นคนละชุด
-- หมวดย่อยเดิมต้องย้ายพ่อแม่ใหม่ ไม่ใช่แค่เปลี่ยนชื่อ:
--   FIN_BUSINESS  → Businesses      (เป็นธุรกิจ ไม่ใช่ตราสาร)
--   FIN_BOND/LOAN → Paper Asset     (สิทธิเรียกร้องที่มีผู้ออก)
--   INV_STOCK/ETF/FUND → Paper Asset
--   INV_GOLD/CRYPTO    → Commodity & Cash (ถือตัวสินทรัพย์เอง ไม่มีผู้ออก)
--   RE_*          → Real Estate     (รวม RE_SRR ขายฝาก/จำนอง ตามที่ลูกพี่ระบุ)
--
-- ปลอดภัยที่จะทำตอนนี้เพราะตาราง assets ยังว่าง (ตรวจแล้ว 0 แถว)
-- ถ้ามีข้อมูลแล้วจะย้ายยากกว่านี้มาก
--
-- ย้อนกลับ: restore จาก backup — การย้าย class ของ category เป็น destructive
-- ============================================================

set search_path = sri_os, public;

-- ---------- หมวดใหญ่ชุดใหม่ ----------
insert into asset_classes (code, name_th, sort_order) values
  ('BIZ',       'Businesses',       10),
  ('RE',        'Real Estate',      20),
  ('PAPER',     'Paper Asset',      30),
  ('COMMODITY', 'Commodity & Cash', 40)
on conflict (code) do update set
  name_th    = excluded.name_th,
  sort_order = excluded.sort_order;

-- ---------- ย้ายหมวดย่อยเดิมไปอยู่ใต้หมวดใหญ่ใหม่ ----------
update asset_categories c set class_id = k.id, code = v.new_code, name_th = v.name_th, sort_order = v.sort_order
  from (values
    ('RE_RENTAL',    'RE_RENTAL',    'RE',        'ปล่อยเช่า',                 10),
    ('RE_FOR_SALE',  'RE_FOR_SALE',  'RE',        'รอขาย',                    20),
    ('RE_PROJECT',   'RE_PROJECT',   'RE',        'โครงการระหว่างพัฒนา',        30),
    ('RE_RENOVATE',  'RE_RENOVATE',  'RE',        'รอปรับปรุง',                40),
    ('RE_SRR',       'RE_SRR',       'RE',        'ขายฝาก / รับจำนอง',         50),
    ('FIN_BUSINESS', 'BIZ_OPERATING','BIZ',       'เงินลงทุนในกิจการ',          10),
    ('FIN_BOND',     'PAPER_BOND',   'PAPER',     'พันธบัตร / หุ้นกู้',          40),
    ('FIN_LOAN',     'PAPER_LOAN',   'PAPER',     'สัญญาเงินให้กู้ยืม',          50),
    ('INV_STOCK',    'PAPER_STOCK',  'PAPER',     'หุ้น',                      10),
    ('INV_ETF',      'PAPER_ETF',    'PAPER',     'ETF',                      20),
    ('INV_FUND',     'PAPER_FUND',   'PAPER',     'กองทุน',                    30),
    ('INV_GOLD',     'COM_GOLD',     'COMMODITY', 'ทองคำ',                     10),
    ('INV_CRYPTO',   'COM_CRYPTO',   'COMMODITY', 'คริปโต',                    20)
  ) as v(old_code, new_code, class_code, name_th, sort_order)
  join asset_classes k on k.code = v.class_code
 where c.code = v.old_code;

-- ---------- หมวดย่อยที่ยังไม่เคยมี ----------
insert into asset_categories (class_id, code, name_th, sort_order)
select k.id, v.code, v.name_th, v.sort_order
  from (values
    ('BIZ',       'BIZ_RELATED', 'บริษัทในเครือ',        20),
    ('COMMODITY', 'COM_CASH',    'เงินสดและเงินฝาก',      30)
  ) as v(class_code, code, name_th, sort_order)
  join asset_classes k on k.code = v.class_code
on conflict (code) do update set
  class_id   = excluded.class_id,
  name_th    = excluded.name_th,
  sort_order = excluded.sort_order;

-- ---------- ย้าย class_id ของทรัพย์ที่มีอยู่ให้ตามหมวดย่อยไปด้วย ----------
-- `assets` เก็บ class_id ไว้ซ้ำกับ category_id · การย้าย category ข้าม class ข้างบน
-- ทำให้แถวเดิมชี้ไป class เก่าค้างอยู่ โดยที่ trigger ไม่ยิง (ยิงเฉพาะตอน insert/update คอลัมน์นั้น)
-- ฐานข้อมูลที่มีทรัพย์จริงจะรายงานคนละหมวดในคนละหน้าโดยไม่มีอะไรฟ้อง
update assets a
   set class_id = c.class_id
  from asset_categories c
 where c.id = a.category_id
   and a.class_id is distinct from c.class_id;

-- กันไม่ให้ migration ผ่านไปทั้งที่ยังเหลือแถวที่ไม่ตรง
do $$
declare
  n int;
begin
  select count(*) into n
    from assets a join asset_categories c on c.id = a.category_id
   where a.class_id is distinct from c.class_id;
  if n > 0 then
    raise exception 'ยังมีทรัพย์ % แถวที่หมวดใหญ่ไม่ตรงกับหมวดย่อย — หยุดก่อน', n;
  end if;
end $$;

-- ---------- ลบหมวดใหญ่เดิมที่ไม่มีลูกแล้ว ----------
delete from asset_classes c
 where c.code in ('FINANCE', 'INVESTMENT', 'BUSINESS')
   and not exists (select 1 from asset_categories x where x.class_id = c.id)
   and not exists (select 1 from assets a where a.class_id = c.id);

-- ถ้าลบไม่หมด แปลว่ายังมีอะไรอ้างอยู่ ต้องรู้ ไม่ใช่ปล่อยให้เหลือ class กำพร้า
do $$
declare
  n int;
begin
  select count(*) into n from asset_classes where code in ('FINANCE', 'INVESTMENT', 'BUSINESS');
  if n > 0 then
    raise exception 'ลบหมวดใหญ่เดิมไม่หมด เหลือ % — มีหมวดย่อยหรือทรัพย์อ้างอยู่', n;
  end if;
end $$;

-- ---------- บัญชีใหม่สำหรับทองคำ/สินทรัพย์ทางเลือก ----------
-- ต้องแยกจาก 1700 เงินลงทุนในหลักทรัพย์ ไม่งั้นแยก Commodity ออกจาก Paper Asset ไม่ได้
insert into chart_of_accounts (code, name_th, name_en, type, sort_order) values
  ('1720', 'เงินลงทุนในทองคำและสินทรัพย์ทางเลือก', 'Gold & alternative assets', 'asset', 172)
on conflict (code) do update set
  name_th = excluded.name_th,
  name_en = excluded.name_en;

-- ---------- กันไม่ให้ class กับ category ของทรัพย์ขัดกันเอง ----------
-- `assets` เก็บทั้ง class_id และ category_id ซึ่งอาจชี้คนละหมวดได้
-- ทรัพย์ชิ้นเดียวโผล่สองหมวดในรายงานคนละหน้า แล้วยอดรวมไม่ตรงกันโดยไม่มีอะไรฟ้อง
create or replace function fn_asset_class_matches_category()
returns trigger language plpgsql set search_path = sri_os, public as $fn$
declare
  v_class uuid;
begin
  select class_id into v_class from asset_categories where id = new.category_id;
  if v_class is null then
    raise exception 'ไม่พบหมวดย่อยของทรัพย์ %', new.category_id;
  end if;
  if new.class_id <> v_class then
    raise exception 'หมวดใหญ่ของทรัพย์ไม่ตรงกับหมวดย่อย — หมวดย่อยนี้อยู่ใต้หมวดใหญ่อื่น';
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_asset_class_matches_category on assets;
create trigger trg_asset_class_matches_category
  before insert or update of class_id, category_id on assets
  for each row execute function fn_asset_class_matches_category();
