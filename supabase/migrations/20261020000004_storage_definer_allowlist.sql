-- ============================================================
-- SRI OS · ปิดข้อขัดแย้ง "storage × ด่านคอลัมน์ (D-089)" + ทำให้คำกล่าวอ้างของด่านเป็นจริง
--   เทสต์: supabase/tests/zz_storage_definer_test.sql            (harness RLS · ไม่มี storage)
--          supabase/tests-storage/zz_storage_definer_test.sql    (harness storage)
--   รัน:   bash scripts/test-rls-local.sh · bash scripts/test-storage-local.sh
--
-- ------------------------------------------------------------
-- ปัญหาที่วัดมาแล้ว (ไม่ใช่การคาดเดา)
-- ------------------------------------------------------------
--   `20261007000007_function_execute_acl.sql` ปิด execute ทั้งสคีมา sri_os แล้วเปิดคืน
--   ตาม allow-list ของตัวเอง ซึ่ง **ไม่มี** `fn_attachment_in_use` / `fn_attachment_orphans`
--   (สองตัวนี้เกิดใน `20261008000009_storage_policies.sql` ซึ่ง **ลำดับจริงใน
--   supabase/migration-order.txt วางไว้ก่อน** เพราะ policy ของ storage เรียก fn_can())
--
--   ผลที่วัดได้ ลำดับจริง (storage มาก่อน → 007 ปิดทีหลัง):
--     `permission denied for function fn_attachment_in_use` ตอนลบไฟล์แนบ
--     (policy `attachments_delete` เรียกมันเป็นเงื่อนไข) → **ลบไฟล์ลอยไม่ได้เลย**
--   ผลที่วัดได้ ถ้าสลับลำดับให้ 007 มาก่อน (= สภาพของ scripts/test-storage-local.sh วันนี้):
--     `fn_attachment_in_use` ถือ execute ของ authenticated ไว้ → กลายเป็น **ทางอ้อมแบบ
--     definer 3 จุด** (transactions · draft_entries · contracts ที่จัดประเภทเป็น `row`)
--     → `fn_column_exposure_guard()` แดง → **trigger ปฏิเสธการสร้างบัญชี Staff**
--   แก้ข้อเดียวพังอีกข้อเสมอ จึงต้องทำคู่กันในไฟล์เดียว
--
-- ------------------------------------------------------------
-- ตัดสินอะไร
-- ------------------------------------------------------------
--   1. **คืน execute** ให้ `fn_attachment_in_use(text)` และ `fn_attachment_orphans(text)`
--      แก่ `authenticated` (ไฟล์นี้อยู่หลัง 007 ตาม migration-order.txt จึงเป็นคำสั่งสุดท้าย)
--      ทำผ่าน `fn_storage_function_acl_apply()` เพื่อให้ "ที่เดียว" ทั้งตอน migrate และตอนเทสต์
--   2. **ขึ้นทะเบียน 6 แถว** ใน `column_exposure_definer_reads`
--      (`fn_attachment_in_use` → 3 ตาราง · `fn_attachment_orphans` → 3 ตารางเดียวกัน
--       ซึ่งมันแตะ **ผ่าน** fn_attachment_in_use)
--      ทั้งคู่ **ไม่ใช่รูที่เปิดอยู่** — เหตุผลรายตัวอยู่ในคอลัมน์ reason ของแต่ละแถว
--      และ **คำกล่าวอ้างในเหตุผลถูกบังคับด้วยเครื่อง** ที่ `fn_storage_definer_guard()`
--      (เหตุผลที่ตรวจไม่ได้ = ตรายาง · ทั้งโปรเจกต์นี้ยืนอยู่บนหลักนั้น)
--   3. **ด่าน D-089 ไล่ callee ลึกขึ้นอีก 3 ชั้น** — ของเดิมอ่านชื่อตารางจาก `prosrc`
--      ของฟังก์ชันนั้นตัวเดียว → ฟังก์ชัน definer ที่แตะตาราง `row` **ผ่านฟังก์ชันอื่น**
--      หลุดด่านทั้งหมด (พิสูจน์แล้ว: `fn_attachment_orphans` → `fn_attachment_in_use`
--      → transactions ไม่ถูกจับเลยในรุ่นก่อนไฟล์นี้) = คำกล่าวอ้างของ D-089 ที่ว่า
--      "ทางอ้อมที่ไม่ขึ้นทะเบียน = ด่านพัง" **ยังไม่จริง** ไฟล์นี้ทำให้จริง
--
-- ------------------------------------------------------------
-- การไล่ลึก: ทำแบบเดียวกับ fn_policy_requires_permission (worklist · ไม่สะสมข้อความ)
-- ------------------------------------------------------------
--   บทเรียนเดิม (20261020000002 ข้อ 3.5): การต่อเนื้อฟังก์ชันเป็นก้อนข้อความเดียว
--   แล้ววนหาในก้อนที่โตขึ้นทุกรอบ ทำให้การตรวจโตแบบทวีคูณจนเทสต์ค้าง > 120 วินาที
--   ไฟล์นี้จึงไล่เป็น **รายชื่อฟังก์ชัน (worklist) ต่อหนึ่งตาราง** และยิง regex
--   **ครั้งเดียวต่อชั้น** ด้วยรูปแบบ alternation `\m(ชื่อ1|ชื่อ2|...)\M`
--   วัดเอง (DB ทดสอบชุดเดียวกัน · 8 ตาราง `row` · 57 ฟังก์ชัน definer):
--     ของเดิม (prosrc ชั้นเดียว)                 ~225 ms
--     ไล่ลึก 3 ชั้นแบบ recursive CTE ไร้เดียงสา  ~2,900 ms   ← ไม่เอา
--     ไล่ลึก 3 ชั้นแบบ worklist + alternation      ~37 ms     ← ที่ใช้
--   (เร็วกว่าของเดิมเพราะไม่ยิง regex รายฟังก์ชัน × รายตาราง อีกต่อไป)
--
--   **ตัดคอมเมนต์ออกก่อนไล่** (`fn_function_code()`): ชื่อที่ถูกเอ่ยในคอมเมนต์ไม่ใช่
--   การเรียกใช้จริง · ลองแล้วถ้าไม่ตัด จะได้ของปลอมทันทีหนึ่งตัว
--   (`fn_contract_gate_fields` ถูกนับว่าแตะ `contracts` เพราะคอมเมนต์ในตัวมัน
--    เอ่ยชื่อ `fn_contract_gate_missing`) → ด่านที่ร้องของปลอมคือด่านที่คนจะปิดทิ้ง
--   ข้อยกเว้น (ก) `fn_can('P')` ก็อ่านจากโค้ดที่ตัดคอมเมนต์แล้วเช่นกัน → fn_can
--   ที่ถูก comment ทิ้งไว้ไม่นับเป็นการถามสิทธิ์อีกต่อไป (เข้มขึ้น ไม่ใช่หลวมลง)
--
--   ข้อจำกัดที่รู้และยอม: ไล่จาก **ข้อความในโค้ด** (prosrc) ไม่ใช่ plan จริง
--   → ลึกเกิน 3 ชั้นยังหลุด · SQL ที่ประกอบด้วย format()/EXECUTE แบบต่อสตริง
--     ที่ชื่อตารางไม่ปรากฏตรงๆ ยังหลุด · ทั้งสองข้อเหมือนด่านเดิมทุกข้อในชุดนี้
--     และเป็นเหตุผลที่ allow-list ต้องมี **เหตุผลที่คนอ่านได้** ไม่ใช่พึ่งเครื่องล้วน
--
-- ------------------------------------------------------------
-- สิ่งที่ไฟล์นี้ **ไม่** ทำ (เป็นทางเลือกของลูกพี่ ไม่ใช่ของผม)
-- ------------------------------------------------------------
--   · ไม่ถอน policy `attachments_delete` และไม่ลดเงื่อนไขของมัน
--   · ไม่ถอน execute ของ `fn_attachment_orphans` (หน้าจัดการไฟล์ลอยจะใช้ไม่ได้)
--   · ไม่ลดเงื่อนไขในตัว `fn_attachment_orphans` (ตรวจสิทธิ์ในตัวเองครบ 3 ชั้นอยู่แล้ว)
--   · ไม่แตะ 20261007000007 / 20261008000009 (apply แล้ว) · ไม่แตะ event trigger ของ view
--
-- ------------------------------------------------------------
-- ย้อนกลับ (rollback)
-- ------------------------------------------------------------
--   -- 1) คืนด่านรุ่นก่อน (อ่าน prosrc ชั้นเดียว): รันบล็อก 4 ของ
--   --    supabase/migrations/20261020000002_column_exposure_ledger.sql ซ้ำ
--   --    (ย้อนแล้ว: ฟังก์ชัน definer ที่แตะตาราง row ผ่านฟังก์ชันอื่น **หลุดด่านทั้งหมด**)
--   -- 2) คืน fn_column_exposure_guard() รุ่นก่อน: รันบล็อก 6 ของ
--   --    supabase/migrations/20261020000000_column_exposure.sql ซ้ำ (ไม่มี perform ตัวใหม่)
--   -- 3) delete from sri_os.column_exposure_definer_reads
--   --     where function_name in ('fn_attachment_in_use', 'fn_attachment_orphans');
--   --    (ย้อนข้อ 3 โดยไม่ย้อนข้อ 1 = guard แดงทันที → สร้างบัญชี Staff ไม่ได้)
--   -- 4) revoke all on function sri_os.fn_attachment_in_use(text)  from authenticated;
--   --    revoke all on function sri_os.fn_attachment_orphans(text) from authenticated;
--   --    (ย้อนข้อ 4 = ลบไฟล์แนบไม่ได้เลย ทั้ง bucket · นี่คืออาการที่ไฟล์นี้มาแก้)
--   -- 5) drop function if exists sri_os.fn_storage_definer_guard();
--   --    drop function if exists sri_os.fn_storage_function_acl_apply();
--   --    drop function if exists sri_os.fn_function_code();   -- ข้อ 1 ต้องย้อนก่อน
--
-- idempotent: create or replace · insert ... on conflict do update · revoke/grant ซ้ำได้
--   รันซ้ำสองรอบติดกันได้ (harness storage รันซ้ำให้อยู่แล้ว)
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 0 · ของที่ต้องมีก่อน — รันสลับลำดับต้องพังให้เห็น ไม่ใช่เดา
-- ============================================================
do $$
begin
  if to_regclass('sri_os.column_exposure') is null
     or to_regclass('sri_os.column_exposure_definer_reads') is null then
    raise exception 'ไม่มีทะเบียนด่านคอลัมน์/allow-list → ต้องรัน 20261020000000 และ 20261020000002 ก่อนไฟล์นี้ (ดู supabase/migration-order.txt)';
  end if;
  if to_regprocedure('sri_os.fn_column_exposure_row_escapes()') is null
     or to_regprocedure('sri_os.fn_column_exposure_guard()') is null then
    raise exception 'ไม่มี fn_column_exposure_row_escapes()/fn_column_exposure_guard() → ไฟล์นี้เขียนทับสองตัวนั้น ต้องมีของเดิมอยู่ก่อน';
  end if;
