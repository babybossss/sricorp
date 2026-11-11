-- ============================================================
-- SRI OS · **อัปโหลดยอดตั้งต้นใหม่ = กลับรายการชุดเดิมแล้วลงชุดใหม่ ในธุรกรรมเดียว**
--
-- ลูกพี่จะอัปโหลดไฟล์ยอดตั้งต้นซ้ำเพื่อแก้ตัวเลข · **กฎเหล็กข้อ 1 ห้าม DELETE
-- รายการที่ post แล้ว** → ทางที่ถูกคือกลับรายการชุดเดิมแล้วลงชุดใหม่
--
-- ------------------------------------------------------------
-- **สามเรื่องที่ไฟล์นี้ทำให้เป็นจริง**
--
-- 1. *"ชุดเดิม" อ่านจากสมุด ไม่ใช่จากป้ายที่ผู้เรียกส่งมา* (D-115)
--    = ใบที่ `txn_types.group_code = 'opening'` ของผู้ถือนั้น ที่ **ยังไม่มีใบกลับ
--    รายการชี้มา** · ผู้เรียกส่งแค่ "เนื้อหาใหม่" ส่งรายการใบที่จะกลับไม่ได้เลย
--
-- 2. *อัปโหลดไฟล์เดิมซ้ำต้องไม่เกิดอะไรขึ้น* — เทียบ **ลายนิ้วมือของเนื้อหา**
--    ที่คำนวณจากสมุด (คู่บัญชี · ยอด · บัญชีธนาคาร · ทรัพย์ · วันตัดยอด + ทะเบียนล็อต)
--    กับลายนิ้วมือของไฟล์ใหม่ · เท่ากัน = **ไม่เขียนอะไรเลย**
--    ถ้า reverse+ลงใหม่ทุกครั้ง สมุดจะบวมด้วยใบที่หักกันเองเป็นคู่ และประวัติอ่านไม่รู้เรื่อง
--    (ไม่เก็บลายนิ้วมือไว้ในคอลัมน์ — คำนวณใหม่ทุกครั้ง · ยอดที่เก็บไว้คือสำเนา
--     ชุดที่สองที่เคลื่อนจากต้นฉบับได้เงียบๆ · D-113/D-115)
--
-- 3. *ธุรกรรมเดียว* — ทุกอย่างอยู่ในฟังก์ชันเดียว (`fn_reimport_opening`)
--    PL/pgSQL ไม่มี commit กลางทาง → error ที่ไหนก็ตามทำให้ **ทั้งคำสั่งย้อนกลับ**
--    จึงไม่มีจังหวะที่ยอดของผู้ถือเป็นศูนย์แล้วค้างอยู่อย่างนั้น
--    (ถ้าแยกเป็นหลายคำสั่งจากฝั่งแอป จังหวะนั้นมีจริง และถ้าไฟดับตรงนั้น
--     **ยอดตั้งต้นทั้งก้อนหาย โดยที่งบดุลยังดุล — ดุลที่ศูนย์**)
--
-- ------------------------------------------------------------
-- **ทะเบียนล็อตกลับรายการอย่างไร** (ตารางเป็น append-only)
--
-- ล็อตได้สองคอลัมน์ร่องรอย `reversed_by_txn_id` + `reversed_at` — **รูปเดียวกับ
-- `transactions.status='void'` + `voided_at/by`** ที่ระบบใช้อยู่ (ไม่ใช่ลบแถว และ
-- ไม่ใช่ล็อตจำนวนติดลบซึ่งจะพังทุก check ของจำนวน) · การตั้งค่านี้ถูกจำกัดสองชั้น:
--   (ก) เปลี่ยนได้ครั้งเดียว null → ค่า และห้ามแก้ฟิลด์อื่นพร้อมกัน
--   (ข) `reversed_by_txn_id` ต้องเป็นใบที่ **กลับรายการใบที่สร้างล็อตนั้นจริง**
--       (พิสูจน์จาก `transactions.reverses_id` ในสมุด ไม่ใช่เชื่อค่าที่ส่งมา)
-- ฟังก์ชันนับจำนวน/ต้นทุน (0008) ถูกเขียนทับให้ **ข้ามล็อตที่ถูกกลับรายการ**
--
-- ------------------------------------------------------------
-- **อัปโหลดใหม่หลังจากมีการขาย/เก็บเงินไปแล้ว → ปฏิเสธ** (ข้อ 5 ของบรีฟ)
--
-- เหตุผล: ยอดตั้งต้นเป็น **ต้นทุน/ยอดค้างที่รายการหลังจากนั้นอ้างไปแล้ว**
--   · ขายหุ้นไปแล้ว → กำไรที่บันทึกไว้คิดจากต้นทุนถัวเฉลี่ยของยอดตั้งต้นเดิม
--     ถ้าเปลี่ยนยอดตั้งต้นย้อนหลัง กำไรที่บันทึกไว้จะผิดโดยไม่มีใบไหนเปลี่ยน
--   · เก็บเงินลูกหนี้ยกมาไปแล้ว → กลับรายการยอดยกมาทำให้ลูกหนี้ติดลบ
-- ทางที่ถูกคือ **กลับรายการสิ่งที่อ้างมันก่อน** (ใบขาย/ใบรับชำระ) แล้วอัปโหลดใหม่
-- → ฟังก์ชันปฏิเสธพร้อมบอกว่าใบไหนอ้างอยู่ · เงียบแล้วปล่อยผ่านคือกำไรผิดเงียบๆ
--
-- ลำดับ: **หลัง 20261025000008_asset_lots.sql** (เขียนทับฟังก์ชันนับของไฟล์นั้น) ·
--   หลัง seed ที่มีประเภท `opening` · ก่อน `20261020000003_replay_end_state_guard.sql`
--   → วางต่อท้าย `20261025000008_asset_lots.sql`
--
-- idempotent: add column if not exists · create or replace function ·
--   drop trigger if exists ก่อน create · insert ... on conflict do update
--
-- ย้อนกลับ (rollback):
--   -- drop function if exists sri_os.fn_reimport_opening(uuid, jsonb);
--   -- drop function if exists sri_os.fn_opening_fingerprint(uuid), sri_os.fn_opening_set(uuid);
--   -- รัน 20261025000008_asset_lots.sql ซ้ำ (คืนฟังก์ชันนับรุ่นที่ไม่รู้จักการกลับรายการล็อต)
--   -- delete from sri_os.column_exposure where table_name = 'asset_lots'
--   --   and column_name in ('reversed_by_txn_id','reversed_at');
--   -- select sri_os.fn_apply_column_exposure();
--   -- alter table sri_os.asset_lots drop column if exists reversed_at, drop column if exists reversed_by_txn_id;
--   -- ย้อนแล้ว: อัปโหลดใหม่ต้องทำจากฝั่งแอปหลายคำสั่ง = มีจังหวะที่ยอดเป็นศูนย์
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 0 · pre-flight
-- ============================================================
do $$
begin
  if to_regclass('sri_os.asset_lots') is null
     or to_regprocedure('sri_os.fn_asset_units(uuid)') is null then
    raise exception 'ไม่มีทะเบียนล็อต → ต้องรัน 20261025000008_asset_lots.sql ก่อนไฟล์นี้';
  end if;
  if not exists (select 1 from sri_os.txn_types where group_code = 'opening') then
    raise exception 'ตารางกฎยังไม่มีประเภท "opening" → ต้องรัน seed ที่ generate จาก npm run sync:rules ก่อน (ไม่มีประเภทนี้ก็ไม่มียอดตั้งต้นให้จัดการ)';
  end if;
  if to_regprocedure('sri_os.fn_post_entry(jsonb)') is null then
    raise exception 'ไม่มีประตู fn_post_entry';
  end if;
