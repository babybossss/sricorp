-- ============================================================
-- SRI OS · C-3 + C-4 · **ประตูสร้างร่าง** (คิวอนุมัติที่ว่างตลอดเพราะไม่มีอะไรสร้างร่าง)
--
-- สภาพก่อนไฟล์นี้
--   Staff มีสิทธิ์ `txn.create` และ policy `draft_insert` เปิดอยู่ **แต่ไม่มีประตู**
--   ที่ตรวจว่าร่างที่คีย์เข้าไปจะ **อนุมัติได้** หรือไม่ · และ `draft_entries`
--   **ไม่มีคอลัมน์บัญชีธนาคาร** (C-4) ทั้งที่บรรทัดเงินสด (11xx) ต้องมี
--   `bank_account_id` เสมอ (20260917000002 · 20261025000004) → ร่างของรายการที่
--   เงินเคลื่อน **อนุมัติไม่ได้เลย** ซึ่งคือครึ่งหนึ่งของรายการจริง
--
-- ------------------------------------------------------------
-- **จุดที่พอดี** (ตรวจหลวม = ร่างค้างคิวตลอดไป · ตรวจเข้ม = Staff คีย์ไม่ได้)
-- ------------------------------------------------------------
-- เกณฑ์ที่ใช้ตัดสินว่าอะไรต้องตรวจ **ตอนคีย์**:
--   “ถ้าปล่อยผ่าน แล้วตอนกดอนุมัติจะถูกด่านไหนตีกลับแน่ๆ โดยที่ผู้อนุมัติ
--    แก้ไม่ได้ด้วยข้อมูลที่ตัวเองมี” → ตรวจตอนคีย์
-- ไล่จากด่านที่ `fn_post_entry` + trigger ของ `transactions`/`transaction_lines`
-- บังคับจริงวันนี้ (อ่านจากไฟล์ ไม่ใช่จากความจำ):
--   1. `trg_corporate_evidence`  → นิติบุคคลต้องมีไฟล์แนบ (+คู่ค้าถ้าหมวดต้องมี)
--   2. บรรทัด 11xx ต้องมี `bank_account_id` → ร่างที่มีวันเงินเคลื่อนต้องมีบัญชี
--   3. `trg_lines_rule_coa_accrual` → หมวดที่ `can_accrue = false` ตั้งค้างไม่ได้
--      (ร่างที่ไม่มี cash_date ของหมวดพวกนี้ = อนุมัติไม่ได้ทุกทาง)
--   4. `trg_period_locked` → นิติบุคคลลงย้อนเข้างวดที่ปิดแล้วไม่ได้
--   5. `fn_assert_line_coa_in_rules` → หมวดต้องมีคู่บัญชีในตารางกฎ
--   6. ตารางกฎบอกว่าหมวดนั้นต้องมีข้อมูลที่ **ตารางร่างไม่มีช่องให้เก็บ**
--      (`requires_transfer_target` · `requires_loan_terms` ·
--       `requires_capital_gain` · `requires_principal_split`)
--      → คีย์เป็นร่างไม่ได้ **ต้องบอกตอนคีย์** ไม่ใช่ให้ไปค้างคิว
--   7. หมวดแปลงค่าอัตราแลกเปลี่ยน (คู่บัญชีแตะ `3410`) ต้องทำบนบัญชีเงินตรา
--      ต่างประเทศพร้อมอัตราของวันนั้น — ร่างเก็บได้แต่บัญชีสกุลบาท
--      (**เจอจากการไล่ทุกหมวดในเทสต์** ไม่ได้มาจากการนั่งนึก)
--
-- สิ่งที่ **ไม่** ตรวจตอนคีย์ (ตั้งใจปล่อยไปตรวจตอนอนุมัติ)
--   · คู่บัญชีรายบรรทัด/ยอดเดบิต-เครดิต — เกิดจาก `buildPosting()` ของผู้อนุมัติ
--     ไม่ใช่จากร่าง (ร่างเก็บแค่ยอดเดียว) · ด่านของ `fn_post_entry` ตรวจครบแล้ว
--   · ยอดในร่างต้องเท่ากับผลรวมเดบิตของใบ — **ไม่เท่ากันโดยธรรมชาติ** ในหลายหมวด
--     (ขายทรัพย์ · ถูกหักภาษี ณ ที่จ่าย · ล้างส่วนเกินทุน) ตามที่ 20261025000017 เขียนไว้
--   · สิทธิ์การอนุมัติของคนที่จะมากด — เป็นเรื่องของตอนอนุมัติ
--
-- **ผลที่วัดได้**: หมวดที่คีย์เป็นร่างได้ = 50 จาก 92 หมวด
--   (ตัด `opening` 23 หมวดซึ่งมีประตูของตัวเอง `fn_opening_set` ·
--    ตัด 17 หมวดที่ต้องมีฟอร์มเพิ่ม · ตัด 2 หมวดแปลงค่าอัตราแลกเปลี่ยน)
--   — ตัวเลขจริงตรวจด้วย `fn_draft_allowed_types()`
--   guard ท้ายไฟล์ **แดงถ้าชุดนั้นว่างเปล่า** (ประตูที่ไม่ยอมอะไรเลย = ไม่มีประตู)
--
-- ------------------------------------------------------------
-- รูปแบบ: **กฎอยู่ที่เดียว** `fn_draft_entry_problem()` คืนข้อความปัญหา (null = ผ่าน)
--   · trigger `trg_draft_entry_postable` เรียกมัน → เป็นด่านจริงที่ปลอมไม่ได้
--   · ฟอร์มเรียกมันตรงๆ ได้ → **บอกผู้คีย์ตั้งแต่ตอนคีย์** ไม่ใช่ให้เดา
--   · `fn_create_draft()` เป็นปากทางเดียวที่แอปใช้ (ปฏิเสธช่องที่ไม่รู้จักทั้งใบ)
--   ทั้งสามตัวไม่มีสำเนาของกฎ — ถ้ามีสองที่ กฎจะแยกกันเดินทันที (บทเรียน mace-windu ข้อ 5)
--
-- `security invoker` ทั้งชุดโดยตั้งใจ (รูปเดียวกับ `fn_corporate_requires_evidence`):
--   ด่านต้องเห็นของเท่าที่ผู้คีย์เห็น — บัญชีธนาคาร/ทรัพย์/คู่ค้าที่ RLS ซ่อนจากเขา
--   ต้องถือว่า "ไม่มี" ไม่ใช่ปล่อยให้อ้างถึงได้ผ่าน definer
--
-- `created_by` **ตั้งจาก `auth.uid()` ตอน INSERT เสมอ** ไม่รับจากคำขอ (D-115)
--   ยกเว้นตอนไม่มีผู้ล็อกอินเลย ซึ่งต้องเป็น source อื่นที่ไม่ใช่ `manual`
--   (กฎเหล็กข้อ 6: automation สร้างได้แค่ร่าง — ถ้าบังคับว่าต้องมีผู้ล็อกอิน
--    automation จะสร้างร่างไม่ได้ และจะมีคนเอาไปเขียนลง transactions ตรงๆ)
--
-- ลำดับ: หลัง 20261025000018/0019 (C-2 ตรึง created_by ตอน UPDATE · ไฟล์นี้ตรึงตอน INSERT)
--
-- idempotent: add column if not exists · create or replace · drop trigger if exists
--
-- ย้อนกลับ (rollback):
--   -- drop trigger if exists trg_draft_entry_postable on sri_os.draft_entries;
--   -- drop function if exists sri_os.fn_assert_draft_entry_postable();
--   -- drop function if exists sri_os.fn_create_draft(jsonb);
--   -- drop function if exists sri_os.fn_draft_allowed_types();
--   -- drop function if exists sri_os.fn_draft_entry_problem(uuid, text, date, date,
--   --      numeric, uuid, uuid, uuid, uuid, text[]);
--   -- delete from sri_os.column_exposure
--   --  where table_name = 'draft_entries' and column_name = 'bank_account_id';
--   -- select sri_os.fn_apply_column_exposure();
--   -- alter table sri_os.draft_entries drop column if exists bank_account_id;
--   ⚠ ถอดแล้ว **คิวอนุมัติกลับไปรับร่างที่อนุมัติไม่ได้** (และร่างของรายการที่เงิน
--     เคลื่อนจะไม่มีที่เก็บเลขบัญชี = อนุมัติไม่ได้ทั้งหมด)
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 0 · ของที่ต้องมีมาก่อน
-- ============================================================
do $$
begin
  if to_regclass('sri_os.draft_entries') is null or to_regclass('sri_os.bank_accounts') is null then
    raise exception 'ไม่มีตาราง draft_entries / bank_accounts → ต้องรัน 20260917000002_ledger.sql ก่อนไฟล์นี้';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'sri_os' and table_name = 'txn_types'
                    and column_name = 'cash_direction') then
    raise exception 'ไม่มีคอลัมน์ txn_types.cash_direction → ต้องรัน 20261009000003 ก่อนไฟล์นี้ (ด่านนี้อ่านทิศทางเงินจากตารางกฎ ไม่เดาจากชื่อหมวด)';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'sri_os' and table_name = 'txn_types'
                    and column_name = 'can_accrue') then
    raise exception 'ไม่มีคอลัมน์ txn_types.can_accrue → ต้องรัน 20261006000003 ก่อนไฟล์นี้';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'sri_os' and table_name = 'txn_types'
                    and column_name = 'requires_transfer_target') then
    raise exception 'ไม่มีคอลัมน์ txn_types.requires_transfer_target → ต้องรัน 20260918000003 ก่อนไฟล์นี้';
  end if;
  if to_regprocedure('sri_os.fn_can_see_owner(uuid)') is null then
    raise exception 'ไม่มี fn_can_see_owner → ต้องรัน 20261006190000_roles_permissions.sql ก่อนไฟล์นี้';
  end if;
  -- ด่านคู่: ประตูนี้ตรึง created_by ตอน INSERT · C-2 ตรึงตอน UPDATE
  -- มีแต่ของตัวเองคือกันครึ่งเดียว (คีย์เป็นชื่อคนอื่นไม่ได้ แต่ย้ายทีหลังได้)
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.draft_entries'::regclass
                    and g.tgname = 'trg_draft_review_separation' and not g.tgisinternal) then
    raise exception 'ไม่มี trigger trg_draft_review_separation → ต้องรัน 20261025000018 ก่อนไฟล์นี้ · ถ้าไม่มี การตรึง created_by ตอน INSERT จะไร้ความหมาย เพราะย้ายชื่อคนคีย์ตอน UPDATE ได้';
  end if;
  if to_regclass('sri_os.column_exposure') is null
     or to_regprocedure('sri_os.fn_apply_column_exposure()') is null then
    raise exception 'ไม่มีทะเบียนด่านคอลัมน์ → ต้องรัน 20261020000000_column_exposure.sql ก่อนไฟล์นี้ (D-089)';
  end if;
