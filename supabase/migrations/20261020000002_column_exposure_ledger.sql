-- ============================================================
-- SRI OS · จัดประเภทคอลัมน์ของสมุดเงินทั้งเล่ม (D-089 รอบที่สอง)
--   ปิดของที่ 20261020000000 ขึ้นทะเบียนไว้เป็น `deferred` คือ
--   `transactions` · `transaction_lines` (รอ D-098 ปิดก่อน · ปิดแล้ว)
--   เทสต์: supabase/tests/zz_column_exposure_test.sql (หมวด C7)
--   **ต้องรันหลัง** 20261020000000_column_exposure.sql และ
--   20261020000001_void_columns_and_views.sql (ไฟล์นี้ตรวจเองที่หัวไฟล์ ไม่เดา)
--
-- ------------------------------------------------------------
-- ตัดสินอะไร: สองตารางนี้เป็น `row` ทั้งใบ **ไม่ใช่ `grant`**
-- ------------------------------------------------------------
-- `row` = ไม่ต้องมีด่านระดับคอลัมน์ เพราะ **policy ของแถวบังคับสิทธิ์นั้นอยู่แล้ว**
--   ทั้งสองตารางอ่านแถวได้ผ่าน policy เดียวต่อตาราง (transactions_by_owner ·
--   lines_by_txn) ซึ่งเรียก `fn_can_read_txn()` ที่บังคับ `ledger.read` เสมอ
--   → **Staff (ไม่มี ledger.read) เห็น 0 แถวทั้งสองตาราง** จึงไม่มี "ระดับที่เห็นแถว
--   แต่ไม่ควรเห็นคอลัมน์" แบบที่ assets/bank_accounts/owners/contacts มี
--   (ที่นั่นแถวหลุดถึง Staff ด้วยทางผ่านของคนคีย์รายการ/policy อ่านเป็น true)
--   ส่วน Manager ถูกจำกัด**ที่ชั้นแถว**อยู่แล้ว (เฉพาะรายการที่ตัวเองคี่ย์ หรือของทรัพย์
--   ที่ตัวเองบริหาร) → ตัวเลขบนแถวที่เขาเห็น เป็นตัวเลขของงานที่เขารับผิดชอบ
--
-- ทำไม **ไม่** ปิดด้วย GRANT (วัดมาแล้วทั้งสองงาน ไม่ใช่ความเห็น):
--   1. `v_ledger_posted` / `v_ledger_voided` (20261020000001) เป็น `security_invoker`
--      → Postgres ตรวจสิทธิ์ **ตารางฐานด้วยสิทธิ์ของผู้เรียก** ถ้าถอน select ระดับตาราง
--      ผู้เรียกต้องมีสิทธิ์ครบ **ทุกคอลัมน์ที่ view นั้น select** ไม่งั้นได้
--      `permission denied` ทั้งใบ · และ event trigger ของ 20261007000000 บังคับให้
--      view ทุกตัวในสคีมานี้เป็น invoker จะเลี่ยงด้วย view แบบ definer ก็ไม่ได้
--   2. `fn_post_entry` (20261008000008) **ไม่ใช่ security definer** โดยเจตนา
--      (ไม่งั้นเป็นประตูหลังข้าม RLS) → มันอ่าน/เขียน transactions ด้วยสิทธิ์ผู้คีย์
--      ถอน select ของตารางฐาน = เส้นทางลงบัญชีจริงตายทั้งเส้น
--   3. ถ้าจะปิดตารางฐานจริง ต้องเปลี่ยนสามอย่าง **พร้อมกัน** (ห้ามปิดครึ่งเดียว
--      — บทเรียนข้อ 7): ทำ `fn_ledger_posted()`/`fn_ledger_voided()` แบบ definer
--      ที่เจ้าของเป็น `sri_os_column_reader` (แพทเทิร์นของ 20261020000000) ·
--      ย้าย `fn_post_entry` ไปอ่านผ่านทางเข้านั้น · แก้ allow-list ของ guard (6b)
--      ใน 20261020000001 → **เป็นงานแยกที่ต้องให้ลูกพี่/mace-windu ตัดสิน**
--      ไฟล์นี้จึงบีบด้วยสิ่งที่บังคับได้วันนี้ และ **ทำให้เหตุผลของ `row` ถูกตรวจด้วยเครื่อง**
--
-- ------------------------------------------------------------
-- `row` ต้องไม่ใช่ตรายาง: ไฟล์นี้เพิ่มด่านที่สามของการจัดประเภทแบบ row
-- ------------------------------------------------------------
-- เดิม guard ตรวจอยู่ข้อเดียว: **ทุก policy ที่อ่านแถวได้** ต้องยังบังคับสิทธิ์ที่ขึ้นทะเบียน
--   (fn_policy_requires_permission · ไล่เนื้อฟังก์ชันที่ policy เรียกลึก 3 ชั้น)
-- ไฟล์นี้เพิ่ม: **ทางอ้อมที่ไม่ผ่าน policy** = ฟังก์ชัน `security definer` ที่เจ้าของ
--   ไม่ถูก RLS บังคับ (เจ้าของตาราง/superuser/bypassrls) ซึ่งอ่านตารางนั้นและ
--   `authenticated`/PUBLIC เรียกได้ → ฟังก์ชันพวกนี้ **ข้าม policy ทั้งใบ**
--   ถ้ามีตัวหนึ่งคืนข้อมูลของตารางที่จัดเป็น `row` ให้คนที่ไม่มีสิทธิ์
--   เหตุผลของ `row` ตายทันทีโดยที่ policy ยังดูดีอยู่
--
--   เงื่อนไขที่ยอมได้ มีสองทางเท่านั้น (fn_column_exposure_row_escapes):
--     (ก) ฟังก์ชันนั้น **ถามสิทธิ์เอง** ด้วย `fn_can('P')` โดย P **ครอบ** สิทธิ์ขั้นต่ำ
--         ของตาราง — "ครอบ" ตรวจจากข้อมูลจริงในตารางสิทธิ์: ทุก role ที่ได้ P
--         ต้องได้สิทธิ์ขั้นต่ำนั้นด้วย และต้องมี role ที่ได้ P อยู่จริง (ไม่ใช่คีย์ลอย)
--         เช่น `fn_health_check` ถาม `settings.manage` ซึ่งวันนี้มีแต่ระดับที่มี
--         `ledger.read` อยู่แล้ว → ผ่าน · ถ้าวันหนึ่งมีใครย้าย settings.manage
--         ไปให้ระดับที่ไม่มี ledger.read **guard จะแดงเอง** ไม่ต้องมีใครจำ
--     (ข) อยู่ใน allow-list ของไฟล์นี้ พร้อมเหตุผลรายตัว และ **ชื่อต้องมีจริง**
--         (ชื่อที่ไม่มีจริง = ยกเว้นของที่ไม่มี แล้วของจริงหลุด → guard แดง)
--
--   allow-list วันนี้มีสองคู่ ทั้งคู่คืนแค่ boolean ไม่คืนตัวเลขหรือข้อความของแถว:
--     · fn_reverse_link_ok(uuid,uuid,uuid) → transactions
--       trigger ที่เรียกมัน (fn_assert_reverse_link · fn_corporate_requires_evidence)
--       **ไม่ใช่ definer** จึงรันด้วยสิทธิ์ผู้คีย์ → ถ้าถอน execute การลงรายการกลับรายการ
--       จะล้มในแอปแต่ผ่านในเทสต์ที่รันเป็น superuser (20261007000001 เขียนไว้ชัด)
--       สิ่งที่รู้เพิ่มได้คือ "มี/ไม่มีรายการ id นี้ของผู้ถือนี้ที่กลับรายการได้"
--     · fn_can_write_schedule(uuid) → contracts
--       เป็นตัวตัดสินสิทธิ์ของ policy เอง (เรียก fn_can_write_contract ข้างใน)
--       คืน boolean ว่าผู้เรียกแก้งวดของสัญญานั้นได้หรือไม่ ไม่ได้คืนเนื้อสัญญา
--   เพิ่มชื่อเข้า allow-list ได้ด้วย migration ใหม่เท่านั้น (ตารางไม่มี policy เขียน)
--
-- ------------------------------------------------------------
-- ขอบเขตที่ไฟล์นี้ **ไม่** ครอบ (เหมือน 20261020000000 · P3)
-- ------------------------------------------------------------
--   · `postgres`/superuser/เจ้าของตาราง ข้ามทุกชั้นโดยธรรมชาติ
--   · `service_role` มี bypassrls → **ข้าม RLS ได้** แปลว่าการจัดประเภทแบบ `row`
--     **ไม่ครอบ service_role** (ต่างจาก `grant` ที่เป็นสิทธิ์ จึงครอบ)
--     ที่กันอยู่วันนี้คือ 20261007000001 ไม่ได้ให้สิทธิ์อะไรใน sri_os แก่ service_role เลย
--     → guard ข้อ (10) ของไฟล์นี้ **แดงถ้ามีใคร grant select ตารางสมุดเงินให้ role
--     ที่มี bypassrls** (ตอนนั้นต้องกลับมาทำทางเข้าแบบ definer ตามข้อ 3 ข้างบน)
--   · ลำดับการตรวจสิทธิ์ภายในฟังก์ชัน allow-list/ข้อ (ก): เครื่องตรวจได้แค่ว่า
--     **มี** การถามสิทธิ์ที่ครอบจริง ไม่ได้ตรวจว่าถามก่อนคืนข้อมูลทุกเส้นทาง
--     (fn_health_check ถามเป็นบรรทัดแรกแล้ว raise · ตรวจด้วยตาตอนรีวิว)
--
-- ย้อนกลับ (rollback)
--   -- update sri_os.column_exposure_tables
--   --    set review_state = 'deferred', reason = '...' where table_name in
--   --    ('transactions', 'transaction_lines');
--   -- delete from sri_os.column_exposure
--   --  where table_name in ('transactions', 'transaction_lines');
--   -- drop function if exists sri_os.fn_column_exposure_row_escapes();
--   -- drop function if exists sri_os.fn_column_exposure_definer_allowlist();
--   -- drop table if exists sri_os.column_exposure_definer_reads;
--   -- คืน fn_column_exposure_breaches() รุ่นก่อน: รันบล็อก 5 ของ
--   --   20261020000000_column_exposure.sql ซ้ำ (รุ่นนั้นไม่มีข้อ 9/10)
--   -- ย้อนแล้ว: สมุดเงินทั้งเล่มไม่มีใครจัดประเภท → guard ไม่รู้ว่าคอลัมน์ใหม่
--   --           ของ transactions หลุดหรือไม่ และ "ปล่อยค้าง" กลับมาเป็นสถานะถาวร
--
-- idempotent: insert ... on conflict do update · create or replace function ·
--   create table if not exists · ไม่แตะ policy ไม่แตะ grant ของตารางสมุดเงิน
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 0 · ของที่ต้องมีก่อน — ถ้าไฟล์นี้ถูกรันสลับลำดับ ต้องพังให้เห็น ไม่ใช่เดา
-- ============================================================
do $$
declare v text;
begin
  if to_regclass('sri_os.column_exposure') is null
     or to_regclass('sri_os.column_exposure_tables') is null then
    raise exception 'ไม่มีทะเบียนด่านคอลัมน์ → ต้องรัน 20261020000000_column_exposure.sql ก่อนไฟล์นี้ (ดู supabase/migration-order.txt)';
  end if;
  select string_agg(c, ', ') into v
    from unnest(array['voided_at', 'voided_by', 'void_reason']) c
   where not exists (
     select 1 from pg_attribute a
      where a.attrelid = 'sri_os.transactions'::regclass
        and a.attname = c and a.attnum > 0 and not a.attisdropped);
  if v is not null then
    raise exception 'transactions ยังไม่มีคอลัมน์ร่องรอยการยกเลิก (%) → ต้องรัน 20261020000001_void_columns_and_views.sql ก่อนไฟล์นี้ ไม่งั้นจัดประเภทไม่ครบคอลัมน์จริง', v;
  end if;
  if to_regclass('sri_os.v_ledger_posted') is null
     or to_regclass('sri_os.v_ledger_voided') is null then
    raise exception 'ไม่มี v_ledger_posted / v_ledger_voided → ต้องรัน 20261020000001 ก่อน (เหตุผลของการเลือก row ขึ้นกับสองวิวนี้)';
  end if;
