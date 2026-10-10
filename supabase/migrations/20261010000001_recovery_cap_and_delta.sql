-- ============================================================
-- SRI OS · ปิด 3 รูที่ผู้ตรวจ BLOCK รอบสอง
--   (1) "หนี้สูญได้รับคืน" ใช้กับลูกหนี้ที่ยังไม่ตัดหนี้สูญได้
--   (2) ด่านระดับบรรทัดตาบอดเพราะถาม NEW/OLD ด้วย IS NOT NULL
--   ต่อจาก 20261009000004_allowance_fixes.sql ซึ่ง **ห้ามแก้** (apply ไปแล้ว)
--
-- ย้อนกลับ (rollback):
--   -- คืนด่านรุ่นก่อนหน้า: รัน supabase/migrations/20261009000004_allowance_fixes.sql
--   -- ซ้ำอีกครั้ง (ไฟล์นั้น idempotent) แล้วถอดของที่ไฟล์นี้เพิ่ม:
--   drop function if exists sri_os.fn_assert_recovery_within_writeoff(uuid, text);
--   -- (ไฟล์ 000004 จะ create or replace fn_allowance_guard / fn_txn_allowance_guard
--   --  กลับเป็นรุ่นเดิมเอง และ trigger ทั้งสองตัวชื่อเดิมจึงไม่ต้องถอด)
--   **ย้อนแล้วอาการเดิมกลับมาทั้งสามข้อ**: ลง "หนี้สูญได้รับคืน" โดยไม่เคยตัดหนี้สูญได้
--   (= รายได้นับสองรอบ + ลูกหนี้ค้างในงบดุลตลอดไป) · UPDATE บรรทัดเลี่ยง cap ค่าเผื่อได้
--   · และข้อความ error ของการเอาค่าเผื่อออกเกินจะชี้ทางแก้ผิดทางอีก
--   ถ้าย้อนเพราะด่านกันของที่ถูก ให้แก้เกณฑ์ในฟังก์ชัน ไม่ใช่ถอดด่าน
--
-- ------------------------------------------------------------
-- รูที่ 1 · ไม่มีด่านไหนบังคับว่าต้อง "ตัดหนี้สูญ" ก่อนจึงจะ "รับคืน" ได้
-- ------------------------------------------------------------
-- 20261009000004 เพิ่มหมวด inc.bad_debt_recovered (Dr เงินสด / Cr 4320) เป็นทางกลับ
-- ของการตัดหนี้สูญ · แต่ตัวหมวดเองไม่แตะลูกหนี้ (ตั้งใจ) จึงไม่มีด่านไหนฟ้องเลย:
--
--   ตั้งลูกหนี้ 30,000 → ลง "หนี้สูญได้รับคืน" 30,000 → **ผ่าน**
--     = กำไร 60,000 (ค่าเช่า 30,000 + รับคืน 30,000) จากเงินที่เก็บได้ 30,000
--     และ **ลูกหนี้ 1200 ค้างอยู่ 30,000 ตลอดไป** เพราะไม่มีอะไรไปล้างมัน
--   หรือลง 500,000 โดยไม่มีประวัติอะไรเลยก็ผ่าน = รายได้จากอากาศ + สินทรัพย์ลวง
--
-- ด่านใหม่: เครดิต 4320 **สะสม** ต่อผู้ถือ ห้ามเกิน **ยอดตัดหนี้สูญสะสม** ต่อผู้ถือ
--
-- **วิธีหา "ยอดตัดหนี้สูญสะสม" โดยไม่เช็ครหัสหมวด** (กฎ CLAUDE.md ห้ามเช็ครหัสหมวดในโค้ด):
--   เดบิต 1290 เกิดได้สองทางตามตารางกฎ (ตรวจจาก src/lib/rules/tx-rules.ts แล้ว
--   ว่ามีแค่สองทางนี้ และ 4320 มีทางเข้าทางเดียวคือ inc.bad_debt_recovered):
--     ตัดหนี้สูญ      adj.writeoff_rent/interest/other  Dr 1290 / Cr 1200·1210·1220
--     กลับค่าเผื่อ     adj.doubtful_release               Dr 1290 / Cr 5920
--   → แยกสองทางนี้ด้วย **บัญชีคู่ในใบเดียวกัน** ไม่ใช่ด้วยรหัสหมวด
--     "ยอดตัดหนี้สูญสะสม" = ผลรวมเดบิตสุทธิของ 1290 **ของใบที่แตะบัญชีลูกหนี้ด้วย**
--
--   ที่ผู้ตรวจสั่งไว้คือ "ใบที่มี **เครดิต** ลูกหนี้" · ของจริงต้องเป็น "ใบที่ **แตะ**
--   บัญชีลูกหนี้" และนับ **เดบิตสุทธิ** (debit − credit) ของ 1290 เพราะใบ
--   **กลับรายการ** ของใบตัดหนี้สูญสลับด้านเป็น Dr 1200 / Cr 1290 ซึ่งมี
--   *เดบิต* ลูกหนี้ ไม่ใช่เครดิต → ถ้านับตามตัวอักษร ใบกลับรายการจะไม่หักยอดที่ตัดไว้
--   แล้วจะเหลือช่อง: ตัดหนี้สูญ 30,000 → กลับรายการใบนั้น (ลูกหนี้กลับมา)
--   → รับคืน 30,000 ได้อีก = อาการเดิมกลับมาทางอ้อม
--   (ใบที่ void ไม่อยู่ในยอดอยู่แล้วเพราะ status <> 'void' เหมือนด่านอื่นในชุดนี้)
--
-- กติกานี้เป็น **กติกาตลอดเวลา** ไม่ใช่กติกาตอนเพิ่ม (ต่างจาก cap ของค่าเผื่อ):
--   ไม่มีรายการที่ถูกต้องชนิดไหนทำให้ "รับคืน > ยอดที่ตัด" เกิดขึ้นได้เอง
--   (ใบรับชำระ · ใบรายได้ · ใบค่าใช้จ่าย ไม่แตะทั้ง 4320 และ 1290)
--   เส้นทางเดียวที่ทำให้สภาพนี้เกิดคือ เพิ่มใบรับคืน หรือ เอาใบตัดหนี้สูญออก
--   ซึ่ง **ทั้งสองทางต้องถูกกัน** แต่ **ทางแก้ของสองทางตรงข้ามกัน** → ข้อความแยกสาขา
--   (บทเรียนข้อ 6 ของ D-103: ข้อความที่ชี้ทางแก้ผิดทำให้ผู้ใช้หาทางอ้อมที่ผิดกว่าเดิม)
--
-- ------------------------------------------------------------
-- รูที่ 2 · ด่านระดับบรรทัดตาบอด · v_delta เป็น 0 ตลอด
-- ------------------------------------------------------------
-- 20261009000004 บรรทัด 272-273 ถาม "มีแถวนี้ไหม" ด้วย `new is not null`
--
-- **กับดักของ Postgres**: `ROW IS NOT NULL` ไม่ได้ถามว่าตัวแปรแถวว่างไหม
--   มันเป็นจริง **เฉพาะเมื่อทุกคอลัมน์ของแถวไม่เป็น null**
--   แถวของ transaction_lines มีคอลัมน์ null เกือบทุกแถว (bank_account_id ·
--   asset_id · contact_id) → เงื่อนไขเป็น false ตลอด → v_delta = 0 ตลอด
--   → ด่านระดับบรรทัดส่ง p_cause = 'other' ทุกครั้ง
--
-- ผลที่รันยืนยันแล้วสองอย่าง:
--   (ก) **ทะลุ cap ได้**: ตั้งค่าเผื่อ 1,000 แล้ว UPDATE สองบรรทัดเป็น 900,000
--       ในธุรกรรมเดียวกัน → ผ่าน (ขณะที่ลูกหนี้มี 10,000) ทั้งที่ลงตรงๆ ถูกปฏิเสธ
--       เพราะ cap มาจาก trigger **หัวรายการ** เท่านั้น ซึ่ง UPDATE บรรทัดไม่ปลุก
--   (ข) **ข้อความเลือกสาขาผิด**: เอาค่าเผื่อออกเกิน (ตัดหนี้สูญ/กลับค่าเผื่อ) ได้
--       ข้อความสาขา "void ใบตั้งค่าเผื่อ" ที่บอกว่า *ตั้งค่าเผื่อเพิ่มไม่ช่วย*
--       ทั้งที่ทางแก้ที่ถูกคือตั้งค่าเผื่อเพิ่ม
--
-- วิธีที่ถูกคือดู `tg_op` แล้วอ่าน old/new ตามเหตุการณ์ (INSERT มีแต่ new ·
--   DELETE มีแต่ old · UPDATE มีทั้งคู่) · ไฟล์นี้ยังเก็บ "ส่วนต่างต่อผู้ถือ"
--   แยกเป็นรายผู้ถือ เพราะ UPDATE ย้ายบรรทัดข้ามใบ (คนละผู้ถือ) ได้
--
-- (ข) ยังมีต้นตออีกที่: trigger **หัวรายการ** เหมาทุกกรณีที่ไม่ใช่ allowance_up
--   เป็น 'other' → ใบตัดหนี้สูญที่ลงใหม่ (ซึ่ง trigger หัวรายการยิง **ก่อน**
--   trigger บรรทัด เพราะ deferred event ยิงตามลำดับที่เข้าคิว) ได้ข้อความสาขา void
--   → ไฟล์นี้ให้ฝั่งหัวรายการตอบ 'allowance_down' ด้วยเมื่อใบที่เข้ามา **ลด** ค่าเผื่อ
--
-- ------------------------------------------------------------
-- ทำไมยังอยู่ที่ DB ไม่ใช่ในเครื่องยนต์ (เหตุผลเดิมยังจริง)
-- ------------------------------------------------------------
-- ทุกด่านตัดสินจาก **ยอดสะสมของผู้ถือในสมุด** ซึ่ง buildPosting() มองไม่เห็น
-- และ insert ตรงเข้าตาราง (PostgREST · service_role · psql · migration) เลี่ยงเครื่องยนต์ได้
--
-- ขอบเขตที่ยัง **ไม่** ครอบ (เหมือนเดิม): เทียบต่อผู้ถือ ไม่ใช่รายลูกหนี้
--   เพราะ transaction_lines ยังไม่มี contact_id ระดับบรรทัด (D-102)
--   → ยอดที่ตัดของลูกหนี้ ก. เอาไปรับคืนของ ข. ได้ · ยอดรวมถูก รายคนผิด
--
-- idempotent: create or replace ทุกฟังก์ชัน · drop trigger if exists ก่อน create
-- ============================================================

