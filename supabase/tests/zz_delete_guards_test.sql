-- ============================================================
-- SRI OS · เทสต์ช่อง "ลบประวัติการเงินได้เงียบๆ" ในอีกสามตาราง
--   ปิดด้วย supabase/migrations/20261008000003_delete_guards.sql
--
--   C* · cash_confirmations — ต้องลบไม่ได้เลย + ต้องมี audit (เดิมไม่มีทั้งสองอย่าง)
--   AL* · audit_log        — เพิ่มได้เท่านั้น (เดิม row DELETE/UPDATE เปิดให้ superuser)
--   P* · period_closes     — **ต้องลบได้ต่อไป** (เปิดงวดใหม่ = เจตนาของระบบ)
--                             แต่ต้องเหลือร่องรอยใน audit_log
--   A* · asset_drafts      — ไม่แก้อะไร แต่พิสูจน์ว่า audit ที่อ้างว่ามีทำงานจริง
--
-- รันในเครื่อง:  bash scripts/test-rls-local.sh
--   ไฟล์ migration ใหม่ต้องอยู่ใน UNDER_TEST ด้วย (ชุด 2026100700000x revoke/sweep
--   ของที่มาก่อน ถ้ารันเรียงชื่อปกติจะทับกัน):
--   UNDER_TEST="... 20261008000002_valuation_delete_guard.sql 20261008000003_delete_guards.sql" \
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
--   M1 ไม่มี trigger กัน DELETE บน cash_confirmations → C0 C1 C2 C4 แดง
--   M2 กันด้วย RLS/revoke แทน trigger                 → C2 แดง (bypassrls + grant ครบ)
--   M3 ไม่กัน TRUNCATE บน cash_confirmations          → C0 C4 แดง
--   M4 ไม่เพิ่ม audit trigger ให้ cash_confirmations   → C0 C6 C7 แดง
--   M5 ไม่มี trigger กัน DELETE/UPDATE บน audit_log    → AL0 AL1 AL2 แดง
--   M6 กัน audit_log แค่ DELETE ไม่กัน UPDATE          → AL0 AL1 AL2 แดง (ขา UPDATE)
--   M7 **เผลอปิดการลบ period_closes**                 → P0 P1 P2 P3 P6 แดง
--   M8 ไม่เพิ่ม audit trigger ให้ period_closes        → P0 P1 P2 P3 แดง
--   M9 ไม่กัน TRUNCATE บน period_closes               → P0 P5 แดง
--   M10 ลืม revoke execute ของ trigger function ใหม่   → C0 AL0 แดง
--   M11 ให้ trigger กันลบไปถาม fn_can                 → C0 AL0 แดง
--   M12 audit trigger ของ asset_drafts หลุด           → A1 แดง
--
-- เคส "ไม่ส่งข้อมูล" (บทเรียนข้อ 3) อยู่ที่ C1/AL1 (DELETE/UPDATE ไม่ใส่ WHERE),
--   C6 (DELETE ที่ไม่ตรงแถวไหน), C7 (ยืนยันเงินโดยยังไม่กรอกยอดจริง),
--   P3 (เปิดงวดทั้งตารางรวดเดียว)
-- ============================================================

begin;

-- ---------- fixtures ----------
create temporary table t_duid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_duid(label) values ('d_super'), ('d_mgmt'), ('d_mgr'), ('d_staff');
insert into auth.users(id) select id from t_duid;

insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, u.label || '@del.local', u.label, x.role, true
  from t_duid u
  join (values ('d_super', 'super_admin'), ('d_mgmt', 'management'),
               ('d_mgr', 'manager'), ('d_staff', 'staff')) as x(label, role)
    on x.label = u.label;

create or replace function pg_temp.duid(p_label text) returns uuid
language sql stable as $fn$ select id from t_duid where label = p_label $fn$;

create or replace function pg_temp.dlogin(p_label text) returns void
language sql as $fn$
  select set_config('test.uid', coalesce((select id::text from t_duid where label = p_label), ''), true);
$fn$;

do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.t_duid to authenticated', s);
end $$;

-- Manager/Staff ต้องเห็น Entity นี้ ไม่งั้นเทสต์ RLS ผ่านเพราะมองไม่เห็นอะไรเลย
insert into sri_os.user_owner_access(user_id, owner_id)
select u.id, o.id from t_duid u cross join sri_os.owners o
 where u.label in ('d_mgr', 'd_staff') and o.code in ('SRI_CORP', 'SUTEE')
on conflict do nothing;

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
select '00000000-0000-0000-0000-00000000dd01', id, 'KBANK', 'บัญชีเทสต์กันลบ', 'บัญชีเทสต์กันลบ'
  from sri_os.owners where code = 'SRI_CORP';

insert into sri_os.draft_entries(id, owner_id, txn_type_code, doc_date, amount, created_by)
select '00000000-0000-0000-0000-00000000dd02', o.id, 'inc.other', current_date, 5000, pg_temp.duid('d_staff')
  from sri_os.owners o where o.code = 'SRI_CORP';

-- ใบยืนยันเงินสามใบ: ยืนยันครบ · ยืนยันบางส่วน · **ยังไม่กรอกยอดจริง**
-- ใบที่สามคือเคส "ไม่ส่งข้อมูล" ของตารางนี้ (คาดว่าเงินจะเข้า แต่ยังไม่เข้า)
insert into sri_os.cash_confirmations
  (id, draft_entry_id, bank_account_id, expected_amount, actual_amount, actual_date, confirmed_by, confirmed_at)
values
  ('00000000-0000-0000-0000-00000000dc01', '00000000-0000-0000-0000-00000000dd02',
   '00000000-0000-0000-0000-00000000dd01', 5000, 5000, current_date, null, now()),
  ('00000000-0000-0000-0000-00000000dc02', '00000000-0000-0000-0000-00000000dd02',
   '00000000-0000-0000-0000-00000000dd01', 5000, 3000, current_date, null, now()),
  ('00000000-0000-0000-0000-00000000dc03', '00000000-0000-0000-0000-00000000dd02',
   '00000000-0000-0000-0000-00000000dd01', 5000, null, null, null, null);

-- กันเทสต์เปล่า: fixture ไม่ครบ = "ลบได้ 0 แถว" แล้วผ่านฟรีๆ ทุกข้อ
do $$
declare n int;
begin
  select count(*) into n from sri_os.cash_confirmations;
  if n <> 3 then
    raise exception 'FAIL: fixture ใบยืนยันเงินต้องมี 3 แถว (ได้ %) — เทสต์ C* จะไม่ได้ตรวจอะไร', n;
  end if;
  -- ขาบวกของคอลัมน์คำนวณ: ใบที่สองต้องถูกมองว่ารับบางส่วน ใบที่สามต้องไม่ใช่
  if (select is_partial from sri_os.cash_confirmations
       where id = '00000000-0000-0000-0000-00000000dc02') is not true then
    raise exception 'FAIL: fixture ใบรับบางส่วนไม่ถูกมองว่า is_partial';
  end if;
