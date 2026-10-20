-- ============================================================
-- SRI OS · เทสต์ D-098 — รายการที่ void ต้อง "เห็นได้ แต่ตัดออกจากงบ"
--   migration ที่ทดสอบ: 20261020000001_void_columns_and_views.sql
--
-- สิ่งที่ต้องเป็นจริง (ตาม D-098 · ลูกพี่สั่ง 09/10):
--   V1 · void แล้วต้องรู้ว่าใคร เมื่อไหร่ ทำไม — voided_at · voided_by · void_reason
--        **บังคับทุกผู้ถือ** · เงื่อนไขสองทาง · แก้ย้อนหลังไม่ได้ · ผู้ยกเลิกเป็นคนจริง
--   V2 · งบทุกใบอ่านจาก v_ledger_posted (ไม่มี void) · หน้า "ยกเลิก" อ่าน v_ledger_voided
--        สองฝั่งแบ่งกันครบและไม่ทับกัน · เคารพ RLS ของผู้เรียก
--   V3 · guard พังเมื่อมี view/รายงานใหม่อ่านตารางฐานตรงๆ แทน v_ledger_posted
--
-- ร่าง/รออนุมัติอยู่ฝั่งไหน: `txn_status` มีสองค่า (posted · void) · **ร่างไม่ได้อยู่ใน
--   transactions เลย** อยู่ตาราง draft_entries ต่างหาก → ร่างไม่อยู่ในวิวไหนทั้งสองอัน
--   โดยเจตนา (งบต้องไม่รวมร่าง · หน้ารายการที่ยกเลิกก็ไม่ใช่ร่าง)
--   เคส V8 วน **ทุก enumlabel ที่ schema ยอมให้มี** ไม่ใช่สองค่าที่นึกออก → ถ้าวันหนึ่ง
--   มีใครเพิ่มค่าใหม่ เทสต์นี้แดงทันทีพร้อมบอกว่าแถวของค่านั้นตกหล่นทั้งสองฝั่ง
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ **rollback** ปิดท้าย — ไม่ทิ้งรายการเงินไว้
--   ด่านหลายตัวของสมุดเป็น `constraint trigger ... deferrable initially deferred`
--   → ใช้ pg_temp.fire() ยิงเดี๋ยวนี้แล้วคืนสภาพ deferred (แพทเทิร์นเดียวกับ
--     zz_reverse_integrity_test / zz_line_guards_test)
--
-- รันในฐานะ superuser ของ cluster = ข้าม RLS แต่ **trigger/constraint ยังทำงานทุกเส้นทาง**
--   (กฎเงินต้องไม่ขึ้นกับสิทธิ์) · V9 เดินเส้นทางอ่านจริงด้วย role authenticated อีกชั้น
--
-- mutation ที่ต้องทำให้เทสต์แดง (ถ้าไม่แดง = เทสต์ยังไม่ครอบ):
--   V1 ถอดเงื่อนไข void_reason ออกจาก constraint        → V1a V1b V1d V2a แดง
--   V2 ให้ v_ledger_posted รวมแถว void ด้วย              → V6 V7 V8 แดง
--   V3 ถอด security_invoker ออกจาก view (+ ถอน event
--      trigger trg_force_view_security_invoker ไม่ให้
--      ใส่คืนอัตโนมัติ)                                  → V9 แดง
--   V4 ยอมให้แก้ void_reason ย้อนหลัง                     → V3c V3d แดง
--   V5 ถอด guard fn_assert_ledger_read_path               → V10 แดง
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
-- ผู้ใช้สามคน:
--   v_mgmt  · management  (owner.view_all + ledger.read + portfolio.view_all) = เห็นทุกผู้ถือ
--   v_mgr   · manager     (ledger.read แต่ **ไม่มี** owner.view_all / portfolio.view_all)
--             → เห็นเฉพาะผู้ถือที่ถูกแจกให้ และเฉพาะรายการที่ตัวเองคีย์ · ใช้พิสูจน์ RLS
--   v_other · management  แต่ **ไม่ใช่คนที่กดยกเลิก** · ใช้พิสูจน์ว่าโยนความผิดให้คนอื่นไม่ได้
create temporary table t_vuid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_vuid(label) values ('v_mgmt'), ('v_mgr'), ('v_other');
insert into auth.users(id) select id from t_vuid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select id, label || '@void.local', label,
       case when label = 'v_mgr' then 'manager' else 'management' end, true
  from t_vuid;

create or replace function pg_temp.vuid(p_label text) returns uuid
language sql stable as $fn$ select id from t_vuid where label = p_label $fn$;

create or replace function pg_temp.vlogin(p_label text) returns void
language sql as $fn$
  select set_config('test.uid', coalesce((select id::text from t_vuid where label = p_label), ''), true);
$fn$;

