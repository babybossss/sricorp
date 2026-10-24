-- ============================================================
-- SRI OS · ปิดรูของด่านล้างยอดค้าง — **เลิกให้ `source_ref` เป็นตัวตัดสินว่าจะตรวจหรือไม่**
--
-- ด่านรุ่น 20261025000003 ปิด "จังหวะพร้อมกัน" ได้จริง แต่มันเริ่มทำงาน
-- **เฉพาะเมื่อผู้เรียกส่ง `source_ref` รูปใบล้าง** (`<uuid>-clr-<n>`) ซึ่งเป็น
-- ข้อความที่ผู้เรียกตั้งเอง → **ไม่ส่งก็ไม่ถูกตรวจ และยอดนั้นไม่ถูกนับ**
-- เหลือแต่ด่านหยาบระดับผู้ถือ (`trg_txn_allowance_limits`) ที่เงียบสนิทเมื่อผู้ถือ
-- มีของค้างก้อนอื่นคลุมอยู่ — เป็นคลาสเดียวกับเรื่องขา 3410 (D-115)
--
-- วัดก่อนแก้ (PG16 · migration ครบถึง 0006):
--   ตั้งค้างรับ 12,000 → ล้าง 7,000 (ส่ง ref) → ล้างอีก 6,000 **โดยไม่ส่ง ref**
--   → **ผ่าน** · ล้างไปรวม 13,000 บนของค้าง 12,000 · ลูกหนี้ของต้นทางนั้น **−1,000**
--   โดยยอดลูกหนี้รวมของผู้ถือยังบวก (มีก้อน 50,000 คลุม) จึงไม่มีด่านไหนพูด
--   และ `adj.writeoff_*` (ตัดหนี้สูญ) ก็ลดบัญชีพักเหมือนกัน แต่ไม่เคยถูกตรวจเลย
--   เพราะไม่ได้ส่งเลขอ้างอิงรูปใบล้าง
--
-- ------------------------------------------------------------
-- **ด่านใหม่อ่านจากอะไร** (ของที่ผู้เรียกเปลี่ยนไม่ได้)
--
-- 1. *ใบนี้ลดบัญชีพักหรือไม่* — อ่านจาก **ผังบัญชี + `txn_types.accrual_coa_code`**
--    (`fn_accrual_coa_codes()`) และทิศจาก `chart_of_accounts.type`
--    (สินทรัพย์ลดด้วยเครดิต · หนี้สินลดด้วยเดบิต) · **ไม่ได้ดูรหัสหมวดหรือป้ายใดๆ
--    ของผู้เรียก** → หมวดใหม่ที่ลดบัญชีพักถูกครอบเองทันที รวม `adj.writeoff_*`
--
-- 2. *ลิงก์ไปต้นทางไหน* — คอลัมน์ใหม่ **`transactions.clears_id` ที่เป็น FK จริง**
--    และถูก **เติมโดย trigger ฝั่ง DB** (`fn_set_clears_id`) จาก `source_ref`
--    ผู้เรียกเขียนค่านี้เองไม่ได้ (ประตูไม่รับช่องนี้ และ trigger เขียนทับทุกครั้ง)
--    → ค่าในคอลัมน์เป็น **ของที่ DB คำนวณ** ไม่ใช่ของที่ผู้เรียกตั้ง
--    ถ้าเลขอ้างอิงชี้ไปใบที่ไม่มีอยู่ ค่าจะเป็น null (ไม่ใช่ FK พัง) แล้ว **ด่านปฏิเสธ**
--
-- 3. *ไม่มีลิงก์ แล้วสมุดบอกไม่ได้ว่าล้างของใคร = **ปฏิเสธ*** ← บรรทัดที่ปิดรูจริง
--    - ของค้างที่ยังเปิดอยู่ของผู้ถือในบัญชีพักนั้น **เหลือใบเดียว** → ไม่กำกวม
--      สมุดบอกได้เองว่าลดของใบนั้น และยอดถูกคุมด้วยยอดค้างของใบนั้น
--      (เส้นทางที่แอปใช้อยู่จริง: ลงใบรับชำระเองจากฟอร์มปกติที่ยังไม่มีช่องเลือกใบค้าง
--       — ถ้าบังคับลิงก์ทุกใบ เส้นทางนี้ตายทั้งเส้น = กันแน่นเกิน บทเรียนข้อ 7)
--    - เปิดอยู่ **มากกว่าหนึ่งใบ** → ไม่มีทางรู้ว่าลดของใบไหน **ต้องระบุลิงก์**
--      นี่คือรูเดิมเป๊ะๆ: ใบหนึ่งถูกล้างเกินและติดลบ โดยอีกใบคลุมยอดรวมไว้ให้ดูปกติ
--    - เปิดอยู่ศูนย์ใบ → ไม่มียอดค้างให้ลด ปฏิเสธ
--    ยกเว้นใบกลับรายการ (`reverses_id`) ซึ่งถูกตรึงให้สะท้อนต้นฉบับตรงตัวแล้ว
--    (`fn_assert_reverse_link` + ด่านเทียบบรรทัดของ 20261009000000)
--    "เปิดอยู่กี่ใบ · เหลือเท่าไร" คำนวณใหม่จากสมุดทุกครั้ง (`fn_accrual_open_sources`)
--
-- `source_ref` ยังอยู่ และยังเป็นที่มาของ `clears_id` (รูปของมันถูกนิยามไว้ที่เดียว
-- ใน `fn_clearing_ref_source`) แต่มันไม่ใช่ "สวิตช์เปิด-ปิดด่าน" อีกแล้ว
--
-- ------------------------------------------------------------
-- **ทำไมเติม `clears_id` ด้วย trigger ไม่ใช่แก้ตัว `fn_post_entry`**
--   ประตูถูกคัดลอกมาเขียนทับแล้วสองรอบ (0001 · 0004) และรอบหนึ่งทำกฎของไฟล์ก่อน
--   หลุดหายไปจนเทสต์ G0 จับได้ · การเติมคอลัมน์ที่คำนวณได้จากแถวเดียวกันเป็นงานของ
--   trigger ไม่ใช่ของประตู → ไม่ต้องคัดลอกประตูอีกรอบ ไม่มีโอกาสทำกฎอื่นหาย
--   และยัง **ครอบทางเขียนตรงเข้าตารางผ่าน REST** ด้วย (ประตูครอบไม่ถึง)
--
-- ลำดับ: **ต้องรันหลัง 20261025000003_clearing_no_over_clear.sql** (เขียนทับ
--   `fn_assert_clearing_not_over_for` และใช้ `fn_clearing_ref_source` ของไฟล์นั้น)
--   · หลัง 20261020000002 (ด่านคอลัมน์) เพราะเพิ่มคอลัมน์ให้ `transactions`
--   → วางต่อท้าย 20261025000006 · ก่อน `20261020000003_replay_end_state_guard.sql`
--
-- idempotent: add column if not exists · create or replace function ·
--   drop trigger if exists ก่อน create · backfill เป็น update ที่ idempotent
--
-- ย้อนกลับ (rollback) — เรียงจากหลังมาหน้า:
--   -- drop trigger  if exists trg_set_clears_id on sri_os.transactions;
--   -- drop function if exists sri_os.fn_set_clears_id();
--   -- drop function if exists sri_os.fn_txn_accrual_reduction(uuid);
--   -- drop function if exists sri_os.fn_accrual_coa_codes();
--   -- รัน 20261025000003_clearing_no_over_clear.sql ซ้ำ (คืน fn_assert_clearing_not_over_for
--   --   รุ่นที่ตัดสินจาก source_ref)
--   -- delete from sri_os.column_exposure where table_name = 'transactions' and column_name = 'clears_id';
--   -- select sri_os.fn_apply_column_exposure();
--   -- alter table sri_os.transactions drop column if exists clears_id;   (ลบประวัติการล้างถาวร)
--   -- ย้อนแล้วได้สภาพเดิมคือ **ล้างเกินได้ด้วยการไม่ส่งเลขอ้างอิง** — ไม่แนะนำ
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 0 · pre-flight
-- ============================================================
do $$
begin
  if to_regprocedure('sri_os.fn_clearing_ref_source(text)') is null
     or to_regprocedure('sri_os.fn_assert_clearing_not_over_for(uuid)') is null then
    raise exception 'ไฟล์นี้ต่อยอดจาก 20261025000003_clearing_no_over_clear.sql ซึ่งยังไม่มีในฐานข้อมูล — ต้องรันหลังไฟล์นั้น (ลงทะเบียนลำดับใน supabase/migration-order.txt และ UNDER_TEST ของ scripts/test-rls-local.sh)';
  end if;
  if to_regprocedure('sri_os.fn_apply_column_exposure()') is null then
    raise exception 'ยังไม่มีด่านคอลัมน์ (20261020000002) — คอลัมน์ใหม่จะไม่ถูกจัดประเภทและไฟล์อื่นจะพังตามเป็นลูกโซ่';
  end if;
