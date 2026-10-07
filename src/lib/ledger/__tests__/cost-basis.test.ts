import { describe, it, expect } from "vitest";
import { consumeFifo, sumConsumedCost, availableQuantity, type Lot, type SellInput } from "../cost-basis";
import { PostingError } from "../types";

/**
 * FIFO cost basis (D-038 · ลูกพี่ยืนยัน 26/09) — ครอบคลุมหุ้น · ทองคำ · คริปโต
 *
 * เทสต์ชุดนี้ยืนยันสามเรื่องที่ถ้าผิดแล้วกำไร/ขาดทุนผิดเงียบๆ
 *  1. ลำดับการตัดล็อตต้อง deterministic
 *  2. ล็อตไม่พอ/ข้อมูลขาด ต้อง throw ไม่ใช่เดาต้นทุน
 *  3. เศษสตางค์ห้ามหายและห้ามงอก
 */

const lot = (over: Partial<Lot> & Pick<Lot, "id">): Lot => ({
  acquiredAt: "2025-01-01",
  quantity: 100,
  unitCost: 10,
  ownerId: "thanakorn",
  assetId: "a-ptt",
  ...over,
});

const sell = (over: Partial<SellInput> = {}): SellInput => ({
  assetId: "a-ptt",
  ownerId: "thanakorn",
  quantity: 100,
  proceeds: 1500,
  soldAt: "2025-06-01",
  ...over,
});

/* ------------------------------------------------------------------ *
 * 1. เส้นทางปกติ
 * ------------------------------------------------------------------ */

describe("ขายพอดีหนึ่งล็อต", () => {
  it("ตัดล็อตเดียวหมด · ต้นทุนและกำไรตรง · remaining ว่าง", () => {
    const lots = [lot({ id: "L1", quantity: 100, unitCost: 10 })];
    const r = consumeFifo(lots, sell({ quantity: 100, proceeds: 1500 }));

    expect(r.consumed).toEqual([{ lotId: "L1", quantity: 100, cost: 1000 }]);
    expect(r.totalCost).toBe(1000);
    expect(r.gain).toBe(500);
    expect(r.outcome).toBe("gain");
    expect(r.remaining).toEqual([]);
  });

  it("ไม่แก้ array/ออบเจกต์ที่ส่งเข้ามา (input ต้องไม่ถูก mutate)", () => {
    const lots = [lot({ id: "L1", quantity: 100 })];
    const snapshot = JSON.parse(JSON.stringify(lots));
    consumeFifo(lots, sell({ quantity: 40 }));
    expect(lots).toEqual(snapshot);
  });
});

describe("ขายข้ามหลายล็อต", () => {
  it("ตัดล็อตเก่าก่อนเสมอ แม้ input เรียงสลับ", () => {
    const lots = [
      lot({ id: "L3", acquiredAt: "2025-03-01", quantity: 50, unitCost: 30 }),
      lot({ id: "L1", acquiredAt: "2025-01-01", quantity: 50, unitCost: 10 }),
      lot({ id: "L2", acquiredAt: "2025-02-01", quantity: 50, unitCost: 20 }),
    ];
    const r = consumeFifo(lots, sell({ quantity: 120, proceeds: 5000 }));

    expect(r.consumed).toEqual([
      { lotId: "L1", quantity: 50, cost: 500 },
      { lotId: "L2", quantity: 50, cost: 1000 },
      { lotId: "L3", quantity: 20, cost: 600 },
    ]);
    expect(r.totalCost).toBe(2100);
    expect(r.gain).toBe(2900);
    // ล็อตสุดท้ายเหลือ 30 หน่วย ที่ต้นทุนเดิม
    expect(r.remaining).toEqual([
      { id: "L3", acquiredAt: "2025-03-01", quantity: 30, unitCost: 30, ownerId: "thanakorn", assetId: "a-ptt" },
    ]);
  });

  it("ขายทุกล็อตพอดี → remaining ว่าง", () => {
    const lots = [
      lot({ id: "L1", acquiredAt: "2025-01-01", quantity: 10, unitCost: 100 }),
      lot({ id: "L2", acquiredAt: "2025-02-01", quantity: 10, unitCost: 200 }),
    ];
    const r = consumeFifo(lots, sell({ quantity: 20, proceeds: 4000 }));
    expect(r.remaining).toEqual([]);
    expect(r.totalCost).toBe(3000);
    expect(r.gain).toBe(1000);
  });
});

