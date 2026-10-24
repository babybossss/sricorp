-- ============================================================
-- SRI OS · เทสต์ด่านฝั่ง DB ของ ภาษีหัก ณ ที่จ่าย + หลายสกุลเงิน
--   (migration 20261024000001_wht_and_fx.sql · D-111 ข้อ 1 และ 2)
--
-- สิ่งที่ไฟล์นี้ต้องจับได้ (ไล่จาก "ถ้าถอดการแก้ออกแล้วต้องแดง"):
--   M1 ไม่มี fn_txn_type_can_withhold                 → W1 W4 แดง
--   M2 ไม่ขยาย fn_assert_line_coa_in_rules ให้รับ 1800 → W2 แดง (เส้นทางที่ถูกทำไม่ได้)
--   M3 ไม่ขยายให้รับ 3400 บนใบขาย                     → R5 แดง
--   M4 ไม่มี trg_assert_wht_gross                     → W3 W5 W6 แดง (รายได้สุทธิผ่านฉลุย)
--   M5 ไม่มี trg_lines_s_revaluation_no_pl            → R2 แดง
--   M6 fn_asset_cost_basis ยังนับใบตีราคาเป็นต้นทุน    → R3 แดง
--   M7 ไม่มี constraint ของ assets.currency / fx       → F1 F2 F3 แดง
--   M8 ลืม revoke execute / ไม่ล็อก search_path        → W0 แดง
--
-- **เคสที่สำคัญที่สุดคือ W3 และ R2** ทั้งคู่เป็นใบที่ **สมดุลทุกบรรทัด**
--   และผ่านด่านอื่นทั้งหมด — ถ้าสองด่านนี้ไม่ติด ตัวเลขผิดแบบเงียบเชียบ
--
-- R2 เป็นเทสต์แบบ **mutation**: แก้คู่บัญชีของหมวดตีราคาใน txn_types ให้ชี้บัญชี
--   รายได้ (ซึ่งทำให้ด่านคู่บัญชี *ยอมรับ* บรรทัดนั้น) แล้วดูว่า trigger ของการ
--   ตีราคายังปฏิเสธ · ถ้าไม่กลายพันธุ์ก่อน เคสจะถูกปฏิเสธด้วยด่านคนละตัว
--   แล้วเราจะไม่รู้เลยว่า trigger ตัวนี้กันอะไรได้ (= ด่านที่ไม่มีใครพิสูจน์)
--
-- **หมายเหตุเรื่อง deferred**: trg_assert_balanced กับ trg_assert_wht_gross เป็น
--   constraint trigger แบบ deferred ทั้งคู่ · ทุกเคสจึง `set constraints all deferred`
--   ก่อนลงบรรทัด แล้ว `set constraints all immediate` เพื่อ **บังคับให้ยิงตอนนี้**
--   ไม่ใช่ตอน commit (ซึ่งไฟล์นี้ rollback ทิ้ง → ด่านจะไม่เคยยิงเลยและเทสต์ผ่านฟรี)
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ **rollback** ปิดท้าย — ไม่ทิ้งรายการเงินไว้
-- และไม่ทิ้งตารางกฎที่ถูกกลายพันธุ์ใน R2 ไว้
-- ============================================================

\set ON_ERROR_STOP 1

begin;

-- ------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------
create temporary table t_uid (label text primary key, id uuid not null default gen_random_uuid());
insert into t_uid(label) values ('mgmt'), ('staff');
insert into auth.users(id) select id from t_uid;
insert into sri_os.app_users(id, email, display_name, role, is_active)
select u.id, u.label || '@whtfx.local', u.label, x.role, true
  from t_uid u join (values ('mgmt', 'management'), ('staff', 'staff')) x(label, role)
    on x.label = u.label;

create or replace function pg_temp.uid(p_label text) returns uuid
language sql stable as $fn$ select id from t_uid where label = p_label $fn$;

create or replace function pg_temp.login(p_label text) returns void
language sql as $fn$
  select set_config('test.uid', coalesce((select id::text from t_uid where label = p_label), ''), true);
$fn$;

insert into sri_os.user_owner_access(user_id, owner_id)
select pg_temp.uid('mgmt'), o.id from sri_os.owners o;

insert into sri_os.bank_accounts(id, owner_id, bank, account_name, display_name)
values ('00000000-0000-0000-0000-00000002b001',
        (select id from sri_os.owners where code = 'THANAKORN'),
        'BBL', 'ธนากร', 'ธนากร - BBL (WHT/FX)');

insert into sri_os.contacts(id, first_name, types)
values ('00000000-0000-0000-0000-00000002c001', 'ผู้เช่านิติบุคคล', array['tenant']);

-- ทรัพย์สองชิ้น: คอนโดให้เช่า (บาท) · หุ้นต่างประเทศ (USD)
insert into sri_os.assets(id, code, name, class_id, category_id, owner_id, currency)
select x.id, x.code, x.name, cat.class_id, cat.id,
       (select id from sri_os.owners where code = 'THANAKORN'), x.cur
  from (values
    ('00000000-0000-0000-0000-00000002a001'::uuid, 'WFX-RENT', 'คอนโดให้เช่า', 'THB'),
    ('00000000-0000-0000-0000-00000002a002'::uuid, 'WFX-STOCK', 'หุ้นต่างประเทศ', 'USD')
  ) as x(id, code, name, cur)
  cross join (select id, class_id from sri_os.asset_categories order by id limit 1) cat;

