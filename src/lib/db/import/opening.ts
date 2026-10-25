/**
 * นำเข้ายอดตั้งต้นงบดุล (ไฟล์ 2 · `templates/SRI_OS_2_ยอดตั้งต้นงบดุล.xlsx`) — **อ่าน + ตรวจ + วางแผน**
 *
 * ไฟล์นี้ไม่เขียนสมุดเอง — การลงจริงอยู่ที่ `opening-post.ts` (ประกอบรายการผ่าน `buildPosting()`)
 * กับ `opening-run.ts` (เรียกประตู `fn_reimport_opening` ที่ฝั่ง DB) · ที่นี่ทำสามอย่างเท่านั้น
 * และทั้งหมดเป็นฟังก์ชันล้วน (ไม่แตะ DB ไม่แตะ Excel โดยตรง):
 *   1. `parseOpeningWorkbook()`  — ตรวจไฟล์ทั้งเล่ม **ทุกช่อง ทุกชีท** แล้วรวบรวมความผิดทั้งหมดในครั้งเดียว
 *                                  มีแม้แต่จุดเดียว = ปฏิเสธทั้งไฟล์ (ไม่นำเข้าบางส่วน) พร้อมบอกชีท/แถว
 *   2. `fingerprintOf()`         — ลายนิ้วมือของ "เนื้อหา" ที่นำเข้า (ไม่ใช่ของไฟล์) ไว้ตัดสินว่าอัปโหลดซ้ำเหมือนเดิมไหม
 *   3. `planOpeningImport()`     — เทียบกับชุดยอดตั้งต้นที่ **อยู่ในสมุดจริง** แล้วบอกว่าต้องทำอะไร:
 *                                  ใหม่ / ไม่เปลี่ยน / กลับรายการชุดเดิมแล้วลงชุดใหม่ (ห้าม DELETE เด็ดขาด)
 *
 * หลักที่ยึด
 *  - **ตารางเทียบรหัสบัญชีอยู่ในไฟล์เทมเพลต/คู่มือ (`docs/IMPORT_GUIDE.md`) และรหัสในไฟล์คือรหัสบัญชีจริง** — ไม่คิดการเทียบใหม่
 *    รหัสทุกตัวต้องมีในผังบัญชีและอยู่ในโครงงบดุล (`BS_LAYOUT`) ไม่งั้นปฏิเสธ
 *  - **วันตัดยอดไม่ fix ในโค้ด** (กฎเหล็กข้อ 5) — อ่านจากหัวชีท (`detectCutoff()`) หรือผู้ใช้ระบุ
 *    และทุกชีทต้องเป็นวันเดียวกัน · ผู้ใช้ระบุแล้วไม่ตรงกับในชีท = ปฏิเสธ ไม่เลือกข้างใดข้างหนึ่งให้
 *    (คนละวันกัน = งบดุลไม่ลงตัวและหาสาเหตุไม่ได้ · templates/README.md)
 *  - ยอดทุกช่องมาจากช่องที่คน **กรอก** เท่านั้น — ช่องที่เป็นสูตรไม่ถูกเชื่อ (ระบบรวมยอดเองใหม่ทุกครั้ง)
 *  - ขาคู่ของยอดตั้งต้นคือส่วนของเจ้าของ (3100 ทุน · 3300 กำไรสะสม) ที่ **ผู้ใช้กรอกมาเอง** ระบบไม่เติมให้:
 *    ถ้าสินทรัพย์ − หนี้สิน − ส่วนของเจ้าของ ≠ 0 = ปฏิเสธ (ไม่ดัดตัวเลขอื่นให้ตรง · คู่มือข้อ "ผลต่างรอกระทบยอด")
 *  - เงินสดทุกบาทต้องผูกบัญชีธนาคารจริงของผู้ถือนั้น และบัญชีต้องยังเปิดอยู่ (Money Invariant 2 · D-092)
 *  - **ล็อตสกุลต่างประเทศต้องมี "อัตรา ณ วันซื้อ"** — ไม่มี = ปฏิเสธทั้งไฟล์ ไม่เดาอัตรา (เดาแล้วต้นทุนผิดและกำไรตอนขายผิดทั้งก้อน)
 *    ต้นทุนบาท = ปัด 2 ตำแหน่ง(ยอดสกุลเดิม × อัตรา) ด้วยเลขจำนวนเต็ม ไม่ใช้ทศนิยมลอยตัว
 *    เพราะ DB ตรวจ `cost_thb = round(amount_original × fx_rate, 2)` **พอดี** (ไม่ยอมเศษสตางค์)
 */

import { createHash } from "node:crypto";
import { COA, coa } from "@/lib/rules/coa";
import { BS_LAYOUT } from "@/lib/rules/statements";
import { parseAmountOrNull } from "@/lib/format";
import { unrealisedEquityCodes } from "../statements";
import { CURRENCIES } from "@/lib/rules/currency";
import { cellAt, type Cell, type Sheet, type Workbook } from "./xlsx";

/* ---------------------------------------------------------------- ชนิด */

export type OwnerRef = { id: string; name: string; status: string };
export type BankRef = { id: string; ownerId: string; name: string; isActive: boolean; currency: string };

export type ParseContext = {
  owners: OwnerRef[];
  banks: BankRef[];
  /** วันตัดยอด YYYY-MM-DD ที่ผู้ใช้ระบุ */
  cutoff: string;
};

export type ImportIssue = { sheet: string; row?: number; message: string };

export type JournalLine = {
  coaCode: string;
  /** บรรทัดเงินสด (11xx) ต้องมีเสมอ · บรรทัดอื่นต้องเป็น null */
  bankAccountId: string | null;
  debit: number;
  credit: number;
};

export type OwnerJournal = {
  ownerId: string;
  ownerName: string;
  sheet: string;
  lines: JournalLine[];
  totalDebit: number;
  totalCredit: number;
  /** ยอดรวมตามประเภท (บาท) — ไว้แสดงในพรีวิว */
  assets: number;
  liabilities: number;
  equity: number;
};

