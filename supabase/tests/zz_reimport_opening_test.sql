-- ============================================================
-- SRI OS · **อัปโหลดยอดตั้งต้นใหม่** (20261025000009_reimport_opening.sql)
--
-- ก่อนไฟล์นั้น: การแก้ยอดตั้งต้นต้องทำจากฝั่งแอปหลายคำสั่ง (กลับรายการ → ลงใหม่)
-- ซึ่งมี **จังหวะที่ยอดของผู้ถือเป็นศูนย์** ถ้าไฟดับตรงนั้นยอดทั้งก้อนหาย
-- และ **งบดุลยังดุล — ดุลที่ศูนย์** จึงไม่มีใครรู้ว่าหาย
--
-- สิ่งที่ไฟล์นี้พิสูจน์:
--   R1 · ลงยอดตั้งต้นสองผู้ถือผ่านประตูเดียว · งบดุลดุล · ตัวเลขตรงไฟล์
--   R2 · **อัปโหลดเดิมซ้ำ → ไม่มีรายการใหม่ ไม่มีการกลับรายการ ไม่มีล็อตใหม่**
--   R3 · อัปโหลดที่แก้แล้ว → กลับรายการ **เฉพาะผู้ถือที่เปลี่ยน** · อีกคนไม่ถูกแตะ
--        ยอดสุทธิถูก · **DELETE = 0** (ใบเดิมยังอยู่ครบ)
--   R4 · **ล้มกลางทาง** (error หลังกลับรายการสำเร็จ ก่อนลงชุดใหม่) →
--        สมุดกลับสภาพเดิมทั้งหมด ไม่มียอดหาย ไม่มีล็อตค้าง
--   R5 · ล็อต: แก้จำนวนหุ้น → ล็อตชุดเดิมไม่ค้าง · ต้นทุนถัวเฉลี่ยตรงไฟล์ใหม่
--   R6 · อัปโหลดใหม่หลังขายไปแล้ว → **ปฏิเสธ** พร้อมบอกว่าใบไหนอ้างอยู่
--   R7 · **MUTATION** — ถอดการเทียบลายนิ้วมือออก แล้ววัดว่าสมุดบวมเท่าไร
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
create temporary table r_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into r_uid(label) values ('mgmt');
insert into auth.users(id) select id from r_uid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, 'reimport@local', 'mgmt', 'management', true from r_uid u;
select set_config('test.uid', (select id::text from r_uid where label = 'mgmt'), true);

insert into sri_os.user_owner_access(user_id, owner_id)
select (select id from r_uid where label = 'mgmt'), o.id from sri_os.owners o;

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
values ('00000000-0000-0000-0000-0000000eb001'::uuid,
        (select id from sri_os.owners where code = 'THANAKORN'), 'SCB', 'ธนากร', 'ธนากร - SCB (นำเข้า)'),
       ('00000000-0000-0000-0000-0000000eb002'::uuid,
        (select id from sri_os.owners where code = 'SUTEE'), 'KBANK', 'สุธี', 'สุธี - KBANK (นำเข้า)');

insert into sri_os.contacts(id, first_name, types)
values ('00000000-0000-0000-0000-0000000ec001', 'โบรกเกอร์ (นำเข้า)', array['other']);

insert into sri_os.fx_rates(currency, rate_date, thb_per_unit, source, note)
values ('USD', '2026-02-02', 35.0, 'manual', 'วันซื้อล็อตแรก'),
       ('USD', '2026-03-02', 37.0, 'manual', 'วันซื้อล็อตสอง'),
       ('USD', '2026-05-01', 39.0, 'manual', 'วันขาย')
on conflict (currency, rate_date) do nothing;

insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, currency)
select '00000000-0000-0000-0000-0000000ea001', 'IMP-AAPL', 'หุ้น AAPL (นำเข้า)',
       cat.class_id, cat.id, (select id from sri_os.owners where code = 'THANAKORN'), 'USD'
  from (select id, class_id from sri_os.asset_categories order by id limit 1) cat;

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

/** ยอดของบัญชีหนึ่งต่อผู้ถือ (ฝั่งเดบิตเป็นบวก) */
create or replace function pg_temp.bal(p_code text, p_owner text) returns numeric
language sql stable as $fn$
  select round(coalesce(sum(v.debit - v.credit), 0), 2)
    from sri_os.v_ledger_posted v
    join sri_os.chart_of_accounts c on c.id = v.coa_id
   where c.code = p_code and v.owner_id = pg_temp.own(p_owner);
$fn$;

/** จำนวนใบยอดยกมาทั้งหมดของผู้ถือ (รวมใบกลับรายการ — พิสูจน์ว่าไม่มีการลบ) */
create or replace function pg_temp.n_txn(p_owner text) returns int
language sql stable as $fn$
  select count(*)::int
    from sri_os.transactions t
   where t.owner_id = pg_temp.own(p_owner) and t.txn_type_code like 'opn.%';
