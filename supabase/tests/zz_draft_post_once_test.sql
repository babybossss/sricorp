-- ============================================================
-- SRI OS · **ร่างหนึ่งใบลงสมุดได้ครั้งเดียวตลอดกาล** (C-1 · เรื่องเงิน)
--            (20261025000017_draft_post_once.sql)
--
-- **รูที่พิสูจน์** — เส้นทางของแอปคือ "โพสต์เข้าสมุด แล้วค่อยอัปเดตร่าง"
-- ซึ่งเป็น **อ่านก่อนเขียน**: ผู้อนุมัติสองคนอ่านร่างเดียวกันเห็น `pending`
-- พร้อมกัน → โพสต์คนละใบ → **ยอดเกินจริงเท่าตัว** และงบดุลดุลทั้งสองใบ
-- จึงไม่มีอะไรฟ้อง (รูปเดียวกับที่ด่านล้างยอดเกินแพ้สามชั้นติด)
--
-- **ทุกเคสรันเป็น role `authenticated`** ไม่ใช่ superuser
--
-- สิ่งที่พิสูจน์
--   D0 · โครงสร้าง: CHECK + unique index + trigger + ปากทางที่ล็อกแถว
--   D1 · อนุมัติผ่านปากทาง → ลงสมุด 1 ใบ · ร่างชี้ใบนั้น · ยอดในสมุด = 50,000
--   D2 · อนุมัติซ้ำ → **ปฏิเสธ** · สมุดยังมีใบเดียว ยอดยัง 50,000 (ไม่ใช่ 100,000)
--   D3 · ร่างที่ตัดสินแล้วเป็น **แถวตาย** — ปลุกกลับเป็น pending ไม่ได้
--   D4 · **เส้นทางที่แอปใช้อยู่**: โพสต์ในคำสั่งหนึ่ง แล้ว UPDATE ร่างในคำสั่งถัดไป
--        → ปฏิเสธด้วยด่าน "ธุรกรรมเดียวกัน" (นี่คือรูปที่แข่งกันได้ และถูกตัดทิ้ง
--        ที่โครงสร้าง ไม่ใช่แพ้จังหวะบางครั้ง)
--   D5 · อนุมัติร่างโดยไม่มีใบ / ชี้ใบของผู้ถืออื่น / ชี้ใบคนละหมวด → ปฏิเสธ
--   D6 · ใบในสมุดใบหนึ่งถูกร่างสองใบอ้างไม่ได้ (unique index)
--   **T1 · สองเซสชันจริง (dblink)** — เซสชัน B ถูก **บล็อกที่ล็อกแถว** ไม่ใช่
--        อ่านสภาพเก่าแล้วเดินต่อ · พิสูจน์ด้วย `lock_timeout` ที่หมดเวลาจริง
--   **TM · MUTATION สองเซสชัน** — ถ้าอนุมัติโดย **ไม่ถือล็อกร่าง** (เส้นทางเดิม)
--        เซสชัน B โพสต์ได้อีกใบทันที → วัดได้ **2 ใบ · 100,000 บาท** จากร่างใบเดียว
-- ============================================================

\set ON_ERROR_STOP 1

/* ============================================================
 * **โครงของไฟล์นี้: สองช่วง** (อ่านก่อนแก้)
 *
 * ช่วงที่ 1 (ธุรกรรมเดียว · rollback) — เคส D0–D5 ที่พิสูจน์ได้ในเซสชันเดียว
 *
 * ช่วงที่ 2 (**สองเซสชันจริง**) — T1/TM · **เซสชันที่สองมองของที่ยังไม่ commit
 *   ไม่เห็น** (นี่คือข้อจำกัดของฐานข้อมูล ไม่ใช่ของเทสต์) → fixture ที่ไม่ใช่เงิน
 *   (ผู้ใช้ · ขอบเขตผู้ถือ · ร่าง) ต้อง **commit** ก่อน แล้วจึงเปิดธุรกรรมของ
 *   เซสชัน A ที่ **rollback ทิ้ง** → **ไม่มีใบไหนลงสมุดค้างไว้เลย**
 *   และเก็บ fixture ทิ้งท้ายไฟล์
 *
 * temp table + ฟังก์ชันช่วยจึงสร้าง **นอกธุรกรรม** เพื่อให้อยู่ข้ามทั้งสองช่วง
 * ============================================================ */

