-- ============================================================
-- SRI OS · เทสต์ด่านของ **บรรทัดบัญชี** ที่ย้ายจากประตูขึ้นมาเป็น trigger
--   (migration 20261008000012_line_guards_as_triggers.sql)
--
--   ข้อ 3 · คู่บัญชีของทุกบรรทัดต้องอยู่ในชุดที่ตารางกฎ (sri_os.txn_types) ระบุ
--   ข้อ 7 · bank_account_id ติดได้เฉพาะบรรทัดเงินสด 11xx
--   + ขาข้ามผู้ถือล็อกเป็น **รหัสตรง** (1310/2310 · 1710/3100 · 3200/4410)
--     ไม่ใช่แค่ "ประเภทบัญชีเดียวกัน" อย่างที่ประตูทำได้ (1300 ก็เป็นสินทรัพย์เหมือน 1310)
--
-- ประเด็นของไฟล์นี้: ด่านทั้งสองเคยอยู่ใน fn_post_entry() เท่านั้น = **เขียนตรง
--   เข้าตารางเลี่ยงได้** (PostgREST ยิง INSERT ตรงได้) · เคสปฏิเสธที่นี่จึงยิง
--   **INSERT/UPDATE ตรงเข้าตาราง** ไม่ผ่าน RPC และยิงทั้งในฐานะ authenticated
--   และในฐานะ superuser ของ cluster (กฎเงินห้ามขึ้นกับสิทธิ์)
--
--   G0  โครงสร้าง: trigger ผูกจริง · ฟังก์ชันปิด · definer + search_path ล็อก
--   G1  คู่บัญชีผิดหมวด → ปฏิเสธ (เงินกู้กลายเป็นรายได้ · ค่าเช่าลง 4900)
--   G2  ขาข้ามผู้ถือที่ใช้บัญชีประเภทเดียวกันแต่ผิดรหัส → ปฏิเสธ (1300 ≠ 1310)
--   G3  bank_account_id บนขาที่ไม่ใช่เงินสด → ปฏิเสธ (ทั้งขาลูกหนี้และขารายได้)
--   G4  UPDATE ก็ถูกกัน ไม่ใช่กันแค่ INSERT
--   G5  เคส "ไม่ส่งข้อมูล": ไม่ใส่ลักษณะข้ามผู้ถือแล้วลง 1310 → ต้องปฏิเสธ
--   G6  superuser ของ cluster ก็ถูกกัน (ด่านอยู่ที่ trigger ไม่ใช่ RLS/ตารางสิทธิ์)
--   G7  **เส้นทางที่ถูกต้องต้องยังทำได้ทั้งหมด** (กันแน่นเกิน = พัง)
--   G8  สำเนาคู่บัญชีระหว่างกันในฝั่ง DB ตอบตรงกับ src/lib/rules/intercompany.ts
--
-- เส้นทางร่าง→อนุมัติ · ยืนยันเงิน · ปิด-เปิดงวด **ไม่** ทำซ้ำที่นี่โดยตั้งใจ —
--   ด่านของไฟล์นี้อยู่บน transaction_lines เท่านั้น และสามเส้นทางนั้นถูกเดินจริง
--   ในฐานะ authenticated อยู่แล้วที่ zz_approval_integrity_test (I13) ·
--   zz_history_guards_test (H11b/H11c) · zz_access_audit_test (X12c)
--   ซึ่งทั้งหมดลงบรรทัดบัญชีจริงผ่าน trigger ชุดนี้
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ **rollback** ปิดท้าย — ไม่ทิ้งรายการเงินไว้
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
create temporary table t_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_uid(label) values ('mgmt');
insert into auth.users(id) select id from t_uid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select id, label || '@lineguards.local', label, 'management', true from t_uid;

create or replace function pg_temp.uid(p_label text) returns uuid
language sql stable as $fn$ select id from t_uid where label = p_label $fn$;

create or replace function pg_temp.login(p_label text) returns void
language sql as $fn$
  select set_config('test.uid', coalesce((select id::text from t_uid where label = p_label), ''), true);
$fn$;

insert into sri_os.user_owner_access(user_id, owner_id)
select pg_temp.uid('mgmt'), o.id from sri_os.owners o;

-- บัญชีธนาคาร: ธนากร 2 บัญชี (ใช้ทดสอบโอนในคนเดียวกัน) · สุธี · SRI Corporation
insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
values
  ('00000000-0000-0000-0000-00000001b001', (select id from sri_os.owners where code='THANAKORN'),
   'BBL', 'ธนากร', 'ธนากร - BBL 001'),
  ('00000000-0000-0000-0000-00000001b002', (select id from sri_os.owners where code='THANAKORN'),
   'KBANK', 'ธนากร (สอง)', 'ธนากร - KBANK 002'),
  ('00000000-0000-0000-0000-00000001b003', (select id from sri_os.owners where code='SUTEE'),
   'KBANK', 'สุธี', 'สุธี - KBANK 003'),
  ('00000000-0000-0000-0000-00000001b004', (select id from sri_os.owners where code='SRI_CORP'),
   'SCB', 'SRI Corporation', 'SRI - SCB 004');

insert into sri_os.contacts(id, first_name, types)
values ('00000000-0000-0000-0000-00000001c001', 'คู่ค้าตัวอย่าง', array['tenant']);