end $$;

-- ============================================================
-- 1 · ร่องรอยการกลับรายการของล็อต (รูปเดียวกับ void ของ transactions)
-- ============================================================
alter table asset_lots
  add column if not exists reversed_by_txn_id uuid references transactions(id),
  add column if not exists reversed_at timestamptz;

comment on column asset_lots.reversed_by_txn_id is
  'ใบกลับรายการที่ทำให้ล็อตนี้เป็นโมฆะ (ต้องเป็นใบที่ reverses_id ชี้ไปใบที่สร้างล็อตนี้ · พิสูจน์จากสมุด) · null = ล็อตยังใช้อยู่ · ฟังก์ชันนับจำนวน/ต้นทุนข้ามล็อตที่มีค่านี้';

alter table asset_lots drop constraint if exists asset_lots_reversed_shape;
alter table asset_lots
  add constraint asset_lots_reversed_shape check (
    (reversed_by_txn_id is null and reversed_at is null)
    or (reversed_by_txn_id is not null and reversed_at is not null)
  );

create index if not exists asset_lots_active_idx on asset_lots (asset_id)
  where reversed_by_txn_id is null;

insert into column_exposure (table_name, column_name, exposure, min_permission, rationale) values
  ('asset_lots', 'reversed_by_txn_id', 'row', 'asset.view_assigned',
   'ใบกลับรายการที่ทำให้ล็อตเป็นโมฆะ · เป็นส่วนหนึ่งของเรื่องต้นทุนของพอร์ต อ่านได้คู่กับแถวที่มันอธิบาย (ขอบเขตทรัพย์เดียวกัน)'),
  ('asset_lots', 'reversed_at', 'row', 'asset.view_assigned',
   'เวลาที่ล็อตถูกกลับรายการ · เหตุผลเดียวกับ reversed_by_txn_id')
on conflict (table_name, column_name) do update
  set exposure = excluded.exposure, min_permission = excluded.min_permission,
      rationale = excluded.rationale;
select fn_apply_column_exposure();

-- ============================================================
-- 2 · ฟังก์ชันนับ — **ข้ามล็อตที่ถูกกลับรายการ** (เขียนทับของ 0008)
-- ============================================================
create or replace function fn_asset_lot_remaining(p_lot uuid) returns numeric
language sql stable security definer set search_path = '' as $fn$
  select round(l.quantity - coalesce((
           select sum(c.quantity) from sri_os.asset_lot_consumptions c where c.lot_id = l.id
         ), 0), 8)
    from sri_os.asset_lots l
   where l.id = p_lot and l.reversed_by_txn_id is null;
