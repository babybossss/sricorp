/**
 * เทมเพลต "แจกแจงทรัพย์สิน" (`templates/SRI_OS_3_แจกแจงทรัพย์สิน.xlsx`)
 * สร้างจาก `scripts/make-breakdown-template.py` ซึ่งเขียน Office Open XML เอง (เครื่องนี้ไม่มี openpyxl)
 *
 * เทสต์นี้อ่านไฟล์ **ด้วยตัวอ่าน xlsx ของโปรเจกต์เอง** (`../xlsx`) เพื่อพิสูจน์ว่า
 * ไฟล์ที่สคริปต์เขียนเป็นไฟล์ .xlsx ที่อ่านได้จริง ไม่ใช่ zip ที่ Excel จะเปิดไม่ขึ้น
 * ถ้าวันหนึ่งสคริปต์สร้างไฟล์เพี้ยน (ชีทหาย · หัวตารางเปลี่ยน · ยอดรวมไม่ตรง) เทสต์ต้องแดง
 *
 * หัวใจของไฟล์: ยอดรวมในตารางสรุปต้องเท่ากับผลบวกของบรรทัดทรัพย์ที่ลิสต์ไว้
 * เทสต์จึง **บวกเองจากบรรทัดทรัพย์** แล้วเทียบกับค่าที่สูตรในไฟล์คำนวณไว้ ไม่ใช่เชื่อค่าในไฟล์เฉยๆ
 */
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import path from "node:path";
import { cellAt, readWorkbook, type Sheet } from "../xlsx";

const TEMPLATE = path.join(__dirname, "..", "..", "..", "..", "..", "templates", "SRI_OS_3_แจกแจงทรัพย์สิน.xlsx");

const DETAIL = "แจกแจงทรัพย์";
const FIRST_DATA_ROW = 6;
const LAST_DATA_ROW = 205;

const OWNERS = ["SRI Corporation", "สุธี", "ธนากร", "ธนวินท์", "เบ็ญจพร", "สุดจิตต์"];
const LINES = ["1500", "1510", "1300", "1400", "1410", "1600"];

const load = () => readWorkbook(readFileSync(TEMPLATE));
const sheetOf = (name: string): Sheet => {
  const s = load().sheets.find((x) => x.name === name);
  if (!s) throw new Error(`เทมเพลตไม่มีชีท ${name}`);
  return s;
};

const str = (s: Sheet, row: number, c: string): string => {
  const v = cellAt(s, row, c)?.value;
  return typeof v === "string" ? v : "";
};
const num = (s: Sheet, row: number, c: string): number => {
  const v = cellAt(s, row, c)?.value;
  return typeof v === "number" ? v : 0;
};

/** บรรทัดทรัพย์ที่กรอกไว้จริงในช่วงตาราง (แถวว่างไม่นับ) */
type Item = { row: number; owner: string; code: string; cost: number; reno: number; name: string };
function itemsOf(s: Sheet): Item[] {
  const out: Item[] = [];
  for (let row = FIRST_DATA_ROW; row <= LAST_DATA_ROW; row++) {
    const owner = str(s, row, "A");
    const name = str(s, row, "C");
    const code = String(cellAt(s, row, "D")?.value ?? "");
    if (!owner && !name && !code) continue;
    out.push({ row, owner, code, name, cost: num(s, row, "E"), reno: num(s, row, "F") });
  }
  return out;
}

/** แถวตารางสรุป: (ผู้ถือ, รหัสบัญชี) → เลขแถว — หาจากเนื้อหา ไม่ผูกกับเลขแถวตายตัว */
function gridOf(s: Sheet): Map<string, number> {
  const out = new Map<string, number>();
  for (const [row] of s.rows) {
    if (row <= LAST_DATA_ROW) continue;
    const owner = str(s, row, "A");
    const code = String(cellAt(s, row, "B")?.value ?? "");
    if (OWNERS.includes(owner) && LINES.includes(code)) out.set(`${owner}|${code}`, row);
  }
  return out;
}

