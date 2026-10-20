-- ============================================================
-- SRI OS · D-098 — รายการที่ void ต้อง "เห็นได้ แต่ตัดออกจากงบ" (ลูกพี่สั่ง 09/10)
--   เทสต์: supabase/tests/zz_void_ledger_test.sql
--   ของเดิมเรื่อง void ที่ไฟล์นี้ **ต่อ ไม่ใช่เขียนทับ**:
--     20261007000000 · fn_void_is_terminal     (ออกจาก void ไม่ได้)
--                    · fn_corporate_immutable  (corporate แก้ได้เฉพาะ → void คง doc_date)
--                    · trg_force_view_security_invoker (event trigger บังคับ view ใหม่)
--     20261009000000 · fn_void_blocked_by_reverse (มีใบกลับรายการที่ยังนับ → void ไม่ได้)
--                    · fn_period_locked_on_void   (งวดปิดแล้ว corporate void ไม่ได้)
--     20261008000004 · แพทเทิร์น "คอลัมน์แก้ย้อนหลังไม่ได้" + guard ท้ายไฟล์
--   ไฟล์นี้ **ไม่ create or replace ฟังก์ชันของไฟล์อื่นแม้ตัวเดียว** (D-104)
--   ทุกอย่างเป็นชื่อใหม่: fn_void_audit_columns() · v_ledger_posted · v_ledger_voided
--
-- ------------------------------------------------------------
-- ทำอะไร (3 ส่วน)
-- ------------------------------------------------------------
-- (1) transactions ได้ voided_at · voided_by · void_reason
--     D-098: "เห็นได้" โดยไม่รู้ว่าใคร/เมื่อไหร่/ทำไม = **ผีที่ไม่มีคำอธิบาย**
--     ซึ่งทำลายเหตุผลทั้งหมดของการเก็บไว้ให้เห็น (ผู้สอบบัญชีถามแล้วตอบไม่ได้)
--     · void_reason **บังคับทุกผู้ถือ** ไม่ใช่แค่ corporate_strict (D-098 ตัดสินแล้ว)
--       เหตุผลหนึ่งบรรทัดคือทั้งหมดที่ทำให้ของที่เก็บไว้มีประโยชน์ → เป็น Money Invariant
--       ไม่ใช่กติกาเอกสารของนิติบุคคล (ฝั่งบุคคล override ได้แค่กติกาเอกสาร)
--     · เงื่อนไข **สองทาง** ที่ check constraint:
--         status = 'void'  → ทั้งสามคอลัมน์ต้องมีค่า
--         มีค่าสักคอลัมน์   → status ต้องเป็น 'void'
--       ทิศที่สองสำคัญเท่าทิศแรก: ไม่งั้นแปะ "เหตุผลที่ยกเลิก" ค้างไว้บนรายการที่ยัง
--       posted ได้ แล้วคนอ่านสมุดเห็นรายการที่ดูเหมือนถูกยกเลิกแต่ยังนับอยู่ในงบ
--     · voided_by เป็น **uuid อ้าง app_users** ไม่ใช่ text — "คนจริงที่ตรวจสอบย้อนได้"
--       ต้องเป็นแถวที่มีอยู่จริง ไม่ใช่ข้อความที่พิมพ์อะไรก็ได้
--     · ทั้งสามคอลัมน์ **แก้ย้อนหลังไม่ได้** (ต่อแพทเทิร์น 20261008000004)
--
-- (2) v_ledger_posted (งบทุกใบอ่านที่นี่ · ไม่มี void) ·
--     v_ledger_voided  (หน้า "รายการที่ยกเลิก" · void เท่านั้น)
--     "ไปเก็บอีกที่" = แยกด้วย view **ไม่ใช่ย้ายแถว** (D-098 ให้เหตุผลไว้ 3 ข้อ:
--     ย้าย = delete+insert ละเมิดกฎเหล็กข้อ 1 · reverses_id เป็น FK ชี้ transactions
--     ลิงก์จะขาด · audit_log อ้าง id นั้นอยู่ ร่องรอยจะชี้ไปของที่ไม่มี)
--     ทั้งสอง view เป็น **ระดับบรรทัด** (join transaction_lines) เพราะงบต้องรวม
--     debit/credit ไม่ใช่นับหัวรายการ
--
-- (3) guard ที่พังเมื่อมี view/รายงานใหม่อ่านตารางฐานตรงๆ แทน v_ledger_posted
--     (แพทเทิร์น guard ท้ายไฟล์ของ 20261008000004) — ข้อนี้สำคัญเท่าตัว view เอง
--
-- ------------------------------------------------------------
-- ร่าง / รออนุมัติ อยู่ฝั่งไหน — ตัดสินแล้ว
-- ------------------------------------------------------------
-- วันนี้ `txn_status` มีสองค่าเท่านั้น: 'posted' · 'void' (20260917000002 บรรทัด 13)
-- **ร่างไม่ได้อยู่ในตาราง transactions เลย** — อยู่ตาราง `draft_entries` ต่างหาก
-- (กฎเหล็กข้อ 6: automation สร้างได้แค่ draft) → ร่างจึง **ไม่อยู่ใน view ไหนทั้งสองอัน**
-- โดยเจตนา และนั่นถูกต้อง: "งบ" ต้องไม่รวมร่าง และ "รายการที่ยกเลิก" ก็ไม่ใช่ร่าง
-- หน้าจอคิวร่างต้องอ่าน draft_entries ตามเดิม ไม่ใช่สองวิวนี้
--
-- v_ledger_posted กรองด้วย **allow-list `status = 'posted'`** ไม่ใช่ `status <> 'void'`
--   เหตุผล: ถ้าวันหนึ่งมีใครเพิ่มค่าใหม่ใน txn_status (เช่น 'pending_approval')
--   `<> 'void'` จะ **ดูดแถวที่ยังไม่อนุมัติเข้างบทุกใบเงียบๆ** ซึ่งเป็นรูปแบบเดิมของ
--   บั๊กที่โปรเจกต์นี้เจอซ้ำที่สุด · allow-list ทำให้แถวนั้น "ตกหล่นทั้งสองฝั่ง"
--   = เห็นผิดทันทีและไม่มีตัวเลขไหนผิด ดีกว่างบที่ผิดเงียบๆ
-- v_ledger_voided กรองด้วย `status = 'void'` เท่านั้น (ไม่ใช่ `<> 'posted'`) ด้วยเหตุผลคู่กัน
--
-- วันนี้สองฝั่งจึง **แบ่งกันครบและไม่ทับกัน** (เพราะ enum มีสองค่า) และ guard ข้อ (3)
--   จะ **พังทันที** ถ้ามีใครเพิ่มค่าใน txn_status โดยไม่กลับมาตัดสินว่าค่านั้นอยู่ฝั่งไหน
--   (เทสต์ V7/V8 วนทุก enumlabel จริง ไม่ใช่สองค่าที่นึกออก)
--
-- ------------------------------------------------------------
-- สิทธิ์อ่าน: สิ่งที่ทำได้จริง และสิ่งที่ D-098 เขียนไว้แต่ **ทำไม่ได้**
-- ------------------------------------------------------------
-- D-098 เสนอว่า `revoke select on transactions / transaction_lines from authenticated`
--   แล้ว grant select ให้เฉพาะสอง view → "เขียนรายงานที่ลืมกรอง void ไม่ได้"
--
-- **ทำแบบนั้นไม่ได้ และไฟล์นี้ไม่ทำ** เพราะขัดกับข้อบังคับ security_invoker ของรีโปนี้:
--   Postgres: view ที่ `security_invoker = true` ตรวจสิทธิ์ **ตารางฐาน** ด้วยสิทธิ์ของ
--   ผู้เรียก ไม่ใช่เจ้าของ view → ถอน select ของตารางฐานออก = ทั้งสอง view
--   คืน `permission denied for table transactions` ให้ทุกคน (วัดเองแล้วบน pg16)
--   และ event trigger `trg_force_view_security_invoker` (20261007000000) บังคับให้
--   view ทุกตัวในสคีมานี้เป็น security_invoker อยู่แล้ว จะเลี่ยงด้วย view แบบ definer
--   ก็ไม่ได้ และถ้าเลี่ยงได้ก็ผิดกติกาอีกข้อ (view ต้องเคารพ RLS ของผู้เรียก)
--   นอกจากนี้ `fn_post_entry` (20261008000008) **ไม่ใช่ security definer** — มันอ่าน
--   transactions ด้วยสิทธิ์ผู้คีย์ → revoke แล้วเส้นทางลงบัญชีจริงตายทั้งเส้น
--
-- สิ่งที่ไฟล์นี้ทำแทน (บีบเท่าที่บีบได้จริง ไม่ลดความเข้มของอย่างอื่นเพื่อแลก):
--   · grant select ให้สอง view · ย้ำ revoke all ของตารางฐาน+view จาก anon/public
--   · **guard ข้อ (3)** = ชั้นที่บีบจริง: view หรือฟังก์ชันรายงาน (set-returning) ตัวใหม่
--     ที่อ่าน transactions / transaction_lines ตรงๆ ทำให้ migration **พัง**
--     ต้องอ่านผ่าน v_ledger_posted หรือเพิ่มเข้า allow-list พร้อมเหตุผลเท่านั้น
--   เรื่องที่เหลือ (ปิดตารางฐานไม่ให้ authenticated อ่านเลย) ต้องเปลี่ยนนโยบาย
--   security_invoker ของทั้งสคีมา = งานแยกที่ต้องให้ลูกพี่/mace-windu ตัดสินก่อน
--   **ห้ามปิดครึ่งเดียว** (บทเรียนข้อ 7)
--
-- ทางที่ทำได้จริงถ้าวันหนึ่งจะปิดตารางฐาน (เขียนไว้เพราะรอบนี้พิสูจน์แล้วว่าทางตรงตาย):
--   D-089 (20261020000000_column_exposure) ลงแพทเทิร์นที่ใช้ได้ไว้แล้ว —
--   ฟังก์ชัน `security definer` ที่ **เจ้าของเป็น role ซึ่งเป็นสมาชิกของ authenticated**
--   (`sri_os_column_reader`) → RLS ยังกรองแถวตาม auth.uid() ของผู้เรียก โดยที่
--   ผู้เรียกไม่ต้องมี select บนตารางฐาน · ทำ fn_ledger_posted() แบบเดียวกันแล้ว
--   revoke ตารางฐานได้จริง **แต่** ต้องแก้สองอย่างพร้อมกัน: allow-list ของ guard 6b
--   (ฟังก์ชันรายงานที่อ่านตารางฐานตรงๆ) และ fn_post_entry ที่ยังอ่านด้วยสิทธิ์ผู้คีย์
--   → งานแยก ต้องคุยกับ D-089 ซึ่งจดไว้แล้วว่า transactions/transaction_lines
--     ยัง `deferred` รอรอบนี้ปิด (ดูแถว seed ของ column_exposure_tables)
--
-- ------------------------------------------------------------
-- ย้อนกลับ (rollback) — เรียงตามนี้ ไม่งั้น view ค้างอ้างคอลัมน์ที่ถูกลบ
-- ------------------------------------------------------------
--   -- revoke select on sri_os.v_ledger_posted, sri_os.v_ledger_voided from authenticated;
--   -- drop view if exists sri_os.v_ledger_voided;
--   -- drop view if exists sri_os.v_ledger_posted;
--   -- drop trigger if exists trg_void_audit_columns on sri_os.transactions;
--   -- drop function if exists sri_os.fn_void_audit_columns();
--   -- alter table sri_os.transactions
--   --   drop constraint if exists transactions_void_fields_both_ways;
--   -- alter table sri_os.transactions
--   --   drop column if exists void_reason,
--   --   drop column if exists voided_by,
--   --   drop column if exists voided_at;
--   -- (ย้อนแล้ว: รายการที่ยกเลิกกลับเป็นผีที่ไม่มีคำอธิบาย **และ** งบไม่มีแหล่งอ่าน
--   --  กลางอีก → คนเขียนรายงานต้องจำเองว่าต้องกรอง void ซึ่งคือบั๊กที่ D-098 ปิด
--   --  ถ้าย้อนเพราะ void_reason เข้ม: ใส่เหตุผลให้ถูก ไม่ใช่ถอนด่าน)
--   -- ข้อมูลในสามคอลัมน์หายถาวรเมื่อ drop column — ก่อนย้อนให้ dump
--   --   select id, voided_at, voided_by, void_reason from sri_os.transactions
--   --    where status = 'void'   ไว้ก่อน
--
-- idempotent: add column if not exists · add constraint ในบล็อกที่กลืน duplicate_object ·
--   create or replace function/view (ชื่อใหม่ทั้งหมด) · drop trigger if exists ก่อน create ·
--   grant/revoke ซ้ำได้ · guard ท้ายไฟล์อ่าน catalog ไม่เขียนอะไร
-- ============================================================

