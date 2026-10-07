-- ============================================================
-- SRI OS · เทสต์ "อนุมัติแล้วต้องเป็นจริง" + สถานะงวดตาม ledger + ร่องรอยตารางกฎ
--   ปิดด้วย supabase/migrations/20261008000006_approval_integrity.sql
--
--   I0  · โครงสร้าง: trigger/ฟังก์ชันใหม่ติดจริง · ชนิดถูก · ACL ปิด · ไม่เรียก fn_can
--   I1  · **ข้อบกพร่องข้อ 1**: Manager อนุมัติร่างของ Staff ตรงๆ โดย patch ไม่ถูกใช้
--         → ต้องถูกปฏิเสธ และข้อมูลต้องไม่เปลี่ยน ร่างต้องยัง pending
--   I2  · เส้นทางที่ถูกต้อง: อนุมัติผ่าน fn_apply_asset_draft() → **ข้อมูลเปลี่ยนจริง**
--   I3  · ปฏิเสธร่าง (reject) และยกเลิกร่างของตัวเอง (cancel) ต้องยังทำได้
--   I4  · **ข้อบกพร่องข้อ 2**: ร่าง kind='create' ชี้ทรัพย์ที่มีอยู่ก่อน → ต้องถูกปฏิเสธ
--         ทั้งฝั่ง Manager และฝั่ง Management · assets ต้องไม่เพิ่ม/ไม่เปลี่ยน
--   I5  · Management อนุมัติร่างสร้างทรัพย์ → **มีทรัพย์ใหม่จริง** + patch ถูกใช้
--   I6  · "ตรวจผล ไม่ใช่เส้นทาง": อนุมัติตรงๆ ที่ **ทำให้เกิดผลจริงครบ** ต้องผ่าน
--         (ไม่งั้นคือกันเส้นทางแทนที่จะกันผลลัพธ์) · และทรัพย์ชิ้นเดียวถูกอ้างซ้ำไม่ได้
--   I7  · assets.created_at / id แก้ไม่ได้ (เงื่อนไขที่รองรับข้อพิสูจน์ของ I4)
--   I8  · audit_log ปลอมไม่ได้ (เงื่อนไขที่รองรับข้อพิสูจน์ชั้นที่สองของ I4)
--   I9  · **ข้อบกพร่องข้อ 3 · กระทบตัวเลขเงิน**: void รายการแล้วงวดต้องคืนสถานะ
--         ตามวันครบกำหนด (overdue/upcoming) ไม่ใช่ค้าง 'received'
--         ครอบ: งวดเดียวผูกรายการที่ถูก void · **สองงวดผูกร่างเดียว** · void แล้ว
--         post ใหม่ · การกลับรายการ (reverse) · กลับรายการที่ถูก void (ทางกลับ) ·
--         'waived' ต้องไม่ถูกแตะ · งวดที่ไม่มีร่างผูกต้องไม่ถูกแตะ
--   I10 · mirror เดิม: สลับ draft_entry_id ใต้แถว 'received' ต้องถูกตรวจใหม่
--   I11 · **ข้อบกพร่องข้อ 4**: ตารางกฎ + ผังบัญชี 7 ตารางมี audit จริง **ทั้งสามคำสั่ง**
--         และ row_id ตรงกับสูตร fn_audit_row_id
--   I12 · เคส "ไม่ส่งข้อมูล" ทุกจุดของกฎใหม่
--   I13 · **เส้นทางที่ถูกต้องต้องยังทำได้** (บทเรียนข้อ 7): post · void · reverse ·
--         ปิด-เปิดงวด · แก้ค่าตั้งค่า · เขียนตารางกฎแบบ sync:rules · เลื่อนงวด
--
-- รันในเครื่อง:  UNDER_TEST="... 20261008000006_approval_integrity.sql" \
--                  bash scripts/test-rls-local.sh
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ rollback ปิดท้าย
--
-- ข้อจำกัดของ harness ที่ต้องรู้ (ไม่ใช่ข้อบกพร่องของกฎ):
--   ทั้งไฟล์อยู่ใน **ธุรกรรมเดียว** → now() คงที่ตลอดไฟล์ · "ทรัพย์ที่มีอยู่ก่อน"
--   จึงจำลองด้วยการ insert พร้อม created_at ย้อนหลังอย่างชัดเจน (I4) และความแน่น
--   ของข้อพิสูจน์ชั้นที่สองพิสูจน์ด้วย "ปลอม audit_log ไม่ได้" ที่ I8 แทน
--
-- สิ่งที่ไฟล์นี้ต้องจับได้ (ไล่จาก "ถ้าถอดการแก้ออกแล้วต้องแดง"):
--   J1  ถอดการเทียบ patch กับแถวจริงออกจาก fn_asset_draft_frozen → I1 I6 แดง
--   J2  ถอดเงื่อนไข created_at = now() ของ kind='create'          → I4 แดง
--   J3  ถอด trg_asset_created_at_immutable                        → I7 แดง
--   J4  ถอด unique index asset_drafts_applied_create_uniq         → I6 แดง
--   J5  ถอด trg_schedule_sync_from_txn                            → I9 แดง (ทุกข้อย่อย)
--   J6  sync แล้วเดาค่าเอง (เขียนทับ waived / งวดที่ไม่มีร่าง)     → I9 แดง
--   J7  ไม่นับการกลับรายการว่า "ไม่มีผล"                          → I9 I10 แดง
--   J8  ไม่ติด audit ตารางกฎตารางใดตารางหนึ่ง                      → I0 I11 แดง
--   J9  ติด audit ตารางกฎแค่ INSERT                                → I11 แดง
--   J10 ใช้ fn_audit (ไม่ใช่ fn_audit_keyed) กับ txn_types/roles    → I11 แดง (42703)
--   J11 เปิด execute ฟังก์ชันใหม่ให้ authenticated/anon             → I0 แดง
--   J12 กันแน่นเกินจนปฏิเสธร่าง/ยกเลิกร่าง/post/void/reverse ไม่ได้ → I3 I13 แดง
-- ============================================================

begin;

-- ---------- fixtures: ผู้ใช้ ----------
create temporary table t_iuid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_iuid(label) values ('i_super'), ('i_mgmt'), ('i_mgr'), ('i_staff');
insert into auth.users(id) select id from t_iuid;

insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, u.label || '@int.local', u.label, x.role, true
  from t_iuid u
  join (values ('i_super', 'super_admin'), ('i_mgmt', 'management'),
               ('i_mgr', 'manager'), ('i_staff', 'staff')) as x(label, role)
    on x.label = u.label;

create or replace function pg_temp.iuid(p_label text) returns uuid
language sql stable as $fn$ select id from t_iuid where label = p_label $fn$;

create or replace function pg_temp.ilogin(p_label text) returns void
language sql as $fn$
  select set_config('test.uid', coalesce((select id::text from t_iuid where label = p_label), ''), true);
$fn$;

-- RLS ปฏิเสธ UPDATE แบบ **เงียบ** (0 แถว ไม่ใช่ error) → แยกให้ออกด้วยตัวนับแถว
create or replace function pg_temp.irows(p_label text, p_sql text, p_expect int) returns void
language plpgsql as $fn$
declare n int;
begin
  execute p_sql;
  get diagnostics n = row_count;
  if n <> p_expect then
    raise exception 'FAIL: % — คาดว่ากระทบ % แถว แต่ได้ % แถว · sql: %', p_label, p_expect, n, p_sql;
  end if;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: % — คำสั่งล้มด้วย error (%) ทั้งที่คาดว่าจะกระทบ % แถว · sql: %',
    p_label, sqlerrm, p_expect, p_sql;
end $fn$;

create or replace function pg_temp.ipass(p_label text, p_sql text) returns void
language plpgsql as $fn$
begin
  execute p_sql;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: % — คำสั่งควรสำเร็จแต่ล้ม (%) · sql: %', p_label, sqlerrm, p_sql;
end $fn$;

-- "ต้องล้มด้วย error จริง" — ถ้า RLS ปฏิเสธเงียบ (0 แถว) ก็นับเป็น FAIL
create or replace function pg_temp.ifail(p_label text, p_sql text) returns text
language plpgsql as $fn$
begin
  execute p_sql;
  raise exception 'FAIL: % — คำสั่งสำเร็จทั้งที่ต้องถูกปฏิเสธ · sql: %', p_label, p_sql;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  return sqlerrm;
