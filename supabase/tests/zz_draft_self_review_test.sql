-- ============================================================
-- SRI OS · **ผู้อนุมัติอนุมัติร่างของตัวเองได้ แต่ทุกใบถูกบันทึกไว้**
--            (C-2 · 20261025000018 + **20261025000019 (คำสั่งลูกพี่ 25/10)**)
--
-- ลูกพี่ตัดสินแล้ว: "ระดับ management คีย์เองได้ อนุมัติของตัวเองได้ ·
-- Manager ก็อนุมัติได้ คีย์เองได้" → โหมดปัจจุบันคือ `any_approver`
--
-- **"อนุญาต" ไม่เท่ากับ "ไม่บันทึก"** — ไฟล์นี้จึงพิสูจน์สองเรื่องคู่กัน
--   (1) ทำได้จริง ไม่ต้องเขียนเหตุผล    (2) ทุกใบขึ้นรายงานให้ไล่ดูได้
--
-- **ทุกเคสรันเป็น role `authenticated`** ไม่ใช่ superuser
--
-- สิ่งที่พิสูจน์
--   S0 · โครงสร้าง + โหมดปัจจุบันคือ any_approver
--   S1 · เส้นทางปกติ (พนักงานคีย์ · ผู้อนุมัติคนอื่นอนุมัติ) → ไม่ขึ้นรายงานอนุมัติตัวเอง
--   S2 · **management คีย์เอง-อนุมัติเอง → ทำได้** ไม่ต้องมีเหตุผล · แต่ขึ้นรายงาน
--   S3 · **manager คีย์เอง-อนุมัติเอง → ทำได้** (ลูกพี่ระบุชื่อระดับนี้ด้วย)
--   S4 · ปฏิเสธร่างของตัวเองก็ทำได้ และก็ขึ้นรายงาน (ไม่ใช่เฉพาะขาอนุมัติ)
--   S5 · เหตุผลเป็นช่อง **ไม่บังคับ** · ใส่แล้วถูกเก็บไว้ · S6 · แก้/ล้างทีหลังไม่ได้
--   S7 · รายงาน: staff เรียกไม่ได้ · เห็นครบทุกใบที่คนคีย์ = คนตัดสิน
--   **M1/M2/M3 · สวิตช์สามทางพลิกได้จริง** (never · super_admin_with_trail · any_approver)
--   S8 · ลงชื่อคนอื่นเป็นผู้ตัดสินไม่ได้ · เว้นไว้ระบบเติมชื่อคนที่กดจริง
--   S9 · ย้ายชื่อคนคีย์ไม่ได้
--   **SM · MUTATION** — ถอดด่านแล้ววัดได้ว่า **ประวัติการอนุมัติโกหกได้** และ
--        **รายงานตาบอด** (ย้ายชื่อคนคีย์ทิ้ง → ใบที่อนุมัติเองหายจากรายงาน)
-- ============================================================

\set ON_ERROR_STOP 1

begin;

create temporary table s_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into s_uid(label) values ('boss'), ('appA'), ('mgrC'), ('clerk');

insert into auth.users(id) select id from s_uid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, u.label || '@selfreview.local', u.label,
       case u.label when 'boss' then 'super_admin'
                    when 'appA' then 'management'
                    when 'mgrC' then 'manager'
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

/** จำนวนใบในรายงาน "คนคีย์ = คนตัดสิน" (ต้องเรียกในฐานะคนที่มี owner.view_all) */
create or replace function pg_temp.n_report() returns int
language sql as $fn$ select count(*)::int from sri_os.fn_self_reviewed_drafts() $fn$;

/** โหมดของสวิตช์ — เปลี่ยนด้วยสิทธิ์ settings.manage ของผู้ล็อกอินจริง */
create or replace function pg_temp.set_mode(p_mode text) returns void
language plpgsql as $fn$
begin
  update sri_os.settings set value = to_jsonb(p_mode) where key = 'approval.self_review';
  if sri_os.fn_self_review_mode() <> p_mode then
    raise exception 'FAIL: พลิกสวิตช์เป็น % ไม่สำเร็จ (อ่านได้ %)',
      p_mode, sri_os.fn_self_review_mode();
  end if;
