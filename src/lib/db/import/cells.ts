/**
 * ตัวช่วยอ่านช่อง Excel ที่ตัวอ่านยอดตั้งต้น (`opening.ts`) กับตัวอ่านชีทแจกแจงทรัพย์ (`breakdown.ts`) ใช้ร่วมกัน
 * แยกออกมาเพื่อไม่ให้สองไฟล์ import กันเป็นวง — กติกาอ่านตัวเลข **ต้องเป็นชุดเดียว**
 * (สูตร = ไม่เชื่อ · อ่านไม่ออก = ปัญหา · ทศนิยมเกิน = ปัญหา) ไม่งั้นสองชีทจะตีความยอดเดียวกันต่างกัน
 */

import { parseAmountOrNull } from "@/lib/format";
import type { Cell } from "./xlsx";
import type { ImportIssue } from "./opening";

export const round2 = (n: number) => Math.round(n * 100) / 100;
export const cents = (n: number) => Math.round(n * 100);
export const text = (c: Cell | null): string => (c && c.value !== null ? String(c.value).trim() : "");

/** จำนวนเงินจากช่องที่คนกรอก — สูตร = ไม่เชื่อ · อ่านไม่ออก = ปัญหา · ว่าง = ไม่มียอด */
export function amountFrom(
  c: Cell | null,
  where: { sheet: string; row: number; label: string },
  issues: ImportIssue[],
  decimals = 2
): number | null {
  if (!c || c.value === null || (typeof c.value === "string" && c.value.trim() === "")) return null;
  if (c.formula) {
    issues.push({ ...where, message: `${where.label}: ช่องนี้เป็นสูตร — ยอดนำเข้าต้องเป็นตัวเลขที่กรอกเอง (ระบบรวมยอดเองใหม่ทุกครั้ง ไม่เชื่อผลคำนวณของ Excel)` });
    return null;
  }
  let n: number | null;
  if (typeof c.value === "number") n = c.value;
  else if (typeof c.value === "boolean") n = null;
  else n = parseAmountOrNull(c.value);
  if (n === null || !Number.isFinite(n)) {
    issues.push({ ...where, message: `${where.label}: อ่านเป็นตัวเลขไม่ได้ ("${String(c.value).slice(0, 30)}")` });
    return null;
  }
  const scale = 10 ** decimals;
  if (Math.abs(n * scale - Math.round(n * scale)) > 1e-6) {
    issues.push({ ...where, message: `${where.label}: มีทศนิยมเกิน ${decimals} ตำแหน่ง (${n})` });
    return null;
  }
  return Math.round(n * scale) / scale;
}
