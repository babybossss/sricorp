import type { Approval } from "@/lib/mock/ledger";
import type { LedgerResolver, PostingInput } from "@/lib/ledger/types";
import { previewPosting, type PreviewResult } from "@/lib/ledger/preview";
import { buildPosting } from "@/lib/ledger/posting";
import { PostingError } from "@/lib/ledger/types";

/**
 * ประกอบ input ของ engine จากรายการรออนุมัติ
 *
 * บัญชีอ่านจาก `item.bankAccountId` ที่คนคีย์เลือกเท่านั้น — ไม่หยิบ "บัญชีแรกของผู้ถือ" มาแทน
 * ถ้าไม่มี ส่งค่าว่างเข้าไปตรงๆ แล้วให้ engine เป็นคนตัดสินว่าพอไหม
 * (แผงนี้ห้ามเช็ค "รายการช่องที่ขาด" เอง — กติกาของ engine เปลี่ยนเมื่อไร แผงจะไม่ล้าหลัง)
 *
 * ค่าว่างเป็น "" ไม่ใช่ undefined เพื่อให้ตรงกับชนิด `PostingInput.bankAccountId: string`
 * ที่ engine ใช้อยู่ — engine ตรวจด้วย falsy จึงถือว่า "" คือไม่ได้ระบุเหมือนกัน
 */
export function approvalInput(item: Approval): PostingInput {
  return {
    typeKey: item.typeKey,
    subCode: item.subCode,
    amount: Math.abs(item.amount),
    ownerId: item.ownerId,
    bankAccountId: item.bankAccountId ?? "",
    assetId: item.assetId,
    contactId: item.contactId,
    // รออนุมัติ = ยังไม่มีใครยืนยันว่าเงินเคลื่อน · ธงมากับรายการ ไม่ใช่ให้แผงเดา
    notYetPaid: !!item.notYetPaid,
    // หลักฐานมากับตัวรายการ — ฝั่งนิติบุคคล engine ใช้ตัดสินว่าบันทึกได้ไหม ห้ามละไว้
    attachments: item.attachments,
  };
}

export type ApprovalPreview = {
  input: PostingInput;
  /**
   * บรรทัดบัญชีสำหรับ "ให้คนอ่าน" — มาจาก `buildPostingDraft()` ผ่าน `previewPosting()`
   * ไฟล์แนบไม่เปลี่ยนคู่บัญชี จึงโชว์บรรทัดได้แม้ยังไม่มีหลักฐาน
   * **ห้ามใช้ field นี้ตัดสินว่าอนุมัติได้ไหม** (ใช้ `canApprove`)
   */
  preview: PreviewResult;
  /**
   * อนุมัติได้ไหม — ตัดสินโดย `buildPosting()` ตัวจริง ซึ่งบังคับกติกาเอกสารของนิติบุคคลด้วย
   * การอนุมัติคือการบันทึกจริง จึงต้องผ่านด่านเดียวกับที่ post ลงฐานข้อมูล ไม่ใช่ draft
   */
  canApprove: boolean;
  /** เหตุที่ engine ปฏิเสธ (ข้อความจาก `PostingError` ตรงๆ ไม่แต่งเอง) */
  blockedReason: string | null;
};

/** ถาม engine ตัวจริง — คืนเหตุผลของ `PostingError` หรือ null ถ้าผ่าน */
function engineVerdict(input: PostingInput, resolve: LedgerResolver): string | null {
  try {
    buildPosting(input, resolve);
    return null;
  } catch (e) {
    if (e instanceof PostingError) return e.message;
    // ข้อผิดพลาดที่ไม่ได้คาดไว้ ปล่อยขึ้นไปให้เห็น ไม่กลืน
    throw e;
  }
}

/** ผลพรีวิวของรายการรออนุมัติ — ที่เดียวที่แผงตรวจ ตารางคิว และปุ่มอนุมัติหมู่ใช้ร่วมกัน */
export function previewApproval(item: Approval, resolve: LedgerResolver): ApprovalPreview {
  const input = approvalInput(item);
  const preview = previewPosting(input, resolve);
  const blockedReason = engineVerdict(input, resolve);
  return { input, preview, canApprove: blockedReason === null, blockedReason };
}

export type BulkApprovalPlan = {
  approvable: Approval[];
  skipped: { item: Approval; reason: string }[];
};

/**
 * แบ่งรายการเป็น "อนุมัติได้" กับ "ข้าม" รายตัวด้วย engine ตัวจริง
 *
 * รายการเดียวที่ติดต้องไม่ดับทั้งคิว (บทเรียน 7: กันแน่นเกินจนใช้งานไม่ได้)
 * แต่ก็ห้ามปล่อยรายการที่ติดให้ผ่านด้วย — ข้ามพร้อมเหตุผลของ engine เสมอ
 */
export function planBulkApproval(items: Approval[], resolve: LedgerResolver): BulkApprovalPlan {
  const plan: BulkApprovalPlan = { approvable: [], skipped: [] };
  for (const item of items) {
    const { canApprove, blockedReason } = previewApproval(item, resolve);
    if (canApprove) plan.approvable.push(item);
    else plan.skipped.push({ item, reason: blockedReason ?? "" });
  }
  return plan;
}