$fn$;

/** จำนวนใบยอดยกมาที่ **ยังมีผล** (ชุดเดิมตามสายตาของฟังก์ชัน) */
create or replace function pg_temp.n_active(p_owner text) returns int
language sql stable as $fn$
  select coalesce(array_length(sri_os.fn_opening_set(pg_temp.own(p_owner)), 1), 0);
$fn$;

/** entries + lots ของไฟล์ยอดตั้งต้นของธนากร (ปรับยอดเงินฝาก/ล็อตได้) */
create or replace function pg_temp.file_tk(p_cash numeric, p_lots jsonb,
                                           p_sec numeric) returns jsonb
language sql stable as $fn$
  select jsonb_build_object(
    'entries', jsonb_build_array(
      jsonb_build_object(
        'txn_type_code', 'opn.cash',
        'doc_date', '2026-01-01', 'cash_date', '2026-01-01',
        'memo', 'นำเข้า: เงินฝากยกมา ' || p_cash::text,
        'attachments', jsonb_build_array('ยอดตั้งต้น.pdf'),
        'transactions', jsonb_build_array(jsonb_build_object(
          'owner_id', pg_temp.own('THANAKORN'),
          'lines', jsonb_build_array(
            jsonb_build_object('coa_code', '1100', 'bank_account_id', '00000000-0000-0000-0000-0000000eb001',
                               'debit', p_cash, 'credit', 0, 'cf_category', 'none'),
            jsonb_build_object('coa_code', '3300', 'debit', 0, 'credit', p_cash, 'cf_category', 'none'))))),
      jsonb_build_object(
        'txn_type_code', 'opn.securities',
        'doc_date', '2026-01-01',
        'memo', 'นำเข้า: หลักทรัพย์ยกมา ' || p_sec::text,
        'asset_id', '00000000-0000-0000-0000-0000000ea001',
        'attachments', jsonb_build_array('ยอดตั้งต้น.pdf'),
        'transactions', jsonb_build_array(jsonb_build_object(
          'owner_id', pg_temp.own('THANAKORN'),
          'lines', jsonb_build_array(
            jsonb_build_object('coa_code', '1700', 'asset_id', '00000000-0000-0000-0000-0000000ea001',
                               'debit', p_sec, 'credit', 0, 'cf_category', 'none'),
            jsonb_build_object('coa_code', '3300', 'debit', 0, 'credit', p_sec, 'cf_category', 'none')))))),
    'lots', p_lots);
$fn$;

/** ล็อตสองล็อตมาตรฐาน: 100 หุ้น @35.00 (35,000) + p_qty2 หุ้น @37.00 */
create or replace function pg_temp.lots(p_qty2 numeric, p_orig2 numeric) returns jsonb
language sql stable as $fn$
  select jsonb_build_array(
    jsonb_build_object('asset_id', '00000000-0000-0000-0000-0000000ea001',
                       'acquired_date', '2026-02-02', 'quantity', 100, 'cost_thb', 35000,
                       'currency', 'USD', 'amount_original', 1000, 'fx_rate', 35.0,
                       'fx_rate_date', '2026-02-02'),
    jsonb_build_object('asset_id', '00000000-0000-0000-0000-0000000ea001',
                       'acquired_date', '2026-03-02', 'quantity', p_qty2,
                       'cost_thb', round(p_orig2 * 37.0, 2),
                       'currency', 'USD', 'amount_original', p_orig2, 'fx_rate', 37.0,
                       'fx_rate_date', '2026-03-02'));
$fn$;

/** ไฟล์ของสุธี (เงินฝากเดียว) */
create or replace function pg_temp.file_st(p_cash numeric) returns jsonb
language sql stable as $fn$
  select jsonb_build_object(
    'entries', jsonb_build_array(jsonb_build_object(
      'txn_type_code', 'opn.cash',
      'doc_date', '2026-01-01', 'cash_date', '2026-01-01',
      'memo', 'นำเข้า: เงินฝากยกมาของสุธี ' || p_cash::text,
      'attachments', jsonb_build_array('ยอดตั้งต้น.pdf'),
      'transactions', jsonb_build_array(jsonb_build_object(
        'owner_id', pg_temp.own('SUTEE'),
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code', '1100', 'bank_account_id', '00000000-0000-0000-0000-0000000eb002',
                             'debit', p_cash, 'credit', 0, 'cf_category', 'none'),
          jsonb_build_object('coa_code', '3300', 'debit', 0, 'credit', p_cash, 'cf_category', 'none')))))),
    'lots', '[]'::jsonb);
