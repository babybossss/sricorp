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
--   6. **ลบ policy เก่าทุกตัวบนตารางที่ไฟล์นี้ดูแล** ก่อนปล่อยของใหม่
--      RLS policy ของ Postgres เป็น permissive และ **OR กัน** — ถ้าเหลือของเก่าที่กว้างกว่าไว้
--      สิทธิ์ใหม่ที่แคบกว่าจะไม่มีผลอะไรเลย (เงียบๆ)
--      บน project จริงมี policy ที่ **ไม่อยู่ใน migration ไฟล์ไหนเลย** (ใส่มือไว้):
--        user_owner_access · access_manage      ← ตัวที่อันตรายที่สุด
--        period_closes      · period_write · period_read
--        cash_confirmations · confirmations_write
--        contact_links      · contact_links_all
--      `access_manage` กั้นด้วย fn_is_management() ซึ่งตอนนี้ = fn_can('owner.view_all')
--      ที่ Management มี · ถ้าไม่ลบ Management จะยังแจกสิทธิ์ดูข้อมูลทุก Entity ให้ใครก็ได้
--      แม้ดีไซน์ใหม่จะย้ายไปเป็น users.manage (super_admin เท่านั้น) แล้ว
--      ท้ายไฟล์จึงมี sweep: ลบทุก policy บนตารางที่ไฟล์นี้ดูแลซึ่งไม่อยู่ในรายการ
--      สุดท้ายที่ประกาศไว้ → ชื่อที่ยังไม่รู้จักก็ไม่หลุดรอด และไฟล์นี้เป็นแหล่งความจริงเดียว
--   7. ชั้น **การมองเห็น** (ลูกพี่สั่ง 07/10): portfolio.view_all · asset.view_assigned ·
--      ledger.read · draft.read_own · Manager เห็นเฉพาะทรัพย์ที่ตัวเองบริหาร
--      Staff อ่าน ledger ไม่ได้เลย แต่ยังอ่านข้อมูลอ้างอิงเพื่อคีย์ได้
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
--   -- 3. policy ที่เคยใส่มือไว้และไฟล์นี้ลบไป ต้องสร้างคืนเองถ้าต้องการของเดิม
--   --    (ชื่อเดิม: access_manage · period_write · period_read · confirmations_write ·
--   --     contact_links_all — ทั้งหมดกั้นด้วย fn_is_management())
--   --    ของที่ไฟล์นี้สร้างแทนให้แล้วชื่อ owner_access_* · period_closes_* ·
--   --    confirmations_write/update · contact_links_* จึงไม่ต้องทำอะไรถ้าไม่ย้อน
--   -- 4. drop function sri_os.fn_can(text);
--   -- 5. drop table sri_os.role_permissions, sri_os.permissions, sri_os.roles;
--   -- หมายเหตุ 1: RLS บนทุกตารางเปิดอยู่ก่อนไฟล์นี้แล้ว **ห้าม disable ตอนย้อน**
--   -- หมายเหตุ 2: fn_period_locked() ที่ไฟล์นี้ทำเป็น security definer **ไม่ต้องย้อน**
--   --   ย้อนแล้วการล็อกงวดจะขึ้นกับสิทธิ์อ่าน period_closes ของคนคีย์ = หลุดได้
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
   'ข้ามตาราง user_owner_access · รวมถึงอ่าน audit log'),
  -- ---- ชั้น "ใครเห็นอะไรได้" (ลูกพี่เพิ่ม 07/10) ----
  ('portfolio.view_all', 'เห็นภาพรวมการลงทุนทั้งพอร์ต',
   'NAV · งบรวมข้ามทรัพย์/ข้ามผู้ถือ · **Manager ไม่มี** → เห็นได้แค่ทรัพย์ที่ตัวเองบริหาร'),
  ('asset.view_assigned', 'เห็นทรัพย์ที่ตัวเองถูกมอบหมายให้ดูแล',
   'ขอบเขต = assets.manager_user_id = ตัวเอง · ทรัพย์ที่ยังไม่มอบหมายก็ไม่เห็น'),
  ('ledger.read',      'เห็นรายการเงินที่ลงแล้ว',
   '**Staff ไม่มี** = ลงข้อมูลได้แต่อ่าน ledger ไม่ได้ · Manager มีแต่ถูกจำกัดขอบเขตด้วยทรัพย์ที่ดูแล'),
  ('draft.read_own',   'เห็นร่างที่ตัวเองคีย์',
   'ทุกระดับมี · คนที่ไม่มี ledger.read จะเห็นแค่ร่างของตัวเอง')
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
    ('owner.view_all',   true,  true,  false, false),
    -- ชั้นการมองเห็น
    ('portfolio.view_all',  true, true,  false, false),
    ('asset.view_assigned', true, true,  true,  false),
    ('ledger.read',         true, true,  true,  false),
    ('draft.read_own',      true, true,  true,  true)
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
--     **ห้ามใช้ FOR ALL** — policy แบบ ALL เอา USING ไปใช้กับ SELECT ด้วย
--     ของเดิมเป็น ALL/ledger.approve ซึ่งแปลว่า Manager อ่าน transaction_lines ได้ทุกแถว
--     แล้ว `select sum(debit) from transaction_lines` = ยอดรวมทั้งพอร์ต (เทสต์ 9.2 จับได้)
--     การอ่านต้องมาจาก lines_by_txn ที่เดียว (ข้อ 11b)
drop policy if exists lines_write on transaction_lines;
drop policy if exists lines_insert on transaction_lines;
create policy lines_insert on transaction_lines
  for insert to authenticated with check (fn_can('ledger.approve'));
