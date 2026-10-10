-- ============================================================
-- SRI OS · เทสต์ของ 20261009000004_allowance_fixes.sql
--   (ข้อ 1 · 2 · 3 · 6 ที่ผู้ตรวจ BLOCK ไว้ · ของเดิมอยู่ใน zz_allowance_test.sql)
--
-- ------------------------------------------------------------
-- ข้อ 1 · ด่าน "ค่าเผื่อห้ามเกินลูกหนี้" วางผิดที่ — ร้ายแรงสุด
-- ------------------------------------------------------------
-- ของจริงที่เกิด: ลูกหนี้ 30,000 · ตั้งค่าเผื่อ 20,000 · ลูกหนี้จ่ายมา 15,000
--   → ใบ **รับชำระ** ถูกปฏิเสธ เพราะหลังรับชำระ ค่าเผื่อ (20,000) > ลูกหนี้ (15,000)
--   → **เงินอยู่ในแบงก์แล้วแต่ลงสมุดไม่ได้** ทางที่ผู้ใช้จะทำคือลง inc.rent ใหม่
--     = **รายได้ซ้ำ** ซึ่งแย่กว่าการไม่มีด่านเลย
--
-- "ค่าเผื่อมากกว่าลูกหนี้" หลังรับชำระ **เป็นเรื่องจริงที่เกิดได้และไม่ใช่ความผิด**
--   (ตั้งเผื่อไว้แล้วลูกหนี้จ่ายมาจริง) · ทางแก้คือ **กลับค่าเผื่อ** ซึ่งผู้ใช้ทำเองได้
--   → ด่านต้องยิง **เฉพาะรายการที่ทำให้ค่าเผื่อเพิ่ม** ไม่ใช่เป็นกติกาตลอดเวลา
--
-- ------------------------------------------------------------
-- ข้อ 2 + 3 · ตัดหนี้สูญแล้วเก็บเงินคืนได้ → ลูกหนี้ติดลบ
-- ------------------------------------------------------------
-- ทางเดียวที่เคยมีคือ inv.collect_rent (Dr 1100 / Cr 1200) ซึ่งผ่านทุกด่านแล้วได้
--   `1200 = −30,000` และ P&L ไม่ขยับ = รายได้ขาดเท่ายอดที่เก็บคืนได้
--   **ไม่มีด่านไหนฟ้อง** เพราะใบสมดุลทุกบรรทัด
-- แก้สองชั้น: หมวดใหม่ `inc.bad_debt_recovered` (Dr 1100 / Cr 4320) ในตารางกฎ
--   + ด่านใหม่ "ลูกหนี้ 1200/1210/1220 ต่อผู้ถือห้ามติดลบ" ที่ DB
--   ด่านนี้คือตัวที่จะจับอาการเดิมได้ **ตั้งแต่ต้น** ถ้าวันหนึ่งมีเส้นทางอื่นโผล่มาอีก
--
-- ------------------------------------------------------------
-- ข้อ 6 · ข้อความ error ของด่าน "ค่าเผื่อติดลบ" ชี้ทางแก้ผิด
-- ------------------------------------------------------------
-- ตอน reverse/void **ใบตั้งค่าเผื่อ** ข้อความบอกให้ "ไปตั้งค่าเผื่อเพิ่ม"
--   ซึ่งทางแก้จริงคือ **กลับใบตัดหนี้สูญก่อน** → ข้อความต้องแยกตามสาเหตุที่ยิงด่าน
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ **rollback** ปิดท้าย — ไม่ทิ้งรายการเงินไว้
--   ด่านเป็น constraint trigger ที่เลื่อนไว้ → ทุกเคสยิงเองผ่าน pg_temp.fire()
--
-- mutation ที่ต้องทำให้เทสต์แดง (ถ้าไม่แดง = เทสต์ยังไม่ครอบ)
--   P1 ให้ด่านค่าเผื่อยิงใส่ทุกรายการอีก (p_cause ไม่มีผล / cap เช็คทุกครั้ง)
--        → F1 F1b F2 F6 แดง (เคสรับชำระ)
--   P2 ถอดด่าน "ลูกหนี้ห้ามติดลบ"                    → F4 F5 F5b F9 แดง
--   P3 ลบหมวด inc.bad_debt_recovered จากตารางกฎ       → F3 F4 แดง (หมวดไม่มีใน txn_types)
--   P4 เปลี่ยน inc.bad_debt_recovered ให้ cr 1200     → F3 แดง (คู่บัญชีใน txn_types)
--      และ F4 แดงที่ด่านลูกหนี้ติดลบ
--   P6b คืนข้อความเดียวของด่านค่าเผื่อติดลบ            → F7 แดง
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
create temporary table t_fuid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_fuid(label) values ('f_mgmt');
insert into auth.users(id) select id from t_fuid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select id, label || '@allowfix.local', label, 'management', true from t_fuid;
insert into sri_os.user_owner_access(user_id, owner_id)
select (select id from t_fuid where label = 'f_mgmt'), o.id from sri_os.owners o;

create or replace function pg_temp.fuid(p_label text) returns uuid
language sql stable as $fn$ select id from t_fuid where label = p_label $fn$;

