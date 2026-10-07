-- ============================================================
-- SRI OS · ตารางสิทธิ์ + fn_can() แทนการฮาร์ดโค้ดชื่อ role ใน RLS
-- อ้างอิง: D-072 (4 ระดับ) · D-073 (สิทธิ์อ่านจากตาราง) · docs/DESIGN_ROLES.md
--
-- ทำอะไร:
--   1. ตาราง roles / permissions / role_permissions
--   2. seed 4 ระดับ (super_admin · management · manager · staff) + 8 สิทธิ์ + การจับคู่
--      **cash.confirm Manager ไม่มี** = การแยกหน้าที่ (คีย์เอง-อนุมัติเองได้
--      แต่ขั้นที่ทำให้เงินเข้าบัญชีจริงต้องมีคนที่สอง)
--   3. fn_can(permission_key) · security definer · search_path = '' · stable
--   4. app_users.role: CHECK 3 ค่า → FK roles(key) · 'user' → 'staff'
--   5. แปลง policy ที่เรียก fn_is_management() ทั้ง 12 จุด → fn_can('<permission>')
--      fn_is_management() เก็บไว้เป็น wrapper (DEPRECATED) ของ fn_can('owner.view_all')
--   6. ปิดช่องที่เจอระหว่างทำ: user_owner_access และ period_closes ยังไม่มี RLS
--      = ใครก็เพิ่มสิทธิ์ดู owner ให้ตัวเอง / ลบแถวปิดงวดเพื่อเปิดงวดได้
--
-- สิ่งที่ migration นี้ **ไม่** ทำ และห้ามทำ:
--   ไม่มี permission ที่ปิดกฎเงิน (invariant.skip · evidence.waive · delete.posted)
--   กฎ 6 ข้อที่บังคับด้วย trigger ใช้กับทุกคนเท่ากัน **รวม super_admin**
--   มี CHECK บนตาราง permissions กันการเผลอเพิ่มคีย์แบบนั้นผ่านหน้า Settings
--
-- ย้อนกลับ (rollback):
--   -- 1. คืน policy ชุดเดิม: รัน supabase/migrations/20260917000004_rls.sql ซ้ำ
--   --    (ไฟล์นั้น drop policy if exists ก่อน create จึงรันซ้ำได้ และจะคืน
--   --     fn_is_management() เวอร์ชันที่เช็ค role = 'management' กลับมาเอง)
--   -- 2. alter table sri_os.app_users drop constraint app_users_role_fkey;
--   --    update sri_os.app_users set role = 'user' where role = 'staff';
--   --    alter table sri_os.app_users alter column role set default 'user';
--   --    alter table sri_os.app_users add constraint app_users_role_check
--   --      check (role in ('management','manager','user'));
--   -- 3. alter table sri_os.period_closes disable row level security;
--   --    alter table sri_os.user_owner_access disable row level security;
--   -- 4. drop function sri_os.fn_can(text);
--   -- 5. drop table sri_os.role_permissions, sri_os.permissions, sri_os.roles;
--   -- หมายเหตุ: fn_period_locked() ที่ migration นี้ทำเป็น security definer
--   --   **ไม่ต้องย้อน** — ย้อนแล้วการล็อกงวดจะอ่าน period_closes ไม่เห็นถ้า RLS ยังเปิด
--
-- idempotent: create table if not exists · insert ... on conflict ·
--   create or replace function · drop policy if exists ก่อน create policy
-- ============================================================

set search_path = sri_os, public;

-- ------------------------------------------------------------
-- 1 · ตาราง
-- ------------------------------------------------------------
create table if not exists roles (
  key        text primary key,
  label      text not null,
  rank_order int  not null unique,
  created_at timestamptz not null default now()
);
comment on table roles is
  'ระดับสิทธิ์ (D-072) · rank_order น้อย = สูงกว่า · เพิ่มระดับใหม่ = เพิ่มแถว ไม่ต้องแก้ RLS';

create table if not exists permissions (
  key        text primary key,
  label      text not null,
  note       text,
  created_at timestamptz not null default now()
);
comment on table permissions is
  'สิทธิ์ว่า "ใครกดอะไรได้" เท่านั้น (D-073) · ห้ามมีคีย์ที่ปิดกฎเงิน — บังคับด้วย CHECK ข้างล่าง';

