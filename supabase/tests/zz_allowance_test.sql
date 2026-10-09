-- ============================================================
-- SRI OS · เทสต์ด่านค่าเผื่อหนี้สงสัยจะสูญ + การตัดหนี้สูญ
--   migration ที่ทดสอบ: 20261009000002_allowance_and_writeoff.sql
--                      20261009000003_txn_types_cash_direction.sql
--   และยืนยันว่า 20261009000001_cash_date_invariant **ยอมรับ** รายการที่ไม่มีเงินเคลื่อน
--
-- รูปแบบใหม่ที่ระบบไม่เคยเจอ: ก่อนรอบนี้ **ทุกหมวดในตารางกฎแตะบัญชี 1100**
--   รายการที่ไม่มีขาเงินสดเลยจึงเป็นเส้นทางที่ไม่มีใครเคยเดิน — ต้องยืนยันว่า
--   ด่านเดิม (cash_date · เงินลอย · คู่บัญชีตรงหมวด) ยอมให้เดินได้จริง
--   ไม่ใช่ปฏิเสธด้วยเหตุผลที่ไม่เกี่ยว
--
-- สิ่งที่ด่านใหม่บังคับ (เป็นอสมการสองข้อของยอดบัญชี 1290 **ต่อผู้ถือ**)
--   allowance  = Σ(credit − debit) ของ 1290            · receivable = Σ(debit − credit) ของ 1200+1210+1220
--   ด่าน 1 · allowance <= receivable   (ค่าเผื่อเกินลูกหนี้ = ลูกหนี้สุทธิติดลบ)
--   ด่าน 2 · allowance >= 0            (ตัดหนี้สูญเกินค่าเผื่อคงเหลือ)
--   ด่าน 3 · allowance >= 0            (กลับค่าเผื่อเกินค่าเผื่อคงเหลือ — อสมการเดียวกับ 2)
--
-- **เคสสำคัญสุดคือ A6**: ตัดหนี้สูญแล้ว P&L ต้องไม่ขยับ
--   ถ้าตัดลง 5920 อีกรอบ = ค่าใช้จ่ายซ้ำสองเท่า กำไรต่ำกว่าจริง
--   และ **งบดุลยังสมดุลทุกบรรทัด ไม่มี trigger ไหนร้อง** → จับได้แค่ด้วยเทสต์นี้
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ **rollback** ปิดท้าย — ไม่ทิ้งรายการเงินไว้
--   ด่านใหม่เป็น `constraint trigger ... deferrable initially deferred` ทั้งสองตัว
--   → ทุกเคสต้องยิง `set constraints all immediate` เองผ่าน pg_temp.fire()
--   แล้วคืนสภาพ deferred (แพทเทิร์นเดียวกับ zz_cash_date_invariant / zz_reverse_integrity)
--
-- รันในฐานะ superuser ของ cluster = ข้าม RLS แต่ **trigger ยังทำงานทุกเส้นทาง**
--   (A12 เดินซ้ำด้วย role authenticated เพื่อยืนยันว่ากฎเงินไม่ขึ้นกับสิทธิ์)
--
-- mutation ที่ต้องทำให้เทสต์แดง (ถ้าไม่แดง = เทสต์ยังไม่ครอบ)
--   N1 ถอด if v_allow > v_recv (ด่าน "ค่าเผื่อห้ามเกินลูกหนี้")   → A3 A3b แดง
--   N2 ถอด if v_allow < 0 (ด่าน "เอาค่าเผื่อออกเกินที่ตั้งไว้")    → A4 A5c A7 A9 A10 A11 A12 แดง
--   N3 เปลี่ยนตัดหนี้สูญให้ลง 5920 แทน 1290                        → A6 แดง (และ A5b)
--   N4 ลบหมวด adj.doubtful_release ออกจากตารางกฎ                   → A7 A8 แดง (หมวดไม่มีใน txn_types)
--   N5 (ฝั่งฟอร์ม) อยู่ใน src/components/form/__tests__/bank-field.test.ts
--   N6 ถอด trg_txn_allowance_limits (ด่านฝั่งหัวรายการ)             → A0 A11(ก) แดง
--      (A11 ยิงผ่าน `update transactions set status` ซึ่งไม่แตะ transaction_lines เลย
--       → ด่านฝั่งบรรทัดไม่ยิง · เป็นเคสเดียวที่พิสูจน์ว่าด่านฝั่งหัวรายการมีหน้าที่จริง)
--   N7 เปลี่ยน constraint trigger เป็น trigger ธรรมดา              → A0 แดง (และ A5 สุ่มแดง)
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
create temporary table t_auid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_auid(label) values ('a_mgmt');
insert into auth.users(id) select id from t_auid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select id, label || '@allowance.local', label, 'management', true from t_auid;
insert into sri_os.user_owner_access(user_id, owner_id)
select (select id from t_auid where label = 'a_mgmt'), o.id from sri_os.owners o;

create or replace function pg_temp.auid(p_label text) returns uuid
language sql stable as $fn$ select id from t_auid where label = p_label $fn$;