end $$;

-- ============================================================
-- 1 · คอลัมน์ `clears_id` — ลิงก์ที่ DB บังคับได้ ไม่ใช่ข้อความ
-- ============================================================
alter table transactions
  add column if not exists clears_id uuid references transactions(id);

comment on column transactions.clears_id is
  'รายการต้นทางที่ใบนี้ล้างยอดค้างของมัน · **เติมโดย trigger fn_set_clears_id จาก source_ref** ผู้เรียกตั้งเองไม่ได้ (ประตูไม่รับช่องนี้ และ trigger เขียนทับทุกครั้ง) · null = ใบนี้ไม่ได้ล้างยอดค้างของใคร — ซึ่งทำได้เฉพาะใบที่ไม่ลดบัญชีพัก (ดู fn_assert_clearing_not_over_for)';

create index if not exists transactions_clears_id_idx on transactions (clears_id)
  where clears_id is not null;

-- ด่านคอลัมน์ D-089 — คอลัมน์ใหม่ของสมุดเงินต้องถูกจัดประเภท ไม่งั้นไฟล์อื่นพังตามกัน
insert into column_exposure (table_name, column_name, exposure, min_permission, rationale) values
  ('transactions', 'clears_id', 'row', 'ledger.read',
   'ลิงก์ไปรายการต้นทางที่ใบนี้ล้างยอดค้าง · เป็นข้อมูลของรายการเงิน ชั้นเดียวกับ source_ref/reverses_id · DB เติมให้จาก source_ref และด่านกันล้างเกินใช้ตัวนี้เป็นลิงก์จริงแทนการจับข้อความ')
on conflict (table_name, column_name) do update
  set exposure = excluded.exposure, min_permission = excluded.min_permission,
      rationale = excluded.rationale;
