-- ============================================================
-- SRI OS · **ใครเฉลี่ยต้นทุนได้ ใครห้าม** (20261025000010_asset_cost_basis_mode.sql)
--
-- ลูกพี่สั่ง 25/10 · เฉลี่ยได้ **สามอย่างเท่านั้น**:
--   หุ้นในตลาดหลักทรัพย์ · คริปโต · ทองคำ
-- **ที่เหลือห้ามทั้งหมด** รวมอสังหาฯ ทุกชนิด · **หุ้นบริษัทนอกตลาด** ·
--   สินทรัพย์ทางเลือกอื่นที่ไม่ใช่ทอง · ETF · กองทุน · พันธบัตร
--
-- สิ่งที่ไฟล์นี้พิสูจน์ (ทุกข้อมีตัวเลขที่วัดได้ ไม่ใช่ "ไม่ error")
--   W1 · คอนโดสองห้องตึกเดียวกัน ต้นทุน 3,000,000 / 5,000,000
--        ขายห้องแรก 3,500,000 → **กำไร +500,000** (ต้นทุนของห้องนั้นเอง)
--        ถ้าเฉลี่ยเป็น 4,000,000 → **ขาดทุน −500,000** · ต่างกัน **1,000,000**
--   W2 · สร้างล็อตที่สองให้คอนโดห้องเดียว → **ปฏิเสธ**
--   W3 · ขายคอนโด 30% → **ปฏิเสธ พร้อมบอกว่าต้องแยกชิ้นก่อน**
--   W4 · นาฬิกาสะสม (`1720` เหมือนทอง แต่ **ห้ามเฉลี่ย**) ตีราคาขึ้น 460,000
--        แล้วขาย → 3400 **ล้างหมดพอดี** ไม่เหลือเศษ · ล้างบางส่วน → ปฏิเสธ
--   W5 · `fn_asset_average_unit_cost` กับทรัพย์ที่ห้ามเฉลี่ย → **ปฏิเสธ**
--   S1 · **หุ้นบริษัทนอกตลาด** ล็อต A 100 หุ้น 1,000,000 · ล็อต B 100 หุ้น 3,000,000
--        ขายล็อต A ทั้งล็อตได้ 1,200,000
--        → ต้นทุนที่ตัดต้องเป็น **1,000,000** (กำไร +200,000)
--        → ส่งค่าเฉลี่ย 2,000,000 เข้ามา (ขาดทุน −800,000) **ถูกปฏิเสธ**
--        ต่างกัน **1,000,000** ในใบเดียว
--   L1 · **หุ้นในตลาด** ล็อตเดียวกันสองราคา → **ยังถัวเฉลี่ยได้เหมือนเดิม**
--        และราคาของล็อตเดี่ยวถูกปฏิเสธ · **อยู่รหัส `1700` เดียวกับ S1**
--        → พิสูจน์ว่าไม่ได้ใช้รหัสบัญชีตัดสิน
--   G1 · **ทองคำ** สองล็อตคนละราคา → **ยังถัวเฉลี่ยได้** (ลูกพี่ยืนยัน)
--        **อยู่รหัส `1720` เดียวกับนาฬิกาใน W4** → พิสูจน์อีกด้านของเรื่องเดียวกัน
--   C1 · **คริปโต** สองล็อตคนละราคา → ยังถัวเฉลี่ยได้
--   D1 · หมวดใหม่ที่ไม่ได้ตั้งค่า → **ห้ามเฉลี่ย** (ค่าตั้งต้นเข้มที่สุด)
--   T1 · ไม่มีด่านไหนอ่าน `assets.ticker` — เปลี่ยน ticker แล้วคำตอบไม่ขยับ
--   M  · **MUTATION** ถอดด่าน/พลิกค่าในตารางอ้างอิง แล้ววัดว่าตัวเลขผิดเท่าไร
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
create temporary table m_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into m_uid(label) values ('mgmt');
insert into auth.users(id) select id from m_uid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, 'cost-mode@local', 'mgmt', 'management', true from m_uid u;
select set_config('test.uid', (select id::text from m_uid where label = 'mgmt'), true);

insert into sri_os.user_owner_access(user_id, owner_id)
select (select id from m_uid where label = 'mgmt'), o.id from sri_os.owners o;

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
values ('00000000-0000-0000-0000-00000004b001',
        (select id from sri_os.owners where code = 'THANAKORN'),
        'KBANK', 'ธนากร', 'ธนากร - KBANK (วิธีคิดต้นทุน)');

-- **หมวดใหม่ที่ไม่ได้ตั้งค่าอะไรเลย** — ใช้พิสูจน์ค่าตั้งต้น (D1)
insert into sri_os.asset_categories(class_id, code, name_th, sort_order)
select k.id, 'ZZ_UNSET', 'หมวดใหม่ที่ยังไม่มีใครตัดสินใจ', 999
  from sri_os.asset_classes k where k.code = 'RE';

/**
 * ทรัพย์ทดสอบ — **หมวดระบุชัดทุกตัว** เพราะหมวดคือตัวตัดสิน
 *
 * จับคู่ไว้โดยตั้งใจเพื่อพิสูจน์ว่า **รหัสบัญชีตัดสินแทนไม่ได้**:
 *   `1700`: CM-PRIV (นอกตลาด · ห้ามเฉลี่ย) คู่กับ CM-LISTED (ในตลาด · เฉลี่ยได้)
 *   `1720`: CM-WATCH (ของสะสม · ห้ามเฉลี่ย) คู่กับ CM-GOLD (ทอง · เฉลี่ยได้)
 */
insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, currency, ticker)
select x.id, x.code, x.name, ct.class_id, ct.id,
       (select id from sri_os.owners where code = 'THANAKORN'), 'THB', x.ticker
  from (values
    ('00000000-0000-0000-0000-00000004a001'::uuid, 'CM-CONDO-A', 'คอนโด ตึกเดียวกัน ห้อง 11/A', 'RE_RENTAL',           null),
    ('00000000-0000-0000-0000-00000004a002'::uuid, 'CM-CONDO-B', 'คอนโด ตึกเดียวกัน ห้อง 11/B', 'RE_RENTAL',           null),
    ('00000000-0000-0000-0000-00000004a003'::uuid, 'CM-WATCH',   'นาฬิกาสะสม (ไม่ใช่ทอง)',      'COM_ALT',             null),
    ('00000000-0000-0000-0000-00000004a004'::uuid, 'CM-PRIV',    'หุ้นบริษัทนอกตลาด',           'PAPER_STOCK_PRIVATE', 'PRIVCO'),
    ('00000000-0000-0000-0000-00000004a005'::uuid, 'CM-LISTED',  'หุ้นในตลาดหลักทรัพย์',        'PAPER_STOCK_LISTED',  'PTT'),
    ('00000000-0000-0000-0000-00000004a006'::uuid, 'CM-GOLD',    'ทองคำแท่ง',                   'COM_GOLD',            null),
    ('00000000-0000-0000-0000-00000004a007'::uuid, 'CM-COIN',    'คริปโต BTC',                  'COM_CRYPTO',          'BTC'),
    ('00000000-0000-0000-0000-00000004a008'::uuid, 'CM-UNSET',   'ทรัพย์ในหมวดที่ยังไม่ตั้งค่า',  'ZZ_UNSET',            null)
  ) as x(id, code, name, cat_code, ticker)
  join sri_os.asset_categories ct on ct.code = x.cat_code;