set search_path = sri_os, public;

-- ------------------------------------------------------------
-- 0 · ด่านก่อนเริ่ม — ไฟล์นี้ต้องรันหลังของเดิมที่มันต่อ
--     (ถ้าลำดับผิด ของที่ไฟล์นี้สร้างจะดูเหมือนครบแต่กฎที่มันพึ่งไม่อยู่)
-- ------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'sri_os.transactions'::regclass
                    and tgname = 'trg_void_is_terminal') then
    raise exception 'ไม่พบ trg_void_is_terminal บน transactions → 20261007000000 ยังไม่ถูก apply · ไฟล์นี้ต้องรันหลังไฟล์นั้น (คอลัมน์ void ที่แก้ย้อนหลังไม่ได้ พึ่งกฎ "ออกจาก void ไม่ได้" เป็นชั้นล่าง)';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'sri_os.transactions'::regclass
                    and tgname = 'trg_void_blocked_by_reverse') then
    raise exception 'ไม่พบ trg_void_blocked_by_reverse บน transactions → 20261009000000 ยังไม่ถูก apply · ไฟล์นี้ต้องรันหลังไฟล์นั้น (D-097/D-098 เป็นชุดเดียวกัน)';
  end if;
end $$;

-- ------------------------------------------------------------
-- 1 · คอลัมน์บันทึกการ void
--
-- voided_by อ้าง app_users(id) ไม่ใช่ auth.users(id) ให้ตรงกับ created_by / approved_by
--   ของตารางเดียวกัน (คนที่ "ใช้ระบบนี้" ไม่ใช่ทุกบัญชีใน auth)
--   **ไม่มี on delete cascade/set null** โดยตั้งใจ: ลบคนที่เคยยกเลิกรายการแล้วให้
--   ร่องรอยหายไปเงียบๆ ไม่ได้ · app_users ลบไม่ออกถ้ายังมีรายการชี้อยู่ ซึ่งถูกต้อง
--   (เลิกใช้งานคนให้ตั้ง is_active = false ไม่ใช่ลบแถว)
-- ------------------------------------------------------------
alter table transactions add column if not exists voided_at  timestamptz;
alter table transactions add column if not exists voided_by  uuid references app_users(id);
alter table transactions add column if not exists void_reason text;

