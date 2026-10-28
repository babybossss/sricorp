-- ============================================================
-- SRI OS · **วิวที่ปันส่วนแล้ว** — ADR 0003 ข้อ 4.2 · 4.2.1 · 5 (ชิ้น A3)
--
--   `v_ledger_allocated`      — สมุดระดับบรรทัด × น้ำหนักของ tag
--   `v_tag_allocated_totals`  — ยอดรวมต่อ tag ที่ **บวกข้าม tag ได้**
--   `fn_assert_tag_read_path()` — ด่านชั้น DB ของ ADR 0002 ข้อ 4 ชั้น 4
--                                 ขยายให้ครอบวิวที่ปันส่วนแล้ว (ADR 0003 ข้อ 5)
--
-- ------------------------------------------------------------
-- **กติกาที่ห้ามละเมิดเด็ดขาด (ADR 0003 ข้อ 4.2)**
--
--     allocated_debit  = debit  * weight      -- **ไม่ปัด**
--     allocated_credit = credit * weight      -- **ไม่ปัด**
--
--   `numeric` ของ Postgres เป็น **ทศนิยมแม่นตรง ไม่ใช่ floating point** จึงได้
--   สองข้อนี้ **เป๊ะทางคณิตศาสตร์** ไม่ใช่ "ใกล้เคียงพอ" — ไม่ต้องมี tolerance ที่ไหนเลย:
--     1. ผลรวมข้าม tag = ยอดในสมุด   Σᵢ(amount × wᵢ) = amount × Σwᵢ = amount × 1
--        (ด่าน Σ = 1 ของชิ้น A2 เป็นคนรับประกันว่า Σw = 1 พอดี)
--     2. งบของแต่ละ tag ยังดุล        Σ(dᵢ × w) = w × Σdᵢ = w × Σcⱼ = Σ(cⱼ × w)
--        เพราะคูณ **น้ำหนักตัวเดียวกันทุกบรรทัดของใบนั้น**
--   ข้อ 2 คือเหตุผลที่ ADR 0003 เปิดรายงาน "กำไรต่อ project" ได้ ซึ่ง ADR 0002
--   ข้อ 4.4 สั่งห้ามเปิดไว้
--
--   **ทางที่ ADR ปฏิเสธและห้ามเอากลับมา**: ปัดรายบรรทัดแล้วให้แถวสุดท้ายรับเศษ
--   มันรักษาข้อ 1 ได้จริง **แต่ทำลายข้อ 2 แบบเงียบๆ** · ตัวอย่างค้าน (รันจริงแล้ว)
--   ใบที่เดบิต 0.05 + 0.05 เครดิต 0.10 แบ่ง A/B อย่างละ 50%:
--       ปัดรายบรรทัด → A 0.06/0.05 (**ไม่ดุล**) · B 0.04/0.05 (**ไม่ดุล**)
--       ไม่ปัด        → A 0.050/0.050 (ดุล)    · B 0.050/0.050 (ดุล)
--   สาเหตุ: การปัดเกิด **ต่อบรรทัด** ซึ่งสองฝั่งมีจำนวนบรรทัดและยอดต่อบรรทัด
--   ไม่เท่ากัน เศษจึงตกคนละขนาด · ผลรวมข้าม tag ยังตรงสมุด (0.06+0.04 = 0.10)
--   **จึงไม่มีด่านไหนจับได้** แล้วงบต่อ project จะไม่ดุลโดยไม่มีใครรู้ว่าทำไม
--   (เทสต์ W4 ของ `zz_tag_allocation_test.sql` ตรึงเคสนี้ไว้)
--
--   **scale**: ยอด `numeric(18,2)` × น้ำหนัก `numeric(9,6)` ได้ scale 8 →
--   วิวต้องปล่อยให้เป็น `numeric` ไม่ระบุ scale · **ห้าม cast กลับเป็น (18,2)**
--   (cast = ปัด = พังทั้งสองข้อข้างบน) · ข้อ 4.2.1 สั่งให้มี **guard ที่ไล่นิยาม
--   ของวิวจริงใน catalog** ไม่ใช่พึ่งความจำของคนที่แก้ครั้งถัดไป → อยู่ใน
--   `fn_assert_tag_read_path()` ข้อ (T5)
--
--   **ปัดที่ไหน**: เฉพาะตัวเลขก้อนสุดท้ายที่คนอ่าน หลังรวมเสร็จแล้ว และตามข้อ
--   4.2.1 ต้องเป็น **ฟังก์ชันตัวเดียวที่ทุกหน้าเรียก** (ชั้น UI · ไม่ใช่ของไฟล์นี้)
--
-- ------------------------------------------------------------
-- **touch กับ allocated ห้ามปนกัน** (ADR 0003 ข้อ 5)
--
--   | ชนิด | requires_allocation | วิว | บวกข้าม tag |
--   |---|---|---|---|
--   | `project` | true  | `v_ledger_allocated` · `v_tag_allocated_totals` | **ได้** |
--   | `label`   | false | `v_ledger_tagged` · `v_tag_touch_totals` (ADR 0002) | **ไม่ได้** |
--
--   `v_ledger_allocated` กรองด้วย `tag_kinds.requires_allocation` (คอนฟิก ไม่ใช่
--   ชื่อ `'project'` ที่พิมพ์ในโค้ด · กฎเหล็กข้อ 5) → ชนิดที่ไม่ปันส่วนเข้ามาไม่ได้
--   เชิงโครงสร้าง และน้ำหนักก็ติดให้ชนิดนั้นไม่ได้อยู่แล้ว (ด่านของชิ้น A2)
--
-- ------------------------------------------------------------
-- **หมายเหตุสำคัญเรื่องลำดับงาน (อ่านก่อนแก้ไฟล์นี้)**
--
--   ชิ้น 3 ของ ADR 0002 (`v_ledger_tagged` · `v_tag_touch_totals` ·
--   `v_tag_coverage` · `fn_tag_transaction` · `tag_ids` ในประตู) **ยังไม่ได้ลง**
--   ณ 28/10 · ไฟล์นี้จึงเป็นคนสร้าง `fn_assert_tag_read_path()` ขึ้นมาเอง และ
--   เขียนให้ **ทนต่อการที่วิวของ ADR 0002 ยังไม่มี**: ข้อที่เกี่ยวกับ touch
--   จะตรวจเฉพาะเมื่อวิวนั้นมีจริง (ไล่จาก catalog ไม่ใช่เดา)
--
--   เมื่อชิ้น 3 ของ ADR 0002 มาลง **ต้อง `create or replace` ฟังก์ชันนี้แบบ
--   "เพิ่มข้อ" ไม่ใช่ "เขียนทับ"** — ถ้าเขียนทับด้วยเวอร์ชันที่รู้จักแต่ touch
--   ด่านของ allocated จะหายไปเงียบๆ ทั้งก้อน · guard ท้ายไฟล์นี้ตรวจว่าฟังก์ชัน
--   ยังพูดถึง `v_tag_allocated_totals` อยู่ เพื่อให้การเขียนทับแบบนั้นพังเสียงดัง
--   ตอนรัน migration ถัดไปของชิ้นนี้ ไม่ใช่เงียบ
--
-- ------------------------------------------------------------
-- ลำดับ: หลัง 20261020000001 (`v_ledger_posted`) · หลัง 20261027000002 (ลิงก์) ·
--        **หลัง 20261028000001** (`tag_allocations`)
--        ลงทะเบียนใน `supabase/migration-order.txt` และ UNDER_TEST ของ
--        `scripts/test-rls-local.sh` ต่อท้าย 20261028000001
--
-- idempotent: `create or replace view` · `create or replace function` ·
--   `update` คอนฟิกแบบมีเงื่อนไข · รันซ้ำได้ผลเดิม
--   **ไฟล์นี้ไม่มีคำสั่งถอนของ และห้ามมีคำนั้นแม้ในคอมเมนต์** (ตัวตรวจของ MCP
--   `apply_migration` อ่านจากข้อความดิบแล้ว timeout ทุกครั้ง · ดู CLAUDE.md)
--
-- ย้อนกลับ (rollback):
--   -- ถอนสองวิว + ฟังก์ชันด่าน ต้องทำใน migration ใหม่ (ไฟล์นี้เขียนคำสั่งถอนไม่ได้)
--   ⚠ ถอนแล้ว **ยอดต่อ project จะไม่มีทางอ่านที่ถูกเหลืออยู่เลย** → หน้าจอจะกลับไป
--     ใช้ยอด touch ซึ่งบวกข้าม tag ไม่ได้ · ถ้าหน้าไหนยังบวกอยู่ ตัวเลขจะเกินจริง
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 0 · pre-flight
-- ============================================================
do $$
begin
  if to_regclass('sri_os.v_ledger_posted') is null then
    raise exception 'ไม่มี v_ledger_posted → ต้องรัน 20261020000001 ก่อน · ยอดที่ปันส่วนต้องอ่านผ่านวิวนั้นเท่านั้น ไม่ใช่จากตารางฐาน (D-098) ไม่งั้นใบที่ยกเลิกแล้วจะไหลเข้ารายงานต่อ project';
  end if;
  if to_regclass('sri_os.tag_allocations') is null then
    raise exception 'ไม่มี tag_allocations → ต้องรัน 20261028000001_tag_allocations.sql ก่อน';
  end if;
  if to_regprocedure('sri_os.fn_assert_ledger_read_path()') is null then
    raise exception 'ไม่มี fn_assert_ledger_read_path → ต้องรัน 20261020000001 ก่อน (ด่านของไฟล์นี้เป็นแพทเทิร์นเดียวกันและเรียกตัวนั้นด้วย)';
  end if;
