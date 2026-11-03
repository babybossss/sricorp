import { describe, expect, it } from "vitest";
import { allLines, assertBalanced, buildPosting as build } from "../posting";
import { PostingError, type PostingInput } from "../types";
import { PROPERTY_COA } from "@/lib/rules/coa";
import { TEST_RESOLVER } from "./fixture-resolver";

const buildPosting = (i: PostingInput) => build(i, TEST_RESOLVER);

/**
 * **เส้นทางเข้าของอสังหาฯ "เพื่อการขาย" (1520) ครบวงจร** (27/10)
 *
 * `f0322a4` เปิดเส้นทาง **ออก** (ขายตรงจาก 1520 ได้) แต่เส้นทาง **เข้า** ยังปิด:
 * `inv.buy_re` กับ `opn.property` เดบิต 1500 ตายตัว → ของที่ซื้อมาเพื่อขาย
 * ต้องลงบัญชีเพื่อการเช่าก่อนแล้วย้ายอีกใบ (งบดุลระหว่างนั้นผิดความจริง)
 *
 * ไฟล์นี้วัด **วงจรที่ลูกพี่ทำจริงที่สุด**: ซื้อของรอขาย → รีโนเวทก่อนขาย → ขาย
 * ด้วยตัวเลขที่ตรวจทานได้ด้วยมือ
 *
 *   ซื้อ 3,000,000 (1520) · รีโนเวท 500,000 (1510) · ขาย 4,200,000
 *   → ต้นทุนที่ตัด 3,500,000 · **กำไร 700,000** (ไม่ใช่ 1,200,000)
 *   → 1520 และ 1510 ต้องกลับเป็นศูนย์ทั้งคู่ (ไม่มีทรัพย์ผีค้างงบดุล)
 *
 * และ **ห้ามแตะ 1500 เลยตลอดวงจร** — ถ้าแตะ แปลว่ายังต้องเดินผ่านบัญชีของให้เช่า
 */

const OWNER = "thanakorn";
const BANK = "b4";
const ASSET = "condo-for-sale-1";

const buy = (subCode: string, amount: number): PostingInput => ({
  typeKey: "invest_buy",
  subCode,
  ownerId: OWNER,
  bankAccountId: BANK,
  assetId: ASSET,
  contactId: "c1",
  amount,
});

const opening = (subCode: string, amount: number): PostingInput => ({
  typeKey: "opening",
  subCode,
  ownerId: OWNER,
  assetId: ASSET,
  amount,
});

const sell = (subCode: string, amount: number, disposal: PostingInput["disposal"]): PostingInput => ({
  typeKey: "invest_sell",
  subCode,
  ownerId: OWNER,
  bankAccountId: BANK,
  assetId: ASSET,
  contactId: "c1",
  amount,
  disposal,
});

/** ยอดสุทธิของบัญชีหนึ่งจากหลายใบรวมกัน (เดบิต − เครดิต) */
const net = (entries: PostingInput[], coaCode: string): number =>
  entries
    .flatMap((e) => allLines(buildPosting(e)))
    .filter((l) => l.coaCode === coaCode)
    .reduce((t, l) => t + l.debit - l.credit, 0);

/* ================================================================== *
 * 1 · ซื้อเข้า 1520 ตรงได้
 * ================================================================== */

