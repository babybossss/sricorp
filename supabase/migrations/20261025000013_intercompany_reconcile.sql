-- ============================================================
-- SRI OS · **การกระทบยอดรายการระหว่างกัน** — ของที่ต้องแลกมากับการยอมให้
--            ยอดยกมาของ `1310`/`2310` ลงข้างเดียวได้
--
-- ------------------------------------------------------------
-- **ที่มา**
--
-- ไฟล์ยอดตั้งต้นของลูกพี่มีรหัส `1310` (ลูกหนี้ระหว่างกัน) และ `2310`
-- (เจ้าหนี้ระหว่างกัน) แน่นอน เพราะกองกลาง SRI โยกเงินกันระหว่างผู้ถือ
-- ก่อนไฟล์นี้ **ไม่มีหมวด `opn.*` ของสองรหัสนั้น** → หน้าจอปฏิเสธไฟล์ทั้งไฟล์
-- (ซึ่งถูก — ดีกว่าข้ามบรรทัดเงียบๆ) แต่แปลว่านำเข้าไม่ได้เลย
--
-- **ข้อจำกัดที่ยอมรับโดยตั้งใจ**: ยอดยกมา **ลงทีละผู้ถือ** (ไฟล์เป็นบัญชีคุม
-- ต่อผู้ถือ) จึงบังคับให้มาครบคู่ข้ามผู้ถือในใบเดียวไม่ได้
-- ด่าน `fn_assert_intercompany_pair` (20261008000011) ทำงานเฉพาะใบที่
-- `is_intercompany = true` ซึ่งยอดยกมาไม่ใช่ → ลงข้างเดียวผ่าน **โดยตั้งใจ**
--
-- ถ้าบังคับให้ครบคู่: ต้องให้ผู้ใช้นำเข้าสองผู้ถือในคำสั่งเดียวตลอด ซึ่งขัดกับ
-- รูปของไฟล์ (ทีละผู้ถือ) และจะทำให้ **นำเข้าผู้ถือแรกไม่ได้เลย** = ด่านที่ห้าม
-- สิ่งที่ต้องทำ · ทางที่เลือกคือ **ยอมให้ลงข้างเดียว แล้วตรวจที่ผลลัพธ์**
-- (D-116: ต้องมีด่านที่ตรวจผลลัพธ์ปลายทาง ไม่ใช่ตรวจแต่ขั้นตอน)
--
-- ------------------------------------------------------------
-- **สมการที่ต้องจริงเสมอหลังนำเข้าครบ**
--
--     Σ (1310 ของทุกผู้ถือ)  =  Σ (2310 ของทุกผู้ถือ)
--
-- เพราะลูกหนี้ระหว่างกันของผู้ถือหนึ่ง **คือ** เจ้าหนี้ระหว่างกันของอีกผู้ถือ
-- ถ้าไม่เท่ากัน งบรวมตัดรายการระหว่างกันไม่ลง → **Money Invariant 6 พัง**
-- ("Consolidated ตัด intercompany แล้ว เงินสดรวม = ผลรวมยอดธนาคารทุกบัญชี")
-- และไม่มีอะไรฟ้องเลย เพราะงบดุลของ **แต่ละผู้ถือ** ยังดุลทั้งคู่
--
-- **ทำไมไม่ทำเป็น trigger**: ระหว่างนำเข้าผู้ถือที่ 1 ของ N สมการนี้
-- **ไม่จริงโดยถูกต้อง** · trigger จะปฏิเสธขั้นตอนที่จำเป็น (รูปเดียวกับ
-- `fn_asset_surplus_mismatch` ที่เป็นการกระทบยอด ไม่ใช่ด่านรายใบ)
-- → เป็นฟังก์ชันที่ **เรียกดูได้ตลอดเวลา** และต้องว่างเปล่าก่อนปิดการนำเข้า
--
-- **ข้อจำกัดที่เหลืออยู่และต้องรู้**: ยอดยกมาไม่ได้บันทึก *คู่สัญญา* ของยอด
-- ระหว่างกัน (ไฟล์เป็นบัญชีคุม ไม่ได้แยกรายคู่) → ตรวจได้แค่ **ยอดรวมทั้งกอง**
-- ไม่ใช่รายคู่ผู้ถือ · ถ้า A บันทึกว่าลูกหนี้ B 100 แต่ B บันทึกว่าเจ้าหนี้ C 100
-- ยอดรวมยังตรงและรายงานนี้เงียบ · การตรวจรายคู่ทำได้เมื่อไฟล์ส่งคู่สัญญามา
-- (ต้องเพิ่มคอลัมน์ที่ **ประตูตั้งให้** ไม่ใช่ข้อความที่ผู้เรียกตั้ง · D-115)
-- **ยังไม่ทำในรอบนี้** และยอมรับได้เพราะยอดรวมในงบรวมยังถูก
--
-- ------------------------------------------------------------
-- ลำดับ: ต้องรันหลัง 20261008000010 (รหัส 1310/2310) และหลัง
--        20261020000001 (วิว `v_ledger_posted`) · guard หัวไฟล์ตรวจให้
--
-- idempotent: `create or replace` ตัวเดียว
--
-- ย้อนกลับ (rollback):
--   -- drop function if exists sri_os.fn_intercompany_mismatch();
--   ⚠ ถอดแล้ว **ไม่มีอะไรบอกได้ว่ารายการระหว่างกันสองฝั่งตรงกันหรือไม่**
--     และยอดยกมาข้างเดียวยังลงได้อยู่ → งบรวมเพี้ยนเงียบๆ
-- ============================================================

set search_path = sri_os, public;

