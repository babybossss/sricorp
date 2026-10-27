-- ============================================================
-- SRI OS · **ประตูสร้างร่าง** (C-3) + **ช่องบัญชีธนาคารของร่าง** (C-4)
--            (20261025000020_draft_gate.sql)
--
-- สภาพก่อนไฟล์นี้: Staff มีสิทธิ์ `txn.create` แต่ไม่มีประตูที่ตรวจว่าร่าง
-- ที่คีย์ไปจะ **อนุมัติได้** หรือไม่ · และร่างไม่มีช่องบัญชีธนาคาร →
-- รายการที่เงินเคลื่อน (ครึ่งหนึ่งของรายการจริง) อนุมัติไม่ได้เลย
--
-- **ทุกเคสรันเป็น role `authenticated`** ไม่ใช่ superuser
--
-- สิ่งที่พิสูจน์
--   G0 · โครงสร้าง: คอลัมน์ + FK + trigger BEFORE INSERT OR UPDATE + สิทธิ์เรียกประตู
--   G1 · **Staff คีย์ร่างได้จริง** ขึ้นคิว · และ **Staff อนุมัติเองไม่ได้** (สมุดไม่ขยับ)
--   G2 · ผู้อนุมัติกดอนุมัติร่างนั้น → **ลงสมุดได้จริง ยอดถูก**
--   G3 · **ร่างที่เงินเคลื่อน + บัญชีธนาคาร** → อนุมัติแล้วได้บรรทัดเงินสดที่ผูกบัญชีถูกตัว
--   **G4 · ร่างที่สร้างได้แต่อนุมัติไม่ได้ ต้องไม่มี** — ไล่ **ทุกหมวดที่ประตูยอม**
--        สร้างร่าง + อนุมัติด้วยคู่บัญชีจากตารางกฎ (ไม่พิมพ์คู่บัญชีเองในเทสต์)
--        บนฐานข้อมูลที่มียอดคงเหลือจริง → ต้องผ่าน **ทุกหมวด**
--        (ไฟล์นี้ต้องรันหลัง 20261025000021 ด้วย — การไล่ครั้งแรกเจอว่าหมวด
--         ล้างเครดิตภาษี `inv.wht_refund` ลงไม่ได้เลย ซึ่งเป็นรูของด่าน gross-up)
--   G5 · `created_by` ปลอมไม่ได้ · ร่างเกิดมาเป็น approved ไม่ได้
--   G6 · รูปร่างที่อนุมัติไม่ได้ ถูกปฏิเสธ **ตอนคีย์** พร้อมบอกเหตุผล
--   G7 · แก้ร่าง pending ให้กลายเป็นร่างที่อนุมัติไม่ได้ ก็ไม่ได้
--   **GM · MUTATION** — ถอดประตูแล้ววัดได้: ร่างค้างคิวที่อนุมัติไม่ได้ (4,300) +
--        ร่างที่ INSERT มาเป็น approved ชี้ใบในสมุดเอง = ข้ามด่าน C-1/C-2 ทั้งชุด
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
create temporary table g_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into g_uid(label) values ('clerk'), ('appA');

insert into auth.users(id) select id from g_uid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, u.label || '@draftgate.local', u.label,
       case u.label when 'clerk' then 'staff' else 'management' end, true
  from g_uid u;
insert into sri_os.user_owner_access(user_id, owner_id)
select u.id, o.id from g_uid u, sri_os.owners o;

create temporary table g_ref (label text primary key, id uuid not null);
insert into g_ref(label, id) values
  ('bank_thb',  '00000000-0000-0000-0000-00000000bb01'),
  ('bank_usd',  '00000000-0000-0000-0000-00000000bb02'),
  ('bank_corp', '00000000-0000-0000-0000-00000000bb03'),
  ('contact',   '00000000-0000-0000-0000-00000000cc01'),
  ('asset',     '00000000-0000-0000-0000-00000000aa01');

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name, currency)
select g.id, o.id, 'KBANK', 'ทดสอบ', v.nm, v.cur
  from g_ref g
  join (values ('bank_thb', 'บัญชีบาทของธนากร', 'THB', 'THANAKORN'),
               ('bank_usd', 'บัญชีดอลลาร์ของธนากร', 'USD', 'THANAKORN'),
               ('bank_corp', 'บัญชีบาทของบริษัท', 'THB', 'SRI_CORP')) v(label, nm, cur, owner)
       on v.label = g.label
  join sri_os.owners o on o.code = v.owner;

insert into sri_os.contacts(id, first_name, types)
select id, 'ผู้เช่าทดสอบ', array['tenant'] from g_ref where label = 'contact';

insert into sri_os.assets(id, code, name, class_id, category_id, owner_id)
select g.id, 'DG-1', 'ห้องทดสอบประตูร่าง', k.class_id, k.id, o.id
  from g_ref g,
       (select class_id, id from sri_os.asset_categories order by code limit 1) k,
       sri_os.owners o
 where g.label = 'asset' and o.code = 'THANAKORN';

