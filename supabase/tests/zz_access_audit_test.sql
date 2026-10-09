-- ============================================================
-- SRI OS · เทสต์ร่องรอยของ "ใครเห็นเงินของใครได้" และตารางรอบนอกที่เหลือ
--   ปิดด้วย supabase/migrations/20261008000005_access_audit.sql
--
--   X0  · โครงสร้าง: trigger ครบหกตาราง ครอบ **insert + update + delete** และเป็น
--         after ... for each row · ฟังก์ชันใหม่ไม่ถาม fn_can · ACL ปิดถูก
--   X1  · settings — audit ทำงานจริงทั้งสามคำสั่ง · row_id คงที่และตรงกับ fn_audit_row_id
--   X2  · user_owner_access — ถอน/เปลี่ยนขอบเขตการเห็นแล้วต้องเห็นว่าเคยมีอะไร
--   X3  · ลบ app_users → cascade ลบ user_owner_access · **ขา cascade ต้องมีร่องรอยด้วย**
--   X4  · FK กันลบคู่ค้าที่ผูก transactions (ยืนยันว่ากันจริง ไม่ใช่เชื่อว่ากัน)
--   X5  · FK กันลบคู่ค้าที่ผูก contracts
--   X6  · ลบคู่ค้าที่ยังไม่ผูกรายการได้ และขา cascade ของ contact_links มีร่องรอย
--   X7  · app_users · owners — audit ทำงานจริงทั้งสามคำสั่ง
--   X8  · **ตรึงพฤติกรรมที่รายงานไว้**: ถอนคนที่เคยลงรายการด้วย DELETE จะติด FK
--         → เส้นทางจริงคือ is_active = false ซึ่งต้องมีร่องรอย
--   X9  · guard "ทุกตารางใน sri_os ต้องมี audit" ไล่จาก pg_trigger จริง +
--         เงื่อนไขของ allow-list ทุกตัว + **พิสูจน์ว่าตารางใหม่ที่ไม่มี audit จะแดง**
--   X10 · ข้ออ้าง "สี่ตารางนั้นมี audit แล้ว" ต้องพิสูจน์ **ตอน DELETE** ไม่ใช่แค่ INSERT
--         (assets · bank_accounts · draft_entries · asset_drafts)
--   X11 · เคส "ไม่ส่งข้อมูล" ของ audit เอง — ไม่ส่งคีย์ · ส่งคีย์ที่ไม่มี · คีย์เป็น null ·
--         DELETE ที่ไม่ตรงแถวไหนเลย · และพิสูจน์ว่า fn_audit เดิมใช้กับตารางไร้ id ไม่ได้
--   X12 · **เส้นทางที่ถูกต้องต้องยังทำได้** ในฐานะ authenticated (บทเรียนข้อ 7)
--
-- รันในเครื่อง:  bash scripts/test-rls-local.sh
--   ไฟล์ migration ใหม่ต้องอยู่ใน UNDER_TEST ด้วย:
--   UNDER_TEST="... 20261008000004_history_guards.sql 20261008000005_access_audit.sql" \
--     bash scripts/test-rls-local.sh
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ rollback ปิดท้าย · เจอข้อผิด = raise exception
--
-- สามแบบของการ "ถูกปฏิเสธ" ที่ต้องแยกให้ออก ไม่งั้นเทสต์ผ่านฟรีๆ:
--   RLS ไม่มี policy → **0 แถว ไม่ใช่ error** → ต้องเช็ค row_count
--   ไม่มี grant      → insufficient_privilege (ไม่ได้แตะ trigger เลย)
--   FK / trigger     → raise_exception/foreign_key_violation + **แถวต้องยังอยู่**
-- ทุกข้อจึงนับแถวก่อน/หลังด้วย ไม่เชื่อแค่ข้อความ error
--
-- สิ่งที่ไฟล์นี้ต้องจับได้ (ไล่จาก "ถ้าถอดการแก้ออกแล้วต้องแดง"):
--   K1  ไม่ติด audit ตารางใดตารางหนึ่งในหก              → X0 X9 แดง (+ ข้อของตารางนั้น)
--   K2  **ติด audit แค่ INSERT (ครอบขาเดียว)**           → X0 X1 X2 X7 X9 แดง
--   K3  ติดเป็น BEFORE แทน AFTER                        → X0 X9 แดง
--   K4  ใช้ fn_audit กับ settings/user_owner_access      → X1 X2 X11 แดง (42703 · และ
--                                                          ทุก mutation ของตารางนั้นล้ม)
--   K5  trigger ติดอยู่แต่ไม่เขียน audit_log จริง        → X1 X2 X7 X10 แดง (นับแถว audit)
--   K6  ส่งคีย์ของ fn_audit_keyed ไม่ตรง PK              → X0 แดง (migration พังก่อนด้วย)
--   K7  **เผลอปิด DELETE/UPDATE ของตารางสิทธิ์/ค่าตั้งค่า** → X12 แดง (และ guard พัง)
--   K8  ไม่ติด audit ที่ contact_links (กันแต่ตารางแม่)  → X6 แดง (ขา cascade ไร้ร่องรอย)
--   K9  FK ของ contacts ถูกเปลี่ยนเป็น set null/cascade  → X4 X5 แดง (รายการชี้ไปที่ว่าง)
--   K10 ตารางใหม่ไม่มี audit แล้วไม่มีใครรู้             → X9 แดง
--   K11 allow-list อ้างเหตุผลที่เน่าแล้ว (เปิด policy เขียนให้ตารางกฎ /
--       เปิด UPDATE ให้ asset_valuations / audit_log ไม่ append-only) → X9 แดง
--   K12 fn_audit_keyed เป็น invoker หรือเรียกจากข้างนอกได้ → X0 แดง
--   K13 สี่ตารางที่อ้างว่า "มี audit แล้ว" ครอบแค่ INSERT/UPDATE → X10 แดง
--
-- เคส "ไม่ส่งข้อมูล" (บทเรียนข้อ 3) อยู่ที่ X11 ทั้งข้อ และที่
--   X1 (settings ที่ value ว่าง → ต้องถูกปฏิเสธที่ NOT NULL ไม่ใช่ audit เดาให้)
--   X9 (ตารางใหม่ที่ "ไม่มีใครใส่ audit ให้" = ข้อมูลที่ไม่ได้ส่งของ guard)
-- ============================================================

begin;

-- ---------- fixtures: ผู้ใช้ ----------
create temporary table t_xuid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_xuid(label) values ('x_super'), ('x_mgmt'), ('x_mgr'), ('x_staff'), ('x_leaver'), ('x_poster');
insert into auth.users(id) select id from t_xuid;

insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, u.label || '@acc.local', u.label, x.role, true
  from t_xuid u
  join (values ('x_super', 'super_admin'), ('x_mgmt', 'management'),
               ('x_mgr', 'manager'), ('x_staff', 'staff'),
               ('x_leaver', 'staff'), ('x_poster', 'manager')) as x(label, role)
    on x.label = u.label;

create or replace function pg_temp.xuid(p_label text) returns uuid
language sql stable as $fn$ select id from t_xuid where label = p_label $fn$;

create or replace function pg_temp.xlogin(p_label text) returns void
language sql as $fn$
  select set_config('test.uid', coalesce((select id::text from t_xuid where label = p_label), ''), true);
$fn$;

-- RLS ปฏิเสธ UPDATE/DELETE แบบ **เงียบ** (0 แถว ไม่ใช่ error) จึงต้องมีตัวนับแถวด้วย
create or replace function pg_temp.xrows(p_label text, p_sql text, p_expect int) returns void
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

