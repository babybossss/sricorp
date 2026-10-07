/**
 * บัญชีที่ปิดใช้งานแล้ว ห้ามรับรายการใหม่ (D-092)
 *
 * ก่อนหน้านี้ `BankInfo` ไม่มีสถานะเปิด-ปิดเลย เครื่องยนต์จึงกันไม่ได้
 * ฟอร์มซ่อนบัญชีที่ปิดจากตัวเลือกอยู่แล้ว แต่ฟอร์มไม่ใช่ที่กั้น (บทเรียน mace-windu ข้อ 6)
 * ตอนปุ่มบันทึกเขียนลง DB ได้จริง ช่องนี้จะเปิดทันทีถ้า engine ไม่กัน
 *
 * สองเรื่องที่ตัดสินไว้ในชุดนี้ และเหตุผล:
 *
 * 1. **กลับรายการได้รับการยกเว้น** — กฎเหล็กข้อ 1 ห้าม DELETE รายการที่ post แล้ว
 *    ทางเดียวที่แก้ได้คือ reverse + ลงใหม่ ถ้ากันบัญชีที่ปิดแบบไม่มียกเว้น
 *    รายการเก่าของบัญชีที่ปิดจะ **แก้ไม่ได้ตลอดกาล** ซึ่งแย่กว่าปัญหาที่พยายามแก้
 *    การยกเว้นอ่านจากธง `reversal` ที่ผู้เรียกบอกเจตนามาตรงๆ เท่านั้น
 *    **ห้ามเดาจากเครื่องหมายยอดเงินหรือหมวดย่อย** เพราะเดาผิด = ปิดบัญชีแล้วยังลงใหม่ได้
 *
 * 2. **บังคับทั้ง draft และตัวจริง** — สถานะบัญชีไม่ใช่กติกาเอกสาร (`assertEvidencePolicy`)
 *    ที่ยอมให้พรีวิวผ่านเพราะไฟล์แนบไม่เปลี่ยนคู่บัญชี บัญชีที่ปิดคือบัญชีที่
 *    **ลงรายการไม่ได้เลย** ถ้าพรีวิวโชว์บรรทัดสวยๆ แล้วกดบันทึกเด้ง ผู้ใช้จะไม่เข้าใจว่าทำไม
 *
 * 3. **ค้างรับ-ค้างจ่ายผ่าน** — เส้นทางนั้นไม่สร้างบรรทัดเงินสดเลย (ลงลูกหนี้/เจ้าหนี้)
 *    จึงไม่มีเงินเข้าบัญชีที่ปิด การรับรู้ว่า "ลูกค้าค้างจ่ายเรา" ไม่ควรถูกบล็อก
 *    เพราะบัญชีที่ตั้งใจจะรับเงินปิดไป — ตอนล้างลูกหนี้ด้วยเงินสดจริงจะมีบรรทัดเงินสด
 *    และถูกกันที่นั้น ซึ่งเป็นจุดที่ถูกต้อง
 */

import { describe, it, expect } from "vitest";
import { buildPosting, buildPostingDraft, allLines } from "../posting";
import { previewPosting } from "../preview";
import { PostingError, type PostingInput } from "../types";
import { isCashAccount } from "@/lib/rules/coa";
import { CLOSED, MISSING_ACTIVE_FLAG_RESOLVER, TEST_RESOLVER } from "./fixture-resolver";

const rent: PostingInput = {
  typeKey: "income",
  subCode: "inc.rent",
  amount: 12_000,
  ownerId: "thanakorn",
  bankAccountId: "b4",
  assetId: "rent1",
  contactId: "c1",
};

/** ข้อความต้องบอกทั้ง "บัญชีไหน" และ "ต้องทำอย่างไรต่อ" ไม่ใช่แค่ว่าไม่ผ่าน */
const withoutBank = (i: PostingInput): PostingInput => {
  const copy = { ...i };
  delete copy.bankAccountId;
  return copy;
};

const expectClosedError = (fn: () => unknown, bankName: string) => {
  expect(fn).toThrow(PostingError);
  let message = "";
  try {
    fn();
  } catch (e) {
    message = (e as Error).message;
  }
  expect(message, "ต้องบอกชื่อบัญชีที่ปิด").toContain(bankName);
  expect(message, "ต้องบอกว่าปิดใช้งานแล้ว").toMatch(/ปิดใช้งาน/);
  expect(message, "ต้องบอกทางออก คือเลือกบัญชีอื่น หรือกลับรายการ").toMatch(/กลับรายการ/);
};

