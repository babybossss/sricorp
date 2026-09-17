import { describe, it, expect } from "vitest";
import { buildPosting, assertBalanced, totalDebit, totalCredit, allLines } from "../posting";
import { PostingError } from "../types";
import { isCashAccount } from "@/lib/rules/coa";
import { TX_TYPES, findSub } from "@/lib/rules/tx-rules";

const base = {
  amount: 12000,
  ownerId: "thanakorn",
  bankAccountId: "b4",
};

describe("Money Invariant 1 — ทุกรายการต้องสมดุล", () => {
  it("ทุกหมวดย่อยในตารางกฎ สร้างบรรทัดที่สมดุลได้", () => {
    for (const t of TX_TYPES) {
      for (const s of t.subs) {
        const input = {
          ...base,
          typeKey: t.key,
          subCode: s.code,
          assetId: "rent1",
          contactId: "c1",
          // เคสพิเศษที่ต้องมีข้อมูลเพิ่ม
          disposal: s.requires?.includes("capitalGain")
            ? { costBasis: 10000, salePrice: 12000 }
            : undefined,
          repayment: s.requires?.includes("principalInterestSplit")
            ? { principal: 9000, interest: 3000 }
            : undefined,
          transferToBankAccountId: t.key === "transfer" ? "b4b" : undefined,
        };
        const r = buildPosting(input);
        expect(totalDebit(allLines(r)), `${s.code} debit=credit`).toBe(totalCredit(allLines(r)));
        expect(allLines(r).length, `${s.code} ต้องมีอย่างน้อย 2 บรรทัด`).toBeGreaterThanOrEqual(2);
      }
    }
  });
});

describe("Money Invariant 2 — ไม่มีเงินลอย", () => {
  it("ทุกบรรทัดเงินสดต้องผูกบัญชีธนาคาร", () => {
    for (const t of TX_TYPES) {
      for (const s of t.subs) {
        const r = buildPosting({
          ...base,
          typeKey: t.key,
          subCode: s.code,
          assetId: "rent1",
          contactId: "c1",
          disposal: s.requires?.includes("capitalGain") ? { costBasis: 10000, salePrice: 12000 } : undefined,
          repayment: s.requires?.includes("principalInterestSplit") ? { principal: 9000, interest: 3000 } : undefined,
          transferToBankAccountId: t.key === "transfer" ? "b4b" : undefined,
        });
        for (const l of allLines(r)) {
          if (isCashAccount(l.coaCode)) {
            expect(l.bankAccountId, `${s.code} บรรทัด ${l.coaCode}`).toBeTruthy();
          }
        }
      }
    }
  });
});

describe("รายการธรรมดาสองบรรทัด", () => {
  it("ค่าเช่า: เงินสดเดบิต · รายได้ค่าเช่าเครดิต", () => {
    const r = buildPosting({ ...base, typeKey: "income", subCode: "inc.rent", assetId: "rent1", contactId: "c1" });
    expect(allLines(r)).toHaveLength(2);
    const cash = allLines(r).find((l) => l.coaCode === "1100")!;
    const rent = allLines(r).find((l) => l.coaCode === "4200")!;
    expect(cash.debit).toBe(12000);
    expect(cash.bankAccountId).toBe("b4");
    expect(rent.credit).toBe(12000);
  });

  it("ค่าซ่อม: ค่าใช้จ่ายเดบิต · เงินสดเครดิต", () => {
    const r = buildPosting({ ...base, typeKey: "expense", subCode: "exp.repair", assetId: "rent1" });
    expect(allLines(r).find((l) => l.coaCode === "5120")!.debit).toBe(12000);
    expect(allLines(r).find((l) => l.coaCode === "1100")!.credit).toBe(12000);
  });

  it("กู้เงินธนาคาร: เงินสดเดบิต · หนี้สินเครดิต และไม่แตะ P&L", () => {
    const r = buildPosting({ ...base, typeKey: "finance_in", subCode: "fin.loan_bank", contactId: "c3" });
    expect(allLines(r).find((l) => l.coaCode === "1100")!.debit).toBe(12000);
    expect(allLines(r).find((l) => l.coaCode === "2410")!.credit).toBe(12000);
    // ไม่มีบรรทัดรายได้เลย
    expect(allLines(r).some((l) => l.coaCode.startsWith("4"))).toBe(false);
  });

  it("ปล่อยกู้: ลูกหนี้เดบิต ไม่ใช่ค่าใช้จ่าย", () => {
    const r = buildPosting({ ...base, typeKey: "invest_buy", subCode: "inv.lend", contactId: "c4" });
    expect(allLines(r).find((l) => l.coaCode === "1300")!.debit).toBe(12000);
    expect(allLines(r).some((l) => l.coaCode.startsWith("5"))).toBe(false);
  });
});

