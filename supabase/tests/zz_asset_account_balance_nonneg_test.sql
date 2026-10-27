-- ============================================================
-- SRI OS · **ยอดคงเหลือต่อ (ทรัพย์ × บัญชี) ติดลบไม่ได้ และใบย้ายต้องย้ายทั้งก้อน**
--            (20261027161500_asset_account_balance_nonneg.sql)
--
-- ช่องที่ปิด (ผู้ตรวจวัดได้ 27/10 · BLOCK): หมวดย้ายวัตถุประสงค์อสังหาฯ ใช้ยอดที่
--   ผู้ใช้พิมพ์ → คอนโดต้นทุน 3,000,000 ถูกย้ายด้วยยอด 30,000,000 ได้
--   **ต้นทุนรวมต่อทรัพย์ไม่เปลี่ยน** จึงทั้ง fn_assert_asset_cost_sane และ
--   fn_assert_asset_whole_disposal ข้ามไปทั้งคู่ (v_removed = 0)
--   งบดุลอ่านได้ว่า "เพื่อการเช่า" = (27,000,000) · "เพื่อการขาย" = 30,000,000
--
-- สิ่งที่ไฟล์นี้พิสูจน์ (ทุกข้อมีตัวเลขที่วัดได้ ไม่ใช่ "ไม่ error")
--   N0 · โครงสร้าง: ฟังก์ชัน + constraint trigger แบบ deferred มีอยู่จริง และ
--        นิยาม "บัญชีถือครอง" ตอบถูกสองทิศ (1500/1510/1520 ใช่ · 1100/1800/1290/1200 ไม่ใช่)
--   N1 · ยอดยกมา 3,000,000 ที่ 1500 + รีโนเวท 500,000 ที่ 1510 → ต้นทุนรวม 3,500,000
--   N2 · **ย้าย 30,000,000 → ถูกปฏิเสธ** (1500 จะเหลือ −27,000,000)
--   N3 · **ย้ายบางส่วน 1,000,000 → ถูกปฏิเสธ** (ค้างสองวัตถุประสงค์พร้อมกัน)
--   N4 · ย้ายทั้งก้อน 3,000,000 → ผ่าน · 1500 = 0 · 1520 = 3,000,000 ·
--        **1510 ยังอยู่ 500,000 (ไม่ต้องย้าย)** · ต้นทุนรวมยังเป็น 3,500,000
--   N5 · ย้ายกลับทั้งก้อน → ผ่าน · 1520 = 0 · 1500 = 3,000,000
--   N6 · **ไม่กันแน่นเกิน**: ค่าเช่าค้างรับที่ผูกทรัพย์ (1200) · **เก็บเงินบางส่วน**
--        (ล้างลูกหนี้ 4,000 จาก 10,000) · ตั้งค่าเผื่อ + **ตัดหนี้สูญบางส่วน**
--        ยังทำได้ตามปกติ — บัญชีพักของตารางกฎไม่อยู่ในชุดที่ด่านนี้ตรวจ
--        (ยอดลูกหนี้เป็นเรื่องของ trg_assert_clearing_not_over)
--   N6e · บรรทัดค่าเผื่อ (1290) ที่ผูกทรัพย์ถูกปฏิเสธ **โดยด่านต้นทุนที่มีอยู่
--        ก่อนไฟล์นี้** — ยืนยันว่าสองด่านตัดสินจากชุดเดียวกัน ไม่ขัดกันเอง
--   N7 · **ใบกลับรายการยกเว้นข้อ "ย้ายทั้งก้อน"** — ย้ายทั้งก้อนแล้วซื้อเพิ่มเข้า
--        บัญชีปลายทาง แล้วกลับรายการใบย้าย → ต้องทำได้ (กฎเหล็กข้อ 1)
--   N8 · **ย้ายข้ามทรัพย์ถูกปฏิเสธ** — Cr 1500 ของคอนโด 40/D / Dr 1520 ของคอนโด 40/E
--        (ช่องที่สองของผู้ตรวจ 27/10) · ทุกบรรทัดผูกทรัพย์และบัญชีต้นทางเหลือศูนย์พอดี
--        จึงผ่านทั้งข้อ (ก) และลูป "ย้ายทั้งก้อน" ถ้าไม่มีด่าน "ทรัพย์ชิ้นเดียวกัน"
--   M1 · MUTATION: ให้ fn_asset_cost_coa() คืน false ทุกบัญชี → **ใบ 30,000,000
--        ลงได้ทันที** (พิสูจน์ว่า N2 แดงเพราะนิยามชุดบัญชีตัวนี้ ไม่ใช่เพราะอย่างอื่น)
--   M2 · MUTATION: ปิด trigger → ใบ 30,000,000 **ลงได้** และ 1500 = −27,000,000
--        (พิสูจน์ว่า N2 วัดด่านตัวนี้จริง ไม่ได้เขียวเพราะด่านอื่น)
--   M3 · MUTATION: ปิด trigger → ใบย้ายข้ามทรัพย์ของ N8 **ลงได้** และวัดได้ว่า
--        ต้นทุนของ 40/D หายทั้งก้อน (2,000,000 → 0) · ของ 40/E โป่ง
--        (1,000,000 → 3,000,000) · **ต้นทุนรวมสองชิ้นเท่าเดิม 3,000,000**
--        ซึ่งคือเหตุที่ด่านต้นทุนเดิมทั้งสองตัวมองไม่เห็น
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ **rollback** ปิดท้าย — ไม่ทิ้งรายการเงินไว้
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
create temporary table nn_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into nn_uid(label) values ('mgmt');
insert into auth.users(id) select id from nn_uid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, 'balance-nonneg@local', 'mgmt', 'management', true from nn_uid u;
select set_config('test.uid', (select id::text from nn_uid where label = 'mgmt'), true);

