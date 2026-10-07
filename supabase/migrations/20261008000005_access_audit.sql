-- ============================================================
-- SRI OS · ร่องรอยของ "ใครเห็นเงินของใครได้" และของตารางรอบนอกที่เหลือ
--   เทสต์: supabase/tests/zz_access_audit_test.sql
--   รุ่นก่อนของเรื่องเดียวกัน: 20261008000002 (asset_valuations) ·
--   20261008000003 (cash_confirmations · audit_log · period_closes) ·
--   20261008000004 (contracts · schedules · TRUNCATE ทุกตาราง)
--
-- ห้าตารางที่รอบก่อนไล่เจอแล้วรายงานไว้ แต่ยังไม่มี audit:
--   user_owner_access · app_users · settings · contacts · contact_links
-- ทั้งห้ากัน TRUNCATE แล้ว (20261008000004) แต่ **ไม่มีร่องรอยการเปลี่ยนแปลงเลย**
--
-- **ตัดสินเหมือนกันทั้งห้า: เพิ่ม audit · ไม่ปิด DELETE/UPDATE** ซึ่งต่างจาก
-- 20261008000002/3/4 ที่ปิดการลบ — ความต่างคือใจความของไฟล์นี้ ใครแก้ต่อให้อ่านให้จบ
--
-- ------------------------------------------------------------
-- (1) user_owner_access · app_users — สำคัญที่สุดของรอบนี้
-- ------------------------------------------------------------
--   สองตารางนี้คือตัวกำหนด **ใครเห็นเงินของใครได้**: user_owner_access คือขอบเขต
--   ตามผู้ถือ (fn_can_see_owner อ่านตารางนี้ → RLS ของสมุดบัญชีทั้งระบบขึ้นกับมัน)
--   ส่วน app_users คือใครอยู่ตำแหน่งไหน (fn_can อ่าน role จากตารางนี้)
--
--   ลบแถวใน user_owner_access = เปลี่ยนว่าใครเห็นอะไร **โดยไม่เหลือร่องรอย**
--   ลบแถวใน app_users = ถอนคนออกจากระบบเงียบๆ (และ user_owner_access.user_id เป็น
--   `on delete cascade` → ขอบเขตทั้งหมดของคนนั้นหายตามไปในคำสั่งเดียว)
--
--   **ไม่ปิด DELETE** เพราะการถอนสิทธิ์และถอนคนออกเป็นงานปกติที่ต้องทำได้
--   (คนลาออก · เปลี่ยนขอบเขต) ปิดแล้วจะบริหารคนไม่ได้ — ที่เราต้องการไม่ใช่
--   "ห้ามถอนสิทธิ์" แต่คือ **รู้ว่าใครถอนเมื่อไหร่** เพราะวันที่มีคนเห็นเงินที่ไม่ควรเห็น
--   ต้องย้อนได้ว่าสิทธิ์เปลี่ยนตอนไหน · audit จึงสำคัญกว่าการปิดในข้อนี้
--   guard ท้ายไฟล์ตรวจ **ทั้งสองทิศ**: ต้องมี audit **และต้องไม่มี** trigger กัน DELETE
--
-- ------------------------------------------------------------
-- (2) settings — กฎข้อ 5 ของ CLAUDE.md
-- ------------------------------------------------------------
--   "ทุกอย่างที่ตั้งค่าได้อยู่ในตาราง config" → ตารางนี้เปลี่ยนพฤติกรรมระบบได้
--   และ policy settings_write กั้นด้วยสิทธิ์ settings.manage เท่านั้น
--   **ไม่ปิด DELETE/UPDATE** (ตั้งค่าต้องแก้ได้) · เพิ่มแต่ร่องรอย
--
--   **สภาพวันนี้ที่รายงานไว้แล้ว**: ตารางนี้ยัง **ว่างเปล่า** (ไม่มี seed แม้แถวเดียว)
--   และ `src/**` ไม่อ่าน/เขียน sri_os.settings เลย → **ยังไม่มีค่าตั้งค่าตัวใดที่
--   กระทบตัวเลขเงินโดยตรง** (อัตราภาษีอยู่ที่ transactions.vat_rate ซึ่งสำรองไว้เฟส 2 ·
--   วันปิดงวดอยู่ที่ตาราง period_closes · สกุลเงินอยู่ที่ assets.currency)
--   ถ้าวันหนึ่งใส่คีย์ที่กระทบตัวเลข (อัตราภาษี · เพดานดอกเบี้ย · วิธีคิดต้นทุน)
--   **audit อย่างเดียวไม่พอ** ต้องกลับมาตัดสินว่าจะล็อกคีย์นั้นแบบไหน — ห้ามใส่เงียบๆ
--
-- ------------------------------------------------------------
-- (3) contacts · contact_links — audit พอ
-- ------------------------------------------------------------
--   คู่ค้าและความเชื่อมโยง · FK กันการลบ contact ที่ผูกกับรายการไว้แล้วจริง
--   (transactions.contact_id และ contracts.counterparty_contact_id เป็น
--    NO ACTION → ลบแล้ว 23503 · เทสต์ X4/X5 พิสูจน์)
--   ส่วน contact_links.contact_id เป็น `on delete cascade` → ลบคู่ค้าที่ยังไม่ผูก
--   รายการได้ และแถวเชื่อมโยงหายตามไป · **ไฟล์นี้ทำให้ขา cascade เหลือร่องรอยด้วย**
--   เพราะติด audit ที่ contact_links เองไม่ใช่กันแต่ตารางแม่ (เทสต์ X6)
--   **ไม่ปิด DELETE** (เพิ่ม/แก้/ลบคู่ค้าที่คีย์ผิดเป็นงานปกติ)
--
-- ------------------------------------------------------------
-- (4) owners — เพิ่ม audit ด้วย (เกินรายการห้าข้อ · เหตุผลอยู่ที่นี่)
-- ------------------------------------------------------------
--   ไม่ได้อยู่ในรายการที่สั่งมา แต่ guard ข้อ (6) บังคับว่าตารางที่ **แอปเขียนได้
--   ตอนรันจริง** ต้องมี audit และ owners เข้าเกณฑ์นั้นเต็มตัว: policy owners_write
--   เป็น FOR ALL ด้วยสิทธิ์ settings.manage → เพิ่มผู้ถือใหม่ · แก้ชื่อ/เลขภาษี/ธง VAT ·
--   และ **ลบผู้ถือฝั่งบุคคลได้** (fn_owners_rule_columns_immutable กันแต่ corporate_strict)
--   ทุกแถวในระบบมี owner_id → การเปลี่ยนรายชื่อผู้ถือกระทบการกรอง Entity ทุกหน้า
--   ทางเลือกอีกทางคือใส่ owners ใน allow-list ซึ่งต้องอ้างเหตุผลที่ไม่จริง
--   (อ้างว่า "เขียนได้จาก migration เท่านั้น" ทั้งที่ policy เปิดให้แอปเขียน)
--   → เลือกเพิ่ม audit แทนการเว้นเงียบ · ไม่แตะ policy และไม่ปิดการลบ
--
-- ------------------------------------------------------------
-- (5) fn_audit ใช้กับ settings / user_owner_access **ไม่ได้** — ข้อบกพร่องที่เจอรอบนี้
-- ------------------------------------------------------------
--   fn_audit (20260917000002) เขียน row_id จาก `coalesce(new.id, old.id)` และ
--   audit_log.row_id เป็น `uuid not null` → ตารางที่ไม่มีคอลัมน์ id แบบ uuid
--   จะล้มทันทีด้วย 42703 `record "new" has no field "id"`
--   พิสูจน์แล้วกับทั้งสองตาราง (settings PK = key text · user_owner_access PK =
--   (user_id, owner_id)) → **ติด fn_audit ตรงๆ แปลว่าแก้ค่าตั้งค่าหรือเปลี่ยนขอบเขต
--   การเห็นไม่ได้อีกเลยทั้งระบบ** ไม่ใช่แค่ audit ไม่ทำงาน
--
--   ทางเลือกที่ **ไม่** เลือก และเหตุผล:
--     - เปลี่ยน audit_log.row_id เป็น text → แตะตารางหลักฐานที่ห้ามลบ/ห้ามแก้
--       และ index เดิม (table_name, row_id) กับโค้ดที่อ่านอยู่ต้องตามทั้งหมด
--     - เพิ่มคอลัมน์ id ให้สองตาราง → เพิ่มคอลัมน์ให้ตารางที่ RLS/fn_can พึ่งพา
--       เพื่อความสะดวกของ audit เป็นการให้หางกระดิกหัว และ `src/**` ต้องตามด้วย
--   → เลือก **fn_audit_keyed()** แทน: audit ตัวเดียวกันแต่คำนวณ row_id จากคีย์ธรรมชาติ
--     ที่ประกาศไว้ตอน create trigger (`execute function fn_audit_keyed('key')`)
--     row_id = md5(ชื่อตาราง + คีย์)::uuid ซึ่ง **คงที่** → ลบแถวแล้วใส่กลับ
--     ได้ row_id เดิม = ไล่ไทม์ไลน์ของสิทธิ์เส้นเดียวกันต่อได้ ซึ่งเป็นสิ่งที่ต้องการ
--     ค่าคีย์จริงไม่ได้หายไป: before/after เก็บแถวเต็มเป็น jsonb อยู่แล้ว
--     และสูตรของ row_id อยู่ใน **fn_audit_row_id() ตัวเดียว** ที่ทั้ง trigger และ
--     คนอ่านรายงานเรียกตัวเดียวกัน (กฎเดียวกันห้ามเขียนสองที่)
--
--   guard ข้อ (6ค)/(6ง) บังคับการเลือกใช้ให้ถูกตัว: ตารางที่มี id uuid ต้องใช้
--   fn_audit · ตารางที่ไม่มีต้องใช้ fn_audit_keyed และ **args ต้องตรงกับ PK จริง**
--   → วันที่ PK เปลี่ยนแล้วลืมแก้ trigger migration/เทสต์พังทันที ไม่ใช่ audit ชี้ผิดแถวเงียบๆ
--
-- ------------------------------------------------------------
-- (6) guard · "ตารางใน sri_os ต้องมี audit" ไล่จาก pg_trigger จริง
-- ------------------------------------------------------------
--   แบบเดียวกับ guard ของ TRUNCATE (20261008000004) และของ RLS (20261006190000):
--   ไล่จาก catalog ไม่ใช่รายชื่อที่พิมพ์มือ → ตารางใหม่ที่ไม่มี audit ทำให้
--   **migration และเทสต์แดงทันที** ไม่ต้องมาไล่มือทุกครั้ง
--
--   ตรวจสามชั้น ไม่ใช่แค่ "มี trigger ติดอยู่":
--     - ต้องครอบ **ทั้ง INSERT + UPDATE + DELETE** (ของจริงรอบนี้เจอมาแล้วว่าคำว่า
--       "มี audit แล้ว" บางทีครอบแค่ขาเดียว → ตรวจ bitmask แยกต่อคำสั่ง)
--     - ต้องเป็น AFTER (BEFORE ... จะไม่เห็นค่าหลัง default/trigger อื่นเติม)
--     - ต้องใช้ฟังก์ชันที่เขียน audit_log จริง (fn_audit / fn_audit_keyed เท่านั้น)
--
--   **allow-list: ตารางที่ไม่มี audit ได้ · มีเหตุผลกำกับรายตัว และเหตุผลนั้น
--   ถูกตรวจด้วยเครื่อง** (เหตุผลที่เป็นแค่ข้อความจะเน่าเงียบๆ) ถ้าเงื่อนไขที่รองรับ
--   เหตุผลหายไป guard พังทันที:
--
--     audit_log           — ตัว audit เอง · fn_audit insert ลงตารางนี้ → ติด audit
--                           บนตัวเองคือเรียกตัวเองไม่จบ · และ append-only จริงแล้ว
--                           (20261008000003) ทุกแถวคือร่องรอยอยู่แล้ว
--                           เงื่อนไขที่ตรวจ: ต้องมี trigger กัน UPDATE **และ** DELETE
--
--     asset_valuations    — append-only จริง: DELETE กันด้วย trg_forbid_delete_valuation
--                           (20261008000002) · UPDATE กันด้วย fn_valuation_revision
--                           (20261008000001) · INSERT ออกเลข revision ให้เอง
--                           → แถวใหม่คือประวัติ ไม่มี mutation ที่จะหายไปได้
--                           เงื่อนไขที่ตรวจ: มีด่าน DELETE และ **ไม่มี** policy
--                           UPDATE/DELETE/ALL (วันที่เปิด UPDATE เหตุผลนี้ตายทันที)
--
--     ตารางกฎ/อ้างอิง 7 ตาราง — chart_of_accounts · txn_types · asset_classes ·
--                           asset_categories · roles · permissions · role_permissions
--                           RLS เปิดแค่ SELECT (ไม่มี policy เขียนแม้ตัวเดียว ·
--                           20261007000003/4 · 20261007000006) → **แอปเขียนไม่ได้เลย**
--                           เส้นทางเปลี่ยนเดียวคือ migration ซึ่งเป็นไฟล์ใน git
--                           (`npm run sync:rules` **generate ไฟล์ migration**
--                            ไม่ได้เขียน DB ตอนรัน — ตรวจแล้วที่ scripts/sync-txn-types.ts)
--                           ร่องรอยของตารางกลุ่มนี้จึงอยู่ใน git ไม่ใช่ใน audit_log
--                           เงื่อนไขที่ตรวจ: **ต้องไม่มี policy ที่ไม่ใช่ SELECT**
--                           วันที่ใครเปิดให้หน้าจอแก้ผังบัญชี/ตารางกฎได้ เหตุผลนี้ตาย
--                           → guard พัง และต้องกลับมาตัดสินใหม่ (ตารางกฎคือคู่บัญชี
--                              ของทุกรายการในอนาคต แก้เงียบๆ = ตัวเลขผิดทั้งระบบ)
--
--   **ที่เหลือไม่มีข้อยกเว้น** — ตารางอื่นทุกตารางต้องมี audit ครบสามคำสั่ง
--
-- ------------------------------------------------------------
-- สิ่งที่ไฟล์นี้ **ไม่ทำ** โดยตั้งใจ (ต้องให้ตัดสินก่อน · บทเรียนข้อ 7)
-- ------------------------------------------------------------
--   - ไม่ปิด DELETE/UPDATE ที่ตารางไหนเลย และไม่แตะ policy แม้ตัวเดียว
--   - ไม่เพิ่ม policy DELETE ให้ contacts (วันนี้ไม่มี → authenticated ลบคู่ค้าไม่ได้
--     เงียบๆ 0 แถว · ของจริงลบได้แค่ superuser/service_role) ปล่อยไว้ตามเดิม
--     แต่ตอนนี้ **มีร่องรอยแล้ว** ถ้าเส้นทางนั้นถูกใช้
--   - ไม่แตะ `on delete cascade` ของ app_users → user_owner_access และของ
--     contacts → contact_links (cascade ยิง row trigger จริง → audit ติดครบทั้งคู่
--     เทสต์ X3/X6 พิสูจน์) · การเปลี่ยนเป็น restrict คือเปลี่ยนเส้นทางบริหารคน
--   - ไม่แก้สิ่งที่รายงานไว้ว่า "ถอนคนออกด้วย DELETE จะติด FK": app_users ถูกอ้าง
--     จาก transactions.created_by/approved_by และอีก 10 จุดแบบ NO ACTION → คนที่เคย
--     ลงรายการจะลบไม่ได้ (23503) เส้นทางที่ใช้ได้จริงคือ `is_active = false`
--     ซึ่งตอนนี้มีร่องรอยแล้ว · เทสต์ X8 ตรึงพฤติกรรมนี้ไว้ให้เห็น ไม่ใช่แก้เอง
--
-- ------------------------------------------------------------
-- ทำไม trigger (หลักเดียวกับ 20261007000000 · 20261008000002/3/4)
-- ------------------------------------------------------------
--   RLS มีผลกับ authenticated เท่านั้น · service_role และเจ้าของฐานข้อมูลอยู่นอก
--   ชั้นนั้นทั้งหมด → ร่องรอยต้องเกิดที่ชั้นที่ไม่มีใครข้ามได้
--   fn_audit_keyed **ไม่ถามสิทธิ์** (ห้ามเรียก fn_can — เทสต์ X0 กันอยู่) เพราะ
--   "ต้องเหลือร่องรอย" เท่ากันทุกตำแหน่ง และต้องปิดไม่ได้จากหน้า Settings
--   แต่ **ต้องเป็น SECURITY DEFINER** เหมือน fn_audit เพราะ audit_log ไม่มี policy
--   INSERT → ถ้าเป็น invoker ผู้ใช้ปกติจะเขียนร่องรอยไม่ได้ แล้ว **ทุก mutation
--   ของห้าตารางนี้จะล้มทั้งหมด** · จึงต้อง revoke execute ให้หมดในไฟล์เดียวกัน
--   (default privileges ของ 20261007000001 เปิด execute ให้ authenticated กับ
--    ฟังก์ชันใหม่ทุกตัว → ไม่ถอนทันทีคือเปิดประตู SECURITY DEFINER ทิ้งไว้)
--   ส่วน fn_audit_row_id เป็นฟังก์ชันคำนวณล้วน (immutable · ไม่อ่านตารางไหน) และ
--   **คงสิทธิ์ให้ authenticated เรียกได้โดยเจตนา** เพราะคนที่มี owner.view_all
--   ต้องใช้มันค้น audit ของ settings/user_owner_access (policy audit_read) ·
--   public/anon ยังเรียกไม่ได้
--
-- ------------------------------------------------------------
-- ถ้าวันหนึ่งต้องลบร่องรอยของสิทธิ์จริงๆ
-- ------------------------------------------------------------
--   ลบไม่ได้: audit_log เป็น append-only ตาม 20261008000003 (ห้าม DELETE/UPDATE
--   ทุก role) · ส่วนการ **ถอด audit trigger** ทำได้ผ่าน migration เท่านั้น และ
--   guard ข้อ (6) จะทำให้ migration ถัดไปพังถ้าถอดแล้วไม่ใส่ allow-list พร้อมเหตุผล
--   ที่ตรวจด้วยเครื่องได้ · **ห้ามถอดทิ้งไว้เฉยๆ**
--
-- ------------------------------------------------------------
-- ย้อนกลับ (rollback)
-- ------------------------------------------------------------
--   -- drop trigger if exists trg_audit_user_owner_access on sri_os.user_owner_access;
--   -- drop trigger if exists trg_audit_settings           on sri_os.settings;
--   -- drop trigger if exists trg_audit_app_users          on sri_os.app_users;
--   -- drop trigger if exists trg_audit_contacts           on sri_os.contacts;
--   -- drop trigger if exists trg_audit_contact_links      on sri_os.contact_links;
--   -- drop trigger if exists trg_audit_owners             on sri_os.owners;
--   -- drop function if exists sri_os.fn_audit_keyed();
--   -- drop function if exists sri_os.fn_audit_row_id(text, text[], jsonb);
--   -- (**ห้าม** drop trg_forbid_truncate ของหกตารางนี้ — เป็นของ 20261008000004)
--   -- ย้อนแล้ว: ถอนสิทธิ์การเห็นเงิน · ถอนคนออกจากระบบ · แก้ค่าตั้งค่า ·
--   --           ลบคู่ค้า · เพิ่ม-ลบผู้ถือ กลับไปไม่เหลือร่องรอยเหมือนเดิม
--   --           และ guard "ทุกตารางต้องมี audit" หายไปด้วย
--
-- idempotent: create or replace function · drop trigger if exists ก่อน create ·
--   ไม่แตะข้อมูล ไม่เพิ่ม/ลบคอลัมน์ ไม่แตะ policy ไม่แตะ FK · revoke/grant ซ้ำได้
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 1 · fn_audit_row_id · สูตรเดียวของ row_id สำหรับตารางที่ไม่มี id แบบ uuid
--     ทั้ง trigger และคนอ่านรายงานใช้ตัวนี้ตัวเดียว (ห้ามเขียนสูตรซ้ำที่อื่น)
--
--     ตัวอย่างการใช้ฝั่งอ่าน — "แถวสิทธิ์เส้นนี้เคยถูกแก้อะไร":
--       select * from sri_os.audit_log
--        where table_name = 'user_owner_access'
--          and row_id = sri_os.fn_audit_row_id('user_owner_access',
--                         array['user_id','owner_id'],
--                         jsonb_build_object('user_id', :u, 'owner_id', :o))
--        order by at;
-- ============================================================
create or replace function fn_audit_row_id(p_table text, p_keys text[], p_row jsonb)
  returns uuid
