/**
 * ทศนิยมแม่นตรงด้วยจำนวนเต็ม (bigint) — ไม่มี float ไม่มีการปัดในไฟล์นี้
 *
 * ใช้กับสองสิ่งเท่านั้น: น้ำหนัก (scale 6 ตรง numeric(9,6)) และจำนวนเงิน (scale 2 ตรง numeric(18,2))
 * อ่านข้อความทศนิยม "ตามที่เขียน" ด้วยการแยกสตริง — ไม่คูณเลขทศนิยมด้วย 1e6 แล้วปัด
 * (0.57 * 100 = 56.99999999999999 ใน float) และถ้ามีหลักเกินที่รับได้ = **ปฏิเสธ ไม่ปัดเงียบๆ**
 *
 * ADR 0003 ข้อ 4.2: การปัดเพื่อแสดงผลอยู่ที่ `display.ts` ที่เดียว
 */

export const BIG = {
  zero: BigInt(0),
  one: BigInt(1),
  ten: BigInt(10),
} as const;

/** 1 หน่วยน้ำหนัก = 0.000001 = 0.0001% · 100% = 1_000_000 หน่วย */
export const WEIGHT_SCALE = 6;
export const MICRO = BigInt(1_000_000);
/** จำนวนเงินเป็นสตางค์ (numeric(18,2)) */
export const MONEY_SCALE = 2;

export type ScaledParse =
  | { ok: true; units: bigint }
  | { ok: false; reason: "not_number" | "format" | "too_precise" };

/**
 * ตัวเลข/ข้อความทศนิยม → จำนวนเต็มหน่วย 10^-scale · ติดลบได้ (ใบกลับรายการ)
 * - รับ `number` ที่จำกัด (finite) หรือข้อความ `"-12.50"` เท่านั้น
 * - รูปแบบวิทยาศาสตร์ (1e-7) / NaN / Infinity / ชนิดอื่น → ปฏิเสธ
 * - หลักทศนิยมเกิน scale → `too_precise` เว้นแต่หลักที่เกินเป็นศูนย์ล้วน
 */
export function parseScaled(value: unknown, scale: number): ScaledParse {
  let text: string;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) return { ok: false, reason: "not_number" };
    text = String(value);
  } else if (typeof value === "string") {
    text = value.trim();
  } else {
    return { ok: false, reason: "not_number" };
  }
  const m = /^(-)?(\d+)(?:\.(\d+))?$/.exec(text);
  if (!m) return { ok: false, reason: "format" };
  const frac = m[3] ?? "";
  if (frac.length > scale && /[1-9]/.test(frac.slice(scale))) return { ok: false, reason: "too_precise" };
  const digits = m[2] + frac.slice(0, scale).padEnd(scale, "0");
  const units = BigInt(digits);
  return { ok: true, units: m[1] ? -units : units };
}

/** จำนวนเต็มหน่วย 10^-scale → ข้อความทศนิยมครบทุกหลัก (ไม่ตัดศูนย์ท้าย · ไม่ปัด) */
export function formatScaled(units: bigint, scale: number): string {
  const neg = units < BIG.zero;
  const abs = neg ? -units : units;
  const s = abs.toString().padStart(scale + 1, "0");
  const whole = s.slice(0, s.length - scale);
  const frac = s.slice(s.length - scale);
  return `${neg ? "-" : ""}${whole}${scale > 0 ? `.${frac}` : ""}`;
}
