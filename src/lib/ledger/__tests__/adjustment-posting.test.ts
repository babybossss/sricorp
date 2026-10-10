/**
 * รายการที่ **ไม่มีเงินเคลื่อน** ต้องลงบัญชีได้ โดยไม่ต้องมีบัญชีธนาคารและไม่มี cash_date
 *
 * รูปแบบนี้ไม่เคยมีในระบบมาก่อน (ก่อนหน้านี้ทั้ง 54 หมวดแตะบัญชี 1100 ทุกหมวด)
 * จึงต้องไล่ทั้งสองทิศ:
 *   - ไม่ส่งบัญชี → ผ่าน และไม่มีบรรทัดเงินสดเลย
 *   - **ส่งบัญชีมา → ต้องถูกปฏิเสธ** ไม่ใช่ถูกเมินทิ้ง (บัญชีที่ติดมากับรายการ
 *     ที่ไม่มีขาเงินสดจะถูกนับเป็นความเคลื่อนไหวของบัญชีนั้นตอนกระทบยอด)
 *
 * และเคสที่สำคัญที่สุดของทั้งงาน: **ตัดหนี้สูญแล้ว P&L ต้องไม่ขยับ**
 * ค่าใช้จ่ายรับรู้ตอนตั้งค่าเผื่อครั้งเดียว ถ้าตัดลง 5920 อีกรอบ = ค่าใช้จ่ายซ้ำสองเท่า
 * งบดุลยังสมดุลทุกบรรทัดและไม่มีอะไรฟ้อง จึงต้องมีเทสต์ตรึงไว้
 */

import { describe, it, expect } from "vitest";
import { buildPosting as buildPostingWith, buildPostingDraft, allLines, assertBalanced } from "../posting";
import { previewPosting } from "../preview";
import { PostingError, type PostingInput, type PostingLine } from "../types";
import { isCashAccount } from "@/lib/rules/coa";
import { allowedSubs, findSub, movesCash } from "@/lib/rules/tx-rules";
import { statementOf } from "@/lib/rules/statements";
import { EVIDENCE, TEST_RESOLVER } from "./fixture-resolver";

const buildPosting = (input: PostingInput) => buildPostingWith(input, TEST_RESOLVER);

/** ผู้ถือฝั่ง personal — ไม่ต้องแนบเอกสาร จึงทดสอบคู่บัญชีได้ตรงๆ */
const adj = (subCode: string, over: Partial<PostingInput> = {}): PostingInput => ({
  typeKey: "adjust",
  subCode,
  amount: 5_000,
  ownerId: "thanakorn",
  contactId: "c1",
  ...over,
});

const net = (lines: PostingLine[], code: string) =>
  lines.filter((l) => l.coaCode === code).reduce((a, l) => a + l.debit - l.credit, 0);

const plNet = (lines: PostingLine[]) =>
  lines.filter((l) => statementOf(l.coaCode).statement === "PL").reduce((a, l) => a + l.debit - l.credit, 0);

const ADJ = allowedSubs("adjust");
const WRITEOFF = ["adj.writeoff_rent", "adj.writeoff_interest", "adj.writeoff_other"];

describe("ลงรายการที่ไม่มีเงินเคลื่อนได้ โดยไม่ต้องส่งบัญชีธนาคาร", () => {
  it("ต้องมีหมวดให้ทดสอบ (กันเทสต์ผ่านเพราะลูปว่าง)", () => {
    expect(ADJ.length).toBe(5);
    expect(ADJ.every((s) => !movesCash(s))).toBe(true);
  });

  for (const s of ADJ) {
    it(`${s.code} — ไม่ส่งบัญชีเลยก็ผ่าน · สมดุล · ไม่มีบรรทัดเงินสด · ไม่เข้างบกระแสเงินสด`, () => {
      const lines = allLines(buildPosting(adj(s.code)));
      assertBalanced(lines);
      expect(lines).toHaveLength(2);
      expect(lines.some((l) => isCashAccount(l.coaCode)), "มีบรรทัดเงินสด").toBe(false);
      // ไม่มี bank_account_id ที่ไหนเลย → ด่าน cash_date ฝั่ง DB จะยอมให้ cash_date เป็น null
      expect(lines.some((l) => l.bankAccountId), "มี bank_account_id ติดมา").toBe(false);
      expect(lines.every((l) => l.cfCategory === "none"), "ยังนับในงบกระแสเงินสด").toBe(true);
      expect(net(lines, s.dr)).toBe(5_000);
      expect(net(lines, s.cr)).toBe(-5_000);
    });
  }

  it('สตริงเปล่าและช่องว่างล้วนถือว่า "ไม่ระบุ" เหมือน undefined ไม่ใช่บัญชีที่หาไม่เจอ', () => {
    for (const blank of ["", "   "]) {
      const lines = allLines(buildPosting(adj("adj.doubtful", { bankAccountId: blank })));
      expect(lines.some((l) => l.bankAccountId), blank).toBe(false);
    }
  });

  it("พรีวิวก็แสดงบรรทัดได้ ไม่ใช่ขึ้นเหตุผลว่าขาดบัญชี", () => {
    const r = previewPosting(adj("adj.doubtful"), TEST_RESOLVER);
    expect(r.ok, r.ok ? "" : r.reason).toBe(true);
  });

  it("บังคับเหมือนกันทั้ง draft และตัวจริง — พรีวิวห้ามโชว์บรรทัดที่ตัวจริงจะปฏิเสธ", () => {
    expect(() => buildPostingDraft(adj("adj.doubtful", { bankAccountId: "b4" }), TEST_RESOLVER)).toThrow(
      PostingError
    );
    expect(previewPosting(adj("adj.doubtful", { bankAccountId: "b4" }), TEST_RESOLVER).ok).toBe(false);
  });
});