-- ------------------------------------------------------------
-- ตัวช่วย — **ที่เดียวที่รู้รูปของ payload** ทุกเคสเดินผ่าน fn_post_entry
-- ------------------------------------------------------------
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

create or replace function pg_temp.must_pass(p_label text, p_sql text) returns void
language plpgsql as $fn$
begin
  execute p_sql;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: % — เส้นทางที่ถูกต้องถูกปฏิเสธ (กันแน่นเกิน): %', p_label, sqlerrm;
end $fn$;

/**
 * บันทึกการตัดล็อต **แล้วบังคับให้ด่านที่เลื่อนไว้ยิงทันที**
 * (`trg_lot_consumption_sane` เป็น deferred constraint trigger — ถ้าไม่บังคับ
 *  มันจะยิงตอน commit ซึ่งไม่เกิดขึ้นในเทสต์ที่ rollback ทิ้ง แล้วเคส
 *  "ต้องถูกปฏิเสธ" จะเขียวด้วยเหตุผลผิด)
 */
create or replace function pg_temp.consume(p_rows jsonb) returns void
language plpgsql as $fn$
declare r jsonb;
begin
  for r in select * from jsonb_array_elements(p_rows) loop
    insert into sri_os.asset_lot_consumptions(lot_id, txn_id, quantity, cost_thb)
    values ((r ->> 'lot')::uuid, (r ->> 'txn')::uuid,
            (r ->> 'qty')::numeric, (r ->> 'cost')::numeric);
  end loop;
  set constraints all immediate;
  set constraints all deferred;
end $fn$;

create or replace function pg_temp.consume1(p_lot uuid, p_txn uuid, p_qty numeric, p_cost numeric)
returns void language sql as $fn$
  select pg_temp.consume(jsonb_build_array(jsonb_build_object(
    'lot', p_lot, 'txn', p_txn, 'qty', p_qty, 'cost', p_cost)));
$fn$;

/** ยอดในบัญชีทรัพย์ของทรัพย์ชิ้นหนึ่ง (ใช้ตรวจว่า "ไม่มีทรัพย์ผีค้าง") */
create or replace function pg_temp.book(p_asset uuid, p_coa text) returns numeric
language sql stable as $fn$
  select coalesce(sum(l.debit - l.credit), 0)
    from sri_os.transaction_lines l
    join sri_os.transactions t on t.id = l.transaction_id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where l.asset_id = p_asset and t.status = 'posted' and c.code = p_coa;
$fn$;

/** ลงยอดยกมาของทรัพย์ชิ้นหนึ่ง **ผูกทรัพย์** (เงื่อนไขที่ด่านล็อตบังคับ) */
create or replace function pg_temp.open_asset(p_asset uuid, p_type text, p_coa text,
                                              p_amount numeric, p_memo text) returns uuid
language sql as $fn$
  select pg_temp.post(pg_temp.entry(p_type, '2026-01-01', null, p_memo, p_asset,
    jsonb_build_array(
      pg_temp.ln(p_coa, p_amount, 0, p_asset, 'none'),
      pg_temp.ln('3300', 0, p_amount, null, 'none'))));
$fn$;

-- ============================================================
-- M0 · โครงสร้าง — ไล่จาก catalog จริง ไม่ใช่ไล่ไฟล์
-- ============================================================
do $$
declare v text;
begin
  if to_regprocedure('sri_os.fn_asset_cost_basis_mode(uuid)') is null
     or to_regprocedure('sri_os.fn_asset_can_average(uuid)') is null then
    raise exception 'FAIL: M0 — ไม่มี fn_asset_cost_basis_mode/fn_asset_can_average (migration ไม่ถูก apply?) เทสต์นี้จะไม่ได้ตรวจอะไร';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'sri_os' and table_name = 'asset_categories'
                    and column_name = 'cost_basis_mode') then
    raise exception 'FAIL: M0 — ไม่มีคอลัมน์ asset_categories.cost_basis_mode';
  end if;

  select string_agg(x.want, ', ') into v
    from (values ('asset_lots', 'trg_lots_single_for_whole_item'),
                 ('transaction_lines', 'trg_assert_asset_whole_disposal')) x(tbl, want)
   where not exists (select 1 from pg_trigger g
                      where g.tgrelid = ('sri_os.' || x.tbl)::regclass
                        and g.tgname = x.want and not g.tgisinternal);
  if v is not null then raise exception 'FAIL: M0 — trigger หายไป: %', v; end if;

  -- **เฉลี่ยได้สามอย่างเท่านั้น** — ถ้าวันหนึ่งมีคนเพิ่มหมวดที่เฉลี่ยได้ ต้องแดงที่นี่
  select string_agg(code, ', ' order by code) into v
    from sri_os.asset_categories where cost_basis_mode = 'average';
  if v is distinct from 'COM_CRYPTO, COM_GOLD, PAPER_STOCK_LISTED' then
    raise exception 'FAIL: M0 — หมวดที่เฉลี่ยได้ต้องเป็น COM_CRYPTO, COM_GOLD, PAPER_STOCK_LISTED เท่านั้น (ลูกพี่สั่ง: หุ้นในตลาด · คริปโต · ทองคำ) แต่ได้: %',
      coalesce(v, '(ไม่มีเลย)');
  end if;

  raise notice 'ok M0 · โครงสร้างครบ · เฉลี่ยได้สามหมวด: หุ้นในตลาด · คริปโต · ทองคำ';
end $$;

-- ============================================================
-- D1 · ค่าตั้งต้น — หมวดที่ยังไม่มีใครตัดสินใจ **ห้ามเฉลี่ย**
--      "เผลอแล้วได้การปฏิเสธ ไม่ใช่การเฉลี่ยเงียบๆ"
-- ============================================================
do $$
declare v text;
begin
  v := sri_os.fn_asset_cost_basis_mode('00000000-0000-0000-0000-00000004a008');
  if v <> 'whole_item' then
    raise exception 'FAIL: D1 — ทรัพย์ในหมวดที่ไม่ได้ตั้งค่าต้องได้ whole_item (เข้มที่สุด) แต่ได้ %', v;
  end if;
  if sri_os.fn_asset_can_average('00000000-0000-0000-0000-00000004a008') then
    raise exception 'FAIL: D1 — หมวดที่ไม่ได้ตั้งค่ากลับเฉลี่ยได้ · ค่าตั้งต้นต้องเป็นด้านที่ปฏิเสธ';
  end if;

  -- ทรัพย์ที่ไม่มีอยู่จริงเลยก็ต้องได้ค่าที่เข้มที่สุด ไม่ใช่ null แล้วถูกตีความว่าเฉลี่ยได้
  if sri_os.fn_asset_cost_basis_mode('00000000-0000-0000-0000-0000deadbeef') <> 'whole_item' then
    raise exception 'FAIL: D1 — ทรัพย์ที่หาไม่เจอต้องได้ whole_item';
  end if;

  raise notice 'ok D1 · หมวดที่ยังไม่ตั้งค่า + ทรัพย์ที่หาไม่เจอ → whole_item (ห้ามเฉลี่ย)';
end $$;