create or replace function pg_temp.own(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.owners where code = p_code $fn$;

create or replace function pg_temp.coa(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.chart_of_accounts where code = p_code $fn$;

-- management เห็นทุกผู้ถืออยู่แล้วจาก owner.view_all · manager ได้เฉพาะ THANAKORN
-- (ไม่แจก SUTEE ให้โดยตั้งใจ — นั่นคือแถวที่ V9 ต้องพิสูจน์ว่าอ่านผ่าน view ก็ไม่เห็น)
insert into sri_os.user_owner_access(user_id, owner_id)
select pg_temp.vuid('v_mgr'), pg_temp.own('THANAKORN');

-- ยิงด่านที่เลื่อนไว้ทั้งหมดเดี๋ยวนี้ แล้วคืนสภาพ deferred
create or replace function pg_temp.fire() returns void
language plpgsql as $fn$
begin
  set constraints all immediate;
  set constraints all deferred;
end $fn$;

-- เคสที่ "ควรถูกปฏิเสธแต่สำเร็จ" ต้องย้อนของที่เพิ่งเขียนทิ้งด้วย ไม่งั้นเคสถัดไป
-- จะล้มด้วยเหตุผลอื่น แล้วรายงานผล mutation ชี้ผิดจุด (แพทเทิร์นจาก zz_reverse_integrity)
create or replace function pg_temp.must_fail_like(p_label text, p_sql text, p_needle text) returns void
language plpgsql as $fn$
declare v text;
begin
  begin
    execute p_sql;
    perform pg_temp.fire();
    raise exception 'VD_UNEXPECTED_SUCCESS';
  exception when others then
    v := sqlerrm;
    if v = 'VD_UNEXPECTED_SUCCESS' then
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
  perform pg_temp.fire();
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: % — เส้นทางที่ถูกต้องถูกปฏิเสธ (กันแน่นเกิน): %', p_label, sqlerrm;
end $fn$;

-- ใบตั้งค้างจ่าย: Dr 5900 ค่าใช้จ่ายอื่น / Cr 2100 เจ้าหนี้ค้างจ่าย (ไม่มีขาเงินสด)
--   หมวด exp.other ตั้งค้างจ่ายได้จริง (can_accrue = true · D-107)
--   created_by ถูก fn_txn_system_columns ตั้งเป็น auth.uid() ให้เอง → ต้อง vlogin ก่อนเรียก
create or replace function pg_temp.mk(p_id uuid, p_owner text, p_amt numeric,
                                     p_status text default 'posted',
                                     p_voided_by uuid default null) returns uuid
language plpgsql as $fn$
begin
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, memo, attachments,
                                  status, voided_at, voided_by, void_reason)
  values (p_id, pg_temp.own(p_owner), 'exp.other', current_date, 'VD ' || p_id::text,
          array['หลักฐาน-VD.pdf'], p_status::sri_os.txn_status,
          case when p_status = 'void' then now() end,
          case when p_status = 'void' then coalesce(p_voided_by, auth.uid()) end,
          case when p_status = 'void' then 'เทสต์: ลงมาเป็น void ตั้งแต่ต้น' end);
  insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit, cf_category, memo)
  values (p_id, pg_temp.coa('5900'), p_amt, 0, 'none', 'ขาค่าใช้จ่าย'),
         (p_id, pg_temp.coa('2100'), 0, p_amt, 'none', 'ขาเจ้าหนี้');
  perform pg_temp.fire();
  return p_id;
end $fn$;

-- ท่อน SQL ของการ void ที่ถูกต้อง (เขียนที่เดียว ใช้หลายเคส)
create or replace function pg_temp.void_sql(p_id uuid, p_reason text default 'ลงผิดใบ ยกเลิกแล้วลงใหม่')
returns text language sql immutable as $fn$
  select format($q$ update sri_os.transactions
                       set status = 'void', voided_at = now(),
                           voided_by = auth.uid(), void_reason = %L
                     where id = %L $q$, p_reason, p_id);
$fn$;

-- ============================================================
-- V1 · void โดยไม่ใส่ร่องรอยให้ครบ → ปฏิเสธ · ใส่ครบ → ผ่าน
--   ไล่ทีละคอลัมน์ เพราะ "ส่งข้อมูลครบเสมอจะไม่มีวันแตะเส้นทางที่ข้อมูลขาด"
--   (บทเรียนข้อ 3 ของ mace-windu) · ทำทั้งฝั่งบุคคลและนิติบุคคล เพราะ D-098
--   ตัดสินว่า void_reason บังคับ **ทุกผู้ถือ** ไม่ใช่แค่ corporate_strict
-- ============================================================
do $$
declare
  v_p1 uuid := '00000000-0000-0000-0000-0000000d0001';   -- บุคคล (THANAKORN)
  v_p2 uuid := '00000000-0000-0000-0000-0000000d0002';
  v_p3 uuid := '00000000-0000-0000-0000-0000000d0003';
  v_p4 uuid := '00000000-0000-0000-0000-0000000d0004';
  v_c1 uuid := '00000000-0000-0000-0000-0000000d0005';   -- นิติบุคคล (SRI_HOLDING)
  v_st text;
begin
  perform pg_temp.vlogin('v_mgmt');
  perform pg_temp.mk(v_p1, 'THANAKORN', 1000);
  perform pg_temp.mk(v_p2, 'THANAKORN', 1000);
  perform pg_temp.mk(v_p3, 'THANAKORN', 1000);
  perform pg_temp.mk(v_p4, 'THANAKORN', 1000);
  perform pg_temp.mk(v_c1, 'SRI_HOLDING', 1000);

  -- V1a · void เปล่าๆ ไม่ใส่อะไรเลย (เส้นทางที่โค้ด/หน้าจอเดิมใช้) → ต้องปฏิเสธ
  perform pg_temp.must_fail_like('V1a void โดยไม่ใส่เหตุผลเลย (บุคคล)', format(
    $q$ update sri_os.transactions set status = 'void' where id = %L $q$, v_p1),
    'ยกเลิกรายการต้องบันทึกให้ครบ');
  select status::text into v_st from sri_os.transactions where id = v_p1;
  if v_st <> 'posted' then
    raise exception 'FAIL: V1a รายการกลายเป็น % ทั้งที่ไม่มีเหตุผล → ผีที่ไม่มีคำอธิบายเกิดขึ้นได้', v_st;
  end if;

  -- V1b · ใส่เวลา+คน แต่ไม่มีเหตุผล → ต้องปฏิเสธ (เหตุผลคือข้อที่ D-098 ตัดสินเอง)
  perform pg_temp.must_fail_like('V1b void แต่ไม่มี void_reason', format(
    $q$ update sri_os.transactions
           set status = 'void', voided_at = now(), voided_by = auth.uid()
         where id = %L $q$, v_p1),
    'ยกเลิกรายการต้องบันทึกให้ครบ');

  -- V1c · เหตุผลเป็นช่องว่างล้วน = ไม่มีเหตุผล → ต้องปฏิเสธ
  perform pg_temp.must_fail_like('V1c void_reason เป็นช่องว่างล้วน', format(
    $q$ update sri_os.transactions
           set status = 'void', voided_at = now(), voided_by = auth.uid(),
               void_reason = '   '
         where id = %L $q$, v_p1),
    'ยกเลิกรายการต้องบันทึกให้ครบ');

  -- V1d · มีเหตุผลแต่ไม่มีเวลา → ต้องปฏิเสธ (ร่องรอยที่ตอบ "เมื่อไหร่" ไม่ได้)
  perform pg_temp.must_fail_like('V1d void แต่ไม่มี voided_at', format(
    $q$ update sri_os.transactions
           set status = 'void', voided_by = auth.uid(), void_reason = 'ลงผิดใบ'
         where id = %L $q$, v_p1),
    'ยกเลิกรายการต้องบันทึกให้ครบ');

  -- V1e · มีเหตุผลแต่ไม่มีคน → ต้องปฏิเสธ (ร่องรอยที่ตอบ "ใคร" ไม่ได้)
  perform pg_temp.must_fail_like('V1e void แต่ไม่มี voided_by', format(
    $q$ update sri_os.transactions
           set status = 'void', voided_at = now(), void_reason = 'ลงผิดใบ'
         where id = %L $q$, v_p1),
    'ยกเลิกรายการต้องบันทึกให้ครบ');

  -- V1f · ใส่ครบ → ต้องผ่าน (ห้ามกันแน่นเกิน ไม่งั้นยกเลิกรายการไม่ได้เลยทั้งระบบ)
  perform pg_temp.must_pass('V1f void ใส่ร่องรอยครบ (บุคคล)', pg_temp.void_sql(v_p1));
  select status::text into v_st from sri_os.transactions where id = v_p1;
  if v_st <> 'void' then raise exception 'FAIL: V1f void ไม่สำเร็จ (status %)', v_st; end if;
  if not exists (
    select 1 from sri_os.transactions
     where id = v_p1 and voided_at is not null and voided_by = pg_temp.vuid('v_mgmt')
       and void_reason = 'ลงผิดใบ ยกเลิกแล้วลงใหม่'
  ) then
    raise exception 'FAIL: V1f ร่องรอยการยกเลิกไม่ถูกบันทึกตามที่ส่งมา';
  end if;

  -- V1g · ฝั่งนิติบุคคลก็ต้องใส่เหตุผลเหมือนกัน (ไม่ใช่กฎที่ใช้กับ corporate เท่านั้น
  --        และไม่ใช่กฎที่ฝั่งบุคคล override ได้)
  perform pg_temp.must_fail_like('V1g void โดยไม่ใส่เหตุผล (นิติบุคคล)', format(
    $q$ update sri_os.transactions set status = 'void' where id = %L $q$, v_c1),
    'ยกเลิกรายการต้องบันทึกให้ครบ');
  perform pg_temp.must_pass('V1g void ใส่ร่องรอยครบ (นิติบุคคล)', pg_temp.void_sql(v_c1));

  raise notice 'ok V1 · void ต้องมี voided_at + voided_by + void_reason ครบทั้งสามช่อง · บังคับทั้งฝั่งบุคคลและนิติบุคคล · ใส่ครบแล้วยังทำได้';
