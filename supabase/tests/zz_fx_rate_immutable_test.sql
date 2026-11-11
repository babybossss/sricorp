-- ============================================================
-- SRI OS · **อัตราแลกเปลี่ยนที่ถูกใช้แล้ว แก้ย้อนหลังไม่ได้**
--            (20261025000015_fx_rate_immutable_when_used.sql)
--
-- **คลาส D-115** — policy `fx_rates_write` เป็น `for all` → ผู้ใช้ที่มี
-- `settings.manage` UPDATE อัตราที่ถูกใช้แล้วได้ตรงๆ · หน้าจอกันแล้ว
-- **แต่ DB ไม่กัน** → คำขอที่ข้ามหน้าจอผ่านหมด
--
-- **ทุกเคสรันเป็น role `authenticated`** ไม่ใช่ superuser (ถ้ารันเป็น superuser
-- จะข้าม policy ทั้งหมดแล้วไม่ได้พิสูจน์เรื่องสิทธิ์เลย)
--
-- สิ่งที่พิสูจน์
--   R0 · โครงสร้าง: trigger อยู่จริง · ผู้ใช้จริงมีสิทธิ์ UPDATE ตารางนี้
--        (ถ้าไม่มีสิทธิ์ตั้งแต่ต้น เคสอื่นจะเขียวด้วยเหตุผลผิด)
--   R1 · UPDATE อัตราที่ถูกใช้แล้ว → **ปฏิเสธ** · ค่ายังเป็น 36.50 ·
--        ยอดบาทของรายการเดิมไม่ขยับ
--   R2 · UPDATE แถวที่ยังไม่มีใครใช้ → **ทำได้** (อัตราที่พิมพ์ผิดต้องแก้ได้)
--        และทำได้จนกว่าจะมีรายการอ้าง — ลงรายการแล้วแก้ไม่ได้ทันที
--   R3 · UPDATE แค่ `note` ของแถวที่ถูกใช้แล้ว → **ทำได้** (ไม่กระทบตัวเลข)
--   R4 · เปลี่ยนคีย์ (`rate_date`) ของแถวที่ถูกใช้ → ปฏิเสธ
--   R5 · DELETE แถวที่ถูกใช้ → **ถูกกันด้วย FK จริง** ไม่ใช่โดยแอป
--   RM · **MUTATION** ถอด trigger → แก้ 36.50 → 40.00 สำเร็จ และวัดส่วนต่างได้
--        **35,000 บาท** ที่ไม่มีใครฟ้อง
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
create temporary table y_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into y_uid(label) values ('mgmt');
insert into auth.users(id) select id from y_uid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, 'fx-rate@local', 'mgmt', 'management', true from y_uid u;

insert into sri_os.user_owner_access(user_id, owner_id)
select (select id from y_uid where label = 'mgmt'), o.id from sri_os.owners o;

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name, currency)
values ('00000000-0000-0000-0000-0000000db001'::uuid,
        (select id from sri_os.owners where code = 'THANAKORN'),
        'SCB', 'ธนากร', 'ธนากร - SCB (บาท · อัตรา)', 'THB'),
       ('00000000-0000-0000-0000-0000000db002'::uuid,
        (select id from sri_os.owners where code = 'THANAKORN'),
        'SCB', 'ธนากร', 'ธนากร - SCB FCD (USD · อัตรา)', 'USD');

-- สองแถว: แถวที่จะถูกใช้ และแถวที่จะไม่มีใครใช้
insert into sri_os.fx_rates(currency, rate_date, thb_per_unit, source, note)
values ('USD', '2026-02-10', 36.50, 'manual', 'อัตราที่จะถูกใช้'),
       ('USD', '2026-02-11', 36.60, 'manual', 'อัตราที่ยังไม่มีใครใช้')
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

create or replace function pg_temp.rate(p_date date) returns numeric
language sql stable as $fn$
  select thb_per_unit from sri_os.fx_rates where currency = 'USD' and rate_date = p_date;
$fn$;

/** ยอดบาทของบัญชี USD ตามสมุด (ยอดที่ "ควรเท่ากับ จำนวนเงินตรา × อัตรา") */
create or replace function pg_temp.usd_thb() returns numeric
language sql stable as $fn$
  select round(coalesce(sum(v.debit - v.credit), 0), 2)
    from sri_os.v_ledger_posted v
   where v.bank_account_id = '00000000-0000-0000-0000-0000000db002';
