-- ============================================================
-- SRI OS · ความสมบูรณ์ของกลไกกลับรายการ (reverse) — ปิดสามรูของ D-097
--
-- D-097 ตัดสินว่า `void` กับ `reverse` เป็นสองกลไกที่ใช้ต่างสถานการณ์ ห้ามปนกัน
--   void   = งวดยังไม่ปิด · ต้นฉบับ → void (ไม่นับในงบ) · **ไม่มี** ใบกลับรายการ
--   reverse = งวดปิดแล้ว/ยื่นงบไปแล้ว · ต้นฉบับยัง posted (นับต่อไป) ·
--             มีใบกลับรายการวันที่ปัจจุบัน สถานะ posted · ต้นฉบับ + ใบกลับ = 0
--
-- ทำอะไร (สามด่าน · ทั้งหมด create or replace / drop ... if exists → **รันซ้ำได้**):
--
--   1 · ใบกลับรายการต้องสะท้อนบรรทัดของต้นฉบับแบบสลับด้าน
--       เดิม fn_reverse_link_ok ตรวจแค่ "ลิงก์" ไม่ตรวจบรรทัดเลย และ corporate_strict
--       **ยกเว้นหลักฐาน** ให้ใบที่อ้างว่า reverse → ตั้ง source='reverse' ชี้ใบจริงใบเล็ก
--       แล้วลงเงินเท่าไหร่ก็ได้โดยไม่ต้องแนบหลักฐาน = override กติกาที่ห้าม override
--       → fn_assert_reverse_mirrors() เทียบ **multiset** ของบรรทัด
--         (coa_id · bank_account_id · asset_id · cf_category + สลับ debit/credit)
--         memo ไม่ต้องตรงกัน — ใบกลับรายการควรเขียนเหตุผลของตัวเองได้
--
--       **ต้องเป็น constraint trigger deferrable initially deferred**
--       วางที่ before insert ไม่ได้เด็ดขาด: ตอน insert หัวรายการ บรรทัดยังไม่เกิด
--       (เส้นทางที่ถูกต้องคือหัวรายการ + บรรทัดในธุรกรรมฐานข้อมูลเดียวกัน · ดู 20261007000000)
--       และ **อ่านบรรทัดของต้นฉบับจาก DB มาเทียบเอง** ไม่รับค่าอะไรจากผู้เรียก
--       (บทเรียนที่แพงที่สุดของโปรเจกต์นี้: ด่านที่ "รับมาตามที่เครื่องยนต์ส่งให้"
--        ไม่ได้ตรวจอะไรเลย)
--
--       เทียบด้วย `except all` **สองทิศ** เพราะทิศเดียว (orig except all rev) จับ
--       "บรรทัดเกินที่สมดุลในตัวเอง" ไม่ได้ · และ except all ถือว่า NULL เท่ากับ NULL
--       จึงปลอดภัยกับ bank_account_id / asset_id / cf_category ที่เว้นว่างได้
--
--   2 · void กับ reverse ปนกันไม่ได้ (กันสองทิศ)
--       ถ้าต้นฉบับ void (ไม่นับ) แต่ใบกลับรายการยัง posted (นับ) → สมุด**ผิดไป −ต้นฉบับ**
--       (ก) ลงใบกลับรายการที่ชี้ไปต้นฉบับที่ status='void' ไม่ได้
--           → เติมใน fn_reverse_link_ok เพราะทำให้**ข้อยกเว้นหลักฐานแน่นขึ้นด้วย**
--             (ใบที่อ้างกลับรายการของใบที่ไม่นับในงบ ไม่ใช่หลักฐานของอะไร)
--           **การตรวจบรรทัดห้ามย้ายเข้ามาในฟังก์ชันนี้** — มันเป็น stable sql ที่ถูกเรียก
--           จากทั้งด่านลิงก์และข้อยกเว้นหลักฐาน · มีเทสต์โครงสร้างยืนยัน (R0ค)
--       (ข) void ต้นฉบับที่มีใบกลับรายการ status <> 'void' ชี้มาไม่ได้
--           → trigger แยกบน update ของ transactions
--           (ยังเปิดทางให้ void ใบกลับรายการที่ลงผิดแล้วกลับรายการใหม่ได้ ไม่ใช่ทางตัน)
--
--   3 · void รายการในงวดที่ปิดแล้วไม่ได้ (เฉพาะ corporate_strict)
--       trg_period_locked ของ 20260917000002 เป็น `before insert` เท่านั้น
--       → UPDATE เป็น void ผ่านฉลุย = งบเดือนที่ยื่นสรรพากร/สำนักงานบัญชีไปแล้ว
--       เปลี่ยนเงียบๆ ซึ่งทำลายเหตุผลทั้งหมดของการปิดงวด
--       ใช้เกณฑ์เดียวกับ fn_period_locked (period_closes + date_trunc('month', doc_date))
--       และบังคับกับ corporate_strict ตาม Entity Policy เดิม — **ฝั่ง personal_flexible
--       ยังยืดหยุ่นได้ ไฟล์นี้ไม่เปลี่ยนนโยบายนั้น**
--       (UPDATE อื่นของ corporate ถูก fn_corporate_immutable ปฏิเสธอยู่แล้ว
--        เส้นทางที่เหลือเปิดอยู่จริงคือ "เปลี่ยนเป็น void" เท่านั้น จึงกันตรงจุดนั้น)
--
-- ทำไมเป็น trigger ไม่ใช่ RLS / ไม่ใช่ด่านใน fn_post_entry:
--   policy เขียนทับ RLS ได้ (permissive OR กัน) และ PostgREST เขียนตรงเข้าตารางได้
--   โดยไม่ผ่าน RPC · trigger บังคับทุกเส้นทางทุก role เท่ากัน รวม super_admin
--   **ไม่มีตัวไหนเรียก fn_can()** — กฎเงินปิดจากหน้า Settings ไม่ได้
--
-- ย้อนกลับ (rollback):
--   -- drop trigger  if exists trg_reverse_mirrors_original on sri_os.transactions;
--   -- drop trigger  if exists trg_void_blocked_by_reverse  on sri_os.transactions;
--   -- drop trigger  if exists trg_period_locked_on_void    on sri_os.transactions;
--   -- drop function if exists sri_os.fn_assert_reverse_mirrors();
--   -- drop function if exists sri_os.fn_void_blocked_by_reverse();
--   -- drop function if exists sri_os.fn_period_locked_on_void();
--   -- คืน fn_reverse_link_ok() + fn_assert_reverse_link() รุ่นก่อนหน้า:
--   --   รัน 20261007000000_line_integrity_and_view_rls.sql ซ้ำ
--   --   (ย้อนแล้วเปิดรูที่ 2(ก) คืน: ลงใบกลับรายการทับต้นฉบับที่ void แล้วได้ → ไม่แนะนำ)
--   ย้อนทั้งไฟล์ไม่แตะข้อมูลเดิมเลย (ไม่มี DML ในไฟล์นี้)
--   ถ้าย้อนเพราะด่านกันของที่ถูกต้อง: แก้ที่ใบกลับรายการให้สะท้อนต้นฉบับ ไม่ใช่ย้อนด่าน
--
-- ของเก่าที่ลงไว้ก่อนไฟล์นี้: trigger ตรวจแต่แถวที่เขียน/แก้ใหม่ (by design)
--   guard ท้ายไฟล์จึง **รายงานจำนวนใบกลับรายการเก่าที่ไม่สะท้อนต้นฉบับ** ด้วย warning
--   ไม่ใช่ raise (raise = migrate ของจริงล้มเพราะประวัติ ซึ่งแก้ด้วยไฟล์นี้ไม่ได้)
--
-- idempotent: create or replace · drop trigger if exists ก่อน create · revoke/grant ซ้ำได้
-- ============================================================

