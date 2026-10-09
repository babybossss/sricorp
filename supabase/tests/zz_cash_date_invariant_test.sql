-- ============================================================
-- SRI OS · เทสต์ Money Invariant ของ cash_date + การแช่แข็ง reverses_id
--   migration ที่ทดสอบ: 20261009000001_cash_date_invariant.sql
--
-- สองรูที่ปิดในรอบนี้ (ผู้ตรวจรันยืนยันแล้วว่าเกิดจริงบน DB ที่ migrate ครบ)
--
--   รูที่ 1 · งบกระแสเงินสดค้างตลอดกาล
--     กฎ "มีบรรทัด 11xx ⟺ cash_date ไม่เป็น null" เคยเขียนไว้ใน fn_post_entry
--     **ที่เดียว** → เป็นกฎของ RPC ไม่ใช่ของฐานข้อมูล · insert ตรง (PostgREST /
--     service_role / psql) เลี่ยงได้ทุกกรณี
--     เคสที่พิสูจน์: ต้นฉบับเงินเข้าธนาคาร 5,000 cash_date = '2026-10-20' →
--     ใบกลับรายการสะท้อนบรรทัดครบทุกมิติ (ผ่านด่าน D-097) แต่ cash_date = null
--     → งบดุลหักกันเป็น 0.00 แต่งบกระแสเงินสด (where cash_date is not null)
--       ค้าง 5,000.00 **ตลอดกาล** · ทุกใบสมดุล · ไม่มี trigger ร้อง
--     ทางกลับกันก็ได้: ต้นฉบับค้างรับ (ไม่มี 11xx · cash_date null) แล้วใบกลับรายการ
--     ใส่ cash_date → เงินสดผีที่ไม่มีเงินจริงเคลื่อน
--
--     แก้ที่ต้นเหตุ = ยกกฎขึ้นเป็น constraint trigger บน transactions
--     → ใบกลับรายการที่สะท้อนบรรทัดครบจะ **มีบรรทัด 11xx อยู่แล้ว** จึงถูกบังคับให้มี
--       cash_date เอง · รูที่ 1 ปิดโดยอัตโนมัติ **ไม่ต้องเทียบ cash_date ในด่านสะท้อน**
--       (ด่านสะท้อนตั้งใจไม่เทียบวันที่ เพราะใบกลับรายการลงวันที่ปัจจุบัน)
--
--   รูที่ 2 · ฝั่ง personal_flexible เขียนทับประวัติ "ใบไหนกลับใบไหน" ได้หลัง commit
--     update ... set reverses_id = <ใบอื่นที่บรรทัดเหมือนกัน> → สำเร็จ
--     ต้นฉบับเดิมกลับเป็น "ยังไม่ถูกกลับรายการ" แล้วกลับรายการซ้ำได้
--     (fn_corporate_immutable กันแต่ corporate · fn_txn_system_columns freeze
--      แค่ owner_id/created_at/write_txn_id)
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ **rollback** ปิดท้าย — ไม่ทิ้งรายการเงินไว้
--   ด่าน cash_date เป็น `constraint trigger ... deferrable initially deferred`
--   (ตอน insert หัวรายการ บรรทัดยังไม่เกิด → before insert เป็นด่านที่ไม่ตรวจอะไรเลย)
--   → เคสปฏิเสธต้องยิง `set constraints all immediate` เองผ่าน pg_temp.fire()
--   แล้วคืนสภาพ deferred เหมือนที่ fn_post_entry ทำ (แพทเทิร์นเดียวกับ zz_reverse_integrity)
--
-- รันในฐานะ superuser ของ cluster = ข้าม RLS แต่ **trigger ยังทำงานทุกเส้นทาง**
--   (กฎเงินต้องไม่ขึ้นกับสิทธิ์ · C1b เดินซ้ำด้วย role authenticated อีกชั้น)
--
-- mutation ที่ต้องทำให้เทสต์แดง (ถ้าไม่แดง = เทสต์ยังไม่ครอบ)
--   M1 ด่าน cash_date return ผ่านทุกกรณี              → C1 C1b C2 C5a C5d C6 C9b แดง
--   M2 เช็คแต่ทิศเดียว (มี 11xx ⇒ ต้องมี cash_date)    → C2 C5d C9b แดง
--   M3 ถอดด่าน freeze reverses_id                      → C7 C8a C8b แดง
--   M4 ด่าน cash_date ยิงแต่ insert ไม่ยิง update       → C6 แดง (และ C0 แดงที่ชั้นโครงสร้าง)
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
create temporary table t_cuid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_cuid(label) values ('c_mgmt');
insert into auth.users(id) select id from t_cuid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select id, label || '@cashdate.local', label, 'management', true from t_cuid;
insert into sri_os.user_owner_access(user_id, owner_id)
select (select id from t_cuid where label = 'c_mgmt'), o.id from sri_os.owners o;

create or replace function pg_temp.cuid(p_label text) returns uuid
language sql stable as $fn$ select id from t_cuid where label = p_label $fn$;

create or replace function pg_temp.coa(p_code text) returns uuid
language sql stable as $fn$
  select id from sri_os.chart_of_accounts where code = p_code
$fn$;

