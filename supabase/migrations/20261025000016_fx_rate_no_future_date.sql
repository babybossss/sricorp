-- ============================================================
-- SRI OS · **ห้ามบันทึกอัตราแลกเปลี่ยนของวันที่ยังไม่มาถึง**
--
-- ------------------------------------------------------------
-- **เหตุผล** — อัตราของวันที่ยังไม่มาถึง **คือการเดา**
--
-- หน้าจอกันแล้ว แต่ DB ไม่กัน → คำขอที่ข้ามหน้าจอผ่านหมด (คลาส D-115
-- เดียวกับการแก้อัตราย้อนหลังที่ `20261025000015` ปิดไป)
--
-- ผลถ้าปล่อย: ลงอัตราล่วงหน้าไว้ แล้วลงรายการที่อ้างอัตรานั้นได้ทันที
-- → ยอดบาทของรายการมาจากอัตราที่ **ยังไม่มีใครรู้** · และเมื่อวันนั้นมาถึงจริง
-- อัตราที่ประกาศจริงต่างออกไป ก็ **แก้ไม่ได้อีกแล้ว** เพราะ `...0015` ห้ามแก้
-- อัตราที่มีรายการอ้างถึง → ติดอยู่กับตัวเลขที่เดาไว้ตลอดไป
-- (สองด่านนี้ต้องมาคู่กัน: ห้ามแก้ย้อนหลัง **และ** ห้ามลงล่วงหน้า
--  มีข้อเดียวจะกลายเป็น "ล็อกค่าที่เดา" ซึ่งแย่กว่าไม่ล็อก)
--
-- ------------------------------------------------------------
-- **ขอบเขตที่เลือก**
--
-- - บังคับทั้ง **INSERT และ UPDATE** ของ `rate_date`
--   (ย้ายวันของแถวที่ยังไม่มีใครใช้ไปอนาคตก็ไม่ได้)
-- - เทียบกับ `current_date` ตรงๆ · **วันนี้ลงได้** (อัตราของวันนี้ประกาศแล้ว)
-- - ไม่แตะแถวที่มีอยู่แล้ว (ไม่ย้อนไปลบ/แก้ของเก่า) — ถ้าฐานข้อมูลจริงมีแถว
--   ที่ลงล่วงหน้าไว้ ด่านนี้จะไม่ปฏิเสธมันจนกว่าจะมีคนไปแก้แถวนั้น
--   `fn_fx_rate_future_rows()` มีไว้ให้ไล่ดูว่ามีค้างอยู่กี่แถว
--
-- ------------------------------------------------------------
-- **สิ่งที่ต้องทำคู่กัน (ทำแล้วในคอมมิตเดียวกัน)**
--
-- fixture ของ `zz_wht_and_fx_test.sql` และ `zz_fcd_currency_test.sql`
-- เคยใช้อัตราสิ้นเดือน `2026-10-31` · `2026-11-30` · `2026-12-31` ซึ่ง
-- **อยู่ในอนาคตเทียบกับวันที่ของเครื่องตอนสร้างไฟล์นี้ (2026-10-25)**
-- → ย้าย timeline ของทั้งสองไฟล์ไปเป็น เม.ย. → พ.ค. → มิ.ย. 2569
-- (สิ้นเดือนเหมือนเดิม · ลำดับและช่องว่างหนึ่งเดือนครบ · ตัวเลขไม่เปลี่ยน)
--
-- **ทำไมต้องย้ายก่อน ไม่ใช่ปล่อยให้แดงแล้วค่อยว่ากัน**: ถ้าปล่อยไว้ สองไฟล์นั้น
-- จะแดงวันนี้แล้ว **กลับมาเขียวเองเมื่อเวลาผ่านไป** โดยไม่มีใครแก้อะไร —
-- เทสต์ที่หยุดทดสอบไปเฉยๆ โดยไม่มีสัญญาณ ซึ่งแย่กว่าไม่มีด่าน เพราะยังดูเหมือนมี
--
-- **ไล่ทั้ง `supabase/tests/` แล้ว** — ที่เหลือที่ผูกกับปฏิทินใช้ **วันแบบสัมพัทธ์**
-- อยู่แล้ว (`current_date + 5` · `current_date - 10` · "ราคาอายุ 3 วัน" ของ
-- `is_stale`) ซึ่งเสถียรเพราะยึดกับนาฬิกา ไม่ใช่กับค่าคงที่ · ส่วนวันเอกสาร
-- (`doc_date`/`cash_date`) ที่เป็นอนาคตในไฟล์อื่นยัง **ไม่มีด่านไหนอ้างอิง
-- `current_date`** จึงไม่เปลี่ยนผลตามปฏิทินวันนี้ — แจ้งไว้เป็นข้อสังเกต
-- ถ้าวันหนึ่งจะเพิ่มด่าน "ห้ามวันเอกสารอนาคต" ต้องย้าย fixture ชุดนั้นก่อนเหมือนกัน
--
-- ------------------------------------------------------------
-- ลำดับ: ต้องรันหลัง 20261024000001 (ตาราง `fx_rates`) · guard หัวไฟล์ตรวจให้
--        ไม่ขึ้นกับ `...0015` แต่ **ควรอยู่คู่กัน** (ดูเหตุผลข้างบน)
--
-- idempotent: `create or replace` · `drop trigger if exists` ก่อน create
--
-- ย้อนกลับ (rollback):
--   -- drop trigger if exists trg_fx_rates_no_future_date on sri_os.fx_rates;
--   -- drop function if exists sri_os.fn_assert_fx_rate_not_future();
--   -- drop function if exists sri_os.fn_fx_rate_future_rows();
--   ⚠ ถอดแล้ว **ลงอัตราล่วงหน้าได้อีก** และเมื่อรวมกับ `...0015` จะกลายเป็น
--     การล็อกตัวเลขที่เดาไว้ถาวร
-- ============================================================

