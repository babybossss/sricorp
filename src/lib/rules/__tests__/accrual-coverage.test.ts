import { describe, it, expect } from "vitest";
import {
  TX_TYPES,
  findSub,
  canAccrueFromForm,
  clearingSubsFor,
  accrualClearingRoutes,
  type SubCategory,
} from "../tx-rules";
import { COA, coa, isCashAccount } from "../coa";
import { findLayoutGaps, statementOf } from "../statements";
// เดินสองขั้นผ่าน engine ตัวจริง — ถ้ายืนยันแค่ตารางกฎ จะไม่รู้ว่า `cfCategory`
// ที่ลงบรรทัดจริงตรงกับหมวดต้นทางหรือไม่ ซึ่งเป็นจุดที่เงินไปโผล่ผิดหมวด
import { buildPosting, allLines } from "@/lib/ledger/posting";
import { PostingError } from "@/lib/ledger/types";

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
 *
 * เทสต์ชุดนี้ยืนยัน **กฎ** ไม่ใช่สิ่งที่โค้ดทำอยู่: เดินสองขั้นจริงผ่าน `buildPosting()`
 * (ตั้งค้าง → ล้าง) แล้วดูว่ายอดกลับมาเป็นศูนย์ และขาเงินสดตอนล้างไปลงกระแสเงินสด
 * หมวดเดียวกับรายการต้นทาง · ถ้าคนละหมวด เงิน 10 ล้านของการซื้อทรัพย์จะไปโผล่
 * Operating ทั้งที่ต้องเป็น Investing ซึ่งไม่มีทางเห็นจากหน้าจอ
 */
