-- ============================================================
-- SRI OS · เทสต์เต็ม RLS/trigger ของโมดูลบริหารสินทรัพย์ (งาน W5)
--
-- ขอบเขต: ทั้ง 22 เคสจาก docs/DESIGN_ASSET_PERMISSIONS.md §5
-- + การค้นหาช่องโหว่ข้ามสิทธิ์
--
-- รูปแบบ: transaction เดียว · rollback ปิดท้าย
-- ============================================================

begin;

-- fixtures: ผู้ใช้
create temporary table t_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_uid(label) values
  ('super'), ('mgmt'), ('mgr'), ('mgr2'), ('staff'), ('staff2'), ('inactive'), ('ghost');
insert into auth.users(id) select id from t_uid;

insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, u.label || '@test.local', u.label, x.role, x.active
  from t_uid u join (values
    ('super','super_admin',true), ('mgmt','management',true), ('mgr','manager',true),
    ('mgr2','manager',true), ('staff','staff',true), ('staff2','staff',true),
    ('inactive','manager',false)
  ) as x(label,role,active) on x.label = u.label;

create or replace function pg_temp.uid(p_label text) returns uuid
language sql stable as $fn$ select id from t_uid where label = p_label $fn$;

create or replace function pg_temp.login(p_label text) returns void
language sql as $fn$
  select set_config('test.uid', coalesce((select id::text from t_uid where label = p_label), ''), true);
$fn$;

create or replace function pg_temp.must_fail(p_label text, p_sql text) returns void
language plpgsql as $fn$
begin
  begin execute p_sql; exception when others then if sqlerrm like 'FAIL:%' then raise; end if; return; end;
  raise exception 'FAIL: % — ควรถูกปฏิเสญแต่สำเร็จ', p_label;
end $fn$;

create or replace function pg_temp.must_pass(p_label text, p_sql text) returns void
language plpgsql as $fn$
begin
  execute p_sql;
exception when others then
  raise exception 'FAIL: % — ควรสำเร็จแต่ล้ม (%)', p_label, sqlerrm;
end $fn$;

create or replace function pg_temp.must_rows(p_label text, p_sql text, p_expect int) returns void
language plpgsql as $fn$
declare n int;
begin
  execute p_sql;
  get diagnostics n = row_count;
  if n <> p_expect then raise exception 'FAIL: % — คาดว่า % แถว แต่ได้ %', p_label, p_expect, n; end if;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: % — ล้มด้วย %', p_label, sqlerrm;
end $fn$;

-- fixtures: ขอบเขต
insert into sri_os.user_owner_access(user_id, owner_id)
select pg_temp.uid(l), o.id from unnest(array['mgr','mgr2','staff','staff2','inactive']) l, sri_os.owners o
 where o.code in ('SRI_CORP');

-- fixtures: ทรัพย์
insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, manager_user_id)
select x.id, x.code, x.name, (select class_id from sri_os.asset_categories order by code limit 1),
       (select id from sri_os.asset_categories order by code limit 1),
       (select id from sri_os.owners where code = 'SRI_CORP'), x.mgr
  from (values
    ('00000000-0000-0000-0000-00000000a001'::uuid, 'A-0001', 'ของ mgr', pg_temp.uid('mgr')),
    ('00000000-0000-0000-0000-00000000a002'::uuid, 'A-0002', 'ของ mgr2', pg_temp.uid('mgr2')),
    ('00000000-0000-0000-0000-00000000a003'::uuid, 'A-0003', 'ไม่มีมอบ', null)
  ) as x(id, code, name, mgr);

insert into sri_os.asset_valuations(asset_id, as_of, method, value)
values ('00000000-0000-0000-0000-00000000a001', current_date, 'manual', 1000000);

-- ผูก transaction_lines กับ A-0001
insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, asset_id, attachments, created_by)
values ('00000000-0000-0000-0000-00000000e001', (select id from sri_os.owners where code = 'SRI_CORP'),
        'exp.other', current_date, '00000000-0000-0000-0000-00000000a001', array['t.pdf'], pg_temp.uid('mgmt'));
insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit, asset_id)
select '00000000-0000-0000-0000-00000000e001', c.id, case when c.rn = 1 then 500 else 0 end,
       case when c.rn = 2 then 500 else 0 end, '00000000-0000-0000-0000-00000000a001'
  from (select c2.id, v.rn from sri_os.chart_of_accounts c2 join (values ('5900', 1), ('2100', 2)) as v(code, rn) on v.code = c2.code) c;