end $$;

-- ============================================================
-- 1 · C-4 · ช่องบัญชีธนาคารของร่าง
--     ร่างที่มี "วันที่เงินเคลื่อน" ต้องบอกได้ว่าเงินเข้า-ออกบัญชีไหน
--     ไม่งั้นบรรทัด 11xx ตอนอนุมัติจะไม่มี bank_account_id → ถูกตีกลับทุกใบ
-- ============================================================
alter table draft_entries
  add column if not exists bank_account_id uuid references bank_accounts(id);

comment on column draft_entries.bank_account_id is
  'C-4 · บัญชีธนาคารที่เงินจะเข้า-ออกของร่างนี้ · บังคับเมื่อร่างมี cash_date และหมวดเป็นหมวดที่เงินเคลื่อน (bank ต้องเป็นของผู้ถือคนเดียวกัน · ยังเปิดใช้ · สกุลบาท) · ต้องเป็น null เมื่อเงินยังไม่เคลื่อน (ค้างรับ-ค้างจ่าย) หรือหมวดที่ไม่แตะเงินสดเลย — ด่านอยู่ที่ fn_draft_entry_problem()';

-- ============================================================
-- 2 · **กฎอยู่ที่เดียว** — คืนข้อความปัญหา (null = คีย์ได้และอนุมัติได้)
--     ฟอร์มเรียกตัวนี้ได้ตรงๆ → ผู้คีย์รู้ก่อนกดบันทึก ไม่ใช่รู้ตอนถูกตีกลับ
-- ============================================================
create or replace function fn_draft_entry_problem(
  p_owner       uuid,
  p_type        text,
  p_doc_date    date,
  p_cash_date   date,
  p_amount      numeric,
  p_bank        uuid     default null,
  p_asset       uuid     default null,
  p_contact     uuid     default null,
  p_contract    uuid     default null,
  p_attachments text[]   default '{}'
) returns text
language plpgsql stable set search_path = sri_os, public as $fn$
declare
  o record;
  t record;
  b record;