create or replace function pg_temp.coa(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.chart_of_accounts where code = p_code $fn$;

create or replace function pg_temp.own(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.owners where code = p_code $fn$;

insert into sri_os.contacts(id, first_name, types)
values ('00000000-0000-0000-0000-0000000fac01', 'ลูกหนี้ AF', array['tenant'])
on conflict do nothing;

-- บัญชีธนาคารจริงต่อผู้ถือ — Money Invariant 2 บังคับว่าขาเงินสดต้องผูกบัญชี
insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
select x.id, pg_temp.own(x.own), x.bank, x.nm, x.nm
  from (values
    ('00000000-0000-0000-0000-0000000fb001'::uuid, 'THANAKORN', 'KBANK', 'AF ธนากร'),
    ('00000000-0000-0000-0000-0000000fb002'::uuid, 'SUTEE',     'BBL',   'AF สุธี'),
    ('00000000-0000-0000-0000-0000000fb003'::uuid, 'THANAWIN',  'SCB',   'AF ธนวินท์')
  ) as x(id, own, bank, nm);

-- ------------------------------------------------------------
-- ตัวช่วย (แพทเทิร์นเดียวกับ zz_allowance_test / zz_cash_date_invariant)
-- ------------------------------------------------------------
/**
 * p_needle ต้องเป็นคำที่มีอยู่ใน **ข้อความของสาขาเดียว** เท่านั้น
 *
 * บทเรียนรอบสอง: F7a เคยใช้ needle 'ตั้งค่าเผื่อ' ซึ่งตรงกับข้อความของ
 *   **ทั้งสองสาขา** ของด่านค่าเผื่อติดลบ → เทสต์เขียวทั้งที่ด่านเลือกสาขาผิด
 *   (ผู้ใช้ถูกบอกว่า "ตั้งค่าเผื่อเพิ่มไม่ช่วย" ทั้งที่ทางแก้คือตั้งค่าเผื่อเพิ่ม)
 * คำที่กว้างเกินแบบเดียวกัน: 'ติดลบ' (อยู่ในทั้งด่านค่าเผื่อและด่านลูกหนี้) ·
 *   'ตัดหนี้สูญ' (อยู่ในทั้งสองสาขา) → เปลี่ยนเป็นประโยคที่มีในสาขานั้นเท่านั้น
 * และเคสที่สาขาสำคัญให้คู่กับ must_fail_without ของอีกสาขาเสมอ
 */
create or replace function pg_temp.must_fail_like(p_label text, p_sql text, p_needle text) returns void
language plpgsql as $fn$
declare v text;
begin
  begin
    execute p_sql;
    raise exception 'AF_UNEXPECTED_SUCCESS';
  exception when others then
    v := sqlerrm;
    if v = 'AF_UNEXPECTED_SUCCESS' then
      raise exception 'FAIL: % — คำสั่งควรถูกปฏิเสธแต่สำเร็จ', p_label;
    end if;
    if v like 'FAIL:%' then raise; end if;
    if position(p_needle in v) = 0 then
      raise exception 'FAIL: % — ปฏิเสธถูกแต่ข้อความไม่มี "%" · ได้: %', p_label, p_needle, v;
    end if;
  end;
end $fn$;

/** ปฏิเสธถูก แต่ข้อความ **ต้องไม่มี** คำที่ชี้ทางแก้ผิด (ข้อ 6) */
create or replace function pg_temp.must_fail_without(p_label text, p_sql text, p_needle text) returns void
language plpgsql as $fn$
declare v text;
begin
  begin
    execute p_sql;
    raise exception 'AF_UNEXPECTED_SUCCESS';
  exception when others then
    v := sqlerrm;
    if v = 'AF_UNEXPECTED_SUCCESS' then
      raise exception 'FAIL: % — คำสั่งควรถูกปฏิเสธแต่สำเร็จ', p_label;
    end if;
    if v like 'FAIL:%' then raise; end if;
    if position(p_needle in v) > 0 then
      raise exception 'FAIL: % — ข้อความยังชี้ทางแก้ผิดด้วยคำว่า "%" · ได้: %', p_label, p_needle, v;
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

/**
 * หัวรายการ + บรรทัด ในธุรกรรมเดียวกัน (เส้นทางเดียวกับที่ fn_post_entry เขียน)
 *   p_lines = [{"coa":"1100","dr":0,"cr":5000,"cf":"operating","bank":"<uuid>"}, ...]
 * **ไม่ใส่ค่า default ให้ cash_date** โดยตั้งใจ (บทเรียนข้อ 3)
 */
create or replace function pg_temp.mk(p_id uuid, p_owner text, p_type text,
                                      p_cash date, p_lines jsonb) returns uuid
language plpgsql as $fn$
declare r jsonb;
begin
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, cash_date, memo,
                                  attachments, contact_id)
  values (p_id, pg_temp.own(p_owner), p_type, current_date, p_cash, 'AF ' || p_id::text,
          array['รายงานอายุลูกหนี้.pdf'], '00000000-0000-0000-0000-0000000fac01');
  for r in select * from jsonb_array_elements(p_lines) loop
    insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id,
                                         debit, credit, cf_category, memo)
    values (p_id, pg_temp.coa(r ->> 'coa'), (r ->> 'bank')::uuid,
            coalesce((r ->> 'dr')::numeric, 0), coalesce((r ->> 'cr')::numeric, 0),
            coalesce(r ->> 'cf', 'none')::sri_os.cf_group, 'AF บรรทัด');
  end loop;
  perform pg_temp.fire();
  return p_id;
end $fn$;

create or replace function pg_temp.bank(p_owner text) returns uuid
language sql stable as $fn$
  select id from sri_os.bank_accounts where owner_id = pg_temp.own(p_owner) and display_name like 'AF %'
$fn$;

-- ตั้งลูกหนี้ค่าเช่าค้างรับ (Dr 1200 / Cr 4200) — ไม่มีขาเงินสด
create or replace function pg_temp.mk_recv(p_id uuid, p_owner text, p_amt numeric) returns uuid
language sql as $fn$
  select pg_temp.mk(p_id, p_owner, 'inc.rent', null,
    jsonb_build_array(jsonb_build_object('coa', '1200', 'dr', p_amt, 'cr', 0),
                      jsonb_build_object('coa', '4200', 'dr', 0, 'cr', p_amt)))
$fn$;

-- ตั้งค่าเผื่อ (Dr 5920 / Cr 1290)
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

