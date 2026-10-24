import { readFileSync } from "node:fs";
import path from "node:path";
import { readWorkbook, type Workbook } from "../xlsx";
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
  { id: "b-sri-scb", ownerId: "o-sri", name: "SRI - SCB", isActive: true },
  { id: "b-tk-bbl", ownerId: "o-thanakorn", name: "ธนากร - BBL 888", isActive: true },
  { id: "b-tk-scb", ownerId: "o-thanakorn", name: "ธนากร - SCB", isActive: true },
  { id: "b-st-ttb", ownerId: "o-suthee", name: "สุธี - TTB", isActive: true },
];

export const ctxOf = (over: Partial<ParseContext> = {}): ParseContext => ({
  owners: OWNERS.map((o) => ({ ...o })),
  banks: BANKS.map((b) => ({ ...b })),
  cutoff: CUTOFF,
  ...over,
});

/** อ่านไฟล์ตัวอย่างใหม่ทุกครั้ง (เทสต์แก้ได้โดยไม่รบกวนกัน) */
export const loadFixture = (): Workbook => readWorkbook(readFileSync(FIXTURE));

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