describe("Backlog ข้อ 4 — ขายทรัพย์สามบรรทัด", () => {
  it("ขายได้กำไร: ตัดทรัพย์ตามต้นทุน · เงินเข้าตามราคาขาย · กำไรเข้า 4300", () => {
    const r = buildPosting({
      ...base,
      typeKey: "invest_sell",
      subCode: "inv.sell_re",
      assetId: "rent1",
      amount: 3_000_000,
      disposal: { costBasis: 2_450_000, salePrice: 3_000_000 },
    });
    assertBalanced(allLines(r));
    expect(allLines(r).find((l) => l.coaCode === "1500")!.credit).toBe(2_450_000);
    expect(allLines(r).find((l) => l.coaCode === "1100")!.debit).toBe(3_000_000);
    expect(allLines(r).find((l) => l.coaCode === "4300")!.credit).toBe(550_000);
  });

  it("ขายขาดทุน: ขาดทุนเข้า 5900 ฝั่งเดบิต", () => {
    const r = buildPosting({
      ...base,
      typeKey: "invest_sell",
      subCode: "inv.sell_re",
      assetId: "rent1",
      amount: 2_000_000,
      disposal: { costBasis: 2_450_000, salePrice: 2_000_000 },
    });
    assertBalanced(allLines(r));
    expect(allLines(r).find((l) => l.coaCode === "5900")!.debit).toBe(450_000);
  });

  it("ค่าใช้จ่ายในการขายลดเงินที่เข้าบัญชี และลดกำไร", () => {
    const r = buildPosting({
      ...base,
      typeKey: "invest_sell",
      subCode: "inv.sell_re",
      assetId: "rent1",
      amount: 2_950_000,
      disposal: { costBasis: 2_450_000, salePrice: 3_000_000, sellingCosts: 50_000 },
    });
    assertBalanced(allLines(r));
    expect(allLines(r).find((l) => l.coaCode === "1100")!.debit).toBe(2_950_000);
    expect(allLines(r).find((l) => l.coaCode === "4300")!.credit).toBe(500_000);
  });

  it("ขายเท่าทุน ไม่มีบรรทัดกำไรหรือขาดทุน", () => {
    const r = buildPosting({
      ...base,
      typeKey: "invest_sell",
      subCode: "inv.sell_re",
      assetId: "rent1",
      amount: 2_450_000,
      disposal: { costBasis: 2_450_000, salePrice: 2_450_000 },
    });
    expect(allLines(r)).toHaveLength(2);
    expect(allLines(r).some((l) => l.coaCode === "4300" || l.coaCode === "5900")).toBe(false);
  });

  it("ทรัพย์ทุกบรรทัดผูก assetId เพื่อคำนวณต้นทุนย้อนหลังได้", () => {
    const r = buildPosting({
      ...base,
      typeKey: "invest_sell",
      subCode: "inv.sell_re",
      assetId: "rent1",
      amount: 3_000_000,
      disposal: { costBasis: 2_450_000, salePrice: 3_000_000 },
    });
    expect(allLines(r).find((l) => l.coaCode === "1500")!.assetId).toBe("rent1");
  });
});

describe("Backlog ข้อ 5 — คืนเงินกู้สามบรรทัด", () => {
  it("เงินต้นลดหนี้สิน · ดอกเบี้ยเป็นค่าใช้จ่าย · เงินสดออกเต็มจำนวน", () => {
    const r = buildPosting({
      ...base,
      typeKey: "finance_out",
      subCode: "fin.repay_bank",
      contactId: "c3",
      amount: 50_000,
      repayment: { principal: 40_000, interest: 10_000 },
    });
    assertBalanced(allLines(r));
    expect(allLines(r).find((l) => l.coaCode === "2410")!.debit).toBe(40_000);
    expect(allLines(r).find((l) => l.coaCode === "5400")!.debit).toBe(10_000);
    expect(allLines(r).find((l) => l.coaCode === "1100")!.credit).toBe(50_000);
  });

  it("จ่ายดอกอย่างเดียว ไม่มีบรรทัดหนี้สิน", () => {
    const r = buildPosting({
      ...base,
      typeKey: "finance_out",
      subCode: "fin.repay_bank",
      contactId: "c3",
      amount: 10_000,
      repayment: { principal: 0, interest: 10_000 },
    });
    expect(allLines(r)).toHaveLength(2);
    expect(allLines(r).some((l) => l.coaCode === "2410")).toBe(false);
  });

  it("เงินต้น + ดอกเบี้ย ต้องเท่ายอดที่จ่าย ไม่งั้นปฏิเสธ", () => {
    expect(() =>
      buildPosting({
        ...base,
        typeKey: "finance_out",
        subCode: "fin.repay_bank",
        contactId: "c3",
        amount: 50_000,
        repayment: { principal: 40_000, interest: 5_000 },
      })
    ).toThrow(PostingError);
  });
});

