-- ============================================================
-- SRI OS · ตารางกฎฝั่ง DB ต้องเก็บ `cash: "none"` ได้ (คอลัมน์ txn_types.cash_direction)
--
-- ------------------------------------------------------------
-- ⚠ เงื่อนไขที่ต้องจริงตลอดไป (แก้ไฟล์นี้ 22/10 · D-106 · D-090)
-- ------------------------------------------------------------
-- ไฟล์นี้ถูกแก้หลังวันที่เขียนครั้งแรก ซึ่ง D-090 ห้ามทำกับไฟล์ที่ apply ไปแล้ว
-- ทำได้เพราะตรวจแล้ว 22/10 ว่า **หมายเลขรุ่นใน project เดิม
-- (`oyigmbmxxlfhkrevsmxo`) เป็นคนละชุดกับชื่อไฟล์ในรีโปนี้ทั้งหมด**
-- (ของจริง `20260917160457` · ของรีโป `20260917000001`) → ไฟล์พวกนี้
-- **ไม่เคยถูก apply ในฐานะไฟล์** และ project ใหม่เริ่มจากศูนย์
--
-- **ห้ามเอาไฟล์ในรีโปนี้ไป apply กับ project เดิม (`oyigmbmxxlfhkrevsmxo`) อีก**
-- เงื่อนไขนี้คือสิ่งเดียวที่ทำให้การแก้ไฟล์เก่าปลอดภัย · ถ้าวันหนึ่งมีใครจะ
-- apply ย้อนกับ project เดิม ต้องถือว่าสมมติฐานนี้ตายแล้ว และต้องตรวจ
-- ทุกไฟล์ที่ถูกแก้ย้อนหลังใหม่ทั้งหมดก่อน
--
-- ย้อนกลับ (rollback):
--   alter table sri_os.txn_types drop constraint if exists txn_types_cash_direction_matches_direction;
--   alter table sri_os.txn_types drop constraint if exists txn_types_cash_direction_values;
--   alter table sri_os.txn_types drop column if exists cash_direction;
--   -- ย้อนแล้ว DB จะแยก "โอนสองทาง" กับ "ไม่มีเงินเคลื่อน" ไม่ออกอีก (ทั้งคู่ direction = 0)
--   -- และ `npm run sync:rules` รุ่นปัจจุบันจะ generate SQL ที่อ้างคอลัมน์ที่ไม่มี → migration ล้ม
--
-- ------------------------------------------------------------
-- ทำไมต้องมีคอลัมน์ใหม่ ไม่ใช่ขยาย check ของ `direction`
-- ------------------------------------------------------------
-- `src/lib/rules/tx-rules.ts` ขยาย `CashDirection` เป็น `in | out | both | none`
-- (`none` = รายการปรับปรุงทางบัญชี ไม่มีขาเงินสดเลย เช่น ตั้งค่าเผื่อ · ตัดหนี้สูญ)
--
-- ฝั่ง DB มี `txn_types.direction smallint not null check (direction in (-1, 0, 1))`
-- ซึ่งคอมเมนต์ในไฟล์ 20260917000001 นิยามไว้ว่า "+1 เงินเข้า, -1 เงินออก, 0 สองทาง"
-- → **ไม่มีค่าสำหรับ "ไม่มีเงินเคลื่อน"** · ถ้าปล่อยให้ `none` ถูกยุบเป็น 0
--   สำเนากฎใน DB จะตอบคำถาม "หมวดนี้มีเงินเคลื่อนไหม" **ผิด** โดยไม่มีอะไรฟ้อง
--   ซึ่งเป็นรูปแบบเดียวกับที่ `sync:rules` ตั้งใจพังเมื่อมีฟิลด์ใหม่ที่ DB ไม่รู้จัก
--   (กฎใน DB ที่ไม่ครบเงียบๆ อันตรายกว่าไม่มีกฎเลย)
--
-- ขยาย check ของ `direction` ให้รับค่าที่สี่ (เช่น 2) **ไม่ทำ** เพราะ:
--   คอลัมน์นั้นเป็นตัวเลขมีเครื่องหมายที่สื่อทิศเงิน · ค่า 2 ไม่มีความหมายในระบบนั้น
--   และโค้ด/รายงานที่อ่าน `direction` อยู่จะตีความใหม่ได้เอง ซึ่งเดาผิดง่ายกว่าอ่านสตริง
--
-- `direction` ยังอยู่ตามเดิม (ยังไม่มี trigger/ฟังก์ชันไหนอ่านมันเลย ณ วันนี้ — ตรวจแล้ว)
-- แต่ constraint ด้านล่างผูกสองคอลัมน์ให้ตรงกันเสมอ จึงไม่มีทางเพี้ยนจากกันได้
--
-- ------------------------------------------------------------
-- ลำดับการ apply (สำคัญ)
-- ------------------------------------------------------------
-- ไฟล์นี้ **ไม่อยู่ใน `supabase/migration-order.txt`** โดยตั้งใจ → ทั้ง
-- `scripts/apply-migrations.sh` และ `scripts/test-rls-local.sh` จะรันมันในรอบแรก
-- (เรียงตามชื่อไฟล์) ซึ่งมาก่อนไฟล์ seed ที่ `npm run sync:rules` สร้าง
-- (ชื่อ `20261009<HHMMSS>_seed_rules.sql` · HHMMSS ของวันที่ทำงานนี้คือ 18xxxx)
-- ถ้าไฟล์นี้ถูกเลื่อนไปอยู่ท้ายสุด ไฟล์ seed จะล้มเพราะคอลัมน์ยังไม่เกิด
--
-- idempotent: add column if not exists · backfill แบบ update ทับได้ ·
--   drop constraint if exists ก่อน add ทุกตัว → replay ซ้ำได้
-- **ลำดับในไฟล์สำคัญ**: backfill ต้องเสร็จก่อน set not null และก่อน add constraint
--   (บทเรียน D-099: เพิ่มคอลัมน์พร้อม constraint ในไฟล์เดียวโดยที่แถวเดิมยังละเมิดอยู่
--    ทำให้ไฟล์ล้มครึ่งทางเมื่อ apply แบบไม่ atomic แล้วไฟล์ถัดไปพังต่อเป็นทอดๆ)
-- ============================================================

