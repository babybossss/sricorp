-- ============================================================
-- SRI OS · ยกกฎ cash_date ขึ้นเป็น Money Invariant ของ **ฐานข้อมูล**
--          + แช่แข็ง reverses_id ที่ตั้งค่าแล้ว (ประวัติ "ใบไหนกลับใบไหน")
--
-- ปิดสองรูที่ผู้ตรวจรันยืนยันแล้วบน DB ที่ migrate ครบ (ไม่ใช่สมมติฐาน)
--
-- ------------------------------------------------------------
-- รูที่ 1 · งบกระแสเงินสดค้างตลอดกาล — ร้ายแรงสุด
-- ------------------------------------------------------------
--   กฎ "มีบรรทัด 11xx ⟺ cash_date ต้องไม่เป็น null" เคยเขียนไว้ใน `fn_post_entry`
--   **ที่เดียว** (20261008000011 หัวข้อ 4 · 20261008000013 หัวข้อเดียวกัน)
--   → มันเป็นกฎของ **RPC ไม่ใช่ของฐานข้อมูล** · `insert` ตรงเข้าตาราง
--     (PostgREST · service_role · psql · migration) เลี่ยงได้ทุกกรณี
--
--   เคสที่พิสูจน์แล้ว:
--     ต้นฉบับ  SRI Corporation · Dr 1100 5,000 / Cr 4900 5,000 · cash_date '2026-10-20'
--     ใบกลับรายการ · สะท้อนบรรทัด **ครบทุกมิติ** (ผ่านด่าน D-097 ทุกข้อ)
--                    แต่ cash_date = null และ attachments = '{}'
--     ผล: เงินฝากในงบดุล = 0.00 (หักกันหมด)
--         เงินฝากในงบกระแสเงินสด (where t.cash_date is not null) = 5,000.00 **ค้างตลอดกาล**
--         ทุกใบสมดุล · ไม่มี trigger ร้อง
--   ทางกลับกันก็ได้: ต้นฉบับค้างรับ (ไม่มี 11xx · cash_date null) แล้วใบกลับรายการ
--     ใส่ cash_date → **เงินสดผีที่ไม่มีเงินจริงเคลื่อน**
--
--   **แก้ที่ต้นเหตุ ไม่ใช่แก้ที่ด่านสะท้อนบรรทัด**
--   ใบกลับรายการที่สะท้อนบรรทัดครบ **มีบรรทัด 11xx อยู่แล้ว** → เมื่อกฎนี้เป็น trigger
--   บนตาราง มันถูกบังคับให้มี cash_date เอง · รูที่ 1 จึงปิดโดยอัตโนมัติ และ
--   `fn_assert_reverse_mirrors` **ไม่ต้องเทียบ cash_date** (ตั้งใจไม่เทียบวันที่
--   เพราะใบกลับรายการลงวันที่ปัจจุบัน — นั่นคือจุดประสงค์ของมัน)
--   และของแถมที่สำคัญกว่า: ปิดรูที่ **กว้างกว่าเรื่องกลับรายการ** คือ insert ตรงทุกรูปแบบ
--
--   ทำไมต้องเป็น `constraint trigger ... deferrable initially deferred`
--     ตอน insert หัวรายการ **บรรทัดยังไม่เกิด** → `before insert` คือด่านที่ไม่ตรวจอะไรเลย
--     (เส้นทางที่ถูกต้องคือหัวรายการ + บรรทัดในธุรกรรมฐานข้อมูลเดียวกัน · 20261007000000)
--   ทำไมต้องยิง **update** ด้วย
--     `update ... set cash_date = null` บนใบที่มีบรรทัดเงินสดก็ทำให้ใบนั้นหายจาก
--     งบกระแสเงินสดเหมือนกัน (ฝั่ง personal_flexible แก้หัวรายการหลัง commit ได้)
--
--   ทำไมผูกบน `transactions` ตารางเดียว ไม่ต้องผูกฝั่ง `transaction_lines` ซ้ำ
--     บรรทัดเขียนได้เฉพาะในธุรกรรมที่ INSERT หัวรายการ (`fn_assert_line_writable`
--     เทียบ write_txn_id) → ตอน commit ของธุรกรรมนั้น ด่านฝั่งหัวรายการเห็นชุดบรรทัด
--     **ชุดสุดท้าย** อยู่แล้ว · และหัวรายการที่ไม่มีบรรทัดเลยถูก trg_txn_needs_lines
--     ปฏิเสธ → ไม่มีสภาพ "บรรทัดโผล่มาทีหลังโดยหัวรายการไม่ถูกแตะ" ให้เลี่ยง
--
--   **นิยาม "บรรทัดเงินสด" ต้องตรงกับที่ประตูใช้ตัวอักษรต่อตัวอักษร**
--     `chart_of_accounts.code ~ '^11[0-9][0-9]$'` (เกณฑ์เดียวกับ fn_assert_no_floating_cash
--     ของ 20260917000002 และ fn_post_entry) · **ห้ามคิดนิยามใหม่** เช่น
--     `bank_account_id is not null` — สองที่ต้องตรงกัน ไม่งั้นได้กฎสองชุด
--     (เทสต์ C0ค ตรวจว่า regex ตัวนี้อยู่ในด่านใหม่จริง)
--
--   **ไม่ถอดกฎออกจาก fn_post_entry ในรอบนี้** (คนละรอบ)
--     ประตูเหลือไว้เพื่อให้ผู้กดได้ error **ก่อนถึง commit** ซึ่งเป็นข้อความที่อ่านรู้เรื่อง
--     กว่าตอน constraint trigger ดังท้ายธุรกรรม · ของจริงที่บังคับคือ trigger ในไฟล์นี้
--     → ไฟล์นี้แก้ `comment on function fn_post_entry` ให้พูดข้อนี้ไว้ (ไม่แก้ตัวฟังก์ชัน
--       เพราะ create or replace ทั้ง 700 บรรทัดซ้ำ = สร้างสำเนาที่สองของประตู
--       ซึ่งเป็นบั๊กประเภทที่โปรเจกต์นี้โดนมาตลอด)
--
--   **ข้อที่ต้องรู้เมื่อประตูกับ trigger ตอบไม่เหมือนกัน**: ประตูอ่าน cash_date
--     ระดับ payload ใบเดียวแล้วใช้กับทุกขา และรวม v_has_cash ข้ามทุกขาในคำขอ
--     ส่วน trigger ตัดสิน **ทีละแถว** จากบรรทัดของแถวนั้น · รายการข้ามผู้ถือที่
--     ขาหนึ่งมีเงินสดและขาหนึ่งไม่มี (เช่นบริษัททดรองจ่ายแทนบุคคล เงินออกจากบัญชี
--     บริษัทตรงไปผู้ขาย) จึงลงผ่านประตูไม่ได้แต่ลงผ่านตารางได้และ **ถูกต้อง**
--     → trigger คือด่านที่ถูก · ประตูหลวมกว่าในมิตินี้และต้องแก้รอบหน้า (รายงานไว้)
--
-- ------------------------------------------------------------
-- รูที่ 2 · ฝั่ง personal_flexible เขียนทับประวัติ "ใบไหนกลับใบไหน" ได้หลัง commit
-- ------------------------------------------------------------
--   `update sri_os.transactions set reverses_id = <ใบอื่นที่บรรทัดเหมือนกัน>
--      where id = <ใบกลับรายการ>` → **สำเร็จ**
--   ต้นฉบับเดิมกลับเป็น "ยังไม่ถูกกลับรายการ" แล้วกลับรายการซ้ำได้
--   ตัวเลขไม่ผิดทันที แต่ประวัติที่ D-098 ยืนบนนั้นเขียนทับได้
--   (fn_corporate_immutable กันแต่ corporate · fn_txn_system_columns freeze
--    แค่ owner_id / created_at / id / write_txn_id)
--
--   กฎที่ตั้ง: **reverses_id ที่ไม่เป็น null แล้ว เปลี่ยนไม่ได้และลบไม่ได้ ทุกผู้ถือ**
--   บังคับทุกผู้ถือเพราะเป็น **ความสมบูรณ์ของประวัติการเงิน** ไม่ใช่กติกาเอกสาร
--   ของนิติบุคคล (ฝั่งบุคคล override ได้แค่กติกาเอกสาร) — หลักเดียวกับ
--   fn_void_blocked_by_reverse ของ 20261009000000
--
--   **null → ค่าใด ยังทำได้** (ตัดสินแล้ว · เหตุผลเขียนไว้ไม่ให้เดาภายหลัง)
--     1. เส้นทางนี้ไม่ลบประวัติอะไร — ของเดิมไม่มีลิงก์อยู่แล้ว
--     2. มันถูกตรวจครบอยู่แล้วสองด่านตอน UPDATE:
--        `trg_assert_reverse_link` (ต้นฉบับมีจริง · ผู้ถือเดียวกัน · ยังไม่ถูก void ·
--        ยังไม่ถูกกลับรายการ) และ `trg_reverse_mirrors_original` ซึ่งเป็น constraint
--        trigger ที่ยิงบน update ด้วย → บรรทัดต้องสะท้อนตรงตัว ตั้งชี้ส่งเดชไม่ได้
--     3. ปิดทางนี้ด้วยคือกันแน่นเกิน: ใบที่ลงถูกทุกบรรทัดแต่ลืมใส่ลิงก์จะซ่อมไม่ได้เลย
--        และทางเดียวที่เหลือคือ void + ลงใหม่ ซึ่งแพงกว่าความเสี่ยงที่กันได้จริง
--     และเมื่อตั้งแล้ว **แช่แข็งทันที** (เทสต์ C8d) จึงไม่ใช่ช่องที่เปิดค้าง
--
--   trigger ธรรมดา (ไม่เลื่อน) โดยตั้งใจ: ด่านนี้เทียบแค่ old/new ของแถวเดียว
--   จึงตอบได้ทันทีและข้อความชี้ตรงที่คำสั่งที่ผิด (หลักเดียวกับ trg_void_blocked_by_reverse)
--
-- ------------------------------------------------------------
-- ทำไม trigger ไม่ใช่ RLS / ไม่ใช่ด่านใน fn_post_entry
-- ------------------------------------------------------------
--   policy เขียนทับกันได้ (permissive OR) · PostgREST และ service_role เขียนตรง
--   เข้าตารางได้โดยไม่ผ่าน RPC · trigger บังคับทุกเส้นทางทุก role เท่ากัน
--   **ไม่มีตัวไหนเรียก fn_can()** — กฎเงินปิดจากหน้า Settings ไม่ได้ (เทสต์ C0จ)
--
-- ------------------------------------------------------------
-- ทั้งไฟล์เป็น create or replace / drop ... if exists / comment → **รันซ้ำได้**
--   ไม่แก้ข้อมูลเดิมแม้แถวเดียว · ไม่แตะไฟล์ migration เก่า
--
-- ย้อนกลับ (rollback):
--   -- drop trigger  if exists trg_txn_cash_date_matches_lines on sri_os.transactions;
--   -- drop trigger  if exists trg_reverses_id_frozen          on sri_os.transactions;
--   -- drop function if exists sri_os.fn_txn_cash_date_guard();
--   -- drop function if exists sri_os.fn_assert_txn_cash_date(uuid);
--   -- drop function if exists sri_os.fn_reverses_id_frozen();
--   ไม่ต้องกู้ข้อมูลอะไร (ไฟล์นี้ไม่เขียน/ไม่ลบแถวใด)
--   ข้อความ comment ของ fn_post_entry: รัน **เฉพาะคำสั่ง comment on function
--   fn_post_entry(jsonb)** ของ 20261008000013 ซ้ำ (ห้ามรันไฟล์นั้นทั้งไฟล์เพื่อย้อน
--   คอมเมนต์ เพราะมันจะ replace ตัวฟังก์ชันด้วย)
--   **ผลของการย้อน**: กฎ cash_date กลับไปอยู่ที่ประตูที่เดียว = รูที่ 1 เปิดอีกครั้ง
-- ============================================================

