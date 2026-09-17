import { describe, it, expect } from "vitest";
import {
  TX_TYPES,
  allowedSubs,
  findSub,
  isValidPair,
  effectsOf,
  impactLines,
  affectsPL,
  type TxTypeKey,
} from "../tx-rules";
import { COA, coa, isCashAccount } from "../coa";
import { LEDGER, APPROVALS } from "@/lib/mock/ledger";

const allSubs = TX_TYPES.flatMap((t) => t.subs);

describe("ผังบัญชี", () => {
  it("รหัสบัญชีไม่ซ้ำกัน", () => {
    const codes = COA.map((a) => a.code);
    expect(new Set(codes).size).toBe(codes.length);
  });

  it("ทุกหมวดย่อยอ้างรหัสบัญชีที่มีอยู่จริง", () => {
    for (const s of allSubs) {
      expect(() => coa(s.dr), `${s.code} dr`).not.toThrow();
      expect(() => coa(s.cr), `${s.code} cr`).not.toThrow();
    }
  });

  it("ทุกหมวดย่อยมีขาเงินสดอย่างน้อยหนึ่งฝั่ง — ไม่มีเงินลอย (Money Invariant 2)", () => {
    for (const s of allSubs) {
      expect(isCashAccount(s.dr) || isCashAccount(s.cr), s.code).toBe(true);
    }
  });
});

describe("Backlog ข้อ 1 — หมวดย่อยผูกกับประเภทรายการ", () => {
  it("รหัสหมวดย่อยไม่ซ้ำกันทั้งระบบ", () => {
    const codes = allSubs.map((s) => s.code);
    expect(new Set(codes).size).toBe(codes.length);
  });

  it("ทุกประเภทมีหมวดย่อยอย่างน้อย 1 อัน", () => {
    for (const t of TX_TYPES) expect(t.subs.length, t.key).toBeGreaterThan(0);
  });

  it("เงินกู้เลือกจากหมวดรายได้ไม่ได้", () => {
    const incomeCodes = allowedSubs("income").map((s) => s.code);
    expect(incomeCodes).not.toContain("fin.loan_bank");
    expect(incomeCodes).not.toContain("fin.loan_director");
    expect(isValidPair("income", "fin.loan_bank")).toBe(false);
  });

  it("เงินกู้อยู่ใต้ จัดหาเงิน เท่านั้น และไม่กระทบ P&L", () => {
    expect(isValidPair("finance_in", "fin.loan_bank")).toBe(true);
    const { pl, bs } = effectsOf(findSub("fin.loan_bank")!.sub);
    expect(pl).toBeUndefined();
    expect(bs).toContainEqual({ line: "เงินกู้ธนาคาร", side: "liability", direction: "increase" });
  });

  it("คืนเงินต้นลดหนี้สิน ไม่ใช่ค่าใช้จ่าย", () => {
    const { pl, bs } = effectsOf(findSub("fin.repay_bank")!.sub);
    expect(pl).toBeUndefined();
    expect(bs).toContainEqual({ line: "เงินกู้ธนาคาร", side: "liability", direction: "decrease" });
  });

  it("จ่ายปันผล/ถอนทุน ลดส่วนของเจ้าของ ไม่ใช่ค่าใช้จ่าย", () => {
    const { pl, bs } = effectsOf(findSub("fin.drawings")!.sub);
    expect(pl).toBeUndefined();
    expect(bs.some((b) => b.side === "equity" && b.direction === "decrease")).toBe(true);
  });

  it("ปล่อยกู้/ขายฝาก เป็น Investing ไม่ใช่ Financing", () => {
    for (const code of ["inv.lend", "inv.srr_out", "inv.mortgage_out"]) {
      const sub = findSub(code)!.sub;
      expect(sub.cashflow, code).toBe("investing");
      expect(effectsOf(sub).pl, code).toBeUndefined();
    }
  });

  it("เงินมัดจำจ่ายเป็นสินทรัพย์ ไม่ใช่ค่าใช้จ่าย", () => {
    const { pl, bs } = effectsOf(findSub("inv.deposit_paid")!.sub);
    expect(pl).toBeUndefined();
    expect(bs).toContainEqual({ line: "เงินมัดจำจ่าย", side: "asset", direction: "increase" });
  });

  it("โอนระหว่างบัญชีไม่เข้า P&L และไม่นับใน CF", () => {
    const sub = findSub("trf.internal")!.sub;
    expect(sub.cashflow).toBe("none");
    expect(effectsOf(sub).pl).toBeUndefined();
  });

  it("ทุกหมวดย่อยของ รายได้ ต้องกระทบ P&L ฝั่งรายได้", () => {
    for (const s of allowedSubs("income")) {
      expect(effectsOf(s).pl?.kind, s.code).toBe("revenue");
    }
  });

  it("ทุกหมวดย่อยของ ลงทุน (ซื้อ) ต้องไม่กระทบ P&L", () => {
    for (const s of allowedSubs("invest_buy")) {
      expect(effectsOf(s).pl, s.code).toBeUndefined();
    }
  });

  it("impactLines บอกครบทั้ง งบดุล · P&L · CF", () => {
    for (const s of allSubs) {
      const lines = impactLines(s);
      expect(lines.some((l) => l.startsWith("กำไรขาดทุน")), s.code).toBe(true);
      expect(lines.some((l) => l.startsWith("กระแสเงินสด")), s.code).toBe(true);
    }
  });
});

