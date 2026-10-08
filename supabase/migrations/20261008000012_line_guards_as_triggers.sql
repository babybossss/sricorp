-- ============================================================
-- SRI OS · ยกด่านของบรรทัดบัญชีสองข้อจาก "ประตู" ขึ้นเป็น "trigger บนตาราง"
--
--   ข้อ 3 · คู่บัญชีของทุกบรรทัดต้องอยู่ในชุดบัญชีที่ **ตารางกฎ** ระบุไว้ของหมวดนั้น
--   ข้อ 7 · bank_account_id ติดได้เฉพาะบรรทัดเงินสด 11xx
--
-- ที่มา: 20261008000011 ปิดสองข้อนี้ไว้ที่ `fn_post_entry()` เท่านั้น เพราะ fixture
--   ของเทสต์ที่ apply แล้ว **ใส่ข้อมูลที่ของจริงเป็นไปไม่ได้** (คู่บัญชีสมมติจาก
--   `where code not like '11%' limit 2` และ bank_account_id บนบรรทัดที่ไม่ใช่เงินสด)
--   → ยกเป็น trigger ตอนนั้นจะทำให้เทสต์เก่าแดงทั้งแถบ
--   รอบนี้แก้ที่ต้นเหตุ: fixture ใช้คู่บัญชีจริงจากตารางกฎแล้ว (ดู supabase/tests/**)
--   จึงยกด่านขึ้นได้ · **ด่านที่อยู่แค่ในประตูอ่อนกว่า trigger** เพราะ PostgREST
--   เขียนตรงเข้าตารางได้โดยไม่ผ่าน RPC (บทเรียนข้อ 6 ในระดับฐานข้อมูล)
--
-- และ **ล็อกบัญชีระหว่างกันเป็นรหัสตรง** (1310/2310/1710/3100/3200/4410)
--   ไม่ใช่แค่ "ประเภทบัญชีตรงกับลักษณะนั้น" อย่างที่ประตูทำได้ในรอบก่อน
--   (รอบก่อนล็อกรหัสตรงไม่ได้เพราะ T4/T5 ใช้ 1300/2400 · รอบนี้ T4/T5 แก้แล้ว)
--
-- ทำอะไร (ทั้งหมด create or replace / drop ... if exists → **รันซ้ำได้**):
--   1 · fn_intercompany_pairs()          — สำเนาเดียวของคู่บัญชีระหว่างกันในฝั่ง DB
--   2 · fn_intercompany_coa(text)        — อ่านคู่ของลักษณะหนึ่ง (null = ไม่รู้จัก)
--   3 · fn_assert_line_coa_in_rules()    — trigger: ข้อ 3 (อ่านชุดบัญชีจาก txn_types)
--   4 · fn_assert_line_bank_is_cash()    — trigger: ข้อ 7
--   5 · guard ท้ายไฟล์                    — ดังตอน migrate ถ้าสำเนาคู่บัญชีเพี้ยน
--
-- **ไม่แก้ไฟล์ migration เก่า และไม่แก้ fn_post_entry()**
--   ด่านในประตูยังอยู่ตามเดิม เพราะมันให้ข้อความก่อนที่อะไรจะถูกเขียน
--   ทั้งสองที่ **อ่านแหล่งความจริงเดียวกัน** (sri_os.txn_types) ไม่ใช่กฎที่สอง
--   ของที่ประตูยังหลวมกว่า (บัญชีระหว่างกันเทียบแค่ประเภท) ถูกทำให้แน่นที่ trigger นี้
--
-- rollback note (ย้อนได้ทั้งไฟล์ ไม่ต้องแตะไฟล์อื่น · ไม่มีการแก้ข้อมูลเดิมเลย):
--   drop trigger  if exists trg_lines_rule_coa       on sri_os.transaction_lines;
--   drop trigger  if exists trg_lines_rule_bank_cash on sri_os.transaction_lines;
--   drop function if exists sri_os.fn_assert_line_coa_in_rules();
--   drop function if exists sri_os.fn_assert_line_bank_is_cash();
--   drop function if exists sri_os.fn_intercompany_coa(text);
--   drop function if exists sri_os.fn_intercompany_pairs();
--   ย้อนแล้วด่านไม่หายทั้งหมด แต่ **เหลือแค่ที่ประตู** = การเขียนตรงเข้าตาราง
--   เลี่ยงได้อีกครั้ง · ถ้าย้อนเพราะด่านกันของที่ถูก ให้แก้ตารางกฎ (sync:rules)
--   ไม่ใช่ย้อนด่าน
--
-- ของเก่าที่ลงไว้ก่อนไฟล์นี้: trigger ตรวจแต่แถวที่เขียนใหม่ (by design —
--   แถวที่ post แล้วแก้ไม่ได้อยู่แล้ว ต้อง reverse + ลงใหม่) · guard ท้ายไฟล์
--   จึง **รายงานจำนวนบรรทัดเก่าที่ไม่ตรงกฎ** ด้วย warning ไม่ใช่ raise
--   (raise = migrate ของจริงล้มเพราะประวัติ ซึ่งแก้ด้วยไฟล์นี้ไม่ได้)
-- ============================================================

set search_path = sri_os, public;

-- ------------------------------------------------------------
-- 1 · คู่บัญชีระหว่างกัน — **สำเนาเดียวในฝั่ง DB** ของ src/lib/rules/intercompany.ts
--
-- ทำไมเป็นฟังก์ชันไม่ใช่ตาราง: ตารางใหม่ต้องมี RLS + policy + grant + audit +
--   allow-list ของเทสต์ตารางกฎ ซึ่งเป็นผิวสัมผัสใหม่ทั้งชุดเพื่อเก็บ 4 แถวที่
--   เปลี่ยนได้เฉพาะด้วย migration อยู่แล้ว · ฟังก์ชัน immutable ให้คุณสมบัติเดียวกัน
--   (แอปแก้ไม่ได้ · เปลี่ยนได้เฉพาะในไฟล์ใน git) และ **enumerate ได้** จึงเอาไป
--   เทียบกับ constraint และกับสำเนาในไฟล์ 20261008000011 ได้ที่ guard ท้ายไฟล์
--
-- **ยังเป็นสำเนา** `npm run sync:rules` ครอบแค่ txn_types ไม่ครอบตารางนี้
--   สิ่งที่ทำให้มันไม่เพี้ยนเงียบๆ มีสามชั้น (ดู guard ท้ายไฟล์):
--     (ก) ลักษณะใหม่ใน intercompany.ts ที่ยังไม่มีใน constraint ของ transactions
--         → ผู้ใช้กดบันทึกไม่ได้ทันที (check constraint ปฏิเสธ) = ดังทันที ไม่เงียบ
--     (ข) ลักษณะใหม่ที่เพิ่มใน constraint แล้วแต่ยังไม่มีในฟังก์ชันนี้
--         → **migration ล้มตอนรัน** (guard ก)
--     (ค) รหัสบัญชีในสำเนาของ 20261008000011 (ประตู + trigger คู่ข้ามผู้ถือ)
--         ไม่ตรงกับฟังก์ชันนี้ → **migration ล้มตอนรัน** (guard ข)
--   ที่ยังขาด: สคริปต์ฝั่ง TypeScript ที่เทียบ intercompany.ts กับไฟล์นี้
--   (เสนอไว้ในรายงาน — ต้องเติมใน package.json / scripts/sync-txn-types.ts)
-- ------------------------------------------------------------
create or replace function fn_intercompany_pairs()
  returns table (nature text, payer_coa text, receiver_coa text)
language sql immutable as $fn$
  -- ฝ่ายจ่าย | ฝ่ายรับ — ตรงกับ INTERCOMPANY_RULES ใน src/lib/rules/intercompany.ts
  values ('advance',  '1310', '2310'),
         ('loan',     '1310', '2310'),
         ('capital',  '1710', '3100'),
         ('dividend', '3200', '4410')
$fn$;

comment on function fn_intercompany_pairs() is
  'สำเนาเดียวในฝั่ง DB ของคู่บัญชีระหว่างกัน (src/lib/rules/intercompany.ts) · enumerate ได้เพื่อให้ guard เทียบกับ constraint และกับสำเนาในไฟล์ 20261008000011 ได้ · sync:rules ยังไม่ครอบ';

create or replace function fn_intercompany_coa(p_nature text) returns text[]
language sql immutable as $fn$
  select array[p.payer_coa, p.receiver_coa]
    from sri_os.fn_intercompany_pairs() p
   where p.nature = p_nature;
$fn$;

comment on function fn_intercompany_coa(text) is
  'คู่บัญชีของลักษณะข้ามผู้ถือหนึ่งลักษณะ = {ฝ่ายจ่าย, ฝ่ายรับ} · null = ลักษณะที่ไม่รู้จัก (ต้องปฏิเสธ ห้ามเดา)';

-- ------------------------------------------------------------
-- 2 · ข้อ 3 · คู่บัญชีของบรรทัดต้องอยู่ในชุดที่ตารางกฎระบุของหมวดนั้น
--
-- **ไม่คิดคู่บัญชีเอง** — อ่านจาก sri_os.txn_types (dr/cr/gain/loss/interest/accrual)
--   ซึ่งเป็นสำเนาของ src/lib/rules/tx-rules.ts ที่ sync ด้วย npm run sync:rules
--   ถ้าตารางกฎไม่ระบุบัญชีของหมวดนั้นเลย → ปฏิเสธ (ห้ามเดาแทน)
--
-- เทียบเป็น **ชุด** ไม่ใช่ "ขาไหนต้องเดบิต" โดยตั้งใจ:
--   รายการกลับรายการใช้รหัสเดิมสลับด้าน · ถ้าเทียบด้าน reverse จะลงไม่ได้
--   = กันแน่นเกินจนใช้งานไม่ได้ ซึ่งก็คือพัง
--   ครอบทุกสาขาที่ posting.ts สร้างได้: ปกติ (dr/cr) · ค้างรับ-ค้างจ่าย (accrual) ·
--   ขายทรัพย์ (gain/loss) · แยกเงินต้น-ดอกเบี้ย (interest) · กลับรายการ
--
-- ขาของรายการข้ามผู้ถือ: **ล็อกเป็นรหัสตรง** ของลักษณะนั้น (+ ขาเงินสด 1100)
--   ต่างจากประตูที่เทียบแค่ "ประเภทบัญชีเดียวกัน" → Dr 1300 (เงินให้กู้ยืม ซึ่งก็เป็น
--   สินทรัพย์เหมือน 1310) บนขากู้ยืมระหว่างกันถูกปฏิเสธที่นี่
--   ถ้าไม่ล็อกรหัส งบรวมจะตัดรายการระหว่างกันไม่ลง เพราะ 1300 ไม่ใช่บัญชีที่คู่กับ 2310
--
-- หัวรายการที่หายังไม่เจอ (FK ยังไม่ตรวจ / แถวของอีกธุรกรรม) → ปล่อยผ่าน
--   ให้ FK และ trg_lines_immutable_after_post เป็นคนปฏิเสธด้วยข้อความของมัน
--   (ห้ามสร้างข้อความที่สองของกฎเดียวกัน)
--
-- security definer + search_path ล็อก ด้วยเหตุผลเดียวกับ fn_assert_line_bank_owner:
--   ต้องได้คำตอบจริงจาก transactions/txn_types ไม่ใช่ได้ null แล้วหลุดด่าน
--   เพราะผู้เรียกมองแถวนั้นไม่เห็น · ไม่เรียก fn_can เลย — กฎเงินปิดจาก Settings ไม่ได้
-- ------------------------------------------------------------
create or replace function fn_assert_line_coa_in_rules() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_type    text;
  v_nature  text;
  v_code    text;
  v_allowed text[];
  v_pair    text[];
begin
  select t.txn_type_code, nullif(t.intercompany_nature, '')
    into v_type, v_nature
    from sri_os.transactions t
   where t.id = new.transaction_id;
  if v_type is null then
    return new;   -- ไม่มีหัวรายการให้เทียบ → FK/ด่านอื่นปฏิเสธด้วยข้อความของมันเอง
  end if;

  select c.code into v_code
    from sri_os.chart_of_accounts c where c.id = new.coa_id;
  if v_code is null then
    raise exception 'บรรทัดบัญชีชี้รหัสบัญชีที่ไม่มีอยู่ในผังบัญชี (coa_id %)', new.coa_id;
  end if;

  select array_remove(array[t.dr_coa_code, t.cr_coa_code, t.gain_coa_code,
                            t.loss_coa_code, t.interest_coa_code, t.accrual_coa_code], null)
    into v_allowed
    from sri_os.txn_types t where t.code = v_type;
  if v_allowed is null or cardinality(v_allowed) = 0 then
    raise exception 'ตารางกฎ (txn_types) ไม่ได้ระบุบัญชีของหมวด "%" เลย — sync ด้วย npm run sync:rules ก่อน ห้ามเดาคู่บัญชีแทน',
      v_type;
  end if;

  if v_nature is not null then
    v_pair := sri_os.fn_intercompany_coa(v_nature);
    if v_pair is null then
      raise exception 'ลักษณะรายการข้ามผู้ถือ "%" ยังไม่มีคู่บัญชีระหว่างกันในฝั่งฐานข้อมูล — เพิ่มใน fn_intercompany_pairs() ให้ตรงกับ src/lib/rules/intercompany.ts ก่อนใช้',
        v_nature;
    end if;
    -- ขาเงินสดกับ **รหัสตรง** ของลักษณะนั้นใช้ได้บนขาข้ามผู้ถือ
    v_allowed := v_allowed || array['1100'] || v_pair;
  end if;

  if not (v_code = any (v_allowed)) then
    raise exception 'หมวด "%" ลงบัญชี % ไม่ได้ — ตารางกฎระบุบัญชีของหมวดนี้ไว้เฉพาะ % · คู่บัญชีที่ไม่ตรงหมวดทำให้ผิดทั้งงบ (เช่น เงินกู้กลายเป็นรายได้)',
      v_type, v_code, array_to_string(v_allowed, ', ');
  end if;

  return new;
end $fn$;

comment on function fn_assert_line_coa_in_rules() is
  'ข้อ 3 ของผู้ตรวจ · ทุกบรรทัดต้องใช้บัญชีที่ตารางกฎ (sri_os.txn_types) ระบุของหมวดนั้น · ขาข้ามผู้ถือล็อกเป็นรหัสตรงจาก fn_intercompany_pairs() · เทียบเป็นชุดเพื่อให้รายการกลับรายการยังลงได้ · trigger ไม่ใช่ด่านในประตู เพราะเขียนตรงเข้าตารางก็ต้องกัน';

-- ชื่อ trigger ขึ้นต้น trg_lines_r* โดยตั้งใจ: BEFORE row trigger ยิงเรียงตามชื่อ
--   → ยิงหลัง trg_lines_immutable_after_post และ trg_line_bank_owner
--   กฎ "แก้ของที่ post แล้วไม่ได้" และ "บัญชีต้องเป็นของผู้ถือ" จึงยังเป็นคนพูดก่อน
--   (ถ้าด่านนี้พูดก่อน ข้อความที่ผู้ใช้เห็นจะชี้ผิดจุด และเทสต์เก่าที่ตรวจข้อความจะแดง)
drop trigger if exists trg_lines_rule_coa on transaction_lines;
create trigger trg_lines_rule_coa
  before insert or update on transaction_lines
  for each row execute function fn_assert_line_coa_in_rules();

-- ------------------------------------------------------------
-- 3 · ข้อ 7 · bank_account_id ติดได้เฉพาะบรรทัดเงินสด 11xx
--
-- 1100-1199 = เงินสดและเงินฝาก (เกณฑ์เดียวกับ fn_assert_no_floating_cash และประตู)
-- ที่ผู้ตรวจทำได้: bank_account_id ติดอยู่บนบรรทัดรายได้ 4200 → รายการนั้นถูกนับ
--   เป็นความเคลื่อนไหวของบัญชีธนาคารตอนกระทบยอด ทั้งที่เงินไม่ได้เข้าออกบัญชีนั้น
-- คู่กับ fn_assert_line_bank_owner (ของ 20261008000011) ที่ตรวจว่าบัญชีเป็นของผู้ถือ
--   แยกฟังก์ชันกันเพื่อให้ข้อความชี้จุดได้ตรง และถอดทีละข้อได้
-- ------------------------------------------------------------
create or replace function fn_assert_line_bank_is_cash() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare v_code text;
begin
  if new.bank_account_id is null then return new; end if;

  select c.code into v_code
    from sri_os.chart_of_accounts c where c.id = new.coa_id;
  if v_code is null then
    raise exception 'บรรทัดบัญชีชี้รหัสบัญชีที่ไม่มีอยู่ในผังบัญชี (coa_id %)', new.coa_id;
  end if;

  if v_code !~ '^11[0-9][0-9]$' then
    raise exception 'ผูกบัญชีธนาคารไว้กับบัญชี % ซึ่งไม่ใช่เงินสด/เงินฝาก — บัญชีธนาคารติดได้เฉพาะขาเงินสด (11xx) ไม่ใช่ขาลูกหนี้/เจ้าหนี้/รายได้ · ไม่งั้นกระทบยอดธนาคารจะนับบรรทัดที่เงินไม่ได้เข้าออก',
      v_code;
  end if;

  return new;
end $fn$;

comment on function fn_assert_line_bank_is_cash() is
  'ข้อ 7 ของผู้ตรวจ · bank_account_id อยู่ได้เฉพาะบรรทัดเงินสด 11xx · trigger ไม่ใช่ด่านในประตู เพราะเขียนตรงเข้าตารางก็ต้องกัน';

drop trigger if exists trg_lines_rule_bank_cash on transaction_lines;
create trigger trg_lines_rule_bank_cash
  before insert or update on transaction_lines
  for each row execute function fn_assert_line_bank_is_cash();

-- ------------------------------------------------------------
-- 4 · ACL — ฟังก์ชันใหม่ติด PUBLIC EXECUTE มาจาก Postgres ต้องปิด
--     trigger function: ปิดทุก role (กฎเงินห้ามเรียกเอง)
--     fn_intercompany_pairs/coa: ปิด public/anon · **เปิดให้ authenticated**
--       เพราะ trigger ที่เรียกมันเป็น security definer (เจ้าของเรียกได้อยู่แล้ว)
--       แต่ถ้าวันหนึ่งหน้าจอหรือ view ต้องอ่านกฎนี้ จะได้ไม่ต้องเปิดสิทธิ์ใหม่
--       ไม่เสี่ยง: ฟังก์ชันบริสุทธิ์ คืนค่าคงที่ 4 แถวที่อยู่ในโค้ดใน git อยู่แล้ว
-- ------------------------------------------------------------
revoke all on function fn_intercompany_pairs() from public;
revoke all on function fn_intercompany_coa(text) from public;
revoke all on function fn_assert_line_coa_in_rules() from public;
revoke all on function fn_assert_line_bank_is_cash() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_intercompany_pairs() from anon';
  execute 'revoke all on function sri_os.fn_intercompany_coa(text) from anon';
  execute 'grant execute on function sri_os.fn_intercompany_pairs() to authenticated';
  execute 'grant execute on function sri_os.fn_intercompany_coa(text) to authenticated';
  execute 'revoke all on function sri_os.fn_assert_line_coa_in_rules() from anon, authenticated';
  execute 'revoke all on function sri_os.fn_assert_line_bank_is_cash() from anon, authenticated';
end $$;

-- ------------------------------------------------------------
-- 5 · guard ท้ายไฟล์ — ต้อง "พังให้เห็น" ตอน migrate ไม่ใช่ raise notice
-- ------------------------------------------------------------
do $$
declare
  v text; n int; r record; v_def text; v_src text; v_bad text;
begin
  -- (ก) ลักษณะที่ตาราง transactions อนุญาต ต้องมีคู่บัญชีในฟังก์ชันนี้ **ครบ และไม่เกิน**
  select pg_get_constraintdef(oid) into v_def from pg_constraint
   where conrelid = 'sri_os.transactions'::regclass
     and conname = 'transactions_intercompany_nature_check';
  if v_def is null then
    raise exception 'ไม่มี constraint transactions_intercompany_nature_check — ลักษณะข้ามผู้ถือจะรับค่าอะไรก็ได้';
  end if;
  select string_agg(x.nature, ', ') into v
    from (select (regexp_matches(v_def, '''([a-z_]+)''::text', 'g'))[1] as nature) x
   where not exists (select 1 from sri_os.fn_intercompany_pairs() p where p.nature = x.nature);
  if v is not null then
    raise exception 'ลักษณะข้ามผู้ถือที่ตารางอนุญาตแต่ยังไม่มีคู่บัญชีใน fn_intercompany_pairs(): % — เพิ่มให้ตรงกับ src/lib/rules/intercompany.ts ก่อน ไม่งั้นรายการลักษณะนั้นจะถูกปฏิเสธตอนผู้ใช้กดบันทึก',
      v;
  end if;
  select string_agg(p.nature, ', ') into v from sri_os.fn_intercompany_pairs() p
   where position('''' || p.nature || '''' in v_def) = 0;
  if v is not null then
    raise exception 'fn_intercompany_pairs() มีลักษณะที่ตาราง transactions ไม่อนุญาต: % (constraint: %) — สำเนาเพี้ยนจากของจริง', v, v_def;
  end if;

  -- (ข) ทุกรหัสในสำเนาต้องมีในผังบัญชี และ **สำเนาในไฟล์ 20261008000011 ต้องตรงกัน**
  --     (กฎเดียวกันเขียนสองที่คือหนี้ที่ยังไม่จ่าย — ที่ทำได้วันนี้คือทำให้มันดังเมื่อเพี้ยน)
  select string_agg(x.code, ', ') into v
    from (select p.payer_coa as code from sri_os.fn_intercompany_pairs() p
          union select p.receiver_coa from sri_os.fn_intercompany_pairs() p) x
   where not exists (select 1 from sri_os.chart_of_accounts c where c.code = x.code);
  if v is not null then
    raise exception 'ผังบัญชีขาดรหัสที่คู่บัญชีระหว่างกันใช้: % — รายการข้ามผู้ถือจะถูกปฏิเสธตอนผู้ใช้กดบันทึก', v;
  end if;

  for r in select p.oid::regprocedure::text as sig, p.prosrc
             from pg_proc p
            where p.oid in ('sri_os.fn_post_entry(jsonb)'::regprocedure,
                            'sri_os.fn_assert_intercompany_pair()'::regprocedure)
  loop
    v_src := r.prosrc;
    select string_agg(format('%s→(%s,%s)', p.nature, p.payer_coa, p.receiver_coa), ', ')
      into v_bad
      from sri_os.fn_intercompany_pairs() p
     where v_src !~ ('''' || p.nature || '''\s*,\s*''' || p.payer_coa
                     || '''\s*,\s*''' || p.receiver_coa || '''');
    if v_bad is not null then
      raise exception 'สำเนาคู่บัญชีระหว่างกันใน % ไม่ตรงกับ fn_intercompany_pairs() (ขาด/ต่าง: %) — แก้ให้ตรงกันทั้งสองที่ หรือย้ายให้อ่านจาก fn_intercompany_pairs() ที่เดียว',
        r.sig, v_bad;
    end if;
    -- สำเนาต้องไม่มีคู่ "เกิน" ที่ของจริงมี (นับรูป 'x','1234','5678' ในโค้ด)
    select count(*) into n
      from regexp_matches(v_src, '''[a-z_]+''\s*,\s*''[0-9]{4}''\s*,\s*''[0-9]{4}''', 'g');
    if n <> (select count(*) from sri_os.fn_intercompany_pairs()) then
      raise exception 'สำเนาคู่บัญชีระหว่างกันใน % มี % คู่ แต่ของจริงมี % คู่ — สำเนาเพี้ยน',
        r.sig, n, (select count(*) from sri_os.fn_intercompany_pairs());
    end if;
  end loop;

  -- (ค) trigger ต้องผูกกับตารางจริง ครอบทั้ง insert และ update (ไม่ใช่สร้างฟังก์ชันทิ้งไว้)
  foreach v in array array['fn_assert_line_coa_in_rules', 'fn_assert_line_bank_is_cash'] loop
    if not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                    where tg.tgrelid = 'sri_os.transaction_lines'::regclass
                      and p.proname = v and not tg.tgisinternal
                      and (tg.tgtype & 1) <> 0 and (tg.tgtype & 2) <> 0
                      and (tg.tgtype & 4) <> 0 and (tg.tgtype & 16) <> 0) then
      raise exception 'ไม่มี trigger before insert or update for each row ที่เรียก % บน transaction_lines', v;
    end if;
  end loop;

  -- (ง) กฎเงินห้ามขึ้นกับสิทธิ์ · definer ต้องล็อก search_path · เรียกตรงไม่ได้
  select string_agg(p.proname, ', ') into v
    from pg_proc p
   where p.oid in ('sri_os.fn_assert_line_coa_in_rules()'::regprocedure,
                   'sri_os.fn_assert_line_bank_is_cash()'::regprocedure)
     and (p.prosrc ~* 'fn_can'
       or not p.prosecdef
       or not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c
                       where c in ('search_path=', 'search_path=""', 'search_path=sri_os'))
       or has_function_privilege('public', p.oid, 'execute')
       or has_function_privilege('anon', p.oid, 'execute')
       or has_function_privilege('authenticated', p.oid, 'execute'));
  if v is not null then
    raise exception 'trigger function ของไฟล์นี้หลวมหรือหลวมผิดทาง (ต้อง secdef + search_path ล็อก + ไม่ถาม fn_can + เรียกตรงไม่ได้): %', v;
  end if;
  if has_function_privilege('public', 'sri_os.fn_intercompany_pairs()', 'execute')
     or has_function_privilege('anon', 'sri_os.fn_intercompany_pairs()', 'execute')
     or has_function_privilege('anon', 'sri_os.fn_intercompany_coa(text)', 'execute') then
    raise exception 'fn_intercompany_pairs/coa ยังเปิดให้ public/anon';
  end if;

  -- (จ) พิสูจน์ด้วยค่าจริงว่าฟังก์ชันคู่บัญชีตอบตรง ไม่ใช่แค่มีอยู่
  if sri_os.fn_intercompany_coa('loan')     is distinct from array['1310', '2310']
   or sri_os.fn_intercompany_coa('capital')  is distinct from array['1710', '3100']
   or sri_os.fn_intercompany_coa('dividend') is distinct from array['3200', '4410']
   or sri_os.fn_intercompany_coa('ไม่มีจริง') is not null then
    raise exception 'fn_intercompany_coa ตอบไม่ตรงกับ src/lib/rules/intercompany.ts';
  end if;

  -- (ฉ) บรรทัดเก่าที่ไม่ตรงกฎใหม่ — รายงาน ไม่ raise (แถวที่ post แล้วแก้ไม่ได้
  --     ต้อง reverse + ลงใหม่ · ถ้า raise ที่นี่ migrate ของจริงจะล้มเพราะประวัติ)
  select count(*) into n
    from sri_os.transaction_lines l
    join sri_os.transactions t on t.id = l.transaction_id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
    left join sri_os.txn_types ty on ty.code = t.txn_type_code
   where not (c.code = any (
           array_remove(array[ty.dr_coa_code, ty.cr_coa_code, ty.gain_coa_code,
                              ty.loss_coa_code, ty.interest_coa_code, ty.accrual_coa_code], null)
           || case when t.intercompany_nature is null then '{}'::text[]
                   else array['1100'] || coalesce(sri_os.fn_intercompany_coa(t.intercompany_nature), '{}'::text[]) end))
      or (l.bank_account_id is not null and c.code !~ '^11[0-9][0-9]$');
  if n > 0 then
    raise warning 'มีบรรทัดบัญชี % บรรทัดที่ลงไว้ก่อนไฟล์นี้และไม่ตรงกฎใหม่ — trigger ตรวจแต่แถวที่เขียนใหม่ (แถวที่ post แล้วแก้ไม่ได้ ต้อง reverse + ลงใหม่) · ไล่ดูด้วย fn_health_check ก่อนปิดงวด', n;
  end if;

  raise notice 'guard · ด่านคู่บัญชีตรงตารางกฎ (ข้อ 3) และ bank เฉพาะขาเงินสด (ข้อ 7) เป็น trigger บนตารางแล้ว · บัญชีระหว่างกันล็อกเป็นรหัสตรง · สำเนาคู่บัญชีสามที่ตรงกัน (% บรรทัดเก่าที่ไม่ตรงกฎ)',
    coalesce(n, 0);
end $$;
