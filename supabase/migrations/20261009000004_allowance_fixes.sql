-- ============================================================
-- SRI OS · แก้ด่านค่าเผื่อหนี้สงสัยจะสูญให้วางถูกที่ + เพิ่มด่าน "ลูกหนี้ห้ามติดลบ"
--   (ข้อ 1 · 3 · 6 ที่ผู้ตรวจ BLOCK ไว้ · ต่อจาก 20261009000002_allowance_and_writeoff.sql
--    ซึ่ง **ห้ามแก้** เพราะ apply ไปแล้ว)
--
-- ย้อนกลับ (rollback):
--   -- คืนด่านรุ่นก่อนหน้า: รัน supabase/migrations/20261009000002_allowance_and_writeoff.sql
--   -- ซ้ำอีกครั้ง (ไฟล์นั้น idempotent) แล้วถอดของที่ไฟล์นี้เพิ่ม:
--   drop trigger  if exists trg_lines_receivable_sign on sri_os.transaction_lines;
--   drop trigger  if exists trg_txn_receivable_sign   on sri_os.transactions;
--   drop function if exists sri_os.fn_receivable_guard();
--   drop function if exists sri_os.fn_txn_receivable_guard();
--   drop function if exists sri_os.fn_assert_receivable_not_negative(uuid);
--   drop function if exists sri_os.fn_assert_allowance_limits(uuid, text);
--   **ย้อนแล้วอาการเดิมกลับมาทั้งสามข้อ**: ใบรับชำระของผู้ถือที่ตั้งค่าเผื่อไว้
--   จะถูกปฏิเสธอีก (เงินอยู่ในแบงก์แล้วแต่ลงสมุดไม่ได้ → ผู้ใช้จะลงรายได้ใหม่ = รายได้ซ้ำ)
--   และลูกหนี้ติดลบได้อีก · ถ้าย้อนเพราะด่านกันของที่ถูก ให้แก้เกณฑ์ในฟังก์ชัน ไม่ใช่ถอดด่าน
--
-- ------------------------------------------------------------
-- ข้อ 1 · ด่าน "ค่าเผื่อห้ามเกินลูกหนี้" วางผิดที่ — ร้ายแรงสุด
-- ------------------------------------------------------------
-- 20261009000002 เขียนด่านนี้เป็น **กติกาตลอดเวลา**: ทุกรายการที่แตะบัญชี
-- 1290/1200/1210/1220 ถูกตรวจว่า allowance <= receivable
--
-- ของจริงที่เกิด: ลูกหนี้ 30,000 · ตั้งค่าเผื่อ 20,000 · ลูกหนี้จ่ายมา 15,000
--   → ใบ **รับชำระ** ถูกปฏิเสธ เพราะหลังรับชำระ ค่าเผื่อ (20,000) > ลูกหนี้ (15,000)
--   → **เงินอยู่ในแบงก์แล้วแต่ลงสมุดไม่ได้** · ทางที่ผู้ใช้จะทำคือลง inc.rent ใหม่
--     = **รายได้ซ้ำ** ซึ่งแย่กว่าการไม่มีด่านเลย
--
-- สภาพ "ค่าเผื่อมากกว่าลูกหนี้" หลังรับชำระ **เป็นเรื่องจริงที่เกิดได้และไม่ใช่ความผิด**
-- (ตั้งเผื่อไว้ว่าจะไม่ได้ แล้วลูกหนี้จ่ายมาจริง) · ทางแก้คือ **กลับค่าเผื่อ**
-- (`adj.doubtful_release`) ซึ่งผู้ใช้ทำเองได้ · ถ้าจะเตือนให้เตือนในรายงาน ไม่ใช่ที่ trigger
--
-- **แก้เป็น**: ด่านยิงเฉพาะการเปลี่ยนแปลงที่ **ทำให้ค่าเผื่อเพิ่มขึ้น**
--   ตัดสินจาก **ผลทางบัญชีของแถวที่เปลี่ยน** (เครดิตสุทธิของ 1290 โตขึ้น)
--   ไม่ใช่จากรหัสหมวด — เส้นทางอื่นที่ทำให้ค่าเผื่อโตในอนาคตจะถูกครอบเอง
--   และหมวดที่ไม่แตะ 1290 เลย (รับชำระ · ตัดหนี้สูญ · กลับค่าเผื่อ) ไม่ถูกตรวจด้วยด่านนี้
--
-- ------------------------------------------------------------
-- ข้อ 3 · ด่านใหม่ · ยอดลูกหนี้ 1200/1210/1220 ต่อผู้ถือ ห้ามติดลบ
-- ------------------------------------------------------------
-- ลูกหนี้ติดลบไม่มีความหมายทางบัญชี — เก็บเงินได้มากกว่าที่เขาเป็นหนี้คือ
-- **เจ้าหนี้** (เงินรับล่วงหน้า) ไม่ใช่ลูกหนี้ติดลบ
--
-- 20261009000002 เขียนไว้เองว่า "ลูกหนี้ติดลบเป็นปัญหาคนละเรื่อง ไฟล์นี้ไม่ใช่เจ้าของกฎนั้น"
-- แล้วเลี่ยงด้วยเงื่อนไข `v_allow > 0` · ผลคือเมื่อ 1200 ติดลบ (ซึ่งเกิดได้จริงจาก
-- การรับชำระค้างรับหลังตัดหนี้สูญ) **การตั้งค่าเผื่อของหนี้รายใหม่ถูกปฏิเสธถาวร**
-- ทั้งผู้ถือ เพราะ cap เทียบกับยอดรวมที่ติดลบ → ฟีเจอร์ตายทั้งคน
--
-- ไฟล์นี้จึงเป็นเจ้าของกฎนั้น · ด่านนี้ทำสองอย่างพร้อมกัน:
--   (ก) ปิดอาการต้นทางของข้อ 2 (ตัดหนี้สูญแล้วเก็บเงินคืนด้วยหมวดรับชำระค้างรับ)
--       **ตั้งแต่ต้น** ถ้าวันหนึ่งมีเส้นทางอื่นโผล่มาอีก
--   (ข) ทำให้ cap ของข้อ 1 เทียบกับยอดที่ไม่ติดลบเสมอ
--
-- **เทียบเป็นบัญชีแต่ละตัว ไม่ใช่ยอดรวม** โดยตั้งใจ: ยอดรวมทำให้ลูกหนี้ดอกเบี้ย
-- ติดลบซ่อนอยู่ใต้ลูกหนี้ค่าเช่าที่เป็นบวกได้ตลอด แล้วงบรายบรรทัดผิดทั้งที่ยอดรวมถูก
--
-- ------------------------------------------------------------
-- ข้อ 6 · ข้อความต้องชี้ทางแก้ให้ตรงสถานการณ์
-- ------------------------------------------------------------
-- "ค่าเผื่อติดลบ" เกิดได้จากสองสาเหตุที่มีทางแก้ **ตรงข้ามกัน**:
--   (ก) เอาค่าเผื่อออกเกินที่ตั้งไว้ (ตัดหนี้สูญ / กลับค่าเผื่อ) → ตั้งค่าเผื่อเพิ่มก่อน
--   (ข) ยกเลิก/กลับรายการ **ใบตั้งค่าเผื่อ** ที่ถูกใช้ไปแล้ว → กลับใบตัดหนี้สูญก่อน
-- ของเดิมพูดแต่ (ก) → ตอน void ใบตั้งค่าเผื่อ ผู้ใช้ถูกบอกให้ไปตั้งค่าเผื่อเพิ่ม
-- ซึ่งทำแล้วก็ไม่ช่วยอะไร (เขากำลังจะเอาใบนั้นออก) → ฟังก์ชันรับ `p_cause` มาเลือกข้อความ
--
-- ------------------------------------------------------------
-- ทำไมยังอยู่ที่ DB ไม่ใช่ในเครื่องยนต์ (เหตุผลเดิมของ 20261009000002 ยังจริง)
-- ------------------------------------------------------------
-- ทุกด่านตัดสินจาก **ยอดสะสมของผู้ถือในสมุด** ซึ่ง `buildPosting()` มองไม่เห็น
-- และ insert ตรงเข้าตาราง (PostgREST · service_role · psql · migration) เลี่ยงเครื่องยนต์ได้
--
-- ขอบเขตที่ยัง **ไม่** ครอบ (เหมือนเดิม): เทียบต่อผู้ถือ ไม่ใช่รายลูกหนี้
--   เพราะ transaction_lines ยังไม่มี contact_id ระดับบรรทัด (D-102)
--   → ค่าเผื่อของลูกหนี้ ก. เอาไปตัดหนี้ของ ข. ได้ · ยอดรวมถูก รายคนผิด
--   ต้องปิดก่อนมีลูกหนี้ค้างหลายรายพร้อมกัน
--
-- idempotent: drop function if exists + create or replace · drop trigger if exists ก่อน create
-- ============================================================

