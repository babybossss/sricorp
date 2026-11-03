-- ============================================================
-- SRI OS · ต้นทุนถัวเฉลี่ย + ล้างส่วนเกินทุนตามสัดส่วน (D-112 ข้อ 1)
--
-- **ปัญหาที่ไฟล์นี้ปิด — กำไรปลอม ที่ผู้ตรวจวัดได้จริงบน PG16**
--   `fn_asset_cost_basis()` รุ่น 20261024000001 กันบรรทัดของ **ใบตีราคา** ออกแล้ว
--   แต่ **ไม่ได้กันขา 1700 ที่คู่กับบรรทัดล้าง 3400 ของใบขาย**
--   ซึ่ง `posting.ts` เติมให้ทุกใบที่ขายทรัพย์ที่เคยตีราคาไว้:
--       Dr 3400 (ล้างส่วนเกินทุน)   Cr 1700 (ตัดส่วนที่ตีเพิ่มออกจากบัญชีทรัพย์)
--   ขา Cr 1700 นั้น **ไม่ใช่การลดต้นทุน** (ต้นทุนเดิมไม่เคยมีส่วนนั้นอยู่)
--   แต่ฟังก์ชันนับเป็นการลดต้นทุน → วัดได้:
--       ซื้อ 10 หน่วย 1,000,000 → ตีขึ้น 460,000 → ขาย 3 หน่วย
--       → ต้นทุนคงเหลือ 240,000 (ที่ถูกคือ 700,000) → ขายส่วนที่เหลือจะโชว์
--         "กำไร" งอกมา 460,000 ที่ไม่มีอยู่จริง และยอด 3400 เดือนถัดไปเพี้ยนตาม
--
-- **สิ่งที่ D-112 เพิ่มเข้ามา (24/10)**
--   หุ้นตัวเดียวกันเก็บเป็นล็อตเพื่อตรวจสอบ **แต่คิดต้นทุนแบบถัวเฉลี่ย ไม่ใช่ FIFO**
--   → ขายบางส่วนต้องล้าง 3400 **ตามสัดส่วน** (ขาย 3 ใน 10 → ล้าง 30%)
--   → กำไรคิดจากต้นทุนถัวเฉลี่ยของทั้งกอง ไม่ใช่ราคาของล็อตที่ขาย
--   → กำไรที่ยังไม่ขายโชว์ได้ แต่ห้ามเข้า P&L เด็ดขาด (ย้ำจาก D-111)
--
--   **ฐานข้อมูลยังไม่มีจำนวนหน่วยที่ผูกกับใบ และไม่มีตารางล็อตเลย**
--   มีแต่ `assets.units` (ยอดคงเหลือรายทรัพย์) ซึ่ง **ใช้บังคับสัดส่วนไม่ได้**
--   เพราะเป็นคอลัมน์ที่แก้มือได้ ไม่มีอะไรผูกกับใบที่ลง และไม่มี trigger ตัวใด
--   ปรับมันตอนขาย → ด่านที่อ้างมันคือด่านที่ปลดได้ด้วยการแก้ค่าเดียว
--   → สัดส่วนฝั่ง DB จึงวัดด้วย **เงิน**:
--       สัดส่วนที่ขายออก = ต้นทุนที่ตัดออก ÷ ต้นทุนก่อนขาย
--   ซึ่ง **เท่ากับสัดส่วนจำนวนหน่วยพอดีเมื่อคิดต้นทุนแบบถัวเฉลี่ย** เพราะทุกหน่วย
--   มีต้นทุนต่อหน่วยเท่ากัน (ถ้าเป็น FIFO สองสัดส่วนนี้จะไม่เท่ากัน — อีกเหตุผล
--   ที่การตัดสินใจเรื่องถัวเฉลี่ยทำให้ด่านนี้บังคับได้ที่ DB โดยไม่ต้องรู้จำนวนหน่วย)
--   ฝั่งจำนวนหน่วย/ล็อตบังคับที่ `src/lib/ledger/average-cost.ts` + เทสต์ของมัน
--
-- **ทำไมต้องเป็นด่าน ไม่ใช่แค่แก้สูตร**
--   สูตรที่แก้แล้วคืนเลขถูกก็จริง แต่ถ้าใบขายล้าง 3400 ผิดจำนวน (ล้างทั้งก้อน
--   ตอนขายบางส่วน = สิ่งที่โค้ดทำอยู่วันนี้) **ตัวเลขทุกตัวยังสมดุลและไม่มีอะไรฟ้อง**
--   ต้นทุนคงเหลือจะไม่เท่าความจริงเงียบๆ → ต้องมีด่านที่ปฏิเสธใบนั้น ไม่ใช่คืนเลขผิด
--
-- ------------------------------------------------------------
-- ลำดับ: **ต้องรันหลัง 20261024000001_wht_and_fx.sql**
--   (ไฟล์นั้น `create or replace fn_asset_cost_basis` ไว้ — ถ้าไฟล์นี้รันก่อน
--    มันจะเขียนทับกลับเป็นรุ่นที่คืน 240,000 แล้วกำไรปลอมกลับมาทั้งก้อน)
--   และ **ก่อน 20261020000003_replay_end_state_guard.sql** (ไฟล์สุดท้ายเสมอ)
--   ลงทะเบียนใน supabase/migration-order.txt + UNDER_TEST ของ scripts/test-rls-local.sh
--
-- idempotent: create or replace function · drop trigger if exists ก่อน create ·
--   ไม่มี DDL ที่ทำซ้ำไม่ได้ → replay ซ้ำได้ตลอด
--
-- ย้อนกลับ (rollback) — เรียงจากหลังมาหน้า:
--   -- drop trigger  if exists trg_assert_asset_cost_sane on sri_os.transaction_lines;
--   -- drop function if exists sri_os.fn_assert_asset_cost_sane();
--   -- drop function if exists sri_os.fn_asset_surplus_mismatch();
--   -- drop function if exists sri_os.fn_asset_revaluation_surplus(uuid);
--   -- รัน 20261024000001_wht_and_fx.sql ซ้ำ (คืน fn_asset_cost_basis รุ่นก่อนไฟล์นี้)
--   -- drop function if exists sri_os.fn_asset_ledger_parts(uuid, uuid);
--   -- ย้อนแล้วได้สภาพเดิมคือ **ต้นทุนคงเหลือต่ำกว่าจริงเท่าส่วนที่ตีราคาไว้**
--   --   และขายบางส่วนล้าง 3400 เท่าไรก็ได้ — ไม่แนะนำให้ย้อน
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 1 · fn_asset_ledger_parts — ต้นทุนเดิม + ส่วนเกินทุนที่ค้าง **จากนิพจน์ชุดเดียว**
--
-- คืนสองค่าพร้อมกันโดยตั้งใจ: ทั้งสองอ่านจากบรรทัดชุดเดียวกันและต้องสอดคล้องกัน
-- (`ยอดบัญชีทรัพย์ = ต้นทุนคงเหลือ + ส่วนเกินทุนคงเหลือ` เสมอ) ถ้าเขียนแยกสองฟังก์ชัน
-- วันหนึ่งจะมีคนแก้ตัวเดียวแล้วสองยอดเล่าเรื่องต่างกัน (บทเรียนข้อ 5)
--
-- `p_exclude_txn` มีไว้ให้ด่านถามว่า "ก่อนใบนี้ยอดเป็นเท่าไร" โดยไม่ต้องคัดลอก
-- นิพจน์ไปเขียนใหม่ในตัวด่าน
--
-- **ต้นทุน** = บรรทัดบัญชีสินทรัพย์ที่ไม่ใช่เงินสด ของใบที่ **ไม่ใช่ใบตีราคา**
--   บวกขา 3400 ของใบเดียวกัน (ซึ่ง "คืน" ส่วนที่ไม่ใช่ต้นทุนกลับมา)
--   เช่น ใบขายที่ล้างส่วนเกินทุน 138,000: Cr 1700 138,000 (−138,000)
--        คู่กับ Dr 3400 138,000 (+138,000) → หักกันเป็นศูนย์ ต้นทุนจึงไม่ขยับ
--   ส่วนขา Cr 1700 300,000 ที่เป็นต้นทุนของหน่วยที่ขายจริง ยังลดต้นทุนตามปกติ
--
--   ยังกันใบตีราคาออกทั้งใบด้วยโดยตั้งใจ (ไม่ได้พึ่งการหักกันเอง) เพราะถ้าขา 3400
--   ของใบตีราคา **ไม่ได้ผูกทรัพย์** การหักกันจะไม่เกิด แล้วต้นทุนจะบวมเท่าที่ตีขึ้น
--
-- **ส่วนเกินทุน** = ทุกบรรทัด 3400 ของทรัพย์ชิ้นนั้น (เครดิต = เพิ่ม · เดบิต = ล้าง)
--   รวมทั้งของใบตีราคาและของขาล้างตอนขาย
-- ============================================================
create or replace function fn_asset_ledger_parts(
  p_asset uuid,
  p_exclude_txn uuid default null
) returns table (cost_basis numeric, surplus numeric)
language sql stable set search_path = '' as $fn$
  with l as (
    select c.code,
           /**
            * บรรทัดนี้เป็น "ต้นทุนของทรัพย์" หรือไม่ — **อ่านจากตารางกฎ ไม่ใช่รายชื่อรหัส**
            *
            * บัญชีสินทรัพย์ที่ **ไม่ใช่** ต้นทุนของทรัพย์:
            *   - เงินสด/เงินฝาก 11xx (เป็นอีกขาของรายการเดียวกัน)
            *   - บัญชีลูกหนี้-เจ้าหนี้ที่ตารางกฎใช้เป็น `accrual_coa_code`
            *     (1200 ลูกหนี้ค่าเช่า · 1210 ลูกหนี้ดอกเบี้ย · 1220 ลูกหนี้อื่น)
            *     ฟอร์มผูกทรัพย์กับรายการค่าเช่าด้วย (ซึ่งถูก · D-112 ข้อ 4 ต้องการ)
            *     → ถ้านับเป็นต้นทุน **ต้นทุนคอนโดจะบวมเท่าค่าเช่าที่ตั้งค้างทุกเดือน**
            *     แล้วยุบกลับตอนเก็บเงินได้ = ต้นทุนแกว่งตามลูกหนี้ โดยไม่มีอะไรฟ้อง
            *   - 1800 ภาษีถูกหัก ณ ที่จ่ายรอเครดิต (เป็นเครดิตภาษีของผู้ถือ
            *     ไม่ใช่ต้นทุนของทรัพย์ · engine ไม่ผูกทรัพย์กับบรรทัดนี้อยู่แล้ว
            *     แต่ด่านต้องไม่พึ่งว่า engine จำได้)
            */
           (c.type::text = 'asset'
            and c.code !~ '^11[0-9][0-9]$'
            and c.code <> '1800'
            and not exists (select 1 from sri_os.txn_types ty2
                             where ty2.accrual_coa_code = c.code)) as is_cost_account,
           c.type::text as kind,
           v.debit,
           v.credit,
           exists (
             select 1 from sri_os.txn_types ty
              where ty.code = v.txn_type_code
                and '3400' in (ty.dr_coa_code, ty.cr_coa_code)
           ) as is_revaluation
      -- **อ่านผ่าน v_ledger_posted ไม่ใช่ตารางฐาน** (D-098) — รายการที่ยกเลิกแล้ว
      -- ต้องไม่นับเป็นต้นทุน และ guard ของ 20261020000001 พังทันทีถ้าฟังก์ชัน
      -- แบบ set-returning อ่านตารางฐานตรงๆ (วิวนี้กรอง status = 'posted' ให้แล้ว)
      from sri_os.v_ledger_posted v
      join sri_os.chart_of_accounts c on c.id = v.coa_id
     where v.line_asset_id = p_asset
       and (p_exclude_txn is null or v.transaction_id <> p_exclude_txn)
  )
  select
    coalesce(sum(
      case when not is_revaluation and (is_cost_account or code = '3400')
           then debit - credit else 0 end), 0),
    coalesce(sum(case when code = '3400' then credit - debit else 0 end), 0)
    from l;