$fn$;

-- ============================================================
-- R0 · โครงสร้าง
-- ============================================================
do $$
begin
  if to_regprocedure('sri_os.fn_reimport_opening(uuid, jsonb)') is null then
    raise exception 'FAIL: R0 — ยังไม่มี fn_reimport_opening (migration ไม่ถูก apply?) เทสต์นี้จะไม่ได้ตรวจอะไร';
  end if;
  if not exists (select 1 from pg_attribute a
                  where a.attrelid = 'sri_os.asset_lots'::regclass
                    and a.attname = 'reversed_by_txn_id' and a.attnum > 0 and not a.attisdropped) then
    raise exception 'FAIL: R0 — ทะเบียนล็อตยังไม่มีร่องรอยการกลับรายการ';
  end if;
  raise notice 'ok R0 · ประตูอัปโหลดยอดตั้งต้นและร่องรอยการกลับรายการของล็อตมีจริง';
end $$;

-- ============================================================
-- R1 · นำเข้าครั้งแรกสองผู้ถือ
--   ธนากร: เงินฝาก 1,000,000 · หลักทรัพย์ 72,000 (2 ล็อต 100+100 หุ้น)
--   สุธี  : เงินฝาก 250,000
-- ============================================================
do $$
declare v jsonb;
begin
  v := sri_os.fn_reimport_opening(pg_temp.own('THANAKORN'),
         pg_temp.file_tk(1000000, pg_temp.lots(100, 1000), 72000));
  if (v ->> 'changed')::boolean is not true or (v ->> 'posted')::int <> 2 or (v ->> 'lots')::int <> 2 then
    raise exception 'FAIL: R1 — ผลลัพธ์ของการนำเข้าครั้งแรกผิด: %', v;
  end if;
  if (v ->> 'reversed')::int <> 0 then
    raise exception 'FAIL: R1 — ครั้งแรกไม่ควรมีการกลับรายการ แต่ได้ %', v ->> 'reversed';
  end if;

  v := sri_os.fn_reimport_opening(pg_temp.own('SUTEE'), pg_temp.file_st(250000));
  if (v ->> 'posted')::int <> 1 then
    raise exception 'FAIL: R1 — ของสุธีควรลง 1 ใบ: %', v;
  end if;

  if pg_temp.bal('1100', 'THANAKORN') <> 1000000 or pg_temp.bal('1700', 'THANAKORN') <> 72000
     or pg_temp.bal('3300', 'THANAKORN') <> -1072000 then
    raise exception 'FAIL: R1 — ยอดของธนากรผิด (1100 % · 1700 % · 3300 %)',
      pg_temp.bal('1100', 'THANAKORN'), pg_temp.bal('1700', 'THANAKORN'), pg_temp.bal('3300', 'THANAKORN');
  end if;
  if pg_temp.bal('1100', 'SUTEE') <> 250000 or pg_temp.bal('3300', 'SUTEE') <> -250000 then
    raise exception 'FAIL: R1 — ยอดของสุธีผิด (1100 % · 3300 %)',
      pg_temp.bal('1100', 'SUTEE'), pg_temp.bal('3300', 'SUTEE');
  end if;
  if sri_os.fn_asset_units('00000000-0000-0000-0000-0000000ea001') <> 200
     or sri_os.fn_asset_lot_cost('00000000-0000-0000-0000-0000000ea001') <> 72000 then
    raise exception 'FAIL: R1 — ทะเบียนล็อตผิด (% หุ้น · % บาท)',
      sri_os.fn_asset_units('00000000-0000-0000-0000-0000000ea001'),
      sri_os.fn_asset_lot_cost('00000000-0000-0000-0000-0000000ea001');
  end if;
  -- สมุดกับทะเบียนต้องตรงกัน (ใบยอดยกมาผูกทรัพย์)
  if sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-0000000ea001') <> 72000 then
    raise exception 'FAIL: R1 — ต้นทุนในสมุดควรเป็น 72,000 แต่ได้ %',
      sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-0000000ea001');
  end if;

  raise notice 'ok R1 · นำเข้าครั้งแรก: ธนากร 1,000,000 + 72,000 (200 หุ้น · 2 ล็อต) · สุธี 250,000 · สมุด = ทะเบียน';
end $$;

-- ============================================================
-- R2 · **อัปโหลดเดิมซ้ำ → ไม่เกิดอะไรเลย**
-- ============================================================
do $$
declare
  v jsonb;
  v_txn0 int := pg_temp.n_txn('THANAKORN');
  v_lot0 int := (select count(*)::int from sri_os.asset_lots);
  v_fp0  text := sri_os.fn_opening_fingerprint(pg_temp.own('THANAKORN'));
