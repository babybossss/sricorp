/**
 * เงินฝากสกุลต่างประเทศ (FCD) ที่ **ชั้นเครื่องยนต์** — เส้นทางที่ผู้ตรวจ BLOCK
 *
 * ทั้งสามข้อที่ถูก BLOCK หลุดด้วยเหตุเดียวกัน: **เทสต์รอบก่อนส่งข้อมูลครบทุกเคส**
 * จึงไม่เคยแตะเส้นทางที่ข้อมูลขาด (บทเรียน mace-windu ข้อ 3) · ไฟล์นี้เริ่มจาก
 * เคส "ไม่ส่งข้อมูล" ก่อนทุกครั้ง แล้วจึงตรวจบรรทัดที่สร้างได้
 *
 * ตัวเลขที่วัดได้ **ก่อนแก้** (ของจริงบน PG16 + เครื่องยนต์เดิม):
 *   - `trf.fx_convert` มีธง `transferTarget` → ตกไปเส้นทางโอนธรรมดา สร้างแค่
 *     สองบรรทัดเงินสดเท่ากัน · **ไม่มีบรรทัด 4330/5930 · ไม่มีบรรทัดล้าง 3410
 *     และไม่มีข้อมูลอัตราเลย** → การแลก 10,000 USD ที่ 36.50 ซึ่งขาดทุนจริง
 *     5,000 บาท (ยอดตามบัญชี 370,000 − บาทที่ได้ 365,000) แสดงผลเป็น **0**
 *   - `trf.fx_translate_up` ลงบน **บัญชีบาท** ได้ → เงินสดโผล่จากอากาศ
 *     (วัดบนฐานข้อมูล: บัญชีบาทจาก −36,500 เป็น 963,500)
 *   - ขา 3410 ไม่มีสกุลกำกับ → ด่านล้างผลต่างมองไม่เห็น แล้วกำไรถูกนับสองครั้ง
 */

import { describe, it, expect } from "vitest";
import { buildPosting as buildPostingWith, allLines, totalDebit, totalCredit } from "../posting";
import { previewPosting } from "../preview";
import { PostingError, type PostingInput, type PostingLine } from "../types";
import { TEST_RESOLVER } from "./fixture-resolver";

const buildPosting = (input: PostingInput) => buildPostingWith(input, TEST_RESOLVER);

const FCD = "b4usd"; // ธนากร · บัญชี USD
const THB = "b4b"; //   ธนากร · บัญชีบาท
const UNKNOWN = "b4x"; // resolver ไม่บอกสกุล — ห้ามตีเป็นบาท
const OTHER_USD = "b5usd"; // ธนวินท์ · บัญชี USD

/** แปลงค่าขึ้น 10,000 USD จาก 36.50 เป็น 37.00 = ผลต่าง 5,000 บาท */
const translateUp = (over: Partial<PostingInput> = {}): PostingInput => ({
  typeKey: "transfer",
  subCode: "trf.fx_translate_up",
  amount: 5_000,
  ownerId: "thanakorn",
  bankAccountId: FCD,
  fxTranslation: {
    currency: "USD",
    balanceOriginal: 10_000,
    bookRateToThb: 36.5,
    bookRateDate: "2026-10-31",
    newRateToThb: 37,
    newRateDate: "2026-11-30",
  },
  ...over,
});

/** แลก 10,000 USD (ยอดตามบัญชี 37.00) เป็นบาทที่ 36.50 → **ขาดทุนจริง 5,000** */
const convertAtLoss = (over: Partial<PostingInput> = {}): PostingInput => ({
  typeKey: "transfer",
  subCode: "trf.fx_convert",
  amount: 365_000,
  ownerId: "thanakorn",
  bankAccountId: FCD,
  transferToBankAccountId: THB,
  fxConversion: {
    currency: "USD",
    amountOriginal: 10_000,
    balanceOriginalBefore: 10_000,
    bookRateToThb: 37,
    bookRateDate: "2026-11-30",
    dealRateToThb: 36.5,
    dealRateDate: "2026-12-31",
    unrealizedBefore: 0,
  },
  ...over,
});

