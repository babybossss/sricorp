-- ============================================================
-- SRI OS · เทสต์ "บัญชีตั้งค้างลงได้ ต่อเมื่อหมวดนั้นตั้งค้างได้จริง" (D-107)
--
-- รูที่ไฟล์นี้เฝ้า:
--   `fn_assert_line_coa_in_rules` สร้างชุดบัญชีที่อนุญาตจาก
--     array[dr, cr, gain, loss, interest, accrual]
--   โดยใส่ `accrual_coa_code` **ไม่มีเงื่อนไข** · ไม่เคยอ่าน `can_accrue` เลย
--   ขณะที่ตารางกฎฝั่งโค้ดบอกว่า 27 หมวดมี `accrualCoa` แต่ `canAccrueFromForm()`
--   คืน false (ในนั้น 16 หมวดชี้ไป `1220` ซึ่ง **ไม่มีหมวดล้างเลย**)
--   → เขียน SQL ตรงลงบรรทัด 1220 ของหมวดพวกนั้นได้ = **mint ลูกหนี้ปลอม**
--   → ดันเพดานค่าเผื่อ → ตัดหนี้สูญ → ดันเพดาน 4320 (วงปั๊มเดิมที่ 20261010000002
--     ปิดไว้เฉพาะวงที่วิ่งผ่านหมวดรับคืนเอง)
--
-- คุณสมบัติที่ไฟล์นี้บังคับ:
--   P1 บัญชีตั้งค้างของหมวดใด ลงบรรทัดได้ต่อเมื่อ `txn_types.can_accrue` ของหมวดนั้นจริง
--      (ผูกกับธง ไม่ใช่ผูกกับ "มีค่าใน accrual_coa_code")
--   P2 ห้ามกันแน่นเกิน — 23 หมวดที่ตั้งค้างได้จริง (1200/1210/2100) ต้องยังลงได้
--      และการล้างค้าง (inv.collect_rent · inv.collect_interest · fin.pay_payable)
--      ต้องยังทำได้ · บัญชี gain/loss/interest ในชุดที่อนุญาตต้องไม่ถูกกระทบ
--
-- ไฟล์นี้ rollback ท้ายไฟล์ (ไม่ commit ข้อมูล) · เคสที่ต้องการ xmin ต่างกันไม่มีที่นี่
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures (แพทเทิร์น/ตัวช่วยชุดเดียวกับ zz_recovery_no_accrual_test · id ไม่ชนกัน)
-- ------------------------------------------------------------
create temporary table t_cauid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_cauid(label) values ('ca_mgmt');
insert into auth.users(id) select id from t_cauid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select id, label || '@can-accrue.local', label, 'management', true from t_cauid;
insert into sri_os.user_owner_access(user_id, owner_id)
select (select id from t_cauid where label = 'ca_mgmt'), o.id from sri_os.owners o;

create or replace function pg_temp.fuid(p_label text) returns uuid
language sql stable as $fn$ select id from t_cauid where label = p_label $fn$;

create or replace function pg_temp.coa(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.chart_of_accounts where code = p_code $fn$;

create or replace function pg_temp.own(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.owners where code = p_code $fn$;

insert into sri_os.contacts(id, first_name, types)
values ('00000000-0000-0000-0000-0000000ca700', 'คู่ค้า CA', array['tenant'])
on conflict do nothing;

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
select x.id, pg_temp.own(x.own), x.bank, x.nm, x.nm
  from (values
    ('00000000-0000-0000-0000-0000000ca001'::uuid, 'SUTEE',     'BBL',   'CA สุธี'),
    ('00000000-0000-0000-0000-0000000ca002'::uuid, 'THANAKORN', 'KBANK', 'CA ธนากร'),
    ('00000000-0000-0000-0000-0000000ca003'::uuid, 'THANAWIN',  'SCB',   'CA ธนวินท์'),
    ('00000000-0000-0000-0000-0000000ca004'::uuid, 'SUDJIT',    'KTB',   'CA สุดจิตต์'),
    ('00000000-0000-0000-0000-0000000ca005'::uuid, 'BENJAPORN', 'TTB',   'CA เบ็ญจพร')
  ) as x(id, own, bank, nm);

create or replace function pg_temp.bank(p_owner text) returns uuid
language sql stable as $fn$
  select id from sri_os.bank_accounts
   where owner_id = pg_temp.own(p_owner) and display_name like 'CA %'
$fn$;

create or replace function pg_temp.fire() returns void
language plpgsql as $fn$
begin
  set constraints all immediate;
  set constraints all deferred;
end $fn$;

create or replace function pg_temp.must_fail_like(p_label text, p_sql text, p_needle text) returns void
language plpgsql as $fn$
declare v text;
begin
  begin
    execute p_sql;
    raise exception 'CA_UNEXPECTED_SUCCESS';
  exception when others then
    v := sqlerrm;
    if v = 'CA_UNEXPECTED_SUCCESS' then
      raise exception 'FAIL: % — คำสั่งควรถูกปฏิเสธแต่สำเร็จ', p_label;
    end if;
    if v like 'FAIL:%' then raise; end if;
    if position(p_needle in v) = 0 then
      raise exception 'FAIL: % — ปฏิเสธถูกแต่ข้อความไม่มี "%" · ได้: %', p_label, p_needle, v;
    end if;
  end;
end $fn$;

/** ปฏิเสธถูก แต่ข้อความ **ต้องไม่มี** คำของอีกสาขา (กันเทสต์ที่เขียวด้วยเหตุผลผิด) */
create or replace function pg_temp.must_fail_without(p_label text, p_sql text, p_needle text) returns void
language plpgsql as $fn$
declare v text;
begin
  begin
    execute p_sql;
    raise exception 'CA_UNEXPECTED_SUCCESS';
  exception when others then
    v := sqlerrm;
    if v = 'CA_UNEXPECTED_SUCCESS' then
      raise exception 'FAIL: % — คำสั่งควรถูกปฏิเสธแต่สำเร็จ', p_label;
    end if;
    if v like 'FAIL:%' then raise; end if;
    if position(p_needle in v) > 0 then
      raise exception 'FAIL: % — ข้อความชี้ไปอีกสาขาด้วยคำว่า "%" · ได้: %', p_label, p_needle, v;
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

create or replace function pg_temp.mk(p_id uuid, p_owner text, p_type text,
                                      p_cash date, p_lines jsonb) returns uuid
language plpgsql as $fn$
declare r jsonb;
begin
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, cash_date, memo,
                                  attachments, contact_id)
  values (p_id, pg_temp.own(p_owner), p_type, current_date, p_cash, 'CA ' || p_id::text,
          array['หลักฐาน CA.pdf'], '00000000-0000-0000-0000-0000000ca700');
  for r in select * from jsonb_array_elements(p_lines) loop
    insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id,
                                         debit, credit, cf_category, memo)
    values (p_id, pg_temp.coa(r ->> 'coa'), (r ->> 'bank')::uuid,
            coalesce((r ->> 'dr')::numeric, 0), coalesce((r ->> 'cr')::numeric, 0),
            coalesce(r ->> 'cf', 'none')::sri_os.cf_group, 'CA บรรทัด');
  end loop;
  perform pg_temp.fire();
  return p_id;