select fn_apply_column_exposure();

-- ============================================================
-- 2 · trigger เติม `clears_id` — **DB เป็นคนตั้ง ไม่ใช่ผู้เรียก**
--
-- เขียนทับค่าที่ส่งมาทุกครั้ง (รวมทางเขียนตรงเข้าตารางผ่าน REST) → ค่าในคอลัมน์
-- เป็นฟังก์ชันของ `source_ref` เสมอ และ **ไม่ชี้ไปใบที่ไม่มีอยู่** (คืน null แทน)
-- ============================================================
create or replace function fn_set_clears_id() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare v_src uuid;
begin
  v_src := sri_os.fn_clearing_ref_source(new.source_ref);
  if v_src is null then
    new.clears_id := null;
    return new;
  end if;
  -- ต้นทางต้องมีอยู่จริง · ถ้าไม่มี ปล่อยเป็น null แล้วให้ด่านอธิบายด้วยภาษาคน
  -- (ถ้าปล่อยให้ FK เป็นคนเด้ง ผู้ใช้จะเห็นข้อความดิบที่ไม่บอกว่าต้องทำอะไร)
  select t.id into new.clears_id
    from sri_os.transactions t where t.id = v_src;
  return new;
end $fn$;

comment on function fn_set_clears_id() is
  'เติม transactions.clears_id จาก source_ref (รูปของเลขอ้างอิงอยู่ที่ fn_clearing_ref_source ที่เดียว) · เขียนทับค่าที่ผู้เรียกส่งมาเสมอ → ลิงก์การล้างเป็นของที่ DB คำนวณ ไม่ใช่ของที่ผู้เรียกตั้ง';

revoke all on function fn_set_clears_id() from public;
do $$ begin execute 'revoke all on function sri_os.fn_set_clears_id() from anon, authenticated'; end $$;

drop trigger if exists trg_set_clears_id on transactions;
create trigger trg_set_clears_id
  before insert or update of source_ref, clears_id on transactions
  for each row execute function fn_set_clears_id();

-- backfill ของเดิม (idempotent · ไม่แตะแถวที่ไม่ใช่ใบล้าง)
update transactions t
   set clears_id = fn_clearing_ref_source(t.source_ref)
 where t.clears_id is null
   and fn_clearing_ref_source(t.source_ref) is not null
   and exists (select 1 from transactions s where s.id = fn_clearing_ref_source(t.source_ref));

-- ============================================================
-- 2b · ลิงก์การล้างต้องอ่านได้ **ผ่านวิวสมุด**
--
-- ด่าน D-098 ห้ามฟังก์ชันรายงาน (set-returning) อ่าน `transactions` ตรงๆ
-- → ฟังก์ชันที่คิด "ของค้างที่ยังเปิดอยู่มีกี่ใบ" ต้องอ่านผ่านวิว จึงต้องมีคอลัมน์นี้ในวิว
-- เติม **ต่อท้าย** เท่านั้น (create or replace view เปลี่ยนของเดิมไม่ได้)
-- ============================================================
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
  l.memo                as line_memo,
  -- FCD (25/10) · ข้อมูลสกุลเดิมของบรรทัด — **ต่อท้ายคอลัมน์เดิมเท่านั้น**
  -- (`create or replace view` เพิ่มคอลัมน์ได้แค่ท้ายสุด และห้ามเปลี่ยนชื่อ/ชนิดของเดิม)
  l.currency,
  l.amount_original,
  l.fx_rate,
  l.fx_rate_date,
  -- ลิงก์การล้างยอดค้าง (25/10 · 20261025000007) — **ต่อท้ายคอลัมน์เดิมเท่านั้น**
  -- ด่านกันล้างเกินและรายงานยอดค้างต้องอ่านลิงก์นี้ผ่านวิว (D-098 ห้ามอ่านตารางตรง)
  t.clears_id
from transactions t
join transaction_lines l on l.transaction_id = t.id
-- allow-list ไม่ใช่ <> 'void' — เหตุผลอยู่หัวไฟล์ (ค่าสถานะใหม่ต้องไม่ไหลเข้างบเอง)
where t.status = 'posted';

alter view v_ledger_posted set (security_invoker = true);

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
  l.memo                as line_memo,
  -- FCD (25/10) · ข้อมูลสกุลเดิมของบรรทัด — **ต่อท้ายคอลัมน์เดิมเท่านั้น**
  -- (`create or replace view` เพิ่มคอลัมน์ได้แค่ท้ายสุด และห้ามเปลี่ยนชื่อ/ชนิดของเดิม)
  l.currency,
  l.amount_original,
  l.fx_rate,
  l.fx_rate_date,
  -- ลิงก์การล้างยอดค้าง (25/10 · 20261025000007) — **ต่อท้ายคอลัมน์เดิมเท่านั้น**
  -- ด่านกันล้างเกินและรายงานยอดค้างต้องอ่านลิงก์นี้ผ่านวิว (D-098 ห้ามอ่านตารางตรง)
  t.clears_id
from transactions t
join transaction_lines l on l.transaction_id = t.id
where t.status = 'void';

alter view v_ledger_voided set (security_invoker = true);

