-- ============================================================
-- SRI OS · ปิดรูที่ mace-windu จับได้ — ความสมบูรณ์ของบรรทัดบัญชี · ขอบเขตสัญญา · view ข้าม RLS
--
-- ทำอะไร:
--   1. trigger บน transaction_lines — บรรทัดของรายการที่ post แล้ว แก้/ลบ/เพิ่มไม่ได้
--      (ยอมเฉพาะตอนลงพร้อมหัวรายการในธุรกรรมเดียวกัน) · กฎเหล็กข้อ 1
--   2. รายการที่ post แล้วต้องมีบรรทัดอย่างน้อย 2 บรรทัดและสมดุล — เดิม 0 บรรทัดผ่านเพราะ 0 = 0
--   3. contracts / schedules เพิ่มขอบเขตทรัพย์ (เดิมกั้นแค่ owner → Manager และ Staff
--      `sum(principal)` ได้ทั้งพอร์ต)
--   4. ทุก view ใน sri_os ตั้ง security_invoker = true — เดิม v_asset_latest_value
--      รันด้วยสิทธิ์เจ้าของ view = NAV ทั้งพอร์ตรั่วให้ Manager/Staff
--
-- ทำไมต้องเป็น trigger ไม่ใช่ RLS: policy ในอนาคตเขียนทับ RLS ได้ (permissive OR กัน)
--   แต่ trigger บังคับกับทุกเส้นทางและทุก role เท่ากัน รวม super_admin
--   **trigger ในไฟล์นี้ห้ามเรียก fn_can()** — กฎเงินไม่ขึ้นกับตารางสิทธิ์ (มีเทสต์ยืนยันจาก pg_proc)
--
-- ย้อนกลับ (rollback):
--   -- drop trigger if exists trg_lines_immutable_after_post on sri_os.transaction_lines;
--   -- drop trigger if exists trg_posted_needs_lines on sri_os.transactions;
--   -- drop function if exists sri_os.fn_lines_immutable_after_post();
--   -- drop function if exists sri_os.fn_posted_needs_lines();
--   -- คืน fn_assert_balanced() รุ่นเดิมจาก 20260917000002_ledger.sql (รันไฟล์นั้นซ้ำได้)
--   -- คืน policy เดิม: รัน 20260917000004_rls.sql ซ้ำ (contracts_by_owner · schedules_by_contract)
--   -- alter view sri_os.v_asset_latest_value reset (security_invoker);
--   -- **ไม่แนะนำให้ย้อนข้อ 4** เพราะเท่ากับเปิดรู NAV คืน
--
-- idempotent: create or replace · drop trigger if exists ก่อน create · alter view ซ้ำได้
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 1 · บรรทัดบัญชีของรายการที่ post แล้ว = ประวัติ ห้ามแตะ
--
--   สถานะมีแค่ posted | void จึงไม่มี "ร่างในตาราง transactions"
--   → เส้นทางที่ถูกต้องคือ ลงหัวรายการ + บรรทัดใน **ธุรกรรมฐานข้อมูลเดียวกัน**
--   ตรวจด้วย xmin ของหัวรายการ ไม่ใช่เวลา เพราะเวลาเดาได้/ชนกันได้
--
--   **ข้อนี้บังคับเส้นทางเขียนลง DB ที่ยังไม่ได้ทำ (งานถัดไปข้อ 1) ให้เขียนหัวรายการ
--   กับบรรทัดในธุรกรรมเดียว** (RPC / function เดียว) ถ้าแยกสองคำขอจะโดนปฏิเสธ
--   ซึ่งถูกต้องแล้ว เพราะหัวรายการ posted ที่ยังไม่มีบรรทัดคือยอดที่ผิดอยู่กลางทาง
-- ============================================================
-- ตรวจหัวรายการ "หนึ่งฝั่ง" — เรียกทั้งฝั่ง old และฝั่ง new
-- (เดิมใช้ coalesce(new.transaction_id, old.transaction_id) ซึ่งตอน UPDATE new ไม่เคย null
--  → ตรวจแค่หัวรายการปลายทาง หัวรายการต้นทางไม่ถูกตรวจเลย = ย้ายบรรทัดออกจากรายการ
--  ที่ posted ได้ เหลือ dr 2000 / cr 0)
create or replace function fn_assert_line_writable(p_txn uuid) returns void
language plpgsql security definer set search_path = '' as $fn$
declare
  v_status  sri_os.txn_status;
  v_xmin    xid;
  v_created timestamptz;
