-- ============================================================
-- SRI OS · **กลับด้านด่านเงินตรา** — เลิกตัดสินจากฟิลด์ที่ผู้เรียกเลือกได้
--
-- สามรอบที่ผ่านมา (0004 → 0005) ด่านถูกเขียนเป็น "อ่านฟิลด์บนขา 3410 แล้วตัดสิน"
-- และ **ทุกรอบมีวิธีแต่งฟิลด์นั้นให้ด่านมองไม่เห็น**:
--     ไม่ส่งสกุล → ส่งเป็น 'THB' → ส่ง amount_original = 0
-- นี่คือบทเรียน mace-windu ข้อ 2 ตรงตัว: *อย่าเชื่อฟิลด์ที่ผู้ใช้เว้นได้ —
-- ผู้ถือปลายทางต้องอ่านจากบัญชีเอง* · `transaction_lines.currency` บนขา 3410
-- เป็นค่าที่ **ผู้เรียกเลือกได้** ด่านทุกตัวที่อ่านค่านั้นจึงเอาชนะได้เสมอ
-- แก้รายละเอียดอีกสิบรอบก็จะมีรูปที่สิบเอ็ด
--
-- วัดก่อนแก้ (PG16 · 0004+0005 ครบ):
--   (1) ติดป้ายขา 3410 ว่า `'THB'` (shape ยอมเพราะ fx_rate = 1) แล้วแลกหมดโดย
--       ล้างแค่ก้อนที่ติดป้าย USD → **ผ่าน** · USD คงเหลือ 0 · **3410 ค้าง 5,100**
--       และกำไรที่รับรู้ 5,000 ทั้งที่ของจริง 10,100 (ต่ำกว่าจริง 5,100 = นับซ้ำ)
--   (2) ขา 3410 ที่ `amount_original = 0` **ลงยอดบาทเท่าไรก็ได้** ไม่มีอัตราไหน
--       รองรับ → บัญชี FCD จาก 373,650 เป็น **1,373,650** (+1,000,000) โดยจำนวน
--       เงินตราเท่าเดิม 10,100 USD = เงินสดโผล่จากอากาศรูปใหม่
--   (3) `dr 1100(บาท) / cr 3410(USD)` ใต้ `trf.fx_convert` → **ผ่าน** ·
--       บัญชีบาทจาก −308,650 เป็น **+56,350** (โผล่ 365,000) โดยไม่มีบรรทัด
--       เงินสดสกุลต่างประเทศในใบเลย (engine สร้างไม่ได้ แต่คำขอที่แก้เองยิงตรงได้)
--
-- ------------------------------------------------------------
-- **ด่านใหม่ตัดสินจากของที่ผู้เรียกเลือกไม่ได้ สองชั้น**
--
-- ชั้นที่ 1 · รูปร่าง — สกุลของใบ **อ่านจาก `bank_accounts.currency` ของบัญชีที่
--   บรรทัดเงินสดอ้างถึง** (ข้อมูลอ้างอิง ไม่ใช่ input) · ขา 3410 ไม่ได้ประกาศสกุล
--   ของตัวเองอีกแล้ว มันต้อง **ตรงกับสกุลที่ได้จากบัญชี** และถ้าใบนั้นไม่มีบรรทัด
--   เงินสดของบัญชีสกุลต่างประเทศเลย → ปฏิเสธ (ปิดเคส 1 และ 3)
--   กฎข้อนี้อยู่ **ที่เดียว** จึงให้เหตุผลเดียวกับทุกรูปที่แต่งมา (เทสต์ F17 ไล่ 4 รูป)
--
-- ชั้นที่ 2 · **invariant ไม่ใช่ pattern matching** (หลัก D-113: ยอดคงเหลือเป็น
--   ความจริงของบัญชี ไม่ใช่สิ่งที่เราตั้ง) — คำนวณใหม่จากสมุดทุกครั้ง:
--
--     ยอด 3410 ของผู้ถือ  ==  Σ ทุกสกุล ( ยอดบาทของบัญชีสกุลนั้น − กองต้นทุนของสกุลนั้น )
--
--   ทั้งสองข้างมาจากข้อมูลอ้างอิงและประวัติที่ลงแล้ว **ไม่สนป้ายสกุลบนบรรทัด 3410
--   แม้แต่นิดเดียว** → ติดป้ายอย่างไรก็หนีไม่ได้ (ปิดเคส 1 ที่ระดับยอด)
--   และการแปลงค่าต้องทำให้ยอดบาทของบัญชีนั้นเท่ากับ
--   **จำนวนเงินตราคงเหลือ × อัตราของวันนั้นในตารางอัตรา** พอดี → ยอดที่ถูกต้อง
--   มีได้ค่าเดียวและมาจากข้อมูลอ้างอิงทั้งหมด (ปิดเคส 2)
--
--   เทียบแบบ **คำนวณยอดใหม่ทั้งก้อน ไม่ใช่สะสมส่วนต่าง** → ความคลาดสะสมไม่ได้
--   (ยอมได้ 0.01 ซึ่งเป็นการปัดของการหารเฉลี่ยครั้งเดียว · ถ้าเพี้ยนเกินนั้น
--    ใบถัดไปจับได้ทันทีเพราะเทียบกับยอดที่คำนวณใหม่เสมอ)
--   และ **เงินตราออกหมด ⇒ ทั้งยอดบาทของบัญชีนั้นและ 3410 ต้องเป็นศูนย์พอดี**
--
-- ------------------------------------------------------------
-- **ไม่แก้ไฟล์ 0004/0005 ที่อยู่ใน commit แล้ว** — เขียนทับสองฟังก์ชันด้วยไฟล์นี้
--   (`fn_assert_line_fx` · `fn_assert_fx_unrealized_cleared_for`) และ **ย้าย**
--   กฎของขา 3410 ออกจากด่านระดับบรรทัดมาอยู่ด่านระดับใบที่เห็นทุกบรรทัดแล้ว
--   (ด่านระดับบรรทัดเห็นแค่แถวตัวเอง จึงรู้สกุลของใบไม่ได้ ต้องเดา = แพ้ทุกครั้ง)
--   trigger ของเดิมทั้งสองตัวใช้ต่อ ไม่สร้างด่านตัวที่สาม (กฎเดียว ที่เดียว)
--
-- ลำดับ: **ต้องรันหลัง 20261025000005_fcd_guard_fixes.sql** · ก่อน
--   `20261020000003_replay_end_state_guard.sql` → วางต่อท้าย 0005
--
-- idempotent: create or replace function เท่านั้น (ไม่มี DDL ของ schema)
-- ย้อนกลับ (rollback): รัน 20261025000005_fcd_guard_fixes.sql ซ้ำทั้งไฟล์
--   แล้ว `drop function if exists sri_os.fn_fx_position(uuid, text),
--   sri_os.fn_fx_required_unrealised(uuid), sri_os.fn_fx_entry_currency(uuid);`
--   ย้อนแล้วได้สภาพเดิมคือ **ติดป้ายสกุลบนขา 3410 แล้วนับกำไรซ้ำได้** — ไม่แนะนำ
-- ============================================================