end $$;

-- ============================================================
-- C0 · โครงสร้าง cash_confirmations: ไล่จาก pg_trigger จริง
--      ไม่เชื่อว่าไฟล์ migration รันแล้ว
-- ============================================================
do $$
declare v text; n int;
begin
  select count(*) into n
    from pg_trigger tg
   where tg.tgrelid = 'sri_os.cash_confirmations'::regclass
     and not tg.tgisinternal
     and tg.tgname = 'trg_forbid_delete_confirmation'
     and (tg.tgtype & 8) <> 0      -- DELETE
     and (tg.tgtype & 2) <> 0      -- BEFORE
     and (tg.tgtype & 1) <> 0;     -- FOR EACH ROW
  if n <> 1 then
    raise exception 'FAIL: ไม่มี before delete for each row trigger ชื่อ trg_forbid_delete_confirmation บน cash_confirmations → เจ้าของฐานข้อมูลลบหลักฐานว่าเงินเคลื่อนจริงได้';
  end if;

  -- TRUNCATE ไม่ยิง row trigger → ต้องมี statement trigger ของตัวเองด้วย
  select count(*) into n
    from pg_trigger tg
   where tg.tgrelid = 'sri_os.cash_confirmations'::regclass
     and not tg.tgisinternal
     and (tg.tgtype & 32) <> 0;    -- TRUNCATE
  if n < 1 then
    raise exception 'FAIL: ไม่มี truncate trigger บน cash_confirmations → ล้างใบยืนยันทั้งตารางได้ในคำสั่งเดียว';
  end if;

  -- audit ที่เดิมไม่มีเลย · ต้องครอบทั้ง insert/update/delete
  select count(*) into n
    from pg_trigger tg
    join pg_proc p on p.oid = tg.tgfoid
   where tg.tgrelid = 'sri_os.cash_confirmations'::regclass
     and not tg.tgisinternal
     and p.proname = 'fn_audit'
     and (tg.tgtype & 4) <> 0      -- INSERT
     and (tg.tgtype & 8) <> 0      -- DELETE
     and (tg.tgtype & 16) <> 0;    -- UPDATE
  if n <> 1 then
    raise exception 'FAIL: cash_confirmations ไม่มี audit trigger ที่ครอบ insert+update+delete (เจอ %)', n;
  end if;

  -- ฟังก์ชันกันลบต้องเรียกตรงไม่ได้ · ไม่เป็น SECURITY DEFINER · ไม่ถาม fn_can
  select string_agg(p.proname, ', ') into v
    from pg_trigger tg
    join pg_proc p on p.oid = tg.tgfoid
   where tg.tgrelid = 'sri_os.cash_confirmations'::regclass
     and tg.tgname = 'trg_forbid_delete_confirmation'
     and (has_function_privilege('public', p.oid, 'execute')
       or has_function_privilege('anon', p.oid, 'execute')
       or has_function_privilege('authenticated', p.oid, 'execute')
       or p.prosecdef
       or p.prosrc ~* 'fn_can');
  if v is not null then
    raise exception 'FAIL: ฟังก์ชันกัน DELETE ของใบยืนยันเงินหลวมเกินไป (เรียกตรงได้ / SECURITY DEFINER / ถาม fn_can): %', v;
  end if;
  raise notice 'ok C0 · cash_confirmations มี trigger กัน DELETE + TRUNCATE + audit ครบ · ACL ปิดถูก';
end $$;

-- ============================================================
-- C1 · superuser ของคลัสเตอร์ (เจ้าของตาราง · ข้าม RLS) ลบไม่ได้
--      นี่คือช่องที่รายงานไว้ตรงๆ · RLS กันไม่ถึงชั้นนี้
--      + เคสไม่ส่งเงื่อนไข: ลบทั้งตารางรวดเดียวต้องล้มเหมือนกัน
-- ============================================================
reset role;
do $$
declare n_before int; n_after int; v_msg text := '';
begin
  select count(*) into n_before from sri_os.cash_confirmations;

  begin
    delete from sri_os.cash_confirmations
     where id = '00000000-0000-0000-0000-00000000dc01';
    raise exception 'FAIL: superuser ลบใบยืนยันเงินได้ → ยอดที่เคยยืนยันหายไปโดยไม่มีร่องรอย (Money Invariant 5 กระทบยอดไม่ได้)';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
    v_msg := sqlerrm;
  end;

  begin
    delete from sri_os.cash_confirmations;
    raise exception 'FAIL: superuser ลบใบยืนยันเงินทั้งตารางได้';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  -- ใบที่ "ยังไม่กรอกยอดจริง" ก็ลบไม่ได้ (ข้อความ error ต้องไม่ล้มเพราะ null)
  begin
    delete from sri_os.cash_confirmations
     where id = '00000000-0000-0000-0000-00000000dc03';
    raise exception 'FAIL: superuser ลบใบยืนยันที่ยังไม่กรอกยอดจริงได้';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if sqlerrm not like '%ยังไม่ยืนยัน%' then
      raise exception 'FAIL: ข้อความปฏิเสธของใบที่ยังไม่กรอกยอดจริงไม่ได้บอกสภาพนั้น (%) → error ที่อ่านไม่รู้เรื่องทำให้คนไปปิด trigger', left(sqlerrm, 120);
    end if;
  end;

  select count(*) into n_after from sri_os.cash_confirmations;
  if n_after <> n_before or n_before = 0 then
    raise exception 'FAIL: จำนวนแถวเปลี่ยนจาก % เป็น % (หรือ fixture ว่าง) → error ขึ้นแต่ของหายจริง', n_before, n_after;
  end if;
  raise notice 'ok C1 · superuser ลบใบยืนยันเงินไม่ได้ ทั้งระบุแถว ไม่ใส่เงื่อนไข และใบที่ยังไม่กรอกยอดจริง · แถวครบ % (%)',
    n_after, left(v_msg, 60);
end $$;

