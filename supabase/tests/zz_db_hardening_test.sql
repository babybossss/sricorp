-- ============================================================
-- SRI OS · เทสต์การปิดรูที่ผู้ตรวจยิงผ่าน 07/10 (ข้อ 1–4)
--
-- รันในเครื่อง:  bash scripts/test-rls-local.sh
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ **rollback ปิดท้าย** จึงไม่ทิ้งข้อมูลทดสอบไว้
-- เจอข้อผิด = raise exception = psql หยุดด้วย exit code ไม่ศูนย์
--
-- สามแบบของการ "ถูกปฏิเสธ" ที่ต้องแยกให้ออก ไม่งั้นเทสต์จะผ่านฟรีๆ:
--   RLS ไม่มี policy เขียน  → **0 แถว ไม่ใช่ error** → ต้องเช็ค row_count
--   column grant ถูกถอน      → error insufficient_privilege
--   trigger ปฏิเสธ           → error raise_exception (ข้อความขึ้นต้นด้วย 'กติกา:')
--
-- ทุกข้อมีขาบวกคู่กัน — กันแน่นเกินจนใช้งานไม่ได้ก็คือพัง
-- ============================================================

begin;

-- ---------- fixtures ----------
create temporary table t_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_uid(label) values ('super'), ('mgmt'), ('mgr'), ('staff'), ('ghost');
insert into auth.users(id) select id from t_uid;

insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, u.label || '@hard.local', u.label, x.role, true
  from t_uid u
  join (values ('super', 'super_admin'), ('mgmt', 'management'),
               ('mgr', 'manager'), ('staff', 'staff')) as x(label, role)
    on x.label = u.label;   -- 'ghost' ไม่มีแถวใน app_users โดยตั้งใจ

create or replace function pg_temp.login(p_label text) returns void
language sql as $fn$
  select set_config('test.uid', coalesce((select id::text from t_uid where label = p_label), ''), true);
$fn$;

do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.t_uid to authenticated', s);
end $$;

-- ============================================================
-- H1 · ตารางกฎ + ผังบัญชี: อ่านได้ทุกตำแหน่ง · เขียนไม่ได้เลยแม้แต่ Super Admin
--      (ผู้ตรวจยิงผ่านในฐานะ management: UPDATE 1 · DELETE 54 · UPDATE 48)
-- ============================================================
set local role authenticated;

do $$
declare r text; n int; n_types int; n_coa int;
begin
  select count(*) into n_types from sri_os.txn_types;
  select count(*) into n_coa   from sri_os.chart_of_accounts;
  if n_types < 40 or n_coa < 40 then
    raise exception 'FAIL: fixture ไม่ครบ (txn_types=% coa=%) เทสต์นี้จะไม่ได้ตรวจอะไร', n_types, n_coa;
  end if;
  if not exists (select 1 from sri_os.txn_types where code = 'exp.bank_charge') then
    raise exception 'FAIL: ไม่มีแถวต้นแบบ exp.bank_charge → H1e จะ insert 0 แถวแล้วผ่านฟรีๆ';
  end if;

  foreach r in array array['staff', 'mgr', 'mgmt', 'super'] loop
    perform pg_temp.login(r);

    -- ขาบวก: ต้องอ่านได้ครบ ไม่งั้นฟอร์มลงรายการไม่มีประเภทให้เลือก
    if (select count(*) from sri_os.txn_types) <> n_types then
      raise exception 'FAIL: % อ่าน txn_types ไม่ครบ → ฟอร์มลงรายการจะว่าง', r;
    end if;
    if (select count(*) from sri_os.chart_of_accounts) <> n_coa then
      raise exception 'FAIL: % อ่าน chart_of_accounts ไม่ครบ → รายงานจะไม่มีชื่อบัญชี', r;
    end if;

    -- H1a สลับคู่บัญชี = เปลี่ยนความหมายของรายการทั้งระบบย้อนหลัง
    update sri_os.txn_types set dr_coa_code = cr_coa_code, cr_coa_code = dr_coa_code;
    get diagnostics n = row_count;
    if n <> 0 then raise exception 'FAIL: % สลับคู่บัญชีในตารางกฎได้ (% แถว)', r, n; end if;

    -- H1b ปลดเงื่อนไขที่ฟอร์มต้องบังคับ
    update sri_os.txn_types set requires_capital_gain = false, requires_principal_split = false,
                                requires_asset = false, requires_transfer_target = false,
                                requires_contact = false, requires_loan_terms = false;
    get diagnostics n = row_count;
    if n <> 0 then raise exception 'FAIL: % ปลด requires_* ในตารางกฎได้ (% แถว)', r, n; end if;

    -- H1c ล้างตารางกฎทิ้ง
    delete from sri_os.txn_types;
    get diagnostics n = row_count;
    if n <> 0 then raise exception 'FAIL: % ลบตารางกฎได้ (% แถว)', r, n; end if;

    -- H1d เปลี่ยนชื่อ/ลบผังบัญชี
    update sri_os.chart_of_accounts set name_th = 'HACKED';
    get diagnostics n = row_count;
    if n <> 0 then raise exception 'FAIL: % แก้ชื่อผังบัญชีได้ (% แถว)', r, n; end if;
    delete from sri_os.chart_of_accounts;
    get diagnostics n = row_count;
    if n <> 0 then raise exception 'FAIL: % ลบผังบัญชีได้ (% แถว)', r, n; end if;

    -- H1e แทรกประเภทรายการปลอม (= เปิดคู่บัญชีของตัวเอง)
    --     ลอกค่าจากแถวจริงเพื่อให้ FK/CHECK ผ่าน แล้วเหลือ RLS เป็นด่านเดียวที่ถูกทดสอบ
    begin
      insert into sri_os.txn_types(code, group_code, name_th, cf_group, direction,
                                   dr_coa_code, cr_coa_code)
      select 'zz.' || r, t.group_code, 'ของปลอม', t.cf_group, t.direction,
             t.dr_coa_code, t.cr_coa_code
        from sri_os.txn_types t where t.code = 'exp.bank_charge';
      raise exception 'FAIL: % แทรกประเภทรายการปลอมได้ = เปิดคู่บัญชีของตัวเอง', r;
    exception when insufficient_privilege then null;
      when raise_exception then if sqlerrm like 'FAIL:%' then raise; end if;
    end;
  end loop;
  raise notice 'ok H1 · ตารางกฎ/ผังบัญชี: ทุกตำแหน่งอ่านได้ครบ · เขียนไม่ได้เลย (รวม Super Admin)';
