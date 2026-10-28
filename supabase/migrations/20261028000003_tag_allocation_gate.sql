-- ============================================================
-- SRI OS · **ประตูของน้ำหนัก tag** — ADR 0003 ข้อ 6 · 4.2.2 (ชิ้น A4)
--
--   `fn_assert_tag_weights_shape(jsonb)` — กฎ "รูปของชุดน้ำหนัก" **ที่เดียว**
--   `fn_tag_counter_legs(uuid)`          — ใบที่ต้องขยับพร้อมกัน (ขาคู่ข้ามผู้ถือ)
--   `fn_post_entry(jsonb)`               — รับช่องใหม่ `tag_weights`
--   `fn_reallocate_tags(uuid, text, jsonb, text)` — แก้สัดส่วนย้อนหลังแบบมีร่องรอย
--
-- ------------------------------------------------------------
-- **ช่อง `tag_weights` ของประตู** (ADR 0003 ข้อ 6)
--
--   รูป `{"<tag_id>": น้ำหนัก}` · ตัวเลขเป็น **สัดส่วน ไม่ใช่จำนวนเงิน** (0.6 = 60%)
--   - ส่งมาแล้ว tag ไม่มีในแค็ตตาล็อก / ปิดใช้งานแล้ว → **ปฏิเสธทั้งใบ**
--     (หลักเดิมของประตู: ไม่ทิ้งช่องเงียบๆ · ทิ้ง tag เงียบๆ = ใบนั้นหายจาก
--      รายงานต่อ project โดยคนกดคิดว่าติดแล้ว)
--   - ส่งชนิดที่ **ไม่ปันส่วน** (`label`) มาในช่องนี้ → ปฏิเสธ (touch กับ allocated
--     ห้ามปนกัน · ADR 0003 ข้อ 5) · ชนิดนั้นใช้ช่อง `tag_ids` ของ ADR 0002
--   - **ไม่ส่งน้ำหนักมา (null) และมีมากกว่าหนึ่ง tag → ปฏิเสธ**
--     ข้อมูลไม่ครบต้องปฏิเสธ ไม่ใช่เดาว่าแบ่งเท่ากัน (บทเรียน mace-windu ข้อ 1)
--   - **ไม่ส่งน้ำหนักมาและมี tag เดียว → เติม 1.000000 ให้**
--     ไม่ใช่การเดา เพราะมีคำตอบที่ถูกได้คำตอบเดียว (ADR 0003 ข้อ 4.1 ข้อย่อย 1)
--   - น้ำหนักละเอียดเกิน 6 ตำแหน่ง → **ปฏิเสธ** ไม่ใช่ปัดให้เงียบๆ
--     (คอลัมน์เป็น numeric(9,6) · ถ้าประตูปัดให้ Σ ที่ผู้ใช้คิดไว้จะไม่ใช่ Σ ที่ลงจริง)
--   - **ติดให้ทุกใบในคำขอ** — ทั้งสองขาของรายการข้ามผู้ถือ (ข้อ 4.2.2 ชั้น 1)
--
--   `buildPosting()` / `posting.ts` / `tx-rules.ts` / `coa.ts` **ไม่แก้แม้บรรทัดเดียว**
--   น้ำหนักไม่ใช่กฎบัญชี · ฟังก์ชันที่สร้างบรรทัดไม่เคยเห็น tag → น้ำหนักเปลี่ยน
--   คู่บัญชีไม่ได้เชิงโครงสร้าง
--
-- ------------------------------------------------------------
-- **`fn_reallocate_tags` ต้องครอบทั้งคู่** (ADR 0003 ข้อ 4.2.2 ชั้น 2)
--
--   ฟังก์ชันนี้ทำงาน **ต่อใบ** แต่รายการข้ามผู้ถือเป็น **สองใบคู่กัน** → แก้น้ำหนัก
--   ข้างเดียวได้ แต่ละขายังดุลในตัวเอง ผลรวมข้าม tag ยังตรงสมุด **จึงไม่มีด่านไหนจับ**
--   แต่ยอดต่อ project ของคู่นั้นไม่สมมาตร
--   → รับใบไหนมาก็ไล่หาขาคู่จากสมุดด้วย `fn_tag_counter_legs()`
--     (`counter_owner_id` + ลักษณะ + หมวด + วันที่ + ยอดตรงกัน · แบบเดียวกับด่าน
--      `fn_assert_intercompany_pair`) แล้วเปลี่ยนน้ำหนัก **ทั้งสองใบในธุรกรรมเดียว**
--   → **หาขาคู่ไม่เจอ หรือเจอหลายใบที่เข้าเกณฑ์เท่ากัน = ปฏิเสธ**
--     ไม่ใช่แก้ข้างเดียวเงียบๆ และไม่ใช่เดาว่าใบไหนคือขาคู่
--   → และ `fn_reallocate_tags` **ไม่เชื่อผลของตัวหา**: ถ้าใบที่ส่งมาเป็นรายการ
--     ข้ามผู้ถือ แต่ชุดที่ได้กลับมาไม่มีใบของผู้ถืออีกฝ่าย → ปฏิเสธ
--     (เทสต์ M3 เปลี่ยน `fn_tag_counter_legs` ให้คืนแต่ขาตัวเองแล้ววัดว่ายังปฏิเสธ)
--
--   แก้สัดส่วน = **ปิดชุดเดิมด้วย `superseded_*` แล้ว insert ชุดใหม่ในธุรกรรมเดียว**
--   `p_reason` **บังคับ** (ว่างไม่ได้) เหมือน `untag_reason` · security **INVOKER**
--   (definer = แก้สัดส่วนของใบที่ตัวเองมองไม่เห็นได้)
--
-- ------------------------------------------------------------
-- ลำดับ: หลัง 20261028000001 (`tag_allocations`) · หลัง 20261028000002 (วิว) ·
--        และ **หลัง 20261025000004** ซึ่งเป็นรุ่นล่าสุดของ `fn_post_entry`
--        (ไฟล์นี้ `create or replace` ทับด้วยรุ่นเดียวกันทุกตัวอักษร + ช่องใหม่)
--        ลงทะเบียนใน `supabase/migration-order.txt` และ UNDER_TEST ของ
--        `scripts/test-rls-local.sh` ต่อท้าย 20261028000002
--
-- idempotent: `create or replace function` ทุกตัว · รันซ้ำได้ผลเดิม
--   **ไฟล์นี้ไม่มีคำสั่งถอนของ และห้ามมีคำนั้นแม้ในคอมเมนต์** (ตัวตรวจของ MCP
--   `apply_migration` อ่านจากข้อความดิบแล้ว timeout ทุกครั้ง · ดู CLAUDE.md)
--
-- ย้อนกลับ (rollback):
--   -- คืน `fn_post_entry` รุ่นก่อน = รัน 20261025000004_fcd_bank_currency.sql อีกครั้ง
--   --   (ไฟล์นั้นถือรุ่นที่ไม่มี tag_weights ไว้ครบทั้งฟังก์ชัน)
--   -- ถอน fn_reallocate_tags / fn_tag_counter_legs / fn_assert_tag_weights_shape
--   --   ต้องทำใน migration ใหม่
--   ⚠ คืนรุ่นก่อนแล้ว **ส่ง tag_weights มาจะเด้ง "ช่องที่ยังไม่รู้จัก"** → ฟอร์มที่มี
--     ช่องน้ำหนักจะบันทึกไม่ได้เลย (ตันทั้งสองทางเหมือนเคสของ WHT ใน D-111 ข้อ 1)
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 0 · pre-flight
-- ============================================================
do $$
begin
  if to_regclass('sri_os.tag_allocations') is null then
    raise exception 'ไม่มี tag_allocations → ต้องรัน 20261028000001_tag_allocations.sql ก่อน';
  end if;
  if to_regclass('sri_os.v_ledger_allocated') is null then
    raise exception 'ไม่มี v_ledger_allocated → ต้องรัน 20261028000002_tag_allocated_views.sql ก่อน';
  end if;
  if to_regprocedure('sri_os.fn_post_entry(jsonb)') is null then
    raise exception 'ไม่มี fn_post_entry → ไฟล์นี้ทับประตูด้วยรุ่นเดิม + ช่อง tag_weights · ต้องรัน 20261025000004_fcd_bank_currency.sql ก่อน';
  end if;
  -- รุ่นที่ไฟล์นี้ลอกมาต้องเป็นรุ่นที่รู้จัก FCD แล้ว ไม่งั้นเรากำลัง **ถอย** ประตู
  if pg_get_functiondef('sri_os.fn_post_entry(jsonb)'::regprocedure) !~ 'amount_original' then
    raise exception 'fn_post_entry ใน DB ไม่รู้จักช่อง amount_original (FCD · 20261025000004) → รุ่นที่ไฟล์นี้จะเขียนทับใหม่กว่าของใน DB หรือมีไฟล์อื่นเขียนทับไปแล้ว · ทับไปจะทำให้ด่าน/ช่องของไฟล์อื่นหายเงียบๆ ให้ตรวจลำดับใน migration-order.txt ก่อน';
  end if;
end $$;

-- ============================================================
-- 1 · `fn_assert_tag_weights_shape` — กฎ "รูปของชุดน้ำหนัก" **ที่เดียว**
--
--   เรียกจากทั้ง `fn_post_entry` และ `fn_reallocate_tags` → กฎเดียวกันไม่ได้
--   เขียนสองที่ (บทเรียน mace-windu ข้อ 5: แผงในฟอร์มเคยคำนวณคู่บัญชีเอง
--   ทำให้สิ่งที่ผู้ใช้เห็นกับสิ่งที่บันทึกจริงแยกจากกันได้)
--
--   **ไม่ใช่ด่านจริงของ Σ = 1** — ด่านจริงคือ `trg_assert_tag_allocation_complete`
--   ที่ชั้นตาราง ซึ่งครอบการ INSERT ตรงด้วย · ที่นี่ตรวจเพื่อให้ผู้กดได้ข้อความ
--   ก่อนที่อะไรจะถูกเขียน **ห้ามถือว่าเป็นแหล่งความจริง**
--
--   security **INVOKER** · อ่านแค่แค็ตตาล็อก (`tags` / `tag_kinds`) ซึ่งเปิดให้
--   ทุกคนที่ล็อกอินอ่านอยู่แล้ว (ADR 0002 ข้อ 5 ข้อ 2) → ไม่มีอะไรรั่วเพิ่ม
-- ============================================================
create or replace function fn_assert_tag_weights_shape(p_weights jsonb) returns void
language plpgsql stable set search_path = '' as $fn$
declare
  v_bad text;
  v_n   int;