set search_path = sri_os, public;

-- ============================================================
-- 0 · pre-flight
-- ============================================================
do $$
begin
  if to_regprocedure('sri_os.fn_assert_line_fx()') is null
     or to_regprocedure('sri_os.fn_assert_fx_unrealized_cleared_for(uuid)') is null
     or to_regprocedure('sri_os.fn_bank_account_currency(uuid)') is null then
    raise exception 'ไฟล์นี้เขียนทับด่านของ 20261025000004/0005 ซึ่งยังไม่มีในฐานข้อมูล — ต้องรันหลังสองไฟล์นั้น (ลงทะเบียนลำดับใน supabase/migration-order.txt และ UNDER_TEST ของ scripts/test-rls-local.sh)';
  end if;
  if to_regprocedure('sri_os.fn_assert_line_fx()') is not null
     and pg_get_functiondef('sri_os.fn_assert_line_fx()'::regprocedure) !~ 'เป็นบัญชี\*\*บาท\*\*' then
    raise exception 'fn_assert_line_fx ในฐานข้อมูลไม่ใช่รุ่นของ 20261025000005 — ลำดับ migration ไม่ถูก';
  end if;
end $$;

-- ============================================================
-- 1 · สกุลเงินของ "ใบ" — อ่านจากบัญชีที่บรรทัดเงินสดอ้างถึง
--
-- `bank_accounts.currency` เป็น **ข้อมูลอ้างอิง** ที่ผู้เรียกใบนี้เลือกไม่ได้
-- (จะเปลี่ยนต้องไปแก้ทะเบียนบัญชี ซึ่งมีด่าน/สิทธิ์ของตัวเองและเห็นในประวัติ)
-- ต่างจาก `transaction_lines.currency` ที่ผู้เรียกพิมพ์อะไรมาก็ได้
-- ============================================================
create or replace function fn_fx_entry_currency(p_txn uuid) returns text
language plpgsql stable security definer set search_path = '' as $fn$
declare v_list text[];
begin
  select coalesce(array_agg(distinct b.currency), '{}') into v_list
    from sri_os.transaction_lines l
    join sri_os.bank_accounts b on b.id = l.bank_account_id
   where l.transaction_id = p_txn and b.currency <> 'THB';

  if array_length(v_list, 1) is null then
    return null;
  end if;
  if array_length(v_list, 1) > 1 then
    raise exception 'ใบเดียวแตะเงินตราสองสกุลพร้อมกัน (%) — ยังไม่รองรับ เพราะผลต่างอัตราแลกเปลี่ยนของแต่ละสกุลต้องแยกกองกัน · ให้แลกเป็นบาทก่อนแล้วซื้อสกุลใหม่เป็นอีกใบ',
      array_to_string(v_list, ' + ');
  end if;
  return v_list[1];
end $fn$;

comment on function fn_fx_entry_currency(uuid) is
  'สกุลเงินของใบนี้ อ่านจาก bank_accounts.currency ของบัญชีที่บรรทัดเงินสดอ้างถึง (**ข้อมูลอ้างอิง ผู้เรียกเลือกไม่ได้**) ไม่ใช่จาก transaction_lines.currency ที่ผู้เรียกพิมพ์อะไรมาก็ได้ · null = ใบนี้ไม่แตะบัญชีสกุลต่างประเทศเลย';

revoke all on function fn_fx_entry_currency(uuid) from public;
do $$ begin execute 'revoke all on function sri_os.fn_fx_entry_currency(uuid) from anon, authenticated'; end $$;

