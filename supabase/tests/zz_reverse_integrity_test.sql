-- ============================================================
-- SRI OS · เทสต์ความสมบูรณ์ของกลไกกลับรายการ (reverse) · D-097
--   migration ที่ทดสอบ: 20261009000000_reverse_integrity.sql
--
-- สามรูที่ปิดในรอบนี้ (ตาม D-097 ข้อ 1-3):
--   รูที่ 1 · ใบกลับรายการต้องสะท้อนบรรทัดของต้นฉบับแบบสลับด้าน
--            เดิมไม่มีอะไรตรวจบรรทัดเลย + corporate_strict ยกเว้นหลักฐานให้ใบ reverse
--            → ตั้ง source='reverse' ชี้ใบจริงใบเล็ก แล้วลงเงินเท่าไหร่ก็ได้ ไม่ต้องแนบหลักฐาน
--   รูที่ 2 · void กับ reverse ปนกันไม่ได้ (ต้นฉบับ void แต่ใบกลับยัง posted = สมุดผิดไป −ต้นฉบับ)
--   รูที่ 3 · void รายการในงวดที่ปิดแล้วไม่ได้ (corporate_strict) — trg_period_locked
--            เป็น before insert เท่านั้น → UPDATE เป็น void เปลี่ยนงบที่ยื่นไปแล้วเงียบๆ
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ **rollback** ปิดท้าย — ไม่ทิ้งรายการเงินไว้
--   ด่านของรูที่ 1 เป็น `constraint trigger ... deferrable initially deferred`
--   (ตอน insert หัวรายการ บรรทัดยังไม่เกิด) → เคสปฏิเสธจึงต้องยิง
--   `set constraints all immediate` เองเพื่อให้ด่านทำงานภายในเทสต์ (แพทเทิร์นเดียวกับ
--   G6b ของ zz_line_guards_test) แล้วคืนสภาพ deferred เหมือนที่ fn_post_entry ทำ
--
-- รันในฐานะ superuser ของ cluster = ข้าม RLS แต่ **trigger ยังทำงานทุกเส้นทาง**
--   (กฎเงินต้องไม่ขึ้นกับสิทธิ์ · R1c เดินเส้นทางจริงด้วย role authenticated ซ้ำอีกชั้น)
--
-- mutation ที่ต้องทำให้เทสต์แดง (ถ้าไม่แดง = เทสต์ยังไม่ครอบ):
--   M1 ด่านสะท้อนบรรทัด return true ทุกกรณี     → R2 R3 R4 R5 R6 R7 R8 R9 R10 แดง
--   M2 ตัด except all ให้เหลือทิศเดียว           → R9 แดง
--   M3 ถอดเงื่อนไข void ออกจาก fn_reverse_link_ok → R11 แดง
--   M4 ด่านงวดปิดไม่ยิงตอน update                → R14a แดง
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
create temporary table t_ruid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_ruid(label) values ('r_mgmt');
insert into auth.users(id) select id from t_ruid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select id, label || '@reverse.local', label, 'management', true from t_ruid;
insert into sri_os.user_owner_access(user_id, owner_id)
select (select id from t_ruid where label = 'r_mgmt'), o.id from sri_os.owners o;

create or replace function pg_temp.ruid(p_label text) returns uuid
language sql stable as $fn$ select id from t_ruid where label = p_label $fn$;

create or replace function pg_temp.rlogin(p_label text) returns void
language sql as $fn$
  select set_config('test.uid', coalesce((select id::text from t_ruid where label = p_label), ''), true);
$fn$;

create or replace function pg_temp.coa(p_code text) returns uuid
language sql stable as $fn$
  select id from sri_os.chart_of_accounts where code = p_code
$fn$;

insert into sri_os.contacts(id, first_name, types)
values ('00000000-0000-0000-0000-00000000bc01', 'คู่ค้า RV', array['tenant'])
on conflict do nothing;

-- ------------------------------------------------------------
-- ตัวช่วย
-- ------------------------------------------------------------
-- เคสที่ "ควรถูกปฏิเสธแต่สำเร็จ" ต้อง **ย้อนของที่เพิ่งเขียนทิ้งด้วย**
--   ไม่ย้อน = ใบที่ไม่ควรมีอยู่ค้างในสมุดของเทสต์ แล้วเคสถัดไปจะล้มด้วยเหตุผลอื่น
--   (เช่น "กลับรายการซ้ำ") ซึ่งทำให้รายงานผล mutation ชี้ผิดจุด
--   วิธีย้อน: โยน exception ของตัวเองให้ subtransaction ของบล็อกนี้ rollback
create or replace function pg_temp.must_fail_like(p_label text, p_sql text, p_needle text) returns void
language plpgsql as $fn$
declare v text;
begin
  begin
    execute p_sql;
    raise exception 'RV_UNEXPECTED_SUCCESS';
  exception when others then
    v := sqlerrm;
    if v = 'RV_UNEXPECTED_SUCCESS' then
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

-- ยิงด่านที่เลื่อนไว้ทั้งหมดเดี๋ยวนี้ แล้วคืนสภาพ deferred
create or replace function pg_temp.fire() returns void
language plpgsql as $fn$
begin
  set constraints all immediate;
  set constraints all deferred;