create or replace function pg_temp.coa(p_code text) returns uuid
language sql stable as $fn$ select id from sri_os.chart_of_accounts where code = p_code $fn$;

create or replace function pg_temp.must_fail_like(p_label text, p_sql text, p_needle text) returns void
language plpgsql as $fn$
declare v text;
begin
  begin
    execute p_sql;
  exception when others then
    v := sqlerrm;
    if v like 'FAIL:%' then raise; end if;
    if position(p_needle in v) = 0 then
      raise exception 'FAIL: % — ปฏิเสธถูกแต่ข้อความไม่มี "%" · ได้: %', p_label, p_needle, v;
    end if;
    return;
  end;
  raise exception 'FAIL: % — คำสั่งควรถูกปฏิเสธแต่สำเร็จ', p_label;
end $fn$;

create or replace function pg_temp.must_pass(p_label text, p_sql text) returns void
language plpgsql as $fn$
begin
  execute p_sql;
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise exception 'FAIL: % — เส้นทางที่ถูกต้องถูกปฏิเสธ (กันแน่นเกิน): %', p_label, sqlerrm;
end $fn$;

/**
 * หัวรายการ — ใส่ค่า wht_* ตอน INSERT เลย ไม่ UPDATE ทีหลัง
 * (รายการที่ post แล้วห้ามแก้ · กฎเหล็กข้อ 1 · และเราไม่อยากทดสอบด่านนั้นที่นี่)
 */
create or replace function pg_temp.mk_txn(p_id uuid, p_type text,
                                          p_rate numeric default null,
                                          p_amount numeric default null,
                                          p_cert text default null,
                                          p_cash_date date default '2026-10-31') returns uuid
language plpgsql as $fn$
begin
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, cash_date, memo,
                                  attachments, contact_id,
                                  wht_rate, wht_amount, wht_certificate_no)
  select p_id, o.id, p_type, '2026-10-31', p_cash_date, 'WFX',
         array['หลักฐาน.pdf'], '00000000-0000-0000-0000-00000002c001',
         p_rate, p_amount, p_cert
    from sri_os.owners o where o.code = 'THANAKORN';
  return p_id;
end $fn$;

create or replace function pg_temp.ln(p_txn uuid, p_code text, p_dr numeric, p_cr numeric,
                                      p_asset uuid default null) returns void
language plpgsql as $fn$
begin
  insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id, debit, credit,
                                       asset_id, cf_category)
  values (p_txn, pg_temp.coa(p_code),
          case when p_code like '11__' then '00000000-0000-0000-0000-00000002b001'::uuid end,
          p_dr, p_cr, p_asset,
          case when p_code like '11__' then 'operating'::sri_os.cf_group end);
end $fn$;

do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.t_uid to authenticated', s);
end $$;

-- อัตราแลกเปลี่ยนของเดือน (ใช้ทั้งไฟล์) · ครบทั้งสี่สกุลและทั้งสองแหล่งที่มา
insert into sri_os.fx_rates(currency, rate_date, thb_per_unit, source, note)
values ('USD', '2026-10-31', 36.5, 'manual', 'ป้อนมือ เดือน ต.ค. 2569'),
       ('THB', '2026-10-31', 1, 'manual', 'สกุลตั้งต้น'),
       ('JPY', '2026-10-31', 0.235, 'manual', null),
       ('CNY', '2026-10-31', 5.05, 'bot_api', 'ทดสอบว่าแยกแหล่งที่มาได้');