begin
  if p_txn is null then return; end if;

  -- security definer: ถ้าปล่อยให้อ่านตามสิทธิ์ผู้เรียก คนที่มองหัวรายการไม่เห็น
  -- จะได้ v_status = null แล้วหลุดการตรวจไปเฉยๆ
  select t.status, t.xmin, t.created_at into v_status, v_xmin, v_created
    from sri_os.transactions t where t.id = p_txn;

  if v_status is null then
    raise exception 'บรรทัดบัญชีต้องผูกกับรายการที่มีอยู่จริง (transaction_id %)', p_txn;
  end if;

  -- ลงพร้อมหัวรายการในธุรกรรมเดียวกัน = เส้นทางปกติของการ post · ต้องจริงทั้งสองข้อ
  --   created_at = now() → now() คือเวลาเริ่มธุรกรรม และ created_at แก้ไม่ได้ (trigger ข้างล่าง)
  --     ใช้ข้อนี้ลำพังไม่พอ เพราะสองธุรกรรมอาจเริ่มที่ไมโครวินาทีเดียวกัน
  --   age(xmin) ≤ age(ธุรกรรมปัจจุบัน) → หัวรายการถูกเขียน "ไม่เก่ากว่า" ธุรกรรมนี้
  --     ใช้ xmin ลำพังไม่พอ เพราะ **UPDATE หัวรายการก็ทำให้ xmin กลายเป็นธุรกรรมนี้**
  --     → `update ... set status='void'` แล้วลบบรรทัดจะหลุด (เทสต์ L4 จับได้)
  -- **ห้ามเทียบ xmin = pg_current_xact_id() ตรงๆ** — บล็อก plpgsql ที่มี exception handler
  -- และ SAVEPOINT ทำให้แถวได้ xid ของ subtransaction (ซึ่ง > xid ของธุรกรรมหลัก)
  -- เทียบตรงๆ จะปฏิเสธการ post ที่ถูกต้องทั้งหมดถ้าเส้นทางเขียนมี savepoint (เทสต์ L13)
  if v_created = now() and age(v_xmin) <= age(pg_current_xact_id()::xid) then
    return;
  end if;

  -- ไม่เช็ค status: void ก็แก้ไม่ได้ ไม่งั้นได้ทางอ้อม "void ก่อน แล้วแก้บรรทัด"
  -- รายการที่อยู่ใน ledger แล้วคือประวัติ ทุกสถานะ
  raise exception 'กฎเหล็กข้อ 1: บรรทัดบัญชีของรายการที่บันทึกแล้วแก้/ลบ/เพิ่มไม่ได้ (transaction % สถานะ %) ให้ reverse รายการเดิมแล้วลงใหม่', p_txn, v_status;
end $fn$;

create or replace function fn_lines_immutable_after_post() returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  -- ย้ายบรรทัดข้ามหัวรายการ = ห้ามเด็ดขาด ไม่มีข้อยกเว้นแม้หัวรายการทั้งสองจะเพิ่งสร้าง
  -- เพราะมันคือการแก้ยอดของรายการต้นทางโดยไม่แตะรายการต้นทางเลย
  if tg_op = 'UPDATE' and new.transaction_id is distinct from old.transaction_id then
    raise exception 'กฎเหล็กข้อ 1: ย้ายบรรทัดบัญชีข้ามรายการไม่ได้ (% → %) ให้ reverse รายการเดิมแล้วลงใหม่',
      old.transaction_id, new.transaction_id;
  end if;

  -- ตรวจทั้งสองฝั่ง · DELETE มีแต่ old · INSERT มีแต่ new
  if tg_op <> 'INSERT' then perform sri_os.fn_assert_line_writable(old.transaction_id); end if;
  if tg_op <> 'DELETE' then perform sri_os.fn_assert_line_writable(new.transaction_id); end if;

  return coalesce(new, old);
end $fn$;

drop trigger if exists trg_lines_immutable_after_post on transaction_lines;
create trigger trg_lines_immutable_after_post
  before insert or update or delete on transaction_lines
  for each row execute function fn_lines_immutable_after_post();

