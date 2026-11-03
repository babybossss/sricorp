import { describe, it, expect } from "vitest";
import { TX_TYPES, movesCash } from "@/lib/rules/tx-rules";
import { isCashAccount } from "@/lib/rules/coa";
import { CASH_FIELD_KEYS, EMPTY_CASH_FIELDS, cashFieldsFor } from "../cash-fields";

/**
 * ข้อ 4 ของผู้ตรวจ · เปลี่ยนไปหมวดที่ไม่มีเงินเคลื่อนแล้ว **ล้างไม่ครบ**
 *
 * ของเดิมล้างแต่ `bankId` ปล่อย `cashDate` ค้างค่าเริ่มต้นไว้
 * ตอนต่อ handler เขียน DB จริง หมวด `cash: "none"` จะส่ง `cash_date` ไม่ null
 * แล้วถูก trigger ของ 20261009000001 ปฏิเสธ (เงินสดผี — งบกระแสเงินสดจะนับ
 * เงินที่ไม่มีอยู่) · ผู้ใช้จะเจอ error จากช่องที่ฟอร์ม **ไม่แสดงให้แก้ได้เลย**
 *
 * เทสต์ชุดนี้เดินจากตารางกฎ ไม่ไล่ชื่อหมวด — หมวดใหม่ที่ `cash: "none"`
 * ถูกครอบอัตโนมัติ
 */

const allSubs = TX_TYPES.flatMap((t) => t.subs);
const NO_CASH = allSubs.filter((s) => !movesCash(s));
const MOVES_CASH = allSubs.filter(movesCash);

/** ฟอร์มที่กรอกไว้ครบแล้ว — ทุกช่องของฝั่งเงินสดมีค่าค้างอยู่ */
const filled = {
  ...EMPTY_CASH_FIELDS,
  subCode: "inc.rent",
  bankId: "b4",
  cashDate: "03/09/2026",
  transferToBankId: "b5",
  intercompanyNature: "loan" as const,
};

describe("เปลี่ยนไปหมวดที่ไม่มีเงินเคลื่อน → ล้างทุกช่องของฝั่งเงินสด", () => {
  it("มีหมวดที่ไม่มีเงินเคลื่อนให้ทดสอบจริง", () => {
    expect(NO_CASH.length).toBeGreaterThan(0);
    expect(MOVES_CASH.length).toBeGreaterThan(0);
  });

  it("ล้างครบทุกช่องที่ประกาศไว้ใน CASH_FIELD_KEYS ไม่เหลือค่าที่มองไม่เห็น", () => {
    for (const s of NO_CASH) {
      const next = cashFieldsFor(s.code, filled);
      for (const key of CASH_FIELD_KEYS) {
        expect(next[key], `${s.code} ยังเหลือค่าในช่อง ${key} ที่ฟอร์มไม่แสดง`).toBe("");
      }
    }
  });

  it("`cashDate` ต้องว่าง — ของเดิมล้างแต่ bankId แล้ว cash_date หลุดลง DB", () => {
    // เคสของ mutation P5 ตรงๆ: คืนโค้ดให้ไม่ล้าง cashDate แล้วบรรทัดนี้ต้องแดง
    for (const s of NO_CASH) {
      expect(cashFieldsFor(s.code, filled).cashDate, s.code).toBe("");
    }
    // และต้องไม่ใช่ว่าค่าตั้งต้นว่างอยู่แล้ว ไม่งั้นเทสต์นี้ไม่ได้ตรวจอะไร
    expect(EMPTY_CASH_FIELDS.cashDate, "ค่าตั้งต้นของ cashDate ต้องไม่ว่าง ไม่งั้นเคสนี้ผ่านฟรี").not.toBe("");
    expect(filled.cashDate).not.toBe("");
  });

  it("ทุกช่องที่ `CASH_FIELD_KEYS` อ้าง มีอยู่จริงในฟอร์ม (กันรายการที่ล้าสมัย)", () => {
    for (const key of CASH_FIELD_KEYS) {
      expect(Object.keys(EMPTY_CASH_FIELDS), key).toContain(key);
    }
  });
});

describe("หมวดที่เงินเคลื่อนจริง ต้องไม่ถูกล้างทิ้ง และกลับมาแล้วต้องกรอกต่อได้", () => {
  it("สลับระหว่างสองหมวดที่เงินเคลื่อน → ค่าที่กรอกไว้ยังอยู่ครบ", () => {
    for (const s of MOVES_CASH) {
      const next = cashFieldsFor(s.code, filled);
      expect(next.bankId, s.code).toBe(filled.bankId);
      expect(next.cashDate, s.code).toBe(filled.cashDate);
    }
  });

  it("กลับจากหมวดที่ไม่มีเงินเคลื่อน → คืนค่าตั้งต้น ไม่ใช่ค่าว่างที่ถูกบังคับทิ้งไว้", () => {
    // ค่าว่างที่ค้างจากการล้าง ทำให้ปุ่มบันทึกดับโดยไม่มีช่องไหนบอกว่าต้องแก้อะไร
    const afterClear = { ...filled, subCode: NO_CASH[0].code, ...cashFieldsFor(NO_CASH[0].code, filled) };
    const back = cashFieldsFor("inc.rent", afterClear);
    expect(back.cashDate).toBe(EMPTY_CASH_FIELDS.cashDate);
    expect(back.bankId).toBe("");
  });

  it("หมวดที่ไม่รู้จัก → ไม่ล้างอะไร ปล่อยให้ engine เป็นคนปฏิเสธพร้อมเหตุผล", () => {
    const next = cashFieldsFor("ghost.sub", filled);
    expect(next.cashDate).toBe(filled.cashDate);
    expect(next.bankId).toBe(filled.bankId);
  });

  it("คำตอบมาจากตารางกฎ ไม่ใช่รายชื่อหมวดที่ต้องมาเติมมือ", () => {
    for (const s of allSubs) {
      const cleared = cashFieldsFor(s.code, filled).cashDate === "";
      expect(cleared, `${s.code} (cash: ${s.cash})`).toBe(!movesCash(s));
      // เทียบกับคู่บัญชีจริงอีกชั้น — ธง `cash` ที่เพี้ยนจากคู่บัญชีต้องไม่ทำให้เทสต์นี้ผ่าน
      expect(cleared, s.code).toBe(!isCashAccount(s.dr) && !isCashAccount(s.cr));
    }
  });
});