describe("โอนระหว่างบัญชี — สองขาเสมอ (Money Invariant 3)", () => {
  it("เงินออกจากบัญชีต้นทาง เข้าบัญชีปลายทาง", () => {
    const r = buildPosting({
      ...base,
      typeKey: "transfer",
      subCode: "trf.internal",
      amount: 20_000,
      transferToBankAccountId: "b4b",
    });
    assertBalanced(allLines(r));
    expect(allLines(r)).toHaveLength(2);
    const out = allLines(r).find((l) => l.credit > 0)!;
    const inn = allLines(r).find((l) => l.debit > 0)!;
    expect(out.bankAccountId).toBe("b4");
    expect(inn.bankAccountId).toBe("b4b");
  });

  it("ไม่ระบุบัญชีปลายทาง = ปฏิเสธ ไม่สร้างขาเดียว", () => {
    expect(() =>
      buildPosting({ ...base, typeKey: "transfer", subCode: "trf.internal", amount: 20_000 })
    ).toThrow(/ปลายทาง/);
  });

  it("โอนเข้าบัญชีเดิม = ปฏิเสธ", () => {
    expect(() =>
      buildPosting({
        ...base,
        typeKey: "transfer",
        subCode: "trf.internal",
        amount: 20_000,
        transferToBankAccountId: "b4",
      })
    ).toThrow(/บัญชีเดียวกัน/);
  });

  it("โอนภายในไม่เข้า P&L", () => {
    const r = buildPosting({
      ...base,
      typeKey: "transfer",
      subCode: "trf.internal",
      amount: 20_000,
      transferToBankAccountId: "b4b",
    });
    expect(allLines(r).every((l) => isCashAccount(l.coaCode))).toBe(true);
  });
});

describe("กันรายการที่ DB จะปฏิเสธอยู่ดี", () => {
  it("หมวดย่อยไม่ตรงกับประเภท", () => {
    expect(() =>
      buildPosting({ ...base, typeKey: "income", subCode: "fin.loan_bank" })
    ).toThrow(/ไม่อยู่ใต้ประเภท/);
  });

  it("หมวดย่อยไม่มีอยู่จริง", () => {
    expect(() => buildPosting({ ...base, typeKey: "income", subCode: "inc.ไม่มี" })).toThrow();
  });

  it("จำนวนเงินต้องมากกว่า 0", () => {
    expect(() => buildPosting({ ...base, amount: 0, typeKey: "income", subCode: "inc.rent", assetId: "rent1", contactId: "c1" })).toThrow(/มากกว่า 0/);
    expect(() => buildPosting({ ...base, amount: -1, typeKey: "income", subCode: "inc.rent", assetId: "rent1", contactId: "c1" })).toThrow();
  });

  it("ต้องระบุบัญชีธนาคารเสมอ", () => {
    expect(() =>
      buildPosting({ ...base, bankAccountId: "", typeKey: "income", subCode: "inc.rent", assetId: "rent1", contactId: "c1" })
    ).toThrow(/บัญชี/);
  });

  it("หมวดที่บังคับผูกทรัพย์ ถ้าไม่ผูกต้องปฏิเสธ", () => {
    expect(() =>
      buildPosting({ ...base, typeKey: "income", subCode: "inc.rent", contactId: "c1" })
    ).toThrow(/ทรัพย์/);
  });

  it("หมวดที่บังคับผู้ติดต่อ ถ้าไม่ระบุต้องปฏิเสธ", () => {
    expect(() =>
      buildPosting({ ...base, typeKey: "finance_in", subCode: "fin.loan_bank" })
    ).toThrow(/ผู้ติดต่อ/);
  });
});

