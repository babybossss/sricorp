/**
 * งบการเงินสามใบ — คำนวณจากบรรทัดที่ post แล้วใน `v_ledger_posted` **ทุกครั้งที่เปิด ไม่เก็บ**
 *
 * ไฟล์นี้ **ไม่มีกฎบัญชี** — มีแต่การรวมยอดตามโครงงบที่ `src/lib/rules/statements.ts` ประกาศไว้
 * (บัญชีไหนอยู่บรรทัดไหน) และงบกระแสเงินสดเรียก `buildCashflow()` ของ engine ตรงๆ
 * ทิศบวก-ลบมาจากประเภทบัญชีในผังบัญชี (`coa().type`) เท่านั้น
 *
 * กติกาที่ตั้งใจ (ลูกพี่สั่ง 24/10 และย้ำ 25/10):
 *   - งบกำไรขาดทุน = บัญชีรายได้/ค่าใช้จ่ายตามโครงงบ ลงตาม `doc_date` ในปี ม.ค.–ธ.ค. เท่านั้น
 *     **3400 ส่วนเกินทุนจากการตีราคา และ 3410 ผลต่างอัตราแลกเปลี่ยน เป็น equity ไม่มีทางอยู่ในงบนี้**
 *     (ไม่ได้กรองออก — โครงงบไม่มีบรรทัดให้ และเทสต์ตรวจว่าไม่มี) · แสดงแยกเป็น "กล่องยังไม่เกิดจริง"
 *   - งบแสดงฐานะการเงิน ณ วันสิ้นปี ตาม `doc_date` ทุกบรรทัด (ใบหนึ่งลงวันที่เดียวกันทุกบรรทัด จึงดุลเสมอ)
 *     กำไรสุทธิสะสมที่ยังไม่ได้ปิดบัญชี **รวมเข้าบรรทัดกำไรสะสม** มาจากฟังก์ชันเดียวกับงบกำไรขาดทุน
 *   - งบกระแสเงินสดตาม `cash_date` · `cash_date` ว่าง = ไม่เข้างบนี้ (ปล่อยให้ `buildCashflow()` ตัดสิน)
 *   - ตัวเลขทั้งหมดบวกบนจำนวนเต็มสตางค์ แล้วแปลงเป็นบาทตอนคืนค่า
 */

import { COA, FX_TRANSLATION_DIFF_COA, REVALUATION_SURPLUS_COA, coa, isCashAccount, type CoaType } from "@/lib/rules/coa";
import { BS_LAYOUT, PL_LAYOUT, type BsSide } from "@/lib/rules/statements";
import { buildCashflow, type CashflowStatement, type CashflowTxn } from "@/lib/ledger/cashflow";
import { PostingError } from "@/lib/ledger/types";
import type { CashflowSection } from "@/lib/rules/tx-rules";

/* ------------------------------------------------------------------ *
 * ข้อมูลเข้า
 * ------------------------------------------------------------------ */

/** แถวดิบของ `v_ledger_posted` เท่าที่งบต้องใช้ */
export type StatementViewRow = {
  line_id: string;
  transaction_id: string;
  owner_id: string;
  txn_type_code: string;
  doc_date: string;
  cash_date: string | null;
  source: string;
  counter_owner_id: string | null;
  intercompany_nature: string | null;
  coa_id: string;
  debit: number | string;
  credit: number | string;
  cf_category: string | null;
  currency: string | null;
};

export type StmtLine = {
  txnId: string;
  ownerId: string;
  subCode: string;
  docDate: string;
  cashDate: string | null;
  source: string;
  counterOwnerId: string | null;
  intercompanyNature: string | null;
  coaCode: string;
  debit: number;
  credit: number;
  cfCategory: string | null;
  currency: string | null;
};

export const UNKNOWN_ACCOUNT = "????";

