-- ============================================================
-- SRI OS · **ซื้อเงินตราเข้าบัญชี FCD** (`trf.fx_acquire` · 25/10)
--
-- ก่อนหมวดนี้ **ไม่มีทางฝากเงินตราเข้าบัญชี FCD ผ่านแอปเลย** → ฟีเจอร์ FCD
-- ทั้งชุด (แปลงค่าสิ้นเดือน · แลกกลับเป็นบาท) ใช้ได้เฉพาะยอดที่มาจากยอดตั้งต้น
--
-- **ซื้อเข้าไม่ใช่กำไรขาดทุน** — ยอดบาทที่จ่ายไปคือ *ต้นทุน* ของเงินตราก้อนนั้น
-- จึงต้อง **ไม่แตะ P&L และไม่แตะ 3410** · ฐานะที่ `fn_fx_position()` คำนวณใหม่
-- จากสมุดต้องได้ `thb − cost = 0` ทันทีที่ซื้อเข้า
--
-- **ทุกเคสรันเป็น role `authenticated`** ไม่ใช่ superuser
--
-- ฉากครบวงจรของลูกพี่ (ตัวเลขต้องตรงกับฝั่งเครื่องยนต์ตัวต่อตัว —
-- `src/lib/ledger/__tests__/fx-posting.test.ts`)
--   X1 · ซื้อ 10,000 USD @36.50 = 365,000 บาท → **P&L 0 · 3410 0** · ต้นทุน 365,000
--   X2 · ตีราคา @37.00                        → **3410 = 5,000** พอดี
--   X3 · แลกออกทั้งก้อน @37.50                → **กำไรจริง 10,000** · 3410 เหลือ 0
--   X4 · ด่านที่ต้องยังกันได้ทุกข้อ: อัตราไม่ตรงตาราง · ไม่พกสกุล ·
--        สกุลไม่ตรงบัญชี · ยอดบาทไม่ลงตัวกับอัตรา
--   XM · **MUTATION** ซื้อเข้าแล้วแอบตั้ง 3410 → ด่าน invariant ปฏิเสธ
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
create temporary table x_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into x_uid(label) values ('mgmt');
insert into auth.users(id) select id from x_uid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, 'fx-acquire@local', 'mgmt', 'management', true from x_uid u;

insert into sri_os.user_owner_access(user_id, owner_id)
select (select id from x_uid where label = 'mgmt'), o.id from sri_os.owners o;

-- บัญชีบาท + บัญชี USD ของผู้ถือเดียวกัน
insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name, currency)
values ('00000000-0000-0000-0000-0000000cb001'::uuid,
        (select id from sri_os.owners where code = 'THANAKORN'),
        'SCB', 'ธนากร', 'ธนากร - SCB (บาท · ซื้อเงินตรา)', 'THB'),
       ('00000000-0000-0000-0000-0000000cb002'::uuid,
        (select id from sri_os.owners where code = 'THANAKORN'),
        'SCB', 'ธนากร', 'ธนากร - SCB FCD (USD · ซื้อเงินตรา)', 'USD');

-- อัตราสามวัน: วันซื้อ 36.50 · วันตีราคา 37.00 · วันแลกออก 37.50
insert into sri_os.fx_rates(currency, rate_date, thb_per_unit, source, note)
values ('USD', '2026-03-02', 36.50, 'manual', 'วันซื้อเงินตรา'),
       ('USD', '2026-03-31', 37.00, 'manual', 'อัตราสิ้นเดือน'),
       ('USD', '2026-04-20', 37.50, 'manual', 'วันแลกออก')
on conflict (currency, rate_date) do nothing;

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

/** ยอดของบัญชีหนึ่งในสมุด (ฝั่งเดบิตเป็นบวก) */
create or replace function pg_temp.bal(p_code text) returns numeric
language sql stable as $fn$
  select round(coalesce(sum(v.debit - v.credit), 0), 2)
    from sri_os.v_ledger_posted v
    join sri_os.chart_of_accounts c on c.id = v.coa_id
   where c.code = p_code;
$fn$;

/** ยอดบาทของบัญชีธนาคารหนึ่งใบ */
create or replace function pg_temp.bank_bal(p_bank uuid) returns numeric
language sql stable as $fn$
  select round(coalesce(sum(v.debit - v.credit), 0), 2)
    from sri_os.v_ledger_posted v where v.bank_account_id = p_bank;
