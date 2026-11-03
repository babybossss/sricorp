-- ============================================================
-- SRI OS · EXECUTE ของฟังก์ชันใน sri_os: ปิดเป็นค่าเริ่มต้น + allow-list ที่เดียว
--
-- ทำไม (ผู้ตรวจ 07/10):
--   20261007000001_grants.sql อ้างว่า "ให้ execute เฉพาะตัวที่ RLS/หน้าจอต้องเรียก"
--   แต่มันทำแค่ **grant ให้ authenticated 6 ตัว** และ **revoke trigger function**
--   ฟังก์ชันที่ไม่เข้าสองกลุ่มนั้นยังถือ ACL เริ่มต้นของ Postgres = **PUBLIC EXECUTE**
--   ไล่จาก pg_proc พบ 5 ตัวที่เปิด PUBLIC อยู่:
--     fn_health_check (SECURITY DEFINER) · fn_my_role (SECURITY DEFINER) ·
--     fn_is_management · fn_asset_cost_basis · fn_contract_completeness
--
--   ตัวที่เป็นรูจริง: `fn_health_check` — SECURITY DEFINER รันด้วยสิทธิ์เจ้าของ
--   จึง **ข้าม RLS ทุกตาราง** และ detail ของ check แรกคืน `transaction_id`
--   ของรายการที่ไม่สมดุล **ข้าม owner ทั้งหมด** · ผู้ตรวจเรียกได้สำเร็จจาก session
--   authenticated ที่ **ไม่มีแถวใน app_users เลย** (fn_can ทุกตัวคืน false)
--   = คนที่ยังไม่ถูกตั้งตำแหน่งดึง id รายการของทุกบ้านออกมาได้
--
--   แก้คอมเมนต์ที่คลาดเคลื่อนใน 20261007000001 แล้ว (ชี้มาที่ไฟล์นี้)
--
-- หลักที่ใช้ตอนนี้: **ปิดก่อน แล้วเปิดเท่าที่จำเป็นในรายการเดียว**
--   revoke execute from public, anon, authenticated ให้ "ทุกฟังก์ชันใน sri_os
--   ที่ไม่ได้มาจาก extension" (ไล่จาก pg_proc ไม่ใช่ลิสต์มือ → ฟังก์ชันที่เพิ่ม
--   ในอนาคตถูกปิดด้วยโดยอัตโนมัติ) แล้ว grant กลับตาม ALLOW ด้านล่าง
--   **ยกเว้น extension (pgcrypto ติดตั้งใน sri_os)** — gen_random_uuid() เป็น default
--   ของคอลัมน์ id ทุกตาราง ถอนแล้ว insert ล้มทั้งระบบ (เหตุผลเดียวกับ 20261007000001)
--
-- การตัดสินทีละตัว:
--   fn_health_check          → เฉพาะคนที่มี settings.manage
--       GRANT เลือกตามสิทธิ์ไม่ได้ (ACL ของ Postgres รู้จักแต่ role ไม่รู้จัก permission)
--       → grant ให้ authenticated แล้ว **เช็ค fn_can('settings.manage') ในตัวฟังก์ชัน
--         และ raise** · ฟังก์ชันนี้ไม่ใช่ trigger function จึงไม่ขัดเทสต์ข้อ 10
--         (ข้อ 10 ห้าม trigger function เรียก fn_can เพราะกฎเงินห้ามปิดได้จาก Settings
--          — ส่วนนี่คือ "ใครดูรายงานสุขภาพข้อมูลได้" ซึ่งเป็นสิทธิ์ ไม่ใช่กฎเงิน)
--   fn_my_role               → authenticated · เป็น self-scoped
--       (select role from app_users where id = auth.uid()) ไม่คืนข้อมูลของคนอื่น
--       และ policy users_read ก็ให้อ่านแถวตัวเองอยู่แล้ว → เปิดไว้ไม่เพิ่มอะไรให้ใคร
--   fn_is_management         → authenticated · เป็น wrapper ของ fn_can('owner.view_all')
--       ซึ่ง authenticated เรียกได้อยู่แล้ว · ปิดก็ไม่ได้ซ่อนอะไร เปิดก็ไม่ได้เพิ่มอะไร
--       (ไม่มี policy ไหนใช้มันแล้ว · เก็บไว้เพื่อ back-compat ตามเทสต์ข้อ 5b)
--   fn_asset_cost_basis      → authenticated · **ไม่ใช่** SECURITY DEFINER (ผู้ตรวจเข้าใจคลาด)
--       รันด้วยสิทธิ์ผู้เรียก → RLS ของ transaction_lines/transactions กรองให้เอง
--       หน้าจอทรัพย์ต้องใช้ (ต้นทุน FIFO ตาม D-038) → เปิดให้ authenticated
--   fn_contract_completeness → authenticated · ไม่ใช่ SECURITY DEFINER เช่นกัน
--       RLS ของ contracts กรองให้ · หน้าสัญญาและ Data health ใช้แสดง % ความครบ
--
-- search_path ของ SECURITY DEFINER (ผู้ตรวจสั่งไล่):
--   ทุกตัว **มี** `set search_path` อยู่แล้ว ไม่มีตัวไหนหลุด แต่สองตัวตั้งเป็น
--   'sri_os, public' ซึ่งพา schema `public` เข้ามาในเส้นทางค้นหาของโค้ดที่รัน
--   ด้วยสิทธิ์เจ้าของ · ไฟล์นี้เปลี่ยนเป็น `search_path = ''` + ชื่อเต็มทุกตัว
--   ให้เหมือน fn_can/fn_can_see_owner ที่ทำไว้ถูกแล้ว
--   (PG15+ ตัด CREATE ของ PUBLIC บน public ออกแล้ว จึงยังไม่ถูกยึดสิทธิ์วันนี้
--    แต่พึ่ง ACL ของ schema อื่นอยู่ = พึ่งสิ่งที่เปลี่ยนได้โดยไฟล์นี้ไม่รู้ตัว)
--   fn_audit ก็เป็น SECURITY DEFINER ที่ตั้ง 'sri_os, public' เหมือนกัน (ผู้ตรวจไม่ได้
--   ยกมาเพราะมันเป็น trigger function ที่ถูก revoke หมดแล้ว จึงเรียกตรงไม่ได้)
--   แต่ "เรียกตรงไม่ได้" ไม่ได้ทำให้ search_path ปลอดภัยขึ้น — มันยังรันทุกครั้งที่มี
--   การเขียนตารางการเงิน ด้วยสิทธิ์เจ้าของ → ไฟล์นี้ create or replace ให้แน่นด้วย
--
-- ย้อนกลับ (rollback):
--   -- grant execute on all functions in schema sri_os to public;   -- คืนสภาพเดิมทั้งหมด
--   -- (ย้อนแล้ว fn_health_check เรียกได้จาก authenticated ทุกคน = ดึง transaction_id
--   --  ข้าม owner ได้โดยไม่ต้องมีตำแหน่ง — ไม่แนะนำ)
--   -- ถ้าอยากคืนแค่ search_path เดิม: create or replace ... set search_path = 'sri_os','public'
--
-- idempotent: revoke/grant ซ้ำได้ · create or replace function (ลายเซ็นไม่เปลี่ยน)
-- ============================================================