-- ============================================================
-- T1 · **ไม่มีด่านไหนอ่าน `assets.ticker`** (D-115)
--      ticker เว้นได้/กรอกผิดได้ → ถ้ามีด่านไหนเชื่อมัน คำตอบจะขยับตามที่เราแก้
-- ============================================================
do $$
declare v_before text; v_after text;
begin
  v_before := sri_os.fn_asset_cost_basis_mode('00000000-0000-0000-0000-00000004a004');
  update sri_os.assets set ticker = 'PTT' where id = '00000000-0000-0000-0000-00000004a004';
  v_after := sri_os.fn_asset_cost_basis_mode('00000000-0000-0000-0000-00000004a004');
  if v_before <> 'specific_lot' or v_after <> v_before then
    raise exception 'FAIL: T1 — เปลี่ยน ticker ของหุ้นนอกตลาดเป็น "PTT" แล้ววิธีคิดต้นทุนเปลี่ยนจาก % เป็น % · ด่านต้องอ่านจากหมวด ไม่ใช่จาก ticker ที่กรอกผิดได้',
      v_before, v_after;
  end if;
  update sri_os.assets set ticker = 'PRIVCO' where id = '00000000-0000-0000-0000-00000004a004';

  -- และทรัพย์ที่ไม่มี ticker เลย (ทอง) ก็ยังเฉลี่ยได้ — "ไม่มี ticker" ไม่ได้แปลว่าห้ามเฉลี่ย
  if not sri_os.fn_asset_can_average('00000000-0000-0000-0000-00000004a006') then
    raise exception 'FAIL: T1 — ทองคำไม่มี ticker แต่ลูกพี่ยืนยันว่าเฉลี่ยได้';
  end if;

  raise notice 'ok T1 · ticker ไม่มีผลต่อคำตอบทั้งสองทิศ (แก้เป็น PTT ก็ยังห้ามเฉลี่ย · ไม่มี ticker ก็ยังเฉลี่ยได้)';
end $$;

-- ============================================================
-- W1 · **คอนโดสองห้องตึกเดียวกัน — ต้นทุนของห้องไหนก็ของห้องนั้น**
--
--   ห้อง 11/A ต้นทุน 3,000,000 · ห้อง 11/B ต้นทุน 5,000,000
--   ขายห้อง 11/A ได้ 3,500,000
--     ถูก   : กำไร 3,500,000 − 3,000,000 = **+500,000**
--     ถ้าเฉลี่ย: 3,500,000 − (3,000,000+5,000,000)/2 = **−500,000**
--   ต่างกัน **1,000,000 บาทจากห้องเดียว** และงบดุลดุลทั้งสองทาง
-- ============================================================
do $$
declare
  v_right   numeric;
  v_avg     numeric;
  v_gain    numeric;
  v_costa   numeric;
  v_costb   numeric;
begin
  perform pg_temp.open_asset('00000000-0000-0000-0000-00000004a001', 'opn.property', '1500',
                             3000000, 'ยอดยกมา คอนโด ห้อง 11/A ต้นทุน 3,000,000');
  perform pg_temp.open_asset('00000000-0000-0000-0000-00000004a002', 'opn.property', '1500',
                             5000000, 'ยอดยกมา คอนโด ห้อง 11/B ต้นทุน 5,000,000');

  v_costa := sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000004a001');
  v_costb := sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000004a002');
  if v_costa <> 3000000 or v_costb <> 5000000 then
    raise exception 'FAIL: W1 — ต้นทุนรายห้องต้องแยกกัน (A=3,000,000 B=5,000,000) แต่ได้ A=% B=%',
      v_costa, v_costb;
  end if;

  -- ขายห้อง 11/A ทั้งห้อง · ตัดต้นทุนของห้องนั้นทั้งก้อน
  perform pg_temp.post(pg_temp.entry('inv.sell_re', '2026-06-30', '2026-06-30',
    'ขายคอนโด ห้อง 11/A ได้ 3,500,000 · ตัดต้นทุนของห้องนั้นเอง 3,000,000',
    '00000000-0000-0000-0000-00000004a001',
    jsonb_build_array(
      pg_temp.ln('1100', 3500000, 0, null, 'investing', '00000000-0000-0000-0000-00000004b001'),
      pg_temp.ln('1500', 0, 3000000, '00000000-0000-0000-0000-00000004a001', 'investing'),
      pg_temp.ln('4300', 0,  500000, '00000000-0000-0000-0000-00000004a001'))));

  -- กำไรที่บันทึกจริง = ยอดในบัญชีกำไรจากการขายของทรัพย์ชิ้นนี้
  select coalesce(sum(l.credit - l.debit), 0) into v_gain
    from sri_os.transaction_lines l
    join sri_os.transactions t on t.id = l.transaction_id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where l.asset_id = '00000000-0000-0000-0000-00000004a001'
     and t.status = 'posted' and c.code = '4300';

  v_right := 3500000 - 3000000;                    -- ต้นทุนของห้องนั้นเอง
  v_avg   := 3500000 - (3000000 + 5000000) / 2;    -- ถ้าเอาสองห้องมาเฉลี่ย

  if v_gain <> v_right or v_right <> 500000 then
    raise exception 'FAIL: W1 — กำไรต้องเป็น +500,000 (ต้นทุนของห้องนั้นเอง) แต่สมุดบันทึก %', v_gain;
  end if;
  if v_avg <> -500000 then
    raise exception 'FAIL: W1 — เลขเปรียบเทียบของทางที่ผิดต้องเป็น −500,000 แต่คิดได้ %', v_avg;
  end if;
  if v_right - v_avg <> 1000000 then
    raise exception 'FAIL: W1 — สองทางต้องต่างกัน 1,000,000 แต่ต่างกัน % · ถ้าเท่ากัน เทสต์นี้ไม่ได้วัดอะไร',
      v_right - v_avg;
  end if;

  -- ห้อง B ต้องไม่ถูกแตะเลย และห้อง A ต้องไม่เหลือทรัพย์ผี
  if sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000004a002') <> 5000000 then
    raise exception 'FAIL: W1 — ขายห้อง A ไปแตะต้นทุนห้อง B';
  end if;
  if pg_temp.book('00000000-0000-0000-0000-00000004a001', '1500') <> 0 then
    raise exception 'FAIL: W1 — บัญชีทรัพย์ของห้อง A ต้องกลับเป็นศูนย์ แต่เหลือ %',
      pg_temp.book('00000000-0000-0000-0000-00000004a001', '1500');
  end if;

  raise notice 'ok W1 · ขายห้อง 11/A กำไร +500,000 จากต้นทุนของห้องนั้นเอง (ถ้าเฉลี่ยจะได้ −500,000 · ต่างกัน 1,000,000) · ห้อง 11/B ยัง 5,000,000 ครบ';
end $$;

