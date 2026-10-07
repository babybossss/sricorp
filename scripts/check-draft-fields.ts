/**
 * เทียบ `PATCH_FIELDS` (ฟอร์มร่างทรัพย์ฝั่ง TS) กับ whitelist ฝั่ง DB `fn_asset_draft_patch_keys()`
 * - TS ต้องเป็นชุดย่อยของ DB → ช่องที่ DB ไม่ยอมอยู่ใน TS = พัง (exit 1)
 * - DB มีช่องที่ TS ยังไม่รองรับ = เตือนอย่างเดียว (exit 0)
 * - อ่านไม่ออก / ชุดว่าง = พัง ไม่ใช่ผ่าน
 *
 * ใช้:
 *   npm run check:draft-fields -- --migrations              → เทียบกับ migration ในรีโป
 *   SRI_DB_URL=postgresql://... npm run check:draft-fields  → เทียบกับ DB จริง (SELECT อย่างเดียว ผ่าน psql)
 * ไม่ใส่ทั้งสองอย่าง = พัง
 */
import { execFileSync } from "node:child_process";
import { PATCH_FIELDS } from "../src/components/assets/asset-drafts";
import { patchKeysFromMigrationsDir } from "../src/lib/assets/draft-whitelist-fs";
import { describePatchKeyDiff, diffPatchKeys, patchKeysOk } from "../src/lib/assets/draft-whitelist";

function fromDb(url: string): string[] {
  const out = execFileSync(
    "psql",
    [url, "-v", "ON_ERROR_STOP=1", "-At", "-c", "select k from unnest(sri_os.fn_asset_draft_patch_keys()) k order by k"],
    { encoding: "utf8" }
  );
  return out.split("\n").map((s) => s.trim()).filter(Boolean);
}

function main(): void {
  const useMigrations = process.argv.includes("--migrations");
  const dbUrl = process.env.SRI_DB_URL;
  if (!useMigrations && !dbUrl)
    throw new Error("ไม่มีอะไรให้เทียบ — ตั้ง SRI_DB_URL หรือรันด้วย `-- --migrations`");

  let dbKeys: string[];
  let source: string;
  if (useMigrations) {
    const r = patchKeysFromMigrationsDir();
    dbKeys = r.keys;
    source = `migration ${r.source}`;
  } else {
    dbKeys = fromDb(dbUrl as string);
    source = "DB (sri_os.fn_asset_draft_patch_keys)";
  }

  const diff = diffPatchKeys(PATCH_FIELDS.map((f) => f.key), dbKeys);
  const msg = describePatchKeyDiff(diff);
  if (!patchKeysOk(diff)) throw new Error(`ช่องที่ร่างได้ไม่ตรงกับ ${source}\n${msg}`);
  if (msg) process.stderr.write(`${msg}\n`);
  process.stdout.write(`ตรงกัน: TS ${PATCH_FIELDS.length} ช่อง ⊆ ${source} ${dbKeys.length} ช่อง\n`);
}

try {
  main();
} catch (e) {
  process.stderr.write(`${e instanceof Error ? e.message : String(e)}\n`);
  process.exit(1);
}
