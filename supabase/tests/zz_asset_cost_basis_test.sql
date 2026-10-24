-- ============================================================
-- SRI OS · เทสต์ "ต้นทุนถัวเฉลี่ย + ล้างส่วนเกินทุนตามสัดส่วน" (D-112 ข้อ 1)
--   migration ที่คุม: 20261025000002_asset_cost_basis_average.sql
--
-- ที่มาของไฟล์นี้ — ผู้ตรวจวัดได้บน PG16 ว่า `fn_asset_cost_basis()` คืน **กำไรปลอม**:
--   ซื้อหุ้น 10 หน่วย 1,000,000 → ตีราคาขึ้น 460,000 → ขาย 3 หน่วย
--   ต้นทุนคงเหลือคืน **240,000** (ที่ถูกคือ 700,000) → ส่วนที่เหลือจะโชว์ "กำไร"
--   งอกมา 460,000 ที่ไม่มีอยู่จริง เพราะฟังก์ชันกันแต่บรรทัดของ **ใบตีราคา**
--   ไม่ได้กันขา 1700 ที่คู่กับบรรทัดล้าง 3400 **ของใบขาย**
--
-- D-112 เปลี่ยนวิธีคิดทั้งก้อน:
--   - หุ้นตัวเดียวกันเก็บเป็นล็อตเพื่อตรวจสอบ **แต่คิดต้นทุนแบบถัวเฉลี่ย**
--   - ขายบางส่วน → ล้าง 3400 **ตามสัดส่วน** (ขาย 3 ใน 10 = 30%)
--   - กำไรที่ยังไม่ขายโชว์ได้ แต่ห้ามเข้า P&L เด็ดขาด (D-111)
--
-- **จำนวนหน่วยระดับรายการยังไม่มีในฐานข้อมูล** (ไม่มีตารางล็อต · มีแต่
--   `assets.units` ที่แก้มือได้และไม่ผูกกับใบ จึงใช้บังคับสัดส่วนไม่ได้)
--   → สัดส่วนฝั่ง DB วัดด้วย **เงิน**: ต้นทุนที่ตัดออก ÷ ต้นทุนก่อนขาย
--   ซึ่งเท่ากับสัดส่วนจำนวนหน่วยพอดีเมื่อคิดต้นทุนแบบถัวเฉลี่ย (ต้นทุนต่อหน่วยเท่ากันทุกหน่วย)
--   ฝั่งจำนวนหน่วย/ล็อตมีเทสต์ของตัวเองที่ src/lib/ledger/__tests__/average-cost.test.ts
--
-- ทุกใบในไฟล์นี้ลงผ่าน **sri_os.fn_post_entry() เท่านั้น** ไม่มี insert เข้า
--   transactions/transaction_lines ตรงๆ แม้แถวเดียว — เทสต์ที่ไม่เดินเส้นทางจริง
--   ไม่ได้พิสูจน์ว่าผู้ใช้ลงรายการนี้ได้จริง
--
-- ไล่ตาม "ถ้าถอดการแก้ออกแล้วต้องแดง":
--   C1 ซื้อสองล็อตคนละราคา → ต้นทุนรวมถูก (ฐานของค่าเฉลี่ย)
--   C2 ตีราคาขึ้น → ต้นทุนไม่ขยับ · ส่วนเกินทุนค้าง 460,000
--   C4 ขายบางส่วนแล้วล้าง 3400 **ทั้งก้อน** (พฤติกรรมของโค้ดวันนี้) → ปฏิเสธ
--   C5 ขายบางส่วนแล้ว **ไม่ล้าง** 3400 → ปฏิเสธ
--   C3 ขายบางส่วนถูกต้อง → ต้นทุนคงเหลือ 700,000 · 3400 เหลือ 322,000 · กำไรจากค่าเฉลี่ย
--   C8 **MUTATION** · คืนนิยามเดิมของ fn_asset_cost_basis → ต้องได้ 240,000 (ต่างกัน 460,000)
--   C7 ตีราคาอีกเดือน (กลับของเดือนก่อน + ลงยอดสะสมใหม่) → ยอดยังถูก
--   C9 ตัดทรัพย์เกินต้นทุนที่ถืออยู่ → ปฏิเสธ
--   C6 ขายส่วนที่เหลือทั้งหมด → ต้นทุน 0 · 3400 **ศูนย์พอดี** · ไม่มีทรัพย์ผีค้าง
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ **rollback** ปิดท้าย ไม่ทิ้งรายการเงินไว้
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
create temporary table t_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_uid(label) values ('mgmt');
insert into auth.users(id) select id from t_uid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, 'cost-basis@local', 'mgmt', 'management', true from t_uid u;

create or replace function pg_temp.login(p_label text) returns void
language sql as $fn$
  select set_config('test.uid', coalesce((select id::text from t_uid where label = p_label), ''), true);
$fn$;

