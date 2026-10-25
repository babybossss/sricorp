/**
 * อัตราแลกเปลี่ยนที่ผู้ดูแลป้อนมือ — กติกาตรวจก่อนเขียนลง `sri_os.fx_rates` (ฟังก์ชันล้วน ใช้ได้ทั้งฟอร์มและ server)
 *
 * คีย์ของตาราง = (สกุล, วันที่) · `thb_per_unit` = บาทต่อ 1 หน่วย numeric(18,8) · `source` เป็น enum ('manual' | 'bot_api')
 * จึง **ที่มาของอัตราแบบข้อความ (เช่น "Google Finance") เก็บที่ `note`** ไม่ใช่ `source`
 *
 * กฎที่เลือก (ดูเหตุผลที่ `actions/fx-rates.ts`): **เพิ่มได้ · แก้ค่าของแถวเดิมไม่ได้เลย** · ลบได้เฉพาะแถวที่ยังไม่มีรายการอ้างถึง (FK ของ DB บังคับ)
 *
 * ปฏิเสธ ไม่ปัด ไม่เดา:
 *  - สกุลนอกรายการที่ระบบรู้จัก · บาท (บาทต่อบาท = 1 เสมอ ไม่ใช่สิ่งที่ป้อน)
 *  - อัตราว่าง / ศูนย์ / ติดลบ / ไม่ใช่ตัวเลข / ทศนิยมเกิน 8 ตำแหน่ง (DB ปัดเงียบๆ → ตัวเลขที่เก็บไม่ใช่ตัวที่ผู้ใช้เห็น)
 *  - วันที่ไม่ใช่วันที่จริง หรือเป็นวันในอนาคต (ด่านล็อต/ตีราคาปฏิเสธอัตราอนาคตอยู่แล้ว ป้อนไว้ก็ใช้ไม่ได้)
 *  - ไม่ระบุที่มา (ตรวจย้อนไม่ได้ว่าตัวเลขมาจากไหน — DB ไม่เติมย้อนหลังให้ได้)
 */

import { dmyToIso, parseAmountOrNull, todayDmy } from "@/lib/format";
import { BASE_CURRENCY, CURRENCIES } from "@/lib/rules/currency";

export type FxRateInput = {
  currency: string;
  /** วว/ดด/ปปปป (ค.ศ.) ตามที่ผู้ใช้พิมพ์ หรือ YYYY-MM-DD */
  rateDate: string;
  /** บาทต่อ 1 หน่วย ตามที่ผู้ใช้พิมพ์ */
  rate: string;
  /** ที่มาของอัตรา (ข้อความสั้นๆ) */
  note: string;
};

export type FxRateFieldErrors = Partial<Record<keyof FxRateInput, string>>;

export type FxRateValid = { currency: string; rate_date: string; thb_per_unit: number; note: string };
export type FxRateCheck = { ok: true; row: FxRateValid; rateText: string } | { ok: false; errors: FxRateFieldErrors };

/** สกุลที่ป้อนอัตราได้ = ทุกสกุลของระบบยกเว้นบาท */
export const FX_RATE_CURRENCIES: readonly string[] = CURRENCIES.filter((c) => c !== BASE_CURRENCY);

export const NOTE_MAX = 200;
const RATE_MAX = 1_000_000;