/** รหัสบัญชีที่ไม่อยู่ในผัง = `UNKNOWN_ACCOUNT` และจะโผล่ในงบเป็นยอดที่จัดหมวดไม่ได้ (ไม่หายเงียบ) */
export function toStmtLines(rows: StatementViewRow[], coaCodeById: Record<string, string>): StmtLine[] {
  return rows.map((r) => ({
    txnId: r.transaction_id,
    ownerId: r.owner_id,
    subCode: r.txn_type_code,
    docDate: r.doc_date,
    cashDate: r.cash_date,
    source: r.source,
    counterOwnerId: r.counter_owner_id,
    intercompanyNature: r.intercompany_nature,
    coaCode: coaCodeById[r.coa_id] ?? UNKNOWN_ACCOUNT,
    debit: Number(r.debit),
    credit: Number(r.credit),
    cfCategory: r.cf_category,
    currency: r.currency,
  }));
}

/* ------------------------------------------------------------------ *
 * ตัวช่วย
 * ------------------------------------------------------------------ */

const satang = (n: number) => Math.round(n * 100);
const baht = (s: number) => Math.round(s) / 100;

/**
 * บัญชี "ยังไม่เกิดขึ้นจริง" (กำไร/ขาดทุนที่ยังไม่ขาย) — ส่วนของเจ้าของ ห้ามเข้างบกำไรขาดทุน
 *
 * ต้นฉบับฝั่ง DB คือ `fn_unrealised_equity_coas()` (`array['3400','3410']`) · ฝั่ง TS ประกอบจากค่าคงที่ของผังบัญชี
 * ตัวเดียวกับที่ engine ใช้ (`REVALUATION_SURPLUS_COA`, `FX_TRANSLATION_DIFF_COA`) — ที่เดียวในงบ ไม่พิมพ์รหัสซ้ำ
 * เทสต์ `statements.test.ts` เทียบกับ migration ว่าสองฝั่งเป็นชุดเดียวกัน
 */
export const unrealisedEquityCodes = (): string[] => [REVALUATION_SURPLUS_COA, FX_TRANSLATION_DIFF_COA];

export const fiscalYear = (year: number): { start: string; end: string } => ({
  start: `${String(year).padStart(4, "0")}-01-01`,
  end: `${String(year).padStart(4, "0")}-12-31`,
});

/** ปีบัญชีแบบเต็ม ม.ค.–ธ.ค. · ปีต้องเป็นจำนวนเต็มสี่หลัก */
export function parseFiscalYear(raw: unknown): number | null {
  const n = typeof raw === "string" ? Number(raw) : typeof raw === "number" ? raw : NaN;
  return Number.isInteger(n) && n >= 1900 && n <= 2399 ? n : null;
}

const typeOf = (code: string): CoaType | null => {
  try {
    return coa(code).type;
  } catch {
    return null;
  }
};

/** ยอดตามด้านปกติของบัญชี (สตางค์) — สินทรัพย์/ค่าใช้จ่าย = เดบิต−เครดิต · อื่นๆ = เครดิต−เดบิต */
function naturalSatang(type: CoaType, debitS: number, creditS: number): number {
  return type === "asset" || type === "expense" ? debitS - creditS : creditS - debitS;
}

type Sums = Map<string, { dr: number; cr: number }>;

function sumByCode(lines: StmtLine[], inRange: (l: StmtLine) => boolean): Sums {
  const m: Sums = new Map();
  for (const l of lines) {
    if (!inRange(l)) continue;
    const cur = m.get(l.coaCode) ?? { dr: 0, cr: 0 };
    cur.dr += satang(l.debit);
    cur.cr += satang(l.credit);
    m.set(l.coaCode, cur);
  }
  return m;
}

const natural = (sums: Sums, code: string): number => {
  const t = typeOf(code);
  const s = sums.get(code);
  if (!t || !s) return 0;
  return naturalSatang(t, s.dr, s.cr);
};

const inScope = (owners: Set<string>) => (l: StmtLine) => owners.has(l.ownerId);

/* ------------------------------------------------------------------ *
 * งบกำไรขาดทุน
 * ------------------------------------------------------------------ */

