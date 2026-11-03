-- ============================================================
-- SRI OS · asset_valuations.revision — ตีราคาใหม่ของ "วันเดิม วิธีเดิม" ได้ โดยไม่ลบของเดิม
-- (docs/DESIGN_ASSET_PERMISSIONS.md §7 ข้อ 8 · งาน W2)
--
-- ปัญหา: unique (asset_id, as_of, method) ทำให้แก้ราคาที่ตีผิดของวันเดียวกันด้วยวิธีเดิม
--   **ไม่ได้เลย** ทางเดียวคือ DELETE แถวเดิมแล้วลงใหม่ ซึ่งขัดเจตนาของระบบนี้
--   (เก็บประวัติแล้วลงใหม่ ไม่ใช่ลบทับ · หลักเดียวกับกฎเหล็กข้อ 1)
--
-- ทำอะไร:
--   1. เพิ่มคอลัมน์ `revision int` — **ระบบออกให้เท่านั้น** (ผู้เรียกส่งมา = ปฏิเสธ)
--      แล้วย้าย unique ไปเป็น (asset_id, as_of, method, revision)
--   2. ตาราง append-only จริง: UPDATE ถูกปฏิเสธที่ trigger ทุก role
--      (ยกเว้นเส้นทาง backfill ของไฟล์นี้เอง ซึ่งแตะได้แค่แถวที่ revision ยังว่าง)
--   3. "มูลค่าล่าสุด" = **revision สูงสุดของ (วันล่าสุด, วิธีนั้น)**
--      กฎเขียนไว้ที่ `v_asset_valuation_current` **ที่เดียว** แล้ว `v_asset_latest_value`
--      อ้างต่อ — ห้ามเขียนกฎ "ราคาล่าสุด" ซ้ำที่อื่น (ไม่งั้นสองที่ตอบไม่ตรงกันเงียบๆ)
--   4. `v_asset_latest_value` เริ่มจาก `assets` แล้ว left join → ทรัพย์ที่ยังไม่เคยตีราคา
--      **ไม่หายไปจากรายงาน** และได้ `value = NULL` ไม่ใช่ 0
--      (0 หมายถึง "ตีราคาแล้วได้ศูนย์" ซึ่งคนละเรื่องกับ "ยังไม่เคยตี")
--      ข้อจำกัดที่ยอมรับไว้: `sum(value)` ข้ามแถว NULL ไปเฉยๆ → รายงานที่ต้องการเตือน
--      "ทรัพย์ที่ยังไม่มีราคา" ต้องนับ `value is null` เอง ไม่ใช่หวังพึ่งผลรวม
--
-- การเรียงลำดับใน v_asset_latest_value (ตั้งใจเลือก · อ่านก่อนแก้):
--   as_of desc → created_at desc → revision desc → method → id
--   - `as_of` มาก่อน `revision` เสมอ: วันล่าสุดชนะ แม้วันเก่าจะถูกแก้ไปหลาย revision แล้ว
--   - revision ต่อ "วิธี" **เป็นเอกเทศ** (นับใน (asset_id, as_of, method)) จึงเทียบข้ามวิธีไม่ได้
--     → ตัวกรอง revision สูงสุดทำใน v_asset_valuation_current (ต่อวิธี) ก่อน
--       แล้วการเลือกข้ามวิธีในวันเดียวกันจึงใช้ created_at (ของเดิมก่อนไฟล์นี้) = เขียนล่าสุดชนะ
--   - created_at/revision/method/id ท้ายๆ มีเพื่อให้ผลลัพธ์ **คงที่** (total order)
--     ไม่ใช่เพื่อสื่อความหมาย · อย่าเขียนโค้ดที่พึ่งลำดับสองตัวท้าย
--
-- ทำไม trigger ไม่ใช่ default/sequence: ลำดับต้องนับ "ภายในกลุ่ม (ทรัพย์, วัน, วิธี)"
--   sequence ทำไม่ได้ · และถ้าให้ผู้เรียกส่ง revision เองได้ จะมีวันที่ส่งเลขต่ำกว่าเดิม
--   แล้ว "ราคาล่าสุด" ชี้ไปแถวเก่า = มูลค่าพอร์ตผิดโดยไม่มีใครเห็น
--   SECURITY DEFINER เพราะการนับ max(revision) ต้องไม่ขึ้นกับ RLS ของคนคีย์
--   (ถ้าเป็น invoker และ RLS ซ่อนแถวเก่า จะนับได้เลขที่ชนกันแล้ว insert ล้มทุกครั้ง)
--   **ไม่เรียก fn_can()** — กฎนี้เท่ากันทุกตำแหน่ง (มีเทสต์จาก pg_trigger ยืนยัน)
--
-- ย้อนกลับ (rollback):
--   -- drop trigger if exists trg_valuation_revision on sri_os.asset_valuations;
--   -- drop function if exists sri_os.fn_valuation_revision();
--   -- alter table sri_os.asset_valuations
--   --   drop constraint if exists asset_valuations_asset_as_of_method_rev_key,
--   --   drop constraint if exists asset_valuations_revision_positive;
--   -- -- ก่อนคืน unique เดิม ต้องเหลือ revision เดียวต่อ (asset_id, as_of, method)
--   -- --   ไม่งั้น add constraint จะล้ม → ตัดสินก่อนว่าจะทิ้ง revision ไหน (ห้ามลบเงียบๆ)
--   -- alter table sri_os.asset_valuations
--   --   add constraint asset_valuations_asset_id_as_of_method_key unique (asset_id, as_of, method);
--   -- alter table sri_os.asset_valuations drop column if exists revision;
--   -- -- คืน v_asset_latest_value รุ่นเดิม (distinct on จาก asset_valuations ล้วน):
--   -- --   รัน 20260917000003_assets_contacts.sql ซ้ำ แล้ว drop view v_asset_valuation_current
--   -- --   **ไม่แนะนำ** เพราะกลับไปแก้ราคาวันเดิมไม่ได้อีก
--
-- idempotent: add column if not exists · backfill เฉพาะแถวที่ revision is null ·
--   drop/add constraint ตามโครงสร้างจริง (ไม่พึ่งชื่อ) · create or replace view/function ·
--   drop trigger if exists ก่อน create
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 1 · คอลัมน์ + backfill แถวเก่า
--   แถวเก่าถูก unique เดิมบังคับให้มีได้แถวเดียวต่อ (asset_id, as_of, method)
--   จึงได้ revision = 1 ทั้งหมด · แต่เขียนด้วย row_number() เพื่อให้ยังถูกต้อง
--   ถ้ารอบก่อนหน้าหยุดกลางทาง (unique เดิมถูก drop ไปแล้วแต่ยัง backfill ไม่เสร็จ)
-- ============================================================
alter table asset_valuations add column if not exists revision int;