end $fn$;

do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.t_iuid to authenticated', s);
end $$;

insert into sri_os.user_owner_access(user_id, owner_id)
select u.id, o.id from t_iuid u cross join sri_os.owners o
 where u.label in ('i_mgr', 'i_staff') and o.code = 'SRI_CORP'
on conflict do nothing;

-- ---------- fixtures: คู่ค้า · ทรัพย์ "ที่มีอยู่ก่อน" · บัญชี · สัญญา · งวด ----------
-- created_at ย้อนหลังอย่างชัดเจน = จำลอง "ทรัพย์ที่มีอยู่ก่อนการอนุมัติ"
-- (ทั้งไฟล์อยู่ในธุรกรรมเดียว → ถ้าใช้ค่า default จะเป็น now() เท่ากับการอนุมัติ)
insert into sri_os.contacts(id, first_name, last_name, types)
values ('00000000-0000-0000-0000-0000000f9a01', 'คู่สัญญาเทสต์อนุมัติ', 'เทสต์', array['borrower']);

insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, manager_user_id,
                          location, created_at)
select x.id, x.code, x.name,
       (select class_id from sri_os.asset_categories order by code limit 1),
       (select id       from sri_os.asset_categories order by code limit 1),
       (select id from sri_os.owners where code = 'SRI_CORP'),
       x.mgr, x.loc, now() - interval '1 day'
  from (values
    ('00000000-0000-0000-0000-0000000fa001'::uuid, 'INT-A1', 'ทรัพย์ของผู้บริหาร',
     pg_temp.iuid('i_mgr'), 'ชลบุรี'),
    ('00000000-0000-0000-0000-0000000fa002'::uuid, 'INT-A2', 'ทรัพย์ที่ยังไม่มอบหมาย',
     null, 'ระยอง')
  ) as x(id, code, name, mgr, loc);

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
select '00000000-0000-0000-0000-0000000fb001', id, 'KBANK', 'บัญชีเทสต์อนุมัติ', 'บัญชีเทสต์อนุมัติ'
  from sri_os.owners where code = 'SRI_CORP';

-- สัญญาครบ 100% (fn_schedule_requires_complete_contract บังคับตอน insert งวด)
insert into sri_os.contracts(id, code, owner_id, asset_id, type, counterparty_contact_id,
                             principal, rate, rate_period, interest_method,
                             start_date, end_date, installments, file_urls, status)
select '00000000-0000-0000-0000-0000000fc001', 'INT-C1', o.id,
       '00000000-0000-0000-0000-0000000fa001', 'loan_receivable',
       '00000000-0000-0000-0000-0000000f9a01',
       1200000, 1.25, 'month', 'simple',
       current_date - 60, current_date + 300, 12, array['สัญญา-INT.pdf'], 'active'
  from sri_os.owners o where o.code = 'SRI_CORP';

-- สองงวดที่ผูก **ร่างใบเดียวกัน** (จ่ายก้อนเดียวปิดสองงวด) + หนึ่งงวดที่ไม่มีร่าง
insert into sri_os.schedules(id, contract_id, period, due_date, expected_amount,
                             principal_amount, interest_amount)
values ('00000000-0000-0000-0000-0000000fd001', '00000000-0000-0000-0000-0000000fc001',
        1, current_date - 10, 100000, 85000, 15000),
       ('00000000-0000-0000-0000-0000000fd002', '00000000-0000-0000-0000-0000000fc001',
        2, current_date + 30, 100000, 86000, 14000),
       ('00000000-0000-0000-0000-0000000fd003', '00000000-0000-0000-0000-0000000fc001',
        3, current_date + 60, 100000, 87000, 13000);

-- ---------- fixtures: ร่างรายการ + รายการที่ post แล้ว + ใบยืนยันเงิน ----------
create or replace function pg_temp.ipost(p_txn uuid, p_amount numeric, p_reverses uuid default null)
returns void language plpgsql as $fn$
begin
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, cash_date,
                                  contact_id, attachments, created_by, source, reverses_id)
  select p_txn, o.id, 'inc.other', current_date, current_date,
         '00000000-0000-0000-0000-0000000f9a01', array['หลักฐาน-INT.pdf'],
         pg_temp.iuid('i_mgmt'),
         case when p_reverses is null then 'manual' else 'reverse' end::sri_os.txn_source,
         p_reverses
    from sri_os.owners o where o.code = 'SRI_CORP';
  insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
  select p_txn, c.id,
         case when c.rn = 1 then p_amount else 0 end,
         case when c.rn = 2 then p_amount else 0 end
    from (select id, row_number() over (order by code) rn
            from sri_os.chart_of_accounts where code not like '11%' order by code limit 2) c;
end $fn$;

select pg_temp.ipost('00000000-0000-0000-0000-0000000ff001', 200000);

insert into sri_os.draft_entries(id, owner_id, txn_type_code, doc_date, amount, status,
                                 posted_txn_id, created_by, reviewed_by, reviewed_at)
select '00000000-0000-0000-0000-0000000fe001', o.id, 'inc.other', current_date, 200000,
       'approved', '00000000-0000-0000-0000-0000000ff001',
       pg_temp.iuid('i_staff'), pg_temp.iuid('i_mgmt'), now()
  from sri_os.owners o where o.code = 'SRI_CORP';

insert into sri_os.cash_confirmations(transaction_id, bank_account_id, expected_amount,
                                     actual_amount, actual_date, confirmed_by, confirmed_at)
values ('00000000-0000-0000-0000-0000000ff001', '00000000-0000-0000-0000-0000000fb001',
        200000, 200000, current_date, (select id from t_iuid where label = 'i_mgmt'), now());

-- ============================================================
-- I0 · โครงสร้าง — ไล่จาก pg_trigger / pg_proc / pg_index จริง ไม่ใช่ไล่ไฟล์
-- ============================================================
do $$
declare r record; v text; n int;
begin
  for r in
    select * from (values
      ('assets',       'trg_asset_created_at_immutable', 2),
      ('asset_drafts', 'trg_asset_draft_frozen',         2),
      ('schedules',    'trg_schedule_status_mirror',     2),
      ('transactions', 'trg_schedule_sync_from_txn',     0)
    ) as t(tbl, trg, before_bit)
  loop
    if not exists (select 1 from pg_trigger tg
                    where tg.tgrelid = ('sri_os.' || r.tbl)::regclass and not tg.tgisinternal
                      and tg.tgname = r.trg
                      and (tg.tgtype & 1) <> 0 and (tg.tgtype & 2) = r.before_bit) then
      raise exception 'FAIL: trigger %.% ไม่ได้ติด หรือชนิดผิด', r.tbl, r.trg;
    end if;
  end loop;

  -- unique index ของการอ้างทรัพย์ (เฉพาะ kind='create')
  if not exists (select 1 from pg_indexes
                  where schemaname = 'sri_os' and tablename = 'asset_drafts'
                    and indexname = 'asset_drafts_applied_create_uniq') then
    raise exception 'FAIL: ไม่มี unique index asset_drafts_applied_create_uniq';
  end if;

  -- ฟังก์ชันใหม่ต้องเรียกจากข้างนอกไม่ได้ (ไม่มีตัวไหนที่หน้าจอ/policy เรียก)
  select string_agg(p.proname, ', '), count(*) into v, n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.proname in ('fn_asset_created_at_immutable', 'fn_schedule_sync_from_txn',
                       'fn_schedule_ledger_status', 'fn_asset_draft_frozen',
                       'fn_schedule_status_mirror')
     and (has_function_privilege('public', p.oid, 'execute')
       or has_function_privilege('anon', p.oid, 'execute')
       or has_function_privilege('authenticated', p.oid, 'execute'));
  if n > 0 then
    raise exception 'FAIL: ฟังก์ชันของรอบนี้ยังเรียกได้จากข้างนอก % ตัว: %', n, v;
  end if;

  -- ฟังก์ชันของรอบนี้ต้องมีอยู่ครบ 5 ตัว (กันเทสต์เปล่า)
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.proname in ('fn_asset_created_at_immutable', 'fn_schedule_sync_from_txn',
                       'fn_schedule_ledger_status', 'fn_asset_draft_frozen',
                       'fn_schedule_status_mirror');
  if n <> 5 then raise exception 'FAIL: ฟังก์ชันของรอบนี้ควรมี 5 ตัว เจอ %', n; end if;

  -- trigger function ทั้งสคีมาต้องไม่เรียก fn_can (กฎเงินห้ามขึ้นกับตารางสิทธิ์)
  select string_agg(distinct p.proname, ', ') into v
    from pg_trigger tg join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace join pg_proc p on p.oid = tg.tgfoid
   where ns.nspname = 'sri_os' and not tg.tgisinternal and p.prosrc ~* 'fn_can';
  if v is not null then raise exception 'FAIL: trigger function เรียก fn_can: %', v; end if;

  -- 7 ตารางกฎต้องมี audit ครบสามคำสั่ง · after · for each row
  select string_agg(t, ', ') into v from unnest(array[
      'chart_of_accounts', 'txn_types', 'asset_classes', 'asset_categories',
      'roles', 'permissions', 'role_permissions']) t
   where not exists (
     select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
      where tg.tgrelid = ('sri_os.' || t)::regclass and not tg.tgisinternal
        and p.proname in ('fn_audit', 'fn_audit_keyed')
        and (tg.tgtype & 4) <> 0 and (tg.tgtype & 16) <> 0 and (tg.tgtype & 8) <> 0
        and (tg.tgtype & 2) = 0 and (tg.tgtype & 1) <> 0);
  if v is not null then
    raise exception 'FAIL: ตารางกฎที่ยังไม่มี audit ครบสามคำสั่ง: %', v;
  end if;

  raise notice 'ok I0 · trigger 4 ตัว + unique index ติดจริง · ฟังก์ชันใหม่ 5 ตัวปิด execute · ไม่มี trigger ไหนเรียก fn_can · ตารางกฎ 7 ตารางมี audit';
