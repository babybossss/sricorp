-- ============================================================
-- SRI OS · เทสต์ช่องที่เหลือจากรอบ W2/W3 ที่ "ไล่เจอแล้วแต่ยังไม่ได้ปิด"
--   ปิดด้วย supabase/migrations/20261008000004_history_guards.sql
--
--   H0*  · contracts  — ต้องลบไม่ได้เลย + กัน TRUNCATE + มี audit (เดิมไม่มีทั้งสามอย่าง)
--   H0b* · schedules  — เหมือนกัน (แถวตารางงวดคือฐานของเกณฑ์ตั้งค้างรับ-ค้างจ่าย)
--   H5   · **UPDATE ของสัญญา/งวดต้องยังทำได้** (เลื่อนงวด · แก้อัตรา · ปิดสัญญา · waive งวด)
--          ข้อนี้คือจุดที่ "กันแน่นเกิน" จะผิด — ต่างจาก asset_valuations ที่เพิ่มได้เท่านั้น
--   H8   · TRUNCATE ต้องถูกกัน **ทุกตารางใน sri_os** ไม่ใช่เฉพาะตารางที่นึกออก
--          และข้อนี้จะแดงเองเมื่อมีตารางใหม่ที่ยังไม่กัน (ไม่ต้องมาไล่มือ)
--   H9   · audit_log ต้องมี index บน at (คำถาม "สัปดาห์นี้มีอะไรเปลี่ยน")
--   H10  · คอมเมนต์/ข้อความปฏิเสธของ cash_confirmations ต้องไม่ชี้ไปทางที่ไม่มีจริง
--   H11  · เส้นทางที่ถูกต้องทั้งชุดต้องยังเดินได้ (บทเรียนข้อ 7)
--
-- รันในเครื่อง:  bash scripts/test-rls-local.sh
--   ไฟล์ migration ใหม่ต้องอยู่ใน UNDER_TEST ด้วย (ชุด 2026100700000x revoke/sweep
--   ของที่มาก่อน ถ้ารันเรียงชื่อปกติจะทับกัน):
--   UNDER_TEST="... 20261008000003_delete_guards.sql 20261008000004_history_guards.sql" \
--     bash scripts/test-rls-local.sh
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ rollback ปิดท้าย · เจอข้อผิด = raise exception
--
-- สามแบบของการ "ถูกปฏิเสธ" ที่ต้องแยกให้ออก ไม่งั้นเทสต์ผ่านฟรีๆ:
--   RLS ไม่มี policy DELETE → **0 แถว ไม่ใช่ error** → ต้องเช็ค row_count
--   ไม่มี grant               → insufficient_privilege (ไม่ได้แตะ trigger เลย)
--   trigger ปฏิเสธ            → raise_exception + **แถวต้องยังอยู่**
-- ทุกข้อจึงนับแถวก่อน/หลังด้วย ไม่เชื่อแค่ข้อความ error
--
-- สิ่งที่ไฟล์นี้ต้องจับได้ (ไล่จาก "ถ้าถอดการแก้ออกแล้วต้องแดง"):
--   N1  ไม่มี trigger กัน DELETE บน contracts        → H0 H1 H2 แดง
--   N2  กันด้วย RLS/revoke แทน trigger               → H2 แดง (bypassrls + grant ครบ)
--   N3  ไม่มี trigger กัน DELETE บน schedules        → H0b H1b H2 แดง
--   N4  ไม่กัน TRUNCATE สองตารางนี้                  → H0 H0b H3 H8 แดง
--   N5  ไม่เพิ่ม audit trigger                       → H0 H0b H4 แดง
--   N6  **เผลอปิด UPDATE ของสัญญา/งวด**              → H5 แดง
--   N7  กัน TRUNCATE ไม่ครบทุกตารางใน sri_os         → H8 แดง
--   N8  ไม่เพิ่ม index บน audit_log(at)              → H9 แดง
--   N9  trigger กันลบเป็น SECURITY DEFINER / ถาม fn_can / public เรียกได้ → H0 H0b แดง
--   N10 คอมเมนต์ยังชี้ไปทาง "รายการกลับ" ที่ไม่มีจริง → H10 แดง
--   N11 **trigger ติดอยู่แต่ไม่ raise (ปล่อยผ่าน)**   → H1 H1b H3 H8 แดง (นับแถวก่อน-หลัง)
--   N12 เผลอปิดเส้นทางถูกต้อง (post/void · ปิด-เปิดงวด · ยืนยันเงิน · เพิ่มทรัพย์/ร่าง)
--                                                    → H11 แดง
--   N13 กันแต่ contracts แล้วให้ cascade ลบงวดเงียบๆ  → H6 แดง
--
-- เคส "ไม่ส่งข้อมูล" (บทเรียนข้อ 3) อยู่ที่
--   H1/H1b (DELETE ไม่ใส่ WHERE = ลบทั้งตารางรวดเดียว)
--   H1c (ลบสัญญาที่ฟิลด์เงินยังว่าง → ข้อความ error ต้องไม่ล้มเพราะ null)
--   H7 (DELETE ที่ไม่ตรงแถวไหนเลย → ต้องไม่ error และต้องไม่แตะอะไร)
--   H8 (TRUNCATE ไม่ใส่เงื่อนไขอะไรได้อยู่แล้วโดยธรรมชาติ · ไล่ทุกตาราง)
-- ============================================================

begin;

-- ---------- fixtures: ผู้ใช้ ----------
create temporary table t_huid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_huid(label) values ('h_super'), ('h_mgmt'), ('h_mgr'), ('h_staff');
insert into auth.users(id) select id from t_huid;

insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, u.label || '@hist.local', u.label, x.role, true
  from t_huid u
  join (values ('h_super', 'super_admin'), ('h_mgmt', 'management'),
               ('h_mgr', 'manager'), ('h_staff', 'staff')) as x(label, role)
    on x.label = u.label;

create or replace function pg_temp.huid(p_label text) returns uuid
language sql stable as $fn$ select id from t_huid where label = p_label $fn$;

create or replace function pg_temp.hlogin(p_label text) returns void
language sql as $fn$
  select set_config('test.uid', coalesce((select id::text from t_huid where label = p_label), ''), true);
$fn$;

-- RLS ปฏิเสธ UPDATE/DELETE แบบ **เงียบ** (0 แถว ไม่ใช่ error) จึงต้องมีตัวนับแถวด้วย
create or replace function pg_temp.hrows(p_label text, p_sql text, p_expect int) returns void
language plpgsql as $fn$
declare n int;
begin
  execute p_sql;
  get diagnostics n = row_count;
  if n <> p_expect then
    raise exception 'FAIL: % — คาดว่ากระทบ % แถว แต่ได้ % แถว · sql: %', p_label, p_expect, n, p_sql;
  end if;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: % — คำสั่งล้มด้วย error (%) ทั้งที่คาดว่าจะกระทบ % แถว · sql: %',
    p_label, sqlerrm, p_expect, p_sql;