end $fn$;

-- ต้นฉบับ: exp.other · Dr 5900 (ค่าใช้จ่ายอื่น) / Cr 2100 (เจ้าหนี้ค้างจ่าย) — ไม่มีขาเงินสด
--   หมวดนี้ **ตั้งค้างจ่ายได้จริง** (can_accrue = true) จึงลงบรรทัด 2100 ได้ตามด่าน D-107
create or replace function pg_temp.mk_orig(p_id uuid, p_owner text, p_amt numeric,
                                           p_doc date default current_date,
                                           p_cf text default 'none',
                                           p_asset uuid default null) returns uuid
language plpgsql as $fn$
begin
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, memo, attachments)
  select p_id, o.id, 'exp.other', p_doc, 'RV ต้นฉบับ', array['หลักฐาน-RV.pdf']
    from sri_os.owners o where o.code = p_owner;
  insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit, cf_category, asset_id, memo)
  values (p_id, pg_temp.coa('5900'), p_amt, 0, p_cf::sri_os.cf_group, p_asset, 'ขาค่าใช้จ่าย'),
         (p_id, pg_temp.coa('2100'), 0, p_amt, p_cf::sri_os.cf_group, p_asset, 'ขาเจ้าหนี้');
  perform pg_temp.fire();
  return p_id;
end $fn$;

-- ต้นฉบับที่มีขาเงินสด (ทดสอบ bank_account_id ไม่ตรง)
create or replace function pg_temp.mk_orig_cash(p_id uuid, p_owner text, p_amt numeric,
                                                p_bank uuid) returns uuid
language plpgsql as $fn$
begin
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, cash_date, memo, attachments)
  select p_id, o.id, 'inc.other', current_date, current_date, 'RV ต้นฉบับเงินสด',
         array['หลักฐาน-RV.pdf']
    from sri_os.owners o where o.code = p_owner;
  insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id, debit, credit, cf_category)
  values (p_id, pg_temp.coa('1100'), p_bank, p_amt, 0, 'operating'),
         (p_id, pg_temp.coa('4900'), null,   0, p_amt, 'operating');
  perform pg_temp.fire();
  return p_id;
end $fn$;

-- ใบกลับรายการ: บรรทัดมาจาก jsonb เพื่อให้เคสปฏิเสธเขียนบรรทัด "ที่ไม่สะท้อน" ได้ตรงๆ
--   [{"coa":"5900","dr":700,"cr":0,"cf":"none","asset":null,"bank":null,"memo":"..."}]
create or replace function pg_temp.try_rev(p_id uuid, p_owner text, p_reverses uuid,
                                           p_lines jsonb,
                                           p_att text[] default '{}',
                                           p_type text default 'exp.other') returns void
language plpgsql as $fn$
declare r jsonb;
        v_has_cash boolean;
begin
  -- cash_date ต้องมีเมื่อใบมีขาเงินสด และต้องเป็น null เมื่อไม่มี
  -- (20261009000001_cash_date_invariant) · helper สร้างใบที่ **ถูกต้อง** เสมอ
  -- เคสที่พิสูจน์การปฏิเสธเรื่อง cash_date อยู่ใน zz_cash_date_invariant_test.sql
  -- ซึ่งมี fixture ของตัวเอง ไม่ได้เรียก helper นี้
  select exists (select 1 from jsonb_array_elements(p_lines) x
                  where (x ->> 'coa') ~ '^11[0-9][0-9]$')
    into v_has_cash;

  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, cash_date, memo,
                                  source, reverses_id, attachments)
  select p_id, o.id, p_type, current_date,
         case when v_has_cash then current_date else null end,
         'RV ใบกลับรายการ (memo ไม่ต้องตรงกับต้นฉบับ)',
         'reverse', p_reverses, p_att
    from sri_os.owners o where o.code = p_owner;
  for r in select * from jsonb_array_elements(p_lines) loop
    insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id,
                                         debit, credit, cf_category, asset_id, memo)
    values (p_id, pg_temp.coa(r ->> 'coa'), (r ->> 'bank')::uuid,
            coalesce((r ->> 'dr')::numeric, 0), coalesce((r ->> 'cr')::numeric, 0),
            (r ->> 'cf')::sri_os.cf_group, (r ->> 'asset')::uuid,
            coalesce(r ->> 'memo', 'กลับรายการตามมติ'));
  end loop;
  perform pg_temp.fire();
end $fn$;