$fn$;

comment on function fn_asset_ledger_parts(uuid, uuid) is
  'D-112 · ต้นทุนเดิม (ถัวเฉลี่ยทั้งกอง) + ส่วนเกินทุนจากการตีราคาที่ค้างอยู่ ของทรัพย์ชิ้นหนึ่ง คิดสดจาก ledger ด้วยนิพจน์ชุดเดียว · ต้นทุนไม่นับใบตีราคา และหักขา 3400 ของใบขายออกจากกัน (ขาล้างส่วนเกินทุนไม่ใช่การลดต้นทุน — จุดที่เคยทำให้ต้นทุนคงเหลือต่ำกว่าจริง 460,000 ในฉากของผู้ตรวจ) · p_exclude_txn = ยอดก่อนใบนั้น ใช้โดยด่าน fn_assert_asset_cost_sane';

revoke all on function fn_asset_ledger_parts(uuid, uuid) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_asset_ledger_parts(uuid, uuid) from anon';
  execute 'grant execute on function sri_os.fn_asset_ledger_parts(uuid, uuid) to authenticated';
end $$;

-- ============================================================
-- 2 · fn_asset_cost_basis — ปากทางเดิมที่ทุกที่เรียกอยู่แล้ว · เนื้อในมาจากข้อ 1
--     (เขียนทับรุ่น 20261024000001 · ลายเซ็นเดิม จึงไม่ต้องแก้ผู้เรียก)
-- ============================================================
create or replace function fn_asset_cost_basis(p_asset uuid)
returns numeric
language sql stable set search_path = '' as $fn$
  select p.cost_basis from sri_os.fn_asset_ledger_parts(p_asset) p;
