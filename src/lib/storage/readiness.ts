import { readSupabaseEnv } from "@/lib/supabase/env";
import { notConfigured, type StorageFailure } from "./errors";

/**
 * พร้อมใช้ไหม — ถามก่อนทำอะไรกับไฟล์แนบเสมอ
 *
 * env ไม่ครบ → คืน `not_configured` พร้อม **ชื่อตัวแปรที่ต้องตั้ง** (ไม่มีค่า)
 * **ห้ามตกกลับไปใช้ไฟล์จำลองเงียบๆ** — ถ้าตกกลับ ด่านหลักฐานของนิติบุคคล
 * จะตรวจชื่อไฟล์ปลอมต่อไปโดยไม่มีใครรู้ว่าไม่มีหลักฐานจริง
 * ใช้ได้ทั้ง browser และ server (publishable key เท่านั้น — env.ts ปฏิเสธ service-role เอง)
 */
export function storageReadiness(): { ok: true } | StorageFailure {
  const r = readSupabaseEnv();
  return r.ok ? { ok: true } : notConfigured(r.problems);
}