set search_path = sri_os, public;

-- ------------------------------------------------------------
-- 1 · Money Invariant: บรรทัด 11xx ⟺ cash_date
--
-- แยกฟังก์ชัน "ตรวจหนึ่งรายการ" ออกจาก trigger function ตามแพทเทิร์นของ
-- fn_assert_txn_balanced / fn_txn_needs_lines — ถ้าวันหนึ่งต้องเรียกจากที่อื่น
-- (รายงาน data health · migration ตรวจประวัติ) จะได้เรียก **ตัวเดียวกัน**
--
-- security definer: ถ้าปล่อยให้อ่านบรรทัดตามสิทธิ์ผู้เรียก คนที่มองบรรทัดไม่เห็น
--   จะได้ v_has_cash = false แล้ว "หลุดการตรวจไปเฉยๆ" (เหตุผลเดียวกับ
--   fn_assert_line_writable และ fn_reverse_link_ok)
-- ------------------------------------------------------------
create or replace function fn_assert_txn_cash_date(p_txn uuid) returns void
language plpgsql security definer set search_path = '' as $fn$
declare
  v_n        int;
  v_has_cash boolean;
  v_cash     date;
  v_status   sri_os.txn_status;
  v_codes    text;
begin
  if p_txn is null then return; end if;

  select t.cash_date, t.status into v_cash, v_status
    from sri_os.transactions t where t.id = p_txn;
  -- หัวรายการไม่อยู่แล้ว (ถูกลบใน ธุรกรรมเดียวกัน) → ไม่ใช่เรื่องของด่านนี้
  if v_status is null then return; end if;

  -- นิยาม "บรรทัดเงินสด" = ผังบัญชี 1100-1199 · **ตัวเดียวกับ fn_post_entry
  -- และ fn_assert_no_floating_cash** (ห้ามเปลี่ยนที่เดียว · เทสต์ C0ค ตรวจ)
  select count(*),
         count(*) filter (where c.code ~ '^11[0-9][0-9]$') > 0,
         string_agg(distinct c.code, ', ') filter (where c.code ~ '^11[0-9][0-9]$')
    into v_n, v_has_cash, v_codes
    from sri_os.transaction_lines l
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where l.transaction_id = p_txn;

  -- 0 บรรทัด = Money Invariant 1 (trg_txn_needs_lines) ซึ่งปฏิเสธอยู่แล้วทุกสถานะ
  -- **ไม่พูดซ้ำที่นี่** ไม่งั้นได้ข้อความสองชุดของเรื่องเดียวกัน (บทเรียนข้อ 5)
  -- เทสต์ C10a/C10a2 ยืนยันว่าเคสนี้ยังถูกปฏิเสธจริง ไม่ได้หลุดเพราะด่านนี้เงียบ
  if v_n = 0 then return; end if;

  if v_has_cash and v_cash is null then
    raise exception 'Money Invariant: รายการ % (สถานะ %) มีบรรทัดเงินสด/เงินฝาก (%) แต่ cash_date เป็น null — ถ้าเงินยังไม่เคลื่อน ต้องลงเป็นลูกหนี้/เจ้าหนี้ ไม่ใช่เงินสด · ถ้าเงินเคลื่อนแล้วต้องใส่วันที่เงินเข้า-ออกจริง ไม่งั้นงบดุลหักกลบแต่งบกระแสเงินสด (where cash_date is not null) ค้างอยู่ตลอดกาล',
      p_txn, v_status, v_codes;
  end if;

  if not v_has_cash and v_cash is not null then
    raise exception 'Money Invariant: รายการ % (สถานะ %) ไม่มีบรรทัดเงินสดเลย (ค้างรับ-ค้างจ่าย) แต่ cash_date = % — ต้องเป็น null ไม่งั้นงบกระแสเงินสดนับเงินที่ยังไม่เคลื่อน (เงินสดผี)',
      p_txn, v_status, v_cash;
  end if;
