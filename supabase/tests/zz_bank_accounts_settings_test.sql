-- ============================================================
-- SRI OS · ตรวจหน้าตั้งค่าบัญชีธนาคารกับ Postgres จริง (RLS · สกุลเงิน · ปิดใช้งาน)
--
-- รันอัตโนมัติโดย `scripts/test-rls-local.sh` (มันเก็บทุกไฟล์ `supabase/tests/*_test.sql`)
-- เขียนขึ้นเป็น probe ตอนทำหน้าจอ แล้วย้ายเข้ามาเพื่อให้รันทุกรอบ ไม่ใช่แค่ตอนที่คนนึกขึ้นได้
--
-- พิสูจน์ (ทุกข้อ "ถอดการแก้ออกแล้วต้องแดง" ดูผลวัดท้ายไฟล์):
--   B1 ผู้ใช้ไม่มี settings.manage → INSERT ถูก RLS ปฏิเสธ (42501) ไม่ใช่แค่ปุ่มเทา
--   B2 ผู้ใช้ไม่มี settings.manage → UPDATE ไม่โดนแถว (is_active ไม่เปลี่ยน)
--   B3 มี settings.manage → สร้างบัญชี USD แล้ว currency = USD จริง · สกุลนอกรายการถูก check constraint ปฏิเสธ
--      · ไม่ส่งสกุล = THB (ของเดิมไม่พัง)
--   B4 บัญชีที่มีรายการ: ปิดใช้งานแล้วรายการเดิมยังอ่านได้ครบ · ลงรายการใหม่ไม่ได้ (D-092) · เปิดกลับแล้วลงได้
--   B5 DELETE บัญชีที่มีรายการถูกปฏิเสธ (หน้าจอไม่เคยลบ แต่ DB ต้องกันซ้ำ)
--   B6 สังเกต (ไม่ใช่ assert): ช่องว่างที่ DB ยังไม่กัน — เปลี่ยนสกุลหลังมีรายการ · ชื่อซ้ำ
--
-- ทั้งไฟล์ rollback ปิดท้าย
-- ============================================================
\set ON_ERROR_STOP 1
begin;

-- ---------- fixtures ----------
insert into auth.users(id) values
  ('00000000-0000-0000-0000-0000000b0001'), ('00000000-0000-0000-0000-0000000b0002'), ('00000000-0000-0000-0000-0000000b0003');
insert into sri_os.app_users(id, email, display_name, role, is_active) values
  ('00000000-0000-0000-0000-0000000b0001', 'mgmt@bank.local',  'mgmt',  'management', true),
  ('00000000-0000-0000-0000-0000000b0002', 'staff@bank.local', 'staff', 'staff',      true),
  ('00000000-0000-0000-0000-0000000b0003', 'mgr@bank.local',   'mgr',   'manager',    true);
-- ทุกคนเห็นผู้ถือทุกคน → ต่างกันที่ settings.manage ตัวเดียว (ไม่ให้ผ่านเพราะ "มองไม่เห็นแถว")
insert into sri_os.user_owner_access(user_id, owner_id)
select u.id, o.id from auth.users u cross join sri_os.owners o
 where u.id in ('00000000-0000-0000-0000-0000000b0001','00000000-0000-0000-0000-0000000b0002','00000000-0000-0000-0000-0000000b0003');

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name) values
  ('00000000-0000-0000-0000-0000000b1001', (select id from sri_os.owners where code='THANAKORN'), 'BBL', 'ธนากร', 'ธนากร - BBL 888');
insert into sri_os.contacts(id, first_name, types) values ('00000000-0000-0000-0000-0000000b2001', 'ผู้เช่า', array['tenant']);
insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, currency)
select '00000000-0000-0000-0000-0000000b3001', 'BK-RENT', 'คอนโด', cat.class_id, cat.id,
       (select id from sri_os.owners where code='THANAKORN'), 'THB'
  from (select id, class_id from sri_os.asset_categories order by id limit 1) cat;