end $$;

-- ============================================================
-- 1 · เนื้อโค้ดของฟังก์ชันโดย **ตัดคอมเมนต์ออก** — ที่เดียวที่นิยาม "โค้ดจริง"
--     ใช้ทั้งการไล่ callee และการตรวจคำกล่าวอ้าง (กฎเดียวห้ามเขียนสองที่)
--     รวมทุก overload ของชื่อเดียวกันเป็นก้อนเดียว เพราะการไล่ทำที่ระดับ "ชื่อ"
--     (ลายเซ็นในข้อความโค้ดไม่ได้บอกว่าเรียก overload ไหน → เลือกทางเข้มกว่า)
-- ============================================================
create or replace function fn_function_code()
returns table (function_name text, code text)
language sql stable set search_path = '' as $fn$
  select p.proname::text,
         string_agg(
           regexp_replace(
             regexp_replace(p.prosrc, '/\*.*?\*/', ' ', 'gs'),   -- คอมเมนต์คร่อม
             '--[^' || chr(10) || ']*', ' ', 'g'),               -- คอมเมนต์ท้ายบรรทัด
           ' ')
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.prokind = 'f'
   group by p.proname
$fn$;
comment on function fn_function_code() is
  'D-089 · เนื้อโค้ดของฟังก์ชันใน sri_os แบบตัดคอมเมนต์ออก (ชื่อที่เอ่ยในคอมเมนต์ไม่ใช่การเรียกใช้จริง) · ใช้ไล่ callee และตรวจคำกล่าวอ้างของ allow-list · prosrc อ่านได้โดย PUBLIC ตามปกติของ Postgres อยู่แล้ว ฟังก์ชันนี้จึงไม่เปิดอะไรใหม่';
