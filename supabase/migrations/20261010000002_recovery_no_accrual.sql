-- ============================================================
-- SRI OS · ปิด **ช่องปั๊มรายได้ไม่จำกัด** ของหมวด "หนี้สูญได้รับคืน"
--   ต่อจาก 20261010000001_recovery_cap_and_delta.sql ซึ่ง **ห้ามแก้**
--   (แก้ได้เฉพาะคอมเมนต์สมมติฐานที่ผิดที่หัวไฟล์นั้น ซึ่งแก้แล้วในรอบนี้)
--
-- ย้อนกลับ (rollback):
--   drop trigger if exists trg_lines_recovery_no_receivable on sri_os.transaction_lines;
--   drop trigger if exists trg_txn_recovery_no_receivable   on sri_os.transactions;
--   drop function if exists sri_os.fn_recovery_no_receivable_guard();
--   drop function if exists sri_os.fn_assert_recovery_no_receivable(uuid);
--   -- และถ้าจะย้อน **ตารางกฎ** ด้วย ต้องใส่ accrualCoa กลับใน
--   --   src/lib/rules/tx-rules.ts แล้ว npm run sync:rules (ห้ามแก้ txn_types ด้วยมือ)
--   **ย้อนแล้วอาการกลับมาทั้งหมด**: ลงใบ Dr 1220 / Cr 4320 ได้ → ปลุกลูกหนี้ของหนี้
--   ที่ตัดออกจากสมุดไปแล้วขึ้นมาใหม่โดยไม่มีเงินเข้า แล้ววนปั๊มเพดานของ 4320 ขึ้นเอง
--   ได้ไม่สิ้นสุด (ผู้ตรวจรันแล้ว 4 รอบ → 4320 = 150,000 จากหนี้จริง 30,000)
--   ถ้าย้อนเพราะด่านกันของที่ถูก ให้แก้เกณฑ์ในฟังก์ชัน **ไม่ใช่ถอดด่าน**
--
-- ------------------------------------------------------------
-- รูที่ปิด · "ตั้งค้างรับ" ของหมวดรับคืน = ฐานให้ปั๊มเพดานของตัวเอง
-- ------------------------------------------------------------
-- `inc.bad_debt_recovered` มี `accrualCoa: "1220"` ในตารางกฎ (ใส่ไว้ให้ครบตามกฎ
--   "หมวดที่เงินเคลื่อนต้องมีบัญชีพัก") · แต่ `accrual_coa_code` **ไม่ใช่แค่เรื่องของ
--   ฟอร์ม**: `fn_assert_line_coa_in_rules` อ่าน **ชุดบัญชีที่หมวดนั้นลงได้** จาก
--   txn_types ซึ่งรวม `accrual_coa_code` → ใบ **Dr 1220 / Cr 4320** ผ่านทุกด่าน
--   = ปลุกลูกหนี้ของหนี้ที่ตัดออกจากสมุดไปแล้วขึ้นมาใหม่ **โดยไม่มีเงินเข้าเลย**
--   (ขัดกับคอมเมนต์ของหมวดเองที่เขียนว่า "รับรู้เป็นรายได้ ไม่ปลุกลูกหนี้")
--
-- แล้ววนได้เป็นวง (ผู้ตรวจรันพิสูจน์แล้ว · ไม่ใช่สมมติฐาน):
--   1. ลูกหนี้ปลอม 30,000 นั้น **ดัน cap ของค่าเผื่อขึ้น** (ค่าเผื่อ ≤ ลูกหนี้รวม)
--   2. ตั้งค่าเผื่อ 30,000 ได้
--   3. ตัดหนี้สูญ (Dr 1290 / Cr 1220) → นับเป็น **ยอดตัดหนี้สูญสะสม**
--   4. → เพดานของ 4320 สูงขึ้น → รับคืนได้อีก → กลับข้อ 1
--   **4 รอบ → 4320 = 150,000** จากหนี้จริง 30,000 · เงินเข้าจริง 30,000
--   ผ่านทุกด่าน งบดุลสะอาด ไม่มีอะไรฟ้อง (ด่านเดิมกันแค่ "เกินเพดาน"
--   แต่ **เพดานถูกปั๊มได้**)
--
-- ------------------------------------------------------------
-- คุณสมบัติที่ต้องเป็นจริง และทำไมต้องปิดสองชั้น
-- ------------------------------------------------------------
-- P1 การรับคืนหนี้สูญ **สร้างลูกหนี้ไม่ได้** — เงินที่เก็บคืนได้คือเงินที่เข้ามาจริง
--    ไม่ใช่สิทธิ์ที่จะได้รับ · "ตั้งค้างรับของการรับคืนหนี้สูญ" ไม่มีความหมายทางบัญชี
-- P2 เพดานของ 4320 ต่อผู้ถือ **ห้ามสูงขึ้นเองโดยไม่มีเงินเข้าจริง**
--
--   ชั้นที่ 1 · **ตารางกฎ** (src/lib/rules/tx-rules.ts) ถอด `accrualCoa` ของหมวดนี้ออก
--     + sync ลง txn_types → ด่านระดับบรรทัด **เดิม** ปฏิเสธบรรทัด 1220 ของหมวดนี้เอง
--     ที่เดียวที่กฎอยู่คือตารางกฎ ไม่มีคู่บัญชีกระจายมาอยู่ในไฟล์นี้
--
--   ชั้นที่ 2 · **ไฟล์นี้** · กติกาที่ไม่พึ่งตารางกฎเลย:
--     ใบที่ **รับรู้รายได้ 4320** (เครดิตสุทธิ > 0) ต้องมีขาเดบิตเป็น **เงินสด 11xx**
--     เท่านั้น · เดบิตบัญชีอื่น (ลูกหนี้ · ค่าเผื่อ · ทรัพย์) = ปฏิเสธ
--
--   ทำไมต้องชั้นที่ 2: กฎที่พึ่งตารางกฎอย่างเดียว **หายไปได้เงียบๆ สองทาง** —
--     มีคนเติม `accrualCoa` กลับ (รีวิวหลุด) หรือ DB ถือ seed รุ่นเก่าอยู่
--     (เคยเกิดจริง: ผังบัญชีใน DB ขาด 3 รหัสแล้วรายการข้ามผู้ถือถูกปฏิเสธหมด
--      โดยไม่มีอะไรดังขึ้นก่อน) · ชั้นที่ 2 ทำให้ "ปั๊มได้อีกครั้ง" ต้องถอด **ด่าน**
--     ไม่ใช่แค่แก้ **ข้อมูลกฎ** · เทสต์ N3 จำลองการถอยกลับของตารางกฎแล้วพิสูจน์ว่า
--     วงปั๊มยังพังทุกรอบ
--
-- **ทำไมเกณฑ์เป็น "เดบิตต้องเป็นเงินสด" ไม่ใช่ "ห้ามเดบิตลูกหนี้"**
--   เขียนเป็น allow-list เพราะ deny-list ต้องไล่ชื่อบัญชีลูกหนี้ให้ครบ และ
--   **บัญชีลูกหนี้ตัวที่สี่ในอนาคตจะหลุดเงียบๆ** (1200/1210/1220 วันนี้) ·
--   ที่สำคัญกว่า: เดบิตบัญชีอื่นที่ไม่ใช่เงินสดก็เปิดช่องแบบเดียวกันได้
--   (เช่น Dr 1290 / Cr 4320 = กลับค่าเผื่อผ่านบัญชีรายได้ ซึ่งซ่อนค่าใช้จ่ายที่รับรู้ไว้)
--   P1 พูดถึง **เงินที่เข้ามาจริง** ตรงๆ → allow-list ตรงกับกติกาที่ต้องการที่สุด
--
-- **ไม่แก้หมวดอื่นในรอบนี้** · หมวดอื่นที่มี `accrualCoa` แล้วชวนสงสัยว่าตั้งค้าง
--   มีความหมายจริงไหม (`fin.loan_bank` · `fin.loan_director` · `fin.loan_other` ·
--   `fin.capital` · `fin.deposit_received` ซึ่งพักที่ 1220 เหมือนกัน) **รายงานไว้
--   ให้ตัดสินใจก่อน** — เปลี่ยนตารางกฎหลายหมวดพร้อมกันเสี่ยงเกิน
--   เส้นทางที่ยังเหลือและต้องปิดต่อ: ใบ Dr 1220 / Cr 2410 (กู้ที่ยังไม่ได้รับเงิน)
--   สร้างลูกหนี้ปลอมได้เหมือนกัน แล้วตัดหนี้สูญก้อนนั้นก็ดันเพดานของ 4320 ขึ้นได้
--   (รอบนี้ปิดเฉพาะเส้นทางที่วิ่งผ่าน **หมวดรับคืนเอง** ซึ่งเป็นวงที่ปั๊มตัวเองได้)
--
-- idempotent: create or replace · drop trigger if exists ก่อน create ทุกตัว
-- ============================================================

