/**
 * ชีท "แจกแจงทรัพย์" (เทมเพลต `templates/SRI_OS_3_แจกแจงทรัพย์สิน.xlsx`) — **อ่าน + กระทบยอดกับงบดุล**
 *
 * ทำไมต้องมี: ยอดตั้งต้นของอสังหาฯ / เงินให้กู้ / ขายฝาก ในชีท `BS-*` เป็น **ยอดรวมต่อรหัสบัญชี**
 * ถ้าลงสมุดเป็นบรรทัดรวม ทรัพย์แต่ละชิ้นจะ **ไม่มีต้นทุนรายชิ้น** → ขายไม่ออกตลอดไป
 * (`posting.ts` ปฏิเสธการขายเมื่อต้นทุน = 0) · ลูกพี่สั่ง 25/10: คอนโดคนละห้องก็คนละชิ้น ห้ามเฉลี่ยต้นทุน (D-117)
 *
 * ไฟล์นี้เป็นฟังก์ชันล้วน (ไม่แตะ DB ไม่คิดคู่บัญชี) ทำสองอย่าง:
 *   1. `readBreakdown()`      — อ่านบรรทัดทรัพย์ทุกบรรทัด รวบรวมความผิดทั้งหมดในครั้งเดียว
 *   2. `reconcileBreakdown()` — ผลบวกต้นทุนรายชิ้นต่อ (ผู้ถือ × รหัสบัญชี) **ต้องเท่ากับ** ยอดในชีท `BS-*` ทุกสตางค์
 *                              ไม่เท่า = ปฏิเสธทั้งไฟล์ พร้อมบอกว่าต่างกันที่ช่องไหน เท่าไร
 *                              (ห้ามเฉลี่ย · ห้ามปัดให้ลง · ห้ามลงบรรทัดส่วนต่าง — D-117)
 *
 * ส่วนการลงสมุด (หนึ่งบรรทัดต่อทรัพย์หนึ่งชิ้น พร้อม `asset_id`) อยู่ที่ `opening-post.ts` ผ่าน `buildPosting()`
 */

import { ASSET_CLASSES, classOfCoa } from "@/lib/rules/asset-classes";
import { RENOVATION_COA, coa } from "@/lib/rules/coa";
import { cellAt, type Cell, type Sheet } from "./xlsx";
import { amountFrom, cents, text } from "./cells";
import type { ImportIssue, OwnerRef } from "./opening";

/* ---------------------------------------------------------------- ค่าคงที่ของโครงไฟล์ */

export const BREAKDOWN_SHEET = "แจกแจงทรัพย์";

/**
 * บรรทัดงบดุลที่ **ต้องแจกแจงรายชิ้น** — ต้องตรงกับ `LINES` ใน `scripts/make-breakdown-template.py`
 * (เทสต์ `breakdown.test.ts` อ่านสคริปต์มาเทียบ · เพิ่มบรรทัดในเทมเพลตแล้วลืมที่นี่ = เทสต์แดง ไม่ใช่ยอดหลุดเงียบๆ)
 */
export const BREAKDOWN_CODES: readonly string[] = ["1500", "1520", "1510", "1300", "1320", "1400", "1410", "1600"];

/**
 * ค่ารีโนเวทสะสม (คอลัมน์ F) ไหลไปบัญชีนี้ — เป็นบัญชีร่วมของทั้งเพื่อการเช่าและเพื่อการขาย
 * แต่ยังผูกกับทรัพย์ชิ้นเดิมด้วย `asset_id`
 *
 * **ส่งต่อจากผังบัญชี ไม่ประกาศซ้ำ** — เดิมไฟล์นี้เขียน `"1510"` ไว้เอง ซึ่งเป็นรหัสเดียวกับ
 * ที่ `coa.ts` ประกาศอยู่แล้ว · ถ้าวันหนึ่งย้ายบัญชีค่ารีโนเวท สองที่จะแยกกันเดินโดยที่
 * typecheck ไม่ฟ้อง แล้วตัวนำเข้ากับ engine จะลงค่ารีโนเวทคนละบัญชี (บทเรียนผู้ตรวจข้อ 5)
 */
export { RENOVATION_COA };

export const isBreakdownCode = (code: string): boolean => BREAKDOWN_CODES.includes(code);