set search_path = sri_os, public;

-- ---------- 1 · fn_health_check: กั้นสิทธิ์ในตัวฟังก์ชัน + search_path = '' ----------
-- SECURITY DEFINER ยังต้องคงไว้: รายงานสุขภาพข้อมูลต้องเห็น **ทุก owner** ถึงจะมีความหมาย
-- (Money Invariant 1/2/6 เป็นข้อความระดับทั้งระบบ ไม่ใช่ระดับคนใดคนหนึ่ง)
-- แต่เมื่อข้าม RLS ได้ ก็ต้องมีด่านของตัวเอง → fn_can('settings.manage')
create or replace function fn_health_check()
returns table(check_name text, ok boolean, detail text)
language plpgsql stable security definer set search_path = '' as $fn$
begin
  -- ด่านของฟังก์ชันนี้เอง · ข้าม RLS ได้แปลว่าต้องถามสิทธิ์ตรงๆ
  -- raise ไม่ใช่ return 0 แถว — "ไม่มีสิทธิ์" กับ "ข้อมูลสุขภาพดี" ต้องแยกกันให้ออก
  if not sri_os.fn_can('settings.manage') then
    raise exception 'ไม่มีสิทธิ์ดูรายงานสุขภาพข้อมูล (ต้องมี settings.manage) · ฟังก์ชันนี้ข้าม RLS และคืน id รายการข้ามผู้ถือ';
  end if;

  -- 1. ทุก transaction สมดุล
  return query
  select 'transactions_balanced'::text,
         not exists (
           select 1 from sri_os.transaction_lines l
            group by l.transaction_id
           having sum(l.debit) <> sum(l.credit)
         ),
         coalesce((
           select string_agg(x.transaction_id::text, ', ')
             from (select l.transaction_id from sri_os.transaction_lines l
                    group by l.transaction_id
                   having sum(l.debit) <> sum(l.credit) limit 10) x
         ), 'ทุกรายการสมดุล');

  -- 2. ไม่มีบรรทัดเงินสดที่ไม่ผูกบัญชี
  return query
  select 'no_floating_cash'::text,
         not exists (
           select 1 from sri_os.transaction_lines l
             join sri_os.chart_of_accounts c on c.id = l.coa_id
            where c.code ~ '^11[0-9][0-9]$' and l.bank_account_id is null
         ),
         'ทุกบรรทัดเงินสดผูกบัญชีธนาคารแล้ว';

  -- 3. สัญญาที่มีตารางงวดต้องข้อมูลครบ
  return query
  select 'contracts_complete'::text,
         not exists (
           select 1 from sri_os.contracts c
            where exists (select 1 from sri_os.schedules s where s.contract_id = c.id)
              and sri_os.fn_contract_completeness(c.id) < 100
         ),
         'สัญญาที่มีตารางงวดกรอกครบแล้ว';

  -- 4. ราคาทรัพย์ที่เก่าเกิน 7 วัน
  return query
  select 'valuations_fresh'::text,
         not exists (select 1 from sri_os.v_asset_latest_value where is_stale),
         coalesce((
           select 'ราคาเก่า ' || count(*)::text || ' รายการ'
             from sri_os.v_asset_latest_value where is_stale
         ), 'ราคาทุกตัวสดใหม่');
