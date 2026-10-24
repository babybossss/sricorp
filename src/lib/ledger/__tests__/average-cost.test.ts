/**
 * ต้นทุนถัวเฉลี่ย + ล้างส่วนเกินทุนตามสัดส่วน (**D-112 ข้อ 1** · ลูกพี่ตัดสิน 24/10)
 *
 * ฉากหลักของไฟล์นี้คือ **ฉากเดียวกับที่ผู้ตรวจวัดกำไรปลอมได้**:
 *   ซื้อ 10 หน่วย 1,000,000 → ตีราคาขึ้น 460,000 → ขาย 3 หน่วย
 *   → ต้นทุนที่ตัด 300,000 (ถัวเฉลี่ย ไม่ใช่ FIFO 270,000)
 *   → ล้างส่วนเกินทุน 30% = 138,000 (ไม่ใช่ทั้งก้อน 460,000)
 *   → ต้นทุนคงเหลือ 700,000 · ส่วนเกินทุนคงเหลือ 322,000
 * ตัวเลขชุดนี้ต้องตรงกับฝั่ง DB ตัวต่อตัว (supabase/tests/zz_asset_cost_basis_test.sql)
 * — ถ้าสองฝั่งไม่ตรงกัน ผู้ใช้จะเห็นยอดหนึ่งแล้วกดบันทึกไม่ได้โดยไม่รู้สาเหตุ
 *
 * เคส "ไม่ส่งข้อมูล" / "ส่งข้อมูลพัง" อยู่ครบโดยตั้งใจ — เทสต์ที่ส่งข้อมูลครบเสมอ
 * จะไม่มีวันแตะเส้นทางที่ข้อมูลขาด (บทเรียน mace-windu ข้อ 3)
 */

import { describe, it, expect } from "vitest";
import {
  availableQuantity,
  costPoolOf,
  sellAtAverageCost,
  sumConsumedCost,
  surplusToReverseFor,
  type Lot,
} from "../average-cost";
import { PostingError } from "../types";

/** สองล็อตคนละราคา รวม 10 หน่วย 1,000,000 → ถัวเฉลี่ย 100,000/หน่วย พอดี */
const lots = (): Lot[] => [
  { id: "L1", acquiredAt: "2026-10-01", quantity: 6, unitCost: 90_000, ownerId: "thanakorn", assetId: "stk" },
  { id: "L2", acquiredAt: "2026-10-05", quantity: 4, unitCost: 115_000, ownerId: "thanakorn", assetId: "stk" },
];

const sell = (over: Partial<Parameters<typeof sellAtAverageCost>[1]> = {}) =>
  sellAtAverageCost(lots(), {
    assetId: "stk",
    ownerId: "thanakorn",
    quantity: 3,
    proceeds: 450_000,
    soldAt: "2026-11-07",
    priorSurplus: 460_000,
    ...over,
  });

const expectRejected = (fn: () => unknown, pattern: RegExp) => {
  let thrown: unknown;
  try {
    fn();
  } catch (e) {
    thrown = e;
  }
  expect(thrown, "ต้องถูกปฏิเสธ แต่ผ่านไปได้").toBeInstanceOf(PostingError);
  expect((thrown as Error).message).toMatch(pattern);
};

