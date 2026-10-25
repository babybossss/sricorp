-- ============================================================
-- SRI OS · **หมวดยอดยกมาที่ขาด 7 รหัส** + การกระทบยอดรายการระหว่างกัน
--            (tx-rules 25/10 + 20261025000013_intercompany_reconcile.sql)
--
-- รหัสที่ไฟล์ยอดตั้งต้นของลูกพี่มี แต่ก่อนหน้านี้ **ลงไม่ได้เลย**
--   `1220` ลูกหนี้อื่น · `1290` ค่าเผื่อหนี้สงสัยจะสูญ · `1310` ลูกหนี้ระหว่างกัน ·
--   `1710` เงินลงทุนในบริษัทในเครือ · `1800` ภาษีถูกหักรอเครดิต ·
--   `2200` เงินมัดจำรับจากผู้เช่า · `2310` เจ้าหนี้ระหว่างกัน
-- → หน้าจอปฏิเสธไฟล์ทั้งไฟล์ (ถูกแล้วที่ไม่ข้ามเงียบๆ) แต่นำเข้าไม่ได้
--
-- **ทุกเคสรันเป็น role `authenticated`** ไม่ใช่ superuser (บทเรียนรอบก่อน:
-- เทสต์ที่รันด้วยสิทธิ์สูงกว่าผู้ใช้จริงพิสูจน์เรื่องสิทธิ์/RLS ไม่ได้เลย)
--
-- สิ่งที่พิสูจน์
--   O0 · มีหมวดครบทั้ง 7 รหัส และทุกหมวด `cashflow = none` + ขาคู่เป็นส่วนของเจ้าของ
--   O1 · ลงได้จริงทั้ง 7 รหัสในฐานะ authenticated · งบดุลดุล · ไม่เข้า P&L
--   O2 · `1290` อยู่ **ฝั่งเครดิต** → ลูกหนี้สุทธิ 300,000 − 20,000 = 280,000
--   O3 · `1310` ลงข้างเดียวได้ (ยอดยกมาลงทีละผู้ถือ) **แต่** การกระทบยอด
--        ฟ้องทันทีว่าสองฝั่งไม่ตรง · ลง `2310` ของผู้ถืออีกฝ่ายแล้ว → ว่างเปล่า
--   O4 · ไม่มีขาเงินสด → ส่งบัญชีธนาคาร/วันเงินเคลื่อนมาต้องถูกปฏิเสธ
--   O5 · `1800` ไม่ใช่ค่าใช้จ่าย — ไม่มีบรรทัดไหนแตะ P&L
--   OM · **MUTATION** กลับทิศ `1290` เป็นฝั่งเดบิต แล้ววัดว่าลูกหนี้สุทธิบวมเท่าไร
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
create temporary table o_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into o_uid(label) values ('mgmt');
insert into auth.users(id) select id from o_uid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, 'opn-new@local', 'mgmt', 'management', true from o_uid u;

insert into sri_os.user_owner_access(user_id, owner_id)
select (select id from o_uid where label = 'mgmt'), o.id from sri_os.owners o;

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
values ('00000000-0000-0000-0000-0000000bb001'::uuid,
        (select id from sri_os.owners where code = 'THANAKORN'), 'SCB', 'ธนากร', 'ธนากร - SCB (ยอดยกมาใหม่)');

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

/**
 * ลงใบยอดยกมาหนึ่งใบ **โดยอ่านคู่บัญชีจากตารางกฎ** ไม่ใช่เขียน dr/cr ในเทสต์
 *
 * เขียนแบบนี้โดยตั้งใจ: ถ้าเทสต์กำหนดคู่บัญชีเอง มันจะไม่เคยจับได้เลยว่า
 * ตารางกฎใส่คู่บัญชีกลับทิศ (เช่น `1290` ไปอยู่ฝั่งเดบิต)
 */
create or replace function pg_temp.open_entry(p_code text, p_owner text, p_amount numeric,
                                              p_memo text) returns uuid