begin
  v := sri_os.fn_reimport_opening(pg_temp.own('THANAKORN'),
         pg_temp.file_tk(1000000, pg_temp.lots(100, 1000), 72000));

  if (v ->> 'changed')::boolean is not false then
    raise exception 'FAIL: R2 — อัปโหลดเดิมซ้ำต้องไม่เปลี่ยนอะไร แต่ได้ %', v;
  end if;
  if pg_temp.n_txn('THANAKORN') <> v_txn0 then
    raise exception 'FAIL: R2 — มีใบใหม่เกิดขึ้น (% → %)', v_txn0, pg_temp.n_txn('THANAKORN');
  end if;
  if (select count(*)::int from sri_os.asset_lots) <> v_lot0 then
    raise exception 'FAIL: R2 — มีล็อตใหม่เกิดขึ้น';
  end if;
  if exists (select 1 from sri_os.asset_lots where reversed_by_txn_id is not null) then
    raise exception 'FAIL: R2 — มีล็อตถูกกลับรายการทั้งที่เนื้อเหมือนเดิม';
  end if;
  if sri_os.fn_opening_fingerprint(pg_temp.own('THANAKORN')) <> v_fp0 then
    raise exception 'FAIL: R2 — ลายนิ้วมือเปลี่ยนทั้งที่ไม่ควรมีอะไรเปลี่ยน';
  end if;
  -- และหมายเหตุที่ต่างกันก็ยังถือว่าเนื้อเดิม (ไม่ reverse ให้เปล่าๆ)
  v := sri_os.fn_reimport_opening(pg_temp.own('THANAKORN'),
         jsonb_set(pg_temp.file_tk(1000000, pg_temp.lots(100, 1000), 72000),
                   '{entries,0,memo}', '"นำเข้า: พิมพ์หมายเหตุใหม่"'));
  if (v ->> 'changed')::boolean is not false then
    raise exception 'FAIL: R2 — หมายเหตุที่ต่างกันไม่ควรทำให้กลับรายการทั้งชุด: %', v;
  end if;

  raise notice 'ok R2 · อัปโหลดไฟล์เดิมซ้ำ (และไฟล์ที่ต่างแค่หมายเหตุ) → ไม่มีใบใหม่ ไม่มีการกลับรายการ ไม่มีล็อตใหม่ (ใบคงเดิม % ใบ)', v_txn0;
end $$;

-- ============================================================
-- R3 · อัปโหลดที่แก้แล้ว → กลับรายการเฉพาะผู้ถือที่เปลี่ยน · DELETE = 0
--      เงินฝากของธนากร 1,000,000 → 1,200,000
-- ============================================================
do $$
declare
  v jsonb;
  v_st_ids uuid[];
  v_st_after uuid[];
  v_txn0 int := pg_temp.n_txn('THANAKORN');
