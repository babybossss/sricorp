-- ============================================================
-- SRI OS · ด่านของค่าเผื่อหนี้สงสัยจะสูญ (1290) และการตัดหนี้สูญ — **บังคับที่ DB**
--
-- ย้อนกลับ (rollback):
--   drop trigger  if exists trg_lines_allowance_limits on sri_os.transaction_lines;
--   drop trigger  if exists trg_txn_allowance_limits   on sri_os.transactions;
--   drop function if exists sri_os.fn_allowance_guard();
--   drop function if exists sri_os.fn_txn_allowance_guard();
--   drop function if exists sri_os.fn_assert_allowance_limits(uuid);
--   -- ย้อนแล้ว **ไม่มีด่านเหลือเลย** ค่าเผื่อติดลบและเกินยอดลูกหนี้ได้ทันที
--   -- (เครื่องยนต์ฝั่ง TypeScript มองยอดสะสมในสมุดไม่เห็น จึงกันเรื่องนี้แทนไม่ได้)
--   -- ถ้าย้อนเพราะด่านกันของที่ถูก ให้แก้เกณฑ์ในฟังก์ชันนี้ ไม่ใช่ถอดด่าน
--
-- ------------------------------------------------------------
-- ทำไมต้องอยู่ที่ DB ไม่ใช่แค่ในเครื่องยนต์
-- ------------------------------------------------------------
-- ทั้งสามด่านตัดสินจาก **ยอดสะสมของผู้ถือในสมุด** ซึ่ง `buildPosting()` มองไม่เห็น
-- (มันเห็นแค่รายการที่กำลังจะลง) · เครื่องยนต์เช็คให้ไม่ได้เลย และถ้าเช็คได้ก็ยัง
-- ต้องมีที่นี่อยู่ดี เพราะ insert ตรงเข้าตาราง (PostgREST · service_role · psql ·
-- migration) เลี่ยงเครื่องยนต์ได้ทุกกรณี — เหตุผลเดียวกับ D-097/20261009000001
--
-- ------------------------------------------------------------
-- สามด่าน (ที่จริงเป็นอสมการสองข้อของยอดบัญชี 1290 ต่อผู้ถือ)
-- ------------------------------------------------------------
-- นิยาม (นับใบที่ status <> 'void' เท่านั้น):
--   allowance  = Σ(credit − debit) ของบัญชี 1290          ← contra-asset ยอดปกติอยู่ฝั่งเครดิต
--   receivable = Σ(debit − credit) ของบัญชี 1200+1210+1220
--
--   ด่าน 1 · allowance <= receivable
--     ค่าเผื่อมากกว่าลูกหนี้ = ลูกหนี้สุทธิติดลบ ซึ่งไม่มีความหมายทางบัญชี
--     (จะอ่านได้ว่า "ลูกค้าเป็นหนี้เราติดลบ" ทั้งที่ความหมายจริงคือเราตั้งสำรองเกินของจริง)
--
--   ด่าน 2 + 3 · allowance >= 0
--     **สองด่านนี้เป็นอสมการเดียวกัน** และนั่นถูกต้อง เพราะทั้งคู่คือการเอาค่าเผื่อออก:
--       ตัดหนี้สูญ   Dr 1290 / Cr ลูกหนี้  → ลด allowance
--       กลับค่าเผื่อ Dr 1290 / Cr 5920     → ลด allowance
--     เอาออกเกินกว่าที่ตั้งไว้ = ค่าเผื่อติดลบ = **สินทรัพย์ปลอม**
--       ตัดหนี้สูญเกินค่าเผื่อ → ลูกหนี้หายไปจากงบดุลโดยไม่มีค่าใช้จ่ายรับรู้เลย
--       กลับค่าเผื่อเกินที่ตั้ง → เครดิต 5920 ค้าง = ค่าใช้จ่ายติดลบ = รายได้จากอากาศ
--     ผล: ถ้าหนี้จริงมากกว่าค่าเผื่อ ผู้ใช้ **ต้อง** ไปตั้งค่าเผื่อเพิ่มที่หมวด
--     `adj.doubtful` ก่อน ซึ่งเป็นจุดที่ค่าใช้จ่าย (Dr 5920) โผล่อย่างชัดเจน
--     ไม่ใช่ซ่อนอยู่ในรายการตัด — นี่คือเจตนาของวิธีค่าเผื่อ
--
-- ไม่รวม "ค่าใช้จ่ายห้ามซ้ำ" ไว้ที่นี่: คู่บัญชีของหมวดตัดหนี้สูญ (Dr 1290 / Cr ลูกหนี้)
-- ถูกบังคับด้วย `trg_lines_rule_coa` (20261008000012) ที่อ่านจาก txn_types อยู่แล้ว
-- → ลง 5920 บนหมวด `adj.writeoff_*` ถูกปฏิเสธที่ด่านนั้น ไม่ต้องเขียนกฎที่สองที่นี่
--
-- ------------------------------------------------------------
-- ทำไมเป็น `constraint trigger ... deferrable initially deferred` ทั้งสองตัว
-- ------------------------------------------------------------
-- รายการตัดหนี้สูญลดทั้ง 1290 และลูกหนี้ **พร้อมกัน** · ถ้าด่านยิงทันทีต่อบรรทัด
-- บรรทัดแรก (Dr 1290) จะทำให้ allowance ลดลงก่อนที่ Cr ลูกหนี้จะเกิด แล้ว
-- ด่าน 1 (allowance <= receivable) ยังผ่าน แต่ **ลำดับการ insert กลับด้าน**
-- (Cr ลูกหนี้ มาก่อน) จะทำให้ receivable ลดก่อน แล้วด่าน 1 ล้มทั้งที่ใบนั้นถูกต้อง
-- → ด่านที่ผลลัพธ์ขึ้นกับลำดับการ insert คือด่านที่ปฏิเสธของที่ถูกแบบสุ่ม
-- เลื่อนไป commit = ตัดสินจาก **สภาพสุดท้าย** ซึ่งเป็นสิ่งเดียวที่มีความหมาย
--
-- ต้องยิงบน `transactions` ด้วย ไม่ใช่แค่ `transaction_lines`:
--   `update transactions set status = 'posted'` ของใบที่ void ไว้ (หรือ update owner_id)
--   เปลี่ยนยอดสะสมโดยไม่แตะบรรทัดเลย → ด่านที่ผูกแค่บรรทัดจะไม่ยิง
--
-- ------------------------------------------------------------
-- ขอบเขตที่ด่านนี้ **ไม่** ครอบ (เขียนไว้เพราะเคยอธิบายเกินจริง)
-- ------------------------------------------------------------
--   * เทียบเป็นยอดรวมต่อผู้ถือ **ไม่ใช่รายลูกหนี้** → ตั้งค่าเผื่อของลูกหนี้ ก.
--     แล้วเอาไปตัดหนี้ของลูกหนี้ ข. ยังทำได้ · ทำรายคนต้องมี contact_id บนบรรทัด
--     (วันนี้มีแค่ระดับหัวรายการ) และต้องตัดสินเรื่องลูกหนี้ที่ไม่ผูก contact ก่อน
--     → `requires: ["contact"]` ในตารางกฎทำให้มีข้อมูลเก็บไว้แล้ว รอรอบหน้า
--   * ไม่ได้บังคับว่าต้องตั้งค่าเผื่อก่อนเสมอ — ตั้งแล้วตัดในใบเดียวกัน (ธุรกรรมเดียว)
--     ผ่านได้ ซึ่งถูกต้อง เพราะสภาพสุดท้ายยังสมเหตุสมผลและค่าใช้จ่ายยังโผล่ครบ
--
-- idempotent: create or replace function · drop trigger if exists ก่อน create
-- ============================================================

