import { describe, it, expect } from "vitest";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { PATCH_FIELDS } from "@/components/assets/asset-drafts";
import {
  WhitelistParseError, describePatchKeyDiff, diffPatchKeys, effectivePatchKeys, patchKeysFromSql, patchKeysOk,
} from "../draft-whitelist";
import { patchKeysFromMigrationsDir } from "../draft-whitelist-fs";

const fn = (inner: string, tail = "::text[]") =>
  `create or replace function fn_asset_draft_patch_keys() returns text[]\nlanguage sql immutable set search_path = '' as $fn$\n  select array[${inner}]${tail};\n$fn$;`;

describe("ตัวอ่าน whitelist จาก SQL — พังเสียงดังเมื่ออ่านไม่ออก (ไม่คืนชุดว่าง)", () => {
  it("อ่านช่องได้ พร้อมข้ามคอมเมนต์ในอาร์เรย์", () => {
    const sql = fn(`'name', 'class_id',\n -- 'not_a_field' ตัวนี้เป็นคอมเมนต์\n 'ticker'`);
    expect(patchKeysFromSql(sql)).toEqual(["name", "class_id", "ticker"]);
  });
  it("ไฟล์ที่ไม่ define ฟังก์ชัน = null (ไม่ใช่ [])", () => {
    expect(patchKeysFromSql("select 1;")).toBeNull();
    expect(patchKeysFromSql("-- เรียก fn_asset_draft_patch_keys() เฉยๆ\nselect fn_asset_draft_patch_keys();")).toBeNull();
  });
  it("define แต่อาร์เรย์ว่าง → พัง", () => {
    expect(() => patchKeysFromSql(fn(""))).toThrow(WhitelistParseError);
    expect(() => patchKeysFromSql(fn("\n -- ช่องทั้งหมดถูกคอมเมนต์\n -- 'name'\n"))).toThrow(/0 ช่อง/);
  });
  it("define แต่ไม่ใช่ array literal → พัง", () => {
    const sql = "create or replace function fn_asset_draft_patch_keys() returns text[] language sql as $fn$ select array(select column_name from information_schema.columns) $fn$;";
    expect(() => patchKeysFromSql(sql)).toThrow(WhitelistParseError);
  });
  it("array ต่อกับนิพจน์อื่น หรือมีสิ่งแปลกปนใน array → พัง ไม่อ่านได้ครึ่งเดียว", () => {
    expect(() => patchKeysFromSql(fn(`'name'`, ` || array['x']`))).toThrow(WhitelistParseError);
    expect(() => patchKeysFromSql(fn(`'name', lower('X')`))).toThrow(WhitelistParseError);
  });
  it("ช่องซ้ำ / ชื่อผิดรูปแบบ → พัง", () => {
    expect(() => patchKeysFromSql(fn(`'name', 'name'`))).toThrow(/ซ้ำ/);
    expect(() => patchKeysFromSql(fn(`'Name x'`))).toThrow(/ผิดรูปแบบ/);
  });
  it("define ชื่อนี้แต่รูปแบบ dollar-quote เปลี่ยน → พัง ไม่ใช่ข้าม", () => {
    const sql = "create function fn_asset_draft_patch_keys() returns text[] language sql as 'select array[''name'']';";
    expect(() => patchKeysFromSql(sql)).toThrow(WhitelistParseError);
  });
  it("หลายไฟล์: ไฟล์ท้ายสุดที่ define ชนะ · ไม่มีไฟล์ไหน define = พัง", () => {
    const r = effectivePatchKeys([
      { name: "2", sql: fn(`'name', 'ticker'`) },
      { name: "1", sql: fn(`'name'`) },
      { name: "3", sql: "select 1;" },
    ]);
    expect(r).toEqual({ keys: ["name", "ticker"], source: "2" });
    expect(() => effectivePatchKeys([{ name: "1", sql: "select 1;" }])).toThrow(/ไม่พบ migration/);
    expect(() => effectivePatchKeys([])).toThrow(WhitelistParseError);
  });
});

describe("ตัวเทียบ TS ⊆ DB", () => {
  it("ช่องที่ DB ไม่ยอม = ผิด · ช่องที่ TS ยังไม่รองรับ = เตือนอย่างเดียว", () => {
    const d = diffPatchKeys(["name", "fake"], ["name", "ticker"]);
    expect(d).toEqual({ notAllowedByDb: ["fake"], notSupportedInTs: ["ticker"] });
    expect(patchKeysOk(d)).toBe(false);
    expect(patchKeysOk(diffPatchKeys(["name"], ["name", "ticker"]))).toBe(true);
    expect(describePatchKeyDiff(diffPatchKeys(["name"], ["name", "ticker"]))).toMatch(/^WARN.*ticker/);
  });
  it("whitelist ฝั่ง DB ว่าง → ปฏิเสธ (ไม่ผ่านเงียบ)", () => {
    expect(() => diffPatchKeys(["name"], [])).toThrow(WhitelistParseError);
  });
});

describe("PATCH_FIELDS เทียบกับ migration จริงในรีโป", () => {
  const real = patchKeysFromMigrationsDir();

  it("อ่าน whitelist จริงได้ครบ (ไม่ใช่ชุดว่าง/ครึ่งเดียว)", () => {
    expect(real.keys.length).toBeGreaterThanOrEqual(16);
    expect(real.keys).toEqual(expect.arrayContaining(["name", "ownership_pct", "size_note"]));
  });

  it("PATCH_FIELDS ⊆ whitelist ฝั่ง DB — ช่องที่ DB ไม่ยอมต้องไม่อยู่ในฟอร์ม", () => {
    const d = diffPatchKeys(PATCH_FIELDS.map((f) => f.key), real.keys);
    expect(d.notAllowedByDb, describePatchKeyDiff(d)).toEqual([]);
    if (d.notSupportedInTs.length) console.warn(describePatchKeyDiff(d));
  });

  it("สคริปต์ `npm run check:draft-fields -- --migrations` ผ่าน (exit 0)", () => {
    const r = spawnSync(join(process.cwd(), "node_modules", ".bin", "tsx"), ["scripts/check-draft-fields.ts", "--migrations"], {
      encoding: "utf8", cwd: process.cwd(),
    });
    expect(r.status, r.stderr).toBe(0);
    expect(r.stdout).toMatch(/ตรงกัน/);
  });

  it("สคริปต์ไม่มีแหล่งให้เทียบ = พัง ไม่ใช่ผ่านเฉยๆ", () => {
    const r = spawnSync(join(process.cwd(), "node_modules", ".bin", "tsx"), ["scripts/check-draft-fields.ts"], {
      encoding: "utf8", cwd: process.cwd(), env: { ...process.env, SRI_DB_URL: "" },
    });
    expect(r.status).toBe(1);
  });
});
