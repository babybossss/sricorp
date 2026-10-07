/**
 * ช่องบังคับของการยืนยันเงินเข้า-ออก (`buildClearing()`) อ่านจาก **ตารางกฎ** ที่เดียว
 *
 * ที่มา: คอมเมนต์ใน `types.ts` เขียนว่า `assetId` "ต้องส่งมาด้วย ไม่งั้นบัญชีย่อยรายทรัพย์
 * ไม่ตรง" แต่ `buildClearing()` **ยอมให้ผ่าน** — เอกสารขัดกับโค้ดในไฟล์เดียวกัน
 *
 * ตัดสินแล้วว่า **โค้ดต้องตามเอกสาร แต่เอกสารต้องแม่นกว่านี้**:
 * การยืนยันคือ transaction จริงอีกใบของเหตุการณ์เดียวกัน จึงต้องมีมิติบังคับชุดเดียวกับ
 * รายการต้นทาง — และ "ชุดไหนบังคับ" อ่านจาก `sub.requires` ของหมวดย่อย **ต้นทาง**
 * ไม่ใช่เช็ครหัสหมวดตรงๆ (CLAUDE.md ห้ามไว้) จึงเป็นกฎเดียวกับที่ `buildPosting()` ใช้
 *
 * ผลที่ตามมา — ไม่ใช่ทุกหมวดที่บังคับ:
 * - `inc.rent` (`requires: asset, contact`) → ต้องมีทั้งทรัพย์และผู้ติดต่อ
 * - `exp.repair` (`requires: asset`) → ต้องมีทรัพย์ ไม่บังคับผู้ติดต่อ
 * - `inc.interest_srr` (`requires: contact`) → ต้องมีผู้ติดต่อ ไม่บังคับทรัพย์
 * - `exp.marketing` (`requires: —`) → ไม่บังคับทั้งสองอย่าง **และต้องยืนยันได้**
 *   (เปิดฟีเจอร์ครึ่งเดียว/กันแน่นเกินจนล้างยอดค้างไม่ได้ อันตรายกว่าไม่เปิด · บทเรียนข้อ 7)
 *
 * ฝั่งนิติบุคคลยังมี `assertEvidencePolicy` บังคับคู่ค้าทุกประเภทรายการซ้อนอีกชั้น
 * ชุดนี้จึงใช้ผู้ถือที่เป็น **บุคคล** เพื่อให้พิสูจน์ได้ว่าด่านที่กันคือตารางกฎ ไม่ใช่กติกาเอกสาร
 */

import { describe, it, expect } from "vitest";
import { buildClearing } from "../clearing";
import { PostingError, type ClearingInput } from "../types";
import { TEST_RESOLVER } from "./fixture-resolver";
import { TX_TYPES, accrualCheck, clearingSubsFor, type SubCategory } from "@/lib/rules/tx-rules";

/** ธนากรเป็นบุคคล จึงไม่ติดกติกาเอกสารของนิติบุคคล — ด่านที่เหลือคือตารางกฎเท่านั้น */
const base: ClearingInput = {
  sourceId: "tx-09",
  typeKey: "income",
  subCode: "inc.rent",
  ownerId: "thanakorn",
  accruedAmount: 12_000,
  postedClearings: [],
  amount: 12_000,
  bankAccountId: "b4",
  date: "2026-10-03",
  assetId: "rent1",
  contactId: "c1",
};

const without = (input: ClearingInput, key: keyof ClearingInput): ClearingInput => {
  const copy = { ...input };
  delete copy[key];
  return copy;
};

const clear = (input: ClearingInput) => buildClearing(input, TEST_RESOLVER);

const rejectedWith = (fn: () => unknown): string => {
  try {
    fn();
  } catch (e) {
    expect(e).toBeInstanceOf(PostingError);
    return (e as Error).message;
  }
  throw new Error("ต้องถูกปฏิเสธ แต่ผ่าน");
};

/** หมวดที่ตั้งค้างได้ **และ** ตารางกฎมีทางล้างให้ — คือหมวดที่ขั้นยืนยันแตะได้จริง */
const CLEARABLE = TX_TYPES.flatMap((t) => t.subs.map((s) => ({ t, s }))).filter(({ s }) => {
  const check = accrualCheck(s);
  return check.ok && clearingSubsFor(check.account, s.cashflow).length > 0;
});

const needs = (s: SubCategory, r: "asset" | "contact") => s.requires?.includes(r) === true;
const inputFor = (t: { key: ClearingInput["typeKey"] }, s: SubCategory): ClearingInput => ({
  ...base,
  typeKey: t.key,
  subCode: s.code,
});

describe("หมวดที่ตารางกฎบังคับทรัพย์ — ไม่ส่ง assetId ต้องถูกปฏิเสธ", () => {
  it('inc.rent (asset + contact) ไม่ส่งทรัพย์ → ปฏิเสธ พร้อมบอกว่า "ต้องผูกทรัพย์"', () => {
    expect(rejectedWith(() => clear(without(base, "assetId")))).toMatch(/ทรัพย์/);
    expect(rejectedWith(() => clear({ ...base, assetId: "  " }))).toMatch(/ทรัพย์/);
  });

  it("exp.repair (asset) ไม่ส่งทรัพย์ → ปฏิเสธ ทั้งที่บัญชีพักเป็นเจ้าหนี้", () => {
    const payable = { ...base, typeKey: "expense" as const, subCode: "exp.repair", accruedAmount: 8_600, amount: 8_600 };
    expect(rejectedWith(() => clear(without(payable, "assetId")))).toMatch(/ทรัพย์/);
    expect(() => clear(payable)).not.toThrow();
  });

  it("ส่งทรัพย์แล้วผ่าน และทรัพย์ติดไปกับบรรทัดลูกหนี้ (บัญชีย่อยรายทรัพย์จึงตรง)", () => {
    const r = clear(base);
    expect(r.transactions[0].lines.find((l) => l.coaCode === "1200")?.assetId).toBe("rent1");
  });
});

