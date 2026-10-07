import type { SubCategory } from "@/lib/rules/tx-rules";

/**
 * ป้ายช่องบัญชีธนาคาร — บอกว่าเป็นบัญชี **เข้า** หรือ **ออก** ตามหมวดย่อย
 *
 * ทิศทางอ่านจาก `sub.cash` ในตารางกฎ ไม่ใช่เดาจากรหัสหมวดหรือเครื่องหมายของยอด
 * ("บัญชี" เฉยๆ ทำให้คนกรอกไม่รู้ว่ากำลังเลือกบัญชีรับหรือบัญชีจ่าย)
 */
export function bankDirectionLabel(sub: SubCategory | undefined): string {
  if (!sub) return "บัญชีธนาคาร";
  if (sub.requires?.includes("transferTarget")) return "โอนออกจากบัญชี (ต้นทาง)";
  if (sub.cash === "in") return "รับเงินเข้าบัญชี";
  if (sub.cash === "out") return "จ่ายเงินออกจากบัญชี";
  return "บัญชีที่เงินเข้า/ออก";
}

type BankLike = { id: string; ownerId: string };

/**
 * ตัวเลือกบัญชีในฟอร์ม — เฉพาะของผู้ถือที่เลือก และเฉพาะที่ยังเปิดใช้งาน
 *
 * **ยกเว้นบัญชีที่ `keepId` ชี้อยู่** แม้ปิดใช้งานแล้ว: ตอนแก้/กลับรายการเก่า
 * บัญชีเดิมของรายการนั้นต้องยังเลือกได้ ไม่งั้นกลับรายการที่ใช้บัญชีที่ปิดไปแล้วไม่ได้
 * (การซ่อนจากตัวเลือกเป็นเรื่องของฟอร์ม — engine ยังหาบัญชีที่ปิดเจออยู่)
 */
export function bankChoices<B extends BankLike>(
  banks: B[],
  isOff: (id: string) => boolean,
  ownerId: string,
  keepId?: string
): B[] {
  return banks.filter((b) => b.ownerId === ownerId && (!isOff(b.id) || b.id === keepId));
}