-- ============================================================
-- 2 · ฐานะเงินตราของผู้ถือต่อสกุล — **คำนวณใหม่จากสมุดทุกครั้ง**
--
--   units = จำนวนเงินตราคงเหลือ · thb = ยอดบาทตามสมุดของบัญชีสกุลนั้น
--   cost  = กองต้นทุนแบบ **ถัวเฉลี่ย** (หลักเดียวกับ D-112 ของทรัพย์)
--
-- บรรทัดที่ `amount_original = 0` คือ **การแปลงค่า** → ขยับยอดบาท ไม่ขยับกอง
-- ใบที่เงินตราเข้าเท่าออกในสกุลเดียวกัน (ย้ายที่อยู่ระหว่างบัญชีตัวเอง) ไม่แตะกอง
--   ถ้านับ จะกลายเป็น "ขายแล้วซื้อคืน" ทำให้กองต้นทุนเด้งไปตามอัตราของวันย้าย
--   แล้วด่าน invariant จะปฏิเสธการย้ายบัญชีที่ถูกต้อง (กันแน่นเกิน · บทเรียนข้อ 7)
--
-- อ่านจาก `v_ledger_posted` เท่านั้น (D-098 — ฟังก์ชันรายงานห้ามอ่านตารางสมุดตรงๆ)
-- ============================================================
create or replace function fn_fx_position(p_owner uuid, p_ccy text)
returns table (units numeric, thb numeric, cost numeric)
language plpgsql stable security definer set search_path = '' as $fn$
declare
  r       record;
  v_units numeric := 0;
  v_thb   numeric := 0;
  v_cost  numeric := 0;
  v_reloc uuid[];
begin
  select coalesce(array_agg(x.transaction_id), '{}') into v_reloc
    from (
      select v.transaction_id,
             sum(case when v.debit > 0 then coalesce(v.amount_original, 0) else 0 end) as in_u,
             sum(case when v.credit > 0 then coalesce(v.amount_original, 0) else 0 end) as out_u
        from sri_os.v_ledger_posted v
        join sri_os.bank_accounts b on b.id = v.bank_account_id
       where v.owner_id = p_owner and b.currency = p_ccy
       group by v.transaction_id
    ) x
   where x.in_u > 0 and x.out_u > 0 and x.in_u = x.out_u;

  for r in
    select v.debit, v.credit, coalesce(v.amount_original, 0) as ao, v.transaction_id
      from sri_os.v_ledger_posted v
      join sri_os.bank_accounts b on b.id = v.bank_account_id
     where v.owner_id = p_owner and b.currency = p_ccy
     -- เรียงตามเวลาจริงของเงิน แล้วจึงตามลำดับที่บันทึก — ต้นทุนถัวเฉลี่ยขึ้นกับลำดับ
     order by coalesce(v.cash_date, v.doc_date), v.created_at, v.line_id
  loop
    v_thb := v_thb + r.debit - r.credit;
    if r.ao = 0 or r.transaction_id = any (v_reloc) then
      continue;
    end if;
    if r.debit > 0 then
      v_units := v_units + r.ao;
      v_cost := v_cost + r.debit;
    elsif round(r.ao, 6) >= round(v_units, 6) then
      -- ออกหมด (หรือมากกว่าที่มี ซึ่งด่านข้างล่างปฏิเสธ) → กองต้นทุนเป็นศูนย์พอดี
      -- ไม่เหลือเศษค้าง จึงไม่มีส่วนเกินทุนลอยอยู่หลังขายหมด
      v_units := v_units - r.ao;
      v_cost := 0;
    else
      v_cost := round(v_cost - (v_cost / v_units) * r.ao, 2);
      v_units := v_units - r.ao;
    end if;
  end loop;

  return query select round(v_units, 6), round(v_thb, 2), round(v_cost, 2);
end $fn$;

comment on function fn_fx_position(uuid, text) is
  'ฐานะเงินตราของผู้ถือต่อสกุล คำนวณใหม่จากสมุด (v_ledger_posted) ทุกครั้ง: จำนวนเงินตราคงเหลือ · ยอดบาทตามสมุด · กองต้นทุนถัวเฉลี่ย (D-112) · สกุลมาจาก bank_accounts.currency ไม่ใช่จากสกุลที่บรรทัดประกาศ';

revoke all on function fn_fx_position(uuid, text) from public;
do $$ begin execute 'revoke all on function sri_os.fn_fx_position(uuid, text) from anon, authenticated'; end $$;

-- ยอดผลต่างที่ "ควรเป็น" ของผู้ถือหนึ่งคน รวมทุกสกุล (ไม่สนป้ายบนบรรทัด 3410)
create or replace function fn_fx_required_unrealised(p_owner uuid) returns numeric
language sql stable security definer set search_path = '' as $fn$
  select coalesce(sum(p.thb - p.cost), 0)
    from (select distinct b.currency as ccy
            from sri_os.bank_accounts b
           where b.owner_id = p_owner and b.currency <> 'THB') c
    cross join lateral sri_os.fn_fx_position(p_owner, c.ccy) p;
$fn$;

comment on function fn_fx_required_unrealised(uuid) is
  'ผลต่างอัตราแลกเปลี่ยนที่ยังไม่เกิดขึ้นจริงซึ่ง **ควร** ค้างอยู่ใน 3410 ของผู้ถือนี้ = Σ ทุกสกุล (ยอดบาทของบัญชีสกุลนั้น − กองต้นทุนของสกุลนั้น) · ที่มาเป็นข้อมูลอ้างอิง + ประวัติที่ลงแล้ว ไม่ใช่ค่าที่ผู้เรียกส่งมา';

revoke all on function fn_fx_required_unrealised(uuid) from public;
do $$ begin execute 'revoke all on function sri_os.fn_fx_required_unrealised(uuid) from anon, authenticated'; end $$;