describe("หมวดที่ตารางกฎบังคับผู้ติดต่อ — ไม่ส่ง contactId ต้องถูกปฏิเสธ", () => {
  it("inc.rent ไม่ส่งผู้ติดต่อ → ปฏิเสธ แม้ผู้ถือเป็นบุคคล (ไม่ใช่กติกาเอกสาร)", () => {
    expect(rejectedWith(() => clear(without(base, "contactId")))).toMatch(/ผู้ติดต่อ/);
  });

  it("inc.interest_srr (contact เท่านั้น) ไม่ส่งผู้ติดต่อ → ปฏิเสธ · ไม่ส่งทรัพย์ → ผ่าน", () => {
    const interest = { ...base, subCode: "inc.interest_srr" };
    expect(rejectedWith(() => clear(without(interest, "contactId")))).toMatch(/ผู้ติดต่อ/);
    expect(() => clear(without(interest, "assetId"))).not.toThrow();
  });
});

describe("หมวดที่ตารางกฎไม่บังคับ — ไม่ส่งแล้วต้องผ่าน ห้ามกันแน่นเกิน", () => {
  const marketing: ClearingInput = {
    ...base,
    typeKey: "expense",
    subCode: "exp.marketing",
    accruedAmount: 4_000,
    amount: 4_000,
  };

  it("exp.marketing ไม่ส่งทั้งทรัพย์และผู้ติดต่อ → ยืนยันได้ และได้บรรทัดครบ", () => {
    const bare = without(without(marketing, "assetId"), "contactId");
    const r = clear(bare);
    expect(r.transactions[0].lines).toHaveLength(2);
    expect(r.transactions[0].lines.find((l) => l.coaCode === "2100")?.debit).toBe(4_000);
  });

  it("exp.commission (contact) ไม่ส่งทรัพย์ → ผ่าน", () => {
    const commission = { ...base, typeKey: "expense" as const, subCode: "exp.commission" };
    expect(() => clear(without(commission, "assetId"))).not.toThrow();
  });
});

describe("กฎเดียวกันทุกหมวด — ไล่จากตารางกฎ ไม่ใช่จากรายการที่พิมพ์ไว้", () => {
  /**
   * สายสะดุด: ถ้าวันหนึ่งไม่มีหมวดใดอยู่ในกลุ่มใดกลุ่มหนึ่ง เคสด้านบนจะพิสูจน์ไม่ได้ว่า
   * เครื่องยนต์อ่าน `requires` จริง หรือบังคับ/ไม่บังคับทุกหมวดเหมือนกันหมด
   */
  it("มีหมวดครบทั้งสี่กลุ่มให้ทดสอบ (บังคับทรัพย์ / ไม่บังคับ / บังคับคู่ค้า / ไม่บังคับ)", () => {
    expect(CLEARABLE.filter(({ s }) => needs(s, "asset")).length).toBeGreaterThan(0);
    expect(CLEARABLE.filter(({ s }) => !needs(s, "asset")).length).toBeGreaterThan(0);
    expect(CLEARABLE.filter(({ s }) => needs(s, "contact")).length).toBeGreaterThan(0);
    expect(CLEARABLE.filter(({ s }) => !needs(s, "contact")).length).toBeGreaterThan(0);
  });

  it("ไม่ส่ง assetId → ปฏิเสธเฉพาะหมวดที่ตารางกฎบังคับ", () => {
    for (const { t, s } of CLEARABLE) {
      const input = without(inputFor(t, s), "assetId");
      if (needs(s, "asset")) {
        expect(rejectedWith(() => clear(input)), s.code).toMatch(/ทรัพย์/);
      } else {
        expect(() => clear(input), s.code).not.toThrow();
      }
    }
  });

  it("ไม่ส่ง contactId → ปฏิเสธเฉพาะหมวดที่ตารางกฎบังคับ", () => {
    for (const { t, s } of CLEARABLE) {
      const input = without(inputFor(t, s), "contactId");
      if (needs(s, "contact")) {
        expect(rejectedWith(() => clear(input)), s.code).toMatch(/ผู้ติดต่อ/);
      } else {
        expect(() => clear(input), s.code).not.toThrow();
      }
    }
  });

  it("ส่งครบตามที่ตารางกฎบังคับ → ทุกหมวดที่ล้างได้ ล้างได้จริง", () => {
    for (const { t, s } of CLEARABLE) {
      expect(() => clear(inputFor(t, s)), s.code).not.toThrow();
    }
  });

  it("หมวดที่ล้างไม่ได้เลย ต้องบอกว่าล้างไม่ได้ ไม่ใช่บอกว่าขาดทรัพย์", () => {
    // ลำดับข้อความสำคัญ: "หมวดนี้ไม่มียอดค้างให้ยืนยัน" ชี้ตรงจุดกว่า "ต้องผูกทรัพย์"
    const noClearing = TX_TYPES.flatMap((t) => t.subs.map((s) => ({ t, s }))).find(
      ({ s }) => !accrualCheck(s).ok && needs(s, "asset")
    )!;
    const m = rejectedWith(() => clear(without(inputFor(noClearing.t, noClearing.s), "assetId")));
    expect(m, noClearing.s.code).not.toMatch(/ต้องผูกทรัพย์/);
  });
});