begin
  -- ---------- (1) ข้อมูลอ้างอิงต้องมีจริงและใช้งานได้ ----------
  if p_owner is null then
    return 'ยังไม่ได้เลือกผู้ถือ (owner) — หนึ่งรายการ = หนึ่งผู้ถือ เดาแทนไม่ได้';
  end if;
  select id, code, name_th, policy, status into o from owners where id = p_owner;
  if o.id is null then
    return 'ไม่พบผู้ถือที่เลือก (หรือคุณไม่มีสิทธิ์เห็นผู้ถือรายนี้)';
  end if;
  if o.status <> 'active' then
    return format('ผู้ถือ %s ไม่ได้ใช้งานอยู่ (สถานะ %s) — ลงรายการใหม่ให้ผู้ถือที่ปิดแล้วไม่ได้',
                  o.name_th, o.status);
  end if;

  if nullif(btrim(coalesce(p_type, '')), '') is null then
    return 'ยังไม่ได้เลือกหมวดย่อยของรายการ (txn_type_code)';
  end if;
  select code, name_th, group_code, is_active, cash_direction, can_accrue,
         accrual_coa_code, dr_coa_code, cr_coa_code,
         requires_asset, requires_contact, requires_transfer_target,
         requires_loan_terms, requires_capital_gain, requires_principal_split
    into t
    from txn_types where code = p_type;
  if t.code is null then
    return format('ไม่มีหมวด "%s" ในตารางกฎ (txn_types) — ตารางกฎคือแหล่งความจริงเดียว', p_type);
  end if;
  if not t.is_active then
    return format('หมวด "%s" ถูกปิดใช้งานแล้ว', t.name_th);
  end if;
  if t.dr_coa_code is null or t.cr_coa_code is null then
    return format('ตารางกฎยังไม่ได้ระบุคู่บัญชีของหมวด "%s" — คีย์ร่างได้แต่จะอนุมัติไม่ได้ · sync ด้วย npm run sync:rules',
                  t.name_th);
  end if;

  -- ---------- (2) หมวดที่คีย์เป็นร่างไม่ได้ ----------
  -- **บอกตอนคีย์** พร้อมบอกว่าต้องไปทางไหน · ไม่ใช่ปล่อยให้ค้างคิว
  if t.group_code = 'opening' then
    return format('หมวด "%s" เป็นยอดยกมา (ตั้งต้นระบบ) — ไม่ผ่านคิวอนุมัติ ต้องใช้ประตูยอดตั้งต้น (sri_os.fn_opening_set)',
                  t.name_th);
  end if;
  if t.requires_transfer_target then
    return format('หมวด "%s" เป็นการโอน ต้องระบุบัญชี/ผู้ถือปลายทาง ซึ่งตารางร่างยังไม่มีช่องเก็บ — คีย์เป็นร่างไม่ได้ ให้ผู้อนุมัติคีย์จากฟอร์มโอนโดยตรง',
                  t.name_th);
  end if;
  if t.requires_loan_terms then
    return format('หมวด "%s" ต้องมีเงื่อนไขสัญญา (อัตรา/งวด/กำหนดไถ่ถอน) ซึ่งตารางร่างยังไม่มีช่องเก็บ — คีย์เป็นร่างไม่ได้',
                  t.name_th);
  end if;
  if t.requires_capital_gain then
    return format('หมวด "%s" ต้องคำนวณกำไร/ขาดทุนจากการขาย (ต้นทุนและล็อตที่ตัด) ซึ่งตารางร่างยังไม่มีช่องเก็บ — คีย์เป็นร่างไม่ได้',
                  t.name_th);
  end if;
  if t.requires_principal_split then
    return format('หมวด "%s" ต้องแยกเงินต้นกับดอกเบี้ย ซึ่งตารางร่างยังไม่มีช่องเก็บ — คีย์เป็นร่างไม่ได้',
                  t.name_th);
  end if;
  -- หมวดแปลงค่าอัตราแลกเปลี่ยน (คู่บัญชีแตะ 3410) ต้องทำบน **บัญชีเงินตราต่างประเทศ**
  -- พร้อมอัตราของวันนั้น · ร่างเก็บได้แต่บัญชีสกุลบาท (ดูข้อ 5) → อนุมัติไม่ได้ทุกใบ
  -- อ่านจาก **คู่บัญชีในตารางกฎ** ไม่ใช่ชื่อหมวด
  if '3410' in (t.dr_coa_code, t.cr_coa_code) then
    return format('หมวด "%s" เป็นการแปลงค่าอัตราแลกเปลี่ยนของบัญชีเงินตราต่างประเทศ — ต้องทำบนบัญชี FCD พร้อมอัตราของวันนั้น ซึ่งตารางร่างยังไม่มีช่องเก็บ จึงคีย์เป็นร่างไม่ได้',
                  t.name_th);
  end if;

  -- ---------- (3) ยอดและวันที่ ----------
  if p_amount is null then
    return 'ยังไม่ได้กรอกจำนวนเงิน';
  end if;
  if p_amount <= 0 then
    return format('จำนวนเงินต้องมากกว่า 0 (ได้ %s) — ทิศทางเงินมาจากหมวดที่เลือก ไม่ใช่จากเครื่องหมายติดลบ',
                  p_amount);
  end if;
  if round(p_amount, 2) <> p_amount then
    return 'จำนวนเงินมีทศนิยมเกินสองตำแหน่ง';
  end if;
  if p_doc_date is null then
    return 'ยังไม่ได้กรอกวันที่เอกสาร (doc_date)';
  end if;
  -- นิติบุคคล: ลงย้อนเข้างวดที่ปิดแล้วไม่ได้ (trg_period_locked จะตีกลับตอนอนุมัติ)
  if o.policy = 'corporate_strict'
     and exists (select 1 from period_closes p
                  where p.owner_id = p_owner
                    and p.period = date_trunc('month', p_doc_date)::date) then
    return format('งวด %s ของ %s ปิดแล้ว — ลงรายการย้อนเข้างวดที่ปิดไม่ได้ ให้ปรับปรุงในงวดปัจจุบัน',
                  to_char(p_doc_date, 'MM/YYYY'), o.name_th);
  end if;

  -- ---------- (4) ข้อมูลที่ตารางกฎบอกว่าต้องมี ----------
  if t.requires_asset and p_asset is null then
    return format('หมวด "%s" ต้องระบุทรัพย์', t.name_th);
  end if;
  if p_asset is not null and not exists (select 1 from assets a where a.id = p_asset) then
    return 'ไม่พบทรัพย์ที่เลือก (หรือคุณไม่มีสิทธิ์เห็นทรัพย์ชิ้นนี้)';
  end if;
  if t.requires_contact and p_contact is null then
    return format('หมวด "%s" ต้องระบุคู่ค้า/ผู้ติดต่อ', t.name_th);
  end if;
  if p_contact is not null and not exists (select 1 from contacts c where c.id = p_contact) then
    return 'ไม่พบผู้ติดต่อที่เลือก';
  end if;
  if p_contract is not null then
    if not exists (select 1 from contracts c where c.id = p_contract and c.owner_id = p_owner) then
      return 'สัญญาที่อ้างถึงไม่ใช่สัญญาของผู้ถือรายนี้ (หรือคุณไม่มีสิทธิ์เห็นสัญญานั้น)';
    end if;
  end if;

  -- นิติบุคคลต้องมีหลักฐานตอน post (trg_corporate_evidence) → ต้องมีตอนคีย์
  -- **ไม่เลื่อนไปตอนอนุมัติ** เพราะคนที่มีเอกสารในมือคือคนคีย์ ถ้าเลื่อน ร่างจะค้างคิว
  if o.policy = 'corporate_strict' and cardinality(coalesce(p_attachments, '{}')) = 0 then
    return format('%s เป็นนิติบุคคล (corporate_strict) — ต้องแนบไฟล์หลักฐานมาพร้อมร่าง ไม่งั้นอนุมัติไม่ได้ (ข้อนี้ override ไม่ได้)',
                  o.name_th);
  end if;

  -- ---------- (5) ขาเงินสด (C-4) ----------
  if t.cash_direction = 'none' then
    if p_cash_date is not null then
      return format('หมวด "%s" ไม่แตะเงินสด จึงต้องไม่มีวันที่เงินเคลื่อน', t.name_th);
    end if;
    if p_bank is not null then
      return format('หมวด "%s" ไม่แตะเงินสด จึงต้องไม่ระบุบัญชีธนาคาร', t.name_th);
    end if;
    return null;
  end if;
  if t.cash_direction = 'both' then
    return format('หมวด "%s" เงินเคลื่อนสองทาง ต้องคีย์จากฟอร์มที่ระบุต้นทาง-ปลายทางได้', t.name_th);
  end if;

  if p_cash_date is null then
    -- ค้างรับ-ค้างจ่าย: ทำได้เฉพาะหมวดที่ตารางกฎบอกว่าตั้งค้างได้
    if not coalesce(t.can_accrue, false) or t.accrual_coa_code is null then
      return format('หมวด "%s" ตั้งค้างรับ-ค้างจ่ายไม่ได้ (ตารางกฎ: can_accrue = false) — ต้องกรอกวันที่เงินเข้า-ออกจริง ถ้าเงินยังไม่เคลื่อน ให้รอแล้วคีย์ตอนนั้น',
                    t.name_th);
    end if;
    if p_bank is not null then
      return format('ร่างนี้ยังไม่มีวันที่เงินเคลื่อน (ลงเป็นค้างรับ-ค้างจ่าย) จึงต้องไม่ระบุบัญชีธนาคาร — ถ้าเงินเคลื่อนแล้ว ให้กรอกวันที่เงินเข้า-ออก');
    end if;
    return null;
  end if;

  -- มีวันที่เงินเคลื่อน → ต้องรู้ว่าเข้า-ออกบัญชีไหน (บรรทัด 11xx บังคับ bank_account_id)
  if p_bank is null then
    return format('ร่างนี้มีวันที่เงินเคลื่อน (%s) จึงต้องระบุบัญชีธนาคารที่เงินเข้า-ออก — บรรทัดเงินสดที่ไม่มีบัญชีธนาคารลงสมุดไม่ได้',
                  to_char(p_cash_date, 'DD/MM/YYYY'));
  end if;
  select id, owner_id, display_name, is_active, currency into b
    from bank_accounts where id = p_bank;
  if b.id is null then
    return 'ไม่พบบัญชีธนาคารที่เลือก (หรือคุณไม่มีสิทธิ์เห็นบัญชีนี้)';
  end if;
  if b.owner_id <> p_owner then
    return format('บัญชี %s ไม่ใช่บัญชีของ %s — เงินของผู้ถือหนึ่งเข้าบัญชีของอีกผู้ถือไม่ได้ (ถ้าเป็นการโอนข้ามผู้ถือ ต้องคีย์จากฟอร์มโอน)',
                  b.display_name, o.name_th);
  end if;
  if not coalesce(b.is_active, false) then
    return format('บัญชี %s ปิดใช้งานแล้ว', b.display_name);
  end if;
  if coalesce(b.currency, 'THB') <> 'THB' then
    return format('บัญชี %s เป็นบัญชีสกุล %s — รายการที่เข้า-ออกบัญชีเงินตราต่างประเทศต้องมีอัตราแลกเปลี่ยนของดีลกำกับ ซึ่งตารางร่างยังไม่มีช่องเก็บ จึงคีย์เป็นร่างไม่ได้',
                  b.display_name, b.currency);
  end if;

  return null;