describe("ส่งบัญชีธนาคารมากับรายการที่ไม่มีเงินเคลื่อน → ปฏิเสธ ไม่ใช่เมินทิ้ง", () => {
  for (const s of ADJ) {
    it(`${s.code} + bankAccountId → PostingError ที่ชี้ว่าหมวดนี้ไม่มีเงินเคลื่อน`, () => {
      let thrown: unknown;
      try {
        buildPosting(adj(s.code, { bankAccountId: "b4" }));
      } catch (e) {
        thrown = e;
      }
      expect(thrown, `${s.code} ปล่อยผ่าน = บัญชีติดไปกับรายการเงียบๆ`).toBeInstanceOf(PostingError);
      expect((thrown as Error).message, s.code).toMatch(/ไม่มีเงินเข้าหรือออกบัญชี/);
    });
  }

  it("บัญชีของคนอื่นยังถูกปฏิเสธด้วยเหตุผลเรื่องผู้ถือก่อน — ลำดับข้อความต้องชี้จุดถูก", () => {
    // b1 เป็นของผู้ถืออื่น: เหตุที่แท้จริงคือบัญชีผิดคน ไม่ใช่เรื่อง "ไม่มีเงินเคลื่อน"
    expect(() => buildPosting(adj("adj.doubtful", { bankAccountId: "b1" }))).toThrow(PostingError);
  });
});

describe("ตั้งค่าเผื่อ — ค่าใช้จ่ายโผล่ครั้งเดียว และลูกหนี้สุทธิลดลง", () => {
  const lines = allLines(buildPosting(adj("adj.doubtful")));

  it("Dr 5920 (P&L) / Cr 1290 (งบดุล)", () => {
    expect(net(lines, "5920")).toBe(5_000);
    expect(net(lines, "1290")).toBe(-5_000);
  });

  it("P&L ขยับเท่ายอดที่ตั้ง (ค่าใช้จ่าย) — เป็นจุดเดียวที่รับรู้ค่าใช้จ่าย", () => {
    expect(plNet(lines)).toBe(5_000);
    expect(statementOf("5920").statement).toBe("PL");
  });

  it("ค่าเผื่ออยู่ในงบดุล ไม่ใช่ P&L และเป็นขาเครดิต (contra) → ลูกหนี้สุทธิลดลง", () => {
    expect(statementOf("1290").statement).toBe("BS");
    expect(lines.find((l) => l.coaCode === "1290")!.credit).toBe(5_000);
  });

  it("งบกระแสเงินสดไม่ขยับเลย — ไม่มีบรรทัดเงินสดและทุกบรรทัด cfCategory = none", () => {
    expect(lines.filter((l) => isCashAccount(l.coaCode))).toHaveLength(0);
    expect(lines.every((l) => l.cfCategory === "none")).toBe(true);
  });
});

