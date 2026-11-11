-- ============================================================
-- SRI OS · **ทะเบียนล็อตรายตัว** (หุ้น · ทอง · คริปโต) — D-112 ภาคที่ยังไม่มีที่เก็บ
--
-- ตัวนำเข้าตรวจและพรีวิวรายล็อตได้แล้ว (วันที่ซื้อ · จำนวน · ราคา · **อัตราวันซื้อ**)
-- แต่ **ไม่มีที่เก็บ** → ลงจริงไม่ได้ และ `average-cost.ts` คิดจากล็อตที่ผู้เรียก
-- ส่งเข้ามาเท่านั้น (= ต้นทุนถัวเฉลี่ยมาจากค่าที่ผู้เรียกเลือกได้ · D-115 ห้าม)
--
-- ------------------------------------------------------------
-- **สิ่งที่ไฟล์นี้ทำให้เป็นความจริงเดียว**
--
-- 1. `asset_lots` = ล็อตที่ซื้อเข้ามา (append-only) · `asset_lot_consumptions`
--    = ส่วนที่ขายออกไปของแต่ละล็อต (append-only) → **จำนวนคงเหลือและต้นทุน
--    ถัวเฉลี่ยคำนวณใหม่จากสองตารางนี้ทุกครั้ง** ไม่มีคอลัมน์ "คงเหลือ" ให้แก้มือ
--    (`assets.units` แก้มือได้ จึง **ห้ามเป็นแหล่งความจริง** — ผมระบุไว้เองตอน D-112
--     และไฟล์นี้ทำให้มีของจริงมาแทน)
--
-- 2. สกุลเงินและอัตราใช้ **รูปเดียวกับ `transaction_lines`** (`currency` ·
--    `amount_original` · `fx_rate` · `fx_rate_date` · 20261025000004) —
--    ไม่คิดรูปที่สี่ · อัตราต้องมีอยู่ใน `fx_rates` จริง (FK) และ **ต้องเท่ากับ
--    อัตราที่ประกาศของวันนั้น** · ต้นทุนบาท = `round(ยอดสกุลเดิม × อัตรา, 2)` **พอดี**
--    ล็อตสกุลต่างประเทศที่ **ไม่มีอัตรา → ปฏิเสธ** (ไม่ใช่เดาเป็น 1 แล้วนับ USD เป็นบาท)
--
-- 3. ล็อตผูกกับ `assets` และผูกกับ **รายการที่สร้างมันได้** (`source_txn_id`)
--    การขายผูกกับใบที่ขาย (`txn_id`) → ตรวจย้อนได้ว่าต้นทุนก้อนนี้มาจากใบไหน
--
-- 4. **ด่านต้นทุนถัวเฉลี่ย**: ยอดต้นทุนที่ตัดออกตอนขาย ต้องเท่ากับ
--      `ต้นทุนคงเหลือทั้งกอง × จำนวนที่ขาย ÷ จำนวนคงเหลือทั้งกอง`
--    คำนวณใหม่จากทะเบียน → **ส่งค่าต้นทุนผิดเข้ามาไม่มีผล** (ถูกปฏิเสธ)
--    และหลังขาย ต้นทุนในสมุด (`fn_asset_cost_basis` · 20261025000002) ต้องเท่ากับ
--    ต้นทุนคงเหลือในทะเบียน → สมุดกับทะเบียนย่อยแยกจากกันไม่ได้
--
-- ------------------------------------------------------------
-- **เงื่อนไขที่ตัวนำเข้าต้องทำตาม** (เขียนไว้ที่นี่เพราะด่านจะบังคับ)
--   ใบยอดยกมาของหลักทรัพย์/ทองคำ **ต้องผูกทรัพย์** (`asset_id` ที่หัวรายการและที่
--   บรรทัดบัญชีทรัพย์) และควรลงแยกต่อทรัพย์หนึ่งชิ้นต่อหนึ่งใบ — ไม่งั้นต้นทุนในสมุด
--   จะเป็นก้อนรวมที่ไม่รู้ว่าของทรัพย์ชิ้นไหน แล้วด่านข้อ 4 จะปฏิเสธการขายครั้งแรก
--   พร้อมข้อความที่บอกวิธีแก้ (ดีกว่าปล่อยให้ตัวเลขสองฝั่งต่างกันเงียบๆ)
--
-- ลำดับ: **ต้องรันหลัง 20261025000002** (ใช้ `fn_asset_cost_basis`) ·
--   **หลัง 20261024000001** (ตาราง `fx_rates`) · **หลัง 20261020000000/2** (ด่านคอลัมน์)
--   → วางต่อท้าย `20261025000007_clearing_link_from_db.sql`
--   ก่อน `20261020000003_replay_end_state_guard.sql`
--
-- idempotent: create table if not exists · drop trigger if exists ก่อน create ·
--   create or replace function · insert ... on conflict do update
--
-- ย้อนกลับ (rollback) — เรียงจากหลังมาหน้า:
--   -- delete from sri_os.column_exposure where table_name in ('asset_lots','asset_lot_consumptions');
--   -- delete from sri_os.column_exposure_tables where table_name in ('asset_lots','asset_lot_consumptions');
--   -- select sri_os.fn_apply_column_exposure();
--   -- drop table if exists sri_os.asset_lot_consumptions;   (ลบประวัติการขายรายล็อตถาวร)
--   -- drop table if exists sri_os.asset_lots;                (ลบทะเบียนต้นทุนถาวร)
--   -- drop function if exists sri_os.fn_asset_lot_remaining(uuid), sri_os.fn_asset_units(uuid),
--   --   sri_os.fn_asset_lot_cost(uuid), sri_os.fn_asset_average_unit_cost(uuid),
--   --   sri_os.fn_asset_lot_mismatch(), sri_os.fn_assert_lot_consumption_sane_for(uuid);
--   -- ย้อนแล้วได้สภาพเดิมคือ **ไม่มีที่เก็บล็อต** และต้นทุนถัวเฉลี่ยมาจากค่าที่ผู้เรียกส่ง
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 0 · pre-flight — ดังก่อนแตะอะไรเลยถ้าลำดับไม่ถูก
-- ============================================================
do $$
begin
  if to_regclass('sri_os.fx_rates') is null then
    raise exception 'ไม่มีตาราง fx_rates → ต้องรัน 20261024000001_wht_and_fx.sql ก่อน (ล็อตสกุลต่างประเทศอ้างอัตราจากตารางนั้น)';
  end if;
  if to_regprocedure('sri_os.fn_asset_cost_basis(uuid)') is null then
    raise exception 'ไม่มี fn_asset_cost_basis → ต้องรัน 20261025000002_asset_cost_basis_average.sql ก่อน (ด่านนี้เทียบทะเบียนล็อตกับต้นทุนในสมุดด้วยฟังก์ชันนั้น)';
  end if;
  if to_regclass('sri_os.column_exposure_tables') is null
     or to_regprocedure('sri_os.fn_apply_column_exposure()') is null then
    raise exception 'ไม่มีทะเบียนด่านคอลัมน์ → ต้องรัน 20261020000000/20261020000002 ก่อน (ตารางใหม่ที่ไม่ขึ้นทะเบียน = guard แดง)';
  end if;
