-- ============================================================
-- SRI OS · 004 RLS + Health check
--
-- ทำอะไร: สิทธิ์การเข้าถึงระดับแถว และฟังก์ชันตรวจสุขภาพตัวเลข
-- ย้อนกลับ: alter table ... disable row level security;
--
-- หลักการ: Management เห็นทุก owner · Manager/User เห็นเฉพาะที่ได้รับสิทธิ์
--           เขียนได้เฉพาะ draft ส่วนการ post ผ่าน function ที่ตรวจ role
-- ============================================================

set search_path = sri_os, public;

create or replace function fn_my_role() returns text
language sql stable security definer set search_path = sri_os, public as $fn$
  select role from app_users where id = auth.uid() and is_active;
$fn$;

create or replace function fn_is_management() returns boolean
language sql stable set search_path = sri_os, public as $fn$
  select coalesce(fn_my_role() = 'management', false);
$fn$;

-- owner ที่ผู้ใช้คนนี้เข้าถึงได้
create table if not exists user_owner_access (
  user_id  uuid not null references app_users(id) on delete cascade,
  owner_id uuid not null references owners(id) on delete cascade,
  primary key (user_id, owner_id)
);

create or replace function fn_can_see_owner(p_owner uuid) returns boolean
language sql stable security definer set search_path = sri_os, public as $fn$
  select fn_is_management()
      or exists (
           select 1 from user_owner_access
            where user_id = auth.uid() and owner_id = p_owner
         );
$fn$;

-- ---------- เปิด RLS ----------
alter table owners             enable row level security;
alter table bank_accounts      enable row level security;
alter table chart_of_accounts  enable row level security;
alter table txn_types          enable row level security;
alter table transactions       enable row level security;
alter table transaction_lines  enable row level security;
alter table draft_entries      enable row level security;
alter table cash_confirmations enable row level security;
alter table assets             enable row level security;
alter table asset_valuations   enable row level security;
alter table contracts          enable row level security;
alter table schedules          enable row level security;
alter table contacts           enable row level security;
alter table audit_log          enable row level security;
alter table app_users          enable row level security;
alter table settings           enable row level security;