end $$;

-- ============================================================
-- H2 · owners: คอลัมน์กติกาแก้ไม่ได้ · ลบ corporate_strict ไม่ได้
--      แต่เพิ่ม/แก้ชื่อ/เปลี่ยนสถานะยังทำได้ตามเดิม
--      (ผู้ตรวจยิงผ่านในฐานะ management: UPDATE 3 = ปลด corporate_strict ทั้งองค์กร)
-- ============================================================
do $$
declare r text; n int; n_corp int;
begin
  select count(*) into n_corp from sri_os.owners where policy = 'corporate_strict';
  if n_corp <> 3 then
    raise exception 'FAIL: fixture ควรมี corporate_strict 3 ราย แต่พบ % — เทสต์นี้อาจไม่ได้ตรวจอะไร', n_corp;
  end if;

  foreach r in array array['staff', 'mgr', 'mgmt', 'super'] loop
    perform pg_temp.login(r);

    -- H2a ปลด corporate_strict ทั้งองค์กรในคำสั่งเดียว — ต้องล้มที่ชั้น GRANT (error)
    begin
      update sri_os.owners set policy = 'personal_flexible' where policy = 'corporate_strict';
      raise exception 'FAIL: % ปลด corporate_strict ได้ทั้งองค์กร', r;
    exception when insufficient_privilege then null;
      when raise_exception then if sqlerrm like 'FAIL:%' then raise; end if;
    end;

    -- H2b เปลี่ยน type / code ของนิติบุคคล
    foreach n in array array[1, 2] loop
      begin
        if n = 1 then
          update sri_os.owners set type = 'person' where code = 'SRI_CORP';
        else
          update sri_os.owners set code = 'SRI_CORP_X' where code = 'SRI_CORP';
        end if;
        raise exception 'FAIL: % แก้คอลัมน์กติกาของ owners ได้ (กรณี %)', r, n;
      exception when insufficient_privilege then null;
        when raise_exception then if sqlerrm like 'FAIL:%' then raise; end if;
      end;
    end loop;

    -- H2c ลบแล้ว insert กลับเป็น personal_flexible = ปลด corporate_strict ทางอ้อม
    begin
      delete from sri_os.owners where code = 'SRI_HOLDING';
      -- ถ้า RLS ปฏิเสธจะได้ 0 แถว (ไม่ error) · ถ้า trigger ปฏิเสธจะ raise
      get diagnostics n = row_count;
      if n <> 0 then
        raise exception 'FAIL: % ลบผู้ถือที่เป็น corporate_strict ได้ → insert กลับเป็น personal ได้ทันที', r;
      end if;
    exception when raise_exception then if sqlerrm like 'FAIL:%' then raise; end if;
    end;

    -- H2+ ขาบวก: แก้ชื่อ · สถานะ · สี · ลำดับ · เลขภาษี · ธง VAT ต้องยังทำได้ (ถ้ามีสิทธิ์)
    update sri_os.owners
       set name_th = 'สุธี (แก้ชื่อ)', status = 'inactive', color = '#111111',
           sort_order = 99, tax_id_last4 = '1234', vat_registered = true
     where code = 'SUTEE';
    get diagnostics n = row_count;
    if r in ('mgmt', 'super') and n <> 1 then
      raise exception 'FAIL: % แก้ชื่อ/สถานะผู้ถือไม่ได้ (% แถว) → หน้าจัดการผู้ถือพัง', r, n;
    end if;
    if r in ('staff', 'mgr') and n <> 0 then
      raise exception 'FAIL: % ไม่มี settings.manage แต่แก้ผู้ถือได้', r;
    end if;
  end loop;

  -- H2+ ขาบวก: เพิ่มผู้ถือใหม่ (รวมนิติบุคคลที่ corporate_strict) ต้องทำได้
  perform pg_temp.login('mgmt');
  insert into sri_os.owners(code, type, policy, name_th, status)
  values ('NEWCO', 'company', 'corporate_strict', 'บริษัทใหม่', 'planned');
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL: settings.manage เพิ่มผู้ถือใหม่ไม่ได้'; end if;

  -- ลบของที่เพิ่งเพิ่ม (corporate_strict) ต้องล้ม — ไม่งั้นช่อง H2c เปิดอยู่
  begin
    delete from sri_os.owners where code = 'NEWCO';
    get diagnostics n = row_count;
    if n <> 0 then raise exception 'FAIL: ลบผู้ถือ corporate_strict ที่เพิ่งสร้างได้'; end if;
  exception when raise_exception then if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  raise notice 'ok H2 · owners: policy/type/code/id แก้ไม่ได้ · ลบ corporate_strict ไม่ได้ · เพิ่ม/แก้ชื่อ-สถานะยังทำได้';
