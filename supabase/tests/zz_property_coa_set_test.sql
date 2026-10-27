-- ============================================================
-- SRI OS · **ชุดบัญชีอสังหาฯ แทนรหัสเดียว** (20261027041500_property_coa_set.sql)
--
-- ที่มา: 27/10 แยกอสังหาฯ เพื่อการลงทุนเป็นเพื่อการเช่า (1500) กับเพื่อการขาย (1520)
--   แต่ด่าน `fn_assert_line_coa_in_rules()` ตัดสินสิทธิ์ลงบรรทัด **1510 ค่ารีโนเวท**
--   จาก `cr_coa_code = '1500'` คือ **รหัสเดียว** → ขายของที่ย้ายไป 1520 แล้ว
--   ตัดค่ารีโนเวทในใบเดียวกันไม่ได้ = ต้นทุนค้างเป็นทรัพย์ผี + กำไรสูงกว่าจริง
--   (ช่องเดียวกับที่ 20261025000011 แก้ไว้ กลับมาอีกรอบในบัญชีตัวใหม่)
--
-- สิ่งที่ไฟล์นี้พิสูจน์ (ทุกข้อมีตัวเลขที่วัดได้ ไม่ใช่ "ไม่ error")
--   P0 · โครงสร้าง: fn_property_coas() มีจริง · immutable · ACL ปิด anon ·
--        ด่านอ่านจากฟังก์ชัน **ไม่ใช่เทียบรหัสเดียว** (ตัดคอมเมนต์ก่อนตรวจ)
--   P1 · ชุดไม่ว่าง · ทุกรหัสอยู่ในผังบัญชี · **ทุกรหัสมีหมวดจำหน่ายของตัวเอง**
--        (มีบัญชีแต่ขายไม่ได้ = เปิดครึ่งเดียว · บทเรียน mace-windu ข้อ 7)
--   P2 · **ขายคอนโดจากบัญชี 1520 พร้อมตัด 1510 → ผ่าน และกำไรถูก**
--        ต้นทุน 3,000,000 + รีโนเวท 500,000 · ขาย 4,000,000 → กำไร **500,000**
--        (ถ้าตัดแค่ 1520 จะโชว์ 1,000,000 = สูงกว่าจริงเท่าค่ารีโนเวท)
--        และ 1520 + 1510 กลับเป็นศูนย์ทั้งคู่ ไม่เหลือทรัพย์ผี
--   P3 · ขายจากบัญชี 1500 **ยังผ่านเหมือนเดิม** (เคสเดิมห้ามเสีย)
--   P4 · **หมวดที่ไม่ใช่อสังหาฯ ลง 1510 → ยังถูกปฏิเสธ** (ด่านต้องไม่หลวมลง)
--        และ 1510 **ไม่อยู่ในชุด** → ใบที่เครดิต 1510 ไม่ได้สิทธิ์เป็นวงกลม
--   P5 · MUTATION: พลิก fn_property_coas() กลับเป็นรหัสเดียว → P2 ต้องแดงทันที
--        (ถ้ายังเขียว แปลว่าเทสต์ P2 ไม่ได้วัดสิ่งที่คิดว่าวัด)
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ **rollback** ปิดท้าย — ไม่ทิ้งรายการเงินไว้
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
create temporary table p_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into p_uid(label) values ('mgmt');
insert into auth.users(id) select id from p_uid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, 'property-set@local', 'mgmt', 'management', true from p_uid u;
select set_config('test.uid', (select id::text from p_uid where label = 'mgmt'), true);

insert into sri_os.user_owner_access(user_id, owner_id)
select (select id from p_uid where label = 'mgmt'), o.id from sri_os.owners o;

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
values ('00000000-0000-0000-0000-0000000c5b01',
        (select id from sri_os.owners where code = 'THANAKORN'),
        'KBANK', 'ธนากร', 'ธนากร - KBANK (ชุดบัญชีอสังหาฯ)');

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

/** ลงยอดยกมาของทรัพย์ชิ้นหนึ่ง **ผูกทรัพย์** (เงื่อนไขที่ด่านล็อตบังคับ) */
create or replace function pg_temp.open_asset(p_asset uuid, p_type text, p_coa text,
                                              p_amount numeric, p_memo text) returns uuid
language sql as $fn$
  select pg_temp.post(pg_temp.entry(p_type, '2026-01-01', null, p_memo, p_asset,
    jsonb_build_array(
      pg_temp.ln(p_coa, p_amount, 0, p_asset, 'none'),
      pg_temp.ln('3300', 0, p_amount, null, 'none'))));
$fn$;