export type PlLineOut = { line: string; codes: string[]; amount: number };
export type PlSectionOut = { kind: "revenue" | "expense"; section: string; lines: PlLineOut[]; total: number };
export type ProfitLoss = {
  year: number;
  periodStart: string;
  periodEnd: string;
  ownerIds: string[];
  sections: PlSectionOut[];
  totalRevenue: number;
  totalExpense: number;
  /** รายได้ − ค่าใช้จ่าย · **ไม่รวมกำไร/ขาดทุนที่ยังไม่เกิดขึ้นจริง** */
  netProfit: number;
  /** ยอดบัญชีรายได้/ค่าใช้จ่ายที่โครงงบไม่มีบรรทัด — ต้องเป็นว่าง (เทสต์บังคับ) แสดงไว้ไม่ให้ยอดหายเงียบ */
  unmapped: { code: string; amount: number }[];
};

/** รวมรายได้/ค่าใช้จ่ายระหว่าง [from, to] ตาม doc_date (ขอบเขตเป็นรหัสวันที่ YYYY-MM-DD เปรียบเทียบแบบข้อความได้) */
function plBetween(lines: StmtLine[], owners: Set<string>, from: string | null, to: string): { sums: Sums } {
  const scope = inScope(owners);
  return {
    sums: sumByCode(lines, (l) => scope(l) && l.docDate <= to && (from === null || l.docDate >= from) && isPlAccount(l.coaCode)),
  };
}

const isPlAccount = (code: string) => {
  const t = typeOf(code);
  return t === "income" || t === "expense";
};

function netProfitSatang(sums: Sums): number {
  let n = 0;
  for (const code of sums.keys()) {
    const t = typeOf(code);
    if (t === "income") n += natural(sums, code);
    else if (t === "expense") n -= natural(sums, code);
  }
  return n;
}

export function buildProfitLoss(lines: StmtLine[], opts: { year: number; ownerIds: string[] }): ProfitLoss {
  const { start, end } = fiscalYear(opts.year);
  const owners = new Set(opts.ownerIds);
  const { sums } = plBetween(lines, owners, start, end);

  const placed = new Set<string>();
  const sections: PlSectionOut[] = PL_LAYOUT.map((sec) => {
    const outLines = sec.lines.map((l) => {
      l.codes.forEach((c) => placed.add(c));
      return { line: l.line, codes: l.codes, amount: baht(l.codes.reduce((t, c) => t + natural(sums, c), 0)) };
    });
    return { kind: sec.kind, section: sec.section, lines: outLines, total: baht(outLines.reduce((t, l) => t + satang(l.amount), 0)) };
  });
  const totalRevenue = sections.filter((s) => s.kind === "revenue").reduce((t, s) => t + satang(s.total), 0);
  const totalExpense = sections.filter((s) => s.kind === "expense").reduce((t, s) => t + satang(s.total), 0);

  const unmapped = [...sums.keys()]
    .filter((c) => !placed.has(c) && natural(sums, c) !== 0)
    .map((c) => ({ code: c, amount: baht(natural(sums, c)) }));

  return {
    year: opts.year,
    periodStart: start,
    periodEnd: end,
    ownerIds: [...owners],
    sections,
    totalRevenue: baht(totalRevenue),
    totalExpense: baht(totalExpense),
    netProfit: baht(netProfitSatang(sums)),
    unmapped,
  };
}

/* ------------------------------------------------------------------ *
 * กล่อง "ยังไม่เกิดขึ้นจริง" — แยกจากงบกำไรขาดทุนโดยตั้งใจ
 * ------------------------------------------------------------------ */

export type UnrealisedRow = {
  code: string;
  name: string;
  /** ยอดยกมาต้นปี (ด้านเครดิตเป็นบวก = กำไรที่ยังไม่ขาย) */
  opening: number;
  /** เปลี่ยนแปลงในปี */
  movement: number;
  /** ยอด ณ สิ้นปี — ยอดเดียวกับบรรทัดส่วนของเจ้าของในงบแสดงฐานะการเงิน */
  closing: number;
};
export type UnrealisedBox = { year: number; rows: UnrealisedRow[]; total: number };

