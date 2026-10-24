import { describe, it, expect } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { buildPosting } from "@/lib/ledger/posting";
import type { PostingInput } from "@/lib/ledger/types";
import { TEST_RESOLVER } from "@/lib/ledger/__tests__/fixture-resolver";
import { BS_LAYOUT, PL_LAYOUT } from "@/lib/rules/statements";
import { COA } from "@/lib/rules/coa";
import {
  balanceSheetCash,
  buildBalanceSheet,
  buildCashFlowReport,
  buildProfitLoss,
  buildUnrealised,
  fiscalYear,
  ownersInView,
  parseFiscalYear,
  unrealisedEquityCodes,
  type StmtLine,
} from "../statements";
import { fetchAllPages } from "../paged";

/* ------------------------------------------------------------------ *
 * สมุดทดสอบ — ทุกบรรทัดมาจาก buildPosting() ตัวจริง (ไม่เขียนคู่บัญชีเอง)
 * ------------------------------------------------------------------ */

const TK = "thanakorn";
const TW = "thanawin";
let seq = 0;

type Meta = { docDate: string; cashDate: string | null; source?: string };

/** ลงรายการผ่าน engine แล้วแปลงเป็นบรรทัดสมุด — แต่ละ transaction (ผู้ถือ) ได้ id ของตัวเอง */
function post(input: PostingInput, meta: Meta): StmtLine[] {
  const result = buildPosting(input, TEST_RESOLVER);
  const sub = input.subCode;
  return result.transactions.flatMap((t) => {
    const txnId = `t${++seq}`;
    return t.lines.map((l) => ({
      txnId,
      ownerId: t.ownerId,
      subCode: sub,
      docDate: meta.docDate,
      cashDate: meta.cashDate,
      source: meta.source ?? "manual",
      counterOwnerId: t.counterOwnerId ?? null,
      intercompanyNature: t.intercompanyNature ?? null,
      coaCode: l.coaCode,
      debit: l.debit,
      credit: l.credit,
      cfCategory: l.cfCategory ?? null,
      currency: l.currency ?? null,
    }));
  });
}

const rentBase = { typeKey: "income" as const, subCode: "inc.rent", ownerId: TK, assetId: "rent1", contactId: "c1" };

function ledger(): StmtLine[] {
  const L: StmtLine[] = [];
  // ---- ปีก่อน (2025): กำไร 50,000 ที่ยังไม่ปิดเข้า 3300 ----
  L.push(...post({ ...rentBase, amount: 50_000, bankAccountId: "b4" }, { docDate: "2025-12-01", cashDate: "2025-12-02" }));
  // ---- ปี 2026 ----
  L.push(...post({ typeKey: "finance_in", subCode: "fin.capital", amount: 1_000_000, ownerId: TK, bankAccountId: "b4", contactId: "c1" }, { docDate: "2026-01-05", cashDate: "2026-01-05" }));
  L.push(...post({ typeKey: "invest_buy", subCode: "inv.buy_re", amount: 800_000, ownerId: TK, bankAccountId: "b4", assetId: "rent1" }, { docDate: "2026-02-01", cashDate: "2026-02-01" }));
  L.push(...post({ ...rentBase, amount: 12_000, bankAccountId: "b4" }, { docDate: "2026-03-01", cashDate: "2026-03-03" }));
  L.push(...post({ ...rentBase, amount: 20_000, notYetPaid: true }, { docDate: "2026-03-05", cashDate: null })); // ค้างรับ
  L.push(...post({ typeKey: "expense", subCode: "exp.repair", amount: 3_000, ownerId: TK, bankAccountId: "b4", assetId: "rent1", contactId: "c5" }, { docDate: "2026-04-01", cashDate: "2026-04-01" }));
  // ---- ข้ามผู้ถือ: ธนากรให้ธนวินท์ยืม 100,000 ----
  L.push(
    ...post(
      { typeKey: "transfer", subCode: "trf.internal", amount: 100_000, ownerId: TK, bankAccountId: "b4", transferToBankAccountId: "b5", intercompanyNature: "loan" },
      { docDate: "2026-05-01", cashDate: "2026-05-01" }
    )
  );
  return L;
}

