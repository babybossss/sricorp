import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { effectivePatchKeys } from "./draft-whitelist";

/** ใช้เฉพาะสคริปต์/เทสต์ (node) — อย่า import จากโค้ดที่รันในเบราว์เซอร์ */
export function patchKeysFromMigrationsDir(dir = join(process.cwd(), "supabase", "migrations")) {
  const files = readdirSync(dir)
    .filter((f) => f.endsWith(".sql"))
    .sort()
    .map((name) => ({ name, sql: readFileSync(join(dir, name), "utf8") }));
  if (files.length === 0) throw new Error(`ไม่พบไฟล์ .sql ใน ${dir}`);
  return effectivePatchKeys(files);
}