end $fn$;

do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.s_uid to authenticated', s);
end $$;

-- ============================================================
-- S0 · โครงสร้าง + โหมดปัจจุบัน
-- ============================================================
do $$
declare v text;
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'sri_os' and table_name = 'draft_entries'
                    and column_name = 'self_review_reason') then
    raise exception 'FAIL: S0 — ไม่มีคอลัมน์ self_review_reason (migration ไม่ถูก apply?)';
  end if;
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.draft_entries'::regclass
                    and g.tgname = 'trg_draft_review_separation' and not g.tgisinternal
                    and (g.tgtype & 2) <> 0) then
    raise exception 'FAIL: S0 — ไม่มี trigger trg_draft_review_separation แบบ BEFORE';
  end if;
  if sri_os.fn_self_review_mode() <> 'any_approver' then
    raise exception 'FAIL: S0 — โหมดปัจจุบันต้องเป็น any_approver (คำสั่งลูกพี่ 25/10) แต่เป็น %',
      sri_os.fn_self_review_mode();
  end if;
  if not has_table_privilege('authenticated', 'sri_os.draft_entries', 'UPDATE') then
    raise exception 'FAIL: S0 — authenticated ไม่มีสิทธิ์ UPDATE draft_entries';
  end if;
  if not has_function_privilege('authenticated',
       'sri_os.fn_self_reviewed_drafts(date, date)'::regprocedure, 'execute') then
    raise exception 'FAIL: S0 — authenticated เรียกรายงานไม่ได้';
  end if;
  v := pg_get_functiondef('sri_os.fn_assert_draft_review_separation()'::regprocedure);
  if v !~ 'auth\.uid\(\)' then
    raise exception 'FAIL: S0 — ด่านไม่ได้อ่าน auth.uid()';
  end if;

  raise notice 'ok S0 · คอลัมน์ + trigger BEFORE UPDATE + รายงาน · โหมดปัจจุบัน = any_approver · สิทธิ์ของ authenticated พอที่จะพิสูจน์ด่านได้';
end $$;

-- ============================================================
-- S1 · ขาบวกของเส้นทางปกติ — พนักงานคีย์ · ผู้อนุมัติ "คนอื่น" อนุมัติ
--      ใบแบบนี้ **ไม่ใช่** การอนุมัติตัวเอง จึงต้องไม่ขึ้นรายงาน
-- ============================================================
do $$
declare v_draft uuid; v_n int;
begin
  set local role authenticated;
  v_draft := pg_temp.new_draft_as('clerk', 'S1 ร่างที่พนักงานคีย์ 50,000');
  perform pg_temp.login('appA');

  perform sri_os.fn_approve_draft(v_draft, pg_temp.payload('S1 อนุมัติโดยคนอื่น'));
  if pg_temp.n_txn() <> 1 or pg_temp.sum_5900() <> 50000 then
    raise exception 'FAIL: S1 — ต้องได้ 1 ใบ · 50,000 แต่ได้ %', pg_temp.book();
  end if;
  if (select reviewed_by from sri_os.draft_entries where id = v_draft) <> pg_temp.uid('appA') then
    raise exception 'FAIL: S1 — ผู้อนุมัติต้องถูกบันทึกเป็น appA';
  end if;

  perform pg_temp.login('boss');
  select count(*)::int into v_n from sri_os.fn_self_reviewed_drafts() r
   where r.draft_id = v_draft;
  if v_n <> 0 then
    raise exception 'FAIL: S1 — ใบที่คนอื่นอนุมัติต้องไม่ขึ้นรายงาน "อนุมัติตัวเอง"';
  end if;

  reset role;
  raise notice 'ok S1 · พนักงานคีย์ → ผู้อนุมัติคนอื่นอนุมัติ → 1 ใบ · 50,000 · ไม่ขึ้นรายงานอนุมัติตัวเอง';
exception when others then
  reset role; raise;
end $$;