set search_path = sri_os, public;

-- ------------------------------------------------------------
-- 0 · ของที่ไฟล์นี้พึ่ง ต้องมีอยู่จริงก่อน
--
--   ถ้าผังบัญชียังไม่มี 1290 ด่านด้านล่างจะคิดยอดได้ 0 ทุกครั้งแล้ว **ผ่านทุกเคส**
--   = ด่านที่ไม่ได้ตรวจอะไรเลยแต่ดูเหมือนติดตั้งแล้ว ซึ่งแย่กว่าไม่มีด่าน
--   → raise ให้ดังตอน migrate · แก้ด้วย `npm run sync:rules` แล้ว apply ไฟล์ seed ก่อน
-- ------------------------------------------------------------
do $do$
declare v text;
begin
  select string_agg(x.code, ', ' order by x.code) into v
    from (values ('1290'), ('1200'), ('1210'), ('1220'), ('5920')) as x(code)
   where not exists (select 1 from sri_os.chart_of_accounts c where c.code = x.code);
  if v is not null then
    raise exception 'ผังบัญชีใน DB ขาดรหัสที่ด่านค่าเผื่อต้องใช้: % — รัน npm run sync:rules แล้ว apply ไฟล์ seed_rules ก่อนไฟล์นี้ ไม่งั้นด่านจะคิดยอดได้ 0 แล้วผ่านทุกเคสเงียบๆ', v;
  end if;