create or replace function pg_temp.coa(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.chart_of_accounts where code = p_code $fn$;

create or replace function pg_temp.own(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.owners where code = p_code $fn$;

insert into sri_os.contacts(id, first_name, types)
values ('00000000-0000-0000-0000-0000000aac01', 'ลูกหนี้ AL', array['tenant'])
on conflict do nothing;

-- ------------------------------------------------------------
-- ตัวช่วย (แพทเทิร์นเดียวกับ zz_cash_date_invariant_test)
-- ------------------------------------------------------------
create or replace function pg_temp.must_fail_like(p_label text, p_sql text, p_needle text) returns void
language plpgsql as $fn$
declare v text;
begin
  begin
    execute p_sql;
    raise exception 'AL_UNEXPECTED_SUCCESS';
  exception when others then
    v := sqlerrm;
    if v = 'AL_UNEXPECTED_SUCCESS' then
      raise exception 'FAIL: % — คำสั่งควรถูกปฏิเสธแต่สำเร็จ', p_label;
    end if;
    if v like 'FAIL:%' then raise; end if;
    if position(p_needle in v) = 0 then
      raise exception 'FAIL: % — ปฏิเสธถูกแต่ข้อความไม่มี "%" · ได้: %', p_label, p_needle, v;
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
 *   p_lines = [{"coa":"1290","dr":0,"cr":5000}, ...]
 * **ไม่ใส่ค่า default ให้ cash_date** โดยตั้งใจ — ผู้เรียกต้องบอกทุกครั้ง
 * (บทเรียนข้อ 3: fixture ที่เติมค่าให้เองจะไม่มีวันแตะเส้นทางที่ข้อมูลขาด)
 */
create or replace function pg_temp.mk(p_id uuid, p_owner text, p_type text,
                                      p_cash date, p_lines jsonb) returns uuid
language plpgsql as $fn$
declare r jsonb;
begin
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, cash_date, memo,
                                  attachments, contact_id)
  values (p_id, pg_temp.own(p_owner), p_type, current_date, p_cash, 'AL ' || p_id::text,
          array['รายงานอายุลูกหนี้.pdf'], '00000000-0000-0000-0000-0000000aac01');
  for r in select * from jsonb_array_elements(p_lines) loop
    insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit, cf_category, memo)
    values (p_id, pg_temp.coa(r ->> 'coa'),
            coalesce((r ->> 'dr')::numeric, 0), coalesce((r ->> 'cr')::numeric, 0),
            coalesce(r ->> 'cf', 'none')::sri_os.cf_group, 'AL บรรทัด');
  end loop;
  perform pg_temp.fire();
  return p_id;
end $fn$;

-- ตั้งลูกหนี้ค่าเช่าค้างรับ (Dr 1200 / Cr 4200) — ไม่มีขาเงินสด จึง cash_date = null
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

-- ตัดหนี้สูญค่าเช่า (Dr 1290 / Cr 1200) — **ไม่แตะ 5920**
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

-- ---------- ตัววัดที่งบแต่ละตัวเห็น ----------
-- ค่าเผื่อคงเหลือ (contra-asset อ่านฝั่งเครดิต)
create or replace function pg_temp.allowance(p_owner text) returns numeric
language sql stable as $fn$
  select coalesce(sum(l.credit - l.debit), 0)
    from sri_os.transactions t
    join sri_os.transaction_lines l on l.transaction_id = t.id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where t.owner_id = pg_temp.own(p_owner) and t.status <> 'void' and c.code = '1290'
$fn$;

-- ลูกหนี้ **สุทธิ** ที่งบดุลแสดง = (1200+1210+1220) − ค่าเผื่อ
create or replace function pg_temp.net_receivable(p_owner text) returns numeric
language sql stable as $fn$
  select coalesce(sum(case when c.code = '1290' then -(l.credit - l.debit)
                           else l.debit - l.credit end), 0)
    from sri_os.transactions t
    join sri_os.transaction_lines l on l.transaction_id = t.id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where t.owner_id = pg_temp.own(p_owner) and t.status <> 'void'
     and c.code in ('1200', '1210', '1220', '1290')
$fn$;

-- กำไรขาดทุน: ค่าใช้จ่าย − รายได้ (บวก = กำไรลด) — เอาไว้พิสูจน์ว่าตัดหนี้สูญไม่ขยับ
create or replace function pg_temp.pl_net(p_owner text) returns numeric
language sql stable as $fn$
  select coalesce(sum(l.debit - l.credit), 0)
    from sri_os.transactions t
    join sri_os.transaction_lines l on l.transaction_id = t.id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where t.owner_id = pg_temp.own(p_owner) and t.status <> 'void'
     and c.type in ('income', 'expense')
$fn$;

