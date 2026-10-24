/**
 * ภาษีหัก ณ ที่จ่าย — ฝั่ง **engine** (D-111 ข้อ 1)
 *
 * ข้อที่สำคัญที่สุดของทั้งเรื่อง: **รายได้ต้องเป็นยอดเต็ม · เงินสดเป็นยอดสุทธิ**
 * และต้องมี **ด่านจับ** ถ้าใครกรอกยอดสุทธิลงช่องจำนวนเงิน ไม่ใช่เขียนไว้ในคู่มือ
 *
 * เคส "ไม่ส่งข้อมูล" อยู่ครบทุกช่องโดยตั้งใจ — เทสต์ที่ส่งข้อมูลครบเสมอ
 * จะไม่มีวันแตะเส้นทางที่ข้อมูลขาด (บทเรียน mace-windu ข้อ 3)
 */

import { describe, it, expect } from "vitest";
import { buildPosting as buildPostingWith, buildPostingDraft as buildPostingDraftWith, allLines, assertBalanced } from "../posting";
import { PostingError, type PostingInput, type PostingLine } from "../types";
import { WHT_COA, isCashAccount } from "@/lib/rules/coa";
import { statementOf } from "@/lib/rules/statements";
import { TX_TYPES, whtEligibleSubs } from "@/lib/rules/tx-rules";
import { EVIDENCE, TEST_RESOLVER } from "./fixture-resolver";

const buildPosting = (i: PostingInput) => buildPostingWith(i, TEST_RESOLVER);
const buildPostingDraft = (i: PostingInput) => buildPostingDraftWith(i, TEST_RESOLVER);

/** ค่าเช่า 100,000 ถูกหัก 5% = 5,000 เงินเข้า 95,000 (ฝั่งบุคคล ไม่ต้องแนบเอกสาร) */
const rent = (over: Partial<PostingInput> = {}): PostingInput => ({
  typeKey: "income",
  subCode: "inc.rent",
  amount: 100_000,
  ownerId: "thanakorn",
  bankAccountId: "b4",
  assetId: "rent1",
  contactId: "c1",
  wht: { rate: 5, amount: 5_000, certificateNo: "WHT-2569-0001" },
  ...over,
});

const net = (lines: PostingLine[], code: string) =>
  lines.filter((l) => l.coaCode === code).reduce((a, l) => a + l.debit - l.credit, 0);

const expectRejected = (input: PostingInput, pattern: RegExp) => {
  let thrown: unknown;
  try {
    buildPosting(input);
  } catch (e) {
    thrown = e;
  }
  expect(thrown, "ต้องถูกปฏิเสธ แต่ผ่านไปได้").toBeInstanceOf(PostingError);
  expect((thrown as Error).message).toMatch(pattern);
};