end $do$;

-- ------------------------------------------------------------
-- 1 · ตรวจผู้ถือหนึ่งราย — แยกจาก trigger function ตามแพทเทิร์นของ
--     fn_assert_txn_cash_date / fn_assert_txn_balanced (เรียกจากรายงาน data health ได้)
--
-- security definer: ถ้าอ่านบรรทัดตามสิทธิ์ผู้เรียก คนที่มองบรรทัดของผู้ถือรายนั้น
--   ไม่เห็นจะได้ยอด 0 แล้ว **หลุดด่านไปเฉยๆ** (เหตุผลเดียวกับ fn_assert_line_writable)
-- ไม่เรียก fn_can เลย — กฎเงินปิดจากหน้า Settings ไม่ได้
-- ------------------------------------------------------------
create or replace function fn_assert_allowance_limits(p_owner uuid) returns void
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

  -- ไม่มีทั้งค่าเผื่อและลูกหนี้ = ไม่มีอะไรให้ตรวจ (ออกก่อนเพื่อไม่ต้องหาชื่อผู้ถือ)
  if v_allow = 0 and v_recv = 0 then return; end if;

  -- ชื่อผู้ถือใช้ `name_th` (ตาราง owners ไม่มีคอลัมน์ `name`) · หาไม่เจอให้ใช้ id
  -- เพื่อให้ข้อความยังชี้ตัวได้ ไม่ใช่เป็นค่าว่าง
  select o.name_th into v_name from sri_os.owners o where o.id = p_owner;
  v_name := coalesce(v_name, p_owner::text);

  -- ---------- ด่าน 2 + 3 · เอาค่าเผื่อออกเกินกว่าที่ตั้งไว้ ----------
  -- ต้องพูดก่อนด่าน 1 เพราะค่าเผื่อติดลบทำให้ด่าน 1 ผ่านเสมอ (ติดลบ <= ลูกหนี้)
  -- ถ้าด่าน 1 พูดก่อน เคสนี้จะเงียบ แล้วสินทรัพย์ปลอมจะลงสมุดได้
  if v_allow < 0 then
    raise exception 'ค่าเผื่อหนี้สงสัยจะสูญของ % ติดลบ (%) — ตัดหนี้สูญหรือกลับค่าเผื่อเกินกว่าค่าเผื่อคงเหลือ · ตัดหนี้สูญได้ไม่เกินค่าเผื่อที่ตั้งไว้ ถ้าหนี้จริงมากกว่า ต้องลง "ตั้งค่าเผื่อหนี้สงสัยจะสูญ" (Dr 5920) เพิ่มก่อน เพื่อให้ค่าใช้จ่ายโผล่ในงบกำไรขาดทุนอย่างชัดเจน ไม่ใช่ซ่อนอยู่ในรายการตัด · กลับค่าเผื่อเกินกว่าที่ตั้งไว้คือการสร้างรายได้จากอากาศ',
      v_name, v_allow;
  end if;

  -- ---------- ด่าน 1 · ค่าเผื่อห้ามเกินยอดลูกหนี้รวม ----------
  -- `v_allow > 0` ไม่ใช่การผ่อนด่าน แต่เป็นขอบเขตของมัน: ด่านนี้ตอบคำถามว่า
  -- "ค่าเผื่อที่ตั้งไว้มากกว่าหนี้ที่มีจริงหรือไม่" ซึ่งไม่มีความหมายเมื่อยังไม่มีค่าเผื่อ
  --
  -- ถ้าไม่มีเงื่อนไขนี้ ผู้ถือที่ลูกหนี้ **ติดลบ** (รับเงินมากกว่าที่ตั้งค้างไว้ เช่น
  -- รับชำระค้างรับด้วย inv.collect_rent โดยไม่เคยตั้งลูกหนี้ไว้ก่อน) จะมี v_recv < 0
  -- แล้ว 0 > v_recv เป็นจริง → **ทุกรายการถัดไปของผู้ถือรายนั้นถูกปฏิเสธ**
  -- ด้วยข้อความเรื่องค่าเผื่อ ทั้งที่ไม่เคยแตะค่าเผื่อเลย (วัดแล้วด้วย harness:
  -- zz_post_entry / zz_reverse_integrity / two-session แดงทั้งชุด)
  -- ลูกหนี้ติดลบเป็นปัญหาคนละเรื่อง ไฟล์นี้ไม่ใช่เจ้าของกฎนั้น
  if v_allow > 0 and v_allow > v_recv then
    raise exception 'ค่าเผื่อหนี้สงสัยจะสูญของ % (%) มากกว่ายอดลูกหนี้รวม 1200+1210+1220 (%) — ลูกหนี้สุทธิในงบดุลจะติดลบ ซึ่งไม่มีความหมายทางบัญชี · ตั้งค่าเผื่อได้ไม่เกินหนี้ที่มีอยู่จริง (ถ้าหนี้สูญไปแล้ว ให้ตัดหนี้สูญ ไม่ใช่ตั้งค่าเผื่อเพิ่ม)',
      v_name, v_allow, v_recv;
  end if;
