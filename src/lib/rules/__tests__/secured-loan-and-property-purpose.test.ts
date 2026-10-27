/**
 * **ลูกพี่สั่ง 27/10 — แยกบัญชีสองเรื่อง**
 *
 *   1. เงินให้กู้ยืมที่มี **สินทรัพย์ค้ำประกัน** (1320) แยกจากเงินให้กู้ยืมปกติ (1300)
 *      พร้อมบัญชีดอกเบี้ยของตัวเอง (4130) เพื่อรักษารูปที่ผังนี้ใช้อยู่แล้ว:
 *      **เงินต้นหนึ่งบัญชี ↔ ดอกเบี้ยหนึ่งบัญชี** (1400→4100 · 1410→4110 · 1300→4120)
 *      ถ้า 1320 ไปใช้ 4120 ร่วมกัน จะแยกไม่ออกว่าดอกเบี้ยก้อนไหนมาจากเงินกู้ที่มี
 *      หลักประกัน ซึ่งคือเหตุผลเดียวที่ขอแยก
 *
 *   2. อสังหาริมทรัพย์เพื่อการลงทุนแยก **เพื่อการเช่า (1500)** กับ **เพื่อการขาย (1520)**
 *      และ **ย้ายข้ามวัตถุประสงค์ได้ทั้งสองทิศ** — ห้องที่ปล่อยเช่าอยู่วันหนึ่งตัดสินใจขาย
 *      ต้องย้ายได้ ไม่ใช่แยกบัญชีได้แต่ย้ายไม่ได้ (บทเรียนข้อ 7:
 *      เปิดฟีเจอร์ครึ่งเดียวอันตรายกว่าไม่เปิด)
 *
 * สิ่งที่ชุดนี้ตรึงไว้ และถ้าหลุดแล้ว **ตัวเลขผิดโดยที่ทุกใบยังสมดุล**:
 *   · ดอกเบี้ยของเงินกู้มีหลักประกันเข้า 4130 ไม่ใช่ 4120 (ทั้งขารับสดและขาไถ่ถอน)
 *   · ตั้งดอกเบี้ยค้างรับได้ **และล้างได้จริง** ในกระแสเงินสดหมวดเดียวกัน
 *   · การย้ายวัตถุประสงค์ **ไม่กระทบ P&L และไม่กระทบเงินสด** (ย้ายบัญชี ไม่ใช่ขาย)
 *   · หมวดใหม่ทุกตัวเลือกจากประเภทรายการอื่นไม่ได้
 *   · หมวดใหม่ทุกตัวมี `caution` ที่บอก **เส้นแบ่ง** ไม่ให้ลงผิดบัญชี
 */

import { describe, it, expect } from "vitest";
import {
  TX_TYPES,
  findSub,
  isValidPair,
  effectsOf,
  affectsPL,
  impactLines,
  movesCash,
  accrualCheck,
  canAccrueFromForm,
  clearingSubsFor,
  type SubCategory,
  type TxTypeKey,
} from "../tx-rules";
import { coa, isCashAccount, RETAINED_EARNINGS_COA } from "../coa";
import {
  statementOf,
  cashflowLineOf,
  findLayoutGaps,
  findCashflowLayoutGaps,
} from "../statements";
import { allCategories, classOfCoa, findAssetClassGaps } from "../asset-classes";

const sub = (code: string): SubCategory => {
  const found = findSub(code);
  expect(found, `ไม่พบหมวด ${code} ในตารางกฎ`).toBeTruthy();
  return found!.sub;
};

const ALL_TYPE_KEYS: TxTypeKey[] = TX_TYPES.map((t) => t.key);

/** หมวดนี้ต้องเลือกได้จากประเภทที่ถูก **และเลือกไม่ได้จากทุกประเภทอื่น** */
function onlyUnder(code: string, key: TxTypeKey): void {
  expect(isValidPair(key, code), `${code} ต้องเลือกได้จาก ${key}`).toBe(true);
  for (const other of ALL_TYPE_KEYS) {
    if (other === key) continue;
    expect(isValidPair(other, code), `${code} ต้องเลือกจาก ${other} ไม่ได้`).toBe(false);
  }
}

const NEW_SUBS = [
  "inc.interest_loan_secured",
  "inv.lend_secured",
  "inv.loan_back_secured",
  "opn.loan_secured_principal",
  "adj.reclass_re_to_sale",
  "adj.reclass_re_to_rental",
];

