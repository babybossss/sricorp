-- ============================================================
-- SRI OS · เทสต์ของ 20261010000002_recovery_no_accrual.sql
--   **ช่องปั๊มรายได้ไม่จำกัด** ที่ผู้ตรวจรันพิสูจน์แล้ว (D-106)
--   ของเดิมอยู่ใน zz_recovery_cap_test.sql · zz_allowance_test.sql ·
--   zz_allowance_fixes_test.sql ซึ่ง **ยังต้องเขียวทั้งสามไฟล์**
--
-- ------------------------------------------------------------
-- รูที่ปิด · "ตั้งค้างรับ" ของหมวดหนี้สูญได้รับคืน
-- ------------------------------------------------------------
-- `inc.bad_debt_recovered` เคยมี `accrualCoa: "1220"` ในตารางกฎ
--   → `txn_types.accrual_coa_code` = '1220' → `fn_assert_line_coa_in_rules`
--     (ซึ่งอ่าน **ชุดบัญชี** ของหมวดจาก txn_types รวม accrual_coa_code)
--     ยอมให้ใบของหมวดนี้ลงบรรทัด 1220 ได้
--   → ลงใบ **Dr 1220 / Cr 4320** ได้ = ปลุกลูกหนี้ของหนี้ที่ตัดไปแล้วขึ้นมาใหม่
--     **โดยไม่มีเงินเข้าเลย** (ขัดกับคอมเมนต์ของหมวดเองที่ว่า "ไม่ปลุกลูกหนี้")
--
-- แล้ววนได้เป็นวง:
--   1. ลูกหนี้ปลอมก้อนนั้น **ดัน cap ของค่าเผื่อขึ้น** (ค่าเผื่อ ≤ ลูกหนี้รวม)
--   2. ตั้งค่าเผื่อ 30,000 ได้
--   3. ตัดหนี้สูญ (Dr 1290 / Cr 1220) → นับเป็น **ยอดตัดหนี้สูญสะสม**
--   4. → เพดานของ 4320 สูงขึ้น → รับคืนได้อีก → กลับข้อ 1
--   ผลที่ผู้ตรวจวัดได้: **4 รอบ → 4320 = 150,000** จากหนี้จริง 30,000
--   เงินเข้าจริง 30,000 · ผ่านทุกด่าน งบดุลสะอาด ไม่มีอะไรฟ้อง
--
-- สมมติฐานที่หัว 20261010000001 เขียนว่า "ไม่มีใบชนิดใดทำให้รับคืน > ยอดที่ตัด
--   ได้เอง" **จึงไม่จริง** — ใบรับคืนเองสร้างฐานให้ตัดหนี้สูญรอบใหม่ได้
--   (คอมเมนต์นั้นถูกแก้ในไฟล์ migration แล้ว)
--
-- ------------------------------------------------------------
-- สองชั้นที่ปิด และทำไมต้องสองชั้น
-- ------------------------------------------------------------
--   ชั้นที่ 1 · **ตารางกฎ** ถอด `accrualCoa` ของหมวดนี้ออก (src/lib/rules/tx-rules.ts
--     + seed ของ txn_types) → ด่านระดับบรรทัดเดิมปฏิเสธบรรทัด 1220 ของหมวดนี้เอง
--   ชั้นที่ 2 · **ด่านใหม่ที่ไม่พึ่งตารางกฎ** (ไฟล์นี้ทดสอบ): ใบที่รับรู้รายได้
--     4320 ต้องมีขาตรงข้ามเป็น **เงินสดเข้าจริง (11xx)** เท่านั้น
--
--   ชั้นที่ 2 จำเป็นเพราะ "กฎที่พึ่งตารางกฎอย่างเดียว" หายไปได้เงียบๆ สองทาง:
--   มีคนเติม `accrualCoa` กลับ (รีวิวหลุด) หรือ DB ถือ seed รุ่นเก่าอยู่
--   N3 จึง **จำลองการถอยกลับของตารางกฎ** (ใส่ accrual_coa_code = '1220' กลับ
--   ในธุรกรรมของเทสต์) แล้วพิสูจน์ว่าวงปั๊มยังพังที่รอบแรกทุกรอบ
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ rollback ปิดท้าย — ไม่ทิ้งรายการเงินไว้
--   และไม่ทิ้งตารางกฎที่ถูกแก้ไว้ (N3 คืนค่าเองด้วย ไม่พึ่ง rollback อย่างเดียว)
--
-- mutation ที่ต้องทำให้เทสต์แดง (ถ้าไม่แดง = เทสต์ยังไม่ครอบ)
--   S1 คืน `accrualCoa: "1220"` ให้หมวดรับคืน (ตารางกฎ + seed)
--        → N0 แดง (txn_types ยังถือ 1220) · N1 N2 แดง (ใบ Dr 1220 ผ่านชั้นที่ 1)
--   S2 ถอดด่านใหม่ของไฟล์นี้ (ไม่เรียก fn_assert_recovery_no_receivable)
--        → N0 แดง (ไม่มีฟังก์ชัน/trigger) · **N3 แดง** (วงปั๊มเดินได้อีกเมื่อตารางกฎถอย)
--   S3 ถอด cap เดิมของ 4320 (20261010000001)
--        → N4 แดง (รับคืนโดยไม่เคยตัดหนี้สูญผ่าน) · และ R1 ของ zz_recovery_cap_test แดง
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures (แพทเทิร์นเดียวกับ zz_recovery_cap_test · ชื่อ/ไอดีไม่ชนกัน)
-- ------------------------------------------------------------
create temporary table t_rnuid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_rnuid(label) values ('rn_mgmt');
insert into auth.users(id) select id from t_rnuid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select id, label || '@no-accrual.local', label, 'management', true from t_rnuid;
insert into sri_os.user_owner_access(user_id, owner_id)
select (select id from t_rnuid where label = 'rn_mgmt'), o.id from sri_os.owners o;