do $$ declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin execute format('grant usage on schema %I to authenticated', s);
      execute format('grant select on %I.t_uid to authenticated', s); end $$;

set local role authenticated;

-- ============================================================
-- 1 · Management insert assets
-- ============================================================
do $$
declare v_own uuid; v_cat uuid; v_cls uuid;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;
  perform pg_temp.login('mgmt');
  perform pg_temp.must_pass('Management insert',
    format('insert into sri_os.assets(code, name, class_id, category_id, owner_id) values (%L, %L, %L, %L, %L)',
      'T-1', 'ใหม่', v_cls, v_cat, v_own));
  raise notice 'ok 1 · Management insert assets ได้';
end $$;

-- ============================================================
-- 2 · Staff ร่าง assets แต่อื่นล้ม
-- ============================================================
do $$
declare v_own uuid; v_cat uuid; v_cls uuid;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;
  perform pg_temp.login('staff');
  perform pg_temp.must_fail('Staff insert assets', format('insert into sri_os.assets(code, name, class_id, category_id, owner_id) values (''T'', ''x'', %L, %L, %L)', v_cls, v_cat, v_own));
  perform pg_temp.must_pass('Staff insert draft', format('insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id) values (''create'', %L, ''r'', %L, %L)', v_own, v_cls, v_cat));
  perform pg_temp.must_fail('Staff insert valuations', format('insert into sri_os.asset_valuations(asset_id, as_of, method, value) values (''00000000-0000-0000-0000-00000000a001'', %L, ''x'', 1)', current_date+1));
  perform pg_temp.must_fail('Staff insert bank', format('insert into sri_os.bank_accounts(owner_id, bank, account_name, display_name) values (%L, ''X'', ''x'', ''x'')', v_own));
  raise notice 'ok 2 · Staff ร่าง assets แต่อื่นล้ม';
end $$;

-- ============================================================
-- 3-4 · Manager แก้ได้เฉพาะของตน
-- ============================================================
do $$
begin
  perform pg_temp.login('mgr');
  perform pg_temp.must_rows('Manager แก้ของตน', 'update sri_os.assets set location = ''x'' where id = ''00000000-0000-0000-0000-00000000a001''', 1);
  perform pg_temp.must_rows('Manager แก้ของคนอื่น', 'update sri_os.assets set location = ''x'' where id = ''00000000-0000-0000-0000-00000000a002''', 0);
  perform pg_temp.must_rows('Manager แก้ null manager', 'update sri_os.assets set location = ''x'' where id = ''00000000-0000-0000-0000-00000000a003''', 0);
  raise notice 'ok 3-4 · Manager แก้ของตนเท่านั้น';
end $$;

-- ============================================================
-- 5 · Manager ตั้ง manager_user_id ไม่ได้
-- ============================================================
do $$
begin
  perform pg_temp.login('mgr');
  perform pg_temp.must_fail('Manager ตั้ง manager_user_id', format('update sri_os.assets set manager_user_id = %L where id = ''00000000-0000-0000-0000-00000000a001''', pg_temp.uid('mgr2')));
  raise notice 'ok 5 · Manager ตั้ง manager_user_id ไม่ได้';
end $$;

-- ============================================================
-- 6 · Staff ยัด forbidden fields ใน patch
-- ============================================================
do $$
declare v_own uuid; v_cat uuid; v_cls uuid; p text;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;
  perform pg_temp.login('staff');
  perform pg_temp.must_fail('Staff ยัด manager_user_id', format('insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id, patch) values (''create'', %L, ''x'', %L, %L, %L::jsonb)', v_own, v_cls, v_cat, jsonb_build_object('manager_user_id', pg_temp.uid('staff'))::text));
  foreach p in array array['owner_id', 'code', 'status', 'id', 'created_at'] loop
    perform pg_temp.must_fail('Staff ยัด ' || p, format('insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id, patch) values (''create'', %L, ''x'', %L, %L, %L::jsonb)', v_own, v_cls, v_cat, jsonb_build_object(p, 'v')::text));
  end loop;
  raise notice 'ok 6 · Staff ยัด forbidden fields ล้ม';
end $$;