describe("คู่บัญชีสามบรรทัด: เงินสดสุทธิ + ภาษีถูกหัก = รายได้เต็มจำนวน", () => {
  it("ลงสามบรรทัดตามที่ D-111 กำหนด และสมดุล", () => {
    const lines = allLines(buildPosting(rent()));
    assertBalanced(lines);
    expect(lines).toHaveLength(3);

    const cash = lines.find((l) => l.coaCode === "1100")!;
    const wht = lines.find((l) => l.coaCode === WHT_COA)!;
    const income = lines.find((l) => l.coaCode === "4200")!;

    expect(cash.debit, "เงินสดต้องเป็นยอดสุทธิที่เข้าบัญชีจริง").toBe(95_000);
    expect(wht.debit, "ภาษีที่ถูกหักเป็นสินทรัพย์ฝั่งเดบิต").toBe(5_000);
    expect(income.credit, "**รายได้ต้องเป็นยอดเต็ม**").toBe(100_000);
  });

  it("ภาษีที่ถูกหักเป็น **สินทรัพย์ในงบดุล** ไม่ใช่ค่าใช้จ่าย", () => {
    const lines = allLines(buildPosting(rent()));
    expect(statementOf(WHT_COA).statement).toBe("BS");
    // ไม่มีบรรทัดค่าใช้จ่ายเพิ่มมาจากการถูกหักภาษี
    const plLines = lines.filter((l) => statementOf(l.coaCode).statement === "PL");
    expect(plLines).toHaveLength(1);
    expect(plLines[0].coaCode).toBe("4200");
  });

  it("บรรทัดภาษี **ไม่ผูกบัญชีธนาคาร** (ไม่ใช่บรรทัดเงินสด)", () => {
    const wht = allLines(buildPosting(rent())).find((l) => l.coaCode === WHT_COA)!;
    expect(isCashAccount(WHT_COA)).toBe(false);
    // ด่าน fn_assert_line_bank_owner ฝั่ง DB ปฏิเสธบรรทัดที่ไม่ใช่เงินสดแต่มีบัญชีติดมา
    expect(wht.bankAccountId).toBeUndefined();
  });

  it("บรรทัดภาษี **ไม่ผูกทรัพย์** — ไม่งั้นต้นทุนทรัพย์บวมและกำไรจากการขายผิด", () => {
    const wht = allLines(buildPosting(rent())).find((l) => l.coaCode === WHT_COA)!;
    // fn_asset_cost_basis() รวมทุกบรรทัดบัญชีสินทรัพย์ที่ผูกทรัพย์เป็นต้นทุน
    // ผูกที่นี่ = ต้นทุนคอนโดโตขึ้น 5,000 ทุกเดือนที่เก็บค่าเช่า
    expect(wht.assetId, "ผูกทรัพย์กับบรรทัดภาษี = ต้นทุน FIFO เพี้ยน").toBeUndefined();
  });

  it("เงินสดเข้างบกระแสเงินสดแค่ยอดสุทธิ — ตรงกับ statement ของธนาคาร", () => {
    const lines = allLines(buildPosting(rent()));
    const cashTotal = lines
      .filter((l) => isCashAccount(l.coaCode))
      .reduce((a, l) => a + l.debit - l.credit, 0);
    expect(cashTotal).toBe(95_000);
  });

  it("ใช้ได้กับทุกหมวดที่ตารางกฎบอกว่าหักได้ — ไม่ใช่แค่ค่าเช่า", () => {
    const eligible = whtEligibleSubs();
    expect(eligible.length).toBeGreaterThan(1);
    for (const s of eligible) {
      // **อ่านประเภทจากตารางกฎ ไม่ใช่สมมติว่าเป็น "income"** — หมวดที่หักได้
      // มีทั้งฝั่งรายได้และฝั่ง "รับชำระค้างรับ" (ลงทุน/ขาย-รับคืน) ตาม D-111 ข้อ 1
      // ถ้าสมมติประเภทไว้ตัวเดียว เคสนี้จะพังทันทีที่เส้นทางที่สองเปิด
      // แล้วเราจะไม่ได้ทดสอบมันเลย
      const key = TX_TYPES.find((t) => t.subs.some((x) => x.code === s.code))!.key;
      const lines = allLines(
        buildPosting(rent({ typeKey: key, subCode: s.code, amount: 10_000, wht: { rate: 3, amount: 300 } }))
      );
      assertBalanced(lines);
      expect(net(lines, WHT_COA), `${s.code} ยอดภาษีไม่ได้ลง 1800`).toBe(300);
      expect(net(lines, s.cr), `${s.code} เงินได้ไม่เต็มจำนวน`).toBe(-10_000);
      expect(net(lines, "1100"), `${s.code} เงินสดต้องเป็นยอดสุทธิ`).toBe(9_700);
    }
  });

  /**
   * **ข้อ 3 ของผู้ตรวจ** — ค่าเช่าที่ตั้งค้างรับไว้แล้วถูกหักภาษีตอนผู้เช่าจ่าย
   *
   * ลูกหนี้ต้องปิด **ยอดเต็ม** 100,000 ด้วยเงินสด 95,000 + ภาษี 5,000
   * ถ้าปิดแค่ 95,000 ลูกหนี้จะค้าง 5,000 ตลอดไป เพราะไม่มีใครมาจ่ายส่วนนั้นอีก
   */
  it("รับชำระค่าเช่าค้างรับที่ถูกหักภาษี → ปิดลูกหนี้ยอดเต็ม ไม่เหลือเศษ", () => {
    const lines = allLines(
      buildPosting(
        rent({
          typeKey: "invest_sell",
          subCode: "inv.collect_rent",
          amount: 100_000,
          wht: { rate: 5, amount: 5_000, certificateNo: "WHT-2569-0009" },
        })
      )
    );
    assertBalanced(lines);
    expect(lines).toHaveLength(3);
    expect(net(lines, "1100"), "เงินสดต้องเป็นยอดสุทธิที่เข้าบัญชีจริง").toBe(95_000);
    expect(net(lines, WHT_COA), "ภาษีที่ถูกหักเป็นสินทรัพย์รอเครดิต").toBe(5_000);
    expect(net(lines, "1200"), "ลูกหนี้ค่าเช่าต้องถูกปิดยอดเต็ม").toBe(-100_000);
    // **ไม่มีบรรทัดรายได้** — รายได้รับรู้ไปแล้วตอนตั้งค้าง ถ้ามีจะนับซ้ำ
    expect(lines.filter((l) => statementOf(l.coaCode).statement === "PL")).toEqual([]);
  });

  it("ไม่ส่งข้อมูลการหักภาษีมาเลย = ลงเงินสดเต็มจำนวนตามปกติ (ค่าตั้งต้นที่ถูก)", () => {
    const lines = allLines(buildPosting(rent({ wht: undefined })));
    expect(lines).toHaveLength(2);
    expect(net(lines, "1100")).toBe(100_000);
    expect(net(lines, WHT_COA)).toBe(0);
  });
});