-- ============================================================
-- S2 + S3 + S4 · **คำสั่งลูกพี่ 25/10** — management และ manager
--      คีย์เอง-อนุมัติเองได้ **ไม่ต้องมีเหตุผล** · และทุกใบขึ้นรายงาน
-- ============================================================
do $$
declare d2 uuid; d3 uuid; d4 uuid; v_n int;
begin
  set local role authenticated;

  -- S2 · management
  d2 := pg_temp.new_draft_as('appA', 'S2 ร่างที่ management คีย์เอง');
  perform pg_temp.login('appA');
  perform sri_os.fn_approve_draft(d2, pg_temp.payload('S2 อนุมัติร่างของตัวเอง'));
  if pg_temp.n_txn() <> 2 or pg_temp.sum_5900() <> 100000 then
    raise exception 'FAIL: S2 — management อนุมัติร่างตัวเองต้องลงสมุดได้ (ต้องเป็น 2 ใบ · 100,000) แต่ได้ %',
      pg_temp.book();
  end if;
  if (select self_review_reason from sri_os.draft_entries where id = d2) is not null then
    raise exception 'FAIL: S2 — ไม่ได้ใส่เหตุผล จึงต้องไม่มีเหตุผลงอกมาเอง';
  end if;
  if (select reviewed_by from sri_os.draft_entries where id = d2) <> pg_temp.uid('appA') then
    raise exception 'FAIL: S2 — ผู้ตัดสินต้องเป็น appA';
  end if;

  -- S3 · manager (ลูกพี่ระบุระดับนี้ด้วย)
  d3 := pg_temp.new_draft_as('mgrC', 'S3 ร่างที่ manager คีย์เอง');
  perform pg_temp.login('mgrC');
  perform sri_os.fn_approve_draft(d3, pg_temp.payload('S3 manager อนุมัติร่างของตัวเอง'));
  -- **วัดผลด้วยสายตาของคนที่เห็นสมุดทั้งเล่ม** — `manager` ถูก RLS จำกัดให้เห็นเฉพาะ
  -- รายการของทรัพย์ที่ตัวเองบริหาร (fn_can_read_txn) ถ้านับด้วยสายตาเขา ตัวเลขจะหายไป
  -- เองโดยที่เงินไม่ได้หายไปไหน → เคสจะแดงด้วยเหตุผลผิด
  perform pg_temp.login('boss');
  if pg_temp.n_txn() <> 3 or pg_temp.sum_5900() <> 150000 then
    raise exception 'FAIL: S3 — manager อนุมัติร่างตัวเองต้องลงสมุดได้ (3 ใบ · 150,000) แต่ได้ %',
      pg_temp.book();
  end if;

  -- S4 · ปฏิเสธร่างของตัวเองก็ทำได้ (ไม่ใช่เฉพาะขาอนุมัติ) และไม่แตะสมุด
  d4 := pg_temp.new_draft_as('appA', 'S4 ร่างที่ผู้คีย์ปฏิเสธเอง');
  perform pg_temp.login('appA');
  update sri_os.draft_entries set status = 'rejected', reject_reason = 'คีย์ผิดเอง'
   where id = d4;
  if (select status::text from sri_os.draft_entries where id = d4) <> 'rejected' then
    raise exception 'FAIL: S4 — ปฏิเสธร่างของตัวเองต้องทำได้';
  end if;
  if pg_temp.n_txn() <> 3 then
    raise exception 'FAIL: S4 — การปฏิเสธต้องไม่แตะสมุด แต่ได้ %', pg_temp.book();
  end if;

  -- ทั้งสามใบต้องขึ้นรายงาน ("อนุญาต" ไม่เท่ากับ "ไม่บันทึก")
  perform pg_temp.login('boss');
  select count(*)::int into v_n from sri_os.fn_self_reviewed_drafts() r
   where r.draft_id in (d2, d3, d4);
  if v_n <> 3 then
    raise exception 'FAIL: S2-S4 — รายงานต้องเห็นทั้ง 3 ใบที่คนคีย์ตัดสินเอง แต่เห็น % ใบ (รายงานที่ว่างเปล่าแย่กว่าไม่มีรายงาน เพราะทำให้เชื่อว่าไม่มี)',
      v_n;
  end if;
  if exists (select 1 from sri_os.fn_self_reviewed_drafts() r
              where r.draft_id = d2 and r.reason is not null) then
    raise exception 'FAIL: S2-S4 — รายงานต้องเห็นใบที่ไม่มีเหตุผลด้วย (เหตุผลเป็นช่องไม่บังคับ)';
  end if;

  reset role;
  raise notice 'ok S2-S4 · management และ manager คีย์เอง-อนุมัติเองได้ ไม่ต้องมีเหตุผล (3 ใบ · 150,000) · ปฏิเสธร่างตัวเองได้และไม่แตะสมุด · ทั้ง 3 ใบขึ้นรายงาน';