-- ============================================================
-- 7-8 · Staff/Manager ตีราคา/bank ล้ม
-- ============================================================
do $$
declare v_own uuid; p text;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  foreach p in array array['staff', 'mgr'] loop
    perform pg_temp.login(p);
    perform pg_temp.must_fail(p || ' valuation', format('insert into sri_os.asset_valuations(asset_id, as_of, method, value) values (''00000000-0000-0000-0000-00000000a001'', %L, ''manual'', 5)', current_date+3));
    perform pg_temp.must_fail(p || ' bank', format('insert into sri_os.bank_accounts(owner_id, bank, account_name, display_name) values (%L, ''X'', ''x'', ''x'')', v_own));
  end loop;
  perform pg_temp.login('mgmt');
  perform pg_temp.must_pass('Management valuation', format('insert into sri_os.asset_valuations(asset_id, as_of, method, value) values (''00000000-0000-0000-0000-00000000a001'', %L, ''manual'', 5)', current_date+4));
  perform pg_temp.must_pass('Management bank', format('insert into sri_os.bank_accounts(owner_id, bank, account_name, display_name) values (%L, ''X'', ''x'', ''x'')', v_own));
  raise notice 'ok 7-8 · Staff/Manager ตีราคา/bank ล้ม · Management ได้';
end $$;

-- ============================================================
-- 9 · Staff insert contracts ล้ม
-- ============================================================
do $$
declare v_own uuid;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  perform pg_temp.login('staff');
  perform pg_temp.must_fail('Staff contracts', format('insert into sri_os.contracts(owner_id, asset_id, type) values (%L, ''00000000-0000-0000-0000-00000000a001'', ''lease'')', v_own));
  raise notice 'ok 9 · Staff insert contracts ล้ม';
end $$;

-- ============================================================
-- 10 · DELETE ทั้ง 5 ตาราง
-- ============================================================
do $$
declare r text;
begin
  reset role;
  if exists (select 1 from pg_policies where schemaname = 'sri_os' and tablename in ('assets', 'asset_valuations', 'contracts', 'schedules', 'bank_accounts', 'asset_drafts') and cmd in ('DELETE', 'ALL')) then raise exception 'FAIL: มี DELETE'; end if;
  set local role authenticated;
  foreach r in array array['staff', 'mgr', 'mgmt', 'super'] loop
    perform pg_temp.login(r);
    perform pg_temp.must_rows(r || ' delete', 'delete from sri_os.assets where id = ''00000000-0000-0000-0000-00000000a003''', 0);
  end loop;
  raise notice 'ok 10 · ไม่มี DELETE policy';
end $$;

-- ============================================================
-- 11 · inactive/ghost
-- ============================================================
do $$
declare r text; v_own uuid; v_cat uuid; v_cls uuid;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;
  foreach r in array array['inactive', 'ghost'] loop
    perform pg_temp.login(r);
    perform pg_temp.must_fail(r || ' draft', format('insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id) values (''create'', %L, ''x'', %L, %L)', v_own, v_cls, v_cat));
  end loop;
  raise notice 'ok 11 · inactive/ghost ทำไม่ได้';
end $$;

-- ============================================================
-- 12-13 · ร่าง → assets ไม่เปลี่ยน · FK ปฏิเสญ
-- ============================================================
do $$
declare v_own uuid; v_cat uuid; v_cls uuid; v_draft uuid; n_before bigint; n_after bigint;
begin
  reset role;
  select count(*) into n_before from sri_os.assets;
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;
  set local role authenticated;
  perform pg_temp.login('staff');
  insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id) values ('create', v_own, 'test', v_cls, v_cat) returning id into v_draft;
  reset role;
  select count(*) into n_after from sri_os.assets;
  if n_before <> n_after then raise exception 'FAIL: assets ขยับ'; end if;
  begin insert into sri_os.asset_valuations(asset_id, as_of, method, value) values (v_draft, current_date, 'manual', 1); raise exception 'FAIL: FK'; exception when foreign_key_violation then null; end;
  raise notice 'ok 12-13 · ร่างไม่นับใน assets · FK ปฏิเสญร่าง';
end $$;

