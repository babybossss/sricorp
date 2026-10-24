-- ============================================================
-- SRI OS · ด่านระดับ "คอลัมน์" (D-089) + เงื่อนไขบังคับก่อนสร้างบัญชี Staff
--   เทสต์: supabase/tests/zz_column_exposure_test.sql
--
-- ปัญหาที่ไฟล์นี้ปิด (D-089)
--   RLS ของ Postgres กรอง **แถว** ไม่กรอง **คอลัมน์** → ใครเห็นแถวได้ อ่านได้ทุกคอลัมน์
--   ของแถวนั้น · ของจริงที่วัดได้ก่อนไฟล์นี้ (ไล่จาก pg_policies ไม่ใช่เดา):
--     · `assets` · policy assets_by_owner มีทางผ่านของคนคีย์รายการ
--       (txn.create and not asset.view_assigned) → **Staff เห็นทรัพย์ทุกแถว**
--       ของผู้ถือที่อยู่ในขอบเขตตัวเอง ซึ่งถูกต้องเพราะต้องเลือกทรัพย์ในฟอร์มได้
--       แต่พอเห็นแถวแล้วก็อ่าน `units` · `ownership_pct` · `beneficiary_id` ·
--       `funding_source` ได้ด้วย = เห็นโครงสร้างการถือและขนาดการลงทุนทั้งบ้าน
--     · `bank_accounts` · policy เป็น fn_can_see_owner(owner_id) เท่านั้น →
--       Staff (ที่ไม่มี ledger.read) และ Manager (ที่ไม่มี portfolio.view_all)
--       อ่าน `opening_balance` ได้ = ยอดยกมาของทุกบัญชีในขอบเขต
--     · `owners` · `contacts` · policy อ่านเป็น true ทั้งตาราง → ทุกคนที่ล็อกอิน
--       อ่าน `tax_id_last4` ได้ (เลขผู้เสียภาษี) และ `contacts.note`
--
--   คำสั่งลูกพี่ที่ใช้ตัดสิน: "Manager ดูภาพรวมการลงทุนไม่ได้ ดูได้แต่ทรัพย์ที่
--   บริหารจัดการ · Staff ทำได้แค่ลงข้อมูล" (D-089 · D-094) → ระดับที่ไม่ควรเห็น
--   **อ่านจากตารางสิทธิ์จริง** (permissions · role_permissions) ไม่ใช่ชื่อ role
--
-- ทำไมไม่ใช้ view (ซึ่งเป็นคำตอบที่ D-089 เขียนไว้)
--   20261007000000 บังคับ **ทุก view ใน sri_os เป็น security_invoker = true**
--   ด้วย event trigger (เพราะ view ที่ไม่ใช่ invoker = ทางข้าม RLS) → view ที่
--   "เปิดเฉพาะคอลัมน์ที่จำเป็น" ยังต้องอาศัยสิทธิ์คอลัมน์ของผู้เรียก จึงซ่อนอะไรไม่ได้เลย
--   ไฟล์นั้นเขียนทางออกไว้แล้วว่า "ให้ใช้ view ปกติหรือ **ฟังก์ชันที่กรองตามสิทธิ์**"
--   → ไฟล์นี้เดินทางนั้น และ **ไม่แตะ event trigger นั้นแม้แต่บรรทัดเดียว**
--
-- กลไกสามชั้น (ชั้นที่ 1 คือด่านจริง · อีกสองชั้นกันของใหม่หลุดเงียบ)
--   1. ชั้น GRANT ระดับคอลัมน์ · ถอน `select` ระดับตารางของ `authenticated`
--      แล้ว grant คืน **เฉพาะคอลัมน์ที่ขึ้นทะเบียนว่าเปิด**
--      ปิดได้ทุกทางที่ P1 ระบุ เพราะ Postgres ตรวจสิทธิ์คอลัมน์ที่ตัว executor:
--        `select *` · ระบุชื่อคอลัมน์ · `where` · `order by` · `returning` ·
--        view ที่เป็น invoker (ทุกตัวในสคีมานี้) · ฟังก์ชันที่ไม่ใช่ definer
--      และเป็นแพทเทิร์นเดิมของรีโปนี้อยู่แล้ว (20261007000005 เจาะ UPDATE ของ owners
--      เป็นระดับคอลัมน์ด้วยเหตุผลเดียวกัน: "RLS กันเป็นคอลัมน์ไม่ได้")
--      **ผลข้างเคียงที่ตั้งใจ**: ตารางที่มีด่านจะไม่มี select ระดับตารางอีก →
--      คอลัมน์ที่เพิ่มใหม่ในอนาคต **อ่านไม่ได้ทันทีจนกว่าจะขึ้นทะเบียน** (deny by default)
--   2. ทางเข้าของระดับที่มีสิทธิ์ · ฟังก์ชัน `fn_<ตาราง>_visible()`
--      security definer **เจ้าของเป็น role `sri_os_column_reader`** ซึ่ง
--        · ไม่ใช่เจ้าของตาราง · ไม่มี bypassrls · nologin · ไม่มีใครเป็นสมาชิก
--        · **เป็นสมาชิกของ `authenticated`** → policy ที่เขียน `to authenticated`
--          ยังมีผลกับมัน และ `auth.uid()` ยังเป็นผู้เรียกตัวจริง (อ่านจาก JWT/GUC)
--      ⇒ **RLS ยังเป็นด่านแถวด่านเดียว ไม่มีการเขียนเงื่อนไขแถวซ้ำที่สอง**
--      (พิสูจน์แล้วด้วย: ghost ที่ไม่มีแถวใน app_users เรียกฟังก์ชันได้ 0 แถว)
--      คอลัมน์ที่ปิดถูกครอบด้วย `case when fn_can('<สิทธิ์>') then ... end` → คนที่
--      ไม่มีสิทธิ์ได้ NULL (ไม่ใช่ error) เพื่อให้หน้าจอเดียวใช้ได้ทุกระดับ
--   3. ทะเบียนจัดประเภท + guard · ตาราง `column_exposure_tables` / `column_exposure`
--      เป็นแหล่งความจริงเดียวของ "คอลัมน์ไหนระดับไหนไม่ควรเห็น" และ
--      `fn_column_exposure_guard()` **พังทันที** เมื่อมีตาราง/คอลัมน์ใหม่ที่ยังไม่จัดประเภท
--      หรือเมื่อด่านไม่ติดจริง (แพทเทิร์นเดียวกับ guard ของ 20261008000004 และ
--      scripts/check-draft-fields.ts) · ด่านและทางเข้าถูก **สร้างจากทะเบียน** ทั้งคู่
--      จึงไม่มีทางที่สองชั้นจะไม่ตรงกัน
--
-- สามสถานะของการจัดประเภท (`column_exposure.exposure`)
--   `open`  = เปิดให้ทุกคนที่ล็อกอินอ่านได้ (ต้องมีเหตุผลกำกับ)
--   `grant` = ปิดด้วยชั้น GRANT จริง + เปิดคืนผ่าน fn_<ตาราง>_visible() ตามสิทธิ์
--   `row`   = ไม่ต้องมีด่านคอลัมน์ เพราะ **policy ของแถวบังคับสิทธิ์นั้นอยู่แล้ว**
--             (เช่น contracts ต้องมี ledger.read ถึงจะเห็นแถว) · guard ตรวจว่าเงื่อนไข
--             นั้นยังจริง โดยไล่ข้อความ policy **ทุกตัวที่อ่านได้** + เนื้อฟังก์ชัน
--             ที่ policy เรียก (ลึก 3 ชั้น) · ถ้าวันหนึ่งมีใครผ่อน policy ให้กว้างขึ้น
--             เหตุผลของ `row` ตาย → guard แดง ไม่ใช่ปล่อยผ่านเงียบๆ
--
-- เงื่อนไขบังคับก่อนสร้างบัญชี Staff (D-089 สั่งห้ามสร้างจนกว่าจะปิดข้อนี้)
--   trigger `trg_staff_requires_column_exposure` บน `app_users`: ถ้าแถวที่กำลัง
--   insert/update เป็นผู้ใช้ **ที่ยังใช้งานอยู่** และอยู่ระดับที่ "ลงข้อมูลได้แต่
--   อ่าน ledger ไม่ได้" (= ไม่มี `ledger.read` ในตารางสิทธิ์ · ไม่ดูชื่อ role)
--   → ต้องผ่าน fn_column_exposure_guard() ก่อน ไม่ผ่าน = ปฏิเสธ
--   **เอกสารห้ามไม่ได้ ของที่ห้ามได้คือ DB** · ปลดเงื่อนไขนี้ได้ด้วย migration เท่านั้น
--
-- ขอบเขตที่ไฟล์นี้ **ไม่** ครอบ (P3 · เขียนไว้ที่หัวไฟล์ตามที่สั่ง)
--   · `postgres` / superuser · เจ้าของตาราง → ข้ามสิทธิ์ทุกชั้นโดยธรรมชาติของ Postgres
--     ชั้นที่ครอบ superuser ได้คือ trigger เท่านั้น ซึ่งใช้กับ "ห้ามลบ/ห้ามแก้" ได้
--     แต่ใช้กับ "ห้ามอ่าน" ไม่ได้ (Postgres ไม่มี trigger ตอน select)
--   · `service_role` **มี bypassrls** → ข้าม RLS ได้ แต่ **ข้ามสิทธิ์ GRANT ไม่ได้**
--     และ 20261007000001 ไม่ได้ให้สิทธิ์อะไรใน sri_os แก่ service_role เลย
--     ⇒ วันนี้ service_role อ่าน sri_os ไม่ได้ทั้งแถวและคอลัมน์
--     **ถ้าวันหนึ่งมีไฟล์ grant ให้ service_role ด่านคอลัมน์นี้จะครอบมันด้วย**
--     (เป็นสิทธิ์ ไม่ใช่ RLS) แต่ไฟล์นั้นต้องไม่ grant select ระดับตารางของ 4 ตารางนี้
--     → guard ข้อ (8) ตรวจ **ทุก role ที่ไม่ใช่เจ้าของ** ไม่ใช่เฉพาะ authenticated
--   · ของที่ยังไม่จัดประเภทเพราะมีอีกงานถืออยู่: `transactions` · `transaction_lines`
--     (D-098 กำลังทำคอลัมน์ void + view + สลับ grant ของสองตารางนี้) ขึ้นทะเบียนเป็น
--     `deferred` พร้อมเหตุผล → guard ไม่ตรวจคอลัมน์ของสองตารางนั้น **แต่ยังตรวจว่า
--     ตารางต้องอยู่ในทะเบียน** · ตารางใหม่ที่ไม่มีใครขึ้นทะเบียน = guard แดง
--
-- ย้อนกลับ (rollback)
--   -- drop trigger if exists trg_staff_requires_column_exposure on sri_os.app_users;
--   -- drop function if exists sri_os.fn_staff_requires_column_exposure();
--   -- คืน select ระดับตารางให้ authenticated (= เปิดช่อง D-089 กลับมา):
--   --   do $$ declare t text; begin
--   --     foreach t in array array['assets','bank_accounts','owners','contacts'] loop
--   --       execute format('revoke select on sri_os.%I from authenticated', t);
--   --       execute format('grant select on sri_os.%I to authenticated', t);
--   --       execute format('drop function if exists sri_os.fn_%s_visible()', t);
--   --     end loop; end $$;
--   -- drop function if exists sri_os.fn_column_exposure_guard();
--   -- drop function if exists sri_os.fn_apply_column_exposure();
--   -- drop function if exists sri_os.fn_column_exposure_unclassified();
--   -- drop function if exists sri_os.fn_column_exposure_breaches();
--   -- drop function if exists sri_os.fn_policy_requires_permission(text, text);
--   -- drop table if exists sri_os.column_exposure;
--   -- drop table if exists sri_os.column_exposure_tables;
--   -- revoke select on all tables in schema sri_os from sri_os_column_reader;
--   -- revoke usage on schema sri_os from sri_os_column_reader;
--   -- revoke authenticated from sri_os_column_reader;  -- role ทิ้งไว้ได้ (nologin ไม่มีสิทธิ์)
--   -- ย้อนแล้ว: Staff อ่าน units/ownership_pct/opening_balance/tax_id_last4 ได้อีก
--   --           และสร้างบัญชี Staff ได้โดยไม่มีอะไรตรวจว่าด่านคอลัมน์ยังอยู่
--
-- idempotent: create table if not exists · insert ... on conflict do update ·
--   create or replace function · drop trigger if exists ก่อน create ·
--   revoke/grant ซ้ำได้ · fn_apply_column_exposure() คำนวณจากทะเบียนใหม่ทุกครั้ง
--   (รันไฟล์นี้ซ้ำได้ และรันได้ทั้งบน DB เปล่าและ DB ที่ apply ไปแล้ว)
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 1 · role เจ้าของทางเข้า (ต้องมาก่อนทะเบียน เพราะ fn_apply ใช้)
-- ============================================================
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'sri_os_column_reader') then
    -- nologin · inherit (ต้อง inherit เพื่อให้ policy ที่เขียน to authenticated มีผล
    -- และเรียก fn_can/fn_can_see_* ได้) · ไม่มี bypassrls · ไม่มี createrole
    create role sri_os_column_reader nologin inherit;
  end if;