-- dblink ใช้เปิด **เซสชันจริงตัวที่สอง** (เทสต์ psql ไฟล์เดียวอยู่ในธุรกรรมเดียว
-- จึงพิสูจน์จังหวะพร้อมกันไม่ได้ · และ scripts/test-two-session-local.sh
-- ไม่ใช่ขอบเขตที่ผมแก้ได้) · `create extension` อยู่ในธุรกรรมนี้ จึงถูก rollback ไปด้วย
create extension if not exists dblink;

-- ------------------------------------------------------------
-- fixtures ที่อยู่ข้ามสองช่วง (temp + ฟังก์ชันช่วย)
-- ------------------------------------------------------------
create temporary table d_uid (label text primary key, id uuid not null default gen_random_uuid());
-- `clerk` = พนักงานคีย์ร่าง · **คนคีย์ต้องไม่ใช่คนอนุมัติ** (C-2 · 20261025000018)
-- ถ้าผู้อนุมัติคีย์ร่างเองแล้วอนุมัติเอง ด่าน C-2 จะปฏิเสธ → เคสของ C-1 จะวัดผิดด่าน
insert into d_uid(label) values ('approver'), ('approver2'), ('clerk');

create or replace function pg_temp.own(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.owners where code = p_code $fn$;

create or replace function pg_temp.uid(p_label text) returns uuid
language sql stable as $fn$ select id from d_uid where label = p_label $fn$;

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

/** payload ของใบค้างจ่าย Dr 5900 / Cr 2100 — ไม่มีขาเงินสด จึงไม่ต้องมีบัญชีธนาคาร */
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

/**
 * คีย์ร่างหนึ่งใบ (สถานะ pending) **ในฐานะพนักงานคีย์ ไม่ใช่ผู้อนุมัติ**
 * สวมสิทธิ์ `clerk` ชั่วคราวแล้วคืนให้ผู้เรียก — เพราะ C-2 ห้ามคนคีย์อนุมัติร่างตัวเอง
 * ถ้าคีย์ด้วยชื่อผู้อนุมัติ เคสของไฟล์นี้จะถูกปฏิเสธด้วยด่าน C-2 แทน (วัดผิดด่าน)
 */
create or replace function pg_temp.new_draft(p_memo text, p_amount numeric default 50000,
                                             p_id uuid default null)
returns uuid language plpgsql as $fn$
declare v_id uuid; v_prev text := coalesce(current_setting('test.uid', true), '');
begin
  perform set_config('test.uid', pg_temp.uid('clerk')::text, true);
  insert into sri_os.draft_entries(id, owner_id, txn_type_code, doc_date, amount, memo,
                                   attachments, created_by)
  values (coalesce(p_id, gen_random_uuid()), pg_temp.own('THANAKORN'), 'exp.other',
          '2026-02-01', p_amount, p_memo, array['ใบแจ้งหนี้.pdf'], auth.uid())
  returning id into v_id;
  perform set_config('test.uid', v_prev, true);
  return v_id;
exception when others then
  perform set_config('test.uid', v_prev, true);
  raise;
end $fn$;

/** จำนวนใบและยอดรวมในสมุดของหมวดนี้ — ตัววัดว่า "ลงซ้ำ" เกิดขึ้นหรือไม่ */
create or replace function pg_temp.book() returns text
language sql stable as $fn$
  select coalesce(count(distinct v.transaction_id), 0)::text || ' ใบ · '
         || coalesce(sum(v.debit) filter (where v.coa_id =
              (select id from sri_os.chart_of_accounts where code = '5900')), 0)::text || ' บาท'
    from sri_os.v_ledger_posted v
   where v.txn_type_code = 'exp.other';
$fn$;

/** นับเฉพาะใบที่ **ยังมีผล** (ใบที่ยกเลิกแล้วไม่นับในงบ จึงไม่นับที่นี่ด้วย) */
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

/** สร้างผู้ใช้ + ขอบเขตผู้ถือของ fixture (เรียกได้ทั้งสองช่วง) */
create or replace function pg_temp.make_users() returns void
language sql as $fn$
  insert into auth.users(id) select id from d_uid on conflict do nothing;
  insert into sri_os.app_users(id, email, display_name, role, is_active)
  select u.id, u.label || '@local', u.label,
         case when u.label = 'clerk' then 'staff' else 'management' end, true
    from d_uid u
  on conflict (id) do nothing;
  insert into sri_os.user_owner_access(user_id, owner_id)
  select u.id, o.id from d_uid u, sri_os.owners o
  on conflict do nothing;
$fn$;

do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.d_uid to authenticated', s);
end $$;

-- ============================================================
-- ช่วงที่ 1 · เคสที่พิสูจน์ได้ในเซสชันเดียว (rollback ทิ้งทั้งหมด)
-- ============================================================
begin;

select pg_temp.make_users();

-- ============================================================
-- D0 · โครงสร้าง — ไล่จาก catalog จริง
-- ============================================================
do $$
declare v text;
begin
  if to_regprocedure('sri_os.fn_approve_draft(uuid, jsonb)') is null then
    raise exception 'FAIL: D0 — ไม่มี fn_approve_draft (migration ไม่ถูก apply?) เทสต์นี้จะไม่ได้ตรวจอะไร';
  end if;
  if not exists (select 1 from pg_constraint where conname = 'draft_entries_posted_iff_approved') then
    raise exception 'FAIL: D0 — ไม่มี CHECK draft_entries_posted_iff_approved';
  end if;
  if not exists (select 1 from pg_class where relname = 'draft_entries_posted_txn_uniq') then
    raise exception 'FAIL: D0 — ไม่มี unique index ของ posted_txn_id';
  end if;
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.draft_entries'::regclass
                    and g.tgname = 'trg_draft_post_once' and not g.tgisinternal) then
    raise exception 'FAIL: D0 — ไม่มี trigger trg_draft_post_once';
  end if;

  -- **ปากทางต้องล็อกแถว ไม่ใช่อ่านแล้วเขียน**
  v := pg_get_functiondef('sri_os.fn_approve_draft(uuid, jsonb)'::regprocedure);
  if v !~ 'for update' then
    raise exception 'FAIL: D0 — fn_approve_draft ไม่ได้ล็อกแถวด้วย for update';
  end if;

  -- ผู้ใช้จริงต้องเรียกปากทางได้ และต้องมีสิทธิ์ UPDATE ร่างอยู่แล้ว
  -- (ถ้าไม่มีสิทธิ์ตั้งแต่ต้น เคสอื่นจะเขียวด้วยเหตุผลผิด)
  if not has_function_privilege('authenticated',
       'sri_os.fn_approve_draft(uuid, jsonb)'::regprocedure, 'execute') then
    raise exception 'FAIL: D0 — authenticated เรียก fn_approve_draft ไม่ได้';
  end if;
  if not has_table_privilege('authenticated', 'sri_os.draft_entries', 'UPDATE') then
    raise exception 'FAIL: D0 — authenticated ไม่มีสิทธิ์ UPDATE draft_entries → เคสอื่นจะเขียวด้วยเหตุผลผิด';
  end if;

  raise notice 'ok D0 · โครงสร้างครบ: CHECK + unique index + trigger + ปากทางที่ล็อกแถว · authenticated มีสิทธิ์พอที่จะพิสูจน์ด่านได้';