end $$;

-- ============================================================
-- 1 · ตารางล็อต — **append-only** (แก้ = กลับรายการแล้วลงใหม่ · กฎเหล็กข้อ 1)
-- ============================================================
create table if not exists asset_lots (
  id              uuid primary key default gen_random_uuid(),
  asset_id        uuid not null references assets(id) on delete restrict,
  /** วันที่ได้มา — ใช้เรียงลำดับและเป็นวันของอัตราที่ควรใช้ */
  acquired_date   date not null,
  /** จำนวนหน่วย (หุ้น/กรัม/เหรียญ) — ทศนิยม 8 ตำแหน่งพอสำหรับคริปโต */
  quantity        numeric(28,8) not null check (quantity > 0),
  /** ต้นทุนรวมของล็อตนี้ **เป็นบาท** = ยอดสกุลเดิม × อัตรา (ปัด 2 ตำแหน่ง) */
  cost_thb        numeric(18,2) not null check (cost_thb >= 0),
  /* ---- สกุลเงินเดิม · รูปเดียวกับ transaction_lines (ครบทั้งสี่ หรือไม่มีเลย) ---- */
  currency        text,
  amount_original numeric(18,6),
  fx_rate         numeric(18,8),
  fx_rate_date    date,
  /** ใบที่สร้างล็อตนี้ (ยอดยกมา หรือใบซื้อ) — ตรวจย้อนได้ว่าต้นทุนมาจากไหน */
  source_txn_id   uuid references transactions(id) on delete restrict,
  note            text,
  created_by      uuid references app_users(id),
  created_at      timestamptz not null default now()
);

-- สกุลเงินใช้ชุดเดียวกับ `src/lib/rules/currency.ts` (THB/USD/JPY/CNY) ด้วย check
-- เหมือน `bank_accounts.currency`/`assets.currency` — ไม่สร้างตารางสกุลเงินตัวที่สอง
alter table asset_lots drop constraint if exists asset_lots_currency_allowed;
alter table asset_lots
  add constraint asset_lots_currency_allowed
  check (currency is null or currency in ('THB', 'USD', 'JPY', 'CNY'));

-- รูปของชุดสกุลเงิน — ครบทั้งสี่ หรือไม่มีเลย (รูปเดียวกับ transaction_lines_fx_shape)
alter table asset_lots drop constraint if exists asset_lots_fx_shape;
alter table asset_lots
  add constraint asset_lots_fx_shape check (
    (currency is null and amount_original is null and fx_rate is null and fx_rate_date is null)
    or (
      currency is not null
      and amount_original is not null and amount_original > 0
      and fx_rate is not null and fx_rate > 0
      and fx_rate_date is not null
      and (currency <> 'THB' or fx_rate = 1)
    )
  );

-- อัตราต้องมีอยู่จริงในตารางอัตรา (รูปเดียวกับ transaction_lines_fx_rate_fk)
alter table asset_lots drop constraint if exists asset_lots_fx_rate_fk;
alter table asset_lots
  add constraint asset_lots_fx_rate_fk
  foreign key (currency, fx_rate_date) references fx_rates(currency, rate_date);

-- ต้นทุนบาทต้องมาจากอัตรา **พอดี** (ไม่ยอมเศษ — เหตุผลเดียวกับ WARN 3 ของ FCD)
alter table asset_lots drop constraint if exists asset_lots_cost_from_rate;
alter table asset_lots
  add constraint asset_lots_cost_from_rate check (
    amount_original is null or cost_thb = round(amount_original * fx_rate, 2)
  );

comment on table asset_lots is
  'ทะเบียนล็อตรายตัวของหุ้น/ทอง/คริปโต (D-112) · **append-only** · จำนวนคงเหลือและต้นทุนถัวเฉลี่ยคำนวณใหม่จากตารางนี้คู่กับ asset_lot_consumptions ทุกครั้ง — ไม่มีคอลัมน์คงเหลือให้แก้มือ และ assets.units ไม่ใช่แหล่งความจริง · สกุลเงิน/อัตราใช้รูปเดียวกับ transaction_lines';