create or replace function pg_temp.own(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.owners where code = p_code $fn$;

insert into sri_os.contacts(id, first_name, types)
values ('00000000-0000-0000-0000-00000000cc01', 'คู่ค้า CD', array['tenant'])
on conflict do nothing;

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
select x.id, pg_temp.own(x.own), x.bank, x.nm, x.nm
  from (values
    ('00000000-0000-0000-0000-00000000cf01'::uuid, 'SRI_CORP',    'SCB',   'CD SRI Corp'),
    ('00000000-0000-0000-0000-00000000cf02'::uuid, 'SUTEE',       'BBL',   'CD สุธี'),
    ('00000000-0000-0000-0000-00000000cf03'::uuid, 'THANAKORN',   'KBANK', 'CD ธนากร'),
    ('00000000-0000-0000-0000-00000000cf04'::uuid, 'SRI_HOLDING', 'SCB',   'CD SRI Holding')
  ) as x(id, own, bank, nm);

-- ------------------------------------------------------------
-- ตัวช่วย (แพทเทิร์นเดียวกับ zz_reverse_integrity_test)
-- ------------------------------------------------------------
-- เคสที่ "ควรถูกปฏิเสธแต่สำเร็จ" ต้องย้อนของที่เพิ่งเขียนทิ้งด้วย ไม่งั้นใบที่ไม่ควรมีอยู่
-- จะค้างในสมุดของเทสต์ แล้วเคสถัดไปล้มด้วยเหตุผลอื่น = รายงาน mutation ชี้ผิดจุด
create or replace function pg_temp.must_fail_like(p_label text, p_sql text, p_needle text) returns void
language plpgsql as $fn$
declare v text;
begin
  begin
    execute p_sql;
    raise exception 'CD_UNEXPECTED_SUCCESS';
  exception when others then
    v := sqlerrm;
    if v = 'CD_UNEXPECTED_SUCCESS' then
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

-- หัวรายการหนึ่งใบ + บรรทัดจาก jsonb ในธุรกรรมเดียวกัน (เส้นทางเดียวกับที่ fn_post_entry เขียน)
--   p_lines = [{"coa":"1100","dr":5000,"cr":0,"cf":"operating","bank":"<uuid>"}, ...]
--   **ไม่ใส่ค่า default ให้ cash_date** โดยตั้งใจ — ผู้เรียกต้องบอกทุกครั้งว่าจะส่งอะไร
--   (บทเรียนข้อ 3: fixture ที่เติมค่าให้เองจะไม่มีวันแตะเส้นทางที่ข้อมูลขาด)
create or replace function pg_temp.mk_txn(p_id uuid, p_owner text, p_type text,
                                          p_cash date, p_lines jsonb,
                                          p_att text[] default array['หลักฐาน-CD.pdf'],
                                          p_source text default 'manual',
                                          p_reverses uuid default null,
                                          p_doc date default current_date) returns uuid
language plpgsql as $fn$
declare r jsonb;
begin
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, cash_date, memo,
                                  attachments, contact_id, source, reverses_id)
  values (p_id, pg_temp.own(p_owner), p_type, p_doc, p_cash, 'CD ' || p_id::text,
          p_att, '00000000-0000-0000-0000-00000000cc01', p_source::sri_os.txn_source, p_reverses);
  for r in select * from jsonb_array_elements(p_lines) loop
    insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id,
                                         debit, credit, cf_category, memo)
    values (p_id, pg_temp.coa(r ->> 'coa'), (r ->> 'bank')::uuid,
            coalesce((r ->> 'dr')::numeric, 0), coalesce((r ->> 'cr')::numeric, 0),
            coalesce(r ->> 'cf', 'none')::sri_os.cf_group, 'CD บรรทัด');
  end loop;
  perform pg_temp.fire();
  return p_id;
end $fn$;

-- ภาพกลับด้านของต้นฉบับ (ของที่ "ถูก" ตามด่าน D-097) — สร้างจากบรรทัดจริงใน DB
create or replace function pg_temp.mirror_of(p_orig uuid) returns jsonb
language sql stable as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
           'coa',  c.code,
           'dr',   l.credit,
           'cr',   l.debit,
           'cf',   l.cf_category,
           'bank', l.bank_account_id)), '[]'::jsonb)
    from sri_os.transaction_lines l
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where l.transaction_id = p_orig
$fn$;

-- ยอดที่ **งบกระแสเงินสด** เห็น: บรรทัดเงินสด 11xx ของใบที่ cash_date ไม่เป็น null
--   (เกณฑ์เดียวกับที่ผู้ตรวจใช้พิสูจน์รูที่ 1 · where t.cash_date is not null)
create or replace function pg_temp.cf_cash(p_ids uuid[]) returns numeric
language sql stable as $fn$
  select coalesce(sum(l.debit - l.credit), 0)
    from sri_os.transactions t
    join sri_os.transaction_lines l on l.transaction_id = t.id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where t.id = any (p_ids)
     and t.status::text <> 'void'
     and t.cash_date is not null
     and c.code ~ '^11[0-9][0-9]$'
$fn$;

-- ยอดที่ **งบดุล** เห็น: บรรทัดเงินสด 11xx ทุกใบ ไม่สนใจ cash_date
create or replace function pg_temp.bs_cash(p_ids uuid[]) returns numeric
language sql stable as $fn$
  select coalesce(sum(l.debit - l.credit), 0)
    from sri_os.transactions t
    join sri_os.transaction_lines l on l.transaction_id = t.id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where t.id = any (p_ids)
     and t.status::text <> 'void'
     and c.code ~ '^11[0-9][0-9]$'
$fn$;

-- คู่รายการข้ามผู้ถือ ลักษณะ "ทดรอง" (advance · 1310/2310)
--   ขา A (SRI Holding จ่ายเงินแทน): Dr 1310 / Cr 1100 → **มีบรรทัดเงินสด**
--   ขา B (สุธีรับภาระค่าใช้จ่าย):    Dr 5900 / Cr 2310 → **ไม่มีบรรทัดเงินสดเลย**
--     เงินออกจากบัญชี SRI Holding ตรงไปผู้ขาย ไม่เคยผ่านบัญชีของสุธี
--     → cash_date ของสองขา **ต่างกันโดยถูกต้อง** (ขา A มีวัน · ขา B ต้องเป็น null)
create or replace function pg_temp.mk_pair(p_a uuid, p_b uuid, p_amt numeric,
                                           p_cash_a date, p_cash_b date) returns void