end $$;

set local role authenticated;

-- ============================================================
-- I1 · ข้อบกพร่องข้อ 1 — อนุมัติร่างแล้วแต่ patch ไม่ถูกนำไปใช้
--      เคสที่ผู้ตรวจรันได้จริง: Staff ร่าง patch {"location":"ไม่ควรถูกเมิน"}
--      → Manager อนุมัติตรงๆ → assets.location ยังเป็น 'ชลบุรี' แต่ร่างขึ้น approved
-- ============================================================
do $$
declare v_own uuid; v_draft uuid; v_loc text; v_status text; v_err text;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';

  perform pg_temp.ilogin('i_staff');
  insert into sri_os.asset_drafts(kind, owner_id, target_asset_id, patch)
  values ('update', v_own, '00000000-0000-0000-0000-0000000fa001',
          '{"location": "ไม่ควรถูกเมิน"}'::jsonb)
  returning id into v_draft;

  -- Manager มี asset.manage + เห็นทรัพย์นี้ (manager_user_id = ตัวเอง) → policy ปล่อย
  -- ด่านที่ต้องกันคือ trigger · และต้องเป็น **error** ไม่ใช่ปฏิเสธเงียบ
  perform pg_temp.ilogin('i_mgr');
  v_err := pg_temp.ifail('Manager อนุมัติร่างตรงๆ โดยไม่แก้ทรัพย์', format(
    'update sri_os.asset_drafts set status = ''approved'', applied_asset_id = %L, reviewed_by = %L, reviewed_at = now() where id = %L',
    '00000000-0000-0000-0000-0000000fa001', pg_temp.iuid('i_mgr'), v_draft));
  if v_err !~ 'ยังไม่ถูกนำไปใช้' then
    raise exception 'FAIL: ถูกปฏิเสธด้วยเหตุผลอื่น ไม่ใช่ "patch ยังไม่ถูกนำไปใช้": %', v_err;
  end if;

  -- ของจริงต้องไม่ขยับ และร่างต้องยัง pending (ไม่ใช่ approved ลอยๆ)
  select location into v_loc from sri_os.assets where id = '00000000-0000-0000-0000-0000000fa001';
  select status::text into v_status from sri_os.asset_drafts where id = v_draft;
  if v_loc <> 'ชลบุรี' then raise exception 'FAIL: ทรัพย์เปลี่ยนไปแล้ว (%)', v_loc; end if;
  if v_status <> 'pending' then raise exception 'FAIL: ร่างขึ้นสถานะ % ทั้งที่การอนุมัติถูกปฏิเสธ', v_status; end if;

  -- เลี่ยงด้วยการ "แก้ทรัพย์เป็นค่าอื่น" ก็ไม่ผ่าน (ต้องตรงกับ patch ทุกคีย์)
  perform pg_temp.irows('Manager แก้ทรัพย์เป็นค่าอื่น',
    'update sri_os.assets set location = ''ค่าที่ไม่ตรงกับร่าง'' where id = ''00000000-0000-0000-0000-0000000fa001''', 1);
  v_err := pg_temp.ifail('อนุมัติโดยทรัพย์เป็นค่าอื่นที่ไม่ตรง patch', format(
    'update sri_os.asset_drafts set status = ''approved'', applied_asset_id = %L, reviewed_by = %L, reviewed_at = now() where id = %L',
    '00000000-0000-0000-0000-0000000fa001', pg_temp.iuid('i_mgr'), v_draft));
  if v_err !~ 'ยังไม่ถูกนำไปใช้' then
    raise exception 'FAIL: เหตุผลการปฏิเสธไม่ตรง: %', v_err;
  end if;
  perform pg_temp.irows('คืนค่าทรัพย์เป็นของเดิม',
    'update sri_os.assets set location = ''ชลบุรี'' where id = ''00000000-0000-0000-0000-0000000fa001''', 1);

  raise notice 'ok I1 · อนุมัติร่างโดย patch ไม่ถูกใช้ = ถูกปฏิเสธด้วย error · ทรัพย์ไม่เปลี่ยน · ร่างยัง pending';
end $$;

-- ============================================================
-- I2 · เส้นทางที่ถูกต้อง — อนุมัติผ่าน fn_apply_asset_draft() แล้วข้อมูลเปลี่ยนจริง
-- ============================================================
do $$
declare v_own uuid; v_draft uuid; v_asset uuid; v_loc text; v_note text;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';

  perform pg_temp.ilogin('i_staff');
  insert into sri_os.asset_drafts(kind, owner_id, target_asset_id, patch)
  values ('update', v_own, '00000000-0000-0000-0000-0000000fa001',
          '{"location": "ศรีราชา", "size_note": "2 ไร่ 1 งาน"}'::jsonb)
  returning id into v_draft;

  perform pg_temp.ilogin('i_mgr');
  v_asset := sri_os.fn_apply_asset_draft(v_draft);
  if v_asset <> '00000000-0000-0000-0000-0000000fa001' then
    raise exception 'FAIL: ร่างแก้ไขควรคืน target_asset_id เดิม (ได้ %)', v_asset;
  end if;
  select location, size_note into v_loc, v_note from sri_os.assets where id = v_asset;
  if v_loc <> 'ศรีราชา' or v_note <> '2 ไร่ 1 งาน' then
    raise exception 'FAIL: อนุมัติแล้วข้อมูลไม่เปลี่ยนจริง (location=% size_note=%)', v_loc, v_note;
  end if;
  if (select status::text from sri_os.asset_drafts where id = v_draft) <> 'approved'
  or (select applied_asset_id from sri_os.asset_drafts where id = v_draft) <> v_asset
  or (select reviewed_by from sri_os.asset_drafts where id = v_draft) <> pg_temp.iuid('i_mgr') then
    raise exception 'FAIL: ร่างไม่ได้ถูกบันทึกว่าอนุมัติแล้วพร้อม reviewed_by';
  end if;

  raise notice 'ok I2 · Staff ร่าง → Manager อนุมัติผ่าน fn_apply_asset_draft → **ข้อมูลเปลี่ยนจริง** ทั้งสองช่อง';
end $$;