update asset_valuations v
   set revision = r.rn
  from (
    select id,
           row_number() over (partition by asset_id, as_of, method
                              order by created_at, id) as rn
      from asset_valuations
     where revision is null
  ) r
 where r.id = v.id
   and v.revision is null;

do $$ begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'sri_os.asset_valuations'::regclass
       and conname  = 'asset_valuations_revision_positive'
  ) then
    alter table asset_valuations
      add constraint asset_valuations_revision_positive check (revision >= 1);
  end if;
end $$;

alter table asset_valuations alter column revision set not null;

comment on column asset_valuations.revision is
  'ครั้งที่ของการตีราคาใน (asset_id, as_of, method) เดียวกัน · เริ่มที่ 1 · **ระบบออกให้เท่านั้น** · ตีผิดให้ลงแถวใหม่ ไม่ลบ/ไม่แก้ของเดิม';

-- ============================================================
-- 2 · ย้าย unique ให้รวม revision
--   ค้นจาก **โครงสร้างคอลัมน์** ไม่ใช่ชื่อ constraint เพราะชื่อบน project จริง
--   อาจไม่ใช่ชื่อ default (เคยมี index ที่ใส่มือไว้) · ถ้าไล่ตามชื่อแล้วพลาด
--   เท่ากับ unique เดิมยังอยู่ และฟีเจอร์นี้ "เปิดแล้วแต่ยังใช้ไม่ได้"
-- ============================================================
do $$
declare r record; n int := 0;
begin
  for r in
    select con.conname
      from pg_constraint con
     where con.conrelid = 'sri_os.asset_valuations'::regclass
       and con.contype in ('u', 'p')
       and (
         select array_agg(att.attname::text order by att.attname)
           from unnest(con.conkey) k
           join pg_attribute att on att.attrelid = con.conrelid and att.attnum = k
       ) = array['as_of', 'asset_id', 'method']
  loop
    execute format('alter table sri_os.asset_valuations drop constraint %I', r.conname);
    n := n + 1;
    raise notice 'ถอด unique เดิม %(asset_id, as_of, method) ออกแล้ว', r.conname;
  end loop;

  -- unique index ที่ไม่ได้ผูกกับ constraint (ใส่มือไว้) ก็ปิดกั้นแบบเดียวกัน
  for r in
    select ic.relname as idxname
      from pg_index i
      join pg_class ic on ic.oid = i.indexrelid
     where i.indrelid = 'sri_os.asset_valuations'::regclass
       and i.indisunique
       and not exists (select 1 from pg_constraint c where c.conindid = i.indexrelid)
       and (
         select array_agg(att.attname::text order by att.attname)
           from unnest(string_to_array(i.indkey::text, ' ')::int2[]) k
           join pg_attribute att on att.attrelid = i.indrelid and att.attnum = k
       ) = array['as_of', 'asset_id', 'method']
  loop
    execute format('drop index sri_os.%I', r.idxname);
    n := n + 1;
    raise notice 'ถอด unique index เดิม % ออกแล้ว', r.idxname;
  end loop;

  if n = 0 then
    raise notice 'ไม่พบ unique (asset_id, as_of, method) — ถอดไปแล้วในรอบก่อน (idempotent)';
  end if;