end $fn$;

create or replace function pg_temp.hpass(p_label text, p_sql text) returns void
language plpgsql as $fn$
begin
  execute p_sql;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: % — คำสั่งควรสำเร็จแต่ล้ม (%) · sql: %', p_label, sqlerrm, p_sql;
end $fn$;

do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.t_huid to authenticated', s);
end $$;

-- Manager/Staff ต้องเห็น Entity นี้ ไม่งั้นเทสต์ผ่านเพราะมองไม่เห็นอะไรเลย
insert into sri_os.user_owner_access(user_id, owner_id)
select u.id, o.id from t_huid u cross join sri_os.owners o
 where u.label in ('h_mgr', 'h_staff') and o.code in ('SRI_CORP', 'SUTEE')
on conflict do nothing;

-- ---------- fixtures: ทรัพย์ · คู่สัญญา · บัญชีธนาคาร ----------
insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, manager_user_id)
select '00000000-0000-0000-0000-00000000ca01', 'HG-A1', 'ทรัพย์เทสต์กันประวัติ',
       (select class_id from sri_os.asset_categories order by code limit 1),
       (select id       from sri_os.asset_categories order by code limit 1),
       o.id, pg_temp.huid('h_mgr')
  from sri_os.owners o where o.code = 'SRI_CORP';

insert into sri_os.contacts(id, first_name, last_name, types)
values ('00000000-0000-0000-0000-00000000ca02', 'คู่สัญญา', 'เทสต์', array['borrower']);

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
select '00000000-0000-0000-0000-00000000ca03', o.id, 'KBANK', 'บัญชีเทสต์กันประวัติ', 'บัญชีเทสต์กันประวัติ'
  from sri_os.owners o where o.code = 'SRI_CORP';

-- ---------- fixtures: สัญญาสองฉบับ ----------
-- ฉบับแรก **ข้อมูลครบ 100%** เพื่อให้สร้างตารางงวดได้ (trg_schedule_complete)
insert into sri_os.contracts(id, code, owner_id, asset_id, type, counterparty_contact_id,
                             principal, rate, rate_period, interest_method,
                             start_date, end_date, installments, file_urls, status)
select '00000000-0000-0000-0000-00000000cc01', 'HG-C1', o.id,
       '00000000-0000-0000-0000-00000000ca01', 'loan_receivable',
       '00000000-0000-0000-0000-00000000ca02',
       1000000, 1.25, 'month', 'simple',
       current_date - 60, current_date + 300, 12, array['สัญญา-HG-C1.pdf'], 'active'
  from sri_os.owners o where o.code = 'SRI_CORP';

-- ฉบับที่สอง **ฟิลด์เงินว่างทั้งหมด** = เคส "ไม่ส่งข้อมูล" ของตารางนี้
--   (คีย์ผิดแล้วอยากล้าง ซึ่งเป็นกรณีที่ต้องรายงานให้ตัดสิน ไม่ใช่เปิดช่องเอง)
--   ข้อความปฏิเสธต้องไม่ล้มเพราะ null และต้องยังลบไม่ได้
insert into sri_os.contracts(id, code, owner_id, asset_id, type, status)
select '00000000-0000-0000-0000-00000000cc02', 'HG-C2', o.id,
       '00000000-0000-0000-0000-00000000ca01', 'lease', 'draft'
  from sri_os.owners o where o.code = 'SRI_CORP';

-- ---------- fixtures: ตารางงวดสองงวด ----------
insert into sri_os.schedules(id, contract_id, period, due_date,
                             expected_amount, principal_amount, interest_amount, status)
values
  ('00000000-0000-0000-0000-00000000cd01', '00000000-0000-0000-0000-00000000cc01',
   1, current_date + 5,  95000, 82500, 12500, 'upcoming'),
  ('00000000-0000-0000-0000-00000000cd02', '00000000-0000-0000-0000-00000000cc01',
   2, current_date + 35, 95000, 83500, 11500, 'upcoming');

-- กันเทสต์เปล่า: fixture ไม่ครบ = "ลบได้ 0 แถว" แล้วผ่านฟรีๆ ทุกข้อ
do $$
declare n int;
begin
  select count(*) into n from sri_os.contracts
   where id in ('00000000-0000-0000-0000-00000000cc01', '00000000-0000-0000-0000-00000000cc02');
  if n <> 2 then
    raise exception 'FAIL: fixture สัญญาต้องมี 2 ฉบับ (ได้ %) — เทสต์ H* จะไม่ได้ตรวจอะไร', n;
  end if;
  select count(*) into n from sri_os.schedules
   where contract_id = '00000000-0000-0000-0000-00000000cc01';
  if n <> 2 then
    raise exception 'FAIL: fixture ตารางงวดต้องมี 2 งวด (ได้ %)', n;
  end if;
  -- สัญญาฉบับแรกต้องครบ 100% จริง ไม่งั้น H5 (แก้/เพิ่มงวด) จะล้มด้วยเหตุผลอื่น
  if sri_os.fn_contract_completeness('00000000-0000-0000-0000-00000000cc01') <> 100 then
    raise exception 'FAIL: fixture สัญญา HG-C1 ไม่ครบ 100%% (ได้ %%%)',
      sri_os.fn_contract_completeness('00000000-0000-0000-0000-00000000cc01');
  end if;
  -- ฉบับที่สองต้อง **ไม่ครบ** โดยตั้งใจ (เคสข้อมูลขาด)
  if sri_os.fn_contract_completeness('00000000-0000-0000-0000-00000000cc02') = 100 then
    raise exception 'FAIL: fixture สัญญา HG-C2 ควรเป็นเคสข้อมูลขาด แต่ครบ 100%%';
  end if;
end $$;

