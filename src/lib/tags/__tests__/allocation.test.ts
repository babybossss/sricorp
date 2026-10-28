import { describe, expect, it } from "vitest";
import { AllocationError, allocateLines, assertAllocationExact, centsOf, formatExact, type AllocLine } from "../allocation";
import { checkWeights, type CheckedWeights } from "../weights";

const W = (w: Record<string, number>): CheckedWeights => {
  const r = checkWeights(Object.keys(w).map((id) => ({ id })), w);
  if (!r.ok) throw new Error(r.issues.map((i) => i.message).join("; "));
  return r.weights;
};
const D = (n: number) => BigInt(n);
const sum = (xs: bigint[]) => xs.reduce((a, b) => a + b, D(0));

/** พิสูจน์ทั้งสองข้อของ ADR 0003 ข้อ 4.2 — เป๊ะ ไม่มี tolerance */
function proves(lines: AllocLine[], w: Record<string, number>) {
  const a = allocateLines(lines, W(w));
  assertAllocationExact(a); // ข้อ 1 Σ = สมุด · ข้อ 2 ดุลต่อ tag
  expect(sum(a.shares.map((s) => s.debit))).toBe(a.ledgerDebit);
  expect(sum(a.shares.map((s) => s.credit))).toBe(a.ledgerCredit);
  for (const s of a.shares) expect(s.debit, s.tagId).toBe(s.credit);
  return a;
}

const sale = (amount: number): AllocLine[] => [
  { debit: amount, credit: 0 },
  { debit: 0, credit: amount },
];

describe("allocateLines · เคสบังคับของ ADR 0003 ข้อ 4.2", () => {
  it("เคสเศษสตางค์ของ ADR: เดบิต 0.05+0.05 / เครดิต 0.10 แบ่ง 50/50 → ทั้งสองฝั่งดุล 0.05 ต่อ tag", () => {
    const a = proves(
      [
        { debit: 0.05, credit: 0 },
        { debit: 0.05, credit: 0 },
        { debit: 0, credit: 0.1 },
      ],
      { A: 0.5, B: 0.5 }
    );
    for (const s of a.shares) {
      expect(formatExact(s.debit)).toBe("0.05000000");
      expect(formatExact(s.credit)).toBe("0.05000000");
    }
  });

  it("เทสต์นี้จับบั๊กได้จริง: ปัดรายบรรทัด (วิธีที่ ADR ปฏิเสธ) ทำให้ไม่ดุลที่ 0.06 / 0.05", () => {
    const lines = [{ debit: 5, credit: 0 }, { debit: 5, credit: 0 }, { debit: 0, credit: 10 }]; // สตางค์
    const roundHalfUp = (cents: number, wNum: number, wDen: number) => Math.floor((cents * wNum + wDen / 2) / wDen);
    let d = 0, c = 0;
    for (const l of lines) {
      d += roundHalfUp(l.debit, 1, 2);
      c += roundHalfUp(l.credit, 1, 2);
    }
    expect(d).toBe(6);
    expect(c).toBe(5);
    expect(d).not.toBe(c); // ถ้าวันหนึ่งใครเปลี่ยนไปปัด เทสต์ด้านบนต้องแดงด้วยเหตุเดียวกันนี้
  });

  it.each([
    ["1/3 · 1/3 · 1/3", { a: 0.333333, b: 0.333333, c: 0.333334 }],
    ["60/40", { a: 0.6, b: 0.4 }],
    ["0.999999 / 0.000001", { a: 0.999999, b: 0.000001 }],
    ["เจ็ดทาง", { a: 0.142857, b: 0.142857, c: 0.142857, d: 0.142857, e: 0.142857, f: 0.142857, g: 0.142858 }],
    ["อันเดียว 100%", { a: 1 }],
  ])("%s · ยอดเศษหลายแบบ → Σ = สมุด และดุลต่อ tag เป๊ะ", (_n, w) => {
    for (const amount of [0.01, 0.07, 1, 99.99, 100, 1234567.89, 10_000_000, 33.33]) proves(sale(amount), w);
  });

  it("ยอด 0.01 แบ่ง 60/40 → 0.006 กับ 0.004 (ไม่ปัดเป็น 0.01 / 0.00)", () => {
    const a = proves(sale(0.01), { a: 0.6, b: 0.4 });
    expect(a.shares.map((s) => formatExact(s.debit))).toEqual(["0.00600000", "0.00400000"]);
  });

  it("ยอดติดลบ (ใบกลับรายการ) → Σ = สมุด และดุลต่อ tag", () => {
    const a = proves(sale(-1234.57), { a: 0.333333, b: 0.333333, c: 0.333334 });
    expect(a.ledgerDebit < D(0)).toBe(true);
  });

  it("ใบที่สองฝั่งมีจำนวนบรรทัดไม่เท่ากัน (เดบิต 3 บรรทัด / เครดิต 1) → ดุลต่อ tag", () => {
    proves(
      [
        { debit: 33.33, credit: 0 },
        { debit: 33.33, credit: 0 },
        { debit: 33.34, credit: 0 },
        { debit: 0, credit: 100 },
      ],
      { a: 0.7, b: 0.299999, c: 0.000001 }
    );
  });

  it("ใบข้ามผู้ถือสองขา: แต่ละขาสมดุลในตัวเอง ใช้ชุดน้ำหนักเดียวกัน → ส่วนแบ่งของ tag ตรงกันสองขา", () => {
    const w = W({ a: 0.6, b: 0.4 });
    const legOut = allocateLines([{ debit: 0, credit: 250000.01 }, { debit: 250000.01, credit: 0 }], w);
    const legIn = allocateLines([{ debit: 250000.01, credit: 0 }, { debit: 0, credit: 250000.01 }], w);
    assertAllocationExact(legOut);
    assertAllocationExact(legIn);
    expect(legOut.shares.map((s) => s.debit)).toEqual(legIn.shares.map((s) => s.debit));
  });

  it("สุ่มเป็นร้อยชุด (ผลิตซ้ำได้) → ทั้งสองข้อจริงทุกชุด", () => {
    let seed = 20261028;
    const rnd = (n: number) => {
      seed = (Math.imul(seed, 1103515245) + 12345) & 0x7fffffff;
      return seed % n;
    };
    for (let run = 0; run < 200; run++) {
      const n = 1 + rnd(7);
      // แบ่ง 1_000_000 หน่วยเป็น n ก้อนบวก (ไม่มีศูนย์)
      const cuts = new Set<number>();
      while (cuts.size < n - 1) cuts.add(1 + rnd(999_999));
      const pts = [0, ...[...cuts].sort((x, y) => x - y), 1_000_000];
      const w: Record<string, number> = {};
      for (let i = 0; i < n; i++) w[`t${i}`] = Number(((pts[i + 1] - pts[i]) / 1_000_000).toFixed(6));
      const k = 1 + rnd(5);
      const cents = Array.from({ length: k }, () => rnd(2_000_000) - 500_000);
      const total = cents.reduce((a, b) => a + b, 0);
      const toBaht = (c: number) => Number((c / 100).toFixed(2));
      const lines: AllocLine[] = [...cents.map((c) => ({ debit: toBaht(c), credit: 0 })), { debit: 0, credit: toBaht(total) }];
      proves(lines, w);
    }
  });
});