end $$;

-- ============================================================
-- 1 · ประโยคกำกับของชนิดที่ปันส่วน — **แก้ที่ต้นทางแล้ว ไม่ซ่อมที่นี่**
--
--   ร่างแรกของไฟล์นี้มี `update tag_kinds set allocation_note_th = …` เพื่อซ่อม
--   ข้อความที่ `20261027000001_tag_catalog.sql` seed ไว้ผิด (ลงท้ายว่า *"เศษจากการ
--   ปัดตกที่โปรเจกต์ที่น้ำหนักมากที่สุด"* ซึ่งเป็นทางที่ **ADR 0003 ข้อ 4.2 ปฏิเสธ**
--   เพราะการปัดรายบรรทัดทำให้ double entry **ต่อ tag ไม่ดุล** ขณะที่ยอดรวมทั้งสมุด
--   ยังตรง → ไม่มีด่านไหนฟ้อง)
--
--   **ถอดการซ่อมออกแล้ว** เพราะไฟล์ seed ถูกแก้ที่ต้นทางไปแล้ว (28/10) และยังไม่มี
--   ฐานข้อมูลไหนในโลกที่เคยรับข้อความเดิมเข้าไป (ตาราง tag ยังไม่ได้ลง DB จริง และ
--   DB ทดสอบสร้างใหม่จากไฟล์ทุกครั้ง) → การซ่อมเป็นโค้ดตาย
--
--   เหตุผลที่ต้องถอด ไม่ใช่ปล่อยไว้เฉยๆ: ประโยคเดียวกันจะมี **สองสำนวนในสองไฟล์**
--   ถ้าใครแก้ที่เดียว อีกที่จะค้าง แล้ววันที่ด่านข้างล่างดังขึ้น คนจะเอาสำนวนของ
--   ไฟล์นี้ไปใส่ ซึ่งต่างจาก seed (กฎเดียวห้ามอยู่สองที่ · บทเรียนผู้ตรวจข้อ 5)
--
--   **ด่านที่กันกฎผิดกลับมา ยังอยู่ท้ายไฟล์** (ไล่หา '%เศษจากการปัด%' แล้ว raise)
--   ซึ่งเป็นสิ่งที่มีค่าจริง — ไม่ได้ถอดไปกับการซ่อม
-- ============================================================

