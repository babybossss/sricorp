/**
 * Postgres ในเครื่องสำหรับเทสต์ที่ต้องพิสูจน์กับ DB จริง — **ไม่แตะ Supabase project จริงเด็ดขาด**
 *
 * สร้าง DB ชั่วคราวชื่อไม่ซ้ำ (ต่อ pid + เวลา) ใส่ของจำลองฝั่ง Supabase (roles · auth.uid() · schema storage)
 * แล้วรัน migration ทุกไฟล์ตามลำดับเดียวกับ `scripts/test-rls-local.sh` / `supabase/migration-order.txt`
 * (ไฟล์ที่อยู่ในรายการลำดับรันท้ายสุดตามที่เขียน · ที่เหลือเรียงตามชื่อ LC_ALL=C) — ไม่มีไฟล์ใดถูกข้าม ถ้าไฟล์ไหนพัง = ดังทันที
 * ไม่มี Postgres ในเครื่อง → `pgAvailable = false` และเทสต์ที่ใช้ไฟล์นี้ถูกข้ามพร้อมเหตุผล (ตั้ง SRI_REQUIRE_PG=1 ให้พังแทน)
 *
 * ลบ DB ทิ้งเสมอตอนจบ (`dropDb`) รวมถึงตอนโปรเซสออกกลางทาง
 */

import { execFileSync, spawnSync } from "node:child_process";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";

const REPO = path.resolve(__dirname, "../../../../..");
const asRoot = typeof process.getuid === "function" && process.getuid() === 0;

function runPsql(db: string, sql: string): { ok: boolean; out: string; err: string } {
  const args = ["-v", "ON_ERROR_STOP=1", "-q", "-At", "-d", db, "-f", "-"];
  const r = asRoot
    ? spawnSync("su", ["postgres", "-c", `psql ${args.map((a) => `'${a}'`).join(" ")}`], { input: sql, encoding: "utf8", maxBuffer: 256 * 1024 * 1024 })
    : spawnSync("psql", args, { input: sql, encoding: "utf8", maxBuffer: 256 * 1024 * 1024 });
  return { ok: r.status === 0, out: r.stdout ?? "", err: r.stderr ?? "" };
}

function admin(cmd: string): { ok: boolean; err: string } {
  const r = asRoot ? spawnSync("su", ["postgres", "-c", cmd], { encoding: "utf8" }) : spawnSync("sh", ["-c", cmd], { encoding: "utf8" });
  return { ok: r.status === 0, err: r.stderr ?? "" };
}

export const pgAvailable: boolean = (() => {
  try {
    execFileSync("psql", ["--version"], { stdio: "ignore" });
  } catch {
    return false;
  }
  return runPsql("postgres", "select 1;").ok;
})();

if (!pgAvailable && process.env.SRI_REQUIRE_PG === "1") {
  throw new Error("SRI_REQUIRE_PG=1 แต่ไม่มี Postgres ในเครื่อง (psql ใช้ไม่ได้) — เทสต์กับ DB จริงข้ามไม่ได้");
}

/** error จาก psql → ข้อความที่ DB `raise exception` (ตัดบรรทัด CONTEXT/HINT/DETAIL ออก) */
export function errorText(stderr: string): string {
  const m = /ERROR:\s+([\s\S]*?)(?:\nCONTEXT:|\nHINT:|\nDETAIL:|\nQUERY:|\npsql:|$)/.exec(stderr);
  return (m ? m[1] : stderr).trim();
}

export class SqlError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SqlError";
  }
}

export type TestDb = {
  name: string;
  /** รัน SQL ในฐานะ superuser (เตรียมข้อมูล · ตรวจ) แล้วคืนผลเป็นข้อความ -At */
  su(sql: string): string;
  /** รัน SQL ในธุรกรรมเดียวในฐานะ `authenticated` ของผู้ใช้ที่ระบุ (RLS บังคับจริง) — error = โยก SqlError(ข้อความของ DB) */
  as(uid: string, sql: string): string;
  /** `select` ที่คืนแถวเป็น JSON array */
  rows<T = Record<string, unknown>>(sql: string): T[];
  /** ตัวเลขเดี่ยว (ผลต่างในสมุด) */
  num(sql: string): number;
  drop(): void;
};