describe("ขายบางส่วนของล็อต", () => {
  it("ล็อตที่เหลือมี quantity ลดลง · id เดิม · unitCost เดิม (ไม่สร้างล็อตใหม่ที่ต้นทุนเปลี่ยน)", () => {
    const lots = [lot({ id: "L1", quantity: 100, unitCost: 12.5 })];
    const r = consumeFifo(lots, sell({ quantity: 30, proceeds: 500 }));

    expect(r.consumed).toEqual([{ lotId: "L1", quantity: 30, cost: 375 }]);
    expect(r.remaining).toHaveLength(1);
    expect(r.remaining[0].id).toBe("L1");
    expect(r.remaining[0].quantity).toBe(70);
    expect(r.remaining[0].unitCost).toBe(12.5);
    expect(r.remaining[0].acquiredAt).toBe("2025-01-01");
  });

  it("ขายต่อเนื่องสองครั้งจาก remaining ให้ผลเท่ากับขายรวมครั้งเดียว", () => {
    const lots = [
      lot({ id: "L1", acquiredAt: "2025-01-01", quantity: 40, unitCost: 11 }),
      lot({ id: "L2", acquiredAt: "2025-02-01", quantity: 40, unitCost: 13 }),
    ];
    const first = consumeFifo(lots, sell({ quantity: 25, proceeds: 0 }));
    const second = consumeFifo(first.remaining, sell({ quantity: 35, proceeds: 0 }));
    const once = consumeFifo(lots, sell({ quantity: 60, proceeds: 0 }));

    expect(first.totalCost + second.totalCost).toBeCloseTo(once.totalCost, 10);
    expect(second.remaining).toEqual(once.remaining);
  });
});

/* ------------------------------------------------------------------ *
 * 2. ล็อตไม่พอ → ต้อง throw (ห้ามเดา ห้ามต้นทุน 0)
 * ------------------------------------------------------------------ */

describe("ล็อตไม่พอ", () => {
  it("ไม่มีล็อตเลย → PostingError", () => {
    expect(() => consumeFifo([], sell({ quantity: 10 }))).toThrow(PostingError);
    expect(() => consumeFifo([], sell({ quantity: 10 }))).toThrow(/ไม่มีล็อต|ไม่พอ/);
  });

  it("มีล็อตแต่ไม่พอ → PostingError และบอกยอดที่มีจริง", () => {
    const lots = [lot({ id: "L1", quantity: 10 })];
    expect(() => consumeFifo(lots, sell({ quantity: 10.5 }))).toThrow(PostingError);
    try {
      consumeFifo(lots, sell({ quantity: 10.5 }));
      throw new Error("ต้อง throw");
    } catch (e) {
      expect((e as Error).message).toContain("10");
    }
  });

  it("ไม่คืนผลลัพธ์ที่มีต้นทุน 0 แทนการ throw", () => {
    const lots = [lot({ id: "L1", quantity: 1, unitCost: 100 })];
    let result: unknown;
    try {
      result = consumeFifo(lots, sell({ quantity: 5, proceeds: 1000 }));
    } catch {
      result = "threw";
    }
    expect(result).toBe("threw");
  });
});

/* ------------------------------------------------------------------ *
 * 3. กรอง owner + asset (1 transaction = 1 owner)
 * ------------------------------------------------------------------ */