end $$;

-- ============================================================
-- 1 · เปลี่ยนสองตารางจาก deferred → classified พร้อมเหตุผลที่ตรวจได้
-- ============================================================
insert into column_exposure_tables (table_name, review_state, reason) values
  ('transactions', 'classified',
   'สมุดเงิน · ทุก policy ที่อ่านแถวได้เรียก fn_can_read_txn ซึ่งบังคับ ledger.read → Staff เห็น 0 แถว · Manager ถูกจำกัดที่ชั้นแถว (รายการของตัวเอง/ของทรัพย์ที่บริหาร) · ปิดด้วย GRANT ไม่ได้เพราะ v_ledger_posted/voided เป็น security_invoker และ fn_post_entry ไม่ใช่ definer (เหตุผลเต็มที่หัวไฟล์ 20261020000002)'),
  ('transaction_lines', 'classified',
   'บรรทัดบัญชี · policy lines_by_txn เรียก fn_can_read_txn ตัวเดียวกับหัวรายการ (เขียนที่เดียวเพื่อไม่ให้รวมยอดผ่าน lines ได้) → เหตุผลเดียวกับ transactions')
on conflict (table_name) do update
  set review_state = excluded.review_state, reason = excluded.reason;

-- ============================================================
-- 2 · จัดประเภทคอลัมน์ · ทั้งสองตารางเป็น `row` ทุกคอลัมน์ ด้วย ledger.read
--     **ไม่มีคอลัมน์ไหนเป็น `open`** โดยเจตนา: "open" แปลว่าทุกคนที่ล็อกอินอ่านได้
--     ซึ่งไม่จริงสำหรับสมุดเงิน — แม้แต่ id ก็ไม่ควรให้คนที่ไม่มี ledger.read อ่าน
--     (รู้ว่ามีรายการกี่ใบและ id อะไร = รู้จังหวะเงินของบ้าน)
--     ผลข้างเคียงที่ตั้งใจ: guard ยืนยันเงื่อนไข policy ให้ **ทุกคอลัมน์** ไม่ใช่บางคอลัมน์
-- ============================================================
insert into column_exposure (table_name, column_name, exposure, min_permission, rationale)
select t.tbl, c, 'row', 'ledger.read', t.why
  from (values
    ('transactions', array[
      'id', 'owner_id', 'txn_type_code', 'asset_id', 'contact_id', 'contract_id',
      'reverses_id', 'write_txn_id'
    ], 'คีย์และความเชื่อมโยงของรายการเงิน · บอกว่ามีรายการอะไรผูกกับทรัพย์/สัญญา/ผู้ถือไหน · แถวต้องมี ledger.read + ขอบเขต (fn_can_read_txn) ถึงจะเห็น'),
    ('transactions', array[
      'doc_date', 'cash_date', 'doc_no', 'status', 'source', 'source_ref',
      'created_by', 'approved_by', 'created_at'
    ], 'วันที่ · สถานะ · เลขเอกสาร · ใครคีย์-ใครอนุมัติ · จังหวะเงินและเส้นทางการอนุมัติของบ้าน · ถูกกรองด้วย fn_can_read_txn เหมือนกันทั้งแถว'),
    ('transactions', array[
      'vat_rate', 'vat_amount', 'tax_invoice_no'
    ], 'ภาษีมูลค่าเพิ่มของรายการ · เป็นตัวเลขเงินและเลขเอกสารภาษี · fn_can_read_txn กันทั้งแถวอยู่แล้ว'),
    ('transactions', array[
      'memo', 'attachments', 'owner_reason', 'funding_source'
    ], 'ข้อความประกอบ · ไฟล์หลักฐาน · เหตุผลที่ override (ฝั่งบุคคล) · แหล่งเงิน · อ่านได้เมื่อเห็นแถวตาม fn_can_read_txn (ตัวไฟล์ยังมีด่าน Storage อีกชั้น)'),
    ('transactions', array[
      'voided_at', 'voided_by', 'void_reason'
    ], 'ร่องรอยการยกเลิก (D-098) · บอกว่าใครยกเลิกอะไรเพราะอะไร · ต้องอ่านได้คู่กับแถวที่มันอธิบาย จึงใช้สิทธิ์เดียวกับแถว'),
    ('transactions', array[
      'is_intercompany', 'counter_owner_id', 'intercompany_nature'
    ], 'ขาข้ามผู้ถือ · ชี้ไปยังผู้ถืออีกฝั่งของรายการคู่ · ดูข้อที่ต้องถามลูกพี่ท้ายไฟล์: policy ปัจจุบันไม่ได้ตรวจขอบเขตของ counter_owner_id ซึ่งเป็นช่องที่ชั้นแถวต้องปิด ไม่ใช่ชั้นคอลัมน์'),
    ('transaction_lines', array[
      'id', 'transaction_id', 'coa_id', 'bank_account_id', 'asset_id'
    ], 'คีย์และคู่บัญชีของบรรทัด · บอกว่าเงินเข้า-ออกบัญชีไหนและลงบัญชีอะไร · policy lines_by_txn เรียก fn_can_read_txn ตัวเดียวกับหัวรายการ'),
    ('transaction_lines', array[
      'debit', 'credit', 'cf_category'
    ], 'ตัวเลขเดบิต-เครดิตและหมวดงบกระแสเงินสด = ตัวเลขเงินทั้งหมดของระบบ · เห็นได้เมื่อเห็นหัวรายการนั้นเท่านั้น'),
    ('transaction_lines', array[
      'memo', 'created_at'
    ], 'ข้อความประกอบบรรทัดและเวลาที่ลง · ถูกกรองด้วย fn_can_read_txn เหมือนกันทั้งแถว')
  ) as t(tbl, cols, why), unnest(t.cols) c
