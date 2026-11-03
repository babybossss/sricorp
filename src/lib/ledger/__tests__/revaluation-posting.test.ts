/**
 * ตีราคาทรัพย์ฝั่งลงทุน — ฝั่ง **engine** (D-111 ข้อ 2 · ลูกพี่ veto 24/10)
 *
 * สามเรื่องที่ไฟล์นี้ตรึงไว้:
 *   1. **ไม่แตะงบกำไรขาดทุนเลย** และมีเทสต์ **mutation** พิสูจน์ว่าด่านแดงจริง
 *      (ถ้าเทสต์ mutation เขียว = ด่านนั้นไม่ได้กันอะไร แค่เขียนไว้สวยๆ)
 *   2. **เดือนต่อเดือนต้องกลับรายการของเดือนก่อน** ไม่ใช่ลงทับกันจนยอดบวม
 *   3. ข้อมูลขาด (ไม่ส่งสกุลเงิน · ไม่ส่งอัตรา · ยอดบาทไม่ตรงอัตรา) → ปฏิเสธ
 */

import { describe, it, expect } from "vitest";
import { buildPosting as buildPostingWith, allLines, assertBalanced } from "../posting";
import { assertNoProfitAndLoss } from "../guards";
import { planRevaluation } from "../mark-to-market";
import type { AssetBook } from "../average-cost";
import { PostingError, type PostingInput, type PostingLine } from "../types";
import { REVALUATION_SURPLUS_COA, isCashAccount } from "@/lib/rules/coa";
import { statementOf } from "@/lib/rules/statements";
import { findSub } from "@/lib/rules/tx-rules";
import { TEST_RESOLVER } from "./fixture-resolver";

const buildPosting = (i: PostingInput) => buildPostingWith(i, TEST_RESOLVER);

const net = (lines: PostingLine[], code: string) =>
  lines.filter((l) => l.coaCode === code).reduce((a, l) => a + l.debit - l.credit, 0);

/**
 * ข้อมูลอ้างอิงของทรัพย์ — `planRevaluation()` ต้องรู้ว่าทรัพย์ชิ้นนี้เฉลี่ยต้นทุนได้ไหม
 * เพราะ **ตอนขาย** ทรัพย์ชิ้นเดียวต้องล้างส่วนเกินทุนทั้งก้อน (ลูกพี่สั่ง 25/10)
 */
const CATEGORY_OF: Record<string, string> = {
  stock1: "PAPER_STOCK_LISTED",
  gold1: "COM_GOLD",
  watch1: "COM_ALT",
  condo1: "RE_RENTAL",
  priv1: "PAPER_STOCK_PRIVATE",
};
const BOOK: AssetBook = (assetId) => {
  const categoryCode = CATEGORY_OF[assetId];
  return categoryCode ? { assetId, categoryCode } : undefined;
};

/** หุ้นต่างประเทศ: ต้นทุน 1,000,000 บาท · ถือ 40,000 USD */
const plan = (over: Partial<Parameters<typeof planRevaluation>[0]> = {}) =>
  planRevaluation({
    ownerId: "thanakorn",
    assetId: "stock1",
    assetCoa: "1700",
    costBasisThb: 1_000_000,
    priorSurplusThb: 0,
    currency: "USD",
    rateToThb: 36.5,
    valueOriginal: 40_000,
    valuationRef: "val-2026-10",
    ...over,
  }, BOOK);

const postPlan = (p: ReturnType<typeof planRevaluation>) =>
  p.entries.flatMap((e) => {
    const r = buildPosting(e);
    // ทุกใบต้องสมดุลในตัวเอง (DB ตรวจต่อ transaction)
    for (const t of r.transactions) assertBalanced(t.lines);
    return allLines(r);
  });

