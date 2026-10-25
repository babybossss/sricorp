-- ============================================================
-- SRI OS · **ประตูอัปโหลดยอดตั้งต้นใช้งานได้จริงในฐานะ `authenticated`**
--            ปิดสองรูที่เทสต์แบบ superuser มองไม่เห็นเลย
--
-- ------------------------------------------------------------
-- **บทเรียนที่ต้องจดไว้ (สำคัญกว่าตัวบั๊ก)**
--
-- เทสต์ที่รันด้วยสิทธิ์สูงกว่าผู้ใช้จริง **พิสูจน์อะไรเกี่ยวกับสิทธิ์/RLS ไม่ได้เลย**
-- `20261025000009` เขียวทั้งไฟล์ ทั้งที่ฟีเจอร์ใช้ไม่ได้บนของจริง — เพราะทุกเคส
-- รันเป็น superuser ซึ่ง **ข้ามทั้ง `GRANT` และ RLS** · ต่อจากนี้เคสที่แตะสิทธิ์
-- ต้อง `set local role authenticated` + ตั้ง `test.uid` ไม่ใช่รันเป็นเจ้าของสคีมา
--
-- ------------------------------------------------------------
-- **บั๊ก 1 · `fn_reimport_opening` เรียกไม่ได้เลย (permission denied)**
--
-- ประตูเป็น `security invoker` โดยตั้งใจ (definer = ทางข้ามสิทธิ์ทั้งชุด)
-- แต่มันเรียก `fn_opening_set()` / `fn_opening_fingerprint()` ซึ่งไฟล์ 0009
-- **ถอน execute จาก `authenticated` ไปแล้ว** → ผู้ใช้จริงได้
--   `permission denied for function fn_opening_set`
-- = **นำเข้ายอดตั้งต้นใหม่ทำไม่ได้เลย** ทั้งที่เทสต์เขียวหมด
--
-- **ทำไมไม่แค่ `grant execute` เฉยๆ**: ทั้งสองตัวเป็น `security definer`
-- ที่อ่าน `transactions` / `asset_lots` ของผู้ถือที่ส่งเข้ามา → เปิดให้เรียกตรงๆ
-- คือ **ทางข้าม RLS** (ลายนิ้วมือและรายการ id ของผู้ถืออื่นรั่ว · D-089 จัดคลาสนี้
-- ว่า row_escape) · ไฟล์นี้จึงทำสองอย่าง **คู่กัน**:
--   1. ใส่ด่านขอบเขตผู้ถือ **ไว้ในตัวฟังก์ชันเอง** (`fn_can_see_owner`)
--      → definer ที่ตรวจสิทธิ์เองแล้วไม่ใช่ทางข้ามอีก
--   2. แล้วจึง `grant execute` ให้ `authenticated`
-- (รูปเดียวกับ `fn_post_entry` ที่เป็น definer ได้เพราะตรวจสิทธิ์ครบในตัว)
--
-- ------------------------------------------------------------
-- **บั๊ก 2 · ผู้ถือที่มีล็อต อัปโหลดแก้ไม่ได้ (เงียบ ไม่ error)**
--
-- `fn_reimport_opening` ทำ `update asset_lots set reversed_by_txn_id = ...`
-- เพื่อติดร่องรอยการกลับรายการ แต่ `asset_lots` **มีแต่ policy SELECT/INSERT**
-- → RLS กรองทิ้งทุกแถว → `UPDATE 0` **ไม่ error** → ล็อตเดิมไม่ถูกปิด
-- → ลงล็อตใหม่ทับ = ล็อตซ้ำ = ต้นทุนสองชุด
-- ด่านลายนิ้วมือปลายทางจับได้แล้วย้อนทั้งคำสั่ง (ยืนยัน D-116 ว่าด่านตรวจ
-- **ผลลัพธ์** จำเป็นจริง) แต่ฟีเจอร์ก็ยังใช้ไม่ได้
--
-- **policy UPDATE ที่เพิ่มแคบที่สุดเท่าที่ทำได้**: ต้องมีสิทธิ์ `asset.manage`
-- เห็นทรัพย์ชิ้นนั้นได้ และแถวที่แก้ต้อง **ยังไม่ถูกกลับรายการ** (`using`)
-- และหลังแก้ต้อง **ถูกกลับรายการแล้ว** (`with check`) → policy เปิดทางเดียว
-- ส่วน "ห้ามแก้คอลัมน์อื่น" ยังเป็นหน้าที่ของ `fn_assert_lot_append_only()`
-- ซึ่งพิสูจน์ร่องรอยจากสมุดอยู่แล้ว (RLS กรองแถวได้ แต่กรองคอลัมน์ไม่ได้ →
-- สองชั้นนี้ต้องมีทั้งคู่)
--
-- ------------------------------------------------------------
-- **ผลการไล่หารูปแบบเดียวกันในไฟล์อื่น** (เขียนไว้เพราะเป็นคลาส ไม่ใช่เคส)
--
--   รูปแบบ ก · *invoker เรียก definer ที่ถอน execute แล้ว* — มีที่เดียวคือรูนี้
--     ไฟล์ 20261025000010/11: ฟังก์ชันด่านทั้งหมดถูกเรียกจาก **trigger**
--     ซึ่งรันด้วยสิทธิ์ของเจ้าของ trigger ไม่ใช่ของผู้เรียก → ถอน execute
--     จาก `authenticated` ได้โดยไม่กระทบ (และต้องถอน ตาม D-089)
--     ตัวที่ผู้เรียกอาจเรียกเองมีสองตัว (`fn_asset_cost_basis_mode`,
--     `fn_asset_can_average`) — **0010 grant ให้ `authenticated` ไว้แล้ว**
--     และทั้งคู่ไม่รั่วอะไร: คืนกฎของ *หมวด* ซึ่ง `asset_categories_read`
--     เปิดให้อ่านอยู่แล้ว (ไม่ใช่ตัวเลขเงิน และไม่ขึ้นกับผู้ถือ)
--     `fn_asset_cost_basis_mode_mismatch()` ถอนทั้ง anon/authenticated
--     (ไล่ทรัพย์ทุกชิ้น = definer ที่รั่วได้) → ใช้ได้เฉพาะงานตรวจด้วย service role
--
--   รูปแบบ ข · *ต้อง UPDATE แต่ไม่มี policy* — ไล่ทุกตารางที่ไฟล์เหล่านี้แตะ:
--     `asset_lots` = รูนี้ (ปิดในไฟล์นี้) · `asset_lot_consumptions` **ไม่ต้องมี**
--     (append-only จริง · ไม่มีโค้ดไหน UPDATE และ trigger ห้ามอยู่แล้ว) ·
--     `asset_categories` เขียนด้วย migration เท่านั้นโดยเจตนา (ไม่มี policy เขียน
--     = ถูกต้อง) · `transactions`/`transaction_lines` ไปผ่าน `fn_post_entry`
--     ซึ่งเป็น definer ที่ตรวจสิทธิ์ครบ · guard ท้ายไฟล์นี้ตรวจข้อ
--     `asset_lot_consumptions` ไว้ด้วย เพื่อให้ "ไม่มี policy" เป็นการตัดสินใจ
--     ที่มีคนตรวจ ไม่ใช่ของที่ลืม
--
-- ------------------------------------------------------------
-- ลำดับ: **ต้องรันหลัง** 20261025000008 และ 20261025000009
--
-- idempotent: `create or replace` · `drop policy if exists` ก่อน create
--
-- ย้อนกลับ (rollback):
--   -- drop policy if exists lots_mark_reversed on sri_os.asset_lots;
--   -- รัน supabase/migrations/20261025000009_reimport_opening.sql ซ้ำ (idempotent)
--   --   เพื่อคืน fn_opening_set / fn_opening_fingerprint เป็นรุ่นที่ถอน execute
--   ⚠ ถอดแล้ว **การนำเข้ายอดตั้งต้นใช้ไม่ได้อีก** สำหรับผู้ใช้จริงทุกคน
-- ============================================================

