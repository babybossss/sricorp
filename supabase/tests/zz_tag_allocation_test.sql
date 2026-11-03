-- ============================================================
-- SRI OS · **ถ่วงน้ำหนัก tag (60/40) — ยอดต่อ project บวกกันได้จริง**
--            (ADR 0003 ข้อ A1–A5 ·
--             20261028000001_tag_allocations.sql ·
--             20261028000002_tag_allocated_views.sql ·
--             20261028000003_tag_allocation_gate.sql)
--
-- **เขียนก่อนโค้ดของ A3/A4** ตามคำสั่งใน ADR 0003 ข้อ 7 (test-first)
--
-- ------------------------------------------------------------
-- สิ่งที่ไฟล์นี้พิสูจน์ — ทุกข้อเป็น **ตัวเลขที่วัดได้** ไม่ใช่ "ไม่ error"
-- ------------------------------------------------------------
--   W0  · โครงสร้าง: ตาราง/constraint/index/trigger/วิว/ประตู มีอยู่จริงและตั้งถูก ·
--         `tag_allocations` **ไม่มีคอลัมน์ numeric ที่ scale ≠ 6** (ADR 0003 ข้อ 3.2) ·
--         วิวที่ปันส่วนแล้ว **ไม่ cast กลับเป็น numeric(18,2)** (ข้อ 4.2 · 4.2.1)
--   W1  · Σ น้ำหนัก ≠ 1 → **ปฏิเสธ** ทั้งขาด (0.9) · เกิน (1.1) ·
--         **ขาด 0.000001** (0.599999 + 0.4) · **เกิน 0.000001** (0.600001 + 0.4)
--         และ Σ = 1 พอดี → ผ่าน (ข้อ 4.1 เทียบแบบ exact ไม่มี tolerance)
--   W2  · ติด tag ชนิดที่ปันส่วนแล้ว **ไม่ใส่น้ำหนัก → ปฏิเสธ** (ข้อ 4.1 ข้อย่อย 1 ·
--         บทเรียน mace-windu ข้อ 1/ข้อ 3: ข้อมูลไม่ครบต้องปฏิเสธ ไม่ใช่เดาให้เป็น 100%)
--         + น้ำหนักที่ยังใช้อยู่ห้ามผูกกับลิงก์ที่ถูกถอดไปแล้ว (ข้อ 4.1 ข้อย่อย 3)
--   W3  · **Σ ยอดที่ปันส่วนของทุก tag = ยอดในสมุดเป๊ะ** และ
--         **Σ allocated_debit = Σ allocated_credit ต่อ tag เป๊ะ** ทุกชุดน้ำหนัก:
--         60/40 · 0.333334-0.333333-0.333333 · 0.999999/0.000001 · เจ็ดทาง ·
--         ยอด 0.01 · **ใบรูปกลับรายการ (เดบิต/เครดิตสลับข้าง)**
--   W4  · **เคสเศษสตางค์ของตารางข้อ 4.2**: เดบิต 0.05 + 0.05 / เครดิต 0.10 แบ่ง 50/50
--         → ต่อ tag ต้องได้ 0.050 ทั้งสองฝั่ง (**ดุล**) · ถ้าปัดรายบรรทัดจะได้
--         A 0.06/0.05 และ B 0.04/0.05 (ไม่ดุลทั้งคู่) ขณะที่ผลรวมข้าม tag ยังตรงสมุด
--         → **ไม่มีด่านไหนจับได้** นี่คือเหตุผลที่ ADR ห้ามปัดที่ชั้นวิว
--   W5  · แก้น้ำหนักย้อนหลัง = ปิดของเก่า + เปิดของใหม่ · แถวที่ปิดแล้วไม่เข้าวิว ·
--         หนึ่งลิงก์มีน้ำหนักที่ใช้อยู่ได้ตัวเดียว · ลบไม่ได้ · เหตุผลว่างไม่ได้
--   W6  · **ประตู `fn_post_entry` ช่อง `tag_weights`**:
--         (ก) project อันเดียว ไม่ส่งน้ำหนัก → เติม 1.000000 ให้ (คำตอบที่ถูกมีอันเดียว)
--         (ข) **สอง project ไม่ส่งน้ำหนัก → ปฏิเสธทั้งใบ**
--         (ค) Σ ≠ 1 → ปฏิเสธ · (ง) ชนิดที่ไม่ปันส่วน (label) ส่งมาในช่องนี้ → ปฏิเสธ
--         (จ) tag ที่ไม่มี/ปิดแล้ว → ปฏิเสธทั้งใบ · (ฉ) ช่องที่ไม่รู้จัก → ปฏิเสธ
--         (ช) **ใบข้ามผู้ถือ: น้ำหนักชุดเดียวกันลงให้ทั้งสองขา** (ข้อ 4.2.2 ชั้น 1)
--   W7  · **`fn_reallocate_tags` ครอบทั้งคู่ของใบข้ามผู้ถือ** (ข้อ 4.2.2 ชั้น 2):
--         เรียกด้วยขาเดียว → น้ำหนักของ **ทั้งสองขา** เปลี่ยนพร้อมกัน ·
--         Σ ≠ 1 / เหตุผลว่าง / ส่ง tag ไม่ครบ → ปฏิเสธ
--   M1  · MUTATION ปิดด่าน Σ = 1 → ลง 60/60 (Σ = 1.2) ได้ แล้ว **วัดได้ว่า**
--         ยอดต่อ project บวกกันได้ 1,200,000 ขณะที่เงินจริง 1,000,000
--         (= ปัญหาที่ ADR 0002 ข้อ 4.1 กลัว กลับมาทันทีเมื่อปิดด่านนี้)
--   M2  · MUTATION ปิดด่าน "ลิงก์ต้องมีน้ำหนัก" → ติดสอง project แต่ใส่น้ำหนัก
--         ให้อันเดียว (0.6) ได้ แล้วยอดรวมที่ปันส่วนกลายเป็น 600,000
--         จากเงินจริง 1,000,000 → **400,000 หายไปจากทุกรายงานต่อ project**
--   M3  · MUTATION ให้ `fn_tag_counter_legs()` คืนแต่ขาตัวเอง → `fn_reallocate_tags`
--         ต้อง **ปฏิเสธ** ไม่ใช่แก้ข้างเดียวเงียบๆ (ข้อ 4.2.2 "หาขาคู่ไม่เจอ → ปฏิเสธ")
--   M5  · MUTATION **ขยับ `c_header` ของประตูจริง** → คำตอบของ
--         `fn_post_entry_accepted_tag_kinds()` ต้อง **พลิก**: เติมช่องปลอมแล้วรับ
--         `label` · ถอดช่องจริงแล้วเลิกรับ `project` · ชื่อช่องที่อยู่ใน **คอมเมนต์**
--         หรือใน `c_line` **ห้ามนับ** · อ่านไม่ออก = พัง ไม่ใช่คืนชุดว่าง
--         (พิสูจน์ว่า W12 เขียวเพราะตัวไล่อ่านของจริง ไม่ใช่เพราะคอมเมนต์)
--   M6  · MUTATION เปิดช่อง `tag_ids` ขณะเส้นทางร่างยังไม่มีช่องน้ำหนัก →
--         `fn_assert_tag_read_path()` ต้องพังพร้อมชี้ A8 (ADR 0003 ข้อ 7.1)
--   M7  · MUTATION เพิ่มรายงานที่อ่านยอดที่ปันส่วนแล้ว **โดยไม่แตะธงขาคู่** →
--         ด่านต้องพัง · ตัวที่ตัดขาคู่แล้วต้องผ่าน (มีธงแต่ไม่มีใครดู = ยอดโป่ง)
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ **rollback** ปิดท้าย — ไม่ทิ้งรายการเงินไว้
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
create temporary table w_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into w_uid(label) values ('w_mgmt');
insert into auth.users(id) select id from w_uid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, 'tag-alloc@local', 'mgmt (น้ำหนัก tag)', 'management', true from w_uid u;
select set_config('test.uid', (select id::text from w_uid where label = 'w_mgmt'), true);

insert into sri_os.user_owner_access(user_id, owner_id)
select (select id from w_uid where label = 'w_mgmt'), o.id from sri_os.owners o;

create or replace function pg_temp.own(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.owners where code = p_code $fn$;

create or replace function pg_temp.coa(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.chart_of_accounts where code = p_code $fn$;

create or replace function pg_temp.tag(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.tags where code = p_code $fn$;

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name) values
  ('00000000-0000-0000-0000-0000000eab01', pg_temp.own('THANAKORN'),
   'KBANK', 'ธนากร', 'ธนากร - KBANK (น้ำหนัก tag)');

-- แค็ตตาล็อกของเทสต์ — migration ไม่ seed tag ตัวอย่างเลยตาม ADR 0002 ข้อ 5 ข้อ 6
insert into sri_os.tags(kind, code, name_th, color_token) values
  ('project', 'wa-p1', 'โปรเจกต์ A (น้ำหนัก)', 'brand'),
  ('project', 'wa-p2', 'โปรเจกต์ B (น้ำหนัก)', 'info'),
  ('project', 'wa-p3', 'โปรเจกต์ C (น้ำหนัก)', null),
  ('project', 'wa-p4', 'โปรเจกต์ D (น้ำหนัก)', null),
  ('project', 'wa-p5', 'โปรเจกต์ E (น้ำหนัก)', null),
  ('project', 'wa-p6', 'โปรเจกต์ F (น้ำหนัก)', null),
  ('project', 'wa-p7', 'โปรเจกต์ G (น้ำหนัก)', null),
  ('project', 'wa-off', 'โปรเจกต์ที่ปิดแล้ว', null),
  ('project', 'wa-ic',  'โปรเจกต์ของรายการข้ามผู้ถือ', null),
  ('project', 'wa-ic2', 'โปรเจกต์ของรายการข้ามผู้ถือ (ฉาก mutation)', null),
  ('project', 'wa-shut','โปรเจกต์ที่จะถูกปิดหลังมีใบติดไปแล้ว', null),
  ('label',   'wa-lbl', 'ป้ายกำกับ (ไม่ปันส่วน)', 'warn');

-- ------------------------------------------------------------
-- ตัวช่วย
-- ------------------------------------------------------------
/** บังคับให้ constraint trigger ที่เลื่อนไว้ยิง **เดี๋ยวนี้** — ไม่งั้นเคส
 *  "ต้องถูกปฏิเสธ" จะเขียวด้วยเหตุผลผิด เพราะเทสต์ rollback ไม่ถึง commit */
create or replace function pg_temp.fire() returns void
language plpgsql as $fn$
begin
  set constraints all immediate;
  set constraints all deferred;
end $fn$;

create or replace function pg_temp.must_fail_like(p_label text, p_sql text, p_needle text) returns void
language plpgsql as $fn$
declare v text;
begin
  begin
    execute p_sql;
    perform pg_temp.fire();
    raise exception 'WA_UNEXPECTED_SUCCESS';
  exception when others then
    v := sqlerrm;
    if v = 'WA_UNEXPECTED_SUCCESS' then
      raise exception 'FAIL: % — คำสั่งควรถูกปฏิเสธแต่สำเร็จ', p_label;
    end if;
    if v like 'FAIL:%' then raise; end if;
    if position(p_needle in v) = 0 then
      raise exception 'FAIL: % — ปฏิเสธถูกแต่ข้อความไม่มี "%" · ได้: %', p_label, p_needle, v;
    end if;
  end;
end $fn$;

create or replace function pg_temp.must_pass(p_label text, p_sql text) returns void
language plpgsql as $fn$
begin
  execute p_sql;
  perform pg_temp.fire();
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: % — เส้นทางที่ถูกต้องถูกปฏิเสธ (กันแน่นเกิน): %', p_label, sqlerrm;
end $fn$;

/** ใบตั้งค้างจ่าย Dr 5900 / Cr 2100 — ไม่มีขาเงินสด จึงไม่ต้องมี cash_date
 *  ลงตรงที่ตาราง (ไม่ผ่านประตู) เพื่อให้คุมจำนวนบรรทัดได้เอง — เคส W4 ต้องการ
 *  ใบที่สองฝั่งมีจำนวนบรรทัด **ไม่เท่ากัน** ซึ่งเป็นรูปของตัวอย่างค้านในข้อ 4.2 */
create or replace function pg_temp.mk(p_id uuid, p_amt numeric, p_split boolean default false)
returns uuid language plpgsql as $fn$
begin
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, memo, attachments)
  values (p_id, pg_temp.own('THANAKORN'), 'exp.other', '2026-05-01',
          'WA ' || p_id::text, array['หลักฐาน-WA.pdf']);
  if p_split then
    -- สองบรรทัดฝั่งเดบิต หนึ่งบรรทัดฝั่งเครดิต (เศษตกคนละขนาดสองฝั่งถ้าปัด)
    insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit, cf_category, memo)
    values (p_id, pg_temp.coa('5900'), p_amt / 2, 0, 'none', 'ขาค่าใช้จ่าย 1'),
           (p_id, pg_temp.coa('5900'), p_amt / 2, 0, 'none', 'ขาค่าใช้จ่าย 2'),
           (p_id, pg_temp.coa('2100'), 0, p_amt, 'none', 'ขาเจ้าหนี้');
  else
    insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit, cf_category, memo)
    values (p_id, pg_temp.coa('5900'), p_amt, 0, 'none', 'ขาค่าใช้จ่าย'),
           (p_id, pg_temp.coa('2100'), 0, p_amt, 'none', 'ขาเจ้าหนี้');
  end if;
  perform pg_temp.fire();
  return p_id;
end $fn$;

/** **ใบกลับรายการจริง** — ภาพกระจกของใบต้นฉบับ (เดบิต/เครดิตสลับข้าง)
 *  ข้อ 4.2 บังคับเคส "ยอดติดลบ (ใบกลับรายการ)" ในลิสต์เทสต์
 *  ต้องเป็นใบกลับรายการจริง (`source = 'reverse'` + `reverses_id`) ไม่ใช่ใบสลับข้าง
 *  ลอยๆ เพราะการลดยอดบัญชีพัก 2100 ของใบธรรมดาติดด่านล้างยอด (20261025000003)
 *  ซึ่งถูกต้อง — ใบกลับรายการได้รับการยกเว้นจากด่านนั้นโดยเจตนา */
create or replace function pg_temp.mk_mirror(p_id uuid, p_orig uuid, p_amt numeric)
returns uuid language plpgsql as $fn$
begin
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, memo, attachments,
                                  source, reverses_id)
  values (p_id, pg_temp.own('THANAKORN'), 'exp.other', '2026-05-02',
          'WA mirror ' || p_id::text, array['หลักฐาน-WA.pdf'],
          'reverse', p_orig);
  insert into sri_os.transaction_lines(transaction_id, coa_id, debit, credit, cf_category, memo)
  values (p_id, pg_temp.coa('2100'), p_amt, 0, 'none', 'กลับขาเจ้าหนี้'),
         (p_id, pg_temp.coa('5900'), 0, p_amt, 'none', 'กลับขาค่าใช้จ่าย');
  perform pg_temp.fire();
  return p_id;