set search_path = sri_os, public;

do $$
begin
  if to_regclass('sri_os.fx_rates') is null then
    raise exception 'ไม่มีตาราง fx_rates → ต้องรัน 20261024000001_wht_and_fx.sql ก่อนไฟล์นี้';
  end if;
end $$;

-- ============================================================
-- 1 · ด่าน — INSERT/UPDATE อัตราของวันที่ยังไม่มาถึง = ปฏิเสธ
-- ============================================================
create or replace function fn_assert_fx_rate_not_future() returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  /**
   * `current_date` ของเซิร์ฟเวอร์ — **ไม่รับวันที่อ้างอิงจากผู้เรียก** (D-115)
   * ถ้าให้ผู้เรียกส่ง "วันนี้" มาเทียบ ด่านนี้จะปลดได้ด้วยการโกหกเรื่องวันที่
   */
  if new.rate_date > current_date then
    raise exception 'อัตรา % ของวันที่ % ยังไม่มาถึง (วันนี้คือ %) — อัตราของวันที่ยังไม่มาถึงคือการเดา · ถ้าลงไว้แล้วมีรายการอ้างถึง จะแก้ย้อนหลังไม่ได้อีก (ด่านของ 20261025000015) แปลว่ายอดบาทของรายการนั้นติดอยู่กับตัวเลขที่เดาไว้ตลอดไป · ให้รอให้ถึงวันนั้นแล้วบันทึกอัตราที่ประกาศจริง',
      new.currency, new.rate_date, current_date;
  end if;
  return new;
end $fn$;

comment on function fn_assert_fx_rate_not_future() is
  'ห้ามบันทึก/ย้ายอัตราแลกเปลี่ยนไปวันที่ยังไม่มาถึง · เทียบกับ current_date ของเซิร์ฟเวอร์ ไม่ใช่วันที่ผู้เรียกส่งมา (D-115) · วันนี้ลงได้ · คู่กับ 20261025000015 (ห้ามแก้อัตราที่มีรายการอ้างถึง) — ต้องมีทั้งสองข้อ ไม่งั้นกลายเป็นการล็อกตัวเลขที่เดาไว้ถาวร';

revoke all on function fn_assert_fx_rate_not_future() from public;
do $$ begin execute 'revoke all on function sri_os.fn_assert_fx_rate_not_future() from anon, authenticated'; end $$;

drop trigger if exists trg_fx_rates_no_future_date on fx_rates;
create trigger trg_fx_rates_no_future_date
  before insert or update of rate_date on fx_rates
  for each row execute function fn_assert_fx_rate_not_future();

-- ============================================================
-- 2 · รายงาน — แถวที่ลงล่วงหน้าไว้ก่อนมีด่านนี้ (ถ้ามี)
--     ไม่ลบ/ไม่แก้ให้โดยอัตโนมัติ: อัตราที่มีรายการอ้างถึงแล้ว การแก้ย้อนหลัง
--     คือสิ่งที่ `...0015` ห้าม · ต้องให้คนตัดสินทีละแถว
-- ============================================================
create or replace function fn_fx_rate_future_rows()
returns table (currency text, rate_date date, thb_per_unit numeric, in_use boolean)
language sql stable security definer set search_path = '' as $fn$
  select f.currency, f.rate_date, f.thb_per_unit,
         sri_os.fn_fx_rate_in_use(f.currency, f.rate_date)
    from sri_os.fx_rates f
   where f.rate_date > current_date
   order by f.rate_date, f.currency;
