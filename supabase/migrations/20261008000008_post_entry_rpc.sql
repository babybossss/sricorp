-- ============================================================
-- SRI OS · fn_post_entry() — ปากทางเดียวที่เขียนผลลัพธ์ของ buildPosting() ลง ledger จริง
--
-- ทำอะไร:
--   1. ตาราง post_entry_requests — ร่องรอยคำขอ + กันกดปุ่มซ้ำ (fingerprint ที่ **DB คิดเอง**)
--   2. trigger fn_assert_bank_account_open — บัญชีที่ปิดใช้งานลงรายการใหม่ไม่ได้ (D-092)
--      ยกเว้นรายการกลับรายการ · บังคับที่ DB เพราะฟอร์มไม่ใช่ที่กั้น (บทเรียนข้อ 6)
--   3. fn_post_entry(jsonb) — รับ { transactions: [...] } ที่เครื่องยนต์ส่งมา
--      แล้วลง `transactions` + `transaction_lines` **ในธุรกรรมฐานข้อมูลเดียวกัน**
--
-- ทำไมต้องเป็นฟังก์ชันเดียว (D-091):
--   trg_lines_immutable_after_post เทียบ transactions.write_txn_id กับ pg_current_xact_id()
--   → ถ้าหัวรายการกับบรรทัดมาจากสองคำขอ (สอง HTTP request = สองธุรกรรม) จะถูกปฏิเสธ
--   ซึ่งถูกต้องแล้ว · **ทางแก้คือรวมเป็นคำขอเดียว ไม่ใช่ผ่อน trigger**
--
-- สิ่งที่ฟังก์ชันนี้ **ไม่ทำ** และห้ามทำ:
--   - ไม่คิดคู่บัญชี ไม่คิดยอดเงิน ไม่เติมบรรทัด ไม่เดาหมวดกระแสเงินสด
--     ตารางกฎ (`src/lib/rules/tx-rules.ts`) + `buildPosting()` เป็นแหล่งความจริงเดียว
--     ถ้าฟังก์ชันนี้คำนวณเอง จะกลายเป็นกฎที่เขียนสองที่ แล้วสิ่งที่ผู้ใช้เห็นในพรีวิว
--     กับสิ่งที่บันทึกจริงแยกจากกันได้ (บทเรียน mace-windu ข้อ 5)
--   - ไม่เป็น SECURITY DEFINER · RLS เป็นด่านเดียวเหมือน fn_apply_asset_draft
--     (definer = ประตูหลังข้าม RLS ทุกตาราง = ทำให้ทุกอย่างที่สร้างมาไร้ความหมาย)
--   - ไม่ปิด/ไม่ผ่อน trigger หรือ constraint ใดๆ · `set constraints all immediate`
--     ที่ใช้ตอนท้ายทำให้ด่านที่เลื่อนไว้ถึง commit **ทำงานเร็วขึ้น** ไม่ใช่หลวมลง
--     (เพื่อให้ผู้เรียกได้ข้อความที่อ่านรู้เรื่องตอนเรียก ไม่ใช่ error ตอน commit)
--
-- สัญญาของ input (snake_case ของ PostingResult ใน src/lib/ledger/types.ts):
--   {
--     "txn_type_code": "inc.rent",          -- = subCode ของ PostingInput (คีย์ของ txn_types)
--     "doc_date": "2026-09-01",             -- บังคับ
--     "cash_date": "2026-09-03" | null,     -- null = ยังค้างรับ-ค้างจ่าย (ดูกฎ cash_date ล่าง)
--     "doc_no", "memo", "owner_reason", "funding_source", "source_ref": text | null,
--     "attachments": ["..."],               -- corporate_strict บังคับ (trigger เดิมตรวจ)
--     "asset_id", "contact_id", "contract_id", "reverses_id": uuid | null,
--     "source": "manual" | "schedule" | "payroll" | "reimburse" | "import" | "reverse",
--     "transactions": [                     -- 1 สมาชิก = 1 ผู้ถือ = 1 transaction
--       { "owner_id": uuid,                 -- บังคับ
--         "counter_owner_id": uuid | null,  -- มีคู่กับ intercompany_nature เท่านั้น
--         "intercompany_nature": "advance" | "loan" | "capital" | "dividend" | null,
--         "lines": [                        -- ≥ 2 บรรทัด
--           { "coa_code": "1100",           -- บังคับ · ต้องมีในผังบัญชี
--             "bank_account_id": uuid | null,
--             "asset_id": uuid | null,
--             "debit": 12000, "credit": 0,  -- ด้านเดียว > 0 เท่านั้น
--             "cf_category": "operating" | "investing" | "financing" | "transfer" | "none" | null,
--             "memo": text | null } ] } ]
--   }
--   **ช่องที่ไม่อยู่ในรายการนี้ = ปฏิเสธทั้งคำขอ** (เหมือน scripts/sync-txn-types.ts)
--   เพราะฟิลด์ใหม่ที่ RPC ยังไม่รู้จักแล้วถูกทิ้งเงียบๆ คือข้อมูลการเงินที่หายไปโดยไม่มีใครเห็น
--
-- สัญญาของ output (jsonb):
--   { "transaction_ids": [uuid, ...],   -- เรียงตามลำดับใน payload (ตัวแรก = ขาของผู้กด)
--     "replayed": false,                -- true = คำขอเดิมซ้ำในหน้าต่างกันกดซ้ำ ไม่ได้ลงใหม่
--     "fingerprint": "<sha256 hex>" }   -- DB คิดเอง หน้าจอไม่ต้องส่งอะไรมา
--
-- กฎ cash_date (ไม่ใช่กฎใหม่ — เป็นความหมายที่คอลัมน์ประกาศไว้ตั้งแต่ไฟล์ 002:
--   "cash_date เข้า CF · null = ยังค้างรับ/ค้างจ่าย"):
--   ตัดสินจาก **บรรทัดที่เครื่องยนต์ส่งมา** ไม่ใช่จากธงในฟอร์ม (บทเรียนข้อ 2)
--     มีบรรทัดผังบัญชี 11xx (เงินสด/เงินฝาก) → ต้องมี cash_date
--     ไม่มีเลย (ค้างรับ-ค้างจ่าย)           → cash_date ต้องเป็น null
--   ถ้าปล่อยให้ขัดกัน งบกระแสเงินสดจะนับเงินที่ยังไม่เคลื่อน หรือเงินที่เคลื่อนแล้วจะหายจาก CF
--
-- กันกดปุ่มซ้ำ (ทางเลือกที่ตัดสิน · เหตุผลเต็มในคอมเมนต์ของตารางข้างล่าง):
--   fingerprint = sha256(auth.uid() || payload ที่ jsonb ทำให้เป็นรูปแบบเดียว)
--   **หน้าจอไม่คิด key เอง** · ซ้ำภายในหน้าต่าง (settings: ledger.post_dedupe_seconds)
--   → คืน id ชุดเดิม + replayed = true โดยไม่ลงรายการใหม่
--
-- ของที่ยังขัดกันและไฟล์นี้ **ไม่แก้** (ต้องตัดสินแยก ไม่ใช่ซ่อนด้วยการเดา):
--   `sri_os.chart_of_accounts` ยังไม่มีรหัส 1310 (ลูกหนี้ระหว่างกัน) · 2310 (เจ้าหนี้ระหว่างกัน)
--   · 1710 (เงินลงทุนในบริษัทในเครือ) ซึ่ง `src/lib/rules/intercompany.ts` ใช้ทุกลักษณะ
--   → รายการข้ามผู้ถือจากเครื่องยนต์จะถูก RPC นี้ **ปฏิเสธ** ด้วยข้อความ "ไม่มีรหัส ... ในผังบัญชี"
--   ซึ่งถูกต้องตามหลัก fail closed (ลงบัญชีที่ไม่มีในผังไม่ได้) แต่แปลว่าฟีเจอร์ข้ามผู้ถือ
--   ยังใช้จริงไม่ได้จนกว่าจะ sync ผังบัญชีให้ตรงกับ src/lib/rules/coa.ts ในไฟล์แยก
--
-- ย้อนกลับ (rollback):
--   -- drop function if exists sri_os.fn_post_entry(jsonb);
--   -- drop trigger  if exists trg_line_bank_account_open on sri_os.transaction_lines;
--   -- drop function if exists sri_os.fn_assert_bank_account_open();
--   -- drop table    if exists sri_os.post_entry_requests;   -- (audit_log ยังเก็บร่องรอยไว้)
--   -- delete from sri_os.settings where key = 'ledger.post_dedupe_seconds';
--   -- ย้อนแล้ว: หน้าจอไม่มีทางเขียนลง ledger เลย (กลับไปสถานะก่อนไฟล์นี้)
--   --   และบัญชีที่ปิดใช้งานจะลงรายการใหม่ได้อีก (เหลือแต่ด่านฝั่งแอป) — ไม่แนะนำ
--
-- idempotent: create table if not exists · create or replace function ·
--   drop policy/trigger if exists ก่อน create · insert ... on conflict do nothing
-- ============================================================

