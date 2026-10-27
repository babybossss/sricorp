import { readFileSync } from "node:fs";
import path from "node:path";
import { cellAt, readWorkbook, type Cell, type Workbook } from "../xlsx";
import { BREAKDOWN_CODES, BREAKDOWN_SHEET } from "../breakdown";
import { coa } from "@/lib/rules/coa";
import type { BankRef, OwnerRef, ParseContext } from "../opening";

export const FIXTURE = path.join(__dirname, "fixtures", "opening-valid.xlsx");
export const CUTOFF = "2026-09-30";

export const OWNERS: OwnerRef[] = [
  { id: "o-sri", name: "SRI Corporation", status: "active" },
  { id: "o-thanakorn", name: "ธนากร", status: "active" },
  { id: "o-suthee", name: "สุธี", status: "active" },
  { id: "o-sudjit", name: "สุดจิตต์", status: "active" },
  { id: "o-thanawin", name: "ธนวินท์", status: "active" },
  { id: "o-benjaporn", name: "เบ็ญจพร", status: "active" },
];

export const BANKS: BankRef[] = [
  { id: "b-sri-scb", ownerId: "o-sri", name: "SRI - SCB", isActive: true, currency: "THB" },
  { id: "b-tk-bbl", ownerId: "o-thanakorn", name: "ธนากร - BBL 888", isActive: true, currency: "THB" },
  { id: "b-tk-scb", ownerId: "o-thanakorn", name: "ธนากร - SCB", isActive: true, currency: "THB" },
  { id: "b-st-ttb", ownerId: "o-suthee", name: "สุธี - TTB", isActive: true, currency: "THB" },
];

export const ctxOf = (over: Partial<ParseContext> = {}): ParseContext => ({
  owners: OWNERS.map((o) => ({ ...o })),
  banks: BANKS.map((b) => ({ ...b })),
  cutoff: CUTOFF,
  ...over,
});

/**
 * อ่านไฟล์ตัวอย่างใหม่ทุกครั้ง (เทสต์แก้ได้โดยไม่รบกวนกัน)
 *
 * ไฟล์ตัวอย่างเก่ายังไม่มีชีท "แจกแจงทรัพย์" (ชีทนี้ **บังคับ** — ไม่มี = ปฏิเสธทั้งไฟล์) จึงเติมให้จากยอดในชีท BS-*:
 * หนึ่งบรรทัดทรัพย์ต่อหนึ่งช่องยอดที่ต้องแจกแจง · นี่คือข้อมูลทดสอบ ไม่ใช่ logic บัญชี (ระบบจริงไม่เติมให้)
 * เทสต์ที่แก้ยอดชีท BS- ของบรรทัดเหล่านี้ต้องเรียก `syncBreakdown()` ใหม่ ไม่งั้นการกระทบยอดจะปฏิเสธ (ตั้งใจ)
 */
export const loadFixture = (): Workbook => syncBreakdown(loadRawFixture());
/** ไฟล์ตัวอย่างตามที่อยู่ในดิสก์ ไม่เติมอะไร (ไว้เทสต์ตัวอ่าน xlsx เอง) */
export const loadRawFixture = (): Workbook => readWorkbook(readFileSync(FIXTURE));

export type BreakdownRow = { owner: string; code?: string; name: string; line: string; cost: number; reno?: number; note?: string };

/** บรรทัดทรัพย์ที่ตรงกับยอดในชีท BS-* พอดี (ช่องละหนึ่งชิ้น) */
export function breakdownRowsFromBs(wb: Workbook): BreakdownRow[] {
  const out: BreakdownRow[] = [];
  for (const s of wb.sheets.filter((x) => x.name.startsWith("BS-"))) {
    const owner = s.name.slice(3);
    for (const [r] of [...s.rows].sort((a, b) => a[0] - b[0])) {
      const code = String(cellAt(s, r, "A")?.value ?? "");
      const v = cellAt(s, r, "E")?.value;
      if (BREAKDOWN_CODES.includes(code) && typeof v === "number" && v > 0) {
        out.push({ owner, name: `${coa(code).nameTh} · ชิ้นที่ 1 ของ${owner}`, line: code, cost: v });
      }
    }
  }
  return out;
}

/** เขียนชีท "แจกแจงทรัพย์" ตามโครงเทมเพลต (หัวแถว 4 · แถวคำอธิบาย 5 · ข้อมูลตั้งแต่แถว 6 · ตารางสรุปอยู่ใต้ตาราง) */
export function setBreakdown(wb: Workbook, rows: BreakdownRow[], name = BREAKDOWN_SHEET): Workbook {
  const sheet = { name, rows: new Map<number, Map<string, Cell>>() };
  const put = (r: number, c: string, value: string | number | null, formula = false) => {
    const row = sheet.rows.get(r) ?? new Map<string, Cell>();
    sheet.rows.set(r, row);
    row.set(c, { value, formula });
  };
  ["ถือในชื่อ *", "รหัสทรัพย์", "ชื่อทรัพย์ *", "บรรทัดในงบดุล *", "ต้นทุน *", "ค่ารีโนเวทสะสม", "หมายเหตุ"].forEach((h, i) => put(4, "ABCDEFG"[i], h));
  put(5, "A", "เลือกจากรายชื่อผู้ถือ — ต้องตรงกับชื่อชีทงบดุลใน SRI_OS_2");
  rows.forEach((x, i) => {
    const r = 6 + i;
    put(r, "A", x.owner);
    if (x.code) put(r, "B", x.code);
    put(r, "C", x.name);
    put(r, "D", x.line);
    put(r, "E", x.cost);
    if (x.reno !== undefined) put(r, "F", x.reno);
    if (x.note) put(r, "G", x.note);
  });
  // ตารางสรุปอัตโนมัติของเทมเพลต (สูตร) — ตัวอ่านต้องไม่ถือเป็นบรรทัดทรัพย์
  put(207, "A", "ตารางสรุปอัตโนมัติ — ยอดรวมต่อผู้ถือ × ต่อบรรทัดงบดุล");
  put(209, "A", "SRI Corporation");
  put(209, "B", "1500");
  put(209, "E", 0, true);
  const keep = wb.sheets.filter((x) => x.name !== name);
  wb.sheets = [...keep, sheet];
  return wb;
}

/** ตั้งชีทแจกแจงให้ตรงกับชีท BS-* ปัจจุบัน */
export const syncBreakdown = (wb: Workbook): Workbook => setBreakdown(wb, breakdownRowsFromBs(wb));

export function sheetOf(wb: Workbook, name: string) {
  const s = wb.sheets.find((x) => x.name === name);
  if (!s) throw new Error(`fixture ไม่มีชีท ${name}`);
  return s;
}

/** ตั้งค่าช่อง (สร้างแถว/ช่องถ้ายังไม่มี) — `null` = ล้างช่อง */
export function setCell(wb: Workbook, sheet: string, row: number, col: string, value: string | number | null, formula = false) {
  const s = sheetOf(wb, sheet);
  const r = s.rows.get(row) ?? new Map();
  s.rows.set(row, r);
  r.set(col, { value, formula });
}