export function buildUnrealised(lines: StmtLine[], opts: { year: number; ownerIds: string[] }): UnrealisedBox {
  const { start, end } = fiscalYear(opts.year);
  const scope = inScope(new Set(opts.ownerIds));
  const codes = unrealisedEquityCodes();
  const before = sumByCode(lines, (l) => scope(l) && l.docDate < start && codes.includes(l.coaCode));
  const upto = sumByCode(lines, (l) => scope(l) && l.docDate <= end && codes.includes(l.coaCode));
  const rows = codes.map((code) => {
    const opening = natural(before, code);
    const closing = natural(upto, code);
    return { code, name: coa(code).nameTh, opening: baht(opening), movement: baht(closing - opening), closing: baht(closing) };
  });
  return { year: opts.year, rows, total: baht(rows.reduce((t, r) => t + satang(r.closing), 0)) };
}

/* ------------------------------------------------------------------ *
 * งบแสดงฐานะการเงิน
 * ------------------------------------------------------------------ */

export type BsLineOut = {
  line: string;
  codes: string[];
  amount: number;
  contra: boolean;
  /** บรรทัดที่งบเติมให้ (ไม่ได้มาจากบัญชีเดียว) พร้อมคำอธิบาย */
  note?: string;
};
export type BsGroupOut = { side: BsSide; group: string; lines: BsLineOut[]; total: number };
export type BalanceSheet = {
  year: number;
  asOf: string;
  ownerIds: string[];
  consolidated: boolean;
  groups: BsGroupOut[];
  totalAssets: number;
  totalLiabilities: number;
  totalEquity: number;
  /** หนี้สิน + ส่วนของเจ้าของ */
  totalLiabilitiesAndEquity: number;
  /** สินทรัพย์ − (หนี้สิน + ส่วนของเจ้าของ) · 0 = ดุล */
  difference: number;
  balanced: boolean;
  retained: {
    /** ยอดบัญชี 3300 */
    account: number;
    /** กำไรสุทธิสะสมของปีก่อนๆ ที่ยังไม่ได้ปิดเข้าบัญชี 3300 */
    priorYears: number;
    /** กำไรสุทธิปีนี้ — ตัวเลขเดียวกับงบกำไรขาดทุนของปีนี้ */
    currentYear: number;
    total: number;
  };
  /** รายการระหว่างกัน (1310/2310) ที่ตัดออกในงบรวม */
  eliminated: number;
  /** ยอดบัญชีงบดุลที่โครงงบไม่มีบรรทัด หรือรหัสที่ไม่อยู่ในผัง — ต้องเป็นว่าง */
  unmapped: { code: string; amount: number }[];
  anomalies: string[];
};

const INTERCOMPANY_BS_GROUP = "รายการระหว่างกัน (ตัดออกในงบรวม)";