end $fn$;

create or replace function pg_temp.link(p_txn uuid, p_tag text) returns uuid
language plpgsql as $fn$
declare v uuid;
begin
  insert into sri_os.transaction_tags(transaction_id, tag_id)
  values (p_txn, pg_temp.tag(p_tag)) returning id into v;
  return v;
end $fn$;

create or replace function pg_temp.alloc(p_link uuid, p_w numeric) returns uuid
language plpgsql as $fn$
declare v uuid;
begin
  insert into sri_os.tag_allocations(transaction_tag_id, weight)
  values (p_link, p_w) returning id into v;
  return v;
end $fn$;

/** ใส่น้ำหนักโดย **ส่ง owner_id มาเอง** — ใช้พิสูจน์ว่าสำเนาผู้ถือถูกบังคับ
 *  (ส่งตรงกับลิงก์ = ผ่าน · ส่งไม่ตรง = ปฏิเสธ · ไม่ใช่ทับให้เงียบๆ) */
create or replace function pg_temp.alloc_own(p_link uuid, p_owner uuid, p_w numeric) returns uuid
language plpgsql as $fn$
declare v uuid;
begin
  insert into sri_os.tag_allocations(transaction_tag_id, owner_id, weight)
  values (p_link, p_owner, p_w) returning id into v;
  return v;
end $fn$;

/** ติด tag + ใส่น้ำหนักในคราวเดียว (ไม่ยิงด่าน — ปล่อยให้ผู้เรียกยิงเอง) */
create or replace function pg_temp.weigh(p_txn uuid, p_tag text, p_w numeric) returns uuid
language sql as $fn$ select pg_temp.alloc(pg_temp.link(p_txn, p_tag), p_w) $fn$;

/** ยอดในสมุดของใบหนึ่ง — **คิดเองในเทสต์จากตารางฐาน** ไม่ถามวิวที่กำลังทดสอบ */
create or replace function pg_temp.book(p_txn uuid, p_side text) returns numeric
language sql stable as $fn$
  select coalesce(sum(case when p_side = 'dr' then l.debit else l.credit end), 0)
    from sri_os.transaction_lines l
    join sri_os.transactions t on t.id = l.transaction_id
   where l.transaction_id = p_txn and t.status = 'posted';
$fn$;

/** ยอดที่ปันส่วนแล้วของใบหนึ่ง — รวมทุก tag (ต้องเท่ากับ pg_temp.book เป๊ะ) */
create or replace function pg_temp.alloc_all(p_txn uuid, p_side text) returns numeric
language sql stable as $fn$
  select coalesce(sum(case when p_side = 'dr' then v.allocated_debit
                          else v.allocated_credit end), 0)
    from sri_os.v_ledger_allocated v
   where v.transaction_id = p_txn;
$fn$;

/** ยอดที่ปันส่วนแล้วของ (ใบ × tag) — ใช้พิสูจน์ว่างบต่อ project ดุล */
create or replace function pg_temp.alloc_one(p_txn uuid, p_tag text, p_side text) returns numeric
language sql stable as $fn$
  select coalesce(sum(case when p_side = 'dr' then v.allocated_debit
                          else v.allocated_credit end), 0)
    from sri_os.v_ledger_allocated v
   where v.transaction_id = p_txn and v.tag_id = pg_temp.tag(p_tag);
$fn$;

-- ============================================================
-- W0 · โครงสร้าง — ไล่จาก catalog จริง ไม่ใช่ไล่ไฟล์
-- ============================================================
do $$
declare v text; n int;
begin
  if to_regclass('sri_os.tag_allocations') is null then
    raise exception 'FAIL: W0 — ยังไม่มีตาราง tag_allocations · เทสต์นี้จะไม่ได้ตรวจอะไรเลย';
  end if;
  if to_regclass('sri_os.v_ledger_allocated') is null
     or to_regclass('sri_os.v_tag_allocated_totals') is null then
    raise exception 'FAIL: W0 — ยังไม่มีวิว v_ledger_allocated / v_tag_allocated_totals (A3)';
  end if;
  if to_regprocedure('sri_os.fn_reallocate_tags(uuid,text,jsonb,text)') is null
     or to_regprocedure('sri_os.fn_tag_counter_legs(uuid)') is null
     or to_regprocedure('sri_os.fn_assert_tag_read_path()') is null then
    raise exception 'FAIL: W0 — ฟังก์ชันของประตู/ด่านอ่านไม่ครบ (A3/A4)';
  end if;

  -- (ก) **ห้ามมีคอลัมน์จำนวนเงิน** — ยอมเฉพาะ `weight` ที่ scale = 6
  --     ไล่จาก numeric_scale ไม่ใช่จากชื่อ (ADR 0003 ข้อ 3.2)
  select string_agg(c.column_name || ' (scale ' || coalesce(c.numeric_scale::text, '-') || ')', ', ')
    into v
    from information_schema.columns c
   where c.table_schema = 'sri_os' and c.table_name = 'tag_allocations'
     and c.data_type in ('numeric', 'money', 'double precision', 'real')
     and (c.numeric_scale is distinct from 6);
  if v is not null then
    raise exception 'FAIL: W0a — tag_allocations มีคอลัมน์ตัวเลขที่ scale ≠ 6: % · ตารางนี้ถือ **ตัวคูณ** เท่านั้น จำนวนเงินมาจากสมุดเสมอ (ADR 0003 ข้อ 3.2)', v;
  end if;
  if not exists (select 1 from information_schema.columns c
                  where c.table_schema = 'sri_os' and c.table_name = 'tag_allocations'
                    and c.column_name = 'weight' and c.data_type = 'numeric'
                    and c.numeric_precision = 9 and c.numeric_scale = 6) then
    raise exception 'FAIL: W0a — weight ต้องเป็น numeric(9,6) ตาม ADR 0003 ข้อ 3.2 (scale 6 คือที่ด่าน W0a ใช้แยกตัวคูณจากจำนวนเงิน)';
  end if;

  -- (ก2) **ทุกแถวมี owner_id** (กฎเหล็กข้อ 3) — เหมือน transaction_tags ของ ADR 0002
  --      ตารางนี้คือตารางที่รายงานเงินพึ่งพาโดยตรง (ตัวคูณของยอดต่อ Entity)
  if not exists (select 1 from information_schema.columns c
                  where c.table_schema = 'sri_os' and c.table_name = 'tag_allocations'
                    and c.column_name = 'owner_id'
                    and c.data_type = 'uuid' and c.is_nullable = 'NO') then
    raise exception 'FAIL: W0a2 — tag_allocations ไม่มีคอลัมน์ owner_id แบบ uuid not null → ละเมิดกฎเหล็กข้อ 3 ("ทุกแถวมี owner_id และรายงานทุกหน้ากรอง Entity ได้") · การ join ผ่านลิงก์ไม่ใช่ข้อยกเว้นที่กฎเหล็กเจาะให้';
  end if;
  if not exists (select 1 from pg_constraint con
                  where con.conrelid = 'sri_os.tag_allocations'::regclass
                    and con.contype = 'f'
                    and con.confrelid = 'sri_os.owners'::regclass) then
    raise exception 'FAIL: W0a2 — owner_id ของ tag_allocations ไม่มี FK ไปที่ owners → ชี้ผู้ถือที่ไม่มีตัวตนได้';
  end if;
  if not exists (select 1 from pg_class i
                  where i.relname = 'tag_alloc_by_owner'
                    and i.relnamespace = 'sri_os'::regnamespace) then
    raise exception 'FAIL: W0a2 — ไม่มี index tag_alloc_by_owner → กรอง Entity ต้องไล่ทั้งตาราง';
  end if;
  -- ด่านของแถวต้องอ่านผู้ถือ **จากลิงก์เอง** ไม่ใช่เชื่อค่าที่ส่งมา (D-115)
  if pg_get_functiondef('sri_os.fn_tag_alloc_system_columns()'::regprocedure)
     !~ 'from sri_os\.transaction_tags' then
    raise exception 'FAIL: W0a2 — ด่านของน้ำหนักไม่ได้อ่าน owner_id จาก transaction_tags → แถวน้ำหนักชี้ผู้ถือผิดได้ทั้งที่ FK ผ่าน';
  end if;

  -- (ข) index/constraint ตาม ADR 0003 ข้อ 3.2
  if not exists (select 1 from pg_index i join pg_class c on c.oid = i.indexrelid
                  where c.relname = 'tag_alloc_active_uq'
                    and i.indisunique and i.indpred is not null) then
    raise exception 'FAIL: W0b — tag_alloc_active_uq ต้องเป็น partial unique index (หนึ่งลิงก์ = หนึ่งน้ำหนักที่ใช้อยู่) · ไม่ unique = ลิงก์เดียวมีสองน้ำหนักพร้อมกันแล้ว Σ เพี้ยน · ไม่มี predicate = แก้น้ำหนักย้อนหลังไม่ได้ตลอดกาล';
  end if;
  select string_agg(x.want, ', ') into v
    from (values ('tag_alloc_weight_range'), ('tag_alloc_supersede_both'),
                 ('tag_alloc_supersede_order')) x(want)
   where not exists (select 1 from pg_constraint con
                      where con.conrelid = 'sri_os.tag_allocations'::regclass
                        and con.conname = x.want and con.convalidated);
  if v is not null then raise exception 'FAIL: W0b — constraint หายไป/ยังไม่ validate: %', v; end if;

  -- (ค) ด่าน Σ = 1 ต้องเป็น constraint trigger แบบ deferred **ทั้งสองตาราง**
  --     ตารางน้ำหนัก (ลบ/แก้น้ำหนักแล้ว Σ เพี้ยน) และตารางลิงก์ (ติด tag แล้วไม่ใส่น้ำหนัก)
  --     ขาดตัวใดตัวหนึ่ง = เปิดฟีเจอร์ครึ่งเดียว (บทเรียน mace-windu ข้อ 7)
  select string_agg(x.rel || '.' || x.trg, ', ') into v
    from (values ('tag_allocations',  'trg_assert_tag_allocation_complete'),
                 ('transaction_tags', 'trg_assert_tag_allocation_links')) x(rel, trg)
   where not exists (select 1 from pg_trigger g join pg_proc p on p.oid = g.tgfoid
                      where g.tgrelid = ('sri_os.' || x.rel)::regclass
                        and g.tgname = x.trg
                        and p.proname = 'fn_assert_tag_allocation_complete'
                        and g.tgdeferrable and g.tginitdeferred and not g.tgisinternal);
  if v is not null then
    raise exception 'FAIL: W0c — constraint trigger ของด่าน Σ = 1 ไม่ครบ/ไม่ deferred: %', v;
  end if;

  -- (ง) ลบน้ำหนักไม่ได้ (append-only เหมือนลิงก์ tag · กฎเหล็กข้อ 1) และ RLS เปิด
  select string_agg(p.polname || '/' || p.polcmd::text, ', ') into v
    from pg_policy p
   where p.polrelid = 'sri_os.tag_allocations'::regclass and p.polcmd in ('d', '*');
  if v is not null then raise exception 'FAIL: W0d — มี policy DELETE/ALL บน tag_allocations: %', v; end if;
  if not (select relrowsecurity from pg_class where oid = 'sri_os.tag_allocations'::regclass) then
    raise exception 'FAIL: W0d — RLS ของ tag_allocations ปิดอยู่ = ไม่มีด่านเลย';
  end if;
  if not sri_os.fn_policy_requires_permission('tag_allocations', 'ledger.read') then
    raise exception 'FAIL: W0d — policy อ่านของ tag_allocations ไม่บังคับ ledger.read → สัดส่วนของใบรั่วไปถึงตำแหน่งที่อ่านสมุดไม่ได้ (น้ำหนัก + ยอดที่เห็นจากที่อื่น = ยอดของ project)';
  end if;

  -- (จ) **ห้าม cast ยอดที่ปันส่วนแล้วกลับเป็น numeric(18,2)** (ข้อ 4.2 · 4.2.1)
  --     ไล่จาก **นิยามของวิวจริงใน catalog** ไม่ใช่พึ่งความจำของคนที่แก้ครั้งถัดไป
  for v in select unnest(array['v_ledger_allocated', 'v_tag_allocated_totals']) loop
    if pg_get_viewdef(('sri_os.' || v)::regclass, true) ~* 'numeric\s*\(\s*18' then
      raise exception 'FAIL: W0e — นิยามของ % มี cast เป็น numeric(18,…) · cast = ปัด = พังทั้งสองข้อของ ADR 0003 ข้อ 4.2 (ผลรวมข้าม tag ไม่ตรงสมุด และงบต่อ project ไม่ดุล)', v;
    end if;
  end loop;
  -- ชนิดจริงของคอลัมน์ที่ปันส่วนแล้วต้องเป็น numeric **ไม่ระบุ scale**
  select string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ') into v
    from pg_attribute a
   where a.attrelid = 'sri_os.v_ledger_allocated'::regclass
     and a.attname in ('allocated_debit', 'allocated_credit')
     and format_type(a.atttypid, a.atttypmod) <> 'numeric';
  if v is not null then
    raise exception 'FAIL: W0e — คอลัมน์ที่ปันส่วนแล้วถูกจำกัด scale: % · ต้องเป็น numeric เปล่าๆ (ยอด 18,2 × น้ำหนัก 9,6 ได้ scale 8 · บีบกลับ = ปัด)', v;
  end if;

  -- (ฉ) ชื่อคอลัมน์ต้องไม่หลอกกัน (ข้อ 5) และต้องมี weight_sum มาด้วย
  if exists (select 1 from pg_attribute a
              where a.attrelid = 'sri_os.v_tag_allocated_totals'::regclass
                and a.attnum > 0 and not a.attisdropped
                and (a.attname like 'touched\_%' or a.attname in ('total', 'amount'))) then
    raise exception 'FAIL: W0f — v_tag_allocated_totals มีคอลัมน์ชื่อ touched_* / total / amount · touch กับ allocated ห้ามปนกัน (ADR 0003 ข้อ 5)';
  end if;
  select string_agg(x.want, ', ') into v
    from (values ('allocated_debit'), ('allocated_credit'), ('allocated_txn_count'),
                 ('weight_sum'), ('allocation_note_th')) x(want)
   where not exists (select 1 from pg_attribute a
                      where a.attrelid = 'sri_os.v_tag_allocated_totals'::regclass
                        and a.attname = x.want and a.attnum > 0 and not a.attisdropped);
  if v is not null then
    raise exception 'FAIL: W0f — v_tag_allocated_totals ขาดคอลัมน์: % (weight_sum ทำให้คนอ่านเห็นเองว่าใบถูกแบ่ง · allocation_note_th คือประโยคกำกับที่มาจาก DB)', v;
  end if;

  -- (ช) ด่านอ่านต้องผ่านตอนนี้ และ **ด่านกันตัวเองตาย** ต้องเห็นวิวของตัวเองครบ
  perform sri_os.fn_assert_tag_read_path();
  perform sri_os.fn_assert_ledger_read_path();

  -- (ซ) ประตูต้องรู้จักช่อง tag_weights (ไม่ใช่เด้ง "ช่องที่ยังไม่รู้จัก")
  if pg_get_functiondef('sri_os.fn_post_entry(jsonb)'::regprocedure) !~ 'tag_weights' then
    raise exception 'FAIL: W0h — fn_post_entry ไม่รู้จักช่อง tag_weights → บันทึกน้ำหนักจากหน้าจอไม่ได้เลย (A4)';
  end if;

  -- (ฌ) ทุกคอลัมน์ของตารางใหม่ต้องอยู่ในทะเบียนด่านคอลัมน์ (D-089)
  select count(*) into n from sri_os.fn_column_exposure_unclassified() u
   where u.object_name like 'tag_allocations%';
  if n <> 0 then
    raise exception 'FAIL: W0i — tag_allocations ยังมี % รายการที่ไม่ได้จัดประเภทในด่านคอลัมน์ (D-089)', n;
  end if;

  raise notice 'ok W0 · ตารางถือแต่ตัวคูณ (scale 6 ตัวเดียว) · partial unique + constraint ครบ · ด่าน Σ = 1 เป็น constraint trigger deferred ทั้งบนตารางน้ำหนักและตารางลิงก์ · ลบไม่ได้ · RLS บังคับ ledger.read · วิวไม่ปัดและไม่ cast กลับ · ประตูรู้จัก tag_weights';