describe("กรองตาม ownerId + assetId", () => {
  it("ไม่ตัดล็อตของ owner อื่น หรือ asset อื่น", () => {
    const lots = [
      lot({ id: "OTHER-OWNER", acquiredAt: "2024-01-01", ownerId: "suthee", quantity: 999 }),
      lot({ id: "OTHER-ASSET", acquiredAt: "2024-01-01", assetId: "a-gold", quantity: 999 }),
      lot({ id: "MINE", acquiredAt: "2025-01-01", quantity: 100, unitCost: 10 }),
    ];
    const r = consumeFifo(lots, sell({ quantity: 100, proceeds: 1200 }));

    expect(r.consumed.map((c) => c.lotId)).toEqual(["MINE"]);
    expect(r.totalCost).toBe(1000);
    // remaining = ขอบเขตของ owner+asset ที่ขาย · ของคนอื่นไม่โผล่มา
    expect(r.remaining).toEqual([]);
    // remainingBook = สมุดเต็ม ของคนอื่นยังอยู่ครบ
    expect(r.remainingBook.map((l) => l.id).sort()).toEqual(["OTHER-ASSET", "OTHER-OWNER"]);
    expect(r.remainingBook.find((l) => l.id === "OTHER-OWNER")?.quantity).toBe(999);
  });

  it("ของตัวเองไม่พอ แต่ของคนอื่นเหลือเยอะ → throw ไม่ใช่ไปตัดของคนอื่น", () => {
    const lots = [
      lot({ id: "OTHER-OWNER", ownerId: "suthee", quantity: 1000 }),
      lot({ id: "OTHER-ASSET", assetId: "a-gold", quantity: 1000 }),
      lot({ id: "MINE", quantity: 5 }),
    ];
    expect(() => consumeFifo(lots, sell({ quantity: 50 }))).toThrow(PostingError);
  });

  it("availableQuantity นับแค่ขอบเขต owner+asset", () => {
    const lots = [
      lot({ id: "A", ownerId: "suthee", quantity: 1000 }),
      lot({ id: "B", quantity: 7 }),
      lot({ id: "C", quantity: 3 }),
    ];
    expect(availableQuantity(lots, "thanakorn", "a-ptt")).toBe(10);
    expect(availableQuantity(lots, "suthee", "a-ptt")).toBe(1000);
    expect(availableQuantity(lots, "nobody", "a-ptt")).toBe(0);
  });
});

/* ------------------------------------------------------------------ *
 * 4. Deterministic — วันเดียวกันหลายล็อต
 * ------------------------------------------------------------------ */