-- ภาพกลับด้านของต้นฉบับ (ของที่ "ถูก") — สร้างจากบรรทัดจริงใน DB
create or replace function pg_temp.mirror_of(p_orig uuid) returns jsonb
language sql stable as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
           'coa',  c.code,
           'dr',   l.credit,
           'cr',   l.debit,
           'cf',   l.cf_category,
           'asset', l.asset_id,
           'bank', l.bank_account_id)), '[]'::jsonb)
    from sri_os.transaction_lines l
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where l.transaction_id = p_orig
$fn$;

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
select x.id, o.id, x.bank, x.nm, x.nm
  from (values
    ('00000000-0000-0000-0000-00000000bf01'::uuid, 'SRI_HOLDING', 'SCB',   'RV Holding 1'),
    ('00000000-0000-0000-0000-00000000bf02'::uuid, 'SRI_HOLDING', 'KBANK', 'RV Holding 2'),
    ('00000000-0000-0000-0000-00000000bf03'::uuid, 'SUTEE',       'BBL',   'RV สุธี'),
    ('00000000-0000-0000-0000-00000000bf04'::uuid, 'SRI_CAPITAL', 'SCB',   'RV Capital')
  ) as x(id, own, bank, nm)
  join sri_os.owners o on o.code = x.own;

-- ============================================================
-- R0 · โครงสร้าง — ไล่จาก pg_trigger / pg_proc จริง ไม่ใช่ไล่ไฟล์
-- ============================================================
do $$
declare
  v_defer  boolean; v_init boolean; v_con oid; v_type int;
  v_name   text; v_bad text; v_ok boolean; n int;
begin
  -- (ก) ด่านสะท้อนบรรทัดต้องเป็น constraint trigger ที่เลื่อนได้และเลื่อนไว้โดยปริยาย
  --     ถ้าเป็น before insert ธรรมดา บรรทัดยังไม่เกิด = ด่านที่ตรวจไม่เจออะไรเลย
  select t.tgdeferrable, t.tginitdeferred, t.tgconstraint, t.tgtype
    into v_defer, v_init, v_con, v_type
    from pg_trigger t
   where t.tgrelid = 'sri_os.transactions'::regclass
     and t.tgname = 'trg_reverse_mirrors_original';
  if not found then
    raise exception 'FAIL: ไม่มี trigger trg_reverse_mirrors_original บน transactions';
  end if;
  if not v_defer or not v_init or v_con = 0 then
    raise exception 'FAIL: trg_reverse_mirrors_original ต้องเป็น constraint trigger deferrable initially deferred (deferrable % · initdeferred % · constraint %)',
      v_defer, v_init, v_con;
  end if;
  -- tgtype: 1=ROW · 2=BEFORE · 4=INSERT · 16=UPDATE
  if (v_type & 1) = 0 or (v_type & 4) = 0 or (v_type & 16) = 0 or (v_type & 2) <> 0 then
    raise exception 'FAIL: trg_reverse_mirrors_original ต้องเป็น AFTER INSERT OR UPDATE FOR EACH ROW (tgtype %)', v_type;
  end if;

  -- (ข) ด่านของรูที่ 2 (ทิศ void ต้นฉบับ) และรูที่ 3 ผูกบน update จริง
  foreach v_name in array array['trg_void_blocked_by_reverse', 'trg_period_locked_on_void'] loop
    select count(*) into n from pg_trigger t
     where t.tgrelid = 'sri_os.transactions'::regclass and t.tgname = v_name
       and (t.tgtype & 16) <> 0;
    if n <> 1 then raise exception 'FAIL: ไม่มี trigger % ที่ครอบ UPDATE บน transactions', v_name; end if;
  end loop;

  -- (ค) fn_reverse_link_ok ต้องยังเป็น stable sql และ **ไม่ตรวจบรรทัด**
  --     (ถ้าย้ายการตรวจบรรทัดเข้าไปในนั้น ข้อยกเว้นหลักฐานของ corporate_strict จะกลาย
  --      เป็นด่านที่ต้องอ่านบรรทัดทุกครั้ง และความหมายของฟังก์ชันจะปนสองเรื่อง — D-097 ห้าม)
  select p.provolatile = 's' and l.lanname = 'sql' and p.prosecdef
         and p.prosrc not like '%transaction_lines%'
    into v_ok
    from pg_proc p join pg_language l on l.oid = p.prolang
   where p.oid = 'sri_os.fn_reverse_link_ok(uuid,uuid,uuid)'::regprocedure;
  if not coalesce(v_ok, false) then
    raise exception 'FAIL: fn_reverse_link_ok ต้องเป็น stable sql · security definer · และไม่อ่าน transaction_lines';
  end if;

  -- (ง) ฟังก์ชันของ trigger ใหม่ต้องเรียกจากข้างนอกไม่ได้ และ search_path ต้องแน่น
  select string_agg(p.proname, ', '), count(*) into v_bad, n
    from pg_proc p
   where p.oid in ('sri_os.fn_assert_reverse_mirrors()'::regprocedure,
                   'sri_os.fn_void_blocked_by_reverse()'::regprocedure,
                   'sri_os.fn_period_locked_on_void()'::regprocedure)
     and (has_function_privilege('authenticated', p.oid, 'execute')
          or has_function_privilege('public', p.oid, 'execute')
          or has_function_privilege('anon', p.oid, 'execute')
          or not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c
                          where c in ('search_path=', 'search_path=""', 'search_path=sri_os')));
  if n > 0 then
    raise exception 'FAIL: ฟังก์ชันด่านใหม่ยังเรียกได้จากข้างนอก หรือ search_path ไม่แน่น: %', v_bad;
  end if;

  raise notice 'ok R0 · ด่านสะท้อนบรรทัดเป็น constraint trigger (deferred) · ด่าน void/งวดปิดผูกบน UPDATE · fn_reverse_link_ok ยังไม่ตรวจบรรทัด · ฟังก์ชันด่านปิดจากข้างนอก';