-- กันตาราง permissions กลายเป็นช่องปลดกฎเงินผ่านหน้า Settings
-- กฎ 6 ข้อบังคับที่ trigger และใช้กับทุกคนเท่ากัน ไม่มี role ไหนยกเว้น
alter table permissions drop constraint if exists permissions_no_money_bypass;
alter table permissions add constraint permissions_no_money_bypass check (
      key !~* '(invariant|evidence|balance[d]?|double.?entry|trigger|posted|immutab|audit.?trail)'
  and key !~* '(skip|waive|bypass|override|force|unlock|disable|ignore|exempt)'
  and key !~* '^(delete|purge|hard_delete|truncate)\.'
);
comment on constraint permissions_no_money_bypass on permissions is
  'D-073: สิทธิ์ที่สื่อถึงการข้ามกฎเงินสร้างไม่ได้เลย แม้แต่ super_admin · ตัวอย่างที่ถูกบล็อก: invariant.skip · evidence.waive · delete.posted · ledger.override';

create table if not exists role_permissions (
  role_key       text not null references roles(key) on update cascade on delete cascade,
  permission_key text not null references permissions(key) on update cascade on delete cascade,
  granted_at     timestamptz not null default now(),
  primary key (role_key, permission_key)
);
comment on table role_permissions is
  'การจับคู่ระดับ → สิทธิ์ · ย้ายสิทธิ์ข้ามระดับ = แก้แถวนี้ ไม่ต้องเขียน migration';

-- ------------------------------------------------------------
-- 2 · seed ระดับสิทธิ์ (D-072)
-- ------------------------------------------------------------
insert into roles (key, label, rank_order) values
  ('super_admin', 'ผู้ดูแลระบบสูงสุด', 10),
  ('management',  'ผู้บริหาร',          20),
  ('manager',     'ผู้จัดการ',          30),
  ('staff',       'พนักงาน',           40)
on conflict (key) do update
  set label = excluded.label, rank_order = excluded.rank_order;

-- ------------------------------------------------------------
-- 3 · seed สิทธิ์
-- ------------------------------------------------------------
insert into permissions (key, label, note) values
  ('txn.create',      'สร้างรายการ',
   'คีย์ร่างรายการได้ในขอบเขต owner ที่ตัวเองเห็น · ทุกระดับมี'),
  ('ledger.approve',  'อนุมัติเข้า Ledger',
   'รับรองว่ารายการถูก · P&L และลูกหนี้/เจ้าหนี้ขยับ · Manager ขึ้นไป (D-072 ข้อ 2)'),
  ('cash.confirm',    'ยืนยันรับ-จ่ายเงินจริง',
   'รับรองว่าเงินเคลื่อนจริง · CF และยอดธนาคารขยับ · **Manager ไม่มี** เพื่อให้ขั้นที่แตะเงินจริงมีคนที่สองเสมอ'),
  ('txn.void',        'กลับรายการ (reverse)',
   'ไม่ใช่สิทธิ์ลบ — รายการที่ post แล้วลบไม่ได้ทุกกรณี บังคับที่ DB trigger · แก้ด้วย reverse + ลงใหม่'),
  ('period.reopen',   'เปิดงวดที่ปิดแล้ว',
   'ลบแถว period_closes · Corporate ยังล็อกย้อนหลังด้วย trigger แยกอีกชั้น'),
  ('settings.manage', 'ตั้งค่าระบบ',
   'ผังบัญชี · ตารางกฎ · owners · contacts · settings'),
  ('users.manage',    'จัดการผู้ใช้และสิทธิ์',
   'สร้าง/ปิดผู้ใช้ · ย้ายระดับ · ติ๊ก role_permissions · มอบสิทธิ์เห็น owner'),
  ('owner.view_all',  'เห็นข้อมูลทุก Entity',
   'ข้ามตาราง user_owner_access · รวมถึงอ่าน audit log')
on conflict (key) do update
  set label = excluded.label, note = excluded.note;