describe("ตีราคาขึ้นครั้งแรก", () => {
  it("ลง Dr ทรัพย์ / Cr ส่วนเกินทุน — สองบรรทัด ไม่มีเงินสด", () => {
    const p = plan();
    // 40,000 × 36.5 = 1,460,000 · ต้นทุน 1,000,000 → ส่วนเกิน 460,000
    expect(p.valueThb).toBe(1_460_000);
    expect(p.targetSurplusThb).toBe(460_000);
    expect(p.entries).toHaveLength(1);

    const lines = postPlan(p);
    expect(lines).toHaveLength(2);
    expect(net(lines, "1700")).toBe(460_000);
    expect(net(lines, REVALUATION_SURPLUS_COA)).toBe(-460_000);
    expect(lines.some((l) => isCashAccount(l.coaCode)), "มีบรรทัดเงินสด").toBe(false);
    expect(lines.some((l) => l.bankAccountId), "มีบัญชีธนาคารติดมา").toBe(false);
    expect(lines.every((l) => l.cfCategory === "none"), "ยังนับในงบกระแสเงินสด").toBe(true);
  });

  it("**ไม่มีบรรทัดในงบกำไรขาดทุนเลย**", () => {
    const lines = postPlan(plan());
    expect(lines.filter((l) => statementOf(l.coaCode).statement === "PL")).toEqual([]);
  });

  it("ผูกทรัพย์ **ทั้งสองขา** รวมขาส่วนเกินทุน — ไม่งั้นล้างตอนขายไม่ได้", () => {
    const lines = postPlan(plan());
    for (const l of lines) expect(l.assetId, l.coaCode).toBe("stock1");
  });

  it("อัตราและมูลค่าสกุลเดิมติดไปใน memo — ตรวจย้อนได้ว่าใช้อัตราไหน", () => {
    const lines = postPlan(plan());
    for (const l of lines) {
      expect(l.memo, l.coaCode).toMatch(/40,000 USD × 36.5/);
      expect(l.memo, l.coaCode).toMatch(/val-2026-10/);
    }
  });

  it("ทองคำ/คริปโตใช้บัญชี 1720 คนละตัวกับหลักทรัพย์", () => {
    const lines = postPlan(plan({ assetCoa: "1720" }));
    expect(net(lines, "1720")).toBe(460_000);
    expect(net(lines, "1700")).toBe(0);
  });

  it("ตีราคาลงครั้งแรก (มูลค่าต่ำกว่าทุน) → ส่วนเกินทุนติดลบ ไม่ใช่ค่าใช้จ่าย", () => {
    // 20,000 × 36.5 = 730,000 · ต้นทุน 1,000,000 → −270,000
    const p = plan({ valueOriginal: 20_000 });
    expect(p.targetSurplusThb).toBe(-270_000);
    const lines = postPlan(p);
    expect(net(lines, REVALUATION_SURPLUS_COA)).toBe(270_000); // เดบิต = ทุนลด
    expect(net(lines, "1700")).toBe(-270_000);
    expect(lines.filter((l) => statementOf(l.coaCode).statement === "PL")).toEqual([]);
  });
});

/**
 * **คำตอบของข้อที่ต้องคิดให้จบ**: ตีราคาเดือนถัดไปต้องกลับรายการของเดือนก่อน
 * แล้วลงยอดสะสมใหม่ทั้งก้อน ไม่ใช่ลงส่วนต่างทับกันไปเรื่อยๆ
 *
 * เทสต์ชุดนี้พิสูจน์ด้วยการเดินสามเดือนจริง แล้วดูว่ายอดใน 3400 เท่ากับ
 * "มูลค่าตีราคาล่าสุด − ต้นทุน" พอดีทุกเดือน (คำถามกระทบยอดข้อเดียวที่ตรวจได้)
 */
