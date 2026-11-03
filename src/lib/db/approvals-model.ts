/**
 * คิวอนุมัติ — ชนิดข้อมูลและฟังก์ชันล้วน (ใช้ได้ทั้ง server และ client)
 *
 * รายการรออนุมัติคือแถว `sri_os.draft_entries` ที่ `status = 'pending'` — **ร่างไม่ใช่รายการบัญชี**
 * (ไม่อยู่ใน `transactions` จึงไม่เข้างบใดๆ จนกว่าจะอนุมัติ · กฎเหล็กข้อ 6: automation สร้างได้แค่ร่าง)
 *
 * ไฟล์นี้ **ไม่มีกฎบัญชี**: แปลงแถวร่างเป็น `PostingInput` แล้วให้ `buildPosting()` ตัดสินทุกอย่าง
 *
 * ช่องที่ `draft_entries` ไม่มี (ต้องรายงานลูกพี่): **บัญชีธนาคาร** และ **ธงยังไม่ได้รับ/จ่ายเงิน**
 *   - ไม่มีบัญชี → ส่ง "" ให้ engine (ไม่หยิบบัญชีแรกของผู้ถือมาเดา) ถ้าหมวดนั้นต้องมีขาเงินสด engine จะปฏิเสธเอง
 *   - ยังไม่ได้รับ/จ่าย = `cash_date` ว่าง (ร่างที่มีวันที่เงินเคลื่อนแต่ไม่มีบัญชีจึงอนุมัติไม่ได้ จนกว่าตารางจะมีช่องบัญชี)
 */
import { findSub, type TxTypeKey } from "@/lib/rules/tx-rules";
import type { PostingInput } from "@/lib/ledger/types";

export type DraftEntryRow = {
  id: string;
  owner_id: string;
  txn_type_code: string;
  doc_date: string;
  cash_date: string | null;
  amount: number | string;
  asset_id: string | null;
  contact_id: string | null;
  contract_id: string | null;
  memo: string | null;
  attachments: string[] | null;
  status: "pending" | "approved" | "rejected";
  reject_reason: string | null;
  due_date: string | null;
  source: string;
  source_ref: string | null;
  posted_txn_id: string | null;
  created_by: string | null;
  reviewed_by: string | null;
  reviewed_at: string | null;
  created_at: string;
};

export type ApprovalItem = {
  id: string;
  ownerId: string;
  subCode: string;
  /** null = ไม่รู้จักหมวดย่อยนี้ในตารางกฎ — อนุมัติไม่ได้ (ไม่เดาประเภท) */
  typeKey: TxTypeKey | null;
  docDate: string;
  cashDate: string | null;
  /** บวกเสมอ — ทิศทางอ่านจากตารางกฎ (`cashDirectionOf`) */
  amount: number;
  assetId: string | null;
  contactId: string | null;
  contractId: string | null;
  memo: string | null;
  attachments: string[];
  dueDate: string | null;
  source: string;
  createdBy: { id: string; name: string } | null;
  createdAt: string;
};

export function toApprovalItem(r: DraftEntryRow, nameOf: (userId: string) => string): ApprovalItem {
  return {
    id: r.id,
    ownerId: r.owner_id,
    subCode: r.txn_type_code,
    typeKey: findSub(r.txn_type_code)?.type.key ?? null,
    docDate: r.doc_date,
    cashDate: r.cash_date,
    amount: Number(r.amount),
    assetId: r.asset_id,
    contactId: r.contact_id,
    contractId: r.contract_id,
    memo: r.memo,
    attachments: r.attachments ?? [],
    dueDate: r.due_date,
    source: r.source,
    createdBy: r.created_by ? { id: r.created_by, name: nameOf(r.created_by) } : null,
    createdAt: r.created_at,
  };
}

/** ร่างนี้เข้า engine ในรูปไหน — null เมื่อไม่รู้จักหมวดย่อย */
export function approvalInput(item: ApprovalItem): PostingInput | null {
  if (item.typeKey === null) return null;
  return {
    typeKey: item.typeKey,
    subCode: item.subCode,
    amount: item.amount,
    ownerId: item.ownerId,
    // ร่างไม่มีบัญชีธนาคาร — ไม่เดา · engine ตัดสินว่าขาดไม่ได้หรือไม่
    bankAccountId: "",
    assetId: item.assetId ?? undefined,
    contactId: item.contactId ?? undefined,
    memo: item.memo ?? undefined,
    // ไม่มีวันที่เงินเคลื่อน = ยังไม่ได้รับ/จ่าย (ลงลูกหนี้/เจ้าหนี้ ไม่ใช่เงินสด)
    notYetPaid: item.cashDate === null,
    attachments: item.attachments,
  };
}

/** ทิศทางเงินของหมวดย่อย (เข้า/ออก/ไม่เคลื่อน) จากตารางกฎ — ไว้โชว์เครื่องหมายยอด ไม่ใช่เดาจากเครื่องหมายของตัวเลข */
export function cashDirectionOf(subCode: string): "in" | "out" | "both" | "none" | null {
  return findSub(subCode)?.sub.cash ?? null;
}

/** ยอดมีเครื่องหมายสำหรับแสดง: เงินออก = ติดลบ (ใช้วงเล็บ) · เงินเข้า = บวก · อื่นๆ = ไม่ใส่เครื่องหมาย */
export function signedAmount(item: Pick<ApprovalItem, "amount" | "subCode">): number {
  return cashDirectionOf(item.subCode) === "out" ? -item.amount : item.amount;
}

export const SOURCE_LABEL: Record<string, string> = {
  manual: "คีย์มือ",
  schedule: "ตารางงวด",
  payroll: "เงินเดือน",
  reimburse: "เบิกจ่าย",
  import: "นำเข้า",
  reverse: "กลับรายการ",
};
export const sourceLabel = (s: string) => SOURCE_LABEL[s] ?? s;
