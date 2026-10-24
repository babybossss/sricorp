-- ============================================================
-- SRI OS · เทสต์ด่านฝั่ง DB ของ ภาษีหัก ณ ที่จ่าย + หลายสกุลเงิน
--   (20261024000001_wht_and_fx.sql + 20261025000001_wht_post_entry.sql · D-111 ข้อ 1-2)
--
-- **เปลี่ยนรอบนี้: ทุกใบลงผ่าน `sri_os.fn_post_entry()` เท่านั้น**
--   รุ่นก่อน `insert into sri_os.transactions` ตรงๆ (บรรทัด 118) จึง **เขียวโดยไม่เคย
--   แตะเส้นทางจริง** — และเส้นทางจริงนั้น **ตันสนิท**: ประตูไม่รับช่อง wht_* เลย
--   (ใส่มาก็เด้ง "ช่องที่ยังไม่รู้จัก" · ไม่ใส่ก็โดนด่านตอน commit)
--   บทเรียน: เทสต์ที่ไม่เดินเส้นทางจริงไม่ได้พิสูจน์ว่าผู้ใช้ทำได้
--
-- สิ่งที่ไฟล์นี้ต้องจับได้ (ไล่จาก "ถ้าถอดการแก้ออกแล้วต้องแดง"):
--   M1 ไม่มี fn_txn_type_can_withhold                  → W1 W4 แดง
--   M2 ประตูไม่รับช่อง wht_*                            → W2 แดง (เส้นทางที่ถูกทำไม่ได้)
--   M3 ด่านบรรทัดไม่รับ 3400 บนใบขาย                   → R5 แดง
--   M4 ไม่มี trg_assert_wht_gross                      → W3 W5 W6 W8b แดง (ยอดสุทธิผ่านฉลุย)
--   M5 ไม่มี trg_lines_s_revaluation_no_pl             → R2 แดง
--   M6 fn_asset_cost_basis ยังนับใบตีราคาเป็นต้นทุน     → R3 แดง
--   M7 ไม่มี constraint ของ assets.currency / fx        → F1 F2 F3 แดง
--   M8 ลืม revoke execute / ไม่ล็อก search_path         → W0 แดง
--   M9 can_withhold ไม่รับหมวดรับชำระค้างรับ            → W8 แดง (ข้อ 3 ของผู้ตรวจ)
--   M10 ไม่มี trg_assert_wht_gross_txn                  → W9 แดง (ข้อ 4 ของผู้ตรวจ)
--
-- **เคสที่สำคัญที่สุดคือ W3 · W8b · R2** ทั้งหมดเป็นใบที่ **สมดุลทุกบรรทัด**
--   และผ่านด่านอื่นทั้งหมด — ถ้าด่านพวกนี้ไม่ติด ตัวเลขผิดแบบเงียบเชียบ
--
-- R2 เป็นเทสต์แบบ **mutation**: แก้คู่บัญชีของหมวดตีราคาใน txn_types ให้ชี้บัญชี
--   รายได้ (ซึ่งทำให้ด่านคู่บัญชี *ยอมรับ* บรรทัดนั้น) แล้วดูว่า trigger ของการ
--   ตีราคายังปฏิเสธ · ถ้าไม่กลายพันธุ์ก่อน เคสจะถูกปฏิเสธด้วยด่านคนละตัว
--
-- **หมายเหตุเรื่อง deferred**: `fn_post_entry` สั่ง `set constraints all immediate`
--   ให้เองก่อนคืนค่า → ด่านที่เลื่อนไว้ (สมดุล · wht gross · สัดส่วนต้นทุน) **ยิงตอน
--   เรียก** ไม่ใช่ตอน commit ซึ่งไฟล์นี้ rollback ทิ้ง (ถ้ายิงตอน commit ด่านจะไม่เคย
--   ทำงานเลยและเทสต์ผ่านฟรี)
--
-- ไฟล์นี้รันในฐานะเจ้าของฐานข้อมูล (ไม่ `set role authenticated`) เพราะเคส mutation
--   ต้องปิด/เปิด trigger ของตารางกฎ · ฝั่ง RLS ของประตูมีเทสต์ของตัวเองแล้วที่
--   zz_post_entry_test.sql และ zz_asset_cost_basis_test.sql (รันเป็น authenticated)
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
 * ตัวช่วยประกอบ payload ของ `fn_post_entry` — **ที่เดียวที่รู้รูปของ payload**
 * ทุกเคสในไฟล์นี้ลงใบผ่าน pg_temp.post() เท่านั้น ไม่มี insert เข้าสมุดตรงๆ
 */
create or replace function pg_temp.ln(p_code text, p_dr numeric, p_cr numeric,
                                     p_asset uuid default null, p_cf text default null,
                                     p_bank uuid default null) returns jsonb
language sql immutable as $fn$
  select jsonb_strip_nulls(jsonb_build_object(
    'coa_code', p_code, 'debit', p_dr, 'credit', p_cr,
    'asset_id', p_asset, 'cf_category', p_cf, 'bank_account_id', p_bank));
$fn$;

-- บรรทัดเงินสดผูกบัญชีธนาคารของธนากรให้เสมอ (Money Invariant 2 · ไม่มีเงินลอย)
create or replace function pg_temp.cash(p_dr numeric, p_cr numeric) returns jsonb
language sql stable as $fn$
  select pg_temp.ln('1100', p_dr, p_cr, null, 'operating',
                    '00000000-0000-0000-0000-00000002b001'::uuid);
$fn$;

create or replace function pg_temp.entry(p_type text, p_memo text, p_lines jsonb,
                                        p_rate numeric default null,
                                        p_amount numeric default null,
                                        p_cert text default null,
                                        p_cash_date date default '2026-10-31',
                                        p_asset uuid default '00000000-0000-0000-0000-00000002a001')