describe("1 · ซื้ออสังหาฯ เพื่อขาย เข้าบัญชี 1520 ตรง", () => {
  it("เดบิต 1520 เต็มจำนวน · เครดิตเงินสด · ผูกทรัพย์ · สมดุล · **ไม่แตะ 1500**", () => {
    const ls = allLines(buildPosting(buy("inv.buy_re_held_for_sale", 3_000_000)));
    assertBalanced(ls);
    expect(ls.find((l) => l.coaCode === "1520")).toMatchObject({ debit: 3_000_000, assetId: ASSET });
    expect(ls.find((l) => l.coaCode === "1100")!.credit).toBe(3_000_000);
    expect(ls.some((l) => l.coaCode === "1500"), "ยังเดินผ่านบัญชีเพื่อการเช่า = ยังปิดช่องไม่สำเร็จ").toBe(false);
  });

  it("เข้ากิจกรรม **ลงทุน** ไม่ใช่ค่าใช้จ่าย — ไม่มีบรรทัดงบกำไรขาดทุนเลย", () => {
    const ls = allLines(buildPosting(buy("inv.buy_re_held_for_sale", 3_000_000)));
    expect(ls.find((l) => l.coaCode === "1520")!.cfCategory).toBe("investing");
    // บัญชี 4xxx/5xxx ห้ามโผล่ — ซื้อทรัพย์คือการเปลี่ยนรูปสินทรัพย์
    expect(ls.filter((l) => /^[45]\d\d\d$/.test(l.coaCode))).toEqual([]);
  });

  it("ซื้อแล้วยังไม่จ่ายเงิน → **ถูกปฏิเสธเหมือนฝั่งเช่าเป๊ะ** ไม่ใช่เปิดช่องใหม่ให้หมวดใหม่", () => {
    // `inv.buy_re` ตั้งค้างจ่ายไม่ได้เพราะบัญชีล้าง (2100) อยู่หมวดดำเนินงาน
    // แต่ตัวรายการอยู่หมวดลงทุน → ตอนจ่ายจริงยอดจะโผล่ผิดหมวดในงบกระแสเงินสด
    // หมวดใหม่ต้องได้คำตอบเดียวกัน ไม่งั้นสองบัญชีของเรื่องเดียวกันมีกฎไม่เท่ากัน
    const msg = /ยังตั้งค้างรับ-ค้างจ่ายไม่ได้/;
    expect(() => buildPosting({ ...buy("inv.buy_re_held_for_sale", 3_000_000), notYetPaid: true })).toThrow(msg);
    expect(() => buildPosting({ ...buy("inv.buy_re", 3_000_000), notYetPaid: true })).toThrow(msg);
  });

  it("ตัวเลขเท่ากับซื้อฝั่งเช่าเป๊ะ ต่างแค่บัญชีทรัพย์", () => {
    const held = allLines(buildPosting(buy("inv.buy_re_held_for_sale", 3_000_000)));
    const rental = allLines(buildPosting(buy("inv.buy_re", 3_000_000)));
    expect(held.find((l) => l.coaCode === "1520")!.debit).toBe(rental.find((l) => l.coaCode === "1500")!.debit);
    expect(held.find((l) => l.coaCode === "1100")!.credit).toBe(rental.find((l) => l.coaCode === "1100")!.credit);
  });
});

/* ================================================================== *
 * 2 · ยอดตั้งต้นลง 1520 ตรงได้
 * ================================================================== */

describe("2 · ยอดยกมาอสังหาฯ เพื่อขาย ลงบัญชี 1520 ตรง", () => {
  it("เดบิต 1520 · เครดิตกำไรสะสม (3300) · ไม่มีเงินสดและไม่มีบัญชีธนาคาร · สมดุล", () => {
    const ls = allLines(buildPosting(opening("opn.property_held_for_sale", 2_400_000)));
    assertBalanced(ls);
    expect(ls.find((l) => l.coaCode === "1520")).toMatchObject({ debit: 2_400_000, assetId: ASSET });
    expect(ls.find((l) => l.coaCode === "3300")!.credit).toBe(2_400_000);
    expect(ls.some((l) => l.coaCode === "1100")).toBe(false);
    expect(ls.every((l) => !l.bankAccountId)).toBe(true);
  });

  it("ไม่เข้างบกำไรขาดทุน และไม่เป็นกระแสเงินสดของงวด", () => {
    const ls = allLines(buildPosting(opening("opn.property_held_for_sale", 2_400_000)));
    expect(ls.filter((l) => /^[45]\d\d\d$/.test(l.coaCode))).toEqual([]);
    expect(ls.every((l) => l.cfCategory === "none" || l.cfCategory === undefined)).toBe(true);
  });

  it("ตัวเลขเท่ากับยอดยกมาฝั่งเช่าเป๊ะ ต่างแค่บัญชีทรัพย์", () => {
    const held = allLines(buildPosting(opening("opn.property_held_for_sale", 2_400_000)));
    const rental = allLines(buildPosting(opening("opn.property", 2_400_000)));
    expect(held.find((l) => l.coaCode === "1520")!.debit).toBe(rental.find((l) => l.coaCode === "1500")!.debit);
    expect(held.find((l) => l.coaCode === "3300")!.credit).toBe(rental.find((l) => l.coaCode === "3300")!.credit);
  });
});

/* ================================================================== *
 * 3 · ค่ารีโนเวทลงบนทรัพย์ที่อยู่ 1520 ได้ — **ข้อที่ห้ามพลาด**
 * ================================================================== */