create or replace function pg_temp.fuid(p_label text) returns uuid
language sql stable as $fn$ select id from t_rnuid where label = p_label $fn$;

create or replace function pg_temp.coa(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.chart_of_accounts where code = p_code $fn$;

create or replace function pg_temp.own(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.owners where code = p_code $fn$;

insert into sri_os.contacts(id, first_name, types)
values ('00000000-0000-0000-0000-0000000ac703', 'ลูกหนี้ RN', array['tenant'])
on conflict do nothing;

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
select x.id, pg_temp.own(x.own), x.bank, x.nm, x.nm
  from (values
    ('00000000-0000-0000-0000-0000000dd001'::uuid, 'SUTEE',     'BBL',   'RN สุธี'),
    ('00000000-0000-0000-0000-0000000dd002'::uuid, 'THANAKORN', 'KBANK', 'RN ธนากร'),
    ('00000000-0000-0000-0000-0000000dd003'::uuid, 'THANAWIN',  'SCB',   'RN ธนวินท์'),
    ('00000000-0000-0000-0000-0000000dd004'::uuid, 'SUDJIT',    'KTB',   'RN สุดจิตต์'),
    ('00000000-0000-0000-0000-0000000dd005'::uuid, 'BENJAPORN', 'TTB',   'RN เบ็ญจพร')
  ) as x(id, own, bank, nm);

-- ------------------------------------------------------------
-- ตัวช่วย
-- ------------------------------------------------------------
create or replace function pg_temp.must_fail_like(p_label text, p_sql text, p_needle text) returns void
language plpgsql as $fn$
declare v text;
begin
  begin
    execute p_sql;
    raise exception 'RN_UNEXPECTED_SUCCESS';
  exception when others then
    v := sqlerrm;
    if v = 'RN_UNEXPECTED_SUCCESS' then
      raise exception 'FAIL: % — คำสั่งควรถูกปฏิเสธแต่สำเร็จ', p_label;
    end if;
    if v like 'FAIL:%' then raise; end if;
    if position(p_needle in v) = 0 then
      raise exception 'FAIL: % — ปฏิเสธถูกแต่ข้อความไม่มี "%" · ได้: %', p_label, p_needle, v;
    end if;
  end;
end $fn$;

/** ปฏิเสธถูก แต่ข้อความ **ต้องไม่มี** คำที่ชี้ทางแก้ของอีกสาขา */
create or replace function pg_temp.must_fail_without(p_label text, p_sql text, p_needle text) returns void
language plpgsql as $fn$
declare v text;
begin
  begin
    execute p_sql;
    raise exception 'RN_UNEXPECTED_SUCCESS';
  exception when others then
    v := sqlerrm;
    if v = 'RN_UNEXPECTED_SUCCESS' then
      raise exception 'FAIL: % — คำสั่งควรถูกปฏิเสธแต่สำเร็จ', p_label;
    end if;
    if v like 'FAIL:%' then raise; end if;
    if position(p_needle in v) > 0 then
      raise exception 'FAIL: % — ข้อความยังชี้ทางแก้ของอีกสถานการณ์ด้วยคำว่า "%" · ได้: %', p_label, p_needle, v;
    end if;
  end;
end $fn$;

create or replace function pg_temp.must_pass(p_label text, p_sql text) returns void
language plpgsql as $fn$
begin
  execute p_sql;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: % — เส้นทางที่ถูกต้องถูกปฏิเสธ (กันแน่นเกิน): %', p_label, sqlerrm;
end $fn$;

create or replace function pg_temp.fire() returns void
language plpgsql as $fn$
begin
  set constraints all immediate;
  set constraints all deferred;
end $fn$;

create or replace function pg_temp.upd(p_sql text) returns void
language plpgsql as $fn$
begin
  execute p_sql;
  perform pg_temp.fire();
end $fn$;

create or replace function pg_temp.mk(p_id uuid, p_owner text, p_type text,
                                      p_cash date, p_lines jsonb) returns uuid
language plpgsql as $fn$
declare r jsonb;
begin
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, cash_date, memo,
                                  attachments, contact_id)
  values (p_id, pg_temp.own(p_owner), p_type, current_date, p_cash, 'RN ' || p_id::text,
          array['รายงานอายุลูกหนี้.pdf'], '00000000-0000-0000-0000-0000000ac703');
  for r in select * from jsonb_array_elements(p_lines) loop
    insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id,
                                         debit, credit, cf_category, memo)
    values (p_id, pg_temp.coa(r ->> 'coa'), (r ->> 'bank')::uuid,
            coalesce((r ->> 'dr')::numeric, 0), coalesce((r ->> 'cr')::numeric, 0),
            coalesce(r ->> 'cf', 'none')::sri_os.cf_group, 'RN บรรทัด');
  end loop;
  perform pg_temp.fire();
  return p_id;
end $fn$;

create or replace function pg_temp.bank(p_owner text) returns uuid
language sql stable as $fn$
  select id from sri_os.bank_accounts where owner_id = pg_temp.own(p_owner) and display_name like 'RN %'
$fn$;

-- ตั้งลูกหนี้ค่าเช่าค้างรับ (Dr 1200 / Cr 4200) — ลูกหนี้ **จริง** ที่มาจากรายได้
create or replace function pg_temp.mk_recv(p_id uuid, p_owner text, p_amt numeric) returns uuid
language sql as $fn$
  select pg_temp.mk(p_id, p_owner, 'inc.rent', null,
    jsonb_build_array(jsonb_build_object('coa', '1200', 'dr', p_amt, 'cr', 0),
                      jsonb_build_object('coa', '4200', 'dr', 0, 'cr', p_amt)))
$fn$;