create or replace function pg_temp.as_user(p text) returns void language sql as $fn$
  select set_config('test.uid', p, true) $fn$;

create or replace function pg_temp.entry(p_memo text, p_bank uuid, p_amount numeric) returns jsonb
language sql stable as $fn$
  select jsonb_build_object(
    'txn_type_code', 'inc.rent', 'doc_date', '2026-10-31', 'cash_date', '2026-10-31', 'memo', p_memo,
    'contact_id', '00000000-0000-0000-0000-0000000b2001', 'attachments', jsonb_build_array('หลักฐาน.pdf'),
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', (select id from sri_os.owners where code='THANAKORN'),
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code','1100','debit',p_amount,'credit',0,'cf_category','operating','bank_account_id',p_bank),
        jsonb_build_object('coa_code','4200','debit',0,'credit',p_amount,'cf_category','operating',
                           'asset_id','00000000-0000-0000-0000-0000000b3001'))))) $fn$;

-- ============================================================
-- B1 · ไม่มี settings.manage → INSERT ถูก RLS ปฏิเสธ
-- ============================================================
set local role authenticated;
do $$
declare v_before bigint; v_state text; u text;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000b0001', true);
  select count(*) into v_before from sri_os.bank_accounts;
  foreach u in array array['00000000-0000-0000-0000-0000000b0002', '00000000-0000-0000-0000-0000000b0003'] loop
    perform set_config('test.uid', u, true);
    begin
      insert into sri_os.bank_accounts(owner_id, bank, account_name, display_name, currency)
      values ((select id from sri_os.owners where code='THANAKORN'), 'KBANK', 'ธนากร', 'ธนากร - KBANK ' || u, 'THB');
      raise exception 'FAIL: B1 — ผู้ใช้ % สร้างบัญชีได้ทั้งที่ไม่มี settings.manage', u;
    exception when insufficient_privilege then
      v_state := sqlstate;
    end;
  end loop;
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000b0001', true);
  if (select count(*) from sri_os.bank_accounts) <> v_before then
    raise exception 'FAIL: B1 — จำนวนบัญชีเปลี่ยนทั้งที่ถูกปฏิเสธ';
  end if;
  raise notice 'ok B1 · staff และ manager สร้างบัญชีไม่ได้ — RLS ตอบ % (insufficient_privilege)', v_state;
end $$;

-- ============================================================
-- B2 · ไม่มี settings.manage → UPDATE ไม่โดนแถว
-- ============================================================
do $$
declare n int; u text;
begin
  foreach u in array array['00000000-0000-0000-0000-0000000b0002', '00000000-0000-0000-0000-0000000b0003'] loop
    perform set_config('test.uid', u, true);
    update sri_os.bank_accounts set is_active = false where id = '00000000-0000-0000-0000-0000000b1001';
    get diagnostics n = row_count;
    if n <> 0 then raise exception 'FAIL: B2 — ผู้ใช้ % ปิดบัญชีได้ (% แถว) ทั้งที่ไม่มี settings.manage', u, n; end if;
    update sri_os.bank_accounts set display_name = 'แก้โดยไม่มีสิทธิ์' where id = '00000000-0000-0000-0000-0000000b1001';
    get diagnostics n = row_count;
    if n <> 0 then raise exception 'FAIL: B2 — ผู้ใช้ % แก้ชื่อบัญชีได้', u; end if;
  end loop;
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000b0001', true);
  if (select is_active from sri_os.bank_accounts where id = '00000000-0000-0000-0000-0000000b1001') is not true
     or (select display_name from sri_os.bank_accounts where id = '00000000-0000-0000-0000-0000000b1001') <> 'ธนากร - BBL 888' then
    raise exception 'FAIL: B2 — ค่าของบัญชีเปลี่ยนไปแล้วทั้งที่ UPDATE ไม่โดนแถว';
  end if;
  raise notice 'ok B2 · staff/manager แก้และปิดบัญชีไม่ได้ (0 แถว) — ค่าเดิมไม่เปลี่ยน';