end $$;

-- ============================================================
-- R1 · ขาบวก — ใบกลับรายการที่สะท้อนตรงตัวต้องลงได้
-- ============================================================
do $$
declare v_orig uuid := '00000000-0000-0000-0000-00000000a001';
        v_rev  uuid := '00000000-0000-0000-0000-00000000a002';
        n int;
begin
  perform pg_temp.mk_orig(v_orig, 'SUTEE', 700);
  perform pg_temp.must_pass('R1a ใบกลับรายการที่สะท้อนตรงตัว (ฝั่งบุคคล)', format(
    $q$ select pg_temp.try_rev(%L, 'SUTEE', %L, pg_temp.mirror_of(%L)) $q$, v_rev, v_orig, v_orig));
  select count(*) into n from sri_os.transaction_lines where transaction_id = v_rev;
  if n <> 2 then raise exception 'FAIL: ใบกลับรายการควรมี 2 บรรทัด ได้ %', n; end if;
  raise notice 'ok R1a · ใบกลับรายการที่สะท้อนตรงตัวลงได้ (memo ต่างจากต้นฉบับได้)';
end $$;

do $$
declare v_orig uuid := '00000000-0000-0000-0000-00000000a003';
        v_rev  uuid := '00000000-0000-0000-0000-00000000a004';
begin
  -- corporate_strict · ใบกลับรายการไม่แนบหลักฐาน แต่ **บรรทัดสะท้อนตรงตัว** → ต้องผ่าน
  -- (หลักฐานของมันคือต้นฉบับ ซึ่งแนบไว้แล้ว)
  perform pg_temp.mk_orig(v_orig, 'SRI_HOLDING', 1200);
  perform pg_temp.must_pass('R1b corporate_strict ไม่แนบหลักฐานแต่สะท้อนตรงตัว', format(
    $q$ select pg_temp.try_rev(%L, 'SRI_HOLDING', %L, pg_temp.mirror_of(%L)) $q$, v_rev, v_orig, v_orig));
  raise notice 'ok R1b · corporate_strict ยังกลับรายการได้โดยไม่แนบหลักฐาน ถ้าบรรทัดสะท้อนต้นฉบับจริง';
end $$;

-- R1c · เส้นทางจริงด้วย role authenticated (ผ่านชั้น GRANT และ RLS)
--   ถ้าด่านใหม่ต้องการ execute บนฟังก์ชันที่ authenticated ไม่มี แอปจะล้มแต่เทสต์จะเขียว
do $$
declare v_orig uuid := '00000000-0000-0000-0000-00000000a005';
        v_rev  uuid := '00000000-0000-0000-0000-00000000a006';
        n int;
begin
  perform pg_temp.rlogin('r_mgmt');
  execute 'set local role authenticated';
  perform pg_temp.mk_orig(v_orig, 'SRI_HOLDING', 450);
  perform pg_temp.try_rev(v_rev, 'SRI_HOLDING', v_orig, pg_temp.mirror_of(v_orig));
  select count(*) into n from sri_os.transaction_lines where transaction_id = v_rev;
  execute 'reset role';
  if n <> 2 then raise exception 'FAIL: ขากลับรายการลงได้ % บรรทัด', n; end if;
  raise notice 'ok R1c · post + reverse ในฐานะ authenticated จริงยังทำได้ (สิทธิ์ execute พอ)';
exception when others then
  execute 'reset role';
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: เส้นทางจริงของ authenticated ล้ม (%) — กฎใหม่กันแน่นเกินหรือสิทธิ์ไม่พอ', sqlerrm;
end $$;