end $$;

-- ============================================================
-- V1h · ชั้นที่สอง — ปิด trigger แล้ว **constraint ต้องยังปฏิเสธ**
--   ทำไมต้องมีเคสนี้: trigger ยิงก่อน constraint เสมอ → ถ้าวัดแต่ข้อความของ trigger
--   วันหนึ่งใครถอดเงื่อนไข void_reason ออกจาก constraint จะไม่มีเทสต์ไหนแดง
--   แล้วเส้นทางที่ trigger ไม่ครอบ (เช่นแถวที่ถูกเขียนตอน trigger ถูกปิด) จะหลุด
--   D-098 กำหนดให้ **บังคับที่ DB** ไม่ใช่ที่ชั้นใดชั้นเดียว (กฎเหล็ก + Money Invariant)
-- ============================================================
do $$
declare v_id uuid := '00000000-0000-0000-0000-0000000d0007';
begin
  perform pg_temp.vlogin('v_mgmt');
  perform pg_temp.mk(v_id, 'THANAKORN', 450);

  execute 'alter table sri_os.transactions disable trigger trg_void_audit_columns';
  begin
    -- ทิศที่หนึ่ง: void โดยไม่มีร่องรอย
    perform pg_temp.must_fail_like('V1h void ไม่มีเหตุผล (ชั้น constraint ล้วน)', format(
      $q$ update sri_os.transactions set status = 'void' where id = %L $q$, v_id),
      'transactions_void_fields_both_ways');
    -- เหตุผลเป็นช่องว่างล้วนก็ต้องตกที่ชั้นนี้ด้วย (btrim อยู่ใน constraint จริง ไม่ใช่แค่ trigger)
    perform pg_temp.must_fail_like('V1h void_reason ช่องว่างล้วน (ชั้น constraint ล้วน)', format(
      $q$ update sri_os.transactions
             set status = 'void', voided_at = now(), voided_by = auth.uid(), void_reason = ' '
           where id = %L $q$, v_id),
      'transactions_void_fields_both_ways');
    -- ทิศที่สอง: แปะเหตุผลบนรายการที่ยัง posted
    perform pg_temp.must_fail_like('V2e แปะ void_reason บน posted (ชั้น constraint ล้วน)', format(
      $q$ update sri_os.transactions set void_reason = 'จดไว้เฉยๆ' where id = %L $q$, v_id),
      'transactions_void_fields_both_ways');
  exception when others then
    execute 'alter table sri_os.transactions enable trigger trg_void_audit_columns';
    raise;
  end;
  execute 'alter table sri_os.transactions enable trigger trg_void_audit_columns';

  if not exists (select 1 from pg_trigger
                  where tgrelid = 'sri_os.transactions'::regclass
                    and tgname = 'trg_void_audit_columns' and tgenabled = 'O') then
    raise exception 'FAIL: V1h เปิด trg_void_audit_columns คืนไม่สำเร็จ — เคสถัดไปจะวัดผิด';
  end if;

  raise notice 'ok V1h/V2e · ชั้น constraint ปฏิเสธเองได้ทั้งสองทิศแม้ปิด trigger (กฎอยู่สองชั้นจริง)';
end $$;