$fn$;

create or replace function fn_asset_units(p_asset uuid) returns numeric
language sql stable security definer set search_path = '' as $fn$
  select round(coalesce(sum(l.quantity), 0) - coalesce((
           select sum(c.quantity)
             from sri_os.asset_lot_consumptions c
             join sri_os.asset_lots l2 on l2.id = c.lot_id
            where l2.asset_id = p_asset and l2.reversed_by_txn_id is null), 0), 8)
    from sri_os.asset_lots l
   where l.asset_id = p_asset and l.reversed_by_txn_id is null;
$fn$;

create or replace function fn_asset_lot_cost(p_asset uuid) returns numeric
language sql stable security definer set search_path = '' as $fn$
  select round(coalesce(sum(l.cost_thb), 0) - coalesce((
           select sum(c.cost_thb)
             from sri_os.asset_lot_consumptions c
             join sri_os.asset_lots l2 on l2.id = c.lot_id
            where l2.asset_id = p_asset and l2.reversed_by_txn_id is null), 0), 2)
    from sri_os.asset_lots l
   where l.asset_id = p_asset and l.reversed_by_txn_id is null;
$fn$;

do $$
declare f text;
begin
  foreach f in array array['sri_os.fn_asset_lot_remaining(uuid)',
                           'sri_os.fn_asset_units(uuid)',
                           'sri_os.fn_asset_lot_cost(uuid)'] loop
    execute format('revoke all on function %s from public', f);
    execute format('revoke all on function %s from anon, authenticated', f);
  end loop;
end $$;

-- ============================================================
-- 3 · append-only ที่ยอมให้ "กลับรายการ" ได้ครั้งเดียว และต้องพิสูจน์ได้จากสมุด
-- ============================================================
create or replace function fn_assert_lot_append_only() returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  if tg_op = 'DELETE' then
    raise exception 'ลบล็อตที่ลงไว้แล้วไม่ได้ (กฎเหล็กข้อ 1) — ถ้าล็อตผิด ให้กลับรายการใบที่สร้างมันแล้วลงล็อตใหม่ · ต้นทุนถัวเฉลี่ยคิดจากทะเบียนนี้ การลบแถวคือการเปลี่ยนต้นทุนย้อนหลังโดยไม่มีร่องรอย';
  end if;

  /**
   * ฟังก์ชันนี้ใช้ร่วมกันสองตาราง — **ตารางการขายออกไม่มีคอลัมน์ร่องรอยนี้**
   * ถ้าไม่แยกก่อนอ่าน `old.reversed_by_txn_id` จะได้ error ดิบ
   * ("record old has no field ...") แทนข้อความที่อ่านรู้เรื่อง (เจอจริงตอนรันทั้งชุด)
   */
  if tg_table_name <> 'asset_lots' then
    raise exception 'แก้บันทึกการขายออกของล็อตไม่ได้ (กฎเหล็กข้อ 1) — ถ้าบันทึกผิด ให้กลับรายการใบที่ขายแล้วบันทึกใหม่ · ต้นทุนถัวเฉลี่ยคิดจากทะเบียนนี้ การแก้แถวคือการเปลี่ยนกำไรย้อนหลังโดยไม่มีร่องรอย';
  end if;

  /**
   * ยอมเฉพาะการ **ติดร่องรอยการกลับรายการ** (null → ค่า) และห้ามแก้ฟิลด์อื่นไปด้วย
   * — รูปเดียวกับที่ `transactions` ยอมให้เปลี่ยนเป็น void ได้แต่ห้ามแก้ตัวเลข
   */
  if old.reversed_by_txn_id is null and new.reversed_by_txn_id is not null
     and new.asset_id = old.asset_id
     and new.acquired_date = old.acquired_date
     and new.quantity = old.quantity
     and new.cost_thb = old.cost_thb
     and new.currency is not distinct from old.currency
     and new.amount_original is not distinct from old.amount_original
     and new.fx_rate is not distinct from old.fx_rate
     and new.fx_rate_date is not distinct from old.fx_rate_date
     and new.source_txn_id is not distinct from old.source_txn_id
  then
    -- **ต้องเป็นใบที่กลับรายการใบที่สร้างล็อตนี้จริง** (อ่านจากสมุด ไม่เชื่อค่าที่ส่งมา)
    if old.source_txn_id is null then
      raise exception 'ล็อตนี้ไม่ได้ผูกกับใบในสมุด (source_txn_id ว่าง) จึงกลับรายการไม่ได้ — ล็อตที่ไม่มีใบรองรับต้องไม่มีอยู่ตั้งแต่แรก';
    end if;
    if not exists (
      select 1 from sri_os.transactions r
       where r.id = new.reversed_by_txn_id
         and r.reverses_id = old.source_txn_id
    ) then
      raise exception 'ใบที่อ้างว่ากลับรายการล็อตนี้ (%) ไม่ได้กลับรายการใบที่สร้างล็อต (%) — ร่องรอยต้องพิสูจน์ได้จากสมุด ไม่ใช่จากค่าที่ส่งมา',
        new.reversed_by_txn_id, old.source_txn_id;
    end if;
    if exists (select 1 from sri_os.asset_lot_consumptions c where c.lot_id = old.id) then
      raise exception 'ล็อตนี้ถูกขายออกไปบางส่วนหรือทั้งหมดแล้ว จึงกลับรายการไม่ได้ — กำไรที่บันทึกไว้คิดจากต้นทุนของล็อตนี้ ถ้าลบต้นทุนย้อนหลังกำไรที่ลงไว้จะผิดโดยไม่มีใบไหนเปลี่ยน · ต้องกลับรายการใบขายก่อน';
    end if;
    return new;
  end if;

  raise exception 'แก้ล็อตที่ลงไว้แล้วไม่ได้ (กฎเหล็กข้อ 1) — ให้กลับรายการใบที่สร้างมันแล้วลงล็อตใหม่ · ที่ทำได้คือบันทึก "ขายออก" เพิ่ม (asset_lot_consumptions) หรือติดร่องรอยการกลับรายการเมื่อใบที่สร้างมันถูกกลับรายการ';
