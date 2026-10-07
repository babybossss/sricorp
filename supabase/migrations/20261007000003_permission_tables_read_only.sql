-- ============================================================
-- SRI OS · ตารางสิทธิ์ (roles · permissions · role_permissions) = อ่านได้ทุกคน เขียนไม่ได้เลย
--
-- ทำอะไร:
--   1. ย้ำ read policy ให้ทั้งสามตาราง (idempotent) — RLS เปิดอยู่ ถ้าไม่มี policy
--      จะปฏิเสธทุกอย่าง**เงียบๆ** (0 แถว ไม่ใช่ error) แล้วหน้า "ไม่มีสิทธิ์"
--      กับ /settings/users จะว่างเปล่าโดยไม่มีอะไรบอกว่าทำไม
--      (RLS ปฏิเสธเงียบๆ อันตรายกว่า error — หน้าจอดูเหมือนทำงานปกติแต่ข้อมูลหาย)
--   2. **ถอน write policy ทั้งสามตัว** (roles_write · permissions_write · role_permissions_write)
--      ที่ 20261006190000 สร้างไว้ให้ users.manage
--
-- ทำไมถอน — และทำไมมันขัดกฎข้อ 5 ของ CLAUDE.md โดยตั้งใจ:
--   กฎข้อ 5 บอกว่า "ทุกอย่างที่ตั้งค่าได้อยู่ในตาราง config ห้าม hard-code"
--   แต่สามตารางนี้ไม่ใช่ config ธรรมดา — มันคือ **ตัวกำหนดว่าใครแตะเงินได้**
--   ถ้าเปิดให้แก้ผ่านแอป บัญชีเดียวที่ถูกยึดและมี users.manage จะเปิดสิทธิ์ให้ตัวเอง
--   ได้ทุกอย่างในคลิกเดียว (รวม ledger.post · portfolio.view_all) โดยไม่ต้องผ่านใคร
--   การเปลี่ยน **โครงสร้าง**สิทธิ์ต้องเหลือร่องรอยใน git ไม่ใช่เกิดเงียบๆ ใน DB
--   → ตารางสามตัวนี้แก้ได้จาก migration เท่านั้น ไม่มีใครแก้ผ่านแอปได้ รวม Super Admin
--
--   สิ่งที่ users.manage **ยังทำได้ตามปกติ**: จัดการว่า**ใครอยู่ตำแหน่งไหน** (app_users.role)
--   = เปลี่ยนคนเข้าตำแหน่งได้ แต่เปลี่ยนไม่ได้ว่าตำแหน่งนั้นทำอะไรได้
--   เจตนาเดิมของ D-073 (ย้ายสิทธิ์แล้วมีผลทันทีโดยไม่ต้องแก้โค้ด) ยังอยู่ครบ
--   เพราะ fn_can อ่านจากตารางเสมอ — เปลี่ยนที่มาของการแก้เป็น migration ไม่ใช่เปลี่ยนกลไก
--
-- ทำไมเป็นไฟล์ใหม่ ไม่แก้ 20261006190000: ไม่ยืนยันได้ว่าไฟล์นั้น apply แล้วหรือยัง
--   ตาม D-090 ถ้าไม่แน่ใจให้ถือว่า apply แล้ว → เพิ่มไฟล์ใหม่
--
-- ย้อนกลับ (rollback):
--   -- do $$ declare t text; begin
--   --   foreach t in array array['roles','permissions','role_permissions'] loop
--   --     execute format('create policy %I_write on sri_os.%I for all to authenticated
--   --       using (sri_os.fn_can(''users.manage'')) with check (sri_os.fn_can(''users.manage''))', t, t);
--   --   end loop; end $$;
--   -- (ย้อนแล้วบัญชีที่มี users.manage จะเลื่อนสิทธิ์ตัวเองได้ — ไม่แนะนำ)
--
-- idempotent: drop policy if exists ก่อน create · drop ของ write ซ้ำได้
-- ============================================================

set search_path = sri_os, public;

do $$
declare t text;
begin
  foreach t in array array['roles', 'permissions', 'role_permissions'] loop
    -- RLS ต้องเปิด (ถ้าไฟล์ก่อนหน้าไม่ได้รัน ก็ยังต้องเปิด ไม่ใช่ปล่อยเปิดโล่ง)
    execute format('alter table sri_os.%I enable row level security', t);

    -- อ่านได้ทุกคนที่ล็อกอิน: นี่คือข้อมูลอ้างอิงที่อธิบายว่าระบบมีสิทธิ์อะไรบ้าง
    -- และตำแหน่งไหนได้อะไร · **ไม่ใช่ตัวเลขเงินและไม่ใช่ข้อมูลของใครคนใดคนหนึ่ง**
    -- Staff ที่เห็นว่า "ตำแหน่ง Manager ดูพอร์ตรวมได้" ไม่ได้ทำให้เขาดูพอร์ตรวมได้
    execute format('drop policy if exists %I_read on sri_os.%I', t, t);
    execute format('create policy %I_read on sri_os.%I for select to authenticated using (true)', t, t);

    -- ไม่มี policy เขียนเลย = RLS ปฏิเสธ insert/update/delete ของทุก role
    -- (ไม่มี policy สำหรับ cmd ไหน = ปฏิเสธ cmd นั้น ไม่ใช่อนุญาต)
    execute format('drop policy if exists %I_write on sri_os.%I', t, t);
  end loop;
end $$;

comment on table roles is
  'ระดับสิทธิ์ (D-072) · rank_order น้อย = สูงกว่า · เพิ่มระดับใหม่ = เพิ่มแถว ไม่ต้องแก้ RLS · **แก้ได้จาก migration เท่านั้น** (ไม่มี write policy) เพราะเป็นตัวกำหนดว่าใครแตะเงินได้';
comment on table permissions is
  'สิทธิ์ว่า "ใครกดอะไรได้" เท่านั้น (D-073) · ห้ามมีคีย์ที่ปิดกฎเงิน (บังคับด้วย CHECK) · **แก้ได้จาก migration เท่านั้น** (ไม่มี write policy)';
comment on table role_permissions is
  'การจับคู่ระดับ → สิทธิ์ · ย้ายสิทธิ์ข้ามระดับ = แก้แถวนี้ **ด้วย migration** (ไม่มี write policy) · users.manage เปลี่ยนได้แค่ว่าใครอยู่ตำแหน่งไหน (app_users.role)';

-- กันพลาด: ถ้าวันหนึ่งมีใครเพิ่ม policy เขียนกลับมา ให้ migration ถัดไปสะดุดที่นี่
do $$
declare v text;
begin
  select string_agg(tablename || '.' || policyname || ' (' || cmd || ')', ', ') into v
    from pg_policies
   where schemaname = 'sri_os'
     and tablename in ('roles', 'permissions', 'role_permissions')
     and cmd <> 'SELECT';
  if v is not null then
    raise exception 'พบ policy เขียนบนตารางสิทธิ์: % · ตารางพวกนี้แก้ได้จาก migration เท่านั้น (เหตุผลอยู่หัวไฟล์นี้)', v;
  end if;
end $$;
