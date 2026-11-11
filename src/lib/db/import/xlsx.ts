/**
 * ตัวอ่านไฟล์ .xlsx แบบ **ไม่พึ่งไลบรารีภายนอก** (zip + XML ของ Office Open XML) — อ่านอย่างเดียว ไม่เขียน
 *
 * ทำไมไม่ใช้ `xlsx`/`exceljs`: ไฟล์ที่นำเข้าคือยอดเงินจริงของครอบครัว ไลบรารีแต่ละตัวพ่วง dependency
 * ยาวและเคยมีช่องโหว่ตอนอ่านไฟล์ที่ผู้ใช้อัปโหลด · สิ่งที่เราต้องการมีแค่ "ค่าในช่อง" ซึ่งอ่านเองได้ในไม่กี่ร้อยบรรทัด
 * และคุมได้ว่ารับอะไร ปฏิเสธอะไร
 *
 * กติกา
 *  - **สูตรไม่ใช่ข้อมูลนำเข้า**: ช่องที่เป็นสูตรถูกทำเครื่องหมาย `formula: true` ผู้ใช้ต้องไม่พึ่งผลคำนวณของ Excel
 *    (ตัวเลขที่ระบบใช้ต้องมาจากช่องที่คนกรอก และระบบคำนวณยอดรวมเองใหม่ทุกครั้ง)
 *  - ไฟล์ใหญ่เกินเพดาน / zip64 / ไฟล์เข้ารหัส / zip bomb = ปฏิเสธ ไม่พยายามอ่านต่อ
 *  - อ่านไม่ได้ = โยก `XlsxError` ที่มีข้อความภาษาไทย (ไม่เดา ไม่ข้ามเงียบ)
 */

import { inflateRawSync } from "node:zlib";

export class XlsxError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "XlsxError";
  }
}

export type Cell = { value: string | number | boolean | null; formula: boolean };
export type Sheet = {
  name: string;
  /** แถว (เลขแถวตามที่ Excel แสดง เริ่ม 1) → คอลัมน์ (A, B, …) → ช่อง */
  rows: Map<number, Map<string, Cell>>;
};
export type Workbook = { sheets: Sheet[] };

export const MAX_XLSX_BYTES = 10 * 1024 * 1024;
const MAX_UNCOMPRESSED_BYTES = 80 * 1024 * 1024;
const MAX_SHEET_ROWS = 20_000;

/* ---------------------------------------------------------------- zip */

type ZipEntry = { name: string; method: number; compressedSize: number; uncompressedSize: number; localOffset: number };

