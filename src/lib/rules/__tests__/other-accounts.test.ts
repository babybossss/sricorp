/**
 * บัญชีรองรับ 4 ตัว (ลูกพี่สั่ง 26/10) — 1900 · 1950 · 2500 · 2600
 *
 * บัญชีรองรับเป็นของที่ **ลงผิดง่ายที่สุดในผังบัญชี** เพราะชื่อมันกว้าง
 * เทสต์ชุดนี้จึงคุมสามอย่างที่ถ้าหลุดแล้วตัวเลขผิดโดยงบยังดุล:
 *   1. ลงแล้ว **ล้างได้** — บัญชีที่ตั้งยอดได้แต่เอาออกไม่ได้คือหนี้/ทรัพย์ผีถาวร
 *   2. **ไม่กระทบกำไรขาดทุน** — จ่ายเงินแลกสิทธิไม่ใช่ค่าใช้จ่าย รับเงินที่ต้องคืนไม่ใช่รายได้
 *   3. อยู่ใน **ประเภทรายการที่ถูก** และเลือกจากประเภทอื่นไม่ได้
 */
import { describe, it, expect } from "vitest";
import { findSub, isValidPair, impactLines, affectsPL, movesCash, TX_TYPES } from "../tx-rules";
import { coa } from "../coa";

/** `findSub` คืน `{ type, sub }` — ที่นี่สนใจแต่ตัวหมวด */
const sub = (code: string) => findSub(code)!.sub;

/** บัญชีรองรับ → หมวดลง · หมวดล้าง · หมวดยอดยกมา · ประเภทรายการที่ควรอยู่ */
const CASES = [
  {
    code: "1900",
    side: "asset" as const,
    cf: "operating" as const,
    inSub: "inv.other_current_asset",
    outSub: "inv.other_current_asset_back",
    opening: "opn.other_current_asset",
    inType: "invest_buy" as const,
    outType: "invest_sell" as const,
  },
  {
    code: "1950",
    side: "asset" as const,
    cf: "investing" as const,
    inSub: "inv.other_noncurrent_asset",
    outSub: "inv.other_noncurrent_asset_back",
    opening: "opn.other_noncurrent_asset",
    inType: "invest_buy" as const,
    outType: "invest_sell" as const,
  },
  {
    code: "2500",
    side: "liability" as const,
    cf: "operating" as const,
    inSub: "fin.other_current_liability_in",
    outSub: "fin.other_current_liability_out",
    opening: "opn.other_current_liability",
    inType: "finance_in" as const,
    outType: "finance_out" as const,
  },
  {
    code: "2600",
    side: "liability" as const,
    cf: "financing" as const,
    inSub: "fin.other_noncurrent_liability_in",
    outSub: "fin.other_noncurrent_liability_out",
    opening: "opn.other_noncurrent_liability",
    inType: "finance_in" as const,
    outType: "finance_out" as const,
  },
];