create index if not exists asset_lots_asset_idx on asset_lots (asset_id, acquired_date, created_at);
create index if not exists asset_lots_txn_idx on asset_lots (source_txn_id) where source_txn_id is not null;

-- ============================================================
-- 2 · การขายออกของแต่ละล็อต — append-only เช่นกัน
-- ============================================================
create table if not exists asset_lot_consumptions (
  id          uuid primary key default gen_random_uuid(),
  lot_id      uuid not null references asset_lots(id) on delete restrict,
  /** ใบที่ขาย/ตัดออก — ผูกกับสมุดเสมอ (ไม่มีการตัดล็อตที่ไม่มีใบ) */
  txn_id      uuid not null references transactions(id) on delete restrict,
  quantity    numeric(28,8) not null check (quantity > 0),
  /** ต้นทุนบาทที่ตัดออกไปกับจำนวนนี้ — ต้องเท่ากับต้นทุนถัวเฉลี่ย × จำนวน (ด่านข้างล่าง) */
  cost_thb    numeric(18,2) not null check (cost_thb >= 0),
  created_by  uuid references app_users(id),
  created_at  timestamptz not null default now()
);

comment on table asset_lot_consumptions is
  'ส่วนที่ขาย/ตัดออกไปของแต่ละล็อต · append-only · ผูกกับใบในสมุดเสมอ · ยอดต้นทุนที่ตัดต้องเท่ากับ **ต้นทุนถัวเฉลี่ยที่คำนวณใหม่จากทะเบียน** ไม่ใช่ค่าที่ผู้เรียกส่งมา (D-115)';

create index if not exists asset_lot_consumptions_lot_idx on asset_lot_consumptions (lot_id);
create index if not exists asset_lot_consumptions_txn_idx on asset_lot_consumptions (txn_id);

-- ============================================================
-- 3 · ความจริงที่คำนวณใหม่ทุกครั้ง (ไม่มีคอลัมน์ให้แก้มือ)
-- ============================================================

/** จำนวนคงเหลือของล็อตหนึ่ง = ที่ซื้อ − ที่ขายออกไปแล้ว */
create or replace function fn_asset_lot_remaining(p_lot uuid) returns numeric
language sql stable security definer set search_path = '' as $fn$
  select round(l.quantity - coalesce((
           select sum(c.quantity) from sri_os.asset_lot_consumptions c where c.lot_id = l.id
         ), 0), 8)
    from sri_os.asset_lots l where l.id = p_lot;
$fn$;

/** จำนวนหน่วยคงเหลือของทรัพย์ชิ้นหนึ่ง — **แหล่งความจริงแทน `assets.units`** */
create or replace function fn_asset_units(p_asset uuid) returns numeric
language sql stable security definer set search_path = '' as $fn$
  select round(coalesce(sum(l.quantity), 0) - coalesce((
           select sum(c.quantity)
             from sri_os.asset_lot_consumptions c
             join sri_os.asset_lots l2 on l2.id = c.lot_id
            where l2.asset_id = p_asset), 0), 8)
    from sri_os.asset_lots l where l.asset_id = p_asset;
$fn$;

/** ต้นทุนคงเหลือของทรัพย์ชิ้นหนึ่งตาม **ทะเบียนล็อต** (บาท) */
create or replace function fn_asset_lot_cost(p_asset uuid) returns numeric
language sql stable security definer set search_path = '' as $fn$
  select round(coalesce(sum(l.cost_thb), 0) - coalesce((
           select sum(c.cost_thb)
             from sri_os.asset_lot_consumptions c
             join sri_os.asset_lots l2 on l2.id = c.lot_id
            where l2.asset_id = p_asset), 0), 2)
    from sri_os.asset_lots l where l.asset_id = p_asset;
$fn$;

/**
 * ต้นทุน **ถัวเฉลี่ย** ต่อหน่วย (D-112) — คำนวณจากทะเบียนล็อตเท่านั้น
 * ไม่มีพารามิเตอร์ให้ผู้เรียกส่งต้นทุนเข้ามา → ส่งค่าผิดมาก็ไม่มีผล
 * คืน null เมื่อไม่มีหน่วยคงเหลือ (หารศูนย์ไม่ได้ และ "ไม่มีของ" ไม่มีต้นทุนต่อหน่วย)
 */
create or replace function fn_asset_average_unit_cost(p_asset uuid) returns numeric
language sql stable security definer set search_path = '' as $fn$
  select case when sri_os.fn_asset_units(p_asset) > 0
              then sri_os.fn_asset_lot_cost(p_asset) / sri_os.fn_asset_units(p_asset)
         end;
$fn$;

comment on function fn_asset_average_unit_cost(uuid) is
  'ต้นทุนถัวเฉลี่ยต่อหน่วย (D-112) คำนวณใหม่จากทะเบียนล็อตทุกครั้ง — **ไม่รับต้นทุนจากผู้เรียก** · ไม่ปัดค่าเฉลี่ย (ปัดแล้วคูณกลับจะคลาดจากยอดกอง)';

