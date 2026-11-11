/**
 * ปิดช่อง "ถูกหักภาษี ณ ที่จ่าย" จากหน้าจอ (ลูกพี่สั่ง: ภาษีทำที่ PEAK · SRI OS ทำ actual + การเงินกองกลาง)
 *
 * ไฟล์นี้ใช้สวิตช์ **จริง** (`WHT_ENABLED`) ไม่ mock — พิสูจน์สถานะที่ส่งมอบ
 * ไฟล์ wht-rules / wht-posting / confirm-cash ยัง mock สวิตช์เป็นเปิด เพื่อรักษาเทสต์ของ
 * ฟีเจอร์ไว้ ให้เปิดกลับแล้วยังถูกต้อง
 *
 * สิ่งที่ต้องไม่เสีย: บัญชี 1800 ยังตั้งได้ผ่านยอดยกมา (กระทบยอดจาก PEAK) และยังล้างได้ผ่านรับเงินคืน
 */
import "@/app/actions/__tests__/mocks";
import { beforeEach, describe, expect, it } from "vitest";
import { ctx, resetCtx } from "@/app/actions/__tests__/ctx";
import { ASSET, BANK, CONTACT, OWNER } from "@/app/actions/__tests__/fake-db";
import { postEntry } from "@/app/actions/post-entry";
import { confirmCash } from "@/app/actions/confirm-cash";
import { buildPosting as buildPostingWith, allLines } from "@/lib/ledger/posting";
import { PostingError, type PostingInput } from "@/lib/ledger/types";
import { TEST_RESOLVER } from "@/lib/ledger/__tests__/fixture-resolver";
import { WHT_COA } from "@/lib/rules/coa";
import { TX_TYPES, accrualCheck, canWithholdTax, whtCheck, whtEligibleSubs } from "@/lib/rules/tx-rules";
import { WHT_ENABLED } from "@/lib/rules/wht-switch";

const buildPosting = (i: PostingInput) => buildPostingWith(i, TEST_RESOLVER);
const net = (i: PostingInput, code = WHT_COA) =>
  allLines(buildPosting(i)).filter((l) => l.coaCode === code).reduce((t, l) => t + l.debit - l.credit, 0);

const rent = (over: Partial<PostingInput> = {}): PostingInput => ({
  typeKey: "income",
  subCode: "inc.rent",
  amount: 100_000,
  ownerId: "thanakorn",
  bankAccountId: "b4",
  assetId: "rent1",
  contactId: "c1",
  ...over,
});
const wht = { rate: 5, amount: 5_000, certificateNo: "WHT-1" };

beforeEach(resetCtx);

describe("สวิตช์ปิดอยู่ และไม่มีหมวดไหนหักภาษีได้", () => {
  it("WHT_ENABLED เป็น false · ไม่มีหมวดใดหักภาษีได้ · whtCheck อธิบายว่าใช้ที่ PEAK", () => {
    expect(WHT_ENABLED).toBe(false);
    expect(whtEligibleSubs()).toHaveLength(0);
    for (const s of TX_TYPES.flatMap((t) => t.subs)) {
      expect(canWithholdTax(s), s.code).toBe(false);
      const c = whtCheck(s);
      expect(c.ok, s.code).toBe(false);
      if (!c.ok) expect(c.why, s.code).toMatch(/PEAK/);
    }
  });
});

describe("1) คีย์รายการสร้างบรรทัด 1800 ใบใหม่ไม่ได้ ไม่ว่าหมวดไหน", () => {
  it("ส่ง wht มากับทุกหมวด → engine ปฏิเสธ (ทั้ง buildPosting จริงและ draft)", () => {
    for (const s of TX_TYPES.flatMap((t) => t.subs)) {
      const t = TX_TYPES.find((x) => x.subs.includes(s))!;
      expect(
        () => buildPosting({ ...rent(), typeKey: t.key, subCode: s.code, wht }),
        s.code
      ).toThrow(PostingError);
    }
  });

  it("หมวดค่าเช่าที่เคยหักได้ ปฏิเสธด้วยเหตุผลที่คนอ่านรู้เรื่อง", () => {
    expect(() => buildPosting(rent({ wht }))).toThrow(/PEAK/);
  });

  it("ไม่ส่ง wht → ลงปกติ และไม่มีบรรทัด 1800", () => {
    const lines = allLines(buildPosting(rent()));
    expect(lines.some((l) => l.coaCode === WHT_COA)).toBe(false);
  });
});