$fn$;

do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.y_uid to authenticated', s);
end $$;

-- ============================================================
-- R0 · โครงสร้าง + **ผู้ใช้จริงต้องมีสิทธิ์ UPDATE ตารางนี้อยู่แล้ว**
--      (ถ้าไม่มี เคส R1 จะเขียวเพราะ "ไม่มีสิทธิ์" ไม่ใช่เพราะด่านใหม่)
-- ============================================================
do $$
begin
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.fx_rates'::regclass
                    and g.tgname = 'trg_fx_rates_immutable_when_used'
                    and not g.tgisinternal) then
    raise exception 'FAIL: R0 — ไม่มี trigger trg_fx_rates_immutable_when_used (migration ไม่ถูก apply?) เทสต์นี้จะไม่ได้ตรวจอะไร';
  end if;

  if not has_table_privilege('authenticated', 'sri_os.fx_rates', 'UPDATE') then
    raise exception 'FAIL: R0 — authenticated ไม่มีสิทธิ์ UPDATE fx_rates ตั้งแต่ต้น → เคสอื่นในไฟล์นี้จะเขียวด้วยเหตุผลผิด (ต้องพิสูจน์ว่าด่านใหม่เป็นตัวกัน)';
  end if;

  if not exists (select 1 from pg_policies
                  where schemaname = 'sri_os' and tablename = 'fx_rates' and cmd = 'ALL') then
    raise exception 'FAIL: R0 — ไม่มี policy เขียนของ fx_rates แล้ว → สมมติฐานของไฟล์นี้เปลี่ยน ต้องอ่านใหม่';
  end if;

  raise notice 'ok R0 · trigger อยู่จริง · authenticated มีสิทธิ์ UPDATE ตารางนี้ (จึงพิสูจน์ด่านได้)';
end $$;

-- ============================================================
-- R1 · ลงรายการที่ใช้อัตรานั้น แล้วแก้อัตรา → **ปฏิเสธ**
-- ============================================================
do $$
declare v_before numeric;
begin
  perform set_config('test.uid', (select id::text from y_uid where label = 'mgmt'), true);
  set local role authenticated;

  -- ซื้อ 10,000 USD @36.50 = 365,000 บาท (ใบนี้อ้างอัตราวันที่ 2026-02-10)
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code', 'trf.fx_acquire',
    'doc_date', '2026-02-10', 'cash_date', '2026-02-10',
    'memo', 'R1 ซื้อ 10,000 USD @36.50',
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', pg_temp.own('THANAKORN'),
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code', '1100',
                           'bank_account_id', '00000000-0000-0000-0000-0000000db002',
                           'debit', 365000, 'credit', 0, 'cf_category', 'none',
                           'currency', 'USD', 'amount_original', 10000,
                           'fx_rate', 36.50, 'fx_rate_date', '2026-02-10'),
        jsonb_build_object('coa_code', '1100',
                           'bank_account_id', '00000000-0000-0000-0000-0000000db001',
                           'debit', 0, 'credit', 365000, 'cf_category', 'none'))))));

  v_before := pg_temp.usd_thb();
  if v_before <> 365000 then
    raise exception 'FAIL: R1 — ยอดบาทของบัญชี USD ต้องเป็น 365,000 แต่ได้ %', v_before;
  end if;

  -- **แก้อัตราที่ถูกใช้แล้ว → ต้องถูกปฏิเสธ**
  perform pg_temp.must_fail_like('R1 แก้อัตราที่ถูกใช้แล้ว 36.50 → 40.00', $q$
    update sri_os.fx_rates set thb_per_unit = 40.00
     where currency = 'USD' and rate_date = '2026-02-10' $q$,
    'มีรายการในสมุดหรือทะเบียนล็อตอ้างถึงแล้ว');

  reset role;

  if pg_temp.rate('2026-02-10') <> 36.50 then
    raise exception 'FAIL: R1 — อัตราต้องยังเป็น 36.50 แต่กลายเป็น %', pg_temp.rate('2026-02-10');
  end if;
  if pg_temp.usd_thb() <> v_before then
    raise exception 'FAIL: R1 — ยอดบาทของรายการเดิมขยับจาก % เป็น %', v_before, pg_temp.usd_thb();
  end if;

  raise notice 'ok R1 · แก้อัตราที่ถูกใช้แล้วถูกปฏิเสธในฐานะ authenticated · อัตรายัง 36.50 · ยอดบาทของรายการเดิมยัง 365,000 ไม่ขยับ';
