import { PERMISSIONS } from "./permissions";

/**
 * เทียบรายการสิทธิ์ใน TypeScript กับของใน DB — ฟังก์ชันบริสุทธิ์ ไว้ให้สคริปต์และเทสต์ใช้ร่วมกัน
 */

export type PermissionDiff = {
  /** มีใน DB แต่ TS ยังไม่รู้จัก (เพิ่มสิทธิ์ใน DB แล้วลืมเพิ่ม union) */
  missingInTs: string[];
  /** มีใน TS แต่ DB ไม่มี (พิมพ์ผิด หรือ DB ยังไม่ migrate) */
  missingInDb: string[];
};

export function diffPermissions(dbKeys: readonly string[], tsKeys: readonly string[] = PERMISSIONS): PermissionDiff {
  const db = new Set(dbKeys);
  const ts = new Set(tsKeys);
  return {
    missingInTs: [...db].filter((k) => !ts.has(k)).sort(),
    missingInDb: [...ts].filter((k) => !db.has(k)).sort(),
  };
}

export const isInSync = (d: PermissionDiff) => d.missingInTs.length === 0 && d.missingInDb.length === 0;

/**
 * ดึงรายการสิทธิ์ที่ migration ไฟล์ seed ตาราง `permissions` (โหมด offline ไม่ต้องต่อ DB)
 * อ่านเฉพาะบล็อก `insert into permissions (...) values ... on conflict`
 * — บล็อก role_permissions ที่หน้าตาคล้ายกันไม่ถูกนับ
 * ถ้าหาบล็อกไม่เจอ = โยน error (ไม่คืน [] เงียบๆ ไม่งั้นจะดูเหมือน "ไม่มีสิทธิ์ใน DB")
 */
export function permissionKeysFromMigration(sql: string): string[] {
  const block = sql.match(/insert\s+into\s+(?:sri_os\.)?permissions\s*\([^)]*\)\s*values([\s\S]*?)on\s+conflict/i);
  if (!block) throw new Error("ไม่พบบล็อก insert into permissions ใน migration");
  const keys = [...block[1].matchAll(/^\s*\(\s*'([a-z_.]+)'\s*,/gm)].map((m) => m[1]);
  if (keys.length === 0) throw new Error("พบบล็อก permissions แต่อ่านคีย์ไม่ได้ — รูปแบบ migration เปลี่ยนไป ต้องแก้ตัวอ่าน");
  return keys;
}

export function describeDiff(d: PermissionDiff): string {
  const out: string[] = [];
  if (d.missingInTs.length)
    out.push(`DB มีสิทธิ์ที่ TypeScript ไม่รู้จัก: ${d.missingInTs.join(", ")} → เพิ่มใน src/lib/auth/permissions.ts`);
  if (d.missingInDb.length)
    out.push(`TypeScript มีสิทธิ์ที่ DB ไม่มี: ${d.missingInDb.join(", ")} → แก้ชื่อให้ตรง หรือเพิ่มใน DB ด้วย migration`);
  return out.join("\n");
}
