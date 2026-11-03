-- ============================================================
-- SRI OS · **ใครเฉลี่ยต้นทุนได้ ใครห้าม** — ลูกพี่สั่งเอง 25/10 (ย้ำสองรอบ)
--
-- > "แยกทรัพย์สินแม้จะอยู่คอนโดเดียวกัน แต่คนละห้องก็แยก
-- >  **จะไม่นำต้นทุนมาคำนวณหรือเฉลี่ยเด็ดขาด ไม่ใช่หุ้นหรือคริปโต**"
-- > "ห้ามเฉลี่ยต้นทุนในทุกทรัพย์สิน อสังหา และ อื่นๆ **มีเฉพาะหุ้น หรือ คริปโต
-- >  เท่านั้นที่เฉลี่ยในตลาดเท่านั้น หุ้นบริษัทนอกตลาดไม่เกี่ยว**"
-- > ยืนยันเพิ่มภายหลัง: **ทองคำเฉลี่ยได้**
--
-- **เฉลี่ยได้สามอย่างเท่านั้น**: หุ้นในตลาดหลักทรัพย์ · คริปโต · ทองคำ
-- **ที่เหลือห้ามทั้งหมด** รวมหุ้นบริษัทนอกตลาด · ETF · กองทุน · พันธบัตร ·
-- อสังหาฯ ทุกชนิด · ที่ดิน · โครงการ · เงินให้กู้ · ขายฝาก · จำนอง · เงินมัดจำ ·
-- สินทรัพย์ทางเลือกอื่นที่ไม่ใช่ทอง (นาฬิกา · งานศิลปะ · ของสะสม)
--
-- ------------------------------------------------------------
-- **ช่องว่างที่ไฟล์นี้ปิด (ตรวจแล้วว่าวันนี้ยังไม่มีอะไรห้าม)**
--
-- `sri_os.assets` ไม่มีคอลัมน์ไหนตอบได้ว่าทรัพย์ชิ้นนี้เฉลี่ยได้หรือไม่
-- (`class_id` · `category_id` · `property_type` · `ticker` · `units` ตอบไม่ได้ทั้งนั้น)
-- และทั้ง 20261025000008 (ทะเบียนล็อต) กับ 20261025000002 (ต้นทุนถัวเฉลี่ย)
-- **ไม่จำกัดประเภททรัพย์เลย** → วันนี้ยังทำสิ่งต่อไปนี้ได้ทั้งหมด:
--
--   1. สร้างล็อตหลายล็อตให้ **คอนโดหนึ่งห้อง** แล้วตัดต้นทุนแบบถัวเฉลี่ย
--   2. ขายคอนโด **30%** โดยตัดต้นทุนไป 30%
--   3. เอา **หุ้นบริษัทนอกตลาด** สองล็อตคนละราคามาเฉลี่ยกัน
--   4. เอา **นาฬิกา/งานศิลปะใน `1720`** มาเฉลี่ยกับทองคำ เพราะใช้รหัสบัญชีเดียวกัน
--
-- ตัวเลขที่วัดได้ (เทสต์ `zz_asset_cost_basis_mode_test.sql`):
--   W1 คอนโดสองห้อง ต้นทุน 3,000,000 / 5,000,000 · ขายห้องแรก 3,500,000
--      ถูก (ต้นทุนของห้องนั้นเอง)  → กำไร **+500,000**
--      ผิด (เฉลี่ยเป็น 4,000,000) → กำไร **−500,000**   ต่างกัน 1,000,000
--   S1 หุ้นนอกตลาด ล็อต A 100 หุ้น 1,000,000 · ล็อต B 100 หุ้น 3,000,000
--      ขายล็อต A ทั้งล็อตได้ 1,200,000
--      ถูก (ต้นทุนล็อต A)        → กำไร **+200,000**
--      ผิด (เฉลี่ย 2,000,000)    → ขาดทุน **−800,000**   ต่างกัน 1,000,000
--   งบดุลยังดุลทั้งสองทางในทุกเคส — ความผิดนี้ไม่มีอะไรฟ้องเลยถ้าไม่มีด่าน
--
-- ------------------------------------------------------------
-- **ตัวแยกอยู่ที่ `asset_categories.cost_basis_mode` จุดเดียว**
--
-- D-115: ด่านที่ตัดสินเรื่องเงินต้องอ่านจาก**ข้อมูลอ้างอิง** ไม่ใช่ป้ายที่ผู้เรียกตั้ง
--   - `asset_categories` เป็นตารางอ้างอิง **อ่านได้เท่านั้น** (20261007000006
--     ไม่มี policy เขียนเลย) → เปลี่ยนค่าได้ด้วย migration เท่านั้น = มีประวัติใน git
--   - `assets.category_id` เป็น `not null` + FK → ทรัพย์ทุกชิ้นได้คำตอบเดียวแน่นอน
--     และคำตอบนั้นมาจาก**หมวดที่เลือกตอนสร้างทรัพย์** ซึ่งเป็นการตั้งค่าอย่างตั้งใจ
--     ไม่ใช่ฟิลด์ที่แต่งได้ต่อรายการ
--
-- **ห้ามใช้รหัสบัญชีตัดสิน และห้ามอนุมานจาก `ticker`** — ข้อนี้บังคับด้วยรูปของข้อมูล:
--   - `1700` มีทั้ง `PAPER_STOCK_LISTED` (เฉลี่ยได้) และ `PAPER_STOCK_PRIVATE`
--     (ห้าม) → รหัสบัญชีตัดสินแทนไม่ได้
--   - `1720` มีทั้ง `COM_GOLD` (เฉลี่ยได้) และ `COM_ALT` (ห้าม) → เช่นกัน
--   - `assets.ticker` เว้นได้และกรอกผิดได้ → ไม่มีด่านไหนในไฟล์นี้อ่านมันเลย
--   เทสต์ L/G พิสูจน์ทั้งสองคู่นี้ตรงๆ (คู่ละสองทิศในรหัสบัญชีเดียวกัน)
--
-- ------------------------------------------------------------
-- **สามค่า ไม่ใช่สอง — และไม่ได้ขัดกันเอง**
--
--   | ค่า | ความหมาย | ใช้กับ |
--   |---|---|---|
--   | `average`      | ถัวเฉลี่ยถ่วงน้ำหนักทั้งกอง (D-112) | หุ้นในตลาด · คริปโต · ทองคำ |
--   | `specific_lot` | เก็บล็อต **ระบุล็อตที่ขาย** ต้นทุนมาจากล็อตนั้นเอง | หุ้นนอกตลาด · ETF · กองทุน · พันธบัตร |
--   | `whole_item`   | ทรัพย์ชิ้นเดียว **แบ่งไม่ได้** ตัดทั้งก้อน | อสังหาฯ · ที่ดิน · สัญญา · กิจการ · ของสะสม |
--
-- คำถามของลูกพี่ ("เฉลี่ยได้ไหม") มีคำตอบเดียวคือ `cost_basis_mode = 'average'`
-- ส่วน `specific_lot` กับ `whole_item` **ห้ามเฉลี่ยเหมือนกัน** ต่างกันแค่
-- **แบ่งขายได้หรือไม่** ซึ่งเป็นคำถามคนละข้อและจำเป็น:
--   หุ้นนอกตลาดซื้อสามครั้ง = สามล็อตจริง และขายล็อตใดล็อตหนึ่งได้
--   คอนโดหนึ่งห้องแบ่งขาย 30% ไม่ได้เลย
-- ถ้ายุบเป็นค่าเดียวต้องเลือกระหว่าง "ห้ามขายล็อตหุ้นนอกตลาด" (ปฏิเสธงานที่ถูก)
-- หรือ "ยอมให้ขายคอนโดบางส่วน" (ยอมตัวเลขที่ผิด) — ทั้งคู่ผิด
--
-- **ค่าตั้งต้นคือ `whole_item`** (เข้มที่สุด) ทั้งที่ `default` ของคอลัมน์และที่
-- `fn_asset_cost_basis_mode()` (หาหมวด/ทรัพย์ไม่เจอ → `whole_item`)
-- เพราะเผลอแล้วต้องได้ **การปฏิเสธเสียงดัง** ไม่ใช่การเฉลี่ยเงียบๆ ·
-- ฝั่งโค้ด `costBasisModeOfCategory()` ใน `src/lib/rules/asset-classes.ts`
-- ใช้กฎเดียวกันตัวต่อตัว และเทสต์อ่านไฟล์นี้มาเทียบว่าสองฝั่งตรงกัน
--
-- ------------------------------------------------------------
-- **ทะเบียนล็อตยังเก็บเหมือนเดิมทุกชนิด** (ล็อต = ข้อมูล · การเฉลี่ย = วิธีคิด)
--
-- ที่เปลี่ยนคือ **วิธีตรวจต้นทุนที่ตัด** ซึ่งอยู่ใน
-- `fn_assert_lot_consumption_sane_for()` **ฟังก์ชันเดิม ที่เดียว** (เขียนทับ
-- รุ่น 20261025000008 ด้วยลายเซ็นเดิม) ไม่ใช่สร้างด่านตัวที่สองมาขัดกับตัวแรก:
--   - `average`      → สมการถัวเฉลี่ยทั้งกองของ D-112 (เหมือนเดิมเป๊ะ)
--   - `specific_lot` → ต้นทุนที่ตัดจากแต่ละล็อตต้องเท่ากับ **ราคาของล็อตนั้นเอง**
--   - `whole_item`   → ต้องตัดออก **ทั้งก้อน** (เหลือ 0 หน่วย 0 บาท)
--
-- **ทรัพย์ `whole_item` มีล็อตได้ไม่เกินหนึ่ง** — เหตุผล: ล็อตคือ "ของที่ซื้อมา
-- ครั้งหนึ่ง จำนวนเท่านี้ ราคาเท่านี้" ส่วน `whole_item` คือของชิ้นเดียวที่ซื้อ
-- ครั้งเดียว · คอนโดห้องเดิมซื้อสองครั้งไม่มีอยู่จริง (ถ้าซื้อห้องที่สองก็เป็น
-- **ทรัพย์คนละแถว**) · ล็อตหลายล็อตบนของชิ้นเดียวจึงเป็น**รูปร่างของการเฉลี่ย**
-- ล้วนๆ และเป็นรูปที่บรีฟสั่งให้ปฏิเสธโดยตรง · ทรัพย์ `specific_lot`/`average`
-- มีล็อตได้ไม่จำกัดเหมือนเดิม
--
-- ------------------------------------------------------------
-- **ด่านที่ไฟล์นี้เพิ่ม/เปลี่ยน**
--   1. คอลัมน์ `asset_categories.cost_basis_mode` + หมวดใหม่ 3 หมวด
--   2. `fn_asset_cost_basis_mode()` / `fn_asset_can_average()` — ความจริงเดียว
--   3. `fn_asset_average_unit_cost()` — ถามกับทรัพย์ที่ไม่ใช่ `average` → **ปฏิเสธ**
--   4. `fn_assert_lot_consumption_sane_for()` — สามกิ่งตามโหมด (ฟังก์ชันเดิม)
--   5. `trg_lots_single_for_whole_item` — `whole_item` มีล็อตได้ไม่เกินหนึ่ง
--   6. `trg_assert_asset_whole_disposal` — ในสมุด: `whole_item` ตัดต้นทุนทั้งก้อน
--      และล้าง 3400 **ทั้งก้อน** (ไม่ใช่ตามสัดส่วน เพราะไม่มีสัดส่วนให้คิด)
--
-- **ทำไมข้อ 6 ต้องมีแม้มีข้อ 4 แล้ว**: ล็อตไม่ใช่เงื่อนไขของการลงสมุด
-- คอนโดส่วนใหญ่ไม่มีล็อตเลย (ต้นทุนอยู่ในสมุดตรงๆ) → ด่านที่ดูแต่ล็อต
-- มองการขายคอนโด 30% ไม่เห็นแม้แต่นิดเดียว
--
-- **ทำไม `fn_asset_lot_cost()` ไม่ปฏิเสธ แต่ `fn_asset_average_unit_cost()` ปฏิเสธ**
--   - `fn_asset_lot_cost()` คืน **ยอดรวมทั้งก้อน** (บาท) ซึ่งสำหรับทรัพย์ที่ห้ามเฉลี่ย
--     *คือ* "ต้นทุนของชิ้นนั้น/กองนั้นตรงๆ" อยู่แล้ว · ยอดรวมเอาไปคูณสัดส่วนไม่ได้
--     โดยไม่มีตัวหาร และตัวหาร (จำนวนหน่วยทั้งกอง) ถูกปฏิเสธที่ข้อ 3
--   - `fn_asset_average_unit_cost()` คืน **อัตราต่อหน่วยของทั้งกอง** ซึ่งมีความหมาย
--     เดียวคือ "เอาไปคูณจำนวนที่ขาย" = การเฉลี่ย · คืนเลขให้คือเปิดทางให้ใช้ผิด
--     ได้ทุกเมื่อโดยไม่มีใครเห็น จึงต้อง **ดังตอนถาม**
--   เกณฑ์ที่พิสูจน์ได้: *ยอดรวมใช้เฉลี่ยไม่ได้ · อัตราต่อหน่วยใช้ทำอย่างอื่นไม่ได้*
--
-- ------------------------------------------------------------
-- ลำดับ: **ต้องรันหลัง** 20261025000002 · 20261025000008 · 20261020000000/2
--        guard หัวไฟล์ตรวจให้ ไม่ใช่เชื่อลำดับชื่อไฟล์
--
-- idempotent: `add column if not exists` · `on conflict do update` ·
--        `drop ... if exists` ก่อน create ทุกตัว · seed ใช้ update จากรายชื่อตรงๆ
--
-- ย้อนกลับ (rollback):
--   -- drop trigger if exists trg_lots_single_for_whole_item on sri_os.asset_lots;
--   -- drop trigger if exists trg_assert_asset_whole_disposal on sri_os.transaction_lines;
--   -- drop function if exists sri_os.fn_assert_single_lot_for_whole_item();
--   -- drop function if exists sri_os.fn_assert_asset_whole_disposal();
--   -- drop function if exists sri_os.fn_asset_cost_basis_mode_mismatch();
--   -- drop function if exists sri_os.fn_asset_can_average(uuid);
--   -- drop function if exists sri_os.fn_asset_cost_basis_mode(uuid);
--   -- -- คืน fn_asset_average_unit_cost + fn_assert_lot_consumption_sane_for
--   -- -- เป็นรุ่นของ 20261025000008: รันไฟล์นั้นซ้ำ (idempotent) หลังถอดไฟล์นี้
--   -- delete from sri_os.asset_categories
--   --  where code in ('PAPER_STOCK_LISTED','PAPER_STOCK_PRIVATE','COM_ALT')
--   --    and not exists (select 1 from sri_os.assets a where a.category_id = asset_categories.id);
--   -- delete from sri_os.column_exposure
--   --  where table_name = 'asset_categories' and column_name = 'cost_basis_mode';
--   -- select sri_os.fn_apply_column_exposure();
--   -- alter table sri_os.asset_categories drop column if exists cost_basis_mode;
--   ⚠ ถอดแล้ว **ต้นทุนคอนโดถูกเฉลี่ยข้ามห้องได้อีก และหุ้นนอกตลาดถูกเฉลี่ยกับ
--     หุ้นในตลาดได้อีก** โดยที่งบดุลยังดุลทุกใบ
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 0 · ของที่ต้องมีมาก่อน — ขาดแล้วหยุด ไม่ใช่สร้างด่านครึ่งใบ
-- ============================================================
do $$
begin
  if to_regclass('sri_os.asset_categories') is null or to_regclass('sri_os.assets') is null then
    raise exception 'ไม่มีตาราง asset_categories/assets → ต้องรัน 20260917000003_assets_contacts.sql ก่อน';
  end if;
  if to_regclass('sri_os.asset_lots') is null or to_regclass('sri_os.asset_lot_consumptions') is null then
    raise exception 'ไม่มีทะเบียนล็อต → ต้องรัน 20261025000008_asset_lots.sql ก่อนไฟล์นี้ (ดู supabase/migration-order.txt)';
  end if;
  if to_regprocedure('sri_os.fn_asset_ledger_parts(uuid, uuid)') is null then
    raise exception 'ไม่มี fn_asset_ledger_parts → ต้องรัน 20261025000002_asset_cost_basis_average.sql ก่อนไฟล์นี้';
  end if;
  if to_regprocedure('sri_os.fn_assert_lot_consumption_sane_for(uuid)') is null then
    raise exception 'ไม่มี fn_assert_lot_consumption_sane_for → ไฟล์นี้เขียนทับฟังก์ชันนั้น ต้องมีของเดิมอยู่ก่อน (20261025000008)';
  end if;
  if to_regclass('sri_os.column_exposure') is null
     or to_regprocedure('sri_os.fn_apply_column_exposure()') is null then
    raise exception 'ไม่มีทะเบียนด่านคอลัมน์ → ต้องรัน 20261020000000_column_exposure.sql ก่อนไฟล์นี้ ไม่งั้นคอลัมน์ใหม่จะไม่มีด่าน (D-089)';
  end if;