$fn$;

comment on function fn_asset_cost_basis(uuid) is
  'ต้นทุนของทรัพย์ (ถัวเฉลี่ยทั้งกอง · D-112) คำนวณสดจาก ledger ใช้เป็นฐานคำนวณกำไร/ขาดทุนตอนขาย · **ไม่นับใบตีราคา และไม่นับขาที่คู่กับบรรทัดล้าง 3400 ของใบขาย** · เนื้อในอยู่ที่ fn_asset_ledger_parts ที่เดียว';

revoke all on function fn_asset_cost_basis(uuid) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_asset_cost_basis(uuid) from anon';
  execute 'grant execute on function sri_os.fn_asset_cost_basis(uuid) to authenticated';
end $$;

-- ============================================================
-- 3 · fn_asset_revaluation_surplus — ส่วนเกินทุนที่ค้างอยู่ของทรัพย์ชิ้นนั้น
--
-- `planRevaluation()` ต้องการยอดนี้ (`priorSurplusThb`) และ **ต้องอ่านจากสมุดที่
-- post แล้วจริง ไม่ใช่จาก state ของหน้าจอ** — หน้าจอที่ยังไม่โหลดใหม่จะบอกว่า
-- "ยังไม่เคยตีราคา" ทั้งที่ตีไปแล้ว แล้วส่วนเกินทุนจะโตเป็นสองเท่า
-- ============================================================
create or replace function fn_asset_revaluation_surplus(p_asset uuid)
returns numeric
language sql stable set search_path = '' as $fn$
  select p.surplus from sri_os.fn_asset_ledger_parts(p_asset) p;