/**
 * รายงานทรัพย์ที่ **สมุดกับทะเบียนล็อตไม่ตรงกัน** — ใช้ตรวจก่อน/หลังนำเข้า
 *
 * ไม่ทำเป็น trigger บังคับทุกใบโดยตั้งใจ: ใบยอดยกมาของพอร์ตอาจถูกลงเป็นก้อนรวม
 * ต่อผู้ถือ (ไฟล์ 2 เป็นบัญชีคุม) ซึ่งไม่ผูกทรัพย์ → ต้นทุนในสมุดต่อทรัพย์จะเป็น 0
 * ทั้งที่ทะเบียนมีล็อตจริง · ด่านที่บังคับคือ **ตอนขาย** (ข้อ 5) ซึ่งเป็นจุดที่
 * ความต่างทำให้ตัวเลขผิดจริง
 */
create or replace function fn_asset_lot_mismatch()
returns table (asset_id uuid, lot_cost numeric, ledger_cost numeric, diff numeric)
language sql stable security definer set search_path = '' as $fn$
  select a.id,
         sri_os.fn_asset_lot_cost(a.id),
         sri_os.fn_asset_cost_basis(a.id),
         round(sri_os.fn_asset_lot_cost(a.id) - sri_os.fn_asset_cost_basis(a.id), 2)
    from sri_os.assets a
   where exists (select 1 from sri_os.asset_lots l where l.asset_id = a.id)
     and abs(round(sri_os.fn_asset_lot_cost(a.id) - sri_os.fn_asset_cost_basis(a.id), 2)) > 0.01;
$fn$;

-- **ต้องถอนจาก `public` ด้วย** ไม่ใช่แค่ `authenticated`
-- (ฟังก์ชันใหม่ได้ execute ให้ PUBLIC มาตั้งแต่เกิดตามค่าปริยายของ Postgres →
--  ถอนแต่ชื่อ role แล้วสิทธิ์ยังอยู่ผ่าน PUBLIC · guard ท้ายไฟล์จับข้อนี้ได้จริง)
do $$
declare f text;
begin
  foreach f in array array['sri_os.fn_asset_lot_remaining(uuid)',
                           'sri_os.fn_asset_units(uuid)',
                           'sri_os.fn_asset_lot_cost(uuid)',
                           'sri_os.fn_asset_average_unit_cost(uuid)',
                           'sri_os.fn_asset_lot_mismatch()'] loop
    execute format('revoke all on function %s from public', f);
    execute format('revoke all on function %s from anon, authenticated', f);
  end loop;
end $$;

-- ============================================================
-- 4 · append-only จริง — ล็อตที่ผูกใบในสมุดแล้ว แก้/ลบไม่ได้
-- ============================================================
create or replace function fn_assert_lot_append_only() returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  if tg_op = 'DELETE' then
    raise exception 'ลบล็อตที่ลงไว้แล้วไม่ได้ (กฎเหล็กข้อ 1) — ถ้าล็อตผิด ให้กลับรายการใบที่สร้างมันแล้วลงล็อตใหม่ · ต้นทุนถัวเฉลี่ยคิดจากทะเบียนนี้ การลบแถวคือการเปลี่ยนต้นทุนย้อนหลังโดยไม่มีร่องรอย';
  end if;
  raise exception 'แก้ล็อตที่ลงไว้แล้วไม่ได้ (กฎเหล็กข้อ 1) — ให้กลับรายการใบที่สร้างมันแล้วลงล็อตใหม่ · ที่แก้ได้คือการบันทึก "ขายออก" เพิ่ม (asset_lot_consumptions)';
end $fn$;

revoke all on function fn_assert_lot_append_only() from public;
do $$ begin execute 'revoke all on function sri_os.fn_assert_lot_append_only() from anon, authenticated'; end $$;

drop trigger if exists trg_lots_append_only on asset_lots;
create trigger trg_lots_append_only
  before update or delete on asset_lots
  for each row execute function fn_assert_lot_append_only();

drop trigger if exists trg_lot_consumptions_append_only on asset_lot_consumptions;
create trigger trg_lot_consumptions_append_only
  before update or delete on asset_lot_consumptions
  for each row execute function fn_assert_lot_append_only();

-- ============================================================
-- 5 · ด่านของการขายออก — **ต้นทุนถัวเฉลี่ยที่คำนวณใหม่ ไม่ใช่ค่าที่ส่งมา**
--
-- ยิงแบบ deferred ต่อใบ เพราะใบหนึ่งตัดได้หลายล็อต (ต้องเห็นครบทั้งใบก่อนตัดสิน)
-- ============================================================
create or replace function fn_assert_lot_consumption_sane_for(p_txn uuid) returns void
language plpgsql security definer set search_path = '' as $fn$
declare
  r           record;
  v_bad       record;
  v_qty       numeric;
  v_cost      numeric;
  v_units0    numeric;   -- จำนวนคงเหลือ "ก่อนใบนี้"
  v_cost0     numeric;   -- ต้นทุนคงเหลือ "ก่อนใบนี้"
  v_expected  numeric;
  v_ledger    numeric;
