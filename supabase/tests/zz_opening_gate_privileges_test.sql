-- ============================================================
-- SRI OS · **ประตูยอดตั้งต้นในฐานะ `authenticated` จริง**
--            (20261025000012_opening_gate_privileges.sql)
--
-- **ทำไมไฟล์นี้ต้องมีแยก**: `zz_reimport_opening_test.sql` เขียวทั้งไฟล์
-- แต่ฟีเจอร์ใช้ไม่ได้บนของจริง เพราะทุกเคสในนั้นรันเป็น **superuser**
-- ซึ่ง **ข้ามทั้ง `GRANT` และ RLS** → มันพิสูจน์เรื่องสิทธิ์ไม่ได้เลย
-- ไฟล์นี้ `set local role authenticated` ทุกเคส
--
-- สิ่งที่พิสูจน์
--   P1 · `fn_reimport_opening` **เรียกได้** ในฐานะ authenticated
--        (บั๊ก 1: เคย `permission denied for function fn_opening_set`)
--   P2 · ผู้ถือที่ **มีล็อต** อัปโหลดแก้ได้ และล็อตเดิมติดร่องรอยจริง
--        (บั๊ก 2: `update asset_lots` เคยได้ 0 แถวเงียบๆ เพราะไม่มี policy UPDATE)
--   P3 · ด่านขอบเขตผู้ถือ **ในตัวฟังก์ชัน** ทำงาน — ผู้ใช้ที่ไม่มีสิทธิ์ของผู้ถือนั้น
--        ถาม `fn_opening_set` / `fn_opening_fingerprint` ไม่ได้ (ไม่ใช่ได้ชุดว่าง)
--   P4 · policy UPDATE เปิด **ทางเดียว** — แก้คอลัมน์อื่น/ย้อนร่องรอยกลับ ไม่ได้
--   P5 · `anon` ยังเรียกไม่ได้ทั้งสองตัว
--   PM · **MUTATION** ถอน execute กลับ → ประตูพังทันทีด้วยข้อความเดิมของบั๊ก 1
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures (สร้างด้วยสิทธิ์สูง · เคสทั้งหมดรันเป็น authenticated)
-- ------------------------------------------------------------
create temporary table p_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into p_uid(label) values ('mgmt'), ('outsider');
insert into auth.users(id) select id from p_uid;

-- **outsider ต้องเป็น role ที่ไม่มี `owner.view_all`** ไม่งั้นมันเห็นทุกผู้ถือ
-- ตามกฎ (ไม่ใช่ตามบั๊ก) แล้วเคส P3 จะเขียวด้วยเหตุผลผิด
-- `manager` มี ledger.read + asset.view_assigned (ผ่านด่านสิทธิ์ที่ครอบตาราง)
-- แต่ **ไม่มี owner.view_all** → ต้องตกที่ด่านขอบเขตผู้ถือเท่านั้น
insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id,
       case u.label when 'mgmt' then 'gate-mgmt@local' else 'gate-out@local' end,
       u.label,
       case u.label when 'mgmt' then 'management' else 'manager' end,
       true
  from p_uid u;

-- mgmt เห็นทุกผู้ถือ · outsider **ไม่ได้รับสิทธิ์ผู้ถือใดเลย**
insert into sri_os.user_owner_access(user_id, owner_id)
select (select id from p_uid where label = 'mgmt'), o.id from sri_os.owners o;

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
values ('00000000-0000-0000-0000-0000000fb001'::uuid,
        (select id from sri_os.owners where code = 'THANAKORN'), 'SCB', 'ธนากร', 'ธนากร - SCB (ประตู)');

insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, currency)
select '00000000-0000-0000-0000-0000000fa001', 'GATE-PTT', 'หุ้น PTT (ประตู)',
       cat.class_id, cat.id, (select id from sri_os.owners where code = 'THANAKORN'), 'THB'
  from (select id, class_id from sri_os.asset_categories
         where code = 'PAPER_STOCK_LISTED') cat;

