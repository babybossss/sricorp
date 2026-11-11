import { describe, it, expect } from "vitest";
import { COA, coa } from "../coa";
import { BS_LAYOUT, PL_LAYOUT, bsCodes, cashflowLineOf, cashflowLineOfLeg, cfSubCodes, findCashflowLayoutGaps, findLayoutGaps, isBalanceSheetType, plCodes, statementOf } from "../statements";
import { TX_TYPES } from "../tx-rules";

/**
 * บัญชีที่ไม่อยู่ในโครงงบ = ยอดหายจากรายงานโดยไม่มีอะไรฟ้อง
 * ซึ่งแย่กว่ายอดผิด เพราะงบยังดู "ลงตัว" อยู่
 */
describe("โครงงบต้องครอบคลุมผังบัญชีครบ", () => {
  it("ทุกบัญชีอยู่ในงบใดงบหนึ่ง ครั้งเดียว", () => {
    const { missing, duplicated, unknown } = findLayoutGaps();
    expect(missing, "บัญชีที่ยังไม่อยู่ในโครงงบ").toEqual([]);
    expect(duplicated, "บัญชีที่ถูกนับสองรอบ").toEqual([]);
    expect(unknown, "โครงงบอ้างรหัสที่ไม่มีในผังบัญชี").toEqual([]);
  });

  it("บัญชีงบดุลอยู่ในงบดุล · บัญชีรายได้-ค่าใช้จ่ายอยู่ใน P&L", () => {
    for (const a of COA) {
      const where = statementOf(a.code);
      expect(where.statement, `${a.code} ${a.nameTh}`).toBe(isBalanceSheetType(a.type) ? "BS" : "PL");
    }
  });

  it("ฝั่งของบรรทัดในงบดุลตรงกับประเภทบัญชี", () => {
    for (const g of BS_LAYOUT) {
      for (const l of g.lines) {
        for (const code of l.codes) {
          expect(coa(code).type, `${code} อยู่ใต้ ${g.group}`).toBe(g.side);
        }
      }
    }
  });

  it("ส่วนรายได้มีแต่บัญชีรายได้ · ส่วนค่าใช้จ่ายมีแต่ค่าใช้จ่าย", () => {
    for (const s of PL_LAYOUT) {
      for (const l of s.lines) {
        for (const code of l.codes) {
          expect(coa(code).type, `${code} อยู่ใต้ ${s.section}`).toBe(
            s.kind === "revenue" ? "income" : "expense"
          );
        }
      }
    }
  });

  it("เงินถอนของเจ้าของเป็น contra ไม่ใช่บรรทัดบวก", () => {
    // 3200 เป็นเครดิตลดส่วนของเจ้าของ ถ้าบวกเข้าไปทุนจะบวมเท่าที่ถอนออก
    const eq = BS_LAYOUT.find((g) => g.side === "equity")!;
    const drawings = eq.lines.find((l) => l.codes.includes("3200"))!;
    expect(drawings.contra).toBe(true);
  });

  it("ไม่มีบรรทัดว่าง และไม่มีชื่อบรรทัดซ้ำในงบเดียวกัน", () => {
    for (const g of BS_LAYOUT) for (const l of g.lines) expect(l.codes.length).toBeGreaterThan(0);
    for (const s of PL_LAYOUT) for (const l of s.lines) expect(l.codes.length).toBeGreaterThan(0);

    const bsLines = BS_LAYOUT.flatMap((g) => g.lines.map((l) => `${g.side}·${l.line}`));
    expect(new Set(bsLines).size).toBe(bsLines.length);
    const plLines = PL_LAYOUT.flatMap((s) => s.lines.map((l) => l.line));
    expect(new Set(plLines).size).toBe(plLines.length);
  });

  it("จำนวนรหัสในโครงงบรวมกันเท่ากับจำนวนบัญชีในผัง", () => {
    expect(bsCodes().length + plCodes().length).toBe(COA.length);
  });
});

describe("โครงงบกระแสเงินสด", () => {
  it("ทุกหมวดที่เข้างบกระแสเงินสดได้ อยู่ในโครงงบ ครั้งเดียว ในส่วนที่ถูกต้อง", () => {
    // เทสต์นี้คือสิ่งที่ทำให้ "เพิ่มหมวดใหม่แล้วลืมใส่ในงบกระแสเงินสด" พังที่นี่
    // ไม่ใช่ยอดหายจากรายงานเงียบๆ จนลูกพี่มาเจอเองตอนกระทบยอดไม่ลง
    expect(findCashflowLayoutGaps()).toEqual({
      missing: [],
      duplicated: [],
      unknown: [],
      wrongSection: [],
      missingLegs: [],
      duplicatedLegs: [],
      wrongSectionLegs: [],
    });
  });

  it("หมวดโอนระหว่างบัญชีตัวเองไม่อยู่ในโครงงบ", () => {
    // โอนเงินระหว่างบัญชีของกองกลางไม่ใช่กระแสเงินสด — ถ้าโผล่ในงบ
    // ยอดจะพองทั้งเงินเข้าและเงินออกด้วยจำนวนเท่ากัน
    expect(cfSubCodes()).not.toContain("trf.internal");
  });

  it("หาบรรทัดของหมวดได้ และหมวดที่ไม่มีในโครงงบต้องโยน error ไม่ใช่คืนค่าว่าง", () => {
    expect(cashflowLineOf("inc.rent").section).toBe("operating");
    expect(cashflowLineOf("inv.sell_re").section).toBe("investing");
    expect(cashflowLineOf("fin.drawings").section).toBe("financing");
    // คืนค่าว่างแปลว่ายอดก้อนนั้นหายไปจากงบโดยไม่มีอะไรเตือน
    expect(() => cashflowLineOf("trf.internal")).toThrow(/ไม่อยู่ในโครงงบกระแสเงินสด/);
    expect(() => cashflowLineOf("ไม่มีหมวดนี้")).toThrow();
  });

  it("ดอกเบี้ยจ่ายอยู่ส่วนเดียวกับที่ตารางกฎจัดไว้ ไม่ใช่ที่โครงงบตัดสินเอง", () => {
    // ถ้าวันหนึ่งย้ายดอกเบี้ยจ่ายไปฝั่งดำเนินงาน ต้องย้ายที่ตารางกฎ
    // แล้วเทสต์ wrongSection ข้างบนจะบังคับให้ย้ายโครงงบตามเอง
    const sub = TX_TYPES.flatMap((t) => t.subs).find((s) => s.code === "fin.interest_paid");
    expect(cashflowLineOf("fin.interest_paid").section).toBe(sub?.cashflow);
  });
});

