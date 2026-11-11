-- ============================================================
-- SRI OS · **tag บนร่าง** (ADR 0002 หัวข้อ 3.4)
--
-- ทำไมต้องมี: ADR 0002 หัวข้อ 7 บอกว่าติด tag ได้ **ตอนสร้างร่าง** ด้วย
-- ถ้าไม่มีที่เก็บตอนร่าง คนคีย์จะต้องกลับมาติด tag อีกรอบหลังอนุมัติ ซึ่ง
-- (ก) คนที่คีย์มักไม่ใช่คนที่อนุมัติ และ (ข) **ใบที่ตกสำรวจคือใบที่หาไม่เจอ**
-- → "ยังไม่ติด tag เลย" จะกลายเป็นกองที่ไม่มีใครตามเก็บ
--
-- ------------------------------------------------------------
-- **ความต่างจาก `transaction_tags` ที่ตั้งใจให้ต่าง**
--
-- | | ร่าง (`draft_entry_tags`) | ใบในสมุด (`transaction_tags`) |
-- |---|---|---|
-- | ลบลิงก์ | **ได้** ตอนที่ร่างยัง `pending` | ไม่ได้เลย (ถอดด้วยร่องรอย) |
-- | FK ของเจ้าของแถว | `on delete cascade` | `on delete restrict` |
-- | `owner_id` | ไม่มี (อ่านจากร่าง) | **มี** เป็นสำเนาจากใบ |
--
-- เหตุผล: **ร่างไม่ใช่สมุด** — ร่างลบได้อยู่แล้ว ไม่ถูกนับในงบใดๆ และยังไม่มี
-- ตัวเลขเข้าสมุด → กฎเหล็กข้อ 1 (ห้ามลบของที่ post แล้ว) ยังไม่มีผลกับมัน
-- ถ้าบังคับให้ถอด tag บนร่างต้องเขียนเหตุผลด้วย คนคีย์ที่กดผิดจะต้องเขียนเรียงความ
-- ทุกครั้งที่ติ๊กผิดช่อง = กันแน่นเกินจนคนเลี่ยงไปไม่ติด tag เลย (ซึ่งแย่กว่า)
--
-- **แต่พอร่างถูกตัดสินแล้ว (approved/rejected) ชุด tag แช่แข็ง** — มันคือหลักฐาน
-- ว่า "สิ่งที่ถูกอนุมัติคือใบที่ติด tag ชุดนี้" · ร่างที่ approved มี `posted_txn_id`
-- ชี้ไปที่ใบจริงแล้ว ถ้าแก้ชุด tag ของร่างทีหลังได้ ร่างกับใบจะเล่าเรื่องคนละเรื่อง
--
-- ------------------------------------------------------------
-- **สิ่งที่ไฟล์นี้ไม่ทำ** (ชิ้น 3 ตาม ADR 0002 หัวข้อ 6)
--   ตอนอนุมัติ ร่างต้องส่ง tag เข้า `fn_post_entry(tag_ids)` →
--   **tag ที่ติดไว้ตอนร่างต้องไม่หายตอนอนุมัติ** ซึ่งเป็น **เทสต์บังคับของชิ้น 3**
--   (ADR 0002 หัวข้อ 3.4) · ไฟล์นี้วางแค่ที่เก็บ ยังไม่มีใครย้ายของให้
--   → ตราบใดที่ชิ้น 3 ยังไม่ลง การติด tag ตอนร่าง **ยังไม่ถูกเปิดใช้ที่หน้าจอ**
--     (เปิดฟีเจอร์ครึ่งเดียวอันตรายกว่าไม่เปิด · บทเรียนข้อ 7 ของ mace-windu)
--
-- ลำดับ: **ต้องรันหลัง 20261027000001** (`tags`) · **หลัง 20260917000002**
--   (`draft_entries`) · **หลัง 20261020000000** (ด่านคอลัมน์)
--   → วางต่อท้าย `20261027000002_tag_links.sql`
--
-- idempotent: create table if not exists · create or replace function ·
--   drop policy/trigger if exists ก่อน create · insert ... on conflict
--
-- ย้อนกลับ (rollback):
--   -- delete from sri_os.column_exposure       where table_name = 'draft_entry_tags';
--   -- delete from sri_os.column_exposure_tables where table_name = 'draft_entry_tags';
--   -- select sri_os.fn_apply_column_exposure();
--   -- drop table if exists sri_os.draft_entry_tags;
--   -- drop function if exists sri_os.fn_draft_tag_frozen();
--   -- ย้อนแล้ว: ติด tag ตอนคีย์ร่างไม่ได้ (ต้องกลับมาติดบนใบหลังอนุมัติ) ·
--   --   ไม่มีตัวเลขในงบเปลี่ยน และลิงก์ของใบในสมุดไม่ถูกแตะ
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 0 · pre-flight
-- ============================================================
do $$
begin
  if to_regclass('sri_os.tags') is null then
    raise exception 'ไม่มีแค็ตตาล็อก tag → ต้องรัน 20261027000001_tag_catalog.sql ก่อน';
  end if;
  if to_regclass('sri_os.draft_entries') is null then
    raise exception 'ไม่มี draft_entries → ต้องรัน 20260917000002_ledger.sql ก่อน';
  end if;
  if not exists (select 1 from sri_os.permissions where key = 'tag.assign') then
    raise exception 'ไม่มีสิทธิ์ tag.assign ในตารางสิทธิ์ → 20261027000001 ไม่ได้ลงหรือถูกย้อน';
  end if;
  if to_regclass('sri_os.column_exposure_tables') is null
     or to_regprocedure('sri_os.fn_apply_column_exposure()') is null then
    raise exception 'ไม่มีทะเบียนด่านคอลัมน์ → ต้องรัน 20261020000000 ก่อน (D-089)';
  end if;