const reval = (): StmtLine[] =>
  post(
    {
      typeKey: "adjust",
      subCode: "adj.revalue_securities_up",
      amount: 460_000,
      ownerId: TK,
      assetId: "stock1",
      revaluation: { currency: "USD", rateToThb: 36.5, valueOriginal: 40_000, valueThb: 1_460_000 },
    },
    { docDate: "2026-06-30", cashDate: null }
  );

const ALL = [TK, TW];
const YEAR = 2026;
const net = (l: StmtLine[], owners = ALL) => buildProfitLoss(l, { year: YEAR, ownerIds: owners }).netProfit;

/* ------------------------------------------------------------------ */

describe("ข้อ 1 · งบแสดงฐานะการเงินต้องดุล — ทุกผู้ถือและมุมมองรวม", () => {
  const L = [...ledger(), ...reval()];

  it("สินทรัพย์ = หนี้สิน + ส่วนของเจ้าของ ทั้งรายผู้ถือและรวม", () => {
    for (const owners of [[TK], [TW], ALL]) {
      const bs = buildBalanceSheet(L, { year: YEAR, ownerIds: owners });
      expect(bs.difference, owners.join()).toBe(0);
      expect(bs.balanced).toBe(true);
      expect(bs.totalAssets).toBe(bs.totalLiabilities + bs.totalEquity);
      expect(bs.unmapped).toEqual([]);
    }
  });

  it("เทสต์นี้แดงได้: ถ้าบรรทัดหนึ่งหายไป งบไม่ดุลและบอกส่วนต่าง", () => {
    const broken = L.filter((l, i) => !(l.coaCode === "1100" && i === L.findIndex((x) => x.coaCode === "1100" && x.ownerId === TK && x.docDate === "2026-01-05")));
    const bs = buildBalanceSheet(broken, { year: YEAR, ownerIds: [TK] });
    expect(bs.balanced).toBe(false);
    expect(bs.difference).toBe(-1_000_000);
  });

  it("ตัวเลขรู้ล่วงหน้า (ธนากรเดี่ยว): เงินสด 1,019,000... ตามสมุดที่ลงจริง", () => {
    const bs = buildBalanceSheet(L, { year: YEAR, ownerIds: [TK] });
    // ปีก่อน +50,000 · ทุน +1,000,000 · ซื้ออสังหา −800,000 · ค่าเช่า +12,000 · ซ่อม −3,000 · ให้ยืม −100,000
    expect(balanceSheetCash(bs)).toBe(159_000);
    const ar = bs.groups.flatMap((g) => g.lines).find((l) => l.codes.includes("1200"))!;
    expect(ar.amount).toBe(20_000);
    expect(bs.totalAssets).toBe(159_000 + 20_000 + 800_000 + 100_000 + 460_000);
  });

  it("มุมมองรวม: รายการระหว่างกันถูกตัดออกทั้งสองฝั่ง และงบยังดุล", () => {
    const solo = buildBalanceSheet(L, { year: YEAR, ownerIds: [TK] });
    const soloIc = solo.groups.flatMap((g) => g.lines).find((l) => l.codes.includes("1310"))!;
    expect(soloIc.amount).toBe(100_000);

    const all = buildBalanceSheet(L, { year: YEAR, ownerIds: ALL });
    const ic = all.groups.flatMap((g) => g.lines).filter((l) => l.codes.includes("1310") || l.codes.includes("2310"));
    expect(ic.map((l) => l.amount)).toEqual([0, 0]);
    expect(all.eliminated).toBe(100_000);
    expect(all.balanced).toBe(true);
  });
});