/** `today` รูป YYYY-MM-DD ตามเวลากรุงเทพฯ — ส่งเข้ามาเพื่อให้เทสต์ควบคุมวันได้ */
export function validateFxRate(input: FxRateInput, today: string = dmyToIso(todayDmy()) ?? ""): FxRateCheck {
  const errors: FxRateFieldErrors = {};

  const currency = (input?.currency ?? "").trim().toUpperCase();
  if (!currency) errors.currency = "เลือกสกุลเงิน";
  else if (currency === BASE_CURRENCY) errors.currency = "บาทต่อบาทเป็น 1 เสมอ ไม่ต้องป้อน — เลือกสกุลต่างประเทศ";
  else if (!FX_RATE_CURRENCIES.includes(currency)) errors.currency = `ระบบรับสกุล ${FX_RATE_CURRENCIES.join(" · ")} เท่านั้น`;

  const date = dmyToIso(input?.rateDate ?? "");
  if (!input?.rateDate?.trim()) errors.rateDate = "กรอกวันที่ของอัตรา";
  else if (!date) errors.rateDate = "วันที่ไม่ถูกต้อง — พิมพ์ วว/ดด/ปปปป เป็นปี ค.ศ. เช่น 30/11/2026";
  else if (today && date > today) errors.rateDate = "ป้อนอัตราของวันในอนาคตไม่ได้ — อัตราต้องเป็นของวันที่เกิดขึ้นแล้ว";

  const rateRaw = (input?.rate ?? "").trim();
  let rate: number | null = null;
  if (!rateRaw) errors.rate = "กรอกอัตรา (บาทต่อ 1 หน่วย)";
  else {
    rate = parseAmountOrNull(rateRaw);
    const plain = rateRaw.replace(/[,\s]/g, "");
    if (rate === null || !Number.isFinite(rate)) errors.rate = "อัตราต้องเป็นตัวเลข เช่น 36.5";
    else if (!(rate > 0)) errors.rate = "อัตราต้องมากกว่า 0 (ติดลบหรือศูนย์ใช้ไม่ได้)";
    else if (rate >= RATE_MAX) errors.rate = "อัตราสูงผิดปกติ — ตรวจว่าใส่เป็น “บาทต่อ 1 หน่วย” ไม่ใช่ทิศกลับ";
    else if (/\.\d{9,}/.test(plain)) errors.rate = "ทศนิยมได้ไม่เกิน 8 ตำแหน่ง (ฐานข้อมูลปัดเศษเงียบๆ ถ้าเกิน จึงไม่รับ)";
  }

  const note = (input?.note ?? "").trim();
  if (!note) errors.note = "ระบุที่มาของอัตรา เช่น “Google Finance 30/11/2026” — ไว้ตรวจย้อนว่าตัวเลขมาจากไหน";
  else if (note.length > NOTE_MAX) errors.note = `ที่มายาวเกิน ${NOTE_MAX} ตัวอักษร`;

  if (Object.keys(errors).length > 0 || rate === null || !date) return { ok: false, errors };
  return { ok: true, row: { currency, rate_date: date, thb_per_unit: rate, note }, rateText: rateRaw };
}

export type FxRateRow = {
  currency: string;
  rateDate: string;
  thbPerUnit: number;
  note: string | null;
  source: string;
  createdAt: string | null;
};

/** ข้อความของข้อผิดพลาดจาก DB เมื่อเขียน/ลบอัตรา — ไม่ใช้ข้อความกลางที่พูดถึงการลงสมุด */
export function humanizeFxRateError(err: { message?: string; code?: string } | null | undefined, doing: "add" | "delete"): string {
  const message = (err?.message ?? "").trim();
  const code = err?.code ?? "";
  const tail = message ? ` (รายละเอียดทางเทคนิค: ${[code, message].filter(Boolean).join(" · ")})` : "";
  if (code === "42501" || /row-level security|permission denied/i.test(message)) {
    return `บัญชีของคุณไม่มีสิทธิ์จัดการอัตราแลกเปลี่ยน — ฐานข้อมูลปฏิเสธ (ต้องมีสิทธิ์ตั้งค่าระบบ) ยังไม่มีอะไรเปลี่ยน${tail}`;
  }
  if (code === "23505") {
    return "มีอัตราของสกุลและวันที่นี้อยู่แล้ว — ระบบไม่เขียนทับ (อัตราเดิมอาจมีรายการอ้างถึงแล้ว) ถ้าอัตราเดิมผิด ให้ดูวิธีแก้ใต้ตารางอัตรา · ยังไม่มีอะไรเปลี่ยน";
  }
  if (code === "23503") {
    return "ลบอัตรานี้ไม่ได้ เพราะมีรายการ บัญชี หรือการตีราคาอ้างถึงอยู่แล้ว (ลบแล้วยอดบาทของรายการเดิมจะไม่มีอัตราให้ตรวจย้อน) — คงอัตราไว้ตามเดิม";
  }
  if (code === "23514") return `ฐานข้อมูลไม่รับค่านี้ (สกุลหรืออัตราไม่ผ่านเงื่อนไขของตาราง)${tail}`;
  if (/JWT|not authenticated|session/i.test(message)) return `เข้าสู่ระบบหมดอายุ — ให้เข้าสู่ระบบใหม่แล้วลองอีกครั้ง${tail}`;
  if (/fetch failed|network|ECONN|timeout/i.test(message)) {
    return `ติดต่อฐานข้อมูลไม่ได้ — ยังไม่ทราบว่า${doing === "add" ? "อัตราถูกบันทึก" : "ลบสำเร็จ"}หรือไม่ ให้โหลดหน้าใหม่ตรวจก่อนทำซ้ำ${tail}`;
  }
  return `ฐานข้อมูลไม่รับคำสั่งนี้ ยังไม่มีอะไรเปลี่ยน${tail}`;
}