const BOOTSTRAP = `
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role; end if;
end $$;
create schema if not exists auth;
create table if not exists auth.users (id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as $fn$ select nullif(current_setting('test.uid', true), '')::uuid $fn$;
create schema if not exists sri_os;
grant usage on schema auth to anon, authenticated, service_role;
create schema storage;
create table storage.buckets (id text primary key, name text not null, public boolean default false, file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text references storage.buckets(id), name text, owner uuid, owner_id text, created_at timestamptz default now(), updated_at timestamptz default now(), metadata jsonb, unique (bucket_id, name));
alter table storage.objects enable row level security;
create or replace function storage.foldername(name text) returns text[] language plpgsql as $fn$
declare _parts text[];
begin select string_to_array(name, '/') into _parts; return _parts[1:array_length(_parts, 1) - 1]; end $fn$;
grant usage on schema storage to anon, authenticated, service_role;
grant all on storage.objects, storage.buckets to anon, authenticated, service_role;
grant execute on function storage.foldername(text) to anon, authenticated, service_role;
`;

/** ลำดับ migration: รายการใน migration-order.txt รันท้ายสุดตามที่เขียน · ที่เหลือเรียงตามชื่อ */
function migrationPlan(): { before: string[]; ordered: string[] } {
  const dir = path.join(REPO, "supabase/migrations");
  const ordered = readFileSync(path.join(REPO, "supabase/migration-order.txt"), "utf8")
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith("#"));
  const others = readdirSync(dir)
    .filter((f) => f.endsWith(".sql") && !ordered.includes(f))
    .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  return { before: others.map((f) => path.join(dir, f)), ordered: ordered.map((f) => path.join(dir, f)) };
}

export function createTestDb(): TestDb {
  const name = `srios_imp_${process.pid}_${Date.now().toString(36)}`;
  const created = admin(`createdb ${name}`);
  if (!created.ok) throw new Error(`สร้าง DB ทดสอบไม่ได้: ${created.err}`);
  let dropped = false;
  const drop = () => {
    if (dropped) return;
    dropped = true;
    admin(`dropdb --if-exists --force ${name}`);
  };
  process.once("exit", drop);

  try {
    const boot = runPsql(name, BOOTSTRAP);
    if (!boot.ok) throw new Error(`ของจำลองฝั่ง Supabase พัง: ${boot.err}`);
    // ไฟล์ที่ไม่อยู่ในรายการลำดับแต่พึ่งไฟล์ในรายการ (เช่น migration ใหม่ที่ยังไม่ถูกเพิ่มใน migration-order.txt) พังรอบแรก
    // → เลื่อนไปลองใหม่หลังไฟล์ลำดับครบ · ยังพังอีก = ดังทันที (ไม่ข้ามเงียบ)
    const { before, ordered } = migrationPlan();
    const deferred: string[] = [];
    for (const f of before) {
      const r = runPsql(name, readFileSync(f, "utf8"));
      if (!r.ok) deferred.push(f);
    }
    for (const f of ordered) {
      const r = runPsql(name, readFileSync(f, "utf8"));
      if (!r.ok) throw new Error(`migration พัง ${path.basename(f)}: ${errorText(r.err)}`);
    }
    for (const f of deferred) {
      const r = runPsql(name, readFileSync(f, "utf8"));
      if (!r.ok) throw new Error(`migration พัง ${path.basename(f)}: ${errorText(r.err)}`);
    }
  } catch (e) {
    drop();
    throw e;
  }

  const su = (sql: string) => {
    const r = runPsql(name, sql);
    if (!r.ok) throw new SqlError(errorText(r.err));
    return r.out.trim();
  };
  const as = (uid: string, sql: string) => {
    // set local role + GUC อยู่ในธุรกรรมเดียวกับคำสั่ง — ไม่ค้างข้ามคำสั่ง
    const r = runPsql(name, `begin; set local role authenticated; set local "test.uid" = '${uid}';\n${sql}\ncommit;`);
    if (!r.ok) throw new SqlError(errorText(r.err));
    return r.out.trim();
  };
  return {
    name,
    su,
    as,
    rows: <T,>(sql: string) => JSON.parse(su(`select coalesce(json_agg(t), '[]'::json) from (${sql}) t;`) || "[]") as T[],
    num: (sql: string) => Number(su(`select (${sql});`)),
    drop,
  };
}
