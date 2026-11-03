-- ============================================================
-- SRI OS · owners: คอลัมน์ที่เป็น "กติกา" ห้ามเปลี่ยนจากแอป — และห้ามเปลี่ยนเลย
--
-- ทำอะไร (สองชั้น เพราะชั้นเดียวไม่พอทั้งคู่):
--   ชั้น GRANT  — `revoke update on owners` แล้ว `grant update (<คอลัมน์ที่แก้ได้>)`
--                 RLS กันเป็นคอลัมน์ไม่ได้ (policy เห็นแถวทั้งแถว ไม่เห็นว่าแก้ช่องไหน)
--                 จึงต้องใช้ column-level grant · ผลคือแอปได้ permission denied
--                 ทันทีที่พยายามแก้ช่องที่ล็อก = **error ไม่ใช่ 0 แถวเงียบๆ**
--   ชั้น TRIGGER — ปฏิเสธการเปลี่ยนค่าในคอลัมน์กติกา **ทุก role รวม superuser**
--                 เพราะ column grant ไม่มีผลกับ superuser / BYPASSRLS / postgres
--                 (เส้นทาง psql ของผู้ดูแล · Edge Function ที่เผลอใช้ service key)
--
-- ทำไม (ผู้ตรวจ 07/10 · รันเองบน Postgres ในเครื่อง):
--   ในฐานะ management ยิงได้จริง:
--     update owners set policy='personal_flexible' where policy='corporate_strict'
--       → UPDATE 3  (SRI_CORP · SRI_HOLDING · SRI_CAPITAL)
--   LEDGER_RULES.md §4 และ CLAUDE.md เขียนว่า corporate_strict **ห้าม override**
--   แต่คำสั่งเดียวนี้ปลดทั้งองค์กรลงมาเป็น personal_flexible ซึ่ง "override ได้
--   ถ้าใส่เหตุผล" → กติกาที่ห้าม override กลายเป็นกติกาที่ปิดได้จากหน้าจอ
--   รูนี้เพิ่งยิงได้เพราะ 20261007000001_grants.sql เปิด UPDATE เป็นครั้งแรก
--
-- คอลัมน์ที่ล็อก (ไล่ทุกคอลัมน์ของ owners แล้วเลือก เพราะข้อ 2 ไม่ได้มีแต่ policy):
--   policy      · ตัวกำหนดว่า override ได้ไหม = หัวใจของข้อนี้
--   type        · company/person เป็นฐานของการจัดกลุ่ม Corporate vs Personal
--                 ทั้งในรายงานและใน Entity Policy · สลับแล้วความหมายของงบเปลี่ยน
--   code        · คีย์ที่โค้ดและ seed อ้างถึงตรงๆ ('SRI_CORP' ฯลฯ) — เปลี่ยนแล้ว
--                 migration ถัดไปจะ insert แถวใหม่ซ้ำเพราะ on conflict (code) ไม่ชน
--   id          · FK จาก transactions/assets/contracts ชี้มาที่นี่ · เปลี่ยน id
--                 = ย้ายเงินของคนหนึ่งไปเป็นของอีกคนในคำสั่งเดียว
--   created_at  · ร่องรอยเวลา ไม่ใช่ข้อมูลธุรกิจ
--
-- คอลัมน์ที่ **ยังแก้ได้ตามปกติ** (ไม่ล็อกทั้งตาราง): name_th · name_en · status ·
--   color · sort_order · tax_id_last4 · vat_registered
--   → เพิ่มผู้ถือใหม่ (INSERT) · แก้ชื่อ · เปลี่ยนสถานะ active/inactive/planned ·
--     ใส่เลขภาษี 4 ตัวท้าย · ติ๊กจด VAT ทำได้หมด ตามสิทธิ์ settings.manage เดิม
--   vat_registered ไม่ล็อกเพราะเป็น **ข้อเท็จจริงทางธุรกิจที่เปลี่ยนได้จริง**
--     (จด VAT เมื่อไรก็เปลี่ยนวันนั้น) และระบบใช้แค่ "เตือน ไม่ตัดสิน" (LEDGER_RULES §6.3)
--
-- DELETE: ปิดช่อง "ลบแล้ว insert ใหม่" ซึ่งเท่ากับเปลี่ยน policy ทางอ้อม
--   (ผู้ตรวจยิงผ่านจริง: delete owners where code='SRI_HOLDING' แล้ว insert กลับ
--    ด้วย policy='personal_flexible' → ได้ SRI_HOLDING ที่ override ได้)
--   → ห้ามลบแถวที่ policy = 'corporate_strict' · แถวบุคคลลบได้ตามเดิม
--   INSERT ไม่ห้าม เพราะเพิ่มนิติบุคคลใหม่ต้องทำได้ และ corporate_strict คือฝั่งที่เข้มกว่า
--
-- **ไม่เรียก fn_can ในฟังก์ชัน trigger** — กฎเงินห้ามขึ้นกับตารางสิทธิ์ที่แก้ได้
--   (เทสต์ข้อ 10 ใน supabase/tests/roles_permissions_test.sql บังคับข้อนี้อยู่)
--   ฟังก์ชันนี้ไม่ดูว่าใครเรียก มันปฏิเสธทุกคน
--
-- ถ้าวันหนึ่งต้องเปลี่ยน policy จริงๆ:
--   ทำใน migration และต้องปิด trigger อย่างชัดเจน (เหลือร่องรอยใน git):
--     alter table sri_os.owners disable trigger trg_owners_rule_columns_immutable;
--     update sri_os.owners set policy = ... where code = ...;
--     alter table sri_os.owners enable  trigger trg_owners_rule_columns_immutable;
--   หมายเหตุ: seed เดิม (20260917000005) ใช้ on conflict do update set policy = excluded.policy
--   ซึ่ง **ไม่สะดุด** เพราะค่าเท่าเดิม (trigger เทียบด้วย is distinct from ไม่ใช่ว่าแตะช่องนั้นไหม)
--   ถ้าแก้ค่าใน seed แล้ว replay → migration จะพังให้เห็น ไม่ใช่เปลี่ยนเงียบๆ
--
-- ย้อนกลับ (rollback):
--   -- drop trigger if exists trg_owners_rule_columns_immutable on sri_os.owners;
--   -- drop function if exists sri_os.fn_owners_rule_columns_immutable();
--   -- grant update on sri_os.owners to authenticated;   -- คืนสิทธิ์ทั้งแถว
--   -- (ย้อนแล้วคำสั่งเดียวปลด corporate_strict ได้ทั้งองค์กร — ไม่แนะนำ)
--
-- idempotent: revoke/grant ซ้ำได้ · create or replace function · drop trigger if exists
-- ============================================================

