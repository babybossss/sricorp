-- ============================================================
-- SRI OS · **คนอนุมัติต้องไม่ใช่คนคีย์** (C-2 · 20261025000018_draft_no_self_review.sql)
--
-- **รูที่พิสูจน์** — policy `draft_review` ให้ทุกคนที่มี `ledger.approve`
-- UPDATE ร่างได้ทุกแถว **รวมร่างที่ตัวเองคีย์** → คนเดียวคีย์เอง อนุมัติเอง
-- ลงสมุดเอง และ **งบดุลยังดุลทุกใบ** จึงไม่มี invariant ไหนฟ้อง
--
-- **ทุกเคสรันเป็น role `authenticated`** ไม่ใช่ superuser
--
-- สิ่งที่พิสูจน์
--   S0 · โครงสร้าง: คอลัมน์ + CHECK + trigger (BEFORE UPDATE) + สวิตช์ใน settings + รายงาน
--   S1 · เส้นทางปกติ: พนักงานคีย์ → ผู้อนุมัติคนอื่นอนุมัติ → 1 ใบ · 50,000 (ขาบวก)
--   S2 · ผู้อนุมัติ (ไม่ใช่ super_admin) อนุมัติร่างที่ตัวเองคีย์ → **ปฏิเสธ**
--        สมุดยัง 1 ใบ · 50,000 (ไม่ใช่ 2 ใบ · 100,000)
--   S3 · ปฏิเสธร่างของตัวเองก็ไม่ได้ (ไม่ใช่ห้ามแต่ขาอนุมัติ)
--   S4 · ใส่เหตุผลแล้วก็ยังไม่ได้ ถ้าไม่ใช่ super_admin (เหตุผลไม่ใช่ override ของทุกคน)
--   S5 · super_admin อนุมัติร่างตัวเองได้ **เมื่อมีเหตุผล ≥ 10 ตัวอักษร** · ไม่มีเหตุผล/สั้น = ปฏิเสธ
--   S6 · เหตุผลที่บันทึกแล้ว **แก้/ล้างไม่ได้** (ร่องรอยที่ลบไม่ได้จริง)
--   S7 · รายงาน `fn_self_reviewed_drafts()` เห็นใบนั้นพร้อมเหตุผล · คนที่ไม่มี owner.view_all เรียกไม่ได้
--   S8 · ชื่อผู้ตัดสินปลอมไม่ได้ (ส่งชื่อคนอื่น = ปฏิเสธ · เว้นไว้ = ระบบเติมชื่อคนที่กดจริง)
--   S9 · ย้ายชื่อคนคีย์แล้วอนุมัติเองไม่ได้ (ทางหลบที่ง่ายที่สุด)
--   S10 · สวิตช์ `settings[approval.self_review] = never` ปิดข้อยกเว้นได้จริง
--   **SM · MUTATION** — ถอด trigger แล้ววัดรูเป็นตัวเลข: ผู้อนุมัติคีย์เอง-อนุมัติเอง
--        ลงสมุดได้อีก 50,000 โดย `reviewed_by = created_by` และ **ไม่มีเหตุผลบันทึกไว้เลย**
-- ============================================================

\set ON_ERROR_STOP 1

begin;

create temporary table s_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into s_uid(label) values ('boss'), ('appA'), ('clerk');

insert into auth.users(id) select id from s_uid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, u.label || '@selfreview.local', u.label,
       case u.label when 'boss' then 'super_admin'
                    when 'appA' then 'management'
                    else 'staff' end, true
  from s_uid u;
insert into sri_os.user_owner_access(user_id, owner_id)
select u.id, o.id from s_uid u, sri_os.owners o;