/* ================================================================== *
 * 1 · ผังบัญชี
 * ================================================================== */

describe("ผังบัญชีของสองเรื่องที่ลูกพี่สั่งแยก 27/10", () => {
  it("1320 เงินให้กู้ยืมมีหลักประกัน เป็นสินทรัพย์ และไม่ใช่บัญชีเงินสด", () => {
    expect(coa("1320").type).toBe("asset");
    expect(coa("1320").nameTh).toContain("ค้ำประกัน");
    // รหัส 11xx ถูก `isCashAccount()` จับเป็นเงินสด → ถ้าอยู่ในช่วงนั้น
    // การปล่อยกู้จะถูกนับเป็นยอดธนาคารและงบกระแสเงินสดจะวิ่งผิด
    expect(isCashAccount("1320")).toBe(false);
  });

  it("4130 ดอกเบี้ยรับเงินให้กู้ยืมมีหลักประกัน เป็นบัญชีรายได้ แยกจาก 4120", () => {
    expect(coa("4130").type).toBe("income");
    expect(coa("4130").nameTh).not.toBe(coa("4120").nameTh);
  });

  it("1500 เปลี่ยนชื่อเป็น 'เพื่อการเช่า' และ 1520 คือ 'เพื่อการขาย'", () => {
    expect(coa("1500").nameTh).toContain("เพื่อการเช่า");
    expect(coa("1520").type).toBe("asset");
    expect(coa("1520").nameTh).toContain("เพื่อการขาย");
    // ค่ารีโนเวทยังเป็นบัญชีเดียวที่ใช้ร่วมกันทั้งสองวัตถุประสงค์
    expect(coa("1510").type).toBe("asset");
  });

  it("รหัสใหม่ไม่ซ้ำกับของเดิม และโครงงบยังครอบผังบัญชีครบ ไม่ซ้ำ ไม่เกิน", () => {
    const { missing, duplicated, unknown } = findLayoutGaps();
    expect(missing, "บัญชีที่ไม่อยู่ในงบใดเลย").toEqual([]);
    expect(duplicated, "บัญชีที่อยู่สองบรรทัด").toEqual([]);
    expect(unknown, "โครงงบอ้างรหัสที่ไม่มีในผัง").toEqual([]);
  });
});

/* ================================================================== *
 * 2 · เงินให้กู้ยืมแบบมีหลักประกัน — ครบวงจร
 * ================================================================== */

