import { describe, it, expect } from "vitest";
import {
  buildCashflow,
  type CashflowInput,
  type CashflowSourceLine,
  type CashflowTxn,
} from "../cashflow";
import { PostingError } from "../types";
import { CF_LAYOUT } from "@/lib/rules/statements";
import type { CashflowSection } from "@/lib/rules/tx-rules";

/**
 * งบกระแสเงินสด **วิธีตรง** — เทสต์ชุดนี้กันเจ็ดเรื่องที่ถ้าผิดแล้วตัวเลขผิดเงียบๆ
 *
 *  1. ใช้ `cashDate` ไม่ใช่ `docDate`
 *  2. `void` ไม่นับ · **ใบกลับรายการนับ** (D-097/D-098)
 *  3. ส่วนมาจาก `cfCategory` ที่เก็บไว้ ไม่ใช่คำนวณใหม่จากตารางกฎ
 *  4. เงินก้อนเดียวอยู่บรรทัดเดียว ห้ามแบ่งตามบัญชีคู่
 *  5. งบรวมตัดรายการระหว่างกัน **เฉพาะเมื่ออีกฝ่ายอยู่ในชุดที่รวม**
 *  6. ด่านกระทบยอดกับบัญชี 11xx ต้องจับรูได้ ไม่ใช่โยนงบทิ้ง
 *  7. ข้อมูลขาดต้องดัง — throw หรือเข้า `anomalies` ห้ามเงียบ
 */

const CASH = "1100";
const CORP = "sri-corp";
const THANAKORN = "thanakorn";

const PERIOD = { periodStart: "2026-01-01", periodEnd: "2026-01-31" };

const ln = (
  coaCode: string,
  debit: number,
  credit: number,
  cfCategory: CashflowSection
): CashflowSourceLine => ({ coaCode, debit, credit, cfCategory });

const tx = (over: Partial<CashflowTxn> = {}): CashflowTxn => ({
  txnId: "t-1",
  ownerId: CORP,
  status: "posted",
  source: "manual",
  subCode: "inc.rent",
  docDate: "2026-01-05",
  cashDate: "2026-01-05",
  counterOwnerId: null,
  lines: [],
  ...over,
});

const run = (txns: CashflowTxn[], over: Partial<CashflowInput> = {}) =>
  buildCashflow({ txns, ownerIds: [CORP], ...PERIOD, ...over });

const section = (st: ReturnType<typeof buildCashflow>, s: "operating" | "investing" | "financing") =>
  st.sections.find((x) => x.section === s)!;

const lineAmount = (
  st: ReturnType<typeof buildCashflow>,
  s: "operating" | "investing" | "financing",
  name: string
) => section(st, s).lines.find((l) => l.line === name)?.amount;

/** ค่าเช่าเข้า 50,000 · เงินเข้าเป็นบวก */
const rentIn = (over: Partial<CashflowTxn> = {}) =>
  tx({
    subCode: "inc.rent",
    lines: [ln(CASH, 50_000, 0, "operating"), ln("4200", 0, 50_000, "operating")],
    ...over,
  });

/** ค่าน้ำค่าไฟออก 8,000 · เงินออกเป็นลบ */
const utilityOut = (over: Partial<CashflowTxn> = {}) =>
  tx({
    txnId: "t-2",
    subCode: "exp.utilities",
    lines: [ln("5110", 8_000, 0, "operating"), ln(CASH, 0, 8_000, "operating")],
    ...over,
  });