begin
  -- (ก) ห้ามล็อตไหนถูกตัดเกินจำนวนที่มี (ตรวจทุกล็อตที่ใบนี้แตะ)
  for v_bad in
    select c.lot_id, sri_os.fn_asset_lot_remaining(c.lot_id) as remaining
      from sri_os.asset_lot_consumptions c
     where c.txn_id = p_txn
     group by c.lot_id
  loop
    if round(v_bad.remaining, 8) < 0 then
      raise exception 'ตัดล็อต % ออกมากกว่าจำนวนที่มี (คงเหลือหลังใบนี้ %) — จำนวนคงเหลือคำนวณจากทะเบียนล็อตหักส่วนที่ขายไปแล้ว ไม่ใช่จาก assets.units ที่แก้มือได้',
        v_bad.lot_id, round(v_bad.remaining, 8);
    end if;
  end loop;

  -- (ข) ต่อทรัพย์หนึ่งชิ้นที่ใบนี้ตัด: ต้นทุนที่ตัดต้องเท่ากับ **ถัวเฉลี่ย × จำนวน**
  for r in
    select l.asset_id,
           sum(c.quantity) as qty,
           sum(c.cost_thb) as cost
      from sri_os.asset_lot_consumptions c
      join sri_os.asset_lots l on l.id = c.lot_id
     where c.txn_id = p_txn
     group by l.asset_id
  loop
    v_qty := r.qty;
    v_cost := r.cost;
    -- สภาพก่อนใบนี้ = ของตอนนี้ + ที่ใบนี้ตัดออกไป (คำนวณย้อน ไม่ได้เก็บไว้)
    v_units0 := round(sri_os.fn_asset_units(r.asset_id) + v_qty, 8);
    v_cost0  := round(sri_os.fn_asset_lot_cost(r.asset_id) + v_cost, 2);

    if v_units0 <= 0 then
      raise exception 'ทรัพย์ % ไม่มีหน่วยคงเหลือในทะเบียนล็อตก่อนใบนี้ จึงตัดออกไม่ได้ — ต้องลงล็อตที่ซื้อเข้ามาก่อน (ยอดยกมาของพอร์ตต้องลงรายล็อตด้วย)',
        r.asset_id;
    end if;
    if round(v_qty, 8) > round(v_units0, 8) then
      raise exception 'ขายทรัพย์ % ออก % หน่วย แต่ทะเบียนล็อตมี % หน่วย — ขายมากกว่าที่ถือไม่ได้',
        r.asset_id, round(v_qty, 8), round(v_units0, 8);
    end if;

    /**
     * **สมการถัวเฉลี่ย (D-112)** — ขายหมดต้องตัดต้นทุนทั้งกองพอดี ไม่เหลือเศษ
     * ยอมคลาดได้ 0.01 ซึ่งคือการปัดของการหารครั้งเดียว · และเพราะเทียบกับ
     * ยอดที่คำนวณใหม่ทั้งก้อนทุกครั้ง ความคลาดจึงสะสมไม่ได้
     */
    if round(v_qty, 8) = round(v_units0, 8) then
      v_expected := v_cost0;
    else
      v_expected := round(v_cost0 * v_qty / v_units0, 2);
    end if;

    if abs(round(v_cost - v_expected, 2)) > 0.01 then
      raise exception 'ต้นทุนที่ตัดออกของทรัพย์ % ต้องเป็น % บาท (ต้นทุนคงเหลือ % × % ÷ % หน่วย ตามต้นทุนถัวเฉลี่ย D-112) แต่บันทึกมา % บาท — **ต้นทุนถัวเฉลี่ยคำนวณจากทะเบียนล็อต ไม่ใช่ค่าที่ส่งเข้ามา** · ส่งค่าผิดมาจะถูกปฏิเสธ ไม่ใช่ถูกใช้',
        r.asset_id, v_expected, v_cost0, round(v_qty, 8), round(v_units0, 8), v_cost;
    end if;

    /**
     * (ค) **สมุดกับทะเบียนย่อยต้องเล่าเรื่องเดียวกัน**
     * ต้นทุนคงเหลือในสมุด (`fn_asset_cost_basis` · แหล่งความจริงของงบ) ต้องเท่ากับ
     * ต้นทุนคงเหลือในทะเบียนล็อตหลังใบนี้ · ถ้าไม่เท่า แปลว่าใบที่สร้างต้นทุนไม่ได้
     * ผูกทรัพย์ (เช่นยอดยกมาลงเป็นก้อนรวม) หรือใบขายตัดต้นทุนคนละยอดกับทะเบียน
     * — ปล่อยผ่านคือปล่อยให้งบกับทะเบียนต่างกันเงียบๆ แล้วไม่มีใครรู้ว่าอันไหนถูก
     */
    v_ledger := sri_os.fn_asset_cost_basis(r.asset_id);
    if abs(round(v_ledger - sri_os.fn_asset_lot_cost(r.asset_id), 2)) > 0.01 then
      raise exception 'ต้นทุนคงเหลือของทรัพย์ % ในสมุด (% บาท) ไม่ตรงกับทะเบียนล็อต (% บาท) — ต้องตรงกันเสมอ · สาเหตุที่พบบ่อย: ใบยอดยกมาของพอร์ตลงเป็นก้อนรวมโดยไม่ผูกทรัพย์ (ต้องลงต่อทรัพย์และผูก asset_id ทั้งที่หัวรายการและบรรทัดบัญชีทรัพย์) หรือใบขายตัดต้นทุนในสมุดคนละยอดกับที่ตัดในทะเบียน',
        r.asset_id, round(v_ledger, 2), sri_os.fn_asset_lot_cost(r.asset_id);
    end if;
  end loop;
end $fn$;

comment on function fn_assert_lot_consumption_sane_for(uuid) is
  'ด่านของการตัดล็อต: ตัดเกินจำนวนที่มีไม่ได้ · ต้นทุนที่ตัดต้องเท่ากับต้นทุนถัวเฉลี่ยที่ **คำนวณใหม่จากทะเบียน** (ส่งค่าผิดมาถูกปฏิเสธ) · และต้นทุนคงเหลือในสมุด (fn_asset_cost_basis) ต้องเท่ากับในทะเบียนล็อตหลังใบนั้น';