export type Lot = {
  ownerId: string;
  ownerName: string;
  kind: string;
  name: string;
  /** YYYY-MM-DD */
  boughtOn: string;
  units: number;
  pricePerUnit: number;
  fee: number;
  /** ต้นทุน **เป็นบาทเสมอ** (ล็อตสกุลต่างประเทศ = ยอดสกุลเดิม × อัตรา ปัด 2 ตำแหน่ง) */
  cost: number;
  /** สกุลเงินของราคา/ค่าธรรมเนียมในไฟล์ (THB / USD / JPY / CNY) */
  currency: string;
  /** ล็อตสกุลต่างประเทศเท่านั้น: ยอดในสกุลเดิม = จำนวน × ราคา + ค่าธรรมเนียม (ปัด 6 ตำแหน่ง ตามคอลัมน์ใน DB) */
  amountOriginal?: number;
  /** ล็อตสกุลต่างประเทศเท่านั้น: บาทต่อหนึ่งหน่วย ณ วันซื้อ ตามที่ผู้ใช้กรอกในไฟล์ */
  fxRate?: number;
  /** 1700 หลักทรัพย์ · 1720 ทองคำและสินทรัพย์ทางเลือก */
  coaCode: "1700" | "1720";
  row: number;
};

export type ParsedOpening = {
  cutoff: string;
  journals: OwnerJournal[];
  lots: Lot[];
  warnings: string[];
};

export type ParseResult = { ok: true; parsed: ParsedOpening } | { ok: false; issues: ImportIssue[] };

/* ---------------------------------------------------------------- ค่าคงที่ของโครงไฟล์ */

const SHEET_PREFIX = "BS-";
const LOTS_SHEET = "พอร์ตลงทุน (รายล็อต)";
/** ชีทที่รู้จักแต่ไม่ใช่ข้อมูลนำเข้า */
const IGNORED_SHEETS = new Set(["อ่านก่อน", "รวมทุกผู้ถือ"]);
/** ชนิดล็อตที่รวมเข้า 1720 — ที่เหลือ (หุ้น ETF กองทุน พันธบัตร) รวมเข้า 1700 ตามคู่มือ */
const COMMODITY_KINDS = new Set(["ทองคำ", "Crypto"]);
const LOT_KINDS = new Set(["หุ้นไทย", "หุ้น US", "ETF", "กองทุน", "Crypto", "ทองคำ", "พันธบัตร"]);

/** 3200 เงินถอนเป็นยอดระหว่างงวด (D-043) · 3400/3410 ยังไม่เกิดจริง ต้องไม่โผล่ในยอดตั้งต้นที่ลงราคาทุน */
function forbiddenCodes(): Map<string, string> {
  const m = new Map<string, string>([
    ["3200", "เงินถอนของเจ้าของเป็นยอดระหว่างงวด ไม่ใช่ยอดคงเหลือ — เงินถอนสะสมถูกหักในกำไรสะสมแล้ว ใส่อีกบรรทัดจะนับสองรอบ (D-043)"],
  ]);
  for (const c of unrealisedEquityCodes()) {
    m.set(c, "เป็นกำไร/ขาดทุนที่ยังไม่เกิดขึ้นจริง ยอดตั้งต้นลงราคาทุนเท่านั้น ราคาประเมินห้ามใส่ที่นี่ (D-043)");
  }
  return m;
}

const bsCodeSet = (): Set<string> => new Set(BS_LAYOUT.flatMap((g) => g.lines.flatMap((l) => l.codes)));

/* ---------------------------------------------------------------- ตัวช่วยอ่านช่อง */

const round2 = (n: number) => Math.round(n * 100) / 100;
const cents = (n: number) => Math.round(n * 100);
const text = (c: Cell | null): string => (c && c.value !== null ? String(c.value).trim() : "");