-- ยอดที่ **งบกระแสเงินสด** เห็น (เกณฑ์เดียวกับ zz_cash_date_invariant: cash_date ไม่ null)
create or replace function pg_temp.cf_cash(p_owner text) returns numeric
language sql stable as $fn$
  select coalesce(sum(l.debit - l.credit), 0)
    from sri_os.transactions t
    join sri_os.transaction_lines l on l.transaction_id = t.id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where t.owner_id = pg_temp.own(p_owner) and t.status <> 'void'
     and t.cash_date is not null and c.code ~ '^11[0-9][0-9]$'
$fn$;

-- ============================================================
-- A0 · โครงสร้าง — ไล่จาก catalog จริง ไม่ใช่ไล่ไฟล์
--      ชั้นนี้จับ N6 (ถอดด่านฝั่งหัวรายการ) และ N7 (ไม่ใช่ constraint trigger)
--      ได้ก่อนถึงเคสข้อมูล ซึ่งอาการจะกำกวมกว่ามาก
-- ============================================================
do $$
declare
  v text; v_type int; v_defer boolean; v_init boolean; v_con oid; n int; v_src text;
begin
  foreach v in array array['transaction_lines|trg_lines_allowance_limits',
                           'transactions|trg_txn_allowance_limits'] loop
    select t.tgtype, t.tgdeferrable, t.tginitdeferred, t.tgconstraint
      into v_type, v_defer, v_init, v_con
      from pg_trigger t
     where t.tgrelid = ('sri_os.' || split_part(v, '|', 1))::regclass
       and t.tgname = split_part(v, '|', 2);
    if v_type is null then
      raise exception 'FAIL: A0 ไม่มี trigger % — ค่าเผื่อติดลบและเกินยอดลูกหนี้ได้ทันที', v;
    end if;
    if not (v_defer and v_init and v_con <> 0) then
      raise exception 'FAIL: A0 ด่าน % ไม่ใช่ constraint trigger (deferrable initially deferred) — ใบตัดหนี้สูญลดทั้ง 1290 และลูกหนี้พร้อมกัน ด่านที่ยิงทันทีจะปฏิเสธใบที่ถูกต้องตามลำดับการ insert', v;
    end if;
    if (v_type & 2) <> 0 then
      raise exception 'FAIL: A0 ด่าน % เป็น BEFORE ต้องเป็น AFTER (บรรทัดของใบยังไม่ครบตอน before)', v;
    end if;
    if (v_type & 4) = 0 then
      raise exception 'FAIL: A0 ด่าน % ไม่ยิงตอน INSERT', v;
    end if;
    if (v_type & 16) = 0 then
      raise exception 'FAIL: A0 ด่าน % ไม่ยิงตอน UPDATE — คืนสภาพใบที่ void ไว้จะเลี่ยงด่านได้', v;
    end if;
  end loop;

  -- กฎเงินห้ามขึ้นกับสิทธิ์: ด่านใหม่ห้ามเรียก fn_can
  select count(*) into n from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.proname in ('fn_assert_allowance_limits', 'fn_allowance_guard', 'fn_txn_allowance_guard')
     and p.prosrc like '%fn_can%';
  if n > 0 then
    raise exception 'FAIL: A0 ด่านค่าเผื่อเรียกฟังก์ชันตรวจสิทธิ์ — กฎเงินต้องปิดไม่ได้จากหน้า Settings';
  end if;

  -- ต้องนับเฉพาะใบที่ไม่ void · ถ้าไม่กรอง ใบที่ยกเลิกไปแล้วจะยังค้ำการตัดหนี้สูญอยู่
  select prosrc into v_src from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_assert_allowance_limits';
  if v_src is null then
    raise exception 'FAIL: A0 ไม่มีฟังก์ชัน sri_os.fn_assert_allowance_limits';
  end if;
  if position('void' in v_src) = 0 then
    raise exception 'FAIL: A0 ด่านค่าเผื่อไม่กรองใบที่ void ออก — ใบที่ยกเลิกแล้วจะยังค้ำยอดค่าเผื่ออยู่';
  end if;

  -- คอลัมน์สำเนาของ CashDirection ต้องรับ none ได้จริง
  select count(*) into n from information_schema.columns
   where table_schema = 'sri_os' and table_name = 'txn_types' and column_name = 'cash_direction';
  if n <> 1 then
    raise exception 'FAIL: A0 ไม่มีคอลัมน์ txn_types.cash_direction — DB แยก "ไม่มีเงินเคลื่อน" จาก "โอนสองทาง" ไม่ออก (direction เป็น 0 ทั้งคู่)';
  end if;
  select count(*) into n from sri_os.txn_types where cash_direction = 'none';
  if n < 5 then
    raise exception 'FAIL: A0 txn_types มีหมวด cash_direction = none แค่ % หมวด (ต้องมีห้าหมวดของประเภทปรับปรุงทางบัญชี) — รัน npm run sync:rules แล้ว apply ไฟล์ seed', n;
  end if;

  raise notice 'ok A0 · ด่านค่าเผื่อผูกเป็น constraint trigger ที่เลื่อนไว้ทั้งฝั่งบรรทัดและฝั่งหัวรายการ · ไม่ขึ้นกับสิทธิ์ · txn_types เก็บ cash_direction = none ได้';
end $$;

