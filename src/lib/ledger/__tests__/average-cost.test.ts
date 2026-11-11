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
  costBasisModeFor,
  costPoolOf,
  planDisposal,
  sellAtAverageCost,
  sellBySpecificLots,
  sellWholeItem,
  sumConsumedCost,
  surplusToReverseFor,
  type AssetBook,
  type Lot,
} from "../average-cost";
import { PostingError } from "../types";

/**
 * **ข้อมูลอ้างอิงของทรัพย์** — วิธีคิดต้นทุนมาจากหมวด ไม่ใช่จากธงที่ส่งเข้า engine
 * (ลูกพี่สั่ง 25/10: เฉลี่ยได้เฉพาะ หุ้นในตลาดหลักทรัพย์ · คริปโต · ทองคำ)
 */
const CATEGORY_OF: Record<string, string> = {
  stk: "PAPER_STOCK_LISTED",     // หุ้นในตลาด → เฉลี่ยได้
  gold: "COM_GOLD",              // ทองคำ → เฉลี่ยได้
  coin: "COM_CRYPTO",            // คริปโต → เฉลี่ยได้
  a: "PAPER_STOCK_LISTED",
  priv: "PAPER_STOCK_PRIVATE",   // หุ้นบริษัทนอกตลาด → ห้ามเฉลี่ย (ระบุล็อต)
  watch: "COM_ALT",              // ของสะสมใน 1720 → ห้ามเฉลี่ย (ชิ้นเดียว)
  "condo-a": "RE_RENTAL",        // คอนโดห้อง A → ชิ้นเดียว
  "condo-b": "RE_RENTAL",        // คอนโดห้อง B → ชิ้นเดียว
  unset: "ZZ_NOT_IN_RULES",      // หมวดที่ตารางกฎไม่รู้จัก → ต้องถือเป็นชิ้นเดียว
};