describe("โครงงบกระแสเงินสด · ขารายการข้ามผู้ถือ", () => {
  it("ทุกลักษณะทั้งสองฝ่ายมีบรรทัดรองรับ ในส่วนที่ intercompany.ts กำหนด", () => {
    // 4 ลักษณะ x 2 ฝ่าย = 8 ขา · เคยหลุดทั้ง 8 เพราะตัวตรวจดูแต่ตารางกฎ
    // ซึ่งบอกว่า trf.internal เป็น "none" แล้วจบ ทั้งที่ของจริงสร้างกระแสเงินสด
    const g = findCashflowLayoutGaps();
    expect(g.missingLegs).toEqual([]);
    expect(g.duplicatedLegs).toEqual([]);
    expect(g.wrongSectionLegs).toEqual([]);
  });

  it("ฝ่ายจ่ายกับฝ่ายรับอยู่ส่วนต่างกันตามที่ตารางกำหนด", () => {
    // เงินทดรอง/กู้ยืม/เพิ่มทุน: จ่าย = ลงทุน · รับ = จัดหาเงิน
    for (const nature of ["advance", "loan", "capital"] as const) {
      expect(cashflowLineOfLeg(nature, "payer").section).toBe("investing");
      expect(cashflowLineOfLeg(nature, "receiver").section).toBe("financing");
    }
    // ปันผลสลับกัน: ฝ่ายจ่ายลดส่วนของเจ้าของ (จัดหาเงิน) · ฝ่ายรับเป็นรายได้ (ดำเนินงาน)
    expect(cashflowLineOfLeg("dividend", "payer").section).toBe("financing");
    expect(cashflowLineOfLeg("dividend", "receiver").section).toBe("operating");
  });

  it("ขาที่ไม่มีในโครงงบต้องโยน error ไม่ใช่คืนบรรทัดมั่วๆ", () => {
    expect(() => cashflowLineOfLeg("advance", "ไม่มีฝ่ายนี้" as never)).toThrow(
      /ไม่อยู่ในโครงงบกระแสเงินสด/,
    );
  });

  it("เงินปันผลระหว่างกันแยกบรรทัดจากเงินปันผลจากภายนอก", () => {
    // ต้องแยก เพราะตัวในกองกลางถูกตัดออกในงบรวม — รวมบรรทัดกันแล้วจะมองไม่ออก
    // ว่ายอดหายไปเพราะการตัดรายการระหว่างกัน ไม่ใช่เพราะปันผลลดลง
    expect(cashflowLineOfLeg("dividend", "receiver").line).not.toBe(
      cashflowLineOf("inc.dividend").line,
    );
  });
});

describe("จุดบอด: บัญชี 11xx ที่ไม่ใช่เงินสดจริง", () => {
  it("ผังบัญชีมีรหัส 11xx เท่าที่ตัดสินใจแล้วว่าเป็นเงินสดจริง", () => {
    // `isCashAccount()` จับทุกรหัส ^11\d\d$ แบบไม่เลือก และทั้งงบกระแสเงินสด
    // กับ Money Invariant 2 (บรรทัดเงินสดต้องผูกบัญชีธนาคาร) พึ่งฟังก์ชันนั้น
    //
    // ถ้าวันหนึ่งเพิ่ม "1150 เงินฝากติดภาระ" (เงินที่ติดค้ำประกันอยู่ ถอนไม่ได้)
    // มันจะถูกนับเป็นเงินสดเงียบๆ ทั้งในงบดุลและในงบกระแสเงินสด
    // ซึ่ง **ผิด** เพราะเงินติดภาระไม่ใช่เงินที่ใช้ได้ และตามมาตรฐานต้องแยกแสดง
    //
    // เทสต์นี้ไม่ได้ห้ามเพิ่ม — มันบังคับให้ **ตัดสินใจก่อน** ว่ารหัสใหม่
    // เป็นเงินสดสำหรับงบกระแสเงินสดหรือไม่ แล้วค่อยมาแก้รายการนี้
    const cashCodes = COA.filter((a) => /^11\d\d$/.test(a.code)).map((a) => a.code);
    expect(cashCodes.sort()).toEqual(["1100"]);
  });
});