describe("ดำเนินงาน — เครื่องหมายและยอด", () => {
  it("ค่าเช่าเข้าเป็นบวก ค่าใช้จ่ายออกเป็นลบ และรวมกันเป็นสุทธิ", () => {
    const st = run([rentIn(), utilityOut()]);

    expect(lineAmount(st, "operating", "เงินสดรับจากค่าเช่าและค่าเช่าซื้อ")).toBe(50_000);
    expect(lineAmount(st, "operating", "เงินสดจ่ายค่าใช้จ่ายเกี่ยวกับทรัพย์สิน")).toBe(-8_000);
    expect(section(st, "operating").total).toBe(42_000);
    expect(section(st, "investing").total).toBe(0);
    expect(section(st, "financing").total).toBe(0);
    expect(st.netChange).toBe(42_000);
    expect(st.reconciled).toBe(true);
    expect(st.anomalies).toEqual([]);
  });

  it("เงินกู้รับเข้ากิจกรรมจัดหาเงิน ไม่ใช่รายได้", () => {
    const st = run([
      tx({
        subCode: "fin.loan_bank",
        lines: [ln(CASH, 3_000_000, 0, "financing"), ln("2410", 0, 3_000_000, "financing")],
      }),
    ]);
    expect(lineAmount(st, "financing", "เงินกู้รับ")).toBe(3_000_000);
    expect(section(st, "operating").total).toBe(0);
    expect(st.reconciled).toBe(true);
  });

  it("เศษสตางค์: ปัดยอดรวม ไม่ใช่ปัดทีละบรรทัดแล้วบวก", () => {
    const st = run([
      rentIn({ txnId: "a", lines: [ln(CASH, 0.1, 0, "operating"), ln("4200", 0, 0.1, "operating")] }),
      rentIn({ txnId: "b", lines: [ln(CASH, 0.1, 0, "operating"), ln("4200", 0, 0.1, "operating")] }),
      rentIn({ txnId: "c", lines: [ln(CASH, 0.1, 0, "operating"), ln("4200", 0, 0.1, "operating")] }),
    ]);
    expect(lineAmount(st, "operating", "เงินสดรับจากค่าเช่าและค่าเช่าซื้อ")).toBe(0.3);
    expect(st.netChange).toBe(0.3);
    expect(st.reconciled).toBe(true);
  });
});

describe("เงินก้อนเดียวอยู่บรรทัดเดียว", () => {
  it("ขายอสังหา 8 ล้าน (ตัดทรัพย์ 6 + กำไร 2) = ลงทุน 8 ล้านทั้งก้อน", () => {
    const st = run([
      tx({
        subCode: "inv.sell_re",
        lines: [
          ln(CASH, 8_000_000, 0, "investing"),
          ln("1500", 0, 6_000_000, "investing"),
          ln("4300", 0, 2_000_000, "investing"),
        ],
      }),
    ]);

    expect(lineAmount(st, "investing", "ขายอสังหาริมทรัพย์")).toBe(8_000_000);
    expect(section(st, "investing").total).toBe(8_000_000);
    // กำไร 2 ล้าน **ห้าม** ไปโผล่ฝั่งดำเนินงาน
    expect(section(st, "operating").total).toBe(0);
    expect(st.netChange).toBe(8_000_000);
    expect(st.reconciled).toBe(true);
  });
});

describe("วันที่ที่ใช้ตัดสินคือ cashDate", () => {
  it("เอกสารปีก่อน เงินเข้าในงวด → เข้างบ", () => {
    const st = run([rentIn({ docDate: "2025-12-28", cashDate: "2026-01-03" })]);
    expect(section(st, "operating").total).toBe(50_000);
  });

  it("เอกสารในงวด เงินเข้างวดถัดไป → ไม่เข้างบ", () => {
    const st = run([rentIn({ docDate: "2026-01-28", cashDate: "2026-02-03" })]);
    expect(section(st, "operating").total).toBe(0);
    expect(st.netChange).toBe(0);
    expect(st.reconciled).toBe(true);
  });

  it("รายการค้างรับ (cashDate null · ไม่มีบรรทัดเงินสด) ไม่เข้างบเลย", () => {
    const st = run([
      tx({
        subCode: "inc.rent",
        cashDate: null,
        lines: [ln("1200", 50_000, 0, "none"), ln("4200", 0, 50_000, "none")],
      }),
    ]);
    expect(st.netChange).toBe(0);
    expect(section(st, "operating").total).toBe(0);
    expect(st.reconciled).toBe(true);
    expect(st.anomalies).toEqual([]);
  });
});

describe("void ไม่นับ · ใบกลับรายการนับ", () => {
  it("รายการที่ void ตัดออกจากงบ (D-098)", () => {
    const st = run([rentIn({ txnId: "v-1", status: "void" })]);
    expect(section(st, "operating").total).toBe(0);
    expect(st.closingCash).toBe(0);
    expect(st.reconciled).toBe(true);
  });

  it("ใบกลับรายการ (source = reverse) นับในงบ", () => {
    const st = run([
      tx({
        txnId: "r-1",
        source: "reverse",
        subCode: "inc.rent",
        cashDate: "2026-01-20",
        docDate: "2026-01-20",
        lines: [ln(CASH, 0, 50_000, "operating"), ln("4200", 50_000, 0, "operating")],
      }),
    ]);
    expect(section(st, "operating").total).toBe(-50_000);
    expect(st.reconciled).toBe(true);
  });

  it("ต้นฉบับ + ใบกลับรายการ = ศูนย์", () => {
    const st = run([
      rentIn(),
      tx({
        txnId: "r-1",
        source: "reverse",
        subCode: "inc.rent",
        cashDate: "2026-01-20",
        docDate: "2026-01-20",
        lines: [ln(CASH, 0, 50_000, "operating"), ln("4200", 50_000, 0, "operating")],
      }),
    ]);
    expect(lineAmount(st, "operating", "เงินสดรับจากค่าเช่าและค่าเช่าซื้อ")).toBe(0);
    expect(st.netChange).toBe(0);
    expect(st.reconciled).toBe(true);
  });
});