insert into sri_os.user_owner_access(user_id, owner_id)
select (select id from nn_uid where label = 'mgmt'), o.id from sri_os.owners o;

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
values ('00000000-0000-0000-0000-0000000be001',
        (select id from sri_os.owners where code = 'THANAKORN'),
        'KBANK', 'ธนากร', 'ธนากร - KBANK (ยอดติดลบต่อทรัพย์)');

insert into sri_os.contacts(id, first_name, last_name, types)
values ('00000000-0000-0000-0000-0000000be0c1', 'ผู้เช่าทดสอบ', 'ยอดติดลบต่อทรัพย์', array['tenant']);

-- ทรัพย์ทดสอบ — แยกชิ้นต่อฉาก เพื่อให้แต่ละเคสวัดยอดของตัวเองได้ไม่ปนกัน
insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, currency)
select x.id, x.code, x.name, ct.class_id, ct.id,
       (select id from sri_os.owners where code = 'THANAKORN'), 'THB'
  from (values
    ('00000000-0000-0000-0000-0000000be0a1'::uuid, 'NN-CONDO-MOVE',  'คอนโด ห้อง 40/A (ย้ายวัตถุประสงค์)', 'RE_RENTAL'),
    ('00000000-0000-0000-0000-0000000be0a2'::uuid, 'NN-CONDO-RECV',  'คอนโด ห้อง 40/B (ค่าเช่า/ค่าเผื่อ)',  'RE_RENTAL'),
    ('00000000-0000-0000-0000-0000000be0a3'::uuid, 'NN-CONDO-REV',   'คอนโด ห้อง 40/C (กลับรายการ)',       'RE_RENTAL'),
    -- คู่ของเคสย้าย **ข้ามทรัพย์** (N8/M3) — ต้องเป็นสองชิ้นจริง ไม่ใช่ชิ้นเดียวสองบัญชี
    ('00000000-0000-0000-0000-0000000be0a4'::uuid, 'NN-CONDO-XFR-A', 'คอนโด ห้อง 40/D (ต้นทางข้ามทรัพย์)', 'RE_RENTAL'),
    ('00000000-0000-0000-0000-0000000be0a5'::uuid, 'NN-CONDO-XFR-B', 'คอนโด ห้อง 40/E (ปลายทางข้ามทรัพย์)', 'RE_RENTAL')
  ) as x(id, code, name, cat_code)
  join sri_os.asset_categories ct on ct.code = x.cat_code;

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
                                         p_memo text, p_asset uuid, p_lines jsonb,
                                         p_contact uuid default null,
                                         p_source text default null,
                                         p_reverses uuid default null)