-- ============================================================
-- H0 · โครงสร้าง contracts: ไล่จาก pg_trigger จริง ไม่ใช่ไล่ไฟล์
-- ============================================================
do $$
declare n int; v text;
begin
  select count(*) into n
    from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
   where tg.tgrelid = 'sri_os.contracts'::regclass
     and not tg.tgisinternal
     and tg.tgname = 'trg_forbid_delete_contract'
     and (tg.tgtype & 8) <> 0 and (tg.tgtype & 2) <> 0 and (tg.tgtype & 1) <> 0
     and p.prosrc ~* 'raise exception';
  if n <> 1 then
    raise exception 'FAIL: ไม่มี before delete for each row trigger ชื่อ trg_forbid_delete_contract บน contracts → เจ้าของฐานข้อมูลลบสัญญา (เงินต้น/ดอกเบี้ย/ฐานของการตั้งค้างรับ) ได้เงียบๆ';
  end if;

  if not exists (select 1 from pg_trigger
                  where tgrelid = 'sri_os.contracts'::regclass and (tgtype & 32) <> 0) then
    raise exception 'FAIL: contracts ไม่มี trigger กัน TRUNCATE → ล้างสัญญาทั้งตารางได้ในคำสั่งเดียวโดยไม่ยิง row trigger';
  end if;

  select count(*) into n
    from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
   where tg.tgrelid = 'sri_os.contracts'::regclass and not tg.tgisinternal
     and p.proname = 'fn_audit'
     and (tg.tgtype & 4) <> 0 and (tg.tgtype & 8) <> 0 and (tg.tgtype & 16) <> 0;
  if n <> 1 then
    raise exception 'FAIL: contracts ไม่มี audit trigger ที่ครอบ insert+update+delete (เจอ %)', n;
  end if;

  -- ฟังก์ชันกันลบต้องไม่ถามสิทธิ์ ไม่เป็น definer และเรียกจากข้างนอกไม่ได้
  select string_agg(p.proname, ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_forbid_delete_contract'
     and (p.prosecdef
       or p.prosrc ~* 'fn_can'
       or has_function_privilege('public', p.oid, 'execute'));
  if v is not null then
    raise exception 'FAIL: fn_forbid_delete_contract หลวมเกินไป (SECURITY DEFINER / ถามสิทธิ์ / PUBLIC execute)';
  end if;
  raise notice 'ok H0 · contracts มี trigger กัน DELETE + TRUNCATE + audit ครบ · ACL ปิดถูก';
end $$;

-- ============================================================
-- H0b · โครงสร้าง schedules — เหมือนกันทุกข้อ (กฎเดียวกันห้ามเขียนสองที่)
-- ============================================================
do $$
declare n int; v text;
begin
  select count(*) into n
    from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
   where tg.tgrelid = 'sri_os.schedules'::regclass
     and not tg.tgisinternal
     and tg.tgname = 'trg_forbid_delete_schedule'
     and (tg.tgtype & 8) <> 0 and (tg.tgtype & 2) <> 0 and (tg.tgtype & 1) <> 0
     and p.prosrc ~* 'raise exception';
  if n <> 1 then
    raise exception 'FAIL: ไม่มี before delete for each row trigger ชื่อ trg_forbid_delete_schedule บน schedules → ลบแถวตารางงวดได้ทุกแถว = ยอดค้างและงวดที่ควรเกิดหายไปไร้ร่องรอย';
  end if;

  if not exists (select 1 from pg_trigger
                  where tgrelid = 'sri_os.schedules'::regclass and (tgtype & 32) <> 0) then
    raise exception 'FAIL: schedules ไม่มี trigger กัน TRUNCATE';
  end if;

  select count(*) into n
    from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
   where tg.tgrelid = 'sri_os.schedules'::regclass and not tg.tgisinternal
     and p.proname = 'fn_audit'
     and (tg.tgtype & 4) <> 0 and (tg.tgtype & 8) <> 0 and (tg.tgtype & 16) <> 0;
  if n <> 1 then
    raise exception 'FAIL: schedules ไม่มี audit trigger ที่ครอบ insert+update+delete (เจอ %)', n;
  end if;

  select string_agg(p.proname, ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_forbid_delete_schedule'
     and (p.prosecdef
       or p.prosrc ~* 'fn_can'
       or has_function_privilege('public', p.oid, 'execute'));
  if v is not null then
    raise exception 'FAIL: fn_forbid_delete_schedule หลวมเกินไป (SECURITY DEFINER / ถามสิทธิ์ / PUBLIC execute)';
  end if;

  -- trigger function ทั้งสองตัวต้องเรียกตรงจาก authenticated ไม่ได้
  select string_agg(p.proname, ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.proname in ('fn_forbid_delete_contract', 'fn_forbid_delete_schedule')
     and has_function_privilege('authenticated', p.oid, 'execute');
  if v is not null then
    raise exception 'FAIL: authenticated เรียก trigger function ได้: %', v;
  end if;
  raise notice 'ok H0b · schedules มี trigger กัน DELETE + TRUNCATE + audit ครบ · ACL ปิดถูก';
end $$;

-- ============================================================
-- H1 · superuser ของคลัสเตอร์ (เจ้าของตาราง · ข้าม RLS) ลบสัญญาไม่ได้
--      + เคสไม่ส่งเงื่อนไข (ลบทั้งตาราง) + เคสฟิลด์เงินว่าง (H1c)
-- ============================================================
reset role;
do $$
declare n_before int; n_after int; v_msg text := '';
begin
  select count(*) into n_before from sri_os.contracts;

  begin
    delete from sri_os.contracts where id = '00000000-0000-0000-0000-00000000cc01';
    raise exception 'FAIL: superuser ลบสัญญาได้ → เงินต้น/อัตรา/ตารางงวดที่เกณฑ์ตั้งค้างรับ-ค้างจ่ายใช้ หายไปโดยไม่มีร่องรอย';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
    v_msg := sqlerrm;
  end;

  -- ไม่ใส่ WHERE = ล้างทั้งตารางรวดเดียว ต้องล้มเหมือนกัน
  begin
    delete from sri_os.contracts;
    raise exception 'FAIL: superuser ลบสัญญาทั้งตารางได้';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  -- H1c · สัญญาที่ฟิลด์เงินยังว่าง (คีย์ผิด/ยังไม่กรอก) ก็ลบไม่ได้
  --        และข้อความ error ต้องบอกสภาพนั้นแทนที่จะล้มเพราะ null
  begin
    delete from sri_os.contracts where id = '00000000-0000-0000-0000-00000000cc02';
    raise exception 'FAIL: superuser ลบสัญญาที่ยังไม่กรอกข้อมูลเงินได้ → ช่องเดิมเปิดอยู่แค่เลือกแถวให้ถูก';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if sqlerrm not like '%ไม่ระบุ%' then
      raise exception 'FAIL: ข้อความปฏิเสธของสัญญาที่ฟิลด์เงินว่างไม่บอกสภาพนั้น (%) → error ที่อ่านไม่รู้เรื่องทำให้คนไปปิด trigger', left(sqlerrm, 160);
    end if;
  end;

  select count(*) into n_after from sri_os.contracts;
  if n_after <> n_before or n_before = 0 then
    raise exception 'FAIL: จำนวนสัญญาเปลี่ยนจาก % เป็น % (หรือ fixture ว่าง) → error ขึ้นแต่ของหายจริง',
      n_before, n_after;
  end if;
  raise notice 'ok H1 · superuser ลบสัญญาไม่ได้ ทั้งระบุแถว ไม่ใส่เงื่อนไข และฉบับที่ข้อมูลยังขาด · แถวครบ % (%)',
    n_after, left(v_msg, 70);
end $$;

-- ============================================================
-- H1b · superuser ลบแถวตารางงวดไม่ได้ (รวมลบทั้งตาราง)
--       ข้อความต้องบอกทางออกที่มีจริง = waive งวด ไม่ใช่ลบแถว
-- ============================================================
do $$
declare n_before int; n_after int; v_msg text := '';
begin
  select count(*) into n_before from sri_os.schedules;

  begin
    delete from sri_os.schedules where id = '00000000-0000-0000-0000-00000000cd01';
    raise exception 'FAIL: superuser ลบแถวตารางงวดได้ → งวดที่ควรเกิดหายไป ยอดค้างรับ-ค้างจ่ายเพี้ยนโดยไม่มีร่องรอย';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
    v_msg := sqlerrm;
  end;

  begin
    delete from sri_os.schedules;
    raise exception 'FAIL: superuser ลบตารางงวดทั้งตารางได้';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  if v_msg not like '%waived%' then
    raise exception 'FAIL: ข้อความปฏิเสธของตารางงวดไม่บอกทางออกที่มีจริง (status = waived) · ได้: %',
      left(v_msg, 160);
  end if;

  select count(*) into n_after from sri_os.schedules;
  if n_after <> n_before or n_before = 0 then
    raise exception 'FAIL: จำนวนงวดเปลี่ยนจาก % เป็น % (หรือ fixture ว่าง)', n_before, n_after;
  end if;
  raise notice 'ok H1b · superuser ลบแถวตารางงวดไม่ได้ · ข้อความชี้ทาง waive ที่มีจริง · แถวครบ %', n_after;
end $$;

-- ============================================================
-- H2 · role ที่มี grant ครบ + BYPASSRLS (แรงเท่า service_role ของจริง)
--      ถ้ากันด้วย RLS/revoke เพียงอย่างเดียวจะหลุดที่ข้อนี้
--      (harness ในเครื่องสร้าง service_role แบบไม่มี grant → ทดสอบตรงๆ จะผ่านฟรีๆ)
-- ============================================================
do $$
declare r_name text := 'histguard_svc_' || pg_backend_pid();
        n_c_before int; n_c_after int; n_s_before int; n_s_after int;
begin
  execute format('create role %I bypassrls', r_name);
  execute format('grant usage on schema sri_os to %I', r_name);
  execute format('grant select, insert, update, delete on sri_os.contracts to %I', r_name);
  execute format('grant select, insert, update, delete on sri_os.schedules to %I', r_name);
  select count(*) into n_c_before from sri_os.contracts;
  select count(*) into n_s_before from sri_os.schedules;

  execute format('set local role %I', r_name);
  begin
    delete from sri_os.contracts;
    raise exception 'FAIL: role ที่ bypassrls + grant ครบ ลบสัญญาได้ → การกันด้วย RLS ไม่ถึงชั้น service_role';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  begin
    delete from sri_os.schedules;
    raise exception 'FAIL: role ที่ bypassrls + grant ครบ ลบตารางงวดได้';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  reset role;

  select count(*) into n_c_after from sri_os.contracts;
  select count(*) into n_s_after from sri_os.schedules;
  if n_c_after <> n_c_before or n_s_after <> n_s_before then
    raise exception 'FAIL: แถวหายจริงทั้งที่ error ขึ้น (สัญญา % → % · งวด % → %)',
      n_c_before, n_c_after, n_s_before, n_s_after;
  end if;
  raise notice 'ok H2 · role แบบ service_role (bypassrls + grant ครบ) ลบสัญญา/งวดไม่ได้ · กันที่ trigger จริง';
end $$;

-- ============================================================
-- H3 · TRUNCATE สองตารางนี้ต้องล้ม (row trigger ไม่ยิงตอน TRUNCATE)
--      ใช้ cascade เพราะ plain truncate จะล้มด้วย foreign_key ก่อนถึง trigger
--      ซึ่งอ่านไม่ออกว่ากันได้จริงหรือแค่ FK บังเอิญช่วย
-- ============================================================
do $$
declare r text; n_c int; n_s int; hit boolean;
begin
  select count(*) into n_c from sri_os.contracts;
  select count(*) into n_s from sri_os.schedules;
  foreach r in array array['contracts', 'schedules'] loop
    hit := false;
    begin
      execute format('truncate table sri_os.%I cascade', r);
    exception when raise_exception then
      if sqlerrm like 'FAIL:%' then raise; end if;
      if sqlerrm not like '%TRUNCATE%' then
        raise exception 'FAIL: TRUNCATE sri_os.% ล้มด้วย error อื่นที่ไม่ใช่ด่าน TRUNCATE (%)', r, left(sqlerrm, 120);
      end if;
      hit := true;
    end;
    if not hit then
      raise exception 'FAIL: TRUNCATE sri_os.% สำเร็จ = ล้างประวัติสัญญา/งวดได้โดยไม่ยิง trigger ไม่เหลือ audit', r;
    end if;
  end loop;
  if (select count(*) from sri_os.contracts) <> n_c
     or (select count(*) from sri_os.schedules) <> n_s then
    raise exception 'FAIL: TRUNCATE ลงไปแล้วบางส่วนทั้งที่ error ขึ้น';
  end if;
  raise notice 'ok H3 · TRUNCATE contracts/schedules ล้มทั้งคู่ · แถวครบ (% สัญญา · % งวด)', n_c, n_s;
end $$;

-- ============================================================
-- H4 · audit ของ contracts/schedules **ทำงานจริง** ไม่ใช่แค่มี trigger ติดอยู่
--      (บทเรียน: "trigger อยู่แต่ปล่อยผ่าน" ต้องจับได้)
-- ============================================================
do $$
declare n int;
begin
  -- insert ของ fixture ต้องเหลือร่องรอยไว้แล้ว
  if not exists (select 1 from sri_os.audit_log
                  where table_name = 'contracts' and action = 'insert'
                    and row_id = '00000000-0000-0000-0000-00000000cc01'
                    and after ->> 'code' = 'HG-C1') then
    raise exception 'FAIL: สร้างสัญญาแล้วไม่มีร่องรอยใน audit_log';
  end if;
  if not exists (select 1 from sri_os.audit_log
                  where table_name = 'schedules' and action = 'insert'
                    and row_id = '00000000-0000-0000-0000-00000000cd01'
                    and (after ->> 'expected_amount')::numeric = 95000) then
    raise exception 'FAIL: สร้างงวดแล้วไม่มีร่องรอยใน audit_log';
  end if;

  -- แก้แล้วต้องเก็บ before-after ทั้งคู่ (ไม่ใช่เก็บแต่ after)
  update sri_os.contracts set rate = 1.50
   where id = '00000000-0000-0000-0000-00000000cc01';
  select count(*) into n from sri_os.audit_log
   where table_name = 'contracts' and action = 'update'
     and row_id = '00000000-0000-0000-0000-00000000cc01'
     and (before ->> 'rate')::numeric = 1.25
     and (after  ->> 'rate')::numeric = 1.50;
  if n <> 1 then
    raise exception 'FAIL: แก้อัตราดอกเบี้ยแล้ว audit_log ไม่เก็บ before-after (เจอ % แถว)', n;
  end if;

  update sri_os.schedules set due_date = due_date + 7
   where id = '00000000-0000-0000-0000-00000000cd01';
  if not exists (select 1 from sri_os.audit_log
                  where table_name = 'schedules' and action = 'update'
                    and row_id = '00000000-0000-0000-0000-00000000cd01'
                    and (before ->> 'due_date') <> (after ->> 'due_date')) then
    raise exception 'FAIL: เลื่อนงวดแล้ว audit_log ไม่เก็บ before-after';
  end if;
  raise notice 'ok H4 · audit ของ contracts/schedules ทำงานจริงทั้ง insert และ update (เก็บ before-after)';
end $$;

-- ============================================================
-- H5 · **เส้นทางบริหารสัญญาต้องยังทำได้** (บทเรียนข้อ 7)
--      สัญญา/งวดเป็นของที่แก้ไขได้ตามปกติ ต่างจากการตีราคาที่เพิ่มได้เท่านั้น
--      ถ้าใครเผลอปิด UPDATE ข้อนี้แดงทันที · ทดสอบในฐานะ authenticated จริง
--      (ผ่านชั้น GRANT + RLS ไม่ใช่ superuser) เพราะนั่นคือเส้นทางของแอป
-- ============================================================
set local role authenticated;
do $$
begin
  perform pg_temp.hlogin('h_mgmt');   -- asset.manage + portfolio.view_all

  -- แก้เงื่อนไขสัญญา: อัตรา · เงินต้น · วันเริ่ม · วิธีคิดดอกเบี้ย
  perform pg_temp.hrows('แก้อัตราดอกเบี้ยของสัญญา',
    'update sri_os.contracts set rate = 1.75 where id = ''00000000-0000-0000-0000-00000000cc01''', 1);
  perform pg_temp.hrows('แก้เงินต้นของสัญญา',
    'update sri_os.contracts set principal = 1200000 where id = ''00000000-0000-0000-0000-00000000cc01''', 1);
  perform pg_temp.hrows('แก้วิธีคิดดอกเบี้ย',
    'update sri_os.contracts set interest_method = ''effective'' where id = ''00000000-0000-0000-0000-00000000cc01''', 1);

  -- เลื่อนงวด · แก้ยอดงวด (เงินต้น+ดอกเบี้ยต้องยังเท่ายอดรวม)
  perform pg_temp.hrows('เลื่อนวันครบกำหนดของงวด',
    'update sri_os.schedules set due_date = due_date + 14 where id = ''00000000-0000-0000-0000-00000000cd02''', 1);
  perform pg_temp.hrows('แก้ยอดงวด (แยกเงินต้น/ดอกเบี้ย)',
    'update sri_os.schedules set expected_amount = 96000, principal_amount = 84000, interest_amount = 12000 where id = ''00000000-0000-0000-0000-00000000cd02''', 1);

  -- ทางออกแทนการลบงวด: waive งวดที่ไม่เกิดจริง (มีอยู่ในตารางสถานะแล้ว)
  perform pg_temp.hrows('waive งวดที่ไม่เกิดจริง',
    'update sri_os.schedules set status = ''waived'' where id = ''00000000-0000-0000-0000-00000000cd02''', 1);

  -- ปิดสัญญา = เปลี่ยนสถานะ ไม่ใช่ลบแถว
  perform pg_temp.hrows('ปิดสัญญาด้วย status = closed',
    'update sri_os.contracts set status = ''closed'' where id = ''00000000-0000-0000-0000-00000000cc02''', 1);

  -- เพิ่มงวดใหม่ (ขยายสัญญา) และเพิ่มสัญญาใหม่ ต้องยังได้
  perform pg_temp.hpass('เพิ่มงวดใหม่เข้าสัญญาเดิม',
    'insert into sri_os.schedules(contract_id, period, due_date, expected_amount, principal_amount, interest_amount)
       values (''00000000-0000-0000-0000-00000000cc01'', 3, current_date + 65, 95000, 84500, 10500)');
  perform pg_temp.hpass('สร้างสัญญาใหม่',
    'insert into sri_os.contracts(code, owner_id, asset_id, type)
       select ''HG-C3'', o.id, ''00000000-0000-0000-0000-00000000ca01'', ''lease''
         from sri_os.owners o where o.code = ''SRI_CORP''');
  raise notice 'ok H5 · แก้สัญญา (อัตรา/เงินต้น/วิธีคิด) · เลื่อน-แก้-waive งวด · ปิดสัญญา · เพิ่มงวด/สัญญาใหม่ ยังทำได้ครบในฐานะ authenticated';
end $$;
reset role;

-- ============================================================
-- H6 · กันแต่ contracts ไม่พอ — cascade ต้องชนด่านของ schedules ด้วย
--      schedules.contract_id เป็น `on delete cascade` → ถ้าวันหนึ่งมี migration
--      ถอดด่านของ contracts ออกชั่วคราวตามขั้นตอนที่หัวไฟล์ระบุ แถวงวดต้อง
--      **ไม่หายตามไปเงียบๆ** · ทดสอบโดยถอด trigger ใน savepoint แล้วย้อนคืน
-- ============================================================
savepoint sp_cascade;
do $$
declare n_s_before int; n_s_after int;
begin
  select count(*) into n_s_before from sri_os.schedules;
  drop trigger trg_forbid_delete_contract on sri_os.contracts;
  begin
    delete from sri_os.contracts where id = '00000000-0000-0000-0000-00000000cc01';
    raise exception 'FAIL: ถอดด่านของ contracts ออกแล้วลบสัญญาได้ และ cascade ลบงวดตามไป → ด่านของ schedules ไม่ได้กันขา cascade';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  select count(*) into n_s_after from sri_os.schedules;
  if n_s_after <> n_s_before then
    raise exception 'FAIL: แถวงวดหายจาก cascade (% → %)', n_s_before, n_s_after;
  end if;
  raise notice 'ok H6 · ด่านของ schedules กันขา cascade ได้เอง (กันสองชั้น ไม่พึ่ง contracts ตัวเดียว)';
end $$;
rollback to savepoint sp_cascade;

-- ============================================================
-- H7 · DELETE ที่ไม่ตรงแถวไหนเลยต้องไม่ error และต้องไม่แตะอะไร
--      (กันอีกทาง: ด่านที่ปฏิเสธทุกคำสั่งมั่วๆ จะทำให้เส้นทางปกติเพี้ยน)
-- ============================================================
do $$
declare n int;
begin
  delete from sri_os.contracts where id = '00000000-0000-0000-0000-0000000000ff';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL: ลบสัญญาที่ไม่มีอยู่ได้ % แถว', n; end if;

  delete from sri_os.schedules where period = 9999;
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL: ลบงวดที่ไม่มีอยู่ได้ % แถว', n; end if;
  raise notice 'ok H7 · DELETE ที่ไม่ตรงแถวไหน ไม่ error และไม่แตะอะไร (trigger ไม่ยิงเพราะไม่มีแถว)';
end $$;

-- ============================================================
-- H8 · TRUNCATE ต้องถูกกัน **ทุกตารางใน sri_os**
--      ไล่จาก pg_class จริง → ข้อนี้แดงเองเมื่อมีตารางใหม่ที่ยังไม่กัน
--      (ไม่ต้องมาเติมชื่อมือเหมือน Z1) · ตรวจสองทิศ: โครงสร้าง + ลองทำจริง
-- ============================================================
do $$
declare v text; n int; r record; hit boolean; n_audit_before bigint;
begin
  -- (ก) โครงสร้าง: ทุกตารางต้องมี statement trigger ของ TRUNCATE
  select string_agg(c.relname, ', ' order by c.relname), count(*) into v, n
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os' and c.relkind = 'r'
     and not exists (select 1 from pg_trigger tg
                      where tg.tgrelid = c.oid and not tg.tgisinternal
                        and (tg.tgtype & 32) <> 0);
  if n > 0 then
    raise exception 'FAIL: % ตารางใน sri_os ที่ TRUNCATE ได้: % · TRUNCATE ไม่ยิง row trigger → ล้าง audit ที่ตารางนั้นพึ่งพาได้ในคำสั่งเดียว', n, v;
  end if;

  -- (ข) ตารางแบบ partitioned รองรับ trigger ของ TRUNCATE ไม่ได้ → ต้องรู้ตัวทันที
  select string_agg(c.relname, ', ') into v
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os' and c.relkind = 'p';
  if v is not null then
    raise exception 'FAIL: มีตาราง partitioned ใน sri_os (%) · TRUNCATE trigger ติดกับตารางแม่ไม่ได้ → ต้องตัดสินวิธีกันก่อนใช้งาน', v;
  end if;

  -- (ค) กันเทสต์เปล่า
  select count(*) into n
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os' and c.relkind = 'r';
  if n < 25 then
    raise exception 'FAIL: นับตารางใน sri_os ได้แค่ % ตาราง — ข้อนี้อาจไม่ได้ตรวจอะไรเลย', n;
  end if;

  -- (ง) พฤติกรรม: ลอง TRUNCATE จริงทุกตารางในฐานะ superuser ของคลัสเตอร์
  --     ทุกตารางต้องล้มด้วยด่าน TRUNCATE (ไม่ใช่ล้มด้วย FK หรือสิทธิ์)
  select count(*) into n_audit_before from sri_os.audit_log;
  for r in
    select c.relname from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
     where ns.nspname = 'sri_os' and c.relkind = 'r' order by c.relname
  loop
    hit := false;
    begin
      execute format('truncate table sri_os.%I cascade', r.relname);
    exception when raise_exception then
      if sqlerrm like 'FAIL:%' then raise; end if;
      if sqlerrm not like '%TRUNCATE%' then
        raise exception 'FAIL: TRUNCATE sri_os.% ล้มด้วยเหตุอื่น (%) → ไม่ได้พิสูจน์ว่ามีด่าน', r.relname, left(sqlerrm, 120);
      end if;
      hit := true;
    end;
    if not hit then
      raise exception 'FAIL: TRUNCATE sri_os.% สำเร็จ', r.relname;
    end if;
  end loop;
  if (select count(*) from sri_os.audit_log) <> n_audit_before then
    raise exception 'FAIL: จำนวนแถว audit_log เปลี่ยนหลังลอง TRUNCATE ทุกตาราง = ลงไปบางส่วนจริง';
  end if;
  raise notice 'ok H8 · ทั้ง % ตารางใน sri_os กัน TRUNCATE ครบ ทั้งที่โครงสร้างและลองทำจริง', n;
end $$;

-- ============================================================
-- H9 · audit_log ต้องค้นด้วยเวลาได้ (คำถาม "สัปดาห์นี้มีอะไรเปลี่ยน")
--      ไม่มี index บน at = seq scan ทั้งตารางที่โตเรื่อยๆ และลบไม่ได้ด้วย
--      ตรวจจาก pg_index จริง (ไม่ใช่ชื่อ index) ว่า **คอลัมน์นำ** คือ at
-- ============================================================
do $$
declare v text;
begin
  if not exists (
    select 1 from pg_index i
     where i.indrelid = 'sri_os.audit_log'::regclass
       and (select attname from pg_attribute
             where attrelid = i.indrelid and attnum = i.indkey[0]) = 'at'
  ) then
    select string_agg(indexdef, ' | ') into v from pg_indexes
     where schemaname = 'sri_os' and tablename = 'audit_log';
    raise exception 'FAIL: audit_log ไม่มี index ที่นำด้วยคอลัมน์ at → "สัปดาห์นี้มีอะไรเปลี่ยน" ต้อง seq scan · index ที่มี: %', v;
  end if;

  -- index ที่มีอยู่เดิมต้องไม่หาย (table_name, row_id) = "แถวนี้เคยถูกแก้อะไรบ้าง"
  if not exists (
    select 1 from pg_index i
     where i.indrelid = 'sri_os.audit_log'::regclass
       and (select attname from pg_attribute
             where attrelid = i.indrelid and attnum = i.indkey[0]) = 'table_name'
  ) then
    raise exception 'FAIL: index ที่นำด้วย table_name หายไปจาก audit_log';
  end if;

  -- index ต้องไม่ unique (ไม่งั้นแถว audit ที่ซ้ำเวลาจะถูกปฏิเสธ = เขียน audit ไม่ได้)
  select string_agg(c.relname, ', ') into v
    from pg_index i join pg_class c on c.oid = i.indexrelid
   where i.indrelid = 'sri_os.audit_log'::regclass and i.indisunique and not i.indisprimary;
  if v is not null then
    raise exception 'FAIL: audit_log มี unique index ที่ไม่ใช่ primary key (%) → การเขียน audit อาจถูกปฏิเสธ', v;
  end if;
  raise notice 'ok H9 · audit_log มี index ตามเวลา (at) และของเดิม (table_name) ยังอยู่ · ไม่มี unique index แปลกปลอม';
end $$;

-- ============================================================
-- H10 · คอมเมนต์ต้องตรงความจริง (ข้อ 4 ของรอบนี้)
--       20261008000003 เขียนว่ายกเลิกการยืนยันให้ "บันทึกรายการกลับ" แต่ตรวจแล้ว
--       **ทำไม่ได้**: ไม่มีคอลัมน์ status/void และ src/** ไม่อ้าง cash_confirmations
--       ของที่มีจริงคือ UPDATE ที่แถวเดิมด้วยสิทธิ์ cash.confirm ซึ่ง audit จับได้
--       ข้อนี้บังคับว่า: ถ้าข้อความไหนพูดถึง "รายการกลับ" ต้องบอกด้วยว่า **ยังไม่มี**
--       และถ้าวันหนึ่งมีคอลัมน์สถานะจริง ข้อนี้จะแดงให้กลับมาแก้หมายเหตุ
-- ============================================================
do $$
declare v text; v_msg text := '';
begin
  -- (ก) ข้ออ้างต้องยังเป็นความจริง: ตารางนี้ยังไม่มีคอลัมน์สถานะ/void
  select string_agg(attname, ', ') into v
    from pg_attribute
   where attrelid = 'sri_os.cash_confirmations'::regclass and attnum > 0 and not attisdropped
     and attname in ('status', 'voided_at', 'voided_by', 'is_void', 'reverses_id');
  if v is not null then
    raise exception 'FAIL: cash_confirmations มีคอลัมน์สถานะ/void แล้ว (%) → หมายเหตุที่บอกว่า "เส้นทางรายการกลับยังไม่มี" ล้าสมัย ให้กลับมาแก้', v;
  end if;

  -- (ข) คอมเมนต์ของตาราง/trigger/ฟังก์ชัน: ถ้าพูดถึงรายการกลับ ต้องบอกว่ายังไม่มี
  for v in
    select x.t from (values
        (obj_description('sri_os.cash_confirmations'::regclass, 'pg_class')),
        (obj_description('sri_os.fn_forbid_delete_confirmation()'::regprocedure, 'pg_proc')),
        ((select obj_description(tg.oid, 'pg_trigger') from pg_trigger tg
           where tg.tgrelid = 'sri_os.cash_confirmations'::regclass
             and tg.tgname = 'trg_forbid_delete_confirmation'))
      ) as x(t)
     where x.t is not null
  loop
    if v ~ 'รายการกลับ' and v !~ 'ยังไม่มี' then
      raise exception 'FAIL: คอมเมนต์ยังชี้ไปทาง "รายการกลับ" โดยไม่บอกว่ายังไม่มีเส้นทางนั้น → คนในอนาคตจะเชื่อว่ามีแล้วไม่เอะใจ · ข้อความ: %', left(v, 200);
    end if;
  end loop;

  -- (ค) ต้องมีหมายเหตุที่ **หาเจอ** และบอกทางออกที่มีจริง (UPDATE + audit + cash.confirm)
  v := coalesce(obj_description('sri_os.cash_confirmations'::regclass, 'pg_class'), '')
    || ' ' || coalesce(obj_description('sri_os.fn_forbid_delete_confirmation()'::regprocedure, 'pg_proc'), '');
  if v !~ 'cash.confirm' or v !~ 'UPDATE' or v !~ 'ยังไม่มี' then
    raise exception 'FAIL: ไม่มีหมายเหตุที่บอกทางออกจริง (UPDATE ที่มีร่องรอยด้วยสิทธิ์ cash.confirm) และบอกว่าเส้นทางรายการกลับยังไม่มี · ที่เจอ: %', left(v, 240);
  end if;

  -- (ง) ข้อความที่ผู้ใช้เห็นตอนถูกปฏิเสธก็ต้องไม่ชี้ไปทางที่ไม่มีจริง
  --     ต้องมีแถวจริงก่อน ไม่งั้น "ลบ 0 แถว" ไม่ยิง trigger แล้วข้อนี้ผ่านฟรีๆ
  insert into sri_os.draft_entries(id, owner_id, txn_type_code, doc_date, amount, created_by)
  select '00000000-0000-0000-0000-00000000ce11', o.id, 'inc.other', current_date, 4000,
         pg_temp.huid('h_staff')
    from sri_os.owners o where o.code = 'SRI_CORP';
  insert into sri_os.cash_confirmations(id, draft_entry_id, bank_account_id, expected_amount)
  values ('00000000-0000-0000-0000-00000000ce12', '00000000-0000-0000-0000-00000000ce11',
          '00000000-0000-0000-0000-00000000ca03', 4000);

  begin
    delete from sri_os.cash_confirmations;
  exception when raise_exception then v_msg := sqlerrm;
  end;
  if v_msg = '' or not exists (select 1 from sri_os.cash_confirmations
                                where id = '00000000-0000-0000-0000-00000000ce12') then
    raise exception 'FAIL: ลบใบยืนยันเงินทั้งตารางได้ (ถดถอยจาก 20261008000003)';
  end if;
  if v_msg ~ 'รายการกลับ' and v_msg !~ 'ยังไม่มี' then
    raise exception 'FAIL: ข้อความปฏิเสธชี้ให้ไป "บันทึกรายการกลับ" ซึ่งยังไม่มีเส้นทางนั้นจริง · %', left(v_msg, 200);
  end if;
  if v_msg !~ 'cash.confirm' then
    raise exception 'FAIL: ข้อความปฏิเสธไม่บอกทางออกที่มีจริง (แก้ที่แถวเดิมด้วยสิทธิ์ cash.confirm) · %', left(v_msg, 200);
  end if;
  raise notice 'ok H10 · หมายเหตุและข้อความปฏิเสธของ cash_confirmations ตรงความจริง (UPDATE ที่มีร่องรอย · เส้นทางรายการกลับยังไม่มี)';
end $$;

-- ============================================================
-- H11 · เส้นทางที่ถูกต้องทั้งชุดต้องยังเดินได้ (บทเรียนข้อ 7)
--       ปิดงวด · **เปิดงวดใหม่** · ยืนยันเงินเข้า-ออก · post/reverse ในฐานะ
--       authenticated จริง · เพิ่มทรัพย์/ร่างทรัพย์ (และลบร่างได้ตามที่ตัดสินไว้)
--       · อ่านข้อมูลอ้างอิงทุกตำแหน่ง
-- ============================================================
-- (ก) ปิดงวดเก่า (ไม่ใช่งวดปัจจุบัน ไม่งั้นจะไปล็อกการ post ในข้อ (ค))
insert into sri_os.period_closes(id, owner_id, period, closed_by)
select '00000000-0000-0000-0000-00000000ce01', o.id,
       (date_trunc('month', current_date) - interval '2 month')::date, pg_temp.huid('h_mgmt')
  from sri_os.owners o where o.code = 'SRI_CORP'
on conflict (owner_id, period) do nothing;

set local role authenticated;
do $$
declare n int;
begin
  -- เปิดงวดใหม่: Management มี period.reopen → ต้องลบได้จริง
  perform pg_temp.hlogin('h_mgmt');
  delete from sri_os.period_closes where id = '00000000-0000-0000-0000-00000000ce01';
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'FAIL: Management เปิดงวดใหม่ไม่ได้ (ลบได้ % แถว) → ปิดฟีเจอร์ที่ต้องใช้', n;
  end if;

  -- ปิดงวดอีกครั้งก็ต้องได้ (ไม่ใช่ปิดได้ครั้งเดียวในชีวิต)
  perform pg_temp.hpass('ปิดงวดใหม่อีกครั้ง',
    'insert into sri_os.period_closes(owner_id, period, closed_by)
       select o.id, (date_trunc(''month'', current_date) - interval ''2 month'')::date,
              ' || quote_literal(pg_temp.huid('h_mgmt')) || '::uuid
         from sri_os.owners o where o.code = ''SRI_CORP''');
  raise notice 'ok H11a · ปิดงวด + เปิดงวดใหม่ + ปิดซ้ำ ยังทำได้ครบ';
end $$;
reset role;

do $$
declare v_draft uuid; v_conf uuid;
begin
  -- (ข) ยืนยันเงินเข้า-ออก: สร้างใบ + กรอกยอดจริง (UPDATE คือทางออกที่มีจริง)
  insert into sri_os.draft_entries(id, owner_id, txn_type_code, doc_date, amount, created_by)
  select '00000000-0000-0000-0000-00000000ce02', o.id, 'inc.other', current_date, 7000,
         pg_temp.huid('h_staff')
    from sri_os.owners o where o.code = 'SRI_CORP'
  returning id into v_draft;

  insert into sri_os.cash_confirmations(draft_entry_id, bank_account_id, expected_amount)
  values (v_draft, '00000000-0000-0000-0000-00000000ca03', 7000)
  returning id into v_conf;

  update sri_os.cash_confirmations
     set actual_amount = 7000, actual_date = current_date, confirmed_at = now()
   where id = v_conf;
  if not exists (select 1 from sri_os.audit_log
                  where table_name = 'cash_confirmations' and action = 'update' and row_id = v_conf) then
    raise exception 'FAIL: ยืนยันเงิน (UPDATE) แล้วไม่เหลือร่องรอย — ทางออกที่เอกสารอ้างถึงต้องมีร่องรอยจริง';
  end if;
  raise notice 'ok H11b · สร้างใบยืนยันเงิน + กรอกยอดจริงด้วย UPDATE ได้ และมีร่องรอยใน audit_log';
end $$;

-- (ค) post + reverse ในฐานะ authenticated จริง (ผ่านชั้น GRANT และ RLS)
do $$
declare n int;
begin
  perform pg_temp.hlogin('h_mgmt');
  execute 'set local role authenticated';

  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, attachments, contract_id)
  select '00000000-0000-0000-0000-00000000cf01', o.id, 'inc.other', current_date,
         array['หลักฐาน-HG.pdf'], '00000000-0000-0000-0000-00000000cc01'
    from sri_os.owners o where o.code = 'SRI_CORP';
  insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
  select '00000000-0000-0000-0000-00000000cf01', c.id,
         case when c.rn = 1 then 410 else 0 end,
         case when c.rn = 2 then 410 else 0 end
    from (select c2.id, v.rn from sri_os.chart_of_accounts c2 join (values ('1220', 1), ('4900', 2)) as v(code, rn) on v.code = c2.code) c;

  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, source, reverses_id, attachments)
  select '00000000-0000-0000-0000-00000000cf02', o.id, 'inc.other', current_date,
         'reverse', '00000000-0000-0000-0000-00000000cf01', '{}'
    from sri_os.owners o where o.code = 'SRI_CORP';
  insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
  select '00000000-0000-0000-0000-00000000cf02', l.coa_id, l.credit, l.debit
    from sri_os.transaction_lines l where l.transaction_id = '00000000-0000-0000-0000-00000000cf01';

  update sri_os.transactions set status = 'void'
   where id = '00000000-0000-0000-0000-00000000cf01';

  select count(*) into n from sri_os.transaction_lines
   where transaction_id = '00000000-0000-0000-0000-00000000cf02';
  execute 'reset role';
  if n <> 2 then raise exception 'FAIL: ขากลับรายการลงได้ % บรรทัด', n; end if;
  raise notice 'ok H11c · post + reverse + void ในฐานะ authenticated (ผ่าน GRANT และ RLS) ยังทำได้ · รายการที่ผูกสัญญาด้วย';
exception when others then
  execute 'reset role';
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: เส้นทางจริงของ authenticated ล้ม (%) — กฎใหม่กันแน่นเกิน', sqlerrm;
end $$;

-- (ง) เพิ่มทรัพย์ · ร่างทรัพย์ (และร่างต้องยังลบได้ตามที่ตัดสินไว้รอบก่อน)
do $$
declare v_class uuid; v_cat uuid; v_owner uuid; n int;
begin
  select id, class_id into v_cat, v_class from sri_os.asset_categories order by code limit 1;
  select id into v_owner from sri_os.owners where code = 'SRI_CORP';

  insert into sri_os.assets(code, name, class_id, category_id, owner_id)
  values ('HG-A9', 'ทรัพย์ใหม่หลังกันประวัติ', v_class, v_cat, v_owner);

  insert into sri_os.asset_drafts(id, kind, owner_id, name, class_id, category_id, created_by)
  values ('00000000-0000-0000-0000-00000000ce03', 'create', v_owner,
          'ร่างเทสต์กันประวัติ', v_class, v_cat, pg_temp.huid('h_staff'));
  delete from sri_os.asset_drafts where id = '00000000-0000-0000-0000-00000000ce03';
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'FAIL: ลบร่างทรัพย์ไม่ได้ (% แถว) → กันแน่นเกินกว่าที่ตัดสินไว้ (asset_drafts ลบได้)', n;
  end if;
  raise notice 'ok H11d · เพิ่มทรัพย์/ร่างทรัพย์ได้ และร่างยังลบได้ตามที่ตัดสินไว้';
end $$;

-- (จ) อ่านข้อมูลอ้างอิงทุกตำแหน่ง (ตารางกฎ/ผังบัญชี/taxonomy/สัญญา/งวด)
set local role authenticated;
do $$
declare r text; n bigint; v text := '';
begin
  foreach r in array array['txn_types', 'chart_of_accounts', 'asset_classes', 'asset_categories',
                           'owners', 'contracts', 'schedules', 'bank_accounts', 'assets'] loop
    perform pg_temp.hlogin('h_mgmt');
    execute format('select count(*) from sri_os.%I', r) into n;
    if n = 0 then v := v || r || ', '; end if;
  end loop;
  if v <> '' then
    raise exception 'FAIL: Management อ่านตารางอ้างอิงได้ 0 แถว: % → กฎใหม่ปิดการอ่านไปด้วย', v;
  end if;
  raise notice 'ok H11e · Management ยังอ่านตารางอ้างอิง/สัญญา/งวด/ทรัพย์ได้ครบ';
end $$;
reset role;

do $$ begin raise notice '=== history guards ผ่านทั้งหมด ==='; end $$;

rollback;
