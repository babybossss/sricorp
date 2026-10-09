import { describe, it, expect } from "vitest";
import {
  TX_TYPES,
  allowedSubs,
  canAccrueFromForm,
  accrualCheck,
  effectsOf,
  affectsPL,
  findSub,
  impactLines,
  isValidPair,
  movesCash,
  cashDirectionLabel,
  type SubCategory,
} from "../tx-rules";
import { COA, coa, isCashAccount } from "../coa";
import { BS_LAYOUT, PL_LAYOUT, cfSubCodes, findCashflowLayoutGaps, findLayoutGaps, statementOf } from "../statements";

const allSubs = TX_TYPES.flatMap((t) => t.subs);
const sub = (code: string): SubCategory => {
  const found = findSub(code);
  expect(found, `ไม่พบหมวด ${code} ในตารางกฎ`).toBeTruthy();
  return found!.sub;
};

/** ห้าหมวดของประเภท "ปรับปรุงทางบัญชี" — เขียนชื่อตรงๆ เพื่อให้การถอดหมวดเห็นใน diff */
const ADJ_CODES = [
  "adj.doubtful",
  "adj.doubtful_release",
  "adj.writeoff_rent",
  "adj.writeoff_interest",
  "adj.writeoff_other",
];

const WRITEOFF_CODES = ["adj.writeoff_rent", "adj.writeoff_interest", "adj.writeoff_other"];

/* ================================================================== *
 * ส่วนที่ 1 · CashDirection "none" — รูปแบบใหม่ที่ระบบไม่เคยเจอ
 * ================================================================== */

describe("CashDirection รับค่า none ได้ และหมายความว่าไม่มีขาเงินสดเลย", () => {
  it("movesCash ตรงกับคู่บัญชีจริงทุกหมวด — ธงกับบัญชีห้ามขัดกัน", () => {
    // ธง `cash` ที่ไม่ตรงกับคู่บัญชี = ฟอร์มถามบัญชีธนาคารกับรายการที่ไม่มีขาเงินสด
    // (หรือแย่กว่า: ไม่ถามกับรายการที่มี แล้วเงินลอย — Money Invariant 2)
    for (const s of allSubs) {
      expect(movesCash(s), `${s.code} (cash: ${s.cash})`).toBe(isCashAccount(s.dr) || isCashAccount(s.cr));
    }
  });

  it("หมวดที่ cash: none ต้องไม่มีขาเงินสดทั้งสองฝั่ง", () => {
    for (const code of ADJ_CODES) {
      const s = sub(code);
      expect(s.cash, code).toBe("none");
      expect(isCashAccount(s.dr), `${code} dr`).toBe(false);
      expect(isCashAccount(s.cr), `${code} cr`).toBe(false);
    }
  });

  it("ทุกหมวดที่เงินเคลื่อน ยังต้องมีขาเงินสดอยู่ (Money Invariant 2 ไม่ได้ถูกผ่อน)", () => {
    const moving = allSubs.filter(movesCash);
    expect(moving.length, "ต้องมีหมวดที่เงินเคลื่อนให้ตรวจ").toBeGreaterThan(0);
    for (const s of moving) {
      expect(isCashAccount(s.dr) || isCashAccount(s.cr), s.code).toBe(true);
    }
  });

  it("ป้ายทิศทางเงินมีคำตอบของ none โดยเฉพาะ ไม่ใช่ตกไปเป็นคำของ both", () => {
    expect(cashDirectionLabel("none")).not.toBe(cashDirectionLabel("both"));
    expect(cashDirectionLabel("none")).toContain("ไม่มีเงินเคลื่อน");
  });
});

/* ================================================================== *
 * ส่วนที่ 2 · ประเภทรายการใหม่ + บัญชีใหม่
 * ================================================================== */

