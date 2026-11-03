import { fail } from "@/lib/storage/errors";
import { jsonFailure, jsonOk } from "@/lib/storage/http";
import { requireUserClient } from "@/lib/storage/session";
import { verifyAttachmentsExist } from "@/lib/storage/server";

/**
 * ก่อนบันทึกรายการ: ทุก ref ต้องเป็นไฟล์จริงใน Storage ที่ผู้ใช้เปิดได้
 * ชื่อไฟล์จำลอง ("สลิป.jpg") หรือ ref ที่ไฟล์หายไปแล้ว → ไม่ผ่าน (ไม่มี fallback)
 */
export const dynamic = "force-dynamic";

export async function POST(req: Request) {
  const s = await requireUserClient(req);
  if (!s.ok) return jsonFailure(s);

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return jsonFailure(fail("bad_request", "ต้องส่ง JSON { refs: [...] }"));
  }
  const r = await verifyAttachmentsExist(s.client, (body as { refs?: unknown } | null)?.refs);
  if (!r.ok) return jsonFailure(r);
  return jsonOk({ count: r.count });
}