-- ============================================================
-- V2 · ทิศที่สอง — มีค่าในคอลัมน์พวกนี้ แต่สถานะไม่ใช่ void → ปฏิเสธ
--   ถ้าปล่อย: แปะ "เหตุผลที่ยกเลิก" ไว้บนรายการที่ยัง posted ได้
--   คนอ่านสมุดเห็นรายการที่ดูเหมือนถูกยกเลิก แต่ตัวเลขยังถูกนับในงบ
-- ============================================================
do $$
declare v_id uuid := '00000000-0000-0000-0000-0000000d0002';
begin
  perform pg_temp.vlogin('v_mgmt');

  perform pg_temp.must_fail_like('V2a แปะ void_reason บนรายการที่ยัง posted', format(
    $q$ update sri_os.transactions set void_reason = 'อยากจดไว้เฉยๆ' where id = %L $q$, v_id),
    'มีค่าได้เมื่อ status = void เท่านั้น');

  perform pg_temp.must_fail_like('V2b แปะ voided_at บนรายการที่ยัง posted', format(
    $q$ update sri_os.transactions set voided_at = now() where id = %L $q$, v_id),
    'มีค่าได้เมื่อ status = void เท่านั้น');

  perform pg_temp.must_fail_like('V2c แปะ voided_by บนรายการที่ยัง posted', format(
    $q$ update sri_os.transactions set voided_by = auth.uid() where id = %L $q$, v_id),
    'มีค่าได้เมื่อ status = void เท่านั้น');

  -- insert ใหม่เข้ามาพร้อมร่องรอยแต่สถานะ posted ก็ไม่ได้ (รูเดียวกันคนละประตู)
  perform pg_temp.must_fail_like('V2d insert รายการ posted พร้อม void_reason',
    $q$ insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, attachments,
                                        void_reason)
        values ('00000000-0000-0000-0000-0000000d00d4',
                (select id from sri_os.owners where code = 'THANAKORN'),
                'exp.other', current_date, array['x.pdf'], 'ยกเลิกแล้วนะ (แต่สถานะยัง posted)') $q$,
    'มีค่าได้เมื่อ status = void เท่านั้น');

  if exists (select 1 from sri_os.transactions
              where status <> 'void'
                and (voided_at is not null or voided_by is not null or void_reason is not null)) then
    raise exception 'FAIL: V2 มีรายการที่ยังไม่ void แต่มีร่องรอยการยกเลิกค้างอยู่';
  end if;

  raise notice 'ok V2 · ร่องรอยการยกเลิกมีค่าได้เมื่อ status = void เท่านั้น (ทั้ง UPDATE และ INSERT)';
end $$;

-- ============================================================
-- V3 · แก้ / ล้าง ร่องรอยการยกเลิกย้อนหลัง → ปฏิเสธทุก role
--   ต่อแพทเทิร์น 20261008000004 (คอลัมน์แก้ย้อนหลังไม่ได้)
--   รันในฐานะ superuser ของ cluster = ถ้าผ่านที่นี่ แปลว่ากฎอยู่ที่ RLS ไม่ใช่ trigger
-- ============================================================
do $$
declare
  v_id uuid := '00000000-0000-0000-0000-0000000d0001';   -- void แล้วจาก V1f
  v_reason text;
begin
  perform pg_temp.vlogin('v_mgmt');

  perform pg_temp.must_fail_like('V3a แก้ voided_at ทีหลัง', format(
    $q$ update sri_os.transactions set voided_at = now() + interval '1 day' where id = %L $q$, v_id),
    'แก้ย้อนหลังไม่ได้');

  perform pg_temp.must_fail_like('V3b แก้ voided_by ทีหลัง', format(
    $q$ update sri_os.transactions set voided_by = %L where id = %L $q$,
    pg_temp.vuid('v_other'), v_id), 'แก้ย้อนหลังไม่ได้');

  perform pg_temp.must_fail_like('V3c แก้ void_reason ทีหลัง', format(
    $q$ update sri_os.transactions set void_reason = 'เปลี่ยนใจ เขียนใหม่' where id = %L $q$, v_id),
    'แก้ย้อนหลังไม่ได้');

  perform pg_temp.must_fail_like('V3d ล้าง void_reason เป็น null', format(
    $q$ update sri_os.transactions set void_reason = null where id = %L $q$, v_id),
    'แก้ย้อนหลังไม่ได้');

  perform pg_temp.must_fail_like('V3e ล้างทั้งสามช่องพร้อมกัน', format(
    $q$ update sri_os.transactions
           set voided_at = null, voided_by = null, void_reason = null
         where id = %L $q$, v_id),
    'แก้ย้อนหลังไม่ได้');

  select void_reason into v_reason from sri_os.transactions where id = v_id;
  if v_reason <> 'ลงผิดใบ ยกเลิกแล้วลงใหม่' then
    raise exception 'FAIL: V3 เหตุผลเดิมถูกเขียนทับไปแล้ว (ได้ %)', v_reason;
  end if;

  -- UPDATE ที่ **ไม่แตะ** สามคอลัมน์นั้นยังทำได้ (void ซ้ำ / แก้ memo ภายใน)
  -- ไม่งั้นแถวที่ void แล้วจะแก้อะไรไม่ได้เลยและเส้นทางเดิมของไฟล์อื่นตาย
  perform pg_temp.must_pass('V3f void ซ้ำบนแถวที่ void แล้ว (ไม่แตะร่องรอย)', format(
    $q$ update sri_os.transactions set status = 'void' where id = %L $q$, v_id));

  raise notice 'ok V3 · ร่องรอยการยกเลิกแก้/ล้างย้อนหลังไม่ได้แม้ในฐานะเจ้าของฐานข้อมูล · UPDATE ที่ไม่แตะสามช่องนั้นยังทำได้';
end $$;

-- ============================================================
-- V4 · "คนจริงที่ตรวจสอบย้อนได้" ไม่ใช่ข้อความที่พิมพ์อะไรก็ได้
-- ============================================================
do $$
declare v_id uuid := '00000000-0000-0000-0000-0000000d0002';
begin
  perform pg_temp.vlogin('v_mgmt');

  -- V4a · ชี้ไป uuid ที่ไม่มีใน app_users → FK ปฏิเสธ
  --   ทดสอบตอน **ไม่ล็อกอิน** (งานระบบ/migration) เพราะถ้าล็อกอินอยู่ ด่าน "ต้องเป็น
  --   คนที่กำลังกด" จะยิงก่อน แล้วเคสนี้จะไม่เคยแตะชั้น FK เลย (บทเรียนข้อ 3)
  perform pg_temp.vlogin('(ไม่ล็อกอิน)');
  perform pg_temp.must_fail_like('V4a voided_by ไม่ใช่ผู้ใช้ที่มีอยู่จริง', format(
    $q$ update sri_os.transactions
           set status = 'void', voided_at = now(),
               voided_by = '00000000-0000-0000-0000-00000000dead',
               void_reason = 'ลงผิด'
         where id = %L $q$, v_id),
    'voided_by_fkey');
  perform pg_temp.vlogin('v_mgmt');

  -- V4b · โยนความผิดให้คนอื่น (ผู้ใช้มีจริง แต่ไม่ใช่คนที่กำลังกด) → ปฏิเสธ
  perform pg_temp.must_fail_like('V4b บันทึกว่าคนอื่นเป็นคนยกเลิก', format(
    $q$ update sri_os.transactions
           set status = 'void', voided_at = now(), voided_by = %L, void_reason = 'ลงผิด'
         where id = %L $q$, pg_temp.vuid('v_other'), v_id),
    'ไม่ใช่ผู้ใช้ที่กำลังยกเลิก');

  raise notice 'ok V4 · ผู้ยกเลิกต้องมีอยู่จริงใน app_users และต้องเป็นคนที่กำลังกดเอง';