create or replace function pg_temp.own(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.owners where code = p_code $fn$;

create or replace function pg_temp.uid(p_label text) returns uuid
language sql stable as $fn$ select id from s_uid where label = p_label $fn$;

/** สวมสิทธิ์ผู้ใช้ fixture (role ยังเป็น authenticated ตลอด) */
create or replace function pg_temp.login(p_label text) returns void
language sql as $fn$
  select set_config('test.uid', (select id::text from s_uid where label = p_label), true);
$fn$;

create or replace function pg_temp.must_fail_like(p_label text, p_sql text, p_needle text)
returns void language plpgsql as $fn$
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

/** ใบค้างจ่าย Dr 5900 / Cr 2100 — ไม่มีขาเงินสด จึงไม่ต้องมีบัญชีธนาคาร */
create or replace function pg_temp.payload(p_memo text, p_amount numeric default 50000)
returns jsonb language sql stable as $fn$
  select jsonb_build_object(
    'txn_type_code', 'exp.other',
    'doc_date', '2026-02-01',
    'memo', p_memo,
    'attachments', jsonb_build_array('ใบแจ้งหนี้.pdf'),
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', pg_temp.own('THANAKORN'),
      'lines', jsonb_build_array(
        jsonb_build_object('coa_code', '5900', 'debit', p_amount, 'credit', 0,
                           'cf_category', 'operating'),
        jsonb_build_object('coa_code', '2100', 'debit', 0, 'credit', p_amount,
                           'cf_category', 'operating')))));
$fn$;

/** คีย์ร่างหนึ่งใบในฐานะผู้ใช้ที่ระบุ แล้วคืนสิทธิ์เดิมให้ผู้เรียก */
create or replace function pg_temp.new_draft_as(p_label text, p_memo text,
                                                p_amount numeric default 50000)
returns uuid language plpgsql as $fn$
declare v_id uuid; v_prev text := coalesce(current_setting('test.uid', true), '');
begin
  perform pg_temp.login(p_label);
  insert into sri_os.draft_entries(owner_id, txn_type_code, doc_date, amount, memo,
                                   attachments, created_by)
  values (pg_temp.own('THANAKORN'), 'exp.other', '2026-02-01', p_amount, p_memo,
          array['ใบแจ้งหนี้.pdf'], auth.uid())
  returning id into v_id;
  perform set_config('test.uid', v_prev, true);
  return v_id;
exception when others then
  perform set_config('test.uid', v_prev, true);
  raise;
end $fn$;

create or replace function pg_temp.n_txn() returns int
language sql stable as $fn$
  select count(*)::int from sri_os.transactions
   where txn_type_code = 'exp.other' and status::text = 'posted';
$fn$;

create or replace function pg_temp.sum_5900() returns numeric
language sql stable as $fn$
  select coalesce(sum(v.debit), 0)
    from sri_os.v_ledger_posted v
    join sri_os.chart_of_accounts c on c.id = v.coa_id
   where c.code = '5900';
$fn$;

/** ตัววัดเดียวที่ใช้ทุกเคส: "กี่ใบ · กี่บาท" */
create or replace function pg_temp.book() returns text
language sql stable as $fn$
  select pg_temp.n_txn()::text || ' ใบ · ' || pg_temp.sum_5900()::text || ' บาท';
$fn$;

do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.s_uid to authenticated', s);
end $$;

-- ============================================================
-- S0 · โครงสร้าง — ไล่จาก catalog จริง
-- ============================================================
do $$
declare v text;
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'sri_os' and table_name = 'draft_entries'
                    and column_name = 'self_review_reason') then
    raise exception 'FAIL: S0 — ไม่มีคอลัมน์ self_review_reason (migration ไม่ถูก apply?) เทสต์นี้จะไม่ได้ตรวจอะไร';
  end if;
  if not exists (select 1 from pg_constraint
                  where conname = 'draft_entries_self_review_reason') then
    raise exception 'FAIL: S0 — ไม่มี CHECK draft_entries_self_review_reason';
  end if;
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.draft_entries'::regclass
                    and g.tgname = 'trg_draft_review_separation' and not g.tgisinternal
                    and (g.tgtype & 2) <> 0) then
    raise exception 'FAIL: S0 — ไม่มี trigger trg_draft_review_separation แบบ BEFORE';
  end if;
  if not exists (select 1 from sri_os.settings where key = 'approval.self_review') then
    raise exception 'FAIL: S0 — ไม่มีสวิตช์ settings[approval.self_review] (กฎเหล็กข้อ 5)';
  end if;
  if sri_os.fn_self_review_mode() <> 'super_admin_with_trail' then
    raise exception 'FAIL: S0 — ค่าตั้งต้นของสวิตช์ต้องเป็น super_admin_with_trail แต่เป็น %',
      sri_os.fn_self_review_mode();
  end if;

  -- ผู้ใช้จริงต้องมีสิทธิ์พอที่จะ "ลองละเมิด" ได้ ไม่งั้นเคสอื่นเขียวด้วยเหตุผลผิด
  if not has_table_privilege('authenticated', 'sri_os.draft_entries', 'UPDATE') then
    raise exception 'FAIL: S0 — authenticated ไม่มีสิทธิ์ UPDATE draft_entries';
  end if;
  if not has_function_privilege('authenticated',
       'sri_os.fn_self_reviewed_drafts(date, date)'::regprocedure, 'execute') then
    raise exception 'FAIL: S0 — authenticated เรียกรายงานไม่ได้';
  end if;

  -- ด่านต้องอ่านผู้ตัดสินจากผู้ล็อกอินจริง (D-115)
  v := pg_get_functiondef('sri_os.fn_assert_draft_review_separation()'::regprocedure);
  if v !~ 'auth\.uid\(\)' then
    raise exception 'FAIL: S0 — ด่านไม่ได้อ่าน auth.uid()';
  end if;

  raise notice 'ok S0 · คอลัมน์ + CHECK + trigger BEFORE UPDATE + สวิตช์ใน settings + รายงาน · สิทธิ์ของ authenticated พอที่จะพิสูจน์ด่านได้';
