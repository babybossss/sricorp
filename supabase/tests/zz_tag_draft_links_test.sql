-- ============================================================
-- SRI OS · เทสต์ **tag บนร่าง** (20261027000003_tag_draft_links.sql · ADR 0002 หัวข้อ 3.4)
--
-- ที่เก็บนี้มีไว้เพื่อให้ติด tag ได้ **ตอนคีย์ร่าง** ไม่ใช่ต้องกลับมาติดทีหลัง
-- (ใบที่ตกสำรวจคือใบที่หาไม่เจอ — "ยังไม่ติด tag เลย" จะกลายเป็นกองที่ไม่มีใครตามเก็บ)
--
-- สิ่งที่ไฟล์นี้พิสูจน์:
--   R0 · โครงสร้าง — คีย์คู่ · cascade ฝั่งร่าง/restrict ฝั่ง tag · ไม่มี policy UPDATE ·
--        ไม่มีคอลัมน์เงิน · audit เป็น fn_audit_keyed ที่คีย์ตรง PK
--   R1 · ติด/ถอด tag บนร่างที่ยัง pending ได้ (ไม่ต้องเขียนเหตุผล — ร่างไม่ใช่สมุด)
--   R2 · ติด tag เดิมซ้ำบนร่างเดียวไม่ได้
--   R3 · ร่างที่ถูกตัดสินแล้ว **ชุด tag แช่แข็ง** (ติดเพิ่ม/ถอดไม่ได้)
--   R4 · ลบร่างทั้งใบ → ลิงก์หายตามด้วย cascade (ไม่ค้างเป็นแถวกำพร้า)
--   R5 · tag ที่ปิดใช้งานแล้วติดใหม่ไม่ได้
--   R6 · RLS — staff ติด tag บนร่างของตัวเองได้ (นี่คือที่ที่ตำแหน่งนั้นทำงานจริง) ·
--        ร่างนอกขอบเขตผู้ถือติดไม่ได้
--
-- **สิ่งที่ยังไม่มีใครทำ และเทสต์นี้ไม่ได้ครอบ**: การย้าย tag จากร่างเข้าสมุดตอนอนุมัติ
--   (`fn_post_entry(tag_ids)` ของชิ้น 3) · ADR 0002 หัวข้อ 3.4 สั่งว่า "tag ที่ติดไว้
--   ตอนร่างต้องไม่หายตอนอนุมัติ" ซึ่งเป็นเทสต์บังคับของชิ้นนั้น ไม่ใช่ของไฟล์นี้
--   → ตราบใดที่ชิ้น 3 ยังไม่ลง หน้าจอยังไม่ควรเปิดช่องติด tag ตอนคีย์ร่าง
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
create temporary table t_ruid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_ruid(label) values ('r_mgmt'), ('r_staff');
insert into auth.users(id) select id from t_ruid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select id, label || '@tagdraft.local', label,
       case label when 'r_staff' then 'staff' else 'management' end, true
  from t_ruid;

create or replace function pg_temp.ruid(p_label text) returns uuid
language sql stable as $fn$ select id from t_ruid where label = p_label $fn$;

create or replace function pg_temp.rlogin(p_label text) returns void
language sql as $fn$
  select set_config('test.uid', coalesce((select id::text from t_ruid where label = p_label), ''), true);
$fn$;