end $$;

-- ============================================================
-- 1 · ตาราง — คีย์คู่ตาม ADR 0002 หัวข้อ 3.4 (ไม่มี surrogate id)
--     ติด tag เดิมซ้ำบนร่างเดียวไม่ได้โดยโครงสร้าง (primary key)
-- ============================================================
create table if not exists draft_entry_tags (
  /** cascade ได้ **เพราะร่างลบได้อยู่แล้ว** (ไม่ใช่สมุด) — ตรงข้ามกับ transaction_tags */
  draft_entry_id uuid not null references draft_entries(id) on delete cascade,
  /** restrict — tag ที่ถูกใช้แล้วลบไม่ออก (เหมือนฝั่งใบ) */
  tag_id         uuid not null references tags(id) on delete restrict,
  primary key (draft_entry_id, tag_id)
);

comment on table draft_entry_tags is
  'tag ที่ติดไว้ตอนคีย์ร่าง (ADR 0002 หัวข้อ 3.4) · cascade ตามร่างได้เพราะร่างไม่ใช่สมุดและลบได้อยู่แล้ว · แก้/ลบได้เฉพาะตอนร่างยัง pending — ร่างที่ถูกตัดสินแล้วชุด tag แช่แข็ง เพราะมันคือหลักฐานว่าสิ่งที่อนุมัติคือใบที่ติด tag ชุดนี้ · ตอนอนุมัติ ชุดนี้ต้องถูกส่งเข้า fn_post_entry(tag_ids) → **tag ต้องไม่หายตอนอนุมัติ** (เทสต์บังคับของชิ้น 3)';

create index if not exists draft_entry_tags_by_tag on draft_entry_tags (tag_id);

-- ============================================================
-- 2 · ร่างที่ถูกตัดสินแล้ว = ชุด tag แช่แข็ง
--
--     กันที่ชั้น trigger ด้วย ไม่ใช่แค่ policy: ร่างที่ approved ชี้ไปที่ใบจริงแล้ว
--     (`posted_txn_id`) · ถ้าแก้ชุด tag ของร่างทีหลังได้ คนที่เปิดดูประวัติจะเห็น
--     ร่างบอกอย่างและใบบอกอย่าง แล้วไม่มีใครรู้ว่าอันไหนคือสิ่งที่ถูกอนุมัติจริง
-- ============================================================
create or replace function fn_draft_tag_frozen() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_draft  uuid := coalesce(new.draft_entry_id, old.draft_entry_id);
  v_status text;
  v_posted uuid;
begin
  select d.status::text, d.posted_txn_id into v_status, v_posted
    from sri_os.draft_entries d where d.id = v_draft;

  -- ลบร่างทั้งใบ → cascade มาถึงที่นี่ · ตอนนั้นแถวร่างหายไปแล้ว ปล่อยผ่านได้
  -- (ถ้าปฏิเสธ จะลบร่างที่ติด tag ไว้ไม่ได้เลย ซึ่งค้านกับ cascade ที่ ADR สั่ง)
  if v_status is null then
    return coalesce(new, old);
  end if;

  if v_status <> 'pending' then
    raise exception 'ร่างนี้ถูกตัดสินแล้ว (สถานะ %) → แก้ชุด tag ไม่ได้ · ชุด tag ของร่างที่อนุมัติ/ปฏิเสธแล้วเป็นหลักฐานว่า "สิ่งที่ถูกตัดสินคือใบที่ติด tag ชุดนี้"% · ถ้าต้องเปลี่ยน tag ของใบที่ลงสมุดแล้ว ให้ติด/ถอดที่ตัวใบ (transaction_tags) ซึ่งมีร่องรอยครบ',
      v_status, coalesce(' (ใบที่สร้างแล้ว: ' || v_posted::text || ')', '');
  end if;

  return coalesce(new, old);