set search_path = sri_os, public;

-- ------------------------------------------------------------
-- 0 · ของที่ไฟล์นี้พึ่ง ต้องมีอยู่จริงก่อน
--
--   ถ้าผังบัญชีขาดรหัสที่ด่านใช้ ด่านจะคิดยอดได้ 0 ทุกครั้งแล้ว **ผ่านทุกเคส**
--   = ด่านที่ไม่ได้ตรวจอะไรแต่ดูเหมือนติดตั้งแล้ว ซึ่งแย่กว่าไม่มีด่าน
--   `4320` อยู่ในรายการนี้ด้วย: มันคือทางกลับของการตัดหนี้สูญ (ข้อ 2) และข้อความ
--   ของด่านลูกหนี้ติดลบชี้ไปที่หมวดที่ใช้มัน — ถ้าบัญชียังไม่ถูก seed ข้อความจะชี้
--   ไปที่หมวดที่ผู้ใช้เลือกไม่ได้
-- ------------------------------------------------------------
do $do$
declare v text;
begin
  select string_agg(x.code, ', ' order by x.code) into v
    from (values ('1290'), ('1200'), ('1210'), ('1220'), ('5920'), ('4320')) as x(code)
   where not exists (select 1 from sri_os.chart_of_accounts c where c.code = x.code);
  if v is not null then
    raise exception 'ผังบัญชีใน DB ขาดรหัสที่ด่านค่าเผื่อ/ลูกหนี้ต้องใช้: % — รัน npm run sync:rules แล้ว apply ไฟล์ seed_rules ก่อนไฟล์นี้ ไม่งั้นด่านจะคิดยอดได้ 0 แล้วผ่านทุกเคสเงียบๆ', v;
  end if;