-- ============================================================
-- I3 · ปฏิเสธร่าง + ยกเลิกร่างของตัวเอง ต้องยังทำได้ (กันแน่นเกินก็คือพัง)
-- ============================================================
do $$
declare v_own uuid; v_d1 uuid; v_d2 uuid;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';

  perform pg_temp.ilogin('i_staff');
  insert into sri_os.asset_drafts(kind, owner_id, target_asset_id, patch)
  values ('update', v_own, '00000000-0000-0000-0000-0000000fa001', '{"location": "ที่จะถูกปฏิเสธ"}'::jsonb)
  returning id into v_d1;
  insert into sri_os.asset_drafts(kind, owner_id, target_asset_id, patch)
  values ('update', v_own, '00000000-0000-0000-0000-0000000fa001', '{"location": "ที่จะถูกยกเลิก"}'::jsonb)
  returning id into v_d2;

  -- ปฏิเสธ: ต้องผ่าน และ **ต้องไม่** ต้องการ applied_asset_id หรือการแก้ทรัพย์
  perform pg_temp.ilogin('i_mgr');
  perform pg_temp.irows('Manager ปฏิเสธร่าง', format(
    'update sri_os.asset_drafts set status = ''rejected'', reject_reason = ''ข้อมูลไม่พอ'', reviewed_by = %L, reviewed_at = now() where id = %L',
    pg_temp.iuid('i_mgr'), v_d1), 1);
  if (select status::text from sri_os.asset_drafts where id = v_d1) <> 'rejected' then
    raise exception 'FAIL: ปฏิเสธร่างไม่สำเร็จ';
  end if;
  -- ปฏิเสธโดยไม่บอกเหตุผล = ยังล้มเหมือนเดิม
  perform pg_temp.ifail('ปฏิเสธร่างโดยไม่บอกเหตุผล', format(
    'update sri_os.asset_drafts set status = ''rejected'', reviewed_by = %L, reviewed_at = now() where id = %L',
    pg_temp.iuid('i_mgr'), v_d2));

  -- คนคีย์ยกเลิกร่างของตัวเองได้
  perform pg_temp.ilogin('i_staff');
  perform pg_temp.irows('Staff ยกเลิกร่างของตัวเอง', format(
    'update sri_os.asset_drafts set status = ''cancelled'', reviewed_by = %L, reviewed_at = now() where id = %L',
    pg_temp.iuid('i_staff'), v_d2), 1);
  if (select status::text from sri_os.asset_drafts where id = v_d2) <> 'cancelled' then
    raise exception 'FAIL: ยกเลิกร่างของตัวเองไม่สำเร็จ';
  end if;

  -- ทรัพย์ต้องไม่ถูกแตะจากการปฏิเสธ/ยกเลิก
  if (select location from sri_os.assets where id = '00000000-0000-0000-0000-0000000fa001') <> 'ศรีราชา' then
    raise exception 'FAIL: การปฏิเสธ/ยกเลิกร่างไปแก้ทรัพย์';
  end if;

  raise notice 'ok I3 · ปฏิเสธร่าง (พร้อมเหตุผล) · ยกเลิกร่างของตัวเอง ยังทำได้ · ปฏิเสธไม่บอกเหตุผลยังล้ม · ทรัพย์ไม่ถูกแตะ';
end $$;

-- ============================================================
-- I4 · ข้อบกพร่องข้อ 2 — ร่าง kind='create' ชี้ทรัพย์ที่มีอยู่ก่อน
--      Manager คัดลอก name/class_id/category_id จากทรัพย์ที่ตนบริหาร
--      แล้วอนุมัติโดยชี้ applied_asset_id ไปที่ทรัพย์เดิมนั้น
-- ============================================================
do $$
declare v_own uuid; v_cls uuid; v_cat uuid; v_draft uuid; v_err text; n0 int; n1 int;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select class_id, category_id into v_cls, v_cat
    from sri_os.assets where id = '00000000-0000-0000-0000-0000000fa001';
  select count(*) into n0 from sri_os.assets;

  -- ฝั่ง Manager: คัดลอกทุกอย่างจากทรัพย์ที่ตนบริหาร
  perform pg_temp.ilogin('i_mgr');
  insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id)
  values ('create', v_own, 'ทรัพย์ของผู้บริหาร', v_cls, v_cat) returning id into v_draft;

  v_err := pg_temp.ifail('Manager อนุมัติร่างสร้างทรัพย์โดยชี้ทรัพย์ที่มีอยู่ก่อน', format(
    'update sri_os.asset_drafts set status = ''approved'', applied_asset_id = %L, reviewed_by = %L, reviewed_at = now() where id = %L',
    '00000000-0000-0000-0000-0000000fa001', pg_temp.iuid('i_mgr'), v_draft));
  if v_err !~ 'มีอยู่ก่อนการอนุมัติ' then
    raise exception 'FAIL: เหตุผลการปฏิเสธไม่ตรง (ต้องเป็น "ทรัพย์มีอยู่ก่อน"): %', v_err;
  end if;

  -- เส้นทางฟังก์ชันก็ยังอนุมัติไม่ได้ (assets_insert ต้องมี portfolio.view_all)
  v_err := pg_temp.ifail('Manager อนุมัติร่างสร้างทรัพย์ผ่านฟังก์ชัน',
    format('select sri_os.fn_apply_asset_draft(%L)', v_draft));

  -- ฝั่ง Management: มี portfolio.view_all → เห็นทรัพย์ที่ยังไม่มอบหมายด้วย
  -- แต่ก็ยังชี้ทรัพย์ที่มีอยู่ก่อนไม่ได้
  perform pg_temp.ilogin('i_mgmt');
  insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id)
  values ('create', v_own, 'ทรัพย์ที่ยังไม่มอบหมาย', v_cls, v_cat) returning id into v_draft;
  v_err := pg_temp.ifail('Management ชี้ทรัพย์ที่มีอยู่ก่อน', format(
    'update sri_os.asset_drafts set status = ''approved'', applied_asset_id = %L, reviewed_by = %L, reviewed_at = now() where id = %L',
    '00000000-0000-0000-0000-0000000fa002', pg_temp.iuid('i_mgmt'), v_draft));
  if v_err !~ 'มีอยู่ก่อนการอนุมัติ' then
    raise exception 'FAIL: เหตุผลการปฏิเสธไม่ตรง: %', v_err;
  end if;

  -- และชี้ทรัพย์ที่ชื่อ/หมวดไม่ตรงก็ยังล้มเหมือนเดิม (ด่านของไฟล์ก่อน)
  v_err := pg_temp.ifail('ชี้ทรัพย์ที่ชื่อ/หมวดไม่ตรงกับร่าง', format(
    'update sri_os.asset_drafts set status = ''approved'', applied_asset_id = %L, reviewed_by = %L, reviewed_at = now() where id = %L',
    '00000000-0000-0000-0000-0000000fa001', pg_temp.iuid('i_mgmt'), v_draft));

  select count(*) into n1 from sri_os.assets;
  if n1 <> n0 then raise exception 'FAIL: การอนุมัติปลอมทำให้ทรัพย์เพิ่ม/ลด (%→%)', n0, n1; end if;

  raise notice 'ok I4 · ร่าง create ที่ชี้ทรัพย์ที่มีอยู่ก่อน ถูกปฏิเสธทั้งฝั่ง Manager และ Management · จำนวนทรัพย์ไม่ขยับ';
end $$;

-- ============================================================
-- I5 · Management อนุมัติร่างสร้างทรัพย์ → **มีทรัพย์ใหม่จริง** + patch ถูกใช้
-- ============================================================
do $$
declare v_own uuid; v_cls uuid; v_cat uuid; v_draft uuid; v_asset uuid;
        n0 int; n1 int; v_code text; v_loc text; v_created timestamptz;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;
  select count(*) into n0 from sri_os.assets;

  perform pg_temp.ilogin('i_staff');
  insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id, patch)
  values ('create', v_own, 'ทรัพย์ชิ้นใหม่จากร่างของ Staff', v_cls, v_cat,
          '{"location": "บางแสน", "units": 4.5}'::jsonb)
  returning id into v_draft;

  perform pg_temp.ilogin('i_mgmt');
  v_asset := sri_os.fn_apply_asset_draft(v_draft);
  select count(*) into n1 from sri_os.assets;
  if n1 <> n0 + 1 then raise exception 'FAIL: อนุมัติร่างสร้างทรัพย์แล้ว assets ควร +1 (%→%)', n0, n1; end if;

  select code, location, created_at into v_code, v_loc, v_created
    from sri_os.assets where id = v_asset;
  if v_code is null or v_code !~ '^[A-Z_]+-[0-9]{4}$' then
    raise exception 'FAIL: รหัสทรัพย์ผิดรูป: %', coalesce(v_code, '(null)');
  end if;
  if v_loc <> 'บางแสน' then raise exception 'FAIL: patch ไม่ถูกใช้ (location=%)', v_loc; end if;
  if v_created is distinct from now() then
    raise exception 'FAIL: ทรัพย์ใหม่ created_at ไม่ใช่เวลาของธุรกรรมที่อนุมัติ';
  end if;
  if (select applied_asset_id from sri_os.asset_drafts where id = v_draft) <> v_asset then
    raise exception 'FAIL: ร่างไม่ได้ชี้ทรัพย์ที่สร้าง';
  end if;

  raise notice 'ok I5 · Management อนุมัติร่างสร้างทรัพย์ → assets +1 จริง · patch ถูกใช้ · รหัสออกตอนอนุมัติ';
