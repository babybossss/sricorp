import { findSub, movesCash } from "@/lib/rules/tx-rules";
import type { IntercompanyNature } from "@/lib/ledger/types";

/**
 * ช่องทุกช่องของ **ฝั่งเงินสด** ในฟอร์มบันทึกรายการ
 *
 * แยกไฟล์จาก `use-tx-form.ts` ด้วยเหตุผลเดียวกับ `bank-field.ts`:
 * กฎนี้เป็นฟังก์ชันล้วน ตรวจได้โดยไม่ต้องเรนเดอร์ฟอร์ม (ชั้นที่มี `.tsx` ปนอยู่)
 *
 * ช่องพวกนี้ **ไม่มีความหมายเลย** ถ้าหมวดย่อยไม่มีเงินเคลื่อน (`cash: "none"`)
 * ของเดิมล้างแต่ `bankId` แล้ว `cashDate` ค้างค่าเริ่มต้นไว้ → ตอนต่อ handler
 * เขียน DB จริง หมวดที่ไม่มีเงินเคลื่อนจะส่ง `cash_date` ไม่ null แล้วถูก trigger
 * ของ `20261009000001_cash_date_invariant` ปฏิเสธว่า "งบกระแสเงินสดจะนับเงินที่ไม่มีอยู่"
 * ซึ่งผู้ใช้ **แก้ไม่ได้เลย** เพราะฟอร์มไม่แสดงช่องนั้นให้ (ปุ่มดับโดยไม่มีทางปลด)
 */
export type CashFields = {
  /** บัญชีธนาคารที่เงินเข้า/ออก */
  bankId: string;
  /** วันที่เงินเคลื่อนจริง — ตัวที่งบกระแสเงินสดใช้ */
  cashDate: string;
  /** โอนระหว่างบัญชี — บัญชีปลายทาง */
  transferToBankId: string;
  /** ลักษณะของรายการข้ามผู้ถือ — เป็นเรื่องของ **การโอนเงิน** จึงอยู่ในชุดนี้ */
  intercompanyNature: IntercompanyNature | "";
};

/**
 * ชื่อช่องทั้งชุด — ประกาศไว้เพื่อให้ "ล้างไม่ครบ" เป็นสิ่งที่เทสต์จับได้
 * เพิ่มช่องใหม่ฝั่งเงินสดแล้วลืมล้าง = เทสต์แดง ไม่ใช่ค่าหลุดลง DB เงียบๆ
 */
export const CASH_FIELD_KEYS = ["bankId", "cashDate", "transferToBankId", "intercompanyNature"] as const;

/** ค่าตั้งต้นของช่องฝั่งเงินสด — `use-tx-form` เอาไปประกอบเป็นฟอร์มเปล่า */
export const EMPTY_CASH_FIELDS: CashFields = {
  bankId: "",
  cashDate: "03/09/2026",
  transferToBankId: "",
  intercompanyNature: "",
};

/** ทุกช่องว่าง — สภาพของหมวดที่ไม่มีเงินเคลื่อน */
const CLEARED_CASH_FIELDS: CashFields = {
  bankId: "",
  cashDate: "",
  transferToBankId: "",
  intercompanyNature: "",
};

/**
 * ค่าของช่องฝั่งเงินสดหลังเปลี่ยนหมวดย่อย
 *
 * - หมวดที่ไม่มีเงินเคลื่อน → **ล้างทุกช่อง** ไม่ใช่แค่บัญชีธนาคาร
 * - กลับมาหมวดที่เงินเคลื่อน **จากหมวดที่ไม่เคลื่อน** → คืนค่าตั้งต้น ไม่ใช่ค่าว่าง
 *   ที่ถูกบังคับทิ้งไว้ (เหตุผลเดียวกับธงค้างรับ-ค้างจ่าย: แค่แวะหมวดที่ไม่มีเงินเคลื่อน
 *   ครั้งเดียว แล้ววันที่เงินเข้าหายไปทั้งวันโดยผู้ใช้ไม่เคยลบเอง)
 * - สลับระหว่างสองหมวดที่เงินเคลื่อน → ไม่แตะอะไร ค่าที่กรอกไว้ยังอยู่
 * - หมวดที่ไม่รู้จัก → ไม่แตะอะไร ปล่อยให้ engine ปฏิเสธพร้อมเหตุผลของมัน
 *
 * คำตอบมาจากตารางกฎ (`movesCash`) ไม่ได้ไล่ชื่อหมวด
 */
export function cashFieldsFor(nextSub: string, prev: CashFields & { subCode: string }): CashFields {
  const next = findSub(nextSub)?.sub;
  if (!next) return { ...pick(prev) };
  if (!movesCash(next)) return { ...CLEARED_CASH_FIELDS };

  const prevSub = findSub(prev.subCode)?.sub;
  if (prevSub && movesCash(prevSub)) return { ...pick(prev) };
  return { ...EMPTY_CASH_FIELDS };
}

function pick(d: CashFields): CashFields {
  return {
    bankId: d.bankId,
    cashDate: d.cashDate,
    transferToBankId: d.transferToBankId,
    intercompanyNature: d.intercompanyNature,
  };
}