end $$;

-- ============================================================
-- W1 · Σ น้ำหนัก = 1 **พอดี** — ไม่มี tolerance แม้ 0.000001
-- ============================================================
do $$
declare v_t uuid := '00000000-0000-0000-0000-0000000ea101';
begin
  perform pg_temp.mk(v_t, 1000000);

  -- (ก) ขาด 0.1
  perform pg_temp.must_fail_like('W1a Σ = 0.9', format($q$
    select pg_temp.weigh(%L, 'wa-p1', 0.6), pg_temp.weigh(%L, 'wa-p2', 0.3) $q$, v_t, v_t),
    'น้ำหนัก');
end $$;

do $$
declare v_t uuid := '00000000-0000-0000-0000-0000000ea102';
begin
  perform pg_temp.mk(v_t, 1000000);
  -- (ข) เกิน 0.1
  perform pg_temp.must_fail_like('W1b Σ = 1.1', format($q$
    select pg_temp.weigh(%L, 'wa-p1', 0.6), pg_temp.weigh(%L, 'wa-p2', 0.5) $q$, v_t, v_t),
    'น้ำหนัก');
end $$;

do $$
declare v_t uuid := '00000000-0000-0000-0000-0000000ea103';
begin
  perform pg_temp.mk(v_t, 1000000);
  -- (ค) **ขาด 0.000001** — หน่วยที่เล็กที่สุดที่คอลัมน์เก็บได้ ก็ยังไม่ผ่าน
  perform pg_temp.must_fail_like('W1c Σ = 0.999999', format($q$
    select pg_temp.weigh(%L, 'wa-p1', 0.599999), pg_temp.weigh(%L, 'wa-p2', 0.4) $q$, v_t, v_t),
    'น้ำหนัก');
end $$;

do $$
declare v_t uuid := '00000000-0000-0000-0000-0000000ea104';
begin
  perform pg_temp.mk(v_t, 1000000);
  -- (ง) **เกิน 0.000001**
  perform pg_temp.must_fail_like('W1d Σ = 1.000001', format($q$
    select pg_temp.weigh(%L, 'wa-p1', 0.600001), pg_temp.weigh(%L, 'wa-p2', 0.4) $q$, v_t, v_t),
    'น้ำหนัก');
end $$;

do $$
declare v_t uuid := '00000000-0000-0000-0000-0000000ea105';
        v_msg text;
begin
  perform pg_temp.mk(v_t, 1000000);
  -- (จ) Σ = 1 พอดี → ผ่าน
  perform pg_temp.must_pass('W1e Σ = 1 พอดี', format($q$
    select pg_temp.weigh(%L, 'wa-p1', 0.6), pg_temp.weigh(%L, 'wa-p2', 0.4) $q$, v_t, v_t));

  -- (ฉ) ข้อความ error ต้องบอก **ยอดที่ขาด/เกิน** และ **รายชื่อ tag พร้อมน้ำหนัก**
  --     ไม่ใช่แค่ "ไม่ถึง 100%" — คนแก้ต้องรู้ว่าจะไปเติมที่ไหน (ข้อ 4.1)
  begin
    perform pg_temp.weigh(v_t, 'wa-p3', 0.000001);
    perform pg_temp.fire();
    raise exception 'FAIL: W1f — เติมน้ำหนักเกินแล้วยังผ่าน';
  exception when others then
    v_msg := sqlerrm;
    if v_msg like 'FAIL:%' then raise; end if;
    if position('wa-p1' in v_msg) = 0 or position('wa-p3' in v_msg) = 0 then
      raise exception 'FAIL: W1f — ข้อความไม่มีรายชื่อ tag พร้อมน้ำหนักปัจจุบัน · ได้: %', v_msg;
    end if;
    if position('1.000001' in v_msg) = 0 and position('0.000001' in v_msg) = 0 then
      raise exception 'FAIL: W1f — ข้อความไม่บอกยอดที่ขาด/เกิน · ได้: %', v_msg;
    end if;
  end;

  raise notice 'ok W1 · Σ = 1 เทียบแบบ exact (0.999999 และ 1.000001 ถูกปฏิเสธทั้งคู่) · ข้อความบอกยอดที่ขาด/เกินและรายชื่อ tag';
end $$;

-- ============================================================
-- W2 · ติด tag ชนิดที่ปันส่วนแล้ว **ไม่ใส่น้ำหนัก → ปฏิเสธ**
--      (ข้อมูลไม่ครบต้องปฏิเสธ ไม่ใช่เดาให้เป็น 100% · บทเรียน mace-windu ข้อ 1)
-- ============================================================
do $$
declare v_t uuid := '00000000-0000-0000-0000-0000000ea201';
begin
  perform pg_temp.mk(v_t, 500000);
  perform pg_temp.must_fail_like('W2a ติด project อันเดียวแต่ไม่ใส่น้ำหนัก', format($q$
    select pg_temp.link(%L, 'wa-p1') $q$, v_t),
    'น้ำหนัก');
end $$;

do $$
declare v_t uuid := '00000000-0000-0000-0000-0000000ea202';
        v_l uuid;
begin
  perform pg_temp.mk(v_t, 500000);
  -- ชนิดที่ไม่ปันส่วน (label) ติดเปล่าๆ ได้ตามเดิม — **ห้ามกันแน่นเกิน**
  perform pg_temp.must_pass('W2b label ไม่ต้องมีน้ำหนัก', format($q$
    select pg_temp.link(%L, 'wa-lbl') $q$, v_t));

  -- และ label **ห้ามมีน้ำหนัก** (น้ำหนักของชนิดที่ไม่ปันส่วนไม่มีความหมาย
  -- และจะทำให้วิว touch กับ allocated ปนกัน · ข้อ 5)
  select id into v_l from sri_os.transaction_tags
   where transaction_id = v_t and tag_id = pg_temp.tag('wa-lbl');
  perform pg_temp.must_fail_like('W2c ใส่น้ำหนักให้ label', format($q$
    select pg_temp.alloc(%L, 1.0) $q$, v_l),
    'ปันส่วน');
end $$;

do $$
declare v_t uuid := '00000000-0000-0000-0000-0000000ea203';
        v_l uuid;
begin
  perform pg_temp.mk(v_t, 500000);
  v_l := pg_temp.link(v_t, 'wa-p1');
  perform pg_temp.alloc(v_l, 1.0);
  perform pg_temp.fire();

  -- (ง) ถอด tag แล้วน้ำหนักที่ยังใช้อยู่ห้ามค้าง (ข้อ 4.1 ข้อย่อย 3 · กันแถวกำพร้า)
  perform pg_temp.must_fail_like('W2d ถอด tag แต่น้ำหนักยังใช้อยู่', format($q$
    update sri_os.transaction_tags
       set untagged_at = now(), untagged_by = auth.uid(),
           untag_reason = 'W2d ทดสอบแถวกำพร้า'
     where id = %L $q$, v_l),
    'น้ำหนัก');

  raise notice 'ok W2 · ติด project แล้วไม่ใส่น้ำหนัก = ปฏิเสธ · label ไม่ต้องมีน้ำหนักและห้ามมี · ถอด tag ต้องปิดน้ำหนักไปด้วย (ไม่มีแถวกำพร้า)';
end $$;

-- ============================================================
-- W3 · **Σ ที่ปันส่วน = ยอดในสมุดเป๊ะ** และ **ดุลต่อ tag เป๊ะ** ทุกชุดน้ำหนัก
--      (ข้อ 4.2 ข้อ 1 และข้อ 2 · ไม่มี tolerance ที่ไหนเลย)
-- ============================================================
do $$
declare
  r         record;
  v_txn     uuid;
  v_i       int := 0;
  v_tags    text[];
  v_ws      numeric[];
  v_j       int;
  v_dr      numeric;
  v_cr      numeric;
  v_sum_dr  numeric;
  v_sum_cr  numeric;
begin
  for r in
    select * from (values
      -- (ชุดน้ำหนัก, ยอดใบ, คำอธิบาย)
      (array[0.6, 0.4],                                    1000000::numeric, '60/40'),
      (array[0.333334, 0.333333, 0.333333],                1000000::numeric, 'สามทางเท่ากัน (เศษตกที่ tag แรก)'),
      (array[0.999999, 0.000001],                          1000000::numeric, '0.999999 / 0.000001'),
      (array[0.3, 0.25, 0.2, 0.1, 0.07, 0.05, 0.03],       1234567.89::numeric, 'เจ็ดทาง'),
      (array[0.6, 0.4],                                    0.01::numeric,     'ยอด 0.01 (หนึ่งสตางค์)'),
      (array[0.5, 0.5],                                    3333.33::numeric,  'ครึ่งต่อครึ่งบนยอดที่หารไม่ลงตัว')
    ) as x(ws, amt, note)
  loop
    v_i := v_i + 1;
    v_txn := ('00000000-0000-0000-0000-0000000ea3' || lpad(v_i::text, 2, '0'))::uuid;
    perform pg_temp.mk(v_txn, r.amt);

    v_tags := array['wa-p1', 'wa-p2', 'wa-p3', 'wa-p4', 'wa-p5', 'wa-p6', 'wa-p7'];
    v_ws   := r.ws;
    for v_j in 1 .. array_length(v_ws, 1) loop
      perform pg_temp.weigh(v_txn, v_tags[v_j], v_ws[v_j]);
    end loop;
    perform pg_temp.fire();

    -- ข้อ 1 · ผลรวมข้าม tag = ยอดในสมุด **เป๊ะ**
    v_dr := pg_temp.book(v_txn, 'dr');
    v_cr := pg_temp.book(v_txn, 'cr');
    v_sum_dr := pg_temp.alloc_all(v_txn, 'dr');
    v_sum_cr := pg_temp.alloc_all(v_txn, 'cr');
    if v_sum_dr <> v_dr or v_sum_cr <> v_cr then
      raise exception 'FAIL: W3 (%) — Σ ที่ปันส่วนไม่เท่ายอดในสมุด · เดบิต % vs % · เครดิต % vs % · ถ้าตัวเลขนี้ไม่ตรง รายงาน "กำไรต่อ project" ที่ ADR 0003 เปิดให้ทำจะผิดทั้งหน้า',
        r.note, v_sum_dr, v_dr, v_sum_cr, v_cr;
    end if;

    -- ข้อ 2 · งบของแต่ละ tag **ยังดุล** (เหตุผลที่เปิดรายงานกำไรต่อ project ได้)
    for v_j in 1 .. array_length(v_ws, 1) loop
      if pg_temp.alloc_one(v_txn, v_tags[v_j], 'dr')
         <> pg_temp.alloc_one(v_txn, v_tags[v_j], 'cr') then
        raise exception 'FAIL: W3 (%) — งบของ % ไม่ดุล: เดบิต % เครดิต % · double entry ต่อ tag ต้องดุลทั้งสองฝั่ง ไม่งั้นตัวเลขกำไรต่อ project ไม่มีความหมาย',
          r.note, v_tags[v_j],
          pg_temp.alloc_one(v_txn, v_tags[v_j], 'dr'),
          pg_temp.alloc_one(v_txn, v_tags[v_j], 'cr');
      end if;
      -- และต้องเท่ากับ ยอด × น้ำหนัก เป๊ะ (ไม่ปัด)
      if pg_temp.alloc_one(v_txn, v_tags[v_j], 'dr') <> v_dr * v_ws[v_j] then
        raise exception 'FAIL: W3 (%) — ยอดของ % ไม่เท่ากับ ยอด × น้ำหนัก (% vs %) · มีการปัดเกิดขึ้นที่ชั้นวิว',
          r.note, v_tags[v_j], pg_temp.alloc_one(v_txn, v_tags[v_j], 'dr'), v_dr * v_ws[v_j];
      end if;
    end loop;
  end loop;

  -- **ใบกลับรายการ** (เดบิต/เครดิตสลับข้าง) — ลิสต์เทสต์ของข้อ 4.2 บังคับ
  -- ต้นฉบับคือใบ 60/40 ของฉากแรก (ea301) · ใบกลับรายการก็ติด tag + น้ำหนักได้เอง
  v_txn := '00000000-0000-0000-0000-0000000ea390';
  perform pg_temp.mk_mirror(v_txn, '00000000-0000-0000-0000-0000000ea301', 1000000);
  perform pg_temp.weigh(v_txn, 'wa-p1', 0.6);
  perform pg_temp.weigh(v_txn, 'wa-p2', 0.4);
  perform pg_temp.fire();
  if pg_temp.alloc_all(v_txn, 'dr') <> pg_temp.book(v_txn, 'dr')
     or pg_temp.alloc_all(v_txn, 'cr') <> pg_temp.book(v_txn, 'cr')
     or pg_temp.alloc_one(v_txn, 'wa-p1', 'dr') <> pg_temp.alloc_one(v_txn, 'wa-p1', 'cr') then
    raise exception 'FAIL: W3 (ใบกลับรายการ) — ยอดที่ปันส่วนของใบที่เดบิต/เครดิตสลับข้างไม่ตรง/ไม่ดุล';
  end if;

  raise notice 'ok W3 · ทุกชุดน้ำหนัก (60/40 · สามทาง · 0.999999/0.000001 · เจ็ดทาง · ยอด 0.01 · ครึ่งต่อครึ่งบนยอดที่หารไม่ลงตัว · ใบกลับรายการ): Σ ข้าม tag = ยอดในสมุดเป๊ะ และงบต่อ tag ดุลเป๊ะ';