end $fn$;

comment on function fn_draft_entry_problem(uuid, text, date, date, numeric, uuid, uuid, uuid, uuid, text[]) is
  'C-3 · แหล่งความจริงเดียวของ "ร่างใบนี้คีย์ได้และอนุมัติได้หรือไม่" · คืนข้อความปัญหาเป็นภาษาคน (null = ผ่าน) · trigger trg_draft_entry_postable เรียกตัวนี้เป็นด่านจริง และฟอร์มเรียกตัวเดียวกันเพื่อบอกผู้คีย์ก่อนกดบันทึก (กฎเดียวกันห้ามเขียนสองที่) · security invoker → เห็นของเท่าที่ผู้คีย์เห็น';

revoke all on function fn_draft_entry_problem(uuid, text, date, date, numeric, uuid, uuid, uuid, uuid, text[]) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_draft_entry_problem(uuid, text, date, date, numeric, uuid, uuid, uuid, uuid, text[]) from anon';
  execute 'grant execute on function sri_os.fn_draft_entry_problem(uuid, text, date, date, numeric, uuid, uuid, uuid, uuid, text[]) to authenticated';
end $$;

-- ---------- หมวดที่คีย์เป็นร่างได้ (ฟอร์มใช้ทำรายการตัวเลือก) ----------
create or replace function fn_draft_allowed_types() returns table (code text, name_th text)
language sql stable set search_path = sri_os, public as $fn$
  select t.code, t.name_th
    from txn_types t
   where t.is_active
     and t.group_code <> 'opening'
     and not t.requires_transfer_target
     and not t.requires_loan_terms
     and not t.requires_capital_gain
     and not t.requires_principal_split
     and t.dr_coa_code is not null
     and t.cr_coa_code is not null
     and t.cash_direction <> 'both'
     and '3410' not in (t.dr_coa_code, t.cr_coa_code)
   order by t.sort_order, t.code;
