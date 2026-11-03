/**
 * ผลลัพธ์ของชั้นไฟล์แนบ — ทุกฟังก์ชันคืน union นี้ ไม่ throw ให้หน้าจอ
 * ข้อความเป็นภาษาไทยพร้อมแสดงตรงๆ (ผู้ใช้มีผู้สูงอายุ — บอกว่าต้องทำอะไรต่อ ไม่ใช่โค้ด error)
 */

export type StorageErrorCode =
  | "not_configured" // ไม่มี env — ห้ามตกไปใช้ไฟล์จำลอง
  | "not_signed_in"
  | "bad_request"
  | "empty_file"
  | "too_large"
  | "unsupported_type"
  | "forbidden"
  | "not_found"
  | "bucket_missing"
  | "timeout"
  | "network"
  | "server";

export type StorageFailure = {
  ok: false;
  code: StorageErrorCode;
  message: string;
  /** รายละเอียดสำหรับ log (ไม่แสดงผู้ใช้) */
  detail?: string;
  /** กรณี not_configured: ชื่อตัวแปรที่ต้องตั้ง */
  problems?: string[];
};

export type Result<T> = ({ ok: true } & T) | StorageFailure;

const MB = (n: number) => `${Math.round((n / (1024 * 1024)) * 10) / 10} MB`;

export const MESSAGES = {
  not_signed_in: "ยังไม่ได้เข้าสู่ระบบ — เข้าสู่ระบบอีกครั้งแล้วลองใหม่",
  empty_file: "ไฟล์ว่างเปล่า (0 ไบต์) — เลือกไฟล์ใหม่",
  too_large: (max: number) => `ไฟล์ใหญ่เกิน ${MB(max)} — ถ่ายรูปใหม่ด้วยขนาดเล็กลง หรือแคปหน้าจอแทน`,
  unsupported_type: "รับเฉพาะรูปถ่าย (JPG · PNG · WebP · HEIC) และ PDF เท่านั้น",
  forbidden: "ไม่มีสิทธิ์กับไฟล์นี้ หรือผู้ถือรายการนี้ไม่อยู่ในสิทธิ์ของคุณ",
  not_found: "ไม่พบไฟล์ หรือคุณไม่มีสิทธิ์เปิดไฟล์นี้",
  bucket_missing:
    "ยังไม่ได้สร้างที่เก็บไฟล์ใน Supabase (bucket attachments) — ต้อง apply migration 20261008000009_storage_policies.sql ก่อน",
  timeout: "ที่เก็บไฟล์ตอบช้าเกินไป — ลองอีกครั้ง (ไฟล์ของคุณยังไม่ได้ถูกบันทึก)",
  network: "เชื่อมต่อไม่ได้ — ตรวจอินเทอร์เน็ตแล้วลองอีกครั้ง",
  server: "ที่เก็บไฟล์ขัดข้อง — ลองอีกครั้ง ถ้ายังไม่ได้ให้แจ้งผู้ดูแลระบบ",
} as const;

export function fail(
  code: StorageErrorCode,
  message: string,
  extra: Partial<Pick<StorageFailure, "detail" | "problems">> = {}
): StorageFailure {
  return { ok: false, code, message, ...extra };
}

export function notConfigured(problems: string[]): StorageFailure {
  return fail(
    "not_configured",
    `ยังอัปโหลดไฟล์แนบไม่ได้ เพราะตั้งค่า Supabase ไม่ครบ: ${problems.join(", ")} — ตั้งใน .env.local (และ Vercel → Settings → Environment Variables) แล้วเริ่มใหม่ · ระบบไม่ใช้ไฟล์จำลองแทน เพราะด่านหลักฐานของนิติบุคคลจะตรวจของปลอมโดยไม่มีใครรู้`,
    { problems }
  );
}

export const HTTP_STATUS: Record<StorageErrorCode, number> = {
  not_configured: 503,
  not_signed_in: 401,
  bad_request: 400,
  empty_file: 400,
  too_large: 413,
  unsupported_type: 415,
  forbidden: 403,
  not_found: 404,
  bucket_missing: 503,
  timeout: 504,
  network: 502,
  server: 502,
};