end $fn$;

/**
 * ลงใบที่ถูกต้องก่อน (ขาเงินสดจริง) แล้ว **UPDATE** ขาเงินสดให้เป็นบัญชีตั้งค้าง
 * ในธุรกรรมเดียวกัน — เส้นทางที่เลี่ยงด่านที่ผูกแค่ INSERT ได้
 */
create or replace function pg_temp.mk_cash_then_accrual(p_id uuid, p_owner text) returns void
language plpgsql as $fn$
begin
  perform pg_temp.mk(p_id, p_owner, 'inc.other', current_date,
    jsonb_build_array(
      jsonb_build_object('coa', '1100', 'dr', 9000, 'cr', 0, 'cf', 'operating',
                         'bank', pg_temp.bank(p_owner)),
      jsonb_build_object('coa', '4900', 'dr', 0, 'cr', 9000)));
  update sri_os.transaction_lines
     set coa_id = pg_temp.coa('1220'), bank_account_id = null
   where transaction_id = p_id and coa_id = pg_temp.coa('1100');
  perform pg_temp.fire();
end $fn$;

/** ยอดสุทธิด้านเดบิตของบัญชีหนึ่งต่อผู้ถือ (ใบที่ไม่ void) */
create or replace function pg_temp.net(p_owner text, p_code text) returns numeric
language sql stable as $fn$
  select coalesce(sum(l.debit - l.credit), 0)
    from sri_os.transactions t
    join sri_os.transaction_lines l on l.transaction_id = t.id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where t.owner_id = pg_temp.own(p_owner) and t.status <> 'void' and c.code = p_code
$fn$;

-- ============================================================
-- CA0 · โครงสร้าง — ไล่จาก catalog จริง ไม่ใช่เชื่อว่าไฟล์รันแล้ว
--   รวม **สภาพตั้งต้นของตารางกฎ**: ถ้าไม่มีหมวดที่ (can_accrue = false และมี
--   accrual_coa_code) เหลืออยู่เลย เคสหลักของไฟล์นี้จะเขียวโดยไม่ได้ทดสอบอะไร
-- ============================================================
do $$
declare
  v text; v_src text; n int; n_false int; n_true int;
  v_type int; v_sec boolean;
