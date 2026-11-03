-- ============================================================
-- SRI OS · พิสูจน์กับ Postgres จริง (ในเครื่อง) ว่าคิวอนุมัติทำงานบนสิ่งที่ DB บังคับจริง
-- รันอัตโนมัติโดย `scripts/test-rls-local.sh` (เก็บทุกไฟล์ `supabase/tests/*_test.sql`)
-- เดิมอยู่ใน `src/lib/db/__tests__/sql/` ซึ่ง **ไม่มี runner เรียก** จึงไม่เคยรันเลย
-- ย้ายเข้ามาเพราะเทสต์ที่ไม่ถูกรัน ไม่ต่างจากไม่มีเทสต์ ต่างแค่ทำให้สบายใจผิดๆ
--
-- **D2 เคยบันทึกว่าเป็นช่องโหว่ ตอนนี้ปิดแล้ว** (20261025000017) ข้อนี้จึงกลับด้าน:
-- จากเดิมยืนยันว่า "ทำได้" เป็นยืนยันว่า "ถูกปฏิเสธ"
-- **D1 ตัดสินแล้ว (ลูกพี่ 25/10)**: ผู้อนุมัติปิดร่างที่ตัวเองคีย์ **ได้**
-- ("ระดับ management คีย์เองได้ อนุมัติของตัวเองได้ · Manager ก็อนุมัติได้ คีย์เองได้")
-- จึงไม่ใช่ช่องโหว่อีกต่อไป แต่ยัง **ต้องถูกบันทึก** → ข้อนี้ตรวจทั้งสองอย่างคู่กัน
-- (กลไกสวิตช์สามโหมดอยู่ที่ 20261025000018 + 20261025000019)
-- ============================================================
begin;
create temporary table t_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_uid(label) values ('mgmt'), ('mgr'), ('staff'), ('staff2');
insert into auth.users(id) select id from t_uid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, u.label || '@probe.local', u.label, x.role, true
  from t_uid u join (values ('mgmt','management'), ('mgr','manager'), ('staff','staff'), ('staff2','staff')) x(label, role) on x.label = u.label;
create or replace function pg_temp.uid(p text) returns uuid language sql stable as $f$ select id from t_uid where label = p $f$;
create or replace function pg_temp.login(p text) returns void language sql as $f$
  select set_config('test.uid', coalesce((select id::text from t_uid where label = p), ''), true) $f$;
create or replace function pg_temp.eq(p_label text, p_got anyelement, p_want anyelement) returns void language plpgsql as $f$
begin if p_got is distinct from p_want then raise exception 'FAIL: % — ได้ % คาด %', p_label, p_got, p_want; end if; end $f$;
create or replace function pg_temp.rows_hit(p_sql text) returns bigint language plpgsql as $f$
declare n bigint; begin execute p_sql; get diagnostics n = row_count; return n; end $f$;

insert into sri_os.user_owner_access(user_id, owner_id)
select pg_temp.uid(l), o.id from unnest(array['mgr','staff','staff2']) l, sri_os.owners o where o.code in ('THANAKORN');
insert into sri_os.contacts(id, first_name, types) values ('00000000-0000-0000-0000-00000000c001', 'ผู้เช่าทดสอบ', array['tenant']);
insert into sri_os.assets(id, code, name, class_id, category_id, owner_id)
select '00000000-0000-0000-0000-00000000a001', 'APR-1', 'ห้องทดสอบ', k.class_id, k.id, o.id
  from (select class_id, id from sri_os.asset_categories order by code limit 1) k, sri_os.owners o where o.code = 'THANAKORN';

-- ร่างสองใบ: ของ staff และของ staff2 (ไม่มี bank_account_id ในตารางร่าง — ข้อเท็จจริงของ schema)
insert into sri_os.draft_entries(id, owner_id, txn_type_code, doc_date, amount, asset_id, contact_id, memo, created_by)
select x.id, o.id, 'inc.rent', date '2026-09-10', 12000, '00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-00000000c001', x.memo, pg_temp.uid(x.by)
  from sri_os.owners o, (values ('00000000-0000-0000-0000-0000000d0001'::uuid, 'ของ staff', 'staff'), ('00000000-0000-0000-0000-0000000d0002'::uuid, 'ของ staff2', 'staff2')) x(id, memo, by)
 where o.code = 'THANAKORN';

do $$ declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin execute format('grant usage on schema %I to authenticated', s); execute format('grant select on %I.t_uid to authenticated', s); end $$;
set local role authenticated;