describe("กองรวมและต้นทุนถัวเฉลี่ย", () => {
  it("ซื้อหลายล็อตคนละราคา → ต้นทุนถัวเฉลี่ยคิดจากทั้งกอง ไม่ใช่ราคาล็อตใดล็อตหนึ่ง", () => {
    const pool = costPoolOf(lots(), "thanakorn", "stk");
    expect(pool.quantity).toBe(10);
    expect(pool.totalCost).toBe(1_000_000);
    expect(pool.unitCost).toBe(100_000);
    expect(pool.lots).toBe(2);
    // ไม่ใช่ราคาของล็อตแรก (90,000) และไม่ใช่ล็อตล่าสุด (115,000)
    expect(pool.unitCost).not.toBe(90_000);
    expect(pool.unitCost).not.toBe(115_000);
  });

  it("ค่าเฉลี่ยถ่วงน้ำหนักด้วยจำนวน ไม่ใช่เฉลี่ยราคาแบบง่าย", () => {
    const pool = costPoolOf(
      [
        { id: "A", acquiredAt: "2026-01-01", quantity: 9, unitCost: 100, ownerId: "o", assetId: "a" },
        { id: "B", acquiredAt: "2026-02-01", quantity: 1, unitCost: 1_000, ownerId: "o", assetId: "a" },
      ],
      "o",
      "a"
    );
    // ถ่วงน้ำหนัก = 1,900/10 = 190 · เฉลี่ยราคาแบบง่ายจะได้ 550 (ผิด)
    expect(pool.totalCost).toBe(1_900);
    expect(pool.unitCost).toBe(190);
  });

  it("กองของผู้ถืออื่น/ทรัพย์อื่นไม่ถูกนับเข้ามาเฉลี่ยด้วย", () => {
    const mixed: Lot[] = [
      ...lots(),
      { id: "X", acquiredAt: "2026-10-01", quantity: 100, unitCost: 1, ownerId: "sutee", assetId: "stk" },
      { id: "Y", acquiredAt: "2026-10-01", quantity: 100, unitCost: 1, ownerId: "thanakorn", assetId: "gold" },
    ];
    expect(costPoolOf(mixed, "thanakorn", "stk").unitCost).toBe(100_000);
    expect(availableQuantity(mixed, "thanakorn", "stk")).toBe(10);
    expect(availableQuantity(mixed, "sutee", "stk")).toBe(100);
  });

  it("ไม่มีล็อตในขอบเขต → ปฏิเสธ ไม่ใช่คืนต้นทุน 0 (ต้นทุน 0 = กำไรเท่ายอดขายทั้งก้อน)", () => {
    expectRejected(() => costPoolOf(lots(), "sutee", "stk"), /ไม่มีล็อต/);
    expectRejected(() => costPoolOf(lots(), "thanakorn", "gold"), /ไม่มีล็อต/);
  });

  it("ข้อมูลล็อตไม่ครบ → ปฏิเสธทุกช่อง", () => {
    expectRejected(() => costPoolOf(undefined as unknown as Lot[], "o", "a"), /ไม่ได้ส่งรายการล็อต/);
    expectRejected(
      () => costPoolOf([{ ...lots()[0], id: "" }], "thanakorn", "stk"),
      /id ต้องมีค่า/
    );
    expectRejected(
      () => costPoolOf([{ ...lots()[0], quantity: 0 }], "thanakorn", "stk"),
      /ต้องมากกว่า 0/
    );
    expectRejected(
      () => costPoolOf([{ ...lots()[0], unitCost: -1 }], "thanakorn", "stk"),
      /ติดลบไม่ได้/
    );
    expectRejected(
      () => costPoolOf([{ ...lots()[0], acquiredAt: "เมื่อวาน" }], "thanakorn", "stk"),
      /ไม่ใช่วันที่ที่อ่านได้/
    );
    expectRejected(
      () => costPoolOf([lots()[0], { ...lots()[1], id: "L1" }], "thanakorn", "stk"),
      /id ซ้ำ/
    );
  });
});