returns jsonb language sql stable as $fn$
  select jsonb_strip_nulls(jsonb_build_object(
    'txn_type_code', p_type,
    'doc_date', p_doc::text,
    'cash_date', case when p_cash is null then null else p_cash::text end,
    'memo', p_memo,
    'asset_id', p_asset,
    'contact_id', p_contact,
    'source', p_source,
    'reverses_id', p_reverses,
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', pg_temp.owner(), 'lines', p_lines))));
$fn$;

/**
 * post แล้ว **บังคับให้ด่านที่เลื่อนไว้ยิงทันที**
 *
 * ด่านของไฟล์นี้เป็น constraint trigger แบบ deferred — ถ้าไม่บังคับ มันจะยิง
 * ตอน commit ซึ่งไม่เกิดขึ้นในเทสต์ที่ rollback ทิ้ง แล้วเคส "ต้องถูกปฏิเสธ"
 * จะเขียวด้วยเหตุผลผิด (บทเรียนเดียวกับ pg_temp.consume ของ zz_asset_cost_basis_mode)
 */
create or replace function pg_temp.post(p_payload jsonb) returns uuid
language plpgsql as $fn$
declare v jsonb;
begin
  v := sri_os.fn_post_entry(p_payload);
  if (v ->> 'replayed')::boolean then
    raise exception 'FAIL: fn_post_entry ถือว่าใบนี้เป็นการกดซ้ำ (memo ของแต่ละใบต้องไม่ซ้ำกัน)';
  end if;
  set constraints all immediate;
  set constraints all deferred;
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

/** ยอดในบัญชีหนึ่งของทรัพย์ชิ้นหนึ่ง — **คิดเองในเทสต์** ไม่ถามฟังก์ชันที่กำลังทดสอบ */
create or replace function pg_temp.book(p_asset uuid, p_coa text) returns numeric
language sql stable as $fn$
  select coalesce(sum(l.debit - l.credit), 0)
    from sri_os.transaction_lines l
    join sri_os.transactions t on t.id = l.transaction_id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where l.asset_id = p_asset and t.status = 'posted' and c.code = p_coa;
$fn$;

/** ลงยอดยกมาของทรัพย์ชิ้นหนึ่ง ผูกทรัพย์ */
create or replace function pg_temp.open_asset(p_asset uuid, p_type text, p_coa text,
                                              p_amount numeric, p_memo text) returns uuid
language sql as $fn$
  select pg_temp.post(pg_temp.entry(p_type, '2026-01-01', null, p_memo, p_asset,
    jsonb_build_array(
      pg_temp.ln(p_coa, p_amount, 0, p_asset, 'none'),
      pg_temp.ln('3300', 0, p_amount, null, 'none'))));
$fn$;

/** ใบย้ายวัตถุประสงค์ — ยอดเป็นพารามิเตอร์ เพราะนั่นคือสิ่งที่กำลังทดสอบ */
create or replace function pg_temp.reclass(p_asset uuid, p_type text, p_dr text, p_cr text,
                                           p_amount numeric, p_memo text) returns uuid
language sql as $fn$
  select pg_temp.post(pg_temp.entry(p_type, '2026-06-01', null, p_memo, p_asset,
    jsonb_build_array(
      pg_temp.ln(p_dr, p_amount, 0, p_asset, 'none'),
      pg_temp.ln(p_cr, 0, p_amount, p_asset, 'none'))));
$fn$;

/**
 * ใบย้าย **ข้ามทรัพย์** — ขาเครดิตเป็นทรัพย์ชิ้นหนึ่ง ขาเดบิตเป็นอีกชิ้นหนึ่ง
 * (รูปของช่องที่ผู้ตรวจเจอ 27/10) · ทุกบรรทัดยังผูกทรัพย์ และบัญชีต้นทางยังเหลือ
 * ศูนย์พอดี จึงผ่านทั้งข้อ (ก) และลูป "ย้ายทั้งก้อน" ถ้าไม่มีด่าน "ชิ้นเดียวกัน"
 */
create or replace function pg_temp.reclass_cross(p_src uuid, p_dst uuid, p_type text,
                                                 p_dr text, p_cr text, p_amount numeric,
                                                 p_memo text) returns uuid
language sql as $fn$
  select pg_temp.post(pg_temp.entry(p_type, '2026-09-01', null, p_memo, p_src,
    jsonb_build_array(
      pg_temp.ln(p_dr, p_amount, 0, p_dst, 'none'),
      pg_temp.ln(p_cr, 0, p_amount, p_src, 'none'))));
$fn$;

-- ============================================================
-- N0 · โครงสร้าง — ไล่จาก catalog จริง ไม่ใช่ไล่ไฟล์
-- ============================================================
do $$
declare v_code text;
begin
  if to_regprocedure('sri_os.fn_asset_account_balance(uuid,text,uuid)') is null
     or to_regprocedure('sri_os.fn_asset_cost_coa(text)') is null
     or to_regprocedure('sri_os.fn_assert_asset_account_balance_nonneg()') is null then
    raise exception 'FAIL: N0 — ฟังก์ชันของด่านไม่ครบ (migration ไม่ถูก apply?) เทสต์นี้จะไม่ได้ตรวจอะไร';
  end if;

  if not exists (select 1 from pg_trigger g
                  join pg_proc p on p.oid = g.tgfoid
                 where g.tgrelid = 'sri_os.transaction_lines'::regclass
                   and g.tgname = 'trg_assert_asset_account_balance_nonneg'
                   and p.proname = 'fn_assert_asset_account_balance_nonneg'
                   and g.tgdeferrable and g.tginitdeferred and not g.tgisinternal) then
    raise exception 'FAIL: N0 — ไม่มี constraint trigger trg_assert_asset_account_balance_nonneg แบบ deferrable initially deferred';
  end if;

  /* สองทิศของนิยาม "บัญชีต้นทุนรายทรัพย์" — ต้องเป็น **ชุดเดียวกับ is_cost_account
   * ของ fn_asset_ledger_parts** (20261025000002) ไม่งั้นด่านต้นทุนกับด่านนี้
   * ตัดสินคนละชุด · 1290 อยู่ฝั่ง "ใช่" เพราะฟังก์ชันนั้นนับมันเหมือนกัน (ดู N6e)
   */
  foreach v_code in array array['1500', '1510', '1520', '1700', '1720', '1290'] loop
    if not sri_os.fn_asset_cost_coa(v_code) then
      raise exception 'FAIL: N0 — fn_asset_cost_coa(%) = false ทั้งที่ fn_asset_ledger_parts นับเป็นต้นทุนของทรัพย์ → ด่านสองตัวตัดสินคนละชุด', v_code;
    end if;
  end loop;
  foreach v_code in array array['1100', '1800', '1200', '1210', '1220', '3300', '3400', '4200', '5920'] loop
    if sri_os.fn_asset_cost_coa(v_code) then
      raise exception 'FAIL: N0 — fn_asset_cost_coa(%) = true ทั้งที่ไม่ใช่บัญชีต้นทุนรายทรัพย์ → ด่านจะปฏิเสธรายการที่ถูกต้อง', v_code;
    end if;
  end loop;

  raise notice 'ok N0 · ด่าน + ฟังก์ชันครบ · นิยามบัญชีต้นทุนรายทรัพย์ตอบถูกสองทิศ (ชุดเดียวกับ fn_asset_ledger_parts)';
end $$;

-- ============================================================
-- N1 · ยอดยกมา 3,000,000 ที่ 1500 + รีโนเวท 500,000 ที่ 1510
-- ============================================================
do $$
declare v_cost numeric;
begin
  perform pg_temp.open_asset('00000000-0000-0000-0000-0000000be0a1', 'opn.property', '1500',
                             3000000, 'N1 ยอดยกมาคอนโด 40/A 3,000,000');
  perform pg_temp.must_pass('N1 รีโนเวท 500,000', format($q$
    select pg_temp.post(pg_temp.entry('inv.capex', '2026-02-01', '2026-02-01',
      'N1 รีโนเวทคอนโด 40/A 500,000', %L,
      jsonb_build_array(
        pg_temp.ln('1510', 500000, 0, %L, 'investing'),
        pg_temp.ln('1100', 0, 500000, null, 'investing', %L))))
    $q$, '00000000-0000-0000-0000-0000000be0a1',
         '00000000-0000-0000-0000-0000000be0a1', '00000000-0000-0000-0000-0000000be001'));

  if pg_temp.book('00000000-0000-0000-0000-0000000be0a1', '1500') <> 3000000 then
    raise exception 'FAIL: N1 — 1500 ต้องเป็น 3,000,000 แต่ได้ %',
      pg_temp.book('00000000-0000-0000-0000-0000000be0a1', '1500');
  end if;
  v_cost := sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-0000000be0a1');
  if v_cost <> 3500000 then
    raise exception 'FAIL: N1 — ต้นทุนรวมต้องเป็น 3,500,000 แต่ได้ %', v_cost;
  end if;
  -- ฟังก์ชันที่ฟอร์มต้องใช้อ่านยอดต้นทาง ต้องตอบตรงกับที่เทสต์คิดเอง
  if sri_os.fn_asset_account_balance('00000000-0000-0000-0000-0000000be0a1', '1500') <> 3000000 then
    raise exception 'FAIL: N1 — fn_asset_account_balance ตอบยอด 1500 ไม่ตรงกับสมุด (%)',
      sri_os.fn_asset_account_balance('00000000-0000-0000-0000-0000000be0a1', '1500');
  end if;
  raise notice 'ok N1 · 1500 = 3,000,000 · 1510 = 500,000 · ต้นทุนรวม 3,500,000';
end $$;

-- ============================================================
-- N2 · ย้าย 30,000,000 (ฉากของผู้ตรวจ) → ต้องถูกปฏิเสธ
-- ============================================================
do $$
begin
  perform pg_temp.must_fail_like('N2 ย้าย 30,000,000 จากยอด 3,000,000', format($q$
    select pg_temp.reclass(%L, 'adj.reclass_re_to_sale', '1520', '1500', 30000000,
      'N2 ย้ายเกินยอด 30,000,000')
    $q$, '00000000-0000-0000-0000-0000000be0a1'), 'ติดลบ');

  -- สมุดต้องไม่เปลี่ยนเลยหลังถูกปฏิเสธ
  if pg_temp.book('00000000-0000-0000-0000-0000000be0a1', '1500') <> 3000000
     or pg_temp.book('00000000-0000-0000-0000-0000000be0a1', '1520') <> 0 then
    raise exception 'FAIL: N2 — ใบที่ถูกปฏิเสธยังทิ้งผลไว้ในสมุด (1500 = % · 1520 = %)',
      pg_temp.book('00000000-0000-0000-0000-0000000be0a1', '1500'),
      pg_temp.book('00000000-0000-0000-0000-0000000be0a1', '1520');
  end if;
  raise notice 'ok N2 · ย้ายเกินยอดที่ถืออยู่ถูกปฏิเสธ (บัญชีต้นทางจะติดลบ 27,000,000)';
end $$;

-- ============================================================
-- N3 · ย้ายบางส่วน 1,000,000 จาก 3,000,000 → ต้องถูกปฏิเสธ
-- ============================================================
do $$
begin
  perform pg_temp.must_fail_like('N3 ย้ายบางส่วน', format($q$
    select pg_temp.reclass(%L, 'adj.reclass_re_to_sale', '1520', '1500', 1000000,
      'N3 ย้ายบางส่วน 1,000,000')
    $q$, '00000000-0000-0000-0000-0000000be0a1'), 'ทั้งก้อน');
  raise notice 'ok N3 · ย้ายบางส่วนถูกปฏิเสธ (ทรัพย์ชิ้นเดียวค้างสองวัตถุประสงค์ไม่ได้)';
end $$;

-- ============================================================
-- N4 · ย้ายทั้งก้อน → ผ่าน · 1510 ไม่ต้องย้าย · ต้นทุนรวมไม่เปลี่ยน
-- ============================================================
do $$
declare v_cost numeric;
begin
  perform pg_temp.must_pass('N4 ย้ายทั้งก้อน 3,000,000', format($q$
    select pg_temp.reclass(%L, 'adj.reclass_re_to_sale', '1520', '1500', 3000000,
      'N4 ย้ายทั้งก้อนไปเพื่อการขาย')
    $q$, '00000000-0000-0000-0000-0000000be0a1'));

  if pg_temp.book('00000000-0000-0000-0000-0000000be0a1', '1500') <> 0 then
    raise exception 'FAIL: N4 — 1500 ต้องเหลือ 0 แต่ได้ %',
      pg_temp.book('00000000-0000-0000-0000-0000000be0a1', '1500');
  end if;
  if pg_temp.book('00000000-0000-0000-0000-0000000be0a1', '1520') <> 3000000 then
    raise exception 'FAIL: N4 — 1520 ต้องเป็น 3,000,000 แต่ได้ %',
      pg_temp.book('00000000-0000-0000-0000-0000000be0a1', '1520');
  end if;
  -- **ค่ารีโนเวทใช้บัญชีเดียวกันทั้งสองวัตถุประสงค์ → ไม่ต้องย้ายตาม**
  if pg_temp.book('00000000-0000-0000-0000-0000000be0a1', '1510') <> 500000 then
    raise exception 'FAIL: N4 — 1510 ต้องยังเป็น 500,000 (ไม่ต้องย้าย) แต่ได้ %',
      pg_temp.book('00000000-0000-0000-0000-0000000be0a1', '1510');
  end if;
  v_cost := sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-0000000be0a1');
  if v_cost <> 3500000 then
    raise exception 'FAIL: N4 — การย้ายต้องไม่เปลี่ยนต้นทุนรวม (ต้อง 3,500,000 ได้ %)', v_cost;
  end if;
  raise notice 'ok N4 · ย้ายทั้งก้อนได้ · 1500 = 0 · 1520 = 3,000,000 · 1510 คงเดิม · ต้นทุนรวมเท่าเดิม';
end $$;

-- ============================================================
-- N5 · ย้ายกลับทั้งก้อน (ทิศตรงข้าม) → ผ่าน
-- ============================================================
do $$
begin
  perform pg_temp.must_pass('N5 ย้ายกลับทั้งก้อน', format($q$
    select pg_temp.reclass(%L, 'adj.reclass_re_to_rental', '1500', '1520', 3000000,
      'N5 เลิกขาย ย้ายกลับไปให้เช่า')
    $q$, '00000000-0000-0000-0000-0000000be0a1'));

  if pg_temp.book('00000000-0000-0000-0000-0000000be0a1', '1520') <> 0
     or pg_temp.book('00000000-0000-0000-0000-0000000be0a1', '1500') <> 3000000 then
    raise exception 'FAIL: N5 — ย้ายกลับแล้ว 1520 ต้องเป็น 0 และ 1500 ต้องเป็น 3,000,000 (ได้ % · %)',
      pg_temp.book('00000000-0000-0000-0000-0000000be0a1', '1520'),
      pg_temp.book('00000000-0000-0000-0000-0000000be0a1', '1500');
  end if;
  raise notice 'ok N5 · ย้ายกลับทั้งก้อนได้ทั้งสองทิศ';
end $$;

-- ============================================================
-- N6 · **ไม่กันแน่นเกิน** — ค่าเช่าค้างรับ · เก็บเงินบางส่วน · ค่าเผื่อ · ตัดหนี้สูญบางส่วน
--      ทุกใบในชุดนี้เป็นเส้นทางที่ถูกต้องและต้องลงได้ตามปกติ
-- ============================================================
do $$
begin
  -- ค่าเช่าค้างรับ 10,000 (Dr 1200 / Cr 4200) **ผูกทรัพย์** (D-112 ข้อ 4)
  perform pg_temp.must_pass('N6a ตั้งค่าเช่าค้างรับ', format($q$
    select pg_temp.post(pg_temp.entry('inc.rent', '2026-03-01', null,
      'N6 ค่าเช่าค้างรับคอนโด 40/B 10,000', %L,
      jsonb_build_array(
        pg_temp.ln('1200', 10000, 0, %L, 'none'),
        pg_temp.ln('4200', 0, 10000, %L, 'none')), %L))
    $q$, '00000000-0000-0000-0000-0000000be0a2', '00000000-0000-0000-0000-0000000be0a2',
         '00000000-0000-0000-0000-0000000be0a2', '00000000-0000-0000-0000-0000000be0c1'));

  -- **เก็บเงินบางส่วน** 4,000 → ลูกหนี้ของทรัพย์เหลือ 6,000 (ต้องไม่ถูกบังคับให้ล้างทั้งก้อน)
  perform pg_temp.must_pass('N6b เก็บค่าเช่าค้างรับบางส่วน', format($q$
    select pg_temp.post(pg_temp.entry('inv.collect_rent', '2026-03-15', '2026-03-15',
      'N6 เก็บค่าเช่าค้างรับ 4,000', %L,
      jsonb_build_array(
        pg_temp.ln('1100', 4000, 0, null, 'operating', %L),
        pg_temp.ln('1200', 0, 4000, %L, 'operating')), %L))
    $q$, '00000000-0000-0000-0000-0000000be0a2', '00000000-0000-0000-0000-0000000be001',
         '00000000-0000-0000-0000-0000000be0a2', '00000000-0000-0000-0000-0000000be0c1'));

  if pg_temp.book('00000000-0000-0000-0000-0000000be0a2', '1200') <> 6000 then
    raise exception 'FAIL: N6b — ลูกหนี้ค่าเช่าของทรัพย์ต้องเหลือ 6,000 แต่ได้ %',
      pg_temp.book('00000000-0000-0000-0000-0000000be0a2', '1200');
  end if;

  -- ตั้งค่าเผื่อ 5,000 แล้วตัดหนี้สูญบางส่วน 2,000 — **ไม่ผูกทรัพย์** (รูปที่ตารางกฎบังคับ:
  -- หมวดค่าเผื่อ/ตัดหนี้สูญบังคับแค่คู่ค้า) · ยอด 1290 ปกติอยู่ฝั่งเครดิต
  perform pg_temp.must_pass('N6c ตั้งค่าเผื่อหนี้สงสัยจะสูญ', format($q$
    select pg_temp.post(pg_temp.entry('adj.doubtful', '2026-04-01', null,
      'N6 ตั้งค่าเผื่อ 5,000', null,
      jsonb_build_array(
        pg_temp.ln('5920', 5000, 0, null, 'none'),
        pg_temp.ln('1290', 0, 5000, null, 'none')), %L))
    $q$, '00000000-0000-0000-0000-0000000be0c1'));

  perform pg_temp.must_pass('N6d ตัดหนี้สูญบางส่วน', format($q$
    select pg_temp.post(pg_temp.entry('adj.writeoff_rent', '2026-05-01', null,
      'N6 ตัดหนี้สูญบางส่วน 2,000', null,
      jsonb_build_array(
        pg_temp.ln('1290', 2000, 0, null, 'none'),
        pg_temp.ln('1200', 0, 2000, null, 'none')), %L))
    $q$, '00000000-0000-0000-0000-0000000be0c1'));

  raise notice 'ok N6 · ค่าเช่าค้างรับ · เก็บเงินบางส่วน (ลูกหนี้เหลือ 6,000) · ค่าเผื่อ · ตัดหนี้สูญบางส่วน ยังทำได้ตามปกติ';
end $$;

-- ============================================================
-- N6e · บรรทัดค่าเผื่อที่ **ผูกทรัพย์** ถูกปฏิเสธโดยด่านต้นทุนที่มีอยู่ก่อนไฟล์นี้
--       (fn_assert_asset_cost_sane · 20261025000002) — ไฟล์นี้จึงนับ 1290 เป็น
--       บัญชีต้นทุนเหมือนกัน เพื่อให้สองด่านตัดสินจากชุดเดียวกัน ไม่ใช่คนละชุด
-- ============================================================
do $$
begin
  perform pg_temp.must_fail_like('N6e ตั้งค่าเผื่อโดยผูกทรัพย์', format($q$
    select pg_temp.post(pg_temp.entry('adj.doubtful', '2026-04-05', null,
      'N6e ตั้งค่าเผื่อ 1,000 โดยผูกทรัพย์', %L,
      jsonb_build_array(
        pg_temp.ln('5920', 1000, 0, null, 'none'),
        pg_temp.ln('1290', 0, 1000, %L, 'none')), %L))
    $q$, '00000000-0000-0000-0000-0000000be0a2', '00000000-0000-0000-0000-0000000be0a2',
         '00000000-0000-0000-0000-0000000be0c1'), 'ติดลบ');
  raise notice 'ok N6e · ค่าเผื่อที่ผูกทรัพย์ถูกปฏิเสธอยู่แล้วก่อนไฟล์นี้ (ด่านสองตัวใช้ชุดบัญชีเดียวกัน)';
end $$;

-- ============================================================
-- N7 · ใบกลับรายการยกเว้นข้อ "ย้ายทั้งก้อน" (กฎเหล็กข้อ 1)
--      ย้ายทั้งก้อน → ซื้อเพิ่มเข้าบัญชีปลายทาง → กลับรายการใบย้าย
--      ถ้าไม่ยกเว้น ใบกลับรายการจะลงไม่ได้ = แก้ของที่ลงผิดไม่ได้
-- ============================================================
do $$
declare v_move uuid;
begin
  perform pg_temp.open_asset('00000000-0000-0000-0000-0000000be0a3', 'opn.property', '1500',
                             2000000, 'N7 ยอดยกมาคอนโด 40/C 2,000,000');

  v_move := pg_temp.reclass('00000000-0000-0000-0000-0000000be0a3', 'adj.reclass_re_to_sale',
                            '1520', '1500', 2000000, 'N7 ย้ายทั้งก้อนไปเพื่อการขาย');

  perform pg_temp.must_pass('N7 ซื้อเพิ่มเข้าบัญชีปลายทาง', format($q$
    select pg_temp.post(pg_temp.entry('inv.buy_re_held_for_sale', '2026-07-01', '2026-07-01',
      'N7 ซื้อส่วนเพิ่มเข้า 1520 500,000', %L,
      jsonb_build_array(
        pg_temp.ln('1520', 500000, 0, %L, 'investing'),
        pg_temp.ln('1100', 0, 500000, null, 'investing', %L))))
    $q$, '00000000-0000-0000-0000-0000000be0a3',
         '00000000-0000-0000-0000-0000000be0a3', '00000000-0000-0000-0000-0000000be001'));

  -- ใบกลับรายการ = ภาพกระจกของใบย้าย (Dr 1500 / Cr 1520) · 1520 จะเหลือ 500,000 ไม่ใช่ 0
  perform pg_temp.must_pass('N7 กลับรายการใบย้าย', format($q$
    select pg_temp.post(pg_temp.entry('adj.reclass_re_to_sale', '2026-08-01', null,
      'N7 กลับรายการใบย้าย', %L,
      jsonb_build_array(
        pg_temp.ln('1500', 2000000, 0, %L, 'none'),
        pg_temp.ln('1520', 0, 2000000, %L, 'none')), null, 'reverse', %L))
    $q$, '00000000-0000-0000-0000-0000000be0a3', '00000000-0000-0000-0000-0000000be0a3',
         '00000000-0000-0000-0000-0000000be0a3', v_move));

  if pg_temp.book('00000000-0000-0000-0000-0000000be0a3', '1520') <> 500000
     or pg_temp.book('00000000-0000-0000-0000-0000000be0a3', '1500') <> 2000000 then
    raise exception 'FAIL: N7 — หลังกลับรายการ 1520 ต้องเหลือ 500,000 และ 1500 ต้องเป็น 2,000,000 (ได้ % · %)',
      pg_temp.book('00000000-0000-0000-0000-0000000be0a3', '1520'),
      pg_temp.book('00000000-0000-0000-0000-0000000be0a3', '1500');
  end if;
  raise notice 'ok N7 · ใบกลับรายการลงได้แม้บัญชีปลายทางไม่เหลือศูนย์ (ข้อ ก ยังบังคับอยู่)';
end $$;

-- ============================================================
-- N8 · ย้าย **ข้ามทรัพย์** (Cr ทรัพย์ A / Dr ทรัพย์ B) → ต้องถูกปฏิเสธ
--
--      ฉาก: คอนโด 40/D ต้นทุน 2,000,000 ที่ 1500 · คอนโด 40/E ต้นทุน 1,000,000 ที่ 1520
--      ใบ Dr 1520 ของ 40/E 2,000,000 / Cr 1500 ของ 40/D 2,000,000
--        - ข้อ (ก) ไม่ฟ้อง: ไม่มีบัญชีไหนติดลบ (1500 ของ 40/D เหลือ 0 พอดี)
--        - ลูป "ย้ายทั้งก้อน" ไม่ฟ้อง: บัญชีต้นทางของ 40/D เหลือศูนย์พอดี
--        - ด่านต้นทุนสองตัวไม่ฟ้อง: ฝั่ง 40/D เหมือนตัดออกครบ ฝั่ง 40/E เหมือนซื้อเข้า
--      → ต้องถูกปฏิเสธด้วยด่าน "ทุกบรรทัดต้องเป็นทรัพย์ชิ้นเดียวกัน" เท่านั้น
--      (M3 ข้างล่างวัดความเสียหายจริงตอนปิดด่าน)
-- ============================================================
do $$
begin
  perform pg_temp.open_asset('00000000-0000-0000-0000-0000000be0a4', 'opn.property', '1500',
                             2000000, 'N8 ยอดยกมาคอนโด 40/D 2,000,000');
  perform pg_temp.open_asset('00000000-0000-0000-0000-0000000be0a5', 'opn.property_held_for_sale',
                             '1520', 1000000, 'N8 ยอดยกมาคอนโด 40/E 1,000,000');

  perform pg_temp.must_fail_like('N8 ย้ายข้ามทรัพย์', format($q$
    select pg_temp.reclass_cross(%L, %L, 'adj.reclass_re_to_sale', '1520', '1500', 2000000,
      'N8 ย้ายข้ามทรัพย์ 2,000,000')
    $q$, '00000000-0000-0000-0000-0000000be0a4', '00000000-0000-0000-0000-0000000be0a5'),
    'ชิ้นเดียวกันทุกบรรทัด');

  -- สมุดต้องไม่เปลี่ยนเลยหลังถูกปฏิเสธ
  if pg_temp.book('00000000-0000-0000-0000-0000000be0a4', '1500') <> 2000000
     or pg_temp.book('00000000-0000-0000-0000-0000000be0a5', '1520') <> 1000000 then
    raise exception 'FAIL: N8 — ใบที่ถูกปฏิเสธยังทิ้งผลไว้ในสมุด (40/D 1500 = % · 40/E 1520 = %)',
      pg_temp.book('00000000-0000-0000-0000-0000000be0a4', '1500'),
      pg_temp.book('00000000-0000-0000-0000-0000000be0a5', '1520');
  end if;

  -- (การย้ายทั้งก้อน **ภายในทรัพย์ชิ้นเดียวกัน** ยังทำได้ — N4/N5 วัดไว้แล้วทั้งสองทิศ
  --  ที่นี่ไม่ย้ายซ้ำ เพื่อให้ฉากของ M3 เริ่มจากยอดเดียวกับที่ N8 เพิ่งถูกปฏิเสธ)

  raise notice 'ok N8 · ย้ายข้ามทรัพย์ถูกปฏิเสธ (ทุกบรรทัดต้องเป็นทรัพย์ชิ้นเดียวกัน)';
end $$;

-- ============================================================
-- M1 · MUTATION — ให้ fn_asset_cost_coa() คืน false ทุกบัญชี
--      → ใบ 30,000,000 **ลงได้ทันที** (ด่านไม่เห็นบัญชี 1500 อีกแล้ว)
--      พิสูจน์ว่า N2 แดงเพราะนิยามชุดบัญชีตัวนี้ ไม่ใช่เพราะด่านอื่น
-- ============================================================
savepoint before_scope_mutation;
do $$
declare v_bal numeric;
begin
  create or replace function sri_os.fn_asset_cost_coa(p_code text) returns boolean
  language sql immutable set search_path = '' as $m$ select false; $m$;

  perform pg_temp.must_pass('M1 ย้ายเกินยอดขณะชุดบัญชีว่าง', format($q$
    select pg_temp.reclass(%L, 'adj.reclass_re_to_sale', '1520', '1500', 30000000,
      'M1 ย้ายเกินยอด 30,000,000 ขณะชุดบัญชีว่าง')
    $q$, '00000000-0000-0000-0000-0000000be0a1'));

  v_bal := pg_temp.book('00000000-0000-0000-0000-0000000be0a1', '1500');
  if v_bal <> -27000000 then
    raise exception 'FAIL: M1 — ชุดบัญชีว่างแล้วยอด 1500 ต้องเป็น −27,000,000 แต่ได้ %', v_bal;
  end if;
  raise notice 'ok M1 · นิยามชุดบัญชีเป็นของที่ด่านอ่านจริง (ชุดว่าง = ช่องเดิมกลับมา · 1500 = −27,000,000)';
end $$;
rollback to savepoint before_scope_mutation;

do $$
begin
  -- rollback คืนทั้งฟังก์ชันและใบที่ลงไป — ยืนยันทั้งสองอย่าง
  if not sri_os.fn_asset_cost_coa('1500') then
    raise exception 'FAIL: M1b — ฟังก์ชันตัวจริงไม่กลับมาหลัง rollback';
  end if;
  if pg_temp.book('00000000-0000-0000-0000-0000000be0a1', '1500') <> 3000000 then
    raise exception 'FAIL: M1b — ใบของ mutation ยังค้างอยู่ในสมุด (1500 = %)',
      pg_temp.book('00000000-0000-0000-0000-0000000be0a1', '1500');
  end if;
  raise notice 'ok M1b · ด่านตัวจริงกลับมาและไม่มีใบของ mutation ค้างในสมุด';
end $$;

-- ============================================================
-- M3 · MUTATION — ปิดด่านแล้วใบ **ย้ายข้ามทรัพย์** ของ N8 ต้องลงได้
--      และความเสียหายต้องวัดได้เป็นตัวเลข:
--        ต้นทุนของ 40/D **หายทั้งก้อน** (2,000,000 → 0)
--        ต้นทุนของ 40/E **โป่ง** (1,000,000 → 3,000,000)
--        ต้นทุนรวมของสองชิ้น **เท่าเดิม** (3,000,000) ← เหตุที่ไม่มีด่านไหนฟ้อง
--      ถ้าปิดด่านแล้วยังลงไม่ได้ แปลว่า N8 เขียวเพราะด่านอื่น ไม่ใช่ด่านของไฟล์นี้
--      (วางใน savepoint แล้วย้อนทิ้ง เพราะ M2 ข้างล่างต้องเริ่มจากสมุดที่ยังถูก)
-- ============================================================
savepoint before_cross_asset_mutation;
do $$
declare v_a numeric; v_b numeric;
begin
  alter table sri_os.transaction_lines
    disable trigger trg_assert_asset_account_balance_nonneg;

  perform pg_temp.must_pass('M3 ย้ายข้ามทรัพย์ขณะปิดด่าน', format($q$
    select pg_temp.reclass_cross(%L, %L, 'adj.reclass_re_to_sale', '1520', '1500', 2000000,
      'M3 ย้ายข้ามทรัพย์ 2,000,000 ขณะปิดด่าน')
    $q$, '00000000-0000-0000-0000-0000000be0a4', '00000000-0000-0000-0000-0000000be0a5'));

  v_a := sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-0000000be0a4');
  v_b := sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-0000000be0a5');
  if v_a <> 0 then
    raise exception 'FAIL: M3 — ปิดด่านแล้วต้นทุนของ 40/D ต้องหายทั้งก้อน (0) แต่ได้ % — ฉากนี้ไม่ใช่ฉากที่ N8 กัน', v_a;
  end if;
  if v_b <> 3000000 then
    raise exception 'FAIL: M3 — ต้นทุนของ 40/E ต้องโป่งเป็น 3,000,000 แต่ได้ %', v_b;
  end if;
  if round(v_a + v_b, 2) <> 3000000 then
    raise exception 'FAIL: M3 — ต้นทุนรวมสองชิ้นต้องเท่าเดิม (3,000,000) แต่ได้ % — ถ้าเปลี่ยน แปลว่าฉากนี้ด่านต้นทุนเดิมมองเห็นเอง ไม่ใช่ช่องที่ต้องกันด้วยด่านนี้',
      round(v_a + v_b, 2);
  end if;
  -- รายบัญชีก็อ่านได้ว่าทรัพย์คนละชิ้นสลับต้นทุนกัน โดยไม่มีบัญชีไหนติดลบ (ข้อ ก จึงไม่ฟ้อง)
  if pg_temp.book('00000000-0000-0000-0000-0000000be0a4', '1500') <> 0
     or pg_temp.book('00000000-0000-0000-0000-0000000be0a5', '1520') <> 3000000 then
    raise exception 'FAIL: M3 — รายบัญชีไม่ตรงฉาก (40/D 1500 = % · 40/E 1520 = %)',
      pg_temp.book('00000000-0000-0000-0000-0000000be0a4', '1500'),
      pg_temp.book('00000000-0000-0000-0000-0000000be0a5', '1520');
  end if;

  alter table sri_os.transaction_lines
    enable trigger trg_assert_asset_account_balance_nonneg;

  raise notice 'ok M3 · ปิดด่าน = ต้นทุนของ 40/D หายทั้งก้อนไปโป่งที่ 40/E โดยต้นทุนรวมยังเป็น 3,000,000';
end $$;
rollback to savepoint before_cross_asset_mutation;

do $$
begin
  if sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-0000000be0a4') <> 2000000
     or sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-0000000be0a5') <> 1000000 then
    raise exception 'FAIL: M3b — ใบของ mutation ยังค้างอยู่ในสมุด (40/D = % · 40/E = %)',
      sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-0000000be0a4'),
      sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-0000000be0a5');
  end if;
  raise notice 'ok M3b · ไม่มีใบของ mutation ค้างในสมุดหลัง rollback';
end $$;

-- ============================================================
-- M2 · MUTATION — ปิด trigger แล้วใบ 30,000,000 ต้องลงได้ และ 1500 = −27,000,000
--      ถ้าปิดแล้วยังลงไม่ได้ แปลว่า N2 เขียวเพราะด่านอื่น ไม่ใช่ด่านของไฟล์นี้
--      **วางไว้ท้ายสุด** เพราะทิ้งสมุดไว้ในสภาพที่ผิด (ทั้งไฟล์ rollback ปิดท้าย)
-- ============================================================
do $$
declare v_bal numeric;
begin
  alter table sri_os.transaction_lines
    disable trigger trg_assert_asset_account_balance_nonneg;

  perform pg_temp.must_pass('M2 ย้ายเกินยอดขณะปิดด่าน', format($q$
    select pg_temp.reclass(%L, 'adj.reclass_re_to_sale', '1520', '1500', 30000000,
      'M2 ย้ายเกินยอด 30,000,000 ขณะปิดด่าน')
    $q$, '00000000-0000-0000-0000-0000000be0a1'));

  v_bal := pg_temp.book('00000000-0000-0000-0000-0000000be0a1', '1500');
  if v_bal <> -27000000 then
    raise exception 'FAIL: M2 — ปิดด่านแล้วยอด 1500 ต้องเป็น −27,000,000 (ช่องเดิม) แต่ได้ % — เคส N2 อาจวัดด่านอื่น', v_bal;
  end if;
  -- ด่านต้นทุนทั้งสองตัวยังเงียบ: ต้นทุนรวมไม่เปลี่ยน (นั่นคือเหตุที่ช่องนี้เคยหลุด)
  if sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-0000000be0a1') <> 3500000 then
    raise exception 'FAIL: M2 — ต้นทุนรวมเปลี่ยนไป (%) แปลว่าฉากนี้ไม่ใช่ฉากเดิมที่ด่านต้นทุนมองไม่เห็น',
      sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-0000000be0a1');
  end if;

  alter table sri_os.transaction_lines
    enable trigger trg_assert_asset_account_balance_nonneg;

  raise notice 'ok M2 · ปิดด่าน = ช่องเดิมกลับมาทันที (1500 = −27,000,000 โดยต้นทุนรวมยังเป็น 3,500,000)';
end $$;

rollback;
