import { describe, it, expect } from "vitest";
import * as fs from "node:fs";
import * as path from "node:path";
import { buildPosting, buildPostingDraft } from "../posting";
import { previewPosting } from "../preview";
import { PostingError, type LedgerResolver, type PostingInput } from "../types";
import { EMPTY_RESOLVER, NO_BANK_RESOLVER, TEST_RESOLVER } from "./fixture-resolver";

/**
 * engine ไม่รู้จักผู้ถือและบัญชีธนาคารด้วยตัวเอง — ต้องรับ `LedgerResolver` เข้ามา
 *
 * ชุดนี้คุมสามเรื่องที่พลาดแล้วตัวเลขผิดเงียบๆ:
 * 1. resolver ตอบว่าไม่รู้จัก → ต้องปฏิเสธด้วย `PostingError` ไม่ใช่ crash ไม่ใช่เดา
 * 2. ผู้ถือปลายทางของการโอนอ่านจาก `bankAccount().ownerId` เสมอ ไม่ใช่จากฟอร์ม
 * 3. ไม่มีไฟล์ไหนใน `lib/ledger` import ข้อมูลจำลองกลับเข้ามา
 */

const rent: PostingInput = {
  typeKey: "income",
  subCode: "inc.rent",
  amount: 12_000,
  ownerId: "thanakorn",
  bankAccountId: "b4",
  assetId: "rent1",
  contactId: "c1",
};

describe("resolver หาไม่เจอ = ปฏิเสธ ไม่ใช่เดา", () => {
  it("ไม่รู้จักผู้ถือ → PostingError ที่บอกว่าหาผู้ถือไม่เจอ", () => {
    expect(() => buildPosting(rent, EMPTY_RESOLVER)).toThrow(PostingError);
    expect(() => buildPosting(rent, EMPTY_RESOLVER)).toThrow(/ไม่พบผู้ถือ/);
  });

  it("ไม่รู้จักบัญชีธนาคาร → PostingError ที่บอกว่าหาบัญชีไม่เจอ", () => {
    // ผู้ถือรู้จัก แต่บัญชีไม่รู้จัก — สองสาเหตุต้องแยกข้อความกัน
    // ไม่งั้นผู้ใช้จะไปแก้ผิดช่อง
    expect(() => buildPosting(rent, NO_BANK_RESOLVER)).toThrow(PostingError);
    expect(() => buildPosting(rent, NO_BANK_RESOLVER)).toThrow(/ไม่พบบัญชีธนาคาร/);
  });

  it("บัญชีปลายทางของการโอนไม่รู้จัก → ปฏิเสธ ไม่ใช่ทิ้งขาเข้าเงียบๆ", () => {
    expect(() =>
      buildPosting(
        {
          typeKey: "transfer",
          subCode: "trf.internal",
          amount: 50_000,
          ownerId: "thanakorn",
          bankAccountId: "b4",
          transferToBankAccountId: "ไม่มีบัญชีนี้",
        },
        TEST_RESOLVER
      )
    ).toThrow(/ไม่พบบัญชีธนาคาร/);
  });

  it("พรีวิวก็ต้องบอกเหตุผลเป็นภาษาคน ไม่โยน error ใส่หน้าจอ", () => {
    const r = previewPosting(rent, EMPTY_RESOLVER);
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.reason).toMatch(/ไม่พบผู้ถือ/);
  });
});

