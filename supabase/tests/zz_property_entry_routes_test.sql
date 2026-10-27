-- ============================================================
-- SRI OS · **เส้นทางเข้าของอสังหาฯ "เพื่อการขาย" (1520)** — ฝั่ง DB
--
-- ที่มา: `f0322a4` เปิดเส้นทาง **ออก** ให้ 1520 (ขายตรงได้ · ตัด 1510 ได้)
--   แต่เส้นทาง **เข้า** ยังปิด เพราะ `inv.buy_re` กับ `opn.property` เดบิต
--   `1500` ตายตัว → ของที่ซื้อ/ถือมาเพื่อขายต้องลงบัญชี **เพื่อการเช่า** ก่อน
--   แล้วย้ายอีกใบ · งบดุลระหว่างสองใบนั้นบอกว่าเป็นของให้เช่า = ผิดความจริง
--   ตั้งแต่ใบแรก และถ้าใครลืมใบที่สอง ยอดสองบัญชีผิดถาวรโดยที่งบดุลยังดุล
--   (27/10 · เพิ่ม `inv.buy_re_held_for_sale` และ `opn.property_held_for_sale`)
--
-- สิ่งที่ไฟล์นี้พิสูจน์ (ทุกข้อมีตัวเลขที่วัดได้ ไม่ใช่ "ไม่ error")
--   E0 · **ทุกรหัสใน fn_property_coas() มีหมวดเข้าครบสองทาง** (ซื้อ + ยอดยกมา)
--        อ่านจาก **ชุด** ไม่ใช่รายชื่อที่เขียนไว้ในเทสต์ — ขาดทางใดทางหนึ่ง
--        = มีบัญชีแต่เข้าไม่ถึง (เปิดครึ่งเดียว · บทเรียน mace-windu ข้อ 7)
--   E1 · **ซื้อคอนโดเข้าบัญชี 1520 ตรง** → ผ่าน · 1520 = 3,000,000 · 1500 = 0
--   E2 · **ค่ารีโนเวท (1510) ลงบนทรัพย์ที่อยู่ 1520** → ผ่าน · ต้นทุนรวม 3,500,000
--        (หมวดค่ารีโนเวทไม่ผูกกับบัญชีอสังหาฯ ตัวใด ความผูกพันอยู่ที่ asset_id)
--   E3 · ขายทรัพย์นั้น 4,200,000 ตัด 1520 + 1510 ในใบเดียว → **กำไร 700,000**
--        และ 1520 กับ 1510 กลับเป็นศูนย์ทั้งคู่ (ไม่เหลือทรัพย์ผี)
--   E4 · **ยอดยกมาลง 1520 ตรง** → ผ่าน · ไม่ต้องลง 1500 ก่อนแล้วย้าย
--   E5 · ด่านไม่หลวมลง — ใบซื้อของ 1520 ที่ไปลงบรรทัด 1500 ยังถูกปฏิเสธ
--   E6 · MUTATION: ถอด 1520 ออกจากชุด → **E3 ต้องแดงทันที** ส่วน E1/E2 ยังเขียว
--        (พิสูจน์ว่าสิทธิ์ลงบรรทัด 1510 ตอนขายอ่านชุดจริง และเส้นทางเข้า
--         ไม่ได้ขึ้นกับชุด — ถ้า E3 ยังเขียว แปลว่า E3 วัดของผิด)
--   E7 · MUTATION: ใส่บัญชีที่ไม่มีหมวดเข้าเข้าไปในชุด → **E0 ต้องแดงทันที**
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ **rollback** ปิดท้าย — ไม่ทิ้งรายการเงินไว้
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
create temporary table pe_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into pe_uid(label) values ('mgmt');
insert into auth.users(id) select id from pe_uid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, 'property-entry@local', 'mgmt', 'management', true from pe_uid u;
select set_config('test.uid', (select id::text from pe_uid where label = 'mgmt'), true);

