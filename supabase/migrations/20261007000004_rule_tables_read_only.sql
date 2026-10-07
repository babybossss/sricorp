-- ============================================================
-- SRI OS · ตารางกฎ (txn_types) + ผังบัญชี (chart_of_accounts) = อ่านได้ทุกคน เขียนไม่ได้เลย
--
-- ทำอะไร:
--   1. **ถอน policy เขียนสองตัว** ที่ 20261006190000 สร้างไว้ให้ `settings.manage`
--      (txn_types_write · chart_of_accounts_write)
--   2. ย้ำ read policy ให้ทั้งสองตาราง (idempotent) — RLS เปิดอยู่ ถ้าไม่มี policy
--      จะปฏิเสธทุกอย่าง **เงียบๆ** (0 แถว ไม่ใช่ error) แล้วฟอร์มลงรายการ
--      จะไม่มีประเภทรายการให้เลือกเลยโดยไม่มีอะไรบอกว่าทำไม
--
-- ทำไมถอน (ผู้ตรวจ 07/10 · รันเองบน Postgres ในเครื่อง):
--   ในฐานะ management (มี settings.manage) ยิงได้จริงทั้งสามอย่าง
--     update txn_types set dr_coa_code=cr_coa_code, cr_coa_code=dr_coa_code
--       where code='exp.bank_charge'            → UPDATE 1
--     delete from txn_types                     → DELETE 54
--     update chart_of_accounts set name_th='…'  → UPDATE 48
--   รูนี้เพิ่งยิงได้เพราะ 20261007000001_grants.sql เปิด UPDATE/DELETE เป็นครั้งแรก
--   ก่อนหน้านั้นไม่มีใครมีสิทธิ์ตารางเลย policy ชุดนี้จึงไม่เคยถูกใช้งานจริง
--
--   สองตารางนี้เป็น **สำเนา** ของ src/lib/rules/{tx-rules,coa}.ts ซึ่ง CLAUDE.md
--   ระบุว่าเป็นแหล่งความจริงเดียวของ ประเภท → หมวดย่อย → คู่บัญชี → ผลกระทบต่องบ
--   ถ้าแก้จากแอปได้ DB จะไม่ตรงกับโค้ด และ `npm run sync:rules` จับไม่ได้
--   เพราะมันสร้าง migration จากโค้ดทางเดียว ไม่ได้อ่านกลับมาเทียบ
--   การสลับคู่บัญชีหนึ่งคู่เปลี่ยนความหมายของรายการทั้งระบบ **ย้อนหลังทุกแถว**
--   ที่อ้างประเภทนั้น โดยไม่มี audit ของการเปลี่ยนกฎให้ใครเห็น
--
--   เหมือนเหตุผลของ 20261007000003 (ตารางสิทธิ์): นี่ไม่ใช่ config ธรรมดา
--   การเปลี่ยนกฎต้องเหลือร่องรอยใน git ไม่ใช่เกิดเงียบๆ ใน DB
--   → แก้ได้จาก migration เท่านั้น ไม่มีใครแก้ผ่านแอปได้ รวม Super Admin
--
--   `npm run sync:rules` ไม่กระทบ — ตรวจแล้วว่าสคริปต์ **ไม่ต่อ DB เลย**
--   (scripts/sync-txn-types.ts เขียนไฟล์ migration ใหม่ออกมา แล้วคนรัน migration)
--
--   สิ่งที่ settings.manage **ยังทำได้ตามปกติ**: owners (เพิ่ม/แก้ชื่อ-สถานะ) ·
--   contacts · settings · ปิดงวด · และอ่านตารางกฎ/ผังบัญชีได้เต็มที่
--
-- ทำไมถอนที่ชั้น policy ไม่ใช่ชั้น GRANT:
--   ใช้แนวเดียวกับ 20261007000003 เพื่อให้เทสต์ P1 ("ทุกตารางต้องมี DML สี่ตัว
--   ไม่งั้นแอปถูกปฏิเสธที่ชั้น GRANT ก่อนถึง RLS") ยังเป็นกฎเดียวทั้งสคีมา
--   ไม่ต้องมีรายการยกเว้นที่คนอ่านต้องจำ · RLS ที่ไม่มี policy เขียน = ปฏิเสธ
--   insert/update/delete ของทุก role ที่ไม่ใช่ BYPASSRLS (= ทุกคนที่มาจากแอป)
--   เคสที่ต้องกันถึงชั้นคอลัมน์ (owners.policy) อยู่ในไฟล์ 20261007000005 แทน
--
-- ย้อนกลับ (rollback):
--   -- do $$ declare t text; begin
--   --   foreach t in array array['txn_types','chart_of_accounts'] loop
--   --     execute format('create policy %I_write on sri_os.%I for all to authenticated
--   --       using (sri_os.fn_can(''settings.manage''))
--   --       with check (sri_os.fn_can(''settings.manage''))', t, t);
--   --   end loop; end $$;
--   -- (ย้อนแล้ว management สลับคู่บัญชีของทุกประเภทรายการได้จากหน้าจอ — ไม่แนะนำ)
--
-- idempotent: drop policy if exists ก่อน create · drop ของ write ซ้ำได้
-- ============================================================

set search_path = sri_os, public;

do $$
declare t text;
begin
  foreach t in array array['txn_types', 'chart_of_accounts'] loop
    -- RLS ต้องเปิด (ถ้าไฟล์ก่อนหน้าไม่ได้รัน ก็ยังต้องเปิด ไม่ใช่ปล่อยเปิดโล่ง)
    execute format('alter table sri_os.%I enable row level security', t);

    -- อ่านได้ทุกคนที่ล็อกอิน: ฟอร์มลงรายการ · รายงาน · หน้าผังบัญชี ต้องอ่านครบ
    -- และกฎไม่ใช่ข้อมูลของใครคนใดคนหนึ่ง จึงไม่ต้องกรองตาม owner
    execute format('drop policy if exists %I_read on sri_os.%I', t, t);
    execute format('create policy %I_read on sri_os.%I for select to authenticated using (true)', t, t);

    -- ไม่มี policy เขียนเลย = RLS ปฏิเสธ insert/update/delete ของทุก role
    execute format('drop policy if exists %I_write on sri_os.%I', t, t);
  end loop;
end $$;

comment on table txn_types is
  'สำเนาตารางกฎจาก src/lib/rules/tx-rules.ts · **แก้ได้จาก migration เท่านั้น** (ไม่มี write policy) · sync ด้วย npm run sync:rules ซึ่งสร้างไฟล์ migration ใหม่ ไม่ได้เขียน DB ตรงๆ';
comment on table chart_of_accounts is
  'สำเนาผังบัญชีจาก src/lib/rules/coa.ts · **แก้ได้จาก migration เท่านั้น** (ไม่มี write policy) · เพิ่มรหัสใหม่ = แก้โค้ดแล้วออก migration ไม่ใช่เพิ่มจากหน้า Settings';

-- กันพลาด: ถ้าวันหนึ่งมีใครเพิ่ม policy เขียนกลับมา ให้ migration ถัดไปสะดุดที่นี่
do $$
declare v text;
begin
  select string_agg(tablename || '.' || policyname || ' (' || cmd || ')', ', ') into v
    from pg_policies
   where schemaname = 'sri_os'
     and tablename in ('txn_types', 'chart_of_accounts')
     and cmd <> 'SELECT';
  if v is not null then
    raise exception 'พบ policy เขียนบนตารางกฎ/ผังบัญชี: % · สองตารางนี้แก้ได้จาก migration เท่านั้น (เหตุผลอยู่หัวไฟล์นี้)', v;
  end if;
end $$;