end $fn$;

comment on function fn_draft_tag_frozen() is
  'ชุด tag ของร่างแก้ได้เฉพาะตอน pending · ร่างที่อนุมัติ/ปฏิเสธแล้วแช่แข็ง (ไม่งั้นร่างกับใบที่มันสร้างเล่าเรื่องคนละเรื่อง) · ยอมให้ cascade ตอนลบร่างทั้งใบผ่าน';

revoke all on function fn_draft_tag_frozen() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_draft_tag_frozen() from anon, authenticated';
exception when undefined_object then null;
end $$;

drop trigger if exists trg_draft_tag_frozen on draft_entry_tags;
create trigger trg_draft_tag_frozen
  before insert or update or delete on draft_entry_tags
  for each row execute function fn_draft_tag_frozen();

-- ============================================================
-- 3 · RLS — **ตามร่าง** ไม่เขียนกฎขอบเขตของร่างซ้ำ
--
--     subquery ใน policy รันใต้ RLS ของผู้อ่าน → ขอบเขตของแถวมาจาก
--     `draft_entries_by_owner` ตัวจริง (แหล่งความจริงเดียว · บทเรียนข้อ 5)
--     เงื่อนไขสิทธิ์ที่เขียนไว้ตรงๆ เป็นชั้น **ซ้ำที่อ่อนกว่า** มีไว้สองเหตุผล:
--     (ก) ให้ด่านคอลัมน์ของ D-089 ยืนยันได้ว่าแถวนี้ต้องมีสิทธิ์ขั้นต่ำอะไร
--     (ข) ปฏิเสธด้วย "ไม่มีสิทธิ์" ชัดๆ แทนที่จะคืน 0 แถวเงียบๆ
-- ============================================================
alter table draft_entry_tags enable row level security;

drop policy if exists draft_tags_by_draft on draft_entry_tags;
create policy draft_tags_by_draft on draft_entry_tags
  for select to authenticated
  using (
    (fn_can('draft.read_own') or fn_can('ledger.read'))
    and exists (select 1 from draft_entries d where d.id = draft_entry_id)
  );

drop policy if exists draft_tags_insert on draft_entry_tags;
create policy draft_tags_insert on draft_entry_tags
  for insert to authenticated
  with check (
    fn_can('tag.assign')
    and exists (
      select 1 from draft_entries d
       where d.id = draft_entry_id and d.status = 'pending'
         and fn_can_see_owner(d.owner_id)
    )
    -- tag ที่ปิดใช้งานแล้วติดใหม่ไม่ได้ (เหมือนฝั่งใบ) · ตรวจที่ policy ได้เพราะ
    -- แค็ตตาล็อกอ่านได้ทุกคน จึงไม่ต้องใช้ definer มาอ่านแทน
    and exists (select 1 from tags t where t.id = tag_id and t.is_active)
  );

-- ถอด tag บนร่างที่ยัง pending = ลบแถว (ไม่ต้องเขียนเหตุผล — ร่างไม่ใช่สมุด)
drop policy if exists draft_tags_delete on draft_entry_tags;
create policy draft_tags_delete on draft_entry_tags
  for delete to authenticated
  using (
    fn_can('tag.assign')
    and exists (
      select 1 from draft_entries d
       where d.id = draft_entry_id and d.status = 'pending'
         and fn_can_see_owner(d.owner_id)
    )
  );

-- **ไม่มี policy UPDATE**: ทุกคอลัมน์เป็นคีย์ · "เปลี่ยน tag" = ลบแถวแล้วใส่แถวใหม่
drop policy if exists draft_tags_update on draft_entry_tags;

grant select, insert, update, delete on draft_entry_tags to authenticated;
do $$
begin
  execute 'revoke all on table sri_os.draft_entry_tags from anon';
exception when undefined_object then null;
end $$;

-- ============================================================
-- 4 · ร่องรอย + ห้าม TRUNCATE
--     ไม่มี `id` แบบ uuid → **ต้องใช้ fn_audit_keyed พร้อมคอลัมน์ PK ตามลำดับ**
--     (ด่านของ 20261008000005 เทียบ args ของ trigger กับ primary key จริง)
-- ============================================================
drop trigger if exists trg_audit_draft_entry_tags on draft_entry_tags;
create trigger trg_audit_draft_entry_tags
  after insert or update or delete on draft_entry_tags
  for each row execute function fn_audit_keyed('draft_entry_id', 'tag_id');