set search_path = sri_os, public;

-- ------------------------------------------------------------
-- 0 · ของที่ไฟล์นี้พึ่ง ต้องมีอยู่จริงก่อน
--     ถ้าผังบัญชีขาดรหัสที่ด่านใช้ ด่านจะคิดยอดได้ 0 ทุกครั้งแล้ว **ผ่านทุกเคส**
--     = ด่านที่ไม่ได้ตรวจอะไรแต่ดูเหมือนติดตั้งแล้ว ซึ่งแย่กว่าไม่มีด่าน
-- ------------------------------------------------------------
do $do$
declare v text;
begin
  select string_agg(x.code, ', ' order by x.code) into v
    from (values ('1290'), ('1200'), ('1210'), ('1220'), ('5920'), ('4320')) as x(code)
   where not exists (select 1 from sri_os.chart_of_accounts c where c.code = x.code);
  if v is not null then
    raise exception 'ผังบัญชีใน DB ขาดรหัสที่ด่านค่าเผื่อ/ลูกหนี้/หนี้สูญได้รับคืนต้องใช้: % — รัน npm run sync:rules แล้ว apply ไฟล์ seed_rules ก่อนไฟล์นี้ ไม่งั้นด่านจะคิดยอดได้ 0 แล้วผ่านทุกเคสเงียบๆ', v;
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'sri_os' and p.proname = 'fn_assert_allowance_limits'
                    and p.pronargs = 2) then
    raise exception 'ไม่พบ sri_os.fn_assert_allowance_limits(uuid, text) — ไฟล์นี้ต่อจาก 20261009000004_allowance_fixes.sql ต้อง apply ไฟล์นั้นก่อน';
  end if;