end $fn$;

comment on function fn_assert_allowance_limits(uuid) is
  'ด่านของค่าเผื่อหนี้สงสัยจะสูญต่อผู้ถือหนึ่งราย · (1) ค่าเผื่อ 1290 ห้ามเกินลูกหนี้ 1200+1210+1220 (ลูกหนี้สุทธิติดลบ) · (2+3) ค่าเผื่อห้ามติดลบ = ตัดหนี้สูญ/กลับค่าเผื่อเกินค่าเผื่อคงเหลือ · นับเฉพาะใบที่ status <> void · อ่านยอดจาก DB เอง ไม่รับค่าจากผู้เรียก (เครื่องยนต์มองยอดสะสมไม่เห็น จึงกันแทนไม่ได้)';

-- ------------------------------------------------------------
-- 2 · trigger ฝั่งบรรทัด — ยิงเฉพาะบรรทัดที่แตะบัญชีค่าเผื่อ/ลูกหนี้
--
-- กรองที่ WHEN ไม่ได้ (ต้อง join หา code จาก coa_id) → กรองในฟังก์ชัน
-- ต้องดูทั้ง new และ old: ลบบรรทัด Cr 1200 ของใบเก่าทำให้ receivable โตขึ้น
--   ซึ่งไม่ทำให้ด่านล้ม แต่ลบบรรทัด Cr 1290 (ที่ตั้งค่าเผื่อไว้) ทำให้ค่าเผื่อหาย
--   และถ้ามีการตัดหนี้สูญอ้างค่าเผื่อนั้นอยู่ ค่าเผื่อจะติดลบ → ต้องยิง
-- ------------------------------------------------------------
create or replace function fn_allowance_guard() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_row    record := coalesce(new, old);
  v_owner  uuid;
  v_code   text;
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

  perform sri_os.fn_assert_allowance_limits(v_owner);
  return null;
end $fn$;

comment on function fn_allowance_guard() is
  'trigger function ฝั่งบรรทัดของด่านค่าเผื่อ · ต้องผูกเป็น constraint trigger (deferrable initially deferred) เพราะรายการตัดหนี้สูญลดทั้ง 1290 และลูกหนี้พร้อมกัน — ด่านที่ยิงทันทีจะให้ผลต่างกันตามลำดับการ insert ของบรรทัด';

drop trigger if exists trg_lines_allowance_limits on transaction_lines;
create constraint trigger trg_lines_allowance_limits
  after insert or update or delete on transaction_lines
  deferrable initially deferred
  for each row execute function fn_allowance_guard();

-- ------------------------------------------------------------
-- 3 · trigger ฝั่งหัวรายการ — เปลี่ยน status/owner_id เปลี่ยนยอดสะสมได้
--     โดยไม่แตะบรรทัดเลย (คืนสภาพใบที่ void ไว้ · ย้ายใบไปผู้ถืออื่น)
--     ยิงทั้งผู้ถือใหม่และผู้ถือเก่า เพราะการย้ายใบกระทบยอดของทั้งสองฝ่าย
-- ------------------------------------------------------------
create or replace function fn_txn_allowance_guard() returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  if new.owner_id is not null then perform sri_os.fn_assert_allowance_limits(new.owner_id); end if;
  if tg_op = 'UPDATE' and old.owner_id is distinct from new.owner_id then
    perform sri_os.fn_assert_allowance_limits(old.owner_id);
  end if;
  return null;
