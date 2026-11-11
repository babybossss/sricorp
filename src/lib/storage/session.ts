import { createClient } from "@/lib/supabase/server";
import { storageReadiness } from "./readiness";
import { fail, MESSAGES, type StorageFailure } from "./errors";
import { isSameOrigin } from "./http";
import type { StorageClientLike } from "./server";

/**
 * จุดเข้าเดียวของ route handler: ตรวจ origin → env → ผู้ใช้ → ได้ client ของผู้ใช้ (publishable key + session)
 * ลำดับสำคัญ: env ไม่ครบต้องบอกชื่อตัวแปรก่อน ไม่ใช่ตกไปที่ 401 งงๆ
 */
export async function requireUserClient(
  req: Request
): Promise<{ ok: true; client: StorageClientLike; userId: string } | StorageFailure> {
  if (!isSameOrigin(req)) return fail("forbidden", "คำขอไม่ได้มาจากหน้าของระบบ");

  const ready = storageReadiness();
  if (!ready.ok) return ready;

  try {
    const supabase = await createClient();
    const { data, error } = await supabase.auth.getUser(); // ถามเซิร์ฟเวอร์ Auth ยืนยันจริง ไม่เชื่อ cookie เฉยๆ
    if (error || !data.user) return fail("not_signed_in", MESSAGES.not_signed_in);
    return { ok: true, client: supabase as unknown as StorageClientLike, userId: data.user.id };
  } catch (e) {
    return fail("server", MESSAGES.server, { detail: e instanceof Error ? e.message : String(e) });
  }
}
