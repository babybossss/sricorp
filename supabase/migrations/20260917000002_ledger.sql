-- ============================================================
-- SRI OS · 002 Ledger — transactions / lines / draft queue / audit
--
-- ทำอะไร: หัวใจเงินของระบบ พร้อม Money Invariants ที่บังคับด้วย trigger
--          ไม่ใช่แค่ที่ application เพราะ application bypass ได้ DB bypass ไม่ได้
-- ย้อนกลับ: drop table sri_os.transaction_lines, sri_os.transactions,
--            sri_os.draft_entries, sri_os.cash_confirmations, sri_os.audit_log cascade;
-- ============================================================

set search_path = sri_os, public;

do $$ begin
  create type txn_status as enum ('posted', 'void');
exception when duplicate_object then null; end $$;

do $$ begin
  create type draft_status as enum ('pending', 'approved', 'rejected');
exception when duplicate_object then null; end $$;

do $$ begin
  create type txn_source as enum ('manual', 'schedule', 'payroll', 'reimburse', 'import', 'reverse');
exception when duplicate_object then null; end $$;

-- ---------- audit log ----------
create table if not exists audit_log (
  id         bigserial primary key,
  table_name text not null,
  row_id     uuid not null,
  action     text not null check (action in ('insert', 'update', 'delete')),
  before     jsonb,
  after      jsonb,
  user_id    uuid,
  at         timestamptz not null default now()
);

create index if not exists audit_log_row_idx on audit_log(table_name, row_id);

create or replace function fn_audit() returns trigger
language plpgsql security definer set search_path = sri_os, public as $fn$
begin
  insert into audit_log(table_name, row_id, action, before, after, user_id)
  values (
    tg_table_name,
    coalesce(new.id, old.id),
    lower(tg_op),
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end,
    auth.uid()
  );
  return coalesce(new, old);
end $fn$;

-- ---------- transactions ----------
create table if not exists transactions (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null references owners(id),
  txn_type_code text not null references txn_types(code),
  -- doc_date เข้า P&L (accrual) · cash_date เข้า CF · null = ยังค้างรับ/ค้างจ่าย
  doc_date      date not null,
  cash_date     date,
  doc_no        text,
  status        txn_status not null default 'posted',
  asset_id      uuid,
  contact_id    uuid,
  contract_id   uuid,
  -- รายการข้าม owner ต้องระบุลักษณะ แล้วระบบสร้างขาอีกฝั่ง
  is_intercompany boolean not null default false,
  counter_owner_id uuid references owners(id),
  intercompany_nature text
    check (intercompany_nature in ('advance', 'loan', 'capital', 'dividend')),
  memo          text,
  attachments   text[] not null default '{}',
  -- สำรองไว้เฟส 2 ยังไม่มี VAT logic ใน MVP
  vat_rate      numeric(5,2),
  vat_amount    numeric(18,2),
  tax_invoice_no text,
  source        txn_source not null default 'manual',
  source_ref    text,
  -- รายการที่กลับ (reverse) ชี้กลับไปที่ตัวเดิม
  reverses_id   uuid references transactions(id),
  created_by    uuid references app_users(id),
  approved_by   uuid references app_users(id),
  created_at    timestamptz not null default now(),

  constraint intercompany_needs_nature check (
    not is_intercompany or (counter_owner_id is not null and intercompany_nature is not null)
  )
);

create index if not exists transactions_owner_date_idx on transactions(owner_id, doc_date desc);
create index if not exists transactions_cash_date_idx on transactions(cash_date);
create index if not exists transactions_asset_idx on transactions(asset_id);

-- ---------- transaction lines ----------
-- ยอดคงเหลือทุกอย่างคำนวณสดจากตารางนี้ ไม่เก็บยอดสะสมไว้ที่ไหน
create table if not exists transaction_lines (
  id              uuid primary key default gen_random_uuid(),
  transaction_id  uuid not null references transactions(id) on delete cascade,
  coa_id          uuid not null references chart_of_accounts(id),
  bank_account_id uuid references bank_accounts(id),
  debit           numeric(18,2) not null default 0 check (debit >= 0),
  credit          numeric(18,2) not null default 0 check (credit >= 0),
  cf_category     cf_group,
  asset_id        uuid,
  memo            text,

  -- บรรทัดหนึ่งเป็นได้อย่างเดียว เดบิตหรือเครดิต
  constraint one_side_only check ((debit > 0 and credit = 0) or (credit > 0 and debit = 0))
);