-- ============================================================
-- W2 · **สร้างล็อตที่สองให้คอนโดห้องเดียว → ปฏิเสธ**
--      ล็อตหลายล็อตบนของชิ้นเดียวคือรูปร่างของการเฉลี่ยล้วนๆ
-- ============================================================
do $$
begin
  -- ล็อตแรกของห้อง 11/B ลงได้ (ทรัพย์ชิ้นเดียว = ซื้อครั้งเดียว)
  perform pg_temp.must_pass('W2 ล็อตแรกของคอนโด', $q$
    insert into sri_os.asset_lots(asset_id, acquired_date, quantity, cost_thb, note)
    values ('00000000-0000-0000-0000-00000004a002', '2026-01-01', 1, 5000000, 'ห้อง 11/B') $q$);

  -- ล็อตที่สอง → ปฏิเสธ (นี่คือทางที่เอาห้อง A มาเฉลี่ยกับห้อง B ได้)
  perform pg_temp.must_fail_like('W2 ล็อตที่สองของคอนโดห้องเดียว', $q$
    insert into sri_os.asset_lots(asset_id, acquired_date, quantity, cost_thb, note)
    values ('00000000-0000-0000-0000-00000004a002', '2026-02-01', 1, 3000000, 'ห้องที่สอง (ผิด)') $q$,
    'มีล็อตได้ไม่เกินหนึ่ง');

  if (select count(*) from sri_os.asset_lots
       where asset_id = '00000000-0000-0000-0000-00000004a002') <> 1 then
    raise exception 'FAIL: W2 — ล็อตของคอนโดต้องเหลือหนึ่งล็อต';
  end if;

  raise notice 'ok W2 · คอนโดห้องเดียวมีได้ล็อตเดียว · ล็อตที่สองถูกปฏิเสธ (ต้องสร้างทรัพย์แถวใหม่)';
end $$;

-- ============================================================
-- W3 · **ขายคอนโด 30% → ปฏิเสธ พร้อมบอกว่าต้องแยกชิ้นก่อน**
--      (ทางที่ถูกตาม D-112: ขายออกทั้งชิ้นแล้วซื้อเข้าเป็นหลายชิ้น ยอดชนกัน = 0)
-- ============================================================
do $$
declare v_cost_before numeric;
begin
  v_cost_before := sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000004a002');

  perform pg_temp.must_fail_like('W3 ขายคอนโด 30%', format($q$
    select pg_temp.post(pg_temp.entry('inv.sell_re', '2026-07-31', '2026-07-31',
      'ขายคอนโด ห้อง 11/B แค่ 30%% (ผิด)',
      '00000000-0000-0000-0000-00000004a002',
      jsonb_build_array(
        pg_temp.ln('1100', 1750000, 0, null, 'investing', %L),
        pg_temp.ln('1500', 0, 1500000, %L, 'investing'),
        pg_temp.ln('4300', 0,  250000, %L))))
    $q$, '00000000-0000-0000-0000-00000004b001',
         '00000000-0000-0000-0000-00000004a002',
         '00000000-0000-0000-0000-00000004a002'),
    'ต้องแยกชิ้นก่อน');

  if sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000004a002') <> v_cost_before then
    raise exception 'FAIL: W3 — ใบที่ถูกปฏิเสธไม่ควรทิ้งผลไว้ แต่ต้นทุนเปลี่ยนจาก % เป็น %',
      v_cost_before, sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000004a002');
  end if;

  -- ขายทั้งห้องได้ตามปกติ (ด่านต้องไม่ห้ามเส้นทางที่ถูก)
  perform pg_temp.must_pass('W3 ขายคอนโดทั้งห้อง', format($q$
    select pg_temp.post(pg_temp.entry('inv.sell_re', '2026-08-31', '2026-08-31',
      'ขายคอนโด ห้อง 11/B ทั้งห้อง 5,800,000',
      '00000000-0000-0000-0000-00000004a002',
      jsonb_build_array(
        pg_temp.ln('1100', 5800000, 0, null, 'investing', %L),
        pg_temp.ln('1500', 0, 5000000, %L, 'investing'),
        pg_temp.ln('4300', 0,  800000, %L))))
    $q$, '00000000-0000-0000-0000-00000004b001',
         '00000000-0000-0000-0000-00000004a002',
         '00000000-0000-0000-0000-00000004a002'));

  if sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000004a002') <> 0 then
    raise exception 'FAIL: W3 — ขายทั้งห้องแล้วต้นทุนต้องเป็น 0 แต่ได้ %',
      sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000004a002');
  end if;

  raise notice 'ok W3 · ขายคอนโด 30%% ถูกปฏิเสธ (ยังเหลือต้นทุน 3,500,000 ในบัญชีทรัพย์) · ขายทั้งห้องยังทำได้ กำไร 800,000';
end $$;

-- ============================================================
-- W4 · **นาฬิกาสะสมใน `1720` (ห้ามเฉลี่ย)** ตีราคาขึ้นแล้วขาย
--      → 3400 ต้องล้าง **หมดพอดี** ไม่เหลือเศษ
--
--      ทรัพย์นี้อยู่รหัสบัญชีเดียวกับทองคำ (`1720`) แต่คนละโหมด
--      → พิสูจน์ว่าระบบ **ไม่ได้ใช้รหัสบัญชีตัดสิน**
-- ============================================================
do $$
declare v_cost numeric; v_surplus numeric;
begin
  perform pg_temp.open_asset('00000000-0000-0000-0000-00000004a003', 'opn.gold_alt', '1720',
                             1000000, 'ยอดยกมา นาฬิกาสะสม ต้นทุน 1,000,000');

  -- ตีราคาขึ้น 460,000 → เข้า 3400 ในส่วนของเจ้าของ ไม่เข้า P&L
  perform pg_temp.post(pg_temp.entry('adj.revalue_commodity_up', '2026-09-30', null,
    'ตีราคานาฬิกาสะสมขึ้น 460,000', '00000000-0000-0000-0000-00000004a003',
    jsonb_build_array(
      pg_temp.ln('1720', 460000, 0, '00000000-0000-0000-0000-00000004a003', 'none'),
      pg_temp.ln('3400', 0, 460000, '00000000-0000-0000-0000-00000004a003', 'none'))));

  select cost_basis, surplus into v_cost, v_surplus
    from sri_os.fn_asset_ledger_parts('00000000-0000-0000-0000-00000004a003');
  if v_cost <> 1000000 or v_surplus <> 460000 then
    raise exception 'FAIL: W4 — หลังตีราคา ต้นทุนต้องยัง 1,000,000 และ 3400 ต้องเป็น 460,000 แต่ได้ % / %',
      v_cost, v_surplus;
  end if;

  -- ล้าง 3400 **บางส่วน** ตอนขาย → ปฏิเสธ (ทรัพย์ชิ้นเดียวไม่มี "สัดส่วน")
  perform pg_temp.must_fail_like('W4 ขายแล้วล้าง 3400 แค่บางส่วน', format($q$
    select pg_temp.post(pg_temp.entry('inv.sell_commodity', '2026-10-15', '2026-10-15',
      'ขายนาฬิกา แต่ล้าง 3400 แค่ 200,000 (ผิด)',
      '00000000-0000-0000-0000-00000004a003',
      jsonb_build_array(
        pg_temp.ln('1100', 2000000, 0, null, 'investing', %L),
        pg_temp.ln('1720', 0, 1200000, %L, 'investing'),
        pg_temp.ln('4900', 0, 1000000, %L),
        pg_temp.ln('3400', 200000, 0, %L))))
    $q$, '00000000-0000-0000-0000-00000004b001',
         '00000000-0000-0000-0000-00000004a003',
         '00000000-0000-0000-0000-00000004a003',
         '00000000-0000-0000-0000-00000004a003'),
    'ส่วนเกินทุน');

  -- ขายทั้งชิ้นและล้าง 3400 ทั้งก้อน → ผ่าน
  perform pg_temp.must_pass('W4 ขายทั้งชิ้น ล้าง 3400 ทั้งก้อน', format($q$
    select pg_temp.post(pg_temp.entry('inv.sell_commodity', '2026-10-31', '2026-10-31',
      'ขายนาฬิกาสะสม 2,000,000 · ล้างส่วนเกินทุน 460,000 ทั้งก้อน',
      '00000000-0000-0000-0000-00000004a003',
      jsonb_build_array(
        pg_temp.ln('1100', 2000000, 0, null, 'investing', %L),
        pg_temp.ln('1720', 0, 1000000, %L, 'investing'),
        pg_temp.ln('4900', 0, 1000000, %L),
        pg_temp.ln('3400', 460000, 0, %L),
        pg_temp.ln('1720', 0,  460000, %L, 'investing'))))
    $q$, '00000000-0000-0000-0000-00000004b001',
         '00000000-0000-0000-0000-00000004a003',
         '00000000-0000-0000-0000-00000004a003',
         '00000000-0000-0000-0000-00000004a003',
         '00000000-0000-0000-0000-00000004a003'));

  select cost_basis, surplus into v_cost, v_surplus
    from sri_os.fn_asset_ledger_parts('00000000-0000-0000-0000-00000004a003');
  if v_cost <> 0 or v_surplus <> 0 then
    raise exception 'FAIL: W4 — ขายทั้งชิ้นแล้วต้นทุนและ 3400 ต้องเป็นศูนย์พอดี แต่ได้ % / % (เศษที่เหลือคือทรัพย์ผีในส่วนของเจ้าของ)',
      v_cost, v_surplus;
  end if;
  if pg_temp.book('00000000-0000-0000-0000-00000004a003', '1720') <> 0
     or pg_temp.book('00000000-0000-0000-0000-00000004a003', '3400') <> 0 then
    raise exception 'FAIL: W4 — ยอดในบัญชี 1720 (%) และ 3400 (%) ต้องกลับเป็นศูนย์ทั้งคู่',
      pg_temp.book('00000000-0000-0000-0000-00000004a003', '1720'),
      pg_temp.book('00000000-0000-0000-0000-00000004a003', '3400');
  end if;

  raise notice 'ok W4 · นาฬิกาใน 1720 (ห้ามเฉลี่ย): ตีขึ้น 460,000 → ขาย → 3400 = 0 พอดี · 1720 = 0 · ล้างบางส่วนถูกปฏิเสธ';
