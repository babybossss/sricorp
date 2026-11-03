-- ============================================================
-- SRI OS · **อัตราแลกเปลี่ยนที่มีรายการอ้างถึงแล้ว แก้ย้อนหลังไม่ได้**
--
-- ------------------------------------------------------------
-- **ที่มา — คลาส D-115 เป๊ะ**
--
-- policy `fx_rates_write` เป็น `for all` และมีแต่ trigger บันทึกประวัติ
-- → ผู้ใช้ที่มี `settings.manage` **UPDATE อัตราที่ถูกใช้แล้วได้ตรงๆ**
-- หน้าจอกันแล้ว (ไม่มีช่องให้แก้) แต่ **DB ไม่กัน** → คำขอที่ข้ามหน้าจอผ่านหมด
--
-- ตัวเลขที่วัดได้: ลง `trf.fx_acquire` 10,000 USD @36.50 = 365,000 บาท
--   แล้วแก้อัตราในตารางเป็น 40.00 → **เหลือส่วนต่าง 35,000 บาท**
--   (10,000 × (40.00 − 36.50)) ที่ไม่มีใครฟ้อง
--
-- **ทำไมอันตรายกว่าที่เห็น** — บรรทัดรายการเก็บอัตราที่ใช้ไว้ **ในตัวเอง**
-- (`transaction_lines.fx_rate`) และด่านของเรา **เทียบอัตรานั้นกับตาราง**
-- (`fn_assert_line_fx` ข้อ 2) ถ้าตารางเปลี่ยนย้อนหลัง:
--   1. ยอดบาทของรายการเก่าไม่ตรงกับอัตราในตารางอีก
--   2. ด่านที่เทียบอัตราเริ่ม **ปฏิเสธรายการเก่า** ทั้งที่รายการนั้นถูกตอนลง
--      (แก้รายการเก่า · กลับรายการ · อัปโหลดยอดตั้งต้นใหม่ → พังทั้งหมด)
--   3. ยอดในงบไม่ตรงกับที่เคยปิดงวดไว้ และ `fn_fx_position()` คิดต้นทุนจาก
--      `debit` ของบรรทัด (ไม่ใช่จากตาราง) → ต้นทุนกับอัตราเล่าเรื่องคนละเรื่อง
--
-- ------------------------------------------------------------
-- **กฎที่เลือก และเหตุผล**
--
-- | การแก้ | แถวที่ **มีรายการอ้างถึง** | แถวที่ **ยังไม่มีใครใช้** |
-- |---|---|---|
-- | `thb_per_unit` | **ปฏิเสธ** | แก้ได้ |
-- | `currency` / `rate_date` (คีย์) | **ปฏิเสธ** | แก้ได้ (FK กันอยู่แล้วอีกชั้น) |
-- | `source` | **ปฏิเสธ** | แก้ได้ |
-- | `note` | **แก้ได้ตลอด** | แก้ได้ |
-- | DELETE | **FK กันอยู่แล้ว** (`no action`) | ลบได้ |
--
-- **ทำไมไม่ห้ามแก้ทั้งหมด** — อัตราที่พิมพ์ผิดก่อนมีใครใช้ ต้องแก้ได้
-- ไม่งั้นทางเดียวคือลบแล้วใส่ใหม่ ซึ่งได้ผลเหมือนกันแต่ทำให้ประวัติอ่านยากกว่า
-- และ "ยังไม่มีใครใช้" **ตัดสินจากการ query ของจริง** (มีบรรทัดรายการหรือล็อต
-- ที่ชี้คีย์นี้หรือไม่) ไม่ใช่ป้ายที่ผู้เรียกส่งมา (D-115)
--
-- **`note` แก้ได้ตลอดโดยตั้งใจ** — ไม่กระทบตัวเลขเลย และเป็นที่เดียวที่คนจะ
-- บันทึกว่า "อัตานี้มาจากไหน/ทำไมต่างจากที่อื่น" ซึ่งเป็นสิ่งที่ควรเพิ่มได้ภายหลัง
--
-- **"มีรายการอ้างถึง" ไล่จากสามตาราง** — `transaction_lines` · `asset_lots` ·
-- `asset_valuations` (ทั้งสามมี FK `(currency, fx_rate_date) → fx_rates(currency, rate_date)`)
-- ตารางที่สาม (ใบตีราคาทรัพย์สกุลต่างประเทศ) **guard ท้ายไฟล์เป็นคนจับได้**
-- ตอนรันครั้งแรก ไม่ใช่ผมจำได้ — ซึ่งคือเหตุที่ guard แบบไล่ catalog ต้องมี
-- ถ้าวันหนึ่งมีตารางที่สามที่อ้างอัตรา **guard ท้ายไฟล์จะพังทันที** เพราะมันไล่
-- FK จาก catalog จริงแล้วเทียบกับรายการที่ฟังก์ชันนี้รู้จัก — ไม่ใช่รายการที่
-- ใครต้องจำมาเติม (รูปเดียวกับที่ `sync:rules` พังเมื่อมีฟิลด์ใหม่)
--
-- ------------------------------------------------------------
-- **ข้อ 2 ของคำสั่ง (ห้ามวันที่อนาคต) ยังไม่ลงในไฟล์นี้ — เหตุผล**
--
-- ด่าน `rate_date > current_date` เขียนง่าย แต่ **ทำให้ชุดเทสต์พังตามปฏิทิน**:
-- fixture ของ `zz_wht_and_fx_test.sql` และ `zz_fcd_currency_test.sql` ใช้
-- อัตราสิ้นเดือน `2026-10-31` · `2026-11-30` · `2026-12-31` ซึ่ง **อยู่ในอนาคต
-- เมื่อเทียบกับวันที่ของเครื่องตอนนี้ (2026-10-25)** → ลงด่านนี้แล้วสองไฟล์นั้น
-- แดงทันที และจะกลับมาเขียวเองเมื่อเวลาผ่านไป = เทสต์ที่ผลขึ้นกับวันที่รัน
-- ซึ่งแย่กว่าไม่มีด่าน (ไม่มีใครเชื่อผลเทสต์ที่เปลี่ยนตามปฏิทินได้)
--
-- ทางที่ถูกคือ **ย้าย timeline ของ fixture สองไฟล์นั้นไปเป็นอดีตก่อน**
-- (ทั้งแถวอัตรา · `fx_rate_date` ของทุกบรรทัดที่ชี้มา · และวันเอกสารที่
-- สัมพันธ์กัน) แล้วจึงลงด่าน — เป็นงานแก้ fixture ที่ต้องทำแยก ไม่ใช่งานเดียวกัน
-- กับการปิดรูนี้ · **ไฟล์นี้จึงปิดรูที่เป็นเรื่องเงิน (35,000 บาท) ก่อน**
-- และผมแจ้งให้ตัดสินใจเรื่อง timeline ของ fixture ต่อ
--
-- ------------------------------------------------------------
-- ลำดับ: **ต้องรันหลัง** 20261024000001 (ตาราง `fx_rates`) ·
--        20261025000004 (FK ของ `transaction_lines`) · 20261025000008 (`asset_lots`)
--        guard หัวไฟล์ตรวจให้
--
-- idempotent: `create or replace` · `drop trigger if exists` ก่อน create
--
-- ย้อนกลับ (rollback):
--   -- drop trigger if exists trg_fx_rates_immutable_when_used on sri_os.fx_rates;
--   -- drop function if exists sri_os.fn_assert_fx_rate_immutable();
--   -- drop function if exists sri_os.fn_fx_rate_in_use(text, date);
--   ⚠ ถอดแล้ว **แก้อัตราย้อนหลังได้อีก** → ยอดบาทของรายการเก่าไม่ตรงกับตาราง
--     ด่านที่เทียบอัตราเริ่มปฏิเสธรายการเก่า และงบไม่ตรงกับที่ปิดงวดไว้
-- ============================================================

