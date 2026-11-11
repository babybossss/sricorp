-- ============================================================
-- SRI OS · ปิดรูของประตู fn_post_entry() ที่ผู้ตรวจพิสูจน์ว่าเปิดอยู่ (7 ข้อ)
--
-- ที่มา: ไฟล์ 20261008000008 สร้างประตูเดียวที่เขียนลง ledger ได้ แต่ประตูนั้น
--   **เชื่อ payload** · ผู้ตรวจยิงเข้าไปตรงๆ แล้วสำเร็จทั้งหมดต่อไปนี้:
--     A6/A6b  เงิน 70,000 เข้าบัญชีของผู้ถือที่ผู้กดไม่มีสิทธิ์เห็นด้วยซ้ำ
--     A1      รายการข้ามผู้ถือขาเดียว (1310 ค้างข้างเดียว ไม่มี 2310 คู่)
--     A2      fin.loan_bank ลง Cr 4200 รายได้ค่าเช่า = **เงินกู้กลายเป็นรายได้**
--     A8      12000 กับ 12000.0 = fingerprint ต่างกัน → กดซ้ำแล้วลงสองใบ
--     A13b    created_by ปลอมได้ด้วยสองคำสั่งในธุรกรรมเดียว
--     A7      bank_account_id ติดอยู่บนบรรทัดรายได้ 4200
--
-- หลักที่ใช้แก้ (แก้คำสั่งที่กำกวมของรอบก่อน):
--   ประตู **ห้ามเขียนกฎซ้ำ** (ห้ามคิดเองว่าหมวดนี้ควรเดบิตอะไร)
--   แต่ **ต้องตรวจว่าสิ่งที่ส่งมาตรงกับกฎ** โดย **อ่านจากตารางกฎ** (`sri_os.txn_types`
--   คอลัมน์ dr/cr/gain/loss/interest/accrual) ซึ่งเป็นการอ่านแหล่งความจริงเดียว
--   ไม่ใช่การสร้างแหล่งที่สอง · ประตูที่ไม่ตรวจอะไรเลยคือประตูที่ไม่มีอยู่
--
-- ทำอะไร (ทั้งหมดเป็น create or replace ทับของเดิม · ไม่แก้ไฟล์ที่ apply แล้ว):
--   1 · fn_canonical_payload()        — ทำ payload ให้เป็นรูปเดียวก่อนคิด fingerprint (ข้อ 4)
--   2 · fn_assert_line_bank_owner()   — trigger: บัญชีธนาคารต้องเป็นของผู้ถือของรายการ (ข้อ 1)
--   3 · fn_assert_intercompany_pair() — constraint trigger: ข้ามผู้ถือต้องมาครบคู่
--                                       และบัญชีระหว่างกันต้องจับคู่กันจริง (ข้อ 2)
--   4 · fn_txn_system_columns()       — เติมบรรทัดเดียว: created_by = auth.uid() (ข้อ 5)
--   5 · fn_post_entry()               — เทียบคู่บัญชีกับตารางกฎ (ข้อ 3) ·
--                                       bank_account_id ได้เฉพาะขาเงินสด (ข้อ 7) ·
--                                       fingerprint จากรูปที่ normalise แล้ว (ข้อ 4)
--   6 · comment on                    — แก้คอมเมนต์ที่ขัดกับโค้ด (ข้อ 6)
--
-- สิ่งที่ไฟล์นี้ **ไม่ได้** ปิด และต้องรู้ไว้ (ห้ามเข้าใจว่าปิดหมดแล้ว):
--   (ก) ด่าน "คู่บัญชีตรงหมวด" กับ "bank_account_id เฉพาะขาเงินสด" อยู่ **ในประตู**
--       ไม่ใช่ trigger บนตาราง → การ INSERT ตรงเข้า transaction_lines ผ่าน PostgREST
--       ยังเลี่ยงได้ · ทำเป็น trigger ไม่ได้ในรอบนี้เพราะเทสต์ที่ apply แล้วหลายไฟล์
--       ใส่คู่บัญชีสมมติ (`where code not like '11%' limit 2`) และผูก bank_account_id
--       กับบรรทัดที่ไม่ใช่เงินสดโดยตั้งใจ (zz_asset_permissions_test.sql:796)
--       → ถ้าย้ายขึ้น trigger ต้องแก้ fixture พวกนั้นก่อน (ให้ลูกพี่ตัดสิน)
--   (ข) ขาที่ไม่ใช่เงินสดของรายการข้ามผู้ถือ เทียบได้แค่ **ประเภทบัญชี** ที่ตารางกฎ
--       กำหนดให้ลักษณะนั้น ยังล็อกเป็นรหัสตรงไม่ได้ — เหตุผลอยู่ที่หัวข้อ 5.3
--   (ค) D-095 (ไฟล์แนบเป็นชื่อไฟล์ลอยๆ) ยังเปิดอยู่ตามที่ decision นั้นตั้งใจ
--
-- ย้อนกลับ (rollback):
--   -- drop trigger  if exists trg_line_bank_owner on sri_os.transaction_lines;
--   -- drop function if exists sri_os.fn_assert_line_bank_owner();
--   -- drop trigger  if exists trg_intercompany_pair on sri_os.transactions;
--   -- drop function if exists sri_os.fn_assert_intercompany_pair();
--   -- drop function if exists sri_os.fn_canonical_payload(jsonb);
--   -- แล้ว **รัน 20261008000008_post_entry_rpc.sql + 20261007000000_line_integrity_and_view_rls.sql
--   --     ซ้ำทั้งไฟล์** เพื่อคืน fn_post_entry() / fn_txn_system_columns() รุ่นก่อนหน้า
--   -- ย้อนแล้วได้สภาพเดิมคือ: ลงเงินเข้าบัญชีของผู้ถืออื่นได้ · เงินกู้ลงเป็นรายได้ได้ ·
--   --   ข้ามผู้ถือขาเดียวได้ · created_by ปลอมได้ — ไม่แนะนำให้ย้อน
--
-- idempotent: create or replace · drop trigger if exists ก่อน create ·
--   ไม่มี insert/alter ที่ทำซ้ำไม่ได้ · รันไฟล์นี้สองรอบได้ผลเท่ากัน
-- ============================================================

set search_path = sri_os, public;

-- ------------------------------------------------------------
-- 1 · fn_canonical_payload — ทำ payload ให้เป็นรูปเดียวก่อนคิด fingerprint (ข้อ 4)
--
-- ปัญหาที่ผู้ตรวจเจอ: fingerprint เดิมคิดจาก `p_payload::text` ตรงๆ
--   jsonb ทำให้ **ลำดับคีย์และช่องว่าง** เป็นรูปเดียวให้แล้ว แต่ **ตัวเลขไม่**
--   → 12000 กับ 12000.0 เป็นคนละ fingerprint แล้วกดซ้ำได้สองใบ
--
-- ทำให้เป็นรูปเดียวตาม **ความหมายที่ฟังก์ชันใช้ค่านั้นจริงๆ** (ไม่ใช่ตามหน้าตา JSON):
--   - ตัวเลข → trim_scale(numeric) เป็นข้อความ  (12000 · 12000.0 · 12000.00 · 1.2e4 = เดียวกัน)
--   - ค่า null และสตริงว่าง → **ตัดคีย์ทิ้ง** เพราะทุกจุดในฟังก์ชันอ่านด้วย
--     nullif(x, '') แล้วถือว่า "ไม่ได้ส่งมา" อยู่แล้ว (null vs ไม่ส่งคีย์ = เดียวกัน)
--   - boolean / สตริง → รูปข้อความของมัน (true กับ "true" ลง memo ได้ค่าเดียวกัน
--     ถ้า fingerprint ต่างกัน จะลงสองใบที่หน้าจออ่านเหมือนกันเป๊ะ)
--   - สตริงรูป uuid → ตัวเล็ก (ตัวใหญ่/ตัวเล็กcast เป็น uuid ตัวเดียวกัน)
--   - ลำดับใน array **คงไว้** (ลำดับขาของผู้ถือมีความหมาย: ขาแรก = ขาของผู้กด)
--
-- รูปที่ยัง "ตัดสินใจไม่ normalise" โดยตั้งใจ: ลำดับไฟล์แนบ (attachments)
--   เพราะการกดรัวครั้งที่สองส่งลำดับเดิมอยู่แล้ว การเรียงใหม่แปลว่ามีคนแก้คำขอ
--
-- ไม่ใช่ security definer: ไม่แตะตารางอะไรเลย · immutable เพราะขึ้นกับ input เท่านั้น
-- ------------------------------------------------------------
create or replace function fn_canonical_payload(p jsonb) returns jsonb
language plpgsql immutable set search_path = '' as $fn$
declare
  v_out  jsonb;
  v_text text;
  k text; v jsonb;
