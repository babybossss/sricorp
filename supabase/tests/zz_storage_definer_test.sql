-- ============================================================
-- SRI OS · เทสต์ของ 20261020000004_storage_definer_allowlist.sql — ฝั่งที่ **ไม่มี** storage
--   รันด้วย scripts/test-rls-local.sh (harness นั้นไม่มีสคีมา storage → 20261008000009 ขึ้น SKIP)
--   ฝั่งที่มี storage อยู่ที่ supabase/tests-storage/zz_storage_definer_test.sql
--
-- ไฟล์นี้พิสูจน์ **ข้อ C ของงาน**: คำกล่าวอ้างของ D-089 ที่ว่า
--   "ทางอ้อมที่ไม่ขึ้นทะเบียน = ด่านพัง" ต้องจริงแม้ทางอ้อมนั้นผ่านฟังก์ชันอีกชั้น
--   (ก่อนไฟล์ migration นั้น ด่านอ่านชื่อตารางจาก prosrc ของฟังก์ชันตัวเดียว
--    → definer ที่แตะตาราง row ผ่าน callee **หลุดทั้งหมด**)
--
-- ไล่ "ถอดการแก้ออกแล้วต้องแดง" (mutation):
--   S3 ถอดการไล่ callee (กลับไปอ่านแค่ prosrc)         → DW2 DW3 DW6
--   ถอดการตัดคอมเมนต์ก่อนไล่                            → DW4 (ด่านร้องของปลอม)
--   ถอดการลบ allow-list ค้างเมื่อไม่มี storage           → DW7
--   ถอด perform fn_storage_definer_guard() ใน guard รวม → ดูไฟล์ฝั่ง storage (G8/G10)
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ rollback ปิดท้าย
-- ============================================================

begin;

create or replace function pg_temp.must_raise(p_label text, p_sql text, p_needle text) returns void
language plpgsql as $fn$
begin
  execute p_sql;
  raise exception 'FAIL: % — ควร raise แต่ผ่านไปเฉยๆ · sql: %', p_label, p_sql;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  if position(p_needle in sqlerrm) = 0 then
    raise exception 'FAIL: % — raise แล้วแต่ข้อความไม่ใช่เรื่องที่ตั้งใจตรวจ (ต้องมี "%") · ได้: %',
      p_label, p_needle, sqlerrm;
  end if;
end $fn$;

-- ---------- DW0 · ด่านต้องเรียบร้อยก่อนเริ่ม ----------
do $$
declare n int;
begin
  begin
    perform sri_os.fn_column_exposure_guard();
  exception when others then
    raise exception 'FAIL: DW0 ด่านคอลัมน์ไม่เรียบร้อยก่อนเทสต์จะเริ่ม → เคสอื่นเชื่อไม่ได้ · สาเหตุ: %', sqlerrm;
  end;
  select count(*) into n from sri_os.fn_column_exposure_row_escapes();
  if n <> 0 then
    raise exception 'FAIL: DW0 มีทางอ้อมแบบ definer ค้างอยู่ % รายการก่อนเทสต์เริ่ม', n;
  end if;
  raise notice 'ok DW0 · ด่านคอลัมน์เรียบร้อย · ไม่มีทางอ้อมค้าง';
end $$;

-- ---------- DW1 · ของเดิมยังต้องจับทางตรงได้ (ไม่ใช่แก้แล้วหายไปอีกฝั่ง) ----------
do $$
declare n int;
begin
  create or replace function sri_os.zz_dw_direct()
  returns table (id uuid, memo text)
  language sql stable security definer set search_path = '' as $f$
    select t.id, t.memo from sri_os.transactions t
  $f$;
  grant execute on function sri_os.zz_dw_direct() to authenticated;
  select count(*) into n from sri_os.fn_column_exposure_row_escapes()
   where function_name = 'zz_dw_direct' and table_name = 'transactions';
  if n <> 1 then
    raise exception 'FAIL: DW1 definer ที่อ่าน transactions ตรงๆ ไม่ถูกจับ (% แถว)', n;
  end if;
  if not exists (select 1 from sri_os.fn_column_exposure_row_escapes()
                  where function_name = 'zz_dw_direct' and problem like '%ตรงๆ%') then
    raise exception 'FAIL: DW1b ข้อความไม่ได้บอกว่าเป็นการอ่านตรงๆ → คนอ่านรายงานแยกทางตรง/ทางอ้อมไม่ออก';
  end if;
  perform pg_temp.must_raise('DW1c guard รวมต้องแดง',
    'select sri_os.fn_column_exposure_guard()', 'ไม่ติดจริง');
  drop function sri_os.zz_dw_direct();
  perform sri_os.fn_column_exposure_guard();
  raise notice 'ok DW1 · ทางตรงยังถูกจับเหมือนเดิม';