drop trigger if exists trg_forbid_truncate on draft_entry_tags;
create trigger trg_forbid_truncate
  before truncate on draft_entry_tags
  for each statement execute function fn_forbid_truncate();

-- ============================================================
-- 5 · ด่านคอลัมน์ (D-089)
--     `row` + `draft.read_own` = สิทธิ์ขั้นต่ำที่ทำให้เห็นแถวของตารางนี้ได้
--     (คนที่มี `ledger.read` เห็นทั้งคิวในขอบเขตผู้ถือ ซึ่งกว้างกว่า แต่ "ขั้นต่ำ"
--      คือของตัวเอง → ประกาศตามของจริง ไม่ประกาศให้ดูเข้มกว่าที่เป็น)
-- ============================================================
insert into column_exposure_tables (table_name, review_state, reason) values
  ('draft_entry_tags', 'classified',
   'tag ที่ติดไว้ตอนคีย์ร่าง (ADR 0002 หัวข้อ 3.4) · แถวถูกกรองผ่าน draft_entries ด้วย policy ตัวจริงของร่าง (draft_entries_by_owner) ไม่ได้เขียนกฎขอบเขตซ้ำ · ไม่มีตัวเลขเงินและไม่มีข้อความอิสระ มีแต่คีย์สองตัว')
on conflict (table_name) do update
  set review_state = excluded.review_state, reason = excluded.reason;

insert into column_exposure (table_name, column_name, exposure, min_permission, rationale)
select 'draft_entry_tags', c, 'row', 'draft.read_own',
       'คีย์ของลิงก์บนร่าง · บอกว่าร่างไหนจะถูกจัดเข้า project/ป้ายไหนเมื่ออนุมัติ → เห็นได้เมื่อเห็นร่างนั้น (ของตัวเองด้วย draft.read_own หรือทั้งคิวด้วย ledger.read)'
  from unnest(array['draft_entry_id', 'tag_id']) c
on conflict (table_name, column_name) do update
  set exposure = excluded.exposure, min_permission = excluded.min_permission,
      rationale = excluded.rationale;

select fn_apply_column_exposure();