end $$;

-- ============================================================
-- 1 · คอลัมน์ตัวแยก — อยู่ที่ตารางอ้างอิง ที่เดียว
-- ============================================================
alter table asset_categories
  add column if not exists cost_basis_mode text not null default 'whole_item';

alter table asset_categories drop constraint if exists asset_categories_cost_basis_mode_allowed;
alter table asset_categories
  add constraint asset_categories_cost_basis_mode_allowed
  check (cost_basis_mode in ('average', 'specific_lot', 'whole_item'));

comment on column asset_categories.cost_basis_mode is
  'วิธีคิดต้นทุนของทรัพย์ในหมวดนี้ (ลูกพี่สั่ง 25/10) · average = ถัวเฉลี่ยทั้งกอง **อนุญาตเฉพาะหุ้นในตลาด · คริปโต · ทองคำ** · specific_lot = เก็บล็อตและระบุล็อตที่ขาย ห้ามเฉลี่ยข้ามล็อต (หุ้นนอกตลาด · ETF · กองทุน · พันธบัตร) · whole_item = ทรัพย์ชิ้นเดียว แบ่งไม่ได้ ตัดทั้งก้อน (อสังหาฯ · ที่ดิน · สัญญา · ของสะสม) · **ค่าตั้งต้น whole_item** เพราะเผลอแล้วต้องได้การปฏิเสธ ไม่ใช่การเฉลี่ย · ต้นฉบับอยู่ที่ src/lib/rules/asset-classes.ts';