-- กลับค่าเผื่อ (Dr 1290 / Cr 5920)
create or replace function pg_temp.mk_release(p_id uuid, p_owner text, p_amt numeric) returns uuid
language sql as $fn$
  select pg_temp.mk(p_id, p_owner, 'adj.doubtful_release', null,
    jsonb_build_array(jsonb_build_object('coa', '1290', 'dr', p_amt, 'cr', 0),
                      jsonb_build_object('coa', '5920', 'dr', 0, 'cr', p_amt)))
$fn$;

-- **รับชำระค่าเช่าค้างรับ** (Dr 1100 / Cr 1200) — เงินเข้าแบงก์จริง
create or replace function pg_temp.mk_collect(p_id uuid, p_owner text, p_amt numeric) returns uuid
language sql as $fn$
  select pg_temp.mk(p_id, p_owner, 'inv.collect_rent', current_date,
    jsonb_build_array(
      jsonb_build_object('coa', '1100', 'dr', p_amt, 'cr', 0, 'cf', 'operating',
                         'bank', pg_temp.bank(p_owner)),
      jsonb_build_object('coa', '1200', 'dr', 0, 'cr', p_amt)))
$fn$;

-- **หนี้สูญได้รับคืน** (Dr 1100 / Cr 4320) — หมวดใหม่ของข้อ 2
create or replace function pg_temp.mk_recovered(p_id uuid, p_owner text, p_amt numeric) returns uuid
language sql as $fn$
  select pg_temp.mk(p_id, p_owner, 'inc.bad_debt_recovered', current_date,
    jsonb_build_array(
      jsonb_build_object('coa', '1100', 'dr', p_amt, 'cr', 0, 'cf', 'operating',
                         'bank', pg_temp.bank(p_owner)),
      jsonb_build_object('coa', '4320', 'dr', 0, 'cr', p_amt)))
$fn$;

-- ---------- ตัววัดที่งบแต่ละตัวเห็น ----------
create or replace function pg_temp.allowance(p_owner text) returns numeric
language sql stable as $fn$
  select coalesce(sum(l.credit - l.debit), 0)
    from sri_os.transactions t
    join sri_os.transaction_lines l on l.transaction_id = t.id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where t.owner_id = pg_temp.own(p_owner) and t.status <> 'void' and c.code = '1290'
$fn$;

/** ลูกหนี้ **ก่อนหักค่าเผื่อ** ของบัญชีเดียว (ตัวที่ด่านใหม่ห้ามติดลบ) */
create or replace function pg_temp.receivable(p_owner text, p_code text) returns numeric
language sql stable as $fn$
  select coalesce(sum(l.debit - l.credit), 0)
    from sri_os.transactions t
    join sri_os.transaction_lines l on l.transaction_id = t.id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where t.owner_id = pg_temp.own(p_owner) and t.status <> 'void' and c.code = p_code
$fn$;

/** กำไรขาดทุน: รายได้ − ค่าใช้จ่าย (บวก = กำไร) */
create or replace function pg_temp.pl_profit(p_owner text) returns numeric
language sql stable as $fn$
  select coalesce(sum(l.credit - l.debit), 0)
    from sri_os.transactions t
    join sri_os.transaction_lines l on l.transaction_id = t.id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where t.owner_id = pg_temp.own(p_owner) and t.status <> 'void'
     and c.type in ('income', 'expense')
$fn$;

/** เงินสดที่ **งบกระแสเงินสด** เห็น (cash_date ไม่ null) แยกตามหมวด cf */
create or replace function pg_temp.cf_cash(p_owner text, p_cf text) returns numeric
language sql stable as $fn$
  select coalesce(sum(l.debit - l.credit), 0)
    from sri_os.transactions t
    join sri_os.transaction_lines l on l.transaction_id = t.id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where t.owner_id = pg_temp.own(p_owner) and t.status <> 'void'
     and t.cash_date is not null and c.code ~ '^11[0-9][0-9]$'
     and l.cf_category::text = p_cf
$fn$;

-- ============================================================
-- F0 · โครงสร้าง — ไล่จาก catalog จริง
-- ============================================================
do $$
declare v text; v_type int; v_defer boolean; v_init boolean; v_con oid; n int;
begin
  -- ด่านทั้งสองยังต้องเป็น constraint trigger ที่เลื่อนไว้ (ไฟล์ใหม่ห้ามทำของเดิมหาย)
  foreach v in array array['transaction_lines|trg_lines_allowance_limits',
                           'transactions|trg_txn_allowance_limits'] loop
    select t.tgtype, t.tgdeferrable, t.tginitdeferred, t.tgconstraint
      into v_type, v_defer, v_init, v_con
      from pg_trigger t
     where t.tgrelid = ('sri_os.' || split_part(v, '|', 1))::regclass
       and t.tgname = split_part(v, '|', 2);
    if v_type is null then
      raise exception 'FAIL: F0 ไม่มี trigger %', v;
    end if;
    if not (v_defer and v_init and v_con <> 0) then
      raise exception 'FAIL: F0 ด่าน % ไม่ใช่ constraint trigger (deferrable initially deferred)', v;
    end if;
    if (v_type & 2) <> 0 then
      raise exception 'FAIL: F0 ด่าน % เป็น BEFORE ต้องเป็น AFTER', v;
    end if;
  end loop;

  -- ฟังก์ชันเดิมรุ่น 1 อาร์กิวเมนต์ต้อง **หายไป** ไม่ใช่อยู่คู่กับรุ่นใหม่
  -- (เหลือไว้ = รายงาน data health เรียกของเก่าที่ยังยิง cap ใส่ทุกรายการ)
  select count(*) into n from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_assert_allowance_limits';
  if n <> 1 then
    raise exception 'FAIL: F0 มีฟังก์ชัน fn_assert_allowance_limits % ตัว (ต้องมีตัวเดียว) — รุ่นเก่าที่ยิง cap ใส่ทุกรายการต้องถูก drop', n;
  end if;

  -- ด่านลูกหนี้ห้ามติดลบต้องมีอยู่จริงเป็นฟังก์ชันของตัวเอง (P2 จับที่นี่ด้วย)
  select count(*) into n from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_assert_receivable_not_negative';
  if n <> 1 then
    raise exception 'FAIL: F0 ไม่มีฟังก์ชัน sri_os.fn_assert_receivable_not_negative — ลูกหนี้ติดลบได้ทันที';
  end if;

  -- กฎเงินห้ามขึ้นกับสิทธิ์
  select count(*) into n from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.proname in ('fn_assert_allowance_limits', 'fn_assert_receivable_not_negative',
                       'fn_allowance_guard', 'fn_txn_allowance_guard')
     and p.prosrc like '%fn_can%';
  if n > 0 then
    raise exception 'FAIL: F0 ด่านเรียกฟังก์ชันตรวจสิทธิ์ — กฎเงินต้องปิดไม่ได้จากหน้า Settings';
  end if;

  -- หมวดใหม่ของข้อ 2 ต้องอยู่ใน txn_types พร้อมคู่บัญชีที่ถูก (P3/P4 จับที่นี่)
  select count(*) into n from sri_os.txn_types
   where code = 'inc.bad_debt_recovered' and dr_coa_code = '1100' and cr_coa_code = '4320';
  if n <> 1 then
    raise exception 'FAIL: F0 txn_types ไม่มีหมวด inc.bad_debt_recovered ที่ Dr 1100 / Cr 4320 — รัน npm run sync:rules แล้ว apply ไฟล์ seed';
  end if;
  if not exists (select 1 from sri_os.chart_of_accounts where code = '4320' and type = 'income') then
    raise exception 'FAIL: F0 ผังบัญชีใน DB ไม่มี 4320 หนี้สูญได้รับคืน (ประเภท income)';
  end if;

  raise notice 'ok F0 · ด่านทั้งสองยังเป็น constraint trigger ที่เลื่อนไว้ · มีด่านลูกหนี้ห้ามติดลบ · ฟังก์ชันเก่ารุ่น 1 อาร์กิวเมนต์ถูกถอด · หมวด/บัญชีใหม่อยู่ใน DB';