/** ตัดคอมเมนต์ออกจากตัวฟังก์ชันก่อนตรวจ — คอมเมนต์คือเอกสาร ไม่ใช่โค้ดที่รัน */
create or replace function pg_temp.code_of(p_fn text) returns text
language sql stable as $fn$
  select regexp_replace(
           regexp_replace(p.prosrc, '/\*.*?\*/', ' ', 'g'),
           '--[^' || chr(10) || ']*', ' ', 'g')
    from pg_proc p where p.oid = p_fn::regprocedure;
$fn$;

-- ทรัพย์ทดสอบ: คอนโดที่ย้ายไปบัญชีเพื่อการขายแล้ว + คอนโดที่ยังปล่อยเช่า + หุ้น
insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, currency)
select x.id, x.code, x.name, ct.class_id, ct.id, pg_temp.owner(), 'THB'
  from (values
    ('00000000-0000-0000-0000-0000000c5a01'::uuid, 'PS-CONDO-SALE',   'คอนโด ห้อง 20/S (ถือไว้ขาย)', 'RE_FOR_SALE'),
    ('00000000-0000-0000-0000-0000000c5a02'::uuid, 'PS-CONDO-RENT',   'คอนโด ห้อง 20/R (ปล่อยเช่า)', 'RE_RENTAL'),
    ('00000000-0000-0000-0000-0000000c5a03'::uuid, 'PS-STOCK',        'หุ้นในตลาด',                   'PAPER_STOCK_LISTED')
  ) as x(id, code, name, cat_code)
  join sri_os.asset_categories ct on ct.code = x.cat_code;

-- ============================================================
-- P0 · โครงสร้าง — ไล่จาก catalog จริง ไม่ใช่ไล่ไฟล์
-- ============================================================
do $$
declare v_src text; v_vol char;
begin
  if to_regprocedure('sri_os.fn_property_coas()') is null then
    raise exception 'FAIL: P0 — ไม่มี fn_property_coas() (migration ไม่ถูก apply?) เทสต์นี้จะไม่ได้ตรวจอะไร';
  end if;

  -- immutable: ชุดคงที่ ไม่ได้อ่านตาราง (แบบเดียวกับ fn_unrealised_equity_coas)
  select p.provolatile into v_vol from pg_proc p
   where p.oid = 'sri_os.fn_property_coas()'::regprocedure;
  if v_vol <> 'i' then
    raise exception 'FAIL: P0 — fn_property_coas() ต้องเป็น immutable (ได้ %)', v_vol;
  end if;

  -- anon ต้องเรียกไม่ได้ (รูปเดียวกับฟังก์ชันกฎตัวอื่น)
  if has_function_privilege('anon', 'sri_os.fn_property_coas()', 'execute') then
    raise exception 'FAIL: P0 — anon เรียก fn_property_coas() ได้';
  end if;

  -- ด่านต้องอ่านจากชุด **ไม่ใช่เทียบรหัสเดียว**
  v_src := pg_temp.code_of('sri_os.fn_assert_line_coa_in_rules()');
  if v_src not like '%fn_property_coas()%' then
    raise exception 'FAIL: P0 — ด่านไม่ได้อ่าน fn_property_coas() = กฎเดียวอยู่สองที่ (บทเรียนข้อ 5)';
  end if;
  if v_src ~ 'cr_coa_code\s*=\s*''1[0-9]{3}''' then
    raise exception 'FAIL: P0 — ด่านกลับไปเทียบรหัสบัญชีเดียวตรงๆ → บัญชีอสังหาฯ ตัวอื่นในชุดจะขายไม่ได้อีกรอบ';
  end if;

  raise notice 'ok P0 · fn_property_coas() มีจริง immutable ปิด anon · ด่านอ่านจากชุด';
end $$;