create index if not exists transaction_lines_txn_idx on transaction_lines(transaction_id);
create index if not exists transaction_lines_bank_idx on transaction_lines(bank_account_id);

-- ============================================================
-- Money Invariants — บังคับที่ DB
-- ============================================================

-- Invariant 1: ทุก transaction สมดุล Σ debit = Σ credit
create or replace function fn_assert_balanced() returns trigger
language plpgsql set search_path = sri_os, public as $fn$
declare
  v_txn uuid := coalesce(new.transaction_id, old.transaction_id);
  v_dr  numeric(18,2);
  v_cr  numeric(18,2);
begin
  select coalesce(sum(debit), 0), coalesce(sum(credit), 0)
    into v_dr, v_cr
    from transaction_lines where transaction_id = v_txn;

  -- ยอม 0 บรรทัดได้ระหว่างสร้าง แต่พอมีบรรทัดแล้วต้องสมดุล
  if v_dr <> v_cr then
    raise exception 'Money Invariant 1: transaction % ไม่สมดุล (debit %, credit %)', v_txn, v_dr, v_cr;
  end if;
  return null;
end $fn$;

drop trigger if exists trg_assert_balanced on transaction_lines;
create constraint trigger trg_assert_balanced
  after insert or update or delete on transaction_lines
  deferrable initially deferred
  for each row execute function fn_assert_balanced();

-- Invariant 2: ไม่มีเงินลอย — บรรทัดที่แตะบัญชีเงินสด/ธนาคารต้องมี bank_account_id
create or replace function fn_assert_no_floating_cash() returns trigger
language plpgsql set search_path = sri_os, public as $fn$
declare
  v_code text;
begin
  select code into v_code from chart_of_accounts where id = new.coa_id;
  -- ผังบัญชี 1100-1199 = เงินสดและเงินฝาก
  if v_code ~ '^11[0-9][0-9]$' and new.bank_account_id is null then
    raise exception 'Money Invariant 2: บรรทัดเงินสด/ธนาคาร (%) ต้องผูก bank_account_id', v_code;
  end if;
  return new;
end $fn$;

drop trigger if exists trg_no_floating_cash on transaction_lines;
create trigger trg_no_floating_cash
  before insert or update on transaction_lines
  for each row execute function fn_assert_no_floating_cash();

-- Invariant 4: ห้าม DELETE รายการที่ post แล้ว — มีแต่ void/reverse
create or replace function fn_forbid_delete_posted() returns trigger
language plpgsql set search_path = sri_os, public as $fn$
begin
  raise exception 'Money Invariant 4: ห้ามลบรายการที่บันทึกแล้ว ให้ใช้ reverse หรือ void แทน (id %)', old.id;
end $fn$;

drop trigger if exists trg_forbid_delete_posted on transactions;
create trigger trg_forbid_delete_posted
  before delete on transactions
  for each row execute function fn_forbid_delete_posted();

-- ห้ามแก้รายการของ owner ที่เป็น corporate_strict หลัง post
create or replace function fn_corporate_immutable() returns trigger
language plpgsql set search_path = sri_os, public as $fn$
declare
  v_policy owner_policy;
begin
  select policy into v_policy from owners where id = old.owner_id;
  if v_policy = 'corporate_strict'
     and old.status = 'posted'
     -- ยอมให้เปลี่ยนเป็น void ได้ (เส้นทาง reverse) แต่ห้ามแก้ตัวเลข/วันที่
     and not (new.status = 'void' and new.doc_date = old.doc_date) then
    raise exception 'Corporate strict: รายการที่บันทึกแล้วแก้ไม่ได้ ให้ reverse แล้วลงใหม่ (id %)', old.id;
  end if;
  return new;
end $fn$;

drop trigger if exists trg_corporate_immutable on transactions;
create trigger trg_corporate_immutable
  before update on transactions
  for each row execute function fn_corporate_immutable();

-- Corporate strict: ต้องมี contact + ไฟล์หลักฐาน
create or replace function fn_corporate_requires_evidence() returns trigger
language plpgsql set search_path = sri_os, public as $fn$
declare
  v_policy owner_policy;
  v_needs_contact boolean;