create or replace function pg_temp.own(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.owners where code = p_code $fn$;
create or replace function pg_temp.uid(p text) returns uuid
language sql stable as $fn$ select id from g_uid where label = p $fn$;
create or replace function pg_temp.ref(p text) returns uuid
language sql stable as $fn$ select id from g_ref where label = p $fn$;
create or replace function pg_temp.login(p text) returns void
language sql as $fn$ select set_config('test.uid', (select id::text from g_uid where label = p), true) $fn$;

create or replace function pg_temp.must_fail_like(p_label text, p_sql text, p_needle text)
returns void language plpgsql as $fn$
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

create or replace function pg_temp.n_txn() returns int
language sql stable as $fn$
  select count(*)::int from sri_os.transactions where status::text = 'posted'
$fn$;
create or replace function pg_temp.n_pending() returns int
language sql stable as $fn$
  select count(*)::int from sri_os.draft_entries where status = 'pending'
$fn$;
create or replace function pg_temp.sum_coa(p_code text) returns numeric
language sql stable as $fn$
  select coalesce(sum(v.debit - v.credit), 0)
    from sri_os.v_ledger_posted v
    join sri_os.chart_of_accounts c on c.id = v.coa_id
   where c.code = p_code
$fn$;

do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.g_uid to authenticated', s);
  execute format('grant select on %I.g_ref to authenticated', s);
end $$;

-- ============================================================
-- G0 · โครงสร้าง
-- ============================================================
do $$
declare n int; v text;
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'sri_os' and table_name = 'draft_entries'
                    and column_name = 'bank_account_id') then
    raise exception 'FAIL: G0 — ไม่มีคอลัมน์ draft_entries.bank_account_id (C-4) · migration ไม่ถูก apply?';
  end if;
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.draft_entries'::regclass
                    and g.tgname = 'trg_draft_entry_postable' and not g.tgisinternal
                    and (g.tgtype & 2) <> 0 and (g.tgtype & 4) <> 0 and (g.tgtype & 16) <> 0) then
    raise exception 'FAIL: G0 — ไม่มี trigger trg_draft_entry_postable แบบ BEFORE INSERT OR UPDATE';
  end if;
  foreach v in array array['sri_os.fn_create_draft(jsonb)',
                           'sri_os.fn_draft_allowed_types()'] loop
    if not has_function_privilege('authenticated', v::regprocedure, 'execute') then
      raise exception 'FAIL: G0 — authenticated เรียก % ไม่ได้', v;
    end if;
  end loop;
  if not has_function_privilege('authenticated',
       'sri_os.fn_draft_entry_problem(uuid, text, date, date, numeric, uuid, uuid, uuid, uuid, text[])'::regprocedure,
       'execute') then
    raise exception 'FAIL: G0 — ฟอร์ม (authenticated) ถามล่วงหน้าไม่ได้ว่าร่างนี้คีย์ได้ไหม';
  end if;

  select count(*) into n from sri_os.fn_draft_allowed_types();
  raise notice 'ok G0 · คอลัมน์ + FK + trigger BEFORE INSERT OR UPDATE + สิทธิ์ครบ · หมวดที่คีย์เป็นร่างได้ % หมวด (จาก % หมวดที่เปิดใช้)',
    n, (select count(*) from sri_os.txn_types where is_active);
end $$;

-- ============================================================
-- G1 + G2 · Staff คีย์ → ขึ้นคิว → Staff อนุมัติเองไม่ได้ → ผู้อนุมัติลงสมุดได้
-- ============================================================
do $$
declare v_out jsonb; v_draft uuid; n0 int;
begin
  set local role authenticated;
  perform pg_temp.login('clerk');
  n0 := pg_temp.n_pending();

  -- G1 · คีย์ร่างผ่านปากทาง (ค้างจ่าย: ยังไม่มีวันเงินเคลื่อน)
  v_out := sri_os.fn_create_draft(jsonb_build_object(
    'owner_id', pg_temp.own('THANAKORN'),
    'txn_type_code', 'exp.other',
    'doc_date', '2026-02-01',
    'amount', 12000,
    'memo', 'G1 ค่าใช้จ่ายที่พนักงานคีย์',
    'attachments', jsonb_build_array('ใบแจ้งหนี้.pdf')));
  v_draft := (v_out ->> 'draft_id')::uuid;
  if v_draft is null then
    raise exception 'FAIL: G1 — ปากทางไม่คืนเลขร่าง';
  end if;
  if pg_temp.n_pending() <> n0 + 1 then
    raise exception 'FAIL: G1 — ร่างต้องขึ้นคิวอนุมัติ (ก่อน % หลัง %)', n0, pg_temp.n_pending();
  end if;
  if (select created_by from sri_os.draft_entries where id = v_draft) <> pg_temp.uid('clerk') then
    raise exception 'FAIL: G1 — ชื่อคนคีย์ต้องเป็น clerk';
  end if;
  if (select status::text from sri_os.draft_entries where id = v_draft) <> 'pending' then
    raise exception 'FAIL: G1 — ร่างใหม่ต้องเป็น pending';
  end if;

  -- G1b · Staff อนุมัติเองไม่ได้ (ไม่มี ledger.approve) · สมุดต้องไม่ขยับ
  if pg_temp.n_txn() <> 0 then
    raise exception 'FAIL: G1b — สมุดต้องว่างก่อนอนุมัติ แต่มี % ใบ', pg_temp.n_txn();
  end if;
  begin
    perform sri_os.fn_approve_draft(v_draft, jsonb_build_object(
      'txn_type_code', 'exp.other', 'doc_date', '2026-02-01', 'memo', 'G1b staff แอบลงสมุด',
      'attachments', jsonb_build_array('ใบแจ้งหนี้.pdf'),
      'transactions', jsonb_build_array(jsonb_build_object(
        'owner_id', pg_temp.own('THANAKORN'),
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code', '5900', 'debit', 12000, 'credit', 0, 'cf_category', 'operating'),
          jsonb_build_object('coa_code', '2100', 'debit', 0, 'credit', 12000, 'cf_category', 'operating'))))));
    raise exception 'FAIL: G1b — Staff อนุมัติร่างเองได้ = การแยกขั้นหายไป';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  if pg_temp.n_txn() <> 0 then
    raise exception 'FAIL: G1b — Staff ลงสมุดได้ % ใบ', pg_temp.n_txn();
  end if;

  -- G2 · ผู้อนุมัติกดอนุมัติ → ลงสมุดจริง
  perform pg_temp.login('appA');
  perform sri_os.fn_approve_draft(v_draft, jsonb_build_object(
    'txn_type_code', 'exp.other', 'doc_date', '2026-02-01', 'memo', 'G2 อนุมัติร่างของพนักงาน',
    'attachments', jsonb_build_array('ใบแจ้งหนี้.pdf'),
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', pg_temp.own('THANAKORN'),
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code', '5900', 'debit', 12000, 'credit', 0, 'cf_category', 'operating'),
        jsonb_build_object('coa_code', '2100', 'debit', 0, 'credit', 12000, 'cf_category', 'operating'))))));

  if pg_temp.n_txn() <> 1 then
    raise exception 'FAIL: G2 — ต้องมี 1 ใบในสมุด แต่มี %', pg_temp.n_txn();
  end if;
  if pg_temp.sum_coa('5900') <> 12000 or pg_temp.sum_coa('2100') <> -12000 then
    raise exception 'FAIL: G2 — ยอดไม่ถูก (5900 = % · 2100 = %)',
      pg_temp.sum_coa('5900'), pg_temp.sum_coa('2100');
  end if;
  if pg_temp.sum_coa('1100') <> 0 then
    raise exception 'FAIL: G2 — ร่างค้างจ่ายต้องไม่มีเงินสดเคลื่อน';
  end if;

  reset role;
  raise notice 'ok G1-G2 · Staff คีย์ร่างได้และขึ้นคิว (ชื่อคนคีย์ = clerk) · Staff อนุมัติเองไม่ได้ (สมุด 0 ใบ) · ผู้อนุมัติกดแล้วลงสมุดจริง 12,000 เข้า 5900/2100 ไม่มีเงินสดเคลื่อน';