end $$;

-- ============================================================
-- W4 · **เคสเศษสตางค์ของตารางข้อ 4.2** — เดบิต 0.05 + 0.05 / เครดิต 0.10 แบ่ง 50/50
--      ทางที่ปฏิเสธ (ปัดรายบรรทัด) ให้ A 0.06/0.05 และ B 0.04/0.05 = **ไม่ดุลทั้งคู่**
--      ขณะที่ผลรวมข้าม tag ยังตรงสมุด (0.06+0.04 = 0.10) จึงไม่มีด่านไหนจับได้
-- ============================================================
do $$
declare
  v_t   uuid := '00000000-0000-0000-0000-0000000ea401';
  v_a_dr numeric; v_a_cr numeric; v_b_dr numeric; v_b_cr numeric;
begin
  perform pg_temp.mk(v_t, 0.10, true);          -- 0.05 + 0.05 / 0.10
  perform pg_temp.weigh(v_t, 'wa-p1', 0.5);
  perform pg_temp.weigh(v_t, 'wa-p2', 0.5);
  perform pg_temp.fire();

  v_a_dr := pg_temp.alloc_one(v_t, 'wa-p1', 'dr');
  v_a_cr := pg_temp.alloc_one(v_t, 'wa-p1', 'cr');
  v_b_dr := pg_temp.alloc_one(v_t, 'wa-p2', 'dr');
  v_b_cr := pg_temp.alloc_one(v_t, 'wa-p2', 'cr');

  -- ฉากต้องเป็นฉากเดิมจริง: สองฝั่งมีจำนวนบรรทัดไม่เท่ากัน
  if (select count(*) from sri_os.transaction_lines where transaction_id = v_t and debit > 0) <> 2
     or (select count(*) from sri_os.transaction_lines where transaction_id = v_t and credit > 0) <> 1 then
    raise exception 'FAIL: W4 — ฉากไม่ใช่ฉากของตารางข้อ 4.2 (ต้องเป็นเดบิตสองบรรทัด เครดิตหนึ่งบรรทัด)';
  end if;

  if v_a_dr <> v_a_cr or v_b_dr <> v_b_cr then
    raise exception 'FAIL: W4 — double entry ต่อ tag **ไม่ดุล**: A %/% · B %/% · นี่คืออาการของการปัดรายบรรทัด (ตารางข้อ 4.2) ซึ่งสมุดใหญ่ยังดุลสนิทจึงไม่มีด่านไหนฟ้อง',
      v_a_dr, v_a_cr, v_b_dr, v_b_cr;
  end if;
  if v_a_dr <> 0.05 or v_b_dr <> 0.05 then
    raise exception 'FAIL: W4 — ต่อ tag ต้องได้ 0.050 ทั้งสองฝั่ง (ไม่ปัด) แต่ได้ A % · B %', v_a_dr, v_b_dr;
  end if;
  if v_a_dr + v_b_dr <> 0.10 or v_a_cr + v_b_cr <> 0.10 then
    raise exception 'FAIL: W4 — ผลรวมข้าม tag ไม่ตรงสมุด (% / %)', v_a_dr + v_b_dr, v_a_cr + v_b_cr;
  end if;

  raise notice 'ok W4 · เคสเศษสตางค์ของตารางข้อ 4.2: ต่อ tag ได้ 0.050/0.050 ดุลทั้งสองฝั่ง และรวมข้าม tag = 0.10 ตรงสมุด (ปัดรายบรรทัดจะได้ 0.06/0.05 กับ 0.04/0.05 = ไม่ดุลทั้งคู่)';
end $$;

-- ============================================================
-- W5 · แก้น้ำหนักย้อนหลัง = ปิดของเก่า + เปิดของใหม่ (ข้อ 3.3)
-- ============================================================
do $$
declare
  v_t  uuid := '00000000-0000-0000-0000-0000000ea501';
  v_l1 uuid; v_l2 uuid; v_a1 uuid;
begin
  perform pg_temp.mk(v_t, 1000000);
  v_l1 := pg_temp.link(v_t, 'wa-p1');
  v_l2 := pg_temp.link(v_t, 'wa-p2');
  v_a1 := pg_temp.alloc(v_l1, 0.6);
  perform pg_temp.alloc(v_l2, 0.4);
  perform pg_temp.fire();

  -- (ก) UPDATE weight ตรงๆ ไม่ได้ (ต้องปิด + เปิดใหม่)
  perform pg_temp.must_fail_like('W5a แก้ weight ทับ', format($q$
    update sri_os.tag_allocations set weight = 0.7 where id = %L $q$, v_a1),
    'แก้');

  -- (ข) DELETE ไม่ได้ทุกทาง (append-only · กฎเหล็กข้อ 1)
  perform pg_temp.must_fail_like('W5b ลบน้ำหนัก', format($q$
    delete from sri_os.tag_allocations where id = %L $q$, v_a1),
    'ลบ');

  -- (ค) ปิดครึ่งเดียวไม่ได้ (เงื่อนไขสองทาง) · เหตุผลว่างไม่ได้
  perform pg_temp.must_fail_like('W5c ปิดโดยไม่มีเหตุผล', format($q$
    update sri_os.tag_allocations
       set superseded_at = now(), superseded_by = auth.uid() where id = %L $q$, v_a1),
    'tag_alloc_supersede_both');
  perform pg_temp.must_fail_like('W5d เหตุผลเป็นช่องว่าง', format($q$
    update sri_os.tag_allocations
       set superseded_at = now(), superseded_by = auth.uid(), supersede_reason = '   '
     where id = %L $q$, v_a1),
    'tag_alloc_supersede_both');

  -- (จ) น้ำหนักนอกช่วง 0 < w <= 1
  perform pg_temp.must_fail_like('W5e น้ำหนัก 0', format($q$
    select pg_temp.alloc(%L, 0) $q$, v_l1), 'tag_alloc_weight_range');
  perform pg_temp.must_fail_like('W5f น้ำหนักเกิน 1', format($q$
    select pg_temp.alloc(%L, 1.5) $q$, v_l1), 'tag_alloc_weight_range');

  -- (ช) ลิงก์เดียวมีน้ำหนักที่ใช้อยู่สองแถวพร้อมกันไม่ได้
  perform pg_temp.must_fail_like('W5g น้ำหนักซ้อนบนลิงก์เดียว', format($q$
    select pg_temp.alloc(%L, 0.3) $q$, v_l1), 'tag_alloc_active_uq');

  raise notice 'ok W5 · weight แก้ทับไม่ได้ · ลบไม่ได้ · ปิดต้องครบสามช่องและเหตุผลว่างไม่ได้ · 0 < w <= 1 · หนึ่งลิงก์หนึ่งน้ำหนักที่ใช้อยู่';
end $$;

-- ============================================================
-- W6 · **ประตู `fn_post_entry` ช่อง `tag_weights`** (A4 · ข้อ 6)
-- ============================================================
create or replace function pg_temp.post(p_payload jsonb) returns uuid[]
language plpgsql as $fn$
declare v jsonb;
begin
  v := sri_os.fn_post_entry(p_payload);
  if (v ->> 'replayed')::boolean then
    raise exception 'FAIL: fn_post_entry ถือว่าใบนี้เป็นการกดซ้ำ (memo ของแต่ละใบต้องไม่ซ้ำกัน)';
  end if;
  perform pg_temp.fire();
  return (select array_agg(x::uuid) from jsonb_array_elements_text(v -> 'transaction_ids') x);
end $fn$;

/** ใบตั้งค้างจ่ายผ่านประตู (ไม่มีขาเงินสด → ไม่ต้องมี cash_date) */
-- หมายเหตุ: ประกอบ `tag_weights` **หลัง** jsonb_strip_nulls เพราะเคส W6a ส่ง
-- น้ำหนักเป็น null มาโดยเจตนา (ประตูต้องเติม 1.000000 ให้) ถ้าโดน strip ไปก่อน
-- จะกลายเป็น object ว่างซึ่งเป็นอีกเคสหนึ่งคนละความหมาย
create or replace function pg_temp.entry(p_memo text, p_amt numeric, p_weights jsonb)
returns jsonb language sql stable as $fn$
  select case when p_weights is null then s.o
              else jsonb_set(s.o, '{tag_weights}', p_weights) end
    from (select jsonb_strip_nulls(jsonb_build_object(
            'txn_type_code', 'exp.other',
            'doc_date', '2026-06-01',
            'memo', p_memo,
            'transactions', jsonb_build_array(jsonb_build_object(
              'owner_id', pg_temp.own('THANAKORN'),
              'lines', jsonb_build_array(
                jsonb_build_object('coa_code', '5900', 'debit', p_amt, 'credit', 0,
                                   'cf_category', 'none'),
                jsonb_build_object('coa_code', '2100', 'debit', 0, 'credit', p_amt,
                                   'cf_category', 'none')))))) as o) s;
$fn$;

do $$
declare v_ids uuid[]; v_w numeric;
begin
  -- (ก) project **อันเดียว** ไม่ส่งน้ำหนัก → ประตูเติม 1.000000 ให้เอง
  --     ไม่ใช่การเดา เพราะมีคำตอบที่ถูกได้คำตอบเดียว (ข้อ 4.1 ข้อย่อย 1 ยกเว้น)
  v_ids := pg_temp.post(pg_temp.entry('W6a', 1000,
             jsonb_build_object(pg_temp.tag('wa-p1')::text, null)));
  select a.weight into v_w
    from sri_os.tag_allocations a
    join sri_os.transaction_tags l on l.id = a.transaction_tag_id
   where l.transaction_id = v_ids[1] and a.superseded_at is null;
  if v_w is distinct from 1.000000 then
    raise exception 'FAIL: W6a — project อันเดียวต้องได้น้ำหนัก 1.000000 แต่ได้ %', v_w;
  end if;
  if pg_temp.alloc_all(v_ids[1], 'dr') <> 1000 then
    raise exception 'FAIL: W6a — ยอดที่ปันส่วนของใบที่ติด project เดียวต้องเท่ายอดเต็ม แต่ได้ %',
      pg_temp.alloc_all(v_ids[1], 'dr');
  end if;

  -- (ข) **สอง project ไม่ส่งน้ำหนัก → ปฏิเสธทั้งใบ** (บทเรียน mace-windu ข้อ 3:
  --     เทสต์ที่ส่งข้อมูลครบเสมอจะไม่มีวันแตะเส้นทางที่ข้อมูลขาด)
  perform pg_temp.must_fail_like('W6b สอง project ไม่ส่งน้ำหนัก', format($q$
    select pg_temp.post(pg_temp.entry('W6b', 1000, jsonb_build_object(%L, null, %L, null))) $q$,
    pg_temp.tag('wa-p1')::text, pg_temp.tag('wa-p2')::text),
    'น้ำหนัก');

  -- (ค) Σ ≠ 1 → ปฏิเสธ
  perform pg_temp.must_fail_like('W6c Σ = 0.9 ที่ประตู', format($q$
    select pg_temp.post(pg_temp.entry('W6c', 1000, jsonb_build_object(%L, 0.6, %L, 0.3))) $q$,
    pg_temp.tag('wa-p1')::text, pg_temp.tag('wa-p2')::text),
    'น้ำหนัก');

  -- (ง) ชนิดที่ไม่ปันส่วนส่งมาในช่องนี้ → ปฏิเสธ (touch กับ allocated ห้ามปนกัน)
  perform pg_temp.must_fail_like('W6d label ใน tag_weights', format($q$
    select pg_temp.post(pg_temp.entry('W6d', 1000, jsonb_build_object(%L, 1.0))) $q$,
    pg_temp.tag('wa-lbl')::text),
    'ปันส่วน');

  -- (จ) tag ที่ไม่มีจริง / ปิดแล้ว → ปฏิเสธทั้งใบ (ไม่ทิ้งช่องเงียบๆ)
  perform pg_temp.must_fail_like('W6e tag ที่ไม่มีจริง',
    $q$ select pg_temp.post(pg_temp.entry('W6e', 1000,
          jsonb_build_object('00000000-0000-0000-0000-00000000dead', 1.0))) $q$,
    'tag');
  update sri_os.tags set is_active = false, archived_at = now(), archived_by = auth.uid()
   where code = 'wa-off';
  perform pg_temp.must_fail_like('W6f tag ที่ปิดแล้ว', format($q$
    select pg_temp.post(pg_temp.entry('W6f', 1000, jsonb_build_object(%L, 1.0))) $q$,
    pg_temp.tag('wa-off')::text),
    'tag');

  -- (ฉ) รูปที่ไม่ใช่ object / น้ำหนักที่ไม่ใช่ตัวเลข / ว่างเปล่า → ปฏิเสธ
  perform pg_temp.must_fail_like('W6g tag_weights เป็น array',
    $q$ select pg_temp.post(jsonb_set(pg_temp.entry('W6g', 1000, jsonb_build_object('x', 1)),
          '{tag_weights}', '[]'::jsonb)) $q$, 'ต้องเป็น object');
  perform pg_temp.must_fail_like('W6h น้ำหนักเป็นข้อความ', format($q$
    select pg_temp.post(pg_temp.entry('W6h', 1000, jsonb_build_object(%L, 'หกสิบ'))) $q$,
    pg_temp.tag('wa-p1')::text), 'น้ำหนัก');

  raise notice 'ok W6 · ประตูเติม 1.000000 ให้ project อันเดียว · สอง project ไม่ส่งน้ำหนัก = ปฏิเสธ · Σ ≠ 1 = ปฏิเสธ · label/tag ที่ปิดแล้ว/รูปผิด = ปฏิเสธทั้งใบ';
end $$;