describe("ข้อ 2 · กำไรสะสมในงบแสดงฐานะการเงิน ต้องตรงกับกำไรสุทธิในงบกำไรขาดทุน", () => {
  const L = [...ledger(), ...reval()];

  it("กำไรสุทธิปีนี้ในงบฐานะ = กำไรสุทธิของงบกำไรขาดทุน (29,000) และปีก่อนรวมเป็นกำไรสะสม (50,000)", () => {
    const pl = buildProfitLoss(L, { year: YEAR, ownerIds: [TK] });
    const bs = buildBalanceSheet(L, { year: YEAR, ownerIds: [TK] });
    expect(pl.netProfit).toBe(32_000 - 3_000); // 12,000 + 20,000 − 3,000
    expect(bs.retained.currentYear).toBe(pl.netProfit);
    expect(bs.retained.priorYears).toBe(50_000);
    expect(bs.retained.total).toBe(79_000);
    const lines = bs.groups.filter((g) => g.side === "equity").flatMap((g) => g.lines);
    const shown = lines.filter((l) => l.note).reduce((t, l) => t + l.amount, 0);
    expect(shown).toBe(79_000);
  });

  it("ปีถัดไป: กำไรปี 2026 กลายเป็นกำไรสะสมยกมา และงบยังดุล", () => {
    const bs = buildBalanceSheet(L, { year: 2027, ownerIds: [TK] });
    expect(bs.retained.currentYear).toBe(0);
    expect(bs.retained.priorYears).toBe(79_000);
    expect(bs.balanced).toBe(true);
  });

  it("ทุกบัญชีในผังมีที่ลงในงบดุลหรืองบกำไรขาดทุน (ไม่มียอดหายเงียบ)", () => {
    const placed = new Set([...BS_LAYOUT.flatMap((g) => g.lines.flatMap((l) => l.codes)), ...PL_LAYOUT.flatMap((s) => s.lines.flatMap((l) => l.codes))]);
    expect(COA.filter((a) => !placed.has(a.code)).map((a) => a.code)).toEqual([]);
  });
});

describe("ข้อ 3 · ตีราคาทรัพย์ขึ้น → กำไรขาดทุนไม่ขยับแม้แต่บาทเดียว ส่วนของเจ้าของเพิ่ม", () => {
  it("งบกำไรขาดทุนก่อนและหลังตีราคาเหมือนกันทุกบรรทัด", () => {
    const base = ledger();
    const withReval = [...base, ...reval()];
    const a = buildProfitLoss(base, { year: YEAR, ownerIds: [TK] });
    const b = buildProfitLoss(withReval, { year: YEAR, ownerIds: [TK] });
    expect(b).toEqual(a);
    expect(b.netProfit).toBe(29_000);
  });

  it("ส่วนของเจ้าของเพิ่มเท่าที่ตีขึ้น (460,000) ที่บรรทัด 3400 และงบดุล", () => {
    const base = ledger();
    const before = buildBalanceSheet(base, { year: YEAR, ownerIds: [TK] });
    const after = buildBalanceSheet([...base, ...reval()], { year: YEAR, ownerIds: [TK] });
    expect(after.totalEquity - before.totalEquity).toBe(460_000);
    expect(after.totalAssets - before.totalAssets).toBe(460_000);
    expect(after.balanced).toBe(true);
    const line = after.groups.flatMap((g) => g.lines).find((l) => l.codes.includes("3400"))!;
    expect(line.amount).toBe(460_000);
    expect(line.line).toMatch(/ยังไม่เกิดขึ้นจริง/);
  });

  it("3400/3410 ไม่มีทางอยู่ในงบกำไรขาดทุน และกล่อง 'ยังไม่เกิดจริง' แยกต่างหาก ไม่รวมกับกำไรสุทธิ", () => {
    const plCodes = PL_LAYOUT.flatMap((s) => s.lines.flatMap((l) => l.codes));
    for (const c of unrealisedEquityCodes()) expect(plCodes).not.toContain(c);

    const box = buildUnrealised([...ledger(), ...reval()], { year: YEAR, ownerIds: [TK] });
    expect(box.rows.map((r) => r.code)).toEqual(unrealisedEquityCodes());
    expect(box.rows.find((r) => r.code === "3400")).toMatchObject({ opening: 0, movement: 460_000, closing: 460_000 });
    expect(box.total).toBe(460_000);
    // งบกำไรขาดทุนมีกำไรสุทธิเท่าเดิม ไม่ว่ากล่องนี้จะเป็นเท่าไร
    expect(net([...ledger(), ...reval()], [TK])).toBe(29_000);
  });

  it("ชุดบัญชี 'ยังไม่เกิดจริง' ฝั่ง TS ตรงกับ fn_unrealised_equity_coas() ใน migration ล่าสุด", () => {
    const dir = path.join(process.cwd(), "supabase/migrations");
    const sql = readdirSync(dir)
      .sort()
      .filter((f) => f.endsWith(".sql"))
      .map((f) => readFileSync(path.join(dir, f), "utf8"))
      .filter((s) => /function fn_unrealised_equity_coas\(\)/.test(s))
      .pop();
    if (!sql) throw new Error("หา fn_unrealised_equity_coas() ใน migration ไม่เจอ — เทสต์นี้ต้องไม่ผ่านด้วยชุดว่าง");
    const m = /fn_unrealised_equity_coas\(\) returns text\[\][\s\S]*?array\[([^\]]+)\]/.exec(sql);
    const codes = [...(m?.[1] ?? "").matchAll(/'(\d{4})'/g)].map((x) => x[1]);
    expect(codes.length).toBeGreaterThan(0);
    expect([...unrealisedEquityCodes()].sort()).toEqual([...codes].sort());
  });
});