-- ============================================================
-- 14 · ร่าง required fields
-- ============================================================
do $$
declare v_own uuid; v_cat uuid; v_cls uuid;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;
  perform pg_temp.login('staff');
  perform pg_temp.must_fail('no class', format('insert into sri_os.asset_drafts(kind, owner_id, name, category_id) values (''create'', %L, ''x'', %L)', v_own, v_cat));
  perform pg_temp.must_fail('no cat', format('insert into sri_os.asset_drafts(kind, owner_id, name, class_id) values (''create'', %L, ''x'', %L)', v_own, v_cls));
  perform pg_temp.must_fail('no name', format('insert into sri_os.asset_drafts(kind, owner_id, class_id, category_id) values (''create'', %L, %L, %L)', v_own, v_cls, v_cat));
  perform pg_temp.must_fail('no target', format('insert into sri_os.asset_drafts(kind, owner_id, patch) values (''update'', %L, %L::jsonb)', v_own, '{"x":"y"}'::jsonb));
  perform pg_temp.must_fail('empty patch', format('insert into sri_os.asset_drafts(kind, owner_id, target_asset_id, patch) values (''update'', %L, ''00000000-0000-0000-0000-00000000a001'', ''{}''::jsonb)', v_own));
  raise notice 'ok 14 · ร่าง required ล้ม';
end $$;

-- ============================================================
-- 15 · อนุมัติ: assets +1 · ledger +0
-- ============================================================
do $$
declare v_own uuid; v_cat uuid; v_cls uuid; v_draft uuid; n_assets_0 bigint; n_txn_0 bigint; n_lines_0 bigint;
        n_assets_1 bigint; n_txn_1 bigint; n_lines_1 bigint;
begin
  reset role;
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;
  select count(*) into n_assets_0 from sri_os.assets;
  select count(*) into n_txn_0 from sri_os.transactions;
  select count(*) into n_lines_0 from sri_os.transaction_lines;
  set local role authenticated;
  perform pg_temp.login('mgmt');
  insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id) values ('create', v_own, 'for', v_cls, v_cat) returning id into v_draft;
  perform sri_os.fn_apply_asset_draft(v_draft);
  reset role;
  select count(*) into n_assets_1 from sri_os.assets;
  select count(*) into n_txn_1 from sri_os.transactions;
  select count(*) into n_lines_1 from sri_os.transaction_lines;
  if n_assets_1 <> n_assets_0 + 1 or n_txn_1 <> n_txn_0 or n_lines_1 <> n_lines_0 then raise exception 'FAIL: counts'; end if;
  raise notice 'ok 15 · อนุมัติ: assets +1 · ledger +0';
end $$;

-- ============================================================
-- 16 · Trigger ไม่เรียก fn_can · ไม่เขียน ledger
-- ============================================================
reset role;
do $$
declare v text;
begin
  select string_agg(distinct p.proname, ', ') into v from pg_trigger tg join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace join pg_proc p on p.oid = tg.tgfoid
   where ns.nspname = 'sri_os' and not tg.tgisinternal and p.prosrc ~* 'fn_can';
  if v is not null then raise exception 'FAIL: fn_can: %', v; end if;
  select string_agg(p.proname, ', ') into v from pg_trigger tg join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace join pg_proc p on p.oid = tg.tgfoid
   where ns.nspname = 'sri_os' and not tg.tgisinternal and c.relname in ('assets', 'asset_drafts')
     and p.prosrc ~* '(insert|update|delete)\s+(into\s+)?(sri_os\.)?(transactions|transaction_lines|draft_entries)\M';
  if v is not null then raise exception 'FAIL: ledger: %', v; end if;
  raise notice 'ok 16 · trigger ไม่เรียก fn_can/ledger';
end $$;

-- ============================================================
-- 17 · ร่าง patch ว่าง
-- ============================================================
set local role authenticated;
do $$
declare v_own uuid; v_cat uuid; v_cls uuid;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;
  perform pg_temp.login('staff');
  perform pg_temp.must_pass('patch {}', format('insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id, patch) values (''create'', %L, ''m'', %L, %L, ''{}''::jsonb)', v_own, v_cls, v_cat));
  raise notice 'ok 17 · ร่าง 4 ช่อง + patch ว่าง ได้';
end $$;

