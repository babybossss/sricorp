-- ============================================================
-- SRI OS · 003 Assets, Contracts, Contacts
--
-- ทำอะไร: ทะเบียนทรัพย์ สัญญา ตารางงวดชำระ และผู้ติดต่อ
-- ย้อนกลับ: drop table sri_os.schedules, sri_os.contracts, sri_os.asset_valuations,
--            sri_os.assets, sri_os.contact_links, sri_os.contacts cascade;
-- ============================================================

set search_path = sri_os, public;

-- ---------- contacts ----------
-- Backlog ข้อ 3: ต้องสร้างได้จากในฟอร์มบันทึกรายการ
create table if not exists contacts (
  id          uuid primary key default gen_random_uuid(),
  first_name  text not null,
  last_name   text,
  -- คนหนึ่งเป็นได้หลายบทบาท เช่น เป็นทั้งผู้เช่าและผู้กู้
  types       text[] not null default '{}',
  phone       text,
  line_id     text,
  email       text,
  tax_id_last4 text,
  note        text,
  is_active   boolean not null default true,
  created_by  uuid references app_users(id),
  created_at  timestamptz not null default now()
);

create index if not exists contacts_name_idx on contacts(first_name, last_name);

create table if not exists contact_links (
  id         uuid primary key default gen_random_uuid(),
  contact_id uuid not null references contacts(id) on delete cascade,
  target_type text not null check (target_type in ('asset', 'contract', 'card', 'listing')),
  target_id  uuid not null,
  role       text,
  unique (contact_id, target_type, target_id, role)
);

-- ---------- asset taxonomy (config แก้ได้) ----------
create table if not exists asset_classes (
  id      uuid primary key default gen_random_uuid(),
  code    text not null unique,
  name_th text not null,
  sort_order int not null default 0
);

create table if not exists asset_categories (
  id       uuid primary key default gen_random_uuid(),
  class_id uuid not null references asset_classes(id),
  code     text not null unique,
  name_th  text not null,
  is_active boolean not null default true,
  sort_order int not null default 0
);

-- ---------- assets ----------
create table if not exists assets (
  id           uuid primary key default gen_random_uuid(),
  code         text not null unique,
  name         text not null,
  class_id     uuid not null references asset_classes(id),
  category_id  uuid not null references asset_categories(id),
  -- ผู้ถือกรรมสิทธิ์จริง — ถือในชื่อบุคคลก็ยังเป็นเงินกองกลาง
  owner_id     uuid not null references owners(id),
  holding_nature text not null default 'beneficial'
                 check (holding_nature in ('beneficial', 'nominee')),
  beneficiary_id uuid references owners(id),
  status       text not null default 'active'
               check (status in ('active', 'inactive', 'sold', 'redeemed')),
  acquired_date date,
  disposed_date date,
  location     text,
  ticker       text,
  units        numeric(18,6),
  currency     text not null default 'THB',
  manager_user_id uuid references app_users(id),
  tags         text[] not null default '{}',
  created_at   timestamptz not null default now()
);

create index if not exists assets_owner_idx on assets(owner_id);
create index if not exists assets_category_idx on assets(category_id);

-- ต้นทุนคำนวณสดจาก ledger ไม่เก็บไว้ในคอลัมน์ กันค่าค้าง
create or replace function fn_asset_cost_basis(p_asset uuid)
returns numeric language sql stable set search_path = sri_os, public as $fn$
  select coalesce(sum(l.debit - l.credit), 0)
    from transaction_lines l
    join transactions t on t.id = l.transaction_id
    join chart_of_accounts c on c.id = l.coa_id
   where l.asset_id = p_asset
     and t.status = 'posted'
     and c.type = 'asset'
     -- ไม่นับบรรทัดเงินสด เพราะเป็นอีกขาของรายการเดียวกัน
     and c.code !~ '^11[0-9][0-9]$';
$fn$;

comment on function fn_asset_cost_basis is 'ต้นทุนของทรัพย์ คำนวณสดจาก ledger ใช้เป็นฐานคำนวณ Cap Gain/Loss ตอนขาย';

-- ---------- valuations ----------
create table if not exists asset_valuations (
  id        uuid primary key default gen_random_uuid(),
  asset_id  uuid not null references assets(id) on delete cascade,
  as_of     date not null,
  method    text not null
            check (method in ('market_api', 'appraisal', 'treasury', 'manual', 'cost')),
  unit_price numeric(18,6),
  value     numeric(18,2) not null,
  source_url text,
  note      text,
  created_by uuid references app_users(id),
  created_at timestamptz not null default now(),
  unique (asset_id, as_of, method)
);

-- ราคาเก่าเกิน 7 วันให้ขึ้นธง ไม่ใช่เก็บเป็นคอลัมน์ที่ต้องมาอัปเดตเอง
create or replace view v_asset_latest_value as
select distinct on (v.asset_id)
       v.asset_id, v.as_of, v.method, v.value, v.source_url,
       (current_date - v.as_of) > 7 as is_stale
  from asset_valuations v
 order by v.asset_id, v.as_of desc, v.created_at desc;