revoke all on function fn_function_code() from public;
do $$ begin
  execute 'revoke all on function sri_os.fn_function_code() from anon';
  -- trigger ตอนสร้างบัญชี Staff ไม่ใช่ definer → ผู้กดเพิ่มผู้ใช้ (authenticated) ต้องเรียกได้
  execute 'grant execute on function sri_os.fn_function_code() to authenticated';
exception when undefined_object then
  raise notice 'ไม่มี role anon/authenticated ในคลัสเตอร์นี้ — ข้าม revoke/grant';
end $$;

-- ============================================================
-- 2 · ด่านทางอ้อมแบบ definer · รุ่นไล่ callee ลึก 3 ชั้น
--     เงื่อนไขทุกข้อ **เท่าเดิม** (เจ้าของที่ RLS ไม่บังคับ · ผู้ใช้แอปเรียกได้ ·
--     ข้อยกเว้น (ก) ถามสิทธิ์ที่ครอบ · ข้อยกเว้น (ข) allow-list)
--     ที่เพิ่มคือ "แตะตาราง" ไม่ได้หมายถึงแตะตรงๆ อย่างเดียวอีกแล้ว
-- ============================================================
create or replace function fn_column_exposure_row_escapes()
returns table (function_name text, table_name text, problem text)
language plpgsql stable set search_path = '' as $fn$
declare
  c_depth constant int := 3;   -- ชั้นของ callee ที่ไล่ · เท่ากับ fn_policy_requires_permission
  v_names  text[];             -- ชื่อฟังก์ชันทั้งหมดใน sri_os
  v_code   text[];             -- โค้ด (ตัดคอมเมนต์) เรียงคู่กับ v_names
  r_tab    record;
  v_direct text[];             -- แตะตารางนี้ตรงๆ
  v_all    text[];             -- แตะตารางนี้ ตรงๆ หรือผ่าน callee ไม่เกิน c_depth ชั้น
  v_front  text[];
  v_next   text[];
  i        int;