end $fn$;

comment on function fn_assert_txn_cash_date(uuid) is
  'Money Invariant · มีบรรทัดผังบัญชี 11xx (เงินสด/เงินฝาก) ⟺ transactions.cash_date ไม่เป็น null · นิยามบรรทัดเงินสดใช้ regex เดียวกับ fn_post_entry และ fn_assert_no_floating_cash · 0 บรรทัดเป็นเรื่องของ trg_txn_needs_lines ไม่พูดซ้ำที่นี่ · อ่านบรรทัดจาก DB เอง ไม่รับค่าจากผู้เรียก';

create or replace function fn_txn_cash_date_guard() returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  perform sri_os.fn_assert_txn_cash_date(new.id);
  return null;
end $fn$;

comment on function fn_txn_cash_date_guard() is
  'trigger function ของ Money Invariant cash_date · ต้องผูกเป็น constraint trigger (deferrable initially deferred) บน insert **และ** update ของ transactions — before insert ไม่ได้เพราะบรรทัดยังไม่เกิด · ไม่ยิง update ไม่ได้เพราะ update set cash_date = null เลี่ยงได้ทั้งหมด';

drop trigger if exists trg_txn_cash_date_matches_lines on transactions;
create constraint trigger trg_txn_cash_date_matches_lines
  after insert or update on transactions
  deferrable initially deferred
  for each row execute function fn_txn_cash_date_guard();