-- ============================================================
-- R2-R9 · รูที่ 1 — บรรทัดที่ไม่สะท้อนต้นฉบับทุกรูปแบบต้องถูกปฏิเสธ
-- ============================================================
do $$
declare v_orig uuid := '00000000-0000-0000-0000-00000000b001';
begin
  perform pg_temp.mk_orig(v_orig, 'SUTEE', 1000);

  -- R2 · ยอดมากกว่าต้นฉบับ (รูของ D-097 ข้อ 1 ตรงๆ: ลงเงินเท่าไหร่ก็ได้)
  perform pg_temp.must_fail_like('R2 ยอดมากกว่าต้นฉบับ', format(
    $q$ select pg_temp.try_rev('00000000-0000-0000-0000-00000000b002', 'SUTEE', %L,
          '[{"coa":"2100","dr":5000000,"cr":0},{"coa":"5900","dr":0,"cr":5000000}]'::jsonb) $q$,
    v_orig), 'สะท้อน');

  -- R3 · ยอดน้อยกว่าต้นฉบับ
  perform pg_temp.must_fail_like('R3 ยอดน้อยกว่าต้นฉบับ', format(
    $q$ select pg_temp.try_rev('00000000-0000-0000-0000-00000000b003', 'SUTEE', %L,
          '[{"coa":"2100","dr":1,"cr":0},{"coa":"5900","dr":0,"cr":1}]'::jsonb) $q$,
    v_orig), 'ยอดต้นฉบับ');

  -- R4 · ยอดเท่าแต่ไม่สลับ dr/cr (= ลงซ้ำอีกใบ ไม่ใช่กลับรายการ · สมุดผิดสองเท่า)
  perform pg_temp.must_fail_like('R4 ยอดเท่าแต่ไม่สลับด้าน', format(
    $q$ select pg_temp.try_rev('00000000-0000-0000-0000-00000000b004', 'SUTEE', %L,
          '[{"coa":"5900","dr":1000,"cr":0},{"coa":"2100","dr":0,"cr":1000}]'::jsonb) $q$,
    v_orig), 'สะท้อน');

  -- R5 · รหัสบัญชีไม่ตรง (2100 → 1100) · ข้อความต้องชี้รหัสที่ไม่ตรงให้คนแก้เองได้
  perform pg_temp.must_fail_like('R5 รหัสบัญชีไม่ตรง', format(
    $q$ select pg_temp.try_rev('00000000-0000-0000-0000-00000000b005', 'SUTEE', %L,
          '[{"coa":"1100","dr":1000,"cr":0,"bank":"00000000-0000-0000-0000-00000000bf03"},
            {"coa":"5900","dr":0,"cr":1000}]'::jsonb) $q$,
    v_orig), '2100');

  -- R9 · บรรทัดเกินมาหนึ่งคู่ที่สมดุลในตัวเอง — ทิศเดียวของ except all จับไม่ได้
  perform pg_temp.must_fail_like('R9 บรรทัดเกินที่สมดุลในตัวเอง', format(
    $q$ select pg_temp.try_rev('00000000-0000-0000-0000-00000000b009', 'SUTEE', %L,
          pg_temp.mirror_of(%L) ||
          '[{"coa":"5900","dr":250,"cr":0},{"coa":"2100","dr":0,"cr":250}]'::jsonb) $q$,
    v_orig, v_orig), 'เกิน');

  raise notice 'ok R2-R5 R9 · ยอดมากกว่า/น้อยกว่า · ไม่สลับด้าน · รหัสบัญชีไม่ตรง · บรรทัดเกินที่สมดุลในตัวเอง = ปฏิเสธทุกเคส';
end $$;

-- R6 · cf_category ไม่ตรง (ถ้าไม่กัน งบกระแสเงินสดเพี้ยนทั้งที่ยอดรวมหักกลบเป็นศูนย์)
do $$
declare v_orig uuid := '00000000-0000-0000-0000-00000000b006';
begin
  perform pg_temp.mk_orig(v_orig, 'SUTEE', 900, current_date, 'operating');
  perform pg_temp.must_fail_like('R6 cf_category ไม่ตรง', format(
    $q$ select pg_temp.try_rev('00000000-0000-0000-0000-00000000b016', 'SUTEE', %L,
          '[{"coa":"2100","dr":900,"cr":0,"cf":"investing"},
            {"coa":"5900","dr":0,"cr":900,"cf":"investing"}]'::jsonb) $q$,
    v_orig), 'สะท้อน');
  raise notice 'ok R6 · cf_category ไม่ตรงกับต้นฉบับ = ปฏิเสธ (งบกระแสเงินสดจะเพี้ยน)';
end $$;

-- R7 · asset_id ไม่ตรง (งบรายทรัพย์จะเพี้ยน)
do $$
declare v_orig uuid := '00000000-0000-0000-0000-00000000b007';
        -- transaction_lines.asset_id ไม่มี FK (ตั้งใจ ดู 002_ledger) → ใช้ค่าคงที่พอ
        v_asset uuid := '00000000-0000-0000-0000-00000000ba01';
begin
  perform pg_temp.mk_orig(v_orig, 'SUTEE', 800, current_date, 'none', v_asset);
  perform pg_temp.must_fail_like('R7 asset_id ไม่ตรง', format(
    $q$ select pg_temp.try_rev('00000000-0000-0000-0000-00000000b017', 'SUTEE', %L,
          '[{"coa":"2100","dr":800,"cr":0},{"coa":"5900","dr":0,"cr":800}]'::jsonb) $q$,
    v_orig), 'สะท้อน');
  raise notice 'ok R7 · asset_id ไม่ตรงกับต้นฉบับ = ปฏิเสธ (งบรายทรัพย์จะเพี้ยน)';
end $$;

