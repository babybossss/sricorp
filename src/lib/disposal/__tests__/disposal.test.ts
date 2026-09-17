import { describe, it, expect } from "vitest";
import { computeDisposal } from "../capital-gain";
import { splitRepayment } from "../repayment";
import { buildSchedule } from "@/lib/loan/schedule";
import { buildPosting, allLines, totalDebit, totalCredit } from "@/lib/ledger/posting";

/**
 * บรรทัดบัญชีไม่ได้สร้างในไฟล์ `lib/disposal/` แล้ว — engine เดียวคือ `lib/ledger/posting.ts`
 * เทสต์ด้านล่างจึงยิงผ่าน `buildPosting()` เพื่อยืนยันว่าตัวเลขจากเครื่องคิดเลข
 * ไปโผล่ในบรรทัดบัญชีจริงถูกที่ ไม่ใช่แค่ถูกในฟังก์ชันที่ไม่มีใครเรียก
 */
const owner = { ownerId: "thanakorn", bankAccountId: "b4" };

/** ขายอสังหาฯ: ยอดเงินของรายการ = ราคาขาย − ค่าใช้จ่ายในการขาย */
function sellRealEstate(d: { costBasis: number; salePrice: number; sellingCosts?: number }) {
  const r = computeDisposal(d);
  return allLines(
    buildPosting({
      ...owner,
      typeKey: "invest_sell" as const,
      subCode: "inv.sell_re",
      amount: r.netProceeds,
      assetId: "rent1",
      disposal: d,
    })
  );
}

/** ชำระคืนเงินกู้ธนาคาร: เงินต้น + ดอกเบี้ย = ยอดที่จ่าย */
function repayBankLoan(split: { principal: number; interest: number }) {
  return allLines(
    buildPosting({
      ...owner,
      typeKey: "finance_out" as const,
      subCode: "fin.repay_bank",
      amount: Math.round((split.principal + split.interest) * 100) / 100,
      contactId: "c3",
      repayment: split,
    })
  );
}

describe("Backlog ข้อ 4 — กำไร/ขาดทุนจากการขาย", () => {
  it("ขายได้กำไร: กำไร = เงินสุทธิ − ต้นทุน", () => {
    const r = computeDisposal({ costBasis: 2_450_000, salePrice: 3_000_000, sellingCosts: 50_000 });
    expect(r.netProceeds).toBe(2_950_000);
    expect(r.capitalGain).toBe(500_000);
    expect(r.isGain).toBe(true);
  });

  it("ขายขาดทุน: กำไรติดลบ", () => {
    const r = computeDisposal({ costBasis: 2_450_000, salePrice: 2_000_000, sellingCosts: 30_000 });
    expect(r.capitalGain).toBe(-480_000);
    expect(r.isGain).toBe(false);
  });

  it("ค่าใช้จ่ายในการขายลดกำไร ไม่ใช่ลดต้นทุน", () => {
    const noCost = computeDisposal({ costBasis: 1_000_000, salePrice: 1_200_000 });
    const withCost = computeDisposal({ costBasis: 1_000_000, salePrice: 1_200_000, sellingCosts: 50_000 });
    expect(withCost.costBasis).toBe(noCost.costBasis);
    expect(withCost.capitalGain).toBe(noCost.capitalGain - 50_000);
  });

  it("ขายเท่าทุนพอดี กำไรเป็นศูนย์", () => {
    expect(computeDisposal({ costBasis: 500_000, salePrice: 500_000 }).capitalGain).toBe(0);
  });

  it("บอกกำไรยังไม่รับรู้ที่ต้องล้างออกพร้อมกัน", () => {
    const r = computeDisposal({
      costBasis: 2_450_000,
      salePrice: 3_000_000,
      unrealizedGain: 330_000,
    });
    expect(r.unrealizedToReverse).toBe(330_000);
  });

  it("ตัดทรัพย์ออกตามต้นทุน ไม่ใช่ราคาขาย", () => {
    const lines = sellRealEstate({ costBasis: 2_450_000, salePrice: 3_000_000 });
    const assetLine = lines.find((l) => l.coaCode === "1500")!;
    expect(assetLine.credit).toBe(2_450_000);
  });

  it("บรรทัดบัญชีสมดุลเสมอ ทั้งกรณีกำไรและขาดทุน", () => {
    for (const salePrice of [3_000_000, 2_450_000, 1_800_000]) {
      const lines = sellRealEstate({ costBasis: 2_450_000, salePrice, sellingCosts: 20_000 });
      expect(totalDebit(lines), `ราคาขาย ${salePrice}`).toBe(totalCredit(lines));
    }
  });

  it("กำไรเข้า 4300 · ขาดทุนเข้า 5900", () => {
    const gain = sellRealEstate({ costBasis: 1_000_000, salePrice: 1_500_000 });
    expect(gain.some((l) => l.coaCode === "4300" && l.credit === 500_000)).toBe(true);

    const loss = sellRealEstate({ costBasis: 1_000_000, salePrice: 600_000 });
    expect(loss.some((l) => l.coaCode === "5900" && l.debit === 400_000)).toBe(true);
  });

  it("ยอดเงินของรายการต้องเท่ากับเงินสุทธิ ไม่ใช่ราคาขายเต็ม", () => {
    // ถ้ากรอกราคาขายเต็มลงช่องจำนวนเงิน เงินสดจะเข้าเกินจริงเท่าค่าธรรมเนียม
    expect(() =>
      buildPosting({
        ...owner,
        typeKey: "invest_sell",
        subCode: "inv.sell_re",
        amount: 3_000_000,
        assetId: "rent1",
        disposal: { costBasis: 2_450_000, salePrice: 3_000_000, sellingCosts: 50_000 },
      })
    ).toThrow(/ราคาขาย − ค่าใช้จ่ายในการขาย/);
  });

  it("ค่าติดลบรับไม่ได้", () => {
    expect(() => computeDisposal({ costBasis: -1, salePrice: 100 })).toThrow();
    expect(() => computeDisposal({ costBasis: 100, salePrice: -1 })).toThrow();
    expect(() => computeDisposal({ costBasis: 100, salePrice: 100, sellingCosts: -1 })).toThrow();
  });
});

