/**
 * ตีราคาทรัพย์ฝั่งลงทุน — ฝั่ง **ตารางกฎ** (D-111 ข้อ 2 · ลูกพี่ veto 24/10)
 *
 * คำสั่ง: *"จะไม่นับ Unrealized PL มาเข้ากำไรขาดทุนเด็ดขาด จะ Book PL เมื่อขายจริง
 * เท่านั้น · จะแยกไว้ก็ได้แต่เอาให้ชัดว่าไม่รวมกับ PL"*
 *
 * ไฟล์นี้ตรึงกฎนั้นไว้ **ที่ระดับโครงสร้าง** ไม่ใช่ที่ระดับ "วันนี้โค้ดทำถูก":
 * ทุกหมวดตีราคาต้องมีคู่บัญชีที่เป็น สินทรัพย์ ↔ ส่วนของเจ้าของ เท่านั้น
 * → `effectsOf()` คืน `pl: undefined` และ `affectsPL()` เป็น false **โดยไม่มีทางเลือกอื่น**
 */

import { describe, it, expect } from "vitest";
import { COA, REVALUATION_SURPLUS_COA, coa, isRevaluationSurplusAccount } from "../coa";
import {
  TX_TYPES,
  affectsPL,
  allowedSubs,
  effectsOf,
  findSub,
  impactLines,
  isRevaluationSub,
  isValidPair,
  movesCash,
  revaluableAssetCoas,
  revaluationAssetCoa,
  revaluationDirection,
  revaluationSubFor,
} from "../tx-rules";
import { findLayoutGaps, statementOf } from "../statements";

const allSubs = TX_TYPES.flatMap((t) => t.subs);
const revalueSubs = allSubs.filter(isRevaluationSub);

describe("บัญชี 3400 ส่วนเกินทุนจากการตีราคา", () => {
  it("เป็นบัญชี **ส่วนของเจ้าของ** ไม่ใช่รายได้และไม่ใช่ค่าใช้จ่าย", () => {
    expect(REVALUATION_SURPLUS_COA).toBe("3400");
    const a = coa(REVALUATION_SURPLUS_COA);
    expect(a.type).toBe("equity");
    expect(a.type).not.toBe("income");
    expect(a.type).not.toBe("expense");
  });

  it("อยู่ในงบดุลฝั่งส่วนของเจ้าของ และ **แยกบรรทัดจากกำไรสะสม**", () => {
    const where = statementOf(REVALUATION_SURPLUS_COA);
    expect(where.statement).toBe("BS");
    expect(where.group).toBe("ส่วนของเจ้าของ");
    // ปนกับกำไรสะสม = มีคนจ่ายปันผลจากกำไรที่ยังไม่ได้ขาย
    expect(where.line).not.toBe(statementOf("3300").line);
    expect(where.line).not.toBe(statementOf("3100").line);
  });

  it("ไม่ชนรหัสเดิม และโครงงบยังครบ", () => {
    const codes = COA.map((a) => a.code);
    expect(new Set(codes).size).toBe(codes.length);
    expect(findLayoutGaps()).toEqual({ missing: [], duplicated: [], unknown: [] });
  });

  it("ตัวตัดสิน isRevaluationSurplusAccount ตอบเฉพาะรหัสนี้", () => {
    expect(isRevaluationSurplusAccount("3400")).toBe(true);
    for (const code of ["3100", "3200", "3300", "1700", "1720", "4300", "5910"]) {
      expect(isRevaluationSurplusAccount(code), code).toBe(false);
    }
  });
});

describe("หมวดตีราคา — ห้ามแตะงบกำไรขาดทุนเลยแม้แต่บรรทัดเดียว", () => {
  it("มีสี่หมวด: หลักทรัพย์ขึ้น/ลง · ทองคำ-คริปโตขึ้น/ลง", () => {
    expect(revalueSubs.map((s) => s.code).sort()).toEqual([
      "adj.revalue_commodity_down",
      "adj.revalue_commodity_up",
      "adj.revalue_securities_down",
      "adj.revalue_securities_up",
    ]);
  });

  it("ทุกหมวดตีราคา affectsPL = false และไม่มีบรรทัด P&L แบบมีเงื่อนไขด้วย", () => {
    for (const s of revalueSubs) {
      const e = effectsOf(s);
      expect(affectsPL(s), `${s.code} กระทบงบกำไรขาดทุน`).toBe(false);
      expect(e.pl, `${s.code} มีบรรทัด P&L`).toBeUndefined();
      // `conditionalPl` คือช่องที่ engine เติมบรรทัดให้บางกรณี — ต้องไม่มีเช่นกัน
      expect(e.conditionalPl, `${s.code} มีบรรทัด P&L แบบมีเงื่อนไข`).toBeUndefined();
      expect(s.gainCoa, s.code).toBeUndefined();
      expect(s.lossCoa, s.code).toBeUndefined();
      expect(s.interestCoa, s.code).toBeUndefined();
    }
  });

  it("ทั้งสองขาเป็นบัญชีงบดุล (asset หรือ equity) เท่านั้น", () => {
    for (const s of revalueSubs) {
      for (const [side, code] of [["dr", s.dr], ["cr", s.cr]] as const) {
        const type = coa(code).type;
        expect(["asset", "equity"], `${s.code}.${side} = ${code} (${type})`).toContain(type);
        expect(statementOf(code).statement, `${s.code}.${side}`).toBe("BS");
      }
    }
  });

  it("ข้อความที่ผู้ใช้เห็นต้องบอกว่าไม่กระทบกำไรขาดทุน ไม่ใช่เงียบ", () => {
    for (const s of revalueSubs) {
      const lines = impactLines(s);
      expect(lines.some((l) => l.includes("กำไรขาดทุน · ไม่กระทบ")), s.code).toBe(true);
      // และต้องไม่มีบรรทัดที่บอกว่าเป็นรายได้หรือค่าใช้จ่าย
      expect(lines.some((l) => /กำไรขาดทุน · (รายได้|ค่าใช้จ่าย)/.test(l)), s.code).toBe(false);
    }
  });

  it("ไม่มีเงินเคลื่อน และไม่เข้างบกระแสเงินสด", () => {
    for (const s of revalueSubs) {
      expect(s.cash, s.code).toBe("none");
      expect(s.cashflow, s.code).toBe("none");
      expect(movesCash(s), s.code).toBe(false);
    }
  });

  it("บังคับผูกทรัพย์ — ส่วนเกินทุนที่ไม่รู้ว่าของทรัพย์ไหน ล้างตอนขายไม่ได้", () => {
    for (const s of revalueSubs) {
      expect(s.requires, s.code).toContain("asset");
      expect(s.requires, s.code).toContain("revaluation");
    }
  });

  it("เลือกจากประเภทอื่นไม่ได้ — อยู่ใต้ adjust เท่านั้น", () => {
    for (const s of revalueSubs) {
      expect(isValidPair("adjust", s.code), s.code).toBe(true);
      for (const key of ["income", "expense", "invest_buy", "invest_sell", "transfer"] as const) {
        expect(isValidPair(key, s.code), `${s.code} / ${key}`).toBe(false);
      }
    }
    expect(allowedSubs("adjust").filter(isRevaluationSub)).toHaveLength(4);
  });
});