-- ============================================================
-- C2 · role ที่มี grant ครบ + BYPASSRLS (แรงเท่า service_role ของจริง)
--      ถ้ากันด้วย RLS/grant เพียงอย่างเดียวจะหลุดที่ข้อนี้
--      (harness ในเครื่องสร้าง service_role แบบไม่มี grant → ทดสอบตรงๆ จะผ่านฟรีๆ)
-- ============================================================
do $$
declare r_name text := 'delguard_svc_' || pg_backend_pid(); n_before int; n_after int;
begin
  execute format('create role %I bypassrls', r_name);
  execute format('grant usage on schema sri_os to %I', r_name);
  execute format('grant select, insert, update, delete on sri_os.cash_confirmations to %I', r_name);
  select count(*) into n_before from sri_os.cash_confirmations;

  execute format('set local role %I', r_name);
  begin
    if (select count(*) from sri_os.cash_confirmations) <> n_before then
      raise exception 'FAIL: role ที่ bypassrls มองไม่เห็นแถว — เทสต์นี้ไม่ได้ตรวจอะไร';
    end if;
    delete from sri_os.cash_confirmations where expected_amount = 5000;
    raise exception 'FAIL: role ที่มี grant + bypassrls ลบใบยืนยันเงินได้';
  exception
    when raise_exception then
      reset role;
      if sqlerrm like 'FAIL:%' then raise; end if;
    when insufficient_privilege then
      reset role;
      raise exception 'FAIL: ถูกปฏิเสธด้วย insufficient_privilege (grant) ไม่ใช่ trigger → เทสต์นี้ไม่ได้พิสูจน์ว่ามี trigger';
  end;
  reset role;

  select count(*) into n_after from sri_os.cash_confirmations;
  if n_after <> n_before then
    raise exception 'FAIL: แถวหายไป % แถว', n_before - n_after;
  end if;
  execute format('revoke all on sri_os.cash_confirmations from %I', r_name);
  execute format('revoke usage on schema sri_os from %I', r_name);
  execute format('drop role %I', r_name);
  raise notice 'ok C2 · role ที่แรงเท่า service_role ลบใบยืนยันเงินไม่ได้ · แถวยังครบ';
end $$;

-- ============================================================
-- C3 · ทุกตำแหน่งในแอป (รวม super_admin) ลบไม่ได้
--      ชั้นนี้ RLS กันอยู่แล้ว = **0 แถว ไม่ใช่ error** → ต้องเช็ค row_count
-- ============================================================
set local role authenticated;
do $$
declare r text; n int; n_before int; n_after int;
begin
  perform pg_temp.dlogin('d_mgmt');
  select count(*) into n_before from sri_os.cash_confirmations;
  if n_before = 0 then
    raise exception 'FAIL: management มองไม่เห็นใบยืนยันเงินเลย — เทสต์ C3 ไม่ได้ตรวจอะไร';
  end if;

  foreach r in array array['d_staff', 'd_mgr', 'd_mgmt', 'd_super'] loop
    perform pg_temp.dlogin(r);
    begin
      delete from sri_os.cash_confirmations;
      get diagnostics n = row_count;
      if n <> 0 then
        raise exception 'FAIL: % ลบใบยืนยันเงินได้ % แถว', r, n;
      end if;
    exception
      when insufficient_privilege then null;
      when raise_exception then
        if sqlerrm like 'FAIL:%' then raise; end if;   -- trigger ปฏิเสธก็ถือว่าผ่าน
    end;
  end loop;

  perform pg_temp.dlogin('d_mgmt');
  select count(*) into n_after from sri_os.cash_confirmations;
  if n_after <> n_before then
    raise exception 'FAIL: แถวหายไป % แถว', n_before - n_after;
  end if;
  raise notice 'ok C3 · ทุกตำแหน่งรวม super_admin ลบใบยืนยันเงินไม่ได้ · แถวยังครบ % แถว', n_after;
end $$;
reset role;

-- ============================================================
-- C4 · TRUNCATE (ไม่ยิง row trigger ไม่ผ่าน RLS) ต้องล้มในฐานะ superuser
-- ============================================================
do $$
declare n_before int; n_after int;
begin
  select count(*) into n_before from sri_os.cash_confirmations;
  begin
    truncate table sri_os.cash_confirmations cascade;
    raise exception 'FAIL: TRUNCATE cash_confirmations สำเร็จ = ล้างหลักฐานการเคลื่อนเงินทั้งตารางรวดเดียว';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  select count(*) into n_after from sri_os.cash_confirmations;
  if n_after <> n_before or n_after = 0 then
    raise exception 'FAIL: แถวเหลือ % จาก % → TRUNCATE ลงไปแล้ว', n_after, n_before;
  end if;
  raise notice 'ok C4 · TRUNCATE ใบยืนยันเงินล้ม · แถวยังครบ % แถว', n_after;
end $$;

-- ============================================================
-- C5 · ทางอ้อม: ลบเอกสารต้นทางทิ้งต้องไม่พาใบยืนยันหายไปด้วย
--      (FK ของ cash_confirmations ไม่ได้ ON DELETE CASCADE → ต้องชน FK
--       ข้อนี้ล็อกพฤติกรรมนั้นไว้ ถ้าวันหนึ่งใครเติม cascade เทสต์จะแดง)
-- ============================================================
do $$
declare n int;
begin
  begin
    delete from sri_os.draft_entries where id = '00000000-0000-0000-0000-00000000dd02';
    raise exception 'FAIL: ลบร่างต้นทางที่มีใบยืนยันเงินผูกอยู่ได้ → หลักฐานการเคลื่อนเงินหายทางอ้อม';
  exception
    when foreign_key_violation then null;
    when raise_exception then
      if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  begin
    delete from sri_os.bank_accounts where id = '00000000-0000-0000-0000-00000000dd01';
    raise exception 'FAIL: ลบบัญชีธนาคารที่มีใบยืนยันเงินผูกอยู่ได้';
  exception
    when foreign_key_violation then null;
    when raise_exception then
      if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  select count(*) into n from sri_os.cash_confirmations;
  if n <> 3 then
    raise exception 'FAIL: ใบยืนยันเหลือ % แถว (ต้อง 3)', n;
  end if;
  raise notice 'ok C5 · ลบร่างต้นทาง/บัญชีธนาคารที่มีใบยืนยันผูกอยู่ไม่ได้ · ใบยืนยันครบ 3 แถว';
end $$;

-- ============================================================
-- C6 · ไม่ถดถอย — เส้นทางที่ถูกต้องต้องยังทำได้
--      "ลบไม่ได้" ต้องไม่กลายเป็น "ยืนยันเงินไม่ได้ / แก้ไม่ได้" = เปิดครึ่งเดียว
--      + เคสไม่ส่งข้อมูล: DELETE ที่ไม่ตรงแถวไหนเลย = 0 แถว ไม่ error (ไม่มีอะไรหาย)
-- ============================================================
set local role authenticated;
do $$
declare n int;
begin
  -- Management (cash.confirm) ยืนยันเงินเข้าใหม่ได้
  perform pg_temp.dlogin('d_mgmt');
  insert into sri_os.cash_confirmations
    (id, draft_entry_id, bank_account_id, expected_amount, actual_amount, actual_date)
  values ('00000000-0000-0000-0000-00000000dc04', '00000000-0000-0000-0000-00000000dd02',
          '00000000-0000-0000-0000-00000000dd01', 1200, 1200, current_date);
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL: Management ยืนยันเงินเข้าไม่ได้ = ปิดฟีเจอร์ที่ต้องใช้'; end if;

  -- ทางออกแทนการลบ: แก้ที่แถวเดิม (ยกเลิกการยืนยัน) ด้วยสิทธิ์ cash.confirm
  update sri_os.cash_confirmations
     set actual_amount = null, actual_date = null, confirmed_at = null
   where id = '00000000-0000-0000-0000-00000000dc04';
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'FAIL: ยกเลิกการยืนยันด้วย UPDATE ไม่ได้ → ห้ามลบแล้วไม่มีทางแก้ = เปิดครึ่งเดียว';
  end if;

  -- Manager ไม่มี cash.confirm → ยังต้องยืนยันไม่ได้ (ไม่หลวมลงจากของเดิม)
  perform pg_temp.dlogin('d_mgr');
  begin
    insert into sri_os.cash_confirmations(draft_entry_id, bank_account_id, expected_amount)
    values ('00000000-0000-0000-0000-00000000dd02', '00000000-0000-0000-0000-00000000dd01', 1);
    raise exception 'FAIL: Manager ยืนยันเงินได้ = การแยกหน้าที่หลุด';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok C6 · ยืนยันเงินได้ · แก้/ยกเลิกการยืนยันได้ (ทางออกแทนการลบ) · Manager ยังยืนยันไม่ได้';
