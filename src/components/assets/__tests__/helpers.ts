import { readFileSync } from "node:fs";
import path from "node:path";
import type { Permission } from "@/lib/auth/permissions";
import type { Perms } from "../asset-drafts";

/**
 * สิทธิ์ของแต่ละตำแหน่ง **อ่านจาก migration จริง** ไม่พิมพ์ซ้ำในเทสต์
 * (ถ้าพิมพ์เอง เทสต์จะผ่านต่อให้ตารางใน DB เปลี่ยนไปแล้ว — แหล่งความจริงต้องมีที่เดียว)
 * รูปแบบแถว: ('คีย์', super_admin, management, manager, staff)
 * อ่านแถวไม่เจอ = โยน error ไม่คืนค่าว่างเงียบๆ
 */
const MIGRATIONS = path.resolve(__dirname, "../../../../supabase/migrations");
const ROLES = ["super_admin", "management", "manager", "staff"] as const;
export type RoleKey = (typeof ROLES)[number];

function grantRow(file: string, key: string): Record<RoleKey, boolean> {
  const sql = readFileSync(path.join(MIGRATIONS, file), "utf8");
  const re = new RegExp(`\\(\\s*'${key.replace(".", "\\.")}'\\s*,\\s*(true|false)\\s*,\\s*(true|false)\\s*,\\s*(true|false)\\s*,\\s*(true|false)\\s*\\)`);
  const m = re.exec(sql);
  if (!m) throw new Error(`ไม่พบแถวจับคู่ตำแหน่งของ ${key} ใน ${file}`);
  return Object.fromEntries(ROLES.map((r, i) => [r, m[i + 1] === "true"])) as Record<RoleKey, boolean>;
}

const GRANTS: [Permission, string][] = [
  ["asset.draft", "20261008000000_asset_permissions.sql"],
  ["asset.manage", "20261008000000_asset_permissions.sql"],
  ["asset.value", "20261008000000_asset_permissions.sql"],
  ["portfolio.view_all", "20261006190000_roles_permissions.sql"],
];

export function permsOf(role: RoleKey): Perms {
  const set = new Set<Permission>();
  for (const [key, file] of GRANTS) if (grantRow(file, key)[role]) set.add(key);
  return set;
}

export const STAFF = permsOf("staff");
export const MANAGER = permsOf("manager");
export const MANAGEMENT = permsOf("management");
export const SUPER_ADMIN = permsOf("super_admin");

export const actor = (id: string, perms: Perms) => ({ id, name: `ผู้ใช้ ${id}`, permissions: perms });