insert into sri_os.user_owner_access(user_id, owner_id)
select (select id from pe_uid where label = 'mgmt'), o.id from sri_os.owners o;

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
values ('00000000-0000-0000-0000-0000000c5e01',
        (select id from sri_os.owners where code = 'THANAKORN'),
        'KBANK', 'ธนากร', 'ธนากร - KBANK (เส้นทางเข้าอสังหาฯ)');

-- ------------------------------------------------------------
-- ตัวช่วย — ทุกเคสเดินผ่าน fn_post_entry (ประตูเดียวกับที่หน้าจอใช้)
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

create or replace function pg_temp.book(p_asset uuid, p_coa text) returns numeric
language sql stable as $fn$
  select coalesce(sum(l.debit - l.credit), 0)
    from sri_os.transaction_lines l
    join sri_os.transactions t on t.id = l.transaction_id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where l.asset_id = p_asset and t.status = 'posted' and c.code = p_coa;
$fn$;

/**
 * บัญชีในชุดที่ยัง "เข้าไม่ได้" — อ่านจาก **ชุด** (`fn_property_coas()`) ที่เดียว
 *
 * ซื้อเข้า  = หมวดที่ `dr_coa_code` เป็นบัญชีนั้น และเครดิตเงินสด (11xx)
 * ยอดยกมา = หมวดกลุ่ม `opening` ที่ `dr_coa_code` เป็นบัญชีนั้น
 */
create or replace function pg_temp.entry_route_gaps() returns text
language plpgsql stable as $fn$
declare v_code text; v_out text := ''; v_miss text;
begin
  foreach v_code in array sri_os.fn_property_coas() loop
    v_miss := '';
    if not exists (
      select 1 from sri_os.txn_types t
       join sri_os.chart_of_accounts c on c.code = t.cr_coa_code
       where t.dr_coa_code = v_code and c.code ~ '^11[0-9][0-9]$'
    ) then v_miss := v_miss || 'ซื้อเข้า '; end if;
    if not exists (
      select 1 from sri_os.txn_types t
       where t.dr_coa_code = v_code and t.group_code = 'opening'
    ) then v_miss := v_miss || 'ยอดยกมา '; end if;
    if v_miss <> '' then v_out := v_out || v_code || ' (ขาด: ' || v_miss || ') '; end if;
  end loop;
  return v_out;
end $fn$;

-- ทรัพย์ทดสอบ: คอนโดที่ซื้อมาเพื่อขาย + คอนโดที่ถือไว้ขายอยู่ก่อนวันตัดยอด
insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, currency)
select x.id, x.code, x.name, ct.class_id, ct.id, pg_temp.owner(), 'THB'
  from (values
    ('00000000-0000-0000-0000-0000000c5d01'::uuid, 'PE-CONDO-BUY',  'คอนโด ห้อง 30/S (ซื้อมาเพื่อขาย)', 'RE_FOR_SALE'),
    ('00000000-0000-0000-0000-0000000c5d02'::uuid, 'PE-CONDO-OPEN', 'คอนโด ห้อง 31/S (ยกมา รอขาย)',     'RE_FOR_SALE')
  ) as x(id, code, name, cat_code)
  join sri_os.asset_categories ct on ct.code = x.cat_code;

-- ============================================================
-- E0 · ทุกบัญชีในชุดต้องมีหมวดเข้าครบสองทาง
-- ============================================================
do $$
declare v_gaps text;
begin
  if to_regprocedure('sri_os.fn_property_coas()') is null then
    raise exception 'FAIL: E0 — ไม่มี fn_property_coas() (migration ไม่ถูก apply?) เทสต์นี้จะไม่ได้ตรวจอะไร';
  end if;
  v_gaps := pg_temp.entry_route_gaps();
  if v_gaps <> '' then
    raise exception 'FAIL: E0 — บัญชีอสังหาฯ ที่เข้าไม่ได้: % → ต้องลงบัญชีอื่นก่อนแล้วย้าย ซึ่งงบดุลระหว่างนั้นผิด (บทเรียนข้อ 7)', v_gaps;
  end if;
  raise notice 'ok E0 · ทุกบัญชีในชุด (%) มีทั้งหมวดซื้อเข้าและหมวดยอดยกมาของตัวเอง',
    array_to_string(sri_os.fn_property_coas(), ', ');