end $$;

-- ============================================================
-- F1 · **เคสของข้อ 1 ตรงๆ** · ลูกหนี้ 30,000 · ค่าเผื่อ 20,000 · รับชำระ 15,000
--      → ต้องผ่าน · เงินอยู่ในแบงก์แล้ว ลงสมุดไม่ได้ไม่ใช่ทางเลือก
-- ============================================================
do $$
declare v_pl numeric; v_cf numeric;
begin
  perform pg_temp.must_pass('F1 ตั้งลูกหนี้ค่าเช่าค้างรับ 30,000', format(
    $q$ select pg_temp.mk_recv('00000000-0000-0000-0000-0000000f0001', 'THANAKORN', 30000) $q$));
  perform pg_temp.must_pass('F1 ตั้งค่าเผื่อ 20,000 (ไม่เกินลูกหนี้)', format(
    $q$ select pg_temp.mk_allow('00000000-0000-0000-0000-0000000f0002', 'THANAKORN', 20000) $q$));

  v_pl := pg_temp.pl_profit('THANAKORN');
  v_cf := pg_temp.cf_cash('THANAKORN', 'operating');

  -- หลังรับชำระ: ค่าเผื่อ 20,000 > ลูกหนี้ 15,000 ซึ่ง **ถูกต้องและเกิดได้จริง**
  perform pg_temp.must_pass('F1 รับชำระ 15,000 ขณะที่ค่าเผื่อ (20,000) จะมากกว่าลูกหนี้ที่เหลือ (15,000)', format(
    $q$ select pg_temp.mk_collect('00000000-0000-0000-0000-0000000f0003', 'THANAKORN', 15000) $q$));

  if pg_temp.receivable('THANAKORN', '1200') <> 15000 then
    raise exception 'FAIL: F1 ลูกหนี้ 1200 ควรเหลือ 15000 ได้ %', pg_temp.receivable('THANAKORN', '1200');
  end if;
  if pg_temp.allowance('THANAKORN') <> 20000 then
    raise exception 'FAIL: F1 ค่าเผื่อควรยังเป็น 20000 ได้ %', pg_temp.allowance('THANAKORN');
  end if;
  -- รับชำระค้างรับ **ไม่ใช่รายได้ใหม่** → P&L ห้ามขยับ (ถ้าขยับ = รายได้ซ้ำ)
  if pg_temp.pl_profit('THANAKORN') <> v_pl then
    raise exception 'FAIL: F1 รับชำระค้างรับแล้ว P&L ขยับจาก % เป็น % — รายได้ซ้ำ', v_pl, pg_temp.pl_profit('THANAKORN');
  end if;
  -- แต่เงินสดต้องเข้างบกระแสเงินสดฝั่งดำเนินงาน 15,000
  if pg_temp.cf_cash('THANAKORN', 'operating') <> v_cf + 15000 then
    raise exception 'FAIL: F1 งบกระแสเงินสดฝั่งดำเนินงานควรเพิ่ม 15000 ได้ %',
      pg_temp.cf_cash('THANAKORN', 'operating') - v_cf;
  end if;

  raise notice 'ok F1 · รับชำระผ่านแม้ค่าเผื่อจะมากกว่าลูกหนี้ที่เหลือ · P&L ไม่ขยับ · เงินเข้างบกระแสเงินสดฝั่งดำเนินงาน';
end $$;

