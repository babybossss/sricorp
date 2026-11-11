-- ============================================================
-- SRI OS · **ยอดคงเหลือต่อ (ทรัพย์ × บัญชี) ติดลบไม่ได้** และใบที่ย้ายต้นทุน
--            ระหว่างบัญชีทรัพย์ต้องย้าย **ทั้งก้อน**
--
-- **ที่มา (ช่องที่ผู้ตรวจวัดได้ 27/10 · BLOCK)**
--   หมวดย้ายวัตถุประสงค์อสังหาฯ (`adj.reclass_re_to_sale` Dr 1520 / Cr 1500 ·
--   `adj.reclass_re_to_rental` Dr 1500 / Cr 1520) ไหลผ่าน **เส้นทางรายการปกติ
--   สองบรรทัด** ของ `posting.ts` ซึ่งรับยอดที่ผู้ใช้พิมพ์มาตรงๆ
--
--     คอนโดต้นทุน 3,000,000 อยู่ที่ 1500 · ผู้ใช้พิมพ์ 30,000,000
--     → Dr 1520 30,000,000 / Cr 1500 30,000,000 ด้วย `asset_id` เดิม
--     → **ต้นทุนรวมต่อทรัพย์ไม่เปลี่ยน** (ออกบัญชีหนึ่ง เข้าอีกบัญชีหนึ่ง เท่ากัน)
--
--   ด่านต้นทุนที่มีอยู่ทั้งสองตัวจึง **ข้ามไปทั้งคู่**:
--     `fn_assert_asset_cost_sane`      (20261025000002) ตัดสินจาก v_removed = 0
--     `fn_assert_asset_whole_disposal` (20261025000010) ตัดสินจาก v_removed = 0
--   ผลที่อ่านได้ในงบดุล: "อสังหาฯ เพื่อการเช่า" = (27,000,000) และ
--   "เพื่อการขาย" = 30,000,000 · **ยอดรวมหมวดยังถูก ไม่มีด่านไหนฟ้องเลย**
--   ย้ายบางส่วน (1,000,000 จาก 3,000,000) ก็ผ่านเงียบเหมือนกัน
--
-- **ทำไมต้องกันที่ DB ด้วย ไม่ใช่แค่ที่ engine**
--   `buildPosting()` บังคับให้ผู้เรียกส่งยอดคงเหลือที่อ่านจากสมุดมาแล้ว
--   (ธง `wholeBalanceMove` ในตารางกฎ) แต่ engine เป็นเพียงด่านของ **เส้นทางหน้าจอ**
--   `fn_post_entry` รับ payload ที่ประกอบบรรทัดเองได้ และ automation/สคริปต์
--   ก็เขียนผ่านประตูเดียวกัน → กั้นแค่ฝั่งแอปคือกั้นครึ่งเดียว (บทเรียน mace-windu ข้อ 6)
--
-- ------------------------------------------------------------
-- ทำอะไร (4 ส่วน)
-- ------------------------------------------------------------
--   1. `fn_asset_cost_coa(text)` — "บัญชีนี้นับเป็น **ต้นทุนรายทรัพย์** ไหม"
--      นิยาม **ชุดเดียวกับ `is_cost_account` ของ `fn_asset_ledger_parts`**
--      (20261025000002) เป๊ะๆ: ประเภท asset · ไม่ใช่เงินสด 11xx ·
--      ไม่ใช่ 1800 ภาษีถูกหักรอเครดิต · ไม่ใช่บัญชีพักลูกหนี้/เจ้าหนี้ของตารางกฎ
--      → ด่านต้นทุนที่มีอยู่กับด่านใหม่ **ตัดสินจากชุดเดียวกัน** ไม่ขัดกันเอง
--   2. (ว่างไว้โดยตั้งใจ — ไม่มีชุดยกเว้นแยกของตัวเอง ดูหมายเหตุเรื่อง 1290 ข้างล่าง)
--   3. `fn_asset_account_balance(uuid, text, uuid)` — ยอดคงเหลือของทรัพย์ชิ้นหนึ่ง
--      ในบัญชีหนึ่ง คิดสดจาก `v_ledger_posted` · **นี่คือตัวที่ฟอร์มต้องเรียก**
--      เพื่ออ่านยอดต้นทางก่อนลงใบย้าย (ห้ามให้ผู้ใช้พิมพ์ยอดเอง · D-115)
--   4. ด่าน `fn_assert_asset_account_balance_nonneg()` ตรวจสองข้อ ตอน commit:
--      (ก) **ยอดคงเหลือต่อ (ทรัพย์ × บัญชีต้นทุน) ติดลบไม่ได้** — ทุกใบ
--          รวมใบกลับรายการ (กลับแล้วติดลบก็ยังผิดอยู่)
--      (ข) ใบที่ **ทุกบรรทัดเป็นบัญชีต้นทุนรายทรัพย์** = ใบย้ายต้นทุนระหว่างบัญชี
--          → บัญชีต้นทางของทรัพย์ชิ้นนั้นต้องเหลือ **ศูนย์พอดี** (ย้ายทั้งก้อน)
--          และทุกบรรทัดต้องผูกทรัพย์ **ชิ้นเดียวกัน**
--
--   ข้อ (ข) ตัดสินจาก **ของจริงของบรรทัด ไม่ใช่รหัสหมวด** (กฎเหล็กข้อ 5):
--     ใบซื้อ/ขาย/ตีราคา/ยอดยกมา มีขาเงินสด หรือขาส่วนของเจ้าของ/หนี้สิน/P&L
--     เสมอ → ไม่เข้าเงื่อนไข "ทุกบรรทัดเป็นบัญชีต้นทุน"
--     ใบตัดหนี้สูญ (Dr 1290 / Cr 1200) ก็ไม่เข้า เพราะ 1200 เป็นบัญชีพักของ
--     ตารางกฎ → **การตัดหนี้สูญบางส่วนยังทำได้ตามปกติ**
--     วันนี้มีแค่สองหมวดย้ายวัตถุประสงค์ที่เข้าเงื่อนไขนี้ และหมวดย้ายตัวใหม่
--     ในอนาคตถูกครอบเองโดยไม่ต้องแก้ด่าน
--
--   **ข้อ (ข) บังคับ "ทรัพย์ชิ้นเดียวกัน" ด้วย** (ผู้ตรวจ 27/10 · ช่องที่สองของไฟล์นี้)
--     รุ่นแรกนิยามใบย้ายจาก "ทุกบรรทัดเป็นบัญชีต้นทุน" + "บัญชีต้นทางต้องเหลือศูนย์"
--     แต่ **ไม่ได้บังคับว่าขาเดบิตเป็นทรัพย์ชิ้นเดียวกับขาเครดิต** → ใบที่
--     `Cr 1500 ของทรัพย์ A` / `Dr 1520 ของทรัพย์ B` ผ่านทั้งข้อ (ก) (ไม่มีบัญชีไหน
--     ติดลบ) และผ่านลูป "ย้ายทั้งก้อน" (1500 ของ A เหลือศูนย์พอดี)
--     ผลคือ **ต้นทุนของ A หายไปทั้งก้อนและไปโป่งที่ B** โดยต้นทุนรวมทั้งงบเท่าเดิม
--     ตอนขาย A กำไรสูงกว่าจริงทั้งก้อน และ B ต่ำกว่าจริงเท่ากัน ·
--     ด่านต้นทุนเดิมสองตัวมองไม่เห็น: ฝั่ง A เหมือนตัดต้นทุนออกครบ (v_after = 0)
--     ฝั่ง B เหมือนซื้อเข้า (v_removed < 0) · engine กันไว้แล้วแต่เป็นด่านของ
--     เส้นทางหน้าจอเท่านั้น (บทเรียน mace-windu ข้อ 6)
--
--   **1290 ค่าเผื่อหนี้สงสัยจะสูญอยู่ในชุดด้วย** (เป็น contra ที่ยอดปกติอยู่ฝั่งเครดิต)
--     โดยตั้งใจ เพราะ `fn_asset_ledger_parts` นับมันเป็นบัญชีต้นทุนเหมือนกัน
--     ผลกับ **บรรทัดค่าเผื่อที่ผูกทรัพย์** ต่างกันตามว่าทรัพย์ชิ้นนั้นมีต้นทุนในสมุดอยู่หรือไม่
--     (เขียนให้ตรงความจริงหลังผู้ตรวจจับได้ว่าคอมเมนต์เดิมเคลมเกิน · 27/10):
--       - ทรัพย์ที่ **ยังไม่มีต้นทุน** (เคส N6e ของเทสต์) → ต้นทุนคงเหลือติดลบทันที
--         `trg_assert_asset_cost_sane` ข้อ (ก) ปฏิเสธอยู่แล้ว **ตั้งแต่ก่อนไฟล์นี้**
--       - ทรัพย์ที่ **มีต้นทุนอยู่แล้ว** → ต้นทุนคงเหลือยังเป็นบวก ด่านนั้นจึงไม่ฟ้อง
--         (ทรัพย์ `whole_item` ไปติด `trg_assert_asset_whole_disposal` เพราะนับเป็น
--         การตัดต้นทุนบางส่วน แต่ทรัพย์ `average`/`specific_lot` **ผ่านเงียบมาก่อน**)
--         → ไฟล์นี้ปฏิเสธด้วยข้อ (ก) เพราะยอด 1290 ต่อทรัพย์ติดลบ ซึ่งเป็นผลที่ถูกต้อง
--     ฟอร์มไม่ผูกทรัพย์กับหมวดค่าเผื่อ/ตัดหนี้สูญ (ตารางกฎบังคับแค่คู่ค้า)
--     → ไม่มีเส้นทางที่ถูกต้องเสียหาย และด่านสองตัวไม่ตัดสินคนละแบบ (ซึ่งแย่กว่า)
--     ถ้าวันหนึ่ง "ค่าเผื่อรายทรัพย์" กลายเป็นของที่ต้องทำได้
--     **ต้องแก้ทั้งสองด่านพร้อมกัน** ไม่ใช่แก้ตัวเดียว
--
--   **ใบกลับรายการ (source = 'reverse') ยกเว้นข้อ (ข)** โดยตั้งใจ — รูปเดียวกับ
--     `fn_assert_asset_cost_sane`: ใบกลับรายการต้องเป็นภาพกระจกของใบเดิมเป๊ะๆ
--     (กฎเหล็กข้อ 1) ถ้าบังคับข้อ (ข) กับมัน การกลับใบย้ายของทรัพย์ที่ซื้อเพิ่ม
--     เข้าบัญชีปลายทางภายหลังจะทำไม่ได้เลย = แก้ของที่ลงผิดไม่ได้
--
-- **ขอบเขตที่ไฟล์นี้ไม่ครอบ** — "ย้ายน้อยกว่ายอดคงเหลือ" ของใบที่ **มีขาอื่นปน**
--   (เช่นวันหนึ่งมีหมวดย้ายที่มีขาค่าธรรมเนียม) ข้อ (ข) จะไม่เข้าเงื่อนไข
--   ส่วนนั้นยังบังคับที่ `buildPosting()` ด้วยยอดที่อ่านจากสมุด (ธง wholeBalanceMove)
--   ถ้าวันหนึ่งมีหมวดแบบนั้นจริง ต้องเพิ่มด่านของมันที่นี่พร้อมกัน ไม่ใช่พึ่ง engine อย่างเดียว
--
-- ------------------------------------------------------------
-- ลำดับ: ต้องรัน **หลัง** 20261020000001 (v_ledger_posted) ·
--        หลัง 20261025000002 (แพทเทิร์นของด่านต้นทุนที่ไฟล์นี้ต่อจาก) ·
--        และหลัง seed ตารางกฎรุ่น 27/10 (มี 1520) — guard หัวไฟล์ตรวจให้ครบ
--        ลงทะเบียนใน `supabase/migration-order.txt` และ UNDER_TEST ของ
--        `scripts/test-rls-local.sh` ต่อท้ายไฟล์ 20261027041500_property_coa_set.sql
--
-- idempotent: `create or replace function` ทุกตัว + สร้าง trigger เฉพาะเมื่อยังไม่มี
--   (ตรวจจาก `pg_trigger` ใน do block) → replay ซ้ำได้ผลเดิม
--   **ไฟล์นี้ไม่มีคำสั่งถอนของ (และห้ามมีคำนั้นแม้ในคอมเมนต์)** เพราะตัวตรวจของ
--   MCP `apply_migration` อ่านจากข้อความดิบแล้ว timeout ทุกครั้ง (ดู CLAUDE.md)
--   จึงใช้ do block แทนรูปแบบ "ถอน trigger ก่อน create" ของไฟล์ก่อนๆ
--
-- ย้อนกลับ (rollback):
--   -- 1. ปิดด่านชั่วคราว (เปิดคืนด้วย enable trigger):
--   --    alter table sri_os.transaction_lines
--   --      disable trigger trg_assert_asset_account_balance_nonneg;
--   -- 2. ถอนฟังก์ชันทั้งสี่ออกถาวร ต้องทำใน migration ใหม่ (ไฟล์นี้เขียนคำสั่งถอน
--   --    ไม่ได้ด้วยเหตุผลข้างบน) · ฟังก์ชันที่ค้างไว้ไม่มีผลข้างเคียงถ้า trigger ปิดแล้ว
--   ⚠ ปิดแล้ว **ย้ายวัตถุประสงค์อสังหาฯ ด้วยยอดเท่าไรก็ได้** และบัญชีทรัพย์ติดลบได้
--     โดยไม่มีอะไรฟ้อง (ช่องเดิมของ 27/10) — ไม่แนะนำให้ย้อน
-- ============================================================