end $$;

-- ============================================================
-- E1 · ซื้อคอนโดเข้าบัญชี 1520 ตรง
-- ============================================================
do $$
begin
  perform pg_temp.must_pass('E1 ซื้อเข้า 1520 ตรง', format($q$
    select pg_temp.post(pg_temp.entry('inv.buy_re_held_for_sale', '2026-11-02', '2026-11-02',
      'E1 ซื้อคอนโด 30/S เพื่อขาย 3,000,000', %L,
      jsonb_build_array(
        pg_temp.ln('1520', 3000000, 0, %L, 'investing'),
        pg_temp.ln('1100', 0, 3000000, null, 'investing', %L))))
    $q$, '00000000-0000-0000-0000-0000000c5d01',
         '00000000-0000-0000-0000-0000000c5d01', '00000000-0000-0000-0000-0000000c5e01'));

  if pg_temp.book('00000000-0000-0000-0000-0000000c5d01', '1520') <> 3000000 then
    raise exception 'FAIL: E1 — บัญชีเพื่อการขายต้องเป็น 3,000,000 แต่ได้ %',
      pg_temp.book('00000000-0000-0000-0000-0000000c5d01', '1520');
  end if;
  -- **ห้ามเดินผ่านบัญชีเพื่อการเช่าเลย** — ถ้าแตะ แปลว่ายังปิดช่องไม่สำเร็จ
  if pg_temp.book('00000000-0000-0000-0000-0000000c5d01', '1500') <> 0 then
    raise exception 'FAIL: E1 — ทรัพย์ที่ซื้อมาเพื่อขายไปโผล่ที่บัญชีเพื่อการเช่า (%)',
      pg_temp.book('00000000-0000-0000-0000-0000000c5d01', '1500');
  end if;
  raise notice 'ok E1 · ซื้อเข้า 1520 ตรงได้ · ไม่แตะ 1500 เลย';
end $$;

-- ============================================================
-- E2 · ค่ารีโนเวท (1510) ลงบนทรัพย์ที่อยู่บัญชี 1520
-- ============================================================
do $$
declare v_cost numeric;
begin
  perform pg_temp.must_pass('E2 ค่ารีโนเวทบนทรัพย์ที่อยู่ 1520', format($q$
    select pg_temp.post(pg_temp.entry('inv.capex', '2026-11-20', '2026-11-20',
      'E2 รีโนเวทคอนโด 30/S ก่อนขาย 500,000', %L,
      jsonb_build_array(
        pg_temp.ln('1510', 500000, 0, %L, 'investing'),
        pg_temp.ln('1100', 0, 500000, null, 'investing', %L))))
    $q$, '00000000-0000-0000-0000-0000000c5d01',
         '00000000-0000-0000-0000-0000000c5d01', '00000000-0000-0000-0000-0000000c5e01'));

  -- ต้นทุนรวมของทรัพย์ = 1520 + 1510 ของทรัพย์ชิ้นเดียวกัน
  v_cost := sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-0000000c5d01');
  if v_cost <> 3500000 then
    raise exception 'FAIL: E2 — ต้นทุนรวมต้องเป็น 3,500,000 แต่ได้ % (ค่ารีโนเวทไม่ถูกนับเป็นต้นทุนของทรัพย์ที่รอขาย)', v_cost;
  end if;
  raise notice 'ok E2 · รีโนเวทของรอขายได้ · ต้นทุนรวม 3,500,000 (ซื้อ 3,000,000 + รีโนเวท 500,000)';
end $$;