-- ============================================================
-- 2 · `v_ledger_allocated` — สมุดระดับบรรทัด × น้ำหนัก
--
--   security_invoker = true → กรองด้วย RLS ของผู้เรียก (ADR 0002 ข้อ 5 ข้อ 2
--   ข้อย่อย 1) · ผลที่ตามมาโดยเจตนา: **ยอดต่อ project ของคนละสิทธิ์ไม่เท่ากัน**
--   หน้าจอต้องเขียนว่าคิดจาก Entity ไหน ไม่งั้นสองคนเปิดหน้าเดียวกันเห็นเลขต่างกัน
--
--   ปันส่วน **รายบรรทัดบัญชี** ไม่ใช่รายใบ (ข้อ 4.2) — ตอบคำถามที่ ADR 0002
--   ข้อ 4.3 ตั้งไว้ว่า "คิดจากยอดใบหรือต่อบรรทัด": รายใบทำไม่ได้เพราะ "ยอดใบ"
--   ของใบเงินต้น+ดอกเบี้ยไม่มีนิยามเดียว
-- ============================================================
create or replace view v_ledger_allocated with (security_invoker = true) as
select
  l.tag_id,
  tg.code                  as tag_code,
  l.tag_kind,
  l.id                     as transaction_tag_id,
  a.id                     as allocation_id,
  a.weight,
  v.owner_id,
  v.transaction_id,
  v.txn_type_code,
  v.doc_date,
  v.cash_date,
  v.contact_id,
  v.counter_owner_id,
  v.line_id,
  v.coa_id,
  v.cf_category,
  v.line_asset_id,
  v.debit,
  v.credit,
  -- **ไม่ปัด · ห้าม cast** (ADR 0003 ข้อ 4.2) — ดูเหตุผลเต็มที่หัวไฟล์
  v.debit  * a.weight      as allocated_debit,
  v.credit * a.weight      as allocated_credit,
  -- **ธงรายการข้ามผู้ถือ** — ต่อท้ายคอลัมน์เดิมเท่านั้น (`create or replace view`
  -- เพิ่มได้แค่ท้ายสุด) · `counter_owner_id` อยู่ข้างบนแล้ว แต่ **ธงต้องมาด้วย**
  -- เพราะคนอ่านแยก "ขาคู่ของรายการข้ามผู้ถือ" ออกจากรายการธรรมดาที่บังเอิญมี
  -- คู่สัญญาไม่ได้ถ้ามีแต่ id · รายการข้ามผู้ถือเป็น **สองใบคู่กัน** (กฎเหล็กข้อ 4)
  -- ที่ติด tag ชุดเดียวกันทั้งสองขา (ประตูบังคับไว้เอง) → รายงานที่บวกข้ามผู้ถือ
  -- โดยไม่ตัดขาคู่ออกจะ **นับเงินก้อนเดียวสองครั้ง** = กำไรที่ไม่จริงแบบเดียวกับที่
  -- ฟีเจอร์นี้มาแก้ · เทสต์ W9 ของ zz_tag_allocation_test.sql ตรึงตัวเลขไว้แล้ว
  v.is_intercompany
from v_ledger_posted v
join transaction_tags l on l.transaction_id = v.transaction_id and l.untagged_at is null
join tag_allocations  a on a.transaction_tag_id = l.id and a.superseded_at is null
join tags             tg on tg.id = l.tag_id
join tag_kinds        k  on k.key = l.tag_kind
-- คอนฟิกเป็นคนตัดสินว่าชนิดไหนปันส่วน ไม่ใช่ชื่อชนิดที่พิมพ์ในโค้ด (กฎเหล็กข้อ 5)
where k.requires_allocation;

alter view v_ledger_allocated set (security_invoker = true);

comment on view v_ledger_allocated is
  'ADR 0003 ข้อ 4.2 · สมุด (v_ledger_posted) × น้ำหนักของ tag ชนิดที่ปันส่วน · allocated_debit = debit * weight และ allocated_credit = credit * weight **ไม่ปัดและห้าม cast กลับเป็น numeric(18,2)** (cast = ปัด = ผลรวมข้าม tag ไม่ตรงสมุด และงบต่อ project ไม่ดุล) · ปันส่วน **รายบรรทัด** ไม่ใช่รายใบ เพราะ "ยอดใบ" ของใบเงินต้น+ดอกเบี้ยไม่มีนิยามเดียว · ยอดของทุก tag บวกกันได้และเท่ากับยอดในสมุดพอดี (ด่าน Σ น้ำหนัก = 1 รับประกัน) · security_invoker → ยอดของคนละสิทธิ์ไม่เท่ากันโดยเจตนา · พา counter_owner_id + is_intercompany มาด้วยเพื่อให้รายงานที่บวกข้ามผู้ถือตัดขาคู่ของรายการข้ามผู้ถือได้ (ไม่ตัด = นับเงินก้อนเดียวสองครั้ง)';

