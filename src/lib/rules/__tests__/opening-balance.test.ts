/**
 * **ยอดยกมา (ตั้งต้นระบบ)** — ประเภทรายการที่ปลดล็อกให้นำเข้ายอดตั้งต้นได้
 *
 * สามอย่างที่ถ้าผิดแล้วตัวเลขผิดเงียบๆ และเทสต์ชุดนี้ตรึงไว้:
 *
 *  1. **งบดุลต้องดุลทุกผู้ถือ** — ยอดยกมาทุกบรรทัดคู่กับส่วนของเจ้าของ
 *     (กำไรสะสม) ถ้าขาคู่ไปเป็นรายได้/ค่าใช้จ่าย งวดแรกจะมีกำไรก้อนใหญ่ปลอม
 *  2. **ไม่เข้างบกำไรขาดทุนเลย** — ยอดยกมาคือผลของอดีตก่อนระบบ
 *  3. **ไม่เป็นกระแสเงินสดของงวด** — เงินสดยกมาคือยอดต้นงวด
 *     (เคสนี้อยู่ใน `cashflow.test.ts` ด้วย เพราะเป็นเรื่องของงบนั้นโดยตรง)
 *
 * และกันรูปที่เคยพลาดในเรื่องอื่นมาแล้ว: **คู่บัญชีต้องอยู่ในตารางกฎ** ไม่ใช่ให้
 * ผู้เรียกเลือกบัญชีเอง (D-115) → เทสต์ไล่ว่าทุกรหัสในตารางเทียบของคู่มือนำเข้า
 * มีหมวดของตัวเองจริง และหมวดเหล่านั้นไม่มีช่องให้เลือกบัญชี
 */

import { describe, it, expect } from "vitest";
import {
  TX_TYPES,
  findSub,
  allowedSubs,
  isValidPair,
  effectsOf,
  affectsPL,
  isOpeningBalanceSub,
  movesCash,
  canAccrueFromForm,
  type SubCategory,
} from "@/lib/rules/tx-rules";
import { coa, RETAINED_EARNINGS_COA, isCashAccount } from "@/lib/rules/coa";

const OPENING = TX_TYPES.find((t) => t.key === "opening");
const subs = OPENING?.subs ?? [];

/** ทุกรหัสที่ `docs/IMPORT_GUIDE.md` ตารางเทียบระบุว่าไฟล์ยอดตั้งต้นมีบรรทัดได้ */
const GUIDE_ACCOUNTS = [
  "1100",
  "1200",
  "1210",
  "1300",
  "1400",
  "1410",
  "1500",
  "1510",
  "1600",
  "1700",
  "1720",
  "2100",
  "2300",
  "2400",
  "2410",
];

describe("ยอดยกมา — ประเภทรายการต้องมีจริงและครอบทุกบัญชีที่คู่มือนำเข้าใช้", () => {
  it("มีประเภทรายการ opening ในตารางกฎ", () => {
    expect(OPENING, "ไม่มีประเภท opening — นำเข้ายอดตั้งต้นไม่ได้เลย").toBeTruthy();
    expect(subs.length).toBeGreaterThan(10);
  });

  it("ทุกรหัสในตารางเทียบของคู่มือมีหมวดของตัวเอง (ไม่ต้องให้ผู้เรียกเลือกบัญชี)", () => {
    const covered = new Set(
      subs.flatMap((s) => [s.dr, s.cr]).filter((c) => c !== RETAINED_EARNINGS_COA)
    );
    const missing = GUIDE_ACCOUNTS.filter((c) => !covered.has(c));
    expect(missing, "รหัสที่คู่มือนำเข้าใช้แต่ยังลงไม่ได้").toEqual([]);
  });

  it("ทุกหมวดมีขาคู่เป็น **ส่วนของเจ้าของ** (กำไรสะสม) — อ่านรหัสจากผังบัญชี", () => {
    expect(subs.length, "ลูปว่าง = เทสต์ผ่านด้วยเหตุผลผิด").toBeGreaterThan(10);
    for (const s of subs) {
      const pair = [s.dr, s.cr];
      expect(pair, `${s.code} ต้องแตะกำไรสะสม`).toContain(RETAINED_EARNINGS_COA);
      // และอีกขาต้องเป็นสินทรัพย์/หนี้สิน/ทุน — ไม่ใช่รายได้หรือค่าใช้จ่าย
      const other = pair.find((c) => c !== RETAINED_EARNINGS_COA)!;
      expect(["asset", "liability", "equity"], `${s.code} ขาอีกข้างเป็น ${coa(other).type}`).toContain(
        coa(other).type
      );
    }
  });

  it("`isOpeningBalanceSub()` ตรงกับประเภท opening ทั้งสองทิศ (ธงต้องไม่ขัดกับคู่บัญชี)", () => {
    for (const t of TX_TYPES) {
      for (const s of t.subs) {
        expect(isOpeningBalanceSub(s), `${s.code}`).toBe(t.key === "opening");
      }
    }
  });
});