-- ---------- หมวดใหม่ 3 หมวด ----------
-- **เหตุผลที่ต้องเพิ่ม ไม่ใช่แค่ติดธงบนหมวดเดิม**
--   หุ้นในตลาดกับหุ้นนอกตลาดอยู่รหัส `1700` เดียวกัน และทองคำกับสินทรัพย์
--   ทางเลือกอื่นอยู่ `1720` เดียวกัน → ถ้าไม่มีหมวดแยก ก็ไม่มีที่ให้เก็บคำตอบ
--   ที่ "ตั้งไว้ชัดเจนในข้อมูลอ้างอิง" ได้เลย (และจะเหลือแต่การเดาจาก ticker/รหัสบัญชี)
insert into asset_categories (class_id, code, name_th, sort_order, cost_basis_mode)
select k.id, v.code, v.name_th, v.sort_order, v.mode
  from (values
    ('PAPER',     'PAPER_STOCK_LISTED',  'หุ้นในตลาดหลักทรัพย์',  8,  'average'),
    ('PAPER',     'PAPER_STOCK_PRIVATE', 'หุ้นบริษัทนอกตลาด',     9,  'specific_lot'),
    ('COMMODITY', 'COM_ALT',             'สินทรัพย์ทางเลือกอื่น',  25, 'whole_item')
  ) as v(class_code, code, name_th, sort_order, mode)
  join asset_classes k on k.code = v.class_code
on conflict (code) do update set
  class_id        = excluded.class_id,
  name_th         = excluded.name_th,
  sort_order      = excluded.sort_order,
  cost_basis_mode = excluded.cost_basis_mode;

-- ---------- seed + backfill ของเดิมทั้งหมด ----------
-- สามขั้นโดยตั้งใจ: ขั้นแรกบังคับทุกหมวดเป็น `whole_item` (รวมหมวดที่ใครเพิ่มมา
-- ทีหลังแล้วลืมตัดสินใจ) แล้วเปิดเฉพาะรายชื่อที่ตัดสินแล้ว
-- → รันซ้ำได้ผลเดิม และ "ลืมระบุ" แปลว่าเข้มที่สุด ไม่ใช่หลวมที่สุด
update asset_categories set cost_basis_mode = 'whole_item'
 where cost_basis_mode <> 'whole_item';

-- **เฉลี่ยได้สามอย่างเท่านั้น** (หุ้นในตลาด · คริปโต · ทองคำ)
update asset_categories set cost_basis_mode = 'average'
 where code in ('PAPER_STOCK_LISTED', 'COM_CRYPTO', 'COM_GOLD');

-- ห้ามเฉลี่ย แต่แบ่งขายรายล็อตได้ (มีหน่วยจริงและซื้อเพิ่มได้หลายครั้ง)
-- `PAPER_STOCK` คือหมวดเดิมก่อนแยกตามตลาด — ยังไม่รู้ว่าอยู่ในตลาดหรือไม่
-- จึง **ห้ามเฉลี่ย** และต้องย้ายทรัพย์ไปหมวดที่ระบุชัด
update asset_categories set cost_basis_mode = 'specific_lot'
 where code in ('PAPER_STOCK', 'PAPER_STOCK_PRIVATE', 'PAPER_ETF', 'PAPER_FUND',
                'PAPER_BOND', 'BIZ_RELATED');

-- ของเดิมต้อง backfill ถูก **และพิสูจน์ว่าถูก** ไม่ใช่เชื่อว่า update ทำงาน
do $$
declare v text;
begin
  select string_agg(code, ', ' order by code) into v
    from sri_os.asset_categories where cost_basis_mode = 'average';
  if v is distinct from 'COM_CRYPTO, COM_GOLD, PAPER_STOCK_LISTED' then
    raise exception 'หมวดที่เฉลี่ยได้ต้องเป็น COM_CRYPTO, COM_GOLD, PAPER_STOCK_LISTED เท่านั้น (ลูกพี่สั่ง 25/10: หุ้นในตลาด · คริปโต · ทองคำ) แต่ได้: % — ถ้าตารางหมวดย่อยในฐานข้อมูลนี้ไม่ตรงกับ src/lib/rules/asset-classes.ts ให้แก้ให้ตรงก่อน ห้ามปล่อยให้ค่าใน DB ต่างจากต้นฉบับในโค้ดเงียบๆ',
      coalesce(v, '(ไม่มีเลย)');
  end if;

  -- อสังหาฯ ทุกหมวดต้องเป็น whole_item — ข้อที่ลูกพี่สั่งตรงๆ
  select string_agg(code || '=' || cost_basis_mode, ', ' order by code) into v
    from sri_os.asset_categories
   where code like 'RE%' and cost_basis_mode <> 'whole_item';
  if v is not null then
    raise exception 'หมวดอสังหาริมทรัพย์ต้องเป็น whole_item ทั้งหมด แต่พบ %: ลูกพี่สั่งว่าคนละห้องก็แยก ห้ามนำต้นทุนมาเฉลี่ยเด็ดขาด', v;
  end if;

  -- **คู่ที่พิสูจน์ว่าไม่ได้ใช้รหัสบัญชีตัดสิน** ต้องมีอยู่จริงทั้งสองคู่
  if (select cost_basis_mode from sri_os.asset_categories where code = 'PAPER_STOCK_PRIVATE') <> 'specific_lot'
     or (select cost_basis_mode from sri_os.asset_categories where code = 'PAPER_STOCK_LISTED') <> 'average' then
    raise exception 'หุ้นในตลาด/นอกตลาดต้องแยกกันได้ (LISTED=average · PRIVATE=specific_lot) — ทั้งคู่อยู่รหัส 1700 เดียวกัน ถ้าไม่แยกที่หมวด ก็ไม่มีที่ไหนแยกได้';
  end if;
  if (select cost_basis_mode from sri_os.asset_categories where code = 'COM_ALT') <> 'whole_item'
     or (select cost_basis_mode from sri_os.asset_categories where code = 'COM_GOLD') <> 'average' then
    raise exception 'ทองคำ/สินทรัพย์ทางเลือกอื่นต้องแยกกันได้ (GOLD=average · ALT=whole_item) — ทั้งคู่อยู่รหัส 1720 เดียวกัน';
  end if;
end $$;