describe("ขายบางส่วน — ฉากที่ผู้ตรวจวัดกำไรปลอมได้", () => {
  it("ต้นทุนที่ตัดคิดจากค่าเฉลี่ย (300,000) ไม่ใช่ FIFO (270,000) และไม่ใช่ล็อตล่าสุด (345,000)", () => {
    const r = sell();
    expect(r.averageUnitCost).toBe(100_000);
    expect(r.costRemoved).toBe(300_000);
    expect(r.costRemoved).not.toBe(270_000);
    expect(r.costRemoved).not.toBe(345_000);
  });

  it("กำไรคิดจากต้นทุนถัวเฉลี่ยของทั้งกอง", () => {
    const r = sell();
    expect(r.gain).toBe(150_000);
    expect(r.outcome).toBe("gain");
  });

  it("**ล้างส่วนเกินทุนตามสัดส่วน 30% = 138,000** ไม่ใช่ทั้งก้อน 460,000", () => {
    const r = sell();
    expect(r.surplusToReverse).toBe(138_000);
    expect(r.surplusToReverse).not.toBe(460_000);
    // ส่วนเกินทุนที่เหลือต้องเท่ากับ 70% ของเดิม = 322,000 (ตรงกับฝั่ง DB)
    expect(460_000 - r.surplusToReverse).toBe(322_000);
  });

  it("ต้นทุนคงเหลือ 700,000 — ไม่ใช่ 240,000 ที่เป็นกำไรปลอม", () => {
    const r = sell();
    expect(r.remainingCost).toBe(700_000);
    expect(r.remainingQuantity).toBe(7);
    // ส่วนต่างที่ผู้ตรวจวัดได้: ถ้านับขาล้างส่วนเกินทุนเป็นการลดต้นทุนด้วย
    expect(r.remainingCost - 240_000).toBe(460_000);
  });

  it("ต้นทุนต่อหน่วยของกองที่เหลือ **ไม่เปลี่ยนเพราะการขาย** (คุณสมบัติของถัวเฉลี่ย)", () => {
    const r = sell();
    expect(r.remainingCost / r.remainingQuantity).toBe(100_000);
    // และคิดใหม่จากสมุดล็อตที่เหลือก็ต้องได้ค่าเดียวกัน — ไม่มีต้นทุนสองชุด
    const after = costPoolOf(r.remainingBook, "thanakorn", "stk");
    expect(after.quantity).toBe(7);
    expect(after.totalCost).toBe(700_000);
    expect(after.unitCost).toBe(100_000);
  });

  it("ตัดทุกล็อตตามสัดส่วนเท่ากัน และยังเห็นราคาที่ซื้อจริงของทุกล็อต (ตรวจสอบย้อนได้)", () => {
    const r = sell();
    expect(r.consumed.map((c) => c.lotId)).toEqual(["L1", "L2"]);
    expect(r.consumed.map((c) => c.quantity)).toEqual([1.8, 1.2]);
    expect(sumConsumedCost(r.consumed)).toBe(r.costRemoved);
    expect(r.remaining.map((l) => [l.id, l.quantity, l.unitCost])).toEqual([
      ["L1", 4.2, 90_000],
      ["L2", 2.8, 115_000],
    ]);
  });

  it("ล็อตของผู้ถืออื่นไม่ถูกแตะใน remainingBook (ต้นทุนของคนอื่นต้องไม่หาย)", () => {
    const mixed: Lot[] = [
      ...lots(),
      { id: "X", acquiredAt: "2026-10-01", quantity: 5, unitCost: 7, ownerId: "sutee", assetId: "stk" },
    ];
    const r = sellAtAverageCost(mixed, {
      assetId: "stk",
      ownerId: "thanakorn",
      quantity: 3,
      proceeds: 450_000,
      soldAt: "2026-11-07",
    });
    expect(r.remainingBook.find((l) => l.id === "X")).toEqual(mixed[2]);
    expect(availableQuantity(r.remainingBook, "sutee", "stk")).toBe(5);
  });
});

describe("ขายหมด — ต้องไม่เหลือเศษค้าง", () => {
  it("ต้นทุนที่ตัด = ต้นทุนทั้งกองพอดี · ส่วนเกินทุนถูกล้างทั้งก้อน · ไม่มีล็อตเหลือ", () => {
    const r = sell({ quantity: 10, proceeds: 1_500_000 });
    expect(r.costRemoved).toBe(1_000_000);
    expect(r.remainingCost).toBe(0);
    expect(r.remainingQuantity).toBe(0);
    expect(r.surplusToReverse).toBe(460_000);
    expect(r.remaining).toEqual([]);
    expect(r.gain).toBe(500_000);
  });

  it("ขายหมดด้วยจำนวนที่หารไม่ลงตัว ก็ยังไม่เหลือเศษสตางค์ค้าง", () => {
    const odd: Lot[] = [
      { id: "A", acquiredAt: "2026-01-01", quantity: 3, unitCost: 33.33, ownerId: "o", assetId: "a" },
      { id: "B", acquiredAt: "2026-01-02", quantity: 4, unitCost: 11.11, ownerId: "o", assetId: "a" },
    ];
    const pool = costPoolOf(odd, "o", "a");
    const r = sellAtAverageCost(odd, {
      assetId: "a",
      ownerId: "o",
      quantity: 7,
      proceeds: 200,
      soldAt: "2026-02-01",
      priorSurplus: 13.37,
    });
    expect(r.costRemoved).toBe(pool.totalCost);
    expect(r.remainingCost).toBe(0);
    expect(sumConsumedCost(r.consumed)).toBe(pool.totalCost);
    expect(r.surplusToReverse).toBe(13.37);
  });
});

