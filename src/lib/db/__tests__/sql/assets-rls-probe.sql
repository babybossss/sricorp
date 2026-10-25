-- ============================================================
-- SRI OS · พิสูจน์กับ Postgres จริง (ในเครื่อง) ว่าสิ่งที่หน้าทรัพย์พึ่งพา "DB ตัดสินสิทธิ์" เป็นจริง
-- ไม่อยู่ใน supabase/tests (นอกขอบเขตงานนี้) · รัน: PROBE=<ไฟล์นี้> bash <harness> (สร้าง DB เปล่า → migration ทั้งชุด → ไฟล์นี้ → ลบ DB)
-- เจอข้อผิด = raise exception 'FAIL: ...' · ทั้งไฟล์ rollback ปิดท้าย
-- ============================================================
begin;

create temporary table t_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_uid(label) values ('mgmt'), ('mgr'), ('mgr2'), ('staff');
insert into auth.users(id) select id from t_uid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, u.label || '@probe.local', u.label, x.role, true
  from t_uid u join (values ('mgmt','management'), ('mgr','manager'), ('mgr2','manager'), ('staff','staff')) x(label, role) on x.label = u.label;
create or replace function pg_temp.uid(p text) returns uuid language sql stable as $f$ select id from t_uid where label = p $f$;
create or replace function pg_temp.login(p text) returns void language sql as $f$
  select set_config('test.uid', coalesce((select id::text from t_uid where label = p), ''), true) $f$;
create or replace function pg_temp.eq(p_label text, p_got anyelement, p_want anyelement) returns void language plpgsql as $f$
begin
  if p_got is distinct from p_want then raise exception 'FAIL: % — ได้ % คาด %', p_label, p_got, p_want; end if;
end $f$;

insert into sri_os.user_owner_access(user_id, owner_id)
select pg_temp.uid(l), o.id from unnest(array['mgr','mgr2','staff']) l, sri_os.owners o where o.code = 'SRI_CORP';

-- ทรัพย์สามชิ้น (ห้อง A1 ของ mgr · A2 ของ mgr2 · A3 ยังไม่มอบหมาย) + ข้อมูลทะเบียนที่ column exposure ปิดไว้
insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, manager_user_id, location, tags, ownership_pct, funding_source)
select x.id, x.code, x.name, k.class_id, k.id, (select id from sri_os.owners where code = 'SRI_CORP'), x.mgr, 'ตึกเดียวกัน', array['ทดสอบ'], 0.5, 'เงินสด'
  from (select class_id, id from sri_os.asset_categories order by code limit 1) k,
       (values ('00000000-0000-0000-0000-00000000a001'::uuid, 'PRB-1', 'ห้อง A1', pg_temp.uid('mgr')),
               ('00000000-0000-0000-0000-00000000a002'::uuid, 'PRB-2', 'ห้อง A2', pg_temp.uid('mgr2')),
               ('00000000-0000-0000-0000-00000000a003'::uuid, 'PRB-3', 'ห้อง A3', null)) x(id, code, name, mgr);

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
select '00000000-0000-0000-0000-00000000b001', id, 'KBANK', 'probe', 'probe' from sri_os.owners where code = 'SRI_CORP';

-- ลงสมุดด้วยรูปเดียวกับที่ engine สร้าง: 1500 ผูกทรัพย์ที่บรรทัด · 1510 ผูกทรัพย์ · รายได้/ค่าซ่อม **ไม่มี asset_id ที่บรรทัด** ผูกที่หัวรายการ
insert into sri_os.contacts(id, first_name, types) values ('00000000-0000-0000-0000-00000000c001', 'ผู้เช่าทดสอบ', array['tenant']);
create or replace function pg_temp.txn(p_id text, p_type text, p_asset uuid, p_dr text, p_cr text, p_amt numeric, p_asset_on_dr boolean) returns void language plpgsql as $f$
declare t uuid := ('00000000-0000-0000-0000-00000' || p_id)::uuid;
begin
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, cash_date, asset_id, contact_id, attachments, created_by)
  values (t, (select id from sri_os.owners where code = 'SRI_CORP'), p_type, date '2026-09-01',
          case when p_cr = '1100' or p_dr = '1100' then date '2026-09-01' end, p_asset, '00000000-0000-0000-0000-00000000c001', array['probe.pdf'], pg_temp.uid('mgmt'));
  insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit, asset_id, bank_account_id)
  values (t, (select id from sri_os.chart_of_accounts where code = p_dr), p_amt, 0,
          case when p_asset_on_dr then p_asset end, case when p_dr = '1100' then '00000000-0000-0000-0000-00000000b001'::uuid end),
         (t, (select id from sri_os.chart_of_accounts where code = p_cr), 0, p_amt,
          case when not p_asset_on_dr and p_cr ~ '^1[2-9]' then p_asset end, case when p_cr = '1100' then '00000000-0000-0000-0000-00000000b001'::uuid end);