exception when others then
  reset role; raise;
end $$;

-- ============================================================
-- G3 · C-4 · ร่างที่เงินเคลื่อน → ต้องลงสมุดพร้อมบรรทัดเงินสดที่ผูกบัญชีถูกตัว
-- ============================================================
do $$
declare v_draft uuid; v_bank uuid; v_line record;
begin
  set local role authenticated;
  v_bank := pg_temp.ref('bank_thb');
  perform pg_temp.login('clerk');

  v_draft := (sri_os.fn_create_draft(jsonb_build_object(
    'owner_id', pg_temp.own('THANAKORN'),
    'txn_type_code', 'exp.other',
    'doc_date', '2026-02-02',
    'cash_date', '2026-02-02',
    'bank_account_id', v_bank,
    'amount', 7500,
    'memo', 'G3 จ่ายจริงจากบัญชีบาท',
    'attachments', jsonb_build_array('สลิป.pdf'))) ->> 'draft_id')::uuid;

  perform pg_temp.login('appA');
  perform sri_os.fn_approve_draft(v_draft, jsonb_build_object(
    'txn_type_code', 'exp.other', 'doc_date', '2026-02-02', 'cash_date', '2026-02-02',
    'memo', 'G3 อนุมัติใบที่เงินออกจริง',
    'attachments', jsonb_build_array('สลิป.pdf'),
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', pg_temp.own('THANAKORN'),
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code', '5900', 'debit', 7500, 'credit', 0, 'cf_category', 'operating'),
        jsonb_build_object('coa_code', '1100', 'debit', 0, 'credit', 7500, 'cf_category', 'operating',
                           'bank_account_id', v_bank))))));

  if pg_temp.sum_coa('1100') <> -7500 then
    raise exception 'FAIL: G3 — เงินสดต้องลดลง 7,500 แต่ได้ %', pg_temp.sum_coa('1100');
  end if;
  select l.bank_account_id into v_line
    from sri_os.transaction_lines l
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where c.code = '1100' limit 1;
  if v_line.bank_account_id is distinct from v_bank then
    raise exception 'FAIL: G3 — บรรทัดเงินสดต้องผูกบัญชีที่ร่างระบุ';
  end if;
  if (select bank_account_id from sri_os.draft_entries where id = v_draft) is distinct from v_bank then
    raise exception 'FAIL: G3 — ร่างต้องเก็บบัญชีธนาคารไว้ (C-4)';
  end if;

  reset role;
  raise notice 'ok G3 · ร่างที่มีวันเงินเคลื่อน + บัญชีธนาคาร → อนุมัติแล้วได้บรรทัดเงินสด -7,500 ผูกบัญชีถูกตัว (ก่อน C-4 ร่างแบบนี้เก็บเลขบัญชีไม่ได้เลย = อนุมัติไม่ได้)';
exception when others then
  reset role; raise;
end $$;

-- ============================================================
-- G4-fixture · **ยอดคงเหลือจริงก่อนไล่ทุกหมวด**
--
-- หมวดกลุ่มล้างลูกหนี้ / ค่าเผื่อ / หนี้สูญ มีด่านที่ตรวจ **ยอดเทียบกับยอด
-- คงเหลือ** (ล้างลูกหนี้ที่ไม่มีอยู่ไม่ได้ · ตั้งค่าเผื่อเกินหนี้ไม่ได้ ·
-- รับคืนหนี้สูญเกินที่ตัดไปไม่ได้) → ถ้าไล่ทุกหมวดบนฐานข้อมูลเปล่า หมวดพวกนี้
-- จะตกด้วยเหตุผล "ไม่มียอดให้ล้าง" ซึ่ง **ไม่ใช่ความผิดของประตูร่าง**
--
-- จึงตั้งยอดคงเหลือให้เหมือนของจริงก่อน แล้วค่อยไล่ — ได้คำตอบที่แรงกว่า:
-- “ทุกหมวดที่ประตูยอม อนุมัติผ่านได้จริงเมื่อยอดคงเหลือสมเหตุสมผล”
-- (ส่วน "ยอดเกินยอดคงเหลือ" เป็นด่านของตอนอนุมัติโดยตั้งใจ เพราะยอดคงเหลือ
--  ขยับได้ระหว่างคีย์กับอนุมัติ ประตูร่างสัญญาแทนไม่ได้)
-- ============================================================
create or replace function pg_temp.post_as_appA(p_code text, p_amount numeric,
                                                p_accrued boolean,
                                                p_asset uuid default null,
                                                p_memo text default null)
returns void language plpgsql as $fn$
declare t record; v_dr text; v_cr text; v_asset uuid;
begin
  select * into t from sri_os.txn_types where code = p_code;
  -- ขาค้างรับ: แทนขาเงินสดด้วยบัญชีพักจากตารางกฎ (ไม่พิมพ์รหัสเองในเทสต์)
  v_dr := case when p_accrued and t.dr_coa_code ~ '^11' then t.accrual_coa_code
               else t.dr_coa_code end;
  v_cr := case when p_accrued and t.cr_coa_code ~ '^11' then t.accrual_coa_code
               else t.cr_coa_code end;
  -- ทรัพย์เฉพาะใบ (ใช้ตอนตั้งยอดคงเหลือของหมวดย้ายบัญชี) · ไม่ส่งมา = ทรัพย์ร่วมของไฟล์นี้
  v_asset := coalesce(p_asset, pg_temp.ref('asset'));
  perform pg_temp.login('appA');
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code', p_code,
    'doc_date', '2026-01-05',
    'memo', coalesce(p_memo, 'G4-fixture ' || p_code),
    'asset_id', case when t.requires_asset or p_asset is not null then v_asset end,
    'contact_id', case when t.requires_contact then pg_temp.ref('contact') end,
    'attachments', jsonb_build_array('หลักฐาน.pdf'),
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', pg_temp.own('THANAKORN'),
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code', v_dr, 'debit', p_amount, 'credit', 0,
                           'cf_category', t.cf_group::text,
                           'asset_id', case when t.requires_asset or p_asset is not null then v_asset end),
        jsonb_build_object('coa_code', v_cr, 'debit', 0, 'credit', p_amount,
                           'cf_category', t.cf_group::text,
                           'asset_id', case when t.requires_asset or p_asset is not null then v_asset end))))));