-- ------------------------------------------------------------
-- 2 · reverses_id ที่ตั้งค่าแล้ว แช่แข็ง (เปลี่ยนไม่ได้ · ลบไม่ได้ · ทุกผู้ถือ)
--
-- ไม่เป็น security definer และต้องถูก revoke execute ในไฟล์เดียวกัน:
--   ฟังก์ชันนี้ **ไม่อ่านตารางไหนและไม่ถามสิทธิ์ใคร** (หลักเดียวกับ 20261008000004)
--   เทียบแค่ old/new ของแถวที่กำลังเขียน · กฎที่บังคับด้วย trigger ต้องปิดไม่ได้
--   จากหน้า Settings
-- ------------------------------------------------------------
create or replace function fn_reverses_id_frozen() returns trigger
language plpgsql set search_path = '' as $fn$
begin
  if old.reverses_id is not null
     and new.reverses_id is distinct from old.reverses_id then
    raise exception 'ประวัติกลับรายการเขียนทับไม่ได้: รายการ % ชี้ reverses_id = % อยู่แล้ว เปลี่ยนเป็น % ไม่ได้ (รวมการลบทิ้งเป็น null) · "ใบไหนกลับใบไหน" เป็นฐานของ D-097/D-098 — ถ้าเขียนทับได้ ต้นฉบับเดิมจะกลับเป็น "ยังไม่ถูกกลับรายการ" แล้วถูกกลับรายการซ้ำได้ · ถ้าใบกลับรายการใบนี้ลงผิด ให้ void ใบนี้แล้วลงใบใหม่ที่ชี้ต้นฉบับที่ถูกต้อง',
      old.id, old.reverses_id, coalesce(new.reverses_id::text, 'null');
  end if;
  return new;