end $$;

-- H2d ชั้น TRIGGER ต้องกัน **superuser** ด้วย (column grant ไม่มีผลกับ superuser)
reset role;
do $$
declare n int;
begin
  begin
    update sri_os.owners set policy = 'personal_flexible' where code = 'SRI_CORP';
    raise exception 'FAIL: superuser ของ cluster ปลด corporate_strict ได้ → ชั้น trigger ไม่ทำงาน';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if sqlerrm not like 'กติกา:%' then
      raise exception 'FAIL: ถูกปฏิเสธด้วยเหตุอื่น ไม่ใช่ trigger ของเรา: %', sqlerrm;
    end if;
  end;

  begin
    delete from sri_os.owners where code = 'SRI_CAPITAL';
    raise exception 'FAIL: superuser ลบผู้ถือ corporate_strict ได้';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  -- ขาบวก: superuser แก้ชื่อได้ตามปกติ (trigger ไม่ได้ล็อกทั้งตาราง)
  update sri_os.owners set name_th = name_th || '' where code = 'SRI_CORP';
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL: trigger ล็อกคอลัมน์ที่ไม่ควรล็อก'; end if;

  -- ขาบวก: ลบผู้ถือฝั่งบุคคลที่ยังไม่มีข้อมูลผูก ยังทำได้
  insert into sri_os.owners(code, type, policy, name_th) values ('TMPP', 'person', 'personal_flexible', 'ชั่วคราว');
  delete from sri_os.owners where code = 'TMPP';
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL: ลบผู้ถือฝั่งบุคคลไม่ได้ = ล็อกแน่นเกินไป'; end if;

  raise notice 'ok H2d · trigger ปฏิเสธการเปลี่ยน policy/ลบ corporate_strict แม้เป็น superuser · ของที่ควรทำได้ยังทำได้';
end $$;

-- ฟังก์ชัน trigger ของ owners ต้อง **ไม่** พึ่งตารางสิทธิ์ (กฎเงินห้ามปิดจากหน้า Settings)
do $$
declare v text;
begin
  select p.prosrc into v from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'sri_os' and p.proname = 'fn_owners_rule_columns_immutable';
  if v is null then raise exception 'FAIL: ไม่พบฟังก์ชัน fn_owners_rule_columns_immutable'; end if;
  if v ~* 'fn_can|fn_is_management' then
    raise exception 'FAIL: trigger ของ owners เรียก fn_can → ปลด corporate_strict ได้ด้วยการแก้ตารางสิทธิ์';
  end if;
  raise notice 'ok H2e · trigger ของ owners ไม่พึ่งตารางสิทธิ์';