end $do$;

-- ------------------------------------------------------------
-- 1 · ด่านค่าเผื่อรุ่นใหม่ — รับ `p_cause` เพื่อรู้ว่า **อะไรทำให้ยิง**
--
-- `p_cause` มีสามค่า · ตัดสินจากผลทางบัญชีของแถวที่เปลี่ยน ไม่ใช่จากรหัสหมวด:
--   'allowance_up'   การเปลี่ยนแปลงนั้นทำให้ค่าเผื่อ (เครดิตสุทธิของ 1290) **เพิ่ม**
--                    → ตรวจ cap "ค่าเผื่อห้ามเกินลูกหนี้" ที่นี่ **ที่เดียว**
--   'allowance_down' ทำให้ค่าเผื่อ **ลด** (ตัดหนี้สูญ / กลับค่าเผื่อ)
--                    → ข้อความของค่าเผื่อติดลบชี้ไปที่ "ตั้งค่าเผื่อเพิ่มก่อน"
--   'other'          ไม่ได้เปลี่ยนค่าเผื่อโดยตรง (รับชำระ · ย้ายผู้ถือ · void/reverse)
--                    → ข้อความของค่าเผื่อติดลบชี้ไปที่ "กลับใบตัดหนี้สูญก่อน"
--
-- **ต้อง drop รุ่น 1 อาร์กิวเมนต์** ไม่ใช่ปล่อยให้ overload อยู่คู่กัน:
--   ของเดิมเป็นฟังก์ชันคนละตัว (ชื่อเดียวกัน อาร์กิวเมนต์ต่างกัน) → รายงาน data health
--   หรือ migration ในอนาคตที่เรียกแบบ 1 อาร์กิวเมนต์จะได้ **ด่านรุ่นบั๊ก** กลับมา
--   โดยไม่มีอะไรเตือน · มีเทสต์ F0 บังคับว่าต้องเหลือตัวเดียว
--
-- security definer: ถ้าอ่านบรรทัดตามสิทธิ์ผู้เรียก คนที่มองบรรทัดของผู้ถือรายนั้น
--   ไม่เห็นจะได้ยอด 0 แล้วหลุดด่านไปเฉยๆ · ไม่เรียก fn_can เลย — กฎเงินปิดจาก Settings ไม่ได้
-- ------------------------------------------------------------
drop function if exists sri_os.fn_assert_allowance_limits(uuid);

create or replace function fn_assert_allowance_limits(p_owner uuid, p_cause text default 'other')
  returns void
language plpgsql security definer set search_path = '' as $fn$
declare
  v_allow numeric(18,2);
  v_recv  numeric(18,2);
  v_name  text;
