import type { PendingCashRow } from "@/lib/mock/ledger";
import type { LedgerResolver } from "@/lib/ledger/types";

/**
 * ด่านของขั้นยืนยันเงินเข้า-ออก
 *
 * ขั้นนี้ทำให้งบกระแสเงินสดวิ่ง **ต้องรู้บัญชีเสมอ** — ไม่งั้นเงินสดเพิ่ม-ลดโดยไม่รู้ว่าบัญชีไหน
 * ยอดธนาคารจะกระทบยอดกับ statement ไม่ได้ รายการที่ตั้งค้างไว้ตอนคีย์ไม่มีบัญชีมาด้วย
 * จึงต้องให้เลือกตอนนี้
 *
 * คืนข้อความเหตุที่ยืนยันไม่ได้ หรือ null ถ้ายืนยันได้ (ไม่เดาบัญชีให้ ไม่ตกไปเส้นทางปกติ)
 * บัญชีกับผู้ถือต้องตรงกัน — กติกาเดียวกับที่ engine ใช้ตอนลงบัญชีจริง
 */
export function confirmBankError(
  row: Pick<PendingCashRow, "ownerId">,
  bankId: string | undefined,
  resolve: LedgerResolver
): string | null {
  if (!bankId) return "ต้องเลือกบัญชีก่อนยืนยัน เพราะเงินสดจะเพิ่ม-ลดในบัญชีนั้น";
  const bank = resolve.bankAccount(bankId);
  if (!bank) return `ไม่พบบัญชี ${bankId}`;
  const owner = resolve.owner(row.ownerId);
  if (bank.ownerId !== row.ownerId) {
    return `บัญชีนี้ไม่ใช่ของ ${owner?.name ?? row.ownerId} — เงินจะไปโผล่ในงบของคนอื่น`;
  }
  return null;
}