end $$;

do $$
begin
  if (select rolsuper or rolbypassrls or rolcanlogin from pg_roles where rolname = 'sri_os_column_reader') then
    raise exception 'role sri_os_column_reader ต้องเป็น nologin · ไม่ superuser · ไม่ bypassrls (ไม่งั้นทางเข้ากลายเป็นทางข้าม RLS)';
  end if;
end $$;

-- สมาชิกของ authenticated = policy "to authenticated" มีผลกับมัน → RLS ยังกรองแถว
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    if not pg_has_role('sri_os_column_reader', 'authenticated', 'member') then
      grant authenticated to sri_os_column_reader;
    end if;
  else
    raise exception 'ไม่มี role authenticated ในคลัสเตอร์นี้ → ด่านคอลัมน์ติดไม่ได้ (ต้องรันไฟล์นี้บน DB ที่มี role ของ Supabase)';
  end if;
end $$;

grant usage on schema sri_os to sri_os_column_reader;

-- **ชั่วคราว** — เจ้าของใหม่ของฟังก์ชันต้องมีสิทธิ์ `create` บนสคีมาที่ฟังก์ชันอยู่
-- ไม่งั้น `alter function ... owner to` ขึ้น `permission denied for schema sri_os`
-- (วัดจากของจริง 24/10 · เครื่องทดสอบไม่เจอเพราะรันเป็น superuser)
-- **ถอนคืนท้ายไฟล์** เพราะทางเข้านี้ไม่ควรสร้างอะไรในสคีมาได้เลย
grant create on schema sri_os to sri_os_column_reader;

-- ------------------------------------------------------------
-- ผู้ที่รัน migration ต้อง **SET ROLE เป็น sri_os_column_reader ได้ชั่วคราว**
-- ไม่งั้น `alter function ... owner to sri_os_column_reader` ใน fn_apply พัง
--
-- ทำไมถึงไม่เจอตอนทดสอบในเครื่อง: ในเครื่องรันด้วย superuser ซึ่งยกความเป็นเจ้าของ
-- ให้ role ไหนก็ได้ · บน Supabase ผู้ใช้ `postgres` **ไม่ใช่ superuser**
-- และตั้งแต่ PG16 การเป็นผู้สร้าง role ให้สิทธิ์ ADMIN มาก็จริง **แต่ไม่ให้ SET**
-- → วัดจากของจริง 24/10: `ERROR: must be able to SET ROLE "sri_os_column_reader"`
--
-- ให้สิทธิ์แบบ `inherit false` เพื่อ **ไม่ให้ผู้รันได้สิทธิ์ของ role นี้ติดมาด้วย**
-- และ **ถอนคืนท้ายไฟล์** เพราะด่าน `reader_role` ห้ามมี role อื่นเป็นสมาชิกค้างไว้
-- (ถ้าค้าง = ใช้สิทธิ์ของทางเข้าได้โดยไม่ต้องผ่านฟังก์ชัน)
do $$
begin
  execute format('grant sri_os_column_reader to %I with inherit false, set true', current_user);
exception when others then
  -- PG15 ลงไปไม่มีตัวเลือก inherit/set · ลองแบบเดิม
  begin
    execute format('grant sri_os_column_reader to %I', current_user);
  exception when others then
    raise exception 'ให้สิทธิ์ SET ROLE sri_os_column_reader แก่ % ไม่ได้ (%) — '
      'ต้องรันไฟล์นี้ด้วยผู้ใช้ที่สร้าง role ได้ เช่น postgres ของ Supabase', current_user, sqlerrm;
  end;
end $$;

-- (ไม่ใช้ comment on role เพราะบน Supabase role ไม่ได้เป็นของ postgres เสมอ
--  คำอธิบายของ role อยู่ที่หัวไฟล์นี้และใน comment ของ fn_<ตาราง>_visible())

-- ============================================================
-- 2 · ทะเบียน · ขอบเขต (ตาราง) และการจัดประเภท (คอลัมน์)
-- ============================================================
create table if not exists column_exposure_tables (
  table_name   text primary key,
  review_state text not null check (review_state in ('classified', 'deferred')),
  reason       text not null check (length(btrim(reason)) > 10),
  created_at   timestamptz not null default now()
);
comment on table column_exposure_tables is
  'ขอบเขตการจัดประเภทคอลัมน์ (D-089) · ทุกตารางใน sri_os ต้องมีแถวที่นี่ ไม่มี = guard แดง · deferred ต้องมีเหตุผลและแก้ได้จาก migration เท่านั้น (ไม่มี write policy) เพื่อให้การเลื่อนมีประวัติใน git';

create table if not exists column_exposure (
  table_name     text not null,
  column_name    text not null,
  exposure       text not null check (exposure in ('open', 'row', 'grant')),
  min_permission text references permissions(key) on update cascade,
  rationale      text not null check (length(btrim(rationale)) > 10),
  created_at     timestamptz not null default now(),
  primary key (table_name, column_name),
  foreign key (table_name) references column_exposure_tables(table_name) on update cascade,
  -- open = ไม่มีสิทธิ์กำกับ · row/grant = ต้องระบุสิทธิ์ขั้นต่ำเสมอ (ไม่งั้นด่านไม่รู้จะถามอะไร)
  constraint column_exposure_permission_shape check (
    (exposure = 'open' and min_permission is null)
    or (exposure in ('row', 'grant') and min_permission is not null)
  )
);
comment on table column_exposure is
  'คอลัมน์ไหนระดับไหนไม่ควรเห็น (D-089) · แหล่งความจริงเดียว: ชั้น GRANT และฟังก์ชัน fn_<ตาราง>_visible() ถูกสร้างจากตารางนี้ทั้งคู่ · min_permission อ้าง permissions(key) จึงไม่มีชื่อ role ในโค้ด (กฎข้อ 5 / D-073)';
comment on column column_exposure.exposure is
  'open = ทุกคนที่ล็อกอินอ่านได้ · grant = ปิดด้วยสิทธิ์ระดับคอลัมน์ แล้วเปิดคืนผ่าน fn_<ตาราง>_visible() · row = policy ของแถวบังคับสิทธิ์นี้อยู่แล้ว (guard ตรวจว่ายังจริง)';