-- ============================================================
-- A1 · ลงรายการที่ไม่มีเงินเคลื่อนได้ · ไม่ต้องมีบัญชีธนาคาร · cash_date = null
--      (ด่าน 20261009000001 ต้องยอม เพราะไม่มีบรรทัด 11xx)
-- ============================================================
do $$
declare v uuid := '00000000-0000-0000-0000-0000000a0001';
begin
  perform pg_temp.must_pass('A1 ตั้งลูกหนี้ค่าเช่าค้างรับ 30,000', format(
    $q$ select pg_temp.mk_recv(%L, 'THANAKORN', 30000) $q$, v));

  perform pg_temp.must_pass('A1 ตั้งค่าเผื่อ 10,000 โดยไม่มีบัญชีธนาคารและ cash_date = null', format(
    $q$ select pg_temp.mk_allow('00000000-0000-0000-0000-0000000a0002', 'THANAKORN', 10000) $q$));

  if pg_temp.allowance('THANAKORN') <> 10000 then
    raise exception 'FAIL: A1 ค่าเผื่อคงเหลือควรเป็น 10000 ได้ %', pg_temp.allowance('THANAKORN');
  end if;
  -- ลูกหนี้สุทธิในงบดุลลดลงจาก 30,000 เป็น 20,000
  if pg_temp.net_receivable('THANAKORN') <> 20000 then
    raise exception 'FAIL: A1 ลูกหนี้สุทธิควรเป็น 20000 ได้ %', pg_temp.net_receivable('THANAKORN');
  end if;
  -- P&L มีค่าใช้จ่าย 10,000 หักจากรายได้ค่าเช่า 30,000 → สุทธิ −20,000 (กำไร 20,000)
  if pg_temp.pl_net('THANAKORN') <> -20000 then
    raise exception 'FAIL: A1 P&L สุทธิควรเป็น -20000 (รายได้ 30000 − ค่าใช้จ่าย 10000) ได้ %', pg_temp.pl_net('THANAKORN');
  end if;
  -- งบกระแสเงินสดไม่ขยับเลย: ทั้งสองใบไม่มีบรรทัด 11xx และ cash_date เป็น null
  if pg_temp.cf_cash('THANAKORN') <> 0 then
    raise exception 'FAIL: A1 งบกระแสเงินสดขยับ % ทั้งที่ไม่มีเงินเคลื่อน', pg_temp.cf_cash('THANAKORN');
  end if;

  raise notice 'ok A1 · รายการที่ไม่มีเงินเคลื่อนลงได้ · ลูกหนี้สุทธิลด · P&L มีค่าใช้จ่าย · งบกระแสเงินสดไม่ขยับ';
end $$;

-- A2 · ใส่ cash_date กับรายการที่ไม่มีบรรทัด 11xx → ด่านเดิมต้องปฏิเสธ (เงินสดผี)
do $$
begin
  perform pg_temp.must_fail_like('A2 ตั้งค่าเผื่อแต่ใส่ cash_date', format(
    $q$ select pg_temp.mk('00000000-0000-0000-0000-0000000a0003', 'THANAKORN', 'adj.doubtful',
          current_date,
          '[{"coa":"5920","dr":1000,"cr":0},{"coa":"1290","dr":0,"cr":1000}]'::jsonb) $q$),
    'cash_date');
  raise notice 'ok A2 · รายการที่ไม่มีบรรทัดเงินสดใส่ cash_date ไม่ได้ (งบกระแสเงินสดจะนับเงินที่ไม่มีอยู่)';
end $$;

-- ============================================================
-- A3 · ด่าน 1 · ตั้งค่าเผื่อเกินยอดลูกหนี้รวม → ปฏิเสธ
--      (ลูกหนี้ 30,000 · ตั้งไว้แล้ว 10,000 → เพิ่มได้อีกไม่เกิน 20,000)
-- ============================================================
do $$
declare v uuid := '00000000-0000-0000-0000-0000000a0010';
begin
  perform pg_temp.must_fail_like('A3 ตั้งค่าเผื่อเพิ่ม 25,000 (รวมเป็น 35,000 > ลูกหนี้ 30,000)', format(
    $q$ select pg_temp.mk_allow(%L, 'THANAKORN', 25000) $q$, v),
    'มากกว่ายอดลูกหนี้รวม');
  if exists (select 1 from sri_os.transactions where id = v) then
    raise exception 'FAIL: A3 ใบที่ถูกปฏิเสธยังค้างอยู่ในสมุด';
  end if;

  -- พอดีเป๊ะต้องผ่าน — ด่านที่กันของที่พอดีคือกันแน่นเกิน
  perform pg_temp.must_pass('A3b ตั้งค่าเผื่อเพิ่ม 20,000 (รวมเป็น 30,000 = ลูกหนี้พอดี)', format(
    $q$ select pg_temp.mk_allow('00000000-0000-0000-0000-0000000a0011', 'THANAKORN', 20000) $q$));
  if pg_temp.net_receivable('THANAKORN') <> 0 then
    raise exception 'FAIL: A3b ลูกหนี้สุทธิควรเป็น 0 ได้ %', pg_temp.net_receivable('THANAKORN');
  end if;

  -- แล้วเพิ่มอีกบาทเดียวต้องไม่ได้ (ลูกหนี้สุทธิจะติดลบ)
  perform pg_temp.must_fail_like('A3c ตั้งค่าเผื่อเพิ่มอีก 1 บาทจากที่พอดีแล้ว', format(
    $q$ select pg_temp.mk_allow('00000000-0000-0000-0000-0000000a0012', 'THANAKORN', 1) $q$),
    'มากกว่ายอดลูกหนี้รวม');

  raise notice 'ok A3 · ค่าเผื่อเกินลูกหนี้ถูกปฏิเสธ · เท่ากันพอดีผ่าน · เกินอีกบาทเดียวก็ไม่ได้';