end $$;

-- ============================================================
-- S1 · ขาบวก — พนักงานคีย์ · ผู้อนุมัติ "คนอื่น" อนุมัติ → ลงสมุดได้
--      (ถ้าขานี้ไม่ผ่าน เคสอื่นจะเขียวเพราะอนุมัติไม่ได้เลย ไม่ใช่เพราะด่านทำงาน)
-- ============================================================
do $$
declare v_draft uuid; v_out jsonb;
begin
  set local role authenticated;
  v_draft := pg_temp.new_draft_as('clerk', 'S1 ร่างที่พนักงานคีย์ 50,000');
  perform pg_temp.login('appA');

  v_out := sri_os.fn_approve_draft(v_draft, pg_temp.payload('S1 อนุมัติโดยคนอื่น'));
  if (v_out ->> 'posted_txn_id') is null then
    raise exception 'FAIL: S1 — ปากทางไม่คืนเลขใบ';
  end if;
  if pg_temp.n_txn() <> 1 or pg_temp.sum_5900() <> 50000 then
    raise exception 'FAIL: S1 — ต้องได้ 1 ใบ · 50,000 แต่ได้ %', pg_temp.book();
  end if;
  if (select reviewed_by from sri_os.draft_entries where id = v_draft) <> pg_temp.uid('appA') then
    raise exception 'FAIL: S1 — ผู้อนุมัติต้องถูกบันทึกเป็น appA';
  end if;
  if (select self_review_reason from sri_os.draft_entries where id = v_draft) is not null then
    raise exception 'FAIL: S1 — ใบที่คนอื่นอนุมัติต้องไม่มีเหตุผล "อนุมัติเอง" ติดอยู่';
  end if;

  reset role;
  raise notice 'ok S1 · พนักงานคีย์ → ผู้อนุมัติคนอื่นอนุมัติ → 1 ใบ · 50,000 (เส้นทางปกติยังทำได้)';
exception when others then
  reset role; raise;
end $$;