-- ============================================================
-- 3 · `v_tag_allocated_totals` — ยอดรวมต่อ tag ที่ **บวกข้าม tag ได้**
--
--   ชื่อคอลัมน์ตาม ADR 0003 ข้อ 5: `allocated_debit` · `allocated_credit` ·
--   `allocated_txn_count` · **และ `weight_sum` มาด้วยในแถวเดียวกัน**
--   (ถ้า `weight_sum` ของแถวไหนไม่ใช่จำนวนเต็มสวยๆ คนอ่านจะเห็นเองว่าใบถูกแบ่ง
--    เช่น 3 ใบที่ติด tag เดียวทั้งก้อน → 3.000000 · 3 ใบที่แบ่ง 60% → 1.800000)
--   **ไม่มี** คอลัมน์ชื่อ `total` หรือ `amount` เปล่าๆ ให้หยิบไปใช้ผิด (กติกา ADR 0002)
--   `allocation_note_th` มาจาก DB ไม่ใช่จากหน้าจอ (ADR 0002 ข้อ 4 ชั้น 3)
--
--   `allocated_txn_count` คิดจาก `v_ledger_allocated` ที่ถูก RLS กรองแล้ว
--   **ห้าม count(*) จาก transaction_tags ตรง** (ADR 0002 ข้อ 5 ข้อ 2 ข้อย่อย 3:
--   วันหนึ่ง policy สองตารางเพี้ยนไม่เท่ากัน = รั่ว)
-- ============================================================
create or replace view v_tag_allocated_totals with (security_invoker = true) as
with per_txn as (
  -- น้ำหนักของ (ใบ × tag) เป็นค่าเดียวทุกบรรทัด → min() คือค่านั้นเป๊ะ
  -- (รวมรายใบก่อน เพื่อให้ weight_sum ไม่ถูกนับซ้ำตามจำนวนบรรทัดของใบ)
  select
    v.tag_id, v.tag_code, v.tag_kind, v.owner_id, v.coa_id, v.cf_category,
    date_trunc('month', v.doc_date)::date as period,
    v.transaction_id,
    -- คู่สัญญา + ธงข้ามผู้ถือเป็นค่าของ **หัวรายการ** → ค่าเดียวทุกบรรทัดของใบ
    v.counter_owner_id, v.is_intercompany,
    min(v.weight)             as weight,
    sum(v.allocated_debit)    as allocated_debit,
    sum(v.allocated_credit)   as allocated_credit
  from v_ledger_allocated v
  group by v.tag_id, v.tag_code, v.tag_kind, v.owner_id, v.coa_id, v.cf_category,
           date_trunc('month', v.doc_date)::date, v.transaction_id,
           v.counter_owner_id, v.is_intercompany
)
select
  p.tag_id,
  p.tag_code,
  p.tag_kind,
  p.owner_id,
  p.coa_id,
  p.cf_category,
  p.period,
  sum(p.allocated_debit)            as allocated_debit,
  sum(p.allocated_credit)           as allocated_credit,
  count(distinct p.transaction_id)  as allocated_txn_count,
  sum(p.weight)                     as weight_sum,
  k.allocation_note_th,
  -- **สองช่องที่แยกขาคู่ออกจากกันได้** — ต่อท้ายคอลัมน์เดิมเท่านั้น
  --
  -- วิวนี้เคยไม่มีสองช่องนี้ ขณะที่ `v_ledger_allocated` มี `counter_owner_id` อยู่แล้ว
  -- ผลคือรายงาน "กำไรต่อ project" ที่บวกข้ามผู้ถือ (ซึ่งเป็นสิ่งที่วิวนี้มีไว้ให้ทำ
  -- เพราะมันรวมมาถึงระดับ tag × ผู้ถือ × งวด) **นับสองขาของรายการเดียวซ้ำ**:
  -- ประตูลง tag ชุดเดียวกันให้ทั้งสองขาโดยเจตนา (ADR 0003 ข้อ 4.2.2 ชั้น 1 —
  -- ไม่งั้นยอดต่อ project ของคู่นั้นไม่สมมาตร) → ยอดโอน 200,000 ที่ติด project
  -- เดียวกันจะกลายเป็น 400,000 เมื่อบวกข้ามผู้ถือ **ทั้งที่ทุกใบดุลและ Σ น้ำหนัก = 1**
  -- จึงไม่มีด่านไหนจับได้ — กำไรที่ไม่จริงแบบเดียวกับที่ฟีเจอร์นี้มาแก้
  --
  -- **หน้าที่ของคนอ่าน**: รายงานที่บวกข้ามผู้ถือต้องตัดสินเรื่องขาคู่ด้วยสองช่องนี้
  -- (กรอง `not is_intercompany` หรือหักขาที่ `counter_owner_id` อยู่ในชุดเดียวกัน
  --  — หลักเดียวกับ Money Invariant ข้อ 6 "Consolidated ตัด intercompany แล้ว")
  -- วิวไม่ตัดให้เอง เพราะยอด **ต่อผู้ถือรายคน** ต้องเห็นขาของตัวเองครบตามจริง
  p.counter_owner_id,
  p.is_intercompany
from per_txn p
join tag_kinds k on k.key = p.tag_kind
group by p.tag_id, p.tag_code, p.tag_kind, p.owner_id, p.coa_id, p.cf_category,
         p.period, k.allocation_note_th, p.counter_owner_id, p.is_intercompany;

alter view v_tag_allocated_totals set (security_invoker = true);

comment on view v_tag_allocated_totals is
  'ADR 0003 ข้อ 5 · ยอดรวมต่อ tag ชนิดที่ปันส่วน · **บวกข้าม tag ได้** (ต่างจาก v_tag_touch_totals ของ ADR 0002 ที่บวกไม่ได้ และห้ามมีวิว/หน้าจอไหนเอาสองอย่างมารวมกัน) · มี weight_sum มาในแถวเดียวกันเพื่อให้คนอ่านเห็นเองว่าใบถูกแบ่ง · ไม่มีคอลัมน์ชื่อ total/amount เปล่าๆ · allocation_note_th มาจาก tag_kinds ไม่ใช่จากหน้าจอ · นับใบจาก v_ledger_allocated ที่ RLS กรองแล้ว ไม่ใช่ count(*) จาก transaction_tags ตรง · **พา counter_owner_id และ is_intercompany มาด้วย** เพราะรายการข้ามผู้ถือเป็นสองใบคู่กันที่ประตูติด tag ชุดเดียวกันให้ทั้งสองขา → รายงานที่บวกข้ามผู้ถือโดยไม่ตัดขาคู่จะนับเงินก้อนเดียวสองครั้ง (200,000 → 400,000) โดยที่ทุกใบดุลและ Σ น้ำหนัก = 1 จึงไม่มีด่านไหนจับได้ · วิวไม่ตัดให้เอง (ยอดต่อผู้ถือรายคนต้องเห็นขาของตัวเองครบ) แต่ให้ช่องที่ตัดสินได้มาเสมอ';

grant select on v_ledger_allocated, v_tag_allocated_totals to authenticated;
do $$
begin
  execute 'revoke all on table sri_os.v_ledger_allocated from anon';
  execute 'revoke all on table sri_os.v_tag_allocated_totals from anon';
exception when undefined_object then null;
end $$;

-- ============================================================
-- 4 · `fn_assert_tag_read_path()` — ด่านชั้น DB ของเส้นทางอ่าน tag
--
--   แพทเทิร์นเดียวกับ `fn_assert_ledger_read_path` (D-098) · ADR 0002 ข้อ 4 ชั้น 4
--   ขยายตาม ADR 0003 ข้อ 5
--
--   เรียก **ตอน migrate** (ท้ายไฟล์นี้) และ **ในเทสต์** → รายงานใหม่ที่อ่าน tag
--   ต้องถูกเพิ่มเข้า allow-list ในไฟล์ migration พร้อมเหตุผล ซึ่งแปลว่า
--   `mace-windu` ต้องเห็น (กติกาข้อ 7 ของ CLAUDE.md)
-- ============================================================
create or replace function fn_assert_tag_read_path() returns void
language plpgsql stable set search_path = '' as $fn$
declare
  v text;
  n int;
  c_allow constant text[] := array[
    -- ADR 0002 ชิ้น 3 (ยังไม่ลง ณ 28/10 — ใส่ไว้ล่วงหน้าเพื่อให้ไฟล์นั้นไม่ต้องแก้ด่านนี้)
    'v_ledger_tagged', 'v_tag_touch_totals', 'v_tag_coverage',
    -- ADR 0003 ชิ้น A3 (ไฟล์นี้)
    'v_ledger_allocated', 'v_tag_allocated_totals'];