$fn$;

comment on function fn_asset_revaluation_surplus(uuid) is
  'D-111 ข้อ 2 · ส่วนเกินทุนจากการตีราคา (3400) ที่ยังค้างอยู่ของทรัพย์ชิ้นนั้นตามสมุดที่ post แล้ว · บวก = เคยตีขึ้น · ลบ = เคยตีลง · ใช้เป็น priorSurplusThb ของ planRevaluation() ซึ่งห้ามเดาจาก state ของหน้าจอ';

revoke all on function fn_asset_revaluation_surplus(uuid) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_asset_revaluation_surplus(uuid) from anon';
  execute 'grant execute on function sri_os.fn_asset_revaluation_surplus(uuid) to authenticated';
end $$;

-- ============================================================
-- 4 · ด่าน: ต้นทุนคงเหลือต้องเป็นความจริงเสมอ
--
-- ตรวจสามข้อ ต่อ **ทรัพย์แต่ละชิ้นที่ใบนี้แตะ** (ไม่ใช่ต่อบรรทัด) ตอน commit:
--
--   (ก) ต้นทุนคงเหลือหลังใบนี้ **ติดลบไม่ได้** — ตัดทรัพย์ออกมากกว่าที่ถืออยู่
--       แปลว่าจำนวนหรือยอดผิด ไม่ใช่ "ต้นทุนติดลบ" ที่มีความหมายทางบัญชี
--
--   (ข) ขายบางส่วนต้องล้าง 3400 **ตามสัดส่วนของต้นทุนที่ตัดออก** (D-112)
--         ส่วนเกินที่ต้องล้าง = ส่วนเกินก่อนขาย × (ต้นทุนที่ตัดออก ÷ ต้นทุนก่อนขาย)
--       ล้างมากกว่านั้น = ต้นทุนคงเหลือต่ำกว่าจริง แล้วการขายครั้งถัดไปโชว์กำไรปลอม
--       ล้างน้อยกว่านั้น = ส่วนเกินของหน่วยที่ขายไปแล้วค้างในส่วนของเจ้าของตลอดไป
--
--   (ค) ขายหมด (ต้นทุนคงเหลือ = 0) → ส่วนเกินทุนของทรัพย์นั้นต้องเหลือ **ศูนย์พอดี**
--       ข้อนี้ (ข) ครอบอยู่แล้วในทางคณิตศาสตร์ แต่ตรวจซ้ำแยกข้อเพราะเป็นข้อที่
--       "ทรัพย์ผีค้างในงบดุล" จะโผล่ และข้อความต้องชี้ตรงจุดนั้น
--
-- **รายการกลับรายการ (source = 'reverse') ไม่ติดข้อ (ข)** โดยตั้งใจ:
--   ใบกลับรายการต้องเป็นภาพกระจกของใบเดิมเป๊ะๆ (กฎเหล็กข้อ 1 · fn_assert_reverse_link
--   บังคับว่าต้องชี้ใบจริงของผู้ถือเดียวกัน) ถ้าบังคับสัดส่วนกับมันด้วย
--   การกลับใบซื้อของทรัพย์ที่เคยตีราคาจะทำไม่ได้เลย = แก้ของที่ลงผิดไม่ได้
--   ข้อ (ก) ยังบังคับกับใบกลับรายการ เพราะกลับแล้วต้นทุนติดลบก็ยังผิดอยู่
--
-- ทำไมเป็น constraint trigger แบบ deferred: ต้องอ่าน **ทุกบรรทัดของใบ**
--   (ขาต้นทุนกับขาล้างส่วนเกินอยู่คนละบรรทัด) ถ้ายิงตอนใส่บรรทัดแรก
--   ใบที่ถูกต้องจะลงไม่ได้เลย — รูปเดียวกับ trg_assert_balanced / trg_assert_wht_gross
--
-- security definer + search_path ล็อก: ต้องได้ **คำตอบจริง** ของทรัพย์ชิ้นนั้น
--   ไม่ใช่ได้ 0 เพราะผู้เรียกมองบรรทัดเก่าไม่เห็น (เหตุผลเดียวกับ fn_assert_wht_gross)
--   → เรียกตรงไม่ได้ทุก role (D-089 ข้อ row_escape จับทันทีถ้าเปิดไว้)
-- ============================================================
create or replace function fn_assert_asset_cost_sane() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_txn      uuid := coalesce(new.transaction_id, old.transaction_id);
  v_type     text;
  v_source   text;
  v_asset    uuid;
  v_name     text;
  v_before   numeric;
  v_sbefore  numeric;
  v_after    numeric;
  v_safter   numeric;
  v_removed  numeric;
  v_cleared  numeric;
  v_required numeric;