exception when others then
  reset role; raise;
end $$;

-- ============================================================
-- S5 + S6 + S7 · เหตุผลเป็นช่อง **ไม่บังคับ** แต่ใส่แล้วลบไม่ได้ · และใครเห็นรายงาน
-- ============================================================
do $$
declare v_draft uuid; v_rows int; v_reason text; v_others int; v_total int;
begin
  set local role authenticated;
  v_draft := pg_temp.new_draft_as('boss', 'S5 ร่างที่ลูกพี่คีย์เอง + ใส่เหตุผล');
  perform pg_temp.login('boss');

  -- เหตุผลสั้นเกินไปยังถูกปฏิเสธ (ถ้าจะใส่ ต้องเป็นเหตุผลจริง)
  perform pg_temp.must_fail_like('S5a เหตุผลสั้นเกินไป', format($q$
    update sri_os.draft_entries set self_review_reason = 'x' where id = %L $q$, v_draft),
    'draft_entries_self_review_reason');

  update sri_os.draft_entries
     set self_review_reason = 'ใบด่วน คีย์เองเพราะทีมบัญชียังไม่เข้า'
   where id = v_draft;
  perform sri_os.fn_approve_draft(v_draft, pg_temp.payload('S5 อนุมัติเองพร้อมเหตุผล'));

  if pg_temp.n_txn() <> 4 or pg_temp.sum_5900() <> 200000 then
    raise exception 'FAIL: S5 — ต้องได้ 4 ใบ · 200,000 แต่ได้ %', pg_temp.book();
  end if;
  select self_review_reason into v_reason from sri_os.draft_entries where id = v_draft;
  if v_reason is null then
    raise exception 'FAIL: S5 — เหตุผลที่ใส่ไว้ต้องถูกเก็บบนแถวร่าง';
  end if;

  -- S6 · ร่องรอยลบไม่ได้ (แถวที่ตัดสินแล้วเป็นแถวตาย · 20261025000017)
  perform pg_temp.must_fail_like('S6a ล้างเหตุผลทีหลัง', format($q$
    update sri_os.draft_entries set self_review_reason = null where id = %L $q$, v_draft),
    'แก้อะไรไม่ได้อีก');
  perform pg_temp.must_fail_like('S6b เปลี่ยนชื่อผู้ตัดสินย้อนหลัง', format($q$
    update sri_os.draft_entries set reviewed_by = %L where id = %L $q$,
    pg_temp.uid('appA'), v_draft),
    'แก้อะไรไม่ได้อีก');
  delete from sri_os.draft_entries where id = v_draft;
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then
    raise exception 'FAIL: S6c — ลบร่างที่ตัดสินแล้วได้ % แถว = ร่องรอยหายไปทั้งแถว', v_rows;
  end if;

  -- S7 · รายงานเห็นครบ 4 ใบที่คนคีย์ตัดสินเอง (S2 · S3 · S4 · S5)
  if pg_temp.n_report() <> 4 then
    raise exception 'FAIL: S7 — รายงานต้องเห็น 4 ใบ แต่เห็น % ใบ', pg_temp.n_report();
  end if;
  -- จำนวน "ผู้อนุมัติคนอื่น" ต้องไม่นับตัวผู้ตัดสินเอง → น้อยกว่ายอดรวมพอดี 1
  select r.other_approvers_now into v_others
    from sri_os.fn_self_reviewed_drafts() r where r.draft_id = v_draft;
  select count(*)::int into v_total
    from sri_os.app_users u
    join sri_os.role_permissions rp on rp.role_key = u.role
   where rp.permission_key = 'ledger.approve' and u.is_active;
  if v_others <> v_total - 1 then
    raise exception 'FAIL: S7 — รายงานบอกผู้อนุมัติคนอื่น % คน แต่ในระบบมี % คน (ต้องไม่นับตัวผู้ตัดสินเอง)',
      v_others, v_total;
  end if;

  -- staff เรียกรายงานไม่ได้ (ผู้ถูกตรวจ ≠ ผู้คุมรายงาน)
  perform pg_temp.login('clerk');
  perform pg_temp.must_fail_like('S7b staff เรียกรายงาน',
    'select * from sri_os.fn_self_reviewed_drafts()', 'owner.view_all');

  reset role;
  raise notice 'ok S5-S7 · เหตุผลไม่บังคับ แต่ถ้าใส่ต้องเป็นเหตุผลจริงและลบ/แก้ย้อนหลังไม่ได้ · รายงานเห็นครบ 4 ใบ · ไม่นับตัวผู้ตัดสินเองในจำนวนผู้อนุมัติคนอื่น · staff เรียกรายงานไม่ได้';