describe("ลงรายการใหม่เข้าบัญชีที่ปิด", () => {
  it("ขาเงินสดเข้าบัญชีที่ปิด ต้องถูกปฏิเสธ", () => {
    expectClosedError(
      () => buildPosting({ ...rent, bankAccountId: "b4c" }, TEST_RESOLVER),
      CLOSED.thanakorn.name
    );
  });

  it("เงินออกจากบัญชีที่ปิดก็ไม่ได้เหมือนกัน", () => {
    expectClosedError(
      () =>
        buildPosting(
          { ...rent, typeKey: "expense", subCode: "exp.repair", bankAccountId: "b4c" },
          TEST_RESOLVER
        ),
      CLOSED.thanakorn.name
    );
  });

  it("เส้นทางแยกเงินต้น-ดอกเบี้ยก็ถูกกัน (สาขานี้สร้างบรรทัดเงินสดเอง)", () => {
    expectClosedError(
      () =>
        buildPosting(
          {
            ...rent,
            typeKey: "finance_out",
            subCode: "fin.repay_bank",
            bankAccountId: "b4c",
            repayment: { principal: 9_000, interest: 3_000 },
          },
          TEST_RESOLVER
        ),
      CLOSED.thanakorn.name
    );
  });

  it("เส้นทางขายทรัพย์ก็ถูกกัน", () => {
    expectClosedError(
      () =>
        buildPosting(
          {
            ...rent,
            typeKey: "invest_sell",
            subCode: "inv.sell_re",
            bankAccountId: "b4c",
            amount: 12_000,
            disposal: { costBasis: 10_000, salePrice: 12_000 },
          },
          TEST_RESOLVER
        ),
      CLOSED.thanakorn.name
    );
  });

  it("บังคับใน draft ด้วย — พรีวิวต้องไม่โชว์บรรทัดที่บันทึกไม่ได้", () => {
    expectClosedError(
      () => buildPostingDraft({ ...rent, bankAccountId: "b4c" }, TEST_RESOLVER),
      CLOSED.thanakorn.name
    );
  });

  it("previewPosting คืน ok:false พร้อมเหตุผล ไม่ throw ขึ้นจอ", () => {
    const r = previewPosting({ ...rent, bankAccountId: "b4c" }, TEST_RESOLVER);
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.reason).toContain(CLOSED.thanakorn.name);
    expect(r.reason).toMatch(/ปิดใช้งาน/);
  });
});

describe("โอนเงิน — ต้องไล่ทั้งต้นทางและปลายทาง", () => {
  const transfer: PostingInput = {
    typeKey: "transfer",
    subCode: "trf.internal",
    amount: 100_000,
    ownerId: "thanakorn",
    bankAccountId: "b4",
    transferToBankAccountId: "b4b",
    contactId: "c1",
  };

  it("ต้นทางปิด → ปฏิเสธ", () => {
    expectClosedError(
      () => buildPosting({ ...transfer, bankAccountId: "b4c", transferToBankAccountId: "b4b" }, TEST_RESOLVER),
      CLOSED.thanakorn.name
    );
  });

  it("ปลายทางปิด (ผู้ถือเดียวกัน) → ปฏิเสธ", () => {
    expectClosedError(
      () => buildPosting({ ...transfer, transferToBankAccountId: "b4c" }, TEST_RESOLVER),
      CLOSED.thanakorn.name
    );
  });

  it("ปลายทางปิดของผู้ถืออีกคน → ปฏิเสธ (ผู้ถือปลายทางอ่านจากบัญชีเอง ไม่ใช่จากฟอร์ม)", () => {
    expectClosedError(
      () =>
        buildPosting(
          { ...transfer, transferToBankAccountId: "b6", intercompanyNature: "loan" },
          TEST_RESOLVER
        ),
      CLOSED.thanawin.name
    );
  });

  it("โอนปกติระหว่างบัญชีที่เปิดทั้งคู่ ยังได้ตัวเลขเดิม", () => {
    const r = buildPosting(transfer, TEST_RESOLVER);
    expect(r.transactions).toHaveLength(1);
    const lines = allLines(r);
    expect(lines).toHaveLength(2);
    expect(lines.find((l) => l.bankAccountId === "b4b")?.debit).toBe(100_000);
    expect(lines.find((l) => l.bankAccountId === "b4")?.credit).toBe(100_000);
    expect(lines.every((l) => l.cfCategory === "none")).toBe(true);
  });
});

