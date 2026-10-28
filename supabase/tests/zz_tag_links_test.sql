-- ============================================================
-- SRI OS · เทสต์ **ลิงก์ tag ↔ ใบในสมุด** (20261027000002_tag_links.sql · ADR 0002)
--
-- ตารางนี้คือที่เดียวที่ tag ของกองกลางมาเจอใบของผู้ถือ → เป็นที่เดียวในเรื่อง tag
-- ที่กฎเหล็กข้อ 1 (ห้ามลบของที่ post แล้ว) และข้อ 3 (ทุกแถวมี owner_id) บังคับเต็มรูป
--
-- สิ่งที่ไฟล์นี้พิสูจน์:
--   K0 · โครงสร้าง — **ไม่มีคอลัมน์จำนวนเงินแม้คอลัมน์เดียว** · ไม่มี policy DELETE ·
--        partial unique index สองตัว · trigger ไม่เขียน transactions/transaction_lines
--   K1 · `owner_id` เป็นสำเนาจากใบ: ไม่ส่งมา = อ่านจากใบเอง · ส่งผิด = **ปฏิเสธ** ·
--        แก้ย้อนหลังไม่ได้ (บทเรียนข้อ 2 และข้อ 4 ของ mace-windu)
--   K2 · `tagged_by` มาจาก auth.uid() — อ้างว่าคนอื่นติดไม่ได้ · เวลาปลอมไม่ได้
--   K3 · สำเนาชนิด/คอนฟิก (`tag_kind` · `single_per_txn`) ต้องตรงต้นฉบับ
--   K4 · **ห้าม DELETE** แม้ในฐานะ superuser · ถอดด้วย untagged_* เท่านั้น
--   K5 · ถอดต้องมีเหตุผล (ว่างไม่ได้) · ถอดแล้วแช่แข็ง · ถอดแล้วติดใหม่ได้
--   K6 · ติด tag เดิมซ้ำบนใบเดียวไม่ได้ (partial unique)
--   K7 · tag ที่ปิดแล้วติดใหม่ไม่ได้ **แต่ลิงก์เก่ายังกรองย้อนหลังเจอครบ**
--        (ข้อนี้คือความพังที่โจทย์ของลูกพี่กลัวตรงๆ)
--   K8 · ใบที่ยกเลิกแล้วติด tag ใหม่ไม่ได้ · ลิงก์เดิมไม่ถูกลบ
--   K9 · งวดที่ปิดแล้ว: ติดได้แต่ **ต้องมีเหตุผล** · สวิตช์ล็อก = ปฏิเสธ ·
--        ค่าคอนฟิกเพี้ยน = ปฏิเสธ (ไม่เดา)
--   K10 · พลิก allows_multi ตอนมีลิงก์ที่ใช้งานอยู่ไม่ได้ (ต้องมาพร้อม backfill)
--   K11 · RLS — tag.assign + ขอบเขตของใบ · ไม่มี ledger.read = มองไม่เห็นและติดไม่ได้ ·
--         UPDATE ทำได้ทางเดียวคือถอด
--   K12 · **ตัวเลขที่อ่านผิดได้** (ADR 0002 หัวข้อ 4.1): ใบเดียวติดสอง project แล้ว
--         เอายอดต่อ tag มาบวกกัน = สองเท่าของเงินจริง → เป็นเหตุผลที่ ADR 0003
--         บังคับถ่วงน้ำหนัก และที่ห้ามมีคอลัมน์ "ยอด" ในตารางนี้
--
-- รันในฐานะ superuser = ข้าม RLS แต่ trigger/constraint ยังทำงานทุกเส้นทาง
--   (กฎร่องรอยห้ามขึ้นกับสิทธิ์) · K11 เดินเส้นทางจริงด้วย role authenticated
--
-- mutation ที่ต้องทำให้เทสต์แดง:
--   M1 ให้ trigger ทับ owner_id เงียบๆ แทนการปฏิเสธ      → K1b แดง
--   M2 ถอด trigger trg_tag_link_no_delete                → K4a แดง
--   M3 ถอดเงื่อนไข untag_reason                           → K5a K5b แดง
--   M4 ถอด predicate ของ tag_link_active_uq               → K5e แดง
--   M5 ยอมให้ติด tag ที่ is_active = false                → K7a แดง
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
--   k_mgmt  · management (owner.view_all + ledger.read + portfolio.view_all + tag.assign)
--   k_mgr   · manager    (ledger.read · ไม่มี owner.view_all/portfolio.view_all)
--   k_staff · staff      (**ไม่มี ledger.read** · มี tag.assign)
--   k_other · management คนที่สอง — ใช้พิสูจน์ว่าอ้างว่าคนอื่นติด/ถอดไม่ได้
-- ------------------------------------------------------------
create temporary table t_kuid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_kuid(label) values ('k_mgmt'), ('k_mgr'), ('k_staff'), ('k_other');
insert into auth.users(id) select id from t_kuid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select id, label || '@taglink.local', label,
       case label when 'k_mgr' then 'manager' when 'k_staff' then 'staff' else 'management' end,
       true
  from t_kuid;

create or replace function pg_temp.kuid(p_label text) returns uuid
language sql stable as $fn$ select id from t_kuid where label = p_label $fn$;

create or replace function pg_temp.klogin(p_label text) returns void
language sql as $fn$
  select set_config('test.uid', coalesce((select id::text from t_kuid where label = p_label), ''), true);
$fn$;