begin
  select t.txn_type_code, t.source::text into v_type, v_source
    from sri_os.transactions t where t.id = v_txn;
  if v_type is null then
    return null;   -- หัวรายการหายไปแล้ว (cascade) → ไม่มีอะไรให้ตรวจ
  end if;

  -- ทรัพย์ทุกชิ้นที่ใบนี้แตะด้วยบรรทัดที่มีผลต่อต้นทุนหรือส่วนเกินทุน
  for v_asset in
    select distinct lx.asset_id
      from sri_os.transaction_lines lx
      join sri_os.chart_of_accounts c on c.id = lx.coa_id
     where lx.transaction_id = v_txn
       and lx.asset_id is not null
       and ((c.type::text = 'asset' and c.code !~ '^11[0-9][0-9]$') or c.code = '3400')
  loop
    select cost_basis, surplus into v_before, v_sbefore
      from sri_os.fn_asset_ledger_parts(v_asset, v_txn);
    select cost_basis, surplus into v_after, v_safter
      from sri_os.fn_asset_ledger_parts(v_asset, null);

    v_removed := round(v_before - v_after, 2);
    v_cleared := round(v_sbefore - v_safter, 2);

    select a.code || ' ' || a.name into v_name
      from sri_os.assets a where a.id = v_asset;
    v_name := coalesce(v_name, v_asset::text);

    -- ---------- (ก) ต้นทุนคงเหลือติดลบไม่ได้ ----------
    if round(v_after, 2) < 0 then
      raise exception 'ทรัพย์ "%" มีต้นทุนคงเหลือ % บาท ก่อนใบนี้ แต่ใบนี้ตัดต้นทุนออก % บาท → **ต้นทุนคงเหลือติดลบ** (%) — ตัดทรัพย์ออกมากกว่าที่ถืออยู่ไม่ได้ · ถ้าขายมากกว่าที่บันทึกไว้ แปลว่ายังมีใบซื้อที่ไม่ได้ลง ต้องลงใบซื้อให้ครบก่อน ไม่ใช่ตัดต้นทุนที่ไม่มีอยู่',
        v_name, round(v_before, 2), v_removed, round(v_after, 2);
    end if;

    -- ---------- (ข) ล้างส่วนเกินทุนตามสัดส่วนที่ขายออก (D-112) ----------
    if v_source <> 'reverse' and v_removed > 0 and round(v_sbefore, 2) <> 0 then
      if round(v_before, 2) <= 0 then
        raise exception 'ทรัพย์ "%" มีส่วนเกินทุนจากการตีราคาค้างอยู่ % บาท แต่ไม่มีต้นทุนในสมุดเลย — คิดสัดส่วนที่ขายออกไม่ได้ · ส่วนเกินทุนที่ไม่มีต้นทุนรองรับแปลว่าใบซื้อหายไปจากสมุด',
          v_name, round(v_sbefore, 2);
      end if;
      v_required := round(v_sbefore * v_removed / v_before, 2);
      if abs(v_cleared - v_required) > 0.01 then
        raise exception 'ใบนี้ตัดต้นทุนของทรัพย์ "%" ออก % จาก % บาท (%.2f%% ของที่ถืออยู่) จึงต้องล้างส่วนเกินทุนจากการตีราคา **ตามสัดส่วน** = % บาท แต่ใบนี้ล้าง % บาท — ล้างเกินทำให้ต้นทุนคงเหลือต่ำกว่าจริง แล้วการขายครั้งถัดไปจะโชว์กำไรที่ไม่มีอยู่จริง · ล้างขาดทำให้ส่วนเกินทุนของหน่วยที่ขายไปแล้วค้างในส่วนของเจ้าของตลอดไป (D-112: เก็บเป็นล็อตเพื่อตรวจสอบ แต่คิดต้นทุนถัวเฉลี่ย)',
          v_name, v_removed, round(v_before, 2), (v_removed * 100 / v_before)::double precision,
          v_required, v_cleared;
      end if;
    end if;

    -- ---------- (ค) ขายหมดแล้วส่วนเกินทุนต้องเหลือศูนย์พอดี ----------
    -- เฉพาะใบที่ **ตัดต้นทุนออกจริง** (v_removed > 0) — ไม่ใช่ทุกใบที่แตะทรัพย์
    -- ที่ต้นทุนเป็นศูนย์อยู่แล้ว (เช่น ค่าเช่าค้างรับของทรัพย์ที่ยกยอดมาเฉพาะมูลค่า
    -- ยังไม่ได้ลงใบซื้อ) ไม่งั้นด่านจะปฏิเสธรายการที่ไม่เกี่ยวกับการขายเลย
    if v_removed > 0 and round(v_after, 2) = 0 and round(v_safter, 2) <> 0 then
      raise exception 'ทรัพย์ "%" ไม่มีต้นทุนคงเหลือแล้ว (ขายหมด) แต่ยังมีส่วนเกินทุนจากการตีราคาค้างอยู่ % บาท — ต้องล้างออกให้เหลือศูนย์พอดีในใบเดียวกับการขาย ไม่งั้นส่วนเกินทุนค้างในส่วนของเจ้าของตลอดไปทั้งที่ทรัพย์ไม่อยู่แล้ว และบัญชีทรัพย์ไม่กลับเป็นศูนย์ (ทรัพย์ผีในงบดุล)',
        v_name, round(v_safter, 2);
    end if;
  end loop;

  return null;