on conflict (table_name, column_name) do update
  set exposure = excluded.exposure, min_permission = excluded.min_permission,
      rationale = excluded.rationale;

-- ============================================================
-- 3 · allow-list ของทางอ้อมแบบ definer (ข้อ (ข) ที่หัวไฟล์)
-- ============================================================
create table if not exists column_exposure_definer_reads (
  function_name text not null,
  table_name    text not null references column_exposure_tables(table_name) on update cascade,
  reason        text not null check (length(btrim(reason)) > 20),
  created_at    timestamptz not null default now(),
  primary key (function_name, table_name)
);
comment on table column_exposure_definer_reads is
  'D-089 · allow-list ของฟังก์ชัน security definer ที่อ่านตารางซึ่งจัดประเภทเป็น row ได้โดยไม่ถามสิทธิ์เอง · ทุกแถวต้องมีเหตุผลและชื่อฟังก์ชันต้องมีจริง · เพิ่มได้จาก migration เท่านั้น (ไม่มี write policy) เพราะนี่คือรายการ "ทางข้าม policy ที่เรายอม"';

insert into column_exposure_definer_reads (function_name, table_name, reason) values
  ('fn_reverse_link_ok', 'transactions',
   'คืนแค่ boolean ว่ารายการที่อ้างกลับรายการได้หรือไม่ ไม่คืนตัวเลขหรือข้อความของแถว · ถอน execute ไม่ได้เพราะ trigger ที่เรียกมันไม่ใช่ definer จึงรันด้วยสิทธิ์ผู้คีย์ (20261007000001 · เทสต์ L23)'),
  ('fn_can_write_schedule', 'contracts',
   'เป็นตัวตัดสินสิทธิ์ของ policy เอง (เรียก fn_can_write_contract ข้างใน) คืน boolean ว่าแก้งวดของสัญญานั้นได้ไหม ไม่ได้คืนเนื้อสัญญา · ถอนแล้ว policy ของ schedules ล้มทั้งตาราง')