-- ตัวช่วย
create or replace function pg_temp.must_fail_like(p_label text, p_sql text, p_needle text) returns void
language plpgsql as $fn$
declare v text;
begin
  begin
    execute p_sql;
  exception when others then
    v := sqlerrm;
    if v like 'FAIL:%' then raise; end if;
    if position(p_needle in v) = 0 then
      raise exception 'FAIL: % — ปฏิเสธถูกแต่ข้อความไม่มี "%" · ได้: %', p_label, p_needle, v;
    end if;
    return;
  end;
  raise exception 'FAIL: % — คำสั่งควรถูกปฏิเสธแต่สำเร็จ', p_label;
end $fn$;

create or replace function pg_temp.must_pass(p_label text, p_sql text) returns void
language plpgsql as $fn$
begin
  execute p_sql;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: % — เส้นทางที่ถูกต้องถูกปฏิเสธ (กันแน่นเกิน): %', p_label, sqlerrm;
end $fn$;

-- หัวรายการเปล่าในธุรกรรมนี้ (บรรทัดจึงเขียนได้ตามเส้นทาง post ปกติ)
create or replace function pg_temp.mk_txn(p_id uuid, p_type text, p_owner text,
                                          p_nature text default null,
                                          p_counter text default null) returns uuid
language plpgsql as $fn$
begin
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, cash_date, memo,
                                  attachments, contact_id,
                                  is_intercompany, counter_owner_id, intercompany_nature)
  select p_id, o.id, p_type, '2026-09-01', '2026-09-01', 'LG',
         array['หลักฐาน.pdf'], '00000000-0000-0000-0000-00000001c001',
         p_nature is not null,
         (select x.id from sri_os.owners x where x.code = p_counter),
         p_nature
    from sri_os.owners o where o.code = p_owner;
  return p_id;
end $fn$;

-- บรรทัดบัญชีที่ **ถูกต้อง** ของแต่ละหัวรายการ — ลงก่อนทุกเคสปฏิเสธโดยตั้งใจ:
--   (1) เคสปฏิเสธจึงเป็น "ยัดบรรทัดผิดเข้าใบที่กำลังลง" ซึ่งเป็นรูปที่เกิดจริง
--   (2) ทุกหัวรายการในไฟล์นี้จึงสมดุลครบคู่ → บล็อก G6b ยิง
--       `set constraints all immediate` ได้ และพิสูจน์ว่าไม่มีใบค้างรูป
create or replace function pg_temp.good_lines(p_id uuid, p_dr text, p_cr text,
                                              p_amt numeric, p_bank uuid) returns void
language plpgsql as $fn$
begin
  insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id, debit, credit)
  values (p_id, (select id from sri_os.chart_of_accounts where code = p_dr),
          case when p_dr like '11__' then p_bank end, p_amt, 0);
  insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id, debit, credit)
  values (p_id, (select id from sri_os.chart_of_accounts where code = p_cr),
          case when p_cr like '11__' then p_bank end, 0, p_amt);
end $fn$;