end $$;

-- ============================================================
-- B3 · มี settings.manage → สร้างได้ · สกุลถูกเก็บจริง
-- ============================================================
do $$
declare v_usd uuid; v_def uuid; ccy text;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000b0001', true);
  insert into sri_os.bank_accounts(owner_id, bank, account_name, display_name, account_no_last4, currency, sort_order)
  values ((select id from sri_os.owners where code='THANAKORN'), 'BBL', 'ธนากร FCD', 'ธนากร - FCD USD', '4321', 'USD', 5)
  returning id into v_usd;
  select currency into ccy from sri_os.bank_accounts where id = v_usd;
  if ccy is distinct from 'USD' then raise exception 'FAIL: B3 — สร้างเป็น USD แต่อ่านกลับได้ %', ccy; end if;

  insert into sri_os.bank_accounts(owner_id, bank, account_name, display_name)
  values ((select id from sri_os.owners where code='THANAKORN'), 'SCB', 'ธนากร', 'ธนากร - SCB ไม่ส่งสกุล')
  returning id, currency into v_def, ccy;
  if ccy <> 'THB' then raise exception 'FAIL: B3 — ไม่ส่งสกุลควรได้ THB แต่ได้ %', ccy; end if;

  begin
    insert into sri_os.bank_accounts(owner_id, bank, account_name, display_name, currency)
    values ((select id from sri_os.owners where code='THANAKORN'), 'X', 'x', 'ธนากร - EUR', 'EUR');
    raise exception 'FAIL: B3 — สกุล EUR ผ่านเข้า DB ได้';
  exception when check_violation then null;
  end;
  begin
    insert into sri_os.bank_accounts(owner_id, bank, account_name, display_name, currency)
    values ((select id from sri_os.owners where code='THANAKORN'), 'X', 'x', 'ธนากร - ว่าง', null);
    raise exception 'FAIL: B3 — สกุล null ผ่านเข้า DB ได้';
  exception when not_null_violation then null;
  end;
  raise notice 'ok B3 · USD ถูกเก็บเป็น USD · ไม่ส่งสกุล = THB · EUR/null ถูก DB ปฏิเสธ';
end $$;

-- ============================================================
-- B4 · ปิดใช้งานบัญชีที่มีรายการ
-- ============================================================
reset role;
select set_config('test.uid', '00000000-0000-0000-0000-0000000b0001', true);
select jsonb_build_object('posted', (sri_os.fn_post_entry(pg_temp.entry('B4 รับค่าเช่า 10,000', '00000000-0000-0000-0000-0000000b1001', 10000)))->'transaction_ids');