end $$;

-- ============================================================
-- A4 · ด่าน 2 · ตัดหนี้สูญเกินค่าเผื่อคงเหลือ → ปฏิเสธ
--      ตอนนี้ของ THANAKORN: ลูกหนี้ 30,000 · ค่าเผื่อ 30,000
-- ============================================================
do $$
declare v uuid := '00000000-0000-0000-0000-0000000a0020';
begin
  perform pg_temp.must_fail_like('A4 ตัดหนี้สูญ 30,001 ขณะที่ค่าเผื่อมี 30,000', format(
    $q$ select pg_temp.mk_writeoff(%L, 'THANAKORN', 30001) $q$, v),
    'ติดลบ');
  if exists (select 1 from sri_os.transactions where id = v) then
    raise exception 'FAIL: A4 ใบที่ถูกปฏิเสธยังค้างอยู่ในสมุด';
  end if;
  if pg_temp.allowance('THANAKORN') <> 30000 then
    raise exception 'FAIL: A4 ค่าเผื่อเพี้ยนหลังเคสที่ถูกปฏิเสธ: %', pg_temp.allowance('THANAKORN');
  end if;
  raise notice 'ok A4 · ตัดหนี้สูญเกินค่าเผื่อคงเหลือถูกปฏิเสธ — ผู้ใช้ต้องไปตั้งค่าเผื่อเพิ่มก่อน (ค่าใช้จ่ายจึงโผล่ชัดเจน)';
end $$;

-- ============================================================
-- A5 · ตัดหนี้สูญ **เท่ากับ** ค่าเผื่อพอดี → ผ่าน
-- A6 · และ **P&L ต้องไม่ขยับเลย** ← เคสสำคัญสุดของทั้งงาน
-- ============================================================
do $$
declare
  v_pl_before numeric := pg_temp.pl_net('THANAKORN');
  v_cf_before numeric := pg_temp.cf_cash('THANAKORN');
  v_id uuid := '00000000-0000-0000-0000-0000000a0021';
begin
  perform pg_temp.must_pass('A5 ตัดหนี้สูญ 30,000 เท่าค่าเผื่อพอดี', format(
    $q$ select pg_temp.mk_writeoff(%L, 'THANAKORN', 30000) $q$, v_id));

  -- (ก) ค่าเผื่อและลูกหนี้ถูกล้างคู่กันจนเหลือศูนย์ทั้งสองข้าง
  if pg_temp.allowance('THANAKORN') <> 0 then
    raise exception 'FAIL: A5 ค่าเผื่อคงเหลือควรเป็น 0 ได้ %', pg_temp.allowance('THANAKORN');
  end if;
  if pg_temp.net_receivable('THANAKORN') <> 0 then
    raise exception 'FAIL: A5 ลูกหนี้สุทธิควรเป็น 0 ได้ %', pg_temp.net_receivable('THANAKORN');
  end if;

  -- (ก2) ใบตัดหนี้สูญต้องไม่มีบรรทัด 5920 เลย (N3 จับที่นี่ด้วย)
  if exists (select 1 from sri_os.transaction_lines l
               join sri_os.chart_of_accounts c on c.id = l.coa_id
              where l.transaction_id = v_id and c.code = '5920') then
    raise exception 'FAIL: A5b ใบตัดหนี้สูญมีบรรทัด 5920 — ค่าใช้จ่ายถูกรับรู้สองรอบ (ตอนตั้งค่าเผื่อ + ตอนตัด)';
  end if;

  -- (ข) **P&L ห้ามขยับ** — ค่าใช้จ่ายรับรู้ไปแล้วตอนตั้งค่าเผื่อ
  if pg_temp.pl_net('THANAKORN') <> v_pl_before then
    raise exception 'FAIL: A6 ตัดหนี้สูญแล้ว P&L ขยับจาก % เป็น % — ค่าใช้จ่ายซ้ำสองเท่า กำไรต่ำกว่าจริง และงบดุลยังสมดุลทุกบรรทัดจึงไม่มีอะไรฟ้อง',
      v_pl_before, pg_temp.pl_net('THANAKORN');
  end if;

  -- (ค) งบกระแสเงินสดก็ไม่ขยับ
  if pg_temp.cf_cash('THANAKORN') <> v_cf_before then
    raise exception 'FAIL: A6 งบกระแสเงินสดขยับจาก % เป็น %', v_cf_before, pg_temp.cf_cash('THANAKORN');
  end if;

  raise notice 'ok A5/A6 · ตัดหนี้สูญเท่าค่าเผื่อพอดีผ่าน · ค่าเผื่อและลูกหนี้ล้างคู่กันเป็นศูนย์ · **P&L ไม่ขยับ** · งบกระแสเงินสดไม่ขยับ';