-- ============================================================
-- 3 · ด่านระดับบรรทัด — **ถอดกฎของขา 3410 ออก** (ย้ายไปด่านระดับใบ)
--
-- ด่านระดับบรรทัดเห็นแค่แถวของตัวเอง จึงไม่มีทางรู้สกุลของใบ → ที่ผ่านมามันต้อง
-- "เชื่อสกุลที่บรรทัดประกาศ" ซึ่งคือรูที่ถูกเจาะสามรอบ · ที่นี่เหลือแต่กฎที่
-- ตัดสินได้จากของจริงของแถวนั้นเอง (บัญชีธนาคารที่อ้างถึง + ตารางอัตรา)
-- ============================================================
create or replace function fn_assert_line_fx() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_code       text;
  v_bank_ccy   text;
  v_label      text;
  v_thb        numeric;
  v_expected   numeric;
  v_type       text;
  v_is_xlate   boolean := false;
  v_table_rate numeric;
begin
  select c.code into v_code
    from sri_os.chart_of_accounts c where c.id = new.coa_id;
  if v_code is null then
    return new;
  end if;

  v_thb := coalesce(new.debit, 0) + coalesce(new.credit, 0);

  select t.txn_type_code into v_type
    from sri_os.transactions t where t.id = new.transaction_id;
  if v_type is not null then
    select exists (select 1 from sri_os.txn_types ty
                    where ty.code = v_type and '3410' in (ty.dr_coa_code, ty.cr_coa_code))
      into v_is_xlate;
  end if;

  -- ---------- (1) ขาเงินสด: ความจริงอยู่ที่ `bank_accounts.currency` ----------
  if new.bank_account_id is not null then
    v_bank_ccy := sri_os.fn_bank_account_currency(new.bank_account_id);
    select b.display_name into v_label
      from sri_os.bank_accounts b where b.id = new.bank_account_id;

    -- การแปลงค่าทำได้เฉพาะบัญชีที่ไม่ใช่บาท (ยอดบาทของบัญชีบาทไม่ขยับตามอัตรา)
    if v_is_xlate then
      if v_bank_ccy is null or v_bank_ccy = 'THB' then
        raise exception 'แปลงค่าอัตราแลกเปลี่ยนบนบัญชี "%" ไม่ได้ เพราะเป็นบัญชี**บาท** — ยอดบาทของบัญชีบาทไม่เปลี่ยนตามอัตราแลกเปลี่ยน · การแปลงค่าทำได้เฉพาะบัญชีเงินฝากสกุลต่างประเทศ (bank_accounts.currency <> THB) ไม่งั้นเท่ากับสร้างเงินสดขึ้นมาจากอากาศ และยอดนั้นจะไปซ่อนอยู่ในบรรทัดผลกระทบอัตราแลกเปลี่ยนของงบกระแสเงินสด',
          coalesce(v_label, new.bank_account_id::text);
      end if;
      if new.currency is null then
        raise exception 'บรรทัดเงินสดของใบแปลงค่าต้องระบุสกุลเงิน อัตรา และวันของอัตราให้ครบ (บัญชี "%") — ยอดบาทที่ไม่มีอัตรากำกับตรวจย้อนไม่ได้ว่ามาจากไหน',
          coalesce(v_label, new.bank_account_id::text);
      end if;
    end if;

    if v_bank_ccy is not null and v_bank_ccy <> 'THB' then
      if new.currency is null then
        raise exception 'บัญชี "%" เป็นบัญชีสกุล % — บรรทัดนี้ต้องระบุสกุลเงิน ยอดในสกุลเดิม อัตราแลกเปลี่ยน และวันของอัตราให้ครบ · **ลงเป็นบาทเฉยๆ ไม่ได้** เพราะยอดบาทจะกลายเป็นตัวเลขที่ไม่มีใครรู้ว่ามาจากอัตราไหน และระบบจะนับเงินตราเป็นบาททั้งก้อน (ยอดเงินสดในงบผิดทั้งงวด)',
          coalesce(v_label, new.bank_account_id::text), v_bank_ccy;
      end if;
      if new.currency <> v_bank_ccy then
        raise exception 'บรรทัดนี้ลงบัญชี "%" ซึ่งเป็นสกุล % แต่ระบุสกุล % — สกุลของบรรทัดต้องเป็นสกุลของบัญชีที่เงินเข้าออกจริง',
          coalesce(v_label, new.bank_account_id::text), v_bank_ccy, new.currency;
      end if;
    elsif v_bank_ccy = 'THB' and new.currency is not null then
      raise exception 'บัญชี "%" เป็นบัญชีบาท แต่บรรทัดนี้แนบข้อมูลอัตราแลกเปลี่ยนมา (สกุล %) — ข้อมูลอัตราที่ติดมากับบรรทัดบาทจะทำให้รายงานสกุลเงินนับยอดนี้เป็นเงินตรา',
        coalesce(v_label, new.bank_account_id::text), new.currency;
    end if;
  end if;

  /**
   * **ไม่มีกฎของขา 3410 ที่นี่อีกแล้ว** (เคยอยู่ที่นี่ใน 0005)
   *
   * ที่นี่รู้แค่แถวตัวเอง จึงตัดสินได้แค่ "บรรทัดนี้ประกาศสกุลอะไร" ซึ่งเป็นค่าที่
   * ผู้เรียกเลือกได้ → ด่านที่อ่านค่านั้นแพ้ทุกรอบ (ไม่ส่ง → 'THB' → ao = 0)
   * กฎของขา 3410 ย้ายไป `fn_assert_fx_unrealized_cleared_for()` ซึ่งเห็นทุกบรรทัด
   * ของใบแล้ว จึงเทียบกับ **สกุลที่ได้จากบัญชี** ได้ · อยู่ที่เดียวจึงให้เหตุผล
   * เดียวกันกับทุกรูปที่แต่งมา
   */

  if new.currency is null then
    return new;   -- บรรทัดบาทตรงๆ → ไม่มีอะไรต้องตรวจต่อ (ของเดิมทุกใบมาทางนี้)
  end if;

  -- ---------- (2) อัตราต้องเท่ากับอัตราที่ประกาศไว้ของวันนั้น ----------
  select f.thb_per_unit into v_table_rate
    from sri_os.fx_rates f
   where f.currency = new.currency and f.rate_date = new.fx_rate_date;
  if v_table_rate is not null and new.fx_rate <> v_table_rate then
    raise exception 'อัตราในบรรทัดนี้ (%) ไม่เท่ากับอัตราในตารางอัตราแลกเปลี่ยนของ % วันที่ % (ประกาศไว้ %) — อัตราที่ใช้ลงบัญชีต้องเป็นอัตราที่ประกาศไว้ ไม่ใช่ตัวเลขที่พิมพ์เอง · ถ้าอัตราที่ใช้จริงต่างจากนี้ (เช่นเรทที่ธนาคารให้ตอนแลก) ให้บันทึกอัตรานั้นลงตารางอัตราของวันนั้นก่อน แล้วอ้างวันนั้น',
      new.fx_rate, new.currency, new.fx_rate_date, v_table_rate;
  end if;

  -- ---------- (3) มีเงินตราเคลื่อน → ยอดบาทต้องมาจากอัตรา **พอดี** ----------
  if new.amount_original > 0 then
    v_expected := round(new.amount_original * new.fx_rate, 2);
    if round(v_thb, 2) <> v_expected then
      raise exception 'ยอดบาทของบรรทัดนี้ (%) ไม่เท่ากับ ยอดสกุลเดิม % × อัตรา % = % พอดี — ยอดบาทต้องมาจากอัตราที่บันทึกไว้ ไม่ใช่ตัวเลขที่พิมพ์แยกกัน (ไม่ยอมเศษแม้สตางค์เดียว เพราะใบที่มีหลายบรรทัดจะสะสมส่วนต่างได้เรื่อยๆ)',
        round(v_thb, 2), new.amount_original, new.fx_rate, v_expected;
    end if;
    return new;
  end if;

  -- ---------- (4) ไม่มีเงินตราเคลื่อนแต่มียอดบาท = บรรทัดแปลงค่า/ล้างผลต่าง ----------
  -- **ยอดที่ลงได้จริงถูกตัดสินที่ด่านระดับใบ** (ต้องเท่ากับ เงินตราคงเหลือ × อัตรา)
  if v_thb <> 0 and not (v_code = '3410' or v_is_xlate) then
    raise exception 'บรรทัดนี้ไม่มียอดเงินตราเคลื่อน (amount_original = 0) แต่มียอดบาท % — บรรทัดแบบนี้คือ **การแปลงค่า** ซึ่งลงได้เฉพาะหมวดแปลงค่าเงินฝากสกุลต่างประเทศ หรือบรรทัดผลต่างอัตราแลกเปลี่ยน (3410) ของใบแลกเงินจริง · หมวด "%" ไม่ใช่ทั้งสองอย่าง',
      round(v_thb, 2), coalesce(v_type, '(ไม่มีหัวรายการ)');
  end if;

  -- ---------- (5) บรรทัดที่ไม่ใช่เงินสด: แนบสกุลได้เฉพาะขาผลต่าง 3410 ----------
  if new.bank_account_id is null and v_code <> '3410' then
    raise exception 'บรรทัดบัญชี % แนบข้อมูลสกุลเงินมา แต่ไม่ใช่ขาเงินสดของบัญชีสกุลต่างประเทศ และไม่ใช่ขาผลต่างอัตราแลกเปลี่ยน (3410) — ข้อมูลสกุลเงินบนบรรทัดอื่นจะทำให้รายงานยอดเงินตรานับซ้ำ',
      v_code;
  end if;

  return new;