describe("เดือนต่อเดือน — กลับรายการของเดือนก่อน ไม่ใช่ลงทับกัน", () => {
  it("เดือนที่สองได้สองใบ: กลับของเดือนก่อน + ลงยอดสะสมใหม่", () => {
    // เดือน 1: ส่วนเกิน 460,000 · เดือน 2: 35,000 × 36.5 = 1,277,500 → 277,500
    const p = plan({ priorSurplusThb: 460_000, valueOriginal: 35_000 });
    expect(p.entries).toHaveLength(2);
    expect(p.priorSurplusThb).toBe(460_000);
    expect(p.targetSurplusThb).toBe(277_500);

    // ใบแรกต้องเป็นใบกลับรายการ (ตีลงเต็มก้อนของเดือนก่อน)
    expect(p.entries[0].subCode).toBe("adj.revalue_securities_down");
    expect(p.entries[0].amount).toBe(460_000);
    expect(p.entries[0].memo).toMatch(/กลับรายการ/);
    // ใบที่สองคือยอดสะสมของเดือนนี้ **จากต้นทุน** ไม่ใช่ส่วนต่าง
    expect(p.entries[1].subCode).toBe("adj.revalue_securities_up");
    expect(p.entries[1].amount).toBe(277_500);
  });

  it("ยอดสุทธิหลังลงครบ = มูลค่าล่าสุด − ต้นทุน (ไม่บวม ไม่ขาด)", () => {
    const month1 = postPlan(plan());
    const month2 = postPlan(plan({ priorSurplusThb: 460_000, valueOriginal: 35_000 }));
    const surplus = net(month1, REVALUATION_SURPLUS_COA) + net(month2, REVALUATION_SURPLUS_COA);
    // เครดิตคือทุนเพิ่ม จึงติดลบในการนับแบบ debit−credit
    expect(-surplus).toBe(277_500);
    // บัญชีทรัพย์ก็ต้องเท่ากัน — ยอดยกมา = ต้นทุน + ส่วนเกิน
    expect(net(month1, "1700") + net(month2, "1700")).toBe(277_500);
  });

  it("กลับทิศจากบวกเป็นลบ → สองใบ ตีลงทั้งคู่ และยอดสุทธิติดลบพอดี", () => {
    // เดือน 3: 25,000 × 36.5 = 912,500 → −87,500 (จากเดิม +277,500)
    const p = plan({ priorSurplusThb: 277_500, valueOriginal: 25_000 });
    expect(p.entries.map((e) => e.subCode)).toEqual([
      "adj.revalue_securities_down",
      "adj.revalue_securities_down",
    ]);
    expect(p.entries.map((e) => e.amount)).toEqual([277_500, 87_500]);

    const lines = postPlan(p);
    // เริ่มจาก +277,500 แล้วลง −277,500 −87,500 → เหลือ −87,500
    expect(-net(lines, REVALUATION_SURPLUS_COA)).toBe(-365_000);
    expect(277_500 + -365_000).toBe(-87_500);
  });

  it("กลับจากลบเป็นบวก → ใบแรกตีขึ้นเพื่อกลับของเดือนก่อน แล้วตีขึ้นอีกใบ", () => {
    const p = plan({ priorSurplusThb: -270_000, valueOriginal: 45_000 });
    expect(p.entries.map((e) => e.subCode)).toEqual([
      "adj.revalue_securities_up",
      "adj.revalue_securities_up",
    ]);
    // 45,000 × 36.5 = 1,642,500 → +642,500
    expect(p.entries.map((e) => e.amount)).toEqual([270_000, 642_500]);
  });

  it("มูลค่ากลับมาเท่าต้นทุนพอดี → มีแต่ใบกลับรายการ ไม่มีใบที่สอง", () => {
    // ต้นทุน 1,000,000 ÷ 36.5 ไม่ลงตัว → ใช้อัตรา 25 กับ 40,000 = 1,000,000 พอดี
    const p = plan({ priorSurplusThb: 460_000, rateToThb: 25, valueOriginal: 40_000 });
    expect(p.targetSurplusThb).toBe(0);
    expect(p.entries).toHaveLength(1);
    expect(p.entries[0].subCode).toBe("adj.revalue_securities_down");
    expect(p.entries[0].amount).toBe(460_000);

    const lines = postPlan(p);
    expect(-net(lines, REVALUATION_SURPLUS_COA)).toBe(-460_000);
    expect(460_000 + -460_000, "ส่วนเกินทุนต้องกลับเป็นศูนย์").toBe(0);
  });

  it("มูลค่าไม่เปลี่ยนจากเดือนก่อน → ปฏิเสธ ไม่ใช่ลงสองใบที่หักกันเป็นศูนย์", () => {
    // ลงใบกลับ + ใบเดิมซ้ำ = ร่องรอยสองใบที่ไม่ได้บอกอะไร และทำให้คนอ่านสมุดสับสน
    expect(() => plan({ priorSurplusThb: 460_000 })).toThrow(PostingError);
    expect(() => plan({ priorSurplusThb: 460_000 })).toThrow(/ไม่มีอะไรต้องลง/);
  });

  it("ลงสองเดือนโดย **ไม่** กลับรายการ จะได้ยอดที่บวมเกิน — เทสต์เชิงเทียบ", () => {
    // ถ้าใครเปลี่ยนไปใช้วิธี "ลงยอดสะสมทับโดยไม่กลับของเดือนก่อน"
    // ยอดจะเป็น 460,000 + 277,500 = 737,500 ทั้งที่ควรเป็น 277,500
    const naive = 460_000 + 277_500;
    const correct = plan({ priorSurplusThb: 460_000, valueOriginal: 35_000 }).targetSurplusThb;
    expect(naive).not.toBe(correct);
    expect(correct).toBe(277_500);
  });
});