describe("Backlog ข้อ 5 — แยกเงินต้น/ดอกเบี้ย", () => {
  const schedule = buildSchedule({
    principal: 1_200_000,
    rate: 0.12,
    ratePeriod: "year",
    method: "effective",
    installments: 12,
    startDate: "2026-01-31",
  });
  const first = schedule[0];

  it("จ่ายตรงงวด ใช้ตัวเลขจากตารางงวด", () => {
    const s = splitRepayment({ amountPaid: first.total, installment: first });
    expect(s.source).toBe("schedule");
    expect(s.principal).toBe(first.principal);
    expect(s.interest).toBe(first.interest);
    expect(s.isPartial).toBe(false);
  });

  it("จ่ายน้อยกว่างวด ตัดดอกเบี้ยก่อน ที่เหลือเป็นเงินต้น", () => {
    const paid = first.interest + 1_000;
    const s = splitRepayment({ amountPaid: paid, installment: first });
    expect(s.interest).toBe(first.interest);
    expect(s.principal).toBe(1_000);
    expect(s.isPartial).toBe(true);
    expect(s.note).toContain("จ่ายน้อยกว่างวด");
  });

  it("จ่ายน้อยกว่าดอกเบี้ยด้วยซ้ำ เงินต้นเป็นศูนย์", () => {
    const s = splitRepayment({ amountPaid: 100, installment: first });
    expect(s.interest).toBe(100);
    expect(s.principal).toBe(0);
  });

  it("จ่ายเกินงวด ส่วนเกินตัดเป็นเงินต้น", () => {
    const s = splitRepayment({ amountPaid: first.total + 5_000, installment: first });
    expect(s.interest).toBe(first.interest);
    expect(s.principal).toBe(first.principal + 5_000);
    expect(s.note).toContain("จ่ายเกินงวด");
  });

  it("ผู้ใช้ระบุเองได้ แต่ต้องรวมกันเท่ายอดที่จ่าย", () => {
    const s = splitRepayment({ amountPaid: 10_000, manualPrincipal: 7_000, manualInterest: 3_000 });
    expect(s.source).toBe("manual");
    expect(s.principal).toBe(7_000);

    expect(() =>
      splitRepayment({ amountPaid: 10_000, manualPrincipal: 7_000, manualInterest: 999 })
    ).toThrow(/ต้องเท่ากับยอดที่จ่าย/);
  });

  it("ไม่มีตารางงวดและไม่ระบุเอง ต้องไม่เดา", () => {
    expect(() => splitRepayment({ amountPaid: 10_000 })).toThrow(/ต้องระบุเงินต้นและดอกเบี้ยเอง/);
  });

  it("ทุกกรณี เงินต้น + ดอกเบี้ย = ยอดที่จ่ายเสมอ", () => {
    for (const paid of [100, first.interest, first.total, first.total + 5_000]) {
      const s = splitRepayment({ amountPaid: paid, installment: first });
      expect(s.principal + s.interest, `จ่าย ${paid}`).toBeCloseTo(paid, 2);
    }
  });

  it("เงินต้นลดหนี้สิน ดอกเบี้ยเป็นค่าใช้จ่าย ไม่ปนกัน", () => {
    const s = splitRepayment({ amountPaid: first.total, installment: first });
    const lines = repayBankLoan(s);

    const liability = lines.find((l) => l.coaCode === "2410")!;
    expect(liability.debit).toBe(s.principal);

    const interestLine = lines.find((l) => l.coaCode === "5400")!;
    expect(interestLine.debit).toBe(s.interest);

    // เงินต้นต้องไม่โผล่ในบรรทัดค่าใช้จ่าย
    expect(interestLine.debit).not.toBe(s.total);
  });

  it("บรรทัดบัญชีของการคืนเงินกู้สมดุล", () => {
    for (const paid of [first.interest, first.total, first.total + 1_000]) {
      const s = splitRepayment({ amountPaid: paid, installment: first });
      const lines = repayBankLoan(s);
      expect(totalDebit(lines), `จ่าย ${paid}`).toBe(totalCredit(lines));
    }
  });

  it("ยอดจ่าย 0 หรือติดลบรับไม่ได้", () => {
    expect(() => splitRepayment({ amountPaid: 0, installment: first })).toThrow();
    expect(() => splitRepayment({ amountPaid: -1, installment: first })).toThrow();
  });
});