create or replace function pg_temp.xpass(p_label text, p_sql text) returns void
language plpgsql as $fn$
begin
  execute p_sql;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: % — คำสั่งควรสำเร็จแต่ล้ม (%) · sql: %', p_label, sqlerrm, p_sql;
end $fn$;

-- คำสั่งที่ต้องล้ม · คืน sqlstate ที่ได้เพื่อแยก "ถูกปฏิเสธด้วยอะไร" ให้ชัด
create or replace function pg_temp.xfail(p_label text, p_sql text) returns text
language plpgsql as $fn$
begin
  execute p_sql;
  raise exception 'FAIL: % — คำสั่งสำเร็จทั้งที่ต้องถูกปฏิเสธ · sql: %', p_label, p_sql;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  return sqlstate;
end $fn$;

do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.t_xuid to authenticated', s);
end $$;

insert into sri_os.user_owner_access(user_id, owner_id)
select u.id, o.id from t_xuid u cross join sri_os.owners o
 where u.label in ('x_mgr', 'x_staff', 'x_poster') and o.code in ('SRI_CORP', 'SUTEE')
on conflict do nothing;

-- ---------- fixtures: คู่ค้า · ทรัพย์ · บัญชีธนาคาร · สัญญา ----------
insert into sri_os.contacts(id, first_name, last_name, types)
values ('00000000-0000-0000-0000-0000000000a1', 'คู่ค้าผูกรายการ', 'เทสต์', array['tenant']),
       ('00000000-0000-0000-0000-0000000000a2', 'คู่ค้าผูกสัญญา',  'เทสต์', array['borrower']),
       ('00000000-0000-0000-0000-0000000000a3', 'คู่ค้าไม่ผูกอะไร', 'เทสต์', array['tenant']);

insert into sri_os.contact_links(id, contact_id, target_type, target_id, role)
values ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a3',
        'asset', '00000000-0000-0000-0000-0000000000b9', 'tenant');

insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, manager_user_id)
select '00000000-0000-0000-0000-0000000000c1', 'AA-A1', 'ทรัพย์เทสต์ร่องรอยสิทธิ์',
       (select class_id from sri_os.asset_categories order by code limit 1),
       (select id       from sri_os.asset_categories order by code limit 1),
       o.id, pg_temp.xuid('x_mgr')
  from sri_os.owners o where o.code = 'SRI_CORP';

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
select '00000000-0000-0000-0000-0000000000c2', o.id, 'KBANK', 'บัญชีเทสต์ร่องรอยสิทธิ์', 'บัญชีเทสต์ร่องรอยสิทธิ์'
  from sri_os.owners o where o.code = 'SRI_CORP';

insert into sri_os.contracts(id, code, owner_id, asset_id, type, counterparty_contact_id,
                             principal, rate, rate_period, interest_method,
                             start_date, end_date, installments, file_urls, status)
select '00000000-0000-0000-0000-0000000000c3', 'AA-C1', o.id,
       '00000000-0000-0000-0000-0000000000c1', 'loan_receivable',
       '00000000-0000-0000-0000-0000000000a2',
       500000, 1.0, 'month', 'simple',
       current_date - 30, current_date + 330, 12, array['สัญญา-AA.pdf'], 'active'
  from sri_os.owners o where o.code = 'SRI_CORP';

-- รายการที่ผูกคู่ค้า a1 · และ x_poster เป็นคนลง (ใช้ตรึงเคส FK ของ app_users ที่ X8)
insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, contact_id, attachments, created_by)
select '00000000-0000-0000-0000-0000000000d1', o.id, 'inc.other', current_date,
       '00000000-0000-0000-0000-0000000000a1', array['หลักฐาน-AA.pdf'], pg_temp.xuid('x_poster')
  from sri_os.owners o where o.code = 'SRI_CORP';
insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
select '00000000-0000-0000-0000-0000000000d1', c.id,
       case when c.rn = 1 then 250 else 0 end,
       case when c.rn = 2 then 250 else 0 end
  from (select c2.id, v.rn from sri_os.chart_of_accounts c2 join (values ('1220', 1), ('4900', 2)) as v(code, rn) on v.code = c2.code) c;

-- ============================================================
-- X0 · โครงสร้าง: ไล่จาก pg_trigger / pg_proc จริง ไม่ใช่ไล่ไฟล์
--      ต้องครอบ **ทั้งสามคำสั่ง** · after for each row · ฟังก์ชันปิดถูก
-- ============================================================
do $$
declare r text; n int; v text; v_pk text;
begin
  foreach r in array array['app_users', 'user_owner_access', 'settings',
                           'contacts', 'contact_links', 'owners'] loop
    select count(*) into n
      from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
     where tg.tgrelid = ('sri_os.' || r)::regclass
       and not tg.tgisinternal
       and p.proname in ('fn_audit', 'fn_audit_keyed')
       and (tg.tgtype & 4) <> 0 and (tg.tgtype & 16) <> 0 and (tg.tgtype & 8) <> 0
       and (tg.tgtype & 2) = 0 and (tg.tgtype & 64) = 0 and (tg.tgtype & 1) <> 0;
    if n <> 1 then
      raise exception 'FAIL: sri_os.% ไม่มี audit trigger ที่ครอบ insert+update+delete แบบ after for each row พอดีหนึ่งตัว (เจอ %) — "มี audit แล้ว" ที่ครอบขาเดียวคือสิ่งที่เทสต์นี้มีอยู่เพื่อจับ', r, n;
    end if;
    -- **ของที่ต้องไม่มี**: trigger ขัดขวาง DML (กันแน่นเกิน = บริหารคน/สิทธิ์ไม่ได้)
    select string_agg(tg.tgname, ', ') into v
      from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
     where tg.tgrelid = ('sri_os.' || r)::regclass and not tg.tgisinternal
       and p.proname like 'fn\_forbid%' and p.proname <> 'fn_forbid_truncate';
    if v is not null then
      raise exception 'FAIL: sri_os.% มี trigger ขัดขวาง DML: % · ถอนสิทธิ์/ถอนคน/แก้ค่าตั้งค่า/แก้คู่ค้า ต้องยังทำได้ (ต้องการร่องรอย ไม่ใช่ห้ามทำ)', r, v;
    end if;
    -- กัน TRUNCATE ของ 20261008000004 ต้องไม่หายไป (row trigger ไม่ยิงตอน TRUNCATE)
    if not exists (select 1 from pg_trigger where tgrelid = ('sri_os.' || r)::regclass
                    and tgname = 'trg_forbid_truncate') then
      raise exception 'FAIL: sri_os.% ไม่มี trigger กัน TRUNCATE → ล้างทั้งตารางได้โดย audit ไม่ยิงแม้แถวเดียว (ถดถอยจาก 20261008000004)', r;
    end if;
  end loop;

  -- ตารางที่ใช้ fn_audit_keyed: คีย์ที่ส่งต้องตรงกับ PK จริง เรียงตามลำดับ
  foreach r in array array['settings', 'user_owner_access'] loop
    select string_agg(quote_literal(a.attname), ', ' order by k.ord) into v_pk
      from pg_constraint con
      join unnest(con.conkey) with ordinality as k(attnum, ord) on true
      join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum
     where con.conrelid = ('sri_os.' || r)::regclass and con.contype = 'p';
    if not exists (select 1 from pg_trigger tg
                    where tg.tgrelid = ('sri_os.' || r)::regclass and not tg.tgisinternal
                      and tg.tgfoid = 'sri_os.fn_audit_keyed'::regproc
                      and pg_get_triggerdef(tg.oid) like '%fn_audit_keyed(' || v_pk || ')') then
      raise exception 'FAIL: audit ของ sri_os.% ไม่ได้ส่งคีย์ตรงกับ primary key (ต้องเป็น fn_audit_keyed(%)) → ร่องรอยจะชี้ผิดแถวเงียบๆ', r, v_pk;
    end if;
  end loop;

  -- fn_audit_keyed: ต้องเป็น SECURITY DEFINER (audit_log ไม่มี policy INSERT)
  --   แต่ต้อง **ไม่ถามสิทธิ์** และเรียกจากข้างนอกไม่ได้
  select string_agg(p.proname, ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_audit_keyed'
     and (not p.prosecdef
       or p.proconfig is null
       or array_to_string(p.proconfig, ',') not like '%search_path%'
       or p.prosrc ~* 'fn_can'
       or has_function_privilege('public', p.oid, 'execute')
       or has_function_privilege('anon', p.oid, 'execute')
       or has_function_privilege('authenticated', p.oid, 'execute'));
  if v is not null then
    raise exception 'FAIL: fn_audit_keyed หลวมหรือหลวมผิดทาง (ต้อง secdef + ล็อก search_path + ไม่ถาม fn_can + เรียกจากข้างนอกไม่ได้): %', v;
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                  where ns.nspname = 'sri_os' and p.proname = 'fn_audit_row_id'
                    and p.provolatile = 'i'
                    and p.prosrc !~* 'fn_can'
                    and not has_function_privilege('public', p.oid, 'execute')
                    and not has_function_privilege('anon', p.oid, 'execute')
                    and has_function_privilege('authenticated', p.oid, 'execute')) then
    raise exception 'FAIL: fn_audit_row_id ต้องเป็น immutable · ไม่ถาม fn_can · public/anon เรียกไม่ได้ · authenticated เรียกได้ (คนที่มี owner.view_all ต้องใช้ค้น audit ของ settings/user_owner_access)';
  end if;

  raise notice 'ok X0 · หกตารางมี audit ครบสามคำสั่งแบบ after row · ไม่มีด่านขัดขวาง DML · คีย์ตรง PK · ฟังก์ชันใหม่ปิดถูก';