set search_path = sri_os, public;

-- ------------------------------------------------------------
-- 1 · ค่าตั้งค่า: หน้าต่างกันกดปุ่มซ้ำ (วินาที)
--     อยู่ในตาราง settings ตามกฎเหล็กข้อ 5 (ห้าม hard-code ค่าที่ตั้งได้)
--     ค่าหายไป/อ่านไม่ได้ → ฟังก์ชันใช้ 60 วินาที (fail safe ไปทางกันซ้ำ ไม่ใช่ปล่อยซ้ำ)
-- ------------------------------------------------------------
insert into settings (key, value) values ('ledger.post_dedupe_seconds', '60'::jsonb)
on conflict (key) do nothing;

-- ------------------------------------------------------------
-- 2 · ร่องรอยคำขอ + กันกดปุ่มซ้ำ
--
-- ทำไมต้องกัน: กดปุ่มรัวสองครั้งในขั้นยืนยันเงิน = สองรายการที่เหมือนกันเป๊ะ
--   ซึ่งลบไม่ได้ (กฎเหล็กข้อ 1) ต้อง reverse ทีหลัง = งานซ่อมที่ไม่ควรมี
--
-- ทำไม fingerprint ไม่ใช่คีย์ที่หน้าจอส่งมา: คีย์ที่หน้าจอคิดเอง
--   (uuid v4 ต่อการกดปุ่ม) จะ **เปลี่ยนทุกครั้งที่ React render ใหม่/ผู้ใช้กด F5**
--   แล้วการกันซ้ำก็หายไปเงียบๆ โดยฝั่ง DB ไม่มีทางรู้ · DB คิดจากเนื้อคำขอเองแทน
--   (jsonb ทำให้ลำดับคีย์/ช่องว่างเป็นรูปแบบเดียวอยู่แล้ว → เทียบกันได้ตรงๆ)
--
-- ทำไมต้องมีหน้าต่างเวลา ไม่ใช่กันตลอดกาล: รายการที่เหมือนกันจริงมีอยู่
--   (ค่าแท็กซี่ 120 บาท สองใบในวันเดียวกัน หมวดเดียวกัน) · กันตลอดกาลแปลว่า
--   ใบที่สองลงไม่ได้ = **เงินหายไปจากสมุด** ซึ่งแย่กว่ารายการซ้ำที่มองเห็นและกลับรายการได้
--
-- ทำไม on conflict do update ... where: ล็อกแถว fingerprint ก่อนเริ่มลงรายการ
--   → สองคำขอที่มาพร้อมกัน (double-click จริงยิงขนานได้) ตัวที่สองจะ **รอ** ตัวแรก
--   commit แล้วประเมินเงื่อนไขใหม่ เห็นว่าอยู่ในหน้าต่าง → กลายเป็น replay
--   ถ้าใช้ select-ก่อน-insert ทั้งคู่จะเห็น "ยังไม่มี" แล้วลงทั้งสองรายการ
--
-- แถวนี้เกิดขึ้นเฉพาะคำขอที่ **สำเร็จ** เพราะคำขอที่ล้มจะ rollback ไปพร้อมกัน
--   → ยิงซ้ำหลัง error ไม่ติดด่านนี้ (ไม่มีสถานะค้างที่ทำให้ลองใหม่ไม่ได้)
-- ------------------------------------------------------------
create table if not exists post_entry_requests (
  id              uuid primary key default gen_random_uuid(),
  fingerprint     text not null unique,
  created_by      uuid not null default auth.uid() references app_users(id),
  transaction_ids uuid[] not null default '{}',
  created_at      timestamptz not null default now()
);