end $$;

-- ============================================================
-- H3 · asset_classes / asset_categories: เปิด RLS แล้ว · อ่านได้ เขียนไม่ได้
--      (ผู้ตรวจลบได้ 15 + 4 แถวจาก session ที่ไม่มีแถวใน app_users เลย)
-- ============================================================
set local role authenticated;
do $$
declare r text; n int; n_cls int; n_cat int;
begin
  perform pg_temp.login('super');
  select count(*) into n_cls from sri_os.asset_classes;
  select count(*) into n_cat from sri_os.asset_categories;
  if n_cls = 0 or n_cat = 0 then
    raise exception 'FAIL: fixture taxonomy ว่าง (cls=% cat=%) เทสต์นี้จะไม่ได้ตรวจอะไร', n_cls, n_cat;
  end if;

  foreach r in array array['ghost', 'staff', 'mgr', 'mgmt', 'super'] loop
    perform pg_temp.login(r);

    -- ขาบวก: ฟอร์มเพิ่มทรัพย์ต้องมีรายการให้เลือก → อ่านต้องได้ทุกตำแหน่ง
    -- (รวม ghost ที่ยังไม่ถูกตั้งตำแหน่ง — ไม่งั้นหน้าแรกหลังเชิญเข้าระบบจะพัง)
    if (select count(*) from sri_os.asset_classes) <> n_cls then
      raise exception 'FAIL: % อ่าน asset_classes ไม่ครบ → ฟอร์มเพิ่มทรัพย์จะไม่มีกลุ่มให้เลือก', r;
    end if;
    if (select count(*) from sri_os.asset_categories) <> n_cat then
      raise exception 'FAIL: % อ่าน asset_categories ไม่ครบ', r;
    end if;

    delete from sri_os.asset_categories;
    get diagnostics n = row_count;
    if n <> 0 then raise exception 'FAIL: % ลบ asset_categories ได้ (% แถว) → ทรัพย์ทุกตัวอ้างหมวดที่หายไป', r, n; end if;

    delete from sri_os.asset_classes;
    get diagnostics n = row_count;
    if n <> 0 then raise exception 'FAIL: % ลบ asset_classes ได้ (% แถว)', r, n; end if;

    update sri_os.asset_classes set name_th = 'hack';
    get diagnostics n = row_count;
    if n <> 0 then raise exception 'FAIL: % แก้ asset_classes ได้ (% แถว)', r, n; end if;

    begin
      insert into sri_os.asset_classes(code, name_th) values ('ZZ_' || r, 'ของปลอม');
      raise exception 'FAIL: % แทรก asset_classes ปลอมได้', r;
    exception when insufficient_privilege then null;
      when raise_exception then if sqlerrm like 'FAIL:%' then raise; end if;
    end;
  end loop;
  raise notice 'ok H3 · taxonomy ทรัพย์: ทุกตำแหน่ง (รวมคนที่ยังไม่มีตำแหน่ง) อ่านได้ · เขียนไม่ได้';
end $$;

-- ============================================================
-- H4 · EXECUTE ของฟังก์ชัน
--      fn_health_check เป็น SECURITY DEFINER ข้าม RLS และคืน transaction_id
--      ข้าม owner — ผู้ตรวจเรียกได้จาก session ที่ไม่มีแถวใน app_users เลย
-- ============================================================
do $$
declare r text; n int;
begin
  -- H4a ไม่มี settings.manage → ต้อง raise ไม่ใช่คืน 0 แถว
  --     ("ไม่มีสิทธิ์" กับ "ข้อมูลสุขภาพดี" ต้องแยกกันให้ออก)
  foreach r in array array['ghost', 'staff', 'mgr'] loop
    perform pg_temp.login(r);
    begin
      perform * from sri_os.fn_health_check();
      raise exception 'FAIL: % เรียก fn_health_check ได้ = ดึง transaction_id ข้ามผู้ถือ', r;
    exception when insufficient_privilege then null;
      when raise_exception then
        if sqlerrm like 'FAIL:%' then raise; end if;
        if sqlerrm not like 'ไม่มีสิทธิ์%' then
          raise exception 'FAIL: % ถูกปฏิเสธด้วยเหตุอื่น: %', r, sqlerrm;
        end if;
    end;
  end loop;

  -- H4b ขาบวก: settings.manage ต้องเรียกได้จริง (ไม่ใช่ปิดตายจนรายงานใช้ไม่ได้)
  foreach r in array array['mgmt', 'super'] loop
    perform pg_temp.login(r);
    -- 5 ข้อตั้งแต่ 20261008000002 (เพิ่มธง valuations_present แยกจาก valuations_fresh)
    -- ตัวเลขตรงนี้คือ canary: ธงที่หายไปเงียบๆ ต้องทำให้เทสต์แดง
    select count(*) into n from sri_os.fn_health_check();
    if n <> 5 then
      raise exception 'FAIL: % เรียก fn_health_check ได้ % แถว (ต้องได้ 5) → หน้า Data health พัง', r, n;
    end if;
  end loop;

  -- H4c ขาบวก: ฟังก์ชันที่หน้าจอต้องใช้ ยังเรียกได้
  perform pg_temp.login('mgr');
  perform sri_os.fn_my_role();
  perform sri_os.fn_is_management();
  perform sri_os.fn_contract_completeness(gen_random_uuid());
  perform sri_os.fn_asset_cost_basis(gen_random_uuid());
  raise notice 'ok H4 · fn_health_check เรียกได้เฉพาะ settings.manage · ฟังก์ชันของหน้าจอยังเรียกได้';
