import { describe, it, expect } from "vitest";
import { buildSchedule, summarize, monthlyRate, type LoanTerms } from "../schedule";

const base: LoanTerms = {
  principal: 1_200_000,
  rate: 0.15,
  ratePeriod: "year",
  method: "flat",
  installments: 12,
  startDate: "2026-01-31",
};

describe("อัตราดอกเบี้ยต่องวด", () => {
  it("แปลงรายปีเป็นรายเดือน", () => {
    expect(monthlyRate({ rate: 0.12, ratePeriod: "year" })).toBeCloseTo(0.01, 10);
  });
  it("รายเดือนใช้ตามที่กรอก", () => {
    expect(monthlyRate({ rate: 0.0125, ratePeriod: "month" })).toBe(0.0125);
  });
});

describe("Money Invariant — เงินต้นต้องคืนครบพอดี", () => {
  for (const method of ["flat", "effective", "interest_only"] as const) {
    it(`${method}: ผลรวมเงินต้นเท่ากับเงินต้นตั้งต้น และยอดคงเหลืองวดสุดท้าย = 0`, () => {
      const rows = buildSchedule({ ...base, method });
      expect(summarize(rows).totalPrincipal).toBe(base.principal);
      expect(rows[rows.length - 1].balance).toBe(0);
    });

    it(`${method}: ทุกงวด total = เงินต้น + ดอกเบี้ย (Backlog ข้อ 5)`, () => {
      for (const r of buildSchedule({ ...base, method })) {
        expect(r.total).toBeCloseTo(r.principal + r.interest, 2);
      }
    });

    it(`${method}: ยอดคงเหลือไม่ติดลบ`, () => {
      for (const r of buildSchedule({ ...base, method })) {
        expect(r.balance).toBeGreaterThanOrEqual(0);
      }
    });
  }
});

describe("วิธีคิดดอกเบี้ย", () => {
  it("flat: ดอกเบี้ยเท่ากันทุกงวด", () => {
    const rows = buildSchedule({ ...base, method: "flat" });
    const first = rows[0].interest;
    expect(rows.every((r) => r.interest === first)).toBe(true);
    // 1,200,000 x 15%/12 = 15,000 ต่องวด
    expect(first).toBe(15_000);
  });

  it("effective: ดอกเบี้ยลดลงเรื่อยๆ ตามเงินต้นคงเหลือ", () => {
    const rows = buildSchedule({ ...base, method: "effective" });
    for (let i = 1; i < rows.length; i++) {
      expect(rows[i].interest).toBeLessThanOrEqual(rows[i - 1].interest);
    }
    // ดอกเบี้ยรวมแบบลดต้นลดดอก ต้องน้อยกว่าแบบคงที่เสมอ
    const flat = summarize(buildSchedule({ ...base, method: "flat" }));
    const eff = summarize(rows);
    expect(eff.totalInterest).toBeLessThan(flat.totalInterest);
  });

  it("interest_only: จ่ายแต่ดอกจนงวดสุดท้ายถึงคืนต้นทั้งก้อน", () => {
    const rows = buildSchedule({ ...base, method: "interest_only" });
    expect(rows.slice(0, -1).every((r) => r.principal === 0)).toBe(true);
    expect(rows[rows.length - 1].principal).toBe(base.principal);
  });

  it("ดอกเบี้ย 0% ก็ยังคืนเงินต้นครบ", () => {
    const rows = buildSchedule({ ...base, rate: 0, method: "effective" });
    expect(summarize(rows).totalInterest).toBe(0);
    expect(summarize(rows).totalPrincipal).toBe(base.principal);
  });
});

describe("วันครบกำหนด", () => {
  it("งวดแรกคือหนึ่งเดือนหลังวันรับเงิน", () => {
    const rows = buildSchedule({ ...base, startDate: "2026-01-15" });
    expect(rows[0].dueDate).toBe("2026-02-15");
  });

  it("วันที่ 31 ไม่ล้นเดือนที่สั้นกว่า", () => {
    const rows = buildSchedule({ ...base, startDate: "2026-01-31", installments: 2 });
    // ก.พ. 2026 มี 28 วัน
    expect(rows[0].dueDate).toBe("2026-02-28");
    expect(rows[1].dueDate).toBe("2026-03-31");
  });

  it("กำหนดวันชำระเองได้", () => {
    const rows = buildSchedule({ ...base, startDate: "2026-01-15", paymentDay: 5, installments: 2 });
    expect(rows[0].dueDate).toBe("2026-02-05");
    expect(rows[1].dueDate).toBe("2026-03-05");
  });
});

describe("เงื่อนไขที่รับไม่ได้", () => {
  it("เงินต้น 0 หรือติดลบ", () => {
    expect(() => buildSchedule({ ...base, principal: 0 })).toThrow();
    expect(() => buildSchedule({ ...base, principal: -1 })).toThrow();
  });
  it("จำนวนงวด 0", () => {
    expect(() => buildSchedule({ ...base, installments: 0 })).toThrow();
  });
  it("ดอกเบี้ยติดลบ", () => {
    expect(() => buildSchedule({ ...base, rate: -0.01 })).toThrow();
  });
});

describe("เคสจริงจาก Asset Management sheet", () => {
  it("ที่ดินบางกระเจ้า 10M ดอก 1.25%/เดือน จ่ายดอกอย่างเดียว = 125,000/งวด", () => {
    const rows = buildSchedule({
      principal: 10_000_000,
      rate: 0.0125,
      ratePeriod: "month",
      method: "interest_only",
      installments: 18,
      startDate: "2025-03-04",
    });
    expect(rows[0].interest).toBe(125_000);
    expect(rows[0].principal).toBe(0);
    expect(summarize(rows).totalPrincipal).toBe(10_000_000);
  });
});