end $fn$;

comment on function fn_assert_asset_cost_sane() is
  'D-112 ข้อ 1 · ต่อทรัพย์ที่ใบนี้แตะ: (ก) ต้นทุนคงเหลือติดลบไม่ได้ (ข) ขายบางส่วนต้องล้าง 3400 ตามสัดส่วนของต้นทุนที่ตัดออก (ค) ขายหมดแล้ว 3400 ต้องเหลือศูนย์พอดี · ใบกลับรายการยกเว้นข้อ (ข) เพราะต้องเป็นภาพกระจกของใบเดิม · ด่านนี้ทำให้ "ต้นทุนคงเหลือ ≠ ความจริง" พังเสียงดังแทนที่จะคืนเลขผิดเงียบๆ';

-- เรียกตรงไม่ได้ทุก role — definer ที่อ่าน transactions/transaction_lines
-- (ทั้งคู่จัดประเภทเป็น row ด้วย ledger.read) คือทางข้าม policy ถ้าเปิดไว้ · D-089
revoke all on function fn_assert_asset_cost_sane() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_asset_cost_sane() from anon, authenticated';
end $$;

-- ชื่อ trg_lines_t* ไม่ได้ใช้: เป็น constraint trigger จึงยิงตอน commit อยู่แล้ว
-- (ลำดับกับด่าน before-row ไม่เกี่ยวกัน) · ชื่อสื่อความหมายตรงๆ แทน
drop trigger if exists trg_assert_asset_cost_sane on transaction_lines;
create constraint trigger trg_assert_asset_cost_sane
  after insert or update or delete on transaction_lines
  deferrable initially deferred
  for each row execute function fn_assert_asset_cost_sane();