begin
  -- (ก) ตารางกฎใน DB ต้องมีสภาพที่ทำให้เคสของไฟล์นี้มีความหมาย
  select count(*) into n_false from sri_os.txn_types
   where can_accrue = false and accrual_coa_code is not null;
  select count(*) into n_true from sri_os.txn_types where can_accrue;
  if n_false = 0 then
    raise exception 'FAIL: CA0 ไม่มีหมวดที่ can_accrue = false แต่มี accrual_coa_code เหลือในตารางกฎ — เคสหลักของไฟล์นี้จะไม่ได้ทดสอบอะไร ต้องเลือกหมวดใหม่ให้ตรงกับตารางกฎรุ่นนี้';
  end if;
  if n_true = 0 then
    raise exception 'FAIL: CA0 ไม่มีหมวดที่ can_accrue = true เลย — เคส "ห้ามกันแน่นเกิน" จะไม่ได้ทดสอบอะไร';
  end if;
  if not exists (select 1 from sri_os.txn_types
                  where code = 'inc.other' and accrual_coa_code = '1220' and can_accrue = false) then
    raise exception 'FAIL: CA0 inc.other ต้องเป็นหมวดที่มีบัญชีพัก 1220 แต่ตั้งค้างไม่ได้ (เคสหลักอ้างหมวดนี้)';
  end if;
  if not exists (select 1 from sri_os.txn_types
                  where code = 'fin.interest_paid' and accrual_coa_code = '2100' and can_accrue = false) then
    raise exception 'FAIL: CA0 fin.interest_paid ต้องเป็นหมวดที่มีบัญชีพัก 2100 แต่ตั้งค้างไม่ได้ (เคส "บัญชีอื่นที่ไม่ใช่ 1220")';
  end if;
  -- 1220 ต้องยังไม่มีหมวดล้าง (เป็นเหตุผลที่ลูกหนี้ปลอมค้างตลอดไป)
  if exists (select 1 from sri_os.txn_types
              where is_active and cr_coa_code = '1220' and dr_coa_code ~ '^11[0-9][0-9]$') then
    raise exception 'FAIL: CA0 มีหมวดล้าง 1220 ด้วยเงินสดแล้ว — สมมติฐานของไฟล์นี้เปลี่ยน ต้องทบทวนว่าหมวดใดควรตั้งค้างที่ 1220 ได้';
  end if;

  -- (ข) ด่านใหม่ต้องเป็นฟังก์ชันของตัวเอง ตัวเดียว (ถอด/แก้ทีละข้อได้)
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_assert_line_accrual_can_accrue';
  if n <> 1 then
    raise exception 'FAIL: CA0 ต้องมี sri_os.fn_assert_line_accrual_can_accrue ตัวเดียว (ได้ %)', n;
  end if;
  select p.prosrc, p.prosecdef into v_src, v_sec from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_assert_line_accrual_can_accrue';
  -- **หัวใจของ P1**: ด่านต้องผูกกับธง ไม่ใช่กับการมีค่าใน accrual_coa_code
  if v_src not like '%can_accrue%' then
    raise exception 'FAIL: CA0 ด่านใหม่ไม่ได้อ่าน can_accrue เลย — กลับไปเป็นรูเดิม (ตารางกฎบอก "ตั้งค้างไม่ได้" แต่ DB บอก "ลงได้")';
  end if;
  if not v_sec then
    raise exception 'FAIL: CA0 ด่านใหม่ต้องเป็น security definer — อ่านตารางกฎตามสิทธิ์ผู้เรียกแล้วได้ null จะหลุดด่านเงียบๆ';
  end if;
  if v_src like '%fn_can%' then
    raise exception 'FAIL: CA0 ด่านใหม่เรียกฟังก์ชันตรวจสิทธิ์ — กฎเงินต้องปิดไม่ได้จากหน้า Settings';
  end if;

  -- (ค) ต้องผูกเป็น trigger ระดับแถว ครอบทั้ง insert และ update
  select t.tgtype into v_type from pg_trigger t
   where t.tgrelid = 'sri_os.transaction_lines'::regclass
     and t.tgname = 'trg_lines_rule_coa_accrual';
  if v_type is null then
    raise exception 'FAIL: CA0 ไม่มี trigger trg_lines_rule_coa_accrual บน transaction_lines';
  end if;
  if (v_type & 1) = 0 or (v_type & 2) = 0 or (v_type & 4) = 0 or (v_type & 16) = 0 then
    raise exception 'FAIL: CA0 trigger ต้องเป็น before insert or update for each row (tgtype %)', v_type;
  end if;

  -- (ง) ชื่อต้องเรียงหลังด่านเดิม — trigger ยิงตามลำดับชื่อ ถ้ายิงก่อน
  --     ข้อความของกฎ "แก้ของที่ post แล้วไม่ได้" จะถูกแทนที่ (เคส CA7 ยืนยันพฤติกรรม)
  if not ('trg_lines_rule_coa_accrual' collate "C" > 'trg_lines_immutable_after_post' collate "C"
          and 'trg_lines_rule_coa_accrual' collate "C" > 'trg_lines_rule_coa' collate "C") then
    raise exception 'FAIL: CA0 ชื่อ trigger เรียงก่อนด่านเดิม — ข้อความที่ผู้ใช้เห็นจะชี้ผิดจุด';
  end if;

  -- (จ) ของเดิมห้ามหาย (บทเรียน D-104: create or replace ของไฟล์ทีหลังลบกติกาเดิมได้เงียบๆ)
  foreach v in array array['fn_assert_line_coa_in_rules', 'fn_assert_line_bank_is_cash',
                           'fn_assert_recovery_no_receivable', 'fn_assert_recovery_within_writeoff',
                           'fn_assert_allowance_limits', 'fn_assert_receivable_not_negative'] loop
    if not exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                    where ns.nspname = 'sri_os' and p.proname = v) then
      raise exception 'FAIL: CA0 ด่านเดิม % หายไป', v;
    end if;
  end loop;
  -- และด่านเดิมต้องยังผูกอยู่จริง
  if not exists (select 1 from pg_trigger t
                  where t.tgrelid = 'sri_os.transaction_lines'::regclass
                    and t.tgname = 'trg_lines_rule_coa') then
    raise exception 'FAIL: CA0 trigger เดิม trg_lines_rule_coa หายไป';
  end if;

  raise notice 'ok CA0 · ด่านใหม่ติดตั้งแล้วและอ่าน can_accrue · ตารางกฎยังมี % หมวดที่ตั้งค้างไม่ได้แต่มีบัญชีพัก และ % หมวดที่ตั้งค้างได้ · ด่านเดิมอยู่ครบ',
    n_false, n_true;