end $fn$;

comment on function fn_reverses_id_frozen() is
  'reverses_id ที่ไม่เป็น null แล้ว เปลี่ยน/ลบไม่ได้ ทุกผู้ถือ (ความสมบูรณ์ของประวัติการเงิน ไม่ใช่กติกาเอกสารของนิติบุคคล) · null → ค่าใด ยังทำได้ เพราะไม่ลบประวัติอะไร และถูกตรวจครบด้วย trg_assert_reverse_link + trg_reverse_mirrors_original ที่ยิงบน update อยู่แล้ว';

drop trigger if exists trg_reverses_id_frozen on transactions;
create trigger trg_reverses_id_frozen
  before update on transactions
  for each row execute function fn_reverses_id_frozen();

-- ------------------------------------------------------------
-- 3 · สิทธิ์ของฟังก์ชันใหม่ — ปิดทุก role (กฎเงินห้ามเรียกเอง)
--   20261007000007 revoke เป็นชุดจาก pg_proc **ตอนที่มันรัน** → ฟังก์ชันที่เพิ่ม
--   หลังจากนั้นถือ ACL เริ่มต้น = PUBLIC EXECUTE ถ้าไม่ถอนที่นี่
--   (trigger ยิงเองโดยไม่ต้องมี execute ของผู้เรียก · เทสต์ C1b เดินด้วย
--    role authenticated จริงเพื่อยืนยันว่าไม่ได้ปิดจนแอปลงรายการไม่ได้)
-- ------------------------------------------------------------
revoke all on function fn_assert_txn_cash_date(uuid) from public;
revoke all on function fn_txn_cash_date_guard()      from public;
revoke all on function fn_reverses_id_frozen()       from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_txn_cash_date(uuid) from anon, authenticated';
  execute 'revoke all on function sri_os.fn_txn_cash_date_guard()      from anon, authenticated';
  execute 'revoke all on function sri_os.fn_reverses_id_frozen()       from anon, authenticated';