set search_path = sri_os, public;

do $$
begin
  if to_regprocedure('sri_os.fn_opening_set(uuid)') is null
     or to_regprocedure('sri_os.fn_opening_fingerprint(uuid)') is null then
    raise exception 'ไม่มี fn_opening_set / fn_opening_fingerprint → ต้องรัน 20261025000009 ก่อนไฟล์นี้';
  end if;
  if to_regprocedure('sri_os.fn_can_see_owner(uuid)') is null then
    raise exception 'ไม่มี fn_can_see_owner → ต้องรัน 20261006190000_roles_permissions.sql ก่อนไฟล์นี้';
  end if;
  if to_regclass('sri_os.asset_lots') is null then
    raise exception 'ไม่มีตาราง asset_lots → ต้องรัน 20261025000008 ก่อนไฟล์นี้';
  end if;
end $$;

-- ============================================================
-- 1 · สองฟังก์ชันของยอดตั้งต้น — definer ที่ **ตรวจขอบเขตผู้ถือเอง**
--     เนื้อในเหมือนรุ่น 0009 ตัวต่อตัว (ยังอ่านจาก `txn_types.group_code`
--     และจาก `reverses_id` ตามเดิม · guard ของ 0009 ตรวจสองคำนี้อยู่)
--     ที่เพิ่มคือด่านบรรทัดแรก และเปลี่ยนเป็น plpgsql เพื่อ raise ได้
-- ============================================================
create or replace function fn_opening_set(p_owner uuid) returns uuid[]
language plpgsql stable security definer set search_path = '' as $outer$
begin
  /**
   * **definer ที่เปิดให้ผู้ใช้แอปเรียก ต้องถามสิทธิ์ที่ "ครอบ" ตารางที่มันอ่านเอง**
   *
   * ด่าน `fn_column_exposure_row_escapes()` (D-089) จับข้อนี้ตรงๆ: ฟังก์ชันนี้
   * อ่าน `transactions` ซึ่งจัดประเภทเป็น `row` ด้วย `ledger.read`
   * ถ้าเปิดให้เรียกโดยไม่ถามสิทธิ์นั้น = **ข้าม policy ของตารางทั้งใบ**
   * (เจอจริงตอนรันครั้งแรก: guard แดงทันทีและสร้างบัญชี Staff ไม่ได้)
   */
  if not sri_os.fn_can('ledger.read') then
    raise exception 'ไม่มีสิทธิ์อ่านสมุดบัญชี (ledger.read) จึงอ่านชุดยอดตั้งต้นไม่ได้';
  end if;

  /**
   * **definer ต้องตรวจขอบเขตผู้ถือเองด้วย** — สิทธิ์ครอบตารางยังไม่พอ
   * ผู้เรียกที่มองผู้ถือนี้ไม่เห็นต้องถูกปฏิเสธ **เสียงดัง** ไม่ใช่ได้ชุดว่าง
   * (ชุดว่างจะถูกแปลว่า "ผู้ถือนี้ยังไม่มียอดตั้งต้น" แล้วลงทับของจริง)
   */
  if not sri_os.fn_can_see_owner(p_owner) then
    raise exception 'ไม่มีสิทธิ์อ่านยอดตั้งต้นของผู้ถือนี้ — ขอบเขตผู้ถืออ่านจาก user_owner_access ไม่ใช่จากค่าที่ส่งมา';
  end if;

  return (
  -- ใบยอดยกมาของผู้ถือนี้ที่ **ยังไม่มีใบกลับรายการชี้มา** · เรียงให้ผลคงที่
  select coalesce(array_agg(t.id order by t.doc_date, t.created_at, t.id), '{}')
    from sri_os.transactions t
    join sri_os.txn_types ty on ty.code = t.txn_type_code
   where t.owner_id = p_owner
     and ty.group_code = 'opening'
     and t.status = 'posted'
     and t.reverses_id is null
     and not exists (select 1 from sri_os.transactions r where r.reverses_id = t.id)
  );
