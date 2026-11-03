/**
 * ยืนยันว่าเงินเข้า-ออกจริงแล้ว = **การลงบัญชี** จึงต้องอยู่ในเครื่องยนต์
 *
 * ขั้นนี้สร้างบรรทัดบัญชีจริง (ล้างลูกหนี้/เจ้าหนี้ → เงินสด) และเป็นขั้นที่ทำให้
 * งบกระแสเงินสดวิ่ง ก่อนหน้านี้กฎของมันถูกเขียนไว้ในหน้าจอ (`components/ledger/confirm-gate.ts`)
 * เพราะเครื่องยนต์ไม่มีฟังก์ชันให้เรียก — กฎเดียวกันอยู่สองที่คือทางที่สิ่งที่ผู้ใช้เห็น
 * กับสิ่งที่ระบบบันทึกแยกจากกันได้ (บทเรียน mace-windu ข้อ 5)
 *
 * คู่บัญชีของการล้าง **ห้ามเขียนในฟังก์ชันนี้** ต้องมาจากตารางกฎ (`clearingSubsFor()`)
 * ชุดนี้จึงมีเคสที่เทียบคู่บัญชีที่ได้กับทางล้างในตารางกฎตรงๆ
 */

import { describe, it, expect } from "vitest";
import { buildClearing, buildClearingDraft } from "../clearing";
import { allLines, assertBalanced } from "../posting";
import { PostingError, type ClearingInput } from "../types";
import { isCashAccount, coa } from "@/lib/rules/coa";
import { TX_TYPES, canAccrueFromForm, clearingSubsFor, findSub } from "@/lib/rules/tx-rules";
import { CLOSED, EVIDENCE, TEST_RESOLVER } from "./fixture-resolver";

/** ค่าเช่าค้างรับ 12,000 ของธนากร ที่ยังไม่เคยยืนยัน */
const receivable: ClearingInput = {
  sourceId: "tx-rent-09",
  typeKey: "income",
  subCode: "inc.rent",
  ownerId: "thanakorn",
  accruedAmount: 12_000,
  postedClearings: [],
  amount: 12_000,
  bankAccountId: "b4",
  date: "2026-10-03",
  assetId: "rent1",
  contactId: "c1",
};

/**
 * ค่าซ่อมค้างจ่าย 8,600 — ฝั่งเจ้าหนี้
 *
 * `assetId` มีเพราะตารางกฎของ `exp.repair` บังคับ (`requires: ["asset"]`) เหมือนกับที่
 * ใบตั้งค้างต้นทางถูกบังคับ — ถ้าใบล้างไม่ผูกทรัพย์ บัญชีย่อยรายทรัพย์จะไม่หักกลบกัน
 * (ดูชุด `clearing-dimensions.test.ts` ที่ทดสอบทั้งหมวดที่บังคับและไม่บังคับ)
 * ทรัพย์ไม่ติดไปกับบรรทัดเจ้าหนี้ (2100 เป็นหนี้สิน) จึงไม่เปลี่ยนตัวเลขของเคสด้านล่าง
 */
const payable: ClearingInput = {
  sourceId: "tx-repair-09",
  typeKey: "expense",
  subCode: "exp.repair",
  ownerId: "thanakorn",
  accruedAmount: 8_600,
  postedClearings: [],
  amount: 8_600,
  bankAccountId: "b4",
  date: "2026-10-03",
  assetId: "rent1",
  contactId: "c1",
};

const clear = (input: ClearingInput) => buildClearing(input, TEST_RESOLVER);
const lines = (input: ClearingInput) => allLines(clear(input));
const cash = (input: ClearingInput) => lines(input).find((l) => isCashAccount(l.coaCode))!;
/** ตัดช่องหนึ่งออกจริงๆ — เลียนแบบข้อมูลที่ขาดมาจาก DB/ฟอร์มตอน runtime */
const without = (input: ClearingInput, key: keyof ClearingInput): ClearingInput => {
  const copy = { ...input };
  delete copy[key];
  return copy;
};

const message = (fn: () => unknown): string => {
  try {
    fn();
  } catch (e) {
    expect(e).toBeInstanceOf(PostingError);
    return (e as Error).message;
  }
  throw new Error("ต้องถูกปฏิเสธ แต่ผ่าน");
};