set search_path = sri_os, public;

-- ------------------------------------------------------------
-- guard หัวไฟล์ — ของที่ต้องมีอยู่ก่อน ไม่งั้นด่านจะครอบของว่างแบบเงียบๆ
-- ------------------------------------------------------------
do $$
begin
  if to_regclass('sri_os.v_ledger_posted') is null then
    raise exception 'ไม่มี v_ledger_posted → ต้องรัน 20261020000001_void_columns_and_views.sql ก่อนไฟล์นี้ (ยอดคงเหลือต้องไม่นับใบที่ยกเลิกแล้ว · D-098)';
  end if;
  if to_regclass('sri_os.txn_types') is null then
    raise exception 'ไม่มีตาราง txn_types → ด่านนี้อ่านบัญชีพักจากตารางกฎ ต้อง seed ตารางกฎก่อน';
  end if;
  if not exists (select 1 from sri_os.txn_types where accrual_coa_code is not null) then
    raise exception 'txn_types ไม่มี accrual_coa_code เลยแม้แถวเดียว → ตารางกฎยังไม่ถูก seed · ด่านจะนับบัญชีลูกหนี้เป็นบัญชีต้นทุนรายทรัพย์ แล้วการตั้งค้างรับของทรัพย์จะถูกปฏิเสธ';
  end if;
  if not exists (select 1 from sri_os.chart_of_accounts where code = '1520') then
    raise exception 'ไม่มีรหัส 1520 อสังหาฯ เพื่อการขายในผังบัญชี → seed ผังบัญชีรุ่น 27/10 ก่อน (npm run sync:rules)';
  end if;
