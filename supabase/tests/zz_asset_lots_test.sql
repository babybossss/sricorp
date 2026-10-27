-- ============================================================
-- SRI OS · **ทะเบียนล็อตรายตัว** (20261025000008_asset_lots.sql)
--
-- ก่อนไฟล์นั้น: ไม่มีที่เก็บล็อตเลย → นำเข้าพอร์ตรายล็อตไม่ได้ และต้นทุนถัวเฉลี่ย
-- มาจาก "ล็อตที่ผู้เรียกส่งเข้ามา" เท่านั้น (ค่าที่ผู้เรียกเลือกได้ · D-115 ห้าม)
--
-- สิ่งที่ไฟล์นี้พิสูจน์:
--   L1 · ล็อตสกุลต่างประเทศ → **ต้นทุนบาทถูกตามอัตราวันซื้อ** · ไม่มีอัตรา → ปฏิเสธ
--   L2 · **ต้นทุนถัวเฉลี่ยคำนวณจากทะเบียน ไม่ใช่จากค่าที่ส่งเข้ามา**
--        (ส่งค่าผิดเข้ามา → ถูกปฏิเสธ ไม่ใช่ถูกใช้)
--   L3 · ขายหมด → ต้นทุนในทะเบียนเหลือ 0 พอดี · ขายเกินจำนวนที่ถือไม่ได้
--   L4 · `assets.units` **ไม่ใช่แหล่งความจริง** — แก้มือแล้วจำนวนคงเหลือไม่เปลี่ยน
--   L5 · append-only — แก้/ลบล็อตไม่ได้ทั้ง RLS และ trigger
--   L6 · **MUTATION** — ถอดด่านถัวเฉลี่ยออก แล้ววัดว่ากำไรเพี้ยนเท่าไร
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
create temporary table l_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into l_uid(label) values ('mgmt');
insert into auth.users(id) select id from l_uid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, 'lots@local', 'mgmt', 'management', true from l_uid u;
select set_config('test.uid', (select id::text from l_uid where label = 'mgmt'), true);

insert into sri_os.user_owner_access(user_id, owner_id)
select (select id from l_uid where label = 'mgmt'), o.id from sri_os.owners o;

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
values ('00000000-0000-0000-0000-0000000ab001',
        (select id from sri_os.owners where code = 'THANAKORN'), 'SCB', 'ธนากร', 'ธนากร - SCB (ล็อต)');

insert into sri_os.contacts(id, first_name, types)
values ('00000000-0000-0000-0000-0000000ac001', 'โบรกเกอร์ (ล็อต)', array['other']);

-- อัตราสามวัน: วันซื้อล็อตแรก 35.00 · ล็อตสอง 37.00 · วันขาย 38.00
insert into sri_os.fx_rates(currency, rate_date, thb_per_unit, source, note)
values ('USD', '2026-02-02', 35.0, 'manual', 'วันซื้อล็อตแรก'),
       ('USD', '2026-03-02', 37.0, 'manual', 'วันซื้อล็อตสอง'),
       ('USD', '2026-04-01', 38.0, 'manual', 'วันขาย')
on conflict (currency, rate_date) do nothing;

-- ทรัพย์สองชิ้น: หุ้นต่างประเทศ (USD) และทองคำ (บาท)
insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, currency)
select '00000000-0000-0000-0000-0000000aa001', 'LOT-AAPL', 'หุ้น AAPL (ล็อต)',
       cat.class_id, cat.id, (select id from sri_os.owners where code = 'THANAKORN'), 'USD'
  -- **หมวดต้องระบุชัด** — ตั้งแต่ 20261025000010 หมวดเป็นตัวตัดสินว่าเฉลี่ยได้หรือไม่
  -- AAPL = หุ้นในตลาดหลักทรัพย์ → เส้นทางถัวเฉลี่ยของ D-112 ยังใช้ได้เหมือนเดิม
  from (select id, class_id from sri_os.asset_categories
         where code = 'PAPER_STOCK_LISTED') cat;

insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, currency)
select '00000000-0000-0000-0000-0000000aa002', 'LOT-GOLD', 'ทองคำแท่ง (ล็อต)',
       cat.class_id, cat.id, (select id from sri_os.owners where code = 'THANAKORN'), 'THB'
  -- ทองคำ — ลูกพี่ยืนยันว่าเฉลี่ยได้ (หนึ่งในสามอย่าง)
  from (select id, class_id from sri_os.asset_categories where code = 'COM_GOLD') cat;

create or replace function pg_temp.own(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.owners where code = p_code $fn$;

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

/** ลงยอดยกมาของทรัพย์ชิ้นหนึ่ง **ผูกทรัพย์** (เงื่อนไขที่ด่านล็อตบังคับ) */
create or replace function pg_temp.open_asset(p_asset uuid, p_code text, p_amount numeric,
                                              p_memo text) returns uuid
language plpgsql as $fn$
declare v jsonb;
begin
  v := sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code', p_code,
    'doc_date', '2026-01-01',
    'memo', p_memo,
    'asset_id', p_asset,
    'attachments', jsonb_build_array('ยอดตั้งต้น.pdf'),
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', pg_temp.own('THANAKORN'),
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code', case when p_code = 'opn.securities' then '1700' else '1720' end,
                           'debit', p_amount, 'credit', 0, 'cf_category', 'none',
                           'asset_id', p_asset),
        jsonb_build_object('coa_code', '3300', 'debit', 0, 'credit', p_amount,
                           'cf_category', 'none'))))));
  return ((v -> 'transaction_ids') ->> 0)::uuid;
end $fn$;

/**
 * ใบขายหลักทรัพย์/ทองคำ — ตัดทรัพย์ตามต้นทุน + รับรู้กำไร/ขาดทุน
 *
 * **หมวดกับบัญชีที่ตัดต้องเป็นของทรัพย์ชิ้นนั้นจริง** (`p_type`/`p_coa`)
 * เดิมฟังก์ชันนี้เครดิต `1700` ตายตัวและใช้หมวด `inv.sell_securities` กับ
 * **ทองคำ (1720)** ใน L6 ด้วย → ยอดรายบัญชีของทรัพย์นั้นกลายเป็น
 * 1700 = −50,000 / 1720 = +400,000 ทั้งที่ **ต้นทุนรวมหักกันแล้วยังถูก**
 * (350,000) จึงไม่มีด่านตัวใดฟ้อง — ฉากเดียวกับช่องของใบย้ายวัตถุประสงค์
 * ที่ `fn_assert_asset_account_balance_nonneg` (20261027161500) ปิด
 * ด่านนั้นจับ fixture ตัวนี้ได้ จึงแก้ให้ขายออกจากบัญชีของทรัพย์เอง
 */
create or replace function pg_temp.sell(p_asset uuid, p_cost numeric, p_proceeds numeric,
                                        p_memo text, p_date date default '2026-04-01',
                                        p_type text default 'inv.sell_securities',
                                        p_coa text default '1700') returns uuid
language plpgsql as $fn$
declare v jsonb; v_gain numeric := round(p_proceeds - p_cost, 2); v_lines jsonb;
begin
  v_lines := jsonb_build_array(
    jsonb_build_object('coa_code', '1100', 'bank_account_id', '00000000-0000-0000-0000-0000000ab001',
                       'debit', p_proceeds, 'credit', 0, 'cf_category', 'investing'),
    jsonb_build_object('coa_code', p_coa, 'debit', 0, 'credit', p_cost,
                       'cf_category', 'investing', 'asset_id', p_asset));
  if v_gain > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'coa_code', '4900', 'debit', 0, 'credit', v_gain, 'cf_category', 'investing',
      'asset_id', p_asset));
  elsif v_gain < 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'coa_code', '5910', 'debit', -v_gain, 'credit', 0, 'cf_category', 'investing',
      'asset_id', p_asset));
  end if;

  v := sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code', p_type,
    'doc_date', p_date::text,
    'cash_date', p_date::text,
    'memo', p_memo,
    'asset_id', p_asset,
    'contact_id', '00000000-0000-0000-0000-0000000ac001',
    'attachments', jsonb_build_array('ใบขาย.pdf'),
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', pg_temp.own('THANAKORN'), 'lines', v_lines))));
  return ((v -> 'transaction_ids') ->> 0)::uuid;
