-- ============================================================
-- SRI OS · ปิดช่อง "ลบประวัติการเงินได้เงียบๆ" ในอีกสามตาราง
--   (ช่องเดียวกับ 20261008000002 แต่คนละตาราง · งานก่อนรายงานไว้เองแต่ยังไม่แก้)
--   เทสต์: supabase/tests/zz_delete_guards_test.sql
--
-- สามข้อนี้ **ตัดสินต่างกันตามลักษณะของตาราง ไม่ใช่เหมารวม** — ความต่างคือใจความ
-- ของไฟล์นี้ ใครแก้ต่อให้อ่านเหตุผลให้จบก่อน:
--
-- ------------------------------------------------------------
-- (1) cash_confirmations — ปิด DELETE + TRUNCATE + เพิ่ม audit
-- ------------------------------------------------------------
--   สภาพเดิม: ไม่มี policy DELETE (authenticated ได้ 0 แถวเงียบๆ) · **ไม่มี trigger**
--   → postgres / role ที่ bypassrls ลบได้ · และ **ไม่มี audit trigger เลย**
--   แปลว่าหายไปโดยไม่เหลือร่องรอยแม้ใน audit_log
--
--   ตารางนี้คือคำตอบของคำถาม "เงินเข้า-ออกจริงแล้วหรือยัง" ซึ่งเป็นสิ่งที่ทำให้
--   งบกระแสเงินสดวิ่ง และเป็นฐานของ **Money Invariant 5 (กระทบยอดธนาคารก่อนปิดงวด)**
--   ยอดที่เคยยืนยันแล้วหายไป = กระทบยอดไม่ได้ และไม่มีใครรู้ว่าเคยมี
--
--   **ทางออกที่ถูกต้องเมื่อยืนยันผิด — เขียนไว้ที่นี่เพราะไม่งั้นคนในอนาคตจะไปปิด
--   trigger ทิ้ง:** ห้ามลบแถว ให้ **บันทึกรายการกลับ / แก้ที่แถวเดิมแล้วให้ audit
--   เก็บ before-after** ผ่านสิทธิ์ cash.confirm (policy confirmations_update)
--   ซึ่งไฟล์นี้ทำให้เหลือร่องรอยแล้วเพราะเพิ่ม trg_audit_cash_confirmations
--   หลักเดียวกับกฎเหล็กข้อ 1: ของที่ผิดไม่ลบ แต่ลงรายการที่หักกลบให้เห็นทั้งสองแถว
--
--   **ข้อจำกัดที่ต้องรู้ (รายงานไว้ ยังไม่แก้ในไฟล์นี้)**: ตารางนี้ยังไม่มีคอลัมน์
--   สถานะ/void และไม่มีหน้าจอ-โค้ดฝั่งแอปแตะมันเลย (`src/**` ไม่อ้าง
--   cash_confirmations แม้แถวเดียว) → เส้นทาง "ยกเลิกการยืนยัน" ที่มีอยู่จริง
--   ตอนนี้คือ **UPDATE ที่ระดับ DB เท่านั้น** ไม่ใช่รายการกลับที่เห็นสองแถวในรายงาน
--   ตั้งใจไม่สร้างคอลัมน์/ฟังก์ชันใหม่ในไฟล์นี้ เพราะต้องให้ลูกพี่ตัดสินรูปแบบก่อน
--   (บทเรียนข้อ 7 · เปิดฟีเจอร์ครึ่งเดียวอันตรายกว่าไม่เปิด)
--
-- ------------------------------------------------------------
-- (2) audit_log — ปิด DELETE + UPDATE (เพิ่มได้เท่านั้น)
-- ------------------------------------------------------------
--   สภาพเดิม: 20261007000000 กัน TRUNCATE ไว้แล้ว แต่ **row DELETE/UPDATE ยังเปิด
--   สำหรับ superuser** → คนที่ทำผิดลบหลักฐานของตัวเองได้ทีละแถว
--   ร่องรอยที่ลบได้ไม่ใช่ร่องรอย · ถ้าชั้นนี้หลุด การกันทุกอย่างข้างบนก็ไม่มีความหมาย
--   จึงปิดทั้ง DELETE และ UPDATE: audit_log เป็น **append-only** แท้ๆ
--   (fn_audit มีแต่ INSERT จึงไม่มีอะไรในระบบที่พึ่งพาการแก้แถว audit)
--
-- ------------------------------------------------------------
-- (3) period_closes — **ไม่ปิดการลบ** เพิ่มแต่ audit + กัน TRUNCATE
-- ------------------------------------------------------------
--   การลบแถวที่นี่คือ "เปิดงวดใหม่" ซึ่ง **เป็นเจตนาของระบบ**: มีสิทธิ์
--   `period.reopen` และ policy period_closes_reopen (FOR DELETE) รองรับอยู่แล้ว
--   (DESIGN_ROLES · LEDGER_RULES §4 ให้ Management เปิดงวดที่ปิดแล้วได้)
--   ถ้าปิดการลบที่นี่ = ปิดฟีเจอร์ที่ลูกพี่ต้องใช้ → **จุดนี้กันแน่นเกินจะผิด**
--
--   ที่ขาดคือ audit: ไม่มี trigger ใดบันทึกว่าเคยปิดงวดแล้วเปิดใหม่ ซึ่งเป็น
--   เหตุการณ์ที่ควรรู้ที่สุดเวลาตัวเลขย้อนหลังเปลี่ยน → เพิ่ม trg_audit_period_closes
--
--   **กัน TRUNCATE ด้วย และนี่ไม่ใช่การปิดการลบ**: trg_audit_* เป็น row trigger
--   TRUNCATE ไม่ยิง row trigger → `truncate period_closes` เปิดทุกงวดของทุกผู้ถือ
--   พร้อมกันโดยไม่เหลือ audit แม้แถวเดียว = ลบล้างข้อ (3) ทั้งข้อ
--   เส้นทางที่ตั้งใจ (DELETE ทีละงวดด้วย period.reopen) **ยังทำได้เหมือนเดิม**
--   และเทสต์ P4/P5 บังคับข้อนี้ไว้ (ถ้าใครเผลอใส่ trigger กัน DELETE ที่นี่ เทสต์แดง)
--
-- ------------------------------------------------------------
-- ตารางที่ **ไม่แตะ** โดยตัดสินแล้ว
-- ------------------------------------------------------------
--   asset_drafts: ลบได้ แต่มี trg_audit_asset_drafts อยู่แล้ว และเป็นร่างก่อน
--   อนุมัติ ไม่ใช่ประวัติเงิน → พอแล้ว (เทสต์ A1 พิสูจน์ว่า audit ของมันทำงานจริง
--   ไม่ใช่แค่มี trigger ติดอยู่)
--
-- ------------------------------------------------------------
-- ทำไม trigger ไม่ใช่ RLS/revoke (หลักเดียวกับ 20261007000000 และ 20261008000002)
-- ------------------------------------------------------------
--   RLS มีผลกับ authenticated เท่านั้น · service_role และเจ้าของฐานข้อมูลอยู่นอก
--   ชั้นนั้นทั้งหมด · ฟังก์ชันกันลบในไฟล์นี้ **ไม่ถามสิทธิ์และไม่อ่านตารางไหนเลย**
--   (ห้าม fn_can — เทสต์ข้อ 10 / S18 กันอยู่) เพราะ "ห้ามลบ" เท่ากันทุกตำแหน่ง
--   และกฎที่บังคับด้วย trigger ต้องปิดไม่ได้จากหน้า Settings
--   จึงไม่เป็น SECURITY DEFINER และต้องถูก revoke execute ในไฟล์เดียวกัน
--   (default privileges ของ 20261007000001 เปิด execute ให้ authenticated
--    กับฟังก์ชันใหม่ทุกตัว → ไม่ถอนทันทีคือเปิดช่องใหม่แทนที่จะปิดช่องเก่า)
--
-- ------------------------------------------------------------
-- ถ้าวันหนึ่งต้องลบใบยืนยันเงิน / แถว audit จริงๆ (ข้อมูลผิดจนต้องล้าง)
-- ------------------------------------------------------------
--   **ทำผ่าน migration เท่านั้น** — เขียนไฟล์ใหม่ที่
--     1) drop trigger ที่กันอยู่
--     2) ลบเฉพาะแถวที่ระบุ id ไว้ตรงๆ ในไฟล์ (ไม่ใช่ลบตามเงื่อนไขกว้างๆ)
--     3) สร้าง trigger กลับทันทีในไฟล์เดียวกัน
--   พร้อมเหตุผลที่หัวไฟล์ว่าใครตัดสินและทำไม
--   **ห้ามปิด trigger ทิ้งไว้** และห้ามเปิดเส้นทางลบจากหน้าจอ/service_role
--
-- ------------------------------------------------------------
-- ย้อนกลับ (rollback)
-- ------------------------------------------------------------
--   -- drop trigger if exists trg_forbid_delete_confirmation on sri_os.cash_confirmations;
--   -- drop trigger if exists trg_forbid_truncate            on sri_os.cash_confirmations;
--   -- drop trigger if exists trg_audit_cash_confirmations   on sri_os.cash_confirmations;
--   -- drop trigger if exists trg_forbid_change_audit        on sri_os.audit_log;
--   -- drop trigger if exists trg_audit_period_closes        on sri_os.period_closes;
--   -- drop trigger if exists trg_forbid_truncate            on sri_os.period_closes;
--   -- drop function if exists sri_os.fn_forbid_delete_confirmation();
--   -- drop function if exists sri_os.fn_forbid_change_audit();
--   -- (**ห้าม** drop trg_forbid_truncate บน audit_log — ของ 20261007000000
--   --  ไฟล์นี้แค่ประกาศซ้ำให้รันเดี่ยวได้ ย้อนแล้วจะเปิดช่องของไฟล์อื่น)
--   -- ย้อนแล้ว: postgres/service_role ลบใบยืนยันเงินและแถว audit ได้อีก
--   --           และการเปิดงวดใหม่กลับไปไม่เหลือร่องรอย = ช่องเดิมทั้งสามข้อ
--
-- idempotent: create or replace function · drop trigger if exists ก่อน create ·
--   ไม่แตะข้อมูล ไม่เพิ่ม/ลบคอลัมน์ ไม่แตะ policy · revoke ซ้ำได้
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 1 · cash_confirmations · ห้าม DELETE ทุก role รวม superuser
-- ============================================================
create or replace function fn_forbid_delete_confirmation() returns trigger
language plpgsql set search_path = '' as $fn$
begin
  raise exception 'กฎเหล็กข้อ 1 / Money Invariant 4+5: ลบใบยืนยันเงินเข้า-ออกไม่ได้ทุกกรณีทุกผู้ใช้ (รวมเจ้าของฐานข้อมูล) · นี่คือหลักฐานว่าเงินเคลื่อนจริงและเป็นฐานของการกระทบยอดธนาคาร · ยืนยันผิดให้บันทึกรายการกลับ/แก้ที่แถวเดิมด้วยสิทธิ์ cash.confirm แล้วให้ audit_log เก็บ before-after ไว้ (id % · บัญชีธนาคาร % · ยอดที่คาด % · ยอดจริง % · วันที่เงินเข้า-ออก %)',
    old.id, old.bank_account_id, old.expected_amount,
    coalesce(old.actual_amount::text, '(ยังไม่ยืนยัน)'),
    coalesce(old.actual_date::text, '(ยังไม่ยืนยัน)');