/**
 * ธง `requires: "revaluation"` (ที่ engine ใช้แยกสาขา) กับรูปของคู่บัญชี
 * (ที่ฝั่ง SQL ใช้ตัดสินจาก `txn_types.dr/cr_coa_code`) **ต้องตอบตรงกันทุกหมวด**
 *
 * ถ้าต่างกัน: ด่านฝั่ง DB กับฝั่งโค้ดคุมหมวดคนละชุด — หมวดที่มีธงแต่ไม่แตะ 3400
 * จะถูก engine บังคับอัตราแลกเปลี่ยนแต่ DB ไม่กัน P&L ให้ · และหมวดที่แตะ 3400
 * แต่ไม่มีธงจะตกไปเส้นทางปกติที่ไม่ถามอัตราเลย
 */
describe("ธงกับคู่บัญชีต้องตรงกันทั้งสองทิศ", () => {
  it("แตะ 3400 ⇔ มีธง revaluation", () => {
    for (const s of allSubs) {
      expect(
        isRevaluationSub(s),
        `${s.code}: ธง revaluation=${!!s.requires?.includes("revaluation")} แต่แตะ 3400=${isRevaluationSub(s)}`
      ).toBe(!!s.requires?.includes("revaluation"));
    }
  });

  it("หมวดที่ไม่ใช่ตีราคา ต้องไม่มีขาไหนแตะ 3400 เลย", () => {
    for (const s of allSubs.filter((x) => !isRevaluationSub(x))) {
      expect(s.dr, s.code).not.toBe(REVALUATION_SURPLUS_COA);
      expect(s.cr, s.code).not.toBe(REVALUATION_SURPLUS_COA);
    }
  });
});

describe("ขาขึ้นกับขาลงต้องเป็นคู่กลับรายการของกันและกัน", () => {
  it("ทุกบัญชีทรัพย์ที่ตีราคาได้ มีทั้งขาขึ้นและขาลง", () => {
    const coas = revaluableAssetCoas();
    expect(coas.sort()).toEqual(["1700", "1720"]);
    for (const c of coas) {
      expect(revaluationSubFor(c, "up"), `${c} ขาขึ้น`).toBeTruthy();
      expect(revaluationSubFor(c, "down"), `${c} ขาลง`).toBeTruthy();
    }
  });

  it("dr/cr ของขาขึ้นกับขาลงสลับข้างกันเป๊ะ", () => {
    for (const c of revaluableAssetCoas()) {
      const up = revaluationSubFor(c, "up")!;
      const down = revaluationSubFor(c, "down")!;
      expect(up.dr).toBe(down.cr);
      expect(up.cr).toBe(down.dr);
      expect(up.dr).toBe(c);
      expect(up.cr).toBe(REVALUATION_SURPLUS_COA);
    }
  });

  it("ทิศและบัญชีทรัพย์อ่านออกจากคู่บัญชี ไม่ได้อ่านจากชื่อหมวด", () => {
    for (const s of revalueSubs) {
      const assetCoa = revaluationAssetCoa(s);
      expect(assetCoa).not.toBe(REVALUATION_SURPLUS_COA);
      expect(coa(assetCoa).type).toBe("asset");
      const dir = revaluationDirection(s);
      expect(dir === "up" ? s.dr : s.cr).toBe(assetCoa);
      expect(revaluationSubFor(assetCoa, dir)!.code).toBe(s.code);
    }
  });

  it("บัญชีที่ยังไม่มีหมวดตีราคา → คืน undefined ให้ผู้เรียกปฏิเสธเอง ไม่ใช่หยิบตัวแรก", () => {
    // อสังหาฯ 1500 อยู่นอกขอบเขต D-111 (ฝั่งลงทุนเท่านั้น)
    expect(revaluationSubFor("1500", "up")).toBeUndefined();
    expect(revaluationSubFor("1500", "down")).toBeUndefined();
    expect(revaluationSubFor("9999", "up")).toBeUndefined();
  });

  it("revaluationAssetCoa โยนถ้าถามหมวดที่ไม่ใช่ตีราคา — ไม่คืนค่ามั่วๆ", () => {
    expect(() => revaluationAssetCoa(findSub("inc.rent")!.sub)).toThrow();
  });
});
