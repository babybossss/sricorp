"use server";

import { getAccess } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";
import { loadReference } from "@/lib/db/reference";
import { readFxContext, type FxContextState } from "@/lib/db/fx-context-server";

/**
 * ข้อมูลเงินตราของบัญชี FCD สำหรับฟอร์มแปลงค่า/แลกเงิน — อ่านจากสมุดสดตาม session ของผู้ใช้ (RLS)
 *
 * ใช้แสดงในฟอร์มและคิดตัวอย่างบรรทัดบัญชีเท่านั้น · **ตอนบันทึกจริง `postEntry` อ่านซ้ำเองทุกครั้ง**
 * ไม่เชื่อสิ่งที่ฟอร์มถือไว้ (ยอดคงเหลือเก่าได้ทุกเสี้ยววินาที)
 */
export async function loadFxContext(req: { ownerId: string; bankAccountId: string }): Promise<FxContextState> {
  const access = await getAccess();
  if (!access.user) return { ok: false, message: "เข้าสู่ระบบหมดอายุ — ให้เข้าสู่ระบบใหม่" };
  if (!req || typeof req.ownerId !== "string" || typeof req.bankAccountId !== "string") {
    return { ok: false, message: "ยังไม่ได้เลือกผู้ถือและบัญชี" };
  }
  const refState = await loadReference();
  if (!refState.ok) return { ok: false, message: `โหลดข้อมูลผู้ถือและบัญชีไม่ได้ (${refState.error})` };
  let supabase;
  try {
    supabase = await createClient();
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : String(e) };
  }
  return readFxContext(supabase, refState.ref, req);
}