create or replace function pg_temp.own(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.owners where code = p_code $fn$;

create or replace function pg_temp.uid(p_label text) returns uuid
language sql stable as $fn$ select id from p_uid where label = p_label $fn$;

/** สลับเป็นผู้ใช้จริงในฐานะ role `authenticated` — **ทุกเคสต้องผ่านตัวนี้** */
create or replace function pg_temp.login(p_label text) returns void
language plpgsql as $fn$
begin
  perform set_config('test.uid', pg_temp.uid(p_label)::text, true);
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

/** ไฟล์ยอดตั้งต้นของธนากร: เงินฝาก + หลักทรัพย์ (ผูกทรัพย์) + ล็อต */
create or replace function pg_temp.file_tk(p_cash numeric, p_sec numeric, p_lot_cost numeric)
returns jsonb language sql stable as $fn$
  select jsonb_build_object(
    'entries', jsonb_build_array(
      jsonb_build_object(
        'txn_type_code', 'opn.cash',
        'doc_date', '2026-01-01', 'cash_date', '2026-01-01',
        'memo', 'ประตู: เงินฝากยกมา ' || p_cash::text,
        'attachments', jsonb_build_array('ยอดตั้งต้น.pdf'),
        'transactions', jsonb_build_array(jsonb_build_object(
          'owner_id', pg_temp.own('THANAKORN'),
          'lines', jsonb_build_array(
            jsonb_build_object('coa_code', '1100',
                               'bank_account_id', '00000000-0000-0000-0000-0000000fb001',
                               'debit', p_cash, 'credit', 0, 'cf_category', 'none'),
            jsonb_build_object('coa_code', '3300', 'debit', 0, 'credit', p_cash,
                               'cf_category', 'none'))))),
      jsonb_build_object(
        'txn_type_code', 'opn.securities',
        'doc_date', '2026-01-01',
        'memo', 'ประตู: หลักทรัพย์ยกมา ' || p_sec::text,
        'asset_id', '00000000-0000-0000-0000-0000000fa001',
        'attachments', jsonb_build_array('ยอดตั้งต้น.pdf'),
        'transactions', jsonb_build_array(jsonb_build_object(
          'owner_id', pg_temp.own('THANAKORN'),
          'lines', jsonb_build_array(
            jsonb_build_object('coa_code', '1700',
                               'asset_id', '00000000-0000-0000-0000-0000000fa001',
                               'debit', p_sec, 'credit', 0, 'cf_category', 'none'),
            jsonb_build_object('coa_code', '3300', 'debit', 0, 'credit', p_sec,
                               'cf_category', 'none')))))),
    'lots', jsonb_build_array(jsonb_build_object(
      'asset_id', '00000000-0000-0000-0000-0000000fa001',
      'acquired_date', '2026-01-01', 'quantity', 100, 'cost_thb', p_lot_cost)));
$fn$;

do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  -- role `authenticated` ต้องอ่าน pg_temp ของเทสต์ได้ ไม่งั้นตัวช่วยเรียกไม่ได้
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.p_uid to authenticated', s);
end $$;

-- ============================================================
-- P0 · โครงสร้าง — ไล่จาก catalog จริง
-- ============================================================
do $$
declare v text;
begin
  if to_regprocedure('sri_os.fn_reimport_opening(uuid, jsonb)') is null then
    raise exception 'FAIL: P0 — ไม่มี fn_reimport_opening (migration ไม่ถูก apply?) เทสต์นี้จะไม่ได้ตรวจอะไร';
  end if;

  -- สิทธิ์ execute ต้องเปิดให้ authenticated ครบทั้งสามตัวที่ประตูต้องใช้
  select string_agg(x.f, ', ') into v
    from (values ('sri_os.fn_reimport_opening(uuid, jsonb)'),
                 ('sri_os.fn_opening_set(uuid)'),
                 ('sri_os.fn_opening_fingerprint(uuid)')) x(f)
   where not has_function_privilege('authenticated', x.f::regprocedure, 'execute');
  if v is not null then
    raise exception 'FAIL: P0 — authenticated เรียกไม่ได้: % → ประตูจะ permission denied บนของจริง', v;
  end if;

  if not exists (select 1 from pg_policies
                  where schemaname = 'sri_os' and tablename = 'asset_lots'
                    and cmd = 'UPDATE') then
    raise exception 'FAIL: P0 — asset_lots ไม่มี policy UPDATE → การติดร่องรอยกลับรายการจะได้ 0 แถวเงียบๆ';
  end if;

  raise notice 'ok P0 · สิทธิ์ execute ครบสามฟังก์ชัน และ asset_lots มี policy UPDATE';
end $$;

-- ============================================================
-- P1 · **บั๊ก 1** — นำเข้าครั้งแรกในฐานะ authenticated จริง
-- ============================================================
do $$
declare v jsonb;
begin
  perform pg_temp.login('mgmt');
  set local role authenticated;

  v := sri_os.fn_reimport_opening(pg_temp.own('THANAKORN'), pg_temp.file_tk(1000000, 72000, 72000));

  if (v ->> 'posted')::int <> 2 then
    raise exception 'FAIL: P1 — ต้องลงใบใหม่ 2 ใบ แต่ได้ % · ผลลัพธ์: %', (v ->> 'posted'), v;
  end if;

  reset role;
  if (select count(*) from sri_os.asset_lots
       where asset_id = '00000000-0000-0000-0000-0000000fa001') <> 1 then
    raise exception 'FAIL: P1 — ต้องมีล็อตหนึ่งล็อตหลังนำเข้า';
  end if;

  raise notice 'ok P1 (บั๊ก 1 ปิดแล้ว) · authenticated เรียก fn_reimport_opening ได้: ลง 2 ใบ + 1 ล็อต (เดิม permission denied for function fn_opening_set)';
exception when others then
  reset role;
  raise;
end $$;

-- ============================================================
-- P2 · **บั๊ก 2** — ผู้ถือที่มีล็อต อัปโหลดแก้ได้ และล็อตเดิมติดร่องรอยจริง
--
--      แก้เงินฝาก 1,000,000 → 1,200,000 (ล็อตเดิมต้องถูกปิด ไม่ใช่ซ้อนกัน)
-- ============================================================
do $$
declare v jsonb; n_lots int; n_closed int; v_units numeric;
begin
  perform pg_temp.login('mgmt');
  set local role authenticated;

  v := sri_os.fn_reimport_opening(pg_temp.own('THANAKORN'), pg_temp.file_tk(1200000, 72000, 72000));

  if (v ->> 'reversed')::int <> 2 then
    raise exception 'FAIL: P2 — ต้องกลับรายการชุดเดิม 2 ใบ แต่ได้ % · ผลลัพธ์: %', (v ->> 'reversed'), v;
  end if;

  reset role;

  select count(*), count(*) filter (where reversed_by_txn_id is not null)
    into n_lots, n_closed
    from sri_os.asset_lots where asset_id = '00000000-0000-0000-0000-0000000fa001';

  if n_lots <> 2 then
    raise exception 'FAIL: P2 — ต้องมีสองล็อตในทะเบียน (เดิมปิดแล้ว + ใหม่) แต่ได้ %', n_lots;
  end if;
  if n_closed <> 1 then
    raise exception 'FAIL: P2 — ล็อตเดิมต้องถูกติดร่องรอยว่ากลับรายการแล้ว 1 ล็อต แต่ได้ % · ถ้าได้ 0 แปลว่า update asset_lots ยังถูก RLS กรองทิ้งเงียบๆ (บั๊ก 2)',
      n_closed;
  end if;

  v_units := sri_os.fn_asset_units('00000000-0000-0000-0000-0000000fa001');
  if v_units <> 100 then
    raise exception 'FAIL: P2 — จำนวนคงเหลือต้องเป็น 100 หุ้น (ไม่ใช่ 200 จากล็อตซ้ำ) แต่ได้ %', v_units;
  end if;

  raise notice 'ok P2 (บั๊ก 2 ปิดแล้ว) · อัปโหลดแก้ของผู้ถือที่มีล็อต: กลับรายการ 2 ใบ · ล็อตเดิมถูกปิด 1 ล็อต · จำนวนคงเหลือ 100 หุ้น (ไม่ใช่ 200 จากล็อตที่ซ้อนกัน)';
exception when others then
  reset role;
  raise;
end $$;

-- ============================================================
-- P3 · ด่านขอบเขตผู้ถือ **ในตัวฟังก์ชัน** — definer ที่เปิดให้เรียกต้องตรวจเอง
--      ผู้ใช้ที่ไม่มีสิทธิ์ของผู้ถือนั้นต้องถูกปฏิเสธ **ไม่ใช่ได้ชุดว่าง**
--      (ชุดว่างจะถูกแปลว่า "ยังไม่มียอดตั้งต้น" แล้วลงทับของจริง)
-- ============================================================
do $$
begin
  perform pg_temp.login('outsider');
  set local role authenticated;

  perform pg_temp.must_fail_like('P3 outsider ถาม fn_opening_set',
    format($q$ select sri_os.fn_opening_set(%L) $q$, pg_temp.own('THANAKORN')),
    'ไม่มีสิทธิ์อ่านยอดตั้งต้นของผู้ถือนี้');

  perform pg_temp.must_fail_like('P3 outsider ถาม fn_opening_fingerprint',
    format($q$ select sri_os.fn_opening_fingerprint(%L) $q$, pg_temp.own('THANAKORN')),
    'ไม่มีสิทธิ์อ่านยอดตั้งต้นของผู้ถือนี้');

  reset role;
  raise notice 'ok P3 · definer ที่เปิดให้ authenticated เรียก ตรวจขอบเขตผู้ถือเอง — outsider ถูกปฏิเสธเสียงดัง ไม่ได้ชุดว่าง';
exception when others then
  reset role;
  raise;
end $$;

-- ============================================================
-- P4 · policy UPDATE เปิด **ทางเดียว** — ไม่ได้เปิดให้แก้ล็อตทั้งแถว
-- ============================================================
do $$
declare v_lot uuid; n int;
begin
  select id into v_lot from sri_os.asset_lots
   where asset_id = '00000000-0000-0000-0000-0000000fa001' and reversed_by_txn_id is null;

  perform pg_temp.login('mgmt');
  set local role authenticated;

  -- (ก) แก้ตัวเลขต้นทุน → ด่าน append-only ปฏิเสธ (RLS กรองคอลัมน์ไม่ได้ จึงต้องมีสองชั้น)
  perform pg_temp.must_fail_like('P4 แก้ต้นทุนของล็อต',
    format($q$ update sri_os.asset_lots set cost_thb = 1 where id = %L $q$, v_lot),
    'แก้ล็อตที่ลงไว้แล้วไม่ได้');

  -- (ข) ติดร่องรอยโดยอ้างใบที่ไม่ได้กลับรายการใบที่สร้างล็อต → ปฏิเสธ
  perform pg_temp.must_fail_like('P4 ติดร่องรอยด้วยใบมั่ว',
    format($q$ update sri_os.asset_lots
                  set reversed_by_txn_id = (select id from sri_os.transactions
                                             where reverses_id is null limit 1),
                      reversed_at = now()
                where id = %L $q$, v_lot),
    'ไม่ได้กลับรายการใบที่สร้างล็อต');

  -- (ค) ย้อนร่องรอยของล็อตที่ถูกปิดแล้วกลับเป็น null → policy `using` กรองทิ้ง (0 แถว)
  update sri_os.asset_lots set reversed_by_txn_id = null, reversed_at = null
   where reversed_by_txn_id is not null;
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'FAIL: P4 — ย้อนร่องรอยกลับเป็น null ได้ % แถว · policy ต้องเปิดทางเดียว', n;
  end if;

  reset role;
  if (select count(*) from sri_os.asset_lots
       where asset_id = '00000000-0000-0000-0000-0000000fa001'
         and reversed_by_txn_id is not null) <> 1 then
    raise exception 'FAIL: P4 — ร่องรอยของล็อตที่ถูกปิดหายไป';
  end if;

  raise notice 'ok P4 · policy UPDATE เปิดทางเดียว: แก้ตัวเลขไม่ได้ · อ้างใบมั่วไม่ได้ · ย้อนร่องรอยกลับได้ 0 แถว';
exception when others then
  reset role;
  raise;
end $$;

-- ============================================================
-- P5 · `anon` ต้องยังเรียกไม่ได้ทั้งสองตัว (เปิดให้ authenticated ไม่ใช่เปิดให้ทุกคน)
-- ============================================================
do $$
declare v text;
begin
  select string_agg(x.f, ', ') into v
    from (values ('sri_os.fn_opening_set(uuid)'),
                 ('sri_os.fn_opening_fingerprint(uuid)'),
                 ('sri_os.fn_reimport_opening(uuid, jsonb)')) x(f)
   where has_function_privilege('anon', x.f::regprocedure, 'execute')
      or has_function_privilege('public', x.f::regprocedure, 'execute');
  if v is not null then
    raise exception 'FAIL: P5 — anon/PUBLIC เรียกได้: %', v;
  end if;
  raise notice 'ok P5 · anon/PUBLIC ยังเรียกไม่ได้ทั้งสามตัว';
end $$;

-- ============================================================
-- PM · **MUTATION** — ถอน execute กลับ แล้วยืนยันว่าประตูพังด้วยข้อความของบั๊ก 1
--      พิสูจน์ว่า P1/P2 เขียวเพราะ `grant` จริง ไม่ใช่เพราะรันด้วยสิทธิ์สูง
-- ============================================================
do $$
begin
  execute 'revoke execute on function sri_os.fn_opening_set(uuid) from authenticated';

  perform pg_temp.login('mgmt');
  set local role authenticated;

  perform pg_temp.must_fail_like('PM ถอน execute แล้วประตูต้องพัง',
    format($q$ select sri_os.fn_reimport_opening(%L, %L::jsonb) $q$,
           pg_temp.own('THANAKORN'), pg_temp.file_tk(1300000, 72000, 72000)::text),
    'permission denied for function fn_opening_set');

  reset role;
  execute 'grant execute on function sri_os.fn_opening_set(uuid) to authenticated';

  raise notice 'ok PM (MUTATION) · ถอน execute ของ fn_opening_set → ประตูพังทันทีด้วย "permission denied for function fn_opening_set" ซึ่งคือข้อความเดิมของบั๊ก 1 · แปลว่า P1/P2 เขียวเพราะ grant จริง ไม่ใช่เพราะเทสต์รันด้วยสิทธิ์สูง';
exception when others then
  reset role;
  execute 'grant execute on function sri_os.fn_opening_set(uuid) to authenticated';
  raise;
end $$;

rollback;