end $$;

-- ============================================================
-- CA1 · **เคสหลัก** · หมวดที่ can_accrue = false ลงบรรทัดบัญชีตั้งค้างของตัวเอง
--       → ปฏิเสธ · ทดสอบทั้ง 1220 และหมวดที่ชี้บัญชีอื่น (2100)
-- ============================================================
do $$
declare
  v_b1220 numeric := pg_temp.net('SUDJIT', '1220');
  v_b2100 numeric := pg_temp.net('SUDJIT', '2100');
begin
  -- (ก) 1220 · inc.other "รายได้อื่น" ตั้งค้างไม่ได้ (1220 ไม่มีหมวดล้าง)
  perform pg_temp.must_fail_like('CA1 ตั้งค้างรับรายได้อื่น 40,000 (Dr 1220 / Cr 4900)', format(
    $q$ select pg_temp.mk('00000000-0000-0000-0000-0000000ca101', 'SUDJIT', 'inc.other', null,
          jsonb_build_array(jsonb_build_object('coa', '1220', 'dr', 40000, 'cr', 0),
                            jsonb_build_object('coa', '4900', 'dr', 0, 'cr', 40000))) $q$),
    'ตั้งค้าง');

  -- (ข) 1220 · fin.loan_bank "เงินกู้ธนาคาร" — เส้นทางที่ 20261010000002 ระบุว่ายังเหลือ
  --     (Dr 1220 / Cr 2410 = กู้ที่ยังไม่ได้รับเงิน → ลูกหนี้ปลอม)
  perform pg_temp.must_fail_like('CA1 เงินกู้ธนาคารที่ยังไม่ได้รับเงิน (Dr 1220 / Cr 2410)', format(
    $q$ select pg_temp.mk('00000000-0000-0000-0000-0000000ca102', 'SUDJIT', 'fin.loan_bank', null,
          jsonb_build_array(jsonb_build_object('coa', '1220', 'dr', 500000, 'cr', 0),
                            jsonb_build_object('coa', '2410', 'dr', 0, 'cr', 500000))) $q$),
    'ตั้งค้าง');

  -- (ค) บัญชีอื่นที่ไม่ใช่ 1220 · fin.interest_paid พักที่ 2100 แต่ตั้งค้างไม่ได้
  --     (2100 เป็นบัญชีที่ **หมวดอื่นตั้งค้างได้** → พิสูจน์ว่าด่านผูกกับหมวด ไม่ใช่กับบัญชี)
  perform pg_temp.must_fail_like('CA1 ดอกเบี้ยจ่ายค้างจ่าย (Dr 5400 / Cr 2100)', format(
    $q$ select pg_temp.mk('00000000-0000-0000-0000-0000000ca103', 'SUDJIT', 'fin.interest_paid', null,
          jsonb_build_array(jsonb_build_object('coa', '5400', 'dr', 7000, 'cr', 0),
                            jsonb_build_object('coa', '2100', 'dr', 0, 'cr', 7000))) $q$),
    'ตั้งค้าง');

  -- (ง) ซื้ออสังหาแบบยังไม่จ่าย (Dr 1500 / Cr 2100) — เคสที่ทำให้ 10 ล้าน
  --     ไปโผล่กระแสเงินสดจากการดำเนินงานตอนล้าง (เหตุผลของ cf_group ใน D-069)
  perform pg_temp.must_fail_like('CA1 ซื้ออสังหาแบบยังไม่จ่าย (Dr 1500 / Cr 2100)', format(
    $q$ select pg_temp.mk('00000000-0000-0000-0000-0000000ca104', 'SUDJIT', 'inv.buy_re', null,
          jsonb_build_array(jsonb_build_object('coa', '1500', 'dr', 10000000, 'cr', 0),
                            jsonb_build_object('coa', '2100', 'dr', 0, 'cr', 10000000))) $q$),
    'ตั้งค้าง');

  -- ข้อความต้องมาจาก **ด่านใหม่** ไม่ใช่สาขา "บัญชีไม่อยู่ในชุดของหมวด" ของด่านเดิม
  -- (ด่านเดิมยอมบรรทัดนี้อยู่แล้ว · ถ้าข้อความเป็นของมัน แปลว่าเทสต์เขียวด้วยเหตุผลผิด)
  perform pg_temp.must_fail_without('CA1 ข้อความต้องเป็นของด่านใหม่ ไม่ใช่สาขาชุดบัญชีของด่านเดิม', format(
    $q$ select pg_temp.mk('00000000-0000-0000-0000-0000000ca105', 'SUDJIT', 'inc.other', null,
          jsonb_build_array(jsonb_build_object('coa', '1220', 'dr', 1, 'cr', 0),
                            jsonb_build_object('coa', '4900', 'dr', 0, 'cr', 1))) $q$),
    'ตารางกฎระบุบัญชีของหมวดนี้ไว้เฉพาะ');

  -- ไม่มีใบไหนค้างในสมุด และยอดไม่ขยับ
  if exists (select 1 from sri_os.transactions
              where id in ('00000000-0000-0000-0000-0000000ca101',
                           '00000000-0000-0000-0000-0000000ca102',
                           '00000000-0000-0000-0000-0000000ca103',
                           '00000000-0000-0000-0000-0000000ca104',
                           '00000000-0000-0000-0000-0000000ca105')) then
    raise exception 'FAIL: CA1 ใบที่ถูกปฏิเสธยังค้างอยู่ในสมุด';
  end if;
  if pg_temp.net('SUDJIT', '1220') <> v_b1220 or pg_temp.net('SUDJIT', '2100') <> v_b2100 then
    raise exception 'FAIL: CA1 ยอดขยับหลังเคสที่ถูกปฏิเสธ: 1220 = % (เดิม %) · 2100 = % (เดิม %)',
      pg_temp.net('SUDJIT', '1220'), v_b1220, pg_temp.net('SUDJIT', '2100'), v_b2100;
  end if;
  raise notice 'ok CA1 · หมวดที่ตั้งค้างไม่ได้ ลงบรรทัดบัญชีตั้งค้างของตัวเองไม่ได้แล้ว (ทั้ง 1220 และ 2100)';