on conflict (function_name, table_name) do update set reason = excluded.reason;

-- ทะเบียนนี้อ่านได้ เขียนไม่ได้จากแอป (แพทเทิร์นเดียวกับ column_exposure)
alter table column_exposure_definer_reads enable row level security;
drop policy if exists column_exposure_definer_reads_read on column_exposure_definer_reads;
create policy column_exposure_definer_reads_read on column_exposure_definer_reads
  for select to authenticated using (true);
drop policy if exists column_exposure_definer_reads_write on column_exposure_definer_reads;
drop trigger if exists trg_forbid_truncate on column_exposure_definer_reads;
create trigger trg_forbid_truncate before truncate on column_exposure_definer_reads
  for each statement execute function fn_forbid_truncate();
drop trigger if exists trg_audit_column_exposure_definer_reads on column_exposure_definer_reads;
create trigger trg_audit_column_exposure_definer_reads
  after insert or update or delete on column_exposure_definer_reads
  for each row execute function fn_audit_keyed('function_name', 'table_name');

-- ตารางใหม่ต้องจัดประเภทตัวเองด้วย ไม่งั้น guard ของตัวเองแดง (P4 กินตัวเอง = ดี)
insert into column_exposure_tables (table_name, review_state, reason) values
  ('column_exposure_definer_reads', 'classified',
   'allow-list ของไฟล์นี้เอง · ต้องจัดประเภทตัวเอง ไม่งั้นมีตารางที่ guard ไม่ตรวจ')
on conflict (table_name) do update
  set review_state = excluded.review_state, reason = excluded.reason;
insert into column_exposure (table_name, column_name, exposure, min_permission, rationale)
select 'column_exposure_definer_reads', c, 'open', null,
       'ทะเบียนทางข้ามที่เรายอม · อ่านได้ทุกคนโดยเจตนา: รู้ว่ามีทางข้ามอะไรไม่ได้ทำให้ใช้ทางนั้นได้ (หลักเดียวกับตาราง permissions)'
  from unnest(array['function_name', 'table_name', 'reason', 'created_at']) c
on conflict (table_name, column_name) do update
  set exposure = excluded.exposure, min_permission = excluded.min_permission,
      rationale = excluded.rationale;

-- ============================================================
-- 3.5 · เขียน fn_policy_requires_permission ใหม่ให้เร็วและเท่าเดิมในความเข้ม
--      ของเดิม (20261020000000) ต่อเนื้อฟังก์ชันเข้าไปใน **ก้อนข้อความเดียว**
--      แล้ววนหาชื่อฟังก์ชันในก้อนที่โตขึ้นทุกรอบ → พอ row เพิ่มจาก 16 เป็น 56 คอลัมน์
--      (สมุดเงินเข้ามา) การตรวจกลายเป็นโตแบบทวีคูณจนเทสต์ค้าง (วัดเอง: > 120 วินาที)
--      รุ่นนี้ไล่เป็น **รายชื่อฟังก์ชัน (worklist)** ลึก 3 ชั้นเท่าเดิม
--      ไม่สะสมข้อความ และหยุดทันทีที่เจอสิทธิ์ → ผลลัพธ์เดิม เวลาเป็นหลักมิลลิวินาที
-- ============================================================
create or replace function fn_policy_requires_permission(p_table text, p_permission text)
returns boolean
language plpgsql stable set search_path = '' as $fn$
declare
  r        record;
  v_names  text[];
  v_seen   text[];
  v_bodies text;
  v_found  boolean := false;
  v_hit    boolean;
  i        int;