describe("ยอดยกมา — ผลกระทบต่องบ", () => {
  it("ไม่กระทบงบกำไรขาดทุนเลยแม้แต่หมวดเดียว", () => {
    expect(subs.length, "ลูปว่าง = เทสต์ผ่านด้วยเหตุผลผิด").toBeGreaterThan(10);
    for (const s of subs) {
      expect(affectsPL(s), `${s.code} ไปแตะ P&L`).toBe(false);
      const { pl, conditionalPl } = effectsOf(s);
      expect(pl, `${s.code}`).toBeUndefined();
      expect(conditionalPl, `${s.code}`).toBeUndefined();
    }
  });

  it("**ทุกหมวดต้องเป็น cashflow: none** (ไม่งั้นงวดแรกมีเงินสดรับที่ไม่มีอยู่จริง)", () => {
    expect(subs.length, "ลูปว่าง = เทสต์ผ่านด้วยเหตุผลผิด").toBeGreaterThan(10);
    const wrong = subs.filter((s) => s.cashflow !== "none").map((s) => s.code);
    expect(wrong, "หมวดยอดยกมาที่เข้างบกระแสเงินสด").toEqual([]);
  });

  it("กระทบงบดุลสองด้านที่หักกันเสมอ (งบดุลดุลเองทุกใบ)", () => {
    expect(subs.length, "ลูปว่าง = เทสต์ผ่านด้วยเหตุผลผิด").toBeGreaterThan(10);
    for (const s of subs) {
      const { bs } = effectsOf(s);
      expect(bs.length, `${s.code}`).toBe(2);
      // ขาคู่กำไรสะสมต้องอยู่ฝั่งส่วนของเจ้าของ
      expect(bs.some((e) => e.side === "equity"), `${s.code}`).toBe(true);
    }
  });

  it("มีขาเงินสดเฉพาะหมวดเงินฝาก และหมวดนั้นต้องมีทิศ (ไม่ใช่ none)", () => {
    expect(subs.length, "ลูปว่าง = เทสต์ผ่านด้วยเหตุผลผิด").toBeGreaterThan(10);
    for (const s of subs) {
      const touchesCash = [s.dr, s.cr].some((c) => isCashAccount(c));
      // ด่าน 20261009000003 ฝั่ง DB: แตะ 11xx ⟺ cash_direction ไม่ใช่ none
      expect(movesCash(s), `${s.code}`).toBe(touchesCash);
      expect(s.cash === "none", `${s.code}`).toBe(!touchesCash);
    }
  });

  it("ตั้งค้างไม่ได้ทุกหมวด (ยอดยกมาไม่ใช่สิ่งที่รอรับ-รอจ่าย)", () => {
    expect(subs.length, "ลูปว่าง = เทสต์ผ่านด้วยเหตุผลผิด").toBeGreaterThan(10);
    for (const s of subs) {
      expect(s.accrualCoa, `${s.code} มีบัญชีพัก = เปิดช่องลงลูกหนี้ปลอมคู่กับกำไรสะสม`).toBeUndefined();
      expect(canAccrueFromForm(s), `${s.code}`).toBe(false);
    }
  });

  it("ไม่บังคับผูกทรัพย์/คู่ค้า — ไฟล์ยอดตั้งต้นเป็นบัญชีคุม ไม่ใช่ทะเบียนย่อย", () => {
    expect(subs.length, "ลูปว่าง = เทสต์ผ่านด้วยเหตุผลผิด").toBeGreaterThan(10);
    for (const s of subs) {
      expect(s.requires ?? [], `${s.code}`).toEqual([]);
    }
  });
});

describe("ยอดยกมา — เลือกหมวดได้จากประเภทที่ถูกเท่านั้น", () => {
  it("หมวด opn.* อยู่ใต้ประเภท opening และเลือกจากประเภทอื่นไม่ได้", () => {
    expect(subs.length, "ลูปว่าง = เทสต์ผ่านด้วยเหตุผลผิด").toBeGreaterThan(10);
    for (const s of subs) {
      expect(isValidPair("opening", s.code), `${s.code}`).toBe(true);
      for (const t of TX_TYPES) {
        if (t.key === "opening") continue;
        expect(isValidPair(t.key, s.code), `${s.code} เลือกได้จาก ${t.key}`).toBe(false);
      }
    }
  });

  it("allowedSubs('opening') คืนเฉพาะหมวดยอดยกมา", () => {
    const got = allowedSubs("opening").map((s: SubCategory) => s.code);
    expect(got.sort()).toEqual(subs.map((s) => s.code).sort());
    expect(got.every((c) => c.startsWith("opn."))).toBe(true);
  });

  it("findSub หาเจอทุกหมวด และรหัสไม่ซ้ำกับหมวดอื่นในระบบ", () => {
    const all = TX_TYPES.flatMap((t) => t.subs.map((s) => s.code));
    expect(new Set(all).size, "รหัสหมวดซ้ำกัน").toBe(all.length);
    for (const s of subs) expect(findSub(s.code)?.type.key).toBe("opening");
  });
});