set search_path = sri_os, public;

-- ------------------------------------------------------------
-- 0 · ของที่ไฟล์นี้พึ่ง ต้องมีอยู่จริงก่อน
--     ด่านที่อ้างรหัสที่ไม่มีในผังบัญชีจะ **ผ่านทุกเคส** แล้วดูเหมือนติดตั้งแล้ว
-- ------------------------------------------------------------
do $do$
declare v text;
begin
  select string_agg(x.code, ', ' order by x.code) into v
    from (values ('4320'), ('1100'), ('1200'), ('1210'), ('1220'), ('1290')) as x(code)
   where not exists (select 1 from sri_os.chart_of_accounts c where c.code = x.code);
  if v is not null then
    raise exception 'ผังบัญชีใน DB ขาดรหัสที่ด่านนี้ต้องใช้: % — รัน npm run sync:rules แล้ว apply ไฟล์ seed ก่อนไฟล์นี้ ไม่งั้นด่านจะคิดยอดได้ 0 แล้วผ่านทุกเคสเงียบๆ', v;
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'sri_os' and p.proname = 'fn_assert_recovery_within_writeoff') then
    raise exception 'ไม่พบ sri_os.fn_assert_recovery_within_writeoff — ไฟล์นี้ต่อจาก 20261010000001_recovery_cap_and_delta.sql ต้อง apply ไฟล์นั้นก่อน (ไฟล์นี้ปิดช่องที่ **ปั๊มเพดาน** ของด่านนั้น ไม่ได้แทนที่มัน)';
  end if;