end $fn$;

comment on function fn_txn_allowance_guard() is
  'ด่านค่าเผื่อฝั่งหัวรายการ · จำเป็นเพราะ update transactions set status/owner_id เปลี่ยนยอดสะสมของผู้ถือโดยไม่แตะ transaction_lines → trigger ที่ผูกแค่บรรทัดจะไม่ยิงเลย';

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
revoke all on function fn_assert_allowance_limits(uuid) from public;
revoke all on function fn_allowance_guard()             from public;
revoke all on function fn_txn_allowance_guard()         from public;
do $do$
begin
  execute 'revoke all on function sri_os.fn_assert_allowance_limits(uuid) from anon, authenticated';
  execute 'revoke all on function sri_os.fn_allowance_guard()             from anon, authenticated';
  execute 'revoke all on function sri_os.fn_txn_allowance_guard()         from anon, authenticated';
end $do$;

-- ------------------------------------------------------------
-- 5 · guard ท้ายไฟล์ — ต้องดังตอน migrate ถ้าด่านไม่ได้ผูกตามที่ไฟล์นี้อ้าง
--     (ประวัติที่ขัดกฎใหม่เป็น warning: raise = migrate ของจริงล้มเพราะข้อมูลเก่า
--      ซึ่งแก้ด้วยไฟล์นี้ไม่ได้ ต้องตามแก้ด้วยมือตามเคส)
-- ------------------------------------------------------------
do $do$
declare
  v_type int; v_defer boolean; v_init boolean; v_con oid; v text; n int;
begin
  -- (ก) ทั้งสองด่านต้องเป็น constraint trigger ที่เลื่อนไว้ · AFTER
  foreach v in array array['transaction_lines|trg_lines_allowance_limits',
                           'transactions|trg_txn_allowance_limits'] loop
    select t.tgtype, t.tgdeferrable, t.tginitdeferred, t.tgconstraint
      into v_type, v_defer, v_init, v_con
      from pg_trigger t
     where t.tgrelid = ('sri_os.' || split_part(v, '|', 1))::regclass
       and t.tgname = split_part(v, '|', 2);
    if v_type is null then
      raise exception 'ไม่พบด่าน % — ค่าเผื่อติดลบและเกินยอดลูกหนี้ได้ทันที', v;
    end if;
    if not (v_defer and v_init and v_con <> 0) then
      raise exception 'ด่าน % ไม่ได้ผูกเป็น constraint trigger (deferrable initially deferred) — ผลของด่านจะขึ้นกับลำดับการ insert ของบรรทัด แล้วใบตัดหนี้สูญที่ถูกต้องจะถูกปฏิเสธแบบสุ่ม', v;
    end if;
    -- tgtype bit 1 = ROW · bit 2 = BEFORE (ต้องเป็น 0 คือ AFTER)
    if (v_type & 2) <> 0 then
      raise exception 'ด่าน % วางไว้ที่ BEFORE — ตอนนั้นบรรทัดของใบยังไม่ครบ ด่านจะตัดสินจากสภาพครึ่งๆ', v;
    end if;
  end loop;

  -- (ข) ประวัติที่ขัดกฎใหม่ — ถ้ามี ให้เห็นก่อนที่ผู้ใช้จะเจอตอนกดบันทึกใบถัดไป
  select count(*) into n
    from sri_os.owners o
   where (select coalesce(sum(case when c.code = '1290' then l.credit - l.debit else 0 end), 0)
            from sri_os.transactions t
            join sri_os.transaction_lines l on l.transaction_id = t.id
            join sri_os.chart_of_accounts c on c.id = l.coa_id
           where t.owner_id = o.id and t.status <> 'void') < 0;
  if n > 0 then
    raise warning 'มีผู้ถือ % รายที่ค่าเผื่อหนี้สงสัยจะสูญติดลบอยู่แล้วก่อนไฟล์นี้ — ด่านใหม่จะปฏิเสธรายการถัดไปของผู้ถือรายนั้นจนกว่าจะลงรายการตั้งค่าเผื่อเพิ่ม (ของเก่าแก้ด้วยไฟล์นี้ไม่ได้ ต้องลงรายการแก้ให้ถูก)', n;
  end if;

  raise notice 'ด่านค่าเผื่อพร้อมใช้ · 1290 ห้ามติดลบ และห้ามเกินลูกหนี้ 1200+1210+1220 ต่อผู้ถือ';
end $do$;