-- ---------- ขอบเขต: ทุกตารางใน sri_os ----------
insert into column_exposure_tables (table_name, review_state, reason) values
  ('app_users',           'classified', 'ผู้ใช้และระดับสิทธิ์ · แถวถูกกรองด้วย users_read (ตัวเอง/users.manage/owner.view_all)'),
  ('asset_categories',    'classified', 'taxonomy อ้างอิง · อ่านได้ทุกคนตามเจตนา ไม่มีตัวเลขเงิน'),
  ('asset_classes',       'classified', 'taxonomy อ้างอิง · อ่านได้ทุกคนตามเจตนา ไม่มีตัวเลขเงิน'),
  ('asset_drafts',        'classified', 'ร่างทรัพย์ (D-093) · แถวถูกกรองเป็นร่างของตัวเอง หรือของคนที่มี asset.manage ในขอบเขตทรัพย์'),
  ('asset_valuations',    'classified', 'ประวัติตีราคา · แถวถูกกรองด้วยขอบเขตทรัพย์ (fn_can_see_asset) อยู่แล้ว'),
  ('assets',              'classified', 'ทรัพย์ · มีทางผ่านของคนคีย์รายการที่ทำให้ Staff เห็นทุกแถว → ต้องมีด่านคอลัมน์'),
  ('audit_log',           'classified', 'ร่องรอย · แถวถูกกรองด้วย owner.view_all · before/after เก็บแถวเต็มจึงเป็น row ไม่ใช่ open'),
  ('bank_accounts',       'classified', 'บัญชีธนาคาร · แถวกรองแค่ผู้ถือ → ยอดยกมาต้องมีด่านคอลัมน์'),
  ('cash_confirmations',  'classified', 'ใบยืนยันเงินเข้า-ออก · แถวต้องมี ledger.read อยู่แล้ว'),
  ('chart_of_accounts',   'classified', 'ผังบัญชี = ตารางกฎ อ่านได้ทุกคน เขียนได้จาก migration เท่านั้น'),
  ('contact_links',       'classified', 'การผูกผู้ติดต่อกับเป้าหมาย · ไม่มีตัวเลขเงิน'),
  ('contacts',            'classified', 'ผู้ติดต่อ · policy อ่านเป็น true ทั้งตาราง → ข้อมูลภาษี/บันทึกต้องมีด่านคอลัมน์'),
  ('contracts',           'classified', 'สัญญา · แถวต้องมี ledger.read + ขอบเขตทรัพย์ (fn_can_read_contract) อยู่แล้ว'),
  ('draft_entries',       'classified', 'ร่างรายการเงิน · แถวเป็นของตัวเองหรือต้องมี ledger.read'),
  ('owners',              'classified', 'ผู้ถือ · policy อ่านเป็น true ทั้งตาราง → เลขผู้เสียภาษีต้องมีด่านคอลัมน์'),
  ('period_closes',       'classified', 'การปิดงวด · ไม่มีตัวเลขเงิน แถวกรองด้วยผู้ถือ'),
  ('permissions',         'classified', 'ตารางสิทธิ์ · อ่านได้ทุกคนตามเจตนา (20261007000003): รู้ว่าระบบมีสิทธิ์อะไร ไม่ได้ทำให้ได้สิทธิ์นั้น'),
  ('post_entry_requests', 'classified', 'กันลงรายการซ้ำ · แถวเป็นของผู้สร้างเท่านั้น'),
  ('role_permissions',    'classified', 'การจับคู่ระดับ-สิทธิ์ · อ่านได้ทุกคนตามเจตนา เขียนได้จาก migration เท่านั้น'),
  ('roles',               'classified', 'ระดับสิทธิ์ · อ่านได้ทุกคนตามเจตนา'),
  ('schedules',           'classified', 'ตารางงวด · แถวผูกกับสัญญาที่ต้องมี ledger.read ถึงจะเห็น'),
  ('settings',            'classified', 'ค่าตั้งค่าระบบ · อ่านได้ทุกคนเพราะหน้าจอทุกหน้าต้องใช้ (ดูข้อที่ต้องถามลูกพี่ท้ายไฟล์)'),
  ('txn_types',           'classified', 'ตารางกฎประเภทรายการ · อ่านได้ทุกคนตามเจตนา (เครื่องยนต์บัญชีต้องใช้)'),
  ('user_owner_access',   'classified', 'ขอบเขตผู้ถือของผู้ใช้ · แถวเป็นของตัวเองหรือคนจัดการผู้ใช้'),
  ('column_exposure',          'classified', 'ทะเบียนของไฟล์นี้เอง · ต้องจัดประเภทตัวเองด้วย ไม่งั้นมีตารางที่ guard ไม่ตรวจ'),
  ('column_exposure_tables',   'classified', 'ทะเบียนขอบเขตของไฟล์นี้เอง · เหตุผลเดียวกับข้างบน'),
  ('transactions',      'deferred', 'D-098 กำลังเพิ่มคอลัมน์ void + view + สลับ grant ของตารางนี้ (งานขนาน) · จัดประเภทตอนนี้จะชนกัน · ต้องกลับมาจัดประเภททันทีที่ D-098 ปิด'),
  ('transaction_lines', 'deferred', 'D-098 กำลังเพิ่ม view ที่อ่านตารางนี้ + สลับ grant (งานขนาน) · แถวของตารางนี้ถูกกรองด้วย fn_can_read_txn (ต้องมี ledger.read) อยู่แล้ว จึงเลื่อนได้ชั่วคราว')
on conflict (table_name) do update
  set review_state = excluded.review_state, reason = excluded.reason;

-- ---------- คอลัมน์ที่ "เปิด" · เขียนเป็นรายชื่อตรงๆ โดยเจตนา ----------
-- **ห้ามเปลี่ยนเป็น "ไล่จาก pg_attribute แล้วถือว่าเปิด"** เพราะนั่นแปลว่าคอลัมน์ใหม่
-- จะเปิดเองเงียบๆ ซึ่งเป็นข้อผิดพลาดที่โปรเจกต์นี้เจอซ้ำหลายครั้ง (P4)
insert into column_exposure (table_name, column_name, exposure, min_permission, rationale)
select t.tbl, c, 'open', null, t.why
  from (values
    ('app_users', array[
      'id', 'email', 'display_name', 'role', 'owner_id', 'is_active', 'created_at'
    ], 'ข้อมูลบัญชีผู้ใช้ · แถวถูกกรองให้เห็นได้แค่ของตัวเอง ยกเว้นคนที่มี users.manage/owner.view_all'),
    ('asset_categories', array[
      'id', 'class_id', 'code', 'name_th', 'is_active', 'sort_order'
    ], 'taxonomy อ้างอิง · ไม่ใช่ข้อมูลของใครคนใดคนหนึ่งและไม่มีตัวเลขเงิน'),
    ('asset_classes', array[
      'id', 'code', 'name_th', 'sort_order'
    ], 'taxonomy อ้างอิง · ไม่ใช่ข้อมูลของใครคนใดคนหนึ่งและไม่มีตัวเลขเงิน'),
    ('asset_drafts', array[
      'id', 'kind', 'target_asset_id', 'owner_id', 'name', 'class_id', 'category_id', 'patch',
      'note', 'status', 'reject_reason', 'applied_asset_id', 'created_by', 'reviewed_by',
      'reviewed_at', 'created_at'
    ], 'ร่างที่ผู้ใช้คีย์เอง · patch ถูกกำกับด้วย whitelist ของ fn_asset_draft_patch_keys และแถวเป็นของผู้สร้างหรือผู้มีสิทธิ์อนุมัติ'),
    ('asset_valuations', array[
      'id', 'asset_id', 'as_of', 'method', 'source_url', 'note', 'created_by', 'created_at',
      'revision'
    ], 'เมทาดาตาของการตีราคา · ตัวเลขมูลค่าแยกเป็น row (ดูด้านล่าง) · แถวถูกกรองด้วยขอบเขตทรัพย์'),
    ('assets', array[
      'id', 'code', 'name', 'class_id', 'category_id', 'owner_id', 'status', 'currency',
      'created_at'
    ], 'ชุดที่ฟอร์มคีย์รายการต้องใช้เลือกทรัพย์ (ชื่อ-รหัส-ชนิด-ผู้ถือ-สถานะ-สกุลเงิน) · ไม่บอกขนาดหรือโครงสร้างการถือ'),
    ('audit_log', array[
      'id', 'table_name', 'row_id', 'action', 'user_id', 'at'
    ], 'หัวร่องรอย (ตารางไหน แถวไหน ใคร เมื่อไร) · เนื้อแถวเต็มอยู่ใน before/after ซึ่งแยกเป็น row'),
    ('bank_accounts', array[
      'id', 'owner_id', 'bank', 'account_name', 'display_name', 'account_no_last4', 'coa_id',
      'short_label', 'color', 'sort_order', 'is_active', 'channel_type', 'created_at'
    ], 'ชุดที่ฟอร์มคีย์รายการต้องใช้เลือกบัญชี · coa_id เปิดเพราะ buildPosting() ต้องรู้คู่บัญชีของบัญชีธนาคารตอนคนคีย์ร่าง (ถ้าปิด Staff คีย์ร่างไม่ได้เลย)'),
    ('cash_confirmations', array[
      'id', 'transaction_id', 'draft_entry_id', 'bank_account_id', 'actual_date', 'is_partial',
      'confirmed_by', 'confirmed_at'
    ], 'เมทาดาตาการยืนยันเงิน · ตัวเลขและสลิปแยกเป็น row · ทั้งตารางต้องมี ledger.read ถึงจะเห็นแถว'),
    ('chart_of_accounts', array[
      'id', 'code', 'name_th', 'name_en', 'type', 'parent_id', 'peak_code', 'is_active',
      'sort_order', 'created_at'
    ], 'ผังบัญชี = ตารางกฎที่เครื่องยนต์บัญชีและหน้าจอทุกหน้าต้องอ่าน'),
    ('contact_links', array[
      'id', 'contact_id', 'target_type', 'target_id', 'role'
    ], 'การผูกผู้ติดต่อกับทรัพย์/สัญญา · ไม่มีตัวเลขเงิน'),
    ('contacts', array[
      'id', 'first_name', 'last_name', 'types', 'phone', 'line_id', 'email', 'is_active',
      'created_by', 'created_at'
    ], 'ชื่อและช่องทางติดต่อ · คนคีย์รายการต้องเลือกคู่สัญญาและติดต่อผู้เช่าได้ (หน้า /contacts ผูกกับสิทธิ์ txn.create)'),
    ('contracts', array[
      'id', 'code', 'asset_id', 'owner_id', 'type', 'counterparty_contact_id', 'rate_period',
      'interest_method', 'start_date', 'end_date', 'payment_day', 'installments',
      'notice_window_start', 'notice_window_end', 'redemption_deadline', 'status', 'created_at'
    ], 'โครงของสัญญา · ทั้งตารางต้องมี ledger.read + ขอบเขตทรัพย์ถึงจะเห็นแถว (fn_can_read_contract) จึงไม่มีระดับที่เห็นแถวแต่ไม่ควรเห็นคอลัมน์พวกนี้'),
    ('draft_entries', array[
      'id', 'owner_id', 'txn_type_code', 'doc_date', 'cash_date', 'asset_id', 'contact_id',
      'contract_id', 'memo', 'attachments', 'status', 'reject_reason', 'due_date', 'batch_id',
      'source', 'source_ref', 'posted_txn_id', 'created_by', 'reviewed_by', 'reviewed_at',
      'created_at'
    ], 'ร่างรายการที่ผู้ใช้คีย์เอง · แถวเป็นของผู้สร้าง (draft.read_own) หรือของคนที่มี ledger.read'),
    ('owners', array[
      'id', 'code', 'type', 'policy', 'name_th', 'name_en', 'vat_registered', 'status', 'color',
      'sort_order', 'created_at'
    ], 'ข้อมูลอ้างอิงผู้ถือที่ทุกหน้าจอและเครื่องยนต์บัญชีต้องใช้ · policy ต้องเปิดเพราะกติกาหลักฐานของนิติบุคคลขึ้นกับค่านี้'),
    ('period_closes', array[
      'id', 'owner_id', 'period', 'closed_by', 'closed_at'
    ], 'สถานะการปิดงวด · ไม่มีตัวเลขเงิน และฟอร์มต้องรู้ว่างวดปิดแล้วเพื่อกันการคีย์ย้อนหลัง'),
    ('permissions', array[
      'key', 'label', 'note', 'created_at'
    ], 'คำอธิบายสิทธิ์ · 20261007000003 ตัดสินแล้วว่าอ่านได้ทุกคน: รู้ว่ามีสิทธิ์อะไรไม่ได้ทำให้ได้สิทธิ์นั้น'),
    ('post_entry_requests', array[
      'id', 'fingerprint', 'created_by', 'transaction_ids', 'created_at'
    ], 'กันลงรายการซ้ำ · แถวเป็นของผู้สร้างเท่านั้น (created_by = auth.uid())'),
    ('role_permissions', array[
      'role_key', 'permission_key', 'granted_at'
    ], 'การจับคู่ระดับ-สิทธิ์ · อ่านได้ทุกคนตามเจตนาเดิม และแก้ได้จาก migration เท่านั้น'),
    ('roles', array[
      'key', 'label', 'rank_order', 'created_at'
    ], 'ชื่อระดับสิทธิ์ · หน้าจอต้องแสดงป้ายระดับของผู้ใช้'),
    ('schedules', array[
      'id', 'contract_id', 'period', 'due_date', 'txn_type_code', 'draft_entry_id', 'status',
      'created_at'
    ], 'โครงของงวด · แถวผูกกับสัญญาที่ต้องมี ledger.read ถึงจะเห็น · ตัวเลขเงินแยกเป็น row'),
    ('settings', array[
      'key', 'value', 'updated_by', 'updated_at'
    ], 'ค่าตั้งค่าระบบ (กฎข้อ 5) · หน้าจอทุกหน้าอ่าน · **ห้ามเก็บความลับที่นี่** (D-086: ความลับอยู่ env/Vault)'),
    ('txn_types', array[
      'code', 'group_code', 'name_th', 'name_en', 'cf_group', 'direction', 'dr_coa_code',
      'cr_coa_code', 'affects_pl', 'pl_line', 'requires_asset', 'requires_contact',
      'requires_loan_terms', 'requires_capital_gain', 'requires_principal_split', 'plain_th',
      'caution_th', 'is_active', 'sort_order', 'gain_coa_code', 'loss_coa_code',
      'interest_coa_code', 'accrual_coa_code', 'requires_transfer_target', 'can_accrue',
      'cash_direction'
    ], 'ตารางกฎประเภทรายการ · เครื่องยนต์บัญชีและฟอร์มต้องอ่านทั้งแถว (สำเนาของ src/lib/rules/tx-rules.ts)'),
    ('user_owner_access', array[
      'user_id', 'owner_id'
    ], 'ขอบเขตผู้ถือของผู้ใช้ · แถวเป็นของตัวเองหรือของคนที่จัดการผู้ใช้/เห็นทุก Entity'),
    ('column_exposure', array[
      'table_name', 'column_name', 'exposure', 'min_permission', 'rationale', 'created_at'
    ], 'ทะเบียนจัดประเภทคอลัมน์ · อ่านได้ทุกคนโดยเจตนา: รู้ว่าคอลัมน์ไหนปิดไม่ได้ทำให้อ่านคอลัมน์นั้นได้ (หลักเดียวกับตาราง permissions)'),
    ('column_exposure_tables', array[
      'table_name', 'review_state', 'reason', 'created_at'
    ], 'ทะเบียนขอบเขต · อ่านได้ทุกคนโดยเจตนา และเป็นที่ที่คนรุ่นถัดไปอ่านว่าตารางไหนยังไม่จัดประเภทเพราะอะไร')
  ) as t(tbl, cols, why), unnest(t.cols) c