-- ============================================================
-- S2 + S3 + S4 · ผู้อนุมัติที่ไม่ใช่ super_admin แตะร่างของตัวเองไม่ได้เลย
-- ============================================================
do $$
declare v_draft uuid;
begin
  set local role authenticated;
  perform pg_temp.login('appA');
  v_draft := pg_temp.new_draft_as('appA', 'S2 ร่างที่ผู้อนุมัติคีย์เอง 50,000');

  -- S2 · อนุมัติเองผ่านปากทาง → ปฏิเสธ
  perform pg_temp.must_fail_like('S2 ผู้อนุมัติอนุมัติร่างที่ตัวเองคีย์', format($q$
    select sri_os.fn_approve_draft(%L, pg_temp.payload('S2 อนุมัติร่างตัวเอง')) $q$, v_draft),
    'การแยกหน้าที่');

  if pg_temp.n_txn() <> 1 or pg_temp.sum_5900() <> 50000 then
    raise exception 'FAIL: S2 — สมุดต้องยังเป็น 1 ใบ · 50,000 แต่ได้ % (ถ้าได้ 2 ใบ · 100,000 คือรูที่เรามาปิด)',
      pg_temp.book();
  end if;

  -- S3 · ปฏิเสธร่างของตัวเองก็ไม่ได้ (ปิดทั้งสองขา ไม่ใช่แค่ขาอนุมัติ)
  perform pg_temp.must_fail_like('S3 ปฏิเสธร่างของตัวเอง', format($q$
    update sri_os.draft_entries set status = 'rejected', reject_reason = 'ยอดไม่ตรง'
     where id = %L $q$, v_draft),
    'การแยกหน้าที่');

  -- S4 · ใส่เหตุผลยาวๆ แล้วก็ยังไม่ได้ — เหตุผลไม่ใช่ปุ่ม override ของทุกคน
  update sri_os.draft_entries
     set self_review_reason = 'ด่วนมาก ลูกพี่สั่งทางโทรศัพท์ จึงอนุมัติเอง'
   where id = v_draft;
  perform pg_temp.must_fail_like('S4 ใส่เหตุผลแล้วอนุมัติเอง (ไม่ใช่ super_admin)', format($q$
    select sri_os.fn_approve_draft(%L, pg_temp.payload('S4 อนุมัติร่างตัวเองพร้อมเหตุผล')) $q$,
    v_draft), 'การแยกหน้าที่');

  if (select status::text from sri_os.draft_entries where id = v_draft) <> 'pending' then
    raise exception 'FAIL: S2-S4 — ร่างต้องยัง pending';
  end if;
  if pg_temp.n_txn() <> 1 then
    raise exception 'FAIL: S2-S4 — สมุดต้องยังมีใบเดียว แต่ได้ %', pg_temp.book();
  end if;

  reset role;
  raise notice 'ok S2-S4 · ผู้อนุมัติ (management) อนุมัติ/ปฏิเสธร่างที่ตัวเองคีย์ไม่ได้ · ใส่เหตุผลก็ไม่ช่วย · สมุดยัง 1 ใบ · 50,000';
exception when others then
  reset role; raise;
end $$;

