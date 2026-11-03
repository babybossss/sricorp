import { jsonFailure, jsonOk, readUploadForm } from "@/lib/storage/http";
import { requireUserClient } from "@/lib/storage/session";
import { createAttachmentUrl, removeAttachments, uploadAttachment } from "@/lib/storage/server";
import { fail } from "@/lib/storage/errors";

/**
 * ไฟล์แนบ (หลักฐานรายการ)
 *   POST   multipart  file + ownerId     → อัปโหลด คืน { ref } ไปใส่ใน attachments
 *   GET    ?ref=<path>                    → ลิงก์ดาวน์โหลดอายุสั้น
 *   DELETE { refs: [...] }                → ลบไฟล์ที่ยังไม่มีรายการอ้าง (ที่เหลือคืนใน kept)
 *
 * ตรวจชนิด/ขนาดจาก **ไบต์จริงฝั่งนี้** ไม่เชื่อสิ่งที่ browser บอก · ใช้ session ของผู้ใช้ + publishable key
 * (ไม่มี service-role) → สิทธิ์ทั้งหมดตัดสินโดย RLS ของ storage.objects ใน DB
 * ไม่มี fallback เป็นไฟล์จำลอง: env ไม่ครบ = 503 พร้อมชื่อตัวแปรที่ต้องตั้ง
 */
export const dynamic = "force-dynamic";

export async function POST(req: Request) {
  const s = await requireUserClient(req);
  if (!s.ok) return jsonFailure(s);

  const form = await readUploadForm(req);
  if (!form.ok) return jsonFailure(form);

  const r = await uploadAttachment(s.client, { userId: s.userId, ownerId: form.fields.ownerId, bytes: form.bytes });
  if (!r.ok) return jsonFailure(r);
  return jsonOk({ ref: r.ref, mime: r.mime, size: r.size }, 201);
}

export async function GET(req: Request) {
  const s = await requireUserClient(req);
  if (!s.ok) return jsonFailure(s);

  const ref = new URL(req.url).searchParams.get("ref");
  const r = await createAttachmentUrl(s.client, ref);
  if (!r.ok) return jsonFailure(r);
  return jsonOk({ url: r.url, expiresIn: r.expiresIn });
}

export async function DELETE(req: Request) {
  const s = await requireUserClient(req);
  if (!s.ok) return jsonFailure(s);

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return jsonFailure(fail("bad_request", "ต้องส่ง JSON { refs: [...] }"));
  }
  const refs = (body as { refs?: unknown } | null)?.refs;
  const r = await removeAttachments(s.client, refs);
  if (!r.ok) return jsonFailure(r);
  return jsonOk({ removed: r.removed, kept: r.kept });
}