-- ============================================================
-- W6i · **ใบข้ามผู้ถือ: น้ำหนักชุดเดียวกันต้องลงให้ทั้งสองขา** (ข้อ 4.2.2 ชั้น 1)
-- ============================================================
create or replace function pg_temp.pair(p_memo text, p_amt numeric, p_weights jsonb)
returns uuid[] language sql as $fn$
  select pg_temp.post(jsonb_build_object(
    'txn_type_code', 'trf.internal',
    'doc_date', '2026-06-10', 'cash_date', '2026-06-10',
    'memo', p_memo,
    'tag_weights', p_weights,
    'transactions', jsonb_build_array(
      jsonb_build_object('owner_id', pg_temp.own('THANAKORN'),
                         'counter_owner_id', pg_temp.own('SUTEE'),
                         'intercompany_nature', 'loan',
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code', '1310', 'debit', p_amt, 'credit', 0, 'cf_category', 'investing'),
          jsonb_build_object('coa_code', '1100', 'bank_account_id',
                             '00000000-0000-0000-0000-0000000eab01',
                             'debit', 0, 'credit', p_amt, 'cf_category', 'investing'))),
      jsonb_build_object('owner_id', pg_temp.own('SUTEE'),
                         'counter_owner_id', pg_temp.own('THANAKORN'),
                         'intercompany_nature', 'loan',
        'lines', jsonb_build_array(
          jsonb_build_object('coa_code', '1100', 'bank_account_id',
                             '00000000-0000-0000-0000-0000000eab02',
                             'debit', p_amt, 'credit', 0, 'cf_category', 'financing'),
          jsonb_build_object('coa_code', '2310', 'debit', 0, 'credit', p_amt, 'cf_category', 'financing'))))));
$fn$;

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name) values
  ('00000000-0000-0000-0000-0000000eab02', pg_temp.own('SUTEE'),
   'SCB', 'สุธี', 'สุธี - SCB (น้ำหนัก tag)');

do $$
declare v_ids uuid[]; n int;
begin
  v_ids := pg_temp.pair('W6i', 200000,
             jsonb_build_object(pg_temp.tag('wa-p1')::text, 0.6,
                                pg_temp.tag('wa-p2')::text, 0.4));
  if array_length(v_ids, 1) <> 2 then
    raise exception 'FAIL: W6i — ใบข้ามผู้ถือต้องได้สองใบ (หนึ่งใบ = หนึ่งผู้ถือ · กฎเหล็กข้อ 4) แต่ได้ %',
      array_length(v_ids, 1);
  end if;

  -- น้ำหนักของทั้งสองขาต้องเหมือนกันทุกตัวอักษร
  select count(*) into n
    from (select l.transaction_id, t.code, a.weight
            from sri_os.tag_allocations a
            join sri_os.transaction_tags l on l.id = a.transaction_tag_id
            join sri_os.tags t on t.id = l.tag_id
           where l.transaction_id = any (v_ids) and a.superseded_at is null) x;
  if n <> 4 then
    raise exception 'FAIL: W6i — ต้องมีน้ำหนัก 4 แถว (2 ใบ × 2 tag) แต่ได้ % · ลงน้ำหนักให้ขาเดียวแปลว่ายอดต่อ project ของคู่นั้นไม่สมมาตร (ข้อ 4.2.2)', n;
  end if;
  if exists (
    select 1
      from (select t.code, a.weight
              from sri_os.tag_allocations a
              join sri_os.transaction_tags l on l.id = a.transaction_tag_id
              join sri_os.tags t on t.id = l.tag_id
             where l.transaction_id = v_ids[1] and a.superseded_at is null) a1
      full join (select t.code, a.weight
              from sri_os.tag_allocations a
              join sri_os.transaction_tags l on l.id = a.transaction_tag_id
              join sri_os.tags t on t.id = l.tag_id
             where l.transaction_id = v_ids[2] and a.superseded_at is null) a2
        on a2.code = a1.code
     where a1.code is null or a2.code is null or a1.weight <> a2.weight) then
    raise exception 'FAIL: W6i — น้ำหนักของสองขาไม่เหมือนกัน';
  end if;

  raise notice 'ok W6i · ประตูลงน้ำหนักชุดเดียวกันให้ทุกใบในคำขอ (ทั้งสองขาของรายการข้ามผู้ถือ)';
end $$;

-- ============================================================
-- W7 · **`fn_reallocate_tags` ต้องครอบทั้งคู่** (ข้อ 4.2.2 ชั้น 2)
-- ============================================================
do $$
declare
  v_ids uuid[]; v_res jsonb; v_w1 numeric; v_w2 numeric; n int;
begin
  v_ids := pg_temp.pair('W7', 300000,
             jsonb_build_object(pg_temp.tag('wa-p1')::text, 0.6,
                                pg_temp.tag('wa-p2')::text, 0.4));

  -- (ก) เรียกด้วย **ขาเดียว** → น้ำหนักของทั้งสองขาต้องเปลี่ยนพร้อมกัน
  v_res := sri_os.fn_reallocate_tags(
             v_ids[1], 'project',
             jsonb_build_object(pg_temp.tag('wa-p1')::text, 0.25,
                                pg_temp.tag('wa-p2')::text, 0.75),
             'W7 ลูกพี่สั่งแก้สัดส่วนเป็น 25/75');
  perform pg_temp.fire();

  if jsonb_array_length(v_res -> 'transaction_ids') <> 2 then
    raise exception 'FAIL: W7a — fn_reallocate_tags ต้องรายงานว่าแก้สองใบ แต่ได้ % · แก้ข้างเดียวจะผ่านโดยไม่มีด่านไหนจับ (ข้อ 4.2.2)',
      jsonb_array_length(v_res -> 'transaction_ids');
  end if;

  select a.weight into v_w1
    from sri_os.tag_allocations a
    join sri_os.transaction_tags l on l.id = a.transaction_tag_id
   where l.transaction_id = v_ids[1] and l.tag_id = pg_temp.tag('wa-p1')
     and a.superseded_at is null;
  select a.weight into v_w2
    from sri_os.tag_allocations a
    join sri_os.transaction_tags l on l.id = a.transaction_tag_id
   where l.transaction_id = v_ids[2] and l.tag_id = pg_temp.tag('wa-p1')
     and a.superseded_at is null;
  if v_w1 is distinct from 0.250000 or v_w2 is distinct from 0.250000 then
    raise exception 'FAIL: W7a — น้ำหนักหลังแก้ไม่ตรงทั้งสองขา (ขา A = % · ขา B = %)', v_w1, v_w2;
  end if;

  -- ชุดเดิมต้องถูก **ปิดด้วยร่องรอย** ไม่ใช่ทับหาย (ข้อ 3.3)
  select count(*) into n
    from sri_os.tag_allocations a
    join sri_os.transaction_tags l on l.id = a.transaction_tag_id
   where l.transaction_id = any (v_ids)
     and a.superseded_at is not null
     and a.supersede_reason like 'W7 ลูกพี่สั่ง%'
     and a.superseded_by = auth.uid();
  if n <> 4 then
    raise exception 'FAIL: W7a — ชุดน้ำหนักเดิมต้องถูกปิดครบ 4 แถวพร้อมเหตุผลและชื่อคน แต่ได้ %', n;
  end if;

  -- และยอดที่ปันส่วนยังตรงสมุดเป๊ะหลังแก้
  if pg_temp.alloc_all(v_ids[1], 'dr') <> pg_temp.book(v_ids[1], 'dr') then
    raise exception 'FAIL: W7a — หลังแก้สัดส่วน Σ ที่ปันส่วนไม่ตรงสมุด (% vs %)',
      pg_temp.alloc_all(v_ids[1], 'dr'), pg_temp.book(v_ids[1], 'dr');
  end if;

  -- (ข) เหตุผลว่าง → ปฏิเสธ (เหมือน untag_reason)
  perform pg_temp.must_fail_like('W7b เหตุผลว่าง', format($q$
    select sri_os.fn_reallocate_tags(%L, 'project',
      jsonb_build_object(%L, 0.5, %L, 0.5), '   ') $q$,
    v_ids[1], pg_temp.tag('wa-p1')::text, pg_temp.tag('wa-p2')::text), 'เหตุผล');

  -- (ค) Σ ≠ 1 → ปฏิเสธ
  perform pg_temp.must_fail_like('W7c Σ ≠ 1', format($q$
    select sri_os.fn_reallocate_tags(%L, 'project',
      jsonb_build_object(%L, 0.5, %L, 0.4), 'W7c ทดสอบ Σ ไม่ครบ') $q$,
    v_ids[1], pg_temp.tag('wa-p1')::text, pg_temp.tag('wa-p2')::text), 'น้ำหนัก');

  -- (ง) ส่ง tag ไม่ครบที่ติดอยู่ → ปฏิเสธ (ไม่ใช่ถอด tag ที่หายไปเงียบๆ)
  perform pg_temp.must_fail_like('W7d ส่ง tag ไม่ครบ', format($q$
    select sri_os.fn_reallocate_tags(%L, 'project',
      jsonb_build_object(%L, 1.0), 'W7d ส่งมาแค่ tag เดียว') $q$,
    v_ids[1], pg_temp.tag('wa-p1')::text), 'ครบ');

  -- (จ) ชนิดที่ไม่ปันส่วน → ปฏิเสธ
  perform pg_temp.must_fail_like('W7e ชนิด label', format($q$
    select sri_os.fn_reallocate_tags(%L, 'label',
      jsonb_build_object(%L, 1.0), 'W7e ป้ายกำกับไม่มีน้ำหนัก') $q$,
    v_ids[1], pg_temp.tag('wa-lbl')::text), 'ปันส่วน');

  raise notice 'ok W7 · เรียกขาเดียวแต่น้ำหนักเปลี่ยนทั้งคู่ · ชุดเดิมปิดด้วยร่องรอย (ใคร/ทำไม) · เหตุผลว่าง/Σ ≠ 1/ส่ง tag ไม่ครบ/ชนิดที่ไม่ปันส่วน = ปฏิเสธ';
end $$;

-- ============================================================
-- M1 · MUTATION — ปิดด่าน Σ = 1 แล้วลง 60/60 (Σ = 1.2)
--      → **วัดได้** ว่ายอดต่อ project บวกกันได้ 1,200,000 จากเงินจริง 1,000,000
--      (คือปัญหาที่ ADR 0002 ข้อ 4.1 กลัว · กลับมาทันทีเมื่อปิดด่านนี้)
--      ถ้าปิดแล้วยังลงไม่ได้ แปลว่า W1 เขียวเพราะด่านอื่น ไม่ใช่ด่านของชิ้นนี้
-- ============================================================
savepoint before_sum_mutation;
do $$
declare v_t uuid := '00000000-0000-0000-0000-0000000eaf01';
        v_all numeric; v_book numeric;
begin
  alter table sri_os.tag_allocations  disable trigger trg_assert_tag_allocation_complete;
  alter table sri_os.transaction_tags disable trigger trg_assert_tag_allocation_links;

  perform pg_temp.mk(v_t, 1000000);
  perform pg_temp.must_pass('M1 ลง 60/60 ขณะปิดด่าน', format($q$
    select pg_temp.weigh(%L, 'wa-p1', 0.6), pg_temp.weigh(%L, 'wa-p2', 0.6) $q$, v_t, v_t));

  v_book := pg_temp.book(v_t, 'dr');
  v_all  := pg_temp.alloc_all(v_t, 'dr');
  if v_book <> 1000000 then
    raise exception 'FAIL: M1 — ฉากไม่ใช่ฉากเดิม (ยอดในสมุด %)', v_book;
  end if;
  if v_all <> 1200000 then
    raise exception 'FAIL: M1 — ปิดด่านแล้วยอดต่อ project ต้องบวกกันได้ 1,200,000 (120%% ของเงินจริง) แต่ได้ % · ถ้าตัวเลขนี้ไม่ใช่ 1,200,000 แปลว่า W1 เขียวเพราะด่านอื่น ไม่ใช่ด่าน Σ = 1 ของชิ้นนี้',
      v_all;
  end if;

  alter table sri_os.tag_allocations  enable trigger trg_assert_tag_allocation_complete;
  alter table sri_os.transaction_tags enable trigger trg_assert_tag_allocation_links;

  raise notice 'ok M1 · ปิดด่าน Σ = 1 = กำไรที่ไม่จริงกลับมาทันที (ยอดต่อ project รวม 1,200,000 จากเงินจริง 1,000,000 · งบดุลยังดุลสนิทและไม่มีตัวเลขในสมุดผิดเลย)';
end $$;
rollback to savepoint before_sum_mutation;

do $$
begin
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.tag_allocations'::regclass
                    and g.tgname = 'trg_assert_tag_allocation_complete'
                    and g.tgenabled = 'O') then
    raise exception 'FAIL: M1b — ด่านตัวจริงไม่กลับมาหลัง rollback';
  end if;
  if exists (select 1 from sri_os.transactions
              where id = '00000000-0000-0000-0000-0000000eaf01') then
    raise exception 'FAIL: M1b — ใบของ mutation ยังค้างอยู่ในสมุด';
  end if;
  raise notice 'ok M1b · ด่านกลับมาและไม่มีใบของ mutation ค้างในสมุด';
end $$;

-- ============================================================
-- M2 · MUTATION — ปิดด่าน "ลิงก์ต้องมีน้ำหนัก" แล้วติดสอง project
--      แต่ใส่น้ำหนักให้อันเดียว (0.6) → ยอดรวมที่ปันส่วนเหลือ 600,000
--      จากเงินจริง 1,000,000 → **400,000 หายไปจากทุกรายงานต่อ project**
--      (อาการตรงข้ามกับ M1 และเงียบกว่า เพราะไม่มีตัวเลขไหนโป่ง)
-- ============================================================
savepoint before_link_mutation;
do $$
declare v_t uuid := '00000000-0000-0000-0000-0000000eaf02';
        v_all numeric;
begin
  alter table sri_os.tag_allocations  disable trigger trg_assert_tag_allocation_complete;
  alter table sri_os.transaction_tags disable trigger trg_assert_tag_allocation_links;

  perform pg_temp.mk(v_t, 1000000);
  perform pg_temp.must_pass('M2 ติดสอง project ใส่น้ำหนักอันเดียว', format($q$
    select pg_temp.weigh(%L, 'wa-p1', 0.6), pg_temp.link(%L, 'wa-p2') $q$, v_t, v_t));

  v_all := pg_temp.alloc_all(v_t, 'dr');
  if v_all <> 600000 then
    raise exception 'FAIL: M2 — ปิดด่านแล้วยอดรวมที่ปันส่วนต้องเหลือ 600,000 (หาย 400,000) แต่ได้ % · ถ้าตัวเลขนี้ไม่ใช่ 600,000 แปลว่า W2 เขียวเพราะด่านอื่น',
      v_all;
  end if;

  alter table sri_os.tag_allocations  enable trigger trg_assert_tag_allocation_complete;
  alter table sri_os.transaction_tags enable trigger trg_assert_tag_allocation_links;

  raise notice 'ok M2 · ปิดด่าน "ลิงก์ต้องมีน้ำหนัก" = 400,000 หายจากทุกรายงานต่อ project โดยไม่มีตัวเลขไหนโป่งให้สังเกต';
end $$;
rollback to savepoint before_link_mutation;