-- ============================================================
-- P1 · ชุดต้องสมเหตุสมผล และ **ทุกบัญชีในชุดต้องขายได้**
-- ============================================================
do $$
declare v_set text[]; v_code text; v_miss text := '';
begin
  v_set := sri_os.fn_property_coas();
  if v_set is null or cardinality(v_set) = 0 then
    raise exception 'FAIL: P1 — ชุดว่าง = ไม่มีใครลงบรรทัดค่ารีโนเวทได้เลย';
  end if;
  if not ('1500' = any (v_set) and '1520' = any (v_set)) then
    raise exception 'FAIL: P1 — ชุดต้องมีทั้ง 1500 (เพื่อการเช่า) และ 1520 (เพื่อการขาย) · ได้ %',
      array_to_string(v_set, ', ');
  end if;
  -- **1510 ห้ามอยู่ในชุด** — มันคือต้นทุนที่เกาะ ไม่ใช่ตัวบัญชีอสังหาฯ
  if '1510' = any (v_set) then
    raise exception 'FAIL: P1 — 1510 อยู่ในชุด → ใบที่เครดิต 1510 จะได้สิทธิ์ลง 1510 จากตัวเองเป็นวงกลม';
  end if;

  foreach v_code in array v_set loop
    if not exists (select 1 from sri_os.chart_of_accounts where code = v_code) then
      raise exception 'FAIL: P1 — รหัส % ในชุดไม่อยู่ในผังบัญชี', v_code;
    end if;
    if not exists (select 1 from sri_os.txn_types t
                    where t.cr_coa_code = v_code and t.requires_capital_gain) then
      v_miss := v_miss || v_code || ' ';
    end if;
  end loop;
  if v_miss <> '' then
    raise exception 'FAIL: P1 — บัญชีอสังหาฯ ที่ยังไม่มีหมวดจำหน่ายของตัวเอง: % → แยกบัญชีได้แต่ขายไม่ได้ (บทเรียนข้อ 7)', v_miss;
  end if;

  raise notice 'ok P1 · ชุด = % · ทุกบัญชีในชุดมีหมวดขายของตัวเอง', array_to_string(v_set, ', ');
end $$;

-- ============================================================
-- P2 · **ขายคอนโดจากบัญชี 1520 พร้อมตัดค่ารีโนเวท** → ผ่าน และกำไรถูก 500,000
-- ============================================================
do $$
declare v_cost numeric; v_gain numeric;
begin
  -- ยอดยกมาลงที่ 1500 + 1510 แล้วย้ายวัตถุประสงค์ไป 1520 (เส้นทางจริงของลูกพี่)
  perform pg_temp.open_asset('00000000-0000-0000-0000-0000000c5a01', 'opn.property', '1500',
                             3000000, 'P2 ยอดยกมา คอนโด 20/S ต้นทุน 3,000,000');
  perform pg_temp.open_asset('00000000-0000-0000-0000-0000000c5a01', 'opn.renovation', '1510',
                             500000, 'P2 ยอดยกมา ค่ารีโนเวทสะสม 20/S 500,000');

  perform pg_temp.must_pass('P2 ย้ายวัตถุประสงค์ไปเพื่อการขาย', format($q$
    select pg_temp.post(pg_temp.entry('adj.reclass_re_to_sale', '2026-11-01', null,
      'P2 ย้าย 20/S ไปบัญชีเพื่อการขาย ด้วยต้นทุนเดิม', %L,
      jsonb_build_array(
        pg_temp.ln('1520', 3000000, 0, %L, 'none'),
        pg_temp.ln('1500', 0, 3000000, %L, 'none'))))
    $q$, '00000000-0000-0000-0000-0000000c5a01',
         '00000000-0000-0000-0000-0000000c5a01', '00000000-0000-0000-0000-0000000c5a01'));

  -- ย้ายด้วยต้นทุนเดิม → ต้นทุนรวมไม่ขยับ และค่ารีโนเวทไม่ต้องย้ายตาม
  v_cost := sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-0000000c5a01');
  if v_cost <> 3500000 then
    raise exception 'FAIL: P2 — ย้ายวัตถุประสงค์แล้วต้นทุนต้องยังเป็น 3,500,000 แต่ได้ %', v_cost;
  end if;
  if pg_temp.book('00000000-0000-0000-0000-0000000c5a01', '1500') <> 0 then
    raise exception 'FAIL: P2 — ย้ายแล้วบัญชีเพื่อการเช่าต้องเหลือ 0 แต่ได้ %',
      pg_temp.book('00000000-0000-0000-0000-0000000c5a01', '1500');
  end if;

  -- **ตัดแค่ 1520 ไม่ตัด 1510 → ปฏิเสธ** (นี่คือรูปที่ทำให้กำไรสูงกว่าจริง)
  perform pg_temp.must_fail_like('P2 ขายแต่ไม่ตัดค่ารีโนเวท', format($q$
    select pg_temp.post(pg_temp.entry('inv.sell_re_held_for_sale', '2026-12-01', '2026-12-01',
      'P2 ขาย 20/S แต่ไม่ตัด 1510 (ผิด)', %L,
      jsonb_build_array(
        pg_temp.ln('1100', 4000000, 0, null, 'investing', %L),
        pg_temp.ln('1520', 0, 3000000, %L, 'investing'),
        pg_temp.ln('4300', 0, 1000000, %L))))
    $q$, '00000000-0000-0000-0000-0000000c5a01', '00000000-0000-0000-0000-0000000c5b01',
         '00000000-0000-0000-0000-0000000c5a01', '00000000-0000-0000-0000-0000000c5a01'),
    'ค่ารีโนเวท 1510');

  -- **ตัด 1520 + 1510 ในใบเดียว → ผ่าน** (ช่องที่ไฟล์นี้ปิด)
  perform pg_temp.must_pass('P2 ขายจากบัญชีเพื่อการขาย พร้อมตัดค่ารีโนเวท', format($q$
    select pg_temp.post(pg_temp.entry('inv.sell_re_held_for_sale', '2026-12-02', '2026-12-02',
      'P2 ขาย 20/S 4,000,000 · ตัด 1520 + 1510 ครบ', %L,
      jsonb_build_array(
        pg_temp.ln('1100', 4000000, 0, null, 'investing', %L),
        pg_temp.ln('1520', 0, 3000000, %L, 'investing'),
        pg_temp.ln('1510', 0,  500000, %L, 'investing'),
        pg_temp.ln('4300', 0,  500000, %L))))
    $q$, '00000000-0000-0000-0000-0000000c5a01', '00000000-0000-0000-0000-0000000c5b01',
         '00000000-0000-0000-0000-0000000c5a01', '00000000-0000-0000-0000-0000000c5a01',
         '00000000-0000-0000-0000-0000000c5a01'));

  if sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-0000000c5a01') <> 0 then
    raise exception 'FAIL: P2 — ขายแล้วต้นทุนต้องเป็น 0 แต่ได้ %',
      sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-0000000c5a01');
  end if;
  if pg_temp.book('00000000-0000-0000-0000-0000000c5a01', '1520') <> 0
     or pg_temp.book('00000000-0000-0000-0000-0000000c5a01', '1510') <> 0 then
    raise exception 'FAIL: P2 — 1520 (%) และ 1510 (%) ต้องกลับเป็นศูนย์ทั้งคู่ ไม่เหลือทรัพย์ผี',
      pg_temp.book('00000000-0000-0000-0000-0000000c5a01', '1520'),
      pg_temp.book('00000000-0000-0000-0000-0000000c5a01', '1510');
  end if;

  select coalesce(sum(l.credit - l.debit), 0) into v_gain
    from sri_os.transaction_lines l
    join sri_os.transactions t on t.id = l.transaction_id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where l.asset_id = '00000000-0000-0000-0000-0000000c5a01'
     and t.status = 'posted' and c.code = '4300';
  if v_gain <> 500000 then
    raise exception 'FAIL: P2 — กำไรต้องเป็น 500,000 (4,000,000 − 3,500,000) แต่ได้ % · ถ้าได้ 1,000,000 แปลว่าค่ารีโนเวทไม่ถูกตัด',
      v_gain;
  end if;

  raise notice 'ok P2 · ขายจากบัญชีเพื่อการขาย (1520) ตัด 1510 ได้ในใบเดียว → กำไร 500,000 ถูกต้อง ไม่เหลือทรัพย์ผี';