comment on column transactions.voided_at is
  'D-098 · เวลาที่ยกเลิกรายการนี้ · มีค่าเมื่อ status = void เท่านั้น และแก้ย้อนหลังไม่ได้';
comment on column transactions.voided_by is
  'D-098 · คนที่ยกเลิก (app_users) · ต้องเป็นคนจริงที่ตรวจสอบย้อนได้ ไม่ใช่ข้อความ · แก้ย้อนหลังไม่ได้';
comment on column transactions.void_reason is
  'D-098 · เหตุผลที่ยกเลิก · **บังคับทุกผู้ถือ** (Money Invariant ไม่ใช่กติกาเอกสาร) · ว่าง/ช่องว่างล้วนไม่ผ่าน · แก้ย้อนหลังไม่ได้';

-- ------------------------------------------------------------
-- 2 · เงื่อนไขสองทางที่ชั้น constraint
--
-- ทำไมเป็น check constraint ไม่ใช่ trigger: นี่เป็น "รูปร่างของแถว" ที่ต้องจริงเสมอ
--   ทุกเส้นทาง (insert · update · copy) และ constraint ปิดไม่ได้ด้วย session_replication_role
--   เหมือน trigger · ส่วนกฎที่ต้องเทียบ old กับ new (แก้ย้อนหลัง) อยู่ที่ trigger ข้อ 3
--
-- `not valid` แล้วค่อย validate: แถว void ที่ลงไว้ **ก่อน** ไฟล์นี้ยังไม่มีเหตุผล และ
--   เราคิดเหตุผลย้อนหลังแทนคนแทนไม่ได้ (เดา = หลักฐานปลอม) · not valid ยังบังคับกับ
--   ทุก insert/update ตั้งแต่นี้ไป รวมการ update แถวเก่าพวกนั้น → รูไม่เปิด
--   แล้ว validate ในบล็อกด้านล่าง: DB ที่สะอาดจะ valid จริง · DB ที่มีประวัติจะได้ warning
--   พร้อมจำนวนแถวที่ต้องตามเก็บ (raise ที่นี่ = migrate ของจริงล้มเพราะอดีต ซึ่งแก้ด้วย
--   ไฟล์นี้ไม่ได้ · หลักเดียวกับ guard ท้าย 20261009000000)
-- ------------------------------------------------------------
do $$
begin
  alter table transactions add constraint transactions_void_fields_both_ways
    check (
      (status = 'void') = (voided_at is not null)
      and (status = 'void') = (voided_by is not null)
      and (status = 'void') = (void_reason is not null and btrim(void_reason) <> '')
    ) not valid;
exception
  when duplicate_object then null;   -- รันซ้ำ
end $$;

do $$
declare n int;
begin
  alter table transactions validate constraint transactions_void_fields_both_ways;
  raise notice 'transactions_void_fields_both_ways · validate ผ่าน (ไม่มีแถวในอดีตที่ขัด)';
exception when check_violation then
  select count(*) into n from transactions
   where (status = 'void') <> (voided_at is not null)
      or (status = 'void') <> (voided_by is not null)
      or (status = 'void') <> (void_reason is not null and btrim(void_reason) <> '');
  raise warning 'มีรายการ % แถวที่ยกเลิกไว้ก่อนไฟล์นี้และยังไม่มี voided_at/voided_by/void_reason → constraint ยังอยู่สถานะ not valid (บังคับกับของใหม่ครบแล้ว แต่ของเก่ายังเป็นผีไม่มีคำอธิบาย) · ให้ตามเก็บด้วย migration ที่เติมค่าจาก audit_log แล้ว validate ซ้ำ: select id, doc_date, owner_id from sri_os.transactions where status = ''void'' and void_reason is null;', n;
end $$;

-- ------------------------------------------------------------
-- 3 · แก้ย้อนหลังไม่ได้ + ค่าที่ใส่ต้องเป็นของจริง (trigger · ชื่อใหม่ ไม่ทับใคร)
--
-- สามเรื่องในตัวเดียว เพราะทั้งสามต้องดู old/new คู่กัน:
--   (ก) ตอนเปลี่ยนเป็น void: voided_at ต้องไม่อยู่ในอนาคต และไม่ก่อนวันที่สร้างรายการ
--       (ปลอมเวลายกเลิกให้ย้อนไปอยู่ในงวดก่อนหน้าได้ = ร่องรอยโกหก)
--       และ voided_by ต้องเป็น **ผู้ใช้ที่กำลังทำ** เมื่อรู้ว่าใครทำ (auth.uid() ไม่ null)
--       → โยนความผิดให้คนอื่นไม่ได้ · เมื่อ auth.uid() เป็น null (migration / งานระบบ)
--         ยังต้องเป็นแถวจริงใน app_users ตาม FK แต่ไม่บังคับว่าเป็นใคร เพราะ
--         "เดาว่าใครทำ" แย่กว่า "บอกว่าทำโดยงานระบบและชี้ตัวคนที่รับผิดชอบ"
--   (ข) แถวที่ void แล้ว: ทั้งสามคอลัมน์แก้/ล้างไม่ได้อีกเลย ทุก role รวมเจ้าของฐานข้อมูล
--       (คู่กับ fn_void_is_terminal ที่ห้ามออกจาก void → void แล้วแช่แข็งถาวร)
--   (ค) แถวที่ยังไม่ void: แปะค่าค้างไว้ไม่ได้ (check constraint กันอยู่แล้ว ·
--       ที่นี่ให้ข้อความที่อ่านรู้เรื่องกว่า "violates check constraint")
--
-- **ไม่เป็น security definer และไม่เรียกฟังก์ชันตรวจสิทธิ์** — กฎเงินต้องเท่ากัน
--   ทุกตำแหน่งและปิดจากหน้า Settings ไม่ได้ (หลักเดียวกับ 20261008000004)
--   อ่าน auth.uid() เท่านั้น ซึ่งเป็นค่าของ session ไม่ใช่ตารางสิทธิ์
-- ------------------------------------------------------------
create or replace function fn_void_audit_columns() returns trigger
language plpgsql set search_path = '' as $fn$
declare
  v_uid uuid := auth.uid();