-- ============================================================
-- 2 · ความจริงเดียวที่ทุกด่านถาม
-- ============================================================

/**
 * วิธีคิดต้นทุนของทรัพย์ชิ้นนี้ — อ่านจาก **ตารางอ้างอิง** เท่านั้น
 *
 * ไม่มีทรัพย์ · ไม่มีหมวด → `'whole_item'` (ค่าที่เข้มที่สุด)
 * ไม่ raise ที่นี่โดยตั้งใจ: ฟังก์ชันนี้ถูกเรียกจากด่านหลายตัวและจากรายงาน
 * การตอบค่าที่เข้มที่สุดทำให้ "ไม่รู้" กลายเป็น "ปฏิเสธ" ซึ่งเป็นด้านที่ปลอดภัย
 * ส่วนการปฏิเสธจริงเป็นหน้าที่ของด่านที่ถาม (มันรู้บริบทว่ากำลังจะทำอะไร)
 *
 * **ไม่อ่าน `assets.ticker` และไม่อ่านรหัสบัญชี** — ทั้งสองตอบคำถามนี้ไม่ได้
 * (หุ้นในตลาด/นอกตลาดอยู่ 1700 เดียวกัน · ทอง/ของสะสมอยู่ 1720 เดียวกัน)
 *
 * security definer: ด่านต้องได้ **คำตอบจริง** ไม่ใช่ได้ค่าตั้งต้นเพราะผู้เรียก
 * มองแถวใน `assets`/`asset_categories` ไม่เห็น (เหตุผลเดียวกับ fn_assert_wht_gross)
 */
create or replace function fn_asset_cost_basis_mode(p_asset uuid) returns text
language sql stable security definer set search_path = '' as $fn$
  select coalesce((
    select ct.cost_basis_mode
      from sri_os.assets a
      join sri_os.asset_categories ct on ct.id = a.category_id
     where a.id = p_asset
  ), 'whole_item');
$fn$;

comment on function fn_asset_cost_basis_mode(uuid) is
  'วิธีคิดต้นทุนของทรัพย์ชิ้นนี้ · อ่านจาก asset_categories.cost_basis_mode (ตารางอ้างอิงที่เขียนได้ด้วย migration เท่านั้น · D-115) · **ไม่อ่าน ticker และไม่อ่านรหัสบัญชี** เพราะหุ้นในตลาด/นอกตลาดอยู่ 1700 เดียวกัน และทองคำ/ของสะสมอยู่ 1720 เดียวกัน · ไม่พบทรัพย์/หมวด → whole_item ซึ่งเข้มที่สุด';

/** **เฉลี่ยได้ไหม** — คำถามของลูกพี่ มีคำตอบเดียวและอยู่ที่นี่ที่เดียว */
create or replace function fn_asset_can_average(p_asset uuid) returns boolean
language sql stable security definer set search_path = '' as $fn$
  select sri_os.fn_asset_cost_basis_mode(p_asset) = 'average';
$fn$;

comment on function fn_asset_can_average(uuid) is
  'ทรัพย์ชิ้นนี้ถัวเฉลี่ยต้นทุนได้หรือไม่ — true เฉพาะหุ้นในตลาด · คริปโต · ทองคำ (ลูกพี่สั่ง 25/10) · ด่านทุกตัวถามผ่านตัวนี้ ไม่เทียบสตริงเองกระจายในโค้ด';