end $$;

-- ============================================================
-- X1 · settings — audit ทำงานจริง ไม่ใช่แค่มี trigger ติดอยู่
--      และ row_id ต้องคงที่ + ตรงกับสูตรที่ฝั่งอ่านเรียกได้
-- ============================================================
do $$
declare n int; v_row uuid; v_again uuid; v_state text;
begin
  v_row := sri_os.fn_audit_row_id('settings', array['key'],
             jsonb_build_object('key', 'acc.probe'));

  insert into sri_os.settings(key, value) values ('acc.probe', '{"v":1}'::jsonb);
  update sri_os.settings set value = '{"v":2}'::jsonb where key = 'acc.probe';
  delete from sri_os.settings where key = 'acc.probe';

  select count(*) into n from sri_os.audit_log
   where table_name = 'settings' and row_id = v_row;
  if n <> 3 then
    raise exception 'FAIL: settings ควรมีร่องรอย 3 แถว (insert+update+delete) แต่ได้ % แถว · row_id ที่ฝั่งอ่านคำนวณได้ต้องตรงกับที่ trigger เขียน', n;
  end if;
  if not exists (select 1 from sri_os.audit_log
                  where table_name = 'settings' and row_id = v_row and action = 'update'
                    and before ->> 'value' = '{"v": 1}' and after ->> 'value' = '{"v": 2}') then
    raise exception 'FAIL: ร่องรอยของการแก้ค่าตั้งค่าไม่เก็บ before-after (แก้ทับได้เงียบๆ = แย่กว่าไม่มี audit เพราะเชื่อว่ามี)';
  end if;
  if not exists (select 1 from sri_os.audit_log
                  where table_name = 'settings' and row_id = v_row and action = 'delete'
                    and before ->> 'key' = 'acc.probe' and after is null) then
    raise exception 'FAIL: ร่องรอยการลบค่าตั้งค่าไม่เก็บค่าเดิมไว้ → ไม่รู้ว่าเคยตั้งไว้เท่าไร';
  end if;

  -- ลบแล้วใส่กลับต้องได้ row_id เดิม = ไล่ไทม์ไลน์ของคีย์เดียวกันต่อได้
  insert into sri_os.settings(key, value) values ('acc.probe', '{"v":3}'::jsonb);
  select row_id into v_again from sri_os.audit_log
   where table_name = 'settings' and action = 'insert' order by id desc limit 1;
  if v_again <> v_row then
    raise exception 'FAIL: ใส่คีย์เดิมกลับได้ row_id ใหม่ (% vs %) → ไทม์ไลน์ของค่าตั้งค่าตัวเดียวกันขาดเป็นสองเส้น', v_again, v_row;
  end if;

  -- เคส "ไม่ส่งข้อมูล": value ว่างต้องถูกปฏิเสธที่ NOT NULL ไม่ใช่ให้ audit เดาให้
  v_state := pg_temp.xfail('ตั้งค่าโดยไม่ส่ง value',
    $q$insert into sri_os.settings(key, value) values ('acc.novalue', null)$q$);
  if v_state <> '23502' then
    raise exception 'FAIL: ตั้งค่าโดยไม่ส่ง value ถูกปฏิเสธด้วย % (คาด 23502 not_null_violation)', v_state;
  end if;
  if exists (select 1 from sri_os.audit_log where table_name = 'settings'
              and coalesce(after ->> 'key', before ->> 'key') = 'acc.novalue') then
    raise exception 'FAIL: มีร่องรอยของค่าตั้งค่าที่ไม่เคยถูกบันทึกสำเร็จ';
  end if;

  delete from sri_os.settings where key = 'acc.probe';
  raise notice 'ok X1 · settings มีร่องรอยครบ insert/update/delete · row_id คงที่และตรงกับ fn_audit_row_id · ค่าที่ไม่ครบถูกปฏิเสธ ไม่ใช่เดาให้';
end $$;