-- F1b · รับชำระ **ที่เหลือทั้งหมด** ขณะมีค่าเผื่อ → ผ่าน (ลูกหนี้เป็น 0 · ค่าเผื่อ 20,000)
do $$
begin
  perform pg_temp.must_pass('F1b รับชำระที่เหลือ 15,000 จนลูกหนี้เป็นศูนย์ ขณะค่าเผื่อยังเต็ม', format(
    $q$ select pg_temp.mk_collect('00000000-0000-0000-0000-0000000f0004', 'THANAKORN', 15000) $q$));
  if pg_temp.receivable('THANAKORN', '1200') <> 0 then
    raise exception 'FAIL: F1b ลูกหนี้ควรเป็น 0 ได้ %', pg_temp.receivable('THANAKORN', '1200');
  end if;
  if pg_temp.allowance('THANAKORN') <> 20000 then
    raise exception 'FAIL: F1b ค่าเผื่อควรยังเป็น 20000 ได้ %', pg_temp.allowance('THANAKORN');
  end if;
  raise notice 'ok F1b · รับชำระเต็มจำนวนขณะมีค่าเผื่อผ่าน (สภาพค่าเผื่อ > ลูกหนี้ ไม่ใช่ความผิด)';
end $$;

-- F2 · ทางแก้ของสภาพนั้นคือ **กลับค่าเผื่อ** ซึ่งผู้ใช้ต้องทำเองได้ ไม่ใช่ถูกบล็อก
do $$
begin
  perform pg_temp.must_pass('F2 กลับค่าเผื่อ 20,000 ที่ไม่ต้องใช้แล้ว', format(
    $q$ select pg_temp.mk_release('00000000-0000-0000-0000-0000000f0005', 'THANAKORN', 20000) $q$));
  if pg_temp.allowance('THANAKORN') <> 0 then
    raise exception 'FAIL: F2 ค่าเผื่อควรกลับเป็น 0 ได้ %', pg_temp.allowance('THANAKORN');
  end if;
  raise notice 'ok F2 · กลับค่าเผื่อได้ตามปกติ — ทางแก้อยู่ในมือผู้ใช้ ไม่ต้องให้ด่านบล็อกใบรับชำระ';
end $$;

-- ============================================================
-- F3 · ด่าน cap **ยังต้องอยู่** · ตั้งค่าเผื่อเกินลูกหนี้ → ปฏิเสธ
--      (อย่าแก้จนด่านหายไป — นี่คือสิ่งที่ P1 กลับทิศแล้วต้องยังเขียว)
-- ============================================================
do $$
declare v uuid := '00000000-0000-0000-0000-0000000f0010';
begin
  -- สุธี: ลูกหนี้ 10,000
  perform pg_temp.must_pass('F3 ตั้งลูกหนี้ของสุธี 10,000', format(
    $q$ select pg_temp.mk_recv('00000000-0000-0000-0000-0000000f0011', 'SUTEE', 10000) $q$));

  perform pg_temp.must_fail_like('F3 ตั้งค่าเผื่อ 10,001 เกินลูกหนี้ 10,000', format(
    $q$ select pg_temp.mk_allow(%L, 'SUTEE', 10001) $q$, v),
    'มากกว่ายอดลูกหนี้รวม');
  if exists (select 1 from sri_os.transactions where id = v) then
    raise exception 'FAIL: F3 ใบที่ถูกปฏิเสธยังค้างอยู่ในสมุด';
  end if;

  perform pg_temp.must_pass('F3b ตั้งค่าเผื่อ 10,000 พอดี', format(
    $q$ select pg_temp.mk_allow('00000000-0000-0000-0000-0000000f0012', 'SUTEE', 10000) $q$));
  perform pg_temp.must_fail_like('F3c ตั้งค่าเผื่อเพิ่มอีก 1 บาท', format(
    $q$ select pg_temp.mk_allow('00000000-0000-0000-0000-0000000f0013', 'SUTEE', 1) $q$),
    'มากกว่ายอดลูกหนี้รวม');

  raise notice 'ok F3 · ด่าน cap ยังทำงาน: ตั้งค่าเผื่อเกินลูกหนี้ถูกปฏิเสธ · พอดีผ่าน · เกินอีกบาทเดียวไม่ได้';
end $$;

-- ============================================================
-- F4 · **เคสของข้อ 2** · ตัดหนี้สูญ → ลูกหนี้จ่ายมาทีหลัง → ลงด้วยหมวดใหม่
--      P&L เพิ่มเท่ายอดที่รับคืน · ลูกหนี้ไม่ติดลบ · CF ขยับฝั่งดำเนินงาน
-- ============================================================
do $$
declare v_pl numeric; v_cf numeric;
begin
  -- สุธีตอนนี้: ลูกหนี้ 10,000 · ค่าเผื่อ 10,000 → ตัดหนี้สูญได้พอดี
  perform pg_temp.must_pass('F4 ตัดหนี้สูญ 10,000', format(
    $q$ select pg_temp.mk_writeoff('00000000-0000-0000-0000-0000000f0020', 'SUTEE', 10000) $q$));
  if pg_temp.receivable('SUTEE', '1200') <> 0 or pg_temp.allowance('SUTEE') <> 0 then
    raise exception 'FAIL: F4 หลังตัดหนี้สูญ ลูกหนี้และค่าเผื่อควรเป็น 0 ทั้งคู่ ได้ % / %',
      pg_temp.receivable('SUTEE', '1200'), pg_temp.allowance('SUTEE');
  end if;

  v_pl := pg_temp.pl_profit('SUTEE');
  v_cf := pg_temp.cf_cash('SUTEE', 'operating');

  perform pg_temp.must_pass('F4 ลูกหนี้ที่ตัดทิ้งไปแล้วจ่ายมา 6,000 → ลงหมวดหนี้สูญได้รับคืน', format(
    $q$ select pg_temp.mk_recovered('00000000-0000-0000-0000-0000000f0021', 'SUTEE', 6000) $q$));

  -- (ก) P&L **เพิ่มขึ้นเท่ายอดที่รับคืน** — ของเดิมไม่ขยับเลย = รายได้ขาดไป 6,000
  if pg_temp.pl_profit('SUTEE') <> v_pl + 6000 then
    raise exception 'FAIL: F4 กำไรควรเพิ่ม 6000 (จาก % เป็น %) ได้ % — รับคืนหนี้สูญต้องรับรู้เป็นรายได้',
      v_pl, v_pl + 6000, pg_temp.pl_profit('SUTEE');
  end if;
  -- (ข) **ลูกหนี้ไม่ติดลบ** — อาการเดิมคือ 1200 = −6,000
  if pg_temp.receivable('SUTEE', '1200') <> 0 then
    raise exception 'FAIL: F4 ลูกหนี้ 1200 ต้องยังเป็น 0 ได้ % — หมวดนี้ห้ามกลับไปแตะบัญชีลูกหนี้',
      pg_temp.receivable('SUTEE', '1200');
  end if;
  -- (ค) งบกระแสเงินสดขยับฝั่งดำเนินงานเท่าเงินที่เข้าจริง
  if pg_temp.cf_cash('SUTEE', 'operating') <> v_cf + 6000 then
    raise exception 'FAIL: F4 งบกระแสเงินสดฝั่งดำเนินงานควรเพิ่ม 6000 ได้ %',
      pg_temp.cf_cash('SUTEE', 'operating') - v_cf;
  end if;
  -- (ง) และยอดต้องไปโผล่ที่บัญชี 4320 จริง ไม่ใช่ 4200 (รายได้ค่าเช่าซ้ำ)
  if (select coalesce(sum(l.credit - l.debit), 0)
        from sri_os.transaction_lines l join sri_os.chart_of_accounts c on c.id = l.coa_id
       where l.transaction_id = '00000000-0000-0000-0000-0000000f0021' and c.code = '4320') <> 6000 then
    raise exception 'FAIL: F4 ยอดที่รับคืนไม่ได้ลงบัญชี 4320 หนี้สูญได้รับคืน';
  end if;

  raise notice 'ok F4 · ตัดหนี้สูญแล้วรับคืนได้ด้วยหมวดของตัวเอง · P&L เพิ่มเท่ายอดที่รับคืน · ลูกหนี้ไม่ติดลบ · CF ฝั่งดำเนินงานขยับ';
