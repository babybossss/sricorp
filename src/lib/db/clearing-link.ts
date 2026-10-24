/**
 * ใบที่ลดบัญชีพัก (ลูกหนี้/เจ้าหนี้) ต้องบอกได้ว่าล้างของใบไหน — ตัวช่วยฝั่งแอป
 *
 * ด่านจริงอยู่ที่ DB (`fn_assert_clearing_not_over_for` · 20261025000007): ใบที่ลดบัญชีพักและมีของค้างเปิดอยู่
 * มากกว่าหนึ่งใบ ต้องมีลิงก์ไปต้นทาง (`source_ref` = `<id ต้นทาง>-clr-<n>` → DB เติม `clears_id` เอง)
 * ไฟล์นี้ **ไม่ใช่ด่าน** — ทำให้ผู้ใช้เลือกใบได้ และได้ข้อความที่อ่านรู้เรื่องก่อนถึง DB
 *
 * "ใบนี้ลดบัญชีพักไหม" อ่านจากบรรทัดที่ engine คืนมา + ผังบัญชี (สินทรัพย์ลดด้วยเครดิต · หนี้สินลดด้วยเดบิต)
 * เหมือนที่ DB ตัดสิน (`fn_txn_accrual_reduction`) — ไม่ดูรหัสหมวดหรือป้ายของผู้เรียก
 * ไม่มีคู่บัญชีที่นี่: ใช้เฉพาะรหัสบัญชีพักจากตารางกฎ (`accrualAccountCodes`)
 */
import { coa } from "@/lib/rules/coa";
import { accrualAccountCodes, type PendingAccrual } from "./pending-accruals";

export type AccrualReduction = { ownerId: string; account: string; amount: number };

type Txn = { ownerId: string; lines: { coaCode: string; debit: number; credit: number }[] };

const round2 = (n: number) => Math.round(n * 100) / 100;

/** บัญชีพักที่ใบ (ผลของ engine) ลด และเท่าไร — รายการว่าง = ไม่ใช่การล้างยอดค้าง */
export function accrualReductionsOf(transactions: Txn[]): AccrualReduction[] {
  const codes = new Set(accrualAccountCodes());
  const out: AccrualReduction[] = [];
  for (const t of transactions) {
    const byAccount = new Map<string, number>();
    for (const l of t.lines) {
      if (!codes.has(l.coaCode)) continue;
      const reduces = coa(l.coaCode).type === "liability" ? l.debit - l.credit : l.credit - l.debit;
      byAccount.set(l.coaCode, (byAccount.get(l.coaCode) ?? 0) + reduces);
    }
    for (const [account, amount] of byAccount) {
      if (round2(amount) > 0) out.push({ ownerId: t.ownerId, account, amount: round2(amount) });
    }
  }
  return out;
}

/** ของค้างที่ยังเปิดอยู่ของผู้ถือในบัญชีพักหนึ่ง (เรียงเก่า → ใหม่) — จากยอดที่อ่านมาจาก DB */
export function openSourcesFor(items: PendingAccrual[], ownerId: string, account: string): PendingAccrual[] {
  return items
    .filter((p) => p.ownerId === ownerId && p.account === account && p.outstanding > 0)
    .sort((a, b) => a.docDate.localeCompare(b.docDate) || a.id.localeCompare(b.id));
}

export const MANY_OPEN_MESSAGE =
  "มีของค้างหลายใบ ต้องเลือกว่าชำระใบไหน — เลือกรายการที่ต้องการชำระในช่อง “ชำระของรายการไหน” ก่อนบันทึก";