-- ============================================================
-- X2 · user_owner_access — ขอบเขต "ใครเห็นเงินของใครได้" เปลี่ยนแล้วต้องเห็น
-- ============================================================
do $$
declare n int; v_row uuid; v_owner uuid; v_owner2 uuid;
begin
  select id into v_owner  from sri_os.owners where code = 'SRI_CORP';
  select id into v_owner2 from sri_os.owners where code = 'SUTEE';

  v_row := sri_os.fn_audit_row_id('user_owner_access', array['user_id', 'owner_id'],
             jsonb_build_object('user_id', pg_temp.xuid('x_leaver'), 'owner_id', v_owner));

  insert into sri_os.user_owner_access(user_id, owner_id)
  values (pg_temp.xuid('x_leaver'), v_owner);
  delete from sri_os.user_owner_access
   where user_id = pg_temp.xuid('x_leaver') and owner_id = v_owner;

  select count(*) into n from sri_os.audit_log
   where table_name = 'user_owner_access' and row_id = v_row;
  if n <> 2 then
    raise exception 'FAIL: ให้สิทธิ์แล้วถอนสิทธิ์ควรมีร่องรอย 2 แถว แต่ได้ % แถว → "ใครถอนเมื่อไหร่" ตอบไม่ได้', n;
  end if;
  if not exists (select 1 from sri_os.audit_log
                  where table_name = 'user_owner_access' and row_id = v_row
                    and action = 'delete'
                    and (before ->> 'user_id')::uuid = pg_temp.xuid('x_leaver')
                    and (before ->> 'owner_id')::uuid = v_owner) then
    raise exception 'FAIL: ร่องรอยการถอนสิทธิ์ไม่บอกว่าถอนขอบเขตของใครออกจากผู้ถือไหน';
  end if;

  -- UPDATE ที่ย้ายขอบเขตไปผู้ถืออื่น: row_id เป็นของคีย์ใหม่ แต่คีย์เก่าต้องอ่านได้จาก before
  insert into sri_os.user_owner_access(user_id, owner_id)
  values (pg_temp.xuid('x_leaver'), v_owner);
  update sri_os.user_owner_access set owner_id = v_owner2
   where user_id = pg_temp.xuid('x_leaver') and owner_id = v_owner;
  if not exists (select 1 from sri_os.audit_log
                  where table_name = 'user_owner_access' and action = 'update'
                    and (before ->> 'owner_id')::uuid = v_owner
                    and (after  ->> 'owner_id')::uuid = v_owner2) then
    raise exception 'FAIL: ย้ายขอบเขตการเห็นข้ามผู้ถือแล้วไม่เห็นว่าย้ายมาจากไหน (before ต้องเก็บคีย์เดิม)';
  end if;
  delete from sri_os.user_owner_access
   where user_id = pg_temp.xuid('x_leaver') and owner_id = v_owner2;

  raise notice 'ok X2 · ให้/ถอน/ย้ายขอบเขตการเห็นเงิน เหลือร่องรอยครบ และบอกได้ว่าเป็นขอบเขตของใครกับผู้ถือไหน';
end $$;

-- ============================================================
-- X3 · ลบ app_users → cascade ลบ user_owner_access
--      ขา cascade ต้องมีร่องรอย **ทั้งสองตาราง** (กันแต่ตารางแม่ไม่พอ)
-- ============================================================
do $$
declare v_u uuid := gen_random_uuid(); v_owner uuid; n_acc int; n_usr int;
begin
  select id into v_owner from sri_os.owners where code = 'SRI_CORP';
  insert into auth.users(id) values (v_u);
  insert into sri_os.app_users(id, email, display_name, role)
  values (v_u, 'cascade@acc.local', 'cascade', 'staff');
  insert into sri_os.user_owner_access(user_id, owner_id) values (v_u, v_owner);

  delete from sri_os.app_users where id = v_u;

  select count(*) into n_usr from sri_os.audit_log
   where table_name = 'app_users' and action = 'delete' and (before ->> 'id')::uuid = v_u;
  select count(*) into n_acc from sri_os.audit_log
   where table_name = 'user_owner_access' and action = 'delete'
     and (before ->> 'user_id')::uuid = v_u;
  if n_usr <> 1 then
    raise exception 'FAIL: ถอนคนออกจากระบบไม่เหลือร่องรอย (% แถว)', n_usr;
  end if;
  if n_acc <> 1 then
    raise exception 'FAIL: ขอบเขตการเห็นเงินหายไปตาม cascade โดยไม่เหลือร่องรอย (% แถว) → ย้อนไม่ได้ว่าคนนั้นเคยเห็นเงินของใคร · ต้องติด audit ที่ user_owner_access เองไม่ใช่กันแต่ app_users', n_acc;
  end if;
  if exists (select 1 from sri_os.user_owner_access where user_id = v_u) then
    raise exception 'FAIL: cascade ไม่ทำงาน — แถวสิทธิ์ยังอยู่ทั้งที่ผู้ใช้ถูกลบ';
  end if;
  raise notice 'ok X3 · ถอนคนออกได้ตามเจตนา และขา cascade ของขอบเขตการเห็นเงินเหลือร่องรอยครบทั้งสองตาราง';
end $$;

-- ============================================================
-- X4 · FK กันลบคู่ค้าที่ผูก transactions จริง (ยืนยัน ไม่ใช่เชื่อ)
--      ถ้าวันหนึ่งกลายเป็น set null/cascade → รายการชี้ไปที่ว่าง = เรื่องใหญ่
-- ============================================================
do $$
declare v_state text; n int;
begin
  v_state := pg_temp.xfail('ลบคู่ค้าที่ผูกรายการในสมุดบัญชี',
    $q$delete from sri_os.contacts where id = '00000000-0000-0000-0000-0000000000a1'$q$);
  if v_state <> '23503' then
    raise exception 'FAIL: ลบคู่ค้าที่ผูกรายการถูกปฏิเสธด้วย % (คาด 23503 foreign_key_violation) — ถ้าไม่ใช่ FK แปลว่าด่านอยู่ที่อื่นและอาจหลุดได้', v_state;
  end if;
  select count(*) into n from sri_os.contacts where id = '00000000-0000-0000-0000-0000000000a1';
  if n <> 1 then raise exception 'FAIL: คู่ค้าหายไปทั้งที่คำสั่งถูกปฏิเสธ'; end if;
  if not exists (select 1 from sri_os.transactions
                  where id = '00000000-0000-0000-0000-0000000000d1'
                    and contact_id = '00000000-0000-0000-0000-0000000000a1') then
    raise exception 'FAIL: รายการในสมุดบัญชีชี้ไปที่ว่างแล้ว (contact_id ถูกล้าง) = FK เป็น set null';
  end if;
  -- FK ต้องเป็น NO ACTION/RESTRICT ที่ตัวข้อจำกัดเอง ไม่ใช่กันได้เพราะจังหวะ
  if exists (select 1 from pg_constraint
              where contype = 'f' and confrelid = 'sri_os.contacts'::regclass
                and conrelid = 'sri_os.transactions'::regclass
                and (confdeltype <> 'a')) then
    raise exception 'FAIL: FK transactions.contact_id ไม่ใช่ NO ACTION แล้ว → ลบคู่ค้าได้โดยรายการชี้ไปที่ว่าง';
  end if;
  raise notice 'ok X4 · FK กันลบคู่ค้าที่ผูกรายการจริง (23503) และแถวทั้งสองฝั่งยังครบ';
end $$;

-- ============================================================
-- X5 · FK กันลบคู่ค้าที่ผูก contracts จริง
-- ============================================================
do $$
declare v_state text;
begin
  v_state := pg_temp.xfail('ลบคู่ค้าที่เป็นคู่สัญญา',
    $q$delete from sri_os.contacts where id = '00000000-0000-0000-0000-0000000000a2'$q$);
  if v_state <> '23503' then
    raise exception 'FAIL: ลบคู่สัญญาถูกปฏิเสธด้วย % (คาด 23503)', v_state;
  end if;
  if not exists (select 1 from sri_os.contracts
                  where id = '00000000-0000-0000-0000-0000000000c3'
                    and counterparty_contact_id = '00000000-0000-0000-0000-0000000000a2') then
    raise exception 'FAIL: สัญญาชี้ไปที่คู่สัญญาว่างแล้ว';
  end if;
  if exists (select 1 from pg_constraint
              where contype = 'f' and confrelid = 'sri_os.contacts'::regclass
                and conrelid = 'sri_os.contracts'::regclass and confdeltype <> 'a') then
    raise exception 'FAIL: FK contracts.counterparty_contact_id ไม่ใช่ NO ACTION แล้ว';
  end if;
  raise notice 'ok X5 · FK กันลบคู่ค้าที่เป็นคู่สัญญาจริง (23503)';