end $fn$;

comment on function fn_forbid_delete_confirmation() is
  'ห้ามลบแถวใน cash_confirmations ทุก role รวม superuser · ตารางนี้คือหลักฐานว่าเงินเคลื่อนจริง (ฐานของ Money Invariant 5) · ยกเลิกการยืนยันให้ทำด้วยรายการกลับ/แก้แถวเดิมที่ audit จับได้ ไม่ใช่ลบ';

revoke all on function fn_forbid_delete_confirmation() from public;
do $$ begin
  execute 'revoke all on function sri_os.fn_forbid_delete_confirmation() from anon, authenticated';
exception when undefined_object then
  raise notice 'ไม่มี role anon/authenticated ในคลัสเตอร์นี้ — ข้าม revoke';
end $$;

drop trigger if exists trg_forbid_delete_confirmation on cash_confirmations;
create trigger trg_forbid_delete_confirmation
  before delete on cash_confirmations
  for each row execute function fn_forbid_delete_confirmation();

-- TRUNCATE ไม่ยิง row trigger และไม่ผ่าน RLS → ล้างใบยืนยันทั้งตารางได้รวดเดียว
-- ใช้ fn_forbid_truncate ตัวเดียวกับตารางสมุดบัญชี (20261007000000) ไม่เขียนกฎซ้ำ
drop trigger if exists trg_forbid_truncate on cash_confirmations;
create trigger trg_forbid_truncate
  before truncate on cash_confirmations
  for each statement execute function fn_forbid_truncate();