end $do$;

-- ------------------------------------------------------------
-- 1 · ด่านใหม่ของรูที่ 1 · "รับคืนหนี้สูญสะสม ห้ามเกินยอดตัดหนี้สูญสะสม"
--
-- แยกเป็นฟังก์ชันของตัวเองเหมือน fn_assert_receivable_not_negative:
--   เป็นกฎของบัญชี 4320 ไม่ใช่ของค่าเผื่อ → ข้อความชี้จุดตรง · ถอด/แก้ทีละข้อได้
--   · รายงาน data health เรียกแยกได้
--
-- p_cause สองค่า (ตัดสินจากผลทางบัญชีของสิ่งที่เปลี่ยน ไม่ใช่จากรหัสหมวด):
--   'recovery_up' การเปลี่ยนแปลงนั้นทำให้ยอดรับคืน (เครดิตสุทธิ 4320) **เพิ่ม**
--                 → ทางแก้คือ "ตัดหนี้สูญก่อน" หรือ "ใช้หมวดรับชำระค้างรับ"
--   'other'       ยอดรับคืนไม่ได้เพิ่ม แต่สภาพเสียเพราะ **ยอดที่ตัดหายไป**
--                 (void/กลับรายการ/ย้ายผู้ถือ ใบตัดหนี้สูญ)
--                 → ทางแก้คือ "เอาใบรับคืนออกก่อน" ซึ่ง **ตรงข้ามกับสาขาแรก**
--
-- security definer: ถ้าอ่านบรรทัดตามสิทธิ์ผู้เรียก คนที่มองบรรทัดของผู้ถือรายนั้น
--   ไม่เห็นจะได้ยอด 0 แล้วหลุดด่านไปเฉยๆ · ไม่เรียก fn_can เลย — กฎเงินปิดจาก Settings ไม่ได้
-- ------------------------------------------------------------
create or replace function fn_assert_recovery_within_writeoff(p_owner uuid, p_cause text default 'other')
  returns void
language plpgsql security definer set search_path = '' as $fn$
declare
  v_recovered numeric(18,2);
  v_writeoff  numeric(18,2);
  v_name      text;