describe("ข้อ 4 · บัญชี FCD: แปลงค่าไม่เข้างบกำไรขาดทุน · แลกจริงจึงเข้า", () => {
  const FX = { currency: "USD", balanceOriginal: 10_000, bookRateToThb: 36.5, bookRateDate: "2026-10-31", newRateToThb: 37, newRateDate: "2026-11-30" };
  const translate = () =>
    post(
      { typeKey: "transfer", subCode: "trf.fx_translate_up", amount: 5_000, ownerId: TK, bankAccountId: "b4usd", fxTranslation: FX },
      { docDate: "2026-11-30", cashDate: "2026-11-30" }
    );

  it("แปลงค่าขึ้น 5,000 → กำไรขาดทุนไม่ขยับ · 3410 เพิ่ม 5,000 ในส่วนของเจ้าของ · งบดุล", () => {
    const base = ledger();
    const withFx = [...base, ...translate()];
    expect(buildProfitLoss(withFx, { year: YEAR, ownerIds: [TK] })).toEqual(buildProfitLoss(base, { year: YEAR, ownerIds: [TK] }));
    const bs0 = buildBalanceSheet(base, { year: YEAR, ownerIds: [TK] });
    const bs1 = buildBalanceSheet(withFx, { year: YEAR, ownerIds: [TK] });
    expect(bs1.totalEquity - bs0.totalEquity).toBe(5_000);
    expect(bs1.balanced).toBe(true);
    expect(buildUnrealised(withFx, { year: YEAR, ownerIds: [TK] }).rows.find((r) => r.code === "3410")?.closing).toBe(5_000);
  });

  it("แปลงค่าไม่ใช่กระแสเงินสดของงวด: อยู่ในบรรทัดผลกระทบอัตราแลกเปลี่ยน และงบกระแสเงินสดกระทบยอดลงตัว", () => {
    const L = [...ledger(), ...translate()];
    const bs = buildBalanceSheet(L, { year: YEAR, ownerIds: [TK] });
    const cf = buildCashFlowReport(L, { year: YEAR, ownerIds: [TK], balanceSheet: bs });
    expect(cf.statement.fxEffect).toBe(5_000);
    expect(cf.statement.reconciled).toBe(true);
    expect(cf.statement.closingCash).toBe(balanceSheetCash(bs));
  });

  it("แลกจริงที่ 37.50 (ต้นทุน 36.50) → กำไรจริง 10,000 เข้างบกำไรขาดทุน (4330) และ 3410 ถูกล้างเป็นศูนย์", () => {
    const base = [...ledger(), ...translate()];
    const conv = post(
      {
        typeKey: "transfer",
        subCode: "trf.fx_convert",
        amount: 375_000,
        ownerId: TK,
        bankAccountId: "b4usd",
        transferToBankAccountId: "b4b",
        fxConversion: { currency: "USD", amountOriginal: 10_000, balanceOriginalBefore: 10_000, bookRateToThb: 37, bookRateDate: "2026-11-30", dealRateToThb: 37.5, dealRateDate: "2026-12-31", unrealizedBefore: 5_000 },
      },
      { docDate: "2026-12-31", cashDate: "2026-12-31" }
    );
    // ก่อนแลก: แปลงค่าขึ้น 5,000 ยังไม่เข้า P&L · หลังแลก: กำไรจริง 375,000 − ต้นทุน 365,000 = 10,000 เข้า P&L ครั้งเดียว
    expect(net(base, [TK])).toBe(29_000);
    expect(net([...base, ...conv], [TK])).toBe(39_000);
    const pl = buildProfitLoss([...base, ...conv], { year: YEAR, ownerIds: [TK] });
    expect(pl.sections.flatMap((s) => s.lines).find((l) => l.codes.includes("4330"))!.amount).toBe(10_000);
    expect(buildUnrealised([...base, ...conv], { year: YEAR, ownerIds: [TK] }).rows.find((r) => r.code === "3410")?.closing).toBe(0);
    expect(buildBalanceSheet([...base, ...conv], { year: YEAR, ownerIds: [TK] }).balanced).toBe(true);
  });
});