create or replace function pg_temp.mk_allow(p_id uuid, p_owner text, p_amt numeric) returns uuid
language sql as $fn$
  select pg_temp.mk(p_id, p_owner, 'adj.doubtful', null,
    jsonb_build_array(jsonb_build_object('coa', '5920', 'dr', p_amt, 'cr', 0),
                      jsonb_build_object('coa', '1290', 'dr', 0, 'cr', p_amt)))
$fn$;

-- ตัดหนี้สูญค่าเช่า (Dr 1290 / Cr 1200)
create or replace function pg_temp.mk_writeoff(p_id uuid, p_owner text, p_amt numeric) returns uuid
language sql as $fn$
  select pg_temp.mk(p_id, p_owner, 'adj.writeoff_rent', null,
    jsonb_build_array(jsonb_build_object('coa', '1290', 'dr', p_amt, 'cr', 0),
                      jsonb_build_object('coa', '1200', 'dr', 0, 'cr', p_amt)))
$fn$;

-- ตัดหนี้สูญ **ลูกหนี้อื่น 1220** (Dr 1290 / Cr 1220) — ขั้นที่ 3 ของวงปั๊ม
create or replace function pg_temp.mk_writeoff_other(p_id uuid, p_owner text, p_amt numeric) returns uuid
language sql as $fn$
  select pg_temp.mk(p_id, p_owner, 'adj.writeoff_other', null,
    jsonb_build_array(jsonb_build_object('coa', '1290', 'dr', p_amt, 'cr', 0),
                      jsonb_build_object('coa', '1220', 'dr', 0, 'cr', p_amt)))
$fn$;

-- รับคืนหนี้สูญ **ด้วยเงินเข้าจริง** (Dr 1100 / Cr 4320) — ทางที่ถูก ต้องผ่านเสมอ
create or replace function pg_temp.mk_recovered(p_id uuid, p_owner text, p_amt numeric) returns uuid
language sql as $fn$
  select pg_temp.mk(p_id, p_owner, 'inc.bad_debt_recovered', current_date,
    jsonb_build_array(
      jsonb_build_object('coa', '1100', 'dr', p_amt, 'cr', 0, 'cf', 'operating',
                         'bank', pg_temp.bank(p_owner)),
      jsonb_build_object('coa', '4320', 'dr', 0, 'cr', p_amt)))
$fn$;

-- **ใบของช่องที่กำลังปิด** · รับคืนแบบ "ตั้งค้างรับ" (Dr 1220 / Cr 4320)
--   ไม่มีขาเงินสด → cash_date ต้องเป็น null (Money Invariant ของ 20261009000001)
create or replace function pg_temp.mk_recovered_accrued(p_id uuid, p_owner text, p_amt numeric) returns uuid
language sql as $fn$
  select pg_temp.mk(p_id, p_owner, 'inc.bad_debt_recovered', null,
    jsonb_build_array(jsonb_build_object('coa', '1220', 'dr', p_amt, 'cr', 0),
                      jsonb_build_object('coa', '4320', 'dr', 0, 'cr', p_amt)))
$fn$;

-- ---------- ตัววัด ----------
create or replace function pg_temp.net(p_owner text, p_code text, p_debit boolean) returns numeric
language sql stable as $fn$
  select coalesce(sum(case when p_debit then l.debit - l.credit else l.credit - l.debit end), 0)
    from sri_os.transactions t
    join sri_os.transaction_lines l on l.transaction_id = t.id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where t.owner_id = pg_temp.own(p_owner) and t.status <> 'void' and c.code = p_code
$fn$;

/** หนี้สูญได้รับคืนสะสม (เครดิตสุทธิ 4320) — ตัวที่ถูกปั๊มได้ */
create or replace function pg_temp.recovered(p_owner text) returns numeric
language sql stable as $fn$ select pg_temp.net(p_owner, '4320', false) $fn$;

/** ยอดตัดหนี้สูญสะสม = เดบิตสุทธิ 1290 ของใบที่แตะบัญชีลูกหนี้ (เกณฑ์เดียวกับด่าน) */
create or replace function pg_temp.writeoff(p_owner text) returns numeric
language sql stable as $fn$
  select coalesce(sum(x.net), 0) from (
    select sum(case when c.code = '1290' then l.debit - l.credit else 0 end) as net,
           bool_or(c.code in ('1200', '1210', '1220')) as touches
      from sri_os.transactions t
      join sri_os.transaction_lines l on l.transaction_id = t.id
      join sri_os.chart_of_accounts c on c.id = l.coa_id
     where t.owner_id = pg_temp.own(p_owner) and t.status <> 'void'
     group by t.id) x
   where x.touches
$fn$;

create or replace function pg_temp.pl_profit(p_owner text) returns numeric
language sql stable as $fn$
  select coalesce(sum(l.credit - l.debit), 0)
    from sri_os.transactions t
    join sri_os.transaction_lines l on l.transaction_id = t.id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where t.owner_id = pg_temp.own(p_owner) and t.status <> 'void'
     and c.type in ('income', 'expense')
$fn$;

