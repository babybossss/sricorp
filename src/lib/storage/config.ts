/**
 * ค่าตั้งของไฟล์แนบ — ที่เดียว
 *
 * ค่าสามตัวแรกซ้ำกับ bucket ใน supabase/migrations/20261008000009_storage_policies.sql
 * (ขนาด · ชนิดไฟล์ · นามสกุลที่ policy รับ) → `__tests__/path.test.ts` อ่านไฟล์ migration มาเทียบ
 * ถ้าแก้ฝั่งเดียว เทสต์แดง · ห้ามแก้ที่เดียวแล้วคิดว่าพอ
 *
 * ตัวตั้งค่าที่เปลี่ยนตามธุรกิจ (ช่วงผ่อนผันไฟล์ลอย) อยู่ในตาราง settings ไม่ใช่ที่นี่ (กฎเหล็กข้อ 5)
 */

export const ATTACHMENT_BUCKET = "attachments" as const;

/**
 * 4 MB — เพดานของ route handler บน Vercel รับ body ได้ราว 4.5 MB
 * รูปถ่ายสลิปจากมือถือมักใหญ่กว่านี้ → ฝั่ง browser ย่อก่อน (`prepareImageForUpload`)
 * แต่ **ฝั่ง server ตรวจซ้ำเสมอ** (browser ปลอมได้)
 */
export const MAX_ATTACHMENT_BYTES = 4 * 1024 * 1024;

/** ชนิดที่รับ (ตัดสินจากไบต์จริง ไม่ใช่จาก Content-Type/นามสกุลที่ผู้ใช้ส่งมา) → นามสกุลที่เก็บ */
export const ALLOWED_TYPES = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
  "image/heic": "heic",
  "application/pdf": "pdf",
} as const;
export type AllowedMime = keyof typeof ALLOWED_TYPES;
export type AllowedExt = (typeof ALLOWED_TYPES)[AllowedMime];

/** ลิงก์ดาวน์โหลดมีอายุจำกัด — ส่งต่อแล้วหมดอายุเอง */
export const SIGNED_URL_TTL_SECONDS = 300;
export const SIGNED_URL_MIN_SECONDS = 30;
export const SIGNED_URL_MAX_SECONDS = 900;

/** เวลารอสูงสุดต่อการเรียก Storage (กันหน้าเว็บค้างเมื่อแหล่งข้อมูลล่ม) */
export const STORAGE_TIMEOUT_MS = 25_000;

/** ส่วนเกินของ multipart (boundary · ชื่อฟิลด์) ที่อนุญาตเหนือขนาดไฟล์ */
export const MULTIPART_OVERHEAD_BYTES = 64 * 1024;

/** ลบทีละกี่ไฟล์ตอนกวาดไฟล์ลอย */
export const REMOVE_CHUNK = 50;