on conflict (table_name, column_name) do update
  set exposure = excluded.exposure, min_permission = excluded.min_permission,
      rationale = excluded.rationale;

-- ---------- คอลัมน์ที่ปิดด้วยชั้น GRANT จริง ----------
insert into column_exposure (table_name, column_name, exposure, min_permission, rationale) values
  -- assets · ชุด "ขนาด/ลักษณะของทรัพย์" → ต้องเป็นคนที่ระบบให้ดูทรัพย์ได้
  --   Staff มีแต่ txn.create → ตกชั้นนี้ · Manager ผ่าน แต่ RLS ยังจำกัดเหลือทรัพย์ที่ตัวเองบริหาร
  ('assets', 'units',            'grant', 'asset.view_assigned', 'จำนวนหน่วย/ขนาดการถือ · คู่กับ ticker และราคาตลาดคือภาพรวมการลงทุน ซึ่งคนที่ลงข้อมูลไม่ต้องรู้'),
  ('assets', 'ticker',           'grant', 'asset.view_assigned', 'รหัสหลักทรัพย์ · บอกว่าบ้านนี้ถืออะไรอยู่ · คู่กับ units = ขนาดพอร์ต'),
  ('assets', 'holding_nature',   'grant', 'asset.view_assigned', 'ลักษณะการถือ (ชื่อบุคคลแต่เป็นกองกลาง ฯลฯ) · เป็นข้อมูลโครงสร้าง ไม่ใช่ข้อมูลที่ใช้คีย์รายการ'),
  ('assets', 'location',         'grant', 'asset.view_assigned', 'ที่ตั้งทรัพย์ · คนที่ไม่ได้ดูแลทรัพย์ไม่ต้องรู้ว่าทรัพย์อยู่ที่ไหน'),
  ('assets', 'size_note',        'grant', 'asset.view_assigned', 'ขนาด/เนื้อที่ · ใช้ประเมินมูลค่าได้ จึงอยู่ชั้นเดียวกับคนที่ดูแลทรัพย์'),
  ('assets', 'property_type',    'grant', 'asset.view_assigned', 'ชนิดอสังหาฯ แบบละเอียด · ใช้ตอนบริหารทรัพย์ ไม่ใช่ตอนคีย์รายการ'),
  ('assets', 'acquired_date',    'grant', 'asset.view_assigned', 'วันได้มา · เป็นฐานของต้นทุน/กำไรขาดทุน'),
  ('assets', 'disposed_date',    'grant', 'asset.view_assigned', 'วันจำหน่าย · เป็นฐานของกำไรขาดทุน'),
  ('assets', 'manager_user_id',  'grant', 'asset.view_assigned', 'ใครเป็นผู้บริหารทรัพย์ = ตัวกำหนดขอบเขตการมองเห็น (D-094) · คนที่ไม่ได้อยู่ชั้นนี้ไม่ต้องรู้ว่าใครดูแลอะไร'),
  ('assets', 'tags',             'grant', 'asset.view_assigned', 'ป้ายกำกับอิสระ · เป็นช่องข้อความที่ใส่อะไรก็ได้ จึงถือเป็นข้อมูลบริหารทรัพย์'),
  ('assets', 'ownership_pct',    'grant', 'portfolio.view_all',  'สัดส่วนการถือ = โครงสร้างการถือของครอบครัว · ลูกพี่สั่งว่า Manager ดูภาพรวมการลงทุนไม่ได้'),
  ('assets', 'beneficiary_id',   'grant', 'portfolio.view_all',  'ผู้รับประโยชน์ที่แท้จริง · เป็นภาพรวมของครอบครัว ไม่ใช่ข้อมูลที่ต้องใช้บริหารทรัพย์รายตัว'),
  ('assets', 'funding_source',   'grant', 'portfolio.view_all',  'แหล่งเงินที่ใช้ซื้อ · บอกการเคลื่อนเงินข้ามผู้ถือ = ภาพรวมการลงทุน'),
  -- bank_accounts · ยอดยกมาเป็นตัวเลขเงิน แต่แถวกรองแค่ผู้ถือ
  ('bank_accounts', 'opening_balance', 'grant', 'portfolio.view_all', 'ยอดยกมาของบัญชี = เงินสดที่มีจริง · แถวนี้ Staff (ไม่มี ledger.read) และ Manager (ไม่มี portfolio.view_all) เห็นได้ จึงต้องปิดที่คอลัมน์'),
  ('bank_accounts', 'opening_date',    'grant', 'portfolio.view_all', 'วันของยอดยกมา · คู่กับยอดยกมาเสมอ เปิดข้างเดียวไม่มีประโยชน์และยังบอกช่วงเวลาที่มีเงิน'),
  -- owners · contacts · policy อ่านเป็น true ทั้งตาราง
  ('owners',   'tax_id_last4', 'grant', 'settings.manage', 'เลขผู้เสียภาษีของผู้ถือ · ใช้ตอนตั้งค่า/ออกเอกสารภาษี ไม่ใช่ตอนคีย์รายการ · policy อ่านของตารางนี้เป็น true จึงต้องปิดที่คอลัมน์'),
  ('contacts', 'tax_id_last4', 'grant', 'settings.manage', 'เลขผู้เสียภาษีคู่ค้า · เหตุผลเดียวกับ owners.tax_id_last4'),
  ('contacts', 'note',         'grant', 'ledger.read',     'บันทึกอิสระเกี่ยวกับคู่ค้า (เงื่อนไข/ข้อควรระวัง/ข้อมูลส่วนตัว) · ไม่จำเป็นต่อการคีย์รายการ และคนทั้งบ้านอ่านได้เพราะ policy เป็น true')
on conflict (table_name, column_name) do update
  set exposure = excluded.exposure, min_permission = excluded.min_permission,
      rationale = excluded.rationale;