end $$;

-- ============================================================
-- 1 · "บัญชีนี้นับเป็นต้นทุนรายทรัพย์ไหม"
--
--   **ชุดเดียวกับ `is_cost_account` ใน `fn_asset_ledger_parts` (20261025000002)
--   เป๊ะๆ** — เขียนเป็นฟังก์ชันเพื่อให้ด่านทุกตัวถามที่เดียวกัน และเพื่อให้
--   ด่านต้นทุนที่มีอยู่กับด่านใหม่ **ตัดสินจากนิยามเดียวกัน** (สองด่านที่คิด
--   คนละชุดคือความผิดแบบที่แพงที่สุด: อันหนึ่งยอม อันหนึ่งไม่ยอม แล้วไม่มีใครรู้ว่าอันไหนถูก)
--
--   ที่ตัดออกและเหตุผล:
--     11xx เงินสด/เงินฝาก  — เป็นอีกขาของรายการ ไม่ใช่ตัวทรัพย์
--     1800 ภาษีถูกหักรอเครดิต — เครดิตภาษีของผู้ถือ ไม่ใช่ต้นทุนของทรัพย์
--     บัญชีพักของตารางกฎ (1200/1210/1220/…) — ลูกหนี้ค่าเช่าของคอนโดผูกทรัพย์
--       อยู่แล้วโดยถูกต้อง (D-112 ข้อ 4) และยอดมันแกว่งขึ้นลงตามการเก็บเงิน
--       การกันไม่ให้ติดลบของบัญชีพักเป็นเรื่องของด่านล้างยอด
--       (`trg_assert_clearing_not_over` · 20261025000003) ไม่ใช่ด่านนี้
--
--   **1290 อยู่ในชุด** (เหตุผลเต็มที่หัวไฟล์) — เหมือนที่ `fn_asset_ledger_parts`
--     นับมัน · บรรทัดค่าเผื่อที่ผูกทรัพย์ซึ่ง **ยังไม่มีต้นทุน** ถูกด่านต้นทุนปฏิเสธ
--     อยู่แล้วก่อนไฟล์นี้ ส่วนทรัพย์ที่ **มีต้นทุนอยู่แล้ว** ด่านนั้นไม่ฟ้อง
--     (ไฟล์นี้ปฏิเสธด้วยข้อ (ก) เพราะยอด 1290 ต่อทรัพย์ติดลบ) — รายละเอียดที่หัวไฟล์
-- ============================================================
create or replace function fn_asset_cost_coa(p_code text) returns boolean
language sql stable set search_path = '' as $fn$
  select coalesce(bool_or(
           c.type::text = 'asset'
           and c.code !~ '^11[0-9][0-9]$'
           and c.code <> '1800'
           and not exists (select 1 from sri_os.txn_types ty
                            where ty.accrual_coa_code = c.code)
         ), false)
    from sri_os.chart_of_accounts c
   where c.code = p_code;