exception when others then
  reset role;
  raise;
end $$;

-- ============================================================
-- R2 · แถวที่ยังไม่มีใครใช้ แก้ได้ — และ **แก้ได้จนกว่าจะมีคนใช้**
-- ============================================================
do $$
begin
  perform set_config('test.uid', (select id::text from y_uid where label = 'mgmt'), true);
  set local role authenticated;

  perform pg_temp.must_pass('R2 แก้อัตราที่ยังไม่มีใครใช้', $q$
    update sri_os.fx_rates set thb_per_unit = 36.75
     where currency = 'USD' and rate_date = '2026-02-11' $q$);

  if pg_temp.rate('2026-02-11') <> 36.75 then
    raise exception 'FAIL: R2 — อัตราที่ยังไม่มีใครใช้ต้องแก้ได้ (ควรเป็น 36.75) แต่ได้ %',
      pg_temp.rate('2026-02-11');
  end if;

  -- ลงรายการที่อ้างอัตรานั้น แล้วแก้อีกครั้ง → ปฏิเสธทันที
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code', 'trf.fx_acquire',
    'doc_date', '2026-02-11', 'cash_date', '2026-02-11',
    'memo', 'R2 ซื้อ 1,000 USD @36.75',
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', pg_temp.own('THANAKORN'),
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code', '1100',
                           'bank_account_id', '00000000-0000-0000-0000-0000000db002',
                           'debit', 36750, 'credit', 0, 'cf_category', 'none',
                           'currency', 'USD', 'amount_original', 1000,
                           'fx_rate', 36.75, 'fx_rate_date', '2026-02-11'),
        jsonb_build_object('coa_code', '1100',
                           'bank_account_id', '00000000-0000-0000-0000-0000000db001',
                           'debit', 0, 'credit', 36750, 'cf_category', 'none'))))));

  perform pg_temp.must_fail_like('R2 แก้อัตราเดิมหลังมีคนใช้แล้ว', $q$
    update sri_os.fx_rates set thb_per_unit = 38.00
     where currency = 'USD' and rate_date = '2026-02-11' $q$,
    'แก้');

  reset role;

  if pg_temp.rate('2026-02-11') <> 36.75 then
    raise exception 'FAIL: R2 — อัตราต้องยังเป็น 36.75 แต่กลายเป็น %', pg_temp.rate('2026-02-11');
  end if;

  raise notice 'ok R2 · อัตราที่ยังไม่มีใครใช้แก้ได้ (36.60 → 36.75) · ลงรายการที่อ้างมันแล้ว แก้ไม่ได้ทันที — เส้นแบ่งคือ "มีรายการอ้างถึงหรือยัง" ไม่ใช่เวลา';
exception when others then
  reset role;
  raise;
end $$;

-- ============================================================
-- R3 · `note` แก้ได้ตลอด (ไม่กระทบตัวเลข) — ด่านต้องไม่แน่นเกิน
-- ============================================================
do $$
begin
  perform set_config('test.uid', (select id::text from y_uid where label = 'mgmt'), true);
  set local role authenticated;

  perform pg_temp.must_pass('R3 แก้ note ของอัตราที่ถูกใช้แล้ว', $q$
    update sri_os.fx_rates set note = 'อัตราจากใบยืนยันของธนาคาร เลขที่ 123'
     where currency = 'USD' and rate_date = '2026-02-10' $q$);

  reset role;

  if (select note from sri_os.fx_rates where currency = 'USD' and rate_date = '2026-02-10')
     not like '%เลขที่ 123%' then
    raise exception 'FAIL: R3 — note ต้องถูกแก้แล้ว';
  end if;
  if pg_temp.rate('2026-02-10') <> 36.50 then
    raise exception 'FAIL: R3 — การแก้ note ไม่ควรแตะอัตรา';
  end if;

  raise notice 'ok R3 · แก้หมายเหตุของอัตราที่ถูกใช้แล้วได้ (ที่มาของอัตราควรเพิ่มได้ภายหลัง) · อัตราไม่ขยับ';