create or replace function pg_temp.coa(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.chart_of_accounts where code = p_code $fn$;

do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.t_uid to authenticated', s);
end $$;

-- ============================================================
-- G0 · โครงสร้าง — ไล่จาก catalog จริง ไม่ใช่ไล่ไฟล์
-- ============================================================
do $$
declare v text; r record;
begin
  -- (ก) ทั้งสองด่านต้องเป็น trigger **บนตาราง** ครอบทั้ง insert และ update
  --     (ถ้าอยู่แต่ในประตู การเขียนตรงผ่าน PostgREST เลี่ยงได้ — บทเรียนข้อ 6)
  foreach v in array array['fn_assert_line_coa_in_rules', 'fn_assert_line_bank_is_cash'] loop
    if not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                    where tg.tgrelid = 'sri_os.transaction_lines'::regclass
                      and p.proname = v and not tg.tgisinternal
                      and (tg.tgtype & 1) <> 0 and (tg.tgtype & 2) <> 0
                      and (tg.tgtype & 4) <> 0 and (tg.tgtype & 16) <> 0) then
      raise exception 'FAIL: ไม่มี trigger before insert or update for each row ที่เรียก % บน transaction_lines', v;
    end if;
  end loop;

  -- (ข) กฎเงินห้ามขึ้นกับสิทธิ์ · definer ต้องล็อก search_path · เรียกตรงไม่ได้
  for r in select p.proname, p.prosrc, p.prosecdef, p.proconfig, p.oid from pg_proc p
            where p.oid in ('sri_os.fn_assert_line_coa_in_rules()'::regprocedure,
                            'sri_os.fn_assert_line_bank_is_cash()'::regprocedure)
  loop
    if r.prosrc ~* 'fn_can' then
      raise exception 'FAIL: % เรียก fn_can → ปิดกฎเงินได้จากหน้า Settings', r.proname;
    end if;
    if not r.prosecdef then
      raise exception 'FAIL: % ไม่ใช่ security definer → ผู้ที่มองหัวรายการไม่เห็นจะได้ null แล้วหลุดด่าน', r.proname;
    end if;
    if not exists (select 1 from unnest(coalesce(r.proconfig, '{}')) c
                    where c in ('search_path=', 'search_path=""', 'search_path=sri_os')) then
      raise exception 'FAIL: % เป็น definer แต่ search_path ไม่ล็อก', r.proname;
    end if;
    if has_function_privilege('public', r.oid, 'execute')
       or has_function_privilege('anon', r.oid, 'execute')
       or has_function_privilege('authenticated', r.oid, 'execute') then
      raise exception 'FAIL: % เรียกตรงจากข้างนอกได้', r.proname;
    end if;
  end loop;

  -- (ค) ตารางคู่บัญชีระหว่างกันฝั่ง DB: public/anon เรียกไม่ได้
  if has_function_privilege('public', 'sri_os.fn_intercompany_pairs()', 'execute')
     or has_function_privilege('anon', 'sri_os.fn_intercompany_pairs()', 'execute')
     or has_function_privilege('anon', 'sri_os.fn_intercompany_coa(text)', 'execute') then
    raise exception 'FAIL: fn_intercompany_pairs/coa ยังเปิดให้ public/anon';
  end if;

  -- (ง) ประตูยังอ่านตารางกฎอยู่ — เป็นการตรวจ **เชิงโครงสร้าง** ไม่ใช่เชิงพฤติกรรม
  --     พูดตรงๆ ว่าเทสต์นี้พิสูจน์อะไรไม่ได้มาก: ตั้งแต่ด่านอยู่ที่ trigger แล้ว
  --     การถอดด่านซ้ำในประตูออก **ไม่มีผลที่สังเกตได้จากข้างนอกเลย** (ทั้งสองทาง
  --     รายการถูกปฏิเสธและม้วนกลับทั้งคำขอ ข้อความก็มีคำว่า "ตารางกฎ" เหมือนกัน)
  --     จึงเขียนเป็นเครื่องเตือนว่าประตูต้องไม่ **เดา** คู่บัญชีเอง (ต้องอ่าน txn_types)
  --     ไม่ใช่เครื่องพิสูจน์ว่าด่านซ้ำยังทำงาน · ถ้าวันหนึ่งจะถอดด่านซ้ำออกตามบทเรียนข้อ 5
  --     ให้ถอดเทสต์ข้อนี้พร้อมกัน ไม่ใช่ปล่อยให้มันแดงแล้วแก้ให้ผ่าน
  select p.prosrc into v from pg_proc p where p.oid = 'sri_os.fn_post_entry(jsonb)'::regprocedure;
  if v !~ 'txn_types' then
    raise exception 'FAIL: ประตู fn_post_entry ไม่ได้อ่านตารางกฎแล้ว — ถ้าประตูคิดคู่บัญชีเอง จะมีกฎที่สองทันที';
  end if;

  raise notice 'ok G0 · ด่านคู่บัญชีและด่าน bank เป็น trigger บนตาราง (insert+update) · ปิด execute · definer+search_path ล็อก · ไม่ถาม fn_can · ประตูยังตรวจซ้ำ';
end $$;

-- ============================================================
-- G1 · คู่บัญชีผิดหมวด → ปฏิเสธ (INSERT ตรง ไม่ผ่านประตู)
-- ============================================================
select pg_temp.login('mgmt');
set local role authenticated;

do $$
declare v_a uuid := '00000000-0000-0000-0000-00000001e001';
        v_b uuid := '00000000-0000-0000-0000-00000001e002';
begin
  -- (ก) เงินกู้ธนาคาร: คู่ที่ถูกคือ Dr 1100 / Cr 2410 (หนี้สินเพิ่ม ไม่ใช่รายได้)
  perform pg_temp.mk_txn(v_a, 'fin.loan_bank', 'THANAKORN');
  perform pg_temp.must_pass('G1a ขาบวก fin.loan_bank = Dr 1100 / Cr 2410', format(
    'select pg_temp.good_lines(%L, ''1100'', ''2410'', 500000, %L)',
    v_a, '00000000-0000-0000-0000-00000001b001'));

  -- แล้วยัดบรรทัดรายได้ค่าเช่าเข้าไปในใบเดียวกัน = เงินกู้กลายเป็นรายได้ (เคส A2 ของผู้ตรวจ)
  perform pg_temp.must_fail_like('G1a fin.loan_bank ลง Cr 4200', format($q$
    insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
    values (%L, %L, 0, 500000)
  $q$, v_a, pg_temp.coa('4200')), 'ตารางกฎ');

  -- (ข) ค่าเช่าลงบัญชีรายได้อื่น (4900) = หมวดกับบัญชีไม่ตรงกัน รายงานแยกไม่ออก
  perform pg_temp.mk_txn(v_b, 'inc.rent', 'THANAKORN');
  perform pg_temp.good_lines(v_b, '1100', '4200', 100, '00000000-0000-0000-0000-00000001b001');
  perform pg_temp.must_fail_like('G1b inc.rent ลง Cr 4900', format($q$
    insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
    values (%L, %L, 0, 100)
  $q$, v_b, pg_temp.coa('4900')), 'ตารางกฎ');

  raise notice 'ok G1 · คู่บัญชีผิดหมวดถูกปฏิเสธที่ตาราง (เงินกู้กลายเป็นรายได้ไม่ได้) · คู่ที่ตรงตารางกฎยังลงได้';
end $$;