$fn$;

comment on function fn_asset_cost_coa(text) is
  'บัญชีที่นับเป็นต้นทุนรายทรัพย์ (ยอดคงเหลือต่อทรัพย์ติดลบไม่ได้) · **นิยามเดียวกับ is_cost_account ของ fn_asset_ledger_parts เป๊ะๆ** เพื่อให้ด่านต้นทุนกับด่านยอดรายบัญชีตัดสินจากชุดเดียวกัน · รหัสที่ไม่มีในผังบัญชีคืน false ไม่ใช่ null (27/10)';

revoke all on function fn_asset_cost_coa(text) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_asset_cost_coa(text) from anon';
  execute 'grant execute on function sri_os.fn_asset_cost_coa(text) to authenticated';
end $$;

-- ============================================================
-- 2 · ยอดคงเหลือของทรัพย์ชิ้นหนึ่งในบัญชีหนึ่ง — **ตัวที่ฟอร์มต้องอ่าน**
--
--   `p_exclude_txn` = "ก่อนใบนี้ยอดเป็นเท่าไร" (ด่านใช้ประกอบข้อความ)
--   อ่านผ่าน `v_ledger_posted` ไม่ใช่ตารางฐาน → ใบที่ยกเลิกแล้วไม่นับ (D-098)
--
--   ฟอร์มต้องเรียกตัวนี้เพื่อใส่ `balanceMove.sourceBalance` ของ `buildPosting()`
--   **ห้ามให้ผู้ใช้พิมพ์ยอดนี้เอง** (D-115) — ยอดที่พิมพ์คือยอดที่ตรวจไม่ได้
-- ============================================================
create or replace function fn_asset_account_balance(
  p_asset uuid,
  p_coa text,
  p_exclude_txn uuid default null
) returns numeric
language sql stable set search_path = '' as $fn$
  select coalesce(sum(v.debit - v.credit), 0)
    from sri_os.v_ledger_posted v
    join sri_os.chart_of_accounts c on c.id = v.coa_id
   where v.line_asset_id = p_asset
     and c.code = p_coa
     and (p_exclude_txn is null or v.transaction_id <> p_exclude_txn);