end $$;

-- ตัดต่อจากที่ค่าเผื่อหมดแล้ว → ปฏิเสธ (ยืนยันว่าด่านยังอยู่หลังล้างครบ)
do $$
begin
  perform pg_temp.must_fail_like('A5c ตัดหนี้สูญอีก 1 บาทตอนค่าเผื่อเหลือ 0', format(
    $q$ select pg_temp.mk_writeoff('00000000-0000-0000-0000-0000000a0022', 'THANAKORN', 1) $q$),
    'ติดลบ');
  raise notice 'ok A5c · ค่าเผื่อหมดแล้วตัดต่อไม่ได้';
end $$;

-- ============================================================
-- A7 · ด่าน 3 · กลับค่าเผื่อเกินกว่าที่ตั้งไว้ → ปฏิเสธ
-- A8 · กลับเท่าที่ตั้งไว้พอดี → ผ่าน และ P&L กลับที่เดิม
-- ============================================================
do $$
declare v_pl_base numeric;
begin
  perform pg_temp.must_pass('A8 ตั้งลูกหนี้ของสุธี 8,000', format(
    $q$ select pg_temp.mk_recv('00000000-0000-0000-0000-0000000a0030', 'SUTEE', 8000) $q$));
  v_pl_base := pg_temp.pl_net('SUTEE');

  perform pg_temp.must_pass('A8 ตั้งค่าเผื่อของสุธี 5,000', format(
    $q$ select pg_temp.mk_allow('00000000-0000-0000-0000-0000000a0031', 'SUTEE', 5000) $q$));
  if pg_temp.pl_net('SUTEE') <> v_pl_base + 5000 then
    raise exception 'FAIL: A8 ตั้งค่าเผื่อแล้ว P&L ต้องเพิ่มค่าใช้จ่าย 5000';
  end if;

  perform pg_temp.must_fail_like('A7 กลับค่าเผื่อ 5,001 ขณะที่ตั้งไว้ 5,000', format(
    $q$ select pg_temp.mk_release('00000000-0000-0000-0000-0000000a0032', 'SUTEE', 5001) $q$),
    'ติดลบ');

  perform pg_temp.must_pass('A8 กลับค่าเผื่อ 5,000 พอดี', format(
    $q$ select pg_temp.mk_release('00000000-0000-0000-0000-0000000a0033', 'SUTEE', 5000) $q$));
  if pg_temp.allowance('SUTEE') <> 0 then
    raise exception 'FAIL: A8 ค่าเผื่อควรกลับเป็น 0 ได้ %', pg_temp.allowance('SUTEE');
  end if;
  if pg_temp.pl_net('SUTEE') <> v_pl_base then
    raise exception 'FAIL: A8 กลับค่าเผื่อแล้ว P&L ต้องกลับที่เดิม (% ) ได้ %', v_pl_base, pg_temp.pl_net('SUTEE');
  end if;

  perform pg_temp.must_fail_like('A7b กลับค่าเผื่ออีก 1 บาทตอนเหลือ 0', format(
    $q$ select pg_temp.mk_release('00000000-0000-0000-0000-0000000a0034', 'SUTEE', 1) $q$),
    'ติดลบ');

  raise notice 'ok A7/A8 · กลับค่าเผื่อเกินที่ตั้งไว้ถูกปฏิเสธ · กลับพอดีผ่านและ P&L กลับที่เดิม (ไม่สร้างรายได้จากอากาศ)';
end $$;

-- ============================================================
-- A9 · ค่าเผื่อของผู้ถือคนหนึ่ง **ไม่ค้ำ** การตัดหนี้ของผู้ถืออีกคน
--      (ด่านตรวจต่อผู้ถือ ไม่ใช่ยอดรวมทั้งกองกลาง — ไม่งั้นค่าเผื่อของบริษัท
--       จะไปค้ำการตัดหนี้ของบุคคล แล้วงบของแต่ละผู้ถือผิดคนละทาง)
-- ============================================================
do $$
begin
  perform pg_temp.must_pass('A9 ตั้งลูกหนี้ของ SRI Holding 9,000', format(
    $q$ select pg_temp.mk_recv('00000000-0000-0000-0000-0000000a0040', 'SRI_HOLDING', 9000) $q$));
  perform pg_temp.must_pass('A9 ตั้งค่าเผื่อของ SRI Holding 9,000', format(
    $q$ select pg_temp.mk_allow('00000000-0000-0000-0000-0000000a0041', 'SRI_HOLDING', 9000) $q$));

  -- สุธีมีลูกหนี้ 8,000 แต่ค่าเผื่อเหลือ 0 (กลับไปแล้วใน A8) → ตัดไม่ได้
  perform pg_temp.must_fail_like('A9 สุธีตัดหนี้สูญโดยอาศัยค่าเผื่อของ SRI Holding', format(
    $q$ select pg_temp.mk_writeoff('00000000-0000-0000-0000-0000000a0042', 'SUTEE', 8000) $q$),
    'ติดลบ');
  raise notice 'ok A9 · ด่านตรวจต่อผู้ถือ ค่าเผื่อข้ามผู้ถือไม่ได้';
