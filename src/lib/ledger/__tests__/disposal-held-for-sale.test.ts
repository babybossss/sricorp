import { describe, expect, it } from "vitest";
import { allLines, assertBalanced, buildPosting as build } from "../posting";
import { PostingError, type PostingInput } from "../types";
import { TEST_RESOLVER } from "./fixture-resolver";

const buildPosting = (i: PostingInput) => build(i, TEST_RESOLVER);

/**
 * **ขายอสังหาฯ "เพื่อการขาย" (1520) พร้อมตัดค่ารีโนเวทในใบเดียวกัน** (27/10)
 *
 * ก่อนไฟล์นี้ `posting.ts` เทียบ `sub.cr !== "1500"` รหัสเดียว → หมวดที่เครดิต 1520
 * ตัดค่ารีโนเวทไม่ได้ และทางออกที่เอกสารบอกคือ "ย้ายกลับ 1500 ก่อนขาย"
 * = แยกบัญชีได้แต่ขายไม่ได้ (บทเรียน mace-windu ข้อ 7)
 *
 * ตัวเลขเดียวกับเคสจริงของ 1500: ต้นทุน 3,000,000 + รีโนเวท 500,000 ขาย 4,000,000
 * → กำไร 500,000 (ไม่ใช่ 1,000,000) และบัญชีทรัพย์ + 1510 เหลือศูนย์
 *
 * **เคสที่ห้ามหาย**: หมวดที่ไม่ใช่อสังหาฯ ส่งค่ารีโนเวทมา ต้องยังถูกปฏิเสธ
 * (เปลี่ยนจาก "เทียบรหัสเดียว" เป็น "เทียบกับชุด" ต้องไม่กลายเป็น "ไม่เทียบเลย")
 */
const sell = (subCode: string, disposal: PostingInput["disposal"], amount: number): PostingInput => ({
  typeKey: "invest_sell",
  subCode,
  ownerId: "thanakorn",
  bankAccountId: "b4",
  assetId: "condo-1",
  contactId: "c1",
  amount,
  disposal,
});

const RENO = { costBasis: 3_500_000, renovationBasis: 500_000, salePrice: 4_000_000 };

describe("ขายอสังหาฯ เพื่อการขาย (1520) ตัดค่ารีโนเวทได้ในใบเดียวกัน", () => {
  it("เครดิต 1520 = 3,000,000 · เครดิต 1510 = 500,000 · กำไร 500,000 · สมดุล · ผูกทรัพย์ทั้งสองบรรทัด", () => {
    const ls = allLines(buildPosting(sell("inv.sell_re_held_for_sale", RENO, 4_000_000)));
    assertBalanced(ls);
    expect(ls.find((l) => l.coaCode === "1520")).toMatchObject({ credit: 3_000_000, assetId: "condo-1" });
    expect(ls.find((l) => l.coaCode === "1510")).toMatchObject({ credit: 500_000, assetId: "condo-1" });
    expect(ls.find((l) => l.coaCode === "4300")!.credit).toBe(500_000);
    expect(ls.find((l) => l.coaCode === "1100")!.debit).toBe(4_000_000);
    // ห้ามแตะบัญชีของฝั่งเช่าเลย — ของรอขายอยู่ 1520 ของมันเอง
    expect(ls.some((l) => l.coaCode === "1500")).toBe(false);
  });

  it("กำไรเท่ากับขายจากฝั่งเช่าเป๊ะ — บัญชีที่ทรัพย์อยู่ไม่เปลี่ยนตัวเลขของงบกำไรขาดทุน", () => {
    const held = allLines(buildPosting(sell("inv.sell_re_held_for_sale", RENO, 4_000_000)));
    const rental = allLines(buildPosting(sell("inv.sell_re", RENO, 4_000_000)));
    expect(held.find((l) => l.coaCode === "4300")!.credit).toBe(rental.find((l) => l.coaCode === "4300")!.credit);
  });

  it("ขายขาดทุนก็ลงได้ — ใช้บัญชีขาดทุนตัวเดียวกับฝั่งเช่า (5910)", () => {
    const ls = allLines(
      buildPosting(sell("inv.sell_re_held_for_sale", { costBasis: 3_500_000, renovationBasis: 500_000, salePrice: 3_000_000 }, 3_000_000))
    );
    assertBalanced(ls);
    expect(ls.find((l) => l.coaCode === "5910")!.debit).toBe(500_000);
    expect(ls.find((l) => l.coaCode === "1520")!.credit).toBe(3_000_000);
    expect(ls.find((l) => l.coaCode === "1510")!.credit).toBe(500_000);
  });

  it("ขาย 1520 ที่เคยตีราคา: ล้าง 3400 ทั้งก้อน · บัญชีทรัพย์ (ต้นทุน + ส่วนตีเพิ่ม) กลับเป็นศูนย์", () => {
    const ls = allLines(
      buildPosting(
        sell(
          "inv.sell_re_held_for_sale",
          { costBasis: 3_500_000, renovationBasis: 500_000, salePrice: 4_500_000, assetCostBefore: 3_500_000, priorSurplus: 700_000 },
          4_500_000
        )
      )
    );
    assertBalanced(ls);
    const net1520 = ls.filter((l) => l.coaCode === "1520").reduce((t, l) => t + l.credit - l.debit, 0);
    expect(net1520).toBe(3_700_000);
    expect(ls.find((l) => l.coaCode === "1510")!.credit).toBe(500_000);
    expect(ls.find((l) => l.coaCode === "3400")!.debit).toBe(700_000);
    expect(ls.find((l) => l.coaCode === "4300")!.credit).toBe(1_000_000);
  });
});