end $$;

do $$ begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'sri_os.asset_valuations'::regclass
       and conname  = 'asset_valuations_asset_as_of_method_rev_key'
  ) then
    alter table asset_valuations
      add constraint asset_valuations_asset_as_of_method_rev_key
      unique (asset_id, as_of, method, revision);
  end if;
end $$;

-- ============================================================
-- 3 · revision ระบบออกให้ · ตาราง append-only
-- ============================================================
create or replace function fn_valuation_revision() returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  if tg_op = 'INSERT' then
    if new.revision is not null then
      raise exception 'asset_valuations.revision ระบบออกให้เท่านั้น (ส่งมา %) · ตีราคาใหม่ให้ insert แถวใหม่โดยไม่ต้องส่ง revision',
        new.revision using errcode = 'check_violation';
    end if;
    -- ข้อมูลที่ขาดต้องถูกปฏิเสธที่ NOT NULL ของตาราง ไม่ใช่เดาให้ที่นี่
    -- (as_of/method/value ว่าง = ไม่รู้ว่าเป็นราคาของวันไหน/วิธีไหน/เท่าไร)
    select coalesce(max(v.revision), 0) + 1
      into new.revision
      from sri_os.asset_valuations v
     where v.asset_id = new.asset_id
       and v.as_of    = new.as_of
       and v.method   = new.method;
    return new;
  end if;

  -- เส้นทาง backfill ของ migration เท่านั้น: เติมเลขให้แถวเก่าที่ยังว่าง
  if old.revision is null then
    return new;
  end if;

  raise exception 'asset_valuations เป็นตารางเพิ่มเท่านั้น (append-only) · ราคาที่ตีผิดให้ลงแถวใหม่เป็น revision ถัดไป ไม่ใช่ update แถวเดิม'
    using errcode = 'check_violation';
end $fn$;

comment on function fn_valuation_revision() is
  'ออกเลข revision ต่อ (asset_id, as_of, method) และบังคับว่าตารางเพิ่มได้เท่านั้น · SECURITY DEFINER เพื่อให้การนับไม่ขึ้นกับ RLS ของคนคีย์ · ไม่เรียก fn_can()';

-- SECURITY DEFINER ที่ PUBLIC เรียกได้ = ช่องข้าม RLS (เทสต์ H4d ไล่จาก pg_proc)
revoke all on function fn_valuation_revision() from public;
do $$ begin
  execute 'revoke all on function sri_os.fn_valuation_revision() from anon, authenticated';
exception when undefined_object then
  raise notice 'ไม่มี role anon/authenticated ในคลัสเตอร์นี้ — ข้าม revoke';
end $$;

drop trigger if exists trg_valuation_revision on asset_valuations;
create trigger trg_valuation_revision
  before insert or update on asset_valuations
  for each row execute function fn_valuation_revision();