end $$;

-- ============================================================
-- D1 + D2 + D3 · อนุมัติได้ครั้งเดียว · ซ้ำไม่ได้ · ปลุกไม่ได้
-- ============================================================
do $$
declare v_draft uuid; v_out jsonb; v_txn uuid;
begin
  perform set_config('test.uid', pg_temp.uid('approver')::text, true);
  set local role authenticated;

  v_draft := pg_temp.new_draft('D1 ค่าใช้จ่ายค้างจ่าย 50,000');

  v_out := sri_os.fn_approve_draft(v_draft, pg_temp.payload('D1 อนุมัติร่าง 50,000'));
  v_txn := (v_out ->> 'posted_txn_id')::uuid;
  if v_txn is null then
    raise exception 'FAIL: D1 — ปากทางไม่คืนเลขใบ';
  end if;

  if pg_temp.n_txn() <> 1 or pg_temp.sum_5900() <> 50000 then
    raise exception 'FAIL: D1 — ต้องมี 1 ใบ · 50,000 บาท แต่ได้ %', pg_temp.book();
  end if;
  if (select posted_txn_id from sri_os.draft_entries where id = v_draft) <> v_txn
     or (select status::text from sri_os.draft_entries where id = v_draft) <> 'approved' then
    raise exception 'FAIL: D1 — ร่างต้องเป็น approved และชี้ใบที่ลง';
  end if;

  -- D2 · อนุมัติซ้ำ → ปฏิเสธ และสมุดต้องไม่เพิ่มใบ
  perform pg_temp.must_fail_like('D2 อนุมัติร่างเดิมซ้ำ', format($q$
    select sri_os.fn_approve_draft(%L, pg_temp.payload('D2 อนุมัติซ้ำ')) $q$, v_draft),
    'อนุมัติไปแล้ว');

  if pg_temp.n_txn() <> 1 or pg_temp.sum_5900() <> 50000 then
    raise exception 'FAIL: D2 — หลังอนุมัติซ้ำที่ถูกปฏิเสธ สมุดต้องยังเป็น 1 ใบ · 50,000 แต่ได้ % (ถ้าได้ 2 ใบ · 100,000 คือรูที่เรามาปิด)',
      pg_temp.book();
  end if;

  -- D3 · ปลุกร่างกลับเป็น pending ไม่ได้
  perform pg_temp.must_fail_like('D3 ปลุกร่างกลับเป็น pending', format($q$
    update sri_os.draft_entries set status = 'pending', posted_txn_id = null
     where id = %L $q$, v_draft),
    'ร่างที่ตัดสินแล้วคือร่างตาย');

  perform pg_temp.must_fail_like('D3b แก้ยอดของร่างที่อนุมัติแล้ว', format($q$
    update sri_os.draft_entries set amount = 1 where id = %L $q$, v_draft),
    'แก้อะไรไม่ได้อีก');

  reset role;
  raise notice 'ok D1-D3 · อนุมัติผ่านปากทาง → 1 ใบ · 50,000 · อนุมัติซ้ำถูกปฏิเสธ (สมุดยัง 1 ใบ · 50,000 ไม่ใช่ 2 ใบ · 100,000) · ร่างที่ตัดสินแล้วปลุกไม่ได้และแก้ยอดไม่ได้';