-- ============================================================
-- S5 + S6 + S7 · ข้อยกเว้นของ super_admin — ทำได้ แต่ **ลบร่องรอยไม่ได้**
-- ============================================================
do $$
declare v_draft uuid; v_out jsonb; v_rows int; v_reason text; v_others int; v_total int;
begin
  set local role authenticated;
  v_draft := pg_temp.new_draft_as('boss', 'S5 ร่างที่ลูกพี่คีย์เอง 50,000');
  perform pg_temp.login('boss');

  -- (ก) ไม่มีเหตุผล → ปฏิเสธ (ข้อยกเว้นไม่ใช่ "ผ่านฟรี")
  perform pg_temp.must_fail_like('S5a super_admin อนุมัติร่างตัวเองโดยไม่มีเหตุผล', format($q$
    select sri_os.fn_approve_draft(%L, pg_temp.payload('S5a ไม่มีเหตุผล')) $q$, v_draft),
    'ต้องเขียนเหตุผลกำกับ');

  -- (ข) เหตุผลสั้นเกินไป → ปฏิเสธ ("x" ไม่ใช่เหตุผล)
  perform pg_temp.must_fail_like('S5b เหตุผลสั้นเกินไป', format($q$
    update sri_os.draft_entries set self_review_reason = 'x' where id = %L $q$, v_draft),
    'draft_entries_self_review_reason');

  if pg_temp.n_txn() <> 1 then
    raise exception 'FAIL: S5 — ยังไม่ควรมีใบใหม่ แต่ได้ %', pg_temp.book();
  end if;

  -- (ค) เหตุผลครบ → อนุมัติเองได้
  update sri_os.draft_entries
     set self_review_reason = 'ผู้ดูแลระบบคนเดียวในระบบ ยังไม่มีผู้อนุมัติคนที่สอง'
   where id = v_draft;
  v_out := sri_os.fn_approve_draft(v_draft, pg_temp.payload('S5c อนุมัติเองพร้อมเหตุผล'));

  if pg_temp.n_txn() <> 2 or pg_temp.sum_5900() <> 100000 then
    raise exception 'FAIL: S5c — ต้องได้ 2 ใบ · 100,000 แต่ได้ %', pg_temp.book();
  end if;
  select self_review_reason into v_reason from sri_os.draft_entries where id = v_draft;
  if v_reason is null then
    raise exception 'FAIL: S5c — เหตุผลต้องถูกบันทึกไว้บนแถวร่าง';
  end if;
  if (select reviewed_by from sri_os.draft_entries where id = v_draft) <> pg_temp.uid('boss') then
    raise exception 'FAIL: S5c — ผู้ตัดสินต้องเป็น boss';
  end if;

  -- S6 · ร่องรอยลบไม่ได้: แถวที่ตัดสินแล้วเป็นแถวตาย (20261025000017)
  perform pg_temp.must_fail_like('S6a ล้างเหตุผลทีหลัง', format($q$
    update sri_os.draft_entries set self_review_reason = null where id = %L $q$, v_draft),
    'แก้อะไรไม่ได้อีก');
  perform pg_temp.must_fail_like('S6b แก้เหตุผลเป็นข้อความอื่น', format($q$
    update sri_os.draft_entries set self_review_reason = 'เปลี่ยนเหตุผลย้อนหลัง'
     where id = %L $q$, v_draft),
    'แก้อะไรไม่ได้อีก');
  -- ลบร่างทิ้งก็ไม่ได้ (ไม่มี policy DELETE ของ draft_entries → เงียบ 0 แถว ไม่ใช่สำเร็จ)
  delete from sri_os.draft_entries where id = v_draft;
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then
    raise exception 'FAIL: S6c — ลบร่างที่ตัดสินแล้วได้ % แถว = ร่องรอยหายไปทั้งแถว', v_rows;
  end if;

  -- S7 · รายงานต้องเห็นใบนี้พร้อมเหตุผล และบอกว่ามีผู้อนุมัติคนอื่นกี่คน
  select count(*)::int into v_rows from sri_os.fn_self_reviewed_drafts();
  if v_rows <> 1 then
    raise exception 'FAIL: S7 — รายงานต้องเห็น 1 ใบ แต่เห็น % ใบ', v_rows;
  end if;
  -- จำนวน "ผู้อนุมัติคนอื่น" ต้อง **ไม่นับตัวผู้ตัดสินเอง** → ต้องน้อยกว่ายอดรวมพอดี 1
  -- (เทียบกับยอดรวมแทนการตรึงเลข เพราะไฟล์เทสต์อื่นทิ้งผู้ใช้ที่ commit ไว้ได้)
  select r.other_approvers_now into v_others
    from sri_os.fn_self_reviewed_drafts() r where r.draft_id = v_draft;
  select count(*)::int into v_total
    from sri_os.app_users u
    join sri_os.role_permissions rp on rp.role_key = u.role
   where rp.permission_key = 'ledger.approve' and u.is_active;
  if v_others <> v_total - 1 then
    raise exception 'FAIL: S7 — รายงานบอกว่ามีผู้อนุมัติคนอื่น % คน แต่ในระบบมีผู้อนุมัติ % คน (ต้องเป็น %-1 คือไม่นับตัวผู้ตัดสินเอง)',
      v_others, v_total, v_total;
  end if;
  if v_others < 1 then
    raise exception 'FAIL: S7 — ต้องมีผู้อนุมัติคนอื่นอยู่จริงอย่างน้อย 1 คน (appA) ไม่งั้นเคสนี้วัดอะไรไม่ได้';
  end if;
  if (select r.reason from sri_os.fn_self_reviewed_drafts() r where r.draft_id = v_draft)
     is distinct from v_reason then
    raise exception 'FAIL: S7 — รายงานต้องแสดงเหตุผลเดียวกับที่บันทึกไว้';
  end if;

  -- คนที่ไม่มี owner.view_all เรียกรายงานไม่ได้ (ผู้ถูกตรวจ ≠ ผู้คุมรายงาน)
  perform pg_temp.login('clerk');
  perform pg_temp.must_fail_like('S7b staff เรียกรายงานการอนุมัติตัวเอง',
    'select * from sri_os.fn_self_reviewed_drafts()', 'owner.view_all');

  reset role;
  raise notice 'ok S5-S7 · super_admin อนุมัติร่างตัวเองได้เมื่อมีเหตุผล (2 ใบ · 100,000) · ไม่มีเหตุผล/เหตุผลสั้น = ปฏิเสธ · เหตุผลแก้ไม่ได้ ลบร่างไม่ได้ · รายงานเห็นใบนั้นพร้อมจำนวนผู้อนุมัติคนอื่น (1 คน) · staff เรียกรายงานไม่ได้';
exception when others then
  reset role; raise;
end $$;

