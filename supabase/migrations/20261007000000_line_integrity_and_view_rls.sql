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
-- รอบสาม (07/10) ปิดอีก 3 รู + กันรูที่ 4 ไว้ล่วงหน้า:
--   5. created_at ของ transactions/transaction_lines **ระบบตั้งเท่านั้น** (BEFORE INSERT ด้วย)
--      และเงื่อนไข "ลงในธุรกรรมเดียวกัน" เลิกเดาจาก created_at + age(xmin)
--      → ใช้คอลัมน์ write_txn_id (xid8 ของธุรกรรมบนสุด) เทียบเท่ากันตรงๆ
--   6. หัวรายการ **ทุกสถานะ** ต้องมีบรรทัด ≥ 2 และสมดุลตอน commit (เดิมเช็คแค่ posted
--      → หัวรายการ status='void' ที่มี 0 บรรทัด commit ผ่าน แล้วใช้เป็นที่วางบรรทัดข้ามธุรกรรม)
--   7. void = สถานะปลายทาง ออกจาก void ไม่ได้ทุก role ทุก owner
--      (เดิม fn_corporate_immutable เช็คแค่ old.status='posted' → void → posted ย้อนได้
--       ขณะที่รายการกลับรายการยังอยู่ = รายได้นับซ้ำ · เป็น Money Invariant ไม่ใช่กติกาเอกสาร)
--   8. ข้อยกเว้น source='reverse' ของ corporate_strict ต้องมี reverses_id ที่ชี้ไปรายการจริง
--      ของผู้ถือเดียวกัน และยังไม่ถูกกลับรายการ (เดิมอ้างคำว่า reverse ลอยๆ ก็ข้ามหลักฐานได้)
--   9. TRUNCATE ตารางการเงินไม่ได้ทุก role (row trigger ไม่ยิงตอน TRUNCATE)
--      กันไว้แม้ project จริงจะไม่ได้ grant TRUNCATE ให้ authenticated
--
-- ทำไมต้องเป็น trigger ไม่ใช่ RLS: policy ในอนาคตเขียนทับ RLS ได้ (permissive OR กัน)
--   แต่ trigger บังคับกับทุกเส้นทางและทุก role เท่ากัน รวม super_admin
--   **trigger ในไฟล์นี้ห้ามเรียก fn_can()** — กฎเงินไม่ขึ้นกับตารางสิทธิ์ (มีเทสต์ยืนยันจาก pg_proc)
--
-- ย้อนกลับ (rollback):
--   -- drop trigger if exists trg_lines_immutable_after_post on sri_os.transaction_lines;
--   -- drop trigger if exists trg_txn_needs_lines on sri_os.transactions;
--   -- drop trigger if exists trg_txn_system_columns on sri_os.transactions;
--   -- drop trigger if exists trg_line_system_columns on sri_os.transaction_lines;
--   -- drop trigger if exists trg_void_is_terminal on sri_os.transactions;
--   -- drop trigger if exists trg_assert_reverse_link on sri_os.transactions;
--   -- drop trigger if exists trg_forbid_truncate on sri_os.transactions;
--   -- drop trigger if exists trg_forbid_truncate on sri_os.transaction_lines;
--   -- drop trigger if exists trg_forbid_truncate on sri_os.audit_log;
--   -- drop function if exists sri_os.fn_lines_immutable_after_post();
--   -- drop function if exists sri_os.fn_txn_needs_lines();
--   -- drop function if exists sri_os.fn_txn_system_columns();
--   -- drop function if exists sri_os.fn_line_system_columns();
--   -- drop function if exists sri_os.fn_void_is_terminal();
--   -- drop function if exists sri_os.fn_assert_reverse_link();
--   -- drop function if exists sri_os.fn_reverse_link_ok(uuid, uuid, uuid);
--   -- drop function if exists sri_os.fn_forbid_truncate();
--   -- alter table sri_os.transactions drop column if exists write_txn_id;
--   -- alter table sri_os.transaction_lines drop column if exists created_at;
--   -- คืน fn_corporate_immutable() + fn_corporate_requires_evidence() รุ่นเดิม:
--   --   รัน 20260917000002_ledger.sql ซ้ำ (แต่จะเปิดรูที่ 7 และ 8 คืน ไม่แนะนำ)
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
-- ============================================================
-- 1a · คอลัมน์ที่ "ระบบตั้งเท่านั้น" + หลักฐานว่าเขียนในธุรกรรมเดียวกันจริง
--
--   เดิมเงื่อนไข "ลงในธุรกรรมเดียวกัน" อ่านจาก created_at + age(xmin) ซึ่งปลอมได้สองทาง
--     1. created_at ของ transactions **ผู้เรียกเขียนได้ตอน INSERT**
--        (trigger เดิมเป็น BEFORE UPDATE เท่านั้น) → session B ปั่นให้เท่ากับ now() ของ A ได้
--     2. age(xmin) ≤ age(ธุรกรรมปัจจุบัน) เป็นเงื่อนไข "ไม่เก่ากว่า" ไม่ใช่ "ตัวเดียวกัน"
--        → ถ้า A จอง xid ไว้ก่อน (pg_current_xact_id()) แล้ว B เขียนหัวรายการทีหลัง
--          xid ของ B จะใหม่กว่า A และผ่านเงื่อนไขนี้
--   รวมกันแล้วลงหัวรายการกับบรรทัดต่าง db transaction ได้จริง (ผู้ตรวจรันได้ dr 777,777)
--
--   กลไกใหม่: คอลัมน์ write_txn_id เก็บ **xid8 ของธุรกรรมบนสุด** ที่ INSERT แถวนั้น
--   - pg_current_xact_id() คืน xid ของธุรกรรม**บนสุด**เสมอ แม้เรียกจาก subtransaction
--     (savepoint / บล็อก exception) → เทียบ "เท่ากันตรงๆ" ได้โดยไม่ต้องผ่อนเป็น age()
--     ซึ่งเป็นต้นเหตุของรูนี้ · เคส L13 จึงยังผ่าน
--   - xid8 เป็น 64 บิต ไม่วน → ไม่มีธุรกรรมอื่นได้ค่าเดียวกันตลอดอายุฐานข้อมูล
--   - trigger เขียนทับค่าที่ผู้เรียกส่งมาทุกครั้ง → ปลอมไม่ได้แม้มีสิทธิ์ INSERT ตรง
--   - แถวของธุรกรรมอื่นที่ยัง**ไม่ commit** มองไม่เห็นด้วย snapshot ของเราอยู่แล้ว
--     (security definer ไม่ช่วยให้เห็น) → ตกที่สาขา "ต้องผูกกับรายการที่มีอยู่จริง"
--
--   แถวเก่าที่มีอยู่ก่อน migration นี้ได้ write_txn_id = null → บรรทัดของมันแก้ไม่ได้
--   (fail closed) ซึ่งถูกต้อง เพราะมันคือประวัติที่ลงไปแล้ว
-- ============================================================
alter table transactions      add column if not exists write_txn_id xid8;
-- ตั้ง default แยกจาก add column: ถ้าใส่ default พร้อมกัน Postgres จะ rewrite ตาราง
-- แล้วเติม xid ของธุรกรรม migration ให้แถวเก่าทุกแถว = โกหกว่าแถวเก่าเขียนในธุรกรรมนี้
alter table transactions      alter column write_txn_id set default pg_current_xact_id();
alter table transaction_lines add column if not exists created_at timestamptz;
alter table transaction_lines alter column created_at set default now();