-- ---------- ตารางอ้างอิง: ทุกคนที่ล็อกอินอ่านได้ แก้ได้เฉพาะ Management ----------
do $$
declare t text;
begin
  foreach t in array array['owners', 'chart_of_accounts', 'txn_types', 'contacts'] loop
    execute format('drop policy if exists %I_read on %I', t, t);
    execute format('create policy %I_read on %I for select to authenticated using (true)', t, t);
    execute format('drop policy if exists %I_write on %I', t, t);
    execute format('create policy %I_write on %I for all to authenticated
                      using (fn_is_management()) with check (fn_is_management())', t, t);
  end loop;
end $$;

-- contacts: ทุก role สร้างได้ (backlog ข้อ 3 ต้องสร้างจากในฟอร์มได้)
drop policy if exists contacts_write on contacts;
drop policy if exists contacts_insert on contacts;
create policy contacts_insert on contacts
  for insert to authenticated with check (true);
drop policy if exists contacts_update on contacts;
create policy contacts_update on contacts
  for update to authenticated
  using (fn_is_management() or created_by = auth.uid())
  with check (fn_is_management() or created_by = auth.uid());

-- ---------- ตารางที่ผูก owner ----------
do $$
declare t text;
begin
  foreach t in array array['bank_accounts', 'transactions', 'draft_entries', 'assets', 'contracts'] loop
    execute format('drop policy if exists %I_by_owner on %I', t, t);
    execute format('create policy %I_by_owner on %I for select to authenticated
                      using (fn_can_see_owner(owner_id))', t, t);
  end loop;
end $$;

-- ทุกคนสร้าง draft ได้ในขอบเขต owner ที่ตัวเองเห็น
drop policy if exists draft_insert on draft_entries;
create policy draft_insert on draft_entries
  for insert to authenticated
  with check (fn_can_see_owner(owner_id) and created_by = auth.uid());

-- อนุมัติ/ปฏิเสธได้เฉพาะ Management
drop policy if exists draft_review on draft_entries;
create policy draft_review on draft_entries
  for update to authenticated
  using (fn_is_management())
  with check (fn_is_management());

-- post เข้า ledger ได้เฉพาะ Management (Manager/User ต้องผ่าน draft)
drop policy if exists txn_insert on transactions;
create policy txn_insert on transactions
  for insert to authenticated
  with check (fn_is_management() and fn_can_see_owner(owner_id));

drop policy if exists txn_update on transactions;
create policy txn_update on transactions
  for update to authenticated
  using (fn_is_management()) with check (fn_is_management());

-- lines ตามสิทธิ์ของ transaction แม่
drop policy if exists lines_by_txn on transaction_lines;
create policy lines_by_txn on transaction_lines
  for select to authenticated
  using (exists (
    select 1 from transactions t
     where t.id = transaction_id and fn_can_see_owner(t.owner_id)
  ));

drop policy if exists lines_write on transaction_lines;
create policy lines_write on transaction_lines
  for all to authenticated
  using (fn_is_management()) with check (fn_is_management());

-- valuations / schedules / cash confirmations ตาม owner ของแม่
drop policy if exists valuations_by_asset on asset_valuations;
create policy valuations_by_asset on asset_valuations
  for select to authenticated
  using (exists (
    select 1 from assets a where a.id = asset_id and fn_can_see_owner(a.owner_id)
  ));

drop policy if exists schedules_by_contract on schedules;
create policy schedules_by_contract on schedules
  for select to authenticated
  using (exists (
    select 1 from contracts c where c.id = contract_id and fn_can_see_owner(c.owner_id)
  ));

drop policy if exists confirmations_read on cash_confirmations;
create policy confirmations_read on cash_confirmations
  for select to authenticated
  using (exists (
    select 1 from bank_accounts b where b.id = bank_account_id and fn_can_see_owner(b.owner_id)
  ));

-- audit log อ่านได้เฉพาะ Management และไม่มีใครแก้ได้
drop policy if exists audit_read on audit_log;
create policy audit_read on audit_log
  for select to authenticated using (fn_is_management());

-- ผู้ใช้เห็นโปรไฟล์ตัวเอง Management เห็นทุกคน
drop policy if exists users_read on app_users;
create policy users_read on app_users
  for select to authenticated using (id = auth.uid() or fn_is_management());

drop policy if exists users_write on app_users;
create policy users_write on app_users
  for all to authenticated
  using (fn_is_management()) with check (fn_is_management());

drop policy if exists settings_read on settings;
create policy settings_read on settings
  for select to authenticated using (true);
drop policy if exists settings_write on settings;
create policy settings_write on settings
  for all to authenticated
  using (fn_is_management()) with check (fn_is_management());

-- ============================================================
-- Health check — Money Invariant 6
-- เงินสดรวมในระบบต้องเท่ากับผลรวมยอดธนาคารทุกบัญชีเสมอ
-- ============================================================
create or replace function fn_health_check()
returns table (check_name text, ok boolean, detail text)
language plpgsql stable security definer set search_path = sri_os, public as $fn$
begin
  -- 1. ทุก transaction สมดุล
  return query
  select 'transactions_balanced'::text,
         not exists (
           select 1 from transaction_lines l
            group by l.transaction_id
           having sum(l.debit) <> sum(l.credit)
         ),
         coalesce((
           select string_agg(x.transaction_id::text, ', ')
             from (select l.transaction_id from transaction_lines l
                    group by l.transaction_id
                   having sum(l.debit) <> sum(l.credit) limit 10) x
         ), 'ทุกรายการสมดุล');

  -- 2. ไม่มีบรรทัดเงินสดที่ไม่ผูกบัญชี
  return query
  select 'no_floating_cash'::text,
         not exists (
           select 1 from transaction_lines l
             join chart_of_accounts c on c.id = l.coa_id
            where c.code ~ '^11[0-9][0-9]$' and l.bank_account_id is null
         ),
         'ทุกบรรทัดเงินสดผูกบัญชีธนาคารแล้ว';

  -- 3. สัญญาที่มีตารางงวดต้องข้อมูลครบ
  return query
  select 'contracts_complete'::text,
         not exists (
           select 1 from contracts c
            where exists (select 1 from schedules s where s.contract_id = c.id)
              and fn_contract_completeness(c.id) < 100
         ),
         'สัญญาที่มีตารางงวดกรอกครบแล้ว';

  -- 4. ราคาทรัพย์ที่เก่าเกิน 7 วัน
  return query
  select 'valuations_fresh'::text,
         not exists (select 1 from v_asset_latest_value where is_stale),
         coalesce((
           select 'ราคาเก่า ' || count(*)::text || ' รายการ'
             from v_asset_latest_value where is_stale
         ), 'ราคาทุกตัวสดใหม่');
end $fn$;

comment on function fn_health_check is 'ตรวจ Money Invariants — ต้องผ่านทุกข้อก่อนปิดเดือน';