end $do$;

-- ------------------------------------------------------------
-- 1 · ด่านใหม่ · "ใบที่รับรู้หนี้สูญได้รับคืน ต้องเป็นเงินสดเข้าจริงเท่านั้น"
--
-- ตัดสินจาก **ผลทางบัญชีของใบ** ไม่ใช่จากรหัสหมวด (กฎ CLAUDE.md ห้ามเช็ครหัสหมวด
--   ในโค้ด) — ใบไหนก็ตามที่เครดิตสุทธิ 4320 > 0 คือใบที่รับรู้รายได้ก้อนนี้
--   ไม่ว่าจะมาจากหมวดใด และไม่ว่าตารางกฎจะอนุญาตบรรทัดอะไรไว้
--
-- **ทิศทางสำคัญ**: ยิงเฉพาะใบที่ **เพิ่ม** รายได้รับคืน (เครดิตสุทธิ > 0)
--   ใบกลับรายการของใบรับคืน (Dr 4320 / Cr 1100) มีเครดิตสุทธิ **ติดลบ**
--   จึงไม่ถูกแตะ — ไม่งั้นด่านจะไปบล็อกการแก้ที่ถูกต้อง (บทเรียนข้อ 1 ของ D-103)
--
-- ใบที่ void ไม่อยู่ในยอดไหนเลย → ไม่ต้องตัดสินรูปของมัน (เหมือนด่านอื่นในชุดนี้)
--
-- security definer: ถ้าอ่านบรรทัดตามสิทธิ์ผู้เรียก คนที่มองบรรทัดนั้นไม่เห็น
--   จะได้ยอด 0 แล้วหลุดด่านไปเฉยๆ · ไม่เรียก fn_can เลย — กฎเงินปิดจาก Settings ไม่ได้
-- ------------------------------------------------------------
create or replace function fn_assert_recovery_no_receivable(p_txn uuid) returns void
language plpgsql security definer set search_path = '' as $fn$
declare
  v_status   text;
  v_recovery numeric(18,2);
  v_bad      text;