end $$;

-- ============================================================
-- X6 · ลบคู่ค้าที่ยังไม่ผูกรายการได้ · ขา cascade ของ contact_links ต้องมีร่องรอย
-- ============================================================
do $$
declare n_c int; n_l int;
begin
  perform pg_temp.xrows('ลบคู่ค้าที่ยังไม่ผูกรายการ',
    $q$delete from sri_os.contacts where id = '00000000-0000-0000-0000-0000000000a3'$q$, 1);

  select count(*) into n_c from sri_os.audit_log
   where table_name = 'contacts' and action = 'delete'
     and (before ->> 'id')::uuid = '00000000-0000-0000-0000-0000000000a3';
  select count(*) into n_l from sri_os.audit_log
   where table_name = 'contact_links' and action = 'delete'
     and (before ->> 'id')::uuid = '00000000-0000-0000-0000-0000000000b1';
  if n_c <> 1 then raise exception 'FAIL: ลบคู่ค้าไม่เหลือร่องรอย (% แถว)', n_c; end if;
  if n_l <> 1 then
    raise exception 'FAIL: แถวเชื่อมโยงหายตาม cascade โดยไม่เหลือร่องรอย (% แถว) → ต้องติด audit ที่ contact_links เอง ไม่ใช่กันแต่ตารางแม่', n_l;
  end if;
  if exists (select 1 from sri_os.contact_links
              where contact_id = '00000000-0000-0000-0000-0000000000a3') then
    raise exception 'FAIL: cascade ของ contact_links ไม่ทำงาน';
  end if;
  raise notice 'ok X6 · ลบคู่ค้าที่ยังไม่ผูกรายการได้ และขา cascade ของความเชื่อมโยงเหลือร่องรอย';
end $$;

-- ============================================================
-- X7 · app_users · owners — audit ทำงานจริงทั้งสามคำสั่ง
--      owners ไม่ได้อยู่ในรายการที่สั่งมา แต่แอปเขียนได้ตอนรันจริง (owners_write)
-- ============================================================
do $$
declare v_u uuid := gen_random_uuid(); v_o uuid := gen_random_uuid(); n int;
begin
  insert into auth.users(id) values (v_u);
  insert into sri_os.app_users(id, email, display_name, role)
  values (v_u, 'audit3@acc.local', 'audit3', 'staff');
  update sri_os.app_users set role = 'manager' where id = v_u;
  update sri_os.app_users set is_active = false where id = v_u;
  delete from sri_os.app_users where id = v_u;
  select count(*) into n from sri_os.audit_log
   where table_name = 'app_users' and row_id = v_u;
  if n <> 4 then
    raise exception 'FAIL: app_users ควรมีร่องรอย 4 แถว (insert + 2 update + delete) แต่ได้ %', n;
  end if;
  if not exists (select 1 from sri_os.audit_log where table_name = 'app_users' and row_id = v_u
                  and action = 'update' and before ->> 'role' = 'staff'
                  and after ->> 'role' = 'manager') then
    raise exception 'FAIL: เลื่อน/เปลี่ยนตำแหน่งคนแล้วไม่เห็นว่าเปลี่ยนจากอะไรเป็นอะไร = เปลี่ยนสิทธิ์เงียบๆ';
  end if;

  insert into sri_os.owners(id, code, name_th, type, policy)
  values (v_o, 'AA_TEST', 'ผู้ถือเทสต์ร่องรอย', 'person', 'personal_flexible');
  update sri_os.owners set name_th = 'ผู้ถือเทสต์ร่องรอย (แก้ชื่อ)' where id = v_o;
  delete from sri_os.owners where id = v_o;
  select count(*) into n from sri_os.audit_log
   where table_name = 'owners' and row_id = v_o;
  if n <> 3 then
    raise exception 'FAIL: owners ควรมีร่องรอย 3 แถว แต่ได้ % — ทุกแถวในระบบมี owner_id การเพิ่ม/ลบผู้ถือจึงต้องเห็น', n;
  end if;
  raise notice 'ok X7 · app_users (รวมการเปลี่ยนตำแหน่ง) และ owners มีร่องรอยครบทั้งสามคำสั่ง';
end $$;

-- ============================================================
-- X8 · ตรึงพฤติกรรมที่รายงานไว้: ถอนคนที่เคยลงรายการด้วย DELETE จะติด FK
--      → เส้นทางจริงคือ is_active = false ซึ่งต้องมีร่องรอย
--      (ไม่ได้แก้ให้ในรอบนี้โดยตั้งใจ · เทสต์นี้ทำให้มันไม่เงียบ)
-- ============================================================
do $$
declare v_state text;
begin
  v_state := pg_temp.xfail('ลบผู้ใช้ที่เคยลงรายการในสมุดบัญชี',
    format($q$delete from sri_os.app_users where id = %L$q$, pg_temp.xuid('x_poster')));
  if v_state <> '23503' then
    raise exception 'FAIL: ลบผู้ใช้ที่เคยลงรายการถูกปฏิเสธด้วย % (คาด 23503) — ถ้าลบได้แปลว่ารายการในสมุดบัญชีชี้ไปที่คนที่ไม่มีอยู่', v_state;
  end if;
  perform pg_temp.xrows('ปิดการใช้งานผู้ใช้ (เส้นทางจริงของการถอนคนออก)',
    format($q$update sri_os.app_users set is_active = false where id = %L$q$, pg_temp.xuid('x_poster')), 1);
  if not exists (select 1 from sri_os.audit_log
                  where table_name = 'app_users' and row_id = pg_temp.xuid('x_poster')
                    and action = 'update' and (before ->> 'is_active')::boolean
                    and not (after ->> 'is_active')::boolean) then
    raise exception 'FAIL: ปิดการใช้งานผู้ใช้ไม่เหลือร่องรอย → ถอนคนออกจากระบบเงียบๆ ได้ (เส้นทางนี้คือเส้นทางที่ใช้ได้จริง เพราะ DELETE ติด FK)';
  end if;
  perform pg_temp.xrows('เปิดกลับ',
    format($q$update sri_os.app_users set is_active = true where id = %L$q$, pg_temp.xuid('x_poster')), 1);
  raise notice 'ok X8 · DELETE ผู้ใช้ที่เคยลงรายการติด FK (23503) ตามที่รายงานไว้ · เส้นทางจริง is_active = false ทำได้และมีร่องรอย';
end $$;

-- ============================================================
-- X9 · guard "ทุกตารางใน sri_os ต้องมี audit" + เงื่อนไขของ allow-list ทุกตัว
--      ข้อนี้คือชั้นที่จับตารางใหม่จริง เพราะ migration รันครั้งเดียว
--      ส่วนเทสต์นี้รันทุกรอบบนสคีมาที่รวม migration ใหม่ทุกไฟล์แล้ว
-- ============================================================
do $$
declare
  c_append_only text[] := array['audit_log', 'asset_valuations'];
  c_read_only   text[] := array['chart_of_accounts', 'txn_types', 'asset_classes',
                                'asset_categories', 'roles', 'permissions',
                                'role_permissions'];
  n int; v text; r text;