-- ============================================================
-- 5 · fn_asset_surplus_mismatch — "3400 = มูลค่าล่าสุด − ต้นทุนคงเหลือ" ตรวจได้ตลอดเวลา
--
-- **ทำไมไม่ทำเป็น trigger**: การตีราคาแบบกลับรายการ (mark-to-market.ts) ลงสองใบ
--   คนละธุรกรรม — ระหว่างสองใบนั้น ส่วนเกินทุนเป็น 0 ชั่วคราวโดยถูกต้อง
--   trigger ที่บังคับสมการนี้ทุกธุรกรรมจะปฏิเสธ **ใบกลับรายการ** ซึ่งเป็นขั้นตอน
--   ที่ถูกต้องตามกฎเหล็กข้อ 1 → กลายเป็นด่านที่ห้ามสิ่งที่ต้องทำ
--   สิ่งที่บังคับได้ต่อใบคือ "สัดส่วน" (ข้อ 4) ส่วนสมการนี้เป็น **การกระทบยอด**
--   ที่ต้องเรียกดูได้ตลอดเวลา และต้องว่างเปล่าหลังตีราคาครบทุกชิ้นของเดือนนั้น
--
-- อ่าน `asset_valuations` แถวล่าสุดต่อทรัพย์ (ยอด **บาท** เสมอ ตาม D-111 ข้อ 2)
-- ทรัพย์ที่ยังไม่เคยตีราคาเลยไม่อยู่ในผลลัพธ์ (ไม่มีอะไรให้เทียบ ไม่ใช่ความผิด)
-- ============================================================
create or replace function fn_asset_surplus_mismatch()
returns table (
  asset_id         uuid,
  asset_code       text,
  valued_at        date,
  latest_value     numeric,
  cost_basis       numeric,
  surplus          numeric,
  expected_surplus numeric,
  diff             numeric
)
language sql stable set search_path = '' as $fn$
  select a.id, a.code, v.as_of, v.value, p.cost_basis, p.surplus,
         round(v.value - p.cost_basis, 2),
         round(p.surplus - (v.value - p.cost_basis), 2)
    from sri_os.assets a
    join lateral (
      select av.as_of, av.value
        from sri_os.asset_valuations av
       where av.asset_id = a.id
       order by av.as_of desc, av.created_at desc
       limit 1
    ) v on true
    cross join lateral sri_os.fn_asset_ledger_parts(a.id) p
   where (p.cost_basis <> 0 or p.surplus <> 0)
     and abs(round(p.surplus - (v.value - p.cost_basis), 2)) > 0.01;
$fn$;

comment on function fn_asset_surplus_mismatch() is
  'D-111 ข้อ 2 + D-112 · ทรัพย์ที่ "ส่วนเกินทุนที่ค้างใน 3400 ≠ มูลค่าตีราคาล่าสุด − ต้นทุนคงเหลือ" · ว่าง = กระทบยอดลง · ไม่ทำเป็น trigger เพราะการตีราคาแบบกลับรายการมีสถานะกลางที่ส่วนเกินทุนเป็น 0 โดยถูกต้อง (ดูหัวข้อ 5 ของ migration)';