-- ============================================================
-- M3 · MUTATION — ให้ `fn_tag_counter_legs()` คืนแต่ขาตัวเอง
--      → `fn_reallocate_tags` ต้อง **ปฏิเสธ** ไม่ใช่แก้ข้างเดียวเงียบๆ
--      (ข้อ 4.2.2: "ถ้าหาขาคู่ไม่เจอ → ปฏิเสธ")
-- ============================================================
savepoint before_pair_mutation;
do $$
declare v_ids uuid[];
begin
  v_ids := pg_temp.pair('M3', 400000,
             jsonb_build_object(pg_temp.tag('wa-p1')::text, 0.6,
                                pg_temp.tag('wa-p2')::text, 0.4));

  create or replace function sri_os.fn_tag_counter_legs(p_transaction_id uuid)
  returns uuid[] language sql stable set search_path = '' as $m$
    select array[p_transaction_id];
  $m$;

  perform pg_temp.must_fail_like('M3 หาขาคู่ไม่เจอ', format($q$
    select sri_os.fn_reallocate_tags(%L, 'project',
      jsonb_build_object(%L, 0.5, %L, 0.5), 'M3 แก้ครึ่งทาง') $q$,
    v_ids[1], pg_temp.tag('wa-p1')::text, pg_temp.tag('wa-p2')::text),
    'ขาคู่');

  raise notice 'ok M3 · หาขาคู่ไม่เจอ = ปฏิเสธ (ไม่แก้ข้างเดียวเงียบๆ) · พิสูจน์ว่า W7a เขียวเพราะตัวหาขาคู่ตัวนี้จริง';
end $$;
rollback to savepoint before_pair_mutation;

do $$
begin
  -- เรียกด้วย id จริงไม่ได้ (ใบของ M3 ถูก rollback ไปแล้ว) → ตรวจจาก **นิยาม** ว่า
  -- ตัวจริงกลับมา: รุ่นที่ mutation ใส่ไว้คืนแต่ array[p_transaction_id] และไม่มี
  -- การไล่ counter_owner_id เลย
  if pg_get_functiondef('sri_os.fn_tag_counter_legs(uuid)'::regprocedure)
     !~ 'counter_owner_id' then
    raise exception 'FAIL: M3b — fn_tag_counter_legs ตัวจริงไม่กลับมาหลัง rollback (นิยามยังเป็นรุ่นของ mutation)';
  end if;
  if exists (select 1 from sri_os.transactions where memo like 'M3%') then
    raise exception 'FAIL: M3b — ใบของ mutation ยังค้างอยู่ในสมุด';
  end if;
  raise notice 'ok M3b · fn_tag_counter_legs ตัวจริงกลับมาและไม่มีใบของ mutation ค้างในสมุด';
end $$;

-- ============================================================
-- W8 · วิวยอดรวมต่อ tag — ประโยคกำกับมาจาก DB และ touch/allocated ไม่ปนกัน
-- ============================================================
do $$
declare v_t uuid := '00000000-0000-0000-0000-0000000ea801';
        r record;
        v_dr numeric; v_cr numeric;
begin
  perform pg_temp.mk(v_t, 1000000);
  perform pg_temp.weigh(v_t, 'wa-p1', 0.6);
  perform pg_temp.weigh(v_t, 'wa-p2', 0.4);
  perform pg_temp.link(v_t, 'wa-lbl');
  perform pg_temp.fire();

  -- ชนิดที่ไม่ปันส่วนต้อง **ไม่โผล่** ในวิวที่ปันส่วนแล้ว (ADR 0003 ข้อ 5)
  if exists (select 1 from sri_os.v_tag_allocated_totals where tag_kind = 'label') then
    raise exception 'FAIL: W8 — ชนิดที่ไม่ปันส่วนโผล่ใน v_tag_allocated_totals → คนอ่านจะเอา touch มาบวกกับ allocated';
  end if;
  -- และ tag ที่ติดแบบไม่มีน้ำหนัก (label) ต้องไม่โผล่ในวิวระดับบรรทัดด้วย
  if exists (select 1 from sri_os.v_ledger_allocated
              where tag_id = pg_temp.tag('wa-lbl')) then
    raise exception 'FAIL: W8 — tag ชนิด label โผล่ใน v_ledger_allocated';
  end if;

  -- (ก) **งบต่อ tag ดุล** เมื่อรวมทุกบัญชีของ tag นั้น
  --     (แถวในวิวแยกตาม coa_id/cf_category ตามกติกา ADR 0002 ข้อ 4.4
  --      "ไม่มีคอลัมน์ยอดใบรวม" → ความดุลอ่านได้ที่ระดับ tag ไม่ใช่ระดับแถว)
  for r in
    select t.code,
           sum(v.allocated_debit)  as dr,
           sum(v.allocated_credit) as cr,
           min(v.weight_sum)       as any_weight_sum,
           min(v.allocation_note_th) as note
      from sri_os.v_tag_allocated_totals v
      join sri_os.tags t on t.id = v.tag_id
     where t.code like 'wa-p%'
     group by t.code
  loop
    if r.dr <> r.cr then
      raise exception 'FAIL: W8 — งบต่อ tag % ไม่ดุลเมื่อรวมทุกบัญชี (เดบิต % · เครดิต %) · ถ้าข้อนี้ไม่จริง ตัวเลขกำไรต่อ project ไม่มีความหมาย',
        r.code, r.dr, r.cr;
    end if;
    if r.note is null or btrim(r.note) = '' then
      raise exception 'FAIL: W8 — allocation_note_th ของ % ว่าง → หน้าจอจะแสดงยอดเปลือย (ADR 0002 ข้อ 4 ชั้น 3)', r.code;
    end if;
    if r.note like '%เศษจากการปัด%' then
      raise exception 'FAIL: W8 — allocation_note_th ของ % ยังบอกว่าระบบปัดเศษตอนปันส่วน ซึ่งเป็นกฎของร่างแรกที่ ADR 0003 ข้อ 4.2 ปฏิเสธไปแล้ว · ถ้าประโยคในหน้าจอบอกตรงข้ามกับสิ่งที่ระบบทำ จะมีคนไปเขียนโค้ดปัดเศษตามนั้น', r.code;
    end if;
    if r.any_weight_sum is null then
      raise exception 'FAIL: W8 — weight_sum ของ % เป็น null → คนอ่านไม่เห็นว่าใบถูกแบ่ง', r.code;
    end if;
  end loop;

  -- (ข) ยอดของใบนี้ที่ปันส่วนแล้วรวมทุก project = ยอดในสมุดเป๊ะ
  v_dr := pg_temp.alloc_all(v_t, 'dr');
  v_cr := pg_temp.alloc_all(v_t, 'cr');
  if v_dr <> 1000000 or v_cr <> 1000000 then
    raise exception 'FAIL: W8 — ยอดที่ปันส่วนของใบนี้รวมทุก project ต้องเป็น 1,000,000 ทั้งสองฝั่ง แต่ได้ % / %',
      v_dr, v_cr;
  end if;

  -- (ค) weight_sum ของใบที่ติด tag เดียวทั้งก้อนต้องเป็นจำนวนเต็มสวยๆ
  --     (W6a ลงใบที่ติด wa-p1 ด้วยน้ำหนัก 1.000000 ไว้แล้ว → weight_sum ของ
  --      wa-p1 ต้องมีเศษ 0.6 จากใบที่แบ่ง ไม่ใช่จำนวนเต็ม) — ยืนยันว่าคอลัมน์นี้
  --     บอกความจริงเรื่องการแบ่ง ไม่ใช่ตัวเลขประดับ
  if (select sum(v.weight_sum) from sri_os.v_tag_allocated_totals v
       where v.tag_id = pg_temp.tag('wa-p1')) = 0 then
    raise exception 'FAIL: W8 — weight_sum ของ wa-p1 เป็น 0 → คอลัมน์นี้ไม่ได้บอกอะไรเลย';
  end if;

  -- (ง) ด่านเส้นทางอ่านยังผ่านหลังมีข้อมูลจริงในวิว
  perform sri_os.fn_assert_tag_read_path();

  raise notice 'ok W8 · ชนิดที่ไม่ปันส่วนไม่โผล่ในวิวที่ปันส่วนแล้ว · งบต่อ project ดุลเมื่อรวมทุกบัญชี · ยอดที่ปันส่วนของใบ = ยอดในสมุด · weight_sum + ประโยคกำกับมาจาก DB และไม่พูดถึงกฎปัดเศษที่ ADR ปฏิเสธ';
end $$;

-- ============================================================
-- W9 · **`owner_id` ของ `tag_allocations`** (กฎเหล็กข้อ 3)
--      เป็นสำเนาที่ระบบเติมจากลิงก์ · ส่งมาไม่ตรง = ปฏิเสธ · **ย้ายไม่ได้**
-- ============================================================
do $$
declare
  v_t   uuid := '00000000-0000-0000-0000-0000000ea901';
  v_l1  uuid; v_l2 uuid; v_a1 uuid;
  v_own uuid;
begin
  perform pg_temp.mk(v_t, 800000);
  v_l1 := pg_temp.link(v_t, 'wa-p1');
  v_l2 := pg_temp.link(v_t, 'wa-p2');
  v_a1 := pg_temp.alloc(v_l1, 0.6);
  perform pg_temp.alloc(v_l2, 0.4);
  perform pg_temp.fire();

  -- (ก) ไม่ส่ง owner_id มาเลย → ระบบเติมจากลิงก์ (ซึ่งเติมจากใบ) ให้ตรงกันทั้งสาย
  select a.owner_id into v_own from sri_os.tag_allocations a where a.id = v_a1;
  if v_own is distinct from pg_temp.own('THANAKORN') then
    raise exception 'FAIL: W9a — owner_id ของน้ำหนักต้องเป็นผู้ถือของใบ (%) แต่ได้ % · ถ้าคอลัมน์นี้ไม่ถูกเติมเอง รายงานที่กรอง Entity จะไม่เห็นแถวนี้เลยหรือเห็นผิดคน',
      pg_temp.own('THANAKORN'), v_own;
  end if;
  if exists (select 1 from sri_os.tag_allocations a
               join sri_os.transaction_tags l on l.id = a.transaction_tag_id
              where a.owner_id is distinct from l.owner_id) then
    raise exception 'FAIL: W9a — มีแถวน้ำหนักที่ owner_id ไม่ตรงกับผู้ถือของลิงก์ (สำเนาเพี้ยนจากต้นทาง)';
  end if;

  -- (ข) ส่ง owner_id ที่ **ถูก** มาก็ได้ (ห้ามกันแน่นเกิน)
  --     ติดลิงก์ + ใส่น้ำหนักในคำสั่งเดียว เพื่อไม่ให้มีลิงก์ที่ยังไม่มีน้ำหนักค้างไว้
  perform pg_temp.mk('00000000-0000-0000-0000-0000000ea902'::uuid, 100000);
  perform pg_temp.must_pass('W9b ส่ง owner_id ที่ตรงกับลิงก์', format($q$
    select pg_temp.alloc_own(pg_temp.link(%L, 'wa-p1'), %L, 1.0) $q$,
    '00000000-0000-0000-0000-0000000ea902'::uuid, pg_temp.own('THANAKORN')));

  -- (ค) ส่ง owner_id ของ **ผู้ถืออีกคน** → ปฏิเสธ ไม่ใช่ทับให้เงียบๆ (D-115)
  --     ใช้ลิงก์ที่มีอยู่แล้ว: ด่านของแถว (BEFORE) ยิงก่อน partial unique index
  --     จึงได้ข้อความเรื่องผู้ถือ ไม่ใช่ข้อความเรื่องน้ำหนักซ้อน
  perform pg_temp.must_fail_like('W9c owner_id ไม่ตรงกับลิงก์', format($q$
    select pg_temp.alloc_own(%L, %L, 1.0) $q$, v_l1, pg_temp.own('SUTEE')),
    'ผู้ถือ');

  -- (ง) **ย้ายผู้ถือย้อนหลังไม่ได้** — ย้ายได้ = ย้ายส่วนแบ่งของเงินก้อนหนึ่ง
  --     ไปอยู่กับผู้ถืออีกคนโดยที่ยอดในสมุดไม่เปลี่ยนเลย
  perform pg_temp.must_fail_like('W9d ย้าย owner_id', format($q$
    update sri_os.tag_allocations set owner_id = %L where id = %L $q$,
    pg_temp.own('SUTEE'), v_a1),
    'ย้ายผู้ถือ');
  -- ย้ายพร้อมกับการปิดชุด (ซ่อนมาในคำสั่งเดียว) ก็ไม่ได้
  perform pg_temp.must_fail_like('W9e ย้าย owner_id พร้อมปิดชุด', format($q$
    update sri_os.tag_allocations
       set owner_id = %L, superseded_at = now(), superseded_by = auth.uid(),
           supersede_reason = 'W9e แอบย้ายผู้ถือมาพร้อมการปิด'
     where id = %L $q$, pg_temp.own('SUTEE'), v_a1),
    'ย้ายผู้ถือ');

  -- (ฉ) ผู้ถือเดิมยังอยู่ครบหลังทุกความพยายามข้างบน
  select a.owner_id into v_own from sri_os.tag_allocations a where a.id = v_a1;
  if v_own is distinct from pg_temp.own('THANAKORN') then
    raise exception 'FAIL: W9f — owner_id เปลี่ยนไปได้จริง (ได้ %)', v_own;
  end if;

  raise notice 'ok W9 · owner_id ของน้ำหนักเป็นสำเนาจากลิงก์ที่ระบบเติมเอง · ส่งมาไม่ตรง = ปฏิเสธ · ย้ายไม่ได้ทั้งทางตรงและทางที่ซ่อนมากับการปิดชุด (กฎเหล็กข้อ 3)';
end $$;

-- ============================================================
-- W10 · **รายการข้ามผู้ถือต้องไม่ถูกนับสองขาซ้ำ**
--
--   ประตูติด tag ชุดเดียวกันให้ **ทั้งสองขา** โดยเจตนา (ข้อ 4.2.2 ชั้น 1 — ไม่งั้น
--   ยอดต่อ project ของคู่นั้นไม่สมมาตร) → วิวที่รวมยอดต่อ tag **ต้องพา
--   `counter_owner_id` และ `is_intercompany` มาด้วย** ไม่งั้นรายงานที่บวกข้าม
--   ผู้ถือจะนับเงินก้อนเดียวสองครั้ง **โดยที่ทุกใบดุลและ Σ น้ำหนัก = 1 พอดี**
--   จึงไม่มีด่านไหนจับได้ (= กำไรที่ไม่จริงแบบเดียวกับที่ฟีเจอร์นี้มาแก้)
-- ============================================================
do $$
declare
  v_ids   uuid[];
  v_all   numeric;
  v_net   numeric;
  v_mine  numeric;
  n       int;