describe("กลับรายการ — ต้องอ้างบัญชีที่ปิดได้เสมอ", () => {
  it("กลับรายการเข้าบัญชีที่ปิดต้องผ่าน ไม่งั้นแก้รายการเก่าไม่ได้เลย", () => {
    const r = buildPosting({ ...rent, bankAccountId: "b4c", reversal: true }, TEST_RESOLVER);
    expect(r.transactions).toHaveLength(1);
    expect(allLines(r).find((l) => isCashAccount(l.coaCode))?.bankAccountId).toBe("b4c");
  });

  it("กลับรายการโอนข้ามผู้ถือที่ปลายทางปิด ก็ต้องผ่านทั้งสองขา", () => {
    const r = buildPosting(
      {
        typeKey: "transfer",
        subCode: "trf.internal",
        amount: 100_000,
        ownerId: "thanakorn",
        bankAccountId: "b4",
        transferToBankAccountId: "b6",
        intercompanyNature: "loan",
        contactId: "c1",
        reversal: true,
      },
      TEST_RESOLVER
    );
    expect(r.transactions).toHaveLength(2);
    expect(r.transactions.map((t) => t.ownerId)).toEqual(["thanakorn", "thanawin"]);
  });

  it("ธง reversal ไม่ปลดกติกาอื่น — นิติบุคคลยังต้องแนบหลักฐาน", () => {
    expect(() =>
      buildPosting(
        { ...rent, ownerId: "corp", bankAccountId: "b2", reversal: true },
        TEST_RESOLVER
      )
    ).toThrow(/ต้องแนบหลักฐาน/);
  });

  it("ธง reversal ไม่ปลดการตรวจว่าบัญชีเป็นของผู้ถือที่ระบุ", () => {
    expect(() =>
      buildPosting({ ...rent, bankAccountId: "b6", reversal: true }, TEST_RESOLVER)
    ).toThrow(/แต่รายการระบุผู้ถือเป็น/);
  });
});