describe("โอนระหว่างบัญชีตัวเอง", () => {
  it("cfCategory none และหักกันเป็นศูนย์ → ไม่เข้างบและไม่ใช่ความผิดปกติ", () => {
    const st = run([
      tx({
        subCode: "trf.internal",
        lines: [ln(CASH, 100_000, 0, "none"), ln(CASH, 0, 100_000, "none")],
      }),
    ]);
    expect(st.netChange).toBe(0);
    expect(st.anomalies).toEqual([]);
    expect(st.reconciled).toBe(true);
  });

  it("บรรทัดเงินสด cfCategory none ที่ไม่หักกันเป็นศูนย์ → ดังทั้งสองด่าน", () => {
    const st = run([
      tx({
        subCode: "trf.internal",
        lines: [ln(CASH, 100_000, 0, "none"), ln("1200", 0, 100_000, "none")],
      }),
    ]);
    expect(st.netChange).toBe(0);
    expect(st.anomalies.map((a) => a.kind)).toContain("cashOutsideStatement");
    expect(st.reconciled).toBe(false);
    expect(st.difference).toBe(-100_000);
  });
});

/** ขาคู่กันของรายการข้ามผู้ถือ — กู้ยืมระหว่างกัน 1 ล้าน */
const icPayer = tx({
  txnId: "ic-pay",
  ownerId: CORP,
  counterOwnerId: THANAKORN,
  subCode: "trf.internal",
  lines: [ln("1310", 1_000_000, 0, "investing"), ln(CASH, 0, 1_000_000, "investing")],
});

const icReceiver = tx({
  txnId: "ic-recv",
  ownerId: THANAKORN,
  counterOwnerId: CORP,
  subCode: "trf.internal",
  lines: [ln(CASH, 1_000_000, 0, "financing"), ln("2310", 0, 1_000_000, "financing")],
});

describe("ข้ามผู้ถือ — สองมุมมอง", () => {
  it("งบรายผู้ถือ: ฝ่ายจ่ายเงินออกจริง", () => {
    const st = run([icPayer, icReceiver], { ownerIds: [CORP] });
    expect(section(st, "investing").total).toBe(-1_000_000);
    expect(st.netChange).toBe(-1_000_000);
    expect(st.eliminated).toEqual([]);
    expect(st.reconciled).toBe(true);
  });

  it("งบรายผู้ถือ: ฝ่ายรับเงินเข้าจริง", () => {
    const st = run([icPayer, icReceiver], { ownerIds: [THANAKORN] });
    expect(section(st, "financing").total).toBe(1_000_000);
    expect(st.netChange).toBe(1_000_000);
    expect(st.reconciled).toBe(true);
  });

  it("งบรวมที่มีทั้งสองฝ่าย: ตัดออกเป็นศูนย์", () => {
    const st = run([icPayer, icReceiver], { ownerIds: [CORP, THANAKORN] });
    expect(st.netChange).toBe(0);
    expect(section(st, "investing").total).toBe(0);
    expect(section(st, "financing").total).toBe(0);
    expect(st.eliminated.map((e) => e.txnId).sort()).toEqual(["ic-pay", "ic-recv"]);
    expect(st.reconciled).toBe(true);
  });

  it("งบรวมที่อีกฝ่าย **ไม่อยู่ในชุด** → ห้ามตัด (เงินออกจากกลุ่มจริง)", () => {
    // รวมแค่สองนิติบุคคล แต่โอนไปบุคคลที่ไม่อยู่ในชุด
    const st = run([icPayer, icReceiver], { ownerIds: [CORP, "sri-holding"] });
    expect(st.eliminated).toEqual([]);
    expect(section(st, "investing").total).toBe(-1_000_000);
    expect(st.netChange).toBe(-1_000_000);
    expect(st.reconciled).toBe(true);
  });

  it("ตัดคู่ที่เงินสดไม่หักกันเป็นศูนย์ → ดังใน anomalies", () => {
    // จ่ายแทนกัน: ฝ่ายจ่ายเงินออกจริง ฝ่ายรับลงค่าใช้จ่ายค้างจ่าย (ไม่มีขาเงินสด)
    const st = run(
      [
        icPayer,
        tx({
          txnId: "ic-recv-nocash",
          ownerId: THANAKORN,
          counterOwnerId: CORP,
          subCode: "trf.internal",
          cashDate: null,
          lines: [ln("5110", 1_000_000, 0, "none"), ln("2310", 0, 1_000_000, "none")],
        }),
      ],
      { ownerIds: [CORP, THANAKORN] }
    );
    expect(st.anomalies.map((a) => a.kind)).toContain("intercompanyNotNetted");
    expect(st.reconciled).toBe(false);
    expect(st.difference).toBe(1_000_000);
  });
});