language sql immutable strict set search_path = '' as $fn$
  -- ผสมชื่อตารางเข้าไปด้วย เพื่อให้ตารางต่างกันไม่ชนกันแม้คีย์ซ้ำค่า
  select md5(p_table || coalesce(
           (select string_agg('|' || k || '=' || coalesce(p_row ->> k, '<null>'), ''
                              order by ord)
              from unnest(p_keys) with ordinality as t(k, ord)), ''))::uuid
$fn$;

comment on function fn_audit_row_id(text, text[], jsonb) is
  'คำนวณ audit_log.row_id จากคีย์ธรรมชาติ สำหรับตารางที่ไม่มีคอลัมน์ id แบบ uuid (settings · user_owner_access) · คงที่: ลบแล้วใส่กลับได้ row_id เดิม → ไล่ไทม์ไลน์เส้นเดียวกันต่อได้ · ค่าคีย์จริงอ่านได้จาก before/after ที่เก็บแถวเต็มเป็น jsonb · ฝั่งอ่านรายงานเรียกตัวนี้ตัวเดียวกับที่ fn_audit_keyed ใช้';

revoke all on function fn_audit_row_id(text, text[], jsonb) from public;
do $$ begin
  execute 'revoke all on function sri_os.fn_audit_row_id(text, text[], jsonb) from anon';
  -- คงไว้ให้ authenticated โดยเจตนา: คนที่มี owner.view_all ต้องใช้ค้น audit
  -- ของ settings/user_owner_access ผ่าน policy audit_read (ดูหัวไฟล์)
  execute 'grant execute on function sri_os.fn_audit_row_id(text, text[], jsonb) to authenticated';