-- ============================================================
-- 3 · บัญชีพักมีรหัสอะไร — **อ่านจากตารางกฎ** ไม่ใช่รายชื่อที่พิมพ์ไว้ในด่าน
-- ============================================================
create or replace function fn_accrual_coa_codes() returns text[]
language sql stable security definer set search_path = '' as $fn$
  select coalesce(array_agg(distinct ty.accrual_coa_code), '{}')
    from sri_os.txn_types ty
   where ty.accrual_coa_code is not null;
$fn$;

comment on function fn_accrual_coa_codes() is
  'รหัสบัญชีพัก (ค้างรับ-ค้างจ่าย) ทั้งหมดจากตารางกฎ `txn_types.accrual_coa_code` · ที่เดียวที่รู้ว่าบัญชีไหนเป็นบัญชีพัก → เพิ่มหมวดใหม่ที่มีบัญชีพักใหม่ ด่านครอบเองทันที';

revoke all on function fn_accrual_coa_codes() from public;
do $$ begin execute 'revoke all on function sri_os.fn_accrual_coa_codes() from anon, authenticated'; end $$;

-- ============================================================
-- 4 · ใบนี้ **ลด** บัญชีพักไหน เท่าไร — ทิศจากประเภทบัญชีในผังบัญชี
--
-- สินทรัพย์ (ลูกหนี้) ลดด้วย **เครดิต** · หนี้สิน (เจ้าหนี้) ลดด้วย **เดบิต**
-- → ไม่ต้องรู้ว่าหมวดชื่ออะไร และป้ายของผู้เรียกเปลี่ยนคำตอบไม่ได้
-- ============================================================
create or replace function fn_txn_accrual_reduction(p_txn uuid) returns text
language plpgsql stable security definer set search_path = '' as $fn$
declare v_list text[];
begin
  /**
   * **คืนค่าเดี่ยว (ไม่ใช่ set-returning) โดยตั้งใจ** — D-098 ห้ามฟังก์ชันรายงาน
   * แบบ set-returning อ่าน transactions/transaction_lines ตรงๆ (ด่านของ
   * 20261020000001 จับได้) · ด่านนี้ต้องเห็นบรรทัดของใบที่กำลังตรวจทุกสถานะ
   * จึงอ่านตารางตรง และเลี่ยงข้อห้ามด้วยการคืนค่าเดี่ยว รูปเดียวกับ
   * `fn_fx_entry_currency()` (20261025000006)
   */
  select coalesce(array_agg(x.code order by x.code), '{}') into v_list
    from (
      select c.code,
             round(sum(case when c.type = 'liability'
                            then coalesce(l.debit, 0) - coalesce(l.credit, 0)
                            else coalesce(l.credit, 0) - coalesce(l.debit, 0) end), 2) as reduced
        from sri_os.transaction_lines l
        join sri_os.chart_of_accounts c on c.id = l.coa_id
       where l.transaction_id = p_txn
         and c.code = any (sri_os.fn_accrual_coa_codes())
       group by c.code
    ) x
   where x.reduced > 0;

  if array_length(v_list, 1) is null then
    return null;
  end if;
  if array_length(v_list, 1) > 1 then
    raise exception 'ใบเดียวลดบัญชีพักหลายบัญชีพร้อมกัน (%) — แยกเป็นใบละบัญชีพัก เพราะยอดที่ล้างต้องนับคู่กับรายการต้นทางของบัญชีนั้น ถ้ารวมใบเดียวจะตรวจยอดค้างไม่ได้ว่าของใครเกิน',
      array_to_string(v_list, ' + ');
  end if;
  return v_list[1];
end $fn$;

comment on function fn_txn_accrual_reduction(uuid) is
  'บัญชีพักที่ใบนี้ **ลด** (คืนค่าเดี่ยว · null = ไม่ลดเลย · ลดหลายบัญชีในใบเดียว = ปฏิเสธ) · ทิศอ่านจาก chart_of_accounts.type (สินทรัพย์ลดด้วยเครดิต · หนี้สินลดด้วยเดบิต) และรายชื่อบัญชีพักจากตารางกฎ → "ใบนี้เป็นการล้างยอดค้างหรือไม่" ตัดสินจากบัญชีที่แตะ ไม่ใช่จากป้ายของผู้เรียก';

revoke all on function fn_txn_accrual_reduction(uuid) from public;
do $$ begin execute 'revoke all on function sri_os.fn_txn_accrual_reduction(uuid) from anon, authenticated'; end $$;