end $$;

-- ---------- DW2 · ทางอ้อมหนึ่งชั้น (นี่คือรูที่ปิดในรอบนี้) ----------
do $$
declare n int; v text;
begin
  -- helper ไม่ใช่ definer และไม่มีใครเรียกได้ → ของเดิมมองไม่เห็นอะไรเลย
  create or replace function sri_os.zz_dw_inner() returns bigint
  language sql stable set search_path = '' as $f$
    select count(*) from sri_os.transaction_lines
  $f$;
  revoke all on function sri_os.zz_dw_inner() from public;
  -- definer ที่ผู้ใช้แอปเรียกได้ แต่ **ไม่เอ่ยชื่อตารางเลย**
  create or replace function sri_os.zz_dw_outer() returns bigint
  language sql stable security definer set search_path = '' as $f$
    select sri_os.zz_dw_inner()
  $f$;
  grant execute on function sri_os.zz_dw_outer() to authenticated;

  select count(*) into n from sri_os.fn_column_exposure_row_escapes()
   where function_name = 'zz_dw_outer' and table_name = 'transaction_lines';
  if n <> 1 then
    raise exception 'FAIL: DW2 definer ที่แตะ transaction_lines ผ่านฟังก์ชันอื่นไม่ถูกจับ (% แถว) → คำกล่าวอ้างของ D-089 ยังไม่จริง (นี่คือเคสที่ mutation S3 ต้องทำให้แดง)', n;
  end if;
  select problem into v from sri_os.fn_column_exposure_row_escapes()
   where function_name = 'zz_dw_outer' and table_name = 'transaction_lines';
  if position('ผ่านฟังก์ชันอื่น' in v) = 0 then
    raise exception 'FAIL: DW2b ข้อความไม่ได้บอกว่าเป็นทางอ้อม · ได้: %', v;
  end if;
  -- helper เองไม่ถูกรายงาน (ไม่ใช่ definer และเรียกไม่ได้) = ไม่ใช่ทางเข้า
  if exists (select 1 from sri_os.fn_column_exposure_row_escapes()
              where function_name = 'zz_dw_inner') then
    raise exception 'FAIL: DW2c ด่านรายงานฟังก์ชันที่ไม่มีใครเรียกได้ → รายงานท่วมจนคนปิดด่าน';
  end if;
  perform pg_temp.must_raise('DW2d guard รวมต้องแดงกับทางอ้อม',
    'select sri_os.fn_column_exposure_guard()', 'ไม่ติดจริง');
  raise notice 'ok DW2 · ทางอ้อมหนึ่งชั้นถูกจับ และ guard รวมแดง';
end $$;

-- ---------- DW3 · ลึกถึง 3 ชั้น (เท่ากับ fn_policy_requires_permission) ----------
do $$
declare n int;
begin
  create or replace function sri_os.zz_dw_l3() returns bigint
  language sql stable set search_path = '' as $f$ select sri_os.zz_dw_inner() $f$;
  create or replace function sri_os.zz_dw_l2() returns bigint
  language sql stable set search_path = '' as $f$ select sri_os.zz_dw_l3() $f$;
  create or replace function sri_os.zz_dw_deep() returns bigint
  language sql stable security definer set search_path = '' as $f$ select sri_os.zz_dw_l2() $f$;
  grant execute on function sri_os.zz_dw_deep() to authenticated;
  select count(*) into n from sri_os.fn_column_exposure_row_escapes()
   where function_name = 'zz_dw_deep' and table_name = 'transaction_lines';
  if n <> 1 then
    raise exception 'FAIL: DW3 ห่วงโซ่สามชั้นไม่ถูกจับ (% แถว)', n;
  end if;
  drop function sri_os.zz_dw_deep();
  drop function sri_os.zz_dw_l2();
  drop function sri_os.zz_dw_l3();
  raise notice 'ok DW3 · ไล่ callee ได้ลึกถึง 3 ชั้น';