begin
  select coalesce(array_agg(t.id order by t.id), '{}') into v_st_ids
    from sri_os.transactions t
   where t.owner_id = pg_temp.own('SUTEE') and t.txn_type_code like 'opn.%';

  v := sri_os.fn_reimport_opening(pg_temp.own('THANAKORN'),
         pg_temp.file_tk(1200000, pg_temp.lots(100, 1000), 72000));

  if (v ->> 'changed')::boolean is not true or (v ->> 'reversed')::int <> 2
     or (v ->> 'posted')::int <> 2 or (v ->> 'lots')::int <> 2 then
    raise exception 'FAIL: R3 — ผลลัพธ์ผิด (ควรกลับรายการ 2 ลงใหม่ 2 ล็อตใหม่ 2): %', v;
  end if;

  -- ยอดสุทธิถูก: 1,000,000 − 1,000,000 + 1,200,000
  if pg_temp.bal('1100', 'THANAKORN') <> 1200000 then
    raise exception 'FAIL: R3 — เงินฝากของธนากรควรเป็น 1,200,000 แต่ได้ %', pg_temp.bal('1100', 'THANAKORN');
  end if;
  if pg_temp.bal('1700', 'THANAKORN') <> 72000 or pg_temp.bal('3300', 'THANAKORN') <> -1272000 then
    raise exception 'FAIL: R3 — ยอดอื่นของธนากรผิด (1700 % · 3300 %)',
      pg_temp.bal('1700', 'THANAKORN'), pg_temp.bal('3300', 'THANAKORN');
  end if;

  -- **DELETE = 0** — ใบเดิมยังอยู่ครบ และมีใบกลับรายการเพิ่ม (2 + 2 + 2 = 6)
  if pg_temp.n_txn('THANAKORN') <> v_txn0 + 4 then
    raise exception 'FAIL: R3 — จำนวนใบควรเป็น % (เดิม % + กลับรายการ 2 + ใหม่ 2) แต่ได้ %',
      v_txn0 + 4, v_txn0, pg_temp.n_txn('THANAKORN');
  end if;
  if (select count(*) from sri_os.transactions t
       where t.owner_id = pg_temp.own('THANAKORN') and t.reverses_id is not null) <> 2 then
    raise exception 'FAIL: R3 — ต้องมีใบกลับรายการ 2 ใบ';
  end if;
  if pg_temp.n_active('THANAKORN') <> 2 then
    raise exception 'FAIL: R3 — ชุดที่ยังมีผลต้องเหลือ 2 ใบ แต่ได้ %', pg_temp.n_active('THANAKORN');
  end if;

  -- **ผู้ถืออื่นไม่ถูกแตะเลย** (id ชุดเดิมและยอดเดิม)
  select coalesce(array_agg(t.id order by t.id), '{}') into v_st_after
    from sri_os.transactions t
   where t.owner_id = pg_temp.own('SUTEE') and t.txn_type_code like 'opn.%';
  if v_st_after <> v_st_ids then
    raise exception 'FAIL: R3 — ใบของสุธีถูกแตะ (เดิม % · หลัง %)', v_st_ids, v_st_after;
  end if;
  if pg_temp.bal('1100', 'SUTEE') <> 250000 then
    raise exception 'FAIL: R3 — ยอดของสุธีเปลี่ยน (%)', pg_temp.bal('1100', 'SUTEE');
  end if;

  -- ล็อตชุดเดิมต้องไม่ค้าง: ยังมี 200 หุ้น 72,000 (ของชุดใหม่) ไม่ใช่ 400 หุ้น
  if sri_os.fn_asset_units('00000000-0000-0000-0000-0000000ea001') <> 200
     or sri_os.fn_asset_lot_cost('00000000-0000-0000-0000-0000000ea001') <> 72000 then
    raise exception 'FAIL: R3 — ล็อตชุดเดิมค้าง (% หุ้น · % บาท)',
      sri_os.fn_asset_units('00000000-0000-0000-0000-0000000ea001'),
      sri_os.fn_asset_lot_cost('00000000-0000-0000-0000-0000000ea001');
  end if;
  if (select count(*) from sri_os.asset_lots where reversed_by_txn_id is not null) <> 2 then
    raise exception 'FAIL: R3 — ล็อตชุดเดิมต้องถูกติดร่องรอยว่ากลับรายการแล้ว 2 ล็อต';
  end if;

  raise notice 'ok R3 · แก้เงินฝาก 1,000,000 → 1,200,000: กลับรายการ 2 + ลงใหม่ 2 (ใบรวม % → %) · DELETE = 0 · สุธีไม่ถูกแตะ · ล็อตเดิมไม่ค้าง (ยัง 200 หุ้น 72,000)',
    v_txn0, pg_temp.n_txn('THANAKORN');
end $$;

-- ============================================================
-- R4 · **ล้มกลางทาง** — error หลังกลับรายการสำเร็จ ก่อนลงชุดใหม่
--      (ใบที่สองของไฟล์ลงบัญชีที่หมวดไม่ได้ประกาศ → ประตูปฏิเสธ)
--      ต้องย้อนทั้งคำสั่ง: ยอดเดิมอยู่ครบ ไม่มีใบกลับรายการใหม่ ไม่มีล็อตค้าง
-- ============================================================
do $$
declare
  v_fp0   text := sri_os.fn_opening_fingerprint(pg_temp.own('THANAKORN'));
  v_txn0  int  := pg_temp.n_txn('THANAKORN');
  v_rev0  int  := (select count(*)::int from sri_os.transactions t
                    where t.owner_id = pg_temp.own('THANAKORN') and t.reverses_id is not null);
  v_lot0  int  := (select count(*)::int from sri_os.asset_lots where reversed_by_txn_id is null);
  v_cash0 numeric := pg_temp.bal('1100', 'THANAKORN');
  v_bad   jsonb;