/**
 * หมวดย่อยของทรัพย์ที่ยอดในบัญชีนี้สังกัด — อ่านจากตารางหมวดทรัพย์ (`asset-classes.ts`) ไม่เขียนซ้ำที่นี่
 *
 * `null` = บัญชีนี้ **ไม่ใช่การลงทุน** จึงไม่มีหมวดทรัพย์ (ตอนนี้คือ `1600` เงินมัดจำจ่าย ซึ่ง
 * `asset-classes.ts` ประกาศไว้ใน `UNCLASSIFIED_ASSET_COA` ว่า "เงินวางประกัน รอคืน")
 * → **ไม่สร้างทรัพย์ และไม่ปฏิเสธ**: ลงสมุดเป็นบรรทัดรวมของบัญชีโดยไม่ผูก `asset_id`
 * แต่ **ยังกระทบยอดกับชีท `BS-*` ทุกสตางค์เหมือนกัน** และชื่อรายการที่กรอกไว้ไปอยู่ใน memo
 *
 * เหตุผลที่ไม่ต้องมีต้นทุนรายชิ้น: ทางคืนเงินมัดจำ (`inv.deposit_returned`) บังคับ `contact`
 * **ไม่ใช่ `asset`** → เงินมัดจำไม่ได้ถูก "ขาย" จึงไม่มีด่านไหนต้องการต้นทุนรายชิ้นของมัน
 * (ถ้าเพิ่มหมวดทรัพย์ให้ 1600 หน้าพอร์ตจะแสดงว่าบ้านนี้ "ลงทุนใน" เงินมัดจำ ซึ่งอ่านไม่รู้เรื่อง)
 *
 * มีหมวดเกินหนึ่ง = ตารางตั้งค่าขัดกันเอง → throw (เลือกให้ไม่ได้)
 */
export function assetCategoryOfCoa(coaCode: string): string | null {
  const hits = ASSET_CLASSES.flatMap((c) => c.categories).filter((cat) => cat.coaCodes.includes(coaCode));
  if (hits.length > 1) throw new Error(`บัญชี ${coaCode} อยู่ในหมวดทรัพย์มากกว่าหนึ่งหมวด (${hits.map((h) => h.code).join(", ")}) — เลือกให้ไม่ได้ ตรวจ asset-classes.ts`);
  return hits[0]?.code ?? null;
}

/* ---------------------------------------------------------------- ชนิด */

/** ทรัพย์หนึ่งชิ้นในชีทแจกแจง */
export type AssetItem = {
  ownerId: string;
  ownerName: string;
  /** "รหัสทรัพย์" ที่กรอก (ว่างได้) — ใช้จับคู่กับทรัพย์ที่มีอยู่แล้ว ไม่ใช่รหัสที่ระบบจะออกให้ */
  assetCode: string | null;
  name: string;
  /** บรรทัดในงบดุลที่ต้นทุนชิ้นนี้ไปลง */
  coaCode: string;
  /** ต้นทุนของชิ้นนี้เอง (บาท) */
  cost: number;
  /** ค่ารีโนเวทสะสมของชิ้นนี้ (บาท · 0 = ไม่มี) — ไปลงบัญชี 1510 แต่ผูกทรัพย์ชิ้นนี้ */
  renovation: number;
  note: string;
  row: number;
};

/** ผลรวมที่ชีทผู้ถือ (`BS-*`) ประกาศไว้ ต่อรหัสบัญชี — ใช้กระทบยอด */
export type DeclaredAmounts = {
  owner: OwnerRef;
  /** ชื่อชีท BS-… */
  sheet: string;
  amounts: Map<string, { amount: number; row: number }>;
};

/* ---------------------------------------------------------------- คอลัมน์ */

type Columns = { owner: string; code: string; name: string; line: string; cost: string; reno: string; note: string };

const HEADERS: { key: keyof Columns; startsWith: string; fallback: string }[] = [
  { key: "owner", startsWith: "ถือในชื่อ", fallback: "A" },
  { key: "code", startsWith: "รหัสทรัพย์", fallback: "B" },
  { key: "name", startsWith: "ชื่อทรัพย์", fallback: "C" },
  { key: "line", startsWith: "บรรทัดในงบดุล", fallback: "D" },
  { key: "cost", startsWith: "ต้นทุน", fallback: "E" },
  { key: "reno", startsWith: "ค่ารีโนเวท", fallback: "F" },
  { key: "note", startsWith: "หมายเหตุ", fallback: "G" },
];