end $fn$;

do $$
begin
  set local role authenticated;
  -- ลูกหนี้สามบัญชี (1200/1210/1220) จากขาค้างรับของหมวดรายได้
  perform pg_temp.post_as_appA('inc.rent', 50000, true);
  perform pg_temp.post_as_appA('inc.interest_srr', 50000, true);
  -- ลูกหนี้อื่น (1220) มาจาก **ยอดยกมา** เท่านั้น — หมวดรายได้ที่พักยอดไว้ที่ 1220
  -- ตั้งค้างไม่ได้ (can_accrue = false เพราะ 1220 ยังไม่มีหมวดสำหรับล้าง)
  -- ข้อนี้คือเหตุผลที่ adj.writeoff_other มีอยู่: ตัดลูกหนี้อื่นที่ยกมาจากระบบเก่า
  perform pg_temp.post_as_appA('opn.receivable_other', 50000, false);
  -- ค่าเผื่อหนี้สงสัยจะสูญ แล้วตัดหนี้สูญส่วนหนึ่ง (เปิดทางให้ "หนี้สูญได้รับคืน")
  perform pg_temp.post_as_appA('adj.doubtful', 30000, false);
  perform pg_temp.post_as_appA('adj.writeoff_rent', 10000, false);
  reset role;

  if pg_temp.sum_coa('1200') <> 40000 or pg_temp.sum_coa('1210') <> 50000
     or pg_temp.sum_coa('1220') <> 50000 or pg_temp.sum_coa('1290') <> -20000 then
    raise exception 'FAIL: G4-fixture — ยอดตั้งต้นไม่ตรง (1200 % · 1210 % · 1220 % · 1290 %)',
      pg_temp.sum_coa('1200'), pg_temp.sum_coa('1210'),
      pg_temp.sum_coa('1220'), pg_temp.sum_coa('1290');
  end if;
  raise notice 'ok G4-fixture · ยอดคงเหลือก่อนไล่ทุกหมวด: ลูกหนี้ 1200 = 40,000 · 1210 = 50,000 · 1220 = 50,000 · ค่าเผื่อ 1290 = 20,000 · ตัดหนี้สูญสะสม 10,000';
exception when others then
  reset role; raise;
end $$;

/* ============================================================
 * G4-fixture (2) · **หมวดย้ายยอดระหว่างบัญชีของทรัพย์ชิ้นเดียวกัน**
 *
 * หมวดพวกนี้ (ย้ายวัตถุประสงค์อสังหาฯ) ย้ายได้เฉพาะ **ทั้งก้อน** —
 * ด่าน `fn_assert_asset_account_balance_nonneg` (20261027161500) ปฏิเสธการย้าย
 * บางส่วนและการย้ายเกินยอดคงเหลือ · การไล่หมวดของ G4 ใช้ยอด 1,000 ทุกใบ
 * จึงต้องให้ทรัพย์ของหมวดนั้นมียอดคงเหลือในบัญชีต้นทาง **1,000 พอดี**
 * เหตุผลเดียวกับ fixture ชุดแรก: ด่านที่เทียบกับยอดคงเหลือไม่ใช่ความผิดของประตูร่าง
 *
 * คัดหมวดจาก **กฎ** (สองขาเป็นบัญชีถือครองทรัพย์ทั้งคู่ = ใบย้าย ไม่ใช่ซื้อ/ขาย)
 * ไม่ใช่รายชื่อรหัสหมวด — หมวดย้ายตัวใหม่ในอนาคตได้ fixture เองทันที
 * ฐานข้อมูลที่ยังไม่มีด่านนี้ (ฟังก์ชันไม่มีจริง) จะไม่สร้างอะไรเลย = พฤติกรรมเดิม
 * ============================================================ */
do $$
declare r record; v_asset uuid; v_open text;
begin
  if to_regprocedure('sri_os.fn_asset_cost_coa(text)') is null then
    raise notice 'ข้าม G4-fixture (2) · ยังไม่มี fn_asset_cost_coa (migration 20261027161500 ไม่ถูก apply)';
    return;
  end if;

  for r in execute $q$
    select t.code, t.cr_coa_code
      from sri_os.txn_types t
     where sri_os.fn_asset_cost_coa(t.dr_coa_code)
       and sri_os.fn_asset_cost_coa(t.cr_coa_code)
     order by t.code
  $q$ loop
    -- ยอดยกมาที่เดบิตบัญชีต้นทางของหมวดนั้น (หาจากตารางกฎ ไม่พิมพ์รหัสเอง)
    select o.code into v_open
      from sri_os.txn_types o
     where o.group_code = 'opening' and o.dr_coa_code = r.cr_coa_code
     order by o.code limit 1;
    if v_open is null then
      -- ไม่มีทางตั้งยอดต้นทาง → ปล่อยให้ G4 รายงานว่าหมวดนี้อนุมัติไม่ได้
      -- (นั่นคือความจริงที่ต้องเห็น ไม่ใช่สิ่งที่ fixture ควรกลบ)
      continue;
    end if;

    v_asset := gen_random_uuid();
    insert into sri_os.assets(id, code, name, class_id, category_id, owner_id)
    select v_asset, 'DG-MV-' || upper(right(r.code, 12)), 'ทรัพย์ของหมวดย้าย ' || r.code,
           k.class_id, k.id, o.id
      from (select class_id, id from sri_os.asset_categories order by code limit 1) k,
           sri_os.owners o
     where o.code = 'THANAKORN';
    insert into g_ref(label, id) values ('move:' || r.code, v_asset);

    set local role authenticated;
    perform pg_temp.post_as_appA(v_open, 1000, false, v_asset,
                                 'G4-fixture ยอดต้นทางของหมวดย้าย ' || r.code);
    reset role;

    raise notice 'ok G4-fixture (2) · % ได้ทรัพย์ของตัวเองที่มียอด 1,000 ในบัญชี % (ย้ายทั้งก้อนได้พอดี)',
      r.code, r.cr_coa_code;
  end loop;