end $fn$;

comment on function fn_health_check() is
  'รายงานสุขภาพข้อมูลทั้งระบบ (Money Invariants) · SECURITY DEFINER = ข้าม RLS โดยเจตนาเพราะต้องเห็นทุก owner · **กั้นด้วย fn_can(settings.manage) ในตัวฟังก์ชัน** เพราะ GRANT เลือกตามสิทธิ์ไม่ได้';

-- ---------- 2 · fn_my_role: search_path = '' (เนื้อในเดิม self-scoped อยู่แล้ว) ----------
create or replace function fn_my_role()
returns text
language sql stable security definer set search_path = '' as $fn$
  select role from sri_os.app_users where id = auth.uid() and is_active;
$fn$;
comment on function fn_my_role() is
  'ตำแหน่งของผู้เรียกเอง · self-scoped (where id = auth.uid()) จึงเปิดให้ authenticated ได้ · SECURITY DEFINER เพื่อไม่ต้องพึ่ง policy users_read';

-- ---------- 3 · สองตัวที่ไม่ใช่ SECURITY DEFINER: แค่เก็บ search_path ให้แน่น ----------
create or replace function fn_asset_cost_basis(p_asset uuid)
returns numeric
language sql stable set search_path = '' as $fn$
  select coalesce(sum(l.debit - l.credit), 0)
    from sri_os.transaction_lines l
    join sri_os.transactions t on t.id = l.transaction_id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where l.asset_id = p_asset
     and t.status = 'posted'
     -- ไม่นับบรรทัดเงินสด เพราะเป็นอีกขาของรายการเดียวกัน
     and c.type = 'asset'::sri_os.coa_type
     and c.code !~ '^11[0-9][0-9]$';
$fn$;

create or replace function fn_contract_completeness(p_contract uuid)
returns integer
language sql stable set search_path = '' as $fn$
  select (
    (case when principal is not null then 1 else 0 end) +
    (case when rate is not null then 1 else 0 end) +
    (case when start_date is not null then 1 else 0 end) +
    (case when end_date is not null or installments is not null then 1 else 0 end) +
    (case when counterparty_contact_id is not null then 1 else 0 end) +
    (case when cardinality(file_urls) > 0 then 1 else 0 end)
  ) * 100 / 6
  from sri_os.contracts where id = p_contract;
$fn$;