/** อ่านตำแหน่งคอลัมน์จากหัวตาราง (ไม่ผูกกับตัวอักษรตายตัว) · หัวที่หาไม่เจอใช้ตำแหน่งของเทมเพลต */
function columnsOf(sheet: Sheet, headerRow: number): Columns {
  const row = sheet.rows.get(headerRow) ?? new Map<string, Cell>();
  const norm = (c: Cell) => text(c).replace(/[\s*＊]/g, "");
  const out = {} as Record<string, string>;
  for (const h of HEADERS) {
    const hit = [...row].find(([, c]) => norm(c).startsWith(h.startsWith.replace(/\s/g, "")));
    out[h.key] = hit ? hit[0] : h.fallback;
  }
  return out as Columns;
}

const normName = (s: string) => s.normalize("NFC").replace(/\s+/g, " ").trim().toLowerCase();

/* ---------------------------------------------------------------- อ่านชีท */

/**
 * อ่านบรรทัดทรัพย์ทั้งหมด · ปัญหาใดๆ ถูกใส่ใน `issues` (ผู้เรียกปฏิเสธทั้งไฟล์) · คืนเฉพาะบรรทัดที่อ่านได้สมบูรณ์
 *
 * `sheetLabel` = ชื่อที่ใช้บอกผู้ใช้ว่าปัญหาอยู่ที่ไหน (แยกไฟล์ต้องบอกให้ชัดว่าเป็นไฟล์แจกแจง ไม่ใช่ไฟล์ยอดตั้งต้น)
 */