begin
  for r in
    select coalesce(p.qual, '') as qual
      from pg_policies p
     where p.schemaname = 'sri_os' and p.tablename = p_table
       and p.cmd in ('SELECT', 'ALL')
  loop
    v_found := true;
    -- สิทธิ์อยู่ในตัว policy เองหรือไม่
    v_hit := position('''' || p_permission || '''' in r.qual) > 0;
    if not v_hit then
      -- ชื่อฟังก์ชันของ sri_os ที่ policy เรียก → ขยายต่อเป็นชั้นๆ
      select coalesce(array_agg(distinct pr.proname), '{}') into v_names
        from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
       where ns.nspname = 'sri_os' and r.qual ~ ('\m' || pr.proname || '\M');
      v_seen := '{}';
      for i in 1..3 loop
        select coalesce(array_agg(n), '{}') into v_names
          from unnest(v_names) n where not (n = any (v_seen));
        exit when coalesce(cardinality(v_names), 0) = 0;
        v_seen := v_seen || v_names;
        select coalesce(string_agg(pr.prosrc, ' '), '') into v_bodies
          from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
         where ns.nspname = 'sri_os' and pr.proname = any (v_names);
        if position('''' || p_permission || '''' in v_bodies) > 0 then
          v_hit := true;
          exit;
        end if;
        select coalesce(array_agg(distinct pr.proname), '{}') into v_names
          from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
         where ns.nspname = 'sri_os' and v_bodies ~ ('\m' || pr.proname || '\M');
      end loop;
    end if;
    -- policy ตัวใดตัวหนึ่งที่ไม่บังคับสิทธิ์นี้ = อ่านแถวได้โดยไม่มีสิทธิ์
    -- (policy เป็น permissive และ OR กัน) → ต้องตอบ false
    if not v_hit then
      return false;
    end if;
  end loop;
  -- ไม่มี policy อ่านเลย = ไม่มีใครอ่านแถวได้ → ถือว่า "ยังไม่ครอบ" ไม่ใช่ปลอดภัย
  return v_found;
end $fn$;
comment on function fn_policy_requires_permission(text, text) is
  'D-089 · ตรวจว่า **ทุก** policy ที่ทำให้อ่านแถวของตารางได้ ยังบังคับสิทธิ์ที่ระบุ (ขยายผ่านรายชื่อฟังก์ชันที่ policy เรียก 3 ชั้น) · ใช้ยืนยันเหตุผลของการจัดประเภทแบบ row · ไม่ใช่ตัวตัดสินสิทธิ์ตอนรันจริง';
revoke all on function fn_policy_requires_permission(text, text) from public;
do $$ begin
  execute 'revoke all on function sri_os.fn_policy_requires_permission(text, text) from anon';
  execute 'grant execute on function sri_os.fn_policy_requires_permission(text, text) to authenticated';
exception when undefined_object then null;
end $$;

-- ============================================================
-- 4 · ด่านที่สามของ `row` · ทางอ้อมแบบ definer ที่ข้าม policy
-- ============================================================
create or replace function fn_column_exposure_row_escapes()
returns table (function_name text, table_name text, problem text)
language sql stable set search_path = '' as $fn$
  select p.proname::text, ce.table_name,
         'ฟังก์ชัน security definer ที่เจ้าของไม่ถูก RLS บังคับ (' ||
         pg_get_userbyid(p.proowner) || ') อ่านตารางที่จัดประเภทเป็น row และ ' ||
         case when has_function_privilege('public', p.oid, 'execute') then 'PUBLIC' else 'authenticated' end ||
         ' เรียกได้ โดยไม่ถามสิทธิ์ที่ครอบ ' || ce.min_permission ||
         ' และไม่อยู่ใน allow-list → ข้าม policy ของตารางทั้งใบ'
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    join (select ce2.table_name, min(ce2.min_permission) as min_permission
            from sri_os.column_exposure ce2
           where ce2.exposure = 'row'
           group by ce2.table_name) ce
         on p.prosrc ~ ('\m' || ce.table_name || '\M')
   where ns.nspname = 'sri_os'
     and p.prosecdef
     -- เจ้าของที่ RLS ไม่บังคับ: เจ้าของตารางนั้นเอง · superuser · bypassrls
     and (p.proowner = (select c.relowner from pg_class c
                         where c.oid = ('sri_os.' || quote_ident(ce.table_name))::regclass)
          or exists (select 1 from pg_roles r
                      where r.oid = p.proowner and (r.rolsuper or r.rolbypassrls)))
     and (has_function_privilege('authenticated', p.oid, 'execute')
          or has_function_privilege('public', p.oid, 'execute'))
     -- (ก) ถามสิทธิ์เองด้วยคีย์ที่ "ครอบ" สิทธิ์ขั้นต่ำของตาราง
     and not exists (
       select 1 from sri_os.permissions perm
        where p.prosrc ~ ('fn_can\(''' || perm.key || '''\)')
          and exists (select 1 from sri_os.role_permissions rp where rp.permission_key = perm.key)
          and not exists (
            select 1 from sri_os.role_permissions rp
             where rp.permission_key = perm.key
               and not exists (select 1 from sri_os.role_permissions r2
                                where r2.role_key = rp.role_key
                                  and r2.permission_key = ce.min_permission))
     )
     -- (ข) allow-list พร้อมเหตุผล
     and not exists (
       select 1 from sri_os.column_exposure_definer_reads al
        where al.function_name = p.proname and al.table_name = ce.table_name)
$fn$;
comment on function fn_column_exposure_row_escapes() is
  'D-089 · คืนรายการ "ทางอ้อมที่ทำให้เหตุผลของการจัดประเภทแบบ row ตาย" = ฟังก์ชัน definer ที่ข้าม RLS อ่านตารางนั้นและผู้ใช้แอปเรียกได้ โดยไม่ถามสิทธิ์ที่ครอบและไม่อยู่ใน allow-list · ว่าง = ไม่มีทางอ้อมที่ไม่ได้ตัดสิน';
revoke all on function fn_column_exposure_row_escapes() from public;

-- ============================================================
-- 5 · ต่อด่านใหม่เข้า fn_column_exposure_breaches() (ตัวที่ guard เรียกอยู่แล้ว)
--     create or replace · เนื้อเดิมของ 20261020000000 ครบทุกข้อ (1)-(8) + เพิ่ม (9)(10)
-- ============================================================
create or replace function fn_column_exposure_breaches()
returns table (breach_kind text, object_name text, problem text)
language sql stable set search_path = '' as $fn$
  -- (1) คอลัมน์ที่ต้องปิดด้วย GRANT แต่ authenticated ยังอ่านได้
  select 'readable', (ce.table_name || '.' || ce.column_name)::text,
         'คอลัมน์ที่จัดประเภทเป็น grant แต่ authenticated ยังมีสิทธิ์ select'
    from sri_os.column_exposure ce
   where ce.exposure = 'grant'
     and to_regclass('sri_os.' || quote_ident(ce.table_name)) is not null
     and has_column_privilege('authenticated', to_regclass('sri_os.' || quote_ident(ce.table_name)),
                              ce.column_name, 'select')
  union all
  -- (2) ตารางที่มีด่าน แต่ยังมี select ระดับตาราง → column grant ไม่มีผลเลย
  select 'table_grant', (c.relname || ' → ' ||
          case when acl.grantee = 0 then 'PUBLIC' else pg_get_userbyid(acl.grantee) end)::text,
         'ตารางที่มีคอลัมน์ปิด แต่ยังมี select ระดับตารางให้ role นี้ → ด่านคอลัมน์ไม่มีผล'
    from pg_class c
    join pg_namespace ns on ns.oid = c.relnamespace
    cross join lateral aclexplode(c.relacl) acl
   where ns.nspname = 'sri_os' and c.relkind = 'r'
     and acl.privilege_type = 'SELECT'
     and acl.grantee <> c.relowner
     and (acl.grantee = 0 or pg_get_userbyid(acl.grantee) <> 'sri_os_column_reader')
     and exists (select 1 from sri_os.column_exposure ce
                  where ce.table_name = c.relname and ce.exposure = 'grant')
  union all
  -- (3) คอลัมน์ที่ควรอ่านได้ แต่ด่านแน่นเกินจนอ่านไม่ได้ (P2 · ห้ามพังเส้นทางที่ถูก)
  select 'too_tight', (ce.table_name || '.' || ce.column_name)::text,
         'คอลัมน์ที่จัดประเภทว่าเปิด/กันด้วยแถว แต่ authenticated อ่านไม่ได้ → หน้าจอที่ต้องใช้จะพัง'
    from sri_os.column_exposure ce
   where ce.exposure in ('open', 'row')
     and to_regclass('sri_os.' || quote_ident(ce.table_name)) is not null
     and not has_column_privilege('authenticated', to_regclass('sri_os.' || quote_ident(ce.table_name)),
                                  ce.column_name, 'select')
  union all
  -- (4) เหตุผลของการจัดประเภทแบบ row ตายแล้ว (policy ถูกผ่อน/มี policy กว้างเพิ่มมา)
  --     ถามรายคู่ (ตาราง, สิทธิ์) ไม่ใช่รายคอลัมน์ — คำตอบเหมือนกันทุกคอลัมน์ของคู่เดียวกัน
  --     และการถามรายคอลัมน์ทำให้การตรวจช้าจนเทสต์ค้างเมื่อสมุดเงินเข้ามา (56 คอลัมน์)
  select 'row_policy', (x.table_name || ' (' || x.min_permission || ')')::text,
         'จัดประเภทเป็น row ด้วยสิทธิ์ ' || x.min_permission || ' ทั้ง ' || x.n_cols ||
         ' คอลัมน์ แต่ policy อ่านของตารางไม่ได้บังคับสิทธิ์นั้นทุกตัวแล้ว'
    from (select ce.table_name, ce.min_permission, count(*) as n_cols
            from sri_os.column_exposure ce
           where ce.exposure = 'row'
           group by ce.table_name, ce.min_permission
           -- `offset 0` กัน planner ยุบ subquery แล้วเอาการเรียกฟังก์ชันไปไว้ใน filter
           -- ของ seq scan ซึ่งทำให้ถูกเรียก **รายคอลัมน์ (56 ครั้ง)** ไม่ใช่รายคู่ (8 ครั้ง)
           -- วัดแล้ว: 2.9 วินาที → 0.4 วินาที ต่อการตรวจหนึ่งรอบ
           offset 0) x
   where not sri_os.fn_policy_requires_permission(x.table_name, x.min_permission)
  union all
  -- (5) ทางเข้าของระดับที่มีสิทธิ์ต้องมีจริง · เป็น definer · เจ้าของเป็น role ที่ตั้งใจ ·
  --     อ่านอย่างเดียว · search_path แน่น · anon เรียกไม่ได้ · authenticated เรียกได้
  select 'reader_fn', ('fn_' || t.table_name || '_visible()')::text, x.problem
    from (select distinct table_name from sri_os.column_exposure where exposure = 'grant') t
    left join lateral (
      select p.* from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
       where ns.nspname = 'sri_os' and p.proname = 'fn_' || t.table_name || '_visible'
         and p.pronargs = 0
    ) p on true
    cross join lateral (select case
        when p.oid is null then 'ไม่มีฟังก์ชันทางเข้าสำหรับตารางที่มีคอลัมน์ปิด → ระดับที่มีสิทธิ์อ่านไม่ได้เลย'
        when not p.prosecdef then 'ฟังก์ชันทางเข้าไม่ใช่ security definer → อ่านคอลัมน์ที่ปิดไม่ได้'
        when pg_get_userbyid(p.proowner) <> 'sri_os_column_reader' then
             'เจ้าของฟังก์ชันคือ ' || pg_get_userbyid(p.proowner) ||
             ' · ถ้าเป็นเจ้าของตารางหรือ role ที่มี bypassrls ฟังก์ชันนี้จะข้าม RLS ทั้งหมด'
        when not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c
                          where c in ('search_path=', 'search_path=""')) then
             'search_path ไม่แน่น (definer ที่ search_path หลวม = ช่องยึดสิทธิ์)'
        when p.provolatile <> 's' then 'ต้องเป็น stable (อ่านอย่างเดียว)'
        when p.prosrc ~* '\m(insert|update|delete|merge|truncate|alter|drop|grant|revoke)\M' then
             'เนื้อฟังก์ชันมีคำสั่งเขียน → ทางเข้าสำหรับอ่านต้องอ่านเท่านั้น'
        when has_function_privilege('public', p.oid, 'execute') then 'PUBLIC เรียกได้'
        when exists (select 1 from pg_roles where rolname = 'anon')
             and has_function_privilege('anon', p.oid, 'execute') then 'anon เรียกได้'
        when not has_function_privilege('authenticated', p.oid, 'execute') then
             'authenticated เรียกไม่ได้ → ระดับที่มีสิทธิ์ก็อ่านไม่ได้'
        else null end as problem) x
   where x.problem is not null
  union all
  -- (6) ทางเข้าต้องครอบ **ทุกคอลัมน์ที่ปิด** และต้องถามสิทธิ์ที่ขึ้นทะเบียนไว้ตรงตัว
  select 'reader_mask', (ce.table_name || '.' || ce.column_name)::text,
         'ฟังก์ชันทางเข้าไม่ได้ครอบคอลัมน์นี้ด้วย fn_can(''' || ce.min_permission || ''')'
    from sri_os.column_exposure ce
   where ce.exposure = 'grant'
     and not exists (
       select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
        where ns.nspname = 'sri_os' and p.proname = 'fn_' || ce.table_name || '_visible'
          and p.prosrc ~ ('fn_can\(''' || ce.min_permission || '''\)[^,]*\m' || ce.column_name || '\M')
     )
  union all
  -- (7) ช่องอ้อมของการจัดประเภทแบบ row บน audit_log: ถ้ามีระดับไหนได้ owner.view_all
  --     แต่ไม่มี portfolio.view_all จะอ่านคอลัมน์ที่ปิดได้จาก before/after
  select 'audit_bypass', rp.role_key::text,
         'ระดับนี้มี owner.view_all (อ่าน audit_log ได้ = เห็นแถวเต็มของทุกตาราง) แต่ไม่มี portfolio.view_all → อ่านคอลัมน์ที่ปิดได้ทางอ้อม'
    from sri_os.role_permissions rp
   where rp.permission_key = 'owner.view_all'
     and not exists (select 1 from sri_os.role_permissions r2
                      where r2.role_key = rp.role_key and r2.permission_key = 'portfolio.view_all')
  union all
  -- (8) role เจ้าของทางเข้าต้องไม่กลายเป็นทางข้าม RLS
  select 'reader_role', 'sri_os_column_reader', x.problem
    from (
      select case
        when not exists (select 1 from pg_roles where rolname = 'sri_os_column_reader')
             then 'ไม่มี role เจ้าของทางเข้า'
        when (select rolsuper or rolbypassrls or rolcanlogin from pg_roles
               where rolname = 'sri_os_column_reader')
             then 'role เจ้าของทางเข้าเป็น superuser/bypassrls/login ได้ → ข้าม RLS'
        when exists (select 1 from pg_roles where rolname = 'authenticated')
             and not pg_has_role('sri_os_column_reader', 'authenticated', 'member')
             then 'role เจ้าของทางเข้าไม่ได้เป็นสมาชิกของ authenticated → policy ที่เขียน to authenticated จะไม่มีผล = ฟังก์ชันคืน 0 แถวทุกคน'
        when exists (select 1 from pg_auth_members m
                      join pg_roles r on r.oid = m.member
                      join pg_roles g on g.oid = m.roleid
                     where g.rolname = 'sri_os_column_reader')
             then 'มี role อื่นเป็นสมาชิกของ sri_os_column_reader → ใช้สิทธิ์ของมันได้โดยไม่ผ่านฟังก์ชัน'
        else null end as problem
    ) x
   where x.problem is not null
  union all
  -- (9) ใหม่ (20261020000002) · ทางอ้อมแบบ definer ที่ข้าม policy ของตาราง row
  select 'row_escape', (e.function_name || ' → ' || e.table_name)::text, e.problem
    from sri_os.fn_column_exposure_row_escapes() e
  union all
  -- (10) ใหม่ · role ที่มี bypassrls ต้องไม่มีสิทธิ์อ่านตารางที่กันด้วยแถว
  --      เพราะ `row` พึ่ง RLS ล้วนๆ → bypassrls = ไม่มีด่านอะไรเลย
  select 'bypassrls_grant', (c.relname || ' → ' || pg_get_userbyid(acl.grantee))::text,
         'role นี้มี bypassrls และมี select บนตารางที่จัดประเภทเป็น row → ข้าม policy ทั้งใบ (ต้องทำทางเข้าแบบ definer แทน ดูหัวไฟล์ 20261020000002 ข้อ 3)'
    from pg_class c
    join pg_namespace ns on ns.oid = c.relnamespace
    cross join lateral aclexplode(c.relacl) acl
    join pg_roles r on r.oid = acl.grantee
   where ns.nspname = 'sri_os' and c.relkind = 'r'
     and acl.privilege_type = 'SELECT'
     and acl.grantee <> c.relowner
     and r.rolbypassrls and not r.rolsuper
     and exists (select 1 from sri_os.column_exposure ce
                  where ce.table_name = c.relname and ce.exposure = 'row')
  union all
  -- (11) ใหม่ · allow-list ต้องอ้างฟังก์ชันที่มีจริง (ชื่อค้าง = ยกเว้นของที่ไม่มี)
  select 'stale_allowlist', (al.function_name || ' → ' || al.table_name)::text,
         'allow-list อ้างฟังก์ชันที่ไม่มีใน sri_os แล้ว → ยกเว้นของที่ไม่มีอยู่ แล้วของจริงหลุด'
    from sri_os.column_exposure_definer_reads al
   where not exists (
     select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
      where ns.nspname = 'sri_os' and p.proname = al.function_name)
$fn$;
comment on function fn_column_exposure_breaches() is
  'D-089 · คืนรายการ "ด่านคอลัมน์ที่ไม่ติดจริง" ทั้งสองทิศ: ที่ควรปิดแต่เปิดอยู่ และที่ควรเปิดแต่ปิดจนหน้าจอพัง · รุ่น 20261020000002 เพิ่มข้อ (9) ทางอ้อมแบบ definer · (10) role ที่มี bypassrls · (11) allow-list ที่อ้างฟังก์ชันที่ไม่มีจริง · ว่าง = ด่านติดครบ';
revoke all on function fn_column_exposure_breaches() from public;
do $$ begin
  execute 'revoke all on function sri_os.fn_column_exposure_breaches() from anon';
  execute 'revoke all on function sri_os.fn_column_exposure_row_escapes() from anon';
  -- trigger ตอนสร้างบัญชี Staff ไม่ใช่ definer → ผู้กดเพิ่มผู้ใช้ (authenticated) ต้องเรียกได้
  execute 'grant execute on function sri_os.fn_column_exposure_breaches() to authenticated';
  execute 'grant execute on function sri_os.fn_column_exposure_row_escapes() to authenticated';
exception when undefined_object then
  raise notice 'ไม่มี role anon/authenticated ในคลัสเตอร์นี้ — ข้าม revoke/grant';
end $$;

-- ============================================================
-- 6 · guard ท้ายไฟล์
-- ============================================================
do $$
declare n int; v text; v2 text;
begin
  perform sri_os.fn_column_exposure_guard();

  -- (ก) ไม่เหลือตารางที่ยังไม่จัดประเภทแม้ตารางเดียว — นี่คือเหตุผลที่ไฟล์นี้มีอยู่
  --     (ถ้าวันหนึ่งต้องเลื่อนตารางใหม่จริง ให้ migration นั้นเขียนเหตุผลไว้ และ
  --      แก้เทสต์ C6 ที่ยืนยันเลข 0 พร้อมกัน — ไม่ใช่เลื่อนเงียบๆ)
  select string_agg(table_name, ', '), count(*) into v, n
    from sri_os.column_exposure_tables where review_state = 'deferred';
  if n > 0 then
    raise exception 'ยังมี % ตารางที่เลื่อนการจัดประเภทไว้: % · สมุดเงินต้องไม่อยู่ในกลุ่มนี้แล้ว (ไฟล์นี้มีไว้เพื่อปิดข้อนั้น)', n, v;
  end if;

  -- (ข) ทั้งสองตารางต้องจัดประเภทครบทุกคอลัมน์จริง (ไล่จาก pg_attribute)
  foreach v in array array['transactions', 'transaction_lines'] loop
    select count(*) into n
      from pg_attribute a
     where a.attrelid = ('sri_os.' || v)::regclass and a.attnum > 0 and not a.attisdropped
       and not exists (select 1 from sri_os.column_exposure ce
                        where ce.table_name = v and ce.column_name = a.attname);
    if n > 0 then
      raise exception 'sri_os.% ยังมี % คอลัมน์ที่ไม่ได้จัดประเภท', v, n;
    end if;
    -- และต้องไม่มีคอลัมน์ไหนเป็น open (สมุดเงินไม่มีคอลัมน์ที่ทุกคนอ่านได้)
    select string_agg(ce.column_name, ', ') into v2
      from sri_os.column_exposure ce where ce.table_name = v and ce.exposure = 'open';
    if v2 is not null then
      raise exception 'สมุดเงิน % มีคอลัมน์ที่จัดเป็น open: % · ต้องเป็น row ทั้งใบ (เหตุผลที่หัวไฟล์)', v, v2;
    end if;
  end loop;

  -- (ค) เหตุผลของ row ต้องยังจริงทั้งสองตาราง (policy + ทางอ้อมแบบ definer)
  if not sri_os.fn_policy_requires_permission('transactions', 'ledger.read')
     or not sri_os.fn_policy_requires_permission('transaction_lines', 'ledger.read') then
    raise exception 'policy อ่านของสมุดเงินไม่ได้บังคับ ledger.read ทุกตัว → เหตุผลของการจัดประเภทแบบ row ตาย';
  end if;
  select count(*) into n from sri_os.fn_column_exposure_row_escapes();
  if n > 0 then
    raise exception 'มีทางอ้อมแบบ definer ที่ยังไม่ได้ตัดสิน % รายการ', n;
  end if;

  -- (ง) กัน guard ใหม่กลายเป็น guard เปล่า: ต้องจับ allow-list ที่รู้ว่ามีอยู่ได้
  --     ถ้าถอน fn_reverse_link_ok ออกจาก allow-list ต้องเจอมันเป็นทางอ้อมทันที
  --     (ตรวจแบบไม่แตะข้อมูลจริง: ถามคำถามเดียวกันแต่ไม่สน allow-list)
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.prosecdef
     and p.proname = 'fn_reverse_link_ok'
     and has_function_privilege('authenticated', p.oid, 'execute');
  if n <> 1 then
    raise exception 'ไม่เจอ fn_reverse_link_ok ที่ authenticated เรียกได้ → คำถามของ guard ข้อ (9) อาจไม่ได้ตรวจอะไรเลย (ถ้าฟังก์ชันถูกถอดจริง ให้ลบออกจาก allow-list ด้วย)';
  end if;

  raise notice 'ด่านคอลัมน์ (D-089) · จัดประเภทครบทุกตารางใน sri_os แล้ว (% แถว · ไม่มี deferred) · สมุดเงิน % คอลัมน์เป็น row ด้วย ledger.read · allow-list ทางอ้อมแบบ definer % รายการ',
    (select count(*) from sri_os.column_exposure),
    (select count(*) from sri_os.column_exposure
      where table_name in ('transactions', 'transaction_lines')),
    (select count(*) from sri_os.column_exposure_definer_reads);
end $$;

-- ============================================================
-- ที่ต้องถามลูกพี่ (เจอรอบนี้ · ไม่ได้แก้เองเพราะเป็นชั้นแถว ไม่ใช่ชั้นคอลัมน์)
--   `transactions.counter_owner_id` · รายการข้ามผู้ถือเก็บผู้ถืออีกฝั่งไว้ในแถว
--   แต่ `fn_can_read_txn()` ตรวจขอบเขตของ `owner_id` ฝั่งเดียว **ไม่ได้ตรวจ
--   fn_can_see_owner(counter_owner_id)** → คนที่เห็นแถวฝั่งหนึ่ง อ่านได้ว่าอีกฝั่ง
--   เป็นผู้ถือรายไหน ทั้งที่อาจไม่มีสิทธิ์เห็นผู้ถือรายนั้น
--   ปิดที่ชั้นคอลัมน์ไม่ได้ (ปิดแล้วหน้าจอรายการข้ามผู้ถือใช้ไม่ได้ทั้งหน้า) และ
--   แก้ `fn_can_read_txn` คือการแตะเส้นทางเงิน → ต้องให้ลูกพี่/mace-windu ตัดสินก่อน
--   ว่า "เห็นขาของตัวเอง = เห็นชื่อผู้ถืออีกฝั่งได้" หรือต้องซ่อน
-- ============================================================