describe("ล้างค้างรับด้วยเงินสด", () => {
  it("ลูกหนี้ลด เงินสดเพิ่ม และหนึ่งรายการต่อหนึ่งผู้ถือ", () => {
    const r = clear(receivable);
    expect(r.transactions).toHaveLength(1);
    expect(r.transactions[0].ownerId).toBe("thanakorn");

    const l = allLines(r);
    assertBalanced(l);
    expect(l).toHaveLength(2);
    expect(l.find((x) => isCashAccount(x.coaCode))?.debit).toBe(12_000);
    expect(l.find((x) => x.coaCode === "1200")?.credit).toBe(12_000);
  });

  it("บรรทัดเงินสดผูกบัญชีที่เงินเข้าจริง · บรรทัดลูกหนี้ไม่ผูกบัญชี", () => {
    const l = lines(receivable);
    expect(cash(receivable).bankAccountId).toBe("b4");
    expect(l.find((x) => x.coaCode === "1200")?.bankAccountId).toBeUndefined();
  });

  it("หมวดกระแสเงินสดตรงกับรายการต้นทาง ไม่ใช่หมวดของทางล้าง", () => {
    const source = findSub("inc.rent")!.sub;
    expect(lines(receivable).every((l) => l.cfCategory === source.cashflow)).toBe(true);
    expect(source.cashflow).toBe("operating");
  });

  it("บรรทัดลูกหนี้ยังผูกทรัพย์เดิม ไม่งั้นบัญชีย่อยรายทรัพย์ไม่ตรง", () => {
    expect(lines(receivable).find((l) => l.coaCode === "1200")?.assetId).toBe("rent1");
  });

  it("คู่บัญชีต้องเท่ากับทางล้างในตารางกฎ (ไม่ได้เขียนเองในฟังก์ชัน)", () => {
    const source = findSub("inc.rent")!.sub;
    const route = clearingSubsFor(source.accrualCoa!, source.cashflow)[0];
    expect(lines(receivable).find((l) => l.debit > 0)?.coaCode).toBe(route.dr);
    expect(lines(receivable).find((l) => l.credit > 0)?.coaCode).toBe(route.cr);
  });
});

describe("ล้างค้างจ่าย", () => {
  it("เจ้าหนี้ลด เงินสดลด", () => {
    const l = lines(payable);
    assertBalanced(l);
    expect(l.find((x) => x.coaCode === "2100")?.debit).toBe(8_600);
    expect(l.find((x) => isCashAccount(x.coaCode))?.credit).toBe(8_600);
    expect(cash(payable).bankAccountId).toBe("b4");
  });

  it("ไม่กระทบกำไรขาดทุน — ค่าใช้จ่ายรับรู้ไปแล้วตอนตั้งหนี้", () => {
    for (const l of lines(payable)) {
      expect(["asset", "liability"]).toContain(coa(l.coaCode).type);
    }
  });
});

describe("ล้างบางส่วน", () => {
  it("ล้างครึ่งเดียวได้ และบอกยอดค้างคงเหลือ", () => {
    const r = clear({ ...receivable, amount: 5_000 });
    expect(allLines(r).find((l) => isCashAccount(l.coaCode))?.debit).toBe(5_000);
    expect(allLines(r).find((l) => l.coaCode === "1200")?.credit).toBe(5_000);
    expect(r.summary.join(" ")).toMatch(/7,000|7000/);
  });

  it("ล้างส่วนที่เหลือหลังจากเคยล้างไปแล้ว", () => {
    const r = clear({
      ...receivable,
      postedClearings: [{ id: "clr-1", amount: 5_000 }],
      amount: 7_000,
    });
    expect(allLines(r).find((l) => isCashAccount(l.coaCode))?.debit).toBe(7_000);
  });

  it("เศษสตางค์ไม่ทำให้ล้างยอดสุดท้ายไม่ได้", () => {
    const r = clear({
      ...receivable,
      accruedAmount: 100.1,
      postedClearings: [{ id: "clr-1", amount: 33.37 }],
      amount: 66.73,
    });
    assertBalanced(allLines(r));
  });
});