-- ============================================================
-- G2 · ขาข้ามผู้ถือ — ล็อก **รหัสตรง** ไม่ใช่แค่ประเภทบัญชี
--      1300 (เงินให้กู้ยืม) เป็นสินทรัพย์เหมือน 1310 → ประตูเดิมปล่อยผ่าน
--      แต่ 1300 ไม่ใช่บัญชีที่คู่กับ 2310 → งบรวมตัดรายการระหว่างกันไม่ลง
-- ============================================================
do $$
declare v_a uuid := '00000000-0000-0000-0000-00000001e003';   -- ขาฝ่ายจ่าย (กู้ยืม)
        v_a2 uuid := '00000000-0000-0000-0000-00000001e013';  -- ขาฝ่ายรับ (คู่ของ v_a)
        v_b uuid := '00000000-0000-0000-0000-00000001e004';   -- ขาฝ่ายจ่าย (เพิ่มทุน)
        v_b2 uuid := '00000000-0000-0000-0000-00000001e014';  -- ขาฝ่ายรับ (คู่ของ v_b)
begin
  -- คู่กู้ยืมระหว่างกันที่ถูกต้อง: ธนากร Dr 1310 / Cr 1100 · สุธี Dr 1100 / Cr 2310
  perform pg_temp.mk_txn(v_a,  'trf.internal', 'THANAKORN', 'loan', 'SUTEE');
  perform pg_temp.mk_txn(v_a2, 'trf.internal', 'SUTEE',     'loan', 'THANAKORN');
  perform pg_temp.must_pass('G2a ขาบวก คู่กู้ยืมระหว่างกัน 1310 ↔ 2310', format(
    'select pg_temp.good_lines(%L, ''1310'', ''1100'', 500, %L), pg_temp.good_lines(%L, ''1100'', ''2310'', 500, %L)',
    v_a, '00000000-0000-0000-0000-00000001b001', v_a2, '00000000-0000-0000-0000-00000001b003'));

  -- 1300 (เงินให้กู้ยืม) เป็นสินทรัพย์เหมือน 1310 → ประตูเดิมปล่อยผ่าน แต่ไม่คู่กับ 2310
  perform pg_temp.must_fail_like('G2a ขากู้ยืมระหว่างกันลง 1300', format($q$
    insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
    values (%L, %L, 500, 0)
  $q$, v_a, pg_temp.coa('1300')), 'ตารางกฎ');

  -- ลักษณะ "เพิ่มทุน" ใช้ 1710/3100 → 1310 ของลักษณะอื่นลงไม่ได้
  perform pg_temp.mk_txn(v_b,  'trf.internal', 'SUTEE',    'capital', 'SRI_CORP');
  perform pg_temp.mk_txn(v_b2, 'trf.internal', 'SRI_CORP', 'capital', 'SUTEE');
  perform pg_temp.good_lines(v_b,  '1710', '1100', 1000, '00000000-0000-0000-0000-00000001b003');
  perform pg_temp.good_lines(v_b2, '1100', '3100', 1000, '00000000-0000-0000-0000-00000001b004');
  perform pg_temp.must_fail_like('G2b ขาเพิ่มทุนลง 1310 (คู่ของ loan)', format($q$
    insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
    values (%L, %L, 1000, 0)
  $q$, v_b, pg_temp.coa('1310')), 'ตารางกฎ');

  raise notice 'ok G2 · ขาข้ามผู้ถือล็อกเป็นรหัสตรงต่อลักษณะ (1300 และ 1310-ในลักษณะเพิ่มทุน ถูกปฏิเสธ) · คู่ที่ถูกต้องยังลงได้';
end $$;

-- ============================================================
-- G3 · bank_account_id ติดได้เฉพาะขาเงินสด 11xx (เคส A7 ของผู้ตรวจ)
-- ============================================================
do $$
declare v_a uuid := '00000000-0000-0000-0000-00000001e005';
        v_b uuid := '00000000-0000-0000-0000-00000001e006';
begin
  perform pg_temp.mk_txn(v_a, 'inc.rent', 'THANAKORN');
  -- ใบที่ถูกต้อง: ค้างรับค่าเช่า Dr 1200 / Cr 4200 (ไม่มีขาเงินสด)
  perform pg_temp.good_lines(v_a, '1200', '4200', 100, null);

  -- (ก) บัญชีธนาคารติดบนขารายได้ → กระทบยอดธนาคารจะนับบรรทัดที่เงินไม่ได้เข้าออก
  perform pg_temp.must_fail_like('G3a bank บนขา 4200', format($q$
    insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id, debit, credit)
    values (%L, %L, '00000000-0000-0000-0000-00000001b001', 0, 100)
  $q$, v_a, pg_temp.coa('4200')), 'เฉพาะขาเงินสด');

  -- (ข) ค้างรับที่แนบบัญชีมาด้วย: ขา 1200 ไม่ใช่เงินสด (บทเรียนข้อ 2 ของประตู)
  perform pg_temp.must_fail_like('G3b bank บนขาลูกหนี้ 1200', format($q$
    insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id, debit, credit)
    values (%L, %L, '00000000-0000-0000-0000-00000001b001', 100, 0)
  $q$, v_a, pg_temp.coa('1200')), 'เฉพาะขาเงินสด');

  -- (ค) ขาบวก: ขาเงินสดผูกบัญชีได้ และ **ต้อง** ผูก (Money Invariant 2 อีกด่าน)
  perform pg_temp.mk_txn(v_b, 'inc.rent', 'THANAKORN');
  perform pg_temp.must_pass('G3c ขาบวก bank บนขา 1100', format(
    'select pg_temp.good_lines(%L, ''1100'', ''4200'', 100, %L)',
    v_b, '00000000-0000-0000-0000-00000001b001'));

  raise notice 'ok G3 · bank_account_id บนขารายได้/ขาลูกหนี้ถูกปฏิเสธ · บนขาเงินสดยังลงได้';
