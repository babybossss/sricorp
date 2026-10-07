/**
 * เทียบ union type `Permission` (src/lib/auth/permissions.ts) กับตาราง `permissions` ใน DB
 * **พังทันทีถ้าไม่ตรง** — แบบเดียวกับ `npm run sync:rules` ที่พังเมื่อฟิลด์ไม่ครบ
 * กันกรณีเพิ่มสิทธิ์ใน DB แล้วหน้าจอไม่รู้จัก (หรือสะกดต่างกัน = เมนูโชว์/ซ่อนผิดเงียบๆ)
 *
 * ใช้:
 *   SRI_DB_URL=postgresql://... npm run check:permissions   → เทียบกับ DB จริง (อ่านอย่างเดียว)
 *   npm run check:permissions -- --migrations               → เทียบกับ migration ในรีโป (ไม่ต้องต่อ DB)
 *
 * ไม่ใส่ทั้งสองอย่าง = พัง (exit 1) ไม่ใช่ผ่านเฉยๆ — เช็คที่ไม่ได้เช็คอะไรห้ามรายงานว่าผ่าน
 * โหมด DB เรียก `psql` (ไม่เพิ่ม dependency) ด้วยคำสั่ง SELECT อย่างเดียว
 * สคริปต์นี้ไม่ได้ถูกรันกับ project จริงโดยอัตโนมัติ — ผู้ใช้เป็นคนใส่ SRI_DB_URL เอง
 */
import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { PERMISSIONS } from "../src/lib/auth/permissions";
import {
  describeDiff,
  diffPermissions,
  isInSync,
  permissionKeysFromMigration,
} from "../src/lib/auth/permission-check";

function fromDb(url: string): string[] {
  const out = execFileSync("psql", [url, "-v", "ON_ERROR_STOP=1", "-At", "-c", "select key from sri_os.permissions order by key"], {
    encoding: "utf8",
  });
  return out.split("\n").map((s) => s.trim()).filter(Boolean);
}

function fromMigrations(): string[] {
  const dir = join(process.cwd(), "supabase", "migrations");
  const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
  const keys = new Set<string>();
  let found = false;
  for (const f of files) {
    const sql = readFileSync(join(dir, f), "utf8");
    if (!/insert\s+into\s+(?:sri_os\.)?permissions\s*\(/i.test(sql)) continue;
    found = true;
    for (const k of permissionKeysFromMigration(sql)) keys.add(k);
  }
  if (!found) throw new Error(`ไม่พบ migration ที่ seed ตาราง permissions ใน ${dir}`);
  return [...keys];
}

function main(): void {
  const useMigrations = process.argv.includes("--migrations");
  const dbUrl = process.env.SRI_DB_URL;

  if (!useMigrations && !dbUrl) {
    throw new Error(
      "ไม่มีอะไรให้เทียบ — ตั้ง SRI_DB_URL เพื่อเทียบกับ DB จริง หรือรันด้วย `-- --migrations` เพื่อเทียบกับ migration ในรีโป"
    );
  }

  const source = useMigrations ? "migration ในรีโป" : "DB (sri_os.permissions)";
  const dbKeys = useMigrations ? fromMigrations() : fromDb(dbUrl as string);
  const diff = diffPermissions(dbKeys);

  if (!isInSync(diff)) {
    throw new Error(`สิทธิ์ไม่ตรงกับ ${source}\n${describeDiff(diff)}`);
  }
  process.stdout.write(`ตรงกัน: ${PERMISSIONS.length} สิทธิ์ (TypeScript = ${source})\n`);
}

try {
  main();
} catch (e) {
  process.stderr.write(`${e instanceof Error ? e.message : String(e)}\n`);
  process.exit(1);
}
