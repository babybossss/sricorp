import { describe, expect, it } from "vitest";
import { allLines, assertBalanced, buildPosting as build } from "../posting";
import { PostingError, type PostingInput } from "../types";
import { TEST_RESOLVER } from "./fixture-resolver";

const buildPosting = (i: PostingInput) => build(i, TEST_RESOLVER);

/**
 * ขายอสังหาฯ ที่เคยรีโนเวท: 1510 เป็นต้นทุนของทรัพย์ชิ้นเดียวกัน ต้องตัดในใบเดียวกัน (20261025000011)
 * ตัวเลขของเคสจริง: ต้นทุน 3,000,000 + รีโนเวท 500,000 ขาย 4,000,000 → กำไร 500,000 (ไม่ใช่ 1,000,000)
 */
const sellRe = (disposal: PostingInput["disposal"], amount: number): PostingInput => ({
  typeKey: "invest_sell",
  subCode: "inv.sell_re",
  ownerId: "thanakorn",
  bankAccountId: "b4",
  assetId: "condo-1",
  contactId: "c1",
  amount,
  disposal,
});

describe("ขายอสังหาฯ ที่เคยรีโนเวท · ตัด 1510 พร้อมทรัพย์", () => {
  const input = sellRe({ costBasis: 3_500_000, renovationBasis: 500_000, salePrice: 4_000_000 }, 4_000_000);

  it("เครดิต 1500 = 3,000,000 · เครดิต 1510 = 500,000 · กำไร 500,000 · สมดุล · ทั้งสองบรรทัดผูกทรัพย์", () => {
    const r = buildPosting(input);
    const ls = allLines(r);
    assertBalanced(ls);
    expect(ls.find((l) => l.coaCode === "1500")).toMatchObject({ credit: 3_000_000, assetId: "condo-1" });
    expect(ls.find((l) => l.coaCode === "1510")).toMatchObject({ credit: 500_000, assetId: "condo-1" });
    expect(ls.find((l) => l.coaCode === "4300")!.credit).toBe(500_000);
    expect(ls.find((l) => l.coaCode === "1100")!.debit).toBe(4_000_000);
  });

  it("ถอดค่ารีโนเวทออก (ไม่ส่ง) → ตัดทั้ง 3,500,000 จาก 1500 ทั้งก้อน ไม่มีบรรทัด 1510 (พฤติกรรมเดิมของทรัพย์ที่ไม่เคยรีโนเวท)", () => {
    const r = buildPosting(sellRe({ costBasis: 3_500_000, salePrice: 4_000_000 }, 4_000_000));
    const ls = allLines(r);
    expect(ls.find((l) => l.coaCode === "1500")!.credit).toBe(3_500_000);
    expect(ls.some((l) => l.coaCode === "1510")).toBe(false);
  });

  it("ขายแล้วรีโนเวทไม่ทำให้กำไรเพี้ยน: กำไรคิดจากต้นทุนรวม (3,500,000) เสมอ ทั้งสองแบบได้ 500,000", () => {
    const withReno = allLines(buildPosting(input)).find((l) => l.coaCode === "4300")!.credit;
    const without = allLines(buildPosting(sellRe({ costBasis: 3_500_000, salePrice: 4_000_000 }, 4_000_000))).find((l) => l.coaCode === "4300")!.credit;
    expect(withReno).toBe(without);
  });

  it("รีโนเวท > ต้นทุนรวม → ปฏิเสธ (รีโนเวทเป็นส่วนหนึ่งของต้นทุน ไม่ใช่ส่วนเพิ่ม)", () => {
    expect(() => buildPosting(sellRe({ costBasis: 100, renovationBasis: 101, salePrice: 200 }, 200))).toThrow(/ค่ารีโนเวทสะสม/);
  });

  it("รีโนเวทติดลบ / ไม่ใช่ตัวเลข → ปฏิเสธ", () => {
    expect(() => buildPosting(sellRe({ costBasis: 100, renovationBasis: -1, salePrice: 200 }, 200))).toThrow(PostingError);
    expect(() => buildPosting(sellRe({ costBasis: 100, renovationBasis: Number.NaN, salePrice: 200 }, 200))).toThrow(PostingError);
  });

  it("หมวดที่ไม่ได้เครดิตอสังหาฯ (ขายหุ้น) ส่งค่ารีโนเวทมา → ปฏิเสธ ไม่ตัด 1510 ให้เงียบๆ", () => {
    expect(() =>
      buildPosting({
        typeKey: "invest_sell",
        subCode: "inv.sell_securities",
        ownerId: "thanakorn",
        bankAccountId: "b4",
        assetId: "stock-1",
        amount: 200,
        disposal: { costBasis: 100, renovationBasis: 50, salePrice: 200 },
      })
    ).toThrow(/ตัดค่ารีโนเวทสะสมไม่ได้/);
  });

  it("ขายทั้งก้อนที่มีส่วนเกินทุนจากตีราคา + รีโนเวท: ล้าง 3400 ทั้งก้อน และบัญชีทรัพย์ (ต้นทุน + ส่วนตีเพิ่ม) กลับเป็นศูนย์", () => {
    const r = buildPosting(
      sellRe(
        { costBasis: 3_500_000, renovationBasis: 500_000, salePrice: 4_500_000, assetCostBefore: 3_500_000, priorSurplus: 700_000 },
        4_500_000
      )
    );
    const ls = allLines(r);
    assertBalanced(ls);
    // เครดิตสุทธิของ 1500 = ต้นทุนส่วนทรัพย์ 3,000,000 + ส่วนตีเพิ่ม 700,000 · 1510 = 500,000 · 3400 เดบิต 700,000
    const credit1500 = ls.filter((l) => l.coaCode === "1500").reduce((t, l) => t + l.credit - l.debit, 0);
    expect(credit1500).toBe(3_700_000);
    expect(ls.find((l) => l.coaCode === "1510")!.credit).toBe(500_000);
    expect(ls.find((l) => l.coaCode === "3400")!.debit).toBe(700_000);
    expect(ls.find((l) => l.coaCode === "4300")!.credit).toBe(1_000_000); // 4,500,000 − 3,500,000 (ส่วนตีราคาไม่นับเป็นกำไรซ้ำ)
  });
});