begin
  if p_txn is null then return; end if;

  select t.status::text into v_status from sri_os.transactions t where t.id = p_txn;
  -- หัวรายการไม่มี (ลบในธุรกรรมเดียวกัน) หรือ void → ไม่ใช่เรื่องของด่านนี้
  if v_status is null or v_status = 'void' then return; end if;

  select coalesce(sum(case when c.code = '4320' then l.credit - l.debit else 0 end), 0)
    into v_recovery
    from sri_os.transaction_lines l
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where l.transaction_id = p_txn;

  if v_recovery <= 0 then return; end if;

  -- ขาตรงข้ามของรายได้ก้อนนี้ต้องเป็นเงินสด/เงินฝาก 11xx เท่านั้น
  -- (เกณฑ์ 11xx ชุดเดียวกับ fn_assert_line_bank_is_cash และ fn_assert_no_floating_cash)
  select string_agg(x.code || ' ' || x.name_th || ' (' || x.net || ')', ' · ' order by x.code)
    into v_bad
    from (
      select c.code, max(c.name_th) as name_th, sum(l.debit - l.credit) as net
        from sri_os.transaction_lines l
        join sri_os.chart_of_accounts c on c.id = l.coa_id
       where l.transaction_id = p_txn
         and c.code <> '4320'
         and c.code !~ '^11[0-9][0-9]$'
       group by c.code
      having sum(l.debit - l.credit) > 0
    ) x;

  if v_bad is null then return; end if;

  raise exception 'ใบที่รับรู้ "หนี้สูญได้รับคืน" (เครดิต 4320 สุทธิ %) ลงเดบิตที่บัญชีซึ่งไม่ใช่เงินสด: % — หนี้สูญได้รับคืน **รับรู้ได้เฉพาะเงินที่เข้าบัญชีจริง** เพราะลูกหนี้ก้อนนั้นออกจากสมุดไปแล้ว ยอดค้างรับของมันจึงไม่มีความหมายทางบัญชี · ถ้าเงินยังไม่เข้า ให้รอจนเงินเข้าแล้วจึงบันทึกใบนี้ · ถ้าลูกหนี้ก้อนนี้ยังอยู่ในสมุด ให้ลงที่หมวดรับชำระค้างรับ (Dr เงินสด / Cr ลูกหนี้) เพื่อให้ลูกหนี้ลดลงจริง — ไม่งั้นลูกหนี้ที่ปลุกกลับมาจะกลายเป็นฐานให้ตั้งค่าเผื่อและตัดหนี้สูญรอบใหม่ ซึ่งดันเพดาน "รับคืนไม่เกินยอดที่ตัด" ขึ้นเองเป็นวงไม่สิ้นสุด',
    v_recovery, v_bad;
end $fn$;

comment on function fn_assert_recovery_no_receivable(uuid) is
  'ด่านของช่องปั๊มรายได้ (D-106) · ใบที่เครดิตสุทธิ 4320 > 0 ต้องมีขาเดบิตเป็นเงินสด 11xx เท่านั้น — เดบิตลูกหนี้/ค่าเผื่อ/บัญชีอื่นถูกปฏิเสธ · ตัดสินจากผลทางบัญชีของใบ ไม่ใช่รหัสหมวด จึงไม่พึ่งตารางกฎ (กฎชั้นที่สองที่ยังอยู่แม้ accrual_coa_code ของหมวดจะถูกเติมกลับ) · ยิงเฉพาะใบที่ **เพิ่ม** รายได้รับคืน ใบกลับรายการ (Dr 4320) จึงลงได้ · ใบที่ void ข้ามไป';