-- ---------- 3b · fn_audit: trigger function ที่เป็น SECURITY DEFINER ----------
-- เนื้อในเดิมทั้งหมด เปลี่ยนแค่ search_path = '' + ชื่อเต็มของ audit_log
create or replace function fn_audit()
returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  insert into sri_os.audit_log(table_name, row_id, action, before, after, user_id)
  values (
    tg_table_name,
    coalesce(new.id, old.id),
    lower(tg_op),
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end,
    auth.uid()
  );
  return coalesce(new, old);
end $fn$;

-- ---------- 4 · ปิดทุกฟังก์ชันใน sri_os แล้วเปิดตาม allow-list ----------
do $$
declare
  r record;
  n_revoked int := 0;
  allow text[] := array[
    -- RLS / หน้าจอ เรียกตรง (ของเดิมจาก 20261007000001 · เขียนซ้ำที่นี่เพื่อให้
    -- "รายการที่เปิด" อ่านจบในที่เดียว ไม่ต้องไล่สองไฟล์)
    'fn_can(text)',
    'fn_can_see_owner(uuid)',
    'fn_can_see_asset(uuid)',
    'fn_can_read_txn(uuid,uuid,uuid)',
    'fn_can_read_contract(uuid,uuid)',
    'fn_reverse_link_ok(uuid,uuid,uuid)',
    -- ที่ไฟล์นี้ตัดสินเพิ่ม (เหตุผลทีละตัวอยู่หัวไฟล์)
    'fn_health_check()',
    'fn_my_role()',
    'fn_is_management()',
    'fn_asset_cost_basis(uuid)',
    'fn_contract_completeness(uuid)'
  ];
  v text;
begin
  -- 4.1 ปิดทั้งสคีมา (เว้นของ extension) — ไล่จาก pg_proc เพื่อให้ของใหม่ถูกปิดด้วย
  for r in
    select p.oid::regprocedure::text as sig
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'sri_os'
       and not exists (select 1 from pg_depend d
                        where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    n_revoked := n_revoked + 1;
  end loop;
  raise notice 'ปิด execute ของฟังก์ชันใน sri_os % ตัว (ไม่รวมของ extension)', n_revoked;

  -- 4.2 เปิดกลับตาม allow-list · ชื่อที่หาไม่เจอต้องพังให้เห็น ไม่ใช่ข้ามเงียบๆ
  foreach v in array allow loop
    if to_regprocedure('sri_os.' || v) is null then
      raise exception 'allow-list อ้างฟังก์ชันที่ไม่มีอยู่: sri_os.% · ลายเซ็นเปลี่ยนแล้วหรือสะกดผิด → แอปจะล้มด้วย permission denied', v;
    end if;
    execute format('grant execute on function sri_os.%s to authenticated', v);
  end loop;
  raise notice 'เปิด execute ให้ authenticated ตาม allow-list % ตัว', cardinality(allow);
end $$;

-- ---------- 5 · guard · ห้ามเหลือ SECURITY DEFINER ที่เปิด PUBLIC ----------
-- ไล่จาก pg_proc ไม่ใช่ลิสต์มือ → จับฟังก์ชันที่เพิ่มในอนาคตด้วย
do $$
declare v text;
begin
  select string_agg(p.oid::regprocedure::text, ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.prosecdef
     and has_function_privilege('public', p.oid, 'execute');
  if v is not null then
    raise exception 'ยังมี SECURITY DEFINER ที่ PUBLIC เรียกได้: % · ฟังก์ชันพวกนี้ข้าม RLS', v;
  end if;

  -- SECURITY DEFINER ทุกตัวต้องตั้ง search_path **ให้แน่น** ไม่ใช่แค่ "มี"
  -- (หลุด = ช่องยึดสิทธิ์ · พา schema อื่นเข้ามา = พึ่ง ACL ที่ไฟล์นี้ไม่ได้คุม)
  select string_agg(p.proname || ' → ' || array_to_string(p.proconfig, ','), ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.prosecdef
     and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c
                      where c in ('search_path=', 'search_path=""', 'search_path=sri_os'));
  if v is not null then
    raise exception 'SECURITY DEFINER ที่ search_path ไม่แน่น: % · ตั้งเป็น '''' แล้วเขียนชื่อเต็ม', v;
  end if;
end $$;