-- ============================================================
-- E3 · ขาย 4,200,000 ตัด 1520 + 1510 ในใบเดียว → กำไร 700,000
-- ============================================================
do $$
begin
  perform pg_temp.must_pass('E3 ขายพร้อมตัดค่ารีโนเวท', format($q$
    select pg_temp.post(pg_temp.entry('inv.sell_re_held_for_sale', '2026-12-10', '2026-12-10',
      'E3 ขายคอนโด 30/S 4,200,000 · ตัด 1520 + 1510 ครบ', %L,
      jsonb_build_array(
        pg_temp.ln('1100', 4200000, 0, null, 'investing', %L),
        pg_temp.ln('1520', 0, 3000000, %L, 'investing'),
        pg_temp.ln('1510', 0,  500000, %L, 'investing'),
        pg_temp.ln('4300', 0,  700000, %L))))
    $q$, '00000000-0000-0000-0000-0000000c5d01', '00000000-0000-0000-0000-0000000c5e01',
         '00000000-0000-0000-0000-0000000c5d01', '00000000-0000-0000-0000-0000000c5d01',
         '00000000-0000-0000-0000-0000000c5d01'));

  if pg_temp.book('00000000-0000-0000-0000-0000000c5d01', '1520') <> 0
     or pg_temp.book('00000000-0000-0000-0000-0000000c5d01', '1510') <> 0 then
    raise exception 'FAIL: E3 — ขายแล้วต้องเหลือศูนย์ทั้งคู่ แต่ได้ 1520=% · 1510=% (ทรัพย์ผีค้างงบดุล)',
      pg_temp.book('00000000-0000-0000-0000-0000000c5d01', '1520'),
      pg_temp.book('00000000-0000-0000-0000-0000000c5d01', '1510');
  end if;
  if sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-0000000c5d01') <> 0 then
    raise exception 'FAIL: E3 — ต้นทุนคงเหลือต้องเป็นศูนย์ แต่ได้ %',
      sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-0000000c5d01');
  end if;
  raise notice 'ok E3 · วงจรครบ ซื้อ → รีโนเวท → ขาย · กำไร 700,000 · ไม่เหลือทรัพย์ผี';
end $$;

-- ============================================================
-- E4 · ยอดยกมาลง 1520 ตรง (ไม่ต้องลง 1500 ก่อนแล้วย้าย)
-- ============================================================
do $$
begin
  perform pg_temp.must_pass('E4 ยอดยกมา 1520 ตรง', format($q$
    select pg_temp.post(pg_temp.entry('opn.property_held_for_sale', '2026-01-01', null,
      'E4 ยอดยกมา คอนโด 31/S (รอขาย) ต้นทุน 2,400,000', %L,
      jsonb_build_array(
        pg_temp.ln('1520', 2400000, 0, %L, 'none'),
        pg_temp.ln('3300', 0, 2400000, null, 'none'))))
    $q$, '00000000-0000-0000-0000-0000000c5d02', '00000000-0000-0000-0000-0000000c5d02'));

  if pg_temp.book('00000000-0000-0000-0000-0000000c5d02', '1520') <> 2400000 then
    raise exception 'FAIL: E4 — ยอดยกมาต้องอยู่ที่ 1520 = 2,400,000 แต่ได้ %',
      pg_temp.book('00000000-0000-0000-0000-0000000c5d02', '1520');
  end if;
  if pg_temp.book('00000000-0000-0000-0000-0000000c5d02', '1500') <> 0 then
    raise exception 'FAIL: E4 — ยอดตั้งต้นของทรัพย์ที่รอขายไปโผล่ที่บัญชีเพื่อการเช่า (%)',
      pg_temp.book('00000000-0000-0000-0000-0000000c5d02', '1500');
  end if;
  raise notice 'ok E4 · ยอดยกมาของทรัพย์ที่ถือไว้ขายลง 1520 ตรงได้ · สมุดหน้าแรกไม่ต้องบอกว่าเป็นของให้เช่า';