end $$;

-- ============================================================
-- W5 · `fn_asset_average_unit_cost` กับทรัพย์ที่ห้ามเฉลี่ย → **ปฏิเสธ**
--      (เลือก "ดังตอนถาม" ไม่ใช่ "คืนเลขทั้งก้อน" เพราะอัตราต่อหน่วย
--       มีความหมายเดียวคือเอาไปคูณสัดส่วน = การเฉลี่ย)
-- ============================================================
do $$
begin
  perform pg_temp.must_fail_like('W5 ถามค่าเฉลี่ยของคอนโด', $q$
    select sri_os.fn_asset_average_unit_cost('00000000-0000-0000-0000-00000004a001') $q$,
    'ห้ามถัวเฉลี่ยต้นทุน');
  perform pg_temp.must_fail_like('W5 ถามค่าเฉลี่ยของหุ้นนอกตลาด', $q$
    select sri_os.fn_asset_average_unit_cost('00000000-0000-0000-0000-00000004a004') $q$,
    'ห้ามถัวเฉลี่ยต้นทุน');
  perform pg_temp.must_fail_like('W5 ถามค่าเฉลี่ยของนาฬิกา', $q$
    select sri_os.fn_asset_average_unit_cost('00000000-0000-0000-0000-00000004a003') $q$,
    'ห้ามถัวเฉลี่ยต้นทุน');

  -- แต่ **ยอดรวมทั้งก้อน** ยังถามได้ (เอาไปเฉลี่ยไม่ได้โดยไม่มีตัวหาร)
  if sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000004a002') is null then
    raise exception 'FAIL: W5 — ต้นทุนทั้งก้อนต้องยังอ่านได้';
  end if;

  raise notice 'ok W5 · อัตราต่อหน่วยของทรัพย์ที่ห้ามเฉลี่ย → raise · ยอดรวมทั้งก้อนยังอ่านได้ตามปกติ';
end $$;

-- ============================================================
-- S1 · **หุ้นบริษัทนอกตลาด — ระบุล็อตที่ขาย ห้ามเฉลี่ย**
--
--   ล็อต A 100 หุ้น 1,000,000 (10,000/หุ้น) · ล็อต B 100 หุ้น 3,000,000 (30,000/หุ้น)
--   ขายล็อต A ทั้งล็อตได้ 1,200,000
--     ถูก   : ต้นทุน **1,000,000** → กำไร **+200,000**
--     ถ้าเฉลี่ย: ต้นทุน 2,000,000 → **ขาดทุน −800,000**
--   ต่างกัน **1,000,000** ในใบเดียว
-- ============================================================
do $$
declare v_lot_a uuid; v_lot_b uuid; v_txn uuid;
begin
  perform pg_temp.open_asset('00000000-0000-0000-0000-00000004a004', 'opn.securities', '1700',
                             4000000, 'ยอดยกมา หุ้นนอกตลาด 200 หุ้น สองล็อต');

  insert into sri_os.asset_lots(asset_id, acquired_date, quantity, cost_thb, note)
  values ('00000000-0000-0000-0000-00000004a004', '2025-03-01', 100, 1000000, 'ล็อต A 10,000/หุ้น')
  returning id into v_lot_a;
  insert into sri_os.asset_lots(asset_id, acquired_date, quantity, cost_thb, note)
  values ('00000000-0000-0000-0000-00000004a004', '2025-09-01', 100, 3000000, 'ล็อต B 30,000/หุ้น')
  returning id into v_lot_b;

  -- หลายล็อตบนทรัพย์ที่ห้ามเฉลี่ย **ทำได้** (ล็อตคือข้อมูล · ลูกพี่ห้ามแค่วิธีคิด)
  if (select count(*) from sri_os.asset_lots
       where asset_id = '00000000-0000-0000-0000-00000004a004') <> 2 then
    raise exception 'FAIL: S1 — หุ้นนอกตลาดต้องเก็บได้หลายล็อต (ล็อต = ข้อมูล ไม่ใช่วิธีคิด)';
  end if;

  -- ใบขายล็อต A: ตัดต้นทุน **ของล็อต A เอง** 1,000,000 → กำไร 200,000
  v_txn := pg_temp.post(pg_temp.entry('inv.sell_securities', '2026-05-15', '2026-05-15',
    'ขายหุ้นนอกตลาด ล็อต A 100 หุ้น ได้ 1,200,000 · ต้นทุนของล็อตนั้น 1,000,000',
    '00000000-0000-0000-0000-00000004a004',
    jsonb_build_array(
      pg_temp.ln('1100', 1200000, 0, null, 'investing', '00000000-0000-0000-0000-00000004b001'),
      pg_temp.ln('1700', 0, 1000000, '00000000-0000-0000-0000-00000004a004', 'investing'),
      pg_temp.ln('4900', 0,  200000, '00000000-0000-0000-0000-00000004a004'))));

  -- **ส่งค่าเฉลี่ย 2,000,000 เข้ามา → ต้องถูกปฏิเสธ** (นี่คือตัวเลขของทางที่ผิด)
  perform pg_temp.must_fail_like('S1 ตัดล็อต A ด้วยต้นทุนเฉลี่ย 2,000,000', format($q$
    select pg_temp.consume1(%L, %L, 100, 2000000) $q$, v_lot_a, v_txn),
    'ห้ามถัวเฉลี่ยต้นทุน');

  -- ค่าที่ถูกต้องตัวเดียว = ราคาของล็อต A เอง
  perform pg_temp.must_pass('S1 ตัดล็อต A ด้วยราคาของล็อตนั้น 1,000,000', format($q$
    select pg_temp.consume1(%L, %L, 100, 1000000) $q$, v_lot_a, v_txn));

  if sri_os.fn_asset_lot_cost('00000000-0000-0000-0000-00000004a004') <> 3000000 then
    raise exception 'FAIL: S1 — หลังขายล็อต A ต้นทุนคงเหลือต้องเป็น 3,000,000 (ของล็อต B) แต่ได้ %',
      sri_os.fn_asset_lot_cost('00000000-0000-0000-0000-00000004a004');
  end if;
  if sri_os.fn_asset_units('00000000-0000-0000-0000-00000004a004') <> 100 then
    raise exception 'FAIL: S1 — ต้องเหลือ 100 หุ้น (ล็อต B) แต่ได้ %',
      sri_os.fn_asset_units('00000000-0000-0000-0000-00000004a004');
  end if;

  raise notice 'ok S1 · หุ้นนอกตลาด: ขายล็อต A ต้นทุน 1,000,000 กำไร +200,000 (ถ้าเฉลี่ยจะเป็นต้นทุน 2,000,000 ขาดทุน −800,000 · ต่างกัน 1,000,000) · ค่าเฉลี่ยถูกปฏิเสธ · เหลือล็อต B 100 หุ้น 3,000,000';
