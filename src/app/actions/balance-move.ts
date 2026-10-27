"use server";

import { getAccess } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";
import { loadReference } from "@/lib/db/reference";
import { readBalanceMove, type BalanceMoveState } from "@/lib/db/balance-move-server";
import { movesWholeBalance } from "@/lib/db/balance-move";
import { findSub } from "@/lib/rules/tx-rules";

/**
 * ยอดที่ระบบจะย้ายทั้งก้อน (หมวดย้ายวัตถุประสงค์ทรัพย์) — อ่านจากสมุดสดตาม session ของผู้ใช้ (RLS) สำหรับแสดงในฟอร์ม
 * **ตอนบันทึกจริง `postEntry` อ่านซ้ำเองทุกครั้ง** ไม่เชื่อค่าที่ฟอร์มถือไว้
 */
export async function loadBalanceMove(req: { ownerId: string; assetId: string; subCode: string }): Promise<BalanceMoveState> {
  const access = await getAccess();
  if (!access.user) return { ok: false, message: "เข้าสู่ระบบหมดอายุ — ให้เข้าสู่ระบบใหม่" };
  if (!req || ![req.ownerId, req.assetId, req.subCode].every((s) => typeof s === "string" && s)) {
    return { ok: false, message: "ยังไม่ได้เลือกผู้ถือและทรัพย์" };
  }
  const sub = findSub(req.subCode)?.sub;
  if (!sub || !movesWholeBalance(sub)) return { ok: false, message: "หมวดนี้ไม่ใช่การย้ายยอดทั้งก้อน" };
  const refState = await loadReference();
  if (!refState.ok) return { ok: false, message: `โหลดข้อมูลผู้ถือและทรัพย์ไม่ได้ (${refState.error})` };
  let supabase;
  try {
    supabase = await createClient();
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : String(e) };
  }
  return readBalanceMove(supabase, refState.ref, sub, req);
}
