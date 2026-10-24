-- ============================================================
-- SRI OS · เทสต์ "ล้างยอดค้างเกินไม่ได้" (migration 20261025000003)
--
-- ที่มา: ผู้ตรวจวัดได้ว่าเส้นทางล้างของค้าง (`confirm-cash.ts`) กันซ้ำสามชั้น
--   แต่ทุกชั้นเป็น **อ่านก่อนเขียน** → คำขอ 7,000 กับ 6,000 บนของค้าง 12,000
--   ที่มาถึงพร้อมกัน ผ่านทั้งคู่ → ล้างไป 13,000 · ลูกหนี้ติดลบ 1,000
--
-- ไฟล์นี้พิสูจน์สี่ข้อ (ข้อ 2 และ 3 สำคัญเท่าข้อ 1 — ด่านใหม่ห้ามไปฆ่าของเดิม):
--   K1 ล้างเกินยอดค้างด้วยสองคำขอที่ **ต่างยอดกัน** → ปฏิเสธ · ยอดที่เหลือถูกต้อง
--      และล้างส่วนที่เหลือพอดีได้ (ไม่กันแน่นเกิน)
--   K2 เลขอ้างอิงเดียวกันซ้ำ (เคสกดรัว/สองแท็บ) → ปฏิเสธที่ index
--   K3 **รายการข้ามผู้ถือยังลงได้ปกติ** รวมกรณีที่ source_ref มีรูปของเลขล้าง
--      (สองขาใช้ source_ref เดียวกัน — กับดักข้อ 1 ของการเลือกรูป index)
--   K4 **กลับรายการใบล้างยังทำได้ปกติ** แม้อ้างเลขอ้างอิงเดิม และยอดค้างกลับมา
--   K5 source_ref ของค่ารูปอื่น (เลขแบตช์นำเข้า) ซ้ำได้ — index ต้องไม่คุม
--   K6 ชี้ source_ref ของใบที่ post แล้วไปต้นทางอื่น → ปฏิเสธ (ล้างเกินโดยไม่แตะบรรทัด)
--   K7 **MUTATION** ถอด index + ด่าน → การล้างเกินสำเร็จจริง พร้อมตัวเลขที่วัดได้
--
-- **เรื่องจังหวะพร้อมกันจริง (สองเซสชัน) พิสูจน์ที่นี่ไม่ได้** — psql เดียวมีธุรกรรม
--   เดียว · ด่านที่ปิดเรื่องนั้นคือ `select ... for update` บนแถวต้นทาง ซึ่ง
--   guard (จ) ของ migration ตรวจว่ายังอยู่ในโค้ด และผมวัดด้วยสองเซสชันจริง
--   ตอนส่งงาน (ผลอยู่ในรายงาน) · ไฟล์นี้คุมส่วนที่พิสูจน์ได้ด้วยเซสชันเดียว:
--   **สมการยอดรวม** ซึ่งเป็นตัวที่ทำให้คำขอที่สอง (หลังรอล็อก) ถูกปฏิเสธ
--
-- ทุกใบลงผ่าน `sri_os.fn_post_entry()` เท่านั้น · ทั้งไฟล์ rollback ปิดท้าย
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
select u.id, 'clearing@local', 'mgmt', 'management', true from t_uid u;

select set_config('test.uid', (select id::text from t_uid where label = 'mgmt'), true);

insert into sri_os.user_owner_access(user_id, owner_id)
select (select id from t_uid where label = 'mgmt'), o.id from sri_os.owners o;

-- บัญชีของสองผู้ถือ (ใบข้ามผู้ถือต้องมีบัญชีของทั้งคู่ · trg_line_bank_owner)
insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
values ('00000000-0000-0000-0000-00000004b001',
        (select id from sri_os.owners where code = 'THANAKORN'),
        'BBL', 'ธนากร', 'ธนากร - BBL (ล้างของค้าง)'),
       ('00000000-0000-0000-0000-00000004b002',
        (select id from sri_os.owners where code = 'SUTEE'),
        'KBANK', 'สุธี', 'สุธี - KBANK (ล้างของค้าง)');

insert into sri_os.contacts(id, first_name, types)
values ('00000000-0000-0000-0000-00000004c001', 'ผู้เช่า (ล้างของค้าง)', array['tenant']);

insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, currency)
select '00000000-0000-0000-0000-00000004a001', 'CLR-RENT', 'คอนโดให้เช่า (ล้างของค้าง)',
       cat.class_id, cat.id, (select id from sri_os.owners where code = 'THANAKORN'), 'THB'
  from (select id, class_id from sri_os.asset_categories order by id limit 1) cat;

create or replace function pg_temp.owner(p_code text default 'THANAKORN') returns uuid
language sql stable as $fn$ select id from sri_os.owners where code = p_code $fn$;

create or replace function pg_temp.ln(p_code text, p_dr numeric, p_cr numeric,
                                     p_cf text default null, p_bank uuid default null,
                                     p_asset uuid default null) returns jsonb
language sql immutable as $fn$
  select jsonb_strip_nulls(jsonb_build_object(
    'coa_code', p_code, 'debit', p_dr, 'credit', p_cr,
    'cf_category', p_cf, 'bank_account_id', p_bank, 'asset_id', p_asset));
$fn$;

/** ใบของผู้ถือเดียว (ธนากร) */
create or replace function pg_temp.entry(p_type text, p_memo text, p_lines jsonb,
                                        p_cash_date date default '2026-10-31',
                                        p_ref text default null,
                                        p_source text default 'manual',
                                        p_reverses uuid default null)