set search_path = sri_os, public;

alter table sri_os.txn_types
  add column if not exists cash_direction text;

-- ---------- backfill จากสิ่งที่ DB ถืออยู่ตอนนี้ ----------
-- แถวเดิมทั้งหมดมาจากตารางกฎรุ่นที่ยังไม่มี `none` → direction 0 คือ `both` เท่านั้น
-- (หมวดเดียวที่เป็น 0 คือ trf.internal) · เติมเฉพาะแถวที่ยังว่าง ไม่ทับค่าที่ seed ใส่มา
update sri_os.txn_types
   set cash_direction = case direction when 1 then 'in' when -1 then 'out' else 'both' end
 where cash_direction is null;

-- ---------- บังคับให้ด่าน deferred ยิงก่อน DDL ----------
-- `txn_types` มี constraint trigger แบบ `deferrable initially deferred`
-- (`trg_assert_accrual_clearable` ของ 20261006000003) · การ update ข้างบน
-- จึง **ค้าง trigger event ไว้จนจบ transaction** และ Postgres ปฏิเสธ DDL
-- ตัวถัดไปด้วย `cannot ALTER TABLE because it has pending trigger events`
-- (วัดแล้ว 20/10 · D-106 — ต้นเหตุที่ลากไฟล์พังต่ออีก 8 ไฟล์ตอน replay
--  จาก DB เปล่า · ตอนรันแบบไม่ atomic ไม่เจอ เพราะ trigger ยิงท้ายทุกคำสั่ง
--  = สิ่งที่เทสต์กับสิ่งที่ apply เป็นคนละอย่าง)
--
-- `set constraints all immediate` **ไม่ลดความเข้มอะไรเลย** — มันบังคับให้ด่าน
-- ที่ค้างอยู่ตรวจ **เดี๋ยวนี้** แทนที่จะตรวจตอน commit · ถ้าแถวไหนละเมิด
-- ไฟล์นี้จะพังที่บรรทัดนี้ (เสียงดัง) ไม่ใช่ผ่านไปเงียบๆ
-- ผลข้างเคียงคือด่านที่เหลือในไฟล์นี้ก็ตรวจทันทีเช่นกัน ซึ่งเข้มกว่าเดิม
set constraints all immediate;