end $f$;
select pg_temp.txn('0000001', 'inv.buy_re', '00000000-0000-0000-0000-00000000a001', '1500', '1100', 3000000, true);
select pg_temp.txn('0000002', 'inv.capex',  '00000000-0000-0000-0000-00000000a001', '1510', '1100', 200000, true);
select pg_temp.txn('0000003', 'exp.repair', '00000000-0000-0000-0000-00000000a001', '5120', '1100', 15000, false);
select pg_temp.txn('0000004', 'inc.rent',   '00000000-0000-0000-0000-00000000a001', '1100', '4200', 12000, false);
select pg_temp.txn('0000005', 'inv.buy_re', '00000000-0000-0000-0000-00000000a002', '1500', '1100', 5000000, true);

do $$
declare r record;
begin
  perform set_config('test.uid', '', true);
end $$;

do $$ declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin execute format('grant usage on schema %I to authenticated', s); execute format('grant select on %I.t_uid to authenticated', s); end $$;

set local role authenticated;

-- ---------- P1 · ทรัพย์ที่เห็น (fn_assets_visible) ----------
select pg_temp.login('mgmt');
select pg_temp.eq('mgmt เห็น 3 ทรัพย์', (select count(*) from sri_os.fn_assets_visible() where code like 'PRB-%'), 3::bigint);
select pg_temp.eq('mgmt เห็นช่องปิด', (select location from sri_os.fn_assets_visible() where code = 'PRB-1'), 'ตึกเดียวกัน');
select pg_temp.eq('mgmt เห็นสัดส่วนถือครอง', (select ownership_pct from sri_os.fn_assets_visible() where code = 'PRB-1'), 0.5::numeric);

select pg_temp.login('mgr');
select pg_temp.eq('mgr เห็นเฉพาะที่ตนบริหาร', (select string_agg(code, ',') from sri_os.fn_assets_visible() where code like 'PRB-%'), 'PRB-1');
select pg_temp.eq('mgr เห็นที่ตั้ง (asset.view_assigned)', (select location from sri_os.fn_assets_visible() where code = 'PRB-1'), 'ตึกเดียวกัน');
select pg_temp.eq('mgr ไม่เห็นสัดส่วนถือครอง (portfolio.view_all) = null ไม่ใช่ error', (select ownership_pct from sri_os.fn_assets_visible() where code = 'PRB-1'), null::numeric);

select pg_temp.login('staff');
select pg_temp.eq('staff เห็นชื่อทรัพย์ไว้คีย์รายการ', (select count(*) from sri_os.fn_assets_visible() where code like 'PRB-%'), 3::bigint);
select pg_temp.eq('staff ที่ตั้ง = null', (select count(*) from sri_os.fn_assets_visible() where code like 'PRB-%' and location is not null), 0::bigint);
select pg_temp.eq('staff tags = null', (select count(*) from sri_os.fn_assets_visible() where code like 'PRB-%' and tags is not null), 0::bigint);

-- ---------- P2 · สมุด (v_ledger_posted ด้วยคอลัมน์และเงื่อนไขเดียวกับที่หน้าทรัพย์ใช้) ----------
create or replace function pg_temp.app_lines() returns bigint language sql as $f$
  select count(*) from (
    select line_id, transaction_id, owner_id, txn_type_code, doc_date, source, coa_id, debit, credit, line_asset_id, txn_asset_id
      from sri_os.v_ledger_posted where line_asset_id is not null or txn_asset_id is not null) q $f$;