returns jsonb language sql stable as $fn$
  select jsonb_strip_nulls(jsonb_build_object(
    'txn_type_code', p_type,
    'doc_date', '2026-10-31',
    'cash_date', case when p_cash_date is null then null else p_cash_date::text end,
    'memo', p_memo,
    'asset_id', '00000000-0000-0000-0000-00000004a001',
    'contact_id', '00000000-0000-0000-0000-00000004c001',
    'attachments', jsonb_build_array('หลักฐาน.pdf'),
    'source', p_source,
    'source_ref', p_ref,
    'reverses_id', p_reverses,
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', pg_temp.owner(), 'lines', p_lines))));
$fn$;

create or replace function pg_temp.post(p_payload jsonb) returns uuid
language plpgsql as $fn$
declare v jsonb;
begin
  v := sri_os.fn_post_entry(p_payload);
  if (v ->> 'replayed')::boolean then
    raise exception 'FAIL: fn_post_entry ถือว่าใบนี้เป็นการกดซ้ำ (memo ของแต่ละใบต้องไม่ซ้ำกัน)';
  end if;
  return ((v -> 'transaction_ids') ->> 0)::uuid;
end $fn$;

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

/** ยอดคงเหลือในบัญชีพัก 1200 ของทั้งสมุด (ลูกหนี้ค่าเช่า) */
create or replace function pg_temp.receivable() returns numeric
language sql stable as $fn$
  select coalesce(sum(v.debit - v.credit), 0)
    from sri_os.v_ledger_posted v
    join sri_os.chart_of_accounts c on c.id = v.coa_id
   where c.code = '1200';
$fn$;

/**
 * ยอดคงเหลือในบัญชีพัก 1200 **ของรายการต้นทางใบหนึ่ง**
 * เขียนเงื่อนไขเองด้วย `like` (ไม่เรียก fn_clearing_ref_source ของ migration)
 * เพื่อให้การวัดไม่ขึ้นกับสิ่งที่กำลังทดสอบ
 */
create or replace function pg_temp.src_balance(p_src uuid) returns numeric
language sql stable as $fn$
  select coalesce(sum(v.debit - v.credit), 0)
    from sri_os.v_ledger_posted v
    join sri_os.chart_of_accounts c on c.id = v.coa_id
   where c.code = '1200'
     and (v.transaction_id = p_src or v.source_ref like p_src::text || '-clr-%');
$fn$;

-- ============================================================
-- K0 · โครงสร้าง — ไล่จาก catalog จริง ไม่ใช่ไล่ไฟล์
-- ============================================================
do $$
declare v text;
begin
  select pg_get_indexdef(i.oid) into v from pg_class i
    join pg_namespace ns on ns.oid = i.relnamespace
   where ns.nspname = 'sri_os' and i.relname = 'transactions_clearing_ref_once';
  if v is null then
    raise exception 'FAIL: ไม่มี index transactions_clearing_ref_once';
  end if;
  if v !~ 'UNIQUE' or v !~ 'WHERE' or v !~ 'owner_id' or v !~ 'reverses_id IS NULL' then
    raise exception 'FAIL: รูปของ index ไม่ถูก (ต้อง unique · partial · มี owner_id · ยกเว้นใบกลับรายการ): %', v;
  end if;

  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.transaction_lines'::regclass
                    and g.tgname = 'trg_assert_clearing_not_over'
                    and not g.tgisinternal and g.tgdeferrable and g.tginitdeferred) then
    raise exception 'FAIL: ไม่มี constraint trigger แบบ deferred บน transaction_lines';
  end if;
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.transactions'::regclass
                    and g.tgname = 'trg_assert_clearing_not_over_txn'
                    and not g.tgisinternal and not g.tgdeferrable) then
    raise exception 'FAIL: ไม่มี trigger แบบยิงทันทีบน transactions (แก้ source_ref ย้อนหลังจะไม่มีใครตรวจ)';
  end if;

  -- **ล็อกแถวต้นทาง** — ตัวที่ปิดจังหวะพร้อมกัน · ตรวจจากโค้ดเพราะเซสชันเดียวพิสูจน์ไม่ได้
  if pg_get_functiondef('sri_os.fn_assert_clearing_not_over_for(uuid)'::regprocedure) !~* 'for update' then
    raise exception 'FAIL: fn_assert_clearing_not_over_for ไม่ได้ล็อกแถวรายการต้นทาง → คำขอที่มาพร้อมกันจะผ่านทั้งคู่';
  end if;

  if has_function_privilege('anon', 'sri_os.fn_clearing_ref_source(text)', 'execute') then
    raise exception 'FAIL: anon เรียก fn_clearing_ref_source ได้';
  end if;
  foreach v in array array['sri_os.fn_assert_clearing_not_over_for(uuid)',
                           'sri_os.fn_assert_clearing_not_over()',
                           'sri_os.fn_assert_clearing_not_over_txn()'] loop
    if has_function_privilege('authenticated', v, 'execute') then
      raise exception 'FAIL: authenticated เรียก % ตรงได้ = ทางข้าม policy', v;
    end if;
  end loop;

  raise notice 'ok K0 · index รูปถูก (unique · partial · มี owner_id · ยกเว้นใบกลับรายการ) · trigger ผูกสองตาราง · ล็อกแถวต้นทางยังอยู่ · ฟังก์ชันด่านปิด';
end $$;

-- ============================================================
-- K1 · ตั้งค้าง 12,000 → ล้าง 7,000 (ได้) → ล้าง 6,000 อีกใบ (**ต้องถูกปฏิเสธ**)
--      → ล้างส่วนที่เหลือ 5,000 พอดี (ได้)
--
-- สองใบล้างใช้เลขอ้างอิงต่างกัน (`-clr-1` กับ `-clr-2`) = จำลองจังหวะที่คำขอ
-- ที่สองอ่านประวัติได้ต่างจากคำขอแรก · เลขไม่ซ้ำ index จึงไม่ติด
-- ตัวที่ต้องปฏิเสธคือ **สมการยอดรวมต่อรายการต้นทาง** เท่านั้น
--
-- **ผู้ถือมีของค้างอีกก้อน 50,000 โดยตั้งใจ** — ด่านเก่า
-- (`trg_txn_allowance_limits` · 20261009000004) ตรวจว่า "ยอดลูกหนี้ 1200
-- **ต่อผู้ถือ** ห้ามติดลบ" ซึ่งเงียบสนิทเมื่อผู้ถือมีลูกหนี้ก้อนอื่นคลุมอยู่
-- → เคสนี้พิสูจน์ว่าด่านใหม่คุม **ต่อรายการต้นทาง** ซึ่งเป็นรูที่ด่านเก่าไม่เห็น
-- (ถ้าไม่มีก้อน 50,000 ด่านเก่าจะเป็นคนปฏิเสธและเทสต์นี้จะไม่ได้พิสูจน์อะไร —
--  เคส K1e ยืนยันสภาพนั้นไว้ด้วย ไม่ใช่เดา)
-- ============================================================
do $$
declare v_src uuid; v_other uuid; v_ref1 text; v_ref2 text;
begin
  -- ของค้างก้อนอื่นของผู้ถือเดียวกัน (ทำให้ยอดรวมของผู้ถือไม่ติดลบตลอดเคสนี้)
  v_other := pg_temp.post(pg_temp.entry('inc.rent', 'K1 ตั้งค้างรับค่าเช่าอีกก้อน 50,000',
    jsonb_build_array(
      pg_temp.ln('1200', 50000, 0, 'none', null, '00000000-0000-0000-0000-00000004a001'),
      pg_temp.ln('4200', 0, 50000, 'none', null, '00000000-0000-0000-0000-00000004a001')),
    null));

  v_src := pg_temp.post(pg_temp.entry('inc.rent', 'K1 ตั้งค้างรับค่าเช่า 12,000',
    jsonb_build_array(
      pg_temp.ln('1200', 12000, 0, 'none', null, '00000000-0000-0000-0000-00000004a001'),
      pg_temp.ln('4200', 0, 12000, 'none', null, '00000000-0000-0000-0000-00000004a001')),
    null));
  if pg_temp.src_balance(v_src) <> 12000 then
    raise exception 'FAIL: K1 — ตั้งค้างแล้วยอดค้างของใบนี้ควรเป็น 12,000 แต่ได้ %', pg_temp.src_balance(v_src);
  end if;

  v_ref1 := v_src::text || '-clr-1';
  v_ref2 := v_src::text || '-clr-2';

  -- คำขอแรก 7,000 — ผ่าน
  perform pg_temp.post(pg_temp.entry('inv.collect_rent', 'K1 ล้าง 7,000',
    jsonb_build_array(
      pg_temp.ln('1100', 7000, 0, 'operating', '00000000-0000-0000-0000-00000004b001'),
      pg_temp.ln('1200', 0, 7000, 'operating', null, '00000000-0000-0000-0000-00000004a001')),
    '2026-10-31', v_ref1));
  if pg_temp.src_balance(v_src) <> 5000 then
    raise exception 'FAIL: K1 — ล้าง 7,000 แล้วยอดค้างของใบนี้ควรเหลือ 5,000 แต่ได้ %', pg_temp.src_balance(v_src);
  end if;

  -- คำขอที่สอง 6,000 (รวมเป็น 13,000 เกินยอดค้าง 12,000) — **ต้องถูกปฏิเสธ**
  -- ยอดรวมของผู้ถือยังเป็น 49,000 (ไม่ติดลบ) → ด่านเก่าเงียบ ตัวที่พูดคือด่านใหม่
  perform pg_temp.must_fail_like('K1b ล้างรวมเกินยอดค้างของรายการต้นทาง',
    format($q$ select pg_temp.post(pg_temp.entry('inv.collect_rent', 'K1b ล้าง 6,000 เกินยอด',
          jsonb_build_array(
            pg_temp.ln('1100', 6000, 0, 'operating', '00000000-0000-0000-0000-00000004b001'),
            pg_temp.ln('1200', 0, 6000, 'operating', null, '00000000-0000-0000-0000-00000004a001')),
          '2026-10-31', %L)) $q$, v_ref2),
    'ล้างยอดค้างเกิน');

  -- ยอดต้องไม่ขยับจากใบที่ถูกปฏิเสธ
  if pg_temp.src_balance(v_src) <> 5000 then
    raise exception 'FAIL: K1b — ใบที่ถูกปฏิเสธทิ้งผลไว้ในสมุด (ยอดค้างของใบนี้ %)', pg_temp.src_balance(v_src);
  end if;
  if pg_temp.src_balance(v_other) <> 50000 then
    raise exception 'FAIL: K1b — ของค้างก้อนอื่นถูกกระทบ (%)', pg_temp.src_balance(v_other);
  end if;

  -- และล้างส่วนที่เหลือ **พอดี** ต้องทำได้ (ด่านห้ามแน่นเกิน)
  perform pg_temp.must_pass('K1c ล้างส่วนที่เหลือพอดี 5,000',
    format($q$ select pg_temp.post(pg_temp.entry('inv.collect_rent', 'K1c ล้าง 5,000 ส่วนที่เหลือ',
          jsonb_build_array(
            pg_temp.ln('1100', 5000, 0, 'operating', '00000000-0000-0000-0000-00000004b001'),
            pg_temp.ln('1200', 0, 5000, 'operating', null, '00000000-0000-0000-0000-00000004a001')),
          '2026-10-31', %L)) $q$, v_ref2));
  if pg_temp.src_balance(v_src) <> 0 then
    raise exception 'FAIL: K1c — ล้างครบแล้วยอดค้างของใบนี้ต้องเป็น 0 แต่ได้ %', pg_temp.src_balance(v_src);
  end if;

  -- ล้างต่ออีกบาทเดียวก็ไม่ได้ (ยอดรวมของผู้ถือยังบวกอยู่ 50,000 → ด่านเก่าเงียบ)
  perform pg_temp.must_fail_like('K1d ล้างต่อหลังครบแล้ว',
    format($q$ select pg_temp.post(pg_temp.entry('inv.collect_rent', 'K1d ล้างเกินอีก 1 บาท',
          jsonb_build_array(
            pg_temp.ln('1100', 1, 0, 'operating', '00000000-0000-0000-0000-00000004b001'),
            pg_temp.ln('1200', 0, 1, 'operating', null, '00000000-0000-0000-0000-00000004a001')),
          '2026-10-31', %L)) $q$, v_src::text || '-clr-3'),
    'ล้างยอดค้างเกิน');

  raise notice 'ok K1 · ล้าง 7,000 + 6,000 บนของค้าง 12,000 ถูกปฏิเสธที่ใบที่สอง (ยอดรวม 13,000 ต่อรายการต้นทาง) ขณะที่ยอดลูกหนี้รวมของผู้ถือยังบวก = ด่านเก่ามองไม่เห็น · ยอดค้างคงเหลือ 5,000 ถูกต้อง · ล้างส่วนที่เหลือพอดีได้ · เกินอีก 1 บาทไม่ได้';