-- ============================================================
-- S8 + S9 · ทางหลบที่ต้องปิดไปพร้อมกัน
-- ============================================================
do $$
declare v_draft uuid; v_draft2 uuid;
begin
  set local role authenticated;
  v_draft := pg_temp.new_draft_as('clerk', 'S8 ร่างสำหรับทดสอบชื่อผู้ตัดสิน');
  perform pg_temp.login('appA');

  -- S8a · ใส่ชื่อคนอื่นเป็นผู้ตัดสิน (อนุมัติเองแต่ลงชื่อเพื่อน) → ปฏิเสธ
  perform pg_temp.must_fail_like('S8a ลงชื่อคนอื่นเป็นผู้ตัดสิน', format($q$
    update sri_os.draft_entries
       set status = 'rejected', reject_reason = 'ลองสวมชื่อคนอื่น', reviewed_by = %L
     where id = %L $q$, pg_temp.uid('boss'), v_draft),
    'ต้องเป็นคนที่กดจริง');

  -- S8b · เว้น reviewed_by ไว้ → ระบบเติมชื่อคนที่กดจริง (ไม่ใช่ null ค้างไว้)
  update sri_os.draft_entries set status = 'rejected', reject_reason = 'ยอดไม่ตรง'
   where id = v_draft;
  if (select reviewed_by from sri_os.draft_entries where id = v_draft)
     is distinct from pg_temp.uid('appA') then
    raise exception 'FAIL: S8b — เว้น reviewed_by ไว้ ระบบต้องเติมชื่อ appA ให้ · ได้ %',
      (select coalesce(reviewed_by::text, '(null)') from sri_os.draft_entries where id = v_draft);
  end if;
  if (select reviewed_at from sri_os.draft_entries where id = v_draft) is null then
    raise exception 'FAIL: S8b — reviewed_at ต้องถูกตั้งให้ตอนตัดสิน';
  end if;

  -- S9 · ย้ายชื่อคนคีย์ไปให้คนอื่น แล้วอนุมัติเอง (ทางหลบที่ง่ายที่สุด) → ปฏิเสธ
  v_draft2 := pg_temp.new_draft_as('appA', 'S9 ร่างที่ผู้อนุมัติคีย์เอง');
  perform pg_temp.must_fail_like('S9 ย้ายชื่อคนคีย์แล้วอนุมัติเอง', format($q$
    update sri_os.draft_entries
       set status = 'rejected', reject_reason = 'ย้ายชื่อคนคีย์', created_by = %L
     where id = %L $q$, pg_temp.uid('clerk'), v_draft2),
    'ย้ายชื่อคนคีย์ร่าง');

  if (select created_by from sri_os.draft_entries where id = v_draft2) <> pg_temp.uid('appA') then
    raise exception 'FAIL: S9 — ชื่อคนคีย์ต้องไม่ถูกย้าย';
  end if;

  reset role;
  raise notice 'ok S8-S9 · ลงชื่อคนอื่นเป็นผู้ตัดสินไม่ได้ · เว้นไว้ระบบเติมชื่อคนที่กดจริง · ย้ายชื่อคนคีย์แล้วอนุมัติเองไม่ได้';
exception when others then
  reset role; raise;
end $$;

-- ============================================================
-- S10 · สวิตช์ในตาราง config ต้องปิดข้อยกเว้นได้จริง
--       (วันที่มีผู้อนุมัติคนที่สอง ลูกพี่พลิกค่านี้แล้วจบ ไม่ต้องรอ migration)
-- ============================================================
do $$
declare v_draft uuid;
begin
  set local role authenticated;
  v_draft := pg_temp.new_draft_as('boss', 'S10 ร่างของลูกพี่ตอนสวิตช์ปิด');
  perform pg_temp.login('boss');

  update sri_os.draft_entries
     set self_review_reason = 'เหตุผลที่ยาวพอแต่สวิตช์ถูกปิดไว้แล้ว'
   where id = v_draft;

  -- `boss` มี settings.manage อยู่แล้ว → พลิกสวิตช์ได้ด้วยสิทธิ์ของตัวเอง
  update sri_os.settings set value = '"never"'::jsonb where key = 'approval.self_review';
  if sri_os.fn_self_review_mode() <> 'never' then
    raise exception 'FAIL: S10 — พลิกสวิตช์แล้วแต่ fn_self_review_mode() ยังเป็น %',
      sri_os.fn_self_review_mode();
  end if;

  perform pg_temp.must_fail_like('S10 super_admin อนุมัติเองตอนสวิตช์ปิด', format($q$
    select sri_os.fn_approve_draft(%L, pg_temp.payload('S10 ไม่ควรลงได้')) $q$, v_draft),
    'ห้ามอนุมัติร่างของตัวเองทุกกรณี');

  if pg_temp.n_txn() <> 2 then
    raise exception 'FAIL: S10 — สมุดต้องยังเป็น 2 ใบ แต่ได้ %', pg_temp.book();
  end if;

  update sri_os.settings set value = '"super_admin_with_trail"'::jsonb
   where key = 'approval.self_review';

  reset role;
  raise notice 'ok S10 · พลิก settings[approval.self_review] = never แล้วแม้ super_admin ก็อนุมัติร่างตัวเองไม่ได้ (สมุดยัง 2 ใบ)';
