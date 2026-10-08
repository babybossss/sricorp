import { MAX_ATTACHMENT_BYTES, STORAGE_TIMEOUT_MS } from "./config";
import { fail, MESSAGES, type Result, type StorageErrorCode, type StorageFailure } from "./errors";
import { storageReadiness } from "./readiness";

/**
 * ฝั่ง browser — เรียก /api/attachments (ตรวจจริงที่ server) · ไม่แตะ Storage ตรง
 *
 * ทุกฟังก์ชัน: env ไม่ครบ → คืน not_configured ทันที (ไม่ยิงอะไรเลย ไม่มีไฟล์จำลองแทน)
 * ทุกคำขอมี timeout · ล้มเหลว = คืน StorageFailure ข้อความไทย ไม่ throw ใส่หน้าจอ
 */

const API = "/api/attachments";

async function call<T extends Record<string, unknown>>(
  url: string,
  init: RequestInit,
  timeoutMs = STORAGE_TIMEOUT_MS * 2
): Promise<Result<T>> {
  const ready = storageReadiness();
  if (!ready.ok) return ready;

  let res: Response;
  try {
    res = await fetch(url, { ...init, signal: AbortSignal.timeout(timeoutMs), credentials: "same-origin" });
  } catch (e) {
    const timedOut = e instanceof DOMException && (e.name === "TimeoutError" || e.name === "AbortError");
    return timedOut ? fail("timeout", MESSAGES.timeout) : fail("network", MESSAGES.network);
  }

  let json: unknown = null;
  try {
    json = await res.json();
  } catch {
    // ไม่ใช่ JSON — เช่น Vercel ตัดคำขอใหญ่ด้วยหน้า HTML 413 ก่อนถึงโค้ดเรา
    if (res.status === 413) return fail("too_large", MESSAGES.too_large(MAX_ATTACHMENT_BYTES));
    return fail("server", MESSAGES.server, { detail: `HTTP ${res.status}` });
  }
  const body = json as { ok?: boolean; code?: StorageErrorCode; message?: string; problems?: string[] } & T;
  if (res.ok && body.ok) return body as Result<T>;
  return {
    ok: false,
    code: body.code ?? "server",
    message: body.message ?? MESSAGES.server,
    problems: body.problems,
  };
}

export const uploadAttachmentFromBrowser = async (file: Blob, ownerId: string) => {
  const form = new FormData();
  form.set("ownerId", ownerId);
  form.set("file", file);
  return call<{ ref: string; mime: string; size: number }>(API, { method: "POST", body: form });
};

export const getAttachmentUrl = (ref: string) =>
  call<{ url: string; expiresIn: number }>(`${API}?ref=${encodeURIComponent(ref)}`, { method: "GET" });

export const deleteAttachments = (refs: string[]) =>
  call<{ removed: string[]; kept: string[] }>(API, {
    method: "DELETE",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ refs }),
  });

export const verifyAttachments = (refs: string[]) =>
  call<{ count: number }>(`${API}/verify`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ refs }),
  });

export const sweepMyOrphans = () => call<{ found: number; removed: number }>(`${API}/sweep`, { method: "POST" });

// ---------------------------------------------------------------- ย่อรูปจากมือถือ

/** ขนาดใหม่ที่ด้านยาวสุดไม่เกิน maxEdge (ไม่ขยาย) */
export function fitWithin(w: number, h: number, maxEdge: number): { w: number; h: number } {
  const longest = Math.max(w, h);
  if (!(longest > maxEdge) || !(w > 0) || !(h > 0)) return { w, h };
  const k = maxEdge / longest;
  return { w: Math.max(1, Math.round(w * k)), h: Math.max(1, Math.round(h * k)) };
}

/**
 * รูปถ่ายสลิปจากมือถือมักเกิน 4 MB → ย่อเป็น JPEG ก่อนส่ง (เพื่อให้ส่งได้ ไม่ใช่เพื่อความปลอดภัย —
 * server ตรวจซ้ำเสมอ) · ไฟล์เล็กพออยู่แล้ว / PDF / ไม่ใช่รูป → คืนตัวเดิม
 * ย่อไม่ได้ (เช่น HEIC บน Chrome ที่ถอดรหัสไม่ได้) และไฟล์ยังใหญ่เกิน → too_large บอกวิธีแก้
 */
export async function prepareImageForUpload(file: File): Promise<{ ok: true; file: Blob } | StorageFailure> {
  if (file.size === 0) return fail("empty_file", MESSAGES.empty_file);
  if (file.size <= MAX_ATTACHMENT_BYTES) return { ok: true, file };
  if (!file.type.startsWith("image/")) return fail("too_large", MESSAGES.too_large(MAX_ATTACHMENT_BYTES));

  try {
    const bmp = await createImageBitmap(file);
    for (const edge of [2400, 1800, 1400, 1000]) {
      const { w, h } = fitWithin(bmp.width, bmp.height, edge);
      const canvas = document.createElement("canvas");
      canvas.width = w;
      canvas.height = h;
      canvas.getContext("2d")?.drawImage(bmp, 0, 0, w, h);
      const blob = await new Promise<Blob | null>((r) => canvas.toBlob(r, "image/jpeg", 0.85));
      if (blob && blob.size > 0 && blob.size <= MAX_ATTACHMENT_BYTES) return { ok: true, file: blob };
    }
  } catch {
    // ถอดรหัสไม่ได้ — ตกไปบอกผู้ใช้ด้านล่าง
  }
  return fail("too_large", MESSAGES.too_large(MAX_ATTACHMENT_BYTES));
}