end $$;

-- ============================================================
-- I6 · "ตรวจผล ไม่ใช่เส้นทาง"
--      อนุมัติตรงๆ ที่ทำให้เกิดผลจริงครบทุกข้อ **ต้องผ่าน** (ไม่งั้นแปลว่าเรากัน
--      เส้นทางแทนที่จะกันผลลัพธ์ แล้วเส้นทางอื่นในอนาคตจะหลุด)
--      และทรัพย์ชิ้นเดียวถูกอ้างว่า "เกิดจากร่าง" ได้ครั้งเดียว
-- ============================================================
do $$
declare v_own uuid; v_cls uuid; v_cat uuid; v_d1 uuid; v_d2 uuid; v_new uuid; v_err text;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;

  perform pg_temp.ilogin('i_mgmt');
  insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id, patch)
  values ('create', v_own, 'ทรัพย์ที่ Management สร้างเองแล้วอนุมัติ', v_cls, v_cat,
          '{"location": "หัวหิน"}'::jsonb)
  returning id into v_d1;

  -- Management สร้างทรัพย์เองในธุรกรรมเดียวกัน (มีสิทธิ์อยู่แล้ว) แต่ **ยังไม่ใส่ patch**
  insert into sri_os.assets(code, name, class_id, category_id, owner_id)
  values ('INT-N9', 'ทรัพย์ที่ Management สร้างเองแล้วอนุมัติ', v_cls, v_cat, v_own)
  returning id into v_new;

  v_err := pg_temp.ifail('อนุมัติตรงๆ โดยยังไม่ใส่ patch ให้ทรัพย์ใหม่', format(
    'update sri_os.asset_drafts set status = ''approved'', applied_asset_id = %L, reviewed_by = %L, reviewed_at = now() where id = %L',
    v_new, pg_temp.iuid('i_mgmt'), v_d1));
  if v_err !~ 'ยังไม่ถูกนำไปใช้' then
    raise exception 'FAIL: เหตุผลการปฏิเสธไม่ตรง: %', v_err;
  end if;

  -- ใส่ patch ให้ตรงแล้วอนุมัติตรงๆ → **ต้องผ่าน** เพราะผลลัพธ์ถูกต้องครบ
  perform pg_temp.irows('ใส่ patch ให้ทรัพย์ใหม่',
    format('update sri_os.assets set location = ''หัวหิน'' where id = %L', v_new), 1);
  perform pg_temp.irows('อนุมัติตรงๆ เมื่อผลลัพธ์ถูกต้องครบ', format(
    'update sri_os.asset_drafts set status = ''approved'', applied_asset_id = %L, reviewed_by = %L, reviewed_at = now() where id = %L',
    v_new, pg_temp.iuid('i_mgmt'), v_d1), 1);

  -- ร่างใบที่สองอ้างทรัพย์ชิ้นเดิมไม่ได้ (unique index)
  insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id, patch)
  values ('create', v_own, 'ทรัพย์ที่ Management สร้างเองแล้วอนุมัติ', v_cls, v_cat,
          '{"location": "หัวหิน"}'::jsonb)
  returning id into v_d2;
  v_err := pg_temp.ifail('ร่างใบที่สองอ้างทรัพย์ชิ้นเดียวกัน', format(
    'update sri_os.asset_drafts set status = ''approved'', applied_asset_id = %L, reviewed_by = %L, reviewed_at = now() where id = %L',
    v_new, pg_temp.iuid('i_mgmt'), v_d2));
  if v_err !~ 'asset_drafts_applied_create_uniq' then
    raise exception 'FAIL: ควรถูกปฏิเสธด้วย unique index ของการอ้างทรัพย์: %', v_err;
  end if;

  -- ร่างแก้ไขหลายใบของทรัพย์เดียวกัน **ต้องยังอนุมัติได้ต่อ** (unique เฉพาะ kind=create)
  perform pg_temp.ilogin('i_staff');
  insert into sri_os.asset_drafts(kind, owner_id, target_asset_id, patch)
  values ('update', v_own, '00000000-0000-0000-0000-0000000fa001', '{"location": "แก้ครั้งที่สอง"}'::jsonb)
  returning id into v_d1;
  insert into sri_os.asset_drafts(kind, owner_id, target_asset_id, patch)
  values ('update', v_own, '00000000-0000-0000-0000-0000000fa001', '{"location": "แก้ครั้งที่สาม"}'::jsonb)
  returning id into v_d2;
  perform pg_temp.ilogin('i_mgr');
  perform sri_os.fn_apply_asset_draft(v_d1);
  perform sri_os.fn_apply_asset_draft(v_d2);
  if (select location from sri_os.assets where id = '00000000-0000-0000-0000-0000000fa001') <> 'แก้ครั้งที่สาม' then
    raise exception 'FAIL: ร่างแก้ไขใบที่สองไม่มีผล';
  end if;

  raise notice 'ok I6 · กฎกัน **ผลลัพธ์** ไม่ใช่เส้นทาง: อนุมัติตรงๆ ที่ผลถูกครบผ่านได้ · ทรัพย์ชิ้นเดียวถูกอ้างซ้ำไม่ได้ · ร่างแก้ไขหลายใบของทรัพย์เดียวกันยังอนุมัติได้';
end $$;

-- ============================================================
-- I7 · assets.created_at / id แก้ไม่ได้ — เงื่อนไขที่รองรับข้อพิสูจน์ของ I4
--      ถ้าแก้ได้ ผู้อนุมัติจะเลื่อน created_at ของทรัพย์เก่ามาเป็น now() แล้วหลุด
-- ============================================================
do $$
declare v_err text;
begin
  perform pg_temp.ilogin('i_mgmt');
  v_err := pg_temp.ifail('เลื่อน created_at ของทรัพย์',
    'update sri_os.assets set created_at = now() where id = ''00000000-0000-0000-0000-0000000fa002''');
  if v_err !~ 'created_at แก้ไม่ได้' then
    raise exception 'FAIL: เหตุผลการปฏิเสธไม่ตรง: %', v_err;
  end if;
  perform pg_temp.ifail('ย้าย id ของทรัพย์',
    'update sri_os.assets set id = gen_random_uuid() where id = ''00000000-0000-0000-0000-0000000fa002''');

  -- ชั้น trigger ต้องกันแม้ RLS ไม่มีผล (superuser)
  reset role;
  perform pg_temp.ifail('เลื่อน created_at (superuser)',
    'update sri_os.assets set created_at = now() where id = ''00000000-0000-0000-0000-0000000fa002''');
  set local role authenticated;

  -- แต่แก้ช่องอื่นของทรัพย์ต้องยังทำได้ (กันแน่นเกินก็คือพัง)
  perform pg_temp.ilogin('i_mgmt');
  perform pg_temp.irows('แก้ที่ตั้งของทรัพย์',
    'update sri_os.assets set location = ''ระยอง (แก้แล้ว)'' where id = ''00000000-0000-0000-0000-0000000fa002''', 1);

  raise notice 'ok I7 · created_at/id ของทรัพย์แก้ไม่ได้ทั้งชั้น RLS และ superuser · ช่องอื่นยังแก้ได้';
end $$;

