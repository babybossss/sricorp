-- ============================================================
-- SRI OS · ปิดสองช่องที่งาน W2 รายงานไว้เองแต่ยังไม่ได้แก้
--   (ตัดสินแล้วทั้งสองข้อว่าต้องปิด · เทสต์: supabase/tests/zz_valuation_guard_test.sql)
--
-- ปัญหา 1 · ประวัติการตีราคาลบได้ด้วยสิทธิ์เจ้าของฐานข้อมูล
--   `asset_valuations` กัน DELETE ด้วย RLS เท่านั้น (ไม่มี policy DELETE = ปฏิเสธ
--   สำหรับ authenticated) แต่ **ไม่มี trigger** → postgres / service_role ลบได้
--   20261008000001 ทำให้ UPDATE ถูกปฏิเสธไปแล้ว (เพิ่มได้ ลบ-แก้ไม่ได้) แต่ DELETE
--   ยังเปิดอยู่ ซึ่งไม่สมเหตุสมผล: **ถ้าแก้ไม่ได้แต่ลบได้ ก็เท่ากับแก้ได้**
--   (ลบแล้วใส่ใหม่) → มูลค่าพอร์ตย้อนหลังเปลี่ยนได้โดยไม่เหลือร่องรอย
--   ปิดด้วย trigger หลักเดียวกับ fn_forbid_delete_posted (กฎเหล็กข้อ 1 ·
--   Money Invariant 4): ปฏิเสธ **ทุก role รวม superuser** ไม่ขึ้นกับ RLS/grant
--   และกัน TRUNCATE ด้วย fn_forbid_truncate ตัวเดียวกับที่ตารางสมุดบัญชีใช้ —
--   ไม่งั้นช่องเดิมเปิดอยู่แค่เปลี่ยนคำสั่ง (TRUNCATE ไม่ยิง row trigger)
--
-- ปัญหา 2 · ระบบตรวจสุขภาพไม่เคยเตือนทรัพย์ที่ยังไม่เคยตีราคา
--   `fn_health_check` ข้อ 4 กรอง `where is_stale` · ทรัพย์ที่ไม่มีการตีราคาเลยได้
--   is_stale = NULL → **เงียบหายไปจากรายงาน** ทั้งที่เป็นสิ่งที่ควรเตือนที่สุด
--   (ทรัพย์ที่ไม่มีมูลค่าเลย ไม่ใช่ทรัพย์ที่มูลค่าเก่า)
--   เพิ่มเป็น **ข้อที่ 5 แยกธง** ไม่ยุบรวมกับข้อ 4 เพราะวิธีแก้ต่างกัน:
--     ข้อ 4 แดง = ต้องตีราคาใหม่ให้ทันสมัย
--     ข้อ 5 แดง = ยังไม่เคยตีราคาเลย ต้องตีครั้งแรก (และ NAV ขาดทรัพย์ตัวนั้นอยู่)
--   รูปผลลัพธ์ (check_name, ok, detail) **ไม่เปลี่ยน** · 4 ข้อเดิมอยู่ตำแหน่งเดิม
--   ธงใหม่ต่อท้าย → ของที่เรียกอยู่ไม่พัง (ไล่แล้ว: src/** ไม่มีใครเรียก ·
--   ผู้เรียกจริงมีแต่เทสต์ zz_db_hardening_test ที่ยืนยันจำนวนข้อ = ปรับเป็น 5)
--   เงื่อนไขที่ใช้คือ `as_of is null` ของ v_asset_latest_value (left join ไม่ติด
--   = ไม่เคยตีราคา) ไม่ใช่ `value = 0` — 0 หมายถึง "ตีราคาแล้วได้ศูนย์" ซึ่งคนละเรื่อง
--   **ไม่กรองตาม assets.status** โดยตั้งใจ: ข้อ 4 เดิมก็ไม่กรอง และการกรองคือการ
--   ซ่อนแถวซึ่งเป็นต้นเหตุของบั๊กนี้เอง · ถ้าทรัพย์ที่ขายแล้ว (status sold/redeemed)
--   ทำให้ธงนี้แดงค้าง ให้ตัดสินกันก่อนแล้วแก้ที่ **ข้อ 4 และข้อ 5 พร้อมกัน** ไม่ใช่ทีละข้อ
--
-- ถ้าวันหนึ่งต้องลบประวัติการตีราคาจริง (ข้อมูลผิดจนต้องล้าง):
--   **ทำผ่าน migration เท่านั้น** — เขียนไฟล์ใหม่ที่
--     1) drop trigger trg_forbid_delete_valuation
--     2) ลบเฉพาะแถวที่ระบุ id ไว้ตรงๆ ในไฟล์ (ไม่ใช่ลบตามเงื่อนไขกว้างๆ)
--     3) สร้าง trigger กลับทันทีในไฟล์เดียวกัน
--   พร้อมเหตุผลที่หัวไฟล์ว่าใครตัดสินและทำไม
--   **ห้ามปิด trigger ทิ้งไว้** และห้ามเปิดเส้นทางลบจากหน้าจอ/service_role:
--   ร่องรอยการลบมูลค่าย้อนหลังเป็นสิ่งที่ผู้สอบบัญชีต้องเห็น
--
-- ย้อนกลับ (rollback):
--   -- drop trigger if exists trg_forbid_delete_valuation on sri_os.asset_valuations;
--   -- drop trigger if exists trg_forbid_truncate         on sri_os.asset_valuations;
--   -- drop function if exists sri_os.fn_forbid_delete_valuation();
--   -- (ย้อนแล้ว postgres/service_role ลบประวัติการตีราคาได้อีก = ช่องเดิมของ W2)
--   -- คืน fn_health_check รุ่น 4 ข้อ: รัน section 1 ของ
--   --   20261007000007_function_execute_acl.sql ซ้ำ
--   --   (แล้วต้องแก้ supabase/tests/zz_db_hardening_test.sql H4b กลับเป็น 4 ข้อด้วย)
--
-- idempotent: create or replace function · drop trigger if exists ก่อน create ·
--   ไม่แตะข้อมูล ไม่เพิ่ม/ลบคอลัมน์ · revoke/grant ซ้ำได้
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 1 · ห้าม DELETE ประวัติการตีราคา — ทุก role รวม superuser
--
--   ทำไม trigger ไม่ใช่ RLS: RLS มีผลกับ authenticated เท่านั้น และผู้ที่ถือกุญแจ
--   service_role / เจ้าของฐานข้อมูลอยู่นอกชั้นนั้นทั้งหมด (หลักเดียวกับที่
--   20261007000000 เลือก trigger แทน RLS ตอนกัน TRUNCATE)
--
--   ฟังก์ชันนี้ **ไม่ถามสิทธิ์ใดๆ และไม่ต้องอ่านตารางไหน** — การห้ามลบเท่ากัน
--   ทุกตำแหน่ง จึงไม่เป็น SECURITY DEFINER และไม่อ้างตารางสิทธิ์
--   (กฎที่บังคับด้วย trigger ต้องปิดไม่ได้จากหน้า Settings · มีเทสต์ไล่จาก
--    pg_trigger/prosrc ยืนยันข้อนี้อยู่)
-- ============================================================
create or replace function fn_forbid_delete_valuation() returns trigger
language plpgsql set search_path = '' as $fn$
begin
  raise exception 'กฎเหล็กข้อ 1 / Money Invariant 4: ลบประวัติการตีราคาไม่ได้ทุกกรณีทุกผู้ใช้ (รวมเจ้าของฐานข้อมูล) · ราคาที่ตีผิดให้ลงแถวใหม่เป็น revision ถัดไป ของเดิมเก็บเป็นประวัติ (id % · ทรัพย์ % · as_of % · revision %)',
    old.id, old.asset_id, old.as_of, old.revision;
end $fn$;

comment on function fn_forbid_delete_valuation() is
  'ห้ามลบแถวใน asset_valuations ทุก role รวม superuser · ถ้าแก้ไม่ได้แต่ลบได้ ก็เท่ากับแก้ได้ · ต้องลบจริงให้ทำผ่าน migration ที่ drop trigger + ลบตาม id + สร้าง trigger คืนในไฟล์เดียวกัน';

-- trigger function ต้องเรียกจากข้างนอกไม่ได้ (default privileges ของ 20261007000001
-- เปิด execute ให้ authenticated กับฟังก์ชันใหม่ทุกตัว → ต้องถอนทันทีในไฟล์เดียวกัน)
revoke all on function fn_forbid_delete_valuation() from public;
do $$ begin
  execute 'revoke all on function sri_os.fn_forbid_delete_valuation() from anon, authenticated';
exception when undefined_object then
  raise notice 'ไม่มี role anon/authenticated ในคลัสเตอร์นี้ — ข้าม revoke';
end $$;

drop trigger if exists trg_forbid_delete_valuation on asset_valuations;
create trigger trg_forbid_delete_valuation
  before delete on asset_valuations
  for each row execute function fn_forbid_delete_valuation();

-- TRUNCATE ไม่ยิง row trigger และไม่ผ่าน RLS → ล้างประวัติราคาทั้งตารางได้รวดเดียว
-- ใช้ fn_forbid_truncate ตัวเดียวกับตารางสมุดบัญชี (20261007000000) ไม่เขียนกฎซ้ำ
drop trigger if exists trg_forbid_truncate on asset_valuations;
create trigger trg_forbid_truncate
  before truncate on asset_valuations
  for each statement execute function fn_forbid_truncate();

-- ============================================================
-- 2 · fn_health_check: เพิ่มข้อ 5 "ทรัพย์ที่ยังไม่เคยตีราคา"
--
--   ข้อ 1–4 คัดลอกมาจาก 20261007000007 **ทั้งดุ้นไม่แก้** (ลายเซ็น ด่านสิทธิ์
--   search_path = '' SECURITY DEFINER เหมือนเดิม) เพิ่มเฉพาะ return query ข้อ 5
--   create or replace จึงรักษา ACL เดิมไว้ (allow-list ของ 20261007000007)
--   แต่ประกาศซ้ำท้ายไฟล์เพื่อให้ไฟล์นี้รันเดี่ยวๆ ก็ได้สภาพเดียวกัน
-- ============================================================
create or replace function fn_health_check()
returns table(check_name text, ok boolean, detail text)
language plpgsql stable security definer set search_path = '' as $fn$
begin
  -- ด่านของฟังก์ชันนี้เอง · ข้าม RLS ได้แปลว่าต้องถามสิทธิ์ตรงๆ
  -- raise ไม่ใช่ return 0 แถว — "ไม่มีสิทธิ์" กับ "ข้อมูลสุขภาพดี" ต้องแยกกันให้ออก
  if not sri_os.fn_can('settings.manage') then
    raise exception 'ไม่มีสิทธิ์ดูรายงานสุขภาพข้อมูล (ต้องมี settings.manage) · ฟังก์ชันนี้ข้าม RLS และคืน id รายการข้ามผู้ถือ';
  end if;

  -- 1. ทุก transaction สมดุล
  return query
  select 'transactions_balanced'::text,
         not exists (
           select 1 from sri_os.transaction_lines l
            group by l.transaction_id
           having sum(l.debit) <> sum(l.credit)
         ),
         coalesce((
           select string_agg(x.transaction_id::text, ', ')
             from (select l.transaction_id from sri_os.transaction_lines l
                    group by l.transaction_id
                   having sum(l.debit) <> sum(l.credit) limit 10) x
         ), 'ทุกรายการสมดุล');

  -- 2. ไม่มีบรรทัดเงินสดที่ไม่ผูกบัญชี
  return query
  select 'no_floating_cash'::text,
         not exists (
           select 1 from sri_os.transaction_lines l
             join sri_os.chart_of_accounts c on c.id = l.coa_id
            where c.code ~ '^11[0-9][0-9]$' and l.bank_account_id is null
         ),
         'ทุกบรรทัดเงินสดผูกบัญชีธนาคารแล้ว';

  -- 3. สัญญาที่มีตารางงวดต้องข้อมูลครบ
  return query
  select 'contracts_complete'::text,
         not exists (
           select 1 from sri_os.contracts c
            where exists (select 1 from sri_os.schedules s where s.contract_id = c.id)
              and sri_os.fn_contract_completeness(c.id) < 100
         ),
         'สัญญาที่มีตารางงวดกรอกครบแล้ว';

  -- 4. ราคาทรัพย์ที่เก่าเกิน 7 วัน
  --    is_stale เป็น NULL สำหรับทรัพย์ที่ไม่เคยตีราคา → ข้อนี้ไม่พูดถึงมันโดยตั้งใจ
  --    (นั่นคือข้อ 5 ซึ่งแก้ด้วยวิธีอื่น) · ห้ามเปลี่ยนเป็น `is not true` ที่นี่
  --    ไม่งั้นสองเรื่องกลับมายุบเป็นธงเดียวอีก
  return query
  select 'valuations_fresh'::text,
         not exists (select 1 from sri_os.v_asset_latest_value where is_stale),
         coalesce((
           select 'ราคาเก่า ' || count(*)::text || ' รายการ'
             from sri_os.v_asset_latest_value where is_stale
         ), 'ราคาทุกตัวสดใหม่');

  -- 5. ทรัพย์ที่ยังไม่เคยตีราคาเลย — คนละเรื่องกับข้อ 4 และเตือนสำคัญกว่า
  --    as_of is null = left join ใน v_asset_latest_value ไม่ติดแถวไหน (as_of ใน
  --    ตารางเป็น not null) = ไม่มีประวัติการตีราคาเลย · NAV ขาดทรัพย์ตัวนี้อยู่
  --    detail บอก **รหัสทรัพย์** ไม่ใช่แค่จำนวน ไม่งั้นรู้ว่าแดงแต่ตามแก้ไม่ได้
  --    (string_agg คืน NULL เมื่อไม่มีแถว → coalesce ได้ข้อความเขียวจริง
  --     ต่างจาก count(*) ที่คืน 0 แถวเดียวเสมอ)
  return query
  select 'valuations_present'::text,
         not exists (select 1 from sri_os.v_asset_latest_value where as_of is null),
         coalesce((
           select 'ยังไม่เคยตีราคา '
                  || (select count(*) from sri_os.v_asset_latest_value where as_of is null)::text
                  || ' รายการ: ' || string_agg(x.code, ', ')
                  || case when (select count(*) from sri_os.v_asset_latest_value where as_of is null) > 10
                          then ', ...' else '' end
             from (select a.code
                     from sri_os.v_asset_latest_value lv
                     join sri_os.assets a on a.id = lv.asset_id
                    where lv.as_of is null
                    order by a.code limit 10) x
         ), 'ทรัพย์ทุกตัวมีราคาแล้ว');
end $fn$;

comment on function fn_health_check() is
  'รายงานสุขภาพข้อมูลทั้งระบบ (Money Invariants) · SECURITY DEFINER = ข้าม RLS โดยเจตนาเพราะต้องเห็นทุก owner · **กั้นด้วย fn_can(settings.manage) ในตัวฟังก์ชัน** เพราะ GRANT เลือกตามสิทธิ์ไม่ได้ · 5 ข้อ: ข้อ 4 = ราคาเก่า · ข้อ 5 = ยังไม่เคยตีราคา (คนละเรื่อง วิธีแก้ต่างกัน ห้ามยุบรวม)';

-- ACL เดิมจาก 20261007000007 (allow-list) · create or replace ไม่ล้าง ACL
-- แต่ประกาศซ้ำให้ไฟล์นี้อ่านจบในตัว และกันกรณีสร้างใหม่ในคลัสเตอร์เปล่า
revoke all on function fn_health_check() from public;
do $$ begin
  execute 'revoke all on function sri_os.fn_health_check() from anon';
  execute 'grant execute on function sri_os.fn_health_check() to authenticated';
exception when undefined_object then
  raise notice 'ไม่มี role anon/authenticated ในคลัสเตอร์นี้ — ข้าม revoke/grant';
end $$;

-- ============================================================
-- 3 · guard ของไฟล์นี้เอง — ถ้ากฎไม่ติดจริง migration ต้องพังทันที
--     ไม่ใช่รอให้เทสต์จับทีหลัง (ไฟล์นี้อาจถูก apply บน project ก่อนเทสต์)
-- ============================================================
do $$
declare n int;
begin
  select count(*) into n
    from pg_trigger tg
   where tg.tgrelid = 'sri_os.asset_valuations'::regclass
     and not tg.tgisinternal
     and tg.tgname in ('trg_forbid_delete_valuation', 'trg_forbid_truncate');
  if n <> 2 then
    raise exception 'trigger กัน DELETE/TRUNCATE บน asset_valuations ไม่ครบ (เจอ % ตัว)', n;
  end if;

  -- ตรวจจาก prosrc ไม่ใช่เรียกฟังก์ชัน: ตอน apply migration ไม่มี auth.uid()
  -- → ด่าน settings.manage จะปฏิเสธ แล้ว guard จะกลายเป็นข้ามเงียบๆ
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_health_check'
     and p.prosecdef
     and p.prosrc like '%valuations_present%'
     and p.prosrc like '%valuations_fresh%'
     and p.prosrc like '%settings.manage%';
  if n <> 1 then
    raise exception 'fn_health_check ไม่ได้มีทั้งธง valuations_fresh + valuations_present + ด่าน settings.manage + SECURITY DEFINER';
  end if;
  raise notice 'guard · trigger กัน DELETE/TRUNCATE ติดแล้ว · fn_health_check มีธงแยกสองธง';
end $$;