describe("เคสข้อมูลขาด — ต้องปฏิเสธ ไม่ใช่เดา", () => {
  it("ไม่ส่งสกุลเงิน → ปฏิเสธ (ไม่ใช่เดาเป็นบาท)", () => {
    // เดาเป็นบาท = ทรัพย์ 40,000 USD จะกลายเป็น 40,000 บาท ต่ำกว่าจริง 36 เท่า
    expect(() => plan({ currency: undefined as unknown as string })).toThrow(PostingError);
    expect(() => plan({ currency: "" })).toThrow(/สกุลเงิน/);
    expect(() => plan({ currency: "EUR" })).toThrow(/สกุลเงิน/);
  });

  it("ไม่ส่งอัตรา → ปฏิเสธ (ไม่ใช่ถือว่า 1 และไม่ใช่ใช้อัตราเดือนก่อน)", () => {
    expect(() => plan({ rateToThb: undefined as unknown as number })).toThrow(/อัตรา/);
    expect(() => plan({ rateToThb: 0 })).toThrow(/อัตรา/);
    expect(() => plan({ rateToThb: -36.5 })).toThrow(/อัตรา/);
    expect(() => plan({ rateToThb: Number.NaN })).toThrow(/อัตรา/);
  });

  it("สกุลบาทที่อัตราไม่ใช่ 1 → ปฏิเสธ", () => {
    expect(() => plan({ currency: "THB", rateToThb: 36.5 })).toThrow(/บาท/);
    expect(() => plan({ currency: "THB", rateToThb: 1, valueOriginal: 1_200_000 })).not.toThrow();
  });

  it("ไม่ส่งส่วนเกินทุนที่ค้างอยู่ → ปฏิเสธ (ไม่ใช่ถือว่าศูนย์)", () => {
    // ถือว่าศูนย์ = ไม่กลับรายการของเดือนก่อน แล้วส่วนเกินทุนโตสองเท่า
    expect(() => plan({ priorSurplusThb: undefined as unknown as number })).toThrow(
      /ส่วนเกินทุนจากการตีราคาที่ค้างอยู่/
    );
    expect(() => plan({ priorSurplusThb: Number.NaN })).toThrow(/ส่วนเกินทุน/);
  });

  it("มูลค่าตลาดหรือต้นทุน 0 / ติดลบ → ปฏิเสธ", () => {
    expect(() => plan({ valueOriginal: 0 })).toThrow(/มากกว่า 0/);
    expect(() => plan({ valueOriginal: -40_000 })).toThrow(/ติดลบ|มากกว่า 0/);
    expect(() => plan({ costBasisThb: 0 })).toThrow(/ต้นทุน/);
  });

  it("บัญชีทรัพย์ที่ยังไม่มีหมวดตีราคา → ปฏิเสธ พร้อมบอกบัญชีที่ทำได้จริง", () => {
    let thrown: unknown;
    try {
      plan({ assetCoa: "1500" });
    } catch (e) {
      thrown = e;
    }
    expect(thrown).toBeInstanceOf(PostingError);
    expect((thrown as Error).message).toMatch(/1700/);
    expect((thrown as Error).message).toMatch(/1720/);
  });

  it("หมวดตีราคาที่ไม่ส่ง revaluation เข้า engine → ปฏิเสธ", () => {
    expect(() =>
      buildPosting({
        typeKey: "adjust",
        subCode: "adj.revalue_securities_up",
        amount: 460_000,
        ownerId: "thanakorn",
        assetId: "stock1",
      })
    ).toThrow(/ต้องระบุสกุลเงิน อัตราแลกเปลี่ยน/);
  });

  it("หมวดตีราคาที่ไม่ผูกทรัพย์ → ปฏิเสธ", () => {
    expect(() =>
      buildPosting({
        typeKey: "adjust",
        subCode: "adj.revalue_securities_up",
        amount: 460_000,
        ownerId: "thanakorn",
        revaluation: { currency: "USD", rateToThb: 36.5, valueOriginal: 40_000, valueThb: 1_460_000 },
      })
    ).toThrow(/ต้องผูกทรัพย์/);
  });

  it("ยอดบาทที่ไม่ตรงกับอัตราคูณมูลค่าสกุลเดิม → ปฏิเสธ", () => {
    // นี่คือด่านที่ทำให้ "เก็บแต่ยอดบาท" เป็นไปไม่ได้ — ยอดบาทต้องพิสูจน์ตัวเองได้
    expect(() =>
      buildPosting({
        typeKey: "adjust",
        subCode: "adj.revalue_securities_up",
        amount: 460_000,
        ownerId: "thanakorn",
        assetId: "stock1",
        revaluation: { currency: "USD", rateToThb: 36.5, valueOriginal: 40_000, valueThb: 9_999_999 },
      })
    ).toThrow(/ไม่ตรงกับอัตราที่ระบุ/);
  });

  it("ส่งบัญชีธนาคารมากับรายการตีราคา → ปฏิเสธ (ไม่มีเงินเคลื่อน)", () => {
    expect(() =>
      buildPosting({
        typeKey: "adjust",
        subCode: "adj.revalue_securities_up",
        amount: 460_000,
        ownerId: "thanakorn",
        assetId: "stock1",
        bankAccountId: "b4",
        revaluation: { currency: "USD", rateToThb: 36.5, valueOriginal: 40_000, valueThb: 1_460_000 },
      })
    ).toThrow(/ไม่มีเงินเข้าหรือออกบัญชี/);
  });

  it("ตั้งค้างรับรายการตีราคา → ปฏิเสธ (ไม่มีขาเงินสดให้พัก)", () => {
    expect(() =>
      buildPosting({
        typeKey: "adjust",
        subCode: "adj.revalue_securities_up",
        amount: 460_000,
        ownerId: "thanakorn",
        assetId: "stock1",
        notYetPaid: true,
        revaluation: { currency: "USD", rateToThb: 36.5, valueOriginal: 40_000, valueThb: 1_460_000 },
      })
    ).toThrow(/ตั้งค้างรับ-ค้างจ่ายไม่ได้/);
  });
});

/**
 * ====================================================================
 * **MUTATION** — พิสูจน์ว่าด่าน "ห้ามแตะ P&L" แดงจริง
 *
 * ด่านที่ไม่มีเทสต์แบบนี้ เราไม่รู้เลยว่ามันกันอะไรได้ · สองชั้นที่ต้องแดงทั้งคู่:
 *   ชั้นที่ 1 เรียก `assertNoProfitAndLoss()` ตรงๆ ด้วยบรรทัดที่แตะ P&L
 *   ชั้นที่ 2 **แก้คู่บัญชีในตารางกฎจริง** ให้ชี้บัญชีรายได้ แล้วเดินผ่าน
 *             `buildPosting()` ทั้งเส้น — ต้องถูกปฏิเสธ ไม่ใช่ลงบรรทัดให้
 *
 * ชั้นที่ 2 คือชั้นที่สำคัญ: มันจำลองสิ่งที่จะเกิดจริงวันหนึ่ง (มีคนคิดว่า
 * "กำไรก็คือรายได้" แล้วแก้ `cr` เป็น 4900) ซึ่งทำให้ใบยังสมดุลทุกบรรทัด
 * และไม่มีอะไรฟ้องเลย กำไรขาดทุนจะวิ่งตามค่าเงินทุกเดือน
 * ====================================================================
 */
