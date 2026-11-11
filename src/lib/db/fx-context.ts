/**
 * ข้อมูลเงินตราของบัญชีเงินฝากสกุลต่างประเทศ (FCD) **ที่ต้องอ่านจากสมุด** ก่อนลงรายการแปลงค่า/แลกเงิน
 *
 * ทำไมต้องอ่านจากสมุด ไม่ให้ผู้ใช้กรอก (D-115): ยอดเงินตราคงเหลือ · อัตราที่ยอดบาทตั้งอยู่ · ผลต่างที่ค้างใน 3410
 * เป็นค่าที่ด่านฝั่ง DB คำนวณใหม่จากสมุดทุกครั้งและปฏิเสธถ้าไม่ตรง — ค่าที่ผู้เรียกกรอกได้ ด่านเชื่อไม่ได้
 * อัตราก็ไม่ให้พิมพ์: ต้องเลือกจากตาราง `fx_rates` (DB ปฏิเสธอัตราที่ไม่เท่าที่ประกาศไว้ของวันนั้น)
 *
 * ไฟล์นี้เป็นฟังก์ชันล้วน (ไม่แตะ DB) ใช้ได้ทั้งฝั่งฟอร์มและฝั่ง server · การอ่านจริงอยู่ที่ `fx-context-server.ts`
 * **ไม่คิดบัญชี** — ผลต่าง/กำไร/ขาดทุนคิดโดย `buildPosting()` ที่เดียว ที่นี่แค่ "รวมตัวเลขที่อยู่ในสมุด" ให้เป็นอินพุต
 */

import { toThb } from "@/lib/rules/currency";

export type FxRate = { currency: string; rateDate: string; thbPerUnit: number };

/** บรรทัดของบัญชีนี้ใน `v_ledger_posted` (เฉพาะคอลัมน์ที่ใช้) */
export type FxBankLine = { debit: number | string; credit: number | string; amount_original: number | string | null; fx_rate_date: string | null };
/** บรรทัด 3410 ของผู้ถือ (เฉพาะคอลัมน์ที่ใช้) */
export type FxDiffLine = { debit: number | string; credit: number | string; currency: string | null };

export type FxAccountContext = {
  bankAccountId: string;
  ownerId: string;
  currency: string;
  /** จำนวนเงินตราคงเหลือของบัญชีนี้ตามสมุด — Σ (เดบิต → +ยอดสกุลเดิม · เครดิต → −) ตรงกับที่ด่านของ DB รวม */
  units: number;
  /** ยอดบาทตามสมุดของบัญชีนี้ — Σ (เดบิต − เครดิต) */
  bookThb: number;
  /**
   * อัตราที่ยอดบาทของบัญชีตั้งอยู่ = ยอดบาท ÷ เงินตรา (8 ตำแหน่ง) · ใช้ได้เฉพาะเมื่อ `toThb(units, อัตรา) = ยอดบาท` พอดี
   * null = ไม่มีเงินตราคงเหลือ หรือหาอัตรา 8 ตำแหน่งที่คูณกลับแล้วได้ยอดบาทตรงไม่ได้
   */
  bookRate: number | null;
  /**
   * แถวในตารางอัตราที่ `units × อัตรา = ยอดบาท` พอดี (ล่าสุดก่อน) — **อัตราตามบัญชีของการแลกต้องเป็นแถวจริงในตาราง**
   * เพราะบรรทัดตัดเงินตราอ้างอัตราและวันของมัน (DB: FK + ต้องเท่าที่ประกาศ) · null = ยอดบาทไม่ได้ตั้งอยู่ที่อัตราที่ประกาศอัตราใด
   * (เช่นฝากหลายครั้งต่างอัตรา) → ต้องแปลงค่าเป็นอัตราหนึ่งก่อน แล้วจึงแลกได้
   */
  bookRateRow: FxRate | null;
  /** วันของอัตราตามบัญชีสำหรับบันทึกในรายการ: วันของ `bookRateRow` หรือวันของอัตราล่าสุดบนบัญชี */
  bookRateDate: string | null;
  /** ผลต่างอัตราแลกเปลี่ยนที่ยังค้างใน 3410 ของสกุลนี้ (เครดิตเป็นบวก · ติดลบได้) */
  unrealized: number;
  /** อัตราในตารางของสกุลนี้ ใหม่ก่อน */
  rates: FxRate[];
};