$fn$;

comment on function fn_asset_account_balance(uuid, text, uuid) is
  'ยอดคงเหลือของทรัพย์ชิ้นหนึ่งในบัญชีหนึ่ง (debit − credit) คิดสดจาก v_ledger_posted · ฟอร์มต้องอ่านยอดต้นทางจากที่นี่ก่อนลงใบย้ายวัตถุประสงค์ ห้ามให้ผู้ใช้พิมพ์เอง (D-115) · p_exclude_txn = ยอดก่อนใบนั้น ใช้โดยด่าน fn_assert_asset_account_balance_nonneg';

revoke all on function fn_asset_account_balance(uuid, text, uuid) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_asset_account_balance(uuid, text, uuid) from anon';
  execute 'grant execute on function sri_os.fn_asset_account_balance(uuid, text, uuid) to authenticated';
end $$;

-- ============================================================
-- 3 · ด่าน — ยอดติดลบต่อ (ทรัพย์ × บัญชี) · และใบย้ายต้องย้ายทั้งก้อน
--
-- ทำไมเป็น constraint trigger แบบ deferred: ต้องอ่าน **ทุกบรรทัดของใบ**
--   (ขาออกกับขาเข้าอยู่คนละบรรทัด) ถ้ายิงตอนใส่บรรทัดแรก ใบที่ถูกต้องจะลงไม่ได้เลย
--   — รูปเดียวกับ trg_assert_balanced / trg_assert_asset_cost_sane
--
-- security definer + search_path ล็อก: ต้องได้ **คำตอบจริง** ของทรัพย์ชิ้นนั้น
--   ไม่ใช่ได้ 0 เพราะผู้เรียกมองบรรทัดเก่าไม่เห็น (เหตุผลเดียวกับ fn_assert_wht_gross)
--   → เรียกตรงไม่ได้ทุก role (D-089 ข้อ row_escape จับทันทีถ้าเปิดไว้)
-- ============================================================
create or replace function fn_assert_asset_account_balance_nonneg() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_txn     uuid := coalesce(new.transaction_id, old.transaction_id);
  v_source  text;
  v_pure    boolean;
  v_noasset int;
  v_assets  int;
  v_list    text;
  v_name    text;
  v_before  numeric;
  v_after   numeric;
  r         record;