end $fn$;


/**
 * บันทึกการตัดล็อต **แล้วบังคับให้ด่านที่เลื่อนไว้ยิงทันที**
 *
 * `trg_lot_consumption_sane` เป็น constraint trigger แบบ deferred (ต้องเห็นทุกแถว
 * ของใบก่อนตัดสิน) → ถ้าเทสต์แค่ INSERT เฉยๆ มันจะยิงตอน commit ซึ่ง **ไม่เกิดขึ้น
 * ในเทสต์ที่ rollback ทิ้ง** แล้วเคส "ต้องถูกปฏิเสธ" จะเขียวด้วยเหตุผลผิด
 * (เจอจริงตอนรันครั้งแรก: ส่งต้นทุน 5,000 แล้วผ่าน)
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

-- ============================================================
-- L0 · โครงสร้าง — ไล่จาก catalog จริง ไม่ใช่ไล่ไฟล์
-- ============================================================
do $$
declare v text;
begin
  if to_regclass('sri_os.asset_lots') is null or to_regclass('sri_os.asset_lot_consumptions') is null then
    raise exception 'FAIL: L0 — ยังไม่มีตารางล็อต (migration ไม่ถูก apply?) เทสต์นี้จะไม่ได้ตรวจอะไร';
  end if;
  /**
   * append-only: **ห้ามมี policy DELETE เลย** และ policy UPDATE มีได้ตัวเดียว
   * คือ `lots_mark_reversed` (20261025000012) ซึ่งเปิดทางเดียวให้ติดร่องรอย
   * การกลับรายการ — ก่อนมีมันนั้น `update asset_lots` ของ `fn_reimport_opening`
   * ได้ **0 แถวเงียบๆ** แล้วล็อตเดิมไม่ถูกปิด = ต้นทุนสองชุด
   * (ตารางการขายออกยังต้องไม่มีทั้ง UPDATE และ DELETE)
   */
  select string_agg(p.polname || '/' || p.polcmd::text, ', ') into v
    from pg_policy p
   where p.polrelid in ('sri_os.asset_lots'::regclass, 'sri_os.asset_lot_consumptions'::regclass)
     and p.polcmd in ('w', 'd')
     and not (p.polrelid = 'sri_os.asset_lots'::regclass
              and p.polcmd = 'w' and p.polname = 'lots_mark_reversed');
  if v is not null then
    raise exception 'FAIL: L0 — มี policy UPDATE/DELETE ของตารางล็อตที่ไม่ได้ตัดสินใจไว้: %', v;
  end if;
  -- ฟังก์ชันคำนวณต้องเรียกตรงไม่ได้ (D-089)
  select string_agg(x.f, ', ') into v
    from unnest(array['sri_os.fn_asset_units(uuid)', 'sri_os.fn_asset_average_unit_cost(uuid)']) x(f)
   where has_function_privilege('authenticated', x.f, 'execute');
  if v is not null then
    raise exception 'FAIL: L0 — ฟังก์ชันของทะเบียนล็อตเรียกตรงได้: %', v;
  end if;
  raise notice 'ok L0 · ตารางล็อตมีจริง · append-only ที่ชั้น RLS · ฟังก์ชันคำนวณเรียกตรงไม่ได้';
end $$;