begin
  -- (ค) ยังไม่ void แต่มีค่าค้าง
  if new.status::text <> 'void'
     and (new.voided_at is not null or new.voided_by is not null or new.void_reason is not null) then
    raise exception 'D-098: แปะ voided_at/voided_by/void_reason ไว้บนรายการที่สถานะเป็น % ไม่ได้ (id %) · สามคอลัมน์นี้มีค่าได้เมื่อ status = void เท่านั้น ไม่งั้นสมุดจะมีรายการที่ดูเหมือนถูกยกเลิกแต่ยังนับในงบ',
      new.status, new.id;
  end if;

  -- (ข) void แล้ว = แช่แข็ง (เทียบเฉพาะตอน UPDATE)
  if tg_op = 'UPDATE' and old.status::text = 'void' then
    if new.voided_at is distinct from old.voided_at
       or new.voided_by is distinct from old.voided_by
       or new.void_reason is distinct from old.void_reason then
      raise exception 'D-098 / กฎเหล็กข้อ 1: ร่องรอยการยกเลิกแก้ย้อนหลังไม่ได้ทุกกรณีทุกผู้ใช้ (รวมเจ้าของฐานข้อมูล) · id % · เวลา % -> % · ผู้ยกเลิก % -> % · เหตุผล % -> % · ถ้าเหตุผลที่บันทึกไว้ผิด ให้บันทึกคำอธิบายเพิ่มที่อื่น (audit_log เก็บ before-after ไว้แล้ว) ไม่ใช่เขียนทับหลักฐานเดิม',
        old.id, old.voided_at, new.voided_at, old.voided_by, new.voided_by,
        old.void_reason, new.void_reason;
    end if;
    return new;
  end if;

  -- (ก) กำลังเปลี่ยนเป็น void (หรือ insert เข้ามาเป็น void เลย)
  if new.status::text = 'void' then
    -- ร่องรอยต้องครบ · constraint transactions_void_fields_both_ways กันเรื่องนี้
    --   อยู่แล้ว (และเป็นชั้นที่ปิดไม่ได้) · ที่นี่ซ้ำอีกชั้นเพื่อ **ข้อความที่ผู้ใช้
    --   อ่านรู้เรื่อง** ว่าขาดช่องไหน ไม่ใช่ "violates check constraint ..."
    --   เทสต์ V1h/V2e ปิด trigger นี้แล้วพิสูจน์ว่าชั้น constraint ยังปฏิเสธจริง
    --   (ไม่งั้นวันหนึ่งใครถอดเงื่อนไขออกจาก constraint แล้วไม่มีเทสต์ไหนแดง)
    if new.voided_at is null or new.voided_by is null
       or new.void_reason is null or btrim(new.void_reason) = '' then
      raise exception 'D-098: ยกเลิกรายการต้องบันทึกให้ครบทั้งสามช่อง (id %) · ขาด: % · เหตุผลบังคับทุกผู้ถือ ไม่ใช่แค่นิติบุคคล เพราะรายการที่ยกเลิกแล้วยังเห็นอยู่ในสมุด ถ้าไม่มีเหตุผลก็เป็นผีที่ไม่มีคำอธิบาย (ผู้สอบบัญชีถามว่าทำไมเดือนนั้นหายไปหนึ่งใบ แล้วตอบไม่ได้)',
        new.id,
        concat_ws(' · ',
          case when new.voided_at is null then 'voided_at (เมื่อไหร่)' end,
          case when new.voided_by is null then 'voided_by (ใคร)' end,
          case when new.void_reason is null or btrim(new.void_reason) = ''
               then 'void_reason (ทำไม)' end);
    end if;
    if new.voided_at > now() then
      raise exception 'D-098: voided_at อยู่ในอนาคต (% > %) · เวลาที่ยกเลิกต้องเป็นเวลาที่เกิดขึ้นจริง (id %)',
        new.voided_at, now(), new.id;
    end if;
    if new.voided_at < new.created_at then
      raise exception 'D-098: voided_at (%) ก่อนเวลาที่สร้างรายการ (%) · ยกเลิกก่อนที่รายการจะมีอยู่ไม่ได้ · ตั้งเวลายกเลิกย้อนหลังเข้างวดก่อนหน้า = ร่องรอยที่โกหก (id %)',
        new.voided_at, new.created_at, new.id;
    end if;
    -- ตรวจเฉพาะเมื่อมีค่า (กรณีไม่มีค่าถูกปฏิเสธไปแล้วข้างบน ด้วยข้อความที่ตรงเรื่อง
    -- ไม่ใช่ "บันทึกว่าคนอื่นเป็นคนยกเลิก" ซึ่งจะชี้ผิดจุดให้คนอ่าน)
    if v_uid is not null and new.voided_by is not null and new.voided_by <> v_uid then
      raise exception 'D-098: voided_by (%) ไม่ใช่ผู้ใช้ที่กำลังยกเลิก (%) · บันทึกว่าคนอื่นเป็นคนยกเลิกไม่ได้ (id %)',
        new.voided_by, v_uid, new.id;
    end if;
  end if;

  return new;
end $fn$;

comment on function fn_void_audit_columns() is
  'D-098 · ร่องรอยการยกเลิก (voided_at · voided_by · void_reason): ใส่ค่าค้างบนรายการที่ยังไม่ void ไม่ได้ · void แล้วแก้/ล้างย้อนหลังไม่ได้ทุก role · เวลาต้องไม่อยู่ในอนาคตและไม่ก่อนวันสร้างรายการ · ผู้ยกเลิกต้องเป็นผู้ใช้ที่กำลังทำเมื่อรู้ว่าใครทำ · ไม่ใช่ security definer และไม่ถามตารางสิทธิ์ (กฎเงินห้ามขึ้นกับสิทธิ์)';

drop trigger if exists trg_void_audit_columns on transactions;
create trigger trg_void_audit_columns
  before insert or update on transactions
  for each row execute function fn_void_audit_columns();