-- ------------------------------------------------------------
-- 4 · การจับคู่ตั้งต้น — แก้ได้จากหน้า Settings ภายหลัง
--     on conflict do nothing = รัน migration ซ้ำไม่ลบของที่ลูกพี่ปรับไว้
-- ------------------------------------------------------------
insert into role_permissions (role_key, permission_key)
select r.key, p.key
  from (values
    -- permission        super_admin  management  manager  staff
    ('txn.create',       true,  true,  true,  true),
    ('ledger.approve',   true,  true,  true,  false),
    ('cash.confirm',     true,  true,  false, false),
    ('txn.void',         true,  true,  false, false),
    ('period.reopen',    true,  true,  false, false),
    ('settings.manage',  true,  true,  false, false),
    ('users.manage',     true,  false, false, false),
    ('owner.view_all',   true,  true,  false, false)
  ) as p(key, super_admin, management, manager, staff)
  cross join lateral (values
    ('super_admin', p.super_admin),
    ('management',  p.management),
    ('manager',     p.manager),
    ('staff',       p.staff)
  ) as r(key, allowed)
 where r.allowed
on conflict (role_key, permission_key) do nothing;

-- ------------------------------------------------------------
-- 5 · fn_can() — แหล่งความจริงเดียวของ "ใครกดอะไรได้"
--     ผู้ใช้ที่ is_active = false หรือไม่มีแถวใน app_users → false ทุกสิทธิ์ (ไม่ error)
-- ------------------------------------------------------------
create or replace function fn_can(p_permission text) returns boolean
language sql stable security definer set search_path = '' as $fn$
  select exists (
    select 1
      from sri_os.app_users u
      join sri_os.role_permissions rp on rp.role_key = u.role
     where u.id = auth.uid()
       and u.is_active
       and rp.permission_key = p_permission
  );
$fn$;
comment on function fn_can(text) is
  'D-073: สิทธิ์อ่านจากตาราง ไม่ hard-code ชื่อ role · คืน false เมื่อไม่ล็อกอิน / ไม่มีแถว / is_active=false · ไม่ใช้ตัดสินกฎเงิน (กฎเงินบังคับที่ trigger ใช้กับทุกคน)';

-- DEPRECATED — เก็บไว้ไม่ให้ของเก่าพัง · โค้ดใหม่ให้เรียก fn_can() ตรงๆ
create or replace function fn_is_management() returns boolean
language sql stable set search_path = '' as $fn$
  select sri_os.fn_can('owner.view_all');
$fn$;
comment on function fn_is_management() is
  'DEPRECATED (D-073) · wrapper ของ fn_can(''owner.view_all'') · ห้ามใช้ใน policy ใหม่ เพราะชื่อบอกระดับ ไม่ได้บอกสิทธิ์';

-- ------------------------------------------------------------
-- 6 · app_users.role → FK roles(key)
--     เพิ่มระดับใหม่ภายหลังจะไม่ต้องแก้ CHECK อีก
--     ยืนยันแล้วว่าตารางมี 0 แถว แต่เขียนให้ย้าย 'user' → 'staff' เผื่อไว้
-- ------------------------------------------------------------
do $$
declare c text;
begin
  for c in
    select con.conname
      from pg_constraint con
      join pg_class cl     on cl.oid = con.conrelid
      join pg_namespace ns on ns.oid = cl.relnamespace
     where ns.nspname = 'sri_os' and cl.relname = 'app_users'
       and con.contype = 'c'
       and pg_get_constraintdef(con.oid) ilike '%role%'
  loop
    execute format('alter table sri_os.app_users drop constraint %I', c);
  end loop;
end $$;

update app_users set role = 'staff' where role = 'user';
alter table app_users alter column role set default 'staff';
alter table app_users drop constraint if exists app_users_role_fkey;
alter table app_users
  add constraint app_users_role_fkey foreign key (role)
  references roles(key) on update cascade;
comment on column app_users.role is
  'FK sri_os.roles(key) · สิทธิ์จริงอยู่ที่ role_permissions ไม่ได้ผูกกับชื่อนี้ในโค้ด';

-- ============================================================
-- 7 · แปลง policy ทั้ง 12 จุดจาก fn_is_management() → fn_can('<permission>')
--     เลือก permission ตามความหมายของแต่ละตาราง ไม่ใช้ตัวเดียวหมด
-- ============================================================

-- (1) ใครเห็น owner ไหน — "เห็นทุก Entity" คือสิทธิ์ตรงตัว
create or replace function fn_can_see_owner(p_owner uuid) returns boolean
language sql stable security definer set search_path = '' as $fn$
  select sri_os.fn_can('owner.view_all')
      or exists (
           select 1 from sri_os.user_owner_access
            where user_id = auth.uid() and owner_id = p_owner
         );
