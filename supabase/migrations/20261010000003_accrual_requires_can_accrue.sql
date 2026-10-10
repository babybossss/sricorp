-- ============================================================
-- SRI OS · ปิดช่อง **mint ลูกหนี้ปลอม** ที่เหลือ
--   "บัญชีตั้งค้างของหมวดใด ลงบรรทัดได้ต่อเมื่อหมวดนั้นตั้งค้างได้จริง"
--   ต่อจาก 20261010000002_recovery_no_accrual.sql ซึ่ง **ห้ามแก้**
--
-- ย้อนกลับ (rollback):
--   drop trigger  if exists trg_lines_rule_coa_accrual on sri_os.transaction_lines;
--   drop function if exists sri_os.fn_assert_line_accrual_can_accrue();
--   (ไฟล์นี้ **ไม่แก้ข้อมูลเดิมและไม่ create or replace ของใคร** → ย้อนแล้วสภาพ
--    กลับไปเท่าก่อนไฟล์นี้พอดี ไม่ต้องตามแก้อย่างอื่น)
--   **ย้อนแล้วอาการกลับมาทั้งหมด**: เขียน SQL ตรงลงบรรทัด 1220 ของ 16 หมวด
--   ที่ตั้งค้างไม่ได้ (และ 2100 ของอีก 11 หมวด) ได้อีก → ลูกหนี้/เจ้าหนี้ปลอม
--   → ดันเพดานค่าเผื่อ → ตัดหนี้สูญ → ดันเพดาน 4320 = ช่องปั๊มรายได้เปิดอีกครั้ง
--   ถ้าย้อนเพราะด่านกันของที่ถูก **ให้แก้ธง can_accrue ในตารางกฎ (src/lib/rules/
--   tx-rules.ts) + sync:rules ไม่ใช่ถอดด่าน** — ด่านนี้ไม่มีเกณฑ์ของตัวเองเลย
--   มันบังคับสิ่งที่ตารางกฎพูดอยู่แล้ว
--
-- ------------------------------------------------------------
-- รูที่ปิด · ด่านฝั่ง DB **ไม่เคยอ่านธง can_accrue**
-- ------------------------------------------------------------
-- `fn_assert_line_coa_in_rules` (20261008000013) สร้างชุดบัญชีที่หมวดหนึ่งลงได้จาก
--   array[dr_coa_code, cr_coa_code, gain_coa_code, loss_coa_code,
--         interest_coa_code, accrual_coa_code]
--   โดยใส่ `accrual_coa_code` **แบบไม่มีเงื่อนไข** · คำว่า `can_accrue` ไม่ปรากฏ
--   ในด่านฝั่ง DB เลยแม้ครั้งเดียว (grep ได้ 0 ครั้ง)
--
-- ขณะที่ตารางกฎฝั่งโค้ด (src/lib/rules/tx-rules.ts · วัดจากโค้ด 10/10):
--   · 23 หมวด ตั้งค้างได้จริง (`canAccrueFromForm()` = true → `can_accrue` = true)
--     พักที่ 1200 (ลูกหนี้ค่าเช่า) · 1210 (ลูกหนี้ดอกเบี้ย) · 2100 (เจ้าหนี้ค้างจ่าย)
--   · **27 หมวด ประกาศ `accrualCoa` ไว้ทั้งที่ตั้งค้างไม่ได้** — ในนั้น
--     16 หมวดชี้ไป `1220 ลูกหนี้อื่น` ซึ่ง **ไม่มีหมวดสำหรับล้างเลย**
--     และ 11 หมวดชี้ไป `2100` แต่คนละกระแสเงินสดกับหมวดที่ล้างได้
--
-- `accrual_coa_code` ตอบแค่ว่า "ถ้าเงินยังไม่เคลื่อน ยอดไปพักที่ไหน" (ข้อมูลที่
--   กลไกยืนยันรับ-จ่ายต้องใช้) · มันไม่ได้ตอบว่า "คีย์ค้างได้" — คนที่ตอบคือ
--   `can_accrue` ซึ่งแคบกว่า (ต้องมีหมวดล้างที่อยู่กระแสเงินสดหมวดเดียวกันด้วย
--   ดู 20261006000003_txn_types_can_accrue.sql)
--
-- ผล: **กฎเดียวกันอยู่สองที่แล้วไม่ตรงกัน** — ตารางกฎบอก "หมวดนี้ตั้งค้างไม่ได้"
--   แต่ฐานข้อมูลบอก "ลงบรรทัดนั้นได้" · ฟอร์มปฏิเสธ (engine ถาม accrualCheck())
--   แต่ SQL ตรง / automation / สคริปต์นำเข้า ลงได้หมด
--
-- วงปั๊มที่เปิดอยู่ (ต่อจากวงที่ 20261010000002 ปิดเฉพาะขาที่วิ่งผ่านหมวดรับคืนเอง):
--   1. ลง Dr 1220 / Cr 4900 ด้วย `inc.other` (หรือ Dr 1220 / Cr 2410 ด้วย
--      `fin.loan_bank` = "กู้ที่ยังไม่ได้รับเงิน" ซึ่งหัว 20261010000002 ชี้ไว้แล้ว
--      ว่าเป็นเส้นทางที่ยังเหลือ) → **ลูกหนี้ปลอมที่ไม่มีทางล้าง**
--   2. ลูกหนี้ปลอมดันเพดานค่าเผื่อ (ค่าเผื่อ ≤ ลูกหนี้รวมต่อผู้ถือ)
--   3. ตัดหนี้สูญ (Dr 1290 / Cr 1220) → ดันยอดตัดหนี้สูญสะสม
--   4. → เพดานของ `4320 หนี้สูญได้รับคืน` สูงขึ้นเองโดยไม่มีเงินเข้าจริง
--
-- ------------------------------------------------------------
-- คุณสมบัติที่บังคับ และทำไมเขียนเป็น trigger **ชื่อใหม่แยก**
-- ------------------------------------------------------------
-- P1 บรรทัดที่ใช้ `accrual_coa_code` ของหมวดนั้น ลงได้ต่อเมื่อ `can_accrue` = true
--    ผูกกับ **ธง** ไม่ใช่กับ "มีค่าใน accrual_coa_code"
-- P2 ไม่กันแน่นเกิน — 23 หมวดที่ตั้งค้างได้จริงยังลงได้ทุกหมวด · การล้างค้าง
--    (`inv.collect_rent` · `inv.collect_interest` · `fin.pay_payable`) ยังทำได้
--    เพราะหมวดล้างใช้บัญชีนั้นเป็น **dr/cr ของตัวเอง** ไม่ใช่เป็นบัญชีตั้งค้าง
--    และบัญชี gain/loss/interest ในชุดที่อนุญาตไม่ถูกแตะเลย
--
-- **ทำไมไม่ `create or replace fn_assert_line_coa_in_rules` ให้ถูกไปเลย**
--   (ถ้าทำได้จะสะอาดกว่า เพราะกฎอยู่ที่เดียว — แต่ทำไม่ได้อย่างปลอดภัย)
--   1. `20261008000013` สร้างฟังก์ชันนั้น และมัน **อยู่ใน `UNDER_TEST` ของ
--      scripts/test-rls-local.sh และใน migration-order.txt** · ลำดับจริงที่ยืนยันแล้ว:
--      ไฟล์ที่ไม่อยู่ในสองรายการนั้นจะรัน **ก่อน** ทั้งชุด → ถ้าไฟล์นี้ยังไม่ถูกเติม
--      เข้ารายการ (หรือถูกถอดออกวันหน้า) การ replace จะถูก **เขียนทับเงียบๆ**
--      แล้วด่านหายไปโดยไม่มีอะไรดังขึ้น = บั๊กเดิมกลับมาแบบไม่มีใครรู้
--      นี่คือกับดักเดียวกับ D-104 (`fn_corporate_requires_evidence` ถูกไฟล์ที่รัน
--      ทีหลังสร้างทับ) ซึ่งแก้ด้วย **trigger ชื่อใหม่ที่ไฟล์ทีหลังไม่รู้จัก**
--   2. ไฟล์นี้จึงไม่ `replace` ของใครเลย · ด่านใหม่เป็น **ส่วนเติมเต็ม** ของด่านเดิม:
--      ด่านเดิมตอบ "บัญชีนี้อยู่ในชุดของหมวดไหม" · ด่านใหม่ตอบ "ถ้ามันเข้าชุดมา
--      ในฐานะบัญชีตั้งค้าง หมวดนี้ตั้งค้างได้จริงไหม" · ไม่มีคู่บัญชีสำเนาที่นี่
--      ทั้งสองอ่าน `sri_os.txn_types` ที่เดียว
--
-- **ชื่อ trigger ต้องเรียงหลังด่านเดิม** — trigger ระดับแถวยิงตามลำดับชื่อ
--   `trg_lines_rule_coa_accrual` > `trg_lines_rule_coa` > `trg_lines_immutable_after_post`
--   (เรียงแบบ C) → กฎ "แก้ของที่บันทึกแล้วไม่ได้" และ "บัญชีต้องเป็นของผู้ถือ"
--   ยังเป็นคนพูดก่อนเสมอ · ถ้าด่านนี้พูดก่อน ข้อความที่ผู้ใช้เห็นจะชี้ผิดจุด
--   และเทสต์เก่าที่ตรวจข้อความจะแดง (เคส CA7 ของ zz_accrual_can_accrue_test
--   บังคับพฤติกรรมนี้ไว้ ไม่ใช่เชื่อชื่อ)
--
-- **ไม่แก้ตารางกฎในรอบนี้** · 27 หมวดนั้นยังถือ `accrualCoa` ไว้ตามเดิม
--   (ข้อมูลที่กลไกยืนยันรับ-จ่ายจะใช้) · ปิดที่ด่านครอบได้ทุกหมวดในที่เดียว
--   และแก้ตารางกฎ 27 แถวพร้อมกันเสี่ยงเกินกว่าผลที่ได้ · ข้อเสนอให้ทบทวนว่า
--   หมวดใดควร "ตั้งค้างได้จริง" (เช่น `fin.loan_bank` ที่เซ็นสัญญาแล้วเงินยังไม่เข้า)
--   ต้องมาพร้อม **หมวดสำหรับล้าง** ของบัญชีนั้น ไม่งั้นยอดค้างในงบดุลตลอดไป
--
-- idempotent: create or replace function · drop trigger if exists ก่อน create
-- ============================================================