-- created_at ของหัวรายการต้องแก้ไม่ได้ ไม่งั้นเงื่อนไข "ลงในธุรกรรมเดียวกัน" ข้างบนปลอมได้
-- และ **owner_id ย้ายด้วย UPDATE ไม่ได้** — เส้นทางที่หลุดทั้ง fn_corporate_immutable
-- (ซึ่งอ่าน old.owner_id จึงกันได้แค่รายการที่เป็นนิติบุคคลอยู่แล้ว) และ
-- fn_corporate_requires_evidence (ซึ่งเดิมเป็น BEFORE INSERT เท่านั้น) คือ
-- รายการของ**บุคคล** ที่ posted แล้ว → `update set owner_id = <SRI Corp>`
-- = เข้าสมุดนิติบุคคลโดยไม่มีไฟล์แนบ/คู่ค้า และผิดกฎ "1 transaction = 1 owner"
-- เลือก raise ไม่ใช่ pin เงียบๆ เพราะ owner_id เป็นข้อมูลที่ผู้ใช้กรอก
-- ถ้าปรับให้เงียบ คนเรียกจะเชื่อว่าย้ายสำเร็จแล้วไปอ่านตัวเลขผิดต่อ
create or replace function fn_txn_created_at_immutable() returns trigger
language plpgsql set search_path = '' as $fn$
begin
  if new.owner_id is distinct from old.owner_id then
    raise exception 'กฎ 1 transaction = 1 owner: ย้ายผู้ถือของรายการที่บันทึกแล้วด้วย UPDATE ไม่ได้ (% → %) ให้ reverse แล้วลงใหม่ในชื่อผู้ถือที่ถูกต้อง',
      old.owner_id, new.owner_id;
  end if;
  new.created_at := old.created_at;   -- เงียบๆ ไม่ให้แก้ · ไม่ใช่ข้อมูลที่ผู้ใช้กรอก
  new.id         := old.id;
  return new;
end $fn$;

drop trigger if exists trg_txn_created_at_immutable on transactions;
create trigger trg_txn_created_at_immutable
  before update on transactions
  for each row execute function fn_txn_created_at_immutable();

-- audit บรรทัดบัญชีด้วย — เดิมมีแต่ transactions และ draft_entries
-- ถ้าไม่มี การแก้บรรทัดจะไม่เหลือร่องรอยเลย (audit_log 0 แถว ตามที่ตรวจเจอ)
drop trigger if exists trg_audit_lines on transaction_lines;
create trigger trg_audit_lines
  after insert or update or delete on transaction_lines
  for each row execute function fn_audit();

-- ============================================================
-- 2 · สมดุลต้องรวมกรณี "ไม่มีบรรทัดเลย"
--     เดิม 0 = 0 ผ่าน → ลบบรรทัดทั้งคู่ทิ้งได้ เหลือหัวรายการ posted ที่ไม่มียอด
-- ============================================================
create or replace function fn_assert_txn_balanced(p_txn uuid) returns void
language plpgsql security definer set search_path = '' as $fn$
declare
  v_dr numeric(18,2);
  v_cr numeric(18,2);
  v_n  int;
  v_status sri_os.txn_status;
begin
  if p_txn is null then return; end if;

  select coalesce(sum(debit), 0), coalesce(sum(credit), 0), count(*)
    into v_dr, v_cr, v_n
    from sri_os.transaction_lines where transaction_id = p_txn;

  if v_dr <> v_cr then
    raise exception 'Money Invariant 1: transaction % ไม่สมดุล (debit %, credit %)', p_txn, v_dr, v_cr;
  end if;

  select t.status into v_status from sri_os.transactions t where t.id = p_txn;
  -- หัวรายการถูกลบไปแล้ว (cascade) ไม่ต้องตรวจ
  if v_status is null then return; end if;

  if v_status = 'posted' and v_n < 2 then
    raise exception 'Money Invariant 1: รายการที่บันทึกแล้วต้องมีบรรทัดบัญชีอย่างน้อย 2 บรรทัด (transaction % มี % บรรทัด)', p_txn, v_n;
  end if;
end $fn$;

-- ตรวจ **ทั้งสองฝั่ง** ไม่ใช่ coalesce ตัวเดียว
-- ตอน UPDATE `new` ไม่เคย null → ของเดิมตรวจแค่ปลายทาง ต้นทางเสียยอดโดยไม่มีใครดู
create or replace function fn_assert_balanced() returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  if tg_op <> 'INSERT' then perform sri_os.fn_assert_txn_balanced(old.transaction_id); end if;
  if tg_op <> 'DELETE' then perform sri_os.fn_assert_txn_balanced(new.transaction_id); end if;
  return null;
end $fn$;

drop trigger if exists trg_assert_balanced on transaction_lines;
create constraint trigger trg_assert_balanced
  after insert or update or delete on transaction_lines
  deferrable initially deferred
  for each row execute function fn_assert_balanced();