describe("ปฏิเสธ — ยอดเงิน", () => {
  it("ล้างเกินยอดค้าง", () => {
    expect(message(() => clear({ ...receivable, amount: 12_001 }))).toMatch(/เกินยอดค้าง/);
  });

  it("ล้างเกินยอดค้างเมื่อรวมกับที่เคยล้างไปแล้ว", () => {
    const m = message(() =>
      clear({ ...receivable, postedClearings: [{ id: "clr-1", amount: 5_000 }], amount: 7_001 })
    );
    expect(m).toMatch(/เกินยอดค้าง/);
  });

  it("ยืนยันซ้ำรายการเดิม (ล้างครบแล้ว) — ห้ามให้เงินสดเพิ่มสองเท่า", () => {
    const m = message(() =>
      clear({ ...receivable, postedClearings: [{ id: "clr-1", amount: 12_000 }] })
    );
    expect(m).toMatch(/ยืนยัน/);
    expect(m).toMatch(/ครบแล้ว|ซ้ำ/);
  });

  it("ยืนยันซ้ำด้วยเลขอ้างอิงเดิม ถึงยอดยังเหลือก็ต้องล้ม", () => {
    const m = message(() =>
      clear({
        ...receivable,
        postedClearings: [{ id: "slip-77", amount: 5_000 }],
        clearingRef: "slip-77",
        amount: 1_000,
      })
    );
    expect(m).toMatch(/ซ้ำ/);
  });

  it("ยอดที่ล้างต้องมากกว่า 0", () => {
    expect(message(() => clear({ ...receivable, amount: 0 }))).toMatch(/มากกว่า 0/);
    expect(() => clear({ ...receivable, amount: -1 })).toThrow(PostingError);
  });

  it("ยอดค้างต้องมากกว่า 0 — รายการที่ลงเงินสดไปแล้วไม่มียอดให้ล้าง", () => {
    expect(message(() => clear({ ...receivable, accruedAmount: 0 }))).toMatch(/ยอดค้าง/);
  });

  it("ประวัติที่ล้างไปแล้วมากกว่ายอดค้าง = ข้อมูลไม่ตรง ต้องปฏิเสธ ไม่ใช่คิดต่อ", () => {
    expect(() =>
      clear({ ...receivable, postedClearings: [{ id: "clr-1", amount: 99_999 }] })
    ).toThrow(PostingError);
  });

  it("ตัวเลขที่คำนวณต่อไม่ได้ (NaN) ต้องปฏิเสธ", () => {
    expect(() => clear({ ...receivable, amount: Number.NaN })).toThrow(PostingError);
    expect(() => clear({ ...receivable, accruedAmount: Number.NaN })).toThrow(PostingError);
  });
});

describe("ปฏิเสธ — บัญชีที่เงินเข้า-ออก", () => {
  it("ไม่ส่งบัญชีเลย (undefined)", () => {
    expect(message(() => clear(without(receivable, "bankAccountId")))).toMatch(/บัญชี/);
  });

  it('ส่งบัญชีเป็นสตริงเปล่า "" = ไม่ได้ระบุ', () => {
    const m = message(() => clear({ ...receivable, bankAccountId: "" }));
    expect(m).toMatch(/บัญชี/);
    // ต้องไม่หลุดไปเป็น "ไม่พบบัญชีธนาคาร: " ซึ่งชี้ผิดจุด
    expect(m).not.toMatch(/ไม่พบบัญชีธนาคาร/);
  });

  it("บัญชีที่ไม่มีในระบบ", () => {
    expect(message(() => clear({ ...receivable, bankAccountId: "b-ghost" }))).toMatch(/b-ghost/);
  });

  it("บัญชีของผู้ถืออื่น — เงินจะไปโผล่ในงบของคนอื่น", () => {
    expect(message(() => clear({ ...receivable, bankAccountId: "b5" }))).toMatch(
      /ระบุผู้ถือเป็น|ไม่ใช่ของ/
    );
  });

  it("บัญชีที่ปิดใช้งานแล้ว — จุดที่ D-092 ตั้งใจกัน คือตอนล้างด้วยเงินสดจริง", () => {
    const m = message(() => clear({ ...receivable, bankAccountId: "b4c" }));
    expect(m).toContain(CLOSED.thanakorn.name);
    expect(m).toMatch(/ปิดใช้งาน/);
  });

  it("ผู้ถือที่เป็นมุมมองรวม เลือกไม่ได้", () => {
    expect(message(() => clear({ ...receivable, ownerId: "family", bankAccountId: "b4" }))).toMatch(
      /มุมมองรวม/
    );
  });

  it("ผู้ถือที่ resolver ไม่รู้จัก", () => {
    expect(message(() => clear({ ...receivable, ownerId: "ไม่มีคนนี้" }))).toMatch(/ไม่พบผู้ถือ/);
  });
});