export function readBreakdown(sheet: Sheet, sheetLabel: string, ownersByName: Map<string, OwnerRef>, issues: ImportIssue[]): AssetItem[] {
  const rowNumbers = [...sheet.rows.keys()].sort((a, b) => a - b);
  const header = rowNumbers.find((r) => text(cellAt(sheet, r, "A")).startsWith("ถือในชื่อ"));
  if (header === undefined) {
    issues.push({ sheet: sheetLabel, message: 'ไม่พบแถวหัวตาราง "ถือในชื่อ" — โครงชีทแจกแจงทรัพย์ผิดไปจากเทมเพลต (ใช้ไฟล์ SRI_OS_3_แจกแจงทรัพย์สิน.xlsx รุ่นล่าสุด)' });
    return [];
  }
  const col = columnsOf(sheet, header);
  // ตารางสรุปอัตโนมัติอยู่ใต้ตารางกรอก (แถวหัว "ตารางสรุป…") — เป็นสูตรของ Excel ห้ามอ่านเป็นบรรทัดทรัพย์
  const summaryAt = rowNumbers.find((r) => r > header && text(cellAt(sheet, r, col.owner)).startsWith("ตารางสรุป"));
  const items: AssetItem[] = [];
  const seenName = new Map<string, number>();
  const seenCode = new Map<string, number>();

  for (const r of rowNumbers) {
    if (r <= header) continue;
    if (summaryAt !== undefined && r >= summaryAt) break;
    const a = text(cellAt(sheet, r, col.owner));
    // แถวคำอธิบายใต้หัวตาราง (เทมเพลตใส่ไว้แถวถัดจากหัว)
    if (r === header + 1 && a.startsWith("เลือกจาก")) continue;
    const watched = [col.owner, col.code, col.name, col.line, col.cost, col.reno, col.note];
    if (watched.every((c) => { const v = cellAt(sheet, r, c); return !v || v.value === null || String(v.value).trim() === ""; })) continue;

    const where = { sheet: sheetLabel, row: r, label: "ทรัพย์" };
    const before = issues.length;
    const bad = (message: string) => issues.push({ sheet: sheetLabel, row: r, message });

    const owner = ownersByName.get(a);
    if (!owner) bad(`ถือในชื่อ "${a || "(ว่าง)"}" ไม่ตรงกับผู้ถือคนใดในระบบ — ต้องตรงกับชื่อชีท BS- ของไฟล์ยอดตั้งต้นทุกตัวอักษร`);

    const name = text(cellAt(sheet, r, col.name));
    if (!name) bad("ไม่ได้ระบุชื่อทรัพย์ — ต้องระบุให้แยกชิ้นได้จริง เช่น เลขห้อง/เลขโฉนด (ทรัพย์แต่ละชิ้นมีต้นทุนของตัวเอง)");

    const lineCell = cellAt(sheet, r, col.line);
    const codeRaw = typeof lineCell?.value === "number" ? String(lineCell.value) : text(lineCell);
    if (!isBreakdownCode(codeRaw)) {
      bad(
        `บรรทัดในงบดุล "${codeRaw || "(ว่าง)"}" ไม่ใช่บรรทัดที่แจกแจงรายชิ้น — ใช้ได้เฉพาะ ${BREAKDOWN_CODES.map((c) => `${c} ${coa(c).nameTh}`).join(" · ")} ` +
          "(ยอดของบัญชีอื่นกรอกที่ชีท BS- ตามเดิม)"
      );
    }

    const beforeCost = issues.length;
    const cost = amountFrom(cellAt(sheet, r, col.cost), { ...where, label: "ต้นทุน" }, issues);
    if (cost === null && issues.length === beforeCost) bad("ต้นทุนว่าง — ทรัพย์ทุกชิ้นต้องมีต้นทุนของตัวเอง (ไม่มีต้นทุนจะขายออกไม่ได้)");
    else if (cost !== null && cost <= 0) bad(`ต้นทุนต้องมากกว่า 0 (ได้ ${cost}) — ทรัพย์ที่ไม่มีต้นทุนขายออกไม่ได้ และห้ามเฉลี่ยต้นทุนจากชิ้นอื่นมาให้`);

    const reno = amountFrom(cellAt(sheet, r, col.reno), { ...where, label: "ค่ารีโนเวทสะสม" }, issues) ?? 0;
    if (reno < 0) bad(`ค่ารีโนเวทสะสมติดลบไม่ได้ (ได้ ${reno})`);
    if (reno > 0 && isBreakdownCode(codeRaw) && classOfCoa(codeRaw)?.code !== "RE") {
      bad(`ค่ารีโนเวทใส่ได้เฉพาะทรัพย์ที่เป็นอสังหาฯ — บรรทัด ${codeRaw} ${coa(codeRaw).nameTh} ไม่ใช่อสังหาฯ`);
    }

    const note = text(cellAt(sheet, r, col.note));
    if (note.startsWith("ตัวอย่าง")) {
      bad(`แถวนี้เป็นตัวอย่างในเทมเพลต (หมายเหตุ "${note.slice(0, 40)}") — ให้ลบแถวทิ้งก่อนอัปโหลด (ถ้าเป็นทรัพย์จริงให้ลบคำว่า "ตัวอย่าง" ออกจากหมายเหตุ) · ระบบไม่ข้ามแถวนี้ให้`);
    }

    const assetCode = text(cellAt(sheet, r, col.code)) || null;
    if (owner && name) {
      const nameKey = `${owner.id}|${normName(name)}`;
      const dup = seenName.get(nameKey);
      if (dup !== undefined) bad(`ชื่อทรัพย์ "${name}" ของ ${owner.name} ซ้ำกับแถว ${dup} — ทรัพย์หนึ่งชิ้นมีบรรทัดเดียว (ถ้าเป็นคนละห้อง/คนละโฉนด ให้ตั้งชื่อให้ต่างกัน)`);
      else seenName.set(nameKey, r);
    }
    if (owner && assetCode) {
      const codeKey = `${owner.id}|${normName(assetCode)}`;
      const dup = seenCode.get(codeKey);
      if (dup !== undefined) bad(`รหัสทรัพย์ "${assetCode}" ของ ${owner.name} ซ้ำกับแถว ${dup}`);
      else seenCode.set(codeKey, r);
    }

    if (issues.length > before || !owner || cost === null) continue;
    items.push({ ownerId: owner.id, ownerName: owner.name, assetCode, name, coaCode: codeRaw, cost, renovation: reno, note, row: r });
  }
  return items;
}

/* ---------------------------------------------------------------- กระทบยอด */

const baht = (cents_: number) => (cents_ / 100).toLocaleString("en-US", { minimumFractionDigits: 0, maximumFractionDigits: 2 });