end $$;
reset role;

do $$
declare n int;
begin
  -- trigger เป็น for each row → ไม่มีแถวตรงเงื่อนไข = ไม่มี error
  -- เขียนไว้ให้ชัดว่าเป็นพฤติกรรมที่รู้ตัว ไม่ใช่ช่อง (ไม่มีแถวไหนหาย)
  delete from sri_os.cash_confirmations where expected_amount = -1;
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL: ลบแถวที่ไม่มีอยู่ได้ % แถว', n; end if;
  if (select count(*) from sri_os.cash_confirmations) <> 4 then
    raise exception 'FAIL: จำนวนใบยืนยันไม่ใช่ 4 แถวหลังเพิ่มใบใหม่';
  end if;
  raise notice 'ok C6b · DELETE ที่ไม่ตรงแถวไหน = 0 แถวเงียบๆ ไม่มีอะไรหาย';
end $$;

-- ============================================================
-- C7 · audit ของ cash_confirmations ทำงานจริง (เดิมไม่มีเลย)
--      ไม่ใช่แค่ "มี trigger ติดอยู่" — ต้องมีแถวที่เก็บ before/after ได้จริง
-- ============================================================
do $$
declare n_ins int; n_upd int; v_before text; v_after text;
begin
  select count(*) into n_ins from sri_os.audit_log
   where table_name = 'cash_confirmations' and action = 'insert';
  if n_ins < 4 then
    raise exception 'FAIL: audit_log มีการยืนยันเงินแค่ % แถว (ต้อง ≥ 4 จาก fixture+C6) = ยืนยันเงินแล้วไม่เหลือร่องรอย', n_ins;
  end if;

  select count(*) into n_upd from sri_os.audit_log
   where table_name = 'cash_confirmations' and action = 'update';
  if n_upd < 1 then
    raise exception 'FAIL: audit_log ไม่มีการแก้ใบยืนยันเงินเลย = ทางออกแทนการลบไม่เหลือร่องรอย (แย่กว่าเดิม: ห้ามลบแต่แก้ทับได้เงียบๆ)';
  end if;

  -- ยกเลิกการยืนยันของ C6 ต้องเห็นทั้งยอดเดิมและยอดใหม่
  select a.before ->> 'actual_amount', coalesce(a.after ->> 'actual_amount', '(null)')
    into v_before, v_after
    from sri_os.audit_log a
   where a.table_name = 'cash_confirmations' and a.action = 'update'
     and a.row_id = '00000000-0000-0000-0000-00000000dc04'
   order by a.id desc limit 1;
  if v_before is null or v_before not like '1200%' then
    raise exception 'FAIL: audit ของการยกเลิกการยืนยันไม่เก็บยอดเดิมไว้ (before.actual_amount = %)', coalesce(v_before, '(ไม่มีแถว)');
  end if;
  if v_after <> '(null)' then
    raise exception 'FAIL: audit ของการยกเลิกการยืนยันไม่เก็บสภาพใหม่ (after.actual_amount = %)', v_after;
  end if;

  -- เคสไม่ส่งข้อมูล: ใบที่ยังไม่กรอกยอดจริงต้องถูก audit ด้วย (ไม่ใช่ข้ามไปเพราะ null)
  if not exists (
    select 1 from sri_os.audit_log
     where table_name = 'cash_confirmations' and action = 'insert'
       and row_id = '00000000-0000-0000-0000-00000000dc03'
       and after ->> 'actual_amount' is null
       and after ->> 'expected_amount' is not null
  ) then
    raise exception 'FAIL: ใบยืนยันที่ยังไม่กรอกยอดจริงไม่มีร่องรอยใน audit_log';
  end if;
  raise notice 'ok C7 · audit ของใบยืนยันเงินทำงานจริง (insert % แถว · update % แถว · เก็บ before/after ครบ)', n_ins, n_upd;
end $$;

-- ============================================================
-- AL0 · โครงสร้าง audit_log: ต้องกันทั้ง DELETE และ UPDATE ที่ระดับแถว
--       (TRUNCATE กันไว้แล้วตั้งแต่ 20261007000000 — ตรวจซ้ำว่ายังอยู่)
-- ============================================================
do $$
declare v text; n int;
begin
  select count(*) into n
    from pg_trigger tg
   where tg.tgrelid = 'sri_os.audit_log'::regclass
     and not tg.tgisinternal
     and (tg.tgtype & 8) <> 0 and (tg.tgtype & 2) <> 0 and (tg.tgtype & 1) <> 0;
  if n < 1 then
    raise exception 'FAIL: audit_log ไม่มี before delete for each row trigger → คนที่ทำผิดลบหลักฐานของตัวเองได้';
  end if;

  select count(*) into n
    from pg_trigger tg
   where tg.tgrelid = 'sri_os.audit_log'::regclass
     and not tg.tgisinternal
     and (tg.tgtype & 16) <> 0 and (tg.tgtype & 2) <> 0 and (tg.tgtype & 1) <> 0;
  if n < 1 then
    raise exception 'FAIL: audit_log ไม่มี before update for each row trigger → แก้ทับก็คือลบของเดิม';
  end if;

  if not exists (select 1 from pg_trigger
                  where tgrelid = 'sri_os.audit_log'::regclass
                    and not tgisinternal and (tgtype & 32) <> 0) then
    raise exception 'FAIL: audit_log ไม่มี truncate trigger (ถดถอยจาก 20261007000000)';
  end if;

  select string_agg(p.proname, ', ') into v
    from pg_trigger tg
    join pg_proc p on p.oid = tg.tgfoid
   where tg.tgrelid = 'sri_os.audit_log'::regclass
     and tg.tgname = 'trg_forbid_change_audit'
     and (has_function_privilege('public', p.oid, 'execute')
       or has_function_privilege('anon', p.oid, 'execute')
       or has_function_privilege('authenticated', p.oid, 'execute')
       or p.prosecdef
       or p.prosrc ~* 'fn_can');
  if v is not null then
    raise exception 'FAIL: ฟังก์ชันกันแก้ audit_log หลวมเกินไป: %', v;
  end if;
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'sri_os.audit_log'::regclass
                    and tgname = 'trg_forbid_change_audit') then
    raise exception 'FAIL: ไม่มี trigger ชื่อ trg_forbid_change_audit → เช็ค ACL ข้างบนไม่ได้ตรวจอะไร';
  end if;
  raise notice 'ok AL0 · audit_log มี trigger กัน DELETE + UPDATE + TRUNCATE · ACL ปิดถูก';