end $$;

-- ============================================================
-- L1 · **หุ้นในตลาด — ยังถัวเฉลี่ยได้เหมือนเดิม**
--      ล็อต A 100 หุ้น 1,000,000 · ล็อต B 100 หุ้น 3,000,000 → เฉลี่ย 20,000/หุ้น
--      ขาย 100 หุ้นได้ 1,200,000 → ต้นทุน 2,000,000 → **ขาดทุน 800,000**
--
--      **อยู่รหัส `1700` เดียวกับ S1 แต่คนละคำตอบ** → ไม่ได้ใช้รหัสบัญชีตัดสิน
--      และราคาของล็อตเดี่ยว (1,000,000) ถูกปฏิเสธ = คนละกฎกับ S1 จริงๆ
-- ============================================================
do $$
declare v_lot_a uuid; v_lot_b uuid; v_txn uuid; v_avg numeric;
begin
  perform pg_temp.open_asset('00000000-0000-0000-0000-00000004a005', 'opn.securities', '1700',
                             4000000, 'ยอดยกมา หุ้นในตลาด 200 หุ้น สองล็อต');

  insert into sri_os.asset_lots(asset_id, acquired_date, quantity, cost_thb, note)
  values ('00000000-0000-0000-0000-00000004a005', '2025-03-01', 100, 1000000, 'ล็อต A 10,000/หุ้น')
  returning id into v_lot_a;
  insert into sri_os.asset_lots(asset_id, acquired_date, quantity, cost_thb, note)
  values ('00000000-0000-0000-0000-00000004a005', '2025-09-01', 100, 3000000, 'ล็อต B 30,000/หุ้น')
  returning id into v_lot_b;

  v_avg := sri_os.fn_asset_average_unit_cost('00000000-0000-0000-0000-00000004a005');
  if v_avg <> 20000 then
    raise exception 'FAIL: L1 — ต้นทุนถัวเฉลี่ยของหุ้นในตลาดต้องเป็น 20,000/หุ้น แต่ได้ %', v_avg;
  end if;

  v_txn := pg_temp.post(pg_temp.entry('inv.sell_securities', '2026-05-20', '2026-05-20',
    'ขายหุ้นในตลาด 100 หุ้น ได้ 1,200,000 · ต้นทุนถัวเฉลี่ย 2,000,000',
    '00000000-0000-0000-0000-00000004a005',
    jsonb_build_array(
      pg_temp.ln('1100', 1200000, 0, null, 'investing', '00000000-0000-0000-0000-00000004b001'),
      pg_temp.ln('1700', 0, 2000000, '00000000-0000-0000-0000-00000004a005', 'investing'),
      pg_temp.ln('5910', 800000, 0, '00000000-0000-0000-0000-00000004a005'))));

  -- ราคาของล็อตเดี่ยว (1,000,000) **ถูกปฏิเสธ** สำหรับหุ้นในตลาด — ต้องเป็นค่าเฉลี่ย
  perform pg_temp.must_fail_like('L1 ตัดล็อต A ด้วยราคาล็อตเดี่ยว 1,000,000', format($q$
    select pg_temp.consume1(%L, %L, 100, 1000000) $q$, v_lot_a, v_txn),
    'ต้นทุนถัวเฉลี่ยคำนวณจากทะเบียนล็อต');

  -- ค่าเฉลี่ย 2,000,000 ผ่าน (เส้นทาง D-112 เดิมไม่ถูกด่านใหม่ฆ่า)
  perform pg_temp.must_pass('L1 ตัดล็อต A ด้วยต้นทุนถัวเฉลี่ย 2,000,000', format($q$
    select pg_temp.consume1(%L, %L, 100, 2000000) $q$, v_lot_a, v_txn));

  if sri_os.fn_asset_lot_cost('00000000-0000-0000-0000-00000004a005') <> 2000000 then
    raise exception 'FAIL: L1 — หลังขายครึ่งกอง ต้นทุนคงเหลือต้องเป็น 2,000,000 (ครึ่งของ 4,000,000) แต่ได้ %',
      sri_os.fn_asset_lot_cost('00000000-0000-0000-0000-00000004a005');
  end if;
  if sri_os.fn_asset_average_unit_cost('00000000-0000-0000-0000-00000004a005') <> 20000 then
    raise exception 'FAIL: L1 — ต้นทุนถัวเฉลี่ยต่อหน่วยต้องไม่เปลี่ยนเพราะการขาย (ยัง 20,000)';
  end if;

  raise notice 'ok L1 · หุ้นในตลาดใน 1700 ยังเฉลี่ยได้ (20,000/หุ้น · ขาย 100 หุ้น ต้นทุน 2,000,000 ขาดทุน 800,000) · ราคาล็อตเดี่ยวถูกปฏิเสธ — คนละคำตอบกับหุ้นนอกตลาดที่อยู่รหัสเดียวกัน';
end $$;