comment on table post_entry_requests is
  'ร่องรอยคำขอ post เข้า ledger + กันกดปุ่มซ้ำ · fingerprint = sha256(auth.uid() || payload) ที่ **DB คิดเอง** ไม่รับคีย์จากหน้าจอ · ซ้ำภายในหน้าต่าง settings.ledger.post_dedupe_seconds = คืน id ชุดเดิม ไม่ลงใหม่';
comment on column post_entry_requests.transaction_ids is
  'id ของรายการที่คำขอนี้สร้าง (เรียงตามลำดับใน payload) · ใช้ตอบ replay ให้หน้าจอพาไปดูรายการเดิมได้';

create index if not exists post_entry_requests_user_idx
  on post_entry_requests(created_by, created_at desc);

alter table post_entry_requests enable row level security;

-- แถวของตัวเองเท่านั้น · fingerprint ผูกกับ auth.uid() อยู่แล้ว จึงไม่มีแถวของคนอื่นให้แตะ
-- **ไม่มี policy DELETE** — ร่องรอยคำขอลบไม่ได้ (แนวเดียวกับทุกตารางฝั่งเงิน)
drop policy if exists post_entry_requests_read on post_entry_requests;
create policy post_entry_requests_read on post_entry_requests
  for select to authenticated using (created_by = auth.uid());