describe("3 · ค่ารีโนเวท (1510) ลงบนทรัพย์ที่อยู่บัญชีเพื่อการขาย", () => {
  it("หมวดค่ารีโนเวทเดบิต 1510 เครดิตเงินสด — ไม่เอ่ยบัญชีอสังหาฯ ตัวใด จึงลงได้ทุกวัตถุประสงค์", () => {
    const ls = allLines(buildPosting(buy("inv.capex", 500_000)));
    assertBalanced(ls);
    expect(ls.find((l) => l.coaCode === "1510")).toMatchObject({ debit: 500_000, assetId: ASSET });
    expect(ls.find((l) => l.coaCode === "1100")!.credit).toBe(500_000);
    // ห้ามแตะบัญชีอสังหาฯ ทั้งสองตัว — ค่ารีโนเวทเกาะทรัพย์ด้วย asset_id
    for (const code of PROPERTY_COA) expect(ls.some((l) => l.coaCode === code), code).toBe(false);
  });

  it("**วงจรครบ** ซื้อ 3,000,000 → รีโนเวท 500,000 → ขาย 4,200,000 = กำไร 700,000", () => {
    const disposal = { costBasis: 3_500_000, renovationBasis: 500_000, salePrice: 4_200_000 };
    const ls = allLines(buildPosting(sell("inv.sell_re_held_for_sale", 4_200_000, disposal)));
    assertBalanced(ls);
    expect(ls.find((l) => l.coaCode === "1520")).toMatchObject({ credit: 3_000_000, assetId: ASSET });
    expect(ls.find((l) => l.coaCode === "1510")).toMatchObject({ credit: 500_000, assetId: ASSET });
    expect(ls.find((l) => l.coaCode === "4300")!.credit).toBe(700_000);
    expect(ls.find((l) => l.coaCode === "1100")!.debit).toBe(4_200_000);
  });

  it("ทั้งวงจรรวมกัน 1520 และ 1510 **กลับเป็นศูนย์ทั้งคู่** (ไม่มีทรัพย์ผี) และ 1500 ไม่เคยถูกแตะ", () => {
    const cycle = [
      buy("inv.buy_re_held_for_sale", 3_000_000),
      buy("inv.capex", 500_000),
      sell("inv.sell_re_held_for_sale", 4_200_000, { costBasis: 3_500_000, renovationBasis: 500_000, salePrice: 4_200_000 }),
    ];
    expect(net(cycle, "1520"), "ต้นทุนค้างในบัญชีของรอขาย = ทรัพย์ผี").toBe(0);
    expect(net(cycle, "1510"), "ค่ารีโนเวทค้าง = ทรัพย์ผี และกำไรสูงกว่าจริงเท่ายอดนี้").toBe(0);
    expect(net(cycle, "1500")).toBe(0);
    expect(net(cycle, "4300")).toBe(-700_000); // รายได้อยู่ฝั่งเครดิต
    expect(net(cycle, "1100")).toBe(700_000); // เงินสดเพิ่มสุทธิ = กำไร
  });

  it("วงจรฝั่งยอดตั้งต้น: ยกมา 1520 + ยกมารีโนเวท แล้วขาย → ศูนย์ทั้งคู่เหมือนกัน", () => {
    const cycle = [
      opening("opn.property_held_for_sale", 3_000_000),
      opening("opn.renovation", 500_000),
      sell("inv.sell_re_held_for_sale", 4_200_000, { costBasis: 3_500_000, renovationBasis: 500_000, salePrice: 4_200_000 }),
    ];
    expect(net(cycle, "1520")).toBe(0);
    expect(net(cycle, "1510")).toBe(0);
    expect(net(cycle, "1500")).toBe(0);
    expect(net(cycle, "4300")).toBe(-700_000);
  });

  it("ขายขาดทุนหลังรีโนเวทก็ลงได้ — ขาย 3,200,000 จากต้นทุน 3,500,000 = ขาดทุน 300,000", () => {
    const ls = allLines(
      buildPosting(sell("inv.sell_re_held_for_sale", 3_200_000, { costBasis: 3_500_000, renovationBasis: 500_000, salePrice: 3_200_000 }))
    );
    assertBalanced(ls);
    expect(ls.find((l) => l.coaCode === "5910")!.debit).toBe(300_000);
    expect(ls.find((l) => l.coaCode === "1520")!.credit).toBe(3_000_000);
    expect(ls.find((l) => l.coaCode === "1510")!.credit).toBe(500_000);
  });
});

/* ================================================================== *
 * 4 · เส้นทางเดิมต้องไม่เสีย และด่านต้องไม่หลวมลง
 * ================================================================== */