const lineOf = (lines: PostingLine[], code: string) => lines.filter((l) => l.coaCode === code);
const fail = (input: PostingInput): string => {
  try {
    buildPosting(input);
  } catch (e) {
    expect(e).toBeInstanceOf(PostingError);
    return (e as Error).message;
  }
  throw new Error("คำสั่งนี้ควรถูกปฏิเสธ แต่สร้างบรรทัดสำเร็จ");
};

describe("ข้อมูลไม่ครบ — ต้องปฏิเสธ ห้ามเดา (เขียนก่อนแก้โค้ด)", () => {
  it("หมวดแปลงค่า แต่ไม่ส่งข้อมูลอัตราเลย", () => {
    const input = translateUp();
    delete input.fxTranslation;
    expect(fail(input)).toMatch(/ต้องระบุสกุลเงิน ยอดเงินตราคงเหลือ อัตราตามบัญชี/);
  });

  it("หมวดแลกเงิน แต่ไม่ส่งข้อมูลการแลกเลย", () => {
    const input = convertAtLoss();
    delete input.fxConversion;
    expect(fail(input)).toMatch(/ต้องระบุจำนวนเงินตราที่แลก/);
  });

  for (const field of [
    "bookRateToThb",
    "bookRateDate",
    "newRateToThb",
    "newRateDate",
    "balanceOriginal",
  ] as const) {
    it(`แปลงค่าโดยไม่ส่ง ${field} → ปฏิเสธ (ไม่ใช่เดาเป็น 1 หรือ 0)`, () => {
      const input = translateUp();
      delete (input.fxTranslation as Record<string, unknown>)[field];
      expect(() => buildPosting(input)).toThrow(PostingError);
    });
  }

  for (const field of [
    "amountOriginal",
    "balanceOriginalBefore",
    "bookRateToThb",
    "bookRateDate",
    "dealRateToThb",
    "dealRateDate",
    "unrealizedBefore",
  ] as const) {
    it(`แลกเงินโดยไม่ส่ง ${field} → ปฏิเสธ`, () => {
      const input = convertAtLoss();
      delete (input.fxConversion as Record<string, unknown>)[field];
      expect(() => buildPosting(input)).toThrow(PostingError);
    });
  }

  it("บัญชีที่ resolver **ไม่บอกสกุล** → ปฏิเสธ ห้ามตีเป็นบาทหรือเป็น USD เงียบๆ", () => {
    expect(fail(translateUp({ bankAccountId: UNKNOWN }))).toMatch(/ไม่ทราบสกุลเงินของบัญชี/);
  });

  it("ไม่ส่งบัญชีเลย → ข้อความเดียวกับทุกหมวด (ไม่ใช่ประโยคของเส้นทางนี้เอง)", () => {
    expect(fail(translateUp({ bankAccountId: undefined }))).toBe(
      "ต้องระบุบัญชีธนาคารที่เงินเข้าหรือออก"
    );
  });

  it("สกุลที่กรอกไม่ตรงกับสกุลของบัญชี → ปฏิเสธ (ความจริงอยู่ที่บัญชี)", () => {
    const input = translateUp({ bankAccountId: "b4jpy" });
    expect(fail(input)).toMatch(/เป็นบัญชีสกุล JPY แต่รายการระบุสกุล USD/);
  });

  it("สกุลนอกชุดที่อนุญาต → ปฏิเสธผ่านชุดสกุลเงินชุดเดียวของระบบ", () => {
    const input = translateUp();
    input.fxTranslation!.currency = "EUR";
    expect(() => buildPosting(input)).toThrow(PostingError);
  });

  it("ส่งข้อมูลการแปลงค่ามากับหมวดที่ไม่ใช่เรื่องค่าเงิน → ปฏิเสธ ไม่ใช่เมินทิ้ง", () => {
    expect(
      fail({
        typeKey: "income",
        subCode: "inc.rent",
        amount: 12_000,
        ownerId: "thanakorn",
        bankAccountId: "b4",
        assetId: "rent1",
        contactId: "c1",
        fxTranslation: translateUp().fxTranslation,
      })
    ).toMatch(/ไม่ใช่การแปลงค่าเงินฝากสกุลต่างประเทศ/);
  });

  it("ส่งข้อมูลการแลกเงินมากับหมวดโอนธรรมดา → ปฏิเสธ", () => {
    expect(
      fail({
        typeKey: "transfer",
        subCode: "trf.internal",
        amount: 1_000,
        ownerId: "thanakorn",
        bankAccountId: "b4",
        transferToBankAccountId: THB,
        fxConversion: convertAtLoss().fxConversion,
      })
    ).toMatch(/ไม่ใช่การแลกเงินตราเป็นบาท/);
  });
});