$fn$;

/** ใบซื้อเงินตรา — สองบรรทัดเงินสด ขาเงินตราพกสกุล/อัตรา */
create or replace function pg_temp.acquire(p_units numeric, p_rate numeric, p_date date,
                                           p_memo text) returns uuid
language plpgsql as $fn$
declare v jsonb; v_thb numeric := round(p_units * p_rate, 2);
begin
  v := sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code', 'trf.fx_acquire',
    'doc_date', p_date::text,
    'cash_date', p_date::text,
    'memo', p_memo,
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', pg_temp.own('THANAKORN'),
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code', '1100',
                           'bank_account_id', '00000000-0000-0000-0000-0000000cb002',
                           'debit', v_thb, 'credit', 0, 'cf_category', 'none',
                           'currency', 'USD', 'amount_original', p_units,
                           'fx_rate', p_rate, 'fx_rate_date', p_date::text),
        jsonb_build_object('coa_code', '1100',
                           'bank_account_id', '00000000-0000-0000-0000-0000000cb001',
                           'debit', 0, 'credit', v_thb, 'cf_category', 'none'))))));
  return ((v -> 'transaction_ids') ->> 0)::uuid;
end $fn$;

do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.x_uid to authenticated', s);
end $$;

-- ============================================================
-- X0 · ตารางกฎต้องมีหมวดนี้ และรูปของหมวดต้องถูก
-- ============================================================
do $$
declare r record;
begin
  select * into r from sri_os.txn_types where code = 'trf.fx_acquire';
  if r.code is null then
    raise exception 'FAIL: X0 — ไม่มีหมวด trf.fx_acquire ในตารางกฎ (sync:rules แล้วหรือยัง) → ฝากเงินตราเข้า FCD ผ่านแอปไม่ได้';
  end if;

  -- สองขาเป็นเงินสดทั้งคู่ · ไม่มีบัญชีกำไร/ขาดทุน · ไม่แตะ 3410/3400
  if r.dr_coa_code <> '1100' or r.cr_coa_code <> '1100' then
    raise exception 'FAIL: X0 — คู่บัญชีต้องเป็นเงินสดทั้งสองขา แต่ได้ Dr % / Cr %',
      r.dr_coa_code, r.cr_coa_code;
  end if;
  if r.gain_coa_code is not null or r.loss_coa_code is not null then
    raise exception 'FAIL: X0 — ซื้อเงินตราไม่ใช่กำไรขาดทุน แต่ตารางกฎให้บัญชีกำไร/ขาดทุนไว้ (% / %)',
      r.gain_coa_code, r.loss_coa_code;
  end if;
  if '3410' in (r.dr_coa_code, r.cr_coa_code) or '3400' in (r.dr_coa_code, r.cr_coa_code) then
    raise exception 'FAIL: X0 — หมวดนี้ต้องไม่แตะ 3410/3400 (ผลต่างเกิดตอนอัตราขยับหลังถือไว้)';
  end if;
  -- ต้องมีขาเงินสด (ไม่งั้น constraint ของ 20261009000003 จะขัดกับการผูกบัญชี)
  if r.cash_direction = 'none' then
    raise exception 'FAIL: X0 — หมวดนี้มีเงินเคลื่อนจริง cash_direction ต้องไม่ใช่ none';
  end if;
  if r.cf_group::text in ('operating', 'investing', 'financing') then
    raise exception 'FAIL: X0 — ซื้อเงินตราไม่ใช่กระแสเงินสดของงวด แต่ cf_group = %', r.cf_group;
  end if;

  raise notice 'ok X0 · หมวด trf.fx_acquire มีจริง · เงินสดสองขา · ไม่มีกำไร/ขาดทุน · ไม่แตะ 3410/3400 · ไม่เข้างบกระแสเงินสด';
end $$;