/**
 * ด่านใจกลาง — **ยอดรายได้ต้องเป็นยอดเต็ม**
 *
 * เคสที่เป็นธรรมชาติที่สุดคือคนเปิด statement เห็นเงินเข้า 95,000 แล้วกรอก 95,000
 * พร้อมแนบใบรับรองที่บอกว่าถูกหัก 5,000 · ถ้าปล่อยผ่าน: รายได้ขาดไป 5,000
 * ใบยังสมดุล (95,000 + 5,000 = 100,000 ... ไม่ใช่ 95,000) — จริงๆ ถ้าปล่อยผ่าน
 * ระบบจะลงเงินสด 90,000 ด้วยซ้ำ ซึ่งไม่ตรง statement แล้วกระทบยอดไม่ลง
 */
describe("ด่านจับคนที่กรอกยอดสุทธิแทนยอดเต็ม", () => {
  it("กรอกยอดสุทธิ 95,000 แต่ถูกหัก 5,000 → ปฏิเสธ พร้อมบอกยอดเต็มที่ควรเป็น", () => {
    let thrown: unknown;
    try {
      buildPosting(rent({ amount: 95_000 }));
    } catch (e) {
      thrown = e;
    }
    expect(thrown).toBeInstanceOf(PostingError);
    const msg = (thrown as Error).message;
    expect(msg, "ต้องบอกว่าต้องเป็นยอดเต็ม").toMatch(/ยอดเต็ม/);
    // 5% ของ 95,000 = 4,750 ไม่ใช่ 5,000
    expect(msg).toMatch(/4750|4,750/);
    // และต้องบอกยอดเต็มที่ควรกรอก (5,000 / 5% = 100,000)
    expect(msg).toMatch(/100000|100,000/);
  });

  it("ยอดที่หักไม่ตรงกับอัตราในทุกรูปแบบ → ปฏิเสธ", () => {
    for (const wht of [
      { rate: 5, amount: 3_000 }, // ใบรับรองกับอัตราไม่ตรงกัน
      { rate: 3, amount: 5_000 },
      { rate: 1, amount: 5_000 },
    ]) {
      expectRejected(rent({ wht }), /ยอดเต็ม/);
    }
  });

  it("ยอมคลาดได้ 1 สตางค์ (ใบรับรองที่ปัดเศษ) แต่ไม่มากกว่านั้น", () => {
    // 3% ของ 33,333.33 = 999.9999 → 1,000.00 ในใบรับรอง
    expect(() => buildPosting(rent({ amount: 33_333.33, wht: { rate: 3, amount: 1_000 } }))).not.toThrow();
    expectRejected(rent({ amount: 33_333.33, wht: { rate: 3, amount: 1_000.5 } }), /ยอดเต็ม/);
  });
});