drop policy if exists lines_update on transaction_lines;
create policy lines_update on transaction_lines
  for update to authenticated
  using (fn_can('ledger.approve')) with check (fn_can('ledger.approve'));
drop policy if exists lines_delete on transaction_lines;
create policy lines_delete on transaction_lines
  for delete to authenticated using (fn_can('txn.void'));

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
-- 9 · cash.confirm ที่ DB — ของเดิมบน project จริงคือ confirmations_write (ALL)
--     ที่กั้นด้วย fn_is_management() และไม่อยู่ใน migration ไฟล์ไหน
--     แทนด้วยสิทธิ์ตรงตัว cash.confirm (Manager ไม่มี) + จำกัดขอบเขตบัญชีธนาคาร
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
-- 10 · สองตารางที่เปิด RLS อยู่แล้วแต่ policy ถูกใส่มือ ไม่อยู่ใน migration
--      ย้ายมาเป็นของในไฟล์นี้ และเปลี่ยนจาก fn_is_management() เป็นสิทธิ์ที่ตรงความหมาย
-- ------------------------------------------------------------

-- user_owner_access: การแจกสิทธิ์ "ใครเห็น Entity ไหน" คือการจัดการผู้ใช้
-- เดิม access_manage กั้นด้วย fn_is_management() = Management แจกได้
-- ใหม่ต้อง users.manage (super_admin) · ถ้าไม่ลบของเก่า OR กันแล้วข้อจำกัดนี้ไม่มีผล
-- fn_can_see_owner() เป็น security definer จึงยังอ่านตารางนี้ได้ครบเหมือนเดิม
alter table user_owner_access enable row level security;
drop policy if exists access_manage on user_owner_access;
drop policy if exists owner_access_read on user_owner_access;
create policy owner_access_read on user_owner_access
  for select to authenticated
  using (user_id = auth.uid() or fn_can('users.manage') or fn_can('owner.view_all'));
drop policy if exists owner_access_write on user_owner_access;
create policy owner_access_write on user_owner_access
  for all to authenticated
  using (fn_can('users.manage')) with check (fn_can('users.manage'));

-- period_closes: เดิม period_write (ALL) + period_read ใส่มือไว้
-- แยกเป็น "ปิดงวด" (settings.manage) กับ "เปิดงวดที่ปิดแล้ว" (period.reopen) คนละสิทธิ์
alter table period_closes enable row level security;
drop policy if exists period_write on period_closes;
drop policy if exists period_read on period_closes;
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

-- ------------------------------------------------------------
-- 11 · contact_links: เดิม contact_links_all (ALL) ใส่มือไว้ กั้นด้วย fn_is_management()
--      ลบแล้วไม่สร้างแทน = ตารางนี้เขียนไม่ได้เลย จึงแทนด้วยคู่ read/write
--      ให้เท่ากับ contacts (ข้อมูลตั้งค่า + ทุกคนอ่านได้)
-- ------------------------------------------------------------
alter table contact_links enable row level security;
drop policy if exists contact_links_all on contact_links;
drop policy if exists contact_links_read on contact_links;
create policy contact_links_read on contact_links
  for select to authenticated using (true);
drop policy if exists contact_links_write on contact_links;
create policy contact_links_write on contact_links
  for all to authenticated
  using (fn_can('settings.manage')) with check (fn_can('settings.manage'));