begin
  if p_owner is null then return; end if;

  -- รายได้ "หนี้สูญได้รับคืน" ที่รับรู้ไว้ = เครดิตสุทธิของ 4320
  -- (อ่านเป็นสุทธิ เพื่อให้ใบกลับรายการของใบรับคืนหักยอดนี้ลงจริง)
  select coalesce(sum(l.credit - l.debit), 0) into v_recovered
    from sri_os.transactions t
    join sri_os.transaction_lines l on l.transaction_id = t.id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where t.owner_id = p_owner
     and t.status <> 'void'
     and c.code = '4320';

  -- ไม่มีรายได้รับคืนในสมุดเลย = ไม่มีอะไรต้อง cap
  -- (และกันกรณีประวัติเพี้ยนจนยอดที่ตัดติดลบ ไม่ให้ไปปฏิเสธรายการที่ไม่เกี่ยวกัน)
  if v_recovered <= 0 then return; end if;

  -- ยอดตัดหนี้สูญสะสม = เดบิตสุทธิของ 1290 **เฉพาะใบที่แตะบัญชีลูกหนี้ด้วย**
  --   ใบตัดหนี้สูญ      Dr 1290 / Cr 1200·1210·1220  → +amount
  --   ใบกลับรายการของมัน Dr 1200 / Cr 1290            → −amount (จึงหักกันเป็นศูนย์)
  --   ใบกลับค่าเผื่อ     Dr 1290 / Cr 5920            → ไม่เข้าเงื่อนไข (ไม่แตะลูกหนี้)
  select coalesce(sum(x.net_writeoff), 0) into v_writeoff
    from (
      select sum(case when c.code = '1290' then l.debit - l.credit else 0 end) as net_writeoff,
             bool_or(c.code in ('1200', '1210', '1220')) as touches_receivable
        from sri_os.transactions t
        join sri_os.transaction_lines l on l.transaction_id = t.id
        join sri_os.chart_of_accounts c on c.id = l.coa_id
       where t.owner_id = p_owner
         and t.status <> 'void'
       group by t.id
    ) x
   where x.touches_receivable;

  if v_recovered <= v_writeoff then return; end if;

  select o.name_th into v_name from sri_os.owners o where o.id = p_owner;
  v_name := coalesce(v_name, p_owner::text);

  if p_cause = 'recovery_up' then
    raise exception 'หนี้สูญได้รับคืนสะสมของ % (%) มากกว่ายอดตัดหนี้สูญสะสม (%) — หมวดนี้ใช้ได้เฉพาะหนี้ที่ถูกตัดหนี้สูญไปแล้ว และได้ไม่เกินยอดที่ตัดไป · ถ้าลูกหนี้ก้อนนี้ยังอยู่ในสมุด ให้ลงที่หมวดรับชำระค้างรับ (Dr เงินสด / Cr ลูกหนี้) เพื่อให้ลูกหนี้ลดลงจริง · ถ้าหนี้ก้อนนี้สูญจริง ให้ตั้งค่าเผื่อแล้วตัดหนี้สูญก่อน จึงรับคืนได้ — ไม่งั้นรายได้ถูกนับสองรอบและลูกหนี้ค้างในงบดุลตลอดไป',
      v_name, v_recovered, v_writeoff;
  else
    raise exception 'หนี้สูญได้รับคืนสะสมของ % (%) มากกว่ายอดตัดหนี้สูญสะสม (%) — ใบตัดหนี้สูญถูกเอาออก (ยกเลิก/กลับรายการ/ย้ายผู้ถือ) ขณะที่ใบหนี้สูญได้รับคืนที่อาศัยยอดนั้นยังอยู่ในสมุด · ต้องกลับรายการหรือยกเลิกใบหนี้สูญได้รับคืนนั้นก่อน แล้วจึงเอาใบตัดหนี้สูญออก (ตัดหนี้สูญใบใหม่ไม่ใช่ทางแก้ เพราะกำลังจะเอาใบนั้นออก) — ไม่งั้นลูกหนี้กลับมาในงบดุลพร้อมกับรายได้ที่รับคืนไปแล้ว = นับสองรอบ',
      v_name, v_recovered, v_writeoff;
  end if;
end $fn$;

comment on function fn_assert_recovery_within_writeoff(uuid, text) is
  'ด่านของรูที่ 1 · เครดิตสะสมของ 4320 (หนี้สูญได้รับคืน) ต่อผู้ถือ ห้ามเกินยอดตัดหนี้สูญสะสมของผู้ถือรายนั้น · "ยอดตัดหนี้สูญ" = เดบิตสุทธิของ 1290 เฉพาะใบที่แตะบัญชีลูกหนี้ (1200/1210/1220) ด้วย — แยกจากใบกลับค่าเผื่อ (Dr 1290 / Cr 5920) ด้วยบัญชีคู่ในใบ ไม่ใช่ด้วยรหัสหมวด · นับเฉพาะใบที่ status <> void · ข้อความแยกสองสาขาเพราะทางแก้ตรงข้ามกัน (รับคืนเกิน vs ใบตัดหนี้สูญถูกเอาออก)';