describe("ปฏิเสธ — รายการที่ล้างไม่ได้", () => {
  it("หมวดที่ไม่ใช่ค้างรับ-ค้างจ่ายเลย (โอนระหว่างบัญชี)", () => {
    const m = message(() =>
      clear({ ...receivable, typeKey: "transfer", subCode: "trf.internal" })
    );
    expect(m).toMatch(/ไม่ใช่รายการค้างรับ-ค้างจ่าย/);
  });

  it("หมวดเส้นทางพิเศษ (ขายทรัพย์) — บันทึกตอนเงินเคลื่อนจริงอยู่แล้ว", () => {
    const m = message(() =>
      clear({ ...receivable, typeKey: "invest_sell", subCode: "inv.sell_re" })
    );
    expect(m).toMatch(/ไม่ใช่รายการค้างรับ-ค้างจ่าย/);
  });

  it("หมวดที่ยังไม่มีทางล้างในตารางกฎ ต้องบอกเหตุผล (D-087)", () => {
    const m = message(() => clear({ ...receivable, typeKey: "income", subCode: "inc.dividend" }));
    expect(m, "ต้องบอกว่าล้างไม่ได้เพราะอะไร ไม่ใช่แค่ว่าไม่ได้").toMatch(/ยังไม่มีหมวดสำหรับล้าง/);
  });

  it("หมวดที่มีทางล้างแต่คนละหมวดกระแสเงินสด ต้องปฏิเสธและบอกว่าทำไม", () => {
    const m = message(() => clear({ ...receivable, typeKey: "invest_buy", subCode: "inv.buy_re" }));
    expect(m).toMatch(/กระแสเงินสด/);
  });

  it("หมวดย่อยที่ไม่มีในตารางกฎ", () => {
    expect(() => clear({ ...receivable, subCode: "inc.ไม่มี" })).toThrow(/ไม่พบหมวดย่อย/);
  });

  it("หมวดย่อยไม่อยู่ใต้ประเภทที่ส่งมา", () => {
    expect(() => clear({ ...receivable, typeKey: "expense", subCode: "inc.rent" })).toThrow(
      /ไม่อยู่ใต้ประเภท/
    );
  });
});

describe('เคส "ไม่ส่ง" ทุกช่อง', () => {
  /** TypeScript กันช่องที่บังคับให้แล้ว แต่ข้อมูลตอน runtime มาจาก DB/ฟอร์มซึ่งกันไม่ถึง */
  const missing = (key: keyof ClearingInput) => without(receivable, key);

  it("ไม่ส่งวันที่ที่เงินเคลื่อน — ขั้นนี้คือขั้นที่ทำให้งบกระแสเงินสดวิ่ง", () => {
    expect(message(() => clear(missing("date")))).toMatch(/วันที่/);
    expect(message(() => clear({ ...receivable, date: "  " }))).toMatch(/วันที่/);
  });

  it("ไม่ส่งยอดค้าง", () => {
    expect(() => clear(missing("accruedAmount"))).toThrow(PostingError);
  });

  it("ไม่ส่งยอดที่จะล้าง", () => {
    expect(() => clear(missing("amount"))).toThrow(PostingError);
  });

  it("ไม่ส่งประวัติการยืนยัน — ห้ามเดาว่า 'ยังไม่เคยยืนยัน'", () => {
    const m = message(() => clear(missing("postedClearings")));
    expect(m).toMatch(/ประวัติ/);
  });

  it("ไม่ส่งรหัสรายการต้นทาง", () => {
    expect(() => clear(missing("sourceId"))).toThrow(PostingError);
  });

  it("ไม่ส่งผู้ถือ", () => {
    expect(() => clear(missing("ownerId"))).toThrow(PostingError);
  });

  it("ประวัติที่มีรายการยอดเป็นค่าที่คำนวณต่อไม่ได้", () => {
    expect(() =>
      clear({ ...receivable, postedClearings: [{ id: "x", amount: Number.NaN }] })
    ).toThrow(PostingError);
  });
});

describe("กติกาเอกสารของนิติบุคคล", () => {
  const corp: ClearingInput = {
    ...payable,
    ownerId: "corp",
    bankAccountId: "b1",
  };

  it("ตัวจริงบังคับหลักฐาน — ยืนยันเงินออกคือการบันทึกจริง", () => {
    expect(message(() => clear(corp))).toMatch(/ต้องแนบหลักฐาน/);
  });

  it("แนบแล้วผ่าน และได้บรรทัดเดิม", () => {
    const r = clear({ ...corp, attachments: EVIDENCE });
    expect(allLines(r).find((l) => isCashAccount(l.coaCode))?.credit).toBe(8_600);
  });

  it("นิติบุคคลต้องมีคู่ค้า", () => {
    const noContact = without(corp, "contactId");
    expect(message(() => clear({ ...noContact, attachments: EVIDENCE }))).toMatch(/คู่ค้า/);
  });

  it("draft ยังไม่บังคับหลักฐาน (ไฟล์แนบไม่เปลี่ยนคู่บัญชี) แต่บังคับบัญชีและยอด", () => {
    const r = buildClearingDraft(corp, TEST_RESOLVER);
    expect(allLines(r)).toHaveLength(2);
    expect(() => buildClearingDraft({ ...corp, bankAccountId: "" }, TEST_RESOLVER)).toThrow(
      PostingError
    );
    expect(() => buildClearingDraft({ ...corp, amount: 99_999 }, TEST_RESOLVER)).toThrow(
      PostingError
    );
  });
});

