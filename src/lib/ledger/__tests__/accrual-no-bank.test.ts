/**
 * ค้างรับ-ค้างจ่าย **ไม่ต้องมีบัญชีธนาคาร** — บัญชีบังคับเฉพาะเมื่อมีบรรทัดเงินสดจริง
 *
 * เดิม engine เช็ค `!input.bankAccountId` ไว้ **ก่อน** การแยกสาขา จึงไม่สนใจ `notYetPaid` เลย
 * ผลคือเส้นทางค้างรับ-ค้างจ่ายที่ยังไม่มีบัญชี (ซึ่งคือกรณีปกติที่สุดของการตั้งค้าง
 * เพราะตอนตั้งค้างยังไม่รู้ว่าเงินจะเข้าบัญชีไหน) ใช้ไม่ได้จริง: `canApprove = false` ตลอดกาล
 * แล้วหน้าคิวที่นับรายการติดอยู่จะดับปุ่ม "อนุมัติทั้งหมด" ทั้งคิว
 * = กันแน่นเกินจนเส้นทางที่ถูกต้องทำไม่ได้ (บทเรียน mace-windu ข้อ 7)
 *
 * คอมเมนต์ของ D-092 ใน `posting.ts` เขียนไว้ตรงๆ ว่าเส้นทางค้าง "ไม่มีบรรทัดเงินสดเลย"
 * แต่โค้ดในไฟล์เดียวกันไม่ยอมให้เส้นทางนั้นเกิดขึ้นได้เลยถ้าไม่ส่งบัญชี —
 * และเทสต์ชุด `closed-account.test.ts` จับไม่ได้เพราะ **ส่งบัญชีมาทุกเคส**
 * (บทเรียนข้อ 3: เทสต์ที่ส่งข้อมูลครบเสมอ จะไม่มีวันแตะเส้นทางที่ข้อมูลขาด)
 *
 * ชุดนี้จึงไล่ทั้งสองทิศพร้อมกัน ทีละหมวดย่อยทุกตัวในตารางกฎ:
 * - หมวดที่ตั้งค้างได้ + **ไม่ส่งบัญชี** (ทั้ง `undefined` และ `""`) → ต้องผ่าน และไม่มีบรรทัดเงินสด
 * - รายการที่มีขาเงินสด + ไม่ส่งบัญชี → ต้องล้ม พร้อมข้อความที่ชี้ไปที่ "บัญชี"
 *   ไม่ใช่ไปโผล่เป็น "บัญชีไม่ตรงผู้ถือ" ซึ่งชี้ผิดจุด
 */

import { describe, it, expect } from "vitest";
import {
  buildPosting as buildPostingWith,
  buildPostingDraft,
  allLines,
  assertBalanced,
} from "../posting";
import { previewPosting } from "../preview";
import { PostingError, type PostingInput } from "../types";
import { isCashAccount } from "@/lib/rules/coa";
import { TX_TYPES, canAccrueFromForm } from "@/lib/rules/tx-rules";
import { TEST_RESOLVER } from "./fixture-resolver";

/** fixture ของ engine เท่านั้น — ไม่ผูกกับข้อมูลจำลองของแอป */
const buildPosting = (input: PostingInput) => buildPostingWith(input, TEST_RESOLVER);

/** ข้อมูลครบทุกช่องที่หมวดใดหมวดหนึ่งอาจบังคับ — เว้นไว้แต่บัญชีธนาคาร */
const inputFor = (
  typeKey: PostingInput["typeKey"],
  code: string,
  requires: string[] | undefined,
  over: Partial<PostingInput> = {}
): PostingInput => ({
  typeKey,
  subCode: code,
  amount: 12_000,
  ownerId: "thanakorn",
  assetId: "rent1",
  contactId: "c1",
  disposal: requires?.includes("capitalGain") ? { costBasis: 10_000, salePrice: 12_000 } : undefined,
  repayment: requires?.includes("principalInterestSplit")
    ? { principal: 9_000, interest: 3_000 }
    : undefined,
  transferToBankAccountId: requires?.includes("transferTarget") ? "b4b" : undefined,
  ...over,
});

const ALL = TX_TYPES.flatMap((t) => t.subs.map((s) => ({ t, s })));
const ACCRUABLE = ALL.filter(({ s }) => canAccrueFromForm(s));

/** ทั้งสองรูปแบบของ "ไม่ส่ง" — ฟอร์มส่ง `""` · โค้ดที่ประกอบ input เองส่ง `undefined` */
const BLANKS: { label: string; value: string | undefined }[] = [
  { label: "undefined", value: undefined },
  { label: 'สตริงเปล่า ""', value: "" },
  // ช่องว่างล้วนก็คือยังไม่เลือก — ถ้าไม่ตัดช่องว่าง ค่านี้จะถูกเอาไปค้นหาบัญชี
  // แล้วล้มด้วย "ไม่พบบัญชีธนาคาร:   " ซึ่งชี้ผิดจุด และฝั่งตั้งค้างจะใช้ไม่ได้ทั้งเส้น
  { label: "ช่องว่างล้วน", value: "   " },
];