describe("ข้อ 5 · เงินสดปลายงวดในงบกระแสเงินสด = เงินสดในงบแสดงฐานะการเงิน เป๊ะ", () => {
  it("ทุกผู้ถือและมุมมองรวม", () => {
    const L = [...ledger(), ...reval()];
    for (const owners of [[TK], [TW], ALL]) {
      const bs = buildBalanceSheet(L, { year: YEAR, ownerIds: owners });
      const cf = buildCashFlowReport(L, { year: YEAR, ownerIds: owners, balanceSheet: bs });
      expect(cf.statement.reconciled, owners.join()).toBe(true);
      expect(cf.statement.closingCash, owners.join()).toBe(balanceSheetCash(bs));
      expect(cf.cashInTransit).toBe(0);
      expect(cf.tiesOut).toBe(true);
    }
    // ตัวเลขรู้ล่วงหน้า: เปิด 50,000 → ปิด 159,000
    const solo = buildCashFlowReport(L, { year: YEAR, ownerIds: [TK], balanceSheet: buildBalanceSheet(L, { year: YEAR, ownerIds: [TK] }) });
    expect(solo.statement.openingCash).toBe(50_000);
    expect(solo.statement.netChange).toBe(109_000);
    expect(solo.statement.closingCash).toBe(159_000);
  });

  it("รายการที่เอกสารลงสิ้นปีแต่เงินเคลื่อนปีหน้า → ส่วนต่างอธิบายได้ตรงเป็น 'เงินสดระหว่างทาง' ไม่หายเงียบ", () => {
    const straddle = post({ ...rentBase, amount: 7_000, bankAccountId: "b4" }, { docDate: "2026-12-30", cashDate: "2027-01-02" });
    const L = [...ledger(), ...straddle];
    const bs = buildBalanceSheet(L, { year: YEAR, ownerIds: [TK] });
    const cf = buildCashFlowReport(L, { year: YEAR, ownerIds: [TK], balanceSheet: bs });
    expect(cf.statement.closingCash).toBe(159_000);
    expect(balanceSheetCash(bs)).toBe(166_000);
    expect(cf.cashInTransit).toBe(7_000);
    expect(cf.tiesOut).toBe(false);
  });
});