describe("ประเภทรายการ ปรับปรุงทางบัญชี (ไม่มีเงินเคลื่อน)", () => {
  const type = TX_TYPES.find((t) => t.key === "adjust");

  it("มีประเภทใหม่ และทั้งประเภทเป็น cash: none", () => {
    expect(type, "ยังไม่มีประเภท adjust ในตารางกฎ").toBeTruthy();
    expect(type!.cash).toBe("none");
  });

  it("มีห้าหมวดครบตามที่ตัดสินไว้ ไม่ขาดไม่เกิน", () => {
    expect(allowedSubs("adjust").map((s) => s.code).sort()).toEqual([...ADJ_CODES].sort());
  });

  it("ห้าหมวดนี้เลือกจากประเภทอื่นไม่ได้ — ห้ามยัดลงประเภทค่าใช้จ่ายเดิม", () => {
    for (const code of ADJ_CODES) {
      expect(isValidPair("adjust", code), code).toBe(true);
      expect(isValidPair("expense", code), code).toBe(false);
      expect(isValidPair("income", code), code).toBe(false);
      expect(isValidPair("transfer", code), code).toBe(false);
    }
  });

  it("ประเภทค่าใช้จ่ายเดิมยังเป็น cash: out — เหตุผลที่ต้องแยกประเภทใหม่", () => {
    expect(TX_TYPES.find((t) => t.key === "expense")!.cash).toBe("out");
  });

  it("ทุกหมวดบังคับ contact — ต้องรู้ว่าเป็นหนี้ของใคร", () => {
    for (const code of ADJ_CODES) expect(sub(code).requires, code).toContain("contact");
  });

  it("หมวดตัดหนี้สูญมี caution เตือนเรื่องค่าใช้จ่ายซ้ำ", () => {
    for (const code of WRITEOFF_CODES) {
      expect(sub(code).caution, code).toBeTruthy();
      expect(sub(code).caution!, code).toMatch(/ค่าเผื่อ/);
    }
  });

  it("ตั้งค้างรับ-ค้างจ่ายไม่ได้ และเหตุผลต้องพูดถึงการไม่มีเงินเคลื่อน ไม่ใช่ 'ไม่ได้ระบุบัญชี'", () => {
    for (const code of ADJ_CODES) {
      const s = sub(code);
      expect(canAccrueFromForm(s), code).toBe(false);
      const check = accrualCheck(s);
      expect(check.ok, code).toBe(false);
      if (check.ok) return;
      expect(check.reason, code).toBe("noCashMovement");
      expect(check.why, code).toMatch(/ไม่มีเงินเคลื่อน/);
    }
  });
});

describe("บัญชีใหม่สองรหัส", () => {
  it("1290 ค่าเผื่อหนี้สงสัยจะสูญ เป็นสินทรัพย์ (contra) และไม่ใช่บัญชีเงินสด", () => {
    const a = coa("1290");
    expect(a.type).toBe("asset");
    expect(isCashAccount("1290"), "1290 ต้องไม่ถูกนับเป็นเงินสด ไม่งั้นงบกระแสเงินสดจะวิ่ง").toBe(false);
  });

  it("5920 หนี้สงสัยจะสูญ เป็นค่าใช้จ่าย", () => {
    expect(coa("5920").type).toBe("expense");
  });

  it("1290 อยู่ใต้กลุ่มลูกหนี้ในงบดุล และเป็นบรรทัด contra (หัก)", () => {
    const where = statementOf("1290");
    expect(where.statement).toBe("BS");
    expect(where.group).toBe(statementOf("1200").group);
    const line = BS_LAYOUT.flatMap((g) => g.lines).find((l) => l.codes.includes("1290"))!;
    expect(line.contra, "ค่าเผื่อที่ไม่ใช่ contra = ลูกหนี้สุทธิบวกเพิ่มทั้งที่ควรหัก").toBe(true);
  });

  it("5920 อยู่ในงบกำไรขาดทุนฝั่งค่าใช้จ่าย แยกบรรทัดของตัวเอง", () => {
    const where = statementOf("5920");
    expect(where.statement).toBe("PL");
    const section = PL_LAYOUT.find((s) => s.lines.some((l) => l.codes.includes("5920")))!;
    expect(section.kind).toBe("expense");
    // ปนกับ "ค่าใช้จ่ายอื่น" แล้วอ่านงบไม่ออกว่าตั้งค่าเผื่อไปเท่าไร
    expect(where.line).not.toBe(statementOf("5900").line);
  });

  it("โครงงบยังครอบคลุมผังบัญชีครบ ไม่ซ้ำ ไม่เกิน หลังเพิ่มสองรหัส", () => {
    expect(findLayoutGaps()).toEqual({ missing: [], duplicated: [], unknown: [] });
    expect(COA.filter((a) => a.code === "1290" || a.code === "5920")).toHaveLength(2);
  });
});

/* ================================================================== *
 * คู่บัญชี — หัวใจของเรื่อง "ค่าใช้จ่ายห้ามซ้ำ"
 * ================================================================== */

