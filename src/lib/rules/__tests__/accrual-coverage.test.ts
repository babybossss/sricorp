import { describe, it, expect } from "vitest";
import {
  TX_TYPES,
  findSub,
  canAccrueFromForm,
  clearingSubsFor,
  type SubCategory,
} from "../tx-rules";
import { COA, coa } from "../coa";
import { findLayoutGaps, statementOf } from "../statements";

const allSubs = TX_TYPES.flatMap((t) => t.subs);
const movingSubs = allSubs.filter((s) => s.cash === "in" || s.cash === "out");

/**
 * D-068 เปิดกฎ "ยังไม่ยืนยันเงินเข้า-ออก = ไม่มีบรรทัดเงินสดเลย" —
 * หมวดที่ไม่มี `accrualCoa` จะตกไปเส้นทางเดิมคือลงเงินสดตรง ซึ่งคือ
 * **การเปิดกฎครึ่งเดียว** (บทเรียนข้อ 7) อันตรายกว่าไม่เปิดเลย
 * เทสต์นี้จึงบังคับว่าทุกหมวดที่เงินเคลื่อนจริงต้องมีบัญชีพักของตัวเอง
 */
describe("ทุกหมวดที่เงินเคลื่อนจริงต้องมีบัญชีพัก (D-069)", () => {
  /**
   * สามหมวดนี้ **ตัวมันเองคือการล้างลูกหนี้/เจ้าหนี้อยู่แล้ว** (D-069b)
   * ให้มันมีบัญชีพักอีก = มีสองทางที่ล้างยอดเดียวกันได้ แล้วลูกหนี้ติดลบ
   * เขียนชื่อตรงๆ ที่นี่โดยตั้งใจ เพื่อให้การเพิ่มข้อยกเว้นเป็นการตัดสินใจที่เห็นใน diff
   */
  const SELF_CLEARING = ["inv.collect_rent", "inv.collect_interest", "fin.pay_payable"];

  it("หมวดที่ cash in/out ต้องมี accrualCoa ยกเว้นสามหมวดที่ล้างยอดในตัวเอง", () => {
    const missing = movingSubs
      .filter((s) => !SELF_CLEARING.includes(s.code) && !s.accrualCoa)
      .map((s) => s.code);
    expect(missing, "หมวดที่เงินเคลื่อนจริงแต่ยังไม่มีบัญชีพัก").toEqual([]);
  });

  it("สามหมวดที่ล้างยอดในตัวเองต้องไม่มี accrualCoa", () => {
    for (const code of SELF_CLEARING) {
      const found = findSub(code);
      expect(found, `ไม่พบหมวด ${code} ในตารางกฎ`).toBeTruthy();
      expect(found!.sub.accrualCoa, `${code} ต้องไม่มีบัญชีพัก ไม่งั้นล้างได้สองทาง`).toBeUndefined();
    }
  });

  it("หมวดที่ไม่เคลื่อนเงินฝั่งเดียว (โอน) ไม่ต้องมีบัญชีพัก", () => {
    // โอนที่ยังไม่โอน = ยังไม่เกิดรายการ ไม่ใช่ลูกหนี้ของใคร
    for (const s of allSubs.filter((x) => x.cash === "both")) {
      expect(s.accrualCoa, s.code).toBeUndefined();
    }
  });
});

describe("บัญชีพักต้องมีจริงและชี้ถูกข้าง", () => {
  it("accrualCoa ทุกตัวเป็นรหัสที่มีอยู่จริงในผังบัญชี", () => {
    for (const s of allSubs) {
      if (!s.accrualCoa) continue;
      expect(() => coa(s.accrualCoa!), `${s.code} → ${s.accrualCoa}`).not.toThrow();
    }
  });

  it("เงินเข้าพักที่สินทรัพย์ (ลูกหนี้) · เงินออกพักที่หนี้สิน (เจ้าหนี้)", () => {
    for (const s of movingSubs) {
      if (!s.accrualCoa) continue;
      const expected = s.cash === "in" ? "asset" : "liability";
      expect(coa(s.accrualCoa).type, `${s.code} (${s.cash}) → ${s.accrualCoa}`).toBe(expected);
    }
  });

  it("บัญชีพักทุกตัวอยู่ในงบดุล ไม่ใช่ P&L", () => {
    // พักไว้ที่ P&L = รับรู้รายได้/ค่าใช้จ่ายซ้ำตอนเงินเข้าจริง
    for (const code of new Set(allSubs.map((s) => s.accrualCoa).filter(Boolean) as string[])) {
      expect(statementOf(code).statement, `${code} ${coa(code).nameTh}`).toBe("BS");
    }
  });
});