describe("tie-break เมื่อ acquiredAt เท่ากัน", () => {
  const sameDay: Lot[] = [
    lot({ id: "c", acquiredAt: "2025-04-01", quantity: 10, unitCost: 30 }),
    lot({ id: "a", acquiredAt: "2025-04-01", quantity: 10, unitCost: 10 }),
    lot({ id: "b", acquiredAt: "2025-04-01", quantity: 10, unitCost: 20 }),
  ];

  const permutations = <T,>(xs: T[]): T[][] =>
    xs.length <= 1
      ? [xs]
      : xs.flatMap((x, i) => permutations([...xs.slice(0, i), ...xs.slice(i + 1)]).map((p) => [x, ...p]));

  it("ผลลัพธ์เหมือนกันทุกครั้งแม้สลับลำดับ input (ทั้ง 6 permutation)", () => {
    const expected = consumeFifo(sameDay, sell({ quantity: 25, proceeds: 1000 }));
    const perms = permutations(sameDay);
    expect(perms).toHaveLength(6);
    for (const p of perms) {
      const r = consumeFifo(p, sell({ quantity: 25, proceeds: 1000 }));
      expect(r.consumed).toEqual(expected.consumed);
      expect(r.totalCost).toEqual(expected.totalCost);
      expect(r.remaining).toEqual(expected.remaining);
    }
  });

  it("tie-break ใช้ id เรียงขึ้น", () => {
    const r = consumeFifo(sameDay, sell({ quantity: 25, proceeds: 1000 }));
    expect(r.consumed.map((c) => c.lotId)).toEqual(["a", "b", "c"]);
    expect(r.totalCost).toBe(10 * 10 + 10 * 20 + 5 * 30);
  });

  it("id ซ้ำในขอบเขตเดียวกัน → throw (ลำดับไม่ determinististic และ consumed จะกำกวม)", () => {
    const dup = [lot({ id: "X", quantity: 5 }), lot({ id: "X", quantity: 5 })];
    expect(() => consumeFifo(dup, sell({ quantity: 3 }))).toThrow(PostingError);
  });

  it("เทียบ acquiredAt ด้วยเวลาจริง ไม่ใช่ string (รูปแบบวันที่ต่างกันก็ต้องเรียงถูก)", () => {
    const lots = [
      lot({ id: "later", acquiredAt: "2025-01-02T03:00:00Z", quantity: 5, unitCost: 99 }),
      lot({ id: "earlier", acquiredAt: "2025-01-01T23:00:00Z", quantity: 5, unitCost: 1 }),
    ];
    const r = consumeFifo(lots, sell({ quantity: 5, proceeds: 0 }));
    expect(r.consumed[0].lotId).toBe("earlier");
  });

  it("acquiredAt ที่ parse ไม่ได้ → throw", () => {
    const lots = [lot({ id: "L1", acquiredAt: "ไม่ใช่วันที่" })];
    expect(() => consumeFifo(lots, sell({ quantity: 1 }))).toThrow(PostingError);
  });

  it("soldAt ที่ parse ไม่ได้ → throw", () => {
    expect(() => consumeFifo([lot({ id: "L1" })], sell({ soldAt: "31/02/2025", quantity: 1 }))).toThrow(PostingError);
  });

  it("ล็อตที่ซื้อหลังวันที่ขาย → throw (ตัดต้นทุนจากของที่ยังไม่ได้ซื้อไม่ได้)", () => {
    const lots = [lot({ id: "FUTURE", acquiredAt: "2025-12-31", quantity: 100 })];
    expect(() => consumeFifo(lots, sell({ quantity: 1, soldAt: "2025-06-01" }))).toThrow(PostingError);
  });

  it("ซื้อ-ขายวันเดียวกัน (acquiredAt มีเวลา · soldAt ไม่มีเวลา) → ตัดได้ปกติ", () => {
    const lots = [lot({ id: "L1", acquiredAt: "2025-06-01T15:30:00Z", quantity: 10, unitCost: 10 })];
    const r = consumeFifo(lots, sell({ quantity: 10, proceeds: 120, soldAt: "2025-06-01" }));
    expect(r.totalCost).toBe(100);
  });

  it("ล็อตอนาคตที่ FIFO ยังไม่ต้องแตะ ไม่ทำให้รายการที่ถูกต้องพัง", () => {
    const lots = [
      lot({ id: "OLD", acquiredAt: "2025-01-01", quantity: 10, unitCost: 10 }),
      lot({ id: "FUTURE", acquiredAt: "2025-12-31", quantity: 10, unitCost: 99 }),
    ];
    const r = consumeFifo(lots, sell({ quantity: 10, proceeds: 150, soldAt: "2025-06-01" }));
    expect(r.consumed.map((c) => c.lotId)).toEqual(["OLD"]);
    expect(r.remaining.map((l) => l.id)).toEqual(["FUTURE"]);
  });
});

/* ------------------------------------------------------------------ *
 * 5. เศษสตางค์
 * ------------------------------------------------------------------ */

