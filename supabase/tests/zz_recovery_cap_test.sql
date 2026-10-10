-- ============================================================
-- SRI OS · เทสต์ของ 20261010000001_recovery_cap_and_delta.sql
--   (สามรูที่ผู้ตรวจ BLOCK รอบสอง · ของเดิมอยู่ใน zz_allowance_test.sql
--    กับ zz_allowance_fixes_test.sql ซึ่งยังต้องเขียวทั้งไฟล์)
--
-- ------------------------------------------------------------
-- รูที่ 1 · "หนี้สูญได้รับคืน" ใช้กับลูกหนี้ที่ยังไม่ตัดหนี้สูญได้ — ร้ายแรงสุด
-- ------------------------------------------------------------
-- 20261009000004 เพิ่มหมวด `inc.bad_debt_recovered` (Dr เงินสด / Cr 4320) เป็น
--   "ทางกลับ" ของการตัดหนี้สูญ แต่ **ไม่มีด่านไหนบังคับว่าต้องตัดหนี้สูญมาก่อน**
--   → ตั้งลูกหนี้ 30,000 แล้วลงหมวดนี้ 30,000 ได้เลย
--     = กำไร 60,000 (รายได้ค่าเช่า 30,000 + หนี้สูญได้รับคืน 30,000)
--       ขณะที่เก็บเงินได้จริง 30,000 · และลูกหนี้ 1200 ค้างอยู่ 30,000 **ตลอดไป**
--   → หรือลงหมวดนี้ 500,000 โดยไม่มีประวัติอะไรเลยก็ได้ = รายได้จากอากาศ
--
-- ด่านใหม่: เครดิต 4320 **สะสม** ต่อผู้ถือ ห้ามเกิน **ยอดตัดหนี้สูญสะสม** ต่อผู้ถือ
--
-- "ยอดตัดหนี้สูญสะสม" หาโดย **ไม่เช็ครหัสหมวด** (กฎ CLAUDE.md): เดบิต 1290
--   เกิดได้สองทางคือตัดหนี้สูญ (คู่กับเครดิตลูกหนี้) และกลับค่าเผื่อ (คู่กับเครดิต 5920)
--   → แยกด้วย **บัญชีคู่ในใบเดียวกัน** ไม่ใช่ด้วยรหัสหมวด
--   R4 คือเคสที่บังคับเรื่องนี้: กลับค่าเผื่อ 10,000 แล้วรับคืน 1 บาทต้องยังถูกปฏิเสธ
--
-- ------------------------------------------------------------
-- รูที่ 2 · `new is not null` ทำให้ d่านระดับบรรทัดตาบอด
-- ------------------------------------------------------------
-- `ROW IS NOT NULL` ของ Postgres เป็นจริงเฉพาะเมื่อ **ทุกคอลัมน์ไม่เป็น null**
--   แถวของ transaction_lines มีคอลัมน์ null เกือบทุกแถว (bank_account_id · asset_id)
--   → เงื่อนไขเป็น false ตลอด → `v_delta` = 0 → ด่านระดับบรรทัดส่ง 'other' ทุกครั้ง
-- ผลสองอย่างที่รันยืนยันแล้ว:
--   (ก) R6 · ตั้งค่าเผื่อ 1,000 แล้ว UPDATE บรรทัดเป็น 900,000 → **ผ่าน** ทั้งที่
--       ลงตรงๆ 900,000 ถูกปฏิเสธ (cap มาจาก trigger หัวรายการเท่านั้น)
--   (ข) R7 · ข้อความเลือกสาขาผิด: เอาค่าเผื่อออกเกินได้ข้อความสาขา "void ใบตั้งค่าเผื่อ"
--       ที่บอกว่า "ตั้งค่าเผื่อเพิ่มไม่ช่วย" ทั้งที่ทางแก้ที่ถูกคือตั้งค่าเผื่อเพิ่ม
--
-- ------------------------------------------------------------
-- needle ของเทสต์ต้องแยกสาขาได้จริง
-- ------------------------------------------------------------
-- F7a เดิมเขียวทั้งที่ข้อความผิดสาขา เพราะ needle 'ตั้งค่าเผื่อ' มีอยู่ใน
--   **ทั้งสองข้อความ** → เทสต์ผ่านด้วยเหตุผลที่ผิด
-- ไฟล์นี้ (และ needle ที่แก้ใน zz_allowance_test / zz_allowance_fixes_test)
--   ใช้คำที่มีอยู่ใน **สาขาเดียว** เสมอ และคู่กับ must_fail_without ของอีกสาขา
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ rollback ปิดท้าย — ไม่ทิ้งรายการเงินไว้
--   ด่านเป็น constraint trigger ที่เลื่อนไว้ → ทุกเคสยิงเองผ่าน pg_temp.fire()
--
-- mutation ที่ต้องทำให้เทสต์แดง (ถ้าไม่แดง = เทสต์ยังไม่ครอบ)
--   R1 ถอด cap ของ 4320 (ไม่เรียก fn_assert_recovery_within_writeoff)
--        → R1 R1b R2 R3 R4 R5 R9 แดง
--   R2 นับ "กลับค่าเผื่อ" เป็นยอดตัดหนี้สูญด้วย (ตัดเงื่อนไขบัญชีคู่ในใบออก)
--        → R4 แดง
--   R3 คืน `new is not null` ใน fn_allowance_guard
--        → R6 แดง (UPDATE 900,000 ผ่าน) · R0 แดงที่เงื่อนไขซอร์ส
--   R4 คืนข้อความให้เลือกสาขาผิด (หัวรายการเหมาเป็น 'other' / ด่านรับคืนมีข้อความเดียว)
--        → R5 R7 แดง · F7a แดง
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
create temporary table t_rcuid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_rcuid(label) values ('rc_mgmt');
insert into auth.users(id) select id from t_rcuid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select id, label || '@recovery.local', label, 'management', true from t_rcuid;
insert into sri_os.user_owner_access(user_id, owner_id)
select (select id from t_rcuid where label = 'rc_mgmt'), o.id from sri_os.owners o;