set local role authenticated;
do $$
declare v_lines bigint; v_after bigint; v_msg text;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000b0001', true);
  select count(*) into v_lines from sri_os.v_ledger_posted where bank_account_id = '00000000-0000-0000-0000-0000000b1001';
  if v_lines <> 1 then raise exception 'FAIL: B4 — ก่อนปิดควรมี 1 บรรทัดเงินสด ได้ %', v_lines; end if;

  update sri_os.bank_accounts set is_active = false where id = '00000000-0000-0000-0000-0000000b1001';

  select count(*) into v_after from sri_os.v_ledger_posted where bank_account_id = '00000000-0000-0000-0000-0000000b1001';
  if v_after <> v_lines then raise exception 'FAIL: B4 — ปิดบัญชีแล้วรายการเดิมอ่านได้ % จาก %', v_after, v_lines; end if;
  if (select sum(debit) from sri_os.v_ledger_posted where bank_account_id = '00000000-0000-0000-0000-0000000b1001') <> 10000 then
    raise exception 'FAIL: B4 — ยอดของบัญชีที่ปิดเพี้ยน';
  end if;
  -- บัญชียังหาเจอในตาราง (รายงานย้อนหลังต้องอ่านชื่อได้)
  if not exists (select 1 from sri_os.bank_accounts where id = '00000000-0000-0000-0000-0000000b1001' and is_active = false) then
    raise exception 'FAIL: B4 — บัญชีที่ปิดหายจากตาราง';
  end if;

  begin
    perform sri_os.fn_post_entry(pg_temp.entry('B4 รับค่าเช่าเข้าบัญชีที่ปิด', '00000000-0000-0000-0000-0000000b1001', 500));
    raise exception 'FAIL: B4 — ลงรายการใหม่เข้าบัญชีที่ปิดใช้งานได้';
  exception when others then
    v_msg := sqlerrm;
    if v_msg like 'FAIL:%' then raise; end if;
    if position('ปิดใช้งาน' in v_msg) = 0 then raise exception 'FAIL: B4 — ถูกปฏิเสธแต่ข้อความไม่ใช่ D-092: %', v_msg; end if;
  end;
  if (select count(*) from sri_os.v_ledger_posted where bank_account_id = '00000000-0000-0000-0000-0000000b1001') <> v_lines then
    raise exception 'FAIL: B4 — มีแถวเพิ่มทั้งที่ถูกปฏิเสธ';
  end if;

  update sri_os.bank_accounts set is_active = true where id = '00000000-0000-0000-0000-0000000b1001';
  perform sri_os.fn_post_entry(pg_temp.entry('B4 รับค่าเช่าหลังเปิดกลับ', '00000000-0000-0000-0000-0000000b1001', 700));
  if (select sum(debit) from sri_os.v_ledger_posted where bank_account_id = '00000000-0000-0000-0000-0000000b1001') <> 10700 then
    raise exception 'FAIL: B4 — หลังเปิดกลับยอดไม่ใช่ 10,700';
  end if;
  raise notice 'ok B4 · ปิดแล้ว: รายการเดิม 1 บรรทัด/10,000 ยังอ่านได้ครบ · ลงใหม่ถูกปฏิเสธ (D-092) · เปิดกลับแล้วลงได้ (10,700)';
end $$;

-- ============================================================
-- B5 · DELETE บัญชีที่มีรายการถูกปฏิเสธ
-- ============================================================
do $$
declare n int;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000b0001', true);
  begin
    delete from sri_os.bank_accounts where id = '00000000-0000-0000-0000-0000000b1001';
    get diagnostics n = row_count;
    if n > 0 then raise exception 'FAIL: B5 — ลบบัญชีที่มีรายการได้'; end if;
    raise notice 'ok B5 · DELETE ไม่โดนแถว (ไม่มี policy ลบ)';
  exception when insufficient_privilege or foreign_key_violation or raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
    raise notice 'ok B5 · DELETE ถูกปฏิเสธ: %', sqlerrm;
  end;
end $$;

-- ============================================================
-- B6 · สังเกต: สิ่งที่ DB ยังไม่กัน (ไม่ assert — รายงานให้เจ้าของ migration)
-- ============================================================
do $$
declare v_usd uuid; v_ok boolean; v_dup boolean;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000b0001', true);
  select id into v_usd from sri_os.bank_accounts where display_name = 'ธนากร - FCD USD';
  begin
    update sri_os.bank_accounts set currency = 'THB' where id = '00000000-0000-0000-0000-0000000b1001' or id = v_usd;
    v_ok := true;
  exception when others then v_ok := false;
  end;
  begin
    insert into sri_os.bank_accounts(owner_id, bank, account_name, display_name)
    values ((select id from sri_os.owners where code='THANAKORN'), 'BBL', 'x', 'ธนากร - BBL 888');
    v_dup := true;
  exception when others then v_dup := false;
  end;
  raise notice 'OBSERVED B6 · เปลี่ยนสกุลของบัญชีที่มีรายการได้? % (ควรห้าม: บัญชีที่มีรายการแล้วเปลี่ยนสกุล = ยอดเงินสดในงบเพี้ยนเงียบๆ) · ชื่อบัญชีซ้ำในผู้ถือเดียวกันได้? %', v_ok, v_dup;
end $$;

rollback;