begin
  -- (ก) ทุกตารางนอก allow-list ต้องมี audit ครอบ insert+update+delete แบบ after row
  select string_agg(c.relname, ', ' order by c.relname), count(*) into v, n
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os' and c.relkind = 'r'
     and not (c.relname = any (c_append_only)) and not (c.relname = any (c_read_only))
     and not exists (
       select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
        where tg.tgrelid = c.oid and not tg.tgisinternal
          and p.proname in ('fn_audit', 'fn_audit_keyed')
          and (tg.tgtype & 4) <> 0 and (tg.tgtype & 16) <> 0 and (tg.tgtype & 8) <> 0
          and (tg.tgtype & 2) = 0 and (tg.tgtype & 64) = 0 and (tg.tgtype & 1) <> 0);
  if n > 0 then
    raise exception 'FAIL: % ตารางใน sri_os ไม่มี audit ที่ครอบ insert+update+delete: % · ถ้าตารางนั้นไม่ควรมี audit จริงๆ ต้องเพิ่มใน allow-list ของ 20261008000005 พร้อมเหตุผลและเงื่อนไขที่ตรวจด้วยเครื่องได้ ห้ามเว้นเงียบ', n, v;
  end if;
  select count(*) into n from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os' and c.relkind = 'r';
  if n < 25 then
    raise exception 'FAIL: นับตารางใน sri_os ได้แค่ % ตาราง — เทสต์นี้อาจไม่ได้ตรวจอะไรเลย', n;
  end if;

  -- (ข) allow-list กลุ่ม append-only: เหตุผลคือ "แถวเองคือประวัติ"
  --     ถ้า UPDATE/DELETE เปิดได้ เหตุผลตาย → ต้องแดง
  if not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                  where tg.tgrelid = 'sri_os.audit_log'::regclass
                    and p.proname like 'fn\_forbid%'
                    and (tg.tgtype & 8) <> 0 and (tg.tgtype & 16) <> 0) then
    raise exception 'FAIL: audit_log ไม่ append-only แล้ว → เหตุผลที่ยกเว้นมันจาก audit ใช้ไม่ได้';
  end if;
  if not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                  where tg.tgrelid = 'sri_os.asset_valuations'::regclass
                    and p.proname like 'fn\_forbid%' and (tg.tgtype & 8) <> 0) then
    raise exception 'FAIL: asset_valuations ไม่มีด่าน DELETE แล้ว → เหตุผลที่ยกเว้นมันจาก audit ใช้ไม่ได้';
  end if;
  select string_agg(policyname || ' (' || cmd || ')', ', ') into v from pg_policies
   where schemaname = 'sri_os' and tablename = 'asset_valuations'
     and cmd in ('UPDATE', 'DELETE', 'ALL');
  if v is not null then
    raise exception 'FAIL: asset_valuations มี policy % → ไม่ใช่ append-only อีกแล้ว ต้องมี audit', v;
  end if;

  -- (ค) allow-list กลุ่มตารางกฎ/อ้างอิง: เหตุผลคือ "แอปเขียนไม่ได้เลย
  --     เส้นทางเดียวคือ migration ที่เป็นไฟล์ใน git"
  --     มี policy เขียนแม้ตัวเดียว = เหตุผลตาย (ตารางกฎคือคู่บัญชีของทุกรายการ)
  select string_agg(tablename || '.' || policyname || ' (' || cmd || ')', ', ') into v
    from pg_policies
   where schemaname = 'sri_os' and tablename = any (c_read_only) and cmd <> 'SELECT';
  if v is not null then
    raise exception 'FAIL: ตารางกฎ/อ้างอิงมี policy เขียน: % · เหตุผลที่ยกเว้นจาก audit ใช้ไม่ได้อีก → แก้คู่บัญชีได้จากหน้าจอโดยไม่เหลือร่องรอย', v;
  end if;
  -- และ RLS ต้องยังเปิดอยู่ ไม่ใช่ปิด RLS แล้วไม่มี policy ให้นับ
  select string_agg(c.relname, ', ') into v
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os' and c.relname = any (c_read_only) and not c.relrowsecurity;
  if v is not null then
    raise exception 'FAIL: ตารางกฎ/อ้างอิงที่ RLS ปิดอยู่: % → "แอปเขียนไม่ได้" ไม่จริงอีกแล้ว', v;
  end if;

  -- (ง) allow-list ต้องอ้างตารางที่มีอยู่จริง (สะกดผิด = ยกเว้นของที่ไม่มี แล้วของจริงหลุด)
  foreach r in array c_append_only || c_read_only loop
    if not exists (select 1 from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
                    where ns.nspname = 'sri_os' and c.relkind = 'r' and c.relname = r) then
      raise exception 'FAIL: allow-list อ้างตารางที่ไม่มีอยู่: sri_os.%', r;
    end if;
  end loop;

  raise notice 'ok X9 · ทุกตารางใน sri_os มี audit ครบสามคำสั่ง ยกเว้น allow-list % ตารางที่เงื่อนไขยังจริงอยู่',
    cardinality(c_append_only) + cardinality(c_read_only);
end $$;

-- X9b · **พิสูจน์ว่า guard จับตารางใหม่ได้จริง** (ไม่ใช่แค่ผ่านเพราะวันนี้ครบ)
--       สร้างตารางใหม่ใน sri_os ชั่วคราวแล้วรันคำถามเดียวกัน ต้องเจอ
do $$
declare n int;
begin
  create table sri_os.zz_probe_no_audit (id uuid primary key default gen_random_uuid());
  select count(*) into n
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os' and c.relkind = 'r' and c.relname = 'zz_probe_no_audit'
     and not exists (
       select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
        where tg.tgrelid = c.oid and not tg.tgisinternal
          and p.proname in ('fn_audit', 'fn_audit_keyed'));
  drop table sri_os.zz_probe_no_audit;
  if n <> 1 then
    raise exception 'FAIL: คำถามที่ใช้หา "ตารางที่ไม่มี audit" หาตารางใหม่ที่ไม่มี audit ไม่เจอ → guard ของ X9 ผ่านฟรีๆ';
  end if;
  raise notice 'ok X9b · คำถามของ guard จับตารางใหม่ที่ไม่มี audit ได้จริง (ไม่ได้ผ่านเพราะคำถามว่างเปล่า)';
end $$;

-- ============================================================
-- X10 · ข้ออ้าง "สี่ตารางนั้นมี audit แล้ว" ต้องพิสูจน์ **ตอน DELETE**
--       assets · bank_accounts · draft_entries · asset_drafts
--       (วันนี้เจอมาแล้วว่า audit ที่อ้างว่าครอบ บางทีครอบแค่ขาเดียว)
-- ============================================================
do $$
declare
  v_o uuid; v_cls uuid; v_cat uuid;
  v_a uuid := gen_random_uuid(); v_b uuid := gen_random_uuid();
  v_d uuid := gen_random_uuid(); v_ad uuid := gen_random_uuid();
  r record; n int;