-- ============================================================
-- 11b · ชั้นการมองเห็น (ลูกพี่สั่ง 07/10)
--   "Manager ไม่สามารถดูภาพรวมการลงทุนได้ ดูได้แต่ทรัพย์สินที่บริหารจัดการ"
--   "Staff ทำได้แค่ลงข้อมูล"
--
--   หลักสามข้อ
--   1. ขอบเขตทรัพย์เป็นชั้น **เพิ่ม** ไม่ใช่ชั้นแทน — ต้องผ่าน fn_can_see_owner() ด้วยทุกครั้ง
--   2. กั้นที่ row ไม่ใช่ที่หน้าจอ · ถ้า Manager ยังอ่าน transaction_lines ของทรัพย์คนอื่นได้
--      ก็ `select sum(...)` รวมพอร์ตเองได้อยู่ดี แม้ไม่มีเมนูให้กด
--   3. ทรัพย์ที่ยังไม่มอบหมาย (manager_user_id is null) Manager ต้องไม่เห็น
--      — "ไม่มีใครดูแล" ไม่ใช่ "ของทุกคน"
-- ============================================================

-- created_by ต้องไม่ว่าง ไม่ใช่เรื่องความเรียบร้อยแต่เป็นเรื่องใช้งานได้จริง:
-- Manager ที่คีย์รายการไม่ผูกทรัพย์ (เงินเดือน · ค่าธรรมเนียม) อ่านได้เฉพาะของตัวเอง
-- ถ้า created_by ว่าง เขาจะอ่านแถวที่ตัวเองเพิ่งลงไม่ได้ และ `insert ... returning`
-- จะ error เพราะ RETURNING ต้องผ่าน policy ฝั่ง select ด้วย
alter table transactions   alter column created_by set default auth.uid();
alter table draft_entries  alter column created_by set default auth.uid();

-- ขอบเขตทรัพย์แบบเข้ม — ใช้กับทุกที่ที่มี "มูลค่า"
create or replace function fn_can_see_asset(p_asset uuid) returns boolean
language sql stable security definer set search_path = '' as $fn$
  select sri_os.fn_can('portfolio.view_all')
      or (
           sri_os.fn_can('asset.view_assigned')
           and exists (
             select 1 from sri_os.assets a
              where a.id = p_asset and a.manager_user_id = auth.uid()
           )
         );
$fn$;
comment on function fn_can_see_asset(uuid) is
  'ขอบเขตทรัพย์: เห็นทั้งพอร์ต (portfolio.view_all) หรือเฉพาะที่ตัวเองถูกมอบหมาย · manager_user_id is null = ไม่มีใครเห็นนอกจากคนที่มี portfolio.view_all';

-- รายการเงินหนึ่งรายการ ใครอ่านได้ — เขียนที่เดียว ใช้ทั้ง transactions และ transaction_lines
-- **รับค่าของแถวเข้ามา ไม่ใช่ id** เพราะถ้าฟังก์ชันไปอ่านตารางเอง แถวที่กำลัง insert
-- จะยังมองไม่เห็นใน snapshot ของคำสั่งเดียวกัน → `insert ... returning` จะพังทันที
-- (เจอตอนเทสต์ 9.6 · RETURNING ต้องผ่าน policy ฝั่ง select ด้วย)
drop function if exists fn_can_read_txn(uuid);
create or replace function fn_can_read_txn(p_owner uuid, p_asset uuid, p_created_by uuid)
returns boolean
language sql stable set search_path = '' as $fn$
  select sri_os.fn_can_see_owner(p_owner)                -- ชั้นเดิม ยังต้องผ่าน
     and sri_os.fn_can('ledger.read')                    -- Staff ตกที่ชั้นนี้ = 0 แถวเสมอ
     and (
          sri_os.fn_can('portfolio.view_all')
       or p_created_by = auth.uid()                      -- รายการที่ไม่ผูกทรัพย์ เห็นได้เฉพาะของตัวเอง
       or (p_asset is not null and sri_os.fn_can_see_asset(p_asset))
     );
$fn$;
comment on function fn_can_read_txn(uuid, uuid, uuid) is
  'แหล่งความจริงเดียวของ "ใครอ่านรายการเงินแถวนี้ได้" · ใช้ทั้ง transactions และ transaction_lines เพื่อไม่ให้รวมยอดผ่าน lines ได้';