begin
  if p_owner is null then return; end if;

  -- contra-asset: ยอดค่าเผื่อที่ "มีอยู่" คือฝั่งเครดิตสุทธิ
  -- ลูกหนี้: ยอดที่ "มีอยู่" คือฝั่งเดบิตสุทธิ · อ่านสองข้างคนละทิศโดยตั้งใจ
  select coalesce(sum((l.credit - l.debit) * (case when c.code = '1290' then 1 else 0 end)), 0),
         coalesce(sum((l.debit - l.credit) * (case when c.code in ('1200', '1210', '1220') then 1 else 0 end)), 0)
    into v_allow, v_recv
    from sri_os.transactions t
    join sri_os.transaction_lines l on l.transaction_id = t.id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where t.owner_id = p_owner
     -- ใบที่ void แล้วไม่อยู่ในงบ จึงไม่อยู่ในยอดที่ด่านนี้ตัดสิน
     -- (ขา reverse **ไม่ถูกตัดออก** — มันคือขาที่ทำให้สุทธิเป็นศูนย์ · D-098)
     and t.status <> 'void'
     and c.code in ('1290', '1200', '1210', '1220');

  if v_allow = 0 and v_recv = 0 then return; end if;

  -- ชื่อผู้ถือใช้ `name_th` · หาไม่เจอให้ใช้ id เพื่อให้ข้อความยังชี้ตัวได้
  select o.name_th into v_name from sri_os.owners o where o.id = p_owner;
  v_name := coalesce(v_name, p_owner::text);

  -- ---------- ค่าเผื่อห้ามติดลบ (ตรวจทุกเส้นทาง ไม่ขึ้นกับ p_cause) ----------
  -- ค่าเผื่อติดลบ = สินทรัพย์ปลอม:
  --   ตัดหนี้สูญเกินค่าเผื่อ → ลูกหนี้หายจากงบดุลโดยไม่มีค่าใช้จ่ายรับรู้เลย
  --   กลับค่าเผื่อเกินที่ตั้ง → เครดิต 5920 ค้าง = ค่าใช้จ่ายติดลบ = รายได้จากอากาศ
  --
  -- ต้องพูดก่อนด่านอื่นเพราะค่าเผื่อติดลบทำให้ cap ผ่านเสมอ (ติดลบ <= ลูกหนี้)
  -- **ข้อความแยกตามสาเหตุ (ข้อ 6)** — ทางแก้ของสองสาเหตุนี้ตรงข้ามกัน
  if v_allow < 0 then
    if p_cause = 'allowance_down' then
      raise exception 'ค่าเผื่อหนี้สงสัยจะสูญของ % ติดลบ (%) — รายการนี้เอาค่าเผื่อออกมากกว่าค่าเผื่อคงเหลือ · ตัดหนี้สูญและกลับค่าเผื่อทำได้ไม่เกินค่าเผื่อที่ตั้งไว้ ถ้าหนี้จริงมากกว่า ต้องลง "ตั้งค่าเผื่อหนี้สงสัยจะสูญ" (Dr 5920) เพิ่มก่อน เพื่อให้ค่าใช้จ่ายโผล่ในงบกำไรขาดทุนอย่างชัดเจน ไม่ใช่ซ่อนอยู่ในรายการตัด',
        v_name, v_allow;
    else
      raise exception 'ค่าเผื่อหนี้สงสัยจะสูญของ % ติดลบ (%) — ใบตั้งค่าเผื่อถูกเอาออก (ยกเลิก/กลับรายการ/ย้ายผู้ถือ) ขณะที่ใบตัดหนี้สูญหรือใบกลับค่าเผื่อที่อาศัยค่าเผื่อนั้น **ยังอยู่ในสมุด** · ต้องกลับรายการหรือยกเลิกใบตัดหนี้สูญ/ใบกลับค่าเผื่อนั้นก่อน แล้วจึงเอาใบตั้งค่าเผื่อออก (ตั้งค่าเผื่อเพิ่มไม่ช่วย เพราะกำลังจะเอาใบนั้นออก)',
        v_name, v_allow;
    end if;
  end if;

  -- ---------- cap · ค่าเผื่อห้ามเกินยอดลูกหนี้รวม ----------
  -- **ยิงเฉพาะรายการที่ทำให้ค่าเผื่อเพิ่ม** (ข้อ 1) — นี่คือหัวใจของไฟล์นี้
  -- รายการอื่นทุกชนิด (รับชำระ · ตัดหนี้สูญ · กลับค่าเผื่อ · อะไรก็ตาม) ต้องลงได้
  -- ตามปกติไม่ว่าสัดส่วนจะกลายเป็นอะไร เพราะ "ค่าเผื่อ > ลูกหนี้" เป็นสภาพที่
  -- เกิดได้จริงและแก้ได้ด้วยการกลับค่าเผื่อ ซึ่งผู้ใช้ทำเองได้
  --
  -- ไม่ต้องมีเงื่อนไข `v_allow > 0` ของรุ่นก่อนแล้ว: ลูกหนี้ติดลบถูกปิดด้วยด่านใหม่
  -- (fn_assert_receivable_not_negative) จึงไม่มีสภาพที่ `0 > v_recv` อีก
  if p_cause = 'allowance_up' and v_allow > v_recv then
    raise exception 'ค่าเผื่อหนี้สงสัยจะสูญของ % (%) มากกว่ายอดลูกหนี้รวม 1200+1210+1220 (%) — ตั้งค่าเผื่อได้ไม่เกินหนี้ที่มีอยู่จริง (ถ้าหนี้สูญไปแล้ว ให้ตัดหนี้สูญ ไม่ใช่ตั้งค่าเผื่อเพิ่ม)',
      v_name, v_allow, v_recv;
  end if;