end $fn$;

revoke all on function fn_assert_lot_append_only() from public;
do $$ begin execute 'revoke all on function sri_os.fn_assert_lot_append_only() from anon, authenticated'; end $$;

-- ============================================================
-- 4 · "ชุดเดิม" + ลายนิ้วมือ — **อ่านจากสมุดทั้งคู่**
-- ============================================================
create or replace function fn_opening_set(p_owner uuid) returns uuid[]
language sql stable security definer set search_path = '' as $fn$
  -- ใบยอดยกมาของผู้ถือนี้ที่ **ยังไม่มีใบกลับรายการชี้มา** · เรียงให้ผลคงที่
  select coalesce(array_agg(t.id order by t.doc_date, t.created_at, t.id), '{}')
    from sri_os.transactions t
    join sri_os.txn_types ty on ty.code = t.txn_type_code
   where t.owner_id = p_owner
     and ty.group_code = 'opening'
     and t.status = 'posted'
     and t.reverses_id is null
     and not exists (select 1 from sri_os.transactions r where r.reverses_id = t.id);
$fn$;

comment on function fn_opening_set(uuid) is
  '"ชุดยอดตั้งต้นที่ยังมีผล" ของผู้ถือหนึ่ง — อ่านจากสมุด: ประเภทที่ txn_types.group_code = opening · ยังไม่มีใบกลับรายการชี้มา · ไม่ใช่ป้ายที่ผู้เรียกส่งมา (D-115)';

/**
 * ลายนิ้วมือของ **เนื้อหา** ยอดตั้งต้นของผู้ถือหนึ่ง (รวมทะเบียนล็อต)
 *
 * เอาเฉพาะสิ่งที่เป็นตัวเลข/คู่บัญชี/วันตัดยอด — **ไม่เอา memo** เพราะข้อความ
 * ที่ต่างกันไม่ใช่เหตุให้กลับรายการทั้งชุด (ไฟล์เดิมที่พิมพ์หมายเหตุใหม่ = เนื้อเดิม)
 * เรียงทุกอย่างก่อน hash → ลำดับบรรทัด/ใบในไฟล์ไม่ทำให้ลายนิ้วมือเปลี่ยน
 */
create or replace function fn_opening_fingerprint(p_owner uuid) returns text
language sql stable security definer set search_path = '' as $fn$
  select md5(coalesce((
      select string_agg(x.sig, '|' order by x.sig)
        from (
          select format('E:%s:%s:%s:%s:%s:%s:%s',
                        t.txn_type_code, t.doc_date, c.code,
                        to_char(l.debit, 'FM999999999990.00'),
                        to_char(l.credit, 'FM999999999990.00'),
                        coalesce(l.bank_account_id::text, '-'),
                        coalesce(l.asset_id::text, '-')) as sig
            from sri_os.transactions t
            join sri_os.transaction_lines l on l.transaction_id = t.id
            join sri_os.chart_of_accounts c on c.id = l.coa_id
           where t.id = any (sri_os.fn_opening_set(p_owner))
        ) x), '')
    || '#' || coalesce((
      select string_agg(y.sig, '|' order by y.sig)
        from (
          select format('L:%s:%s:%s:%s:%s:%s:%s:%s',
                        lo.asset_id, lo.acquired_date,
                        to_char(lo.quantity, 'FM999999999990.00000000'),
                        to_char(lo.cost_thb, 'FM999999999990.00'),
                        coalesce(lo.currency, '-'),
                        coalesce(to_char(lo.amount_original, 'FM999999999990.000000'), '-'),
                        coalesce(to_char(lo.fx_rate, 'FM999999999990.00000000'), '-'),
                        coalesce(lo.fx_rate_date::text, '-')) as sig
            from sri_os.asset_lots lo
            join sri_os.assets a on a.id = lo.asset_id
           where a.owner_id = p_owner and lo.reversed_by_txn_id is null
        ) y), ''));
$fn$;