-- ============================================================
-- 4b · ของค้างที่ **ยังเปิดอยู่** ของผู้ถือในบัญชีพักหนึ่ง — คำนวณใหม่จากสมุด
--
--   ยอดค้างคงเหลือของใบหนึ่ง = (ตั้งค้าง + ใบที่กลับรายการใบตั้งค้าง)
--                              − (ใบที่ลิงก์มาล้างใบนี้ + ใบที่กลับรายการใบล้างเหล่านั้น)
--
-- อ่านจาก `v_ledger_posted` เท่านั้น (D-098) · ลิงก์คือคอลัมน์ `clears_id`
-- ที่ DB เติมให้ ไม่ใช่การจับข้อความใน `source_ref`
-- ============================================================
create or replace function fn_accrual_open_sources(p_owner uuid, p_coa text)
returns table (src uuid, remaining numeric)
language sql stable security definer set search_path = '' as $fn$
  with mine as (
    select v.transaction_id, v.reverses_id, v.clears_id,
           sum(v.debit - v.credit) as net
      from sri_os.v_ledger_posted v
      join sri_os.chart_of_accounts c on c.id = v.coa_id
     where v.owner_id = p_owner and c.code = p_coa
     group by v.transaction_id, v.reverses_id, v.clears_id
  ),
  sources as (
    /**
     * ใบตั้งค้าง = ไม่ใช่ใบกลับรายการ · ไม่ใช่ใบที่ลิงก์ไปล้างใบอื่น · และยอดอยู่
     * **ทิศเดียวกับการตั้งค้างของบัญชีนั้น** (ลูกหนี้/สินทรัพย์ตั้งด้วยเดบิต ·
     * เจ้าหนี้/หนี้สินตั้งด้วยเครดิต) — ทิศอ่านจากประเภทบัญชีในผังบัญชี
     *
     * ขาดเงื่อนไขทิศไม่ได้: **ใบล้างที่ไม่มีลิงก์ (รวมใบที่กำลังตรวจ) จะถูกนับเป็น
     * "ของค้างอีกใบ"** แล้วเคส "เปิดอยู่ใบเดียว" จะกลายเป็นสองใบเสมอ
     * (เจอตอนรันจริง: ลงรับชำระเองตอนมีของค้างใบเดียวถูกปฏิเสธ = กันแน่นเกิน)
     */
    select m.transaction_id as id, m.net
      from mine m
     where m.reverses_id is null and m.clears_id is null
       and case when (select c.type from sri_os.chart_of_accounts c where c.code = p_coa) = 'liability'
                then m.net < -0.005
                else m.net > 0.005
           end
  )
  select s.id,
         round(abs(s.net)
               -- ใบล้างที่ลิงก์มาที่ใบนี้ (และใบที่กลับรายการใบล้างเหล่านั้น) — ทิศตรงข้ามกับการตั้งค้าง
               + sign(s.net) * coalesce((
                   select sum(m2.net) from mine m2
                    where m2.clears_id = s.id
                       or m2.reverses_id in (select m3.transaction_id from mine m3 where m3.clears_id = s.id)
                 ), 0)
               -- ใบที่กลับรายการใบตั้งค้างนี้ (คืนยอดค้าง)
               + sign(s.net) * coalesce((
                   select sum(m4.net) from mine m4 where m4.reverses_id = s.id
                 ), 0), 2) as remaining
    from sources s;
$fn$;

comment on function fn_accrual_open_sources(uuid, text) is
  'ยอดค้างคงเหลือของรายการต้นทางแต่ละใบในบัญชีพักหนึ่งของผู้ถือหนึ่ง คำนวณใหม่จากสมุด (v_ledger_posted) ทุกครั้ง · ลิงก์มาจากคอลัมน์ clears_id ที่ DB เติมให้ ไม่ใช่ข้อความใน source_ref · ใช้ตัดสินว่า "สมุดบอกได้เองไหมว่าล้างของใบไหน" (เปิดอยู่ใบเดียว = บอกได้ · หลายใบ = ต้องระบุลิงก์)';

revoke all on function fn_accrual_open_sources(uuid, text) from public;
do $$ begin execute 'revoke all on function sri_os.fn_accrual_open_sources(uuid, text) from anon, authenticated'; end $$;

-- ============================================================
-- 5 · ด่านกันล้างเกิน v2 — ชื่อเดิม (trigger ของ 0003 ผูกไว้แล้ว · กฎเดียว ที่เดียว)
-- ============================================================
create or replace function fn_assert_clearing_not_over_for(p_txn uuid) returns void
language plpgsql security definer set search_path = '' as $fn$
declare
  v_owner    uuid;
  v_rev      uuid;
  v_clears   uuid;
  v_ref      text;
  v_memo     text;
  v_accrual  text;
  v_src_owner uuid;
  v_accrued  numeric;
  v_cleared  numeric;
  v_sign     numeric;
  v_open     int;
  v_only     uuid;
  v_capacity numeric;
  v_unlinked numeric;