language plpgsql as $fn$
declare v jsonb; v_dr text; v_cr text;
begin
  select t.dr_coa_code, t.cr_coa_code into v_dr, v_cr
    from sri_os.txn_types t where t.code = p_code;
  if v_dr is null or v_cr is null then
    raise exception 'FAIL: ตารางกฎไม่มีคู่บัญชีของหมวด % — sync:rules ยังไม่ได้รัน?', p_code;
  end if;

  v := sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code', p_code,
    'doc_date', '2026-01-01',
    'memo', p_memo,
    'attachments', jsonb_build_array('ยอดตั้งต้น.pdf'),
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', pg_temp.own(p_owner),
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code', v_dr, 'debit', p_amount, 'credit', 0, 'cf_category', 'none'),
        jsonb_build_object('coa_code', v_cr, 'debit', 0, 'credit', p_amount, 'cf_category', 'none'))))));
  return ((v -> 'transaction_ids') ->> 0)::uuid;
end $fn$;

/** ยอดของบัญชีหนึ่ง (ฝั่งเดบิตเป็นบวก) รวมทุกผู้ถือ */
create or replace function pg_temp.bal(p_code text) returns numeric
language sql stable as $fn$
  select round(coalesce(sum(v.debit - v.credit), 0), 2)
    from sri_os.v_ledger_posted v
    join sri_os.chart_of_accounts c on c.id = v.coa_id
   where c.code = p_code;
$fn$;

do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.o_uid to authenticated', s);
end $$;

-- ============================================================
-- O0 · ตารางกฎต้องมีหมวดครบ และรูปของหมวดต้องถูก
-- ============================================================
do $$
declare v text; n int;
begin
  -- ครบทั้ง 7 รหัสที่ขาด
  select string_agg(x.code, ', ' order by x.code) into v
    from (values ('1220'), ('1290'), ('1310'), ('1710'), ('1800'), ('2200'), ('2310')) x(code)
   where not exists (select 1 from sri_os.txn_types t
                      where t.group_code = 'opening'
                        and x.code in (t.dr_coa_code, t.cr_coa_code));
  if v is not null then
    raise exception 'FAIL: O0 — ยังไม่มีหมวดยอดยกมาของรหัส: % → นำเข้าไฟล์จริงของลูกพี่ไม่ได้ (sync:rules แล้วหรือยัง)', v;
  end if;

  /**
   * ทุกหมวดยอดยกมาต้องไม่เข้างบกระแสเงินสด
   *
   * คอลัมน์จริงคือ `cf_group` และ `cashflow: "none"` ฝั่งโค้ดถูก sync เป็น
   * **`transfer`** ในชนิด enum ของ DB (`20260917000001_core.sql`) ซึ่งหมายถึง
   * "ไม่นับในงบกระแสเงินสด · ตัดออกตอน consolidate" — ไม่ใช่ `none`
   * เทียบกับค่าที่ **ไม่ใช่** operating/investing/financing จึงตรงความหมาย
   */
  select string_agg(t.code, ', ') into v
    from sri_os.txn_types t
   where t.group_code = 'opening'
     and t.cf_group::text in ('operating', 'investing', 'financing');
  if v is not null then
    raise exception 'FAIL: O0 — หมวดยอดยกมาที่เข้างบกระแสเงินสด: % (ยอดยกมาไม่ใช่กระแสเงินสดของงวด)', v;
  end if;

  -- ทุกหมวดยอดยกมาต้องมีขาคู่เป็นกำไรสะสม (3300) — หมวดใหม่ก็ต้องตามนี้
  select string_agg(t.code, ', ') into v
    from sri_os.txn_types t
   where t.group_code = 'opening'
     and '3300' not in (t.dr_coa_code, t.cr_coa_code);
  if v is not null then
    raise exception 'FAIL: O0 — หมวดยอดยกมาที่ขาคู่ไม่ใช่กำไรสะสม: %', v;
  end if;

  select count(*) into n from sri_os.txn_types where group_code = 'opening';
  raise notice 'ok O0 · หมวดยอดยกมา % หมวด · ครบทั้ง 7 รหัสที่ขาด · ไม่เข้างบกระแสเงินสด · ขาคู่เป็นกำไรสะสมทุกหมวด', n;
end $$;