-- ============================================================
-- I8 · audit_log ปลอมไม่ได้ — ข้อพิสูจน์ชั้นที่สองของ I4 ยืนอยู่บนข้อนี้
-- ============================================================
do $$
begin
  perform pg_temp.ilogin('i_super');
  -- ไม่มี policy INSERT → RLS ปฏิเสธ (0 แถวไม่เกิดกับ insert · เป็น error)
  perform pg_temp.ifail('ยัดร่องรอยการสร้างทรัพย์ปลอมเข้า audit_log', format(
    'insert into sri_os.audit_log(table_name, row_id, action, after) values (''assets'', %L, ''insert'', ''{}''::jsonb)',
    '00000000-0000-0000-0000-0000000fa001'));
  -- ไม่มี policy UPDATE/DELETE → RLS ปฏิเสธ **เงียบ** (0 แถว ไม่ใช่ error) · ต้องนับแถว
  perform pg_temp.irows('แก้ร่องรอยใน audit_log (ชั้น RLS)',
    'update sri_os.audit_log set action = ''insert'' where table_name = ''assets''', 0);
  perform pg_temp.irows('ลบร่องรอยใน audit_log (ชั้น RLS)',
    'delete from sri_os.audit_log where table_name = ''assets''', 0);

  -- และชั้น trigger ต้องกันแม้ RLS ไม่มีผล (superuser / service key ที่ bypassrls)
  reset role;
  perform pg_temp.ifail('แก้ร่องรอยใน audit_log (superuser)',
    'update sri_os.audit_log set action = ''insert'' where table_name = ''assets''');
  perform pg_temp.ifail('ลบร่องรอยใน audit_log (superuser)',
    'delete from sri_os.audit_log where table_name = ''assets''');
  set local role authenticated;

  raise notice 'ok I8 · audit_log เพิ่ม/แก้/ลบด้วยมือไม่ได้ทั้งชั้น RLS และ trigger → ร่องรอย "ทรัพย์เกิดในธุรกรรมนี้" ปลอมไม่ได้';
end $$;

-- ============================================================
-- I9 · ข้อบกพร่องข้อ 3 — void / กลับรายการ แล้วตารางงวดต้องคืนสถานะ
--      **กระทบตัวเลขเงิน**: ถ้าไม่คืน ยอดค้างรับต่ำกว่าจริง
-- ============================================================
reset role;
do $$
declare v_s1 text; v_s2 text; v_s3 text; n int;
begin
  -- ผูกสองงวดกับร่างใบเดียว (จ่ายก้อนเดียวปิดสองงวด) แล้วตั้ง received
  update sri_os.schedules set draft_entry_id = '00000000-0000-0000-0000-0000000fe001'
   where id in ('00000000-0000-0000-0000-0000000fd001', '00000000-0000-0000-0000-0000000fd002');
  update sri_os.schedules set status = 'received'
   where id in ('00000000-0000-0000-0000-0000000fd001', '00000000-0000-0000-0000-0000000fd002');
  select status into v_s1 from sri_os.schedules where id = '00000000-0000-0000-0000-0000000fd001';
  if v_s1 <> 'received' then raise exception 'FAIL: ตั้ง received ไม่ได้ (%) — fixtures ผิด', v_s1; end if;

  -- ---------- void รายการที่ post แล้ว ----------
  update sri_os.transactions set status = 'void' where id = '00000000-0000-0000-0000-0000000ff001';

  select status into v_s1 from sri_os.schedules where id = '00000000-0000-0000-0000-0000000fd001';
  select status into v_s2 from sri_os.schedules where id = '00000000-0000-0000-0000-0000000fd002';
  select status into v_s3 from sri_os.schedules where id = '00000000-0000-0000-0000-0000000fd003';
  -- id01 เลยกำหนด (due_date = วันนี้ - 10) → overdue · id02 ยังไม่ถึง → upcoming
  if v_s1 <> 'overdue' then
    raise exception 'FAIL: void แล้วงวดที่เลยกำหนดยังเป็น % (ยอดค้างรับต่ำกว่าจริง)', v_s1;
  end if;
  if v_s2 <> 'upcoming' then
    raise exception 'FAIL: void แล้วงวดที่ยังไม่ถึงกำหนดเป็น % (ควร upcoming)', v_s2;
  end if;
  if v_s3 <> 'upcoming' then
    raise exception 'FAIL: งวดที่ไม่มีร่างผูกถูกแตะ (%) — ต้องไม่เดาให้', v_s3;
  end if;
  -- การคืนสถานะต้องมีร่องรอย
  select count(*) into n from sri_os.audit_log
   where table_name = 'schedules' and action = 'update'
     and row_id = '00000000-0000-0000-0000-0000000fd001'
     and (before ->> 'status') = 'received' and (after ->> 'status') = 'overdue';
  if n < 1 then raise exception 'FAIL: การคืนสถานะงวดไม่มีร่องรอยใน audit_log'; end if;

  -- ตั้ง received กลับด้วยมือไม่ได้อีก (mirror ยังกันอยู่)
  begin
    update sri_os.schedules set status = 'received'
     where id = '00000000-0000-0000-0000-0000000fd001';
    raise exception 'FAIL: ตั้ง received บนรายการที่ void แล้วได้';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  raise notice 'ok I9a · void รายการ → สองงวดที่ผูกร่างเดียวกันคืนเป็น overdue/upcoming ตามวันครบกำหนด · งวดที่ไม่มีร่างไม่ถูกแตะ · มีร่องรอย';
end $$;

do $$
declare v_s1 text; v_s2 text;
begin
  -- ---------- void แล้ว post ใหม่ ----------
  perform pg_temp.ipost('00000000-0000-0000-0000-0000000ff002', 200000);
  insert into sri_os.draft_entries(id, owner_id, txn_type_code, doc_date, amount, status,
                                   posted_txn_id, created_by, reviewed_by, reviewed_at)
  select '00000000-0000-0000-0000-0000000fe002', o.id, 'inc.other', current_date, 200000,
         'approved', '00000000-0000-0000-0000-0000000ff002',
         pg_temp.iuid('i_staff'), pg_temp.iuid('i_mgmt'), now()
    from sri_os.owners o where o.code = 'SRI_CORP';
  insert into sri_os.cash_confirmations(transaction_id, bank_account_id, expected_amount,
                                        actual_amount, actual_date, confirmed_by, confirmed_at)
  values ('00000000-0000-0000-0000-0000000ff002', '00000000-0000-0000-0000-0000000fb001',
          200000, 200000, current_date, pg_temp.iuid('i_mgmt'), now());

  update sri_os.schedules
     set draft_entry_id = '00000000-0000-0000-0000-0000000fe002', status = 'received'
   where id in ('00000000-0000-0000-0000-0000000fd001', '00000000-0000-0000-0000-0000000fd002');
  select status into v_s1 from sri_os.schedules where id = '00000000-0000-0000-0000-0000000fd001';
  if v_s1 <> 'received' then raise exception 'FAIL: void แล้ว post ใหม่ ตั้ง received ไม่ได้ (%)', v_s1; end if;

  -- ---------- กลับรายการ (reverse) · ต้นฉบับยังเป็น posted ----------
  perform pg_temp.ipost('00000000-0000-0000-0000-0000000ff003', 200000,
                        '00000000-0000-0000-0000-0000000ff002');
  select status into v_s1 from sri_os.schedules where id = '00000000-0000-0000-0000-0000000fd001';
  select status into v_s2 from sri_os.schedules where id = '00000000-0000-0000-0000-0000000fd002';
  if (select status::text from sri_os.transactions where id = '00000000-0000-0000-0000-0000000ff002') <> 'posted' then
    raise exception 'FAIL: fixtures ผิด — ต้นฉบับควรยังเป็น posted เพื่อทดสอบเส้นทาง reverse';
  end if;
  if v_s1 <> 'overdue' or v_s2 <> 'upcoming' then
    raise exception 'FAIL: กลับรายการแล้วงวดยังไม่คืนสถานะ (% · %) — เส้นทาง reverse หลุด', v_s1, v_s2;
  end if;

  -- ---------- กลับรายการที่ลงผิด แล้ว void ทิ้ง → ต้นฉบับมีผลอีกครั้ง ----------
  update sri_os.transactions set status = 'void' where id = '00000000-0000-0000-0000-0000000ff003';
  select status into v_s1 from sri_os.schedules where id = '00000000-0000-0000-0000-0000000fd001';
  select status into v_s2 from sri_os.schedules where id = '00000000-0000-0000-0000-0000000fd002';
  if v_s1 <> 'received' or v_s2 <> 'received' then
    raise exception 'FAIL: void รายการกลับรายการแล้วงวดไม่กลับเป็น received (% · %)', v_s1, v_s2;
  end if;

  raise notice 'ok I9b · void แล้ว post ใหม่ตั้ง received ได้ · กลับรายการ → งวดคืนสถานะ · void รายการกลับรายการ → งวดกลับเป็น received (สูตรเดียว ไม่เดา)';