end $$;

-- ============================================================
-- AL1 · superuser ลบ/แก้แถว audit ไม่ได้ (ทั้งระบุแถวและไม่ใส่เงื่อนไข)
-- ============================================================
do $$
declare n_before int; n_after int; v_id bigint; v_msg text := '';
begin
  select count(*) into n_before from sri_os.audit_log;
  if n_before = 0 then
    raise exception 'FAIL: audit_log ว่าง — เทสต์ AL* ไม่ได้ตรวจอะไร';
  end if;
  select id into v_id from sri_os.audit_log order by id desc limit 1;

  begin
    delete from sri_os.audit_log where id = v_id;
    raise exception 'FAIL: superuser ลบแถว audit ได้ → ร่องรอยที่ลบได้ไม่ใช่ร่องรอย';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
    v_msg := sqlerrm;
  end;

  begin
    delete from sri_os.audit_log;
    raise exception 'FAIL: superuser ลบ audit ทั้งตารางได้';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  -- UPDATE: แก้ทับก็คือลบของเดิม · ทั้งแบบระบุแถวและแบบกวาดทั้งตาราง
  begin
    update sri_os.audit_log set user_id = null where id = v_id;
    raise exception 'FAIL: superuser แก้แถว audit ได้ → ลบคนที่ทำออกจากหลักฐานได้';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  begin
    update sri_os.audit_log set before = null, after = null;
    raise exception 'FAIL: superuser ล้างเนื้อหา audit ทั้งตารางได้';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  select count(*) into n_after from sri_os.audit_log;
  if n_after <> n_before then
    raise exception 'FAIL: แถว audit เปลี่ยนจาก % เป็น %', n_before, n_after;
  end if;
  if exists (select 1 from sri_os.audit_log where before is null and after is null) then
    raise exception 'FAIL: มีแถว audit ที่เนื้อหาถูกล้างจริง ทั้งที่ขึ้น error';
  end if;
  raise notice 'ok AL1 · superuser ลบ/แก้ audit ไม่ได้ ทั้งระบุแถวและไม่ใส่เงื่อนไข · % แถวครบ (%)',
    n_after, left(v_msg, 60);
end $$;

-- ============================================================
-- AL2 · role ที่ grant ครบ + bypassrls ก็ลบ/แก้ audit ไม่ได้
-- ============================================================
do $$
declare r_name text := 'delguard_aud_' || pg_backend_pid(); n_before int; n_after int;
begin
  execute format('create role %I bypassrls', r_name);
  execute format('grant usage on schema sri_os to %I', r_name);
  execute format('grant select, insert, update, delete on sri_os.audit_log to %I', r_name);
  select count(*) into n_before from sri_os.audit_log;

  execute format('set local role %I', r_name);
  begin
    if (select count(*) from sri_os.audit_log) <> n_before then
      raise exception 'FAIL: role ที่ bypassrls มองไม่เห็นแถว audit — เทสต์นี้ไม่ได้ตรวจอะไร';
    end if;
    delete from sri_os.audit_log where table_name = 'cash_confirmations';
    raise exception 'FAIL: role ที่มี grant + bypassrls ลบ audit ได้';
  exception
    when raise_exception then
      reset role;
      if sqlerrm like 'FAIL:%' then raise; end if;
    when insufficient_privilege then
      reset role;
      raise exception 'FAIL: ถูกปฏิเสธด้วย insufficient_privilege (grant) ไม่ใช่ trigger';
  end;
  reset role;

  execute format('set local role %I', r_name);
  begin
    update sri_os.audit_log set table_name = 'xxx' where table_name = 'cash_confirmations';
    raise exception 'FAIL: role ที่มี grant + bypassrls แก้ audit ได้';
  exception
    when raise_exception then
      reset role;
      if sqlerrm like 'FAIL:%' then raise; end if;
    when insufficient_privilege then
      reset role;
      raise exception 'FAIL: ขา UPDATE ถูกปฏิเสธด้วย grant ไม่ใช่ trigger';
  end;
  reset role;

  select count(*) into n_after from sri_os.audit_log;
  if n_after <> n_before then
    raise exception 'FAIL: แถว audit หายไป % แถว', n_before - n_after;
  end if;
  if exists (select 1 from sri_os.audit_log where table_name = 'xxx') then
    raise exception 'FAIL: audit ถูกแก้ชื่อตารางจริง';
  end if;
  execute format('revoke all on sri_os.audit_log from %I', r_name);
  execute format('revoke usage on schema sri_os from %I', r_name);
  execute format('drop role %I', r_name);
  raise notice 'ok AL2 · role ที่แรงเท่า service_role ลบ/แก้ audit ไม่ได้';
end $$;

-- ============================================================
-- AL3 · ทุกตำแหน่งในแอป: audit_log อ่านได้ (บางตำแหน่ง) แต่ลบ/แก้ไม่ได้เลย
--       RLS มีแต่ policy SELECT → **0 แถว ไม่ใช่ error** → เช็ค row_count
-- ============================================================
set local role authenticated;
do $$
declare r text; n int; n_before int;
begin
  perform pg_temp.dlogin('d_mgmt');
  select count(*) into n_before from sri_os.audit_log;
  if n_before = 0 then
    raise exception 'FAIL: management อ่าน audit_log ไม่เห็นเลย — เทสต์ AL3 ไม่ได้ตรวจอะไร';
  end if;

  foreach r in array array['d_staff', 'd_mgr', 'd_mgmt', 'd_super'] loop
    perform pg_temp.dlogin(r);
    begin
      delete from sri_os.audit_log;
      get diagnostics n = row_count;
      if n <> 0 then raise exception 'FAIL: % ลบ audit ได้ % แถว', r, n; end if;
    exception
      when insufficient_privilege then null;
      when raise_exception then if sqlerrm like 'FAIL:%' then raise; end if;
    end;
    begin
      update sri_os.audit_log set user_id = null;
      get diagnostics n = row_count;
      if n <> 0 then raise exception 'FAIL: % แก้ audit ได้ % แถว', r, n; end if;
    exception
      when insufficient_privilege then null;
      when raise_exception then if sqlerrm like 'FAIL:%' then raise; end if;
    end;
  end loop;

  perform pg_temp.dlogin('d_mgmt');
  if (select count(*) from sri_os.audit_log) <> n_before then
    raise exception 'FAIL: จำนวนแถว audit ที่ management เห็นเปลี่ยนไป';
  end if;
  raise notice 'ok AL3 · ทุกตำแหน่งรวม super_admin ลบ/แก้ audit ไม่ได้ · % แถวครบ', n_before;