describe("ผู้ถือปลายทางอ่านจากบัญชี ไม่ใช่จากฟอร์ม", () => {
  /**
   * resolver บอกว่า `bX` เป็นของ `thanawin` ทั้งที่ฟอร์มไม่มีช่องผู้ถือปลายทางเลย
   * engine ต้องรู้เองว่าข้ามผู้ถือ แล้วแตกเป็นสอง transaction ฝ่ายละหนึ่ง
   * (บทเรียน mace-windu ข้อ 2 และ Money Invariant 3)
   */
  const resolve: LedgerResolver = {
    owner: TEST_RESOLVER.owner,
    bankAccount: (id) =>
      id === "bX" ? { id: "bX", name: "บัญชีที่ฟอร์มไม่รู้ว่าเป็นของใคร", ownerId: "thanawin" } : TEST_RESOLVER.bankAccount(id),
  };

  const transfer: PostingInput = {
    typeKey: "transfer",
    subCode: "trf.internal",
    amount: 100_000,
    ownerId: "thanakorn",
    bankAccountId: "b4",
    transferToBankAccountId: "bX",
    intercompanyNature: "loan",
  };

  it("แตกเป็นสองรายการ ผู้ถือฝ่ายรับมาจาก bankAccount().ownerId", () => {
    const r = buildPosting(transfer, resolve);
    expect(r.transactions).toHaveLength(2);
    expect(r.transactions.map((t) => t.ownerId)).toEqual(["thanakorn", "thanawin"]);
    expect(r.transactions[0].counterOwnerId).toBe("thanawin");
    expect(r.transactions[1].counterOwnerId).toBe("thanakorn");
  });

  it("แต่ละรายการสมดุลในตัวเอง และบรรทัดเงินสดอยู่บัญชีของฝ่ายตัวเอง", () => {
    const r = buildPosting(transfer, resolve);
    for (const t of r.transactions) {
      const dr = t.lines.reduce((n, l) => n + l.debit, 0);
      const cr = t.lines.reduce((n, l) => n + l.credit, 0);
      expect(dr, `${t.ownerId} ต้องสมดุลในตัวเอง`).toBe(cr);
    }
    const payer = r.transactions.find((t) => t.ownerId === "thanakorn")!;
    const receiver = r.transactions.find((t) => t.ownerId === "thanawin")!;
    expect(payer.lines.find((l) => l.bankAccountId)!.bankAccountId).toBe("b4");
    expect(receiver.lines.find((l) => l.bankAccountId)!.bankAccountId).toBe("bX");
  });

  it("ถ้า resolver บอกว่าบัญชีปลายทางเป็นของคนเดียวกัน ต้องเป็นรายการเดียว", () => {
    // ฟอร์มส่งอินพุตเหมือนกันทุกช่อง ต่างกันแค่คำตอบของ resolver —
    // ยืนยันว่าคนตัดสินว่า "ข้ามผู้ถือหรือไม่" คือ resolver ไม่ใช่ฟอร์ม
    const sameOwner: LedgerResolver = {
      owner: TEST_RESOLVER.owner,
      bankAccount: (id) => (id === "bX" ? { id: "bX", name: "บัญชีที่สองของธนากร", ownerId: "thanakorn" } : TEST_RESOLVER.bankAccount(id)),
    };
    const r = buildPostingDraft({ ...transfer, intercompanyNature: undefined }, sameOwner);
    expect(r.transactions).toHaveLength(1);
    expect(r.transactions[0].ownerId).toBe("thanakorn");
  });
});

describe("lib/ledger ต้องไม่ผูกกับข้อมูลจำลอง", () => {
  const dir = path.resolve(__dirname, "..");

  const tsFiles = (root: string): string[] =>
    fs.readdirSync(root, { withFileTypes: true }).flatMap((e) => {
      const full = path.join(root, e.name);
      if (e.isDirectory()) return tsFiles(full);
      return e.isFile() && (e.name.endsWith(".ts") || e.name.endsWith(".tsx")) ? [full] : [];
    });

  it("ไม่มีไฟล์ใดใน src/lib/ledger/ อ้างถึง lib/mock", () => {
    const files = tsFiles(dir);
    // ถ้าอ่านไฟล์ไม่เจอเลย เทสต์นี้จะผ่านแบบไร้ความหมาย — กันไว้ก่อน
    expect(files.length, "ต้องอ่านไฟล์ใน lib/ledger เจอ").toBeGreaterThan(3);

    const offenders = files.filter((f) => /lib\/mock/.test(fs.readFileSync(f, "utf8"))).map((f) => path.relative(dir, f));
    expect(
      offenders,
      "engine บัญชีต้องรับข้อมูลผู้ถือ/บัญชีผ่าน LedgerResolver เท่านั้น ห้าม import ข้อมูลจำลองกลับเข้ามา"
    ).toEqual([]);
  });
});