set search_path = sri_os, public;

-- ------------------------------------------------------------
-- 1 · รูที่ 2(ก) — ต้นฉบับที่ถูก void แล้ว กลับรายการไม่ได้
--
-- แหล่งความจริงเดียวของเงื่อนไข "เป็นการกลับรายการที่พิสูจน์ได้" (ใช้สองที่เรียก:
--   trg_assert_reverse_link และข้อยกเว้นหลักฐานของ corporate_strict)
--   1. reverses_id ไม่เป็น null
--   2. ไม่ชี้ตัวเอง
--   3. ชี้ไปรายการที่มีอยู่จริง
--   4. ของผู้ถือเดียวกัน (1 txn = 1 owner · กลับรายการข้ามสมุดไม่ได้)
--   5. **ต้นฉบับยังไม่ถูก void** ← ใหม่รอบนี้ (D-097 ข้อ 2)
--   6. ยังไม่มีใบกลับรายการตัวอื่นที่ยังไม่ถูก void ชี้ไปที่เดียวกัน
--      นับเฉพาะตัวที่ยัง**ไม่ void** เพราะถ้านับตัวที่ void แล้วด้วย ใบกลับรายการที่
--      ลงผิดแล้ว void ทิ้งจะทำให้ต้นฉบับกลับรายการไม่ได้อีกตลอดไป (ทางตัน)
--      ส่วนการนับซ้ำต้องมีตัวที่ยังมีผลอยู่สองตัว ซึ่งยังถูกบล็อก
--
-- **ไม่ตรวจบรรทัดในนี้** (ด่านบรรทัดคือ fn_assert_reverse_mirrors ข้อ 2)
--   ฟังก์ชันนี้ต้องเบาและตอบคำถามเดียว: "ลิงก์นี้เป็นการกลับรายการที่พิสูจน์ได้ไหม"
--
-- security definer ด้วยเหตุผลเดิม: ถ้าอ่านตามสิทธิ์ผู้เรียก คนที่มองต้นฉบับไม่เห็น
--   จะทำให้ข้อ 3 เป็นเท็จ (ปฏิเสธรายการที่ถูกต้อง) และข้อ 6 เป็นจริงเสมอ (หลุดการกันซ้ำ)
-- ------------------------------------------------------------
create or replace function fn_reverse_link_ok(p_id uuid, p_owner uuid, p_reverses uuid)
returns boolean
language sql stable security definer set search_path = '' as $fn$
  select p_reverses is not null
     and p_reverses is distinct from p_id
     and exists (
           select 1 from sri_os.transactions t
            where t.id = p_reverses
              and t.owner_id = p_owner
              -- D-097 ข้อ 2: ต้นฉบับที่ void แล้วไม่นับในงบ · ใบกลับรายการที่ยังนับอยู่
              -- จะทำให้สมุดผิดไป −ต้นฉบับ (ผิดเท่าตัวของยอดเดิม)
              and t.status::text <> 'void'
         )
     and not exists (
           select 1 from sri_os.transactions t
            where t.reverses_id = p_reverses
              and t.id is distinct from p_id
              and t.status::text <> 'void'
         );