end $outer$;

comment on function fn_opening_set(uuid) is
  '"ชุดยอดตั้งต้นที่ยังมีผล" ของผู้ถือหนึ่ง — อ่านจากสมุด: ประเภทที่ txn_types.group_code = opening · ยังไม่มีใบกลับรายการชี้มา · ไม่ใช่ป้ายที่ผู้เรียกส่งมา (D-115) · **definer ที่ตรวจขอบเขตผู้ถือเอง** จึงเปิดให้ authenticated เรียกได้โดยไม่เป็นทางข้าม RLS';

create or replace function fn_opening_fingerprint(p_owner uuid) returns text
language plpgsql stable security definer set search_path = '' as $outer$
begin
  -- ลายนิ้วมืออ่านทั้งสมุด (`transactions`/`transaction_lines` · ledger.read)
  -- และทะเบียนล็อต (`asset_lots` · asset.view_assigned) → ต้องถามทั้งสองคีย์
  -- ไม่งั้นด่าน row_escape ของ D-089 ถือว่าเป็นทางข้าม policy ของตารางนั้น
  if not sri_os.fn_can('ledger.read') then
    raise exception 'ไม่มีสิทธิ์อ่านสมุดบัญชี (ledger.read) จึงคิดลายนิ้วมือยอดตั้งต้นไม่ได้';
  end if;
  if not sri_os.fn_can('asset.view_assigned') then
    raise exception 'ไม่มีสิทธิ์อ่านทะเบียนทรัพย์ (asset.view_assigned) จึงคิดลายนิ้วมือยอดตั้งต้นไม่ได้ — ลายนิ้วมือรวมทะเบียนล็อตด้วย';
  end if;
  if not sri_os.fn_can_see_owner(p_owner) then
    raise exception 'ไม่มีสิทธิ์อ่านยอดตั้งต้นของผู้ถือนี้ — ขอบเขตผู้ถืออ่านจาก user_owner_access ไม่ใช่จากค่าที่ส่งมา';
  end if;

  return (
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
        ) y), ''))
  );
