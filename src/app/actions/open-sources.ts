"use server";

import { createClient } from "@/lib/supabase/server";
import { getAccess } from "@/lib/auth/session";
import { loadReference } from "@/lib/db/reference";
import { openSourcesFor } from "@/lib/db/clearing-link";
import { readPendingAccruals } from "@/lib/db/pending-accruals-server";

/**
 * รายการของค้างที่ยังเปิดอยู่ของผู้ถือในบัญชีพักหนึ่ง — ให้ฟอร์ม "เลือกว่าชำระใบไหน"
 * ยอดคงเหลืออ่านจาก DB ทุกครั้ง (ไม่คำนวณในหน้าจอ) · ใช้ session ของผู้ใช้ (RLS)
 */
export type OpenSource = {
  id: string;
  label: string;
  docDate: string;
  subCode: string;
  assetId: string | null;
  accrued: number;
  outstanding: number;
  clearedCount: number;
};
export type OpenSourcesOutcome = { ok: true; items: OpenSource[] } | { ok: false; message: string };

export async function listOpenSources(req: { ownerId: string; account: string }): Promise<OpenSourcesOutcome> {
  const access = await getAccess();
  if (!access.user) return { ok: false, message: "เข้าสู่ระบบหมดอายุ — ให้เข้าสู่ระบบใหม่" };
  if (typeof req?.ownerId !== "string" || typeof req?.account !== "string") {
    return { ok: false, message: "ไม่ได้ระบุผู้ถือหรือบัญชีพัก" };
  }
  const ref = await loadReference();
  if (!ref.ok) return { ok: false, message: `โหลดข้อมูลอ้างอิงไม่ได้ (${ref.error})` };
  let supabase;
  try {
    supabase = await createClient();
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : String(e) };
  }
  const read = await readPendingAccruals(supabase, ref.ref.coaCodeById);
  if (!read.ok) return { ok: false, message: read.error };
  return {
    ok: true,
    items: openSourcesFor(read.items, req.ownerId, req.account).map((p) => ({
      id: p.id,
      label: p.memo ?? p.subCode,
      docDate: p.docDate,
      subCode: p.subCode,
      assetId: p.assetId,
      accrued: p.accruedAmount,
      outstanding: p.outstanding,
      clearedCount: p.postedClearings.length,
    })),
  };
}