exception when others then
  reset role;
  raise;
end $$;

-- ============================================================
-- D5 · อนุมัติแบบอื่นที่ต้องปฏิเสธ
-- ============================================================
do $$
declare v_draft uuid; v_other uuid; v_txn uuid;
begin
  perform set_config('test.uid', pg_temp.uid('approver')::text, true);
  set local role authenticated;

  v_draft := pg_temp.new_draft('D5 ร่างทดสอบการอนุมัติที่ผิดรูป');

  -- (ก) อนุมัติโดยไม่มีใบในสมุด
  perform pg_temp.must_fail_like('D5a อนุมัติโดยไม่มีใบ', format($q$
    update sri_os.draft_entries set status = 'approved' where id = %L $q$, v_draft),
    -- trigger พูดก่อน CHECK และข้อความชี้ทางออกให้ด้วย (CHECK กันอยู่อีกชั้น)
    'โดยไม่มีใบในสมุดไม่ได้');

  -- (ข) ชี้ใบที่มีอยู่แล้วของร่างอื่น (unique index) — ใช้ใบของ D1
  select posted_txn_id into v_txn from sri_os.draft_entries
   where status = 'approved' and memo like 'D1%' limit 1;
  if v_txn is null then
    raise exception 'FAIL: D5 — ไม่พบใบของ D1 มาใช้ทดสอบ';
  end if;
  perform pg_temp.must_fail_like('D5b ชี้ใบที่ร่างอื่นอ้างไปแล้ว', format($q$
    update sri_os.draft_entries set status = 'approved', posted_txn_id = %L
     where id = %L $q$, v_txn, v_draft),
    'draft_entries_posted_txn_uniq');

  -- (ค) ชี้ใบที่ไม่มีอยู่
  perform pg_temp.must_fail_like('D5c ชี้ใบที่ไม่มีอยู่', format($q$
    update sri_os.draft_entries
       set status = 'approved', posted_txn_id = '00000000-0000-0000-0000-00000000dead'
     where id = %L $q$, v_draft),
    -- trigger พูดก่อน FK และข้อความอ่านรู้เรื่องกว่า (FK กันอยู่อีกชั้น)
    'ที่ไม่มีอยู่ในสมุด');

  -- (ง) ร่าง pending ที่ชี้ใบ (ลงไปแล้วแต่คิวยังค้าง)
  perform pg_temp.must_fail_like('D5d ร่าง pending ที่ชี้ใบ', format($q$
    update sri_os.draft_entries set posted_txn_id = %L where id = %L $q$, v_txn, v_draft),
    'ยังไม่ได้อนุมัติ แต่ชี้ใบในสมุด');

  if (select status::text from sri_os.draft_entries where id = v_draft) <> 'pending' then
    raise exception 'FAIL: D5 — ร่างต้องยัง pending หลังทุกเคสที่ถูกปฏิเสธ';
  end if;

  reset role;
  raise notice 'ok D5 · อนุมัติโดยไม่มีใบ · ชี้ใบที่ร่างอื่นอ้างแล้ว · ชี้ใบผี · ร่าง pending ที่ชี้ใบ → ปฏิเสธทุกเคส';