describe("เส้นทางเดิมต้องไม่เสีย และด่านต้องไม่หลวมลง", () => {
  it("ขายอสังหาฯ เพื่อการเช่า (1500) พร้อมค่ารีโนเวท ยังผ่านเหมือนเดิม", () => {
    const ls = allLines(buildPosting(sell("inv.sell_re", RENO, 4_000_000)));
    assertBalanced(ls);
    expect(ls.find((l) => l.coaCode === "1500")!.credit).toBe(3_000_000);
    expect(ls.find((l) => l.coaCode === "1510")!.credit).toBe(500_000);
  });

  it("**หมวดที่ไม่ใช่อสังหาฯ (ขายหุ้น) ส่งค่ารีโนเวทมา → ยังปฏิเสธ** ไม่ตัด 1510 ให้เงียบๆ", () => {
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

  it("หมวดที่ไม่ใช่อสังหาฯ อีกตัว (ขายทองคำ) ส่งค่ารีโนเวทมา → ยังปฏิเสธ", () => {
    expect(() =>
      buildPosting({
        typeKey: "invest_sell",
        subCode: "inv.sell_commodity",
        ownerId: "thanakorn",
        bankAccountId: "b4",
        assetId: "gold-1",
        amount: 200,
        disposal: { costBasis: 100, renovationBasis: 50, salePrice: 200 },
      })
    ).toThrow(PostingError);
  });

  it("รีโนเวท > ต้นทุนรวม บนหมวด 1520 → ปฏิเสธเหมือนฝั่งเช่า", () => {
    expect(() =>
      buildPosting(sell("inv.sell_re_held_for_sale", { costBasis: 100, renovationBasis: 101, salePrice: 200 }, 200))
    ).toThrow(/ค่ารีโนเวทสะสม/);
  });

  it("รีโนเวทติดลบ / ไม่ใช่ตัวเลข บนหมวด 1520 → ปฏิเสธ", () => {
    expect(() =>
      buildPosting(sell("inv.sell_re_held_for_sale", { costBasis: 100, renovationBasis: -1, salePrice: 200 }, 200))
    ).toThrow(PostingError);
    expect(() =>
      buildPosting(sell("inv.sell_re_held_for_sale", { costBasis: 100, renovationBasis: Number.NaN, salePrice: 200 }, 200))
    ).toThrow(PostingError);
  });
});