end $$;

-- ============================================================
-- V5 · เวลาที่ยกเลิกต้องเป็นเวลาที่เกิดขึ้นจริง
--   ปลอม voided_at ย้อนไปอยู่งวดก่อนหน้า = ร่องรอยที่โกหกผู้สอบบัญชี
-- ============================================================
do $$
declare v_id uuid := '00000000-0000-0000-0000-0000000d0002';
begin
  perform pg_temp.vlogin('v_mgmt');

  perform pg_temp.must_fail_like('V5a voided_at อยู่ในอนาคต', format(
    $q$ update sri_os.transactions
           set status = 'void', voided_at = now() + interval '2 days',
               voided_by = auth.uid(), void_reason = 'ลงผิด'
         where id = %L $q$, v_id),
    'อยู่ในอนาคต');

  perform pg_temp.must_fail_like('V5b voided_at ก่อนวันที่สร้างรายการ', format(
    $q$ update sri_os.transactions
           set status = 'void', voided_at = now() - interval '90 days',
               voided_by = auth.uid(), void_reason = 'ลงผิด'
         where id = %L $q$, v_id),
    'ก่อนเวลาที่สร้างรายการ');

  raise notice 'ok V5 · voided_at ปลอมไปอนาคตหรือย้อนก่อนวันสร้างรายการไม่ได้';
end $$;

-- ============================================================
-- V6 · แถวที่ void หายจาก v_ledger_posted และโผล่ใน v_ledger_voided
--   พร้อมร่องรอยครบ (ไม่งั้น "เห็นได้" แต่เป็นผีที่ไม่มีคำอธิบาย)
-- ============================================================
do $$
declare
  v_keep uuid := '00000000-0000-0000-0000-0000000d0003';
  v_kill uuid := '00000000-0000-0000-0000-0000000d0004';
  n int; v_reason text; v_by uuid;
begin
  perform pg_temp.vlogin('v_mgmt');

  -- ก่อน void: ทั้งสองใบอยู่ในงบ · ไม่มีใบไหนอยู่หน้ารายการที่ยกเลิก
  select count(*) into n from sri_os.v_ledger_posted where transaction_id in (v_keep, v_kill);
  if n <> 4 then raise exception 'FAIL: V6 ก่อน void ควรมี 4 บรรทัดในงบ แต่ได้ %', n; end if;
  select count(*) into n from sri_os.v_ledger_voided where transaction_id in (v_keep, v_kill);
  if n <> 0 then raise exception 'FAIL: V6 ก่อน void มี % บรรทัดอยู่หน้ารายการที่ยกเลิกแล้ว', n; end if;

  perform pg_temp.must_pass('V6 void หนึ่งใบ', pg_temp.void_sql(v_kill, 'ผู้เช่าโอนมาเกิน ยกเลิกใบนี้'));

  -- หลัง void: ใบที่ยกเลิก **หายจากงบ**
  select count(*) into n from sri_os.v_ledger_posted where transaction_id = v_kill;
  if n <> 0 then
    raise exception 'FAIL: V6 ใบที่ยกเลิกยังอยู่ในงบ % บรรทัด → "ตัดออกจากงบ" ไม่เกิดขึ้นจริง', n;
  end if;
  -- และใบที่ไม่ได้ยกเลิก **ยังอยู่** (ห้ามตัดมากเกินไป)
  select count(*) into n from sri_os.v_ledger_posted where transaction_id = v_keep;
  if n <> 2 then
    raise exception 'FAIL: V6 ใบที่ไม่ได้ยกเลิกเหลือ % บรรทัดในงบ (ต้อง 2) → ตัดเกิน', n;
  end if;

  -- โผล่ในหน้ารายการที่ยกเลิก **พร้อมร่องรอย**
  select count(*) into n from sri_os.v_ledger_voided where transaction_id = v_kill;
  if n <> 2 then
    raise exception 'FAIL: V6 ใบที่ยกเลิกโผล่ในหน้ารายการที่ยกเลิก % บรรทัด (ต้อง 2) → "เห็นได้" ไม่เกิดขึ้นจริง', n;
  end if;
  select distinct void_reason, voided_by into v_reason, v_by
    from sri_os.v_ledger_voided where transaction_id = v_kill;
  if v_reason <> 'ผู้เช่าโอนมาเกิน ยกเลิกใบนี้' or v_by <> pg_temp.vuid('v_mgmt') then
    raise exception 'FAIL: V6 หน้ารายการที่ยกเลิกไม่เห็นเหตุผล/ผู้ยกเลิก (เหตุผล % · คน %)', v_reason, v_by;
  end if;
  if not exists (select 1 from sri_os.v_ledger_voided
                  where transaction_id = v_kill and voided_at is not null) then
    raise exception 'FAIL: V6 หน้ารายการที่ยกเลิกไม่เห็นเวลาที่ยกเลิก';
  end if;

  -- v_ledger_voided ต้องไม่มีของที่ยัง posted หลุดเข้าไป
  if exists (select 1 from sri_os.v_ledger_voided where status <> 'void') then
    raise exception 'FAIL: V6 v_ledger_voided มีแถวที่สถานะไม่ใช่ void';
  end if;
  if exists (select 1 from sri_os.v_ledger_posted where status <> 'posted') then
    raise exception 'FAIL: V6 v_ledger_posted มีแถวที่สถานะไม่ใช่ posted → งบนับของที่ไม่ควรนับ';
  end if;

  raise notice 'ok V6 · void แล้วหายจาก v_ledger_posted · โผล่ใน v_ledger_voided พร้อมร่องรอยครบ (ใคร เมื่อไหร่ ทำไม)';
end $$;