describe("บัญชีรองรับ 4 ตัว มีครบทั้งทางลง ทางล้าง และยอดยกมา", () => {
  it.each(CASES)("$code อยู่ในผังบัญชีและเป็นฝั่งที่ถูก", ({ code, side }) => {
    expect(coa(code).type).toBe(side);
  });

  /**
   * ข้อที่สำคัญที่สุดของชุดนี้ — บทเรียนข้อ 7 ของผู้ตรวจ
   * เคยมีหมวดที่ "ตั้งค้างได้แต่ล้างไม่ได้" ทำให้ลูกหนี้ค้างตลอดไปและรายได้ถูกนับซ้ำ
   */
  it.each(CASES)("$code ล้างได้จริง — มีทั้งหมวดลงและหมวดล้าง ไม่ใช่ทางเดียว", ({ code, inSub, outSub }) => {
    expect(findSub(inSub), `ไม่มีหมวดลงของ ${code}`).toBeTruthy();
    expect(findSub(outSub), `ไม่มีหมวดล้างของ ${code} → ยอดจะค้างตลอดไป`).toBeTruthy();

    const put = sub(inSub);
    const clear = sub(outSub);
    expect([put.dr, put.cr]).toContain(code);
    expect([clear.dr, clear.cr]).toContain(code);

    // ทิศต้องกลับกันพอดี: ลงแล้วบัญชีเพิ่ม ล้างแล้วบัญชีลด
    const putsOn = put.dr === code ? "dr" : "cr";
    const clearsOn = clear.dr === code ? "dr" : "cr";
    expect(putsOn).not.toBe(clearsOn);
  });

  it.each(CASES)("$code มีหมวดยอดยกมา ไม่งั้นนำเข้ายอดตั้งต้นไม่ได้", ({ code, opening }) => {
    expect(findSub(opening), `ไม่มีหมวดยอดยกมาของ ${code}`).toBeTruthy();
    const s = sub(opening);
    expect([s.dr, s.cr]).toContain(code);
    // ยอดยกมาไม่ใช่เงินที่เคลื่อนในงวด — เข้างบกระแสเงินสดแล้วงวดแรกจะโชว์เงินก้อนที่ไม่มีจริง
    expect(s.cash).toBe("none");
    expect(s.cashflow).toBe("none");
    expect(movesCash(s)).toBe(false);
  });

  /**
   * **ไม่กระทบกำไรขาดทุนทุกหมวด** — นี่คือจุดที่ลงผิดแล้วกำไรเพี้ยนทันที
   * จ่ายเงินแลกสิทธิ = สินทรัพย์ ไม่ใช่ค่าใช้จ่าย · รับเงินที่ต้องคืน = หนี้สิน ไม่ใช่รายได้
   */
  it.each(CASES)("$code ไม่มีหมวดไหนกระทบกำไรขาดทุนเลย", ({ inSub, outSub, opening }) => {
    for (const c of [inSub, outSub, opening]) {
      const s = sub(c);
      expect(affectsPL(s), `${c} ไม่ควรกระทบ P&L`).toBe(false);
      expect(impactLines(s)).toContain("กำไรขาดทุน · ไม่กระทบ");
      // ไม่มีบัญชีกำไร/ขาดทุน แปลว่าเครื่องยนต์เติมบรรทัดกำไรให้ไม่ได้แม้อยากทำ
      expect(s.gainCoa).toBeUndefined();
      expect(s.lossCoa).toBeUndefined();
    }
  });

  it.each(CASES)("$code เงินเข้า-ออกถูกทิศ และอยู่ในกระแสเงินสดหมวดที่ตั้งใจ", ({ side, cf, inSub, outSub }) => {
    const put = sub(inSub);
    const clear = sub(outSub);
    // ฝั่งสินทรัพย์: ลง = จ่ายเงินออก · ฝั่งหนี้สิน: ลง = รับเงินเข้า
    expect(put.cash).toBe(side === "asset" ? "out" : "in");
    expect(clear.cash).toBe(side === "asset" ? "in" : "out");
    expect(put.cashflow).toBe(cf);
    expect(clear.cashflow).toBe(cf);
  });

  it.each(CASES)("$code งบดุลขยับถูกด้าน ลงแล้วเพิ่ม ล้างแล้วลด", ({ code, side, inSub, outSub }) => {
    const label = side === "asset" ? "สินทรัพย์" : "หนี้สิน";
    const name = coa(code).nameTh;   // อ่านจากผังบัญชี ไม่เขียนชื่อซ้ำที่นี่
    expect(impactLines(sub(inSub))).toContain(`งบดุล · ${label} — ${name} เพิ่มขึ้น`);
    expect(impactLines(sub(outSub))).toContain(`งบดุล · ${label} — ${name} ลดลง`);
  });

  it.each(CASES)("$code หมวดอยู่ใต้ประเภทที่ถูก และเลือกจากประเภทอื่นไม่ได้", ({ inSub, outSub, opening, inType, outType }) => {
    expect(isValidPair(inType, inSub)).toBe(true);
    expect(isValidPair(outType, outSub)).toBe(true);
    expect(isValidPair("opening", opening)).toBe(true);

    // เลือกข้ามประเภทไม่ได้ — ไม่งั้นหมวดจ่ายเงินจะไปโผล่ในเมนูรายได้
    for (const k of TX_TYPES.map((t) => t.key).filter((k) => k !== inType)) {
      expect(isValidPair(k, inSub), `${inSub} ไม่ควรเลือกได้จาก ${k}`).toBe(false);
    }
    for (const k of TX_TYPES.map((t) => t.key).filter((k) => k !== outType)) {
      expect(isValidPair(k, outSub), `${outSub} ไม่ควรเลือกได้จาก ${k}`).toBe(false);
    }
  });

  /**
   * บัญชีรองรับต้องมีคำเตือน เพราะชื่อกว้างจนคนเทของลงได้ทุกอย่าง
   * ถ้าเทลงหมด รายงานจะแยกไม่ออกว่าเงินไปอยู่กับอะไร
   */
  it.each(CASES)("$code หมวดลงและหมวดยอดยกมามีคำเตือนกำกับ", ({ inSub, opening }) => {
    for (const c of [inSub, opening]) {
      expect(sub(c).caution, `${c} ต้องมีคำเตือน`).toBeTruthy();
    }
  });
});