end $$;

do $$
declare v_s2 text;
begin
  -- ---------- 'waived' เป็นการตัดสินใจเชิงธุรกิจ · ledger ห้ามเขียนทับ ----------
  update sri_os.schedules set status = 'waived' where id = '00000000-0000-0000-0000-0000000fd002';
  perform pg_temp.ipost('00000000-0000-0000-0000-0000000ff004', 200000,
                        '00000000-0000-0000-0000-0000000ff002');
  select status into v_s2 from sri_os.schedules where id = '00000000-0000-0000-0000-0000000fd002';
  if v_s2 <> 'waived' then
    raise exception 'FAIL: การกลับรายการเขียนทับ waived (ได้ %) — ต้องไม่เดาแทนคน', v_s2;
  end if;
  if (select status from sri_os.schedules where id = '00000000-0000-0000-0000-0000000fd001') <> 'overdue' then
    raise exception 'FAIL: งวดที่ไม่ได้ waive ควรคืนเป็น overdue';
  end if;
  raise notice 'ok I9c · waived ไม่ถูก ledger เขียนทับ · งวดอื่นในชุดเดียวกันยังคืนสถานะตามปกติ';
end $$;

-- ============================================================
-- I10 · mirror เดิม: สลับ draft_entry_id ใต้แถว 'received' ต้องถูกตรวจใหม่
--       (เดิมคืนค่าออกก่อนเมื่อ "สถานะไม่เปลี่ยน" → สลับร่างได้เงียบๆ)
-- ============================================================
do $$
declare v_err text;
begin
  -- คืน id01 ให้เป็น received บนร่างที่มีผล (void รายการกลับรายการใบที่สองทิ้ง)
  update sri_os.transactions set status = 'void' where id = '00000000-0000-0000-0000-0000000ff004';
  if (select status from sri_os.schedules where id = '00000000-0000-0000-0000-0000000fd001') <> 'received' then
    raise exception 'FAIL: fixtures ของ I10 ผิด — id01 ควรกลับเป็น received';
  end if;

  -- ร่างใบใหม่ที่ยังรออนุมัติ (ไม่มี posted_txn_id) — สลับเข้ามาใต้แถว received ไม่ได้
  insert into sri_os.draft_entries(id, owner_id, txn_type_code, doc_date, amount, status, created_by)
  select '00000000-0000-0000-0000-0000000fe003', o.id, 'inc.other', current_date, 200000,
         'pending', pg_temp.iuid('i_staff')
    from sri_os.owners o where o.code = 'SRI_CORP';

  v_err := pg_temp.ifail('สลับ draft_entry_id ใต้แถว received',
    'update sri_os.schedules set draft_entry_id = ''00000000-0000-0000-0000-0000000fe003'' where id = ''00000000-0000-0000-0000-0000000fd001''');
  if v_err !~ 'ต้องมีรายการที่อนุมัติเข้า ledger' then
    raise exception 'FAIL: เหตุผลการปฏิเสธไม่ตรง: %', v_err;
  end if;

  -- แก้ช่องอื่นของงวดที่ received ต้องยังทำได้ (เลื่อนงวด/แก้ยอด)
  perform pg_temp.irows('เลื่อนวันครบกำหนดของงวดที่ received',
    'update sri_os.schedules set due_date = due_date - 1 where id = ''00000000-0000-0000-0000-0000000fd001''', 1);

  raise notice 'ok I10 · สลับร่างใต้แถว received ถูกตรวจและปฏิเสธ · เลื่อนงวด/แก้ช่องอื่นยังทำได้';
end $$;

-- ============================================================
-- I11 · ข้อบกพร่องข้อ 4 — ตารางกฎ + ผังบัญชีมี audit จริง **ทั้งสามคำสั่ง**
--       เขียนในฐานะ superuser = เส้นทางของ migration / service key
--       (คือเส้นทางที่เหตุผลเดิมของ allow-list มองข้ามไป)
-- ============================================================
do $$
declare v_id uuid; n int; v_row uuid;
begin
  -- ---------- chart_of_accounts (fn_audit · id uuid) ----------
  insert into sri_os.chart_of_accounts(code, name_th, type)
  values ('9901', 'บัญชีทดสอบร่องรอย', 'expense') returning id into v_id;
  update sri_os.chart_of_accounts set name_th = 'บัญชีทดสอบร่องรอย (แก้)' where id = v_id;
  delete from sri_os.chart_of_accounts where id = v_id;
  select count(*) into n from sri_os.audit_log
   where table_name = 'chart_of_accounts' and row_id = v_id
     and action in ('insert', 'update', 'delete');
  if n <> 3 then
    raise exception 'FAIL: audit ของผังบัญชีไม่ครบสามคำสั่ง (เจอ % แถว) · service key เขียนผังบัญชีได้โดยไม่เหลือร่องรอย', n;
  end if;
  if not exists (select 1 from sri_os.audit_log
                  where table_name = 'chart_of_accounts' and row_id = v_id and action = 'update'
                    and (before ->> 'name_th') = 'บัญชีทดสอบร่องรอย'
                    and (after  ->> 'name_th') = 'บัญชีทดสอบร่องรอย (แก้)') then
    raise exception 'FAIL: audit ของผังบัญชีไม่เก็บ before-after';
  end if;

  -- ---------- asset_classes / asset_categories (fn_audit) ----------
  insert into sri_os.asset_classes(code, name_th) values ('ZZTEST', 'หมวดใหญ่ทดสอบ')
  returning id into v_id;
  insert into sri_os.asset_categories(class_id, code, name_th)
  values (v_id, 'ZZTEST-1', 'หมวดย่อยทดสอบ');
  delete from sri_os.asset_categories where code = 'ZZTEST-1';
  delete from sri_os.asset_classes where id = v_id;
  select count(*) into n from sri_os.audit_log where table_name = 'asset_classes' and row_id = v_id;
  if n <> 2 then raise exception 'FAIL: audit ของ asset_classes ไม่ครบ (%)', n; end if;
  if not exists (select 1 from sri_os.audit_log
                  where table_name = 'asset_categories' and action = 'delete'
                    and (before ->> 'code') = 'ZZTEST-1') then
    raise exception 'FAIL: audit ของ asset_categories ไม่จับขา DELETE';
  end if;

  -- ---------- txn_types (fn_audit_keyed · PK = code) · เส้นทาง sync:rules ----------
  -- คัดลอกแถวจริงแล้วเปลี่ยน code → ไม่ต้องรู้ทุกคอลัมน์/ทุก constraint ของตารางกฎ
  -- (เทสต์ที่ไปรู้โครงตารางกฎเองจะพังทุกครั้งที่ตารางกฎเพิ่มช่อง)
  create temporary table zz_tt as select * from sri_os.txn_types where code = 'inc.other';
  update zz_tt set code = 'zz.audit_probe';
  insert into sri_os.txn_types select * from zz_tt
  on conflict (code) do nothing;
  update sri_os.txn_types set name_th = name_th || ' (แก้คู่บัญชี)'
   where code = 'zz.audit_probe';
  delete from sri_os.txn_types where code = 'zz.audit_probe';
  v_row := sri_os.fn_audit_row_id('txn_types', array['code'],
                                  jsonb_build_object('code', 'zz.audit_probe'));
  select count(*) into n from sri_os.audit_log
   where table_name = 'txn_types' and row_id = v_row;
  if n <> 3 then
    raise exception 'FAIL: audit ของตารางกฎไม่ครบสามคำสั่ง (เจอ %) · row_id ต้องตรงกับ fn_audit_row_id', n;
  end if;

  -- ---------- roles / permissions / role_permissions (fn_audit_keyed) ----------
  insert into sri_os.roles(key, label, rank_order) values ('zz_probe', 'ตำแหน่งทดสอบ', 99);
  insert into sri_os.permissions(key, label) values ('probe.manage', 'สิทธิ์ทดสอบ');
  insert into sri_os.role_permissions(role_key, permission_key) values ('zz_probe', 'probe.manage');
  delete from sri_os.role_permissions where role_key = 'zz_probe';
  delete from sri_os.permissions where key = 'probe.manage';
  delete from sri_os.roles where key = 'zz_probe';

  v_row := sri_os.fn_audit_row_id('role_permissions', array['role_key', 'permission_key'],
             jsonb_build_object('role_key', 'zz_probe', 'permission_key', 'probe.manage'));
  select count(*) into n from sri_os.audit_log where table_name = 'role_permissions' and row_id = v_row;
  if n <> 2 then
    raise exception 'FAIL: audit ของ role_permissions ไม่ครบ (เจอ %) · การแจกสิทธิ์ต้องเห็นร่องรอย', n;
  end if;
  v_row := sri_os.fn_audit_row_id('roles', array['key'], jsonb_build_object('key', 'zz_probe'));
  if (select count(*) from sri_os.audit_log where table_name = 'roles' and row_id = v_row) <> 2 then
    raise exception 'FAIL: audit ของ roles ไม่ครบ';
  end if;
  v_row := sri_os.fn_audit_row_id('permissions', array['key'], jsonb_build_object('key', 'probe.manage'));
  if (select count(*) from sri_os.audit_log where table_name = 'permissions' and row_id = v_row) <> 2 then
    raise exception 'FAIL: audit ของ permissions ไม่ครบ';
  end if;

  raise notice 'ok I11 · ตารางกฎ+ผังบัญชี 7 ตาราง: audit ครบ insert/update/delete · เก็บ before-after · row_id ตรงกับ fn_audit_row_id';
