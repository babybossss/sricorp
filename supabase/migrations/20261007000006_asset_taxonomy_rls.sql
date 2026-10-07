-- ============================================================
-- SRI OS · asset_classes / asset_categories: เปิด RLS + อ่านได้เท่านั้น
--           และ guard ว่า "ทุกตารางใน sri_os ต้องเปิด RLS และต้องมี policy"
--
-- ทำไม (ผู้ตรวจ 07/10 · รันเองบน Postgres ในเครื่อง):
--   สองตารางนี้ **ไม่เคยถูก `alter table ... enable row level security` เลย**
--   (relrowsecurity = false · policy 0 ตัว) และ 20261006190000 ก็ไม่ sweep ให้
--   เพราะไม่ได้อยู่ในรายการตารางที่ไฟล์นั้นดูแล
--   ตอนที่ไม่มีใครมี ACL บน sri_os เลย เรื่องนี้ไม่มีผล — แต่ 20261007000001_grants.sql
--   เปิด select/insert/update/delete ให้ `authenticated` → RLS ที่ปิดอยู่
--   แปลว่า **ไม่มีด่านอะไรเลย** · session ที่เป็น authenticated และ
--   **ไม่มีแถวใน app_users แม้แต่แถวเดียว** (ยังไม่ถูกตั้งตำแหน่ง) ลบได้จริง:
--     delete from asset_categories → DELETE 15
--     delete from asset_classes    → DELETE 4
--   ผล: ทรัพย์ทุกตัวอ้าง class_id ที่หายไป · หน้าทรัพย์และการจัดกลุ่มงบพัง
--   (FK กันไม่ให้ลบ class ที่มีทรัพย์ผูกอยู่เท่านั้น — class ที่ยังไม่มีทรัพย์ลบได้หมด)
--
-- ตัดสิน: `enable row level security` + policy `for select using (true)` **เท่านั้น**
--   ให้เหมือนตารางอ้างอิงอื่น (txn_types · chart_of_accounts · roles · permissions)
--   เพราะสองตารางนี้เป็น **สำเนา** ของ src/lib/rules/asset-classes.ts
--   (ASSET_CLASSES / หมวดย่อยของทรัพย์) ซึ่งเป็นแหล่งความจริงเดียวตาม CLAUDE.md
--   คอมเมนต์เดิมใน 20260917000003 เขียนว่า "asset taxonomy (config แก้ได้)"
--   → **คอมเมนต์นั้นผิด** ตั้งแต่วันที่ taxonomy ย้ายไปอยู่ในโค้ด · แก้คอมเมนต์ท้ายไฟล์นี้
--
-- สิ่งที่ยังทำได้: **เพิ่มทรัพย์** (ตาราง assets คนละตัว policy เดิมไม่ถูกแตะ) ·
--   อ่าน taxonomy ได้ทุกตำแหน่ง (ฟอร์มเพิ่มทรัพย์ต้องมีรายการ class/category ให้เลือก)
--   เพิ่ม/แก้ class ใหม่ = แก้ src/lib/rules/asset-classes.ts แล้วออก migration
--
-- ย้อนกลับ (rollback):
--   -- drop policy if exists asset_classes_read    on sri_os.asset_classes;
--   -- drop policy if exists asset_categories_read on sri_os.asset_categories;
--   -- alter table sri_os.asset_classes     disable row level security;
--   -- alter table sri_os.asset_categories  disable row level security;
--   -- (ย้อนแล้ว authenticated คนไหนก็ลบ taxonomy ได้หมด — ไม่แนะนำ)
--
-- idempotent: enable rls ซ้ำได้ · drop policy if exists ก่อน create
-- ============================================================

set search_path = sri_os, public;

do $$
declare t text;
begin
  foreach t in array array['asset_classes', 'asset_categories'] loop
    execute format('alter table sri_os.%I enable row level security', t);
    execute format('drop policy if exists %I_read on sri_os.%I', t, t);
    execute format('create policy %I_read on sri_os.%I for select to authenticated using (true)', t, t);
    -- ไม่มี policy เขียน = RLS ปฏิเสธ insert/update/delete ของทุก role ที่มาจากแอป
    execute format('drop policy if exists %I_write on sri_os.%I', t, t);
    execute format('drop policy if exists %I_all on sri_os.%I', t, t);
  end loop;
end $$;

comment on table asset_classes is
  'สำเนากลุ่มทรัพย์จาก src/lib/rules/asset-classes.ts · **อ่านได้เท่านั้น** (ไม่มี write policy) · เพิ่มกลุ่มใหม่ = แก้โค้ดแล้วออก migration';
comment on table asset_categories is
  'สำเนาหมวดย่อยของทรัพย์จาก src/lib/rules/asset-classes.ts · **อ่านได้เท่านั้น** (ไม่มี write policy)';

-- ============================================================
-- guard · ทุกตารางใน sri_os ต้องเปิด RLS **และ** ต้องมี policy อย่างน้อยหนึ่งตัว
--
--   ไม่ auto-enable ให้ตารางที่เพิ่มใหม่ในอนาคต เพราะ "เปิด RLS แต่ไม่มี policy"
--   = ปฏิเสธทุกอย่าง**เงียบๆ** (0 แถว ไม่ใช่ error) → หน้าจอว่างโดยไม่มีอะไรบอกว่าทำไม
--   (เจอมาแล้ว · เป็นเหตุผลเดียวกับหัวไฟล์ 20261007000003)
--   ตารางใหม่ต้องมีคนตัดสินว่าใครเห็นอะไร แล้วเขียน policy ลง migration
--   → ที่นี่จึง **พังให้เห็น** ไม่ใช่เดาแทน
-- ============================================================
do $$
declare v_off text; v_nopol text;
begin
  select string_agg(c.relname, ', ' order by c.relname) into v_off
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'sri_os' and c.relkind = 'r' and not c.relrowsecurity;
  if v_off is not null then
    raise exception 'ตารางใน sri_os ที่ยังไม่เปิด RLS: % · เปิด RLS แล้วเขียน policy ลง migration ก่อน (grants ให้ DML ทุกตารางอยู่ = RLS ปิด แปลว่าไม่มีด่านเลย)', v_off;
  end if;

  select string_agg(c.relname, ', ' order by c.relname) into v_nopol
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'sri_os' and c.relkind = 'r'
     and not exists (select 1 from pg_policies p
                      where p.schemaname = 'sri_os' and p.tablename = c.relname);
  if v_nopol is not null then
    raise exception 'ตารางใน sri_os ที่เปิด RLS แต่ไม่มี policy เลย: % · จะปฏิเสธทุกอย่างเงียบๆ (0 แถว ไม่ใช่ error) แล้วหน้าจอจะว่างโดยไม่มีอะไรฟ้อง', v_nopol;
  end if;
end $$;
