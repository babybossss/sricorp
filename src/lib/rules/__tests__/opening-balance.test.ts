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

/**
 * ทุกรหัสที่ไฟล์ยอดตั้งต้นของลูกพี่มีบรรทัดได้
 * (`docs/IMPORT_GUIDE.md` ตารางเทียบ + ที่เพิ่ม 25/10 จากไฟล์จริง)
 *
 * **รายการนี้คือสัญญา**: รหัสที่อยู่ในนี้แต่ไม่มีหมวด `opn.*` ของตัวเอง
 * = หน้าจอปฏิเสธไฟล์ทั้งไฟล์ (ซึ่งถูก — ดีกว่าข้ามบรรทัดเงียบๆ)
 * เทสต์ด้านล่างตรวจ **สองทาง**: ทุกรหัสในนี้ต้องมีหมวด และทุกหมวดต้องลงรหัสในนี้
 */
const GUIDE_ACCOUNTS = [
  "1100",
  "1200",
  "1210",
  // เพิ่ม 25/10 — ไฟล์จริงของลูกพี่มีรหัสเหล่านี้ และก่อนหน้านี้ลงไม่ได้เลย
  "1220", // ลูกหนี้อื่น (รอรับเงิน)
  "1290", // ค่าเผื่อหนี้สงสัยจะสูญ — ฝั่งเครดิต
  "1300",
  "1310", // ลูกหนี้ระหว่างกัน — กองกลาง SRI มีแน่นอน
  "1400",
  "1410",
  "1500",
  "1510",
  "1600",
  "1700",
  "1710", // เงินลงทุนในบริษัทในเครือ
  "1720",
  "1800", // ภาษีถูกหัก ณ ที่จ่ายรอเครดิต — ผู้เช่าหักภาษีทุกเดือน
  "2100",
  "2200", // เงินมัดจำรับจากผู้เช่า
  "2300",
  "2310", // เจ้าหนี้ระหว่างกัน
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

  it("**ทางกลับ** — ไม่มีหมวดยอดยกมาที่ลงบัญชีนอกตารางเทียบ", () => {
    // ทางเดียวไม่พอ: หมวดที่ลงบัญชีซึ่งไฟล์นำเข้าไม่เคยมี แปลว่าคนละความจริง
    // สองชุด (ไฟล์บอกอย่าง ตารางกฎบอกอย่าง) แล้วไม่มีใครรู้ว่าอันไหนถูก
    const allowed = new Set([...GUIDE_ACCOUNTS, RETAINED_EARNINGS_COA, "3100"]);
    const extra = [...new Set(subs.flatMap((s) => [s.dr, s.cr]))]
      .filter((c) => !allowed.has(c))
      .sort();
    expect(extra, "หมวดยอดยกมาที่ลงบัญชีนอกตารางเทียบ").toEqual([]);
  });

  it("บัญชีระหว่างกันมีทั้งสองฝั่ง — ลงข้างเดียวได้ แต่ต้องมีหมวดของอีกข้างให้ลงด้วย", () => {
    // ยอดยกมาลงทีละผู้ถือ จึงบังคับให้มาครบคู่ในใบเดียวไม่ได้
    // แต่ถ้ามีแค่ฝั่งลูกหนี้ ผู้ถืออีกฝ่ายจะลงเจ้าหนี้ไม่ได้เลย = ตัดกันไม่ลงถาวร
    const codes = new Set(subs.flatMap((s) => [s.dr, s.cr]));
    expect(codes.has("1310"), "ไม่มีหมวดลูกหนี้ระหว่างกัน").toBe(true);
    expect(codes.has("2310"), "ไม่มีหมวดเจ้าหนี้ระหว่างกัน").toBe(true);
  });

  it("ค่าเผื่อหนี้สงสัยจะสูญอยู่ **ฝั่งเครดิต** (สินทรัพย์ติดลบ) ไม่ใช่ฝั่งเดบิต", () => {
    const allowance = subs.find((s) => s.cr === "1290" || s.dr === "1290");
    expect(allowance, "ไม่มีหมวดยอดยกมาของค่าเผื่อหนี้สงสัยจะสูญ").toBeTruthy();
    // ลงผิดข้าง = ลูกหนี้สุทธิบวมเท่าค่าเผื่อสองเท่า โดยงบดุลยังดุล
    expect(allowance!.cr).toBe("1290");
    expect(allowance!.dr).toBe(RETAINED_EARNINGS_COA);
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