create or replace function pg_temp.own(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.owners where code = p_code $fn$;

-- staff ได้ขอบเขตแค่ THANAKORN (ไม่ได้ SUTEE โดยตั้งใจ — เคส R6 ใช้พิสูจน์)
insert into sri_os.user_owner_access(user_id, owner_id)
values (pg_temp.ruid('r_staff'), pg_temp.own('THANAKORN'));

create or replace function pg_temp.must_fail_like(p_label text, p_sql text, p_needle text) returns void
language plpgsql as $fn$
declare v text;
begin
  begin
    execute p_sql;
    raise exception 'RG_UNEXPECTED_SUCCESS';
  exception when others then
    v := sqlerrm;
    if v = 'RG_UNEXPECTED_SUCCESS' then
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

/** ร่างค่าใช้จ่ายหนึ่งใบ (หมวด exp.other · แนบหลักฐาน) */
create or replace function pg_temp.mkdraft(p_owner text, p_memo text) returns uuid
language plpgsql as $fn$
declare v uuid;
begin
  insert into sri_os.draft_entries(owner_id, txn_type_code, doc_date, amount, memo,
                                   attachments, created_by)
  values (pg_temp.own(p_owner), 'exp.other', '2026-02-03', 900, p_memo,
          array['ใบแจ้งหนี้.pdf'], auth.uid())
  returning id into v;
  return v;
end $fn$;

select pg_temp.rlogin('r_mgmt');

insert into sri_os.tags(kind, code, name_th) values
  ('project', 'rg-iris', 'ไอริส 235 (ร่าง)'),
  ('project', 'rg-reno', 'รีโนเวต 2026 (ร่าง)'),
  ('label',   'rg-off',  'ป้ายที่จะถูกปิด');

-- ============================================================
-- R0 · โครงสร้าง
-- ============================================================
do $$
declare v text;
begin
  if to_regclass('sri_os.draft_entry_tags') is null then
    raise exception 'FAIL: R0 — ยังไม่มีตาราง draft_entry_tags เทสต์นี้จะไม่ได้ตรวจอะไร';
  end if;

  select string_agg(a.attname, ', ' order by k.ord) into v
    from pg_constraint con
    join unnest(con.conkey) with ordinality as k(attnum, ord) on true
    join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum
   where con.conrelid = 'sri_os.draft_entry_tags'::regclass and con.contype = 'p';
  if v is distinct from 'draft_entry_id, tag_id' then
    raise exception 'FAIL: R0a — primary key ต้องเป็น (draft_entry_id, tag_id) แต่ได้ (%)', coalesce(v, 'ไม่มี');
  end if;

  select string_agg(c.column_name, ', ') into v
    from information_schema.columns c
   where c.table_schema = 'sri_os' and c.table_name = 'draft_entry_tags'
     and c.data_type in ('numeric', 'money', 'double precision', 'real');
  if v is not null then
    raise exception 'FAIL: R0b — draft_entry_tags มีคอลัมน์ตัวเลขเงิน: % · ร่างส่งต่อให้ประตูได้แค่ "ติด tag อะไร" ไม่ใช่ตัวเลข', v;
  end if;

  -- cascade ฝั่งร่าง · restrict ฝั่ง tag
  select string_agg(con.conname || ': ' || con.confdeltype::text, ', ') into v
    from pg_constraint con
   where con.conrelid = 'sri_os.draft_entry_tags'::regclass and con.contype = 'f'
     and ((con.confrelid = 'sri_os.draft_entries'::regclass and con.confdeltype <> 'c')
       or (con.confrelid = 'sri_os.tags'::regclass and con.confdeltype <> 'r'));
  if v is not null then raise exception 'FAIL: R0c — FK ไม่ตรง ADR 0002 หัวข้อ 3.4: %', v; end if;

  -- ไม่มี policy UPDATE (ทุกคอลัมน์เป็นคีย์)
  select string_agg(p.polname || '/' || p.polcmd::text, ', ') into v
    from pg_policy p
   where p.polrelid = 'sri_os.draft_entry_tags'::regclass and p.polcmd in ('w', '*');
  if v is not null then raise exception 'FAIL: R0d — มี policy UPDATE/ALL: %', v; end if;

  if not (select relrowsecurity from pg_class where oid = 'sri_os.draft_entry_tags'::regclass) then
    raise exception 'FAIL: R0d — RLS ปิดอยู่';
  end if;

  -- audit ต้องเป็น fn_audit_keyed ที่คีย์ตรง PK (ไม่งั้นร่องรอยชี้ผิดแถว)
  if not exists (
    select 1 from pg_trigger g
     where g.tgrelid = 'sri_os.draft_entry_tags'::regclass and not g.tgisinternal
       and g.tgfoid = 'sri_os.fn_audit_keyed'::regproc
       and pg_get_triggerdef(g.oid) like '%fn_audit_keyed(''draft_entry_id'', ''tag_id'')%') then
    raise exception 'FAIL: R0e — audit ของ draft_entry_tags ไม่ใช่ fn_audit_keyed ที่คีย์ตรง PK';
  end if;

  raise notice 'ok R0 · คีย์คู่ · ไม่มีคอลัมน์เงิน · cascade ฝั่งร่าง restrict ฝั่ง tag · ไม่มี policy UPDATE · RLS เปิด · audit คีย์ตรง PK';
end $$;

-- ============================================================
-- R1 · ติด/ถอด tag บนร่างที่ยัง pending
-- ============================================================
do $$
declare v_d uuid; n int;
begin
  v_d := pg_temp.mkdraft('THANAKORN', 'R1 ร่างที่ติด tag');

  perform pg_temp.must_pass('R1a ติดสอง tag', format($q$
    insert into sri_os.draft_entry_tags(draft_entry_id, tag_id)
    select %L, id from sri_os.tags where code in ('rg-iris', 'rg-reno') $q$, v_d));
  select count(*) into n from sri_os.draft_entry_tags where draft_entry_id = v_d;
  if n <> 2 then raise exception 'FAIL: R1a — ควรมี 2 ลิงก์ แต่ได้ %', n; end if;

  -- R1b · ถอดได้โดยไม่ต้องเขียนเหตุผล (ร่างไม่ใช่สมุด · ติ๊กผิดช่องเกิดขึ้นจริง)
  perform pg_temp.must_pass('R1b ถอด tag บนร่าง', format($q$
    delete from sri_os.draft_entry_tags
     where draft_entry_id = %L and tag_id = (select id from sri_os.tags where code = 'rg-reno') $q$, v_d));
  select count(*) into n from sri_os.draft_entry_tags where draft_entry_id = v_d;
  if n <> 1 then raise exception 'FAIL: R1b — ถอดแล้วควรเหลือ 1 ลิงก์ แต่ได้ %', n; end if;

  raise notice 'ok R1 · ติด tag หลายอันบนร่างได้ · ถอดได้โดยไม่ต้องเขียนเหตุผล (ต่างจากใบในสมุดโดยเจตนา)';
end $$;

-- ============================================================
-- R2 · ติด tag เดิมซ้ำบนร่างเดียวไม่ได้
-- ============================================================
do $$
declare v_d uuid;
begin
  v_d := pg_temp.mkdraft('THANAKORN', 'R2 ร่างสำหรับเคสซ้ำ');
  perform pg_temp.must_pass('R2 ติดครั้งแรก', format($q$
    insert into sri_os.draft_entry_tags(draft_entry_id, tag_id)
    values (%L, (select id from sri_os.tags where code = 'rg-iris')) $q$, v_d));
  perform pg_temp.must_fail_like('R2 ติดซ้ำ', format($q$
    insert into sri_os.draft_entry_tags(draft_entry_id, tag_id)
    values (%L, (select id from sri_os.tags where code = 'rg-iris')) $q$, v_d),
    'draft_entry_tags_pkey');
  raise notice 'ok R2 · ติด tag เดิมซ้ำบนร่างเดียวไม่ได้ (คีย์คู่กันให้โดยโครงสร้าง)';
end $$;

-- ============================================================
-- R3 · ร่างที่ถูกตัดสินแล้ว = ชุด tag แช่แข็ง
-- ============================================================
do $$
declare v_d uuid;
begin
  v_d := pg_temp.mkdraft('THANAKORN', 'R3 ร่างที่จะถูกปฏิเสธ');
  insert into sri_os.draft_entry_tags(draft_entry_id, tag_id)
  values (v_d, (select id from sri_os.tags where code = 'rg-iris'));

  update sri_os.draft_entries
     set status = 'rejected', reject_reason = 'เทสต์: ปฏิเสธเพื่อดูว่าชุด tag แช่แข็งไหม',
         reviewed_by = auth.uid(), reviewed_at = now()
   where id = v_d;

  perform pg_temp.must_fail_like('R3a ติด tag เพิ่มบนร่างที่ตัดสินแล้ว', format($q$
    insert into sri_os.draft_entry_tags(draft_entry_id, tag_id)
    values (%L, (select id from sri_os.tags where code = 'rg-reno')) $q$, v_d),
    'ถูกตัดสินแล้ว');

  perform pg_temp.must_fail_like('R3b ถอด tag บนร่างที่ตัดสินแล้ว', format($q$
    delete from sri_os.draft_entry_tags where draft_entry_id = %L $q$, v_d),
    'ถูกตัดสินแล้ว');

  raise notice 'ok R3 · ร่างที่อนุมัติ/ปฏิเสธแล้วแก้ชุด tag ไม่ได้ — มันคือหลักฐานว่าสิ่งที่ถูกตัดสินคือใบที่ติด tag ชุดนี้';
end $$;

-- ============================================================
-- R4 · ลบร่างทั้งใบ → ลิงก์หายตาม (cascade) ไม่ค้างเป็นแถวกำพร้า
-- ============================================================
do $$
declare v_d uuid; n int;
begin
  v_d := pg_temp.mkdraft('THANAKORN', 'R4 ร่างที่จะถูกลบ');
  insert into sri_os.draft_entry_tags(draft_entry_id, tag_id)
  values (v_d, (select id from sri_os.tags where code = 'rg-iris'));

  perform pg_temp.must_pass('R4 ลบร่างที่ติด tag ไว้', format($q$
    delete from sri_os.draft_entries where id = %L $q$, v_d));
  select count(*) into n from sri_os.draft_entry_tags where draft_entry_id = v_d;
  if n <> 0 then
    raise exception 'FAIL: R4 — ลบร่างแล้วยังเหลือลิงก์ % แถว (แถวกำพร้า)', n;
  end if;

  raise notice 'ok R4 · ลบร่างที่ติด tag ไว้ได้ (cascade) — ถ้า restrict จะลบร่างไม่ได้เลยซึ่งค้าน ADR 0002 หัวข้อ 3.4';
end $$;

-- ============================================================
-- R5 · tag ที่ปิดใช้งานแล้วติดใหม่ไม่ได้ (เส้นทางจริงผ่าน RLS)
-- ============================================================
do $$
declare v_d uuid; v_off uuid;
begin
  v_d := pg_temp.mkdraft('THANAKORN', 'R5 ร่างกับ tag ที่ปิดแล้ว');
  select id into v_off from sri_os.tags where code = 'rg-off';
  update sri_os.tags set is_active = false where id = v_off;

  begin
    set local role authenticated;
    insert into sri_os.draft_entry_tags(draft_entry_id, tag_id) values (v_d, v_off);
    reset role;
    raise exception 'FAIL: R5 — ติด tag ที่ปิดใช้งานแล้วบนร่างได้';
  exception when insufficient_privilege then
    reset role;
  when others then
    reset role;
    if sqlerrm like 'FAIL:%' then raise; end if;
    raise exception 'FAIL: R5 — ถูกปฏิเสธด้วย error ที่ไม่ใช่เรื่องสิทธิ์/policy: %', sqlerrm;
  end;

  update sri_os.tags set is_active = true where id = v_off;
  raise notice 'ok R5 · tag ที่ปิดใช้งานแล้วติดบนร่างใหม่ไม่ได้ (ตัวเลือกตอนติดต้องไม่มีของที่ปิด)';
end $$;

-- ============================================================
-- R6 · RLS — staff ติด tag บนร่างของตัวเองได้ · นอกขอบเขตผู้ถือไม่ได้
--      (นี่คือเหตุผลที่ตำแหน่งที่ไม่มี ledger.read ยังทำงานเรื่อง tag ได้ครบ
--       แม้จะติด tag บนใบในสมุดไม่ได้ — ดู K11 ของ zz_tag_links_test)
-- ============================================================
do $$
declare v_own uuid; v_other uuid; n int; v_iris uuid;
begin
  perform pg_temp.rlogin('r_staff');
  v_iris := (select id from sri_os.tags where code = 'rg-iris');

  -- ร่างของ staff เอง (ในขอบเขต THANAKORN)
  v_own := pg_temp.mkdraft('THANAKORN', 'R6 ร่างของ staff');
  -- ร่างของผู้ถือที่ staff ไม่มีขอบเขต (คีย์ในฐานะ superuser)
  perform pg_temp.rlogin('r_mgmt');
  v_other := pg_temp.mkdraft('SUTEE', 'R6 ร่างนอกขอบเขตของ staff');
  perform pg_temp.rlogin('r_staff');

  set local role authenticated;
  insert into sri_os.draft_entry_tags(draft_entry_id, tag_id) values (v_own, v_iris);
  select count(*) into n from sri_os.draft_entry_tags where draft_entry_id = v_own;
  reset role;
  if n <> 1 then
    raise exception 'FAIL: R6a — staff ติด tag บนร่างของตัวเองแล้วอ่านไม่เห็น (n = %)', n;
  end if;

  begin
    set local role authenticated;
    insert into sri_os.draft_entry_tags(draft_entry_id, tag_id) values (v_other, v_iris);
    reset role;
    raise exception 'FAIL: R6b — staff ติด tag บนร่างของผู้ถือที่ตัวเองไม่มีขอบเขตได้';
  exception when insufficient_privilege then
    reset role;
  when others then
    reset role;
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  -- และ staff อ่านลิงก์ของร่างนอกขอบเขตไม่เห็น (ขอบเขตมาจาก policy ตัวจริงของร่าง)
  insert into sri_os.draft_entry_tags(draft_entry_id, tag_id) values (v_other, v_iris);
  set local role authenticated;
  select count(*) into n from sri_os.draft_entry_tags where draft_entry_id = v_other;
  reset role;
  if n <> 0 then
    raise exception 'FAIL: R6c — staff เห็นลิงก์ของร่างนอกขอบเขต % แถว', n;
  end if;

  perform pg_temp.rlogin('r_mgmt');
  raise notice 'ok R6 · staff ติด tag บนร่างของตัวเองได้ · ร่างนอกขอบเขตผู้ถือทั้งติดและอ่านไม่ได้';
end $$;

-- ---------- สรุป ----------
do $$
declare n int;
begin
  select count(*) into n from sri_os.draft_entry_tags;
  if n < 4 then
    raise exception 'FAIL: นับลิงก์บนร่างได้แค่ % — เทสต์อาจไม่ได้ลงอะไรเลย', n;
  end if;
  if exists (select 1 from sri_os.draft_entry_tags t
              where not exists (select 1 from sri_os.draft_entries d where d.id = t.draft_entry_id)) then
    raise exception 'FAIL: มีลิงก์ที่ชี้ไปหาร่างที่ไม่มีอยู่แล้ว (แถวกำพร้า)';
  end if;
  raise notice 'ok R · ลิงก์บนร่าง % แถว · ไม่มีแถวกำพร้า', n;
end $$;

do $$ begin raise notice '=== tag บนร่าง ผ่านทั้งหมด ==='; end $$;

rollback;