comment on column transactions.write_txn_id is
  'xid8 ของธุรกรรมบนสุดที่ INSERT แถวนี้ · ระบบตั้งเท่านั้น (trigger ทับค่าที่ส่งมา) · ใช้พิสูจน์ว่าบรรทัดบัญชีลงพร้อมหัวรายการในธุรกรรมเดียวกัน';
comment on column transaction_lines.created_at is
  'ระบบตั้งเท่านั้น · now() ของธุรกรรมที่ลงบรรทัดนี้';

-- ตรวจหัวรายการ "หนึ่งฝั่ง" — เรียกทั้งฝั่ง old และฝั่ง new
-- (เดิมใช้ coalesce(new.transaction_id, old.transaction_id) ซึ่งตอน UPDATE new ไม่เคย null
--  → ตรวจแค่หัวรายการปลายทาง หัวรายการต้นทางไม่ถูกตรวจเลย = ย้ายบรรทัดออกจากรายการ
--  ที่ posted ได้ เหลือ dr 2000 / cr 0)
create or replace function fn_assert_line_writable(p_txn uuid) returns void
language plpgsql security definer set search_path = '' as $fn$
declare
  v_status sri_os.txn_status;
  v_write  xid8;
begin
  if p_txn is null then return; end if;

  -- security definer: ถ้าปล่อยให้อ่านตามสิทธิ์ผู้เรียก คนที่มองหัวรายการไม่เห็น
  -- จะได้ v_status = null แล้วหลุดการตรวจไปเฉยๆ
  select t.status, t.write_txn_id into v_status, v_write
    from sri_os.transactions t where t.id = p_txn;

  if v_status is null then
    raise exception 'บรรทัดบัญชีต้องผูกกับรายการที่มีอยู่จริง (transaction_id %)', p_txn;
  end if;

  -- หัวรายการถูก INSERT ด้วย **ธุรกรรมนี้** จริง = เส้นทางปกติของการ post
  if v_write is not null and v_write = pg_current_xact_id() then
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