begin
  if p is null then return null; end if;

  case jsonb_typeof(p)
    when 'object' then
      v_out := '{}'::jsonb;
      for k, v in select key, value from jsonb_each(p) order by key loop
        -- null / '' = "ไม่ได้ส่งมา" ตามที่ฟังก์ชันอ่านจริง → ตัดทิ้งให้เท่ากัน
        if jsonb_typeof(v) = 'null' then continue; end if;
        if jsonb_typeof(v) = 'string' and (v #>> '{}') = '' then continue; end if;
        v_out := v_out || jsonb_build_object(k, sri_os.fn_canonical_payload(v));
      end loop;
      return v_out;

    when 'array' then
      return coalesce((
        select jsonb_agg(sri_os.fn_canonical_payload(e.value) order by e.ord)
          from jsonb_array_elements(p) with ordinality as e(value, ord)
         where jsonb_typeof(e.value) <> 'null'), '[]'::jsonb);

    when 'number' then
      return to_jsonb(trim_scale((p #>> '{}')::numeric)::text);

    else
      v_text := p #>> '{}';
      if v_text ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        v_text := lower(v_text);
      end if;
      return to_jsonb(v_text);
  end case;
end $fn$;

comment on function fn_canonical_payload(jsonb) is
  'ทำ payload ของ fn_post_entry ให้เป็นรูปเดียวก่อนคิด fingerprint · ตัวเลข trim_scale · null/สตริงว่างตัดทิ้ง · uuid ตัวเล็ก · ลำดับ array คงไว้ · เพื่อให้ 12000 กับ 12000.0 นับเป็นการกดซ้ำครั้งเดียว';

-- ------------------------------------------------------------
-- 2 · ข้อ 1 + 7 · บัญชีธนาคารต้องเป็นของผู้ถือของรายการนั้น
--
-- เครื่องยนต์กันไว้แล้วที่ src/lib/ledger/guards.ts (assertBankBelongsTo) แต่ประตู
--   ไม่กัน · ผู้ตรวจลง Dr 1100 70,000 เข้า SRI-SCB ของ SRI Corporation ในรายการ
--   ของธนากรได้สำเร็จ — เงินไปอยู่ในบัญชีของผู้ถือที่ผู้กด **มองไม่เห็นด้วยซ้ำ**
--   fn_health_check จับไม่ได้เพราะตรวจแค่ null
--
-- เป็น **trigger บนตาราง** ไม่ใช่ด่านในประตู เพราะกฎนี้ไม่ขึ้นกับทางเข้า:
--   ลง REST ตรงก็ต้องกัน (บทเรียนข้อ 6 ในระดับฐานข้อมูล)
--
-- security definer ด้วยเหตุผลเดียวกับ fn_assert_bank_account_open / fn_assert_line_writable:
--   ต้องได้ **คำตอบจริง** ไม่ใช่ได้ null แล้วหลุดด่านเพราะผู้เรียกมองแถวนั้นไม่เห็น
-- ไม่เรียก fn_can เลย — กฎเงินใช้กับทุกคนเท่ากัน ปิดจากหน้า Settings ไม่ได้
-- ------------------------------------------------------------
create or replace function fn_assert_line_bank_owner() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_bank_owner uuid;
  v_bank_label text;
  v_txn_owner  uuid;
begin
  if new.bank_account_id is null then return new; end if;

  select b.owner_id, b.display_name into v_bank_owner, v_bank_label
    from sri_os.bank_accounts b where b.id = new.bank_account_id;
  if v_bank_owner is null then
    raise exception 'บรรทัดเงินสดผูกกับบัญชีที่ไม่มีอยู่จริง (bank_account_id %)', new.bank_account_id;
  end if;

  select t.owner_id into v_txn_owner
    from sri_os.transactions t where t.id = new.transaction_id;
  if v_txn_owner is null then
    raise exception 'บรรทัดบัญชีไม่มีหัวรายการอยู่จริง (transaction_id %)', new.transaction_id;
  end if;

  if v_txn_owner <> v_bank_owner then
    raise exception 'บัญชี "%" เป็นของ % แต่รายการนี้เป็นของ % — ลงเงินเข้าบัญชีของผู้ถืออื่นไม่ได้ (เงินจะไปโผล่ในงบของคนอื่น) · โอนข้ามผู้ถือต้องแตกเป็นสองรายการ ฝ่ายละหนึ่ง',
      v_bank_label,
      coalesce((select o.name_th from sri_os.owners o where o.id = v_bank_owner), v_bank_owner::text),
      coalesce((select o.name_th from sri_os.owners o where o.id = v_txn_owner),  v_txn_owner::text);
  end if;

  return new;
end $fn$;

comment on function fn_assert_line_bank_owner() is
  'ข้อ 1 ของผู้ตรวจ · bank_account_id ของทุกบรรทัดต้องเป็นบัญชีของ owner_id ของ transaction นั้น · trigger ไม่ใช่ด่านในประตู เพราะ REST ตรงก็ต้องกัน · security definer เพื่อให้ได้คำตอบจริงแม้ผู้เรียกมองแถวบัญชีนั้นไม่เห็น';

drop trigger if exists trg_line_bank_owner on transaction_lines;
create trigger trg_line_bank_owner
  before insert or update on transaction_lines
  for each row execute function fn_assert_line_bank_owner();

-- ------------------------------------------------------------
-- 3 · ข้อ 2 · ข้ามผู้ถือต้องมาครบคู่ **และบัญชีระหว่างกันต้องจับคู่กันจริง**
--
-- ที่ผู้ตรวจทำได้: is_intercompany = true · nature = loan · **ขาเดียว**
--   → 1310 ลูกหนี้ระหว่างกันค้างข้างเดียว ไม่มี 2310 คู่
--   ผลคือ งบรวมตัดรายการระหว่างกันไม่ลง (Invariant 6) และเงินสดรวม ≠ ผลรวมบัญชี
--
-- วิธีตรวจ (ไม่ใช่ "นับว่ามีสอง transaction"):
--   (ก) ขาคู่ต้องอยู่ใน **ธุรกรรมฐานข้อมูลเดียวกัน** (write_txn_id เท่ากัน)
--       — ระบบตั้งเอง ปลอมไม่ได้ · และตรงกับความจริงที่ fn_post_entry ลงสองขาในคำขอเดียว
--   (ข) **นับให้เท่ากัน** ไม่ใช่แค่ "มีอยู่": จำนวนขา A→B ที่ยอดเท่ากัน
--       ต้องเท่ากับจำนวนขา B→A ที่ยอดเท่ากัน · ถ้าใช้ exists ขาที่สามจะจับคู่
--       กับขาเดิมซ้ำได้ แล้วเงินข้างหนึ่งหายไปโดยทุกใบยังสมดุลในตัวเอง
--   (ค) **บัญชีระหว่างกันต้องหักกลบกัน**: ถ้าข้างหนึ่งลงบัญชีฝ่ายจ่ายของลักษณะนั้น
--       อีกข้างต้องลงบัญชีฝ่ายรับในยอดเท่ากันและด้านตรงข้าม (1310 ↔ 2310 · 1710 ↔ 3100 ·
--       3200 ↔ 4410) · ใช้ผลรวม (debit − credit) จึงใช้ได้ทั้งรายการปกติและรายการกลับรายการ
--       ที่สลับด้าน
--
-- **ตารางคู่บัญชีระหว่างกันในฟังก์ชันนี้เป็นสำเนาของ `src/lib/rules/intercompany.ts`**
--   เหมือนที่ `sri_os.txn_types` เป็นสำเนาของ `tx-rules.ts` · `npm run sync:rules`
--   **ยังไม่ครอบ** ตารางนี้ → ถ้า intercompany.ts เพิ่มลักษณะใหม่ ต้องมาแก้ที่นี่ด้วย
--   guard ท้ายไฟล์จับได้เฉพาะลักษณะที่ constraint ของตาราง transactions อนุญาต
--   แต่ยังไม่มีในสำเนานี้ (= fail closed ตอน migrate ไม่ใช่ตอนผู้ใช้กดบันทึก)
--
-- constraint trigger แบบ deferred เพราะตอนลงขาแรก ขาที่สองยังไม่เกิด
--   fn_post_entry สั่ง `set constraints all immediate` ตอนท้าย → ผู้กดได้ข้อความทันที
-- ------------------------------------------------------------
create or replace function fn_assert_intercompany_pair() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_p     text;
  v_r     text;
  v_amt   numeric;
  v_same  int;
  v_other int;
  v_sp numeric; v_sr numeric; v_op numeric; v_or numeric;
begin
  if not new.is_intercompany then return null; end if;

  if new.counter_owner_id is null or new.intercompany_nature is null then
    -- constraint intercompany_needs_nature กันไว้แล้ว · ย้ำเพื่อให้ข้อความอ่านรู้เรื่อง
    raise exception 'รายการข้ามผู้ถือต้องมีทั้งผู้ถืออีกฝ่ายและลักษณะรายการ (รายการ %)', new.id;
  end if;
  if new.counter_owner_id = new.owner_id then
    raise exception 'รายการข้ามผู้ถือชี้กลับมาที่ผู้ถือเดิม (%) — ถ้าเป็นการย้ายกระเป๋าในคนเดียวกัน ไม่ใช่รายการข้ามผู้ถือ',
      new.owner_id;
  end if;

  -- สำเนาคู่บัญชีระหว่างกันจาก src/lib/rules/intercompany.ts (ดูคำเตือนข้างบน)
  select x.payer, x.receiver into v_p, v_r
    from (values ('advance', '1310', '2310'),
                 ('loan',    '1310', '2310'),
                 ('capital', '1710', '3100'),
                 ('dividend','3200', '4410')) as x(nature, payer, receiver)
   where x.nature = new.intercompany_nature;
  if v_p is null then
    raise exception 'ลักษณะรายการข้ามผู้ถือ "%" ยังไม่มีคู่บัญชีระหว่างกันในสำเนาของ DB — เพิ่มใน 20261008000011 ให้ตรงกับ src/lib/rules/intercompany.ts ก่อนใช้',
      new.intercompany_nature;
  end if;

  select coalesce(sum(l.debit), 0) into v_amt
    from sri_os.transaction_lines l where l.transaction_id = new.id;

  -- (ก)+(ข) ขาคู่ในธุรกรรมเดียวกัน · นับสองทางให้เท่ากัน
  with legs as (
    select t.owner_id,
           (select coalesce(sum(l.debit), 0) from sri_os.transaction_lines l
             where l.transaction_id = t.id) as amt
      from sri_os.transactions t
     where t.write_txn_id is not null
       and t.write_txn_id = new.write_txn_id
       and t.is_intercompany
       and t.intercompany_nature = new.intercompany_nature
       and t.txn_type_code = new.txn_type_code
       and t.doc_date = new.doc_date
       and t.owner_id in (new.owner_id, new.counter_owner_id)
       and t.counter_owner_id in (new.owner_id, new.counter_owner_id)
  )
  select count(*) filter (where owner_id = new.owner_id         and amt = v_amt),
         count(*) filter (where owner_id = new.counter_owner_id and amt = v_amt)
    into v_same, v_other
    from legs;

  if v_same <> v_other then
    raise exception 'รายการข้ามผู้ถือต้องมาครบคู่ในคำขอเดียว (ขาออก + ขาเข้า) — ยอด % มีขาของผู้ถือ % อยู่ % ขา แต่มีขาคู่ของ % อยู่ % ขา · ขาเดียวแปลว่าเงินหายไปข้างหนึ่งและงบรวมตัดรายการระหว่างกันไม่ลง',
      v_amt,
      coalesce((select o.name_th from sri_os.owners o where o.id = new.owner_id), new.owner_id::text),
      v_same,
      coalesce((select o.name_th from sri_os.owners o where o.id = new.counter_owner_id), new.counter_owner_id::text),
      v_other;
  end if;

  -- (ค) บัญชีระหว่างกันต้องหักกลบกันข้ามขา
  select
    coalesce(sum(case when t.owner_id = new.owner_id         and c.code = v_p then l.debit - l.credit else 0 end), 0),
    coalesce(sum(case when t.owner_id = new.owner_id         and c.code = v_r then l.debit - l.credit else 0 end), 0),
    coalesce(sum(case when t.owner_id = new.counter_owner_id and c.code = v_p then l.debit - l.credit else 0 end), 0),
    coalesce(sum(case when t.owner_id = new.counter_owner_id and c.code = v_r then l.debit - l.credit else 0 end), 0)
    into v_sp, v_sr, v_op, v_or
    from sri_os.transactions t
    join sri_os.transaction_lines l on l.transaction_id = t.id
    join sri_os.chart_of_accounts c on c.id = l.coa_id
   where t.write_txn_id is not null
     and t.write_txn_id = new.write_txn_id
     and t.is_intercompany
     and t.intercompany_nature = new.intercompany_nature
     and t.txn_type_code = new.txn_type_code
     and t.doc_date = new.doc_date
     and t.owner_id in (new.owner_id, new.counter_owner_id)
     and t.counter_owner_id in (new.owner_id, new.counter_owner_id);

  if v_sp + v_or <> 0 or v_sr + v_op <> 0 then
    raise exception 'บัญชีระหว่างกันของรายการข้ามผู้ถือไม่จับคู่กัน (ลักษณะ % ต้องเป็น % ข้างหนึ่งกับ % อีกข้างในยอดเท่ากัน · ได้ %=% / %=% ฝั่งหนึ่ง และ %=% / %=% ฝั่งตรงข้าม) — ถ้าไม่หักกลบกัน งบรวมจะตัดรายการระหว่างกันไม่ลง',
      new.intercompany_nature, v_p, v_r, v_p, v_sp, v_r, v_sr, v_p, v_op, v_r, v_or;
  end if;

  return null;
end $fn$;

comment on function fn_assert_intercompany_pair() is
  'ข้อ 2 ของผู้ตรวจ · รายการข้ามผู้ถือต้องมาครบคู่ในธุรกรรมเดียวกัน (นับสองทางให้เท่ากัน ไม่ใช่ exists) และบัญชีระหว่างกันต้องหักกลบกันข้ามขา (1310↔2310 · 1710↔3100 · 3200↔4410) · **ตารางคู่บัญชีในฟังก์ชันเป็นสำเนาของ src/lib/rules/intercompany.ts ซึ่ง sync:rules ยังไม่ครอบ**';

drop trigger if exists trg_intercompany_pair on transactions;
create constraint trigger trg_intercompany_pair
  after insert or update on transactions
  deferrable initially deferred
  for each row execute function fn_assert_intercompany_pair();

-- ------------------------------------------------------------
-- 4 · ข้อ 5 · created_by ปลอมไม่ได้
--
-- ของเดิม (20261007000000) ทับ created_at / write_txn_id ตอน INSERT แต่ **ไม่ทับ
--   created_by** → ผู้ที่ยิง SQL สองคำสั่งในธุรกรรมเดียวใส่ชื่อคนอื่นเป็นคนคีย์ได้
--   (ผู้ตรวจพิสูจน์แล้วด้วย attack5.sql · ผ่าน PostgREST ทำไม่ได้ แต่ไม่มีเหตุผลให้เหลือไว้)
--
-- ทับเฉพาะคำขอที่ **อยู่ใต้ RLS จริง** (row_security_active) และล็อกอินอยู่
--   เพราะ migration / seed / fixture ของเทสต์รันในฐานะเจ้าของตาราง (RLS ไม่บังคับ)
--   และตั้ง created_by เป็นของผู้ใช้คนอื่นโดยตั้งใจ — เช่น roles_permissions_test
--   สร้างรายการ "ที่ mgr ลงเอง" เพื่อทดสอบขอบเขตการมองเห็น · ถ้าทับหมดทุกทาง
--   fixture พวกนั้นจะกลายเป็นของผู้ใช้ที่ login ค้างอยู่ใน GUC แล้วเทสต์ขอบเขต
--   การมองเห็นจะเพี้ยนทั้งชุด (เจอจริงตอนรัน harness: 9.2 Manager เห็น 4 ใบ)
--   เลือกเงื่อนไข row_security_active ไม่ใช่ชื่อ role เพราะไม่ผูกกับชื่อที่ Supabase ตั้ง
--   ด่านที่ต้องปิดคือ "ผู้ใช้แอปที่ล็อกอินแล้วยิง SQL เอง" ซึ่งอยู่ใต้ RLS เสมอ
--   (service_role / postgres ข้าม RLS ได้ทั้งตารางอยู่แล้ว การทับที่นี่ไม่เพิ่มอะไรให้มัน)
-- ที่เหลือในฟังก์ชันเหมือนเดิมทุกบรรทัด — คัดลอกมาเพราะไฟล์เดิมแก้ไม่ได้
-- ------------------------------------------------------------
create or replace function fn_txn_system_columns() returns trigger
language plpgsql set search_path = '' as $fn$
begin
  if tg_op = 'INSERT' then
    new.created_at   := now();                   -- ทับค่าที่ส่งมา ไม่ว่าจะส่งอะไร
    new.write_txn_id := pg_current_xact_id();    -- ธุรกรรมบนสุด · subtransaction ก็ได้ค่านี้
    -- ข้อ 5: คนคีย์คือคนที่ล็อกอินอยู่ ไม่ใช่ค่าที่ payload ส่งมา
    if auth.uid() is not null
       and pg_catalog.row_security_active('sri_os.transactions'::regclass) then
      new.created_by := auth.uid();
    end if;
    return new;
  end if;

  if new.owner_id is distinct from old.owner_id then
    raise exception 'กฎ 1 transaction = 1 owner: ย้ายผู้ถือของรายการที่บันทึกแล้วด้วย UPDATE ไม่ได้ (% → %) ให้ reverse แล้วลงใหม่ในชื่อผู้ถือที่ถูกต้อง',
      old.owner_id, new.owner_id;
  end if;
  new.created_at   := old.created_at;   -- เงียบๆ ไม่ให้แก้ · ไม่ใช่ข้อมูลที่ผู้ใช้กรอก
  new.id           := old.id;
  new.write_txn_id := old.write_txn_id; -- UPDATE ห้ามทำให้หัวรายการ "กลายเป็นของธุรกรรมนี้"
  -- คนคีย์เปลี่ยนย้อนหลังไม่ได้ (เงื่อนไขเดียวกับตอน INSERT: เฉพาะคำขอที่อยู่ใต้ RLS
  -- เพื่อไม่ปิดทางให้ migration ที่ต้องกู้ข้อมูลผิดในอนาคต ซึ่งเป็นไฟล์ใน git อยู่แล้ว)
  if pg_catalog.row_security_active('sri_os.transactions'::regclass) then
    new.created_by := old.created_by;
  end if;
  return new;
end $fn$;

comment on function fn_txn_system_columns() is
  'คอลัมน์ที่ระบบตั้งเองของ transactions: created_at · write_txn_id · **created_by = auth.uid()** (ข้อ 5 ของผู้ตรวจ) · owner_id ย้ายด้วย UPDATE ไม่ได้';

-- ------------------------------------------------------------
-- 5 · fn_post_entry — ประตูที่ **ตรวจ** ว่าสิ่งที่ส่งมาตรงกับตารางกฎ
--
--   5.1 ข้อ 3: คู่บัญชีของทุกบรรทัดต้องอยู่ในชุดบัญชีที่หมวดนั้นใช้ได้
--       ชุดนั้น **อ่านจาก txn_types** (dr/cr/gain/loss/interest/accrual) ไม่ได้พิมพ์มือ
--       → ครอบบรรทัดที่เครื่องยนต์เติมให้ครบทุกสาขาที่ posting.ts สร้างได้:
--         ปกติสองบรรทัด (dr/cr) · ค้างรับ-ค้างจ่าย (ขาเงินสดกลายเป็น accrual) ·
--         ขายทรัพย์ (cr + gain หรือ loss) · แยกเงินต้น-ดอกเบี้ย (dr/cr + interest) ·
--         กลับรายการ (รหัสเดิม สลับด้าน → ตรวจเป็น **ชุด** ไม่ใช่ตรวจด้าน)
--       เทียบเป็นชุดโดยตั้งใจ: ถ้าเทียบ "ขาไหนต้องเดบิต" รายการกลับรายการจะลงไม่ได้
--       = กันแน่นเกินจนใช้งานไม่ได้ ซึ่งก็คือพัง
--
--   5.2 ข้อ 7: bank_account_id ติดได้เฉพาะบรรทัดเงินสด 11xx
--       ค้างรับที่แนบบัญชีของผู้ถืออื่นมาด้วยจึงถูกปฏิเสธสองชั้น (ที่นี่ + trigger ข้อ 1)
--
--   5.3 ขาที่ไม่ใช่เงินสดของรายการข้ามผู้ถือ — **ล็อกเป็นรหัสตรงไม่ได้ในรอบนี้**
--       ตารางกฎฝั่ง DB (txn_types) ไม่มีคอลัมน์ของบัญชีระหว่างกัน · กฎนั้นอยู่ใน
--       src/lib/rules/intercompany.ts และ sync:rules ยังไม่ครอบ · นอกจากนั้น
--       เทสต์ T4/T5 ที่ apply แล้วลงขาข้ามผู้ถือด้วย 1300/2400 (ไม่ใช่ 1310/2310
--       ที่เครื่องยนต์สร้าง) → ถ้าล็อกรหัสตรงวันนี้ จะพังเทสต์ที่แก้ไม่ได้
--       ที่ทำได้คือ **แคบลงจากเดิมมาก**: ขานั้นต้องเป็นบัญชี **ประเภทเดียวกับ**
--       บัญชีที่ลักษณะนั้นกำหนด (ลูกหนี้=สินทรัพย์ / เจ้าหนี้=หนี้สิน / ทุน=ส่วนของเจ้าของ /
--       ปันผลรับ=รายได้) → Cr 4200 รายได้ค่าเช่า บนขากู้ยืมระหว่างกันถูกปฏิเสธ
--       และการจับคู่ยอดจริงยังถูกบังคับที่ trg_intercompany_pair อีกชั้น
--
--   5.4 ข้อ 4: fingerprint คิดจาก fn_canonical_payload() + วันที่/source ที่ normalise แล้ว
--
--   ที่เหลือเหมือนรุ่น 20261008000008 ทุกบรรทัด (คัดลอกมาเพราะไฟล์เดิมแก้ไม่ได้)
-- ------------------------------------------------------------
create or replace function fn_post_entry(p_payload jsonb) returns jsonb
language plpgsql set search_path = '' as $fn$
declare
  c_header constant text[] := array[
    'txn_type_code', 'doc_date', 'cash_date', 'doc_no', 'memo', 'attachments',
    'asset_id', 'contact_id', 'contract_id', 'owner_reason', 'funding_source',
    'source', 'source_ref', 'reverses_id', 'transactions'];
  c_txn    constant text[] := array['owner_id', 'counter_owner_id', 'intercompany_nature', 'lines'];
  c_line   constant text[] := array['coa_code', 'bank_account_id', 'asset_id',
                                    'debit', 'credit', 'cf_category', 'memo'];
  v_bad      text;
  v_source   text;
  v_has_cash boolean := false;
  v_i        int := 0;
  v_j        int;
  v_dr       numeric;
  v_cr       numeric;
  v_txn      jsonb;
  v_line     jsonb;
  v_coa      uuid;
  v_txn_id   uuid;
  v_ids      uuid[] := '{}';
  v_prev     uuid[];
  v_fp       text;
  v_canon    jsonb;
  v_secs     numeric;
  v_req      uuid;
  v_doc      date;
  v_cash     date;
  v_allowed  text[];
  v_types    text[];
  v_nature   text;
  v_p        text;
  v_r        text;
begin
  -- ========== 0 · ไม่ส่งข้อมูลมาเลย = ปฏิเสธ ห้ามตกไปเส้นทางปกติ (บทเรียนข้อ 1) ==========
  if p_payload is null or jsonb_typeof(p_payload) = 'null' then
    raise exception 'บันทึกรายการไม่ได้: ไม่ได้ส่งข้อมูลรายการมาเลย';
  end if;
  if jsonb_typeof(p_payload) <> 'object' then
    raise exception 'บันทึกรายการไม่ได้: รูปแบบข้อมูลไม่ถูกต้อง — ต้องเป็น object ของทั้งใบ ไม่ใช่ %',
      jsonb_typeof(p_payload);
  end if;

  select string_agg(k, ', ' order by k) into v_bad
    from jsonb_object_keys(p_payload) as k where k <> all (c_header);
  if v_bad is not null then
    raise exception 'บันทึกรายการไม่ได้: มีช่องที่ยังไม่รู้จัก (%) — RPC ปฏิเสธทั้งใบแทนที่จะทิ้งช่องนั้นเงียบๆ · ช่องที่รับคือ %',
      v_bad, array_to_string(c_header, ', ');
  end if;

  -- ========== 1 · ผู้เรียกต้องมีตัวตนในระบบ ==========
  if auth.uid() is null then
    raise exception 'บันทึกรายการไม่ได้: ยังไม่ได้ล็อกอิน';
  end if;
  if not exists (select 1 from sri_os.app_users u where u.id = auth.uid() and u.is_active) then
    raise exception 'บันทึกรายการไม่ได้: ผู้ใช้นี้ยังไม่ได้ถูกตั้งตำแหน่งในระบบ หรือถูกปิดใช้งานแล้ว';
  end if;

  -- ========== 2 · ช่องบังคับของหัวรายการ ==========
  if nullif(p_payload ->> 'txn_type_code', '') is null then
    raise exception 'บันทึกรายการไม่ได้: ไม่ได้ส่ง txn_type_code (หมวดย่อยของรายการ)';
  end if;
  if not exists (select 1 from sri_os.txn_types t where t.code = p_payload ->> 'txn_type_code') then
    raise exception 'บันทึกรายการไม่ได้: ไม่มีหมวด "%" ในตารางกฎ (txn_types) — ตารางกฎคือแหล่งความจริงเดียว ถ้าเพิ่มหมวดใหม่ให้ sync ด้วย npm run sync:rules',
      p_payload ->> 'txn_type_code';
  end if;
  if nullif(p_payload ->> 'doc_date', '') is null then
    raise exception 'บันทึกรายการไม่ได้: ไม่ได้ส่ง doc_date (วันที่เอกสาร)';
  end if;

  -- วันที่: แปลงที่นี่ครั้งเดียว เพื่อให้ได้ข้อความภาษาคนแทน error ดิบของการ cast
  -- และเพื่อให้ "2026-09-01" กับรูปอื่นของวันเดียวกันได้ fingerprint เดียวกัน (ข้อ 4)
  begin
    v_doc := (p_payload ->> 'doc_date')::date;
  exception when others then
    raise exception 'บันทึกรายการไม่ได้: doc_date "%" ไม่ใช่วันที่ที่อ่านได้ (ต้องเป็น YYYY-MM-DD)',
      p_payload ->> 'doc_date';
  end;
  if nullif(p_payload ->> 'cash_date', '') is not null then
    begin
      v_cash := (p_payload ->> 'cash_date')::date;
    exception when others then
      raise exception 'บันทึกรายการไม่ได้: cash_date "%" ไม่ใช่วันที่ที่อ่านได้ (ต้องเป็น YYYY-MM-DD)',
        p_payload ->> 'cash_date';
    end;
  end if;

  v_source := coalesce(nullif(p_payload ->> 'source', ''), 'manual');
  if not exists (
       select 1 from pg_catalog.pg_enum e
         join pg_catalog.pg_type t on t.oid = e.enumtypid
         join pg_catalog.pg_namespace n on n.oid = t.typnamespace
        where n.nspname = 'sri_os' and t.typname = 'txn_source' and e.enumlabel = v_source) then
    raise exception 'บันทึกรายการไม่ได้: source "%" ไม่รู้จัก', v_source;
  end if;

  if p_payload -> 'attachments' is not null
     and jsonb_typeof(p_payload -> 'attachments') <> 'array' then
    raise exception 'บันทึกรายการไม่ได้: attachments ต้องเป็น array ของชื่อไฟล์';
  end if;

  if p_payload -> 'transactions' is null then
    raise exception 'บันทึกรายการไม่ได้: ไม่ได้ส่ง transactions (ผลลัพธ์จาก buildPosting)';
  end if;
  if jsonb_typeof(p_payload -> 'transactions') <> 'array' then
    raise exception 'บันทึกรายการไม่ได้: transactions ต้องเป็น array (หนึ่งสมาชิก = หนึ่งผู้ถือ)';
  end if;
  if jsonb_array_length(p_payload -> 'transactions') = 0 then
    raise exception 'บันทึกรายการไม่ได้: ไม่มีรายการใน transactions เลย';
  end if;

  -- ========== 3 · ตรวจรูปของทุกรายการ/ทุกบรรทัด **ก่อนเขียนอะไรลงไป** ==========
  for v_txn in select value from jsonb_array_elements(p_payload -> 'transactions') loop
    v_i := v_i + 1;
    if jsonb_typeof(v_txn) <> 'object' then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ต้องเป็น object', v_i;
    end if;

    select string_agg(k, ', ' order by k) into v_bad
      from jsonb_object_keys(v_txn) as k where k <> all (c_txn);
    if v_bad is not null then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % มีช่องที่ยังไม่รู้จัก (%) · ช่องที่รับคือ %',
        v_i, v_bad, array_to_string(c_txn, ', ');
    end if;

    if nullif(v_txn ->> 'owner_id', '') is null then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ไม่ได้ส่ง owner_id (ผู้ถือ) — หนึ่งรายการ = หนึ่งผู้ถือ เดาแทนไม่ได้', v_i;
    end if;

    -- ข้ามผู้ถือต้องมาเป็นคู่: ขาดข้างใดข้างหนึ่งแปลว่าข้อมูลไม่ครบ ไม่ใช่รายการธรรมดา
    if nullif(v_txn ->> 'counter_owner_id', '') is not null
       and nullif(v_txn ->> 'intercompany_nature', '') is null then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % เป็นรายการข้ามผู้ถือ ต้องระบุลักษณะ (intercompany_nature: advance/loan/capital/dividend)', v_i;
    end if;
    if nullif(v_txn ->> 'intercompany_nature', '') is not null
       and nullif(v_txn ->> 'counter_owner_id', '') is null then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ระบุลักษณะข้ามผู้ถือแต่ไม่มีผู้ถืออีกฝ่าย (counter_owner_id)', v_i;
    end if;
    if nullif(v_txn ->> 'counter_owner_id', '') is not null
       and (v_txn ->> 'counter_owner_id') = (v_txn ->> 'owner_id') then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ระบุผู้ถืออีกฝ่ายเป็นคนเดียวกับผู้ถือของรายการ — ถ้าเป็นการย้ายกระเป๋าในคนเดียวกัน ไม่ใช่รายการข้ามผู้ถือ', v_i;
    end if;

    if v_txn -> 'lines' is null or jsonb_typeof(v_txn -> 'lines') <> 'array' then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ไม่ได้ส่ง lines เป็น array', v_i;
    end if;
    if jsonb_array_length(v_txn -> 'lines') < 2 then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % มีบรรทัดบัญชี % บรรทัด — บัญชีสองด้านต้องมีอย่างน้อยสองบรรทัด',
        v_i, jsonb_array_length(v_txn -> 'lines');
    end if;

    -- ---------- 3.1 ชุดบัญชีที่หมวดนี้ใช้ได้ — อ่านจากตารางกฎ ไม่ได้คิดเอง (ข้อ 3) ----------
    select array_remove(array[t.dr_coa_code, t.cr_coa_code, t.gain_coa_code,
                              t.loss_coa_code, t.interest_coa_code, t.accrual_coa_code], null)
      into v_allowed
      from sri_os.txn_types t where t.code = p_payload ->> 'txn_type_code';
    if v_allowed is null or cardinality(v_allowed) = 0 then
      raise exception 'บันทึกรายการไม่ได้: ตารางกฎ (txn_types) ไม่ได้ระบุบัญชีของหมวด "%" เลย — sync ด้วย npm run sync:rules ก่อน ห้ามเดาคู่บัญชีแทน',
        p_payload ->> 'txn_type_code';
    end if;

    v_nature := nullif(v_txn ->> 'intercompany_nature', '');
    v_types  := '{}'::text[];
    v_p := null; v_r := null;
    if v_nature is not null then
      -- สำเนาคู่บัญชีระหว่างกันจาก src/lib/rules/intercompany.ts (ดูหัวข้อ 3 ของไฟล์นี้)
      select x.payer, x.receiver into v_p, v_r
        from (values ('advance', '1310', '2310'),
                     ('loan',    '1310', '2310'),
                     ('capital', '1710', '3100'),
                     ('dividend','3200', '4410')) as x(nature, payer, receiver)
       where x.nature = v_nature;
      if v_p is null then
        raise exception 'บันทึกรายการไม่ได้: ลักษณะรายการข้ามผู้ถือ "%" ไม่รู้จัก (advance/loan/capital/dividend)', v_nature;
      end if;
      -- ขาเงินสดกับบัญชีระหว่างกันของลักษณะนั้นใช้ได้เสมอบนขาข้ามผู้ถือ
      v_allowed := v_allowed || array['1100', v_p, v_r];
      select array_agg(c.type::text) into v_types
        from sri_os.chart_of_accounts c where c.code in (v_p, v_r);
    end if;

    v_j := 0;
    for v_line in select value from jsonb_array_elements(v_txn -> 'lines') loop
      v_j := v_j + 1;
      if jsonb_typeof(v_line) <> 'object' then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % ต้องเป็น object', v_i, v_j;
      end if;

      select string_agg(k, ', ' order by k) into v_bad
        from jsonb_object_keys(v_line) as k where k <> all (c_line);
      if v_bad is not null then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % มีช่องที่ยังไม่รู้จัก (%) · ช่องที่รับคือ %',
          v_i, v_j, v_bad, array_to_string(c_line, ', ');
      end if;

      if nullif(v_line ->> 'coa_code', '') is null then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % ไม่ได้ส่ง coa_code', v_i, v_j;
      end if;
      select c.id into v_coa
        from sri_os.chart_of_accounts c where c.code = v_line ->> 'coa_code';
      if v_coa is null then
        raise exception 'บันทึกรายการไม่ได้: ไม่มีรหัส "%" ในผังบัญชี (chart_of_accounts) — ผังบัญชีในฐานข้อมูลอาจยังไม่ sync กับ src/lib/rules/coa.ts',
          v_line ->> 'coa_code';
      end if;

      -- ---------- 3.2 คู่บัญชีต้องตรงกับที่ตารางกฎระบุไว้ (ข้อ 3) ----------
      if not ((v_line ->> 'coa_code') = any (v_allowed)) then
        if v_nature is null
           or not exists (select 1 from sri_os.chart_of_accounts c
                           where c.code = v_line ->> 'coa_code'
                             and c.type::text = any (v_types)) then
          raise exception 'บันทึกรายการไม่ได้: หมวด "%" ลงบัญชี % ไม่ได้ — ตารางกฎ (txn_types) ระบุบัญชีของหมวดนี้ไว้เฉพาะ % · คู่บัญชีที่ไม่ตรงหมวดทำให้ผิดทั้งงบ (เช่น เงินกู้กลายเป็นรายได้)',
            p_payload ->> 'txn_type_code', v_line ->> 'coa_code', array_to_string(v_allowed, ', ');
        end if;
      end if;

      -- ---------- 3.3 bank_account_id ติดได้เฉพาะบรรทัดเงินสด 11xx (ข้อ 7) ----------
      if nullif(v_line ->> 'bank_account_id', '') is not null
         and (v_line ->> 'coa_code') !~ '^11[0-9][0-9]$' then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % ผูกบัญชีธนาคารไว้กับบัญชี % ซึ่งไม่ใช่เงินสด/เงินฝาก — บัญชีธนาคารติดได้เฉพาะขาเงินสด ไม่ใช่ขาลูกหนี้/เจ้าหนี้/รายได้',
          v_i, v_j, v_line ->> 'coa_code';
      end if;

      if (v_line -> 'debit') is null and (v_line -> 'credit') is null then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % ไม่ได้ส่งทั้งเดบิตและเครดิต', v_i, v_j;
      end if;
      if (v_line -> 'debit') is not null and jsonb_typeof(v_line -> 'debit') not in ('number', 'null') then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % เดบิตต้องเป็นตัวเลข', v_i, v_j;
      end if;
      if (v_line -> 'credit') is not null and jsonb_typeof(v_line -> 'credit') not in ('number', 'null') then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % เครดิตต้องเป็นตัวเลข', v_i, v_j;
      end if;
      v_dr := coalesce((v_line ->> 'debit')::numeric, 0);
      v_cr := coalesce((v_line ->> 'credit')::numeric, 0);
      if v_dr < 0 or v_cr < 0 then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % มียอดติดลบ (เดบิต % เครดิต %) — ทิศทางมาจากด้านที่ลง ไม่ใช่จากเครื่องหมาย',
          v_i, v_j, v_dr, v_cr;
      end if;
      if not ((v_dr > 0 and v_cr = 0) or (v_cr > 0 and v_dr = 0)) then
        raise exception 'บันทึกรายการไม่ได้: รายการที่ % บรรทัดที่ % ต้องลงด้านเดียวและมากกว่า 0 (เดบิต % เครดิต %)',
          v_i, v_j, v_dr, v_cr;
      end if;

      if nullif(v_line ->> 'cf_category', '') is not null
         and not exists (
           select 1 from pg_catalog.pg_enum e
             join pg_catalog.pg_type t on t.oid = e.enumtypid
             join pg_catalog.pg_namespace n on n.oid = t.typnamespace
            where n.nspname = 'sri_os' and t.typname = 'cf_group'
              and e.enumlabel = v_line ->> 'cf_category') then
        raise exception 'บันทึกรายการไม่ได้: หมวดกระแสเงินสด "%" ไม่รู้จัก', v_line ->> 'cf_category';
      end if;

      -- ผังบัญชี 1100-1199 = เงินสดและเงินฝาก (เกณฑ์เดียวกับ fn_assert_no_floating_cash)
      if (v_line ->> 'coa_code') ~ '^11[0-9][0-9]$' then v_has_cash := true; end if;
    end loop;
  end loop;

  -- ========== 3.4 · ข้ามผู้ถือต้องมาครบคู่ในคำขอเดียว (ข้อ 2 · ข้อความที่อ่านรู้เรื่อง) ==========
  -- ด่านจริงคือ trg_intercompany_pair (constraint trigger) ที่ครอบ REST ตรงด้วย
  -- ที่นี่ตรวจซ้ำเพื่อให้ผู้กดได้ข้อความก่อนที่อะไรจะถูกเขียน ไม่ใช่กฎที่สองที่คิดต่างกัน
  with legs as (
    select (x.value ->> 'owner_id') as o,
           nullif(x.value ->> 'counter_owner_id', '') as c,
           nullif(x.value ->> 'intercompany_nature', '') as n,
           (select coalesce(sum(coalesce((l.value ->> 'debit')::numeric, 0)), 0)
              from jsonb_array_elements(x.value -> 'lines') as l) as amt
      from jsonb_array_elements(p_payload -> 'transactions') as x
  )
  select string_agg(distinct a.o, ', ') into v_bad
    from legs a
   where a.c is not null
     and (select count(*) from legs b
           where b.o = a.o and b.c = a.c and b.n = a.n and b.amt = a.amt)
      <> (select count(*) from legs b
           where b.o = a.c and b.c = a.o and b.n = a.n and b.amt = a.amt);
  if v_bad is not null then
    raise exception 'บันทึกรายการไม่ได้: รายการข้ามผู้ถือต้องมาครบคู่ในคำขอเดียว (ขาออกของผู้ถือหนึ่ง + ขาเข้าของอีกผู้ถือ ยอดเท่ากัน) — ขาของผู้ถือ % ไม่มีขาคู่ · ขาเดียวแปลว่าเงินหายไปข้างหนึ่งและงบรวมตัดรายการระหว่างกันไม่ลง',
      v_bad;
  end if;

  -- ========== 4 · cash_date ต้องสอดคล้องกับบรรทัดที่เครื่องยนต์ส่งมา ==========
  if v_has_cash and v_cash is null then
    raise exception 'บันทึกรายการไม่ได้: รายการนี้มีบรรทัดเงินสด/เงินฝาก แต่ไม่ได้ส่ง cash_date (วันที่เงินเข้า-ออกจริง) — ถ้าเงินยังไม่เคลื่อน ต้องลงเป็นลูกหนี้/เจ้าหนี้ ไม่ใช่เงินสด';
  end if;
  if not v_has_cash and v_cash is not null then
    raise exception 'บันทึกรายการไม่ได้: รายการนี้ไม่มีบรรทัดเงินสดเลย (ค้างรับ-ค้างจ่าย) cash_date ต้องเป็น null ไม่งั้นงบกระแสเงินสดจะนับเงินที่ยังไม่เคลื่อน';
  end if;

  -- ========== 5 · กันกดปุ่มซ้ำ — ล็อกแถว fingerprint ก่อนลงรายการ ==========
  select coalesce((s.value #>> '{}')::numeric, 60) into v_secs
    from sri_os.settings s where s.key = 'ledger.post_dedupe_seconds';
  v_secs := greatest(coalesce(v_secs, 60), 0);

  -- ข้อ 4: normalise ก่อนคิด fingerprint · วันที่/source ใช้ค่าที่ฟังก์ชันจะใช้จริง
  v_canon := sri_os.fn_canonical_payload(p_payload);
  v_canon := jsonb_set(v_canon, '{doc_date}', to_jsonb(v_doc::text));
  if v_cash is null then
    v_canon := v_canon - 'cash_date';
  else
    v_canon := jsonb_set(v_canon, '{cash_date}', to_jsonb(v_cash::text));
  end if;
  v_canon := jsonb_set(v_canon, '{source}', to_jsonb(v_source));

  v_fp := encode(sha256(convert_to(auth.uid()::text || '|' || v_canon::text, 'UTF8')), 'hex');

  insert into sri_os.post_entry_requests as r (fingerprint)
  values (v_fp)
      on conflict (fingerprint) do update
         set created_at = now(), transaction_ids = '{}'::uuid[]
       where r.created_at < now() - make_interval(secs => v_secs::double precision)
  returning r.id into v_req;

  if v_req is null then
    -- คำขอเดิมซ้ำในหน้าต่าง = กดรัว · คืน id ชุดเดิมโดยไม่ลงใหม่
    select r.transaction_ids into v_prev
      from sri_os.post_entry_requests r where r.fingerprint = v_fp;
    return jsonb_build_object(
      'transaction_ids', coalesce(to_jsonb(v_prev), '[]'::jsonb),
      'replayed', true,
      'fingerprint', v_fp);
  end if;

  -- ========== 6 · เขียนลงจริง — หัวรายการ + บรรทัด ในธุรกรรมเดียวกัน (D-091) ==========
  -- created_by ไม่อยู่ในรายการคอลัมน์โดยตั้งใจ: trigger ตั้งเป็น auth.uid() ให้ (ข้อ 5)
  for v_txn in select value from jsonb_array_elements(p_payload -> 'transactions') loop
    insert into sri_os.transactions (
      owner_id, txn_type_code, doc_date, cash_date, doc_no, memo, attachments,
      asset_id, contact_id, contract_id, owner_reason, funding_source,
      source, source_ref, reverses_id,
      is_intercompany, counter_owner_id, intercompany_nature)
    values (
      (v_txn ->> 'owner_id')::uuid,
      p_payload ->> 'txn_type_code',
      v_doc,
      v_cash,
      nullif(p_payload ->> 'doc_no', ''),
      nullif(p_payload ->> 'memo', ''),
      coalesce((select array_agg(a) from jsonb_array_elements_text(p_payload -> 'attachments') as a),
               '{}'::text[]),
      (nullif(p_payload ->> 'asset_id', ''))::uuid,
      (nullif(p_payload ->> 'contact_id', ''))::uuid,
      (nullif(p_payload ->> 'contract_id', ''))::uuid,
      nullif(p_payload ->> 'owner_reason', ''),
      nullif(p_payload ->> 'funding_source', ''),
      v_source::sri_os.txn_source,
      nullif(p_payload ->> 'source_ref', ''),
      (nullif(p_payload ->> 'reverses_id', ''))::uuid,
      nullif(v_txn ->> 'counter_owner_id', '') is not null,
      (nullif(v_txn ->> 'counter_owner_id', ''))::uuid,
      nullif(v_txn ->> 'intercompany_nature', ''))
    returning id into v_txn_id;

    for v_line in select value from jsonb_array_elements(v_txn -> 'lines') loop
      insert into sri_os.transaction_lines (
        transaction_id, coa_id, bank_account_id, debit, credit, cf_category, asset_id, memo)
      values (
        v_txn_id,
        (select c.id from sri_os.chart_of_accounts c where c.code = v_line ->> 'coa_code'),
        (nullif(v_line ->> 'bank_account_id', ''))::uuid,
        coalesce((v_line ->> 'debit')::numeric, 0),
        coalesce((v_line ->> 'credit')::numeric, 0),
        (nullif(v_line ->> 'cf_category', ''))::sri_os.cf_group,
        (nullif(v_line ->> 'asset_id', ''))::uuid,
        nullif(v_line ->> 'memo', ''));
    end loop;

    v_ids := v_ids || v_txn_id;
  end loop;

  update sri_os.post_entry_requests r
     set transaction_ids = v_ids
   where r.id = v_req;

  -- ด่านสมดุล/บรรทัดครบ/คู่ข้ามผู้ถือเป็น constraint trigger แบบ deferred (ยิงตอน commit)
  -- → บังคับให้ยิง **ตอนนี้** เพื่อให้คนกดปุ่มได้ข้อความที่อ่านรู้เรื่องทันที
  --   นี่คือการทำให้ด่าน **เข้มขึ้น (เร็วขึ้น)** ไม่ใช่ผ่อน · แล้วคืนสภาพ deferred ให้เหมือนเดิม
  set constraints all immediate;
  set constraints all deferred;

  return jsonb_build_object(
    'transaction_ids', to_jsonb(v_ids),
    'replayed', false,
    'fingerprint', v_fp);
end $fn$;

-- ------------------------------------------------------------
-- 6 · ข้อ 6 · คอมเมนต์ต้องตรงกับพฤติกรรม
--
-- หัวไฟล์ 20261008000008 ยังเขียนว่า "รายการข้ามผู้ถือจะถูก RPC นี้ปฏิเสธ
--   เพราะไม่มีรหัส 1310/2310/1710 ในผังบัญชี" ซึ่ง **ไม่จริงแล้ว** ตั้งแต่
--   20261008000010 เติมสามรหัสนั้น และเทสต์ T4 พิสูจน์ว่าลงสองขาได้จริง
--   ไฟล์นั้น apply แล้วแก้ไม่ได้ → แก้ที่คอมเมนต์ของวัตถุใน DB ซึ่งเป็นที่ที่
--   คนอ่านจาก \df+ / information_schema เห็น (ไม่ใช่ที่ที่คนอ่านไฟล์เห็น — ข้อจำกัดนี้
--   คือเหตุผลที่ควรมีกลไกให้เทสต์จับคอมเมนต์ที่ขัดโค้ด ดูข้อเสนอในรายงาน)
-- ------------------------------------------------------------
comment on function fn_post_entry(jsonb) is
  'ปากทางเดียวที่เขียนผลลัพธ์ของ buildPosting() ลง transactions + transaction_lines ในธุรกรรมเดียว (D-091) · **security invoker** → RLS เป็นด่านเดียว · ไม่คิดคู่บัญชีเอง แต่ **เทียบคู่บัญชีที่ส่งมากับตารางกฎ txn_types** (ข้อ 3) · bank_account_id ได้เฉพาะขาเงินสด 11xx (ข้อ 7) · ข้ามผู้ถือต้องครบคู่ (ข้อ 2) · fingerprint คิดจาก payload ที่ normalise แล้ว (ข้อ 4) · **แก้ข้อความที่ล้าสมัยในหัวไฟล์ 20261008000008: รายการข้ามผู้ถือ "ไม่" ถูกปฏิเสธอีกแล้ว เพราะ 20261008000010 เติม 1310/2310/1710 ครบ และ T4 ผ่าน**';

comment on trigger trg_intercompany_pair on transactions is
  'ข้อ 2 · ข้ามผู้ถือต้องมาครบคู่ในธุรกรรมเดียวกันและบัญชีระหว่างกันต้องหักกลบกัน · deferred เพราะตอนลงขาแรก ขาที่สองยังไม่เกิด';

comment on trigger trg_line_bank_owner on transaction_lines is
  'ข้อ 1 · bank_account_id ต้องเป็นบัญชีของผู้ถือของรายการนั้น · ก่อนมีด่านนี้ เงิน 70,000 เข้าบัญชีของผู้ถือที่ผู้กดมองไม่เห็นได้สำเร็จ';

-- ------------------------------------------------------------
-- 7 · ACL — ฟังก์ชันใหม่ติด PUBLIC EXECUTE มาจาก Postgres ต้องปิดก่อนเปิดเท่าที่จำเป็น
--     (create or replace ไม่ล้าง ACL เดิมของ fn_post_entry แต่ย้ำไว้ให้ไฟล์นี้รันเองได้)
-- ------------------------------------------------------------
revoke all on function fn_post_entry(jsonb) from public;
revoke all on function fn_canonical_payload(jsonb) from public;
revoke all on function fn_assert_line_bank_owner() from public;
revoke all on function fn_assert_intercompany_pair() from public;
revoke all on function fn_txn_system_columns() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_post_entry(jsonb) from anon';
  execute 'grant execute on function sri_os.fn_post_entry(jsonb) to authenticated';
  -- fn_canonical_payload **ต้องเปิดให้ authenticated** เพราะ fn_post_entry เป็น
  -- security invoker → เรียกฟังก์ชันช่วยในฐานะผู้กด ถ้าปิด ประตูจะพังด้วย
  -- "permission denied for function fn_canonical_payload" ทุกครั้ง (เจอจริงตอนทดสอบ)
  -- เปิดได้ไม่เสี่ยง: เป็นฟังก์ชันบริสุทธิ์ ไม่แตะตารางใด ไม่มีผลข้างเคียง
  -- และไม่เปิดเผยอะไรที่ผู้เรียกไม่ได้ส่งเข้าไปเอง · anon ยังปิดสนิท
  execute 'revoke all on function sri_os.fn_canonical_payload(jsonb) from anon';
  execute 'grant execute on function sri_os.fn_canonical_payload(jsonb) to authenticated';
  -- trigger function เรียกตรงไม่ได้ทุก role (กฎเงินห้ามเรียกเอง/ห้ามปิด)
  execute 'revoke all on function sri_os.fn_assert_line_bank_owner() from anon, authenticated';
  execute 'revoke all on function sri_os.fn_assert_intercompany_pair() from anon, authenticated';
  execute 'revoke all on function sri_os.fn_txn_system_columns() from anon, authenticated';
end $$;

-- ------------------------------------------------------------
-- 8 · guard ท้ายไฟล์ — ต้อง "พังให้เห็น" ไม่ใช่ raise notice
-- ------------------------------------------------------------
do $$
declare v text; n int;
begin
  -- (ก) ประตูต้องยังเป็น invoker และ ACL ยังแคบ (เหมือน guard ของ 20261008000008)
  if (select p.prosecdef from pg_proc p where p.oid = 'sri_os.fn_post_entry(jsonb)'::regprocedure) then
    raise exception 'fn_post_entry เป็น SECURITY DEFINER = ทางข้าม RLS · ต้องเป็น invoker';
  end if;
  if has_function_privilege('public', 'sri_os.fn_post_entry(jsonb)', 'execute')
     or has_function_privilege('anon', 'sri_os.fn_post_entry(jsonb)', 'execute') then
    raise exception 'fn_post_entry ยังเปิดให้ public/anon เรียกได้';
  end if;
  if not has_function_privilege('authenticated', 'sri_os.fn_post_entry(jsonb)', 'execute') then
    raise exception 'authenticated เรียก fn_post_entry ไม่ได้ → หน้าจอใช้ไม่ได้';
  end if;
  -- ประตูเป็น invoker → ต้องเรียกฟังก์ชันช่วยในฐานะผู้กดได้ ไม่งั้นประตูพังทุกครั้ง
  if not has_function_privilege('authenticated', 'sri_os.fn_canonical_payload(jsonb)', 'execute') then
    raise exception 'authenticated เรียก fn_canonical_payload ไม่ได้ → fn_post_entry จะพังทุกครั้ง';
  end if;
  if has_function_privilege('anon', 'sri_os.fn_canonical_payload(jsonb)', 'execute') then
    raise exception 'anon เรียก fn_canonical_payload ได้';
  end if;

  -- (ข) trigger ของไฟล์นี้ต้องผูกกับตารางจริง ไม่ใช่สร้างฟังก์ชันทิ้งไว้
  if not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                  where tg.tgrelid = 'sri_os.transaction_lines'::regclass
                    and p.proname = 'fn_assert_line_bank_owner'
                    and (tg.tgtype & 4) <> 0 and (tg.tgtype & 2) <> 0 and (tg.tgtype & 16) <> 0) then
    raise exception 'ไม่มี trigger before insert or update กันบัญชีผิดผู้ถือบน transaction_lines';
  end if;
  if not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                  where tg.tgrelid = 'sri_os.transactions'::regclass
                    and p.proname = 'fn_assert_intercompany_pair'
                    and tg.tgdeferrable and tg.tginitdeferred) then
    raise exception 'ไม่มี constraint trigger (deferred) กันข้ามผู้ถือขาเดียวบน transactions';
  end if;

  -- (ค) กฎเงินห้ามขึ้นกับสิทธิ์ — trigger function ของไฟล์นี้ต้องไม่เรียก fn_can
  for v in select p.proname from pg_proc p
            where p.oid in ('sri_os.fn_assert_line_bank_owner()'::regprocedure,
                            'sri_os.fn_assert_intercompany_pair()'::regprocedure)
              and p.prosrc ~* 'fn_can' loop
    raise exception '% เรียก fn_can → ปิดกฎเงินได้จากหน้า Settings', v;
  end loop;

  -- (ง) ข้อ 5: ฟังก์ชันคอลัมน์ระบบต้องทับ created_by จริง (ไม่ใช่แค่คอมเมนต์ว่าทับ)
  select p.prosrc into v from pg_proc p
   where p.oid = 'sri_os.fn_txn_system_columns()'::regprocedure;
  if v !~ 'created_by\s*:=\s*auth\.uid\(\)' then
    raise exception 'fn_txn_system_columns ไม่ได้ตั้ง created_by = auth.uid() → ปลอมคนคีย์ได้';
  end if;

  -- (จ) ข้อ 4: รูปตัวเลขที่ต่างกันต้องได้ canonical เดียวกัน (พิสูจน์ด้วยค่าจริง)
  if sri_os.fn_canonical_payload('{"a":12000}'::jsonb)
     is distinct from sri_os.fn_canonical_payload('{"a":12000.00}'::jsonb)
   or sri_os.fn_canonical_payload('{"a":12000}'::jsonb)
     is distinct from sri_os.fn_canonical_payload('{"a":1.2e4}'::jsonb)
   or sri_os.fn_canonical_payload('{"a":1,"b":null}'::jsonb)
     is distinct from sri_os.fn_canonical_payload('{"b":null,"a":1.0}'::jsonb)
   or sri_os.fn_canonical_payload('{"a":1}'::jsonb)
     is distinct from sri_os.fn_canonical_payload('{"a":1,"c":""}'::jsonb) then
    raise exception 'fn_canonical_payload ยังแยกรูปที่ควรเท่ากัน → กดซ้ำยังหลุดได้';
  end if;
  -- และต้อง **ไม่** รวมของที่ต่างกันจริง
  if sri_os.fn_canonical_payload('{"a":12000}'::jsonb)
     = sri_os.fn_canonical_payload('{"a":12001}'::jsonb)
   or sri_os.fn_canonical_payload('[1,2]'::jsonb) = sri_os.fn_canonical_payload('[2,1]'::jsonb) then
    raise exception 'fn_canonical_payload รวมคำขอที่ต่างกันจริงเข้าด้วยกัน → ใบที่สองจะหายเงียบๆ';
  end if;

  -- (ฉ) สำเนาคู่บัญชีระหว่างกันต้องครบทุกลักษณะที่ตารางอนุญาต และทุกรหัสต้องมีในผังบัญชี
  --     (ถ้าเพิ่มลักษณะใน check constraint แล้วลืมสำเนา → ต้องดังตอน migrate)
  select string_agg(x.code, ', ') into v
    from unnest(array['1310', '2310', '1710', '3100', '3200', '4410']) as x(code)
   where not exists (select 1 from sri_os.chart_of_accounts c where c.code = x.code);
  if v is not null then
    raise exception 'ผังบัญชีขาดรหัสที่คู่บัญชีระหว่างกันใช้: % — รายการข้ามผู้ถือจะถูกปฏิเสธตอนผู้ใช้กดบันทึก', v;
  end if;
  select pg_get_constraintdef(oid) into v from pg_constraint
   where conrelid = 'sri_os.transactions'::regclass and conname = 'transactions_intercompany_nature_check';
  if v is not null then
    for n in select 1 from unnest(array['advance', 'loan', 'capital', 'dividend']) as k(nature)
              where position(k.nature in v) = 0 loop
      raise exception 'ลักษณะข้ามผู้ถือใน constraint กับสำเนาคู่บัญชีในไฟล์นี้ไม่ตรงกัน (%)', v;
    end loop;
  end if;

  raise notice 'guard · บัญชีผิดผู้ถือ/ข้ามผู้ถือขาเดียว/คู่บัญชีผิดหมวด/bank บนขาไม่ใช่เงินสด/created_by ปลอม/กดซ้ำด้วยรูปตัวเลข — ปิดครบและพิสูจน์ด้วยค่าจริงแล้ว';
end $$;