end $fn$;

comment on function fn_assert_line_fx() is
  'FCD · ด่านระดับบรรทัด ตัดสินจากของจริงของแถวนั้นเอง: สกุลต้องตรงกับ bank_accounts.currency ของบัญชีที่อ้างถึง · แปลงค่าได้เฉพาะบัญชีที่ไม่ใช่บาท · อัตราต้องเท่ากับ fx_rates ของวันนั้น · ยอดบาท = round(ยอดสกุลเดิม × อัตรา, 2) พอดี · **กฎของขา 3410 ไม่อยู่ที่นี่** เพราะที่นี่เห็นแค่แถวตัวเอง จึงต้องเชื่อสกุลที่บรรทัดประกาศ (ค่าที่ผู้เรียกเลือกได้) → ย้ายไปด่านระดับใบ';

revoke all on function fn_assert_line_fx() from public;
do $$ begin execute 'revoke all on function sri_os.fn_assert_line_fx() from anon, authenticated'; end $$;

-- ============================================================
-- 4 · ด่านระดับใบ — รูปร่าง + **invariant**
--
-- ชื่อฟังก์ชันเดิม เพราะ trigger ของ 20261025000004 ผูกไว้แล้ว และกฎค่าเงิน
-- ทั้งหมดควรอยู่ **ที่เดียว** (ด่านตัวที่สามคือกฎเดียวกันเขียนสองที่ · บทเรียนข้อ 5)
-- ============================================================
create or replace function fn_assert_fx_unrealized_cleared_for(p_txn uuid) returns void
language plpgsql security definer set search_path = '' as $fn$
declare
  v_owner    uuid;
  v_ccy      text;
  v_has_3410 boolean;
  v_bad      record;
  r          record;
  v_units    numeric;
  v_thb      numeric;
  v_cost     numeric;
  v_actual   numeric;
  v_required numeric;