describe("ทุกหมวดที่ตั้งค้างได้ ต้องล้างได้จริง — และตัวเลขต้องถูกทุกหมวด", () => {
  const ACCRUABLE = TX_TYPES.flatMap((t) => t.subs.map((s) => ({ t, s }))).filter(({ s }) =>
    canAccrueFromForm(s)
  );

  it("มีหมวดให้ทดสอบ (กันเทสต์ผ่านเพราะลูปว่าง)", () => {
    expect(ACCRUABLE.length).toBeGreaterThan(0);
  });

  /**
   * **สายสะดุด ไม่ใช่เทสต์กฎ** — วันนี้หมวดที่ตั้งค้างได้ทุกตัวลงกระแสเงินสดหมวดดำเนินงาน
   * (บัญชีพัก 1200 · 1210 · 2100 มีทางล้างเฉพาะหมวด operating) ผลคือเคสด้านล่าง
   * **พิสูจน์ไม่ได้** ว่าเครื่องยนต์อ่านหมวด CF จากรายการต้นทางจริง หรือฮาร์ดโค้ด "operating" ไว้
   * สองอย่างนั้นให้ผลเหมือนกันเป๊ะกับตารางกฎชุดนี้
   *
   * ถ้าวันหนึ่งตารางกฎมีหมวดที่ตั้งค้างได้และลงหมวดลงทุน/จัดหาเงิน (เช่น เปิดทางล้าง
   * ให้ซื้อทรัพย์ค้างจ่าย) เทสต์นี้จะพังเพื่อเตือนว่า **ต้องเพิ่มเคสหมวดนั้นลงไป** —
   * ไม่งั้นช่องว่างนี้จะอยู่ต่อแบบไม่มีใครรู้ (เงินก้อนใหญ่ไปโผล่ผิดหมวดในงบกระแสเงินสด)
   */
  it("สายสะดุด: ถ้ามีหมวดตั้งค้างที่ไม่ใช่ดำเนินงาน ต้องเพิ่มเคสครอบคลุมหมวดนั้น", () => {
    expect([...new Set(ACCRUABLE.map(({ s }) => s.cashflow))]).toEqual(["operating"]);
  });

  it("ได้สองบรรทัดที่สมดุล · เงินสดหนึ่งบรรทัดผูกบัญชี · หมวด CF ตรงกับต้นทาง", () => {
    for (const { t, s } of ACCRUABLE) {
      const r = clear({
        ...receivable,
        typeKey: t.key,
        subCode: s.code,
        assetId: "rent1",
        contactId: "c1",
      });
      const l = allLines(r);
      assertBalanced(l);
      expect(l.length, s.code).toBe(2);

      const cashLines = l.filter((x) => isCashAccount(x.coaCode));
      expect(cashLines.length, s.code).toBe(1);
      expect(cashLines[0].bankAccountId, s.code).toBe("b4");
      expect(l.every((x) => x.cfCategory === s.cashflow), s.code).toBe(true);

      // ลูกหนี้ (สินทรัพย์) → เงินเข้า · เจ้าหนี้ (หนี้สิน) → เงินออก
      const accrualType = coa(s.accrualCoa!).type;
      expect(cashLines[0][accrualType === "asset" ? "debit" : "credit"], s.code).toBe(12_000);
      expect(l.find((x) => x.coaCode === s.accrualCoa), s.code).toBeDefined();
    }
  });

  it("คู่บัญชีของทุกหมวดมาจากตารางกฎ ไม่มีรหัสที่ฟังก์ชันคิดขึ้นเอง", () => {
    for (const { t, s } of ACCRUABLE) {
      const route = clearingSubsFor(s.accrualCoa!, s.cashflow)[0];
      const l = allLines(
        clear({ ...receivable, typeKey: t.key, subCode: s.code, assetId: "rent1", contactId: "c1" })
      );
      expect(l.find((x) => x.debit > 0)?.coaCode, s.code).toBe(route.dr);
      expect(l.find((x) => x.credit > 0)?.coaCode, s.code).toBe(route.cr);
    }
  });
});