-- ============================================================
-- N0 · โครงสร้าง — ไล่จาก catalog จริง ไม่ใช่เชื่อว่าไฟล์รันแล้ว
-- ============================================================
do $$
declare v text; v_src text; n int; v_type int; v_defer boolean; v_init boolean; v_con oid;
begin
  -- ชั้นที่ 1 · ตารางกฎใน DB ต้อง **ไม่มี** บัญชีพักของหมวดรับคืนแล้ว
  -- (ด่านระดับบรรทัดอ่านชุดบัญชีจากที่นี่ — ถ้า DB ยังถือ 1220 ช่องยังเปิดอยู่จริง)
  select accrual_coa_code into v from sri_os.txn_types where code = 'inc.bad_debt_recovered';
  if v is not null then
    raise exception 'FAIL: N0 txn_types.accrual_coa_code ของ inc.bad_debt_recovered ยังเป็น % — รัน npm run sync:rules แล้ว apply ไฟล์ seed ก่อน ไม่งั้นด่านระดับบรรทัดยังยอมให้ลง Dr 1220 / Cr 4320', v;
  end if;
  -- คู่บัญชีของหมวดต้องไม่ถูกแตะ (ถอดบัญชีพักออก ไม่ใช่ถอดหมวด)
  if not exists (select 1 from sri_os.txn_types
                  where code = 'inc.bad_debt_recovered'
                    and dr_coa_code = '1100' and cr_coa_code = '4320' and can_accrue = false) then
    raise exception 'FAIL: N0 หมวด inc.bad_debt_recovered ต้องยังเป็น Dr 1100 / Cr 4320 และ can_accrue = false';
  end if;

  -- ชั้นที่ 2 · ด่านใหม่ต้องเป็นฟังก์ชันของตัวเอง ตัวเดียว (ถอด/แก้ทีละข้อได้ · รายงานเรียกแยกได้)
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_assert_recovery_no_receivable';
  if n <> 1 then
    raise exception 'FAIL: N0 ต้องมี sri_os.fn_assert_recovery_no_receivable ตัวเดียว (ได้ %) — ไม่มีด่านนี้ = ตารางกฎถอยกลับแล้วช่องปั๊มรายได้เปิดอีกโดยไม่มีอะไรฟ้อง', n;
  end if;

  select p.prosrc into v_src from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_recovery_no_receivable_guard';
  if v_src is null or v_src not like '%fn_assert_recovery_no_receivable%' then
    raise exception 'FAIL: N0 ไม่มี trigger function fn_recovery_no_receivable_guard ที่เรียกด่านใหม่';
  end if;
  -- **ห้ามถาม "มีแถวนี้ไหม" ด้วย ROW IS NOT NULL** (บทเรียนรูที่ 2 ของ D-105)
  if v_src ~* '\m(new|old)\s+is\s+(not\s+)?null\M' then
    raise exception 'FAIL: N0 fn_recovery_no_receivable_guard ใช้ "row is [not] null" ถามว่ามีแถวไหม — เป็นจริงเฉพาะเมื่อทุกคอลัมน์ไม่เป็น null ต้องใช้ tg_op';
  end if;

  -- ต้องผูกทั้งฝั่งบรรทัดและฝั่งหัวรายการ (UPDATE status/owner ไม่แตะบรรทัดเลย)
  foreach v in array array['transaction_lines|trg_lines_recovery_no_receivable',
                           'transactions|trg_txn_recovery_no_receivable'] loop
    select t.tgtype, t.tgdeferrable, t.tginitdeferred, t.tgconstraint
      into v_type, v_defer, v_init, v_con
      from pg_trigger t
     where t.tgrelid = ('sri_os.' || split_part(v, '|', 1))::regclass
       and t.tgname = split_part(v, '|', 2);
    if v_type is null then
      raise exception 'FAIL: N0 ไม่มี trigger %', v;
    end if;
    if not (v_defer and v_init and v_con <> 0) then
      raise exception 'FAIL: N0 ด่าน % ไม่ใช่ constraint trigger (deferrable initially deferred) — ใบทั้งใบต้องเขียนเสร็จก่อนจึงตัดสินได้', v;
    end if;
    if (v_type & 2) <> 0 then
      raise exception 'FAIL: N0 ด่าน % เป็น BEFORE ต้องเป็น AFTER', v;
    end if;
  end loop;

  -- **ของเดิมห้ามหาย** (บทเรียน D-104: create or replace ของไฟล์ทีหลังลบกติกาเดิมได้เงียบๆ)
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_assert_recovery_within_writeoff';
  if n <> 1 then
    raise exception 'FAIL: N0 cap เดิมของ 4320 (fn_assert_recovery_within_writeoff) หายไป';
  end if;
  for v in select unnest(array['fn_allowance_guard', 'fn_txn_allowance_guard']) loop
    select p.prosrc into v_src from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'sri_os' and p.proname = v;
    if v_src not like '%fn_assert_recovery_within_writeoff%'
       or v_src not like '%fn_assert_allowance_limits%' then
      raise exception 'FAIL: N0 % ไม่เรียกด่านเดิมครบแล้ว — ไฟล์ใหม่เขียนทับของเดิม', v;
    end if;
  end loop;

  -- กฎเงินห้ามขึ้นกับสิทธิ์
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.proname in ('fn_assert_recovery_no_receivable', 'fn_recovery_no_receivable_guard')
     and p.prosrc like '%fn_can%';
  if n > 0 then
    raise exception 'FAIL: N0 ด่านใหม่เรียกฟังก์ชันตรวจสิทธิ์ — กฎเงินต้องปิดไม่ได้จากหน้า Settings';
  end if;

  raise notice 'ok N0 · ตารางกฎใน DB ไม่มีบัญชีพักของหมวดรับคืนแล้ว · ด่านใหม่ติดทั้งสองฝั่งเป็น constraint trigger · ด่านเดิมยังอยู่ครบ';
end $$;

-- ============================================================
-- N1 · **เคสของ P1 ตรงๆ** · ลงใบ Dr 1220 / Cr 4320 ของหมวดรับคืน → ปฏิเสธ
--      (ชั้นที่ 1 เป็นคนพูด: บรรทัด 1220 ไม่อยู่ในชุดบัญชีของหมวดนี้อีกแล้ว)
-- ============================================================
do $$
declare
  v uuid := '00000000-0000-0000-0000-0000000a7001';
  -- **ยอดตั้งต้นไม่ใช่ศูนย์** — ไฟล์เทสต์ก่อนหน้าบางไฟล์ commit รายการไว้จริง
  -- (สุธีมีลูกหนี้อื่นค้างอยู่ก่อนแล้ว) → เทียบ **ส่วนต่าง** ไม่ใช่ค่าสัมบูรณ์
  -- ไม่งั้นเทสต์จะแดงเพราะข้อมูลของไฟล์อื่น ไม่ใช่เพราะกฎที่กำลังตรวจ
  v_b1220 numeric := pg_temp.net('SUDJIT', '1220', true);
  v_brec  numeric := pg_temp.recovered('SUDJIT');