describe("ตั้งค้างรับ-ค้างจ่ายโดยไม่ส่งบัญชีธนาคาร", () => {
  it("ต้องมีหมวดที่ตั้งค้างได้ให้ทดสอบ (กันเทสต์ผ่านเพราะลูปว่าง)", () => {
    expect(ACCRUABLE.length).toBeGreaterThan(0);
  });

  for (const { label, value } of BLANKS) {
    it(`ทุกหมวดที่ตั้งค้างได้ ส่งบัญชีเป็น ${label} ต้องผ่าน และไม่มีบรรทัดเงินสด`, () => {
      for (const { t, s } of ACCRUABLE) {
        const input = inputFor(t.key, s.code, s.requires, {
          bankAccountId: value,
          notYetPaid: true,
        });
        const lines = allLines(buildPosting(input));
        assertBalanced(lines);
        expect(lines.some((l) => isCashAccount(l.coaCode)), s.code).toBe(false);
        expect(lines.some((l) => l.bankAccountId), s.code).toBe(false);
        expect(lines.every((l) => l.cfCategory === "none"), s.code).toBe(true);
      }
    });
  }

  it("ค้างรับ (ลูกหนี้) ลงบัญชีพักฝั่งเดบิต", () => {
    const lines = allLines(
      buildPosting(inputFor("income", "inc.rent", ["asset", "contact"], { notYetPaid: true }))
    );
    expect(lines.find((l) => l.coaCode === "1200")?.debit).toBe(12_000);
    expect(lines.find((l) => l.coaCode === "4200")?.credit).toBe(12_000);
  });

  it("ค้างจ่าย (เจ้าหนี้) ลงบัญชีพักฝั่งเครดิต", () => {
    const lines = allLines(
      buildPosting(inputFor("expense", "exp.repair", ["contact"], { notYetPaid: true }))
    );
    expect(lines.find((l) => l.coaCode === "2100")?.credit).toBe(12_000);
    expect(lines.filter((l) => l.debit > 0)).toHaveLength(1);
  });

  it("พรีวิวก็ต้องแสดงบรรทัดได้ ไม่ใช่ขึ้นเหตุผลว่าขาดบัญชี", () => {
    const r = previewPosting(
      inputFor("income", "inc.rent", ["asset", "contact"], { notYetPaid: true }),
      TEST_RESOLVER
    );
    expect(r.ok, r.ok ? "" : r.reason).toBe(true);
  });

  it("นิติบุคคลตั้งค้างได้โดยไม่มีบัญชี แต่ยังต้องมีหลักฐานและคู่ค้า", () => {
    const corp = inputFor("expense", "exp.common", ["contact"], {
      ownerId: "corp",
      notYetPaid: true,
    });
    expect(() => buildPosting(corp)).toThrow(/ต้องแนบหลักฐาน/);
    const ok = buildPosting({ ...corp, attachments: ["บิลค่าน้ำไฟ.pdf"] });
    expect(allLines(ok).some((l) => isCashAccount(l.coaCode))).toBe(false);
  });
});