-- audit ที่ไม่มีมาก่อน · INSERT = ยืนยันเงิน · UPDATE = แก้/ยกเลิกการยืนยัน
-- (ซึ่งเป็นทางออกแทนการลบ จึงต้องเห็น before-after)
-- ประกาศ DELETE ไว้ด้วยโดยเจตนา: ตามปกติจะไม่ยิงเลยเพราะ before-delete ข้างบน
-- raise ก่อน แต่ถ้าวันหนึ่งมี migration ถอด trigger กันลบออกชั่วคราวตามขั้นตอน
-- ที่หัวไฟล์ระบุ การลบครั้งนั้นต้องยังเหลือร่องรอย
drop trigger if exists trg_audit_cash_confirmations on cash_confirmations;
create trigger trg_audit_cash_confirmations
  after insert or update or delete on cash_confirmations
  for each row execute function fn_audit();

-- ============================================================
-- 2 · audit_log · append-only จริง — ห้าม DELETE และ UPDATE
--     ข้อความ error บอก tg_op เพราะสองคำสั่งนี้คนละเจตนา แต่ผลเท่ากัน
--     (แก้ทับก็คือลบของเดิม)
-- ============================================================
create or replace function fn_forbid_change_audit() returns trigger
language plpgsql set search_path = '' as $fn$
begin
  raise exception 'กฎเหล็กข้อ 1 / Money Invariant 4: % แถวใน audit_log ไม่ได้ทุกกรณีทุกผู้ใช้ (รวมเจ้าของฐานข้อมูล) · ร่องรอยที่ลบหรือแก้ได้ไม่ใช่ร่องรอย — คนที่ทำผิดจะลบหลักฐานของตัวเองได้ · ตารางนี้เพิ่มได้เท่านั้น (id % · ตาราง % · แถว % · การกระทำ % · เมื่อ %)',
    case tg_op when 'DELETE' then 'ลบ' when 'UPDATE' then 'แก้' else tg_op end,
    old.id, old.table_name, old.row_id, old.action, old.at;