end $$;

-- ============================================================
-- G4 · UPDATE ก็ต้องถูกกัน (ลงถูกก่อนแล้วแก้ทีหลัง = ทางอ้อมรอบด่าน INSERT)
--      แก้ได้เฉพาะในธุรกรรมที่สร้างหัวรายการ (fn_assert_line_writable) จึงทดสอบที่นี่
-- ============================================================
do $$
declare v_a uuid := '00000000-0000-0000-0000-00000001e007'; v_line uuid;
begin
  perform pg_temp.mk_txn(v_a, 'inc.rent', 'THANAKORN');
  insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id, debit, credit)
  values (v_a, pg_temp.coa('1100'), '00000000-0000-0000-0000-00000001b001', 100, 0);
  insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id, debit, credit)
  values (v_a, pg_temp.coa('4200'), null, 0, 100)
  returning id into v_line;   -- บรรทัดรายได้ค่าเช่า (ขาที่ไม่ใช่เงินสด)

  perform pg_temp.must_fail_like('G4a UPDATE เปลี่ยนบัญชีเป็น 4900', format(
    'update sri_os.transaction_lines set coa_id = %L where id = %L',
    pg_temp.coa('4900'), v_line), 'ตารางกฎ');
  perform pg_temp.must_fail_like('G4b UPDATE ติด bank เข้าขา 4200', format(
    'update sri_os.transaction_lines set bank_account_id = %L where id = %L',
    '00000000-0000-0000-0000-00000001b001', v_line), 'เฉพาะขาเงินสด');

  -- ขาบวก: แก้ memo ของบรรทัดในธุรกรรมที่สร้างมันเอง ยังทำได้
  perform pg_temp.must_pass('G4c ขาบวก UPDATE memo', format(
    'update sri_os.transaction_lines set memo = ''ค่าเช่า ก.ย.'' where id = %L', v_line));

  if (select coa_id from sri_os.transaction_lines where id = v_line) <> pg_temp.coa('4200') then
    raise exception 'FAIL: บัญชีของบรรทัดถูกเปลี่ยนไปแล้ว';
  end if;
  raise notice 'ok G4 · แก้บัญชี/ติด bank ด้วย UPDATE ไม่ได้ · แก้ memo ยังได้';
end $$;

-- ============================================================
-- G5 · เคส "ไม่ส่งข้อมูล" — ไม่ระบุลักษณะข้ามผู้ถือ แล้วลงบัญชีระหว่างกัน
--      ต้องปฏิเสธ ไม่ใช่เดาว่าเป็นลักษณะไหน (บทเรียนข้อ 1)
-- ============================================================
do $$
declare v_a uuid := '00000000-0000-0000-0000-00000001e008';
begin
  perform pg_temp.mk_txn(v_a, 'trf.internal', 'THANAKORN');   -- ไม่ส่ง nature
  -- ใบที่ถูกต้องของหมวดนี้เมื่อไม่ใช่รายการข้ามผู้ถือ = ย้ายกระเป๋าในคนเดียวกัน
  perform pg_temp.good_lines(v_a, '1100', '1100', 500, '00000000-0000-0000-0000-00000001b001');

  perform pg_temp.must_fail_like('G5a 1310 บนรายการที่ไม่ได้ระบุลักษณะ', format($q$
    insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
    values (%L, %L, 500, 0)
  $q$, v_a, pg_temp.coa('1310')), 'ตารางกฎ');

  if sri_os.fn_intercompany_coa(null) is not null
     or sri_os.fn_intercompany_coa('') is not null then
    raise exception 'FAIL: fn_intercompany_coa เดาคู่บัญชีให้ลักษณะที่ไม่ได้ส่งมา';
  end if;
  raise notice 'ok G5 · ไม่ระบุลักษณะข้ามผู้ถือ = ลงบัญชีระหว่างกันไม่ได้ · ฟังก์ชันคู่บัญชีไม่เดาค่าว่าง';
end $$;

-- ============================================================
-- G6 · superuser ของ cluster ก็ถูกกัน — ด่านอยู่ที่ trigger ไม่ใช่ RLS
--      (RLS เป็นชั้นที่ policy ในอนาคตเขียนทับได้ · trigger ไม่ได้)
-- ============================================================
reset role;
do $$
declare v_a uuid := '00000000-0000-0000-0000-00000001e009';
begin
  perform pg_temp.mk_txn(v_a, 'inc.rent', 'SRI_CORP');
  perform pg_temp.good_lines(v_a, '1100', '4200', 100, '00000000-0000-0000-0000-00000001b004');

  perform pg_temp.must_fail_like('G6a superuser ลง Cr 4900 ในหมวดค่าเช่า', format($q$
    insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit)
    values (%L, %L, 0, 100)
  $q$, v_a, pg_temp.coa('4900')), 'ตารางกฎ');
  perform pg_temp.must_fail_like('G6b superuser ติด bank บนขา 4200', format($q$
    insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id, debit, credit)
    values (%L, %L, '00000000-0000-0000-0000-00000001b004', 0, 100)
  $q$, v_a, pg_temp.coa('4200')), 'เฉพาะขาเงินสด');
  raise notice 'ok G6 · ด่านทั้งสองบังคับกับ superuser ของ cluster ด้วย (ไม่ใช่ด่านที่ขึ้นกับสิทธิ์)';