select pg_temp.login('mgmt');
select pg_temp.eq('mgmt อ่านบรรทัดทั้งหมด (10 บรรทัด)', pg_temp.app_lines(), 10::bigint);
select pg_temp.login('mgr');
select pg_temp.eq('mgr อ่านเฉพาะบรรทัดของ A1 (8 บรรทัด)', pg_temp.app_lines(), 8::bigint);
select pg_temp.eq('mgr ไม่เห็นบรรทัดของ A2 เลย', (select count(*) from sri_os.v_ledger_posted where txn_asset_id = '00000000-0000-0000-0000-00000000a002'), 0::bigint);
select pg_temp.login('staff');
select pg_temp.eq('staff อ่านสมุดไม่ได้เลย = 0 แถว', pg_temp.app_lines(), 0::bigint);

-- ---------- P3 · ต้นทุนจาก DB (fn_asset_cost_basis) ----------
select pg_temp.login('mgmt');
select pg_temp.eq('A1 ต้นทุนรวม = 1500 + 1510', sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000000a001'), 3200000::numeric);
select pg_temp.eq('A2 ต้นทุนรวม (แยกจาก A1 ไม่ปน)', sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000000a002'), 5000000::numeric);
select pg_temp.eq('ค่าปรับปรุง = ผลบวกบรรทัด 1510 ของ A1', (select sum(v.debit - v.credit) from sri_os.v_ledger_posted v join sri_os.chart_of_accounts c on c.id = v.coa_id where v.line_asset_id = '00000000-0000-0000-0000-00000000a001' and c.code = '1510'), 200000::numeric);
select pg_temp.eq('ค่าซ่อม (ผูกที่หัวรายการ) = 15,000', (select sum(v.debit - v.credit) from sri_os.v_ledger_posted v join sri_os.chart_of_accounts c on c.id = v.coa_id where v.txn_asset_id = '00000000-0000-0000-0000-00000000a001' and c.code = '5120'), 15000::numeric);
select pg_temp.eq('บรรทัดรายได้ไม่มี asset_id ที่บรรทัด (ต้องผูกที่หัว)', (select count(*) from sri_os.v_ledger_posted v join sri_os.chart_of_accounts c on c.id = v.coa_id where c.code = '4200' and v.line_asset_id is not null), 0::bigint);
select pg_temp.login('mgr');
select pg_temp.eq('mgr ถามต้นทุน A2 ได้ 0 (RLS) — เหตุที่หน้าจอต้องไม่แสดง 0 แทน "ไม่มีสิทธิ์"', sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000000a002'), 0::numeric);
select pg_temp.login('staff');
select pg_temp.eq('staff ถามต้นทุน A1 ได้ 0', sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000000a001'), 0::numeric);

-- ---------- P4 · ร่าง + อนุมัติ ----------
select pg_temp.login('staff');
insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id, patch, created_by)
select 'create', o.id, 'ห้องใหม่ 301', k.class_id, k.id, '{"location":"พหลโยธิน","tags":["a","b"],"ownership_pct":0.5}'::jsonb, pg_temp.uid('staff')
  from sri_os.owners o, (select class_id, id from sri_os.asset_categories order by code limit 1) k where o.code = 'SRI_CORP';
select pg_temp.eq('staff เห็นร่างของตัวเอง', (select count(*) from sri_os.asset_drafts), 1::bigint);
do $$ begin
  begin
    insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id, patch, created_by)
    select 'create', o.id, 'แอบสร้างในนามคนอื่น', k.class_id, k.id, '{}'::jsonb, pg_temp.uid('mgmt')
      from sri_os.owners o, (select class_id, id from sri_os.asset_categories order by code limit 1) k where o.code = 'SRI_CORP';
    raise exception 'FAIL: staff สร้างร่างในนามคนอื่นได้';
  exception when insufficient_privilege or others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
end $$;
select pg_temp.login('mgr');
select pg_temp.eq('mgr (asset.manage) เห็นร่างสร้างใหม่ในขอบเขตผู้ถือ', (select count(*) from sri_os.asset_drafts), 1::bigint);
do $$ begin
  begin
    perform sri_os.fn_apply_asset_draft((select id from sri_os.asset_drafts limit 1));
    raise exception 'FAIL: manager อนุมัติร่างสร้างทรัพย์ได้ (ต้องมี portfolio.view_all)';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
end $$;
select pg_temp.eq('ร่างยัง pending หลัง manager อนุมัติล้ม', (select status::text from sri_os.asset_drafts limit 1), 'pending');
select pg_temp.login('mgmt');
select pg_temp.eq('อนุมัติโดย management ได้ทรัพย์ 1 ชิ้นใหม่', (select count(*) from (select sri_os.fn_apply_asset_draft((select id from sri_os.asset_drafts limit 1))) q), 1::bigint);
select pg_temp.eq('ทรัพย์ใหม่มี patch ครบ (ป้ายกำกับเป็น array)', (select tags::text from sri_os.fn_assets_visible() where name = 'ห้องใหม่ 301'), '{a,b}');
select pg_temp.eq('ทรัพย์ใหม่ออกรหัสให้', (select code like '%-%' from sri_os.fn_assets_visible() where name = 'ห้องใหม่ 301'), true);
select pg_temp.eq('ร่างเป็น approved และมี applied_asset_id', (select (status::text = 'approved' and applied_asset_id is not null) from sri_os.asset_drafts limit 1), true);

-- ---------- P5 · แก้ตรง / ตีราคา ----------
create or replace function pg_temp.rows_hit(p_sql text) returns bigint language plpgsql as $f$
declare n bigint; begin execute p_sql; get diagnostics n = row_count; return n; end $f$;
select pg_temp.login('mgr');
select pg_temp.eq('mgr แก้ A1 ได้ 1 แถว', pg_temp.rows_hit($q$update sri_os.assets set location = 'ใหม่' where id = '00000000-0000-0000-0000-00000000a001'$q$), 1::bigint);
select pg_temp.eq('mgr แก้ A2 ได้ 0 แถว (RLS เงียบ)', pg_temp.rows_hit($q$update sri_os.assets set location = 'แอบแก้' where id = '00000000-0000-0000-0000-00000000a002'$q$), 0::bigint);
do $$ begin
  begin
    insert into sri_os.asset_valuations(asset_id, as_of, method, value) values ('00000000-0000-0000-0000-00000000a001', date '2026-09-30', 'manual', 3900000);
    raise exception 'FAIL: manager ตีราคาได้ (ต้องมี asset.value)';
  exception when others then if sqlerrm like 'FAIL:%' then raise; end if; end;
end $$;
select pg_temp.login('staff');
select pg_temp.eq('staff แก้ทะเบียนตรงได้ 0 แถว', pg_temp.rows_hit($q$update sri_os.assets set location = 'แก้เอง' where id = '00000000-0000-0000-0000-00000000a001'$q$), 0::bigint);
select pg_temp.login('mgmt');
insert into sri_os.asset_valuations(asset_id, as_of, method, value, note, created_by)
values ('00000000-0000-0000-0000-00000000a001', date '2026-09-30', 'manual', 3900000, 'probe', pg_temp.uid('mgmt'));
select pg_temp.eq('มูลค่าล่าสุดของ A1', (select value from sri_os.v_asset_latest_value where asset_id = '00000000-0000-0000-0000-00000000a001'), 3900000::numeric);
select pg_temp.eq('ตีราคาไม่เปลี่ยนต้นทุนตามสมุด', sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000000a001'), 3200000::numeric);
select pg_temp.eq('ทรัพย์ที่ยังไม่เคยตีราคา value = null (ไม่ใช่ 0)', (select value from sri_os.v_asset_latest_value where asset_id = '00000000-0000-0000-0000-00000000a002'), null::numeric);
select pg_temp.login('mgr');
select pg_temp.eq('mgr เห็นมูลค่าของ A1 แต่ไม่เห็น A2', (select count(*) from sri_os.v_asset_latest_value where value is not null), 1::bigint);

reset role;
rollback;
\echo 'assets-rls-probe: ผ่านทุกข้อ'