-- หัวรายการที่ post แล้วแต่ไม่เคยมีบรรทัดเลย — trigger ฝั่ง lines ไม่เคยยิง จึงต้องมีตัวนี้
create or replace function fn_posted_needs_lines() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare v_n int;
begin
  if new.status <> 'posted' then return null; end if;
  select count(*) into v_n from sri_os.transaction_lines where transaction_id = new.id;
  if v_n < 2 then
    raise exception 'Money Invariant 1: รายการ % บันทึกแล้วแต่มีบรรทัดบัญชี % บรรทัด (ต้อง ≥ 2) — หัวรายการกับบรรทัดต้องลงในธุรกรรมเดียวกัน', new.id, v_n;
  end if;
  return null;
end $fn$;

drop trigger if exists trg_posted_needs_lines on transactions;
create constraint trigger trg_posted_needs_lines
  after insert or update on transactions
  deferrable initially deferred
  for each row execute function fn_posted_needs_lines();

-- ============================================================
-- 2b · กติกาหลักฐานของนิติบุคคลต้องบังคับตอน UPDATE ด้วย
--   เดิม trg_corporate_evidence เป็น `before insert` เท่านั้น
--   → insert พร้อมไฟล์แนบ แล้ว `update set attachments = '{}'` ไม่มี trigger ไหนตรวจเลย
--   (fn_corporate_immutable ยอมให้แก้ได้ถ้า status เป็น void และ doc_date เดิม
--    จึงล้างไฟล์แนบพร้อม void ได้) · และถ้าวันหนึ่งคิวอนุมัติ post ด้วยการ UPDATE status
--   กติกาหลักฐานจะไม่เคยถูกบังคับเลย
--   ไม่แก้ไฟล์ 002 · แค่ผูก trigger เดิมเพิ่มเหตุการณ์ (ตัวฟังก์ชันใช้ new ล้วน ใช้กับ update ได้)
-- ============================================================
drop trigger if exists trg_corporate_evidence on transactions;
create trigger trg_corporate_evidence
  before insert or update on transactions
  for each row execute function fn_corporate_requires_evidence();

-- ============================================================
-- 3 · contracts / schedules — เพิ่มขอบเขตทรัพย์
--     เดิม `using (fn_can_see_owner(owner_id))` → Manager รวม principal ได้ทั้งพอร์ต
--     และ Staff ที่ไม่ควรเห็นยอดเลยก็ได้เท่ากัน
--     contracts ไม่มีคอลัมน์ created_by จึงไม่มีสาขา "ของที่ตัวเองลง" เหมือน transactions
-- ============================================================
create or replace function fn_can_read_contract(p_owner uuid, p_asset uuid) returns boolean
language sql stable set search_path = '' as $fn$
  select sri_os.fn_can_see_owner(p_owner)
     and sri_os.fn_can('ledger.read')                  -- Staff ตกที่ชั้นนี้
     and (
          sri_os.fn_can('portfolio.view_all')
       or (p_asset is not null and sri_os.fn_can_see_asset(p_asset))
     );
$fn$;
comment on function fn_can_read_contract(uuid, uuid) is
  'ขอบเขตการอ่านสัญญา = owner + ทรัพย์ที่ดูแล · สัญญาที่ไม่ผูกทรัพย์เห็นได้เฉพาะคนที่มี portfolio.view_all';

drop policy if exists contracts_by_owner on contracts;
create policy contracts_by_owner on contracts
  for select to authenticated
  using (fn_can_read_contract(owner_id, asset_id));

drop policy if exists schedules_by_contract on schedules;
create policy schedules_by_contract on schedules
  for select to authenticated
  using (exists (
    select 1 from contracts c
     where c.id = contract_id and fn_can_read_contract(c.owner_id, c.asset_id)
  ));

-- กันแบบเดียวกับข้อ 11c ของไฟล์ก่อน: policy อ่านที่ค้างอยู่หนึ่งตัว OR ทับขอบเขตนี้ได้
do $$
declare v text;
begin
  select string_agg(tablename || '.' || policyname || ' (' || cmd || ')', ', ') into v
    from pg_policies
   where schemaname = 'sri_os'
     and tablename in ('contracts', 'schedules')
     and cmd in ('SELECT', 'ALL')
     and (tablename, policyname) not in (values
           ('contracts', 'contracts_by_owner'),
           ('schedules', 'schedules_by_contract')
         );
  if v is not null then
    raise exception 'พบ policy อ่านที่ค้างอยู่บน contracts/schedules จะ OR ทับขอบเขตทรัพย์: % · ให้ตรวจแล้ว drop ก่อนรัน migration นี้', v;
  end if;
