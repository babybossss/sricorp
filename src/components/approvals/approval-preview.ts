import type { ApprovalItem } from "@/lib/db/approvals-model";
import { approvalInput } from "@/lib/db/approvals-model";
import type { LedgerResolver, PostingInput } from "@/lib/ledger/types";
import { previewPosting, type PreviewResult } from "@/lib/ledger/preview";
import { buildPosting } from "@/lib/ledger/posting";
import { PostingError } from "@/lib/ledger/types";

/**
 * พรีวิวและด่านของรายการรออนุมัติ — ที่เดียวที่แผงตรวจ รายการในคิว และปุ่มอนุมัติหมู่ใช้ร่วมกัน
 * การแปลงร่าง → input ของ engine อยู่ที่ `approvalInput()` (ไม่เดาบัญชี ไม่เดาประเภท)
 */
export { approvalInput };

export type ApprovalPreview = {
  /** null = ไม่รู้จักหมวดย่อยของร่างนี้ */
  input: PostingInput | null;
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

const UNKNOWN_SUB = (code: string) => `ไม่รู้จักหมวดย่อย "${code}" ในตารางกฎ — ระบบไม่เดาประเภทรายการให้ จึงอนุมัติไม่ได้`;

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

export function previewApproval(item: ApprovalItem, resolve: LedgerResolver): ApprovalPreview {
  const input = approvalInput(item);
  if (!input) {
    const reason = UNKNOWN_SUB(item.subCode);
    return { input: null, preview: { ok: false, reason }, canApprove: false, blockedReason: reason };
  }
  const preview = previewPosting(input, resolve);
  const blockedReason = engineVerdict(input, resolve);
  return { input, preview, canApprove: blockedReason === null, blockedReason };
}

export type BulkApprovalPlan = {
  approvable: ApprovalItem[];
  skipped: { item: ApprovalItem; reason: string }[];
};

/**
 * แบ่งรายการเป็น "อนุมัติได้" กับ "ข้าม" รายตัวด้วย engine ตัวจริง
 *
 * รายการเดียวที่ติดต้องไม่ดับทั้งคิว แต่ก็ห้ามปล่อยรายการที่ติดให้ผ่านด้วย — ข้ามพร้อมเหตุผลของ engine เสมอ
 */
export function planBulkApproval(items: ApprovalItem[], resolve: LedgerResolver): BulkApprovalPlan {
  const plan: BulkApprovalPlan = { approvable: [], skipped: [] };
  for (const item of items) {
    const { canApprove, blockedReason } = previewApproval(item, resolve);
    if (canApprove) plan.approvable.push(item);
    else plan.skipped.push({ item, reason: blockedReason ?? "" });
  }
  return plan;
}