end $$;

-- ============================================================
-- CA2 · **ห้ามกันแน่นเกิน** · หมวดที่ can_accrue = true ลงบรรทัดตั้งค้างได้
--       ครบทั้งสามบัญชี 1200 · 1210 · 2100
-- ============================================================
do $$
declare
  v_b1200 numeric := pg_temp.net('SUTEE', '1200');
  v_b1210 numeric := pg_temp.net('SUTEE', '1210');
  v_b2100 numeric := pg_temp.net('SUTEE', '2100');
begin
  perform pg_temp.must_pass('CA2 ค่าเช่าค้างรับ 30,000 (Dr 1200 / Cr 4200)', format(
    $q$ select pg_temp.mk('00000000-0000-0000-0000-0000000ca201', 'SUTEE', 'inc.rent', null,
          jsonb_build_array(jsonb_build_object('coa', '1200', 'dr', 30000, 'cr', 0),
                            jsonb_build_object('coa', '4200', 'dr', 0, 'cr', 30000))) $q$));

  perform pg_temp.must_pass('CA2 ดอกเบี้ยขายฝากค้างรับ 5,000 (Dr 1210 / Cr 4100)', format(
    $q$ select pg_temp.mk('00000000-0000-0000-0000-0000000ca202', 'SUTEE', 'inc.interest_srr', null,
          jsonb_build_array(jsonb_build_object('coa', '1210', 'dr', 5000, 'cr', 0),
                            jsonb_build_object('coa', '4100', 'dr', 0, 'cr', 5000))) $q$));

  perform pg_temp.must_pass('CA2 ค่าซ่อมค้างจ่าย 8,000 (Dr 5120 / Cr 2100)', format(
    $q$ select pg_temp.mk('00000000-0000-0000-0000-0000000ca203', 'SUTEE', 'exp.repair', null,
          jsonb_build_array(jsonb_build_object('coa', '5120', 'dr', 8000, 'cr', 0),
                            jsonb_build_object('coa', '2100', 'dr', 0, 'cr', 8000))) $q$));

  if pg_temp.net('SUTEE', '1200') <> v_b1200 + 30000
     or pg_temp.net('SUTEE', '1210') <> v_b1210 + 5000
     or pg_temp.net('SUTEE', '2100') <> v_b2100 - 8000 then
    raise exception 'FAIL: CA2 ยอดตั้งค้างไม่ตรง: 1200 % (ควร %) · 1210 % (ควร %) · 2100 % (ควร %)',
      pg_temp.net('SUTEE', '1200'), v_b1200 + 30000,
      pg_temp.net('SUTEE', '1210'), v_b1210 + 5000,
      pg_temp.net('SUTEE', '2100'), v_b2100 - 8000;
  end if;
  raise notice 'ok CA2 · หมวดที่ตั้งค้างได้จริง ยังลงบรรทัดตั้งค้างได้ทั้ง 1200 · 1210 · 2100';
end $$;

-- ============================================================
-- CA3 · **การล้างค้างต้องยังทำได้** (ถ้าล้างไม่ได้ ลูกหนี้ค้างตลอดไปและรายได้ถูกนับซ้ำ)
--       inv.collect_rent · inv.collect_interest · fin.pay_payable
-- ============================================================
do $$
declare
  v_b1200 numeric := pg_temp.net('SUTEE', '1200');
  v_b1210 numeric := pg_temp.net('SUTEE', '1210');
  v_b2100 numeric := pg_temp.net('SUTEE', '2100');