returns jsonb language sql stable as $fn$
  select jsonb_strip_nulls(jsonb_build_object(
    'txn_type_code', p_type,
    'doc_date', '2026-10-31',
    'cash_date', case when p_cash_date is null then null else p_cash_date::text end,
    'memo', p_memo,
    'asset_id', p_asset,
    'contact_id', '00000000-0000-0000-0000-00000002c001',
    'attachments', jsonb_build_array('หลักฐาน.pdf'),
    'wht_rate', p_rate,
    'wht_amount', p_amount,
    'wht_certificate_no', p_cert,
    'transactions', jsonb_build_array(jsonb_build_object(
      'owner_id', (select id from sri_os.owners where code = 'THANAKORN'),
      'lines', p_lines))));
$fn$;

create or replace function pg_temp.post(p_payload jsonb) returns uuid
language plpgsql as $fn$
declare v jsonb;
begin
  v := sri_os.fn_post_entry(p_payload);
  if (v ->> 'replayed')::boolean then
    raise exception 'FAIL: fn_post_entry ถือว่าใบนี้เป็นการกดซ้ำ (memo ของแต่ละใบต้องไม่ซ้ำกัน)';
  end if;
  return ((v -> 'transaction_ids') ->> 0)::uuid;
end $fn$;

do $$
declare s text := (select nspname from pg_namespace where oid = pg_my_temp_schema());
begin
  execute format('grant usage on schema %I to authenticated', s);
  execute format('grant select on %I.t_uid to authenticated', s);
end $$;

select pg_temp.login('mgmt');

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
                            'sri_os.fn_assert_wht_gross()'::regprocedure,
                            'sri_os.fn_assert_wht_gross_txn()'::regprocedure,
                            'sri_os.fn_assert_wht_gross_for(uuid)'::regprocedure)
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
  -- **ข้อ 4 ของผู้ตรวจ** · ด่านต้องผูก `transactions` ด้วย ไม่ใช่แต่บรรทัด
  -- และต้อง **ยิงทันที ไม่ใช่เลื่อนถึง commit**: การแก้ยอดภาษีย้อนหลังต้องเด้ง
  -- ตอนสั่ง ไม่ใช่ตอน commit (เซสชันที่ไม่เคย commit จะไม่โดนด่านเลย)
  if not exists (select 1 from pg_trigger g
                  where g.tgrelid = 'sri_os.transactions'::regclass
                    and g.tgname = 'trg_assert_wht_gross_txn' and not g.tgisinternal
                    and not g.tgdeferrable
                    and (g.tgtype & 1) <> 0 and (g.tgtype & 4) <> 0 and (g.tgtype & 16) <> 0) then
    raise exception 'FAIL: ไม่มี trg_assert_wht_gross_txn แบบ after insert or update for each row (ไม่ deferred) บน transactions — แก้ wht_amount ของใบที่ post แล้วจะไม่มีอะไรตรวจ';
  end if;

  -- ประตูต้องรู้จักช่อง wht_* จริง (ถ้าไม่รู้จัก เส้นทางทั้งเรื่องตัน)
  select string_agg(x.k, ', ') into v
    from unnest(array['wht_rate', 'wht_amount', 'wht_certificate_no']) x(k)
   where pg_get_functiondef('sri_os.fn_post_entry(jsonb)'::regprocedure) not like '%' || x.k || '%';
  if v is not null then
    raise exception 'FAIL: ประตู fn_post_entry ไม่รู้จักช่อง % — ลงรายการที่ถูกหักภาษีไม่ได้เลย', v;
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

  raise notice 'ok W0 · ฟังก์ชันปิด · trigger ผูกทั้งสองตาราง · ประตูรู้จักช่อง wht_* · fx_rates มี RLS และ policy ถามสิทธิ์';
end $$;

-- ============================================================
-- W1 · fn_txn_type_can_withhold ตอบตรงกับกฎทุกแถว
--
-- เขียนเงื่อนไขซ้ำ **อย่างอิสระ** ที่นี่โดยตั้งใจ — ถ้าเรียกฟังก์ชันมาเทียบกับ
-- ตัวเอง เทสต์จะผ่านฟรี · นี่คือตัวที่ยืนยันว่าสำเนาฝั่ง SQL ตรงกับ
-- canWithholdTax() ใน src/lib/rules/tx-rules.ts
--
-- **เงินได้มีสองรูป** (D-111 ข้อ 1 + ข้อ 3 ของผู้ตรวจ):
--   (ก) ขาเครดิตเป็นบัญชีรายได้ — รับรู้รายได้พร้อมรับเงิน
--   (ข) ขาเครดิตเป็นบัญชีค้างรับของหมวดรายได้ — รับชำระลูกหนี้ที่รับรู้รายได้
--       ยอดเต็มไปแล้วตอนตั้งค้าง (ค่าเช่าที่ผู้เช่าหัก 5% ตอนจ่าย)
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
           and t.cf_group = 'operating'
           and (
             c.type::text = 'income'
             or exists (
               select 1 from sri_os.txn_types a
                 join sri_os.chart_of_accounts ci on ci.code = a.cr_coa_code
                where a.accrual_coa_code = t.cr_coa_code
                  and ci.type::text = 'income'
                  and a.cf_group = 'operating')
           )
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
  -- **ข้อ 3 ของผู้ตรวจ** — ค่าเช่าที่ตั้งค้างไว้แล้วถูกหักตอนรับชำระ ต้องหักได้
  if not sri_os.fn_txn_type_can_withhold('inv.collect_rent') then
    raise exception 'FAIL: inv.collect_rent ต้องหักภาษีได้ — ไม่งั้นค่าเช่าที่ออกใบแจ้งหนี้ไว้แล้วผู้เช่าหัก 5%% ลงไม่ได้ทุกทาง';
  end if;
  foreach v in array array['exp.repair', 'inv.srr_redeem', 'trf.internal',
                           'inv.wht_refund', 'adj.revalue_securities_up'] loop
    if sri_os.fn_txn_type_can_withhold(v) then
      raise exception 'FAIL: % ไม่ควรหักภาษี ณ ที่จ่ายได้', v;
    end if;
  end loop;

  raise notice 'ok W1 · fn_txn_type_can_withhold ตรงกับกฎทุกแถว (% หมวดที่หักได้ · รวมหมวดรับชำระค้างรับ)', n;
