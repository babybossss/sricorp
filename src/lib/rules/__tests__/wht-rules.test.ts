/**
 * ภาษีหัก ณ ที่จ่าย — ฝั่ง **ตารางกฎ** (D-111 ข้อ 1)
 *
 * สองข้อที่ไฟล์นี้ตรึงไว้ และถ้าหลุดจะไม่มีอะไรฟ้องเลย:
 *   1. บัญชี 1800 **ต้องไม่ถูกจับเป็นเงินสด** — ถ้าอยู่ในช่วง 11xx งบกระแสเงินสด
 *      จะบอกว่ารับเงินเต็ม 100 ทั้งที่ธนาคารเข้าแค่ 95
 *   2. 1800 **ต้องมีทางล้าง** — เปิดให้หักภาษีได้แต่ล้างไม่ได้ = ยอดโตตลอดไป
 *      และไม่มีใครรู้ว่าเครดิตที่ขอคืนได้จริงเหลือเท่าไร (บทเรียนข้อ 7)
 */

import { describe, it, expect } from "vitest";
import {
  COA,
  WHT_COA,
  coa,
  isCashAccount,
} from "../coa";
import {
  TX_TYPES,
  accrualClearingRoutes,
  canWithholdTax,
  clearingSubsFor,
  findSub,
  whtCheck,
  whtEligibleSubs,
} from "../tx-rules";
import { findCashflowLayoutGaps, findLayoutGaps, statementOf } from "../statements";

const allSubs = TX_TYPES.flatMap((t) => t.subs);

/**
 * "ขาเครดิตเป็น **เงินได้ยอดเต็ม** หรือไม่" — เขียนเงื่อนไขซ้ำ **อย่างอิสระ** ที่นี่
 * โดยตั้งใจ (ไม่เรียก `canWithholdTax` มาเทียบกับตัวเอง ซึ่งจะผ่านฟรี)
 *
 * เงินได้มีสองรูปในสมุดของเรา:
 *   (ก) บัญชีรายได้ตรงๆ — ใบที่รับรู้รายได้พร้อมรับเงิน
 *   (ข) บัญชีค้างรับของหมวดรายได้ — ใบรับชำระลูกหนี้ที่รับรู้รายได้ยอดเต็มไปแล้ว
 *       (ค่าเช่าที่ออกใบแจ้งหนี้ไว้ ผู้เช่าจ่ายแล้วหัก 5% · ข้อ 3 ของผู้ตรวจ)
 */
function isGrossIncomeCredit(code: string): boolean {
  if (coa(code).type === "income") return true;
  return allSubs.some(
    (s) => s.accrualCoa === code && s.cashflow === "operating" && coa(s.cr).type === "income"
  );
}

describe("บัญชี 1800 ภาษีถูกหัก ณ ที่จ่ายรอเครดิต", () => {
  it("เป็นสินทรัพย์ และรหัสที่ใช้คือ 1800", () => {
    expect(WHT_COA).toBe("1800");
    expect(coa(WHT_COA).type).toBe("asset");
  });

  it("**ไม่ใช่บัญชีเงินสด** — นี่คือข้อที่ทำให้งบกระแสเงินสดไม่เพี้ยน", () => {
    expect(isCashAccount(WHT_COA)).toBe(false);
    // ไล่ซ้ำกับรูปแบบจริงของด่าน ไม่ใช่เชื่อผลของ isCashAccount เพียงอย่างเดียว
    expect(/^11\d\d$/.test(WHT_COA)).toBe(false);
  });

  it("ไม่ชนรหัสเดิมในผังบัญชี", () => {
    const codes = COA.map((a) => a.code);
    expect(new Set(codes).size, "มีรหัสซ้ำในผังบัญชี").toBe(codes.length);
    expect(codes.filter((c) => c === WHT_COA)).toHaveLength(1);
  });

  it("อยู่ในงบดุล เป็นบรรทัดของตัวเอง ไม่ยุบรวมกับลูกหนี้", () => {
    const where = statementOf(WHT_COA);
    expect(where.statement).toBe("BS");
    expect(where.group).toBe("สินทรัพย์หมุนเวียน");
    // ยุบรวมกับลูกหนี้ = จะไปโดนค่าเผื่อหนี้สงสัยจะสูญคิดด้วย
    expect(where.line).not.toBe(statementOf("1200").line);
    expect(where.line).not.toBe(statementOf("1220").line);
  });

  it("โครงงบยังครอบคลุมผังบัญชีครบ ไม่ซ้ำ ไม่เกิน", () => {
    expect(findLayoutGaps()).toEqual({ missing: [], duplicated: [], unknown: [] });
  });
});