end $outer$;

comment on function fn_opening_fingerprint(uuid) is
  'ลายนิ้วมือของเนื้อหายอดตั้งต้นของผู้ถือหนึ่ง (คู่บัญชี · ยอด · บัญชีธนาคาร · ทรัพย์ · วันตัดยอด + ทะเบียนล็อตที่ยังใช้อยู่) · **คำนวณใหม่จากสมุดทุกครั้ง ไม่เก็บไว้** · ไม่รวม memo เพราะข้อความไม่ใช่เหตุให้กลับรายการทั้งชุด · **definer ที่ตรวจขอบเขตผู้ถือเอง**';

-- เปิดให้ `authenticated` เรียกได้ **หลังจากมีด่านในตัวแล้ว** · `anon` ยังปิด
do $$
declare f text;
begin
  foreach f in array array['sri_os.fn_opening_set(uuid)', 'sri_os.fn_opening_fingerprint(uuid)'] loop
    execute format('revoke all on function %s from public', f);
    execute format('revoke all on function %s from anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- ============================================================
-- 2 · policy UPDATE ของ asset_lots — **เปิดทางเดียว: ติดร่องรอยการกลับรายการ**
-- ============================================================
drop policy if exists lots_mark_reversed on asset_lots;
create policy lots_mark_reversed on asset_lots
  for update to authenticated
  using (
    -- แถวที่แก้ได้: ยังไม่ถูกกลับรายการ · อยู่ในขอบเขตทรัพย์ของผู้เรียก · มีสิทธิ์จัดการทรัพย์
    reversed_by_txn_id is null
    and fn_can('asset.manage')
    and exists (
      select 1 from assets a
       where a.id = asset_id and fn_can_see_owner(a.owner_id) and fn_can_see_asset(a.id)
    )
  )
  with check (
    -- ผลลัพธ์ที่ยอม: ถูกกลับรายการแล้วเท่านั้น (ย้อนกลับเป็น null ไม่ได้)
    reversed_by_txn_id is not null
    and fn_can('asset.manage')
    and exists (
      select 1 from assets a
       where a.id = asset_id and fn_can_see_owner(a.owner_id) and fn_can_see_asset(a.id)
    )
  );

-- ============================================================
-- 3 · guard ท้ายไฟล์ — ดังตอน migrate ไม่ใช่ตอนผู้ใช้กด
-- ============================================================
do $$
declare v text;
begin
  -- (ก) ต้องเรียกได้ในฐานะ authenticated จริง
  select string_agg(x.f, ', ') into v
    from (values ('sri_os.fn_opening_set(uuid)'), ('sri_os.fn_opening_fingerprint(uuid)')) x(f)
   where not has_function_privilege('authenticated', x.f::regprocedure, 'execute');
  if v is not null then
    raise exception 'authenticated ยังเรียกไม่ได้: % — ประตูอัปโหลดยอดตั้งต้นจะ permission denied เหมือนเดิม', v;
  end if;

  -- (ข) แต่ anon ต้องยังเรียกไม่ได้ (ทั้งทางชื่อและทาง PUBLIC)
  select string_agg(x.f, ', ') into v
    from (values ('sri_os.fn_opening_set(uuid)'), ('sri_os.fn_opening_fingerprint(uuid)')) x(f)
   where has_function_privilege('anon', x.f::regprocedure, 'execute')
      or has_function_privilege('public', x.f::regprocedure, 'execute');
  if v is not null then raise exception 'anon/PUBLIC เรียกได้: %', v; end if;

  -- (ค) ด่านขอบเขตผู้ถือต้องอยู่ในตัวฟังก์ชันจริง ไม่ใช่หวังว่าผู้เรียกจะตรวจ
  foreach v in array array['sri_os.fn_opening_set(uuid)', 'sri_os.fn_opening_fingerprint(uuid)'] loop
    if pg_get_functiondef(v::regprocedure) !~ 'fn_can_see_owner' then
      raise exception '% เป็น definer ที่ไม่ตรวจขอบเขตผู้ถือ = ทางข้าม RLS (D-089)', v;
    end if;
  end loop;

  -- (ค2) ต้องถามสิทธิ์ที่ "ครอบ" ตารางที่อ่าน ไม่งั้นด่าน row_escape ของ D-089 แดง
  if pg_get_functiondef('sri_os.fn_opening_set(uuid)'::regprocedure) !~ 'ledger\.read' then
    raise exception 'fn_opening_set ไม่ได้ถาม ledger.read — เปิดให้ authenticated เรียกแล้วกลายเป็นทางข้าม policy ของ transactions (D-089)';
  end if;
  v := pg_get_functiondef('sri_os.fn_opening_fingerprint(uuid)'::regprocedure);
  if v !~ 'ledger\.read' or v !~ 'asset\.view_assigned' then
    raise exception 'fn_opening_fingerprint ไม่ได้ถามทั้ง ledger.read และ asset.view_assigned — มันอ่านทั้งสมุดและทะเบียนล็อต (D-089)';
  end if;
  if exists (select 1 from sri_os.fn_column_exposure_row_escapes() e
              where e.function_name in ('fn_opening_set', 'fn_opening_fingerprint')) then
    raise exception 'ยังมีทางข้าม policy จากสองฟังก์ชันนี้ — ด่าน D-089 จะแดงและสร้างบัญชี Staff ไม่ได้';
  end if;

  -- (ง) เนื้อในต้องยังอ่านจากตารางกฎ + สมุด (guard ของ 0009 ตรวจสองคำนี้)
  v := pg_get_functiondef('sri_os.fn_opening_set(uuid)'::regprocedure);
  if v !~ 'group_code' or v !~ 'reverses_id' then
    raise exception 'fn_opening_set ไม่ได้ตัดสินจากตารางกฎ/สมุดอีกแล้ว — การเขียนทับทำกฎเดิมหาย';
  end if;

  -- (จ) ประตูต้องยังเป็น invoker (ไฟล์นี้ไม่ได้แก้ข้อนั้น และห้ามแก้)
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'sri_os' and p.proname = 'fn_reimport_opening' and p.prosecdef) then
    raise exception 'fn_reimport_opening กลายเป็น definer — ต้องเป็น invoker';
  end if;

  -- (ฉ) policy UPDATE ต้องมีจริง ไม่งั้นการติดร่องรอยยังเงียบเหมือนเดิม
  if not exists (select 1 from pg_policies
                  where schemaname = 'sri_os' and tablename = 'asset_lots'
                    and policyname = 'lots_mark_reversed' and cmd = 'UPDATE') then
    raise exception 'ไม่มี policy UPDATE บน asset_lots — update จะกรองทิ้งทุกแถวเงียบๆ';
  end if;

  -- (ช) ตารางการขายออกต้อง **ไม่มี** policy UPDATE/DELETE (append-only จริง)
  select string_agg(policyname || '/' || cmd, ', ') into v
    from pg_policies
   where schemaname = 'sri_os' and tablename = 'asset_lot_consumptions'
     and cmd in ('UPDATE', 'DELETE');
  if v is not null then
    raise exception 'asset_lot_consumptions ไม่ควรมี policy UPDATE/DELETE แต่มี: %', v;
  end if;

  raise notice 'ok · authenticated เรียกฟังก์ชันยอดตั้งต้นได้ (มีด่านขอบเขตผู้ถือในตัว) · asset_lots ติดร่องรอยการกลับรายการได้';
end $$;