-- trigger function ต้องเรียกจากข้างนอกไม่ได้ · Postgres ตรวจสิทธิ์ตอน create trigger
-- ไม่ใช่ตอนยิง · 20261007000007 ไล่จาก pg_proc **ตอนที่มันรัน** → ของที่เพิ่มทีหลัง
-- ถือ ACL เริ่มต้น = PUBLIC EXECUTE ถ้าไม่ถอนที่นี่ (ไฟล์นี้ถอนเอง ไม่ฝากไฟล์อื่น)
revoke all on function fn_void_audit_columns() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_void_audit_columns() from anon, authenticated';
exception when undefined_object then null;   -- เครื่องที่ไม่มี role ของ Supabase
end $$;

-- ------------------------------------------------------------
-- 4 · สอง view — แหล่งเดียวของงบ และหน้า "รายการที่ยกเลิก"
--
-- ระดับบรรทัด (join transaction_lines) เพราะงบต้องรวม debit/credit
--   หัวรายการทุกใบมี >= 2 บรรทัดบังคับอยู่แล้ว (trg_txn_needs_lines · 20261007000000)
--   → ไม่มีหัวรายการที่ "ไม่มีบรรทัด" หลุดออกจากทั้งสองฝั่ง
--
-- ชื่อคอลัมน์ที่ชนกันระหว่างหัวรายการกับบรรทัด (id · asset_id · memo) ตั้งชื่อให้ต่างชัดเจน
--   **ห้ามใช้ t.* / l.*** : คอลัมน์ใหม่ของตารางฐานจะไหลเข้างบเองโดยไม่มีใครตัดสิน
--   (เรื่องเดียวกับ D-089 ที่กำลังทำขนาน) · เพิ่มคอลัมน์ในวิวต้องเป็นการตัดสินใจที่เห็นใน git
--
-- security_invoker = true: ผลถูกกรองด้วย RLS ของ **ผู้เรียก** ไม่ใช่เจ้าของ view
--   (เหมือน v_asset_valuation_current · v_asset_latest_value · v_contract_data_health)
--   ถ้าไม่ตั้ง → ทุกคนที่อ่าน view ได้จะเห็นสมุดของทุกผู้ถือ
--   ตั้งซ้ำด้วย alter view ด้านล่างอีกรอบ เพราะ `create or replace view` บน view ที่มี
--   อยู่แล้วไม่เปลี่ยน reloptions ให้ (ของเดิมอาจถูกตั้งไว้ต่าง)
-- ------------------------------------------------------------
create or replace view v_ledger_posted with (security_invoker = true) as
select
  t.id                  as transaction_id,
  t.owner_id,
  t.txn_type_code,
  t.doc_date,
  t.cash_date,
  t.doc_no,
  t.status,
  t.asset_id            as txn_asset_id,
  t.contact_id,
  t.contract_id,
  t.is_intercompany,
  t.counter_owner_id,
  t.intercompany_nature,
  t.memo                as txn_memo,
  t.attachments,
  t.source,
  t.source_ref,
  t.reverses_id,
  t.created_by,
  t.approved_by,
  t.created_at,
  l.id                  as line_id,
  l.coa_id,
  l.bank_account_id,
  l.debit,
  l.credit,
  l.cf_category,
  l.asset_id            as line_asset_id,
  l.memo                as line_memo
from transactions t
join transaction_lines l on l.transaction_id = t.id
-- allow-list ไม่ใช่ <> 'void' — เหตุผลอยู่หัวไฟล์ (ค่าสถานะใหม่ต้องไม่ไหลเข้างบเอง)
where t.status = 'posted';

alter view v_ledger_posted set (security_invoker = true);

comment on view v_ledger_posted is
  'D-098 · แหล่งความจริงเดียวของงบทุกใบ (ระดับบรรทัด) · ไม่มีรายการที่ยกเลิก · **มีทั้งต้นฉบับและใบกลับรายการ (source = reverse) ห้ามกรองใบกลับรายการออก** เพราะมันคือขาที่ทำให้ยอดสุทธิเป็นศูนย์ (D-097) · ร่างไม่อยู่ในนี้ (ร่างอยู่ตาราง draft_entries) · security_invoker = กรองด้วย RLS ของผู้เรียก';

create or replace view v_ledger_voided with (security_invoker = true) as
select
  t.id                  as transaction_id,
  t.owner_id,
  t.txn_type_code,
  t.doc_date,
  t.cash_date,
  t.doc_no,
  t.status,
  t.asset_id            as txn_asset_id,
  t.contact_id,
  t.contract_id,
  t.is_intercompany,
  t.counter_owner_id,
  t.intercompany_nature,
  t.memo                as txn_memo,
  t.attachments,
  t.source,
  t.source_ref,
  t.reverses_id,
  t.created_by,
  t.approved_by,
  t.created_at,
  t.voided_at,
  t.voided_by,
  t.void_reason,
  l.id                  as line_id,
  l.coa_id,
  l.bank_account_id,
  l.debit,
  l.credit,
  l.cf_category,
  l.asset_id            as line_asset_id,
  l.memo                as line_memo
from transactions t
join transaction_lines l on l.transaction_id = t.id
where t.status = 'void';

alter view v_ledger_voided set (security_invoker = true);

comment on view v_ledger_voided is
  'D-098 · หน้า "รายการที่ยกเลิก" — เห็นได้แต่ไม่อยู่ในงบ · มีร่องรอยครบ (voided_at · voided_by · void_reason) ไม่งั้นเป็นผีที่ไม่มีคำอธิบาย · **ห้ามใช้ทำงบ** · security_invoker = กรองด้วย RLS ของผู้เรียก';

-- ------------------------------------------------------------
-- 5 · สิทธิ์
--   authenticated ต้องอ่านสอง view ได้ (default privileges ของ 20261007000001 ให้
--   select มาแล้วกับ "tables" ซึ่งรวม view — grant ตรงๆ ซ้ำที่นี่เพื่อให้ไฟล์นี้
--   ปลอดภัยถ้าถูก apply ลำพัง และเพื่อให้ guard ข้อ 6 ตรวจเจอของที่ไฟล์นี้รับผิดชอบ)
--   anon ห้ามแตะอะไรเลย (ทุกหน้าของระบบนี้ต้องล็อกอิน)
--   PUBLIC ห้ามแตะ — view ใหม่ที่สร้างโดย role อื่นอาจติด ACL เริ่มต้นมา
-- ------------------------------------------------------------
-- อ่านอย่างเดียว · ถอน insert/update/delete ที่ 20261007000001 แจกเป็นชุดให้ "ทุกตาราง"
--   (view ก็นับเป็น table ใน `grant ... on all tables`) · วิวรายงานต้องเขียนไม่ได้:
--   เขียนผ่าน view = เส้นทางเขียนสมุดเส้นที่สอง ที่คนตรวจไม่ได้ไล่ด่านไว้
--   (วันนี้เป็น JOIN จึงไม่ auto-updatable อยู่แล้ว แต่ถ้าวันหนึ่งใครทำวิวให้เขียนได้
--    หรือเติม INSTEAD OF trigger สิทธิ์ที่ค้างอยู่จะกลายเป็นประตูทันที — ถอนตั้งแต่ตอนนี้)
revoke insert, update, delete, truncate, references, trigger
  on v_ledger_posted, v_ledger_voided from authenticated;