begin
  if p_weights is null or jsonb_typeof(p_weights) = 'null' then
    raise exception 'ไม่ได้ส่งชุดน้ำหนัก tag มาเลย — ถ้าใบนี้ไม่ต้องติด tag ที่ปันส่วน ให้ไม่ส่งช่องนั้นมา (null กับ "ไม่ส่ง" ต้องแปลเหมือนกัน และผู้เรียกต้องเป็นคนตัดสิน ไม่ใช่ประตูเดาแทน)';
  end if;
  if jsonb_typeof(p_weights) <> 'object' then
    raise exception 'ชุดน้ำหนัก tag ต้องเป็น object รูป {"<tag_id>": น้ำหนัก} ไม่ใช่ % · น้ำหนักเป็น **สัดส่วน** (0.6 = 60%%) ไม่ใช่จำนวนเงิน',
      jsonb_typeof(p_weights);
  end if;
  if p_weights = '{}'::jsonb then
    raise exception 'ส่งชุดน้ำหนัก tag มาแต่ว่างเปล่า — ถ้าใบนี้ไม่ต้องติด tag ที่ปันส่วน ให้ไม่ส่งช่องนั้นมาเลย · ส่งของว่างมาแปลว่าผู้เรียกคิดว่ามีน้ำหนักแต่มันหายไประหว่างทาง ซึ่งต้องปฏิเสธ ไม่ใช่ลงใบโดยไม่ติด tag เงียบๆ';
  end if;

  select count(*) into v_n from jsonb_object_keys(p_weights) as k;

  -- (ก) คีย์ต้องเป็น tag id (uuid)
  select string_agg(k, ', ' order by k) into v_bad
    from jsonb_object_keys(p_weights) as k
   where k !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  if v_bad is not null then
    raise exception 'คีย์ของชุดน้ำหนัก tag ต้องเป็น tag id (uuid) — ได้ % · ช่องนี้รับ id จากแค็ตตาล็อก ไม่ใช่รหัสหรือชื่อ tag (tag ต้องตั้งไว้ก่อนแล้วเลือก · คำสั่ง 26/10)',
      v_bad;
  end if;

  -- (ข) tag ต้องมีจริงในแค็ตตาล็อก — ไม่รู้จัก = ปฏิเสธทั้งคำขอ
  --
  -- **เส้นแบ่งของ "tag ที่ถูกปิดใช้งาน" (is_active = false) อยู่ที่นี่**
  --   ติด tag ใหม่  → **ห้าม** · บังคับที่ `fn_tag_link_system_columns` บนตาราง
  --                   `transaction_tags` ซึ่งอ่าน `tags.is_active` เองตอน INSERT
  --                   (ครอบการเขียนตรงด้วย ไม่ใช่แค่ทางประตู) · guard ท้ายไฟล์นี้
  --                   ตรวจว่าด่านตัวนั้นยังอ่าน is_active อยู่
  --   แก้สัดส่วนของ **tag ที่ติดอยู่กับใบนั้นแล้ว** → **ได้**
  --
  -- ฟังก์ชันนี้จึง **ไม่ตรวจ is_active** โดยเจตนา: มันถูกเรียกจากสองทางที่ความหมาย
  -- ต่างกัน — ประตู (ติดใหม่) และ `fn_reallocate_tags` (แก้ของที่ติดแล้ว) — และตัวมันเอง
  -- ไม่รู้จักใบ จึงแยกสองกรณีไม่ได้ · ถ้าตรวจที่นี่ ใบที่ติด tag ไปแล้วก่อน tag ถูกปิด
  -- จะ **แก้สัดส่วนไม่ได้อีกเลยตลอดกาล** (และถอด tag ก็ยังไม่มีประตู) = ใบนั้นติดค้าง
  -- ถาวรพร้อมสัดส่วนที่รู้อยู่ว่าผิด — เปิดฟีเจอร์ครึ่งเดียวอันตรายกว่าไม่เปิด
  -- (บทเรียน mace-windu ข้อ 7) · ส่วนทางติดใหม่ยังปิดสนิทเพราะด่านบนตารางปฏิเสธ
  -- ทั้งคำขอตอน INSERT ลิงก์ (ประตูเขียนลิงก์ก่อนน้ำหนักเสมอ) ไม่ใช่ทิ้งเงียบๆ
  select string_agg(k, ', ' order by k) into v_bad
    from jsonb_object_keys(p_weights) as k
   where not exists (select 1 from sri_os.tags t where t.id = k::uuid);
  if v_bad is not null then
    raise exception 'tag % ไม่มีในแค็ตตาล็อก → ปฏิเสธทั้งคำขอ ไม่ใช่ทิ้ง tag นั้นเงียบๆ (ทิ้งเงียบๆ = ใบนี้หายจากรายงานต่อ project โดยคนกดคิดว่าติดแล้ว และ Σ น้ำหนักที่เหลือจะไม่ครบ 1 โดยไม่มีใครรู้ว่าเพราะอะไร) · tag ต้องตั้งไว้ก่อนแล้วเลือก (คำสั่ง 26/10)',
      v_bad;
  end if;

  -- (ค) ต้องเป็นชนิดที่ **ปันส่วน** (อ่านจากคอนฟิก ไม่ใช่ชื่อชนิดในโค้ด)
  select string_agg(t.code || ' (ชนิด ' || t.kind || ')', ', ' order by t.code) into v_bad
    from jsonb_object_keys(p_weights) as k
    join sri_os.tags t      on t.id  = k::uuid
    join sri_os.tag_kinds d on d.key = t.kind
   where not d.requires_allocation;
  if v_bad is not null then
    raise exception 'tag % ไม่ใช่ชนิดที่ **ปันส่วน** (tag_kinds.requires_allocation = false) → ใส่น้ำหนักให้ไม่ได้ · ยอดของชนิดนั้นเป็น "ยอดที่แตะ tag" (touch) ซึ่งบวกข้าม tag ไม่ได้ และต้องส่งผ่านช่อง tag_ids ของ ADR 0002 · เอาน้ำหนักมาใส่จะทำให้ touch กับ allocated ปนกัน แล้วไม่มีใครรู้ว่าตัวเลขไหนหมายถึงอะไร (ADR 0003 ข้อ 5)',
      v_bad;
  end if;

  -- (ง) ชนิดข้อมูลของน้ำหนัก
  select string_agg(t.code || ' = ' || e.value::text, ' · ' order by t.code) into v_bad
    from jsonb_each(p_weights) as e(key, value)
    join sri_os.tags t on t.id = e.key::uuid
   where jsonb_typeof(e.value) not in ('number', 'null');
  if v_bad is not null then
    raise exception 'น้ำหนักของ tag ต้องเป็นตัวเลขสัดส่วน (0.6 = 60%%) — ได้ % · ส่งเป็นข้อความหรือรูปอื่นมาไม่ได้ เพราะการแปลงเองคือการเดาแทนผู้ใช้',
      v_bad;
  end if;

  -- (จ) **ไม่ส่งน้ำหนักมา**: ยอมเฉพาะกรณีที่มี tag เดียวบนใบนั้น
  select string_agg(t.code, ' · ' order by t.code) into v_bad
    from jsonb_each(p_weights) as e(key, value)
    join sri_os.tags t on t.id = e.key::uuid
   where jsonb_typeof(e.value) = 'null';
  if v_bad is not null and v_n > 1 then
    raise exception 'ไม่ได้ส่งน้ำหนักของ tag % มา ทั้งที่คำขอนี้มี tag ที่ปันส่วน % อัน → **ปฏิเสธ** · ข้อมูลไม่ครบต้องปฏิเสธ ไม่ใช่เดาให้เป็น 100%% หรือแบ่งเท่ากันเอง เพราะเดาผิดแปลว่ายอดต่อ project ผิดเงียบๆ · ประตูเติม 1.000000 ให้เองได้เฉพาะกรณีที่มี tag เดียว (คำตอบที่ถูกมีได้คำตอบเดียว)',
      v_bad, v_n;
  end if;

  -- (ฉ) ช่วงของน้ำหนัก + ความละเอียดไม่เกิน 6 ตำแหน่ง
  select string_agg(t.code || ' = ' || (e.value #>> '{}'), ' · ' order by t.code) into v_bad
    from jsonb_each(p_weights) as e(key, value)
    join sri_os.tags t on t.id = e.key::uuid
   where jsonb_typeof(e.value) = 'number'
     and ((e.value #>> '{}')::numeric <= 0 or (e.value #>> '{}')::numeric > 1);
  if v_bad is not null then
    raise exception 'น้ำหนักของ tag ต้องอยู่ในช่วง 0 < น้ำหนัก <= 1 — ได้ % · 0 ไม่มีความหมาย (ติด tag ไว้แล้วบอกว่าไม่เกี่ยว ให้ถอด tag แทน ซึ่งมีร่องรอยชัดกว่า) · เกิน 1 คือใบเดียวให้ project เกินตัวมันเอง',
      v_bad;
  end if;
  select string_agg(t.code || ' = ' || (e.value #>> '{}'), ' · ' order by t.code) into v_bad
    from jsonb_each(p_weights) as e(key, value)
    join sri_os.tags t on t.id = e.key::uuid
   where jsonb_typeof(e.value) = 'number'
     and (e.value #>> '{}')::numeric
         is distinct from round((e.value #>> '{}')::numeric, 6);
  if v_bad is not null then
    raise exception 'น้ำหนักของ tag ละเอียดเกิน 6 ตำแหน่ง: % → **ปฏิเสธ ไม่ปัดให้** · คอลัมน์เก็บได้ 6 ตำแหน่ง (numeric(9,6)) ถ้าประตูปัดให้เงียบๆ Σ ที่ผู้ใช้คิดไว้จะไม่ใช่ Σ ที่ลงจริง แล้วใบจะถูกปฏิเสธที่ด่าน Σ = 1 ด้วยเหตุผลที่คนกรอกอ่านไม่เข้าใจ',
      v_bad;
  end if;

  -- (ช) Σ ต่อชนิด = 1.000000 พอดี (ด่านจริงอยู่ที่ชั้นตาราง · ที่นี่เพื่อข้อความ)
  select string_agg(x.kind || ': Σ = ' || to_char(x.s, 'FM0.000000')
                    || ' (' || case when x.s < 1 then 'ขาด' else 'เกิน' end || ' '
                    || to_char(abs(x.s - 1), 'FM0.000000') || ') · ' || x.detail, ' · ')
    into v_bad
    from (
      select t.kind as kind,
             sum(coalesce((e.value #>> '{}')::numeric, 1.000000)) as s,
             string_agg(t.code || ' = '
                        || to_char(coalesce((e.value #>> '{}')::numeric, 1.000000),
                                   'FM0.000000'), ' · ' order by t.code) as detail
        from jsonb_each(p_weights) as e(key, value)
        join sri_os.tags t on t.id = e.key::uuid
       group by t.kind) x
   where x.s is distinct from 1.000000::numeric;
  if v_bad is not null then
    raise exception 'ยอดรวมน้ำหนักของ tag ต้องเป็น 1.000000 พอดีต่อชนิด — % · เทียบแบบ exact ไม่มี tolerance (numeric เป็นทศนิยมแม่นตรง และน้ำหนักเป็นค่าที่คนกรอก ไม่ใช่ผลหาร) · Σ น้อยกว่า 1 = เงินหายไปจากทุกรายงานต่อ project · Σ มากกว่า 1 = กำไรที่ไม่จริงออกมา **โดยที่งบดุลยังดุลสนิทและไม่มีตัวเลขในสมุดผิดเลย** จึงไม่มีด่านอื่นจับได้ (ADR 0003 ข้อ 4.1)',
      v_bad;
  end if;
end $fn$;

comment on function fn_assert_tag_weights_shape(jsonb) is
  'ADR 0003 ข้อ 6 · กฎ "รูปของชุดน้ำหนัก tag" **ที่เดียว** ที่ทั้ง fn_post_entry และ fn_reallocate_tags เรียก (กฎเดียวกันห้ามเขียนสองที่) · ตรวจ: เป็น object ไม่ว่าง · คีย์เป็น tag id · tag มีจริงในแค็ตตาล็อก · ชนิดต้อง requires_allocation · น้ำหนักเป็นตัวเลข 0 < w <= 1 · ละเอียดไม่เกิน 6 ตำแหน่ง (เกิน = ปฏิเสธ ไม่ปัดให้) · น้ำหนักที่ไม่ส่งมายอมได้เฉพาะกรณี tag เดียว (เติม 1.000000) · Σ ต่อชนิด = 1.000000 พอดี · **ไม่ตรวจ tags.is_active โดยเจตนา**: ห้ามติด tag ที่ปิดแล้ว **ใหม่** บังคับที่ fn_tag_link_system_columns บนตารางลิงก์ (ครอบการเขียนตรงด้วย) ส่วนการ **แก้สัดส่วนของ tag ที่ติดอยู่กับใบนั้นแล้ว** ต้องทำได้ต่อไปแม้ tag ถูกปิด ไม่งั้นใบนั้นติดค้างถาวรพร้อมสัดส่วนที่รู้อยู่ว่าผิด (บทเรียนผู้ตรวจข้อ 7) · **ไม่ใช่แหล่งความจริง** — ด่านจริงคือ trg_assert_tag_allocation_complete ที่ชั้นตาราง ซึ่งครอบการ INSERT ตรงด้วย';

revoke all on function fn_assert_tag_weights_shape(jsonb) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_tag_weights_shape(jsonb) from anon';
  execute 'grant execute on function sri_os.fn_assert_tag_weights_shape(jsonb) to authenticated';
end $$;

-- ============================================================
-- 1b · `fn_post_entry_accepted_tag_kinds` — **ชนิด tag ที่ลงผ่านประตูได้จริงวันนี้**
--
--   ฝั่งแอปต้องรู้ว่าชนิดไหน "มีช่องทางเข้าประตู" แล้ว เพื่อ **ไม่โชว์ช่องที่กด
--   บันทึกแล้วตาย** · กติกาของฝั่งแอปคือ "อ่านไม่ได้ = ซ่อน" จึงต้องมีฟังก์ชันนี้
--   ไม่งั้นฟอร์มซ่อน tag **ทุกชนิด** รวมชนิดที่ประตูรับอยู่แล้ว
--
--   **อ่านจากของจริง ไม่ใช่รายชื่อตายตัว**: ไล่ `c_header` (รายการช่องที่
--   `fn_post_entry` รับ) จาก `pg_get_functiondef` ของประตูเอง แล้วจับคู่กับคอนฟิก
--     ชนิดที่ `requires_allocation` → เข้าทางช่อง `tag_weights`
--     ชนิดที่ไม่ปันส่วน            → เข้าทางช่อง `tag_ids` (ADR 0002 ชิ้น 3)
--   วันที่ชิ้น 3 ของ ADR 0002 ลงแล้วประตูรับ `tag_ids` ด้วย ฟังก์ชันนี้จะเริ่มคืน
--   `label` **เอง** โดยไม่มีใครต้องมาแก้ → ถ้าตัดสินจากธง `requires_allocation`
--   เพียวๆ ฟอร์มจะซ่อน `label` ต่อไปตลอดกาลโดยไม่มีใครรู้
--
--   อ่าน `c_header` ไม่ออก = **พัง** ไม่ใช่คืนชุดว่าง (ชุดว่างแปลว่า "ไม่มีชนิดไหน
--   ลงได้" ซึ่งฟอร์มจะปิดทุกช่องทิ้งทั้งที่ของจริงลงได้ · หลักเดียวกับ check:sync
--   ที่ไม่ยอมผ่านด้วยชุดว่าง)
--
--   อ่านอย่างเดียว · **INVOKER** · อ่านแค่แค็ตตาล็อกชนิด (`tag_kinds`) ซึ่งเปิดให้
--   ทุกคนที่ล็อกอินอ่านอยู่แล้ว และ catalog ของฟังก์ชัน → ไม่มีอะไรรั่วเพิ่ม
-- ============================================================
create or replace function fn_post_entry_accepted_tag_kinds() returns text[]
language plpgsql stable set search_path = '' as $fn$
declare
  c_q      constant text := chr(39);   -- เครื่องหมายคำพูดเดี่ยว (ใช้ล้อมชื่อช่องใน c_header)
  v_def    text;
  v_header text;
  v_kinds  text[];
begin
  if to_regprocedure('sri_os.fn_post_entry(jsonb)') is null then
    raise exception 'ไม่มีประตู fn_post_entry ในฐานข้อมูลนี้ → ตอบไม่ได้ว่าชนิด tag ไหนลงได้ · ปฏิเสธไว้ก่อน ไม่คืนชุดว่าง (ชุดว่างแปลว่า "ไม่มีชนิดไหนลงได้" ซึ่งฟอร์มจะซ่อนทุกช่องทิ้งทั้งที่ของจริงอาจลงได้)';
  end if;

  v_def := pg_get_functiondef('sri_os.fn_post_entry(jsonb)'::regprocedure);
  -- รายการช่องของประตูอยู่ **ในตัวฟังก์ชัน** (ค่าคงที่ c_header) → อ่านจากนิยามจริง
  v_header := substring(v_def from 'c_header[^:]*:=\s*array\[(.*?)\]\s*;');
  if v_header is null or btrim(v_header) = '' then
    raise exception 'อ่านรายการช่องของประตู (c_header ใน fn_post_entry) ไม่ออก → ตอบไม่ได้ว่าชนิด tag ไหนลงผ่านประตูได้ · **ปฏิเสธไว้ก่อน ไม่คืนชุดว่าง** · ถ้าประตูถูกเขียนใหม่ด้วยรูปอื่น (เช่นย้ายรายการช่องไปเก็บในตาราง) ต้องแก้ฟังก์ชันนี้ให้อ่านจากที่ใหม่ ไม่ใช่เขียนรายชื่อชนิดตายตัวไว้ที่นี่ (รายชื่อตายตัวจะค้างล้าสมัยเงียบๆ เหมือนจำนวนผังบัญชีในเอกสาร)';
  end if;

  select array_agg(k.key order by k.sort_order, k.key) into v_kinds
    from sri_os.tag_kinds k
   where k.is_active
     and position(c_q
                  || case when k.requires_allocation then 'tag_weights' else 'tag_ids' end
                  || c_q
                  in v_header) > 0;

  return coalesce(v_kinds, '{}'::text[]);
end $fn$;

comment on function fn_post_entry_accepted_tag_kinds() is
  'ชนิด tag ที่ **ลงผ่าน fn_post_entry ได้จริงวันนี้** (ADR 0003 ข้อ 6 · ADR 0002 ชิ้น 3 ยังไม่ลง ณ 28/10) · ตัดสินจาก **การมีอยู่จริงของช่องใน c_header ของประตู** ที่อ่านจาก pg_get_functiondef ไม่ใช่จากธง requires_allocation เพียวๆ และไม่ใช่รายชื่อตายตัว → วันที่ประตูรับ tag_ids ฟังก์ชันนี้จะคืน label เองโดยไม่มีใครต้องแก้ · อ่าน c_header ไม่ออก = **พัง** ไม่คืนชุดว่าง (ชุดว่าง = ฟอร์มซ่อนทุกชนิดทั้งที่ของจริงลงได้) · อ่านอย่างเดียว · INVOKER · มีไว้ให้ฟอร์มปิดช่องที่ประตูยังไม่รับ แทนที่จะโชว์แล้วไปตายตอนกดบันทึก';

revoke all on function fn_post_entry_accepted_tag_kinds() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_post_entry_accepted_tag_kinds() from anon';
  execute 'grant execute on function sri_os.fn_post_entry_accepted_tag_kinds() to authenticated';
end $$;

-- ============================================================
-- 2 · `fn_tag_counter_legs` — ใบที่ต้องขยับพร้อมกัน (ADR 0003 ข้อ 4.2.2)
--
--   คืน **ทุกใบ** ที่น้ำหนักต้องเปลี่ยนพร้อมกัน (รวมใบที่ส่งมาเอง)
--   - ใบปกติ → ใบเดียว
--   - ใบข้ามผู้ถือ → ใบนั้น + ขาคู่ของมัน
--
--   เกณฑ์หาขาคู่ **ชุดเดียวกับด่าน `fn_assert_intercompany_pair`**: ผู้ถือสลับกับ
--   `counter_owner_id` · ลักษณะเดียวกัน · หมวดเดียวกัน · วันที่เอกสารเดียวกัน ·
--   **ยอดเดบิตรวมเท่ากัน** → ไม่มีเกณฑ์ชุดที่สองที่คิดต่างจากด่าน
--
--   อ่านผ่าน `v_ledger_posted` (security invoker) โดยเจตนา: ถ้าผู้เรียกมองขาคู่
--   ไม่เห็น ก็ต้องแก้สัดส่วนไม่ได้ (fail closed) · ใบที่ยกเลิกแล้วไม่อยู่ในนั้น
--
--   **เจอหลายใบที่เข้าเกณฑ์เท่ากัน → ปฏิเสธ** ไม่ใช่หยิบใบแรก: ถ้ามีคู่เหมือนกัน
--   สองคู่ในวันเดียว การเดาผิดแปลว่าแก้สัดส่วนของคู่อื่นไปโดยไม่มีใครรู้
-- ============================================================
create or replace function fn_tag_counter_legs(p_transaction_id uuid) returns uuid[]
language plpgsql stable set search_path = '' as $fn$
declare
  v_self  record;
  v_other uuid[];
begin
  select v.owner_id, v.counter_owner_id, v.intercompany_nature,
         v.txn_type_code, v.doc_date, sum(v.debit) as amt
    into v_self
    from sri_os.v_ledger_posted v
   where v.transaction_id = p_transaction_id
   group by v.owner_id, v.counter_owner_id, v.intercompany_nature,
            v.txn_type_code, v.doc_date;
  if v_self.owner_id is null then
    raise exception 'ไม่พบใบ % ในสมุดที่คุณมีสิทธิ์เห็น → แก้สัดส่วนไม่ได้ · ใบที่ยกเลิกแล้วและใบของผู้ถือที่คุณมองไม่เห็นก็อยู่ในกรณีนี้ (ปฏิเสธไว้ก่อน ดีกว่าแก้ของที่ตัวเองตรวจไม่ได้)',
      p_transaction_id;
  end if;

  if v_self.counter_owner_id is null then
    return array[p_transaction_id];
  end if;

  select array_agg(x.transaction_id order by x.transaction_id) into v_other
    from (
      select v.transaction_id, sum(v.debit) as amt
        from sri_os.v_ledger_posted v
       where v.is_intercompany
         and v.transaction_id <> p_transaction_id
         and v.intercompany_nature = v_self.intercompany_nature
         and v.txn_type_code       = v_self.txn_type_code
         and v.doc_date            = v_self.doc_date
         and v.owner_id            = v_self.counter_owner_id
         and v.counter_owner_id    = v_self.owner_id
       group by v.transaction_id) x
   where x.amt = v_self.amt;

  if v_other is null or array_length(v_other, 1) = 0 then
    raise exception 'หา **ขาคู่** ของใบ % ไม่เจอ (รายการข้ามผู้ถือลักษณะ "%" ยอด % ของวันที่ %) → ปฏิเสธ · รายการข้ามผู้ถือเป็นสองใบคู่กัน (กฎเหล็กข้อ 4) ถ้าแก้น้ำหนักข้างเดียว แต่ละขายังดุลในตัวเองและผลรวมข้าม tag ยังตรงสมุด **จึงไม่มีด่านไหนจับได้** แต่ยอดต่อ project ของคู่นั้นจะไม่สมมาตร (ขาหนึ่งนับเข้า project A 60%% อีกขานับ 40%% ทั้งที่เป็นเงินก้อนเดียวกันที่ย้ายข้ามกระเป๋า) · ถ้าขาคู่อยู่กับผู้ถือที่คุณมองไม่เห็น ต้องให้คนที่เห็นทั้งสองฝ่ายเป็นคนแก้',
      p_transaction_id, v_self.intercompany_nature, v_self.amt, v_self.doc_date;
  end if;
  if array_length(v_other, 1) > 1 then
    raise exception 'เจอ **ขาคู่** ของใบ % มากกว่าหนึ่งใบ (%) → ปฏิเสธ · มีคู่ที่เหมือนกันทุกเกณฑ์ (ลักษณะ หมวด วันที่ ยอด) มากกว่าหนึ่งคู่ในวันเดียว การหยิบใบแรกมาแก้คือการเดา ซึ่งถ้าเดาผิดจะไปแก้สัดส่วนของอีกคู่โดยไม่มีใครรู้ · ให้แก้ด้วย memo/เลขเอกสารที่แยกคู่ออกจากกันได้ก่อน',
      p_transaction_id, array_to_string(v_other, ', ');
  end if;

  return array[p_transaction_id] || v_other;
end $fn$;

comment on function fn_tag_counter_legs(uuid) is
  'ADR 0003 ข้อ 4.2.2 · ใบทุกใบที่น้ำหนัก tag ต้องเปลี่ยนพร้อมกัน (ใบนั้น + ขาคู่ถ้าเป็นรายการข้ามผู้ถือ) · เกณฑ์หาขาคู่ชุดเดียวกับ fn_assert_intercompany_pair (ผู้ถือสลับกับ counter_owner_id · ลักษณะ · หมวด · วันที่ · ยอดเดบิตรวมเท่ากัน) · อ่านผ่าน v_ledger_posted แบบ invoker → มองขาคู่ไม่เห็นก็แก้ไม่ได้ (fail closed) · หาไม่เจอหรือเจอหลายใบ = **ปฏิเสธ** ไม่ใช่เดา';

revoke all on function fn_tag_counter_legs(uuid) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_tag_counter_legs(uuid) from anon';
  execute 'grant execute on function sri_os.fn_tag_counter_legs(uuid) to authenticated';
end $$;

-- ============================================================
-- 3 · `fn_reallocate_tags` — แก้สัดส่วนย้อนหลังแบบมีร่องรอย (ADR 0003 ข้อ 3.3 · 6)
-- ============================================================
create or replace function fn_reallocate_tags(
  p_transaction_id uuid,
  p_kind           text,
  p_weights        jsonb,
  p_reason         text
) returns jsonb
language plpgsql set search_path = '' as $fn$
declare
  v_legs    uuid[];
  v_counter uuid;
  v_leg     uuid;
  v_tag     uuid;
  v_w       text;
  v_link    uuid;
  v_closed  int := 0;
  v_opened  int := 0;
  v_bad     text;
begin
  if auth.uid() is null then
    raise exception 'แก้สัดส่วน tag ไม่ได้: ยังไม่ได้ล็อกอิน';
  end if;
  if p_transaction_id is null then
    raise exception 'แก้สัดส่วน tag ไม่ได้: ไม่ได้ส่งใบที่จะแก้มา';
  end if;

  -- (ก) เหตุผล **บังคับ** เหมือน untag_reason/void_reason
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'แก้สัดส่วน tag ไม่ได้: ต้องกรอก **เหตุผล** · กำไรต่อ project ที่เคยรายงานไปแล้วคิดจากน้ำหนักชุดเดิม ถ้าแก้ได้โดยไม่มีเหตุผลติดไว้ จะไม่มีใครอธิบายได้ว่าทำไมตัวเลขเดือนที่แล้วเปลี่ยน (ADR 0003 ข้อ 3.3)';
  end if;

  -- (ข) ชนิดต้องมีจริงและต้องเป็นชนิดที่ **ปันส่วน**
  if p_kind is null or not exists (select 1 from sri_os.tag_kinds k where k.key = p_kind) then
    raise exception 'แก้สัดส่วน tag ไม่ได้: ไม่มีชนิด tag "%" ในคอนฟิก', p_kind;
  end if;
  if not exists (select 1 from sri_os.tag_kinds k
                  where k.key = p_kind and k.requires_allocation) then
    raise exception 'แก้สัดส่วน tag ไม่ได้: ชนิด "%" ไม่ใช่ชนิดที่ **ปันส่วน** (tag_kinds.requires_allocation = false) จึงไม่มีน้ำหนักให้แก้ · ยอดของชนิดนี้เป็น "ยอดที่แตะ tag" (touch) ซึ่งบวกข้าม tag ไม่ได้ · ถ้าจะเอา/เอาออก ให้ติด/ถอด tag แทน (ADR 0003 ข้อ 5)',
      p_kind;
  end if;

  -- (ค) รูปของชุดน้ำหนัก — **ฟังก์ชันตัวเดียวกับที่ประตูเรียก**
  perform sri_os.fn_assert_tag_weights_shape(p_weights);

  -- ทุก tag ในชุดต้องเป็นชนิดที่ขอแก้ (ส่งชนิดอื่นปนมา = ผู้เรียกเข้าใจผิด)
  select string_agg(t.code || ' (ชนิด ' || t.kind || ')', ', ' order by t.code) into v_bad
    from jsonb_object_keys(p_weights) as k
    join sri_os.tags t on t.id = k::uuid
   where t.kind <> p_kind;
  if v_bad is not null then
    raise exception 'แก้สัดส่วน tag ไม่ได้: ชุดน้ำหนักมี tag ของชนิดอื่นปนมา (%) ขณะที่กำลังแก้ชนิด "%" · Σ = 1 คิดต่อชนิด การปนชนิดทำให้ไม่รู้ว่า Σ ของชนิดไหนครบ',
      v_bad, p_kind;
  end if;

  -- (ง) **ต้องครอบทั้งคู่ของรายการข้ามผู้ถือ** (ADR 0003 ข้อ 4.2.2 ชั้น 2)
  v_legs := sri_os.fn_tag_counter_legs(p_transaction_id);

  -- **ไม่เชื่อผลของตัวหา**: ถ้าใบนี้เป็นรายการข้ามผู้ถือ ชุดที่ได้กลับมา
  -- ต้องมีใบของผู้ถืออีกฝ่ายอยู่จริง · ถ้าตัวหาถูกแก้/ถอยรุ่นวันหนึ่ง
  -- การแก้ข้างเดียวต้องพังเสียงดัง ไม่ใช่ผ่านเงียบ (เทสต์ M3 วัดข้อนี้)
  select v.counter_owner_id into v_counter
    from sri_os.v_ledger_posted v
   where v.transaction_id = p_transaction_id and v.is_intercompany
   limit 1;
  if v_counter is not null
     and not exists (select 1 from sri_os.v_ledger_posted v
                      where v.transaction_id = any (v_legs)
                        and v.owner_id = v_counter) then
    raise exception 'แก้สัดส่วน tag ไม่ได้: ใบ % เป็นรายการข้ามผู้ถือ แต่ชุดใบที่จะแก้ไม่มี **ขาคู่** ของผู้ถืออีกฝ่ายอยู่เลย → ปฏิเสธ · แก้ข้างเดียวจะผ่านโดยไม่มีด่านไหนจับ (แต่ละขายังดุลในตัวเองและผลรวมข้าม tag ยังตรงสมุด) แล้วยอดต่อ project ของคู่นั้นจะไม่สมมาตร (ADR 0003 ข้อ 4.2.2)',
      p_transaction_id;
  end if;

  -- (จ) ชุดน้ำหนักต้องครอบ tag ที่ติดอยู่ **ครบทุกอัน** ของทุกขา
  foreach v_leg in array v_legs loop
    select string_agg(t.code, ' · ' order by t.code) into v_bad
      from sri_os.transaction_tags l
      join sri_os.tags t on t.id = l.tag_id
     where l.transaction_id = v_leg
       and l.tag_kind = p_kind
       and l.untagged_at is null
       and not (p_weights ? l.tag_id::text);
    if v_bad is not null then
      raise exception 'แก้สัดส่วน tag ไม่ได้: ใบ % ติด tag % อยู่ แต่ชุดน้ำหนักที่ส่งมาไม่ได้พูดถึงมัน → ต้องส่งน้ำหนักของ tag ที่ติดอยู่ให้ **ครบทุกอัน** · ถ้าจะเอา tag นั้นออก ให้ถอด tag (ซึ่งต้องมีเหตุผลและเหลือร่องรอย) ไม่ใช่ปล่อยให้มันหายจากชุดน้ำหนักเงียบๆ แล้วค้างเป็นลิงก์ที่ไม่มีสัดส่วน',
        v_leg, v_bad;
    end if;

    select string_agg(t.code, ' · ' order by t.code) into v_bad
      from jsonb_object_keys(p_weights) as k
      join sri_os.tags t on t.id = k::uuid
     where not exists (select 1 from sri_os.transaction_tags l
                        where l.transaction_id = v_leg
                          and l.tag_id = k::uuid
                          and l.untagged_at is null);
    if v_bad is not null then
      raise exception 'แก้สัดส่วน tag ไม่ได้: ชุดน้ำหนักพูดถึง tag % ซึ่งใบ % ไม่ได้ติดอยู่ · ฟังก์ชันนี้แก้สัดส่วนของ tag ที่ติดอยู่แล้วเท่านั้น ไม่ใช่ประตูสำหรับติด tag ใหม่ (ติด tag มีร่องรอยของตัวเองที่ต้องผ่าน)',
        v_bad, v_leg;
    end if;
  end loop;

  -- (ฉ) ปิดชุดเดิม + เปิดชุดใหม่ **ในธุรกรรมเดียว** (ข้อ 3.3)
  foreach v_leg in array v_legs loop
    update sri_os.tag_allocations a
       set superseded_at    = now(),
           superseded_by    = auth.uid(),
           supersede_reason = p_reason
     where a.superseded_at is null
       and a.transaction_tag_id in (
             select l.id from sri_os.transaction_tags l
              where l.transaction_id = v_leg
                and l.tag_kind = p_kind
                and l.untagged_at is null);
    v_closed := v_closed + coalesce((select count(*) from sri_os.tag_allocations a
                                      where a.superseded_at is not null
                                        and a.supersede_reason = p_reason
                                        and a.transaction_tag_id in (
                                              select l.id from sri_os.transaction_tags l
                                               where l.transaction_id = v_leg)), 0);

    for v_tag, v_w in
      select e.key::uuid, e.value #>> '{}'
        from jsonb_each(p_weights) as e(key, value)
       order by e.key
    loop
      select l.id into v_link
        from sri_os.transaction_tags l
       where l.transaction_id = v_leg and l.tag_id = v_tag and l.untagged_at is null;
      insert into sri_os.tag_allocations (transaction_tag_id, weight)
      values (v_link, coalesce(v_w, '1.000000')::numeric);
      v_opened := v_opened + 1;
    end loop;
  end loop;

  -- ด่าน Σ = 1 เป็น constraint trigger แบบ deferred → บังคับให้ยิง **เดี๋ยวนี้**
  -- เพื่อให้คนกดได้ข้อความที่อ่านรู้เรื่องทันที แล้วคืนสภาพ deferred ให้เหมือนเดิม
  -- (ทำให้ด่าน **เข้มขึ้น** ไม่ใช่ผ่อน · รูปเดียวกับที่ fn_post_entry ทำ)
  set constraints all immediate;
  set constraints all deferred;

  return jsonb_build_object(
    'transaction_ids', to_jsonb(v_legs),
    'kind', p_kind,
    'superseded', v_closed,
    'allocated', v_opened);
end $fn$;

comment on function fn_reallocate_tags(uuid, text, jsonb, text) is
  'ADR 0003 ข้อ 3.3 · 6 · 4.2.2 · แก้สัดส่วน tag ย้อนหลัง = **ปิดชุดเดิม (superseded_at/by/reason) + เปิดชุดใหม่ในธุรกรรมเดียว** ไม่มี UPDATE weight · p_reason บังคับ (ว่างไม่ได้) · security **INVOKER** → ขอบเขตของ RLS เป็นด่าน และมองขาคู่ไม่เห็นก็แก้ไม่ได้ · **ครอบทั้งสองขาของรายการข้ามผู้ถือ** ด้วย fn_tag_counter_legs และ **ไม่เชื่อผลของตัวหา** (ถ้าชุดที่ได้ไม่มีขาของผู้ถืออีกฝ่าย = ปฏิเสธ) เพราะแก้ข้างเดียวจะผ่านโดยไม่มีด่านไหนจับ · ชุดน้ำหนักต้องครอบ tag ที่ติดอยู่ครบทุกอันของทุกขา และต้องไม่พูดถึง tag ที่ไม่ได้ติด (ฟังก์ชันนี้ไม่ใช่ประตูติด tag) · กฎรูปน้ำหนักเรียก fn_assert_tag_weights_shape ตัวเดียวกับประตู';

revoke all on function fn_reallocate_tags(uuid, text, jsonb, text) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_reallocate_tags(uuid, text, jsonb, text) from anon';
  execute 'grant execute on function sri_os.fn_reallocate_tags(uuid, text, jsonb, text) to authenticated';
end $$;

-- ============================================================
-- 4 · `fn_post_entry` — **รุ่นเดียวกับ 20261025000004 ทุกตัวอักษร + ช่อง `tag_weights`**
--
--   ลอกมาทั้งฟังก์ชันเพราะ `c_header` (รายการช่องที่รับ) อยู่ **ในตัวฟังก์ชัน**
--   → เพิ่มช่องใหม่โดยไม่ลอกทั้งก้อนไม่ได้ · รูปแบบเดียวกับที่ 20261025000001
--   (WHT) และ 20261025000004 (FCD) ทำมาก่อน
--
--   สิ่งที่ต่างจากรุ่นก่อนมี **สามจุดเท่านั้น** (หาด้วยการ diff ได้):
--     1. `c_header` มี `'tag_weights'`
--     2. ข้อ 3.5 · เรียก `fn_assert_tag_weights_shape()` ตรวจรูปก่อนเขียนอะไร
--     3. ข้อ 6.1 · เขียนลิงก์ + น้ำหนักให้ **ทุกใบในคำขอ** หลังบรรทัดบัญชีถูกเขียนครบ
--   ไม่มีการแก้กฎบัญชี/ด่านเดิมแม้บรรทัดเดียว
-- ============================================================

create or replace function fn_post_entry(p_payload jsonb) returns jsonb
language plpgsql set search_path = '' as $fn$
declare
  c_header constant text[] := array[
    'txn_type_code', 'doc_date', 'cash_date', 'doc_no', 'memo', 'attachments',
    'asset_id', 'contact_id', 'contract_id', 'owner_reason', 'funding_source',
    'source', 'source_ref', 'reverses_id',
    -- D-111 ข้อ 1 · ภาษีหัก ณ ที่จ่าย — **สามช่องนี้คือสิ่งที่ไฟล์นี้เพิ่ม**
    -- ก่อนหน้านี้ส่งมาไม่ได้เลย (เด้ง "ช่องที่ยังไม่รู้จัก") และถ้าไม่ส่ง
    -- หัวรายการจะเป็น null แล้ว fn_assert_wht_gross ปฏิเสธตอน commit
    -- → บันทึกการถูกหักภาษี **ตันทั้งสองทาง**
    'wht_rate', 'wht_amount', 'wht_certificate_no',
    -- ADR 0003 ข้อ 6 · **ช่องที่ไฟล์นี้เพิ่ม** — น้ำหนักของ tag ชนิดที่ปันส่วน
    -- รูป {"<tag_id>": น้ำหนัก} · ส่ง null มาได้เฉพาะกรณีที่มี tag เดียวบนใบนั้น
    -- (ประตูเติม 1.000000 ให้ ซึ่งไม่ใช่การเดาเพราะมีคำตอบที่ถูกได้คำตอบเดียว)
    -- **หมายเหตุลำดับงาน**: ช่อง `tag_ids` ของ ADR 0002 ข้อ 7 (ชนิดที่ไม่ปันส่วน)
    -- ยังไม่ได้ลง ณ 28/10 (ชิ้น 3 ของ ADR 0002) · ไฟล์ที่ลงมันต้อง **เพิ่ม** ชื่อช่อง
    -- เข้า c_header นี้โดยคง 'tag_weights' ไว้ ไม่ใช่เขียนทับฟังก์ชันด้วยรุ่นที่ไม่มีมัน
    -- (ไม่งั้นบันทึกน้ำหนักจากหน้าจอจะตันเงียบๆ อีกรอบ) · guard ท้ายไฟล์นี้
    -- ตรวจว่า fn_post_entry ยังรู้จัก tag_weights อยู่
    'tag_weights',
    'transactions'];
  c_txn    constant text[] := array['owner_id', 'counter_owner_id', 'intercompany_nature', 'lines'];
  c_line   constant text[] := array['coa_code', 'bank_account_id', 'asset_id',
                                    'debit', 'credit', 'cf_category', 'memo',
                                    -- FCD (25/10) · ข้อมูลสกุลเดิมของบรรทัด
                                    -- ยอดบาทยังอยู่ที่ debit/credit เหมือนเดิมทุกบรรทัด
                                    'currency', 'amount_original', 'fx_rate', 'fx_rate_date'];
  v_bad      text;
  v_source   text;
  v_has_cash boolean := false;
  v_i        int := 0;
  v_j        int;
  v_dr       numeric;
  v_cr       numeric;
  v_txn      jsonb;
  v_line     jsonb;
  v_coa      uuid;
  v_txn_id   uuid;
  v_ids      uuid[] := '{}';
  v_prev     uuid[];
  v_fp       text;
  v_canon    jsonb;
  v_secs     numeric;
  v_req      uuid;
  v_doc      date;
  v_cash     date;
  v_wht_rate numeric;
  v_wht_amt  numeric;
  v_wht_cert text;
  v_num      text;
  v_fxdate   date;
  v_allowed  text[];
  v_nature   text;
  -- ADR 0003 ชิ้น A4 · tag ที่ปันส่วน
  v_tw       jsonb;
  v_tw_n     int;
  v_tw_tag   uuid;
  v_tw_w     text;
  v_tw_link  uuid;
  v_leg      int;
begin
  -- ========== 0 · ไม่ส่งข้อมูลมาเลย = ปฏิเสธ ห้ามตกไปเส้นทางปกติ (บทเรียนข้อ 1) ==========
  if p_payload is null or jsonb_typeof(p_payload) = 'null' then
    raise exception 'บันทึกรายการไม่ได้: ไม่ได้ส่งข้อมูลรายการมาเลย';
  end if;
  if jsonb_typeof(p_payload) <> 'object' then
    raise exception 'บันทึกรายการไม่ได้: รูปแบบข้อมูลไม่ถูกต้อง — ต้องเป็น object ของทั้งใบ ไม่ใช่ %',
      jsonb_typeof(p_payload);
  end if;

  select string_agg(k, ', ' order by k) into v_bad
    from jsonb_object_keys(p_payload) as k where k <> all (c_header);
  if v_bad is not null then
    raise exception 'บันทึกรายการไม่ได้: มีช่องที่ยังไม่รู้จัก (%) — RPC ปฏิเสธทั้งใบแทนที่จะทิ้งช่องนั้นเงียบๆ · ช่องที่รับคือ %',
      v_bad, array_to_string(c_header, ', ');
  end if;

  -- ========== 1 · ผู้เรียกต้องมีตัวตนในระบบ ==========
  if auth.uid() is null then
    raise exception 'บันทึกรายการไม่ได้: ยังไม่ได้ล็อกอิน';
  end if;
  if not exists (select 1 from sri_os.app_users u where u.id = auth.uid() and u.is_active) then
    raise exception 'บันทึกรายการไม่ได้: ผู้ใช้นี้ยังไม่ได้ถูกตั้งตำแหน่งในระบบ หรือถูกปิดใช้งานแล้ว';
  end if;

  -- ========== 2 · ช่องบังคับของหัวรายการ ==========
  if nullif(p_payload ->> 'txn_type_code', '') is null then
    raise exception 'บันทึกรายการไม่ได้: ไม่ได้ส่ง txn_type_code (หมวดย่อยของรายการ)';
  end if;
  if not exists (select 1 from sri_os.txn_types t where t.code = p_payload ->> 'txn_type_code') then
    raise exception 'บันทึกรายการไม่ได้: ไม่มีหมวด "%" ในตารางกฎ (txn_types) — ตารางกฎคือแหล่งความจริงเดียว ถ้าเพิ่มหมวดใหม่ให้ sync ด้วย npm run sync:rules',
      p_payload ->> 'txn_type_code';
  end if;
  if nullif(p_payload ->> 'doc_date', '') is null then
    raise exception 'บันทึกรายการไม่ได้: ไม่ได้ส่ง doc_date (วันที่เอกสาร)';
  end if;

  -- วันที่: แปลงที่นี่ครั้งเดียว เพื่อให้ได้ข้อความภาษาคนแทน error ดิบของการ cast
  -- และเพื่อให้ "2026-09-01" กับรูปอื่นของวันเดียวกันได้ fingerprint เดียวกัน (ข้อ 4)
  begin
    v_doc := (p_payload ->> 'doc_date')::date;
  exception when others then
    raise exception 'บันทึกรายการไม่ได้: doc_date "%" ไม่ใช่วันที่ที่อ่านได้ (ต้องเป็น YYYY-MM-DD)',
      p_payload ->> 'doc_date';
  end;
  if nullif(p_payload ->> 'cash_date', '') is not null then
    begin
      v_cash := (p_payload ->> 'cash_date')::date;
    exception when others then
      raise exception 'บันทึกรายการไม่ได้: cash_date "%" ไม่ใช่วันที่ที่อ่านได้ (ต้องเป็น YYYY-MM-DD)',
        p_payload ->> 'cash_date';
    end;
  end if;

  v_source := coalesce(nullif(p_payload ->> 'source', ''), 'manual');
  if not exists (
       select 1 from pg_catalog.pg_enum e
         join pg_catalog.pg_type t on t.oid = e.enumtypid
         join pg_catalog.pg_namespace n on n.oid = t.typnamespace
        where n.nspname = 'sri_os' and t.typname = 'txn_source' and e.enumlabel = v_source) then
    raise exception 'บันทึกรายการไม่ได้: source "%" ไม่รู้จัก', v_source;
  end if;

  if p_payload -> 'attachments' is not null
     and jsonb_typeof(p_payload -> 'attachments') <> 'array' then
    raise exception 'บันทึกรายการไม่ได้: attachments ต้องเป็น array ของชื่อไฟล์';
  end if;

  -- ========== 2.1 · ภาษีหัก ณ ที่จ่าย (D-111 ข้อ 1) ==========
  -- ตรวจ **รูปของข้อมูล** ที่นี่เพื่อให้ได้ข้อความภาษาคนแทน error ดิบของ constraint
  -- ส่วนกฎบัญชี ("เงินได้ต้องเป็นยอดเต็ม") อยู่ที่ fn_assert_wht_gross_for() ที่เดียว
  -- ซึ่งอ่านทุกบรรทัดของใบตอน commit — **ไม่ได้ทำสำเนากฎไว้ในประตู** (บทเรียนข้อ 5)
  if (p_payload -> 'wht_rate') is not null
     and jsonb_typeof(p_payload -> 'wht_rate') not in ('number', 'null') then
    raise exception 'บันทึกรายการไม่ได้: wht_rate ต้องเป็นตัวเลข (ร้อยละ) ไม่ใช่ %',
      jsonb_typeof(p_payload -> 'wht_rate');
  end if;
  if (p_payload -> 'wht_amount') is not null
     and jsonb_typeof(p_payload -> 'wht_amount') not in ('number', 'null') then
    raise exception 'บันทึกรายการไม่ได้: wht_amount ต้องเป็นตัวเลข (บาท) ไม่ใช่ %',
      jsonb_typeof(p_payload -> 'wht_amount');
  end if;
  v_wht_rate := (p_payload ->> 'wht_rate')::numeric;
  v_wht_amt  := (p_payload ->> 'wht_amount')::numeric;
  v_wht_cert := nullif(btrim(coalesce(p_payload ->> 'wht_certificate_no', '')), '');

  -- อัตรากับยอดต้องมาคู่กันเสมอ (constraint transactions_wht_shape กันไว้อีกชั้น
  -- แต่ข้อความของ constraint อ่านไม่รู้เรื่องสำหรับคนกดปุ่ม)
  if (v_wht_rate is null) <> (v_wht_amt is null) then
    raise exception 'บันทึกรายการไม่ได้: ภาษีหัก ณ ที่จ่ายต้องส่งทั้งอัตรา (wht_rate) และยอดที่ถูกหัก (wht_amount) คู่กัน — มียอดแต่ไม่มีอัตราจะตรวจกับใบรับรองไม่ได้ · มีอัตราแต่ไม่มียอดจะไม่รู้ว่าสินทรัพย์ภาษีเป็นเท่าไร';
  end if;
  if v_wht_cert is not null and v_wht_amt is null then
    raise exception 'บันทึกรายการไม่ได้: ส่งเลขที่ใบรับรองการหักภาษีมาแต่ใบนี้ไม่ได้ถูกหักภาษี — เลขที่ใบรับรองติดได้เฉพาะใบที่ถูกหักจริง';
  end if;

  if p_payload -> 'transactions' is null then
    raise exception 'บันทึกรายการไม่ได้: ไม่ได้ส่ง transactions (ผลลัพธ์จาก buildPosting)';
  end if;
  if jsonb_typeof(p_payload -> 'transactions') <> 'array' then
    raise exception 'บันทึกรายการไม่ได้: transactions ต้องเป็น array (หนึ่งสมาชิก = หนึ่งผู้ถือ)';
  end if;
  if jsonb_array_length(p_payload -> 'transactions') = 0 then
    raise exception 'บันทึกรายการไม่ได้: ไม่มีรายการใน transactions เลย';
  end if;

  -- ========== 3 · ตรวจรูปของทุกรายการ/ทุกบรรทัด **ก่อนเขียนอะไรลงไป** ==========
  for v_txn in select value from jsonb_array_elements(p_payload -> 'transactions') loop
    v_i := v_i + 1;
    if jsonb_typeof(v_txn) <> 'object' then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ต้องเป็น object', v_i;
    end if;

    select string_agg(k, ', ' order by k) into v_bad
      from jsonb_object_keys(v_txn) as k where k <> all (c_txn);
    if v_bad is not null then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % มีช่องที่ยังไม่รู้จัก (%) · ช่องที่รับคือ %',
        v_i, v_bad, array_to_string(c_txn, ', ');
    end if;

    if nullif(v_txn ->> 'owner_id', '') is null then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ไม่ได้ส่ง owner_id (ผู้ถือ) — หนึ่งรายการ = หนึ่งผู้ถือ เดาแทนไม่ได้', v_i;
    end if;

    -- ข้ามผู้ถือต้องมาเป็นคู่: ขาดข้างใดข้างหนึ่งแปลว่าข้อมูลไม่ครบ ไม่ใช่รายการธรรมดา
    if nullif(v_txn ->> 'counter_owner_id', '') is not null
       and nullif(v_txn ->> 'intercompany_nature', '') is null then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % เป็นรายการข้ามผู้ถือ ต้องระบุลักษณะ (intercompany_nature: advance/loan/capital/dividend)', v_i;
    end if;
    if nullif(v_txn ->> 'intercompany_nature', '') is not null
       and nullif(v_txn ->> 'counter_owner_id', '') is null then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ระบุลักษณะข้ามผู้ถือแต่ไม่มีผู้ถืออีกฝ่าย (counter_owner_id)', v_i;
    end if;
    if nullif(v_txn ->> 'counter_owner_id', '') is not null
       and (v_txn ->> 'counter_owner_id') = (v_txn ->> 'owner_id') then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ระบุผู้ถืออีกฝ่ายเป็นคนเดียวกับผู้ถือของรายการ — ถ้าเป็นการย้ายกระเป๋าในคนเดียวกัน ไม่ใช่รายการข้ามผู้ถือ', v_i;
    end if;

    if v_txn -> 'lines' is null or jsonb_typeof(v_txn -> 'lines') <> 'array' then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ไม่ได้ส่ง lines เป็น array', v_i;
    end if;
    if jsonb_array_length(v_txn -> 'lines') < 2 then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % มีบรรทัดบัญชี % บรรทัด — บัญชีสองด้านต้องมีอย่างน้อยสองบรรทัด',
        v_i, jsonb_array_length(v_txn -> 'lines');
    end if;

    -- ---------- 3.1 ชุดบัญชีที่หมวดนี้ใช้ได้ — อ่านจากตารางกฎ ไม่ได้คิดเอง (ข้อ 3) ----------
    select array_remove(array[t.dr_coa_code, t.cr_coa_code, t.gain_coa_code,
                              t.loss_coa_code, t.interest_coa_code, t.accrual_coa_code], null)
      into v_allowed
      from sri_os.txn_types t where t.code = p_payload ->> 'txn_type_code';
    if v_allowed is null or cardinality(v_allowed) = 0 then
      raise exception 'บันทึกรายการไม่ได้: ตารางกฎ (txn_types) ไม่ได้ระบุบัญชีของหมวด "%" เลย — sync ด้วย npm run sync:rules ก่อน ห้ามเดาคู่บัญชีแทน',
        p_payload ->> 'txn_type_code';
    end if;

    -- ---------- 3.2 ลักษณะข้ามผู้ถือต้องเป็นลักษณะที่ฝั่ง DB รู้จัก (ห้ามเดา) ----------
    -- **ไม่มีสำเนาคู่บัญชีในฟังก์ชันนี้แล้ว** — อ่านจาก fn_intercompany_pairs() ที่เดียว
    --   ด่าน "ขาข้ามผู้ถือต้องเป็นรหัสตรงของลักษณะนั้น" อยู่ที่ trg_lines_rule_coa
    --   ที่นี่เหลือแค่การปฏิเสธลักษณะที่ไม่รู้จัก **ก่อนเขียนอะไรลงไป** เพื่อให้ได้
    --   ข้อความภาษาคน ไม่ใช่ error ดิบของ check constraint
    v_nature := nullif(v_txn ->> 'intercompany_nature', '');
    if v_nature is not null and sri_os.fn_intercompany_coa(v_nature) is null then
      raise exception 'บันทึกรายการไม่ได้: ลักษณะรายการข้ามผู้ถือ "%" ไม่รู้จัก (ที่รับคือ %)',
        v_nature,
        coalesce((select string_agg(p.nature, '/' order by p.nature)
                    from sri_os.fn_intercompany_pairs() p), '(ยังไม่มีลักษณะใดในฝั่ง DB)');
    end if;

    v_j := 0;
    for v_line in select value from jsonb_array_elements(v_txn -> 'lines') loop
      v_j := v_j + 1;
      if jsonb_typeof(v_line) <> 'object' then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % ต้องเป็น object', v_i, v_j;
      end if;

      select string_agg(k, ', ' order by k) into v_bad
        from jsonb_object_keys(v_line) as k where k <> all (c_line);
      if v_bad is not null then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % มีช่องที่ยังไม่รู้จัก (%) · ช่องที่รับคือ %',
          v_i, v_j, v_bad, array_to_string(c_line, ', ');
      end if;

      if nullif(v_line ->> 'coa_code', '') is null then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % ไม่ได้ส่ง coa_code', v_i, v_j;
      end if;
      select c.id into v_coa
        from sri_os.chart_of_accounts c where c.code = v_line ->> 'coa_code';
      if v_coa is null then
        raise exception 'บันทึกรายการไม่ได้: ไม่มีรหัส "%" ในผังบัญชี (chart_of_accounts) — ผังบัญชีในฐานข้อมูลอาจยังไม่ sync กับ src/lib/rules/coa.ts',
          v_line ->> 'coa_code';
      end if;

      if (v_line -> 'debit') is null and (v_line -> 'credit') is null then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % ไม่ได้ส่งทั้งเดบิตและเครดิต', v_i, v_j;
      end if;
      if (v_line -> 'debit') is not null and jsonb_typeof(v_line -> 'debit') not in ('number', 'null') then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % เดบิตต้องเป็นตัวเลข', v_i, v_j;
      end if;
      if (v_line -> 'credit') is not null and jsonb_typeof(v_line -> 'credit') not in ('number', 'null') then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % เครดิตต้องเป็นตัวเลข', v_i, v_j;
      end if;
      v_dr := coalesce((v_line ->> 'debit')::numeric, 0);
      v_cr := coalesce((v_line ->> 'credit')::numeric, 0);
      if v_dr < 0 or v_cr < 0 then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % มียอดติดลบ (เดบิต % เครดิต %) — ทิศทางมาจากด้านที่ลง ไม่ใช่จากเครื่องหมาย',
          v_i, v_j, v_dr, v_cr;
      end if;
      if not ((v_dr > 0 and v_cr = 0) or (v_cr > 0 and v_dr = 0)) then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % ต้องลงด้านเดียวและมากกว่า 0 (เดบิต % เครดิต %)',
          v_i, v_j, v_dr, v_cr;
      end if;

      if nullif(v_line ->> 'cf_category', '') is not null
         and not exists (
           select 1 from pg_catalog.pg_enum e
             join pg_catalog.pg_type t on t.oid = e.enumtypid
             join pg_catalog.pg_namespace n on n.oid = t.typnamespace
            where n.nspname = 'sri_os' and t.typname = 'cf_group'
              and e.enumlabel = v_line ->> 'cf_category') then
        raise exception 'บันทึกรายการไม่ได้: หมวดกระแสเงินสด "%" ไม่รู้จัก', v_line ->> 'cf_category';
      end if;

      -- ---------- FCD (25/10) · รูปของข้อมูลสกุลเดิม ----------
      -- กฎบัญชี (ต้องมีอัตราถ้าบัญชีไม่ใช่บาท · ยอดบาทต้องมาจากอัตรา) อยู่ที่
      -- trg_lines_fx_shape ที่เดียว — ที่นี่ตรวจแค่ชนิดข้อมูลเพื่อให้ได้ข้อความภาษาคน
      -- แทน error ดิบของการ cast (ไม่ได้ทำสำเนากฎไว้ในประตู · บทเรียนข้อ 5)
      foreach v_num in array array['amount_original', 'fx_rate'] loop
        if (v_line -> v_num) is not null
           and jsonb_typeof(v_line -> v_num) not in ('number', 'null') then
          raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % ช่อง % ต้องเป็นตัวเลข ไม่ใช่ %',
            v_i, v_j, v_num, jsonb_typeof(v_line -> v_num);
        end if;
      end loop;
      if nullif(v_line ->> 'fx_rate_date', '') is not null then
        begin
          v_fxdate := (v_line ->> 'fx_rate_date')::date;
        exception when others then
          raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % fx_rate_date "%" ไม่ใช่วันที่ที่อ่านได้ (ต้องเป็น YYYY-MM-DD)',
            v_i, v_j, v_line ->> 'fx_rate_date';
        end;
      end if;

      -- ผังบัญชี 1100-1199 = เงินสดและเงินฝาก (เกณฑ์เดียวกับ fn_assert_no_floating_cash)
      if (v_line ->> 'coa_code') ~ '^11[0-9][0-9]$' then v_has_cash := true; end if;
    end loop;
  end loop;

  -- ========== 3.4 · ข้ามผู้ถือต้องมาครบคู่ในคำขอเดียว (ข้อ 2 · ข้อความที่อ่านรู้เรื่อง) ==========
  -- ด่านจริงคือ trg_intercompany_pair (constraint trigger) ที่ครอบ REST ตรงด้วย
  -- ที่นี่ตรวจซ้ำเพื่อให้ผู้กดได้ข้อความก่อนที่อะไรจะถูกเขียน ไม่ใช่กฎที่สองที่คิดต่างกัน
  with legs as (
    select (x.value ->> 'owner_id') as o,
           nullif(x.value ->> 'counter_owner_id', '') as c,
           nullif(x.value ->> 'intercompany_nature', '') as n,
           (select coalesce(sum(coalesce((l.value ->> 'debit')::numeric, 0)), 0)
              from jsonb_array_elements(x.value -> 'lines') as l) as amt
      from jsonb_array_elements(p_payload -> 'transactions') as x
  )
  select string_agg(distinct a.o, ', ') into v_bad
    from legs a
   where a.c is not null
     and (select count(*) from legs b
           where b.o = a.o and b.c = a.c and b.n = a.n and b.amt = a.amt)
      <> (select count(*) from legs b
           where b.o = a.c and b.c = a.o and b.n = a.n and b.amt = a.amt);
  if v_bad is not null then
    raise exception 'บันทึกรายการไม่ได้: รายการข้ามผู้ถือต้องมาครบคู่ในคำขอเดียว (ขาออกของผู้ถือหนึ่ง + ขาเข้าของอีกผู้ถือ ยอดเท่ากัน) — ขาของผู้ถือ % ไม่มีขาคู่ · ขาเดียวแปลว่าเงินหายไปข้างหนึ่งและงบรวมตัดรายการระหว่างกันไม่ลง',
      v_bad;
  end if;

  -- ========== 3.5 · น้ำหนักของ tag ชนิดที่ปันส่วน (ADR 0003 ข้อ 6) ==========
  -- ตรวจ **รูป** ที่นี่เพื่อให้ผู้กดได้ข้อความก่อนที่อะไรจะถูกเขียน
  -- ด่านจริงของ Σ = 1.000000 คือ trg_assert_tag_allocation_complete (constraint
  -- trigger แบบ deferred · 20261028000001) ซึ่งครอบการ INSERT ตรงด้วย
  -- **ที่นี่ไม่ใช่กฎที่สองที่คิดต่างกัน** — เรียกฟังก์ชันตัวเดียวกับที่
  -- fn_reallocate_tags เรียก เพื่อให้กฎรูปน้ำหนักมีที่เดียว (บทเรียน mace-windu ข้อ 5)
  v_tw := p_payload -> 'tag_weights';
  if v_tw is not null and jsonb_typeof(v_tw) <> 'null' then
    perform sri_os.fn_assert_tag_weights_shape(v_tw);
  end if;

  -- ========== 4 · cash_date ต้องสอดคล้องกับบรรทัดที่เครื่องยนต์ส่งมา ==========
  if v_has_cash and v_cash is null then
    raise exception 'บันทึกรายการไม่ได้: รายการนี้มีบรรทัดเงินสด/เงินฝาก แต่ไม่ได้ส่ง cash_date (วันที่เงินเข้า-ออกจริง) — ถ้าเงินยังไม่เคลื่อน ต้องลงเป็นลูกหนี้/เจ้าหนี้ ไม่ใช่เงินสด';
  end if;
  if not v_has_cash and v_cash is not null then
    raise exception 'บันทึกรายการไม่ได้: รายการนี้ไม่มีบรรทัดเงินสดเลย (ค้างรับ-ค้างจ่าย) cash_date ต้องเป็น null ไม่งั้นงบกระแสเงินสดจะนับเงินที่ยังไม่เคลื่อน';
  end if;

  -- ========== 5 · กันกดปุ่มซ้ำ — ล็อกแถว fingerprint ก่อนลงรายการ ==========
  select coalesce((s.value #>> '{}')::numeric, 60) into v_secs
    from sri_os.settings s where s.key = 'ledger.post_dedupe_seconds';
  v_secs := greatest(coalesce(v_secs, 60), 0);

  -- ข้อ 4: normalise ก่อนคิด fingerprint · วันที่/source ใช้ค่าที่ฟังก์ชันจะใช้จริง
  v_canon := sri_os.fn_canonical_payload(p_payload);
  v_canon := jsonb_set(v_canon, '{doc_date}', to_jsonb(v_doc::text));
  if v_cash is null then
    v_canon := v_canon - 'cash_date';
  else
    v_canon := jsonb_set(v_canon, '{cash_date}', to_jsonb(v_cash::text));
  end if;
  v_canon := jsonb_set(v_canon, '{source}', to_jsonb(v_source));

  v_fp := encode(sha256(convert_to(auth.uid()::text || '|' || v_canon::text, 'UTF8')), 'hex');

  insert into sri_os.post_entry_requests as r (fingerprint)
  values (v_fp)
      on conflict (fingerprint) do update
         set created_at = now(), transaction_ids = '{}'::uuid[]
       where r.created_at < now() - make_interval(secs => v_secs::double precision)
  returning r.id into v_req;

  if v_req is null then
    -- คำขอเดิมซ้ำในหน้าต่าง = กดรัว · คืน id ชุดเดิมโดยไม่ลงใหม่
    select r.transaction_ids into v_prev
      from sri_os.post_entry_requests r where r.fingerprint = v_fp;
    return jsonb_build_object(
      'transaction_ids', coalesce(to_jsonb(v_prev), '[]'::jsonb),
      'replayed', true,
      'fingerprint', v_fp);
  end if;

  -- ========== 6 · เขียนลงจริง — หัวรายการ + บรรทัด ในธุรกรรมเดียวกัน (D-091) ==========
  -- created_by ไม่อยู่ในรายการคอลัมน์โดยตั้งใจ: trigger ตั้งเป็น auth.uid() ให้ (ข้อ 5)
  for v_txn in select value from jsonb_array_elements(p_payload -> 'transactions') loop
    insert into sri_os.transactions (
      owner_id, txn_type_code, doc_date, cash_date, doc_no, memo, attachments,
      asset_id, contact_id, contract_id, owner_reason, funding_source,
      source, source_ref, reverses_id,
      wht_rate, wht_amount, wht_certificate_no,
      is_intercompany, counter_owner_id, intercompany_nature)
    values (
      (v_txn ->> 'owner_id')::uuid,
      p_payload ->> 'txn_type_code',
      v_doc,
      v_cash,
      nullif(p_payload ->> 'doc_no', ''),
      nullif(p_payload ->> 'memo', ''),
      coalesce((select array_agg(a) from jsonb_array_elements_text(p_payload -> 'attachments') as a),
               '{}'::text[]),
      (nullif(p_payload ->> 'asset_id', ''))::uuid,
      (nullif(p_payload ->> 'contact_id', ''))::uuid,
      (nullif(p_payload ->> 'contract_id', ''))::uuid,
      nullif(p_payload ->> 'owner_reason', ''),
      nullif(p_payload ->> 'funding_source', ''),
      v_source::sri_os.txn_source,
      nullif(p_payload ->> 'source_ref', ''),
      (nullif(p_payload ->> 'reverses_id', ''))::uuid,
      v_wht_rate, v_wht_amt, v_wht_cert,
      nullif(v_txn ->> 'counter_owner_id', '') is not null,
      (nullif(v_txn ->> 'counter_owner_id', ''))::uuid,
      nullif(v_txn ->> 'intercompany_nature', ''))
    returning id into v_txn_id;

    for v_line in select value from jsonb_array_elements(v_txn -> 'lines') loop
      insert into sri_os.transaction_lines (
        transaction_id, coa_id, bank_account_id, debit, credit, cf_category, asset_id, memo,
        currency, amount_original, fx_rate, fx_rate_date)
      values (
        v_txn_id,
        (select c.id from sri_os.chart_of_accounts c where c.code = v_line ->> 'coa_code'),
        (nullif(v_line ->> 'bank_account_id', ''))::uuid,
        coalesce((v_line ->> 'debit')::numeric, 0),
        coalesce((v_line ->> 'credit')::numeric, 0),
        (nullif(v_line ->> 'cf_category', ''))::sri_os.cf_group,
        (nullif(v_line ->> 'asset_id', ''))::uuid,
        nullif(v_line ->> 'memo', ''),
        nullif(v_line ->> 'currency', ''),
        (nullif(v_line ->> 'amount_original', ''))::numeric,
        (nullif(v_line ->> 'fx_rate', ''))::numeric,
        (nullif(v_line ->> 'fx_rate_date', ''))::date);
    end loop;

    v_ids := v_ids || v_txn_id;
  end loop;

  -- ========== 6.1 · ติด tag ที่ปันส่วน + น้ำหนัก ให้ **ทุกใบในคำขอนี้** ==========
  --
  -- ADR 0003 ข้อ 4.2.2 ชั้น 1: รายการข้ามผู้ถือเป็น **สองใบคู่กัน** (กฎเหล็กข้อ 4)
  --   ถ้าลงน้ำหนักให้ขาเดียว แต่ละขายังดุลในตัวเองและผลรวมข้าม tag ยังตรงสมุด
  --   **จึงไม่มีด่านไหนจับ** แต่ยอดต่อ project ของคู่นั้นไม่สมมาตร: ขาหนึ่งนับเข้า
  --   project A 60% อีกขานับ 40% ทั้งที่เป็นเงินก้อนเดียวกันที่ย้ายข้ามกระเป๋า
  --   → ลูปนี้ลงชุดเดียวกันให้ทุกใบ (เหมือนที่ tag_ids ติดให้ทุกใบตาม ADR 0002 ข้อ 7)
  --
  -- เขียน **หลัง** บรรทัดบัญชีถูกเขียนครบแล้ว (ADR 0002 ข้อ 5 ข้อ 6) และไม่มี
  -- เส้นทางใดที่ค่าใน tag_weights ย้อนไปมีผลต่อชุดบัญชีที่อนุญาต (v_allowed คิดจาก
  -- txn_types ก่อนหน้านี้แล้ว) → **น้ำหนักเปลี่ยนคู่บัญชีไม่ได้เชิงโครงสร้าง**
  if v_tw is not null and jsonb_typeof(v_tw) = 'object' then
    for v_leg in 1 .. coalesce(array_length(v_ids, 1), 0) loop
      for v_tw_tag, v_tw_w in
        select e.key::uuid, e.value #>> '{}'
          from jsonb_each(v_tw) as e(key, value)
         order by e.key
      loop
        insert into sri_os.transaction_tags (transaction_id, tag_id)
        values (v_ids[v_leg], v_tw_tag)
        returning id into v_tw_link;

        -- น้ำหนักที่ไม่ส่งมา = 1.000000 ซึ่ง fn_assert_tag_weights_shape ยอมให้
        -- เกิดขึ้นได้เฉพาะกรณีที่มี tag เดียวบนใบนั้น (คำตอบที่ถูกมีได้คำตอบเดียว)
        insert into sri_os.tag_allocations (transaction_tag_id, weight)
        values (v_tw_link, coalesce(v_tw_w, '1.000000')::numeric);
      end loop;
    end loop;
  end if;

  update sri_os.post_entry_requests r
     set transaction_ids = v_ids
   where r.id = v_req;

  -- ด่านสมดุล/บรรทัดครบ/คู่ข้ามผู้ถือเป็น constraint trigger แบบ deferred (ยิงตอน commit)
  -- → บังคับให้ยิง **ตอนนี้** เพื่อให้คนกดปุ่มได้ข้อความที่อ่านรู้เรื่องทันที
  --   นี่คือการทำให้ด่าน **เข้มขึ้น (เร็วขึ้น)** ไม่ใช่ผ่อน · แล้วคืนสภาพ deferred ให้เหมือนเดิม
  set constraints all immediate;
  set constraints all deferred;

  return jsonb_build_object(
    'transaction_ids', to_jsonb(v_ids),
    'replayed', false,
    'fingerprint', v_fp);
end $fn$;


comment on function fn_post_entry(jsonb) is
  'ปากทางเดียวที่เขียนผลลัพธ์ของ buildPosting() ลง transactions + transaction_lines ในธุรกรรมเดียว (D-091) · **security invoker** → RLS เป็นด่านเดียว · **ไม่มีด่านคู่บัญชี/bank ซ้ำในประตูอีกแล้ว** ด่านนั้นอยู่ที่ trg_lines_rule_coa และ trg_lines_rule_bank_cash บนตาราง (กันการ INSERT ตรงด้วย) · **กฎ cash_date (มีบรรทัด 11xx ⟺ cash_date ไม่เป็น null) ของจริงอยู่ที่ trg_txn_cash_date_matches_lines บนตารางแล้ว (20261009000001)** ด่านในประตู (หัวข้อ 4) เหลือไว้เพื่อให้ error ถึงผู้ใช้ก่อนถึง commit เท่านั้น ห้ามถือว่าเป็นแหล่งความจริง · ประตูยังหลวมกว่า trigger ในมิติเดียว: มันอ่าน cash_date ระดับ payload ใบเดียวแล้วใช้กับทุกขา และรวม v_has_cash ข้ามทุกขา → รายการข้ามผู้ถือที่ขาหนึ่งมีเงินสดขาหนึ่งไม่มี ลงผ่านประตูไม่ได้ (ต้องแก้รอบหน้า) · ประตูเหลือด่านของข้อมูลที่ยังไม่ถูกเขียน: หมวดที่ตารางกฎไม่ระบุบัญชี · รหัสที่ไม่มีในผังบัญชี · ลักษณะข้ามผู้ถือที่ไม่รู้จัก (อ่านจาก fn_intercompany_pairs() ไม่มีสำเนาในฟังก์ชัน) · ข้ามผู้ถือต้องครบคู่ (ข้อ 2) · fingerprint จาก payload ที่ normalise แล้ว (ข้อ 4) · **รับช่อง wht_rate/wht_amount/wht_certificate_no แล้ว (D-111 ข้อ 1 · 20261025000001)** ซึ่งก่อนหน้านี้ทำให้บันทึกการถูกหักภาษี ณ ที่จ่ายไม่ได้เลยทุกทาง (ใส่มาก็เด้ง "ช่องที่ยังไม่รู้จัก" · ไม่ใส่ก็โดน trg_assert_wht_gross ตอน commit) · ประตูตรวจแค่ **รูป** ของสามช่องนั้น (อัตรากับยอดมาคู่กัน · ใบรับรองติดได้เฉพาะใบที่ถูกหักจริง · หมวดต้องหักภาษีได้) ส่วนกฎบัญชี "เงินได้ต้องเป็นยอดเต็ม" อยู่ที่ fn_assert_wht_gross_for() ที่เดียว · **รับสี่ช่องของบรรทัด currency/amount_original/fx_rate/fx_rate_date แล้ว (FCD · 25/10)** ยอดบาทยังอยู่ที่ debit/credit เหมือนเดิม — ประตูตรวจแค่ชนิดข้อมูล ส่วนกฎ "บัญชีไม่ใช่บาทต้องมีอัตรา" และ "ยอดบาทต้องมาจากอัตรา" อยู่ที่ trg_lines_fx_shape ที่เดียว · **รับช่อง tag_weights แล้ว (ADR 0003 ข้อ 6 · 28/10)** รูป {"<tag_id>": น้ำหนัก} สำหรับ tag ชนิดที่ requires_allocation · ประตูตรวจแค่ **รูป** ผ่าน fn_assert_tag_weights_shape() (ตัวเดียวกับที่ fn_reallocate_tags เรียก) ส่วนกฎ Σ น้ำหนัก = 1.000000 ต่อ (ใบ × ชนิด) อยู่ที่ trg_assert_tag_allocation_complete บนตาราง ที่เดียว (ครอบการ INSERT ตรงด้วย) · ติด tag + น้ำหนักให้ **ทุกใบในคำขอ** (ทั้งสองขาของรายการข้ามผู้ถือ) เพราะลงขาเดียวจะทำให้ยอดต่อ project ของคู่นั้นไม่สมมาตรโดยไม่มีด่านไหนจับได้ (ADR 0003 ข้อ 4.2.2) · เขียน tag **หลัง** บรรทัดบัญชีถูกเขียนครบแล้ว และไม่มีเส้นทางใดที่น้ำหนักย้อนไปมีผลต่อชุดบัญชีที่อนุญาต → น้ำหนักเปลี่ยนคู่บัญชีไม่ได้เชิงโครงสร้าง';

-- ACL ของประตู (create or replace ไม่ล้าง ACL เดิม แต่ย้ำไว้ให้ไฟล์นี้รันเองได้)
revoke all on function fn_post_entry(jsonb) from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_post_entry(jsonb) from anon';
  execute 'grant execute on function sri_os.fn_post_entry(jsonb) to authenticated';
end $$;

-- ============================================================
-- 5 · guard ท้ายไฟล์ — ดังตอน migrate ไม่ใช่ตอนผู้ใช้กด
-- ============================================================
do $$
declare v text;
begin
  -- (ก) ประตูต้องรู้จักช่องใหม่ และ **ต้องไม่ลืมช่องเก่า**
  v := pg_get_functiondef('sri_os.fn_post_entry(jsonb)'::regprocedure);
  if v !~ '\mtag_weights\M' then
    raise exception 'fn_post_entry ไม่รู้จักช่อง tag_weights → บันทึกน้ำหนักจากหน้าจอตันทั้งสองทาง (ใส่มาก็เด้ง "ช่องที่ยังไม่รู้จัก" · ไม่ใส่ก็ไม่มีน้ำหนักให้ใบที่ติด project แล้วโดนด่าน Σ = 1 ตอน commit) — รูปแบบเดียวกับเคส WHT ใน D-111 ข้อ 1';
  end if;
  select string_agg(x.want, ', ') into v
    from (values ('wht_rate'), ('wht_amount'), ('wht_certificate_no'),
                 ('amount_original'), ('fx_rate'), ('fx_rate_date'),
                 ('reverses_id'), ('funding_source'), ('owner_reason')) x(want)
   where pg_get_functiondef('sri_os.fn_post_entry(jsonb)'::regprocedure)
         !~ ('\m' || x.want || '\M');
  if v is not null then
    raise exception 'fn_post_entry ที่ไฟล์นี้เขียนทับลืมช่องที่ไฟล์ก่อนๆ เพิ่มไว้: % · การลอกฟังก์ชันมาทั้งก้อนแล้วลืมช่อง = ถอยประตูกลับไปรุ่นเก่าเงียบๆ', v;
  end if;

  -- (ข) ประตูต้องเรียกกฎรูปน้ำหนัก **ตัวเดียวกับ fn_reallocate_tags** ไม่ใช่เขียนซ้ำ
  if pg_get_functiondef('sri_os.fn_post_entry(jsonb)'::regprocedure)
     !~ '\mfn_assert_tag_weights_shape\M' then
    raise exception 'fn_post_entry ไม่ได้เรียก fn_assert_tag_weights_shape → กฎรูปน้ำหนักถูกเขียนซ้ำในประตู · สองที่ที่คิดคนละแบบ = สิ่งที่ฟอร์มเห็นกับสิ่งที่บันทึกจริงแยกจากกันได้ (บทเรียน mace-windu ข้อ 5)';
  end if;
  if pg_get_functiondef('sri_os.fn_reallocate_tags(uuid, text, jsonb, text)'::regprocedure)
     !~ '\mfn_assert_tag_weights_shape\M' then
    raise exception 'fn_reallocate_tags ไม่ได้เรียก fn_assert_tag_weights_shape → กฎรูปน้ำหนักสองที่';
  end if;

  -- (ค) ประตูต้องเขียนลิงก์ + น้ำหนักให้ **ทุกใบในคำขอ** (ข้อ 4.2.2 ชั้น 1)
  if pg_get_functiondef('sri_os.fn_post_entry(jsonb)'::regprocedure)
     !~ 'array_length\(v_ids' then
    raise exception 'fn_post_entry ไม่ได้ไล่ทุกใบใน v_ids ตอนลงน้ำหนัก → รายการข้ามผู้ถือจะได้น้ำหนักขาเดียว แล้วยอดต่อ project ของคู่นั้นไม่สมมาตรโดยไม่มีด่านไหนจับ (ADR 0003 ข้อ 4.2.2)';
  end if;

  -- (ง) `fn_reallocate_tags` ต้องเป็น INVOKER และต้องไม่เชื่อผลของตัวหาขาคู่
  if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
              where ns.nspname = 'sri_os'
                and p.proname in ('fn_reallocate_tags', 'fn_tag_counter_legs',
                                  'fn_assert_tag_weights_shape')
                and p.prosecdef) then
    raise exception 'ฟังก์ชันของประตูน้ำหนัก tag เป็น security definer → แก้สัดส่วน/อ่านขาคู่ของใบที่ตัวเองมองไม่เห็นได้ (ADR 0003 ข้อ 6 สั่ง INVOKER)';
  end if;
  v := pg_get_functiondef('sri_os.fn_reallocate_tags(uuid, text, jsonb, text)'::regprocedure);
  if v !~ '\mfn_tag_counter_legs\M' then
    raise exception 'fn_reallocate_tags ไม่ได้เรียก fn_tag_counter_legs → ไม่ได้ครอบขาคู่ของรายการข้ามผู้ถือ (ADR 0003 ข้อ 4.2.2)';
  end if;
  if v !~ 'counter_owner_id' then
    raise exception 'fn_reallocate_tags ไม่ได้ยืนยันเองว่าชุดใบที่จะแก้มีขาของผู้ถืออีกฝ่าย → ถ้าวันหนึ่งตัวหาขาคู่ถูกแก้/ถอยรุ่น การแก้ข้างเดียวจะผ่านเงียบ (เทสต์ M3 วัดข้อนี้)';
  end if;

  -- (ง2) **เส้นแบ่งของ tag ที่ถูกปิดใช้งาน** (is_active = false)
  --   ติดใหม่ห้าม · แก้สัดส่วนของที่ติดแล้วได้
  --   `fn_assert_tag_weights_shape` ไม่ตรวจ is_active โดยเจตนา (มันไม่รู้จักใบ
  --   จึงแยก "ติดใหม่" กับ "แก้ของที่ติดแล้ว" ไม่ได้) → ทางติดใหม่ต้องปิดสนิทที่
  --   ด่านบนตารางลิงก์ · ถ้าด่านตัวนั้นเลิกอ่าน is_active ขึ้นวันหนึ่ง
  --   **tag ที่ปิดแล้วจะติดใหม่ได้เงียบๆ** ซึ่งเป็นรูที่เรายอมแลกมาโดยไม่รู้ตัว
  --   เทียบจากนิยามที่ **ตัดคอมเมนต์ออกแล้ว** — ไม่งั้นข้อนี้จะเขียว/แดงเพราะ
  --   ประโยคอธิบายที่พูดถึงธงตัวนี้ ไม่ใช่เพราะโค้ดที่ตรวจมันจริง
  if regexp_replace(pg_get_functiondef('sri_os.fn_tag_link_system_columns()'::regprocedure),
                    '--[^' || chr(10) || ']*', '', 'g') !~ '\mis_active\M' then
    raise exception 'fn_tag_link_system_columns ไม่ได้อ่าน tags.is_active อีกแล้ว → ติด tag ที่ปิดใช้งานแล้วเป็นลิงก์ใหม่ได้เงียบๆ · กฎรูปน้ำหนัก (fn_assert_tag_weights_shape) ปล่อย is_active ผ่านโดยเจตนาเพื่อให้ **แก้สัดส่วนของ tag ที่ติดอยู่กับใบนั้นแล้ว** ทำได้แม้ tag ถูกปิด (ไม่งั้นใบนั้นติดค้างถาวรพร้อมสัดส่วนที่รู้อยู่ว่าผิด) → ด่านบนตารางลิงก์คือที่เดียวที่ปิดทางติดใหม่ ห้ามถอด';
  end if;
  if regexp_replace(pg_get_functiondef('sri_os.fn_assert_tag_weights_shape(jsonb)'::regprocedure),
                    '--[^' || chr(10) || ']*', '', 'g') ~ '\mis_active\M' then
    raise exception 'fn_assert_tag_weights_shape กลับไปตรวจ tags.is_active → ใบที่ติด tag ไว้ก่อน tag ถูกปิด จะ **แก้สัดส่วนไม่ได้อีกเลยตลอดกาล** (fn_reallocate_tags เรียกฟังก์ชันนี้) และถอด tag ก็ยังไม่มีประตู = ใบนั้นติดค้างถาวร · เปิดฟีเจอร์ครึ่งเดียวอันตรายกว่าไม่เปิด (บทเรียนผู้ตรวจข้อ 7) · ทางติดใหม่ปิดอยู่แล้วที่ด่านบนตารางลิงก์';
  end if;

  -- (ง3) **ฟังก์ชันบอกชนิดที่ประตูรับแล้ว** (ฝั่งแอปใช้ปิดช่องที่กดแล้วตาย)
  if to_regprocedure('sri_os.fn_post_entry_accepted_tag_kinds()') is null then
    raise exception 'ไม่มี fn_post_entry_accepted_tag_kinds → ฝั่งแอปอ่านไม่ได้ว่าชนิด tag ไหนลงผ่านประตูได้ และกติกา "อ่านไม่ได้ = ซ่อน" จะทำให้ฟอร์มซ่อน tag ทุกชนิด รวมชนิดที่ประตูรับอยู่แล้ว';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
              where ns.nspname = 'sri_os'
                and p.proname = 'fn_post_entry_accepted_tag_kinds' and p.prosecdef) then
    raise exception 'fn_post_entry_accepted_tag_kinds เป็น security definer → ต้องเป็น INVOKER (มันแค่อ่านคอนฟิกกับนิยามของประตู ไม่มีเหตุผลให้ยกสิทธิ์)';
  end if;
  if not has_function_privilege('authenticated',
        'sri_os.fn_post_entry_accepted_tag_kinds()', 'execute') then
    raise exception 'authenticated เรียก fn_post_entry_accepted_tag_kinds ไม่ได้ → ฟอร์มจะซ่อน tag ทุกชนิด (อ่านไม่ได้ = ซ่อน)';
  end if;
  if has_function_privilege('anon', 'sri_os.fn_post_entry_accepted_tag_kinds()', 'execute')
     or has_function_privilege('public', 'sri_os.fn_post_entry_accepted_tag_kinds()', 'execute') then
    raise exception 'fn_post_entry_accepted_tag_kinds เปิดให้ PUBLIC/anon';
  end if;
  -- ต้องตัดสินจาก **ของจริง** ไม่ใช่รายชื่อตายตัว
  v := pg_get_functiondef('sri_os.fn_post_entry_accepted_tag_kinds()'::regprocedure);
  if v !~ '\mc_header\M' or v !~ '\mpg_get_functiondef\M' then
    raise exception 'fn_post_entry_accepted_tag_kinds ไม่ได้อ่าน c_header ของ fn_post_entry จาก catalog → กลายเป็นรายชื่อตายตัวที่จะค้างล้าสมัยเงียบๆ (วันที่ประตูรับ tag_ids ฟอร์มจะยังซ่อน label ตลอดกาลโดยไม่มีใครรู้)';
  end if;
  -- **สภาพวันนี้ (28/10)**: ประตูรับ `tag_weights` แล้ว แต่ยังไม่รับ `tag_ids`
  --   (ADR 0002 ชิ้น 3 ยังไม่ลง) → ต้องคืน 'project' และต้องยังไม่คืน 'label'
  --   **ถ้า guard นี้ดังเพราะคืน 'label' ด้วย แปลว่าชิ้น 3 ของ ADR 0002 ลงแล้ว
  --   → แก้ guard ข้อนี้ ไม่ใช่แก้ฟังก์ชัน** (ฟังก์ชันทำงานถูกแล้ว: มันอ่านช่องจริง
  --   ของประตู ไม่ได้เขียนรายชื่อตายตัว)
  if not ('project' = any (sri_os.fn_post_entry_accepted_tag_kinds())) then
    raise exception 'fn_post_entry_accepted_tag_kinds ไม่คืน "project" ทั้งที่ประตูรับช่อง tag_weights แล้ว → ฟอร์มจะซ่อนช่อง project ทั้งที่ลงได้ (ฟีเจอร์ที่ลงเสร็จแล้วแต่ใช้ไม่ได้)';
  end if;
  if 'label' = any (sri_os.fn_post_entry_accepted_tag_kinds()) then
    raise exception 'fn_post_entry_accepted_tag_kinds คืน "label" ทั้งที่ c_header ของประตูยังไม่มีช่อง tag_ids → ฟอร์มจะโชว์ช่องที่กดบันทึกแล้วเด้ง "ช่องที่ยังไม่รู้จัก" · **ถ้า guard นี้ดังเพราะชิ้น 3 ของ ADR 0002 ลงแล้วจริง ให้แก้ guard ข้อนี้ ไม่ใช่แก้ฟังก์ชัน**';
  end if;

  -- (จ) ACL: ประตูเปิดให้ authenticated · ปิดจาก anon/PUBLIC
  if has_function_privilege('public', 'sri_os.fn_post_entry(jsonb)', 'execute')
     or has_function_privilege('anon', 'sri_os.fn_post_entry(jsonb)', 'execute') then
    raise exception 'fn_post_entry เปิดให้ PUBLIC/anon';
  end if;
  if not has_function_privilege('authenticated', 'sri_os.fn_post_entry(jsonb)', 'execute') then
    raise exception 'authenticated เรียก fn_post_entry ไม่ได้ → หน้าจอบันทึกรายการไม่ได้ทั้งระบบ';
  end if;
  if not has_function_privilege('authenticated',
        'sri_os.fn_reallocate_tags(uuid, text, jsonb, text)', 'execute') then
    raise exception 'authenticated เรียก fn_reallocate_tags ไม่ได้ → แก้สัดส่วนจากหน้าจอไม่ได้';
  end if;
  if has_function_privilege('anon', 'sri_os.fn_reallocate_tags(uuid, text, jsonb, text)', 'execute')
     or has_function_privilege('public', 'sri_os.fn_reallocate_tags(uuid, text, jsonb, text)', 'execute') then
    raise exception 'fn_reallocate_tags เปิดให้ PUBLIC/anon';
  end if;

  -- (ฉ) ด่านเส้นทางอ่านต้องยังผ่าน (ฟังก์ชันใหม่ไม่ใช่ set-returning และไม่ใช่ definer)
  perform sri_os.fn_assert_tag_read_path();
  perform sri_os.fn_assert_ledger_read_path();

  raise notice 'ok · ประตูน้ำหนัก tag พร้อม: fn_post_entry รับ tag_weights และลงน้ำหนักชุดเดียวกันให้ทุกใบในคำขอ · กฎรูปน้ำหนักอยู่ที่ fn_assert_tag_weights_shape ที่เดียว · fn_reallocate_tags ปิดชุดเดิม + เปิดชุดใหม่พร้อมเหตุผลบังคับ และครอบทั้งสองขาของรายการข้ามผู้ถือ (ยืนยันเองไม่เชื่อผลของตัวหา)';
end $$;