exception when undefined_object then
  raise notice 'ไม่มี role anon/authenticated ในคลัสเตอร์นี้ — ข้าม revoke/grant';
end $$;

-- ============================================================
-- 2 · fn_audit_keyed · audit ตัวเดียวกับ fn_audit แต่สำหรับตารางที่ไม่มี id uuid
--     คีย์ประกาศตอน create trigger · ข้อมูลไม่ครบ = **ปฏิเสธ ไม่ใช่เดา**
--     (ถ้าเดา row_id ให้ ร่องรอยจะชี้ไปผิดแถวเงียบๆ ซึ่งแย่กว่าไม่มีร่องรอย)
-- ============================================================
create or replace function fn_audit_keyed() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_before jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_after  jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  v_row    jsonb := coalesce(v_after, v_before);
  v_col    text;
begin
  if tg_nargs = 0 then
    raise exception 'fn_audit_keyed ต้องระบุคอลัมน์คีย์ตอน create trigger (ตาราง %) · ไม่ระบุ = ไม่รู้ว่าร่องรอยนี้เป็นของแถวไหน', tg_table_name;
  end if;
  foreach v_col in array tg_argv loop
    if not (v_row ? v_col) then
      raise exception 'fn_audit_keyed: ตาราง % ไม่มีคอลัมน์ % ที่ประกาศเป็นคีย์ของ trigger · คีย์เปลี่ยนแล้วแต่ trigger ยังชี้ชื่อเดิม', tg_table_name, v_col;
    end if;
    if (v_row ->> v_col) is null then
      raise exception 'fn_audit_keyed: คีย์ %.% เป็น null → ร่องรอยชี้กลับไปหาแถวไม่ได้', tg_table_name, v_col;
    end if;
  end loop;

  insert into sri_os.audit_log(table_name, row_id, action, before, after, user_id)
  values (
    tg_table_name,
    sri_os.fn_audit_row_id(tg_table_name, tg_argv, v_row),
    lower(tg_op),
    v_before,
    v_after,
    auth.uid()
  );
  return coalesce(new, old);
