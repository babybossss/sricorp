/**
 * ตรวจไฟล์ยอดตั้งต้นแบบออฟไลน์ — ใช้ตัวอ่านตัวเดียวกับหน้า /import
 *
 *   npx tsx scripts/check-opening-file.ts <ไฟล์ยอดตั้งต้น.xlsx> [--breakdown <ไฟล์แจกแจงทรัพย์.xlsx>] --refs <refs.json>
 *
 * ทำไมต้องมี: หน้าเว็บตรวจให้อยู่แล้ว แต่ต้องอัปโหลดทีละรอบ
 * สคริปต์นี้พิมพ์ข้อผิดทั้งหมดรอบเดียว รวมถึง **ชื่อบัญชีธนาคารที่ไฟล์ต้องการ**
 * ซึ่งต้องไปสร้างในหน้าตั้งค่าก่อน (ระบบไม่สร้างบัญชีให้เองและไม่เดาว่าเป็นบัญชีไหน)
 *
 * refs.json = { "owners": [{id,name,status}], "banks": [{id,ownerId,name,isActive,currency}] }
 * ถ้ายังไม่มีบัญชีธนาคารในระบบ ให้ส่ง "banks": [] แล้วอ่านรายชื่อที่ไฟล์ต้องการจากผลตรวจ
 *
 * **สคริปต์นี้อ่านเท่านั้น ไม่เขียนอะไรลง DB** และไม่ต้องต่อ DB เลย
 */
import { readFileSync } from "node:fs";
import { readWorkbook, XlsxError, MAX_XLSX_BYTES } from "../src/lib/db/import/xlsx";
import { detectCutoff, parseOpeningWorkbook, type BankRef, type ImportIssue, type OwnerRef } from "../src/lib/db/import/opening";

type Refs = { owners: OwnerRef[]; banks: BankRef[] };

function arg(flag: string): string | null {
  const i = process.argv.indexOf(flag);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : null;
}

function die(msg: string): never {
  console.error(`\n✗ ${msg}\n`);
  process.exit(2);
}

function load(path: string) {
  const buf = readFileSync(path);
  if (buf.byteLength > MAX_XLSX_BYTES) die(`${path} ใหญ่เกิน ${MAX_XLSX_BYTES / 1024 / 1024} MB`);
  try {
    return readWorkbook(buf);
  } catch (e) {
    if (e instanceof XlsxError) die(`อ่าน ${path} ไม่ได้: ${e.message}`);
    throw e;
  }
}

function printIssues(issues: ImportIssue[]) {
  const bySheet = new Map<string, ImportIssue[]>();
  for (const it of issues) {
    const k = it.sheet || "(ไม่ระบุชีท)";
    if (!bySheet.has(k)) bySheet.set(k, []);
    bySheet.get(k)!.push(it);
  }
  for (const [sheet, list] of bySheet) {
    console.log(`\n■ ชีท ${sheet} — ${list.length} ข้อ`);
    // เรียงตามแถวเพื่อให้ไล่แก้ในไฟล์ได้จากบนลงล่าง
    for (const it of [...list].sort((a, b) => (a.row ?? 0) - (b.row ?? 0))) {
      console.log(`   ${it.row ? `แถว ${String(it.row).padStart(4)}` : "        "}  ${it.message}`);
    }
  }
}

/** ชื่อบัญชีที่ไฟล์อ้างแต่ยังไม่มีในระบบ — ดึงจากข้อความของตัวอ่าน ไม่เดาเอง */
function missingBankNames(issues: ImportIssue[]): string[] {
  const out = new Set<string>();
  for (const it of issues) {
    const m = /^บัญชี "(.+?)" ไม่มีในระบบเป็นของ (.+?) —/.exec(it.message);
    if (m) out.add(`${m[2]}  →  ${m[1]}`);
  }
  return [...out].sort();
}

function main() {
  const file = process.argv[2];
  if (!file || file.startsWith("--")) die("ต้องใส่ path ของไฟล์ยอดตั้งต้น (.xlsx) เป็นอาร์กิวเมนต์แรก");
  const refsPath = arg("--refs");
  if (!refsPath) die("ต้องใส่ --refs <refs.json> (owners + banks)");
  const refs = JSON.parse(readFileSync(refsPath, "utf8")) as Refs;
  if (!Array.isArray(refs.owners) || !refs.owners.length) die("refs.json ต้องมี owners อย่างน้อยหนึ่งราย");
  if (!Array.isArray(refs.banks)) die("refs.json ต้องมี banks (ใส่ [] ได้ถ้ายังไม่มีบัญชีในระบบ)");

  const wb = load(file);
  const breakdownPath = arg("--breakdown");
  const breakdownWb = breakdownPath ? load(breakdownPath) : null;

  console.log(`ไฟล์ยอดตั้งต้น : ${file}`);
  console.log(`ไฟล์แจกแจงทรัพย์: ${breakdownPath ?? "(ไม่ได้แนบ — ต้องมีชีท “แจกแจงทรัพย์” อยู่ในไฟล์ยอดตั้งต้นแทน)"}`);
  console.log(`ผู้ถือในระบบ    : ${refs.owners.length} ราย · บัญชีธนาคารในระบบ: ${refs.banks.length} บัญชี`);
  console.log(`ชีทในไฟล์       : ${wb.sheets.map((s) => s.name).join(" · ")}`);

  const cut = detectCutoff(wb);
  if (!cut.ok) {
    console.log("\n✗ หาวันตัดยอดไม่ได้");
    printIssues(cut.issues);
    process.exit(1);
  }
  console.log(`วันตัดยอด       : ${cut.cutoff}`);

  const res = parseOpeningWorkbook(wb, { owners: refs.owners, banks: refs.banks, cutoff: cut.cutoff }, breakdownWb);

  if (!res.ok) {
    console.log(`\n✗ ยังนำเข้าไม่ได้ — พบ ${res.issues.length} ข้อที่ต้องแก้`);
    printIssues(res.issues);
    const missing = missingBankNames(res.issues);
    if (missing.length) {
      console.log(`\n▶ ต้องสร้างบัญชีธนาคารที่หน้า /settings/banks ก่อน ${missing.length} บัญชี`);
      console.log("   (ชื่อต้องตรงกับในไฟล์ทุกตัวอักษร ระบบไม่เดาให้)\n");
      for (const m of missing) console.log(`   ผู้ถือ ${m}`);
    }
    process.exit(1);
  }

  const p = res.parsed;
  const lines = p.journals.reduce((t, j) => t + j.lines.length, 0);
  console.log("\n✓ ไฟล์ผ่านการตรวจทั้งหมด — พร้อมอัปโหลดที่หน้า /import");
  console.log(`   ผู้ถือที่มียอด : ${p.journals.length} ราย`);
  console.log(`   บรรทัดบัญชี    : ${lines}`);
  console.log(`   ล็อตลงทุน      : ${p.lots.length}`);
  console.log(`   ทรัพย์รายชิ้น  : ${p.assetItems.length}`);
}

main();