-- ============================================================
-- O1 · ลงได้จริงทั้ง 7 รหัส **ในฐานะ authenticated** · งบดุลดุล
-- ============================================================
do $$
declare v_dr numeric; v_cr numeric;
begin
  perform set_config('test.uid', (select id::text from o_uid where label = 'mgmt'), true);
  set local role authenticated;

  perform pg_temp.open_entry('opn.receivable_rent',          'THANAKORN', 300000, 'ยอดยกมา ลูกหนี้ค่าเช่า 300,000');
  perform pg_temp.open_entry('opn.receivable_other',         'THANAKORN',  45000, 'ยอดยกมา ลูกหนี้อื่น 45,000');
  perform pg_temp.open_entry('opn.allowance',                'THANAKORN',  20000, 'ยอดยกมา ค่าเผื่อหนี้สงสัยจะสูญ 20,000');
  perform pg_temp.open_entry('opn.intercompany_receivable',  'THANAKORN', 500000, 'ยอดยกมา ลูกหนี้ระหว่างกัน 500,000');
  perform pg_temp.open_entry('opn.related_investment',       'THANAKORN', 900000, 'ยอดยกมา เงินลงทุนในบริษัทในเครือ 900,000');
  perform pg_temp.open_entry('opn.wht_credit',               'THANAKORN',  15000, 'ยอดยกมา ภาษีถูกหักรอเครดิต 15,000');
  perform pg_temp.open_entry('opn.tenant_deposit',           'THANAKORN',  80000, 'ยอดยกมา เงินมัดจำรับจากผู้เช่า 80,000');

  reset role;

  if pg_temp.bal('1220') <> 45000  then raise exception 'FAIL: O1 — 1220 ต้องเป็น 45,000 แต่ได้ %',  pg_temp.bal('1220'); end if;
  if pg_temp.bal('1290') <> -20000 then raise exception 'FAIL: O1 — 1290 ต้องเป็น −20,000 (ฝั่งเครดิต) แต่ได้ %', pg_temp.bal('1290'); end if;
  if pg_temp.bal('1310') <> 500000 then raise exception 'FAIL: O1 — 1310 ต้องเป็น 500,000 แต่ได้ %', pg_temp.bal('1310'); end if;
  if pg_temp.bal('1710') <> 900000 then raise exception 'FAIL: O1 — 1710 ต้องเป็น 900,000 แต่ได้ %', pg_temp.bal('1710'); end if;
  if pg_temp.bal('1800') <> 15000  then raise exception 'FAIL: O1 — 1800 ต้องเป็น 15,000 แต่ได้ %',  pg_temp.bal('1800'); end if;
  if pg_temp.bal('2200') <> -80000 then raise exception 'FAIL: O1 — 2200 ต้องเป็น −80,000 (หนี้สิน) แต่ได้ %', pg_temp.bal('2200'); end if;

  -- งบดุลดุล: Σ debit = Σ credit ของทุกใบที่ลงไป
  select coalesce(sum(v.debit), 0), coalesce(sum(v.credit), 0) into v_dr, v_cr
    from sri_os.v_ledger_posted v
   where v.txn_type_code like 'opn.%';
  if round(v_dr - v_cr, 2) <> 0 then
    raise exception 'FAIL: O1 — ยอดยกมาไม่สมดุล (debit % credit %)', v_dr, v_cr;
  end if;

  raise notice 'ok O1 · ลงครบทั้ง 7 รหัสในฐานะ authenticated · 1220=45,000 · 1290=(20,000) · 1310=500,000 · 1710=900,000 · 1800=15,000 · 2200=(80,000) · สมดุล';
exception when others then
  reset role;
  raise;
end $$;

-- ============================================================
-- O2 · `1290` อยู่ฝั่งเครดิต → **ลูกหนี้สุทธิ 280,000** ไม่ใช่ 320,000
-- ============================================================
do $$
declare v_net numeric;
begin
  v_net := pg_temp.bal('1200') + pg_temp.bal('1290');
  if v_net <> 280000 then
    raise exception 'FAIL: O2 — ลูกหนี้ค่าเช่าสุทธิต้องเป็น 280,000 (300,000 − 20,000) แต่ได้ % · ถ้าได้ 320,000 แปลว่าค่าเผื่อไปอยู่ฝั่งเดบิต = ลูกหนี้สุทธิบวมเท่าค่าเผื่อสองเท่า',
      v_net;
  end if;
  raise notice 'ok O2 · ค่าเผื่อหักจากลูกหนี้จริง: 300,000 − 20,000 = 280,000 (ถ้ากลับทิศจะได้ 320,000 · ต่าง 40,000)';