begin
  select t.owner_id, t.reverses_id, t.clears_id, t.source_ref
    into v_owner, v_rev, v_clears, v_ref
    from sri_os.transactions t where t.id = p_txn;
  if v_owner is null then
    return;
  end if;

  /**
   * ใบกลับรายการ = การ **คืนยอด** ไม่ใช่การล้างเพิ่ม · ยอดของมันถูกนับหักกลบใน
   * สมการข้างล่างอยู่แล้ว และรูปของมันถูกตรึงให้สะท้อนต้นฉบับตรงตัวโดย
   * `fn_assert_reverse_link` + ด่านเทียบบรรทัด (20261009000000) จึงแต่งเองไม่ได้
   * ถ้าตรวจมันด้วยจะกลายเป็นด่านที่ห้ามแก้ของที่ลงผิด (กฎเหล็กข้อ 1)
   */
  if v_rev is not null then
    return;
  end if;

  -- **ใบนี้ลดบัญชีพักหรือไม่ — ตัดสินจากบัญชี ไม่ใช่จากเลขอ้างอิง**
  v_accrual := sri_os.fn_txn_accrual_reduction(p_txn);
  if v_accrual is null then
    return;   -- ไม่ลดบัญชีพักเลย → ด่านนี้ไม่เกี่ยว (ของเดิมเกือบทุกใบมาทางนี้)
  end if;

  select t.memo into v_memo from sri_os.transactions t where t.id = p_txn;

  /**
   * ---------- ลิงก์: บังคับเมื่อ **สมุดบอกไม่ได้เองว่าล้างของใคร** ----------
   *
   * ของค้างที่เปิดอยู่มีใบเดียว → ไม่มีอะไรกำกวม สมุดเองบอกได้ว่าลดของใบนั้น
   * (เส้นทางที่ใช้อยู่จริงในแอป: ลงใบรับชำระเองจากฟอร์มปกติ โดยไม่มีเลขอ้างอิง)
   * ของค้างที่เปิดอยู่ **มากกว่าหนึ่งใบ** → ไม่มีทางรู้ว่าลดของใบไหน และนี่คือ
   * ช่องที่ทำให้ล้างเกินได้: ใบหนึ่งติดลบ โดยมีอีกใบคลุมยอดรวมไว้ให้ดูปกติ
   * → **ต้องระบุลิงก์ ไม่ใช่ปล่อยผ่าน**
   *
   * ทั้ง "เปิดอยู่กี่ใบ" และ "ยอดคงเหลือเท่าไร" คำนวณใหม่จากสมุดทุกครั้ง
   * (ของที่ผู้เรียกเปลี่ยนไม่ได้) ไม่ใช่อ่านจากเลขอ้างอิงที่ส่งมา
   */
  if v_clears is null then
    /**
     * ส่งเลขอ้างอิงมาในรูปใบล้างแต่ **ชี้ไปใบที่ไม่มีอยู่** → บอกให้ตรงจุด
     * (ไม่ปล่อยให้ไปโผล่เป็น "กำกวม" ซึ่งชี้ผิดสาเหตุ) · ข้อความยังมีประโยคกลาง
     * เดียวกันกับทุกรูปของลิงก์ที่ใช้ไม่ได้
     */
    if sri_os.fn_clearing_ref_source(v_ref) is not null then
      raise exception 'ใบนี้อ้างเลขอ้างอิงการล้าง "%" แต่**ไม่มีรายการต้นทาง** % อยู่ในสมุด — ลิงก์การล้าง **ต้องชี้ไปที่รายการต้นทางที่มียอดค้างจริง** ของผู้ถือเดียวกัน (เลขอ้างอิงถูกประกอบเองหรือรายการต้นทางไม่ได้ถูกบันทึก)',
        v_ref, sri_os.fn_clearing_ref_source(v_ref);
    end if;

    -- ยอดค้างของแต่ละใบ (ตั้งค้าง − ที่ล้างไปแล้วผ่านลิงก์) ของผู้ถือนี้ในบัญชีนี้
    -- (uuid ไม่มี min() — ใช้ array_agg แล้วหยิบตัวแรก ซึ่งใช้ได้เพราะเราสนแค่กรณีเปิดอยู่ใบเดียว)
    select count(*), (array_agg(o.src))[1] into v_open, v_only
      from sri_os.fn_accrual_open_sources(v_owner, v_accrual) o
     where o.remaining > 0.005;

    if v_open = 0 then
      raise exception 'ใบนี้ลดยอดในบัญชีพัก % ของผู้ถือนี้ แต่ **ไม่มีรายการต้นทางที่ยังมียอดค้างเหลืออยู่เลย** — ลิงก์การล้าง **ต้องชี้ไปที่รายการต้นทางที่มียอดค้างจริง** ของผู้ถือเดียวกัน · ลดต่อจะทำให้ลูกหนี้/เจ้าหนี้ติดลบและเงินสดไม่ตรง statement · ถ้าเก็บเงินได้เกินที่เขาเป็นหนี้ ส่วนเกินคือเงินรับล่วงหน้า ต้องลงเป็นรายการของตัวเอง',
        v_accrual;
    end if;

    if v_open > 1 then
      raise exception 'ใบนี้ลดยอดในบัญชีพัก % แต่ผู้ถือนี้มีของค้างที่ยังเปิดอยู่ % ใบ จึงไม่มีทางรู้ว่าล้างของใบไหน — ต้องระบุเลขอ้างอิงการล้าง (<id ของรายการต้นทาง>-clr-<n>) · ลิงก์นี้ **ต้องชี้ไปที่รายการต้นทางที่มียอดค้างจริง** ของผู้ถือเดียวกัน · ถ้าไม่ระบุ ใบหนึ่งจะถูกล้างเกินและติดลบเงียบๆ โดยมีอีกใบคลุมยอดรวมไว้ให้ดูปกติ (ตอนนี้เลขอ้างอิงที่ส่งมาคือ "%")',
        v_accrual, v_open, coalesce(v_ref, '(ไม่ส่งมา)');
    end if;

    -- เปิดอยู่ใบเดียว → ลดของใบนั้นแน่นอน · ล็อกแถวนั้นแล้วคุมด้วยยอดค้างของมัน
    v_clears := v_only;
    perform 1 from sri_os.transactions t where t.id = v_clears for update;
  end if;

  -- ล็อกแถวต้นทางก่อนคิดยอด — บรรทัดที่ปิด "จังหวะพร้อมกัน" (ของ 0003 · ต้องคงไว้)
  perform 1 from sri_os.transactions t where t.id = v_clears for update;

  select t.owner_id into v_src_owner from sri_os.transactions t where t.id = v_clears;
  if v_src_owner is distinct from v_owner then
    raise exception 'ใบนี้ลดบัญชีพัก % ของผู้ถือหนึ่ง แต่ลิงก์ชี้ไปรายการต้นทางของผู้ถืออีกคน — ลิงก์ **ต้องชี้ไปที่รายการต้นทางที่มียอดค้างจริง** ของผู้ถือเดียวกัน · ยอดค้างของคนอื่นเอามาคุมการลดลูกหนี้/เจ้าหนี้ของผู้ถือนี้ไม่ได้ (ลูกหนี้ของผู้ถือนี้จะติดลบโดยที่สมการของอีกคนยังดูปกติ)',
      v_accrual;
  end if;

  -- ยอดค้างของต้นทาง: บรรทัดบัญชีพักของใบต้นทาง **บวกใบที่กลับรายการต้นทางนั้น**
  select coalesce(sum(v.debit - v.credit), 0) into v_accrued
    from sri_os.v_ledger_posted v
    join sri_os.chart_of_accounts c on c.id = v.coa_id
   where c.code = v_accrual
     and (v.transaction_id = v_clears or v.reverses_id = v_clears);

  if round(v_accrued, 2) = 0 then
    raise exception 'ใบนี้ลดยอดในบัญชีพัก % แต่รายการต้นทางที่ลิงก์ชี้ไปไม่มียอดค้างในบัญชีนั้นเลย (อาจเป็นใบที่รับเงินสดทันทีโดยไม่ได้ตั้งค้าง หรือถูกกลับรายการไปแล้ว) — ลิงก์ **ต้องชี้ไปที่รายการต้นทางที่มียอดค้างจริง** ของผู้ถือเดียวกัน · ล้างต่อจะทำให้ลูกหนี้/เจ้าหนี้ติดลบและเงินสดไม่ตรง statement',
      v_accrual;
  end if;

  -- ใบล้างทั้งหมดของต้นทางนี้ (รวมใบนี้) **บวกใบที่กลับรายการใบล้าง**
  -- ลิงก์คือคอลัมน์ `clears_id` ที่ DB เติมให้ ไม่ใช่การจับข้อความใน source_ref
  select coalesce(sum(v.debit - v.credit), 0) into v_cleared
    from sri_os.v_ledger_posted v
    join sri_os.chart_of_accounts c on c.id = v.coa_id
   where c.code = v_accrual
     and (
       v.transaction_id in (select t.id from sri_os.transactions t where t.clears_id = v_clears)
       or v.reverses_id in (select t.id from sri_os.transactions t where t.clears_id = v_clears)
     );

  -- ทิศ: ลูกหนี้ (สินทรัพย์) ตั้งค้างด้วยเดบิต · เจ้าหนี้ (หนี้สิน) ด้วยเครดิต
  v_sign    := sign(v_accrued);
  v_accrued := abs(v_accrued);
  v_cleared := -v_sign * v_cleared;

  if round(v_cleared, 2) > round(v_accrued, 2) + 0.005 then
    raise exception 'ล้างยอดค้างเกิน: รายการต้นทาง "%" (%) ตั้งค้างไว้ % บาท แต่ใบที่ลดบัญชีพักของต้นทางนี้รวมใบนี้เป็น % บาท (เกิน % บาท) — ล้างเกินทำให้ลูกหนี้/เจ้าหนี้ติดลบและเงินสดในระบบไม่ตรงกับยอดธนาคาร · ถ้าเก็บเงินได้มากกว่าที่เขาเป็นหนี้ ส่วนเกินคือเงินรับล่วงหน้า (เจ้าหนี้) ต้องลงเป็นรายการของตัวเอง ไม่ใช่ล้างยอดค้างเกิน · ถ้าเป็นการตัดหนี้สูญ ให้ตัดได้ไม่เกินยอดค้างที่เหลือ',
      coalesce((select t.memo from sri_os.transactions t where t.id = v_clears), v_clears::text),
      v_accrual, round(v_accrued, 2), round(v_cleared, 2), round(v_cleared - v_accrued, 2);
  end if;