$fn$;

comment on function fn_reverse_link_ok(uuid, uuid, uuid) is
  'รายการนี้เป็นการกลับรายการที่พิสูจน์ได้หรือไม่ (ลิงก์เท่านั้น ไม่ตรวจบรรทัด) · แหล่งความจริงเดียวของเงื่อนไข ใช้ทั้งที่ trigger ตรวจ reverses_id และที่ยกเว้นหลักฐานของ corporate_strict · D-097: ต้นฉบับต้องยังไม่ถูก void';

-- ข้อความต้องบอกเหตุผลที่เพิ่มเข้ามาด้วย ไม่งั้นคนอ่าน error แล้วไม่รู้ว่าทำไมถูกปฏิเสธ
create or replace function fn_assert_reverse_link() returns trigger
language plpgsql set search_path = sri_os, public as $fn$
begin
  if new.source = 'reverse' or new.reverses_id is not null then
    if not fn_reverse_link_ok(new.id, new.owner_id, new.reverses_id) then
      raise exception 'รายการกลับรายการต้องชี้ไปรายการจริงของผู้ถือเดียวกัน ที่ยังไม่ถูก void และยังไม่ถูกกลับรายการ (source % · reverses_id %) · ถ้าต้นฉบับถูก void ไปแล้ว มันไม่ถูกนับในงบอยู่แล้ว การลงใบกลับรายการทับจะทำให้สมุดผิดไปเท่ายอดต้นฉบับ (D-097)',
        new.source, coalesce(new.reverses_id::text, 'null');
    end if;
  end if;
  return new;