drop policy if exists post_entry_requests_insert on post_entry_requests;
create policy post_entry_requests_insert on post_entry_requests
  for insert to authenticated with check (created_by = auth.uid());

-- UPDATE จำเป็นเพราะ `insert ... on conflict do update` ต้องผ่าน policy ฝั่ง update ด้วย
drop policy if exists post_entry_requests_update on post_entry_requests;
create policy post_entry_requests_update on post_entry_requests
  for update to authenticated
  using (created_by = auth.uid()) with check (created_by = auth.uid());

-- DML ครบสี่ตัวตามแบบแผนของทุกตารางในสคีมานี้ (เทสต์ของ 20261007000000 ข้อ 2 บังคับ):
-- **ชั้น GRANT ไม่ใช่ที่กั้น** ไม่งั้นแอปถูกปฏิเสธก่อนถึง RLS แล้วอ่านไม่ออกว่าใครกั้น
-- ด่านจริงของการลบคือ **ไม่มี policy DELETE** → ลบไม่ได้ทุกตำแหน่งรวม super_admin
grant select, insert, update, delete on post_entry_requests to authenticated;
revoke all on post_entry_requests from anon;

-- TRUNCATE ไม่ยิง row trigger → ล้างทั้งตารางได้ในคำสั่งเดียวโดยไม่เหลือ audit
-- ใช้ fn_forbid_truncate ตัวเดียวกับตารางสมุดบัญชี (20261007000000) ไม่เขียนกฎซ้ำ
drop trigger if exists trg_forbid_truncate on post_entry_requests;
create trigger trg_forbid_truncate
  before truncate on post_entry_requests
  for each statement execute function fn_forbid_truncate();