-- ---------- คอลัมน์ที่ policy ของแถวกันไว้แล้ว (ไม่ต้องมีด่านคอลัมน์) ----------
-- guard ตรวจทุกแถวในกลุ่มนี้ว่า **ทุก policy ที่อ่านได้** ของตารางนั้นยังบังคับสิทธิ์ที่ระบุ
-- ถ้ามีใครผ่อน policy หรือเพิ่ม policy กว้างๆ เข้ามา (permissive = OR กัน) → แดงทันที
insert into column_exposure (table_name, column_name, exposure, min_permission, rationale) values
  ('audit_log', 'before', 'row', 'owner.view_all', 'เก็บแถวเต็มก่อนแก้ของทุกตาราง = ช่องอ้อมของด่านคอลัมน์ · แถวต้องมี owner.view_all ซึ่งวันนี้มีแต่ระดับที่เห็นทุกอย่างอยู่แล้ว (guard ข้อ 7 ตรวจเงื่อนไขนี้ให้)'),
  ('audit_log', 'after',  'row', 'owner.view_all', 'เหตุผลเดียวกับ before'),
  ('contracts', 'principal',       'row', 'ledger.read', 'เงินต้นตามสัญญา · เห็นแถวได้ต้องมี ledger.read + ขอบเขตทรัพย์อยู่แล้ว'),
  ('contracts', 'rate',            'row', 'ledger.read', 'อัตราดอกเบี้ย · เหตุผลเดียวกับ principal'),
  ('contracts', 'deposit',         'row', 'ledger.read', 'เงินมัดจำ (D-088) · เหตุผลเดียวกับ principal'),
  ('contracts', 'collateral_note', 'row', 'ledger.read', 'รายละเอียดหลักประกัน · เหตุผลเดียวกับ principal'),
  ('contracts', 'file_urls',       'row', 'ledger.read', 'ไฟล์สัญญา · เหตุผลเดียวกับ principal (ตัวไฟล์ยังมีด่านของ Storage อีกชั้น)'),
  ('schedules', 'expected_amount',  'row', 'ledger.read', 'ยอดที่ควรได้รับ-จ่ายต่องวด · แถวผูกกับสัญญาที่ต้องมี ledger.read'),
  ('schedules', 'principal_amount', 'row', 'ledger.read', 'ส่วนเงินต้นของงวด · เหตุผลเดียวกับ expected_amount'),
  ('schedules', 'interest_amount',  'row', 'ledger.read', 'ส่วนดอกเบี้ยของงวด · เหตุผลเดียวกับ expected_amount'),
  ('asset_valuations', 'unit_price', 'row', 'asset.view_assigned', 'ราคาต่อหน่วยที่ตีไว้ · แถวถูกกรองด้วย fn_can_see_asset (ทั้งพอร์ตหรือทรัพย์ที่ตัวเองบริหาร)'),
  ('asset_valuations', 'value',      'row', 'asset.view_assigned', 'มูลค่าที่ตีไว้ · เหตุผลเดียวกับ unit_price'),
  ('cash_confirmations', 'expected_amount', 'row', 'ledger.read', 'ยอดที่คาด · ทั้งตารางต้องมี ledger.read ถึงจะเห็นแถว'),
  ('cash_confirmations', 'actual_amount',   'row', 'ledger.read', 'ยอดจริงที่เข้า-ออกบัญชี · เหตุผลเดียวกับ expected_amount'),
  ('cash_confirmations', 'slip_url',        'row', 'ledger.read', 'สลิป · เหตุผลเดียวกับ expected_amount'),
  ('draft_entries', 'amount', 'row', 'draft.read_own', 'ยอดในร่าง · เห็นได้เฉพาะร่างของตัวเอง (draft.read_own) หรือคนที่มี ledger.read')
on conflict (table_name, column_name) do update
  set exposure = excluded.exposure, min_permission = excluded.min_permission,
      rationale = excluded.rationale;

-- ---------- ทะเบียนแก้ได้จาก migration เท่านั้น ----------
-- แพทเทิร์นเดียวกับ 20261007000003: RLS เปิด · มี policy อ่าน · **ไม่มี policy เขียน**
-- (ไม่มี policy ของคำสั่งไหน = ปฏิเสธคำสั่งนั้น) → หน้า Settings เปลี่ยนด่านไม่ได้
do $$
declare t text;
begin
  foreach t in array array['column_exposure', 'column_exposure_tables'] loop
    execute format('alter table sri_os.%I enable row level security', t);
    execute format('drop policy if exists %I_read on sri_os.%I', t, t);
    execute format('create policy %I_read on sri_os.%I for select to authenticated using (true)', t, t);
    execute format('drop policy if exists %I_write on sri_os.%I', t, t);
    -- TRUNCATE ไม่ยิง row trigger และไม่ผ่าน RLS → ล้างทะเบียนทั้งตารางได้ในคำสั่งเดียว
    -- = ปลดด่านโดยไม่เหลือร่องรอย (เทสต์ H8 ของ 20261008000004 บังคับทุกตารางอยู่แล้ว)
    execute format('drop trigger if exists trg_forbid_truncate on sri_os.%I', t);
    execute format('create trigger trg_forbid_truncate before truncate on sri_os.%I for each statement execute function sri_os.fn_forbid_truncate()', t);
    -- audit: ทั้งสองตารางไม่มี id uuid → fn_audit_keyed พร้อมคีย์ธรรมชาติ
    execute format('drop trigger if exists trg_audit_%s on sri_os.%I', t, t);
  end loop;
end $$;

create trigger trg_audit_column_exposure
  after insert or update or delete on column_exposure
  for each row execute function fn_audit_keyed('table_name', 'column_name');
create trigger trg_audit_column_exposure_tables
  after insert or update or delete on column_exposure_tables
  for each row execute function fn_audit_keyed('table_name');

-- ============================================================
-- 3 · ตัวช่วย · "policy ของตารางนี้ยังบังคับสิทธิ์นี้อยู่ไหม"
--     ใช้กับการจัดประเภทแบบ `row` · ไล่ทุก policy ที่ทำให้อ่านแถวได้ (SELECT/ALL)
--     แล้วขยายด้วยเนื้อฟังก์ชันของ sri_os ที่ policy เรียก (ลึก 3 ชั้น)
--     เพราะเงื่อนไขจริงซ่อนอยู่ในฟังก์ชัน เช่น fn_can_read_contract → 'ledger.read'
-- ============================================================
create or replace function fn_policy_requires_permission(p_table text, p_permission text)
returns boolean
language plpgsql stable set search_path = '' as $fn$
declare
  r record; v_text text; v_prev text; i int; v_found boolean := false;