end $fn$;

-- ชื่อขึ้นต้นด้วย a เพื่อให้ยิงก่อน trg_corporate_evidence (trigger เรียงตามชื่อ)
drop trigger if exists trg_assert_reverse_link on transactions;
create trigger trg_assert_reverse_link
  before insert or update on transactions
  for each row execute function fn_assert_reverse_link();

-- ------------------------------------------------------------
-- 2 · รูที่ 1 — ใบกลับรายการต้องสะท้อนบรรทัดของต้นฉบับแบบสลับด้าน
--
-- เทียบ multiset สองทิศด้วย except all:
--   ภาพกลับด้านของต้นฉบับ (expected) = บรรทัดต้นฉบับที่สลับ debit ↔ credit
--   expected except all actual = "บรรทัดที่ขาด"  (ลงไม่ครบ / ยอดไม่ตรง / ด้านไม่สลับ)
--   actual except all expected = "บรรทัดที่เกิน" (ยัดบรรทัดเพิ่ม แม้จะสมดุลในตัวเอง)
--   ทิศเดียวไม่พอ: ใบที่สะท้อนครบ + บรรทัดเกินคู่หนึ่งที่สมดุลในตัวเอง จะผ่านทิศแรกหมด
--
-- ไม่เทียบ memo โดยตั้งใจ — ใบกลับรายการควรเขียนเหตุผลของตัวเองได้
-- ไม่เทียบ doc_date/cash_date — ใบกลับรายการลงวันที่ปัจจุบัน (นั่นคือจุดประสงค์ของมัน)
-- ------------------------------------------------------------
create or replace function fn_assert_reverse_mirrors() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_missing text;
  v_extra   text;
  v_orig_dr numeric;
  v_rev_dr  numeric;
