-- ============================================================
-- SRI OS · สิทธิ์ระดับ GRANT ของสคีมา sri_os (ชั้นก่อน RLS)
--
-- ทำไมต้องมีไฟล์นี้:
--   ตรวจ project จริง (07/10) พบว่า **ไม่มี ACL เลย** — `sri_os` ไม่ให้ usage แก่ใคร
--   และทุกตารางมีแต่ `postgres` → แอปที่ deploy อยู่อ่าน/เขียนไม่ได้เลย
--   เพราะถูกปฏิเสธที่ชั้น GRANT ก่อนจะถึง RLS (RLS กรองได้เฉพาะ role ที่มีสิทธิ์ตารางแล้ว)
--   ของพวกนี้เคยอยู่แค่ใน scripts/test-rls-local.sh ซึ่ง **หลวมกว่า** ของจริง (`grant all`)
--   → harness เป็นแหล่งความจริงของสิทธิ์ไม่ได้ ต้องเป็น migration ที่ทั้งสองฝั่งใช้ไฟล์เดียวกัน
--
-- หลักที่ใช้:
--   · ให้ **authenticated เท่านั้น** — ไม่ให้ `anon` ทุกกรณี เพราะทุกหน้าของระบบนี้
--     ต้องล็อกอิน ไม่มีหน้า public · ถ้า anon มี usage + select แม้แต่ตารางเดียว
--     ข้อมูลครอบครัวจะอ่านได้ด้วย anon key ที่ฝังอยู่ในหน้าเว็บ
--   · ไม่ให้ `service_role` ที่นี่ — ถ้าวันหนึ่งต้องใช้ (cron / Edge Function) ให้เพิ่ม
--     เป็นไฟล์แยกพร้อมเหตุผล ไม่ใช่ให้ไว้ก่อนเพราะมันข้าม RLS ทั้งหมด
--   · DML สี่ตัวเท่านั้น: select · insert · update · delete
--     **ไม่มี TRUNCATE** (ไม่ยิง row trigger ไม่ผ่าน RLS ไม่เหลือ audit → ล้างสมุดได้ในคำสั่งเดียว
--     กฎเหล็กข้อ 1 / Money Invariant 4 · มี trg_forbid_truncate กันอีกชั้นที่ DB)
--     **ไม่มี REFERENCES** (สร้าง FK ชี้ตารางการเงินจากตารางของตัวเองได้ = ล็อกแถวไม่ให้แก้)
--     **ไม่มี TRIGGER** (สร้าง trigger บนตารางการเงินได้ = แทรกโค้ดในเส้นทางลงบัญชี)
--   · ฟังก์ชัน: ไฟล์นี้ **grant** ตัวที่ RLS/หน้าจอต้องเรียก และ **revoke** trigger function
--     (trigger ไม่ต้องมีสิทธิ์ตอนยิง) — แต่สองอย่างนี้ **ไม่ได้ปิดฟังก์ชันที่เหลือ**
--     ตัวที่ไม่เข้าสองกลุ่มยังถือ ACL เริ่มต้นของ Postgres = PUBLIC EXECUTE
--     ผู้ตรวจ (07/10) พบ 5 ตัวที่เปิด PUBLIC อยู่ รวม `fn_health_check` ที่เป็น
--     SECURITY DEFINER และคืน transaction_id ข้าม owner
--     → การ "ปิดก่อนแล้วเปิดตาม allow-list" อยู่ใน
--       **supabase/migrations/20261007000007_function_execute_acl.sql**
--     อ่านไฟล์นี้ลำพังแล้วเข้าใจว่าฟังก์ชันปิดหมดแล้ว = เข้าใจผิด
--
-- ย้อนกลับ (rollback):
--   -- revoke all on all tables in schema sri_os from authenticated;
--   -- revoke all on all sequences in schema sri_os from authenticated;
--   -- revoke usage on schema sri_os from authenticated;
--   -- alter default privileges in schema sri_os revoke all on tables from authenticated;
--   -- alter default privileges in schema sri_os revoke all on sequences from authenticated;
--   -- (ย้อนแล้วแอปจะใช้งานไม่ได้เลย = สถานะเดียวกับ project จริงก่อนไฟล์นี้)
--
-- idempotent: grant/revoke ซ้ำได้ · alter default privileges ซ้ำได้
-- ============================================================

set search_path = sri_os, public;

-- ---------- สคีมา ----------
grant usage on schema sri_os to authenticated;
revoke all on schema sri_os from anon;

-- ---------- ตาราง + view ----------
grant select, insert, update, delete on all tables in schema sri_os to authenticated;
revoke all on all tables in schema sri_os from anon;