$fn$;

comment on function fn_draft_allowed_types() is
  'C-3 · หมวดที่คีย์เป็นร่างได้ · เงื่อนไขชุดเดียวกับที่ fn_draft_entry_problem() ปฏิเสธระดับหมวด (ฟอร์มต้องไม่แสดงหมวดที่กดแล้วถูกตีกลับแน่ๆ) · ไม่รวม opening ซึ่งมีประตูของตัวเอง และไม่รวมหมวดที่ต้องมีฟอร์มเพิ่ม';

revoke all on function fn_draft_allowed_types() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_draft_allowed_types() from anon';
  execute 'grant execute on function sri_os.fn_draft_allowed_types() to authenticated';
end $$;

-- ============================================================
-- 3 · ด่านจริง — trigger (ไม่ใช่การเช็คในแอป · ปากทางเดียวกันไม่พอ D-115)
-- ============================================================
create or replace function fn_assert_draft_entry_postable() returns trigger
language plpgsql set search_path = sri_os, public as $fn$
declare v_problem text;
begin
  if tg_op = 'INSERT' then
    /**
     * `created_by` ตั้งจากผู้ล็อกอินจริง **ไม่รับจากคำขอ** (D-115)
     * ไม่มีผู้ล็อกอิน = ต้องเป็น source อื่นที่ไม่ใช่ manual (กฎเหล็กข้อ 6:
     * automation สร้างได้แค่ร่าง — ห้ามปิดทางนั้น ไม่งั้นจะมีคนเขียนลงสมุดตรงๆ)
     */
    if auth.uid() is not null then
      new.created_by := auth.uid();

      /**
       * ร่างที่ **ผู้ใช้** คีย์ ต้องเกิดมาเป็น `pending` เสมอ ห้ามเกิดมาพร้อมผลการตัดสิน
       * ไม่งั้นเลี่ยงด่าน C-1/C-2 ได้ทั้งชุด เพราะสองด่านนั้นเป็น trigger ของ **UPDATE**
       * (วัดไว้ในเทสต์: INSERT ร่าง `approved` ที่ชี้ใบในสมุดพร้อมใส่ชื่อผู้อนุมัติ
       *  ที่ไม่เคยกด = ประวัติการอนุมัติที่ไม่เคยเกิดขึ้น)
       *
       * **บังคับเฉพาะตอนมีผู้ล็อกอิน** โดยตั้งใจ: การนำเข้าร่างในอดีตจากระบบเก่า
       * และ fixture ระดับ DB ไม่มี `auth.uid()` และเป็นงานที่ข้ามชั้นสิทธิ์
       * อยู่แล้วโดยธรรมชาติ (RLS ก็ไม่ครอบ superuser) · ทราฟฟิกของแอปทุกเส้น
       * มี `auth.uid()` เสมอ จึงถูกครอบทั้งหมด
       */
      if new.status <> 'pending' then
        raise exception 'คีย์ร่างไม่ได้: ร่างใหม่ต้องมีสถานะ pending (ได้ "%") — การอนุมัติเป็นคนละขั้นกับการคีย์ และต้องลงสมุดในคำสั่งเดียวกับการอนุมัติ (sri_os.fn_approve_draft)',
          new.status;
      end if;
      if new.posted_txn_id is not null or new.reviewed_by is not null
         or new.reviewed_at is not null then
        raise exception 'คีย์ร่างไม่ได้: ร่างใหม่ต้องไม่มีผลการอนุมัติติดมาด้วย (posted_txn_id/reviewed_by/reviewed_at)';
      end if;

    elsif new.created_by is null and new.source = 'manual' then
      /**
       * ไม่มีผู้ล็อกอินและไม่บอกว่าใครคีย์ → ร่างไร้เจ้าของ
       * คิวอนุมัติจะมีใบที่ถามไม่ได้ว่าใครคีย์ และรายงาน "คนคีย์ = คนอนุมัติ"
       * (C-2) จะมองไม่เห็นใบพวกนี้เลย
       * `source` อื่น (schedule/import/payroll) = งานของเครื่อง ยอมให้ไม่มีชื่อคนได้
       * (กฎเหล็กข้อ 6: automation สร้างได้แค่ร่าง — ห้ามปิดทางนั้น)
       */
      raise exception 'คีย์ร่างไม่ได้: ไม่มีผู้ล็อกอินและไม่ได้ระบุว่าใครคีย์ (created_by) — ร่างต้องตอบได้ว่าใครเป็นคนคีย์ · ร่างที่เครื่องสร้างให้ ต้องระบุ source เป็นอย่างอื่นที่ไม่ใช่ manual';
    end if;
  end if;

  -- ตรวจเฉพาะร่างที่ยัง pending — ร่างที่ตัดสินแล้วเป็นแถวตาย (20261025000017)
  -- และตอนอนุมัติ `fn_post_entry` เป็นคนตรวจเนื้อใบ
  if new.status <> 'pending' then
    return new;
  end if;

  v_problem := fn_draft_entry_problem(
    new.owner_id, new.txn_type_code, new.doc_date, new.cash_date, new.amount,
    new.bank_account_id, new.asset_id, new.contact_id, new.contract_id, new.attachments);
  if v_problem is not null then
    /**
     * **ปฏิเสธ ไม่ใช่รับไว้แล้วค่อยไปตายตอนอนุมัติ** — ร่างที่อนุมัติไม่ได้
     * จะค้างคิวตลอดไป (บทเรียนข้อ 7: เปิดฟีเจอร์ครึ่งเดียวอันตรายกว่าไม่เปิด)
     */
    raise exception 'คีย์ร่างไม่ได้: %', v_problem;
  end if;
  return new;