-- ============================================================
-- X1 · ซื้อ 10,000 USD @36.50 → **P&L 0 · 3410 0** · ต้นทุน 365,000
-- ============================================================
do $$
declare p record;
begin
  perform set_config('test.uid', (select id::text from x_uid where label = 'mgmt'), true);
  set local role authenticated;

  perform pg_temp.acquire(10000, 36.50, '2026-03-02', 'X1 ซื้อ 10,000 USD @36.50');

  reset role;

  if pg_temp.bank_bal('00000000-0000-0000-0000-0000000cb002') <> 365000 then
    raise exception 'FAIL: X1 — บัญชี USD ต้องมียอดบาท 365,000 แต่ได้ %',
      pg_temp.bank_bal('00000000-0000-0000-0000-0000000cb002');
  end if;
  if pg_temp.bank_bal('00000000-0000-0000-0000-0000000cb001') <> -365000 then
    raise exception 'FAIL: X1 — บัญชีบาทต้องลดลง 365,000 แต่ได้ %',
      pg_temp.bank_bal('00000000-0000-0000-0000-0000000cb001');
  end if;

  -- **ไม่แตะ P&L และไม่แตะ 3410**
  if pg_temp.bal('3410') <> 0 or pg_temp.bal('4330') <> 0 or pg_temp.bal('5930') <> 0 then
    raise exception 'FAIL: X1 — ซื้อเข้าต้องไม่แตะ 3410/4330/5930 แต่ได้ % / % / %',
      pg_temp.bal('3410'), pg_temp.bal('4330'), pg_temp.bal('5930');
  end if;

  /**
   * **ฐานะเงินตราที่ DB คำนวณใหม่จากสมุด** — ต้นทุนต้องเท่ากับยอดบาทพอดี
   * นี่คือข้อที่ทำให้ "ไม่ต้องตั้ง 3410" เป็นจริงเชิงสมการ ไม่ใช่เพราะเราเลือกไม่ตั้ง
   */
  select * into p from sri_os.fn_fx_position(pg_temp.own('THANAKORN'), 'USD');
  if p.units <> 10000 or p.thb <> 365000 or p.cost <> 365000 then
    raise exception 'FAIL: X1 — ฐานะต้องเป็น 10,000 หน่วย · บาท 365,000 · ต้นทุน 365,000 แต่ได้ % / % / %',
      p.units, p.thb, p.cost;
  end if;
  if sri_os.fn_fx_required_unrealised(pg_temp.own('THANAKORN')) <> 0 then
    raise exception 'FAIL: X1 — ผลต่างที่ควรค้างต้องเป็น 0 ทันทีที่ซื้อเข้า แต่ได้ %',
      sri_os.fn_fx_required_unrealised(pg_temp.own('THANAKORN'));
  end if;

  raise notice 'ok X1 · ซื้อ 10,000 USD @36.50 ในฐานะ authenticated: USD +365,000 บาท · บัญชีบาท −365,000 · 3410 = 0 · P&L = 0 · ต้นทุนที่ DB คิดใหม่ = 365,000 พอดี';
exception when others then
  reset role;
  raise;
end $$;

-- ============================================================
-- X2 · ตีราคาสิ้นเดือน @37.00 → **3410 = 5,000** พอดี
-- ============================================================
do $$
begin
  perform set_config('test.uid', (select id::text from x_uid where label = 'mgmt'), true);
  set local role authenticated;

  -- 10,000 USD × (37.00 − 36.50) = 5,000
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code', 'trf.fx_translate_up',
    'doc_date', '2026-03-31', 'cash_date', '2026-03-31',
    'memo', 'X2 แปลงค่าสิ้นเดือน 36.50 → 37.00',
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', pg_temp.own('THANAKORN'),
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code', '1100',
                           'bank_account_id', '00000000-0000-0000-0000-0000000cb002',
                           'debit', 5000, 'credit', 0, 'cf_category', 'none',
                           'currency', 'USD', 'amount_original', 0,
                           'fx_rate', 37.00, 'fx_rate_date', '2026-03-31'),
        -- ขา 3410 ต้องพกสกุล/อัตราด้วย (ด่านระดับใบตัดสินจากสกุลของบัญชีเงินสดในใบ)
        jsonb_build_object('coa_code', '3410', 'debit', 0, 'credit', 5000,
                           'cf_category', 'none',
                           'currency', 'USD', 'amount_original', 0,
                           'fx_rate', 37.00, 'fx_rate_date', '2026-03-31'))))));

  reset role;

  if pg_temp.bal('3410') <> -5000 then
    raise exception 'FAIL: X2 — 3410 ต้องเป็น 5,000 ฝั่งเครดิต (แสดงเป็น −5,000) แต่ได้ %',
      pg_temp.bal('3410');
  end if;
  if sri_os.fn_fx_required_unrealised(pg_temp.own('THANAKORN')) <> 5000 then
    raise exception 'FAIL: X2 — ผลต่างที่ควรค้างต้องเป็น 5,000 แต่ได้ %',
      sri_os.fn_fx_required_unrealised(pg_temp.own('THANAKORN'));
  end if;
  if pg_temp.bal('4330') <> 0 or pg_temp.bal('5930') <> 0 then
    raise exception 'FAIL: X2 — การแปลงค่ายังไม่ใช่กำไรจริง ห้ามแตะ P&L';
  end if;

  raise notice 'ok X2 · ตีราคา @37.00 → 3410 = 5,000 พอดี (ไม่ใช่ตัวเลขอื่น) · ยังไม่เข้า P&L · ฐานต้นทุน 365,000 ที่ใบซื้อสร้างไว้เป็นตัวที่ทำให้ได้ 5,000';