-- created_at / write_txn_id ต้อง **ระบบตั้งตอน INSERT และแก้ไม่ได้ตอน UPDATE**
--   ตอน INSERT: ทับค่าที่ผู้เรียกส่งมาด้วย now() / pg_current_xact_id() เสมอ
--     เดิมกันแค่ UPDATE → ผู้เรียกใส่ created_at เองตอน INSERT ได้ = ปลอมเงื่อนไขข้างบน
--   ตอน UPDATE: pin กลับเป็นค่าเดิม (ไม่ raise เพราะไม่ใช่ข้อมูลที่ผู้ใช้กรอก)
-- และ **owner_id ย้ายด้วย UPDATE ไม่ได้** — เส้นทางที่หลุดทั้ง fn_corporate_immutable
-- (ซึ่งอ่าน old.owner_id จึงกันได้แค่รายการที่เป็นนิติบุคคลอยู่แล้ว) และ
-- fn_corporate_requires_evidence (ซึ่งเดิมเป็น BEFORE INSERT เท่านั้น) คือ
-- รายการของ**บุคคล** ที่ posted แล้ว → `update set owner_id = <SRI Corp>`
-- = เข้าสมุดนิติบุคคลโดยไม่มีไฟล์แนบ/คู่ค้า และผิดกฎ "1 transaction = 1 owner"
-- เลือก raise ไม่ใช่ pin เงียบๆ เพราะ owner_id เป็นข้อมูลที่ผู้ใช้กรอก
-- ถ้าปรับให้เงียบ คนเรียกจะเชื่อว่าย้ายสำเร็จแล้วไปอ่านตัวเลขผิดต่อ
create or replace function fn_txn_system_columns() returns trigger
language plpgsql set search_path = '' as $fn$
begin
  if tg_op = 'INSERT' then
    new.created_at   := now();                   -- ทับค่าที่ส่งมา ไม่ว่าจะส่งอะไร
    new.write_txn_id := pg_current_xact_id();    -- ธุรกรรมบนสุด · subtransaction ก็ได้ค่านี้
    return new;
  end if;

  if new.owner_id is distinct from old.owner_id then
    raise exception 'กฎ 1 transaction = 1 owner: ย้ายผู้ถือของรายการที่บันทึกแล้วด้วย UPDATE ไม่ได้ (% → %) ให้ reverse แล้วลงใหม่ในชื่อผู้ถือที่ถูกต้อง',
      old.owner_id, new.owner_id;
  end if;
  new.created_at   := old.created_at;   -- เงียบๆ ไม่ให้แก้ · ไม่ใช่ข้อมูลที่ผู้ใช้กรอก
  new.id           := old.id;
  new.write_txn_id := old.write_txn_id; -- UPDATE ห้ามทำให้หัวรายการ "กลายเป็นของธุรกรรมนี้"
  return new;
end $fn$;

-- ของเดิมชื่อ fn_txn_created_at_immutable และผูกแค่ before update — ถอดทิ้งให้หมด
-- ไม่ให้เหลือสองตัวที่ถือกฎเดียวกัน (ถ้าเหลือ ตัวเก่าจะเงียบๆ ไม่ครอบ INSERT)
drop trigger  if exists trg_txn_created_at_immutable on transactions;
drop function if exists fn_txn_created_at_immutable();

drop trigger if exists trg_txn_system_columns on transactions;
create trigger trg_txn_system_columns
  before insert or update on transactions
  for each row execute function fn_txn_system_columns();