begin
  select t.source::text into v_source
    from sri_os.transactions t where t.id = v_txn;
  if v_source is null then
    return null;   -- หัวรายการหายไปแล้ว (cascade) → ไม่มีอะไรให้ตรวจ
  end if;

  -- ---------- (ก) ยอดคงเหลือต่อ (ทรัพย์ × บัญชีต้นทุน) ติดลบไม่ได้ ----------
  for r in
    select distinct lx.asset_id as asset_id, c.code as code
      from sri_os.transaction_lines lx
      join sri_os.chart_of_accounts c on c.id = lx.coa_id
     where lx.transaction_id = v_txn
       and lx.asset_id is not null
       and sri_os.fn_asset_cost_coa(c.code)
  loop
    v_after  := sri_os.fn_asset_account_balance(r.asset_id, r.code, null);
    if round(v_after, 2) < 0 then
      v_before := sri_os.fn_asset_account_balance(r.asset_id, r.code, v_txn);
      select a.code || ' ' || a.name into v_name from sri_os.assets a where a.id = r.asset_id;
      raise exception 'ทรัพย์ "%" มียอดคงเหลือในบัญชี % เพียง % บาท ก่อนใบนี้ แต่ใบนี้ทำให้เหลือ % บาท → **ยอดคงเหลือต่อทรัพย์ติดลบ** · ตัดหรือย้ายออกมากกว่าที่ถืออยู่ในบัญชีนั้นไม่ได้ · ยอดรวมของทรัพย์อาจไม่เปลี่ยน (ย้ายออกบัญชีหนึ่งเข้าอีกบัญชีหนึ่ง) แต่งบดุลจะอ่านได้ว่าบัญชีต้นทางติดลบและบัญชีปลายทางบวมเกินจริง — ต้องย้าย/ตัดได้ไม่เกินยอดที่สมุดบอก (อ่านด้วย sri_os.fn_asset_account_balance)',
        coalesce(v_name, r.asset_id::text), r.code, round(v_before, 2), round(v_after, 2);
    end if;
  end loop;

  -- ใบกลับรายการต้องเป็นภาพกระจกของใบเดิม (กฎเหล็กข้อ 1) → ไม่ติดข้อ (ข)
  if v_source = 'reverse' then
    return null;
  end if;

  /* ---------- (ข) ใบย้ายต้นทุนระหว่างบัญชีทรัพย์ → ย้ายทั้งก้อน ----------
   *
   * "ใบย้าย" ตัดสินจาก **ของจริงของบรรทัด**: ทุกบรรทัดในใบเป็นบัญชีต้นทุนรายทรัพย์
   * (ไม่มีขาเงินสด · ไม่มีขา P&L · ไม่มีขาหนี้สิน/ส่วนของเจ้าของ · ไม่มีบัญชีพัก)
   * ซึ่งเป็นจริงกับหมวดย้ายวัตถุประสงค์อสังหาฯ เท่านั้นในวันนี้ และกับหมวดย้าย
   * ตัวใหม่ในอนาคตโดยไม่ต้องแก้ด่าน · **ไม่เช็ครหัสหมวดตรงๆ** (กฎเหล็กข้อ 5)
   */
  select not exists (
           select 1
             from sri_os.transaction_lines lx
             join sri_os.chart_of_accounts c on c.id = lx.coa_id
            where lx.transaction_id = v_txn
              and not sri_os.fn_asset_cost_coa(c.code)
         )
    into v_pure;
  if not coalesce(v_pure, false) then
    return null;
  end if;

  -- ย้ายต้นทุนโดยไม่ผูกทรัพย์ = ต้นทุนรายชิ้นแยกออกจากกันไม่ได้หลังย้าย
  select count(*) into v_noasset
    from sri_os.transaction_lines lx
   where lx.transaction_id = v_txn and lx.asset_id is null;
  if v_noasset > 0 then
    raise exception 'ใบนี้ย้ายต้นทุนระหว่างบัญชีสินทรัพย์ แต่มี % บรรทัดที่ไม่ผูกทรัพย์ — ย้ายแล้วต้นทุนรายชิ้นแยกออกจากกันไม่ได้ (fn_asset_cost_basis รวมเฉพาะบรรทัดที่ผูกทรัพย์) ทุกบรรทัดของใบย้ายต้องมี asset_id',
      v_noasset;
  end if;

  /* ทุกบรรทัดของใบย้ายต้องผูก **ทรัพย์ชิ้นเดียวกัน** (ผู้ตรวจ 27/10)
   *
   * ลูปข้างล่างตรวจ "บัญชีต้นทางเหลือศูนย์" **ต่อ (ทรัพย์ × บัญชี)** → ใบที่
   * `Cr 1500 ของทรัพย์ A` / `Dr 1520 ของทรัพย์ B` ผ่านมันได้สบาย (1500 ของ A
   * เหลือศูนย์พอดี) และผ่านข้อ (ก) ด้วย เพราะไม่มีบัญชีไหนติดลบ
   * ผลคือต้นทุนของ A **หายทั้งก้อน** ไปโป่งที่ B โดยต้นทุนรวมทั้งงบไม่เปลี่ยน
   * — ความผิดแบบที่ไม่มีใครเห็นจนถึงวันขาย แล้วกำไรของทั้งสองชิ้นผิดทั้งคู่
   */
  select count(distinct lx.asset_id),
         string_agg(distinct coalesce(a.code || ' ' || a.name, lx.asset_id::text), ' · ')
    into v_assets, v_list
    from sri_os.transaction_lines lx
    left join sri_os.assets a on a.id = lx.asset_id
   where lx.transaction_id = v_txn;
  if coalesce(v_assets, 0) > 1 then
    raise exception 'ใบนี้ย้ายต้นทุนระหว่างบัญชีสินทรัพย์ แต่บรรทัดในใบผูกทรัพย์ **ต่างกัน % ชิ้น** (%) — ใบย้ายวัตถุประสงค์ต้องเป็นของทรัพย์ **ชิ้นเดียวกันทุกบรรทัด** · ถ้าขาเครดิตเป็นทรัพย์ชิ้นหนึ่งแต่ขาเดบิตเป็นอีกชิ้น ต้นทุนของชิ้นแรกจะ **หายไปทั้งก้อนและไปโป่งที่ชิ้นที่สอง** โดยต้นทุนรวมทั้งงบยังเท่าเดิม จึงไม่มีด่านต้นทุนตัวไหนฟ้อง (ฝั่งแรกดูเหมือนตัดออกครบ ฝั่งที่สองดูเหมือนซื้อเข้า) แล้วตอนขายชิ้นแรกจะได้กำไรสูงกว่าจริงทั้งก้อน และชิ้นที่สองต่ำกว่าจริงเท่ากัน · การย้ายทรัพย์ไปเป็นต้นทุนของทรัพย์อีกชิ้นไม่ใช่การย้ายวัตถุประสงค์ ต้องลงเป็นการขายออกและซื้อเข้าของแต่ละชิ้น (D-112)',
      v_assets, v_list;
  end if;

  for r in
    select lx.asset_id as asset_id, c.code as code,
           sum(lx.credit - lx.debit) as moved_out
      from sri_os.transaction_lines lx
      join sri_os.chart_of_accounts c on c.id = lx.coa_id
     where lx.transaction_id = v_txn
       and lx.asset_id is not null
     group by lx.asset_id, c.code
    having round(sum(lx.credit - lx.debit), 2) > 0
  loop
    v_after := sri_os.fn_asset_account_balance(r.asset_id, r.code, null);
    if round(v_after, 2) <> 0 then
      v_before := sri_os.fn_asset_account_balance(r.asset_id, r.code, v_txn);
      select a.code || ' ' || a.name into v_name from sri_os.assets a where a.id = r.asset_id;
      raise exception 'ใบนี้ย้ายต้นทุนของทรัพย์ "%" ออกจากบัญชี % เพียง % บาท จากยอดคงเหลือ % บาท และยังเหลือ % บาทค้างอยู่ — การย้ายวัตถุประสงค์ต้องย้าย **ทั้งก้อน** ไม่งั้นทรัพย์ชิ้นเดียวค้างอยู่สองวัตถุประสงค์พร้อมกัน และงบดุลอ่านไม่ออกว่าถือไว้เพื่ออะไร · ถ้าจะแบ่งวัตถุประสงค์จริงต้องแยกทรัพย์เป็นสองชิ้นก่อน (D-112) · ยอดที่ย้ายต้องมาจาก sri_os.fn_asset_account_balance ไม่ใช่จากที่ผู้ใช้พิมพ์',
        coalesce(v_name, r.asset_id::text), r.code, round(r.moved_out, 2),
        round(v_before, 2), round(v_after, 2);
    end if;
  end loop;

  return null;