end $$;

-- ============================================================
-- F5 · **เคสของข้อ 3** · ทำให้ลูกหนี้ติดลบด้วยเส้นทางใดก็ตาม → ปฏิเสธ
--      (เส้นทางที่ผู้ใช้จะเดินจริงถ้าไม่มีหมวดใหม่: รับชำระค้างรับหลังตัดหนี้สูญ)
-- ============================================================
do $$
declare v uuid := '00000000-0000-0000-0000-0000000f0030';
begin
  -- สุธีตอนนี้: ลูกหนี้ 1200 = 0 → รับชำระค้างรับอีกบาทเดียวก็ติดลบ
  perform pg_temp.must_fail_like('F5 รับชำระค้างรับ 6,000 หลังตัดหนี้สูญไปแล้ว (ลูกหนี้จะติดลบ)', format(
    $q$ select pg_temp.mk_collect(%L, 'SUTEE', 6000) $q$, v),
    'ลูกหนี้ติดลบไม่มีความหมายทางบัญชี');
  if exists (select 1 from sri_os.transactions where id = v) then
    raise exception 'FAIL: F5 ใบที่ถูกปฏิเสธยังค้างอยู่ในสมุด';
  end if;

  -- ข้อความต้องชี้ทางที่ถูก (หมวดหนี้สูญได้รับคืน) ไม่ใช่บอกแต่ว่าผิด
  perform pg_temp.must_fail_like('F5 ข้อความของด่านลูกหนี้ติดลบต้องชี้หมวดที่ถูก', format(
    $q$ select pg_temp.mk_collect('00000000-0000-0000-0000-0000000f0031', 'SUTEE', 1) $q$),
    '"หนี้สูญได้รับคืน" (Dr เงินสด / Cr 4320)');

  raise notice 'ok F5 · ลูกหนี้ติดลบถูกปฏิเสธ และข้อความชี้ไปที่หมวดหนี้สูญได้รับคืน';
end $$;

-- F5b · ด่านนี้ดูเป็นบัญชี **แต่ละตัว** ไม่ใช่ยอดรวม
--       1210 ติดลบโดยมี 1200 บวกคลุมอยู่ ต้องยังถูกปฏิเสธ
--       (ถ้าดูแต่ยอดรวม ลูกหนี้ดอกเบี้ยติดลบจะซ่อนอยู่ใต้ลูกหนี้ค่าเช่าได้ตลอด)
do $$
begin
  perform pg_temp.must_pass('F5b ตั้งลูกหนี้ค่าเช่าของธนวินท์ 20,000', format(
    $q$ select pg_temp.mk_recv('00000000-0000-0000-0000-0000000f0040', 'THANAWIN', 20000) $q$));
  perform pg_temp.must_fail_like('F5b รับชำระดอกเบี้ยค้างรับ 5,000 ที่ไม่เคยตั้งไว้ (1210 ติดลบ)', format(
    $q$ select pg_temp.mk('00000000-0000-0000-0000-0000000f0041', 'THANAWIN', 'inv.collect_interest',
          current_date,
          jsonb_build_array(
            jsonb_build_object('coa', '1100', 'dr', 5000, 'cr', 0, 'cf', 'operating',
                               'bank', pg_temp.bank('THANAWIN')),
            jsonb_build_object('coa', '1210', 'dr', 0, 'cr', 5000))) $q$),
    'ลูกหนี้ติดลบไม่มีความหมายทางบัญชี');
  if pg_temp.receivable('THANAWIN', '1200') <> 20000 then
    raise exception 'FAIL: F5b ลูกหนี้ค่าเช่าเพี้ยนหลังเคสที่ถูกปฏิเสธ: %', pg_temp.receivable('THANAWIN', '1200');
  end if;
  raise notice 'ok F5b · ด่านดูลูกหนี้เป็นบัญชีแต่ละตัว ไม่ใช่ยอดรวม (1210 ติดลบไม่ซ่อนใต้ 1200)';
end $$;

