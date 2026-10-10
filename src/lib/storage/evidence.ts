import { isUuid, parseAttachmentRef } from "./path";

/**
 * "หลักฐานจริง" ของ corporate_strict (D-095) — ฝั่งเครื่องยนต์
 *
 * กติกาเต็มมีสามข้อ (ดู supabase/migrations/20261010000000_evidence_real_files.sql):
 *   1. รูปแบบ path ถูกตามนิยามใน `path.ts` — **ใช้ตัวนั้น ไม่มี regex ชุดที่สอง**
 *   2. ส่วน `<owner_id>` ของ path = ผู้ถือของรายการ (ยืมไฟล์ของผู้ถืออื่นมาอ้างไม่ได้)
 *   3. มีไฟล์จริงใน `storage.objects` ของ bucket `attachments`
 *
 * ไฟล์นี้ตรวจได้ **ข้อ 1 และข้อ 2** เท่านั้น · ข้อ 3 ตรวจได้ที่ DB ที่เดียว
 * (ฝั่งแอปมี `verifyAttachments()` ช่วยถามก่อนบันทึกได้ แต่คำตอบเก่าได้ทุกเสี้ยววินาที)
 * ดังนั้นที่นี่ **ไม่ใช่ตัวอนุญาต** — เป็นด่านที่ทำให้ผู้ใช้เห็นข้อความที่อ่านรู้เรื่อง
 * ก่อนกดบันทึก ตัวบังคับจริงคือ trigger `trg_corporate_evidence_real_files` ใน DB
 * ซึ่งปฏิเสธเสมอถ้าไฟล์ไม่มีอยู่จริง (และปฏิเสธถ้าตรวจไม่ได้)
 *
 * นับซ้ำไม่ได้: path เดียวกันสองช่อง = 1 ไฟล์ (เหมือน `distinct` ฝั่ง DB)
 */

export type EvidenceScope = {
  /**
   * ผู้ถือของรายการ — เทียบกับ `<owner_id>` ใน path
   *
   * เทียบได้เฉพาะเมื่อเป็น uuid (รหัสผู้ถือจริงใน `sri_os.owners`) · ข้อมูลจำลองของหน้าจอ
   * ยังใช้รหัสสั้นอย่าง `"corp"` ซึ่งไม่มีทางอยู่ใน path ได้เลย ถ้าเทียบตรงๆ ทุกไฟล์จะตก
   * ทั้งหมดและผู้ใช้จะเห็นข้อความที่ชี้ผิดจุด → กรณีนั้นข้ามข้อ 2 **ที่ด่านข้อความนี้เท่านั้น**
   * ส่วน DB เทียบเสมอเพราะ `transactions.owner_id` เป็น uuid จริงทุกแถว
   */
  ownerId?: string;
};

export function realEvidenceRefs(
  attachments: readonly unknown[] | null | undefined,
  scope: EvidenceScope = {}
): string[] {
  const owner = typeof scope.ownerId === "string" ? scope.ownerId.toLowerCase() : undefined;
  const checkOwner = isUuid(owner);
  const out = new Set<string>();
  for (const item of attachments ?? []) {
    const ref = parseAttachmentRef(item);
    if (!ref) continue;
    if (checkOwner && ref.ownerId !== owner) continue;
    out.add(item as string);
  }
  return [...out];
}

export const realEvidenceCount = (
  attachments: readonly unknown[] | null | undefined,
  scope: EvidenceScope = {}
): number => realEvidenceRefs(attachments, scope).length;

export const hasRealEvidence = (
  attachments: readonly unknown[] | null | undefined,
  scope: EvidenceScope = {}
): boolean => realEvidenceCount(attachments, scope) > 0;
