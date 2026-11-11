-- ============================================================
-- SRI OS · เติม can_accrue ให้ตารางกฎฝั่ง DB + บังคับ "ตั้งค้างได้ ต้องล้างได้" ที่ DB
--
-- ทำอะไร:
--   1. เพิ่มคอลัมน์ sri_os.txn_types.can_accrue (default false = ปิดไว้ก่อน)
--   2. CHECK — ตั้งค้างได้ ต้องมีบัญชีพัก
--   3. constraint trigger (deferrable) — ตั้งค้างได้ ต้องมีหมวดที่ล้างบัญชีพักนั้นได้จริง
--      **และหมวดล้างต้องอยู่กระแสเงินสดหมวดเดียวกับรายการต้นทาง**
--
-- ทำไม: `accrual_coa_code is not null` ตอบแค่ว่า "ถ้าเงินยังไม่เคลื่อน ยอดไปพักที่ไหน"
--   ซึ่งเป็นข้อมูลที่ถูกสำหรับกลไกยืนยันรับ-จ่าย (C6) ที่จะลงบรรทัดเงินสดด้วย
--   cf_group ของรายการต้นทาง · แต่ **ไม่ได้ตอบว่าวันนี้คีย์ค้างจากฟอร์มได้จริงไหม**
--   SQL/automation ที่อ่าน DB แล้วเห็นว่า "มีบัญชีพัก" จะเข้าใจว่าตั้งค้างได้ทั้ง 32 หมวด
--   ทั้งที่ engine เปิดให้แค่ 23 หมวด — กฎใน DB ครึ่งเดียวคือสิ่งที่ sync มีไว้เพื่อกัน
--
--   เงื่อนไข cf_group ของหมวดล้างไม่ใช่เรื่องความสวยงาม: ซื้อทรัพย์ 10 ล้านแบบยังไม่จ่าย
--   พักที่ 2100 · ทางล้างเดียวที่มีคือ "จ่ายเจ้าหนี้ค้างจ่าย" ซึ่งเป็น operating
--   เงิน 10 ล้านจะไปโผล่กระแสเงินสดจากการดำเนินงาน ทั้งที่ต้องเป็น investing
--   งบดุลยังสมดุลทุกบรรทัดและไม่มีอะไรฟ้อง — บังคับที่ DB เพราะ application
--   ไม่ใช่ทางเดียวที่เขียนตารางนี้ (sync script, psql, automation)
--
-- idempotent: add column if not exists · drop แล้ว add constraint/trigger ใหม่ทุกรอบ
--   trigger เป็น deferrable initially deferred เพราะ seed insert ทั้ง 50+ หมวด
--   ในคำสั่งเดียว — หมวดที่ตั้งค้างอาจเข้าแถวก่อนหมวดที่ล้างมัน ต้องตรวจตอน commit
--
-- ย้อนกลับ:
--   drop trigger if exists trg_assert_accrual_clearable on sri_os.txn_types;
--   drop function if exists sri_os.fn_assert_accrual_clearable();
--   alter table sri_os.txn_types
--     drop constraint if exists txn_types_can_accrue_needs_account,
--     drop column if exists can_accrue;
--   (ถอดคอลัมน์ทิ้งได้ปลอดภัย — ไม่มี journal_lines อ้างถึง และ seed รอบถัดไป
--    จะเขียนค่ากลับมาเองจาก canAccrueFromForm() ในตารางกฎฝั่งโค้ด)
-- ============================================================

set search_path = sri_os, public;

alter table sri_os.txn_types
  add column if not exists can_accrue boolean not null default false;

comment on column sri_os.txn_types.can_accrue is
  'ติ๊ก "ยังไม่ได้รับ/จ่ายเงิน" กับหมวดนี้ได้ไหม — คำนวณจาก canAccrueFromForm() ในตารางกฎ '
  'แคบกว่า accrual_coa_code is not null: ต้องมีหมวดล้างที่อยู่กระแสเงินสดหมวดเดียวกันด้วย';

-- ตั้งค้างได้ ต้องรู้ว่าพักที่บัญชีไหน
alter table sri_os.txn_types
  drop constraint if exists txn_types_can_accrue_needs_account;
alter table sri_os.txn_types
  add constraint txn_types_can_accrue_needs_account
  check (can_accrue = false or accrual_coa_code is not null);

/**
 * ตั้งค้างได้ ต้องล้างได้ — และล้างแล้วเงินต้องไปลงกระแสเงินสดหมวดเดิม
 *
 * ตรวจทั้งตารางทุกครั้ง (54 แถว ถูกมาก) ไม่ใช่ตรวจแค่แถวที่เปลี่ยน เพราะการ
 * **ลบหมวดล้าง** ก็ทำให้หมวดที่ตั้งค้างอยู่กลายเป็นล้างไม่ได้เหมือนกัน
 * ถ้าตรวจแค่แถวใหม่ การลบ fin.pay_payable จะผ่านเงียบๆ แล้ว 21 หมวดค่าใช้จ่าย
 * จะตั้งค้างได้โดยไม่มีทางล้าง
 */
create or replace function sri_os.fn_assert_accrual_clearable() returns trigger
language plpgsql set search_path = sri_os, public as $fn$
declare
  r record;
begin
  for r in
    select t.code, t.cf_group, t.accrual_coa_code, a.type::text as acc_type
      from txn_types t
      left join chart_of_accounts a on a.code = t.accrual_coa_code
     where t.can_accrue
  loop
    -- บัญชีพักที่เป็นรายได้/ค่าใช้จ่าย = รับรู้ซ้ำตอนเงินเข้าจริง · ต้องอยู่ในงบดุล
    if r.acc_type is null or r.acc_type not in ('asset', 'liability') then
      raise exception
        'หมวด % ตั้งค้างได้ แต่พักยอดที่ % ซึ่งไม่ใช่สินทรัพย์หรือหนี้สิน (%)',
        r.code, coalesce(r.accrual_coa_code, '-'), coalesce(r.acc_type, 'ไม่มีในผังบัญชี');
    end if;

    -- ลูกหนี้ (สินทรัพย์) ลดเมื่ออยู่ฝั่งเครดิต · เจ้าหนี้ (หนี้สิน) ลดเมื่ออยู่ฝั่งเดบิต
    -- ขาที่ "เพิ่ม" ยอดไม่ใช่ทางล้าง แม้จะแตะบัญชีเดียวกันและมีขาเงินสด
    if not exists (
      select 1
        from txn_types c
       where c.is_active
         and c.cf_group = r.cf_group
         and (
           (r.acc_type = 'asset'
             and c.cr_coa_code = r.accrual_coa_code
             and c.dr_coa_code ~ '^11[0-9][0-9]$')
           or
           (r.acc_type = 'liability'
             and c.dr_coa_code = r.accrual_coa_code
             and c.cr_coa_code ~ '^11[0-9][0-9]$')
         )
    ) then
      raise exception
        'หมวด % ตั้งค้างที่ % ได้ แต่ไม่มีหมวดที่ล้างบัญชีนี้ในกระแสเงินสดหมวด % — '
        'ตั้งค้างไว้จะค้างในงบดุลตลอดไป หรือล้างแล้วเงินไปโผล่ผิดหมวด',
        r.code, r.accrual_coa_code, r.cf_group;
    end if;
  end loop;

  return null;
end $fn$;

drop trigger if exists trg_assert_accrual_clearable on sri_os.txn_types;
create constraint trigger trg_assert_accrual_clearable
  after insert or update or delete on sri_os.txn_types
  deferrable initially deferred
  for each row execute function sri_os.fn_assert_accrual_clearable();