end $fn$;

comment on function fn_assert_asset_account_balance_nonneg() is
  '27/10 · ต่อทรัพย์ที่ใบนี้แตะ: (ก) ยอดคงเหลือต่อ (ทรัพย์ × บัญชีต้นทุน) ติดลบไม่ได้ — ปิดช่องที่ใบย้ายวัตถุประสงค์อสังหาฯ ใช้ยอดที่ผู้ใช้พิมพ์ (3,000,000 → พิมพ์ 30,000,000) แล้วด่านต้นทุนทั้งสองตัวข้ามไปเพราะต้นทุนรวมไม่เปลี่ยน (v_removed = 0) · (ข) ใบที่ทุกบรรทัดเป็นบัญชีต้นทุนรายทรัพย์ (= ใบย้ายต้นทุน ตัดสินจากบรรทัดจริง ไม่ใช่รหัสหมวด) ต้องย้ายทั้งก้อนจนบัญชีต้นทางเหลือศูนย์ · ทุกบรรทัดต้องผูกทรัพย์ **และต้องเป็นทรัพย์ชิ้นเดียวกันทุกบรรทัด** (ใบ Cr ทรัพย์ A / Dr ทรัพย์ B ทำให้ต้นทุนของ A หายทั้งก้อนไปโป่งที่ B โดยต้นทุนรวมทั้งงบเท่าเดิม ด่านต้นทุนเดิมทั้งสองตัวมองไม่เห็น · 27/10) · ใบกลับรายการยกเว้นข้อ (ข)';