-- ============================================================
-- L1 · ล็อตสกุลต่างประเทศ — ต้นทุนบาทมาจาก **อัตราวันซื้อ** · ไม่มีอัตรา → ปฏิเสธ
--
--   ล็อต 1: 100 หุ้น × 10 USD = 1,000 USD @35.00 = **35,000 บาท**
--   ล็อต 2: 100 หุ้น × 10 USD = 1,000 USD @37.00 = **37,000 บาท**
--   → รวม 200 หุ้น · ต้นทุน 72,000 บาท · ถัวเฉลี่ย **360 บาท/หุ้น**
-- ============================================================
do $$
declare v_asset uuid := '00000000-0000-0000-0000-0000000aa001';
begin
  -- (ก) ไม่ส่งอัตราเลย → ปฏิเสธ (ห้ามเดาเป็น 1 แล้วนับ USD เป็นบาท)
  perform pg_temp.must_fail_like('L1 ล็อต USD ไม่ส่งอัตรา', format($q$
    insert into sri_os.asset_lots(asset_id, acquired_date, quantity, cost_thb)
    values (%L, '2026-02-02', 100, 35000) $q$, v_asset),
    'ต้องระบุสกุลเงิน');

  -- (ข) ส่งอัตราที่ไม่ตรงกับตารางอัตราของวันนั้น → ปฏิเสธ
  perform pg_temp.must_fail_like('L1 อัตราไม่ตรงตารางอัตรา', format($q$
    insert into sri_os.asset_lots(asset_id, acquired_date, quantity, cost_thb,
                                  currency, amount_original, fx_rate, fx_rate_date)
    values (%L, '2026-02-02', 100, 36000, 'USD', 1000, 36.0, '2026-02-02') $q$, v_asset),
    'ไม่เท่ากับอัตราในตารางอัตราแลกเปลี่ยน');

  -- (ค) ต้นทุนบาทไม่เท่ากับ ยอดสกุลเดิม × อัตรา → ปฏิเสธ (check constraint)
  perform pg_temp.must_fail_like('L1 ต้นทุนบาทไม่ตรงกับอัตรา', format($q$
    insert into sri_os.asset_lots(asset_id, acquired_date, quantity, cost_thb,
                                  currency, amount_original, fx_rate, fx_rate_date)
    values (%L, '2026-02-02', 100, 35000.01, 'USD', 1000, 35.0, '2026-02-02') $q$, v_asset),
    'asset_lots_cost_from_rate');

  -- (ง) สกุลไม่ตรงกับสกุลของทรัพย์ → ปฏิเสธ (ความจริงอยู่ที่ assets.currency)
  perform pg_temp.must_fail_like('L1 สกุลล็อตไม่ตรงกับสกุลของทรัพย์', format($q$
    insert into sri_os.asset_lots(asset_id, acquired_date, quantity, cost_thb,
                                  currency, amount_original, fx_rate, fx_rate_date)
    values (%L, '2026-02-02', 100, 35000, 'THB', 35000, 1, '2026-02-02') $q$, v_asset),
    'สกุลของล็อตต้องเป็นสกุลของทรัพย์');

  -- (จ) ของที่ถูกต้องสองล็อต
  perform pg_temp.must_pass('L1 ล็อตแรก 100 หุ้น @35.00', format($q$
    insert into sri_os.asset_lots(asset_id, acquired_date, quantity, cost_thb,
                                  currency, amount_original, fx_rate, fx_rate_date, note)
    values (%L, '2026-02-02', 100, 35000, 'USD', 1000, 35.0, '2026-02-02', 'L1 ล็อตแรก') $q$, v_asset));
  perform pg_temp.must_pass('L1 ล็อตสอง 100 หุ้น @37.00', format($q$
    insert into sri_os.asset_lots(asset_id, acquired_date, quantity, cost_thb,
                                  currency, amount_original, fx_rate, fx_rate_date, note)
    values (%L, '2026-03-02', 100, 37000, 'USD', 1000, 37.0, '2026-03-02', 'L1 ล็อตสอง') $q$, v_asset));

  if sri_os.fn_asset_units(v_asset) <> 200 then
    raise exception 'FAIL: L1 — จำนวนคงเหลือควรเป็น 200 หุ้น แต่ได้ %', sri_os.fn_asset_units(v_asset);
  end if;
  if sri_os.fn_asset_lot_cost(v_asset) <> 72000 then
    raise exception 'FAIL: L1 — ต้นทุนรวมควรเป็น 72,000 บาท (35,000 + 37,000) แต่ได้ %',
      sri_os.fn_asset_lot_cost(v_asset);
  end if;
  if round(sri_os.fn_asset_average_unit_cost(v_asset), 2) <> 360 then
    raise exception 'FAIL: L1 — ต้นทุนถัวเฉลี่ยควรเป็น 360 บาท/หุ้น แต่ได้ %',
      sri_os.fn_asset_average_unit_cost(v_asset);
  end if;

  raise notice 'ok L1 · ล็อต USD สองล็อต (1,000 USD @35 = 35,000 · 1,000 USD @37 = 37,000) → 200 หุ้น · ต้นทุน 72,000 · ถัวเฉลี่ย 360 บาท/หุ้น · ไม่มีอัตรา/อัตราไม่ตรงตาราง/สกุลผิด → ปฏิเสธทั้งหมด';