begin
  -- ใบที่ไม่ได้อ้างว่าเป็นการกลับรายการ ไม่ใช่เรื่องของด่านนี้
  if new.source::text <> 'reverse' and new.reverses_id is null then
    return null;
  end if;

  -- ลิงก์ที่ใช้ไม่ได้ (null / ชี้ตัวเอง / ชี้ของไม่มีจริง / ข้ามผู้ถือ / ซ้ำ / ต้นฉบับ void)
  -- เป็นหน้าที่ของ fn_assert_reverse_link ซึ่งปฏิเสธไปก่อนหน้านี้แล้ว
  -- **ห้ามสร้างข้อความที่สองของกฎเดียวกัน** — ที่นี่แค่ไม่ต้องพูดต่อ
  if new.reverses_id is null
     or not exists (select 1 from sri_os.transactions t where t.id = new.reverses_id) then
    return null;
  end if;

  -- อ่านบรรทัดของ **ทั้งสองใบจาก DB เอง** ไม่รับค่าอะไรจากผู้เรียก
  select coalesce(sum(l.debit), 0) into v_orig_dr
    from sri_os.transaction_lines l where l.transaction_id = new.reverses_id;
  select coalesce(sum(l.debit), 0) into v_rev_dr
    from sri_os.transaction_lines l where l.transaction_id = new.id;

  with expected as (
    select l.coa_id, l.bank_account_id, l.asset_id, l.cf_category,
           l.credit as debit, l.debit as credit          -- ← สลับด้าน
      from sri_os.transaction_lines l
     where l.transaction_id = new.reverses_id
  ), actual as (
    select l.coa_id, l.bank_account_id, l.asset_id, l.cf_category,
           l.debit, l.credit
      from sri_os.transaction_lines l
     where l.transaction_id = new.id
  ), missing as (
    select * from expected
    except all
    select * from actual
  ), extra as (
    select * from actual
    except all
    select * from expected
  )
  select
    (select string_agg(z.d, ' · ') from (
       select format('%s %s %s%s%s%s',
                     coalesce(c.code, m.coa_id::text),
                     case when m.debit > 0 then 'Dr' else 'Cr' end,
                     to_char(greatest(m.debit, m.credit), 'FM9999999999990.00'),
                     coalesce(' [cf ' || m.cf_category::text || ']', ''),
                     coalesce(' [บัญชี ' || b.display_name || ']', ''),
                     coalesce(' [ทรัพย์ ' || m.asset_id::text || ']', '')) as d
         from missing m
         left join sri_os.chart_of_accounts c on c.id = m.coa_id
         left join sri_os.bank_accounts b     on b.id = m.bank_account_id) z),
    (select string_agg(z.d, ' · ') from (
       select format('%s %s %s%s%s%s',
                     coalesce(c.code, x.coa_id::text),
                     case when x.debit > 0 then 'Dr' else 'Cr' end,
                     to_char(greatest(x.debit, x.credit), 'FM9999999999990.00'),
                     coalesce(' [cf ' || x.cf_category::text || ']', ''),
                     coalesce(' [บัญชี ' || b.display_name || ']', ''),
                     coalesce(' [ทรัพย์ ' || x.asset_id::text || ']', '')) as d
         from extra x
         left join sri_os.chart_of_accounts c on c.id = x.coa_id
         left join sri_os.bank_accounts b     on b.id = x.bank_account_id) z)
    into v_missing, v_extra;

  if v_missing is not null or v_extra is not null then
    raise exception 'ใบกลับรายการต้องสะท้อนบรรทัดของต้นฉบับแบบสลับด้านทุกบรรทัด (ใบ % กลับรายการ %) · ยอดต้นฉบับ (เดบิตรวม) % · ยอดที่ลงมา % · บรรทัดที่ขาด: % · บรรทัดที่เกิน: % · เทียบรหัสบัญชี + บัญชีธนาคาร + ทรัพย์ + หมวดกระแสเงินสด และต้องสลับ debit/credit (memo ไม่ต้องตรงกัน) — ถ้าไม่สะท้อนตรงตัว ต้นฉบับ + ใบกลับรายการจะไม่หักกลบกันเป็นศูนย์ (D-097)',
      new.id, new.reverses_id,
      to_char(v_orig_dr, 'FM9999999999990.00'),
      to_char(v_rev_dr,  'FM9999999999990.00'),
      coalesce(v_missing, '(ไม่มี)'),
      coalesce(v_extra,   '(ไม่มี)');
  end if;

  return null;
end $fn$;

comment on function fn_assert_reverse_mirrors() is
  'D-097 ข้อ 1 · ใบกลับรายการต้องเป็นภาพกลับด้านของต้นฉบับแบบ multiset (coa/bank/asset/cf + สลับ dr-cr) · อ่านบรรทัดของต้นฉบับจาก DB เอง · except all สองทิศเพื่อจับบรรทัดเกินที่สมดุลในตัวเอง · ต้องเป็น constraint trigger ที่เลื่อนไว้เพราะตอน insert หัวรายการ บรรทัดยังไม่เกิด';