end $$;

-- ============================================================
-- W2 · เส้นทางที่ถูกต้องต้องทำได้ **ผ่านประตูจริง** — สามบรรทัด รายได้ยอดเต็ม
--      (เคสนี้คือเคสที่พิสูจน์ว่าข้อ 1 ของผู้ตรวจถูกปิดแล้ว: ก่อนแก้ ใบนี้
--       ลงไม่ได้ทั้งสองทาง — ใส่ช่อง wht_* ก็เด้ง ไม่ใส่ก็โดนด่านตอน commit)
-- ============================================================
do $$
declare t uuid; r sri_os.transactions;
begin
  -- เงินสด 95,000 + ภาษีถูกหัก 5,000 = รายได้ 100,000
  t := pg_temp.post(pg_temp.entry('inc.rent', 'W2 ค่าเช่าถูกหักภาษี 5%',
    jsonb_build_array(
      pg_temp.cash(95000, 0),
      pg_temp.ln('1800', 5000, 0, null, 'operating'),
      pg_temp.ln('4200', 0, 100000, '00000000-0000-0000-0000-00000002a001', 'operating')),
    5, 5000, 'WHT-2569-001'));

  select * into r from sri_os.transactions where id = t;
  if r.wht_rate <> 5 or r.wht_amount <> 5000 or r.wht_certificate_no <> 'WHT-2569-001' then
    raise exception 'FAIL: W2 — ประตูไม่ได้เขียนค่า wht_* ลงหัวรายการ (ได้ rate=% amount=% cert=%) → ด่านจะปฏิเสธใบที่ถูกต้องทุกใบ',
      r.wht_rate, r.wht_amount, r.wht_certificate_no;
  end if;
  raise notice 'ok W2 · ใบที่ถูกหักภาษีและลงรายได้ยอดเต็ม **ลงผ่าน fn_post_entry ได้จริง** และค่า wht_* ไปถึงหัวรายการ';
end $$;

-- ============================================================
-- W3 · **ใบที่ลงรายได้เป็นยอดสุทธิ → ต้องถูกปฏิเสธ**
--
-- ใบนี้ **สมดุลทุกบรรทัด** (90,000 + 5,000 = 95,000) และผ่านด่านอื่นทุกตัว
-- ถ้าด่านนี้ไม่ติด: รายได้ขาดไป 5,000 ทุกใบ และเงินสดในระบบขาดไป 5,000
-- (ลง 90,000 ทั้งที่ธนาคารเข้า 95,000) แล้วกระทบยอดกับ statement ไม่ลงตลอดไป
-- ============================================================
do $$
begin
  perform pg_temp.must_fail_like('W3 ลงรายได้เป็นยอดสุทธิ',
    $q$ select pg_temp.post(pg_temp.entry('inc.rent', 'W3 รายได้ยอดสุทธิ',
          jsonb_build_array(
            pg_temp.cash(90000, 0),
            pg_temp.ln('1800', 5000, 0, null, 'operating'),
            pg_temp.ln('4200', 0, 95000, '00000000-0000-0000-0000-00000002a001', 'operating')),
          5, 5000, 'WHT-2569-002')) $q$,
    'ยอดเต็ม');
  raise notice 'ok W3 · ใบที่ลงรายได้เป็นยอดสุทธิถูกปฏิเสธ (สมการ เงินได้ = เงินสด + ภาษีที่ถูกหัก)';
end $$;

-- ============================================================
-- W4 · บรรทัด 1800 บนหมวดที่หักภาษีไม่ได้ → ปฏิเสธ
--      (ด่านคู่บัญชีระดับบรรทัดเป็นคนพูดก่อน · ประตูไม่มีกฎนี้แล้วตั้งแต่ 013)
-- ============================================================
do $$
begin
  perform pg_temp.must_fail_like('W4 บรรทัด 1800 บนหมวดค่าใช้จ่าย',
    $q$ select pg_temp.post(pg_temp.entry('exp.repair', 'W4 ค่าซ่อมที่พยายามลง 1800',
          jsonb_build_array(
            pg_temp.ln('5120', 95000, 0, '00000000-0000-0000-0000-00000002a001', 'operating'),
            pg_temp.ln('1800', 5000, 0, null, 'operating'),
            pg_temp.cash(0, 100000)))) $q$,
    '1800');
  raise notice 'ok W4 · บรรทัด 1800 ลงได้เฉพาะหมวดที่หักภาษีได้จริง (เราเป็นผู้จ่าย ไม่ใช่ผู้ถูกหัก)';
end $$;

-- ============================================================
-- W5 · ยอดในหัวรายการไม่เท่ายอดในบรรทัด 1800 → ปฏิเสธ
--      สองตัวเลขนี้คือยอดเดียวกัน ต่างกัน = รายงานภาษีกับสมุดไม่ตรง
-- ============================================================
do $$
begin
  perform pg_temp.must_fail_like('W5 หัวรายการบอก 3,000 แต่บรรทัดลง 5,000',
    $q$ select pg_temp.post(pg_temp.entry('inc.rent', 'W5 หัวกับบรรทัดไม่ตรง',
          jsonb_build_array(
            pg_temp.cash(95000, 0),
            pg_temp.ln('1800', 5000, 0, null, 'operating'),
            pg_temp.ln('4200', 0, 100000, '00000000-0000-0000-0000-00000002a001', 'operating')),
          3, 3000, 'WHT-2569-004')) $q$,
    'ยอดภาษี');
  raise notice 'ok W5 · ยอดในหัวรายการต้องเท่ายอดในบรรทัด 1800';
end $$;