-- ============================================================
-- 18 · ร่างอนุมัติแล้ว: RLS + trigger ล้ม
-- ============================================================
do $$
declare v_own uuid; v_cat uuid; v_cls uuid; v_draft uuid;
begin
  reset role;
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;
  set local role authenticated;
  perform pg_temp.login('mgmt');
  insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id) values ('create', v_own, 'ed', v_cls, v_cat) returning id into v_draft;
  perform sri_os.fn_apply_asset_draft(v_draft);
  perform pg_temp.must_rows('RLS', format('update sri_os.asset_drafts set note = ''e'' where id = %L', v_draft), 0);
  reset role;
  perform pg_temp.must_fail('trigger', format('update sri_os.asset_drafts set note = ''e'' where id = %L', v_draft));
  raise notice 'ok 18 · ร่างอนุมัติแล้ว: RLS + trigger ล้ม';
end $$;

-- ============================================================
-- 19 · อนุมัติซ้ำ
-- ============================================================
set local role authenticated;
do $$
declare v_own uuid; v_cat uuid; v_cls uuid; v_draft uuid; n_before bigint; n_after bigint;
begin
  reset role;
  select count(*) into n_before from sri_os.assets;
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;
  set local role authenticated;
  perform pg_temp.login('mgmt');
  insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id) values ('create', v_own, 're', v_cls, v_cat) returning id into v_draft;
  perform sri_os.fn_apply_asset_draft(v_draft);
  select count(*) into n_after from sri_os.assets;
  perform pg_temp.must_fail('2x', format('select sri_os.fn_apply_asset_draft(%L)', v_draft));
  reset role;
  if (select count(*) from sri_os.assets) <> n_after then raise exception 'FAIL: 2x'; end if;
  raise notice 'ok 19 · อนุมัติซ้ำล้ม';
end $$;

-- ============================================================
-- 20 · owner_id ล็อก
-- ============================================================
set local role authenticated;
do $$
declare v_other uuid; v_free uuid;
begin
  reset role;
  select id into v_other from sri_os.owners where code <> 'SRI_CORP' limit 1;
  select id from sri_os.assets where (select count(*) from sri_os.transaction_lines tl where tl.asset_id = assets.id) = 0 into v_free limit 1;
  set local role authenticated;
  perform pg_temp.login('super');
  perform pg_temp.must_fail('with lines', format('update sri_os.assets set owner_id = %L where id = ''00000000-0000-0000-0000-00000000a001''', v_other));
  if v_free is not null then
    perform pg_temp.must_rows('no lines', format('update sri_os.assets set owner_id = %L where id = %L', v_other, v_free), 1);
  end if;
  raise notice 'ok 20 · owner_id ล็อกเมื่อมี lines';
end $$;

-- ============================================================
-- 21 · Manager ไม่ได้ข้ามกฎ
-- ============================================================
do $$
begin
  perform pg_temp.login('mgr');
  perform pg_temp.must_fail('clear mgr_user_id', 'update sri_os.assets set manager_user_id = null where id = ''00000000-0000-0000-0000-00000000a001''');
  perform pg_temp.must_fail('move owner', format('update sri_os.assets set owner_id = (select id from sri_os.owners where code <> ''SRI_CORP'' limit 1) where id = ''00000000-0000-0000-0000-00000000a001'''));
  raise notice 'ok 21 · Manager ไม่ได้ข้ามกฎผ่าน mgr/owner fields';
end $$;

-- ============================================================
-- 22 · Manager ไม่สามารถอนุมัติร่างของ Staff ที่สร้างทรัพย์นอกขอบเขต
-- ============================================================
do $$
declare v_own uuid; v_cat uuid; v_cls uuid; v_draft uuid; v_asset uuid;
begin
  reset role;
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;
  
  set local role authenticated;
  perform pg_temp.login('staff');
  -- Staff สร้างร่าง
  insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id) 
  values ('create', v_own, 'draft ของ staff', v_cls, v_cat) returning id into v_draft;
  
  -- Manager พยายามอนุมัติจะล้ม (Manager ไม่มี portfolio.view_all)
  perform pg_temp.login('mgr');
  begin
    v_asset := sri_os.fn_apply_asset_draft(v_draft);
    if v_asset is not null then raise exception 'FAIL: Manager อนุมัติร่าง create ได้'; end if;
  exception when others then
    if sqlerrm not like '%portfolio.view_all%' then
      raise exception 'FAIL: error ไม่ชัดเจน: %', sqlerrm;
    end if;
  end;
  
  raise notice 'ok 22 · Manager ไม่สามารถอนุมัติร่าง create นอกเขตสิทธิ์ (ต้อง portfolio.view_all)';
end $$;

do $$ begin raise notice '=== asset permissions: 22 cases passed ==='; end $$;

rollback;