describe("เศษสตางค์", () => {
  it("ตัด 3 ล็อตที่หารไม่ลงตัว → sum(consumed.cost) === totalCost เป๊ะ", () => {
    const lots = [
      // 0.33333333 ไม่ใช่ 1/3 — 1/3 ละเอียดเกิน 8 ตำแหน่ง engine ต้องปฏิเสธ (เทสต์แยกด้านล่าง)
      lot({ id: "L1", acquiredAt: "2025-01-01", quantity: 0.33333333, unitCost: 100.07 }),
      lot({ id: "L2", acquiredAt: "2025-01-02", quantity: 0.33333333, unitCost: 100.07 }),
      lot({ id: "L3", acquiredAt: "2025-01-03", quantity: 0.33333333, unitCost: 100.07 }),
    ];
    const r = consumeFifo(lots, sell({ quantity: availableQuantity(lots, "thanakorn", "a-ptt"), proceeds: 120 }));

    expect(r.consumed).toHaveLength(3);
    expect(sumConsumedCost(r.consumed)).toBe(r.totalCost);
    expect(r.gain).toBe(Math.round((120 - r.totalCost) * 100) / 100);
  });

  it("เศษครึ่งสตางค์ต่อล็อต — ผลรวมไม่งอก", () => {
    // แต่ละล็อตต้นทุนจริง 0.005 บาท ถ้าปัดแยกล็อตจะได้ 0.01×3 = 0.03
    // แต่ยอดจริงคือ 0.015 → 0.02 ผลรวมจึงต้องเป็น 0.02 ไม่ใช่ 0.03
    const lots = [
      lot({ id: "L1", acquiredAt: "2025-01-01", quantity: 1, unitCost: 0.005 }),
      lot({ id: "L2", acquiredAt: "2025-01-02", quantity: 1, unitCost: 0.005 }),
      lot({ id: "L3", acquiredAt: "2025-01-03", quantity: 1, unitCost: 0.005 }),
    ];
    const r = consumeFifo(lots, sell({ quantity: 3, proceeds: 0 }));
    expect(r.totalCost).toBe(0.02);
    expect(sumConsumedCost(r.consumed)).toBe(0.02);
  });

  it("ทุกค่าเงินที่คืนออกมาเป็นทศนิยมไม่เกิน 2 ตำแหน่ง", () => {
    const lots = [
      lot({ id: "L1", acquiredAt: "2025-01-01", quantity: 0.777, unitCost: 1333.333 }),
      lot({ id: "L2", acquiredAt: "2025-01-02", quantity: 0.333, unitCost: 1777.777 }),
    ];
    const r = consumeFifo(lots, sell({ quantity: 1.11, proceeds: 1999.999 }));
    const twoDp = (n: number) => Math.round(n * 100) / 100 === n;
    expect(twoDp(r.totalCost)).toBe(true);
    expect(twoDp(r.gain)).toBe(true);
    for (const c of r.consumed) expect(twoDp(c.cost)).toBe(true);
    expect(sumConsumedCost(r.consumed)).toBe(r.totalCost);
  });

  it("ตัดหลายสิบล็อตที่หารไม่ลงตัว เศษก็ยังไม่หาย", () => {
    const lots = Array.from({ length: 40 }, (_, i) =>
      lot({
        id: `L${String(i).padStart(2, "0")}`,
        acquiredAt: `2025-01-${String((i % 28) + 1).padStart(2, "0")}`,
        quantity: 0.07,
        unitCost: 1 / 7,
      }),
    );
    const r = consumeFifo(lots, sell({ quantity: 40 * 0.07, proceeds: 1 }));
    expect(r.consumed).toHaveLength(40);
    expect(sumConsumedCost(r.consumed)).toBe(r.totalCost);
  });
});

/* ------------------------------------------------------------------ *
 * 6. ขาดทุน / จุดคุ้มทุน
 * ------------------------------------------------------------------ */

describe("กำไร ขาดทุน คุ้มทุน", () => {
  it("proceeds < cost → ขาดทุน (gain ติดลบ · outcome = loss)", () => {
    const lots = [lot({ id: "L1", quantity: 10, unitCost: 100 })];
    const r = consumeFifo(lots, sell({ quantity: 10, proceeds: 400 }));
    expect(r.totalCost).toBe(1000);
    expect(r.gain).toBe(-600);
    expect(r.outcome).toBe("loss");
  });

  it("proceeds = cost → คุ้มทุน (ไม่ลง gain/loss)", () => {
    const lots = [lot({ id: "L1", quantity: 10, unitCost: 100 })];
    const r = consumeFifo(lots, sell({ quantity: 10, proceeds: 1000 }));
    expect(r.gain).toBe(0);
    expect(r.outcome).toBe("breakeven");
  });

  it("proceeds = 0 ขายทิ้ง → ขาดทุนเต็มต้นทุน", () => {
    const lots = [lot({ id: "L1", quantity: 2, unitCost: 55.55 })];
    const r = consumeFifo(lots, sell({ quantity: 2, proceeds: 0 }));
    expect(r.totalCost).toBe(111.1);
    expect(r.gain).toBe(-111.1);
    expect(r.outcome).toBe("loss");
  });
});

/* ------------------------------------------------------------------ *
 * 7. คริปโต — ทศนิยม 8 ตำแหน่ง
 * ------------------------------------------------------------------ */