-- บรรทัดบัญชีก็เหมือนกัน: created_at ระบบตั้งเท่านั้น
-- (ตัวบรรทัดแก้ไม่ได้อยู่แล้วหลัง commit แต่ตอน INSERT ผู้เรียกใส่วันที่ย้อนหลังได้
--  ซึ่งจะทำให้ร่องรอยเวลาใน audit อ่านไม่ตรงความจริง)
create or replace function fn_line_system_columns() returns trigger
language plpgsql set search_path = '' as $fn$
begin
  if tg_op = 'INSERT' then
    new.created_at := now();
    return new;
  end if;
  new.created_at := old.created_at;
  new.id         := old.id;
  return new;
end $fn$;

drop trigger if exists trg_line_system_columns on transaction_lines;
create trigger trg_line_system_columns
  before insert or update on transaction_lines
  for each row execute function fn_line_system_columns();

-- audit บรรทัดบัญชีด้วย — เดิมมีแต่ transactions และ draft_entries
-- ถ้าไม่มี การแก้บรรทัดจะไม่เหลือร่องรอยเลย (audit_log 0 แถว ตามที่ตรวจเจอ)
drop trigger if exists trg_audit_lines on transaction_lines;
create trigger trg_audit_lines
  after insert or update or delete on transaction_lines
  for each row execute function fn_audit();

-- ============================================================
-- 2 · สมดุลต้องรวมกรณี "ไม่มีบรรทัดเลย" · และต้องบังคับกับ **ทุกสถานะ**
--     เดิม 0 = 0 ผ่าน → ลบบรรทัดทั้งคู่ทิ้งได้ เหลือหัวรายการ posted ที่ไม่มียอด
--
--     เดิมเช็ค "ต้องมีบรรทัด ≥ 2" เฉพาะ status = 'posted'
--     → หัวรายการ status = 'void' ที่มี 0 บรรทัด commit ผ่าน แล้วกลายเป็น
--       "ที่ว่างสำหรับวางบรรทัดข้ามธุรกรรม" ของผู้ตรวจ (B ลงหัว · A ลงบรรทัด + flip posted)
--
--     txn_status มีแค่ posted | void ไม่มี draft (ร่างอยู่ตาราง draft_entries)
--     → **ทุกแถวใน transactions ไม่ใช่ draft** จึงต้องมีบรรทัดครบและสมดุลตอน commit ทุกแถว
--     void จริงๆ หน้าตาคือ "แถวที่เคย posted แล้วเปลี่ยน status เป็น void · บรรทัดยังอยู่ครบ"
--     (บรรทัดลบไม่ได้ตามข้อ 1 → void ของจริงมีบรรทัดอยู่เสมอ ไม่มีเคส void 0 บรรทัดที่ถูกต้อง)
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

  -- ทุกสถานะ ไม่ใช่เฉพาะ posted — void 0 บรรทัดก็ผิด (เหตุผลอยู่หัวข้อ 2)
  if v_n < 2 then
    raise exception 'Money Invariant 1: รายการ % (สถานะ %) มีบรรทัดบัญชี % บรรทัด (ต้อง ≥ 2) — หัวรายการกับบรรทัดต้องลงในธุรกรรมเดียวกัน', p_txn, v_status, v_n;
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

-- หัวรายการที่ไม่เคยมีบรรทัดเลย — trigger ฝั่ง lines ไม่เคยยิง จึงต้องมีตัวนี้
-- **เรียกฟังก์ชันเดียวกับฝั่ง lines** ไม่เขียนกฎซ้ำสองที่ (บทเรียนข้อ 5)
create or replace function fn_txn_needs_lines() returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  perform sri_os.fn_assert_txn_balanced(new.id);
  return null;
end $fn$;

-- ของเดิมชื่อ fn_posted_needs_lines และข้าม status ที่ไม่ใช่ posted — ถอดทิ้ง
drop trigger  if exists trg_posted_needs_lines on transactions;
drop function if exists fn_posted_needs_lines();

drop trigger if exists trg_txn_needs_lines on transactions;
create constraint trigger trg_txn_needs_lines
  after insert or update on transactions
  deferrable initially deferred
  for each row execute function fn_txn_needs_lines();