end $$;

-- ============================================================
-- L2 · **ต้นทุนถัวเฉลี่ยคำนวณจากทะเบียน ไม่ใช่จากค่าที่ส่งเข้ามา**
--
--   ยอดยกมาในสมุด 72,000 (ผูกทรัพย์) → ขาย 50 หุ้น
--   ต้นทุนที่ต้องตัด = 72,000 × 50/200 = **18,000 บาท**
--   ส่งค่าผิด (เช่น 5,000 หรือ 30,000) → **ปฏิเสธ** ไม่ใช่ถูกใช้
-- ============================================================
do $$
declare
  v_asset uuid := '00000000-0000-0000-0000-0000000aa001';
  v_open  uuid;
  v_txn   uuid;
  v_lot1  uuid;
begin
  -- ยอดยกมาของทรัพย์ชิ้นนี้ **ผูกทรัพย์** เพื่อให้สมุดกับทะเบียนตรงกัน
  v_open := pg_temp.open_asset(v_asset, 'opn.securities', 72000, 'L2 ยอดยกมาหุ้น 72,000');
  if sri_os.fn_asset_cost_basis(v_asset) <> 72000 then
    raise exception 'FAIL: L2 — ต้นทุนในสมุดควรเป็น 72,000 แต่ได้ % (ใบยอดยกมาต้องผูกทรัพย์)',
      sri_os.fn_asset_cost_basis(v_asset);
  end if;

  select id into v_lot1 from sri_os.asset_lots where asset_id = v_asset and note = 'L1 ล็อตแรก';

  -- ขาย 50 หุ้นได้ 25,000 บาท · ต้นทุนถูกต้อง 18,000 → กำไร 7,000
  v_txn := pg_temp.sell(v_asset, 18000, 25000, 'L2 ขาย 50 หุ้น');

  -- **ส่งต้นทุนที่ตัดผิดเข้ามา → ต้องถูกปฏิเสธ** (ตัวเลขมาจากทะเบียนเท่านั้น)
  perform pg_temp.must_fail_like('L2 ตัดล็อตด้วยต้นทุนที่ส่งมาผิด (5,000)', format($q$
    select pg_temp.consume1(%L, %L, 50, 5000) $q$, v_lot1, v_txn),
    'ต้นทุนถัวเฉลี่ยคำนวณจากทะเบียนล็อต');

  perform pg_temp.must_fail_like('L2 ตัดล็อตด้วยต้นทุนที่ส่งมาผิด (30,000)', format($q$
    select pg_temp.consume1(%L, %L, 50, 30000) $q$, v_lot1, v_txn),
    'ต้นทุนถัวเฉลี่ยคำนวณจากทะเบียนล็อต');

  -- ค่าที่ถูกต้องตัวเดียว = 18,000 (72,000 × 50/200)
  perform pg_temp.must_pass('L2 ตัดล็อตด้วยต้นทุนถัวเฉลี่ยที่ถูกต้อง 18,000', format($q$
    select pg_temp.consume1(%L, %L, 50, 18000) $q$, v_lot1, v_txn));

  if sri_os.fn_asset_units(v_asset) <> 150 then
    raise exception 'FAIL: L2 — เหลือ 150 หุ้น แต่ได้ %', sri_os.fn_asset_units(v_asset);
  end if;
  if sri_os.fn_asset_lot_cost(v_asset) <> 54000 then
    raise exception 'FAIL: L2 — ต้นทุนคงเหลือควรเป็น 54,000 แต่ได้ %', sri_os.fn_asset_lot_cost(v_asset);
  end if;
  if round(sri_os.fn_asset_average_unit_cost(v_asset), 2) <> 360 then
    raise exception 'FAIL: L2 — ต้นทุนถัวเฉลี่ยต้องยังเป็น 360 บาท/หุ้น แต่ได้ %',
      sri_os.fn_asset_average_unit_cost(v_asset);
  end if;
  if sri_os.fn_asset_cost_basis(v_asset) <> 54000 then
    raise exception 'FAIL: L2 — ต้นทุนในสมุดควรเหลือ 54,000 เท่าทะเบียน แต่ได้ %',
      sri_os.fn_asset_cost_basis(v_asset);
  end if;

  raise notice 'ok L2 · ขาย 50/200 หุ้น → ต้นทุนที่ตัดมีค่าที่ถูกต้องตัวเดียว 18,000 (ส่ง 5,000 และ 30,000 ถูกปฏิเสธ) · เหลือ 150 หุ้น ต้นทุน 54,000 · ถัวเฉลี่ยยัง 360 · สมุดกับทะเบียนตรงกัน';
