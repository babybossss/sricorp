/**
 * ค่าที่ฟอร์มถือไว้สำหรับหมวดแปลงค่า/แลกเงินตรา พร้อมฟังก์ชันล้วนที่เกี่ยวข้อง
 *
 * ผู้ใช้เลือกได้แค่ **วันของอัตราจากตารางอัตรา** กับ **จำนวนเงินตราที่แลก** — ไม่มีช่องพิมพ์ตัวเลขอัตรา
 * ไม่มีช่องยอดคงเหลือ ไม่มีช่องผลต่างที่ค้าง (ทั้งหมดอ่านจากสมุด · `src/lib/db/fx-context.ts`)
 * แยกเป็นไฟล์ล้วนเพราะเป็นตรรกะเรื่องเงิน เทสต์ต้อง import ตรงๆ ได้ (ไม่ติด JSX)
 */

import { dmyToIso, isoToDmy } from "@/lib/format";
import type { FxChoice } from "@/lib/db/fx-input";

export type FxDraft = {
  /** แปลงค่า: วันของอัตราสิ้นงวด (YYYY-MM-DD จากตารางอัตรา) */
  newRateDate: string;
  /** แลกเงิน: วันของอัตราที่แลกได้จริง (YYYY-MM-DD จากตารางอัตรา) */
  dealRateDate: string;
  /** แลกเงิน: จำนวนเงินตราที่แลก ตามที่พิมพ์ */
  amountOriginal: string;
};

export const EMPTY_FX: FxDraft = { newRateDate: "", dealRateDate: "", amountOriginal: "" };

/** จำนวนเงินตราจากช่องพิมพ์ — อ่านไม่ออก/ว่าง = undefined (ไม่เดาเป็น 0) */
export function parseUnits(s: string): number | undefined {
  const t = s.replace(/,/g, "").trim();
  if (!/^\d+(\.\d{1,6})?$/.test(t)) return undefined;
  const n = Number(t);
  return Number.isFinite(n) ? n : undefined;
}

/** ฟอร์ม → สิ่งที่ผู้ใช้เลือก (ตรงกับ `PostEntryRequest.fx` และอินพุตของ `fxInputFor`) */
export function fxChoiceOf(d: FxDraft): FxChoice {
  return {
    ...(d.newRateDate ? { newRateDate: d.newRateDate } : {}),
    ...(d.dealRateDate ? { dealRateDate: d.dealRateDate } : {}),
    ...(parseUnits(d.amountOriginal) !== undefined ? { amountOriginal: parseUnits(d.amountOriginal) } : {}),
  };
}

/**
 * เลือกอัตราแล้ว ตั้งวันที่เอกสารและวันที่เงินเคลื่อนเป็นวันของอัตรานั้นให้ (ผู้ใช้แก้ต่อได้)
 * — แปลงค่าสิ้นเดือนลงวันสิ้นเดือน · แลกเงินลงวันที่แลก · ไม่แตะถ้าวันของอัตราอ่านไม่ออก
 */
export function datesForRate(rateDate: string): { docDate: string; cashDate: string } | null {
  if (!rateDate) return null;
  const dmy = isoToDmy(rateDate);
  return dmyToIso(dmy) === rateDate ? { docDate: dmy, cashDate: dmy } : null;
}