describe("หมวดไหนถูกหักภาษี ณ ที่จ่ายได้ — คำนวณจากคู่บัญชี", () => {
  it("หมวดรายได้ที่เงินเข้าและเครดิตบัญชีรายได้ → หักได้", () => {
    for (const code of [
      "inc.rent",
      "inc.hire_purchase",
      "inc.interest_srr",
      "inc.interest_mortgage",
      "inc.interest_loan",
      "inc.dividend",
      "inc.key_money",
      "inc.fee",
    ]) {
      expect(canWithholdTax(findSub(code)!.sub), code).toBe(true);
    }
  });

  /**
   * **ข้อ 3 ของผู้ตรวจ** — ค่าเช่าที่ตั้งค้างรับไว้แล้วถูกหักภาษีตอนผู้เช่าจ่าย
   *
   * ลำดับที่เกิดจริงทุกเดือน: ออกใบแจ้งหนี้ → ตั้งลูกหนี้ค่าเช่า (รายได้ยอดเต็ม
   * รับรู้ตอนนี้) → ผู้เช่าจ่ายแล้วหัก 5% · ก่อน D-112 เส้นทางนี้ **ลงไม่ได้ทุกทาง**:
   * ตั้งค้างพร้อมหักภาษีก็ไม่ได้ (ยังไม่มีใครหัก) และตอนรับชำระก็ไม่ได้
   * (ขาเครดิตเป็นลูกหนี้ ไม่ใช่บัญชีรายได้) → เงิน 5% หายจากสมุดถาวร
   */
  it("หมวดรับชำระค้างรับของ **หมวดรายได้** → หักได้ (ค่าเช่า/ดอกเบี้ยที่ตั้งค้างไว้)", () => {
    for (const code of ["inv.collect_rent", "inv.collect_interest"]) {
      const sub = findSub(code)!.sub;
      expect(canWithholdTax(sub), code).toBe(true);
      const r = whtCheck(sub);
      expect(r.ok, code).toBe(true);
      if (r.ok) expect(r.account, code).toBe(WHT_COA);
      // ขาเครดิตเป็นลูกหนี้ (สินทรัพย์) **ไม่ใช่** บัญชีรายได้ — จึงต้องมีเส้นทางที่สอง
      expect(coa(sub.cr).type, code).toBe("asset");
      // และลูกหนี้ตัวนั้นต้องเป็นบัญชีพักของหมวดรายได้จริง (คำนวณจากตารางกฎ)
      expect(
        allSubs.some(
          (s) => s.accrualCoa === sub.cr && s.cashflow === "operating" && coa(s.cr).type === "income"
        ),
        `${code}: ${sub.cr} ต้องเป็น accrualCoa ของหมวดรายได้`
      ).toBe(true);
    }
  });

  it("หมวดที่ไม่ใช่เงินได้ → หักไม่ได้ พร้อมเหตุผลที่ชี้จุดจริง", () => {
    // รับคืนเงินต้น · รับคืนมัดจำ · ขอคืนภาษี · กู้เงินเข้า: เงินเข้าเหมือนกัน
    // แต่ไม่ใช่เงินได้ จึงไม่มีการหักภาษี ณ ที่จ่าย
    // (`inv.wht_refund` เครดิต 1800 ซึ่งเป็นสินทรัพย์เหมือนลูกหนี้ แต่ **ไม่ใช่**
    //  บัญชีพักของหมวดรายได้ใด → เส้นทางที่สองไม่รับ = ขอคืนภาษีไม่ถูกหักภาษีอีกชั้น)
    for (const code of [
      "inv.srr_redeem",
      "inv.deposit_returned",
      "inv.wht_refund",
      "fin.loan_bank",
      "fin.capital",
    ]) {
      const sub = findSub(code)!.sub;
      expect(canWithholdTax(sub), code).toBe(false);
      const r = whtCheck(sub);
      expect(r.ok, code).toBe(false);
      if (!r.ok) expect(r.why.length, code).toBeGreaterThan(10);
    }
  });

  it("ค่าใช้จ่าย · โอน · ปรับปรุงทางบัญชี → หักไม่ได้ทั้งกลุ่ม", () => {
    // เราเป็นผู้ **จ่าย** แล้วหักภาษีไว้นำส่ง = หนี้สิน คนละเรื่องกับ 1800
    // และยังไม่อยู่ในขอบเขตเฟสนี้ (D-111 พูดถึงฝั่งที่ **เราถูกหัก** เท่านั้น)
    for (const key of ["expense", "transfer", "adjust", "invest_buy"] as const) {
      const subs = TX_TYPES.find((t) => t.key === key)!.subs;
      expect(subs.length, key).toBeGreaterThan(0);
      for (const s of subs) expect(canWithholdTax(s), s.code).toBe(false);
    }
  });

  it("ทุกหมวดที่หักได้ ต้องเข้าเงื่อนไขทั้งสี่ข้อจริง (ไม่ใช่รายชื่อที่เติมมือ)", () => {
    const eligible = whtEligibleSubs();
    expect(eligible.length, "ต้องมีหมวดให้ทดสอบ").toBeGreaterThan(0);
    for (const s of eligible) {
      expect(s.cash, s.code).toBe("in");
      expect(s.cashflow, s.code).toBe("operating");
      expect(isCashAccount(s.dr), s.code).toBe(true);
      expect(isGrossIncomeCredit(s.cr), s.code).toBe(true);
      const r = whtCheck(s);
      expect(r.ok, s.code).toBe(true);
      if (r.ok) expect(r.account, s.code).toBe(WHT_COA);
    }
  });

  it("หมวดที่หักได้ต้องเครดิต **เงินได้ยอดเต็ม** เท่านั้น — ห้ามมีทางอื่นเล็ดลอด", () => {
    for (const s of allSubs) {
      if (!canWithholdTax(s)) continue;
      expect(
        isGrossIncomeCredit(s.cr),
        `${s.code} หักภาษีได้แต่เครดิต ${s.cr} ซึ่งไม่ใช่บัญชีรายได้และไม่ใช่บัญชีค้างรับของหมวดรายได้`
      ).toBe(true);
    }
  });

  it("เส้นทางที่สองต้องไม่กว้างเกิน — บัญชีสินทรัพย์ที่ไม่ใช่บัญชีพักของรายได้ ห้ามผ่าน", () => {
    // 1800 (ภาษีถูกหักรอเครดิต) · 1300 (เงินให้กู้ยืม-เงินต้น) · 1700 (เงินลงทุน)
    // เป็นสินทรัพย์เหมือนลูกหนี้ค่าเช่า แต่ **ไม่ใช่บัญชีพักของหมวดรายได้**
    // → เครดิตบัญชีพวกนี้แล้วลง 1800 ด้วยไม่ได้
    // ไม่งั้นเงินต้นที่รับคืน/ภาษีที่ขอคืน จะกลายเป็นเงินได้
    for (const code of ["1800", "1300", "1700"]) {
      expect(isGrossIncomeCredit(code), code).toBe(false);
    }
    // และ 1200/1210/1220 (ลูกหนี้ค่าเช่า/ดอกเบี้ย/อื่น) ต้องผ่าน — ไม่งั้นข้อ 3 กลับมาตัน
    // (1220 เป็นบัญชีพักของทั้งหมวดรายได้อื่นและหมวดลงทุน · ที่ทำให้หมวดหนึ่ง
    //  หักภาษีได้คือ **คู่บัญชีของหมวดนั้นเอง** ไม่ใช่บัญชีพักตัวนี้ลอยๆ
    //  วันนี้ยังไม่มีหมวดใดเครดิต 1220 เลย จึงไม่มีหมวดใดได้สิทธิ์จากข้อนี้)
    for (const code of ["1200", "1210", "1220"]) {
      expect(isGrossIncomeCredit(code), code).toBe(true);
    }
    // หมวดที่เครดิต 1220 วันนี้มีแต่ **การตัดหนี้สูญ** (ไม่มีเงินเข้า ขาเดบิตเป็น
    // ค่าใช้จ่าย) → ต้องไม่หักภาษีได้ · ข้อนี้พิสูจน์ว่าเส้นทางที่สองไม่ได้ให้สิทธิ์
    // จาก "บัญชีพักของรายได้" ลอยๆ แต่ยังบังคับทิศเงินและขาเดบิตเหมือนเดิม
    const creditors1220 = allSubs.filter((s) => s.cr === "1220");
    expect(creditors1220.length, "ต้องมีหมวดให้ทดสอบ").toBeGreaterThan(0);
    for (const s of creditors1220) {
      expect(canWithholdTax(s), `${s.code} เครดิต 1220 แต่ไม่ใช่การรับเงินได้`).toBe(false);
    }
  });
});