-- ------------------------------------------------------------
-- 2 · trigger ฝั่งบรรทัด · รุ่นที่ "เห็น" ส่วนต่างจริง
--
-- อ่าน old/new ตาม tg_op (INSERT มีแต่ new · DELETE มีแต่ old · UPDATE มีทั้งคู่)
--   **ห้ามถาม "มีแถวนี้ไหม" ด้วย ROW IS NOT NULL** — ดูคำอธิบายกับดักที่หัวไฟล์
--   (สรุป: ROW IS NOT NULL เป็นจริงเฉพาะเมื่อทุกคอลัมน์ไม่เป็น null
--    แถวจริงเกือบทุกแถวมีคอลัมน์ null → ตอบ false ตลอด → ส่วนต่างเป็น 0 ตลอด)
--
-- คิดส่วนต่าง **แยกตามผู้ถือ** เพราะ UPDATE ย้ายบรรทัดข้ามใบได้ และสองใบนั้น
--   อยู่ต่างผู้ถือกันได้ → ผู้ถือปลายทางยอดเพิ่ม ผู้ถือต้นทางยอดลด คนละสาเหตุกัน
--
-- ส่วนต่างของค่าเผื่อ = (credit − debit) ของบรรทัดที่ชี้ 1290 · ของรับคืน = ของ 4320
--   > 0 ค่าเผื่อเพิ่ม  → 'allowance_up'   (ตรวจ cap ค่าเผื่อห้ามเกินลูกหนี้)
--   < 0 ค่าเผื่อลด    → 'allowance_down' (ข้อความ "ตั้งค่าเผื่อเพิ่มก่อน")
-- อ่านจากตัวเลขของแถว **ไม่ใช่จากรหัสหมวด** โดยตั้งใจ (กฎโปรเจกต์)
--
-- **แถวที่ส่วนต่างเป็นศูนย์**: คำสั่ง UPDATE เดียวแก้หลายบรรทัดของใบเดียวกันได้
--   (ใบตัดหนี้สูญมีบรรทัด 1290 กับบรรทัดลูกหนี้ ซึ่งต้องแก้คู่กันให้ใบยังสมดุล)
--   บรรทัดลูกหนี้มีส่วนต่างของค่าเผื่อเป็นศูนย์ แต่ตอนมันยิง สภาพในสมุดเสียแล้ว
--   → ถ้าปล่อยเป็น 'other' ข้อความจะขึ้นกับ **ลำดับแถวในคำสั่ง** ซึ่งไม่แน่นอน
--   → ใช้ "ผลสุทธิของใบนั้น" เป็นตัวสำรอง และ **ใช้เลือกข้อความเท่านั้น**
--     ตัวสำรองนี้ตอบ allowance_down ได้ แต่ **ห้ามตอบ allowance_up** เพราะ
--     allowance_up เปิด cap → การแก้ memo ของบรรทัดในใบเก่าจะถูกปฏิเสธเพราะ
--     สภาพที่ใบอื่นสร้างไว้ (อาการเดียวกับข้อ 1 ของ D-103 ที่เพิ่งแก้ไป)
-- ------------------------------------------------------------
create or replace function fn_allowance_guard() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_old_code text;
  v_new_code text;
  v_old_txn  uuid;
  v_new_txn  uuid;
  v_old_net  numeric(18,2) := 0;
  v_new_net  numeric(18,2) := 0;
  -- บรรทัดที่เปลี่ยนยอดของด่านชุดนี้ได้ · 4320 เพิ่มมาในไฟล์นี้ (รูที่ 1)
  v_watch    text[] := array['1290', '1200', '1210', '1220', '4320'];
  v_doc_txn  uuid;
  v_doc_allowance numeric(18,2) := 0;
  v_doc_recovery  numeric(18,2) := 0;
  r          record;
  v_cause    text;
  v_rcause   text;