/**
 * บัญชีที่ตั้งค้างได้แต่ล้างไม่ได้ = ลูกหนี้ค้างในงบดุลตลอดไป และรายได้ถูกนับซ้ำ
 * ตอนเงินเข้าจริง · `1220` ถูกออกแบบให้กลไกการ check (D-068) เป็นคนล้าง
 * ซึ่งยังไม่มี จึงต้องไม่มีทางตั้งค้างเข้ามันจากฟอร์มได้เลย
 */
describe("ตั้งค้างได้ ต้องล้างได้", () => {
  const formAccruable = allSubs.filter(canAccrueFromForm);

  it("บัญชีพักของหมวดที่ตั้งค้างจากฟอร์มได้ ต้องมีหมวดสำหรับล้าง", () => {
    for (const s of formAccruable) {
      const clearing = clearingSubsFor(s.accrualCoa!);
      expect(clearing.length, `${s.code} พักที่ ${s.accrualCoa} แต่ไม่มีหมวดล้าง`).toBeGreaterThan(0);
    }
  });

  it("1220 ยังล้างด้วยการคีย์มือไม่ได้ จึงต้องตั้งค้างเข้ามันจากฟอร์มไม่ได้", () => {
    expect(clearingSubsFor("1220")).toEqual([]);
    expect(formAccruable.filter((s) => s.accrualCoa === "1220").map((s) => s.code)).toEqual([]);
  });

  it("หมวดที่ตั้งค้างจากฟอร์มได้ ต้องมีขาเงินสดให้แทนที่", () => {
    for (const s of formAccruable) {
      expect(s.dr === "1100" || s.cr === "1100", s.code).toBe(true);
    }
  });
});

describe("บัญชี 1220 ลูกหนี้อื่น (รอรับเงิน)", () => {
  it("อยู่ในผังบัญชีเป็นสินทรัพย์", () => {
    const a = coa("1220");
    expect(a.type).toBe("asset");
    expect(a.nameEn).toBe("Other receivable");
  });

  it("อยู่ในโครงงบดุล กลุ่มสินทรัพย์หมุนเวียน แยกบรรทัดจากลูกหนี้ค่าเช่าและดอกเบี้ย", () => {
    const where = statementOf("1220");
    expect(where.statement).toBe("BS");
    expect(where.group).toBe("สินทรัพย์หมุนเวียน");
    expect(where.line).not.toBe(statementOf("1200").line);
  });

  it("โครงงบยังครอบคลุมผังบัญชีครบ ไม่ซ้ำ ไม่เกิน", () => {
    const { missing, duplicated, unknown } = findLayoutGaps();
    expect(missing, "บัญชีที่ยังไม่อยู่ในโครงงบ").toEqual([]);
    expect(duplicated, "บัญชีที่ถูกนับสองรอบ").toEqual([]);
    expect(unknown, "โครงงบอ้างรหัสที่ไม่มีในผังบัญชี").toEqual([]);
  });

  it("ไม่มีรหัสบัญชีซ้ำในผังหลังเพิ่ม 1220", () => {
    const codes = COA.map((a) => a.code);
    expect(new Set(codes).size).toBe(codes.length);
  });
});

/**
 * A5 (D-058 ข้อ 1) — ซื้อหลักทรัพย์/ทองคำโดยไม่ผูกทะเบียน
 * แปลว่าตอนขายไม่มีล็อตให้ตัดต้นทุนแบบ FIFO (D-038) ซึ่งทำย้อนหลังไม่ได้
 */
describe("ซื้อหลักทรัพย์และทองคำต้องผูกทรัพย์", () => {
  const requiresAsset = (s: SubCategory) => !!s.requires?.includes("asset");

  it("inv.buy_securities และ inv.buy_commodity อยู่ในหมวดที่บังคับผูกทรัพย์", () => {
    const codes = allSubs.filter(requiresAsset).map((s) => s.code);
    expect(codes).toContain("inv.buy_securities");
    expect(codes).toContain("inv.buy_commodity");
  });

  it("ทุกหมวดลงทุนขาซื้อที่เงินออกจริง บังคับผูกทรัพย์ครบ", () => {
    // LEDGER_RULES §2: Investing − ผูก asset = บังคับ ไม่มีข้อยกเว้นรายหมวด
    const invBuy = TX_TYPES.find((t) => t.key === "invest_buy")!;
    const loose = invBuy.subs
      .filter((s) => s.cash === "out" && !requiresAsset(s) && !s.requires?.includes("contact"))
      .map((s) => s.code);
    expect(loose, "หมวดลงทุนขาซื้อที่ไม่ผูกทั้งทรัพย์และคู่ค้า").toEqual([]);
  });
});