describe("สัดส่วนส่วนเกินทุน — สมการเดียวกับด่านฝั่ง DB", () => {
  it("ไม่เคยตีราคา → ไม่มีอะไรต้องล้าง", () => {
    expect(surplusToReverseFor({ priorSurplus: 0, costBefore: 1_000_000, costRemoved: 300_000 })).toBe(0);
    expect(sell({ priorSurplus: undefined }).surplusToReverse).toBe(0);
  });

  it("เคยตีราคาลง (ส่วนเกินติดลบ) → ล้างตามสัดส่วนในทิศกลับกัน", () => {
    expect(surplusToReverseFor({ priorSurplus: -460_000, costBefore: 1_000_000, costRemoved: 300_000 })).toBe(
      -138_000
    );
    expect(sell({ priorSurplus: -460_000 }).surplusToReverse).toBe(-138_000);
  });

  it("ปัดเศษแล้วขายหมดต้องได้ยอดเดิมเป๊ะ (ไม่ค้าง 1 สตางค์ใน 3400)", () => {
    expect(surplusToReverseFor({ priorSurplus: 100.01, costBefore: 3, costRemoved: 1 })).toBe(33.34);
    expect(surplusToReverseFor({ priorSurplus: 100.01, costBefore: 3, costRemoved: 3 })).toBe(100.01);
  });

  it("ส่วนเกินทุนที่ไม่มีต้นทุนรองรับ → ปฏิเสธ (ใบซื้อหายไปจากสมุด)", () => {
    expectRejected(
      () => surplusToReverseFor({ priorSurplus: 460_000, costBefore: 0, costRemoved: 0 }),
      /คิดสัดส่วนที่ขายออกไม่ได้/
    );
  });

  it("ตัดต้นทุนเกินที่ถืออยู่ → ปฏิเสธ", () => {
    expectRejected(
      () => surplusToReverseFor({ priorSurplus: 460_000, costBefore: 1_000, costRemoved: 1_001 }),
      /ต้องอยู่ระหว่าง 0 ถึงต้นทุนก่อนขาย/
    );
  });

  it("ไม่ส่งตัวเลขมาเลย → ปฏิเสธ ไม่ใช่ถือว่า 0", () => {
    expectRejected(
      () => surplusToReverseFor({ costBefore: 1, costRemoved: 1 } as never),
      /ส่วนเกินทุนที่ค้างอยู่/
    );
  });
});