-- ============================================================
-- W6 · หัวรายการกับบรรทัดต้องเล่าเรื่องเดียวกัน **ทั้งสองทิศ**
-- ============================================================
do $$
begin
  -- มีบรรทัด 1800 แต่หัวรายการว่าง → ยอดที่ไม่มีอัตรากำกับ ตรวจใบรับรองไม่ได้
  perform pg_temp.must_fail_like('W6a มีบรรทัด 1800 แต่หัวรายการว่าง',
    $q$ select pg_temp.post(pg_temp.entry('inc.rent', 'W6a หัวรายการว่าง',
          jsonb_build_array(
            pg_temp.cash(95000, 0),
            pg_temp.ln('1800', 5000, 0, null, 'operating'),
            pg_temp.ln('4200', 0, 100000, '00000000-0000-0000-0000-00000002a001', 'operating')))) $q$,
    'wht_amount');

  -- หัวรายการบอกว่าถูกหัก แต่ไม่มีบรรทัด 1800 เลย → สินทรัพย์ภาษีหายจากสมุด
  perform pg_temp.must_fail_like('W6b หัวรายการบอกว่าถูกหักแต่ไม่มีบรรทัด',
    $q$ select pg_temp.post(pg_temp.entry('inc.rent', 'W6b ไม่มีบรรทัด 1800',
          jsonb_build_array(
            pg_temp.cash(100000, 0),
            pg_temp.ln('4200', 0, 100000, '00000000-0000-0000-0000-00000002a001', 'operating')),
          5, 5000, 'WHT-6')) $q$,
    'ไม่มีบรรทัด 1800');

  raise notice 'ok W6 · หัวรายการกับบรรทัดต้องเล่าเรื่องเดียวกันทั้งสองทิศ';
end $$;

-- ============================================================
-- W7 · รูปของค่าที่ส่งมา — อัตรากับยอดต้องมาคู่กัน · อัตราต้องมีความหมาย
--      ด่านมีสองชั้น: ข้อความภาษาคนที่ประตู + constraint ที่ตาราง
--      (ทั้งสองชั้นต้องอยู่จริง — เทสต์ไล่ทั้งคู่ ไม่ใช่เชื่อชั้นใดชั้นเดียว)
-- ============================================================
do $$
declare v text;
begin
  perform pg_temp.must_fail_like('W7a อัตราที่ไม่มียอด',
    $q$ select pg_temp.post(pg_temp.entry('inc.rent', 'W7a อัตราไม่มียอด',
          jsonb_build_array(
            pg_temp.cash(100000, 0),
            pg_temp.ln('4200', 0, 100000, '00000000-0000-0000-0000-00000002a001', 'operating')),
          5, null, null)) $q$,
    'คู่กัน');
  perform pg_temp.must_fail_like('W7b ยอดที่ไม่มีอัตรา',
    $q$ select pg_temp.post(pg_temp.entry('inc.rent', 'W7b ยอดไม่มีอัตรา',
          jsonb_build_array(
            pg_temp.cash(95000, 0),
            pg_temp.ln('1800', 5000, 0, null, 'operating'),
            pg_temp.ln('4200', 0, 100000, '00000000-0000-0000-0000-00000002a001', 'operating')),
          null, 5000, null)) $q$,
    'คู่กัน');
  perform pg_temp.must_fail_like('W7c อัตรา 0 ไม่ใช่การหักภาษี',
    $q$ select pg_temp.post(pg_temp.entry('inc.rent', 'W7c อัตราศูนย์',
          jsonb_build_array(
            pg_temp.cash(95000, 0),
            pg_temp.ln('1800', 5000, 0, null, 'operating'),
            pg_temp.ln('4200', 0, 100000, '00000000-0000-0000-0000-00000002a001', 'operating')),
          0, 5000, null)) $q$,
    'transactions_wht_shape');
  perform pg_temp.must_fail_like('W7d อัตราเกิน 100',
    $q$ select pg_temp.post(pg_temp.entry('inc.rent', 'W7d อัตราเกินร้อย',
          jsonb_build_array(
            pg_temp.cash(95000, 0),
            pg_temp.ln('1800', 5000, 0, null, 'operating'),
            pg_temp.ln('4200', 0, 100000, '00000000-0000-0000-0000-00000002a001', 'operating')),
          150, 5000, null)) $q$,
    'transactions_wht_shape');
  perform pg_temp.must_fail_like('W7e เลขที่ใบรับรองบนใบที่ไม่ได้ถูกหักภาษี',
    $q$ select pg_temp.post(pg_temp.entry('inc.rent', 'W7e ใบรับรองผี',
          jsonb_build_array(
            pg_temp.cash(100000, 0),
            pg_temp.ln('4200', 0, 100000, '00000000-0000-0000-0000-00000002a001', 'operating')),
          null, null, 'WHT-ผี')) $q$,
    'ใบรับรอง');

  -- ชั้นที่สองต้องมีจริงและ validate แล้ว (constraint ที่ไม่ validate = ไม่มีด่าน)
  if not exists (select 1 from pg_constraint c
                  where c.conname = 'transactions_wht_shape' and c.convalidated) then
    raise exception 'FAIL: W7f — ไม่มี constraint transactions_wht_shape ที่ validate แล้ว';
  end if;
  select pg_get_constraintdef(c.oid) into v from pg_constraint c where c.conname = 'transactions_wht_shape';
  if position('wht_rate' in v) = 0 then
    raise exception 'FAIL: W7f — constraint ไม่ได้พูดถึง wht_rate (%)', v;
  end if;

  raise notice 'ok W7 · อัตรากับยอดต้องมาคู่กัน · อัตราต้องอยู่ในช่วงที่มีความหมาย · ใบรับรองติดได้เฉพาะใบที่ถูกหักจริง · ด่านครบทั้งสองชั้น';
end $$;