end $fn$;

comment on function fn_assert_clearing_not_over_for(uuid) is
  'ด่านกันล้างยอดค้างเกิน · **ยิงทุกใบที่ลดบัญชีพัก** ซึ่งตัดสินจากผังบัญชี + txn_types.accrual_coa_code (ไม่ใช่จากรูปของ source_ref ที่ผู้เรียกตั้งเอง — รูเดิม: ไม่ส่งก็ไม่ถูกตรวจ) · ลิงก์ไปต้นทางอ่านจากคอลัมน์ FK clears_id ที่ trigger ของ DB เติมให้ · ไม่มีลิงก์: ของค้างเปิดอยู่ใบเดียว → สมุดบอกได้เองว่าลดของใบนั้น · เปิดหลายใบ (หรือศูนย์ใบ) → ปฏิเสธ เพราะนั่นคือช่องที่ล้างเกินได้โดยมีอีกใบคลุมยอดรวมไว้ · ยอดที่ล้างทั้งหมด (วัดจากบัญชีพัก ไม่ใช่จากขาเงินสด) ห้ามเกินยอดค้างของต้นทาง · **ล็อกแถวต้นทางก่อนคิดยอด** จึงกันคำขอที่มาถึงพร้อมกันได้ · ใบกลับรายการได้รับการยกเว้นเพราะถูกตรึงให้สะท้อนต้นฉบับตรงตัวแล้ว';

revoke all on function fn_assert_clearing_not_over_for(uuid) from public;
do $$ begin execute 'revoke all on function sri_os.fn_assert_clearing_not_over_for(uuid) from anon, authenticated'; end $$;