end $$;

-- ============================================================
-- 4 · view ต้องรันด้วยสิทธิ์ผู้เรียก ไม่ใช่สิทธิ์เจ้าของ view
--     v_asset_latest_value ไม่ได้ตั้ง security_invoker → Manager/Staff อ่าน
--     asset_valuations ตรงๆ ได้ 1/0 แถว แต่ `select sum(value)` ผ่าน view ได้ทั้งพอร์ต
--     ทำทุก view ในสคีมา ไม่ใช่ตัวเดียว เพราะของจริงอาจมี view ที่ไม่อยู่ในรีโป
-- ============================================================
do $$
declare r record; n int := 0;
begin
  for r in
    select c.relname
      from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
     where ns.nspname = 'sri_os' and c.relkind in ('v', 'm')
  loop
    begin
      execute format('alter view sri_os.%I set (security_invoker = true)', r.relname);
      n := n + 1;
    exception when others then
      -- materialized view ตั้งไม่ได้ ต้องแก้เป็น view ปกติหรือฟังก์ชันที่กรองเอง
      raise exception 'ตั้ง security_invoker ให้ % ไม่ได้: % · materialized view ข้าม RLS โดยธรรมชาติ ห้ามเก็บยอดเงินไว้ในนั้น', r.relname, sqlerrm;
    end;
  end loop;
  raise notice 'ตั้ง security_invoker = true ให้ view ในสคีมา sri_os จำนวน % ตัว', n;
end $$;

-- ============================================================
-- 5 · view ที่สร้าง **หลัง** migration นี้ต้องได้ security_invoker เองโดยอัตโนมัติ
--     loop ในข้อ 4 ตั้งให้เฉพาะ view ที่มีอยู่ตอน migrate · ของใหม่จะกลายเป็นทางลัดข้าม RLS อีก
--     event trigger ต้องสร้างด้วยสิทธิ์ superuser · บน Supabase ถ้า role ที่รัน migration
--     ไม่มีสิทธิ์ จะไม่ล้ม แต่จะเตือนออกมาให้ไปรันด้วย supabase_admin (เงียบไม่ได้)
-- ============================================================
create or replace function fn_force_view_security_invoker() returns event_trigger
language plpgsql as $fn$
declare r record; v_opts text;
begin
  for r in select * from pg_event_trigger_ddl_commands() loop
    if r.schema_name = 'sri_os' and r.object_type in ('view', 'materialized view') then
      if r.object_type = 'materialized view' then
        raise exception 'materialized view (%) ข้าม RLS โดยธรรมชาติ ตั้ง security_invoker ไม่ได้ · ห้ามเก็บยอดเงินไว้ในนั้น ให้ใช้ view ปกติหรือฟังก์ชันที่กรองตามสิทธิ์', r.object_identity;
      end if;
      select array_to_string(c.reloptions, ',') into v_opts
        from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
       where c.oid = r.objid;
      -- กันวนซ้ำ: ALTER ข้างล่างจะยิง event trigger นี้อีกรอบ แต่รอบนั้นค่าถูกตั้งแล้ว
      if coalesce(v_opts, '') not ilike '%security_invoker=true%' then
        execute format('alter view %s set (security_invoker = true)', r.object_identity);
        raise notice 'ตั้ง security_invoker = true ให้ view ใหม่ % อัตโนมัติ', r.object_identity;
      end if;
    end if;
  end loop;
end $fn$;

do $$
begin
  drop event trigger if exists trg_force_view_security_invoker;
  create event trigger trg_force_view_security_invoker
    on ddl_command_end
    when tag in ('CREATE VIEW', 'ALTER VIEW', 'CREATE MATERIALIZED VIEW')
    execute function fn_force_view_security_invoker();
exception when insufficient_privilege then
  raise warning 'สร้าง event trigger ไม่ได้ (ต้องเป็น superuser) → view ที่สร้างหลังจากนี้จะไม่ได้ security_invoker อัตโนมัติ · ให้รันท่อนนี้ด้วย supabase_admin: create event trigger trg_force_view_security_invoker on ddl_command_end when tag in (''CREATE VIEW'', ''ALTER VIEW'', ''CREATE MATERIALIZED VIEW'') execute function sri_os.fn_force_view_security_invoker();';
end $$;