-- R8 · bank_account_id ไม่ตรง (กระทบยอดธนาคารจะเพี้ยนทั้งสองบัญชี)
do $$
declare v_orig uuid := '00000000-0000-0000-0000-00000000b008';
begin
  perform pg_temp.mk_orig_cash(v_orig, 'SRI_HOLDING', 600, '00000000-0000-0000-0000-00000000bf01');
  perform pg_temp.must_fail_like('R8 bank_account_id ไม่ตรง', format(
    $q$ select pg_temp.try_rev('00000000-0000-0000-0000-00000000b018', 'SRI_HOLDING', %L,
          '[{"coa":"4900","dr":600,"cr":0,"cf":"operating"},
            {"coa":"1100","dr":0,"cr":600,"cf":"operating","bank":"00000000-0000-0000-0000-00000000bf02"}]'::jsonb,
          '{}', 'inc.other') $q$,
    v_orig), 'สะท้อน');
  -- ขาบวกคู่กัน: บัญชีเดิมถูกต้อง → ผ่าน (ไม่ได้กันขาเงินสดทั้งหมด)
  -- **ต้นฉบับของ R8 เป็นใบเงินสดของหมวด inc.other** (ไม่ใช่ใบค้างรับเหมือนเคสอื่น)
  -- → ใบกลับรายการต้องระบุหมวดเดิมเอง ไม่ใช้ค่าตั้งต้น exp.other ของ try_rev
  perform pg_temp.must_pass('R8b bank_account_id ตรง', format(
    $q$ select pg_temp.try_rev('00000000-0000-0000-0000-00000000b028', 'SRI_HOLDING', %L,
          pg_temp.mirror_of(%L), '{}', 'inc.other') $q$, v_orig, v_orig));
  raise notice 'ok R8 · bank_account_id ไม่ตรง = ปฏิเสธ · ตรงแล้วผ่าน';
end $$;

-- ============================================================
-- R10 · รูที่ 1 ตรงตัว — corporate_strict · ไม่แนบหลักฐาน · บรรทัดไม่สะท้อน
--       เดิม: ตั้ง source='reverse' ชี้ใบจริงใบเล็ก แล้วลงเงินเท่าไหร่ก็ได้
--       โดยข้ามกติกาหลักฐานที่ "ห้าม override"
-- ============================================================
do $$
declare v_orig uuid := '00000000-0000-0000-0000-00000000c001';
        n int; v_sum numeric;
begin
  perform pg_temp.mk_orig(v_orig, 'SRI_CORP', 100);     -- ใบจริงใบเล็ก 100 บาท
  perform pg_temp.must_fail_like('R10 corporate ไม่แนบหลักฐาน + บรรทัดไม่สะท้อน', format(
    $q$ select pg_temp.try_rev('00000000-0000-0000-0000-00000000c002', 'SRI_CORP', %L,
          '[{"coa":"2100","dr":5000000,"cr":0},{"coa":"5900","dr":0,"cr":5000000}]'::jsonb) $q$,
    v_orig), 'สะท้อน');

  select count(*), coalesce(sum(l.debit), 0) into n, v_sum
    from sri_os.transactions t
    left join sri_os.transaction_lines l on l.transaction_id = t.id
   where t.id = '00000000-0000-0000-0000-00000000c002';
  if v_sum <> 0 then
    raise exception 'FAIL: ใบ 5,000,000 ที่ไม่มีหลักฐานยังอยู่ในสมุดนิติบุคคล (เดบิต %)', v_sum;
  end if;
  raise notice 'ok R10 · corporate_strict อ้างว่า reverse แล้วลงเงินเท่าไหร่ก็ได้โดยไม่แนบหลักฐาน = ปิดแล้ว';
end $$;

-- ============================================================
-- R11-R13 · รูที่ 2 — void กับ reverse ปนกันไม่ได้
-- ============================================================
do $$
declare v_orig uuid := '00000000-0000-0000-0000-00000000d001';
begin
  -- R11 · ต้นฉบับถูก void แล้ว (ไม่นับในงบ) → ลงใบกลับรายการชี้มาไม่ได้
  perform pg_temp.mk_orig(v_orig, 'SUTEE', 500);
  update sri_os.transactions set status = 'void' where id = v_orig;
  perform pg_temp.must_fail_like('R11 ต้นฉบับ void แล้วลงใบกลับรายการ', format(
    $q$ select pg_temp.try_rev('00000000-0000-0000-0000-00000000d002', 'SUTEE', %L,
          pg_temp.mirror_of(%L)) $q$, v_orig, v_orig), 'void');
  raise notice 'ok R11 · ลงใบกลับรายการที่ชี้ไปต้นฉบับที่ void แล้วไม่ได้ (สมุดจะผิดไป −ต้นฉบับ)';
end $$;

do $$
declare v_orig uuid := '00000000-0000-0000-0000-00000000d003';
        v_rev  uuid := '00000000-0000-0000-0000-00000000d004';
        v_rev2 uuid := '00000000-0000-0000-0000-00000000d005';
        v_status text;
begin
  perform pg_temp.mk_orig(v_orig, 'SUTEE', 300);
  perform pg_temp.try_rev(v_rev, 'SUTEE', v_orig, pg_temp.mirror_of(v_orig));

  -- R12 · void ต้นฉบับที่มีใบกลับรายการที่ยังนับอยู่ → ปฏิเสธ
  perform pg_temp.must_fail_like('R12 void ต้นฉบับที่มีใบกลับรายการที่ยังนับอยู่', format(
    $q$ update sri_os.transactions set status = 'void' where id = %L $q$, v_orig),
    'กลับรายการ');
  select status::text into v_status from sri_os.transactions where id = v_orig;
  if v_status <> 'posted' then raise exception 'FAIL: ต้นฉบับกลายเป็น % แล้ว', v_status; end if;

  -- R13 · void ใบกลับรายการที่ลงผิดได้ แล้วกลับรายการใบใหม่ได้ (ห้ามเป็นทางตัน)
  update sri_os.transactions set status = 'void' where id = v_rev;
  perform pg_temp.must_pass('R13 กลับรายการใหม่หลัง void ใบกลับรายการเดิม', format(
    $q$ select pg_temp.try_rev(%L, 'SUTEE', %L, pg_temp.mirror_of(%L)) $q$,
    v_rev2, v_orig, v_orig));
  raise notice 'ok R12-R13 · void ต้นฉบับที่มีใบกลับที่ยังนับอยู่ = ปฏิเสธ · void ใบกลับแล้วกลับรายการใหม่ได้ (ไม่ใช่ทางตัน)';
