import { MAX_ATTACHMENT_BYTES, MULTIPART_OVERHEAD_BYTES } from "./config";
import { fail, HTTP_STATUS, MESSAGES, type StorageFailure } from "./errors";

/**
 * ตัวช่วยของ route handler (ไม่แตะ Next/Supabase เพื่อเทสต์ได้ตรงๆ)
 */

/** อ่าน body แบบมีเพดาน — เกินแล้วหยุดอ่านทันที ไม่โหลดทั้งก้อนเข้าหน่วยความจำก่อนค่อยปฏิเสธ */
export async function readCappedBody(
  req: Request,
  maxBytes: number
): Promise<{ ok: true; bytes: Uint8Array } | StorageFailure> {
  const declared = Number(req.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maxBytes) {
    return fail("too_large", MESSAGES.too_large(MAX_ATTACHMENT_BYTES), { detail: `content-length ${declared}` });
  }
  if (!req.body) return fail("empty_file", MESSAGES.empty_file);

  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel().catch(() => undefined);
      return fail("too_large", MESSAGES.too_large(MAX_ATTACHMENT_BYTES), { detail: "stream เกินเพดาน" });
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) {
    bytes.set(c, at);
    at += c.byteLength;
  }
  return { ok: true, bytes };
}

/**
 * อ่านฟอร์ม multipart โดยคุมขนาดตั้งแต่ต้นทาง
 * คืนไฟล์ + ฟิลด์ข้อความ · "ไม่ส่งไฟล์" กับ "ไฟล์ว่าง" คืน empty_file ทั้งคู่
 */
export async function readUploadForm(
  req: Request
): Promise<{ ok: true; bytes: Uint8Array; fields: Record<string, string> } | StorageFailure> {
  const ct = req.headers.get("content-type") ?? "";
  if (!/^multipart\/form-data\b/i.test(ct)) {
    return fail("bad_request", "ต้องส่งแบบ multipart/form-data (ฟิลด์ file และ ownerId)");
  }
  const body = await readCappedBody(req, MAX_ATTACHMENT_BYTES + MULTIPART_OVERHEAD_BYTES);
  if (!body.ok) return body;

  let form: FormData;
  try {
    form = await new Response(new Blob([body.bytes as BlobPart]), { headers: { "content-type": ct } }).formData();
  } catch {
    return fail("bad_request", "อ่านข้อมูลที่ส่งมาไม่ได้");
  }
  const file = form.get("file");
  if (!file || typeof file === "string") return fail("empty_file", MESSAGES.empty_file);
  const bytes = new Uint8Array(await file.arrayBuffer());

  const fields: Record<string, string> = {};
  for (const [k, v] of form.entries()) if (typeof v === "string") fields[k] = v;
  return { ok: true, bytes, fields };
}

/**
 * กัน CSRF แบบเบา: คำขอที่เปลี่ยนสถานะต้องมาจากหน้าของเราเอง
 * (cookie ของ Supabase เป็น SameSite=Lax อยู่แล้ว นี่คือชั้นที่สอง) — ไม่มี Origin = ไม่ใช่ browser → ปล่อย
 * เพราะไม่มีทางส่ง cookie ของผู้ใช้มาโดยไม่ผ่าน browser
 */
export function isSameOrigin(req: Request): boolean {
  const origin = req.headers.get("origin");
  if (!origin) return true;
  const host = req.headers.get("x-forwarded-host") ?? req.headers.get("host");
  try {
    return !!host && new URL(origin).host === host;
  } catch {
    return false;
  }
}

export function jsonFailure(f: StorageFailure): Response {
  return Response.json(
    { ok: false, code: f.code, message: f.message, problems: f.problems },
    { status: HTTP_STATUS[f.code], headers: { "Cache-Control": "no-store" } }
  );
}

export function jsonOk(body: Record<string, unknown>, status = 200): Response {
  return Response.json({ ok: true, ...body }, { status, headers: { "Cache-Control": "no-store" } });
}
