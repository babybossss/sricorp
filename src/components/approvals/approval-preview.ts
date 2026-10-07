import type { Approval } from "@/lib/mock/ledger";
import type { LedgerResolver, PostingInput } from "@/lib/ledger/types";
import { previewPosting, type PreviewResult } from "@/lib/ledger/preview";

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
  };
}

export type ApprovalPreview = {
  input: PostingInput;
  preview: PreviewResult;
  /** อนุมัติได้เมื่อ engine พรีวิวได้เท่านั้น — อนุมัติสิ่งที่ยังไม่รู้ว่าจะลงบัญชีอย่างไร คืออนุมัติแบบไม่เห็นของ */
  canApprove: boolean;
  /** เหตุที่ engine ปฏิเสธ (ถ้าพรีวิวไม่ได้) */
  blockedReason: string | null;
};

/** ผลพรีวิวของรายการรออนุมัติ — ที่เดียวที่แผงตรวจ ตารางคิว และปุ่มอนุมัติหมู่ใช้ร่วมกัน */
export function previewApproval(item: Approval, resolve: LedgerResolver): ApprovalPreview {
  const input = approvalInput(item);
  const preview = previewPosting(input, resolve);
  return {
    input,
    preview,
    canApprove: preview.ok,
    blockedReason: preview.ok ? null : preview.reason,
  };
}