-- แถวเก่าที่มีอยู่ก่อน migration นี้อาจมี < 2 บรรทัด (กฎนี้ยังไม่เคยมี)
-- แถวพวกนั้นจะ **UPDATE ไม่ได้อีก** (เช่น void) เพราะ constraint trigger ตรวจตอน UPDATE ด้วย
-- → เตือนให้เห็นตอน migrate ไม่ปล่อยให้ไปเจอตอนผู้ใช้กดปุ่มแล้วอ่าน error ไม่รู้เรื่อง
do $$
declare v text; n int;
begin
  select count(*), string_agg(id::text, ', ') into n, v
    from transactions t
   where (select count(*) from transaction_lines l where l.transaction_id = t.id) < 2;
  if n > 0 then
    raise warning 'มีหัวรายการเก่า % แถวที่มีบรรทัดบัญชี < 2 → แก้ไข/void แถวพวกนี้ไม่ได้จนกว่าจะล้างข้อมูล (ต้องทำด้วย role ที่ปิด trigger ได้): %', n, v;
  end if;
end $$;

-- ============================================================
-- 2b · กติกาหลักฐานของนิติบุคคลต้องบังคับตอน UPDATE ด้วย
--   เดิม trg_corporate_evidence เป็น `before insert` เท่านั้น
--   → insert พร้อมไฟล์แนบ แล้ว `update set attachments = '{}'` ไม่มี trigger ไหนตรวจเลย
--   (fn_corporate_immutable ยอมให้แก้ได้ถ้า status เป็น void และ doc_date เดิม
--    จึงล้างไฟล์แนบพร้อม void ได้) · และถ้าวันหนึ่งคิวอนุมัติ post ด้วยการ UPDATE status
--   กติกาหลักฐานจะไม่เคยถูกบังคับเลย
--   ไม่แก้ไฟล์ 002 · แค่ผูก trigger เดิมเพิ่มเหตุการณ์ (ตัวฟังก์ชันใช้ new ล้วน ใช้กับ update ได้)
-- ============================================================
-- ============================================================
-- 2c · void = สถานะปลายทาง · ออกจาก void ไม่ได้ทุก role ทุก owner
--
--   รูที่ผู้ตรวจรันได้: fn_corporate_immutable เช็ค old.status = 'posted' เท่านั้น
--   → เมื่อ old.status = 'void' guard ไม่ทำงานเลย · `update set status='posted'`
--     บนรายการที่ void ไปแล้ว **ขณะที่รายการกลับรายการยังอยู่** = debit 1,400 แทน 700
--     (รายได้นับซ้ำ) ทำได้ด้วย role management
--
--   บังคับที่ **ทุก owner** ไม่ใช่แค่ corporate_strict เพราะรายได้นับซ้ำเป็น Money Invariant
--   ไม่ใช่กติกาเอกสารของนิติบุคคล (ฝั่งบุคคล override ได้แค่กติกาเอกสาร)
--   ถ้าต้องกลับมาบันทึกใหม่: ลงรายการใหม่ (reverse แล้วลงใหม่) ไม่ใช่ปลุกแถวเดิม
-- ============================================================
create or replace function fn_void_is_terminal() returns trigger
language plpgsql set search_path = '' as $fn$
begin
  if old.status = 'void' and new.status is distinct from old.status then
    raise exception 'Money Invariant: void คือสถานะปลายทาง · เปลี่ยน void → % ไม่ได้ทุกกรณีทุกผู้ใช้ (id %) ถ้าต้องบันทึกอีกครั้งให้ลงรายการใหม่ (รายการที่ปลุกกลับมาทำให้รายได้นับซ้ำกับรายการกลับรายการที่ยังอยู่)',
      new.status, old.id;
  end if;
  return new;
end $fn$;

drop trigger if exists trg_void_is_terminal on transactions;
create trigger trg_void_is_terminal
  before update on transactions
  for each row execute function fn_void_is_terminal();

-- ปิดรูที่จุดเดิมด้วย (ledger.sql:177) — นิติบุคคลที่ void แล้วก็แก้อะไรไม่ได้อีก
-- ยอมเฉพาะ UPDATE ที่คง status = void และ doc_date เดิม (เส้นทาง void ซ้ำ/แก้ memo ภายใน)
create or replace function fn_corporate_immutable() returns trigger
language plpgsql set search_path = sri_os, public as $fn$
declare
  v_policy owner_policy;