revoke all on function fn_assert_lot_consumption_sane_for(uuid) from public;
do $$ begin execute 'revoke all on function sri_os.fn_assert_lot_consumption_sane_for(uuid) from anon, authenticated'; end $$;

create or replace function fn_assert_lot_consumption_sane() returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  perform sri_os.fn_assert_lot_consumption_sane_for(coalesce(new.txn_id, old.txn_id));
  return null;
end $fn$;

revoke all on function fn_assert_lot_consumption_sane() from public;
do $$ begin execute 'revoke all on function sri_os.fn_assert_lot_consumption_sane() from anon, authenticated'; end $$;

drop trigger if exists trg_lot_consumption_sane on asset_lot_consumptions;
create constraint trigger trg_lot_consumption_sane
  after insert on asset_lot_consumptions
  deferrable initially deferred
  for each row execute function fn_assert_lot_consumption_sane();

-- ============================================================
-- 6 · ล็อตสกุลต่างประเทศ **ต้องมีอัตรา** และอัตราต้องตรงตารางอัตรา
--     (check constraint บังคับรูปได้ แต่ "ตรงกับอัตราที่ประกาศ" ต้องใช้ trigger)
-- ============================================================
create or replace function fn_assert_lot_fx() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_asset_ccy  text;
  v_table_rate numeric;
begin
  select a.currency into v_asset_ccy from sri_os.assets a where a.id = new.asset_id;

  /**
   * ทรัพย์ที่สกุลไม่ใช่บาท (หุ้นต่างประเทศ · คริปโต) **ต้องมีอัตราวันซื้อ**
   * สกุลอ่านจาก `assets.currency` (ข้อมูลอ้างอิงของทรัพย์) ไม่ใช่จากค่าที่ส่งมากับล็อต
   * — ถ้าเชื่อค่าที่ส่งมา ล็อต USD ที่ "ไม่ส่งสกุล" จะถูกนับเป็นบาททั้งก้อน
   * (รูปเดียวกับรูที่ถูก BLOCK ในเรื่อง FCD · D-115)
   */
  if v_asset_ccy is not null and v_asset_ccy <> 'THB' then
    if new.currency is null then
      raise exception 'ทรัพย์นี้เป็นสกุล % — ล็อตต้องระบุสกุลเงิน ยอดในสกุลเดิม อัตราวันซื้อ และวันของอัตราให้ครบ · **ลงเป็นบาทเฉยๆ ไม่ได้** เพราะต้นทุนบาทจะกลายเป็นตัวเลขที่ไม่มีใครรู้ว่ามาจากอัตราไหน และกำไรตอนขายจะผิดทั้งก้อน',
        v_asset_ccy;
    end if;
    if new.currency <> v_asset_ccy then
      raise exception 'ล็อตของทรัพย์สกุล % ระบุสกุล % — สกุลของล็อตต้องเป็นสกุลของทรัพย์ (อ่านจาก assets.currency ไม่ใช่จากค่าที่ส่งมา)',
        v_asset_ccy, new.currency;
    end if;
  end if;

  if new.currency is not null then
    select f.thb_per_unit into v_table_rate
      from sri_os.fx_rates f
     where f.currency = new.currency and f.rate_date = new.fx_rate_date;
    if v_table_rate is not null and new.fx_rate <> v_table_rate then
      raise exception 'อัตราของล็อตนี้ (%) ไม่เท่ากับอัตราในตารางอัตราแลกเปลี่ยนของ % วันที่ % (ประกาศไว้ %) — อัตราที่ใช้คิดต้นทุนต้องเป็นอัตราที่ประกาศไว้ ไม่ใช่ตัวเลขที่พิมพ์เอง',
        new.fx_rate, new.currency, new.fx_rate_date, v_table_rate;
    end if;
    if new.fx_rate_date > new.acquired_date then
      raise exception 'วันของอัตรา (%) อยู่หลังวันที่ซื้อ (%) — ต้นทุนต้องคิดด้วยอัตรา ณ วันซื้อ ไม่ใช่อัตราของอนาคต (ถ้าวันซื้อเป็นวันหยุดและไม่มีอัตรา ให้ใช้อัตราของวันทำการก่อนหน้า)',
        new.fx_rate_date, new.acquired_date;
    end if;
  end if;

  return new;
end $fn$;

comment on function fn_assert_lot_fx() is
  'ล็อตของทรัพย์สกุลต่างประเทศต้องมีอัตราวันซื้อครบ (สกุลอ่านจาก assets.currency ไม่ใช่จากค่าที่ส่งมา) · อัตราต้องเท่ากับที่ประกาศใน fx_rates ของวันนั้น และต้องไม่เป็นอัตราของอนาคต';

revoke all on function fn_assert_lot_fx() from public;
do $$ begin execute 'revoke all on function sri_os.fn_assert_lot_fx() from anon, authenticated'; end $$;

drop trigger if exists trg_lots_fx on asset_lots;
create trigger trg_lots_fx
  before insert on asset_lots
  for each row execute function fn_assert_lot_fx();

-- ============================================================
-- 7 · RLS — ขอบเขตเดียวกับ asset_valuations (ผ่านทรัพย์)
--     ไม่มี policy UPDATE/DELETE → แก้ไม่ได้ทั้งสองชั้น (RLS + trigger)
-- ============================================================
alter table asset_lots enable row level security;
alter table asset_lot_consumptions enable row level security;