end $fn$;

comment on function fn_audit_keyed() is
  'audit สำหรับตารางที่ไม่มีคอลัมน์ id แบบ uuid (settings PK = key · user_owner_access PK = (user_id, owner_id)) · fn_audit เดิมใช้ไม่ได้เพราะอ่าน new.id แล้วล้ม 42703 ซึ่งจะทำให้แก้ค่าตั้งค่า/เปลี่ยนขอบเขตการเห็นไม่ได้ทั้งระบบ · คีย์ประกาศตอน create trigger และ guard ของ 20261008000005 บังคับให้ตรงกับ PK จริง · SECURITY DEFINER เพราะ audit_log ไม่มี policy INSERT · ไม่ถามสิทธิ์และเรียกจากข้างนอกไม่ได้';

revoke all on function fn_audit_keyed() from public;
do $$ begin
  execute 'revoke all on function sri_os.fn_audit_keyed() from anon, authenticated';
exception when undefined_object then
  raise notice 'ไม่มี role anon/authenticated ในคลัสเตอร์นี้ — ข้าม revoke';
end $$;

-- ============================================================
-- 3 · ติด audit · ตารางที่มี id แบบ uuid ใช้ fn_audit เดิม (ห้ามเขียนกฎซ้ำ)
--     ไม่มี trigger กัน DELETE/UPDATE ที่นี่ **โดยตั้งใจ** — ดูหัวไฟล์ข้อ (1)–(4)
-- ============================================================
drop trigger if exists trg_audit_app_users on app_users;
create trigger trg_audit_app_users
  after insert or update or delete on app_users
  for each row execute function fn_audit();