describe("คำอธิบายภาษาคน", () => {
  it("บอกว่าระบบลงบัญชีให้อย่างไร", () => {
    const r = buildPosting({ ...base, typeKey: "income", subCode: "inc.rent", assetId: "rent1", contactId: "c1" });
    expect(r.summary.length).toBeGreaterThan(0);
    expect(r.summary.join(" ")).toContain(findSub("inc.rent")!.sub.plain);
  });
});

/**
 * เส้นทางที่ mace-windu ชี้ว่าเทสต์ชุดแรกไม่เคยแตะ
 * ทุกเคสในนี้เคยผ่านเข้าไปได้แล้วลงบัญชีผิด ก่อนจะถูกแก้
 */
describe("เส้นทางที่เคยหลุด — ข้อมูลไม่ครบต้องถูกปฏิเสธ ไม่ใช่เดาให้", () => {
  it("คืนเงินกู้โดยไม่ระบุการแยกเงินต้น/ดอกเบี้ย ต้องถูกปฏิเสธ", () => {
    // เคยตกไปเส้นทางปกติ → ลงเงินต้นเต็ม 50,000 ดอกเบี้ยหายจาก P&L
    expect(() =>
      buildPosting({
        ...base,
        typeKey: "finance_out",
        subCode: "fin.repay_bank",
        contactId: "c3",
        amount: 50_000,
      })
    ).toThrow(/แยกเงินต้น/);
  });

  it("ขายทรัพย์โดยไม่ระบุต้นทุน ต้องถูกปฏิเสธ", () => {
    // เคยตัดทรัพย์ด้วยราคาขายแทนต้นทุน และไม่รับรู้กำไรเลย
    expect(() =>
      buildPosting({
        ...base,
        typeKey: "invest_sell",
        subCode: "inv.sell_re",
        assetId: "rent1",
        amount: 3_000_000,
      })
    ).toThrow(/ต้นทุนและราคาขาย/);
  });

  it("ยอดหัวรายการต้องตรงกับเงินที่เข้าบัญชีจริง", () => {
    // amount ที่ไม่ตรงกับ salePrice − sellingCosts ทำให้กระทบยอดธนาคารพัง
    expect(() =>
      buildPosting({
        ...base,
        typeKey: "invest_sell",
        subCode: "inv.sell_re",
        assetId: "rent1",
        amount: 1,
        disposal: { costBasis: 2_450_000, salePrice: 3_000_000 },
      })
    ).toThrow(/ยอดที่รับจริง/);
  });

  it("ค่าใช้จ่ายในการขายมากกว่าราคาขาย ต้องถูกปฏิเสธ", () => {
    // เคยได้บรรทัดเงินสดติดลบ ซึ่ง DB มี check (debit >= 0) ปฏิเสธอยู่แล้ว
    expect(() =>
      buildPosting({
        ...base,
        typeKey: "invest_sell",
        subCode: "inv.sell_re",
        assetId: "rent1",
        amount: 0,
        disposal: { costBasis: 1000, salePrice: 600, sellingCosts: 1000 },
      })
    ).toThrow();
  });

  it("กำไรขายหลักทรัพย์ต้องไม่ไปโผล่บรรทัดกำไรขายอสังหาฯ", () => {
    const re = buildPosting({
      ...base,
      typeKey: "invest_sell",
      subCode: "inv.sell_re",
      assetId: "rent1",
      amount: 120,
      disposal: { costBasis: 100, salePrice: 120 },
    });
    const sec = buildPosting({
      ...base,
      typeKey: "invest_sell",
      subCode: "inv.sell_securities",
      amount: 120,
      disposal: { costBasis: 100, salePrice: 120 },
    });
    expect(allLines(re).some((l) => l.coaCode === "4300")).toBe(true);
    expect(allLines(sec).some((l) => l.coaCode === "4300")).toBe(false);
    expect(allLines(sec).some((l) => l.coaCode === "4900")).toBe(true);
  });
});