end $$;

-- ------------------------------------------------------------
-- K1e · ยืนยันสภาพที่ทำให้ K1 มีความหมาย — **ด่านเก่าคุมแค่ยอดรวมต่อผู้ถือ**
--       (ของค้างก้อนเดียว ไม่มีก้อนอื่นคลุม → ด่านเก่าเป็นคนปฏิเสธก่อน)
--       ถ้าวันหนึ่งข้อนี้เปลี่ยน แปลว่าขอบเขตของด่านเก่าเปลี่ยน ต้องมาอ่าน K1 ใหม่
-- ------------------------------------------------------------
do $$
declare v_src uuid;
begin
  v_src := pg_temp.post(pg_temp.entry('inc.rent', 'K1e ตั้งค้างรับของผู้ถือที่ไม่มีก้อนอื่น',
    jsonb_build_array(
      pg_temp.ln('1200', 1000, 0, 'none', null, '00000000-0000-0000-0000-00000004a001'),
      pg_temp.ln('4200', 0, 1000, 'none', null, '00000000-0000-0000-0000-00000004a001')),
    null));
  -- ล้างให้หมดก่อน (ยอดรวมของผู้ถือตอนนี้ = 50,000 จาก K1 + 1,000 ของใบนี้)
  perform pg_temp.post(pg_temp.entry('inv.collect_rent', 'K1e ล้าง 1,000 ครบ',
    jsonb_build_array(
      pg_temp.ln('1100', 1000, 0, 'operating', '00000000-0000-0000-0000-00000004b001'),
      pg_temp.ln('1200', 0, 1000, 'operating', null, '00000000-0000-0000-0000-00000004a001')),
    '2026-10-31', v_src::text || '-clr-1'));
  -- ล้างเกิน 51,000 → **ทั้งสองด่านมีเหตุจะปฏิเสธ** (ต่อใบ และต่อผู้ถือ)
  -- ข้อนี้รับข้อความของด่านใดก็ได้ แต่ต้อง "ไม่ผ่าน" เสมอ
  perform pg_temp.must_fail_like('K1e ล้างเกินจนยอดรวมของผู้ถือติดลบ',
    format($q$ select pg_temp.post(pg_temp.entry('inv.collect_rent', 'K1e ล้างเกิน 51,000',
          jsonb_build_array(
            pg_temp.ln('1100', 51001, 0, 'operating', '00000000-0000-0000-0000-00000004b001'),
            pg_temp.ln('1200', 0, 51001, 'operating', null, '00000000-0000-0000-0000-00000004a001')),
          '2026-10-31', %L)) $q$, v_src::text || '-clr-2'),
    'ติดลบ');
  raise notice 'ok K1e · ด่านเก่า (ยอดลูกหนี้ต่อผู้ถือห้ามติดลบ) ยังทำงานและเป็นคนพูดเมื่อยอดรวมติดลบ — ด่านใหม่เป็นชั้นที่ละเอียดกว่า ไม่ใช่ตัวแทน';
end $$;

-- ============================================================
-- K2 · เลขอ้างอิงเดียวกันซ้ำ (กดรัว · สองแท็บ · เน็ตหลุดแล้วลองใหม่)
--      → ปฏิเสธที่ **index** ไม่ใช่ที่สมการยอด (ยอดรวมยังไม่เกินก็ต้องไม่ผ่าน
--        เพราะประวัติการล้างจะมีสองแถวเลขเดียวกันแล้วนับยอดผิดตลอดไป)
-- ============================================================
do $$
declare v_src uuid; v_ref text;
begin
  v_src := pg_temp.post(pg_temp.entry('inc.rent', 'K2 ตั้งค้างรับค่าเช่า 9,000',
    jsonb_build_array(
      pg_temp.ln('1200', 9000, 0, 'none', null, '00000000-0000-0000-0000-00000004a001'),
      pg_temp.ln('4200', 0, 9000, 'none', null, '00000000-0000-0000-0000-00000004a001')),
    null));
  v_ref := v_src::text || '-clr-1';

  perform pg_temp.post(pg_temp.entry('inv.collect_rent', 'K2 ล้าง 1,000 ครั้งที่หนึ่ง',
    jsonb_build_array(
      pg_temp.ln('1100', 1000, 0, 'operating', '00000000-0000-0000-0000-00000004b001'),
      pg_temp.ln('1200', 0, 1000, 'operating', null, '00000000-0000-0000-0000-00000004a001')),
    '2026-10-31', v_ref));

  -- ยอดรวม 2,000 ยังไม่เกิน 9,000 → ตัวที่ต้องปฏิเสธคือ index ของเลขอ้างอิง
  perform pg_temp.must_fail_like('K2b เลขอ้างอิงเดิมซ้ำ',
    format($q$ select pg_temp.post(pg_temp.entry('inv.collect_rent', 'K2b ล้าง 1,000 ด้วยเลขเดิม',
          jsonb_build_array(
            pg_temp.ln('1100', 1000, 0, 'operating', '00000000-0000-0000-0000-00000004b001'),
            pg_temp.ln('1200', 0, 1000, 'operating', null, '00000000-0000-0000-0000-00000004a001')),
          '2026-10-31', %L)) $q$, v_ref),
    'transactions_clearing_ref_once');

  raise notice 'ok K2 · เลขอ้างอิงการล้างเดิมซ้ำถูกปฏิเสธที่ index (ถึงยอดรวมจะยังไม่เกิน) — ประวัติการล้างจึงมีใบละหนึ่งแถวเสมอ';