-- ============================================================
-- V7 · งบต้องยังสมดุลหลัง void — Σ debit = Σ credit ใน v_ledger_posted
--   void ตัดออก **ทั้งใบ** ไม่ใช่ตัดบางบรรทัด · ตัดขาเดียวคือสมุดเสียสมดุล
-- ============================================================
do $$
declare v_dr numeric; v_cr numeric; v_before numeric; v_after numeric;
        v_id uuid := '00000000-0000-0000-0000-0000000d0006';
begin
  perform pg_temp.vlogin('v_mgmt');

  select coalesce(sum(debit), 0) into v_before from sri_os.v_ledger_posted;
  perform pg_temp.mk(v_id, 'THANAKORN', 7777);
  perform pg_temp.must_pass('V7 void ใบที่เพิ่งลง', pg_temp.void_sql(v_id, 'ลงซ้ำกับใบก่อน'));
  select coalesce(sum(debit), 0) into v_after from sri_os.v_ledger_posted;
  if v_after <> v_before then
    raise exception 'FAIL: V7 ยอดในงบเปลี่ยนจาก % เป็น % หลังลงแล้ว void ทั้งใบ (ต้องเท่าเดิม)', v_before, v_after;
  end if;

  select coalesce(sum(debit), 0), coalesce(sum(credit), 0) into v_dr, v_cr
    from sri_os.v_ledger_posted;
  if v_dr <> v_cr then
    raise exception 'FAIL: V7 งบไม่สมดุลหลัง void (เดบิต % · เครดิต %) → void ตัดบรรทัดไม่ครบใบ', v_dr, v_cr;
  end if;
  if v_dr = 0 then
    raise exception 'FAIL: V7 งบว่างเปล่า — เคสนี้ไม่ได้วัดอะไรเลย (view อาจกรองทุกอย่างออก)';
  end if;

  -- ฝั่งรายการที่ยกเลิกก็ต้องสมดุลในตัวเอง (ใบที่ยกเลิกยังเป็นใบที่ลงถูกต้อง)
  select coalesce(sum(debit), 0), coalesce(sum(credit), 0) into v_dr, v_cr
    from sri_os.v_ledger_voided;
  if v_dr <> v_cr then
    raise exception 'FAIL: V7 v_ledger_voided ไม่สมดุล (เดบิต % · เครดิต %)', v_dr, v_cr;
  end if;

  raise notice 'ok V7 · Σ เดบิต = Σ เครดิต ใน v_ledger_posted หลัง void (และยอดกลับไปเท่าก่อนลงใบที่ถูกยกเลิก)';
end $$;

-- ============================================================
-- V8 · สองฝั่งแบ่งกันครบและไม่ทับกัน — **วนทุกค่าของ status ที่ schema ยอมให้มี**
--   ไม่ใช่สองค่าที่นึกออก · ถ้ามีใครเพิ่มค่าใน txn_status แล้วไม่กลับมาตัดสินว่า
--   ค่านั้นอยู่ฝั่งไหน เคสนี้แดงทันทีพร้อมบอกชื่อค่า
-- ============================================================
do $$
declare
  r record; v_id uuid; v_np int; v_nv int; n int; v_labels text;
begin
  perform pg_temp.vlogin('v_mgmt');

  select string_agg(e.enumlabel, ', ' order by e.enumsortorder) into v_labels
    from pg_enum e where e.enumtypid = 'sri_os.txn_status'::regtype;
  if v_labels is null then
    raise exception 'FAIL: V8 อ่านค่าของ txn_status จาก pg_enum ไม่ได้ — เคสนี้ไม่ได้วัดอะไรเลย';
  end if;
  raise notice '   V8 · ค่าของ txn_status ที่ schema ยอมให้มีวันนี้: %', v_labels;

  for r in
    select e.enumlabel::text as lbl from pg_enum e
     where e.enumtypid = 'sri_os.txn_status'::regtype
     order by e.enumsortorder
  loop
    v_id := gen_random_uuid();
    begin
      perform pg_temp.mk(v_id, 'THANAKORN', 321, r.lbl);
    exception when others then
      if sqlerrm like 'FAIL:%' then raise; end if;
      raise exception 'FAIL: V8 ลงรายการสถานะ "%" ไม่ได้ (%) · ค่าใหม่ใน txn_status ต้องมาพร้อมการตัดสินว่าอยู่ฝั่งไหนและ fixture ที่ลงได้จริง', r.lbl, sqlerrm;
    end;

    select count(*) into v_np from sri_os.v_ledger_posted where transaction_id = v_id;
    select count(*) into v_nv from sri_os.v_ledger_voided where transaction_id = v_id;

    if v_np > 0 and v_nv > 0 then
      raise exception 'FAIL: V8 สถานะ "%" อยู่ทั้งสองฝั่ง (งบ % บรรทัด · ยกเลิก % บรรทัด) → นับซ้ำ', r.lbl, v_np, v_nv;
    end if;
    if v_np + v_nv <> 2 then
      raise exception 'FAIL: V8 สถานะ "%" มี 2 บรรทัดในสมุด แต่โผล่ในวิวรวมกันแค่ % บรรทัด → แถวตกหล่นทั้งสองฝั่งโดยไม่มีใครตัดสิน · ต้องกลับไปตัดสินว่าสถานะนี้อยู่ฝั่งไหน (งบ = posted · รายการที่ยกเลิก = void · ร่างอยู่ตาราง draft_entries ไม่ใช่ที่นี่)', r.lbl, v_np + v_nv;
    end if;
    raise notice '   V8 · สถานะ "%" อยู่ฝั่ง % เพียงฝั่งเดียว (2 บรรทัด)',
      r.lbl, case when v_np > 0 then 'งบ (v_ledger_posted)' else 'รายการที่ยกเลิก (v_ledger_voided)' end;
  end loop;

  -- ระดับทั้งตาราง (รวมแถวที่ไฟล์เทสต์อื่น commit ไว้ด้วย): ครบ และไม่ทับกัน
  select count(*) into n from (
    select l.id from sri_os.transaction_lines l
      join sri_os.transactions t on t.id = l.transaction_id
    except
    (select line_id from sri_os.v_ledger_posted
      union all
     select line_id from sri_os.v_ledger_voided)
  ) x;
  if n <> 0 then
    raise exception 'FAIL: V8 มีบรรทัดบัญชี % บรรทัดที่ไม่อยู่ในวิวไหนเลย → ตัวเลขหายไปจากทั้งงบและหน้ารายการที่ยกเลิก', n;
  end if;

  select count(*) into n from (
    select line_id from sri_os.v_ledger_posted
    intersect
    select line_id from sri_os.v_ledger_voided
  ) x;
  if n <> 0 then
    raise exception 'FAIL: V8 มีบรรทัด % บรรทัดอยู่ทั้งสองวิว → นับซ้ำ', n;
  end if;

  raise notice 'ok V8 · ทุกค่าของ txn_status ตกฝั่งใดฝั่งหนึ่งเพียงฝั่งเดียว · ทั้งตารางไม่มีบรรทัดตกหล่นและไม่มีบรรทัดซ้อนสองฝั่ง';