function readZip(buf: Buffer): Map<string, Buffer> {
  if (buf.length < 22) throw new XlsxError("ไฟล์เล็กเกินไป ไม่ใช่ไฟล์ Excel (.xlsx)");
  if (buf.length > MAX_XLSX_BYTES) {
    throw new XlsxError(`ไฟล์ใหญ่เกิน ${Math.round(MAX_XLSX_BYTES / 1024 / 1024)} MB — ไฟล์ยอดตั้งต้นควรเล็กกว่านี้มาก ตรวจว่าเป็นไฟล์ที่ถูกต้อง`);
  }
  // หา End Of Central Directory จากท้ายไฟล์
  let eocd = -1;
  for (let i = buf.length - 22; i >= Math.max(0, buf.length - 22 - 65535); i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new XlsxError("ไม่ใช่ไฟล์ Excel (.xlsx) — อ่านโครงสร้างไฟล์ไม่ได้ (ไฟล์ .xls เก่า หรือไฟล์เสียหาย)");
  const total = buf.readUInt16LE(eocd + 10);
  const cdSize = buf.readUInt32LE(eocd + 12);
  const cdOffset = buf.readUInt32LE(eocd + 16);
  if (total === 0xffff || cdSize === 0xffffffff || cdOffset === 0xffffffff) {
    throw new XlsxError("ไฟล์ zip64 ไม่รองรับ — บันทึกไฟล์ Excel ใหม่เป็น .xlsx ปกติ");
  }
  if (cdOffset + cdSize > buf.length) throw new XlsxError("ไฟล์ Excel เสียหาย (สารบัญไฟล์ภายในผิดตำแหน่ง)");

  const entries: ZipEntry[] = [];
  let p = cdOffset;
  for (let n = 0; n < total; n++) {
    if (p + 46 > buf.length || buf.readUInt32LE(p) !== 0x02014b50) throw new XlsxError("ไฟล์ Excel เสียหาย (สารบัญไฟล์ภายในอ่านไม่ได้)");
    const flags = buf.readUInt16LE(p + 8);
    if (flags & 1) throw new XlsxError("ไฟล์ Excel ถูกเข้ารหัส/ตั้งรหัสผ่าน — เปิดรหัสผ่านแล้วบันทึกใหม่ก่อนนำเข้า");
    const nameLen = buf.readUInt16LE(p + 28);
    const extraLen = buf.readUInt16LE(p + 30);
    const commentLen = buf.readUInt16LE(p + 32);
    entries.push({
      method: buf.readUInt16LE(p + 10),
      compressedSize: buf.readUInt32LE(p + 20),
      uncompressedSize: buf.readUInt32LE(p + 24),
      localOffset: buf.readUInt32LE(p + 42),
      name: buf.toString("utf8", p + 46, p + 46 + nameLen),
    });
    p += 46 + nameLen + extraLen + commentLen;
  }

  let totalOut = 0;
  const out = new Map<string, Buffer>();
  for (const e of entries) {
    if (e.name.endsWith("/")) continue;
    totalOut += e.uncompressedSize;
    if (totalOut > MAX_UNCOMPRESSED_BYTES) throw new XlsxError("ไฟล์ Excel ขยายแล้วใหญ่ผิดปกติ — ปฏิเสธเพื่อความปลอดภัย");
    // เฉพาะส่วนที่ต้องใช้ (ข้ามรูป/ธีม/สไตล์)
    if (!/^xl\/(workbook\.xml|_rels\/workbook\.xml\.rels|sharedStrings\.xml|worksheets\/[^/]+\.xml)$/.test(e.name)) continue;
    const lh = e.localOffset;
    if (lh + 30 > buf.length || buf.readUInt32LE(lh) !== 0x04034b50) throw new XlsxError("ไฟล์ Excel เสียหาย (ส่วนหัวของไฟล์ภายในผิด)");
    const dataStart = lh + 30 + buf.readUInt16LE(lh + 26) + buf.readUInt16LE(lh + 28);
    const raw = buf.subarray(dataStart, dataStart + e.compressedSize);
    if (raw.length !== e.compressedSize) throw new XlsxError("ไฟล์ Excel เสียหาย (ข้อมูลภายในถูกตัด)");
    let data: Buffer;
    if (e.method === 0) data = Buffer.from(raw);
    else if (e.method === 8) {
      try {
        data = inflateRawSync(raw, { maxOutputLength: MAX_UNCOMPRESSED_BYTES });
      } catch {
        throw new XlsxError(`ไฟล์ Excel เสียหาย (แตกไฟล์ภายใน ${e.name} ไม่ได้)`);
      }
    } else throw new XlsxError(`ไฟล์ Excel ใช้วิธีบีบอัดที่ไม่รองรับ (${e.method})`);
    out.set(e.name, data);
  }
  return out;
}

/* ---------------------------------------------------------------- xml */

const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };
function unescapeXml(s: string): string {
  return s.replace(/&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);/g, (_m, g: string) => {
    if (g[0] === "#") {
      const code = g[1] === "x" ? parseInt(g.slice(2), 16) : parseInt(g.slice(1), 10);
      return Number.isFinite(code) && code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : "";
    }
    return ENTITIES[g] ?? "";
  });
}

const attr = (tag: string, name: string): string | null => {
  const m = new RegExp(`(?:^|\\s)${name}="([^"]*)"`).exec(tag);
  return m ? unescapeXml(m[1]) : null;
};

/** ข้อความของ <si>/<is> — รวมทุก <t> แต่ข้ามตัวอ่านสัทศาสตร์ <rPh> */
function textOf(xml: string): string {
  const noPh = xml.replace(/<rPh[\s\S]*?<\/rPh>/g, "");
  let out = "";
  for (const m of noPh.matchAll(/<t(?:\s[^>]*)?>([\s\S]*?)<\/t>/g)) out += m[1];
  return unescapeXml(out);
}

function parseSharedStrings(xml: string | undefined): string[] {
  if (!xml) return [];
  return [...xml.matchAll(/<si(?:\s[^>]*)?>([\s\S]*?)<\/si>|<si\s*\/>/g)].map((m) => textOf(m[1] ?? ""));
}

/** "AB12" → { col: "AB", row: 12 } */
function splitRef(ref: string): { col: string; row: number } | null {
  const m = /^([A-Z]{1,3})([0-9]{1,7})$/.exec(ref);
  return m ? { col: m[1], row: Number(m[2]) } : null;
}