comment on function fn_opening_fingerprint(uuid) is
  'ลายนิ้วมือของเนื้อหายอดตั้งต้นของผู้ถือหนึ่ง (คู่บัญชี · ยอด · บัญชีธนาคาร · ทรัพย์ · วันตัดยอด + ทะเบียนล็อตที่ยังใช้อยู่) · **คำนวณใหม่จากสมุดทุกครั้ง ไม่เก็บไว้** · ไม่รวม memo เพราะข้อความไม่ใช่เหตุให้กลับรายการทั้งชุด';

do $$
declare f text;
begin
  foreach f in array array['sri_os.fn_opening_set(uuid)', 'sri_os.fn_opening_fingerprint(uuid)'] loop
    execute format('revoke all on function %s from public', f);
    execute format('revoke all on function %s from anon, authenticated', f);
  end loop;
end $$;

-- ============================================================
-- 5 · ประตูเดียวของการอัปโหลดยอดตั้งต้นใหม่ — **ธุรกรรมเดียว**
--
-- `security invoker` โดยตั้งใจ: ทุกการเขียนไปผ่าน `fn_post_entry` ซึ่งตรวจสิทธิ์
-- และ RLS ด้วยสิทธิ์ของผู้เรียกจริง · definer จะกลายเป็นทางข้ามสิทธิ์ทั้งชุด
-- ============================================================
create or replace function fn_reimport_opening(p_owner uuid, p_payload jsonb) returns jsonb
language plpgsql set search_path = sri_os, public as $fn$
declare
  v_old        uuid[];
  v_fp_before  text;
  v_fp_after   text;
  v_entry      jsonb;
  v_lot        jsonb;
  v_txn        uuid;
  v_rev        uuid;
  v_out        jsonb;
  v_lines      jsonb;
  v_posted     uuid[] := '{}';
  v_reversed   uuid[] := '{}';
  v_blocker    text;
  v_n_lots     int := 0;
  v_round      int;
  v_i          int;