end $$;

-- ============================================================
-- K3 · **รายการข้ามผู้ถือยังลงได้ปกติ** — ข้อนี้สำคัญเท่าข้อ K1
--
-- `source_ref` อยู่ที่ระดับ payload → สองขาของใบข้ามผู้ถือได้ค่าเดียวกัน
-- ถ้า index เป็น unique บน `source_ref` เดี่ยว รายการข้ามผู้ถือจะลงไม่ได้ทั้งหมด
-- เคสนี้ลองทั้งสองแบบ: source_ref ปกติ และ **source_ref ที่มีรูปของเลขล้าง**
-- (กรณีที่แย่ที่สุดที่ index ยังต้องยอม)
-- ============================================================
do $$
declare v_src uuid; v_out jsonb; v_ids int;
begin
  -- ต้นทางของ K3 มีไว้ให้เลขอ้างอิงรูปใบล้างชี้ไปที่ของจริง (ด่านปฏิเสธเลขที่ชี้ไปที่ว่าง)
  v_src := pg_temp.post(pg_temp.entry('inc.rent', 'K3 ตั้งค้างรับค่าเช่า 4,000',
    jsonb_build_array(
      pg_temp.ln('1200', 4000, 0, 'none', null, '00000000-0000-0000-0000-00000004a001'),
      pg_temp.ln('4200', 0, 4000, 'none', null, '00000000-0000-0000-0000-00000004a001')),
    null));

  for v_ids in 1..2 loop
    v_out := sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code', 'trf.internal',
      'doc_date', '2026-10-31',
      'cash_date', '2026-10-31',
      'memo', 'K3 โอนข้ามผู้ถือ ครั้งที่ ' || v_ids,
      -- ครั้งที่ 1 เลขปกติ · ครั้งที่ 2 เลข **รูปเดียวกับใบล้าง** (กรณีที่แย่ที่สุด)
      'source_ref', case when v_ids = 1 then 'K3-TRANSFER-' || v_ids
                         else v_src::text || '-clr-90' end,
      'transactions', jsonb_build_array(
        jsonb_build_object(
          'owner_id', pg_temp.owner(),
          'counter_owner_id', pg_temp.owner('SUTEE'),
          'intercompany_nature', 'loan',
          'lines', jsonb_build_array(
            pg_temp.ln('1310', 2000, 0, 'investing'),
            pg_temp.ln('1100', 0, 2000, 'investing', '00000000-0000-0000-0000-00000004b001'))),
        jsonb_build_object(
          'owner_id', pg_temp.owner('SUTEE'),
          'counter_owner_id', pg_temp.owner(),
          'intercompany_nature', 'loan',
          'lines', jsonb_build_array(
            pg_temp.ln('1100', 2000, 0, 'financing', '00000000-0000-0000-0000-00000004b002'),
            pg_temp.ln('2310', 0, 2000, 'financing'))))));

    if jsonb_array_length(v_out -> 'transaction_ids') <> 2 then
      raise exception 'FAIL: K3 — ใบข้ามผู้ถือครั้งที่ % ต้องได้สอง transaction แต่ได้ %',
        v_ids, jsonb_array_length(v_out -> 'transaction_ids');
    end if;
  end loop;

  raise notice 'ok K3 · รายการข้ามผู้ถือลงได้ครบสองขาทั้งกรณี source_ref ปกติและกรณีที่เลขมีรูปของใบล้าง (index มี owner_id ในคีย์จึงไม่ฆ่าของเดิม)';
end $$;

-- ============================================================
-- K4 · **กลับรายการใบล้างยังทำได้ปกติ** แม้อ้างเลขอ้างอิงเดิม
--      และยอดค้างต้องกลับมาให้ล้างใหม่ได้ (ไม่ใช่ค้างไว้ว่าล้างแล้ว)
-- ============================================================
do $$
declare v_src uuid; v_clr uuid; v_ref text;
begin
  v_src := pg_temp.post(pg_temp.entry('inc.rent', 'K4 ตั้งค้างรับค่าเช่า 8,000',
    jsonb_build_array(
      pg_temp.ln('1200', 8000, 0, 'none', null, '00000000-0000-0000-0000-00000004a001'),
      pg_temp.ln('4200', 0, 8000, 'none', null, '00000000-0000-0000-0000-00000004a001')),
    null));
  v_ref := v_src::text || '-clr-1';

  v_clr := pg_temp.post(pg_temp.entry('inv.collect_rent', 'K4 ล้าง 8,000 ทั้งก้อน',
    jsonb_build_array(
      pg_temp.ln('1100', 8000, 0, 'operating', '00000000-0000-0000-0000-00000004b001'),
      pg_temp.ln('1200', 0, 8000, 'operating', null, '00000000-0000-0000-0000-00000004a001')),
    '2026-10-31', v_ref));

  -- ใบกลับรายการ: ภาพกระจกของใบล้าง · **อ้างเลขอ้างอิงเดิม** (เส้นทางในอนาคตจะทำแบบนี้)
  perform pg_temp.must_pass('K4b กลับรายการใบล้างที่อ้างเลขเดิม',
    format($q$ select pg_temp.post(pg_temp.entry('inv.collect_rent', 'K4b กลับรายการใบล้าง 8,000',
          jsonb_build_array(
            pg_temp.ln('1200', 8000, 0, 'operating', null, '00000000-0000-0000-0000-00000004a001'),
            pg_temp.ln('1100', 0, 8000, 'operating', '00000000-0000-0000-0000-00000004b001')),
          '2026-10-31', %L, 'reverse', %L)) $q$, v_ref, v_clr));

  -- ล้างใหม่ได้เต็มจำนวน เพราะใบเดิมถูกกลับรายการแล้ว (เลขใหม่ · ใบเดิมยังอยู่ในสมุด)
  perform pg_temp.must_pass('K4c ล้างใหม่หลังกลับรายการ',
    format($q$ select pg_temp.post(pg_temp.entry('inv.collect_rent', 'K4c ล้างใหม่ 8,000',
          jsonb_build_array(
            pg_temp.ln('1100', 8000, 0, 'operating', '00000000-0000-0000-0000-00000004b001'),
            pg_temp.ln('1200', 0, 8000, 'operating', null, '00000000-0000-0000-0000-00000004a001')),
          '2026-10-31', %L)) $q$, v_src::text || '-clr-2'));

  raise notice 'ok K4 · กลับรายการใบล้างทำได้แม้อ้างเลขเดิม (index ยกเว้นใบกลับรายการ · ด่านยอดหักกลบให้) และล้างใหม่เต็มจำนวนได้';
end $$;

-- ============================================================
-- K5 · `source_ref` รูปอื่น (เลขแบตช์/ชื่อไฟล์นำเข้า) **ซ้ำได้**
--      index ต้องไม่ไปบังคับความหมายกับช่องข้อความอิสระที่ยังไม่มีสัญญา
-- ============================================================
do $$
begin
  perform pg_temp.post(pg_temp.entry('inc.rent', 'K5 ค่าเช่าใบที่หนึ่งของแบตช์',
    jsonb_build_array(
      pg_temp.ln('1100', 1500, 0, 'operating', '00000000-0000-0000-0000-00000004b001'),
      pg_temp.ln('4200', 0, 1500, 'operating', null, '00000000-0000-0000-0000-00000004a001')),
    '2026-10-31', 'IMPORT-2026-10-SHEET1'));
  perform pg_temp.must_pass('K5b เลขแบตช์เดิมซ้ำได้',
    $q$ select pg_temp.post(pg_temp.entry('inc.rent', 'K5 ค่าเช่าใบที่สองของแบตช์',
          jsonb_build_array(
            pg_temp.ln('1100', 2500, 0, 'operating', '00000000-0000-0000-0000-00000004b001'),
            pg_temp.ln('4200', 0, 2500, 'operating', null, '00000000-0000-0000-0000-00000004a001')),
          '2026-10-31', 'IMPORT-2026-10-SHEET1')) $q$);
  raise notice 'ok K5 · source_ref รูปอื่นซ้ำได้ (ตัวนำเข้า/automation ในอนาคตไม่พัง) — index คุมเฉพาะรูปของเลขอ้างอิงการล้าง';