describe("คู่บัญชีของการตั้งค่าเผื่อ / กลับค่าเผื่อ / ตัดหนี้สูญ", () => {
  it("ตั้งค่าเผื่อ Dr 5920 / Cr 1290 — ค่าใช้จ่ายรับรู้ตอนนี้ครั้งเดียว", () => {
    const s = sub("adj.doubtful");
    expect(s.dr).toBe("5920");
    expect(s.cr).toBe("1290");
    const { pl, bs } = effectsOf(s);
    expect(pl).toEqual({ line: coa("5920").nameTh, kind: "expense" });
    // เครดิต contra-asset = สินทรัพย์รวมลด = ลูกหนี้สุทธิลด
    expect(bs).toContainEqual({ line: coa("1290").nameTh, side: "asset", direction: "decrease" });
  });

  it("กลับค่าเผื่อ Dr 1290 / Cr 5920 — เป็นคู่ตรงข้ามของการตั้งเป๊ะๆ", () => {
    const set = sub("adj.doubtful");
    const rel = sub("adj.doubtful_release");
    expect(rel.dr).toBe(set.cr);
    expect(rel.cr).toBe(set.dr);
  });

  it("มีหมวดกลับค่าเผื่ออยู่จริง — ตั้งได้ต้องล้างได้ (บทเรียนข้อ 7)", () => {
    // ค่าเผื่อที่ตั้งได้แต่ลดไม่ได้ = ลูกหนี้ถูกกดต่ำตลอดกาล
    const release = allowedSubs("adjust").filter((s) => s.dr === "1290" && s.cr === "5920");
    expect(release.map((s) => s.code), "ไม่มีหมวดที่กลับค่าเผื่อ (Dr 1290 / Cr 5920)").toEqual([
      "adj.doubtful_release",
    ]);
  });

  it("ตัดหนี้สูญหักที่ 1290 ไม่แตะ P&L — ถ้าลง 5920 อีกรอบ = ค่าใช้จ่ายซ้ำสองเท่า", () => {
    for (const code of WRITEOFF_CODES) {
      const s = sub(code);
      expect(s.dr, `${code} ต้องเดบิต 1290 (ล้างค่าเผื่อ)`).toBe("1290");
      expect([s.dr, s.cr], `${code} ห้ามแตะ 5920`).not.toContain("5920");
      expect(affectsPL(s), `${code} แตะ P&L = ค่าใช้จ่ายซ้ำ`).toBe(false);
      expect(effectsOf(s).pl, code).toBeUndefined();
      expect(effectsOf(s).conditionalPl, code).toBeUndefined();
      expect(impactLines(s), code).toContain("กำไรขาดทุน · ไม่กระทบ");
    }
  });

  it("ตัดหนี้สูญเครดิตบัญชีลูกหนี้ของมันเอง ครบทั้งสามตัวและไม่ซ้ำ", () => {
    expect(sub("adj.writeoff_rent").cr).toBe("1200");
    expect(sub("adj.writeoff_interest").cr).toBe("1210");
    expect(sub("adj.writeoff_other").cr).toBe("1220");
    const crs = WRITEOFF_CODES.map((c) => sub(c).cr);
    expect(new Set(crs).size).toBe(crs.length);
  });

  it("ทุกหมวดอ้างรหัสที่มีอยู่จริงในผังบัญชี", () => {
    for (const code of ADJ_CODES) {
      expect(() => coa(sub(code).dr), `${code} dr`).not.toThrow();
      expect(() => coa(sub(code).cr), `${code} cr`).not.toThrow();
    }
  });
});

/* ================================================================== *
 * ส่วนที่ 3 ข้อ 4 · ต้องไม่อยู่ในงบกระแสเงินสด
 * ================================================================== */

describe("ห้าหมวดนี้ต้องไม่โผล่ในงบกระแสเงินสด", () => {
  it("cashflow เป็น none ทุกหมวด", () => {
    for (const code of ADJ_CODES) expect(sub(code).cashflow, code).toBe("none");
  });

  it("ไม่อยู่ใน CF_LAYOUT และ findCashflowLayoutGaps() ยังว่างทั้งเจ็ดช่อง", () => {
    for (const code of ADJ_CODES) expect(cfSubCodes(), code).not.toContain(code);
    expect(findCashflowLayoutGaps()).toEqual({
      missing: [],
      duplicated: [],
      unknown: [],
      wrongSection: [],
      missingLegs: [],
      duplicatedLegs: [],
      wrongSectionLegs: [],
    });
  });

  it("impactLines บอกตรงๆ ว่าไม่มีเงินเคลื่อน ไม่ใช่ 'ย้ายระหว่างบัญชี'", () => {
    for (const code of ADJ_CODES) {
      const cf = impactLines(sub(code)).find((l) => l.startsWith("กระแสเงินสด"))!;
      expect(cf, code).toContain("ไม่มีเงินเคลื่อน");
      expect(cf, code).not.toContain("ย้ายระหว่างบัญชี");
    }
  });
});
