-- ============================================================
-- SRI OS · เทสต์ด่านฝั่ง DB ของ ภาษีหัก ณ ที่จ่าย + หลายสกุลเงิน
--   (migration 20261024000001_wht_and_fx.sql · D-111 ข้อ 1 และ 2)
--
-- สิ่งที่ไฟล์นี้ต้องจับได้ (ไล่จาก "ถ้าถอดการแก้ออกแล้วต้องแดง"):
--   M1 ไม่มี fn_txn_type_can_withhold               → W1 W4 แดง
--   M2 ไม่ขยาย fn_assert_line_coa_in_rules ให้รับ 1800 → W2 แดง (เส้นทางที่ถูกทำไม่ได้)
--   M3 ไม่ขยายให้รับ 3400 บนใบขาย                   → R5 แดง
--   M4 ไม่มี trg_assert_wht_gross                   → W3 W5 W6 แดง (รายได้สุทธิผ่านฉลุย)
--   M5 ไม่มี trg_lines_s_revaluation_no_pl          → R2 แดง
--   M6 fn_asset_cost_basis ยังนับใบตีราคา           → R3 แดง
--   M7 ไม่มี constraint ของ assets.currency/fx      → F1 F2 F3 แดง
--   M8 ลืม revoke execute ของฟังก์ชันใหม่           → W0 แดง
--
-- **เคสที่สำคัญที่สุดคือ W3 และ R2** ทั้งคู่เป็นใบที่ **สมดุลทุกบรรทัด**
--   และผ่านด่านอื่นทั้งหมด — ถ้าสองด่านนี้ไม่ติด ตัวเลขผิดแบบเงียบเชียบ
--
-- R2 เป็นเทสต์แบบ **mutation**: แก้คู่บัญชีของหมวดตีราคาใน txn_types ให้ชี้
--   บัญชีรายได้ (ซึ่งทำให้ด่านคู่บัญชียอมรับบรรทัดนั้น) แล้วดูว่า trigger
--   ของการตีราคายังปฏิเสธ · ถ้าไม่ทำแบบนี้ เคสจะถูกปฏิเสธด้วยด่านคนละตัว
--   แล้วเราจะไม่รู้เลยว่า trigger ตัวนี้กันอะไรได้
--
-- ทั้งไฟล์อยู่ใน transaction เดียวและ **rollback** ปิดท้าย — ไม่ทิ้งรายการเงินไว้
-- และไม่ทิ้งตารางกฎที่ถูกกลายพันธุ์ไว้
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
 * หัวรายการ + บรรทัด ในก้อนเดียว — ด่าน wht_gross เป็น constraint trigger แบบ deferred
 * จึงต้อง `set constraints all immediate` เพื่อให้มันยิงตอนที่เราอยากตรวจ
 * ไม่ใช่ตอน commit ของทั้งไฟล์ (ซึ่งเราทำ rollback)
 */
create or replace function pg_temp.mk_txn(p_id uuid, p_type text, p_cash_date date default '2026-10-31')
returns uuid language plpgsql as $fn$
begin
  insert into sri_os.transactions(id, owner_id, txn_type_code, doc_date, cash_date, memo,
                                  attachments, contact_id)
  select p_id, o.id, p_type, '2026-10-31', p_cash_date, 'WFX',
         array['หลักฐาน.pdf'], '00000000-0000-0000-0000-00000002c001'
    from sri_os.owners o where o.code = 'THANAKORN';
  return p_id;
end $fn$;

create or replace function pg_temp.ln(p_txn uuid, p_code text, p_dr numeric, p_cr numeric,
                                      p_asset uuid default null) returns void
language plpgsql as $fn$
begin
  insert into sri_os.transaction_lines(transaction_id, coa_id, bank_account_id, debit, credit, asset_id, cf_category)
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

-- อัตราแลกเปลี่ยนของเดือน (ใช้ทั้งไฟล์)
insert into sri_os.fx_rates(currency, rate_date, thb_per_unit, source, note)
values ('USD', '2026-10-31', 36.5, 'manual', 'ป้อนมือ เดือน ต.ค. 2569'),
       ('THB', '2026-10-31', 1, 'manual', 'สกุลตั้งต้น'),
       ('JPY', '2026-10-31', 0.235, 'manual', null),
       ('CNY', '2026-10-31', 5.05, 'bot_api', 'ทดสอบว่าแยกแหล่งที่มาได้');