insert into sri_os.user_owner_access(user_id, owner_id)
select (select id from t_uid where label = 'mgmt'), o.id from sri_os.owners o;

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
values ('00000000-0000-0000-0000-00000003b001',
        (select id from sri_os.owners where code = 'THANAKORN'),
        'BBL', 'ธนากร', 'ธนากร - BBL (ต้นทุนถัวเฉลี่ย)');

-- หุ้นสองตัว: ตัวที่ใช้ทดสอบ และตัวควบคุมที่ต้องไม่ถูกกระทบ (กันฟังก์ชันนับข้ามทรัพย์)
insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, currency)
select x.id, x.code, x.name, cat.class_id, cat.id,
       (select id from sri_os.owners where code = 'THANAKORN'), 'THB'
  from (values
    ('00000000-0000-0000-0000-00000003a001'::uuid, 'ACB-STOCK', 'หุ้น ก (ทดสอบ)'),
    ('00000000-0000-0000-0000-00000003a002'::uuid, 'ACB-OTHER', 'หุ้น ข (ตัวควบคุม)')
  ) as x(id, code, name)
  cross join (select id, class_id from sri_os.asset_categories order by id limit 1) cat;

do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.t_uid to authenticated', s);
end $$;

/**
 * ตัวช่วยประกอบ payload — **ที่เดียวที่รู้รูปของ payload**
 * ทุกเคสเรียกผ่าน pg_temp.post() จึงเดินเส้นทาง fn_post_entry เสมอ
 */
create or replace function pg_temp.owner() returns uuid
language sql stable as $fn$ select id from sri_os.owners where code = 'THANAKORN' $fn$;

create or replace function pg_temp.ln(p_code text, p_dr numeric, p_cr numeric,
                                     p_asset uuid default null, p_cf text default null,
                                     p_bank uuid default null) returns jsonb
language sql immutable as $fn$
  select jsonb_strip_nulls(jsonb_build_object(
    'coa_code', p_code, 'debit', p_dr, 'credit', p_cr,
    'asset_id', p_asset, 'cf_category', p_cf, 'bank_account_id', p_bank));
$fn$;

create or replace function pg_temp.entry(p_type text, p_doc date, p_cash date,
                                        p_memo text, p_asset uuid, p_lines jsonb)