describe("มีขาเงินสดแต่ไม่ส่งบัญชี — ต้องล้มทุกหมวด ทุกสาขา", () => {
  for (const { label, value } of BLANKS) {
    it(`ทุกหมวดย่อย เงินเคลื่อนจริง + บัญชีเป็น ${label} → PostingError ที่ชี้ไปที่บัญชี`, () => {
      for (const { t, s } of ALL) {
        const input = inputFor(t.key, s.code, s.requires, { bankAccountId: value });
        let message = "";
        try {
          buildPosting(input);
          throw new Error(`${s.code} ต้องถูกปฏิเสธเพราะไม่มีบัญชีที่เงินเข้า-ออก`);
        } catch (e) {
          expect(e, s.code).toBeInstanceOf(PostingError);
          message = (e as Error).message;
        }
        /**
         * ตรึงข้อความไว้ที่ประโยคที่ผู้ใช้อ่านรู้เรื่อง ไม่ใช่ประโยคภายในของด่านสุดท้าย
         * ("บรรทัดเงินสด 1100 ต้องระบุบัญชีธนาคาร" ซึ่งอ้างรหัสบัญชีที่ผู้ใช้ไม่รู้จัก)
         * ถ้าไม่ตรึง วันที่ด่านหน้าหายไป ด่านสำรองจะยังกันได้แต่ผู้ใช้จะอ่านไม่เข้าใจ
         */
        expect(message, s.code).toBe("ต้องระบุบัญชีธนาคารที่เงินเข้าหรือออก");
        // ข้อความต้องชี้จุดถูก — ห้ามไปโผล่เป็นเรื่องผู้ถือหรือบัญชีปิด
        expect(message, s.code).not.toMatch(/ระบุผู้ถือเป็น|ปิดใช้งาน/);
      }
    });
  }

  it("โอนระหว่างบัญชีที่ไม่มีบัญชีต้นทาง → ล้ม (ปลายทางมีก็ไม่พอ)", () => {
    expect(() =>
      buildPosting(inputFor("transfer", "trf.internal", ["transferTarget"], { bankAccountId: "" }))
    ).toThrow(PostingError);
  });

  it("โอนข้ามผู้ถือที่ไม่มีบัญชีต้นทาง → ล้ม ไม่ใช่สร้างขาเดียว", () => {
    expect(() =>
      buildPosting(
        inputFor("transfer", "trf.internal", ["transferTarget"], {
          bankAccountId: undefined,
          transferToBankAccountId: "b5",
          intercompanyNature: "loan",
        })
      )
    ).toThrow(PostingError);
  });

  it("ขายทรัพย์ไม่มีบัญชีรับเงิน → ล้ม", () => {
    expect(() =>
      buildPosting(
        inputFor("invest_sell", "inv.sell_re", ["asset", "capitalGain"], { bankAccountId: undefined })
      )
    ).toThrow(/บัญชี/);
  });

  it("แยกเงินต้น-ดอกเบี้ยไม่มีบัญชี → ล้ม (สาขานี้สร้างบรรทัดเงินสดเอง หลายบรรทัด)", () => {
    expect(() =>
      buildPosting(
        inputFor("finance_out", "fin.repay_bank", ["principalInterestSplit", "contact"], {
          bankAccountId: undefined,
        })
      )
    ).toThrow(/บัญชี/);
  });

  it("บังคับใน draft ด้วย — พรีวิวต้องไม่โชว์บรรทัดเงินสดที่ไม่รู้บัญชี", () => {
    expect(() =>
      buildPostingDraft(inputFor("income", "inc.rent", ["asset", "contact"]), TEST_RESOLVER)
    ).toThrow(/บัญชี/);
    const r = previewPosting(inputFor("income", "inc.rent", ["asset", "contact"]), TEST_RESOLVER);
    expect(r.ok).toBe(false);
  });

  it("เส้นทางพิเศษที่ติ๊กค้างไว้ ยังถูกปฏิเสธด้วยเหตุผลเดิม ไม่ใช่เรื่องบัญชี", () => {
    // ลำดับข้อความสำคัญ: เหตุที่แท้จริงคือ "หมวดนี้ตั้งค้างไม่ได้" ไม่ใช่ "ไม่มีบัญชี"
    expect(() =>
      buildPosting(
        inputFor("transfer", "trf.internal", ["transferTarget"], {
          bankAccountId: undefined,
          notYetPaid: true,
        })
      )
    ).toThrow(/ตั้งค้างรับ-ค้างจ่ายไม่ได้/);
  });
});

describe("ไม่ส่งบัญชีแล้วไม่ปลดกติกาอื่น", () => {
  it("ตั้งค้างยังต้องกรอกช่องที่หมวดบังคับ (ทรัพย์/คู่ค้า)", () => {
    expect(() =>
      buildPosting({
        typeKey: "income",
        subCode: "inc.rent",
        amount: 12_000,
        ownerId: "thanakorn",
        notYetPaid: true,
        contactId: "c1",
      })
    ).toThrow(/ทรัพย์/);
  });

  it("ตั้งค้างในชื่อมุมมองรวม ยังเลือกไม่ได้", () => {
    expect(() =>
      buildPosting(
        inputFor("income", "inc.rent", ["asset", "contact"], {
          ownerId: "family",
          notYetPaid: true,
        })
      )
    ).toThrow(/มุมมองรวม/);
  });

  it("ส่งบัญชีของผู้ถืออื่นมาพร้อมการตั้งค้าง ยังต้องถูกปฏิเสธ", () => {
    // ตั้งค้างไม่ได้ใช้บัญชี แต่ถ้าผู้ใช้ส่งบัญชีผิดคนมา อย่าเงียบ —
    // รายการนั้นจะถูกยืนยันเงินเข้าบัญชีของคนอื่นภายหลัง
    expect(() =>
      buildPosting(
        inputFor("income", "inc.rent", ["asset", "contact"], {
          bankAccountId: "b5",
          notYetPaid: true,
        })
      )
    ).toThrow(/ระบุผู้ถือเป็น/);
  });

  it("ส่งบัญชีที่ไม่มีในระบบมาพร้อมการตั้งค้าง ยังต้องถูกปฏิเสธ", () => {
    expect(() =>
      buildPosting(
        inputFor("income", "inc.rent", ["asset", "contact"], {
          bankAccountId: "b-ghost",
          notYetPaid: true,
        })
      )
    ).toThrow(/ไม่พบบัญชีธนาคาร/);
  });

  it("จำนวนเงินยังต้องมากกว่า 0 แม้ไม่มีบัญชี", () => {
    expect(() =>
      buildPosting(
        inputFor("income", "inc.rent", ["asset", "contact"], {
          bankAccountId: undefined,
          notYetPaid: true,
          amount: 0,
        })
      )
    ).toThrow(/มากกว่า 0/);
  });
});