end $$;
reset role;

-- ============================================================
-- AL4 · TRUNCATE audit_log ล้ม (ไม่ถดถอยจาก 20261007000000)
-- ============================================================
do $$
declare n_before int; n_after int;
begin
  select count(*) into n_before from sri_os.audit_log;
  begin
    truncate table sri_os.audit_log;
    raise exception 'FAIL: TRUNCATE audit_log สำเร็จ';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  select count(*) into n_after from sri_os.audit_log;
  if n_after <> n_before or n_after = 0 then
    raise exception 'FAIL: แถว audit เหลือ % จาก %', n_after, n_before;
  end if;
  raise notice 'ok AL4 · TRUNCATE audit_log ล้ม · % แถวครบ', n_after;
end $$;

-- ============================================================
-- AL5 · ไม่ถดถอย: "เพิ่มได้เท่านั้น" ต้องยัง **เพิ่มได้จริง**
--       ถ้าเผลอกัน INSERT ด้วย ระบบจะเลิกบันทึกร่องรอยทั้งหมดเงียบๆ
-- ============================================================
do $$
declare n_before int; n_after int;
begin
  select count(*) into n_before from sri_os.audit_log;

  -- (ก) ทางตรง
  insert into sri_os.audit_log(table_name, row_id, action, after)
  values ('delguard_probe', gen_random_uuid(), 'insert', '{"probe": true}'::jsonb);

  -- (ข) ทางที่ระบบใช้จริง: fn_audit ยิงจากการแก้ข้อมูล
  update sri_os.cash_confirmations set slip_url = 'slip-delguard.pdf'
   where id = '00000000-0000-0000-0000-00000000dc03';

  select count(*) into n_after from sri_os.audit_log;
  if n_after < n_before + 2 then
    raise exception 'FAIL: เพิ่มแถว audit ไม่ได้ (% → %) → กันแน่นเกินไป ระบบเลิกบันทึกร่องรอย', n_before, n_after;
  end if;
  raise notice 'ok AL5 · audit_log ยังเพิ่มได้ทั้งทางตรงและผ่าน fn_audit (% → % แถว)', n_before, n_after;
end $$;

-- ============================================================
-- P0 · โครงสร้าง period_closes: ต้องมี audit + กัน TRUNCATE
--      และ **ต้องไม่มี** trigger ขัดขวาง DELETE (จุดที่กันแน่นเกินจะผิด)
-- ============================================================
do $$
declare v text; n int;
begin
  select count(*) into n
    from pg_trigger tg
    join pg_proc p on p.oid = tg.tgfoid
   where tg.tgrelid = 'sri_os.period_closes'::regclass
     and not tg.tgisinternal
     and p.proname = 'fn_audit'
     and (tg.tgtype & 4) <> 0 and (tg.tgtype & 8) <> 0 and (tg.tgtype & 16) <> 0;
  if n <> 1 then
    raise exception 'FAIL: period_closes ไม่มี audit trigger ที่ครอบ insert+update+delete (เจอ %) → ปิดงวดแล้วเปิดใหม่ไม่เหลือร่องรอย', n;
  end if;

  if not exists (select 1 from pg_trigger
                  where tgrelid = 'sri_os.period_closes'::regclass
                    and not tgisinternal and (tgtype & 32) <> 0) then
    raise exception 'FAIL: period_closes ไม่มี truncate trigger → เปิดทุกงวดของทุกผู้ถือรวดเดียวโดยไม่เหลือ audit (row trigger ไม่ยิงตอน TRUNCATE)';
  end if;

  -- ของที่ต้องไม่มี
  select string_agg(tg.tgname, ', ') into v
    from pg_trigger tg
    join pg_proc p on p.oid = tg.tgfoid
   where tg.tgrelid = 'sri_os.period_closes'::regclass
     and not tg.tgisinternal
     and (tg.tgtype & 8) <> 0
     and p.proname <> 'fn_audit';
  if v is not null then
    raise exception 'FAIL: period_closes มี trigger ขัดขวาง DELETE: % · การลบที่นี่คือ "เปิดงวดใหม่" ซึ่งเป็นเจตนาของระบบ (สิทธิ์ period.reopen) ห้ามปิด', v;
  end if;
  if not exists (select 1 from pg_policies
                  where schemaname = 'sri_os' and tablename = 'period_closes' and cmd = 'DELETE') then
    raise exception 'FAIL: ไม่มี policy FOR DELETE บน period_closes → เปิดงวดใหม่จากแอปไม่ได้';
  end if;
  raise notice 'ok P0 · period_closes มี audit + กัน TRUNCATE · ไม่มี trigger ปิดการลบ · policy เปิดงวดใหม่ยังอยู่';
end $$;

-- ---------- fixture ของชุด P: ปิดงวดให้ทั้งสองฝั่ง ----------
insert into sri_os.period_closes(id, owner_id, period, closed_by)
select '00000000-0000-0000-0000-00000000dd11', o.id,
       date_trunc('month', current_date)::date, pg_temp.duid('d_mgmt')
  from sri_os.owners o where o.code = 'SRI_CORP'
on conflict (owner_id, period) do nothing;

insert into sri_os.period_closes(id, owner_id, period, closed_by)
select '00000000-0000-0000-0000-00000000dd12', o.id,
       date_trunc('month', current_date)::date, pg_temp.duid('d_mgmt')
  from sri_os.owners o where o.code = 'SUTEE'
on conflict (owner_id, period) do nothing;

do $$
declare n int;
begin
  select count(*) into n from sri_os.period_closes
   where id in ('00000000-0000-0000-0000-00000000dd11', '00000000-0000-0000-0000-00000000dd12');
  if n <> 2 then
    raise exception 'FAIL: fixture ปิดงวดต้องมี 2 แถว (ได้ %) — เทสต์ P* จะไม่ได้ตรวจอะไร', n;
  end if;
  -- การปิดงวดต้องเหลือร่องรอยแล้วตั้งแต่ตอนปิด ไม่ใช่เฉพาะตอนเปิดใหม่
  if not exists (select 1 from sri_os.audit_log
                  where table_name = 'period_closes' and action = 'insert'
                    and row_id = '00000000-0000-0000-0000-00000000dd11') then
    raise exception 'FAIL: ปิดงวดแล้วไม่มีร่องรอยใน audit_log';
  end if;
  raise notice 'ok P0b · การปิดงวดเหลือร่องรอยใน audit_log แล้ว';
end $$;