set search_path = sri_os, public;

-- รายการคอลัมน์กติกา **เขียนที่เดียว** แล้วใช้ทั้งชั้น GRANT และชั้น TRIGGER
-- (ถ้าเขียนสองที่ วันหนึ่งสองชั้นจะไม่ตรงกันแล้วไม่มีอะไรฟ้อง)
do $$
declare
  locked      text[] := array['id', 'code', 'type', 'policy', 'created_at'];
  all_cols    text[];
  grantable   text[];
  v_missing   text;
  v_body      text;
begin
  select array_agg(a.attname::text order by a.attnum) into all_cols
    from pg_attribute a
   where a.attrelid = 'sri_os.owners'::regclass
     and a.attnum > 0 and not a.attisdropped;

  -- ถ้าชื่อคอลัมน์ในรายการล็อกหายไป (เปลี่ยนชื่อ/ลบ) ต้องพังให้เห็น
  -- ไม่ใช่ล็อกคอลัมน์ที่ไม่มีอยู่แล้วเงียบๆ จนกลายเป็นไม่ล็อกอะไรเลย
  select string_agg(c, ', ') into v_missing
    from unnest(locked) c where c <> all (all_cols);
  if v_missing is not null then
    raise exception 'owners ไม่มีคอลัมน์ที่ไฟล์นี้ตั้งใจจะล็อก: % · โครงตารางเปลี่ยนแล้ว ต้องทบทวนรายการใหม่', v_missing;
  end if;

  select array_agg(c order by c) into grantable
    from unnest(all_cols) c where c <> all (locked);

  -- ---------- ชั้น GRANT ----------
  -- ต้อง revoke สิทธิ์ระดับตารางก่อน · Postgres ไม่ยอมให้ "เจาะรู" คอลัมน์
  -- ออกจาก grant ระดับตารางที่มีอยู่ (revoke update (col) จะไม่มีผลและได้แค่ warning)
  revoke update on sri_os.owners from authenticated;
  execute format('grant update (%s) on sri_os.owners to authenticated',
                 (select string_agg(quote_ident(c), ', ') from unnest(grantable) c));
  raise notice 'owners · authenticated แก้ได้เฉพาะคอลัมน์: %', array_to_string(grantable, ', ');

  -- ---------- ชั้น TRIGGER ----------
  -- สร้างตัวฟังก์ชันจาก array เดียวกัน เพื่อให้สองชั้นมาแหล่งเดียวกันเสมอ
  select string_agg(
           format($f$
  if new.%1$I is distinct from old.%1$I then
    raise exception 'กติกา: คอลัมน์ owners.%1$s แก้ไม่ได้ (เดิม %%, ใหม่ %%) · เปลี่ยนได้จาก migration ที่ปิด trigger อย่างชัดเจนเท่านั้น · เหตุผลอยู่ใน 20261007000005', old.%1$I, new.%1$I;
  end if;$f$, c), '')
    into v_body
    from unnest(locked) c;

  execute format($fn$
create or replace function sri_os.fn_owners_rule_columns_immutable()
returns trigger
language plpgsql
set search_path = ''
as $body$
begin
  if tg_op = 'DELETE' then
    -- ลบแล้ว insert ใหม่ = เปลี่ยน policy ทางอ้อม · ปิดช่องนี้ที่ฝั่ง corporate
    if old.policy = 'corporate_strict'::sri_os.owner_policy then
      raise exception 'กติกา: ลบผู้ถือที่เป็น corporate_strict (%%) ไม่ได้ · ลบแล้วลงใหม่ = ปลด corporate_strict ทางอ้อม', old.code;
    end if;
    return old;
  end if;
  %s
  return new;
end $body$;
$fn$, v_body);
end $$;