language plpgsql as $fn$
begin
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, cash_date, memo,
                                  attachments, contact_id,
                                  is_intercompany, counter_owner_id, intercompany_nature)
  values (p_a, pg_temp.own('SRI_HOLDING'), 'exp.other', current_date, p_cash_a,
          'CD ข้ามผู้ถือ ขาจ่าย', array['ใบทดรอง.pdf'],
          '00000000-0000-0000-0000-00000000cc01',
          true, pg_temp.own('SUTEE'), 'advance'),
         (p_b, pg_temp.own('SUTEE'), 'exp.other', current_date, p_cash_b,
          'CD ข้ามผู้ถือ ขารับภาระ', array['ใบทดรอง.pdf'],
          '00000000-0000-0000-0000-00000000cc01',
          true, pg_temp.own('SRI_HOLDING'), 'advance');
  insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id, debit, credit, cf_category)
  values (p_a, pg_temp.coa('1310'), null, p_amt, 0, 'investing'),
         (p_a, pg_temp.coa('1100'), '00000000-0000-0000-0000-00000000cf04', 0, p_amt, 'investing'),
         (p_b, pg_temp.coa('5900'), null, p_amt, 0, 'operating'),
         (p_b, pg_temp.coa('2310'), null, 0, p_amt, 'operating');
  perform pg_temp.fire();
end $fn$;

-- ============================================================
-- C0 · โครงสร้าง — ไล่จาก pg_trigger / pg_proc จริง ไม่ใช่ไล่ไฟล์
--      เคสนี้คือชั้นที่จับ M4 (ยิงแต่ insert) ได้ก่อนถึงเคสข้อมูล
-- ============================================================
do $$
declare
  v_type int; v_defer boolean; v_init boolean; v_con oid;
  n int; v_src text;
begin
  -- (ก) ด่าน cash_date ต้องเป็น constraint trigger ที่เลื่อนไว้จริง และยิง **ทั้ง insert และ update**
  select t.tgtype, t.tgdeferrable, t.tginitdeferred, t.tgconstraint
    into v_type, v_defer, v_init, v_con
    from pg_trigger t
   where t.tgrelid = 'sri_os.transactions'::regclass
     and t.tgname = 'trg_txn_cash_date_matches_lines';
  if v_type is null then
    raise exception 'FAIL: C0ก ไม่มี trigger trg_txn_cash_date_matches_lines บน sri_os.transactions — กฎ cash_date ยังเป็นกฎของ RPC ไม่ใช่ของฐานข้อมูล (insert ตรงเลี่ยงได้)';
  end if;
  if not (v_defer and v_init and v_con <> 0) then
    raise exception 'FAIL: C0ก ด่าน cash_date ไม่ได้ผูกเป็น constraint trigger (deferrable initially deferred) — ตอน insert หัวรายการ บรรทัดยังไม่เกิด = ด่านที่ไม่ตรวจอะไรเลย';
  end if;
  if (v_type & 2) <> 0 then
    raise exception 'FAIL: C0ก ด่าน cash_date เป็น BEFORE — ต้องเป็น AFTER (บรรทัดยังไม่เกิดตอน before)';
  end if;
  if (v_type & 4) = 0 then
    raise exception 'FAIL: C0ก ด่าน cash_date ไม่ยิงตอน INSERT';
  end if;
  if (v_type & 16) = 0 then
    raise exception 'FAIL: C0ก ด่าน cash_date ไม่ยิงตอน UPDATE — `update ... set cash_date = null` จะเลี่ยงได้ทั้งหมด';
  end if;

  -- (ข) ด่าน freeze reverses_id ต้องผูกบน UPDATE
  select count(*) into n from pg_trigger t
   where t.tgrelid = 'sri_os.transactions'::regclass
     and t.tgname = 'trg_reverses_id_frozen'
     and (t.tgtype & 16) <> 0;
  if n <> 1 then
    raise exception 'FAIL: C0ข ด่าน freeze reverses_id ไม่ได้ผูกบน UPDATE ของ sri_os.transactions (เจอ %)', n;
  end if;

  -- (ค) นิยาม "บรรทัดเงินสด" ต้องตรงกับที่ประตูใช้ — **สองที่ต้องตรงกัน ไม่ใช่กฎสองชุด**
  --     ประตูเช็ค chart_of_accounts.code ~ '^11[0-9][0-9]$' (เกณฑ์เดียวกับ
  --     fn_assert_no_floating_cash) → ด่านใหม่ต้องใช้ regex ตัวเดียวกันตัวอักษรต่อตัวอักษร
  select prosrc into v_src from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_assert_txn_cash_date';
  if v_src is null then
    raise exception 'FAIL: C0ค ไม่มีฟังก์ชัน sri_os.fn_assert_txn_cash_date';
  end if;
  if position('^11[0-9][0-9]$' in v_src) = 0 then
    raise exception 'FAIL: C0ค ด่านใหม่ไม่ได้ใช้นิยามบรรทัดเงินสดเดียวกับประตู/fn_assert_no_floating_cash (regex ^11[0-9][0-9]$) — นิยามใหม่ = ได้กฎสองชุด';
  end if;

  -- (ง) ประตู fn_post_entry ต้อง **ยังมีกฎเดิมอยู่** รอบนี้ (ตั้งใจไม่ถอด)
  --     เหลือไว้เพื่อให้ผู้กดได้ error ก่อนถึง commit · ถ้ารอบหน้าถอดออกจริง
  --     ให้แก้เคสนี้พร้อมกับ migration ที่ถอด ไม่ใช่ปล่อยให้เงียบ
  select prosrc into v_src from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_post_entry';
  if v_src is null or position('cash_date' in v_src) = 0
     or position('^11[0-9][0-9]$' in v_src) = 0 then
    raise exception 'FAIL: C0ง ประตู fn_post_entry ไม่มีกฎ cash_date แล้ว — รอบนี้ยังต้องมี (ให้ error ถึงผู้ใช้ก่อน commit)';
  end if;

  -- (จ) กฎเงินห้ามขึ้นกับสิทธิ์: ด่านใหม่ห้ามเรียก fn_can
  select count(*) into n from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.proname in ('fn_assert_txn_cash_date', 'fn_txn_cash_date_guard', 'fn_reverses_id_frozen')
     and p.prosrc like '%fn_can%';
  if n > 0 then
    raise exception 'FAIL: C0จ ด่านใหม่เรียกฟังก์ชันตรวจสิทธิ์ — กฎเงินต้องปิดไม่ได้จากหน้า Settings';
  end if;

  raise notice 'ok C0 · ด่าน cash_date เป็น constraint trigger ที่เลื่อนไว้ ยิงทั้ง insert/update · freeze reverses_id ผูกบน update · นิยามบรรทัดเงินสดตรงกับประตู';