describe("MUTATION · ด่านห้ามแตะงบกำไรขาดทุนต้องแดงจริง", () => {
  it("ชั้นที่ 1 · เรียกด่านตรงๆ ด้วยบรรทัดบัญชีรายได้ → โยน", () => {
    const lines: PostingLine[] = [
      { coaCode: "1700", debit: 100, credit: 0 },
      { coaCode: "4900", debit: 0, credit: 100 },
    ];
    expect(() => assertNoProfitAndLoss(lines, "รายการตีราคาทดสอบ")).toThrow(PostingError);
    expect(() => assertNoProfitAndLoss(lines, "รายการตีราคาทดสอบ")).toThrow(/ห้ามเข้างบกำไรขาดทุนเด็ดขาด/);
  });

  it("ชั้นที่ 1 · บรรทัดบัญชีค่าใช้จ่ายก็ต้องโยน (ไม่ใช่กันแต่ฝั่งรายได้)", () => {
    const lines: PostingLine[] = [
      { coaCode: "5900", debit: 100, credit: 0 },
      { coaCode: "1700", debit: 0, credit: 100 },
    ];
    expect(() => assertNoProfitAndLoss(lines, "รายการตีราคาทดสอบ")).toThrow(/ค่าใช้จ่าย/);
  });

  it("ชั้นที่ 1 · บรรทัดงบดุลล้วนต้องผ่าน (ด่านไม่แน่นเกินจนของที่ถูกทำไม่ได้)", () => {
    const lines: PostingLine[] = [
      { coaCode: "1700", debit: 100, credit: 0 },
      { coaCode: REVALUATION_SURPLUS_COA, debit: 0, credit: 100 },
    ];
    expect(() => assertNoProfitAndLoss(lines, "รายการตีราคาทดสอบ")).not.toThrow();
  });

  it("ชั้นที่ 2 · แก้คู่บัญชีของหมวดตีราคาให้ชี้บัญชีรายได้ → buildPosting ปฏิเสธ", () => {
    const sub = findSub("adj.revalue_securities_up")!.sub;
    const original = sub.cr;
    const input: PostingInput = {
      typeKey: "adjust",
      subCode: "adj.revalue_securities_up",
      amount: 460_000,
      ownerId: "thanakorn",
      assetId: "stock1",
      revaluation: { currency: "USD", rateToThb: 36.5, valueOriginal: 40_000, valueThb: 1_460_000 },
    };

    // ของเดิมต้องผ่าน — ไม่งั้นเทสต์นี้ "แดง" เพราะเหตุผลอื่น
    expect(() => buildPosting(input)).not.toThrow();

    try {
      // กลายพันธุ์: รายได้อื่น (4900) แทนส่วนเกินทุนจากการตีราคา
      sub.cr = "4900";
      let thrown: unknown;
      try {
        buildPosting(input);
      } catch (e) {
        thrown = e;
      }
      expect(thrown, "ด่านไม่ได้กันอะไรเลย — การตีราคาหลุดเข้างบกำไรขาดทุนได้").toBeInstanceOf(
        PostingError
      );
      expect((thrown as Error).message).toMatch(/ห้ามเข้างบกำไรขาดทุนเด็ดขาด/);
      expect((thrown as Error).message).toMatch(/4900/);
    } finally {
      sub.cr = original;
    }
    // คืนสภาพแล้วต้องผ่านอีกครั้ง (กันเทสต์ตัวถัดไปรับผลข้างเคียง)
    expect(() => buildPosting(input)).not.toThrow();
  });

  it("ชั้นที่ 2 · กลายพันธุ์ฝั่งเดบิตเป็นบัญชีค่าใช้จ่าย → ปฏิเสธเหมือนกัน", () => {
    const sub = findSub("adj.revalue_securities_down")!.sub;
    const original = sub.dr;
    const input: PostingInput = {
      typeKey: "adjust",
      subCode: "adj.revalue_securities_down",
      amount: 270_000,
      ownerId: "thanakorn",
      assetId: "stock1",
      revaluation: { currency: "USD", rateToThb: 36.5, valueOriginal: 20_000, valueThb: 730_000 },
    };
    expect(() => buildPosting(input)).not.toThrow();
    try {
      sub.dr = "5900";
      expect(() => buildPosting(input)).toThrow(/ห้ามเข้างบกำไรขาดทุนเด็ดขาด/);
    } finally {
      sub.dr = original;
    }
    expect(() => buildPosting(input)).not.toThrow();
  });
});