begin
  select t.owner_id into v_owner
    from sri_os.transactions t where t.id = p_txn;
  if v_owner is null then
    return;
  end if;

  select exists (select 1
                   from sri_os.transaction_lines l
                   join sri_os.chart_of_accounts c on c.id = l.coa_id
                  where l.transaction_id = p_txn and c.code = '3410')
    into v_has_3410;

  -- สกุลของใบนี้ **จากบัญชีที่บรรทัดเงินสดอ้างถึง** (ผู้เรียกเลือกไม่ได้)
  v_ccy := sri_os.fn_fx_entry_currency(p_txn);

  -- ใบที่ไม่แตะเงินตราและไม่แตะ 3410 เลย → จบ (ของเดิมทุกใบมาทางนี้)
  if v_ccy is null and not v_has_3410 then
    return;
  end if;

  /**
   * ---------- (ก) รูปร่างของขาผลต่าง 3410 ----------
   *
   * **เหตุผลเดียวสำหรับทุกรูปที่แต่งมา** (ไม่ส่งสกุล · ติดป้ายบาท · ติดป้ายสกุลอื่น ·
   * อ้างว่ามีเงินตราเคลื่อนบนขาทุน · ไม่มีบรรทัดเงินสดสกุลต่างประเทศในใบเลย)
   * เพราะกฎอยู่ที่เดียวและตัดสินจากสกุลที่ได้จากบัญชี ไม่ใช่จากค่าที่ส่งมา
   */
  if v_has_3410 then
    if v_ccy is null then
      raise exception 'ขาผลต่างอัตราแลกเปลี่ยน (3410) ตัดสินจากสกุลของบัญชีเงินสดในใบนี้ ไม่ใช่จากค่าที่ส่งมาในบรรทัด — ใบนี้**ไม่มีบรรทัดเงินสดของบัญชีสกุลต่างประเทศเลย** จึงไม่มีผลต่างอัตราแลกเปลี่ยนให้ลง · ยอดบาทที่ลงคู่กับขานี้คือเงินสดที่โผล่มาโดยไม่มีเงินตราเคลื่อนไหวรองรับ';
    end if;
    for v_bad in
      select l.id, l.currency, l.amount_original, l.fx_rate, l.fx_rate_date,
             coalesce(l.debit, 0) + coalesce(l.credit, 0) as thb
        from sri_os.transaction_lines l
        join sri_os.chart_of_accounts c on c.id = l.coa_id
       where l.transaction_id = p_txn and c.code = '3410'
         and (l.currency is distinct from v_ccy
              or coalesce(l.amount_original, -1) <> 0
              or l.fx_rate is null or l.fx_rate_date is null)
    loop
      raise exception 'ขาผลต่างอัตราแลกเปลี่ยน (3410) ตัดสินจากสกุลของบัญชีเงินสดในใบนี้ ไม่ใช่จากค่าที่ส่งมาในบรรทัด — ใบนี้เป็นเงินตราสกุล % แต่ขานี้ส่งสกุล "%" · ยอดในสกุลเดิม % (ต้องเป็น 0 เพราะเงินตราไม่ได้เคลื่อนที่ขาทุน) · ต้องระบุอัตราและวันของอัตราด้วย',
        v_ccy, coalesce(v_bad.currency, '(ไม่ส่ง)'), coalesce(v_bad.amount_original::text, '(ไม่ส่ง)');
    end loop;
  end if;

  /**
   * ---------- (ข) การแปลงค่ามี "ยอดที่ถูกต้อง" ได้ค่าเดียว ----------
   *
   * ยอดบาทของบัญชีนั้นหลังใบนี้ ต้องเท่ากับ
   *     **จำนวนเงินตราคงเหลือ × อัตราของวันนั้นในตารางอัตรา**  พอดี
   * ทั้งสองตัวเป็นข้อมูลอ้างอิง/ประวัติ → ผู้เรียกกำหนดยอดเองไม่ได้
   * (ก่อนแก้: ลง 1,000,000 ก็ได้ ทั้งที่จำนวนเงินตราเท่าเดิม = เงินสดจากอากาศ)
   */
  for r in
    select l.bank_account_id, l.fx_rate, b.display_name, b.currency
      from sri_os.transaction_lines l
      join sri_os.bank_accounts b on b.id = l.bank_account_id
     where l.transaction_id = p_txn
       and b.currency <> 'THB'
       and coalesce(l.amount_original, -1) = 0
  loop
    select coalesce(sum(case when v.debit > 0 then v.amount_original else -v.amount_original end), 0),
           coalesce(sum(v.debit - v.credit), 0)
      into v_units, v_thb
      from sri_os.v_ledger_posted v
     where v.bank_account_id = r.bank_account_id;

    if round(v_thb, 2) <> round(v_units * r.fx_rate, 2) then
      raise exception 'แปลงค่าบัญชี "%" แล้วยอดบาทต้องเท่ากับ **จำนวนเงินตราคงเหลือ** % % × อัตรา % = % พอดี แต่หลังใบนี้เป็น % — ยอดการแปลงค่ามีค่าที่ถูกต้องได้ค่าเดียว และมาจากจำนวนเงินตราในสมุดกับอัตราที่ประกาศไว้ ไม่ใช่ยอดที่ส่งมาในบรรทัด (ยอดที่ไม่มีอัตรารองรับคือเงินสดที่โผล่มาจากอากาศ)',
        r.display_name, round(v_units, 6), r.currency, r.fx_rate,
        round(v_units * r.fx_rate, 2), round(v_thb, 2);
    end if;
  end loop;

  /**
   * ---------- (ค) invariant ของยอดคงเหลือ (D-113) ----------
   *
   *   ยอด 3410 ของผู้ถือ == Σ ทุกสกุล (ยอดบาทของบัญชีสกุลนั้น − กองต้นทุนของสกุลนั้น)
   *
   * **ไม่อ่านป้ายสกุลบนบรรทัด 3410 เลย** → ติดป้ายอย่างไรก็หนีด่านนี้ไม่ได้
   * และเพราะคำนวณยอดใหม่ทั้งก้อนทุกครั้ง ความคลาดจึงสะสมไม่ได้
   * (ยอม 0.01 = การปัดของการหารเฉลี่ยครั้งเดียว · เกินกว่านั้นใบถัดไปจับได้ทันที)
   */
  select coalesce(sum(v.credit - v.debit), 0) into v_actual
    from sri_os.v_ledger_posted v
    join sri_os.chart_of_accounts c on c.id = v.coa_id
   where v.owner_id = v_owner and c.code = '3410';
  v_required := sri_os.fn_fx_required_unrealised(v_owner);

  if abs(round(v_actual - v_required, 2)) > 0.01 then
    raise exception 'ผลต่างอัตราแลกเปลี่ยนที่ค้างอยู่ในส่วนของเจ้าของ (3410) ของผู้ถือนี้เป็น % บาท แต่ยอดที่คำนวณใหม่จากสมุดบอกว่าต้องเป็น % บาท (= ยอดบาทของบัญชีเงินตรา − กองต้นทุนถัวเฉลี่ยของเงินตราที่ยังถืออยู่) — ส่วนต่าง % บาท · **เงินตราออกหมดแล้วต้องเหลือศูนย์พอดี** · ด่านนี้คำนวณจากบัญชีและประวัติที่ลงแล้ว ไม่ได้อ่านสกุลที่บรรทัด 3410 ประกาศ จึงติดป้ายสกุลให้ด่านมองไม่เห็นไม่ได้ · สาเหตุที่พบบ่อย: แลกเงินออกแล้วไม่ล้างผลต่างออกให้ครบตามสัดส่วน (กำไรจะถูกนับซ้ำ) หรือลงยอดผลต่างที่ไม่มีอัตรารองรับ',
      round(v_actual, 2), round(v_required, 2), round(v_actual - v_required, 2);
  end if;

  -- ---------- (ง) เงินตราติดลบไม่ได้ · ออกหมดแล้วยอดบาทของบัญชีนั้นต้องเป็นศูนย์ ----------
  for r in
    select distinct b.currency as ccy
      from sri_os.bank_accounts b
     where b.owner_id = v_owner and b.currency <> 'THB'
  loop
    select p.units, p.thb into v_units, v_thb from sri_os.fn_fx_position(v_owner, r.ccy) p;
    if round(v_units, 6) < 0 then
      raise exception 'ยอดเงินตราสกุล % ของผู้ถือนี้ติดลบ (%) — จ่ายเงินตราออกมากกว่าที่มีอยู่ในบัญชีไม่ได้ · ถ้ามีเงินเข้าที่ยังไม่ได้ลง ต้องลงใบนั้นก่อน',
        r.ccy, round(v_units, 6);
    end if;
    if round(v_units, 6) = 0 and round(v_thb, 2) <> 0 then
      raise exception 'เงินตราสกุล % ของผู้ถือนี้ออกหมดแล้ว (คงเหลือ 0) แต่บัญชีสกุลนั้นยังมียอดบาทค้างอยู่ % บาท — ต้องเหลือศูนย์พอดีทั้งจำนวนเงินตราและยอดบาท · ยอดบาทที่ค้างแปลว่าตัดเงินตราออกด้วยอัตราที่ไม่ใช่ยอดตามบัญชี (ต้องแปลงค่าให้เป็นอัตราของวันที่แลกก่อน แล้วจึงแลก)',
        r.ccy, round(v_thb, 2);
    end if;
  end loop;