set search_path = sri_os, public;

-- ------------------------------------------------------------
-- 0 · ของที่ไฟล์นี้พึ่ง ต้องมีอยู่จริงก่อน
--     ด่านที่อ่านคอลัมน์/ฟังก์ชันที่ไม่มี จะพังตอนยิง ไม่ใช่ตอน migrate
-- ------------------------------------------------------------
do $do$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'sri_os' and table_name = 'txn_types'
                    and column_name = 'can_accrue') then
    raise exception 'ไม่พบคอลัมน์ sri_os.txn_types.can_accrue — ต้อง apply 20261006000003_txn_types_can_accrue.sql ก่อนไฟล์นี้ (ด่านนี้คือการบังคับธงนั้นที่ฝั่ง DB)';
  end if;

  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'sri_os' and p.proname = 'fn_assert_line_coa_in_rules') then
    raise exception 'ไม่พบ sri_os.fn_assert_line_coa_in_rules — ไฟล์นี้เป็นส่วนเติมเต็มของด่านนั้น (20261008000013) ต้อง apply ไฟล์นั้นก่อน';
  end if;

  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'sri_os' and p.proname = 'fn_intercompany_coa') then
    raise exception 'ไม่พบ sri_os.fn_intercompany_coa(text) — ด่านนี้ต้องยกเว้นขาข้ามผู้ถือตามรหัสตรงของลักษณะนั้น (อ่านจากที่เดียวกับด่านเดิม)';
  end if;