begin
  -- ---------- (T1) view/matview ที่อ่าน transaction_tags / tag_allocations ตรงๆ ----------
  --   นอก allow-list = รายงานที่จะนับซ้ำ (touch) หรือหยิบตัวคูณไปใช้ (น้ำหนัก)
  --   โดยไม่มีใครตัดสิน → ต้องเห็นใน git ไม่ใช่โผล่มาเงียบๆ
  select string_agg(distinct nd.nspname || '.' || dep.relname
                             || ' (relkind ' || dep.relkind::text || ')', ', ') into v
    from pg_depend d
    join pg_rewrite r   on r.oid = d.objid
    join pg_class  dep  on dep.oid = r.ev_class
    join pg_class  base on base.oid = d.refobjid
    join pg_namespace nb on nb.oid = base.relnamespace
    join pg_namespace nd on nd.oid = dep.relnamespace
   where d.classid    = 'pg_rewrite'::regclass
     and d.refclassid = 'pg_class'::regclass
     and nb.nspname = 'sri_os'
     and base.relname in ('transaction_tags', 'tag_allocations')
     and dep.relkind in ('v', 'm')
     and dep.oid <> base.oid
     and not (nd.nspname = 'sri_os' and dep.relname = any (c_allow));
  if v is not null then
    raise exception 'ADR 0002 ข้อ 4 ชั้น 4 · ADR 0003 ข้อ 5: พบ view/matview ที่อ่าน transaction_tags / tag_allocations ตรงๆ: % · รายงานต่อ tag ต้องอ่านผ่านวิวที่ประกาศความหมายของตัวเองแล้ว (%) เพราะสองความหมายห้ามปนกัน: **touch** (ยอดที่แตะ tag · บวกข้าม tag ไม่ได้) กับ **allocated** (ส่วนแบ่งของ tag · บวกได้) · ถ้าของตัวนี้ต้องอ่านตารางฐานจริงๆ ให้เพิ่มชื่อเข้า allow-list ในไฟล์ migration ใหม่พร้อมเหตุผล ไม่ใช่ถอน guard',
      v, array_to_string(c_allow, ', ');
  end if;

  -- ---------- (T2) ฟังก์ชันรายงาน (set-returning) ที่อ่านตารางฐานตรงๆ ----------
  --   และ **ห้าม security definer เด็ดขาด** (ADR 0002 ข้อ 5 ข้อ 2 ข้อย่อย 2:
  --   fn_tag_totals() แบบ definer "เพื่อให้ยอดครบ" = เปิดสมุดของผู้ถืออื่นผ่านยอดรวม)
  select string_agg(p.oid::regprocedure::text
                    || case when p.prosecdef then ' (security definer!)' else '' end, ', ')
    into v
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.proretset
     and p.prorettype <> 'trigger'::regtype
     and p.prosrc ~ '\m(transaction_tags|tag_allocations)\M';
  if v is not null then
    raise exception 'พบฟังก์ชันรายงาน (set-returning) ที่อ่าน transaction_tags / tag_allocations ตรงๆ: % · ให้อ่านผ่านวิวของเส้นทางนี้เท่านั้น · และห้ามเป็น security definer เพื่อ "ให้ยอดครบ" เด็ดขาด (= เปิดสมุดของผู้ถืออื่นผ่านยอดรวม · ADR 0002 ข้อ 5 ข้อ 2)', v;
  end if;

  select string_agg(p.oid::regprocedure::text, ', ') into v
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.prosecdef
     and p.prorettype <> 'trigger'::regtype
     and p.prosrc ~ '\m(v_tag_touch_totals|v_tag_allocated_totals|v_ledger_allocated|v_ledger_tagged)\M';
  if v is not null then
    raise exception 'พบฟังก์ชัน security definer ที่อ่านวิวของ tag: % · วิวพวกนี้เป็น security_invoker โดยเจตนา (ยอดของคนละสิทธิ์ไม่เท่ากัน) · ห่อด้วย definer = ทางลัดที่ทำให้ยอด "ครบ" ข้ามขอบเขตผู้ถือ', v;
  end if;

  -- ---------- (T3) ห้ามมีอะไรอ่าน **ทั้ง** touch และ allocated ในนิยามเดียวกัน ----------
  --   = กำลังเอา "ยอดที่แตะ tag" มาบวกกับ "ส่วนแบ่งของ tag" (ADR 0003 ข้อ 5)
  select string_agg(distinct nd.nspname || '.' || dep.relname, ', ') into v
    from pg_depend d
    join pg_rewrite r   on r.oid = d.objid
    join pg_class  dep  on dep.oid = r.ev_class
    join pg_class  base on base.oid = d.refobjid
    join pg_namespace nb on nb.oid = base.relnamespace
    join pg_namespace nd on nd.oid = dep.relnamespace
   where d.classid    = 'pg_rewrite'::regclass
     and d.refclassid = 'pg_class'::regclass
     and nb.nspname = 'sri_os'
     and base.relname = 'v_tag_touch_totals'
     and dep.relkind in ('v', 'm')
     and dep.oid <> base.oid
     and exists (
       select 1
         from pg_depend d2
         join pg_rewrite r2 on r2.oid = d2.objid
         join pg_class b2   on b2.oid = d2.refobjid
         join pg_namespace nb2 on nb2.oid = b2.relnamespace
        where d2.classid = 'pg_rewrite'::regclass and d2.refclassid = 'pg_class'::regclass
          and r2.ev_class = dep.oid
          and nb2.nspname = 'sri_os' and b2.relname = 'v_tag_allocated_totals');
  if v is not null then
    raise exception 'พบ view ที่อ่าน **ทั้ง** v_tag_touch_totals และ v_tag_allocated_totals ในนิยามเดียวกัน: % · touch บวกข้าม tag ไม่ได้ · allocated บวกได้ · เอามารวมกันแปลว่าตัวเลขที่ออกมาไม่มีความหมายเดียว และไม่มีใครรู้ว่าแถวไหนหมายถึงอะไร (ADR 0003 ข้อ 5)', v;
  end if;

  select string_agg(p.oid::regprocedure::text, ', ') into v
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.prosrc ~ '\mv_tag_touch_totals\M'
     and p.prosrc ~ '\mv_tag_allocated_totals\M'
     and p.proname <> 'fn_assert_tag_read_path';
  if v is not null then
    raise exception 'พบฟังก์ชันที่อ่านทั้ง v_tag_touch_totals และ v_tag_allocated_totals: % (ADR 0003 ข้อ 5)', v;
  end if;

  -- ---------- (T4) ชื่อคอลัมน์ห้ามหลอกกัน ----------
  -- ไล่จาก information_schema.columns (ไม่ต้องกรองคอลัมน์ที่ถูกถอนไปแล้วเอง)
  select string_agg(c.table_name || '.' || c.column_name, ', ') into v
    from information_schema.columns c
   where c.table_schema = 'sri_os'
     and (   (c.table_name = 'v_tag_allocated_totals' and c.column_name like 'touched\_%')
          or (c.table_name = 'v_tag_touch_totals'     and c.column_name like 'allocated\_%')
          or (c.table_name in ('v_tag_allocated_totals', 'v_tag_touch_totals')
              and c.column_name in ('total', 'amount')));
  if v is not null then
    raise exception 'ชื่อคอลัมน์หลอกความหมาย: % · วิวที่ปันส่วนแล้วห้ามมีคอลัมน์ touched_* · วิว touch ห้ามมี allocated_* · และทั้งคู่ห้ามมี total/amount เปล่าๆ ให้หยิบไปใช้ผิด (ADR 0002 ข้อ 4 ชั้น 1 · ADR 0003 ข้อ 5)', v;
  end if;

  -- ---------- (T5) **ห้ามปัด / ห้าม cast** ที่ชั้นวิว (ADR 0003 ข้อ 4.2 · 4.2.1) ----------
  --   ไล่จาก **นิยามของวิวจริงใน catalog** ไม่ใช่พึ่งความจำของคนที่แก้ครั้งถัดไป
  if to_regclass('sri_os.v_ledger_allocated') is not null then
    v := pg_get_viewdef('sri_os.v_ledger_allocated'::regclass, true);
    if v ~* 'numeric\s*\(' then
      raise exception 'นิยามของ v_ledger_allocated มี cast เป็น numeric(...) · ยอด numeric(18,2) × น้ำหนัก numeric(9,6) ได้ scale 8 ต้องปล่อยให้เป็น numeric ไม่ระบุ scale · cast = ปัด = พังทั้งสองข้อของ ADR 0003 ข้อ 4.2 (ผลรวมข้าม tag ไม่ตรงสมุด และ **งบต่อ project ไม่ดุล** โดยสมุดใหญ่ยังดุลสนิทจึงไม่มีด่านไหนฟ้อง)';
    end if;
    if v ~* '\m(round|trunc)\s*\(' then
      raise exception 'นิยามของ v_ledger_allocated มี round()/trunc() · ADR 0003 ข้อ 4.2 ห้ามปัดตอนปันส่วนเด็ดขาด (ร่างแรกที่สั่ง "เศษตกที่แถวสุดท้าย" **ถูกปฏิเสธและทดลองแล้วพังจริง**) · ปัดเฉพาะตัวเลขก้อนสุดท้ายที่คนอ่าน ด้วยฟังก์ชันตัวเดียวที่ทุกหน้าเรียก (ข้อ 4.2.1)';
    end if;
    -- ชนิดจริงของคอลัมน์ต้องเป็น numeric ไม่ระบุ scale (กันทาง cast ที่ pg_get_viewdef ย่อไว้)
    select string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ') into v
      from pg_attribute a
     where a.attrelid = 'sri_os.v_ledger_allocated'::regclass
       and a.attname in ('allocated_debit', 'allocated_credit')
       and format_type(a.atttypid, a.atttypmod) <> 'numeric';
    if v is not null then
      raise exception 'คอลัมน์ที่ปันส่วนแล้วถูกจำกัด scale: % · ต้องเป็น numeric เปล่าๆ', v;
    end if;
  end if;
  if to_regclass('sri_os.v_tag_allocated_totals') is not null then
    v := pg_get_viewdef('sri_os.v_tag_allocated_totals'::regclass, true);
    if v ~* 'numeric\s*\(' or v ~* '\m(round|trunc)\s*\(' then
      raise exception 'นิยามของ v_tag_allocated_totals มีการปัด/cast · ยอดรวมต่อ project ต้องเป็นผลบวกของค่าที่ไม่ปัด (ปัดที่ชั้นแสดงผลเท่านั้น · ADR 0003 ข้อ 4.2.1)';
    end if;
  end if;

  -- ---------- (T6) ชนิดที่ปันส่วน/ไม่ปันส่วน ต้องอยู่คนละวิว ----------
  --   นิยามของวิวที่ปันส่วนแล้ว **ต้องกรองจากคอนฟิก** ไม่ใช่จากชื่อชนิดในโค้ด
  if pg_get_viewdef('sri_os.v_ledger_allocated'::regclass, true) !~ 'requires_allocation' then
    raise exception 'v_ledger_allocated ไม่ได้กรองด้วย tag_kinds.requires_allocation → ชนิดที่ไม่ปันส่วน (label) จะไหลเข้าวิวที่บวกข้าม tag ได้ แล้วยอดจะเกินจริงเงียบๆ · และต้องกรองจาก **คอนฟิก** ไม่ใช่เทียบชื่อ ''project'' ที่พิมพ์ในโค้ด (กฎเหล็กข้อ 5)';
  end if;
  select string_agg(distinct k.key, ', ') into v
    from sri_os.v_tag_allocated_totals t
    join sri_os.tag_kinds k on k.key = t.tag_kind
   where not k.requires_allocation;
  if v is not null then
    raise exception 'ชนิดที่ไม่ปันส่วนโผล่ใน v_tag_allocated_totals: % · คนอ่านจะเอา touch มาบวกกับ allocated (ADR 0003 ข้อ 5)', v;
  end if;
  if to_regclass('sri_os.v_tag_touch_totals') is not null then
    if pg_get_viewdef('sri_os.v_tag_touch_totals'::regclass, true) !~ 'requires_allocation' then
      raise exception 'v_tag_touch_totals ไม่ได้กรองชนิดที่ requires_allocation ออก → ชนิดที่ปันส่วนจะโผล่ในวิว touch ด้วย แล้วมีสองยอดของ project เดียวกันคนละความหมายอยู่ในระบบพร้อมกัน (ADR 0003 ข้อ 5) · ชิ้น 3 ของ ADR 0002 ต้องเพิ่มเงื่อนไขนี้ตอนสร้างวิวนั้น';
    end if;
  end if;

  -- ---------- (T7) ตารางน้ำหนักห้ามกลายเป็นที่เก็บจำนวนเงิน ----------
  select string_agg(c.column_name || ' (scale ' || coalesce(c.numeric_scale::text, '-') || ')', ', ')
    into v
    from information_schema.columns c
   where c.table_schema = 'sri_os' and c.table_name = 'tag_allocations'
     and c.data_type in ('numeric', 'money', 'double precision', 'real')
     and (c.numeric_scale is distinct from 6);
  if v is not null then
    raise exception 'tag_allocations มีคอลัมน์ numeric ที่ scale ≠ 6: % (= มีคนเติมคอลัมน์จำนวนเงิน) · ตารางนี้ถือแต่ตัวคูณ จำนวนเงินมาจากสมุดเสมอ (ADR 0003 ข้อ 3.2 · ข้อ 5)', v;
  end if;
  if exists (select 1 from information_schema.columns c
              where c.table_schema = 'sri_os' and c.table_name = 'transaction_tags'
                and c.data_type in ('numeric', 'money', 'double precision', 'real')) then
    raise exception 'transaction_tags มีคอลัมน์ตัวเลขเงิน/สัดส่วน · น้ำหนักต้องอยู่ใน tag_allocations ตารางแยก (ADR 0002 ข้อ 4.3)';
  end if;

  -- ---------- (T8) ประโยคกำกับว่าง = หน้าจอแสดงยอดเปลือย ----------
  select string_agg(k.key, ', ') into v
    from sri_os.tag_kinds k
   where k.aggregate_note_th is null or btrim(k.aggregate_note_th) = '';
  if v is not null then
    raise exception 'tag_kinds.aggregate_note_th ว่างในชนิด: % · ADR 0002 ข้อ 4 ชั้น 3 บังคับให้ทุกตาราง/การ์ด/export ต่อ tag แสดงประโยคนี้ ว่างแล้วหน้าจอจะโชว์เลขเปลือย', v;
  end if;
  select string_agg(k.key, ', ') into v
    from sri_os.tag_kinds k
   where k.requires_allocation
     and (k.allocation_note_th is null or btrim(k.allocation_note_th) = '');
  if v is not null then
    raise exception 'ชนิดที่ปันส่วนไม่มี allocation_note_th: % · วิวที่ปันส่วนแล้วใช้ประโยคนี้แทน aggregate_note_th (ADR 0003 ข้อ 3.1)', v;
  end if;
  -- ประโยคกำกับห้ามพูดถึงกฎที่ ADR ปฏิเสธไปแล้ว (ร่างแรกของข้อ 4.2)
  select string_agg(k.key, ', ') into v
    from sri_os.tag_kinds k
   where k.requires_allocation and k.allocation_note_th like '%เศษจากการปัด%';
  if v is not null then
    raise exception 'allocation_note_th ของชนิด % ยังบอกผู้ใช้ว่าระบบปัดเศษตอนปันส่วน (กฎของ **ร่างแรกที่ ADR 0003 ข้อ 4.2 ปฏิเสธไปแล้ว**) · ระบบไม่ปัดตอนปันส่วน และถ้าประโยคในหน้าจอบอกตรงข้าม จะมีคนไปเขียนโค้ดปัดเศษตามนั้นแล้วงบต่อ project ไม่ดุล', v;
  end if;

  -- ---------- (T10) วิวที่ปันส่วนแล้วต้องพาช่องที่ **แยกขาคู่** ออกมาได้ ----------
  --   รายการข้ามผู้ถือเป็นสองใบคู่กัน (กฎเหล็กข้อ 4) และประตูติด tag ชุดเดียวกัน
  --   ให้ทั้งสองขาโดยเจตนา (ADR 0003 ข้อ 4.2.2 ชั้น 1) → ถ้าวิวไม่พา
  --   `counter_owner_id` / `is_intercompany` มา รายงานที่บวกข้ามผู้ถือจะ
  --   **นับเงินก้อนเดียวสองครั้ง** โดยที่ทุกใบดุลและ Σ น้ำหนัก = 1 พอดี
  --   จึงไม่มีด่านไหนจับได้ (= กำไรที่ไม่จริงแบบเดียวกับที่ฟีเจอร์นี้มาแก้)
  select string_agg(x.rel || '.' || x.col, ', ') into v
    from (values ('v_ledger_allocated', 'counter_owner_id'),
                 ('v_ledger_allocated', 'is_intercompany'),
                 ('v_tag_allocated_totals', 'counter_owner_id'),
                 ('v_tag_allocated_totals', 'is_intercompany')) x(rel, col)
   where not exists (select 1 from information_schema.columns c
                      where c.table_schema = 'sri_os'
                        and c.table_name = x.rel and c.column_name = x.col);
  if v is not null then
    raise exception 'วิวที่ปันส่วนแล้วขาดช่องที่แยกขาคู่ของรายการข้ามผู้ถือ: % · ประตูติด tag ชุดเดียวกันให้ทั้งสองขาโดยเจตนา (ADR 0003 ข้อ 4.2.2 ชั้น 1 — ไม่งั้นยอดต่อ project ของคู่นั้นไม่สมมาตร) → ถ้าไม่มีสองช่องนี้ รายงาน "กำไรต่อ project" ที่บวกข้ามผู้ถือจะนับเงินก้อนเดียวสองครั้ง (โอน 200,000 กลายเป็น 400,000) **โดยที่ทุกใบดุลและ Σ น้ำหนัก = 1 พอดี** จึงไม่มีด่านไหนจับได้',
      v;
  end if;

  -- ---------- (T9) ด่านกันตัวเองตาย (D-096) ----------
  --   ถ้าวิธีไล่ catalog เพี้ยน query ทุกข้อข้างบนจะคืนค่าว่างและ "ผ่าน" ทุกครั้ง
  --   เครื่องมือที่ครอบไม่ครบอันตรายกว่าไม่มีเครื่องมือ
  select count(*) into n
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os' and c.relkind = 'v'
     and c.relname in ('v_ledger_allocated', 'v_tag_allocated_totals');
  if n <> 2 then
    raise exception 'ด่านนี้ไล่ catalog ไม่เจอวิวของตัวเองครบสองตัว (เจอ % ตัว) → วิธีไล่ใช้ไม่ได้บน Postgres รุ่นนี้ หรือมีคนถอนวิวไป · ปล่อยผ่าน = ด่านนี้ไม่จับอะไรเลยตลอดไป (D-096)', n;
  end if;

  select count(*) into n
    from pg_depend d
    join pg_rewrite r   on r.oid = d.objid
    join pg_class  dep  on dep.oid = r.ev_class
    join pg_class  base on base.oid = d.refobjid
    join pg_namespace nb on nb.oid = base.relnamespace
   where d.classid    = 'pg_rewrite'::regclass
     and d.refclassid = 'pg_class'::regclass
     and nb.nspname = 'sri_os'
     and base.relname in ('transaction_tags', 'tag_allocations')
     and dep.relkind in ('v', 'm')
     and dep.oid <> base.oid;
  if n < 1 then
    raise exception 'ด่าน (T1) มองไม่เห็นแม้ v_ledger_allocated ที่รู้ว่าอ่าน transaction_tags + tag_allocations อยู่ → วิธีไล่ dependency เพี้ยน · guard นี้จะไม่จับอะไรเลย (D-096)';
  end if;

  -- สองวิวต้องเป็น security_invoker จริง (definer = ยอดข้ามขอบเขตผู้ถือ)
  select string_agg(c.relname, ', ') into v
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'sri_os'
     and c.relname in ('v_ledger_allocated', 'v_tag_allocated_totals')
     and not coalesce((select option_value::boolean from pg_options_to_table(c.reloptions)
                        where option_name = 'security_invoker'), false);
  if v is not null then
    raise exception 'วิว % ไม่ใช่ security_invoker → ยอดต่อ project จะข้ามขอบเขตผู้ถือของผู้เรียก (ADR 0002 ข้อ 5 ข้อ 2 ข้อย่อย 1)', v;
  end if;