exception when others then
  reset role;
  raise;
end $$;

-- ============================================================
-- X3 · แลกออกทั้งก้อน @37.50 → **กำไรจริง 10,000** · 3410 เหลือ 0
-- ============================================================
do $$
begin
  perform set_config('test.uid', (select id::text from x_uid where label = 'mgmt'), true);
  set local role authenticated;

  /**
   * บาทที่ได้ 375,000 − ยอดตามบัญชี 370,000 (= 10,000 × 37.00) = 5,000
   * บวกผลต่างที่เคยตั้งไว้ 5,000 ที่ถูกล้างออก = **กำไรจริง 10,000**
   */
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code', 'trf.fx_convert',
    'doc_date', '2026-04-20', 'cash_date', '2026-04-20',
    'memo', 'X3 แลก 10,000 USD @37.50 เป็นบาท',
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', pg_temp.own('THANAKORN'),
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code', '1100',
                           'bank_account_id', '00000000-0000-0000-0000-0000000cb001',
                           'debit', 375000, 'credit', 0, 'cf_category', 'none'),
        jsonb_build_object('coa_code', '1100',
                           'bank_account_id', '00000000-0000-0000-0000-0000000cb002',
                           'debit', 0, 'credit', 370000, 'cf_category', 'none',
                           'currency', 'USD', 'amount_original', 10000,
                           'fx_rate', 37.00, 'fx_rate_date', '2026-03-31'),
        jsonb_build_object('coa_code', '3410', 'debit', 5000, 'credit', 0,
                           'cf_category', 'none',
                           'currency', 'USD', 'amount_original', 0,
                           'fx_rate', 37.50, 'fx_rate_date', '2026-04-20'),
        jsonb_build_object('coa_code', '4330', 'debit', 0, 'credit', 10000,
                           'cf_category', 'none'))))));

  reset role;

  if pg_temp.bal('4330') <> -10000 then
    raise exception 'FAIL: X3 — กำไรอัตราแลกเปลี่ยนที่เกิดจริงต้องเป็น 10,000 แต่ได้ %',
      -pg_temp.bal('4330');
  end if;
  if pg_temp.bal('3410') <> 0 then
    raise exception 'FAIL: X3 — แลกออกหมดแล้ว 3410 ต้องเหลือ 0 พอดี แต่ได้ %', pg_temp.bal('3410');
  end if;
  if pg_temp.bank_bal('00000000-0000-0000-0000-0000000cb002') <> 0 then
    raise exception 'FAIL: X3 — บัญชี USD ต้องกลับเป็น 0 แต่ได้ %',
      pg_temp.bank_bal('00000000-0000-0000-0000-0000000cb002');
  end if;
  -- บัญชีบาท: −365,000 (ซื้อ) + 375,000 (แลกคืน) = +10,000 = กำไรที่ได้จริง
  if pg_temp.bank_bal('00000000-0000-0000-0000-0000000cb001') <> 10000 then
    raise exception 'FAIL: X3 — บัญชีบาทสุทธิต้องเป็น +10,000 (เท่ากำไรที่เกิดจริง) แต่ได้ %',
      pg_temp.bank_bal('00000000-0000-0000-0000-0000000cb001');
  end if;

  raise notice 'ok X3 · ครบวงจร: ซื้อ @36.50 → ตีราคา @37.00 → แลกออก @37.50 = **กำไรจริง 10,000** · 3410 เหลือ 0 · บัญชี USD เหลือ 0 · เงินบาทสุทธิ +10,000 เท่ากำไรพอดี';