returns jsonb language sql stable as $fn$
  select jsonb_strip_nulls(jsonb_build_object(
    'txn_type_code', p_type,
    'doc_date', p_doc::text,
    'cash_date', case when p_cash is null then null else p_cash::text end,
    'memo', p_memo,
    'asset_id', p_asset,
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', pg_temp.owner(), 'lines', p_lines))));
$fn$;

create or replace function pg_temp.post(p_payload jsonb) returns uuid
language plpgsql as $fn$
declare v jsonb;
begin
  v := sri_os.fn_post_entry(p_payload);
  if (v ->> 'replayed')::boolean then
    raise exception 'FAIL: fn_post_entry ถือว่าใบนี้เป็นการกดซ้ำ (memo ของแต่ละใบต้องไม่ซ้ำกัน)';
  end if;
  return ((v -> 'transaction_ids') ->> 0)::uuid;
end $fn$;

create or replace function pg_temp.must_fail_like(p_label text, p_sql text, p_needle text) returns void
language plpgsql as $fn$
declare v text;
begin
  begin
    execute p_sql;
  exception when others then
    v := sqlerrm;
    if v like 'FAIL:%' then raise; end if;
    if position(p_needle in v) = 0 then
      raise exception 'FAIL: % — ปฏิเสธถูกแต่ข้อความไม่มี "%" · ได้: %', p_label, p_needle, v;
    end if;
    return;
  end;
  raise exception 'FAIL: % — คำสั่งควรถูกปฏิเสธแต่สำเร็จ', p_label;
end $fn$;

-- ยอดบัญชีทรัพย์ (1700) ของทรัพย์ชิ้นหนึ่งตามสมุดที่ post แล้ว — ใช้ตรวจว่า
-- "ยอดในบัญชีทรัพย์ = ต้นทุนคงเหลือ + ส่วนเกินทุนคงเหลือ" เสมอ
create or replace function pg_temp.book(p_asset uuid) returns numeric
language sql stable as $fn$
  select coalesce(sum(l.debit - l.credit), 0)
    from sri_os.transaction_lines l
    join sri_os.transactions t on t.id = l.transaction_id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where l.asset_id = p_asset and t.status = 'posted' and c.code = '1700';
$fn$;

-- ============================================================
-- C0 · โครงสร้าง — ไล่จาก catalog จริง ไม่ใช่ไล่ไฟล์
-- ============================================================
do $$
begin
  if to_regprocedure('sri_os.fn_asset_cost_basis(uuid)') is null then
    raise exception 'FAIL: ไม่มี fn_asset_cost_basis(uuid)';
  end if;
  if to_regprocedure('sri_os.fn_asset_revaluation_surplus(uuid)') is null then
    raise exception 'FAIL: ไม่มี fn_asset_revaluation_surplus(uuid) — ส่วนเกินทุนที่ค้างต้องอ่านได้จากสมุด ไม่ใช่จาก state ของหน้าจอ';
  end if;
  if to_regprocedure('sri_os.fn_asset_ledger_parts(uuid,uuid)') is null then
    raise exception 'FAIL: ไม่มี fn_asset_ledger_parts(uuid,uuid) — ต้นทุนกับส่วนเกินทุนต้องคิดจากนิพจน์ชุดเดียว ไม่ใช่สองสำเนา';
  end if;

  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.transaction_lines'::regclass
                    and g.tgname = 'trg_assert_asset_cost_sane'
                    and not g.tgisinternal and g.tgdeferrable and g.tginitdeferred) then
    raise exception 'FAIL: ไม่มี constraint trigger trg_assert_asset_cost_sane แบบ deferrable initially deferred บน transaction_lines — ด่านที่ต้องอ่านทุกบรรทัดของใบ ยิงตอนใส่บรรทัดแรกไม่ได้';
  end if;

  /**
   * **ปากทางที่แอปเรียกจริงต้องเป็นรุ่นที่แก้แล้ว**
   *
   * เคสที่ข้อนี้กัน: ไฟล์ 20261024000001_wht_and_fx.sql ก็ `create or replace`
   * `fn_asset_cost_basis` เหมือนกัน → ถ้า 20261025000002 ยังไม่ได้ลงทะเบียนลำดับ
   * (supabase/migration-order.txt + UNDER_TEST ของ scripts/test-rls-local.sh)
   * มันจะรันก่อนแล้วถูกเขียนทับกลับเป็นรุ่นที่คืน 240,000 — โดยที่เทสต์ส่วนอื่น
   * ของไฟล์นี้ยังเขียวหมด เพราะมันอ่าน fn_asset_ledger_parts ซึ่งไม่ถูกทับ
   * = กำไรปลอมกลับมาเงียบๆ ทั้งที่เทสต์ผ่าน
   */
  if pg_get_functiondef('sri_os.fn_asset_cost_basis(uuid)'::regprocedure)
     not like '%fn_asset_ledger_parts%' then
    raise exception 'FAIL: fn_asset_cost_basis ไม่ได้อ่านจาก fn_asset_ledger_parts — มีไฟล์อื่นเขียนทับหลัง 20261025000002_asset_cost_basis_average.sql (ลำดับยังไม่ได้ลงทะเบียนใน supabase/migration-order.txt และ UNDER_TEST ของ scripts/test-rls-local.sh) → ต้นทุนคงเหลือต่ำกว่าจริงเท่าส่วนที่ตีราคาไว้ และกำไรปลอมกลับมาทั้งก้อน';
  end if;

  if has_function_privilege('anon', 'sri_os.fn_asset_cost_basis(uuid)', 'execute') then
    raise exception 'FAIL: anon เรียก fn_asset_cost_basis ได้';
  end if;
  if has_function_privilege('anon', 'sri_os.fn_asset_ledger_parts(uuid,uuid)', 'execute') then
    raise exception 'FAIL: anon เรียก fn_asset_ledger_parts ได้';
  end if;

  raise notice 'ok C0 · ฟังก์ชันต้นทุน/ส่วนเกินทุนครบ · ด่านต้นทุนผูกกับตารางจริง · anon เรียกไม่ได้';
end $$;

set local role authenticated;
select pg_temp.login('mgmt');

-- ============================================================
-- C1 · ซื้อสองล็อตคนละราคา → ต้นทุนรวม 1,000,000 · 10 หน่วย
--      ล็อต 1: 6 หน่วย × 90,000 = 540,000
--      ล็อต 2: 4 หน่วย × 115,000 = 460,000
--      → ถัวเฉลี่ย 100,000/หน่วย พอดี (ไม่ใช่ราคาของล็อตใดล็อตหนึ่ง)
-- ============================================================
do $$
declare v_cost numeric; v_surplus numeric;
begin
  perform pg_temp.post(pg_temp.entry('inv.buy_securities', '2026-10-01', '2026-10-01',
    'ซื้อหุ้น ก ล็อต 1 · 6 หน่วย × 90,000', '00000000-0000-0000-0000-00000003a001',
    jsonb_build_array(
      pg_temp.ln('1700', 540000, 0, '00000000-0000-0000-0000-00000003a001', 'investing'),
      pg_temp.ln('1100', 0, 540000, null, 'investing', '00000000-0000-0000-0000-00000003b001'))));

  perform pg_temp.post(pg_temp.entry('inv.buy_securities', '2026-10-05', '2026-10-05',
    'ซื้อหุ้น ก ล็อต 2 · 4 หน่วย × 115,000', '00000000-0000-0000-0000-00000003a001',
    jsonb_build_array(
      pg_temp.ln('1700', 460000, 0, '00000000-0000-0000-0000-00000003a001', 'investing'),
      pg_temp.ln('1100', 0, 460000, null, 'investing', '00000000-0000-0000-0000-00000003b001'))));

  select cost_basis, surplus into v_cost, v_surplus
    from sri_os.fn_asset_ledger_parts('00000000-0000-0000-0000-00000003a001');
  if v_cost <> 1000000 then
    raise exception 'FAIL: C1 — ต้นทุนรวมสองล็อตควรเป็น 1,000,000 แต่ได้ %', v_cost;
  end if;
  if v_surplus <> 0 then
    raise exception 'FAIL: C1 — ยังไม่เคยตีราคา ส่วนเกินทุนต้องเป็น 0 แต่ได้ %', v_surplus;
  end if;
  if sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000003a002') <> 0 then
    raise exception 'FAIL: C1 — ต้นทุนของทรัพย์ตัวควบคุมไม่เป็นศูนย์ = ฟังก์ชันนับข้ามทรัพย์';
  end if;

  raise notice 'ok C1 · ซื้อสองล็อตคนละราคา (90,000 กับ 115,000) → ต้นทุนรวม 1,000,000 · ถัวเฉลี่ย 100,000/หน่วย';
end $$;

-- ============================================================
-- C2 · ตีราคาขึ้น 460,000 → **ต้นทุนไม่ขยับ** · ส่วนเกินทุน 460,000
-- ============================================================
do $$
declare v_cost numeric; v_surplus numeric;
begin
  perform pg_temp.post(pg_temp.entry('adj.revalue_securities_up', '2026-10-31', null,
    'ตีราคาหุ้น ก ขึ้น 460,000 (ยังไม่ขาย)', '00000000-0000-0000-0000-00000003a001',
    jsonb_build_array(
      pg_temp.ln('1700', 460000, 0, '00000000-0000-0000-0000-00000003a001', 'none'),
      pg_temp.ln('3400', 0, 460000, '00000000-0000-0000-0000-00000003a001', 'none'))));

  select cost_basis, surplus into v_cost, v_surplus
    from sri_os.fn_asset_ledger_parts('00000000-0000-0000-0000-00000003a001');
  if v_cost <> 1000000 then
    raise exception 'FAIL: C2 — ตีราคาแล้วต้นทุนต้องยังเป็น 1,000,000 แต่ได้ % (ใบตีราคาถูกนับเป็นต้นทุน)', v_cost;
  end if;
  if v_surplus <> 460000 then
    raise exception 'FAIL: C2 — ส่วนเกินทุนที่ค้างควรเป็น 460,000 แต่ได้ %', v_surplus;
  end if;
  if sri_os.fn_asset_revaluation_surplus('00000000-0000-0000-0000-00000003a001') <> 460000 then
    raise exception 'FAIL: C2 — fn_asset_revaluation_surplus ตอบไม่ตรงกับ fn_asset_ledger_parts';
  end if;
  if pg_temp.book('00000000-0000-0000-0000-00000003a001') <> 1460000 then
    raise exception 'FAIL: C2 — ยอดบัญชี 1700 ควรเป็น 1,460,000 แต่ได้ %',
      pg_temp.book('00000000-0000-0000-0000-00000003a001');
  end if;
  raise notice 'ok C2 · ตีราคาขึ้นไม่เปลี่ยนต้นทุน (1,000,000) · ส่วนเกินทุนค้าง 460,000 · ยอด 1700 = 1,460,000';
end $$;

-- ============================================================
-- C4 · **เคสที่ทำให้เกิดกำไรปลอม** — ขาย 3 ใน 10 หน่วย แต่ล้าง 3400 ทั้งก้อน
--      (คือสิ่งที่ posting.ts ทำวันนี้: ล้าง unrealizedToReverse ทั้งก้อน)
-- ============================================================
do $$
begin
  perform pg_temp.must_fail_like('C4 ขายบางส่วนแต่ล้างส่วนเกินทุนทั้งก้อน',
    $q$ select pg_temp.post(pg_temp.entry('inv.sell_securities', '2026-11-05', '2026-11-05',
          'ขาย 3 หน่วย แต่ล้าง 3400 ทั้ง 460,000 (ผิด)',
          '00000000-0000-0000-0000-00000003a001',
          jsonb_build_array(
            pg_temp.ln('1100', 450000, 0, null, 'investing', '00000000-0000-0000-0000-00000003b001'),
            pg_temp.ln('1700', 0, 300000, '00000000-0000-0000-0000-00000003a001', 'investing'),
            pg_temp.ln('4900', 0, 150000, '00000000-0000-0000-0000-00000003a001'),
            pg_temp.ln('3400', 460000, 0, '00000000-0000-0000-0000-00000003a001'),
            pg_temp.ln('1700', 0, 460000, '00000000-0000-0000-0000-00000003a001', 'investing')))) $q$,
    'ตามสัดส่วน');
  raise notice 'ok C4 · ขายบางส่วนแล้วล้างส่วนเกินทุนทั้งก้อนถูกปฏิเสธ (ถ้าผ่าน = ต้นทุนคงเหลือหายไป 460,000 และกำไรงอกเท่านั้น)';
end $$;

-- ============================================================
-- C5 · ขายบางส่วนแล้ว **ไม่ล้าง** 3400 เลย → ปฏิเสธ
-- ============================================================
do $$
begin
  perform pg_temp.must_fail_like('C5 ขายบางส่วนแต่ไม่ล้างส่วนเกินทุน',
    $q$ select pg_temp.post(pg_temp.entry('inv.sell_securities', '2026-11-06', '2026-11-06',
          'ขาย 3 หน่วย ไม่ล้าง 3400 เลย (ผิด)',
          '00000000-0000-0000-0000-00000003a001',
          jsonb_build_array(
            pg_temp.ln('1100', 450000, 0, null, 'investing', '00000000-0000-0000-0000-00000003b001'),
            pg_temp.ln('1700', 0, 300000, '00000000-0000-0000-0000-00000003a001', 'investing'),
            pg_temp.ln('4900', 0, 150000, '00000000-0000-0000-0000-00000003a001')))) $q$,
    'ตามสัดส่วน');
  raise notice 'ok C5 · ขายบางส่วนแล้วไม่ล้างส่วนเกินทุนถูกปฏิเสธ (ส่วนเกินของหน่วยที่ขายไปจะค้างตลอดไป)';
end $$;

-- ============================================================
-- C3 · **เคสที่ถูกต้อง** — ขาย 3 ใน 10 หน่วย
--      ต้นทุนที่ตัด 300,000 = ถัวเฉลี่ย 100,000 × 3
--        (FIFO จะเป็น 270,000 · ล็อตล่าสุดจะเป็น 345,000 — ทั้งคู่ไม่ใช่ของ D-112)
--      กำไร 450,000 − 300,000 = 150,000 · ล้าง 3400 ตามสัดส่วน 30% = 138,000
--      → ต้นทุนคงเหลือ **700,000** (ไม่ใช่ 240,000) · 3400 เหลือ **322,000**
-- ============================================================
do $$
declare v_cost numeric; v_surplus numeric;
begin
  perform pg_temp.post(pg_temp.entry('inv.sell_securities', '2026-11-07', '2026-11-07',
    'ขายหุ้น ก 3 หน่วย · ต้นทุนถัวเฉลี่ย 300,000 · ล้างส่วนเกินทุน 30%',
    '00000000-0000-0000-0000-00000003a001',
    jsonb_build_array(
      pg_temp.ln('1100', 450000, 0, null, 'investing', '00000000-0000-0000-0000-00000003b001'),
      pg_temp.ln('1700', 0, 300000, '00000000-0000-0000-0000-00000003a001', 'investing'),
      pg_temp.ln('4900', 0, 150000, '00000000-0000-0000-0000-00000003a001'),
      pg_temp.ln('3400', 138000, 0, '00000000-0000-0000-0000-00000003a001'),
      pg_temp.ln('1700', 0, 138000, '00000000-0000-0000-0000-00000003a001', 'investing'))));

  select cost_basis, surplus into v_cost, v_surplus
    from sri_os.fn_asset_ledger_parts('00000000-0000-0000-0000-00000003a001');
  if v_cost <> 700000 then
    raise exception 'FAIL: C3 — ต้นทุนคงเหลือหลังขาย 3 ใน 10 หน่วยต้องเป็น 700,000 แต่ได้ % (ส่วนต่าง % คือกำไรปลอมที่ผู้ตรวจวัดไว้)',
      v_cost, 700000 - v_cost;
  end if;
  if v_surplus <> 322000 then
    raise exception 'FAIL: C3 — ส่วนเกินทุนที่ยังค้างต้องเป็น 322,000 (70%% ของ 460,000) แต่ได้ %', v_surplus;
  end if;
  if pg_temp.book('00000000-0000-0000-0000-00000003a001') <> v_cost + v_surplus then
    raise exception 'FAIL: C3 — ยอดบัญชี 1700 (%) ไม่เท่ากับ ต้นทุน (%) + ส่วนเกินทุน (%)',
      pg_temp.book('00000000-0000-0000-0000-00000003a001'), v_cost, v_surplus;
  end if;

  raise notice 'ok C3 · ขายบางส่วน: ต้นทุนคงเหลือ 700,000 · 3400 เหลือ 322,000 · กำไร 150,000 จากต้นทุนถัวเฉลี่ย 300,000 (ไม่ใช่ FIFO 270,000) · ยอด 1700 = 1,022,000';
end $$;

reset role;

-- ============================================================
-- C8 · **MUTATION** — ถอดการแก้ **ทั้งสองชั้น** ออก แล้ววัดฉากของผู้ตรวจซ้ำ
--
-- ของจริงวันนี้ (`posting.ts`) ล้างส่วนเกินทุน **ทั้งก้อน** ตอนขายบางส่วน
-- ซึ่งด่านข้อ 4 ของ migration ปฏิเสธไปแล้ว (C4) → การวัด "กำไรปลอม 460,000"
-- ของผู้ตรวจต้องถอดทั้งด่านและนิยามของฟังก์ชันออกก่อน ไม่ใช่ถอดอย่างเดียว
--
--   ถอด trg_assert_asset_cost_sane → ใบที่ล้าง 3400 ทั้งก้อนลงได้อีก
--   คืนนิยามเดิมของ fn_asset_cost_basis → ต้นทุนคงเหลือคืน **240,000**
--   นิยามที่แก้แล้วบนข้อมูลชุดเดียวกันคืน **700,000** · ต่างกัน **460,000** พอดี
--
-- ทำบนทรัพย์ตัวที่สองเพื่อไม่แตะฉากของ a001 (ซึ่งเทสต์ C7/C6 ใช้ต่อ)
-- ทั้งบล็อกอยู่บน savepoint → rollback แล้วทั้งด่าน ทั้งนิยาม ทั้งใบ กลับที่เดิม
-- ============================================================
savepoint before_mutation;

set local role authenticated;
select pg_temp.login('mgmt');
do $$
begin
  perform pg_temp.post(pg_temp.entry('inv.buy_securities', '2026-10-01', '2026-10-01',
    'MUT · ซื้อหุ้น ข 10 หน่วย 1,000,000', '00000000-0000-0000-0000-00000003a002',
    jsonb_build_array(
      pg_temp.ln('1700', 1000000, 0, '00000000-0000-0000-0000-00000003a002', 'investing'),
      pg_temp.ln('1100', 0, 1000000, null, 'investing', '00000000-0000-0000-0000-00000003b001'))));
  perform pg_temp.post(pg_temp.entry('adj.revalue_securities_up', '2026-10-31', null,
    'MUT · ตีราคาหุ้น ข ขึ้น 460,000', '00000000-0000-0000-0000-00000003a002',
    jsonb_build_array(
      pg_temp.ln('1700', 460000, 0, '00000000-0000-0000-0000-00000003a002', 'none'),
      pg_temp.ln('3400', 0, 460000, '00000000-0000-0000-0000-00000003a002', 'none'))));
end $$;
reset role;

-- ถอดชั้นที่ 1 · ด่านสัดส่วน
drop trigger trg_assert_asset_cost_sane on sri_os.transaction_lines;

-- ถอดชั้นที่ 2 · นิยามเดิมของต้นทุน (ยกมาจาก 20261024000001_wht_and_fx.sql ข้อ 8)
create or replace function sri_os.fn_asset_cost_basis(p_asset uuid)
returns numeric
language sql stable set search_path = '' as $fn$
  -- กันแต่ "ใบตีราคา" → ยังนับขา 1700 ที่คู่กับบรรทัดล้าง 3400 ของ **ใบขาย**
  -- เป็นการลดต้นทุนด้วย ซึ่งคือที่มาของกำไรปลอม
  select coalesce(sum(l.debit - l.credit), 0)
    from sri_os.transaction_lines l
    join sri_os.transactions t on t.id = l.transaction_id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where l.asset_id = p_asset
     and t.status = 'posted'
     and c.type = 'asset'
     and c.code !~ '^11[0-9][0-9]$'
     and not exists (
       select 1 from sri_os.txn_types ty
        where ty.code = t.txn_type_code
          and '3400' in (ty.dr_coa_code, ty.cr_coa_code)
     );
$fn$;

-- ใบขาย 3 ใน 10 หน่วย แบบที่โค้ดวันนี้ทำ: ล้างส่วนเกินทุนทั้งก้อน 460,000
set local role authenticated;
select pg_temp.login('mgmt');
do $$
begin
  perform pg_temp.post(pg_temp.entry('inv.sell_securities', '2026-11-05', '2026-11-05',
    'MUT · ขายหุ้น ข 3 หน่วย ล้าง 3400 ทั้งก้อน (พฤติกรรมของโค้ดวันนี้)',
    '00000000-0000-0000-0000-00000003a002',
    jsonb_build_array(
      pg_temp.ln('1100', 450000, 0, null, 'investing', '00000000-0000-0000-0000-00000003b001'),
      pg_temp.ln('1700', 0, 300000, '00000000-0000-0000-0000-00000003a002', 'investing'),
      pg_temp.ln('4900', 0, 150000, '00000000-0000-0000-0000-00000003a002'),
      pg_temp.ln('3400', 460000, 0, '00000000-0000-0000-0000-00000003a002'),
      pg_temp.ln('1700', 0, 460000, '00000000-0000-0000-0000-00000003a002', 'investing'))));
end $$;
reset role;

do $$
declare v_old numeric; v_true numeric; v_surplus numeric;
begin
  v_old := sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000003a002');
  select cost_basis, surplus into v_true, v_surplus
    from sri_os.fn_asset_ledger_parts('00000000-0000-0000-0000-00000003a002');

  if v_true <> 700000 then
    raise exception 'FAIL: C8 — นิยามที่แก้แล้วต้องคืน 700,000 บนฉากของผู้ตรวจ แต่ได้ %', v_true;
  end if;
  if v_old <> 240000 then
    raise exception 'FAIL: C8 — นิยามเดิมควรคืน 240,000 แต่ได้ % → เคส mutation นี้ไม่ได้พิสูจน์อะไร', v_old;
  end if;
  if v_true - v_old <> 460000 then
    raise exception 'FAIL: C8 — ส่วนต่างต้องเป็น 460,000 พอดี แต่ได้ %', v_true - v_old;
  end if;
  -- และใบที่ล้างทั้งก้อนทำให้ส่วนเกินทุนของ 7 หน่วยที่ยังถืออยู่หายไปหมด
  if v_surplus <> 0 then
    raise exception 'FAIL: C8 — ใบที่ล้างทั้งก้อนควรทำให้ส่วนเกินทุนเหลือ 0 (ทั้งที่ยังถือ 7 หน่วย) แต่ได้ %', v_surplus;
  end if;
  raise notice 'ok C8 · MUTATION · ถอดด่าน + คืนนิยามเดิม → ต้นทุนคงเหลือ 240,000 · นิยามที่แก้แล้ว 700,000 · ส่วนต่าง 460,000 คือกำไรปลอมที่ถูกปิดไปแล้ว (และ 3400 ของ 7 หน่วยที่ยังถืออยู่หายไปหมด)';
end $$;

rollback to savepoint before_mutation;

do $$
declare v numeric;
begin
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.transaction_lines'::regclass
                    and g.tgname = 'trg_assert_asset_cost_sane' and not g.tgisinternal) then
    raise exception 'FAIL: C8b — ด่านไม่กลับมาหลัง rollback (mutation ทิ้งสภาพค้างไว้)';
  end if;
  if sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000003a002') <> 0 then
    raise exception 'FAIL: C8b — ใบของ mutation ยังค้างอยู่หลัง rollback';
  end if;
  v := sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000003a001');
  if v <> 700000 then
    raise exception 'FAIL: C8b — หลัง rollback นิยามจริงต้องกลับมา (700,000) แต่ได้ %', v;
  end if;
  raise notice 'ok C8b · นิยามจริงและด่านกลับมาหลัง rollback (ไม่ทิ้งฟังก์ชันหรือ trigger กลายพันธุ์ไว้)';