-- assets: Manager เห็นเฉพาะที่ตัวเองดูแล
-- Staff ต้องเห็น **ชื่อ** ทรัพย์ไม่งั้นคีย์ไม่ได้ → สาขาอ้างอิงสำหรับคนที่ไม่มีสิทธิ์ขอบเขตทรัพย์เลย
-- ผูกกับ fn_can('txn.create') ไม่ใช่ "ไม่มีสิทธิ์อะไร" เพราะผู้ใช้ที่ปิดใช้งานต้องไม่เห็นอะไรทั้งนั้น
-- มูลค่าทั้งหมดอยู่ที่ asset_valuations / transaction_lines ซึ่งสาขานี้เข้าไม่ถึง
drop policy if exists assets_by_owner on assets;
create policy assets_by_owner on assets
  for select to authenticated
  using (
    fn_can_see_owner(owner_id)
    and (
         fn_can_see_asset(id)
      or (fn_can('txn.create') and not fn_can('asset.view_assigned'))
    )
  );

-- asset_valuations = มูลค่า → ขอบเขตทรัพย์แบบเข้ม ไม่มีสาขาอ้างอิง
drop policy if exists valuations_by_asset on asset_valuations;
create policy valuations_by_asset on asset_valuations
  for select to authenticated
  using (exists (
    select 1 from assets a
     where a.id = asset_id and fn_can_see_owner(a.owner_id) and fn_can_see_asset(a.id)
  ));

drop policy if exists transactions_by_owner on transactions;
create policy transactions_by_owner on transactions
  for select to authenticated
  using (fn_can_read_txn(owner_id, asset_id, created_by));

-- บรรทัดบัญชีต้องกั้นด้วยกฎเดียวกับหัวรายการ ไม่งั้นรวมยอดผ่าน lines ได้ทั้งพอร์ต
drop policy if exists lines_by_txn on transaction_lines;
create policy lines_by_txn on transaction_lines
  for select to authenticated
  using (exists (
    select 1 from transactions t
     where t.id = transaction_id
       and fn_can_read_txn(t.owner_id, t.asset_id, t.created_by)
  ));

-- ร่าง: คนที่มี ledger.read เห็นทั้งคิวในขอบเขต owner · ที่เหลือเห็นแค่ของตัวเอง
drop policy if exists draft_entries_by_owner on draft_entries;
create policy draft_entries_by_owner on draft_entries
  for select to authenticated
  using (
    fn_can_see_owner(owner_id)
    and (
         fn_can('ledger.read')
      or (fn_can('draft.read_own') and created_by = auth.uid())
    )
  );

-- ============================================================
-- 11c · กันช่องโหว่แบบเดียวกับ access_manage บนตารางที่ชั้นการมองเห็นพึ่งพา
--   policy เป็น permissive และ OR กัน · SELECT/ALL ที่ค้างอยู่หนึ่งตัวบน assets หรือ
--   asset_valuations ลบล้างขอบเขตทรัพย์ทั้งหมด · ผมมองของจริงไม่เห็น จึงให้ migration
--   **หยุด** และบอกชื่อออกมา ดีกว่าปล่อยผ่านแล้วคิดว่ากั้นแล้ว
--   (policy ฝั่งเขียนไม่รื้อให้ เพราะสิทธิ์โมดูลทรัพย์ยังไม่ได้ออกแบบ · D-083)
-- ============================================================
do $$
declare v text;
begin
  select string_agg(tablename || '.' || policyname || ' (' || cmd || ')', ', ') into v
    from pg_policies
   where schemaname = 'sri_os'
     and tablename in ('assets', 'asset_valuations')
     and cmd in ('SELECT', 'ALL')
     and (tablename, policyname) not in (values
           ('assets',           'assets_by_owner'),
           ('asset_valuations', 'valuations_by_asset')
         );
  if v is not null then
    raise exception 'พบ policy อ่านที่ค้างอยู่บนตารางทรัพย์ จะ OR ทับขอบเขตของ Manager: % · ให้ตรวจแล้ว drop หรือเพิ่มเข้า allow-list ก่อนรัน migration นี้', v;
  end if;
end $$;