end $do$;

-- ------------------------------------------------------------
-- 1 · ด่านใหม่ · "บัญชีตั้งค้างลงได้ ต่อเมื่อหมวดนั้นตั้งค้างได้จริง"
--
-- ไม่มีเกณฑ์ของตัวเองเลย · อ่านตารางกฎ `sri_os.txn_types` ที่เดียว
--   (ห้ามเช็ครหัสหมวดตรงๆ ในโค้ด — ถาม `can_accrue` ของหมวดที่ใบนั้นอ้างอิง)
--
-- security definer: ถ้าอ่านตารางกฎ/หัวรายการตามสิทธิ์ผู้เรียก คนที่มองแถวนั้นไม่เห็น
--   จะได้ null แล้ว **หลุดด่านไปเฉยๆ** (แพทเทิร์นเดียวกับด่านอื่นในชุดนี้)
-- ไม่เรียก fn_can เลย — กฎเงินปิดจากหน้า Settings ไม่ได้
-- ------------------------------------------------------------
create or replace function fn_assert_line_accrual_can_accrue() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_type    text;
  v_nature  text;
  v_code    text;
  v_accrual text;
  v_can     boolean;
  v_other   text[];
  v_pair    text[];
begin
  select t.txn_type_code, nullif(t.intercompany_nature, '')
    into v_type, v_nature
    from sri_os.transactions t
   where t.id = new.transaction_id;
  -- ไม่มีหัวรายการให้เทียบ → FK/ด่านอื่นปฏิเสธด้วยข้อความของมันเอง (ด่านนี้ไม่พูดซ้อน)
  if v_type is null then return new; end if;

  select c.code into v_code
    from sri_os.chart_of_accounts c where c.id = new.coa_id;
  -- รหัสที่ไม่มีในผังบัญชี เป็นเรื่องของ fn_assert_line_coa_in_rules
  if v_code is null then return new; end if;

  select t.accrual_coa_code, t.can_accrue,
         array_remove(array[t.dr_coa_code, t.cr_coa_code, t.gain_coa_code,
                            t.loss_coa_code, t.interest_coa_code], null)
    into v_accrual, v_can, v_other
    from sri_os.txn_types t
   where t.code = v_type;

  -- หมวดที่ตารางกฎไม่ได้ระบุบัญชีพัก หรือระบุแล้วและ **ตั้งค้างได้จริง** → ไม่ใช่เรื่องของด่านนี้
  if v_accrual is null or coalesce(v_can, false) then return new; end if;
  if v_code <> v_accrual then return new; end if;

  -- บัญชีเดียวกันอาจเป็นคู่บัญชี/กำไร/ขาดทุน/ดอกเบี้ยของหมวดนั้นด้วย
  --   → บรรทัดนั้น **ไม่ใช่การตั้งค้าง** และต้องลงได้ตามปกติ (กันแน่นเกิน = ของที่ถูกลงไม่ได้)
  if v_code = any (v_other) then return new; end if;

  -- ขาข้ามผู้ถือ: เงินสด + รหัสตรงของลักษณะนั้นใช้ได้ (ชุดเดียวกับด่านเดิม
  --   อ่านจาก fn_intercompany_pairs() ที่เดียว ไม่มีสำเนาคู่บัญชีในไฟล์นี้)
  if v_nature is not null then
    v_pair := sri_os.fn_intercompany_coa(v_nature);
    if v_pair is not null and (v_code = '1100' or v_code = any (v_pair)) then
      return new;
    end if;
  end if;

  raise exception 'หมวด "%" **ตั้งค้างรับ-ค้างจ่ายไม่ได้** จึงลงบรรทัดบัญชี % ซึ่งเป็นบัญชีพักของหมวดนี้ไม่ได้ (ตารางกฎ: can_accrue = false) · บรรทัดที่ถูกปฏิเสธ: เดบิต % เครดิต % · บัญชีพักในตารางกฎตอบแค่ว่า "ถ้าเงินยังไม่เคลื่อน ยอดไปพักที่ไหน" ไม่ได้แปลว่าคีย์ค้างได้ — หมวดนี้ตั้งค้างไม่ได้เพราะบัญชีพักนั้นยังไม่มีหมวดสำหรับล้างในกระแสเงินสดหมวดเดียวกัน · ลงไว้จะค้างในงบดุลตลอดไป แล้วกลายเป็นฐานให้ตั้งค่าเผื่อและตัดหนี้สูญของหนี้ที่ไม่มีอยู่จริง (ซึ่งดันเพดาน "หนี้สูญได้รับคืน" ขึ้นเองโดยไม่มีเงินเข้า) · ถ้าเงินยังไม่เคลื่อนจริง ให้รอจนเงินเข้า-ออกแล้วบันทึกตอนนั้น · ถ้าหมวดนี้ควรตั้งค้างได้จริง ให้เพิ่มหมวดสำหรับล้างบัญชี % แล้วเปิดธงที่ src/lib/rules/tx-rules.ts (ห้ามแก้ txn_types ด้วยมือ)',
    v_type, v_code, new.debit, new.credit, v_accrual;