end $$;

set local role authenticated;
select pg_temp.login('mgmt');

-- ============================================================
-- C7 · ตีราคาอีกเดือน (กลับของเดือนก่อนแล้วลงยอดสะสมใหม่ · mark-to-market.ts)
--      มูลค่าตลาดสิ้น พ.ย. = 1,100,000 · ต้นทุนคงเหลือ 700,000 → เป้าหมาย 400,000
-- ============================================================
do $$
declare v_cost numeric; v_surplus numeric;
begin
  perform pg_temp.post(pg_temp.entry('adj.revalue_securities_down', '2026-11-30', null,
    'กลับรายการตีราคาที่ค้างอยู่ 322,000', '00000000-0000-0000-0000-00000003a001',
    jsonb_build_array(
      pg_temp.ln('3400', 322000, 0, '00000000-0000-0000-0000-00000003a001', 'none'),
      pg_temp.ln('1700', 0, 322000, '00000000-0000-0000-0000-00000003a001', 'none'))));

  select cost_basis, surplus into v_cost, v_surplus
    from sri_os.fn_asset_ledger_parts('00000000-0000-0000-0000-00000003a001');
  if v_cost <> 700000 or v_surplus <> 0 then
    raise exception 'FAIL: C7a — หลังกลับรายการ ต้นทุนต้อง 700,000 (ได้ %) และส่วนเกินทุนต้อง 0 (ได้ %)', v_cost, v_surplus;
  end if;

  perform pg_temp.post(pg_temp.entry('adj.revalue_securities_up', '2026-11-30', null,
    'ตีราคาสะสมจากต้นทุน 400,000 (มูลค่าตลาด 1,100,000)', '00000000-0000-0000-0000-00000003a001',
    jsonb_build_array(
      pg_temp.ln('1700', 400000, 0, '00000000-0000-0000-0000-00000003a001', 'none'),
      pg_temp.ln('3400', 0, 400000, '00000000-0000-0000-0000-00000003a001', 'none'))));

  select cost_basis, surplus into v_cost, v_surplus
    from sri_os.fn_asset_ledger_parts('00000000-0000-0000-0000-00000003a001');
  if v_cost <> 700000 then
    raise exception 'FAIL: C7b — ตีราคาเดือนที่สองแล้วต้นทุนต้องยังเป็น 700,000 แต่ได้ %', v_cost;
  end if;
  if v_surplus <> 400000 then
    raise exception 'FAIL: C7b — ส่วนเกินทุนควรเป็น 400,000 (= มูลค่าตลาด 1,100,000 − ต้นทุนคงเหลือ 700,000) แต่ได้ %', v_surplus;
  end if;
  raise notice 'ok C7 · ตีราคา → ขายบางส่วน → ตีราคาอีกเดือน: ต้นทุน 700,000 คงที่ · ส่วนเกินทุน 400,000 = มูลค่าตลาด − ต้นทุนคงเหลือ';