end $fn$;

comment on function fn_assert_tag_read_path() is
  'ADR 0002 ข้อ 4 ชั้น 4 + ADR 0003 ข้อ 5 · ด่าน "เส้นทางอ่าน tag": view/matview หรือฟังก์ชันรายงานที่อ่าน transaction_tags/tag_allocations ตรงๆ นอก allow-list → พัง · ห้ามอะไรอ่านทั้ง v_tag_touch_totals และ v_tag_allocated_totals (touch กับ allocated ห้ามปนกัน) · ชื่อคอลัมน์ห้ามหลอกกัน · **ห้ามปัด/cast ที่ชั้นวิว** (ไล่จากนิยามจริงใน catalog ตามข้อ 4.2.1) · ชนิดที่ไม่ปันส่วนห้ามโผล่ในวิวที่ปันส่วนแล้ว · ประโยคกำกับว่างไม่ได้และห้ามพูดถึงกฎปัดเศษที่ ADR ปฏิเสธไปแล้ว · **วิวที่ปันส่วนแล้วต้องพา counter_owner_id/is_intercompany มาด้วย** (ไม่มี = รายงานที่บวกข้ามผู้ถือนับเงินก้อนเดียวสองครั้งโดยไม่มีด่านไหนจับ) · รวมด่านกันตัวเองตาย (D-096) · **ชิ้น 3 ของ ADR 0002 ต้องเพิ่มข้อ ไม่ใช่เขียนทับฟังก์ชันนี้** ไม่งั้นด่านของ allocated หายไปทั้งก้อน';