end $$;

-- ============================================================
-- L3 · ขายหมด → ต้นทุนเหลือ 0 **พอดี** · ขายเกินที่ถือไม่ได้
-- ============================================================
do $$
declare
  v_asset uuid := '00000000-0000-0000-0000-0000000aa001';
  v_txn   uuid;
  v_lot1  uuid;
  v_lot2  uuid;
begin
  select id into v_lot1 from sri_os.asset_lots where asset_id = v_asset and note = 'L1 ล็อตแรก';
  select id into v_lot2 from sri_os.asset_lots where asset_id = v_asset and note = 'L1 ล็อตสอง';

  -- ขายที่เหลือทั้งหมด 150 หุ้น · ต้นทุน 54,000 · ได้เงิน 60,000 → กำไร 6,000
  v_txn := pg_temp.sell(v_asset, 54000, 60000, 'L3 ขายที่เหลือ 150 หุ้น');

  -- ตัดเกินจำนวนที่ล็อตมี → ปฏิเสธ (ล็อตแรกเหลือ 50 หุ้น)
  perform pg_temp.must_fail_like('L3 ตัดล็อตเกินจำนวนที่มี', format($q$
    select pg_temp.consume1(%L, %L, 80, 28800) $q$, v_lot1, v_txn),
    'มากกว่าจำนวนที่มี');

  -- ตัดครบสองล็อต (50 + 100 = 150 หุ้น · 18,000 + 36,000 = 54,000)
  perform pg_temp.must_pass('L3 ตัดครบทั้งสองล็อต', format($q$
    select pg_temp.consume(jsonb_build_array(
      jsonb_build_object('lot', %L, 'txn', %L, 'qty', 50, 'cost', 18000),
      jsonb_build_object('lot', %L, 'txn', %L, 'qty', 100, 'cost', 36000))) $q$,
    v_lot1, v_txn, v_lot2, v_txn));

  if sri_os.fn_asset_units(v_asset) <> 0 then
    raise exception 'FAIL: L3 — ขายหมดแล้วต้องเหลือ 0 หุ้น แต่ได้ %', sri_os.fn_asset_units(v_asset);
  end if;
  if sri_os.fn_asset_lot_cost(v_asset) <> 0 then
    raise exception 'FAIL: L3 — ขายหมดแล้วต้นทุนในทะเบียนต้องเป็น 0 พอดี แต่เหลือ %',
      sri_os.fn_asset_lot_cost(v_asset);
  end if;
  if sri_os.fn_asset_cost_basis(v_asset) <> 0 then
    raise exception 'FAIL: L3 — ขายหมดแล้วต้นทุนในสมุดต้องเป็น 0 แต่เหลือ %',
      sri_os.fn_asset_cost_basis(v_asset);
  end if;
  if sri_os.fn_asset_average_unit_cost(v_asset) is not null then
    raise exception 'FAIL: L3 — ไม่มีหน่วยคงเหลือแล้ว ต้นทุนต่อหน่วยต้องเป็น null (หารศูนย์ไม่ได้)';
  end if;

  raise notice 'ok L3 · ขายหมด 150 หุ้น (54,000) → ทั้งจำนวนและต้นทุนเหลือ 0 พอดีทั้งทะเบียนและสมุด · ตัดเกินจำนวนที่ล็อตมีถูกปฏิเสธ';
end $$;