end $$;

-- G6b · ทุกใบที่ไฟล์นี้สร้าง (รวมใบของเคสปฏิเสธ) ต้องผ่านด่านที่เลื่อนไว้ได้จริง
--       = เคสปฏิเสธข้างบนปฏิเสธ **เฉพาะบรรทัดที่ผิด** ไม่ได้ทำให้ใบเสียรูป
--       (ยิงด่านที่เลื่อนไว้ตอนนี้เลย แล้วคืนสภาพ deferred เหมือนที่ fn_post_entry ทำ)
do $$
declare n int;
begin
  set constraints all immediate;
  set constraints all deferred;
  select count(*) into n from sri_os.transactions where memo = 'LG';
  if n < 9 then raise exception 'FAIL: นับใบของเคสปฏิเสธได้แค่ % ใบ — เทสต์อาจไม่ได้ลงอะไรเลย', n; end if;
  raise notice 'ok G6b · ทั้ง % ใบของเคสปฏิเสธยังสมดุลครบคู่ (รวมคู่ข้ามผู้ถือ) และผ่านด่านที่เลื่อนไว้', n;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: ใบที่เคสปฏิเสธสร้างไว้เสียรูป — ด่านปฏิเสธมากกว่าบรรทัดที่ผิด: %', sqlerrm;
end $$;

-- ============================================================
-- G7 · **เส้นทางที่ถูกต้องต้องยังทำได้ทั้งหมด** — เดินผ่านประตูจริงในฐานะ authenticated
--      ปกติ · ค้างรับ · ล้างค้าง · โอนในคนเดียวกัน · ข้ามผู้ถือ 2 ขา (กู้ยืม/เพิ่มทุน/
--      ปันผล) · กลับรายการ · กำไร · ขาดทุน · แยกเงินต้น-ดอกเบี้ย · นิติบุคคลแนบไฟล์
--      ถ้าเคสใดล้ม = กันแน่นเกินจนใช้งานไม่ได้ ซึ่งก็คือพัง (บทเรียนข้อ 7)
-- ============================================================
select pg_temp.login('mgmt');
set local role authenticated;

do $$
declare
  v_t uuid := (select id from sri_os.owners where code='THANAKORN');
  v_s uuid := (select id from sri_os.owners where code='SUTEE');
  v_c uuid := (select id from sri_os.owners where code='SRI_CORP');
  v_out jsonb; v_rent uuid; v_n int; v_bad text;