exception when others then
  reset role; raise;
end $$;

-- ============================================================
-- G4 · **ร่างที่สร้างได้แต่อนุมัติไม่ได้ ต้องไม่มี**
--
-- ไล่ **ทุกหมวดที่ประตูยอม** → คีย์ร่าง → อนุมัติด้วยคู่บัญชี **จากตารางกฎ**
-- (ไม่ได้พิมพ์คู่บัญชีเองในเทสต์ · ถ้าตารางกฎเปลี่ยน เทสต์เดินตามเอง)
-- แล้วเทียบ "ชุดที่ตก" กับรายการที่ตั้งใจให้ตกพร้อมเหตุผล
-- ============================================================
create or replace function pg_temp.try_type(p_code text) returns text
language plpgsql as $fn$
declare
  t record; v_draft uuid; v_cash date; v_bank uuid; v_cf text; v_owner uuid; v_asset uuid;
begin
  select * into t from sri_os.txn_types where code = p_code;
  v_owner := pg_temp.own('THANAKORN');
  -- หมวดย้ายยอดมีทรัพย์ของตัวเอง (ยอดต้นทาง 1,000 พอดี · ดู G4-fixture (2))
  -- หมวดอื่นใช้ทรัพย์ร่วมของไฟล์นี้เหมือนเดิม
  v_asset := coalesce((select id from g_ref where label = 'move:' || p_code), pg_temp.ref('asset'));
  v_cf := t.cf_group::text;
  if t.cash_direction = 'none' then
    v_cash := null; v_bank := null;
  else
    v_cash := date '2026-03-01'; v_bank := pg_temp.ref('bank_thb');
  end if;

  perform pg_temp.login('clerk');
  v_draft := (sri_os.fn_create_draft(jsonb_build_object(
    'owner_id', v_owner,
    'txn_type_code', p_code,
    'doc_date', '2026-03-01',
    'cash_date', v_cash,
    'bank_account_id', v_bank,
    'amount', 1000,
    'asset_id', case when t.requires_asset then v_asset end,
    'contact_id', case when t.requires_contact then pg_temp.ref('contact') end,
    'memo', 'G4 ' || p_code,
    'attachments', jsonb_build_array('หลักฐาน.pdf'))) ->> 'draft_id')::uuid;

  perform pg_temp.login('appA');
  perform sri_os.fn_approve_draft(v_draft, jsonb_build_object(
    'txn_type_code', p_code,
    'doc_date', '2026-03-01',
    'cash_date', v_cash,
    'memo', 'G4 อนุมัติ ' || p_code,
    'asset_id', case when t.requires_asset then v_asset end,
    'contact_id', case when t.requires_contact then pg_temp.ref('contact') end,
    'attachments', jsonb_build_array('หลักฐาน.pdf'),
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', v_owner,
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code', t.dr_coa_code, 'debit', 1000, 'credit', 0,
                           'cf_category', v_cf,
                           'bank_account_id', case when t.dr_coa_code ~ '^11' then v_bank end,
                           'asset_id', case when t.requires_asset then v_asset end),
        jsonb_build_object('coa_code', t.cr_coa_code, 'debit', 0, 'credit', 1000,
                           'cf_category', v_cf,
                           'bank_account_id', case when t.cr_coa_code ~ '^11' then v_bank end,
                           'asset_id', case when t.requires_asset then v_asset end))))));
  return null;
exception when others then
  return left(sqlerrm, 150);
end $fn$;

do $$
declare
  r record; v_err text; n_ok int := 0; n_fail int := 0; v_list text := '';
  -- หมวดที่ **ตั้งใจให้ตกตอนอนุมัติ** พร้อมเหตุผล (ชุดนี้ต้องตรงเป๊ะ)
  -- เหตุผลร่วมกัน: ด่านของมันตรวจ **ยอดเทียบกับยอดคงเหลือ ณ เวลาอนุมัติ**
  -- ซึ่งประตูร่างสัญญาแทนไม่ได้ (ยอดคงเหลือขยับได้ระหว่างคีย์กับอนุมัติ)
  expected text[] := array[]::text[];
begin
  set local role authenticated;
  for r in select code from sri_os.fn_draft_allowed_types() loop
    v_err := pg_temp.try_type(r.code);
    if v_err is null then
      n_ok := n_ok + 1;
    else
      n_fail := n_fail + 1;
      v_list := v_list || E'\n    · ' || r.code || ' → ' || v_err;
    end if;
  end loop;
  reset role;

  if n_ok = 0 then
    raise exception 'FAIL: G4 — ไม่มีหมวดไหนอนุมัติผ่านเลย (% ตก) เทสต์นี้วัดอะไรไม่ได้ · %',
      n_fail, v_list;
  end if;
  if n_fail > 0 then
    raise exception 'FAIL: G4 — มี % หมวดที่ "คีย์ร่างได้แต่อนุมัติไม่ได้" (ผ่าน % หมวด) · ร่างพวกนี้จะค้างคิวตลอดไป ต้องกันที่ประตูร่างหรืออธิบายว่าทำไมต้องตกตอนอนุมัติ:%',
      n_fail, n_ok, v_list;
  end if;
  raise notice 'ok G4 · ทุกหมวดที่ประตูยอม (% หมวด) คีย์เป็นร่างแล้ว **อนุมัติผ่านได้จริงทั้งหมด** ด้วยคู่บัญชีจากตารางกฎ → ไม่มีร่างที่สร้างได้แต่อนุมัติไม่ได้',
    n_ok;
exception when others then
  reset role; raise;
end $$;