describe("ตั้งค้างได้ ต้องล้างได้ และล้างแล้วต้องลงกระแสเงินสดหมวดเดิม", () => {
  const formAccruable = allSubs.filter(canAccrueFromForm);

  /** เจ้าของและบัญชีฝั่ง personal — ไม่ต้องแนบเอกสารจึงเดินสองขั้นได้ครบในเทสต์ */
  const base = { amount: 12000, ownerId: "thanakorn", bankAccountId: "b4", assetId: "rent1", contactId: "c1" };
  const post = (sub: SubCategory, notYetPaid = false) =>
    allLines(buildPosting({ ...base, typeKey: findSub(sub.code)!.type.key, subCode: sub.code, notYetPaid }));
  const net = (lines: { coaCode: string; debit?: number; credit?: number }[], code: string) =>
    lines
      .filter((l) => l.coaCode === code)
      .reduce((acc, l) => acc + (l.debit ?? 0) - (l.credit ?? 0), 0);

  it("ทุกหมวดที่ตั้งค้างจากฟอร์มได้ ต้องมีทางล้างที่กระแสเงินสดหมวดเดียวกัน", () => {
    expect(formAccruable.length, "ต้องมีหมวดให้ทดสอบ").toBeGreaterThan(0);
    for (const s of formAccruable) {
      const routes = clearingSubsFor(s.accrualCoa!, s.cashflow);
      expect(
        routes.map((r) => r.code),
        `${s.code} พักที่ ${s.accrualCoa} (CF ${s.cashflow}) แต่ไม่มีหมวดล้างที่ CF ตรงกัน`
      ).not.toEqual([]);
    }
  });

  it("เดินสองขั้น: ตั้งค้างแล้วล้าง → บัญชีพักกลับเป็นศูนย์ และขาเงินสดอยู่หมวด CF เดิม", () => {
    for (const s of formAccruable) {
      const accrual = s.accrualCoa!;

      // ขั้นที่ 1 — ตั้งค้าง: ไม่มีบรรทัดเงินสด ยอดไปพักที่บัญชีพัก ไม่นับใน CF
      const step1 = post(s, true);
      expect(step1.some((l) => isCashAccount(l.coaCode)), `${s.code} ตั้งค้างแล้วยังมีบรรทัดเงินสด`).toBe(false);
      expect(net(step1, accrual), `${s.code} ยอดไม่ได้ไปพักที่ ${accrual}`).not.toBe(0);
      expect(step1.every((l) => l.cfCategory === "none"), `${s.code} ตั้งค้างแล้วยังนับใน CF`).toBe(true);

      // ขั้นที่ 2 — ล้าง: เงินเคลื่อนจริง บัญชีพักกลับเป็นศูนย์ และ CF ต้องเป็นหมวดของต้นทาง
      for (const route of clearingSubsFor(accrual, s.cashflow)) {
        const step2 = post(route);
        expect(net(step1, accrual) + net(step2, accrual), `${s.code} → ${route.code} ล้างไม่หมด`).toBe(0);

        const cash = step2.filter((l) => isCashAccount(l.coaCode));
        expect(cash.length, `${route.code} ไม่มีขาเงินสด`).toBeGreaterThan(0);
        for (const l of cash) {
          expect(
            l.cfCategory,
            `${s.code} (CF ${s.cashflow}) ล้างด้วย ${route.code} แล้วเงินไปโผล่ CF ${l.cfCategory}`
          ).toBe(s.cashflow);
        }
      }
    }
  });

  it("หมวดที่เพิ่มยอดบัญชีพัก ไม่ใช่ทางล้าง แม้จะแตะบัญชีเดียวกันและมีขาเงินสด", () => {
    // fin.deposit_received เครดิต 2200 = **ตั้ง**หนี้เงินมัดจำ · ทางล้างคือ fin.deposit_refund
    // ที่เดบิต 2200 · นับขาที่เพิ่มยอดเป็นทางล้าง = เชื่อว่าล้างได้ทั้งที่ล้างไม่ได้
    const routes = accrualClearingRoutes("2200").map((s) => s.code);
    expect(routes).toContain("fin.deposit_refund");
    expect(routes).not.toContain("fin.deposit_received");
  });

  it("1220 ยังไม่มีหมวดล้างเลยสักหมวด จึงตั้งค้างเข้ามันจากฟอร์มไม่ได้", () => {
    /**
     * ยืนยันสถานะจริงของตารางกฎวันนี้ ไม่ใช่สิ่งที่โค้ดคำนวณได้
     * `1220` รับยอดจากขายทรัพย์ · รับไถ่ถอน · กู้เงินเข้า · เพิ่มทุน ซึ่งทั้งหมดรอ
     * กลไกยืนยันรับ-จ่าย (C6) เป็นคนล้าง — ยังไม่มีหมวดคีย์มือที่เครดิต 1220 คู่กับเงินสด
     *
     * เทสต์นี้ **จะพังตอนเพิ่มหมวดล้าง 1220 ในอนาคต** ซึ่งถูกแล้ว:
     * คนที่เพิ่มต้องมาแก้บรรทัดนี้ และตอนนั้นต้องตอบให้ได้ว่าหมวดล้างที่เพิ่มมา
     * ลงกระแสเงินสดหมวดเดียวกับรายการต้นทางครบทุกหมวดหรือยัง (investing/financing
     * ใช้บัญชีพักตัวเดียวกัน แต่คนละหมวด CF) ไม่งั้นเปิดให้ตั้งค้างแล้วเงินไปผิดหมวด
     */
    expect(accrualClearingRoutes("1220")).toEqual([]);
    expect(formAccruable.filter((s) => s.accrualCoa === "1220").map((s) => s.code)).toEqual([]);
  });

  it("บัญชีพักที่ไม่มีทางล้างเลย ต้องไม่มีหมวดไหนตั้งค้างเข้ามันได้", () => {
    for (const account of new Set(allSubs.map((s) => s.accrualCoa).filter(Boolean) as string[])) {
      if (accrualClearingRoutes(account).length > 0) continue;
      expect(
        allSubs.filter((s) => s.accrualCoa === account && canAccrueFromForm(s)).map((s) => s.code),
        `${account} ไม่มีทางล้าง แต่ยังตั้งค้างได้`
      ).toEqual([]);
    }
  });

  it("หมวดที่ตั้งค้างจากฟอร์มได้ ต้องมีขาเงินสดให้แทนที่", () => {
    for (const s of formAccruable) {
      expect(s.dr === "1100" || s.cr === "1100", s.code).toBe(true);
    }
  });

  /**
   * เคส "ไม่ส่งข้อมูล"/"เส้นทางที่ยังไม่เปิด" — เทสต์ที่ส่งแต่หมวดที่ตั้งค้างได้
   * จะไม่มีวันแตะเส้นทางนี้ · ซื้อทรัพย์แบบยังไม่จ่ายต้องถูกปฏิเสธ **พร้อมเหตุผลตรงจุด**
   * ไม่ใช่ลงเจ้าหนี้ไว้แล้วให้ผู้ใช้ไปจ่ายด้วย fin.pay_payable ซึ่งเป็น Operating
   */
  it("ตั้งค้างหมวด investing ที่พักที่ 2100 ต้องถูกปฏิเสธ เพราะทางล้างอยู่คนละหมวด CF", () => {
    const investingAccruals = allSubs.filter(
      (s) => s.accrualCoa === "2100" && s.cashflow === "investing" && !canAccrueFromForm(s)
    );
    expect(investingAccruals.length, "ต้องมีหมวดลงทุนที่พักที่ 2100 ให้ทดสอบ").toBeGreaterThan(0);

    for (const s of investingAccruals) {
      let thrown: unknown;
      try {
        post(s, true);
      } catch (e) {
        thrown = e;
      }
      expect(thrown, `${s.code} ตั้งค้างผ่านได้ ทั้งที่ล้างแล้วเงินจะไปผิดหมวด CF`).toBeInstanceOf(PostingError);
      const message = (thrown as Error).message;
      expect(message, s.code).toMatch(/ตั้งค้างรับ-ค้างจ่ายไม่ได้/);
      // ต้องบอกเหตุผลจริง (กระแสเงินสดคนละหมวด) ไม่ใช่ข้อความรวมๆ ที่ชี้ผิดจุด
      expect(message, s.code).toMatch(/กระแสเงินสด/);
      expect(message, s.code).toMatch(/ลงทุน/);
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