const cents = (v: number | string): number => Math.round(Number(v) * 100);
const micro = (v: number | string): number => Math.round(Number(v) * 1_000_000);

/** ผลรวมของบรรทัดบัญชีเงินตรา → จำนวนเงินตรา (หน่วย 10⁻⁶) และยอดบาท (สตางค์) เป็นเลขจำนวนเต็ม ไม่สะสมความคลาดแบบทศนิยมลอยตัว */
export function positionOf(lines: FxBankLine[]): { units: number; bookThb: number } {
  let u = 0;
  let t = 0;
  for (const l of lines) {
    const ao = l.amount_original === null ? 0 : micro(l.amount_original);
    u += Number(l.debit) > 0 ? ao : -ao;
    t += cents(l.debit) - cents(l.credit);
  }
  return { units: u / 1_000_000, bookThb: t / 100 };
}

/** ผลต่างที่ค้างใน 3410: เครดิต − เดบิต (สตางค์ → บาท) */
export function unrealizedOf(lines: FxDiffLine[], onlyCurrency?: string): number {
  let t = 0;
  for (const l of lines) {
    if (onlyCurrency !== undefined && l.currency !== onlyCurrency) continue;
    t += cents(l.credit) - cents(l.debit);
  }
  return t / 100;
}

/** อัตรา 8 ตำแหน่งที่คูณเงินตราแล้วได้ยอดบาทตรงพอดี (ด้วย `toThb` ตัวเดียวกับ engine) · ไม่มี = null */
function exactRate(units: number, thb: number): number | null {
  if (!(units > 0)) return null;
  const base = Math.round((thb / units) * 1e8);
  for (const step of [0, 1, -1, 2, -2, 3, -3]) {
    const r = (base + step) / 1e8;
    if (r > 0 && toThb(units, r) === thb) return r;
  }
  return null;
}

export function buildFxContext(args: {
  bankAccountId: string;
  ownerId: string;
  currency: string;
  bankLines: FxBankLine[];
  diffLines: FxDiffLine[];
  /** ผู้ถือมีบัญชีสกุลต่างประเทศสกุลเดียวหรือไม่ — ใช่: นับ 3410 ทั้งก้อน (ตรงกับด่านของ DB ที่ไม่ดูป้ายสกุลบนบรรทัด) · ไม่ใช่: นับตามป้าย */
  singleCurrencyOwner: boolean;
  rates: FxRate[];
}): FxAccountContext {
  const { units, bookThb } = positionOf(args.bankLines);
  const rates = args.rates
    .filter((r) => r.currency === args.currency)
    .sort((a, b) => (a.rateDate < b.rateDate ? 1 : a.rateDate > b.rateDate ? -1 : 0));
  const lastLineDate = args.bankLines
    .map((l) => l.fx_rate_date)
    .filter((d): d is string => !!d)
    .sort()
    .at(-1);
  // แถวที่ units × อัตรา = ยอดบาทพอดี · อัตราเดียวกันอาจมีหลายวัน → เลือกวันที่ยอดบาทถูกตั้งไว้จริง (วันของบรรทัดล่าสุดของบัญชี)
  // ถ้าไม่มีวันนั้นเอาวันที่ใกล้ที่สุดก่อนหน้า แล้วจึงเอาล่าสุด — ทุกแถวที่ตรงให้ยอดเท่ากัน ต่างแค่ป้ายวันในบันทึก
  const exact = units > 0 ? rates.filter((r) => toThb(units, r.thbPerUnit) === bookThb) : [];
  const bookRateRow =
    exact.find((r) => r.rateDate === lastLineDate) ?? exact.find((r) => !!lastLineDate && r.rateDate <= lastLineDate) ?? exact[0] ?? null;
  return {
    bankAccountId: args.bankAccountId,
    ownerId: args.ownerId,
    currency: args.currency,
    units,
    bookThb,
    bookRate: bookRateRow ? bookRateRow.thbPerUnit : exactRate(units, bookThb),
    bookRateRow,
    bookRateDate: bookRateRow?.rateDate ?? lastLineDate ?? null,
    unrealized: unrealizedOf(args.diffLines, args.singleCurrencyOwner ? undefined : args.currency),
    rates,
  };
}