alter table sri_os.txn_types
  alter column cash_direction set not null;

alter table sri_os.txn_types
  drop constraint if exists txn_types_cash_direction_values;
alter table sri_os.txn_types
  add constraint txn_types_cash_direction_values
  check (cash_direction in ('in', 'out', 'both', 'none'));

-- สองคอลัมน์ห้ามเล่าเรื่องต่างกัน · `none` กับ `both` แชร์ direction = 0 ได้
-- (นั่นคือข้อจำกัดของคอลัมน์เก่า) แต่ in/out ต้องตรงกันเป๊ะทั้งสองทิศ
alter table sri_os.txn_types
  drop constraint if exists txn_types_cash_direction_matches_direction;
alter table sri_os.txn_types
  add constraint txn_types_cash_direction_matches_direction
  check (
    direction = case cash_direction
                  when 'in'  then 1
                  when 'out' then -1
                  else 0
                end
  );

comment on column sri_os.txn_types.cash_direction is
  'สำเนาของ `cash` ใน src/lib/rules/tx-rules.ts (in | out | both | none) · **คอลัมน์นี้คือตัวที่ตอบว่าหมวดนี้มีเงินเคลื่อนไหม** · direction (smallint) แยก none จาก both ไม่ออกเพราะทั้งคู่เป็น 0 · sync ด้วย npm run sync:rules';

-- ------------------------------------------------------------
-- guard ท้ายไฟล์ — ดังตอน migrate ไม่ใช่ตอนผู้ใช้กดบันทึก
-- ------------------------------------------------------------
do $do$
declare v text;
begin
  -- หมวดที่บอกว่าไม่มีเงินเคลื่อน แต่คู่บัญชีมีขา 11xx = ธงกับบัญชีขัดกัน
  -- (เงินจะเคลื่อนจริงโดยที่ฟอร์มไม่ถามบัญชีและไม่ถามวันที่เงินเข้า-ออก)
  select string_agg(code, ', ' order by code) into v
    from sri_os.txn_types
   where cash_direction = 'none'
     and (coalesce(dr_coa_code, '') ~ '^11[0-9][0-9]$' or coalesce(cr_coa_code, '') ~ '^11[0-9][0-9]$');
  if v is not null then
    raise exception 'หมวดที่ตั้ง cash_direction = none แต่คู่บัญชียังมีขาเงินสด 11xx: % — แก้ที่ src/lib/rules/tx-rules.ts แล้ว sync:rules ใหม่', v;
  end if;

  -- และทางกลับกัน: หมวดที่บอกว่าเงินเคลื่อน ต้องมีขาเงินสดให้ผูกบัญชีได้ (Money Invariant 2)
  select string_agg(code, ', ' order by code) into v
    from sri_os.txn_types
   where cash_direction <> 'none'
     and coalesce(dr_coa_code, '') !~ '^11[0-9][0-9]$'
     and coalesce(cr_coa_code, '') !~ '^11[0-9][0-9]$';
  if v is not null then
    raise warning 'หมวดที่บอกว่าเงินเคลื่อนแต่ไม่มีขาเงินสดในคู่บัญชี: % — ถ้าเป็นเส้นทางที่ engine สร้างบรรทัดเงินสดเองได้ (ขายทรัพย์/แยกเงินต้น-ดอกเบี้ย) ไม่ผิด · ถ้าไม่ใช่ แปลว่าธง cash ไม่ตรงกับคู่บัญชี', v;
  end if;

  raise notice 'txn_types.cash_direction พร้อมใช้ · ค่าที่อนุญาต: in | out | both | none';
end $do$;