-- ============================================================
-- W0 · โครงสร้าง — ไล่จาก catalog จริง
-- ============================================================
do $$
declare r record; v text;
begin
  -- (ก) ฟังก์ชันใหม่ต้องล็อก search_path และ anon เรียกไม่ได้
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

  -- (ข) trigger ต้องผูกจริงบนตาราง ไม่ใช่มีแต่ฟังก์ชัน
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

  -- (ค) ตาราง fx_rates ต้องมี RLS + policy อ่าน + policy เขียนที่ถามสิทธิ์
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

  -- ต้องมีหมวดที่หักได้จริง ไม่งั้นเทสต์ข้างบนผ่านเพราะทุกแถวเป็น false เหมือนกัน
  select count(*) into n from sri_os.txn_types t where sri_os.fn_txn_type_can_withhold(t.code);
  if n < 5 then
    raise exception 'FAIL: มีหมวดที่หักภาษีได้แค่ % หมวด — น้อยกว่าที่ตารางกฎมี (หมวดรายได้ทั้งกลุ่ม)', n;
  end if;

  -- และต้องมีหมวดที่หักไม่ได้ ไม่งั้นด่านไม่ได้แยกอะไรเลย
  if not exists (select 1 from sri_os.txn_types t
                  where t.code = 'inc.rent' and sri_os.fn_txn_type_can_withhold(t.code)) then
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
  perform pg_temp.mk_txn(t, 'inc.rent');
  update sri_os.transactions set wht_rate = 5, wht_amount = 5000, wht_certificate_no = 'WHT-2569-001'
   where id = t;
  -- เงินสด 95,000 + ภาษีถูกหัก 5,000 = รายได้ 100,000
  perform pg_temp.ln(t, '1100', 95000, 0);
  perform pg_temp.ln(t, '1800', 5000, 0);
  perform pg_temp.ln(t, '4200', 0, 100000, '00000000-0000-0000-0000-00000002a001');
  set constraints all immediate;
  raise notice 'ok W2 · ใบที่ถูกหักภาษีและลงรายได้ยอดเต็ม ลงได้';
end $$;

-- ============================================================
-- W3 · **ใบที่ลงรายได้เป็นยอดสุทธิ → ต้องถูกปฏิเสธ**
--
-- ใบนี้ **สมดุลทุกบรรทัด** (95,000 = 90,000 + 5,000) และผ่านด่านอื่นทุกตัว
-- ถ้าด่านนี้ไม่ติด: รายได้ขาดไป 5,000 ทุกใบ · เงินสดในระบบขาดไป 5,000
-- (ลง 90,000 ทั้งที่ธนาคารเข้า 95,000) แล้วกระทบยอดไม่ลงตลอดไป
-- ============================================================
do $$
declare t uuid := '00000000-0000-0000-0000-00000002f002';
begin
  perform pg_temp.mk_txn(t, 'inc.rent');
  update sri_os.transactions set wht_rate = 5, wht_amount = 5000 where id = t;
  perform pg_temp.ln(t, '1100', 90000, 0);
  perform pg_temp.ln(t, '1800', 5000, 0);
  perform pg_temp.ln(t, '4200', 0, 95000, '00000000-0000-0000-0000-00000002a001');
  begin
    set constraints all immediate;
    raise exception 'FAIL: W3 — ใบที่ลงรายได้เป็นยอดสุทธิผ่านได้ (รายได้ขาดไปเท่าภาษีที่ถูกหัก)';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if position('ยอดเต็ม' in sqlerrm) = 0 then
      raise exception 'FAIL: W3 — ปฏิเสธถูกแต่ข้อความไม่ได้บอกเรื่องยอดเต็ม: %', sqlerrm;
    end if;
  end;
  raise notice 'ok W3 · ใบที่ลงรายได้เป็นยอดสุทธิถูกปฏิเสธ';
end $$;
rollback to savepoint_none_marker;