end $$;

-- ---------- DW4 · ชื่อที่อยู่ใน **คอมเมนต์** ไม่ใช่การเรียกใช้ ----------
-- ด่านที่ร้องของปลอมคือด่านที่คนจะปิดทิ้ง · ของจริงเคยเจอหนึ่งตัว
-- (fn_contract_gate_fields ถูกนับว่าแตะ contracts เพราะคอมเมนต์เอ่ยชื่อ fn_contract_gate_missing)
do $$
declare n int;
begin
  create or replace function sri_os.zz_dw_comment_only() returns bigint
  language sql stable security definer set search_path = '' as $f$
    -- ฟังก์ชันนี้ไม่ได้อ่าน sri_os.transactions และไม่ได้เรียก zz_dw_inner()
    /* และไม่ได้อ่าน transaction_lines ด้วย */
    select 0::bigint
  $f$;
  grant execute on function sri_os.zz_dw_comment_only() to authenticated;
  select count(*) into n from sri_os.fn_column_exposure_row_escapes()
   where function_name = 'zz_dw_comment_only';
  if n <> 0 then
    raise exception 'FAIL: DW4 ด่านนับชื่อที่อยู่ในคอมเมนต์เป็นการเรียกใช้ (% แถว) → รายงานของปลอม', n;
  end if;
  drop function sri_os.zz_dw_comment_only();
  raise notice 'ok DW4 · ชื่อในคอมเมนต์ไม่ถูกนับเป็นการเรียกใช้';
end $$;

-- ---------- DW5 · ข้อยกเว้น (ก) ยังทำงานกับทางอ้อม และยังเข้มเท่าเดิม ----------
do $$
declare n int;
begin
  -- ถามสิทธิ์ที่ **ครอบ** ledger.read (settings.manage วันนี้มีแต่ระดับที่มี ledger.read)
  create or replace function sri_os.zz_dw_outer() returns bigint
  language sql stable security definer set search_path = '' as $f$
    select case when sri_os.fn_can('settings.manage') then sri_os.zz_dw_inner() else 0 end
  $f$;
  select count(*) into n from sri_os.fn_column_exposure_row_escapes()
   where function_name = 'zz_dw_outer';
  if n <> 0 then
    raise exception 'FAIL: DW5 ทางอ้อมที่ถามสิทธิ์ซึ่งครอบสิทธิ์ขั้นต่ำ ยังถูกรายงาน (% แถว)', n;
  end if;
  perform sri_os.fn_column_exposure_guard();

  -- ถามสิทธิ์ที่ Staff ก็มี (txn.create) → ไม่ครอบ → ต้องกลับมาแดง
  create or replace function sri_os.zz_dw_outer() returns bigint
  language sql stable security definer set search_path = '' as $f$
    select case when sri_os.fn_can('txn.create') then sri_os.zz_dw_inner() else 0 end
  $f$;
  select count(*) into n from sri_os.fn_column_exposure_row_escapes()
   where function_name = 'zz_dw_outer';
  if n <> 1 then
    raise exception 'FAIL: DW5b ทางอ้อมที่ถามสิทธิ์ซึ่งไม่ครอบ ledger.read ไม่ถูกรายงาน (% แถว)', n;
  end if;

  -- fn_can ที่ถูก comment ทิ้ง = ไม่ได้ถามสิทธิ์ (ต้องยังแดง)
  create or replace function sri_os.zz_dw_outer() returns bigint
  language sql stable security definer set search_path = '' as $f$
    -- select case when sri_os.fn_can('settings.manage') then 1 else 0 end
    select sri_os.zz_dw_inner()
  $f$;
  select count(*) into n from sri_os.fn_column_exposure_row_escapes()
   where function_name = 'zz_dw_outer';
  if n <> 1 then
    raise exception 'FAIL: DW5c fn_can ที่อยู่ในคอมเมนต์ถูกนับว่าเป็นการถามสิทธิ์ (% แถว) → ปลดด่านด้วยคอมเมนต์ได้', n;
  end if;
  raise notice 'ok DW5 · ข้อยกเว้น "ถามสิทธิ์ที่ครอบ" ใช้ได้กับทางอ้อม และคอมเมนต์ปลดด่านไม่ได้';