-- ============================================================
-- W0 · โครงสร้าง — ไล่จาก catalog จริง ไม่ใช่ไล่ไฟล์
-- ============================================================
do $$
declare r record; v text;
begin
  for r in select p.proname, p.prosecdef, p.proconfig, p.oid from pg_proc p
            where p.oid in ('sri_os.fn_txn_type_can_withhold(text)'::regprocedure,
                            'sri_os.fn_assert_revaluation_no_pl()'::regprocedure,
                            'sri_os.fn_assert_wht_gross()'::regprocedure)
  loop
    if not r.prosecdef then
      raise exception 'FAIL: % ต้องเป็น security definer — ไม่งั้นได้ null จาก transactions/txn_types ที่ผู้เรียกมองไม่เห็น แล้วหลุดด่าน', r.proname;
    end if;
    if r.proconfig is null or not (r.proconfig::text like '%search_path%') then
      raise exception 'FAIL: % ไม่ได้ล็อก search_path (definer ที่ไม่ล็อก = ช่องให้สลับ schema)', r.proname;
    end if;
    if has_function_privilege('anon', r.oid, 'execute') then
      raise exception 'FAIL: anon เรียก % ได้', r.proname;
    end if;
  end loop;

  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.transaction_lines'::regclass
                    and g.tgname = 'trg_lines_s_revaluation_no_pl' and not g.tgisinternal
                    and (g.tgtype & 1) <> 0 and (g.tgtype & 2) <> 0
                    and (g.tgtype & 4) <> 0 and (g.tgtype & 16) <> 0) then
    raise exception 'FAIL: ไม่มี trigger before insert or update for each row ของ fn_assert_revaluation_no_pl';
  end if;
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.transaction_lines'::regclass
                    and g.tgname = 'trg_assert_wht_gross' and not g.tgisinternal
                    and g.tgdeferrable and g.tginitdeferred) then
    raise exception 'FAIL: trg_assert_wht_gross ต้องเป็น constraint trigger แบบ deferrable initially deferred — ไม่งั้นมันยิงตอนใส่บรรทัดแรกที่ใบยังไม่ครบ แล้วลงใบที่ถูกต้องไม่ได้เลย';
  end if;

  if not (select relrowsecurity from pg_class where oid = 'sri_os.fx_rates'::regclass) then
    raise exception 'FAIL: fx_rates ไม่ได้เปิด RLS';
  end if;
  select string_agg(policyname || '(' || cmd || ')', ', ') into v
    from pg_policies where schemaname = 'sri_os' and tablename = 'fx_rates';
  if v is null or position('fx_rates_read' in v) = 0 or position('fx_rates_write' in v) = 0 then
    raise exception 'FAIL: fx_rates policy ไม่ครบ (ได้: %)', coalesce(v, 'ไม่มีเลย');
  end if;
  if not exists (select 1 from pg_policies
                  where schemaname = 'sri_os' and tablename = 'fx_rates'
                    and policyname = 'fx_rates_write'
                    and coalesce(qual, '') like '%settings.manage%') then
    raise exception 'FAIL: policy เขียนของ fx_rates ไม่ได้บังคับสิทธิ์ settings.manage — อัตราผิดหนึ่งตัวทำให้มูลค่าทรัพย์ในงบดุลผิดทั้งก้อน';
  end if;

  raise notice 'ok W0 · ฟังก์ชันปิด · trigger ผูกจริง · fx_rates มี RLS และ policy ถามสิทธิ์';
end $$;

-- ============================================================
-- W1 · fn_txn_type_can_withhold ตอบตรงกับกฎทุกแถว
--
-- เขียนเงื่อนไขซ้ำ **อย่างอิสระ** ที่นี่โดยตั้งใจ — ถ้าเรียกฟังก์ชันมาเทียบกับ
-- ตัวเอง เทสต์จะผ่านฟรี · นี่คือตัวที่ยืนยันว่าสำเนาฝั่ง SQL ตรงกับ
-- canWithholdTax() ใน src/lib/rules/tx-rules.ts (เงื่อนไขสี่ข้อเดียวกัน)
-- ============================================================
do $$
declare v text; n int;
begin
  select string_agg(t.code, ', ' order by t.code), count(*) into v, n
    from sri_os.txn_types t
    left join sri_os.chart_of_accounts c on c.code = t.cr_coa_code
   where sri_os.fn_txn_type_can_withhold(t.code) <> (
           t.cash_direction = 'in'
           and t.dr_coa_code ~ '^11[0-9][0-9]$'
           and c.type::text = 'income'
           and t.cf_group = 'operating'
         );
  if n > 0 then
    raise exception 'FAIL: fn_txn_type_can_withhold ตอบไม่ตรงกับกฎที่ % หมวด: % — สำเนาฝั่ง SQL กับ canWithholdTax() ในโค้ดแยกจากกันแล้ว', n, v;
  end if;

  -- ต้องมีหมวดที่หักได้จริง ไม่งั้นข้อข้างบนผ่านเพราะทุกแถวเป็น false เหมือนกัน
  select count(*) into n from sri_os.txn_types t where sri_os.fn_txn_type_can_withhold(t.code);
  if n < 5 then
    raise exception 'FAIL: มีหมวดที่หักภาษีได้แค่ % หมวด — น้อยกว่าที่ตารางกฎมี (หมวดรายได้ทั้งกลุ่ม)', n;
  end if;

  if not sri_os.fn_txn_type_can_withhold('inc.rent') then
    raise exception 'FAIL: inc.rent ต้องหักภาษีได้';
  end if;
  foreach v in array array['exp.repair', 'inv.srr_redeem', 'trf.internal',
                           'inv.wht_refund', 'adj.revalue_securities_up'] loop
    if sri_os.fn_txn_type_can_withhold(v) then
      raise exception 'FAIL: % ไม่ควรหักภาษี ณ ที่จ่ายได้', v;
    end if;
  end loop;

  raise notice 'ok W1 · fn_txn_type_can_withhold ตรงกับกฎทุกแถว (% หมวดที่หักได้)', n;
end $$;