exception when others then
  reset role;
  raise;
end $$;

-- ============================================================
-- X4 · ด่านเดิมของ FCD ต้องยังกันได้ทุกข้อ (หมวดใหม่ไม่ได้เปิดรูให้)
-- ============================================================
do $$
begin
  perform set_config('test.uid', (select id::text from x_uid where label = 'mgmt'), true);
  set local role authenticated;

  -- (ก) ไม่พกสกุล/อัตรา → ปฏิเสธ (นี่คือเหตุที่ trf.internal ใช้แทนไม่ได้)
  perform pg_temp.must_fail_like('X4 ซื้อเงินตราโดยไม่พกสกุล', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code', 'trf.fx_acquire',
      'doc_date', '2026-03-02', 'cash_date', '2026-03-02',
      'memo', 'X4 ไม่พกสกุล (ผิด)',
      'transactions', jsonb_build_array(jsonb_build_object(
        'owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code', '1100', 'bank_account_id', %L,
                             'debit', 36500, 'credit', 0, 'cf_category', 'none'),
          jsonb_build_object('coa_code', '1100', 'bank_account_id', %L,
                             'debit', 0, 'credit', 36500, 'cf_category', 'none'))))))
    $q$, pg_temp.own('THANAKORN'),
         '00000000-0000-0000-0000-0000000cb002', '00000000-0000-0000-0000-0000000cb001'),
    'ต้องระบุสกุลเงิน');

  -- (ข) อัตราไม่ตรงตารางอัตรา → ปฏิเสธ
  perform pg_temp.must_fail_like('X4 อัตราไม่ตรงตารางอัตรา', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code', 'trf.fx_acquire',
      'doc_date', '2026-03-02', 'cash_date', '2026-03-02',
      'memo', 'X4 อัตรา 30.00 ที่ไม่ได้ประกาศ (ผิด)',
      'transactions', jsonb_build_array(jsonb_build_object(
        'owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code', '1100', 'bank_account_id', %L,
                             'debit', 30000, 'credit', 0, 'cf_category', 'none',
                             'currency', 'USD', 'amount_original', 1000,
                             'fx_rate', 30.00, 'fx_rate_date', '2026-03-02'),
          jsonb_build_object('coa_code', '1100', 'bank_account_id', %L,
                             'debit', 0, 'credit', 30000, 'cf_category', 'none'))))))
    $q$, pg_temp.own('THANAKORN'),
         '00000000-0000-0000-0000-0000000cb002', '00000000-0000-0000-0000-0000000cb001'),
    'ไม่เท่ากับอัตราในตารางอัตราแลกเปลี่ยน');

  -- (ค) ยอดบาทไม่ลงตัวกับอัตรา → ปฏิเสธ (ไม่ยอมเศษแม้สตางค์เดียว)
  perform pg_temp.must_fail_like('X4 ยอดบาทไม่ลงตัวกับอัตรา', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code', 'trf.fx_acquire',
      'doc_date', '2026-03-02', 'cash_date', '2026-03-02',
      'memo', 'X4 ยอดบาทเกินมา 1 สตางค์ (ผิด)',
      'transactions', jsonb_build_array(jsonb_build_object(
        'owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code', '1100', 'bank_account_id', %L,
                             'debit', 36500.01, 'credit', 0, 'cf_category', 'none',
                             'currency', 'USD', 'amount_original', 1000,
                             'fx_rate', 36.50, 'fx_rate_date', '2026-03-02'),
          jsonb_build_object('coa_code', '1100', 'bank_account_id', %L,
                             'debit', 0, 'credit', 36500.01, 'cf_category', 'none'))))))
    $q$, pg_temp.own('THANAKORN'),
         '00000000-0000-0000-0000-0000000cb002', '00000000-0000-0000-0000-0000000cb001'),
    'ไม่เท่ากับ');

  -- (ง) สกุลไม่ตรงกับบัญชี → ปฏิเสธ (อ่านจาก bank_accounts.currency)
  perform pg_temp.must_fail_like('X4 สกุลไม่ตรงบัญชี', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code', 'trf.fx_acquire',
      'doc_date', '2026-03-02', 'cash_date', '2026-03-02',
      'memo', 'X4 บอกว่า JPY แต่บัญชีเป็น USD (ผิด)',
      'transactions', jsonb_build_array(jsonb_build_object(
        'owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code', '1100', 'bank_account_id', %L,
                             'debit', 36500, 'credit', 0, 'cf_category', 'none',
                             'currency', 'JPY', 'amount_original', 1000,
                             'fx_rate', 36.50, 'fx_rate_date', '2026-03-02'),
          jsonb_build_object('coa_code', '1100', 'bank_account_id', %L,
                             'debit', 0, 'credit', 36500, 'cf_category', 'none'))))))
    $q$, pg_temp.own('THANAKORN'),
         '00000000-0000-0000-0000-0000000cb002', '00000000-0000-0000-0000-0000000cb001'),
    'สกุลของบรรทัดต้องเป็นสกุลของบัญชี');

  -- (จ) เส้นทางที่ถูกต้องยังลงได้ (ด่านต้องไม่แน่นเกิน)
  perform pg_temp.must_pass('X4 ซื้อ 1,000 USD ถูกต้อง', $q$
    select pg_temp.acquire(1000, 36.50, '2026-03-02', 'X4 ซื้อ 1,000 USD @36.50 (ถูกต้อง)') $q$);

  reset role;
  raise notice 'ok X4 · ด่าน FCD เดิมยังกันได้ครบ: ไม่พกสกุล · อัตราไม่ตรงตาราง · ยอดบาทเศษ 1 สตางค์ · สกุลไม่ตรงบัญชี — และเส้นทางที่ถูกยังลงได้';