-- ============================================================
-- W8 · **ข้อ 3 ของผู้ตรวจ** — ค่าเช่าที่ตั้งค้างรับไว้ แล้วผู้เช่าจ่ายโดยหัก 5%
--
-- ลำดับที่เกิดจริงทุกเดือน: ออกใบแจ้งหนี้ → ตั้งลูกหนี้ค่าเช่า 100,000
-- (รายได้รับรู้ยอดเต็มตอนนี้) → ผู้เช่าโอน 95,000 + ใบหักภาษี 5,000
--
-- ก่อนแก้: ใบตั้งค้างพร้อมหักภาษีลงไม่ได้ (ยังไม่มีใครหัก — ซึ่งถูก)
--          และใบรับชำระก็ลงไม่ได้ (ขาเครดิตเป็นลูกหนี้ ไม่ใช่บัญชีรายได้)
--          → **5,000 หายจากสมุดถาวร** หรือผู้ใช้ต้องลงผิดเป็นค่าใช้จ่าย
-- ============================================================
do $$
declare v_recv numeric;
begin
  -- (1) ตั้งลูกหนี้ค่าเช่า — ไม่มีบรรทัดเงินสด จึงไม่มี cash_date (ด่าน cash_date)
  perform pg_temp.post(pg_temp.entry('inc.rent', 'W8 ตั้งค้างรับค่าเช่า 100,000',
    jsonb_build_array(
      pg_temp.ln('1200', 100000, 0, '00000000-0000-0000-0000-00000002a001', 'none'),
      pg_temp.ln('4200', 0, 100000, '00000000-0000-0000-0000-00000002a001', 'none')),
    null, null, null, null));

  /**
   * (2) **ปิดลูกหนี้ด้วยยอดสุทธิ → ต้องถูกปฏิเสธ**
   *
   * ทำก่อนใบที่ถูกต้อง เพราะถ้าปิดลูกหนี้ครบไปแล้ว ด่าน "ลูกหนี้ติดลบ" จะเป็น
   * คนปฏิเสธก่อน แล้วเราจะไม่รู้ว่าด่านของภาษีกันอะไรได้ (ด่านที่ไม่มีใครพิสูจน์)
   *
   * ใบนี้ **สมดุลทุกบรรทัด** (90,000 + 5,000 = 95,000) และคู่บัญชีอยู่ในชุดที่
   * หมวดนี้ลงได้ทั้งหมด · คนที่กรอกแบบนี้คือคนที่เอายอดในใบแจ้งหนี้ (ยอดเต็ม)
   * มาสับสนกับยอดที่เข้าบัญชี แล้วลูกหนี้จะเหลือค้าง 5,000 ตลอดไปพร้อมกับ
   * เงินสดที่ไม่ตรง statement 5,000 · คนที่ปฏิเสธคือ **ข้อ (ง) ของกฎเดียวกัน**:
   * 5% ของเงินได้ที่ลงไว้ (95,000) คือ 4,750 ไม่ใช่ 5,000 ที่ใบรับรองบอก
   * → ถ้าใบรับรองถูก ยอดที่ลงไว้ก็ไม่ใช่ยอดเต็ม
   *
   * (ภายในชุดบัญชีที่หมวดนี้ลงได้ — เงินสด · 1800 · ลูกหนี้ — สมการ
   *  "เงินได้ = เงินสด + ภาษี" ถูกบังคับร่วมกันโดยด่านสมดุลกับข้อ (ง)
   *  ส่วนด่านข้อ (ค) เป็นตัวหลักของใบที่รับรู้รายได้พร้อมรับเงิน ซึ่ง W3 ทดสอบไว้)
   */
  perform pg_temp.must_fail_like('W8b ปิดลูกหนี้ด้วยยอดสุทธิ',
    $q$ select pg_temp.post(pg_temp.entry('inv.collect_rent', 'W8b ปิดลูกหนี้ยอดสุทธิ',
          jsonb_build_array(
            pg_temp.cash(90000, 0),
            pg_temp.ln('1800', 5000, 0, null, 'operating'),
            pg_temp.ln('1200', 0, 95000, '00000000-0000-0000-0000-00000002a001', 'operating')),
          5, 5000, 'WHT-2569-008b')) $q$,
    'ยอดเต็ม');

  -- (3) รับชำระโดยถูกหักภาษี 5% — ลูกหนี้ต้องปิด **ยอดเต็ม** 100,000
  perform pg_temp.post(pg_temp.entry('inv.collect_rent', 'W8 รับชำระค่าเช่าค้างรับ หัก 5%',
    jsonb_build_array(
      pg_temp.cash(95000, 0),
      pg_temp.ln('1800', 5000, 0, null, 'operating'),
      pg_temp.ln('1200', 0, 100000, '00000000-0000-0000-0000-00000002a001', 'operating')),
    5, 5000, 'WHT-2569-008'));

  select coalesce(sum(l.debit - l.credit), 0) into v_recv
    from sri_os.transaction_lines l
    join sri_os.transactions t on t.id = l.transaction_id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where c.code = '1200' and t.status = 'posted';
  if v_recv <> 0 then
    raise exception 'FAIL: W8 — ลูกหนี้ค่าเช่าต้องปิดสนิทเป็น 0 แต่เหลือ % (ถ้าปิดแค่ยอดสุทธิ จะค้างเท่าภาษีที่ถูกหักตลอดไป เพราะไม่มีใครมาจ่ายส่วนนั้นอีก)', v_recv;
  end if;

  raise notice 'ok W8 · ค่าเช่าที่ตั้งค้างแล้วถูกหักภาษี **ลงได้จริง** · ลูกหนี้ปิดยอดเต็ม 100,000 = เงินสด 95,000 + ภาษี 5,000 · ปิดด้วยยอดสุทธิถูกปฏิเสธ';
end $$;