end $fn$;

comment on function fn_assert_line_accrual_can_accrue() is
  'ส่วนเติมเต็มของ fn_assert_line_coa_in_rules (D-107) · ด่านเดิมใส่ accrual_coa_code เข้าชุดบัญชีที่อนุญาต **แบบไม่มีเงื่อนไข** ไม่เคยอ่าน can_accrue → 27 หมวดที่ตั้งค้างไม่ได้ลงบรรทัดบัญชีพักของตัวเองได้ (16 หมวดชี้ 1220 ที่ไม่มีหมวดล้าง = mint ลูกหนี้ปลอม → ดันเพดานค่าเผื่อ/ตัดหนี้สูญ/4320) · ด่านนี้ปฏิเสธบรรทัดที่ใช้บัญชีพักของหมวดที่ can_accrue = false · ยกเว้นเมื่อบัญชีนั้นเป็น dr/cr/gain/loss/interest ของหมวดเดียวกัน หรือเป็นขาข้ามผู้ถือ (กันแน่นเกิน) · ไม่มีเกณฑ์ของตัวเอง อ่านตารางกฎที่เดียว · trigger ชื่อใหม่แยก ไม่ replace ของใคร (บทเรียน D-104)';

-- ------------------------------------------------------------
-- 2 · trigger · ชื่อเรียงหลังด่านเดิมโดยตั้งใจ (ดูเหตุผลที่หัวไฟล์)
--     ต้องครอบ **UPDATE** ด้วย: ลงบรรทัดที่ถูกก่อนแล้วแก้เป็นบัญชีพักในธุรกรรมเดียวกัน
--     เป็นเส้นทางที่เลี่ยงด่านที่ผูกแค่ INSERT ได้ (รูที่ 2 ของ D-105 เป็นแบบนี้)
--     DELETE ไม่ต้องครอบ — ถอนบรรทัดไม่ได้สร้างลูกหนี้ และกฎเหล็กข้อ 1 ห้ามอยู่แล้ว
-- ------------------------------------------------------------
drop trigger if exists trg_lines_rule_coa_accrual on transaction_lines;
create trigger trg_lines_rule_coa_accrual
  before insert or update on transaction_lines
  for each row execute function fn_assert_line_accrual_can_accrue();