end $fn$;

comment on function fn_forbid_change_audit() is
  'audit_log เพิ่มได้เท่านั้น · ห้าม DELETE/UPDATE ทุก role รวม superuser · ถ้าลบ audit ได้ การกันลบของทุกตารางข้างบนก็ไม่มีความหมาย';

revoke all on function fn_forbid_change_audit() from public;
do $$ begin
  execute 'revoke all on function sri_os.fn_forbid_change_audit() from anon, authenticated';
exception when undefined_object then
  raise notice 'ไม่มี role anon/authenticated ในคลัสเตอร์นี้ — ข้าม revoke';
end $$;

-- trigger เดียวคุมทั้งสองคำสั่ง — กฎเดียวกันห้ามเขียนสองที่
drop trigger if exists trg_forbid_change_audit on audit_log;
create trigger trg_forbid_change_audit
  before delete or update on audit_log
  for each row execute function fn_forbid_change_audit();

-- TRUNCATE มีอยู่แล้วจาก 20261007000000 · ประกาศซ้ำให้ไฟล์นี้รันเดี่ยวก็ได้สภาพเดียวกัน
drop trigger if exists trg_forbid_truncate on audit_log;
create trigger trg_forbid_truncate
  before truncate on audit_log
  for each statement execute function fn_forbid_truncate();

-- ============================================================
-- 3 · period_closes · **คงการลบไว้ตามเจตนา** (period.reopen) เพิ่มแต่ร่องรอย
--     ไม่มี fn_forbid_delete_* ที่นี่โดยตั้งใจ · ดูเหตุผลเต็มที่หัวไฟล์ข้อ (3)
-- ============================================================
drop trigger if exists trg_audit_period_closes on period_closes;
create trigger trg_audit_period_closes
  after insert or update or delete on period_closes
  for each row execute function fn_audit();

-- กัน TRUNCATE เท่านั้น (ไม่ใช่ DELETE): row trigger ข้างบนไม่ยิงตอน TRUNCATE
-- → เปิดทุกงวดของทุกผู้ถือพร้อมกันแบบไร้ร่องรอยได้ ซึ่งลบล้าง audit ที่เพิ่งเพิ่ม
drop trigger if exists trg_forbid_truncate on period_closes;
create trigger trg_forbid_truncate
  before truncate on period_closes
  for each statement execute function fn_forbid_truncate();