end $$;

-- ============================================================
-- K6 · ชี้ `source_ref` ของใบที่ post แล้วไปที่ต้นทางอื่น → ปฏิเสธ
--      (ล้างเกินโดยไม่แตะบรรทัดเลย — ด่านฝั่งบรรทัดมองไม่เห็น)
-- ============================================================
do $$
declare v_src uuid; v_other uuid; v_clr uuid;
begin
  -- ต้นทางเล็ก 3,000 แล้วล้างครบ
  v_src := pg_temp.post(pg_temp.entry('inc.rent', 'K6 ตั้งค้างรับค่าเช่า 3,000',
    jsonb_build_array(
      pg_temp.ln('1200', 3000, 0, 'none', null, '00000000-0000-0000-0000-00000004a001'),
      pg_temp.ln('4200', 0, 3000, 'none', null, '00000000-0000-0000-0000-00000004a001')),
    null));
  v_clr := pg_temp.post(pg_temp.entry('inv.collect_rent', 'K6 ล้าง 3,000 ครบ',
    jsonb_build_array(
      pg_temp.ln('1100', 3000, 0, 'operating', '00000000-0000-0000-0000-00000004b001'),
      pg_temp.ln('1200', 0, 3000, 'operating', null, '00000000-0000-0000-0000-00000004a001')),
    '2026-10-31', v_src::text || '-clr-1'));

  -- ต้นทางอีกใบที่ล้างครบแล้ว (K1) — เอาใบล้างของ K6 ไปชี้ทับ = ยอดรวมของ K1 เกิน
  select t.id into v_other from sri_os.transactions t
   where t.memo = 'K1 ตั้งค้างรับค่าเช่า 12,000' limit 1;
  if v_other is null then
    raise exception 'FAIL: K6 — หา transaction ต้นทางของ K1 ไม่เจอ เทสต์นี้จะไม่ได้ตรวจอะไร';
  end if;

  perform pg_temp.must_fail_like('K6b ชี้ source_ref ไปต้นทางที่ล้างครบแล้ว',
    format($q$ update sri_os.transactions set source_ref = %L where id = %L $q$,
           v_other::text || '-clr-7', v_clr),
    'ล้างยอดค้างเกิน');

  -- และชี้ไปที่เลขอ้างอิงที่ไม่มีต้นทางอยู่จริง ก็ต้องไม่ได้
  perform pg_temp.must_fail_like('K6c ชี้ไปต้นทางที่ไม่มีอยู่',
    format($q$ update sri_os.transactions set source_ref = %L where id = %L $q$,
           '00000000-0000-0000-0000-0000000000ff-clr-1', v_clr),
    'ไม่มีรายการต้นทาง');

  raise notice 'ok K6 · แก้ source_ref ของใบที่ post แล้วให้ไปล้างต้นทางอื่นถูกปฏิเสธ (ทั้งกรณีต้นทางเต็มและกรณีต้นทางไม่มีอยู่)';
end $$;

-- ============================================================
-- K7 · **MUTATION** — ถอด index + ด่านยอดรวมออก แล้ววัดว่า "ล้างเกิน" สำเร็จจริง
--
-- ถ้าเคสนี้ไม่แดง แปลว่าเทสต์ทั้งไฟล์ไม่ได้พิสูจน์ว่าการแก้มีผล
-- ทำบน savepoint → rollback แล้วทั้ง index ทั้ง trigger กลับมาเอง
-- ============================================================
savepoint before_mutation;

drop trigger trg_assert_clearing_not_over on sri_os.transaction_lines;
drop trigger trg_assert_clearing_not_over_txn on sri_os.transactions;
drop index sri_os.transactions_clearing_ref_once;

do $$
declare v_src uuid; v_before numeric; v_after numeric;
begin
  -- ของค้างก้อนใหญ่ของผู้ถือเดียวกัน → ด่านเก่า (ยอดรวมต่อผู้ถือ) เงียบ
  -- เคสนี้จึงวัด **ผลของการถอดด่านใหม่** ไม่ใช่วัดด่านเก่า
  perform pg_temp.post(pg_temp.entry('inc.rent', 'K7 ตั้งค้างรับก้อนใหญ่ 80,000 (mutation)',
    jsonb_build_array(
      pg_temp.ln('1200', 80000, 0, 'none', null, '00000000-0000-0000-0000-00000004a001'),
      pg_temp.ln('4200', 0, 80000, 'none', null, '00000000-0000-0000-0000-00000004a001')),
    null));

  v_src := pg_temp.post(pg_temp.entry('inc.rent', 'K7 ตั้งค้างรับค่าเช่า 12,000 (mutation)',
    jsonb_build_array(
      pg_temp.ln('1200', 12000, 0, 'none', null, '00000000-0000-0000-0000-00000004a001'),
      pg_temp.ln('4200', 0, 12000, 'none', null, '00000000-0000-0000-0000-00000004a001')),
    null));
  v_before := pg_temp.src_balance(v_src);

  -- สองคำขอที่ **ต่างยอดกัน** บนของค้าง 12,000 — ฉากเดียวกับที่ผู้ตรวจวัด
  perform pg_temp.post(pg_temp.entry('inv.collect_rent', 'K7 ล้าง 7,000 (mutation)',
    jsonb_build_array(
      pg_temp.ln('1100', 7000, 0, 'operating', '00000000-0000-0000-0000-00000004b001'),
      pg_temp.ln('1200', 0, 7000, 'operating', null, '00000000-0000-0000-0000-00000004a001')),
    '2026-10-31', v_src::text || '-clr-1'));
  perform pg_temp.post(pg_temp.entry('inv.collect_rent', 'K7 ล้าง 6,000 (mutation)',
    jsonb_build_array(
      pg_temp.ln('1100', 6000, 0, 'operating', '00000000-0000-0000-0000-00000004b001'),
      pg_temp.ln('1200', 0, 6000, 'operating', null, '00000000-0000-0000-0000-00000004a001')),
    '2026-10-31', v_src::text || '-clr-2'));

  v_after := pg_temp.src_balance(v_src);
  if v_before <> 12000 then
    raise exception 'FAIL: K7 — ยอดค้างตั้งต้นควรเป็น 12,000 แต่ได้ %', v_before;
  end if;
  if v_after <> -1000 then
    raise exception 'FAIL: K7 — ถอดด่านแล้วควรล้างไปได้ 13,000 → ยอดค้างของใบนี้ติดลบ 1,000 แต่ได้ % · เคส mutation นี้ไม่ได้พิสูจน์อะไร',
      v_after;
  end if;

  -- และเลขอ้างอิงซ้ำก็ลงได้ (ประวัติการล้างพัง)
  perform pg_temp.post(pg_temp.entry('inv.collect_rent', 'K7 ล้างซ้ำเลขเดิม (mutation)',
    jsonb_build_array(
      pg_temp.ln('1100', 500, 0, 'operating', '00000000-0000-0000-0000-00000004b001'),
      pg_temp.ln('1200', 0, 500, 'operating', null, '00000000-0000-0000-0000-00000004a001')),
    '2026-10-31', v_src::text || '-clr-1'));

  raise notice 'ok K7 · MUTATION · ถอด index + ด่าน → ล้าง 7,000 + 6,000 บนของค้าง 12,000 สำเร็จทั้งคู่ = ล้างไป 13,000 · ลูกหนี้ของต้นทางนั้นติดลบ 1,000 · และเลขอ้างอิงซ้ำลงได้อีกใบ (ประวัติพัง)';
end $$;

rollback to savepoint before_mutation;