end $$;

-- ============================================================
-- R16 · เคส "ข้อมูลขาด/ชี้ผิด" — ห้ามตกไปเส้นทางปกติ
-- ============================================================
do $$
begin
  -- ชี้ไป id ที่ไม่มีจริง
  perform pg_temp.must_fail_like('R16a reverses_id ชี้ไป id ที่ไม่มีจริง',
    $q$ select pg_temp.try_rev('00000000-0000-0000-0000-00000000e001', 'SUTEE',
          '00000000-0000-0000-0000-0000000deadb'::uuid,
          '[{"coa":"2100","dr":10,"cr":0},{"coa":"5900","dr":0,"cr":10}]'::jsonb) $q$,
    'กลับรายการ');
  -- ชี้ไปตัวเอง
  perform pg_temp.must_fail_like('R16b reverses_id ชี้ไปตัวเอง',
    $q$ select pg_temp.try_rev('00000000-0000-0000-0000-00000000e002', 'SUTEE',
          '00000000-0000-0000-0000-00000000e002'::uuid,
          '[{"coa":"2100","dr":10,"cr":0},{"coa":"5900","dr":0,"cr":10}]'::jsonb) $q$,
    'กลับรายการ');
  raise notice 'ok R16 · reverses_id ที่ชี้ id ไม่มีจริง/ชี้ตัวเอง = ปฏิเสธ (ไม่ตกไปเส้นทางปกติ)';
end $$;

-- ============================================================
-- R15 · รายการข้ามผู้ถือ — กลับรายการทั้งสองขาในธุรกรรมเดียวต้องทำได้
-- ============================================================
do $$
declare
  v_a  uuid := '00000000-0000-0000-0000-00000000f001';   -- ขาสุธี (ผู้ให้กู้ 1310)
  v_b  uuid := '00000000-0000-0000-0000-00000000f002';   -- ขา SRI Holding (ผู้กู้ 2310)
  v_ra uuid := '00000000-0000-0000-0000-00000000f003';
  v_rb uuid := '00000000-0000-0000-0000-00000000f004';
  n int;
begin
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, cash_date, memo,
                                  attachments, contact_id,
                                  is_intercompany, counter_owner_id, intercompany_nature)
  select v_a, o.id, 'trf.internal', current_date - 1, current_date - 1, 'RV ข้ามผู้ถือ',
         array['สัญญากู้.pdf'], '00000000-0000-0000-0000-00000000bc01',
         true, (select x.id from sri_os.owners x where x.code = 'SRI_HOLDING'), 'loan'
    from sri_os.owners o where o.code = 'SUTEE';
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, cash_date, memo,
                                  attachments, contact_id,
                                  is_intercompany, counter_owner_id, intercompany_nature)
  select v_b, o.id, 'trf.internal', current_date - 1, current_date - 1, 'RV ข้ามผู้ถือ',
         array['สัญญากู้.pdf'], '00000000-0000-0000-0000-00000000bc01',
         true, (select x.id from sri_os.owners x where x.code = 'SUTEE'), 'loan'
    from sri_os.owners o where o.code = 'SRI_HOLDING';
  insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id, debit, credit, cf_category)
  values (v_a, pg_temp.coa('1310'), null, 20000, 0, 'investing'),
         (v_a, pg_temp.coa('1100'), '00000000-0000-0000-0000-00000000bf03', 0, 20000, 'investing'),
         (v_b, pg_temp.coa('1100'), '00000000-0000-0000-0000-00000000bf01', 20000, 0, 'financing'),
         (v_b, pg_temp.coa('2310'), null, 0, 20000, 'financing');
  perform pg_temp.fire();

  -- กลับรายการทั้งสองขาในธุรกรรมเดียว (แต่ละขาสะท้อนขาของตัวเอง · 1 txn = 1 owner)
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, cash_date, memo,
                                  source, reverses_id, attachments, contact_id,
                                  is_intercompany, counter_owner_id, intercompany_nature)
  select v_ra, o.id, 'trf.internal', current_date, current_date, 'RV กลับรายการข้ามผู้ถือ',
         'reverse', v_a, '{}', '00000000-0000-0000-0000-00000000bc01',
         true, (select x.id from sri_os.owners x where x.code = 'SRI_HOLDING'), 'loan'
    from sri_os.owners o where o.code = 'SUTEE';
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, cash_date, memo,
                                  source, reverses_id, attachments, contact_id,
                                  is_intercompany, counter_owner_id, intercompany_nature)
  select v_rb, o.id, 'trf.internal', current_date, current_date, 'RV กลับรายการข้ามผู้ถือ',
         'reverse', v_b, '{}', '00000000-0000-0000-0000-00000000bc01',
         true, (select x.id from sri_os.owners x where x.code = 'SUTEE'), 'loan'
    from sri_os.owners o where o.code = 'SRI_HOLDING';
  insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id, debit, credit, cf_category)
  values (v_ra, pg_temp.coa('1310'), null, 0, 20000, 'investing'),
         (v_ra, pg_temp.coa('1100'), '00000000-0000-0000-0000-00000000bf03', 20000, 0, 'investing'),
         (v_rb, pg_temp.coa('1100'), '00000000-0000-0000-0000-00000000bf01', 0, 20000, 'financing'),
         (v_rb, pg_temp.coa('2310'), null, 20000, 0, 'financing');

  begin
    perform pg_temp.fire();
  exception when others then
    raise exception 'FAIL: R15 กลับรายการข้ามผู้ถือสองขาในธุรกรรมเดียวถูกปฏิเสธ (กันแน่นเกิน): %', sqlerrm;
  end;

  select count(*) into n from sri_os.transaction_lines where transaction_id in (v_ra, v_rb);
  if n <> 4 then raise exception 'FAIL: ขากลับรายการข้ามผู้ถือลงได้ % บรรทัด (ต้อง 4)', n; end if;

  raise notice 'ok R15 · กลับรายการข้ามผู้ถือทั้งสองขาในธุรกรรมเดียวทำได้ (แต่ละขาสะท้อนขาของตัวเอง)';