end $$;

-- ---------- DW6 · allow-list ปิดทางอ้อมได้ และถอนแล้วกลับมาแดง ----------
do $$
declare n int;
begin
  insert into sri_os.column_exposure_definer_reads(function_name, table_name, reason)
    values ('zz_dw_outer', 'transaction_lines',
            'แถวทดสอบว่า allow-list ครอบทางอ้อมที่ไล่ callee เจอได้ (ยาวพอให้ผ่าน check ของตาราง)');
  select count(*) into n from sri_os.fn_column_exposure_row_escapes()
   where function_name = 'zz_dw_outer';
  if n <> 0 then
    raise exception 'FAIL: DW6 ขึ้นทะเบียน allow-list แล้วทางอ้อมยังถูกรายงาน (% แถว) → ทะเบียนไม่มีผลกับทางอ้อม', n;
  end if;
  perform sri_os.fn_column_exposure_guard();

  delete from sri_os.column_exposure_definer_reads where function_name = 'zz_dw_outer';
  select count(*) into n from sri_os.fn_column_exposure_row_escapes()
   where function_name = 'zz_dw_outer';
  if n <> 1 then
    raise exception 'FAIL: DW6b ถอน allow-list แล้วทางอ้อมไม่กลับมาถูกรายงาน → allow-list กลายเป็นตรายาง';
  end if;

  drop function sri_os.zz_dw_outer();
  drop function sri_os.zz_dw_inner();
  perform sri_os.fn_column_exposure_guard();
  raise notice 'ok DW6 · allow-list ครอบทางอ้อมได้ และถอนแล้วด่านกลับมาแดง';
end $$;

-- ---------- DW7 · allow-list ของไฟล์แนบต้องสอดคล้องกับ "มี/ไม่มี storage" ----------
-- harness นี้ไม่มีสคีมา storage → 20261008000009 ไม่ได้รัน → ฟังก์ชันไฟล์แนบไม่มีจริง
-- ถ้าไฟล์ migration ใส่แถวทิ้งไว้ guard ข้อ (11) stale_allowlist จะแดงทั้งระบบ
do $$
declare n int; v_has_storage boolean := to_regclass('storage.objects') is not null;
begin
  select count(*) into n from sri_os.column_exposure_definer_reads
   where function_name in ('fn_attachment_in_use', 'fn_attachment_orphans');
  if v_has_storage then
    if n <> 6 then
      raise exception 'FAIL: DW7 คลัสเตอร์นี้มี storage แต่ allow-list ของไฟล์แนบมี % แถว (ต้องเป็น 6)', n;
    end if;
  else
    if n <> 0 then
      raise exception 'FAIL: DW7 ไม่มีสคีมา storage แต่ allow-list ยังอ้าง fn_attachment_* % แถว → ยกเว้นของที่ไม่มีอยู่ (guard ข้อ 11 จะแดงทั้งระบบ)', n;
    end if;
    if exists (select 1 from sri_os.fn_column_exposure_unclassified())
       or exists (select 1 from sri_os.fn_column_exposure_breaches()) then
      raise exception 'FAIL: DW7b ด่านคอลัมน์มีของค้างในคลัสเตอร์ที่ไม่มี storage';
    end if;
    -- ด่านของไฟล์ storage ต้อง "ไม่ตรวจอะไร" อย่างเงียบและไม่พัง
    perform sri_os.fn_storage_definer_guard();
  end if;
  raise notice 'ok DW7 · allow-list ของไฟล์แนบสอดคล้องกับการมี/ไม่มีสคีมา storage (มี storage = %)', v_has_storage;
