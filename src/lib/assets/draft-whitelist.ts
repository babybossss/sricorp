/**
 * whitelist ของช่องที่ร่างทะเบียนทรัพย์แก้ได้ — ตัวอ่านจากไฟล์ migration + ตัวเทียบ (ฟังก์ชันบริสุทธิ์ ไม่แตะ fs)
 *
 * แหล่งความจริงอยู่ที่ DB: `fn_asset_draft_patch_keys()` (trigger บังคับ) · ฝั่ง TS (`PATCH_FIELDS`) ต้องเป็น **ชุดย่อย**
 * - TS รู้จักช่องที่ DB ไม่ยอม  → พัง (ผู้ใช้กรอกแล้วกดส่งไม่ได้ โดยไม่รู้ว่าทำไม)
 * - DB มีช่องที่ TS ยังไม่รองรับ → เตือน (งานที่ยังไม่ได้ทำ ไม่ใช่ความผิดพลาด)
 *
 * **ตัวอ่านพังเสียงดังเมื่ออ่านไม่ออก** ห้ามคืน [] — ชุดว่างทำให้ "ชุดย่อย" จริงเสมอ = เทสต์ผ่านโดยไม่ตรวจอะไร
 */

export class WhitelistParseError extends Error {}

const FN_NAME = "fn_asset_draft_patch_keys";

/**
 * ดึงรายชื่อช่องจาก SQL ของ migration หนึ่งไฟล์ · คืน `null` ถ้าไฟล์นี้ไม่ได้ (re)define ฟังก์ชัน
 * ถ้าไฟล์ define ฟังก์ชันแต่อ่านรูปแบบไม่ออก → โยน `WhitelistParseError`
 * รองรับเฉพาะรูปแบบ `select array['a', 'b', ...]::text[]` — โครงสร้างอื่น (array(select..), ต่อ array, ตัวแปร)
 * จะพังพร้อมบอกให้แก้ตัวอ่าน แทนที่จะอ่านได้ครึ่งเดียวเงียบๆ
 */
export function patchKeysFromSql(sql: string): string[] | null {
  const def = new RegExp(
    `create\\s+(?:or\\s+replace\\s+)?function\\s+(?:sri_os\\.)?${FN_NAME}\\s*\\(\\s*\\)\\s*returns\\s+text\\s*\\[\\s*\\]([\\s\\S]*?)(?:\\$(\\w*)\\$)([\\s\\S]*?)\\$\\2\\$`,
    "i"
  ).exec(sql);
  if (!def) {
    // ไม่ define ในไฟล์นี้ — แต่ถ้ามีคำว่า create function ... ชื่อนี้อยู่ ทั้งที่ regex ไม่เจอ = รูปแบบเปลี่ยน ต้องพัง
    if (new RegExp(`create\\s+(?:or\\s+replace\\s+)?function\\s+(?:sri_os\\.)?${FN_NAME}\\b`, "i").test(sql))
      throw new WhitelistParseError(`พบการ define ${FN_NAME}() แต่อ่านรูปแบบไม่ออก (ต้องเป็น $tag$ ... $tag$) — แก้ตัวอ่านที่ src/lib/assets/draft-whitelist.ts`);
    return null;
  }
  const body = def[3].replace(/--[^\n]*/g, ""); // ตัดคอมเมนต์ก่อน (คอมเมนต์ในอาร์เรย์มีคำที่ดูเหมือนช่อง)
  const arr = /\barray\s*\[((?:'[^']*'|[^\]'])*)\]/i.exec(body);
  if (!arr) throw new WhitelistParseError(`${FN_NAME}() ไม่มี array['...'] ให้อ่าน — รูปแบบเปลี่ยน ต้องแก้ตัวอ่าน`);

  // ส่วนที่เหลือหลังเอา string literal ออกต้องเป็นแค่ , และช่องว่าง — กัน array(select ..) / || / ฟังก์ชัน ที่อ่านได้ไม่ครบ
  const leftover = arr[1].replace(/'[^']*'/g, "").replace(/[\s,]/g, "");
  if (leftover !== "")
    throw new WhitelistParseError(`array ใน ${FN_NAME}() มีโครงสร้างที่ตัวอ่านไม่รองรับ ("${leftover.slice(0, 40)}") — แก้ตัวอ่านแทนการเดา`);
  const tail = body.slice((arr.index ?? 0) + arr[0].length).replace(/\s+/g, "");
  if (!/^(?:::text\[\])?;?$/i.test(tail))
    throw new WhitelistParseError(`หลัง array ใน ${FN_NAME}() ยังมีนิพจน์อื่น ("${tail.slice(0, 40)}") — ตัวอ่านอ่านได้ไม่ครบ`);

  const keys = [...arr[1].matchAll(/'([^']*)'/g)].map((m) => m[1]);
  if (keys.length === 0) throw new WhitelistParseError(`${FN_NAME}() อ่านได้ 0 ช่อง — ชุดว่างทำให้การเทียบผ่านโดยไม่ตรวจอะไร`);
  const bad = keys.filter((k) => !/^[a-z][a-z0-9_]*$/.test(k));
  if (bad.length) throw new WhitelistParseError(`ชื่อช่องผิดรูปแบบ: ${bad.join(", ")}`);
  const dup = keys.filter((k, i) => keys.indexOf(k) !== i);
  if (dup.length) throw new WhitelistParseError(`ช่องซ้ำใน ${FN_NAME}(): ${[...new Set(dup)].join(", ")}`);
  return keys;
}