describe("เงินให้กู้ยืมแบบมีหลักประกัน — ลงได้ รับคืนได้ ล้างดอกเบี้ยค้างได้", () => {
  it("ปล่อยกู้อยู่ใต้ ลงทุน (ซื้อ/ปล่อยเงิน) เท่านั้น · Dr 1320 / Cr เงินสด", () => {
    onlyUnder("inv.lend_secured", "invest_buy");
    const s = sub("inv.lend_secured");
    expect(s.dr).toBe("1320");
    expect(isCashAccount(s.cr)).toBe(true);
    expect(s.cash).toBe("out");
    // LEDGER_RULES §3 — ปล่อยกู้เป็น Investing ไม่ใช่ Financing
    expect(s.cashflow).toBe("investing");
    expect(affectsPL(s), "ปล่อยกู้ไม่ใช่ค่าใช้จ่าย").toBe(false);
    expect(s.requires).toContain("loanTerms");
    expect(s.requires).toContain("contact");
  });

  it("รับคืนเงินต้นอยู่ใต้ ลงทุน (ขาย/รับคืน) เท่านั้น · Cr 1320 และดอกเบี้ยเข้า 4130", () => {
    onlyUnder("inv.loan_back_secured", "invest_sell");
    const s = sub("inv.loan_back_secured");
    expect(isCashAccount(s.dr)).toBe(true);
    expect(s.cr).toBe("1320");
    expect(s.cash).toBe("in");
    expect(s.cashflow).toBe("investing");
    expect(s.interestCoa, "ดอกเบี้ยต้องเข้าบัญชีของเงินกู้มีหลักประกัน").toBe("4130");
    expect(s.requires).toContain("principalInterestSplit");

    // เงินต้นไม่กระทบ P&L · ดอกเบี้ยกระทบฝั่งรายได้ — ต้องพูดทั้งสองอย่าง
    const e = effectsOf(s);
    expect(e.pl, "เงินต้นที่รับคืนไม่ใช่รายได้").toBeUndefined();
    expect(e.conditionalPl?.kind).toBe("revenue");
    expect(e.conditionalPl?.line).toBe(coa("4130").nameTh);
    const plLine = impactLines(s).find((l) => l.startsWith("กำไรขาดทุน"));
    expect(plLine, "ขึ้นว่าไม่กระทบจะเข้าใจผิดว่าดอกเบี้ยไม่เข้างบ").not.toBe(
      "กำไรขาดทุน · ไม่กระทบ"
    );
  });

  it("รับดอกเบี้ยอยู่ใต้ รายได้ เท่านั้น · Cr 4130 ไม่ใช่ 4120", () => {
    onlyUnder("inc.interest_loan_secured", "income");
    const s = sub("inc.interest_loan_secured");
    expect(isCashAccount(s.dr)).toBe(true);
    expect(s.cr, "ปนกับ 4120 แล้วแยกดอกเบี้ยของเงินกู้มีหลักประกันไม่ออก").toBe("4130");
    expect(s.cash).toBe("in");
    expect(s.cashflow).toBe("operating");
    expect(effectsOf(s).pl?.kind).toBe("revenue");
    expect(effectsOf(s).pl?.line).toBe(coa("4130").nameTh);
  });

  it("เงินต้นจับคู่ดอกเบี้ยหนึ่งต่อหนึ่งครบทุกผลิตภัณฑ์ (เหตุผลเดียวที่แยก 4130)", () => {
    const PAIRS: { principal: string; interest: string; incomeSub: string; backSub: string }[] = [
      { principal: "1400", interest: "4100", incomeSub: "inc.interest_srr", backSub: "inv.srr_redeem" },
      { principal: "1410", interest: "4110", incomeSub: "inc.interest_mortgage", backSub: "inv.mortgage_redeem" },
      { principal: "1300", interest: "4120", incomeSub: "inc.interest_loan", backSub: "inv.loan_back" },
      { principal: "1320", interest: "4130", incomeSub: "inc.interest_loan_secured", backSub: "inv.loan_back_secured" },
    ];
    for (const p of PAIRS) {
      expect(sub(p.incomeSub).cr, `${p.incomeSub} ต้องเข้า ${p.interest}`).toBe(p.interest);
      expect(sub(p.backSub).cr, `${p.backSub} ต้องลด ${p.principal}`).toBe(p.principal);
      expect(sub(p.backSub).interestCoa, `${p.backSub} ดอกเบี้ยต้องเข้า ${p.interest}`).toBe(p.interest);
    }
    // ไม่มีบัญชีดอกเบี้ยตัวไหนถูกใช้ซ้ำสองผลิตภัณฑ์
    const used = PAIRS.map((p) => p.interest);
    expect(new Set(used).size).toBe(used.length);
  });

  it("ตั้งดอกเบี้ยค้างรับได้ **และมีหมวดล้างในกระแสเงินสดหมวดเดียวกัน**", () => {
    const s = sub("inc.interest_loan_secured");
    expect(s.accrualCoa, "ลูกหนี้ดอกเบี้ย").toBe("1210");
    const check = accrualCheck(s);
    expect(check.ok, check.ok ? "" : check.why).toBe(true);
    expect(canAccrueFromForm(s)).toBe(true);

    // ทางล้างต้องมีจริงและอยู่หมวด CF เดียวกัน ไม่งั้นลูกหนี้ค้างตลอดไป
    // และเงินจะไปโผล่ผิดหมวดในงบกระแสเงินสดตอนเก็บได้ (บทเรียนข้อ 7)
    const routes = clearingSubsFor("1210", "operating");
    expect(routes.map((r) => r.code)).toContain("inv.collect_interest");
    for (const r of routes) {
      expect(affectsPL(r), `${r.code} ล้างลูกหนี้ ห้ามรับรู้รายได้ซ้ำ`).toBe(false);
    }
  });

  it("เดินครบวงจร: ปล่อยกู้ → ตั้งดอกเบี้ยค้าง → ล้าง → รับคืนเงินต้น ยอด 1320/1210 กลับเป็นศูนย์", () => {
    const lend = sub("inv.lend_secured");
    const accrue = sub("inc.interest_loan_secured");
    const collect = sub("inv.collect_interest");
    const back = sub("inv.loan_back_secured");

    // เงินต้น: เดบิต 1320 ตอนปล่อย · เครดิต 1320 ตอนรับคืน → หักกันหมด
    expect(lend.dr).toBe(back.cr);
    // ดอกเบี้ยค้าง: เดบิต 1210 ตอนตั้ง (แทนขาเงินสด) · เครดิต 1210 ตอนล้าง
    expect(accrue.accrualCoa).toBe(collect.cr);
    expect(coa(collect.cr).type).toBe("asset");
    expect(isCashAccount(collect.dr)).toBe(true);
  });

  it("ยอดยกมามีของตัวเอง · Dr 1320 คู่กับกำไรสะสม ไม่เข้า P&L ไม่เข้า CF", () => {
    onlyUnder("opn.loan_secured_principal", "opening");
    const s = sub("opn.loan_secured_principal");
    expect(s.dr).toBe("1320");
    expect(s.cr).toBe(RETAINED_EARNINGS_COA);
    expect(affectsPL(s)).toBe(false);
    expect(s.cashflow).toBe("none");
    expect(movesCash(s)).toBe(false);
    expect(canAccrueFromForm(s), "ยอดยกมาไม่ใช่สิ่งที่รอรับ").toBe(false);
  });

  it("บรรทัดในงบ: 1320 อยู่งบดุลกลุ่มเงินให้กู้ · 4130 อยู่บรรทัดรายได้ดอกเบี้ย", () => {
    const bs = statementOf("1320");
    expect(bs.statement).toBe("BS");
    expect(bs.group).toBe("เงินให้กู้และลงทุนตามสัญญา");

    const pl = statementOf("4130");
    expect(pl.statement).toBe("PL");
    // รวมบรรทัดกับดอกเบี้ยตัวอื่นในงบ แต่แยกบัญชีในผัง — รายงานแยกได้ งบอ่านง่าย
    expect(pl.line).toBe(statementOf("4120").line);
  });

  it("บรรทัดในงบกระแสเงินสด: ดอกเบี้ยอยู่ดำเนินงาน · เงินต้นอยู่ลงทุน", () => {
    expect(cashflowLineOf("inc.interest_loan_secured").section).toBe("operating");
    expect(cashflowLineOf("inc.interest_loan_secured").line).toBe(
      cashflowLineOf("inc.interest_loan").line
    );
    expect(cashflowLineOf("inv.lend_secured").section).toBe("investing");
    expect(cashflowLineOf("inv.lend_secured").line).toBe(cashflowLineOf("inv.lend").line);
    expect(cashflowLineOf("inv.loan_back_secured").section).toBe("investing");
    expect(cashflowLineOf("inv.loan_back_secured").line).toBe(
      cashflowLineOf("inv.loan_back").line
    );
  });

  it("1320 อยู่ในหมวดทรัพย์ Paper Asset คู่กับ 1300 (หลักประกันไม่ใช่อสังหาฯ)", () => {
    expect(classOfCoa("1320")?.name).toBe("Paper Asset");
    const loan = allCategories().find((c) => c.code === "PAPER_LOAN")!;
    expect(loan.coaCodes).toEqual(["1300", "1320"]);
    // หลักประกันเป็นที่ดิน/สิ่งปลูกสร้างยังอยู่ RE_SRR เหมือนเดิม
    expect(classOfCoa("1400")?.name).toBe("Real Estate");
  });
});

