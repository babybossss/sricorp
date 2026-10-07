-- ============================================================
-- SRI OS · สำเนาสถานะจริงที่ migration ในรีโปไม่มี (ใช้เฉพาะเทสต์ในเครื่อง)
--
-- ทำไมต้องมีไฟล์นี้: project จริง (oyigmbmxxlfhkrevsmxo) มี policy หลายตัว
-- ที่ใส่มือไว้และ **ไม่อยู่ใน supabase/migrations ไฟล์ไหนเลย** · DB ที่ replay
-- จากรีโปจึงไม่มีของพวกนี้ และเทสต์จะ "ผ่าน" ทั้งที่ของจริงยังมีช่องโหว่
-- (policy เป็น permissive และ OR กัน ของเก่าที่กว้างกว่าลบล้างสิทธิ์ใหม่ได้เงียบๆ)
--
-- รันก่อน migration ที่กำลังทดสอบ โดย scripts/test-rls-local.sh
-- ชื่อ policy ด้านล่างมาจาก pg_policies ของ project จริง
-- ============================================================

alter table sri_os.user_owner_access enable row level security;
drop policy if exists access_manage on sri_os.user_owner_access;
create policy access_manage on sri_os.user_owner_access
  for all to authenticated
  using (sri_os.fn_is_management()) with check (sri_os.fn_is_management());

alter table sri_os.period_closes enable row level security;
drop policy if exists period_read on sri_os.period_closes;
create policy period_read on sri_os.period_closes
  for select to authenticated using (sri_os.fn_can_see_owner(owner_id));
drop policy if exists period_write on sri_os.period_closes;
create policy period_write on sri_os.period_closes
  for all to authenticated
  using (sri_os.fn_is_management()) with check (sri_os.fn_is_management());

drop policy if exists confirmations_write on sri_os.cash_confirmations;
create policy confirmations_write on sri_os.cash_confirmations
  for all to authenticated
  using (sri_os.fn_is_management()) with check (sri_os.fn_is_management());

alter table sri_os.contact_links enable row level security;
drop policy if exists contact_links_all on sri_os.contact_links;
create policy contact_links_all on sri_os.contact_links
  for all to authenticated
  using (sri_os.fn_is_management()) with check (sri_os.fn_is_management());