end $$;

-- ============================================================
-- A10 · void ใบที่ตั้งค่าเผื่อ แล้วค่าเผื่อต้องหายไปจากยอดที่ด่านใช้ตัดสิน
--       (ถ้าด่านไม่กรอง void ใบที่ยกเลิกแล้วจะยังค้ำการตัดหนี้สูญอยู่)
-- ============================================================
do $$
begin
  -- SRI Holding ตอนนี้: ลูกหนี้ 9,000 · ค่าเผื่อ 9,000
  perform pg_temp.upd(format(
    $q$ update sri_os.transactions set status = 'void'
         where id = '00000000-0000-0000-0000-0000000a0041' $q$));
  if pg_temp.allowance('SRI_HOLDING') <> 0 then
    raise exception 'FAIL: A10 void ใบตั้งค่าเผื่อแล้วค่าเผื่อควรเป็น 0 ได้ %', pg_temp.allowance('SRI_HOLDING');
  end if;

  perform pg_temp.must_fail_like('A10 ตัดหนี้สูญโดยอาศัยค่าเผื่อของใบที่ void แล้ว', format(
    $q$ select pg_temp.mk_writeoff('00000000-0000-0000-0000-0000000a0043', 'SRI_HOLDING', 9000) $q$),
    'ติดลบ');
  raise notice 'ok A10 · ค่าเผื่อของใบที่ void แล้วไม่ค้ำการตัดหนี้สูญ';
end $$;

-- ============================================================
-- A11 · ด่านฝั่งหัวรายการ — เส้นทางที่ **ไม่แตะ transaction_lines เลย**
--       → ด่านที่ผูกแค่บรรทัดจะไม่ยิง แล้วค่าเผื่อติดลบได้เงียบๆ
--
--       เส้นทางที่ใช้: `update transactions set status = 'void'` ของ **ใบตั้งค่าเผื่อ**
--       ทั้งที่เอาค่าเผื่อนั้นไปตัดหนี้สูญไปแล้ว → ค่าเผื่อหายไปแต่ลูกหนี้ที่ถูกตัดไม่กลับมา
--       = สินทรัพย์ปลอม (ลูกหนี้หายจากงบดุลโดยไม่มีค่าใช้จ่ายรับรู้เลย)
--
--       ใช้ผู้ถือ **personal_flexible** (สุธี) โดยตั้งใจ: ฝั่ง corporate_strict
--       ถูก fn_corporate_immutable ปฏิเสธก่อนถึงด่านนี้ → เคสที่เขียนกับบริษัท
--       จะ "ผ่าน" ด้วยเหตุผลของด่านอื่น แล้วรายงาน mutation ชี้ผิดจุด
--       (ถอดด่านฝั่งหัวรายการออกแล้วเคสนั้นก็ยังเขียว = เทสต์ที่ไม่ได้ตรวจอะไร)
--
--       **ทางกลับกันไม่มี**: void → posted ถูกปฏิเสธอยู่แล้วทุกกรณี
--       (20261008000004 · "void คือสถานะปลายทาง") จึงไม่ใช่ช่องที่ไฟล์นี้ต้องปิด
-- ============================================================
do $$
begin
  -- สุธีตอนนี้: ลูกหนี้ 8,000 · ค่าเผื่อ 0 (ตั้ง 5,000 แล้วกลับคืนหมดใน A8)
  perform pg_temp.must_pass('A11 ตั้งค่าเผื่อ 8,000', format(
    $q$ select pg_temp.mk_allow('00000000-0000-0000-0000-0000000a0036', 'SUTEE', 8000) $q$));
  perform pg_temp.must_pass('A11 ตัดหนี้สูญ 8,000 (ใช้ค่าเผื่อนั้นหมด)', format(
    $q$ select pg_temp.mk_writeoff('00000000-0000-0000-0000-0000000a0037', 'SUTEE', 8000) $q$));
  if pg_temp.allowance('SUTEE') <> 0 or pg_temp.net_receivable('SUTEE') <> 0 then
    raise exception 'FAIL: A11 ค่าเผื่อ/ลูกหนี้ควรเป็น 0 ทั้งคู่ ได้ % / %',
      pg_temp.allowance('SUTEE'), pg_temp.net_receivable('SUTEE');
  end if;

  -- (ก) ยกเลิกใบ **ตั้งค่าเผื่อ** ทั้งที่ใบตัดหนี้สูญยังอยู่ → ค่าเผื่อติดลบ → ต้องปฏิเสธ
  perform pg_temp.must_fail_like('A11 void ใบตั้งค่าเผื่อ ขณะที่ใบตัดหนี้สูญยังอยู่',
    $q$ select pg_temp.upd($i$ update sri_os.transactions set status = 'void'
            where id = '00000000-0000-0000-0000-0000000a0036' $i$) $q$,
    'ติดลบ');
  if pg_temp.allowance('SUTEE') <> 0 then
    raise exception 'FAIL: A11 ใบที่ถูกปฏิเสธยังมีผลต่อยอดค่าเผื่อ: %', pg_temp.allowance('SUTEE');
  end if;

  -- (ข) ห้ามกันแน่นเกิน: ยกเลิกใบ **ตัดหนี้สูญ** ก่อน ทำได้ (ค่าเผื่อกลับมามีของรองรับ)
  perform pg_temp.must_pass('A11 void ใบตัดหนี้สูญ (ลำดับที่ถูกต้อง)',
    $q$ select pg_temp.upd($i$ update sri_os.transactions set status = 'void'
            where id = '00000000-0000-0000-0000-0000000a0037' $i$) $q$);
  if pg_temp.allowance('SUTEE') <> 8000 or pg_temp.net_receivable('SUTEE') <> 0 then
    raise exception 'FAIL: A11 หลัง void ใบตัดหนี้สูญ ค่าเผื่อควรเป็น 8000 และลูกหนี้สุทธิ 0 ได้ % / %',
      pg_temp.allowance('SUTEE'), pg_temp.net_receivable('SUTEE');
  end if;

  raise notice 'ok A11 · การเปลี่ยนสถานะหัวรายการถูกตรวจด้วย (ไม่แตะบรรทัดเลยก็เลี่ยงด่านไม่ได้) · ลำดับยกเลิกที่ถูกต้องยังทำได้';