exception when others then
  reset role;
  raise;
end $$;

rollback;

-- ============================================================
-- ช่วงที่ 2 · **สองเซสชันจริง**
--
-- เซสชันที่สองมองของที่ยังไม่ commit ไม่เห็น → fixture ที่ **ไม่ใช่เงิน**
-- (ผู้ใช้ · ขอบเขตผู้ถือ · ร่าง) ต้อง commit ก่อน
-- ส่วนธุรกรรมที่ลงสมุดอยู่ในช่วงถัดไปที่ **rollback ทิ้ง** → ไม่มีใบค้างในสมุด
-- ============================================================
begin;
select pg_temp.make_users();

create temporary table d_fix (label text primary key, id uuid);
insert into d_fix(label, id) values ('t1', gen_random_uuid()), ('d4', gen_random_uuid());

-- role `authenticated` ต้องอ่านตารางนี้ได้ ไม่งั้น insert ที่อ่านจากมันพัง
do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant select on %I.d_fix to authenticated', s);
end $$;

/**
 * ใบที่ **ลงแล้วยกเลิกแล้ว** ใน **ธุรกรรมนี้** (ซึ่ง commit) — ใช้เป็นใบที่
 * "มาจากธุรกรรมอื่น" สำหรับเคส D4 ในช่วงถัดไป
 *
 * ทำไมต้อง void: `write_txn_id` **ปลอมไม่ได้แม้แต่เจ้าของสคีมา** (trigger ของ
 * 20261007000000 ตรึง `new.write_txn_id := old.write_txn_id` ทุก UPDATE) →
 * การพิสูจน์กิ่ง "มาจากธุรกรรมอื่น" **ต้องมีใบที่ commit จากธุรกรรมอื่นจริง**
 * แต่เทสต์ต้องไม่ทิ้งเงินไว้ → ลงแล้ว **ยกเลิกทันที** ในธุรกรรมเดียวกัน
 * (`v_ledger_posted` ไม่นับใบที่ยกเลิก → ไม่มีเงินค้างในงบเลย แถวยังอยู่
 *  เพราะกฎเหล็กข้อ 1 ห้ามลบ ซึ่งถูกต้อง)
 */
do $$
declare v_txn uuid;
begin
  perform set_config('test.uid', pg_temp.uid('approver')::text, true);
  set local role authenticated;
  v_txn := ((sri_os.fn_post_entry(pg_temp.payload('C1-d4 ใบที่ลงจากธุรกรรมอื่นแล้วยกเลิก'))
              -> 'transaction_ids') ->> 0)::uuid;
  update sri_os.transactions
     set status = 'void', voided_at = now(), voided_by = auth.uid(),
         void_reason = 'fixture ของเทสต์ C-1 · ยกเลิกทันทีเพื่อไม่ทิ้งเงินไว้ในสมุด'
   where id = v_txn;
  reset role;
  update d_fix set id = v_txn where label = 'd4';
exception when others then
  reset role;
  raise;
end $$;

-- ร่างหนึ่งใบสำหรับเคสสองเซสชัน (ยังไม่มีเงินลงสมุด) — ใส่ด้วยสิทธิ์ของผู้ใช้จริง
do $$
begin
  perform set_config('test.uid', pg_temp.uid('approver')::text, true);
  set local role authenticated;
  perform pg_temp.new_draft('C1-t1 ร่างสำหรับสองเซสชัน', 50000,
                            (select id from d_fix where label = 't1'));
  reset role;
exception when others then
  reset role;
  raise;
end $$;
commit;

-- ---------- ธุรกรรมของเซสชัน A (rollback ทิ้ง · ไม่มีใบค้างในสมุด) ----------
begin;