drop trigger if exists trg_reverse_mirrors_original on transactions;
create constraint trigger trg_reverse_mirrors_original
  after insert or update on transactions
  deferrable initially deferred
  for each row execute function fn_assert_reverse_mirrors();

-- ------------------------------------------------------------
-- 3 · รูที่ 2(ข) — void ต้นฉบับที่ยังมีใบกลับรายการที่นับอยู่ ไม่ได้
--
-- trigger ธรรมดา (ไม่เลื่อน) โดยตั้งใจ: ด่านนี้ไม่ต้องอ่านบรรทัด จึงตอบได้ทันที
--   และการตอบทันทีทำให้ข้อความชี้ตรงที่คำสั่งที่ผิด
--   ถ้าจะ void ทั้งคู่จริงๆ ให้ void ใบกลับรายการก่อน แล้วค่อย void ต้นฉบับ
--   (ลำดับนี้ปลอดภัยทุกจังหวะ ไม่มีช่วงไหนที่สมุดผิด)
--
-- บังคับกับ **ทุก owner** เพราะ "สมุดผิดไป −ต้นฉบับ" เป็น Money Invariant
--   ไม่ใช่กติกาเอกสารของนิติบุคคล (ฝั่งบุคคล override ได้แค่กติกาเอกสาร)
-- ------------------------------------------------------------
create or replace function fn_void_blocked_by_reverse() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare v_live text;
begin
  if new.status::text <> 'void' or old.status::text = 'void' then
    return new;
  end if;

  select string_agg(t.id::text, ', ') into v_live
    from sri_os.transactions t
   where t.reverses_id = old.id
     and t.id is distinct from old.id
     and t.status::text <> 'void';

  if v_live is not null then
    raise exception 'void รายการนี้ไม่ได้ เพราะมีใบกลับรายการที่ยังนับในงบชี้มาอยู่ (%) · ถ้าต้นฉบับไม่นับแต่ใบกลับรายการยังนับ สมุดจะผิดไปเท่ายอดต้นฉบับ · ถ้าใบกลับรายการลงผิดให้ void ใบกลับรายการก่อน แล้วค่อย void ต้นฉบับ (D-097)',
      v_live;
  end if;

  return new;
end $fn$;

comment on function fn_void_blocked_by_reverse() is
  'D-097 ข้อ 2 ทิศที่สอง · void ต้นฉบับที่มีใบกลับรายการ status <> void ชี้มาไม่ได้ (สมุดจะผิดไป −ต้นฉบับ) · บังคับทุก owner เพราะเป็น Money Invariant ไม่ใช่กติกาเอกสาร';

drop trigger if exists trg_void_blocked_by_reverse on transactions;
create trigger trg_void_blocked_by_reverse
  before update on transactions
  for each row execute function fn_void_blocked_by_reverse();