/**
 * ตอนขายจริง — รับรู้กำไร/ขาดทุนเข้า P&L **และล้างส่วนเกินทุนออกพร้อมกัน**
 *
 * ถ้าไม่ล้าง: ส่วนเกินทุนค้างในส่วนของเจ้าของตลอดไปทั้งที่ทรัพย์ไม่อยู่แล้ว
 * และยอดในบัญชีทรัพย์ไม่กลับเป็นศูนย์ (เครดิตแค่ต้นทุน แต่ยอดยกมาคือต้นทุน+ส่วนเกิน)
 */
describe("ขายจริง — ล้างส่วนเกินทุนของทรัพย์ชิ้นนั้นพร้อมกัน", () => {
  const sell = (over: Partial<PostingInput> = {}): PostingInput => ({
    typeKey: "invest_sell",
    subCode: "inv.sell_securities",
    amount: 1_500_000,
    ownerId: "thanakorn",
    bankAccountId: "b4",
    assetId: "stock1",
    contactId: "c1",
    disposal: { costBasis: 1_000_000, salePrice: 1_500_000, assetCostBefore: 1_000_000, priorSurplus: 460_000 },
    ...over,
  });

  it("เคยตีขึ้น 460,000 → เดบิต 3400 ล้างออก และบัญชีทรัพย์กลับเป็นศูนย์", () => {
    const lines = allLines(buildPosting(sell()));
    assertBalanced(lines);
    // ส่วนเกินทุนถูกล้าง: เคยเครดิต 460,000 ตอนตีราคา ตอนนี้เดบิตคืน
    expect(net(lines, REVALUATION_SURPLUS_COA)).toBe(460_000);
    // บัญชีทรัพย์ถูกตัดออกทั้งก้อน = ต้นทุน + ส่วนเกินที่ตีไว้
    expect(net(lines, "1700")).toBe(-1_460_000);
  });

  it("ยอดรวมของทั้งวงจร (ตีราคา → ขาย) ต้องเป็นศูนย์ทั้งสองบัญชี", () => {
    const revalue = postPlan(plan());
    const sale = allLines(buildPosting(sell()));
    expect(net(revalue, REVALUATION_SURPLUS_COA) + net(sale, REVALUATION_SURPLUS_COA)).toBe(0);
    // ทรัพย์: ซื้อ 1,000,000 (ไม่ได้อยู่ในเทสต์นี้) + ตีขึ้น 460,000 − ตัดออก 1,460,000
    expect(net(revalue, "1700") + net(sale, "1700")).toBe(-1_000_000);
  });

  it("กำไรที่รับรู้เข้า P&L คิดจาก **ต้นทุนเดิม** ไม่ใช่มูลค่าที่ตีไว้ — ไม่นับซ้ำ", () => {
    const lines = allLines(buildPosting(sell()));
    // ขาย 1,500,000 − ต้นทุน 1,000,000 = กำไร 500,000 (ไม่ใช่ 1,500,000 − 1,460,000)
    const gain = lines.filter((l) => statementOf(l.coaCode).statement === "PL");
    expect(gain).toHaveLength(1);
    expect(gain[0].credit).toBe(500_000);
  });

  it("เคยตีลง (ส่วนเกินติดลบ) → กลับทิศ และยังสมดุล", () => {
    const lines = allLines(
      buildPosting(
        sell({ disposal: { costBasis: 1_000_000, salePrice: 1_500_000, assetCostBefore: 1_000_000, priorSurplus: -270_000 } })
      )
    );
    assertBalanced(lines);
    expect(net(lines, REVALUATION_SURPLUS_COA)).toBe(-270_000);
    expect(net(lines, "1700")).toBe(-730_000);
  });

  it("ไม่เคยตีราคา (ไม่ส่ง / 0) → ไม่มีบรรทัด 3400 เลย", () => {
    for (const disposal of [
      { costBasis: 1_000_000, salePrice: 1_500_000 },
      { costBasis: 1_000_000, salePrice: 1_500_000, unrealizedAdjustment: 0 },
    ]) {
      const lines = allLines(buildPosting(sell({ disposal })));
      expect(lines.some((l) => l.coaCode === REVALUATION_SURPLUS_COA)).toBe(false);
      expect(lines).toHaveLength(3);
    }
  });

  it("บรรทัดล้างส่วนเกินทุนผูกทรัพย์ — ตามรอยได้ว่าล้างของทรัพย์ชิ้นไหน", () => {
    const lines = allLines(buildPosting(sell()));
    for (const l of lines.filter((x) => x.coaCode === REVALUATION_SURPLUS_COA)) {
      expect(l.assetId).toBe("stock1");
    }
  });

  it("เงินสดที่เข้าบัญชียังเป็นราคาขายสุทธิ ไม่ถูกส่วนเกินทุนกวน", () => {
    const lines = allLines(buildPosting(sell()));
    expect(net(lines, "1100")).toBe(1_500_000);
  });
});