exception when others then
  reset role; raise;
end $$;

-- ============================================================
-- M1 + M2 + M3 · **สวิตช์สามทางต้องพลิกได้จริง** ไม่ใช่มีไว้เฉยๆ
--      วันที่ลูกพี่มีทีมบัญชีหลายคนแล้วอยากเปิดด่านกลับ ต้องทำได้โดยไม่แก้โค้ด
-- ============================================================
do $$
declare dA uuid; dB uuid; v_n0 int;
begin
  set local role authenticated;
  -- วัดด้วยสายตาของคนที่เห็นสมุดทั้งเล่มเสมอ (ตัวเลขที่วัดด้วยสายตาคนที่เห็นไม่ครบ
  -- จะ "หาย" เองโดยที่เงินไม่ได้หายไปไหน)
  perform pg_temp.login('boss');
  v_n0 := pg_temp.n_txn();
  dA := pg_temp.new_draft_as('appA', 'M ร่างของ management');
  dB := pg_temp.new_draft_as('boss', 'M ร่างของลูกพี่');

  -- ---------- M1 · never = ห้ามทุกคน รวม super_admin ----------
  perform pg_temp.login('boss');
  perform pg_temp.set_mode('never');
  perform pg_temp.must_fail_like('M1a super_admin อนุมัติเองตอนโหมด never', format($q$
    select sri_os.fn_approve_draft(%L, pg_temp.payload('M1a ไม่ควรลงได้')) $q$, dB),
    'ห้ามอนุมัติร่างของตัวเองทุกกรณี');
  perform pg_temp.login('appA');
  perform pg_temp.must_fail_like('M1b management อนุมัติเองตอนโหมด never', format($q$
    select sri_os.fn_approve_draft(%L, pg_temp.payload('M1b ไม่ควรลงได้')) $q$, dA),
    'ห้ามอนุมัติร่างของตัวเองทุกกรณี');

  -- ---------- M2 · super_admin_with_trail = เฉพาะ super_admin + ต้องมีเหตุผล ----------
  perform pg_temp.login('boss');
  perform pg_temp.set_mode('super_admin_with_trail');
  perform pg_temp.login('appA');
  perform pg_temp.must_fail_like('M2a management อนุมัติเองตอนโหมด super_admin_with_trail', format($q$
    select sri_os.fn_approve_draft(%L, pg_temp.payload('M2a ไม่ควรลงได้')) $q$, dA),
    'มีเพียงผู้ดูแลระบบสูงสุด');
  perform pg_temp.login('boss');
  perform pg_temp.must_fail_like('M2b super_admin อนุมัติเองโดยไม่มีเหตุผล', format($q$
    select sri_os.fn_approve_draft(%L, pg_temp.payload('M2b ไม่ควรลงได้')) $q$, dB),
    'ต้องเขียนเหตุผลกำกับ');

  if pg_temp.n_txn() <> v_n0 then
    raise exception 'FAIL: M1-M2 — ทุกเคสถูกปฏิเสธ สมุดต้องไม่ขยับ แต่ได้ %', pg_temp.book();
  end if;

  update sri_os.draft_entries
     set self_review_reason = 'โหมดนี้ต้องมีเหตุผล จึงเขียนกำกับไว้'
   where id = dB;
  perform sri_os.fn_approve_draft(dB, pg_temp.payload('M2c อนุมัติเองพร้อมเหตุผล'));
  if pg_temp.n_txn() <> v_n0 + 1 then
    raise exception 'FAIL: M2c — super_admin ที่มีเหตุผลต้องอนุมัติเองได้ในโหมดนี้';
  end if;

  -- ---------- M3 · กลับมาเป็น any_approver = ค่าปัจจุบันตามคำสั่งลูกพี่ ----------
  perform pg_temp.login('boss');
  perform pg_temp.set_mode('any_approver');
  perform pg_temp.login('appA');
  perform sri_os.fn_approve_draft(dA, pg_temp.payload('M3 อนุมัติเองในโหมดปัจจุบัน'));
  if pg_temp.n_txn() <> v_n0 + 2 then
    raise exception 'FAIL: M3 — โหมด any_approver ต้องให้ management อนุมัติร่างตัวเองได้ · ได้ %',
      pg_temp.book();
  end if;

  reset role;
  raise notice 'ok M1-M3 · สวิตช์พลิกได้จริงทั้งสามทาง: never ห้ามทุกคน (รวม super_admin) · super_admin_with_trail เฉพาะ super_admin + ต้องมีเหตุผล · any_approver ผู้อนุมัติทุกคนทำได้ — เปลี่ยนได้จากตาราง settings ไม่ต้องแก้โค้ด';