end $$;

-- ============================================================
-- V9 · view ต้องเคารพ RLS ของ **ผู้เรียก** ไม่ใช่ของเจ้าของ view
--   (security_invoker) · ผู้ใช้ที่ไม่มีสิทธิ์ในแถวนั้น อ่านผ่าน view ก็ต้องไม่เห็น
--   v_mgr = manager · ได้ขอบเขตแค่ THANAKORN · ไม่มี owner.view_all
-- ============================================================
do $$
declare
  v_a uuid := '00000000-0000-0000-0000-0000000d0091';   -- THANAKORN (เห็นได้)
  v_b uuid := '00000000-0000-0000-0000-0000000d0092';   -- SUTEE (ต้องไม่เห็น)
  n_a int; n_b int; n_all int;
begin
  -- ลงทั้งสองใบในฐานะ v_mgr เอง (fn_txn_system_columns ตั้ง created_by = auth.uid())
  -- → ถ้า v_mgr ไม่เห็นใบ SUTEE แปลว่าตกที่ชั้นขอบเขตผู้ถือจริง ไม่ใช่ตกเพราะ "ไม่ได้คีย์เอง"
  perform pg_temp.vlogin('v_mgr');
  perform pg_temp.mk(v_a, 'THANAKORN', 150);
  perform pg_temp.mk(v_b, 'SUTEE', 150);

  execute 'set local role authenticated';

  select count(*) into n_a from sri_os.v_ledger_posted where transaction_id = v_a;
  select count(*) into n_b from sri_os.v_ledger_posted where transaction_id = v_b;
  select count(*) into n_all from sri_os.v_ledger_posted;

  execute 'reset role';

  if n_a <> 2 then
    raise exception 'FAIL: V9 ผู้ใช้ที่มีสิทธิ์อ่านรายการของตัวเองผ่าน view ไม่ได้ (เห็น % บรรทัด ต้อง 2) — กันแน่นเกินจนหน้างบใช้ไม่ได้', n_a;
  end if;
  if n_b <> 0 then
    raise exception 'FAIL: V9 ผู้ใช้ที่ไม่มีสิทธิ์ในผู้ถือรายนั้น **เห็นแถวผ่าน view** (% บรรทัด) → view ไม่ได้ใช้ RLS ของผู้เรียก (security_invoker หาย) = สมุดของทุกผู้ถือรั่ว', n_b;
  end if;

  -- ขาควบคุม: เจ้าของฐานข้อมูล/management เห็นทั้งสองใบ → เคสบนไม่ได้เขียวเพราะวิวว่าง
  select count(*) into n_all from sri_os.v_ledger_posted where transaction_id in (v_a, v_b);
  if n_all <> 4 then
    raise exception 'FAIL: V9 ขาควบคุม — ควรเห็น 4 บรรทัดเมื่อไม่ถูก RLS กรอง แต่ได้ % (เคส V9 อาจเขียวเพราะวิวว่างเปล่า)', n_all;
  end if;

  raise notice 'ok V9 · v_ledger_posted กรองด้วย RLS ของผู้เรียก (เห็นผู้ถือที่ตัวเองมีสิทธิ์ · ไม่เห็นที่ไม่มีสิทธิ์) และขาควบคุมยืนยันว่าวิวไม่ว่าง';
end $$;

-- ============================================================
-- V9b · สิทธิ์ระดับ GRANT ของสองวิว
-- ============================================================
do $$
declare r record;
begin
  for r in select unnest(array['v_ledger_posted', 'v_ledger_voided']) as rel loop
    if not has_table_privilege('authenticated', 'sri_os.' || r.rel, 'select') then
      raise exception 'FAIL: V9b authenticated อ่าน sri_os.% ไม่ได้ → หน้างบใช้งานไม่ได้', r.rel;
    end if;
    if has_table_privilege('anon', 'sri_os.' || r.rel, 'select') then
      raise exception 'FAIL: V9b anon อ่าน sri_os.% ได้ → สมุดครอบครัวอ่านได้ด้วย anon key ที่ฝังในหน้าเว็บ', r.rel;
    end if;
    if has_table_privilege('authenticated', 'sri_os.' || r.rel, 'insert')
       or has_table_privilege('authenticated', 'sri_os.' || r.rel, 'update')
       or has_table_privilege('authenticated', 'sri_os.' || r.rel, 'delete') then
      raise exception 'FAIL: V9b authenticated เขียนผ่าน sri_os.% ได้ → เขียนสมุดอ้อม view ได้ (ข้ามด่านของตารางฐาน)', r.rel;
    end if;
    if not exists (
      select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'sri_os' and c.relname = r.rel
         and array_to_string(coalesce(c.reloptions, '{}'), ',') ilike '%security_invoker=true%'
    ) then
      raise exception 'FAIL: V9b view sri_os.% ไม่ได้ตั้ง security_invoker = true', r.rel;
    end if;
  end loop;
  raise notice 'ok V9b · สองวิว: authenticated อ่านได้อย่างเดียว · anon ไม่ได้เลย · security_invoker ตั้งไว้ครบ';
end $$;