-- ============================================================
-- F6 · **เคสของข้อ 3 ส่วนที่สอง** · ตั้งค่าเผื่อของหนี้รายใหม่ได้
--      หลังจากตัดหนี้สูญและรับคืนไปแล้ว
--      (ของเดิม: 1200 ติดลบ → cap เทียบกับยอดติดลบ → ปฏิเสธถาวรทั้งผู้ถือ)
-- ============================================================
do $$
begin
  perform pg_temp.must_pass('F6 ตั้งลูกหนี้รายใหม่ของสุธี 7,000', format(
    $q$ select pg_temp.mk_recv('00000000-0000-0000-0000-0000000f0050', 'SUTEE', 7000) $q$));
  perform pg_temp.must_pass('F6 ตั้งค่าเผื่อของหนี้รายใหม่ 7,000', format(
    $q$ select pg_temp.mk_allow('00000000-0000-0000-0000-0000000f0051', 'SUTEE', 7000) $q$));
  if pg_temp.allowance('SUTEE') <> 7000 then
    raise exception 'FAIL: F6 ค่าเผื่อควรเป็น 7000 ได้ %', pg_temp.allowance('SUTEE');
  end if;
  perform pg_temp.must_pass('F6 และตัดหนี้สูญรายใหม่ได้ครบวงจร', format(
    $q$ select pg_temp.mk_writeoff('00000000-0000-0000-0000-0000000f0052', 'SUTEE', 7000) $q$));
  raise notice 'ok F6 · ฟีเจอร์ไม่ตายทั้งผู้ถือหลังตัดหนี้สูญ+รับคืน (ตั้งค่าเผื่อรายใหม่ได้ครบวงจร)';
end $$;

-- ============================================================
-- F7 · **ข้อ 6** · ข้อความของด่าน "ค่าเผื่อติดลบ" ต้องชี้ทางแก้ให้ตรงสถานการณ์
--      (ก) เอาค่าเผื่อออกเกินที่ตั้งไว้ (ตัดหนี้สูญ/กลับค่าเผื่อ) → "ตั้งค่าเผื่อเพิ่ม"
--      (ข) void/reverse **ใบตั้งค่าเผื่อ** ที่ถูกใช้ไปแล้ว → "กลับใบตัดหนี้สูญก่อน"
--          ของเดิมบอกให้ไปตั้งค่าเผื่อเพิ่ม ซึ่งผู้ใช้ทำแล้วก็ไม่ช่วยอะไร
-- ============================================================
do $$
begin
  -- ตั้งลูกหนี้ไว้ก่อน เพื่อให้เคส (ก) ยิง **ด่านค่าเผื่อ** ตัวเดียว
  -- (ตัดหนี้สูญตอนลูกหนี้เป็นศูนย์จะยิงด่านลูกหนี้ติดลบด้วย แล้วเคสนี้จะตรวจข้อความผิดด่าน)
  perform pg_temp.must_pass('F7 ตั้งลูกหนี้ 5,000', format(
    $q$ select pg_temp.mk_recv('00000000-0000-0000-0000-0000000f0061', 'THANAKORN', 5000) $q$));

  -- (ก) ค่าเผื่อ 0 แต่ลูกหนี้มี 5,000 → ตัดหนี้สูญไม่ได้ และทางแก้คือ "ตั้งค่าเผื่อเพิ่ม"
  perform pg_temp.must_fail_like('F7a ตัดหนี้สูญตอนค่าเผื่อเหลือ 0', format(
    $q$ select pg_temp.mk_writeoff('00000000-0000-0000-0000-0000000f0060', 'THANAKORN', 1000) $q$),
    'เอาค่าเผื่อออกมากกว่าค่าเผื่อคงเหลือ');
  -- **และต้องไม่** เป็นสาขา void ใบตั้งค่าเผื่อ ซึ่งบอกว่า "ตั้งค่าเผื่อเพิ่มไม่ช่วย"
  -- ทั้งที่ทางแก้ที่ถูกของเคสนี้คือตั้งค่าเผื่อเพิ่ม (รูที่ 2ข ของผู้ตรวจรอบสอง)
  perform pg_temp.must_fail_without('F7a ข้อความห้ามเป็นสาขา void ใบตั้งค่าเผื่อ', format(
    $q$ select pg_temp.mk_writeoff('00000000-0000-0000-0000-0000000f0064', 'THANAKORN', 1000) $q$),
    'ตั้งค่าเผื่อเพิ่มไม่ช่วย');

  -- (ข) เตรียมสภาพ: ตั้งค่าเผื่อ → ตัดหนี้สูญจนค่าเผื่อหมด
  perform pg_temp.must_pass('F7 ตั้งค่าเผื่อ 5,000', format(
    $q$ select pg_temp.mk_allow('00000000-0000-0000-0000-0000000f0062', 'THANAKORN', 5000) $q$));
  perform pg_temp.must_pass('F7 ตัดหนี้สูญ 5,000', format(
    $q$ select pg_temp.mk_writeoff('00000000-0000-0000-0000-0000000f0063', 'THANAKORN', 5000) $q$));

  -- void ใบ **ตั้งค่าเผื่อ** ขณะที่ใบตัดหนี้สูญยังอยู่ → ค่าเผื่อติดลบ → ปฏิเสธ
  perform pg_temp.must_fail_like('F7b void ใบตั้งค่าเผื่อที่ถูกใช้ไปแล้ว → ต้องปฏิเสธ',
    $q$ select pg_temp.upd($i$ update sri_os.transactions set status = 'void'
            where id = '00000000-0000-0000-0000-0000000f0062' $i$) $q$,
    'ใบตั้งค่าเผื่อถูกเอาออก');

  -- และข้อความต้องชี้ว่าให้ **กลับใบตัดหนี้สูญ** ก่อน
  perform pg_temp.must_fail_like('F7b ข้อความต้องบอกให้จัดการใบตัดหนี้สูญก่อน',
    $q$ select pg_temp.upd($i$ update sri_os.transactions set status = 'void'
            where id = '00000000-0000-0000-0000-0000000f0062' $i$) $q$,
    'ต้องกลับรายการหรือยกเลิกใบตัดหนี้สูญ');

  -- **และต้องไม่** บอกให้ไปตั้งค่าเผื่อเพิ่ม ซึ่งเป็นทางแก้ของอีกสถานการณ์
  perform pg_temp.must_fail_without('F7b ข้อความห้ามชี้ทางแก้ของอีกสถานการณ์',
    $q$ select pg_temp.upd($i$ update sri_os.transactions set status = 'void'
            where id = '00000000-0000-0000-0000-0000000f0062' $i$) $q$,
    'ต้องลง "ตั้งค่าเผื่อหนี้สงสัยจะสูญ"');

  -- ลำดับที่ถูกต้องยังทำได้ (ห้ามกันแน่นเกิน)
  perform pg_temp.must_pass('F7c void ใบตัดหนี้สูญก่อน แล้วค่อย void ใบตั้งค่าเผื่อ',
    $q$ select pg_temp.upd($i$ update sri_os.transactions set status = 'void'
            where id = '00000000-0000-0000-0000-0000000f0063' $i$) $q$);
  perform pg_temp.must_pass('F7c แล้ว void ใบตั้งค่าเผื่อได้',
    $q$ select pg_temp.upd($i$ update sri_os.transactions set status = 'void'
            where id = '00000000-0000-0000-0000-0000000f0062' $i$) $q$);

  raise notice 'ok F7 · ข้อความของด่านค่าเผื่อติดลบแยกตามสาเหตุ (เอาค่าเผื่อออกเกิน vs ยกเลิกใบตั้งค่าเผื่อที่ถูกใช้ไปแล้ว) · ลำดับที่ถูกต้องยังทำได้';