comment on trigger trg_audit_app_users on app_users is
  'ร่องรอย "ใครอยู่ตำแหน่งไหน" · การถอนคนออก (DELETE) ยังทำได้ตามเจตนา แต่ต้องเห็นว่าใครถอนเมื่อไหร่ · หมายเหตุ: คนที่เคยลงรายการจะลบไม่ได้เพราะ FK NO ACTION จาก transactions.created_by → เส้นทางจริงคือ is_active = false ซึ่งก็มีร่องรอยที่นี่';

drop trigger if exists trg_audit_contacts on contacts;
create trigger trg_audit_contacts
  after insert or update or delete on contacts
  for each row execute function fn_audit();

drop trigger if exists trg_audit_contact_links on contact_links;
create trigger trg_audit_contact_links
  after insert or update or delete on contact_links
  for each row execute function fn_audit();

comment on trigger trg_audit_contact_links on contact_links is
  'ติดที่ตารางลูกเองไม่ใช่กันแต่ตารางแม่ · contact_links.contact_id เป็น on delete cascade → ลบคู่ค้าแล้วแถวเชื่อมโยงหายตามไป ถ้าไม่ติดที่นี่ขา cascade จะไร้ร่องรอย (เทสต์ X6)';

drop trigger if exists trg_audit_owners on owners;
create trigger trg_audit_owners
  after insert or update or delete on owners
  for each row execute function fn_audit();

