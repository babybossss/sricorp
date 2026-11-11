"use server";

import { getAccess } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";
import { loadReference } from "@/lib/db/reference";
import { readDisposalContext, type DisposalContextState } from "@/lib/db/disposal-context-server";

/**
 * ต้นทุน/รีโนเวท/ส่วนเกินทุนของทรัพย์ที่จะขาย — อ่านจากสมุดสดตาม session ของผู้ใช้ (RLS) สำหรับแสดงในฟอร์ม
 * **ตอนบันทึกจริง `postEntry` อ่านซ้ำเองทุกครั้ง** ไม่เชื่อค่าที่ฟอร์มถือไว้
 */
export async function loadDisposalContext(req: { ownerId: string; assetId: string }): Promise<DisposalContextState> {
  const access = await getAccess();
  if (!access.user) return { ok: false, message: "เข้าสู่ระบบหมดอายุ — ให้เข้าสู่ระบบใหม่" };
  if (!req || typeof req.ownerId !== "string" || typeof req.assetId !== "string" || !req.ownerId || !req.assetId) {
    return { ok: false, message: "ยังไม่ได้เลือกผู้ถือและทรัพย์" };
  }
  const refState = await loadReference();
  if (!refState.ok) return { ok: false, message: `โหลดข้อมูลผู้ถือและทรัพย์ไม่ได้ (${refState.error})` };
  let supabase;
  try {
    supabase = await createClient();
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : String(e) };
  }
  return readDisposalContext(supabase, refState.ref, req);
}