$fn$;

comment on function fn_fx_rate_future_rows() is
  'อัตราที่ลงไว้ล่วงหน้า (วันที่ยังไม่มาถึง) ซึ่งค้างอยู่ก่อนมีด่านของไฟล์นี้ · ต้องว่างเปล่า · คอลัมน์ in_use บอกว่ามีรายการอ้างถึงแล้วหรือยัง เพราะแถวที่ถูกใช้แล้วแก้ย้อนหลังไม่ได้ (20261025000015) ต้องตัดสินทีละแถว ไม่ลบอัตโนมัติ';

revoke all on function fn_fx_rate_future_rows() from public;
do $$ begin execute 'revoke all on function sri_os.fn_fx_rate_future_rows() from anon, authenticated'; end $$;

-- ============================================================
-- 3 · guard ท้ายไฟล์
-- ============================================================
do $$
declare v text; n int;
begin
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.fx_rates'::regclass
                    and g.tgname = 'trg_fx_rates_no_future_date'
                    and not g.tgisinternal) then
    raise exception 'trigger trg_fx_rates_no_future_date ไม่ถูกสร้าง';
  end if;

  -- ต้องเป็น before (after จะสายไปแล้ว) และต้องครอบทั้ง insert และ update
  select string_agg(g.tgname, ', ') into v
    from pg_trigger g
   where g.tgrelid = 'sri_os.fx_rates'::regclass
     and g.tgname = 'trg_fx_rates_no_future_date'
     and (g.tgtype & 2) = 0;   -- bit 1 = BEFORE
  if v is not null then
    raise exception 'trigger % ต้องเป็น BEFORE', v;
  end if;

  -- ฟังก์ชันต้องไม่เปิดให้ผู้ใช้แอป
  select string_agg(p.proname, ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.proname in ('fn_assert_fx_rate_not_future', 'fn_fx_rate_future_rows')
     and (has_function_privilege('anon', p.oid, 'execute')
          or has_function_privilege('public', p.oid, 'execute')
          or has_function_privilege('authenticated', p.oid, 'execute'));
  if v is not null then
    raise exception 'ฟังก์ชันของไฟล์นี้เปิดให้ผู้ใช้แอปเรียก: %', v;
  end if;

  -- ด่านคู่ของมันต้องมีอยู่ (มีข้อเดียว = ล็อกตัวเลขที่เดา หรือ ปล่อยแก้ย้อนหลัง)
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.fx_rates'::regclass
                    and g.tgname = 'trg_fx_rates_immutable_when_used'
                    and not g.tgisinternal) then
    raise exception 'ไม่มีด่าน trg_fx_rates_immutable_when_used (20261025000015) — ห้ามลงล่วงหน้าโดยไม่ห้ามแก้ย้อนหลังด้วย จะกลายเป็นว่าอัตราที่เดาไว้แก้ได้ แต่อัตราที่ประกาศจริงแก้ไม่ได้';
  end if;

  -- แถวที่ลงล่วงหน้าไว้ก่อนหน้านี้ (ถ้ามี) ต้องรู้ ไม่ใช่เงียบ
  select count(*) into n from sri_os.fn_fx_rate_future_rows();
  if n > 0 then
    select string_agg(r.currency || ' ' || r.rate_date::text
                      || case when r.in_use then ' (มีรายการอ้างถึงแล้ว)' else '' end, ', ')
      into v from sri_os.fn_fx_rate_future_rows() r;
    raise warning 'มีอัตราที่ลงล่วงหน้าค้างอยู่ % แถว: % — ด่านใหม่ไม่ลบให้ เพราะแถวที่ถูกใช้แล้วแก้ย้อนหลังไม่ได้ ต้องตัดสินทีละแถว (select * from sri_os.fn_fx_rate_future_rows())',
      n, v;
  end if;

  raise notice 'ok · ห้ามบันทึกอัตราของวันที่ยังไม่มาถึง (INSERT + ย้าย rate_date) · อัตราล่วงหน้าที่ค้างอยู่: % แถว', n;
end $$;