-- A1 · ใครเห็นคิว
select pg_temp.login('mgmt');
select pg_temp.eq('ผู้อนุมัติเห็นร่างทั้งสอง', (select count(*) from sri_os.draft_entries where status = 'pending'), 2::bigint);
select pg_temp.eq('ผู้อนุมัติอ่าน amount ได้ (row exposure)', (select sum(amount) from sri_os.draft_entries), 24000::numeric);
select pg_temp.login('staff');
select pg_temp.eq('staff เห็นเฉพาะของตัวเอง (draft.read_own)', (select string_agg(memo, ',') from sri_os.draft_entries), 'ของ staff');

-- A2 · staff อนุมัติ/ปฏิเสธเองไม่ได้ (draft_review ต้อง ledger.approve) — เงียบ 0 แถว
select pg_temp.eq('staff ปิดร่างตัวเองไม่ได้', pg_temp.rows_hit($q$update sri_os.draft_entries set status = 'approved' where id = '00000000-0000-0000-0000-0000000d0001'$q$), 0::bigint);
do $$ begin
  begin
    insert into sri_os.transactions(owner_id, txn_type_code, doc_date, asset_id, contact_id, created_by)
    select id, 'inc.rent', date '2026-09-10', null, null, pg_temp.uid('staff') from sri_os.owners where code = 'THANAKORN';
    raise exception 'FAIL: staff insert transactions ได้';
  exception when others then if sqlerrm like 'FAIL:%' then raise; end if; end;
end $$;

-- A3 · อนุมัติ: fn_post_entry (ค้างรับ ไม่มีเงินสด) แล้วปิดร่าง
select pg_temp.login('mgmt');
create temporary table t_posted(r jsonb);
grant all on t_posted to authenticated;
insert into t_posted select sri_os.fn_post_entry(jsonb_build_object(
  'txn_type_code', 'inc.rent', 'doc_date', '2026-09-10', 'memo', 'ของ staff',
  'asset_id', '00000000-0000-0000-0000-00000000a001', 'contact_id', '00000000-0000-0000-0000-00000000c001',
  'transactions', jsonb_build_array(jsonb_build_object('owner_id', (select id from sri_os.owners where code = 'THANAKORN'),
    'lines', jsonb_build_array(
      jsonb_build_object('coa_code', '1200', 'asset_id', '00000000-0000-0000-0000-00000000a001', 'debit', 12000, 'credit', 0, 'cf_category', 'operating'),
      jsonb_build_object('coa_code', '4200', 'debit', 0, 'credit', 12000, 'cf_category', 'operating'))))));
select pg_temp.eq('ลงสมุดแล้ว 1 ใบ', jsonb_array_length((select r->'transaction_ids' from t_posted)), 1);
select pg_temp.eq('ปิดร่างพร้อมชี้ใบที่ลง', pg_temp.rows_hit(format($q$update sri_os.draft_entries set status = 'approved', posted_txn_id = %L, reviewed_by = %L, reviewed_at = now() where id = '00000000-0000-0000-0000-0000000d0001' and status = 'pending'$q$,
  (select r->'transaction_ids'->>0 from t_posted), pg_temp.uid('mgmt'))), 1::bigint);
select pg_temp.eq('ปิดซ้ำไม่ได้ (eq status pending → 0 แถว)', pg_temp.rows_hit($q$update sri_os.draft_entries set status = 'approved' where id = '00000000-0000-0000-0000-0000000d0001' and status = 'pending'$q$), 0::bigint);
select pg_temp.eq('ลูกหนี้ค่าเช่า 12,000 ไม่มีเงินสดเคลื่อน', (select sum(v.debit - v.credit) from sri_os.v_ledger_posted v join sri_os.chart_of_accounts c on c.id = v.coa_id where c.code = '1200'), 12000::numeric);
select pg_temp.eq('ไม่มีบรรทัดเงินสด', (select count(*) from sri_os.v_ledger_posted v join sri_os.chart_of_accounts c on c.id = v.coa_id where c.code = '1100'), 0::bigint);

-- A4 · ไม่อนุมัติ: แก้เฉพาะร่าง สมุดไม่เปลี่ยน
select pg_temp.eq('สมุดก่อนปฏิเสธ', (select count(*) from sri_os.v_ledger_posted), 2::bigint);
select pg_temp.eq('ปฏิเสธใบที่สองได้', pg_temp.rows_hit(format($q$update sri_os.draft_entries set status = 'rejected', reject_reason = 'ยอดไม่ตรง', reviewed_by = %L, reviewed_at = now() where id = '00000000-0000-0000-0000-0000000d0002' and status = 'pending'$q$, pg_temp.uid('mgmt'))), 1::bigint);
select pg_temp.eq('สมุดหลังปฏิเสธ ไม่เปลี่ยน', (select count(*) from sri_os.v_ledger_posted), 2::bigint);