exception when others then
  reset role;
  raise;
end $$;

-- ============================================================
-- R4 · เปลี่ยนคีย์ของแถวที่ถูกใช้ → ปฏิเสธ
-- ============================================================
do $$
begin
  perform set_config('test.uid', (select id::text from y_uid where label = 'mgmt'), true);
  set local role authenticated;

  perform pg_temp.must_fail_like('R4 ย้ายวันของอัตราที่ถูกใช้', $q$
    update sri_os.fx_rates set rate_date = '2026-02-20'
     where currency = 'USD' and rate_date = '2026-02-10' $q$,
    'แก้');

  perform pg_temp.must_fail_like('R4 แก้ที่มาของอัตราที่ถูกใช้', $q$
    update sri_os.fx_rates set source = 'bot_api'
     where currency = 'USD' and rate_date = '2026-02-10' $q$,
    'แก้');

  reset role;
  if pg_temp.rate('2026-02-10') is null then
    raise exception 'FAIL: R4 — แถวเดิมหายไป';
  end if;

  raise notice 'ok R4 · ย้ายวันของอัตรา/แก้ที่มา ของแถวที่ถูกใช้แล้ว ถูกปฏิเสธ';
exception when others then
  reset role;
  raise;
end $$;

-- ============================================================
-- R5 · DELETE ถูกกันด้วย **FK จริง** ไม่ใช่โดยแอป
-- ============================================================
do $$
begin
  perform set_config('test.uid', (select id::text from y_uid where label = 'mgmt'), true);
  set local role authenticated;

  perform pg_temp.must_fail_like('R5 ลบอัตราที่ถูกใช้', $q$
    delete from sri_os.fx_rates where currency = 'USD' and rate_date = '2026-02-10' $q$,
    'violates foreign key constraint');

  reset role;
  if pg_temp.rate('2026-02-10') <> 36.50 then
    raise exception 'FAIL: R5 — แถวต้องยังอยู่';
  end if;

  raise notice 'ok R5 · ลบอัตราที่ถูกใช้ถูกกันด้วย FK ของฐานข้อมูลเอง (ไม่ใช่โดยแอป)';
exception when others then
  reset role;
  raise;
end $$;

-- ============================================================
-- RM · **MUTATION** — ถอด trigger แล้ววัดความเสียหายเป็นตัวเลข
-- ============================================================
do $$
declare v_units numeric; v_thb numeric; v_should numeric; v_gap numeric;
begin
  drop trigger trg_fx_rates_immutable_when_used on sri_os.fx_rates;

  perform set_config('test.uid', (select id::text from y_uid where label = 'mgmt'), true);
  set local role authenticated;

  update sri_os.fx_rates set thb_per_unit = 40.00
   where currency = 'USD' and rate_date = '2026-02-10';

  reset role;

  if pg_temp.rate('2026-02-10') <> 40.00 then
    raise exception 'FAIL: RM — ถอด trigger แล้วควรแก้อัตราได้ แต่ยังเป็น % · ถ้าแก้ไม่ได้ แปลว่า R1 เขียวเพราะอย่างอื่น ไม่ใช่เพราะ trigger',
      pg_temp.rate('2026-02-10');
  end if;

  /**
   * **ส่วนต่างที่ไม่มีใครฟ้อง** — ยอดบาทในสมุดยังเป็น 365,000 (อัตรา 36.50
   * ตอนลง) แต่อัตราในตารางบอกว่า 10,000 USD ต้องเป็น 400,000
   * → ต่างกัน **35,000 บาท** · งบดุลยังดุล และไม่มีด่านไหนดังขึ้น
   * ร้ายกว่านั้น: ด่าน `fn_assert_line_fx` ข้อ 2 เทียบอัตราบนบรรทัดกับตาราง
   * → ตั้งแต่นี้ไป **รายการเก่าแก้/กลับรายการไม่ได้อีก** เพราะอัตราไม่ตรงตาราง
   */
  v_units := 10000;
  v_thb := 365000;                                  -- ยอดในสมุด (อัตราตอนลง)
  v_should := round(v_units * pg_temp.rate('2026-02-10'), 2);  -- ตามอัตราใหม่
  v_gap := v_should - v_thb;

  if v_gap <> 35000 then
    raise exception 'FAIL: RM — ส่วนต่างต้องเป็น 35,000 บาท แต่คิดได้ % (ยอดสมุด % · ตามอัตราใหม่ %)',
      v_gap, v_thb, v_should;
  end if;

  raise notice 'ok RM (MUTATION) · ถอด trigger → แก้อัตรา 36.50 → 40.00 สำเร็จ · ยอดบาทในสมุดยัง 365,000 แต่ตามอัตราในตารางต้องเป็น 400,000 → **ส่วนต่าง 35,000 บาท** ที่ไม่มีใครฟ้อง · และรายการเก่าจะแก้/กลับรายการไม่ได้อีก เพราะด่านเทียบอัตราบนบรรทัดกับตาราง';
  raise exception 'ROLLBACK_RM';