-- audit: ทุกตารางใน sri_os ต้องมี (guard ของ 20261008000005 + เทสต์ X9 ไล่จาก pg_trigger จริง)
drop trigger if exists trg_audit_post_entry_requests on post_entry_requests;
create trigger trg_audit_post_entry_requests
  after insert or update or delete on post_entry_requests
  for each row execute function fn_audit();

-- ------------------------------------------------------------
-- 3 · D-092 · บัญชีที่ปิดใช้งานลงรายการใหม่ไม่ได้ ยกเว้นรายการกลับรายการ
--
--   เดิมกฎนี้อยู่ฝั่งเครื่องยนต์เท่านั้น (assertCashAccountsActive) ซึ่งพอรูที่
--   D-092 พูดถึงเปิดจริง (= ไฟล์นี้ ที่ทำให้เขียนลง DB ได้) ก็ไม่พออีกแล้ว:
--   ใครเรียก REST ตรงก็ลงบรรทัดเข้าบัญชีที่ปิดได้ · "ฟอร์มกันได้ แต่ฟอร์มไม่ใช่ที่กั้น"
--
--   ข้อยกเว้นอ่านจาก transactions.source = 'reverse' ซึ่ง **พิสูจน์ได้** เพราะ
--   fn_assert_reverse_link (20261007000000) บังคับทุก owner ว่า source='reverse'
--   ต้องมี reverses_id ที่ชี้ไปรายการจริงของผู้ถือเดียวกันที่ยังไม่ถูกกลับรายการ
--   → อ้างคำว่า reverse ลอยๆ เพื่อปลดด่านนี้ไม่ได้
--
--   security definer เพราะต้องอ่าน bank_accounts/transactions ให้ได้คำตอบจริง
--   ไม่ใช่ได้ null แล้วหลุดด่านเพราะผู้เรียกมองแถวนั้นไม่เห็น (เหตุผลเดียวกับ
--   fn_assert_line_writable) · ไม่เรียก fn_can เลย — กฎเงินใช้กับทุกคนเท่ากัน
-- ------------------------------------------------------------
create or replace function fn_assert_bank_account_open() returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare
  v_active boolean;
  v_label  text;
  v_source sri_os.txn_source;
begin
  if new.bank_account_id is null then return new; end if;

  select b.is_active, b.display_name into v_active, v_label
    from sri_os.bank_accounts b where b.id = new.bank_account_id;
  if v_active is null then
    raise exception 'บรรทัดเงินสดผูกกับบัญชีที่ไม่มีอยู่จริง (bank_account_id %)', new.bank_account_id;
  end if;
  if v_active then return new; end if;

  select t.source into v_source
    from sri_os.transactions t where t.id = new.transaction_id;
  if v_source = 'reverse' then return new; end if;

  raise exception 'บัญชี "%" ปิดใช้งานแล้ว ลงรายการใหม่เข้าบัญชีนี้ไม่ได้ (D-092) — ทำได้เฉพาะรายการกลับรายการของรายการเดิม', v_label;
end $fn$;

comment on function fn_assert_bank_account_open() is
  'D-092 · บัญชีที่ปิดใช้งานลงรายการใหม่ไม่ได้ · ยกเว้น transactions.source = reverse ซึ่ง fn_assert_reverse_link บังคับให้ชี้ไปรายการจริงอยู่แล้ว · trigger ไม่ใช่ RLS เพราะ policy ในอนาคตเขียนทับ RLS ได้';

drop trigger if exists trg_line_bank_account_open on transaction_lines;
create trigger trg_line_bank_account_open
  before insert on transaction_lines
  for each row execute function fn_assert_bank_account_open();