-- ============================================================
-- G1 · **ทองคำ — ลูกพี่ยืนยันว่าเฉลี่ยได้**
--      ล็อต A 10 หน่วย 300,000 · ล็อต B 10 หน่วย 400,000 → เฉลี่ย 35,000/หน่วย
--      ขาย 10 หน่วยได้ 400,000 → ต้นทุน 350,000 → กำไร 50,000
--
--      **อยู่รหัส `1720` เดียวกับนาฬิกาใน W4 แต่คนละคำตอบ**
-- ============================================================
do $$
declare v_lot_a uuid; v_txn uuid;
begin
  perform pg_temp.open_asset('00000000-0000-0000-0000-00000004a006', 'opn.gold_alt', '1720',
                             700000, 'ยอดยกมา ทองคำ 20 หน่วย สองล็อต');

  insert into sri_os.asset_lots(asset_id, acquired_date, quantity, cost_thb, note)
  values ('00000000-0000-0000-0000-00000004a006', '2025-04-01', 10, 300000, 'ทอง ล็อต A 30,000/หน่วย')
  returning id into v_lot_a;
  insert into sri_os.asset_lots(asset_id, acquired_date, quantity, cost_thb, note)
  values ('00000000-0000-0000-0000-00000004a006', '2025-10-01', 10, 400000, 'ทอง ล็อต B 40,000/หน่วย');

  if sri_os.fn_asset_average_unit_cost('00000000-0000-0000-0000-00000004a006') <> 35000 then
    raise exception 'FAIL: G1 — ต้นทุนถัวเฉลี่ยของทองต้องเป็น 35,000/หน่วย แต่ได้ %',
      sri_os.fn_asset_average_unit_cost('00000000-0000-0000-0000-00000004a006');
  end if;

  v_txn := pg_temp.post(pg_temp.entry('inv.sell_commodity', '2026-06-10', '2026-06-10',
    'ขายทอง 10 หน่วย ได้ 400,000 · ต้นทุนถัวเฉลี่ย 350,000',
    '00000000-0000-0000-0000-00000004a006',
    jsonb_build_array(
      pg_temp.ln('1100', 400000, 0, null, 'investing', '00000000-0000-0000-0000-00000004b001'),
      pg_temp.ln('1720', 0, 350000, '00000000-0000-0000-0000-00000004a006', 'investing'),
      pg_temp.ln('4900', 0,  50000, '00000000-0000-0000-0000-00000004a006'))));

  -- ราคาของล็อตเดี่ยว (300,000) ถูกปฏิเสธ — ทองใช้ค่าเฉลี่ย
  perform pg_temp.must_fail_like('G1 ตัดทองด้วยราคาล็อตเดี่ยว 300,000', format($q$
    select pg_temp.consume1(%L, %L, 10, 300000) $q$, v_lot_a, v_txn),
    'ต้นทุนถัวเฉลี่ยคำนวณจากทะเบียนล็อต');

  perform pg_temp.must_pass('G1 ตัดทองด้วยต้นทุนถัวเฉลี่ย 350,000', format($q$
    select pg_temp.consume1(%L, %L, 10, 350000) $q$, v_lot_a, v_txn));

  if sri_os.fn_asset_lot_cost('00000000-0000-0000-0000-00000004a006') <> 350000 then
    raise exception 'FAIL: G1 — ต้นทุนทองคงเหลือต้องเป็น 350,000 แต่ได้ %',
      sri_os.fn_asset_lot_cost('00000000-0000-0000-0000-00000004a006');
  end if;

  raise notice 'ok G1 · ทองคำใน 1720 เฉลี่ยได้ (35,000/หน่วย · ขาย 10 หน่วย ต้นทุน 350,000 กำไร 50,000) — คนละคำตอบกับนาฬิกาที่อยู่รหัส 1720 เดียวกัน';
end $$;

-- ============================================================
-- C1 · **คริปโต — ยังถัวเฉลี่ยได้**
--      1 BTC @ 2,000,000 · 1 BTC @ 3,000,000 → เฉลี่ย 2,500,000/เหรียญ
-- ============================================================
do $$
declare v_lot_a uuid; v_txn uuid;
begin
  perform pg_temp.open_asset('00000000-0000-0000-0000-00000004a007', 'opn.gold_alt', '1720',
                             5000000, 'ยอดยกมา BTC 2 เหรียญ สองล็อต');

  insert into sri_os.asset_lots(asset_id, acquired_date, quantity, cost_thb, note)
  values ('00000000-0000-0000-0000-00000004a007', '2025-02-01', 1, 2000000, 'BTC ล็อต A')
  returning id into v_lot_a;
  insert into sri_os.asset_lots(asset_id, acquired_date, quantity, cost_thb, note)
  values ('00000000-0000-0000-0000-00000004a007', '2025-08-01', 1, 3000000, 'BTC ล็อต B');

  if sri_os.fn_asset_average_unit_cost('00000000-0000-0000-0000-00000004a007') <> 2500000 then
    raise exception 'FAIL: C1 — ต้นทุนถัวเฉลี่ยของ BTC ต้องเป็น 2,500,000/เหรียญ แต่ได้ %',
      sri_os.fn_asset_average_unit_cost('00000000-0000-0000-0000-00000004a007');
  end if;

  v_txn := pg_temp.post(pg_temp.entry('inv.sell_commodity', '2026-06-20', '2026-06-20',
    'ขาย BTC 1 เหรียญ ได้ 2,800,000 · ต้นทุนถัวเฉลี่ย 2,500,000',
    '00000000-0000-0000-0000-00000004a007',
    jsonb_build_array(
      pg_temp.ln('1100', 2800000, 0, null, 'investing', '00000000-0000-0000-0000-00000004b001'),
      pg_temp.ln('1720', 0, 2500000, '00000000-0000-0000-0000-00000004a007', 'investing'),
      pg_temp.ln('4900', 0,  300000, '00000000-0000-0000-0000-00000004a007'))));

  perform pg_temp.must_pass('C1 ตัด BTC ด้วยต้นทุนถัวเฉลี่ย 2,500,000', format($q$
    select pg_temp.consume1(%L, %L, 1, 2500000) $q$, v_lot_a, v_txn));

  raise notice 'ok C1 · คริปโตยังเฉลี่ยได้ (2,500,000/เหรียญ · ขาย 1 เหรียญ กำไร 300,000)';
end $$;

-- ============================================================
-- M · **MUTATION** — ถอดของที่เพิ่ง build แล้ววัดว่าตัวเลขผิดเท่าไร
--     ทุกเคสทำใน savepoint แล้ว rollback (ไม่ทิ้งสภาพไว้ให้เคสถัดไป)
-- ============================================================

