import { describe, it, expect } from "vitest";
import {
  TX_TYPES,
  affectsPL,
  allowedSubs,
  effectsOf,
  findSub,
  impactLines,
  isValidPair,
  movesCash,
  type SubCategory,
} from "../tx-rules";
import { COA, coa, isCashAccount } from "../coa";
import {
  PL_LAYOUT,
  cashflowLineOf,
  cfSubCodes,
  findCashflowLayoutGaps,
  findLayoutGaps,
  statementOf,
} from "../statements";

const RECOVERED = "inc.bad_debt_recovered";
const WRITEOFF_CODES = ["adj.writeoff_rent", "adj.writeoff_interest", "adj.writeoff_other"];
/** บัญชีลูกหนี้ทั้งสามตัวที่หมวดตัดหนี้สูญล้างออกจากสมุด */
const RECEIVABLES = ["1200", "1210", "1220"];

const allSubs = TX_TYPES.flatMap((t) => t.subs);
const sub = (code: string): SubCategory => {
  const found = findSub(code);
  expect(found, `ไม่พบหมวด ${code} ในตารางกฎ`).toBeTruthy();
  return found!.sub;
};

/* ================================================================== *
 * ข้อ 2 ของผู้ตรวจ · ตัดหนี้สูญแล้วลูกหนี้จ่ายมาทีหลัง — เกิดจริงบ่อย
 *
 * ก่อนรอบนี้ทางเดียวที่มีคือ `inv.collect_rent` (Dr 1100 / Cr 1200)
 * ซึ่งผ่านทุกด่านแล้วได้ `1200 = −30,000` และ P&L ไม่ขยับ:
 *   → รายได้ขาดเท่ายอดที่เก็บคืนได้ และลูกหนี้ติดลบในงบดุล
 *   → ทั้งใบสมดุลทุกบรรทัด ไม่มี trigger ไหนฟ้อง จับได้แค่ด้วยเทสต์นี้
 * ================================================================== */

describe("มีทางกลับของการตัดหนี้สูญ — หมวด หนี้สูญได้รับคืน", () => {
  it("หมวดมีอยู่จริง และอยู่ใต้ประเภท รายได้ ไม่ใช่ประเภทปรับปรุงทางบัญชี", () => {
    // อยู่ใต้ "รายได้" เพราะเงินเข้าจริงและรับรู้เป็นรายได้ ไม่ใช่รายการปรับปรุงที่ไม่มีเงินเคลื่อน
    expect(findSub(RECOVERED)?.type.key, "หมวดหนี้สูญได้รับคืนต้องอยู่ใต้ประเภทรายได้").toBe("income");
    expect(isValidPair("income", RECOVERED)).toBe(true);
    expect(isValidPair("adjust", RECOVERED)).toBe(false);
    expect(allowedSubs("income").map((s) => s.code)).toContain(RECOVERED);
  });

  it("คู่บัญชี Dr 1100 / Cr 4320 — เงินเข้าบัญชีจริงและรับรู้เป็นรายได้", () => {
    const s = sub(RECOVERED);
    expect(s.dr).toBe("1100");
    expect(s.cr).toBe("4320");
    expect(s.cash).toBe("in");
    expect(s.cashflow).toBe("operating");
    expect(movesCash(s)).toBe(true);
    expect(s.requires, "ต้องรู้ว่าเก็บคืนได้จากใคร").toContain("contact");
  });

  /**
   * **เคสของ mutation P4** — เปลี่ยนให้ `cr 1200` (ปลุกลูกหนี้กลับมา) ต้องแดงที่นี่
   *
   * ลูกหนี้ตัวนั้นถูกตัดออกจากสมุดไปแล้ว การเครดิตบัญชีลูกหนี้จึงทำให้ยอดติดลบ
   * (ไม่มีอะไรให้ลด) และรายได้ไม่โผล่ที่งบกำไรขาดทุนเลย = อาการเดิมที่กำลังแก้
   */
  it("ห้ามเครดิตบัญชีลูกหนี้ — ปลุกลูกหนี้กลับมาแล้วรายได้จะไม่โผล่ และลูกหนี้ติดลบ", () => {
    const s = sub(RECOVERED);
    expect(RECEIVABLES, `${RECOVERED} เครดิต ${s.cr}`).not.toContain(s.cr);
    expect(coa(s.cr).type, "ขาที่ไม่ใช่เงินสดต้องเป็นรายได้").toBe("income");
    expect(affectsPL(s), "เก็บหนี้สูญคืนได้ต้องขยับกำไรขาดทุน ไม่ใช่แค่สลับบัญชีในงบดุล").toBe(true);
  });

  it("ผลกระทบที่ฟอร์มแสดง: รายได้เพิ่ม · เงินสดเพิ่ม · กระแสเงินสดฝั่งดำเนินงาน", () => {
    const s = sub(RECOVERED);
    const { pl, bs } = effectsOf(s);
    expect(pl).toEqual({ line: coa("4320").nameTh, kind: "revenue" });
    expect(bs).toContainEqual({ line: coa("1100").nameTh, side: "asset", direction: "increase" });
    const cf = impactLines(s).find((l) => l.startsWith("กระแสเงินสด"))!;
    expect(cf).toContain("ดำเนินงาน");
  });

  it("คำอธิบายบอกเหตุผลที่รับรู้เป็นรายได้ ไม่ใช่ปลุกลูกหนี้กลับมา (คนอ่านต้องรู้ว่าทำไม)", () => {
    const s = sub(RECOVERED);
    expect(s.plain).toMatch(/รายได้/);
    expect(s.caution, "ต้องมี caution อธิบายการตัดสินใจ").toBeTruthy();
    expect(s.caution!).toMatch(/ตัดหนี้สูญ/);
  });

  /**
   * กฎทั่วไป ไม่ใช่เคสเดียว — "หมวดที่เอาของออกจากสมุดถาวร ต้องมีทางรับของกลับ"
   * เหมือนกฎ "ตั้งค้างได้ต้องล้างได้" (บทเรียนข้อ 7) · เพิ่มหมวดตัดหนี้สูญตัวที่สี่
   * ในอนาคตแล้วลืมทางกลับ จะแดงที่นี่ ไม่ใช่ไปเจอตอนลูกหนี้จ่ายเงินมาจริง
   */
  it("ทุกหมวดตัดหนี้สูญมีทางรับเงินคืนที่รับรู้เป็นรายได้ อย่างน้อยหนึ่งทาง", () => {
    expect(WRITEOFF_CODES.every((c) => findSub(c)), "หมวดตัดหนี้สูญต้องยังอยู่").toBe(true);
    const recovery = allSubs.filter(
      (s) => s.cash === "in" && movesCash(s) && coa(s.cr).type === "income" && affectsPL(s) && s.cr === "4320"
    );
    expect(recovery.map((s) => s.code), "ไม่มีหมวดรับคืนหนี้สูญ").toEqual([RECOVERED]);
  });
});