do $$
declare f text;
begin
  foreach f in array array['sri_os.fn_asset_cost_basis_mode(uuid)',
                           'sri_os.fn_asset_can_average(uuid)'] loop
    execute format('revoke all on function %s from public', f);
    execute format('revoke all on function %s from anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- ============================================================
-- 3 · ต้นทุนถัวเฉลี่ยต่อหน่วย — ถามกับทรัพย์ที่ห้ามเฉลี่ย = **ปฏิเสธ**
--     (เขียนทับรุ่น sql ของ 20261025000008 · ลายเซ็นเดิม ผู้เรียกไม่ต้องแก้)
-- ============================================================
create or replace function fn_asset_average_unit_cost(p_asset uuid) returns numeric
language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_units numeric;
  v_mode  text;
  v_name  text;
begin
  v_mode := sri_os.fn_asset_cost_basis_mode(p_asset);
  if v_mode <> 'average' then
    select a.code || ' ' || a.name into v_name from sri_os.assets a where a.id = p_asset;
    raise exception 'ทรัพย์ "%" **ห้ามถัวเฉลี่ยต้นทุน** (หมวดนี้ cost_basis_mode = %) จึงไม่มีต้นทุนถัวเฉลี่ยต่อหน่วย — ลูกพี่สั่ง 25/10 ว่าเฉลี่ยได้เฉพาะ หุ้นในตลาดหลักทรัพย์ · คริปโต · ทองคำ เท่านั้น · ต้นทุนของทรัพย์นี้คือยอดทั้งก้อน (sri_os.fn_asset_lot_cost / sri_os.fn_asset_cost_basis) หรือราคาของล็อตที่ระบุ ไม่ใช่อัตราต่อหน่วยที่เอาไปคูณสัดส่วน',
      coalesce(v_name, p_asset::text), v_mode;
  end if;

  v_units := sri_os.fn_asset_units(p_asset);
  if v_units is null or v_units <= 0 then
    return null;   -- ไม่มีของ = ไม่มีต้นทุนต่อหน่วย (หารศูนย์ไม่ได้) · รูปเดิมของ 0008
  end if;
  return sri_os.fn_asset_lot_cost(p_asset) / v_units;
end $fn$;

comment on function fn_asset_average_unit_cost(uuid) is
  'ต้นทุนถัวเฉลี่ยต่อหน่วย (D-112) คำนวณใหม่จากทะเบียนล็อตทุกครั้ง — **ไม่รับต้นทุนจากผู้เรียก** · ไม่ปัดค่าเฉลี่ย · **ทรัพย์ที่ห้ามเฉลี่ย → raise ไม่ใช่คืนเลข** เพราะอัตราต่อหน่วยของทั้งกองมีความหมายเดียวคือเอาไปคูณสัดส่วน = การเฉลี่ยที่ลูกพี่ห้าม (25/10)';

comment on function fn_asset_lot_cost(uuid) is
  'ต้นทุนคงเหลือของทรัพย์ชิ้นหนึ่งตามทะเบียนล็อต (บาท) · ใช้ได้กับทุกโหมด: สำหรับทรัพย์ที่ห้ามเฉลี่ย ยอดนี้ *คือ* ต้นทุนของชิ้นนั้น/กองนั้นตรงๆ · เป็น **ยอดรวมทั้งก้อน** จึงเอาไปเฉลี่ยไม่ได้โดยไม่มีตัวหาร และตัวหารนั้นถูกปฏิเสธที่ fn_asset_average_unit_cost()';

revoke all on function fn_asset_average_unit_cost(uuid) from public;
do $$ begin execute 'revoke all on function sri_os.fn_asset_average_unit_cost(uuid) from anon, authenticated'; end $$;

-- ============================================================
-- 4 · ด่านของการตัดล็อต — **ฟังก์ชันเดิม สามกิ่งตามโหมด**
--
-- เขียนทับ `fn_assert_lot_consumption_sane_for()` ของ 20261025000008 ด้วย
-- ลายเซ็นเดิม → `trg_lot_consumption_sane` ตัวเดิมยังเป็นตัวเรียก ไม่มี trigger
-- ตัวที่สองมาตรวจเรื่องเดียวกันคนละคำตอบ (กฎเดียวกันห้ามเขียนสองที่)
--
-- สิ่งที่ **ไม่เปลี่ยน** จากของเดิม: ข้อ (ก) ตัดเกินจำนวนที่มี · ข้อ (ค) สมุดกับ
-- ทะเบียนต้องตรงกัน · ข้อความของทั้งสองข้อคงคำเดิมไว้ (เทสต์เดิมอ้างอิงอยู่)
-- ที่เปลี่ยนคือข้อ (ข) ซึ่งเดิมบังคับ "ถัวเฉลี่ย" กับ **ทุกทรัพย์**
-- ============================================================
create or replace function fn_assert_lot_consumption_sane_for(p_txn uuid) returns void
language plpgsql security definer set search_path = '' as $fn$
declare
  r           record;
  v_bad       record;
  v_lot       record;
  v_qty       numeric;
  v_cost      numeric;
  v_units0    numeric;   -- จำนวนคงเหลือ "ก่อนใบนี้"
  v_cost0     numeric;   -- ต้นทุนคงเหลือ "ก่อนใบนี้"
  v_expected  numeric;
  v_ledger    numeric;
  v_mode      text;
begin
  -- (ก) ห้ามล็อตไหนถูกตัดเกินจำนวนที่มี (ตรวจทุกล็อตที่ใบนี้แตะ) — เหมือนเดิม
  for v_bad in
    select c.lot_id, sri_os.fn_asset_lot_remaining(c.lot_id) as remaining
      from sri_os.asset_lot_consumptions c
     where c.txn_id = p_txn
     group by c.lot_id
  loop
    if round(v_bad.remaining, 8) < 0 then
      raise exception 'ตัดล็อต % ออกมากกว่าจำนวนที่มี (คงเหลือหลังใบนี้ %) — จำนวนคงเหลือคำนวณจากทะเบียนล็อตหักส่วนที่ขายไปแล้ว ไม่ใช่จาก assets.units ที่แก้มือได้',
        v_bad.lot_id, round(v_bad.remaining, 8);
    end if;
  end loop;

  -- ต่อทรัพย์หนึ่งชิ้นที่ใบนี้ตัด
  for r in
    select l.asset_id,
           sum(c.quantity) as qty,
           sum(c.cost_thb) as cost
      from sri_os.asset_lot_consumptions c
      join sri_os.asset_lots l on l.id = c.lot_id
     where c.txn_id = p_txn
     group by l.asset_id
  loop
    v_qty := r.qty;
    v_cost := r.cost;
    -- สภาพก่อนใบนี้ = ของตอนนี้ + ที่ใบนี้ตัดออกไป (คำนวณย้อน ไม่ได้เก็บไว้)
    v_units0 := round(sri_os.fn_asset_units(r.asset_id) + v_qty, 8);
    v_cost0  := round(sri_os.fn_asset_lot_cost(r.asset_id) + v_cost, 2);
    v_mode   := sri_os.fn_asset_cost_basis_mode(r.asset_id);

    if v_units0 <= 0 then
      raise exception 'ทรัพย์ % ไม่มีหน่วยคงเหลือในทะเบียนล็อตก่อนใบนี้ จึงตัดออกไม่ได้ — ต้องลงล็อตที่ซื้อเข้ามาก่อน (ยอดยกมาของพอร์ตต้องลงรายล็อตด้วย)',
        r.asset_id;
    end if;
    if round(v_qty, 8) > round(v_units0, 8) then
      raise exception 'ขายทรัพย์ % ออก % หน่วย แต่ทะเบียนล็อตมี % หน่วย — ขายมากกว่าที่ถือไม่ได้',
        r.asset_id, round(v_qty, 8), round(v_units0, 8);
    end if;

    if v_mode = 'average' then
      /**
       * (ข-1) **สมการถัวเฉลี่ย (D-112)** — ใช้ได้เฉพาะ หุ้นในตลาด · คริปโต · ทองคำ
       * ขายหมดต้องตัดต้นทุนทั้งกองพอดี ไม่เหลือเศษ · ยอมคลาดได้ 0.01
       * ซึ่งคือการปัดของการหารครั้งเดียว และเพราะเทียบกับยอดที่คำนวณใหม่ทั้งก้อน
       * ทุกครั้ง ความคลาดจึงสะสมไม่ได้
       */
      if round(v_qty, 8) = round(v_units0, 8) then
        v_expected := v_cost0;
      else
        v_expected := round(v_cost0 * v_qty / v_units0, 2);
      end if;

      if abs(round(v_cost - v_expected, 2)) > 0.01 then
        raise exception 'ต้นทุนที่ตัดออกของทรัพย์ % ต้องเป็น % บาท (ต้นทุนคงเหลือ % × % ÷ % หน่วย ตามต้นทุนถัวเฉลี่ย D-112) แต่บันทึกมา % บาท — **ต้นทุนถัวเฉลี่ยคำนวณจากทะเบียนล็อต ไม่ใช่ค่าที่ส่งเข้ามา** · ส่งค่าผิดมาจะถูกปฏิเสธ ไม่ใช่ถูกใช้',
          r.asset_id, v_expected, v_cost0, round(v_qty, 8), round(v_units0, 8), v_cost;
      end if;

    elsif v_mode = 'specific_lot' then
      /**
       * (ข-2) **ระบุล็อตที่ขาย — ต้นทุนมาจากราคาของล็อตนั้นเอง ห้ามเฉลี่ยข้ามล็อต**
       *
       * ตรวจ **รายล็อต** ไม่ใช่รายทรัพย์: นี่คือจุดที่ความต่างอยู่
       * (รายทรัพย์จะยอมให้สลับยอดระหว่างล็อตแพงกับล็อตถูกแล้วผลรวมยังตรง)
       *
       * ตัดล็อตหมดพอดี → ต้นทุนคงเหลือของล็อตนั้นทั้งก้อน (ไม่เหลือเศษสตางค์)
       * ตัดบางส่วน → ราคาของล็อตนั้น × สัดส่วนจำนวนของล็อตนั้น
       *   (การหารนี้ **ไม่ใช่การเฉลี่ย**: ทุกหน่วยในล็อตเดียวซื้อมาในราคาเดียวกัน
       *    จริงๆ ไม่ได้เอาราคาของล็อตอื่นมาเจือ)
       */
      for v_lot in
        select c.lot_id,
               l.quantity as lot_qty,
               l.cost_thb as lot_cost,
               sum(c.quantity) as take_qty,
               sum(c.cost_thb) as take_cost,
               sri_os.fn_asset_lot_remaining(c.lot_id) as remaining_after
          from sri_os.asset_lot_consumptions c
          join sri_os.asset_lots l on l.id = c.lot_id
         where c.txn_id = p_txn and l.asset_id = r.asset_id
         group by c.lot_id, l.quantity, l.cost_thb
      loop
        if round(v_lot.remaining_after, 8) = 0 then
          -- ปิดล็อต → ต้องตัดต้นทุนที่เหลือของล็อตนั้นออกให้หมดพอดี
          select v_lot.lot_cost - coalesce(sum(c2.cost_thb), 0) into v_expected
            from sri_os.asset_lot_consumptions c2
           where c2.lot_id = v_lot.lot_id and c2.txn_id <> p_txn;
          v_expected := round(v_expected, 2);
        else
          v_expected := round(v_lot.lot_cost * v_lot.take_qty / v_lot.lot_qty, 2);
        end if;

        if abs(round(v_lot.take_cost - v_expected, 2)) > 0.01 then
          raise exception 'ทรัพย์ % **ห้ามถัวเฉลี่ยต้นทุน** (หมวดนี้ cost_basis_mode = specific_lot) — ต้นทุนที่ตัดจากล็อต % ต้องเป็น % บาท ซึ่งคือ **ราคาของล็อตนั้นเอง** (ล็อตละ % บาท ต่อ % หน่วย × % หน่วยที่ตัด) แต่บันทึกมา % บาท · ลูกพี่สั่ง 25/10 ว่าเฉลี่ยได้เฉพาะ หุ้นในตลาดหลักทรัพย์ · คริปโต · ทองคำ — **หุ้นบริษัทนอกตลาดไม่เกี่ยว** · ถ้าจะขายของถูกหรือของแพงก่อน ให้ระบุล็อตที่ขาย ไม่ใช่เฉลี่ยทั้งกอง',
            r.asset_id, v_lot.lot_id, v_expected, v_lot.lot_cost, round(v_lot.lot_qty, 8),
            round(v_lot.take_qty, 8), v_lot.take_cost;
        end if;
      end loop;

    else
      /**
       * (ข-3) **ทรัพย์ชิ้นเดียว แบ่งไม่ได้** — ตัดออกต้องตัดทั้งก้อน
       * เหลือจำนวนหรือต้นทุนค้าง = แบ่งขายทรัพย์ที่แบ่งไม่ได้ (ขาย 30%
       * ของคอนโดหนึ่งห้องไม่มีอยู่จริง) และต้นทุนที่เหลือจะถูกคิดต่อแบบเฉลี่ย
       */
      if round(sri_os.fn_asset_units(r.asset_id), 8) <> 0
         or round(sri_os.fn_asset_lot_cost(r.asset_id), 2) <> 0 then
        raise exception 'ทรัพย์ % เป็นทรัพย์ชิ้นเดียว (หมวดนี้ cost_basis_mode = whole_item) จึง **ขายบางส่วนไม่ได้** — ใบนี้ตัดออกแล้วยังเหลือ % หน่วย / % บาท · ลูกพี่สั่ง 25/10: แยกทรัพย์แม้อยู่คอนโดเดียวกัน คนละห้องก็แยก **ห้ามนำต้นทุนมาคำนวณหรือเฉลี่ยเด็ดขาด** · **ต้องแยกชิ้นก่อน** ตาม D-112: ขายออกทั้งชิ้นแล้วซื้อเข้าเป็นหลายชิ้น ยอดสองฝั่งหักกันได้ศูนย์ แล้วจึงขายชิ้นที่ต้องการ',
          r.asset_id,
          round(sri_os.fn_asset_units(r.asset_id), 8),
          round(sri_os.fn_asset_lot_cost(r.asset_id), 2);
      end if;
    end if;

    /**
     * (ค) **สมุดกับทะเบียนย่อยต้องเล่าเรื่องเดียวกัน** — ทุกโหมด เหมือนเดิม
     */
    v_ledger := sri_os.fn_asset_cost_basis(r.asset_id);
    if abs(round(v_ledger - sri_os.fn_asset_lot_cost(r.asset_id), 2)) > 0.01 then
      raise exception 'ต้นทุนคงเหลือของทรัพย์ % ในสมุด (% บาท) ไม่ตรงกับทะเบียนล็อต (% บาท) — ต้องตรงกันเสมอ · สาเหตุที่พบบ่อย: ใบยอดยกมาของพอร์ตลงเป็นก้อนรวมโดยไม่ผูกทรัพย์ (ต้องลงต่อทรัพย์และผูก asset_id ทั้งที่หัวรายการและบรรทัดบัญชีทรัพย์) หรือใบขายตัดต้นทุนในสมุดคนละยอดกับที่ตัดในทะเบียน',
        r.asset_id, round(v_ledger, 2), sri_os.fn_asset_lot_cost(r.asset_id);
    end if;
  end loop;
end $fn$;

comment on function fn_assert_lot_consumption_sane_for(uuid) is
  'ด่านของการตัดล็อต · (ก) ตัดเกินจำนวนที่มีไม่ได้ · (ข) ต้นทุนที่ตัดต้องตรงกับ **โหมดของหมวดทรัพย์**: average = ถัวเฉลี่ยทั้งกองที่คำนวณใหม่จากทะเบียน (หุ้นในตลาด · คริปโต · ทองคำ เท่านั้น) · specific_lot = ราคาของล็อตที่ระบุ ตรวจรายล็อต · whole_item = ตัดทั้งก้อน · (ค) ต้นทุนคงเหลือในสมุดต้องเท่ากับในทะเบียน · ค่าที่ส่งเข้ามาผิดถูกปฏิเสธ ไม่ใช่ถูกใช้ (D-115)';

revoke all on function fn_assert_lot_consumption_sane_for(uuid) from public;
do $$ begin execute 'revoke all on function sri_os.fn_assert_lot_consumption_sane_for(uuid) from anon, authenticated'; end $$;

-- ============================================================
-- 5 · ทรัพย์ชิ้นเดียวมีล็อตได้ไม่เกินหนึ่ง
--
-- **ทรัพย์ `specific_lot` และ `average` มีล็อตได้ไม่จำกัดเหมือนเดิม** —
-- ล็อตคือข้อมูล ลูกพี่ห้ามแค่วิธีคิด · ด่านนี้แคบมาก: เฉพาะ `whole_item`
-- ซึ่งคือของชิ้นเดียวที่ซื้อครั้งเดียว (คอนโดห้องเดิมซื้อสองครั้งไม่มีอยู่จริง —
-- ถ้าซื้อห้องที่สองก็เป็นทรัพย์คนละแถว) · ล็อตหลายล็อตบนของชิ้นเดียวจึงเป็น
-- รูปร่างของการเฉลี่ยล้วนๆ
--
-- นับ **ทุกล็อตที่เคยมี** ไม่ใช่เฉพาะล็อตที่ยังเหลือ: ตารางเป็น append-only
-- ============================================================
create or replace function fn_assert_single_lot_for_whole_item() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_n    int;
  v_name text;
begin
  if sri_os.fn_asset_cost_basis_mode(new.asset_id) <> 'whole_item' then
    return new;
  end if;

  select count(*) into v_n from sri_os.asset_lots l
   where l.asset_id = new.asset_id and l.id <> new.id;
  if v_n > 0 then
    select a.code || ' ' || a.name into v_name from sri_os.assets a where a.id = new.asset_id;
    raise exception 'ทรัพย์ "%" เป็นทรัพย์ชิ้นเดียว (หมวดนี้ cost_basis_mode = whole_item) จึงมีล็อตได้ไม่เกินหนึ่ง แต่มีอยู่แล้ว % ล็อต — ล็อตหลายล็อตบนของชิ้นเดียวคือรูปร่างของการถัวเฉลี่ย ซึ่งลูกพี่ห้ามเด็ดขาด (25/10: แยกทรัพย์แม้อยู่คอนโดเดียวกัน คนละห้องก็แยก) · ถ้านี่เป็นทรัพย์อีกชิ้น (อีกห้อง/อีกแปลง) ให้สร้างแถวใหม่ใน assets แล้วผูกล็อตกับแถวนั้น · ถ้าจะแบ่งขายส่วนหนึ่ง ให้ทำตาม D-112 คือ **ขายออกแล้วซื้อเข้าเป็นหลายชิ้น ยอดสองฝั่งหักกันได้ศูนย์**',
      coalesce(v_name, new.asset_id::text), v_n;
  end if;
  return new;
end $fn$;

comment on function fn_assert_single_lot_for_whole_item() is
  'ทรัพย์โหมด whole_item (อสังหาฯ · ที่ดิน · สัญญา · ของสะสม) มีล็อตได้ไม่เกินหนึ่ง — ของชิ้นเดียวซื้อครั้งเดียว ล็อตที่สองคือรูปร่างของการเฉลี่ย · **ไม่แตะทรัพย์โหมด specific_lot/average ซึ่งมีล็อตได้ไม่จำกัด**';

revoke all on function fn_assert_single_lot_for_whole_item() from public;
do $$ begin execute 'revoke all on function sri_os.fn_assert_single_lot_for_whole_item() from anon, authenticated'; end $$;

drop trigger if exists trg_lots_single_for_whole_item on asset_lots;
create trigger trg_lots_single_for_whole_item
  before insert or update of asset_id on asset_lots
  for each row execute function fn_assert_single_lot_for_whole_item();

-- ============================================================
-- 6 · ในสมุด: ตัดต้นทุนทรัพย์ชิ้นเดียว = ตัดทั้งก้อน + ล้าง 3400 ทั้งก้อน
--
-- **ด่านนี้คือตัวที่จับการขายคอนโด 30% ได้จริง** เพราะคอนโดส่วนใหญ่ไม่มีล็อต
-- ต้นทุนอยู่ในสมุดตรงๆ → ด่านที่ดูแต่ทะเบียนล็อตมองไม่เห็นเลย
--
-- ยกเว้น `source = 'reverse'` ด้วยเหตุผลเดียวกับข้อ (ข) ของ 20261025000002:
--   ใบกลับรายการต้องเป็นภาพกระจกของใบเดิมเป๊ะ (กฎเหล็กข้อ 1) ถ้าบังคับ
--   "ทั้งก้อน" กับมันด้วย การกลับใบค่ารีโนเวท (`inv.capex`) ของคอนโดจะทำไม่ได้เลย
--   = แก้ของที่ลงผิดไม่ได้ ซึ่งแย่กว่าปัญหาที่กัน
--
-- deferred constraint trigger: ต้องอ่าน **ทุกบรรทัดของใบ** (ขาต้นทุนกับขาล้าง
--   ส่วนเกินอยู่คนละบรรทัด) · รูปเดียวกับ trg_assert_asset_cost_sane
-- ============================================================
create or replace function fn_assert_asset_whole_disposal() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_txn      uuid := coalesce(new.transaction_id, old.transaction_id);
  v_source   text;
  v_asset    uuid;
  v_name     text;
  v_before   numeric;
  v_sbefore  numeric;
  v_after    numeric;
  v_safter   numeric;
  v_removed  numeric;
begin
  select t.source::text into v_source from sri_os.transactions t where t.id = v_txn;
  if v_source is null then
    return null;   -- หัวรายการหายไปแล้ว (cascade) → ไม่มีอะไรให้ตรวจ
  end if;
  if v_source = 'reverse' then
    return null;
  end if;

  for v_asset in
    select distinct lx.asset_id
      from sri_os.transaction_lines lx
      join sri_os.chart_of_accounts c on c.id = lx.coa_id
     where lx.transaction_id = v_txn
       and lx.asset_id is not null
       and ((c.type::text = 'asset' and c.code !~ '^11[0-9][0-9]$') or c.code = '3400')
  loop
    -- **เฉพาะ whole_item** — หุ้น/คริปโต/ทอง/หุ้นนอกตลาด ขายบางส่วนได้ตามปกติ
    if sri_os.fn_asset_cost_basis_mode(v_asset) <> 'whole_item' then
      continue;
    end if;

    select cost_basis, surplus into v_before, v_sbefore
      from sri_os.fn_asset_ledger_parts(v_asset, v_txn);
    select cost_basis, surplus into v_after, v_safter
      from sri_os.fn_asset_ledger_parts(v_asset, null);
    v_removed := round(v_before - v_after, 2);

    -- ใบที่ไม่ได้ตัดต้นทุนออก (ซื้อ · รีโนเวท · ตีราคา · ค่าเช่าค้างรับ) ไม่เกี่ยว
    if v_removed <= 0 then
      continue;
    end if;

    select a.code || ' ' || a.name into v_name from sri_os.assets a where a.id = v_asset;
    v_name := coalesce(v_name, v_asset::text);

    -- ---------- (ก) ตัดต้นทุนบางส่วนไม่ได้ ----------
    if round(v_after, 2) <> 0 then
      raise exception 'ทรัพย์ "%" เป็นทรัพย์ชิ้นเดียว (หมวดนี้ cost_basis_mode = whole_item) จึง **ขายบางส่วนไม่ได้** — ใบนี้ตัดต้นทุนออก % บาท จาก % บาท และยังเหลือ % บาทในบัญชีทรัพย์ · ลูกพี่สั่ง 25/10: แยกทรัพย์แม้อยู่คอนโดเดียวกัน คนละห้องก็แยก **ห้ามนำต้นทุนมาคำนวณหรือเฉลี่ยเด็ดขาด** · ถ้าจะแบ่งขาย **ต้องแยกชิ้นก่อน** ตาม D-112: ขายออกทั้งชิ้นแล้วซื้อเข้าเป็นหลายชิ้น ยอดสองฝั่งหักกันได้ศูนย์ แล้วจึงขายชิ้นที่ต้องการ (ถ้านี่เป็นการขายทั้งชิ้นจริง แปลว่าต้นทุนในสมุดยังมีบรรทัดที่ไม่ถูกตัด เช่นค่ารีโนเวท 1510 — ต้องตัดในใบเดียวกัน)',
        v_name, v_removed, round(v_before, 2), round(v_after, 2);
    end if;

    -- ---------- (ข) ส่วนเกินทุนต้องล้าง **ทั้งก้อน** ไม่ใช่ตามสัดส่วน ----------
    -- ขายทั้งชิ้นแล้ว "สัดส่วน" ไม่มีความหมาย: ส่วนเกินที่เหลือค้างคือส่วนเกินของ
    -- ทรัพย์ที่ไม่อยู่แล้ว = ทรัพย์ผีในส่วนของเจ้าของ
    if round(v_safter, 2) <> 0 then
      raise exception 'ทรัพย์ "%" ถูกตัดต้นทุนออกทั้งก้อน (% บาท) แต่ยังมีส่วนเกินทุนจากการตีราคา (3400) ค้างอยู่ % บาท จากที่เคยมี % บาท — ทรัพย์ชิ้นเดียวต้องล้างส่วนเกินทุน **ทั้งก้อนในใบเดียวกับการขาย** ไม่ใช่ตามสัดส่วน เพราะไม่มีสัดส่วนให้คิด · ปล่อยค้างไว้แปลว่าส่วนของเจ้าของมีมูลค่าของทรัพย์ที่ขายไปแล้ว และบัญชีทรัพย์ไม่กลับเป็นศูนย์',
        v_name, v_removed, round(v_safter, 2), round(v_sbefore, 2);
    end if;
  end loop;

  return null;
end $fn$;

comment on function fn_assert_asset_whole_disposal() is
  'ลูกพี่สั่ง 25/10 · ทรัพย์โหมด whole_item (อสังหาฯ ทุกหมวด · สัญญาเงินกู้/ขายฝาก · กิจการ · ของสะสม): ใบที่ตัดต้นทุนออกต้องตัด **ทั้งก้อน** (เหลือ 0) และล้าง 3400 **ทั้งก้อน** · ด่านนี้จับการขายคอนโดบางส่วนซึ่งทะเบียนล็อตมองไม่เห็น เพราะคอนโดส่วนใหญ่ไม่มีล็อต · ใบกลับรายการยกเว้น (ต้องเป็นภาพกระจกของใบเดิม · กฎเหล็กข้อ 1) · ทรัพย์โหมดอื่นไม่ถูกแตะ';

revoke all on function fn_assert_asset_whole_disposal() from public;
do $$ begin execute 'revoke all on function sri_os.fn_assert_asset_whole_disposal() from anon, authenticated'; end $$;

drop trigger if exists trg_assert_asset_whole_disposal on transaction_lines;
create constraint trigger trg_assert_asset_whole_disposal
  after insert or update or delete on transaction_lines
  deferrable initially deferred
  for each row execute function fn_assert_asset_whole_disposal();

-- ============================================================
-- 7 · การกระทบยอด — ของที่ด่านรายใบจับไม่ได้ ต้องเรียกดูได้ตลอดเวลา
--
-- ด่านทั้งหมดข้างบนทำงาน "ตอนมีใบ/มีล็อต" · สิ่งที่มันมองไม่เห็นคือสภาพที่
-- **เกิดจากการเลือกหมวดผิดตั้งแต่สร้างทรัพย์** เช่นคอนโดที่ถูกใส่หมวดหุ้น
-- หรือหุ้นที่ยังค้างในหมวด `PAPER_STOCK` ที่ยังไม่ระบุตลาด
-- → ไม่ทำเป็น trigger เพราะข้อมูลที่ยกยอดมาก่อนไฟล์นี้อาจมีสภาพนี้อยู่แล้ว
--    และการปฏิเสธใบถัดไปไม่ได้แก้อะไร (รูปเดียวกับ fn_asset_surplus_mismatch)
-- ============================================================
create or replace function fn_asset_cost_basis_mode_mismatch()
returns table (asset_id uuid, asset_code text, mode text, problem text)
language sql stable security definer set search_path = '' as $fn$
  -- (1) ทรัพย์ชิ้นเดียวที่มีล็อตหลายล็อต (สภาพที่ด่านใหม่ห้าม แต่ของเก่าอาจมี)
  select a.id, a.code, sri_os.fn_asset_cost_basis_mode(a.id),
         'ทรัพย์ชิ้นเดียวแต่มี ' || count(*)::text || ' ล็อต — ต้นทุนถูกเฉลี่ยข้ามชิ้นได้'
    from sri_os.assets a
    join sri_os.asset_lots l on l.asset_id = a.id
   where sri_os.fn_asset_cost_basis_mode(a.id) = 'whole_item'
   group by a.id, a.code
  having count(*) > 1
  union all
  -- (2) ทรัพย์ที่ยังอยู่ในหมวดที่ไม่ระบุว่าอยู่ในตลาดหรือไม่ → ต้องย้าย
  select a.id, a.code, sri_os.fn_asset_cost_basis_mode(a.id),
         'ยังอยู่หมวด PAPER_STOCK ที่ไม่ระบุตลาด — ต้องย้ายไป PAPER_STOCK_LISTED (เฉลี่ยได้) หรือ PAPER_STOCK_PRIVATE (ห้ามเฉลี่ย) ให้ชัด'
    from sri_os.assets a
    join sri_os.asset_categories ct on ct.id = a.category_id
   where ct.code = 'PAPER_STOCK';
$fn$;

comment on function fn_asset_cost_basis_mode_mismatch() is
  'การกระทบยอดของเส้นแบ่งวิธีคิดต้นทุน · **ต้องว่างเปล่าเสมอ**: ทรัพย์ชิ้นเดียวที่มีหลายล็อต (สภาพที่ด่านใหม่ห้าม แต่ของที่ยกยอดมาก่อนอาจมี) · ทรัพย์ที่ยังค้างในหมวด PAPER_STOCK ที่ไม่ระบุตลาด ซึ่งต้องย้ายให้ชัด · เก็บเฉพาะข้อที่ **ต้องแก้** ไม่ใส่ข้อที่เป็นแค่ข้อสังเกต (เช่น "มีหลายล็อตคนละราคา" ซึ่งปกติสำหรับหุ้นนอกตลาด) เพราะรายงานที่มีแถวตามปกติจะไม่มีใครอ่าน · ไม่ทำเป็น trigger เพราะสภาพนี้เกิดจากการเลือกหมวดผิดตอนสร้างทรัพย์ ไม่ใช่จากใบที่กำลังลง';

revoke all on function fn_asset_cost_basis_mode_mismatch() from public;
do $$ begin execute 'revoke all on function sri_os.fn_asset_cost_basis_mode_mismatch() from anon, authenticated'; end $$;

-- ============================================================
-- 8 · ด่านคอลัมน์ (D-089) — คอลัมน์ใหม่ที่ไม่ขึ้นทะเบียน = guard แดง
--     `cost_basis_mode` เป็นกฎอ้างอิง ไม่ใช่ข้อมูลของใครและไม่มีตัวเลขเงิน → open
--     (เหมือนคอลัมน์อื่นทั้งหมดของ asset_categories)
-- ============================================================
insert into column_exposure (table_name, column_name, exposure, min_permission, rationale)
values ('asset_categories', 'cost_basis_mode', 'open', null,
        'กฎอ้างอิงว่าหมวดนี้คิดต้นทุนแบบไหน (เฉลี่ยทั้งกอง / ระบุล็อต / ทั้งชิ้น) · ไม่ใช่ข้อมูลของใครคนใดคนหนึ่งและไม่มีตัวเลขเงิน · ฟอร์มต้องอ่านได้เพื่อบอกผู้ใช้ว่าทรัพย์ชิ้นนี้แบ่งขายไม่ได้หรือต้องระบุล็อต ก่อนที่ด่านจะปฏิเสธตอนกดบันทึก')
on conflict (table_name, column_name) do update
  set exposure = excluded.exposure, min_permission = excluded.min_permission,
      rationale = excluded.rationale;

select fn_apply_column_exposure();

-- ============================================================
-- 9 · guard ท้ายไฟล์ — ดังตอน migrate ไม่ใช่ตอนผู้ใช้กด
-- ============================================================
do $$
declare v text; n int;
begin
  -- (ก) คอลัมน์ + constraint อยู่จริง
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'sri_os' and table_name = 'asset_categories'
                    and column_name = 'cost_basis_mode' and is_nullable = 'NO') then
    raise exception 'คอลัมน์ asset_categories.cost_basis_mode ไม่ถูกสร้าง หรือยอม null';
  end if;
  if not exists (select 1 from pg_constraint
                  where conname = 'asset_categories_cost_basis_mode_allowed') then
    raise exception 'ไม่มี check constraint ของ cost_basis_mode → ค่าอื่นนอกสามค่าเข้าได้';
  end if;

  -- (ข) ค่าตั้งต้นของคอลัมน์ต้องเป็น whole_item — "เผลอแล้วปลอดภัย"
  if (select column_default from information_schema.columns
       where table_schema = 'sri_os' and table_name = 'asset_categories'
         and column_name = 'cost_basis_mode') not like '%whole_item%' then
    raise exception 'ค่าตั้งต้นของ cost_basis_mode ต้องเป็น whole_item — ถ้าเป็นอย่างอื่น หมวดใหม่ที่ใครลืมตัดสินใจจะได้สิทธิ์ที่หลวมกว่าเองเงียบๆ';
  end if;

  -- (ค) หมวดใหม่ทั้งสามต้องมีอยู่ ไม่งั้นไม่มีที่เก็บเส้นแบ่ง "ในตลาด/นอกตลาด"
  select string_agg(x.code, ', ') into v
    from (values ('PAPER_STOCK_LISTED'), ('PAPER_STOCK_PRIVATE'), ('COM_ALT')) x(code)
   where not exists (select 1 from sri_os.asset_categories ct where ct.code = x.code);
  if v is not null then raise exception 'หมวดที่ต้องมีหายไป: %', v; end if;

  -- (ง) trigger ทั้งสองตัวต้องอยู่ และตัวเดิมของ 0008 ต้องยังอยู่ (เราเขียนทับแค่ตัวฟังก์ชัน)
  select string_agg(x.want, ', ') into v
    from (values ('asset_lots', 'trg_lots_single_for_whole_item'),
                 ('asset_lot_consumptions', 'trg_lot_consumption_sane'),
                 ('transaction_lines', 'trg_assert_asset_whole_disposal'),
                 ('transaction_lines', 'trg_assert_asset_cost_sane')) x(tbl, want)
   where not exists (select 1 from pg_trigger g
                      where g.tgrelid = ('sri_os.' || x.tbl)::regclass
                        and g.tgname = x.want and not g.tgisinternal);
  if v is not null then raise exception 'trigger ที่ต้องมีหายไป: %', v; end if;

  -- (จ) ด่านระดับใบต้องเป็น constraint trigger แบบ deferred จริง
  --     (ถ้าไม่ deferred มันจะยิงตอนใส่บรรทัดแรก แล้วใบที่ถูกต้องลงไม่ได้เลย)
  select string_agg(g.tgname, ', ') into v
    from pg_trigger g
   where g.tgname in ('trg_assert_asset_whole_disposal', 'trg_lot_consumption_sane')
     and not g.tgisinternal
     and not (g.tgdeferrable and g.tginitdeferred);
  if v is not null then
    raise exception 'trigger ต้องเป็น deferrable initially deferred แต่ไม่ใช่: %', v;
  end if;

  -- (ฉ) ฟังก์ชันต้องไม่เปิดให้ anon/PUBLIC (D-089 · definer ที่อ่านสมุด)
  select string_agg(p.proname, ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.proname in ('fn_assert_single_lot_for_whole_item', 'fn_assert_asset_whole_disposal',
                       'fn_assert_lot_consumption_sane_for', 'fn_asset_average_unit_cost',
                       'fn_asset_cost_basis_mode_mismatch')
     and (has_function_privilege('anon', p.oid, 'execute')
          or has_function_privilege('public', p.oid, 'execute'));
  if v is not null then
    raise exception 'ฟังก์ชันของไฟล์นี้ยังเปิดให้ anon/PUBLIC: %', v;
  end if;

  -- (ช) ทุกคอลัมน์ต้องจัดประเภทครบ — ไฟล์นี้เพิ่มคอลัมน์ให้ตารางที่จัดแล้ว
  select count(*) into n from sri_os.fn_column_exposure_unclassified();
  if n <> 0 then
    select string_agg(u.table_name || '.' || u.column_name, ', ') into v
      from sri_os.fn_column_exposure_unclassified() u;
    raise exception 'ยังมีคอลัมน์ที่ไม่ได้จัดประเภท % รายการ: % (D-089)', n, v;
  end if;

  -- (ซ) เส้นทางถัวเฉลี่ยของสามอย่างที่อนุญาตต้องยังเปิดอยู่ — ด่านใหม่ต้องไม่ฆ่าของเดิม
  select count(*) into n from sri_os.asset_categories where cost_basis_mode = 'average';
  if n <> 3 then
    raise exception 'หมวดที่เฉลี่ยได้ต้องมี 3 หมวดพอดี (หุ้นในตลาด · คริปโต · ทองคำ) แต่ได้ % — มากกว่านี้คือเปิดให้ของที่ลูกพี่ห้าม น้อยกว่านี้คือปิดของที่ลูกพี่อนุญาต', n;
  end if;

  raise notice 'ok · เส้นแบ่งวิธีคิดต้นทุนติดครบ (คอลัมน์ + 3 หมวดใหม่ + 2 trigger + ฟังก์ชันสามกิ่ง) · เฉลี่ยได้ % หมวด', n;
end $$;