exception when others then
  reset role;
  if sqlerrm like 'FAIL:%' then raise; end if;
  if sqlerrm <> 'ROLLBACK_RM' then raise; end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.fx_rates'::regclass
                    and g.tgname = 'trg_fx_rates_immutable_when_used'
                    and not g.tgisinternal) then
    raise exception 'FAIL: RM — trigger ไม่กลับมาหลัง rollback';
  end if;
  if pg_temp.rate('2026-02-10') <> 36.50 then
    raise exception 'FAIL: RM — อัตราไม่ถูกย้อนกลับ (เป็น %)', pg_temp.rate('2026-02-10');
  end if;
  raise notice 'ok RMb · trigger กลับมาและอัตรากลับเป็น 36.50 หลัง rollback';
end $$;

-- ============================================================
-- N · **ห้ามบันทึกอัตราของวันที่ยังไม่มาถึง** (20261025000016)
--
--     ทุกเคสยึดกับ `current_date` **ไม่ใช่วันคงที่** — เทสต์ที่ใช้วันคงที่
--     จะกลับมาเขียว/แดงเองตามปฏิทินโดยไม่มีใครแก้อะไร ซึ่งคือเหตุที่ต้องย้าย
--     timeline ของ fixture สองไฟล์ (zz_wht_and_fx · zz_fcd_currency) พร้อมกับด่านนี้
-- ============================================================
do $$
declare v_tomorrow date := current_date + 1;
begin
  perform set_config('test.uid', (select id::text from y_uid where label = 'mgmt'), true);
  set local role authenticated;

  -- (ก) INSERT วันที่อนาคต → ปฏิเสธที่ DB
  perform pg_temp.must_fail_like('N1 ลงอัตราของวันพรุ่งนี้', format($q$
    insert into sri_os.fx_rates(currency, rate_date, thb_per_unit, source)
    values ('USD', %L, 37.00, 'manual') $q$, v_tomorrow),
    'ยังไม่มาถึง');

  -- (ข) **วันนี้ลงได้** — อัตราของวันนี้ประกาศแล้ว (ด่านต้องไม่แน่นเกิน)
  perform pg_temp.must_pass('N2 ลงอัตราของวันนี้', format($q$
    insert into sri_os.fx_rates(currency, rate_date, thb_per_unit, source, note)
    values ('USD', %L, 37.10, 'manual', 'อัตราของวันนี้') $q$, current_date));

  -- (ค) ย้ายวันของแถวที่ยังไม่มีใครใช้ ไปอนาคต → ปฏิเสธ
  perform pg_temp.must_fail_like('N3 ย้ายวันของอัตราไปอนาคต', format($q$
    update sri_os.fx_rates set rate_date = %L
     where currency = 'USD' and rate_date = %L $q$, v_tomorrow, current_date),
    'ยังไม่มาถึง');

  -- (ง) ย้ายไปอดีตยังได้ (แถวนี้ยังไม่มีใครใช้)
  perform pg_temp.must_pass('N4 ย้ายวันของอัตราไปอดีต', format($q$
    update sri_os.fx_rates set rate_date = %L
     where currency = 'USD' and rate_date = %L $q$, current_date - 3, current_date));

  reset role;

  if not exists (select 1 from sri_os.fx_rates
                  where currency = 'USD' and rate_date = current_date - 3) then
    raise exception 'FAIL: N4 — แถวที่ย้ายไปอดีตต้องอยู่ที่วันใหม่';
  end if;
  if exists (select 1 from sri_os.fx_rates where rate_date > current_date) then
    raise exception 'FAIL: N — ยังมีอัตราของวันที่ยังไม่มาถึงค้างอยู่';
  end if;
  if (select count(*) from sri_os.fn_fx_rate_future_rows()) <> 0 then
    raise exception 'FAIL: N — รายงานอัตราล่วงหน้าต้องว่างเปล่า';
  end if;

  raise notice 'ok N · ลงอัตราของวันพรุ่งนี้ถูกปฏิเสธ · วันนี้ลงได้ · ย้ายไปอนาคตไม่ได้ · ย้ายไปอดีตได้ · รายงานอัตราล่วงหน้าว่างเปล่า';