function dateFromText(s: string): string | null {
  const m = /(\d{1,2})\/(\d{1,2})\/(\d{4})/.exec(s) ?? null;
  if (!m) return null;
  const d = Number(m[1]), mo = Number(m[2]), y = Number(m[3]);
  if (y < 1900 || y > 2399 || mo < 1 || mo > 12 || d < 1 || d > new Date(Date.UTC(y, mo, 0)).getUTCDate()) return null;
  return `${String(y).padStart(4, "0")}-${String(mo).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

/** วันที่ในช่อง: ตัวเลข serial ของ Excel · วว/ดด/ปปปป · YYYY-MM-DD — อย่างอื่น null */
function dateFromCell(c: Cell | null): string | null {
  if (!c || c.value === null) return null;
  if (typeof c.value === "number") {
    if (!Number.isFinite(c.value)) return null;
    const serial = Math.floor(c.value);
    if (serial < 20000 || serial > 80000) return null; // ~1954–2118 · เลขอื่นไม่ใช่วันที่
    const d = new Date(Date.UTC(1899, 11, 30) + serial * 86400000);
    return d.toISOString().slice(0, 10);
  }
  const s = String(c.value).trim();
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return dateFromText(`${s.slice(8)}/${s.slice(5, 7)}/${s.slice(0, 4)}`);
  return dateFromText(s);
}

/** จำนวนเงินจากช่องที่คนกรอก — สูตร = ไม่เชื่อ · อ่านไม่ออก = ปัญหา · ว่าง = ไม่มียอด */
function amountFrom(
  c: Cell | null,
  where: { sheet: string; row: number; label: string },
  issues: ImportIssue[],
  decimals = 2
): number | null {
  if (!c || c.value === null || (typeof c.value === "string" && c.value.trim() === "")) return null;
  if (c.formula) {
    issues.push({ ...where, message: `${where.label}: ช่องนี้เป็นสูตร — ยอดนำเข้าต้องเป็นตัวเลขที่กรอกเอง (ระบบรวมยอดเองใหม่ทุกครั้ง ไม่เชื่อผลคำนวณของ Excel)` });
    return null;
  }
  let n: number | null;
  if (typeof c.value === "number") n = c.value;
  else if (typeof c.value === "boolean") n = null;
  else n = parseAmountOrNull(c.value);
  if (n === null || !Number.isFinite(n)) {
    issues.push({ ...where, message: `${where.label}: อ่านเป็นตัวเลขไม่ได้ ("${String(c.value).slice(0, 30)}")` });
    return null;
  }
  const scale = 10 ** decimals;
  if (Math.abs(n * scale - Math.round(n * scale)) > 1e-6) {
    issues.push({ ...where, message: `${where.label}: มีทศนิยมเกิน ${decimals} ตำแหน่ง (${n})` });
    return null;
  }
  return Math.round(n * scale) / scale;
}

/* ---------------------------------------------------------------- วันตัดยอดจากในชีท */

/** วันตัดยอดที่เขียนไว้หัวชีท ("ณ วันที่ วว/ดด/ปปปป" ในแถว 1–3) — ไม่พบ/อ่านไม่ออก = null */
function sheetCutoff(sheet: Sheet): string | null {
  for (let r = 1; r <= 3; r++) {
    const t = text(cellAt(sheet, r, "A")) || text(cellAt(sheet, r, "B"));
    if (/ณ วันที่/.test(t)) return dateFromText(t);
  }
  return null;
}

export type DetectCutoffResult = { ok: true; cutoff: string } | { ok: false; issues: ImportIssue[] };

/**
 * **เติมวันตัดยอดจากในชีทให้** เมื่อผู้ใช้ไม่ได้ระบุ — ทุกชีทผู้ถือ (`BS-…`) ต้องเขียนวันเดียวกัน
 *
 * ไม่เลือกให้เมื่อชีทขัดกันเอง (คนละวัน = งบดุลไม่ลงตัวและหาสาเหตุไม่ได้) และไม่เลือกให้เมื่อ
 * ไม่มีชีทไหนระบุวัน · **ผู้ใช้ระบุเองแล้วไม่ตรงกับในชีท ยังถูกปฏิเสธเหมือนเดิม** (ที่ `readOwnerSheet`)
 * — ฟังก์ชันนี้แค่ตอบว่า "ไฟล์นี้บอกว่าวันไหน" ไม่ได้ตัดสินแทนผู้ใช้
 */
export function detectCutoff(wb: Workbook): DetectCutoffResult {
  const issues: ImportIssue[] = [];
  const byDate = new Map<string, string[]>();
  for (const sh of wb.sheets) {
    if (!sh.name.startsWith(SHEET_PREFIX)) continue;
    const d = sheetCutoff(sh);
    if (!d) {
      issues.push({ sheet: sh.name, row: 2, message: 'ไม่พบ "ณ วันที่ วว/ดด/ปปปป" ในหัวชีท — อ่านวันตัดยอดจากไฟล์ไม่ได้ (ระบุวันตัดยอดเองได้ แต่ทุกชีทยังต้องเขียนวันที่ไว้)' });
      continue;
    }
    byDate.set(d, [...(byDate.get(d) ?? []), sh.name]);
  }
  if (byDate.size === 0 && issues.length === 0) {
    issues.push({ sheet: "(ทั้งไฟล์)", message: "ไม่พบชีทผู้ถือ (ชื่อขึ้นต้น BS-) จึงอ่านวันตัดยอดไม่ได้" });
  }
  if (byDate.size > 1) {
    const detail = [...byDate].map(([d, names]) => `${d}: ${names.join(", ")}`).join(" · ");
    issues.push({ sheet: "(ทั้งไฟล์)", message: `ชีทแต่ละผู้ถือเขียนวันตัดยอดไม่ตรงกัน (${detail}) — ต้องเป็นวันเดียวกันทั้งไฟล์ ไม่งั้นงบดุลไม่ลงตัวและหาสาเหตุไม่ได้` });
  }
  if (issues.length) return { ok: false, issues };
  return { ok: true, cutoff: [...byDate.keys()][0] };
}

/* ---------------------------------------------------------------- อ่านชีทผู้ถือ */

type OwnerSheet = {
  owner: OwnerRef;
  sheet: string;
  amounts: Map<string, { amount: number; row: number }>;
  cash: { name: string; amount: number; row: number }[];
  hasAnything: boolean;
};

function readOwnerSheet(sheet: Sheet, owner: OwnerRef, ctx: ParseContext, issues: ImportIssue[]): OwnerSheet {
  const name = sheet.name;
  const out: OwnerSheet = { owner, sheet: name, amounts: new Map(), cash: [], hasAnything: false };

  // วันตัดยอด (แถว 2) ต้องมีและตรงกับที่ผู้ใช้ระบุ
  const fileCutoff = sheetCutoff(sheet);
  if (!fileCutoff) {
    issues.push({ sheet: name, row: 2, message: 'ไม่พบ "ณ วันที่ วว/ดด/ปปปป" ในหัวชีท — ทุกชีทต้องระบุวันตัดยอด และต้องเป็นวันเดียวกันทั้งไฟล์' });
  } else if (fileCutoff !== ctx.cutoff) {
    issues.push({
      sheet: name,
      row: 2,
      message: `วันตัดยอดในชีทคือ ${fileCutoff} แต่ที่ระบุตอนนำเข้าคือ ${ctx.cutoff} — ยอดตั้งต้นคนละวันกันทำให้งบดุลไม่ลงตัวและหาสาเหตุไม่ได้ ต้องเป็นวันเดียวกันทั้งไฟล์`,
    });
  }

  const forbidden = forbiddenCodes();
  const allowed = bsCodeSet();
  const rowNumbers = [...sheet.rows.keys()].sort((a, b) => a - b);
  let cashHeader = -1;
  let cashEnd = -1;
  let totalsAt = -1;

  for (const r of rowNumbers) {
    const b = text(cellAt(sheet, r, "B"));
    if (b === "รวมสินทรัพย์" && totalsAt < 0) totalsAt = r;
    if (b === "บัญชี" && cashHeader < 0) cashHeader = r;
    if (b === "รวมเงินสด" && cashEnd < 0) cashEnd = r;
  }

  // ---- บรรทัดบัญชี: คอลัมน์ A เป็นรหัส 4 หลัก ก่อนแถวรวม ----
  for (const r of rowNumbers) {
    if (totalsAt >= 0 && r >= totalsAt) break;
    const a = cellAt(sheet, r, "A");
    const code = typeof a?.value === "number" ? String(a.value) : text(a);
    if (!/^\d{4}$/.test(code)) continue;
    const where = { sheet: name, row: r, label: `รหัส ${code}` };

    if (!COA.some((x) => x.code === code)) {
      issues.push({ ...where, message: `${where.label}: ไม่มีรหัสนี้ในผังบัญชี` });
      continue;
    }
    if (forbidden.has(code)) {
      issues.push({ ...where, message: `${where.label}: ใส่ในยอดตั้งต้นไม่ได้ — ${forbidden.get(code)}` });
      continue;
    }
    if (!allowed.has(code)) {
      issues.push({ ...where, message: `${where.label}: ไม่ใช่บัญชีงบดุล (รายได้/ค่าใช้จ่ายไม่มียอดตั้งต้น) — ยอดสะสมของปีก่อนอยู่ในกำไรสะสม 3300` });
      continue;
    }
    if (out.amounts.has(code)) {
      issues.push({ ...where, message: `${where.label}: ซ้ำกับแถว ${out.amounts.get(code)!.row} — หนึ่งรหัสมีบรรทัดเดียว` });
      continue;
    }
    const amount = amountFrom(cellAt(sheet, r, "E"), { ...where, label: `${where.label} ยอดตั้งต้น` }, issues);
    if (amount === null) continue;
    if (amount < 0 && code !== "3300") {
      issues.push({ ...where, message: `${where.label}: ยอดติดลบไม่ได้ (ใส่จำนวนบวกเสมอ — ระบบรู้เดบิต/เครดิตจากประเภทบัญชี) ยกเว้น 3300 กำไรสะสมที่ขาดทุนสะสมได้` });
      continue;
    }
    if (amount === 0) continue;
    out.amounts.set(code, { amount, row: r });
    out.hasAnything = true;
  }

  // ---- ตารางแยกเงินสดตามบัญชีธนาคาร ----
  if (cashHeader >= 0) {
    const stop = cashEnd >= 0 ? cashEnd : Math.max(...rowNumbers) + 1;
    const seen = new Set<string>();
    for (let r = cashHeader + 1; r < stop; r++) {
      const nm = text(cellAt(sheet, r, "B"));
      const eCell = cellAt(sheet, r, "E");
      const hasAmount = !!eCell && eCell.value !== null && String(eCell.value).trim() !== "";
      if (!nm && !hasAmount) continue;
      const where = { sheet: name, row: r, label: `บัญชี "${nm || "(ไม่มีชื่อ)"}"` };
      if (!nm) {
        issues.push({ ...where, message: "มียอดเงินสดแต่ไม่ได้ระบุชื่อบัญชี — เงินสดทุกบาทต้องผูกบัญชีธนาคารจริง (Money Invariant 2)" });
        continue;
      }
      const amount = amountFrom(eCell, { ...where, label: `${where.label} ยอด` }, issues);
      if (amount === null || amount === 0) continue;
      if (amount < 0) {
        issues.push({ ...where, message: `${where.label}: ยอดเงินสดติดลบไม่ได้` });
        continue;
      }
      if (seen.has(nm)) {
        issues.push({ ...where, message: `${where.label}: ชื่อบัญชีซ้ำในตารางเงินสดเดียวกัน` });
        continue;
      }
      seen.add(nm);
      out.cash.push({ name: nm, amount, row: r });
    }
  }
  return out;
}

/* ---------------------------------------------------------------- สร้างรายการบัญชีของผู้ถือ */

function buildJournal(os: OwnerSheet, ctx: ParseContext, issues: ImportIssue[]): OwnerJournal | null {
  const lines: JournalLine[] = [];
  const sheet = os.sheet;
  // ชื่อบัญชีซ้ำในผู้ถือเดียวกัน = ไม่รู้ว่าเงินก้อนนี้เข้าบัญชีไหน → ห้ามให้ตัวหลังชนะเงียบๆ
  const bankOf = new Map<string, BankRef>();
  const ambiguous = new Set<string>();
  for (const b of ctx.banks.filter((x) => x.ownerId === os.owner.id)) {
    const k = b.name.trim();
    if (bankOf.has(k)) ambiguous.add(k);
    bankOf.set(k, b);
  }

  const cashTotal = round2(os.cash.reduce((t, c) => t + c.amount, 0));
  const cashRow = os.amounts.get("1100");
  if ((cashRow?.amount ?? 0) !== cashTotal) {
    issues.push({
      sheet,
      row: cashRow?.row,
      message:
        `เงินสด 1100 = ${(cashRow?.amount ?? 0).toLocaleString("en-US")} แต่ตารางแยกบัญชีรวมได้ ${cashTotal.toLocaleString("en-US")} ` +
        `(ต่างกัน ${round2((cashRow?.amount ?? 0) - cashTotal).toLocaleString("en-US")}) — ต้องเท่ากันทุกสตางค์ และเงินสดทุกบาทต้องแยกเป็นรายบัญชีธนาคาร`,
    });
  }
  for (const c of os.cash) {
    const bank = bankOf.get(c.name);
    if (!bank) {
      issues.push({
        sheet,
        row: c.row,
        message: `บัญชี "${c.name}" ไม่มีในระบบเป็นของ ${os.owner.name} — สร้างบัญชีธนาคารที่ตั้งค่าก่อน แล้วใช้ชื่อให้ตรงกัน (ระบบไม่สร้างบัญชีให้เอง ไม่เดาว่าเป็นบัญชีไหน)`,
      });
      continue;
    }
    if (ambiguous.has(c.name)) {
      issues.push({ sheet, row: c.row, message: `บัญชี "${c.name}" มีชื่อซ้ำกันมากกว่าหนึ่งบัญชีของ ${os.owner.name} ในระบบ — ไม่รู้ว่าเงินก้อนนี้เข้าบัญชีไหน ให้แก้ชื่อบัญชีในหน้าตั้งค่าให้ไม่ซ้ำก่อน` });
      continue;
    }
    if (bank.currency !== "THB") {
      issues.push({
        sheet,
        row: c.row,
        message: `บัญชี "${c.name}" เป็นบัญชีสกุล ${bank.currency} — ยังนำเข้ายอดตั้งต้นของบัญชีสกุลต่างประเทศไม่ได้ เพราะไฟล์ไม่มีอัตราแลกเปลี่ยน ณ วันตัดยอด และระบบไม่เดาอัตราให้ (ลงเป็นบาทเฉยๆ ยอดเงินสดในงบจะผิดเงียบๆ)`,
      });
      continue;
    }
    if (!bank.isActive) {
      issues.push({ sheet, row: c.row, message: `บัญชี "${c.name}" ปิดใช้งานแล้ว — ลงยอดตั้งต้นเข้าบัญชีที่ปิดไม่ได้ (D-092)` });
      continue;
    }
    lines.push({ coaCode: "1100", bankAccountId: bank.id, debit: c.amount, credit: 0 });
  }

  for (const [code, { amount }] of [...os.amounts].sort(([a], [b]) => a.localeCompare(b))) {
    if (code === "1100") continue; // แตกเป็นรายบัญชีแล้ว
    const type = coa(code).type;
    const debitSide = type === "asset" || amount < 0; // 3300 ติดลบ = ขาดทุนสะสม = เดบิต
    lines.push({
      coaCode: code,
      bankAccountId: null,
      debit: debitSide ? Math.abs(amount) : 0,
      credit: debitSide ? 0 : Math.abs(amount),
    });
  }

  const totalDebit = round2(lines.reduce((t, l) => t + l.debit, 0));
  const totalCredit = round2(lines.reduce((t, l) => t + l.credit, 0));
  const sumType = (t: string) =>
    round2(
      [...os.amounts].filter(([c]) => coa(c).type === t).reduce((s, [, v]) => s + v.amount, 0)
    );
  const journal: OwnerJournal = {
    ownerId: os.owner.id,
    ownerName: os.owner.name,
    sheet,
    lines,
    totalDebit,
    totalCredit,
    assets: sumType("asset"),
    liabilities: sumType("liability"),
    equity: sumType("equity"),
  };
  if (cents(totalDebit) !== cents(totalCredit)) {
    issues.push({
      sheet,
      message:
        `งบดุลของ ${os.owner.name} ไม่ลงตัว: สินทรัพย์ ${journal.assets.toLocaleString("en-US")} − หนี้สิน ${journal.liabilities.toLocaleString("en-US")} ` +
        `− ส่วนของเจ้าของ ${journal.equity.toLocaleString("en-US")} = ${round2(totalDebit - totalCredit).toLocaleString("en-US")} (ต้องเป็น 0) — ` +
        "ใส่ผลต่างที่ 3300 กำไรสะสมพร้อมหมายเหตุตามคู่มือ อย่าดัดตัวเลขอื่นให้ตรง",
    });
  }
  return lines.length ? journal : null;
}

/* ---------------------------------------------------------------- รายล็อต */

/**
 * คอลัมน์ของชีทรายล็อต — **อ่านจากหัวตาราง** ไม่ผูกกับตำแหน่ง เพราะเทมเพลตเพิ่มคอลัมน์ "อัตรา ณ วันซื้อ"
 * เข้ามาทีหลังและตำแหน่งอาจขยับได้ · หัวที่หาไม่เจอ (ไฟล์รุ่นเก่า) ใช้ตำแหน่งเดิมของเทมเพลตรุ่นแรก
 * ยกเว้นคอลัมน์อัตรา ซึ่งไม่มีตำแหน่งเดิม (ไม่พบหัว = ไม่มีคอลัมน์ → ล็อตสกุลต่างประเทศถูกปฏิเสธ)
 */
type LotColumns = { owner: string; kind: string; name: string; date: string; units: string; price: string; fee: string; currency: string; rate: string | null };

const LOT_HEADERS: { key: keyof LotColumns; startsWith: string; fallback: string | null }[] = [
  { key: "owner", startsWith: "ถือในชื่อ", fallback: "A" },
  { key: "kind", startsWith: "ประเภท", fallback: "B" },
  { key: "name", startsWith: "ชื่อ", fallback: "C" },
  { key: "date", startsWith: "วันที่ซื้อ", fallback: "D" },
  { key: "units", startsWith: "จำนวนหน่วย", fallback: "E" },
  { key: "price", startsWith: "ราคาต่อหน่วย", fallback: "F" },
  { key: "fee", startsWith: "ค่าธรรมเนียม", fallback: "G" },
  { key: "currency", startsWith: "สกุลเงิน", fallback: "I" },
  { key: "rate", startsWith: "อัตรา", fallback: null },
];

function lotColumns(sheet: Sheet, headerRow: number): LotColumns {
  const row = sheet.rows.get(headerRow) ?? new Map<string, Cell>();
  const norm = (c: Cell) => text(c).replace(/[\s*＊]/g, "");
  const out = {} as Record<string, string | null>;
  for (const h of LOT_HEADERS) {
    const hit = [...row].find(([, c]) => norm(c).startsWith(h.startsWith.replace(/\s/g, "")));
    out[h.key] = hit ? hit[0] : h.fallback;
  }
  return out as LotColumns;
}

/** ตัวเลข → จำนวนเต็มที่คูณ 10^dp (ไม่ผ่านการคูณทศนิยมลอยตัว) — ค่าที่ผ่าน `amountFrom` มีทศนิยมไม่เกิน dp อยู่แล้ว */
const scaled = (n: number, dp: number): bigint => BigInt(n.toFixed(dp).replace(".", ""));
/** หารแล้วปัดครึ่งขึ้น (ค่าบวกเท่านั้น) */
const divRound = (num: bigint, den: bigint): bigint => (num + den / BigInt(2)) / den;
const pow10 = (n: number): bigint => BigInt("1" + "0".repeat(n));

/**
 * ต้นทุนของล็อตด้วยเลขจำนวนเต็ม — คืนทั้งยอดสกุลเดิม (ปัด 6 ตำแหน่ง) และต้นทุนบาท (ปัด 2 ตำแหน่ง)
 *
 * DB บังคับ `cost_thb = round(amount_original × fx_rate, 2)` พอดีกับค่าที่เก็บ จึงต้องคำนวณจาก
 * `amount_original` ที่ปัดแล้ว (ไม่ใช่จากผลคูณเต็ม) และต้องไม่คลาดเพราะทศนิยมลอยตัวแม้ 1 สตางค์
 * `rate` เป็น null = ล็อตบาท (ต้นทุน = ยอดรวมปัด 2 ตำแหน่ง)
 */
export function lotCost(units: number, price: number, fee: number, rate: number | null): { amountOriginal: number; costThb: number } {
  const gross12 = scaled(units, 6) * scaled(price, 6) + scaled(fee, 2) * pow10(10); // ทศนิยม 12 ตำแหน่ง
  const original6 = divRound(gross12, pow10(6)); // ทศนิยม 6 ตำแหน่ง
  const cost2 = rate === null ? divRound(gross12, pow10(10)) : divRound(original6 * scaled(rate, 8), pow10(12));
  return { amountOriginal: Number(original6) / 1e6, costThb: Number(cost2) / 100 };
}

function readLots(sheet: Sheet, ownersByName: Map<string, OwnerRef>, ctx: ParseContext, issues: ImportIssue[]): Lot[] {
  const rowNumbers = [...sheet.rows.keys()].sort((a, b) => a - b);
  const header = rowNumbers.find((r) => text(cellAt(sheet, r, "A")).startsWith("ถือในชื่อ"));
  if (header === undefined) {
    issues.push({ sheet: sheet.name, message: 'ไม่พบแถวหัวตาราง "ถือในชื่อ" — โครงชีทรายล็อตผิดไปจากเทมเพลต' });
    return [];
  }
  const col = lotColumns(sheet, header);
  const lots: Lot[] = [];
  for (const r of rowNumbers.filter((x) => x > header)) {
    const a = text(cellAt(sheet, r, col.owner));
    if (a.startsWith("ต้องตรงกับ")) continue; // แถวคำอธิบายของเทมเพลต
    const watched = [col.owner, col.kind, col.name, col.date, col.units, col.price, col.fee, col.currency, ...(col.rate ? [col.rate] : [])];
    if (watched.every((c) => { const v = cellAt(sheet, r, c); return !v || v.value === null || String(v.value).trim() === ""; })) continue;
    const where = { sheet: sheet.name, row: r, label: "ล็อต" };
    const before = issues.length;

    const owner = ownersByName.get(a);
    if (!owner) issues.push({ ...where, message: `ถือในชื่อ "${a || "(ว่าง)"}" ไม่ตรงกับผู้ถือคนใดในระบบ` });
    const kind = text(cellAt(sheet, r, col.kind));
    if (!LOT_KINDS.has(kind)) issues.push({ ...where, message: `ประเภท "${kind || "(ว่าง)"}" ไม่อยู่ในรายการ (${[...LOT_KINDS].join(" / ")})` });
    const nm = text(cellAt(sheet, r, col.name));
    if (!nm) issues.push({ ...where, message: "ไม่ได้ระบุชื่อ/รหัสหลักทรัพย์" });
    const boughtOn = dateFromCell(cellAt(sheet, r, col.date));
    if (!boughtOn) issues.push({ ...where, message: "วันที่ซื้ออ่านเป็นวันที่ไม่ได้ (รับ วว/ดด/ปปปป ค.ศ. หรือวันที่ของ Excel)" });
    else if (boughtOn > ctx.cutoff) issues.push({ ...where, message: `วันที่ซื้อ ${boughtOn} หลังวันตัดยอด ${ctx.cutoff} — ล็อตที่ซื้อหลังวันตัดยอดต้องบันทึกเป็นรายการซื้อ ไม่ใช่ยอดตั้งต้น` });
    const units = amountFrom(cellAt(sheet, r, col.units), { ...where, label: "จำนวนหน่วย" }, issues, 6);
    const price = amountFrom(cellAt(sheet, r, col.price), { ...where, label: "ราคาต่อหน่วย" }, issues, 6);
    const fee = amountFrom(cellAt(sheet, r, col.fee), { ...where, label: "ค่าธรรมเนียม" }, issues) ?? 0;
    const cur = text(cellAt(sheet, r, col.currency));
    const rate = col.rate ? amountFrom(cellAt(sheet, r, col.rate), { ...where, label: "อัตรา ณ วันซื้อ" }, issues, 8) : null;

    const known = (CURRENCIES as readonly string[]).includes(cur);
    if (!known) {
      issues.push({ ...where, message: `สกุลเงิน "${cur || "(ว่าง)"}" ไม่อยู่ในรายการที่รับ (${CURRENCIES.join(" / ")})` });
    } else if (cur === "THB") {
      if (rate !== null && rate !== 1) issues.push({ ...where, message: `ล็อตสกุลบาทมีอัตรา ${rate} — ล็อตบาทไม่ต้องใส่อัตรา (ถ้าเป็นหุ้น/คริปโตต่างประเทศให้เปลี่ยนสกุลเป็นสกุลจริงของล็อต)` });
    } else if (!col.rate) {
      issues.push({ ...where, message: `ล็อตสกุล ${cur} ต้องมีอัตรา ณ วันซื้อ แต่ไม่พบคอลัมน์ "อัตรา ณ วันซื้อ" ในชีท — ใช้เทมเพลตรุ่นล่าสุด · ระบบไม่เดาอัตราให้ (เดาแล้วต้นทุนผิดและกำไรตอนขายผิดทั้งก้อน)` });
    } else if (rate === null) {
      issues.push({ ...where, message: `ล็อตสกุล ${cur} ต้องมีอัตรา ณ วันซื้อ (บาทต่อ 1 ${cur}) — ช่องนี้ว่าง · ระบบไม่เดาอัตราให้ เพราะเดาแล้วต้นทุนผิดและกำไรตอนขายผิดทั้งก้อน` });
    } else if (rate <= 0) {
      issues.push({ ...where, message: `อัตรา ณ วันซื้อต้องมากกว่า 0 (ได้ ${rate})` });
    }
    if (units === null || units <= 0) issues.push({ ...where, message: "จำนวนหน่วยต้องมากกว่า 0" });
    if (price === null || price < 0) issues.push({ ...where, message: "ราคาต่อหน่วยต้องไม่ติดลบ" });
    if (fee < 0) issues.push({ ...where, message: "ค่าธรรมเนียมต้องไม่ติดลบ" });
    if (issues.length > before || !owner || units === null || price === null || !boughtOn) continue;

    const foreign = cur !== "THB";
    const { amountOriginal, costThb } = lotCost(units, price, fee, foreign ? rate : null);
    lots.push({
      ownerId: owner.id,
      ownerName: owner.name,
      kind,
      name: nm,
      boughtOn,
      units,
      pricePerUnit: price,
      fee,
      cost: costThb,
      currency: cur,
      ...(foreign ? { amountOriginal, fxRate: rate! } : {}),
      coaCode: COMMODITY_KINDS.has(kind) ? "1720" : "1700",
      row: r,
    });
  }
  return lots;
}

/* ---------------------------------------------------------------- ตัวหลัก */

export function parseOpeningWorkbook(wb: Workbook, ctx: ParseContext): ParseResult {
  const issues: ImportIssue[] = [];
  const warnings: string[] = [];
  const ownersByName = new Map(ctx.owners.map((o) => [o.name.trim(), o]));
  const sheetByOwner = new Map<string, Sheet>();

  for (const sh of wb.sheets) {
    if (IGNORED_SHEETS.has(sh.name) || sh.name === LOTS_SHEET) continue;
    if (!sh.name.startsWith(SHEET_PREFIX)) {
      warnings.push(`ชีท "${sh.name}" ไม่ใช่ชีทของเทมเพลต จึงไม่ถูกอ่าน`);
      continue;
    }
    const nm = sh.name.slice(SHEET_PREFIX.length).trim();
    const owner = ownersByName.get(nm);
    if (!owner) {
      issues.push({ sheet: sh.name, message: `ชื่อผู้ถือ "${nm}" ไม่ตรงกับผู้ถือคนใดในระบบ — ชื่อชีทต้องเป็น "BS-" ตามด้วยชื่อผู้ถือให้ตรงทุกตัวอักษร` });
      continue;
    }
    if (owner.status !== "active") {
      issues.push({ sheet: sh.name, message: `ผู้ถือ "${nm}" ยังไม่เปิดใช้งาน (สถานะ ${owner.status}) — ลงยอดตั้งต้นให้ไม่ได้` });
      continue;
    }
    sheetByOwner.set(owner.id, sh);
  }
  for (const o of ctx.owners.filter((x) => x.status === "active")) {
    if (!sheetByOwner.has(o.id)) {
      issues.push({ sheet: "(ทั้งไฟล์)", message: `ไม่พบชีท "BS-${o.name}" — ผู้ถือที่ใช้งานอยู่ทุกคนต้องมีชีท (ไม่มียอดก็ปล่อยว่างทั้งชีท) เพื่อให้รู้ว่าตั้งใจว่าง ไม่ใช่ลืม` });
    }
  }
  const lotsSheet = wb.sheets.find((s) => s.name === LOTS_SHEET);
  if (!lotsSheet) {
    issues.push({ sheet: "(ทั้งไฟล์)", message: `ไม่พบชีท "${LOTS_SHEET}" — ต้องมีชีทนี้เสมอ (ไม่มีหลักทรัพย์ก็ปล่อยว่าง)` });
  }

  const sheets: OwnerSheet[] = [];
  for (const o of ctx.owners) {
    const sh = sheetByOwner.get(o.id);
    if (sh) sheets.push(readOwnerSheet(sh, o, ctx, issues));
  }
  const lots = lotsSheet ? readLots(lotsSheet, ownersByName, ctx, issues) : [];

  // ล็อตต้องรวมได้เท่า 1700 / 1720 ของแต่ละผู้ถือ
  for (const os of sheets) {
    for (const code of ["1700", "1720"] as const) {
      const declared = os.amounts.get(code);
      const sum = round2(lots.filter((l) => l.ownerId === os.owner.id && l.coaCode === code).reduce((t, l) => t + l.cost, 0));
      if (cents(declared?.amount ?? 0) !== cents(sum)) {
        issues.push({
          sheet: os.sheet,
          row: declared?.row,
          message:
            `${code} ${coa(code).nameTh} = ${(declared?.amount ?? 0).toLocaleString("en-US")} แต่ชีทรายล็อตของ ${os.owner.name} รวมได้ ${sum.toLocaleString("en-US")} ` +
            `(ต่างกัน ${round2((declared?.amount ?? 0) - sum).toLocaleString("en-US")}) — ต้องเท่ากันทุกสตางค์ (ระบบต้องรู้ล็อตเพื่อคิดต้นทุนถัวเฉลี่ยทีหลัง · ย้อนสร้างไม่ได้)`,
        });
      }
    }
  }

  const journals: OwnerJournal[] = [];
  for (const os of sheets) {
    const j = buildJournal(os, ctx, issues);
    if (j) journals.push(j);
  }

  if (issues.length) return { ok: false, issues };

  // ลูกหนี้/เจ้าหนี้ระหว่างกันต้องหักกันได้ในงบรวม — เตือน ไม่ปฏิเสธ (แต่ละผู้ถือยังดุลในตัวเอง)
  const sumCode = (code: string) => round2(sheets.reduce((t, s) => t + (s.amounts.get(code)?.amount ?? 0), 0));
  if (cents(sumCode("1310")) !== cents(sumCode("2310"))) {
    warnings.push(
      `ลูกหนี้ระหว่างกัน 1310 รวม ${sumCode("1310").toLocaleString("en-US")} ไม่เท่าเจ้าหนี้ระหว่างกัน 2310 รวม ${sumCode("2310").toLocaleString("en-US")} — ` +
        "งบรวมตัดรายการระหว่างกันไม่ได้จนกว่าจะเท่ากัน (ตรวจว่าฝั่งตรงข้ามกรอกครบหรือไม่)"
    );
  }
  return { ok: true, parsed: { cutoff: ctx.cutoff, journals, lots, warnings } };
}

/* ---------------------------------------------------------------- ลายนิ้วมือ */

/** ลายนิ้วมือของ "เนื้อหาที่จะนำเข้า" — ไม่ผูกกับตัวไฟล์ (บันทึกใหม่/จัดรูปใหม่แล้วเนื้อเหมือนเดิมต้องได้ค่าเดิม) */
export function fingerprintOf(p: Pick<ParsedOpening, "cutoff" | "journals" | "lots">): string {
  const canon = {
    v: 2,
    cutoff: p.cutoff,
    journals: [...p.journals]
      .sort((a, b) => a.ownerId.localeCompare(b.ownerId))
      .map((j) => ({
        owner: j.ownerId,
        lines: j.lines
          .map((l) => [l.coaCode, l.bankAccountId ?? "", cents(l.debit), cents(l.credit)] as const)
          .sort((a, b) => (a[0] + a[1]).localeCompare(b[0] + b[1])),
      })),
    lots: p.lots
      .map((l) => [l.ownerId, l.coaCode, l.kind, l.name, l.boughtOn, l.units, l.pricePerUnit, cents(l.fee), l.currency, l.fxRate ?? null, cents(l.cost)] as const)
      .sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b))),
  };
  return createHash("sha256").update(JSON.stringify(canon)).digest("hex");
}

/* ---------------------------------------------------------------- แผน (ใหม่ / ไม่เปลี่ยน / กลับแล้วลงใหม่) */

/**
 * ใบยอดตั้งต้นที่ **อยู่ในสมุดจริงและยังไม่ถูกกลับรายการ** — ผู้เรียกอ่านจาก DB (ไม่รับจากไฟล์หรือจากหน้าจอ)
 * หลักยึดที่ใช้บอกว่า "ใบนี้คือยอดตั้งต้น" ต้องเป็นสิ่งที่ DB กำหนด (ประเภทรายการในตารางกฎ) ไม่ใช่ป้ายที่ผู้เรียกส่งมา
 */
export type ExistingOpeningEntry = {
  txnId: string;
  ownerId: string;
  docDate: string;
  lines: JournalLine[];
};

export type PlanAction = "new" | "unchanged" | "replace" | "retract";

export type PlanItem = {
  ownerId: string;
  ownerName: string;
  action: PlanAction;
  /** บรรทัดที่จะลงใหม่ (ว่างเมื่อ unchanged/retract) */
  post: JournalLine[];
  /** ใบเดิมที่ต้องกลับรายการก่อน (ไม่มีการลบ) */
  reverse: string[];
  note?: string;
};

export type OpeningPlan = {
  cutoff: string;
  fingerprint: string;
  items: PlanItem[];
  /** ไม่มีอะไรต้องทำเลย (อัปโหลดเนื้อหาเดิมซ้ำ) */
  nothingToDo: boolean;
  totals: { owners: number; journals: number; lines: number; assets: number; liabilities: number; equity: number };
};

/**
 * ลายเซ็นเนื้อหาของชุดยอดตั้งต้นหนึ่งชุด — **รวมเป็นยอดสุทธิต่อ (รหัสบัญชี, บัญชีธนาคาร)** ไม่เทียบทีละบรรทัด
 * เพราะในสมุดจริงยอดตั้งต้นของผู้ถือหนึ่งคนกระจายหลายใบ (หนึ่งหมวดต่อใบ · หุ้นต่อทรัพย์หนึ่งใบ) และแต่ละใบมีขา 3300 ของตัวเอง
 * ขณะที่ชุดจากไฟล์เป็นบรรทัดเดียวต่อรหัสบัญชี — เทียบทีละบรรทัดจะเห็น "ต่าง" ทั้งที่ยอดสุทธิเท่ากัน
 */
const signature = (docDate: string, lines: JournalLine[]): string => {
  const net = new Map<string, number>();
  for (const l of lines) {
    const k = `${l.coaCode}|${l.bankAccountId ?? ""}`;
    net.set(k, (net.get(k) ?? 0) + cents(l.debit) - cents(l.credit));
  }
  return JSON.stringify([docDate, [...net].filter(([, v]) => v !== 0).sort(([x], [y]) => x.localeCompare(y))]);
};

export function planOpeningImport(parsed: ParsedOpening, existing: ExistingOpeningEntry[], ownerNames: Map<string, string>): OpeningPlan {
  const items: PlanItem[] = [];
  const byOwner = new Map<string, ExistingOpeningEntry[]>();
  for (const e of existing) byOwner.set(e.ownerId, [...(byOwner.get(e.ownerId) ?? []), e]);

  const ownerIds = new Set([...parsed.journals.map((j) => j.ownerId), ...byOwner.keys()]);
  for (const ownerId of [...ownerIds].sort()) {
    const next = parsed.journals.find((j) => j.ownerId === ownerId);
    const prev = byOwner.get(ownerId) ?? [];
    const ownerName = next?.ownerName ?? ownerNames.get(ownerId) ?? ownerId;

    if (next && prev.length === 0) {
      items.push({ ownerId, ownerName, action: "new", post: next.lines, reverse: [] });
    } else if (next) {
      // ชุดเดิมของผู้ถือคนนี้ที่ยังไม่ถูกกลับ: เทียบเนื้อหา "ทั้งชุด" (รวมวันที่) กับชุดใหม่
      const prevSig = signature(prev[0].docDate, prev.flatMap((e) => e.lines));
      const sameDate = prev.every((e) => e.docDate === parsed.cutoff);
      if (sameDate && prevSig === signature(parsed.cutoff, next.lines)) {
        items.push({ ownerId, ownerName, action: "unchanged", post: [], reverse: [] });
      } else {
        items.push({
          ownerId,
          ownerName,
          action: "replace",
          post: next.lines,
          reverse: prev.map((e) => e.txnId),
          note: sameDate ? undefined : `วันตัดยอดเปลี่ยนจาก ${prev[0].docDate} เป็น ${parsed.cutoff}`,
        });
      }
    } else {
      // เคยนำเข้า แต่ไฟล์ใหม่ไม่มียอดของคนนี้เลย = ถอนยอดตั้งต้นของเขา (กลับรายการ ไม่ลบ)
      items.push({ ownerId, ownerName, action: "retract", post: [], reverse: prev.map((e) => e.txnId), note: "ไฟล์ใหม่ไม่มียอดของผู้ถือคนนี้ — กลับรายการชุดเดิมทั้งหมด" });
    }
  }

  const posted = items.filter((i) => i.post.length);
  const sumType = (t: string) => round2(parsed.journals.reduce((s, j) => s + (t === "asset" ? j.assets : t === "liability" ? j.liabilities : j.equity), 0));
  return {
    cutoff: parsed.cutoff,
    fingerprint: fingerprintOf(parsed),
    items,
    nothingToDo: items.every((i) => i.action === "unchanged"),
    totals: {
      owners: parsed.journals.length,
      journals: posted.length,
      lines: posted.reduce((t, i) => t + i.post.length, 0),
      assets: sumType("asset"),
      liabilities: sumType("liability"),
      equity: sumType("equity"),
    },
  };
}