do $$
begin
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.transaction_lines'::regclass
                    and g.tgname = 'trg_assert_clearing_not_over' and not g.tgisinternal)
     or not exists (select 1 from pg_class i join pg_namespace ns on ns.oid = i.relnamespace
                     where ns.nspname = 'sri_os' and i.relname = 'transactions_clearing_ref_once') then
    raise exception 'FAIL: K7b — ด่านไม่กลับมาหลัง rollback (mutation ทิ้งสภาพค้างไว้)';
  end if;
  if exists (select 1 from sri_os.transactions t where t.memo like 'K7 %') then
    raise exception 'FAIL: K7b — ใบของ mutation ยังค้างอยู่ในสมุดหลัง rollback';
  end if;
  raise notice 'ok K7b · index และ trigger กลับมาหลัง rollback · ไม่มีใบของ mutation ค้างในสมุด';
end $$;

-- ============================================================
-- K8..K11 · **รูที่ผู้ตรวจ/ผมไล่เจอเอง (D-115)** — ด่านรุ่น 20261025000003
--   ทำงาน **เฉพาะเมื่อผู้เรียกส่ง `source_ref` รูปใบล้าง** ซึ่งเป็นข้อความที่
--   ผู้เรียกตั้งเอง → **ไม่ส่งก็ไม่ถูกตรวจและไม่ถูกนับ** = ล้างเกินได้เหมือนเดิม
--   เหลือแต่ด่านหยาบระดับผู้ถือ (ซึ่ง K1e ยืนยันแล้วว่าเงียบเมื่อมีของค้างก้อนอื่นคลุม)
--
--   ด่านใหม่ต้องตัดสินจาก **ของที่ผู้เรียกเปลี่ยนไม่ได้**:
--     ใครคือ "ใบที่ลดบัญชีพัก" → อ่านจากผังบัญชี + `txn_types.accrual_coa_code`
--     ชี้ไปต้นทางไหน → คอลัมน์ **FK `clears_id`** ที่ประตูเติมให้ และต้องชี้ไป
--     ใบที่มียอดค้างจริงของผู้ถือเดียวกัน · ไม่มีลิงก์ = **ปฏิเสธ** ไม่ใช่ข้ามการตรวจ
-- ============================================================

-- ------------------------------------------------------------
-- K8 · ล้าง 7,000 (มี ref) + 6,000 (**ไม่ส่ง ref**) บนของค้าง 12,000
--      วัดก่อนแก้: ใบที่สองผ่าน → ล้างไป 13,000 · ลูกหนี้ของต้นทางนั้น **−1,000**
-- ------------------------------------------------------------
do $$
declare v_src uuid; v_other uuid;
begin
  v_other := pg_temp.post(pg_temp.entry('inc.rent', 'K8 ของค้างก้อนอื่น 50,000',
    jsonb_build_array(
      pg_temp.ln('1200', 50000, 0, 'none', null, '00000000-0000-0000-0000-00000004a001'),
      pg_temp.ln('4200', 0, 50000, 'none', null, '00000000-0000-0000-0000-00000004a001')),
    null));
  v_src := pg_temp.post(pg_temp.entry('inc.rent', 'K8 ตั้งค้างรับ 12,000',
    jsonb_build_array(
      pg_temp.ln('1200', 12000, 0, 'none', null, '00000000-0000-0000-0000-00000004a001'),
      pg_temp.ln('4200', 0, 12000, 'none', null, '00000000-0000-0000-0000-00000004a001')),
    null));

  perform pg_temp.post(pg_temp.entry('inv.collect_rent', 'K8 ล้าง 7,000 (มีเลขอ้างอิง)',
    jsonb_build_array(
      pg_temp.ln('1100', 7000, 0, 'operating', '00000000-0000-0000-0000-00000004b001'),
      pg_temp.ln('1200', 0, 7000, 'operating', null, '00000000-0000-0000-0000-00000004a001')),
    '2026-10-31', v_src::text || '-clr-1'));

  -- **ไม่ส่ง source_ref เลย** — ก่อนแก้ ด่านไม่ยิงและยอดนี้ไม่ถูกนับ
  perform pg_temp.must_fail_like('K8b ล้างโดยไม่ส่งเลขอ้างอิง',
    $q$ select pg_temp.post(pg_temp.entry('inv.collect_rent', 'K8b ล้าง 6,000 ไม่ส่งเลขอ้างอิง',
          jsonb_build_array(
            pg_temp.ln('1100', 6000, 0, 'operating', '00000000-0000-0000-0000-00000004b001'),
            pg_temp.ln('1200', 0, 6000, 'operating', null, '00000000-0000-0000-0000-00000004a001')),
          '2026-10-31')) $q$,
    'ต้องชี้ไปที่รายการต้นทางที่มียอดค้างจริง');

  if pg_temp.src_balance(v_src) <> 5000 then
    raise exception 'FAIL: K8b — ใบที่ถูกปฏิเสธทิ้งผลไว้ (ยอดค้างของต้นทาง %)', pg_temp.src_balance(v_src);
  end if;

  -- ของที่ถูกต้องยังทำได้ (ด่านห้ามแน่นเกิน)
  perform pg_temp.must_pass('K8c ล้างส่วนที่เหลือพอดีโดยมีเลขอ้างอิง',
    format($q$ select pg_temp.post(pg_temp.entry('inv.collect_rent', 'K8c ล้าง 5,000 ส่วนที่เหลือ',
          jsonb_build_array(
            pg_temp.ln('1100', 5000, 0, 'operating', '00000000-0000-0000-0000-00000004b001'),
            pg_temp.ln('1200', 0, 5000, 'operating', null, '00000000-0000-0000-0000-00000004a001')),
          '2026-10-31', %L)) $q$, v_src::text || '-clr-2'));
  if pg_temp.src_balance(v_src) <> 0 or pg_temp.src_balance(v_other) <> 50000 then
    raise exception 'FAIL: K8c — ยอดหลังล้างครบผิด (ต้นทาง % · ก้อนอื่น %)',
      pg_temp.src_balance(v_src), pg_temp.src_balance(v_other);
  end if;
  raise notice 'ok K8 · ใบที่ลดบัญชีพักโดยไม่มีลิงก์ไปต้นทางถูกปฏิเสธ (ก่อนแก้: ผ่าน → ล้าง 13,000 บนของค้าง 12,000 · ลูกหนี้ติดลบ 1,000)';
end $$;

-- ------------------------------------------------------------
-- K9 · **ไล่ทุกรูปของลิงก์ที่คิดออก** — ทุกรูปต้องถูกปฏิเสธด้วย
--      **เหตุผลเดียวกัน** ไม่ใช่รอดไปรูปใดรูปหนึ่ง (รูปเดียวกับที่ทำกับขา 3410)
-- ------------------------------------------------------------
do $$
declare
  v_src   uuid;
  v_other uuid;
  v_refs  text[];
  v_ref   text;
  v_n     int := 0;