describe("บัญชีใหม่ 4320 หนี้สูญได้รับคืน", () => {
  it("อยู่ในผังบัญชี เป็นรายได้ และไม่ใช่บัญชีเงินสด", () => {
    const a = coa("4320");
    expect(a.type).toBe("income");
    expect(a.nameTh).toBe("หนี้สูญได้รับคืน");
    expect(isCashAccount("4320")).toBe(false);
  });

  it("ไม่มีรหัสซ้ำในผังหลังเพิ่ม 4320", () => {
    const codes = COA.map((a) => a.code);
    expect(new Set(codes).size).toBe(codes.length);
  });

  it("อยู่ในงบกำไรขาดทุนฝั่งรายได้ แยกบรรทัดของตัวเอง ไม่ปนกับรายได้อื่น", () => {
    const where = statementOf("4320");
    expect(where.statement).toBe("PL");
    const section = PL_LAYOUT.find((s) => s.lines.some((l) => l.codes.includes("4320")))!;
    expect(section.kind).toBe("revenue");
    // ปนกับ "รายได้อื่น" แล้วอ่านงบไม่ออกว่ารายได้ก้อนนี้คือหนี้ที่ตัดทิ้งไปแล้วและเก็บคืนได้
    // (คู่ตรงข้ามของบรรทัด "หนี้สงสัยจะสูญ" ซึ่งก็แยกบรรทัดด้วยเหตุผลเดียวกัน)
    expect(where.line).not.toBe(statementOf("4900").line);
    expect(where.line).not.toBe(statementOf("5920").line);
  });

  it("โครงงบยังครอบผังบัญชีครบ ไม่ซ้ำ ไม่เกิน หลังเพิ่ม 4320", () => {
    expect(findLayoutGaps()).toEqual({ missing: [], duplicated: [], unknown: [] });
  });
});

describe("หนี้สูญได้รับคืนต้องโผล่ในงบกระแสเงินสดฝั่งดำเนินงาน", () => {
  it("อยู่ใน CF_LAYOUT ส่วนดำเนินงาน", () => {
    expect(cfSubCodes()).toContain(RECOVERED);
    expect(cashflowLineOf(RECOVERED).section).toBe("operating");
  });

  it("findCashflowLayoutGaps() ยังว่างทั้งเจ็ดช่อง", () => {
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
});