-- ============================================================
-- V10 · guard ของ V3 — ทำของที่ละเมิดขึ้นมาแล้ว guard ต้องพัง
--   เรียก sri_os.fn_assert_ledger_read_path() ซึ่งเป็น **กฎตัวเดียวกัน**
--   ที่ migration เรียก (ไม่ได้เขียน query ซ้ำในเทสต์ = กฎอยู่ที่เดียว)
-- ============================================================
do $$
declare v_ok boolean;
begin
  -- ขาควบคุม: สภาพปัจจุบันต้องผ่าน ไม่งั้นเคสล่างเขียวเพราะอย่างอื่น
  perform sri_os.fn_assert_ledger_read_path();

  -- V10a · view ใหม่ที่อ่านตารางฐานตรงๆ (= รายงานที่ลืมกรอง void)
  execute 'create view sri_os.v_zz_void_probe as
             select t.id, t.status, l.debit
               from sri_os.transactions t
               join sri_os.transaction_lines l on l.transaction_id = t.id';
  v_ok := false;
  begin
    perform sri_os.fn_assert_ledger_read_path();
    v_ok := true;
  exception when others then
    if sqlerrm not like '%v_zz_void_probe%' then
      raise exception 'FAIL: V10a guard พังแต่ไม่ได้ชี้ชื่อ view ที่ผิด: %', sqlerrm;
    end if;
  end;
  execute 'drop view sri_os.v_zz_void_probe';
  if v_ok then
    raise exception 'FAIL: V10a สร้าง view ที่อ่าน transactions/transaction_lines ตรงๆ ได้โดย guard ไม่พัง → รายงานใหม่ที่ลืมกรอง void จะหลุดเงียบๆ (รูปแบบเดิมของบั๊กที่โปรเจกต์นี้เจอซ้ำที่สุด)';
  end if;

  -- V10b · ฟังก์ชันรายงาน (set-returning) ที่อ่านตารางฐานตรงๆ
  execute 'create function sri_os.fn_zz_void_probe() returns setof uuid
             language sql stable as $f$ select id from sri_os.transactions $f$';
  v_ok := false;
  begin
    perform sri_os.fn_assert_ledger_read_path();
    v_ok := true;
  exception when others then
    if sqlerrm not like '%fn_zz_void_probe%' then
      raise exception 'FAIL: V10b guard พังแต่ไม่ได้ชี้ชื่อฟังก์ชันที่ผิด: %', sqlerrm;
    end if;
  end;
  execute 'drop function sri_os.fn_zz_void_probe()';
  if v_ok then
    raise exception 'FAIL: V10b ฟังก์ชันรายงานที่อ่านตารางฐานตรงๆ หลุด guard → งบที่ลืมกรอง void เขียนได้โดยไม่มีอะไรจับ';
  end if;

  -- V10c · เก็บของแล้ว guard ต้องกลับมาผ่าน (guard ที่แดงค้างคือ guard ที่ทีมจะปิด)
  perform sri_os.fn_assert_ledger_read_path();

  -- V10d · view ของตัวเองสองตัวต้องยังอยู่ใน allow-list (ไม่ใช่ guard ที่ไม่เห็นอะไรเลย)
  if not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'sri_os' and c.relname = 'v_ledger_posted'
  ) then
    raise exception 'FAIL: V10d ไม่มี v_ledger_posted';
  end if;

  raise notice 'ok V10 · guard พังทันทีเมื่อมี view หรือฟังก์ชันรายงานใหม่อ่าน transactions/transaction_lines ตรงๆ · เก็บของแล้วกลับมาผ่าน';
end $$;

-- ============================================================
-- V11 · ขา reverse ต้องไม่ถูกตัดออกจากงบ (D-097 · D-098 เตือนไว้ตรงๆ)
--   ใบกลับรายการคือขาที่ทำให้ยอดสุทธิเป็นศูนย์ · ถ้าเผลอกรอง source='reverse' ออก
--   งบจะกลับไปแสดงยอดที่ควรถูกล้างแล้ว
-- ============================================================
do $$
declare
  v_orig uuid := '00000000-0000-0000-0000-0000000d00a1';
  v_rev  uuid := '00000000-0000-0000-0000-0000000d00a2';
  v_net numeric; n int;
begin
  perform pg_temp.vlogin('v_mgmt');
  perform pg_temp.mk(v_orig, 'THANAKORN', 2400);

  -- ใบกลับรายการ: สลับด้านของต้นฉบับ (fn_assert_reverse_mirrors เทียบ multiset ของบรรทัด)
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, memo,
                                  source, reverses_id, attachments)
  values (v_rev, pg_temp.own('THANAKORN'), 'exp.other', current_date,
          'VD ใบกลับรายการ', 'reverse', v_orig, array['หลักฐาน-VD.pdf']);
  insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit, cf_category)
  values (v_rev, pg_temp.coa('5900'), 0, 2400, 'none'),
         (v_rev, pg_temp.coa('2100'), 2400, 0, 'none');
  perform pg_temp.fire();

  select count(*) into n from sri_os.v_ledger_posted where transaction_id = v_rev;
  if n <> 2 then
    raise exception 'FAIL: V11 ใบกลับรายการอยู่ในงบ % บรรทัด (ต้อง 2) → ถ้ากรองใบกลับรายการออก งบจะกลับไปแสดงยอดที่ควรถูกล้างแล้ว (D-097)', n;
  end if;

  select coalesce(sum(debit) - sum(credit), 0) into v_net
    from sri_os.v_ledger_posted where transaction_id in (v_orig, v_rev);
  if v_net <> 0 then
    raise exception 'FAIL: V11 ต้นฉบับ + ใบกลับรายการ ในงบไม่เป็นศูนย์ (ได้ %)', v_net;
  end if;

  raise notice 'ok V11 · v_ledger_posted มีทั้งต้นฉบับและใบกลับรายการ · ยอดสุทธิของคู่นี้เป็นศูนย์';
end $$;

-- ============================================================
-- สรุป: ของที่ไฟล์นี้ลงไว้ต้องผ่านด่านที่เลื่อนไว้จริง
-- ============================================================
do $$
declare n int;
begin
  set constraints all immediate;
  select count(*) into n from sri_os.transactions where memo like 'VD %';
  if n < 10 then
    raise exception 'FAIL: นับใบที่เทสต์นี้สร้างได้แค่ % ใบ — เทสต์อาจไม่ได้ลงอะไรเลย', n;
  end if;
  raise notice 'ok V · ทั้ง % ใบของไฟล์นี้ผ่านด่านที่เลื่อนไว้ (เคสปฏิเสธไม่ทิ้งใบเสียรูปไว้)', n;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: ใบที่เทสต์นี้สร้างไว้เสียรูป: %', sqlerrm;
end $$;

rollback;