describe("quantity ทศนิยม (คริปโต 8 ตำแหน่ง · ทองคำ)", () => {
  it("ตัดข้ามล็อตด้วยจำนวนทศนิยม 8 ตำแหน่งได้ · remaining ไม่มี error ลอยท้าย", () => {
    const lots = [
      lot({ id: "BTC1", assetId: "a-btc", acquiredAt: "2024-05-01", quantity: 0.12345678, unitCost: 2000000 }),
      lot({ id: "BTC2", assetId: "a-btc", acquiredAt: "2024-06-01", quantity: 0.5, unitCost: 2400000 }),
    ];
    const r = consumeFifo(
      lots,
      sell({ assetId: "a-btc", quantity: 0.2, proceeds: 800000, soldAt: "2025-01-01" }),
    );

    expect(r.consumed[0]).toEqual({ lotId: "BTC1", quantity: 0.12345678, cost: 246913.56 });
    expect(r.consumed[1].lotId).toBe("BTC2");
    expect(r.consumed[1].quantity).toBe(0.07654322);
    expect(sumConsumedCost(r.consumed)).toBe(r.totalCost);
    // 0.5 - 0.07654322 ต้องเป็น 0.42345678 พอดี ไม่ใช่ 0.4234567799999
    expect(r.remaining).toHaveLength(1);
    expect(r.remaining[0].quantity).toBe(0.42345678);
  });

  it("ขายทองคำ 1.5 บาททอง จากล็อต 2.3 → เหลือ 0.8 พอดี", () => {
    const lots = [lot({ id: "G1", assetId: "a-gold", quantity: 2.3, unitCost: 42000 })];
    const r = consumeFifo(lots, sell({ assetId: "a-gold", quantity: 1.5, proceeds: 65000 }));
    expect(r.remaining[0].quantity).toBe(0.8);
    expect(r.totalCost).toBe(63000);
  });

  it("quantity ละเอียดเกิน 8 ตำแหน่ง → throw (ปัดเงียบๆ = จำนวนเพี้ยน)", () => {
    const lots = [lot({ id: "L1", quantity: 10 })];
    expect(() => consumeFifo(lots, sell({ quantity: 0.123456789 }))).toThrow(PostingError);
  });

  it("ล็อตที่ quantity ละเอียดเกิน 8 ตำแหน่ง → throw", () => {
    const lots = [lot({ id: "L1", quantity: 0.1234567891 })];
    expect(() => consumeFifo(lots, sell({ quantity: 0.1 }))).toThrow(PostingError);
  });
});

/* ------------------------------------------------------------------ *
 * 8. input ไม่ถูกต้อง
 * ------------------------------------------------------------------ */

describe("input ไม่ถูกต้อง → throw", () => {
  const lots = [lot({ id: "L1", quantity: 100 })];

  it("quantity ≤ 0", () => {
    expect(() => consumeFifo(lots, sell({ quantity: 0 }))).toThrow(PostingError);
    expect(() => consumeFifo(lots, sell({ quantity: -5 }))).toThrow(PostingError);
  });

  it("proceeds < 0", () => {
    expect(() => consumeFifo(lots, sell({ proceeds: -1 }))).toThrow(PostingError);
  });

  it("quantity / proceeds ที่ไม่ใช่ตัวเลขจำกัด", () => {
    expect(() => consumeFifo(lots, sell({ quantity: Number.NaN }))).toThrow(PostingError);
    expect(() => consumeFifo(lots, sell({ quantity: Number.POSITIVE_INFINITY }))).toThrow(PostingError);
    expect(() => consumeFifo(lots, sell({ proceeds: Number.NaN }))).toThrow(PostingError);
  });

  it("ล็อตที่ quantity ≤ 0 (รวมล็อตติดลบ) → throw ไม่ใช่ข้ามไปเงียบๆ", () => {
    expect(() => consumeFifo([lot({ id: "Z", quantity: 0 })], sell({ quantity: 1 }))).toThrow(PostingError);
    expect(() => consumeFifo([lot({ id: "N", quantity: -3 })], sell({ quantity: 1 }))).toThrow(PostingError);
  });

  it("ล็อตที่ unitCost ติดลบ → throw", () => {
    expect(() => consumeFifo([lot({ id: "L1", unitCost: -1 })], sell({ quantity: 1 }))).toThrow(PostingError);
  });

  it("ล็อตนอกขอบเขตที่ข้อมูลพัง ไม่ทำให้รายการที่ถูกต้องพัง (ตรวจเฉพาะขอบเขตที่ตัด)", () => {
    const mixed = [
      lot({ id: "BAD", ownerId: "suthee", quantity: -99 }),
      lot({ id: "GOOD", quantity: 10, unitCost: 10 }),
    ];
    const r = consumeFifo(mixed, sell({ quantity: 10, proceeds: 100 }));
    expect(r.totalCost).toBe(100);
  });
});