begin
  perform pg_temp.must_fail_like('N1 ตั้งค้างรับของหนี้สูญได้รับคืน 30,000 (Dr 1220 / Cr 4320)', format(
    $q$ select pg_temp.mk_recovered_accrued(%L, 'SUDJIT', 30000) $q$, v),
    'ตารางกฎระบุบัญชีของหมวดนี้ไว้เฉพาะ');

  if exists (select 1 from sri_os.transactions where id = v) then
    raise exception 'FAIL: N1 ใบที่ถูกปฏิเสธยังค้างอยู่ในสมุด';
  end if;
  if pg_temp.net('SUDJIT', '1220', true) <> v_b1220 or pg_temp.recovered('SUDJIT') <> v_brec then
    raise exception 'FAIL: N1 ยอดขยับหลังเคสที่ถูกปฏิเสธ: ลูกหนี้อื่น % (เดิม %) · รับคืน % (เดิม %)',
      pg_temp.net('SUDJIT', '1220', true), v_b1220, pg_temp.recovered('SUDJIT'), v_brec;
  end if;
  raise notice 'ok N1 · ใบ Dr 1220 / Cr 4320 ของหมวดหนี้สูญได้รับคืนถูกปฏิเสธ (ปลุกลูกหนี้ที่ตัดไปแล้วไม่ได้)';
end $$;

-- ============================================================
-- N2 · **ลูปที่ผู้ตรวจใช้** · ตั้งลูกหนี้ 30k · ค่าเผื่อ 30k · ตัดหนี้สูญ 30k
--      แล้ววน 2 รอบ → ต้องพังที่ **รอบแรกที่พยายามปลุกลูกหนี้**
--      และ 4320 สะสมต้องไม่เกิน 30,000 (ของเดิม: 2 รอบ = 90,000 · 4 รอบ = 150,000)
-- ============================================================
do $$
declare
  i int; v_pl numeric;
  -- ยอดตั้งต้นของสุธีไม่ใช่ศูนย์ (ไฟล์เทสต์ก่อนหน้า commit ไว้) → เทียบส่วนต่าง
  v_b1200 numeric := pg_temp.net('SUTEE', '1200', true);
  v_b1220 numeric := pg_temp.net('SUTEE', '1220', true);
  v_brec  numeric := pg_temp.recovered('SUTEE');
  v_bwo   numeric := pg_temp.writeoff('SUTEE');