-- ------------------------------------------------------------
-- 4 · fn_post_entry — ปากทางเดียวที่หน้าจอใช้บันทึกรายการ
-- ------------------------------------------------------------
create or replace function fn_post_entry(p_payload jsonb) returns jsonb
language plpgsql set search_path = '' as $fn$
declare
  -- ช่องที่รู้จัก · เขียนไว้ที่เดียว ใช้ทั้งตรวจและเป็นเอกสาร (หัวไฟล์อ้างรายการนี้)
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
  v_secs     numeric;
  v_req      uuid;
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
  -- ไม่ใช่การตัดสินสิทธิ์ (RLS ตัดสิน) แต่เป็นเงื่อนไขที่ทำให้ข้อความอ่านรู้เรื่อง
  -- แทน error ดิบของ foreign key ตอน created_by = auth.uid() ชี้ไปแถวที่ไม่มี
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

    if v_txn -> 'lines' is null or jsonb_typeof(v_txn -> 'lines') <> 'array' then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % ไม่ได้ส่ง lines เป็น array', v_i;
    end if;
    if jsonb_array_length(v_txn -> 'lines') < 2 then
      raise exception 'บันทึกรายการไม่ได้: รายการที่ % มีบรรทัดบัญชี % บรรทัด — บัญชีสองด้านต้องมีอย่างน้อยสองบรรทัด',
        v_i, jsonb_array_length(v_txn -> 'lines');
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

  -- ========== 4 · cash_date ต้องสอดคล้องกับบรรทัดที่เครื่องยนต์ส่งมา ==========
  if v_has_cash and nullif(p_payload ->> 'cash_date', '') is null then
    raise exception 'บันทึกรายการไม่ได้: รายการนี้มีบรรทัดเงินสด/เงินฝาก แต่ไม่ได้ส่ง cash_date (วันที่เงินเข้า-ออกจริง) — ถ้าเงินยังไม่เคลื่อน ต้องลงเป็นลูกหนี้/เจ้าหนี้ ไม่ใช่เงินสด';
  end if;
  if not v_has_cash and nullif(p_payload ->> 'cash_date', '') is not null then
    raise exception 'บันทึกรายการไม่ได้: รายการนี้ไม่มีบรรทัดเงินสดเลย (ค้างรับ-ค้างจ่าย) cash_date ต้องเป็น null ไม่งั้นงบกระแสเงินสดจะนับเงินที่ยังไม่เคลื่อน';
  end if;

  -- ========== 5 · กันกดปุ่มซ้ำ — ล็อกแถว fingerprint ก่อนลงรายการ ==========
  select coalesce((s.value #>> '{}')::numeric, 60) into v_secs
    from sri_os.settings s where s.key = 'ledger.post_dedupe_seconds';
  v_secs := greatest(coalesce(v_secs, 60), 0);

  v_fp := encode(sha256(convert_to(auth.uid()::text || '|' || p_payload::text, 'UTF8')), 'hex');

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
  -- created_by ไม่อยู่ในรายการคอลัมน์โดยตั้งใจ: ใช้ default auth.uid()
  -- (ถ้ารับจาก payload จะกลายเป็นช่องปลอมตัวว่าใครคีย์)
  for v_txn in select value from jsonb_array_elements(p_payload -> 'transactions') loop
    insert into sri_os.transactions (
      owner_id, txn_type_code, doc_date, cash_date, doc_no, memo, attachments,
      asset_id, contact_id, contract_id, owner_reason, funding_source,
      source, source_ref, reverses_id,
      is_intercompany, counter_owner_id, intercompany_nature)
    values (
      (v_txn ->> 'owner_id')::uuid,
      p_payload ->> 'txn_type_code',
      (p_payload ->> 'doc_date')::date,
      (nullif(p_payload ->> 'cash_date', ''))::date,
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

  -- ด่านสมดุล/บรรทัดครบเป็น constraint trigger แบบ deferred (ยิงตอน commit)
  -- → บังคับให้ยิง **ตอนนี้** เพื่อให้คนกดปุ่มได้ข้อความที่อ่านรู้เรื่องทันที
  --   ไม่ใช่ error ตอน commit ที่หน้าจออ่านไม่ออกและไม่รู้ว่าใบไหนผิด
  --   นี่คือการทำให้ด่าน **เข้มขึ้น (เร็วขึ้น)** ไม่ใช่ผ่อน · แล้วคืนสภาพ deferred ให้เหมือนเดิม
  set constraints all immediate;
  set constraints all deferred;

  return jsonb_build_object(
    'transaction_ids', to_jsonb(v_ids),
    'replayed', false,
    'fingerprint', v_fp);
end $fn$;

comment on function fn_post_entry(jsonb) is
  'ปากทางเดียวที่เขียนผลลัพธ์ของ buildPosting() ลง transactions + transaction_lines ในธุรกรรมเดียว (D-091) · **security invoker** → RLS เป็นด่านเดียว · ไม่คิดคู่บัญชี/ยอดเงินเอง · ช่องที่ไม่รู้จักปฏิเสธทั้งใบ · กันกดซ้ำด้วย fingerprint ที่ DB คิดเองจากเนื้อคำขอ';

-- ------------------------------------------------------------
-- 5 · ACL — ฟังก์ชันใหม่ติด PUBLIC EXECUTE มาจาก Postgres ต้องปิดก่อนเปิดเท่าที่จำเป็น
--     (รูปแบบเดียวกับ 20261007000007 · ถ้าไม่ปิด anon เรียกได้)
-- ------------------------------------------------------------
revoke all on function fn_post_entry(jsonb) from public;
revoke all on function fn_assert_bank_account_open() from public;
do $$
begin
  execute 'revoke all on function sri_os.fn_post_entry(jsonb) from anon';
  execute 'grant execute on function sri_os.fn_post_entry(jsonb) to authenticated';
  -- trigger function เรียกตรงไม่ได้ทุก role (กฎเงินห้ามเรียกเอง/ห้ามปิด)
  execute 'revoke all on function sri_os.fn_assert_bank_account_open() from anon, authenticated';
end $$;

-- ------------------------------------------------------------
-- 6 · guard ท้ายไฟล์ — ต้อง "พังให้เห็น" ไม่ใช่ raise notice
-- ------------------------------------------------------------
do $$
declare v text;
begin
  -- (ก) fn_post_entry ต้องไม่เป็น SECURITY DEFINER (ADR: definer = ประตูหลังข้าม RLS)
  if (select p.prosecdef from pg_proc p where p.oid = 'sri_os.fn_post_entry(jsonb)'::regprocedure) then
    raise exception 'fn_post_entry เป็น SECURITY DEFINER = ทางข้าม RLS · ต้องเป็น invoker';
  end if;

  -- (ข) ไม่มีใครเรียกฟังก์ชันพวกนี้ได้นอกจากที่ตั้งใจ
  if has_function_privilege('public', 'sri_os.fn_post_entry(jsonb)', 'execute')
     or has_function_privilege('anon', 'sri_os.fn_post_entry(jsonb)', 'execute') then
    raise exception 'fn_post_entry ยังเปิดให้ public/anon เรียกได้';
  end if;
  if not has_function_privilege('authenticated', 'sri_os.fn_post_entry(jsonb)', 'execute') then
    raise exception 'authenticated เรียก fn_post_entry ไม่ได้ → หน้าจอใช้ไม่ได้';
  end if;
  if has_function_privilege('public', 'sri_os.fn_assert_bank_account_open()', 'execute')
     or has_function_privilege('authenticated', 'sri_os.fn_assert_bank_account_open()', 'execute') then
    raise exception 'trigger function fn_assert_bank_account_open เรียกตรงได้';
  end if;

  -- (ค) กฎเงินห้ามขึ้นกับสิทธิ์ — trigger function ของไฟล์นี้ต้องไม่เรียก fn_can
  select p.prosrc into v from pg_proc p
   where p.oid = 'sri_os.fn_assert_bank_account_open()'::regprocedure;
  if v ~* 'fn_can' then
    raise exception 'fn_assert_bank_account_open เรียก fn_can → ปิดกฎได้จากหน้า Settings';
  end if;

  -- (ง) ตารางร่องรอยคำขอต้องมี RLS + audit ครบสามคำสั่ง + ไม่มีทางลบ
  if not (select c.relrowsecurity from pg_class c
           where c.oid = 'sri_os.post_entry_requests'::regclass) then
    raise exception 'post_entry_requests ไม่ได้เปิด RLS';
  end if;
  if not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                  where tg.tgrelid = 'sri_os.post_entry_requests'::regclass
                    and p.proname = 'fn_audit'
                    and (tg.tgtype & 4) <> 0 and (tg.tgtype & 16) <> 0 and (tg.tgtype & 8) <> 0
                    and (tg.tgtype & 2) = 0 and (tg.tgtype & 1) <> 0) then
    raise exception 'post_entry_requests ไม่มี audit ครอบ insert+update+delete';
  end if;
  select string_agg(policyname || ' (' || cmd || ')', ', ') into v from pg_policies
   where schemaname = 'sri_os' and tablename = 'post_entry_requests' and cmd in ('DELETE', 'ALL');
  if v is not null then
    raise exception 'post_entry_requests มี policy ที่กว้างเกินไป: %', v;
  end if;
  -- ชั้น GRANT ต้องครบสี่ (RLS เป็นด่านเดียว) แต่ TRUNCATE ต้องไม่มี + ต้องมี trigger กัน
  if has_table_privilege('authenticated', 'sri_os.post_entry_requests', 'truncate') then
    raise exception 'authenticated มีสิทธิ์ TRUNCATE บน post_entry_requests';
  end if;
  if not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                  where tg.tgrelid = 'sri_os.post_entry_requests'::regclass
                    and p.proname = 'fn_forbid_truncate' and (tg.tgtype & 32) <> 0) then
    raise exception 'post_entry_requests ไม่มี trigger กัน TRUNCATE';
  end if;
  select string_agg(g.privilege_type, ', ') into v from information_schema.role_table_grants g
   where g.table_schema = 'sri_os' and g.table_name = 'post_entry_requests'
     and g.grantee = 'authenticated'
     and g.privilege_type in ('SELECT', 'INSERT', 'UPDATE', 'DELETE');
  if v is null or array_length(string_to_array(v, ', '), 1) <> 4 then
    raise exception 'authenticated ต้องมี DML ครบสี่ตัวบน post_entry_requests (ได้: %) · ด่านคือ RLS ไม่ใช่ GRANT', coalesce(v, '(ไม่มี)');
  end if;

  -- (จ) trigger กันบัญชีปิดต้องผูกกับ transaction_lines จริง (ไม่ใช่สร้างฟังก์ชันทิ้งไว้)
  if not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                  where tg.tgrelid = 'sri_os.transaction_lines'::regclass
                    and p.proname = 'fn_assert_bank_account_open'
                    and (tg.tgtype & 4) <> 0 and (tg.tgtype & 2) <> 0) then
    raise exception 'ไม่มี trigger before insert กันบัญชีปิดบน transaction_lines';
  end if;

  -- (ฉ) ค่าตั้งค่าต้องมีจริง (ฟังก์ชันมี fallback 60 วิ แต่ถ้าคีย์หายแปลว่าตั้งค่าจากหน้าจอไม่ได้)
  if not exists (select 1 from sri_os.settings where key = 'ledger.post_dedupe_seconds') then
    raise exception 'ไม่มีคีย์ settings.ledger.post_dedupe_seconds';
  end if;

  raise notice 'guard · fn_post_entry เป็น invoker · ACL แคบ · ตารางคำขอมี RLS+audit · trigger บัญชีปิดผูกแล้ว';
end $$;