describe("2) opn.wht_credit ยังลงยอดเข้า 1800 ได้ (ยอดตั้งต้นจาก PEAK)", () => {
  it("เดบิต 1800 ตามยอด", () => {
    expect(net({ typeKey: "opening", subCode: "opn.wht_credit", amount: 5_000, ownerId: "thanakorn" })).toBe(5_000);
  });
});

describe("3) inv.wht_refund ยังล้าง 1800 ได้ · เดินสองขั้นแล้วเป็นศูนย์", () => {
  it("ยอดยกมา 5,000 → รับคืน 5,000 → 1800 เป็นศูนย์", () => {
    const step1 = net({ typeKey: "opening", subCode: "opn.wht_credit", amount: 5_000, ownerId: "thanakorn" });
    const step2 = net({
      typeKey: "invest_sell",
      subCode: "inv.wht_refund",
      amount: 5_000,
      ownerId: "thanakorn",
      bankAccountId: "b4",
      contactId: "c1",
    });
    expect(step1).toBe(5_000);
    expect(step2).toBe(-5_000);
    expect(step1 + step2).toBe(0);
  });
});

describe("4) ด่าน 'ตั้งค้างได้ต้องล้างได้' ไม่ถูกกระทบ", () => {
  it("1800 มีทั้งทางตั้ง (opn.wht_credit) และทางล้าง (inv.wht_refund) ในตารางกฎ", () => {
    const subs = TX_TYPES.flatMap((t) => t.subs);
    expect(subs.find((s) => s.code === "opn.wht_credit")?.dr).toBe(WHT_COA);
    const refund = subs.find((s) => s.code === "inv.wht_refund")!;
    expect(refund.cr).toBe(WHT_COA);
    expect(refund.cash).toBe("in");
    // หมวดค้างรับไม่ได้ผูกกับ 1800 — การปิดสวิตช์ไม่ทำให้มีบัญชีพักที่ตั้งได้แต่ล้างไม่ได้
    expect(subs.filter((s) => {
        const a = accrualCheck(s);
        return a.ok && a.account === WHT_COA;
      })).toHaveLength(0);
  });
});

describe("5) ยิง server action ตรงพร้อม wht → ต้องถูกปฏิเสธ ไม่ใช่เงียบแล้วลงให้", () => {
  it("postEntry พร้อม wht → ไม่เขียน DB", async () => {
    const out = await postEntry({
      input: { ...rent({ ownerId: OWNER.tk, bankAccountId: BANK.tk, assetId: ASSET, contactId: CONTACT, amount: 12000 }), wht },
      docDate: "24/10/2026",
      cashDate: "24/10/2026",
    });
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.message).toMatch(/PEAK/);
    expect(ctx.db.rpcCalls).toHaveLength(0);
    expect(ctx.db.rows).toHaveLength(0);
  });

  it("confirmCash พร้อม wht → ปฏิเสธ ลูกหนี้ยังค้างเต็มและไม่มีเงินสด/1800", async () => {
    const posted = await postEntry({
      input: { ...rent({ ownerId: OWNER.tk, assetId: ASSET, contactId: CONTACT, amount: 100000 }), bankAccountId: undefined, notYetPaid: true },
      docDate: "01/10/2026",
      cashDate: "",
    });
    if (!posted.ok) throw new Error(posted.message);
    const out = await confirmCash({
      items: [
        {
          sourceId: posted.transactionIds[0],
          amount: "100,000.00",
          date: "24/10/2026",
          bankAccountId: BANK.tk,
          slips: [],
          expectedClearedCount: 0,
          wht: { rate: "5", amount: "5,000.00", certificateNo: "WHT-1" },
        },
      ],
    });
    expect(out.ok).toBe(false);
    expect(ctx.db.balance("1200")).toBe(100000);
    expect(ctx.db.balance("1100")).toBe(0);
    expect(ctx.db.balance("1800")).toBe(0);
  });
});