begin
  if tg_op <> 'INSERT' then
    v_old_txn := old.transaction_id;
    v_old_net := old.credit - old.debit;
    select c.code into v_old_code
      from sri_os.chart_of_accounts c where c.id = old.coa_id;
  end if;
  if tg_op <> 'DELETE' then
    v_new_txn := new.transaction_id;
    v_new_net := new.credit - new.debit;
    select c.code into v_new_code
      from sri_os.chart_of_accounts c where c.id = new.coa_id;
  end if;

  -- บรรทัดอื่นเปลี่ยนยอดที่ด่านชุดนี้ตัดสินไม่ได้เลย
  -- (กรองที่ WHEN ไม่ได้เพราะต้อง join หา code จาก coa_id)
  if not (coalesce(v_old_code, '') = any(v_watch) or coalesce(v_new_code, '') = any(v_watch)) then
    return null;
  end if;

  -- ผลสุทธิ **ของใบ** ไว้เลือกข้อความให้แถวที่ส่วนต่างเป็นศูนย์ (ดูคำอธิบายข้างบน)
  v_doc_txn := coalesce(v_new_txn, v_old_txn);
  select coalesce(sum(case when c.code = '1290' then l.credit - l.debit else 0 end), 0),
         coalesce(sum(case when c.code = '4320' then l.credit - l.debit else 0 end), 0)
    into v_doc_allowance, v_doc_recovery
    from sri_os.transaction_lines l
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where l.transaction_id = v_doc_txn;

  -- หัวรายการไม่อยู่แล้ว (ลบในธุรกรรมเดียวกัน) → ไม่มีแถวในลูป = ไม่ใช่เรื่องของด่านนี้
  for r in
    with chg(txn, code, net, sgn) as (
      select v.txn, v.code, v.net, v.sgn
        from (values (v_new_txn::uuid, v_new_code::text, v_new_net::numeric,  1),
                     (v_old_txn::uuid, v_old_code::text, v_old_net::numeric, -1)) as v(txn, code, net, sgn)
       where v.txn is not null
    )
    select t.owner_id,
           sum(case when chg.code = '1290' then chg.net * chg.sgn else 0 end) as d_allowance,
           sum(case when chg.code = '4320' then chg.net * chg.sgn else 0 end) as d_recovery
      from chg
      join sri_os.transactions t on t.id = chg.txn
     where t.owner_id is not null
     group by t.owner_id
  loop
    v_cause := 'other';
    if r.d_allowance > 0 then
      v_cause := 'allowance_up';
    elsif r.d_allowance < 0 then
      v_cause := 'allowance_down';
    elsif v_doc_allowance < 0 then
      -- บรรทัดอื่นของ **ใบที่เอาค่าเผื่อออก** (เช่นบรรทัดลูกหนี้ของใบตัดหนี้สูญ)
      -- → เลือกข้อความให้ตรงสถานการณ์ โดยไม่เปิด cap (ซึ่งจะกันแน่นเกิน)
      v_cause := 'allowance_down';
    end if;
    v_rcause := case when r.d_recovery > 0 or (r.d_recovery = 0 and v_doc_recovery > 0)
                     then 'recovery_up' else 'other' end;

    perform sri_os.fn_assert_allowance_limits(r.owner_id, v_cause);
    perform sri_os.fn_assert_receivable_not_negative(r.owner_id);
    perform sri_os.fn_assert_recovery_within_writeoff(r.owner_id, v_rcause);
  end loop;
  return null;
end $fn$;

comment on function fn_allowance_guard() is
  'trigger function ฝั่งบรรทัดของด่านค่าเผื่อ + ลูกหนี้ห้ามติดลบ + หนี้สูญได้รับคืนห้ามเกินยอดที่ตัด · ตัดสินว่าแถวที่เปลี่ยนทำให้ยอดเพิ่มหรือลดจากตัวเลขของแถวเอง ไม่ใช่จากรหัสหมวด · อ่าน old/new ตาม tg_op (ห้ามถามว่ามีแถวไหมด้วย ROW IS NOT NULL ซึ่งเป็นจริงเฉพาะเมื่อทุกคอลัมน์ไม่เป็น null → ส่วนต่างเป็น 0 ตลอดและ UPDATE บรรทัดเลี่ยง cap ได้) · คิดส่วนต่างแยกตามผู้ถือเพราะ UPDATE ย้ายบรรทัดข้ามใบคนละผู้ถือได้';

drop trigger if exists trg_lines_allowance_limits on transaction_lines;
create constraint trigger trg_lines_allowance_limits
  after insert or update or delete on transaction_lines
  deferrable initially deferred
  for each row execute function fn_allowance_guard();

-- ------------------------------------------------------------
-- 3 · trigger ฝั่งหัวรายการ — เปลี่ยน status/owner_id เปลี่ยนยอดสะสมได้
--     โดยไม่แตะบรรทัดเลย (คืนสภาพใบที่ void ไว้ · ย้ายใบไปผู้ถืออื่น)
--
-- ของเดิมเหมาทุกกรณีที่ไม่ใช่ allowance_up เป็น 'other' → ใบ **ตัดหนี้สูญ** ที่ลงใหม่
--   ได้ข้อความสาขา "void ใบตั้งค่าเผื่อ" ซึ่งชี้ทางแก้ผิด และ trigger ฝั่งนี้
--   ยิง **ก่อน** ฝั่งบรรทัด (deferred event ยิงตามลำดับที่เข้าคิว: หัวรายการ insert ก่อน)
--   → แก้ฝั่งบรรทัดอย่างเดียวไม่พอ ข้อความก็ยังผิดสาขา
--
-- ยังคงหลักเดิมไว้ทั้งสองข้อ:
--   · ตรวจ cap เฉพาะตอนใบที่เพิ่มค่าเผื่อ "เข้ามา" ในยอดของผู้ถือ (ใบใหม่ · ออกจาก
--     void · ย้ายเข้ามา) ไม่ใช่ทุกครั้งที่แก้หัวรายการ — ไม่งั้นแก้ memo ของใบเก่า
--     จะถูกปฏิเสธเพราะสภาพที่ใบอื่นสร้างไว้ (อาการเดียวกับข้อ 1 ของ D-103)
--   · ฝั่งผู้ถือ **เก่า** ตอนย้ายใบเป็น 'other' เสมอ — ยอดของเขาลดลง ไม่ใช่เพิ่ม
-- ------------------------------------------------------------
create or replace function fn_txn_allowance_guard() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_net_allowance numeric(18,2) := 0;
  v_net_recovery  numeric(18,2) := 0;
  v_cause   text := 'other';
  v_rcause  text := 'other';
  v_entered boolean;