-- ============================================================
-- G5 · ชื่อคนคีย์ปลอมไม่ได้ · ร่างเกิดมาเป็น approved ไม่ได้
-- ============================================================
do $$
declare v_draft uuid;
begin
  set local role authenticated;
  perform pg_temp.login('clerk');

  -- (ก) INSERT ตรงโดยอ้างว่าคนอื่นคีย์ → ระบบตรึงเป็นชื่อผู้ล็อกอินจริง
  insert into sri_os.draft_entries(owner_id, txn_type_code, doc_date, amount, memo,
                                   attachments, created_by)
  values (pg_temp.own('THANAKORN'), 'exp.other', '2026-02-03', 900,
          'G5 อ้างว่าคนอื่นคีย์', array['ใบแจ้งหนี้.pdf'], pg_temp.uid('appA'))
  returning id into v_draft;
  if (select created_by from sri_os.draft_entries where id = v_draft) <> pg_temp.uid('clerk') then
    raise exception 'FAIL: G5a — ชื่อคนคีย์ต้องถูกตรึงเป็นผู้ล็อกอินจริง (clerk)';
  end if;

  -- (ข) ร่างที่เกิดมาพร้อมสถานะ approved = เลี่ยงด่าน C-1/C-2 ทั้งชุด
  perform pg_temp.must_fail_like('G5b ร่างเกิดมาเป็น approved', format($q$
    insert into sri_os.draft_entries(owner_id, txn_type_code, doc_date, amount, memo,
                                     attachments, status, posted_txn_id)
    values (%L, 'exp.other', '2026-02-03', 900, 'G5b', array['x.pdf'], 'approved', null) $q$,
    pg_temp.own('THANAKORN')),
    'ร่างใหม่ต้องมีสถานะ pending');

  -- (ค) ปากทางต้องไม่รับช่องที่ระบบเป็นคนตั้ง
  perform pg_temp.must_fail_like('G5c ปากทางรับ created_by', format($q$
    select sri_os.fn_create_draft(jsonb_build_object(
      'owner_id', %L, 'txn_type_code', 'exp.other', 'doc_date', '2026-02-03',
      'amount', 900, 'created_by', %L)) $q$, pg_temp.own('THANAKORN'), pg_temp.uid('appA')),
    'ช่องที่ยังไม่รู้จัก');

  reset role;
  raise notice 'ok G5 · ชื่อคนคีย์ถูกตรึงจากผู้ล็อกอินจริง · ร่างเกิดมาเป็น approved ไม่ได้ · ปากทางปฏิเสธช่อง created_by ทั้งใบ';
exception when others then
  reset role; raise;
end $$;

-- ============================================================
-- G6 · รูปร่างที่อนุมัติไม่ได้ ต้องถูกปฏิเสธ **ตอนคีย์** พร้อมเหตุผลเป็นภาษาคน
-- ============================================================
do $$
declare
  v_own  uuid := pg_temp.own('THANAKORN');
  v_corp uuid := pg_temp.own('SRI_CORP');
  n0 int;