describe("เส้นทางที่ข้อมูลขาดหรือผิด — ต้องปฏิเสธ ไม่ใช่เดา", () => {
  it("ขายมากกว่าที่ถืออยู่ → ปฏิเสธพร้อมบอกจำนวนที่มี", () => {
    expectRejected(() => sell({ quantity: 11 }), /ล็อตคงเหลือไม่พอ/);
  });

  it("ขาย 0 หรือติดลบ → ปฏิเสธ", () => {
    expectRejected(() => sell({ quantity: 0 }), /ต้องมากกว่า 0/);
    expectRejected(() => sell({ quantity: -1 }), /ต้องมากกว่า 0/);
  });

  it("ยอดเงินที่ได้รับติดลบ → ปฏิเสธ (ค่าใช้จ่ายต้องหักมาก่อน)", () => {
    expectRejected(() => sell({ proceeds: -1 }), /ติดลบไม่ได้/);
  });

  it("ไม่ส่งข้อมูลการขาย / ไม่ส่งผู้ถือ / ไม่ส่งทรัพย์ → ปฏิเสธ", () => {
    expectRejected(() => sellAtAverageCost(lots(), null as never), /ไม่ได้ส่งข้อมูลการขาย/);
    expectRejected(() => sell({ ownerId: "" }), /ownerId ต้องมีค่า/);
    expectRejected(() => sell({ assetId: "" }), /assetId ต้องมีค่า/);
    expectRejected(() => sell({ soldAt: "" }), /soldAt ต้องมีค่า/);
  });

  it("มีล็อตที่ซื้อหลังวันขายอยู่ในกอง → ปฏิเสธ (เฉลี่ยกับของที่ยังไม่ได้ซื้อไม่ได้)", () => {
    // ต่างจาก FIFO: ถัวเฉลี่ยรวมทุกล็อต ล็อตอนาคตจึงเจือค่าเฉลี่ยทันที
    // แม้จะ "ไม่ถูกตัด" ก็ยังทำให้ต้นทุนของหน่วยที่ขายผิด
    expectRejected(
      () => sell({ quantity: 1, soldAt: "2026-10-02" }),
      /หลังวันที่ขาย/
    );
  });

  it("จำนวนที่ละเอียดเกิน 8 ตำแหน่ง → ปฏิเสธ ไม่ปัดเงียบๆ", () => {
    expectRejected(() => sell({ quantity: 0.123456789 }), /ละเอียดเกิน 8 ตำแหน่ง/);
  });

  it("จำนวนเล็กกว่าหน่วยที่เล็กที่สุด → ปฏิเสธ (ไม่ใช่ปัดเป็น 0 แล้วต้นทุน 0)", () => {
    expectRejected(() => sell({ quantity: 1e-11 }), /เล็กกว่าหน่วยที่เล็กที่สุด/);
  });
});

/**
 * **กฎเดียวกันห้ามเขียนสองที่** (บทเรียน mace-windu ข้อ 5)
 *
 * `cost-basis.ts` (FIFO · D-038) **ถูกลบแล้ว** เพราะ D-112 เปลี่ยนไปใช้ถัวเฉลี่ยถ่วงน้ำหนัก
 * เหตุผลที่ลบไม่ใช่เก็บไว้: สองเครื่องยนต์ต้นทุนในรีโปเดียวแปลว่ากำไรคิดได้สองแบบ
 * และด่าน "ห้าม import" กันได้แค่วันนี้ ไม่ได้กันคนที่พรุ่งนี้เขียนตัวใหม่ทับ
 * ประวัติการตัดสินใจอยู่ใน `docs/DECISIONS.md` (D-038 → D-112) ซึ่งเป็นที่ที่ควรอยู่
 *
 * ข้อนี้จึงตรวจสองอย่าง: ไฟล์นั้นไม่กลับมา และไม่มีใครเรียก `consumeFifo` ที่ไหนอีก
 */
describe("FIFO ถูกแทนที่แล้ว (D-112) — ห้ามมีสองเครื่องยนต์ในเส้นทางจริง", () => {
  it("ไม่มีโค้ดฝั่งที่สร้างรายการเงิน import consumeFifo", async () => {
    const { readdirSync, readFileSync, statSync } = await import("node:fs");
    const { join } = await import("node:path");
    const walk = (dir: string): string[] =>
      readdirSync(dir).flatMap((name) => {
        const full = join(dir, name);
        return statSync(full).isDirectory() ? walk(full) : [full];
      });
    const offenders = walk("src")
      .filter((f) => /\.tsx?$/.test(f))
      // ยกเว้นไฟล์นี้เท่านั้น ที่เอ่ยชื่อ `consumeFifo` เพื่อตรวจ
      .filter((f) => !f.endsWith("average-cost.test.ts"))
      .filter((f) => /\bconsumeFifo\b/.test(readFileSync(f, "utf8")));
    expect(offenders, "D-112 ใช้ต้นทุนถัวเฉลี่ย — ไฟล์พวกนี้ยังเรียก FIFO").toEqual([]);
  });

  it("ไฟล์ FIFO เดิมไม่กลับมาอยู่ในรีโป", async () => {
    const { existsSync } = await import("node:fs");
    expect(
      existsSync("src/lib/ledger/cost-basis.ts"),
      "cost-basis.ts กลับมาแล้ว — ต้นทุนจะคิดได้สองแบบ เลือกวิธีเดียวแล้วลบอีกวิธีทิ้ง"
    ).toBe(false);
  });
});