begin
  perform pg_temp.must_pass('CA3 รับชำระค่าเช่าค้างรับ 30,000 (Dr 1100 / Cr 1200)', format(
    $q$ select pg_temp.mk('00000000-0000-0000-0000-0000000ca301', 'SUTEE', 'inv.collect_rent', current_date,
          jsonb_build_array(
            jsonb_build_object('coa', '1100', 'dr', 30000, 'cr', 0, 'cf', 'operating',
                               'bank', %L),
            jsonb_build_object('coa', '1200', 'dr', 0, 'cr', 30000))) $q$, pg_temp.bank('SUTEE')));

  perform pg_temp.must_pass('CA3 รับชำระดอกเบี้ยค้างรับ 5,000 (Dr 1100 / Cr 1210)', format(
    $q$ select pg_temp.mk('00000000-0000-0000-0000-0000000ca302', 'SUTEE', 'inv.collect_interest', current_date,
          jsonb_build_array(
            jsonb_build_object('coa', '1100', 'dr', 5000, 'cr', 0, 'cf', 'operating',
                               'bank', %L),
            jsonb_build_object('coa', '1210', 'dr', 0, 'cr', 5000))) $q$, pg_temp.bank('SUTEE')));

  perform pg_temp.must_pass('CA3 จ่ายเจ้าหนี้ค้างจ่าย 8,000 (Dr 2100 / Cr 1100)', format(
    $q$ select pg_temp.mk('00000000-0000-0000-0000-0000000ca303', 'SUTEE', 'fin.pay_payable', current_date,
          jsonb_build_array(
            jsonb_build_object('coa', '2100', 'dr', 8000, 'cr', 0),
            jsonb_build_object('coa', '1100', 'dr', 0, 'cr', 8000, 'cf', 'operating',
                               'bank', %L))) $q$, pg_temp.bank('SUTEE')));

  -- ล้างแล้วยอดค้างต้องกลับไปเท่าก่อนตั้งค้าง (ไม่ค้างในงบดุล ไม่นับรายได้ซ้ำ)
  if pg_temp.net('SUTEE', '1200') <> v_b1200 - 30000
     or pg_temp.net('SUTEE', '1210') <> v_b1210 - 5000
     or pg_temp.net('SUTEE', '2100') <> v_b2100 + 8000 then
    raise exception 'FAIL: CA3 ล้างค้างแล้วยอดไม่กลับ: 1200 % · 1210 % · 2100 %',
      pg_temp.net('SUTEE', '1200'), pg_temp.net('SUTEE', '1210'), pg_temp.net('SUTEE', '2100');
  end if;
  raise notice 'ok CA3 · ล้างค้างทั้งสามเส้นทางยังทำได้ และยอดค้างกลับเป็นศูนย์ตามเดิม';
end $$;

-- ============================================================
-- CA4 · บัญชีอื่นในชุดที่อนุญาต (gain · loss · interest) ต้องไม่ถูกกระทบ
--       และหมวดเดียวกันนั้น ถ้าลงบรรทัด **บัญชีตั้งค้าง** ยังต้องถูกปฏิเสธ
-- ============================================================
do $$
declare v_b1220 numeric := pg_temp.net('THANAWIN', '1220');
begin
  -- gain · ขายอสังหาได้กำไร (Dr 1100 / Cr 1500 + Cr 4300)
  perform pg_temp.must_pass('CA4 ขายอสังหาได้กำไร 200,000 (บัญชี gain 4300)', format(
    $q$ select pg_temp.mk('00000000-0000-0000-0000-0000000ca401', 'THANAWIN', 'inv.sell_re', current_date,
          jsonb_build_array(
            jsonb_build_object('coa', '1100', 'dr', 1200000, 'cr', 0, 'cf', 'investing',
                               'bank', %L),
            jsonb_build_object('coa', '1500', 'dr', 0, 'cr', 1000000),
            jsonb_build_object('coa', '4300', 'dr', 0, 'cr', 200000))) $q$, pg_temp.bank('THANAWIN')));

  -- loss · ขายหลักทรัพย์ขาดทุน (บัญชี loss 5910)
  perform pg_temp.must_pass('CA4 ขายหลักทรัพย์ขาดทุน 100,000 (บัญชี loss 5910)', format(
    $q$ select pg_temp.mk('00000000-0000-0000-0000-0000000ca402', 'THANAWIN', 'inv.sell_securities', current_date,
          jsonb_build_array(
            jsonb_build_object('coa', '1100', 'dr', 400000, 'cr', 0, 'cf', 'investing',
                               'bank', %L),
            jsonb_build_object('coa', '5910', 'dr', 100000, 'cr', 0),
            jsonb_build_object('coa', '1700', 'dr', 0, 'cr', 500000))) $q$, pg_temp.bank('THANAWIN')));

  -- interest · รับคืนเงินต้น + ดอกเบี้ย (บัญชี interest 4120)
  perform pg_temp.must_pass('CA4 รับคืนเงินให้กู้ + ดอกเบี้ย (บัญชี interest 4120)', format(
    $q$ select pg_temp.mk('00000000-0000-0000-0000-0000000ca403', 'THANAWIN', 'inv.loan_back', current_date,
          jsonb_build_array(
            jsonb_build_object('coa', '1100', 'dr', 110000, 'cr', 0, 'cf', 'investing',
                               'bank', %L),
            jsonb_build_object('coa', '1300', 'dr', 0, 'cr', 100000),
            jsonb_build_object('coa', '4120', 'dr', 0, 'cr', 10000))) $q$, pg_temp.bank('THANAWIN')));

  -- หมวดเดียวกับเคส interest ข้างบน · บัญชีตั้งค้าง 1220 ของมันยังต้องถูกปฏิเสธ
  perform pg_temp.must_fail_like('CA4 เงินต้น+ดอกเบี้ยที่ "ยังไม่ได้รับ" (Dr 1220 / Cr 1300)', format(
    $q$ select pg_temp.mk('00000000-0000-0000-0000-0000000ca404', 'THANAWIN', 'inv.loan_back', null,
          jsonb_build_array(jsonb_build_object('coa', '1220', 'dr', 100000, 'cr', 0),
                            jsonb_build_object('coa', '1300', 'dr', 0, 'cr', 100000))) $q$),
    'ตั้งค้าง');

  if pg_temp.net('THANAWIN', '1220') <> v_b1220 then
    raise exception 'FAIL: CA4 ลูกหนี้อื่นของธนวินท์ขยับเป็น % (เดิม %)',
      pg_temp.net('THANAWIN', '1220'), v_b1220;
  end if;
  raise notice 'ok CA4 · gain/loss/interest ยังลงได้ตามเดิม · บัญชีตั้งค้างของหมวดเดียวกันยังถูกปฏิเสธ';