begin
  for r in
    select coalesce(p.qual, '') as qual
      from pg_policies p
     where p.schemaname = 'sri_os' and p.tablename = p_table
       and p.cmd in ('SELECT', 'ALL')
  loop
    v_found := true;
    v_text := r.qual;
    -- ขยายชื่อฟังก์ชัน → เนื้อฟังก์ชัน (เงื่อนไขจริงอยู่ข้างใน ไม่ได้อยู่ในตัว policy)
    for i in 1..3 loop
      v_prev := v_text;
      select v_prev || coalesce(string_agg(pr.prosrc, ' '), '') into v_text
        from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
       where ns.nspname = 'sri_os'
         and v_prev ~ ('\m' || pr.proname || '\M');
      exit when v_text = v_prev;
    end loop;
    -- policy ตัวใดตัวหนึ่งที่ไม่บังคับสิทธิ์นี้ = อ่านแถวได้โดยไม่มีสิทธิ์
    -- (policy เป็น permissive และ OR กัน) → ต้องตอบ false
    if position('''' || p_permission || '''' in v_text) = 0 then
      return false;
    end if;
  end loop;
  -- ไม่มี policy อ่านเลย = ไม่มีใครอ่านแถวได้ → ถือว่า "ยังไม่ครอบ" ไม่ใช่ปลอดภัย
  -- (ถ้าปล่อยผ่านแล้ววันหนึ่งมีคนเพิ่ม policy อ่านกว้างๆ เข้ามา guard จะไม่รู้ตัว)
  return v_found;
end $fn$;
comment on function fn_policy_requires_permission(text, text) is
  'D-089 · ตรวจว่า **ทุก** policy ที่ทำให้อ่านแถวของตารางได้ ยังบังคับสิทธิ์ที่ระบุ (ขยายผ่านเนื้อฟังก์ชันที่ policy เรียก 3 ชั้น) · ใช้ยืนยันเหตุผลของการจัดประเภทแบบ row · ไม่ใช่ตัวตัดสินสิทธิ์ตอนรันจริง';
revoke all on function fn_policy_requires_permission(text, text) from public;

-- ============================================================
-- 4 · ของใหม่ต้องไม่หลุดเงียบ (P4) · "อะไรยังไม่จัดประเภท"
-- ============================================================
create or replace function fn_column_exposure_unclassified()
returns table (object_kind text, object_name text, problem text)
language sql stable set search_path = '' as $fn$
  -- (ก) ตารางใน sri_os ที่ไม่มีแถวในทะเบียนขอบเขตเลย
  select 'table', c.relname::text,
         'ตารางใหม่ที่ยังไม่อยู่ใน column_exposure_tables → ไม่มีใครตัดสินว่าคอลัมน์ไหนปิด'
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os' and c.relkind = 'r'
     and not exists (select 1 from sri_os.column_exposure_tables t where t.table_name = c.relname)
  union all
  -- (ข) คอลัมน์ของตารางที่ประกาศว่า classified แล้ว แต่ยังไม่มีแถวจัดประเภท
  select 'column', (c.relname || '.' || a.attname)::text,
         'คอลัมน์ใหม่ที่ยังไม่จัดประเภทใน column_exposure'
    from pg_class c
    join pg_namespace ns on ns.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid
    join sri_os.column_exposure_tables t
         on t.table_name = c.relname and t.review_state = 'classified'
   where ns.nspname = 'sri_os' and c.relkind = 'r'
     and a.attnum > 0 and not a.attisdropped
     and not exists (
       select 1 from sri_os.column_exposure ce
        where ce.table_name = c.relname and ce.column_name = a.attname)
  union all
  -- (ค) ทะเบียนอ้างของที่ไม่มีจริง (สะกดผิด/เปลี่ยนชื่อ = ด่านที่ไม่ได้กันอะไร)
  select 'stale', (ce.table_name || '.' || ce.column_name)::text,
         'ทะเบียนอ้างคอลัมน์ที่ไม่มีอยู่จริงแล้ว → ด่านที่คิดว่ามีอาจไม่มี'
    from sri_os.column_exposure ce
   where not exists (
     select 1 from pg_class c
       join pg_namespace ns on ns.oid = c.relnamespace
       join pg_attribute a on a.attrelid = c.oid
      where ns.nspname = 'sri_os' and c.relname = ce.table_name
        and a.attname = ce.column_name and a.attnum > 0 and not a.attisdropped)
  union all
  select 'stale', t.table_name,
         'ทะเบียนขอบเขตอ้างตารางที่ไม่มีอยู่จริงแล้ว'
    from sri_os.column_exposure_tables t
   where not exists (
     select 1 from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
      where ns.nspname = 'sri_os' and c.relkind = 'r' and c.relname = t.table_name)
  union all
  -- (ง) ตารางที่ classified แต่ไม่มีแถวจัดประเภทเลย (ทะเบียนว่าง = ไม่ได้ตรวจอะไร)
  select 'table', t.table_name,
         'ประกาศว่า classified แต่ไม่มีคอลัมน์ใดถูกจัดประเภทเลย'
    from sri_os.column_exposure_tables t
   where t.review_state = 'classified'
     and not exists (select 1 from sri_os.column_exposure ce where ce.table_name = t.table_name)
$fn$;
comment on function fn_column_exposure_unclassified() is
  'D-089/P4 · คืนรายการตาราง/คอลัมน์ที่ยังไม่จัดประเภท หรือทะเบียนที่อ้างของที่ไม่มีจริง · ว่าง = ครบ';

-- ============================================================
-- 5 · ด่านติดจริงไหม (ไม่ใช่เขียนไว้เฉยๆ)
-- ============================================================
create or replace function fn_column_exposure_breaches()
returns table (breach_kind text, object_name text, problem text)
language sql stable set search_path = '' as $fn$
  -- (1) คอลัมน์ที่ต้องปิดด้วย GRANT แต่ authenticated ยังอ่านได้
  select 'readable', (ce.table_name || '.' || ce.column_name)::text,
         'คอลัมน์ที่จัดประเภทเป็น grant แต่ authenticated ยังมีสิทธิ์ select'
    from sri_os.column_exposure ce
   where ce.exposure = 'grant'
     and to_regclass('sri_os.' || quote_ident(ce.table_name)) is not null
     and has_column_privilege('authenticated', to_regclass('sri_os.' || quote_ident(ce.table_name)),
                              ce.column_name, 'select')
  union all
  -- (2) ตารางที่มีด่าน แต่ยังมี select ระดับตาราง → column grant ไม่มีผลเลย
  --     (บทเรียนของ 20261007000005: Postgres ไม่ยอมให้ "เจาะรู" ออกจาก grant ระดับตาราง)
  --     ไล่จาก ACL จริงของตาราง → ครอบ **ทุก role** ไม่ใช่แค่ authenticated
  --     (รวม PUBLIC และ service_role ที่วันนี้ยังไม่มีสิทธิ์ใน sri_os เลย)
  select 'table_grant', (c.relname || ' → ' ||
          case when acl.grantee = 0 then 'PUBLIC' else pg_get_userbyid(acl.grantee) end)::text,
         'ตารางที่มีคอลัมน์ปิด แต่ยังมี select ระดับตารางให้ role นี้ → ด่านคอลัมน์ไม่มีผล'
    from pg_class c
    join pg_namespace ns on ns.oid = c.relnamespace
    cross join lateral aclexplode(c.relacl) acl
   where ns.nspname = 'sri_os' and c.relkind = 'r'
     and acl.privilege_type = 'SELECT'
     and acl.grantee <> c.relowner
     and (acl.grantee = 0 or pg_get_userbyid(acl.grantee) <> 'sri_os_column_reader')
     and exists (select 1 from sri_os.column_exposure ce
                  where ce.table_name = c.relname and ce.exposure = 'grant')
  union all
  -- (3) คอลัมน์ที่ควรอ่านได้ แต่ด่านแน่นเกินจนอ่านไม่ได้ (P2 · ห้ามพังเส้นทางที่ถูก)
  select 'too_tight', (ce.table_name || '.' || ce.column_name)::text,
         'คอลัมน์ที่จัดประเภทว่าเปิด/กันด้วยแถว แต่ authenticated อ่านไม่ได้ → หน้าจอที่ต้องใช้จะพัง'
    from sri_os.column_exposure ce
   where ce.exposure in ('open', 'row')
     and to_regclass('sri_os.' || quote_ident(ce.table_name)) is not null
     and not has_column_privilege('authenticated', to_regclass('sri_os.' || quote_ident(ce.table_name)),
                                  ce.column_name, 'select')
  union all
  -- (4) เหตุผลของการจัดประเภทแบบ row ตายแล้ว (policy ถูกผ่อน/มี policy กว้างเพิ่มมา)
  select 'row_policy', (ce.table_name || '.' || ce.column_name)::text,
         'จัดประเภทเป็น row ด้วยสิทธิ์ ' || ce.min_permission ||
         ' แต่ policy อ่านของตารางไม่ได้บังคับสิทธิ์นั้นทุกตัวแล้ว'
    from sri_os.column_exposure ce
   where ce.exposure = 'row'
     and not sri_os.fn_policy_requires_permission(ce.table_name, ce.min_permission)
  union all
  -- (5) ทางเข้าของระดับที่มีสิทธิ์ต้องมีจริง · เป็น definer · เจ้าของเป็น role ที่ตั้งใจ ·
  --     อ่านอย่างเดียว · search_path แน่น · anon เรียกไม่ได้ · authenticated เรียกได้
  select 'reader_fn', ('fn_' || t.table_name || '_visible()')::text, x.problem
    from (select distinct table_name from sri_os.column_exposure where exposure = 'grant') t
    left join lateral (
      select p.* from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
       where ns.nspname = 'sri_os' and p.proname = 'fn_' || t.table_name || '_visible'
         and p.pronargs = 0
    ) p on true
    cross join lateral (select case
        when p.oid is null then 'ไม่มีฟังก์ชันทางเข้าสำหรับตารางที่มีคอลัมน์ปิด → ระดับที่มีสิทธิ์อ่านไม่ได้เลย'
        when not p.prosecdef then 'ฟังก์ชันทางเข้าไม่ใช่ security definer → อ่านคอลัมน์ที่ปิดไม่ได้'
        when pg_get_userbyid(p.proowner) <> 'sri_os_column_reader' then
             'เจ้าของฟังก์ชันคือ ' || pg_get_userbyid(p.proowner) ||
             ' · ถ้าเป็นเจ้าของตารางหรือ role ที่มี bypassrls ฟังก์ชันนี้จะข้าม RLS ทั้งหมด'
        when not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c
                          where c in ('search_path=', 'search_path=""')) then
             'search_path ไม่แน่น (definer ที่ search_path หลวม = ช่องยึดสิทธิ์)'
        when p.provolatile <> 's' then 'ต้องเป็น stable (อ่านอย่างเดียว)'
        when p.prosrc ~* '\m(insert|update|delete|merge|truncate|alter|drop|grant|revoke)\M' then
             'เนื้อฟังก์ชันมีคำสั่งเขียน → ทางเข้าสำหรับอ่านต้องอ่านเท่านั้น'
        when has_function_privilege('public', p.oid, 'execute') then 'PUBLIC เรียกได้'
        when exists (select 1 from pg_roles where rolname = 'anon')
             and has_function_privilege('anon', p.oid, 'execute') then 'anon เรียกได้'
        when not has_function_privilege('authenticated', p.oid, 'execute') then
             'authenticated เรียกไม่ได้ → ระดับที่มีสิทธิ์ก็อ่านไม่ได้'
        else null end as problem) x
   where x.problem is not null
  union all
  -- (6) ทางเข้าต้องครอบ **ทุกคอลัมน์ที่ปิด** และต้องถามสิทธิ์ที่ขึ้นทะเบียนไว้ตรงตัว
  select 'reader_mask', (ce.table_name || '.' || ce.column_name)::text,
         'ฟังก์ชันทางเข้าไม่ได้ครอบคอลัมน์นี้ด้วย fn_can(''' || ce.min_permission || ''')'
    from sri_os.column_exposure ce
   where ce.exposure = 'grant'
     and not exists (
       select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
        where ns.nspname = 'sri_os' and p.proname = 'fn_' || ce.table_name || '_visible'
          and p.prosrc ~ ('fn_can\(''' || ce.min_permission || '''\)[^,]*\m' || ce.column_name || '\M')
     )
  union all
  -- (7) ช่องอ้อมของการจัดประเภทแบบ row บน audit_log: ถ้ามีระดับไหนได้ owner.view_all
  --     แต่ไม่มี portfolio.view_all จะอ่านคอลัมน์ที่ปิดได้จาก before/after
  select 'audit_bypass', rp.role_key::text,
         'ระดับนี้มี owner.view_all (อ่าน audit_log ได้ = เห็นแถวเต็มของทุกตาราง) แต่ไม่มี portfolio.view_all → อ่านคอลัมน์ที่ปิดได้ทางอ้อม'
    from sri_os.role_permissions rp
   where rp.permission_key = 'owner.view_all'
     and not exists (select 1 from sri_os.role_permissions r2
                      where r2.role_key = rp.role_key and r2.permission_key = 'portfolio.view_all')
  union all
  -- (8) role เจ้าของทางเข้าต้องไม่กลายเป็นทางข้าม RLS
  select 'reader_role', 'sri_os_column_reader', x.problem
    from (
      select case
        when not exists (select 1 from pg_roles where rolname = 'sri_os_column_reader')
             then 'ไม่มี role เจ้าของทางเข้า'
        when (select rolsuper or rolbypassrls or rolcanlogin from pg_roles
               where rolname = 'sri_os_column_reader')
             then 'role เจ้าของทางเข้าเป็น superuser/bypassrls/login ได้ → ข้าม RLS'
        when exists (select 1 from pg_roles where rolname = 'authenticated')
             and not pg_has_role('sri_os_column_reader', 'authenticated', 'member')
             then 'role เจ้าของทางเข้าไม่ได้เป็นสมาชิกของ authenticated → policy ที่เขียน to authenticated จะไม่มีผล = ฟังก์ชันคืน 0 แถวทุกคน'
        when exists (select 1 from pg_auth_members m
                      join pg_roles r on r.oid = m.member
                      join pg_roles g on g.oid = m.roleid
                     where g.rolname = 'sri_os_column_reader')
             then 'มี role อื่นเป็นสมาชิกของ sri_os_column_reader → ใช้สิทธิ์ของมันได้โดยไม่ผ่านฟังก์ชัน'
        else null end as problem
    ) x
   where x.problem is not null
$fn$;
comment on function fn_column_exposure_breaches() is
  'D-089 · คืนรายการ "ด่านคอลัมน์ที่ไม่ติดจริง" ทั้งสองทิศ: ที่ควรปิดแต่เปิดอยู่ และที่ควรเปิดแต่ปิดจนหน้าจอพัง · ว่าง = ด่านติดครบ';

-- ============================================================
-- 6 · guard · ใช้ทั้งท้าย migration · ในเทสต์ · และตอนสร้างบัญชี Staff
-- ============================================================
create or replace function fn_column_exposure_guard() returns void
language plpgsql stable set search_path = '' as $fn$
declare v text; n int;
begin
  select string_agg(object_kind || ' ' || object_name || ' — ' || problem, E'\n  '), count(*)
    into v, n from sri_os.fn_column_exposure_unclassified();
  if n > 0 then
    raise exception 'ด่านคอลัมน์ (D-089): มี % รายการที่ยังไม่จัดประเภท →%  %',
      n, E'\n  ', v
      using hint = 'เพิ่มแถวใน sri_os.column_exposure / column_exposure_tables ด้วย migration ใหม่ (open ต้องมีเหตุผล · grant/row ต้องระบุสิทธิ์ขั้นต่ำ) แล้วเรียก sri_os.fn_apply_column_exposure()';
  end if;

  select string_agg(breach_kind || ' ' || object_name || ' — ' || problem, E'\n  '), count(*)
    into v, n from sri_os.fn_column_exposure_breaches();
  if n > 0 then
    raise exception 'ด่านคอลัมน์ (D-089): ด่าน % จุดไม่ติดจริง →%  %',
      n, E'\n  ', v
      using hint = 'รัน sri_os.fn_apply_column_exposure() ใหม่ (ต้องเป็น role ที่เป็นเจ้าของตาราง) หรือกู้สิ่งที่ถูกถอดออกด้วย migration ใหม่';
  end if;

  -- กัน guard กลายเป็น guard เปล่า: ถ้าทะเบียนว่างหรือตื้นเกิน สองข้อบนจะผ่านฟรีๆ
  select count(*) into n from sri_os.column_exposure;
  if n < 200 then
    raise exception 'ด่านคอลัมน์: ทะเบียนมีแค่ % แถว — น้อยกว่าจำนวนคอลัมน์ที่ sri_os มีจริง แปลว่า guard นี้อาจไม่ได้ตรวจอะไรเลย', n;
  end if;
  select count(*) into n from sri_os.column_exposure where exposure = 'grant';
  if n < 15 then
    raise exception 'ด่านคอลัมน์: มีคอลัมน์ที่ปิดด้วย GRANT แค่ % คอลัมน์ — ชุดที่ D-089 ระบุหายไป ต้องตรวจว่าใครถอดออก', n;
  end if;
end $fn$;
comment on function fn_column_exposure_guard() is
  'D-089 · พังทันทีเมื่อมีตาราง/คอลัมน์ใหม่ที่ยังไม่จัดประเภท หรือด่านคอลัมน์ไม่ติดจริง · เรียกจากท้าย migration · เทสต์ · และ trigger ตอนสร้างบัญชีระดับที่อ่าน ledger ไม่ได้';
revoke all on function fn_column_exposure_guard() from public;

-- ============================================================
-- 7 · ติดด่าน + สร้างทางเข้า · **สร้างจากทะเบียนทั้งคู่** (กฎเดียวห้ามเขียนสองที่)
-- ============================================================
create or replace function fn_apply_column_exposure() returns void
language plpgsql set search_path = '' as $fn$
declare
  r record;
  v_open   text;
  v_sig    text;
  v_body   text;
  v_n      int := 0;
begin
  -- ------------------------------------------------------------
  -- สิทธิ์ชั่วคราวที่จำเป็นต่อ `alter function ... owner to` ข้างล่าง
  -- ผู้รันต้อง (1) สวมบทบาท sri_os_column_reader ได้ และ
  --            (2) role นั้นต้องมีสิทธิ์ `create` บนสคีมาที่ฟังก์ชันอยู่
  --
  -- **อยู่ในฟังก์ชันไม่ใช่ในไฟล์** เพราะมีหลาย migration ที่เรียกฟังก์ชันนี้
  -- (ไฟล์นี้ · wht_and_fx · และหน้าตั้งค่าในอนาคตที่แก้ทะเบียนแล้วต้องเรียกซ้ำ)
  -- ถ้าวางไว้ที่ไฟล์เดียว ไฟล์อื่นจะพังด้วย error เดียวกัน
  --
  -- ทั้งสองข้อนี้ **ไม่เจอตอนทดสอบในเครื่อง** เพราะที่นั่นรันเป็น superuser
  -- ซึ่งข้ามการตรวจทั้งสองอย่าง · วัดจากของจริง 24/10
  -- ------------------------------------------------------------
  begin
    execute format('grant sri_os_column_reader to %I with inherit false, set true', current_user);
  exception when others then
    begin execute format('grant sri_os_column_reader to %I', current_user);
    exception when others then null; end;   -- superuser ไม่ต้องการสิทธิ์นี้
  end;
  begin
    execute 'grant create on schema sri_os to sri_os_column_reader';
  exception when others then null;
  end;
  for r in select distinct table_name from sri_os.column_exposure
            where exposure = 'grant' order by 1
  loop
    -- ---------- ชั้น GRANT ----------
    -- ถอนระดับตารางก่อนเสมอ · Postgres ไม่ยอมให้ revoke select (col) ออกจาก grant ระดับตาราง
    -- (ได้แค่ warning แล้วด่านไม่ติด — บทเรียนที่เขียนไว้ใน 20261007000005)
    execute format('revoke select on sri_os.%I from authenticated', r.table_name);

    select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into v_open
      from pg_attribute a
      join sri_os.column_exposure ce
           on ce.table_name = r.table_name and ce.column_name = a.attname
     where a.attrelid = ('sri_os.' || quote_ident(r.table_name))::regclass
       and a.attnum > 0 and not a.attisdropped
       and ce.exposure in ('open', 'row');
    if v_open is null then
      raise exception 'ตาราง sri_os.% ไม่มีคอลัมน์ที่เปิดเลย → ปิดทั้งตารางแบบนี้ทำให้ทุกหน้าจอที่ใช้มันพัง ต้องทบทวนการจัดประเภท', r.table_name;
    end if;
    execute format('grant select (%s) on sri_os.%I to authenticated', v_open, r.table_name);

    -- ---------- ทางเข้าของระดับที่มีสิทธิ์ ----------
    -- ครอบ **ทุกคอลัมน์ของตาราง** ตามลำดับจริง · คอลัมน์ที่ปิดถูกครอบด้วย fn_can()
    -- ของสิทธิ์ที่ขึ้นทะเบียนไว้ → ไม่มีทางที่ด่านกับทางเข้าจะถามสิทธิ์ไม่ตรงกัน
    select string_agg(format('%I %s', a.attname, format_type(a.atttypid, a.atttypmod)),
                      ', ' order by a.attnum),
           string_agg(case when ce.exposure = 'grant'
                           then format('case when sri_os.fn_can(%L) then t.%I end',
                                       ce.min_permission, a.attname)
                           else format('t.%I', a.attname) end,
                      ', ' order by a.attnum)
      into v_sig, v_body
      from pg_attribute a
      join sri_os.column_exposure ce
           on ce.table_name = r.table_name and ce.column_name = a.attname
     where a.attrelid = ('sri_os.' || quote_ident(r.table_name))::regclass
       and a.attnum > 0 and not a.attisdropped;

    execute format('drop function if exists sri_os.fn_%s_visible()', r.table_name);
    execute format($x$
create function sri_os.fn_%1$s_visible() returns table (%2$s)
language sql stable security definer set search_path = '' as $body$
  select %3$s from sri_os.%1$I t
$body$;
$x$, r.table_name, v_sig, v_body);

    execute format('alter function sri_os.fn_%s_visible() owner to sri_os_column_reader', r.table_name);
    execute format('revoke all on function sri_os.fn_%s_visible() from public', r.table_name);
    execute format('grant execute on function sri_os.fn_%s_visible() to authenticated', r.table_name);
    execute format('grant select on sri_os.%I to sri_os_column_reader', r.table_name);
    execute format($c$comment on function sri_os.fn_%1$s_visible() is 'ทางเข้าของระดับที่มีสิทธิ์อ่านคอลัมน์ที่ปิดของ sri_os.%1$s (D-089) · เจ้าของเป็น sri_os_column_reader ซึ่งเป็นสมาชิกของ authenticated → **RLS ยังกรองแถวตาม auth.uid() ของผู้เรียก** ไม่ได้เขียนเงื่อนไขแถวซ้ำ · คอลัมน์ที่ไม่มีสิทธิ์ได้ NULL · สร้างจากตาราง sri_os.column_exposure ห้ามแก้มือ'$c$, r.table_name);
    v_n := v_n + 1;
  end loop;
  -- ถอนสิทธิ์ชั่วคราวคืนทันที · **ต้องถอนทั้งสอง**
  --   สมาชิกภาพ: ด่าน reader_role ห้ามมี role อื่นเป็นสมาชิกของทางเข้า
  --              (ถ้าค้าง = ใช้สิทธิ์ของทางเข้าได้โดยไม่ต้องเดินผ่านทางเข้า)
  --   create on schema: ทางเข้านี้มีไว้ "อ่านแทน" ไม่ควรสร้างอะไรในสคีมาได้
  begin execute 'revoke create on schema sri_os from sri_os_column_reader';
  exception when others then null; end;
  begin execute format('revoke sri_os_column_reader from %I', current_user);
  exception when others then null; end;

  raise notice 'ด่านคอลัมน์ · ติดด่าน + สร้างทางเข้าให้ % ตาราง', v_n;
end $fn$;
comment on function fn_apply_column_exposure() is
  'D-089 · ติดด่านระดับคอลัมน์และสร้างฟังก์ชันทางเข้าจากตาราง column_exposure · รันซ้ำได้ · ต้องรันด้วย role ที่เป็นเจ้าของตาราง (migration) · ไม่ใช่ฟังก์ชันที่แอปเรียก';
revoke all on function fn_apply_column_exposure() from public;

-- ---------- ใครเรียกอะไรได้ ----------
-- ปิด PUBLIC ก่อนทุกตัว (Postgres ให้ EXECUTE แก่ PUBLIC เป็นค่าตั้งต้น → ไม่ปิด = anon ก็เรียกได้)
revoke all on function fn_column_exposure_unclassified() from public;
revoke all on function fn_column_exposure_breaches() from public;
do $$ begin
  -- `fn_apply_column_exposure` เปลี่ยนสิทธิ์และสร้างฟังก์ชัน → แอปต้องเรียกไม่ได้เด็ดขาด
  execute 'revoke all on function sri_os.fn_apply_column_exposure() from anon, authenticated';
  execute 'revoke all on function sri_os.fn_column_exposure_guard() from anon';
  execute 'revoke all on function sri_os.fn_policy_requires_permission(text, text) from anon';
  execute 'revoke all on function sri_os.fn_column_exposure_unclassified() from anon';
  execute 'revoke all on function sri_os.fn_column_exposure_breaches() from anon';
  -- **ต้องให้ authenticated เรียก guard ได้** เพราะ trigger ตอนสร้างบัญชี Staff
  -- ไม่ใช่ security definer → รันด้วยสิทธิ์คนที่กดเพิ่มผู้ใช้ (ซึ่งเป็น authenticated)
  -- ถ้าไม่ให้ หน้าจัดการผู้ใช้จะเพิ่มคนไม่ได้เลยด้วย permission denied
  -- (เหตุผลเดียวกับ fn_reverse_link_ok ใน 20261007000001)
  -- ทั้งสามตัวเป็นตัวอ่านอย่างเดียวและคืนแต่ข้อมูลของทะเบียนที่อ่านได้อยู่แล้ว
  execute 'grant execute on function sri_os.fn_column_exposure_guard() to authenticated';
  execute 'grant execute on function sri_os.fn_column_exposure_unclassified() to authenticated';
  execute 'grant execute on function sri_os.fn_column_exposure_breaches() to authenticated';
  execute 'grant execute on function sri_os.fn_policy_requires_permission(text, text) to authenticated';
exception when undefined_object then
  raise notice 'ไม่มี role anon/authenticated ในคลัสเตอร์นี้ — ข้าม revoke/grant';
end $$;

select fn_apply_column_exposure();

-- ถอนสมาชิกภาพชั่วคราวคืนทันทีที่ตั้งเจ้าของเสร็จ
-- **ต้องถอน** ไม่งั้นด่าน `reader_role` จะฟ้องว่ามี role อื่นเป็นสมาชิกของทางเข้า
-- ซึ่งแปลว่าใช้สิทธิ์ของทางเข้าได้โดยไม่ต้องผ่านฟังก์ชัน = ด่านคอลัมน์ไร้ผล
do $$
begin
  execute format('revoke sri_os_column_reader from %I', current_user);
exception when others then null;   -- ไม่เคยได้รับก็ไม่ต้องถอน
end $$;

-- ถอนสิทธิ์สร้างของในสคีมาคืนด้วย — ทางเข้านี้มีไว้ "อ่านแทน" เท่านั้น
-- ถ้าปล่อยไว้ มันสร้างฟังก์ชันหรือตารางใน sri_os ได้ ซึ่งเกินหน้าที่ไปมาก
revoke create on schema sri_os from sri_os_column_reader;

-- ============================================================
-- 8 · เงื่อนไขบังคับก่อนสร้างบัญชี Staff (D-089 สั่งห้ามสร้างจนกว่าจะปิดข้อนี้)
--     "ระดับ Staff" อ่านจากตารางสิทธิ์: ระดับที่ **ไม่มี ledger.read** = ลงข้อมูลได้
--     แต่อ่านสมุดไม่ได้ ตามคำสั่งลูกพี่ "Staff ทำได้แค่ลงข้อมูล"
--     → ห้ามดูชื่อ role ตรงๆ (D-073 · ชื่อระดับเปลี่ยนได้ สิทธิ์คือของจริง)
-- ============================================================
create or replace function fn_staff_requires_column_exposure() returns trigger
language plpgsql set search_path = '' as $fn$
begin
  if new.is_active
     and not exists (select 1 from sri_os.role_permissions rp
                      where rp.role_key = new.role and rp.permission_key = 'ledger.read')
  then
    begin
      perform sri_os.fn_column_exposure_guard();
    exception when others then
      raise exception 'D-089: ยังสร้าง/เปิดใช้บัญชีระดับที่อ่าน ledger ไม่ได้ (%) ไม่ได้ เพราะด่านคอลัมน์ยังไม่เรียบร้อย · ผู้ใช้ที่เห็นแถวได้จะอ่านทุกคอลัมน์ของแถวนั้น · สาเหตุ: %',
        new.role, sqlerrm
        using hint = 'จัดประเภทคอลัมน์ที่ค้างใน sri_os.column_exposure แล้วรัน sri_os.fn_apply_column_exposure() ด้วย migration ใหม่ · ตรวจด้วย select * from sri_os.fn_column_exposure_unclassified()';
    end;
  end if;
  return new;
end $fn$;
comment on function fn_staff_requires_column_exposure() is
  'D-089 · ปฏิเสธการสร้าง/เปิดใช้บัญชีระดับที่ไม่มี ledger.read ตราบใดที่ด่านคอลัมน์ยังไม่ครบ · ตัดสินจากตารางสิทธิ์ไม่ใช่ชื่อ role · ปลดได้ด้วย migration เท่านั้น (เอกสารห้ามไม่ได้ ของที่ห้ามได้คือ DB)';
revoke all on function fn_staff_requires_column_exposure() from public;
do $$ begin
  execute 'revoke all on function sri_os.fn_staff_requires_column_exposure() from anon, authenticated';
exception when undefined_object then null;
end $$;

drop trigger if exists trg_staff_requires_column_exposure on app_users;
create trigger trg_staff_requires_column_exposure
  before insert or update of role, is_active on app_users
  for each row execute function fn_staff_requires_column_exposure();
comment on trigger trg_staff_requires_column_exposure on app_users is
  'D-089: ห้ามสร้างบัญชี Staff จนกว่าด่านคอลัมน์จะปิด · บังคับที่ DB ไม่ใช่เอกสาร';

-- ============================================================
-- 9 · guard ท้ายไฟล์ · ถ้าของในไฟล์นี้ไม่ติดจริง migration ต้องพังทันที
-- ============================================================
do $$
declare n int; v text;
begin
  perform sri_os.fn_column_exposure_guard();

  -- ด่านต้องกันได้จริงกับ role ที่แอปใช้ (ไม่ใช่เชื่อว่า revoke แล้วต้องกันได้)
  if has_column_privilege('authenticated', 'sri_os.assets'::regclass, 'units', 'select')
     or has_column_privilege('authenticated', 'sri_os.bank_accounts'::regclass, 'opening_balance', 'select')
     or has_column_privilege('authenticated', 'sri_os.owners'::regclass, 'tax_id_last4', 'select')
  then
    raise exception 'ด่านคอลัมน์ไม่ติด: authenticated ยังอ่านคอลัมน์ตัวอย่างได้';
  end if;
  -- และต้องไม่แน่นเกิน (เส้นทางที่ถูกต้องต้องยังอ่านได้)
  if not has_column_privilege('authenticated', 'sri_os.assets'::regclass, 'code', 'select')
     or not has_column_privilege('authenticated', 'sri_os.bank_accounts'::regclass, 'coa_id', 'select')
  then
    raise exception 'ด่านคอลัมน์แน่นเกิน: ฟอร์มคีย์รายการจะเลือกทรัพย์/บัญชีไม่ได้';
  end if;

  -- trigger เงื่อนไข Staff ต้องติดจริงและเป็น before row
  if not exists (
    select 1 from pg_trigger tg
     where tg.tgrelid = 'sri_os.app_users'::regclass and not tg.tgisinternal
       and tg.tgname = 'trg_staff_requires_column_exposure'
       and (tg.tgtype & 1) <> 0 and (tg.tgtype & 2) <> 0
  ) then
    raise exception 'ไม่มี trigger เงื่อนไขก่อนสร้างบัญชี Staff (ต้องเป็น before ... for each row)';
  end if;

  -- ตารางทะเบียนต้องอ่านได้แต่เขียนไม่ได้จากแอป
  select string_agg(tablename || '.' || policyname || ' (' || cmd || ')', ', ') into v
    from pg_policies
   where schemaname = 'sri_os'
     and tablename in ('column_exposure', 'column_exposure_tables') and cmd <> 'SELECT';
  if v is not null then
    raise exception 'ทะเบียนด่านคอลัมน์มี policy เขียน: % · ต้องแก้ได้จาก migration เท่านั้น (ไม่งั้นเปลี่ยนด่านจากหน้า Settings ได้)', v;
  end if;

  select count(*) into n from sri_os.column_exposure where exposure = 'row';
  raise notice 'ด่านคอลัมน์ (D-089) · ทะเบียน % แถว · ปิดด้วย GRANT % คอลัมน์ · กันด้วยแถว % คอลัมน์ · เลื่อนไว้ % ตาราง',
    (select count(*) from sri_os.column_exposure),
    (select count(*) from sri_os.column_exposure where exposure = 'grant'),
    n,
    (select count(*) from sri_os.column_exposure_tables where review_state = 'deferred');
end $$;

-- ============================================================
-- ที่ต้องถามลูกพี่ (ตัดสินเองไม่ได้ · ทำส่วนที่ชัดเจนไปก่อนแล้ว)
--   1. `contacts.phone` · `line_id` · `email` เปิดให้ทุกคนที่ล็อกอิน (รวม Staff)
--      เพราะคนคีย์รายการต้องติดต่อผู้เช่า/คู่ค้าได้ · ถ้าลูกพี่ไม่ต้องการให้ Staff
--      เห็นเบอร์โทรทั้งบ้าน ย้ายเป็น grant + ledger.read ได้ในไฟล์ถัดไป
--   2. `bank_accounts.account_no_last4` เปิดไว้ (ฟอร์มมือถือแสดง "กสิกร ...1234"
--      ให้เลือกบัญชีถูกใบ) · ปิดได้ถ้ายอมให้เลือกจากชื่อย่ออย่างเดียว
--   3. `assets.ownership_pct` · `beneficiary_id` · `funding_source` ตั้งไว้ที่
--      portfolio.view_all = **Manager ไม่เห็นแม้ในทรัพย์ที่ตัวเองบริหาร**
--      (ตีความตามคำสั่ง "Manager ดูภาพรวมการลงทุนไม่ได้" และเลือกทางเข้มกว่า)
--      ถ้าลูกพี่เห็นว่าผู้บริหารทรัพย์ควรรู้สัดส่วนการถือของทรัพย์ที่ตัวเองดูแล
--      ย้ายเป็น asset.view_assigned ได้ = แก้แถวในทะเบียน + รัน fn_apply ใหม่
--   4. `settings.value` เปิดให้ทุกคน (หน้าจอทุกหน้าใช้) → **ห้ามเก็บความลับในนั้น**
--      ถ้าวันหนึ่งต้องเก็บค่าที่ไม่ควรให้ Staff เห็น ต้องแยกคีย์เป็นตาราง/คอลัมน์ใหม่
--      แล้วจัดประเภทเป็น grant ไม่ใช่ยัดลง value
--   5. `transactions` · `transaction_lines` ยัง deferred (D-098 ถืออยู่) ·
--      ต้องกลับมาจัดประเภททันทีที่งานนั้นปิด ไม่งั้นสองตารางใหญ่สุดไม่มีด่านคอลัมน์
-- ============================================================