-- ------------------------------------------------------------
-- 2 · trigger — ผูกทั้งฝั่งบรรทัดและฝั่งหัวรายการ
--
--   ฝั่งบรรทัด: บรรทัดเข้า/ออก/ย้ายใบ เปลี่ยนรูปของใบได้
--     อ่าน old/new ตาม `tg_op` · **ห้ามถาม "มีแถวนี้ไหม" ด้วย ROW IS NOT NULL**
--     (เป็นจริงเฉพาะเมื่อทุกคอลัมน์ไม่เป็น null → แถวจริงเกือบทุกแถวตอบ false
--      แล้วด่านจะตาบอดเงียบๆ · รูที่ 2 ของ D-105)
--   ฝั่งหัวรายการ: `update transactions set status` คืนสภาพใบที่ void ไว้ได้
--     โดยไม่แตะบรรทัดเลย → ด่านที่ผูกแค่บรรทัดจะไม่ยิง
--
-- **ชื่อ trigger/ฟังก์ชันใหม่ ไม่ทับของ 20261010000001** (บทเรียน D-104:
--   create or replace ของไฟล์ที่รันทีหลังลบกติกาของไฟล์ก่อนหน้าได้เงียบๆ)
--   → ด่านค่าเผื่อ/ลูกหนี้ติดลบ/cap ของ 4320 ยังเป็นของไฟล์นั้นทั้งหมด
--
-- constraint trigger deferrable initially deferred: ต้องเห็น **ใบทั้งใบ**
--   จึงตัดสินได้ (ขาเงินสดกับขารายได้เขียนทีละบรรทัด)
-- ------------------------------------------------------------
create or replace function fn_recovery_no_receivable_guard() returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  if tg_table_name = 'transactions' then
    -- insert/update เท่านั้น (ลบใบที่ post แล้วถูกห้ามด้วยด่านอื่นอยู่แล้ว)
    perform sri_os.fn_assert_recovery_no_receivable(new.id);
    return null;
  end if;

  -- transaction_lines · UPDATE ย้ายบรรทัดข้ามใบได้ → ตรวจทั้งใบปลายทางและใบต้นทาง
  if tg_op <> 'DELETE' then
    perform sri_os.fn_assert_recovery_no_receivable(new.transaction_id);
  end if;
  if tg_op <> 'INSERT' then
    perform sri_os.fn_assert_recovery_no_receivable(old.transaction_id);
  end if;
  return null;
end $fn$;

comment on function fn_recovery_no_receivable_guard() is
  'trigger function ของด่าน D-106 · ใช้ตัวเดียวกับทั้งสองตาราง แยกด้วย tg_table_name · อ่าน old/new ตาม tg_op (ห้ามใช้ ROW IS NOT NULL ถามว่ามีแถวไหม) · ตรวจทั้งใบปลายทางและใบต้นทางเพราะ UPDATE ย้ายบรรทัดข้ามใบได้';

drop trigger if exists trg_lines_recovery_no_receivable on transaction_lines;
create constraint trigger trg_lines_recovery_no_receivable
  after insert or update or delete on transaction_lines
  deferrable initially deferred
  for each row execute function fn_recovery_no_receivable_guard();

drop trigger if exists trg_txn_recovery_no_receivable on transactions;
create constraint trigger trg_txn_recovery_no_receivable
  after insert or update on transactions
  deferrable initially deferred
  for each row execute function fn_recovery_no_receivable_guard();

-- ------------------------------------------------------------
-- 3 · ACL — ฟังก์ชันใหม่ติด PUBLIC EXECUTE มาจาก Postgres ต้องปิด
--     (20261007000007 revoke เป็นชุด **ตอนที่มันรัน** ฟังก์ชันที่เพิ่มทีหลังไม่ถูกครอบ)
-- ------------------------------------------------------------
revoke all on function fn_assert_recovery_no_receivable(uuid) from public;
revoke all on function fn_recovery_no_receivable_guard()      from public;
do $do$
begin
  execute 'revoke all on function sri_os.fn_assert_recovery_no_receivable(uuid) from anon, authenticated';
  execute 'revoke all on function sri_os.fn_recovery_no_receivable_guard()      from anon, authenticated';
end $do$;