describe("โอนข้าม owner ต้องระบุลักษณะ (Money Invariant 3)", () => {
  it("โอนภายในผู้ถือเดียวกัน ได้รายการเดียวสองบรรทัด", () => {
    // b4 และ b4b เป็นของธนากรทั้งคู่
    const r = buildPosting({
      ...base,
      typeKey: "transfer",
      subCode: "trf.internal",
      amount: 20_000,
      transferToBankAccountId: "b4b",
    });
    expect(r.transactions).toHaveLength(1);
    assertBalanced(allLines(r));
  });

  it("โอนข้ามผู้ถือโดยไม่ระบุลักษณะ ต้องถูกปฏิเสธ", () => {
    expect(() =>
      buildPosting({
        ...base,
        typeKey: "transfer",
        subCode: "trf.internal",
        amount: 20_000,
        transferToBankAccountId: "b1",
        })
    ).toThrow(/ลักษณะ/);
  });

  it("โอนข้ามผู้ถือได้สองรายการคู่กัน ฝ่ายละหนึ่ง", () => {
    const r = buildPosting({
      ...base,
      typeKey: "transfer",
      subCode: "trf.internal",
      amount: 20_000,
      transferToBankAccountId: "b1",
      intercompanyNature: "loan",
    });
    expect(r.transactions).toHaveLength(2);
    // แต่ละรายการต้องสมดุลในตัวเอง เพราะ DB ตรวจต่อ transaction
    for (const t of r.transactions) assertBalanced(t.lines);
    expect(r.transactions[0].ownerId).toBe("thanakorn");
    expect(r.transactions[1].ownerId).toBe("corp");
    expect(r.summary.join(" ")).toMatch(/ข้ามผู้ถือ/);
  });

  it("ผู้ถือปลายทางอ่านจากบัญชีเอง ไม่เชื่อสิ่งที่ผู้ใช้เว้นได้", () => {
    // b1 เป็นของ SRI Corporation — ต้องรู้เองว่าข้ามผู้ถือ แม้ไม่มีฟิลด์บอก
    expect(() =>
      buildPosting({
        ...base,
        typeKey: "transfer",
        subCode: "trf.internal",
        amount: 20_000,
        transferToBankAccountId: "b1",
      })
    ).toThrow(/ข้ามผู้ถือ/);
  });

  it("ปันผลข้ามผู้ถือ: ฝ่ายจ่ายลดส่วนของเจ้าของ ฝ่ายรับได้รายได้", () => {
    const r = buildPosting({
      ownerId: "corp",
      bankAccountId: "b1",
      typeKey: "transfer",
      subCode: "trf.internal",
      amount: 100_000,
      transferToBankAccountId: "b4",
      intercompanyNature: "dividend",
      attachments: ["slip.pdf"],
      contactId: "c1",
    });
    const payer = r.transactions.find((t) => t.ownerId === "corp")!;
    const receiver = r.transactions.find((t) => t.ownerId === "thanakorn")!;
    // 3200 เงินถอนของเจ้าของ — ปันผลลดส่วนของเจ้าของ ไม่ใช่ค่าใช้จ่าย
    expect(payer.lines.find((l) => l.coaCode === "3200")!.debit).toBe(100_000);
    expect(payer.lines.some((l) => l.coaCode.startsWith("5"))).toBe(false);
    expect(receiver.lines.find((l) => l.coaCode === "4410")!.credit).toBe(100_000);
  });
});

describe("Corporate strict — ดักก่อนให้ผู้ใช้เห็นข้อความที่เข้าใจได้", () => {
  it("ฝั่งบริษัทไม่แนบหลักฐาน ต้องเตือนตั้งแต่ก่อนส่ง", () => {
    expect(() =>
      buildPosting({
        ...base,
        ownerId: "corp",
        bankAccountId: "b1",
        typeKey: "income",
        subCode: "inc.rent",
        assetId: "rent1",
        contactId: "c1",
        attachments: [],
      })
    ).toThrow(/หลักฐาน/);
  });

  it("ฝั่งบริษัทแนบหลักฐานแล้ว ผ่าน", () => {
    const r = buildPosting({
      ...base,
      ownerId: "corp",
      bankAccountId: "b1",
      typeKey: "income",
      subCode: "inc.rent",
      assetId: "rent1",
      contactId: "c1",
      attachments: ["slip.pdf"],
    });
    assertBalanced(allLines(r));
  });

  it("ฝั่งบุคคลไม่แนบหลักฐานได้ (personal_flexible)", () => {
    const r = buildPosting({
      ...base,
      ownerId: "thanakorn",
      typeKey: "income",
      subCode: "inc.rent",
      assetId: "rent1",
      contactId: "c1",
    });
    assertBalanced(allLines(r));
  });
});