begin
  -- ไฟล์ใหม่ที่ "ใบแรกถูก ใบที่สองพัง" → การกลับรายการเกิดก่อนแล้วค่อยพัง
  v_bad := jsonb_set(pg_temp.file_tk(1500000, pg_temp.lots(100, 1000), 72000),
                     '{entries,1,transactions,0,lines,0,coa_code}', '"4200"');

  perform pg_temp.must_fail_like('R4 ไฟล์ใหม่พังกลางทาง', format(
    $q$ select sri_os.fn_reimport_opening(%L, %L::jsonb) $q$,
    pg_temp.own('THANAKORN'), v_bad),
    'ตารางกฎระบุบัญชีของหมวดนี้ไว้เฉพาะ');

  -- **สมุดต้องกลับสภาพเดิมทั้งหมด**
  if sri_os.fn_opening_fingerprint(pg_temp.own('THANAKORN')) <> v_fp0 then
    raise exception 'FAIL: R4 — ลายนิ้วมือเปลี่ยนหลังคำสั่งที่ล้ม (สมุดไม่กลับสภาพเดิม)';
  end if;
  if pg_temp.n_txn('THANAKORN') <> v_txn0 then
    raise exception 'FAIL: R4 — จำนวนใบเปลี่ยน (% → %)', v_txn0, pg_temp.n_txn('THANAKORN');
  end if;
  if (select count(*)::int from sri_os.transactions t
       where t.owner_id = pg_temp.own('THANAKORN') and t.reverses_id is not null) <> v_rev0 then
    raise exception 'FAIL: R4 — มีใบกลับรายการค้างจากคำสั่งที่ล้ม';
  end if;
  if (select count(*)::int from sri_os.asset_lots where reversed_by_txn_id is null) <> v_lot0 then
    raise exception 'FAIL: R4 — ล็อตที่ยังใช้อยู่เปลี่ยนจำนวน (% → %)', v_lot0,
      (select count(*)::int from sri_os.asset_lots where reversed_by_txn_id is null);
  end if;
  if pg_temp.bal('1100', 'THANAKORN') <> v_cash0 or v_cash0 <> 1200000 then
    raise exception 'FAIL: R4 — ยอดเงินฝากเปลี่ยน (% → %) **ยอดตั้งต้นหาย**',
      v_cash0, pg_temp.bal('1100', 'THANAKORN');
  end if;
  if pg_temp.n_active('THANAKORN') <> 2 then
    raise exception 'FAIL: R4 — ชุดที่ยังมีผลไม่ใช่ 2 ใบ (%) — มีจังหวะที่ยอดเป็นศูนย์ค้างอยู่',
      pg_temp.n_active('THANAKORN');
  end if;

  raise notice 'ok R4 · คำสั่งที่ล้มหลังกลับรายการสำเร็จ → ย้อนทั้งคำสั่ง: เงินฝากยัง 1,200,000 · ใบคงเดิม % ใบ · ไม่มีใบกลับรายการค้าง · ไม่มีล็อตค้าง (ถ้าแยกเป็นหลายคำสั่งจากฝั่งแอป จังหวะนี้คือยอดเป็นศูนย์)',
    v_txn0;
end $$;

-- ============================================================
-- R5 · ล็อต: แก้จำนวนหุ้น → ล็อตเดิมไม่ค้าง · ถัวเฉลี่ยตรงไฟล์ใหม่
--      ล็อตสอง 100 หุ้น (1,000 USD @37 = 37,000) → 150 หุ้น (1,500 USD @37 = 55,500)
--      → 250 หุ้น · ต้นทุน 90,500 · ถัวเฉลี่ย 362 บาท/หุ้น
-- ============================================================
do $$
declare v jsonb; v_asset uuid := '00000000-0000-0000-0000-0000000ea001';
begin
  v := sri_os.fn_reimport_opening(pg_temp.own('THANAKORN'),
         pg_temp.file_tk(1200000, pg_temp.lots(150, 1500), 90500));

  if (v ->> 'changed')::boolean is not true or (v ->> 'reversed')::int <> 2 then
    raise exception 'FAIL: R5 — ควรกลับรายการชุดเดิม 2 ใบ: %', v;
  end if;
  if sri_os.fn_asset_units(v_asset) <> 250 then
    raise exception 'FAIL: R5 — ควรเหลือ 250 หุ้น แต่ได้ % (ล็อตเดิมค้าง?)', sri_os.fn_asset_units(v_asset);
  end if;
  if sri_os.fn_asset_lot_cost(v_asset) <> 90500 then
    raise exception 'FAIL: R5 — ต้นทุนในทะเบียนควรเป็น 90,500 แต่ได้ %', sri_os.fn_asset_lot_cost(v_asset);
  end if;
  if round(sri_os.fn_asset_average_unit_cost(v_asset), 2) <> 362 then
    raise exception 'FAIL: R5 — ถัวเฉลี่ยควรเป็น 362 บาท/หุ้น แต่ได้ %',
      sri_os.fn_asset_average_unit_cost(v_asset);
  end if;
  if sri_os.fn_asset_cost_basis(v_asset) <> 90500 then
    raise exception 'FAIL: R5 — ต้นทุนในสมุดควรตรงกับทะเบียน (90,500) แต่ได้ %',
      sri_os.fn_asset_cost_basis(v_asset);
  end if;
  if (select count(*) from sri_os.asset_lots where asset_id = v_asset and reversed_by_txn_id is null) <> 2 then
    raise exception 'FAIL: R5 — ล็อตที่ยังใช้อยู่ต้องมี 2 ล็อต (ของไฟล์ใหม่)';
  end if;

  raise notice 'ok R5 · แก้จำนวนล็อต 100 → 150 หุ้น: 250 หุ้น · ต้นทุน 90,500 · ถัวเฉลี่ย 362 บาท/หุ้น · สมุด = ทะเบียน · ล็อตเดิม 4 ล็อตติดร่องรอยไว้ครบ';