-- ============================================================
-- W2 · เส้นทางที่ถูกต้องต้องทำได้ — สามบรรทัด รายได้เต็มจำนวน
-- ============================================================
do $$
declare t uuid := '00000000-0000-0000-0000-00000002f001';
begin
  set constraints all deferred;
  perform pg_temp.mk_txn(t, 'inc.rent', 5, 5000, 'WHT-2569-001');
  -- เงินสด 95,000 + ภาษีถูกหัก 5,000 = รายได้ 100,000
  perform pg_temp.ln(t, '1100', 95000, 0);
  perform pg_temp.ln(t, '1800', 5000, 0);
  perform pg_temp.ln(t, '4200', 0, 100000, '00000000-0000-0000-0000-00000002a001');
  set constraints all immediate;
  raise notice 'ok W2 · ใบที่ถูกหักภาษีและลงรายได้ยอดเต็ม ลงได้ (เส้นทางที่ถูกต้องไม่ถูกกันแน่นเกิน)';
end $$;

-- ============================================================
-- W3 · **ใบที่ลงรายได้เป็นยอดสุทธิ → ต้องถูกปฏิเสธ**
--
-- ใบนี้ **สมดุลทุกบรรทัด** (90,000 + 5,000 = 95,000) และผ่านด่านอื่นทุกตัว
-- ถ้าด่านนี้ไม่ติด: รายได้ขาดไป 5,000 ทุกใบ และเงินสดในระบบขาดไป 5,000
-- (ลง 90,000 ทั้งที่ธนาคารเข้า 95,000) แล้วกระทบยอดกับ statement ไม่ลงตลอดไป
-- ============================================================
do $$
declare t uuid := '00000000-0000-0000-0000-00000002f002';
begin
  begin
    set constraints all deferred;
    perform pg_temp.mk_txn(t, 'inc.rent', 5, 5000, 'WHT-2569-002');
    perform pg_temp.ln(t, '1100', 90000, 0);
    perform pg_temp.ln(t, '1800', 5000, 0);
    perform pg_temp.ln(t, '4200', 0, 95000, '00000000-0000-0000-0000-00000002a001');
    set constraints all immediate;
    raise exception 'FAIL: W3 — ใบที่ลงรายได้เป็นยอดสุทธิผ่านได้ (รายได้ขาดไปเท่าภาษีที่ถูกหัก)';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if position('ยอดเต็ม' in sqlerrm) = 0 then
      raise exception 'FAIL: W3 — ปฏิเสธถูกแต่ข้อความไม่ได้บอกเรื่องยอดเต็ม: %', sqlerrm;
    end if;
  end;
  raise notice 'ok W3 · ใบที่ลงรายได้เป็นยอดสุทธิถูกปฏิเสธ (สมการ รายได้ = เงินสด + ภาษีที่ถูกหัก)';
end $$;

-- ============================================================
-- W4 · บรรทัด 1800 บนหมวดที่หักภาษีไม่ได้ → ปฏิเสธ
--      (ด่านคู่บัญชีระดับบรรทัดเป็นคนพูดก่อน)
-- ============================================================
do $$
declare t uuid := '00000000-0000-0000-0000-00000002f003';
begin
  begin
    set constraints all deferred;
    perform pg_temp.mk_txn(t, 'exp.repair', null, null, null);
    perform pg_temp.ln(t, '5120', 95000, 0, '00000000-0000-0000-0000-00000002a001');
    perform pg_temp.ln(t, '1800', 5000, 0);
    perform pg_temp.ln(t, '1100', 0, 100000);
    set constraints all immediate;
    raise exception 'FAIL: W4 — ลงบรรทัด 1800 บนหมวดค่าใช้จ่ายได้ (เราเป็นผู้จ่าย ไม่ใช่ผู้ถูกหัก)';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if position('1800' in sqlerrm) = 0 then
      raise exception 'FAIL: W4 — ปฏิเสธถูกแต่ข้อความไม่ได้พูดถึงบัญชี 1800: %', sqlerrm;
    end if;
  end;
  raise notice 'ok W4 · บรรทัด 1800 ลงได้เฉพาะหมวดที่หักภาษีได้จริง';
end $$;

-- ============================================================
-- W5 · ยอดในหัวรายการไม่เท่ายอดในบรรทัด 1800 → ปฏิเสธ
--      สองตัวเลขนี้คือยอดเดียวกัน ต่างกัน = รายงานภาษีกับสมุดไม่ตรง
-- ============================================================
do $$
declare t uuid := '00000000-0000-0000-0000-00000002f004';
begin
  begin
    set constraints all deferred;
    perform pg_temp.mk_txn(t, 'inc.rent', 5, 3000, 'WHT-2569-004');
    perform pg_temp.ln(t, '1100', 95000, 0);
    perform pg_temp.ln(t, '1800', 5000, 0);
    perform pg_temp.ln(t, '4200', 0, 100000, '00000000-0000-0000-0000-00000002a001');
    set constraints all immediate;
    raise exception 'FAIL: W5 — หัวรายการบอก 3,000 แต่บรรทัดลง 5,000 แล้วผ่านได้';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if position('ยอดภาษี' in sqlerrm) = 0 then
      raise exception 'FAIL: W5 — ปฏิเสธถูกแต่ข้อความชี้ผิดจุด: %', sqlerrm;
    end if;
  end;
  raise notice 'ok W5 · ยอดในหัวรายการต้องเท่ายอดในบรรทัด 1800';