begin
  select id into v_o from sri_os.owners where code = 'SRI_CORP';
  select id, class_id into v_cat, v_cls from sri_os.asset_categories order by code limit 1;

  insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
  values (v_b, v_o, 'KBANK', 'บัญชีเทสต์ X10', 'บัญชีเทสต์ X10');
  insert into sri_os.assets(id, code, name, class_id, category_id, owner_id)
  values (v_a, 'AA-X10', 'ทรัพย์เทสต์ X10', v_cls, v_cat, v_o);
  insert into sri_os.draft_entries(id, owner_id, txn_type_code, doc_date, amount, status, created_by)
  values (v_d, v_o, 'inc.other', current_date, 100, 'pending', pg_temp.xuid('x_staff'));
  insert into sri_os.asset_drafts(id, kind, owner_id, name, class_id, category_id, created_by)
  values (v_ad, 'create', v_o, 'ร่างเทสต์ X10', v_cls, v_cat, pg_temp.xuid('x_staff'));

  delete from sri_os.draft_entries where id = v_d;
  delete from sri_os.asset_drafts  where id = v_ad;
  delete from sri_os.assets        where id = v_a;
  delete from sri_os.bank_accounts where id = v_b;

  for r in select * from (values ('draft_entries', v_d), ('asset_drafts', v_ad),
                                 ('assets', v_a), ('bank_accounts', v_b)) as t(tbl, rid)
  loop
    select count(*) into n from sri_os.audit_log
     where table_name = r.tbl and row_id = r.rid and action = 'delete';
    if n <> 1 then
      raise exception 'FAIL: ลบแถวใน sri_os.% แล้วไม่เหลือร่องรอย (% แถว) — ข้ออ้างว่า "ตารางนี้มี audit แล้ว" ครอบแค่ insert/update', r.tbl, n;
    end if;
    select count(*) into n from sri_os.audit_log
     where table_name = r.tbl and row_id = r.rid and action = 'insert';
    if n <> 1 then
      raise exception 'FAIL: เพิ่มแถวใน sri_os.% ไม่เหลือร่องรอย (% แถว)', r.tbl, n;
    end if;
  end loop;
  raise notice 'ok X10 · audit ของ assets · bank_accounts · draft_entries · asset_drafts ทำงานจริง **ตอน DELETE** ไม่ใช่แค่ INSERT';
end $$;

-- ============================================================
-- X11 · เคส "ไม่ส่งข้อมูล" ของ audit เอง — ต้องปฏิเสธ ไม่ใช่เดา
--       ร่องรอยที่ชี้ผิดแถวแย่กว่าไม่มีร่องรอย เพราะคนจะเชื่อมัน
-- ============================================================
do $$
declare v_state text; n_before bigint; n_after bigint;
begin
  -- (ก) DELETE ที่ไม่ตรงแถวไหนเลย: ไม่ error และต้องไม่เขียนร่องรอย
  select count(*) into n_before from sri_os.audit_log;
  perform pg_temp.xrows('ลบค่าตั้งค่าที่ไม่มีอยู่',
    $q$delete from sri_os.settings where key = 'acc.ไม่มีคีย์นี้'$q$, 0);
  perform pg_temp.xrows('ถอนสิทธิ์ที่ไม่มีอยู่',
    $q$delete from sri_os.user_owner_access where user_id = '00000000-0000-0000-0000-0000000000ff'$q$, 0);
  select count(*) into n_after from sri_os.audit_log;
  if n_after <> n_before then
    raise exception 'FAIL: คำสั่งที่ไม่ตรงแถวไหนเลยเขียนร่องรอยเพิ่ม % แถว → audit_log มีแถวที่ไม่มีเหตุการณ์จริง',
      n_after - n_before;
  end if;

  -- (ข) trigger ที่ **ไม่ส่งคีย์** ต้องถูกปฏิเสธ ไม่ใช่เขียน row_id ที่เดาเอง
  create trigger zz_probe_nokey after insert on sri_os.settings
    for each row execute function sri_os.fn_audit_keyed();
  drop trigger trg_audit_settings on sri_os.settings;
  v_state := pg_temp.xfail('audit ที่ไม่ได้ประกาศคีย์',
    $q$insert into sri_os.settings(key, value) values ('acc.nokey', '{}'::jsonb)$q$);
  if v_state <> 'P0001' then
    raise exception 'FAIL: fn_audit_keyed ที่ไม่ได้รับคีย์ถูกปฏิเสธด้วย % (คาด P0001 raise_exception) — ถ้าปล่อยผ่าน row_id จะชี้ผิดแถวเงียบๆ', v_state;
  end if;
  drop trigger zz_probe_nokey on sri_os.settings;

  -- (ค) trigger ที่ส่ง **คอลัมน์ที่ไม่มี** ต้องถูกปฏิเสธ (คีย์เปลี่ยนแล้วลืมแก้ trigger)
  create trigger zz_probe_badkey after insert on sri_os.settings
    for each row execute function sri_os.fn_audit_keyed('ไม่มีคอลัมน์นี้');
  v_state := pg_temp.xfail('audit ที่ชี้คอลัมน์คีย์ผิด',
    $q$insert into sri_os.settings(key, value) values ('acc.badkey', '{}'::jsonb)$q$);
  if v_state <> 'P0001' then
    raise exception 'FAIL: fn_audit_keyed ที่ชี้คอลัมน์ไม่มีจริงถูกปฏิเสธด้วย % (คาด P0001)', v_state;
  end if;
  drop trigger zz_probe_badkey on sri_os.settings;

  -- (ง) คีย์ที่เป็น null ต้องถูกปฏิเสธ (ร่องรอยชี้กลับไปหาแถวไม่ได้)
  create trigger zz_probe_nullkey after insert on sri_os.settings
    for each row execute function sri_os.fn_audit_keyed('updated_by');
  v_state := pg_temp.xfail('audit ที่คีย์เป็น null',
    $q$insert into sri_os.settings(key, value) values ('acc.nullkey', '{}'::jsonb)$q$);
  if v_state <> 'P0001' then
    raise exception 'FAIL: fn_audit_keyed ที่คีย์เป็น null ถูกปฏิเสธด้วย % (คาด P0001)', v_state;
  end if;
  drop trigger zz_probe_nullkey on sri_os.settings;

  -- (จ) **พิสูจน์ว่า fn_audit เดิมใช้กับตารางไร้ id ไม่ได้** = เหตุผลของ fn_audit_keyed มีจริง
  --     ถ้าวันหนึ่งใครเปลี่ยนไปใช้ fn_audit "ให้เหมือนตารางอื่น" ทุก mutation จะล้ม
  create trigger zz_probe_plain after insert on sri_os.settings
    for each row execute function sri_os.fn_audit();
  v_state := pg_temp.xfail('fn_audit กับตารางที่ไม่มี id uuid',
    $q$insert into sri_os.settings(key, value) values ('acc.plain', '{}'::jsonb)$q$);
  if v_state <> '42703' then
    raise exception 'FAIL: fn_audit กับ settings ควรล้มด้วย 42703 (record "new" has no field "id") แต่ได้ % — ถ้าไม่ล้มแล้วก็ไม่ต้องมี fn_audit_keyed', v_state;
  end if;
  drop trigger zz_probe_plain on sri_os.settings;

  -- คืน trigger จริงให้ครบก่อนออกจากข้อนี้
  create trigger trg_audit_settings after insert or update or delete on sri_os.settings
    for each row execute function sri_os.fn_audit_keyed('key');

  raise notice 'ok X11 · คำสั่งที่ไม่ตรงแถวไม่เขียนร่องรอย · audit ที่ไม่ได้คีย์/คีย์ผิด/คีย์ null ถูกปฏิเสธ · และ fn_audit เดิมใช้กับตารางไร้ id uuid ไม่ได้จริง';
end $$;