begin
  select array_agg(c.function_name order by c.function_name),
         array_agg(c.code          order by c.function_name)
    into v_names, v_code
    from sri_os.fn_function_code() c;

  for r_tab in
    select ce.table_name, min(ce.min_permission) as min_permission
      from sri_os.column_exposure ce
     where ce.exposure = 'row'
     group by ce.table_name
  loop
    -- ชั้น 0 · ฟังก์ชันที่เอ่ยชื่อตารางนี้ในโค้ดของตัวเอง
    select coalesce(array_agg(u.n), '{}') into v_direct
      from unnest(v_names, v_code) as u(n, s)
     where u.s ~ ('\m' || r_tab.table_name || '\M');
    v_all := v_direct;
    v_front := v_direct;

    -- ชั้น 1..c_depth · ใครเรียกของชั้นก่อนหน้า (regex ครั้งเดียวต่อชั้น)
    for i in 1..c_depth loop
      exit when coalesce(cardinality(v_front), 0) = 0;
      select coalesce(array_agg(u.n), '{}') into v_next
        from unnest(v_names, v_code) as u(n, s)
       where not (u.n = any (v_all))
         and u.s ~ ('\m(' || array_to_string(v_front, '|') || ')\M');
      v_all := v_all || v_next;
      v_front := v_next;
    end loop;

    return query
    select p.proname::text, r_tab.table_name,
           'ฟังก์ชัน security definer ที่เจ้าของไม่ถูก RLS บังคับ (' ||
           pg_get_userbyid(p.proowner) || ') อ่านตารางที่จัดประเภทเป็น row ' ||
           case when p.proname::text = any (v_direct) then 'ตรงๆ'
                else 'ผ่านฟังก์ชันอื่นอีกชั้น (ไล่ callee ' || c_depth || ' ชั้น)' end ||
           ' และ ' ||
           case when has_function_privilege('public', p.oid, 'execute') then 'PUBLIC' else 'authenticated' end ||
           ' เรียกได้ โดยไม่ถามสิทธิ์ที่ครอบ ' || r_tab.min_permission ||
           ' และไม่อยู่ใน allow-list → ข้าม policy ของตารางทั้งใบ'
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'sri_os' and p.prosecdef and p.prokind = 'f'
       and p.proname::text = any (v_all)
       and (has_function_privilege('authenticated', p.oid, 'execute')
            or has_function_privilege('public', p.oid, 'execute'))
       -- เจ้าของที่ RLS ไม่บังคับ: เจ้าของตารางนั้นเอง · superuser · bypassrls
       and (p.proowner = (select c.relowner from pg_class c
                           where c.oid = ('sri_os.' || quote_ident(r_tab.table_name))::regclass)
            or exists (select 1 from pg_roles r
                        where r.oid = p.proowner and (r.rolsuper or r.rolbypassrls)))
       -- (ก) ถามสิทธิ์เองด้วยคีย์ที่ "ครอบ" สิทธิ์ขั้นต่ำของตาราง (อ่านจากตารางสิทธิ์จริง)
       and not exists (
         select 1 from sri_os.permissions perm
          join unnest(v_names, v_code) as u(n, s) on u.n = p.proname::text
          where u.s ~ ('fn_can\(''' || perm.key || '''\)')
            and exists (select 1 from sri_os.role_permissions rp
                         where rp.permission_key = perm.key)
            and not exists (
              select 1 from sri_os.role_permissions rp
               where rp.permission_key = perm.key
                 and not exists (select 1 from sri_os.role_permissions r2
                                  where r2.role_key = rp.role_key
                                    and r2.permission_key = r_tab.min_permission)))
       -- (ข) allow-list พร้อมเหตุผล
       and not exists (
         select 1 from sri_os.column_exposure_definer_reads al
          where al.function_name = p.proname::text
            and al.table_name = r_tab.table_name);
  end loop;
end $fn$;
comment on function fn_column_exposure_row_escapes() is
  'D-089 · คืนรายการ "ทางอ้อมที่ทำให้เหตุผลของการจัดประเภทแบบ row ตาย" = ฟังก์ชัน definer ที่ข้าม RLS อ่านตารางนั้น **ตรงๆ หรือผ่าน callee ไม่เกิน 3 ชั้น** และผู้ใช้แอปเรียกได้ โดยไม่ถามสิทธิ์ที่ครอบและไม่อยู่ใน allow-list · รุ่น 20261020000004 ตัดคอมเมนต์ออกก่อนไล่ (ชื่อในคอมเมนต์ไม่ใช่การเรียกใช้) · ว่าง = ไม่มีทางอ้อมที่ไม่ได้ตัดสิน';
revoke all on function fn_column_exposure_row_escapes() from public;
do $$ begin
  execute 'revoke all on function sri_os.fn_column_exposure_row_escapes() from anon';
  execute 'grant execute on function sri_os.fn_column_exposure_row_escapes() to authenticated';
exception when undefined_object then
  raise notice 'ไม่มี role anon/authenticated ในคลัสเตอร์นี้ — ข้าม revoke/grant';
end $$;

-- ============================================================
-- 3 · คืน execute ให้สองฟังก์ชันของ storage · ที่เดียว (migration + เทสต์เรียกตัวนี้)
--     ทำไมต้องเป็นฟังก์ชัน ไม่ใช่ grant ลอยในไฟล์: เทสต์ต้องจำลอง "ลำดับจริง"
--     (007 ปิดทีหลัง) แล้วพิสูจน์ว่าไฟล์นี้เปิดคืนได้จริง · ถ้าเทสต์เขียน grant เอง
--     มันจะทดสอบ grant ของตัวเอง ไม่ใช่ของ migration (กฎเดียวห้ามเขียนสองที่)
-- ============================================================
create or replace function fn_storage_function_acl_apply() returns void
language plpgsql set search_path = '' as $fn$
declare
  -- ฟังก์ชันที่ policy/หน้าจัดการไฟล์ของ bucket attachments ต้องเรียกได้
  --   fn_attachment_in_use  → policy attachments_delete เรียกเป็นเงื่อนไข
  --   fn_attachment_orphans → หน้าจัดการไฟล์ลอย (ตรวจสิทธิ์ในตัวเอง)
  c_allow constant text[] := array['fn_attachment_in_use(text)', 'fn_attachment_orphans(text)'];
  v text;
begin
  foreach v in array c_allow loop
    if to_regprocedure('sri_os.' || v) is null then
      raise exception 'ไม่มี sri_os.% → ต้องรัน 20261008000009_storage_policies.sql ก่อน (ลายเซ็นเปลี่ยนแล้วก็ขึ้น error นี้ · ปล่อยผ่านเงียบไม่ได้ เพราะแอปจะล้มด้วย permission denied ตอนลบไฟล์)', v;
    end if;
    -- ปิดก่อนแล้วเปิดเท่าที่ต้องใช้ (หลักเดียวกับ 20261007000007)
    execute format('revoke all on function sri_os.%s from public', v);
    begin
      execute format('revoke all on function sri_os.%s from anon', v);
    exception when undefined_object then null;
    end;
    execute format('grant execute on function sri_os.%s to authenticated', v);
  end loop;
end $fn$;
comment on function fn_storage_function_acl_apply() is
  'คืน execute ของ fn_attachment_in_use/fn_attachment_orphans ให้ authenticated (ปิด public/anon) · ต้องรันหลัง 20261007000007 ที่ปิด execute ทั้งสคีมา · ไม่ใช่ฟังก์ชันที่แอปเรียก (เปลี่ยนสิทธิ์)';
revoke all on function fn_storage_function_acl_apply() from public;
do $$ begin
  execute 'revoke all on function sri_os.fn_storage_function_acl_apply() from anon, authenticated';
exception when undefined_object then null;
end $$;

-- ============================================================
-- 4 · ด่านของไฟล์นี้ · ทำให้ "เหตุผลใน allow-list" เป็นสิ่งที่เครื่องตรวจได้
--     ตรวจสามเรื่อง:
--       (1) ฟังก์ชันของ sri_os ที่ policy ของ storage.objects เรียก → authenticated
--           ต้อง execute ได้ (ไล่จาก pg_policies จริง ไม่ใช่ลิสต์มือ → policy ใหม่ถูกตรวจด้วย)
--       (2) สองฟังก์ชันของ storage ต้องไม่เปิดให้ public/anon
--       (3) คำกล่าวอ้างในเหตุผลของ allow-list ยังจริง:
--           · fn_attachment_in_use  คืน boolean · รับ path ตรงตัวหนึ่งค่า · อ่านอย่างเดียว
--           · fn_attachment_orphans ตรวจสิทธิ์ในตัวเองครบสามชั้น
--     ไม่มีสคีมา storage (harness RLS) = ไม่มีอะไรให้ตรวจ → คืนเฉยๆ
-- ============================================================
create or replace function fn_storage_definer_guard() returns void
language plpgsql stable set search_path = '' as $fn$
declare
  v    text;
  v_code text;
  v_oid oid;
begin
  if to_regclass('storage.objects') is null then
    return;   -- คลัสเตอร์ที่ไม่มี Supabase Storage (เช่น scripts/test-rls-local.sh)
  end if;

  -- (1) policy ของ storage เรียกฟังก์ชันไหน ตัวนั้นต้องเรียกได้จริง
  select string_agg(distinct p.proname, ', ') into v
    from pg_policies pol
    cross join pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where pol.schemaname = 'storage' and pol.tablename = 'objects'
     and ns.nspname = 'sri_os'
     and (coalesce(pol.qual, '') || ' ' || coalesce(pol.with_check, ''))
         ~ ('\msri_os\.' || p.proname || '\M')
     and not has_function_privilege('authenticated', p.oid, 'execute');
  if v is not null then
    raise exception 'policy ของ storage.objects เรียกฟังก์ชันที่ authenticated ไม่มีสิทธิ์ execute: % · policy จะล้มด้วย permission denied (ของจริงที่วัดได้: ลบไฟล์แนบไม่ได้ทั้ง bucket) · คืนด้วย select sri_os.fn_storage_function_acl_apply()', v
      using hint = '20261007000007 ปิด execute ทั้งสคีมาแล้วเปิดคืนตาม allow-list ของมัน · ฟังก์ชันที่เกิดใน migration ที่ลำดับอยู่ก่อนมัน ต้องถูก grant คืนในไฟล์ที่อยู่หลัง (ไฟล์นี้)';
  end if;

  -- (2) ห้ามเปิดให้ public/anon
  select string_agg(p.proname, ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.proname in ('fn_attachment_in_use', 'fn_attachment_orphans')
     and (has_function_privilege('public', p.oid, 'execute')
          or (exists (select 1 from pg_roles where rolname = 'anon')
              and has_function_privilege('anon', p.oid, 'execute')));
  if v is not null then
    raise exception 'ฟังก์ชันไฟล์แนบเปิดให้ public/anon: % · คนที่ไม่ได้ล็อกอินต้องเรียกไม่ได้', v;
  end if;

  -- (3ก) คำกล่าวอ้างของ fn_attachment_in_use ที่ทำให้ allow-list ยอมได้
  v_oid := to_regprocedure('sri_os.fn_attachment_in_use(text)');
  if v_oid is not null then
    select case
      when (select p.prorettype from pg_proc p where p.oid = v_oid) <> 'boolean'::regtype
        then 'ไม่ได้คืน boolean แล้ว → allow-list ยอมมันเพราะ "คืนแค่มี/ไม่มี" ถ้าคืนข้อมูลของแถวได้ เหตุผลนั้นตาย'
      when (select p.provolatile from pg_proc p where p.oid = v_oid) <> 's'
        then 'ไม่ใช่ stable แล้ว → ทางข้าม RLS ที่เขียนข้อมูลได้ ไม่ใช่ของที่ allow-list ยอม'
      when not (select p.prosecdef from pg_proc p where p.oid = v_oid)
        then 'ไม่ใช่ security definer แล้ว → รายการที่ผู้เรียกมองไม่เห็นจะถูกนับว่า "ไม่มีใครอ้าง" แล้วลบไฟล์หลักฐานได้ (20261008000009 ข้อ 4)'
      else null end into v;
    if v is null then
      select c.code into v_code from sri_os.fn_function_code() c
       where c.function_name = 'fn_attachment_in_use';
      if v_code ~* '\m(insert|update|delete|merge|truncate|alter|drop|grant|revoke)\M' then
        v := 'เนื้อฟังก์ชันมีคำสั่งเขียน → ตัวที่ allow-list ยอมคือตัวอ่านอย่างเดียว';
      end if;
    end if;
    if v is not null then
      raise exception 'fn_attachment_in_use ไม่ตรงกับเหตุผลที่ขึ้นทะเบียนไว้ใน column_exposure_definer_reads: % · แก้ฟังก์ชันหรือทบทวน allow-list พร้อมกัน ไม่ใช่ทีละข้าง', v;
    end if;
  end if;

  -- (3ข) คำกล่าวอ้างของ fn_attachment_orphans: "ตรวจสิทธิ์ในตัวเอง" ต้องยังจริง
  --       ทั้งสามข้อนี้คือสิ่งที่ทำให้มัน **ไม่ใช่รู** แม้ authenticated เรียกได้
  select c.code into v_code from sri_os.fn_function_code() c
   where c.function_name = 'fn_attachment_orphans';
  if v_code is not null then
    if v_code !~ 'auth\.uid\(\)\s+is\s+null' then
      raise exception 'fn_attachment_orphans ไม่ปฏิเสธผู้ที่ไม่ได้ล็อกอินแล้ว (ไม่เจอการตรวจ auth.uid() is null) · ฟังก์ชันนี้เป็น definer ที่ข้าม RLS → ไม่ตรวจ = คนไม่มีตัวตนอ่าน path ของทุกคนได้';
    end if;
    if v_code !~ 'fn_can\(''settings\.manage''\)' then
      raise exception 'fn_attachment_orphans ไม่บังคับ settings.manage สำหรับ scope all แล้ว · นี่คือเงื่อนไขที่ allow-list ยอมมันไว้ → ถอนแล้วทุกคนที่ล็อกอินเห็น path ของทุกผู้ถือ';
    end if;
    if v_code !~ '\[2\].{0,80}auth\.uid\(\)' then
      raise exception 'fn_attachment_orphans ไม่จำกัด scope mine ไว้ที่โฟลเดอร์ของ auth.uid() แล้ว · เงื่อนไขนี้คือเหตุผลที่ scope mine ไม่ต้องมีสิทธิ์พิเศษ';
    end if;
    if v_code !~ 'fn_can_see_owner' then
      raise exception 'fn_attachment_orphans ไม่กรองด้วย fn_can_see_owner อีกชั้นแล้ว · settings.manage ไม่ได้แปลว่าเห็นทุกผู้ถือ (ขอบเขตผู้ถือเป็นอีกมิติ)';
    end if;
  end if;
end $fn$;
comment on function fn_storage_definer_guard() is
  'ด่านของ 20261020000004 · (1) ฟังก์ชันที่ policy ของ storage.objects เรียกต้อง execute ได้ด้วย authenticated (ไม่งั้นลบไฟล์แนบไม่ได้) (2) ห้ามเปิดให้ public/anon (3) คำกล่าวอ้างในเหตุผลของ allow-list ยังจริง (in_use คืน boolean อ่านอย่างเดียว · orphans ตรวจสิทธิ์ในตัวเองครบ) · ไม่มีสคีมา storage = ไม่ตรวจ';
revoke all on function fn_storage_definer_guard() from public;
do $$ begin
  execute 'revoke all on function sri_os.fn_storage_definer_guard() from anon';
  -- เรียกจาก fn_column_exposure_guard() ซึ่ง trigger ตอนสร้างบัญชี Staff เรียกด้วยสิทธิ์ผู้กด
  execute 'grant execute on function sri_os.fn_storage_definer_guard() to authenticated';
exception when undefined_object then
  raise notice 'ไม่มี role anon/authenticated ในคลัสเตอร์นี้ — ข้าม revoke/grant';
end $$;

-- ============================================================
-- 5 · allow-list · 6 แถว พร้อมเหตุผลที่คนอ่านทีหลังเข้าใจ
--     เงื่อนไข: ขึ้นทะเบียนเมื่อคลัสเตอร์นี้ **มี Supabase Storage**
--       · มี storage แต่ยังไม่ได้รัน 20261008000009 (เกิดได้เฉพาะใน
--         scripts/test-storage-local.sh ที่รันไฟล์ storage ท้ายสุด) → แถวขึ้นก่อน
--         ฟังก์ชันเกิดเล็กน้อย แล้วครบทันทีที่ไฟล์นั้นรัน
--       · ไม่มี storage เลย (scripts/test-rls-local.sh) → **ลบแถวออก** ไม่ปล่อยค้าง
--         เพราะ guard ข้อ (11) ของ 20261020000002 แดงถ้า allow-list อ้างฟังก์ชันที่ไม่มีจริง
--         (ยกเว้นของที่ไม่มีอยู่ = ของจริงหลุด)
-- ============================================================
do $$
declare n int;
begin
  if to_regclass('storage.objects') is null then
    delete from sri_os.column_exposure_definer_reads
     where function_name in ('fn_attachment_in_use', 'fn_attachment_orphans');
    raise notice 'คลัสเตอร์นี้ไม่มีสคีมา storage → ไม่ขึ้นทะเบียน allow-list ของไฟล์แนบ (และลบของค้างออก %  แถว)', (select count(*) from sri_os.column_exposure_definer_reads);
    return;
  end if;

  insert into sri_os.column_exposure_definer_reads (function_name, table_name, reason) values
    ('fn_attachment_in_use', 'transactions',
     'คืนแค่ boolean ว่า "path นี้มีแถวอ้างถึงไหม" ไม่คืนตัวเลข/ข้อความของแถว · รับ path ตรงตัว (ไม่มี pattern/like) ซึ่งเป็น uuid สองชั้นที่สุ่มฝั่ง server → ถามเพื่อสืบของคนอื่นไม่ได้ · ต้องเป็น definer เพราะถ้าถามใต้ RLS ของผู้เรียก รายการที่ตัวเองมองไม่เห็นจะถูกนับว่า "ไม่มีใครอ้าง" แล้วลบไฟล์หลักฐานของคนอื่นได้ (20261008000009 ข้อ 4) · ถอน execute ไม่ได้เพราะ policy attachments_delete เรียกมันเป็นเงื่อนไข → ลบไฟล์ลอยไม่ได้ทั้ง bucket · คำกล่าวอ้างทั้งหมดนี้บังคับด้วย sri_os.fn_storage_definer_guard()'),
    ('fn_attachment_in_use', 'draft_entries',
     'เหตุผลเดียวกับแถว transactions ของฟังก์ชันนี้: คืนแค่ boolean ต่อ path ที่ถามมาตรงตัว · ร่างที่ยังไม่ส่งก็ต้องนับเป็น "มีคนอ้าง" ไม่งั้นลบไฟล์ที่ร่างของคนอื่นอ้างอยู่ได้ · ถอน execute = policy attachments_delete ล้ม'),
    ('fn_attachment_in_use', 'contracts',
     'เหตุผลเดียวกับแถว transactions ของฟังก์ชันนี้ · contracts.file_urls อยู่ในฝั่ง "ห้ามลบ" เพื่อกันลบ ไม่ใช่เปิดอ่าน (policy อ่านไฟล์ยังไม่ผูกกับสัญญา) · คืน boolean ต่อ path ที่ถามตรงตัวเท่านั้น'),
    ('fn_attachment_orphans', 'transactions',
     'แตะตารางนี้ **ผ่าน** fn_attachment_in_use (ไล่ callee เจอที่ชั้น 1) ไม่ได้อ่านเอง · ตัวมันตรวจสิทธิ์ในตัวเองครบ: ปฏิเสธเมื่อ auth.uid() เป็น null · scope all ต้องมี settings.manage **และ** ยังกรองด้วย fn_can_see_owner อีกชั้น · scope mine จำกัดที่โฟลเดอร์ของ auth.uid() เอง · คืนเฉพาะ metadata (path/ขนาด/อายุ) ไม่ได้คืนเนื้อไฟล์และไม่ได้คืนข้อมูลของ transactions · ขึ้นทะเบียนไว้เพื่อให้ "ทางอ้อม" ตัวนี้ถูกตัดสินอย่างชัดเจน และเงื่อนไขทั้งสี่ข้อถูกบังคับด้วย sri_os.fn_storage_definer_guard() → ถอนเงื่อนไขในตัวมันออกเมื่อไร ด่านแดงทันที'),
    ('fn_attachment_orphans', 'draft_entries',
     'เหตุผลเดียวกับแถว transactions ของฟังก์ชันนี้: แตะผ่าน fn_attachment_in_use ชั้นเดียว · ตรวจสิทธิ์ในตัวเองครบสี่ข้อซึ่ง fn_storage_definer_guard() บังคับไว้ · คืนเฉพาะ metadata ของไฟล์ ไม่ใช่เนื้อร่าง'),
    ('fn_attachment_orphans', 'contracts',
     'เหตุผลเดียวกับแถว transactions ของฟังก์ชันนี้: แตะผ่าน fn_attachment_in_use ชั้นเดียว · ตรวจสิทธิ์ในตัวเองครบสี่ข้อซึ่ง fn_storage_definer_guard() บังคับไว้ · คืนเฉพาะ metadata ของไฟล์ ไม่ใช่เนื้อสัญญา')
  on conflict (function_name, table_name) do update set reason = excluded.reason;

  select count(*) into n from sri_os.column_exposure_definer_reads
   where function_name in ('fn_attachment_in_use', 'fn_attachment_orphans');
  if n <> 6 then
    raise exception 'allow-list ของไฟล์แนบต้องมี 6 แถว (พบ %)', n;
  end if;
end $$;

-- ============================================================
-- 6 · ต่อด่านใหม่เข้า fn_column_exposure_guard()
--     เนื้อเดิมของ 20261020000000 บล็อก 6 ครบทุกบรรทัด + perform ตัวใหม่ท้ายสุด
--     ทำไมต้องต่อที่นี่: guard ตัวนี้คือสิ่งที่ trigger ตอนสร้างบัญชี Staff เรียก
--     → ถ้าวันหนึ่งมีใครถอด grant หรือถอดเงื่อนไขในตัว fn_attachment_orphans
--     **การสร้างบัญชีจะพังให้เห็น** ไม่ใช่รู้ตอนผู้ใช้ลบไฟล์ไม่ได้
-- ============================================================
create or replace function fn_column_exposure_guard() returns void
language plpgsql stable set search_path = '' as $fn$
declare v text; n int;
begin
  select string_agg(object_kind || ' ' || object_name || ' — ' || problem, E'\n  '), count(*)
    into v, n from sri_os.fn_column_exposure_unclassified();
  if n > 0 then
    raise exception 'ด่านคอลัมน์ (D-089): มี % รายการที่ยังไม่จัดประเภท →%  %',
      n, E'\n  ', v
      using hint = 'เพิ่มแถวใน sri_os.column_exposure / column_exposure_tables ด้วย migration ใหม่ (open ต้องมีเหตุผล · grant/row ต้องระบุสิทธิ์ขั้นต่ำ) แล้วเรียก sri_os.fn_apply_column_exposure()';
  end if;

  select string_agg(breach_kind || ' ' || object_name || ' — ' || problem, E'\n  '), count(*)
    into v, n from sri_os.fn_column_exposure_breaches();
  if n > 0 then
    raise exception 'ด่านคอลัมน์ (D-089): ด่าน % จุดไม่ติดจริง →%  %',
      n, E'\n  ', v
      using hint = 'รัน sri_os.fn_apply_column_exposure() ใหม่ (ต้องเป็น role ที่เป็นเจ้าของตาราง) หรือกู้สิ่งที่ถูกถอดออกด้วย migration ใหม่';
  end if;

  -- กัน guard กลายเป็น guard เปล่า: ถ้าทะเบียนว่างหรือตื้นเกิน สองข้อบนจะผ่านฟรีๆ
  select count(*) into n from sri_os.column_exposure;
  if n < 200 then
    raise exception 'ด่านคอลัมน์: ทะเบียนมีแค่ % แถว — น้อยกว่าจำนวนคอลัมน์ที่ sri_os มีจริง แปลว่า guard นี้อาจไม่ได้ตรวจอะไรเลย', n;
  end if;
  select count(*) into n from sri_os.column_exposure where exposure = 'grant';
  if n < 15 then
    raise exception 'ด่านคอลัมน์: มีคอลัมน์ที่ปิดด้วย GRANT แค่ % คอลัมน์ — ชุดที่ D-089 ระบุหายไป ต้องตรวจว่าใครถอดออก', n;
  end if;

  -- ใหม่ (20261020000004) · ทางข้ามของ storage: ACL ของฟังก์ชันที่ policy เรียก
  -- + คำกล่าวอ้างในเหตุผลของ allow-list ยังจริง (ไม่มีสคีมา storage = ไม่ตรวจ)
  perform sri_os.fn_storage_definer_guard();
end $fn$;
comment on function fn_column_exposure_guard() is
  'D-089 · พังทันทีเมื่อมีตาราง/คอลัมน์ใหม่ที่ยังไม่จัดประเภท หรือด่านคอลัมน์ไม่ติดจริง · รุ่น 20261020000004 เรียก fn_storage_definer_guard() ต่อท้ายด้วย (ACL ของฟังก์ชันที่ policy ของ storage เรียก + คำกล่าวอ้างของ allow-list) · เรียกจากท้าย migration · เทสต์ · และ trigger ตอนสร้างบัญชีระดับที่อ่าน ledger ไม่ได้';
revoke all on function fn_column_exposure_guard() from public;
do $$ begin
  execute 'revoke all on function sri_os.fn_column_exposure_guard() from anon';
  execute 'grant execute on function sri_os.fn_column_exposure_guard() to authenticated';
exception when undefined_object then
  raise notice 'ไม่มี role anon/authenticated ในคลัสเตอร์นี้ — ข้าม revoke/grant';
end $$;

-- ============================================================
-- 7 · guard ท้ายไฟล์ — ไม่ผ่าน = migration ล้ม ไม่ใช่เงียบ
-- ============================================================
do $$
declare n int; v text;
begin
  -- (ก) ด่านใหม่ต้องไม่เป็นด่านเปล่า: ต้องจับ "definer ที่แตะตาราง row ผ่านฟังก์ชันอื่น"
  --     ได้จริง · ทดลองของปลอมแล้วลบในบล็อกเดียว (ไม่ทิ้งอะไรไว้)
  create or replace function sri_os.zz_dw_probe_inner() returns bigint
    language sql stable set search_path = '' as 'select count(*) from sri_os.transactions';
  create or replace function sri_os.zz_dw_probe_outer() returns bigint
    language sql stable security definer set search_path = ''
    as 'select sri_os.zz_dw_probe_inner()';
  execute 'grant execute on function sri_os.zz_dw_probe_outer() to authenticated';
  select count(*) into n from sri_os.fn_column_exposure_row_escapes()
   where function_name = 'zz_dw_probe_outer';
  drop function sri_os.zz_dw_probe_outer();
  drop function sri_os.zz_dw_probe_inner();
  if n <> 1 then
    raise exception 'การไล่ callee ไม่ทำงาน: ฟังก์ชัน definer ที่แตะ transactions ผ่านฟังก์ชันอื่นไม่ถูกจับ (ได้ % แถว) → คำกล่าวอ้างของ D-089 ว่า "ทางอ้อมที่ไม่ขึ้นทะเบียน = ด่านพัง" ยังไม่จริง', n;
  end if;

  -- (ข) ของจริงต้องไม่เหลือทางอ้อมที่ไม่ได้ตัดสิน
  select string_agg(function_name || ' → ' || table_name, ', '), count(*) into v, n
    from sri_os.fn_column_exposure_row_escapes();
  if n > 0 then
    raise exception 'ยังมีทางอ้อมแบบ definer ที่ไม่ได้ตัดสิน % รายการ: % · ขึ้นทะเบียนพร้อมเหตุผล หรือถอน execute/เพิ่มการตรวจสิทธิ์ในตัวฟังก์ชัน', n, v;
  end if;

  -- (ค) ฝั่ง storage: คืน execute + ตรวจคำกล่าวอ้าง + ด่านรวมของ D-089
  --     ทั้งสามข้อขึ้นกับ "ฟังก์ชันของ 20261008000009 มีอยู่แล้วหรือยัง"
  --     **ลำดับจริงตาม migration-order.txt มีอยู่แล้วเสมอ** (storage อยู่เกือบต้นแฟ้ม)
  --     ที่ไม่มีคือสองกรณีของ harness เท่านั้น ซึ่งเขียนไว้ในหมายเหตุให้ดัง ไม่เงียบ
  if to_regprocedure('sri_os.fn_attachment_in_use(text)') is null then
    raise notice E'ข้ามการคืน execute และข้ามด่านรวม เพราะยังไม่มี sri_os.fn_attachment_in_use(text)\n  เกิดได้สองกรณี (ทั้งคู่เป็นเรื่องของ harness ไม่ใช่ของ project จริง):\n    1. คลัสเตอร์ไม่มีสคีมา storage → 20261008000009 ขึ้น SKIP (scripts/test-rls-local.sh)\n       กรณีนี้ allow-list ของไฟล์แนบถูกลบออกแล้วในบล็อก 5 → ไม่มีอะไรค้าง\n    2. harness รันไฟล์ storage **ท้ายสุด** (scripts/test-storage-local.sh)\n       กรณีนี้ allow-list ขึ้นทะเบียนล่วงหน้าแล้ว (เพราะมีสคีมา storage) จึง **ค้างชั่วคราว**\n       จนไฟล์นั้นรันจบ · ด่านรวมจึงยังเรียกไม่ได้ตอนนี้ และเทสต์ใน supabase/tests-storage/\n       เป็นตัวยืนยันสภาพปลายทาง (zz_storage_definer_test.sql เคส G0/G1/G6)';
  else
    perform sri_os.fn_storage_function_acl_apply();
    if not has_function_privilege('authenticated', 'sri_os.fn_attachment_in_use(text)', 'execute')
       or not has_function_privilege('authenticated', 'sri_os.fn_attachment_orphans(text)', 'execute') then
      raise exception 'คืน execute ให้ authenticated ไม่สำเร็จ → policy attachments_delete จะยังล้ม';
    end if;
    perform sri_os.fn_storage_definer_guard();
    -- (ง) ด่านรวมของ D-089 ต้องผ่าน = สร้างบัญชี Staff ได้
    perform sri_os.fn_column_exposure_guard();
  end if;

  raise notice 'storage × ด่านคอลัมน์: allow-list ไฟล์แนบ % แถว · ด่านไล่ callee 3 ชั้น (ตัดคอมเมนต์) · ทางอ้อมที่ยังไม่ตัดสิน 0 รายการ',
    (select count(*) from sri_os.column_exposure_definer_reads
      where function_name in ('fn_attachment_in_use', 'fn_attachment_orphans'));
end $$;

-- ============================================================
-- ที่ต้องบอกลูกพี่ (เจอรอบนี้ · ไม่ได้แก้เองเพราะเป็นเรื่องนอกขอบงาน)
--   1. `fn_guard_attachment_objects()` (trigger กันลบ/ย้ายไฟล์) ก็แตะสามตารางนั้น
--      ผ่าน fn_attachment_in_use เหมือนกัน แต่ **ถูก revoke หมดแล้ว** (ไม่มีใครเรียกตรงได้)
--      จึงไม่เข้าเงื่อนไขของด่านและไม่ต้องขึ้นทะเบียน · ถ้าวันหนึ่งมีใคร grant ให้
--      authenticated ด่านจะแดงเอง (ไม่ต้องมีใครจำ)
--   2. ด่านไล่จาก **ข้อความในโค้ด** ลึก 3 ชั้น → ห่วงโซ่ที่ยาวกว่านั้น หรือ SQL ที่
--      ประกอบชื่อตารางด้วยสตริงตอนรัน ยังหลุดอยู่ · ถ้าต้องการปิดจริงต้องเปลี่ยนไป
--      ไล่จาก pg_depend/การ parse แทน ซึ่งเป็นงานแยก (และ Postgres ไม่เก็บ dependency
--      ของตารางที่ฟังก์ชันอ้างใน body อยู่แล้ว)
-- ============================================================