end $fn$;

comment on function fn_assert_draft_entry_postable() is
  'C-3 · ด่านของตารางร่าง: ตรึง created_by จากผู้ล็อกอินตอน INSERT · ร่างใหม่ต้องเป็น pending และไม่มีผลการอนุมัติติดมา · และร่างที่ยัง pending ต้องผ่าน fn_draft_entry_problem() ทั้งตอน INSERT และ UPDATE (แก้ร่างให้กลายเป็นร่างที่อนุมัติไม่ได้ก็ไม่ได้) · ไม่ใช่ definer โดยตั้งใจ เพื่อให้เห็นของเท่าที่ผู้คีย์เห็น (รูปเดียวกับ fn_corporate_requires_evidence)';

-- ฟังก์ชัน trigger ไม่ใช่ API — trigger ไม่ต้องมี EXECUTE ของผู้เรียก
-- (ถ้าปล่อยไว้ public เรียกได้ `zz_asset_permissions_test` จะฟ้อง และฟังก์ชัน
--  ที่รับ `trigger` ถูกเรียกตรงๆ ไม่ได้อยู่แล้ว แต่ ACL ต้องสะอาดเหมือนตัวอื่น)
revoke all on function fn_assert_draft_entry_postable() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_draft_entry_postable() from anon, authenticated';
end $$;

drop trigger if exists trg_draft_entry_postable on draft_entries;
create trigger trg_draft_entry_postable
  before insert or update on draft_entries
  for each row execute function fn_assert_draft_entry_postable();