-- ------------------------------------------------------------
-- 4 · รูที่ 3 — void รายการในงวดที่ปิดแล้วไม่ได้ (corporate_strict)
--
-- fn_period_locked ของ 20260917000002 ผูกไว้ `before insert` เท่านั้น
--   → UPDATE เป็น void เปลี่ยนงบเดือนที่ยื่นไปแล้วเงียบๆ
-- ไม่แก้ fn_period_locked และไม่เพิ่มเหตุการณ์ให้ trg_period_locked เดิม เพราะ
--   ฟังก์ชันนั้นใช้ `new` ล้วน จึงแยก "เปลี่ยนเป็น void" ออกจาก UPDATE อื่นไม่ได้
--   และข้อความของมันพูดเรื่อง "ลงรายการย้อนหลัง" ซึ่งไม่ตรงกับสิ่งที่เกิดที่นี่
-- เกณฑ์งวดต้องเหมือนกันทุกตัวอักษร: period_closes + date_trunc('month', doc_date)
--
-- ใช้ doc_date ของ **แถวเดิม** (old) — เป็นงวดที่ตัวเลขถูกยื่นออกไปแล้ว
--   (corporate เปลี่ยน doc_date ไม่ได้อยู่แล้วตาม fn_corporate_immutable
--    ส่วน new.doc_date ที่เปลี่ยนไปงวดอื่นจะถูกปฏิเสธด้วยด่านนั้น ไม่ใช่ด่านนี้)
-- ------------------------------------------------------------
create or replace function fn_period_locked_on_void() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare v_policy text;
begin
  if new.status::text <> 'void' or old.status::text = 'void' then
    return new;
  end if;

  select o.policy::text into v_policy
    from sri_os.owners o where o.id = old.owner_id;
  if v_policy is distinct from 'corporate_strict' then
    return new;   -- personal_flexible ยังยืดหยุ่นได้ตาม Entity Policy เดิม
  end if;

  if exists (
    select 1 from sri_os.period_closes p
     where p.owner_id = old.owner_id
       and p.period = date_trunc('month', old.doc_date)::date
  ) then
    raise exception 'งวด % ปิดแล้ว · void รายการในงวดที่ปิดแล้วไม่ได้ (id %) · งบของงวดที่ยื่นออกไปแล้วต้องตรงกับสมุด ให้ลงใบกลับรายการ (source=reverse) ลงวันที่ในงวดปัจจุบันแทน (D-097)',
      to_char(old.doc_date, 'MM/YYYY'), old.id;
  end if;

  return new;
end $fn$;

comment on function fn_period_locked_on_void() is
  'D-097 ข้อ 3 · trg_period_locked เดิมเป็น before insert เท่านั้น → UPDATE เป็น void เปลี่ยนงบที่ยื่นไปแล้วเงียบๆ · บังคับกับ corporate_strict ตาม Entity Policy (ฝั่งบุคคลยังยืดหยุ่น)';

drop trigger if exists trg_period_locked_on_void on transactions;
create trigger trg_period_locked_on_void
  before update on transactions
  for each row execute function fn_period_locked_on_void();

-- ------------------------------------------------------------
-- 5 · สิทธิ์ของฟังก์ชันใหม่ — ปิดทุก role (กฎเงินห้ามเรียกเอง)
--   20261007000007 revoke เป็นชุดจาก pg_proc **ตอนที่มันรัน** → ฟังก์ชันที่เพิ่ม
--   หลังจากนั้นถือ ACL เริ่มต้นของ Postgres = PUBLIC EXECUTE ถ้าไม่ถอนที่นี่
--   (fn_reverse_link_ok ไม่ต้องแตะ — create or replace คง ACL เดิมไว้ และ
--    authenticated **ต้องเรียกได้** เพราะ trigger ที่เรียกมันไม่ใช่ security definer)
-- ------------------------------------------------------------
revoke all on function fn_assert_reverse_mirrors()  from public;
revoke all on function fn_void_blocked_by_reverse() from public;
revoke all on function fn_period_locked_on_void()   from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_assert_reverse_mirrors()  from anon, authenticated';
  execute 'revoke all on function sri_os.fn_void_blocked_by_reverse() from anon, authenticated';
  execute 'revoke all on function sri_os.fn_period_locked_on_void()   from anon, authenticated';
end $$;

