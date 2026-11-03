import { describe, expect, it } from "vitest";
import { checkWeights, microToPercent } from "../weights";

const tags = (...ids: string[]) => ids.map((id) => ({ id, nameTh: `P-${id}` }));
const msgs = (r: ReturnType<typeof checkWeights>) => (r.ok ? [] : r.issues.map((i) => i.message)).join(" | ");

describe("checkWeights · Σ ต้อง = 1.000000 พอดี", () => {
  it.each([
    ["60/40", { a: 0.6, b: 0.4 }],
    ["อันเดียว 100%", { a: 1 }],
    ["0.999999 + 0.000001", { a: 0.999999, b: 0.000001 }],
    ["1/3 ในหกตำแหน่ง", { a: 0.333333, b: 0.333333, c: 0.333334 }],
    ["เจ็ดทาง", { a: 0.142857, b: 0.142857, c: 0.142857, d: 0.142857, e: 0.142857, f: 0.142857, g: 0.142858 }],
    ["0.1 + 0.2 + 0.7 (ผลรวม float ไม่ใช่ 1 แต่ทศนิยมแม่นตรงใช่)", { a: 0.1, b: 0.2, c: 0.7 }],
  ])("%s → ผ่าน", (_n, w) => {
    const r = checkWeights(tags(...Object.keys(w)), w);
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.weights.entries.reduce((s, e) => s + e.micro, BigInt(0))).toBe(BigInt(1_000_000));
  });

  it("ขาด 0.000001 → ปฏิเสธ ไม่มี tolerance และบอกว่าขาดเท่าไร", () => {
    const r = checkWeights(tags("a", "b"), { a: 0.6, b: 0.399999 });
    expect(r.ok).toBe(false);
    expect(msgs(r)).toMatch(/ขาดอีก 0\.0001%/);
    expect(msgs(r)).toMatch(/P-a 60%.*P-b 39\.9999%/); // รายชื่อ tag พร้อมน้ำหนักปัจจุบัน (ADR 4.1)
  });

  it("เกิน 0.000001 → ปฏิเสธ และบอกว่าเกินเท่าไร", () => {
    const r = checkWeights(tags("a", "b"), { a: 0.6, b: 0.400001 });
    expect(r.ok).toBe(false);
    expect(msgs(r)).toMatch(/เกินอยู่ 0\.0001%/);
    if (!r.ok) expect(r.diffMicro).toBe(BigInt(-1));
  });

  it("ขาดมาก / เกินมาก", () => {
    expect(msgs(checkWeights(tags("a", "b"), { a: 0.5, b: 0.3 }))).toMatch(/ขาดอีก 20%/);
    expect(msgs(checkWeights(tags("a", "b"), { a: 0.7, b: 0.5 }))).toMatch(/เกินอยู่ 20%/);
  });

  it("1/3 สามตัวเท่ากันเป๊ะ (0.333333 ×3) ไม่ผ่าน — ระบบไม่แจกเศษให้เอง", () => {
    const r = checkWeights(tags("a", "b", "c"), { a: 0.333333, b: 0.333333, c: 0.333333 });
    expect(r.ok).toBe(false);
    expect(msgs(r)).toMatch(/ขาดอีก 0\.0001%/);
  });
});

describe("checkWeights · ข้อมูลไม่ครบต้องปฏิเสธ ไม่ตกไปเส้นทางปกติ", () => {
  it.each([[undefined], [null], [{}]])("ไม่ส่งน้ำหนักมาเลย (%j) → ปฏิเสธทุก tag แม้มี tag เดียว", (w) => {
    for (const ids of [["a"], ["a", "b"]]) {
      const r = checkWeights(tags(...ids), w as never);
      expect(r.ok).toBe(false);
      if (!r.ok) expect(r.issues.filter((i) => i.code === "missing").map((i) => i.tagId)).toEqual(ids);
    }
  });

  it("ส่งมาไม่ครบ (tag b ไม่มีน้ำหนัก) → ปฏิเสธ ไม่เติมเศษให้ b", () => {
    const r = checkWeights(tags("a", "b"), { a: 0.6 });
    expect(r.ok).toBe(false);
    expect(msgs(r)).toMatch(/P-b.*ยังไม่ได้ใส่สัดส่วน/);
  });

  it("น้ำหนักเป็น null ของ tag หนึ่ง → ปฏิเสธ", () => {
    expect(checkWeights(tags("a", "b"), { a: 0.6, b: null }).ok).toBe(false);
  });

  it("ไม่มี tag เลย → ปฏิเสธ (ไม่ใช่ Σ ของเซตว่างที่บังเอิญผ่าน)", () => {
    const r = checkWeights([], {});
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.issues[0].code).toBe("no_tags");
  });

  it("น้ำหนักที่ไม่มี tag รองรับ → ปฏิเสธ แม้ Σ ของที่เหลือ = 1", () => {
    const r = checkWeights(tags("a"), { a: 1, ghost: 0.5 });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.issues.map((i) => i.code)).toContain("orphan");
  });
});

describe("checkWeights · 0 < weight <= 1", () => {
  it("น้ำหนัก 0 → ปฏิเสธ พร้อมบอกให้เอา tag ออก", () => {
    const r = checkWeights(tags("a", "b"), { a: 1, b: 0 });
    expect(r.ok).toBe(false);
    expect(msgs(r)).toMatch(/0 ไม่ได้.*เอา tag ออก/);
  });
  it("น้ำหนัก > 1 → ปฏิเสธ (ทั้ง 1.000001 และ 2)", () => {
    for (const x of [1.000001, 2]) {
      const r = checkWeights(tags("a"), { a: x });
      expect(r.ok).toBe(false);
      if (!r.ok) expect(r.issues[0].code).toBe("over_one");
    }
  });
  it("ติดลบ → ปฏิเสธ", () => {
    const r = checkWeights(tags("a", "b"), { a: -0.5, b: 1.5 });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.issues.map((i) => i.code)).toEqual(expect.arrayContaining(["negative", "over_one"]));
  });
  it("ทศนิยมเกิน 6 ตำแหน่ง → ปฏิเสธ ไม่ปัดให้ (0.3333333 / 1e-7 / 0.1+0.2)", () => {
    for (const x of [0.3333333, 0.0000001, 0.1 + 0.2]) {
      const r = checkWeights(tags("a"), { a: x });
      expect(r.ok, String(x)).toBe(false);
      if (!r.ok) expect(r.issues[0].code, String(x)).toMatch(/too_precise|not_number/);
    }
    const r = checkWeights(tags("a"), { a: 0.3333333 });
    if (!r.ok) expect(r.issues[0].code).toBe("too_precise");
  });
  it.each([["0.6"], [Number.NaN], [Number.POSITIVE_INFINITY], [true], [{}]])("ไม่ใช่ตัวเลข (%j) → ปฏิเสธ", (x) => {
    const r = checkWeights(tags("a"), { a: x });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.issues[0].code).toBe("not_number");
  });
});

describe("microToPercent", () => {
  it.each([
    [1_000_000, "100%"],
    [600_000, "60%"],
    [333_333, "33.3333%"],
    [1, "0.0001%"],
    [-1, "-0.0001%"],
    [0, "0%"],
  ])("%s → %s", (n, s) => expect(microToPercent(BigInt(n))).toBe(s));
});