-- ============================================================
-- 4 · ปากทางของแอป — ปฏิเสธช่องที่ไม่รู้จักทั้งใบ (รูปเดียวกับ fn_post_entry)
--     ไม่มีสำเนาของกฎในนี้: ด่านจริงคือ trigger ข้างบน
-- ============================================================
create or replace function fn_create_draft(p_payload jsonb) returns jsonb
language plpgsql set search_path = sri_os, public as $fn$
declare
  v_allowed text[] := array['txn_type_code', 'owner_id', 'doc_date', 'cash_date', 'amount',
                            'bank_account_id', 'asset_id', 'contact_id', 'contract_id',
                            'memo', 'attachments', 'due_date', 'source', 'source_ref'];
  v_bad  text;
  v_id   uuid;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'คีย์ร่างไม่ได้: ต้องส่งข้อมูลร่างเป็น object';
  end if;
  select string_agg(k, ', ') into v_bad
    from jsonb_object_keys(p_payload) k where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'คีย์ร่างไม่ได้: มีช่องที่ยังไม่รู้จัก (%) — ปฏิเสธทั้งใบแทนที่จะทิ้งช่องนั้นเงียบๆ · ช่องที่รับคือ %',
      v_bad, array_to_string(v_allowed, ', ');
  end if;
  if p_payload -> 'attachments' is not null
     and jsonb_typeof(p_payload -> 'attachments') <> 'array' then
    raise exception 'คีย์ร่างไม่ได้: attachments ต้องเป็น array ของชื่อไฟล์';
  end if;

  insert into draft_entries (
    owner_id, txn_type_code, doc_date, cash_date, amount, bank_account_id,
    asset_id, contact_id, contract_id, memo, attachments, due_date, source, source_ref)
  values (
    (nullif(p_payload ->> 'owner_id', ''))::uuid,
    nullif(p_payload ->> 'txn_type_code', ''),
    (nullif(p_payload ->> 'doc_date', ''))::date,
    (nullif(p_payload ->> 'cash_date', ''))::date,
    (nullif(p_payload ->> 'amount', ''))::numeric,
    (nullif(p_payload ->> 'bank_account_id', ''))::uuid,
    (nullif(p_payload ->> 'asset_id', ''))::uuid,
    (nullif(p_payload ->> 'contact_id', ''))::uuid,
    (nullif(p_payload ->> 'contract_id', ''))::uuid,
    nullif(p_payload ->> 'memo', ''),
    coalesce((select array_agg(x) from jsonb_array_elements_text(
                coalesce(p_payload -> 'attachments', '[]'::jsonb)) x), '{}'),
    (nullif(p_payload ->> 'due_date', ''))::date,
    coalesce((nullif(p_payload ->> 'source', ''))::txn_source, 'manual'),
    nullif(p_payload ->> 'source_ref', ''))
  returning id into v_id;

  return jsonb_build_object('draft_id', v_id, 'status', 'pending');
end $fn$;

comment on function fn_create_draft(jsonb) is
  'C-3 · ปากทางเดียวที่แอปใช้คีย์ร่าง · ปฏิเสธช่องที่ไม่รู้จักทั้งใบ และ **ไม่รับ created_by/status/posted_txn_id/reviewed_* เลย** (ตารางช่องที่รับอยู่ในตัวฟังก์ชัน) · กฎว่าร่างใช้ได้หรือไม่อยู่ที่ trigger trg_draft_entry_postable ที่เดียว · security invoker → RLS เป็นด่านสิทธิ์';

revoke all on function fn_create_draft(jsonb) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_create_draft(jsonb) from anon';
  execute 'grant execute on function sri_os.fn_create_draft(jsonb) to authenticated';
end $$;

-- ============================================================
-- 5 · ด่านคอลัมน์ (D-089)
-- ============================================================
insert into column_exposure (table_name, column_name, exposure, min_permission, rationale)
values ('draft_entries', 'bank_account_id', 'open', null,
        'บัญชีธนาคารที่เงินของร่างจะเข้า-ออก · เป็น id ไม่ใช่ยอดเงิน และคนที่เห็นแถวร่างได้อยู่แล้ว (เจ้าของร่างหรือคนที่มี ledger.read) ต้องเห็นเพื่อรู้ว่าร่างนี้สมบูรณ์หรือยัง · เลขบัญชี/ชื่อบัญชีจริงยังมีด่านของ bank_accounts อีกชั้น')
on conflict (table_name, column_name) do update
  set exposure = excluded.exposure, min_permission = excluded.min_permission,
      rationale = excluded.rationale;

select fn_apply_column_exposure();