end $$;

-- ============================================================
-- P3 · ขายจากบัญชีเพื่อการเช่า (1500) **ยังผ่านเหมือนเดิม** — เคสเดิมห้ามเสีย
-- ============================================================
do $$
begin
  perform pg_temp.open_asset('00000000-0000-0000-0000-0000000c5a02', 'opn.property', '1500',
                             3000000, 'P3 ยอดยกมา คอนโด 20/R ต้นทุน 3,000,000');
  perform pg_temp.open_asset('00000000-0000-0000-0000-0000000c5a02', 'opn.renovation', '1510',
                             500000, 'P3 ยอดยกมา ค่ารีโนเวทสะสม 20/R 500,000');

  perform pg_temp.must_pass('P3 ขายจากบัญชีเพื่อการเช่า พร้อมตัดค่ารีโนเวท', format($q$
    select pg_temp.post(pg_temp.entry('inv.sell_re', '2026-12-03', '2026-12-03',
      'P3 ขาย 20/R 4,000,000 · ตัด 1500 + 1510 ครบ', %L,
      jsonb_build_array(
        pg_temp.ln('1100', 4000000, 0, null, 'investing', %L),
        pg_temp.ln('1500', 0, 3000000, %L, 'investing'),
        pg_temp.ln('1510', 0,  500000, %L, 'investing'),
        pg_temp.ln('4300', 0,  500000, %L))))
    $q$, '00000000-0000-0000-0000-0000000c5a02', '00000000-0000-0000-0000-0000000c5b01',
         '00000000-0000-0000-0000-0000000c5a02', '00000000-0000-0000-0000-0000000c5a02',
         '00000000-0000-0000-0000-0000000c5a02'));

  if sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-0000000c5a02') <> 0 then
    raise exception 'FAIL: P3 — เส้นทางเดิมเสีย: ขายแล้วต้นทุนต้องเป็น 0 แต่ได้ %',
      sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-0000000c5a02');
  end if;

  raise notice 'ok P3 · ขายจากบัญชีเพื่อการเช่า (1500) ยังผ่านเหมือนเดิม';