begin
  perform pg_temp.must_pass('N2 ตั้งลูกหนี้ค่าเช่าค้างรับของสุธี 30,000', format(
    $q$ select pg_temp.mk_recv('00000000-0000-0000-0000-0000000a7010', 'SUTEE', 30000) $q$));
  perform pg_temp.must_pass('N2 ตั้งค่าเผื่อ 30,000', format(
    $q$ select pg_temp.mk_allow('00000000-0000-0000-0000-0000000a7011', 'SUTEE', 30000) $q$));
  perform pg_temp.must_pass('N2 ตัดหนี้สูญ 30,000', format(
    $q$ select pg_temp.mk_writeoff('00000000-0000-0000-0000-0000000a7012', 'SUTEE', 30000) $q$));

  if pg_temp.writeoff('SUTEE') <> v_bwo + 30000 then
    raise exception 'FAIL: N2 สภาพตั้งต้นเพี้ยน: ยอดตัดหนี้สูญควรเพิ่ม 30000 จาก % ได้ %',
      v_bwo, pg_temp.writeoff('SUTEE');
  end if;

  for i in 1..2 loop
    -- ขั้นที่ 1 ของวงปั๊ม — **ต้องพังที่นี่ทุกรอบ**
    perform pg_temp.must_fail_like(format('N2 รอบที่ %s ขั้นที่ 1 · ปลุกลูกหนี้ด้วยใบรับคืนแบบตั้งค้าง', i), format(
      $q$ select pg_temp.mk_recovered_accrued('00000000-0000-0000-0000-000000a71%s0'::uuid, 'SUTEE', 30000) $q$,
      lpad(i::text, 2, '0')),
      'ตารางกฎระบุบัญชีของหมวดนี้ไว้เฉพาะ');

    -- ขั้นที่ 2 ของวงปั๊ม — ไม่มีลูกหนี้ปลอมแล้ว จึงตั้งค่าเผื่อรอบใหม่ไม่ได้ด้วย
    perform pg_temp.must_fail_like(format('N2 รอบที่ %s ขั้นที่ 2 · ตั้งค่าเผื่อ 30,000 โดยไม่มีลูกหนี้', i), format(
      $q$ select pg_temp.mk_allow('00000000-0000-0000-0000-000000a72%s0'::uuid, 'SUTEE', 30000) $q$,
      lpad(i::text, 2, '0')),
      'มากกว่ายอดลูกหนี้รวม');

    -- ขั้นที่ 3 ของวงปั๊ม — ตัดหนี้สูญ 1220 ที่ไม่มีอยู่ → ลูกหนี้ติดลบ/ค่าเผื่อติดลบ
    perform pg_temp.must_fail_like(format('N2 รอบที่ %s ขั้นที่ 3 · ตัดหนี้สูญลูกหนี้อื่นที่ไม่มีอยู่', i), format(
      $q$ select pg_temp.mk_writeoff_other('00000000-0000-0000-0000-000000a73%s0'::uuid, 'SUTEE', 30000) $q$,
      lpad(i::text, 2, '0')),
      'ค่าเผื่อหนี้สงสัยจะสูญ');

    -- เพดานห้ามขยับเลยในทุกรอบ (นี่คือ invariant ที่ถูกละเมิด)
    if pg_temp.writeoff('SUTEE') <> v_bwo + 30000 then
      raise exception 'FAIL: N2 รอบที่ % ดันยอดตัดหนี้สูญสะสมขึ้นเป็น % (ควรคงที่ที่ %) — เพดานของ 4320 ถูกปั๊มได้',
        i, pg_temp.writeoff('SUTEE'), v_bwo + 30000;
    end if;
    if pg_temp.net('SUTEE', '1220', true) <> v_b1220 then
      raise exception 'FAIL: N2 รอบที่ % มีลูกหนี้อื่นโผล่มา % (เดิม %) — ใบรับคืนปลุกลูกหนี้ได้',
        i, pg_temp.net('SUTEE', '1220', true), v_b1220;
    end if;
  end loop;

  -- **ห้ามกันแน่นเกิน**: รับคืนด้วยเงินสดตามปกติยังผ่าน และได้เท่าที่ตัดไปจริง
  v_pl := pg_temp.pl_profit('SUTEE');
  perform pg_temp.must_pass('N2 รับคืนด้วยเงินเข้าจริง 30,000 (Dr 1100 / Cr 4320)', format(
    $q$ select pg_temp.mk_recovered('00000000-0000-0000-0000-0000000a7013', 'SUTEE', 30000) $q$));
  if pg_temp.pl_profit('SUTEE') <> v_pl + 30000 then
    raise exception 'FAIL: N2 กำไรควรเพิ่ม 30000 ตามเงินที่เก็บได้จริง ได้ %',
      pg_temp.pl_profit('SUTEE') - v_pl;
  end if;

  -- แล้วเกินอีกบาทเดียวไม่ได้ (cap เดิมของ 20261010000001 ต้องไม่หาย)
  perform pg_temp.must_fail_like('N2 รับคืนอีก 1 บาทหลังรับคืนครบยอดที่ตัดไป', format(
    $q$ select pg_temp.mk_recovered('00000000-0000-0000-0000-0000000a7014', 'SUTEE', 1) $q$),
    'หมวดนี้ใช้ได้เฉพาะหนี้ที่ถูกตัดหนี้สูญไปแล้ว');

  if pg_temp.recovered('SUTEE') <> v_brec + 30000
     or pg_temp.recovered('SUTEE') > pg_temp.writeoff('SUTEE') then
    raise exception 'FAIL: N2 รับคืนสะสมต้องเพิ่มแค่ 30000 จาก % และไม่เกินยอดที่ตัด (%) ได้ %',
      v_brec, pg_temp.writeoff('SUTEE'), pg_temp.recovered('SUTEE');
  end if;
  -- ลูกหนี้ของรอบนี้ถูกตัดไปแล้ว และใบรับคืนไม่ได้ปลุกกลับมา → กลับเท่ายอดตั้งต้น
  if pg_temp.net('SUTEE', '1200', true) <> v_b1200 or pg_temp.net('SUTEE', '1220', true) <> v_b1220 then
    raise exception 'FAIL: N2 ลูกหนี้เหลือค้างเกินยอดตั้งต้น: 1200 = % (เดิม %) · 1220 = % (เดิม %)',
      pg_temp.net('SUTEE', '1200', true), v_b1200, pg_temp.net('SUTEE', '1220', true), v_b1220;
  end if;

  raise notice 'ok N2 · ลูปของผู้ตรวจพังที่รอบแรกที่พยายามปลุกลูกหนี้ · 4320 สะสม = 30000 เท่าเงินที่เข้าจริง · ทางที่ถูกยังลงได้';
end $$;

-- ============================================================
-- N3 · **ชั้นที่ 2 · S2** · จำลอง "ตารางกฎถอยกลับ" (accrual_coa_code = '1220')
--      แล้วเดินลูปของผู้ตรวจ **4 รอบ** เต็มรูปแบบ
--      → ต้องพังที่ขั้นที่ 1 ทุกรอบด้วยด่านใหม่ (ไม่ใช่ด่าน cap)
--      → 4320 สะสมต้องไม่ถึง 150,000 ที่ผู้ตรวจวัดได้
--
--      cap เดิม **ยอมให้ผ่าน** ในรอบแรก (รับคืน 30,000 ≤ ยอดที่ตัด 30,000)
--      จึงเป็นเคสที่ **มีแต่ด่านใหม่เท่านั้นที่กันได้** (ถอดด่านใหม่ → แดงที่นี่)
-- ============================================================
do $$
declare
  i int; v_rec numeric;
  -- เทียบส่วนต่างจากยอดตั้งต้น (ไฟล์เทสต์ก่อนหน้า commit รายการของผู้ถือรายนี้ไว้ได้)
  v_b1220 numeric := pg_temp.net('THANAKORN', '1220', true);
  v_brec  numeric := pg_temp.recovered('THANAKORN');
  v_bwo   numeric := pg_temp.writeoff('THANAKORN');