drop policy if exists lots_by_asset on asset_lots;
create policy lots_by_asset on asset_lots
  for select to authenticated
  using (exists (
    select 1 from assets a
     where a.id = asset_id and fn_can_see_owner(a.owner_id) and fn_can_see_asset(a.id)
  ));

drop policy if exists lots_insert on asset_lots;
create policy lots_insert on asset_lots
  for insert to authenticated
  with check (
    fn_can('asset.manage')
    and exists (
      select 1 from assets a
       where a.id = asset_id and fn_can_see_owner(a.owner_id) and fn_can_see_asset(a.id)
    )
  );

drop policy if exists lot_consumptions_by_asset on asset_lot_consumptions;
create policy lot_consumptions_by_asset on asset_lot_consumptions
  for select to authenticated
  using (exists (
    select 1 from asset_lots l join assets a on a.id = l.asset_id
     where l.id = lot_id and fn_can_see_owner(a.owner_id) and fn_can_see_asset(a.id)
  ));

drop policy if exists lot_consumptions_insert on asset_lot_consumptions;
create policy lot_consumptions_insert on asset_lot_consumptions
  for insert to authenticated
  with check (
    fn_can('asset.manage')
    and exists (
      select 1 from asset_lots l join assets a on a.id = l.asset_id
       where l.id = lot_id and fn_can_see_owner(a.owner_id) and fn_can_see_asset(a.id)
    )
  );

-- ============================================================
-- 8 · ด่านคอลัมน์ (D-089) — ตารางใหม่ที่ไม่ขึ้นทะเบียน = guard แดง
--     ทุกคอลัมน์เป็น `row` ด้วย `asset.view_assigned` เหมือนตัวเลขของ asset_valuations
--     (ไม่มีคอลัมน์ไหนเป็น `open` โดยเจตนา — ล็อตคือต้นทุนจริงของพอร์ต)
-- ============================================================
insert into column_exposure_tables (table_name, review_state, reason) values
  ('asset_lots', 'classified',
   'ทะเบียนล็อตต้นทุนรายตัว · แถวถูกกรองด้วยขอบเขตทรัพย์ (fn_can_see_owner + fn_can_see_asset) แบบเดียวกับ asset_valuations · ไม่มี policy UPDATE/DELETE และมี trigger append-only อีกชั้น'),
  ('asset_lot_consumptions', 'classified',
   'ส่วนที่ขายออกของแต่ละล็อต · แถวถูกกรองผ่านล็อต → ทรัพย์ → ผู้ถือ ด้วยฟังก์ชันชุดเดียวกับ asset_lots')
on conflict (table_name) do update
  set review_state = excluded.review_state, reason = excluded.reason;

insert into column_exposure (table_name, column_name, exposure, min_permission, rationale)
select t.tbl, c, 'row', 'asset.view_assigned', t.why
  from (values
    ('asset_lots', array[
      'id', 'asset_id', 'acquired_date', 'quantity', 'cost_thb',
      'currency', 'amount_original', 'fx_rate', 'fx_rate_date',
      'source_txn_id', 'note', 'created_by', 'created_at'
    ], 'ต้นทุนและจำนวนรายล็อตของพอร์ต = ตัวเลขเงินและข้อมูลที่ประกอบเป็นต้นทุน · แถวถูกกรองด้วยขอบเขตทรัพย์ (fn_can_see_asset) เหมือนตัวเลขของ asset_valuations'),
    ('asset_lot_consumptions', array[
      'id', 'lot_id', 'txn_id', 'quantity', 'cost_thb', 'created_by', 'created_at'
    ], 'จำนวนและต้นทุนที่ตัดออกตอนขาย = ตัวเลขเงิน · แถวถูกกรองผ่านล็อตไปถึงขอบเขตทรัพย์ชุดเดียวกัน')
  ) as t(tbl, cols, why), unnest(t.cols) c
on conflict (table_name, column_name) do update
  set exposure = excluded.exposure, min_permission = excluded.min_permission,
      rationale = excluded.rationale;

select fn_apply_column_exposure();

-- ============================================================
-- 8b · ร่องรอย (audit) + ห้าม TRUNCATE — **กฎทั้งระบบ ไม่ใช่ทางเลือก**
--
-- ด่านของ 20261008000005 บังคับว่าทุกตารางใน `sri_os` ต้องมี audit ที่ครอบ
-- insert+update+delete และด่านของ 20261008000004 บังคับว่าต้อง TRUNCATE ไม่ได้
-- (TRUNCATE ไม่ยิง row trigger → ล้างทะเบียนล็อตทั้งตารางได้ในคำสั่งเดียว
--  และ audit ที่ควรบันทึกการลบจะไม่มีอะไรเลย)
-- ตารางใหม่ของไฟล์นี้จึงต้องติดทั้งสองอย่าง ไม่งั้นเทสต์ทั้งระบบแดง (เจอจริงตอนรัน)
-- ============================================================
drop trigger if exists trg_audit_asset_lots on asset_lots;
create trigger trg_audit_asset_lots
  after insert or update or delete on asset_lots
  for each row execute function fn_audit();

drop trigger if exists trg_audit_asset_lot_consumptions on asset_lot_consumptions;
create trigger trg_audit_asset_lot_consumptions
  after insert or update or delete on asset_lot_consumptions
  for each row execute function fn_audit();

drop trigger if exists trg_forbid_truncate on asset_lots;
create trigger trg_forbid_truncate
  before truncate on asset_lots
  for each statement execute function fn_forbid_truncate();