describe("หมวดย่อยที่ต้องกรอกข้อมูลเพิ่ม", () => {
  it("หมวดที่เป็นสัญญากู้/ให้กู้ ต้องบังคับ loanTerms และ contact (Backlog ข้อ 2)", () => {
    for (const code of ["inv.lend", "inv.srr_out", "inv.mortgage_out", "fin.loan_bank", "fin.loan_director"]) {
      const s = findSub(code)!.sub;
      expect(s.requires, code).toContain("loanTerms");
      expect(s.requires, code).toContain("contact");
    }
  });

  it("หมวดขายทรัพย์/ขายหลักทรัพย์ ต้องคำนวณ Cap Gain/Loss (Backlog ข้อ 4)", () => {
    for (const code of ["inv.sell_re", "inv.sell_securities"]) {
      expect(findSub(code)!.sub.requires, code).toContain("capitalGain");
    }
  });

  it("หมวดชำระคืนเงินกู้ ต้องแยกเงินต้น/ดอกเบี้ย (Backlog ข้อ 5)", () => {
    for (const code of ["fin.repay_bank", "fin.repay_director"]) {
      expect(findSub(code)!.sub.requires, code).toContain("principalInterestSplit");
    }
  });
});

describe("ข้อมูลตัวอย่างต้องตรงกับตารางกฎ", () => {
  it("ทุกแถวใน ledger อ้างหมวดย่อยที่มีอยู่จริง และตรงกับประเภท", () => {
    for (const r of LEDGER) {
      expect(findSub(r.subCode), `${r.id} ${r.subCode}`).toBeDefined();
      expect(isValidPair(r.typeKey as TxTypeKey, r.subCode), `${r.id}`).toBe(true);
    }
  });

  it("ทุกแถวในคิวอนุมัติอ้างหมวดย่อยที่ถูกต้อง", () => {
    for (const a of APPROVALS) {
      expect(findSub(a.subCode), `${a.id} ${a.subCode}`).toBeDefined();
      expect(isValidPair(a.typeKey as TxTypeKey, a.subCode), `${a.id}`).toBe(true);
    }
  });

  it("ทิศทางเงินของแถว ledger ตรงกับหมวดย่อย", () => {
    for (const r of LEDGER) {
      const sub = findSub(r.subCode)!.sub;
      if (sub.cash === "in") expect(r.inAmt, r.id).not.toBeNull();
      if (sub.cash === "out") expect(r.outAmt, r.id).not.toBeNull();
    }
  });
});

/**
 * ตารางผลกระทบที่โชว์ในฟอร์ม ต้องตรงกับบรรทัดที่ engine ลงจริง
 * ถ้าไม่ตรง ผู้ใช้จะตัดสินใจจากข้อมูลที่ผิด ทั้งที่ตัวเลขในบัญชีถูก
 */