describe("ค้างรับ-ค้างจ่าย — ไม่มีขาเงินสด จึงอ้างบัญชีที่ปิดได้", () => {
  it("ค่าเช่าค้างรับที่อ้างบัญชีที่ปิด ต้องผ่าน และไม่มีบรรทัดเงินสด", () => {
    const r = buildPosting({ ...rent, bankAccountId: "b4c", notYetPaid: true }, TEST_RESOLVER);
    const lines = allLines(r);
    expect(lines.some((l) => isCashAccount(l.coaCode))).toBe(false);
    expect(lines.some((l) => l.bankAccountId)).toBe(false);
    expect(lines.find((l) => l.coaCode === "1200")?.debit).toBe(rent.amount);
  });

  it("ค่าใช้จ่ายค้างจ่ายที่อ้างบัญชีที่ปิด ต้องผ่าน", () => {
    const r = buildPosting(
      { ...rent, typeKey: "expense", subCode: "exp.repair", bankAccountId: "b4c", notYetPaid: true },
      TEST_RESOLVER
    );
    expect(allLines(r).some((l) => isCashAccount(l.coaCode))).toBe(false);
  });

  /**
   * เคสที่ชุดนี้ขาดไปตอนแรก และเป็นช่องที่ปล่อยบั๊กผ่าน: **ทุกเคสส่ง `b4c` มาด้วย**
   *
   * ทั้งชุดจึงไม่มีเคสไหนเลยที่ไม่ส่งบัญชี แล้วด่านที่เช็ค `!input.bankAccountId`
   * ไว้ก่อนแยกสาขา (ซึ่งทำให้ตั้งค้างโดยไม่มีบัญชีไม่ได้เลย) ก็ไม่ถูกแตะ —
   * เทสต์ผ่านทั้งชุดด้วยเหตุผลผิดๆ (บทเรียน mace-windu ข้อ 3)
   *
   * ของจริงยิ่งกว่านั้น: รายการค้างรับ-ค้างจ่าย **ตามปกติจะไม่มีบัญชีมาด้วย**
   * เพราะตอนตั้งค้างยังไม่รู้ว่าเงินจะเข้า-ออกบัญชีไหน (ดู `UNASSIGNED_CASH_ROWS`)
   * เคสที่อ้างบัญชีที่ปิดจึงเป็นเคสรอง ไม่ใช่เคสหลัก
   */
  it("ค้างรับที่ไม่ส่งบัญชีเลย (undefined) ต้องผ่าน", () => {
    const r = buildPosting({ ...withoutBank(rent), notYetPaid: true }, TEST_RESOLVER);
    const lines = allLines(r);
    expect(lines.some((l) => isCashAccount(l.coaCode))).toBe(false);
    expect(lines.find((l) => l.coaCode === "1200")?.debit).toBe(rent.amount);
  });

  it('ค้างจ่ายที่ส่งบัญชีเป็นสตริงเปล่า "" ต้องผ่าน', () => {
    const r = buildPosting(
      { ...rent, typeKey: "expense", subCode: "exp.repair", bankAccountId: "", notYetPaid: true },
      TEST_RESOLVER
    );
    const lines = allLines(r);
    expect(lines.some((l) => isCashAccount(l.coaCode))).toBe(false);
    expect(lines.find((l) => l.coaCode === "2100")?.credit).toBe(rent.amount);
  });

  it("แต่รายการเงินสดที่ไม่ส่งบัญชีเลย ต้องล้ม — ไม่ใช่ลงเงินลอย", () => {
    const noBank = withoutBank(rent);
    expect(() => buildPosting(noBank, TEST_RESOLVER)).toThrow(PostingError);
    expect(() => buildPosting(noBank, TEST_RESOLVER)).toThrow(/บัญชี/);
  });

  it("แต่ตอนล้างด้วยเงินสดจริงเข้าบัญชีที่ปิด ต้องถูกกัน — จุดที่ควรกันคือตรงนี้", () => {
    expectClosedError(
      () => buildPosting({ ...rent, bankAccountId: "b4c" }, TEST_RESOLVER),
      CLOSED.thanakorn.name
    );
  });
});

describe("ไม่พังรายการที่ถูกต้อง", () => {
  it("บัญชีที่ปิดของผู้ถือคนอื่นไม่ทำให้รายการที่ถูกต้องพัง", () => {
    // `b2` (corp) และ `b6` (ธนวินท์) ปิดอยู่ใน fixture แต่รายการนี้ไม่ได้แตะเลย
    const r = buildPosting(rent, TEST_RESOLVER);
    expect(allLines(r).find((l) => isCashAccount(l.coaCode))?.debit).toBe(rent.amount);
  });

  it("ตัวเลขและคู่บัญชีของเส้นทางที่ถูกต้องไม่เปลี่ยน", () => {
    const lines = allLines(buildPosting(rent, TEST_RESOLVER));
    expect(lines).toHaveLength(2);
    expect(lines.find((l) => l.coaCode === "4200")?.credit).toBe(rent.amount);
    expect(lines.every((l) => l.cfCategory === "operating")).toBe(true);
  });
});

describe("resolver ที่คืนข้อมูลไม่ครบ", () => {
  /**
   * บทเรียน mace-windu ข้อ 1 + ข้อ 3 — "ไม่บอก" ต้องไม่เท่ากับ "เปิดใช้งาน"
   * ถ้าตีความว่าเปิด การกันบัญชีปิดจะหายไปทั้งระบบเมื่อ resolver ตัวใดตัวหนึ่งลืมส่งฟิลด์
   */
  it("ไม่ส่ง isActive ต้องถูกปฏิเสธ ไม่ใช่ถือว่าเปิดใช้งาน", () => {
    expect(() => buildPosting(rent, MISSING_ACTIVE_FLAG_RESOLVER)).toThrow(PostingError);
    expect(() => buildPosting(rent, MISSING_ACTIVE_FLAG_RESOLVER)).toThrow(/สถานะ|ปิดใช้งาน/);
  });

  it("ไม่ส่ง isActive แล้วเป็นการกลับรายการ ยังผ่านได้ (เหตุผลเดียวกับข้อยกเว้น)", () => {
    const r = buildPosting({ ...rent, reversal: true }, MISSING_ACTIVE_FLAG_RESOLVER);
    expect(r.transactions).toHaveLength(1);
  });
});