describe("BLOCK 2 — แปลงค่าบนบัญชีบาท คือการสร้างเงินสดจากอากาศ", () => {
  it("บัญชีบาท → ปฏิเสธ (ก่อนแก้: ลงได้ และบัญชีบาทเพิ่มขึ้น 1,000,000)", () => {
    expect(fail(translateUp({ bankAccountId: THB }))).toMatch(
      /เป็นบัญชีบาท จึงลงการแปลงค่า/
    );
  });

  it("ทิศของหมวดต้องตรงกับทิศของอัตรา — ขึ้นแต่อัตราลง → ปฏิเสธ", () => {
    const input = translateUp();
    input.fxTranslation!.newRateToThb = 36; // ต่ำกว่าอัตราตามบัญชี
    input.amount = 5_000;
    expect(fail(input)).toMatch(/ใช้กับการที่ยอดบาทเพิ่ม แต่อัตราที่ระบุทำให้ยอดบาทลด/);
  });

  it("อัตราเท่ากันสองวัน → ไม่มีผลต่าง ปฏิเสธ (ห้ามมีใบเปล่าในสมุด)", () => {
    const input = translateUp();
    input.fxTranslation!.newRateToThb = 36.5;
    expect(fail(input)).toMatch(/ไม่มีผลต่างให้ลง/);
  });

  it("ยอดที่กรอกไม่เท่ากับผลต่างที่คิดจากอัตรา → ปฏิเสธ แม้ต่างสตางค์เดียว", () => {
    expect(fail(translateUp({ amount: 5_000.01 }))).toMatch(/ผลต่างจากการแปลงค่าคือ 5,000 บาท/);
  });
});

describe("BLOCK 1 — ทุกขาของใบแปลงค่าต้องมีสกุลกำกับ รวมขา 3410", () => {
  it("สร้างสองบรรทัด: เงินสด FCD เดบิต · 3410 เครดิต · ทั้งคู่มีสกุล/อัตรา/วันครบ", () => {
    const lines = allLines(buildPosting(translateUp()));
    expect(lines).toHaveLength(2);
    expect(totalDebit(lines)).toBe(totalCredit(lines));

    const cash = lineOf(lines, "1100")[0];
    expect(cash.debit).toBe(5_000);
    expect(cash.bankAccountId).toBe(FCD);
    expect(cash.currency).toBe("USD");
    // **ไม่มีเงินตราเคลื่อน** — จำนวน USD เท่าเดิม เปลี่ยนแต่ยอดบาท
    expect(cash.amountOriginal).toBe(0);
    expect(cash.fxRate).toBe(37);
    expect(cash.fxRateDate).toBe("2026-11-30");

    const diff = lineOf(lines, "3410")[0];
    expect(diff.credit).toBe(5_000);
    expect(diff.bankAccountId).toBeUndefined();
    // ขา 3410 ไม่มีบัญชีธนาคารให้อ้าง สกุลบนบรรทัดคือตัวเดียวที่บอกว่าเป็นของสกุลไหน
    expect(diff.currency, "ขา 3410 ต้องมีสกุล ไม่งั้นด่านล้างผลต่างมองไม่เห็น").toBe("USD");
    expect(diff.amountOriginal).toBe(0);
    expect(diff.fxRate).toBe(37);
    expect(diff.fxRateDate).toBe("2026-11-30");
  });

  it("ไม่แตะงบกำไรขาดทุนเลย และไม่เข้างบกระแสเงินสด", () => {
    const lines = allLines(buildPosting(translateUp()));
    expect(lines.every((l) => l.cfCategory === "none")).toBe(true);
    expect(lines.some((l) => /^[45]/.test(l.coaCode))).toBe(false);
  });

  it("แปลงค่าลง: 3410 เดบิต · เงินสด FCD เครดิต · ยังไม่แตะ P&L", () => {
    const lines = allLines(
      buildPosting({
        ...translateUp(),
        subCode: "trf.fx_translate_down",
        amount: 5_000,
        fxTranslation: {
          currency: "USD",
          balanceOriginal: 10_000,
          bookRateToThb: 37,
          bookRateDate: "2026-11-30",
          newRateToThb: 36.5,
          newRateDate: "2026-12-31",
        },
      })
    );
    expect(lineOf(lines, "3410")[0].debit).toBe(5_000);
    expect(lineOf(lines, "1100")[0].credit).toBe(5_000);
    expect(lineOf(lines, "1100")[0].currency).toBe("USD");
    expect(lines.some((l) => /^[45]/.test(l.coaCode))).toBe(false);
  });
});

