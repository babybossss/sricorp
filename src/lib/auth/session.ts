import { cache } from "react";
import { connection } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { PERMISSIONS, type Permission } from "./permissions";
import { ACCESS_RPC, accessFromPayload, type AccessPayload } from "./access-row";

/**
 * ผู้ใช้ปัจจุบัน + ชุดสิทธิ์ — ถาม DB หนึ่งครั้งต่อ request (react `cache`)
 * ใช้ได้เฉพาะ server component / server action / route handler
 *
 * **สิทธิ์มาจาก `sri_os.fn_can()` ที่เดียว** (ตัวเดียวกับที่ RLS ใช้) โดยถามผ่าน
 * `fn_my_access(array[...])` ครั้งเดียวต่อหนึ่งหน้า — ฝั่งนี้ไม่มีเกณฑ์สิทธิ์ของตัวเอง
 * และ **ห้ามอ่าน `roles`/`role_permissions` เอง** (เคยทำแล้ว = กฎสองที่ · ดู access-row.ts)
 * ถามด้วย session ของผู้ใช้เอง (ไม่ใช้สิทธิ์ที่สูงกว่า) และ **ล้มเหลว = ไม่มีสิทธิ์**
 * พร้อมเหตุผลให้หน้าจอบอก ไม่ใช่เงียบ · ไม่แคชข้าม request (react `cache` ต่อ request เท่านั้น)
 */

export type CurrentUser = { id: string; email: string | null };

export type AppProfile = { displayName: string; roleKey: string; roleLabel: string | null };

export type AccessState = {
  user: CurrentUser | null;
  permissions: ReadonlySet<Permission>;
  /** ลงทะเบียนใน app_users แล้วและ active (ถ้าไม่ใช่ ทุกสิทธิ์จะเป็น false) */
  profile: AppProfile | null;
  /** ตรวจสิทธิ์กับ DB ไม่สำเร็จ (เช่น schema ยังไม่ expose) — permissions จะว่าง */
  error: string | null;
};

const EMPTY: ReadonlySet<Permission> = new Set();

export const getAccess = cache(async (): Promise<AccessState> => {
  // สิทธิ์ขึ้นกับผู้ใช้ → ห้าม prerender ตอน build เด็ดขาด (กันไว้อีกชั้นนอกจาก cookies())
  await connection();
  let supabase;
  try {
    supabase = await createClient();
  } catch (e) {
    return { user: null, permissions: EMPTY, profile: null, error: e instanceof Error ? e.message : String(e) };
  }

  // getUser() ถามเซิร์ฟเวอร์ Auth ยืนยันตัวตนจริง (getSession() เชื่อ cookie ได้ไม่เท่า)
  const { data, error: userErr } = await supabase.auth.getUser();
  if (userErr || !data.user) {
    return { user: null, permissions: EMPTY, profile: null, error: null };
  }
  const user: CurrentUser = { id: data.user.id, email: data.user.email ?? null };

  // **ถาม DB ครั้งเดียว**: โปรไฟล์ + คำตอบของทุกสิทธิ์ (เดิมเรียก fn_can ทีละสิทธิ์ = 16 round trip ต่อหน้า)
  // สิ่งที่ส่งไปคือ **คำถาม** (ชื่อสิทธิ์ที่ฝั่งนี้รู้จัก) ไม่ใช่คำตอบ — คำตอบมาจาก fn_can ทั้งหมด
  // ถามด้วย session ของผู้ใช้เอง (RLS บังคับ: เห็นโปรไฟล์ของตัวเองเท่านั้น) · ล้มเหลว = ไม่มีสิทธิ์ พร้อมเหตุผล
  const { data: payload, error } = await supabase.rpc(ACCESS_RPC, {
    p_permissions: PERMISSIONS as unknown as string[],
  });
  if (error) {
    return { user, permissions: EMPTY, profile: null, error: `ตรวจสิทธิ์กับฐานข้อมูลไม่สำเร็จ (${error.message})` };
  }
  const { permissions, profile } = accessFromPayload(payload as unknown as AccessPayload | null);

  return { user, permissions, profile, error: null };
});

/** `can("ledger.approve")` — เช็คจากชุดสิทธิ์ที่ถามจาก DB ไว้แล้วใน request นี้ */
export async function can(permission: Permission): Promise<boolean> {
  return (await getAccess()).permissions.has(permission);
}

export async function canAny(...permissions: Permission[]): Promise<boolean> {
  const { permissions: set } = await getAccess();
  return permissions.some((p) => set.has(p));
}