-- ============================================================
-- 6 · guard ท้ายไฟล์
-- ============================================================
do $$
declare v text; n int; v_owner uuid; v_coa text;
begin
  -- (ก) ด่านต้องเป็นรุ่นที่ตัดสินจากบัญชี + clears_id
  v := pg_get_functiondef('sri_os.fn_assert_clearing_not_over_for(uuid)'::regprocedure);
  if v !~ 'fn_txn_accrual_reduction' or v !~ 'clears_id' then
    raise exception 'ด่านกันล้างเกินไม่ได้ตัดสินจากบัญชีพัก/ลิงก์ที่ DB เติม — มีไฟล์อื่นเขียนทับหลังไฟล์นี้';
  end if;
  if v !~ 'for update' then
    raise exception 'ด่านกันล้างเกินไม่ได้ล็อกแถวต้นทางอีกแล้ว — คำขอสองใบที่มาพร้อมกันจะคิดยอดจากสมุดเดียวกันแล้วผ่านทั้งคู่ (ของ 20261025000003)';
  end if;
  if v ~ 'fn_clearing_ref_source\(v\.source_ref\)' then
    raise exception 'ด่านกลับไปจับข้อความใน source_ref เพื่อนับยอดที่ล้างแล้ว — ใบที่ไม่ส่งเลขอ้างอิงจะไม่ถูกนับอีก (รูเดิม)';
  end if;

  -- (ข) trigger ต้องยังผูกอยู่ครบ
  select string_agg(x.want, ', ') into v
    from (values ('trg_set_clears_id'), ('trg_assert_clearing_not_over_txn')) x(want)
   where not exists (select 1 from pg_trigger g
                      where g.tgrelid = 'sri_os.transactions'::regclass
                        and g.tgname = x.want and not g.tgisinternal);
  if v is not null then
    raise exception 'trigger หายไปจาก transactions: %', v;
  end if;
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.transaction_lines'::regclass
                    and g.tgname = 'trg_assert_clearing_not_over' and not g.tgisinternal) then
    raise exception 'trigger trg_assert_clearing_not_over หายไปจาก transaction_lines';
  end if;

  -- (ค) ฟังก์ชันด่านเรียกตรงไม่ได้ (D-089)
  select string_agg(x.f, ', ') into v
    from unnest(array['sri_os.fn_assert_clearing_not_over_for(uuid)',
                      'sri_os.fn_set_clears_id()',
                      'sri_os.fn_accrual_coa_codes()',
                      'sri_os.fn_txn_accrual_reduction(uuid)']) x(f)
   where has_function_privilege('authenticated', x.f, 'execute')
      or has_function_privilege('anon', x.f, 'execute');
  if v is not null then
    raise exception 'ฟังก์ชันด่านยังเรียกตรงได้: % = ทางข้าม policy ของสมุดเงิน', v;
  end if;

  -- (ง) ของที่อยู่ในสมุดแล้วต้องไม่ละเมิดกฎใหม่ — ต้องรู้ตอน migrate ไม่ใช่ตอนผู้ใช้กด
  --     ตรวจ **ยอดค้างคงเหลือของแต่ละใบ** (ซึ่งเป็นสิ่งที่กฎใหม่คุม) ไม่ใช่เรียกร้อง
  --     ลิงก์ย้อนหลังกับใบเก่า: ใบเก่าที่ลงตอนมีของค้างใบเดียวถูกต้องตามกฎใหม่อยู่แล้ว
  n := 0;
  for v_owner, v_coa in
    select distinct t.owner_id, c.code
      from sri_os.v_ledger_posted t
      join sri_os.chart_of_accounts c on c.id = t.coa_id
     where c.code = any (sri_os.fn_accrual_coa_codes())
  loop
    if exists (select 1 from sri_os.fn_accrual_open_sources(v_owner, v_coa) o
                where o.remaining < -0.005) then
      n := n + 1;
      raise warning 'ผู้ถือ % มีรายการต้นทางในบัญชีพัก % ที่ถูกล้างเกินไปแล้ว (ยอดค้างคงเหลือติดลบ) — ต้องแก้ด้วยใบกลับรายการ ไม่ใช่แก้แถว (กฎเหล็กข้อ 1)',
        v_owner, v_coa;
    end if;
  end loop;
  if n > 0 then
    raise exception 'มี % (ผู้ถือ × บัญชีพัก) ที่มีรายการต้นทางถูกล้างเกินอยู่ในสมุดแล้ว — ด่านใหม่จะปฏิเสธใบถัดไปที่แตะบัญชีพักนั้น ต้องกลับรายการใบที่ล้างเกินก่อน · ดูรายการ: select o.* from sri_os.owners w cross join lateral sri_os.fn_accrual_open_sources(w.id, ''1200'') o where o.remaining < 0;', n;
  end if;

  raise notice 'ด่านล้างยอดค้างอ่านจากของที่ผู้เรียกเปลี่ยนไม่ได้แล้ว: "ใบนี้ลดบัญชีพักไหม" จากผังบัญชี+ตารางกฎ · ลิงก์ไปต้นทางจากคอลัมน์ FK clears_id ที่ DB เติมให้ · ของค้างเปิดอยู่ใบเดียว = สมุดบอกได้เอง · เปิดหลายใบแล้วไม่ระบุ = ปฏิเสธ (เดิม: ไม่ส่งเลขอ้างอิง = ไม่ถูกตรวจเลย)';
end $$;