/* ================================================================== *
 * 3 · อสังหาฯ เพื่อการลงทุน แยกเช่า/ขาย + ย้ายวัตถุประสงค์
 * ================================================================== */

describe("อสังหาฯ เพื่อการลงทุน — แยกเช่า/ขาย และย้ายได้ทั้งสองทิศ", () => {
  const RECLASS = ["adj.reclass_re_to_sale", "adj.reclass_re_to_rental"];

  it("ทั้งสองทิศอยู่ใต้ ปรับปรุงทางบัญชี เท่านั้น", () => {
    // อยู่กลุ่ม "ปรับปรุงทางบัญชี" เพราะ **ไม่มีเงินเคลื่อนเลย** ซึ่งเป็นนิยามของกลุ่มนั้น
    // (กลุ่มโอนระหว่างบัญชีมีขาเงินสดและต้องผูกบัญชีธนาคาร)
    for (const code of RECLASS) onlyUnder(code, "adjust");
  });

  it("ย้ายเช่า→ขาย และ ขาย→เช่า เป็นคู่กลับรายการของกันและกันเป๊ะ", () => {
    const toSale = sub("adj.reclass_re_to_sale");
    const toRental = sub("adj.reclass_re_to_rental");
    expect(toSale.dr).toBe("1520");
    expect(toSale.cr).toBe("1500");
    // ขาดข้างใดข้างหนึ่ง = ย้ายไปแล้วย้ายกลับไม่ได้ (เปิดฟีเจอร์ครึ่งเดียว)
    expect(toRental.dr).toBe(toSale.cr);
    expect(toRental.cr).toBe(toSale.dr);
  });

  it("**ไม่กระทบงบกำไรขาดทุน** — ย้ายบัญชีไม่ใช่การขาย จึงไม่มีกำไรเกิดขึ้น", () => {
    for (const code of RECLASS) {
      const s = sub(code);
      expect(affectsPL(s), `${code} ต้องไม่แตะ P&L`).toBe(false);
      expect(effectsOf(s).pl, code).toBeUndefined();
      expect(effectsOf(s).conditionalPl, code).toBeUndefined();
      expect(impactLines(s).find((l) => l.startsWith("กำไรขาดทุน"))).toBe("กำไรขาดทุน · ไม่กระทบ");
      // ห้ามมีบัญชีกำไร/ขาดทุนหรือดอกเบี้ย = ห้ามตีราคาใหม่ในใบเดียวกัน
      expect(s.gainCoa, code).toBeUndefined();
      expect(s.lossCoa, code).toBeUndefined();
      expect(s.interestCoa, code).toBeUndefined();
    }
  });

  it("**ไม่กระทบเงินสด** — ไม่มีขาเงินสด ไม่อยู่ในงบกระแสเงินสดเลย", () => {
    for (const code of RECLASS) {
      const s = sub(code);
      expect(s.cash, code).toBe("none");
      expect(s.cashflow, code).toBe("none");
      expect(movesCash(s), code).toBe(false);
      expect(isCashAccount(s.dr) || isCashAccount(s.cr), code).toBe(false);
      // หมวดที่ cashflow = none ต้องไม่อยู่ในโครงงบกระแสเงินสด ไม่งั้นยอดถูกนับเป็นกระแสเงินสด
      expect(() => cashflowLineOf(code), code).toThrow();
    }
  });

  it("ทั้งสองขาอยู่ในสินทรัพย์ ข้างหนึ่งเพิ่มข้างหนึ่งลด (งบดุลไม่เปลี่ยนยอดรวม)", () => {
    for (const code of RECLASS) {
      const { bs } = effectsOf(sub(code));
      expect(bs.length, code).toBe(2);
      expect(bs.every((b) => b.side === "asset"), code).toBe(true);
      expect(bs.filter((b) => b.direction === "increase").length, code).toBe(1);
      expect(bs.filter((b) => b.direction === "decrease").length, code).toBe(1);
    }
  });

  it("ตั้งค้างรับ/ค้างจ่ายไม่ได้ (ไม่มีเงินรอรับรอจ่าย) และต้องผูกทรัพย์", () => {
    for (const code of RECLASS) {
      const s = sub(code);
      expect(s.accrualCoa, code).toBeUndefined();
      expect(canAccrueFromForm(s), code).toBe(false);
      const check = accrualCheck(s);
      expect(check.ok).toBe(false);
      if (!check.ok) expect(check.reason).toBe("noCashMovement");
      // ย้ายทรัพย์ชิ้นไหนต้องรู้ ไม่งั้นต้นทุนรายชิ้นแยกไม่ออกหลังย้าย
      expect(s.requires, code).toContain("asset");
    }
  });

  it("บรรทัดในงบดุล: เพื่อการเช่ากับเพื่อการขายแยกบรรทัดกัน ค่ารีโนเวทอยู่กับฝั่งเช่า", () => {
    const rental = statementOf("1500");
    const forSale = statementOf("1520");
    const renov = statementOf("1510");
    expect(rental.statement).toBe("BS");
    expect(forSale.statement).toBe("BS");
    // กลุ่มเดียวกัน (อสังหาฯ เพื่อการลงทุน) แต่คนละบรรทัด — อ่านงบออกว่าของไหนรอขาย
    expect(forSale.group).toBe(rental.group);
    expect(forSale.line).not.toBe(rental.line);
    expect(renov.group).toBe(rental.group);
  });

  it("หมวดทรัพย์: RE_FOR_SALE มีบัญชีของตัวเองแล้ว · RE_RENTAL ไม่เปลี่ยน", () => {
    const forSale = allCategories().find((c) => c.code === "RE_FOR_SALE")!;
    const rental = allCategories().find((c) => c.code === "RE_RENTAL")!;
    expect(forSale.coaCodes, "เดิมเป็น [] = ของรอขายไม่มีบัญชีของตัวเอง").toEqual(["1520"]);
    expect(rental.coaCodes).toEqual(["1500", "1510"]);
    expect(classOfCoa("1520")?.name).toBe("Real Estate");
  });

  it("การจับคู่บัญชีกับหมวดทรัพย์ยังครบ ไม่ซ้ำ ไม่ขัดกันเอง", () => {
    const { missing, duplicated, unknown, bothWays } = findAssetClassGaps();
    expect(missing, "บัญชีสินทรัพย์ที่ยังไม่ได้จัดหมวด").toEqual([]);
    expect(duplicated, "บัญชีที่อยู่สองหมวด = ยอดถูกนับซ้ำในมุมมองประเภทการลงทุน").toEqual([]);
    expect(unknown).toEqual([]);
    expect(bothWays).toEqual([]);
  });
});