-- ------------------------------------------------------------
-- 4 · guard ท้ายไฟล์ — ต้องดังถ้าผลลัพธ์ไม่ตรงกับที่ไฟล์นี้อ้าง
--
--   สองเรื่องที่เป็น **warning ไม่ใช่ raise** โดยตั้งใจ:
--   · ลำดับของ seed ตารางกฎ (ชั้นที่ 1) ไม่ได้อยู่ในมือไฟล์นี้ — ถ้า raise
--     migrate จะล้มเพราะไฟล์ seed ยังไม่ถูก apply ซึ่งแก้ด้วยไฟล์นี้ไม่ได้
--     (เทสต์ `zz_recovery_no_accrual_test.sql` N0 เป็นคน **บังคับ** เรื่องนี้แบบ hard fail)
--   · ประวัติที่ขัดกฎใหม่ต้องตามแก้ด้วยมือตามเคส (reverse + ลงใหม่)
-- ------------------------------------------------------------
do $do$
declare v text; n int; v_type int; v_defer boolean; v_init boolean; v_con oid;
begin
  foreach v in array array['transaction_lines|trg_lines_recovery_no_receivable',
                           'transactions|trg_txn_recovery_no_receivable'] loop
    select t.tgtype, t.tgdeferrable, t.tginitdeferred, t.tgconstraint
      into v_type, v_defer, v_init, v_con
      from pg_trigger t
     where t.tgrelid = ('sri_os.' || split_part(v, '|', 1))::regclass
       and t.tgname = split_part(v, '|', 2);
    if v_type is null then
      raise exception 'ติดตั้ง trigger % ไม่สำเร็จ', v;
    end if;
    if not (v_defer and v_init and v_con <> 0) then
      raise exception 'trigger % ไม่ใช่ constraint trigger ที่เลื่อนไว้ — ด่านจะตัดสินก่อนที่ใบจะเขียนครบ', v;
    end if;
  end loop;

  -- ด่านของไฟล์ก่อนหน้าต้องยังอยู่ (ไฟล์นี้ไม่ได้ create or replace ทับของใคร)
  foreach v in array array['fn_assert_recovery_within_writeoff', 'fn_assert_allowance_limits',
                           'fn_assert_receivable_not_negative', 'fn_allowance_guard',
                           'fn_txn_allowance_guard'] loop
    if not exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                    where ns.nspname = 'sri_os' and p.proname = v) then
      raise exception 'ด่านเดิม % หายไปหลังรันไฟล์นี้', v;
    end if;
  end loop;

  -- ชั้นที่ 1 · ตารางกฎใน DB ยังถือบัญชีพักของหมวดที่แตะ 4320 อยู่ไหม
  select string_agg(t.code, ', ' order by t.code) into v
    from sri_os.txn_types t
   where (t.dr_coa_code = '4320' or t.cr_coa_code = '4320')
     and t.accrual_coa_code is not null;
  if v is not null then
    raise warning 'txn_types ยังถือ accrual_coa_code ของหมวดที่แตะ 4320: % — ด่านระดับบรรทัดยังยอมให้ลงบรรทัดนั้นได้ (ชั้นที่ 1 ยังไม่ถูก apply) · รัน npm run sync:rules แล้ว apply ไฟล์ seed · ด่านของไฟล์นี้ยังกันวงปั๊มไว้ให้ แต่ต้องปิดทั้งสองชั้น', v;
  end if;

  -- ประวัติที่ขัดกฎใหม่ (ถ้ามี) — ตามแก้ด้วย reverse + ลงใหม่ ไฟล์นี้ไม่แก้ข้อมูลเก่า
  select count(distinct t.id) into n
    from sri_os.transactions t
   where t.status <> 'void'
     and exists (select 1 from sri_os.transaction_lines l
                   join sri_os.chart_of_accounts c on c.id = l.coa_id
                  where l.transaction_id = t.id and c.code = '4320')
     and (select coalesce(sum(case when c.code = '4320' then l.credit - l.debit else 0 end), 0)
            from sri_os.transaction_lines l
            join sri_os.chart_of_accounts c on c.id = l.coa_id
           where l.transaction_id = t.id) > 0
     and exists (select 1 from sri_os.transaction_lines l
                   join sri_os.chart_of_accounts c on c.id = l.coa_id
                  where l.transaction_id = t.id and c.code <> '4320'
                    and c.code !~ '^11[0-9][0-9]$' and l.debit > l.credit);
  if n > 0 then
    raise warning 'มีใบหนี้สูญได้รับคืน % ใบในสมุดที่ลงเดบิตบัญชีซึ่งไม่ใช่เงินสด (ขัดกฎใหม่) — ต้องกลับรายการแล้วลงใหม่ตามเคส · ยอด 4320 สะสมของผู้ถือนั้นอาจถูกปั๊มไว้แล้ว ให้กระทบยอดกับเงินที่เข้าบัญชีจริงก่อนปิดงวด', n;
  end if;

  raise notice 'ok 20261010000002 · ด่าน "รับคืนหนี้สูญต้องเป็นเงินเข้าจริง" ติดตั้งแล้วทั้งฝั่งบรรทัดและหัวรายการ · ด่านเดิมของ 20261010000001 ยังอยู่ครบ';
end $do$;