-- ============================================================
-- P1 · เปิดงวดใหม่จากแอปต้อง **ยังทำได้** และต้องเหลือร่องรอย
--      นี่คือข้อที่จะแดงทันทีถ้าใครเผลอปิดการลบตารางนี้
-- ============================================================
set local role authenticated;
do $$
declare n int;
begin
  -- Manager ไม่มี period.reopen → RLS กัน = 0 แถว ไม่ใช่ error
  perform pg_temp.dlogin('d_mgr');
  delete from sri_os.period_closes where id = '00000000-0000-0000-0000-00000000dd11';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL: Manager เปิดงวดที่ปิดแล้วได้ % แถว', n; end if;
  if not exists (select 1 from sri_os.period_closes
                  where id = '00000000-0000-0000-0000-00000000dd11') then
    raise exception 'FAIL: แถวปิดงวดหายไปทั้งที่ Manager ควรลบไม่ได้';
  end if;

  -- Management มี period.reopen → ต้องลบได้จริง
  perform pg_temp.dlogin('d_mgmt');
  delete from sri_os.period_closes where id = '00000000-0000-0000-0000-00000000dd11';
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'FAIL: Management (period.reopen) เปิดงวดใหม่ไม่ได้ (ลบได้ % แถว) → ปิดฟีเจอร์ที่ลูกพี่ต้องใช้', n;
  end if;
  raise notice 'ok P1 · Manager เปิดงวดใหม่ไม่ได้ · Management เปิดได้จริง';
end $$;
reset role;

do $$
declare v_period text; v_user uuid;
begin
  select a.before ->> 'period', a.user_id into v_period, v_user
    from sri_os.audit_log a
   where a.table_name = 'period_closes' and a.action = 'delete'
     and a.row_id = '00000000-0000-0000-0000-00000000dd11'
   order by a.id desc limit 1;
  if v_period is null then
    raise exception 'FAIL: เปิดงวดใหม่แล้วไม่เหลือร่องรอยใน audit_log → ตัวเลขย้อนหลังเปลี่ยนได้โดยไม่มีใครรู้';
  end if;
  if v_period <> to_char(date_trunc('month', current_date), 'YYYY-MM-01') then
    raise exception 'FAIL: audit ของการเปิดงวดใหม่ไม่ได้บอกงวดที่ถูกเปิด (ได้ %)', v_period;
  end if;
  if v_user is distinct from pg_temp.duid('d_mgmt') then
    raise exception 'FAIL: audit ของการเปิดงวดใหม่ไม่ได้บอกว่าใครทำ (user_id = %)', coalesce(v_user::text, '(null)');
  end if;
  raise notice 'ok P1b · audit เก็บงวดที่ถูกเปิด (%) และผู้ที่ทำไว้ครบ', v_period;
end $$;

-- ============================================================
-- P2 · superuser ก็ต้องลบได้ (ตารางนี้ **ไม่มี** ด่าน trigger โดยเจตนา)
--      ถ้าข้อนี้แดง = กันแน่นเกินไป ไม่ใช่กันหลุด
-- ============================================================
do $$
declare n int;
begin
  insert into sri_os.period_closes(id, owner_id, period, closed_by)
  select '00000000-0000-0000-0000-00000000dd13', o.id,
         (date_trunc('month', current_date) - interval '1 month')::date, pg_temp.duid('d_mgmt')
    from sri_os.owners o where o.code = 'SRI_CORP';

  delete from sri_os.period_closes where id = '00000000-0000-0000-0000-00000000dd13';
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'FAIL: superuser ลบแถวปิดงวดไม่ได้ (% แถว) → มี trigger ปิดฟีเจอร์เปิดงวดใหม่', n;
  end if;
  if not exists (select 1 from sri_os.audit_log
                  where table_name = 'period_closes' and action = 'delete'
                    and row_id = '00000000-0000-0000-0000-00000000dd13') then
    raise exception 'FAIL: การลบของ superuser ไม่เหลือร่องรอย';
  end if;
  raise notice 'ok P2 · superuser เปิดงวดใหม่ได้และเหลือร่องรอย';
end $$;

-- ============================================================
-- P3 · เคสไม่ส่งข้อมูล: DELETE ไม่ใส่ WHERE (เปิดทุกงวดรวดเดียว)
--      ต้องทำได้ตามเจตนา และต้องเหลือร่องรอย **ทุกแถว** ไม่ใช่แถวเดียว
-- ============================================================
do $$
declare n_rows int; n_audit_before int; n_audit_after int;
begin
  select count(*) into n_rows from sri_os.period_closes;
  if n_rows = 0 then
    raise exception 'FAIL: ไม่มีแถวปิดงวดเหลือ — เทสต์ P3 ไม่ได้ตรวจอะไร';
  end if;
  select count(*) into n_audit_before from sri_os.audit_log
   where table_name = 'period_closes' and action = 'delete';

  delete from sri_os.period_closes;

  if (select count(*) from sri_os.period_closes) <> 0 then
    raise exception 'FAIL: ลบแถวปิดงวดทั้งตารางไม่หมด';
  end if;
  select count(*) into n_audit_after from sri_os.audit_log
   where table_name = 'period_closes' and action = 'delete';
  if n_audit_after <> n_audit_before + n_rows then
    raise exception 'FAIL: ลบ % แถว แต่ audit เพิ่มแค่ % แถว → audit เป็น statement trigger หรือหลุดบางแถว',
      n_rows, n_audit_after - n_audit_before;
  end if;
  raise notice 'ok P3 · เปิดทุกงวดรวดเดียวได้ (% แถว) และ audit ครบทุกแถว', n_rows;
end $$;

-- ============================================================
-- P5 · TRUNCATE period_closes ต้องล้ม — ไม่ใช่เพราะ "ห้ามลบ"
--      แต่เพราะ TRUNCATE ไม่ยิง row trigger = เปิดทุกงวดแบบไร้ร่องรอย
-- ============================================================
do $$
declare n_before int;
begin
  insert into sri_os.period_closes(id, owner_id, period, closed_by)
  select '00000000-0000-0000-0000-00000000dd14', o.id,
         date_trunc('month', current_date)::date, pg_temp.duid('d_mgmt')
    from sri_os.owners o where o.code = 'SRI_CORP';
  select count(*) into n_before from sri_os.period_closes;

  begin
    truncate table sri_os.period_closes;
    raise exception 'FAIL: TRUNCATE period_closes สำเร็จ = เปิดทุกงวดของทุกผู้ถือโดยไม่เหลือ audit แม้แถวเดียว';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  if (select count(*) from sri_os.period_closes) <> n_before or n_before = 0 then
    raise exception 'FAIL: แถวปิดงวดหายไปจริง (เหลือ % จาก %)',
      (select count(*) from sri_os.period_closes), n_before;
  end if;
  raise notice 'ok P5 · TRUNCATE period_closes ล้ม · การลบทีละงวดยังทำได้ (P1/P2/P3)';
end $$;

