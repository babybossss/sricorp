import { BIG, MICRO, MONEY_SCALE, formatScaled, parseScaled } from "./decimal";
import type { CheckedWeights } from "./weights";

/**
 * การปันส่วนยอดตามน้ำหนัก (ADR 0003 ข้อ 4.2)
 *
 *     allocated = amount * weight        **ห้ามปัด**
 *
 * เหตุผลที่ห้าม (ตัวอย่างค้านใน ADR): ปัดรายบรรทัดแล้วใบ "เดบิต 0.05+0.05 / เครดิต 0.10" แบ่ง 50/50
 * ได้ tag A เดบิต 0.06 เครดิต 0.05 (ไม่ดุล) ขณะที่ยอดรวมข้าม tag ยังตรงสมุด จึงไม่มีด่านไหนฟ้อง
 * ไม่ปัด = Σᵢ(amount × wᵢ) = amount เป๊ะ และ Σเดบิต(d×w) = w×Σd = w×Σc = Σเครดิต(c×w) เป๊ะ
 *
 * ภายในเป็น bigint ล้วน: สตางค์ (scale 2) × น้ำหนัก (scale 6) = หน่วย 10^-8 บาท — **ไม่มีการปัด ไม่มี float**
 * ไฟล์นี้ห้ามมี toFixed / Math.round / numeric(18,2) (มีเทสต์สแกนซอร์สกัน) — การปัดเพื่อแสดงผลอยู่ที่ `display.ts` ที่เดียว
 */

/** หนึ่งบรรทัดบัญชีของใบ (ยอดเป็นบาท ทศนิยมไม่เกิน 2 ตำแหน่ง · ติดลบได้ในใบกลับรายการ) */
export type AllocLine = { debit: number | string; credit: number | string };

/** ส่วนแบ่งของหนึ่ง tag — ยอดเป็นหน่วย 10^-8 บาท (แม่นตรง) */
export type TagShare = {
  tagId: string;
  weightMicro: bigint;
  debit: bigint;
  credit: bigint;
};

export type Allocation = {
  shares: TagShare[];
  /** Σ เดบิต/เครดิตของสมุด ในหน่วยเดียวกับ shares (สตางค์ × 10^6) */
  ledgerDebit: bigint;
  ledgerCredit: bigint;
};

export class AllocationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AllocationError";
  }
}

/** ยอดเงิน (บาท) → สตางค์ · หลักเกินสองตำแหน่ง/ไม่ใช่ตัวเลข = ปฏิเสธ ไม่ปัด */
export function centsOf(amount: number | string, what = "ยอดเงิน"): bigint {
  const p = parseScaled(amount, MONEY_SCALE);
  if (!p.ok) {
    throw new AllocationError(
      p.reason === "too_precise" ? `${what}มีทศนิยมเกิน 2 ตำแหน่ง ระบบไม่ปัดให้` : `${what}ต้องเป็นตัวเลข`
    );
  }
  return p.units;
}

export function allocateLines(lines: readonly AllocLine[], weights: CheckedWeights): Allocation {
  // ผลรวมน้ำหนักเป็นเงื่อนไขของความถูกต้องของทั้งฟังก์ชัน — เช็คซ้ำแม้ชนิดบอกว่าผ่านแล้ว (ราคาถูก · กันของปลอมที่ cast มา)
  const sumW = weights.entries.reduce((a, e) => a + e.micro, BIG.zero);
  if (sumW !== MICRO) throw new AllocationError("ผลรวมสัดส่วนไม่ใช่ 100% พอดี — ปันส่วนไม่ได้");

  let debitCents = BIG.zero;
  let creditCents = BIG.zero;
  for (const l of lines) {
    debitCents += centsOf(l.debit, "ยอดเดบิต");
    creditCents += centsOf(l.credit, "ยอดเครดิต");
  }
  const shares: TagShare[] = weights.entries.map((e) => ({
    tagId: e.tagId,
    weightMicro: e.micro,
    // Σ ต่อบรรทัดของ (cents × w) = (Σ cents) × w — จำนวนเต็มล้วน เลยคูณหลังรวมได้ผลเท่ากันเป๊ะ
    debit: debitCents * e.micro,
    credit: creditCents * e.micro,
  }));
  return { shares, ledgerDebit: debitCents * MICRO, ledgerCredit: creditCents * MICRO };
}

/**
 * พิสูจน์สองข้อของ ADR 0003 ข้อ 4.2 บนผลลัพธ์จริง (เป๊ะ ไม่มี tolerance) — พังเสียงดังถ้าข้อใดไม่จริง
 *   1. Σ ส่วนแบ่งข้าม tag = ยอดในสมุด
 *   2. ส่วนแบ่งของแต่ละ tag ดุลในตัวเอง **ถ้าสมุดดุล** (เดบิต = เครดิต)
 */
export function assertAllocationExact(a: Allocation): void {
  const sd = a.shares.reduce((s, x) => s + x.debit, BIG.zero);
  const sc = a.shares.reduce((s, x) => s + x.credit, BIG.zero);
  if (sd !== a.ledgerDebit || sc !== a.ledgerCredit) {
    throw new AllocationError("ผลรวมส่วนแบ่งของทุก tag ไม่เท่ายอดในสมุด");
  }
  if (a.ledgerDebit === a.ledgerCredit) {
    const off = a.shares.find((x) => x.debit !== x.credit);
    if (off) throw new AllocationError(`ส่วนแบ่งของ tag ${off.tagId} ไม่ดุล (เดบิต ${formatExact(off.debit)} / เครดิต ${formatExact(off.credit)})`);
  }
}

/** ยอดหน่วย 10^-8 บาท → ข้อความทศนิยม 8 ตำแหน่งครบ (ใช้ในข้อความ error / เทสต์ · ไม่ใช่ข้อความที่ผู้ใช้อ่าน) */
export function formatExact(units: bigint): string {
  return formatScaled(units, MONEY_SCALE + 6);
}