end $fn$;

comment on function fn_assert_allowance_limits(uuid, text) is
  'ด่านของค่าเผื่อหนี้สงสัยจะสูญต่อผู้ถือหนึ่งราย · (1) ค่าเผื่อ 1290 ห้ามติดลบ — ตรวจทุกเส้นทาง ข้อความแยกตามสาเหตุ (เอาค่าเผื่อออกเกิน vs ยกเลิกใบตั้งค่าเผื่อที่ถูกใช้แล้ว) · (2) ค่าเผื่อห้ามเกินลูกหนี้ — ยิง **เฉพาะ** p_cause = allowance_up คือรายการที่ทำให้ค่าเผื่อเพิ่ม ไม่ใช่กติกาตลอดเวลา (ไม่งั้นใบรับชำระของผู้ถือที่ตั้งค่าเผื่อไว้ถูกปฏิเสธ = เงินเข้าแบงก์แล้วลงสมุดไม่ได้ แล้วผู้ใช้จะลงรายได้ซ้ำ) · นับเฉพาะใบที่ status <> void';

-- ------------------------------------------------------------
-- 2 · ด่านใหม่ · ยอดลูกหนี้ต่อผู้ถือห้ามติดลบ (ข้อ 3)
--
-- แยกฟังก์ชันจากด่านค่าเผื่อโดยตั้งใจ: เป็นกฎของบัญชีลูกหนี้ ไม่ใช่ของค่าเผื่อ
--   → ข้อความชี้จุดได้ตรง · ถอด/แก้ทีละข้อได้ · และรายงาน data health เรียกแยกได้
--
-- ข้อความ **ชี้หมวดที่ถูกต้อง** ไม่ใช่บอกแต่ว่าผิด: เส้นทางที่ทำให้ลูกหนี้ติดลบ
--   ในชีวิตจริงคือ "ตัดหนี้สูญไปแล้ว ลูกหนี้จ่ายมาทีหลัง แล้วลงเป็นรับชำระค้างรับ"
--   ซึ่งทางที่ถูกคือหมวด `inc.bad_debt_recovered` (Dr 1100 / Cr 4320)
-- ------------------------------------------------------------
create or replace function fn_assert_receivable_not_negative(p_owner uuid) returns void
language plpgsql security definer set search_path = '' as $fn$
declare
  v_code text;
  v_bal  numeric(18,2);
  v_name text;
begin
  if p_owner is null then return; end if;

  -- เทียบ **บัญชีแต่ละตัว** ไม่ใช่ยอดรวม (ยอดรวมซ่อนตัวที่ติดลบไว้ใต้ตัวที่เป็นบวกได้)
  select x.code, x.bal into v_code, v_bal
    from (
      select c.code, sum(l.debit - l.credit) as bal
        from sri_os.transactions t
        join sri_os.transaction_lines l on l.transaction_id = t.id
        join sri_os.chart_of_accounts c on c.id = l.coa_id
       where t.owner_id = p_owner
         and t.status <> 'void'
         and c.code in ('1200', '1210', '1220')
       group by c.code
      having sum(l.debit - l.credit) < 0
       order by c.code
       limit 1
    ) x;

  if v_code is null then return; end if;

  select o.name_th into v_name from sri_os.owners o where o.id = p_owner;
  v_name := coalesce(v_name, p_owner::text);

  raise exception 'ยอดลูกหนี้บัญชี % ของ % ติดลบ (%) — ลูกหนี้ติดลบไม่มีความหมายทางบัญชี (เก็บเงินได้มากกว่าที่เขาเป็นหนี้คือเงินรับล่วงหน้า = เจ้าหนี้ ไม่ใช่ลูกหนี้ติดลบ) · ถ้าหนี้ก้อนนี้ถูก "ตัดหนี้สูญ" ไปแล้วและลูกหนี้จ่ายมาทีหลัง ให้ลงที่หมวด "หนี้สูญได้รับคืน" (Dr เงินสด / Cr 4320) ไม่ใช่หมวดรับชำระค้างรับ — ไม่งั้นลูกหนี้ติดลบและรายได้ขาดไปเท่ายอดที่เก็บคืนได้ · ถ้าตั้งลูกหนี้ไว้น้อยกว่าที่เก็บได้จริง ให้ตั้งรายได้ส่วนที่ขาดก่อน',
    v_code, v_name, v_bal;
end $fn$;