function parseSheet(xml: string, shared: string[], name: string): Sheet {
  const rows = new Map<number, Map<string, Cell>>();
  let rowCount = 0;
  for (const rm of xml.matchAll(/<row\b([^>]*?)(?:\/>|>([\s\S]*?)<\/row>)/g)) {
    if (++rowCount > MAX_SHEET_ROWS) throw new XlsxError(`ชีท "${name}" มีแถวมากเกิน ${MAX_SHEET_ROWS.toLocaleString("en-US")} แถว`);
    const body = rm[2] ?? "";
    for (const cm of body.matchAll(/<c\b([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)) {
      const ref = attr(cm[1], "r");
      const pos = ref ? splitRef(ref) : null;
      // ช่องที่ไม่มีตำแหน่ง = อ่านไม่รู้ว่าอยู่ตรงไหน → ปฏิเสธทั้งไฟล์ ไม่ข้ามเงียบๆ (ข้ามแล้วยอดหายโดยไม่มีใครรู้)
      if (!pos) throw new XlsxError(`ชีท "${name}" มีช่องที่ไม่ระบุตำแหน่ง (${ref ?? "ไม่มี r"}) — ไฟล์ผิดรูปแบบ`);
      const type = attr(cm[1], "t");
      const inner = cm[2] ?? "";
      const hasFormula = /<f[\s>\/]/.test(inner);
      const vMatch = /<v>([\s\S]*?)<\/v>/.exec(inner);
      let value: Cell["value"] = null;
      if (type === "inlineStr") {
        value = textOf(/<is>([\s\S]*?)<\/is>/.exec(inner)?.[1] ?? "");
      } else if (vMatch) {
        const raw = unescapeXml(vMatch[1]);
        if (type === "s") {
          const idx = Number(raw);
          if (!Number.isInteger(idx) || idx < 0 || idx >= shared.length) throw new XlsxError(`ชีท "${name}" ช่อง ${ref}: อ้างข้อความที่ไม่มีอยู่ในไฟล์`);
          value = shared[idx];
        } else if (type === "str") value = raw;
        else if (type === "b") value = raw === "1";
        else if (type === "e") value = null; // ค่า error ของ Excel (#REF! ฯลฯ) = ไม่มีค่า
        else {
          const n = Number(raw);
          value = raw.trim() === "" || !Number.isFinite(n) ? null : n;
        }
      }
      const row = rows.get(pos.row) ?? new Map<string, Cell>();
      row.set(pos.col, { value, formula: hasFormula });
      rows.set(pos.row, row);
    }
  }
  return { name, rows };
}

/** อ่านไฟล์ .xlsx ทั้งเล่ม */
export function readWorkbook(input: Buffer | Uint8Array): Workbook {
  const buf = Buffer.isBuffer(input) ? input : Buffer.from(input);
  const files = readZip(buf);
  const wbXml = files.get("xl/workbook.xml")?.toString("utf8");
  const relsXml = files.get("xl/_rels/workbook.xml.rels")?.toString("utf8");
  if (!wbXml || !relsXml) throw new XlsxError("ไม่ใช่ไฟล์ Excel (.xlsx) — ไม่พบสมุดงานภายในไฟล์");

  const targets = new Map<string, string>();
  for (const m of relsXml.matchAll(/<Relationship\b([^>]*?)\/?>/g)) {
    const id = attr(m[1], "Id");
    const target = attr(m[1], "Target");
    if (id && target) targets.set(id, target.startsWith("/") ? target.slice(1) : `xl/${target}`);
  }
  const shared = parseSharedStrings(files.get("xl/sharedStrings.xml")?.toString("utf8"));

  const sheets: Sheet[] = [];
  for (const m of wbXml.matchAll(/<sheet\b([^>]*?)\/?>/g)) {
    const name = attr(m[1], "name");
    const rid = attr(m[1], "r:id");
    const state = attr(m[1], "state");
    if (!name || !rid) continue;
    if (state === "hidden" || state === "veryHidden") continue; // ชีทซ่อนไม่ใช่สิ่งที่ผู้ใช้เห็น จึงไม่ใช่ข้อมูลนำเข้า
    const target = targets.get(rid);
    const xml = target ? files.get(target)?.toString("utf8") : undefined;
    if (!xml) throw new XlsxError(`ไฟล์ Excel เสียหาย: ไม่พบเนื้อหาของชีท "${name}"`);
    sheets.push(parseSheet(xml, shared, name));
  }
  if (sheets.length === 0) throw new XlsxError("ไฟล์ Excel ไม่มีชีทที่มองเห็นเลย");
  return { sheets };
}

/** ช่องของชีท (คอลัมน์เป็นตัวอักษร) — ไม่มี = null */
export function cellAt(sheet: Sheet, row: number, col: string): Cell | null {
  return sheet.rows.get(row)?.get(col) ?? null;
}