end $$;

-- ============================================================
-- A12 · กฎเงินต้องไม่ขึ้นกับสิทธิ์ — เดินเส้นทางเดียวกันด้วย role authenticated
-- ============================================================
do $$
begin
  perform set_config('test.uid', pg_temp.auid('a_mgmt')::text, true);
  execute 'set local role authenticated';

  -- สุธีตอนนี้: ค่าเผื่อ 8,000 · ลูกหนี้ 8,000 → ตัด 8,001 คือเกินค่าเผื่อไป 1 บาท
  perform pg_temp.must_fail_like('A12 ตัดหนี้สูญเกินค่าเผื่อ 1 บาท (authenticated)', format(
    $q$ select pg_temp.mk_writeoff('00000000-0000-0000-0000-0000000a0050', 'SUTEE', 8001) $q$),
    'ติดลบ');

  execute 'reset role';
  raise notice 'ok A12 · ด่านเดียวกันทำงานกับ role authenticated ด้วย (ไม่ได้ผ่านเพราะรันเป็น superuser)';
end $$;

-- ============================================================
-- A13 · ห้ามกันแน่นเกิน — รายการเงินปกติของผู้ถือที่มีค่าเผื่ออยู่ ต้องยังลงได้
-- ============================================================
do $$
begin
  perform pg_temp.must_pass('A13 ตั้งลูกหนี้ใหม่ของสุธี 4,000 (มีค่าเผื่อ 8,000 อยู่แล้ว)', format(
    $q$ select pg_temp.mk_recv('00000000-0000-0000-0000-0000000a0060', 'SUTEE', 4000) $q$));
  perform pg_temp.must_pass('A13 ตั้งค่าเผื่อ 2,000 แล้วตัด 2,000 ในสองใบติดกัน', format(
    $q$ select pg_temp.mk_allow('00000000-0000-0000-0000-0000000a0061', 'SUTEE', 2000) $q$));
  perform pg_temp.must_pass('A13 ตัดหนี้สูญ 2,000', format(
    $q$ select pg_temp.mk_writeoff('00000000-0000-0000-0000-0000000a0062', 'SUTEE', 2000) $q$));
  raise notice 'ok A13 · เส้นทางที่ถูกต้องยังทำได้ครบ (ด่านไม่ได้กันแน่นเกิน)';
end $$;

-- ---------- สรุป: ทุกใบที่ไฟล์นี้สร้างต้องผ่านด่านที่เลื่อนไว้จริง ----------
do $$
declare n int;
begin
  set constraints all immediate;
  select count(*) into n from sri_os.transactions where memo like 'AL %';
  if n < 12 then
    raise exception 'FAIL: นับใบที่เทสต์นี้สร้างได้แค่ % ใบ — เทสต์อาจไม่ได้ลงอะไรเลย', n;
  end if;
  raise notice 'ok A · ทั้ง % ใบของไฟล์นี้ผ่านด่านที่เลื่อนไว้ (เคสปฏิเสธไม่ทิ้งใบเสียรูปไว้)', n;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: ใบที่เทสต์นี้สร้างไว้เสียรูป: %', sqlerrm;
end $$;

rollback;