/* ------------------------------------------------------------------ *
 * 9. ข้อมูลขาด — บทเรียนข้อ 3 (เทสต์ที่ส่งข้อมูลครบเสมอจะไม่แตะเส้นทางนี้)
 * ------------------------------------------------------------------ */

describe("ข้อมูลไม่ครบ → ปฏิเสธ ไม่ใช่เดา", () => {
  const partial = (o: Record<string, unknown>) => o as unknown as SellInput;
  const partialLot = (o: Record<string, unknown>) => o as unknown as Lot;

  it("ไม่ส่ง lots เลย", () => {
    expect(() => consumeFifo(undefined as unknown as Lot[], sell())).toThrow(PostingError);
    expect(() => consumeFifo(null as unknown as Lot[], sell())).toThrow(PostingError);
  });

  it("ไม่ส่ง input เลย", () => {
    expect(() => consumeFifo([lot({ id: "L1" })], undefined as unknown as SellInput)).toThrow(PostingError);
  });

  it("input ขาด assetId", () => {
    expect(() =>
      consumeFifo([lot({ id: "L1" })], partial({ ownerId: "thanakorn", quantity: 1, proceeds: 10, soldAt: "2025-06-01" })),
    ).toThrow(PostingError);
  });

  it("input ขาด ownerId (ห้าม default เป็นเจ้าของล็อตแรก)", () => {
    expect(() =>
      consumeFifo([lot({ id: "L1" })], partial({ assetId: "a-ptt", quantity: 1, proceeds: 10, soldAt: "2025-06-01" })),
    ).toThrow(PostingError);
  });

  it("input ขาด quantity", () => {
    expect(() =>
      consumeFifo(
        [lot({ id: "L1" })],
        partial({ assetId: "a-ptt", ownerId: "thanakorn", proceeds: 10, soldAt: "2025-06-01" }),
      ),
    ).toThrow(PostingError);
  });

  it("input ขาด proceeds (ห้ามถือว่า 0 แล้วลงขาดทุนเต็มต้นทุน)", () => {
    expect(() =>
      consumeFifo(
        [lot({ id: "L1" })],
        partial({ assetId: "a-ptt", ownerId: "thanakorn", quantity: 1, soldAt: "2025-06-01" }),
      ),
    ).toThrow(PostingError);
  });

  it("input ขาด soldAt", () => {
    expect(() =>
      consumeFifo(
        [lot({ id: "L1" })],
        partial({ assetId: "a-ptt", ownerId: "thanakorn", quantity: 1, proceeds: 10 }),
      ),
    ).toThrow(PostingError);
  });

  it("ล็อตขาด id", () => {
    expect(() =>
      consumeFifo(
        [partialLot({ acquiredAt: "2025-01-01", quantity: 10, unitCost: 10, ownerId: "thanakorn", assetId: "a-ptt" })],
        sell({ quantity: 1 }),
      ),
    ).toThrow(PostingError);
  });

  it("ล็อตขาด acquiredAt (เรียง FIFO ไม่ได้)", () => {
    expect(() =>
      consumeFifo(
        [partialLot({ id: "L1", quantity: 10, unitCost: 10, ownerId: "thanakorn", assetId: "a-ptt" })],
        sell({ quantity: 1 }),
      ),
    ).toThrow(PostingError);
  });

  it("ล็อตขาด unitCost (ห้ามถือว่าต้นทุน 0)", () => {
    expect(() =>
      consumeFifo(
        [partialLot({ id: "L1", acquiredAt: "2025-01-01", quantity: 10, ownerId: "thanakorn", assetId: "a-ptt" })],
        sell({ quantity: 1 }),
      ),
    ).toThrow(PostingError);
  });

  it("ล็อตขาด quantity", () => {
    expect(() =>
      consumeFifo(
        [partialLot({ id: "L1", acquiredAt: "2025-01-01", unitCost: 10, ownerId: "thanakorn", assetId: "a-ptt" })],
        sell({ quantity: 1 }),
      ),
    ).toThrow(PostingError);
  });

  it("ล็อตขาด ownerId หรือ assetId → throw (กรองไม่ได้ = อาจตัดของคนอื่น)", () => {
    expect(() =>
      consumeFifo(
        [partialLot({ id: "L1", acquiredAt: "2025-01-01", quantity: 10, unitCost: 10, assetId: "a-ptt" })],
        sell({ quantity: 1 }),
      ),
    ).toThrow(PostingError);
    expect(() =>
      consumeFifo(
        [partialLot({ id: "L1", acquiredAt: "2025-01-01", quantity: 10, unitCost: 10, ownerId: "thanakorn" })],
        sell({ quantity: 1 }),
      ),
    ).toThrow(PostingError);
  });

  it("sumConsumedCost / availableQuantity ก็ต้องปฏิเสธข้อมูลขาด", () => {
    expect(() => sumConsumedCost(undefined as unknown as never)).toThrow(PostingError);
    expect(() => availableQuantity(undefined as unknown as Lot[], "thanakorn", "a-ptt")).toThrow(PostingError);
    expect(() => availableQuantity([], "", "a-ptt")).toThrow(PostingError);
  });
});