end $$;

-- ============================================================
-- F8 · กฎเงินต้องไม่ขึ้นกับสิทธิ์ — เดินเส้นทางสำคัญซ้ำด้วย role authenticated
-- ============================================================
do $$
begin
  perform set_config('test.uid', pg_temp.fuid('f_mgmt')::text, true);
  execute 'set local role authenticated';

  -- ธนวินท์: ลูกหนี้ค่าเช่า 20,000 · ค่าเผื่อ 0
  perform pg_temp.must_pass('F8 ตั้งค่าเผื่อ 20,000 (authenticated)', format(
    $q$ select pg_temp.mk_allow('00000000-0000-0000-0000-0000000f0070', 'THANAWIN', 20000) $q$));
  -- รับชำระ 20,000 ขณะค่าเผื่อเต็ม → ต้องผ่าน (เคสของข้อ 1 ในฐานะผู้ใช้จริง)
  perform pg_temp.must_pass('F8 รับชำระ 20,000 ขณะค่าเผื่อเต็ม (authenticated)', format(
    $q$ select pg_temp.mk_collect('00000000-0000-0000-0000-0000000f0071', 'THANAWIN', 20000) $q$));
  -- แต่รับชำระเกินจนลูกหนี้ติดลบ ยังต้องถูกปฏิเสธ
  perform pg_temp.must_fail_like('F8 รับชำระเกินจนลูกหนี้ติดลบ (authenticated)', format(
    $q$ select pg_temp.mk_collect('00000000-0000-0000-0000-0000000f0072', 'THANAWIN', 1) $q$),
    'ลูกหนี้ติดลบไม่มีความหมายทางบัญชี');

  execute 'reset role';
  raise notice 'ok F8 · ด่านทั้งชุดทำงานกับ role authenticated ด้วย (ไม่ได้ผ่าน/ไม่ผ่านเพราะรันเป็น superuser)';
end $$;

-- ============================================================
-- F9 · ห้ามกันแน่นเกิน — ใบกลับรายการของใบรับชำระต้องลงได้
--      (ใบ reverse สลับด้าน: Dr 1200 / Cr 1100 → ลูกหนี้กลับมา ไม่ติดลบ)
-- ============================================================
do $$
begin
  perform pg_temp.must_pass('F9 กลับรายการใบรับชำระของธนวินท์ 20,000', format(
    $q$ select pg_temp.mk('00000000-0000-0000-0000-0000000f0080', 'THANAWIN', 'inv.collect_rent',
          current_date,
          jsonb_build_array(
            jsonb_build_object('coa', '1200', 'dr', 20000, 'cr', 0),
            jsonb_build_object('coa', '1100', 'dr', 0, 'cr', 20000, 'cf', 'operating',
                               'bank', pg_temp.bank('THANAWIN')))) $q$));
  if pg_temp.receivable('THANAWIN', '1200') <> 20000 then
    raise exception 'FAIL: F9 ลูกหนี้ควรกลับมาเป็น 20000 ได้ %', pg_temp.receivable('THANAWIN', '1200');
  end if;
  raise notice 'ok F9 · ใบกลับรายการที่สลับด้านยังลงได้ (ด่านตัดสินจากสภาพสุดท้าย ไม่ใช่ทิศของบรรทัด)';
end $$;

-- ---------- สรุป: ทุกใบที่ไฟล์นี้สร้างต้องผ่านด่านที่เลื่อนไว้จริง ----------
do $$
declare n int;
begin
  set constraints all immediate;
  select count(*) into n from sri_os.transactions where memo like 'AF %';
  if n < 14 then
    raise exception 'FAIL: นับใบที่เทสต์นี้สร้างได้แค่ % ใบ — เทสต์อาจไม่ได้ลงอะไรเลย', n;
  end if;
  raise notice 'ok F · ทั้ง % ใบของไฟล์นี้ผ่านด่านที่เลื่อนไว้ (เคสปฏิเสธไม่ทิ้งใบเสียรูปไว้)', n;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: ใบที่เทสต์นี้สร้างไว้เสียรูป: %', sqlerrm;
end $$;

rollback;