end $$;

-- ============================================================
-- O3 · `1310` ลงข้างเดียวได้ **แต่การกระทบยอดต้องฟ้อง**
--      แล้วลง `2310` ของผู้ถืออีกฝ่าย → ว่างเปล่า
-- ============================================================
do $$
declare r record; n int;
begin
  -- ตอนนี้มีแต่ฝั่งลูกหนี้ 500,000 → ต้องฟ้องว่าต่าง 500,000
  select * into r from sri_os.fn_intercompany_mismatch();
  if r.diff is null then
    raise exception 'FAIL: O3 — ลง 1310 ข้างเดียวแล้วการกระทบยอดต้องฟ้อง แต่ว่างเปล่า · ถ้าเงียบ งบรวมจะตัดรายการระหว่างกันไม่ลงโดยไม่มีใครรู้';
  end if;
  if r.diff <> 500000 then
    raise exception 'FAIL: O3 — ส่วนต่างต้องเป็น 500,000 แต่ได้ %', r.diff;
  end if;

  -- ลงฝั่งเจ้าหนี้ของผู้ถืออีกฝ่าย (ยอดยกมาลงทีละผู้ถือ จึงเป็นอีกใบ)
  perform set_config('test.uid', (select id::text from o_uid where label = 'mgmt'), true);
  set local role authenticated;
  perform pg_temp.open_entry('opn.intercompany_payable', 'SUTEE', 500000,
                             'ยอดยกมา เจ้าหนี้ระหว่างกันของสุธี 500,000');
  reset role;

  select count(*) into n from sri_os.fn_intercompany_mismatch();
  if n <> 0 then
    select * into r from sri_os.fn_intercompany_mismatch();
    raise exception 'FAIL: O3 — ลงครบสองฝั่งแล้วการกระทบยอดต้องว่างเปล่า แต่ยังฟ้อง: %', r.detail;
  end if;
  if pg_temp.bal('2310') <> -500000 then
    raise exception 'FAIL: O3 — 2310 ต้องเป็น −500,000 แต่ได้ %', pg_temp.bal('2310');
  end if;

  raise notice 'ok O3 · 1310 ลงข้างเดียวผ่าน (ยอดยกมาลงทีละผู้ถือ) · การกระทบยอดฟ้องส่วนต่าง 500,000 ทันที · ลง 2310 ของสุธีแล้วว่างเปล่า — สองฝั่งตรงกัน';
exception when others then
  reset role;
  raise;
end $$;

-- ============================================================
-- O4 · ไม่มีขาเงินสด → ส่งบัญชีธนาคาร/วันเงินเคลื่อนมาต้องถูกปฏิเสธ
--      (constraint ของ 20261009000003: หมวด cash_direction = none ห้ามมีขา 11xx)
-- ============================================================
do $$
begin
  perform set_config('test.uid', (select id::text from o_uid where label = 'mgmt'), true);
  set local role authenticated;

  -- เอาบัญชีธนาคารไปแปะบนบรรทัดที่ไม่ใช่ขาเงินสด
  perform pg_temp.must_fail_like('O4 ผูกบัญชีธนาคารกับบรรทัดที่ไม่ใช่เงินสด', format($q$
    select sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code', 'opn.wht_credit',
      'doc_date', '2026-01-01',
      'memo', 'O4 ภาษีถูกหักรอเครดิต + บัญชีธนาคาร (ผิด)',
      'attachments', jsonb_build_array('ยอดตั้งต้น.pdf'),
      'transactions', jsonb_build_array(jsonb_build_object(
        'owner_id', %L,
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code', '1800', 'bank_account_id', %L,
                             'debit', 1000, 'credit', 0, 'cf_category', 'none'),
          jsonb_build_object('coa_code', '3300', 'debit', 0, 'credit', 1000,
                             'cf_category', 'none'))))))
    $q$, pg_temp.own('THANAKORN'), '00000000-0000-0000-0000-0000000bb001'),
    'บัญชีธนาคาร');

  reset role;
  raise notice 'ok O4 · หมวดยอดยกมาที่ไม่มีขาเงินสด ผูกบัญชีธนาคารไม่ได้';