begin
  select policy into v_policy from owners where id = new.owner_id;
  if v_policy <> 'corporate_strict' then return new; end if;

  if new.source = 'reverse' then return new; end if;

  if cardinality(new.attachments) = 0 then
    raise exception 'Corporate strict: ต้องแนบหลักฐานก่อนบันทึก (txn_type %)', new.txn_type_code;
  end if;

  select requires_contact into v_needs_contact from txn_types where code = new.txn_type_code;
  if coalesce(v_needs_contact, false) and new.contact_id is null then
    raise exception 'Corporate strict: ประเภทรายการนี้ต้องระบุคู่ค้า (txn_type %)', new.txn_type_code;
  end if;

  return new;
end $fn$;

drop trigger if exists trg_corporate_evidence on transactions;
create trigger trg_corporate_evidence
  before insert on transactions
  for each row execute function fn_corporate_requires_evidence();

-- audit ทุกตารางการเงิน
drop trigger if exists trg_audit_transactions on transactions;
create trigger trg_audit_transactions
  after insert or update or delete on transactions
  for each row execute function fn_audit();

-- ---------- draft queue ----------
-- Automation ไม่เคย post เอง สร้างได้แค่ draft
create table if not exists draft_entries (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null references owners(id),
  txn_type_code text not null references txn_types(code),
  doc_date      date not null,
  cash_date     date,
  amount        numeric(18,2) not null,
  asset_id      uuid,
  contact_id    uuid,
  contract_id   uuid,
  memo          text,
  attachments   text[] not null default '{}',
  status        draft_status not null default 'pending',
  reject_reason text,
  due_date      date,
  batch_id      uuid,
  source        txn_source not null default 'manual',
  source_ref    text,
  -- เมื่ออนุมัติแล้วชี้ไปที่ transaction ที่สร้างขึ้น
  posted_txn_id uuid references transactions(id),
  created_by    uuid references app_users(id),
  reviewed_by   uuid references app_users(id),
  reviewed_at   timestamptz,
  created_at    timestamptz not null default now()
);

create index if not exists draft_entries_status_idx on draft_entries(status, due_date);

drop trigger if exists trg_audit_drafts on draft_entries;
create trigger trg_audit_drafts
  after insert or update or delete on draft_entries
  for each row execute function fn_audit();

-- ---------- cash confirmations ----------
create table if not exists cash_confirmations (
  id              uuid primary key default gen_random_uuid(),
  transaction_id  uuid references transactions(id),
  draft_entry_id  uuid references draft_entries(id),
  bank_account_id uuid not null references bank_accounts(id),
  expected_amount numeric(18,2) not null,
  actual_amount   numeric(18,2),
  actual_date     date,
  slip_url        text,
  -- รับบางส่วน: คงค้าง = expected - actual
  is_partial      boolean generated always as (
                    actual_amount is not null and actual_amount <> expected_amount
                  ) stored,
  confirmed_by    uuid references app_users(id),
  confirmed_at    timestamptz,

  constraint confirm_needs_source check (
    transaction_id is not null or draft_entry_id is not null
  )
);

-- ---------- month close ----------
create table if not exists period_closes (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references owners(id),
  period     date not null,
  closed_by  uuid references app_users(id),
  closed_at  timestamptz not null default now(),
  unique (owner_id, period)
);

-- ปิดงวดแล้วห้ามลงรายการย้อนเข้าไปในงวดนั้น (Corporate ล็อกถาวร)
create or replace function fn_period_locked() returns trigger
language plpgsql set search_path = sri_os, public as $fn$
declare
  v_policy owner_policy;
begin
  if exists (
    select 1 from period_closes
     where owner_id = new.owner_id
       and period = date_trunc('month', new.doc_date)::date
  ) then
    select policy into v_policy from owners where id = new.owner_id;
    if v_policy = 'corporate_strict' then
      raise exception 'งวด % ปิดแล้ว ลงรายการย้อนหลังไม่ได้ ให้ปรับปรุงในงวดปัจจุบัน', to_char(new.doc_date, 'MM/YYYY');
    end if;
  end if;
  return new;
end $fn$;

drop trigger if exists trg_period_locked on transactions;
create trigger trg_period_locked
  before insert on transactions
  for each row execute function fn_period_locked();