-- ---------- contracts ----------
-- Backlog ข้อ 2: เงื่อนไขสัญญากู้/ให้กู้ ต้องกรอกครบถึงจะสร้างตารางงวดได้
create table if not exists contracts (
  id             uuid primary key default gen_random_uuid(),
  code           text unique,
  asset_id       uuid references assets(id),
  owner_id       uuid not null references owners(id),
  type           text not null
                 check (type in ('lease', 'sale_leaseback', 'mortgage', 'loan_payable',
                                 'loan_receivable', 'service')),
  -- ยืมจากใคร / ให้ใครยืม
  counterparty_contact_id uuid references contacts(id),
  principal      numeric(18,2),
  rate           numeric(7,4),
  rate_period    text check (rate_period in ('year', 'month', 'day')),
  -- วิธีคิดดอกเบี้ย
  interest_method text check (interest_method in ('flat', 'effective', 'simple')),
  start_date     date,
  end_date       date,
  payment_day    smallint check (payment_day between 1 and 31),
  installments   int,
  deposit        numeric(18,2),
  -- ขายฝาก: ช่วงส่ง Notice และวันครบกำหนดไถ่ถอน
  notice_window_start date,
  notice_window_end   date,
  redemption_deadline date,
  collateral_note text,
  -- บังคับ ≥ 1 ไฟล์ ระบบนี้เก็บข้อมูลสัญญา ไม่ใช่เครื่องมือร่างสัญญา
  file_urls      text[] not null default '{}',
  status         text not null default 'active'
                 check (status in ('draft', 'active', 'closed', 'defaulted')),
  created_at     timestamptz not null default now()
);

create index if not exists contracts_asset_idx on contracts(asset_id);
create index if not exists contracts_counterparty_idx on contracts(counterparty_contact_id);

-- ข้อมูลครบกี่ % — ใช้โชว์ใน Data health และกันการสร้างตารางงวดจากสัญญาที่ยังไม่ครบ
create or replace function fn_contract_completeness(p_contract uuid)
returns int language sql stable set search_path = sri_os, public as $fn$
  select (
    (case when principal is not null then 1 else 0 end) +
    (case when rate is not null then 1 else 0 end) +
    (case when start_date is not null then 1 else 0 end) +
    (case when end_date is not null or installments is not null then 1 else 0 end) +
    (case when counterparty_contact_id is not null then 1 else 0 end) +
    (case when cardinality(file_urls) > 0 then 1 else 0 end)
  ) * 100 / 6
  from contracts where id = p_contract;
$fn$;

-- ---------- schedules ----------
-- สร้างจากเงื่อนไขสัญญา หน้า "ยืนยันรับ-จ่าย" และ "ค้างรับ/ค้างจ่าย" ดึงไปใช้
create table if not exists schedules (
  id            uuid primary key default gen_random_uuid(),
  contract_id   uuid not null references contracts(id) on delete cascade,
  period        int not null,
  due_date      date not null,
  expected_amount numeric(18,2) not null,
  -- แยกเงินต้น/ดอกเบี้ยตั้งแต่ตอนสร้างตารางงวด (backlog ข้อ 5)
  principal_amount numeric(18,2) not null default 0,
  interest_amount  numeric(18,2) not null default 0,
  txn_type_code text references txn_types(code),
  draft_entry_id uuid references draft_entries(id),
  status        text not null default 'upcoming'
                check (status in ('upcoming', 'drafted', 'approved', 'received', 'overdue', 'waived')),
  created_at    timestamptz not null default now(),
  unique (contract_id, period)
);

create index if not exists schedules_due_idx on schedules(due_date, status);

-- ยอดรวมของงวดต้องเท่ากับเงินต้น + ดอกเบี้ย
alter table schedules drop constraint if exists schedule_amount_split;
alter table schedules add constraint schedule_amount_split
  check (principal_amount + interest_amount = expected_amount);

-- กันสร้างตารางงวดจากสัญญาที่ข้อมูลไม่ครบ
create or replace function fn_schedule_requires_complete_contract() returns trigger
language plpgsql set search_path = sri_os, public as $fn$
begin
  if fn_contract_completeness(new.contract_id) < 100 then
    raise exception 'สัญญา % ข้อมูลยังไม่ครบ สร้างตารางงวดไม่ได้ (ครบ %%)',
      new.contract_id, fn_contract_completeness(new.contract_id);
  end if;
  return new;
end $fn$;

drop trigger if exists trg_schedule_complete on schedules;
create trigger trg_schedule_complete
  before insert on schedules
  for each row execute function fn_schedule_requires_complete_contract();

-- FK ที่รอตารางปลายทางอยู่
alter table transactions drop constraint if exists transactions_asset_fk;
alter table transactions add constraint transactions_asset_fk
  foreign key (asset_id) references assets(id);
alter table transactions drop constraint if exists transactions_contact_fk;
alter table transactions add constraint transactions_contact_fk
  foreign key (contact_id) references contacts(id);
alter table transactions drop constraint if exists transactions_contract_fk;
alter table transactions add constraint transactions_contract_fk
  foreign key (contract_id) references contracts(id);