-- ============================================================
-- 6 · guard ท้ายไฟล์
-- ============================================================
do $$
declare v text; n int;
begin
  if to_regclass('sri_os.draft_entry_tags') is null then
    raise exception 'ตาราง draft_entry_tags ไม่ถูกสร้าง';
  end if;

  -- (ก) คีย์คู่ตาม ADR (ไม่มี surrogate id → ติด tag ซ้ำบนร่างเดียวไม่ได้)
  select string_agg(a.attname, ', ' order by k.ord) into v
    from pg_constraint con
    join unnest(con.conkey) with ordinality as k(attnum, ord) on true
    join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum
   where con.conrelid = 'sri_os.draft_entry_tags'::regclass and con.contype = 'p';
  if v is distinct from 'draft_entry_id, tag_id' then
    raise exception 'primary key ของ draft_entry_tags ต้องเป็น (draft_entry_id, tag_id) ตาม ADR 0002 หัวข้อ 3.4 แต่ได้ (%) · ถ้าไม่ใช่คีย์คู่ ร่างหนึ่งจะติด tag เดิมซ้ำได้', coalesce(v, 'ไม่มี');
  end if;

  -- (ข) ห้ามมีคอลัมน์จำนวนเงิน/สัดส่วน (น้ำหนักของ ADR 0003 อยู่ตารางแยก)
  select string_agg(c.column_name || ' (' || c.data_type || ')', ', '), count(*) into v, n
    from information_schema.columns c
   where c.table_schema = 'sri_os' and c.table_name = 'draft_entry_tags'
     and c.data_type in ('numeric', 'money', 'double precision', 'real');
  if n > 0 then
    raise exception 'draft_entry_tags มีคอลัมน์ชนิดตัวเลขเงิน/สัดส่วน: % · ร่างต้องส่งต่อแค่ "ติด tag อะไร" ให้ประตู ไม่ใช่ตัวเลข (ADR 0002 หัวข้อ 5 ข้อ 4)', v;
  end if;

  -- (ค) FK ต้องเป็น cascade ฝั่งร่าง และ restrict ฝั่ง tag (ADR 0002 หัวข้อ 3.4)
  select string_agg(con.conname || ': ' || con.confdeltype::text, ', ') into v
    from pg_constraint con
   where con.conrelid = 'sri_os.draft_entry_tags'::regclass and con.contype = 'f'
     and ((con.confrelid = 'sri_os.draft_entries'::regclass and con.confdeltype <> 'c')
       or (con.confrelid = 'sri_os.tags'::regclass and con.confdeltype <> 'r'));
  if v is not null then
    raise exception 'FK ของ draft_entry_tags ไม่ตรง ADR 0002 หัวข้อ 3.4 (%) · ฝั่ง draft_entries ต้อง cascade (ร่างลบได้อยู่แล้ว ถ้า restrict จะลบร่างที่ติด tag ไม่ได้) · ฝั่ง tags ต้อง restrict (tag ที่ถูกใช้แล้วต้องลบไม่ออก)', v;
  end if;

  -- (ง) trigger ครบ · audit ต้องเป็น fn_audit_keyed ที่ args ตรง PK
  select string_agg(x.want, ', ') into v
    from (values ('trg_draft_tag_frozen'), ('trg_audit_draft_entry_tags'),
                 ('trg_forbid_truncate')) x(want)
   where not exists (select 1 from pg_trigger g
                      where g.tgrelid = 'sri_os.draft_entry_tags'::regclass
                        and g.tgname = x.want and not g.tgisinternal);
  if v is not null then raise exception 'trigger หายไปจาก draft_entry_tags: %', v; end if;

  if not exists (
    select 1 from pg_trigger g
     where g.tgrelid = 'sri_os.draft_entry_tags'::regclass and not g.tgisinternal
       and g.tgfoid = 'sri_os.fn_audit_keyed'::regproc
       and pg_get_triggerdef(g.oid) like '%fn_audit_keyed(''draft_entry_id'', ''tag_id'')%') then
    raise exception 'trigger audit ของ draft_entry_tags ส่งคีย์ไม่ตรง primary key → ร่องรอยชี้ผิดแถวเงียบๆ (ด่านของ 20261008000005 ตรวจข้อนี้ด้วย)';
  end if;

  -- (จ) ไม่มี policy UPDATE (ทุกคอลัมน์เป็นคีย์ · เปลี่ยน tag = ลบแล้วใส่ใหม่)
  select string_agg(p.polname || '/' || p.polcmd::text, ', ') into v
    from pg_policy p
   where p.polrelid = 'sri_os.draft_entry_tags'::regclass and p.polcmd in ('w', '*');
  if v is not null then
    raise exception 'มี policy UPDATE/ALL บน draft_entry_tags (%) · ทุกคอลัมน์เป็นคีย์ การ UPDATE จึงเป็นการย้ายลิงก์ไปร่าง/tag อื่นโดยไม่มีร่องรอยว่าของเดิมเคยเป็นอะไร', v;
  end if;

  if not (select c.relrowsecurity from pg_class c
           where c.oid = 'sri_os.draft_entry_tags'::regclass) then
    raise exception 'RLS ของ draft_entry_tags ยังปิดอยู่ = ไม่มีด่านเลย';
  end if;

  -- (ฉ) ด่านคอลัมน์
  select string_agg(u.object_name || ': ' || u.problem, ' · ') into v
    from sri_os.fn_column_exposure_unclassified() u
   where u.object_name like 'draft_entry_tags%';
  if v is not null then
    raise exception 'ด่านคอลัมน์ยังมีของค้างจาก draft_entry_tags (D-089): %', v;
  end if;
  select string_agg(b.object_name || ': ' || b.problem, ' · ') into v
    from sri_os.fn_column_exposure_breaches() b
   where b.object_name like 'draft_entry_tags%';
  if v is not null then
    raise exception 'ด่านคอลัมน์ของ draft_entry_tags ไม่ติดจริง: %', v;
  end if;
  if not sri_os.fn_policy_requires_permission('draft_entry_tags', 'draft.read_own') then
    raise exception 'policy อ่านของ draft_entry_tags ไม่ได้บังคับ draft.read_own ทุกตัว → ลิงก์ของร่างเปิดกว้างกว่าร่างที่มันอธิบาย';
  end if;

  raise notice 'tag บนร่างพร้อม: คีย์คู่ (draft_entry_id, tag_id) · cascade ตามร่าง restrict ตาม tag · แก้ได้เฉพาะตอน pending แล้วแช่แข็ง · ไม่มี policy UPDATE · ขอบเขตมาจาก policy ตัวจริงของร่าง · **ชิ้นที่ย้าย tag จากร่างเข้าสมุด (fn_post_entry) ยังไม่ลง — หน้าจอยังไม่ควรเปิดช่องนี้**';
end $$;