comment on function fn_assert_receivable_not_negative(uuid) is
  'ข้อ 3 ของผู้ตรวจ · ยอดลูกหนี้ 1200/1210/1220 ต่อผู้ถือห้ามติดลบ — เทียบเป็นบัญชีแต่ละตัว ไม่ใช่ยอดรวม · ปิดอาการของการ "ตัดหนี้สูญแล้วเก็บเงินคืนด้วยหมวดรับชำระค้างรับ" ตั้งแต่ต้น (ยอดนั้นต้องไปที่ inc.bad_debt_recovered → 4320) และทำให้ cap ของด่านค่าเผื่อเทียบกับยอดที่ไม่ติดลบเสมอ';

-- ------------------------------------------------------------
-- 3 · trigger ฝั่งบรรทัด — ตัดสิน `p_cause` จาก **ผลทางบัญชีของแถวที่เปลี่ยน**
--
-- ค่าเผื่อของแถว = (credit − debit) ของบรรทัดที่ชี้บัญชี 1290
--   insert → delta = new
--   delete → delta = −old   (ลบบรรทัด Dr 1290 ของใบตัดหนี้สูญ = ค่าเผื่อเพิ่มขึ้น)
--   update → delta = new − old
-- delta > 0 = ค่าเผื่อเพิ่ม → 'allowance_up' (ตรวจ cap)
-- delta < 0 = ค่าเผื่อลด   → 'allowance_down' (ข้อความของการเอาค่าเผื่อออกเกิน)
--
-- อ่านจากตัวเลขของแถว **ไม่ใช่จากรหัสหมวด** โดยตั้งใจ (กฎโปรเจกต์: ห้ามเช็ครหัสหมวด
--   ตรงๆ ในโค้ด) → เส้นทางใหม่ที่ทำให้ค่าเผื่อโตในอนาคตถูกครอบเองโดยไม่ต้องมาแก้ที่นี่
--
-- ยังกรองเฉพาะบรรทัดที่แตะ 1290/1200/1210/1220 เหมือนเดิม (กรองที่ WHEN ไม่ได้
--   เพราะต้อง join หา code จาก coa_id) — บรรทัดอื่นเปลี่ยนยอดสองตัวนี้ไม่ได้เลย
-- ------------------------------------------------------------
create or replace function fn_allowance_guard() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_row    record := coalesce(new, old);
  v_owner  uuid;
  v_code   text;
  v_delta  numeric(18,2) := 0;
  v_cause  text := 'other';
begin
  select c.code into v_code
    from sri_os.chart_of_accounts c where c.id = v_row.coa_id;
  if v_code is null or v_code not in ('1290', '1200', '1210', '1220') then
    return null;
  end if;

  select t.owner_id into v_owner
    from sri_os.transactions t where t.id = v_row.transaction_id;
  -- หัวรายการไม่อยู่แล้ว (ลบในธุรกรรมเดียวกัน) → ไม่ใช่เรื่องของด่านนี้
  if v_owner is null then return null; end if;

  if v_code = '1290' then
    if new is not null then v_delta := v_delta + (new.credit - new.debit); end if;
    if old is not null then v_delta := v_delta - (old.credit - old.debit); end if;
    if v_delta > 0 then
      v_cause := 'allowance_up';
    elsif v_delta < 0 then
      v_cause := 'allowance_down';
    end if;
  end if;

  perform sri_os.fn_assert_allowance_limits(v_owner, v_cause);
  perform sri_os.fn_assert_receivable_not_negative(v_owner);
  return null;
end $fn$;

comment on function fn_allowance_guard() is
  'trigger function ฝั่งบรรทัดของด่านค่าเผื่อ + ด่านลูกหนี้ห้ามติดลบ · ตัดสินว่าแถวนี้ทำให้ค่าเผื่อเพิ่มหรือลดจากตัวเลขของแถวเอง (เครดิตสุทธิของ 1290) ไม่ใช่จากรหัสหมวด → cap "ค่าเผื่อห้ามเกินลูกหนี้" ยิงเฉพาะรายการที่ทำให้ค่าเผื่อเพิ่ม · ต้องผูกเป็น constraint trigger (deferrable initially deferred) เพราะใบตัดหนี้สูญลดทั้ง 1290 และลูกหนี้พร้อมกัน';

drop trigger if exists trg_lines_allowance_limits on transaction_lines;
create constraint trigger trg_lines_allowance_limits
  after insert or update or delete on transaction_lines
  deferrable initially deferred
  for each row execute function fn_allowance_guard();