do $$
declare c text;
begin
  if to_regclass('sri_os.v_ledger_posted') is null then
    raise exception 'ไม่มีวิว v_ledger_posted → ต้องรัน 20261020000001_void_columns_and_views.sql ก่อนไฟล์นี้';
  end if;
  foreach c in array array['1310', '2310'] loop
    if not exists (select 1 from sri_os.chart_of_accounts where code = c) then
      raise exception 'ไม่มีรหัส % ในผังบัญชี → ต้องรัน 20261008000010_coa_intercompany.sql ก่อนไฟล์นี้', c;
    end if;
  end loop;
end $$;

-- ============================================================
-- 1 · การกระทบยอดรายการระหว่างกัน — **ต้องว่างเปล่าเมื่อนำเข้าครบ**
--
-- อ่านผ่าน `v_ledger_posted` (D-098) ไม่ใช่ตารางฐาน → ใบที่ยกเลิกแล้วไม่ถูกนับ
-- ============================================================
create or replace function fn_intercompany_mismatch()
returns table (receivable_total numeric, payable_total numeric, diff numeric, detail text)
language sql stable security definer set search_path = '' as $fn$
  with t as (
    select
      coalesce(sum(case when c.code = '1310' then v.debit - v.credit else 0 end), 0) as recv,
      coalesce(sum(case when c.code = '2310' then v.credit - v.debit else 0 end), 0) as pay
      from sri_os.v_ledger_posted v
      join sri_os.chart_of_accounts c on c.id = v.coa_id
     where c.code in ('1310', '2310')
  )
  select round(t.recv, 2), round(t.pay, 2), round(t.recv - t.pay, 2),
         'ลูกหนี้ระหว่างกันรวม ' || round(t.recv, 2)::text
           || ' ไม่เท่ากับเจ้าหนี้ระหว่างกันรวม ' || round(t.pay, 2)::text
           || ' (ต่าง ' || round(t.recv - t.pay, 2)::text
           || ') — งบรวมจะตัดรายการระหว่างกันไม่ลง ทั้งที่งบดุลของแต่ละผู้ถือยังดุล'
    from t
   where abs(round(t.recv - t.pay, 2)) > 0.01;
$fn$;

comment on function fn_intercompany_mismatch() is
  'การกระทบยอดรายการระหว่างกัน · Σ 1310 ของทุกผู้ถือต้องเท่ากับ Σ 2310 ของทุกผู้ถือ ไม่งั้นงบรวมตัดกันไม่ลง (Money Invariant 6) · **ต้องว่างเปล่าก่อนปิดการนำเข้ายอดตั้งต้น** · ไม่ทำเป็น trigger เพราะระหว่างนำเข้าผู้ถือที่ 1 ของ N สมการนี้ไม่จริงโดยถูกต้อง · ตรวจได้แค่ยอดรวมทั้งกอง ไม่ใช่รายคู่ผู้ถือ เพราะไฟล์ยอดตั้งต้นเป็นบัญชีคุมที่ไม่ได้ส่งคู่สัญญามา';

revoke all on function fn_intercompany_mismatch() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_intercompany_mismatch() from anon';
  -- definer ที่อ่านสมุด → เปิดให้ authenticated ไม่ได้ (D-089 row_escape)
  -- รายงานนี้เป็นงานตรวจของผู้ดูแล รันด้วย service role
  execute 'revoke all on function sri_os.fn_intercompany_mismatch() from authenticated';
end $$;

-- ============================================================
-- 2 · guard ท้ายไฟล์
-- ============================================================
do $$
declare v text;
begin
  if to_regprocedure('sri_os.fn_intercompany_mismatch()') is null then
    raise exception 'ฟังก์ชันกระทบยอดรายการระหว่างกันไม่ถูกสร้าง';
  end if;

  -- ต้องไม่เปิดให้ผู้ใช้แอป (definer ที่อ่าน v_ledger_posted)
  if has_function_privilege('anon', 'sri_os.fn_intercompany_mismatch()'::regprocedure, 'execute')
     or has_function_privilege('public', 'sri_os.fn_intercompany_mismatch()'::regprocedure, 'execute')
     or has_function_privilege('authenticated', 'sri_os.fn_intercompany_mismatch()'::regprocedure, 'execute') then
    raise exception 'fn_intercompany_mismatch เปิดให้ผู้ใช้แอปเรียก = ทางข้าม policy ของสมุด (D-089)';
  end if;

  -- หมวดยอดยกมาของทั้งสองฝั่งต้องมีในตารางกฎ ไม่งั้นรายงานนี้ไม่มีความหมาย
  -- (มีแต่ฝั่งลูกหนี้ = ผู้ถืออีกฝ่ายลงเจ้าหนี้ไม่ได้เลย → ตัดกันไม่ลงถาวร)
  select string_agg(x.code, ', ') into v
    from (values ('1310'), ('2310')) x(code)
   where not exists (select 1 from sri_os.txn_types t
                      where t.group_code = 'opening'
                        and x.code in (t.dr_coa_code, t.cr_coa_code));
  if v is not null then
    raise exception 'ยังไม่มีหมวดยอดยกมาของบัญชีระหว่างกัน: % — sync ด้วย npm run sync:rules ก่อน (ไม่งั้นนำเข้าไฟล์จริงของลูกพี่ไม่ได้)', v;
  end if;

  raise notice 'ok · การกระทบยอดรายการระหว่างกันพร้อม (ต้องว่างเปล่าก่อนปิดการนำเข้า) · หมวดยอดยกมาของ 1310/2310 มีครบทั้งสองฝั่ง';
end $$;