grant select on v_ledger_posted, v_ledger_voided to authenticated;
revoke all on v_ledger_posted, v_ledger_voided from public;
do $$
begin
  execute 'revoke all on sri_os.v_ledger_posted, sri_os.v_ledger_voided from anon';
  execute 'revoke all on sri_os.transactions, sri_os.transaction_lines from anon';
exception when undefined_object then null;
end $$;

-- ------------------------------------------------------------
-- 6 · guard — ของใหม่ในอนาคตต้องไม่หลุดเงียบๆ
--
-- ข้อนี้สำคัญเท่าตัว view เอง: โปรเจกต์นี้พลาดจากของที่เพิ่มมาทีหลังซ้ำหลายครั้ง
-- (20261008000010 ครอบแต่ txn_types → ผังบัญชีใน DB ขาด 3 รหัส และไม่มีอะไรจับได้)
--
-- "รายงาน" = ของที่คืนหลายแถวให้คนอ่าน → view · materialized view ·
--   ฟังก์ชัน set-returning · ของพวกนี้ที่อ่าน transactions / transaction_lines
--   **ตรงๆ** คือจุดที่ลืมกรอง void ได้ → ต้องอยู่ใน allow-list พร้อมเหตุผล
--
-- ไล่จาก catalog (pg_rewrite / pg_depend / pg_proc) ไม่ใช่รายชื่อที่พิมพ์มือ
--   → ของที่มีอยู่วันนี้ครบแน่ และของใหม่ในอนาคตถูกจับทั้งใน migration และในเทสต์
--   (เทสต์คือชั้นที่จับของใหม่จริง เพราะไฟล์นี้รันครั้งเดียว ส่วนเทสต์รันทุกรอบ
--    บนสคีมาที่รวม migration ใหม่ทุกไฟล์แล้ว — หลักเดียวกับ H8 ของ 20261008000004)
--
-- trigger function ไม่นับ (prorettype = trigger): มันต้องอ่านตารางฐานเพื่อบังคับกฎ
--   รวมแถวที่ void แล้ว · เช่น fn_void_blocked_by_reverse ต้องเห็นแถว void โดยเจตนา
-- ฟังก์ชันคืนค่าเดี่ยวไม่นับ: fn_reverse_link_ok · fn_real_evidence_count ฯลฯ
--   ตอบคำถาม "ใช่/ไม่ใช่" ของด่าน ไม่ใช่รายงานตัวเลขให้คนอ่าน
-- ------------------------------------------------------------

-- 6a-6d อยู่ใน **ฟังก์ชันเดียว** ไม่ใช่ do block
--   เพราะเทสต์ต้องเรียก "กฎตัวเดียวกัน" ซ้ำหลังสร้างของที่ละเมิดขึ้นมา
--   ถ้าเขียน query ซ้ำในเทสต์ = กฎเดียวกันอยู่สองที่ แล้ววันหนึ่งสองที่จะไม่ตรงกัน
--   (บทเรียนข้อ 5 ของ mace-windu) · migration เรียกมันหนึ่งครั้งด้านล่าง
create or replace function fn_assert_ledger_read_path() returns void
language plpgsql stable set search_path = '' as $fn$
declare v text; n int;
begin
  -- (6a) view / materialized view ที่อ่านตารางฐานตรงๆ
  select string_agg(distinct nd.nspname || '.' || dep.relname
                             || ' (relkind ' || dep.relkind::text || ')', ', ') into v
    from pg_depend d
    join pg_rewrite r   on r.oid = d.objid
    join pg_class  dep  on dep.oid = r.ev_class
    join pg_class  base on base.oid = d.refobjid
    join pg_namespace nb on nb.oid = base.relnamespace
    join pg_namespace nd on nd.oid = dep.relnamespace
   where d.classid    = 'pg_rewrite'::regclass
     and d.refclassid = 'pg_class'::regclass
     and nb.nspname = 'sri_os'
     and base.relname in ('transactions', 'transaction_lines')
     and dep.relkind in ('v', 'm')
     and dep.oid <> base.oid
     and not (nd.nspname = 'sri_os' and dep.relname in ('v_ledger_posted', 'v_ledger_voided'));
  if v is not null then
    raise exception 'D-098: พบ view/materialized view ที่อ่าน transactions / transaction_lines ตรงๆ: % · งบและรายงานทุกใบต้องอ่านผ่าน sri_os.v_ledger_posted (ไม่มี void) หรือ v_ledger_voided · ถ้าของตัวนี้ต้องเห็นทุกสถานะจริงๆ ให้เพิ่มชื่อเข้า allow-list ในไฟล์ migration ใหม่พร้อมเหตุผล ไม่ใช่ถอน guard', v;
  end if;

  -- (6b) ฟังก์ชันรายงาน (set-returning) ที่อ่านตารางฐานตรงๆ
  --   allow-list: fn_health_check — ตรวจ Money Invariants ข้าม **ทุกสถานะ** โดยเจตนา
  --   (รายการที่ void แล้วแต่ไม่สมดุลก็ยังเป็นความผิดปกติที่ต้องเห็น) และกั้นด้วย
  --   fn_can('settings.manage') ในตัวเอง ไม่ใช่รายงานที่คนทั่วไปอ่าน
  --   fn_assert_ledger_read_path เองไม่ติด เพราะไม่ใช่ set-returning
  select string_agg(p.oid::regprocedure::text, ', ') into v
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.proretset
     and p.prorettype <> 'trigger'::regtype
     and p.prosrc ~ '\m(transactions|transaction_lines)\M'
     and p.proname not in ('fn_health_check');
  if v is not null then
    raise exception 'D-098: พบฟังก์ชันรายงาน (set-returning) ที่อ่าน transactions / transaction_lines ตรงๆ: % · ให้อ่านผ่าน sri_os.v_ledger_posted หรือ v_ledger_voided · ถ้าต้องเห็นทุกสถานะจริงๆ ให้เพิ่มชื่อเข้า allow-list ในไฟล์ migration ใหม่พร้อมเหตุผล', v;
  end if;

  -- (6c) guard ต้องไม่กลายเป็นของที่ไม่ได้ตรวจอะไรเลย
  --   ถ้าวิธีไล่ catalog เพี้ยน query ข้างบนจะคืนค่าว่างและ "ผ่าน" ทุกครั้ง
  --   (เครื่องมือที่ครอบไม่ครบ อันตรายกว่าไม่มีเครื่องมือ · D-096)
  select count(*) into n
    from pg_depend d
    join pg_rewrite r   on r.oid = d.objid
    join pg_class  dep  on dep.oid = r.ev_class
    join pg_class  base on base.oid = d.refobjid
    join pg_namespace nb on nb.oid = base.relnamespace
   where d.classid    = 'pg_rewrite'::regclass
     and d.refclassid = 'pg_class'::regclass
     and nb.nspname = 'sri_os'
     and base.relname in ('transactions', 'transaction_lines')
     and dep.relkind in ('v', 'm');
  if n < 2 then
    raise exception 'guard (6a) มองไม่เห็น view ของตัวเอง (เจอ % ตัว ต้อง >= 2 จาก v_ledger_posted + v_ledger_voided) → วิธีไล่ dependency ใช้ไม่ได้บน Postgres รุ่นนี้ · ปล่อยผ่าน = guard นี้ไม่จับอะไรเลยตลอดไป', n;
  end if;

  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proretset
     and p.prorettype <> 'trigger'::regtype
     and p.prosrc ~ '\m(transactions|transaction_lines)\M';
  if n < 1 then
    raise exception 'guard (6b) ไม่เจอแม้ fn_health_check ที่รู้ว่าอ่าน transaction_lines อยู่ → regex หรือเงื่อนไขเพี้ยน · guard นี้จะไม่จับอะไรเลย';
  end if;

  -- (6d) ค่าใหม่ใน txn_status ต้องมาพร้อมการตัดสินว่าอยู่ฝั่งไหน
  --   สองวิวกรองด้วย allow-list → ค่าใหม่จะตกหล่นทั้งสองฝั่ง "โดยปลอดภัย" (งบไม่ผิด)
  --   แต่ต้องไม่เงียบ: ของที่หายจากทั้งสองหน้าจอโดยไม่มีใครรู้ก็เป็นบั๊กคนละแบบ
  select string_agg(e.enumlabel, ', ' order by e.enumlabel) into v
    from pg_enum e
   where e.enumtypid = 'sri_os.txn_status'::regtype
     and e.enumlabel not in ('posted', 'void');
  if v is not null then
    raise exception 'txn_status มีค่าใหม่ที่ยังไม่มีใครตัดสินว่าอยู่ฝั่งไหน: % · v_ledger_posted = งบ (ต้องไม่รวมของที่ยังไม่อนุมัติ) · v_ledger_voided = รายการที่ยกเลิก (ไม่ใช่ร่าง) · ไปตัดสินแล้วเขียนเหตุผลไว้ที่หัวไฟล์ migration ใหม่ พร้อมแก้วิว/เทสต์ ไม่ใช่เติมเข้า allow-list เฉยๆ (D-098)', v;
  end if;