describe("4 · เคสเดิมยังผ่าน และด่านยังกันของที่ต้องกัน", () => {
  it("ซื้อ/ยกมา/ขาย ฝั่งเพื่อการเช่า (1500) ยังเหมือนเดิมทุกบรรทัด", () => {
    const cycle = [
      buy("inv.buy_re", 3_000_000),
      buy("inv.capex", 500_000),
      sell("inv.sell_re", 4_200_000, { costBasis: 3_500_000, renovationBasis: 500_000, salePrice: 4_200_000 }),
    ];
    expect(net(cycle, "1500")).toBe(0);
    expect(net(cycle, "1510")).toBe(0);
    expect(net(cycle, "1520")).toBe(0);
    expect(net(cycle, "4300")).toBe(-700_000);
  });

  it("หมวดที่ไม่ใช่อสังหาฯ ส่งค่ารีโนเวทมา → ยังถูกปฏิเสธ (ด่านไม่หลวมลง)", () => {
    expect(() =>
      buildPosting({
        typeKey: "invest_sell",
        subCode: "inv.sell_securities",
        ownerId: OWNER,
        bankAccountId: BANK,
        assetId: "stock-1",
        amount: 200,
        disposal: { costBasis: 100, renovationBasis: 50, salePrice: 200 },
      })
    ).toThrow(/ตัดค่ารีโนเวทสะสมไม่ได้/);
  });

  it("ค่ารีโนเวทมากกว่าต้นทุนที่ตัด → ปฏิเสธเหมือนฝั่งเช่า", () => {
    expect(() =>
      buildPosting(sell("inv.sell_re_held_for_sale", 200, { costBasis: 100, renovationBasis: 101, salePrice: 200 }))
    ).toThrow(PostingError);
  });

  it("ซื้อเข้า 1520 โดย **ไม่ส่งทรัพย์** → ปฏิเสธ (หมวดบังคับผูกทรัพย์เหมือนฝั่งเช่า)", () => {
    // เคส "ไม่ส่ง" ต้องมีจริง — เทสต์ที่ส่งข้อมูลครบเสมอจะไม่เคยแตะเส้นทางนี้ (บทเรียนข้อ 3)
    const withoutAsset: PostingInput = { ...buy("inv.buy_re_held_for_sale", 3_000_000), assetId: undefined };
    expect(() => buildPosting(withoutAsset)).toThrow(PostingError);
  });

  it("ยอดยกมา 1520 ที่ยอดเป็นศูนย์/ติดลบ → ปฏิเสธ ไม่ลงบรรทัดเปล่า", () => {
    expect(() => buildPosting(opening("opn.property_held_for_sale", 0))).toThrow(PostingError);
    expect(() => buildPosting(opening("opn.property_held_for_sale", -1))).toThrow(PostingError);
  });
});

/* ================================================================== *
 * 5 · MUTATION — ด่านค่ารีโนเวทอ่าน **ชุด** จริง
 *
 *   ถอด 1520 ออกจาก PROPERTY_COA แล้วใบขายที่ตัดค่ารีโนเวทต้องแดงทันที
 *   ถ้ายังเขียว แปลว่าเคสข้อ 3 ไม่ได้วัดสิ่งที่คิดว่าวัด
 *   (รูปเดียวกับ P5 ของ supabase/tests/zz_property_coa_set_test.sql)
 * ================================================================== */

describe("5 · เทสต์กลายพันธุ์ · ถอดบัญชีออกจากชุดแล้วเคสต้องแดง", () => {
  const withRenovation = () =>
    buildPosting(sell("inv.sell_re_held_for_sale", 4_200_000, { costBasis: 3_500_000, renovationBasis: 500_000, salePrice: 4_200_000 }));

  it("ถอด 1520 ออกจากชุด → ขาย 1520 พร้อมตัดค่ารีโนเวทถูกปฏิเสธทันที · คืนชุดแล้วผ่านอีกครั้ง", () => {
    expect(() => withRenovation(), "ของเดิมต้องผ่านก่อน ไม่งั้นเทสต์นี้แดงเพราะเหตุผลอื่น").not.toThrow();

    const set = PROPERTY_COA as unknown as string[];
    const at = set.indexOf("1520");
    expect(at, "ไม่มี 1520 ในชุดตั้งแต่ต้น").toBeGreaterThanOrEqual(0);
    set.splice(at, 1);
    try {
      expect(
        () => withRenovation(),
        "ถอด 1520 ออกจากชุดแล้วยังตัดค่ารีโนเวทได้ → ด่านไม่ได้อ่าน PROPERTY_COA จริง"
      ).toThrow(/ตัดค่ารีโนเวทสะสมไม่ได้/);
    } finally {
      set.splice(at, 0, "1520");
    }
    expect(() => withRenovation(), "คืนชุดไม่สำเร็จ").not.toThrow();
  });

  it("ถอด 1500 ออกจากชุด → ขายฝั่งเช่าพร้อมตัดค่ารีโนเวทก็แดงทันที (ด่านเดียวกันตัวเดียว)", () => {
    const rental = () =>
      buildPosting(sell("inv.sell_re", 4_200_000, { costBasis: 3_500_000, renovationBasis: 500_000, salePrice: 4_200_000 }));
    expect(() => rental()).not.toThrow();
    const set = PROPERTY_COA as unknown as string[];
    const at = set.indexOf("1500");
    set.splice(at, 1);
    try {
      expect(() => rental()).toThrow(/ตัดค่ารีโนเวทสะสมไม่ได้/);
    } finally {
      set.splice(at, 0, "1500");
    }
    expect(() => rental()).not.toThrow();
  });
});