-- เรียกตรงไม่ได้ทุก role — definer ที่อ่าน transactions/transaction_lines
-- (ทั้งคู่จัดประเภทเป็น row ด้วย ledger.read) คือทางข้าม policy ถ้าเปิดไว้ · D-089
revoke all on function fn_assert_asset_account_balance_nonneg() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_asset_account_balance_nonneg() from anon, authenticated';
end $$;

-- ------------------------------------------------------------
-- ผูก trigger — สร้างเฉพาะเมื่อยังไม่มี (idempotent โดยไม่ต้องถอนของเก่า)
-- ------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.transaction_lines'::regclass
                    and g.tgname = 'trg_assert_asset_account_balance_nonneg'
                    and not g.tgisinternal) then
    execute 'create constraint trigger trg_assert_asset_account_balance_nonneg
               after insert or update or delete on sri_os.transaction_lines
               deferrable initially deferred
               for each row execute function sri_os.fn_assert_asset_account_balance_nonneg()';
  end if;
end $$;

-- ============================================================
-- guard ท้ายไฟล์ — ดังตอน migrate ไม่ใช่ตอนผู้ใช้กด
-- ============================================================
do $$
declare v_code text;
begin
  -- (ก) trigger ต้องผูกอยู่กับฟังก์ชันตัวนี้จริง
  if not exists (select 1 from pg_trigger g
                  join pg_proc p on p.oid = g.tgfoid
                 where g.tgrelid = 'sri_os.transaction_lines'::regclass
                   and g.tgname = 'trg_assert_asset_account_balance_nonneg'
                   and p.proname = 'fn_assert_asset_account_balance_nonneg'
                   and g.tgdeferrable and g.tginitdeferred
                   and not g.tgisinternal) then
    raise exception 'trigger trg_assert_asset_account_balance_nonneg ไม่ได้ผูกกับ fn_assert_asset_account_balance_nonneg แบบ deferrable initially deferred — ด่านจะยิงผิดจังหวะแล้วใบที่ถูกต้องลงไม่ได้';
  end if;

  -- (ข) นิยาม "บัญชีต้นทุนรายทรัพย์" ต้องตอบถูกทั้งสองทิศ — ไล่จากของจริงในผังบัญชี
  --     ทิศหนึ่งผิด = ด่านครอบของว่าง · ทิศสองผิด = ด่านปฏิเสธรายการที่ถูกต้อง
  --     1290 อยู่ฝั่ง "ใช่" เพราะ fn_asset_ledger_parts นับมันเหมือนกัน (ดูหัวไฟล์)
  foreach v_code in array array['1500', '1510', '1520', '1700', '1720', '1290'] loop
    if exists (select 1 from sri_os.chart_of_accounts where code = v_code)
       and not sri_os.fn_asset_cost_coa(v_code) then
      raise exception 'fn_asset_cost_coa(%) = false ทั้งที่ fn_asset_ledger_parts นับบัญชีนี้เป็นต้นทุนของทรัพย์ — ด่านสองตัวจะตัดสินคนละชุด', v_code;
    end if;
  end loop;
  foreach v_code in array array['1100', '1800', '1200', '1210', '1220', '3300', '3400', '4200', '5920'] loop
    if exists (select 1 from sri_os.chart_of_accounts where code = v_code)
       and sri_os.fn_asset_cost_coa(v_code) then
      raise exception 'fn_asset_cost_coa(%) = true ทั้งที่ไม่ใช่บัญชีต้นทุนรายทรัพย์ (เงินสด / ภาษีถูกหัก / บัญชีพักลูกหนี้-เจ้าหนี้ / ไม่ใช่สินทรัพย์) — ด่านจะปฏิเสธรายการที่ถูกต้อง', v_code;
    end if;
  end loop;
  -- รหัสที่ไม่มีในผังบัญชีต้องได้ false ไม่ใช่ null (null ทำให้เงื่อนไขของด่านกลายเป็นไม่รู้)
  if sri_os.fn_asset_cost_coa('9999') is distinct from false then
    raise exception 'fn_asset_cost_coa() คืนค่าที่ไม่ใช่ false สำหรับรหัสที่ไม่มีในผังบัญชี';
  end if;

  raise notice 'ok · ด่านยอดคงเหลือต่อ (ทรัพย์ × บัญชี) พร้อมใช้ · ติดลบไม่ได้ · ใบย้ายต้นทุนระหว่างบัญชีทรัพย์ต้องย้ายทั้งก้อน';
end $$;