describe("เคสข้อมูลขาด — ต้องปฏิเสธ ไม่ใช่เดา", () => {
  it("ไม่ส่งอัตราที่หัก → ปฏิเสธ (ไม่ใช่คำนวณอัตราย้อนกลับจากยอด)", () => {
    expectRejected(
      rent({ wht: { amount: 5_000 } as NonNullable<PostingInput["wht"]> }),
      /อัตราภาษีหัก ณ ที่จ่าย/
    );
  });

  it("ไม่ส่งยอดที่ถูกหัก → ปฏิเสธ (ไม่ใช่คำนวณจากอัตราแล้วลงให้เอง)", () => {
    // ถ้าคำนวณให้เอง ยอดในสมุดจะไม่ตรงใบรับรองที่ปัดเศษ แล้วขอคืนไม่ได้
    expectRejected(
      rent({ wht: { rate: 5 } as NonNullable<PostingInput["wht"]> }),
      /ยอดภาษีที่ถูกหัก|ต้องเป็นตัวเลขที่ระบุได้/
    );
  });

  it("อัตรา 0 · ติดลบ · เกิน 100 → ปฏิเสธ", () => {
    expectRejected(rent({ wht: { rate: 0, amount: 5_000 } }), /อัตราภาษีหัก ณ ที่จ่าย/);
    expectRejected(rent({ wht: { rate: -5, amount: 5_000 } }), /ติดลบ|อัตราภาษี/);
    expectRejected(rent({ wht: { rate: 150, amount: 5_000 } }), /อัตราภาษีหัก ณ ที่จ่าย/);
  });

  it("ยอดที่หัก 0 หรือติดลบ → ปฏิเสธ", () => {
    expectRejected(rent({ wht: { rate: 5, amount: 0 } }), /มากกว่า 0/);
    expectRejected(rent({ wht: { rate: 5, amount: -5_000 } }), /ติดลบ/);
  });

  it("ยอดที่หักเท่าหรือมากกว่ายอดเต็ม → ปฏิเสธ (กรอกสลับช่อง)", () => {
    expectRejected(rent({ wht: { rate: 5, amount: 100_000 } }), /น้อยกว่ายอดรายได้เต็มจำนวน/);
    expectRejected(rent({ wht: { rate: 5, amount: 200_000 } }), /น้อยกว่ายอดรายได้เต็มจำนวน/);
  });

  it("ยอดที่หักเป็น NaN/Infinity → ปฏิเสธ ไม่ใช่ลงบรรทัดที่คำนวณต่อไม่ได้", () => {
    expectRejected(rent({ wht: { rate: 5, amount: Number.NaN } }), /ระบุได้/);
    expectRejected(rent({ wht: { rate: Number.POSITIVE_INFINITY, amount: 5_000 } }), /ระบุได้/);
  });
});

describe("หมวดที่หักภาษีไม่ได้ ส่งข้อมูลการหักมา → ปฏิเสธ ไม่ใช่เมินทิ้ง", () => {
  it("ค่าใช้จ่าย · รับคืนเงินต้น · โอน · ตีราคา → ปฏิเสธทุกตัว", () => {
    const cases: PostingInput[] = [
      { typeKey: "expense", subCode: "exp.repair", amount: 100_000, ownerId: "thanakorn", bankAccountId: "b4", assetId: "rent1", contactId: "c1", wht: { rate: 5, amount: 5_000 } },
      { typeKey: "invest_sell", subCode: "inv.srr_redeem", amount: 100_000, ownerId: "thanakorn", bankAccountId: "b4", assetId: "rent1", contactId: "c1", repayment: { principal: 90_000, interest: 10_000 }, wht: { rate: 5, amount: 5_000 } },
      { typeKey: "transfer", subCode: "trf.internal", amount: 100_000, ownerId: "thanakorn", bankAccountId: "b4", transferToBankAccountId: "b4b", wht: { rate: 5, amount: 5_000 } },
      { typeKey: "adjust", subCode: "adj.revalue_securities_up", amount: 100_000, ownerId: "thanakorn", assetId: "rent1", wht: { rate: 5, amount: 5_000 }, revaluation: { currency: "USD", rateToThb: 36.5, valueOriginal: 1_000, valueThb: 36_500 } },
      { typeKey: "invest_sell", subCode: "inv.wht_refund", amount: 5_000, ownerId: "thanakorn", bankAccountId: "b4", contactId: "c1", wht: { rate: 5, amount: 250 } },
    ];
    for (const input of cases) {
      expectRejected(input, /ถูกหักภาษี ณ ที่จ่ายไม่ได้/);
    }
  });

  it("ปฏิเสธที่ draft ด้วย — ไม่ใช่รอให้ถึงตอนกดบันทึกแล้วพรีวิวโชว์บรรทัดผิด", () => {
    expect(() =>
      buildPostingDraft({
        typeKey: "expense",
        subCode: "exp.repair",
        amount: 100_000,
        ownerId: "thanakorn",
        bankAccountId: "b4",
        assetId: "rent1",
        wht: { rate: 5, amount: 5_000 },
      })
    ).toThrow(PostingError);
  });
});

describe("ตั้งค้างรับพร้อมถูกหักภาษี → ปฏิเสธ", () => {
  it("ยังไม่ได้รับเงิน = ยังไม่มีใครหักภาษี (ใบรับรองออกตอนจ่ายจริง)", () => {
    // ปล่อยผ่าน = ได้สินทรัพย์ภาษีจากเหตุการณ์ที่ยังไม่เกิด แล้วตอนเงินเข้าจริง
    // จะหักอีกรอบ = เครดิตภาษีสองเท่าของที่ถูกหักจริง
    expectRejected(rent({ notYetPaid: true, bankAccountId: undefined }), /ยังไม่ได้รับเงิน/);
  });
});