exception when others then
  reset role;
  raise;
end $$;

-- ============================================================
-- XM · **MUTATION** — ซื้อเข้าแล้วแอบตั้ง 3410 → ด่าน invariant ต้องปฏิเสธ
--      พิสูจน์ว่า "ซื้อเข้าไม่ตั้งผลต่าง" ถูกบังคับที่ DB ไม่ใช่แค่ที่เครื่องยนต์
-- ============================================================
do $$
begin
  perform set_config('test.uid', (select id::text from x_uid where label = 'mgmt'), true);
  set local role authenticated;

  perform pg_temp.must_fail_like('XM ซื้อเข้าแล้วแอบตั้ง 3410', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code', 'trf.fx_acquire',
      'doc_date', '2026-03-02', 'cash_date', '2026-03-02',
      'memo', 'XM ซื้อ 1,000 USD แล้วตั้งผลต่าง 500 (ผิด)',
      'transactions', jsonb_build_array(jsonb_build_object(
        'owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code', '1100', 'bank_account_id', %L,
                             'debit', 36500, 'credit', 0, 'cf_category', 'none',
                             'currency', 'USD', 'amount_original', 1000,
                             'fx_rate', 36.50, 'fx_rate_date', '2026-03-02'),
          jsonb_build_object('coa_code', '1100', 'bank_account_id', %L,
                             'debit', 0, 'credit', 36000, 'cf_category', 'none'),
          jsonb_build_object('coa_code', '3410', 'debit', 0, 'credit', 500,
                             'cf_category', 'none'))))))
    $q$, pg_temp.own('THANAKORN'),
         '00000000-0000-0000-0000-0000000cb002', '00000000-0000-0000-0000-0000000cb001'),
    '3410');

  reset role;
  raise notice 'ok XM (MUTATION) · ซื้อเข้าแล้วแอบตั้งผลต่าง 500 ถูกปฏิเสธที่ DB — ถ้าผ่าน ส่วนของเจ้าของจะมีผลต่าง 500 ที่ไม่มีอยู่จริง และกำไรตอนแลกออกจะต่ำกว่าจริง 500 ทั้งที่งบดุลยังดุล';
exception when others then
  reset role;
  raise;
end $$;

rollback;