exception when others then
  reset role; raise;
end $$;

-- ============================================================
-- SM · **MUTATION** — ถอดด่านแล้ววัดรูเป็นตัวเลข
--      ถ้าไม่มี trigger: ผู้อนุมัติคีย์เอง-อนุมัติเอง-ลงสมุดเองได้ทันที
--      โดย `reviewed_by = created_by` และ **ไม่มีเหตุผลบันทึกไว้เลย** (ไม่มีอะไรฟ้อง)
-- ============================================================
do $$
declare v_draft uuid; v_before numeric; v_reason text; v_n int;
begin
  v_before := pg_temp.sum_5900();
  drop trigger trg_draft_review_separation on sri_os.draft_entries;

  set local role authenticated;
  v_draft := pg_temp.new_draft_as('appA', 'SM ร่างที่ผู้อนุมัติคีย์เองตอนด่านถูกถอด');
  perform pg_temp.login('appA');
  perform sri_os.fn_approve_draft(v_draft, pg_temp.payload('SM อนุมัติเองตอนด่านถูกถอด'));
  reset role;

  if pg_temp.sum_5900() <> v_before + 50000 then
    raise exception 'FAIL: SM — ถอดด่านแล้วต้องลงสมุดได้อีก 50,000 (ถ้าไม่ได้ แปลว่าเคสอื่นเขียวเพราะด่านอื่น ไม่ใช่ด่านนี้) · ได้ %',
      pg_temp.book();
  end if;
  select self_review_reason into v_reason from sri_os.draft_entries where id = v_draft;
  if v_reason is not null then
    raise exception 'FAIL: SM — ไม่ควรมีเหตุผลติดมาเอง';
  end if;
  select count(*)::int into v_n from sri_os.draft_entries
   where id = v_draft and reviewed_by = created_by;
  if v_n <> 1 then
    raise exception 'FAIL: SM — ใบนี้ควรมี reviewed_by = created_by';
  end if;

  raise notice 'ok SM (MUTATION) · ไม่มี trigger: ผู้อนุมัติคีย์เอง-อนุมัติเอง ลงสมุดได้อีก **50,000 บาท** โดย reviewed_by = created_by และไม่มีเหตุผลบันทึกไว้เลย → รายงานก็ไม่เห็น (ร่องรอยเดียวที่เหลือคือ audit_log ซึ่งไม่มีใครตั้งให้ไล่ดู) · ด่านจริงคือ trigger ไม่ใช่ธงบนหน้าจอ';
exception when others then
  reset role; raise;
end $$;

-- ============================================================
-- SMb · สภาพหลัง mutation ต้องกลับมาครบ (ถ้าไม่กลับ เทสต์ไฟล์อื่นจะเขียวผิด)
-- ============================================================
rollback;

do $$
begin
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.draft_entries'::regclass
                    and g.tgname = 'trg_draft_review_separation' and not g.tgisinternal) then
    raise exception 'FAIL: SMb — trigger ไม่กลับมาหลัง rollback';
  end if;
  if sri_os.fn_self_review_mode() <> 'super_admin_with_trail' then
    raise exception 'FAIL: SMb — สวิตช์ไม่กลับมาเป็นค่าตั้งต้นหลัง rollback';
  end if;
  raise notice 'ok SMb · trigger และสวิตช์กลับมาครบหลัง rollback';
end $$;

\echo 'zz_draft_self_review_test: ผ่านทุกข้อ'