-- ============================================================
-- W9 · **ข้อ 4 ของผู้ตรวจ** — แก้ยอดภาษีของใบที่ post แล้วย้อนหลัง
--
-- ด่านเดิมผูกแต่ `transaction_lines` → `update transactions set wht_amount = ...`
-- ไม่มีอะไรตรวจเลย เพราะไม่มีบรรทัดไหนถูกแตะ · ฝั่ง personal_flexible แก้ได้
-- แล้วรายงานภาษีกับสมุดบัญชีจะแยกจากกันเงียบๆ
-- ============================================================
do $$
declare t uuid;
begin
  t := pg_temp.post(pg_temp.entry('inc.rent', 'W9 ใบสำหรับทดสอบการแก้ย้อนหลัง',
    jsonb_build_array(
      pg_temp.cash(95000, 0),
      pg_temp.ln('1800', 5000, 0, null, 'operating'),
      pg_temp.ln('4200', 0, 100000, '00000000-0000-0000-0000-00000002a001', 'operating')),
    5, 5000, 'WHT-2569-009'));

  -- ขาควบคุม: การแก้ที่ไม่เกี่ยวกับภาษีต้องยังทำได้ (ไม่งั้นเทสต์ข้างล่างผ่านฟรี)
  perform pg_temp.must_pass('W9a แก้ memo ของใบเดียวกันยังทำได้',
    format($q$ update sri_os.transactions set memo = 'W9 แก้หมายเหตุ' where id = %L $q$, t));

  perform pg_temp.must_fail_like('W9b แก้ยอดภาษีย้อนหลัง',
    format($q$ update sri_os.transactions set wht_amount = 1, wht_rate = 1 where id = %L $q$, t),
    'ยอดภาษี');
  perform pg_temp.must_fail_like('W9c ล้างยอดภาษีทิ้งย้อนหลัง',
    format($q$ update sri_os.transactions set wht_amount = null, wht_rate = null,
                   wht_certificate_no = null where id = %L $q$, t),
    'wht_amount');

  raise notice 'ok W9 · แก้/ล้างยอดภาษีของใบที่ post แล้วย้อนหลังถูกปฏิเสธ (ด่านผูกหัวรายการด้วย ไม่ใช่แต่บรรทัด)';
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
--      ไม่มีขาเงินสด → cash_date ต้องเป็น null (20261009000001_cash_date_invariant)
-- ============================================================
do $$
begin
  perform pg_temp.post(pg_temp.entry('adj.revalue_securities_up', 'R1 ตีราคาหุ้นขึ้น 460,000',
    jsonb_build_array(
      pg_temp.ln('1700', 460000, 0, '00000000-0000-0000-0000-00000002a002', 'none'),
      pg_temp.ln('3400', 0, 460000, '00000000-0000-0000-0000-00000002a002', 'none')),
    null, null, null, null, '00000000-0000-0000-0000-00000002a002'));
  raise notice 'ok R1 · รายการตีราคาลงได้ ทรัพย์ ↔ ส่วนเกินทุน ไม่มีบรรทัดเงินสด';
end $$;

-- ============================================================
-- R2 · **MUTATION** — ด่าน "ตีราคาห้ามแตะ P&L" ต้องแดงจริง
--
-- รอบแรกเทสต์นี้กลายพันธุ์ `cr_coa_code` จาก 3400 → 4900 แล้ว **ด่านไม่ติด**
-- เพราะ `fn_assert_revaluation_no_pl()` ชี้ว่า "ใบนี้เป็นการตีราคา" จากการที่
-- คู่บัญชีแตะ 3400 → ถอด 3400 ออก ด่านก็เลิกมองหมวดนั้นไปเลย
-- (ด่านที่ชี้ตัวเองจากสิ่งที่ถูกแก้ = ด่านที่ปลดได้ด้วยการแก้สิ่งเดียวกัน)
--
-- ปิดด้วยสองด่านที่ทดสอบแยกกันที่นี่:
--   R2a ตั้ง `gain_coa_code = '4900'` โดย **คงคู่บัญชีไว้** → ด่านคู่บัญชี
--       (fn_assert_line_coa_in_rules) ยอมรับบรรทัด 4900 เพราะอยู่ในช่องที่ประกาศไว้
--       → ตัวที่ต้องปฏิเสธคือ trg_lines_s_revaluation_no_pl เท่านั้น
--   R2b ถอด 3400 ออกจากหมวด → **การแก้ตารางกฎเองต้องถูกปฏิเสธ**
--   R2c ตั้งบัญชี P&L ไว้ในช่อง gain ตั้งแต่ตอนแก้ตารางกฎ → ถูกปฏิเสธที่ตารางกฎ
--
-- ถ้าเคสพวกนี้ผ่าน: กำไรขาดทุนจะวิ่งตามค่าเงินทุกเดือนทั้งที่ไม่มีอะไรเกิดขึ้นจริง
-- และใบยังสมดุลทุกบรรทัด ไม่มีอะไรฟ้องเลย (ลูกพี่สั่ง 24/10 ว่า "เด็ดขาด")
-- ============================================================
savepoint before_mutation;
do $$
begin
  -- กลายพันธุ์แบบที่ **ไม่แตะคู่บัญชี** → ด่านคู่บัญชียังยอมรับบรรทัด 4900
  -- ปิด trigger ของตารางกฎชั่วคราวเพื่อให้กลายพันธุ์ลงได้จริง (R2c ทดสอบตัวนั้นแยก)
  --
  -- `set constraints all immediate` ก่อน ALTER โดยจำเป็น: `fn_post_entry` คืนสภาพ
  -- เป็น deferred ตอนจบ → UPDATE ตารางกฎจะ **จองเหตุการณ์ค้าง** ของ
  -- trg_assert_accrual_clearable (constraint trigger ของ txn_types) แล้ว
  -- `alter table ... enable trigger` จะพังด้วย "has pending trigger events"
  -- (รุ่นก่อนของไฟล์นี้ไม่เจอ เพราะมันไม่เคยผ่าน fn_post_entry จึงอยู่ในโหมด immediate)
  set constraints all immediate;
  alter table sri_os.txn_types disable trigger trg_txn_types_revaluation_clean;
  update sri_os.txn_types set gain_coa_code = '4900', loss_coa_code = '5910'
   where code = 'adj.revalue_securities_up';
  alter table sri_os.txn_types enable trigger trg_txn_types_revaluation_clean;
  -- คืนโหมด deferred **ก่อนลงใบ** ไม่งั้นด่านสมดุลยิงตอนใส่บรรทัดแรกที่ใบยังไม่ครบ
  set constraints all deferred;

  if (select gain_coa_code from sri_os.txn_types where code = 'adj.revalue_securities_up') <> '4900' then
    raise exception 'FAIL: R2a — กลายพันธุ์ไม่สำเร็จ เทสต์นี้จึงไม่ได้พิสูจน์อะไร';
  end if;

  perform pg_temp.must_fail_like('R2a รายการตีราคาที่พากำไรเข้า P&L',
    $q$ select pg_temp.post(pg_temp.entry('adj.revalue_securities_up', 'R2a ตีราคาเข้า P&L',
          jsonb_build_array(
            pg_temp.ln('1700', 460000, 0, '00000000-0000-0000-0000-00000002a002', 'none'),
            pg_temp.ln('3400', 0, 300000, '00000000-0000-0000-0000-00000002a002', 'none'),
            pg_temp.ln('4900', 0, 160000, '00000000-0000-0000-0000-00000002a002', 'none')),
          null, null, null, null, '00000000-0000-0000-0000-00000002a002')) $q$,
    'ห้ามเข้างบกำไรขาดทุนเด็ดขาด');
  raise notice 'ok R2a · MUTATION · ด่านบรรทัด "ตีราคาห้ามแตะงบกำไรขาดทุน" แดงจริง';