-- ============================================================
-- X12 · **เส้นทางที่ถูกต้องต้องยังทำได้** ในฐานะ authenticated จริง
--       (ผ่านชั้น GRANT + RLS + trigger ทั้งหมด) · บทเรียนข้อ 7
-- ============================================================
-- (ก) บริหารคนและขอบเขตการเห็น — ต้องมี users.manage (super_admin)
do $$
declare v_u uuid := gen_random_uuid(); v_o uuid;
begin
  select id into v_o from sri_os.owners where code = 'SRI_CORP';
  insert into auth.users(id) values (v_u);
  perform pg_temp.xlogin('x_super');
  execute 'set local role authenticated';

  perform pg_temp.xpass('เพิ่มคนเข้าระบบ', format(
    $q$insert into sri_os.app_users(id, email, display_name, role) values (%L, 'new@acc.local', 'คนใหม่', 'staff')$q$, v_u));
  perform pg_temp.xrows('เปลี่ยนตำแหน่ง', format(
    $q$update sri_os.app_users set role = 'manager' where id = %L$q$, v_u), 1);
  perform pg_temp.xpass('เพิ่มขอบเขตการเห็นผู้ถือ', format(
    $q$insert into sri_os.user_owner_access(user_id, owner_id) values (%L, %L)$q$, v_u, v_o));
  perform pg_temp.xrows('ถอนขอบเขตการเห็นผู้ถือ', format(
    $q$delete from sri_os.user_owner_access where user_id = %L and owner_id = %L$q$, v_u, v_o), 1);
  perform pg_temp.xrows('ปิดการใช้งานคน (ถอนคนออกแบบที่ใช้ได้จริง)', format(
    $q$update sri_os.app_users set is_active = false where id = %L$q$, v_u), 1);
  perform pg_temp.xrows('ถอนคนออกจากระบบ (คนที่ยังไม่เคยลงรายการ)', format(
    $q$delete from sri_os.app_users where id = %L$q$, v_u), 1);

  execute 'reset role';
  raise notice 'ok X12a · เพิ่มคน · เปลี่ยนตำแหน่ง · เพิ่ม-ถอนขอบเขตการเห็น · ปิดการใช้งาน · ถอนคนออก ยังทำได้ครบในฐานะ authenticated';
exception when others then
  execute 'reset role';
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: เส้นทางบริหารคน/สิทธิ์ของ authenticated ล้ม (%) — กฎใหม่กันแน่นเกิน', sqlerrm;
end $$;

-- (ข) ค่าตั้งค่า · คู่ค้า · ความเชื่อมโยง · ผู้ถือ — ต้องมี settings.manage (management)
do $$
declare v_c uuid := gen_random_uuid(); v_o uuid := gen_random_uuid();
begin
  perform pg_temp.xlogin('x_mgmt');
  execute 'set local role authenticated';

  perform pg_temp.xpass('ตั้งค่าใหม่',
    $q$insert into sri_os.settings(key, value) values ('acc.app', '{"on":true}'::jsonb)$q$);
  perform pg_temp.xrows('แก้ค่าตั้งค่า',
    $q$update sri_os.settings set value = '{"on":false}'::jsonb where key = 'acc.app'$q$, 1);
  perform pg_temp.xrows('ลบค่าตั้งค่า',
    $q$delete from sri_os.settings where key = 'acc.app'$q$, 1);

  perform pg_temp.xpass('เพิ่มคู่ค้า', format(
    $q$insert into sri_os.contacts(id, first_name, types) values (%L, 'คู่ค้าใหม่', array['tenant'])$q$, v_c));
  perform pg_temp.xrows('แก้คู่ค้า', format(
    $q$update sri_os.contacts set phone = '02-000-0000' where id = %L$q$, v_c), 1);
  perform pg_temp.xpass('เพิ่มความเชื่อมโยงของคู่ค้า', format(
    $q$insert into sri_os.contact_links(contact_id, target_type, target_id, role) values (%L, 'asset', '00000000-0000-0000-0000-0000000000c1', 'tenant')$q$, v_c));
  perform pg_temp.xrows('ถอนความเชื่อมโยง', format(
    $q$delete from sri_os.contact_links where contact_id = %L$q$, v_c), 1);

  perform pg_temp.xpass('เพิ่มผู้ถือฝั่งบุคคล', format(
    $q$insert into sri_os.owners(id, code, name_th, type, policy) values (%L, 'AA_APP', 'ผู้ถือใหม่', 'person', 'personal_flexible')$q$, v_o));

  execute 'reset role';
  raise notice 'ok X12b · ตั้งค่า-แก้-ลบค่าตั้งค่า · เพิ่ม-แก้คู่ค้า · เพิ่ม-ถอนความเชื่อมโยง · เพิ่มผู้ถือ ยังทำได้ครบในฐานะ authenticated';
exception when others then
  execute 'reset role';
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: เส้นทางค่าตั้งค่า/คู่ค้า/ผู้ถือของ authenticated ล้ม (%) — กฎใหม่กันแน่นเกิน', sqlerrm;
end $$;

-- (ค) สมุดบัญชีและงวด — กฎของรอบนี้ต้องไม่กระทบ post/void/reverse และ ปิด-เปิดงวด
do $$
declare n int; v_o uuid;
begin
  select id into v_o from sri_os.owners where code = 'SRI_CORP';
  perform pg_temp.xlogin('x_mgmt');
  execute 'set local role authenticated';

  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, attachments)
  values ('00000000-0000-0000-0000-0000000000e1', v_o, 'inc.other', current_date, array['หลักฐาน-X12.pdf']);
  insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
  select '00000000-0000-0000-0000-0000000000e1', c.id,
         case when c.rn = 1 then 120 else 0 end,
         case when c.rn = 2 then 120 else 0 end
    from (select c2.id, v.rn from sri_os.chart_of_accounts c2 join (values ('1220', 1), ('4900', 2)) as v(code, rn) on v.code = c2.code) c;

  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, source, reverses_id, attachments)
  values ('00000000-0000-0000-0000-0000000000e2', v_o, 'inc.other', current_date,
          'reverse', '00000000-0000-0000-0000-0000000000e1', '{}');
  insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
  select '00000000-0000-0000-0000-0000000000e2', l.coa_id, l.credit, l.debit
    from sri_os.transaction_lines l
   where l.transaction_id = '00000000-0000-0000-0000-0000000000e1';

  -- void **ใบกลับรายการ** ไม่ใช่ต้นฉบับ (D-097: ต้นฉบับที่ถูกกลับรายการต้องยัง posted
  -- ไม่งั้นสมุดผิดไป −ต้นฉบับ · trg_void_blocked_by_reverse ปฏิเสธเส้นทางเดิมแล้ว)
  update sri_os.transactions set status = 'void'
   where id = '00000000-0000-0000-0000-0000000000e2';

  insert into sri_os.period_closes(owner_id, period, closed_by)
  values (v_o, date_trunc('month', current_date)::date, pg_temp.xuid('x_mgmt'));
  delete from sri_os.period_closes
   where owner_id = v_o and period = date_trunc('month', current_date)::date;
  get diagnostics n = row_count;
  execute 'reset role';
  if n <> 1 then
    raise exception 'FAIL: เปิดงวดใหม่ไม่ได้ (% แถว) — สิทธิ์ period.reopen ต้องยังใช้ได้', n;
  end if;
  raise notice 'ok X12c · post + reverse + void · ปิดงวดและเปิดงวดใหม่ ยังทำได้ครบ (กฎของรอบนี้ไม่กระทบสมุดบัญชี)';
exception when others then
  execute 'reset role';
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: เส้นทางสมุดบัญชี/งวดของ authenticated ล้ม (%) — กฎใหม่กันแน่นเกิน', sqlerrm;
end $$;

do $$ begin raise notice '=== access audit ผ่านทั้งหมด ==='; end $$;

rollback;