drop trigger if exists trg_forbid_truncate on asset_lot_consumptions;
create trigger trg_forbid_truncate
  before truncate on asset_lot_consumptions
  for each statement execute function fn_forbid_truncate();

-- ============================================================
-- 9 · guard ท้ายไฟล์ — ดังตอน migrate ไม่ใช่ตอนผู้ใช้กด
-- ============================================================
do $$
declare v text; n int;
begin
  -- (ก) ตาราง + ด่านต้องอยู่จริง
  if to_regclass('sri_os.asset_lots') is null or to_regclass('sri_os.asset_lot_consumptions') is null then
    raise exception 'ตารางล็อตไม่ถูกสร้าง';
  end if;
  select string_agg(x.want, ', ') into v
    from (values ('trg_lots_append_only'), ('trg_lots_fx')) x(want)
   where not exists (select 1 from pg_trigger g
                      where g.tgrelid = 'sri_os.asset_lots'::regclass
                        and g.tgname = x.want and not g.tgisinternal);
  if v is not null then raise exception 'trigger หายไปจาก asset_lots: %', v; end if;

  select string_agg(x.want, ', ') into v
    from (values ('trg_lot_consumptions_append_only'), ('trg_lot_consumption_sane')) x(want)
   where not exists (select 1 from pg_trigger g
                      where g.tgrelid = 'sri_os.asset_lot_consumptions'::regclass
                        and g.tgname = x.want and not g.tgisinternal);
  if v is not null then raise exception 'trigger หายไปจาก asset_lot_consumptions: %', v; end if;

  -- audit + ห้าม TRUNCATE ของทั้งสองตาราง (กฎทั้งระบบ · 20261008000004/5)
  select string_agg(t.rel || '/' || x.want, ', ') into v
    from (values ('asset_lots'), ('asset_lot_consumptions')) t(rel),
         (values ('trg_audit_asset_lots'), ('trg_forbid_truncate')) x(want)
   where (x.want <> 'trg_audit_asset_lots'
          or t.rel = 'asset_lots')
     and not exists (select 1 from pg_trigger g
                      where g.tgrelid = ('sri_os.' || t.rel)::regclass
                        and g.tgname = case when x.want = 'trg_audit_asset_lots' and t.rel = 'asset_lot_consumptions'
                                            then 'trg_audit_asset_lot_consumptions' else x.want end
                        and not g.tgisinternal);
  if v is not null then raise exception 'ขาด audit/ด่าน TRUNCATE: %', v; end if;

  -- (ข) ด่านตัดล็อตต้องคำนวณจากทะเบียน ไม่ใช่รับค่าจากผู้เรียก
  v := pg_get_functiondef('sri_os.fn_assert_lot_consumption_sane_for(uuid)'::regprocedure);
  if v !~ 'fn_asset_lot_cost' or v !~ 'fn_asset_units' or v !~ 'fn_asset_cost_basis' then
    raise exception 'ด่านตัดล็อตไม่ได้คำนวณจากทะเบียน/สมุด — มีไฟล์อื่นเขียนทับหลังไฟล์นี้';
  end if;

  -- (ค) ไม่มี policy UPDATE/DELETE ของสองตารางนี้ (append-only ที่ชั้น RLS ด้วย)
  select string_agg(p.polname, ', ') into v
    from pg_policy p
   where p.polrelid in ('sri_os.asset_lots'::regclass, 'sri_os.asset_lot_consumptions'::regclass)
     and p.polcmd in ('w', 'd');
  if v is not null then
    raise exception 'มี policy UPDATE/DELETE ของตารางล็อต (%) — ต้องไม่มี ทะเบียนนี้เป็น append-only', v;
  end if;

  -- (ง) ฟังก์ชันคำนวณ/ด่านต้องเรียกตรงไม่ได้ (D-089)
  select string_agg(x.f, ', ') into v
    from unnest(array['sri_os.fn_asset_units(uuid)',
                      'sri_os.fn_asset_lot_cost(uuid)',
                      'sri_os.fn_asset_average_unit_cost(uuid)',
                      'sri_os.fn_asset_lot_remaining(uuid)',
                      'sri_os.fn_asset_lot_mismatch()',
                      'sri_os.fn_assert_lot_consumption_sane_for(uuid)']) x(f)
   where has_function_privilege('authenticated', x.f, 'execute')
      or has_function_privilege('anon', x.f, 'execute');
  if v is not null then
    raise exception 'ฟังก์ชันของทะเบียนล็อตยังเรียกตรงได้: % = ทางข้ามขอบเขตทรัพย์', v;
  end if;

  -- (จ) ด่านคอลัมน์ต้องไม่มีของค้างจากตารางใหม่
  select string_agg(u.object_name || ': ' || u.problem, ' · ') into v
    from sri_os.fn_column_exposure_unclassified() u
   where u.object_name like 'asset_lot%';
  if v is not null then
    raise exception 'ด่านคอลัมน์ยังมีของค้างจากตารางล็อต (D-089): %', v;
  end if;

  raise notice 'ทะเบียนล็อตพร้อม: จำนวนคงเหลือและต้นทุนถัวเฉลี่ยคำนวณใหม่จากทะเบียนทุกครั้ง (assets.units ไม่ใช่แหล่งความจริง) · ล็อตสกุลต่างประเทศต้องมีอัตราวันซื้อที่ตรงกับตารางอัตรา · append-only ทั้ง RLS และ trigger · ตอนขายต้นทุนต้องเท่ากับถัวเฉลี่ยที่คำนวณใหม่ และสมุดต้องตรงกับทะเบียน';
end $$;