end $$;

-- ============================================================
-- P4 · **ด่านต้องไม่หลวมลง** — หมวดที่ไม่ใช่อสังหาฯ ลง 1510 ยังถูกปฏิเสธ
-- ============================================================
do $$
begin
  perform pg_temp.open_asset('00000000-0000-0000-0000-0000000c5a03', 'opn.securities', '1700',
                             1000000, 'P4 ยอดยกมา หุ้น 1,000,000');

  -- ขายหุ้นแล้วยัดบรรทัดค่ารีโนเวท → ต้องปฏิเสธ (1700 ไม่อยู่ในชุดอสังหาฯ)
  perform pg_temp.must_fail_like('P4 ขายหุ้นแล้วยัดบรรทัด 1510', format($q$
    select pg_temp.post(pg_temp.entry('inv.sell_securities', '2026-12-04', '2026-12-04',
      'P4 ขายหุ้น + 1510 (ผิด)', %L,
      jsonb_build_array(
        pg_temp.ln('1100', 1200000, 0, null, 'investing', %L),
        pg_temp.ln('1700', 0,  900000, %L, 'investing'),
        pg_temp.ln('1510', 0,  100000, %L, 'investing'),
        pg_temp.ln('4310', 0,  200000, %L))))
    $q$, '00000000-0000-0000-0000-0000000c5a03', '00000000-0000-0000-0000-0000000c5b01',
         '00000000-0000-0000-0000-0000000c5a03', '00000000-0000-0000-0000-0000000c5a03',
         '00000000-0000-0000-0000-0000000c5a03'),
    '1510');

  raise notice 'ok P4 · หมวดที่ไม่ใช่อสังหาฯ ลงบรรทัด 1510 ไม่ได้ — ด่านไม่หลวมลง';
end $$;

-- ============================================================
-- P5 · MUTATION — พลิกชุดกลับเป็นรหัสเดียว แล้ว **เคสของ 1520 ต้องแดงทันที**
--
--   ถ้ายังเขียว แปลว่า P2 ไม่ได้วัดสิ่งที่คิดว่าวัด (ด่านไม่ได้อ่านชุดจริง)
--   คืนค่าให้เหมือนเดิมท้ายบล็อก แล้ว rollback ปิดท้ายไฟล์อีกชั้น
-- ============================================================
do $$
declare v_ok boolean := false;
begin
  create or replace function sri_os.fn_property_coas() returns text[]
  language sql immutable set search_path = '' as $m$ select array['1500']; $m$;

  begin
    perform pg_temp.post(pg_temp.entry('inv.sell_re_held_for_sale', '2026-12-05', '2026-12-05',
      'P5 ขายจาก 1520 ตอนชุดเหลือรหัสเดียว (ต้องถูกปฏิเสธ)',
      '00000000-0000-0000-0000-0000000c5a01',
      jsonb_build_array(
        pg_temp.ln('1100', 1000000, 0, null, 'investing', '00000000-0000-0000-0000-0000000c5b01'),
        pg_temp.ln('1520', 0, 900000, '00000000-0000-0000-0000-0000000c5a01', 'investing'),
        pg_temp.ln('1510', 0, 100000, '00000000-0000-0000-0000-0000000c5a01', 'investing'))));
  exception when others then
    v_ok := true;
  end;

  -- คืนชุดให้เหมือน migration ก่อนออกจากบล็อก
  create or replace function sri_os.fn_property_coas() returns text[]
  language sql immutable set search_path = '' as $m$ select array['1500', '1520']; $m$;

  if not v_ok then
    raise exception 'FAIL: P5 — ถอด 1520 ออกจากชุดแล้วใบขายของ 1520 ยังลงบรรทัด 1510 ได้ → ด่านไม่ได้อ่านชุดจริง เทสต์ P2 วัดของผิด';
  end if;

  if not ('1520' = any (sri_os.fn_property_coas())) then
    raise exception 'FAIL: P5 — คืนชุดไม่สำเร็จ';
  end if;

  raise notice 'ok P5 · ถอด 1520 ออกจากชุด → ใบขายของ 1520 ลง 1510 ไม่ได้ทันที (ด่านอ่านชุดจริง)';
end $$;

rollback;