end $$;

-- ============================================================
-- I12 · เคส "ไม่ส่งข้อมูล" ของกฎใหม่ (บทเรียน mace-windu ข้อ 3)
-- ============================================================
set local role authenticated;
do $$
declare v_own uuid; v_cls uuid; v_cat uuid; v_draft uuid;
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;

  perform pg_temp.ilogin('i_mgmt');
  insert into sri_os.asset_drafts(kind, owner_id, name, class_id, category_id, patch)
  values ('create', v_own, 'ร่างสำหรับเคสไม่ส่งข้อมูล', v_cls, v_cat, '{"location":"x"}'::jsonb)
  returning id into v_draft;

  -- อนุมัติแต่ไม่ชี้ทรัพย์
  perform pg_temp.ifail('approved แต่ไม่ส่ง applied_asset_id', format(
    'update sri_os.asset_drafts set status = ''approved'', reviewed_by = %L, reviewed_at = now() where id = %L',
    pg_temp.iuid('i_mgmt'), v_draft));
  -- อนุมัติแต่ไม่ส่ง reviewed_by
  perform pg_temp.ifail('approved แต่ไม่ส่ง reviewed_by', format(
    'update sri_os.asset_drafts set status = ''approved'', applied_asset_id = %L, reviewed_at = now() where id = %L',
    '00000000-0000-0000-0000-0000000fa001', v_draft));
  -- ชี้ทรัพย์ที่ไม่มีอยู่จริง
  perform pg_temp.ifail('ชี้ทรัพย์ที่ไม่มีอยู่จริง', format(
    'update sri_os.asset_drafts set status = ''approved'', applied_asset_id = %L, reviewed_by = %L, reviewed_at = now() where id = %L',
    gen_random_uuid(), pg_temp.iuid('i_mgmt'), v_draft));
  -- ฟังก์ชันที่ไม่ส่งร่าง
  perform pg_temp.ifail('fn_apply_asset_draft(null)', 'select sri_os.fn_apply_asset_draft(null::uuid)');
  -- สูตรสถานะงวดที่ไม่ส่งงวด / ส่งงวดที่ไม่มีจริง → null ไม่ใช่เดาค่า
  reset role;
  if sri_os.fn_schedule_ledger_status(null::uuid) is not null then
    raise exception 'FAIL: fn_schedule_ledger_status(null) ควรคืน null (ไม่มีข้อมูลให้สรุป)';
  end if;
  if sri_os.fn_schedule_ledger_status(gen_random_uuid()) is not null then
    raise exception 'FAIL: fn_schedule_ledger_status(งวดที่ไม่มีจริง) ควรคืน null';
  end if;
  -- งวดที่ไม่มีร่างผูก → null (ห้ามเดา)
  if sri_os.fn_schedule_ledger_status('00000000-0000-0000-0000-0000000fd003') is not null then
    raise exception 'FAIL: งวดที่ไม่มี draft_entry_id ควรคืน null';
  end if;
  set local role authenticated;

  raise notice 'ok I12 · เคสไม่ส่งข้อมูลทุกจุด: ไม่ส่ง applied_asset_id / reviewed_by / ทรัพย์ที่ไม่มีจริง / fn_apply(null) / สูตรสถานะที่ไม่มีข้อมูล = ปฏิเสธหรือคืน null ไม่เดา';
end $$;

-- ============================================================
-- I13 · **เส้นทางที่ถูกต้องต้องยังทำได้** ในฐานะ authenticated จริง
--       (ผ่านชั้น GRANT + RLS ไม่ใช่ superuser) — บทเรียนข้อ 7
-- ============================================================
do $$
declare v_own uuid; v_txn uuid := gen_random_uuid();
begin
  select id into v_own from sri_os.owners where code = 'SRI_CORP';
  perform pg_temp.ilogin('i_mgmt');

  -- post รายการใหม่ (หัวรายการ + บรรทัดในธุรกรรมเดียว)
  perform pg_temp.ipass('Management ลงรายการใหม่', format(
    'insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, cash_date, contact_id, attachments, created_by) values (%L, %L, ''inc.other'', current_date, current_date, %L, array[''หลักฐาน.pdf''], %L)',
    v_txn, v_own, '00000000-0000-0000-0000-0000000f9a01', pg_temp.iuid('i_mgmt')));
  perform pg_temp.ipass('ลงบรรทัดบัญชีสองด้าน', format(
    'insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit) select %L, c.id, case when c.rn = 1 then 500 else 0 end, case when c.rn = 2 then 500 else 0 end from (select id, row_number() over (order by code) rn from sri_os.chart_of_accounts where code not like ''11%%'' order by code limit 2) c',
    v_txn));

  -- void (txn.void = Management มี)
  perform pg_temp.irows('Management void รายการ',
    format('update sri_os.transactions set status = ''void'' where id = %L', v_txn), 1);

  -- ปิดงวด แล้วเปิดกลับ (period.reopen)
  perform pg_temp.ipass('ปิดงวด', format(
    'insert into sri_os.period_closes(owner_id, period, closed_by) values (%L, date_trunc(''month'', current_date - interval ''2 month'')::date, %L)',
    v_own, pg_temp.iuid('i_mgmt')));
  perform pg_temp.irows('เปิดงวดที่ปิดแล้ว', format(
    'delete from sri_os.period_closes where owner_id = %L and period = date_trunc(''month'', current_date - interval ''2 month'')::date',
    v_own), 1);

  -- แก้ค่าตั้งค่า (settings.manage)
  perform pg_temp.ipass('แก้ค่าตั้งค่า',
    'insert into sri_os.settings(key, value) values (''zz_probe_key'', ''{"v":1}''::jsonb) on conflict (key) do update set value = excluded.value');

  raise notice 'ok I13 · post · void · ปิดงวด-เปิดงวด · แก้ค่าตั้งค่า ยังทำได้ครบในฐานะ authenticated';
end $$;

reset role;
do $$
declare n0 int; n1 int;
begin
  -- เส้นทาง reverse ที่ถูกต้อง (ของจริงทำผ่านฟังก์ชันฝั่งแอป) ต้องยังลงได้
  select count(*) into n0 from sri_os.transactions;
  perform pg_temp.ipost('00000000-0000-0000-0000-0000000ff005', 200000);
  perform pg_temp.ipost('00000000-0000-0000-0000-0000000ff006', 200000,
                        '00000000-0000-0000-0000-0000000ff005');
  select count(*) into n1 from sri_os.transactions;
  if n1 <> n0 + 2 then raise exception 'FAIL: ลงรายการ + กลับรายการไม่สำเร็จ (%→%)', n0, n1; end if;
  if (select reverses_id from sri_os.transactions where id = '00000000-0000-0000-0000-0000000ff006')
     <> '00000000-0000-0000-0000-0000000ff005' then
    raise exception 'FAIL: ลิงก์กลับรายการไม่ถูกบันทึก';
  end if;
  raise notice 'ok I13b · ลงรายการแล้วกลับรายการ (reverse) ยังทำได้ · trigger คืนสถานะงวดไม่ขัดขวางรายการที่ไม่มีงวดผูก';
end $$;

rollback;