describe("BLOCK 3 — การแลกเงินต้องสร้างบรรทัดกำไร/ขาดทุนและบรรทัดล้างผลต่างให้ครบ", () => {
  it("แลกขาดทุน 5,000 (ก่อนแก้โชว์ 0) — ขาดทุนเข้า 5930 เต็มจำนวน", () => {
    const lines = allLines(buildPosting(convertAtLoss()));
    expect(totalDebit(lines)).toBe(totalCredit(lines));

    expect(lineOf(lines, "1100").find((l) => l.bankAccountId === THB)?.debit).toBe(365_000);
    const out = lineOf(lines, "1100").find((l) => l.bankAccountId === FCD)!;
    expect(out.credit, "ตัดเงินตราออกตามอัตราตามบัญชี ไม่ใช่อัตราที่แลกได้").toBe(370_000);
    expect(out.currency).toBe("USD");
    expect(out.amountOriginal).toBe(10_000);
    expect(out.fxRate).toBe(37);

    const loss = lineOf(lines, "5930")[0];
    expect(loss, "ก่อนแก้ไม่มีบรรทัดนี้เลย ขาดทุน 5,000 จึงแสดงเป็น 0").toBeDefined();
    expect(loss.debit).toBe(5_000);
    expect(lineOf(lines, "4330")).toHaveLength(0);
    expect(lineOf(lines, "3410"), "ไม่มีผลต่างค้างอยู่ จึงไม่มีอะไรต้องล้าง").toHaveLength(0);
  });

  it("แลกได้กำไร พร้อมล้างผลต่างที่ค้างทั้งก้อน → 3410 ออกหมดในใบเดียวกัน", () => {
    // ซื้อที่ 36.50 (ต้นทุน 365,000) · แปลงค่าขึ้นเป็น 37.00 (3410 = 5,000)
    // แลกหมดที่ 37.50 ได้ 375,000 → กำไรจริง 10,000 = 375,000 − 365,000
    const lines = allLines(
      buildPosting(
        convertAtLoss({
          amount: 375_000,
          fxConversion: {
            currency: "USD",
            amountOriginal: 10_000,
            balanceOriginalBefore: 10_000,
            bookRateToThb: 37,
            bookRateDate: "2026-11-30",
            dealRateToThb: 37.5,
            dealRateDate: "2026-12-31",
            unrealizedBefore: 5_000,
          },
        })
      )
    );
    expect(totalDebit(lines)).toBe(totalCredit(lines));
    expect(lineOf(lines, "1100").find((l) => l.bankAccountId === THB)?.debit).toBe(375_000);
    expect(lineOf(lines, "1100").find((l) => l.bankAccountId === FCD)?.credit).toBe(370_000);

    const clear = lineOf(lines, "3410")[0];
    expect(clear.debit, "ล้างผลต่างที่ค้างออกทั้งก้อนเพราะแลกหมด").toBe(5_000);
    expect(clear.currency, "ขาล้างต้องมีสกุลกำกับ").toBe("USD");
    expect(clear.amountOriginal).toBe(0);

    expect(lineOf(lines, "4330")[0].credit, "กำไรจริง = บาทที่ได้ − ต้นทุนเดิม").toBe(10_000);
    expect(lineOf(lines, "5930")).toHaveLength(0);
  });

  it("แลกบางส่วน → ล้างผลต่างตามสัดส่วนที่แลกออก (ไม่ใช่ทั้งก้อน)", () => {
    // ถือ 10,000 USD · ผลต่างค้าง 5,000 · แลกออก 3,000 (30%) → ล้าง 1,500
    const lines = allLines(
      buildPosting(
        convertAtLoss({
          amount: 112_500,
          fxConversion: {
            currency: "USD",
            amountOriginal: 3_000,
            balanceOriginalBefore: 10_000,
            bookRateToThb: 37,
            bookRateDate: "2026-11-30",
            dealRateToThb: 37.5,
            dealRateDate: "2026-12-31",
            unrealizedBefore: 5_000,
          },
        })
      )
    );
    expect(totalDebit(lines)).toBe(totalCredit(lines));
    expect(lineOf(lines, "3410")[0].debit, "5,000 × 3,000/10,000").toBe(1_500);
    // กำไรจริง = 112,500 − 111,000 + 1,500
    expect(lineOf(lines, "4330")[0].credit).toBe(3_000);
  });

  it("แลกมากกว่ายอดคงเหลือ → ปฏิเสธ (เงินตราติดลบไม่ได้)", () => {
    const input = convertAtLoss();
    input.fxConversion!.amountOriginal = 11_000;
    input.amount = 401_500;
    expect(fail(input)).toMatch(/มากกว่ายอดคงเหลือ/);
  });

  it("บาทที่กรอกไม่ตรงกับอัตราที่แลกได้จริง → ปฏิเสธ", () => {
    expect(fail(convertAtLoss({ amount: 366_000 }))).toMatch(/บาทที่ได้รับต้องเท่ากับ/);
  });

  it("ปลายทางเป็นบัญชีเงินตราอีกใบ → ปฏิเสธ (ยังไม่ใช่การแลกเป็นบาท)", () => {
    expect(fail(convertAtLoss({ transferToBankAccountId: "b4jpy" }))).toMatch(
      /ไม่ใช่บัญชีบาท/
    );
  });

  it("ปลายทางเป็นบัญชีของผู้ถืออื่น → ปฏิเสธ (1 รายการ = 1 ผู้ถือ และต้องล้างผลต่างของเจ้าตัว)", () => {
    expect(fail(convertAtLoss({ transferToBankAccountId: "b5" }))).toMatch(
      /ต้องเข้าบัญชีบาทของผู้ถือเดียวกัน/
    );
  });

  it("ปลายทางเป็นบัญชีเดียวกับต้นทาง → ปฏิเสธ", () => {
    expect(fail(convertAtLoss({ transferToBankAccountId: FCD }))).toMatch(/บัญชีเดียวกับ/);
  });

  it("ไม่ส่งปลายทาง → ปฏิเสธ", () => {
    expect(fail(convertAtLoss({ transferToBankAccountId: undefined }))).toMatch(
      /ต้องระบุบัญชีบาทที่รับเงินเข้า/
    );
  });

  it("บัญชีต้นทางของผู้ถืออื่น → ปฏิเสธด้วยเรื่องผู้ถือ ไม่ใช่เรื่องสกุล", () => {
    expect(() => buildPosting(convertAtLoss({ bankAccountId: OTHER_USD }))).toThrow(PostingError);
  });
});

describe("พรีวิวกับบันทึกจริงต้องเห็นของเดียวกัน", () => {
  it("พรีวิวแสดงบรรทัดของใบแลกเงินได้ครบ (ไม่ใช่ขึ้นเหตุผลว่าทำไม่ได้)", () => {
    const r = previewPosting(convertAtLoss(), TEST_RESOLVER);
    expect(r.ok, r.ok ? "" : r.reason).toBe(true);
    if (!r.ok) return;
    const codes = r.lines.map((l) => l.coaCode);
    expect(codes).toContain("5930");
  });

  it("หนึ่งใบ = หนึ่งผู้ถือ ทั้งสองเส้นทาง", () => {
    expect(buildPosting(translateUp()).transactions).toHaveLength(1);
    expect(buildPosting(convertAtLoss()).transactions).toHaveLength(1);
  });
});