set search_path = sri_os, public;

do $$
begin
  if to_regclass('sri_os.fx_rates') is null then
    raise exception 'ไม่มีตาราง fx_rates → ต้องรัน 20261024000001_wht_and_fx.sql ก่อนไฟล์นี้';
  end if;
  if to_regclass('sri_os.asset_lots') is null then
    raise exception 'ไม่มีตาราง asset_lots → ต้องรัน 20261025000008_asset_lots.sql ก่อนไฟล์นี้ (ไฟล์นี้ต้องนับการอ้างอิงจากทะเบียนล็อตด้วย)';
  end if;
end $$;

-- ============================================================
-- 1 · "อัตรานี้มีรายการอ้างถึงแล้วหรือยัง" — **ถามสมุดและทะเบียน ไม่ถามป้าย**
-- ============================================================
create or replace function fn_fx_rate_in_use(p_ccy text, p_date date) returns boolean
language sql stable security definer set search_path = '' as $fn$
  select exists (
           -- อ่าน **ตารางฐาน** ไม่ใช่ v_ledger_posted โดยตั้งใจ: ใบที่ยกเลิกแล้ว
           -- ก็ยังอ้างอัตรานั้นอยู่ในประวัติ และด่านที่เทียบอัตรายังเทียบกับมัน
           -- (ถ้านับแต่ใบที่ posted อัตราของใบที่ void แล้วจะแก้ได้ แล้วประวัติเพี้ยน)
           select 1 from sri_os.transaction_lines l
            where l.currency = p_ccy and l.fx_rate_date = p_date
         )
      or exists (
           select 1 from sri_os.asset_lots lo
            where lo.currency = p_ccy and lo.fx_rate_date = p_date
         )
      or exists (
           -- **ตารางที่สามที่ guard ท้ายไฟล์เป็นคนจับได้** (ผมไล่จาก FK แล้วเจอเอง
           -- ว่าใบตีราคาทรัพย์สกุลต่างประเทศก็อ้างอัตราด้วย) — ถ้าไม่มี guard
           -- ตัวนั้น อัตราที่ใบตีราคาใช้อยู่จะถูกแก้ย้อนหลังได้เงียบๆ
           select 1 from sri_os.asset_valuations av
            where av.currency = p_ccy and av.fx_rate_date = p_date
         );
