import { isPermission, type Permission } from "./permissions";

/**
 * แปลงคำตอบของ **คำขอเดียว** ที่ `getAccess()` ยิงไปที่ DB:
 *
 *   sri_os.fn_my_access(array[<ชื่อสิทธิ์ทุกตัวที่ฝั่งนี้รู้จัก>])
 *     → { user_id, profile: {display_name, role_key, role_label, is_active} | null,
 *         permissions: { "<ชื่อสิทธิ์>": true|false, ... } }
 *
 * **ไฟล์นี้ไม่ตัดสินสิทธิ์** — มันแค่อ่าน boolean ที่ DB ตอบมา
 * ใครมีสิทธิ์อะไรอยู่ใน `sri_os.fn_can()` ที่เดียว (ซึ่ง RLS ก็ใช้ตัวเดียวกัน)
 * ห้ามเอา `roles` / `role_permissions` กลับมาไล่เองที่นี่อีก — เคยทำแล้วและมันคือ
 * **เกณฑ์สิทธิ์ที่สอง**: สิ่งที่หน้าจอโชว์กับสิ่งที่ DB บังคับแยกจากกันได้เงียบๆ
 * (เทสต์ `access-row.pg.test.ts` แดงถ้าไฟล์นี้หรือ `session.ts` เอ่ยถึงตารางพวกนั้น)
 *
 * ฟังก์ชันล้วน ไม่ import อะไรของ server จึงเทสต์ตรงๆ ได้
 */

/** ชื่อ RPC ที่ `getAccess()` เรียก — เทสต์ยืนยันว่าตรงกับฟังก์ชันที่มีจริงใน DB */
export const ACCESS_RPC = "fn_my_access";

export type AccessPayload = {
  user_id?: string | null;
  profile?: {
    display_name?: string | null;
    role_key?: string | null;
    role_label?: string | null;
    is_active?: boolean | null;
  } | null;
  permissions?: Record<string, unknown> | null;
};

export type AccessFromRow = {
  permissions: Set<Permission>;
  profile: { displayName: string; roleKey: string; roleLabel: string | null } | null;
};

export function accessFromPayload(payload: AccessPayload | null | undefined): AccessFromRow {
  // ไม่มีคำตอบ (ไม่ล็อกอิน · ไม่มีแถวใน app_users · อ่านไม่ได้) = ไม่มีสิทธิ์และไม่มีโปรไฟล์
  if (!payload || typeof payload !== "object") return { permissions: new Set(), profile: null };

  const p = payload.profile;
  const profile =
    p && typeof p.display_name === "string" && typeof p.role_key === "string"
      ? { displayName: p.display_name, roleKey: p.role_key, roleLabel: p.role_label ?? null }
      : null;

  const permissions = new Set<Permission>();
  // ไม่มีแถวใน `app_users` (ยังไม่ถูกตั้งตำแหน่ง) = ไม่มีสิทธิ์ ไม่ว่า DB จะตอบอะไรมา
  if (!profile) return { permissions, profile: null };
  // บัญชีที่ถูกปิดใช้งาน: DB ตอบ false ให้ทุกตัวอยู่แล้ว (`fn_can` เช็ค `is_active`)
  // ข้างล่างเป็นชั้นที่ **เอาสิทธิ์ออกได้เท่านั้น ไม่เคยเพิ่ม** จึงไม่ใช่เกณฑ์ที่สอง
  // (ถ้าวันหนึ่ง DB พลาด ฝั่งนี้ยังปิดอยู่ — ผิดทางที่ปลอดภัย)
  if (p?.is_active !== true) return { permissions, profile };

  for (const [key, allowed] of Object.entries(payload.permissions ?? {})) {
    // รับเฉพาะ `true` จริงๆ (string "true" / 1 / null ไม่ใช่การอนุญาต) และเฉพาะชื่อที่ฝั่งนี้รู้จัก
    // (`npm run check:permissions` เป็นตัวบอกว่าสองฝั่งมีชื่อไม่ตรงกัน)
    if (allowed === true && isPermission(key)) permissions.add(key);
  }
  return { permissions, profile };
}