begin
  -- 1 · ปกติ: ค่าเช่าเข้าบัญชี
  v_out := sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','inc.rent','doc_date','2026-09-01','cash_date','2026-09-03','memo','G7-1',
    'transactions', jsonb_build_array(jsonb_build_object('owner_id', v_t, 'lines', jsonb_build_array(
      jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-00000001b001','debit',12000,'credit',0,'cf_category','operating'),
      jsonb_build_object('coa_code','4200','debit',0,'credit',12000,'cf_category','operating'))))));
  v_rent := ((v_out -> 'transaction_ids') ->> 0)::uuid;

  -- 2 · ค้างรับ (ไม่มีบรรทัดเงินสด → cash_date ต้องเป็น null)
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','inc.rent','doc_date','2026-09-05','memo','G7-2',
    'transactions', jsonb_build_array(jsonb_build_object('owner_id', v_t, 'lines', jsonb_build_array(
      jsonb_build_object('coa_code','1200','debit',8000,'credit',0,'cf_category','none'),
      jsonb_build_object('coa_code','4200','debit',0,'credit',8000,'cf_category','none'))))));

  -- 3 · ล้างค้าง (เก็บค่าเช่าที่ค้างไว้)
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','inv.collect_rent','doc_date','2026-09-10','cash_date','2026-09-10','memo','G7-3',
    'transactions', jsonb_build_array(jsonb_build_object('owner_id', v_t, 'lines', jsonb_build_array(
      jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-00000001b001','debit',8000,'credit',0,'cf_category','operating'),
      jsonb_build_object('coa_code','1200','debit',0,'credit',8000,'cf_category','operating'))))));

  -- 4 · โอนระหว่างบัญชีของตัวเอง (ไม่เข้า P&L ไม่เข้า CF)
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','trf.internal','doc_date','2026-09-11','cash_date','2026-09-11','memo','G7-4',
    'transactions', jsonb_build_array(jsonb_build_object('owner_id', v_t, 'lines', jsonb_build_array(
      jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-00000001b002','debit',5000,'credit',0,'cf_category','none'),
      jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-00000001b001','debit',0,'credit',5000,'cf_category','none'))))));

  -- 5 · ข้ามผู้ถือ: กู้ยืมระหว่างกัน (1310 ↔ 2310) สองขาคู่กัน
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','trf.internal','doc_date','2026-09-12','cash_date','2026-09-12','memo','G7-5',
    'transactions', jsonb_build_array(
      jsonb_build_object('owner_id', v_t, 'counter_owner_id', v_s, 'intercompany_nature','loan',
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1310','debit',20000,'credit',0,'cf_category','investing'),
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-00000001b001','debit',0,'credit',20000,'cf_category','investing'))),
      jsonb_build_object('owner_id', v_s, 'counter_owner_id', v_t, 'intercompany_nature','loan',
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-00000001b003','debit',20000,'credit',0,'cf_category','financing'),
          jsonb_build_object('coa_code','2310','debit',0,'credit',20000,'cf_category','financing'))))));

  -- 6 · ข้ามผู้ถือ: เพิ่มทุนเข้าบริษัท (1710 ↔ 3100) · ขานิติบุคคลต้องมีหลักฐาน+คู่ค้า
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','trf.internal','doc_date','2026-09-13','cash_date','2026-09-13','memo','G7-6',
    'attachments', jsonb_build_array('โอนเพิ่มทุน.pdf'),
    'contact_id','00000000-0000-0000-0000-00000001c001',
    'transactions', jsonb_build_array(
      jsonb_build_object('owner_id', v_s, 'counter_owner_id', v_c, 'intercompany_nature','capital',
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1710','debit',100000,'credit',0,'cf_category','investing'),
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-00000001b003','debit',0,'credit',100000,'cf_category','investing'))),
      jsonb_build_object('owner_id', v_c, 'counter_owner_id', v_s, 'intercompany_nature','capital',
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-00000001b004','debit',100000,'credit',0,'cf_category','financing'),
          jsonb_build_object('coa_code','3100','debit',0,'credit',100000,'cf_category','financing'))))));

  -- 7 · ข้ามผู้ถือ: บริษัทจ่ายปันผลให้ผู้ถือหุ้น (3200 ↔ 4410)
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','trf.internal','doc_date','2026-09-14','cash_date','2026-09-14','memo','G7-7',
    'attachments', jsonb_build_array('มติจ่ายปันผล.pdf'),
    'contact_id','00000000-0000-0000-0000-00000001c001',
    'transactions', jsonb_build_array(
      jsonb_build_object('owner_id', v_c, 'counter_owner_id', v_s, 'intercompany_nature','dividend',
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','3200','debit',50000,'credit',0,'cf_category','financing'),
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-00000001b004','debit',0,'credit',50000,'cf_category','financing'))),
      jsonb_build_object('owner_id', v_s, 'counter_owner_id', v_c, 'intercompany_nature','dividend',
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-00000001b003','debit',50000,'credit',0,'cf_category','operating'),
          jsonb_build_object('coa_code','4410','debit',0,'credit',50000,'cf_category','operating'))))));

  -- 8 · กลับรายการของข้อ 1 (รหัสเดิม สลับด้าน · ไม่มีไฟล์แนบเพราะหลักฐานคือต้นฉบับ)
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','inc.rent','doc_date','2026-09-15','cash_date','2026-09-15','memo','G7-8',
    'source','reverse','reverses_id', v_rent::text,
    'transactions', jsonb_build_array(jsonb_build_object('owner_id', v_t, 'lines', jsonb_build_array(
      jsonb_build_object('coa_code','4200','debit',12000,'credit',0,'cf_category','operating'),
      jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-00000001b001','debit',0,'credit',12000,'cf_category','operating'))))));

  -- 9 · ขายทรัพย์ได้กำไร (cr ต้นทุน + gain)
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','inv.sell_re','doc_date','2026-09-16','cash_date','2026-09-16','memo','G7-9',
    'transactions', jsonb_build_array(jsonb_build_object('owner_id', v_t, 'lines', jsonb_build_array(
      jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-00000001b001','debit',1200000,'credit',0,'cf_category','investing'),
      jsonb_build_object('coa_code','1500','debit',0,'credit',1000000,'cf_category','investing'),
      jsonb_build_object('coa_code','4300','debit',0,'credit',200000,'cf_category','none'))))));

  -- 10 · ขายทรัพย์ขาดทุน (dr loss)
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','inv.sell_re','doc_date','2026-09-17','cash_date','2026-09-17','memo','G7-10',
    'transactions', jsonb_build_array(jsonb_build_object('owner_id', v_t, 'lines', jsonb_build_array(
      jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-00000001b001','debit',800000,'credit',0,'cf_category','investing'),
      jsonb_build_object('coa_code','5910','debit',200000,'credit',0,'cf_category','none'),
      jsonb_build_object('coa_code','1500','debit',0,'credit',1000000,'cf_category','investing'))))));

  -- 11 · รับคืนเงินต้น + ดอกเบี้ย แยกสองบรรทัด (เงินต้น Investing · ดอกเบี้ย Operating)
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','inv.loan_back','doc_date','2026-09-18','cash_date','2026-09-18','memo','G7-11',
    'transactions', jsonb_build_array(jsonb_build_object('owner_id', v_t, 'lines', jsonb_build_array(
      jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-00000001b001','debit',11000,'credit',0,'cf_category','investing'),
      jsonb_build_object('coa_code','1300','debit',0,'credit',10000,'cf_category','investing'),
      jsonb_build_object('coa_code','4120','debit',0,'credit',1000,'cf_category','operating'))))));

  -- 12 · นิติบุคคล: ค่าเช่าเข้าบริษัท พร้อมหลักฐาน + คู่ค้า
  perform sri_os.fn_post_entry(jsonb_build_object(
    'txn_type_code','inc.rent','doc_date','2026-09-19','cash_date','2026-09-19','memo','G7-12',
    'attachments', jsonb_build_array('ใบแจ้งหนี้.pdf'),
    'contact_id','00000000-0000-0000-0000-00000001c001',
    'transactions', jsonb_build_array(jsonb_build_object('owner_id', v_c, 'lines', jsonb_build_array(
      jsonb_build_object('coa_code','1100','bank_account_id','00000000-0000-0000-0000-00000001b004','debit',30000,'credit',0,'cf_category','operating'),
      jsonb_build_object('coa_code','4200','debit',0,'credit',30000,'cf_category','operating'))))));

  -- ตรวจผล: 12 เหตุการณ์ โดยข้ามผู้ถือสามเคสนับสองใบต่อเคส = 15 ใบ
  reset role;
  select count(*) into v_n from sri_os.transactions where memo like 'G7-%';
  if v_n <> 15 then
    raise exception 'FAIL: เส้นทางที่ถูกต้องลงได้ % ใบ (ต้อง 15 ใบ = 12 เหตุการณ์ + ข้ามผู้ถือ 3 เคสนับสองใบ)', v_n;
  end if;
  select string_agg(t.memo, ', ') into v_bad from sri_os.transactions t
   where t.memo like 'G7-%'
     and ((select coalesce(sum(l.debit),0) from sri_os.transaction_lines l where l.transaction_id = t.id)
       <> (select coalesce(sum(l.credit),0) from sri_os.transaction_lines l where l.transaction_id = t.id)
      or (select count(*) from sri_os.transaction_lines l where l.transaction_id = t.id) < 2);
  if v_bad is not null then
    raise exception 'FAIL: มีใบที่ไม่สมดุล/บรรทัดไม่ครบในเส้นทางที่ถูกต้อง: %', v_bad;
  end if;
  set local role authenticated;
  raise notice 'ok G7 · ปกติ · ค้างรับ · ล้างค้าง · โอนในคนเดียวกัน · ข้ามผู้ถือ 2 ขา (กู้ยืม/เพิ่มทุน/ปันผล) · กลับรายการ · กำไร · ขาดทุน · แยกเงินต้น-ดอกเบี้ย · นิติบุคคล = ลงได้ครบ 15 ใบ';