begin
  select policy into v_policy from owners where id = old.owner_id;
  if v_policy = 'corporate_strict'
     -- เดิมเช็คแค่ 'posted' → แถวที่ void แล้วแก้ได้ฟรี (รวมปลุกกลับเป็น posted)
     and old.status in ('posted', 'void')
     -- ยอมให้เปลี่ยนเป็น void ได้ (เส้นทาง reverse) แต่ห้ามแก้ตัวเลข/วันที่
     and not (new.status = 'void' and new.doc_date = old.doc_date) then
    raise exception 'Corporate strict: รายการที่บันทึกแล้วแก้ไม่ได้ ให้ reverse แล้วลงใหม่ (id % สถานะ %)', old.id, old.status;
  end if;
  return new;
end $fn$;

-- ============================================================
-- 2d · ข้ออ้าง "นี่เป็นรายการกลับรายการ" ต้องพิสูจน์ได้
--
--   รูที่ผู้ตรวจรันได้: fn_corporate_requires_evidence มี
--   `if new.source = 'reverse' then return new; end if;` โดยไม่ดู reverses_id เลย
--   → source='reverse' + reverses_id null + attachments '{}' = posted 5,000,000
--     ไม่มีหลักฐาน ไม่มีคู่ค้า ในสมุดนิติบุคคล
--
--   เงื่อนไขของการเป็น "รายการกลับรายการ" ที่ใช้ยกเว้นได้ (ที่เดียว ใช้สองที่เรียก):
--     1. reverses_id ไม่เป็น null
--     2. ไม่ชี้ตัวเอง
--     3. ชี้ไปรายการที่มีอยู่จริง
--     4. รายการนั้นเป็นของ **ผู้ถือเดียวกัน** (กลับรายการข้ามสมุดไม่ได้ · 1 txn = 1 owner)
--     5. ยังไม่มีรายการกลับรายการตัวอื่นที่ยังไม่ถูก void ชี้ไปที่เดียวกัน
--        (กันกลับรายการซ้ำสองรอบ = เครดิตซ้ำ) · นับเฉพาะตัวที่ยัง**ไม่ void**
--        เพราะถ้านับตัวที่ void แล้วด้วย รายการกลับรายการที่ลงผิดแล้ว void ทิ้ง
--        จะทำให้ต้นฉบับกลับรายการไม่ได้อีกตลอดไป (ทางตัน) ส่วนการนับซ้ำต้องมี
--        ตัวที่ยังมีผลอยู่สองตัว ซึ่งยังถูกบล็อก
--
--   security definer: ถ้าอ่านตามสิทธิ์ผู้เรียก คนที่มองรายการต้นฉบับไม่เห็น
--   จะทำให้ข้อ 3 เป็นเท็จ (ปฏิเสธรายการที่ถูกต้อง) และข้อ 5 เป็นจริงเสมอ (หลุดการกันซ้ำ)
-- ============================================================
create or replace function fn_reverse_link_ok(p_id uuid, p_owner uuid, p_reverses uuid)
returns boolean
language sql stable security definer set search_path = '' as $fn$
  select p_reverses is not null
     and p_reverses is distinct from p_id
     and exists (
           select 1 from sri_os.transactions t
            where t.id = p_reverses and t.owner_id = p_owner
         )
     and not exists (
           select 1 from sri_os.transactions t
            where t.reverses_id = p_reverses
              and t.id is distinct from p_id
              and t.status <> 'void'
         );
$fn$;
comment on function fn_reverse_link_ok(uuid, uuid, uuid) is
  'รายการนี้เป็นการกลับรายการที่พิสูจน์ได้หรือไม่ · แหล่งความจริงเดียวของเงื่อนไข ใช้ทั้งที่ trigger ตรวจ reverses_id และที่ยกเว้นหลักฐานของ corporate_strict';

-- บังคับกับ **ทุก owner**: ลิงก์กลับรายการที่ชี้ผิดคือตัวเลขผิด ไม่ใช่เรื่องเอกสาร
create or replace function fn_assert_reverse_link() returns trigger
language plpgsql set search_path = sri_os, public as $fn$
begin
  if new.source = 'reverse' or new.reverses_id is not null then
    if not fn_reverse_link_ok(new.id, new.owner_id, new.reverses_id) then
      raise exception 'รายการกลับรายการต้องชี้ไปรายการจริงของผู้ถือเดียวกันที่ยังไม่ถูกกลับรายการ (source % · reverses_id %)',
        new.source, coalesce(new.reverses_id::text, 'null');
    end if;
  end if;
  return new;