comment on function fn_owners_rule_columns_immutable() is
  'owners: id · code · type · policy · created_at แก้ไม่ได้ และห้ามลบแถว corporate_strict · ปฏิเสธทุก role รวม superuser · **ไม่เรียก fn_can** (กฎเงินห้ามขึ้นกับตารางสิทธิ์)';

-- trigger function ต้องเรียกจากข้างนอกไม่ได้ · Postgres ตรวจสิทธิ์ตอน create trigger
-- ไม่ใช่ตอนยิง จึงถอนได้โดย trigger ยังทำงานปกติ · ไฟล์นี้ถอนเองไม่ฝากไฟล์อื่น
-- (20261007000007 ไล่จาก pg_proc ให้อีกชั้น แต่ไฟล์นี้ต้องปลอดภัยถ้าถูก apply ลำพัง)
revoke all on function fn_owners_rule_columns_immutable() from public, anon, authenticated;

drop trigger if exists trg_owners_rule_columns_immutable on owners;
create trigger trg_owners_rule_columns_immutable
  before update or delete on owners
  for each row execute function fn_owners_rule_columns_immutable();

-- กันพลาด: ยืนยันผลของทั้งสองชั้นตอนจบ migration
do $$
declare v text;
begin
  -- 1) authenticated ต้องไม่มี UPDATE ระดับตารางบน owners อีก
  if exists (
    select 1 from information_schema.role_table_grants
     where table_schema = 'sri_os' and table_name = 'owners'
       and grantee = 'authenticated' and privilege_type = 'UPDATE'
  ) then
    raise exception 'owners ยังมี UPDATE ระดับตารางให้ authenticated · column grant จะไม่มีผล';
  end if;

  -- 2) คอลัมน์กติกาต้องไม่มี UPDATE แม้ระดับคอลัมน์
  select string_agg(column_name, ', ') into v
    from information_schema.role_column_grants
   where table_schema = 'sri_os' and table_name = 'owners'
     and grantee = 'authenticated' and privilege_type = 'UPDATE'
     and column_name in ('id', 'code', 'type', 'policy', 'created_at');
  if v is not null then
    raise exception 'owners · authenticated ยังแก้คอลัมน์กติกาได้: %', v;
  end if;

  -- 3) คอลัมน์ที่ต้องแก้ได้ ต้องยังแก้ได้ (กันแน่นเกินจนเพิ่ม/แก้ผู้ถือไม่ได้)
  select string_agg(c, ', ') into v
    from unnest(array['name_th', 'name_en', 'status', 'color', 'sort_order',
                      'tax_id_last4', 'vat_registered']) c
   where not exists (
     select 1 from information_schema.role_column_grants g
      where g.table_schema = 'sri_os' and g.table_name = 'owners'
        and g.grantee = 'authenticated' and g.privilege_type = 'UPDATE'
        and g.column_name = c);
  if v is not null then
    raise exception 'owners · authenticated แก้คอลัมน์ที่ควรแก้ได้ไม่ได้: % · หน้าจัดการผู้ถือจะพัง', v;
  end if;
end $$;