/**
 * ไฟล์ migration เรียงตามชื่อ (เก่า → ใหม่) · **ไฟล์ท้ายสุดที่ define ฟังก์ชันชนะ** (create or replace)
 * ไม่มีไฟล์ไหน define เลย = พัง
 */
export function effectivePatchKeys(files: readonly { name: string; sql: string }[]): { keys: string[]; source: string } {
  let found: { keys: string[]; source: string } | null = null;
  for (const f of [...files].sort((a, b) => a.name.localeCompare(b.name))) {
    let keys: string[] | null;
    try {
      keys = patchKeysFromSql(f.sql);
    } catch (e) {
      throw new WhitelistParseError(`${f.name}: ${e instanceof Error ? e.message : String(e)}`);
    }
    if (keys) found = { keys, source: f.name };
  }
  if (!found) throw new WhitelistParseError(`ไม่พบ migration ที่ define ${FN_NAME}() เลย (ค้นจาก ${files.length} ไฟล์)`);
  return found;
}

export type PatchKeyDiff = {
  /** TS รู้จัก แต่ DB ไม่ยอม → ความผิดพลาด */
  notAllowedByDb: string[];
  /** DB อนุญาต แต่ TS ยังไม่รองรับ → เตือน */
  notSupportedInTs: string[];
};

export function diffPatchKeys(tsKeys: readonly string[], dbKeys: readonly string[]): PatchKeyDiff {
  if (dbKeys.length === 0) throw new WhitelistParseError("whitelist ฝั่ง DB ว่าง — ปฏิเสธการเทียบ (ผ่านโดยไม่ตรวจอะไร)");
  const db = new Set(dbKeys);
  const ts = new Set(tsKeys);
  return {
    notAllowedByDb: [...ts].filter((k) => !db.has(k)).sort(),
    notSupportedInTs: [...db].filter((k) => !ts.has(k)).sort(),
  };
}

export const patchKeysOk = (d: PatchKeyDiff) => d.notAllowedByDb.length === 0;

export function describePatchKeyDiff(d: PatchKeyDiff): string {
  const out: string[] = [];
  if (d.notAllowedByDb.length)
    out.push(`ERROR: PATCH_FIELDS มีช่องที่ DB ไม่ยอม: ${d.notAllowedByDb.join(", ")} → ผู้ใช้กรอกแล้วส่งร่างไม่ได้ · ถอดออกจาก TS หรือเพิ่มใน fn_asset_draft_patch_keys() ด้วย migration`);
  if (d.notSupportedInTs.length)
    out.push(`WARN: DB อนุญาตแต่ฟอร์มยังไม่รองรับ ${d.notSupportedInTs.length} ช่อง: ${d.notSupportedInTs.join(", ")}`);
  return out.join("\n");
}