-- ============================================================
-- 6 · guard ท้ายไฟล์
-- ============================================================
do $$
declare v text; v_bad text; n int; n_all int;
begin
  -- (ก) ของครบ
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'sri_os' and table_name = 'draft_entries'
                    and column_name = 'bank_account_id') then
    raise exception 'ไม่มีคอลัมน์ draft_entries.bank_account_id (C-4)';
  end if;
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.draft_entries'::regclass
                    and g.tgname = 'trg_draft_entry_postable' and not g.tgisinternal
                    and (g.tgtype & 2) <> 0          -- BEFORE
                    and (g.tgtype & 4) <> 0          -- INSERT
                    and (g.tgtype & 16) <> 0) then   -- UPDATE
    raise exception 'ไม่มี trigger trg_draft_entry_postable แบบ BEFORE INSERT OR UPDATE — ถ้าไม่ครอบ UPDATE ก็แก้ร่างให้กลายเป็นร่างที่อนุมัติไม่ได้ทีหลังได้';
  end if;

  -- (ข) FK ของคอลัมน์ใหม่ต้องมี (ชี้บัญชีผีไม่ได้)
  if not exists (
    select 1 from pg_constraint c
     where c.conrelid = 'sri_os.draft_entries'::regclass and c.contype = 'f'
       and c.confrelid = 'sri_os.bank_accounts'::regclass) then
    raise exception 'draft_entries.bank_account_id ไม่มี FK ไปยัง bank_accounts';
  end if;

  -- (ค) **กฎอยู่ที่เดียว** — trigger ต้องเรียก fn_draft_entry_problem
  --     และต้องไม่มีสำเนาของกฎในตัวเอง (ตรวจคำที่เป็นหัวใจของกฎ)
  select regexp_replace(
           regexp_replace(p.prosrc, '/\*.*?\*/', ' ', 'gs'), '--[^\n]*', ' ', 'g')
    into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_assert_draft_entry_postable';
  if v is null then
    raise exception 'อ่าน prosrc ของ fn_assert_draft_entry_postable ไม่ได้ — ไม่ยอมผ่านด้วยชุดว่าง';
  end if;
  if v !~ 'fn_draft_entry_problem' then
    raise exception 'trigger ไม่ได้เรียก fn_draft_entry_problem → กฎถูกคัดลอกไปไว้ในตัว trigger (กฎเดียวกันสองที่ = แยกกันเดินทันที)';
  end if;
  if v ~ 'cash_direction|can_accrue|corporate_strict|period_closes' then
    raise exception 'trigger มีสำเนาของกฎอยู่ในตัวเอง (พบคำที่เป็นเนื้อกฎ) — ต้องถาม fn_draft_entry_problem เท่านั้น';
  end if;
  if v !~ 'auth\.uid\(\)' then
    raise exception 'trigger ไม่ได้ตรึง created_by จาก auth.uid() (D-115)';
  end if;

  -- (ง) ปากทางต้องไม่ **เขียน** ช่องที่ผู้ใช้ไม่ควรกำหนดเอง
  --     ตรวจจากรายชื่อคอลัมน์ใน insert target list จริง ไม่ใช่จากการมีคำนั้นอยู่ที่ไหนก็ได้
  --     (ครั้งแรกตรวจแบบหาคำ แล้วมันไปจับ 'status' ในค่าที่ฟังก์ชันคืนกลับ = แดงด้วยเหตุผลผิด)
  v := substring(pg_get_functiondef('sri_os.fn_create_draft(jsonb)'::regprocedure)
                 from 'insert into draft_entries \(([^)]*)\)');
  if v is null then
    raise exception 'อ่านรายชื่อคอลัมน์ที่ fn_create_draft เขียนไม่ได้ — ไม่ยอมผ่านด้วยชุดว่าง';
  end if;
  select string_agg(c, ', ') into v_bad
    from unnest(string_to_array(regexp_replace(v, '\s', '', 'g'), ',')) c
   where c in ('created_by', 'status', 'posted_txn_id', 'reviewed_by', 'reviewed_at',
               'self_review_reason', 'reject_reason');
  if v_bad is not null then
    raise exception 'fn_create_draft เขียนช่อง % เอง — ช่องพวกนี้ต้องมาจากระบบ/ขั้นอนุมัติ ไม่ใช่จากผู้คีย์', v_bad;
  end if;

  -- (จ) **ประตูต้องยอมอะไรได้จริง** — ชุดว่างคือประตูที่ไม่มีประตู
  select count(*) into n from sri_os.fn_draft_allowed_types();
  select count(*) into n_all from sri_os.txn_types where is_active;
  if n = 0 then
    raise exception 'fn_draft_allowed_types() ว่างเปล่า — Staff คีย์ร่างไม่ได้เลย (เท่ากับไม่ได้เปิดฟีเจอร์)';
  end if;
  if n < 20 then
    raise exception 'fn_draft_allowed_types() เหลือแค่ % หมวดจาก % — เข้มเกินไปจนใช้งานจริงไม่ได้ ต้องทบทวนเกณฑ์',
      n, n_all;
  end if;
  -- หมวดหลักที่คนคีย์ทุกวันต้องอยู่ในชุดนั้น (ถ้าหลุด แปลว่าเกณฑ์เพี้ยน)
  select string_agg(c, ', ') into v
    from unnest(array['inc.rent', 'exp.other']) c
   where not exists (select 1 from sri_os.fn_draft_allowed_types() a where a.code = c);
  if v is not null then
    raise exception 'หมวดที่ใช้ทุกวันคีย์เป็นร่างไม่ได้: % — เกณฑ์เข้มเกินไป', v;
  end if;
  -- และต้องไม่ยอมหมวดที่ตารางร่างเก็บข้อมูลไม่พอ
  select string_agg(a.code, ', ') into v
    from sri_os.fn_draft_allowed_types() a
    join sri_os.txn_types t on t.code = a.code
   where t.group_code = 'opening' or t.requires_transfer_target
      or t.requires_loan_terms or t.requires_capital_gain or t.requires_principal_split
      or '3410' in (t.dr_coa_code, t.cr_coa_code);
  if v is not null then
    raise exception 'ชุดหมวดที่ยอมให้คีย์ร่าง มีหมวดที่ข้อมูลไม่พอจะอนุมัติ: %', v;
  end if;

  -- (ฉ) คอลัมน์ใหม่ต้องขึ้นทะเบียนด่านคอลัมน์
  if not exists (select 1 from sri_os.column_exposure
                  where table_name = 'draft_entries' and column_name = 'bank_account_id') then
    raise exception 'คอลัมน์ bank_account_id ไม่ได้ขึ้นทะเบียนด่านคอลัมน์ (D-089)';
  end if;

  -- (ช) แถวร่างที่ค้างอยู่ก่อนไฟล์นี้ ถ้าอนุมัติไม่ได้ ต้องรู้ (ไม่ใช่ปล่อยค้างคิวเงียบๆ)
  select count(*) into n from sri_os.draft_entries d
   where d.status = 'pending'
     and sri_os.fn_draft_entry_problem(d.owner_id, d.txn_type_code, d.doc_date, d.cash_date,
           d.amount, d.bank_account_id, d.asset_id, d.contact_id, d.contract_id,
           d.attachments) is not null;
  if n > 0 then
    raise warning 'มีร่างค้างคิว % ใบที่อนุมัติไม่ได้ด้วยเกณฑ์ใหม่ — ไล่ดูด้วย: select id, sri_os.fn_draft_entry_problem(owner_id, txn_type_code, doc_date, cash_date, amount, bank_account_id, asset_id, contact_id, contract_id, attachments) from sri_os.draft_entries where status = ''pending''', n;
  end if;

  raise notice 'C-3 + C-4 ok · ประตูสร้างร่างพร้อม · คีย์เป็นร่างได้ % หมวดจาก % หมวดที่เปิดใช้ · ช่องบัญชีธนาคารของร่างมีแล้ว',
    (select count(*) from sri_os.fn_draft_allowed_types()), n_all;
end $$;