create or replace function pg_temp.own(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.owners where code = p_code $fn$;

create or replace function pg_temp.coa(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.chart_of_accounts where code = p_code $fn$;

-- manager เห็นเฉพาะ THANAKORN (ไม่แจก SUTEE ให้โดยตั้งใจ) · staff ก็แจกให้เหมือนกัน
-- → ชั้นที่ staff ตกคือ `ledger.read` ไม่ใช่ขอบเขตผู้ถือ (พิสูจน์ที่ K11)
insert into sri_os.user_owner_access(user_id, owner_id)
select pg_temp.kuid(l), pg_temp.own('THANAKORN') from unnest(array['k_mgr', 'k_staff']) l;

create or replace function pg_temp.fire() returns void
language plpgsql as $fn$
begin
  set constraints all immediate;
  set constraints all deferred;
end $fn$;

create or replace function pg_temp.must_fail_like(p_label text, p_sql text, p_needle text) returns void
language plpgsql as $fn$
declare v text;
begin
  begin
    execute p_sql;
    perform pg_temp.fire();
    raise exception 'KG_UNEXPECTED_SUCCESS';
  exception when others then
    v := sqlerrm;
    if v = 'KG_UNEXPECTED_SUCCESS' then
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
  perform pg_temp.fire();
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: % — เส้นทางที่ถูกต้องถูกปฏิเสธ (กันแน่นเกิน): %', p_label, sqlerrm;
end $fn$;

-- ใบตั้งค้างจ่าย: Dr 5900 ค่าใช้จ่ายอื่น / Cr 2100 เจ้าหนี้ค้างจ่าย (ไม่มีขาเงินสด)
-- หมวด exp.other ตั้งค้างจ่ายได้จริง (can_accrue = true · D-107) — แพทเทิร์นเดียวกับ
-- zz_void_ledger_test เพื่อไม่ต้องพึ่งประตู fn_post_entry (ซึ่งยังไม่รู้จัก tag_ids)
-- `created_by` ส่งเข้ามาได้เพราะ `fn_can_read_txn` ให้ manager เห็น **เฉพาะรายการที่
-- ตัวเองคีย์** (ไม่มี portfolio.view_all) → เคส RLS ของ manager ต้องมีใบที่ manager คีย์จริง
create or replace function pg_temp.mk(p_id uuid, p_owner text, p_amt numeric,
                                     p_date date default current_date,
                                     p_created_by uuid default null) returns uuid
language plpgsql as $fn$
begin
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, memo, attachments,
                                  created_by)
  values (p_id, pg_temp.own(p_owner), 'exp.other', p_date, 'KG ' || p_id::text,
          array['หลักฐาน-KG.pdf'], coalesce(p_created_by, auth.uid()));
  insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit, cf_category, memo)
  values (p_id, pg_temp.coa('5900'), p_amt, 0, 'none', 'ขาค่าใช้จ่าย'),
         (p_id, pg_temp.coa('2100'), 0, p_amt, 'none', 'ขาเจ้าหนี้');
  perform pg_temp.fire();
  return p_id;
end $fn$;