begin
  v_ids := pg_temp.pair('W10', 200000,
             jsonb_build_object(pg_temp.tag('wa-ic')::text, 1.0));
  if array_length(v_ids, 1) <> 2 then
    raise exception 'FAIL: W10 — ฉากต้องเป็นใบข้ามผู้ถือสองใบคู่กัน แต่ได้ % ใบ', array_length(v_ids, 1);
  end if;

  -- (ก) วิวต้องพาสองช่องนั้นมาจริง (ไม่ใช่ให้คนอ่านไป join เอง)
  select count(*) into n
    from (values ('counter_owner_id'), ('is_intercompany')) x(col)
   where not exists (select 1 from information_schema.columns c
                      where c.table_schema = 'sri_os'
                        and c.table_name = 'v_tag_allocated_totals'
                        and c.column_name = x.col);
  if n > 0 then
    raise exception 'FAIL: W10a — v_tag_allocated_totals ไม่มี counter_owner_id/is_intercompany (ขาด % ช่อง) · v_ledger_allocated มี counter_owner_id อยู่แล้ว แต่วิวยอดรวมไม่มี → รายงาน "กำไรต่อ project" ที่บวกข้ามผู้ถือจะนับสองขาซ้ำโดยไม่มีใครรู้', n;
  end if;

  -- (ข) ทุกแถวของคู่นี้ต้องถูกธงว่าเป็นรายการข้ามผู้ถือ และมีคู่สัญญาติดมา
  select count(*) into n
    from sri_os.v_tag_allocated_totals v
   where v.tag_id = pg_temp.tag('wa-ic')
     and (not v.is_intercompany or v.counter_owner_id is null);
  if n > 0 then
    raise exception 'FAIL: W10b — มี % แถวของ wa-ic ที่ไม่ได้ถูกธงว่าข้ามผู้ถือหรือไม่มีคู่สัญญา → แยกขาคู่ออกจากรายการธรรมดาไม่ได้', n;
  end if;

  -- (ค) **ตัวเลขของเรื่องนี้**: เงินที่เคลื่อนจริง 200,000
  --     บวกทุกแถวแบบไม่ดูธง  → 400,000 (**สองเท่า** = กำไรที่ไม่จริง)
  --     ตัดขาคู่ออกตาม Money Invariant ข้อ 6 → 0 (การย้ายเงินในบ้านไม่ใช่ผลงานของ project)
  --     กรองผู้ถือรายคน → 200,000 (ขาของตัวเองต้องเห็นครบ วิวห้ามตัดให้เอง)
  select coalesce(sum(v.allocated_debit), 0) into v_all
    from sri_os.v_tag_allocated_totals v where v.tag_id = pg_temp.tag('wa-ic');
  select coalesce(sum(v.allocated_debit), 0) into v_net
    from sri_os.v_tag_allocated_totals v
   where v.tag_id = pg_temp.tag('wa-ic') and not v.is_intercompany;
  select coalesce(sum(v.allocated_debit), 0) into v_mine
    from sri_os.v_tag_allocated_totals v
   where v.tag_id = pg_temp.tag('wa-ic') and v.owner_id = pg_temp.own('THANAKORN');

  if v_all <> 400000 then
    raise exception 'FAIL: W10c — ฉากไม่ใช่ฉากเดิม: บวกทุกแถวต้องได้ 400,000 (สองขา × 200,000) แต่ได้ % · ถ้าตัวเลขนี้ไม่ใช่ 400,000 แปลว่าประตูไม่ได้ลง tag ให้ทั้งสองขา แล้วเทสต์นี้ไม่ได้วัดการนับซ้ำเลย',
      v_all;
  end if;
  if v_net <> 0 then
    raise exception 'FAIL: W10c — ตัดขาคู่ด้วย is_intercompany แล้วยอดต่อ project ต้องเป็น 0 (การย้ายเงินข้ามกระเป๋าในบ้านไม่ใช่ผลงานของ project · Money Invariant ข้อ 6) แต่ได้ %',
      v_net;
  end if;
  if v_mine <> 200000 then
    raise exception 'FAIL: W10c — กรองผู้ถือรายคนต้องเห็นขาของตัวเองเต็ม 200,000 แต่ได้ % · วิวห้ามตัด intercompany ให้เอง (ยอดต่อผู้ถือรายคนต้องตรงกับสมุดของคนนั้น) ต้องให้ช่องที่ตัดสินได้มาเสมอ',
      v_mine;
  end if;
  if v_net = v_all or v_mine = v_all then
    raise exception 'FAIL: W10c — ยอดที่ตัดขาคู่แล้วเท่ากับยอดที่ไม่ตัด (%) → ไม่มีอะไรกันการนับสองเท่าเลย', v_all;
  end if;

  raise notice 'ok W10 · วิวยอดรวมพา counter_owner_id/is_intercompany มาด้วย · บวกไม่ดูธง = 400,000 (สองเท่าของเงินจริง) · ตัดขาคู่ = 0 · ต่อผู้ถือรายคน = 200,000 ครบตามสมุด';
end $$;

-- ============================================================
-- M4 · MUTATION — **ปิดการกันการนับซ้ำ** (= รายงานที่ไม่ดูสองช่องนั้น ซึ่งเป็น
--      สิ่งที่เกิดขึ้นเองถ้าวิวไม่พามันมา) แล้ว **วัดได้** ว่ายอดต่อ project
--      โป่งเป็น **สองเท่า** ของเงินที่เคลื่อนจริง
--      ถ้าปิดแล้วตัวเลขไม่โป่ง แปลว่า W10 เขียวเพราะอย่างอื่น ไม่ใช่เพราะสองช่องนี้
-- ============================================================
savepoint before_ic_mutation;
do $$
declare
  v_ids    uuid[];
  v_moved  numeric;
  v_blind  numeric;
  v_guard  numeric;
begin
  -- ใช้ tag ของตัวเอง (wa-ic2) เพื่อให้ยอดที่วัดมีแต่ของฉากนี้ ไม่ปนกับ W10
  v_ids := pg_temp.pair('M4', 350000,
             jsonb_build_object(pg_temp.tag('wa-ic2')::text, 1.0));

  -- เงินที่เคลื่อนจริง = ยอดของ **ขาเดียว** (อีกขาคือด้านตรงข้ามของเงินก้อนเดิม)
  v_moved := pg_temp.book(v_ids[1], 'dr');

  -- **ปิดการกัน** = รายงานที่บวกยอดต่อ tag โดยไม่ดู is_intercompany/counter_owner_id
  --   ซึ่งเป็นสิ่งที่เกิดขึ้น **เอง** ถ้าวิวไม่พาสองช่องนั้นมา (ตัดไม่ได้เพราะไม่มีช่องให้ตัด)
  select coalesce(sum(v.allocated_debit), 0) into v_blind
    from sri_os.v_tag_allocated_totals v
   where v.tag_id = pg_temp.tag('wa-ic2');
  if v_blind <> v_moved * 2 then
    raise exception 'FAIL: M4 — ปิดการกันแล้วยอดต่อ project ต้องเป็นสองเท่าของเงินที่เคลื่อนจริง (% vs %)',
      v_blind, v_moved;
  end if;

  -- **เปิดการกัน**: ใช้สองช่องที่วิวพามาให้ → ตัดขาคู่ออกได้
  select coalesce(sum(v.allocated_debit), 0) into v_guard
    from sri_os.v_tag_allocated_totals v
   where v.tag_id = pg_temp.tag('wa-ic2') and not v.is_intercompany;
  if v_guard <> 0 then
    raise exception 'FAIL: M4 — เปิดการกันแล้วต้องตัดขาคู่ออกได้หมด (ได้ %)', v_guard;
  end if;

  raise notice 'ok M4 · ปิดการกัน = ยอดต่อ project โป่งเป็นสองเท่าของเงินจริงทันที (% → %)',
    v_moved, v_blind;
end $$;
rollback to savepoint before_ic_mutation;

-- ============================================================
-- W11 · **tag ที่ถูกปิดหลังมีใบติดไปแล้ว**
--       ติดใหม่ห้าม · **แก้สัดส่วนของใบที่ติดอยู่แล้วได้**
--       (ถ้าแก้ไม่ได้ ใบนั้นติดค้างถาวรพร้อมสัดส่วนที่รู้อยู่ว่าผิด — และถอด tag
--        ก็ยังไม่มีประตู · เปิดฟีเจอร์ครึ่งเดียวอันตรายกว่าไม่เปิด)
-- ============================================================
do $$
declare
  v_t   uuid := '00000000-0000-0000-0000-0000000eb101';
  v_t2  uuid := '00000000-0000-0000-0000-0000000eb102';
  v_res jsonb;
  v_w   numeric;
begin
  perform pg_temp.mk(v_t, 1000000);
  perform pg_temp.weigh(v_t, 'wa-shut', 0.6);
  perform pg_temp.weigh(v_t, 'wa-p1',  0.4);
  perform pg_temp.fire();

  -- ปิด tag **หลังจาก** ใบติดไปแล้ว (เกิดขึ้นจริงได้ทุกเมื่อที่หน้าตั้งค่า)
  update sri_os.tags set is_active = false, archived_at = now(), archived_by = auth.uid()
   where code = 'wa-shut';

  -- (ก) **แก้สัดส่วนของใบเดิมได้** แม้ tag ถูกปิดแล้ว
  v_res := sri_os.fn_reallocate_tags(v_t, 'project',
             jsonb_build_object(pg_temp.tag('wa-shut')::text, 0.25,
                                pg_temp.tag('wa-p1')::text,  0.75),
             'W11 ลูกพี่สั่งแก้สัดส่วนของใบเดิม ทั้งที่ project นี้ปิดรับงานใหม่แล้ว');
  perform pg_temp.fire();
  select a.weight into v_w
    from sri_os.tag_allocations a
    join sri_os.transaction_tags l on l.id = a.transaction_tag_id
   where l.transaction_id = v_t and l.tag_id = pg_temp.tag('wa-shut')
     and a.superseded_at is null;
  if v_w is distinct from 0.250000 then
    raise exception 'FAIL: W11a — แก้สัดส่วนของใบที่ติด tag ซึ่งถูกปิดแล้วไม่ได้ (น้ำหนักที่ใช้อยู่ = %) · ถ้าแก้ไม่ได้ ใบนั้นติดค้างถาวรพร้อมสัดส่วนที่รู้อยู่ว่าผิด และถอด tag ก็ยังไม่มีประตู (บทเรียน mace-windu ข้อ 7)',
      v_w;
  end if;
  if pg_temp.alloc_all(v_t, 'dr') <> pg_temp.book(v_t, 'dr') then
    raise exception 'FAIL: W11a — หลังแก้สัดส่วน Σ ที่ปันส่วนไม่ตรงสมุด (% vs %)',
      pg_temp.alloc_all(v_t, 'dr'), pg_temp.book(v_t, 'dr');
  end if;

  -- (ข) แต่ **ติด tag ที่ปิดแล้วให้ใบใหม่ไม่ได้** (เส้นแบ่งอยู่ที่นี่)
  perform pg_temp.mk(v_t2, 1000000);
  perform pg_temp.must_fail_like('W11b ติด tag ที่ปิดแล้วให้ใบใหม่', format($q$
    select pg_temp.weigh(%L, 'wa-shut', 1.0) $q$, v_t2),
    'ปิดใช้งาน');

  -- (ค) และผ่านประตูก็ติดใหม่ไม่ได้เหมือนกัน (ประตูเขียนลิงก์ก่อนน้ำหนักเสมอ)
  perform pg_temp.must_fail_like('W11c ประตู + tag ที่ปิดแล้ว', format($q$
    select pg_temp.post(pg_temp.entry('W11c', 1000, jsonb_build_object(%L, 1.0))) $q$,
    pg_temp.tag('wa-shut')::text),
    'tag');

  raise notice 'ok W11 · tag ที่ปิดแล้ว: แก้สัดส่วนของใบที่ติดอยู่แล้วได้ (ไม่ติดค้างถาวร) · ติดให้ใบใหม่ไม่ได้ทั้งทางตรงและทางประตู';
end $$;

-- ============================================================
-- W12 · **ชนิด tag ที่ประตูรับได้จริงวันนี้** — ฝั่งแอปใช้ปิดช่องที่กดแล้วตาย
--       กติกาฝั่งแอปคือ "อ่านไม่ได้ = ซ่อน" → ฟังก์ชันนี้ต้องมีและต้องตอบจากของจริง
-- ============================================================
do $$
declare v_kinds text[];
begin
  if to_regprocedure('sri_os.fn_post_entry_accepted_tag_kinds()') is null then
    raise exception 'FAIL: W12 — ไม่มี sri_os.fn_post_entry_accepted_tag_kinds() → ฟอร์มจะซ่อน tag ทุกชนิด รวม project ที่ประตูรับอยู่แล้ว';
  end if;
  v_kinds := sri_os.fn_post_entry_accepted_tag_kinds();

  if not ('project' = any (v_kinds)) then
    raise exception 'FAIL: W12a — ต้องคืน "project" (ประตูรับช่อง tag_weights แล้ว) แต่ได้ %',
      array_to_string(v_kinds, ', ');
  end if;
  -- **สภาพวันนี้ (28/10)**: ADR 0002 ชิ้น 3 ยังไม่ลง → ประตูยังไม่มีช่อง tag_ids
  --   ถ้าข้อนี้แดงเพราะคืน 'label' ด้วย แปลว่าชิ้น 3 ลงแล้ว → **แก้เทสต์ข้อนี้
  --   ไม่ใช่แก้ฟังก์ชัน** (ฟังก์ชันอ่านช่องจริงของประตู ไม่ได้เขียนรายชื่อตายตัว)
  if 'label' = any (v_kinds) then
    raise exception 'FAIL: W12b — คืน "label" ทั้งที่ c_header ของประตูยังไม่มีช่อง tag_ids → ฟอร์มจะโชว์ช่องที่กดบันทึกแล้วเด้ง "ช่องที่ยังไม่รู้จัก" (ถ้าชิ้น 3 ของ ADR 0002 ลงแล้วจริง ให้แก้เทสต์ข้อนี้)';
  end if;

  -- ต้องตัดสินจาก **ของจริง** ไม่ใช่รายชื่อตายตัว และต้องใช้ตัวไล่ตัวเดียวของระบบ
  -- (ตัวไล่สองตัว = วันหนึ่งคนแก้ตัวเดียว · M5 พิสูจน์ว่าตัวไล่อ่านของจริงจริง)
  if pg_get_functiondef('sri_os.fn_post_entry_accepted_tag_kinds()'::regprocedure)
     !~ '\mfn_post_entry_header_fields\M' then
    raise exception 'FAIL: W12c — ฟังก์ชันไม่ได้ถาม fn_post_entry_header_fields → ไล่ c_header เองหรือเป็นรายชื่อตายตัวที่จะค้างล้าสมัยเงียบๆ (วันที่ประตูรับ tag_ids ฟอร์มจะยังซ่อน label ตลอดกาล)';
  end if;
  if pg_get_functiondef('sri_os.fn_post_entry_header_fields()'::regprocedure)
     !~ '\mc_header\M' then
    raise exception 'FAIL: W12c — fn_post_entry_header_fields ไม่ได้อ่าน c_header ของ fn_post_entry';
  end if;
  -- ช่องของ **บรรทัด** ต้องไม่ปนมาเป็นช่องของ **หัวใบ** (รุ่นแรกกินถึง c_line)
  if 'fx_rate'  = any (sri_os.fn_post_entry_header_fields())
     or 'coa_code' = any (sri_os.fn_post_entry_header_fields()) then
    raise exception 'FAIL: W12e — ตัวไล่ c_header กินเลยไปถึง c_line (เจอ fx_rate / coa_code) → คำตอบเรื่อง "ประตูรับช่องไหน" เชื่อไม่ได้ทั้งหมด';
  end if;
  if not has_function_privilege('authenticated',
        'sri_os.fn_post_entry_accepted_tag_kinds()', 'execute') then
    raise exception 'FAIL: W12d — authenticated เรียกไม่ได้ → ฟอร์มซ่อนทุกชนิด';
  end if;
  if has_function_privilege('anon', 'sri_os.fn_post_entry_accepted_tag_kinds()', 'execute') then
    raise exception 'FAIL: W12d — เปิดให้ anon';
  end if;

  raise notice 'ok W12 · fn_post_entry_accepted_tag_kinds คืน {project} จากการไล่ c_header ของประตูจริง · ยังไม่คืน label เพราะประตูยังไม่มีช่อง tag_ids · authenticated เรียกได้ anon ไม่ได้';