revoke all on function fn_asset_surplus_mismatch() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_asset_surplus_mismatch() from anon';
  execute 'grant execute on function sri_os.fn_asset_surplus_mismatch() to authenticated';
end $$;

-- ============================================================
-- 6 · guard ท้ายไฟล์ — ดังตอน migrate ไม่ใช่ตอนผู้ใช้กดบันทึก
-- ============================================================
do $$
declare v text; n int;
begin
  -- (ก) ฟังก์ชันต้องมีจริงทั้งชุด และ fn_asset_cost_basis ต้องเป็นรุ่นที่ผ่านข้อ 1
  --     (ไฟล์ที่รันทีหลังแล้ว create or replace ทับ จะทำให้เงื่อนไขนี้แดง)
  select string_agg(x.want, ', ') into v
    from (values ('sri_os.fn_asset_ledger_parts(uuid,uuid)'),
                 ('sri_os.fn_asset_cost_basis(uuid)'),
                 ('sri_os.fn_asset_revaluation_surplus(uuid)'),
                 ('sri_os.fn_asset_surplus_mismatch()'),
                 ('sri_os.fn_assert_asset_cost_sane()')) x(want)
   where to_regprocedure(x.want) is null;
  if v is not null then
    raise exception 'ฟังก์ชันหายไป: %', v;
  end if;

  if not exists (
    select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'sri_os' and p.proname = 'fn_asset_cost_basis'
       and pg_get_functiondef(p.oid) like '%fn_asset_ledger_parts%') then
    raise exception 'fn_asset_cost_basis ไม่ได้อ่านจาก fn_asset_ledger_parts — มีไฟล์อื่นเขียนทับหลังไฟล์นี้ (ลำดับ migration ผิด) → ต้นทุนคงเหลือจะต่ำกว่าจริงเท่าส่วนที่ตีราคาไว้ และกำไรปลอมกลับมาทั้งก้อน';
  end if;

  -- (ข) ด่านต้องผูกกับตารางจริงและเป็น constraint trigger แบบ deferred
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.transaction_lines'::regclass
                    and g.tgname = 'trg_assert_asset_cost_sane'
                    and not g.tgisinternal and g.tgdeferrable and g.tginitdeferred) then
    raise exception 'trg_assert_asset_cost_sane ไม่ได้ผูกกับ transaction_lines แบบ deferrable initially deferred — ฟังก์ชันที่ไม่ได้ผูกกับตารางไม่ได้กันอะไรเลย';
  end if;

  -- (ค) definer ต้องเรียกตรงไม่ได้ (D-089) · ตัวอ่านต้องเรียกได้จริง (ไม่งั้นรายงานพัง)
  if has_function_privilege('authenticated', 'sri_os.fn_assert_asset_cost_sane()', 'execute')
     or has_function_privilege('anon', 'sri_os.fn_assert_asset_cost_sane()', 'execute') then
    raise exception 'fn_assert_asset_cost_sane ยังเรียกตรงได้ = definer ที่อ่านสมุดเงินโดยไม่ถามสิทธิ์';
  end if;
  if not has_function_privilege('authenticated', 'sri_os.fn_asset_cost_basis(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'sri_os.fn_asset_ledger_parts(uuid, uuid)', 'execute') then
    raise exception 'authenticated อ่านต้นทุนทรัพย์ไม่ได้ → หน้าจอขายทรัพย์และการตีราคาใช้ไม่ได้';
  end if;

  -- (ง) 3400 ต้องยังมีทางล้าง (บทเรียนข้อ 7) — หมวดที่รับรู้กำไร/ขาดทุนจากการขาย
  select count(*) into n from sri_os.txn_types t where t.requires_capital_gain;
  if n = 0 then
    raise exception 'ไม่มีหมวดที่รับรู้กำไร/ขาดทุนจากการขายเลย → ส่วนเกินทุนจากการตีราคาไม่มีทางล้าง และด่านข้อ 4 จะไม่ได้คุมอะไร';
  end if;

  raise notice 'ต้นทุนถัวเฉลี่ย (D-112) พร้อม: fn_asset_cost_basis อ่านจาก fn_asset_ledger_parts · ด่านสัดส่วนผูกกับ transaction_lines · หมวดที่รับรู้กำไรจากการขาย % หมวด', n;
end $$;