end $$;

-- ============================================================
-- CA5 · **ลูปปั๊มผ่าน 1220** · mint ลูกหนี้ปลอมด้วยหมวดที่ตั้งค้างไม่ได้
--       → ต้องพังที่ **ก้าวแรก** ทุกรอบ · เพดานค่าเผื่อ/ตัดหนี้สูญห้ามขยับ
-- ============================================================
do $$
declare
  i int;
  v_b1220 numeric := pg_temp.net('THANAKORN', '1220');
  v_b1290 numeric := pg_temp.net('THANAKORN', '1290');
  v_b4320 numeric := pg_temp.net('THANAKORN', '4320');
begin
  for i in 1..3 loop
    -- ก้าวที่ 1 · ปั๊มลูกหนี้ปลอม 1220 ด้วยหมวดที่ตั้งค้างไม่ได้ → ต้องพังที่นี่
    perform pg_temp.must_fail_like(format('CA5 รอบที่ %s ก้าวที่ 1 · mint ลูกหนี้ปลอม 1220', i), format(
      $q$ select pg_temp.mk('00000000-0000-0000-0000-000000ca51%s'::uuid, 'THANAKORN', 'inc.fee', null,
            jsonb_build_array(jsonb_build_object('coa', '1220', 'dr', 30000, 'cr', 0),
                              jsonb_build_object('coa', '4400', 'dr', 0, 'cr', 30000))) $q$,
      lpad(i::text, 2, '0')),
      'ตั้งค้าง');

    -- ก้าวที่ 2 · ไม่มีลูกหนี้ปลอม → ตั้งค่าเผื่อไม่ได้ (ด่านของ 20261009000004)
    perform pg_temp.must_fail_like(format('CA5 รอบที่ %s ก้าวที่ 2 · ตั้งค่าเผื่อโดยไม่มีลูกหนี้', i), format(
      $q$ select pg_temp.mk('00000000-0000-0000-0000-000000ca52%s'::uuid, 'THANAKORN', 'adj.doubtful', null,
            jsonb_build_array(jsonb_build_object('coa', '5920', 'dr', 30000, 'cr', 0),
                              jsonb_build_object('coa', '1290', 'dr', 0, 'cr', 30000))) $q$,
      lpad(i::text, 2, '0')),
      'มากกว่ายอดลูกหนี้รวม');

    -- ก้าวที่ 3 · ตัดหนี้สูญลูกหนี้อื่นที่ไม่มีอยู่ → ด่านลูกหนี้ติดลบ/ค่าเผื่อ
    perform pg_temp.must_fail_like(format('CA5 รอบที่ %s ก้าวที่ 3 · ตัดหนี้สูญลูกหนี้อื่นที่ไม่มีอยู่', i), format(
      $q$ select pg_temp.mk('00000000-0000-0000-0000-000000ca53%s'::uuid, 'THANAKORN', 'adj.writeoff_other', null,
            jsonb_build_array(jsonb_build_object('coa', '1290', 'dr', 30000, 'cr', 0),
                              jsonb_build_object('coa', '1220', 'dr', 0, 'cr', 30000))) $q$,
      lpad(i::text, 2, '0')),
      'ค่าเผื่อหนี้สงสัยจะสูญ');

    if pg_temp.net('THANAKORN', '1220') <> v_b1220
       or pg_temp.net('THANAKORN', '1290') <> v_b1290
       or pg_temp.net('THANAKORN', '4320') <> v_b4320 then
      raise exception 'FAIL: CA5 รอบที่ % เพดานขยับ: 1220 = % (เดิม %) · 1290 = % (เดิม %) · 4320 = % (เดิม %)',
        i, pg_temp.net('THANAKORN', '1220'), v_b1220,
        pg_temp.net('THANAKORN', '1290'), v_b1290,
        pg_temp.net('THANAKORN', '4320'), v_b4320;
    end if;
  end loop;
  raise notice 'ok CA5 · วงปั๊มผ่าน 1220 พังที่ก้าวแรกทุกรอบ · ยอดลูกหนี้/ค่าเผื่อ/รับคืนไม่ขยับเลย';