/**
 * ผลบวกบรรทัดทรัพย์ต่อ (ผู้ถือ × รหัสบัญชี) ต้องเท่ากับยอดในชีท `BS-*` **ทุกสตางค์**
 *
 *  - รหัสทั่วไป: Σ ต้นทุนของบรรทัดที่เลือกรหัสนั้น
 *  - 1510 (ค่ารีโนเวท): Σ ค่ารีโนเวทสะสมของ **ทุกชิ้นของผู้ถือ** + Σ ต้นทุนของบรรทัดที่เลือก 1510 เอง
 *
 * ไม่เท่า = issue ที่ชีท BS- (แถวของรหัสนั้น) บอกยอดทั้งสองฝั่ง ผลต่าง และแถวทรัพย์ที่เกี่ยวข้อง ·
 * BS มียอดแต่ไม่มีบรรทัดทรัพย์เลย = issue เหมือนกัน (ไม่งั้นได้ทรัพย์ที่ขายไม่ออก) ·
 * ไม่มีทางผ่านด้วยการเฉลี่ย ปัดเศษ หรือลงบรรทัดส่วนต่างให้
 */
export function reconcileBreakdown(items: AssetItem[], declared: DeclaredAmounts[], sheetLabel: string, issues: ImportIssue[]): void {
  for (const d of declared) {
    const mine = items.filter((i) => i.ownerId === d.owner.id);
    for (const code of BREAKDOWN_CODES) {
      const bs = d.amounts.get(code);
      const bsCents = cents(bs?.amount ?? 0);
      const rows = code === RENOVATION_COA ? mine.filter((i) => i.coaCode === code || i.renovation > 0) : mine.filter((i) => i.coaCode === code);
      const sumCents = rows.reduce((t, i) => t + (i.coaCode === code ? cents(i.cost) : 0) + (code === RENOVATION_COA ? cents(i.renovation) : 0), 0);
      if (bsCents === sumCents) continue;

      const rowList = rows.length ? `แถว ${rows.map((i) => i.row).join(", ")} ของชีท "${sheetLabel}"` : `ไม่มีบรรทัดทรัพย์ในชีท "${sheetLabel}"`;
      const label = `${code} ${coa(code).nameTh}`;
      const composition = code === RENOVATION_COA ? " (ค่ารีโนเวทสะสมของทุกชิ้น + ต้นทุนของบรรทัดที่เลือก 1510)" : "";
      if (rows.length === 0) {
        issues.push({
          sheet: d.sheet,
          row: bs?.row,
          message:
            `${label} = ${baht(bsCents)} แต่ชีท "${sheetLabel}" ไม่มีทรัพย์ของ ${d.owner.name} ในบรรทัดนี้เลย — ` +
            "ยอดนี้ต้องแจกแจงเป็นรายชิ้น (ลงเป็นยอดรวมไม่ได้ เพราะทรัพย์จะไม่มีต้นทุนของตัวเองและขายออกไม่ได้) · " +
            "เพิ่มทรัพย์ทีละชิ้นในชีทแจกแจง หรือแก้ยอดในงบดุลให้ตรง",
        });
      } else {
        const diff = bsCents - sumCents;
        issues.push({
          sheet: d.sheet,
          row: bs?.row,
          message:
            `${label} = ${baht(bsCents)} แต่ทรัพย์ของ ${d.owner.name} ในชีท "${sheetLabel}" รวมได้ ${baht(sumCents)}${composition} ` +
            `(${rowList} · ต่างกัน ${baht(diff)}) — ต้องเท่ากันทุกสตางค์ · ระบบไม่เฉลี่ย ไม่ปัดให้ลง และไม่ลงบรรทัดส่วนต่างให้ (D-117)`,
        });
      }
    }
  }
  // ทรัพย์ของผู้ถือที่ไม่มีชีท BS- เลย — ไม่มีที่ให้กระทบ ห้ามปล่อยให้ยอดหายเงียบๆ
  const declaredOwners = new Set(declared.map((d) => d.owner.id));
  for (const i of items) {
    if (!declaredOwners.has(i.ownerId)) {
      issues.push({ sheet: sheetLabel, row: i.row, message: `ทรัพย์ของ ${i.ownerName} แต่ไม่มีชีท BS-${i.ownerName} ให้กระทบยอด — ยอดนี้จะหายจากงบดุล` });
    }
  }
}