begin
  set local role authenticated;
  perform pg_temp.login('clerk');
  n0 := pg_temp.n_pending();

  -- ยอดเงิน
  perform pg_temp.must_fail_like('G6a ยอด 0', format($q$
    select sri_os.fn_create_draft(jsonb_build_object('owner_id', %L,
      'txn_type_code', 'exp.other', 'doc_date', '2026-02-04', 'amount', 0)) $q$, v_own),
    'ต้องมากกว่า 0');
  perform pg_temp.must_fail_like('G6b ยอดติดลบ', format($q$
    select sri_os.fn_create_draft(jsonb_build_object('owner_id', %L,
      'txn_type_code', 'exp.other', 'doc_date', '2026-02-04', 'amount', -500)) $q$, v_own),
    'ต้องมากกว่า 0');

  -- วันเงินเคลื่อนแต่ไม่มีบัญชี (C-4) · บัญชีของผู้ถืออื่น · บัญชีสกุลต่างประเทศ
  perform pg_temp.must_fail_like('G6c มีวันเงินเคลื่อนแต่ไม่มีบัญชี', format($q$
    select sri_os.fn_create_draft(jsonb_build_object('owner_id', %L,
      'txn_type_code', 'exp.other', 'doc_date', '2026-02-04', 'cash_date', '2026-02-04',
      'amount', 500)) $q$, v_own),
    'ต้องระบุบัญชีธนาคาร');
  perform pg_temp.must_fail_like('G6d บัญชีของผู้ถืออื่น', format($q$
    select sri_os.fn_create_draft(jsonb_build_object('owner_id', %L,
      'txn_type_code', 'exp.other', 'doc_date', '2026-02-04', 'cash_date', '2026-02-04',
      'bank_account_id', %L, 'amount', 500)) $q$, v_own, pg_temp.ref('bank_corp')),
    'ไม่ใช่บัญชีของ');
  perform pg_temp.must_fail_like('G6e บัญชีเงินตราต่างประเทศ', format($q$
    select sri_os.fn_create_draft(jsonb_build_object('owner_id', %L,
      'txn_type_code', 'exp.other', 'doc_date', '2026-02-04', 'cash_date', '2026-02-04',
      'bank_account_id', %L, 'amount', 500)) $q$, v_own, pg_temp.ref('bank_usd')),
    'อัตราแลกเปลี่ยนของดีล');

  -- ระบุบัญชีทั้งที่เงินยังไม่เคลื่อน (ค้างจ่าย)
  perform pg_temp.must_fail_like('G6f ค้างจ่ายแต่ระบุบัญชี', format($q$
    select sri_os.fn_create_draft(jsonb_build_object('owner_id', %L,
      'txn_type_code', 'exp.other', 'doc_date', '2026-02-04',
      'bank_account_id', %L, 'amount', 500)) $q$, v_own, pg_temp.ref('bank_thb')),
    'ต้องไม่ระบุบัญชีธนาคาร');

  -- นิติบุคคลไม่แนบหลักฐาน (ด่านนี้ override ไม่ได้ และจะตีกลับตอนอนุมัติแน่ๆ)
  perform pg_temp.must_fail_like('G6g นิติบุคคลไม่แนบหลักฐาน', format($q$
    select sri_os.fn_create_draft(jsonb_build_object('owner_id', %L,
      'txn_type_code', 'exp.other', 'doc_date', '2026-02-04', 'amount', 500)) $q$, v_corp),
    'ต้องแนบไฟล์หลักฐาน');

  -- หมวดที่ตารางร่างเก็บข้อมูลไม่พอ → บอกตอนคีย์ ไม่ใช่ปล่อยค้างคิว
  perform pg_temp.must_fail_like('G6h หมวดโอน', format($q$
    select sri_os.fn_create_draft(jsonb_build_object('owner_id', %L,
      'txn_type_code', 'trf.internal', 'doc_date', '2026-02-04', 'amount', 500)) $q$, v_own),
    'คีย์เป็นร่างไม่ได้');
  perform pg_temp.must_fail_like('G6i หมวดยอดยกมา', format($q$
    select sri_os.fn_create_draft(jsonb_build_object('owner_id', %L,
      'txn_type_code', 'opn.cash', 'doc_date', '2026-02-04', 'amount', 500)) $q$, v_own),
    'ประตูยอดตั้งต้น');
  perform pg_temp.must_fail_like('G6j หมวดที่ต้องมีเงื่อนไขสัญญา', format($q$
    select sri_os.fn_create_draft(jsonb_build_object('owner_id', %L,
      'txn_type_code', 'inv.lend', 'doc_date', '2026-02-04', 'amount', 500)) $q$, v_own),
    'เงื่อนไขสัญญา');

  -- หมวดที่ต้องมีคู่ค้า/ทรัพย์ แต่ไม่ส่งมา
  perform pg_temp.must_fail_like('G6k หมวดที่ต้องมีทรัพย์', format($q$
    select sri_os.fn_create_draft(jsonb_build_object('owner_id', %L,
      'txn_type_code', 'inc.rent', 'doc_date', '2026-02-04', 'cash_date', '2026-02-04',
      'bank_account_id', %L, 'amount', 500, 'contact_id', %L)) $q$,
    v_own, pg_temp.ref('bank_thb'), pg_temp.ref('contact')),
    'ต้องระบุทรัพย์');

  -- หมวดที่ไม่แตะเงินสดเลย แต่ใส่วันเงินเคลื่อนมา
  -- ส่งทรัพย์กับคู่ค้ามาด้วย เพื่อให้เคสนี้ไปถึงด่าน "วันเงินเคลื่อน" จริงๆ
  -- (ครั้งแรกหมวดที่สุ่มได้ต้องมีคู่ค้า → ถูกปฏิเสธด้วยเหตุผลอื่น = วัดผิดด่าน)
  perform pg_temp.must_fail_like('G6l หมวดไม่แตะเงินสดแต่มีวันเงินเคลื่อน', format($q$
    select sri_os.fn_create_draft(jsonb_build_object('owner_id', %L,
      'txn_type_code', (select code from sri_os.txn_types where cash_direction = 'none'
                         and is_active and group_code <> 'opening' order by code limit 1),
      'doc_date', '2026-02-04', 'cash_date', '2026-02-04', 'amount', 500,
      'asset_id', %L, 'contact_id', %L, 'attachments', jsonb_build_array('x.pdf'))) $q$,
    v_own, pg_temp.ref('asset'), pg_temp.ref('contact')),
    'ไม่แตะเงินสด');

  -- คิวต้องไม่โตขึ้นเลยจากเคสที่ถูกปฏิเสธทั้งหมด
  if pg_temp.n_pending() <> n0 then
    raise exception 'FAIL: G6 — มีร่างที่ถูกปฏิเสธหลุดเข้าคิว (ก่อน % หลัง %)', n0, pg_temp.n_pending();
  end if;

  reset role;
  raise notice 'ok G6 · รูปร่างที่อนุมัติไม่ได้ 12 แบบถูกปฏิเสธตอนคีย์พร้อมเหตุผลเป็นภาษาคน · คิวอนุมัติไม่โตขึ้นเลย';
exception when others then
  reset role; raise;
end $$;

-- ============================================================
-- G7 · แก้ร่าง pending ให้กลายเป็นร่างที่อนุมัติไม่ได้ ก็ไม่ได้
--      (ประตูที่ครอบแต่ INSERT = ประตูที่เลี่ยงได้ด้วยคำสั่งที่สอง)
-- ============================================================
do $$
declare v_draft uuid;
begin
  set local role authenticated;
  perform pg_temp.login('clerk');
  v_draft := (sri_os.fn_create_draft(jsonb_build_object(
    'owner_id', pg_temp.own('THANAKORN'), 'txn_type_code', 'exp.other',
    'doc_date', '2026-02-05', 'cash_date', '2026-02-05',
    'bank_account_id', pg_temp.ref('bank_thb'), 'amount', 2200,
    'memo', 'G7 ร่างที่จะถูกแก้ให้เสีย',
    'attachments', jsonb_build_array('สลิป.pdf'))) ->> 'draft_id')::uuid;

  -- ผู้อนุมัติแก้ร่าง (policy draft_review ให้แก้ได้ทุกคอลัมน์)
  perform pg_temp.login('appA');
  perform pg_temp.must_fail_like('G7a ถอดบัญชีธนาคารออกแต่คงวันเงินเคลื่อน', format($q$
    update sri_os.draft_entries set bank_account_id = null where id = %L $q$, v_draft),
    'ต้องระบุบัญชีธนาคาร');
  perform pg_temp.must_fail_like('G7b แก้ยอดเป็น 0', format($q$
    update sri_os.draft_entries set amount = 0 where id = %L $q$, v_draft),
    'ต้องมากกว่า 0');
  perform pg_temp.must_fail_like('G7c ย้ายไปใช้บัญชีของผู้ถืออื่น', format($q$
    update sri_os.draft_entries set bank_account_id = %L where id = %L $q$,
    pg_temp.ref('bank_corp'), v_draft),
    'ไม่ใช่บัญชีของ');

  if (select bank_account_id from sri_os.draft_entries where id = v_draft)
     is distinct from pg_temp.ref('bank_thb') then
    raise exception 'FAIL: G7 — ร่างต้องยังสมบูรณ์เหมือนเดิมหลังทุกเคสที่ถูกปฏิเสธ';
  end if;

  reset role;
  raise notice 'ok G7 · แก้ร่าง pending ให้กลายเป็นร่างที่อนุมัติไม่ได้ ถูกปฏิเสธทั้งสามแบบ (ประตูครอบ UPDATE ด้วย ไม่ใช่แค่ INSERT)';