-- ============================================================
-- D4 · **เส้นทางที่แอปใช้อยู่** — โพสต์คำสั่งหนึ่ง แล้ว UPDATE ร่างคำสั่งถัดไป
--
--      นี่คือรูปเดียวที่ผู้อนุมัติสองคนแข่งกันได้ · ด่าน "ธุรกรรมเดียวกัน"
--      ตัดทิ้งที่โครงสร้าง — ไม่ใช่แพ้จังหวะบางครั้ง แต่ **ลงไม่ได้เลย**
--
--      ใบที่ใช้คือใบที่ commit จาก **ธุรกรรมอื่นจริง** (ช่วง fixture ข้างบน)
--      และถูกยกเลิกแล้วเพื่อไม่ทิ้งเงินไว้ · `write_txn_id` ปลอมไม่ได้
--      แม้แต่เจ้าของสคีมา จึงไม่มีทางจำลองกิ่งนี้ในธุรกรรมเดียว
-- ============================================================
do $$
declare v_draft uuid; v_txn uuid;
begin
  select id into v_txn from d_fix where label = 'd4';
  perform set_config('test.uid', pg_temp.uid('approver')::text, true);
  set local role authenticated;

  v_draft := pg_temp.new_draft('C1-d4b ร่างที่จะถูกอัปเดตข้ามธุรกรรม');

  perform pg_temp.must_fail_like('D4 อัปเดตร่างให้ชี้ใบที่มาจากธุรกรรมอื่น', format($q$
    update sri_os.draft_entries
       set status = 'approved', posted_txn_id = %L, reviewed_by = auth.uid(), reviewed_at = now()
     where id = %L $q$, v_txn, v_draft),
    'ไม่ใช่ธุรกรรมเดียวกับการอนุมัติร่าง');

  if (select status::text from sri_os.draft_entries where id = v_draft) <> 'pending' then
    raise exception 'FAIL: D4 — ร่างต้องยัง pending';
  end if;

  reset role;
  raise notice 'ok D4 · เส้นทาง "โพสต์ก่อน แล้วอัปเดตร่างทีหลัง" (ใบ commit มาจากธุรกรรมอื่นจริง) ถูกปฏิเสธที่โครงสร้าง — นี่คือรูปเดียวที่ผู้อนุมัติสองคนแข่งกันได้';
exception when others then
  reset role;
  raise;
end $$;