end $$;

-- ---------- DW8 · สร้างบัญชี Staff ได้ (trigger ของ D-089 ต้องไม่ปฏิเสธ) ----------
do $$
declare v_id uuid := gen_random_uuid();
begin
  insert into auth.users(id) values (v_id);
  insert into sri_os.app_users(id, email, display_name, role, is_active)
    values (v_id, 'zz_dw_staff@st.local', 'zz_dw_staff', 'staff', true);
  if not exists (select 1 from sri_os.app_users where id = v_id) then
    raise exception 'FAIL: DW8 สร้างบัญชี staff ไม่สำเร็จ';
  end if;
  raise notice 'ok DW8 · สร้างบัญชี Staff ได้ (ด่านคอลัมน์ + ด่าน storage ผ่าน)';
end $$;

-- ---------- DW9 · ใครเรียกอะไรได้ ----------
do $$
begin
  -- anon ต้องเรียกไม่ได้ทั้งสามตัว
  begin
    set local role anon;
    perform * from sri_os.fn_function_code();
    reset role;
    raise exception 'FAIL: DW9a anon เรียก fn_function_code ได้';
  exception when insufficient_privilege then reset role; end;
  begin
    set local role anon;
    perform * from sri_os.fn_column_exposure_row_escapes();
    reset role;
    raise exception 'FAIL: DW9b anon เรียก fn_column_exposure_row_escapes ได้';
  exception when insufficient_privilege then reset role; end;
  begin
    set local role anon;
    perform sri_os.fn_storage_definer_guard();
    reset role;
    raise exception 'FAIL: DW9c anon เรียก fn_storage_definer_guard ได้';
  exception when insufficient_privilege then reset role; end;

  -- ตัวที่ **เปลี่ยนสิทธิ์** ต้องไม่ให้แอปเรียกเลย
  begin
    set local role authenticated;
    perform sri_os.fn_storage_function_acl_apply();
    reset role;
    raise exception 'FAIL: DW9d authenticated เรียก fn_storage_function_acl_apply ได้ → แอป grant สิทธิ์เองได้';
  exception when insufficient_privilege then reset role; end;

  -- authenticated ต้องเรียกตัวที่ trigger ใช้ได้ (ไม่ใช่ definer → รันด้วยสิทธิ์ผู้กด)
  set local role authenticated;
  perform * from sri_os.fn_function_code();
  perform * from sri_os.fn_column_exposure_row_escapes();
  perform sri_os.fn_storage_definer_guard();
  perform sri_os.fn_column_exposure_guard();
  reset role;
  raise notice 'ok DW9 · anon เรียกไม่ได้ · ตัวที่เปลี่ยนสิทธิ์แอปเรียกไม่ได้ · ตัวที่ trigger ใช้ authenticated เรียกได้';
end $$;

-- ---------- DW10 · ความเร็ว (บทเรียน: การไล่แบบสะสมข้อความทำเทสต์ค้าง > 120 วินาที) ----------
do $$
declare t0 timestamptz := clock_timestamp(); ms numeric; i int;
begin
  for i in 1..5 loop
    perform count(*) from sri_os.fn_column_exposure_row_escapes();
  end loop;
  ms := extract(epoch from clock_timestamp() - t0) * 1000;
  if ms > 5000 then
    raise exception 'FAIL: DW10 ด่านไล่ callee ใช้ % ms ต่อ 5 รอบ → ช้าเกินจะเรียกจาก trigger ตอนสร้างผู้ใช้ (ใช้ worklist + regex รายชั้น ไม่ใช่สะสมข้อความ)', round(ms);
  end if;
  raise notice 'ok DW10 · ไล่ callee 3 ชั้น 5 รอบใน % ms', round(ms);
end $$;

do $$ begin raise notice '=== storage × ด่านคอลัมน์ (ฝั่งไม่มี storage) ผ่านทั้งหมด ==='; end $$;

rollback;