end $$;

-- ------------------------------------------------------------
-- 4 · คอมเมนต์ของประตู — ชี้ว่าของจริงอยู่ที่ trigger แล้ว
--     **ไม่แก้ตัวฟังก์ชัน** (ดูเหตุผลในหัวไฟล์) · ด่านในประตูยังอยู่ตามเดิม
-- ------------------------------------------------------------
comment on function fn_post_entry(jsonb) is
  'ปากทางเดียวที่เขียนผลลัพธ์ของ buildPosting() ลง transactions + transaction_lines ในธุรกรรมเดียว (D-091) · **security invoker** → RLS เป็นด่านเดียว · **ไม่มีด่านคู่บัญชี/bank ซ้ำในประตูอีกแล้ว** ด่านนั้นอยู่ที่ trg_lines_rule_coa และ trg_lines_rule_bank_cash บนตาราง (กันการ INSERT ตรงด้วย) · **กฎ cash_date (มีบรรทัด 11xx ⟺ cash_date ไม่เป็น null) ของจริงอยู่ที่ trg_txn_cash_date_matches_lines บนตารางแล้ว (20261009000001)** ด่านในประตู (หัวข้อ 4) เหลือไว้เพื่อให้ error ถึงผู้ใช้ก่อนถึง commit เท่านั้น ห้ามถือว่าเป็นแหล่งความจริง · ประตูยังหลวมกว่า trigger ในมิติเดียว: มันอ่าน cash_date ระดับ payload ใบเดียวแล้วใช้กับทุกขา และรวม v_has_cash ข้ามทุกขา → รายการข้ามผู้ถือที่ขาหนึ่งมีเงินสดขาหนึ่งไม่มี ลงผ่านประตูไม่ได้ (ต้องแก้รอบหน้า) · ประตูเหลือด่านของข้อมูลที่ยังไม่ถูกเขียน: หมวดที่ตารางกฎไม่ระบุบัญชี · รหัสที่ไม่มีในผังบัญชี · ลักษณะข้ามผู้ถือที่ไม่รู้จัก (อ่านจาก fn_intercompany_pairs() ไม่มีสำเนาในฟังก์ชัน) · ข้ามผู้ถือต้องครบคู่ (ข้อ 2) · fingerprint จาก payload ที่ normalise แล้ว (ข้อ 4)';

-- ------------------------------------------------------------
-- 5 · guard ท้ายไฟล์ — ต้องดังตอน migrate ถ้าด่านไม่ได้ผูกตามที่ไฟล์นี้อ้าง
--     (ส่วนประวัติที่ขัดกฎใหม่เป็น warning: raise = migrate ของจริงล้มเพราะ
--      ข้อมูลเก่า ซึ่งแก้ด้วยไฟล์นี้ไม่ได้ ต้องตามแก้ด้วยมือตามเคส)
-- ------------------------------------------------------------
do $$
declare
  v_type int; v_defer boolean; v_init boolean; v_con oid;
  n int; v text;