exception when others then
  reset role;
  raise;
end $$;

-- ============================================================
-- O5 · `1800` ไม่ใช่ค่าใช้จ่าย — ยอดยกมาทั้งชุดไม่แตะ P&L เลย
-- ============================================================
do $$
declare v text;
begin
  select string_agg(distinct c.code, ', ') into v
    from sri_os.v_ledger_posted v2
    join sri_os.chart_of_accounts c on c.id = v2.coa_id
   where v2.txn_type_code like 'opn.%'
     and c.type::text in ('income', 'expense');
  if v is not null then
    raise exception 'FAIL: O5 — ยอดยกมาแตะบัญชีกำไรขาดทุน: % · ยอดยกมาคือยอดคงเหลือ ไม่ใช่รายได้/ค่าใช้จ่ายของงวด', v;
  end if;
  raise notice 'ok O5 · ยอดยกมาทั้งชุดไม่มีบรรทัดในบัญชีรายได้/ค่าใช้จ่ายเลย (1800 เป็นสินทรัพย์ ไม่ใช่ค่าใช้จ่าย)';
end $$;

-- ============================================================
-- OM · **MUTATION** — กลับทิศ `1290` ไปฝั่งเดบิตในตารางกฎ แล้ววัดความเสียหาย
-- ============================================================
do $$
declare v_net numeric;
begin
  update sri_os.txn_types
     set dr_coa_code = '1290', cr_coa_code = '3300'
   where code = 'opn.allowance';

  perform set_config('test.uid', (select id::text from o_uid where label = 'mgmt'), true);
  set local role authenticated;
  perform pg_temp.open_entry('opn.allowance', 'THANAKORN', 20000, 'OM ค่าเผื่อกลับทิศ 20,000');
  reset role;

  v_net := pg_temp.bal('1200') + pg_temp.bal('1290');
  if v_net <> 300000 then
    raise exception 'FAIL: OM — หลังกลับทิศ ลูกหนี้สุทธิควรกลายเป็น 300,000 (ค่าเผื่อหักกันเอง) แต่ได้ % · ถ้าไม่เปลี่ยน แปลว่าเทสต์ O2 ไม่ได้วัดทิศของคู่บัญชีจริง',
      v_net;
  end if;

  raise notice 'ok OM (MUTATION) · กลับทิศ 1290 ไปฝั่งเดบิต → ใบใหม่หักล้างค่าเผื่อเดิม ลูกหนี้สุทธิกลายเป็น 300,000 แทน 280,000 · บวมขึ้น 20,000 ต่อการลงผิดหนึ่งใบ (และ 40,000 ถ้าลงผิดตั้งแต่ต้น) โดยงบดุลยังดุล';
  raise exception 'ROLLBACK_OM';
exception when others then
  reset role;
  if sqlerrm like 'FAIL:%' then raise; end if;
  if sqlerrm <> 'ROLLBACK_OM' then raise; end if;
end $$;

do $$
begin
  if (select dr_coa_code from sri_os.txn_types where code = 'opn.allowance') <> '3300' then
    raise exception 'FAIL: OM — mutation ไม่ถูกย้อนกลับ (opn.allowance ยัง dr = %)',
      (select dr_coa_code from sri_os.txn_types where code = 'opn.allowance');
  end if;
  if pg_temp.bal('1200') + pg_temp.bal('1290') <> 280000 then
    raise exception 'FAIL: OM — สภาพไม่ถูกย้อน ลูกหนี้สุทธิ %', pg_temp.bal('1200') + pg_temp.bal('1290');
  end if;
  raise notice 'ok OMb · สภาพหลัง mutation ถูกย้อนกลับครบ (ลูกหนี้สุทธิ 280,000)';
end $$;

rollback;