begin
  if new.owner_id is not null then
    -- ใบนี้ "เข้ามา" อยู่ในยอดของผู้ถือรายนี้ตอนนี้หรือไม่
    v_entered := (tg_op = 'INSERT')
              or (tg_op = 'UPDATE' and old.status = 'void' and new.status <> 'void')
              or (tg_op = 'UPDATE' and old.owner_id is distinct from new.owner_id);
    if v_entered and new.status <> 'void' then
      select coalesce(sum(case when c.code = '1290' then l.credit - l.debit else 0 end), 0),
             coalesce(sum(case when c.code = '4320' then l.credit - l.debit else 0 end), 0)
        into v_net_allowance, v_net_recovery
        from sri_os.transaction_lines l
        join sri_os.chart_of_accounts c on c.id = l.coa_id
       where l.transaction_id = new.id;

      if v_net_allowance > 0 then
        v_cause := 'allowance_up';
      elsif v_net_allowance < 0 then
        -- ใบที่เข้ามาแล้ว **ลด** ค่าเผื่อ = ตัดหนี้สูญ / กลับค่าเผื่อ
        -- ทางแก้ของสาขานี้คือ "ตั้งค่าเผื่อเพิ่มก่อน" ซึ่งตรงข้ามกับสาขา 'other'
        v_cause := 'allowance_down';
      end if;
      if v_net_recovery > 0 then v_rcause := 'recovery_up'; end if;
    end if;

    perform sri_os.fn_assert_allowance_limits(new.owner_id, v_cause);
    perform sri_os.fn_assert_receivable_not_negative(new.owner_id);
    perform sri_os.fn_assert_recovery_within_writeoff(new.owner_id, v_rcause);
  end if;

  if tg_op = 'UPDATE' and old.owner_id is distinct from new.owner_id then
    perform sri_os.fn_assert_allowance_limits(old.owner_id, 'other');
    perform sri_os.fn_assert_receivable_not_negative(old.owner_id);
    perform sri_os.fn_assert_recovery_within_writeoff(old.owner_id, 'other');
  end if;
  return null;
end $fn$;

comment on function fn_txn_allowance_guard() is
  'ด่านค่าเผื่อ + ลูกหนี้ + หนี้สูญได้รับคืน ฝั่งหัวรายการ · จำเป็นเพราะ update transactions set status/owner_id เปลี่ยนยอดสะสมของผู้ถือโดยไม่แตะ transaction_lines → trigger ที่ผูกแค่บรรทัดจะไม่ยิงเลย (เส้นทางของ void ใบตัดหนี้สูญขณะมีใบรับคืน) · ตรวจ cap เฉพาะตอนที่ใบซึ่งเพิ่มค่าเผื่อเข้ามาในยอดของผู้ถือ · ใบที่เข้ามาแล้วลดค่าเผื่อตอบ allowance_down เพื่อให้ข้อความชี้ทางแก้ถูกสาขา (ฝั่งนี้ยิงก่อนฝั่งบรรทัดเสมอ)';

drop trigger if exists trg_txn_allowance_limits on transactions;
create constraint trigger trg_txn_allowance_limits
  after insert or update on transactions
  deferrable initially deferred
  for each row execute function fn_txn_allowance_guard();

-- ------------------------------------------------------------
-- 4 · ACL — ฟังก์ชันใหม่ติด PUBLIC EXECUTE มาจาก Postgres ต้องปิด
--     (20261007000007 revoke เป็นชุด **ตอนที่มันรัน** ฟังก์ชันที่เพิ่มทีหลังไม่ถูกครอบ)
--     trigger ยิงเองโดยไม่ต้องมี execute ของผู้เรียก — กฎเงินห้ามเรียกเอง
-- ------------------------------------------------------------
revoke all on function fn_assert_recovery_within_writeoff(uuid, text) from public;
revoke all on function fn_allowance_guard()                           from public;
revoke all on function fn_txn_allowance_guard()                       from public;
do $do$
begin
  execute 'revoke all on function sri_os.fn_assert_recovery_within_writeoff(uuid, text) from anon, authenticated';
  execute 'revoke all on function sri_os.fn_allowance_guard()                          from anon, authenticated';
  execute 'revoke all on function sri_os.fn_txn_allowance_guard()                      from anon, authenticated';
end $do$;