export function buildBalanceSheet(lines: StmtLine[], opts: { year: number; ownerIds: string[] }): BalanceSheet {
  const { start, end } = fiscalYear(opts.year);
  const owners = new Set(opts.ownerIds);
  const scope = inScope(owners);
  const consolidated = owners.size > 1;
  const upto = sumByCode(lines, (l) => scope(l) && l.docDate <= end);

  // กำไรสุทธิสะสม = จากฟังก์ชันตัวเดียวกับงบกำไรขาดทุน (ปีนี้) + ปีก่อนๆ ทั้งหมด
  const cumulative = plBetween(lines, owners, null, end).sums;
  const current = plBetween(lines, owners, start, end).sums;
  const cumulativeNp = netProfitSatang(cumulative);
  const currentNp = netProfitSatang(current);
  const priorNp = cumulativeNp - currentNp;

  const anomalies: string[] = [];
  const placed = new Set<string>();

  // ตัดรายการระหว่างกันในงบรวม: ใช้ได้เมื่อลูกหนี้ระหว่างกันเท่าเจ้าหนี้ระหว่างกันพอดี
  const icCodes = BS_LAYOUT.filter((g) => g.group === INTERCOMPANY_BS_GROUP).flatMap((g) => g.lines.flatMap((l) => l.codes));
  const icAssetCodes = icCodes.filter((c) => typeOf(c) === "asset");
  const icLiabCodes = icCodes.filter((c) => typeOf(c) === "liability");
  const icAsset = icAssetCodes.reduce((t, c) => t + natural(upto, c), 0);
  const icLiab = icLiabCodes.reduce((t, c) => t + natural(upto, c), 0);
  let eliminated = 0;
  let eliminateIc = false;
  if (consolidated && (icAsset !== 0 || icLiab !== 0)) {
    if (icAsset === icLiab) {
      eliminateIc = true;
      eliminated = icAsset;
    } else {
      anomalies.push(
        `ลูกหนี้ระหว่างกัน ${baht(icAsset)} ไม่เท่าเจ้าหนี้ระหว่างกัน ${baht(icLiab)} — ตัดออกในงบรวมไม่ได้ ` +
          "จึงแสดงทั้งสองฝั่งตามจริง ตรวจว่ารายการข้ามผู้ถือครบทั้งสองขาหรือไม่"
      );
    }
  }

  const groups: BsGroupOut[] = BS_LAYOUT.map((g) => {
    const out: BsLineOut[] = [];
    for (const l of g.lines) {
      l.codes.forEach((c) => placed.add(c));
      const isIc = g.group === INTERCOMPANY_BS_GROUP;
      const amount = eliminateIc && isIc ? 0 : l.codes.reduce((t, c) => t + natural(upto, c), 0);
      out.push({ line: l.line, codes: l.codes, amount: baht(amount), contra: !!l.contra });
      // กำไรสะสม: เติมกำไรสุทธิที่ยังไม่ได้ปิดบัญชีไว้ใต้บรรทัด 3300 โดยบอกที่มาตรงๆ
      if (g.side === "equity" && l.codes.includes("3300")) {
        out.push({
          line: "กำไร(ขาดทุน)สุทธิสะสมของปีก่อนๆ ที่ยังไม่ปิดบัญชี",
          codes: [],
          amount: baht(priorNp),
          contra: false,
          note: "รวมกำไรสุทธิทุกปีก่อนหน้า (ตัวเลขเดียวกับงบกำไรขาดทุนของแต่ละปี)",
        });
        out.push({
          line: `กำไร(ขาดทุน)สุทธิปี ${opts.year}`,
          codes: [],
          amount: baht(currentNp),
          contra: false,
          note: "ตรงกับกำไรสุทธิในงบกำไรขาดทุนของปีเดียวกัน (ไม่รวมกำไรที่ยังไม่เกิดขึ้นจริง)",
        });
      }
    }
    return { side: g.side, group: g.group, lines: out, total: baht(out.reduce((t, x) => t + satang(x.amount), 0)) };
  });

  // บัญชีงบดุลที่ไม่มีที่ลงในโครงงบ — ต้องไม่มี · ถ้ามีแสดงเป็นความผิดปกติ (และงบจะไม่ดุล ไม่ใช่ซ่อน)
  const unmapped = [...upto.keys()]
    .filter((c) => !placed.has(c) && !isPlAccount(c) && natural(upto, c) !== 0)
    .map((c) => ({ code: c, amount: baht(natural(upto, c)) }));
  if (unmapped.length) {
    anomalies.push(`มียอดบัญชีที่โครงงบไม่มีบรรทัดรองรับ: ${unmapped.map((u) => u.code).join(", ")}`);
  }

  const sideTotal = (side: BsSide) => groups.filter((g) => g.side === side).reduce((t, g) => t + satang(g.total), 0);
  const assets = sideTotal("asset");
  const liabilities = sideTotal("liability");
  const equity = sideTotal("equity");
  const difference = assets - (liabilities + equity);

  return {
    year: opts.year,
    asOf: end,
    ownerIds: [...owners],
    consolidated,
    groups,
    totalAssets: baht(assets),
    totalLiabilities: baht(liabilities),
    totalEquity: baht(equity),
    totalLiabilitiesAndEquity: baht(liabilities + equity),
    difference: baht(difference),
    balanced: difference === 0,
    retained: {
      account: baht(natural(upto, "3300")),
      priorYears: baht(priorNp),
      currentYear: baht(currentNp),
      total: baht(natural(upto, "3300") + cumulativeNp),
    },
    eliminated: baht(eliminated),
    unmapped,
    anomalies,
  };
}

/** ยอดบัญชีเงินสดและเงินฝาก (11xx) ในงบแสดงฐานะการเงิน — อ่านจากบรรทัดของงบนั้น ไม่คำนวณแยก */
export function balanceSheetCash(bs: BalanceSheet): number {
  const sum = bs.groups
    .flatMap((g) => g.lines)
    .filter((l) => l.codes.some(isCashAccount))
    .reduce((t, l) => t + satang(l.amount), 0);
  return baht(sum);
}