end $$;

-- ============================================================
-- CA6 · UPDATE ก็ต้องกัน (ไม่งั้นลงบรรทัดถูกก่อนแล้วแก้เป็น 1220 ในธุรกรรมเดียวกัน)
-- ============================================================
do $$
declare v_id uuid := '00000000-0000-0000-0000-0000000ca601';
begin
  perform pg_temp.must_fail_like('CA6 ลง Dr 1100 ถูกก่อน แล้ว UPDATE เป็น 1220 ในธุรกรรมเดียวกัน', format(
    $q$ select pg_temp.mk_cash_then_accrual(%L, 'BENJAPORN') $q$, v_id),
    'ตั้งค้าง');
  if exists (select 1 from sri_os.transactions where id = v_id) then
    raise exception 'FAIL: CA6 ใบที่ถูกปฏิเสธยังค้างอยู่ในสมุด';
  end if;
  raise notice 'ok CA6 · UPDATE บรรทัดเป็นบัญชีตั้งค้างของหมวดที่ตั้งค้างไม่ได้ ถูกปฏิเสธด้วย';
end $$;

-- ============================================================
-- CA7 · ด่านใหม่ต้องไม่กลืนข้อความของด่านเดิม (ยิงหลังตามลำดับชื่อ)
--       บรรทัด 1220 ที่ **ผูกบัญชีธนาคาร** ต้องได้ข้อความของด่าน "bank เฉพาะขาเงินสด"
--       ซึ่งเรียงชื่อก่อน (trg_lines_rule_bank_cash) · ไม่ใช่ข้อความของด่านใหม่
--       (ตรวจพฤติกรรมจริง ไม่ใช่เชื่อลำดับชื่อใน CA0 อย่างเดียว)
-- ============================================================
do $$
begin
  perform pg_temp.must_fail_like('CA7 บรรทัด 1220 ที่ผูกบัญชีธนาคาร', format(
    $q$ select pg_temp.mk('00000000-0000-0000-0000-0000000ca701', 'BENJAPORN', 'inc.other', null,
          jsonb_build_array(
            jsonb_build_object('coa', '1220', 'dr', 2000, 'cr', 0, 'bank', %L),
            jsonb_build_object('coa', '4900', 'dr', 0, 'cr', 2000))) $q$,
    pg_temp.bank('BENJAPORN')),
    'เฉพาะขาเงินสด');
  raise notice 'ok CA7 · ด่านเดิมที่เรียงชื่อก่อนยังพูดก่อนด่านใหม่ (ข้อความไม่ชี้ผิดจุด)';
end $$;

-- ============================================================
-- CA8 · กฎเงินต้องไม่ขึ้นกับสิทธิ์ — เดินเคสหลักซ้ำด้วย role authenticated
-- ============================================================
do $$
begin
  perform set_config('test.uid', pg_temp.fuid('ca_mgmt')::text, true);
  execute 'set local role authenticated';

  perform pg_temp.must_fail_like('CA8 mint ลูกหนี้ปลอม 1220 ในฐานะ authenticated', format(
    $q$ select pg_temp.mk('00000000-0000-0000-0000-0000000ca801', 'THANAWIN', 'inc.key_money', null,
          jsonb_build_array(jsonb_build_object('coa', '1220', 'dr', 100, 'cr', 0),
                            jsonb_build_object('coa', '4310', 'dr', 0, 'cr', 100))) $q$),
    'ตั้งค้าง');

  execute 'reset role';
  raise notice 'ok CA8 · ด่านทำงานกับ role authenticated ด้วย (ไม่ได้ผ่านเพราะรันเป็น superuser)';
end $$;

-- ---------- สรุป: ทุกใบที่ไฟล์นี้สร้างต้องผ่านด่านที่เลื่อนไว้จริง ----------
do $$
declare n int;
begin
  set constraints all immediate;
  select count(*) into n from sri_os.transactions where memo like 'CA %';
  if n < 8 then
    raise exception 'FAIL: นับใบที่เทสต์นี้สร้างได้แค่ % ใบ — เทสต์อาจไม่ได้ลงอะไรเลย', n;
  end if;
  raise notice 'ok CA · ทั้ง % ใบของไฟล์นี้ผ่านด่านที่เลื่อนไว้ (เคสปฏิเสธไม่ทิ้งใบเสียรูปไว้)', n;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: ใบที่เทสต์นี้สร้างไว้เสียรูป: %', sqlerrm;
end $$;

rollback;