describe("เทมเพลตแจกแจงทรัพย์สิน", () => {
  it("เปิดอ่านได้ด้วยตัวอ่านของระบบ และมีชีทครบตามที่ตั้งใจ", () => {
    expect(load().sheets.map((s) => s.name)).toEqual(["อ่านก่อน", DETAIL]);
  });

  it("ชีท 'อ่านก่อน' ย้ำกฎห้ามเฉลี่ยต้นทุนข้ามชิ้น (D-117)", () => {
    const intro = sheetOf("อ่านก่อน");
    const text = [...intro.rows.values()]
      .flatMap((r) => [...r.values()].map((c) => (typeof c.value === "string" ? c.value : "")))
      .join("\n");
    expect(text).toContain("ห้ามเฉลี่ยข้ามชิ้น");
    expect(text).toContain("D-117");
    expect(text).toContain("คนละห้องก็แยก");
    expect(text).toContain(DETAIL); // บอกว่าไปกรอกที่ชีทไหน
  });

  it("หัวตารางตรงกับที่ลูกพี่ขอ ทุกคอลัมน์ ตามลำดับ", () => {
    const s = sheetOf(DETAIL);
    expect("ABCDEFG".split("").map((c) => str(s, 4, c))).toEqual([
      "ถือในชื่อ *",
      "รหัสทรัพย์",
      "ชื่อทรัพย์ *",
      "บรรทัดในงบดุล *",
      "ต้นทุน *",
      "ค่ารีโนเวทสะสม",
      "หมายเหตุ",
    ]);
  });

  it("ตัวอย่าง 2 คอนโดของธนากร 3,000,000 + 5,000,000 → รวม 8,000,000", () => {
    const s = sheetOf(DETAIL);
    const items = itemsOf(s);
    expect(items).toHaveLength(2);
    expect(items.map((i) => i.owner)).toEqual(["ธนากร", "ธนากร"]);
    expect(items.map((i) => i.code)).toEqual(["1500", "1500"]);
    expect(items.map((i) => i.cost)).toEqual([3_000_000, 5_000_000]);
    expect(items.reduce((a, i) => a + i.cost, 0)).toBe(8_000_000);

    // คอนโดสองห้องต้องเป็นสองชิ้นที่แยกจากกัน (D-117) ไม่ใช่บรรทัดเดียวยอดรวม
    expect(new Set(items.map((i) => i.name)).size).toBe(2);
  });

  it("ตารางสรุปให้ 'ธนากร · 1500 · 2 รายการ · 8,000,000' และเป็นช่องสูตร (Excel คำนวณใหม่ได้)", () => {
    const s = sheetOf(DETAIL);
    const row = gridOf(s).get("ธนากร|1500");
    expect(row).toBeDefined();
    expect(str(s, row!, "C")).toBe("อสังหาริมทรัพย์เพื่อการลงทุน");
    expect(num(s, row!, "D")).toBe(2); // จำนวนรายการ
    expect(num(s, row!, "E")).toBe(8_000_000); // รวมต้นทุน
    expect(num(s, row!, "G")).toBe(8_000_000); // ยอดที่ไปลงบัญชี 1500
    expect(cellAt(s, row!, "D")?.formula).toBe(true);
    expect(cellAt(s, row!, "E")?.formula).toBe(true);
    expect(cellAt(s, row!, "G")?.formula).toBe(true);
  });

  it("ค่ารีโนเวทไม่ปนกับต้นทุนทรัพย์ — ไหลไปบรรทัด 1510 แยก", () => {
    const s = sheetOf(DETAIL);
    const g = gridOf(s);
    expect(num(s, g.get("ธนากร|1500")!, "F")).toBe(500_000); // โชว์ว่ามาจากทรัพย์ชิ้นไหน
    expect(num(s, g.get("ธนากร|1510")!, "G")).toBe(500_000); // แต่ไปลงบัญชี 1510
    expect(num(s, g.get("ธนากร|1500")!, "G")).toBe(8_000_000); // ต้นทุน 1500 ไม่บวกค่ารีโนเวท
  });

  it("ยอดรวมทุกช่องในตารางสรุปตรงกับที่บวกเองจากบรรทัดทรัพย์ (ไม่มียอดตกหล่น ไม่มีนับซ้ำ)", () => {
    const s = sheetOf(DETAIL);
    const items = itemsOf(s);
    const grid = gridOf(s);
    expect(grid.size).toBe(OWNERS.length * LINES.length); // ครบทุกช่องของตาราง ผู้ถือ × บรรทัด

    for (const owner of OWNERS) {
      for (const code of LINES) {
        const row = grid.get(`${owner}|${code}`)!;
        const mine = items.filter((i) => i.owner === owner && i.code === code);
        const cost = mine.reduce((a, i) => a + i.cost, 0);
        const reno = mine.reduce((a, i) => a + i.reno, 0);
        expect(num(s, row, "D")).toBe(mine.length);
        expect(num(s, row, "E")).toBe(cost);
        expect(num(s, row, "F")).toBe(reno);
        const posted =
          code === "1510"
            ? cost + items.filter((i) => i.owner === owner).reduce((a, i) => a + i.reno, 0)
            : cost;
        expect(num(s, row, "G")).toBe(posted);
      }
    }

    // ทุกบรรทัดทรัพย์ต้องตกในช่องใดช่องหนึ่งของตารางสรุป ไม่มีผู้ถือ/รหัสที่ตารางจับไม่ได้
    for (const i of items) expect(grid.has(`${i.owner}|${i.code}`)).toBe(true);

    // ผลรวมทั้งไฟล์: ต้นทุนรวมของบรรทัดทรัพย์ = ผลรวมคอลัมน์ 'รวมต้นทุน' ของตารางสรุป
    const gridCost = [...grid.values()].reduce((a, row) => a + num(s, row, "E"), 0);
    expect(gridCost).toBe(items.reduce((a, i) => a + i.cost, 0));
  });

  it("ช่องตรวจเป็น 0 ทุกช่อง และผลต่างกับยอดในงบดุลโชว์เป็นตัวเลข ไม่ซ่อน", () => {
    const s = sheetOf(DETAIL);
    const grid = gridOf(s);
    const lastGrid = Math.max(...grid.values());

    // ยอดที่กรอกว่าอยู่ในงบดุล (ตัวอย่าง) ตรงกับยอดรวมที่คำนวณได้ → ผลต่าง 0 · สถานะ "ตรงกัน"
    for (const row of grid.values()) {
      expect(num(s, row, "I")).toBe(0);
      expect(str(s, row, "J")).toBe("ตรงกัน");
      expect(cellAt(s, row, "I")?.formula).toBe(true);
      expect(cellAt(s, row, "J")?.formula).toBe(true);
    }
    expect(num(s, grid.get("ธนากร|1500")!, "H")).toBe(8_000_000);
    expect(num(s, grid.get("ธนากร|1510")!, "H")).toBe(500_000);

    // บล็อกช่องตรวจอยู่ใต้ตารางสรุป: ป้ายกำกับใน A · ค่าที่คำนวณใน E · ต้องเป็น 0 ทุกช่อง
    const checks: number[] = [];
    for (const [row] of s.rows) {
      if (row <= lastGrid) continue;
      const label = str(s, row, "A");
      const cell = cellAt(s, row, "E");
      if (label && cell?.formula) checks.push(num(s, row, "E"));
    }
    expect(checks.length).toBeGreaterThanOrEqual(8);
    expect(checks.every((v) => v === 0)).toBe(true);
  });
});