-- ============================================================
-- L4 · **`assets.units` ไม่ใช่แหล่งความจริง** — แก้มือแล้วคำตอบไม่เปลี่ยน
-- ============================================================
do $$
declare
  v_asset uuid := '00000000-0000-0000-0000-0000000aa002';   -- ทองคำ (บาท)
  v_before numeric;
  v_has_units boolean;
begin
  -- ทองคำ 10 บาททอง ต้นทุน 400,000 (สกุลบาท → ไม่ต้องมีอัตรา)
  insert into sri_os.asset_lots(asset_id, acquired_date, quantity, cost_thb, note)
  values (v_asset, '2026-02-10', 10, 400000, 'L4 ทองคำ');

  v_before := sri_os.fn_asset_units(v_asset);
  if v_before <> 10 then
    raise exception 'FAIL: L4 — ควรมี 10 หน่วย แต่ได้ %', v_before;
  end if;

  select exists (select 1 from pg_attribute a
                  where a.attrelid = 'sri_os.assets'::regclass and a.attname = 'units'
                    and a.attnum > 0 and not a.attisdropped) into v_has_units;
  if v_has_units then
    execute format('update sri_os.assets set units = 999 where id = %L', v_asset);
    if sri_os.fn_asset_units(v_asset) <> v_before then
      raise exception 'FAIL: L4 — แก้ assets.units แล้วจำนวนคงเหลือเปลี่ยนเป็น % (units ต้องไม่ใช่แหล่งความจริง)',
        sri_os.fn_asset_units(v_asset);
    end if;
    raise notice 'ok L4 · แก้ assets.units เป็น 999 แล้วจำนวนคงเหลือยังเป็น 10 (ความจริงมาจากทะเบียนล็อต)';
  else
    raise notice 'ok L4 · ตาราง assets ไม่มีคอลัมน์ units ในสคีมานี้ — ความจริงมาจากทะเบียนล็อตอยู่แล้ว (10 หน่วย)';
  end if;
end $$;

-- ============================================================
-- L5 · append-only — แก้/ลบล็อตไม่ได้ (ทั้ง trigger และ RLS)
-- ============================================================
do $$
declare v_lot uuid;
begin
  select id into v_lot from sri_os.asset_lots where note = 'L4 ทองคำ';

  perform pg_temp.must_fail_like('L5 แก้จำนวนของล็อต', format($q$
    update sri_os.asset_lots set quantity = 1 where id = %L $q$, v_lot),
    'แก้ล็อตที่ลงไว้แล้วไม่ได้');

  perform pg_temp.must_fail_like('L5 แก้ต้นทุนของล็อต', format($q$
    update sri_os.asset_lots set cost_thb = 1 where id = %L $q$, v_lot),
    'แก้ล็อตที่ลงไว้แล้วไม่ได้');

  perform pg_temp.must_fail_like('L5 ลบล็อต', format($q$
    delete from sri_os.asset_lots where id = %L $q$, v_lot),
    'ลบล็อตที่ลงไว้แล้วไม่ได้');

  -- ตารางการขายออกมีข้อความของตัวเอง (ไม่มีคอลัมน์ร่องรอยการกลับรายการ)
  perform pg_temp.must_fail_like('L5 แก้ส่วนที่ขายออก', $q$
    update sri_os.asset_lot_consumptions set cost_thb = 1 where cost_thb = 18000 $q$,
    'ไม่ได้ (กฎเหล็กข้อ 1)');

  if sri_os.fn_asset_units('00000000-0000-0000-0000-0000000aa002') <> 10 then
    raise exception 'FAIL: L5 — ทะเบียนถูกแก้ได้ (จำนวนเปลี่ยนเป็น %)',
      sri_os.fn_asset_units('00000000-0000-0000-0000-0000000aa002');
  end if;
  raise notice 'ok L5 · แก้/ลบล็อตและส่วนที่ขายออกไม่ได้ (append-only · กฎเหล็กข้อ 1) — แก้ต้องกลับรายการใบที่สร้างแล้วลงใหม่';
end $$;