-- ============================================================
-- T1 · **สองเซสชันจริง** — เซสชันที่สองต้องถูก **บล็อกที่ล็อกแถว**
--
--      เซสชัน A (ธุรกรรมของไฟล์นี้) อนุมัติร่างแล้ว **ยังไม่ commit**
--      → ถือล็อกแถวร่างอยู่
--      เซสชัน B (dblink · ธุรกรรมของตัวเอง) ตั้ง `lock_timeout` แล้วอนุมัติร่างเดิม
--      → ต้อง **หมดเวลาเพราะรอล็อก** = พิสูจน์ว่ามันรอจริง ไม่ใช่เห็นสภาพเก่า
--        แล้วเดินต่อ (ถ้าเป็นแบบอ่านก่อนเขียน B จะไม่รอเลย แล้วลงใบที่สอง)
-- ============================================================
do $$
declare v_draft uuid; v_conn text := 'c_t1'; v_err text;
begin
  perform set_config('test.uid', pg_temp.uid('approver')::text, true);
  set local role authenticated;
  select id into v_draft from d_fix where label = 't1';
  -- A อนุมัติ (ถือล็อกแถวไว้ · ธุรกรรมนี้ยังไม่ commit)
  perform sri_os.fn_approve_draft(v_draft, pg_temp.payload('T1 อนุมัติจากเซสชัน A'));
  reset role;

  perform dblink_connect(v_conn, 'dbname=' || current_database());
  -- `dblink_exec` รับคำสั่งที่ไม่คืนผลลัพธ์ → ใช้ SET ตรงๆ ไม่ใช่ set_config()
  perform dblink_exec(v_conn, format($q$ set test.uid = %L $q$, pg_temp.uid('approver2')::text));
  perform dblink_exec(v_conn, 'set role authenticated');
  perform dblink_exec(v_conn, 'begin');
  -- รอสั้นๆ แล้วต้องหมดเวลา — ถ้ามันไม่รอเลย แปลว่าไม่มีล็อก
  perform dblink_exec(v_conn, $q$ set lock_timeout = '1200ms' $q$);

  begin
    perform dblink_exec(v_conn, format(
      $q$ select sri_os.fn_approve_draft(%L, %L::jsonb) $q$,
      v_draft, pg_temp.payload('T1 อนุมัติจากเซสชัน B')::text));
    -- ไม่ควรมาถึงบรรทัดนี้
    perform dblink_exec(v_conn, 'rollback');
    perform dblink_disconnect(v_conn);
    raise exception 'FAIL: T1 — เซสชัน B อนุมัติร่างเดียวกันสำเร็จขณะที่ A ยังถือล็อก → ลงสมุดสองใบจากร่างใบเดียว';
  exception when others then
    v_err := sqlerrm;
    if v_err like 'FAIL:%' then raise; end if;
  end;

  perform dblink_exec(v_conn, 'rollback');
  perform dblink_disconnect(v_conn);

  if position('lock timeout' in v_err) = 0 then
    raise exception 'FAIL: T1 — เซสชัน B ต้องล้มเพราะ **รอล็อกแถวแล้วหมดเวลา** แต่ได้: % · ถ้าล้มด้วยเหตุอื่น เทสต์นี้ไม่ได้พิสูจน์ว่ามีล็อกจริง',
      v_err;
  end if;

  -- ช่วงนี้เริ่มจากสมุดว่าง (ช่วงที่ 1 ถูก rollback) → ต้องมีใบของ A ใบเดียว
  if pg_temp.n_txn() <> 1 or pg_temp.sum_5900() <> 50000 then
    raise exception 'FAIL: T1 — สมุดต้องมีใบของ A ใบเดียว 50,000 บาท แต่ได้ % · ถ้าได้ 2 ใบ 100,000 คือเซสชัน B ลงใบที่สองสำเร็จ = รูที่เรามาปิด',
      pg_temp.book();
  end if;

  raise notice 'ok T1 (สองเซสชันจริง) · A ถือล็อกแถวร่างอยู่ → B **รอแล้วหมดเวลา (lock timeout)** ไม่ได้ลงใบที่สอง · สมุดมี 1 ใบ 50,000 บาท (ไม่ใช่ 2 ใบ 100,000)';
exception when others then
  reset role;
  perform dblink_disconnect(v_conn);
  raise;
end $$;

-- ============================================================
-- TM · **MUTATION สองเซสชัน** — ถ้าอนุมัติโดยไม่ถือล็อกร่าง (เส้นทางเดิมของแอป)
--      เซสชัน B โพสต์ได้อีกใบทันที → วัดความเสียหายเป็นตัวเลข
-- ============================================================
do $$
declare v_conn text := 'c_tm'; v_n int; v_sum numeric;
begin
  perform dblink_connect(v_conn, 'dbname=' || current_database());
  -- `dblink_exec` รับคำสั่งที่ไม่คืนผลลัพธ์ → ใช้ SET ตรงๆ ไม่ใช่ set_config()
  perform dblink_exec(v_conn, format($q$ set test.uid = %L $q$, pg_temp.uid('approver2')::text));
  perform dblink_exec(v_conn, 'set role authenticated');
  perform dblink_exec(v_conn, 'begin');
  perform dblink_exec(v_conn, $q$ set lock_timeout = '1200ms' $q$);

  /**
   * จำลองเส้นทางเดิม: **ไม่ล็อกร่าง** แค่โพสต์ลงสมุดตรงๆ
   * (ซึ่งคือสิ่งที่เกิดขึ้นถ้าแอปโพสต์ก่อนแล้วค่อยอัปเดตร่าง)
   * → ไม่มีอะไรบล็อกเลย เพราะไม่ได้แตะแถวร่าง
   */
  -- ใช้ `dblink()` เพราะคำสั่งนี้คืนผลลัพธ์ (`dblink_exec` รับได้แต่คำสั่งที่ไม่คืนผล)
  perform * from dblink(v_conn, format(
    $q$ select (sri_os.fn_post_entry(%L::jsonb) ->> 'replayed') $q$,
    pg_temp.payload('TM โพสต์โดยไม่ถือล็อกร่าง')::text)) as t(x text);

  -- วัดจากภายในเซสชัน B ก่อน rollback (A ยังไม่ commit จึงไม่เห็นใบของ A)
  select t.n, t.s into v_n, v_sum from dblink(v_conn, $q$
    select count(*)::int,
           coalesce(sum(l.debit), 0)
      from sri_os.transactions t
      join sri_os.transaction_lines l on l.transaction_id = t.id
      join sri_os.chart_of_accounts c on c.id = l.coa_id
     where t.txn_type_code = 'exp.other' and c.code = '5900'
       and t.memo like 'TM%' $q$) as t(n int, s numeric);

  perform dblink_exec(v_conn, 'rollback');
  perform dblink_disconnect(v_conn);

  if v_n <> 1 or v_sum <> 50000 then
    raise exception 'FAIL: TM — เซสชัน B ควรโพสต์ได้ 1 ใบ 50,000 บาทโดยไม่ถูกบล็อก (เพราะไม่ได้แตะแถวร่าง) แต่ได้ % ใบ % บาท · ถ้าถูกบล็อก แปลว่าเทสต์ T1 เขียวเพราะอย่างอื่น ไม่ใช่เพราะล็อกแถว',
      v_n, v_sum;
  end if;

  raise notice 'ok TM (MUTATION สองเซสชัน) · เส้นทางที่ **ไม่ถือล็อกร่าง** โพสต์ได้อีก 1 ใบ 50,000 บาททันทีโดยไม่ถูกบล็อกเลย → รวมกับใบของเซสชัน A เป็น **2 ใบ 100,000 บาทจากร่างใบเดียว** (ยอดเกินจริงเท่าตัว · งบดุลดุลทั้งสองใบ) · ด่าน "ธุรกรรมเดียวกัน" คือสิ่งที่ทำให้เส้นทางนี้ลงสมุดแล้วผูกกับร่างไม่ได้ และปากทางที่ล็อกแถวคือสิ่งที่ทำให้มันไม่เกิดตั้งแต่ต้น';