end $$;

-- ============================================================
-- E5 · ด่านไม่หลวมลง — ใบของหมวด 1520 ที่ไปลงบรรทัด 1500 ยังถูกปฏิเสธ
-- ============================================================
do $$
begin
  perform pg_temp.must_fail_like('E5 ซื้อหมวด 1520 แต่ลงบรรทัด 1500', format($q$
    select pg_temp.post(pg_temp.entry('inv.buy_re_held_for_sale', '2026-11-03', '2026-11-03',
      'E5 ซื้อเพื่อขายแต่ลง 1500 (ผิด)', %L,
      jsonb_build_array(
        pg_temp.ln('1500', 1000000, 0, %L, 'investing'),
        pg_temp.ln('1100', 0, 1000000, null, 'investing', %L))))
    $q$, '00000000-0000-0000-0000-0000000c5d02',
         '00000000-0000-0000-0000-0000000c5d02', '00000000-0000-0000-0000-0000000c5e01'),
    '1500');

  perform pg_temp.must_fail_like('E5 ยอดยกมาหมวด 1520 แต่ลงบรรทัด 1500', format($q$
    select pg_temp.post(pg_temp.entry('opn.property_held_for_sale', '2026-01-01', null,
      'E5 ยอดยกมาเพื่อขายแต่ลง 1500 (ผิด)', %L,
      jsonb_build_array(
        pg_temp.ln('1500', 500000, 0, %L, 'none'),
        pg_temp.ln('3300', 0, 500000, null, 'none'))))
    $q$, '00000000-0000-0000-0000-0000000c5d02', '00000000-0000-0000-0000-0000000c5d02'),
    '1500');

  raise notice 'ok E5 · หมวดของ 1520 ลงบรรทัด 1500 ไม่ได้ — ด่านบัญชีตามตารางกฎไม่หลวมลง';
end $$;