-- ------------------------------------------------------------
-- 5 · guard ท้ายไฟล์ — ต้องดังตอน migrate ถ้าผลลัพธ์ไม่ตรงกับที่ไฟล์นี้อ้าง
--     (ประวัติที่ขัดกฎใหม่เป็น warning: raise = migrate ของจริงล้มเพราะข้อมูลเก่า
--      ซึ่งแก้ด้วยไฟล์นี้ไม่ได้ ต้องตามแก้ด้วยมือตามเคส)
-- ------------------------------------------------------------
do $do$
declare
  v_type int; v_defer boolean; v_init boolean; v_con oid; v text; v_src text; n int;
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
      raise exception 'ไม่พบด่าน % — ค่าเผื่อติดลบ ลูกหนี้ติดลบ และรับคืนหนี้สูญที่ไม่เคยตัด เกิดได้ทันที', v;
    end if;
    if not (v_defer and v_init and v_con <> 0) then
      raise exception 'ด่าน % ไม่ได้ผูกเป็น constraint trigger (deferrable initially deferred) — ผลของด่านจะขึ้นกับลำดับการ insert ของบรรทัด แล้วใบที่ถูกต้องจะถูกปฏิเสธแบบสุ่ม', v;
    end if;
    if (v_type & 2) <> 0 then
      raise exception 'ด่าน % วางไว้ที่ BEFORE — ตอนนั้นบรรทัดของใบยังไม่ครบ ด่านจะตัดสินจากสภาพครึ่งๆ', v;
    end if;
  end loop;

  -- (ข) ด่านใหม่ต้องมีตัวเดียว และถูกเรียกจากทั้งสองฝั่ง
  select count(*) into n from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'sri_os' and p.proname = 'fn_assert_recovery_within_writeoff';
  if n <> 1 then
    raise exception 'มีฟังก์ชัน fn_assert_recovery_within_writeoff % ตัว (ต้องมีตัวเดียว)', n;
  end if;
  foreach v in array array['fn_allowance_guard', 'fn_txn_allowance_guard'] loop
    select p.prosrc into v_src from pg_proc p
      join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'sri_os' and p.proname = v;
    if v_src not like '%fn_assert_recovery_within_writeoff%' then
      raise exception 'ด่าน % ไม่เรียก fn_assert_recovery_within_writeoff — เส้นทางหนึ่งของรูที่ 1 ยังเปิดอยู่', v;
    end if;
    -- (ค) กับดัก ROW IS NOT NULL ต้องไม่กลับมา
    if v_src ~* '\m(new|old)\s+is\s+(not\s+)?null\M' then
      raise exception 'ด่าน % ถาม NEW/OLD ด้วย IS NULL อีกแล้ว — ROW IS NOT NULL เป็นจริงเฉพาะเมื่อทุกคอลัมน์ไม่เป็น null จึงตอบ false ตลอดและส่วนต่างเป็น 0 ตลอด (UPDATE บรรทัดจะเลี่ยง cap ได้) · ต้องดู tg_op แทน', v;
    end if;
  end loop;

  -- (ง) ประวัติที่ขัดกฎใหม่ — ให้เห็นก่อนที่ผู้ใช้จะเจอตอนกดบันทึกใบถัดไป
  select count(*) into n
    from sri_os.owners o
   where (
     select coalesce(sum(l.credit - l.debit), 0)
       from sri_os.transactions t
       join sri_os.transaction_lines l on l.transaction_id = t.id
       join sri_os.chart_of_accounts c on c.id = l.coa_id
      where t.owner_id = o.id and t.status <> 'void' and c.code = '4320'
   ) > (
     select coalesce(sum(x.net_writeoff), 0)
       from (
         select sum(case when c.code = '1290' then l.debit - l.credit else 0 end) as net_writeoff,
                bool_or(c.code in ('1200', '1210', '1220')) as touches_receivable
           from sri_os.transactions t
           join sri_os.transaction_lines l on l.transaction_id = t.id
           join sri_os.chart_of_accounts c on c.id = l.coa_id
          where t.owner_id = o.id and t.status <> 'void'
          group by t.id
       ) x
      where x.touches_receivable
   );
  if n > 0 then
    raise warning 'มีผู้ถือ % รายที่ลง "หนี้สูญได้รับคืน" มากกว่ายอดที่ตัดหนี้สูญไว้อยู่แล้วก่อนไฟล์นี้ — รายได้ถูกนับสองรอบและลูกหนี้ค้างในงบดุล · ด่านใหม่จะปฏิเสธรายการถัดไปที่แตะบัญชีกลุ่มนี้ของผู้ถือรายนั้นจนกว่าจะลงรายการแก้ให้ถูก (กลับรายการใบรับคืนที่เกิน หรือตัดหนี้สูญให้ครบตามความจริง) · ของเก่าแก้ด้วยไฟล์นี้ไม่ได้', n;
  end if;

  raise notice 'ด่านรุ่นใหม่พร้อมใช้ · หนี้สูญได้รับคืนสะสมห้ามเกินยอดตัดหนี้สูญสะสมต่อผู้ถือ (ข้อความแยกสองสาขา) · ด่านระดับบรรทัดเห็นส่วนต่างจริงแล้ว (UPDATE/DELETE เลี่ยง cap ไม่ได้) · หัวรายการตอบ allowance_down ได้';
end $do$;
