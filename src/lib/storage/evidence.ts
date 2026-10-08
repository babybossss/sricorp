import { isAttachmentRef } from "./path";

/**
 * "หลักฐานจริง" = ref ที่เป็น path ของไฟล์ใน Storage (รูปแบบถูกต้อง)
 *
 * ด่านของ corporate_strict (`lib/ledger/guards.ts`) ตอนนี้นับแค่ว่ามีสมาชิกใน attachments
 * ซึ่งชื่อไฟล์จำลอง ("สลิป.jpg") ก็ผ่าน — พอหน้าจอเลิกใช้ mock ให้ด่านเรียก `realEvidenceCount()`
 * แทน `attachments.length` (ไฟล์นี้ไม่แก้ lib/ledger ตามขอบเขตงาน)
 * หมายเหตุ: นี่ตรวจ "รูปแบบ" เท่านั้น · ว่าไฟล์ยังอยู่จริงไหมใช้ verifyAttachments() ก่อนบันทึก
 */
export const realEvidenceCount = (attachments: readonly unknown[] | null | undefined): number =>
  (attachments ?? []).filter(isAttachmentRef).length;

export const hasRealEvidence = (attachments: readonly unknown[] | null | undefined): boolean =>
  realEvidenceCount(attachments) > 0;