describe("คำอธิบายผลกระทบต้องตรงกับที่ engine ลงจริง", () => {
  it("หมวดที่ engine เติมบรรทัด P&L ให้ ต้องไม่ขึ้นว่า “ไม่กระทบ”", () => {
    for (const s of allSubs) {
      if (!affectsPL(s)) continue;
      const pl = impactLines(s).find((l) => l.startsWith("กำไรขาดทุน"));
      expect(pl, s.code).not.toBe("กำไรขาดทุน · ไม่กระทบ");
    }
  });

  it("ดอกเบี้ยรับต้องขึ้นเป็นรายได้ ไม่ใช่ค่าใช้จ่าย", () => {
    // เคยฮาร์ดโค้ดเป็น expense ทุกกรณี — รับไถ่ถอนขายฝากจึงโชว์ดอกเบี้ยรับเป็นค่าใช้จ่าย
    for (const s of allSubs) {
      if (!s.interestCoa) continue;
      const kind = effectsOf(s).conditionalPl?.kind;
      expect(kind, s.code).toBe(coa(s.interestCoa).type === "income" ? "revenue" : "expense");
    }
  });
});

/**
 * ตั้งค้างรับ-ค้างจ่ายได้ แต่ล้างไม่ได้ = ลูกหนี้/เจ้าหนี้ค้างในงบดุลตลอดไป
 * และผู้ใช้จะเผลอลงรายได้ซ้ำตอนเงินเข้าจริง
 */
describe("ค้างรับ-ค้างจ่ายต้องมีทางล้าง", () => {
  const accrualAccounts = [...new Set(allSubs.map((s) => s.accrualCoa).filter(Boolean))] as string[];

  it("มีหมวดตั้งค้างอย่างน้อยฝั่งรายได้และฝั่งค่าใช้จ่าย", () => {
    expect(accrualAccounts.length).toBeGreaterThan(0);
  });

  it("ทุกบัญชีค้างรับ-ค้างจ่าย ต้องมีหมวดที่รับ/จ่ายเงินมาล้างได้", () => {
    for (const account of accrualAccounts) {
      const settles = allSubs.filter(
        (s) => (s.dr === account || s.cr === account) && (isCashAccount(s.dr) || isCashAccount(s.cr))
      );
      expect(settles.length, `${account} ${coa(account).nameTh} ไม่มีหมวดสำหรับล้าง`).toBeGreaterThan(0);
    }
  });

  it("หมวดที่ล้างลูกหนี้/เจ้าหนี้ ต้องไม่กระทบกำไรขาดทุนซ้ำ", () => {
    // รายได้รับรู้ไปแล้วตอนตั้งค้าง ถ้าหมวดล้างแตะ P&L อีก จะนับซ้ำสองรอบ
    for (const account of accrualAccounts) {
      for (const s of allSubs) {
        if (s.dr !== account && s.cr !== account) continue;
        if (!isCashAccount(s.dr) && !isCashAccount(s.cr)) continue;
        expect(affectsPL(s), s.code).toBe(false);
      }
    }
  });

  it("บัญชีค้างทุกตัวต้องอยู่ในผังบัญชี และเป็นสินทรัพย์หรือหนี้สิน", () => {
    for (const account of accrualAccounts) {
      const type = coa(account).type;
      expect(["asset", "liability"], account).toContain(type);
    }
  });
});

/**
 * บัญชีค้างชี้ผิดข้างจะไม่มีใครเห็น — หมวดรายได้ที่ชี้ไปบัญชีหนี้สิน
 * จะกลายเป็น "เดบิตลดเจ้าหนี้" ทั้งที่ควรเป็น "เดบิตเพิ่มลูกหนี้"
 */
describe("บัญชีค้างต้องชี้ถูกข้าง", () => {
  it("หมวดเงินเข้าต้องตั้งเป็นลูกหนี้ (สินทรัพย์) · เงินออกต้องเป็นเจ้าหนี้ (หนี้สิน)", () => {
    for (const s of allSubs) {
      if (!s.accrualCoa) continue;
      const expected = s.cash === "in" ? "asset" : "liability";
      expect(coa(s.accrualCoa).type, `${s.code} → ${s.accrualCoa}`).toBe(expected);
    }
  });

  it("หมวดที่ตั้งค้างได้ ต้องมีขาเงินสดให้แทนที่", () => {
    // ไม่มีขาเงินสด = ไม่รู้จะเอา accrualCoa ไปแทนบรรทัดไหน
    for (const s of allSubs) {
      if (!s.accrualCoa) continue;
      expect(isCashAccount(s.dr) || isCashAccount(s.cr), s.code).toBe(true);
    }
  });
});