begin
  -- (ก) ด่าน cash_date ต้องเป็น constraint trigger ที่เลื่อนไว้ · AFTER · insert + update
  select t.tgtype, t.tgdeferrable, t.tginitdeferred, t.tgconstraint
    into v_type, v_defer, v_init, v_con
    from pg_trigger t
   where t.tgrelid = 'sri_os.transactions'::regclass
     and t.tgname = 'trg_txn_cash_date_matches_lines';
  if v_type is null or not (v_defer and v_init and v_con <> 0)
     or (v_type & 2) <> 0 or (v_type & 4) = 0 or (v_type & 16) = 0 then
    raise exception 'ด่าน cash_date ไม่ได้ผูกเป็น constraint trigger (deferrable initially deferred · AFTER · insert และ update) — วางที่ before insert = บรรทัดยังไม่เกิด · ไม่ยิง update = update set cash_date = null เลี่ยงได้ทั้งหมด';
  end if;

  -- (ข) ด่าน freeze reverses_id ต้องผูกบน UPDATE
  select count(*) into n from pg_trigger t
   where t.tgrelid = 'sri_os.transactions'::regclass
     and t.tgname = 'trg_reverses_id_frozen'
     and (t.tgtype & 16) <> 0;
  if n <> 1 then
    raise exception 'ด่าน freeze reverses_id ไม่ได้ผูกบน UPDATE ของ transactions (เจอ %)', n;
  end if;

  -- (ค) นิยามบรรทัดเงินสดต้องตรงกับประตูตัวอักษรต่อตัวอักษร — ไม่ใช่ความจำของคน
  select count(*) into n from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.proname in ('fn_assert_txn_cash_date', 'fn_post_entry', 'fn_assert_no_floating_cash')
     and position('^11[0-9][0-9]$' in p.prosrc) > 0;
  if n <> 3 then
    raise exception 'นิยาม "บรรทัดเงินสด" (regex ^11[0-9][0-9]$) ไม่ตรงกันทั้งสามที่ (เจอ % จาก 3: fn_assert_txn_cash_date · fn_post_entry · fn_assert_no_floating_cash) — นิยามต่างกัน = กฎสองชุด', n;
  end if;

  -- (ง) กฎเงินห้ามขึ้นกับสิทธิ์
  select count(*) into n from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os'
     and p.proname in ('fn_assert_txn_cash_date', 'fn_txn_cash_date_guard', 'fn_reverses_id_frozen')
     and p.prosrc like '%fn_can%';
  if n > 0 then
    raise exception 'ด่านใหม่เรียกฟังก์ชันตรวจสิทธิ์ — กฎเงินต้องปิดไม่ได้จากหน้า Settings';
  end if;

  -- (จ) ประวัติ: แถวเก่าที่ขัดกฎใหม่ → **UPDATE แถวพวกนี้ไม่ได้อีก** (เช่น void)
  --     เพราะ constraint trigger ตรวจตอน UPDATE ด้วย · ต้องเห็นตอน migrate
  select count(*), string_agg(t.id::text, ', ') into n, v
    from sri_os.transactions t
   where (select count(*) from sri_os.transaction_lines l where l.transaction_id = t.id) > 0
     and (
       (t.cash_date is null and exists (
          select 1 from sri_os.transaction_lines l
            join sri_os.chart_of_accounts c on c.id = l.coa_id
           where l.transaction_id = t.id and c.code ~ '^11[0-9][0-9]$'))
       or
       (t.cash_date is not null and not exists (
          select 1 from sri_os.transaction_lines l
            join sri_os.chart_of_accounts c on c.id = l.coa_id
           where l.transaction_id = t.id and c.code ~ '^11[0-9][0-9]$'))
     );
  if n > 0 then
    raise warning 'มีรายการเก่า % แถวที่ขัด Money Invariant cash_date → ตัวเลขในงบกระแสเงินสดของแถวพวกนี้ยังผิดอยู่ และ **แก้/void แถวพวกนี้ไม่ได้จนกว่าจะแก้ cash_date ให้ถูก** (ด่านใหม่ตรวจตอน UPDATE ด้วย): %', n, v;
  end if;

  raise notice 'guard · กฎ cash_date เป็น constraint trigger ที่เลื่อนไว้ ยิงทั้ง insert/update · reverses_id ที่ตั้งแล้วแช่แข็งบน update · นิยามบรรทัดเงินสดตรงกันสามที่ · ด่านใหม่ไม่ถามสิทธิ์';
end $$;