-- ============================================================
-- 4 · guard ของไฟล์นี้เอง — ถ้ากฎไม่ติดจริง migration ต้องพังทันที
--     ไม่ใช่รอให้เทสต์จับทีหลัง (ไฟล์นี้อาจถูก apply บน project ก่อนเทสต์)
--     ตรวจทั้งสองทิศ: ของที่ต้องมี **และของที่ต้องไม่มี**
-- ============================================================
do $$
declare n int; v text;
begin
  -- (ก) cash_confirmations: กันลบ + กัน truncate + audit ครบสามตัว
  select count(*) into n
    from pg_trigger tg
   where tg.tgrelid = 'sri_os.cash_confirmations'::regclass
     and not tg.tgisinternal
     and tg.tgname in ('trg_forbid_delete_confirmation', 'trg_forbid_truncate',
                       'trg_audit_cash_confirmations');
  if n <> 3 then
    raise exception 'trigger บน cash_confirmations ไม่ครบ (เจอ % จาก 3)', n;
  end if;

  -- (ข) audit_log: กัน DELETE และ UPDATE ด้วย trigger ตัวเดียว + กัน truncate
  select count(*) into n
    from pg_trigger tg
   where tg.tgrelid = 'sri_os.audit_log'::regclass
     and tg.tgname = 'trg_forbid_change_audit'
     and (tg.tgtype & 8) <> 0      -- DELETE
     and (tg.tgtype & 16) <> 0     -- UPDATE
     and (tg.tgtype & 2) <> 0      -- BEFORE
     and (tg.tgtype & 1) <> 0;     -- FOR EACH ROW
  if n <> 1 then
    raise exception 'trg_forbid_change_audit ต้องเป็น before delete or update for each row (เจอ %)', n;
  end if;
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'sri_os.audit_log'::regclass
                    and tgname = 'trg_forbid_truncate') then
    raise exception 'audit_log ไม่มี trigger กัน TRUNCATE';
  end if;

  -- (ค) period_closes: ต้องมี audit + กัน truncate แต่ **ต้องไม่มี** trigger กัน DELETE
  --     ข้อนี้คือจุดที่ "กันแน่นเกิน" จะผิด → guard ตรวจไว้ไม่ให้ใครเผลอเติม
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'sri_os.period_closes'::regclass
                    and tgname = 'trg_audit_period_closes') then
    raise exception 'period_closes ไม่มี audit trigger';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'sri_os.period_closes'::regclass
                    and tgname = 'trg_forbid_truncate') then
    raise exception 'period_closes ไม่มี trigger กัน TRUNCATE';
  end if;
  select string_agg(tg.tgname, ', ') into v
    from pg_trigger tg
    join pg_proc p on p.oid = tg.tgfoid
   where tg.tgrelid = 'sri_os.period_closes'::regclass
     and not tg.tgisinternal
     and (tg.tgtype & 8) <> 0                  -- DELETE
     and p.proname <> 'fn_audit';              -- audit บันทึกได้ ไม่ใช่ขัดขวาง
  if v is not null then
    raise exception 'period_closes มี trigger ขัดขวาง DELETE: % · การลบที่นี่คือ "เปิดงวดใหม่" ซึ่งเป็นเจตนาของระบบ (สิทธิ์ period.reopen) ห้ามปิด', v;
  end if;
  if not exists (select 1 from pg_policies
                  where schemaname = 'sri_os' and tablename = 'period_closes'
                    and cmd = 'DELETE') then
    raise exception 'policy period_closes_reopen (FOR DELETE) หายไป → เปิดงวดใหม่ไม่ได้';
  end if;

  -- (ง) ฟังก์ชันกันลบทั้งสองตัวต้องเรียกตรงไม่ได้ และต้องไม่เป็น SECURITY DEFINER
  --     และต้องไม่เรียก fn_can (การห้ามลบไม่ขึ้นกับสิทธิ์ · เทสต์ข้อ 10 / S18)
  select string_agg(p.proname, ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.proname in ('fn_forbid_delete_confirmation', 'fn_forbid_change_audit')
     and (p.prosecdef
       or p.prosrc ~* 'fn_can'
       or has_function_privilege('public', p.oid, 'execute'));
  if v is not null then
    raise exception 'ฟังก์ชันกันลบหลวมเกินไป (SECURITY DEFINER / เรียก fn_can / PUBLIC execute): %', v;
  end if;

  raise notice 'guard · cash_confirmations กัน DELETE+TRUNCATE และมี audit แล้ว · audit_log เพิ่มได้เท่านั้น · period_closes ยังเปิดงวดใหม่ได้และมีร่องรอยแล้ว';
end $$;