-- ------------------------------------------------------------
-- 3 · ACL — ฟังก์ชันใหม่ติด PUBLIC EXECUTE มาจาก Postgres ต้องปิด
--     (20261007000007 revoke เป็นชุด **ตอนที่มันรัน** ของที่เพิ่มทีหลังไม่ถูกครอบ)
-- ------------------------------------------------------------
revoke all on function fn_assert_line_accrual_can_accrue() from public;
do $do$
begin
  execute 'revoke all on function sri_os.fn_assert_line_accrual_can_accrue() from anon, authenticated';
end $do$;

-- ------------------------------------------------------------
-- 4 · guard ท้ายไฟล์ — ต้องดังถ้าผลลัพธ์ไม่ตรงกับที่ไฟล์นี้อ้าง
-- ------------------------------------------------------------
do $do$
declare v text; n int; v_type int; v_src text;
begin
  -- (ก) trigger ต้องติดจริง ครอบ insert และ update ระดับแถว และเป็น BEFORE
  select t.tgtype into v_type from pg_trigger t
   where t.tgrelid = 'sri_os.transaction_lines'::regclass
     and t.tgname = 'trg_lines_rule_coa_accrual';
  if v_type is null then
    raise exception 'ติดตั้ง trigger trg_lines_rule_coa_accrual ไม่สำเร็จ — ไม่มีใครบังคับ can_accrue ที่ฝั่ง DB เลย';
  end if;
  if (v_type & 1) = 0 or (v_type & 2) = 0 or (v_type & 4) = 0 or (v_type & 16) = 0 then
    raise exception 'trg_lines_rule_coa_accrual ต้องเป็น before insert or update for each row (tgtype %) — ไม่ครอบ UPDATE = ลงถูกก่อนแล้วแก้เป็นบัญชีพักได้', v_type;
  end if;

  -- (ข) ลำดับชื่อ: ต้องยิง **หลัง** ด่านเดิมทุกตัวที่พูดเรื่องสิทธิ์เขียน/คู่บัญชี
  --     (ไม่งั้นข้อความที่ผู้ใช้เห็นจะชี้ผิดจุด และเทสต์เก่าที่ตรวจข้อความจะแดง)
  for v in select unnest(array['trg_lines_immutable_after_post', 'trg_line_bank_owner',
                               'trg_lines_rule_coa']) loop
    if exists (select 1 from pg_trigger t
                where t.tgrelid = 'sri_os.transaction_lines'::regclass and t.tgname = v)
       and not ('trg_lines_rule_coa_accrual' collate "C" > v collate "C") then
      raise exception 'ชื่อ trigger ของด่านใหม่เรียงก่อน % — trigger ยิงตามลำดับชื่อ ข้อความของกฎเดิมจะถูกแทนที่', v;
    end if;
  end loop;

  -- (ค) ด่านเดิมห้ามหาย และไฟล์นี้ต้องไม่ได้ไปแตะมัน (บทเรียน D-104)
  for v in select unnest(array['fn_assert_line_coa_in_rules', 'fn_assert_line_bank_is_cash',
                               'fn_assert_recovery_no_receivable', 'fn_assert_recovery_within_writeoff',
                               'fn_assert_allowance_limits', 'fn_assert_receivable_not_negative']) loop
    if not exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                    where ns.nspname = 'sri_os' and p.proname = v) then
      raise exception 'ด่านเดิม % หายไปหลังรันไฟล์นี้', v;
    end if;
  end loop;

  -- (ง) ด่านใหม่ต้องอ่าน can_accrue จริง (ไม่ใช่ตัดสินจาก "มีค่าใน accrual_coa_code")
  select p.prosrc into v_src from pg_proc p
   where p.oid = 'sri_os.fn_assert_line_accrual_can_accrue()'::regprocedure;
  if v_src !~ 'can_accrue' then
    raise exception 'ด่านใหม่ไม่ได้อ่าน can_accrue — เท่ากับไม่ได้ปิดอะไรเลย';
  end if;

  -- (จ) ด่านเดิมยังใส่ accrual_coa_code เข้าชุดที่อนุญาตอยู่ไหม
  --     ถ้าวันหนึ่งมีคนแก้ด่านเดิมให้ถูกเองแล้ว **กฎจะอยู่สองที่** → เตือนให้มาถอดด่านนี้
  --     (ไม่ raise: ไฟล์นี้ apply แล้วแก้ไม่ได้ และสภาพนั้นยังปลอดภัย เข้มซ้อนกันเฉยๆ)
  select p.prosrc into v_src from pg_proc p
   where p.oid = 'sri_os.fn_assert_line_coa_in_rules()'::regprocedure;
  if v_src !~ 'accrual_coa_code' then
    raise warning 'fn_assert_line_coa_in_rules ไม่ได้ใส่ accrual_coa_code เข้าชุดที่อนุญาตแล้ว — ด่านของไฟล์นี้กลายเป็นกฎซ้อน ให้พิจารณาถอด trg_lines_rule_coa_accrual ออกด้วย migration ใหม่ (กฎเดียวกันห้ามอยู่สองที่)';
  end if;

  -- (ฉ) ความจริงของตารางกฎในวันที่ apply — ถ้าไม่มีหมวดแบบนี้เลย ด่านนี้ไม่ได้ปิดอะไร
  select count(*) into n from sri_os.txn_types
   where can_accrue = false and accrual_coa_code is not null;
  if n = 0 then
    raise warning 'ตารางกฎใน DB ไม่มีหมวดที่ can_accrue = false แต่มี accrual_coa_code เลย — ด่านนี้จะไม่ปฏิเสธอะไร (DB อาจถือ seed รุ่นเก่า · ตรวจด้วย npm run check:sync)';
  end if;

  -- (ช) ประวัติที่ขัดกฎใหม่ (ถ้ามี) — ไฟล์นี้ไม่แก้ข้อมูลเก่า ต้องตามแก้ด้วย reverse + ลงใหม่
  select count(distinct l.transaction_id) into n
    from sri_os.transaction_lines l
    join sri_os.transactions t   on t.id = l.transaction_id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
    join sri_os.txn_types ty     on ty.code = t.txn_type_code
   where t.status <> 'void'
     and ty.can_accrue = false
     and ty.accrual_coa_code is not null
     and c.code = ty.accrual_coa_code
     and c.code <> all (array_remove(array[ty.dr_coa_code, ty.cr_coa_code, ty.gain_coa_code,
                                           ty.loss_coa_code, ty.interest_coa_code], null));
  if n > 0 then
    raise warning 'มีรายการ % ใบในสมุดที่ลงบรรทัดบัญชีพักของหมวดที่ตั้งค้างไม่ได้ (ขัดกฎใหม่) — ลูกหนี้/เจ้าหนี้ก้อนนั้นไม่มีทางล้าง ต้องกลับรายการแล้วลงใหม่ตามเคส และกระทบยอดค่าเผื่อ/ตัดหนี้สูญที่อาจถูกปั๊มจากมันก่อนปิดงวด', n;
  end if;

  raise notice 'ok 20261010000003 · ด่าน "บัญชีตั้งค้างต้องมาจากหมวดที่ตั้งค้างได้จริง" ติดตั้งแล้ว (trigger ชื่อใหม่ ไม่ทับของใคร) · ด่านเดิมอยู่ครบ';
end $do$;