exception when others then
  reset role; raise;
end $$;

-- ============================================================
-- S8 + S9 · **ของที่ห้ามอ่อนลงแม้จะอนุญาตให้อนุมัติร่างตัวเองแล้ว**
--      ไม่เกี่ยวกับการแยกหน้าที่ — เป็นความซื่อของประวัติการอนุมัติ
-- ============================================================
do $$
declare v_draft uuid; v_draft2 uuid;
begin
  set local role authenticated;
  v_draft := pg_temp.new_draft_as('clerk', 'S8 ร่างสำหรับทดสอบชื่อผู้ตัดสิน');
  perform pg_temp.login('appA');

  -- S8a · ลงชื่อคนอื่นเป็นผู้ตัดสิน → ปฏิเสธ (ไม่งั้นประวัติการอนุมัติโกหกได้)
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

  -- S9 · ย้ายชื่อคนคีย์ → ปฏิเสธ (ถ้าย้ายได้ รายงานอนุมัติตัวเองก็หลบได้)
  v_draft2 := pg_temp.new_draft_as('appA', 'S9 ร่างที่ผู้อนุมัติคีย์เอง');
  perform pg_temp.must_fail_like('S9 ย้ายชื่อคนคีย์แล้วตัดสิน', format($q$
    update sri_os.draft_entries
       set status = 'rejected', reject_reason = 'ย้ายชื่อคนคีย์', created_by = %L
     where id = %L $q$, pg_temp.uid('clerk'), v_draft2),
    'ย้ายชื่อคนคีย์ร่าง');

  if (select created_by from sri_os.draft_entries where id = v_draft2) <> pg_temp.uid('appA') then
    raise exception 'FAIL: S9 — ชื่อคนคีย์ต้องไม่ถูกย้าย';
  end if;

  reset role;
  raise notice 'ok S8-S9 · ลงชื่อคนอื่นเป็นผู้ตัดสินไม่ได้ · เว้นไว้ระบบเติมชื่อคนที่กดจริง · ย้ายชื่อคนคีย์ไม่ได้ (ข้อนี้ไม่อ่อนลงแม้โหมดจะอนุญาตให้อนุมัติร่างตัวเอง)';
exception when others then
  reset role; raise;
end $$;