-- D1/D2 · ข้อสังเกตที่ DB ยังไม่บังคับ (ถ้าวันหนึ่ง DB บังคับ ข้อนี้จะแดง → ให้แก้เทสต์เป็นการยืนยันด่านใหม่)
reset role;
insert into sri_os.draft_entries(id, owner_id, txn_type_code, doc_date, amount, asset_id, contact_id, memo, created_by)
select '00000000-0000-0000-0000-0000000d0003', id, 'inc.rent', date '2026-09-11', 500, '00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-00000000c001', 'ผู้อนุมัติสร้างเอง', pg_temp.uid('mgmt')
  from sri_os.owners where code = 'THANAKORN';
set local role authenticated;
select pg_temp.login('mgmt');
-- **D1 (ปรับตามคำสั่งลูกพี่ 25/10)** — ผู้อนุมัติปิดร่างที่ตัวเองคีย์ **ได้**
-- โหมดปัจจุบันคือ `any_approver` (settings[approval.self_review] · 20261025000019)
-- แต่ "อนุญาต" ไม่เท่ากับ "ไม่บันทึก" → ใบนั้นต้องขึ้นรายงาน fn_self_reviewed_drafts()
-- (สามโหมดของสวิตช์ และของที่ยังห้ามทุกโหมด ทดสอบที่ zz_draft_self_review_test.sql)
do $d1$
declare n bigint;
begin
  update sri_os.draft_entries
     set status = 'rejected', reject_reason = 'x',
         reviewed_by = pg_temp.uid('mgmt'), reviewed_at = now()
   where id = '00000000-0000-0000-0000-0000000d0003';
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'FAIL D1 · ผู้อนุมัติปิดร่างที่ตัวเองคีย์ไม่ได้ (% แถว) — ลูกพี่สั่งเองว่าต้องทำได้', n;
  end if;
  if not exists (select 1 from sri_os.fn_self_reviewed_drafts() r
                  where r.draft_id = '00000000-0000-0000-0000-0000000d0003') then
    raise exception 'FAIL D1b · ใบที่คนคีย์ตัดสินเองต้องขึ้นรายงานให้ไล่ดูได้ — อนุญาตแล้วไม่ได้แปลว่าเลิกบันทึก';
  end if;
  raise notice 'ok D1 · ผู้อนุมัติปิดร่างที่ตัวเองคีย์ได้ (โหมด any_approver) และใบนั้นขึ้นรายงานการอนุมัติตัวเอง';
end $d1$;

-- D2 ต้องใช้ร่างใหม่ที่ยัง pending ไม่ใช่ร่างที่ D1 เพิ่งปฏิเสธไป
-- (ร่างนี้ `mgmt` คีย์เองเหมือนกัน แต่ `trg_draft_post_once` ยิงก่อน `trg_draft_review_separation`
--  ตามลำดับชื่อ → ข้อความที่ได้ยังเป็นด่าน "ต้องมีใบในสมุด" ซึ่งเป็นสิ่งที่ข้อนี้วัด)
-- ไม่งั้นจะไปชนด่าน "ร่างที่ตัดสินแล้วแก้ไม่ได้" ซึ่งเป็นคนละด่านกับที่ข้อนี้ตั้งใจวัด
do $d2$
declare
  v_refused boolean := false;
  v_msg     text;
  v_owner   uuid;
begin
  select id into v_owner from sri_os.owners where code = 'THANAKORN';
  insert into sri_os.draft_entries(id, owner_id, txn_type_code, doc_date, amount, asset_id, contact_id, memo, created_by)
  values ('00000000-0000-0000-0000-0000000d0004', v_owner, 'inc.rent', date '2026-09-11', 500,
          '00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-00000000c001',
          'ร่างสำหรับวัด D2', pg_temp.uid('mgmt'));

  -- ปิดแล้วโดย 20261025000017: approved ต้องมี posted_txn_id
  -- และต้องลงสมุดในธุรกรรมเดียวกับการอนุมัติ
  begin
    update sri_os.draft_entries set status = 'approved'
     where id = '00000000-0000-0000-0000-0000000d0004';
  exception when others then
    v_refused := true;
    get stacked diagnostics v_msg = message_text;
  end;

  -- ตั้งธงแล้วค่อยตัดสินข้างนอก ไม่ raise ในบล็อกที่มี exception handler
  -- เพราะ error ของ trigger ก็เป็น raise_exception เหมือนกัน จะถูกดักกลืนหรือ re-raise ผิดตัว
  if not v_refused then
    raise exception 'FAIL D2 · ปิดร่างเป็น approved โดยไม่มี posted_txn_id ได้ — ด่าน 20261025000017 ไม่ทำงาน';
  end if;
  raise notice 'ok D2 · approved โดยไม่มี posted_txn_id ถูกปฏิเสธ (%)', left(v_msg, 70);
end $d2$;

reset role;
rollback;
\echo 'zz_approvals_queue_test: ผ่านทุกข้อ'