-- ------------------------------------------------------------
-- 4 · trigger ฝั่งหัวรายการ — เปลี่ยน status/owner_id เปลี่ยนยอดสะสมได้
--     โดยไม่แตะบรรทัดเลย (คืนสภาพใบที่ void ไว้ · ย้ายใบไปผู้ถืออื่น)
--
-- `p_cause` ของฝั่งนี้ต้องคิดจาก **ส่วนที่ยอดของผู้ถือเปลี่ยนจริง** ไม่ใช่เหมาเป็น
--   'allowance_up' ทุกครั้งที่ใบนั้นมีเครดิต 1290:
--   แก้ memo ของใบตั้งค่าเผื่อเก่า **ไม่ได้เพิ่มค่าเผื่อ** ถ้าเหมาเป็น up จะไปตรวจ cap
--   แล้วการแก้ข้อความของใบเก่าจะถูกปฏิเสธเพราะสภาพที่ใบอื่นสร้างไว้ = กันแน่นเกิน
--   (อาการเดียวกับข้อ 1 ที่กำลังแก้ · เส้นทางเดียวที่ทำให้ค่าเผื่อของผู้ถือโตจาก
--    ฝั่งหัวรายการคือ ใบเข้าใหม่ · ใบออกจาก void · ใบย้ายเข้ามาจากผู้ถืออื่น)
--
-- ฝั่งผู้ถือ **เก่า** ตอนย้ายใบเป็น 'other' เสมอ — ค่าเผื่อของเขาลดลง ไม่ใช่เพิ่ม
--   และถ้าลดจนติดลบ ข้อความที่ถูกคือ "กลับใบตัดหนี้สูญก่อน" ซึ่งเป็นสาขา other พอดี
-- ------------------------------------------------------------
create or replace function fn_txn_allowance_guard() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_net   numeric(18,2);
  v_cause text := 'other';
  v_entered boolean;
begin
  if new.owner_id is not null then
    -- ใบนี้ "เข้ามา" อยู่ในยอดของผู้ถือรายนี้ตอนนี้หรือไม่
    v_entered := (tg_op = 'INSERT')
              or (tg_op = 'UPDATE' and old.status = 'void' and new.status <> 'void')
              or (tg_op = 'UPDATE' and old.owner_id is distinct from new.owner_id);
    if v_entered and new.status <> 'void' then
      select coalesce(sum(case when c.code = '1290' then l.credit - l.debit else 0 end), 0)
        into v_net
        from sri_os.transaction_lines l
        join sri_os.chart_of_accounts c on c.id = l.coa_id
       where l.transaction_id = new.id;
      if v_net > 0 then v_cause := 'allowance_up'; end if;
    end if;

    perform sri_os.fn_assert_allowance_limits(new.owner_id, v_cause);
    perform sri_os.fn_assert_receivable_not_negative(new.owner_id);
  end if;

  if tg_op = 'UPDATE' and old.owner_id is distinct from new.owner_id then
    perform sri_os.fn_assert_allowance_limits(old.owner_id, 'other');
    perform sri_os.fn_assert_receivable_not_negative(old.owner_id);
  end if;
  return null;
end $fn$;

comment on function fn_txn_allowance_guard() is
  'ด่านค่าเผื่อ + ด่านลูกหนี้ฝั่งหัวรายการ · จำเป็นเพราะ update transactions set status/owner_id เปลี่ยนยอดสะสมของผู้ถือโดยไม่แตะ transaction_lines → trigger ที่ผูกแค่บรรทัดจะไม่ยิงเลย · ตรวจ cap เฉพาะตอนที่ใบซึ่งเพิ่มค่าเผื่อ "เข้ามา" ในยอดของผู้ถือ (ใบใหม่ · ออกจาก void · ย้ายเข้ามา) ไม่ใช่ทุกครั้งที่แก้หัวรายการ';

drop trigger if exists trg_txn_allowance_limits on transactions;
create constraint trigger trg_txn_allowance_limits
  after insert or update on transactions
  deferrable initially deferred
  for each row execute function fn_txn_allowance_guard();

-- ------------------------------------------------------------
-- 5 · ACL — ฟังก์ชันใหม่ติด PUBLIC EXECUTE มาจาก Postgres ต้องปิด
--     (20261007000007 revoke เป็นชุด **ตอนที่มันรัน** ฟังก์ชันที่เพิ่มทีหลังไม่ถูกครอบ)
--     trigger ยิงเองโดยไม่ต้องมี execute ของผู้เรียก — กฎเงินห้ามเรียกเอง
-- ------------------------------------------------------------
revoke all on function fn_assert_allowance_limits(uuid, text)   from public;
revoke all on function fn_assert_receivable_not_negative(uuid)  from public;
revoke all on function fn_allowance_guard()                     from public;
revoke all on function fn_txn_allowance_guard()                 from public;
do $do$
begin
  execute 'revoke all on function sri_os.fn_assert_allowance_limits(uuid, text)  from anon, authenticated';
  execute 'revoke all on function sri_os.fn_assert_receivable_not_negative(uuid) from anon, authenticated';
  execute 'revoke all on function sri_os.fn_allowance_guard()                    from anon, authenticated';
  execute 'revoke all on function sri_os.fn_txn_allowance_guard()                from anon, authenticated';