end $$;

-- ============================================================
-- W6 · มีบรรทัด 1800 แต่หัวรายการไม่บันทึกอัตรา/ยอด → ปฏิเสธ
--      ยอดที่ไม่มีอัตรากำกับ ตรวจกับใบรับรองไม่ได้ และขอคืนไม่ได้
-- ============================================================
do $$
declare t uuid := '00000000-0000-0000-0000-00000002f005';
begin
  begin
    set constraints all deferred;
    perform pg_temp.mk_txn(t, 'inc.rent', null, null, null);
    perform pg_temp.ln(t, '1100', 95000, 0);
    perform pg_temp.ln(t, '1800', 5000, 0);
    perform pg_temp.ln(t, '4200', 0, 100000, '00000000-0000-0000-0000-00000002a001');
    set constraints all immediate;
    raise exception 'FAIL: W6 — มีบรรทัดภาษีถูกหักแต่หัวรายการว่างเปล่า แล้วผ่านได้';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if position('wht_amount' in sqlerrm) = 0 then
      raise exception 'FAIL: W6 — ปฏิเสธถูกแต่ข้อความไม่ได้ชี้ไปที่หัวรายการ: %', sqlerrm;
    end if;
  end;

  -- และทิศกลับกัน: หัวรายการบอกว่าถูกหัก แต่ไม่มีบรรทัด 1800 เลย
  begin
    set constraints all deferred;
    perform pg_temp.mk_txn('00000000-0000-0000-0000-00000002f006', 'inc.rent', 5, 5000, 'WHT-6');
    perform pg_temp.ln('00000000-0000-0000-0000-00000002f006', '1100', 100000, 0);
    perform pg_temp.ln('00000000-0000-0000-0000-00000002f006', '4200', 0, 100000,
                       '00000000-0000-0000-0000-00000002a001');
    set constraints all immediate;
    raise exception 'FAIL: W6b — หัวรายการบอกว่าถูกหักภาษีแต่ไม่มีบรรทัด 1800 แล้วผ่านได้ (สินทรัพย์ภาษีหายจากสมุด)';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if position('ไม่มีบรรทัด 1800' in sqlerrm) = 0 then
      raise exception 'FAIL: W6b — ปฏิเสธถูกแต่ข้อความชี้ผิดจุด: %', sqlerrm;
    end if;
  end;

  raise notice 'ok W6 · หัวรายการกับบรรทัดต้องเล่าเรื่องเดียวกันทั้งสองทิศ';
end $$;

-- ============================================================
-- W7 · constraint รูปร่างของคอลัมน์ wht_* (อัตรากับยอดต้องมาคู่กัน)
-- ============================================================
do $$
begin
  perform pg_temp.must_fail_like(
    'W7a อัตราที่ไม่มียอด',
    $q$ select pg_temp.mk_txn('00000000-0000-0000-0000-00000002f011', 'inc.rent', 5, null, null) $q$,
    'transactions_wht_shape');
  perform pg_temp.must_fail_like(
    'W7b ยอดที่ไม่มีอัตรา',
    $q$ select pg_temp.mk_txn('00000000-0000-0000-0000-00000002f012', 'inc.rent', null, 5000, null) $q$,
    'transactions_wht_shape');
  perform pg_temp.must_fail_like(
    'W7c อัตรา 0 ไม่ใช่การหักภาษี',
    $q$ select pg_temp.mk_txn('00000000-0000-0000-0000-00000002f013', 'inc.rent', 0, 5000, null) $q$,
    'transactions_wht_shape');
  perform pg_temp.must_fail_like(
    'W7d อัตราเกิน 100',
    $q$ select pg_temp.mk_txn('00000000-0000-0000-0000-00000002f014', 'inc.rent', 150, 5000, null) $q$,
    'transactions_wht_shape');
  perform pg_temp.must_fail_like(
    'W7e เลขที่ใบรับรองบนใบที่ไม่ได้ถูกหักภาษี',
    $q$ select pg_temp.mk_txn('00000000-0000-0000-0000-00000002f015', 'inc.rent', null, null, 'WHT-ผี') $q$,
    'transactions_wht_shape');
  raise notice 'ok W7 · อัตรากับยอดต้องมาคู่กัน และเลขที่ใบรับรองติดได้เฉพาะใบที่ถูกหักจริง';
end $$;