end $$;

-- ============================================================
-- R14 · รูที่ 3 — void รายการในงวดที่ปิดแล้ว
--       corporate_strict = ปฏิเสธ · personal_flexible = ยังยืดหยุ่นได้ (Entity Policy เดิม)
--       **ไว้ท้ายสุด** เพราะปิดงวดแล้วเคสอื่นของผู้ถือเดียวกันจะลงรายการไม่ได้
-- ============================================================
do $$
declare v_corp uuid := '00000000-0000-0000-0000-0000000a0001';
        v_pers uuid := '00000000-0000-0000-0000-0000000a0002';
        v_status text;
begin
  perform pg_temp.mk_orig(v_corp, 'SRI_CAPITAL', 2500);
  perform pg_temp.mk_orig(v_pers, 'THANAKORN', 2500);

  insert into sri_os.period_closes(owner_id, period, closed_by)
  select o.id, date_trunc('month', current_date)::date, pg_temp.ruid('r_mgmt')
    from sri_os.owners o where o.code in ('SRI_CAPITAL', 'THANAKORN');

  -- R14a · corporate: งบที่ยื่นไปแล้วต้องไม่ขยับ → void ไม่ได้ ให้ลงใบกลับรายการในงวดปัจจุบัน
  perform pg_temp.must_fail_like('R14a void ในงวดที่ปิดแล้ว (corporate)', format(
    $q$ update sri_os.transactions set status = 'void' where id = %L $q$, v_corp), 'งวด');
  select status::text into v_status from sri_os.transactions where id = v_corp;
  if v_status <> 'posted' then
    raise exception 'FAIL: รายการในงวดที่ปิดแล้วกลายเป็น % (งบที่ยื่นไปแล้วเปลี่ยนเงียบๆ)', v_status;
  end if;

  -- R14b · personal: ยังยืดหยุ่นได้ตาม Entity Policy เดิม (ห้ามเปลี่ยนนโยบายนั้นเอง)
  perform pg_temp.must_pass('R14b void ในงวดที่ปิดแล้ว (บุคคล)', format(
    $q$ update sri_os.transactions set status = 'void' where id = %L $q$, v_pers));
  select status::text into v_status from sri_os.transactions where id = v_pers;
  if v_status <> 'void' then
    raise exception 'FAIL: ฝั่งบุคคล void ไม่ได้ (status %) — กันแน่นเกินและเปลี่ยนนโยบาย', v_status;
  end if;

  raise notice 'ok R14 · void รายการในงวดที่ปิดแล้ว: corporate ปฏิเสธ · บุคคลยังทำได้';
end $$;

-- ---------- สรุป: ทุกใบที่ไฟล์นี้สร้างต้องผ่านด่านที่เลื่อนไว้จริง ----------
do $$
declare n int;
begin
  set constraints all immediate;
  select count(*) into n from sri_os.transactions where memo like 'RV %';
  if n < 14 then
    raise exception 'FAIL: นับใบที่เทสต์นี้สร้างได้แค่ % ใบ — เทสต์อาจไม่ได้ลงอะไรเลย', n;
  end if;
  raise notice 'ok R · ทั้ง % ใบของไฟล์นี้ผ่านด่านที่เลื่อนไว้ (เคสปฏิเสธไม่ทิ้งใบเสียรูปไว้)', n;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: ใบที่เทสต์นี้สร้างไว้เสียรูป: %', sqlerrm;
end $$;

rollback;