comment on trigger trg_audit_owners on owners is
  'ทุกแถวในระบบมี owner_id · policy owners_write (FOR ALL ด้วย settings.manage) ให้แอปเพิ่ม/แก้/ลบผู้ถือฝั่งบุคคลได้ตอนรันจริง → ต้องมีร่องรอย · เกินรายการที่สั่งมา เหตุผลอยู่ที่หัวไฟล์ข้อ (4)';

-- ============================================================
-- 4 · ติด audit · ตารางที่ **ไม่มี** id แบบ uuid → fn_audit_keyed + คีย์ธรรมชาติ
--     คีย์ที่ส่งต้องตรงกับ PK จริง · guard ข้อ 5(ง) ตรวจให้
-- ============================================================
drop trigger if exists trg_audit_settings on settings;
create trigger trg_audit_settings
  after insert or update or delete on settings
  for each row execute function fn_audit_keyed('key');

comment on trigger trg_audit_settings on settings is
  'ร่องรอยของตาราง config (กฎข้อ 5 ของ CLAUDE.md) · ไม่ปิด DELETE/UPDATE เพราะค่าตั้งค่าต้องแก้ได้ · ใช้ fn_audit_keyed เพราะ PK = key (text) ไม่มี id uuid ให้ fn_audit อ่าน';

drop trigger if exists trg_audit_user_owner_access on user_owner_access;
create trigger trg_audit_user_owner_access
  after insert or update or delete on user_owner_access
  for each row execute function fn_audit_keyed('user_id', 'owner_id');

comment on trigger trg_audit_user_owner_access on user_owner_access is
  'ร่องรอยของ "ใครเห็นเงินของใครได้" (fn_can_see_owner อ่านตารางนี้ → RLS ของสมุดบัญชีทั้งระบบขึ้นกับมัน) · ไม่ปิด DELETE เพราะถอน/เปลี่ยนขอบเขตเป็นงานปกติ ที่ต้องการคือรู้ว่าใครถอนเมื่อไหร่ · รวมขา cascade จากการลบ app_users (เทสต์ X3)';

-- ============================================================
-- 5 · guard ของไฟล์นี้เอง — ถ้ากฎไม่ติดจริง migration ต้องพังทันที
--     ไม่ใช่รอให้เทสต์จับทีหลัง (ไฟล์นี้อาจถูก apply บน project ก่อนเทสต์)
--     ตรวจทั้งสองทิศ: ของที่ต้องมี **และของที่ต้องไม่มี**
-- ============================================================
do $$
declare
  -- allow-list · ตารางที่ไม่มี audit ได้ · เหตุผลรายตัวอยู่ที่หัวไฟล์ข้อ (6)
  -- และเงื่อนไขที่รองรับเหตุผลถูกตรวจด้านล่าง ไม่ใช่เชื่อข้อความ
  c_append_only text[] := array['audit_log', 'asset_valuations'];
  c_read_only   text[] := array['chart_of_accounts', 'txn_types', 'asset_classes',
                                'asset_categories', 'roles', 'permissions',
                                'role_permissions'];
  c_audited     text[] := array['app_users', 'user_owner_access', 'settings',
                                'contacts', 'contact_links', 'owners'];
  n int; v text; r text;