-- ============================================================
-- 4 · "ราคาล่าสุด" — กฎอยู่ที่นี่ที่เดียว
--
--   v_asset_valuation_current = ราคาที่ยังมีผลของแต่ละ (ทรัพย์, วัน, วิธี)
--     = revision สูงสุดของกลุ่มนั้น · revision ที่ถูกแก้ไปแล้วยังอยู่ในตาราง (ประวัติ)
--     แต่ไม่โผล่ในวิวนี้ ไม่งั้นรวมยอดจะนับซ้ำเท่าจำนวนครั้งที่แก้ราคา
-- ============================================================
create or replace view v_asset_valuation_current as
select v.id, v.asset_id, v.as_of, v.method, v.revision,
       v.unit_price, v.value, v.source_url, v.note, v.created_at
  from asset_valuations v
 where v.revision = (
         select max(v2.revision)
           from asset_valuations v2
          where v2.asset_id = v.asset_id
            and v2.as_of    = v.as_of
            and v2.method   = v.method
       );

comment on view v_asset_valuation_current is
  'ราคาที่ยังมีผลของแต่ละ (ทรัพย์, วัน, วิธี) = revision สูงสุดของกลุ่ม · revision เก่าเป็นประวัติ ไม่นับในผลรวม · **มีหลายแถวต่อทรัพย์ ห้ามเอาไปรวมเป็นมูลค่าพอร์ต** NAV ใช้ v_asset_latest_value เท่านั้น';

-- ราคาเก่าเกิน 7 วันให้ขึ้นธง ไม่ใช่เก็บเป็นคอลัมน์ที่ต้องมาอัปเดตเอง
-- เริ่มจาก assets เพื่อให้ทรัพย์ที่ยังไม่เคยตีราคาไม่หายไปจากรายงาน (value = NULL)
-- is_stale ของทรัพย์ที่ไม่เคยตีราคา = NULL ไม่ใช่ true — คงพฤติกรรมเดิมของ
-- fn_health_check (`where is_stale`) ไว้ · "ไม่เคยตีราคา" เป็นคนละข้อกับ "ราคาเก่า"
-- ลำดับคอลัมน์: ของเดิม (asset_id, as_of, method, value, source_url, is_stale) ต้องอยู่
-- ตำแหน่งเดิมทุกตัว แล้วต่อ revision ท้ายสุด — create or replace view **เพิ่มท้ายได้เท่านั้น**
-- (แทรกกลางจะล้มด้วย 'cannot change name of view column' · ถ้าเลี่ยงด้วย drop view
--  จะพาของที่อ้างวิวนี้หลุดไปด้วย จึงไม่ทำ)
create or replace view v_asset_latest_value as
select a.id as asset_id,
       cur.as_of, cur.method, cur.value, cur.source_url,
       (current_date - cur.as_of) > 7 as is_stale,
       cur.revision
  from assets a
  left join lateral (
    select c.as_of, c.method, c.revision, c.value, c.source_url
      from v_asset_valuation_current c
     where c.asset_id = a.id
     order by c.as_of desc, c.created_at desc, c.revision desc, c.method, c.id
     limit 1
  ) cur on true;

comment on view v_asset_latest_value is
  'มูลค่าล่าสุดต่อทรัพย์ = revision ล่าสุดของวันล่าสุด (วันมาก่อน revision เสมอ) · ทรัพย์ที่ยังไม่เคยตีราคายังอยู่ในวิวด้วย value = NULL (ไม่ใช่ 0) · security_invoker = ผลลัพธ์ถูกกรองด้วย RLS ของผู้เรียก';

-- view ใหม่ต้องเคารพ RLS ของผู้เรียก (event trigger trg_force_view_security_invoker
-- ตั้งให้อัตโนมัติ แต่ตั้งซ้ำที่นี่ด้วย เพราะ event trigger สร้างได้เฉพาะ superuser
-- → บน cluster ที่สร้างไม่สำเร็จ วิวจะรันด้วยสิทธิ์เจ้าของ = NAV ทั้งพอร์ตรั่ว)
alter view v_asset_valuation_current set (security_invoker = true);
alter view v_asset_latest_value      set (security_invoker = true);

-- สิทธิ์: ของเดิมมาจาก alter default privileges ใน 20261007000001_grants.sql
-- ซึ่งมีผลเฉพาะ object ที่สร้างโดย role เดียวกัน → ประกาศซ้ำให้ชัดเจน
do $$ begin
  execute 'grant select on sri_os.v_asset_valuation_current, sri_os.v_asset_latest_value to authenticated';
  execute 'revoke all on sri_os.v_asset_valuation_current, sri_os.v_asset_latest_value from anon';
exception when undefined_object then
  raise notice 'ไม่มี role anon/authenticated ในคลัสเตอร์นี้ — ข้าม grant/revoke ของวิว';
end $$;