exception when others then
  reset role; raise;
end $$;

-- ============================================================
-- GM · **MUTATION** — ถอดประตูแล้ววัดรูเป็นตัวเลข
--
-- หมายเหตุที่ได้จากการวัดจริง: การ "อ้างว่าคนอื่นคีย์" ถูก **RLS** กันอยู่แล้ว
-- (`draft_insert` มี `created_by = auth.uid()`) → ไม่ใช่สิ่งที่ประตูนี้เพิ่ม
-- สิ่งที่ประตูนี้เพิ่มจริงคือสองข้อข้างล่าง (เขียนไว้เพื่อไม่ให้ใครเข้าใจผิดว่า
-- trigger นี้คือสิ่งที่กัน created_by ของผู้ใช้ที่ล็อกอิน)
-- ============================================================
do $$
declare v_draft uuid; v_txn uuid; v_stuck int; v_err text; v_fake int;
begin
  drop trigger trg_draft_entry_postable on sri_os.draft_entries;

  set local role authenticated;
  perform pg_temp.login('clerk');

  -- (ก) **ร่างที่อนุมัติไม่ได้เข้าคิวได้** — มีวันเงินเคลื่อนแต่ไม่มีบัญชีธนาคาร
  insert into sri_os.draft_entries(owner_id, txn_type_code, doc_date, cash_date, amount,
                                   memo, attachments, created_by)
  values (pg_temp.own('THANAKORN'), 'exp.other', '2026-02-06', '2026-02-06', 4300,
          'GM ร่างที่อนุมัติไม่ได้', array['สลิป.pdf'], auth.uid())
  returning id into v_draft;

  perform pg_temp.login('appA');
  begin
    perform sri_os.fn_approve_draft(v_draft, jsonb_build_object(
      'txn_type_code', 'exp.other', 'doc_date', '2026-02-06', 'cash_date', '2026-02-06',
      'memo', 'GM อนุมัติร่างที่ข้อมูลไม่พอ',
      'attachments', jsonb_build_array('สลิป.pdf'),
      'transactions', jsonb_build_array(jsonb_build_object(
        'owner_id', pg_temp.own('THANAKORN'),
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code', '5900', 'debit', 4300, 'credit', 0, 'cf_category', 'operating'),
          jsonb_build_object('coa_code', '1100', 'debit', 0, 'credit', 4300, 'cf_category', 'operating'))))));
    raise exception 'FAIL: GM — ใบที่บรรทัดเงินสดไม่มีบัญชีธนาคารไม่ควรลงสมุดได้';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    v_err := left(sqlerrm, 80);
  end;

  select count(*)::int into v_stuck from sri_os.draft_entries
   where status = 'pending' and memo like 'GM %';
  if v_stuck <> 1 then
    raise exception 'FAIL: GM(ก) — ควรมีร่างค้างคิว 1 ใบ แต่มี %', v_stuck;
  end if;

  /**
   * (ข) **ร่างเกิดมาพร้อมผลการอนุมัติ** → ข้ามด่าน C-1/C-2 ทั้งชุด
   * เพราะทั้งสองด่านเป็น trigger ของ **UPDATE** · ร่างที่ถูก INSERT มาเป็น
   * `approved` พร้อมชี้ใบในสมุดและใส่ชื่อผู้อนุมัติเป็นใครก็ได้
   * = ประวัติการอนุมัติที่ไม่เคยเกิดขึ้น (ไม่มีใครกดอนุมัติเลย)
   */
  v_txn := ((sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code', 'exp.other', 'doc_date', '2026-02-07',
      'memo', 'GM ใบที่จะถูกร่างปลอมอ้าง',
      'attachments', jsonb_build_array('ใบแจ้งหนี้.pdf'),
      'transactions', jsonb_build_array(jsonb_build_object(
        'owner_id', pg_temp.own('THANAKORN'),
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code', '5900', 'debit', 1100, 'credit', 0, 'cf_category', 'operating'),
          jsonb_build_object('coa_code', '2100', 'debit', 0, 'credit', 1100, 'cf_category', 'operating'))))))
    -> 'transaction_ids') ->> 0)::uuid;

  insert into sri_os.draft_entries(owner_id, txn_type_code, doc_date, amount, memo,
                                   attachments, created_by, status, posted_txn_id,
                                   reviewed_by, reviewed_at)
  values (pg_temp.own('THANAKORN'), 'exp.other', '2026-02-07', 1100,
          'GM ร่างที่เกิดมาเป็น approved', array['ใบแจ้งหนี้.pdf'], auth.uid(),
          'approved', v_txn, pg_temp.uid('clerk'), now());
  select count(*)::int into v_fake from sri_os.draft_entries
   where memo = 'GM ร่างที่เกิดมาเป็น approved' and status = 'approved';
  reset role;

  if v_fake <> 1 then
    raise exception 'FAIL: GM(ข) — ถอดประตูแล้วต้อง INSERT ร่างที่ approved มาแต่เกิดได้ (ถ้าไม่ได้ เคส G5 เขียวเพราะด่านอื่น)';
  end if;

  raise notice 'ok GM (MUTATION) · ไม่มีประตู: (ก) ร่าง 4,300 บาทที่ **อนุมัติไม่ได้** เข้าคิวได้และค้างตลอดไป (ผู้อนุมัติกดแล้วได้ "%") · (ข) ร่างถูก INSERT มาเป็น approved ชี้ใบในสมุด 1,100 บาทพร้อมชื่อผู้อนุมัติที่ไม่เคยกด → **ข้ามด่าน C-1/C-2 ทั้งชุด** เพราะสองด่านนั้นเป็น trigger ของ UPDATE',
    v_err;
exception when others then
  reset role; raise;
end $$;

rollback;

-- ============================================================
-- GMb · สภาพหลัง mutation ต้องกลับมาครบ
-- ============================================================
do $$
begin
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.draft_entries'::regclass
                    and g.tgname = 'trg_draft_entry_postable' and not g.tgisinternal) then
    raise exception 'FAIL: GMb — trigger ไม่กลับมาหลัง rollback';
  end if;
  raise notice 'ok GMb · ประตูกลับมาครบหลัง rollback';
end $$;

\echo 'zz_draft_gate_test: ผ่านทุกข้อ'