/**
 * บทเรียนข้อ 7 ในรูปของภาษีหัก ณ ที่จ่าย
 *
 * ถ้าไม่มีหมวดล้าง ยอดใน 1800 จะโตขึ้นทุกเดือนตลอดไป · งบดุลยังสมดุลทุกบรรทัด
 * และไม่มีอะไรฟ้อง จับได้ก็ตอนยื่นภาษีแล้วหายอดเครดิตที่ใช้ได้ไม่เจอ
 */
describe("1800 ต้องมีทางล้าง และล้างแล้วลงกระแสเงินสดหมวดเดิม", () => {
  it("มีหมวดที่ล้าง 1800 ได้จริงอย่างน้อยหนึ่งหมวด", () => {
    const routes = accrualClearingRoutes(WHT_COA).map((s) => s.code);
    expect(routes, "1800 ไม่มีหมวดสำหรับล้าง").not.toEqual([]);
    expect(routes).toContain("inv.wht_refund");
  });

  it("ทางล้างอยู่หมวดกระแสเงินสดเดียวกับหมวดที่ถูกหักภาษีไว้ (ดำเนินงาน)", () => {
    for (const s of whtEligibleSubs()) {
      expect(
        clearingSubsFor(WHT_COA, s.cashflow).map((r) => r.code),
        `${s.code} (CF ${s.cashflow}) ถูกหักภาษีไว้ แต่ทางล้าง 1800 อยู่คนละหมวด CF`
      ).not.toEqual([]);
    }
  });

  it("หมวดล้างคือขาที่ **ลด** 1800 คู่กับเงินสด ไม่ใช่ขาที่เพิ่มยอด", () => {
    const sub = findSub("inv.wht_refund")!.sub;
    expect(sub.cr, "ต้องเครดิต 1800 (ลดสินทรัพย์)").toBe(WHT_COA);
    expect(isCashAccount(sub.dr), "อีกขาต้องเป็นเงินสด").toBe(true);
    expect(sub.cashflow).toBe("operating");
    expect(sub.cash).toBe("in");
  });

  it("หมวดล้างอยู่ในโครงงบกระแสเงินสด ไม่หลุดไปบรรทัดตกหล่น", () => {
    const gaps = findCashflowLayoutGaps();
    expect(gaps.missing).toEqual([]);
    expect(gaps.duplicated).toEqual([]);
    expect(gaps.unknown).toEqual([]);
    expect(gaps.wrongSection).toEqual([]);
  });

  it("หมวดล้างไม่มีบัญชีพักของตัวเอง — ไม่งั้นล้างได้สองทางแล้วยอดติดลบ", () => {
    expect(findSub("inv.wht_refund")!.sub.accrualCoa).toBeUndefined();
  });
});
