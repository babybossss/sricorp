import { jsonFailure, jsonOk } from "@/lib/storage/http";
import { requireUserClient } from "@/lib/storage/session";
import { sweepOwnOrphans } from "@/lib/storage/server";

/**
 * กวาดไฟล์ลอยของผู้ใช้เอง (อัปโหลดแล้วบันทึกรายการไม่สำเร็จ เก่ากว่าช่วงผ่อนผันใน settings)
 * หน้าจอเรียกตอนเปิดฟอร์มแนบไฟล์ · ลบได้เฉพาะไฟล์ที่ไม่มีรายการ/ร่าง/สัญญาอ้าง (DB บังคับ)
 */
export const dynamic = "force-dynamic";

export async function POST(req: Request) {
  const s = await requireUserClient(req);
  if (!s.ok) return jsonFailure(s);
  const r = await sweepOwnOrphans(s.client);
  if (!r.ok) return jsonFailure(r);
  return jsonOk({ found: r.found, removed: r.removed });
}
