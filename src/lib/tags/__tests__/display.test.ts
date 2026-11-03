import { describe, expect, it } from "vitest";
import { allocateLines } from "../allocation";
import { centsToBaht, roundShares, roundSharePairs } from "../display";
import { checkWeights } from "../weights";

const D = (n: number) => BigInt(n);
const sum = (xs: bigint[]) => xs.reduce((a, b) => a + b, D(0));
const exact = (baht: number, w: Record<string, number>) => {
  const c = checkWeights(Object.keys(w).map((id) => ({ id })), w);
  if (!c.ok) throw new Error("weights");
  return allocateLines([{ debit: baht, credit: 0 }], c.weights).shares.map((s) => s.debit);
};

describe("roundShares · ฟังก์ชันปัดเพื่อแสดงผลตัวเดียว (ADR 0003 ข้อ 4.2.1)", () => {
  it("ผลรวมที่ปัดแล้ว = ยอดรวมที่ปัดครั้งเดียว · 100.00 แบ่งสามเท่าๆ → 33.33 + 33.33 + 33.34", () => {
    const r = roundShares(exact(100, { a: 0.333333, b: 0.333333, c: 0.333334 }));
    expect(r.cents).toEqual([D(3333), D(3333), D(3334)]);
    expect(r.totalCents).toBe(D(10000));
    expect(sum(r.cents)).toBe(r.totalCents);
  });

  it("ยอดรวมเท่ายอดในสมุดเสมอเมื่อ Σ น้ำหนัก = 1 (ไม่ว่ายอดเศษแค่ไหน)", () => {
    for (const baht of [0.01, 0.03, 1, 33.33, 99.99, 1234567.89, -250.05]) {
      for (const w of [{ a: 0.6, b: 0.4 }, { a: 0.333333, b: 0.333333, c: 0.333334 }, { a: 0.999999, b: 0.000001 }] as Record<string, number>[]) {
        const r = roundShares(exact(baht, w));
        expect(sum(r.cents), `${baht}`).toBe(r.totalCents);
        expect(centsToBaht(r.totalCents)).toBe(baht);
      }
    }
  });

  it("แต่ละแถวห่างจากค่าแม่นตรงไม่เกิน 1 สตางค์", () => {
    const ex = exact(1234567.89, { a: 0.142857, b: 0.142857, c: 0.142857, d: 0.142857, e: 0.142857, f: 0.142857, g: 0.142858 });
    const r = roundShares(ex);
    r.cents.forEach((c, i) => {
      const diff = ex[i] - c * D(1_000_000);
      expect(diff > D(-1_000_000) && diff < D(1_000_000)).toBe(true);
    });
  });

  it("ยอด 0.01 แบ่ง 60/40: ยอดรวมปัดได้ 1 สตางค์ ตกที่แถวที่เศษมากสุด (0.6) ไม่หายไป ไม่เกิน", () => {
    const r = roundShares(exact(0.01, { a: 0.6, b: 0.4 }));
    expect(r.cents).toEqual([D(1), D(0)]);
    expect(r.totalCents).toBe(D(1));
  });

  it("ยอดติดลบ: ปัดครึ่งออกจากศูนย์ที่ยอดรวม · ผลรวมยังตรง", () => {
    const r = roundShares(exact(-0.01, { a: 0.5, b: 0.5 }));
    expect(r.totalCents).toBe(D(-1));
    expect(sum(r.cents)).toBe(D(-1));
    const r2 = roundShares(exact(-100, { a: 0.333333, b: 0.333333, c: 0.333334 }));
    expect(sum(r2.cents)).toBe(D(-10000));
  });

  it("เศษเท่ากัน → แถวก่อนหน้าได้ก่อน (ผลซ้ำเดิมทุกครั้ง) · ลำดับอินพุต = ลำดับผลลัพธ์", () => {
    const r = roundShares([D(500_000), D(500_000)]); // 0.5 สตางค์ ×2 = 1 สตางค์
    expect(r.cents).toEqual([D(1), D(0)]);
    expect(roundShares([D(500_000), D(500_000)]).cents).toEqual(r.cents);
  });

  it("ว่าง / แถวเดียว", () => {
    expect(roundShares([])).toEqual({ cents: [], totalCents: D(0) });
    // 1234.5678 สตางค์ → แถวเดียวปัดเป็น 1235 และเท่ายอดรวมเสมอ
    expect(roundShares([D(1_234_567_800)])).toEqual({ cents: [D(1235)], totalCents: D(1235) });
  });

  it("ค่าสุ่ม: ผลรวมที่ปัดแล้ว = ปัดครั้งเดียว และแต่ละแถว < 1 สตางค์จากค่าจริง", () => {
    let seed = 7;
    const rnd = (n: number) => ((seed = (Math.imul(seed, 1103515245) + 12345) & 0x7fffffff), seed % n);
    for (let run = 0; run < 300; run++) {
      const n = 1 + rnd(9);
      const ex = Array.from({ length: n }, () => D(rnd(2_000_000_000) - 1_000_000_000));
      const r = roundShares(ex);
      expect(sum(r.cents)).toBe(r.totalCents);
      r.cents.forEach((c, i) => {
        const diff = ex[i] - c * D(1_000_000);
        expect(diff > D(-1_000_000) && diff < D(1_000_000)).toBe(true);
      });
    }
  });
});