-- ============================================================
-- F1 · สกุลเงินของทรัพย์ — จำกัดสี่สกุล (D-111 ข้อ 2)
-- ============================================================
do $$
declare n int;
begin
  perform pg_temp.must_fail_like(
    'F1a สกุลที่ไม่อยู่ในรายการ',
    $q$ update sri_os.assets set currency = 'EUR' where code = 'WFX-STOCK' $q$,
    'assets_currency_allowed');
  perform pg_temp.must_fail_like(
    'F1b ตัวพิมพ์เล็ก',
    $q$ update sri_os.assets set currency = 'usd' where code = 'WFX-STOCK' $q$,
    'assets_currency_allowed');
  perform pg_temp.must_pass(
    'F1c สี่สกุลที่อนุญาตต้องใส่ได้ครบ',
    $q$ update sri_os.assets set currency = 'JPY' where code = 'WFX-STOCK' $q$);
  update sri_os.assets set currency = 'USD' where code = 'WFX-STOCK';

  -- DB ต้องรู้จักสี่สกุลพอดี ไม่ขาดไม่เกิน (สำเนาของ CURRENCIES ใน currency.ts)
  select count(*) into n from unnest(array['THB', 'USD', 'JPY', 'CNY']) x(c)
   where not exists (select 1 from sri_os.fx_rates f where f.currency = x.c);
  if n > 0 then
    raise exception 'FAIL: F1d — มี % สกุลที่ constraint อนุญาตแต่ใส่อัตราไม่ได้', n;
  end if;
  perform pg_temp.must_fail_like(
    'F1e สกุลที่ห้าในตารางอัตรา',
    $q$ insert into sri_os.fx_rates(currency, rate_date, thb_per_unit, source)
        values ('EUR', '2026-10-31', 39.5, 'manual') $q$,
    'fx_rates_currency_check');
  perform pg_temp.must_fail_like(
    'F1f บาทต้องมีอัตรา 1',
    $q$ insert into sri_os.fx_rates(currency, rate_date, thb_per_unit, source)
        values ('THB', '2026-11-30', 36.5, 'manual') $q$,
    'fx_rates_base_currency_is_one');
  perform pg_temp.must_fail_like(
    'F1g แหล่งที่มาที่ไม่รู้จัก',
    $q$ insert into sri_os.fx_rates(currency, rate_date, thb_per_unit, source)
        values ('USD', '2026-11-30', 36.9, 'ลูกพี่บอกมา') $q$,
    'fx_rates_source_check');
  perform pg_temp.must_fail_like(
    'F1h อัตราติดลบหรือศูนย์',
    $q$ insert into sri_os.fx_rates(currency, rate_date, thb_per_unit, source)
        values ('USD', '2026-11-30', 0, 'manual') $q$,
    'fx_rates_thb_per_unit_check');

  raise notice 'ok F1 · สกุลเงินจำกัดสี่สกุล · บาทอัตรา 1 · แหล่งที่มาจำกัดค่า · อัตราต้องเป็นบวก';
end $$;

-- ============================================================
-- F2 · การตีราคาต้องเก็บ **มูลค่าสกุลเดิม + อัตรา + ยอดบาท** ครบชุด
--      และยอดบาทต้องคูณกันลงตัว (ห้ามเก็บแต่ยอดบาทสุดท้าย)
-- ============================================================
do $$
begin
  -- 40,000 USD × 36.5 = 1,460,000 บาท
  perform pg_temp.must_pass(
    'F2a ครบชุดและคูณลงตัว',
    $q$ insert into sri_os.asset_valuations(asset_id, as_of, method, value,
                                            currency, value_original, fx_rate, fx_rate_date)
        values ('00000000-0000-0000-0000-00000002a002', '2026-10-31', 'market_api', 1460000,
                'USD', 40000, 36.5, '2026-10-31') $q$);

  perform pg_temp.must_fail_like(
    'F2b ระบุสกุลแต่ไม่ส่งอัตรา',
    $q$ insert into sri_os.asset_valuations(asset_id, as_of, method, value,
                                            currency, value_original)
        values ('00000000-0000-0000-0000-00000002a002', '2026-09-30', 'market_api', 1460000,
                'USD', 40000) $q$,
    'asset_valuations_fx_shape');

  perform pg_temp.must_fail_like(
    'F2c ระบุอัตราแต่ไม่ส่งมูลค่าสกุลเดิม (เก็บแต่ยอดบาท)',
    $q$ insert into sri_os.asset_valuations(asset_id, as_of, method, value,
                                            currency, fx_rate, fx_rate_date)
        values ('00000000-0000-0000-0000-00000002a002', '2026-09-30', 'market_api', 1460000,
                'USD', 36.5, '2026-10-31') $q$,
    'asset_valuations_fx_shape');

  perform pg_temp.must_fail_like(
    'F2d ยอดบาทไม่ตรงกับอัตราคูณมูลค่าสกุลเดิม',
    $q$ insert into sri_os.asset_valuations(asset_id, as_of, method, value,
                                            currency, value_original, fx_rate, fx_rate_date)
        values ('00000000-0000-0000-0000-00000002a002', '2026-09-30', 'market_api', 9999999,
                'USD', 40000, 36.5, '2026-10-31') $q$,
    'asset_valuations_fx_shape');

  perform pg_temp.must_fail_like(
    'F2e อัตราที่ไม่มีอยู่ในตาราง fx_rates (เดาอัตราเอง)',
    $q$ insert into sri_os.asset_valuations(asset_id, as_of, method, value,
                                            currency, value_original, fx_rate, fx_rate_date)
        values ('00000000-0000-0000-0000-00000002a002', '2026-09-30', 'market_api', 1480000,
                'USD', 40000, 37, '2026-09-30') $q$,
    'asset_valuations_fx_rate_fk');

  perform pg_temp.must_fail_like(
    'F2f มีอัตราค้างมาแต่ไม่ได้ระบุสกุล',
    $q$ insert into sri_os.asset_valuations(asset_id, as_of, method, value, fx_rate)
        values ('00000000-0000-0000-0000-00000002a001', '2026-09-30', 'appraisal', 5000000, 36.5) $q$,
    'asset_valuations_fx_shape');

  -- ทรัพย์ในประเทศยังตีราคาเป็นบาทตรงๆ ได้เหมือนเดิม (กันแน่นเกิน = พัง)
  perform pg_temp.must_pass(
    'F2g ตีราคาเป็นบาทโดยไม่ต้องมีสกุลและอัตรา',
    $q$ insert into sri_os.asset_valuations(asset_id, as_of, method, value)
        values ('00000000-0000-0000-0000-00000002a001', '2026-10-31', 'appraisal', 5000000) $q$);

  raise notice 'ok F2 · ตีราคาสกุลต่างประเทศต้องมีมูลค่าสกุลเดิม + อัตรา + ยอดบาทที่คูณลงตัว และอัตราต้องมีอยู่จริงในตาราง';