/* ------------------------------------------------------------------ *
 * งบกระแสเงินสด
 * ------------------------------------------------------------------ */

const CF_VALUES: CashflowSection[] = ["operating", "investing", "financing", "none"];

export type CashFlowReport = {
  year: number;
  statement: CashflowStatement;
  /** ยอดเงินสดในงบแสดงฐานะการเงิน ณ สิ้นปี */
  balanceSheetCash: number;
  /**
   * เงินสดระหว่างทาง = เงินสดในงบแสดงฐานะการเงิน − เงินสดปลายงวดในงบกระแสเงินสด
   * 0 เมื่อทุกรายการที่มีเงินสดมี `doc_date` กับ `cash_date` อยู่ฝั่งเดียวกันของวันตัดปี
   * ไม่เป็น 0 = มีรายการที่เอกสารลงปีหนึ่งแต่เงินเคลื่อนอีกปี (งบแสดงฐานะการเงินนับตาม doc_date งบกระแสเงินสดนับตาม cash_date)
   */
  cashInTransit: number;
  tiesOut: boolean;
};

export function buildCashFlowReport(
  lines: StmtLine[],
  opts: { year: number; ownerIds: string[]; balanceSheet: BalanceSheet }
): CashFlowReport {
  const { start, end } = fiscalYear(opts.year);
  const owners = new Set(opts.ownerIds);

  const byTxn = new Map<string, StmtLine[]>();
  for (const l of lines) {
    if (!owners.has(l.ownerId)) continue;
    const arr = byTxn.get(l.txnId);
    if (arr) arr.push(l);
    else byTxn.set(l.txnId, [l]);
  }
  const txns: CashflowTxn[] = [...byTxn.entries()].map(([txnId, ls]) => {
    const h = ls[0];
    return {
      txnId,
      ownerId: h.ownerId,
      status: "posted",
      source: h.source as CashflowTxn["source"],
      subCode: h.subCode,
      docDate: h.docDate,
      cashDate: h.cashDate,
      counterOwnerId: h.counterOwnerId,
      intercompanyNature: h.intercompanyNature as CashflowTxn["intercompanyNature"],
      lines: ls.map((l) => ({
        coaCode: l.coaCode,
        debit: l.debit,
        credit: l.credit,
        // บรรทัดที่ไม่มีหมวด = "none" (ไม่เข้างบ) — บรรทัดเงินสดที่เป็น none จะถูกรายงานเป็น anomaly โดย engine
        cfCategory: (CF_VALUES as string[]).includes(l.cfCategory ?? "") ? (l.cfCategory as CashflowSection) : "none",
        currency: l.currency,
      })),
    };
  });

  let statement: CashflowStatement;
  try {
    statement = buildCashflow({ txns, periodStart: start, periodEnd: end, ownerIds: [...owners] });
  } catch (e) {
    if (e instanceof PostingError) throw new Error(`ประกอบงบกระแสเงินสดไม่ได้: ${e.message}`);
    throw e;
  }

  const bsCash = balanceSheetCash(opts.balanceSheet);
  const cashInTransit = baht(satang(bsCash) - satang(statement.closingCash));
  return { year: opts.year, statement, balanceSheetCash: bsCash, cashInTransit, tiesOut: cashInTransit === 0 };
}

/** ผู้ถือที่รวมอยู่ในมุมมอง — `null`/`"family"` = ทุกผู้ถือ */
export function ownersInView(view: string | null, allOwnerIds: string[]): string[] {
  if (!view || view === "family") return [...allOwnerIds];
  return allOwnerIds.includes(view) ? [view] : [];
}

/** รายการบัญชีทั้งหมดในผังที่ไม่ใช่รายได้/ค่าใช้จ่าย — ไว้ให้เทสต์ไล่ว่าทุกบัญชีมีที่ลงในงบดุล */
export const balanceSheetCoaCodes = (): string[] => COA.filter((a) => !isPlAccount(a.code)).map((a) => a.code);