end $fn$;

-- ชื่อขึ้นต้นด้วย a เพื่อให้ยิงก่อน trg_corporate_evidence (trigger เรียงตามชื่อ)
-- → ข้ออ้าง reverse ที่ปลอมจะได้ error ที่บอกสาเหตุจริง ไม่ใช่ "ต้องแนบหลักฐาน"
drop trigger if exists trg_assert_reverse_link on transactions;
create trigger trg_assert_reverse_link
  before insert or update on transactions
  for each row execute function fn_assert_reverse_link();

-- ข้อยกเว้นหลักฐานของ corporate_strict ต้องเรียกเงื่อนไขเดียวกัน ไม่ใช่เชื่อคำว่า reverse
-- (ไม่พึ่งลำดับ trigger — ถ้าวันหนึ่งมีใครเปลี่ยนชื่อ trigger ข้างบน ข้อยกเว้นนี้ต้องยังแน่น)
create or replace function fn_corporate_requires_evidence() returns trigger
language plpgsql set search_path = sri_os, public as $fn$
declare
  v_policy owner_policy;
  v_needs_contact boolean;
begin
  select policy into v_policy from owners where id = new.owner_id;
  if v_policy <> 'corporate_strict' then return new; end if;

  -- รายการกลับรายการที่พิสูจน์ได้เท่านั้นที่ข้ามหลักฐานได้
  -- (หลักฐานของมันคือรายการต้นฉบับซึ่งมีหลักฐานอยู่แล้ว)
  if new.source = 'reverse'
     and fn_reverse_link_ok(new.id, new.owner_id, new.reverses_id) then
    return new;
  end if;

  if cardinality(new.attachments) = 0 then
    raise exception 'Corporate strict: ต้องแนบหลักฐานก่อนบันทึก (txn_type %)', new.txn_type_code;
  end if;

  select requires_contact into v_needs_contact from txn_types where code = new.txn_type_code;
  if coalesce(v_needs_contact, false) and new.contact_id is null then
    raise exception 'Corporate strict: ประเภทรายการนี้ต้องระบุคู่ค้า (txn_type %)', new.txn_type_code;
  end if;

  return new;
end $fn$;

drop trigger if exists trg_corporate_evidence on transactions;
create trigger trg_corporate_evidence
  before insert or update on transactions
  for each row execute function fn_corporate_requires_evidence();

-- ============================================================
-- 2e · TRUNCATE ตารางการเงินไม่ได้ (กฎเหล็กข้อ 1 · Money Invariant 4)
--
--   TRUNCATE ไม่ยิง row trigger และไม่ผ่าน RLS → ล้างสมุดทั้งเล่มได้ในคำสั่งเดียว
--   โดยไม่เหลือร่องรอยใน audit_log · ผู้ตรวจรายงานว่า authenticated ทำได้
--   ซึ่งเป็น **false positive** (ต้นเหตุคือ scripts/test-rls-local.sh ให้ grant all
--   ซึ่งกว้างกว่า project จริง — แก้ที่ harness แล้ว) แต่กันที่ DB ด้วยอยู่ดี
--   เพราะกฎเงินต้องไม่ขึ้นกับว่าใครเผลอ grant อะไรในอนาคต
--   (ตรงหลักเดียวกับที่ไฟล์นี้เลือก trigger แทน RLS)
-- ============================================================
create or replace function fn_forbid_truncate() returns trigger
language plpgsql set search_path = '' as $fn$
begin
  raise exception 'กฎเหล็กข้อ 1 / Money Invariant 4: TRUNCATE %.% ไม่ได้ทุกกรณีทุกผู้ใช้ — ไม่ยิง trigger ไม่เหลือ audit · ให้ใช้ void/reverse ทีละรายการ',
    tg_table_schema, tg_table_name;
end $fn$;

do $$
declare r text;
begin
  foreach r in array array['transactions', 'transaction_lines', 'audit_log'] loop
    execute format('drop trigger if exists trg_forbid_truncate on sri_os.%I', r);
    execute format(
      'create trigger trg_forbid_truncate before truncate on sri_os.%I for each statement execute function sri_os.fn_forbid_truncate()', r);
  end loop;
end $$;

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
