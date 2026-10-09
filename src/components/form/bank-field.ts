import { movesCash, type SubCategory } from "@/lib/rules/tx-rules";

/**
 * ฟอร์มต้องแสดงขั้น "เลือกบัญชีธนาคาร" ให้หมวดนี้ไหม — **คำตอบมาจากตารางกฎ**
 *
 * ไม่ใช่ `required` ที่ปล่อยช่องว่างไว้: หมวดที่ไม่มีเงินเคลื่อนต้อง **ไม่โชว์ช่องเลย**
 * ช่องที่โชว์แล้วปล่อยว่างคือคำเชิญให้เลือก แล้วค่าที่เลือกจะถูกส่งเข้า engine
 * ซึ่งปฏิเสธ (ดู `buildPostingDraft()`) → ผู้ใช้เจอ error ที่ไม่เข้าใจว่าทำไม
 * และถ้าวันหนึ่ง engine เผลอเมินค่านั้นแทนที่จะปฏิเสธ บัญชีจะติดไปกับรายการเงียบๆ
 *
 * ยังไม่เลือกหมวด → `true` เพื่อให้โครงฟอร์มไม่กระพริบ (engine เป็นคนกั้นปุ่มอยู่แล้ว)
 */
export function showsBankField(sub: SubCategory | undefined): boolean {
  return sub ? movesCash(sub) : true;
}

/**
 * ป้ายช่องบัญชีธนาคาร — บอกว่าเป็นบัญชี **เข้า** หรือ **ออก** ตามหมวดย่อย
 *
 * ทิศทางอ่านจาก `sub.cash` ในตารางกฎ ไม่ใช่เดาจากรหัสหมวดหรือเครื่องหมายของยอด
 * ("บัญชี" เฉยๆ ทำให้คนกรอกไม่รู้ว่ากำลังเลือกบัญชีรับหรือบัญชีจ่าย)
 *
 * เขียนเป็น switch ครบเคสโดยตั้งใจ — ค่าใหม่ใน `CashDirection` ต้องถูกตัดสินที่นี่
 * ไม่ใช่ตกไปเป็น "บัญชีที่เงินเข้า/ออก" ซึ่งเป็นคำของ `both` และผิดสำหรับ `none`
 */
export function bankDirectionLabel(sub: SubCategory | undefined): string {
  if (!sub) return "บัญชีธนาคาร";
  if (sub.requires?.includes("transferTarget")) return "โอนออกจากบัญชี (ต้นทาง)";
  switch (sub.cash) {
    case "in":
      return "รับเงินเข้าบัญชี";
    case "out":
      return "จ่ายเงินออกจากบัญชี";
    case "both":
      return "บัญชีที่เงินเข้า/ออก";
    case "none":
      // ปกติไม่ถูกแสดง (`showsBankField()` = false) — ป้ายนี้มีไว้กันกรณีที่มีคน
      // เรนเดอร์ช่องนี้โดยไม่ถาม `showsBankField()` แล้วผู้ใช้เห็นคำที่ไม่จริง
      return "ไม่ใช้บัญชีธนาคาร (ไม่มีเงินเคลื่อน)";
  }
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