end $fn$;

comment on function fn_assert_fx_unrealized_cleared_for(uuid) is
  'FCD · ด่านระดับใบ **ตัดสินจากของที่ผู้เรียกเลือกไม่ได้**: (ก) ขา 3410 ต้องตรงกับสกุลที่ได้จาก bank_accounts.currency ของบรรทัดเงินสดในใบ และใบที่ไม่มีบรรทัดเงินสดสกุลต่างประเทศเลย ลง 3410 ไม่ได้ (เหตุผลเดียวสำหรับทุกรูปที่แต่งมา) · (ข) การแปลงค่าต้องทำให้ยอดบาท = จำนวนเงินตราคงเหลือ × อัตราในตาราง พอดี · (ค) **invariant**: ยอด 3410 ของผู้ถือ = Σ (ยอดบาทของบัญชีสกุลนั้น − กองต้นทุนถัวเฉลี่ย) คำนวณใหม่ทุกครั้ง ไม่อ่านป้ายสกุลบนบรรทัด · (ง) เงินตราติดลบไม่ได้ และออกหมดแล้วต้องเหลือศูนย์พอดีทั้งสองฝั่ง';

revoke all on function fn_assert_fx_unrealized_cleared_for(uuid) from public;
do $$ begin execute 'revoke all on function sri_os.fn_assert_fx_unrealized_cleared_for(uuid) from anon, authenticated'; end $$;