-- ============================================================
-- SM · **MUTATION** — ถอดด่านแล้ววัดรูเป็นตัวเลข
--      สิ่งที่หายไปไม่ใช่ "การแยกหน้าที่" (ลูกพี่ยกเลิกเองแล้ว) แต่คือ
--      **ความซื่อของประวัติ**: ชื่อผู้อนุมัติปลอมได้ · ชื่อคนคีย์ย้ายได้
--      → และรายงาน "ใครอนุมัติร่างตัวเอง" **ตาบอดทันที**
-- ============================================================
do $$
declare d_fake uuid; d_hide uuid; v_before int; v_after int;
begin
  set local role authenticated;
  perform pg_temp.login('boss');
  v_before := pg_temp.n_report();
  reset role;

  drop trigger trg_draft_review_separation on sri_os.draft_entries;

  set local role authenticated;
  d_fake := pg_temp.new_draft_as('clerk', 'SM ร่างที่จะถูกลงชื่อผู้อนุมัติปลอม');
  d_hide := pg_temp.new_draft_as('appA', 'SM ร่างที่ผู้อนุมัติคีย์เองแล้วย้ายชื่อคนคีย์ทิ้ง');
  perform pg_temp.login('appA');

  -- (ก) ประวัติโกหก: appA กดเอง แต่บันทึกว่า boss เป็นผู้อนุมัติ
  update sri_os.draft_entries
     set status = 'rejected', reject_reason = 'ปลอมชื่อผู้อนุมัติ',
         reviewed_by = pg_temp.uid('boss'), reviewed_at = now()
   where id = d_fake;
  if (select reviewed_by from sri_os.draft_entries where id = d_fake) <> pg_temp.uid('boss') then
    raise exception 'FAIL: SM(ก) — ถอดด่านแล้วต้องปลอมชื่อผู้อนุมัติได้ (ถ้าไม่ได้ เคส S8 เขียวเพราะด่านอื่น)';
  end if;

  -- (ข) รายงานตาบอด: appA คีย์เอง-ตัดสินเอง แต่ย้ายชื่อคนคีย์ไปให้ clerk ในคำสั่งเดียว
  update sri_os.draft_entries
     set status = 'rejected', reject_reason = 'ย้ายชื่อคนคีย์ทิ้ง',
         created_by = pg_temp.uid('clerk'),
         reviewed_by = pg_temp.uid('appA'), reviewed_at = now()
   where id = d_hide;

  perform pg_temp.login('boss');
  v_after := pg_temp.n_report();
  reset role;

  if v_after <> v_before then
    raise exception 'FAIL: SM(ข) — ใบที่ผู้อนุมัติคีย์เอง-ตัดสินเอง ควร **หายไปจากรายงาน** หลังย้ายชื่อคนคีย์ (ก่อน % ใบ หลัง % ใบ)',
      v_before, v_after;
  end if;

  raise notice 'ok SM (MUTATION) · ไม่มี trigger: (ก) ผู้ที่กดจริงคือ appA แต่สมุดบันทึกว่า **boss อนุมัติ** = ประวัติการอนุมัติโกหกได้ · (ข) ย้ายชื่อคนคีย์ไปให้คนอื่นในคำสั่งเดียวกับการตัดสิน → ใบที่อนุมัติเอง **หายจากรายงาน** (รายงานยัง % ใบเท่าเดิม) = อนุญาตแล้วแต่ยังตรวจย้อนได้ ต้องมีด่านนี้',
    v_after;
exception when others then
  reset role; raise;
end $$;

rollback;

-- ============================================================
-- SMb · สภาพหลัง mutation ต้องกลับมาครบ (ถ้าไม่กลับ เทสต์ไฟล์อื่นจะเขียวผิด)
-- ============================================================
do $$
begin
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.draft_entries'::regclass
                    and g.tgname = 'trg_draft_review_separation' and not g.tgisinternal) then
    raise exception 'FAIL: SMb — trigger ไม่กลับมาหลัง rollback';
  end if;
  if sri_os.fn_self_review_mode() <> 'any_approver' then
    raise exception 'FAIL: SMb — สวิตช์ไม่กลับมาเป็น any_approver หลัง rollback (ได้ %)',
      sri_os.fn_self_review_mode();
  end if;
  raise notice 'ok SMb · trigger และสวิตช์กลับมาครบหลัง rollback';
end $$;

\echo 'zz_draft_self_review_test: ผ่านทุกข้อ'