begin
  v_other := pg_temp.post(pg_temp.entry('inc.rent', 'K9 ของค้างก้อนอื่น 50,000',
    jsonb_build_array(
      pg_temp.ln('1200', 50000, 0, 'none', null, '00000000-0000-0000-0000-00000004a001'),
      pg_temp.ln('4200', 0, 50000, 'none', null, '00000000-0000-0000-0000-00000004a001')),
    null));
  v_src := pg_temp.post(pg_temp.entry('inc.rent', 'K9 ตั้งค้างรับ 3,000',
    jsonb_build_array(
      pg_temp.ln('1200', 3000, 0, 'none', null, '00000000-0000-0000-0000-00000004a001'),
      pg_temp.ln('4200', 0, 3000, 'none', null, '00000000-0000-0000-0000-00000004a001')),
    null));

  v_refs := array[
    'ล้างงวด ต.ค. 2569',                                        -- ข้อความอิสระ (ไม่ใช่รูปใบล้าง)
    '00000000-0000-0000-0000-0000000000ff-clr-1',               -- ชี้ไปใบที่ไม่มีอยู่
    v_other::text,                                              -- uuid เปล่าๆ ไม่มีรูป -clr-
    v_src::text || '-clr'                                        -- รูปขาดเลขงวดท้าย
    -- หมายเหตุ: ตัวพิมพ์ใหญ่ (`-CLR-1`) **ใช้ได้โดยตั้งใจ** — fn_clearing_ref_source
    -- จับแบบไม่สนตัวพิมพ์ จึงไม่ใช่รูปที่ต้องปฏิเสธ (เคยเขียนเป็นเคสนี้แล้วพบว่าผ่าน)
  ];
  foreach v_ref in array v_refs loop
    v_n := v_n + 1;
    perform pg_temp.must_fail_like('K9 ลิงก์รูปที่ ' || v_n,
      format($q$ select pg_temp.post(pg_temp.entry('inv.collect_rent', 'K9 รูปที่ %s',
            jsonb_build_array(
              pg_temp.ln('1100', 1000, 0, 'operating', '00000000-0000-0000-0000-00000004b001'),
              pg_temp.ln('1200', 0, 1000, 'operating', null, '00000000-0000-0000-0000-00000004a001')),
            '2026-10-31', %L)) $q$, v_n, v_ref),
      'ต้องชี้ไปที่รายการต้นทางที่มียอดค้างจริง');
  end loop;
  if v_n <> 4 then
    raise exception 'FAIL: K9 — ลูปว่าง/ไม่ครบ (%)', v_n;
  end if;

  -- และลิงก์ที่ชี้ไปใบที่ **ไม่ได้ตั้งค้าง** (ใบเงินสดธรรมดา) ก็ไม่ได้
  declare v_cash uuid;
  begin
    v_cash := pg_temp.post(pg_temp.entry('inc.rent', 'K9 รับเงินสดเลย ไม่ได้ตั้งค้าง',
      jsonb_build_array(
        pg_temp.ln('1100', 900, 0, 'operating', '00000000-0000-0000-0000-00000004b001'),
        pg_temp.ln('4200', 0, 900, 'operating', null, '00000000-0000-0000-0000-00000004a001'))));
    perform pg_temp.must_fail_like('K9b ลิงก์ไปใบที่ไม่มียอดค้าง',
      format($q$ select pg_temp.post(pg_temp.entry('inv.collect_rent', 'K9b ล้างใบที่ไม่ได้ตั้งค้าง',
            jsonb_build_array(
              pg_temp.ln('1100', 500, 0, 'operating', '00000000-0000-0000-0000-00000004b001'),
              pg_temp.ln('1200', 0, 500, 'operating', null, '00000000-0000-0000-0000-00000004a001')),
            '2026-10-31', %L)) $q$, v_cash::text || '-clr-1'),
      'ต้องชี้ไปที่รายการต้นทางที่มียอดค้างจริง');
  end;

  raise notice 'ok K9 · ลิงก์ทั้ง 5 รูป (ข้อความอิสระ · ใบที่ไม่มีอยู่ · uuid ไม่มีรูป -clr- · รูปเพี้ยน · ใบที่ไม่มียอดค้าง) ถูกปฏิเสธด้วยเหตุผลเดียวกัน';
end $$;

-- ------------------------------------------------------------
-- K10 · ลิงก์ของผู้ถือคนอื่น → ปฏิเสธ
--       (ลดลูกหนี้ของเรา แต่ไปนับกับยอดค้างของคนอื่น = ลูกหนี้ของเราติดลบเงียบๆ)
-- ------------------------------------------------------------
do $$
declare v_theirs uuid;
begin
  -- ของค้างของสุธี (ลงเป็นใบของสุธีเอง)
  v_theirs := ((sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code', 'inc.rent',
      'doc_date', '2026-10-31',
      'memo', 'K10 ของค้างของสุธี 9,000',
      'contact_id', '00000000-0000-0000-0000-00000004c001',
      'attachments', jsonb_build_array('หลักฐาน.pdf'),
      'transactions', jsonb_build_array(jsonb_build_object(
        'owner_id', pg_temp.owner('SUTEE'),
        'lines', jsonb_build_array(
          pg_temp.ln('1200', 9000, 0, 'none'),
          pg_temp.ln('4200', 0, 9000, 'none'))))
    )) -> 'transaction_ids') ->> 0)::uuid;

  perform pg_temp.must_fail_like('K10 ลิงก์ไปของค้างของผู้ถืออื่น',
    format($q$ select pg_temp.post(pg_temp.entry('inv.collect_rent', 'K10 ล้างของค้างคนอื่น',
          jsonb_build_array(
            pg_temp.ln('1100', 1000, 0, 'operating', '00000000-0000-0000-0000-00000004b001'),
            pg_temp.ln('1200', 0, 1000, 'operating', null, '00000000-0000-0000-0000-00000004a001')),
          '2026-10-31', %L)) $q$, v_theirs::text || '-clr-1'),
    'ต้องชี้ไปที่รายการต้นทางที่มียอดค้างจริง');
  raise notice 'ok K10 · ลิงก์ข้ามผู้ถือถูกปฏิเสธ — ยอดค้างของคนอื่นเอามาคุมการลดลูกหนี้ของเราไม่ได้';
end $$;

-- ------------------------------------------------------------
-- K11 · **ตัดหนี้สูญก็ลดบัญชีพัก** → ต้องมีลิงก์และเกินยอดค้างไม่ได้
--       (หมวด `adj.writeoff_*` ไม่ใช่ "ใบล้าง" ในสายตาด่านเก่าเลย จึงหลุดทั้งหมด)
-- ------------------------------------------------------------
do $$
declare v_src uuid;
begin
  v_src := pg_temp.post(pg_temp.entry('inc.rent', 'K11 ตั้งค้างรับ 4,000',
    jsonb_build_array(
      pg_temp.ln('1200', 4000, 0, 'none', null, '00000000-0000-0000-0000-00000004a001'),
      pg_temp.ln('4200', 0, 4000, 'none', null, '00000000-0000-0000-0000-00000004a001')),
    null));

  -- ตั้งค่าเผื่อหนี้สงสัยจะสูญก่อน — ด่านเดิม (ค่าเผื่อติดลบไม่ได้) บังคับไว้
  -- ถ้าไม่ตั้ง เคสนี้จะถูกปฏิเสธด้วยเหตุอื่นและ **ไม่ได้ทดสอบด่านที่เรากำลังทำ**
  perform pg_temp.post(pg_temp.entry('adj.doubtful', 'K11 ตั้งค่าเผื่อ 6,000',
    jsonb_build_array(
      pg_temp.ln('5920', 6000, 0, 'none'),
      pg_temp.ln('1290', 0, 6000, 'none')),
    null));

  perform pg_temp.must_fail_like('K11 ตัดหนี้สูญโดยไม่มีลิงก์',
    $q$ select pg_temp.post(pg_temp.entry('adj.writeoff_rent', 'K11 ตัดหนี้สูญ 4,000 ไม่มีลิงก์',
          jsonb_build_array(
            pg_temp.ln('1290', 4000, 0, 'none'),
            pg_temp.ln('1200', 0, 4000, 'none', null, '00000000-0000-0000-0000-00000004a001')),
          null)) $q$,
    'ต้องชี้ไปที่รายการต้นทางที่มียอดค้างจริง');

  perform pg_temp.must_fail_like('K11b ตัดหนี้สูญเกินยอดค้าง',
    format($q$ select pg_temp.post(pg_temp.entry('adj.writeoff_rent', 'K11b ตัดหนี้สูญ 5,000 เกินยอด',
          jsonb_build_array(
            pg_temp.ln('1290', 5000, 0, 'none'),
            pg_temp.ln('1200', 0, 5000, 'none', null, '00000000-0000-0000-0000-00000004a001')),
          null, %L)) $q$, v_src::text || '-clr-1'),
    'ล้างยอดค้างเกิน');

  perform pg_temp.must_pass('K11c ตัดหนี้สูญพอดีตามยอดค้าง',
    format($q$ select pg_temp.post(pg_temp.entry('adj.writeoff_rent', 'K11c ตัดหนี้สูญ 4,000 พอดี',
          jsonb_build_array(
            pg_temp.ln('1290', 4000, 0, 'none'),
            pg_temp.ln('1200', 0, 4000, 'none', null, '00000000-0000-0000-0000-00000004a001')),
          null, %L)) $q$, v_src::text || '-clr-1'));
  if pg_temp.src_balance(v_src) <> 0 then
    raise exception 'FAIL: K11c — ตัดหนี้สูญครบแล้วยอดค้างต้องเป็น 0 แต่ได้ %', pg_temp.src_balance(v_src);
  end if;
  raise notice 'ok K11 · ตัดหนี้สูญถูกคุมด้วยด่านเดียวกัน (ไม่มีลิงก์ไม่ได้ · เกินยอดค้างไม่ได้ · พอดีได้) — ด่านเก่าไม่เคยเห็นหมวดนี้เลยเพราะไม่ได้ส่งเลขอ้างอิงรูปใบล้าง';