begin
  -- (ก) หกตารางของรอบนี้ต้องมี audit ครบ **สามคำสั่ง** และเป็น AFTER FOR EACH ROW
  foreach r in array c_audited loop
    select count(*) into n
      from pg_trigger tg
      join pg_proc p on p.oid = tg.tgfoid
     where tg.tgrelid = ('sri_os.' || r)::regclass
       and not tg.tgisinternal
       and p.proname in ('fn_audit', 'fn_audit_keyed')
       and (tg.tgtype & 4) <> 0       -- INSERT
       and (tg.tgtype & 16) <> 0      -- UPDATE
       and (tg.tgtype & 8) <> 0       -- DELETE
       and (tg.tgtype & 2) = 0        -- AFTER (bit 2 = BEFORE)
       and (tg.tgtype & 1) <> 0;      -- FOR EACH ROW
    if n <> 1 then
      raise exception 'audit ของ sri_os.% ไม่ครบ: ต้องมี after insert or update or delete for each row ที่เรียก fn_audit/fn_audit_keyed พอดี 1 ตัว (เจอ %)', r, n;
    end if;
  end loop;

  -- (ข) **ของที่ต้องไม่มี**: trigger ที่ขัดขวาง DELETE/UPDATE/INSERT ของหกตารางนี้
  --     นี่คือจุดที่ "กันแน่นเกิน" จะผิด → บริหารคน/สิทธิ์/ค่าตั้งค่า/คู่ค้าไม่ได้
  select string_agg(tg.tgrelid::regclass::text || '.' || tg.tgname, ', ') into v
    from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
   where tg.tgrelid = any (select ('sri_os.' || x)::regclass from unnest(c_audited) x)
     and not tg.tgisinternal
     and p.proname like 'fn\_forbid%'
     and p.proname <> 'fn_forbid_truncate';   -- กัน TRUNCATE คือของ 20261008000004
  if v is not null then
    raise exception 'มี trigger ขัดขวาง DML ของตารางสิทธิ์/ค่าตั้งค่า/คู่ค้า: % · การถอนสิทธิ์ ถอนคนออก แก้ค่าตั้งค่า และแก้คู่ค้า ต้องยังทำได้ (ต้องการร่องรอย ไม่ใช่ห้ามทำ)', v;
  end if;
  -- และ policy ที่เป็นเส้นทางของงานปกติต้องยังอยู่
  foreach r in array array['app_users|users_write', 'user_owner_access|owner_access_write',
                           'settings|settings_write', 'contact_links|contact_links_write',
                           'contacts|contacts_update', 'owners|owners_write'] loop
    if not exists (select 1 from pg_policies
                    where schemaname = 'sri_os'
                      and tablename  = split_part(r, '|', 1)
                      and policyname = split_part(r, '|', 2)) then
      raise exception 'policy % หายไป → เส้นทางบริหารคน/สิทธิ์/ค่าตั้งค่า/คู่ค้าเดินไม่ได้', r;
    end if;
  end loop;

  -- (ค) ตารางที่ใช้ fn_audit ต้องมีคอลัมน์ id แบบ uuid จริง
  --     ข้อนี้คือข้อบกพร่องที่เจอรอบนี้: fn_audit อ่าน new.id → ไม่มีก็ล้ม 42703
  --     ทุก mutation ของตารางนั้น ไม่ใช่แค่ audit ไม่ทำงาน
  select string_agg(distinct c.relname, ', ') into v
    from pg_class c
    join pg_namespace ns on ns.oid = c.relnamespace
    join pg_trigger tg on tg.tgrelid = c.oid and not tg.tgisinternal
    join pg_proc p on p.oid = tg.tgfoid
   where ns.nspname = 'sri_os' and c.relkind = 'r' and p.proname = 'fn_audit'
     and not exists (select 1 from pg_attribute a
                      where a.attrelid = c.oid and a.attname = 'id'
                        and a.attnum > 0 and not a.attisdropped
                        and a.atttypid = 'uuid'::regtype);
  if v is not null then
    raise exception 'ตารางที่ติด fn_audit แต่ไม่มีคอลัมน์ id แบบ uuid: % · fn_audit อ่าน new.id → ทุก insert/update/delete ของตารางนั้นจะล้มด้วย 42703 ไม่ใช่แค่ audit ไม่ทำงาน · ใช้ fn_audit_keyed พร้อมคีย์ธรรมชาติแทน', v;
  end if;

  -- (ง) ตารางที่ใช้ fn_audit_keyed: ต้องไม่มี id uuid (ไม่งั้นใช้ตัวที่ง่ายกว่าได้)
  --     และ args ของ trigger ต้องตรงกับคอลัมน์ PK จริงเรียงตามลำดับ
  for r in select c.relname from pg_class c
             join pg_namespace ns on ns.oid = c.relnamespace
             join pg_trigger tg on tg.tgrelid = c.oid and not tg.tgisinternal
             join pg_proc p on p.oid = tg.tgfoid
            where ns.nspname = 'sri_os' and p.proname = 'fn_audit_keyed'
            group by c.relname
  loop
    if exists (select 1 from pg_attribute a
                where a.attrelid = ('sri_os.' || r)::regclass and a.attname = 'id'
                  and a.attnum > 0 and not a.attisdropped
                  and a.atttypid = 'uuid'::regtype) then
      raise exception 'sri_os.% มี id แบบ uuid อยู่แล้ว → ต้องใช้ fn_audit ไม่ใช่ fn_audit_keyed (กฎเดียวกันห้ามมีสองเส้นทาง)', r;
    end if;
    select string_agg(quote_literal(a.attname), ', ' order by k.ord) into v
      from pg_constraint con
      join unnest(con.conkey) with ordinality as k(attnum, ord) on true
      join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum
     where con.conrelid = ('sri_os.' || r)::regclass and con.contype = 'p';
    if v is null then
      raise exception 'sri_os.% ไม่มี primary key → คีย์ของ audit อ้างอะไรไม่ได้', r;
    end if;
    if not exists (select 1 from pg_trigger tg
                    where tg.tgrelid = ('sri_os.' || r)::regclass
                      and not tg.tgisinternal
                      and tg.tgfoid = 'sri_os.fn_audit_keyed'::regproc
                      and pg_get_triggerdef(tg.oid) like '%fn_audit_keyed(' || v || ')') then
      raise exception 'trigger audit ของ sri_os.% ส่งคีย์ไม่ตรงกับ primary key (ต้องเป็น fn_audit_keyed(%)) · ไม่ตรงแปลว่าร่องรอยชี้ผิดแถวเงียบๆ', r, v;
    end if;
  end loop;

  -- (จ) **guard หลักของไฟล์นี้**: ทุกตารางใน sri_os ต้องมี audit ครบสามคำสั่ง
  --     ยกเว้น allow-list · ไล่จาก pg_trigger จริง ตารางใหม่ที่ลืมจะพังที่นี่
  select string_agg(c.relname, ', ' order by c.relname), count(*) into v, n
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os' and c.relkind = 'r'
     and not (c.relname = any (c_append_only))
     and not (c.relname = any (c_read_only))
     and not exists (
       select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
        where tg.tgrelid = c.oid and not tg.tgisinternal
          and p.proname in ('fn_audit', 'fn_audit_keyed')
          and (tg.tgtype & 4) <> 0 and (tg.tgtype & 16) <> 0 and (tg.tgtype & 8) <> 0
          and (tg.tgtype & 2) = 0 and (tg.tgtype & 1) <> 0);
  if n > 0 then
    raise exception '% ตารางใน sri_os ไม่มี audit ที่ครอบ insert+update+delete: % · ถ้าตารางนั้นไม่ควรมี audit จริงๆ ให้เพิ่มใน allow-list ของ 20261008000005 พร้อมเหตุผลและเงื่อนไขที่ตรวจด้วยเครื่องได้ ห้ามเว้นเงียบ', n, v;
  end if;
  select count(*) into n from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os' and c.relkind = 'r';
  if n < 25 then
    raise exception 'นับตารางใน sri_os ได้แค่ % ตาราง — guard นี้อาจไม่ได้ตรวจอะไรเลย', n;
  end if;

  -- (ฉ) allow-list ต้องมีจริงทุกชื่อ (สะกดผิด = ยกเว้นตารางที่ไม่มีอยู่ แล้วของจริงหลุด)
  foreach r in array c_append_only || c_read_only loop
    if not exists (select 1 from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
                    where ns.nspname = 'sri_os' and c.relkind = 'r' and c.relname = r) then
      raise exception 'allow-list อ้างตารางที่ไม่มีอยู่: sri_os.% · สะกดผิดหรือตารางถูกลบ', r;
    end if;
  end loop;

  -- (ช) เงื่อนไขของ allow-list กลุ่ม append-only · เหตุผลคือ "แถวเองคือประวัติ"
  --     ถ้า UPDATE/DELETE เปิดได้ เหตุผลตายทันที → guard ต้องพัง
  if not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                  where tg.tgrelid = 'sri_os.audit_log'::regclass
                    and p.proname like 'fn\_forbid%'
                    and (tg.tgtype & 8) <> 0 and (tg.tgtype & 16) <> 0) then
    raise exception 'audit_log ไม่ได้ append-only แล้ว (ไม่มี trigger กันทั้ง DELETE และ UPDATE) → เหตุผลที่ยกเว้นมันจาก audit ใช้ไม่ได้อีก';
  end if;
  if not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                  where tg.tgrelid = 'sri_os.asset_valuations'::regclass
                    and p.proname like 'fn\_forbid%' and (tg.tgtype & 8) <> 0) then
    raise exception 'asset_valuations ไม่มีด่าน DELETE แล้ว → เหตุผลที่ยกเว้นมันจาก audit ใช้ไม่ได้อีก';
  end if;
  select string_agg(policyname, ', ') into v from pg_policies
   where schemaname = 'sri_os' and tablename = 'asset_valuations'
     and cmd in ('UPDATE', 'DELETE', 'ALL');
  if v is not null then
    raise exception 'asset_valuations มี policy % → ไม่ใช่ append-only อีกแล้ว ต้องมี audit หรือกลับมาตัดสินใหม่', v;
  end if;

  -- (ซ) เงื่อนไขของ allow-list กลุ่มตารางกฎ/อ้างอิง · เหตุผลคือ "แอปเขียนไม่ได้เลย
  --     เส้นทางเดียวคือ migration ที่เป็นไฟล์ใน git" → มี policy เขียนแม้ตัวเดียว
  --     เหตุผลตาย (ตารางกฎคือคู่บัญชีของทุกรายการในอนาคต)
  select string_agg(tablename || '.' || policyname || ' (' || cmd || ')', ', ') into v
    from pg_policies
   where schemaname = 'sri_os' and tablename = any (c_read_only)
     and cmd <> 'SELECT';
  if v is not null then
    raise exception 'ตารางกฎ/อ้างอิงมี policy เขียน: % · เหตุผลที่ยกเว้นจาก audit คือ "แอปเขียนไม่ได้ เปลี่ยนได้จาก migration ใน git เท่านั้น" ซึ่งใช้ไม่ได้อีก → ต้องเพิ่ม audit หรือกลับมาตัดสินใหม่', v;
  end if;

  -- (ฌ) ฟังก์ชันใหม่ต้องไม่หลวม: fn_audit_keyed ต้องเรียกจากข้างนอกไม่ได้และไม่ถามสิทธิ์
  select string_agg(p.proname, ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_audit_keyed'
     and (p.prosrc ~* 'fn_can'
       or has_function_privilege('public', p.oid, 'execute'));
  if v is not null then
    raise exception 'fn_audit_keyed หลวมเกินไป (เรียก fn_can / PUBLIC execute ได้): %', v;
  end if;
  if not (select p.prosecdef from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
           where ns.nspname = 'sri_os' and p.proname = 'fn_audit_keyed') then
    raise exception 'fn_audit_keyed ไม่เป็น SECURITY DEFINER → audit_log ไม่มี policy INSERT แปลว่าผู้ใช้ปกติแก้ค่าตั้งค่า/เปลี่ยนขอบเขตการเห็นไม่ได้เลย';
  end if;
  select string_agg(p.proname, ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_audit_row_id'
     and (p.provolatile <> 'i' or p.prosrc ~* 'fn_can'
       or has_function_privilege('public', p.oid, 'execute'));
  if v is not null then
    raise exception 'fn_audit_row_id หลวมเกินไป (ไม่ immutable / เรียก fn_can / PUBLIC execute ได้): %', v;
  end if;

  raise notice 'guard · audit ครบทุกตารางใน sri_os (ยกเว้น allow-list % ตารางที่มีเงื่อนไขตรวจแล้ว) · DELETE/UPDATE ของตารางสิทธิ์-ค่าตั้งค่า-คู่ค้า ยังเปิดตามเจตนา · fn_audit_keyed ปิดถูก',
    cardinality(c_append_only) + cardinality(c_read_only);
end $$;
