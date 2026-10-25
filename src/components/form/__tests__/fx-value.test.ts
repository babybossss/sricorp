import { describe, expect, it } from "vitest";
import { EMPTY_FX, datesForRate, fxChoiceOf, parseUnits } from "../fx-value";

describe("parseUnits · จำนวนเงินตราจากช่องพิมพ์ — อ่านไม่ออกคือ undefined ไม่ใช่ 0", () => {
  it.each([
    ["10000", 10000],
    ["10,000", 10000],
    [" 4000.5 ", 4000.5],
    ["0.000001", 0.000001],
  ])("%s → %s", (s, n) => expect(parseUnits(s)).toBe(n));

  it.each(["", " ", "abc", "-5", "1e3", "1.1234567", "1.2.3", "10,00,0x", "(100)", "−100"])("%j → undefined (ไม่เดา)", (s) => {
    expect(parseUnits(s)).toBeUndefined();
  });
});

describe("fxChoiceOf · ฟอร์ม → สิ่งที่ผู้ใช้เลือก (ไม่มีตัวเลขอัตรา ไม่มียอดคงเหลือ)", () => {
  it("ฟอร์มเปล่า → ไม่มีอะไรเลย (ไม่ส่ง 0 หรือสตริงว่างไปแทนค่าที่ไม่ได้เลือก)", () => {
    expect(fxChoiceOf(EMPTY_FX)).toEqual({});
  });
  it("แปลงค่า → มีเฉพาะวันของอัตรา", () => {
    expect(fxChoiceOf({ ...EMPTY_FX, newRateDate: "2026-11-30" })).toEqual({ newRateDate: "2026-11-30" });
  });
  it("แลกเงิน → วันของอัตรา + จำนวนที่แลก · จำนวนที่อ่านไม่ออกไม่ถูกส่ง", () => {
    expect(fxChoiceOf({ newRateDate: "", dealRateDate: "2026-12-31", amountOriginal: "4,000" })).toEqual({ dealRateDate: "2026-12-31", amountOriginal: 4000 });
    expect(fxChoiceOf({ newRateDate: "", dealRateDate: "2026-12-31", amountOriginal: "สี่พัน" })).toEqual({ dealRateDate: "2026-12-31" });
  });
  it("ผลลัพธ์มีได้แค่สามช่องที่ server รับ — ไม่มีช่องอื่นหลุดไปกับคำขอ", () => {
    const keys = Object.keys(fxChoiceOf({ newRateDate: "2026-11-30", dealRateDate: "2026-12-31", amountOriginal: "1" })).sort();
    expect(keys).toEqual(["amountOriginal", "dealRateDate", "newRateDate"]);
  });
});

describe("datesForRate · เลือกอัตราแล้วตั้งวันที่เอกสาร/วันที่เงินเคลื่อนให้เป็นวันของอัตรา", () => {
  it("2026-11-30 → 30/11/2026 ทั้งสองช่อง (ปี ค.ศ. ตามที่ฟอร์มอ่านได้)", () => {
    expect(datesForRate("2026-11-30")).toEqual({ docDate: "30/11/2026", cashDate: "30/11/2026" });
  });
  it("ยังไม่เลือก / วันที่ไม่มีจริง → null (ไม่ทับวันที่ที่ผู้ใช้กรอกไว้)", () => {
    expect(datesForRate("")).toBeNull();
    expect(datesForRate("2026-02-30")).toBeNull();
  });
});