create or replace function pg_temp.tag(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.tags where code = p_code $fn$;

select pg_temp.klogin('k_mgmt');

/**
 * ชนิดของเทสต์ไฟล์นี้ — **แก้ 28/10 พร้อม ADR 0003 ชิ้น A2**
 *
 * เดิมไฟล์นี้ใช้ชนิด `project` ของจริง แต่ A2 เพิ่มด่าน Σ น้ำหนัก = 1.000000
 * ต่อ (ใบ × ชนิดที่ `requires_allocation`) ซึ่งทำให้ "ติด project แล้วไม่ใส่น้ำหนัก"
 * กลายเป็น **สภาพที่ DB ไม่ยอมรับ** (ซึ่งถูกต้องตาม ADR 0003 ข้อ 4.1)
 *
 * ไฟล์นี้ทดสอบ **ตารางลิงก์** ไม่ได้ทดสอบการปันส่วน จึงใช้ชนิดของตัวเองที่
 * `requires_allocation = false` และ `allows_multi = true` เพื่อให้กลไกที่ทดสอบ
 * (สำเนาคอนฟิก · ติดได้หลายอัน · การนับซ้ำของ touch · คานของทางเลือก B)
 * เหมือนเดิมทุกข้อ · ด่านน้ำหนักมีเทสต์ของตัวเองที่ `zz_tag_allocation_test.sql`
 *
 * **ห้ามเปลี่ยนกลับไปใช้ `project` เฉยๆ** — จะทำให้ไฟล์นี้แดงทั้งไฟล์ และถ้า
 * "แก้" ด้วยการใส่น้ำหนักให้ทุกเคส เคส "ติด tag เดิมใหม่หลังถอด" จะไม่ได้
 * ทดสอบตารางลิงก์อีกต่อไป
 */
insert into sri_os.tag_kinds(key, name_th, name_en, allows_multi, aggregate_note_th,
                             requires_allocation)
values ('kgmulti', 'ชนิดหลายอัน (เทสต์ลิงก์)', 'Multi kind (link test)', true,
        'ยอดที่แตะ tag นี้ · ใบที่ติดหลาย tag ถูกนับในทุก tag ที่ติด — เอายอดของแต่ละ tag มาบวกกันไม่ได้',
        false)
on conflict (key) do nothing;

-- แค็ตตาล็อกของเทสต์ (ไฟล์ migration ไม่ seed tag ตัวอย่างเลยตาม ADR)
insert into sri_os.tags(kind, code, name_th, color_token) values
  ('kgmulti', 'kg-iris', 'ไอริส 235', 'brand'),
  ('kgmulti', 'kg-reno', 'รีโนเวต 2026', 'info'),
  ('label',   'kg-urgent', 'เร่งด่วน', 'warn'),
  ('label',   'kg-old', 'ป้ายที่จะถูกปิด', null);

-- ============================================================
-- K0 · โครงสร้าง
-- ============================================================
do $$
declare v text;
begin
  if to_regclass('sri_os.transaction_tags') is null then
    raise exception 'FAIL: K0 — ยังไม่มีตาราง transaction_tags เทสต์นี้จะไม่ได้ตรวจอะไร';
  end if;

  -- (ก) **ห้ามมีคอลัมน์จำนวนเงิน/สัดส่วน** — ปิดทางเลือก C เชิงโครงสร้าง
  select string_agg(c.column_name || ' (' || c.data_type || ')', ', ') into v
    from information_schema.columns c
   where c.table_schema = 'sri_os' and c.table_name = 'transaction_tags'
     and c.data_type in ('numeric', 'money', 'double precision', 'real');
  if v is not null then
    raise exception 'FAIL: K0a — transaction_tags มีคอลัมน์ตัวเลขเงิน/สัดส่วน: % · tag ต้องไม่มีน้ำหนักต่อตัวเลขในงบ (ADR 0002 หัวข้อ 5 ข้อ 4) · น้ำหนัก 60/40 ของ ADR 0003 อยู่ใน tag_allocations ตารางแยก', v;
  end if;

  -- (ข) trigger ของตารางนี้ห้ามเขียนสมุด (อ่านได้ เขียนไม่ได้)
  select string_agg(p.proname, ', ') into v
    from pg_trigger g join pg_proc p on p.oid = g.tgfoid
   where g.tgrelid = 'sri_os.transaction_tags'::regclass and not g.tgisinternal
     and p.prosrc ~* '(insert\s+into|update|delete\s+from)\s+(sri_os\.)?"?transaction(s|_lines)"?';
  if v is not null then
    raise exception 'FAIL: K0b — trigger ของ transaction_tags เขียน transactions/transaction_lines: % → ติด tag เปลี่ยนตัวเลขในงบได้', v;
  end if;

  -- (ค) partial unique index สองตัวตาม ADR 0002 หัวข้อ 3.3
  select string_agg(x.want, ', ') into v
    from (values ('tag_link_active_uq'), ('tag_link_single_uq')) x(want)
   where not exists (select 1 from pg_index i join pg_class c on c.oid = i.indexrelid
                      where c.relname = x.want and i.indisunique and i.indpred is not null);
  if v is not null then
    raise exception 'FAIL: K0c — index ที่ต้องเป็น partial unique หายไป/ไม่ใช่ partial unique: %', v;
  end if;

  -- (ง) ไม่มี policy DELETE และ RLS เปิด
  select string_agg(p.polname || '/' || p.polcmd::text, ', ') into v
    from pg_policy p
   where p.polrelid = 'sri_os.transaction_tags'::regclass and p.polcmd in ('d', '*');
  if v is not null then raise exception 'FAIL: K0d — มี policy DELETE/ALL: %', v; end if;
  if not (select relrowsecurity from pg_class where oid = 'sri_os.transaction_tags'::regclass) then
    raise exception 'FAIL: K0d — RLS ของ transaction_tags ปิดอยู่';
  end if;

  -- (จ) ขอบเขตอ่านต้องบังคับ ledger.read เหมือนสมุด (ไม่กว้างกว่าใบที่มันอธิบาย)
  if not sri_os.fn_policy_requires_permission('transaction_tags', 'ledger.read') then
    raise exception 'FAIL: K0e — policy อ่านของ transaction_tags ไม่บังคับ ledger.read → ข้อความเหตุผล (ที่มักมียอดเงินอยู่ในประโยค) รั่วไปถึงตำแหน่งที่อ่านสมุดไม่ได้';
  end if;

  raise notice 'ok K0 · ไม่มีคอลัมน์เงินแม้คอลัมน์เดียว · trigger ไม่เขียนสมุด · partial unique สองตัวครบ · ไม่มี policy DELETE · RLS เปิด · ขอบเขตอ่านบังคับ ledger.read';
end $$;

-- ============================================================
-- K1 · owner_id เป็นสำเนาจากใบ (กฎเหล็กข้อ 3)
-- ============================================================
do $$
declare v_t1 uuid := '00000000-0000-0000-0000-00000000c001';
        v_link uuid;
begin
  perform pg_temp.mk(v_t1, 'THANAKORN', 1000);

  -- K1a · ไม่ส่ง owner_id มาเลย → trigger อ่านจากใบเอง (ไม่ใช่ล้มด้วย not null)
  insert into sri_os.transaction_tags(transaction_id, tag_id)
  values (v_t1, pg_temp.tag('kg-iris')) returning id into v_link;
  if (select owner_id from sri_os.transaction_tags where id = v_link)
       <> pg_temp.own('THANAKORN') then
    raise exception 'FAIL: K1a — owner_id ไม่ได้ถูกอ่านจากใบ';
  end if;

  -- K1b · ส่ง owner_id ของผู้ถืออื่น → **ปฏิเสธ** (ไม่ใช่ทับเงียบๆ)
  perform pg_temp.must_fail_like('K1b ส่งผู้ถือผิดมา', format($q$
    insert into sri_os.transaction_tags(transaction_id, tag_id, owner_id)
    values (%L, %L, %L) $q$, v_t1, pg_temp.tag('kg-reno'), pg_temp.own('SUTEE')),
    'ไม่ตรงกับผู้ถือของใบ');

  -- K1c · ย้ายผู้ถือของลิงก์ที่ลงแล้ว → ปฏิเสธ (1 แถว = 1 ใบ = 1 ผู้ถือ)
  perform pg_temp.must_fail_like('K1c ย้ายผู้ถือย้อนหลัง', format($q$
    update sri_os.transaction_tags set owner_id = %L where id = %L $q$,
    pg_temp.own('SUTEE'), v_link),
    'แก้ลิงก์ tag ย้อนหลังไม่ได้');

  -- K1d · ติด tag ให้ใบที่ไม่มีอยู่ → ปฏิเสธด้วยข้อความที่บอกเรื่องจริง
  perform pg_temp.must_fail_like('K1d ใบที่ไม่มีอยู่', format($q$
    insert into sri_os.transaction_tags(transaction_id, tag_id)
    values (%L, %L) $q$, gen_random_uuid(), pg_temp.tag('kg-iris')),
    'ไม่มีใบ');

  raise notice 'ok K1 · owner_id อ่านจากใบเองเมื่อไม่ส่งมา · ส่งผิด = ปฏิเสธ (ไม่ทับเงียบๆ) · ย้ายผู้ถือย้อนหลังไม่ได้ · ใบที่ไม่มีอยู่ติดไม่ได้';
end $$;

-- ============================================================
-- K2 · tagged_by / tagged_at — ปลอมไม่ได้
-- ============================================================
do $$
declare v_t1 uuid := '00000000-0000-0000-0000-00000000c001';
        v_link uuid;
begin
  -- K2a · อ้างว่าคนอื่นเป็นคนติด → ปฏิเสธ
  perform pg_temp.must_fail_like('K2a อ้างว่าคนอื่นติด', format($q$
    insert into sri_os.transaction_tags(transaction_id, tag_id, tagged_by)
    values (%L, %L, %L) $q$, v_t1, pg_temp.tag('kg-urgent'), pg_temp.kuid('k_other')),
    'ไม่ใช่ผู้ใช้ที่กำลังติด tag');

  -- K2b · ไม่ส่ง tagged_by → ได้ auth.uid() · ส่งเวลาย้อนหลังมา → ถูกทับ
  insert into sri_os.transaction_tags(transaction_id, tag_id, tagged_at)
  values (v_t1, pg_temp.tag('kg-urgent'), '2000-01-01'::timestamptz)
  returning id into v_link;
  if (select tagged_by from sri_os.transaction_tags where id = v_link) <> pg_temp.kuid('k_mgmt') then
    raise exception 'FAIL: K2b — tagged_by ไม่ได้มาจาก auth.uid()';
  end if;
  if (select tagged_at from sri_os.transaction_tags where id = v_link) <> now() then
    raise exception 'FAIL: K2b — tagged_at ที่ส่งมาไม่ถูกทับด้วยเวลาจริง → ปลอมเวลาติด tag ให้ย้อนเข้างวดก่อนได้';
  end if;

  -- K2c · สร้างลิงก์ที่ "ถอดแล้ว" ตรงๆ ไม่ได้ (ปลอมประวัติทั้งก้อน)
  perform pg_temp.must_fail_like('K2c ลิงก์ที่เกิดมาถอดแล้ว', format($q$
    insert into sri_os.transaction_tags(transaction_id, tag_id, untagged_at, untagged_by, untag_reason)
    values (%L, %L, now(), %L, 'ปลอมประวัติ') $q$,
    v_t1, pg_temp.tag('kg-old'), pg_temp.kuid('k_mgmt')),
    'สร้างลิงก์ tag ที่ถอดไว้แล้วตรงๆ ไม่ได้');

  raise notice 'ok K2 · tagged_by = auth.uid() (อ้างคนอื่นไม่ได้) · เวลาปลอมไม่ได้ · ลิงก์ที่เกิดมาถอดแล้วสร้างไม่ได้';
end $$;

-- ============================================================
-- K3 · สำเนาชนิดและคอนฟิกต้องตรงต้นฉบับ
-- ============================================================
do $$
declare v_t1 uuid := '00000000-0000-0000-0000-00000000c001';
begin
  if (select tag_kind from sri_os.transaction_tags tt
       where tt.transaction_id = v_t1 and tt.tag_id = pg_temp.tag('kg-iris')) <> 'kgmulti' then
    raise exception 'FAIL: K3a — tag_kind ไม่ได้ถูกคัดลอกจากแค็ตตาล็อก';
  end if;
  if (select single_per_txn from sri_os.transaction_tags tt
       where tt.transaction_id = v_t1 and tt.tag_id = pg_temp.tag('kg-iris')) then
    raise exception 'FAIL: K3a — single_per_txn ต้องเป็น false วันนี้ (allows_multi = true ทั้งสองชนิดตามคำสั่ง 26/10)';
  end if;

  perform pg_temp.must_fail_like('K3b ส่งชนิดที่ขัดกับแค็ตตาล็อก', format($q$
    insert into sri_os.transaction_tags(transaction_id, tag_id, tag_kind)
    values (%L, %L, 'label') $q$, v_t1, pg_temp.tag('kg-reno')),
    'ไม่ตรงกับชนิดของ tag ในแค็ตตาล็อก');

  perform pg_temp.must_fail_like('K3c ส่ง single_per_txn เอง', format($q$
    insert into sri_os.transaction_tags(transaction_id, tag_id, single_per_txn)
    values (%L, %L, true) $q$, v_t1, pg_temp.tag('kg-reno')),
    'ไม่ตรงกับคอนฟิกของชนิด');

  perform pg_temp.must_fail_like('K3d tag ที่ไม่มีในแค็ตตาล็อก', format($q$
    insert into sri_os.transaction_tags(transaction_id, tag_id)
    values (%L, %L) $q$, v_t1, gen_random_uuid()),
    'ไม่มี tag id');

  raise notice 'ok K3 · tag_kind/single_per_txn ถูกคัดลอกจากต้นฉบับ · ส่งค่าที่ขัดกับต้นฉบับ = ปฏิเสธ · tag ที่ไม่มีในแค็ตตาล็อกติดไม่ได้';
end $$;

-- ============================================================
-- K4 · **ห้าม DELETE** — แม้ในฐานะ superuser
-- ============================================================
do $$
declare v_t1 uuid := '00000000-0000-0000-0000-00000000c001'; v_link uuid;
begin
  select id into v_link from sri_os.transaction_tags
   where transaction_id = v_t1 and tag_id = pg_temp.tag('kg-iris');

  perform pg_temp.must_fail_like('K4a ลบลิงก์', format($q$
    delete from sri_os.transaction_tags where id = %L $q$, v_link),
    'ลบลิงก์ tag ไม่ได้');

  perform pg_temp.must_fail_like('K4b ลบทั้งใบด้วย where ที่กว้าง', format($q$
    delete from sri_os.transaction_tags where transaction_id = %L $q$, v_t1),
    'ลบลิงก์ tag ไม่ได้');

  -- และลบ tag ที่ถูกใช้แล้วก็ไม่ได้ (FK restrict + trigger ของแค็ตตาล็อก)
  perform pg_temp.must_fail_like('K4c ลบ tag ที่ถูกใช้แล้ว', format($q$
    delete from sri_os.tags where id = %L $q$, pg_temp.tag('kg-iris')),
    'ปิดได้ ห้ามลบ');

  raise notice 'ok K4 · ลบลิงก์ไม่ได้ทั้งแบบระบุ id และแบบกวาดทั้งใบ · ลบ tag ที่ถูกใช้แล้วก็ไม่ได้';
end $$;

-- ============================================================
-- K5 · ถอด tag — เหตุผลบังคับ · ถอดแล้วแช่แข็ง · ถอดแล้วติดใหม่ได้
-- ============================================================
do $$
declare v_t1 uuid := '00000000-0000-0000-0000-00000000c001'; v_link uuid; v_new uuid;
begin
  select id into v_link from sri_os.transaction_tags
   where transaction_id = v_t1 and tag_id = pg_temp.tag('kg-iris');

  -- K5a · เติมเวลาแต่ไม่มีเหตุผล → ปฏิเสธ
  perform pg_temp.must_fail_like('K5a ถอดโดยไม่มีเหตุผล', format($q$
    update sri_os.transaction_tags set untagged_at = now(), untagged_by = %L where id = %L $q$,
    pg_temp.kuid('k_mgmt'), v_link),
    'ถอด tag ต้องเขียนเหตุผล');

  -- K5b · เหตุผลเป็นช่องว่างล้วน = ไม่มีเหตุผล → ปฏิเสธ
  perform pg_temp.must_fail_like('K5b เหตุผลเป็นช่องว่าง', format($q$
    update sri_os.transaction_tags
       set untagged_at = now(), untagged_by = %L, untag_reason = '   ' where id = %L $q$,
    pg_temp.kuid('k_mgmt'), v_link),
    'ถอด tag ต้องเขียนเหตุผล');

  -- K5c · แก้ค่าอื่นของลิงก์ที่ยังใช้อยู่ → ปฏิเสธ (UPDATE มีไว้เพื่อถอดเท่านั้น)
  perform pg_temp.must_fail_like('K5c แก้เหตุผลตอนติดย้อนหลัง', format($q$
    update sri_os.transaction_tags set tag_note = 'แก้ทีหลัง' where id = %L $q$, v_link),
    'แก้ลิงก์ tag ย้อนหลังไม่ได้');

  -- K5d · ถอดถูกวิธี (เหตุผลเต็มประโยคตามที่ dialog ของ ADR ออกแบบ)
  perform pg_temp.must_pass('K5d ถอดถูกวิธี', format($q$
    update sri_os.transaction_tags
       set untagged_at = now(), untagged_by = %L,
           untag_reason = 'ใบนี้เป็นค่าช่างของไซต์รีโนเวต ไม่ใช่ของไอริส 235 · ลูกพี่ยืนยัน 27/10'
     where id = %L $q$, pg_temp.kuid('k_mgmt'), v_link));
  if (select untagged_by from sri_os.transaction_tags where id = v_link) <> pg_temp.kuid('k_mgmt') then
    raise exception 'FAIL: K5d — untagged_by ไม่ใช่ผู้ที่กำลังถอด';
  end if;

  -- K5d2 · ถอดแล้วแก้ร่องรอยย้อนหลังไม่ได้
  perform pg_temp.must_fail_like('K5d2 แก้เหตุผลการถอด', format($q$
    update sri_os.transaction_tags set untag_reason = 'เปลี่ยนคำอธิบาย' where id = %L $q$, v_link),
    'ร่องรอยการถอด tag แก้ย้อนหลังไม่ได้');
  perform pg_temp.must_fail_like('K5d3 ปลด untagged_at คืน (ย้อนการถอด)', format($q$
    update sri_os.transaction_tags
       set untagged_at = null, untagged_by = null, untag_reason = null where id = %L $q$, v_link),
    'ร่องรอยการถอด tag แก้ย้อนหลังไม่ได้');

  -- K5e · ถอดแล้ว **ติด tag เดิมใหม่ได้** (เพราะ unique index เป็น partial)
  perform pg_temp.must_pass('K5e ติด tag เดิมใหม่หลังถอด', format($q$
    insert into sri_os.transaction_tags(transaction_id, tag_id, tag_note)
    values (%L, %L, 'ตรวจแล้วใบนี้อยู่ไอริส 235 จริง') $q$, v_t1, pg_temp.tag('kg-iris')));
  if (select count(*) from sri_os.transaction_tags
       where transaction_id = v_t1 and tag_id = pg_temp.tag('kg-iris')) <> 2 then
    raise exception 'FAIL: K5e — ประวัติการติด/ถอดต้องเก็บไว้ทั้งสองแถว (ถอดแล้วติดใหม่ = แถวใหม่ ไม่ใช่เขียนทับ)';
  end if;

  raise notice 'ok K5 · ถอดต้องมีเหตุผล (ว่างไม่ได้) · แก้ค่าอื่นของลิงก์ที่ใช้อยู่ไม่ได้ · ถอดแล้วแช่แข็งและย้อนไม่ได้ · ถอดแล้วติดใหม่ได้โดยประวัติเก่าอยู่ครบ';
end $$;

-- ============================================================
-- K6 · ติด tag เดิมซ้ำบนใบเดียวไม่ได้
-- ============================================================
do $$
declare v_t1 uuid := '00000000-0000-0000-0000-00000000c001';
begin
  perform pg_temp.must_fail_like('K6 ติด tag เดิมซ้ำ', format($q$
    insert into sri_os.transaction_tags(transaction_id, tag_id)
    values (%L, %L) $q$, v_t1, pg_temp.tag('kg-iris')),
    'tag_link_active_uq');
  raise notice 'ok K6 · ติด tag เดิมซ้ำบนใบเดียวไม่ได้ (ไม่งั้นยอด touch จะนับใบเดียวสองครั้งโดยไม่มีใครรู้)';
end $$;

-- ============================================================
-- K7 · tag ที่ปิดแล้ว — ติดใหม่ไม่ได้ แต่ **กรองย้อนหลังยังเจอครบ**
--      (ADR 0002 หัวข้อ 5 ข้อ 3: ถ้าหายไป การกรองย้อนหลังจะไม่ครบโดยไม่มีใครรู้)
-- ============================================================
do $$
declare v_t2 uuid := '00000000-0000-0000-0000-00000000c002'; n_before int; n_after int;
begin
  perform pg_temp.mk(v_t2, 'THANAKORN', 2000);
  perform pg_temp.must_pass('K7 ติด tag ที่ยังเปิดอยู่', format($q$
    insert into sri_os.transaction_tags(transaction_id, tag_id)
    values (%L, %L) $q$, v_t2, pg_temp.tag('kg-old')));

  select count(*) into n_before from sri_os.transaction_tags
   where tag_id = pg_temp.tag('kg-old') and untagged_at is null;

  update sri_os.tags set is_active = false where id = pg_temp.tag('kg-old');

  -- K7a · ติดใหม่ไม่ได้
  perform pg_temp.must_fail_like('K7a ติด tag ที่ปิดแล้ว', format($q$
    insert into sri_os.transaction_tags(transaction_id, tag_id)
    values (%L, %L) $q$, '00000000-0000-0000-0000-00000000c001', pg_temp.tag('kg-old')),
    'ปิดใช้งานแล้ว');

  -- K7b · ลิงก์เก่ายังอยู่และกรองย้อนหลังเจอ "จำนวนเท่าเดิม"
  select count(*) into n_after from sri_os.transaction_tags
   where tag_id = pg_temp.tag('kg-old') and untagged_at is null;
  if n_after <> n_before or n_after = 0 then
    raise exception 'FAIL: K7b — ปิด tag แล้วกรองย้อนหลังได้ % แถว (ก่อนปิด %) · ต้องเท่าเดิม ไม่งั้นการตรวจย้อนหลังไม่ครบโดยไม่มีใครรู้',
      n_after, n_before;
  end if;

  update sri_os.tags set is_active = true where id = pg_temp.tag('kg-old');
  raise notice 'ok K7 · tag ที่ปิดแล้วติดใหม่ไม่ได้ แต่ลิงก์เก่าครบจำนวนเท่าเดิม (กรองย้อนหลังยังเจอ)';
end $$;

-- ============================================================
-- K8 · ใบที่ยกเลิกแล้ว — ติด tag ใหม่ไม่ได้ · ลิงก์เดิมไม่ถูกลบ
-- ============================================================
do $$
declare v_t3 uuid := '00000000-0000-0000-0000-00000000c003'; n int;
begin
  perform pg_temp.mk(v_t3, 'THANAKORN', 3000);
  perform pg_temp.must_pass('K8 ติด tag ก่อนยกเลิก', format($q$
    insert into sri_os.transaction_tags(transaction_id, tag_id)
    values (%L, %L) $q$, v_t3, pg_temp.tag('kg-urgent')));

  update sri_os.transactions
     set status = 'void', voided_at = now(), voided_by = auth.uid(),
         void_reason = 'เทสต์: ยกเลิกเพื่อดูว่าติด tag ใหม่ได้ไหม'
   where id = v_t3;
  perform pg_temp.fire();

  perform pg_temp.must_fail_like('K8a ติด tag ให้ใบที่ยกเลิกแล้ว', format($q$
    insert into sri_os.transaction_tags(transaction_id, tag_id)
    values (%L, %L) $q$, v_t3, pg_temp.tag('kg-iris')),
    'ติด tag ใหม่ไม่ได้');

  select count(*) into n from sri_os.transaction_tags where transaction_id = v_t3;
  if n <> 1 then
    raise exception 'FAIL: K8b — ลิงก์ของใบที่ยกเลิกต้องยังอยู่เป็นร่องรอย (เจอ % แถว) · มันโผล่ในงบไม่ได้อยู่แล้วเพราะ v_ledger_posted กรอง status', n;
  end if;

  raise notice 'ok K8 · ใบที่ยกเลิกแล้วติด tag ใหม่ไม่ได้ · ลิงก์เดิมไม่ถูกลบ (เป็นร่องรอย) และโผล่ในงบไม่ได้โดยโครงสร้าง';
end $$;

-- ============================================================
-- K9 · งวดที่ปิดแล้ว (ADR 0002 หัวข้อ 5 ข้อ 3)
-- ============================================================
do $$
declare v_t4 uuid := '00000000-0000-0000-0000-00000000c004'; v_link uuid;
begin
  perform pg_temp.mk(v_t4, 'THANAKORN', 4000, '2026-03-15');
  insert into sri_os.period_closes(owner_id, period, closed_by)
  values (pg_temp.own('THANAKORN'), '2026-03-01', pg_temp.kuid('k_mgmt'));

  -- K9a · ติด tag ในงวดที่ปิดแล้วโดยไม่เขียนเหตุผล → ปฏิเสธ
  perform pg_temp.must_fail_like('K9a งวดปิดแล้วไม่เขียนเหตุผล', format($q$
    insert into sri_os.transaction_tags(transaction_id, tag_id)
    values (%L, %L) $q$, v_t4, pg_temp.tag('kg-iris')),
    'ต้องเขียนเหตุผล');

  -- K9b · เขียนเหตุผลแล้วติดได้ (tag ไม่ใช่ตัวเลข ไม่กระทบงบที่ล็อก)
  insert into sri_os.transaction_tags(transaction_id, tag_id, tag_note)
  values (v_t4, pg_temp.tag('kg-iris'), 'จัดกลุ่มย้อนหลังตามที่ลูกพี่สั่ง 27/10 — งวดนี้ปิดแล้วแต่ตัวเลขไม่เปลี่ยน')
  returning id into v_link;

  -- K9c · พลิกสวิตช์เป็น true → ถอดไม่ได้ (และติดใหม่ก็ไม่ได้)
  update sri_os.settings set value = 'true'::jsonb where key = 'tags.lock_with_period';
  perform pg_temp.must_fail_like('K9c สวิตช์ล็อก = ติดไม่ได้', format($q$
    insert into sri_os.transaction_tags(transaction_id, tag_id, tag_note)
    values (%L, %L, 'มีเหตุผลแต่สวิตช์ล็อกอยู่') $q$, v_t4, pg_temp.tag('kg-reno')),
    'ติด tag ไม่ได้');
  perform pg_temp.must_fail_like('K9c สวิตช์ล็อก = ถอดไม่ได้', format($q$
    update sri_os.transaction_tags
       set untagged_at = now(), untagged_by = %L, untag_reason = 'ลองถอดตอนล็อก'
     where id = %L $q$, pg_temp.kuid('k_mgmt'), v_link),
    'ถอด tag ไม่ได้');

  -- K9d · ค่าคอนฟิกที่ไม่ใช่ boolean → **ปฏิเสธ** ไม่ใช่เดาว่าปลดล็อก
  update sri_os.settings set value = '"yes"'::jsonb where key = 'tags.lock_with_period';
  perform pg_temp.must_fail_like('K9d คอนฟิกเพี้ยน', format($q$
    insert into sri_os.transaction_tags(transaction_id, tag_id, tag_note)
    values (%L, %L, 'คอนฟิกเพี้ยน') $q$, v_t4, pg_temp.tag('kg-reno')),
    'ไม่ใช่ boolean');

  update sri_os.settings set value = 'false'::jsonb where key = 'tags.lock_with_period';

  -- K9e · ปลดล็อกแล้วถอดได้ตามปกติ (ยังต้องมีเหตุผล)
  perform pg_temp.must_pass('K9e ปลดล็อกแล้วถอดได้', format($q$
    update sri_os.transaction_tags
       set untagged_at = now(), untagged_by = %L,
           untag_reason = 'ย้ายไปโปรเจกต์รีโนเวตตามที่ตรวจพบ 27/10'
     where id = %L $q$, pg_temp.kuid('k_mgmt'), v_link));

  raise notice 'ok K9 · งวดปิดแล้วต้องมีเหตุผลทั้งขาติดและขาถอด · สวิตช์ tags.lock_with_period บังคับได้จริงทั้งสองขา · ค่าคอนฟิกเพี้ยน = ปฏิเสธไม่ใช่เดา';
end $$;

-- ============================================================
-- K10 · พลิก allows_multi ตอนมีลิงก์ที่ใช้งานอยู่ → ต้องมาพร้อม migration backfill
-- ============================================================
do $$
begin
  perform pg_temp.must_fail_like('K10 พลิกคอนฟิกตอนมีลิงก์อยู่', $q$
    update sri_os.tag_kinds set allows_multi = false where key = 'kgmulti' $q$,
    'migration ที่ backfill');
  raise notice 'ok K10 · พลิก allows_multi/requires_allocation ด้วย UPDATE เฉยๆ ไม่ได้เมื่อมีลิงก์อยู่ (คานของทางเลือก B ต้องมาพร้อม backfill ไม่ใช่พลิกแล้วใบเก่าขัดกับคอนฟิกเงียบๆ)';
end $$;

-- ============================================================
-- K11 · RLS — เส้นทางจริงด้วย role authenticated
-- ============================================================
do $$
declare
  v_t5   uuid := '00000000-0000-0000-0000-00000000c005';
  n      int;
  v_link uuid;
  -- **อ่านค่าที่ต้องใช้ไว้ก่อนสลับ role** — ตาราง/ฟังก์ชันชั่วคราวของเทสต์
  -- `authenticated` อ่านไม่ได้ (permission denied for table t_kuid) ซึ่งจะทำให้
  -- เคสล้มด้วยเหตุผลที่ไม่เกี่ยวกับสิ่งที่กำลังพิสูจน์
  v_mgr  uuid := pg_temp.kuid('k_mgr');
  v_reno uuid := pg_temp.tag('kg-reno');
  v_urg  uuid := pg_temp.tag('kg-urgent');
begin
  -- ใบนี้ให้ manager เป็นคนคีย์ เพราะ fn_can_read_txn ให้ manager เห็นเฉพาะใบของตัวเอง
  -- (ไม่มี portfolio.view_all · ใบนี้ไม่ผูกทรัพย์) → ถ้า k_mgmt คีย์ manager จะมองไม่เห็น
  -- และเคสนี้จะพิสูจน์ผิดเรื่อง (ตกที่ขอบเขตใบ ไม่ใช่ที่สิทธิ์ tag)
  perform pg_temp.mk(v_t5, 'THANAKORN', 5000, current_date, v_mgr);

  -- (ก) manager (ledger.read + ขอบเขต THANAKORN + tag.assign + เป็นคนคีย์ใบนี้) ติดได้
  perform pg_temp.klogin('k_mgr');
  set local role authenticated;
  insert into sri_os.transaction_tags(transaction_id, tag_id)
  values (v_t5, v_reno) returning id into v_link;
  select count(*) into n from sri_os.transaction_tags where transaction_id = v_t5;
  reset role;
  if n < 1 then raise exception 'FAIL: K11a — manager ติด tag แล้วอ่านแถวของตัวเองไม่เห็น'; end if;

  -- (ข) manager ลบไม่ได้ (ไม่มี policy DELETE → 0 แถว หรือ trigger ดัง)
  begin
    set local role authenticated;
    delete from sri_os.transaction_tags where id = v_link;
    reset role;
  exception when others then
    reset role;
  end;
  if not exists (select 1 from sri_os.transaction_tags where id = v_link) then
    raise exception 'FAIL: K11b — manager ลบลิงก์ได้ผ่าน RLS';
  end if;

  -- (ค) manager แก้ค่าอื่นผ่าน RLS ไม่ได้ (policy UPDATE ยอมแค่การปิด)
  begin
    set local role authenticated;
    update sri_os.transaction_tags set tag_note = 'แก้ผ่าน RLS' where id = v_link;
    reset role;
  exception when others then
    reset role;
  end;
  if (select tag_note from sri_os.transaction_tags where id = v_link) is not null then
    raise exception 'FAIL: K11c — แก้ tag_note ของลิงก์ที่ลงแล้วผ่าน RLS ได้';
  end if;

  -- (ง) staff (ไม่มี ledger.read) มองไม่เห็นและติดไม่ได้
  perform pg_temp.klogin('k_staff');
  set local role authenticated;
  select count(*) into n from sri_os.transaction_tags;
  reset role;
  if n <> 0 then
    raise exception 'FAIL: K11d — staff (ไม่มี ledger.read) เห็นลิงก์ % แถว · ข้อความเหตุผลของลิงก์มักมียอดเงินอยู่ในประโยค จึงต้องปิดเท่ากับสมุด', n;
  end if;
  begin
    set local role authenticated;
    insert into sri_os.transaction_tags(transaction_id, tag_id) values (v_t5, v_urg);
    reset role;
    raise exception 'FAIL: K11e — staff ติด tag บนใบในสมุดได้ ทั้งที่อ่านใบนั้นไม่ได้ (ติด tag ให้ของที่มองไม่เห็น = เดา)';
  exception when insufficient_privilege then
    reset role;
  when others then
    reset role;
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  -- (จ) manager ถอดได้ (เส้นทางที่ถูกต้องห้ามถูกกัน)
  perform pg_temp.klogin('k_mgr');
  set local role authenticated;
  update sri_os.transaction_tags
     set untagged_at = now(), untagged_by = v_mgr,
         untag_reason = 'ติดผิดใบ ย้ายไปใบที่ถูกแล้ว'
   where id = v_link;
  reset role;
  if (select untagged_at from sri_os.transaction_tags where id = v_link) is null then
    raise exception 'FAIL: K11f — manager ที่มี tag.assign ถอด tag ไม่ได้ (กันแน่นเกิน)';
  end if;

  perform pg_temp.klogin('k_mgmt');
  raise notice 'ok K11 · manager ติด/ถอดได้ในขอบเขต · ลบไม่ได้ · แก้ค่าอื่นไม่ได้ · staff (ไม่มี ledger.read) มองไม่เห็นและติดบนใบไม่ได้';
end $$;

-- ============================================================
-- K12 · **ตัวเลขที่อ่านผิดได้** (ADR 0002 หัวข้อ 4.1 · 4.4)
--      ใบเดียวติดสอง project → เอายอดต่อ tag มาบวกกันได้สองเท่าของเงินจริง
--      ทั้งที่งบดุลยังดุลสนิทและ fn_health_check ยังผ่าน (ไม่มีตัวเลขในสมุดผิดเลย)
--      นี่คือเหตุผลที่ ADR 0003 สั่งถ่วงน้ำหนัก และที่ตารางนี้ห้ามมีคอลัมน์ "ยอด"
-- ============================================================
do $$
declare v_t6 uuid := '00000000-0000-0000-0000-00000000c006';
        v_ledger numeric; v_touch numeric;
begin
  perform pg_temp.mk(v_t6, 'THANAKORN', 10000000);
  insert into sri_os.transaction_tags(transaction_id, tag_id) values
    (v_t6, pg_temp.tag('kg-iris')), (v_t6, pg_temp.tag('kg-reno'));
  perform pg_temp.fire();

  select sum(l.debit) into v_ledger
    from sri_os.transaction_lines l where l.transaction_id = v_t6;

  -- "ยอดที่แตะ tag นี้" รวมทุก tag = นับใบเดิมซ้ำตามจำนวน tag ที่ติด
  select sum(x.d) into v_touch
    from (select tt.tag_id, sum(l.debit) as d
            from sri_os.transaction_tags tt
            join sri_os.transaction_lines l on l.transaction_id = tt.transaction_id
           where tt.transaction_id = v_t6 and tt.untagged_at is null
             and tt.tag_kind = 'kgmulti'
           group by tt.tag_id) x;

  if v_touch <> v_ledger * 2 then
    raise exception 'FAIL: K12 — คาดว่ายอด touch รวมสอง project = % (สองเท่าของ %) แต่ได้ % · ถ้าตัวเลขนี้เปลี่ยน แปลว่าสมมติฐานของ ADR 0002 หัวข้อ 4.1 เปลี่ยนไปแล้ว ต้องอ่าน ADR ใหม่ก่อนแก้เทสต์',
      v_ledger * 2, v_ledger, v_touch;
  end if;

  raise notice 'ok K12 · ยืนยันการนับซ้ำที่ ADR 0002 หัวข้อ 4.1 เตือนไว้: ใบ % บาทที่ติดสอง project ให้ยอด touch รวม % (สองเท่า) · งบยังดุลสนิทและไม่มีตัวเลขในสมุดผิดเลย — ผิดเฉพาะ "วิธีรวม" → ห้ามมีคอลัมน์ยอดในตารางนี้ · ชื่อวิว/คอลัมน์ต้องประกาศตัวว่าเป็น touch · และ ADR 0003 ถ่วงน้ำหนักเพื่อแก้ที่ราก',
    v_ledger, v_touch;
end $$;

-- ---------- สรุป ----------
do $$
declare n int;
begin
  perform pg_temp.fire();
  select count(*) into n from sri_os.transaction_tags;
  if n < 8 then
    raise exception 'FAIL: นับลิงก์ที่สร้างได้แค่ % — เทสต์อาจไม่ได้ลงอะไรเลย', n;
  end if;
  -- ทุกแถวต้องมีผู้ถือตรงกับใบของมัน (กฎเหล็กข้อ 3 · ไล่ทั้งตารางไม่ใช่เฉพาะแถวที่เพิ่งลง)
  if exists (select 1 from sri_os.transaction_tags tt
               join sri_os.transactions t on t.id = tt.transaction_id
              where tt.owner_id <> t.owner_id) then
    raise exception 'FAIL: มีแถวลิงก์ที่ผู้ถือไม่ตรงกับใบ → สำเนาหลุดจากต้นฉบับ';
  end if;
  raise notice 'ok K · ลิงก์ % แถว · ผู้ถือตรงกับใบทุกแถว', n;
end $$;

do $$ begin raise notice '=== ลิงก์ tag ผ่านทั้งหมด ==='; end $$;

rollback;
