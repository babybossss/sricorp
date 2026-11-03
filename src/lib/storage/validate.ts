import { MAX_ATTACHMENT_BYTES, type AllowedExt, type AllowedMime } from "./config";
import { fail, MESSAGES, type StorageFailure } from "./errors";
import { sniffType } from "./sniff";

/**
 * ตรวจไฟล์ที่ **ฝั่ง server** จากไบต์จริงที่รับมา
 *
 * ไม่เชื่อ: ขนาดที่ client แจ้ง · Content-Type · ชื่อไฟล์/นามสกุล — ทั้งหมดนี้ปลอมได้
 * เชื่อ: ความยาวของ bytes ที่อ่านได้จริง + ไบต์ต้นไฟล์
 */

export type ValidFile = { ok: true; mime: AllowedMime; ext: AllowedExt; size: number };

export function validateUpload(bytes: Uint8Array | null | undefined): ValidFile | StorageFailure {
  if (!bytes || bytes.byteLength === 0) {
    return fail("empty_file", MESSAGES.empty_file);
  }
  if (bytes.byteLength > MAX_ATTACHMENT_BYTES) {
    return fail("too_large", MESSAGES.too_large(MAX_ATTACHMENT_BYTES), {
      detail: `${bytes.byteLength} > ${MAX_ATTACHMENT_BYTES}`,
    });
  }
  const t = sniffType(bytes);
  if (!t) return fail("unsupported_type", MESSAGES.unsupported_type);
  return { ok: true, mime: t.mime, ext: t.ext, size: bytes.byteLength };
}