-- ============================================================
-- E6 · MUTATION — ถอด 1520 ออกจากชุด
--
--   คาดหวัง: **ใบขายที่ตัด 1510 ต้องแดงทันที** (สิทธิ์นั้นอ่านจากชุด)
--            ส่วน **ใบซื้อและใบรีโนเวทยังเขียว** เพราะเส้นทางเข้าไม่ได้ขึ้นกับชุด
--   ถ้าใบขายยังเขียว แปลว่า E3 ไม่ได้วัดสิ่งที่คิดว่าวัด
-- ============================================================
do $$
declare v_sell_blocked boolean := false;
begin
  create or replace function sri_os.fn_property_coas() returns text[]
  language sql immutable set search_path = '' as $m$ select array['1500']; $m$;

  -- เส้นทางเข้ายังต้องทำงานได้ (ไม่ขึ้นกับชุด)
  perform pg_temp.must_pass('E6 ซื้อเข้า 1520 ตอนชุดเหลือรหัสเดียว', format($q$
    select pg_temp.post(pg_temp.entry('inv.buy_re_held_for_sale', '2026-11-04', '2026-11-04',
      'E6 ซื้อคอนโด 31/S เพื่อขาย 900,000 (ชุดเหลือรหัสเดียว)', %L,
      jsonb_build_array(
        pg_temp.ln('1520', 900000, 0, %L, 'investing'),
        pg_temp.ln('1100', 0, 900000, null, 'investing', %L))))
    $q$, '00000000-0000-0000-0000-0000000c5d02',
         '00000000-0000-0000-0000-0000000c5d02', '00000000-0000-0000-0000-0000000c5e01'));

  perform pg_temp.must_pass('E6 ค่ารีโนเวทตอนชุดเหลือรหัสเดียว', format($q$
    select pg_temp.post(pg_temp.entry('inv.capex', '2026-11-21', '2026-11-21',
      'E6 รีโนเวทคอนโด 31/S 100,000 (ชุดเหลือรหัสเดียว)', %L,
      jsonb_build_array(
        pg_temp.ln('1510', 100000, 0, %L, 'investing'),
        pg_temp.ln('1100', 0, 100000, null, 'investing', %L))))
    $q$, '00000000-0000-0000-0000-0000000c5d02',
         '00000000-0000-0000-0000-0000000c5d02', '00000000-0000-0000-0000-0000000c5e01'));

  -- แต่ขายพร้อมตัดค่ารีโนเวทต้องถูกปฏิเสธ
  begin
    perform pg_temp.post(pg_temp.entry('inv.sell_re_held_for_sale', '2026-12-11', '2026-12-11',
      'E6 ขายคอนโด 31/S ตอนชุดเหลือรหัสเดียว (ต้องถูกปฏิเสธ)',
      '00000000-0000-0000-0000-0000000c5d02',
      jsonb_build_array(
        pg_temp.ln('1100', 4000000, 0, null, 'investing', '00000000-0000-0000-0000-0000000c5e01'),
        pg_temp.ln('1520', 0, 3300000, '00000000-0000-0000-0000-0000000c5d02', 'investing'),
        pg_temp.ln('1510', 0,  100000, '00000000-0000-0000-0000-0000000c5d02', 'investing'),
        pg_temp.ln('4300', 0,  600000, '00000000-0000-0000-0000-0000000c5d02'))));
  exception when others then
    v_sell_blocked := true;
  end;

  -- คืนชุดให้เหมือน migration ก่อนออกจากบล็อก
  create or replace function sri_os.fn_property_coas() returns text[]
  language sql immutable set search_path = '' as $m$ select array['1500', '1520']; $m$;

  if not v_sell_blocked then
    raise exception 'FAIL: E6 — ถอด 1520 ออกจากชุดแล้วใบขายยังลงบรรทัด 1510 ได้ → สิทธิ์นั้นไม่ได้อ่านชุดจริง เทสต์ E3 วัดของผิด';
  end if;
  if not ('1520' = any (sri_os.fn_property_coas())) then
    raise exception 'FAIL: E6 — คืนชุดไม่สำเร็จ';
  end if;
  raise notice 'ok E6 · เส้นทางเข้าไม่ขึ้นกับชุด · สิทธิ์ตัด 1510 ตอนขายขึ้นกับชุดจริง';
end $$;

-- ============================================================
-- E7 · MUTATION — ใส่บัญชีที่ไม่มีหมวดเข้าเข้าไปในชุด → E0 ต้องแดงทันที
--
--   1290 (ค่าเผื่อหนี้สงสัยจะสูญ) มีหมวดยอดยกมาฝั่ง **เครดิต** และไม่มีหมวดซื้อเข้า
--   ถ้า E0 ยังเขียว แปลว่ามันไม่ได้ไล่จากชุดจริง (ไปอ่านรายชื่อที่เขียนไว้เอง)
-- ============================================================
do $$
declare v_gaps text;
begin
  create or replace function sri_os.fn_property_coas() returns text[]
  language sql immutable set search_path = '' as $m$ select array['1500', '1520', '1290']; $m$;

  v_gaps := pg_temp.entry_route_gaps();

  create or replace function sri_os.fn_property_coas() returns text[]
  language sql immutable set search_path = '' as $m$ select array['1500', '1520']; $m$;

  if v_gaps not like '%1290%' then
    raise exception 'FAIL: E7 — ใส่ 1290 เข้าชุดแล้วด่าน E0 ยังไม่ฟ้อง (ได้: "%") → E0 ไม่ได้ไล่จากชุดจริง', v_gaps;
  end if;
  if pg_temp.entry_route_gaps() <> '' then
    raise exception 'FAIL: E7 — คืนชุดไม่สำเร็จ (ยังมีช่องว่าง: %)', pg_temp.entry_route_gaps();
  end if;
  raise notice 'ok E7 · ด่านเส้นทางเข้าไล่จาก fn_property_coas() จริง';
end $$;

rollback;