describe("allocateLines · ข้อมูลผิดต้องปฏิเสธ ไม่ปัดเงียบ", () => {
  it("ยอดมีทศนิยมเกิน 2 ตำแหน่ง → ปฏิเสธ", () => {
    expect(() => allocateLines([{ debit: 0.005, credit: 0 }], W({ a: 1 }))).toThrow(AllocationError);
  });
  it.each([[Number.NaN], ["abc"], [Number.POSITIVE_INFINITY]])("ยอดที่ไม่ใช่ตัวเลข (%s) → ปฏิเสธ", (x) => {
    expect(() => allocateLines([{ debit: x as never, credit: 0 }], W({ a: 1 }))).toThrow(AllocationError);
  });
  it("ชุดน้ำหนักที่ Σ ≠ 1 ที่หลุดชนิดเข้ามา → ปฏิเสธ (กันของปลอมที่ cast)", () => {
    const fake = { entries: [{ tagId: "a", micro: D(600_000) }] } as unknown as CheckedWeights;
    expect(() => allocateLines(sale(100), fake)).toThrow(/ไม่ใช่ 100%/);
  });
  it("assertAllocationExact พังเสียงดังถ้าส่วนแบ่งไม่ดุล (สมุดดุลแต่ tag ไม่ดุล)", () => {
    const a = allocateLines(sale(100), W({ a: 0.5, b: 0.5 }));
    a.shares[0] = { ...a.shares[0], debit: a.shares[0].debit + D(1) };
    a.shares[1] = { ...a.shares[1], debit: a.shares[1].debit - D(1) };
    expect(() => assertAllocationExact(a)).toThrow(/ไม่ดุล/);
  });
  it("centsOf: ติดลบ/ศูนย์/ข้อความ", () => {
    expect(centsOf(-12.5)).toBe(D(-1250));
    expect(centsOf("0.10")).toBe(D(10));
    expect(centsOf(0)).toBe(D(0));
  });
});