begin
  perform pg_temp.must_pass('N3 ตั้งลูกหนี้ของธนากร 30,000', format(
    $q$ select pg_temp.mk_recv('00000000-0000-0000-0000-0000000a7020', 'THANAKORN', 30000) $q$));
  perform pg_temp.must_pass('N3 ตั้งค่าเผื่อ 30,000', format(
    $q$ select pg_temp.mk_allow('00000000-0000-0000-0000-0000000a7021', 'THANAKORN', 30000) $q$));
  perform pg_temp.must_pass('N3 ตัดหนี้สูญ 30,000', format(
    $q$ select pg_temp.mk_writeoff('00000000-0000-0000-0000-0000000a7022', 'THANAKORN', 30000) $q$));

  -- ตารางกฎถอยกลับ: ด่านระดับบรรทัดจะยอมให้ลงบรรทัด 1220 ของหมวดรับคืนอีกครั้ง
  --
  -- **ถอยกลับให้ครบทุกช่องโดยตั้งใจ** (D-107): ตั้งแต่ 20261010000003 มีด่าน
  --   `trg_lines_rule_coa_accrual` ที่ปฏิเสธบรรทัด `accrual_coa_code` ของหมวดที่
  --   `can_accrue = false` ตั้งแต่ชั้นแรก · ถ้าถอยกลับแค่ช่อง accrual ด่านนั้นจะเป็น
  --   คนปฏิเสธ แล้วเคสนี้จะ **ไม่ได้ทดสอบชั้นที่ 2 อีกเลย** (เขียวด้วยเหตุผลผิด)
  --   → ใส่ 1220 ไว้ในช่อง gain ด้วย ซึ่งเป็นช่องที่ด่านชั้นแรกยอมตามตารางกฎเสมอ
  --     (ด่านชั้นแรกต้องไม่กันแน่นเกินกับ gain/loss/interest) · ชั้นที่ 2 จึงเป็น
  --     คนพูด และข้อความที่เคสนี้ตรวจยังเป็นของด่านที่ **ไม่พึ่งตารางกฎเลย**
  update sri_os.txn_types
     set accrual_coa_code = '1220', gain_coa_code = '1220', loss_coa_code = '5910'
   where code = 'inc.bad_debt_recovered';
  perform pg_temp.fire();

  for i in 1..4 loop
    perform pg_temp.must_fail_like(format('N3 รอบที่ %s · ปลุกลูกหนี้ด้วยใบรับคืนแบบตั้งค้าง (ตารางกฎถอยกลับแล้ว)', i), format(
      $q$ select pg_temp.mk_recovered_accrued('00000000-0000-0000-0000-000000a74%s0'::uuid, 'THANAKORN', 30000) $q$,
      lpad(i::text, 2, '0')),
      'รับรู้ได้เฉพาะเงินที่เข้าบัญชีจริง');

    -- ข้อความต้องเป็นของด่านใหม่ ไม่ใช่สาขา cap ซึ่งชี้ทางแก้ตรงข้าม
    -- ("ไปตัดหนี้สูญเพิ่มก่อน" = ชวนให้เดินวงปั๊มต่อ ซึ่งแย่กว่าไม่บอกอะไรเลย)
    perform pg_temp.must_fail_without(format('N3 รอบที่ %s · ข้อความห้ามชวนไปตัดหนี้สูญเพิ่ม', i), format(
      $q$ select pg_temp.mk_recovered_accrued('00000000-0000-0000-0000-000000a75%s0'::uuid, 'THANAKORN', 30000) $q$,
      lpad(i::text, 2, '0')),
      'ให้ตั้งค่าเผื่อแล้วตัดหนี้สูญก่อน');

    if pg_temp.net('THANAKORN', '1220', true) <> v_b1220
       or pg_temp.writeoff('THANAKORN') <> v_bwo + 30000 then
      raise exception 'FAIL: N3 รอบที่ % เพดานขยับ: ลูกหนี้อื่น % (เดิม %) · ยอดตัดหนี้สูญ % (ควร %)',
        i, pg_temp.net('THANAKORN', '1220', true), v_b1220,
        pg_temp.writeoff('THANAKORN'), v_bwo + 30000;
    end if;
  end loop;

  v_rec := pg_temp.recovered('THANAKORN');
  if v_rec <> v_brec then
    raise exception 'FAIL: N3 เดิน 4 รอบแล้วรับคืนสะสมขยับจาก % เป็น % (ผู้ตรวจวัดได้ 150,000 จากหนี้จริง 30,000) ต้องไม่ขยับเลย',
      v_brec, v_rec;
  end if;

  -- **ห้ามกันแน่นเกิน** — แม้ตารางกฎยอมให้บรรทัด 1220 ลงได้ ใบที่เงินเข้าจริงยังต้องผ่าน
  perform pg_temp.must_pass('N3 รับคืนด้วยเงินเข้าจริง 30,000 ขณะตารางกฎยังถอยกลับอยู่', format(
    $q$ select pg_temp.mk_recovered('00000000-0000-0000-0000-0000000a7023', 'THANAKORN', 30000) $q$));
  if pg_temp.recovered('THANAKORN') <> v_brec + 30000 then
    raise exception 'FAIL: N3 รับคืนด้วยเงินจริงควรเพิ่ม 30000 จาก % ได้ %',
      v_brec, pg_temp.recovered('THANAKORN');
  end if;

  -- คืนตารางกฎเอง ไม่พึ่ง rollback อย่างเดียว (เคสที่เหลือต้องเห็นกฎจริงของรีโป)
  update sri_os.txn_types
     set accrual_coa_code = null, gain_coa_code = null, loss_coa_code = null
   where code = 'inc.bad_debt_recovered';
  perform pg_temp.fire();

  raise notice 'ok N3 · ตารางกฎถอยกลับแล้ววงปั๊มยังพังทุกรอบด้วยด่านที่ไม่พึ่งตารางกฎ · 4 รอบได้ 0 ไม่ใช่ 150000';
end $$;