describe("roundSharePairs · รับเป็นคู่ dr/cr (กันตัวเลขของ tag เดียวแสดงไม่ดุล)", () => {
  const pairs = (baht: number, w: Record<string, number>) => {
    const c = checkWeights(Object.keys(w).map((id) => ({ id })), w);
    if (!c.ok) throw new Error("weights");
    // ใบสมดุล: เดบิตหนึ่งบรรทัด เครดิตแตกเป็นสองบรรทัด → เศษต่อบรรทัดต่างกันแต่ยอดต่อ tag ต้องเท่ากัน
    const half = baht / 2;
    return allocateLines(
      [
        { debit: baht, credit: 0 },
        { debit: 0, credit: half },
        { debit: 0, credit: half },
      ],
      c.weights
    ).shares;
  };

  it("ใบสมดุล: ทุก tag ได้ dr = cr ทุกสตางค์ (ค่าสุ่ม)", () => {
    let seed = 11;
    const rnd = (n: number) => ((seed = (Math.imul(seed, 1103515245) + 12345) & 0x7fffffff), seed % n);
    const sets: Record<string, number>[] = [
      { a: 0.333333, b: 0.333333, c: 0.333334 },
      { a: 0.6, b: 0.4 },
      { a: 0.142857, b: 0.142857, c: 0.142857, d: 0.142857, e: 0.142857, f: 0.142857, g: 0.142858 },
    ];
    for (const w of sets) {
      for (let run = 0; run < 100; run++) {
        const baht = (2 * (1 + rnd(2_500_000))) / 100; // เป็นเลขสตางค์คู่ เพื่อแบ่งครึ่งเป็นสองบรรทัดเครดิตได้พอดี
        const shares = pairs(baht, w);
        const r = roundSharePairs(shares);
        expect(r.creditCents).toEqual(r.debitCents);
        expect(r.totalCreditCents).toBe(r.totalDebitCents);
        expect(sum(r.debitCents)).toBe(r.totalCents);
      }
    }
  });

  it("ยอดแม่นตรงของ tag เท่ากัน → ผลปัดเท่ากัน แม้ลำดับ/จำนวน tag เป็นแบบที่เศษไม่ลงตัว", () => {
    const x = [D(333_333_333), D(333_333_333), D(333_333_334)]; // 3.33333333 สตางค์ ×3
    const r = roundSharePairs(x.map((v) => ({ debit: v, credit: v })));
    expect(r.debitCents).toEqual(r.creditCents);
  });

  it("ถ้ายอดแม่นตรงสองฝั่งต่างกันจริง (ใบไม่สมดุล) ก็แสดงตามจริง ไม่ซ่อน", () => {
    const r = roundSharePairs([{ debit: D(1_000_000), credit: D(2_000_000) }]);
    expect(r.debitCents).toEqual([D(1)]);
    expect(r.creditCents).toEqual([D(2)]);
  });
});