const BOOK: AssetBook = (assetId) => ({
  assetId,
  categoryCode: CATEGORY_OF[assetId] ?? "PAPER_STOCK_LISTED",
});

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
  }, BOOK);

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
    const pool = costPoolOf(lots(), "thanakorn", "stk", BOOK);
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
      "a",
      BOOK
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
    expect(costPoolOf(mixed, "thanakorn", "stk", BOOK).unitCost).toBe(100_000);
    expect(availableQuantity(mixed, "thanakorn", "stk")).toBe(10);
    expect(availableQuantity(mixed, "sutee", "stk")).toBe(100);
  });

  it("ไม่มีล็อตในขอบเขต → ปฏิเสธ ไม่ใช่คืนต้นทุน 0 (ต้นทุน 0 = กำไรเท่ายอดขายทั้งก้อน)", () => {
    expectRejected(() => costPoolOf(lots(), "sutee", "stk", BOOK), /ไม่มีล็อต/);
    expectRejected(() => costPoolOf(lots(), "thanakorn", "gold", BOOK), /ไม่มีล็อต/);
  });

  it("ข้อมูลล็อตไม่ครบ → ปฏิเสธทุกช่อง", () => {
    expectRejected(() => costPoolOf(undefined as unknown as Lot[], "o", "a", BOOK), /ไม่ได้ส่งรายการล็อต/);
    expectRejected(
      () => costPoolOf([{ ...lots()[0], id: "" }], "thanakorn", "stk", BOOK),
      /id ต้องมีค่า/
    );
    expectRejected(
      () => costPoolOf([{ ...lots()[0], quantity: 0 }], "thanakorn", "stk", BOOK),
      /ต้องมากกว่า 0/
    );
    expectRejected(
      () => costPoolOf([{ ...lots()[0], unitCost: -1 }], "thanakorn", "stk", BOOK),
      /ติดลบไม่ได้/
    );
    expectRejected(
      () => costPoolOf([{ ...lots()[0], acquiredAt: "เมื่อวาน" }], "thanakorn", "stk", BOOK),
      /ไม่ใช่วันที่ที่อ่านได้/
    );
    expectRejected(
      () => costPoolOf([lots()[0], { ...lots()[1], id: "L1" }], "thanakorn", "stk", BOOK),
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
    const after = costPoolOf(r.remainingBook, "thanakorn", "stk", BOOK);
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
    }, BOOK);
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
    const pool = costPoolOf(odd, "o", "a", BOOK);
    const r = sellAtAverageCost(odd, {
      assetId: "a",
      ownerId: "o",
      quantity: 7,
      proceeds: 200,
      soldAt: "2026-02-01",
      priorSurplus: 13.37,
    }, BOOK);
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
    expectRejected(() => sellAtAverageCost(lots(), null as never, BOOK), /ไม่ได้ส่งข้อมูลการขาย/);
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

/* ================================================================== *
 * **ใครเฉลี่ยได้ ใครห้าม** (ลูกพี่สั่ง 25/10 · ย้ำสองรอบ)
 *
 * เฉลี่ยได้สามอย่างเท่านั้น: หุ้นในตลาดหลักทรัพย์ · คริปโต · ทองคำ
 * ที่เหลือห้ามทั้งหมด รวม **หุ้นบริษัทนอกตลาด** · อสังหาฯ ทุกชนิด ·
 * สินทรัพย์ทางเลือกอื่นที่ไม่ใช่ทอง
 *
 * ตัวเลขทุกชุดในบล็อกนี้ต้องตรงกับฝั่ง DB ตัวต่อตัว
 * (supabase/tests/zz_asset_cost_basis_mode_test.sql)
 * ================================================================== */

describe("ตัวแยกวิธีคิดต้นทุน — อ่านจากข้อมูลอ้างอิง ไม่ใช่จากผู้เรียก (D-115)", () => {
  it("หุ้นในตลาด · คริปโต · ทองคำ = average · ที่เหลือห้ามเฉลี่ย", () => {
    expect(costBasisModeFor("stk", BOOK)).toBe("average");
    expect(costBasisModeFor("coin", BOOK)).toBe("average");
    expect(costBasisModeFor("gold", BOOK)).toBe("average");
    expect(costBasisModeFor("priv", BOOK)).toBe("specific_lot");
    expect(costBasisModeFor("watch", BOOK)).toBe("whole_item");
    expect(costBasisModeFor("condo-a", BOOK)).toBe("whole_item");
  });

  it("หมวดที่ตารางกฎไม่รู้จัก → whole_item (เผลอแล้วได้ 'ห้ามเฉลี่ย')", () => {
    expect(costBasisModeFor("unset", BOOK)).toBe("whole_item");
    expect(costBasisModeFor("x", (id) => ({ assetId: id, categoryCode: "" }))).toBe("whole_item");
  });

  it("ไม่ส่งตัวอ่าน / ตัวอ่านไม่รู้จักทรัพย์ / ตอบผิดชิ้น → ปฏิเสธ ไม่ใช่เดา", () => {
    expectRejected(
      () => costBasisModeFor("stk", undefined as unknown as AssetBook),
      /ไม่ได้ส่งข้อมูลอ้างอิงของทรัพย์/
    );
    expectRejected(() => costBasisModeFor("stk", () => undefined), /ไม่พบทรัพย์/);
    expectRejected(() => costBasisModeFor("stk", () => null), /ไม่พบทรัพย์/);
    expectRejected(
      () => costBasisModeFor("stk", () => ({ assetId: "gold", categoryCode: "COM_GOLD" })),
      /ตอบผิดชิ้น|ตอบทรัพย์/
    );
  });

  it("ไม่มีช่องให้ผู้เรียกบอกว่า 'เฉลี่ยได้' — ต้องส่งแค่หมวด", () => {
    // ส่งธงปลอมเข้ามาใน AssetRef แล้วต้องไม่มีผล (หมวดเป็นตัวตัดสินเสมอ)
    const lying = (id: string) =>
      ({ assetId: id, categoryCode: "RE_RENTAL", canAverage: true }) as never;
    expect(costBasisModeFor("condo-a", lying)).toBe("whole_item");
  });
});

describe("ทรัพย์ชิ้นเดียว — กำไรจากต้นทุนของชิ้นนั้นเอง ห้ามเฉลี่ยข้ามห้อง", () => {
  const condo = () =>
    sellWholeItem(
      {
        assetId: "condo-a",
        ownerId: "thanakorn",
        proceeds: 3_500_000,
        soldAt: "2026-06-30",
        assetCost: 3_000_000,
      },
      BOOK
    );

  it("คอนโด 2 ห้องตึกเดียวกัน: ขายห้องแรก 3,500,000 → กำไร +500,000 (ไม่ใช่ −500,000)", () => {
    const r = condo();
    expect(r.mode).toBe("whole_item");
    expect(r.costRemoved).toBe(3_000_000);
    expect(r.gain).toBe(500_000);
    expect(r.outcome).toBe("gain");

    // ตัวเลขของทางที่ผิด: เฉลี่ยกับห้อง B (5,000,000) → ต้นทุน 4,000,000
    const averagedCost = (3_000_000 + 5_000_000) / 2;
    const gainIfAveraged = 3_500_000 - averagedCost;
    expect(averagedCost).toBe(4_000_000);
    expect(gainIfAveraged).toBe(-500_000);
    // สองทางต้องต่างกันชัด ไม่งั้นเทสต์นี้ไม่ได้วัดอะไร
    expect(r.gain - gainIfAveraged).toBe(1_000_000);
  });

  it("ขายคอนโดบางส่วน (ส่ง quantity/picks มา) → ปฏิเสธ พร้อมบอกว่าต้องแยกชิ้นก่อน", () => {
    expectRejected(
      () =>
        sellWholeItem(
          {
            assetId: "condo-a",
            ownerId: "thanakorn",
            proceeds: 1_050_000,
            soldAt: "2026-06-30",
            assetCost: 3_000_000,
            quantity: 0.3,
          } as never,
          BOOK
        ),
      /แบ่งขายไม่ได้[\s\S]*แยกชิ้นก่อน/
    );
    expectRejected(
      () =>
        sellWholeItem(
          {
            assetId: "condo-a",
            ownerId: "thanakorn",
            proceeds: 1_050_000,
            soldAt: "2026-06-30",
            assetCost: 3_000_000,
            picks: [{ lotId: "L1", quantity: 1 }],
          } as never,
          BOOK
        ),
      /แบ่งขายไม่ได้/
    );
  });

  it("ส่วนเกินทุน (3400) ล้าง **ทั้งก้อน** ไม่ใช่ตามสัดส่วน — ไม่เหลือเศษ", () => {
    const r = sellWholeItem(
      {
        assetId: "watch",
        ownerId: "thanakorn",
        proceeds: 2_000_000,
        soldAt: "2026-10-31",
        assetCost: 1_000_000,
        priorSurplus: 460_000,
      },
      BOOK
    );
    expect(r.surplusToReverse).toBe(460_000);
    expect(r.remainingCost).toBe(0);
    // เทียบกับสมการสัดส่วนของ D-112: ถ้าเอามาใช้กับทรัพย์ชิ้นเดียวที่ขายทั้งชิ้น
    // ก็ได้ค่าเดียวกัน — แต่ถ้ามีใครส่ง costRemoved ที่น้อยกว่าเข้ามา สัดส่วนจะเหลือเศษ
    expect(surplusToReverseFor({ priorSurplus: 460_000, costBefore: 1_000_000, costRemoved: 1_000_000 }))
      .toBe(460_000);
    expect(surplusToReverseFor({ priorSurplus: 460_000, costBefore: 1_000_000, costRemoved: 300_000 }))
      .toBe(138_000);
  });

  it("ตีราคาลง (ส่วนเกินติดลบ) ก็ล้างทั้งก้อน", () => {
    const r = sellWholeItem(
      {
        assetId: "watch",
        ownerId: "thanakorn",
        proceeds: 900_000,
        soldAt: "2026-10-31",
        assetCost: 1_000_000,
        priorSurplus: -120_000,
      },
      BOOK
    );
    expect(r.surplusToReverse).toBe(-120_000);
    expect(r.gain).toBe(-100_000);
    expect(r.outcome).toBe("loss");
  });

  it("ต้นทุน 0 / ไม่ส่งต้นทุน / ข้อมูลขาด → ปฏิเสธ ไม่ใช่เดา", () => {
    const base = {
      assetId: "condo-a",
      ownerId: "thanakorn",
      proceeds: 3_500_000,
      soldAt: "2026-06-30",
    };
    expectRejected(() => sellWholeItem({ ...base, assetCost: 0 }, BOOK), /ต้องมากกว่า 0/);
    expectRejected(() => sellWholeItem(base as never, BOOK), /ต้องเป็นตัวเลข/);
    expectRejected(
      () => sellWholeItem({ ...base, assetCost: 1, soldAt: "" }, BOOK),
      /soldAt ต้องมีค่า/
    );
    expectRejected(() => sellWholeItem(null as never, BOOK), /ไม่ได้ส่งข้อมูลการขาย/);
  });

  it("เส้นทางถัวเฉลี่ยกับคอนโด → ปฏิเสธ และบอกฟังก์ชันที่ควรใช้", () => {
    expectRejected(
      () =>
        sellAtAverageCost(
          [
            { id: "A", acquiredAt: "2026-01-01", quantity: 1, unitCost: 3_000_000, ownerId: "thanakorn", assetId: "condo-a" },
            { id: "B", acquiredAt: "2026-02-01", quantity: 1, unitCost: 5_000_000, ownerId: "thanakorn", assetId: "condo-a" },
          ],
          { assetId: "condo-a", ownerId: "thanakorn", quantity: 1, proceeds: 3_500_000, soldAt: "2026-06-30" },
          BOOK
        ),
      /sellWholeItem\(\)/
    );
    expectRejected(() => costPoolOf([], "thanakorn", "condo-a", BOOK), /ชิ้นเดียว|ห้ามเฉลี่ย|sellWholeItem/);
  });
});

describe("หุ้นบริษัทนอกตลาด — ระบุล็อตที่ขาย ห้ามเฉลี่ย", () => {
  /** ล็อต A 100 หุ้น 1,000,000 (10,000/หุ้น) · ล็อต B 100 หุ้น 3,000,000 (30,000/หุ้น) */
  const privLots = (): Lot[] => [
    { id: "PA", acquiredAt: "2025-03-01", quantity: 100, unitCost: 10_000, ownerId: "thanakorn", assetId: "priv" },
    { id: "PB", acquiredAt: "2025-09-01", quantity: 100, unitCost: 30_000, ownerId: "thanakorn", assetId: "priv" },
  ];

  it("ขายล็อต A ทั้งล็อต 1,200,000 → ต้นทุน 1,000,000 กำไร +200,000 (เฉลี่ยจะเป็น −800,000)", () => {
    const r = sellBySpecificLots(
      privLots(),
      {
        assetId: "priv",
        ownerId: "thanakorn",
        picks: [{ lotId: "PA", quantity: 100 }],
        proceeds: 1_200_000,
        soldAt: "2026-05-15",
      },
      BOOK
    );
    expect(r.mode).toBe("specific_lot");
    expect(r.costRemoved).toBe(1_000_000);
    expect(r.gain).toBe(200_000);
    expect(r.outcome).toBe("gain");

    // ตัวเลขของทางที่ผิด — ต้องต่างกันชัด
    expect(r.costIfAveragedWrongly).toBe(2_000_000);
    // กำไรถ้าเผลอเฉลี่ย = 1,200,000 − 2,000,000 = **−800,000**
    expect(1_200_000 - r.costIfAveragedWrongly).toBe(-800_000);
    expect(r.costIfAveragedWrongly - r.costRemoved).toBe(1_000_000);

    // เหลือล็อต B ครบ ราคาเดิม (ตรวจย้อนได้)
    expect(r.remainingCost).toBe(3_000_000);
    expect(r.remainingQuantity).toBe(100);
    expect(r.remaining.map((l) => [l.id, l.quantity, l.unitCost])).toEqual([["PB", 100, 30_000]]);
  });

  it("ขายล็อต B แพงกว่า → ได้คนละตัวเลขกับล็อต A (พิสูจน์ว่าไม่ได้เฉลี่ย)", () => {
    const r = sellBySpecificLots(
      privLots(),
      {
        assetId: "priv",
        ownerId: "thanakorn",
        picks: [{ lotId: "PB", quantity: 100 }],
        proceeds: 1_200_000,
        soldAt: "2026-05-15",
      },
      BOOK
    );
    expect(r.costRemoved).toBe(3_000_000);
    expect(r.gain).toBe(-1_800_000);
    expect(r.remainingCost).toBe(1_000_000);
  });

  it("ขายบางส่วนของล็อตเดียว = ราคาของล็อตนั้น ไม่ใช่ค่าเฉลี่ยของกอง", () => {
    const r = sellBySpecificLots(
      privLots(),
      {
        assetId: "priv",
        ownerId: "thanakorn",
        picks: [{ lotId: "PA", quantity: 40 }],
        proceeds: 500_000,
        soldAt: "2026-05-15",
      },
      BOOK
    );
    expect(r.costRemoved).toBe(400_000); // 10,000 × 40 ของล็อต A
    expect(r.gain).toBe(100_000);
    expect(r.costIfAveragedWrongly).toBe(800_000); // 20,000 × 40 ถ้าเฉลี่ย (ผิด)
    expect(r.remainingQuantity).toBe(160);
  });

  it("ไม่ระบุล็อต → ปฏิเสธ ไม่ใช่เดาให้ (ทุกการเดาให้กำไรคนละตัวเลข)", () => {
    const base = {
      assetId: "priv",
      ownerId: "thanakorn",
      proceeds: 1_200_000,
      soldAt: "2026-05-15",
    };
    expectRejected(() => sellBySpecificLots(privLots(), base as never, BOOK), /ต้องระบุล็อตที่ขาย/);
    expectRejected(
      () => sellBySpecificLots(privLots(), { ...base, picks: [] }, BOOK),
      /ต้องระบุล็อตที่ขาย/
    );
  });

  it("ระบุล็อตผี · ระบุซ้ำ · เกินจำนวนในล็อต · ล็อตอนาคต → ปฏิเสธทุกเคส", () => {
    const base = {
      assetId: "priv",
      ownerId: "thanakorn",
      proceeds: 1_200_000,
      soldAt: "2026-05-15",
    };
    expectRejected(
      () => sellBySpecificLots(privLots(), { ...base, picks: [{ lotId: "ZZ", quantity: 1 }] }, BOOK),
      /ไม่อยู่ในสมุด/
    );
    expectRejected(
      () =>
        sellBySpecificLots(
          privLots(),
          { ...base, picks: [{ lotId: "PA", quantity: 10 }, { lotId: "PA", quantity: 10 }] },
          BOOK
        ),
      /ซ้ำสองครั้ง/
    );
    expectRejected(
      () => sellBySpecificLots(privLots(), { ...base, picks: [{ lotId: "PA", quantity: 101 }] }, BOOK),
      /ขายเกินล็อตไม่ได้/
    );
    expectRejected(
      () =>
        sellBySpecificLots(
          privLots(),
          { ...base, soldAt: "2025-04-01", picks: [{ lotId: "PB", quantity: 1 }] },
          BOOK
        ),
      /หลังวันที่ขาย/
    );
  });

  it("ขายหมดทั้งสองล็อต → ต้นทุนที่ตัด = ทั้งกองพอดี และส่วนเกินทุนถูกล้างทั้งก้อน", () => {
    const r = sellBySpecificLots(
      privLots(),
      {
        assetId: "priv",
        ownerId: "thanakorn",
        picks: [{ lotId: "PA", quantity: 100 }, { lotId: "PB", quantity: 100 }],
        proceeds: 5_000_000,
        soldAt: "2026-05-15",
        priorSurplus: 460_000,
      },
      BOOK
    );
    expect(r.costRemoved).toBe(4_000_000);
    expect(sumConsumedCost(r.consumed)).toBe(r.costRemoved);
    expect(r.remainingCost).toBe(0);
    expect(r.remainingQuantity).toBe(0);
    expect(r.surplusToReverse).toBe(460_000);
    expect(r.gain).toBe(1_000_000);
  });

  it("หุ้นในตลาดใช้เส้นทางระบุล็อตไม่ได้ และหุ้นนอกตลาดใช้เส้นทางเฉลี่ยไม่ได้", () => {
    expectRejected(
      () =>
        sellBySpecificLots(
          lots(),
          {
            assetId: "stk",
            ownerId: "thanakorn",
            picks: [{ lotId: "L1", quantity: 1 }],
            proceeds: 100,
            soldAt: "2026-11-07",
          },
          BOOK
        ),
      /sellAtAverageCost\(\)/
    );
    expectRejected(
      () =>
        sellAtAverageCost(
          privLots(),
          { assetId: "priv", ownerId: "thanakorn", quantity: 100, proceeds: 1_200_000, soldAt: "2026-05-15" },
          BOOK
        ),
      /sellBySpecificLots\(\)/
    );
  });
});

describe("หุ้นในตลาด · ทองคำ · คริปโต — ยังถัวเฉลี่ยได้เหมือนเดิม (ข้อนี้สำคัญเท่ากัน)", () => {
  it("หุ้นในตลาดสองล็อตคนละราคา → เฉลี่ยถ่วงน้ำหนักเหมือน D-112 ไม่ถูกด่านใหม่ฆ่า", () => {
    const pool = costPoolOf(lots(), "thanakorn", "stk", BOOK);
    expect(pool.unitCost).toBe(100_000);
    const r = sell({ quantity: 3, proceeds: 450_000 });
    expect(r.costRemoved).toBe(300_000);
    expect(r.gain).toBe(150_000);
    expect(r.surplusToReverse).toBe(138_000);
  });

  it("ทองคำสองล็อตคนละราคา → เฉลี่ย 35,000/หน่วย · ขาย 10 หน่วย ต้นทุน 350,000 กำไร 50,000", () => {
    const goldLots: Lot[] = [
      { id: "GA", acquiredAt: "2025-04-01", quantity: 10, unitCost: 30_000, ownerId: "thanakorn", assetId: "gold" },
      { id: "GB", acquiredAt: "2025-10-01", quantity: 10, unitCost: 40_000, ownerId: "thanakorn", assetId: "gold" },
    ];
    expect(costPoolOf(goldLots, "thanakorn", "gold", BOOK).unitCost).toBe(35_000);
    const r = sellAtAverageCost(
      goldLots,
      { assetId: "gold", ownerId: "thanakorn", quantity: 10, proceeds: 400_000, soldAt: "2026-06-10" },
      BOOK
    );
    expect(r.costRemoved).toBe(350_000);
    expect(r.gain).toBe(50_000);
    expect(r.remainingCost).toBe(350_000);
    // ต้นทุนต่อหน่วยของกองที่เหลือไม่เปลี่ยนเพราะการขาย (คุณสมบัติของถัวเฉลี่ย)
    expect(costPoolOf(r.remainingBook, "thanakorn", "gold", BOOK).unitCost).toBe(35_000);
  });

  it("คริปโตเหรียญเดียวกันสองล็อต → เฉลี่ย 2,500,000/เหรียญ · ขาย 1 เหรียญ กำไร 300,000", () => {
    const coinLots: Lot[] = [
      { id: "CA", acquiredAt: "2025-02-01", quantity: 1, unitCost: 2_000_000, ownerId: "thanakorn", assetId: "coin" },
      { id: "CB", acquiredAt: "2025-08-01", quantity: 1, unitCost: 3_000_000, ownerId: "thanakorn", assetId: "coin" },
    ];
    expect(costPoolOf(coinLots, "thanakorn", "coin", BOOK).unitCost).toBe(2_500_000);
    const r = sellAtAverageCost(
      coinLots,
      { assetId: "coin", ownerId: "thanakorn", quantity: 1, proceeds: 2_800_000, soldAt: "2026-06-20" },
      BOOK
    );
    expect(r.costRemoved).toBe(2_500_000);
    expect(r.gain).toBe(300_000);
  });
});

describe("planDisposal — ปากทางเดียว เลือกเส้นทางจากข้อมูลอ้างอิง", () => {
  it("ส่งข้อมูลชุดเดียวกัน แต่ทรัพย์คนละหมวด → คนละเส้นทางและคนละตัวเลข", () => {
    const listed = planDisposal(
      lots(),
      { assetId: "stk", ownerId: "thanakorn", quantity: 3, proceeds: 450_000, soldAt: "2026-11-07" },
      BOOK
    );
    expect("averageUnitCost" in listed).toBe(true);
    expect(listed.costRemoved).toBe(300_000);

    const whole = planDisposal(
      [],
      {
        assetId: "condo-a",
        ownerId: "thanakorn",
        proceeds: 3_500_000,
        soldAt: "2026-06-30",
        assetCost: 3_000_000,
      },
      BOOK
    );
    expect(whole.costRemoved).toBe(3_000_000);
    expect(whole.gain).toBe(500_000);
  });

  it("หมวดที่ไม่รู้จัก → เดินเส้นทางชิ้นเดียว (ปฏิเสธการเฉลี่ย)", () => {
    expectRejected(
      () =>
        planDisposal(
          [],
          { assetId: "unset", ownerId: "thanakorn", quantity: 1, proceeds: 100, soldAt: "2026-01-01" } as never,
          BOOK
        ),
      /แบ่งขายไม่ได้|ต้องเป็นตัวเลข/
    );
  });

  it("ไม่ส่งข้อมูลอ้างอิง → ปฏิเสธที่ปากทาง ไม่หลุดไปเส้นทางใดเลย", () => {
    expectRejected(
      () =>
        planDisposal(lots(), { assetId: "stk", ownerId: "o", quantity: 1, proceeds: 1, soldAt: "2026-01-01" }, undefined as unknown as AssetBook),
      /ไม่ได้ส่งข้อมูลอ้างอิงของทรัพย์/
    );
  });
});