/**
 * **ขายบางส่วน — ล้างส่วนเกินทุนตามสัดส่วน** (D-112 ข้อ 1 · ลูกพี่ตัดสิน 24/10)
 *
 * ฉากเดียวกับที่ผู้ตรวจวัดกำไรปลอมได้: ซื้อ 10 หน่วย 1,000,000 → ตีขึ้น 460,000
 * → ขาย 3 หน่วย (ต้นทุนถัวเฉลี่ย 300,000) → ต้องล้าง 3400 เพียง **30% = 138,000**
 * ถ้าล้างทั้งก้อน ต้นทุนคงเหลือจะเหลือ 240,000 แทน 700,000 แล้วการขายครั้งถัดไป
 * โชว์ "กำไร" งอกมา 460,000 ที่ไม่มีอยู่จริง
 *
 * ตัวเลขชุดนี้ต้องตรงกับฝั่ง DB ตัวต่อตัว (supabase/tests/zz_asset_cost_basis_test.sql)
 */
describe("ขายบางส่วน — ล้างส่วนเกินทุนตามสัดส่วน (D-112)", () => {
  const partial = (over: Record<string, unknown> = {}): PostingInput => ({
    typeKey: "invest_sell",
    subCode: "inv.sell_securities",
    amount: 450_000,
    ownerId: "thanakorn",
    bankAccountId: "b4",
    assetId: "stock1",
    contactId: "c1",
    disposal: {
      costBasis: 300_000,
      salePrice: 450_000,
      assetCostBefore: 1_000_000,
      priorSurplus: 460_000,
      ...over,
    },
  });

  it("ขาย 3 ใน 10 หน่วย → ล้าง 3400 แค่ 138,000 (30%) ไม่ใช่ 460,000", () => {
    const lines = allLines(buildPosting(partial()));
    assertBalanced(lines);
    expect(net(lines, REVALUATION_SURPLUS_COA)).toBe(138_000);
    expect(net(lines, REVALUATION_SURPLUS_COA)).not.toBe(460_000);
    // บัญชีทรัพย์ถูกตัดออก = ต้นทุนที่ขาย 300,000 + ส่วนที่ตีไว้ตามสัดส่วน 138,000
    expect(net(lines, "1700")).toBe(-438_000);
  });

  it("กำไรยังคิดจากต้นทุนถัวเฉลี่ยของหน่วยที่ขาย ไม่ใช่จากมูลค่าที่ตีไว้", () => {
    const gain = allLines(buildPosting(partial())).filter(
      (l) => statementOf(l.coaCode).statement === "PL"
    );
    expect(gain).toHaveLength(1);
    expect(gain[0].credit).toBe(150_000);
  });

  it("ส่งยอดที่ล้างมาเองไม่ตรงสัดส่วน → **ปฏิเสธ** พร้อมบอกยอดที่ถูก", () => {
    let thrown: unknown;
    try {
      buildPosting(partial({ unrealizedAdjustment: 460_000 }));
    } catch (e) {
      thrown = e;
    }
    expect(thrown, "ล้างทั้งก้อนตอนขายบางส่วนต้องถูกปฏิเสธ").toBeInstanceOf(PostingError);
    expect((thrown as Error).message).toMatch(/138000/);
    expect((thrown as Error).message).toMatch(/สัดส่วน/);
  });

  it("ส่งยอดที่ตรงสัดส่วนมาด้วยก็ได้ (ยืนยันกันเอง) → ลงได้ปกติ", () => {
    const lines = allLines(buildPosting(partial({ unrealizedAdjustment: 138_000 })));
    expect(net(lines, REVALUATION_SURPLUS_COA)).toBe(138_000);
  });

  it("ส่วนเกินทุนที่ล้าง (unrealizedAdjustment) ส่งเดี่ยวๆ ไม่ได้ — ต้องจับคู่ assetCostBefore + priorSurplus (D-115)", () => {
    const alone = (adj: number): PostingInput => {
      const p = partial();
      return { ...p, disposal: { costBasis: 300_000, salePrice: 450_000, unrealizedAdjustment: adj } };
    };
    for (const adj of [460_000, -270_000]) {
      expect(() => buildPosting(alone(adj))).toThrow(PostingError);
      expect(() => buildPosting(alone(adj))).toThrow(/assetCostBefore/);
    }
    // 0 ยังได้ (ทรัพย์ที่ไม่เคยตีราคา) — ด่านใหม่ไม่กันเกินจน 0 ก็ใช้ไม่ได้
    expect(() => buildPosting(alone(0))).not.toThrow();
  });

  it("ส่งมาตัวเดียว (ขาดต้นทุนทั้งก้อน หรือขาดส่วนเกินที่ค้าง) → ปฏิเสธ ไม่ใช่เดา", () => {
    for (const disposal of [
      { costBasis: 300_000, salePrice: 450_000, priorSurplus: 460_000 },
      { costBasis: 300_000, salePrice: 450_000, assetCostBefore: 1_000_000 },
    ]) {
      let thrown: unknown;
      try {
        buildPosting({ ...partial(), disposal } as PostingInput);
      } catch (e) {
        thrown = e;
      }
      expect(thrown).toBeInstanceOf(PostingError);
      expect((thrown as Error).message).toMatch(/คู่กัน/);
    }
  });

  it("ขายหมด (ต้นทุนที่ขาย = ต้นทุนทั้งก้อน) → ล้างส่วนเกินทั้งก้อนพอดี", () => {
    const lines = allLines(
      buildPosting({
        ...partial(),
        amount: 1_500_000,
        disposal: {
          costBasis: 1_000_000,
          salePrice: 1_500_000,
          assetCostBefore: 1_000_000,
          priorSurplus: 460_000,
        },
      })
    );
    assertBalanced(lines);
    expect(net(lines, REVALUATION_SURPLUS_COA)).toBe(460_000);
    expect(net(lines, "1700")).toBe(-1_460_000);
  });

  it("เคยตีราคาลง → ล้างตามสัดส่วนในทิศกลับกัน", () => {
    const lines = allLines(buildPosting(partial({ priorSurplus: -460_000 })));
    assertBalanced(lines);
    expect(net(lines, REVALUATION_SURPLUS_COA)).toBe(-138_000);
    expect(net(lines, "1700")).toBe(-162_000);
  });

  it("ส่วนเกินทุนค้างอยู่แต่ไม่มีต้นทุนในสมุด → ปฏิเสธ (ใบซื้อหายไป)", () => {
    let thrown: unknown;
    try {
      buildPosting(partial({ assetCostBefore: 0 }));
    } catch (e) {
      thrown = e;
    }
    expect(thrown).toBeInstanceOf(PostingError);
  });
});