begin
  if p_owner is null then
    raise exception 'บันทึกยอดตั้งต้นไม่ได้: ต้องระบุผู้ถือ';
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'บันทึกยอดตั้งต้นไม่ได้: ต้องส่งเนื้อหาของไฟล์ (entries / lots)';
  end if;
  if (select count(*) from jsonb_object_keys(p_payload) k where k <> all (array['entries', 'lots'])) > 0 then
    raise exception 'บันทึกยอดตั้งต้นไม่ได้: มีช่องที่ยังไม่รู้จัก — รับเฉพาะ entries และ lots (ปฏิเสธทั้งคำขอแทนที่จะทิ้งช่องนั้นเงียบๆ)';
  end if;
  if jsonb_typeof(p_payload -> 'entries') <> 'array' then
    raise exception 'บันทึกยอดตั้งต้นไม่ได้: entries ต้องเป็นรายการของใบยอดยกมา';
  end if;

  v_old := fn_opening_set(p_owner);
  v_fp_before := fn_opening_fingerprint(p_owner);

  -- ---------- ลงชุดใหม่บนฐานเปล่า แล้วเทียบลายนิ้วมือทีหลังไม่ได้ ----------
  -- ต้องรู้ "ลายนิ้วมือของไฟล์ใหม่" ก่อนตัดสินใจ → ประกอบจาก payload ด้วยสูตรเดียวกัน
  with e as (
    select ent.value as entry from jsonb_array_elements(p_payload -> 'entries') ent
  ), tx as (
    -- บรรทัดอยู่ใต้ `transactions[*].lines` ของ payload ประตู **ไม่ใช่ใต้ใบตรงๆ**
    -- (เขียนผิดที่นี่แล้วลายนิ้วมือฝั่งไฟล์จะว่างเปล่า → เทียบกับสมุดไม่ตรงทุกครั้ง
    --  ซึ่งเจอตอนรันจริง: ด่านปิดท้ายปฏิเสธการนำเข้าครั้งแรก)
    select e.entry, t.value as txn
      from e, jsonb_array_elements(e.entry -> 'transactions') t
  ), sigs as (
    select format('E:%s:%s:%s:%s:%s:%s:%s',
                  tx.entry ->> 'txn_type_code', (tx.entry ->> 'doc_date')::date, l.value ->> 'coa_code',
                  to_char(coalesce((l.value ->> 'debit')::numeric, 0), 'FM999999999990.00'),
                  to_char(coalesce((l.value ->> 'credit')::numeric, 0), 'FM999999999990.00'),
                  coalesce(l.value ->> 'bank_account_id', '-'),
                  coalesce(l.value ->> 'asset_id', '-')) as sig
      from tx, jsonb_array_elements(tx.txn -> 'lines') l
  ), lotsigs as (
    select format('L:%s:%s:%s:%s:%s:%s:%s:%s',
                  lo.value ->> 'asset_id', (lo.value ->> 'acquired_date')::date,
                  to_char((lo.value ->> 'quantity')::numeric, 'FM999999999990.00000000'),
                  to_char((lo.value ->> 'cost_thb')::numeric, 'FM999999999990.00'),
                  coalesce(lo.value ->> 'currency', '-'),
                  coalesce(to_char((lo.value ->> 'amount_original')::numeric, 'FM999999999990.000000'), '-'),
                  coalesce(to_char((lo.value ->> 'fx_rate')::numeric, 'FM999999999990.00000000'), '-'),
                  coalesce(lo.value ->> 'fx_rate_date', '-')) as sig
      from jsonb_array_elements(coalesce(p_payload -> 'lots', '[]'::jsonb)) lo
  )
  select md5(coalesce((select string_agg(sig, '|' order by sig) from sigs), '')
             || '#' || coalesce((select string_agg(sig, '|' order by sig) from lotsigs), ''))
    into v_fp_after;

  /**
   * ---------- เนื้อเหมือนเดิม = **ไม่เขียนอะไรเลย** ----------
   * ไม่ใช่ reverse แล้วลงใหม่ให้เหมือนเดิม (สมุดจะบวมด้วยคู่ที่หักกันเอง
   * และคนอ่านประวัติจะแยกไม่ออกว่าอะไรคือการแก้จริง)
   */
  if v_fp_before = v_fp_after then
    return jsonb_build_object(
      'changed', false,
      'reason', 'เนื้อหาเหมือนเดิมทุกตัวเลข จึงไม่ลงรายการใหม่และไม่กลับรายการอะไร',
      'kept', coalesce(array_length(v_old, 1), 0),
      'reversed', 0, 'posted', 0, 'lots', 0);
  end if;

  -- ---------- มีรายการอื่นอ้างยอดตั้งต้นนี้ไปแล้ว → ปฏิเสธ ----------
  select string_agg(b.why, ' · ') into v_blocker
    from (
      -- (ก) ขายล็อตที่มาจากยอดตั้งต้นไปแล้ว
      select format('ขายล็อตของทรัพย์ %s ไปแล้ว (ใบ %s)', l.asset_id, c.txn_id) as why
        from asset_lot_consumptions c
        join asset_lots l on l.id = c.lot_id
       where l.reversed_by_txn_id is null
         and l.source_txn_id = any (v_old)
      union all
      -- (ข) ล้างยอดค้าง (เก็บเงิน/จ่าย/ตัดหนี้สูญ) ที่อ้างใบยอดตั้งต้นเป็นต้นทาง
      select format('มีใบล้างยอดค้างที่อ้างใบยอดตั้งต้น %s (ใบ %s)', t.clears_id, t.id) as why
        from transactions t
       where t.clears_id = any (v_old) and t.status = 'posted'
    ) b;
  if v_blocker is not null then
    raise exception 'อัปโหลดยอดตั้งต้นใหม่ของผู้ถือนี้ไม่ได้ เพราะมีรายการที่อ้างยอดเดิมไปแล้ว: % · ยอดตั้งต้นเป็นต้นทุน/ยอดค้างที่รายการหลังจากนั้นคิดต่อจากมัน — เปลี่ยนย้อนหลังแล้วกำไรหรือยอดค้างที่บันทึกไว้จะผิดโดยไม่มีใบไหนเปลี่ยน · ต้องกลับรายการใบเหล่านั้นก่อน แล้วอัปโหลดใหม่',
      v_blocker;
  end if;

  -- ---------- (1) กลับรายการชุดเดิมทั้งชุด ----------
  foreach v_txn in array v_old loop
    -- บรรทัดกลับด้าน — **อ่านจากสมุด** ไม่รับจากผู้เรียก (ด่าน reverse เทียบ multiset เอง)
    select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
             'coa_code', c.code,
             'bank_account_id', l.bank_account_id,
             'asset_id', l.asset_id,
             'debit', l.credit,
             'credit', l.debit,
             'cf_category', l.cf_category::text,
             'memo', 'กลับรายการยอดตั้งต้น (อัปโหลดใหม่)')))
      into v_lines
      from transaction_lines l
      join chart_of_accounts c on c.id = l.coa_id
     where l.transaction_id = v_txn;

    v_out := fn_post_entry((
      select jsonb_strip_nulls(jsonb_build_object(
        'txn_type_code', t.txn_type_code,
        'doc_date', to_char(current_date, 'YYYY-MM-DD'),
        'cash_date', case when exists (
                            select 1 from transaction_lines l2
                             join chart_of_accounts c2 on c2.id = l2.coa_id
                            where l2.transaction_id = t.id and c2.code ~ '^11[0-9][0-9]$')
                          then to_char(current_date, 'YYYY-MM-DD') end,
        'memo', 'กลับรายการยอดตั้งต้นเพื่ออัปโหลดใหม่ (ใบเดิม ' || t.id::text || ')',
        'asset_id', t.asset_id,
        'contact_id', t.contact_id,
        'attachments', t.attachments,
        'source', 'reverse',
        'reverses_id', t.id,
        'transactions', jsonb_build_array(jsonb_build_object(
          'owner_id', t.owner_id, 'lines', v_lines))))
        from transactions t where t.id = v_txn));

    v_rev := ((v_out -> 'transaction_ids') ->> 0)::uuid;
    v_reversed := v_reversed || v_rev;

    -- ล็อตที่ใบนี้สร้าง → ติดร่องรอยว่าถูกกลับรายการ (ด่านตรวจว่าใบนั้นกลับรายการจริง)
    update asset_lots
       set reversed_by_txn_id = v_rev, reversed_at = now()
     where source_txn_id = v_txn and reversed_by_txn_id is null;
  end loop;

  /**
   * ---------- (2) ลงชุดใหม่ ----------
   *
   * **ต้องติดเลขรอบการนำเข้าไปกับทุกใบ** (`source_ref = opening-import:<รอบ>:<ลำดับ>`)
   *
   * ประตู `fn_post_entry` มีด่านกันกดซ้ำที่ตัดสินจาก **ลายนิ้วมือของ payload**
   * → ใบใหม่ที่เนื้อเหมือนใบเดิมเป๊ะ (เช่นอัปโหลดใหม่ที่แก้แค่บางใบ) จะถูกมองเป็น
   * "การกดซ้ำ" แล้วประตูคืน id ของใบเดิม **ซึ่งเพิ่งถูกกลับรายการไป** = ยอดนั้นหายไป
   * ทั้งที่ทุกคำสั่งสำเร็จ (เจอจริงตอนรัน: ใบหลักทรัพย์ไม่ถูกลงใหม่ และด่านปิดท้าย
   * เป็นคนจับได้) · เลขรอบทำให้ payload ของแต่ละรอบต่างกันจริง และอ่านย้อนได้ว่า
   * ใบนี้มาจากการอัปโหลดรอบไหน
   */
  v_round := 1 + (
    select count(*) from transactions t
      join txn_types ty on ty.code = t.txn_type_code
     where t.owner_id = p_owner and ty.group_code = 'opening' and t.reverses_id is null);

  v_i := 0;
  for v_entry in select value from jsonb_array_elements(p_payload -> 'entries') loop
    v_i := v_i + 1;
    v_out := fn_post_entry(jsonb_set(v_entry, '{source_ref}',
               to_jsonb(format('opening-import:%s:%s', v_round, v_i))));
    if (v_out ->> 'replayed')::boolean then
      raise exception 'ประตูมองใบที่ % ของการอัปโหลดรอบนี้เป็นการกดซ้ำ — แปลว่าเลขรอบไม่ได้ทำให้ payload ต่างจริง · ปฏิเสธทั้งคำสั่งแทนที่จะคืน id ของใบเก่าที่เพิ่งถูกกลับรายการ (ซึ่งจะทำให้ยอดหายโดยที่ทุกคำสั่งสำเร็จ)',
        v_i;
    end if;
    v_posted := v_posted || ((v_out -> 'transaction_ids') ->> 0)::uuid;
  end loop;

  -- ---------- (3) ล็อตชุดใหม่ ----------
  for v_lot in select value from jsonb_array_elements(coalesce(p_payload -> 'lots', '[]'::jsonb)) loop
    insert into asset_lots(asset_id, acquired_date, quantity, cost_thb,
                           currency, amount_original, fx_rate, fx_rate_date,
                           source_txn_id, note, created_by)
    values ((v_lot ->> 'asset_id')::uuid,
            (v_lot ->> 'acquired_date')::date,
            (v_lot ->> 'quantity')::numeric,
            (v_lot ->> 'cost_thb')::numeric,
            v_lot ->> 'currency',
            (v_lot ->> 'amount_original')::numeric,
            (v_lot ->> 'fx_rate')::numeric,
            (v_lot ->> 'fx_rate_date')::date,
            -- ล็อตต้องผูกใบในสมุด: ใบของทรัพย์ชิ้นนั้นในชุดใหม่
            (select p from unnest(v_posted) p
              join transactions t on t.id = p
             where t.asset_id = (v_lot ->> 'asset_id')::uuid limit 1),
            v_lot ->> 'note',
            auth.uid());
    v_n_lots := v_n_lots + 1;
  end loop;

  -- ---------- (4) ลายนิ้วมือหลังลงต้องเท่ากับของไฟล์ใหม่ ----------
  -- ด่านปิดท้ายที่พิสูจน์ว่า "ที่ลงไป" = "ที่ไฟล์บอก" · ไม่เท่า = ย้อนทั้งคำสั่ง
  if fn_opening_fingerprint(p_owner) <> v_fp_after then
    raise exception 'ลงยอดตั้งต้นใหม่แล้วเนื้อหาในสมุดไม่ตรงกับไฟล์ที่ส่งมา — ย้อนทั้งคำสั่ง (ถ้าปล่อยผ่าน สมุดจะไม่ตรงกับไฟล์โดยไม่มีใครรู้) · ตรวจว่าไฟล์มีใบของผู้ถืออื่นปนมา หรือมีบรรทัดที่ประตูปรับค่าให้';
  end if;

  return jsonb_build_object(
    'changed', true,
    'reversed', coalesce(array_length(v_reversed, 1), 0),
    'posted', coalesce(array_length(v_posted, 1), 0),
    'lots', v_n_lots,
    'reversed_ids', to_jsonb(v_reversed),
    'posted_ids', to_jsonb(v_posted));