$fn$;

-- (2) ตารางอ้างอิง (owners · ผังบัญชี · ตารางกฎ · contacts) = ข้อมูลตั้งค่า
do $$
declare t text;
begin
  foreach t in array array['owners', 'chart_of_accounts', 'txn_types', 'contacts'] loop
    execute format('drop policy if exists %I_write on %I', t, t);
    execute format('create policy %I_write on %I for all to authenticated
                      using (fn_can(''settings.manage''))
                      with check (fn_can(''settings.manage''))', t, t);
  end loop;
end $$;

-- (3) contacts: ทุกคนสร้างได้ (ต้องสร้างจากในฟอร์มได้) · แก้ได้ถ้าเป็นของตัวเอง
drop policy if exists contacts_write on contacts;
drop policy if exists contacts_update on contacts;
create policy contacts_update on contacts
  for update to authenticated
  using (fn_can('settings.manage') or created_by = auth.uid())
  with check (fn_can('settings.manage') or created_by = auth.uid());

-- (4) คีย์ร่างได้ = txn.create (เดิมไม่เช็คสิทธิ์เลย ดูแค่ขอบเขต owner)
drop policy if exists draft_insert on draft_entries;
create policy draft_insert on draft_entries
  for insert to authenticated
  with check (fn_can('txn.create') and fn_can_see_owner(owner_id) and created_by = auth.uid());

-- (5) อนุมัติ/ปฏิเสธร่าง = ledger.approve (Manager ทำได้แล้วตาม D-072)
drop policy if exists draft_review on draft_entries;
create policy draft_review on draft_entries
  for update to authenticated
  using (fn_can('ledger.approve'))
  with check (fn_can('ledger.approve'));

-- (6) post เข้า ledger = ledger.approve
drop policy if exists txn_insert on transactions;
create policy txn_insert on transactions
  for insert to authenticated
  with check (fn_can('ledger.approve') and fn_can_see_owner(owner_id));

-- (7) แก้รายการที่ post แล้ว = txn.void (ทำได้แค่ reverse ลบไม่ได้ บังคับที่ trigger)
drop policy if exists txn_update on transactions;
create policy txn_update on transactions
  for update to authenticated
  using (fn_can('txn.void')) with check (fn_can('txn.void'));

-- (8) บรรทัดบัญชี = ledger.approve (เขียนพร้อม post)
drop policy if exists lines_write on transaction_lines;
create policy lines_write on transaction_lines
  for all to authenticated
  using (fn_can('ledger.approve')) with check (fn_can('ledger.approve'));

-- (9) audit log = คนที่เห็นข้อมูลทั้งบ้าน · ไม่มีใครแก้ได้
drop policy if exists audit_read on audit_log;
create policy audit_read on audit_log
  for select to authenticated using (fn_can('owner.view_all'));

-- (10) รายชื่อผู้ใช้: อ่าน = ตัวเอง / คนจัดการผู้ใช้ / คนที่เห็นทั้งบ้าน
--      D-072 ให้ Management ดูแลผู้ใช้ แต่ตารางสิทธิ์ให้ users.manage แก่ super_admin
--      จึงแยก อ่านได้ถึง Management · เขียนเฉพาะ users.manage
drop policy if exists users_read on app_users;
create policy users_read on app_users
  for select to authenticated
  using (id = auth.uid() or fn_can('users.manage') or fn_can('owner.view_all'));

-- (11) สร้าง/ปิดผู้ใช้ · ย้ายระดับ = users.manage
drop policy if exists users_write on app_users;
create policy users_write on app_users
  for all to authenticated
  using (fn_can('users.manage')) with check (fn_can('users.manage'));

-- (12) settings = settings.manage
drop policy if exists settings_write on settings;
create policy settings_write on settings
  for all to authenticated
  using (fn_can('settings.manage')) with check (fn_can('settings.manage'));

-- ------------------------------------------------------------
-- 8 · ตารางสิทธิ์เอง: ทุกคนอ่านได้ (UI ต้องรู้ว่าปุ่มไหนกดได้) แก้ได้เฉพาะ users.manage
-- ------------------------------------------------------------
alter table roles            enable row level security;
alter table permissions      enable row level security;
alter table role_permissions enable row level security;

do $$
declare t text;
begin
  foreach t in array array['roles', 'permissions', 'role_permissions'] loop
    execute format('drop policy if exists %I_read on %I', t, t);
    execute format('create policy %I_read on %I for select to authenticated using (true)', t, t);
    execute format('drop policy if exists %I_write on %I', t, t);
    execute format('create policy %I_write on %I for all to authenticated
                      using (fn_can(''users.manage''))
                      with check (fn_can(''users.manage''))', t, t);
  end loop;
end $$;

-- ------------------------------------------------------------
-- 9 · cash.confirm ที่ DB — เดิม cash_confirmations เปิด RLS แต่มีแต่ policy อ่าน
--     แปลว่าเขียนไม่ได้เลย (ฟีเจอร์ยืนยันเงินทำงานไม่ได้) · ใส่ policy เขียนให้ตรง D-072
-- ------------------------------------------------------------
drop policy if exists confirmations_write on cash_confirmations;
create policy confirmations_write on cash_confirmations
  for insert to authenticated
  with check (
    fn_can('cash.confirm')
    and exists (
      select 1 from bank_accounts b
       where b.id = bank_account_id and fn_can_see_owner(b.owner_id)
    )
  );

drop policy if exists confirmations_update on cash_confirmations;
create policy confirmations_update on cash_confirmations
  for update to authenticated
  using (fn_can('cash.confirm')) with check (fn_can('cash.confirm'));

-- ------------------------------------------------------------
-- 10 · ปิดช่องที่เจอระหว่างทำ — สองตารางนี้ยังไม่เคยเปิด RLS
-- ------------------------------------------------------------

-- user_owner_access: ถ้าไม่เปิด ใครก็ insert สิทธิ์ดู owner ให้ตัวเองได้
-- fn_can_see_owner() เป็น security definer จึงยังอ่านตารางนี้ได้ครบเหมือนเดิม
alter table user_owner_access enable row level security;
drop policy if exists owner_access_read on user_owner_access;
create policy owner_access_read on user_owner_access
  for select to authenticated
  using (user_id = auth.uid() or fn_can('users.manage') or fn_can('owner.view_all'));
drop policy if exists owner_access_write on user_owner_access;
create policy owner_access_write on user_owner_access
  for all to authenticated
  using (fn_can('users.manage')) with check (fn_can('users.manage'));

-- period_closes: ถ้าไม่เปิด ใครก็ลบแถวปิดงวด = เปิดงวดเองได้โดยไม่ต้องมีสิทธิ์
alter table period_closes enable row level security;
drop policy if exists period_closes_read on period_closes;
create policy period_closes_read on period_closes
  for select to authenticated using (fn_can_see_owner(owner_id));
drop policy if exists period_closes_insert on period_closes;
create policy period_closes_insert on period_closes
  for insert to authenticated
  with check (fn_can('settings.manage') and fn_can_see_owner(owner_id));
drop policy if exists period_closes_reopen on period_closes;
create policy period_closes_reopen on period_closes
  for delete to authenticated using (fn_can('period.reopen'));

-- **สำคัญ**: fn_period_locked() เดิมเป็น security invoker และอ่าน period_closes
-- พอเปิด RLS บนตารางนั้น trigger จะมองไม่เห็นแถวที่ผู้ใช้อ่านไม่ได้ = การล็อกงวดหลุดเงียบๆ
-- จึงทำเป็น security definer · ตัวกฎไม่เปลี่ยน (Corporate ล็อกถาวรเหมือนเดิม)
create or replace function fn_period_locked() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_policy sri_os.owner_policy;
begin
  if exists (
    select 1 from sri_os.period_closes
     where owner_id = new.owner_id
       and period = date_trunc('month', new.doc_date)::date
  ) then
    select policy into v_policy from sri_os.owners where id = new.owner_id;
    if v_policy = 'corporate_strict' then
      raise exception 'งวด % ปิดแล้ว ลงรายการย้อนหลังไม่ได้ ให้ปรับปรุงในงวดปัจจุบัน',
        to_char(new.doc_date, 'MM/YYYY');
    end if;
  end if;
  return new;
end $fn$;