exception when others then
  perform dblink_disconnect(v_conn);
  raise;
end $$;

rollback;

-- ---------- เก็บ fixture ----------
begin;
do $$
declare v text;
begin
  delete from sri_os.draft_entries where id in (select id from d_fix);
  delete from sri_os.user_owner_access where user_id in (select id from d_uid);
  -- ใบ fixture ของ D4 ถูก commit แล้ว (void แล้วก็ยังลบไม่ได้ — กฎเหล็กข้อ 1)
  -- transactions.created_by จึงยังชี้ผู้ใช้เหล่านี้อยู่ = ลบ app_users ไม่ได้ **ซึ่งถูกต้อง**
  begin
    delete from sri_os.app_users where id in (select id from d_uid);
    delete from auth.users where id in (select id from d_uid);
    raise notice 'ok · เก็บ fixture ของช่วงสองเซสชันเรียบร้อยทั้งหมด';
  exception when foreign_key_violation then
    raise notice 'ok · ผู้ใช้ fixture ลบไม่ได้เพราะใบที่ commit แล้ว (ถึง void ก็ลบไม่ได้) ยังอ้างอยู่ — นี่คือกฎเหล็กข้อ 1 ทำงาน ไม่ใช่เทสต์พัง · DB ทดสอบถูกลบทิ้งทั้งก้อนอยู่แล้ว';
  end;
exception when others then
  -- เก็บไม่ได้ก็ไม่ให้เทสต์แดง แต่ต้องรู้ (harness ลบ DB ทิ้งอยู่แล้ว)
  raise warning 'เก็บ fixture ไม่หมด: % — ตรวจว่ามีด่านห้ามลบของตารางไหน', sqlerrm;
end $$;

-- **ด่านปลายทาง**: ต้องไม่มีใบในสมุดของหมวดนี้ค้างจากช่วงสองเซสชันเลย
do $$
declare n int;
begin
  select count(*) into n from sri_os.transactions
   where txn_type_code = 'exp.other' and memo like 'C1-%' and status::text = 'posted';
  if n <> 0 then
    raise exception 'FAIL · มีใบที่ยังมีผล % ใบค้างจากช่วงสองเซสชัน — เทสต์ต้องไม่ทิ้งเงินไว้ในงบ', n;
  end if;
  raise notice 'ok · ไม่มีใบที่ยังมีผลค้างจากช่วงสองเซสชัน (ใบ fixture ถูกยกเลิกแล้ว · v_ledger_posted ไม่นับ) → ไม่มีเงินค้างในงบ';
end $$;
commit;