-- ---------- M1 · พลิกค่าในตารางอ้างอิง: อสังหาฯ กลายเป็น "เฉลี่ยได้" ----------
-- พิสูจน์ว่า **ค่าในตารางอ้างอิงคือตัวที่แบกกฎ** ไม่ใช่ความบังเอิญของโค้ด
do $$
declare v_cost numeric; v_n int;
begin
  insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, currency)
  select '00000000-0000-0000-0000-00000004a009', 'CM-CONDO-C', 'คอนโด ห้อง 11/C',
         ct.class_id, ct.id, pg_temp.owner(), 'THB'
    from sri_os.asset_categories ct where ct.code = 'RE_RENTAL';
  perform pg_temp.open_asset('00000000-0000-0000-0000-00000004a009', 'opn.property', '1500',
                             3000000, 'ยอดยกมา คอนโด ห้อง 11/C ต้นทุน 3,000,000');

  -- ของจริง: ขาย 30% ถูกปฏิเสธ
  perform pg_temp.must_fail_like('M1 ก่อน mutation: ขาย 30%', format($q$
    select pg_temp.post(pg_temp.entry('inv.sell_re', '2026-11-01', '2026-11-01',
      'M1 ขายคอนโด C 30%% (ก่อน mutation)', %L,
      jsonb_build_array(
        pg_temp.ln('1100', 1050000, 0, null, 'investing', %L),
        pg_temp.ln('1500', 0, 900000, %L, 'investing'),
        pg_temp.ln('4300', 0, 150000, %L))))
    $q$, '00000000-0000-0000-0000-00000004a009', '00000000-0000-0000-0000-00000004b001',
         '00000000-0000-0000-0000-00000004a009', '00000000-0000-0000-0000-00000004a009'),
    'ต้องแยกชิ้นก่อน');

  -- mutation: เปลี่ยนค่าในตารางอ้างอิงค่าเดียว
  update sri_os.asset_categories set cost_basis_mode = 'average' where code = 'RE_RENTAL';

  perform pg_temp.post(pg_temp.entry('inv.sell_re', '2026-11-01', '2026-11-01',
    'M1 ขายคอนโด C 30% (หลัง mutation)', '00000000-0000-0000-0000-00000004a009',
    jsonb_build_array(
      pg_temp.ln('1100', 1050000, 0, null, 'investing', '00000000-0000-0000-0000-00000004b001'),
      pg_temp.ln('1500', 0, 900000, '00000000-0000-0000-0000-00000004a009', 'investing'),
      pg_temp.ln('4300', 0, 150000, '00000000-0000-0000-0000-00000004a009'))));

  v_cost := sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000004a009');
  if v_cost <> 2100000 then
    raise exception 'FAIL: M1 — หลังถอดกฎ การขาย 30%% ควรผ่านและเหลือต้นทุน 2,100,000 แต่ได้ % · ถ้าไม่ผ่าน แปลว่าเทสต์ไม่ได้วัดด่านตัวที่คิด',
      v_cost;
  end if;

  -- และล็อตที่สองของคอนโดก็ลงได้ (ทางที่เอาสองห้องมาเฉลี่ยกัน)
  insert into sri_os.asset_lots(asset_id, acquired_date, quantity, cost_thb, note)
  values ('00000000-0000-0000-0000-00000004a009', '2026-01-01', 1, 2100000, 'M1 ล็อตแรก');
  insert into sri_os.asset_lots(asset_id, acquired_date, quantity, cost_thb, note)
  values ('00000000-0000-0000-0000-00000004a009', '2026-02-01', 1, 5000000, 'M1 ล็อตที่สอง (ห้องอื่น)');
  select count(*) into v_n from sri_os.asset_lots
   where asset_id = '00000000-0000-0000-0000-00000004a009';
  if v_n <> 2 then
    raise exception 'FAIL: M1 — หลังถอดกฎ ควรสร้างล็อตที่สองได้ แต่ได้ % ล็อต', v_n;
  end if;

  raise notice 'ok M1 (MUTATION) · พลิก RE_RENTAL เป็น average ค่าเดียวในตารางอ้างอิง → ขายคอนโด 30%% ผ่าน (เหลือต้นทุน 2,100,000 ของห้องที่ขายไปแล้วบางส่วน) และสร้างล็อตที่สอง 5,000,000 ให้ห้องเดียวได้ → ต้นทุนเฉลี่ย (2,100,000+5,000,000)/2 = 3,550,000 ต่อ "ห้อง" ที่ไม่มีอยู่จริง';
  raise exception 'ROLLBACK_M1';
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  if sqlerrm <> 'ROLLBACK_M1' then raise; end if;
end $$;

-- บล็อก M1 ทิ้งสภาพไว้ (exception ใน plpgsql ย้อนเฉพาะคำสั่งในบล็อก
-- แต่เราใช้ raise เพื่อย้อนทั้งบล็อก) — ยืนยันว่าสภาพกลับมาแล้วจริง
do $$
begin
  if (select cost_basis_mode from sri_os.asset_categories where code = 'RE_RENTAL') <> 'whole_item' then
    raise exception 'FAIL: M1 — mutation ไม่ถูกย้อนกลับ RE_RENTAL ยังเป็น %',
      (select cost_basis_mode from sri_os.asset_categories where code = 'RE_RENTAL');
  end if;
  if exists (select 1 from sri_os.assets where code = 'CM-CONDO-C') then
    raise exception 'FAIL: M1 — ทรัพย์ทดสอบของ M1 ยังค้างอยู่ สภาพไม่ถูกย้อน';
  end if;
  raise notice 'ok M1b · สภาพหลัง mutation ถูกย้อนกลับครบ (RE_RENTAL = whole_item)';
end $$;

-- ---------- M2 · ถอด trigger ระดับสมุด ----------
do $$
declare v_cost numeric;
begin
  insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, currency)
  select '00000000-0000-0000-0000-00000004a00a', 'CM-CONDO-D', 'คอนโด ห้อง 11/D',
         ct.class_id, ct.id, pg_temp.owner(), 'THB'
    from sri_os.asset_categories ct where ct.code = 'RE_RENTAL';
  perform pg_temp.open_asset('00000000-0000-0000-0000-00000004a00a', 'opn.property', '1500',
                             3000000, 'ยอดยกมา คอนโด ห้อง 11/D ต้นทุน 3,000,000');

  drop trigger trg_assert_asset_whole_disposal on sri_os.transaction_lines;

  perform pg_temp.post(pg_temp.entry('inv.sell_re', '2026-11-02', '2026-11-02',
    'M2 ขายคอนโด D 30% หลังถอด trigger', '00000000-0000-0000-0000-00000004a00a',
    jsonb_build_array(
      pg_temp.ln('1100', 1050000, 0, null, 'investing', '00000000-0000-0000-0000-00000004b001'),
      pg_temp.ln('1500', 0, 900000, '00000000-0000-0000-0000-00000004a00a', 'investing'),
      pg_temp.ln('4300', 0, 150000, '00000000-0000-0000-0000-00000004a00a'))));

  v_cost := sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000004a00a');
  if v_cost <> 2100000 then
    raise exception 'FAIL: M2 — ถอด trg_assert_asset_whole_disposal แล้วการขาย 30%% ควรผ่าน (เหลือ 2,100,000) แต่ได้ % · ถ้ายังไม่ผ่าน แปลว่าเคส W3 เขียวเพราะด่านตัวอื่น ไม่ใช่ตัวนี้',
      v_cost;
  end if;

  raise notice 'ok M2 (MUTATION) · ถอด trg_assert_asset_whole_disposal → ขายคอนโด 30%% ผ่าน เหลือต้นทุน 2,100,000 ของห้องที่ "ขายไป 30%%" ซึ่งไม่มีอยู่จริงในโลก → W3 เขียวเพราะ trigger ตัวนี้จริง';
  raise exception 'ROLLBACK_M2';
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  if sqlerrm <> 'ROLLBACK_M2' then raise; end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.transaction_lines'::regclass
                    and g.tgname = 'trg_assert_asset_whole_disposal' and not g.tgisinternal) then
    raise exception 'FAIL: M2 — trigger ไม่กลับมาหลัง rollback';
  end if;
  raise notice 'ok M2b · trigger กลับมาครบหลัง rollback';
end $$;

-- ============================================================
-- Z · การกระทบยอด — ต้องว่างเปล่าสำหรับทรัพย์ที่ลงถูก
-- ============================================================
do $$
declare v text;
begin
  select string_agg(asset_code || ': ' || problem, ' · ') into v
    from sri_os.fn_asset_cost_basis_mode_mismatch()
   where asset_code like 'CM-%';
  if v is not null then
    raise exception 'FAIL: Z — ทรัพย์ทดสอบที่ลงถูกต้องไม่ควรติดรายงานกระทบยอด: %', v;
  end if;
  raise notice 'ok Z · รายงานกระทบยอดว่างเปล่าสำหรับทรัพย์ที่ลงถูกต้อง';
end $$;

rollback;