end $$;

-- ============================================================
-- R1 · รายการตีราคาที่ถูกต้อง — Dr ทรัพย์ / Cr 3400 ไม่มีเงินสด
-- ============================================================
do $$
declare t uuid := '00000000-0000-0000-0000-00000002f021';
begin
  set constraints all deferred;
  -- ไม่มีขาเงินสด → cash_date ต้องเป็น null (20261009000001_cash_date_invariant)
  perform pg_temp.mk_txn(t, 'adj.revalue_securities_up', null, null, null, null);
  perform pg_temp.ln(t, '1700', 460000, 0, '00000000-0000-0000-0000-00000002a002');
  perform pg_temp.ln(t, '3400', 0, 460000, '00000000-0000-0000-0000-00000002a002');
  set constraints all immediate;
  raise notice 'ok R1 · รายการตีราคาลงได้ ทรัพย์ ↔ ส่วนเกินทุน ไม่มีบรรทัดเงินสด';
end $$;

-- ============================================================
-- R2 · **MUTATION** — ด่าน "ตีราคาห้ามแตะ P&L" ต้องแดงจริง
--
-- กลายพันธุ์ตารางกฎให้หมวดตีราคาเครดิตบัญชี **รายได้** (4900) ซึ่งทำให้
-- ด่านคู่บัญชี (fn_assert_line_coa_in_rules) **ยอมรับ** บรรทัดนั้น
-- → ตัวที่ต้องปฏิเสธคือ trg_lines_s_revaluation_no_pl เท่านั้น
--
-- ถ้าเคสนี้ผ่าน: กำไรขาดทุนจะวิ่งตามค่าเงินทุกเดือนทั้งที่ไม่มีอะไรเกิดขึ้นจริง
-- และใบยังสมดุลทุกบรรทัด ไม่มีอะไรฟ้องเลย (ลูกพี่สั่ง 24/10 ว่า "เด็ดขาด")
-- ============================================================
savepoint before_mutation;
do $$
declare t uuid := '00000000-0000-0000-0000-00000002f022';
begin
  -- กลายพันธุ์: ส่วนเกินทุน (3400) → รายได้อื่น (4900)
  update sri_os.txn_types set cr_coa_code = '4900' where code = 'adj.revalue_securities_up';
  if (select cr_coa_code from sri_os.txn_types where code = 'adj.revalue_securities_up') <> '4900' then
    raise exception 'FAIL: R2 — กลายพันธุ์ไม่สำเร็จ เทสต์นี้จึงไม่ได้พิสูจน์อะไร';
  end if;

  begin
    set constraints all deferred;
    perform pg_temp.mk_txn(t, 'adj.revalue_securities_up', null, null, null, null);
    perform pg_temp.ln(t, '1700', 460000, 0, '00000000-0000-0000-0000-00000002a002');
    perform pg_temp.ln(t, '4900', 0, 460000, '00000000-0000-0000-0000-00000002a002');
    set constraints all immediate;
    raise exception 'FAIL: R2 — รายการตีราคาลงบัญชีรายได้ได้ ด่านไม่ได้กันอะไรเลย';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if position('ห้ามเข้างบกำไรขาดทุนเด็ดขาด' in sqlerrm) = 0 then
      raise exception 'FAIL: R2 — ปฏิเสธถูกแต่ไม่ใช่ด่านการตีราคา: %', sqlerrm;
    end if;
  end;
  raise notice 'ok R2 · MUTATION · ด่าน "ตีราคาห้ามแตะงบกำไรขาดทุน" แดงจริง';
end $$;
-- คืนตารางกฎให้กลับเป็นของจริง **ก่อน** เคสถัดไป
rollback to savepoint before_mutation;
do $$
begin
  if (select cr_coa_code from sri_os.txn_types where code = 'adj.revalue_securities_up') <> '3400' then
    raise exception 'FAIL: R2 — ตารางกฎยังค้างสภาพกลายพันธุ์หลัง rollback';
  end if;
  raise notice 'ok R2b · ตารางกฎกลับสภาพเดิมหลังเทสต์ mutation';