end $$;

-- ============================================================
-- R6 · อัปโหลดใหม่ **หลังจากขายไปแล้ว → ปฏิเสธ**
--      (ยอดตั้งต้นคือต้นทุนที่กำไรของใบขายคิดต่อจากมัน)
-- ============================================================
do $$
declare
  v_asset uuid := '00000000-0000-0000-0000-0000000ea001';
  v_lot   uuid;
  v_txn   uuid;
  v_out   jsonb;
begin
  -- ขาย 50 หุ้น · ต้นทุนถัวเฉลี่ย 90,500 × 50/250 = 18,100 · ได้เงิน 25,000 → กำไร 6,900
  v_out := sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code', 'inv.sell_securities',
    'doc_date', '2026-05-01', 'cash_date', '2026-05-01',
    'memo', 'R6 ขายหุ้น 50 หุ้น',
    'asset_id', v_asset,
    'contact_id', '00000000-0000-0000-0000-0000000ec001',
    'attachments', jsonb_build_array('ใบขาย.pdf'),
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', pg_temp.own('THANAKORN'),
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code', '1100', 'bank_account_id', '00000000-0000-0000-0000-0000000eb001',
                           'debit', 25000, 'credit', 0, 'cf_category', 'investing'),
        jsonb_build_object('coa_code', '1700', 'asset_id', v_asset,
                           'debit', 0, 'credit', 18100, 'cf_category', 'investing'),
        jsonb_build_object('coa_code', '4900', 'asset_id', v_asset,
                           'debit', 0, 'credit', 6900, 'cf_category', 'investing'))))));
  v_txn := ((v_out -> 'transaction_ids') ->> 0)::uuid;

  select id into v_lot from sri_os.asset_lots
   where asset_id = v_asset and reversed_by_txn_id is null and quantity = 150;

  insert into sri_os.asset_lot_consumptions(lot_id, txn_id, quantity, cost_thb)
  values (v_lot, v_txn, 50, 18100);
  set constraints all immediate;
  set constraints all deferred;

  -- อัปโหลดใหม่หลังขาย → ต้องปฏิเสธ พร้อมบอกว่าใบไหนอ้างอยู่
  perform pg_temp.must_fail_like('R6 อัปโหลดใหม่หลังขายไปแล้ว', format(
    $q$ select sri_os.fn_reimport_opening(%L, %L::jsonb) $q$,
    pg_temp.own('THANAKORN'), pg_temp.file_tk(1300000, pg_temp.lots(150, 1500), 90500)),
    'มีรายการที่อ้างยอดเดิมไปแล้ว');

  -- และยอดต้องไม่ขยับจากคำสั่งที่ถูกปฏิเสธ
  if pg_temp.bal('1100', 'THANAKORN') <> 1225000 then
    raise exception 'FAIL: R6 — ยอดเงินฝากควรเป็น 1,225,000 (1,200,000 + 25,000) แต่ได้ %',
      pg_temp.bal('1100', 'THANAKORN');
  end if;
  if sri_os.fn_asset_units(v_asset) <> 200 or sri_os.fn_asset_lot_cost(v_asset) <> 72400 then
    raise exception 'FAIL: R6 — หลังขาย 50 หุ้นควรเหลือ 200 หุ้น ต้นทุน 72,400 แต่ได้ % หุ้น · % บาท',
      sri_os.fn_asset_units(v_asset), sri_os.fn_asset_lot_cost(v_asset);
  end if;

  raise notice 'ok R6 · อัปโหลดใหม่หลังขายไปแล้วถูกปฏิเสธพร้อมบอกใบที่อ้างอยู่ — ถ้าเปลี่ยนยอดตั้งต้นย้อนหลัง กำไร 6,900 ที่บันทึกไว้จะผิดโดยไม่มีใบไหนเปลี่ยน · ยอดหลังขาย: 200 หุ้น · ต้นทุน 72,400';
end $$;

-- ============================================================
-- R7 · **MUTATION** — ถอดการเทียบลายนิ้วมือออก แล้ววัดว่าสมุดบวมเท่าไร
-- ============================================================
savepoint before_fp_mutation;
do $$
declare
  v_txn0 int := pg_temp.n_txn('SUTEE');
  v_after int;
  v jsonb;