-- ============================================================
-- N4 · ของเดิมต้องไม่หาย (S3) · รับคืนโดยไม่เคยตัดหนี้สูญเลย → ปฏิเสธด้วย cap เดิม
-- ============================================================
do $$
declare v_brec numeric := pg_temp.recovered('BENJAPORN');
begin
  perform pg_temp.must_fail_like('N4 เบ็ญจพรรับคืน 1,000 โดยไม่เคยตัดหนี้สูญ', format(
    $q$ select pg_temp.mk_recovered('00000000-0000-0000-0000-0000000a7030', 'BENJAPORN', 1000) $q$),
    'หมวดนี้ใช้ได้เฉพาะหนี้ที่ถูกตัดหนี้สูญไปแล้ว');
  if pg_temp.recovered('BENJAPORN') <> v_brec then
    raise exception 'FAIL: N4 ยอดรับคืนของเบ็ญจพรขยับจาก % เป็น % — ใบที่ถูกปฏิเสธมีผล',
      v_brec, pg_temp.recovered('BENJAPORN');
  end if;
  raise notice 'ok N4 · cap เดิมของ 4320 ยังทำงาน (ด่านใหม่ไม่ได้ไปแทนที่ของเดิม)';
end $$;

-- ============================================================
-- N5 · เส้นทางที่ถูกต้องรอบใบรับคืน ต้องยังทำได้ครบ (ด่านใหม่ยิงเฉพาะใบที่เสียรูป)
--      void ใบรับคืน → ต้องผ่าน (ด่านใหม่ต้องข้ามใบที่ void ไม่ใช่ตัดสินจากบรรทัด)
-- ============================================================
do $$
declare
  v_brec_tk numeric := pg_temp.recovered('THANAKORN') - 30000;  -- ยอดก่อนใบรับคืนของ N3
  v_brec_tw numeric := pg_temp.recovered('THANAWIN');
begin
  perform pg_temp.must_pass('N5 void ใบรับคืนของธนากร',
    $q$ select pg_temp.upd($i$ update sri_os.transactions set status = 'void'
            where id = '00000000-0000-0000-0000-0000000a7023' $i$) $q$);
  if pg_temp.recovered('THANAKORN') <> v_brec_tk then
    raise exception 'FAIL: N5 หลัง void ใบรับคืน ยอดรับคืนควรกลับเป็น % ได้ %',
      v_brec_tk, pg_temp.recovered('THANAKORN');
  end if;

  -- ตัดหนี้สูญ (เดบิต 1290 คู่กับเครดิตลูกหนี้) ไม่ใช่ใบรับคืน ด่านใหม่ต้องไม่แตะ
  perform pg_temp.must_pass('N5 ตั้งลูกหนี้ + ค่าเผื่อ + ตัดหนี้สูญของธนวินท์ ตามปกติ', format(
    $q$ select pg_temp.mk_recv('00000000-0000-0000-0000-0000000a7040', 'THANAWIN', 8000),
               pg_temp.mk_allow('00000000-0000-0000-0000-0000000a7041', 'THANAWIN', 8000),
               pg_temp.mk_writeoff('00000000-0000-0000-0000-0000000a7042', 'THANAWIN', 8000) $q$));
  perform pg_temp.must_pass('N5 แล้วรับคืนด้วยเงินจริง 8,000', format(
    $q$ select pg_temp.mk_recovered('00000000-0000-0000-0000-0000000a7043', 'THANAWIN', 8000) $q$));
  if pg_temp.recovered('THANAWIN') <> v_brec_tw + 8000 then
    raise exception 'FAIL: N5 รับคืนของธนวินท์ควรเพิ่ม 8000 จาก % ได้ %',
      v_brec_tw, pg_temp.recovered('THANAWIN');
  end if;
  raise notice 'ok N5 · void/ตัดหนี้สูญ/รับคืนด้วยเงินจริง ยังทำได้ครบ';
end $$;

-- ============================================================
-- N6 · กฎเงินต้องไม่ขึ้นกับสิทธิ์ — เดินเส้นทางสำคัญซ้ำด้วย role authenticated
-- ============================================================
do $$
begin
  perform set_config('test.uid', pg_temp.fuid('rn_mgmt')::text, true);
  execute 'set local role authenticated';

  perform pg_temp.must_fail_like('N6 ตั้งค้างรับของหนี้สูญได้รับคืน (authenticated)', format(
    $q$ select pg_temp.mk_recovered_accrued('00000000-0000-0000-0000-0000000a7050', 'THANAWIN', 100) $q$),
    'ตารางกฎระบุบัญชีของหมวดนี้ไว้เฉพาะ');

  execute 'reset role';
  raise notice 'ok N6 · ด่านทำงานกับ role authenticated ด้วย (ไม่ได้ผ่าน/ไม่ผ่านเพราะรันเป็น superuser)';
end $$;

-- ---------- สรุป: ทุกใบที่ไฟล์นี้สร้างต้องผ่านด่านที่เลื่อนไว้จริง ----------
do $$
declare n int;
begin
  set constraints all immediate;
  select count(*) into n from sri_os.transactions where memo like 'RN %';
  if n < 10 then
    raise exception 'FAIL: นับใบที่เทสต์นี้สร้างได้แค่ % ใบ — เทสต์อาจไม่ได้ลงอะไรเลย', n;
  end if;
  -- ตารางกฎต้องถูกคืนค่าแล้ว (เทสต์ไฟล์ถัดไปอ่านกฎจริงของรีโป)
  if (select accrual_coa_code from sri_os.txn_types where code = 'inc.bad_debt_recovered') is not null then
    raise exception 'FAIL: N3 ไม่ได้คืนตารางกฎ — เทสต์ไฟล์อื่นจะรันบนกฎที่ถูกแก้';
  end if;
  raise notice 'ok N · ทั้ง % ใบของไฟล์นี้ผ่านด่านที่เลื่อนไว้ (เคสปฏิเสธไม่ทิ้งใบเสียรูปไว้)', n;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: ใบที่เทสต์นี้สร้างไว้เสียรูป: %', sqlerrm;
end $$;

rollback;
