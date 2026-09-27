/**
 * ค่าที่ฟอร์มถือไว้สำหรับแผงขายทรัพย์และแผงคืนเงินกู้ พร้อมฟังก์ชันล้วนที่เกี่ยวข้อง
 *
 * แยกออกจาก `disposal-panel.tsx` เพราะเป็น**ตรรกะเรื่องเงิน ไม่ใช่การแสดงผล**
 * อยู่ในไฟล์ component แล้วเทสต์ import ตรงๆ ไม่ได้ (ติด JSX)
 * ซึ่งขัดกับกติกา "test-first ทุกอย่างที่แตะเงิน"
 */

import { parseAmount } from "@/lib/format";

export type DisposalValue = {
  costBasis: string;
  salePrice: string;
  sellingCosts: string;
  /** จำนวนบวกเสมอ — ทิศทางอยู่ที่ `unrealizedDirection` ไม่ให้พิมพ์เครื่องหมายเอง */
  unrealizedAmount: string;
  unrealizedDirection: "up" | "down";
};

export const EMPTY_DISPOSAL: DisposalValue = {
  costBasis: "",
  salePrice: "",
  sellingCosts: "",
  unrealizedAmount: "",
  unrealizedDirection: "up",
};

/**
 * ส่วนต่างจากการตีราคาแบบมีเครื่องหมาย
 *
 * แยกทิศทางออกมาเป็นปุ่มแทนการให้พิมพ์เลขติดลบ เพราะ:
 * - แป้นตัวเลขบนมือถือ (`inputMode="decimal"`) ไม่มีปุ่มลบ
 * - ผู้ใช้ก๊อปตัวเลขจากหน้าจอมาวางได้ ซึ่งแสดงติดลบเป็นวงเล็บหรือ `−` ยูนิโคด
 *   เคยทำให้ตีราคาลงกลายเป็นตีราคาขึ้นโดยไม่มีอะไรฟ้อง
 */
export function signedUnrealized(v: DisposalValue): number {
  return Math.abs(parseAmount(v.unrealizedAmount)) * (v.unrealizedDirection === "down" ? -1 : 1);
}

export type RepaymentValue = {
  manualPrincipal: string;
  manualInterest: string;
  useManual: boolean;
};

export const EMPTY_REPAYMENT: RepaymentValue = {
  manualPrincipal: "",
  manualInterest: "",
  useManual: false,
};

/**
 * ต้องกรอกเงินต้น/ดอกเบี้ยเองหรือไม่
 *
 * ไม่มีตารางงวดอ้างอิง = บังคับกรอกเสมอ ไม่ว่าจะติ๊กช่องหรือไม่ — ระบบไม่เดาให้
 * กฎนี้ต้องใช้ชุดเดียวกันทั้งในแผงและในรายการช่องที่ยังขาด ไม่งั้นจะปล่อยให้กดถัดไปทั้งที่ยังไม่ครบ
 */
export function isManualSplit(value: RepaymentValue, hasSchedule: boolean): boolean {
  return value.useManual || !hasSchedule;
}
