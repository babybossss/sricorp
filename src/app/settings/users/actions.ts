"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getAccess } from "@/lib/auth/session";
import { humanizeDbError } from "@/lib/db/post-entry";

/**
 * เปลี่ยนระดับสิทธิ์ / เปิด-ปิดการใช้งานผู้ใช้ — เขียน `app_users` จริง
 *
 * ด่านสิทธิ์คือ RLS (`users_write` ต้องมี users.manage) ไม่ใช่โค้ดนี้ · ระดับที่ใส่ต้องมีในตาราง `roles` (FK บังคับที่ DB)
 * **ไม่มีการลบผู้ใช้** ไม่ว่ากรณีใด — เลิกใช้งานคือ `is_active = false` (ประวัติที่อ้างถึงผู้ใช้ต้องหาเจอเสมอ)
 * ไม่แตะอีเมล ชื่อ หรือขอบเขตผู้ถือ (การแจกสิทธิ์เห็นผู้ถือเป็นงานแยก)
 *
 * กันล็อกตัวเองออกเป็น **ความสะดวก ไม่ใช่ด่านจริง**: DB ไม่ห้ามเปลี่ยน/ปิดตัวเอง และไม่ห้ามปิด super_admin คนสุดท้าย
 * (รายงานลูกพี่แล้ว) — action นี้ปฏิเสธสองกรณีนั้นก่อนเขียน แต่ผู้ที่ยิง SQL ตรงข้ามได้
 */
export type UserOutcome = { ok: true; message: string } | { ok: false; message: string };

export async function updateUserAccess(input: { userId: string; role: string; isActive: boolean }): Promise<UserOutcome> {
  const access = await getAccess();
  if (!access.user) return { ok: false, message: "เข้าสู่ระบบหมดอายุ — ให้เข้าสู่ระบบใหม่แล้วลองอีกครั้ง" };
  const role = String(input?.role ?? "").trim();
  if (!input?.userId || !role || typeof input.isActive !== "boolean") {
    return { ok: false, message: "ข้อมูลไม่ครบ (ผู้ใช้ ระดับสิทธิ์ สถานะ) — ยังไม่ได้เปลี่ยนอะไร" };
  }
  let db;
  try {
    db = await createClient();
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : String(e) };
  }

  const rolesRes = await db.from("roles").select("key");
  if (rolesRes.error) return { ok: false, message: humanizeDbError(rolesRes.error) };
  if (!((rolesRes.data ?? []) as { key: string }[]).some((r) => r.key === role)) {
    return { ok: false, message: `ไม่มีระดับสิทธิ์ "${role}" ในระบบ — ยังไม่ได้เปลี่ยนอะไร` };
  }

  const { data: cur, error: curErr } = await db.from("app_users").select("id, role, is_active").eq("id", input.userId).maybeSingle();
  if (curErr) return { ok: false, message: humanizeDbError(curErr) };
  // มองไม่เห็นกับไม่มีอยู่ตอบเหมือนกัน (RLS)
  if (!cur) return { ok: false, message: "ไม่พบผู้ใช้นี้ หรือคุณไม่มีสิทธิ์เห็น — ยังไม่ได้เปลี่ยนอะไร" };
  const before = cur as { id: string; role: string; is_active: boolean };
  if (before.role === role && before.is_active === input.isActive) return { ok: false, message: "ไม่มีอะไรเปลี่ยน — ระดับสิทธิ์และสถานะเหมือนเดิม" };

  if (input.userId === access.user.id) {
    return { ok: false, message: "แก้ระดับสิทธิ์หรือปิดบัญชีของตัวเองไม่ได้ — กันไม่ให้ล็อกตัวเองออกจากระบบ ให้ผู้ดูแลอีกท่านเป็นคนแก้ให้ · ยังไม่ได้เปลี่ยนอะไร" };
  }
  if (before.role === "super_admin" && before.is_active && (role !== "super_admin" || !input.isActive)) {
    const sa = await db.from("app_users").select("id").eq("role", "super_admin").eq("is_active", true);
    if (sa.error) return { ok: false, message: humanizeDbError(sa.error) };
    if (((sa.data ?? []) as unknown[]).length <= 1) {
      return { ok: false, message: "ลดระดับหรือปิดบัญชี Super Admin คนสุดท้ายไม่ได้ — จะไม่เหลือใครจัดการผู้ใช้ · ยังไม่ได้เปลี่ยนอะไร" };
    }
  }

  const { data, error } = await db.from("app_users").update({ role, is_active: input.isActive }).eq("id", input.userId).select("id");
  if (error) return { ok: false, message: humanizeDbError(error) };
  if (!data || data.length === 0) {
    return { ok: false, message: "ไม่มีสิทธิ์แก้ผู้ใช้นี้ — ฐานข้อมูลไม่แก้ให้ (ต้องมีสิทธิ์จัดการผู้ใช้) ยังไม่มีอะไรเปลี่ยน" };
  }
  revalidatePath("/settings/users");
  return { ok: true, message: "บันทึกแล้ว — ผู้ใช้ต้องออกแล้วเข้าใหม่จึงเห็นสิทธิ์ใหม่ครบ" };
}