end $fn$;

comment on function fn_reimport_opening(uuid, jsonb) is
  'อัปโหลดยอดตั้งต้นใหม่ของผู้ถือหนึ่ง **ในธุรกรรมเดียว**: เนื้อเหมือนเดิม → ไม่เขียนอะไรเลย · ต่างกัน → กลับรายการชุดเดิม (อ่านชุดจากสมุด ไม่ใช่จากป้ายที่ส่งมา) แล้วลงชุดใหม่ + ติดร่องรอยล็อตเดิมและลงล็อตใหม่ · มีรายการอื่นอ้างยอดเดิมไปแล้ว (ขาย/เก็บเงิน) → ปฏิเสธพร้อมบอกว่าใบไหน · error ที่ไหนก็ย้อนทั้งคำสั่ง จึงไม่มีจังหวะที่ยอดของผู้ถือเป็นศูนย์';

revoke all on function fn_reimport_opening(uuid, jsonb) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_reimport_opening(uuid, jsonb) from anon';
  execute 'grant execute on function sri_os.fn_reimport_opening(uuid, jsonb) to authenticated';
end $$;

-- ============================================================
-- 6 · guard ท้ายไฟล์
-- ============================================================
do $$
declare v text;
begin
  -- (ก) ชุดเดิมต้องอ่านจากตารางกฎ + สมุด ไม่ใช่จากป้ายของผู้เรียก
  v := pg_get_functiondef('sri_os.fn_opening_set(uuid)'::regprocedure);
  if v !~ 'group_code' or v !~ 'reverses_id' then
    raise exception 'fn_opening_set ไม่ได้ตัดสินจากตารางกฎ/สมุด — มีไฟล์อื่นเขียนทับหลังไฟล์นี้';
  end if;

  -- (ข) ฟังก์ชันอัปโหลดต้องเป็น invoker (definer = ทางข้ามสิทธิ์ทั้งชุด)
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'sri_os' and p.proname = 'fn_reimport_opening' and p.prosecdef) then
    raise exception 'fn_reimport_opening เป็น security definer — ต้องเป็น invoker เพื่อให้ RLS และสิทธิ์ของผู้เรียกบังคับจริง';
  end if;

  -- (ค) ต้องเขียนผ่านประตูเดียว (ห้าม insert เข้า transactions ตรงๆ)
  v := pg_get_functiondef('sri_os.fn_reimport_opening(uuid, jsonb)'::regprocedure);
  if v ~* 'insert\s+into\s+transactions' or v ~* 'insert\s+into\s+transaction_lines' then
    raise exception 'fn_reimport_opening เขียนเข้าตารางสมุดตรงๆ — ต้องผ่าน fn_post_entry เท่านั้น';
  end if;
  if v !~ 'fn_post_entry' then
    raise exception 'fn_reimport_opening ไม่ได้เรียก fn_post_entry';
  end if;
  if v !~ 'fn_opening_fingerprint' then
    raise exception 'fn_reimport_opening ไม่ได้เทียบลายนิ้วมือ — อัปโหลดเดิมซ้ำจะ reverse แล้วลงใหม่เปล่าๆ';
  end if;
  if v !~ 'opening-import:' then
    raise exception 'fn_reimport_opening ไม่ได้ติดเลขรอบการนำเข้าไปกับใบใหม่ — ประตูจะมองใบที่เนื้อเหมือนใบเดิมเป็นการกดซ้ำ แล้วคืน id ของใบที่เพิ่งถูกกลับรายการ = ยอดหายโดยที่ทุกคำสั่งสำเร็จ';
  end if;

  -- (ง) ฟังก์ชันนับต้องข้ามล็อตที่ถูกกลับรายการ
  v := pg_get_functiondef('sri_os.fn_asset_units(uuid)'::regprocedure);
  if v !~ 'reversed_by_txn_id is null' then
    raise exception 'fn_asset_units ยังนับล็อตที่ถูกกลับรายการ — ยอดจะค้างสองชุดหลังอัปโหลดใหม่';
  end if;

  -- (จ) ด่านของล็อตต้องพิสูจน์ร่องรอยจากสมุด
  v := pg_get_functiondef('sri_os.fn_assert_lot_append_only()'::regprocedure);
  if v !~ 'r\.reverses_id = old\.source_txn_id' then
    raise exception 'ด่านล็อตยอมให้ติดร่องรอยการกลับรายการโดยไม่พิสูจน์จากสมุด';
  end if;

  -- (ฉ) ด่านคอลัมน์ต้องไม่มีของค้าง
  select string_agg(u.object_name, ', ') into v
    from sri_os.fn_column_exposure_unclassified() u
   where u.object_name like 'asset_lot%';
  if v is not null then
    raise exception 'ด่านคอลัมน์มีของค้างจากตารางล็อต: %', v;
  end if;

  raise notice 'อัปโหลดยอดตั้งต้นใหม่พร้อม: เนื้อเหมือนเดิม = ไม่เขียนอะไร · ต่างกัน = กลับรายการชุดเดิม (อ่านจากสมุด) + ลงชุดใหม่ + ล็อตเดิมติดร่องรอย ทั้งหมดในธุรกรรมเดียว · มีคนอ้างยอดเดิมไปแล้ว = ปฏิเสธ';
end $$;