end $do$;

-- ------------------------------------------------------------
-- 6 · guard ท้ายไฟล์ — ต้องดังตอน migrate ถ้าผลลัพธ์ไม่ตรงกับที่ไฟล์นี้อ้าง
--     (ประวัติที่ขัดกฎใหม่เป็น warning: raise = migrate ของจริงล้มเพราะข้อมูลเก่า
--      ซึ่งแก้ด้วยไฟล์นี้ไม่ได้ ต้องตามแก้ด้วยมือตามเคส)
-- ------------------------------------------------------------
do $do$
declare
  v_type int; v_defer boolean; v_init boolean; v_con oid; v text; n int;
begin
  -- (ก) ทั้งสองด่านต้องยังเป็น constraint trigger ที่เลื่อนไว้ · AFTER
  foreach v in array array['transaction_lines|trg_lines_allowance_limits',
                           'transactions|trg_txn_allowance_limits'] loop
    select t.tgtype, t.tgdeferrable, t.tginitdeferred, t.tgconstraint
      into v_type, v_defer, v_init, v_con
      from pg_trigger t
     where t.tgrelid = ('sri_os.' || split_part(v, '|', 1))::regclass
       and t.tgname = split_part(v, '|', 2);
    if v_type is null then
      raise exception 'ไม่พบด่าน % — ค่าเผื่อติดลบและลูกหนี้ติดลบได้ทันที', v;
    end if;
    if not (v_defer and v_init and v_con <> 0) then
      raise exception 'ด่าน % ไม่ได้ผูกเป็น constraint trigger (deferrable initially deferred) — ผลของด่านจะขึ้นกับลำดับการ insert ของบรรทัด แล้วใบที่ถูกต้องจะถูกปฏิเสธแบบสุ่ม', v;
    end if;
    if (v_type & 2) <> 0 then
      raise exception 'ด่าน % วางไว้ที่ BEFORE — ตอนนั้นบรรทัดของใบยังไม่ครบ ด่านจะตัดสินจากสภาพครึ่งๆ', v;
    end if;
  end loop;

  -- (ข) ฟังก์ชันเดิมรุ่น 1 อาร์กิวเมนต์ต้องหายไป ไม่ใช่อยู่คู่กับรุ่นใหม่
  select count(*) into n from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_assert_allowance_limits';
  if n <> 1 then
    raise exception 'มีฟังก์ชัน fn_assert_allowance_limits % ตัว — รุ่นเก่า (uuid) ที่ยิง cap ใส่ทุกรายการต้องถูก drop ไม่ใช่ปล่อยให้ overload อยู่คู่กัน', n;
  end if;

  -- (ค) ประวัติที่ขัดกฎใหม่ — ให้เห็นก่อนที่ผู้ใช้จะเจอตอนกดบันทึกใบถัดไป
  select count(*) into n
    from sri_os.owners o
   where exists (
     select 1
       from sri_os.transactions t
       join sri_os.transaction_lines l on l.transaction_id = t.id
       join sri_os.chart_of_accounts c on c.id = l.coa_id
      where t.owner_id = o.id and t.status <> 'void' and c.code in ('1200', '1210', '1220')
      group by c.code
     having sum(l.debit - l.credit) < 0);
  if n > 0 then
    raise warning 'มีผู้ถือ % รายที่ยอดลูกหนี้ติดลบอยู่แล้วก่อนไฟล์นี้ — ด่านใหม่จะปฏิเสธรายการถัดไปที่แตะบัญชีลูกหนี้ของผู้ถือรายนั้นจนกว่าจะลงรายการแก้ให้ถูก (ยอดที่เกินมาคือรายได้ที่ยังไม่ได้ตั้ง หรือหนี้สูญที่เก็บคืนได้ → ลงหมวด "หนี้สูญได้รับคืน") · ของเก่าแก้ด้วยไฟล์นี้ไม่ได้', n;
  end if;

  raise notice 'ด่านค่าเผื่อรุ่นใหม่พร้อมใช้ · cap ยิงเฉพาะรายการที่ทำให้ค่าเผื่อเพิ่ม · ค่าเผื่อห้ามติดลบ (ข้อความแยกตามสาเหตุ) · ลูกหนี้ 1200/1210/1220 ต่อผู้ถือห้ามติดลบ';
end $do$;