-- ============================================================
-- L6 · **MUTATION** — ถอดด่านถัวเฉลี่ยออก แล้ววัดว่ากำไรเพี้ยนเท่าไร
--      (ถ้าเคสนี้ไม่แดง แปลว่า L2 ไม่ได้พิสูจน์อะไร)
-- ============================================================
savepoint before_lot_mutation;
do $$
declare
  v_asset uuid := '00000000-0000-0000-0000-0000000aa002';
  v_lot   uuid;
  v_txn   uuid;
  v_cost  numeric;
begin
  select id into v_lot from sri_os.asset_lots where note = 'L4 ทองคำ';

  set constraints all immediate;
  alter table sri_os.asset_lot_consumptions disable trigger trg_lot_consumption_sane;
  set constraints all deferred;

  -- ยอดยกมาของทองคำ (ผูกทรัพย์) 400,000 แล้วขาย 5 หน่วย
  perform pg_temp.open_asset(v_asset, 'opn.gold_alt', 400000, 'L6 ยอดยกมาทองคำ 400,000');
  -- **ขายทองต้องตัดออกจากบัญชีของทองเอง (1720) ด้วยหมวดของมัน** ไม่ใช่ 1700
  v_txn := pg_temp.sell(v_asset, 50000, 260000, 'L6 ขายทอง 5 หน่วย (mutation)',
                        '2026-04-01', 'inv.sell_commodity', '1720');

  -- ตัดต้นทุนแค่ 50,000 ทั้งที่ถัวเฉลี่ยคือ 400,000 × 5/10 = 200,000
  insert into sri_os.asset_lot_consumptions(lot_id, txn_id, quantity, cost_thb)
  values (v_lot, v_txn, 5, 50000);

  set constraints all immediate;
  alter table sri_os.asset_lot_consumptions enable trigger trg_lot_consumption_sane;
  set constraints all deferred;

  v_cost := sri_os.fn_asset_lot_cost(v_asset);
  if v_cost <> 350000 then
    raise exception 'FAIL: L6 — กลายพันธุ์ไม่สำเร็จ (ต้นทุนคงเหลือ % ควรเป็น 350,000) เคสนี้จึงไม่ได้พิสูจน์อะไร', v_cost;
  end if;

  raise notice 'ok L6 · MUTATION · ถอดด่านถัวเฉลี่ยออก → ตัดต้นทุน 50,000 แทนที่จะเป็น 200,000 (ถัวเฉลี่ย 400,000 × 5/10) → **กำไรสูงกว่าจริง 150,000** และต้นทุนคงเหลือในทะเบียนบวมเป็น 350,000 ทั้งที่เหลือของครึ่งเดียว (ควรเป็น 200,000) = ตัวเลขผิดเงียบๆ ที่ด่านนี้กันไว้';
end $$;
rollback to savepoint before_lot_mutation;

do $$
begin
  if exists (select 1 from pg_trigger g
              where g.tgrelid = 'sri_os.asset_lot_consumptions'::regclass
                and g.tgname = 'trg_lot_consumption_sane' and g.tgenabled = 'D') then
    raise exception 'FAIL: L6b — ด่านยังถูกปิดอยู่หลัง rollback';
  end if;
  if exists (select 1 from sri_os.transactions where memo like 'L6 %') then
    raise exception 'FAIL: L6b — ใบของ mutation ยังค้างอยู่ในสมุด';
  end if;
  raise notice 'ok L6b · ด่านกลับมาและไม่มีใบของ mutation ค้างในสมุด';
end $$;

-- ---------- สรุป: ของที่ไฟล์นี้สร้างต้องผ่านด่านที่เลื่อนไว้จริง ----------
do $$
declare n int;
begin
  set constraints all immediate;
  select count(*) into n from sri_os.asset_lots;
  if n < 3 then
    raise exception 'FAIL: นับล็อตที่ลงได้แค่ % — เทสต์อาจไม่ได้ลงอะไรเลย', n;
  end if;
  raise notice 'ok L · ล็อต % แถวและการตัดล็อตทั้งหมดผ่านด่านที่เลื่อนไว้', n;
end $$;

do $$ begin raise notice '=== ทะเบียนล็อตรายตัว ผ่านทั้งหมด ==='; end $$;

rollback;
