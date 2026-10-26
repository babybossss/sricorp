import { isPermission, type Permission } from "./permissions";

/**
 * แถวเดียวที่ `getAccess()` ถาม DB: ผู้ใช้ + ระดับสิทธิ์ + สิทธิ์ของระดับนั้น (embed ผ่าน FK ใน PostgREST)
 *
 *   app_users(display_name, role, is_active, roles(label, role_permissions(permission_key)))
 *
 * แทนการเรียก `fn_can()` ทีละสิทธิ์ (16 round trip ต่อหนึ่งหน้า) — ความหมายต้องเท่ากับ `fn_can` ทุกประการ:
 *   มีสิทธิ์ ⇔ ผู้ใช้มีแถวใน app_users ∧ is_active ∧ ระดับของเขามีสิทธิ์นั้นใน role_permissions
 * ผู้ใช้ไม่ active = ไม่มีสิทธิ์ใดเลย (แต่ยังมี profile ให้หน้าจอบอกว่าถูกปิดใช้งาน) · ไม่มีแถว = ไม่มีทั้งสิทธิ์และ profile
 * เทสต์ `access-row.pg.test.ts` เทียบกับ `fn_can` ของ DB จริงทุกระดับ/ทุกสิทธิ์ เพื่อให้สองทางนี้แยกจากกันไม่ได้เงียบๆ
 *
 * ฟังก์ชันล้วน ไม่ import อะไรของ server จึงเทสต์ตรงๆ ได้
 */

export type AccessRow = {
  display_name: string;
  role: string;
  is_active: boolean;
  roles: RoleEmbed | RoleEmbed[] | null;
};
type RoleEmbed = { label: string; role_permissions: { permission_key: string }[] | null };

export const ACCESS_SELECT = "display_name, role, is_active, roles(label, role_permissions(permission_key))";

export type AccessFromRow = {
  permissions: Set<Permission>;
  profile: { displayName: string; roleKey: string; roleLabel: string | null } | null;
};

export function accessFromRow(row: AccessRow | null): AccessFromRow {
  if (!row) return { permissions: new Set(), profile: null };
  const roleRow = Array.isArray(row.roles) ? row.roles[0] : row.roles;
  const profile = { displayName: row.display_name, roleKey: row.role, roleLabel: roleRow?.label ?? null };
  // ผู้ใช้ที่ปิดใช้งาน หรือระดับที่อ่านไม่ได้ → ไม่มีสิทธิ์ใดเลย (ล้มเหลว = ไม่มีสิทธิ์)
  if (row.is_active !== true || !roleRow) return { permissions: new Set(), profile };
  // คีย์ที่ TS ยังไม่รู้จักถูกทิ้ง (`npm run check:permissions` เป็นตัวบอกว่าสองฝั่งไม่ตรงกัน)
  const permissions = new Set<Permission>();
  for (const rp of roleRow.role_permissions ?? []) if (isPermission(rp.permission_key)) permissions.add(rp.permission_key);
  return { permissions, profile };
}