end $$;
-- คืนตารางกฎให้กลับเป็นของจริง **ก่อน** เคสถัดไป
rollback to savepoint before_mutation;

do $$
begin
  if (select gain_coa_code from sri_os.txn_types where code = 'adj.revalue_securities_up') is not null then
    raise exception 'FAIL: R2a — ตารางกฎยังค้างสภาพกลายพันธุ์หลัง rollback';
  end if;

  -- R2b · ถอด 3400 ออกจากหมวดตีราคา → การแก้ตารางกฎต้องถูกปฏิเสธเอง
  perform pg_temp.must_fail_like(
    'R2b ถอด 3400 ออกจากหมวดตีราคา',
    $q$ update sri_os.txn_types set cr_coa_code = '4900' where code = 'adj.revalue_securities_up' $q$,
    'จะเปลี่ยนให้ไม่แตะ 3400 ไม่ได้');

  -- R2c · ตั้งบัญชี P&L ไว้ในช่อง gain/loss ของหมวดตีราคา → ถูกปฏิเสธที่ตารางกฎ
  perform pg_temp.must_fail_like(
    'R2c ตั้งบัญชีรายได้ไว้ในช่อง gain ของหมวดตีราคา',
    $q$ update sri_os.txn_types set gain_coa_code = '4900' where code = 'adj.revalue_commodity_up' $q$,
    'ห้ามเข้างบกำไรขาดทุนเด็ดขาด');
  perform pg_temp.must_fail_like(
    'R2d ตั้งบัญชีค่าใช้จ่ายไว้ในช่อง accrual ของหมวดตีราคา',
    $q$ update sri_os.txn_types set accrual_coa_code = '5900' where code = 'adj.revalue_commodity_down' $q$,
    'ห้ามเข้างบกำไรขาดทุนเด็ดขาด');

  -- แต่การแก้ที่ไม่เกี่ยวกับ P&L ต้องยังทำได้ (กันแน่นเกิน = seed รอบหน้าพัง)
  perform pg_temp.must_pass(
    'R2e แก้คำอธิบายของหมวดตีราคายังทำได้',
    $q$ update sri_os.txn_types set caution_th = 'ทดสอบ' where code = 'adj.revalue_securities_up' $q$);
  -- และหมวดที่ไม่ใช่การตีราคา ยังตั้งบัญชี P&L ได้ตามปกติ
  perform pg_temp.must_pass(
    'R2f หมวดอื่นยังตั้งบัญชีกำไร/ขาดทุนได้',
    $q$ update sri_os.txn_types set gain_coa_code = '4300' where code = 'inv.sell_re' $q$);

  raise notice 'ok R2b–R2f · ตารางกฎกันการปลดด่านทั้งสองทาง และไม่กันแน่นเกิน';
end $$;
rollback to savepoint before_mutation;

-- ============================================================
-- R3 · ต้นทุนทรัพย์ต้องเป็น **ต้นทุนเดิม** ไม่รวมใบตีราคา
--      ไม่งั้นกำไรจากการขายต่ำกว่าจริงทุกใบ
--      (ฉากเต็มของต้นทุนถัวเฉลี่ย + ล้างส่วนเกินทุนตามสัดส่วนอยู่ที่
--       zz_asset_cost_basis_test.sql · ที่นี่คุมแค่ว่าใบตีราคาไม่เป็นต้นทุน)
-- ============================================================
do $$
declare v_cost numeric;
begin
  -- ซื้อหุ้น 1,000,000 (ใบจริง) — ต้นทุนต้องเป็นก้อนนี้เท่านั้น
  perform pg_temp.post(pg_temp.entry('inv.buy_securities', 'R3 ซื้อหุ้น 1,000,000',
    jsonb_build_array(
      pg_temp.ln('1700', 1000000, 0, '00000000-0000-0000-0000-00000002a002', 'investing'),
      pg_temp.ln('1100', 0, 1000000, null, 'investing', '00000000-0000-0000-0000-00000002b001')),
    null, null, null, '2026-10-31', '00000000-0000-0000-0000-00000002a002'));

  -- ใบตีราคา 460,000 ของ R1 ยังอยู่ในสมุด → ถ้า fn_asset_cost_basis นับมันด้วย
  -- ต้นทุนจะกลายเป็น 1,460,000
  select sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000002a002') into v_cost;
  if v_cost <> 1000000 then
    raise exception 'FAIL: R3 — ต้นทุนทรัพย์ควรเป็น 1,000,000 (ต้นทุนเดิม) แต่ได้ % · ใบตีราคาถูกนับเป็นต้นทุน แล้วกำไรจากการขายจะต่ำกว่าจริง', v_cost;
  end if;
  raise notice 'ok R3 · fn_asset_cost_basis ไม่นับใบตีราคา (ต้นทุน 1,000,000 ไม่ใช่ 1,460,000)';