-- ============================================================
-- 12 · SWEEP — ตารางที่ไฟล์นี้ดูแล ต้องมี policy เท่าที่ประกาศไว้ข้างล่างเท่านั้น
--
--   เหตุผล: policy เป็น permissive และ OR กัน · ของเก่าที่กว้างกว่าหนึ่งตัวที่ค้างอยู่
--   ลบล้างข้อจำกัดใหม่ทั้งหมดได้เงียบๆ · และ project จริงมี policy ที่ใส่มือไว้
--   ซึ่งไม่มีใน migration ไฟล์ไหน จึง drop ตามชื่อเพียงอย่างเดียวไม่พอ
--   ชื่อที่ไม่อยู่ในรายการนี้ = ของเก่า/ของใส่มือ → ลบ แล้ว raise notice บอกว่าลบอะไร
--
--   ตารางที่ไฟล์นี้ **ไม่** ดูแล (bank_accounts · assets · contracts · asset_valuations ·
--   schedules · asset_classes · asset_categories) ไม่ถูก sweep เพราะสิทธิ์ของโมดูลทรัพย์
--   ยังไม่ได้ออกแบบ · แต่ข้อ 13 จะรายงานออกมาว่ามีตัวไหนยังผูกกับ fn_is_management()
-- ============================================================
do $$
declare r record; n int := 0;
begin
  for r in
    select p.tablename, p.policyname
      from pg_policies p
     where p.schemaname = 'sri_os'
       and p.tablename in (
             'owners', 'chart_of_accounts', 'txn_types', 'contacts', 'contact_links',
             'transactions', 'transaction_lines', 'draft_entries', 'cash_confirmations',
             'audit_log', 'app_users', 'settings', 'user_owner_access', 'period_closes',
             'roles', 'permissions', 'role_permissions'
           )
       and (p.tablename, p.policyname) not in (values
             ('owners',             'owners_read'),
             ('owners',             'owners_write'),
             ('chart_of_accounts',  'chart_of_accounts_read'),
             ('chart_of_accounts',  'chart_of_accounts_write'),
             ('txn_types',          'txn_types_read'),
             ('txn_types',          'txn_types_write'),
             ('contacts',           'contacts_read'),
             ('contacts',           'contacts_insert'),
             ('contacts',           'contacts_update'),
             ('contact_links',      'contact_links_read'),
             ('contact_links',      'contact_links_write'),
             ('transactions',       'transactions_by_owner'),
             ('transactions',       'txn_insert'),
             ('transactions',       'txn_update'),
             ('transaction_lines',  'lines_by_txn'),
             ('transaction_lines',  'lines_insert'),
             ('transaction_lines',  'lines_update'),
             ('transaction_lines',  'lines_delete'),
             ('draft_entries',      'draft_entries_by_owner'),
             ('draft_entries',      'draft_insert'),
             ('draft_entries',      'draft_review'),
             ('cash_confirmations', 'confirmations_read'),
             ('cash_confirmations', 'confirmations_write'),
             ('cash_confirmations', 'confirmations_update'),
             ('audit_log',          'audit_read'),
             ('app_users',          'users_read'),
             ('app_users',          'users_write'),
             ('settings',           'settings_read'),
             ('settings',           'settings_write'),
             ('user_owner_access',  'owner_access_read'),
             ('user_owner_access',  'owner_access_write'),
             ('period_closes',      'period_closes_read'),
             ('period_closes',      'period_closes_insert'),
             ('period_closes',      'period_closes_reopen'),
             ('roles',              'roles_read'),
             ('roles',              'roles_write'),
             ('permissions',        'permissions_read'),
             ('permissions',        'permissions_write'),
             ('role_permissions',   'role_permissions_read'),
             ('role_permissions',   'role_permissions_write')
           )
  loop
    execute format('drop policy if exists %I on sri_os.%I', r.policyname, r.tablename);
    raise notice 'sweep: ลบ policy ที่ค้างอยู่ %.% (จะ OR ทับสิทธิ์ใหม่)', r.tablename, r.policyname;
    n := n + 1;
  end loop;
  raise notice 'sweep: ลบของค้างทั้งหมด % ตัว', n;
end $$;

-- ============================================================
-- 13 · รายงานของที่ยังผูกกับ fn_is_management() บนตารางที่ไฟล์นี้ไม่ดูแล
--      ไม่ลบให้ เพราะสิทธิ์โมดูลทรัพย์ยังไม่ได้ออกแบบ (D-083) แต่ต้องไม่เงียบ
-- ============================================================
do $$
declare v text;
begin
  select string_agg(tablename || '.' || policyname, ', ') into v
    from pg_policies
   where schemaname = 'sri_os'
     and (coalesce(qual, '') || coalesce(with_check, '')) ~ 'fn_is_management';
  if v is not null then
    raise notice 'เหลือ policy ที่ยังเรียก fn_is_management() (deprecated) ต้องแปลงในงานถัดไป: %', v;
  else
    raise notice 'ไม่มี policy ไหนเรียก fn_is_management() แล้ว';
  end if;
end $$;