exception when others then
  reset role;
  raise;
end $$;

-- ============================================================
-- NM · **MUTATION** — ถอดด่านวันที่อนาคต แล้ววัดว่าเกิดอะไร
--      (อัตราที่เดาไว้ + ด่านห้ามแก้ย้อนหลัง = ติดอยู่กับตัวเลขที่เดาตลอดไป)
-- ============================================================
do $$
declare v_future date := current_date + 30;
begin
  drop trigger trg_fx_rates_no_future_date on sri_os.fx_rates;

  perform set_config('test.uid', (select id::text from y_uid where label = 'mgmt'), true);
  set local role authenticated;

  insert into sri_os.fx_rates(currency, rate_date, thb_per_unit, source, note)
  values ('USD', v_future, 45.00, 'manual', 'NM อัตราที่เดาไว้ล่วงหน้า 30 วัน');

  -- แล้วลงรายการที่อ้างอัตราที่เดาไว้ได้ทันที
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code', 'trf.fx_acquire',
    'doc_date', v_future::text, 'cash_date', v_future::text,
    'memo', 'NM ซื้อ 1,000 USD ด้วยอัตราที่เดาไว้ 45.00',
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', pg_temp.own('THANAKORN'),
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code', '1100',
                           'bank_account_id', '00000000-0000-0000-0000-0000000db002',
                           'debit', 45000, 'credit', 0, 'cf_category', 'none',
                           'currency', 'USD', 'amount_original', 1000,
                           'fx_rate', 45.00, 'fx_rate_date', v_future::text),
        jsonb_build_object('coa_code', '1100',
                           'bank_account_id', '00000000-0000-0000-0000-0000000db001',
                           'debit', 0, 'credit', 45000, 'cf_category', 'none'))))));

  -- และตอนนี้ **แก้อัตราที่เดาไว้ไม่ได้อีกแล้ว** เพราะมีรายการอ้างถึง (0015)
  perform pg_temp.must_fail_like('NM แก้อัตราที่เดาไว้ให้ตรงความจริง', format($q$
    update sri_os.fx_rates set thb_per_unit = 37.00
     where currency = 'USD' and rate_date = %L $q$, v_future),
    'มีรายการในสมุดหรือทะเบียนล็อตอ้างถึงแล้ว');

  reset role;

  raise notice 'ok NM (MUTATION) · ถอดด่านวันที่อนาคต → ลงอัตรา 45.00 ของอีก 30 วันข้างหน้าได้ แล้วลงรายการ 1,000 USD = 45,000 บาทจากอัตราที่ยังไม่มีใครรู้ · และเมื่อถึงวันจริงถ้าอัตราเป็น 37.00 **แก้ไม่ได้อีกแล้ว** (ด่าน 0015 ห้าม) → ติดอยู่กับยอดที่เดาไว้ สูงกว่าจริง 8,000 บาท · สองด่านนี้จึงต้องมาคู่กัน';
  raise exception 'ROLLBACK_NM';
exception when others then
  reset role;
  if sqlerrm like 'FAIL:%' then raise; end if;
  if sqlerrm <> 'ROLLBACK_NM' then raise; end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.fx_rates'::regclass
                    and g.tgname = 'trg_fx_rates_no_future_date'
                    and not g.tgisinternal) then
    raise exception 'FAIL: NM — trigger ไม่กลับมาหลัง rollback';
  end if;
  raise notice 'ok NMb · trigger วันที่อนาคตกลับมาหลัง rollback';
end $$;

rollback;