describe("ข้อ 6 · ยังไม่รับ/จ่ายเงิน (cash_date ว่าง) อยู่ในงบกำไรขาดทุน แต่ไม่อยู่ในงบกระแสเงินสด", () => {
  it("ค่าเช่าค้างรับ 20,000: รายได้ 32,000 แต่เงินสดรับค่าเช่าแค่ 12,000", () => {
    const L = ledger();
    const pl = buildProfitLoss(L, { year: YEAR, ownerIds: [TK] });
    const rent = pl.sections[0].lines.find((l) => l.codes.includes("4200"))!;
    expect(rent.amount).toBe(32_000);

    const bs = buildBalanceSheet(L, { year: YEAR, ownerIds: [TK] });
    const cf = buildCashFlowReport(L, { year: YEAR, ownerIds: [TK], balanceSheet: bs }).statement;
    const cfRent = cf.sections.flatMap((s) => s.lines).find((l) => l.subCodes.includes("inc.rent"))!;
    expect(cfRent.inflow).toBe(12_000);
    expect(cf.anomalies).toEqual([]);
  });

  it("ล้างค้างรับด้วยเงินจริงแล้วจึงเข้างบกระแสเงินสด และรายได้ไม่นับซ้ำ", () => {
    const clear = post(
      { typeKey: "invest_sell", subCode: "inv.collect_rent", amount: 20_000, ownerId: TK, bankAccountId: "b4", assetId: "rent1", contactId: "c1" },
      { docDate: "2026-07-01", cashDate: "2026-07-01" }
    );
    const L = [...ledger(), ...clear];
    expect(buildProfitLoss(L, { year: YEAR, ownerIds: [TK] }).netProfit).toBe(29_000);
    const bs = buildBalanceSheet(L, { year: YEAR, ownerIds: [TK] });
    const cf = buildCashFlowReport(L, { year: YEAR, ownerIds: [TK], balanceSheet: bs }).statement;
    expect(cf.sections.flatMap((s) => s.lines).find((l) => l.subCodes.includes("inv.collect_rent"))?.inflow).toBe(32_000); // 12,000 ที่รับตรง + 20,000 ที่ล้างค้างรับ (บรรทัดเดียวกันตามโครงงบ)
    expect(bs.groups.flatMap((g) => g.lines).find((l) => l.codes.includes("1200"))?.amount).toBe(0);
  });
});

describe("ตัวช่วย", () => {
  it("ปีบัญชี ม.ค.–ธ.ค. · ปีที่อ่านไม่ออกถูกปฏิเสธ · มุมมองรวม", () => {
    expect(fiscalYear(2026)).toEqual({ start: "2026-01-01", end: "2026-12-31" });
    expect(parseFiscalYear("2026")).toBe(2026);
    expect(parseFiscalYear("2569x")).toBeNull();
    expect(parseFiscalYear(undefined)).toBeNull();
    expect(ownersInView("family", ["a", "b"])).toEqual(["a", "b"]);
    expect(ownersInView(null, ["a", "b"])).toEqual(["a", "b"]);
    expect(ownersInView("b", ["a", "b"])).toEqual(["b"]);
    expect(ownersInView("ghost", ["a", "b"])).toEqual([]);
  });

  it("แบ่งหน้า: ตัดที่ 1,000 แถวต่อคำขอก็ยังได้ครบ 2,350 แถว · เกินเพดานถูกปฏิเสธ", async () => {
    const all = Array.from({ length: 2350 }, (_, i) => i);
    const build = () => ({
      range: async (from: number, to: number) => ({ data: all.slice(from, Math.min(to, from + 999) + 1), error: null }),
    });
    const r = await fetchAllPages<number>(build);
    expect(r.ok && r.rows.length).toBe(2350);
    const tooMany = await fetchAllPages<number>(build, { maxRows: 2000 });
    expect(tooMany.ok).toBe(false);
  });
});