end $$;

-- ============================================================
-- M5 · MUTATION — **ตัวไล่ `c_header` ต้องอ่านของจริง ไม่ใช่คอมเมนต์หรือ `c_line`**
--
--   W12 เขียวได้ด้วยเหตุผลผิดหลายแบบ: ตัวไล่ที่กินยาวถึง `c_line` ก็ตอบ
--   `{project}` ถูก · ตัวไล่ที่เชื่อคอมเมนต์ก็ตอบถูก · แม้แต่รายชื่อตายตัวก็ตอบถูก
--   → ข้อนี้ **ขยับ `c_header` ของประตูจริง** แล้ววัดว่าคำตอบ **พลิก**
--
--     M5a เติมช่องปลอม `'tag_ids'` เข้า c_header → ต้องเริ่มคืน `label`
--     M5b ถอดช่องจริง `'tag_weights'` ออก (เหลือแต่ในคอมเมนต์และใน c_line)
--         → ต้อง **เลิก** คืน `project`  (ถ้ายังคืน = ตอบถูกเพราะคอมเมนต์/c_line)
--     M5c ชื่อช่องอยู่ **ในคอมเมนต์เท่านั้น** (ทั้ง `--` และ `/* */`) → ต้องไม่นับ
--     M5d อ่าน c_header ไม่ออก → ต้อง **พัง** ไม่ใช่คืนชุดว่าง
--     M5e ไล่ได้ผลที่ขาดช่องพื้นฐานของประตู → ต้องพัง (ด่านกันตัวเองตาย D-096)
--
--   ประตูตัวปลอมเป็น stub (`return p_payload`) เพราะข้อนี้วัด **ตัวไล่** ไม่ใช่ประตู
--   ทั้งก้อนอยู่ใน savepoint → ประตูตัวจริงกลับมาครบ (ตรวจที่ M5z)
-- ============================================================
create or replace function pg_temp.stub_gate(p_decl text) returns void
language plpgsql as $fn$
begin
  execute format($m$
    create or replace function sri_os.fn_post_entry(p_payload jsonb) returns jsonb
    language plpgsql set search_path = %L as $stub$
    declare
      %s
    begin
      return p_payload;
    end $stub$
  $m$, '', p_decl);
end $fn$;

savepoint before_header_mutation;
do $$
declare v_kinds text[];
begin
  -- ---------- M5a · เติมช่องปลอม → คำตอบต้องพลิกเป็น "รับ label แล้ว" ----------
  perform pg_temp.stub_gate($d$
    c_header constant text[] := array['txn_type_code', 'tag_weights',
                                      'tag_ids', 'transactions'];
    c_line   constant text[] := array['coa_code', 'fx_rate'];
  $d$);
  v_kinds := sri_os.fn_post_entry_accepted_tag_kinds();
  if not ('label' = any (v_kinds)) then
    raise exception 'FAIL: M5a — เติม ''tag_ids'' เข้า c_header ของประตูแล้ว คำตอบต้องพลิกเป็นรับ label ด้วย แต่ได้ % · แปลว่าตัวไล่ไม่ได้อ่าน c_header ของจริง (รายชื่อตายตัว/ธง requires_allocation เพียวๆ) → วันที่ชิ้น 3 ของ ADR 0002 ลง ฟอร์มจะซ่อน label ตลอดกาลโดยไม่มีใครรู้',
      array_to_string(v_kinds, ', ');
  end if;
  if not ('project' = any (v_kinds)) then
    raise exception 'FAIL: M5a — ฉากนี้ยังมี ''tag_weights'' อยู่ ต้องคืน project ด้วย (ได้ %)',
      array_to_string(v_kinds, ', ');
  end if;

  -- ---------- M5b · ถอดช่องจริงออก เหลือแต่ในคอมเมนต์และใน c_line ----------
  perform pg_temp.stub_gate($d$
    -- ไฟล์ที่ลง tag_ids ต้องคง 'tag_weights' ไว้ (ประโยคนี้คือ **คอมเมนต์**)
    c_header constant text[] := array['txn_type_code', 'transactions'];
    c_line   constant text[] := array['coa_code', 'tag_weights', 'fx_rate'];
  $d$);
  v_kinds := sri_os.fn_post_entry_accepted_tag_kinds();
  if 'project' = any (v_kinds) then
    raise exception 'FAIL: M5b — ถอดช่อง ''tag_weights'' ออกจาก c_header แล้ว ยังตอบว่ารับ project (ได้ %) · คำตอบมาจาก **คอมเมนต์หรือ c_line** ไม่ใช่จากของจริง → ด่านที่ตอบถูกเพราะคอมเมนต์ ไม่ใช่เพราะของจริง',
      array_to_string(v_kinds, ', ');
  end if;

  -- ---------- M5c · ชื่อช่องอยู่ในคอมเมนต์เท่านั้น → ห้ามนับ ----------
  perform pg_temp.stub_gate($d$
    -- ช่องที่ยังไม่มี: 'tag_ids' (ADR 0002 ชิ้น 3 ยังไม่ลง)
    c_header constant text[] := array[
      'txn_type_code',
      /* บล็อกคอมเมนต์ที่เอ่ย 'tag_ids' เหมือนกัน */
      'tag_weights', 'transactions'];
    c_line   constant text[] := array['coa_code', 'tag_ids', 'fx_rate'];
  $d$);
  v_kinds := sri_os.fn_post_entry_accepted_tag_kinds();
  if 'label' = any (v_kinds) then
    raise exception 'FAIL: M5c — ''tag_ids'' อยู่ใน **คอมเมนต์** (และใน c_line) เท่านั้น แต่ตอบว่ารับ label แล้ว (ได้ %) · ฟอร์มจะโชว์ชนิดที่กดบันทึกแล้วเด้ง "ช่องที่ยังไม่รู้จัก" = ช่องเดิมที่เพิ่งปิดไปกลับมา',
      array_to_string(v_kinds, ', ');
  end if;
  if not ('project' = any (v_kinds)) then
    raise exception 'FAIL: M5c — ฉากนี้มี ''tag_weights'' จริงใน c_header ต้องคืน project (ได้ %)',
      array_to_string(v_kinds, ', ');
  end if;

  -- ---------- M5d · อ่าน c_header ไม่ออก → พัง ไม่ใช่คืนชุดว่าง ----------
  perform pg_temp.stub_gate($d$
    c_hdr constant text[] := array['txn_type_code', 'tag_weights', 'transactions'];
  $d$);
  perform pg_temp.must_fail_like('M5d อ่าน c_header ไม่ออก',
    'select sri_os.fn_post_entry_accepted_tag_kinds()', 'c_header');

  -- ---------- M5e · ด่านกันตัวเองตาย (D-096) ----------
  perform pg_temp.stub_gate($d$
    c_header constant text[] := array['tag_weights'];
  $d$);
  perform pg_temp.must_fail_like('M5e ไล่ได้ผลที่ขาดช่องพื้นฐาน',
    'select sri_os.fn_post_entry_header_fields()', 'txn_type_code');

  raise notice 'ok M5 · ตัวไล่ c_header อ่าน **ของจริง**: เติมช่องปลอม = คำตอบพลิก · ถอดช่องจริง = พลิกกลับ · ชื่อช่องในคอมเมนต์/ใน c_line ไม่นับ · อ่านไม่ออกหรือไล่ได้ผลครึ่งเดียว = พัง ไม่ใช่คืนชุดว่าง';
end $$;

-- ============================================================
-- M6 · MUTATION — **ด่าน "ห้ามเปิด `tag_ids` ก่อนปิด A8" ต้องดังวันที่ควรดัง**
--      (ADR 0003 ข้อ 7.1) · เดิมอยู่ใน migration ซึ่ง **รันก่อนไฟล์อนาคตเสมอ**
--      จึงไม่ดังเลยวันที่ใครลง migration เปิด `tag_ids` · ย้ายมาอยู่ใน
--      `fn_assert_tag_read_path()` ที่เทสต์เรียกสดกับสคีมาสุดท้าย
-- ============================================================
do $$
begin
  -- ฉากของ "วันที่ชิ้น 3 ของ ADR 0002 ลงแต่ A8 ยังไม่ปิด"
  perform pg_temp.stub_gate($d$
    c_header constant text[] := array['txn_type_code', 'tag_weights',
                                      'tag_ids', 'transactions'];
  $d$);
  if exists (select 1 from information_schema.columns c
              where c.table_schema = 'sri_os'
                and c.table_name like 'draft\_entry\_tag%'
                and c.column_name like '%weight%') then
    raise notice 'skip M6 · เส้นทางร่างมีช่องน้ำหนักแล้ว (A8 ปิดแล้ว) → ฉากนี้ไม่มีอยู่จริงอีก';
  else
    perform pg_temp.must_fail_like('M6 เปิด tag_ids ขณะ A8 ยังไม่ปิด',
      'select sri_os.fn_assert_tag_read_path()', 'A8');
    raise notice 'ok M6 · ประตูรับ tag_ids ขณะเส้นทางร่างยังไม่มีช่องน้ำหนัก = fn_assert_tag_read_path พังทันที (ร่างที่ติด project จะคีย์ได้แต่อนุมัติไม่ได้ · ADR 0003 ข้อ 7.1)';
  end if;
end $$;

rollback to savepoint before_header_mutation;

-- ============================================================
-- M5z · ประตูตัวจริงกลับมาครบหลัง rollback (ไม่ใช่ stub ค้างอยู่)
-- ============================================================
do $$
declare v_fields text[];
begin
  v_fields := sri_os.fn_post_entry_header_fields();
  -- ช่องของ FCD/WHT ต้องยังอยู่ → ที่กลับมาคือประตูตัวจริง ไม่ใช่ stub
  if not ('wht_rate' = any (v_fields)) or not ('tag_weights' = any (v_fields)) then
    raise exception 'FAIL: M5z — ประตูตัวจริงไม่กลับมาหลัง rollback (ช่องที่ไล่ได้: %)',
      array_to_string(v_fields, ', ');
  end if;
  if 'tag_ids' = any (v_fields) then
    raise exception 'FAIL: M5z — stub ของ mutation ยังค้างอยู่ (c_header ยังมี tag_ids)';
  end if;
  perform sri_os.fn_assert_tag_read_path();
  raise notice 'ok M5z · ประตูตัวจริงกลับมาครบ (wht_rate + tag_weights ยังอยู่ · ไม่มี tag_ids) และด่านเส้นทางอ่าน tag ผ่านตามปกติ';
end $$;

-- ============================================================
-- M7 · MUTATION — **ผู้บริโภคของยอดที่ปันส่วนแล้วต้องแตะธงขาคู่**
--      ธงมีมาตั้งแต่ (T10) แต่ **ไม่มีใครใช้** = ยอดโป่งเหมือนไม่มีธง
--      ข้อนี้พิสูจน์ว่าด่านดังวันที่มีคนเพิ่มผู้บริโภคตัวแรกที่ลืมกรอง
-- ============================================================
savepoint before_consumer_mutation;
do $$
begin
  -- (ก) รายงานที่บวกข้ามผู้ถือโดยไม่ดูธงเลย → ด่านต้องพัง
  create view sri_os.v_wa_profit_by_project as
    select tag_id, sum(allocated_debit) as dr, sum(allocated_credit) as cr
      from sri_os.v_tag_allocated_totals
     group by tag_id;
  perform pg_temp.must_fail_like('M7a ผู้บริโภคที่ไม่แตะธงขาคู่',
    'select sri_os.fn_assert_tag_read_path()', 'ขาคู่');
end $$;
rollback to savepoint before_consumer_mutation;

savepoint before_consumer_ok;
do $$
begin
  -- (ข) รายงานเดียวกันที่ตัดขาคู่ออก → ด่านต้องปล่อยผ่าน (ไม่กันแน่นเกิน)
  create view sri_os.v_wa_profit_by_project as
    select tag_id, sum(allocated_debit) as dr, sum(allocated_credit) as cr
      from sri_os.v_tag_allocated_totals
     where not is_intercompany
     group by tag_id;
  perform sri_os.fn_assert_tag_read_path();
  raise notice 'ok M7 · ผู้บริโภคที่ไม่แตะ is_intercompany/counter_owner_id = ด่านพัง · ตัวที่ตัดขาคู่แล้ว = ผ่าน (ด่านบังคับให้ตัดสินใจ ไม่ได้บังคับคำตอบ)';
end $$;
rollback to savepoint before_consumer_ok;

do $$
begin
  if to_regclass('sri_os.v_wa_profit_by_project') is not null then
    raise exception 'FAIL: M7b — วิวของ mutation ยังค้างอยู่ในสคีมา';
  end if;
  perform sri_os.fn_assert_tag_read_path();
  raise notice 'ok M7b · วิวของ mutation ไม่ค้าง และด่านกลับมาเขียวตามปกติ';
end $$;

rollback;