end $$;

-- ============================================================
-- R3 · ต้นทุนทรัพย์ต้องเป็น **ต้นทุนเดิม** ไม่รวมใบตีราคา
--      ไม่งั้นกำไรจากการขายตาม FIFO (D-038) ต่ำกว่าจริงทุกใบ
-- ============================================================
do $$
declare t uuid := '00000000-0000-0000-0000-00000002f023';
        v_cost numeric;
begin
  -- ซื้อหุ้น 1,000,000 (ใบจริง) — ต้นทุนต้องเป็นก้อนนี้เท่านั้น
  set constraints all deferred;
  perform pg_temp.mk_txn(t, 'inv.buy_securities');
  perform pg_temp.ln(t, '1700', 1000000, 0, '00000000-0000-0000-0000-00000002a002');
  perform pg_temp.ln(t, '1100', 0, 1000000);
  set constraints all immediate;

  -- ใบตีราคา 460,000 ของ R1 ยังอยู่ในสมุด → ถ้า fn_asset_cost_basis นับมันด้วย
  -- ต้นทุนจะกลายเป็น 1,460,000
  select sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000002a002') into v_cost;
  if v_cost <> 1000000 then
    raise exception 'FAIL: R3 — ต้นทุนทรัพย์ควรเป็น 1,000,000 (ต้นทุนเดิม) แต่ได้ % · ใบตีราคาถูกนับเป็นต้นทุน แล้วกำไรจากการขายจะต่ำกว่าจริง', v_cost;
  end if;
  raise notice 'ok R3 · fn_asset_cost_basis ไม่นับใบตีราคา (ต้นทุน 1,000,000 ไม่ใช่ 1,460,000)';
end $$;

-- ============================================================
-- R5 · ใบขายจริง — ล้างส่วนเกินทุนออกพร้อมกัน และรับรู้กำไรเข้า P&L ได้
--
-- ใบนี้แตะ **ทั้ง** 3400 (ล้างส่วนเกินทุน) และบัญชีกำไรจากการขาย
-- ซึ่งต้องทำได้: ด่านการตีราคาไม่ติด เพราะหมวดขายไม่ได้มี 3400 ใน dr/cr
-- ถ้าด่านกันแน่นเกิน การขายทรัพย์ที่เคยตีราคาจะทำไม่ได้เลย
-- ============================================================
do $$
declare t uuid := '00000000-0000-0000-0000-00000002f024';
begin
  set constraints all deferred;
  perform pg_temp.mk_txn(t, 'inv.sell_securities');
  -- ขาย 1,500,000 · ต้นทุน 1,000,000 · กำไร 500,000 · ล้างส่วนเกินทุน 460,000
  perform pg_temp.ln(t, '1100', 1500000, 0);
  perform pg_temp.ln(t, '1700', 0, 1000000, '00000000-0000-0000-0000-00000002a002');
  perform pg_temp.ln(t, '4900', 0, 500000, '00000000-0000-0000-0000-00000002a002');
  perform pg_temp.ln(t, '3400', 460000, 0, '00000000-0000-0000-0000-00000002a002');
  perform pg_temp.ln(t, '1700', 0, 460000, '00000000-0000-0000-0000-00000002a002');
  set constraints all immediate;
  raise notice 'ok R5 · ใบขายล้างส่วนเกินทุน (3400) และรับรู้กำไรเข้า P&L ได้พร้อมกัน';
end $$;

-- ============================================================
-- R6 · บรรทัด 3400 บนหมวดที่ไม่ใช่ทั้งตีราคาและไม่ใช่การขาย → ปฏิเสธ
--      กันช่องที่ใครเอาส่วนเกินทุนไปปั่นกับหมวดอื่น
-- ============================================================
do $$
declare t uuid := '00000000-0000-0000-0000-00000002f025';
begin
  begin
    set constraints all deferred;
    perform pg_temp.mk_txn(t, 'inc.rent');
    perform pg_temp.ln(t, '1100', 100000, 0);
    perform pg_temp.ln(t, '3400', 0, 100000, '00000000-0000-0000-0000-00000002a001');
    set constraints all immediate;
    raise exception 'FAIL: R6 — ลงบรรทัด 3400 บนหมวดค่าเช่าได้ (ปั่นส่วนเกินทุนจากรายได้)';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if position('3400' in sqlerrm) = 0 then
      raise exception 'FAIL: R6 — ปฏิเสธถูกแต่ข้อความไม่ได้พูดถึง 3400: %', sqlerrm;
    end if;
  end;
  raise notice 'ok R6 · บรรทัด 3400 ลงได้เฉพาะหมวดตีราคาและหมวดที่รับรู้กำไร/ขาดทุนจากการขาย';
end $$;

do $$ begin raise notice '=== WHT + FX (D-111 ข้อ 1 และ 2) ผ่านทั้งหมด ==='; end $$;

rollback;