describe("ด่านกระทบยอด", () => {
  it("ลงตัว → reconciled true และยอดต้น-ปลายงวดถูก", () => {
    const st = run([
      rentIn({ txnId: "prev", docDate: "2025-12-10", cashDate: "2025-12-10" }),
      rentIn(),
      utilityOut(),
    ]);
    expect(st.openingCash).toBe(50_000);
    expect(st.closingCash).toBe(92_000);
    expect(st.netChange).toBe(42_000);
    expect(st.difference).toBe(0);
    expect(st.reconciled).toBe(true);
  });

  it("ใบกลับรายการที่ขาด cashDate → reconciled false พร้อมส่วนต่าง ไม่ใช่โยนงบทิ้ง", () => {
    const st = run([
      rentIn(),
      tx({
        txnId: "r-nocashdate",
        source: "reverse",
        subCode: "inc.rent",
        docDate: "2026-01-20",
        cashDate: null,
        lines: [ln(CASH, 0, 50_000, "operating"), ln("4200", 50_000, 0, "operating")],
      }),
    ]);

    // งบยังดูได้ — ยอดที่ค้างไว้ยังอยู่ให้เห็น
    expect(section(st, "operating").total).toBe(50_000);
    expect(st.closingCash).toBe(0);
    expect(st.netChange).toBe(50_000);
    expect(st.reconciled).toBe(false);
    expect(st.difference).toBe(50_000);
    expect(st.anomalies.map((a) => a.kind)).toContain("cashWithoutCashDate");
    expect(st.anomalies.map((a) => a.kind)).toContain("unreconciled");
  });
});

describe("cfCategory ที่เก็บไว้ขัดกับโครงงบ", () => {
  it("ยึดของที่เก็บไว้ แต่ต้องโผล่ใน anomalies ไม่ใช่เลือกข้างเงียบๆ", () => {
    const st = run([
      rentIn({
        lines: [ln(CASH, 50_000, 0, "investing"), ln("4200", 0, 50_000, "investing")],
      }),
    ]);

    // ของที่เก็บไว้ชนะ (ประวัติเปลี่ยนไม่ได้) → ยอดอยู่ฝั่งลงทุน
    expect(section(st, "investing").total).toBe(50_000);
    expect(section(st, "operating").total).toBe(0);

    const conflict = st.anomalies.find((a) => a.kind === "sectionConflict");
    expect(conflict).toBeDefined();
    expect(conflict!.txnId).toBe("t-1");
    expect(conflict!.message).toContain("inc.rent");
    // ยอดไม่หาย → ยังกระทบยอดได้
    expect(st.reconciled).toBe(true);
  });

  it("บรรทัดเงินสดของรายการเดียวกันมี cfCategory ไม่ตรงกัน → ดัง", () => {
    const st = run([
      tx({
        subCode: "inc.rent",
        lines: [
          ln(CASH, 50_000, 0, "operating"),
          ln(CASH, 0, 20_000, "financing"),
          ln("4200", 0, 30_000, "operating"),
        ],
      }),
    ]);
    expect(st.anomalies.map((a) => a.kind)).toContain("mixedCfCategory");
    // เงินไม่หายไปจากงบ จึงยังกระทบยอดได้
    expect(st.netChange).toBe(30_000);
    expect(st.reconciled).toBe(true);
  });
});