end $$;

reset role;

-- H4d โครงสร้าง: ห้ามมี SECURITY DEFINER ตัวใดเหลือ PUBLIC EXECUTE
--     ไล่จาก pg_proc ไม่ใช่ลิสต์มือ → จับฟังก์ชันที่เพิ่มในอนาคตด้วย
do $$
declare v text; n int;
begin
  select string_agg(p.oid::regprocedure::text, ', '), count(*) into v, n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.prosecdef
     and has_function_privilege('public', p.oid, 'execute');
  if n > 0 then
    raise exception 'FAIL: SECURITY DEFINER ที่ PUBLIC เรียกได้ % ตัว: % · ฟังก์ชันพวกนี้ข้าม RLS ทุกตาราง', n, v;
  end if;

  -- anon ต้องเรียกอะไรใน sri_os ไม่ได้เลย (ไม่มีหน้า public)
  select string_agg(p.proname, ', '), count(*) into v, n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname like 'fn\_%'
     and has_function_privilege('anon', p.oid, 'execute');
  if n > 0 then
    raise exception 'FAIL: anon เรียกฟังก์ชันใน sri_os ได้ % ตัว: %', n, v;
  end if;

  -- SECURITY DEFINER ทุกตัวต้องตั้ง search_path (หลุด = ช่องยึดสิทธิ์)
  -- และต้องไม่พา schema อื่นเข้ามาในเส้นทางค้นหา นอกจาก sri_os ของตัวเอง
  select string_agg(p.proname || ' → ' || array_to_string(p.proconfig, ','), ', '), count(*) into v, n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.prosecdef
     and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c
                      where c in ('search_path=', 'search_path=""', 'search_path=sri_os'));
  if n > 0 then
    raise exception 'FAIL: SECURITY DEFINER ที่ search_path ไม่แน่น % ตัว: % · ตั้งเป็น '''' แล้วเขียนชื่อเต็ม', n, v;
  end if;

  -- กันเทสต์เปล่า
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.prosecdef;
  if n < 10 then
    raise exception 'FAIL: นับ SECURITY DEFINER ได้แค่ % ตัว — เทสต์นี้อาจไม่ได้ตรวจอะไรเลย', n;
  end if;
  raise notice 'ok H4d · SECURITY DEFINER ทั้ง % ตัว: ไม่มีตัวไหนเปิด PUBLIC · search_path แน่นทุกตัว · anon เรียกไม่ได้', n;
end $$;

-- ============================================================
-- H5 · ตารางที่ "อ่านได้แต่เขียนไม่ได้" ต้องไม่มี policy ที่ไม่ใช่ SELECT หลงกลับมา
--      policy เป็น permissive และ OR กัน · ของกว้างตัวเดียวลบล้างทั้งชุดได้เงียบๆ
-- ============================================================
do $$
declare v text;
begin
  select string_agg(tablename || '.' || policyname || ' (' || cmd || ')', ', ') into v
    from pg_policies
   where schemaname = 'sri_os'
     and tablename in ('txn_types', 'chart_of_accounts', 'asset_classes', 'asset_categories',
                       'roles', 'permissions', 'role_permissions')
     and cmd <> 'SELECT';
  if v is not null then
    raise exception 'FAIL: ตารางอ้างอิง/ตารางกฎมี policy ที่ไม่ใช่ SELECT: %', v;
  end if;
  raise notice 'ok H5 · ตารางกฎ/ผังบัญชี/taxonomy/ตารางสิทธิ์: มีแต่ policy SELECT';
end $$;

do $$ begin raise notice '=== db hardening ผ่านทั้งหมด ==='; end $$;

rollback;