end $$;

-- ------------------------------------------------------------
-- K12 · **ห้ามกันแน่นเกิน** · ของค้างเปิดอยู่ใบเดียว → ลงใบรับชำระเองได้
--        โดยไม่ต้องมีเลขอ้างอิง (สมุดบอกได้เองว่าล้างของใบไหน)
--        แต่ **เกินยอดของใบนั้นก็ยังไม่ได้** — ด่านคุมด้วยยอดค้างของต้นทางเสมอ
--
--        นี่คือเส้นทางที่แอปใช้อยู่จริง (ฟอร์มปกติยังไม่มีช่องเลือกใบค้าง)
--        ถ้าปิดทางนี้ = ปิดฟีเจอร์ที่ถูกต้อง (บทเรียนข้อ 7)
-- ------------------------------------------------------------
do $$
declare v_src uuid; v_owner uuid;
begin
  -- ใช้ผู้ถือที่ **ยังไม่มีของค้างในไฟล์นี้เลย** เพื่อให้ฉาก "เปิดอยู่ใบเดียว" เป็นจริง
  -- (สุธีมีของค้างจากเคสก่อนๆ อยู่แล้ว ถ้าใช้สุธีเคสนี้จะวัดอย่างอื่น)
  v_owner := pg_temp.owner('BENJAPORN');
  insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
  values ('00000000-0000-0000-0000-00000004b003', v_owner, 'SCB', 'เบ็ญจพร',
          'เบ็ญจพร - SCB (ล้างของค้าง)')
  on conflict (id) do nothing;
  v_src := ((sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code', 'inc.rent',
      'doc_date', '2026-10-31',
      'memo', 'K12 ตั้งค้างรับของเบ็ญจพร 9,000',
      'contact_id', '00000000-0000-0000-0000-00000004c001',
      'attachments', jsonb_build_array('หลักฐาน.pdf'),
      'transactions', jsonb_build_array(jsonb_build_object(
        'owner_id', v_owner,
        'lines', jsonb_build_array(
          pg_temp.ln('1200', 9000, 0, 'none'),
          pg_temp.ln('4200', 0, 9000, 'none'))))
    )) -> 'transaction_ids') ->> 0)::uuid;

  perform pg_temp.must_pass('K12 ลงใบรับชำระเองโดยไม่มีเลขอ้างอิง (ของค้างเปิดอยู่ใบเดียว)',
    $q$ select sri_os.fn_post_entry(jsonb_build_object(
          'txn_type_code', 'inv.collect_rent',
          'doc_date', '2026-10-31', 'cash_date', '2026-10-31',
          'memo', 'K12 รับชำระเอง 6,000',
          'contact_id', '00000000-0000-0000-0000-00000004c001',
          'attachments', jsonb_build_array('หลักฐาน.pdf'),
          'transactions', jsonb_build_array(jsonb_build_object(
            'owner_id', pg_temp.owner('BENJAPORN'),
            'lines', jsonb_build_array(
              pg_temp.ln('1100', 6000, 0, 'operating', '00000000-0000-0000-0000-00000004b003'),
              pg_temp.ln('1200', 0, 6000, 'operating')))))) $q$);

  /**
   * เกินยอดของใบนั้น (6,000 + 4,000 > 9,000) → ต้องถูกปฏิเสธ แม้ไม่มีเลขอ้างอิง
   *
   * ฉากนี้ผู้ถือมีของค้างใบเดียว → "ต่อรายการต้นทาง" กับ "ต่อผู้ถือ" เป็นเรื่องเดียวกัน
   * ด่านเก่า (ลูกหนี้ติดลบต่อผู้ถือ) จึงพูดก่อน และนั่นถูกต้อง — ด่านต่อรายการต้นทาง
   * มีค่าตรงที่ **มีของค้างก้อนอื่นคลุมยอดรวมไว้** (K1/K8 คือเคสนั้น)
   */
  perform pg_temp.must_fail_like('K12b รับชำระเองเกินยอดค้างของใบเดียวที่เปิดอยู่',
    $q$ select sri_os.fn_post_entry(jsonb_build_object(
          'txn_type_code', 'inv.collect_rent',
          'doc_date', '2026-10-31', 'cash_date', '2026-10-31',
          'memo', 'K12b รับชำระเอง 4,000 เกินยอด',
          'contact_id', '00000000-0000-0000-0000-00000004c001',
          'attachments', jsonb_build_array('หลักฐาน.pdf'),
          'transactions', jsonb_build_array(jsonb_build_object(
            'owner_id', pg_temp.owner('BENJAPORN'),
            'lines', jsonb_build_array(
              pg_temp.ln('1100', 4000, 0, 'operating', '00000000-0000-0000-0000-00000004b003'),
              pg_temp.ln('1200', 0, 4000, 'operating')))))) $q$,
    'ติดลบ');

  -- และเมื่อ **มีของค้างใบที่สอง** เปิดขึ้นมา การลงเองโดยไม่ระบุก็ต้องถูกปฏิเสธทันที
  perform sri_os.fn_post_entry(jsonb_build_object(
      'txn_type_code', 'inc.rent',
      'doc_date', '2026-10-31',
      'memo', 'K12 ตั้งค้างรับของเบ็ญจพรใบที่สอง 5,000',
      'contact_id', '00000000-0000-0000-0000-00000004c001',
      'attachments', jsonb_build_array('หลักฐาน.pdf'),
      'transactions', jsonb_build_array(jsonb_build_object(
        'owner_id', v_owner,
        'lines', jsonb_build_array(
          pg_temp.ln('1200', 5000, 0, 'none'),
          pg_temp.ln('4200', 0, 5000, 'none'))))));

  perform pg_temp.must_fail_like('K12c มีของค้างสองใบแล้วลงเองโดยไม่ระบุ',
    $q$ select sri_os.fn_post_entry(jsonb_build_object(
          'txn_type_code', 'inv.collect_rent',
          'doc_date', '2026-10-31', 'cash_date', '2026-10-31',
          'memo', 'K12c รับชำระเอง 1,000 ตอนมีสองใบ',
          'contact_id', '00000000-0000-0000-0000-00000004c001',
          'attachments', jsonb_build_array('หลักฐาน.pdf'),
          'transactions', jsonb_build_array(jsonb_build_object(
            'owner_id', pg_temp.owner('BENJAPORN'),
            'lines', jsonb_build_array(
              pg_temp.ln('1100', 1000, 0, 'operating', '00000000-0000-0000-0000-00000004b003'),
              pg_temp.ln('1200', 0, 1000, 'operating')))))) $q$,
    'ต้องชี้ไปที่รายการต้นทางที่มียอดค้างจริง');

  raise notice 'ok K12 · ของค้างเปิดใบเดียว → ลงรับชำระเองได้โดยไม่มีเลขอ้างอิง (แต่เกินยอดไม่ได้) · เปิดสองใบ → ต้องระบุว่าล้างของใบไหน';
end $$;

do $$ begin raise notice '=== ล้างยอดค้างเกินไม่ได้ (ปิดจังหวะพร้อมกันที่ DB) ผ่านทั้งหมด ==='; end $$;

rollback;
