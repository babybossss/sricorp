import { BIG, MICRO } from "./decimal";

/**
 * **ที่เดียวในระบบที่ปัดยอดที่ปันส่วนแล้ว** (ADR 0003 ข้อ 4.2.1)
 *
 * ทุกหน้าที่โชว์ "ยอดต่อ project" เป็นบาทสองตำแหน่งต้องเรียกฟังก์ชันนี้ — ไม่ลอกกฎไปวางเอง
 * ไม่งั้น project เดียวจะโชว์คนละเลขในสองหน้า แล้วไม่มีใครรู้ว่าหน้าไหนถูก
 *
 * ทำอะไร: รับ **ยอดแม่นตรง** (หน่วย 10^-8 บาท จาก `allocation.ts`) ของทุก tag ในชุดเดียวกัน
 * แล้วคืนสตางค์ที่ปัดแล้ว โดยให้ **ผลรวมที่ปัดแล้ว = ยอดรวมแม่นตรงที่ปัดครั้งเดียว** พอดี
 * (กฎเศษที่ชั้นยอดรวม · largest remainder: ปัดลงทุกแถวก่อน แล้วแจกสตางค์ที่ขาดให้แถวที่เศษมากสุด)
 *
 * ห้ามเรียกกับค่าเดี่ยวเพื่อ "ปัดให้สวย" แล้วเอาไปบวกต่อ — ปัดแล้วไม่ใช่ตัวคูณของระบบอีกต่อไป
 * ห้ามเอาผลไปเก็บลง DB / ใช้เป็นตัวตั้งของการคำนวณอื่น: ผลนี้เกิดเพื่อให้คนอ่านเท่านั้น
 */

/** ตัวหาร: หน่วย 10^-8 → สตางค์ (10^-2) = 10^6 */
const CENT = MICRO;
const HALF = CENT / BigInt(2);

export type RoundedShares = {
  /** สตางค์ที่ปัดแล้วของแต่ละแถว ตามลำดับเดียวกับอินพุต */
  cents: bigint[];
  /** ยอดรวมแม่นตรงปัดครั้งเดียว (ครึ่งปัดออกจากศูนย์) = Σ cents เสมอ */
  totalCents: bigint;
};

export function roundShares(exact: readonly bigint[]): RoundedShares {
  const total = exact.reduce((a, x) => a + x, BIG.zero);
  const abs = total < BIG.zero ? -total : total;
  const absCents = (abs + HALF) / CENT;
  const totalCents = total < BIG.zero ? -absCents : absCents;

  // floor ที่ถูกต้องกับค่าติดลบ (bigint หารตัดไปทางศูนย์) → เศษเป็นบวกเสมอ [0, CENT)
  const floors: bigint[] = [];
  const rems: bigint[] = [];
  for (const x of exact) {
    let q = x / CENT;
    let r = x - q * CENT;
    if (r < BIG.zero) {
      q -= BIG.one;
      r += CENT;
    }
    floors.push(q);
    rems.push(r);
  }

  const base = floors.reduce((a, x) => a + x, BIG.zero);
  const need = Number(totalCents - base);
  if (need < 0 || need > exact.length) {
    // พิสูจน์ได้ว่าเกิดไม่ได้ (Σเศษ < n) — ถ้าเกิด = โค้ดนี้ผิด ห้ามคืนตัวเลขที่เดาเอา
    throw new Error("roundShares: เศษที่ต้องแจกอยู่นอกช่วงที่เป็นไปได้");
  }
  const order = exact
    .map((_, i) => i)
    .sort((i, j) => (rems[i] === rems[j] ? i - j : rems[i] > rems[j] ? -1 : 1));
  const cents = [...floors];
  for (let k = 0; k < need; k++) cents[order[k]] += BIG.one;

  return { cents, totalCents };
}

/** สตางค์ → บาท (number) สำหรับส่งเข้า `money()` แสดงผลเท่านั้น */
export function centsToBaht(cents: bigint): number {
  return Number(cents) / 100;
}