-- ---------- ลำดับเลข (bigserial ของ audit_log) ----------
-- usage + select พอสำหรับ nextval/currval · ไม่ให้ update (setval = ย้อนเลขลำดับ audit)
grant usage, select on all sequences in schema sri_os to authenticated;
revoke all on all sequences in schema sri_os from anon;

-- ---------- ตารางที่สร้างทีหลัง ----------
-- หมายเหตุสำคัญ: default privileges **ผูกกับ role ที่สร้างออบเจกต์** ไม่ใช่ทั้งฐานข้อมูล
-- ไฟล์นี้จึงตั้งให้ role ที่รัน migration (current_user) เท่านั้น
-- ถ้าวันหนึ่งมี role อื่นสร้างตารางในสคีมานี้ ตารางนั้นจะไม่ได้สิทธิ์ → do block ล่างเตือนให้
alter default privileges in schema sri_os
  grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema sri_os
  grant usage, select on sequences to authenticated;

do $$
declare v text;
begin
  select string_agg(distinct pg_get_userbyid(c.relowner), ', ') into v
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'sri_os' and c.relkind in ('r', 'v', 'm', 'S')
     and pg_get_userbyid(c.relowner) <> current_user;
  if v is not null then
    raise warning 'มีออบเจกต์ใน sri_os ที่เจ้าของไม่ใช่ % (%) → default privileges ที่ไฟล์นี้ตั้งจะไม่ครอบของที่ role พวกนั้นสร้างใหม่ · ต้องรัน alter default privileges for role <role> เพิ่ม', current_user, v;
  end if;
end $$;

-- ---------- ฟังก์ชันที่ต้องเรียกได้จากข้างนอก ----------
-- fn_can  — หน้าจอเรียกตรงผ่าน rpc (src/lib/auth/session.ts) และ RLS ก็ใช้ตัวเดียวกัน
-- fn_can_see_owner / fn_can_see_asset / fn_can_read_txn / fn_can_read_contract
--   — อยู่ใน expression ของ policy ซึ่ง **รันด้วยสิทธิ์ผู้เรียก** ถ้าไม่มี execute
--     ทุก select จะล้มด้วย permission denied (ไม่ใช่เห็น 0 แถว)
-- fn_reverse_link_ok — ผู้เรียกต้องมี execute เพราะ fn_assert_reverse_link และ
--   fn_corporate_requires_evidence (trigger ที่เรียกมัน) **ไม่ใช่ security definer**
--   จึงรันด้วยสิทธิ์ผู้คีย์ · ถ้าถอนออก การลงรายการกลับรายการจะล้มในแอปแต่ผ่านในเทสต์
--   ที่รันเป็น superuser (= harness หลวมกว่าของจริงอีกแบบ) · เทสต์ L23 กันเคสนี้
--   ถ้าจะถอนจริงต้องเปลี่ยน trigger ทั้งสองตัวเป็น security definer ก่อน (งานแยก)
grant execute on function
  fn_can(text),
  fn_can_see_owner(uuid),
  fn_can_see_asset(uuid),
  fn_can_read_txn(uuid, uuid, uuid),
  fn_can_read_contract(uuid, uuid),
  fn_reverse_link_ok(uuid, uuid, uuid)
to authenticated;

-- ---------- ฟังก์ชันที่ห้ามเรียกจากข้างนอก ----------
-- trigger / event trigger function: Postgres ตรวจสิทธิ์ตอน create trigger ไม่ใช่ตอนยิง
--   → ถอน execute ได้โดย trigger ยังทำงานปกติ
-- fn_assert_line_writable / fn_assert_txn_balanced: ถูกเรียกจาก trigger function ที่เป็น
--   security definer เท่านั้น (ตรวจแล้ว) จึงไม่ต้องมีสิทธิ์ที่ผู้เรียก
-- ไล่จาก pg_proc ไม่ใช่ลิสต์มือ เพื่อให้ trigger function ที่เพิ่มในอนาคตถูกปิดด้วย
-- **ไม่ revoke ทั้งสคีมา** เพราะ pgcrypto ติดตั้งใน sri_os และ gen_random_uuid()
-- เป็น default ของคอลัมน์ id — ถอนแล้ว insert ทุกตารางล้มทันที
do $$
declare r record; n int := 0;
begin
  for r in
    select p.oid::regprocedure::text as sig
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'sri_os'
       and (p.prorettype in ('trigger'::regtype, 'event_trigger'::regtype)
            or p.proname in ('fn_assert_line_writable', 'fn_assert_txn_balanced'))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    n := n + 1;
  end loop;
  raise notice 'ถอน execute ของฟังก์ชันภายใน % ตัวออกจาก public/anon/authenticated', n;
end $$;