$fn$;

comment on function fn_fx_rate_in_use(text, date) is
  'อัตราแลกเปลี่ยนแถวนี้มีรายการอ้างถึงแล้วหรือยัง · ไล่จาก transaction_lines และ asset_lots (สองตารางที่มี FK ชี้มาที่ fx_rates) ด้วยการ query ของจริง ไม่ใช่ป้ายที่ผู้เรียกส่ง (D-115) · อ่านตารางฐานไม่ใช่วิวที่กรองสถานะ เพราะใบที่ยกเลิกแล้วก็ยังอ้างอัตรานั้นในประวัติ';

revoke all on function fn_fx_rate_in_use(text, date) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_fx_rate_in_use(text, date) from anon';
  -- definer ที่อ่าน transaction_lines → เปิดให้ authenticated ไม่ได้ (D-089 row_escape)
  -- ด่านเรียกมันเองผ่าน trigger ซึ่งรันด้วยสิทธิ์ของเจ้าของ trigger
  execute 'revoke all on function sri_os.fn_fx_rate_in_use(text, date) from authenticated';
end $$;

-- ============================================================
-- 2 · ด่าน — แก้ค่าที่กระทบตัวเลขของแถวที่ถูกใช้แล้ว = ปฏิเสธ
-- ============================================================
create or replace function fn_assert_fx_rate_immutable() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_changed text[] := '{}';
begin
  -- `note` ไม่กระทบตัวเลข → แก้ได้ตลอด (และควรแก้ได้ เพื่อบันทึกที่มาของอัตรา)
  if new.thb_per_unit is distinct from old.thb_per_unit then
    v_changed := v_changed || array['อัตรา (thb_per_unit)'];
  end if;
  if new.currency is distinct from old.currency then
    v_changed := v_changed || array['สกุลเงิน (currency)'];
  end if;
  if new.rate_date is distinct from old.rate_date then
    v_changed := v_changed || array['วันของอัตรา (rate_date)'];
  end if;
  if new.source is distinct from old.source then
    v_changed := v_changed || array['ที่มาของอัตรา (source)'];
  end if;

  if cardinality(v_changed) = 0 then
    return new;   -- แก้แต่ note (หรือไม่ได้แก้อะไรที่กระทบตัวเลข)
  end if;

  if sri_os.fn_fx_rate_in_use(old.currency, old.rate_date) then
    raise exception 'อัตรา % วันที่ % มีรายการในสมุดหรือทะเบียนล็อตอ้างถึงแล้ว จึงแก้ % ย้อนหลังไม่ได้ — บรรทัดรายการเก็บอัตราที่ใช้ไว้ในตัวเอง และด่านของระบบเทียบอัตรานั้นกับตารางนี้ · แก้ตารางย้อนหลังจะทำให้ (1) ยอดบาทของรายการเก่าไม่ตรงกับอัตราในตาราง (2) ด่านเริ่มปฏิเสธรายการเก่าที่ถูกตอนลง (แก้/กลับรายการ/อัปโหลดยอดตั้งต้นใหม่จะพังทั้งหมด) (3) ยอดในงบไม่ตรงกับที่เคยปิดงวดไว้ · **ถ้าอัตราที่ใช้จริงต่างจากนี้ ให้เพิ่มอัตราของวันใหม่ แล้วลงรายการที่อ้างวันนั้น** ไม่ใช่แก้ของเดิม · ช่องหมายเหตุ (note) แก้ได้ตลอดเวลา',
      old.currency, old.rate_date, array_to_string(v_changed, ', ');
  end if;

  return new;
end $fn$;

comment on function fn_assert_fx_rate_immutable() is
  'อัตราแลกเปลี่ยนที่มีรายการอ้างถึงแล้ว: ห้ามแก้ thb_per_unit/currency/rate_date/source · note แก้ได้ตลอด (ไม่กระทบตัวเลข) · แถวที่ยังไม่มีใครใช้แก้ได้ทุกช่อง · "มีรายการอ้างถึง" อ่านจาก transaction_lines + asset_lots ด้วยการ query ของจริง (D-115) · DELETE ถูกกันด้วย FK อยู่แล้ว ไม่ต้องมีกฎที่นี่';