end $$;

-- ============================================================
-- G8 · สำเนาคู่บัญชีระหว่างกันฝั่ง DB ต้องตรงกับ src/lib/rules/intercompany.ts
--      (ตารางนี้ sync:rules ยังไม่ครอบ → ต้องมีอะไรดังเมื่อมันเพี้ยน)
-- ============================================================
reset role;
do $$
declare v text; n int;
begin
  if sri_os.fn_intercompany_coa('advance')  is distinct from array['1310','2310']
   or sri_os.fn_intercompany_coa('loan')     is distinct from array['1310','2310']
   or sri_os.fn_intercompany_coa('capital')  is distinct from array['1710','3100']
   or sri_os.fn_intercompany_coa('dividend') is distinct from array['3200','4410'] then
    raise exception 'FAIL: คู่บัญชีระหว่างกันฝั่ง DB ไม่ตรงกับ INTERCOMPANY_RULES ใน src/lib/rules/intercompany.ts';
  end if;
  select count(*) into n from sri_os.fn_intercompany_pairs();
  if n <> 4 then raise exception 'FAIL: ลักษณะข้ามผู้ถือในฝั่ง DB มี % (ของจริง 4)', n; end if;

  -- ทุกลักษณะที่ตาราง transactions อนุญาต ต้องมีคู่บัญชี (ไม่งั้นผู้ใช้กดแล้วตาย)
  select string_agg(x.nature, ', ') into v
    from (select (regexp_matches(pg_get_constraintdef(c.oid), '''([a-z_]+)''::text', 'g'))[1] as nature
            from pg_constraint c
           where c.conrelid = 'sri_os.transactions'::regclass
             and c.conname = 'transactions_intercompany_nature_check') x
   where not exists (select 1 from sri_os.fn_intercompany_pairs() p where p.nature = x.nature);
  if v is not null then
    raise exception 'FAIL: ลักษณะข้ามผู้ถือที่ตารางอนุญาตแต่ไม่มีคู่บัญชีในฝั่ง DB: %', v;
  end if;

  -- ทุกรหัสต้องมีในผังบัญชีจริง
  select string_agg(x.code, ', ') into v
    from (select p.payer_coa as code from sri_os.fn_intercompany_pairs() p
          union select p.receiver_coa from sri_os.fn_intercompany_pairs() p) x
   where not exists (select 1 from sri_os.chart_of_accounts c where c.code = x.code);
  if v is not null then raise exception 'FAIL: ผังบัญชีขาดรหัสของคู่บัญชีระหว่างกัน: %', v; end if;

  raise notice 'ok G8 · คู่บัญชีระหว่างกันฝั่ง DB ครบ 4 ลักษณะ · ตรงกับ intercompany.ts · ตรงกับ constraint · ทุกรหัสมีในผังบัญชี';
end $$;

do $$ begin raise notice '=== line guards (คู่บัญชีตรงตารางกฎ + bank เฉพาะขาเงินสด) ผ่านทั้งหมด ==='; end $$;

rollback;