/* ------------------------------------------------------------------ *
 * เศษธุลีที่เล็กกว่าหน่วยที่เก็บได้ — ปฏิเสธ ไม่ปัดเป็น 0
 *
 * เดิมจำนวนอย่าง 1e-11 ถูก Math.round ปัดเป็น 0 หน่วยและผ่านด่าน
 * ความละเอียดไปได้ เพราะส่วนต่างเล็กกว่า epsilon ที่ตั้งไว้กันเศษ float
 * ผลคือขายเศษธุลีแล้วได้ต้นทุน 0 กำไรเท่ากับยอดขายทั้งก้อน
 * ------------------------------------------------------------------ */
describe("จำนวนที่เล็กกว่าหน่วยที่เล็กที่สุด", () => {
  it("ขายเศษธุลี 1e-11 → throw ไม่ใช่ได้กำไรเต็มยอดขายจากต้นทุน 0", () => {
    const book = [lot({ id: "L1" })];
    expect(() => consumeFifo(book, sell({ quantity: 1e-11, proceeds: 5000 }))).toThrow(PostingError);
  });

  it("ล็อตเศษธุลีในสมุด → throw ไม่ใช่หายไปพร้อมต้นทุนของมัน", () => {
    const book = [lot({ id: "L1", quantity: 1e-11 })];
    expect(() => consumeFifo(book, sell({ quantity: 1e-11, proceeds: 1 }))).toThrow(PostingError);
  });

  it("ล็อตเศษธุลีปนอยู่กับล็อตปกติของผู้ถือเดียวกัน → throw ไม่ตัดเงียบ", () => {
    const book = [lot({ id: "L1" }), lot({ id: "L2", quantity: 1e-11 })];
    expect(() => consumeFifo(book, sell({ quantity: 50, proceeds: 800 }))).toThrow(PostingError);
  });

  it("หน่วยที่เล็กที่สุดที่เก็บได้ (1e-8) ยังขายได้ปกติ", () => {
    const book = [lot({ id: "L1", quantity: 1e-8, unitCost: 100 })];
    const r = consumeFifo(book, sell({ quantity: 1e-8, proceeds: 0.01 }));
    expect(r.consumed).toHaveLength(1);
    expect(r.remaining).toHaveLength(0);
  });

  it("ล็อตเศษธุลีของผู้ถืออื่นไม่บล็อกรายการที่ถูกต้อง", () => {
    const book = [lot({ id: "L1" }), lot({ id: "L9", quantity: 1e-11, ownerId: "sutee" })];
    const r = consumeFifo(book, sell({ quantity: 100, proceeds: 1500 }));
    expect(r.totalCost).toBe(1000);
    expect(r.gain).toBe(500);
  });
});
