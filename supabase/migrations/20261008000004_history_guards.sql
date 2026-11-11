-- ============================================================
-- SRI OS · ปิดช่องที่เหลือจากรอบก่อน (ไล่เจอจาก pg_policies/pg_trigger จริงแล้ว
--   รายงานไว้แต่ยังไม่ได้แก้) · ตัดสินแล้ว 4 ข้อ
--   เทสต์: supabase/tests/zz_history_guards_test.sql
--   รุ่นก่อนหน้าของเรื่องเดียวกัน: 20261008000002 (asset_valuations) ·
--   20261008000003 (cash_confirmations · audit_log · period_closes)
--
-- สี่ข้อนี้ **ตัดสินต่างกันตามลักษณะของตาราง ไม่ใช่เหมารวม** ใครแก้ต่อให้อ่านให้จบ
--
-- ------------------------------------------------------------
-- (1) contracts · schedules — ปิด DELETE + TRUNCATE + เพิ่ม audit
--                             แต่ **ห้ามปิด UPDATE**
-- ------------------------------------------------------------
--   สภาพเดิม: ไม่มี policy DELETE (authenticated ได้ 0 แถวเงียบๆ) · **ไม่มี trigger**
--   → postgres / role ที่ bypassrls ลบสัญญาและ **แถวตารางงวดทุกแถว** ได้
--   และ **ไม่มี audit trigger เลยทั้งสองตาราง** = หายไปโดยไม่เหลือร่องรอยแม้ใน audit_log
--   (ช่องเดียวกับ 20261008000002/3 แต่ตารางนี้ใหญ่กว่า เพราะเก็บทั้งเงินต้น
--    อัตราดอกเบี้ย และตารางงวด ซึ่ง **เกณฑ์ตั้งค้างรับ-ค้างจ่ายใช้** (D-087 ·
--    txn_types.can_accrue) และเป็นฐานของการตั้งรายการอัตโนมัติ · ลบแล้วยอดค้าง
--    และงวดที่ควรเกิดหายไปพร้อมกัน แล้วไม่มีใครรู้ว่าเคยมี)
--
--   **ความต่างจาก asset_valuations ที่ต้องรักษาไว้ให้ได้**: ประวัติการตีราคา
--   "เพิ่มได้เท่านั้น" (20261008000001 ปิด UPDATE ไปแล้ว) แต่สัญญาและตารางงวดเป็น
--   **ของที่แก้ไขได้ตามปกติ** — เลื่อนงวด · แก้อัตรา · แก้เงินต้น · ปิดสัญญา ·
--   เพิ่มงวดใหม่ ทั้งหมดนี้คือการบริหารสัญญาที่เกิดขึ้นจริงทุกเดือน
--   ไฟล์นี้จึง **ไม่แตะ policy และไม่เพิ่ม trigger ใดๆ ที่ขัดขวาง UPDATE/INSERT**
--   (policy contracts_update · schedules_update ของ 20261008000000 ยังเป็นด่านเดียว)
--   ถ้าปิด UPDATE ที่นี่ = บริหารสัญญาไม่ได้ทั้งระบบ (บทเรียนข้อ 7)
--   guard ท้ายไฟล์ตรวจทั้งสองทิศ: ของที่ต้องมี **และของที่ต้องไม่มี**
--
--   **ทางออกที่ถูกต้องเมื่อไม่ต้องการงวดนั้นแล้ว — เขียนไว้ที่นี่เพราะไม่งั้นคนใน
--   อนาคตจะไปปิด trigger ทิ้ง:** ไม่ลบแถว แต่
--     - งวดที่ไม่เกิดจริง → `schedules.status = 'waived'` (มีในตารางสถานะอยู่แล้ว
--       และเทสต์ S14 ของ W1 ยืนยันว่าเปลี่ยนได้)
--     - สัญญาที่จบ/ยกเลิก → `contracts.status = 'closed'` (หรือ 'defaulted')
--   ทั้งสองทางเหลือร่องรอยใน audit_log แล้วเพราะไฟล์นี้เพิ่ม trg_audit_* ให้
--
--   **ข้อที่ยัง "ไม่ได้ตัดสิน" และตั้งใจไม่ตัดสินเองในไฟล์นี้**: สัญญาที่คีย์ผิด
--   และ **ยังไม่มี posting ผูกอยู่เลย** ควรลบทิ้งได้หรือไม่ (ตอนนี้: ลบไม่ได้
--   ต้องตั้ง status = 'closed' ทิ้งไว้) → รายงานให้ตัดสิน ห้ามเปิดช่องเองเพราะ
--   เงื่อนไข "ยังไม่มี posting" ต้องนิยามให้ครบ (transactions.contract_id ·
--   schedules.draft_entry_id · draft_entries ที่อ้างถึง) ไม่งั้นได้ช่องกว้างกว่าที่คิด
--
--   หมายเหตุขา cascade: schedules.contract_id เป็น `on delete cascade`
--   → ไฟล์นี้กัน **ทั้งสองตาราง** ไม่ใช่กันแต่ตารางแม่ ถ้ากันแต่ contracts แล้ววันหนึ่ง
--   มี migration ถอดด่านตารางแม่ออกชั่วคราว แถวงวดจะหายตามไปเงียบๆ (เทสต์ H6 กันข้อนี้)
--
-- ------------------------------------------------------------
-- (2) TRUNCATE — กันให้ครบ **ทุกตารางใน sri_os** ไม่ใช่ทีละตารางที่นึกออก
-- ------------------------------------------------------------
--   สภาพเดิม: กันแล้ว 5 ตาราง (transactions · transaction_lines · audit_log ·
--   asset_valuations · cash_confirmations · period_closes) เหลืออีก 19 ตาราง
--   รวม draft_entries · assets · bank_accounts · asset_drafts ที่ **มี audit trigger
--   อยู่แล้วแต่ไม่มีอะไรกัน TRUNCATE** → TRUNCATE ไม่ยิง row trigger แปลว่า
--   ล้างของที่ audit พึ่งพาได้ในคำสั่งเดียวโดยไม่เหลือร่องรอย = audit นั้นไม่จริง
--
--   **ตัดสินให้กันทุกตาราง ไม่มีข้อยกเว้น** เพราะ TRUNCATE ไม่ใช่เส้นทางของระบบนี้
--   ที่ไหนเลย (ไล่แล้ว: src/** · scripts/** ไม่มีคำสั่ง TRUNCATE แม้ที่เดียว ·
--   sync:rules ใช้ upsert) ส่วนตารางอ้างอิง/ตารางกฎก็อ่านได้เขียนไม่ได้อยู่แล้ว
--   การยกเว้นตารางไหนไว้ = ต้องมาเถียงกันทุกครั้งว่าตารางใหม่อยู่กลุ่มไหน
--   ซึ่งเป็นต้นเหตุที่ทำให้ 19 ตารางนี้หลุดมาตั้งแต่แรก
--
--   **ไล่จาก pg_class ไม่ใช่ไล่รายชื่อที่พิมพ์มือ** → ตารางที่มีอยู่วันนี้ครบแน่
--   ส่วนตารางใหม่ในอนาคต: guard ท้ายไฟล์ + เทสต์ H8 **แดงทันทีถ้ามีตารางที่ยังไม่กัน**
--   (เทสต์คือชั้นที่จับของใหม่จริง เพราะ migration นี้รันครั้งเดียว ส่วน H8 รันทุกรอบ
--    บนสคีมาที่รวม migration ใหม่ทุกไฟล์แล้ว)
--   ตาราง partitioned ติด trigger ของ TRUNCATE ที่ตารางแม่ไม่ได้ → ถ้ามีวันนั้น
--   ไฟล์นี้และ H8 จะพังให้รู้ตัว ไม่ใช่ปล่อยผ่านเงียบๆ
--
-- ------------------------------------------------------------
-- (3) audit_log — เพิ่ม index ตามเวลา (เท่าที่ปลอดภัย)
-- ------------------------------------------------------------
--   ไม่มี index บน at → คำถาม "สัปดาห์นี้มีอะไรเปลี่ยน" ต้อง seq scan ทั้งตาราง
--   ที่โตขึ้นเรื่อยๆ และลบไม่ได้ (append-only ตาม 20261008000003)
--   เพิ่มสอง index: (at desc) สำหรับไล่ตามเวลาทั้งระบบ และ (table_name, at desc)
--   สำหรับ "ตารางนี้สัปดาห์นี้เปลี่ยนอะไร" ซึ่งเป็นคำถามที่ถามจริงเวลาตัวเลขเพี้ยน
--   (index เดิม (table_name, row_id) ตอบ "แถวนี้เคยถูกแก้อะไร" — คนละคำถาม จึงไม่ทับกัน)
--
--   **index ไม่เอาข้อมูลออกจากตาราง** จึงทำได้เลย · ไม่ใช่ `concurrently` โดยตั้งใจ
--   เพราะ migration รันในธุรกรรมเดียว และตารางนี้ยังเล็ก
--
--   **สามข้อที่ห้ามทำ และไม่ได้ทำในไฟล์นี้** (ต้องให้ลูกพี่เห็นก่อน):
--   เก็บเฉพาะคอลัมน์ที่เปลี่ยน · partition ตาราง · ย้ายของเก่าไปตารางเก็บถาวร
--   ทั้งสามเปลี่ยนรูปหรือย้าย **หลักฐานทางการเงิน** ออกจากตารางที่กันไว้
--
-- ------------------------------------------------------------
-- (4) แก้คอมเมนต์ของ 20261008000003 ที่ชี้ไปทางออกที่ไม่มีจริง
-- ------------------------------------------------------------
--   ไฟล์นั้นเขียนว่าการยกเลิกการยืนยันให้ "บันทึกรายการกลับ" แต่ตรวจแล้วพบว่า
--   **ทำไม่ได้**: cash_confirmations ไม่มีคอลัมน์ status/void และ `src/**`
--   ไม่อ้าง cash_confirmations เลยแม้แถวเดียว → ไม่มีทั้งที่เก็บสถานะและหน้าจอ
--   ของที่มีจริงคือ policy `confirmations_update` (สิทธิ์ `cash.confirm`) =
--   **แก้ที่แถวเดิม** ซึ่ง 20261008000003 ทำให้ audit จับได้แล้ว
--
--   คอมเมนต์ที่ชี้ไปทางที่ไม่มีจริงอันตราย เพราะคนในอนาคตจะเชื่อว่ามีแล้วไม่เอะใจ
--   → ไฟล์นี้แก้ข้อความให้ตรงความจริงที่ **สามที่ที่หาเจอจาก DB โดยตรง**:
--   comment ของตาราง · comment ของฟังก์ชัน · comment ของ trigger
--   และแก้ **ข้อความ error ที่ผู้ใช้เห็นตอนถูกปฏิเสธ** ด้วย เพราะนั่นคือข้อความที่
--   คนอ่านก่อนตัดสินใจไปปิด trigger (ไฟล์เดิมที่ commit แล้วไม่ถูกแตะ —
--   `create or replace` ทับใน migration ใหม่ตามเส้นทางปกติของสคีมา)
--   **ไม่สร้างคอลัมน์หรือเส้นทางใหม่** ในไฟล์นี้: จะรับ "UPDATE ที่มีร่องรอย" เป็น
--   ทางการ หรือจะทำเส้นทางรายการกลับจริง ต้องตัดสินก่อน (บทเรียนข้อ 7)
--
-- ------------------------------------------------------------
-- ทำไม trigger ไม่ใช่ RLS/revoke (หลักเดียวกับ 20261007000000 · 2/3 ของรอบก่อน)
-- ------------------------------------------------------------
--   RLS มีผลกับ authenticated เท่านั้น · service_role และเจ้าของฐานข้อมูลอยู่นอก
--   ชั้นนั้นทั้งหมด · ฟังก์ชันกันลบในไฟล์นี้ **ไม่ถามสิทธิ์และไม่อ่านตารางไหนเลย**
--   (ห้ามเรียกฟังก์ชันตรวจสิทธิ์ — เทสต์ S18 / H0 / H0b กันอยู่) เพราะ "ห้ามลบ"
--   เท่ากันทุกตำแหน่ง และกฎที่บังคับด้วย trigger ต้องปิดไม่ได้จากหน้า Settings
--   จึงไม่เป็น SECURITY DEFINER และต้องถูก revoke execute ในไฟล์เดียวกัน
--   (default privileges ของ 20261007000001 เปิด execute ให้ authenticated
--    กับฟังก์ชันใหม่ทุกตัว → ไม่ถอนทันทีคือเปิดช่องใหม่แทนที่จะปิดช่องเก่า)
--
-- ------------------------------------------------------------
-- ถ้าวันหนึ่งต้องลบสัญญา/แถวตารางงวดจริงๆ (ข้อมูลผิดจนต้องล้าง)
-- ------------------------------------------------------------
--   **ทำผ่าน migration เท่านั้น** — เขียนไฟล์ใหม่ที่
--     1) drop trigger ที่กันอยู่ (ทั้ง contracts **และ** schedules เพราะกันสองชั้น)
--     2) ลบเฉพาะแถวที่ระบุ id ไว้ตรงๆ ในไฟล์ (ไม่ใช่ลบตามเงื่อนไขกว้างๆ)
--     3) สร้าง trigger กลับทันทีในไฟล์เดียวกัน
--   พร้อมเหตุผลที่หัวไฟล์ว่าใครตัดสินและทำไม
--   **ห้ามปิด trigger ทิ้งไว้** และห้ามเปิดเส้นทางลบจากหน้าจอ/service_role
--
-- ------------------------------------------------------------
-- ย้อนกลับ (rollback)
-- ------------------------------------------------------------
--   -- drop trigger if exists trg_forbid_delete_contract on sri_os.contracts;
--   -- drop trigger if exists trg_audit_contracts         on sri_os.contracts;
--   -- drop trigger if exists trg_forbid_delete_schedule  on sri_os.schedules;
--   -- drop trigger if exists trg_audit_schedules         on sri_os.schedules;
--   -- drop function if exists sri_os.fn_forbid_delete_contract();
--   -- drop function if exists sri_os.fn_forbid_delete_schedule();
--   -- ถอด trigger กัน TRUNCATE ที่ไฟล์นี้เพิ่ม (19 ตาราง) — **ห้ามถอดของ 5 ตาราง
--   -- ที่มาก่อน** (transactions · transaction_lines · audit_log · asset_valuations ·
--   -- cash_confirmations · period_closes) เพราะเป็นของไฟล์อื่น:
--   --   do $$ declare r text; begin
--   --     foreach r in array array['app_users','asset_categories','asset_classes',
--   --       'asset_drafts','assets','bank_accounts','chart_of_accounts','contact_links',
--   --       'contacts','contracts','draft_entries','owners','permissions',
--   --       'role_permissions','roles','schedules','settings','txn_types',
--   --       'user_owner_access'] loop
--   --       execute format('drop trigger if exists trg_forbid_truncate on sri_os.%I', r);
--   --     end loop; end $$;
--   -- drop index if exists sri_os.audit_log_at_idx;
--   -- drop index if exists sri_os.audit_log_table_at_idx;
--   -- คืนข้อความเดิมของ fn_forbid_delete_confirmation + comment:
--   --   รัน section 1 ของ 20261008000003_delete_guards.sql ซ้ำ
--   --   (แต่จะได้คอมเมนต์ที่ชี้ไปทาง "รายการกลับ" ซึ่งยังไม่มีจริงกลับมา)
--   -- ย้อนแล้ว: postgres/service_role ลบสัญญาและแถวตารางงวดได้อีก (ยอดค้างรับ-ค้างจ่าย
--   --           และงวดที่ควรเกิดหายไร้ร่องรอย) · TRUNCATE ล้าง 19 ตารางได้อีก
--
-- idempotent: create or replace function · drop trigger if exists ก่อน create ·
--   create index if not exists · ไม่แตะข้อมูล ไม่เพิ่ม/ลบคอลัมน์ ไม่แตะ policy ·
--   revoke ซ้ำได้
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 1 · contracts · ห้าม DELETE ทุก role รวม superuser
--     ฟิลด์เงินทุกตัวของตารางนี้ nullable → ข้อความต้องไม่ล้มเพราะ null
--     (เคสสัญญาที่คีย์ผิดยังไม่กรอกอะไร = เคส "ไม่ส่งข้อมูล" ของตารางนี้)
-- ============================================================
create or replace function fn_forbid_delete_contract() returns trigger
language plpgsql set search_path = '' as $fn$
begin
  raise exception 'กฎเหล็กข้อ 1 / Money Invariant 4: ลบสัญญาไม่ได้ทุกกรณีทุกผู้ใช้ (รวมเจ้าของฐานข้อมูล) · สัญญาเก็บเงินต้น-อัตราดอกเบี้ย-ตารางงวด ซึ่งเกณฑ์ตั้งค้างรับ-ค้างจ่ายและการตั้งรายการอัตโนมัติใช้ · สัญญาที่จบหรือยกเลิกให้ตั้ง status = closed/defaulted แล้วแก้ที่แถวเดิม (แก้ได้ตามปกติ และ audit_log เก็บ before-after) · งวดที่ไม่เกิดจริงตั้ง status = waived (id % · รหัส % · ประเภท % · เงินต้น % · อัตรา % · สถานะ % · จำนวนงวดที่ผูกอยู่ %)',
    old.id,
    coalesce(old.code, '(ไม่ระบุรหัส)'),
    old.type,
    coalesce(old.principal::text, '(ไม่ระบุ)'),
    coalesce(old.rate::text, '(ไม่ระบุ)'),
    old.status,
    (select count(*) from sri_os.schedules s where s.contract_id = old.id);
end $fn$;

comment on function fn_forbid_delete_contract() is
  'ห้ามลบแถวใน contracts ทุก role รวม superuser · สัญญาคือฐานของยอดค้างรับ-ค้างจ่ายและตารางงวด · **UPDATE ยังเปิดโดยเจตนา** (เลื่อนงวด/แก้อัตรา/ปิดสัญญาเป็นงานประจำ) ต่างจาก asset_valuations ที่เพิ่มได้เท่านั้น · ต้องลบจริงให้ทำผ่าน migration ที่ drop trigger ของทั้ง contracts และ schedules + ลบตาม id + สร้าง trigger คืนในไฟล์เดียวกัน';

revoke all on function fn_forbid_delete_contract() from public;
do $$ begin
  execute 'revoke all on function sri_os.fn_forbid_delete_contract() from anon, authenticated';
exception when undefined_object then
  raise notice 'ไม่มี role anon/authenticated ในคลัสเตอร์นี้ — ข้าม revoke';
end $$;

drop trigger if exists trg_forbid_delete_contract on contracts;
create trigger trg_forbid_delete_contract
  before delete on contracts
  for each row execute function fn_forbid_delete_contract();

comment on trigger trg_forbid_delete_contract on contracts is
  'ด่าน DELETE ระดับแถว (ไม่ขึ้นกับ RLS/grant) · เส้นทางที่ถูกต้องคือแก้ที่แถวเดิม/เปลี่ยน status ไม่ใช่ลบ';

-- audit ที่ไม่มีมาก่อนทั้งตาราง · INSERT = สร้างสัญญา · UPDATE = แก้เงื่อนไข/ปิดสัญญา
-- (ซึ่งเป็นทางออกแทนการลบ จึงต้องเห็น before-after)
-- ประกาศ DELETE ไว้ด้วยโดยเจตนา: ตามปกติจะไม่ยิงเลยเพราะ before-delete ข้างบน raise
-- ก่อน แต่ถ้าวันหนึ่งมี migration ถอด trigger กันลบออกชั่วคราวตามขั้นตอนที่หัวไฟล์ระบุ
-- การลบครั้งนั้นต้องยังเหลือร่องรอย
drop trigger if exists trg_audit_contracts on contracts;
create trigger trg_audit_contracts
  after insert or update or delete on contracts
  for each row execute function fn_audit();

-- TRUNCATE ไม่ยิง row trigger และไม่ผ่าน RLS → ล้างสัญญาทั้งตารางได้รวดเดียว
-- ใช้ fn_forbid_truncate ตัวเดียวกับตารางสมุดบัญชี (20261007000000) ไม่เขียนกฎซ้ำ
-- (ข้อ 3 ของไฟล์นี้ไล่ให้ครบทุกตารางอีกชั้น · ประกาศที่นี่ให้อ่านจบในหัวข้อเดียว)
drop trigger if exists trg_forbid_truncate on contracts;
create trigger trg_forbid_truncate
  before truncate on contracts
  for each statement execute function fn_forbid_truncate();

-- ============================================================
-- 2 · schedules · ห้าม DELETE ทุก role รวม superuser
--     กันที่ตารางลูกด้วย ไม่ใช่กันแต่ตารางแม่: contract_id เป็น on delete cascade
--     → ถ้ากันแต่ contracts แล้ววันหนึ่งด่านตารางแม่ถูกถอดชั่วคราว แถวงวดจะหาย
--     ตามไปเงียบๆ ทั้งที่เป็นยอดเงินคนละชุด (เทสต์ H6)
-- ============================================================
create or replace function fn_forbid_delete_schedule() returns trigger
language plpgsql set search_path = '' as $fn$
begin
  raise exception 'กฎเหล็กข้อ 1 / Money Invariant 4: ลบแถวตารางงวดไม่ได้ทุกกรณีทุกผู้ใช้ (รวมเจ้าของฐานข้อมูล) · งวดคือสิ่งที่บอกว่าเงินควรเข้า-ออกเมื่อไรเท่าไร และเป็นฐานของยอดค้างรับ-ค้างจ่าย · งวดที่ไม่เกิดจริงให้ตั้ง status = waived (แก้ที่แถวเดิมได้ตามปกติ และ audit_log เก็บ before-after) · เลื่อนงวดให้แก้ due_date (id % · สัญญา % · งวดที่ % · ครบกำหนด % · ยอด % = เงินต้น % + ดอกเบี้ย % · สถานะ % · ร่างที่ผูกอยู่ %)',
    old.id, old.contract_id, old.period, old.due_date,
    old.expected_amount, old.principal_amount, old.interest_amount, old.status,
    coalesce(old.draft_entry_id::text, '(ยังไม่มีร่าง)');
end $fn$;

comment on function fn_forbid_delete_schedule() is
  'ห้ามลบแถวใน schedules ทุก role รวม superuser · งวดที่ไม่เกิดจริงใช้ status = waived ไม่ใช่ลบแถว · **UPDATE ยังเปิดโดยเจตนา** (เลื่อนงวด/แก้ยอด/waive เป็นงานประจำ) · กันขา cascade จาก contracts ด้วย';

revoke all on function fn_forbid_delete_schedule() from public;
do $$ begin
  execute 'revoke all on function sri_os.fn_forbid_delete_schedule() from anon, authenticated';
exception when undefined_object then
  raise notice 'ไม่มี role anon/authenticated ในคลัสเตอร์นี้ — ข้าม revoke';
end $$;

drop trigger if exists trg_forbid_delete_schedule on schedules;
create trigger trg_forbid_delete_schedule
  before delete on schedules
  for each row execute function fn_forbid_delete_schedule();

comment on trigger trg_forbid_delete_schedule on schedules is
  'ด่าน DELETE ระดับแถว · กันทั้งการลบตรงและขา cascade จาก contracts · งวดที่ไม่เกิดจริงใช้ status = waived';

drop trigger if exists trg_audit_schedules on schedules;
create trigger trg_audit_schedules
  after insert or update or delete on schedules
  for each row execute function fn_audit();

drop trigger if exists trg_forbid_truncate on schedules;
create trigger trg_forbid_truncate
  before truncate on schedules
  for each statement execute function fn_forbid_truncate();

-- ============================================================
-- 3 · TRUNCATE · ไล่ให้ครบ **ทุกตารางใน sri_os**
--     ไล่จาก pg_class ไม่ใช่รายชื่อที่พิมพ์มือ (รายชื่อมือคือต้นเหตุที่ 19 ตารางหลุด)
--     ของที่มีอยู่แล้วชื่อเดียวกัน trigger เดียวกัน → drop/create ซ้ำได้ ไม่เพิ่มของซ้อน
-- ============================================================
do $$
declare r record; n int := 0; v text;
begin
  -- ตาราง partitioned ติด TRUNCATE trigger ที่ตารางแม่ไม่ได้ → ต้องรู้ตัวก่อนใช้งาน
  select string_agg(c.relname, ', ') into v
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os' and c.relkind = 'p';
  if v is not null then
    raise exception 'มีตาราง partitioned ใน sri_os (%) · trigger กัน TRUNCATE ติดกับตารางแม่ไม่ได้ → ต้องตัดสินวิธีกันก่อน ไม่ใช่ปล่อยผ่านเงียบๆ', v;
  end if;

  for r in
    select c.relname from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
     where ns.nspname = 'sri_os' and c.relkind = 'r' order by c.relname
  loop
    execute format('drop trigger if exists trg_forbid_truncate on sri_os.%I', r.relname);
    execute format('create trigger trg_forbid_truncate before truncate on sri_os.%I '
                   'for each statement execute function sri_os.fn_forbid_truncate()', r.relname);
    n := n + 1;
  end loop;
  raise notice 'กัน TRUNCATE ให้ครบ % ตารางใน sri_os (ไล่จาก pg_class)', n;
end $$;

-- ============================================================
-- 4 · audit_log · index ตามเวลา
--     ไม่ย้าย ไม่ยุบ ไม่ตัดคอลัมน์ — index เท่านั้น (ไม่มีข้อมูลออกจากตาราง)
-- ============================================================
create index if not exists audit_log_at_idx       on audit_log(at desc);
create index if not exists audit_log_table_at_idx on audit_log(table_name, at desc);

comment on index audit_log_at_idx is
  '"ช่วงเวลานี้มีอะไรเปลี่ยนทั้งระบบ" · ตารางนี้ append-only และลบไม่ได้ จึงโตทางเดียว';
comment on index audit_log_table_at_idx is
  '"ตารางนี้ช่วงเวลานี้เปลี่ยนอะไร" · ไม่ทับ audit_log_row_idx(table_name, row_id) ที่ตอบ "แถวนี้เคยถูกแก้อะไร"';

-- ============================================================
-- 5 · แก้ข้อความของ cash_confirmations ให้ตรงความจริง (ข้อ 4 ของรอบนี้)
--     **ไม่เพิ่มคอลัมน์ ไม่เพิ่มเส้นทาง ไม่แตะ policy** — แก้ข้อความอย่างเดียว
--     ตัวฟังก์ชันคงคุณสมบัติเดิมทุกข้อ: plpgsql · ไม่เป็น SECURITY DEFINER ·
--     search_path = '' · ไม่ถามสิทธิ์ · ยังบอก '(ยังไม่ยืนยัน)' สำหรับใบที่ยัง
--     ไม่กรอกยอดจริง (เทสต์ C1 ของ 20261008000003 บังคับข้อนี้ไว้)
-- ============================================================
create or replace function fn_forbid_delete_confirmation() returns trigger
language plpgsql set search_path = '' as $fn$
begin
  raise exception 'กฎเหล็กข้อ 1 / Money Invariant 4+5: ลบใบยืนยันเงินเข้า-ออกไม่ได้ทุกกรณีทุกผู้ใช้ (รวมเจ้าของฐานข้อมูล) · นี่คือหลักฐานว่าเงินเคลื่อนจริงและเป็นฐานของการกระทบยอดธนาคาร · **ทางออกที่มีจริงวันนี้คือแก้ที่แถวเดิม (UPDATE) ด้วยสิทธิ์ cash.confirm แล้ว audit_log เก็บ before-after ไว้** · เส้นทาง "บันทึกรายการกลับให้เห็นสองแถว" ยังไม่มีในระบบ (ตารางนี้ไม่มีคอลัมน์สถานะ/void และยังไม่มีหน้าจอ) รอตัดสินว่าจะรับ UPDATE เป็นทางการหรือทำเส้นทางรายการกลับ (id % · บัญชีธนาคาร % · ยอดที่คาด % · ยอดจริง % · วันที่เงินเข้า-ออก %)',
    old.id, old.bank_account_id, old.expected_amount,
    coalesce(old.actual_amount::text, '(ยังไม่ยืนยัน)'),
    coalesce(old.actual_date::text, '(ยังไม่ยืนยัน)');
end $fn$;

comment on function fn_forbid_delete_confirmation() is
  'ห้ามลบแถวใน cash_confirmations ทุก role รวม superuser · ตารางนี้คือหลักฐานว่าเงินเคลื่อนจริง (ฐานของ Money Invariant 5) · ยกเลิก/แก้การยืนยัน = UPDATE ที่แถวเดิมด้วยสิทธิ์ cash.confirm ซึ่ง audit_log จับ before-after แล้ว · **เส้นทางรายการกลับที่เห็นสองแถวยังไม่มี** (ไม่มีคอลัมน์สถานะ/void · src/** ไม่อ้างตารางนี้) — คอมเมนต์เดิมของ 20261008000003 ชี้ไปทางนั้นทั้งที่ยังไม่มี แก้ไว้ที่นี่ (20261008000004)';

comment on table cash_confirmations is
  'ใบยืนยันว่าเงินเข้า-ออกจริงแล้วหรือยัง (ฐานของงบกระแสเงินสดและ Money Invariant 5) · ลบไม่ได้ทุก role · แก้ได้ที่แถวเดิมด้วยสิทธิ์ cash.confirm (policy confirmations_update) และมีร่องรอยใน audit_log · **เส้นทาง "บันทึกรายการกลับ" ยังไม่มี**: ไม่มีคอลัมน์สถานะ/void และยังไม่มีหน้าจอ ถ้าจะทำต้องตัดสินรูปแบบก่อน ห้ามเพิ่มคอลัมน์เงียบๆ (บทเรียนข้อ 7)';

do $$
declare v_oid oid;
begin
  select tg.oid into v_oid from pg_trigger tg
   where tg.tgrelid = 'sri_os.cash_confirmations'::regclass
     and tg.tgname = 'trg_forbid_delete_confirmation';
  if v_oid is null then
    raise exception 'ไม่พบ trg_forbid_delete_confirmation บน cash_confirmations → 20261008000003 ยังไม่ถูก apply (ไฟล์นี้ต้องรันหลังไฟล์นั้น)';
  end if;
  execute 'comment on trigger trg_forbid_delete_confirmation on sri_os.cash_confirmations is '
    || quote_literal('ด่าน DELETE ระดับแถว · ทางออกที่มีจริงวันนี้ = UPDATE ที่แถวเดิมด้วยสิทธิ์ cash.confirm (audit จับ before-after) · เส้นทางรายการกลับยังไม่มี รอตัดสิน');
end $$;

-- ============================================================
-- 6 · guard ของไฟล์นี้เอง — ถ้ากฎไม่ติดจริง migration ต้องพังทันที
--     ไม่ใช่รอให้เทสต์จับทีหลัง (ไฟล์นี้อาจถูก apply บน project ก่อนเทสต์)
--     ตรวจทั้งสองทิศ: ของที่ต้องมี **และของที่ต้องไม่มี**
-- ============================================================
do $$
declare n int; v text; r text;
begin
  -- (ก) contracts/schedules: กันลบ + กัน truncate + audit ครบตารางละสามตัว
  foreach r in array array['contracts', 'schedules'] loop
    select count(*) into n
      from pg_trigger tg
     where tg.tgrelid = ('sri_os.' || r)::regclass
       and not tg.tgisinternal
       and tg.tgname in ('trg_forbid_delete_' || left(r, length(r) - 1),
                         'trg_forbid_truncate', 'trg_audit_' || r);
    if n <> 3 then
      raise exception 'trigger บน % ไม่ครบ (เจอ % จาก 3: กันลบ + กัน truncate + audit)', r, n;
    end if;
    -- ด่านต้องเป็น before delete for each row และต้อง raise จริง ไม่ใช่ติดไว้เฉยๆ
    select count(*) into n
      from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
     where tg.tgrelid = ('sri_os.' || r)::regclass
       and tg.tgname = 'trg_forbid_delete_' || left(r, length(r) - 1)
       and (tg.tgtype & 8) <> 0 and (tg.tgtype & 2) <> 0 and (tg.tgtype & 1) <> 0
       and p.prosrc ~* 'raise exception';
    if n <> 1 then
      raise exception 'ด่าน DELETE ของ % ไม่ใช่ before delete for each row ที่ raise จริง', r;
    end if;
  end loop;

  -- (ข) **ของที่ต้องไม่มี**: trigger ที่ขัดขวาง UPDATE/INSERT ของสัญญา-งวด
  --     นี่คือจุดที่ "กันแน่นเกิน" จะผิด → บริหารสัญญาไม่ได้ทั้งระบบ
  --     fn_audit บันทึกได้ (ไม่ขัดขวาง) · fn_schedule_* ของเดิมเป็นด่านเงื่อนไข
  --     ที่ตัดสินไว้แล้ว (ข้อมูลสัญญาไม่ครบ / สถานะงวดต้องสอดคล้องกับร่าง)
  select string_agg(tg.tgname, ', ') into v
    from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
   where tg.tgrelid in ('sri_os.contracts'::regclass, 'sri_os.schedules'::regclass)
     and not tg.tgisinternal
     and ((tg.tgtype & 16) <> 0 or (tg.tgtype & 4) <> 0)     -- UPDATE หรือ INSERT
     and p.proname like 'fn_forbid%';
  if v is not null then
    raise exception 'contracts/schedules มี trigger กัน UPDATE/INSERT: % · สัญญาและงวดต้องแก้ได้ตามปกติ (เลื่อนงวด/แก้อัตรา/ปิดสัญญา) ห้ามปิด', v;
  end if;
  if not exists (select 1 from pg_policies
                  where schemaname = 'sri_os' and tablename = 'contracts'
                    and policyname = 'contracts_update' and cmd = 'UPDATE')
     or not exists (select 1 from pg_policies
                     where schemaname = 'sri_os' and tablename = 'schedules'
                       and policyname = 'schedules_update' and cmd = 'UPDATE') then
    raise exception 'policy contracts_update / schedules_update หายไป → แก้สัญญาหรือเลื่อนงวดไม่ได้';
  end if;
  -- และต้องไม่มี policy DELETE โผล่มา (ลบไม่ได้ทุกตำแหน่งตามที่ตัดสิน)
  select string_agg(tablename || '.' || policyname, ', ') into v
    from pg_policies
   where schemaname = 'sri_os' and tablename in ('contracts', 'schedules')
     and cmd in ('DELETE', 'ALL');
  if v is not null then
    raise exception 'contracts/schedules มี policy DELETE/ALL: %', v;
  end if;

  -- (ค) TRUNCATE ครบทุกตารางใน sri_os · ข้อนี้คือ guard ที่ขอไว้:
  --     มีตารางใดไม่ถูกกัน = migration พัง ไม่ใช่ค้นเจอทีหลัง
  select string_agg(c.relname, ', ' order by c.relname), count(*) into v, n
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os' and c.relkind = 'r'
     and not exists (select 1 from pg_trigger tg
                      where tg.tgrelid = c.oid and not tg.tgisinternal
                        and (tg.tgtype & 32) <> 0);
  if n > 0 then
    raise exception '% ตารางใน sri_os ยัง TRUNCATE ได้: %', n, v;
  end if;
  select count(*) into n
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os' and c.relkind = 'r';
  if n < 25 then
    raise exception 'นับตารางใน sri_os ได้แค่ % ตาราง — guard นี้อาจไม่ได้ตรวจอะไรเลย', n;
  end if;

  -- (ง) index ของ audit_log: ต้องมี index ที่ **นำด้วย** at และของเดิมต้องไม่หาย
  if not exists (
    select 1 from pg_index i
     where i.indrelid = 'sri_os.audit_log'::regclass
       and (select attname from pg_attribute
             where attrelid = i.indrelid and attnum = i.indkey[0]) = 'at'
  ) then
    raise exception 'audit_log ไม่มี index ที่นำด้วยคอลัมน์ at';
  end if;
  if not exists (
    select 1 from pg_index i
     where i.indrelid = 'sri_os.audit_log'::regclass
       and (select attname from pg_attribute
             where attrelid = i.indrelid and attnum = i.indkey[0]) = 'table_name'
  ) then
    raise exception 'index ที่นำด้วย table_name หายไปจาก audit_log';
  end if;

  -- (จ) ฟังก์ชันใหม่ทั้งสามตัวต้องเรียกตรงไม่ได้ ไม่เป็น SECURITY DEFINER
  --     และไม่ถามสิทธิ์ (การห้ามลบไม่ขึ้นกับสิทธิ์ · เทสต์ S18 / H0 / H0b)
  select string_agg(p.proname, ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.proname in ('fn_forbid_delete_contract', 'fn_forbid_delete_schedule',
                       'fn_forbid_delete_confirmation')
     and (p.prosecdef
       or p.prosrc ~* 'fn_can'
       or has_function_privilege('public', p.oid, 'execute'));
  if v is not null then
    raise exception 'ฟังก์ชันกันลบหลวมเกินไป (SECURITY DEFINER / ถามสิทธิ์ / PUBLIC execute): %', v;
  end if;

  -- (ฉ) ข้อ 4: ข้อความที่ชี้ไปทาง "รายการกลับ" ต้องบอกด้วยว่ายังไม่มี
  --     ตรวจทั้งเนื้อฟังก์ชันและคอมเมนต์ที่หาเจอจาก DB
  select string_agg(x.src, ' || ') into v from (
      select p.prosrc as src from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
       where ns.nspname = 'sri_os' and p.proname = 'fn_forbid_delete_confirmation'
      union all
      select obj_description('sri_os.cash_confirmations'::regclass, 'pg_class')
      union all
      select obj_description('sri_os.fn_forbid_delete_confirmation()'::regprocedure, 'pg_proc')
    ) x
   where x.src ~ 'รายการกลับ' and x.src !~ 'ยังไม่มี';
  if v is not null then
    raise exception 'ยังมีข้อความที่ชี้ไปทาง "รายการกลับ" โดยไม่บอกว่ายังไม่มีเส้นทางนั้น (คนในอนาคตจะเชื่อว่ามีแล้วไม่เอะใจ)';
  end if;
  if (select count(*) from pg_attribute
       where attrelid = 'sri_os.cash_confirmations'::regclass and attnum > 0 and not attisdropped
         and attname in ('status', 'voided_at', 'voided_by', 'is_void', 'reverses_id')) > 0 then
    raise exception 'cash_confirmations มีคอลัมน์สถานะ/void แล้ว → หมายเหตุ "เส้นทางรายการกลับยังไม่มี" ล้าสมัย ให้กลับมาแก้';
  end if;

  raise notice 'guard · contracts/schedules กัน DELETE+TRUNCATE และมี audit แล้ว · UPDATE ยังเปิด · TRUNCATE กันครบ % ตาราง · audit_log มี index ตามเวลา · หมายเหตุ cash_confirmations ตรงความจริง', n;
end $$;