end $$;

-- ============================================================
-- R4 · **ค่าเช่าค้างรับที่ผูกทรัพย์ ห้ามกลายเป็นต้นทุนของทรัพย์**
--
-- ฟอร์มผูกทรัพย์กับรายการค่าเช่า (ซึ่งถูก · D-112 ข้อ 4 ต้องการรายงานรายทรัพย์)
-- → บรรทัด Dr 1200 ลูกหนี้ค่าเช่า มี asset_id ติดมาด้วย
-- ถ้า fn_asset_cost_basis นับบัญชีสินทรัพย์ทุกตัวเป็นต้นทุน **ต้นทุนคอนโดจะบวม
-- เท่าค่าเช่าที่ตั้งค้างทุกเดือน** แล้วยุบกลับตอนเก็บเงินได้ = ต้นทุนแกว่งตาม
-- ลูกหนี้ โดยทุกใบสมดุลและไม่มีอะไรฟ้อง (W8 ลงใบพวกนั้นไว้แล้ว)
-- ============================================================
do $$
declare v_cost numeric;
begin
  select sri_os.fn_asset_cost_basis('00000000-0000-0000-0000-00000002a001') into v_cost;
  if v_cost <> 0 then
    raise exception 'FAIL: R4 — คอนโดยังไม่มีใบซื้อในสมุด ต้นทุนต้องเป็น 0 แต่ได้ % · บรรทัดลูกหนี้/ภาษีถูกหักที่ผูกทรัพย์ถูกนับเป็นต้นทุน', v_cost;
  end if;
  raise notice 'ok R4 · ลูกหนี้ค่าเช่าและภาษีถูกหักที่ผูกทรัพย์ ไม่ถูกนับเป็นต้นทุนของทรัพย์';
end $$;

-- ============================================================
-- R5 · ใบขายจริง — ล้างส่วนเกินทุนออกพร้อมกัน และรับรู้กำไรเข้า P&L ได้
--
-- ใบนี้แตะ **ทั้ง** 3400 (ล้างส่วนเกินทุน) และบัญชีกำไรจากการขาย
-- ซึ่งต้องทำได้: ด่านการตีราคาไม่ติด เพราะหมวดขายไม่ได้มี 3400 ใน dr/cr
-- ถ้าด่านกันแน่นเกิน การขายทรัพย์ที่เคยตีราคาจะทำไม่ได้เลย
--
-- ขายทั้งก้อน (ต้นทุน 1,000,000 ทั้งหมด) จึงล้างส่วนเกินทุนได้ทั้ง 460,000
-- = 100% ของที่ถืออยู่ ซึ่งตรงกับด่านสัดส่วน (D-112) พอดี
-- ============================================================
do $$
declare v_cost numeric; v_surplus numeric;
begin
  perform pg_temp.post(pg_temp.entry('inv.sell_securities', 'R5 ขายหุ้นทั้งก้อน 1,500,000',
    jsonb_build_array(
      pg_temp.ln('1100', 1500000, 0, null, 'investing', '00000000-0000-0000-0000-00000002b001'),
      pg_temp.ln('1700', 0, 1000000, '00000000-0000-0000-0000-00000002a002', 'investing'),
      pg_temp.ln('4900', 0, 500000, '00000000-0000-0000-0000-00000002a002'),
      pg_temp.ln('3400', 460000, 0, '00000000-0000-0000-0000-00000002a002'),
      pg_temp.ln('1700', 0, 460000, '00000000-0000-0000-0000-00000002a002', 'investing')),
    null, null, null, '2026-10-31', '00000000-0000-0000-0000-00000002a002'));

  select cost_basis, surplus into v_cost, v_surplus
    from sri_os.fn_asset_ledger_parts('00000000-0000-0000-0000-00000002a002');
  if v_cost <> 0 or v_surplus <> 0 then
    raise exception 'FAIL: R5 — ขายหมดแล้วต้นทุนและส่วนเกินทุนต้องเหลือ 0 ทั้งคู่ (ได้ % และ %)', v_cost, v_surplus;
  end if;
  raise notice 'ok R5 · ใบขายล้างส่วนเกินทุน (3400) และรับรู้กำไรเข้า P&L ได้พร้อมกัน · ต้นทุนและส่วนเกินทุนเหลือศูนย์พอดี';
end $$;

-- ============================================================
-- R6 · บรรทัด 3400 บนหมวดที่ไม่ใช่ทั้งตีราคาและไม่ใช่การขาย → ปฏิเสธ
--      กันช่องที่ใครเอาส่วนเกินทุนไปปั่นกับหมวดอื่น
-- ============================================================
do $$
begin
  perform pg_temp.must_fail_like('R6 บรรทัด 3400 บนหมวดค่าเช่า',
    $q$ select pg_temp.post(pg_temp.entry('inc.rent', 'R6 ปั่นส่วนเกินทุนจากค่าเช่า',
          jsonb_build_array(
            pg_temp.cash(100000, 0),
            pg_temp.ln('3400', 0, 100000, '00000000-0000-0000-0000-00000002a001', 'operating')))) $q$,
    '3400');
  raise notice 'ok R6 · บรรทัด 3400 ลงได้เฉพาะหมวดตีราคาและหมวดที่รับรู้กำไร/ขาดทุนจากการขาย';
end $$;

do $$ begin raise notice '=== WHT + FX (D-111 ข้อ 1 และ 2) ผ่านทั้งหมด — ทุกใบเดินผ่าน fn_post_entry ==='; end $$;

rollback;