end $fn$;

comment on function fn_assert_ledger_read_path() is
  'D-098 · ด่าน "งบทุกใบอ่านผ่าน v_ledger_posted": view/matview หรือฟังก์ชันรายงาน (set-returning) ที่อ่าน transactions/transaction_lines ตรงๆ ทำให้ raise · รวมด่านกันตัวเองตาย (ต้องเห็นสองวิวของตัวเองและ fn_health_check) และด่านค่าใหม่ของ txn_status · เทสต์ zz_void_ledger_test เรียกฟังก์ชันตัวเดียวกันนี้ ไม่ได้เขียน query ซ้ำ';

-- guard function ห้ามเรียกจากข้างนอก (ไม่ใช่ข้อมูล เป็นด่านของ migration)
revoke all on function fn_assert_ledger_read_path() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_ledger_read_path() from anon, authenticated';
exception when undefined_object then null;
end $$;

-- เรียกด่านเดี๋ยวนี้ · ถ้าวันนี้มีของที่ละเมิดอยู่แล้ว migration ต้องพังที่นี่
do $$ begin perform fn_assert_ledger_read_path(); end $$;

-- 6e · ของที่ไฟล์นี้ต้องมี — ครบและตั้งค่าถูก
do $$
declare r record; v text; n int;
begin
  -- คอลัมน์ + ชนิด
  for r in
    select * from (values
      ('voided_at', 'timestamp with time zone'),
      ('voided_by', 'uuid'),
      ('void_reason', 'text')
    ) as x(col, typ)
  loop
    if not exists (
      select 1 from information_schema.columns c
       where c.table_schema = 'sri_os' and c.table_name = 'transactions'
         and c.column_name = r.col and c.data_type = r.typ
    ) then
      raise exception 'transactions.% (%) ไม่เกิด → รายการที่ยกเลิกจะเป็นผีที่ไม่มีคำอธิบาย', r.col, r.typ;
    end if;
  end loop;

  -- FK ของ voided_by (ต้องเป็นคนจริง ไม่ใช่ uuid ลอยๆ)
  if not exists (
    select 1
      from pg_constraint fk
      join pg_class ref on ref.oid = fk.confrelid
     where fk.conrelid = 'sri_os.transactions'::regclass
       and fk.contype = 'f'
       and ref.relname = 'app_users'
       and (select array_agg(a.attname::text)
              from unnest(fk.conkey) k
              join pg_attribute a on a.attrelid = fk.conrelid and a.attnum = k)
           = array['voided_by']
  ) then
    raise exception 'voided_by ไม่มี FK ไป app_users → "คนที่ยกเลิก" กลายเป็น uuid ที่พิมพ์อะไรก็ได้ ตรวจสอบย้อนไม่ได้';
  end if;

  -- constraint สองทาง — ต้องมี **และต้อง validated**
  --   `convalidated = false` แปลว่าบล็อก validate ข้างบนเจอแถว void ในอดีตที่ไม่มี
  --   ร่องรอย แล้วออกมาด้วย `raise warning` · warning ใน log การ apply ยาวๆ ไม่มีใครเห็น
  --   → ถ้าปล่อยผ่านที่นี่ ข้อความของ guard จะ **แข็งกว่าความจริง**: ใครอ่านไฟล์นี้
  --   จะเชื่อว่า "ทุกแถวที่ void มีเหตุผลครบ" ทั้งที่ยังมีผีค้างอยู่ในสมุด
  --   (เปิดครึ่งเดียวอันตรายกว่าไม่เปิด · บทเรียนข้อ 7)
  --   วันนี้ DB จริงยังไม่มีรายการเลย → validate ผ่านแน่นอน · วันไหนไม่ผ่าน
  --   คือวันที่เราต้องรู้เสียงดัง ไม่ใช่วันที่ควรปล่อยผ่าน
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'sri_os.transactions'::regclass
       and conname = 'transactions_void_fields_both_ways' and contype = 'c'
  ) then
    raise exception 'ไม่มี constraint transactions_void_fields_both_ways → void โดยไม่ใส่เหตุผลได้ และแปะเหตุผลค้างบนรายการที่ยัง posted ได้';
  end if;
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'sri_os.transactions'::regclass
       and conname = 'transactions_void_fields_both_ways' and contype = 'c'
       and convalidated
  ) then
    select count(*) into n from transactions
     where (status = 'void') <> (voided_at is not null)
        or (status = 'void') <> (voided_by is not null)
        or (status = 'void') <> (void_reason is not null and btrim(void_reason) <> '');
    raise exception 'constraint transactions_void_fields_both_ways ยังเป็น NOT VALID (มีรายการในอดีต % แถวที่ขัด) → ของใหม่ถูกบังคับครบแล้ว แต่ยังมีรายการที่ยกเลิกไว้ก่อนหน้านี้เป็น "ผีที่ไม่มีคำอธิบาย" อยู่ในสมุด และ D-098 ทั้งข้อพึ่งการมีเหตุผลกำกับ · ให้ตามเก็บก่อนแล้ว apply ซ้ำ (ไฟล์นี้ idempotent): select id, owner_id, doc_date, status, voided_at, voided_by, void_reason from sri_os.transactions where status = ''void'' and (voided_at is null or voided_by is null or void_reason is null or btrim(void_reason) = '''') order by doc_date; -- เติมค่าจาก audit_log (ใครกด UPDATE เป็น void เมื่อไหร่) ด้วย migration ที่ปิด trg_void_audit_columns อย่างชัดเจน แล้วรัน alter table sri_os.transactions validate constraint transactions_void_fields_both_ways;',
      n;
  end if;

  -- trigger แก้ย้อนหลังไม่ได้
  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'sri_os.transactions'::regclass
       and tgname = 'trg_void_audit_columns' and not tgisinternal
  ) then
    raise exception 'ไม่มี trg_void_audit_columns → ร่องรอยการยกเลิกแก้ย้อนหลังได้';
  end if;

  -- ฟังก์ชันของไฟล์นี้ต้องไม่หลวม (ไม่ definer · ไม่ถามสิทธิ์ · ไม่เปิด PUBLIC execute)
  select string_agg(p.proname, ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_void_audit_columns'
     and (p.prosecdef or p.prosrc ~* 'fn_can|fn_is_management'
          or has_function_privilege('public', p.oid, 'execute'));
  if v is not null then
    raise exception 'fn_void_audit_columns หลวมเกินไป (SECURITY DEFINER / ถามตารางสิทธิ์ / PUBLIC execute) · กฎเงินต้องเท่ากันทุกตำแหน่งและปิดจากหน้า Settings ไม่ได้';
  end if;

  -- สอง view: มีจริง · security_invoker · authenticated อ่านได้ · anon อ่านไม่ได้
  for r in select unnest(array['v_ledger_posted', 'v_ledger_voided']) as rel loop
    if not exists (
      select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'sri_os' and c.relname = r.rel and c.relkind = 'v'
    ) then
      raise exception 'ไม่มี view sri_os.% → งบไม่มีแหล่งอ่านกลาง คนเขียนรายงานต้องจำเองว่าต้องกรอง void', r.rel;
    end if;
    if not exists (
      select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'sri_os' and c.relname = r.rel
         and array_to_string(coalesce(c.reloptions, '{}'), ',') ilike '%security_invoker=true%'
    ) then
      raise exception 'view sri_os.% ไม่ได้ตั้ง security_invoker = true → ผลจะถูกกรองด้วย RLS ของเจ้าของ view = ทุกคนเห็นสมุดของทุกผู้ถือ', r.rel;
    end if;
    begin
      if not has_table_privilege('authenticated', 'sri_os.' || r.rel, 'select') then
        raise exception 'authenticated อ่าน sri_os.% ไม่ได้ → หน้างบใช้งานไม่ได้ (บีบให้อ่านผ่าน view แล้วปิดทางที่ถูกต้องไปด้วย = ปิดครึ่งเดียว)', r.rel;
      end if;
      if has_table_privilege('anon', 'sri_os.' || r.rel, 'select') then
        raise exception 'anon อ่าน sri_os.% ได้ → สมุดครอบครัวอ่านได้ด้วย anon key ที่ฝังในหน้าเว็บ', r.rel;
      end if;
      if has_table_privilege('authenticated', 'sri_os.' || r.rel, 'insert')
         or has_table_privilege('authenticated', 'sri_os.' || r.rel, 'update')
         or has_table_privilege('authenticated', 'sri_os.' || r.rel, 'delete') then
        raise exception 'authenticated เขียนผ่าน sri_os.% ได้ → เส้นทางเขียนสมุดเส้นที่สองที่ไม่มีใครไล่ด่านไว้ · วิวรายงานต้องอ่านอย่างเดียว', r.rel;
      end if;
    exception when undefined_object then
      raise warning 'ไม่มี role anon/authenticated ในคลัสเตอร์นี้ → ข้ามการตรวจสิทธิ์ของ %', r.rel;
    end;
  end loop;

  -- เงื่อนไขกรองของแต่ละวิวต้องเป็น allow-list ของสถานะที่ตัดสินไว้ (ไม่ใช่ <> อีกฝั่ง)
  if pg_get_viewdef('sri_os.v_ledger_posted'::regclass, true) !~* 'status\s*=\s*''posted''' then
    raise exception 'v_ledger_posted ไม่ได้กรองด้วย status = ''posted'' → ถ้าใช้ <> ''void'' ค่าสถานะใหม่ในอนาคต (เช่นรออนุมัติ) จะไหลเข้างบทุกใบเงียบๆ (เหตุผลเต็มอยู่หัวไฟล์)';
  end if;
  if pg_get_viewdef('sri_os.v_ledger_voided'::regclass, true) !~* 'status\s*=\s*''void''' then
    raise exception 'v_ledger_voided ไม่ได้กรองด้วย status = ''void'' → หน้า "รายการที่ยกเลิก" จะกลายเป็นที่รวมของทุกอย่างที่ไม่ใช่ posted รวมร่าง';
  end if;

  -- v_ledger_posted ต้องไม่กรองใบกลับรายการออก (D-097: ขาที่ทำให้สุทธิเป็นศูนย์)
  --   ตรวจจากค่าคงที่ 'reverse' ในนิยามวิว (การกรองต้องเขียนค่านี้ลงไป)
  --   คอลัมน์ source / source_ref ยัง select ออกไปได้ตามปกติ — นั่นไม่ใช่การกรอง
  if pg_get_viewdef('sri_os.v_ledger_posted'::regclass, true) ~* '''reverse''' then
    raise exception 'v_ledger_posted มีค่าคงที่ ''reverse'' ในนิยาม → ถ้ากรอง source = reverse ออก งบจะกลับไปแสดงยอดที่ควรถูกล้างแล้ว (D-097) · ใบกลับรายการต้องอยู่ในงบคู่กับต้นฉบับ';
  end if;

  raise notice 'D-098 ครบ · คอลัมน์ร่องรอยการยกเลิก 3 คอลัมน์ + constraint สองทาง + trigger แก้ย้อนหลังไม่ได้ + v_ledger_posted/v_ledger_voided (security_invoker) + guard ของใหม่';
end $$;