describe("ข้อมูลขาด — ต้องชัดเจน ห้ามเงียบ", () => {
  it("มี cashDate แต่ไม่มีบรรทัดเงินสดเลย → เข้า anomalies", () => {
    const st = run([
      tx({
        subCode: "inc.rent",
        cashDate: "2026-01-09",
        lines: [ln("1200", 50_000, 0, "operating"), ln("4200", 0, 50_000, "operating")],
      }),
    ]);
    expect(st.anomalies.map((a) => a.kind)).toContain("cashDateWithoutCashLine");
    expect(st.netChange).toBe(0);
    expect(st.reconciled).toBe(true);
  });

  it("subCode ที่ไม่มีในโครงงบ → เข้า anomalies และยอดไม่หาย", () => {
    const st = run([
      tx({
        subCode: "zzz.not_in_layout",
        lines: [ln(CASH, 1_000, 0, "operating"), ln("4900", 0, 1_000, "operating")],
      }),
    ]);
    const a = st.anomalies.find((x) => x.kind === "subCodeNotInLayout");
    expect(a).toBeDefined();
    expect(a!.message).toContain("zzz.not_in_layout");
    expect(section(st, "operating").total).toBe(1_000);
    expect(st.reconciled).toBe(true);
  });

  it("รายการข้ามผู้ถือ (trf.internal) ไม่มีบรรทัดในโครงงบ → ยอดอยู่ครบและมี anomaly", () => {
    const st = run([icPayer, icReceiver], { ownerIds: [CORP] });
    expect(st.anomalies.map((a) => a.kind)).toContain("subCodeNotInLayout");
    expect(section(st, "investing").total).toBe(-1_000_000);
  });

  it("ฟิลด์บังคับที่หายไป → PostingError ไม่ใช่เดา", () => {
    expect(() => run([rentIn({ ownerId: "" })])).toThrow(PostingError);
    expect(() => run([rentIn({ txnId: "" })])).toThrow(PostingError);
    expect(() => run([rentIn({ subCode: "" })])).toThrow(PostingError);
    expect(() => run([rentIn({ docDate: "05/01/2026" })])).toThrow(PostingError);
    expect(() => run([rentIn({ cashDate: "2026-02-30" })])).toThrow(PostingError);
    expect(() => run([rentIn({ status: "draft" as never })])).toThrow(PostingError);
  });

  it("ฟิลด์ที่ผู้เรียกเว้นไว้ (ไม่ส่งมาเลย) → PostingError ไม่ใช่ถือว่าไม่มี", () => {
    const noCashDate = { ...rentIn() } as Record<string, unknown>;
    delete noCashDate.cashDate;
    expect(() => run([noCashDate as unknown as CashflowTxn])).toThrow(PostingError);

    const noCounter = { ...rentIn() } as Record<string, unknown>;
    delete noCounter.counterOwnerId;
    expect(() => run([noCounter as unknown as CashflowTxn])).toThrow(PostingError);

    const noCf = tx({ lines: [{ coaCode: CASH, debit: 10, credit: 0 } as CashflowSourceLine] });
    expect(() => run([noCf])).toThrow(PostingError);
  });

  it("งวดและชุดผู้ถือที่ไม่สมเหตุสมผล → PostingError", () => {
    expect(() => run([], { periodStart: "2026-02-01", periodEnd: "2026-01-31" })).toThrow(PostingError);
    expect(() => run([], { ownerIds: [] })).toThrow(PostingError);
    expect(() => run([], { ownerIds: [CORP, CORP] })).toThrow(PostingError);
  });

  it("ยอดเงินที่ไม่ใช่ตัวเลขหรือติดลบ → PostingError", () => {
    expect(() => run([rentIn({ lines: [ln(CASH, Number.NaN, 0, "operating")] })])).toThrow(PostingError);
    expect(() => run([rentIn({ lines: [ln(CASH, -5, 0, "operating")] })])).toThrow(PostingError);
  });
});

describe("งวดว่าง", () => {
  it("ไม่มีรายการ → ทุกบรรทัดเป็น 0 · reconciled true · ไม่ throw", () => {
    const st = run([]);

    expect(st.sections).toHaveLength(CF_LAYOUT.length);
    for (const sec of st.sections) {
      expect(sec.total).toBe(0);
      for (const l of sec.lines) expect(l.amount).toBe(0);
    }
    // ทุกบรรทัดของโครงงบต้องมีอยู่ ไม่ใช่หายไปเพราะยอดเป็นศูนย์
    const names = st.sections.flatMap((s) => s.lines.map((l) => l.line));
    for (const sec of CF_LAYOUT) for (const l of sec.lines) expect(names).toContain(l.line);

    expect(st.netChange).toBe(0);
    expect(st.openingCash).toBe(0);
    expect(st.closingCash).toBe(0);
    expect(st.reconciled).toBe(true);
    expect(st.difference).toBe(0);
    expect(st.anomalies).toEqual([]);
  });

  it("ผู้ถือที่ไม่อยู่ในชุด ไม่เข้างบ", () => {
    const st = run([rentIn({ ownerId: THANAKORN })], { ownerIds: [CORP] });
    expect(st.netChange).toBe(0);
    expect(st.closingCash).toBe(0);
    expect(st.reconciled).toBe(true);
  });
});