end $$;

-- ============================================================
-- C1 · มีบรรทัด 11xx แต่ cash_date null → ปฏิเสธ
--      (เคสที่ผู้ตรวจรันแล้ว "ผ่านฉลุย" — ต้องกลับเป็นปฏิเสธ)
-- ============================================================
do $$
declare v uuid := '00000000-0000-0000-0000-0000000c0001';
begin
  perform pg_temp.must_fail_like('C1 เงินเข้าธนาคารแต่ไม่มี cash_date', format(
    $q$ select pg_temp.mk_txn(%L, 'SRI_CORP', 'inc.other', null,
          '[{"coa":"1100","dr":5000,"cr":0,"cf":"operating","bank":"00000000-0000-0000-0000-00000000cf01"},
             {"coa":"4900","dr":0,"cr":5000,"cf":"operating"}]'::jsonb) $q$, v),
    'บรรทัดเงินสด');
  if exists (select 1 from sri_os.transactions where id = v) then
    raise exception 'FAIL: C1 ใบที่ถูกปฏิเสธยังค้างอยู่ในสมุด';
  end if;
  raise notice 'ok C1 · มีบรรทัด 11xx แต่ cash_date null ถูกปฏิเสธที่ฐานข้อมูล (ไม่ใช่แค่ที่ RPC)';
end $$;

-- C1b · เส้นทางเดียวกันด้วย role authenticated — กฎเงินต้องไม่ขึ้นกับสิทธิ์
do $$
declare v uuid := '00000000-0000-0000-0000-0000000c0002';
begin
  perform set_config('test.uid', pg_temp.cuid('c_mgmt')::text, true);
  execute 'set local role authenticated';
  perform pg_temp.must_fail_like('C1b เงินเข้าธนาคารแต่ไม่มี cash_date (authenticated)', format(
    $q$ select pg_temp.mk_txn(%L, 'SUTEE', 'inc.other', null,
          '[{"coa":"1100","dr":2500,"cr":0,"cf":"operating","bank":"00000000-0000-0000-0000-00000000cf02"},
             {"coa":"4900","dr":0,"cr":2500,"cf":"operating"}]'::jsonb) $q$, v),
    'บรรทัดเงินสด');
  execute 'reset role';
  raise notice 'ok C1b · ด่านเดียวกันทำงานกับ role authenticated ด้วย (สิทธิ์ execute พอ)';
exception when others then
  execute 'reset role';
  raise;
end $$;

-- ============================================================
-- C2 · ไม่มีบรรทัด 11xx แต่ใส่ cash_date → ปฏิเสธ (เงินสดผี)
-- ============================================================
do $$
declare v uuid := '00000000-0000-0000-0000-0000000c0003';
begin
  perform pg_temp.must_fail_like('C2 ค้างรับแต่ใส่ cash_date (เงินสดผี)', format(
    $q$ select pg_temp.mk_txn(%L, 'SRI_CORP', 'inc.other', current_date,
          '[{"coa":"1220","dr":4000,"cr":0,"cf":"none"},
             {"coa":"4900","dr":0,"cr":4000,"cf":"none"}]'::jsonb) $q$, v),
    'ไม่มีบรรทัดเงินสดเลย');
  if exists (select 1 from sri_os.transactions where id = v) then
    raise exception 'FAIL: C2 ใบที่ถูกปฏิเสธยังค้างอยู่ในสมุด';
  end if;
  raise notice 'ok C2 · ไม่มีบรรทัด 11xx แต่ใส่ cash_date ถูกปฏิเสธ (งบกระแสเงินสดนับเงินที่ยังไม่เคลื่อนไม่ได้)';
end $$;

-- ============================================================
-- C3 · มี 11xx + มี cash_date → ผ่าน
-- ============================================================
do $$
declare v uuid := '00000000-0000-0000-0000-0000000c0004';
begin
  perform pg_temp.must_pass('C3 เงินเข้าธนาคารพร้อม cash_date', format(
    $q$ select pg_temp.mk_txn(%L, 'SRI_CORP', 'inc.other', date '2026-10-20',
          '[{"coa":"1100","dr":5000,"cr":0,"cf":"operating","bank":"00000000-0000-0000-0000-00000000cf01"},
             {"coa":"4900","dr":0,"cr":5000,"cf":"operating"}]'::jsonb) $q$, v));
  if pg_temp.cf_cash(array[v]) <> 5000 then
    raise exception 'FAIL: C3 งบกระแสเงินสดควรเห็น 5000 แต่เห็น %', pg_temp.cf_cash(array[v]);
  end if;
  raise notice 'ok C3 · มี 11xx + cash_date ผ่าน และงบกระแสเงินสดเห็นยอดจริง';
end $$;

-- ============================================================
-- C4 · ค้างรับ (ไม่มี 11xx) + cash_date null → ผ่าน
-- ============================================================
do $$
declare v uuid := '00000000-0000-0000-0000-0000000c0005';
begin
  perform pg_temp.must_pass('C4 ค้างรับ cash_date null', format(
    $q$ select pg_temp.mk_txn(%L, 'SRI_CORP', 'inc.other', null,
          '[{"coa":"1220","dr":4000,"cr":0,"cf":"none"},
             {"coa":"4900","dr":0,"cr":4000,"cf":"none"}]'::jsonb) $q$, v));
  if pg_temp.cf_cash(array[v]) <> 0 then
    raise exception 'FAIL: C4 ใบค้างรับไม่ควรโผล่ในงบกระแสเงินสด (เห็น %)', pg_temp.cf_cash(array[v]);
  end if;
  raise notice 'ok C4 · ค้างรับ + cash_date null ผ่าน และไม่ถูกนับในงบกระแสเงินสด';
end $$;

-- ============================================================
-- C5 · เคสกลับรายการของ mace-windu เต็มรูป
--      ต้นฉบับมีเงินสด + cash_date · ใบกลับรายการสะท้อนบรรทัดครบ (ผ่านด่าน D-097)
--      แต่ cash_date = null และ attachments = '{}'
--      → เดิมผ่านฉลุย · ต้องปฏิเสธ · แล้วพิสูจน์ว่าเมื่อใส่ cash_date
--        ทั้งงบดุล **และ** งบกระแสเงินสดหักกันเป็นศูนย์จริง
-- ============================================================
do $$
declare
  v_o uuid := '00000000-0000-0000-0000-0000000c0010';
  v_r uuid := '00000000-0000-0000-0000-0000000c0011';
  v_cf numeric; v_bs numeric;
begin
  perform pg_temp.mk_txn(v_o, 'SRI_CORP', 'inc.other', date '2026-10-20',
    '[{"coa":"1100","dr":5000,"cr":0,"cf":"operating","bank":"00000000-0000-0000-0000-00000000cf01"},
       {"coa":"4900","dr":0,"cr":5000,"cf":"operating"}]'::jsonb);

  -- C5a · ใบกลับรายการที่สะท้อนครบทุกมิติ แต่ cash_date null → ต้องปฏิเสธ
  --        (ด่านสะท้อนบรรทัดไม่เทียบ cash_date โดยตั้งใจ · ด่านนี้คือตัวที่ปิดรู)
  perform pg_temp.must_fail_like('C5a ใบกลับรายการสะท้อนครบแต่ cash_date null', format(
    $q$ select pg_temp.mk_txn(%L, 'SRI_CORP', 'inc.other', null, %L, '{}', 'reverse', %L) $q$,
    v_r, pg_temp.mirror_of(v_o)::text, v_o),
    'บรรทัดเงินสด');
  if exists (select 1 from sri_os.transactions where id = v_r) then
    raise exception 'FAIL: C5a ใบกลับรายการที่ถูกปฏิเสธยังค้างอยู่ในสมุด';
  end if;

  -- C5b · งบกระแสเงินสดของต้นฉบับยังค้าง 5000 อยู่จริง (พิสูจน์ว่ารูเดิมอันตรายแค่ไหน)
  if pg_temp.cf_cash(array[v_o, v_r]) <> 5000 then
    raise exception 'FAIL: C5b ยอดในงบกระแสเงินสดหลังใบกลับรายการถูกปฏิเสธควรเป็น 5000 (ของต้นฉบับ) ได้ %',
      pg_temp.cf_cash(array[v_o, v_r]);
  end if;

  -- C5c · ใส่ cash_date แล้วผ่าน (ไม่ต้องแนบหลักฐานตามข้อยกเว้นของ D-097)
  perform pg_temp.must_pass('C5c ใบกลับรายการพร้อม cash_date', format(
    $q$ select pg_temp.mk_txn(%L, 'SRI_CORP', 'inc.other', current_date, %L, '{}', 'reverse', %L) $q$,
    v_r, pg_temp.mirror_of(v_o)::text, v_o));

  v_bs := pg_temp.bs_cash(array[v_o, v_r]);
  v_cf := pg_temp.cf_cash(array[v_o, v_r]);
  if v_bs <> 0 then
    raise exception 'FAIL: C5c เงินฝากในงบดุลต้องหักกันเป็น 0 ได้ %', v_bs;
  end if;
  if v_cf <> 0 then
    raise exception 'FAIL: C5c เงินฝากในงบกระแสเงินสดต้องหักกันเป็น 0 ได้ % — นี่คือรูที่ 1 ที่ยังไม่ปิด', v_cf;
  end if;

  raise notice 'ok C5a-c · ใบกลับรายการที่ไม่มี cash_date ถูกปฏิเสธ · เมื่อใส่แล้วงบดุล 0.00 และงบกระแสเงินสด 0.00 (ไม่ค้างตลอดกาล)';
end $$;

-- C5d · ทางกลับกัน: ต้นฉบับค้างรับ (ไม่มี 11xx · cash_date null)
--        แล้วใบกลับรายการใส่ cash_date → เงินสดผี ต้องปฏิเสธ
do $$
declare
  v_o uuid := '00000000-0000-0000-0000-0000000c0012';
  v_r uuid := '00000000-0000-0000-0000-0000000c0013';
begin
  perform pg_temp.mk_txn(v_o, 'SRI_CORP', 'inc.other', null,
    '[{"coa":"1220","dr":3000,"cr":0,"cf":"none"},
       {"coa":"4900","dr":0,"cr":3000,"cf":"none"}]'::jsonb);

  perform pg_temp.must_fail_like('C5d ใบกลับรายการของใบค้างรับแต่ใส่ cash_date', format(
    $q$ select pg_temp.mk_txn(%L, 'SRI_CORP', 'inc.other', current_date, %L, '{}', 'reverse', %L) $q$,
    v_r, pg_temp.mirror_of(v_o)::text, v_o),
    'ไม่มีบรรทัดเงินสดเลย');

  perform pg_temp.must_pass('C5d2 ใบกลับรายการของใบค้างรับ cash_date null', format(
    $q$ select pg_temp.mk_txn(%L, 'SRI_CORP', 'inc.other', null, %L, '{}', 'reverse', %L) $q$,
    v_r, pg_temp.mirror_of(v_o)::text, v_o));

  raise notice 'ok C5d · ใบกลับรายการของรายการค้างรับใส่ cash_date ไม่ได้ (เงินสดผี) · ปล่อย null แล้วผ่าน';
end $$;

-- ============================================================
-- C6 · update ... set cash_date = null บนรายการที่มีบรรทัด 11xx (ฝั่ง personal) → ปฏิเสธ
--      ฝั่ง personal คือฝั่งที่แก้หัวรายการหลัง commit ได้จริง
--      (corporate ถูก fn_corporate_immutable ปฏิเสธอยู่แล้วด้วยเหตุผลอื่น)
-- ============================================================
do $$
declare v uuid := '00000000-0000-0000-0000-0000000c0020';
        v_cash date;
begin
  perform pg_temp.mk_txn(v, 'SUTEE', 'inc.other', date '2026-10-20',
    '[{"coa":"1100","dr":7000,"cr":0,"cf":"operating","bank":"00000000-0000-0000-0000-00000000cf02"},
       {"coa":"4900","dr":0,"cr":7000,"cf":"operating"}]'::jsonb);

  perform pg_temp.must_fail_like('C6 ลบ cash_date ทิ้งหลัง commit', format(
    $q$ update sri_os.transactions set cash_date = null where id = %L $q$, v),
    'บรรทัดเงินสด');
  select cash_date into v_cash from sri_os.transactions where id = v;
  if v_cash is null then
    raise exception 'FAIL: C6 cash_date กลายเป็น null ได้ — ใบนี้จะหายจากงบกระแสเงินสดทั้งที่เงินเคลื่อนจริง';
  end if;

  -- C6b · **แก้วันที่เป็นวันอื่นยังต้องทำได้** (กระทบยอดธนาคารแล้วพบว่าเงินเข้าอีกวัน)
  --        ถ้ากันข้อนี้ด้วย = กันแน่นเกินและปิดเส้นทางที่ Entity Policy เปิดไว้
  perform pg_temp.must_pass('C6b แก้ cash_date เป็นวันอื่น', format(
    $q$ update sri_os.transactions set cash_date = date '2026-10-21' where id = %L $q$, v));

  raise notice 'ok C6 · ลบ cash_date ของรายการที่มีเงินสดไม่ได้ · แก้เป็นวันอื่นยังทำได้';
end $$;

-- ============================================================
-- C7 / C8 · ประวัติ "ใบไหนกลับใบไหน" เขียนทับไม่ได้ (ทุกผู้ถือ)
--   O1 กับ O2 มีบรรทัด **เหมือนกันทุกมิติ** โดยตั้งใจ → ด่านสะท้อนบรรทัดของ D-097
--   ยอมให้ R ชี้ไปใบไหนก็ได้ และ fn_reverse_link_ok ก็ยอม (O2 ยังไม่ถูกกลับรายการ)
--   = เคสนี้ **มีด่านใหม่เท่านั้นที่ปฏิเสธได้** (ถอดด่านออก → C7/C8a ผ่านทันที)
-- ============================================================
do $$
declare
  v_o1 uuid := '00000000-0000-0000-0000-0000000c0030';
  v_o2 uuid := '00000000-0000-0000-0000-0000000c0031';
  v_r  uuid := '00000000-0000-0000-0000-0000000c0032';
  v_x  uuid := '00000000-0000-0000-0000-0000000c0033';
  v_link uuid;
  v_src  text;
begin
  perform pg_temp.mk_txn(v_o1, 'THANAKORN', 'inc.other', null,
    '[{"coa":"1220","dr":1500,"cr":0,"cf":"none"},
       {"coa":"4900","dr":0,"cr":1500,"cf":"none"}]'::jsonb);
  perform pg_temp.mk_txn(v_o2, 'THANAKORN', 'inc.other', null,
    '[{"coa":"1220","dr":1500,"cr":0,"cf":"none"},
       {"coa":"4900","dr":0,"cr":1500,"cf":"none"}]'::jsonb);
  perform pg_temp.mk_txn(v_r, 'THANAKORN', 'inc.other', null,
    pg_temp.mirror_of(v_o1), '{}', 'reverse', v_o1);

  -- C7 · ย้ายลิงก์ไปชี้ใบอื่น (ต้นฉบับเดิมกลับเป็น "ยังไม่ถูกกลับรายการ" แล้วกลับซ้ำได้)
  perform pg_temp.must_fail_like('C7 ย้าย reverses_id ไปชี้ใบอื่น', format(
    $q$ update sri_os.transactions set reverses_id = %L where id = %L $q$, v_o2, v_r),
    'reverses_id');
  select reverses_id into v_link from sri_os.transactions where id = v_r;
  if v_link <> v_o1 then
    raise exception 'FAIL: C7 ลิงก์กลับรายการถูกเขียนทับเป็น % (ประวัติ D-098 พิมพ์ทับได้)', v_link;
  end if;

  -- C8a · ลบลิงก์ทิ้งพร้อมเปลี่ยน source กลับเป็น manual
  --        เส้นทางนี้ **ด่านลิงก์เดิมไม่เห็นเลย** (new.source <> reverse และ new.reverses_id is null)
  --        → ถ้าถอดด่านใหม่ออก เคสนี้ผ่านทันที = ตัววัด M3 ที่แท้จริง
  perform pg_temp.must_fail_like('C8a ลบ reverses_id ทิ้งพร้อมเปลี่ยน source', format(
    $q$ update sri_os.transactions set reverses_id = null, source = 'manual' where id = %L $q$, v_r),
    'reverses_id');
  select reverses_id, source::text into v_link, v_src from sri_os.transactions where id = v_r;
  if v_link is null then
    raise exception 'FAIL: C8a ลิงก์กลับรายการถูกลบทิ้งได้ (source เหลือ %)', v_src;
  end if;

  -- C8b · ลบลิงก์ทิ้งเฉยๆ (ด่านลิงก์เดิมก็ปฏิเสธด้วย — ต้องยังปฏิเสธอยู่)
  perform pg_temp.must_fail_like('C8b ลบ reverses_id ทิ้ง', format(
    $q$ update sri_os.transactions set reverses_id = null where id = %L $q$, v_r),
    'reverses_id');

  -- C8c · null → ค่าใด **ยังทำได้** แต่ต้องผ่านด่านสะท้อนบรรทัดเดิม
  --        เหตุผล: เส้นทางนี้ไม่ได้ลบประวัติอะไร (ของเดิมไม่มีลิงก์) และยังถูกตรวจครบ
  --        ทั้ง fn_reverse_link_ok (ต้นฉบับมีจริง ผู้ถือเดียวกัน ยังไม่ถูกกลับรายการ)
  --        และ trg_reverse_mirrors_original (บรรทัดต้องสะท้อนตรงตัว)
  --        → ปิดทางนี้ด้วยคือกันแน่นเกิน: ใบที่ลงถูกแล้วแต่ลืมใส่ลิงก์จะซ่อมไม่ได้เลย
  perform pg_temp.mk_txn(v_x, 'THANAKORN', 'inc.other', null, pg_temp.mirror_of(v_o2));
  perform pg_temp.must_pass('C8c ตั้ง reverses_id จาก null เป็นค่าที่สะท้อนบรรทัดจริง', format(
    $q$ update sri_os.transactions set reverses_id = %L, source = 'reverse' where id = %L $q$,
    v_o2, v_x));

  -- C8d · และเมื่อตั้งแล้วก็แช่แข็งทันที (ไม่ใช่ช่องที่เปิดค้างไว้)
  perform pg_temp.must_fail_like('C8d ตั้งแล้วเปลี่ยนอีกไม่ได้', format(
    $q$ update sri_os.transactions set reverses_id = %L where id = %L $q$, v_o1, v_x),
    'reverses_id');

  raise notice 'ok C7/C8 · reverses_id ที่ไม่เป็น null เปลี่ยน/ลบไม่ได้ทุกผู้ถือ · null → ค่าใด ยังทำได้และถูกตรวจด้วยด่านสะท้อนบรรทัด';
end $$;

-- ============================================================
-- C9 · รายการข้ามผู้ถือ: ขาที่มีเงินสดกับขาที่ไม่มี บังคับ cash_date ต่างกันถูกต้อง
--      ด่านเป็น **per-row** จึงตัดสินแต่ละขาด้วยบรรทัดของขานั้นเอง
--      (ประตู fn_post_entry ใช้ cash_date ระดับ payload ใบเดียวกับทุกขา —
--       เคสผสมแบบนี้จึงต้องลงผ่านตารางโดยตรง ซึ่งเป็นเหตุผลที่ด่านต้องอยู่ที่ตาราง)
-- ============================================================
do $$
declare
  v_a uuid := '00000000-0000-0000-0000-0000000c0040';
  v_b uuid := '00000000-0000-0000-0000-0000000c0041';
  v_c uuid := '00000000-0000-0000-0000-0000000c0042';
  v_d uuid := '00000000-0000-0000-0000-0000000c0043';
begin
  -- C9a · ถูกต้อง: ขาจ่าย (มี 1100) มี cash_date · ขารับภาระ (ไม่มี 11xx) เป็น null
  perform pg_temp.must_pass('C9a ข้ามผู้ถือ ขาหนึ่งมีเงินสด ขาหนึ่งไม่มี', format(
    $q$ select pg_temp.mk_pair(%L, %L, 5000, current_date, null) $q$, v_a, v_b));
  if pg_temp.cf_cash(array[v_a, v_b]) <> -5000 then
    raise exception 'FAIL: C9a งบกระแสเงินสดควรเห็นเงินออก -5000 ได้ %', pg_temp.cf_cash(array[v_a, v_b]);
  end if;

  -- C9b · ขารับภาระที่ไม่มีบรรทัดเงินสดเลย แต่ใส่ cash_date → เงินสดผี ต้องปฏิเสธ
  perform pg_temp.must_fail_like('C9b ขาที่ไม่มีเงินสดแต่ใส่ cash_date', format(
    $q$ select pg_temp.mk_pair(%L, %L, 6000, current_date, current_date) $q$, v_c, v_d),
    'ไม่มีบรรทัดเงินสดเลย');
  if exists (select 1 from sri_os.transactions where id in (v_c, v_d)) then
    raise exception 'FAIL: C9b ขาที่ถูกปฏิเสธยังค้างอยู่ในสมุด';
  end if;

  -- C9c · ขาที่มีเงินสดแต่ไม่ใส่ cash_date ก็ต้องปฏิเสธ (ไม่ใช่กันแต่ขาที่ไม่มีเงินสด)
  perform pg_temp.must_fail_like('C9c ขาที่มีเงินสดแต่ไม่ใส่ cash_date', format(
    $q$ select pg_temp.mk_pair(%L, %L, 6000, null, null) $q$, v_c, v_d),
    'บรรทัดเงินสด');

  raise notice 'ok C9 · ด่านตัดสินทีละขาจากบรรทัดของขานั้นเอง (cash_date ของสองขาต่างกันได้โดยถูกต้อง)';
end $$;

-- ============================================================
-- C10 · เคส "ข้อมูลขาด" — ตัดสินสองข้อ และเขียนเหตุผลไว้ ไม่เงียบ
--
--  (ก) ไม่มีบรรทัดเลย → **ปฏิเสธ** แต่เป็นหน้าที่ของ Money Invariant 1
--      (trg_txn_needs_lines) ไม่ใช่ด่านนี้ · ด่านนี้เงียบตอน 0 บรรทัดโดยตั้งใจ
--      เพราะถ้าพูดด้วยจะได้ข้อความสองชุดของเรื่องเดียวกัน (บทเรียนข้อ 5)
--      เคสนี้ยืนยันว่า **ยังถูกปฏิเสธจริง** ไม่ใช่หลุดเพราะด่านใหม่เงียบ
--
--  (ข) cash_date ก่อน doc_date มากๆ → **ตัดสินว่าไม่กันในรอบนี้** (รายงานให้ตัดสินต่อ)
--      เหตุผล:
--        1. เกิดขึ้นจริงและถูกต้อง — รับเงินล่วงหน้า/มัดจำก่อนออกเอกสาร
--           (เงินเข้า 01/10 · ใบเสร็จลง 05/10) · ถ้ากัน = ลงของจริงไม่ได้
--        2. doc_date เองก็ไม่ถูกจำกัดว่าต้องไม่เกินวันนี้ · การกันเฉพาะความสัมพันธ์
--           ของสองวันนี้จึงไม่ได้ปิดอะไรที่เปิดอยู่ (ลงวันไหนก็ยังได้)
--        3. งวดที่ปิดแล้วถูกกันด้วย period_closes/doc_date อยู่แล้ว ซึ่งเป็นด่านที่
--           ตอบคำถาม "ตัวเลขที่ยื่นไปแล้วขยับได้ไหม" ตรงกว่าเกณฑ์ระยะห่างของวันที่
--        4. ฝั่ง personal_flexible ลงย้อนหลังได้ตาม Entity Policy — การตั้งเพดาน
--           ระยะห่างเองในโค้ดคือการตัดสินนโยบายแทนลูกพี่
--      ถ้าต้องการเตือน ให้ทำที่ **Data health (รายงาน)** ไม่ใช่ที่ด่านที่ปฏิเสธ
--      เคสนี้ล็อกพฤติกรรมปัจจุบันไว้ให้ชัด: ลงได้ และถ้าวันหนึ่งตัดสินใหม่ว่าต้องกัน
--      เคสนี้จะแดงให้รู้ตัวว่ากำลังเปลี่ยนพฤติกรรมที่ตั้งใจไว้
-- ============================================================
do $$
declare
  v_a uuid := '00000000-0000-0000-0000-0000000c0050';
  v_b uuid := '00000000-0000-0000-0000-0000000c0051';
begin
  -- (ก) หัวรายการที่ไม่มีบรรทัดเลย + cash_date null
  perform pg_temp.must_fail_like('C10a หัวรายการ 0 บรรทัด', format(
    $q$ select pg_temp.mk_txn(%L, 'SUTEE', 'inc.other', null, '[]'::jsonb) $q$, v_a),
    'บรรทัดบัญชี');

  -- (ก2) หัวรายการที่ไม่มีบรรทัดเลย + cash_date มีค่า — ต้องยังปฏิเสธ (ไม่หลุดทั้งสองด่าน)
  perform pg_temp.must_fail_like('C10a2 หัวรายการ 0 บรรทัด + cash_date', format(
    $q$ select pg_temp.mk_txn(%L, 'SUTEE', 'inc.other', current_date, '[]'::jsonb) $q$, v_a),
    'บรรทัดบัญชี');

  -- (ข) cash_date ก่อน doc_date 90 วัน — ตัดสินว่าไม่กัน (เหตุผลอยู่หัวข้อข้างบน)
  perform pg_temp.must_pass('C10b cash_date ก่อน doc_date 90 วัน (ตัดสินว่าไม่กัน)', format(
    $q$ select pg_temp.mk_txn(%L, 'SUTEE', 'inc.other', current_date - 90,
          '[{"coa":"1100","dr":900,"cr":0,"cf":"operating","bank":"00000000-0000-0000-0000-00000000cf02"},
             {"coa":"4900","dr":0,"cr":900,"cf":"operating"}]'::jsonb,
          array['หลักฐาน-CD.pdf'], 'manual', null, current_date) $q$, v_b));

  raise notice 'ok C10 · 0 บรรทัดยังถูกปฏิเสธด้วย Money Invariant 1 (ทั้งสองค่าของ cash_date) · ระยะห่าง cash_date-doc_date ตัดสินว่าไม่กันในรอบนี้ (เหตุผลอยู่ในไฟล์)';
end $$;

-- ---------- สรุป: ทุกใบที่ไฟล์นี้สร้างต้องผ่านด่านที่เลื่อนไว้จริง ----------
do $$
declare n int;
begin
  set constraints all immediate;
  select count(*) into n from sri_os.transactions where memo like 'CD %';
  if n < 12 then
    raise exception 'FAIL: นับใบที่เทสต์นี้สร้างได้แค่ % ใบ — เทสต์อาจไม่ได้ลงอะไรเลย', n;
  end if;
  raise notice 'ok C · ทั้ง % ใบของไฟล์นี้ผ่านด่านที่เลื่อนไว้ (เคสปฏิเสธไม่ทิ้งใบเสียรูปไว้)', n;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: ใบที่เทสต์นี้สร้างไว้เสียรูป: %', sqlerrm;
end $$;

rollback;
