-- ============================================================
-- SRI OS · 001 Core — เจ้าของ / บัญชีธนาคาร / ผังบัญชี / ประเภทรายการ
--
-- ทำอะไร: สร้างตารางอ้างอิงที่ทุกอย่างอื่นพึ่งพา
-- ย้อนกลับ: drop schema sri_os cascade;  (ทำได้เฉพาะตอนยังไม่มีข้อมูลจริง)
-- ============================================================

create schema if not exists sri_os;
set search_path = sri_os, public;

create extension if not exists "pgcrypto";

-- ---------- enum ----------
do $$ begin
  create type owner_type as enum ('company', 'person');
exception when duplicate_object then null; end $$;

do $$ begin
  -- Corporate = เข้ม 100% · Personal = ยืดหยุ่นได้แต่ Money Invariants ห้ามละเมิด
  create type owner_policy as enum ('corporate_strict', 'personal_flexible');
exception when duplicate_object then null; end $$;

do $$ begin
  create type coa_type as enum ('asset', 'liability', 'equity', 'income', 'expense');
exception when duplicate_object then null; end $$;

do $$ begin
  -- transfer = โอนระหว่างบัญชีตัวเอง ตัดทิ้งตอน consolidate
  create type cf_group as enum ('operating', 'investing', 'financing', 'transfer', 'none');
exception when duplicate_object then null; end $$;

-- ---------- owners ----------
create table if not exists owners (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,
  type          owner_type not null,
  policy        owner_policy not null,
  name_th       text not null,
  name_en       text,
  -- เก็บแค่ 4 ตัวท้าย ห้ามเก็บเลขผู้เสียภาษีเต็มในตารางธรรมดา
  tax_id_last4  text,
  vat_registered boolean not null default false,
  -- 'planned' = นิติบุคคลที่ยังไม่จดทะเบียน ซ่อนจากรายงาน
  status        text not null default 'active'
                check (status in ('active', 'inactive', 'planned')),
  color         text,
  sort_order    int not null default 0,
  created_at    timestamptz not null default now()
);

comment on table owners is 'ผู้ถือกรรมสิทธิ์ — ทุกอย่างยังเป็นกองกลาง SRI Family ตารางนี้บอกแค่ว่าใครถือ';

-- ---------- chart of accounts ----------
create table if not exists chart_of_accounts (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  name_th     text not null,
  name_en     text,
  type        coa_type not null,
  parent_id   uuid references chart_of_accounts(id),
  peak_code   text,
  is_active   boolean not null default true,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now()
);

-- ---------- bank accounts ----------
create table if not exists bank_accounts (
  id               uuid primary key default gen_random_uuid(),
  owner_id         uuid not null references owners(id),
  bank             text not null,
  account_name     text not null,
  display_name     text not null,
  account_no_last4 text,
  coa_id           uuid references chart_of_accounts(id),
  opening_balance  numeric(18,2) not null default 0,
  opening_date     date,
  short_label      text,
  color            text,
  -- ลำดับนี้คือลำดับที่แสดงในตัวเลือกบัญชีทุกฟอร์ม
  sort_order       int not null default 0,
  -- ปิดใช้งาน = ซ่อนจาก dropdown แต่ยังอยู่ในรายงานย้อนหลัง
  is_active        boolean not null default true,
  created_at       timestamptz not null default now()
);

create index if not exists bank_accounts_owner_idx on bank_accounts(owner_id);

-- ---------- txn_types (ตารางกฎ) ----------
-- แหล่งความจริงคือ src/lib/rules/tx-rules.ts ตารางนี้คือ seed ที่ sync มา
-- ผู้ใช้ตั้งค่าได้เฉพาะ is_active และ name_th ส่วนคู่บัญชีแก้ผ่าน PR เท่านั้น
create table if not exists txn_types (
  code            text primary key,
  group_code      text not null,
  name_th         text not null,
  name_en         text,
  cf_group        cf_group not null,
  -- +1 เงินเข้า, -1 เงินออก, 0 สองทาง (transfer)
  direction       smallint not null check (direction in (-1, 0, 1)),
  dr_coa_code     text references chart_of_accounts(code),
  cr_coa_code     text references chart_of_accounts(code),
  affects_pl      boolean not null default false,
  pl_line         text,
  requires_asset   boolean not null default false,
  requires_contact boolean not null default false,
  -- ต้องเปิดฟอร์มเงื่อนไขสัญญา (backlog ข้อ 2)
  requires_loan_terms boolean not null default false,
  -- ต้องคำนวณกำไร/ขาดทุนจากการขาย (backlog ข้อ 4)
  requires_capital_gain boolean not null default false,
  -- ต้องแยกเงินต้น/ดอกเบี้ย (backlog ข้อ 5)
  requires_principal_split boolean not null default false,
  plain_th        text,
  caution_th      text,
  is_active       boolean not null default true,
  sort_order      int not null default 0
);

comment on table txn_types is 'ตารางกฎเดียวที่ระบบอ้างอิง — ประเภทรายการ → หมวดย่อย → ผลกระทบต่องบ';

-- ---------- app users ----------
create table if not exists app_users (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text not null,
  display_name text not null,
  -- Management อนุมัติได้และข้ามขั้นได้ · Manager/User สร้างได้ต้องรออนุมัติ
  role        text not null default 'user'
              check (role in ('management', 'manager', 'user')),
  owner_id    uuid references owners(id),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ---------- settings ----------
create table if not exists settings (
  key         text primary key,
  value       jsonb not null,
  updated_by  uuid references app_users(id),
  updated_at  timestamptz not null default now()
);