/* ================================================================== *
 * 4 · คำเตือนของหมวดใหม่ — เส้นแบ่งต้องอยู่ในตารางกฎ ไม่ใช่ในหัวคน
 * ================================================================== */

describe("ทุกหมวดใหม่มี caution ที่บอกเส้นแบ่ง", () => {
  it("มี caution ครบทุกหมวด และไม่ใช่ข้อความว่าง", () => {
    for (const code of NEW_SUBS) {
      const c = sub(code).caution;
      expect(c, `${code} ไม่มี caution — หมวดที่ลงผิดง่ายต้องมีคำเตือนในตารางกฎ`).toBeTruthy();
      expect((c ?? "").trim().length, code).toBeGreaterThan(20);
    }
  });

  it("หมวดของเงินกู้มีหลักประกัน เตือนเส้นแบ่ง 'หลักประกันเป็นที่ดิน → ขายฝาก/จำนอง'", () => {
    for (const code of ["inv.lend_secured", "inv.loan_back_secured", "inc.interest_loan_secured"]) {
      const c = sub(code).caution ?? "";
      expect(c, `${code} ต้องบอกว่าหลักประกันเป็นอสังหาฯ ให้ใช้บัญชีอื่น`).toMatch(/ที่ดิน/);
      expect(c, `${code} ต้องชี้ไปที่ขายฝาก/จำนอง`).toMatch(/ขายฝาก|จำนอง/);
    }
  });

  it("หมวดย้ายวัตถุประสงค์ เตือนว่า 'ไม่ใช่การขาย · ไม่มีกำไร · ต้นทุนเดิม'", () => {
    for (const code of ["adj.reclass_re_to_sale", "adj.reclass_re_to_rental"]) {
      const c = sub(code).caution ?? "";
      expect(c, `${code} ต้องบอกว่าไม่ใช่การขาย`).toMatch(/ไม่ใช่การขาย/);
      expect(c, `${code} ต้องบอกว่าไม่มีกำไรเกิดขึ้น`).toMatch(/กำไร/);
      expect(c, `${code} ต้องบอกว่าย้ายด้วยต้นทุนเดิม`).toMatch(/ต้นทุนเดิม/);
    }
  });
});

/* ================================================================== *
 * 5 · โครงงบกระแสเงินสดยังไม่มีช่องว่างหลังเพิ่มหมวดใหม่
 * ================================================================== */

describe("โครงงบกระแสเงินสดครอบหมวดใหม่ครบ", () => {
  it("ไม่มีหมวดตกหล่น ไม่ซ้ำ ไม่เกิน และไม่มีหมวดอยู่ผิดส่วน", () => {
    const g = findCashflowLayoutGaps();
    expect(g.missing, "หมวดที่เข้างบ CF ได้แต่โครงงบไม่มี → ยอดหายเงียบๆ").toEqual([]);
    expect(g.duplicated, "หมวดที่อยู่สองบรรทัด → ยอดถูกนับซ้ำ").toEqual([]);
    expect(g.unknown).toEqual([]);
    expect(g.wrongSection, "หมวดที่อยู่ผิดส่วน → กระแสเงินสดดำเนินงานผิด").toEqual([]);
    expect(g.missingLegs).toEqual([]);
    expect(g.duplicatedLegs).toEqual([]);
    expect(g.wrongSectionLegs).toEqual([]);
  });
});