begin
  -- รุ่นกลายพันธุ์: ข้ามการเทียบลายนิ้วมือ (เหมือนลืมเทียบ) แต่ตรรกะอื่นเหมือนเดิม
  create or replace function sri_os.fn_reimport_opening_mut(p_owner uuid, p_payload jsonb) returns jsonb
  language plpgsql set search_path = sri_os, public as $m$
  declare v_old uuid[]; v_txn uuid; v_lines jsonb; v_out jsonb; v_entry jsonb;
          v_rev uuid; v_n int := 0;
  begin
    v_old := sri_os.fn_opening_set(p_owner);
    foreach v_txn in array v_old loop
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'coa_code', c.code, 'bank_account_id', l.bank_account_id, 'asset_id', l.asset_id,
               'debit', l.credit, 'credit', l.debit, 'cf_category', l.cf_category::text)))
        into v_lines
        from sri_os.transaction_lines l join sri_os.chart_of_accounts c on c.id = l.coa_id
       where l.transaction_id = v_txn;
      v_out := sri_os.fn_post_entry((
        select jsonb_strip_nulls(jsonb_build_object(
          'txn_type_code', t.txn_type_code,
          'doc_date', to_char(current_date, 'YYYY-MM-DD'),
          'cash_date', to_char(current_date, 'YYYY-MM-DD'),
          'memo', 'R7 กลายพันธุ์: กลับรายการ ' || t.id::text,
          'asset_id', t.asset_id, 'contact_id', t.contact_id, 'attachments', t.attachments,
          'source', 'reverse', 'reverses_id', t.id,
          'transactions', jsonb_build_array(jsonb_build_object('owner_id', t.owner_id, 'lines', v_lines))))
          from sri_os.transactions t where t.id = v_txn));
      v_rev := ((v_out -> 'transaction_ids') ->> 0)::uuid;
      update sri_os.asset_lots set reversed_by_txn_id = v_rev, reversed_at = now()
       where source_txn_id = v_txn and reversed_by_txn_id is null;
      v_n := v_n + 1;
    end loop;
    for v_entry in select value from jsonb_array_elements(p_payload -> 'entries') loop
      v_out := sri_os.fn_post_entry(jsonb_set(v_entry, '{memo}',
                 to_jsonb('R7 กลายพันธุ์: ลงใหม่ ' || (v_entry ->> 'memo'))));
      v_n := v_n + 1;
    end loop;
    return jsonb_build_object('changed', true, 'touched', v_n);
  end $m$;

  v := sri_os.fn_reimport_opening_mut(pg_temp.own('SUTEE'), pg_temp.file_st(250000));
  v_after := pg_temp.n_txn('SUTEE');

  if v_after <> v_txn0 + 2 then
    raise exception 'FAIL: R7 — กลายพันธุ์ไม่สำเร็จ (ใบ % → % ควรเพิ่ม 2) เคสนี้จึงไม่ได้พิสูจน์อะไร',
      v_txn0, v_after;
  end if;
  if pg_temp.bal('1100', 'SUTEE') <> 250000 then
    raise exception 'FAIL: R7 — ยอดเปลี่ยน (%) ทั้งที่ควรหักกันเป็นศูนย์', pg_temp.bal('1100', 'SUTEE');
  end if;

  raise notice 'ok R7 · MUTATION · ถอดการเทียบลายนิ้วมือ → อัปโหลดไฟล์เดิมซ้ำครั้งเดียวทำให้ใบของสุธีเพิ่มจาก % เป็น % ใบ (กลับรายการ 1 + ลงใหม่ 1 ที่หักกันเองเป็นศูนย์) · อัปโหลดสิบครั้งก็ยี่สิบใบ = ประวัติอ่านไม่รู้เรื่องและยอดไม่เปลี่ยนเลย',
    v_txn0, v_after;

  drop function sri_os.fn_reimport_opening_mut(uuid, jsonb);
end $$;
rollback to savepoint before_fp_mutation;

do $$
begin
  if to_regprocedure('sri_os.fn_reimport_opening_mut(uuid, jsonb)') is not null then
    raise exception 'FAIL: R7b — ฟังก์ชันกลายพันธุ์ยังค้างอยู่หลัง rollback';
  end if;
  if pg_temp.n_txn('SUTEE') <> 1 then
    raise exception 'FAIL: R7b — ใบของสุธีไม่กลับมาเป็น 1 ใบ (ได้ %)', pg_temp.n_txn('SUTEE');
  end if;
  raise notice 'ok R7b · ฟังก์ชันกลายพันธุ์หายไปและใบของสุธีกลับเป็น 1 ใบหลัง rollback';
end $$;

do $$ begin raise notice '=== อัปโหลดยอดตั้งต้นใหม่ ผ่านทั้งหมด ==='; end $$;

rollback;