revoke all on function fn_assert_fx_rate_immutable() from public;
do $$ begin execute 'revoke all on function sri_os.fn_assert_fx_rate_immutable() from anon, authenticated'; end $$;

drop trigger if exists trg_fx_rates_immutable_when_used on fx_rates;
create trigger trg_fx_rates_immutable_when_used
  before update on fx_rates
  for each row execute function fn_assert_fx_rate_immutable();

-- ============================================================
-- 3 · guard ท้ายไฟล์ — ดังตอน migrate ไม่ใช่ตอนผู้ใช้กด
-- ============================================================
do $$
declare v text; n int; n_missing text;
begin
  -- (ก) trigger ต้องอยู่ และต้องเป็น before update (after จะสายไปแล้ว)
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.fx_rates'::regclass
                    and g.tgname = 'trg_fx_rates_immutable_when_used'
                    and not g.tgisinternal) then
    raise exception 'trigger trg_fx_rates_immutable_when_used ไม่ถูกสร้าง';
  end if;

  -- (ข) ฟังก์ชันต้องไม่เปิดให้ผู้ใช้แอป (definer ที่อ่าน transaction_lines)
  select string_agg(p.proname, ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.proname in ('fn_fx_rate_in_use', 'fn_assert_fx_rate_immutable')
     and (has_function_privilege('anon', p.oid, 'execute')
          or has_function_privilege('public', p.oid, 'execute')
          or has_function_privilege('authenticated', p.oid, 'execute'));
  if v is not null then
    raise exception 'ฟังก์ชันของไฟล์นี้เปิดให้ผู้ใช้แอปเรียก = ทางข้าม policy ของสมุด (D-089): %', v;
  end if;

  /**
   * (ค) **ทุกตารางที่มี FK ชี้มาที่ `fx_rates` ต้องถูกนับใน `fn_fx_rate_in_use`**
   *
   * ไล่จาก catalog จริง ไม่ใช่รายการที่ใครต้องจำมาเติม — ถ้าวันหนึ่งมีตาราง
   * ที่สามที่อ้างอัตรา ด่านนี้พังตอน migrate ไม่ใช่ปล่อยให้อัตราที่ตารางนั้น
   * ใช้อยู่ถูกแก้ย้อนหลังได้เงียบๆ (รูปเดียวกับที่ sync:rules พังเมื่อมีฟิลด์ใหม่)
   */
  v := pg_get_functiondef('sri_os.fn_fx_rate_in_use(text, date)'::regprocedure);
  select string_agg(c.relname::text, ', ') into n_missing
    from pg_constraint fk
    join pg_class c on c.oid = fk.conrelid
    join pg_class t on t.oid = fk.confrelid
   where fk.contype = 'f'
     and t.relname = 'fx_rates'
     and c.relnamespace = 'sri_os'::regnamespace
     and position(c.relname::text in v) = 0;
  if n_missing is not null then
    raise exception 'มีตารางที่อ้าง fx_rates แต่ fn_fx_rate_in_use ไม่ได้นับ: % — อัตราที่ตารางนั้นใช้อยู่จะถูกแก้ย้อนหลังได้', n_missing;
  end if;

  -- (ง) DELETE ต้องถูกกันด้วย FK จริง (no action/restrict) ไม่ใช่โดยแอป
  select string_agg(c.relname::text || '/' || fk.confdeltype::text, ', ') into v
    from pg_constraint fk
    join pg_class c on c.oid = fk.conrelid
    join pg_class t on t.oid = fk.confrelid
   where fk.contype = 'f' and t.relname = 'fx_rates'
     and c.relnamespace = 'sri_os'::regnamespace
     and fk.confdeltype not in ('a', 'r');   -- a = no action · r = restrict
  if v is not null then
    raise exception 'FK ที่ชี้มาที่ fx_rates ยอมให้ลบแถวที่ถูกใช้ (cascade/set null): % — การลบอัตราที่ถูกใช้ทำให้บรรทัดรายการชี้อัตราที่ไม่มีอยู่', v;
  end if;

  select count(*) into n
    from pg_constraint fk join pg_class t on t.oid = fk.confrelid
   where fk.contype = 'f' and t.relname = 'fx_rates';
  raise notice 'ok · อัตราที่ถูกใช้แล้วแก้ย้อนหลังไม่ได้ (note ยังแก้ได้) · % FK ชี้มาที่ fx_rates และถูกนับครบ · DELETE ถูกกันด้วย FK', n;
end $$;