-- ============================================================
-- P6 · ผลลัพธ์ที่ต้องได้จริง: ปิดงวดแล้ว **ลงรายการย้อนไม่ได้**
--      เปิดงวดใหม่แล้ว **ลงได้** — เส้นทางที่ถูกต้องครบวง
--      (ถ้าปิดการลบตารางนี้ ข้อนี้จะไม่มีทางผ่าน)
-- ============================================================
set local role authenticated;
do $$
declare v_owner uuid; n int;
begin
  select id into v_owner from sri_os.owners where code = 'SRI_CORP';
  perform pg_temp.dlogin('d_mgr');

  -- งวดนี้ถูกปิดอยู่ (dp04) → corporate_strict ต้องลงไม่ได้
  begin
    insert into sri_os.transactions(owner_id, txn_type_code, doc_date, attachments)
    values (v_owner, 'inc.other', current_date, array['slip.pdf']);
    raise exception 'FAIL: ลงรายการในงวดที่ปิดแล้วของ corporate_strict ได้ = การล็อกงวดหลุด';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if sqlerrm not like '%ปิดแล้ว%' then raise; end if;
  end;

  -- เปิดงวดใหม่ด้วยสิทธิ์ period.reopen
  perform pg_temp.dlogin('d_mgmt');
  delete from sri_os.period_closes where id = '00000000-0000-0000-0000-00000000dd14';
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL: เปิดงวดใหม่ไม่ได้ (% แถว)', n; end if;

  -- แล้วต้องลงรายการได้จริง
  perform pg_temp.dlogin('d_mgr');
  insert into sri_os.transactions(owner_id, txn_type_code, doc_date, attachments)
  values (v_owner, 'inc.other', current_date, array['slip.pdf']);
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL: เปิดงวดใหม่แล้วยังลงรายการไม่ได้'; end if;
  raise notice 'ok P6 · ปิดงวด → ลงย้อนไม่ได้ · เปิดงวดใหม่ → ลงได้ · ครบวงและมีร่องรอยทุกขั้น';
end $$;
reset role;

-- ============================================================
-- A1 · asset_drafts: ตัดสินว่าไม่ต้องกันการลบ (เป็นร่างก่อนอนุมัติ ไม่ใช่ประวัติเงิน)
--      แต่ข้ออ้างว่า "มี audit อยู่แล้ว" ต้องพิสูจน์ ไม่ใช่เชื่อ
-- ============================================================
do $$
declare v_class uuid; v_cat uuid; v_owner uuid; n int;
begin
  select id, class_id into v_cat, v_class from sri_os.asset_categories order by id limit 1;
  select id into v_owner from sri_os.owners where code = 'SRI_CORP';

  insert into sri_os.asset_drafts(id, kind, owner_id, name, class_id, category_id, created_by)
  values ('00000000-0000-0000-0000-00000000dd21', 'create', v_owner,
          'ร่างเทสต์กันลบ', v_class, v_cat, pg_temp.duid('d_staff'));

  if not exists (select 1 from sri_os.audit_log
                  where table_name = 'asset_drafts' and action = 'insert'
                    and row_id = '00000000-0000-0000-0000-00000000dd21'
                    and after ->> 'name' = 'ร่างเทสต์กันลบ') then
    raise exception 'FAIL: สร้างร่างทรัพย์แล้วไม่มีร่องรอยใน audit_log → ข้ออ้างว่า asset_drafts มี audit อยู่แล้วไม่จริง';
  end if;

  -- ลบได้ตามที่ตัดสินไว้ (ไม่ใช่ประวัติเงิน) แต่ต้องเหลือ before ไว้ครบ
  delete from sri_os.asset_drafts where id = '00000000-0000-0000-0000-00000000dd21';
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'FAIL: ลบร่างทรัพย์ไม่ได้ (% แถว) → กันแน่นเกินกว่าที่ตัดสินไว้', n;
  end if;
  if not exists (select 1 from sri_os.audit_log
                  where table_name = 'asset_drafts' and action = 'delete'
                    and row_id = '00000000-0000-0000-0000-00000000dd21'
                    and before ->> 'name' = 'ร่างเทสต์กันลบ') then
    raise exception 'FAIL: ลบร่างทรัพย์แล้วไม่เหลือเนื้อหาเดิมใน audit_log = ลบได้เงียบๆ';
  end if;
  raise notice 'ok A1 · asset_drafts ลบได้ตามที่ตัดสิน และ audit ของมันทำงานจริงทั้ง insert และ delete';
end $$;

-- ============================================================
-- Z1 · ไล่ทั้งสคีมา: ตารางที่เป็นประวัติทางการเงินต้องมีด่าน DELETE ที่ระดับแถว
--      **และ** trigger กัน TRUNCATE · ไล่จาก pg_trigger จริง ไม่ใช่ไล่ไฟล์
--      (grep ไฟล์พลาดมาแล้ว) · audit trigger **ไม่นับเป็นด่าน** เพราะมันบันทึก
--      ไม่ได้ขัดขวาง — ของที่นับคือ trigger ที่ปฏิเสธ (fn_forbid_* หรือด่านเงื่อนไข
--      อย่าง fn_lines_immutable_after_post ที่ปฏิเสธเฉพาะรายการที่ post แล้ว)
--
--      **รายชื่อนี้คือของที่ตัดสินแล้วถึงรอบนี้** ถ้าเพิ่มตารางประวัติการเงินใหม่
--      แล้วไม่กันลบ ข้อนี้จะไม่จับให้ — ต้องเติมชื่อเข้ามาเอง
--      contracts/schedules เข้ามาในรอบ 20261008000004 (ตัดสินแล้วว่าปิด DELETE
--      แต่ **UPDATE ยังเปิด** เพราะต้องเลื่อนงวด/แก้อัตราได้ — เทสต์เต็มอยู่ที่
--      supabase/tests/zz_history_guards_test.sql · ข้อนี้ตรวจแต่ด่าน DELETE/TRUNCATE)
-- ============================================================
do $$
declare r text; v text := '';
begin
  foreach r in array array['transactions', 'transaction_lines', 'asset_valuations',
                           'cash_confirmations', 'contracts', 'schedules'] loop
    if not exists (
      select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
       where tg.tgrelid = ('sri_os.' || r)::regclass and not tg.tgisinternal
         and (tg.tgtype & 8) <> 0 and (tg.tgtype & 2) <> 0 and (tg.tgtype & 1) <> 0
         and p.proname <> 'fn_audit'
         and p.prosrc ~* 'raise exception'
    ) then
      v := v || r || ' (ไม่มีด่าน DELETE ที่ระดับแถว), ';
    end if;
    if not exists (
      select 1 from pg_trigger tg
       where tg.tgrelid = ('sri_os.' || r)::regclass and not tg.tgisinternal
         and (tg.tgtype & 32) <> 0
    ) then
      v := v || r || ' (ไม่มี trigger กัน TRUNCATE), ';
    end if;
  end loop;
  if v <> '' then
    raise exception 'FAIL: ตารางประวัติการเงินที่ยังลบได้: %', v;
  end if;
  raise notice 'ok Z1 · ตารางประวัติการเงินที่ตัดสินแล้ว 6 ตาราง (รวม contracts/schedules) มีด่าน DELETE ระดับแถว + กัน TRUNCATE ครบ';
end $$;

do $$ begin raise notice '=== delete guards ผ่านทั้งหมด ==='; end $$;

rollback;