describe("ตีราคา — สองเส้นทางของ 'ตอนขาย' ต้องแยกกันตั้งแต่ตอนตีราคา (25/10)", () => {
  it("ทรัพย์ชิ้นเดียว (ของสะสมใน 1720) → บอกยอดที่ต้องล้างทั้งก้อนตอนขาย", () => {
    const p = plan({ assetId: "watch1", assetCoa: "1720", currency: "THB", rateToThb: 1, valueOriginal: 1_460_000 });
    expect(p.costBasisMode).toBe("whole_item");
    expect(p.targetSurplusThb).toBe(460_000);
    // ขายทั้งชิ้น → ล้าง 460,000 ทั้งก้อน ไม่มีสัดส่วนให้คิด
    expect(p.surplusToClearOnWholeDisposal).toBe(460_000);
    expect(p.summary.some((l) => l.includes("ทั้งก้อน"))).toBe(true);
  });

  it("ทองคำ (เฉลี่ยได้) → ไม่บอกยอดทั้งก้อน เพราะขึ้นกับสัดส่วนตอนขาย", () => {
    const p = plan({ assetId: "gold1", assetCoa: "1720", currency: "THB", rateToThb: 1, valueOriginal: 1_460_000 });
    expect(p.costBasisMode).toBe("average");
    expect(p.surplusToClearOnWholeDisposal).toBeNull();
    expect(p.summary.some((l) => l.includes("ตามสัดส่วน"))).toBe(true);
  });

  it("หุ้นนอกตลาด (ห้ามเฉลี่ย แต่แบ่งขายรายล็อตได้) → บอกให้ระบุล็อตตอนขาย", () => {
    const p = plan({ assetId: "priv1", assetCoa: "1700" });
    expect(p.costBasisMode).toBe("specific_lot");
    expect(p.surplusToClearOnWholeDisposal).toBeNull();
    expect(p.summary.some((l) => l.includes("ระบุล็อต"))).toBe(true);
  });

  it("ไม่ส่งข้อมูลอ้างอิง / ทรัพย์ที่ตัวอ่านไม่รู้จัก → ปฏิเสธ ไม่ใช่เดา", () => {
    let thrown: unknown;
    try {
      planRevaluation(
        {
          ownerId: "thanakorn",
          assetId: "stock1",
          assetCoa: "1700",
          costBasisThb: 1_000_000,
          priorSurplusThb: 0,
          currency: "USD",
          rateToThb: 36.5,
          valueOriginal: 40_000,
        },
        undefined as unknown as AssetBook
      );
    } catch (e) {
      thrown = e;
    }
    expect(thrown).toBeInstanceOf(PostingError);
    expect((thrown as Error).message).toMatch(/ไม่ได้ส่งข้อมูลอ้างอิงของทรัพย์/);

    expect(() => plan({ assetId: "ไม่มีในทะเบียน" })).toThrow(/ไม่พบทรัพย์/);
  });

  it("ปฏิเสธ 'ข้อมูลอ้างอิงไม่ครบ' **ก่อน** ตรวจอย่างอื่น — ไม่หลุดไปสร้างใบด้วยโหมดที่เดา", () => {
    // อัตราแลกเปลี่ยนก็ผิด แต่ข้อความต้องเป็นเรื่องทรัพย์ เพราะนั่นคือด่านแรก
    expect(() => plan({ assetId: "ไม่รู้จัก", rateToThb: 0 })).toThrow(/ไม่พบทรัพย์/);
  });
});