-- guard function ห้ามเรียกจากข้างนอก (ไม่ใช่ข้อมูล เป็นด่านของ migration/เทสต์)
revoke all on function fn_assert_tag_read_path() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_tag_read_path() from anon';
exception when undefined_object then null;
end $$;

-- ============================================================
-- 5 · guard ท้ายไฟล์ — ดังตอน migrate ไม่ใช่ตอนผู้ใช้กด
-- ============================================================
do $$
declare v text;
begin
  -- ด่านทั้งสองตัวต้องผ่านเดี๋ยวนี้ (ถ้าวันนี้มีของที่ละเมิดอยู่แล้ว migration ต้องพังที่นี่)
  perform sri_os.fn_assert_tag_read_path();
  perform sri_os.fn_assert_ledger_read_path();

  -- ฟังก์ชันด่านต้องยังพูดถึงวิวของ allocated (กันการเขียนทับจากชิ้น 3 ของ ADR 0002)
  v := pg_get_functiondef('sri_os.fn_assert_tag_read_path()'::regprocedure);
  if v !~ '\mv_tag_allocated_totals\M' or v !~ '\mv_ledger_allocated\M' then
    raise exception 'fn_assert_tag_read_path ไม่พูดถึงวิวที่ปันส่วนแล้ว → มีไฟล์อื่นเขียนทับฟังก์ชันนี้ด้วยเวอร์ชันที่รู้จักแต่ touch · ด่านของ allocated หายไปทั้งก้อน (ต้อง **เพิ่มข้อ** ไม่ใช่เขียนทับ)';
  end if;

  -- สองวิวต้องอ่านผ่าน v_ledger_posted ไม่ใช่ตารางฐาน (D-098)
  if pg_get_viewdef('sri_os.v_ledger_allocated'::regclass, true) !~ 'v_ledger_posted' then
    raise exception 'v_ledger_allocated ไม่ได้อ่านผ่าน v_ledger_posted → ใบที่ยกเลิกแล้วจะไหลเข้ารายงานต่อ project (D-098)';
  end if;

  raise notice 'ok · วิวที่ปันส่วนแล้วพร้อม: allocated_debit/credit = ยอด × น้ำหนัก **ไม่ปัดและไม่ cast** · อ่านผ่าน v_ledger_posted · กรองชนิดจากคอนฟิก requires_allocation · security_invoker ทั้งคู่ · ด่าน fn_assert_tag_read_path ครอบ touch และ allocated พร้อมด่านกันตัวเองตาย';
end $$;