-- ------------------------------------------------------------
-- 6 · guard ท้ายไฟล์ — ต้องดังตอน migrate ถ้าด่านไม่ได้ผูกตามที่ไฟล์นี้อ้าง
--   (ส่วนประวัติที่ไม่สะท้อนเป็น warning: raise = migrate ของจริงล้มเพราะข้อมูลเก่า
--    ซึ่งแก้ด้วยไฟล์นี้ไม่ได้ · ต้อง reverse/void ด้วยมือตามเคส)
-- ------------------------------------------------------------
do $$
declare n int; v text;
begin
  -- (ก) ด่านบรรทัดต้องเป็น constraint trigger ที่เลื่อนไว้จริง ไม่ใช่ before insert
  select count(*) into n from pg_trigger t
   where t.tgrelid = 'sri_os.transactions'::regclass
     and t.tgname = 'trg_reverse_mirrors_original'
     and t.tgdeferrable and t.tginitdeferred and t.tgconstraint <> 0
     and (t.tgtype & 2) = 0;
  if n <> 1 then
    raise exception 'ด่านสะท้อนบรรทัดไม่ได้ผูกเป็น constraint trigger (deferrable initially deferred, AFTER) — ถ้าวางที่ before insert บรรทัดยังไม่เกิด = ด่านที่ไม่ตรวจอะไรเลย';
  end if;

  -- (ข) สองด่านของ void ต้องผูกบน update
  select count(*) into n from pg_trigger t
   where t.tgrelid = 'sri_os.transactions'::regclass
     and t.tgname in ('trg_void_blocked_by_reverse', 'trg_period_locked_on_void')
     and (t.tgtype & 16) <> 0;
  if n <> 2 then
    raise exception 'ด่าน void (ใบกลับรายการ / งวดที่ปิดแล้ว) ไม่ได้ผูกบน UPDATE ครบสองตัว (เจอ %)', n;
  end if;

  -- (ค) ประวัติ: ใบกลับรายการเก่าที่ไม่สะท้อนต้นฉบับ (ทั้งสองทิศ)
  select count(*), string_agg(t.id::text, ', ') into n, v
    from sri_os.transactions t
   where t.reverses_id is not null
     and exists (select 1 from sri_os.transactions o where o.id = t.reverses_id)
     and (
       exists (
         select l.coa_id, l.bank_account_id, l.asset_id, l.cf_category, l.credit, l.debit
           from sri_os.transaction_lines l where l.transaction_id = t.reverses_id
         except all
         select l.coa_id, l.bank_account_id, l.asset_id, l.cf_category, l.debit, l.credit
           from sri_os.transaction_lines l where l.transaction_id = t.id
       )
       or exists (
         select l.coa_id, l.bank_account_id, l.asset_id, l.cf_category, l.debit, l.credit
           from sri_os.transaction_lines l where l.transaction_id = t.id
         except all
         select l.coa_id, l.bank_account_id, l.asset_id, l.cf_category, l.credit, l.debit
           from sri_os.transaction_lines l where l.transaction_id = t.reverses_id
       )
     );
  if n > 0 then
    raise warning 'มีใบกลับรายการเก่า % ใบที่บรรทัดไม่สะท้อนต้นฉบับ → ตัวเลขของใบพวกนี้ยังผิดอยู่ (ด่านใหม่ตรวจแต่แถวที่เขียนใหม่) · ต้องตามแก้ด้วยมือ: %', n, v;
  end if;

  -- (ง) ประวัติ: ต้นฉบับที่ void แล้วแต่ใบกลับรายการยังนับอยู่ = สมุดผิดไป −ต้นฉบับ
  select count(*), string_agg(o.id::text, ', ') into n, v
    from sri_os.transactions o
   where o.status::text = 'void'
     and exists (select 1 from sri_os.transactions t
                  where t.reverses_id = o.id and t.status::text <> 'void');
  if n > 0 then
    raise warning 'มีต้นฉบับ % ใบที่ถูก void ทั้งที่ใบกลับรายการยังนับในงบ → สมุดผิดไปเท่ายอดต้นฉบับของใบพวกนี้ (ด่านใหม่กันแต่รายการใหม่): %', n, v;
  end if;

  raise notice 'guard · ด่านสะท้อนบรรทัดเป็น constraint trigger ที่เลื่อนไว้ · ด่าน void (ใบกลับรายการ/งวดที่ปิดแล้ว) ผูกบน UPDATE ครบ · fn_reverse_link_ok ปฏิเสธต้นฉบับที่ void แล้ว';
end $$;