describe("ใบรับรองการหักภาษี — กติกาเอกสาร ไม่ใช่กติกาบัญชี", () => {
  const corp = (over: Partial<PostingInput> = {}): PostingInput =>
    rent({ ownerId: "corp", bankAccountId: "b1", attachments: EVIDENCE, ...over });

  it("นิติบุคคลไม่ใส่เลขที่ใบรับรอง → บันทึกจริงไม่ได้", () => {
    expectRejected(corp({ wht: { rate: 5, amount: 5_000 } }), /ใบรับรองการหักภาษี/);
    expectRejected(corp({ wht: { rate: 5, amount: 5_000, certificateNo: "   " } }), /ใบรับรองการหักภาษี/);
  });

  it("นิติบุคคลใส่เลขที่ใบรับรองครบ → ผ่าน", () => {
    const lines = allLines(buildPosting(corp()));
    assertBalanced(lines);
    expect(net(lines, "4200")).toBe(-100_000);
    const wht = lines.find((l) => l.coaCode === WHT_COA)!;
    expect(wht.memo, "เลขที่ใบรับรองต้องติดไปกับบรรทัด").toMatch(/WHT-2569-0001/);
  });

  it("พรีวิวแสดงบรรทัดได้ก่อนหาใบรับรอง — เลขที่ใบไม่เปลี่ยนคู่บัญชี", () => {
    const draft = buildPostingDraft(corp({ wht: { rate: 5, amount: 5_000 } }));
    const lines = allLines(draft);
    expect(lines).toHaveLength(3);
    assertBalanced(lines);
  });

  it("ฝั่งบุคคลไม่บังคับเลขที่ใบรับรอง (ได้ใบมาทีหลังได้)", () => {
    expect(() => buildPosting(rent({ wht: { rate: 5, amount: 5_000 } }))).not.toThrow();
  });

  it("รายการที่ไม่ได้ถูกหักภาษี ไม่ถูกบังคับช่องใบรับรอง", () => {
    expect(() => buildPosting(corp({ wht: undefined }))).not.toThrow();
  });
});

/**
 * เดินสองขั้นจริง — ตั้งยอดเครดิตภาษี แล้วล้าง
 * ถ้าล้างไม่หมด ยอดใน 1800 จะค้างตลอดไปและไม่มีใครรู้ว่าเครดิตเหลือเท่าไร
 */
describe("ล้างยอดเครดิตภาษีได้จริง และกลับเป็นศูนย์", () => {
  it("ถูกหัก 5,000 → ขอคืน 5,000 → ยอดใน 1800 เป็นศูนย์", () => {
    const step1 = allLines(buildPosting(rent()));
    const step2 = allLines(
      buildPosting({
        typeKey: "invest_sell",
        subCode: "inv.wht_refund",
        amount: 5_000,
        ownerId: "thanakorn",
        bankAccountId: "b4",
        contactId: "c1",
      })
    );
    expect(net(step1, WHT_COA)).toBe(5_000);
    expect(net(step2, WHT_COA)).toBe(-5_000);
    expect(net(step1, WHT_COA) + net(step2, WHT_COA), "ล้างไม่หมด").toBe(0);
  });

  it("ขั้นล้างลงกระแสเงินสดหมวดดำเนินงาน เหมือนรายการต้นทาง", () => {
    const step2 = allLines(
      buildPosting({
        typeKey: "invest_sell",
        subCode: "inv.wht_refund",
        amount: 5_000,
        ownerId: "thanakorn",
        bankAccountId: "b4",
        contactId: "c1",
      })
    );
    for (const l of step2.filter((x) => isCashAccount(x.coaCode))) {
      expect(l.cfCategory).toBe("operating");
      expect(l.bankAccountId).toBe("b4");
    }
  });

  it("ขั้นล้างไม่แตะงบกำไรขาดทุน — รายได้รับรู้ไปแล้วตอนถูกหัก", () => {
    const step2 = allLines(
      buildPosting({
        typeKey: "invest_sell",
        subCode: "inv.wht_refund",
        amount: 5_000,
        ownerId: "thanakorn",
        bankAccountId: "b4",
        contactId: "c1",
      })
    );
    expect(step2.filter((l) => statementOf(l.coaCode).statement === "PL")).toHaveLength(0);
  });
});