create or replace function pg_temp.fuid(p_label text) returns uuid
language sql stable as $fn$ select id from t_rcuid where label = p_label $fn$;

create or replace function pg_temp.coa(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.chart_of_accounts where code = p_code $fn$;

create or replace function pg_temp.own(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.owners where code = p_code $fn$;

insert into sri_os.contacts(id, first_name, types)
values ('00000000-0000-0000-0000-0000000fac02', 'ลูกหนี้ RC', array['tenant'])
on conflict do nothing;

-- บัญชีธนาคารจริงต่อผู้ถือ — Money Invariant 2 บังคับว่าขาเงินสดต้องผูกบัญชี
insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
select x.id, pg_temp.own(x.own), x.bank, x.nm, x.nm
  from (values
    ('00000000-0000-0000-0000-0000000cc001'::uuid, 'SUTEE',     'BBL',   'RC สุธี'),
    ('00000000-0000-0000-0000-0000000cc002'::uuid, 'THANAKORN', 'KBANK', 'RC ธนากร'),
    ('00000000-0000-0000-0000-0000000cc003'::uuid, 'THANAWIN',  'SCB',   'RC ธนวินท์'),
    ('00000000-0000-0000-0000-0000000cc004'::uuid, 'SUDJIT',    'KTB',   'RC สุดจิตต์'),
    ('00000000-0000-0000-0000-0000000cc005'::uuid, 'BENJAPORN', 'TTB',   'RC เบ็ญจพร')
  ) as x(id, own, bank, nm);

-- ------------------------------------------------------------
-- ตัวช่วย (แพทเทิร์นเดียวกับ zz_allowance_fixes_test)
-- ------------------------------------------------------------
create or replace function pg_temp.must_fail_like(p_label text, p_sql text, p_needle text) returns void
language plpgsql as $fn$
declare v text;
begin
  begin
    execute p_sql;
    raise exception 'RC_UNEXPECTED_SUCCESS';
  exception when others then
    v := sqlerrm;
    if v = 'RC_UNEXPECTED_SUCCESS' then
      raise exception 'FAIL: % — คำสั่งควรถูกปฏิเสธแต่สำเร็จ', p_label;
    end if;
    if v like 'FAIL:%' then raise; end if;
    if position(p_needle in v) = 0 then
      raise exception 'FAIL: % — ปฏิเสธถูกแต่ข้อความไม่มี "%" · ได้: %', p_label, p_needle, v;
    end if;
  end;
end $fn$;

/** ปฏิเสธถูก แต่ข้อความ **ต้องไม่มี** คำที่ชี้ทางแก้ของอีกสาขา (รูที่ 2ข) */
create or replace function pg_temp.must_fail_without(p_label text, p_sql text, p_needle text) returns void
language plpgsql as $fn$
declare v text;
begin
  begin
    execute p_sql;
    raise exception 'RC_UNEXPECTED_SUCCESS';
  exception when others then
    v := sqlerrm;
    if v = 'RC_UNEXPECTED_SUCCESS' then
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
  values (p_id, pg_temp.own(p_owner), p_type, current_date, p_cash, 'RC ' || p_id::text,
          array['รายงานอายุลูกหนี้.pdf'], '00000000-0000-0000-0000-0000000fac02');
  for r in select * from jsonb_array_elements(p_lines) loop
    insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id,
                                         debit, credit, cf_category, memo)
    values (p_id, pg_temp.coa(r ->> 'coa'), (r ->> 'bank')::uuid,
            coalesce((r ->> 'dr')::numeric, 0), coalesce((r ->> 'cr')::numeric, 0),
            coalesce(r ->> 'cf', 'none')::sri_os.cf_group, 'RC บรรทัด');
  end loop;
  perform pg_temp.fire();
  return p_id;
end $fn$;

create or replace function pg_temp.bank(p_owner text) returns uuid
language sql stable as $fn$
  select id from sri_os.bank_accounts where owner_id = pg_temp.own(p_owner) and display_name like 'RC %'
$fn$;

-- ตั้งลูกหนี้ค่าเช่าค้างรับ (Dr 1200 / Cr 4200)
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

-- ตัดหนี้สูญค่าเช่า (Dr 1290 / Cr 1200) — **ใบที่นับเป็นยอดตัดหนี้สูญ**
create or replace function pg_temp.mk_writeoff(p_id uuid, p_owner text, p_amt numeric) returns uuid
language sql as $fn$
  select pg_temp.mk(p_id, p_owner, 'adj.writeoff_rent', null,
    jsonb_build_array(jsonb_build_object('coa', '1290', 'dr', p_amt, 'cr', 0),
                      jsonb_build_object('coa', '1200', 'dr', 0, 'cr', p_amt)))
$fn$;

-- กลับค่าเผื่อ (Dr 1290 / Cr 5920) — **ห้ามนับเป็นยอดตัดหนี้สูญ**
create or replace function pg_temp.mk_release(p_id uuid, p_owner text, p_amt numeric) returns uuid
language sql as $fn$
  select pg_temp.mk(p_id, p_owner, 'adj.doubtful_release', null,
    jsonb_build_array(jsonb_build_object('coa', '1290', 'dr', p_amt, 'cr', 0),
                      jsonb_build_object('coa', '5920', 'dr', 0, 'cr', p_amt)))
$fn$;

-- รับชำระค่าเช่าค้างรับ (Dr 1100 / Cr 1200) — ทางที่ถูกเมื่อลูกหนี้ยังอยู่ในสมุด
create or replace function pg_temp.mk_collect(p_id uuid, p_owner text, p_amt numeric) returns uuid
language sql as $fn$
  select pg_temp.mk(p_id, p_owner, 'inv.collect_rent', current_date,
    jsonb_build_array(
      jsonb_build_object('coa', '1100', 'dr', p_amt, 'cr', 0, 'cf', 'operating',
                         'bank', pg_temp.bank(p_owner)),
      jsonb_build_object('coa', '1200', 'dr', 0, 'cr', p_amt)))
$fn$;

-- หนี้สูญได้รับคืน (Dr 1100 / Cr 4320) — หมวดที่ไฟล์นี้ใส่ cap ให้
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

/** หนี้สูญได้รับคืนสะสม (เครดิตสุทธิของ 4320) — ตัวที่ด่านใหม่ cap ไว้ */
create or replace function pg_temp.recovered(p_owner text) returns numeric
language sql stable as $fn$
  select coalesce(sum(l.credit - l.debit), 0)
    from sri_os.transactions t
    join sri_os.transaction_lines l on l.transaction_id = t.id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where t.owner_id = pg_temp.own(p_owner) and t.status <> 'void' and c.code = '4320'
$fn$;

/** เดบิต 1290 **ทั้งหมด** (ตัดหนี้สูญ + กลับค่าเผื่อ) — ตัวที่ **ห้าม** ใช้เป็น cap */
create or replace function pg_temp.debit_1290(p_owner text) returns numeric
language sql stable as $fn$
  select coalesce(sum(l.debit - l.credit), 0)
    from sri_os.transactions t
    join sri_os.transaction_lines l on l.transaction_id = t.id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where t.owner_id = pg_temp.own(p_owner) and t.status <> 'void' and c.code = '1290'
$fn$;

-- ============================================================
-- R0 · โครงสร้าง — ไล่จาก catalog จริง
-- ============================================================
do $$
declare v text; v_type int; v_defer boolean; v_init boolean; v_con oid; n int; v_src text;
begin
  -- ด่านทั้งสองยังต้องเป็น constraint trigger ที่เลื่อนไว้ · AFTER (ไฟล์ใหม่ห้ามทำของเดิมหาย)
  foreach v in array array['transaction_lines|trg_lines_allowance_limits',
                           'transactions|trg_txn_allowance_limits'] loop
    select t.tgtype, t.tgdeferrable, t.tginitdeferred, t.tgconstraint
      into v_type, v_defer, v_init, v_con
      from pg_trigger t
     where t.tgrelid = ('sri_os.' || split_part(v, '|', 1))::regclass
       and t.tgname = split_part(v, '|', 2);
    if v_type is null then
      raise exception 'FAIL: R0 ไม่มี trigger %', v;
    end if;
    if not (v_defer and v_init and v_con <> 0) then
      raise exception 'FAIL: R0 ด่าน % ไม่ใช่ constraint trigger (deferrable initially deferred)', v;
    end if;
    if (v_type & 2) <> 0 then
      raise exception 'FAIL: R0 ด่าน % เป็น BEFORE ต้องเป็น AFTER', v;
    end if;
  end loop;

  -- ด่านใหม่ของรูที่ 1 ต้องเป็นฟังก์ชันของตัวเอง ตัวเดียว (เรียกแยกจากรายงาน data health ได้)
  select count(*) into n from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_assert_recovery_within_writeoff';
  if n <> 1 then
    raise exception 'FAIL: R0 ต้องมี sri_os.fn_assert_recovery_within_writeoff ตัวเดียว (ได้ %) — ไม่มีด่านนี้ = ลงหนี้สูญได้รับคืนโดยไม่เคยตัดหนี้สูญได้', n;
  end if;

  -- และต้องถูกเรียกจาก **ทั้งสอง** ด่าน (บรรทัด + หัวรายการ)
  -- void ใบตัดหนี้สูญไม่แตะบรรทัดเลย → ด่านที่ผูกแค่บรรทัดจะไม่ยิง
  for v in select unnest(array['fn_allowance_guard', 'fn_txn_allowance_guard']) loop
    select p.prosrc into v_src from pg_proc p
      join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'sri_os' and p.proname = v;
    if v_src not like '%fn_assert_recovery_within_writeoff%' then
      raise exception 'FAIL: R0 % ไม่เรียก fn_assert_recovery_within_writeoff', v;
    end if;
  end loop;

  -- ด่านระดับบรรทัดต้องมอง 4320 ด้วย ไม่ใช่แค่ 1290/ลูกหนี้
  select p.prosrc into v_src from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_allowance_guard';
  if v_src not like '%4320%' then
    raise exception 'FAIL: R0 fn_allowance_guard ไม่ได้มอง 4320 — บรรทัดหนี้สูญได้รับคืนจะไม่ปลุกด่านเลย';
  end if;

  -- **กับดัก ROW IS NOT NULL** · ห้ามใช้ `new is not null` ถามว่า "มีแถวนี้ไหม"
  -- (เป็นจริงเฉพาะเมื่อทุกคอลัมน์ไม่เป็น null → แถวจริงเกือบทุกแถวตอบ false)
  for v in select unnest(array['fn_allowance_guard', 'fn_txn_allowance_guard']) loop
    select p.prosrc into v_src from pg_proc p
      join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'sri_os' and p.proname = v;
    if v_src ~* '\m(new|old)\s+is\s+(not\s+)?null\M' then
      raise exception 'FAIL: R0 % ยังใช้ "row is [not] null" ถามว่ามีแถวนี้ไหม — ROW IS NOT NULL เป็นจริงเฉพาะเมื่อทุกคอลัมน์ไม่เป็น null ต้องใช้ tg_op แทน', v;
    end if;
  end loop;

  -- กฎเงินห้ามขึ้นกับสิทธิ์
  select count(*) into n from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.proname in ('fn_assert_allowance_limits', 'fn_assert_receivable_not_negative',
                       'fn_assert_recovery_within_writeoff',
                       'fn_allowance_guard', 'fn_txn_allowance_guard')
     and p.prosrc like '%fn_can%';
  if n > 0 then
    raise exception 'FAIL: R0 ด่านเรียกฟังก์ชันตรวจสิทธิ์ — กฎเงินต้องปิดไม่ได้จากหน้า Settings';
  end if;

  raise notice 'ok R0 · มีด่าน fn_assert_recovery_within_writeoff ตัวเดียว · ถูกเรียกจากทั้งบรรทัดและหัวรายการ · ไม่มี row is not null เหลืออยู่';
end $$;

-- ============================================================
-- R1 · **เคสของรูที่ 1 ตรงๆ** · ตั้งลูกหนี้ 30,000 แล้วลง "หนี้สูญได้รับคืน"
--      30,000 โดย **ไม่เคยตัดหนี้สูญ** → ต้องปฏิเสธ
--      (ของเดิมผ่าน → กำไร 60,000 และลูกหนี้ 1200 ค้าง 30,000 ตลอดไป)
-- ============================================================
do $$
declare v uuid := '00000000-0000-0000-0000-0000000e0002'; v_pl numeric;
begin
  perform pg_temp.must_pass('R1 ตั้งลูกหนี้ค่าเช่าค้างรับของสุธี 30,000', format(
    $q$ select pg_temp.mk_recv('00000000-0000-0000-0000-0000000e0001', 'SUTEE', 30000) $q$));
  v_pl := pg_temp.pl_profit('SUTEE');

  perform pg_temp.must_fail_like('R1 ลงหนี้สูญได้รับคืน 30,000 โดยยังไม่เคยตัดหนี้สูญ', format(
    $q$ select pg_temp.mk_recovered(%L, 'SUTEE', 30000) $q$, v),
    'หมวดนี้ใช้ได้เฉพาะหนี้ที่ถูกตัดหนี้สูญไปแล้ว');

  -- ข้อความต้องเป็นสาขา "รับคืนเกินยอดที่ตัด" ไม่ใช่สาขา "ใบตัดหนี้สูญถูกเอาออก"
  perform pg_temp.must_fail_without('R1 ข้อความห้ามชี้ทางแก้ของอีกสถานการณ์', format(
    $q$ select pg_temp.mk_recovered('00000000-0000-0000-0000-0000000e0003', 'SUTEE', 30000) $q$),
    'ต้องกลับรายการหรือยกเลิกใบหนี้สูญได้รับคืนนั้นก่อน');

  if exists (select 1 from sri_os.transactions where id = v) then
    raise exception 'FAIL: R1 ใบที่ถูกปฏิเสธยังค้างอยู่ในสมุด';
  end if;
  -- กำไรต้องยังเป็น 30,000 ไม่ใช่ 60,000 · และลูกหนี้ยังอยู่ครบ (ไม่ค้างเพราะใบผี)
  if pg_temp.pl_profit('SUTEE') <> v_pl then
    raise exception 'FAIL: R1 กำไรขยับจาก % เป็น % — รายได้ถูกนับสองรอบ', v_pl, pg_temp.pl_profit('SUTEE');
  end if;
  if pg_temp.receivable('SUTEE', '1200') <> 30000 or pg_temp.recovered('SUTEE') <> 0 then
    raise exception 'FAIL: R1 ยอดเพี้ยนหลังเคสที่ถูกปฏิเสธ: ลูกหนี้ % · รับคืน %',
      pg_temp.receivable('SUTEE', '1200'), pg_temp.recovered('SUTEE');
  end if;

  raise notice 'ok R1 · รับคืนหนี้สูญโดยไม่เคยตัดหนี้สูญถูกปฏิเสธ · กำไรไม่ถูกนับสองรอบ · ลูกหนี้ไม่ค้าง';
end $$;

-- R1b · ไม่มีประวัติอะไรเลยแล้วลง 500,000 → ปฏิเสธ (รายได้จากอากาศ + สินทรัพย์ลวง)
do $$
begin
  perform pg_temp.must_fail_like('R1b เบ็ญจพรลงหนี้สูญได้รับคืน 500,000 โดยไม่มีประวัติเลย', format(
    $q$ select pg_temp.mk_recovered('00000000-0000-0000-0000-0000000e0004', 'BENJAPORN', 500000) $q$),
    'หมวดนี้ใช้ได้เฉพาะหนี้ที่ถูกตัดหนี้สูญไปแล้ว');
  if pg_temp.pl_profit('BENJAPORN') <> 0 then
    raise exception 'FAIL: R1b P&L ของเบ็ญจพรต้องยังเป็น 0 ได้ %', pg_temp.pl_profit('BENJAPORN');
  end if;
  raise notice 'ok R1b · ลงหมวดนี้โดยไม่มีประวัติตัดหนี้สูญเลยถูกปฏิเสธ';
end $$;

-- R1c · **ห้ามกันแน่นเกิน** · ลูกหนี้ยังอยู่ในสมุด → ทางที่ถูกคือรับชำระค้างรับ ต้องผ่าน
do $$
declare v_pl numeric := pg_temp.pl_profit('SUTEE');
begin
  perform pg_temp.must_pass('R1c รับชำระค่าเช่าค้างรับ 30,000 (ทางที่ถูกเมื่อยังไม่ได้ตัดหนี้สูญ)', format(
    $q$ select pg_temp.mk_collect('00000000-0000-0000-0000-0000000e0005', 'SUTEE', 30000) $q$));
  if pg_temp.receivable('SUTEE', '1200') <> 0 then
    raise exception 'FAIL: R1c ลูกหนี้ควรลดเป็น 0 ได้ %', pg_temp.receivable('SUTEE', '1200');
  end if;
  if pg_temp.pl_profit('SUTEE') <> v_pl then
    raise exception 'FAIL: R1c รับชำระค้างรับไม่ใช่รายได้ใหม่ แต่ P&L ขยับจาก % เป็น %',
      v_pl, pg_temp.pl_profit('SUTEE');
  end if;
  raise notice 'ok R1c · ด่านใหม่ไม่ได้ปิดทางที่ถูก (รับชำระค้างรับยังลงได้ตามปกติ)';
end $$;

-- ============================================================
-- R2 · ตัดหนี้สูญ 30,000 → รับคืน 30,000 **ผ่าน** · 30,001 **ปฏิเสธ**
-- ============================================================
do $$
declare v_pl numeric;
begin
  perform pg_temp.must_pass('R2 ตั้งลูกหนี้ของธนากร 30,000', format(
    $q$ select pg_temp.mk_recv('00000000-0000-0000-0000-0000000e0010', 'THANAKORN', 30000) $q$));
  perform pg_temp.must_pass('R2 ตั้งค่าเผื่อ 30,000', format(
    $q$ select pg_temp.mk_allow('00000000-0000-0000-0000-0000000e0011', 'THANAKORN', 30000) $q$));
  perform pg_temp.must_pass('R2 ตัดหนี้สูญ 30,000', format(
    $q$ select pg_temp.mk_writeoff('00000000-0000-0000-0000-0000000e0012', 'THANAKORN', 30000) $q$));

  -- เกินไปบาทเดียวก็ไม่ได้
  perform pg_temp.must_fail_like('R2 รับคืน 30,001 เกินยอดที่ตัดไป 30,000', format(
    $q$ select pg_temp.mk_recovered('00000000-0000-0000-0000-0000000e0013', 'THANAKORN', 30001) $q$),
    'หมวดนี้ใช้ได้เฉพาะหนี้ที่ถูกตัดหนี้สูญไปแล้ว');

  v_pl := pg_temp.pl_profit('THANAKORN');
  -- **พอดีเป๊ะต้องผ่าน** — ด่านที่กันของที่พอดีคือกันแน่นเกิน
  perform pg_temp.must_pass('R2 รับคืน 30,000 พอดีเท่ายอดที่ตัดไป', format(
    $q$ select pg_temp.mk_recovered('00000000-0000-0000-0000-0000000e0014', 'THANAKORN', 30000) $q$));
  if pg_temp.pl_profit('THANAKORN') <> v_pl + 30000 then
    raise exception 'FAIL: R2 กำไรควรเพิ่ม 30000 ได้ %', pg_temp.pl_profit('THANAKORN') - v_pl;
  end if;
  if pg_temp.receivable('THANAKORN', '1200') <> 0 then
    raise exception 'FAIL: R2 หมวดนี้ห้ามกลับไปแตะลูกหนี้ ได้ %', pg_temp.receivable('THANAKORN', '1200');
  end if;

  -- แล้วเกินอีกบาทเดียวไม่ได้
  perform pg_temp.must_fail_like('R2 รับคืนอีก 1 บาทหลังรับคืนครบแล้ว', format(
    $q$ select pg_temp.mk_recovered('00000000-0000-0000-0000-0000000e0015', 'THANAKORN', 1) $q$),
    'หมวดนี้ใช้ได้เฉพาะหนี้ที่ถูกตัดหนี้สูญไปแล้ว');

  raise notice 'ok R2 · รับคืนเท่ายอดที่ตัดไปผ่าน · เกินไปบาทเดียวถูกปฏิเสธทั้งก่อนและหลัง';
end $$;

-- ============================================================
-- R3 · รับคืนเป็นงวด · 10,000 สองครั้งผ่าน · ครั้งที่สามที่เกินถูกปฏิเสธ
--      (cap เป็น **ยอดสะสม** ไม่ใช่เทียบใบต่อใบ)
-- ============================================================
do $$
begin
  perform pg_temp.must_pass('R3 ตั้งลูกหนี้ของธนวินท์ 30,000', format(
    $q$ select pg_temp.mk_recv('00000000-0000-0000-0000-0000000e0020', 'THANAWIN', 30000) $q$));
  perform pg_temp.must_pass('R3 ตั้งค่าเผื่อ 30,000', format(
    $q$ select pg_temp.mk_allow('00000000-0000-0000-0000-0000000e0021', 'THANAWIN', 30000) $q$));
  perform pg_temp.must_pass('R3 ตัดหนี้สูญ 30,000', format(
    $q$ select pg_temp.mk_writeoff('00000000-0000-0000-0000-0000000e0022', 'THANAWIN', 30000) $q$));

  perform pg_temp.must_pass('R3 รับคืนงวดที่ 1 · 10,000', format(
    $q$ select pg_temp.mk_recovered('00000000-0000-0000-0000-0000000e0023', 'THANAWIN', 10000) $q$));
  perform pg_temp.must_pass('R3 รับคืนงวดที่ 2 · 10,000', format(
    $q$ select pg_temp.mk_recovered('00000000-0000-0000-0000-0000000e0024', 'THANAWIN', 10000) $q$));
  if pg_temp.recovered('THANAWIN') <> 20000 then
    raise exception 'FAIL: R3 รับคืนสะสมควรเป็น 20000 ได้ %', pg_temp.recovered('THANAWIN');
  end if;

  -- งวดที่ 3 ที่ทำให้สะสมเกิน → ปฏิเสธ
  perform pg_temp.must_fail_like('R3 รับคืนงวดที่ 3 · 10,001 (สะสมเกิน 30,000)', format(
    $q$ select pg_temp.mk_recovered('00000000-0000-0000-0000-0000000e0025', 'THANAWIN', 10001) $q$),
    'หมวดนี้ใช้ได้เฉพาะหนี้ที่ถูกตัดหนี้สูญไปแล้ว');
  -- แต่พอดีเป๊ะยังผ่าน
  perform pg_temp.must_pass('R3 งวดที่ 3 · 10,000 พอดีเต็มยอดที่ตัดไป', format(
    $q$ select pg_temp.mk_recovered('00000000-0000-0000-0000-0000000e0026', 'THANAWIN', 10000) $q$));
  if pg_temp.recovered('THANAWIN') <> 30000 then
    raise exception 'FAIL: R3 รับคืนสะสมควรเป็น 30000 ได้ %', pg_temp.recovered('THANAWIN');
  end if;

  raise notice 'ok R3 · cap เป็นยอดสะสมต่อผู้ถือ · รับคืนเป็นงวดได้จนครบ แล้วเกินไม่ได้';
end $$;

-- ============================================================
-- R4 · **กลับค่าเผื่อไม่ใช่การตัดหนี้สูญ** · เดบิต 1290 เหมือนกันแต่คู่กับ 5920
--      → แยกด้วยบัญชีคู่ในใบเดียวกัน ไม่ใช่ด้วยรหัสหมวด
--      (mutation R2: ถ้านับเดบิต 1290 ทั้งหมด เคสนี้จะผ่านทันที)
-- ============================================================
do $$
begin
  perform pg_temp.must_pass('R4 ตั้งลูกหนี้ของสุดจิตต์ 10,000', format(
    $q$ select pg_temp.mk_recv('00000000-0000-0000-0000-0000000e0030', 'SUDJIT', 10000) $q$));
  perform pg_temp.must_pass('R4 ตั้งค่าเผื่อ 10,000', format(
    $q$ select pg_temp.mk_allow('00000000-0000-0000-0000-0000000e0031', 'SUDJIT', 10000) $q$));
  perform pg_temp.must_pass('R4 กลับค่าเผื่อ 10,000 (Dr 1290 / Cr 5920 — ไม่แตะลูกหนี้)', format(
    $q$ select pg_temp.mk_release('00000000-0000-0000-0000-0000000e0032', 'SUDJIT', 10000) $q$));

  -- เดบิต 1290 มี 10,000 อยู่จริง แต่ **ไม่ใช่ยอดตัดหนี้สูญ**
  if pg_temp.debit_1290('SUDJIT') <> 0 then
    raise exception 'FAIL: R4 สภาพตั้งต้นเพี้ยน: 1290 สุทธิควรเป็น 0 ได้ %', pg_temp.debit_1290('SUDJIT');
  end if;

  perform pg_temp.must_fail_like('R4 รับคืน 1 บาทโดยที่มีแต่ใบกลับค่าเผื่อ ไม่มีใบตัดหนี้สูญ', format(
    $q$ select pg_temp.mk_recovered('00000000-0000-0000-0000-0000000e0033', 'SUDJIT', 1) $q$),
    'หมวดนี้ใช้ได้เฉพาะหนี้ที่ถูกตัดหนี้สูญไปแล้ว');

  raise notice 'ok R4 · ใบกลับค่าเผื่อไม่ถูกนับเป็นยอดตัดหนี้สูญ (แยกด้วยบัญชีคู่ในใบ)';
end $$;

-- ============================================================
-- R5 · void **ใบตัดหนี้สูญ** → ยอดตัดหนี้สูญสะสมลด → ใบรับคืนที่เคยผ่านต้องถูกกัน
--      และข้อความต้องเป็นสาขา "ใบตัดหนี้สูญถูกเอาออก" ไม่ใช่สาขา "ยังไม่ได้ตัด"
--      (ทางแก้ของสองสาขาตรงข้ามกัน · บทเรียนข้อ 6 ของ D-103)
-- ============================================================
do $$
begin
  -- สุธีตอนนี้: ลูกหนี้ 0 · ค่าเผื่อ 0 · รับคืน 0 (R1c รับชำระครบแล้ว)
  perform pg_temp.must_pass('R5 ตั้งลูกหนี้ 5,000', format(
    $q$ select pg_temp.mk_recv('00000000-0000-0000-0000-0000000e0040', 'SUTEE', 5000) $q$));
  perform pg_temp.must_pass('R5 ตั้งค่าเผื่อ 5,000', format(
    $q$ select pg_temp.mk_allow('00000000-0000-0000-0000-0000000e0041', 'SUTEE', 5000) $q$));
  perform pg_temp.must_pass('R5 ตัดหนี้สูญ 5,000', format(
    $q$ select pg_temp.mk_writeoff('00000000-0000-0000-0000-0000000e0042', 'SUTEE', 5000) $q$));
  perform pg_temp.must_pass('R5 รับคืน 5,000 (ตอนนี้ถูกต้องทุกอย่าง)', format(
    $q$ select pg_temp.mk_recovered('00000000-0000-0000-0000-0000000e0043', 'SUTEE', 5000) $q$));

  -- (ก) void ใบ **ตัดหนี้สูญ** ขณะที่ใบรับคืนยังอยู่ → ปฏิเสธ
  --     (ไม่งั้นลูกหนี้ 5,000 กลับมาในงบดุล **พร้อมกับ** รายได้ที่รับคืนไปแล้ว = นับสองรอบ)
  perform pg_temp.must_fail_like('R5 void ใบตัดหนี้สูญขณะที่ใบรับคืนยังอยู่ในสมุด',
    $q$ select pg_temp.upd($i$ update sri_os.transactions set status = 'void'
            where id = '00000000-0000-0000-0000-0000000e0042' $i$) $q$,
    'ต้องกลับรายการหรือยกเลิกใบหนี้สูญได้รับคืนนั้นก่อน');

  -- (ข) และข้อความ **ต้องไม่** เป็นสาขา "ยังไม่ได้ตัดหนี้สูญ" ซึ่งทางแก้ตรงข้ามกัน
  perform pg_temp.must_fail_without('R5 ข้อความห้ามชี้ทางแก้ของอีกสถานการณ์',
    $q$ select pg_temp.upd($i$ update sri_os.transactions set status = 'void'
            where id = '00000000-0000-0000-0000-0000000e0042' $i$) $q$,
    'หมวดนี้ใช้ได้เฉพาะหนี้ที่ถูกตัดหนี้สูญไปแล้ว');

  if pg_temp.recovered('SUTEE') <> 5000 then
    raise exception 'FAIL: R5 ใบที่ถูกปฏิเสธมีผลต่อยอดรับคืน: %', pg_temp.recovered('SUTEE');
  end if;

  -- (ค) ลำดับที่ถูกต้องยังทำได้ — ห้ามกันแน่นเกิน
  perform pg_temp.must_pass('R5 void ใบรับคืนก่อน',
    $q$ select pg_temp.upd($i$ update sri_os.transactions set status = 'void'
            where id = '00000000-0000-0000-0000-0000000e0043' $i$) $q$);
  perform pg_temp.must_pass('R5 แล้ว void ใบตัดหนี้สูญได้',
    $q$ select pg_temp.upd($i$ update sri_os.transactions set status = 'void'
            where id = '00000000-0000-0000-0000-0000000e0042' $i$) $q$);
  if pg_temp.recovered('SUTEE') <> 0 or pg_temp.receivable('SUTEE', '1200') <> 5000 then
    raise exception 'FAIL: R5 หลัง void ตามลำดับที่ถูก ควรเหลือรับคืน 0 · ลูกหนี้ 5000 ได้ % / %',
      pg_temp.recovered('SUTEE'), pg_temp.receivable('SUTEE', '1200');
  end if;

  raise notice 'ok R5 · void ใบตัดหนี้สูญขณะมีใบรับคืนถูกปฏิเสธด้วยข้อความของสาขาตัวเอง · ลำดับที่ถูกยังทำได้';
end $$;

-- ============================================================
-- R6 · **เคสของรูที่ 2ก** · ตั้งค่าเผื่อ 1,000 แล้ว UPDATE บรรทัดเป็น 900,000
--      ในธุรกรรมเดียวกัน → ต้องปฏิเสธ
--      (ของเดิมผ่าน เพราะ `new is not null` ทำให้ v_delta = 0 → cause 'other'
--       → cap มาจาก trigger หัวรายการเท่านั้น ซึ่ง UPDATE บรรทัดไม่ปลุก)
-- ============================================================
do $$
begin
  perform pg_temp.must_pass('R6 ตั้งลูกหนี้ของเบ็ญจพร 10,000', format(
    $q$ select pg_temp.mk_recv('00000000-0000-0000-0000-0000000e0050', 'BENJAPORN', 10000) $q$));

  -- ลงตรงๆ 900,000 ถูกปฏิเสธอยู่แล้ว (trigger หัวรายการ) — ไว้เทียบว่าช่องทางสองทางต้องตรงกัน
  perform pg_temp.must_fail_like('R6 ตั้งค่าเผื่อ 900,000 ตรงๆ (ลูกหนี้มี 10,000)', format(
    $q$ select pg_temp.mk_allow('00000000-0000-0000-0000-0000000e0051', 'BENJAPORN', 900000) $q$),
    'มากกว่ายอดลูกหนี้รวม');

  perform pg_temp.must_pass('R6 ตั้งค่าเผื่อ 1,000 (อยู่ในวงเงิน)', format(
    $q$ select pg_temp.mk_allow('00000000-0000-0000-0000-0000000e0052', 'BENJAPORN', 1000) $q$));

  -- **ช่องที่รูที่ 2ก เปิดไว้**: แก้ทั้งสองบรรทัดพร้อมกัน (ใบยังสมดุล) เป็น 900,000
  perform pg_temp.must_fail_like('R6 UPDATE บรรทัดของใบตั้งค่าเผื่อจาก 1,000 เป็น 900,000',
    $q$ select pg_temp.upd($i$ update sri_os.transaction_lines
             set debit  = case when debit  > 0 then 900000 else 0 end,
                 credit = case when credit > 0 then 900000 else 0 end
           where transaction_id = '00000000-0000-0000-0000-0000000e0052' $i$) $q$,
    'มากกว่ายอดลูกหนี้รวม');
  if pg_temp.allowance('BENJAPORN') <> 1000 then
    raise exception 'FAIL: R6 UPDATE ที่ถูกปฏิเสธยังมีผลต่อยอดค่าเผื่อ: %', pg_temp.allowance('BENJAPORN');
  end if;

  -- ห้ามกันแน่นเกิน: แก้เป็น 10,000 ซึ่งพอดีกับลูกหนี้ ต้องผ่าน
  perform pg_temp.must_pass('R6 UPDATE เป็น 10,000 ซึ่งพอดีกับลูกหนี้',
    $q$ select pg_temp.upd($i$ update sri_os.transaction_lines
             set debit  = case when debit  > 0 then 10000 else 0 end,
                 credit = case when credit > 0 then 10000 else 0 end
           where transaction_id = '00000000-0000-0000-0000-0000000e0052' $i$) $q$);
  if pg_temp.allowance('BENJAPORN') <> 10000 then
    raise exception 'FAIL: R6 ค่าเผื่อควรเป็น 10000 หลัง UPDATE ที่ถูกต้อง ได้ %', pg_temp.allowance('BENJAPORN');
  end if;

  raise notice 'ok R6 · UPDATE บรรทัดเลี่ยง cap ไม่ได้อีก (ด่านระดับบรรทัดเห็นส่วนต่างจริงแล้ว) · การแก้ที่อยู่ในวงเงินยังทำได้';
end $$;

-- ============================================================
-- R7 · **เคสของรูที่ 2ข** · เอาค่าเผื่อออกเกินด้วย UPDATE บรรทัด
--      → ต้องได้ข้อความสาขา "ตั้งค่าเผื่อเพิ่มก่อน" ไม่ใช่สาขา void ใบตั้งค่าเผื่อ
--      (ของเดิม v_delta = 0 → ตกสาขา other ที่บอกว่า "ตั้งค่าเผื่อเพิ่มไม่ช่วย"
--       ซึ่งชี้ทางแก้ผิดทาง · needle 'ตั้งค่าเผื่อ' เดิมตรงกับทั้งสองข้อความ)
-- ============================================================
do $$
begin
  -- ธนวินท์มีใบตัดหนี้สูญ 30,000 อยู่ (R3) และค่าเผื่อเหลือ 0
  perform pg_temp.must_fail_like('R7 UPDATE ใบตัดหนี้สูญจาก 30,000 เป็น 900,000',
    $q$ select pg_temp.upd($i$ update sri_os.transaction_lines
             set debit  = case when debit  > 0 then 900000 else 0 end,
                 credit = case when credit > 0 then 900000 else 0 end
           where transaction_id = '00000000-0000-0000-0000-0000000e0022' $i$) $q$,
    'เอาค่าเผื่อออกมากกว่าค่าเผื่อคงเหลือ');

  perform pg_temp.must_fail_without('R7 ข้อความห้ามเป็นสาขา void ใบตั้งค่าเผื่อ',
    $q$ select pg_temp.upd($i$ update sri_os.transaction_lines
             set debit  = case when debit  > 0 then 900000 else 0 end,
                 credit = case when credit > 0 then 900000 else 0 end
           where transaction_id = '00000000-0000-0000-0000-0000000e0022' $i$) $q$,
    'ตั้งค่าเผื่อเพิ่มไม่ช่วย');

  raise notice 'ok R7 · ด่านระดับบรรทัดเลือกสาขาข้อความได้ถูกต้องแล้ว (เอาค่าเผื่อออกเกิน ≠ ยกเลิกใบตั้งค่าเผื่อ)';
end $$;

-- ============================================================
-- R8 · ด่านใหม่เทียบ **ต่อผู้ถือ** · ยอดที่ตัดของคนหนึ่งไม่ค้ำการรับคืนของอีกคน
-- ============================================================
do $$
begin
  -- ธนวินท์ตัดหนี้สูญไว้ 30,000 (R3) · สุดจิตต์ไม่เคยตัดเลย (R4 มีแต่ใบกลับค่าเผื่อ)
  perform pg_temp.must_fail_like('R8 สุดจิตต์รับคืนโดยอาศัยยอดที่ธนวินท์ตัดไว้', format(
    $q$ select pg_temp.mk_recovered('00000000-0000-0000-0000-0000000e0060', 'SUDJIT', 100) $q$),
    'หมวดนี้ใช้ได้เฉพาะหนี้ที่ถูกตัดหนี้สูญไปแล้ว');
  raise notice 'ok R8 · ยอดตัดหนี้สูญข้ามผู้ถือไม่ได้ (เทียบต่อผู้ถือเหมือนด่านอื่นในชุดนี้)';
end $$;

-- ============================================================
-- R9 · กฎเงินต้องไม่ขึ้นกับสิทธิ์ — เดินเส้นทางสำคัญซ้ำด้วย role authenticated
-- ============================================================
do $$
begin
  perform set_config('test.uid', pg_temp.fuid('rc_mgmt')::text, true);
  execute 'set local role authenticated';

  -- ธนากรรับคืนครบ 30,000 แล้ว (R2) → อีกบาทเดียวต้องไม่ได้
  perform pg_temp.must_fail_like('R9 รับคืนเกินยอดที่ตัดไป (authenticated)', format(
    $q$ select pg_temp.mk_recovered('00000000-0000-0000-0000-0000000e0070', 'THANAKORN', 1) $q$),
    'หมวดนี้ใช้ได้เฉพาะหนี้ที่ถูกตัดหนี้สูญไปแล้ว');
  -- และเบ็ญจพรที่ไม่เคยตัดเลยก็ยังลงไม่ได้
  perform pg_temp.must_fail_like('R9 รับคืนโดยไม่เคยตัดหนี้สูญ (authenticated)', format(
    $q$ select pg_temp.mk_recovered('00000000-0000-0000-0000-0000000e0071', 'BENJAPORN', 1) $q$),
    'หมวดนี้ใช้ได้เฉพาะหนี้ที่ถูกตัดหนี้สูญไปแล้ว');

  execute 'reset role';
  raise notice 'ok R9 · ด่านใหม่ทำงานกับ role authenticated ด้วย (ไม่ได้ผ่าน/ไม่ผ่านเพราะรันเป็น superuser)';
end $$;

-- ---------- สรุป: ทุกใบที่ไฟล์นี้สร้างต้องผ่านด่านที่เลื่อนไว้จริง ----------
do $$
declare n int;
begin
  set constraints all immediate;
  select count(*) into n from sri_os.transactions where memo like 'RC %';
  if n < 15 then
    raise exception 'FAIL: นับใบที่เทสต์นี้สร้างได้แค่ % ใบ — เทสต์อาจไม่ได้ลงอะไรเลย', n;
  end if;
  raise notice 'ok R · ทั้ง % ใบของไฟล์นี้ผ่านด่านที่เลื่อนไว้ (เคสปฏิเสธไม่ทิ้งใบเสียรูปไว้)', n;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: ใบที่เทสต์นี้สร้างไว้เสียรูป: %', sqlerrm;
end $$;

rollback;