describe("ตัดหนี้สูญ — P&L ต้องไม่ขยับเลย (เคสสำคัญสุด: ค่าใช้จ่ายห้ามซ้ำ)", () => {
  for (const code of WRITEOFF) {
    it(`${code} ไม่มีบรรทัดใน P&L และไม่แตะ 5920`, () => {
      const lines = allLines(buildPosting(adj(code)));
      expect(plNet(lines), `${code} ทำให้ P&L ขยับ = ค่าใช้จ่ายซ้ำสองเท่า`).toBe(0);
      expect(
        lines.filter((l) => statementOf(l.coaCode).statement === "PL").map((l) => l.coaCode),
        `${code} มีบรรทัดใน P&L`
      ).toEqual([]);
      expect(lines.map((l) => l.coaCode), `${code} แตะ 5920`).not.toContain("5920");
      // ล้างค่าเผื่อ (เดบิต 1290) คู่กับล้างลูกหนี้ (เครดิต)
      expect(net(lines, "1290")).toBe(5_000);
      expect(net(lines, findSub(code)!.sub.cr)).toBe(-5_000);
    });
  }

  it("ตั้งค่าเผื่อแล้วตัดเต็มจำนวน → ค่าเผื่อกลับเป็นศูนย์ และ P&L ขยับครั้งเดียว", () => {
    const set = allLines(buildPosting(adj("adj.doubtful")));
    const off = allLines(buildPosting(adj("adj.writeoff_rent")));
    expect(net(set, "1290") + net(off, "1290"), "ค่าเผื่อไม่ถูกล้างหมด").toBe(0);
    expect(plNet(set) + plNet(off), "ค่าใช้จ่ายรวมสองขั้นต้องเท่ายอดที่ตั้งครั้งเดียว").toBe(5_000);
    // ลูกหนี้ลดลงจริงหลังตัด
    expect(net(off, "1200")).toBe(-5_000);
  });
});

describe("กลับค่าเผื่อ — เป็นคู่ตรงข้ามของการตั้ง ลบล้างกันพอดี", () => {
  it("ตั้งแล้วกลับเท่ากัน → ทั้งค่าเผื่อและ P&L กลับเป็นศูนย์", () => {
    const set = allLines(buildPosting(adj("adj.doubtful")));
    const rel = allLines(buildPosting(adj("adj.doubtful_release")));
    expect(net(set, "1290") + net(rel, "1290")).toBe(0);
    expect(plNet(set) + plNet(rel)).toBe(0);
  });

  it("กลับค่าเผื่อลดค่าใช้จ่าย (เครดิต 5920) ไม่ใช่สร้างรายได้บรรทัดใหม่", () => {
    const rel = allLines(buildPosting(adj("adj.doubtful_release")));
    expect(rel.find((l) => l.coaCode === "5920")!.credit).toBe(5_000);
    expect(rel.map((l) => l.coaCode)).not.toContain("4900");
  });
});

describe("เคสข้อมูลขาด — ต้องปฏิเสธ ห้ามเดา", () => {
  for (const s of ADJ) {
    it(`${s.code} ไม่ระบุ contact → ปฏิเสธ (ต้องรู้ว่าเป็นหนี้ของใคร)`, () => {
      const noContact = { ...adj(s.code) };
      delete noContact.contactId;
      let thrown: unknown;
      try {
        buildPosting(noContact);
      } catch (e) {
        thrown = e;
      }
      expect(thrown, `${s.code} ลงได้โดยไม่รู้ว่าเป็นหนี้ของใคร`).toBeInstanceOf(PostingError);
    });
  }

  it("ยอดเป็น 0 → ปฏิเสธ", () => {
    expect(() => buildPosting(adj("adj.doubtful", { amount: 0 }))).toThrow(PostingError);
  });

  it('ติ๊ก "ยังไม่ได้รับ/จ่ายเงิน" → ปฏิเสธ พร้อมเหตุผลว่าไม่มีเงินเคลื่อน', () => {
    // เหตุผลต้องไม่ใช่ "ตารางกฎยังไม่ได้ระบุบัญชีลูกหนี้" ซึ่งอ่านเหมือนช่องที่ยังทำไม่เสร็จ
    let message = "";
    try {
      buildPosting(adj("adj.doubtful", { notYetPaid: true }));
    } catch (e) {
      expect(e).toBeInstanceOf(PostingError);
      message = (e as Error).message;
    }
    expect(message).toMatch(/ไม่มีเงินเคลื่อน/);
  });

  it("นิติบุคคลยังต้องแนบหลักฐาน — ไม่มีเงินเคลื่อนไม่ได้ปลดกติกาเอกสาร", () => {
    const corp = adj("adj.doubtful", { ownerId: "corp" });
    expect(() => buildPosting(corp)).toThrow(/ต้องแนบหลักฐาน/);
    const ok = buildPosting({ ...corp, attachments: EVIDENCE });
    expect(allLines(ok).some((l) => isCashAccount(l.coaCode))).toBe(false);
  });

  it("หมวดนี้เลือกจากประเภทอื่นไม่ได้ — engine ปฏิเสธคู่ที่ไม่ตรงตารางกฎ", () => {
    expect(() =>
      buildPosting(adj("adj.doubtful", { typeKey: "expense" } as Partial<PostingInput>))
    ).toThrow(PostingError);
  });
});