end $$;

-- ============================================================
-- C9 · ตัดทรัพย์เกินต้นทุนที่ถืออยู่ → ปฏิเสธ (ต้นทุนคงเหลือติดลบไม่ได้)
-- ============================================================
do $$
begin
  perform pg_temp.must_fail_like('C9 ตัดทรัพย์เกินต้นทุนที่ถืออยู่',
    $q$ select pg_temp.post(pg_temp.entry('inv.sell_securities', '2026-12-01', '2026-12-01',
          'ตัดทรัพย์ 900,000 ทั้งที่ต้นทุนเหลือ 700,000 (ผิด)',
          '00000000-0000-0000-0000-00000003a001',
          jsonb_build_array(
            pg_temp.ln('1100', 900000, 0, null, 'investing', '00000000-0000-0000-0000-00000003b001'),
            pg_temp.ln('1700', 0, 900000, '00000000-0000-0000-0000-00000003a001', 'investing')))) $q$,
    'ต้นทุนคงเหลือ');
  raise notice 'ok C9 · ตัดทรัพย์เกินต้นทุนที่ถืออยู่ถูกปฏิเสธ (ต้นทุนคงเหลือติดลบไม่ได้)';
end $$;

-- ============================================================
-- C6 · ขายส่วนที่เหลือทั้งหมด → ต้นทุน 0 · 3400 **ศูนย์พอดี** · 1700 ของทรัพย์นี้เป็น 0
--      ต้นทุน 700,000 · ส่วนเกินทุน 400,000 · ขายได้ 1,200,000 → กำไร 500,000
-- ============================================================
do $$
declare v_cost numeric; v_surplus numeric;
begin
  perform pg_temp.post(pg_temp.entry('inv.sell_securities', '2026-12-02', '2026-12-02',
    'ขายหุ้น ก ที่เหลือทั้งหมด 7 หน่วย', '00000000-0000-0000-0000-00000003a001',
    jsonb_build_array(
      pg_temp.ln('1100', 1200000, 0, null, 'investing', '00000000-0000-0000-0000-00000003b001'),
      pg_temp.ln('1700', 0, 700000, '00000000-0000-0000-0000-00000003a001', 'investing'),
      pg_temp.ln('4900', 0, 500000, '00000000-0000-0000-0000-00000003a001'),
      pg_temp.ln('3400', 400000, 0, '00000000-0000-0000-0000-00000003a001'),
      pg_temp.ln('1700', 0, 400000, '00000000-0000-0000-0000-00000003a001', 'investing'))));

  select cost_basis, surplus into v_cost, v_surplus
    from sri_os.fn_asset_ledger_parts('00000000-0000-0000-0000-00000003a001');
  if v_cost <> 0 then
    raise exception 'FAIL: C6 — ขายหมดแล้วต้นทุนคงเหลือต้องเป็น 0 พอดี แต่ได้ %', v_cost;
  end if;
  if v_surplus <> 0 then
    raise exception 'FAIL: C6 — ขายหมดแล้วส่วนเกินทุนของทรัพย์นี้ต้องเหลือศูนย์พอดี แต่ได้ % (ค้างในส่วนของเจ้าของทั้งที่ทรัพย์ไม่อยู่แล้ว)', v_surplus;
  end if;
  if pg_temp.book('00000000-0000-0000-0000-00000003a001') <> 0 then
    raise exception 'FAIL: C6 — ขายหมดแล้วยอดบัญชี 1700 ของทรัพย์นี้ต้องเป็น 0 แต่ได้ % (ทรัพย์ผีค้างในงบดุล)',
      pg_temp.book('00000000-0000-0000-0000-00000003a001');
  end if;

  raise notice 'ok C6 · ขายหมด: ต้นทุน 0 · 3400 ศูนย์พอดี · ยอด 1700 ของทรัพย์นี้เป็น 0 (ไม่มีทรัพย์ผีค้าง)';
end $$;

reset role;

do $$ begin raise notice '=== ต้นทุนถัวเฉลี่ย + ล้างส่วนเกินทุนตามสัดส่วน (D-112) ผ่านทั้งหมด ==='; end $$;

rollback;