-- ============================================================
-- 5 · guard ท้ายไฟล์ — ดังตอน migrate ไม่ใช่ตอนผู้ใช้กดบันทึก
-- ============================================================
do $$
declare v text; n int; v_owner uuid;
begin
  -- (ก) ด่านต้องเป็นรุ่นที่ตัดสินจากบัญชี ไม่ใช่จากป้ายบนบรรทัด
  v := pg_get_functiondef('sri_os.fn_assert_fx_unrealized_cleared_for(uuid)'::regprocedure);
  if v !~ 'fn_fx_entry_currency' or v !~ 'fn_fx_required_unrealised' then
    raise exception 'ด่านระดับใบไม่ได้ตัดสินจากสกุลที่ได้จากบัญชี/ยอดที่คำนวณใหม่ — มีไฟล์อื่นเขียนทับหลังไฟล์นี้';
  end if;
  if v ~ 'v\.currency = v_ccy' then
    raise exception 'ด่านระดับใบกลับไปกรองด้วยสกุลที่บรรทัดประกาศอีกแล้ว — ติดป้าย THB แล้วหนีด่านได้ (ผู้ตรวจวัดได้ 3410 ค้าง 5,100 · กำไรต่ำกว่าจริง 5,100)';
  end if;

  v := pg_get_functiondef('sri_os.fn_assert_line_fx()'::regprocedure);
  if v ~ 'ต้องระบุสกุลเงินของผลต่างก้อนนี้' then
    raise exception 'ด่านระดับบรรทัดยังตัดสินกฎของขา 3410 อยู่ — กฎเดียวต้องอยู่ที่เดียว (ด่านระดับบรรทัดเห็นแค่แถวตัวเอง จึงต้องเชื่อค่าที่ผู้เรียกส่งมา)';
  end if;
  if v !~ 'เป็นบัญชี\*\*บาท\*\*' then
    raise exception 'ด่านระดับบรรทัดไม่กันการแปลงค่าบนบัญชีบาทอีกแล้ว';
  end if;

  -- (ข) trigger ต้องยังผูกอยู่
  select string_agg(x.want, ', ') into v
    from (values ('trg_lines_fx_shape'), ('trg_assert_fx_unrealized_cleared')) x(want)
   where not exists (select 1 from pg_trigger g
                      where g.tgrelid = 'sri_os.transaction_lines'::regclass
                        and g.tgname = x.want and not g.tgisinternal);
  if v is not null then
    raise exception 'trigger หายไปจาก transaction_lines: %', v;
  end if;

  -- (ค) ฟังก์ชันด่าน/ฟังก์ชันคำนวณต้องเรียกตรงไม่ได้ (D-089)
  select string_agg(x.f, ', ') into v
    from unnest(array['sri_os.fn_assert_line_fx()',
                      'sri_os.fn_assert_fx_unrealized_cleared_for(uuid)',
                      'sri_os.fn_fx_entry_currency(uuid)',
                      'sri_os.fn_fx_position(uuid, text)',
                      'sri_os.fn_fx_required_unrealised(uuid)']) x(f)
   where has_function_privilege('authenticated', x.f, 'execute')
      or has_function_privilege('anon', x.f, 'execute');
  if v is not null then
    raise exception 'ฟังก์ชันด่านยังเรียกตรงได้: % = ทางข้าม policy ของสมุดเงิน', v;
  end if;

  -- (ง) ของที่อยู่ในสมุดแล้วต้องไม่ละเมิด invariant ใหม่ (ถ้ามี ต้องรู้ตอน migrate)
  n := 0;
  for v_owner in
    select distinct b.owner_id from sri_os.bank_accounts b where b.currency <> 'THB'
  loop
    if abs(round(
         coalesce((select sum(v2.credit - v2.debit)
                     from sri_os.v_ledger_posted v2
                     join sri_os.chart_of_accounts c on c.id = v2.coa_id
                    where v2.owner_id = v_owner and c.code = '3410'), 0)
         - sri_os.fn_fx_required_unrealised(v_owner), 2)) > 0.01 then
      n := n + 1;
      raise warning 'ผู้ถือ % มียอด 3410 ไม่ตรงกับยอดที่คำนวณใหม่จากสมุด — ต้องกลับรายการใบที่ผิดแล้วลงใหม่ (ห้ามแก้แถวตรงๆ · กฎเหล็กข้อ 1)', v_owner;
    end if;
  end loop;
  if n > 0 then
    raise exception 'มีผู้ถือ % รายที่ยอด 3410 ในสมุดไม่ตรงกับความจริงที่คำนวณใหม่ได้ — ด่านใหม่จะปฏิเสธใบถัดไปของผู้ถือเหล่านี้ทันที ต้องแก้ด้วยใบกลับรายการก่อน', n;
  end if;

  raise notice 'ด่านเงินตรากลับด้านแล้ว: สกุลมาจาก bank_accounts.currency ของบรรทัดเงินสด · ยอดการแปลงค่ามีค่าที่ถูกต้องได้ค่าเดียว · ยอด 3410 ของผู้ถือถูกเทียบกับยอดที่คำนวณใหม่จากสมุดทุกใบ (ไม่อ่านป้ายสกุลบนบรรทัด)';
end $$;
