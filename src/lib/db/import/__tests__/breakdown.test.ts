/**
 * ชีท "แจกแจงทรัพย์" ในตัวนำเข้ายอดตั้งต้น — อ่าน · กระทบยอดกับ BS-* · ปฏิเสธ
 *
 * หัวใจ (mace-windu ข้อ 3): เทสต์ที่ส่งข้อมูลครบเสมอจะไม่มีวันแตะเส้นทางที่ข้อมูลขาด จึงเขียนเคส "ไม่ส่ง" ครบ —
 * ไม่มีชีท · มียอดแต่ไม่มีบรรทัดทรัพย์ · มีทรัพย์แต่ไม่มียอด · ต่างกันแค่ 1 สตางค์
 */
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fingerprintOf, parseOpeningWorkbook, type ImportIssue, type ParsedOpening } from "../opening";
import { BREAKDOWN_CODES, BREAKDOWN_SHEET, RENOVATION_COA, readBreakdown, assetCategoryOfCoa } from "../breakdown";
import { readWorkbook, type Workbook } from "../xlsx";
import { breakdownRowsFromBs, ctxOf, loadFixture, setBreakdown, setCell, sheetOf, syncBreakdown, type BreakdownRow } from "./helpers";
import { setByCode } from "./post-helpers";
import { COA } from "@/lib/rules/coa";
import { ASSET_CLASSES, UNCLASSIFIED_ASSET_COA } from "@/lib/rules/asset-classes";

const TK = "BS-ธนากร";
const ok = (wb: Workbook, breakdown?: Workbook | null): ParsedOpening => {
  const r = parseOpeningWorkbook(wb, ctxOf(), breakdown);
  if (!r.ok) throw new Error("ควรผ่านแต่ถูกปฏิเสธ:\n" + r.issues.map((i) => `${i.sheet}#${i.row ?? "-"} ${i.message}`).join("\n"));
  return r.parsed;
};
const bad = (wb: Workbook, breakdown?: Workbook | null): ImportIssue[] => {
  const r = parseOpeningWorkbook(wb, ctxOf(), breakdown);
  if (r.ok) throw new Error("ควรถูกปฏิเสธแต่ผ่าน");
  return r.issues;
};

const CONDOS: BreakdownRow[] = [
  { owner: "ธนากร", code: "CONDO-A", name: "คอนโด ลุมพินี ห้อง 1203", line: "1500", cost: 3_000_000 },
  { owner: "ธนากร", code: "CONDO-B", name: "คอนโด ลุมพินี ห้อง 1507", line: "1500", cost: 5_000_000, reno: 500_000 },
];
/** แก้ยอดบรรทัดหนึ่งของชีท BS- แล้วปรับกำไรสะสม 3300 ให้งบดุลยังลงตัว (ไม่ให้ปัญหา "งบดุลไม่ลงตัว" มาปนกับสิ่งที่เทสต์วัด) */
function getByCode(wb: Workbook, sheet: string, code: string): number {
  for (const cells of sheetOf(wb, sheet).rows.values()) if (String(cells.get("A")?.value ?? "") === code) return Number(cells.get("E")?.value ?? 0);
  throw new Error(`ไม่พบรหัส ${code}`);
}
function setBalanced(wb: Workbook, sheet: string, code: string, amount: number | null) {
  const before = getByCode(wb, sheet, code);
  setByCode(wb, sheet, code, amount);
  setByCode(wb, sheet, "3300", getByCode(wb, sheet, "3300") + ((amount ?? 0) - before));
}

describe("ไฟล์ที่ทรัพย์รายชิ้นกระทบยอดกับงบดุลพอดี", () => {
  it("ไฟล์ตัวอย่าง (เติมชีทแจกแจงจาก BS) ผ่าน · ได้ทรัพย์รายชิ้นครบ ต้นทุนรายชิ้น", () => {
    const p = ok(loadFixture());
    expect(p.assetItems.map((i) => [i.ownerName, i.coaCode, i.cost]).sort()).toEqual(
      [
        ["SRI Corporation", "1400", 1_000_000],
        ["SRI Corporation", "1500", 5_000_000],
        ["ธนากร", "1500", 3_000_000],
      ].sort()
    );
  });

  it("คอนโดสองห้อง 3,000,000 + 5,000,000 (+รีโนเวท 500,000) กระทบกับ BS 1500 = 8,000,000 และ 1510 = 500,000 → ผ่าน · ห้องไหนต้นทุนห้องนั้น", () => {
    const r = parseOpeningWorkbook(balancedCondo(), ctxOf());
    expect(r.ok, r.ok ? "" : JSON.stringify(r.issues)).toBe(true);
    if (!r.ok) return;
    const items = r.parsed.assetItems.filter((i) => i.ownerName === "ธนากร");
    expect(items.map((i) => [i.name, i.cost, i.renovation, i.assetCode])).toEqual([
      ["คอนโด ลุมพินี ห้อง 1203", 3_000_000, 0, "CONDO-A"],
      ["คอนโด ลุมพินี ห้อง 1507", 5_000_000, 500_000, "CONDO-B"],
    ]);
  });
});

/** ธนากร: 1500 = 8,000,000 · 1510 = 500,000 · ที่เหลือคงเดิม (ปรับทุนให้ดุล) แล้วใส่ชีทแจกแจงคอนโดสองห้อง */
function balancedCondo(rows: BreakdownRow[] = CONDOS, over: { c1500?: number; c1510?: number } = {}): Workbook {
  const wb = loadFixture();
  const c1500 = over.c1500 ?? 8_000_000;
  const c1510 = over.c1510 ?? 500_000;
  setBalanced(wb, TK, "1500", c1500);
  setBalanced(wb, TK, "1510", c1510);
  // ผู้ถือคนอื่นคงเดิม → เติมชีทให้ตรง BS ของคนอื่น แล้วแทนที่แถวของธนากรด้วยทรัพย์ที่ทดสอบ
  const others = breakdownRowsOfOthers(wb);
  return setBreakdown(wb, [...others, ...rows]);
}
function breakdownRowsOfOthers(wb: Workbook): BreakdownRow[] {
  const all = syncBreakdown(structuredClone(wb));
  const sheet = all.sheets.find((s) => s.name === BREAKDOWN_SHEET)!;
  const out: BreakdownRow[] = [];
  for (const [r, cells] of [...sheet.rows].sort((a, b) => a[0] - b[0])) {
    if (r < 6 || r >= 207) continue;
    const owner = String(cells.get("A")?.value ?? "");
    if (!owner || owner === "ธนากร") continue;
    out.push({ owner, name: String(cells.get("C")?.value), line: String(cells.get("D")?.value), cost: Number(cells.get("E")?.value) });
  }
  return out;
}


describe("ปฏิเสธทั้งไฟล์เมื่อไม่กระทบยอด · ต้องบอกว่าต่างกันที่ช่องไหน เท่าไร", () => {
  it("ผลบวกทรัพย์ต่างจากงบดุล 1 สตางค์ → ปฏิเสธ · ชี้ชีท BS- แถวของ 1500 · บอกทั้งสองยอดและผลต่าง", () => {
    const wb = balancedCondo(CONDOS, { c1500: 8_000_000 });
    // งบดุลบอก 8,000,000.01 แต่ทรัพย์รวม 8,000,000
    setBalanced(wb, TK, "1500", 8_000_000.01);
    const issues = bad(wb);
    const i = issues.find((x) => x.sheet === TK && /1500/.test(x.message) && /ทรัพย์/.test(x.message));
    expect(i, JSON.stringify(issues)).toBeDefined();
    expect(i!.row).toBeGreaterThan(0);
    expect(i!.message).toContain("8,000,000.01");
    expect(i!.message).toContain("8,000,000 ");
    expect(i!.message).toMatch(/ต่างกัน 0\.01/);
    expect(i!.message).toMatch(/แถว 7, 8|แถว 6, 7|แถว/);
    expect(i!.message).toMatch(/ไม่เฉลี่ย ไม่ปัดให้ลง และไม่ลงบรรทัดส่วนต่าง/);
  });

  it("ยอดต่างกันมาก (ห้อง B ต้นทุนผิด 5,000,000 → 4,000,000) → ปฏิเสธ บอกผลต่าง 1,000,000 · ไม่มีทางผ่านด้วยการเฉลี่ย", () => {
    const rows = CONDOS.map((r) => (r.code === "CONDO-B" ? { ...r, cost: 4_000_000 } : r));
    const issues = bad(balancedCondo(rows));
    const i = issues.find((x) => x.sheet === TK && /1500/.test(x.message))!;
    expect(i.message).toMatch(/ต่างกัน 1,000,000/);
    expect(i.message).toContain("7,000,000"); // ที่ทรัพย์รวมได้
    expect(i.message).toContain("8,000,000"); // ที่งบดุลบอก
  });

  it("ค่ารีโนเวทไม่ตรง 1510 → ปฏิเสธที่ 1510 (ผลบวกคอลัมน์ F ทุกชิ้น + ต้นทุนของบรรทัดที่เลือก 1510)", () => {
    const issues = bad(balancedCondo(CONDOS, { c1510: 400_000 }));
    const i = issues.find((x) => x.sheet === TK && /1510/.test(x.message))!;
    expect(i.message).toContain("400,000");
    expect(i.message).toContain("500,000");
    expect(i.message).toMatch(/ค่ารีโนเวทสะสมของทุกชิ้น/);
  });

  it("งบดุลมียอดแต่ไม่มีบรรทัดทรัพย์เลย → ปฏิเสธ (ไม่ลงเป็นยอดรวม · ไม่งั้นได้ทรัพย์ที่ขายไม่ออก)", () => {
    const wb = balancedCondo([]);
    const issues = bad(wb);
    const i = issues.find((x) => x.sheet === TK && /1500/.test(x.message))!;
    expect(i.message).toMatch(/ไม่มีทรัพย์ของ ธนากร ในบรรทัดนี้เลย/);
    expect(i.message).toMatch(/ขายออกไม่ได้/);
  });

  it("มีทรัพย์แต่งบดุลไม่มียอดบรรทัดนั้น → ปฏิเสธเหมือนกัน (ยอดจะหายเงียบๆ ถ้าปล่อย)", () => {
    const wb = balancedCondo(CONDOS);
    setBalanced(wb, TK, "1500", null);
    expect(bad(wb).some((x) => x.sheet === TK && /1500/.test(x.message) && /ต่างกัน/.test(x.message))).toBe(true);
  });

  it("ปฏิเสธเงียบ ไม่ได้: บอกทุกช่องที่ไม่ตรงในครั้งเดียว (1500 และ 1510 พร้อมกัน)", () => {
    const issues = bad(balancedCondo([], { c1500: 8_000_000, c1510: 500_000 }));
    expect(issues.filter((x) => x.sheet === TK && /ทรัพย์/.test(x.message)).map((x) => /^(\d{4})/.exec(x.message)![1]).sort()).toEqual(["1500", "1510"]);
  });
});

describe("1600 เงินมัดจำจ่าย (ไม่มีหมวดทรัพย์): ยังกระทบยอดเหมือนเดิม", () => {
  const deposits: BreakdownRow[] = [
    { owner: "ธนากร", name: "ค่ามัดจำสำนักงาน", line: "1600", cost: 30_000 },
    { owner: "ธนากร", name: "ค่ามัดจำไฟฟ้า", line: "1600", cost: 20_000 },
  ];
  const withDeposit = (bs: number) => {
    const wb = loadFixture();
    setBalanced(wb, TK, "1600", bs);
    return setBreakdown(wb, [...breakdownRowsFromBs(wb).filter((x) => !(x.owner === "ธนากร" && x.line === "1600")), ...deposits]);
  };
  it("กระทบพอดี (30,000 + 20,000 = 50,000) → ผ่าน รับแถวแจกแจงทั้งสอง", () => {
    expect(ok(withDeposit(50_000)).assetItems.filter((i) => i.coaCode === "1600")).toHaveLength(2);
  });
  it("ไม่กระทบ (BS 50,001) → ปฏิเสธด้วยข้อความเดิม บอกผลต่าง", () => {
    const i = bad(withDeposit(50_001)).find((x) => x.sheet === TK && /1600/.test(x.message))!;
    expect(i.message).toMatch(/50,001/);
    expect(i.message).toMatch(/ต่างกัน 1/);
  });
});

describe("ไม่มีชีทแจกแจง → ปฏิเสธ (ไม่ตกไปเส้นทางบรรทัดรวม)", () => {
  it("ไฟล์ที่ไม่มีชีท 'แจกแจงทรัพย์' และไม่แนบไฟล์แยก → ปฏิเสธทั้งไฟล์ ทั้งที่ข้อมูลอื่นครบและงบดุลลงตัว", () => {
    const wb = loadFixture();
    wb.sheets = wb.sheets.filter((s) => s.name !== BREAKDOWN_SHEET);
    const issues = bad(wb);
    expect(issues).toHaveLength(1);
    expect(issues[0].message).toContain(BREAKDOWN_SHEET);
    expect(issues[0].message).toMatch(/ไฟล์ยอดตั้งต้น หรือแนบไฟล์/);
    expect(issues[0].message).toMatch(/ขายออกไม่ได้/);
  });

  it("ชีทมีแต่หัวตาราง (ว่าง) ผ่านได้เมื่องบดุลไม่มียอดในบรรทัดที่ต้องแจกแจง · แต่ถ้า BS มียอดต้องปฏิเสธ", () => {
    const wb = loadFixture();
    for (const code of ["1400", "1500"]) setBalanced(wb, "BS-SRI Corporation", code, null);
    setBalanced(wb, "BS-ธนากร", "1500", null);
    expect(parseOpeningWorkbook(syncBreakdown(wb), ctxOf()).ok).toBe(true);
    // เติมยอดกลับโดยไม่เติมทรัพย์ (ชีทแจกแจงยังเป็นชุดว่าง)
    const wb2 = syncBreakdown(structuredClone(wb));
    setBalanced(wb2, "BS-ธนากร", "1500", 3_000_000);
    expect(bad(wb2).some((i) => i.sheet === "BS-ธนากร" && /ไม่มีทรัพย์ของ ธนากร/.test(i.message))).toBe(true);
  });
});

describe("ชีทแจกแจงในไฟล์เดียวกัน หรือไฟล์แยก (รับได้ทั้งสองแบบ · ต้องมีทางเดียว)", () => {
  const sheetOnly = (wb: Workbook): Workbook => ({ sheets: wb.sheets.filter((s) => s.name === BREAKDOWN_SHEET) });
  const withoutSheet = (wb: Workbook): Workbook => ({ sheets: wb.sheets.filter((s) => s.name !== BREAKDOWN_SHEET) });

  it("ไฟล์แยก: ไฟล์ยอดตั้งต้นไม่มีชีท + ไฟล์แจกแจงแนบมา → ผ่าน ผลเท่ากับใส่ชีทในไฟล์เดียวกัน", () => {
    const one = loadFixture();
    const together = ok(one);
    const separate = ok(withoutSheet(one), sheetOnly(one));
    expect(separate.assetItems).toEqual(together.assetItems);
    expect(fingerprintOf(separate)).toBe(fingerprintOf(together));
  });

  it("ไฟล์แยกที่มี ปัญหาบอกว่าอยู่ที่ 'ไฟล์แจกแจงทรัพย์ที่แนบแยก' ไม่ใช่ไฟล์ยอดตั้งต้น", () => {
    const one = loadFixture();
    const sep = sheetOnly(one);
    setCell(sep, BREAKDOWN_SHEET, 6, "E", 0);
    const issues = bad(withoutSheet(one), sep);
    expect(issues.some((i) => i.sheet.includes("ไฟล์แจกแจงทรัพย์ที่แนบแยก") && i.row === 6)).toBe(true);
  });

  it("มีชีททั้งสองที่ → ปฏิเสธ ไม่เลือกข้างให้ (สองชุดอาจไม่เหมือนกัน)", () => {
    const one = loadFixture();
    const issues = bad(one, sheetOnly(one));
    expect(issues).toHaveLength(1);
    expect(issues[0].message).toMatch(/ทั้งในไฟล์ยอดตั้งต้นและในไฟล์แจกแจงที่แนบแยก/);
  });

  it("แนบไฟล์แยกแต่ไฟล์นั้นไม่มีชีทแจกแจง → ปฏิเสธ (ไม่ตกไปใช้ชีทในไฟล์หลัก)", () => {
    const one = loadFixture();
    const issues = bad(one, withoutSheet(loadFixture()));
    expect(issues.some((i) => /ไฟล์แจกแจงทรัพย์ที่แนบไม่มีชีท/.test(i.message))).toBe(true);
  });

  it("ไม่มีทั้งสองที่ → ปฏิเสธ", () => {
    expect(bad(withoutSheet(loadFixture()), null).some((i) => /ไม่พบชีท "แจกแจงทรัพย์"/.test(i.message))).toBe(true);
  });
});

describe("อ่านบรรทัดทรัพย์: ตรวจทุกช่อง รวบรวมความผิดทั้งหมด", () => {
  const read = (rows: BreakdownRow[]) => {
    const wb = setBreakdown(loadFixture(), rows);
    const issues: ImportIssue[] = [];
    const owners = new Map(ctxOf().owners.map((o) => [o.name, o]));
    const items = readBreakdown(sheetOf(wb, BREAKDOWN_SHEET), BREAKDOWN_SHEET, owners, issues);
    return { items, issues };
  };
  const row = (over: Partial<BreakdownRow> = {}): BreakdownRow => ({ owner: "ธนากร", name: "คอนโด X", line: "1500", cost: 1_000_000, ...over });

  it("แถวคำอธิบายใต้หัวตารางและตารางสรุปอัตโนมัติ (สูตร) ไม่ถูกอ่านเป็นทรัพย์", () => {
    const { items, issues } = read([row()]);
    expect(issues).toEqual([]);
    expect(items).toHaveLength(1);
  });

  it.each([
    ["ผู้ถือไม่รู้จัก", row({ owner: "ใครสักคน" }), /ไม่ตรงกับผู้ถือคนใด/],
    ["ไม่มีชื่อทรัพย์", row({ name: "" }), /ไม่ได้ระบุชื่อทรัพย์/],
    ["บรรทัดงบดุลที่ไม่ต้องแจกแจง (เงินสด 1100)", row({ line: "1100" }), /ไม่ใช่บรรทัดที่แจกแจงรายชิ้น/],
    ["บรรทัดงบดุลว่าง", row({ line: "" }), /ไม่ใช่บรรทัดที่แจกแจงรายชิ้น/],
    ["ต้นทุนเป็น 0", row({ cost: 0 }), /ต้นทุนต้องมากกว่า 0/],
    ["ต้นทุนติดลบ", row({ cost: -5 }), /ต้นทุนต้องมากกว่า 0/],
    ["ค่ารีโนเวทติดลบ", row({ reno: -1 }), /ติดลบไม่ได้/],
    ["ค่ารีโนเวทในทรัพย์ที่ไม่ใช่อสังหาฯ (เงินให้กู้ 1300)", row({ line: "1300", reno: 10 }), /เฉพาะทรัพย์ที่เป็นอสังหาฯ/],
    ["แถวตัวอย่างของเทมเพลตที่ลืมลบ", row({ note: "ตัวอย่าง — ลบได้" }), /แถวนี้เป็นตัวอย่างในเทมเพลต/],
  ])("%s → ปฏิเสธพร้อมเลขแถว", (_n, r, re) => {
    const { items, issues } = read([r]);
    expect(items).toEqual([]);
    expect(issues).toHaveLength(1);
    expect(issues[0].row).toBe(6);
    expect(issues[0].message).toMatch(re);
  });

  it("ต้นทุนว่าง → ปฏิเสธ (ทรัพย์ทุกชิ้นต้องมีต้นทุนของตัวเอง)", () => {
    const wb = setBreakdown(loadFixture(), [row()]);
    setCell(wb, BREAKDOWN_SHEET, 6, "E", null);
    const issues: ImportIssue[] = [];
    readBreakdown(sheetOf(wb, BREAKDOWN_SHEET), BREAKDOWN_SHEET, new Map(ctxOf().owners.map((o) => [o.name, o])), issues);
    expect(issues.map((i) => i.message).join()).toMatch(/ต้นทุนว่าง/);
  });

  it("ต้นทุนเป็นสูตร Excel → ไม่เชื่อ (ยอดต้องเป็นตัวเลขที่กรอกเอง)", () => {
    const wb = setBreakdown(loadFixture(), [row()]);
    setCell(wb, BREAKDOWN_SHEET, 6, "E", 1_000_000, true);
    const issues: ImportIssue[] = [];
    readBreakdown(sheetOf(wb, BREAKDOWN_SHEET), BREAKDOWN_SHEET, new Map(ctxOf().owners.map((o) => [o.name, o])), issues);
    expect(issues.map((i) => i.message).join()).toMatch(/เป็นสูตร/);
  });

  it("ชื่อทรัพย์ซ้ำของผู้ถือเดียวกัน → ปฏิเสธ ชี้แถวแรก · คนละผู้ถือชื่อเดียวกันได้", () => {
    const { issues } = read([row({ name: "คอนโด X" }), row({ name: "  คอนโด  X " })]);
    expect(issues).toHaveLength(1);
    expect(issues[0].row).toBe(7);
    expect(issues[0].message).toMatch(/ซ้ำกับแถว 6/);
    expect(read([row(), row({ owner: "สุธี" })]).issues).toEqual([]);
  });

  it("รหัสทรัพย์ซ้ำของผู้ถือเดียวกัน → ปฏิเสธ", () => {
    const { issues } = read([row({ code: "A1", name: "ห้อง 1" }), row({ code: "a1", name: "ห้อง 2" })]);
    expect(issues).toHaveLength(1);
    expect(issues[0].message).toMatch(/รหัสทรัพย์ "a1".*ซ้ำกับแถว 6/);
  });

  it("บรรทัดงบดุลเป็นตัวเลขใน Excel (1500 ไม่ใช่ข้อความ) ก็อ่านได้", () => {
    const wb = setBreakdown(loadFixture(), [row()]);
    setCell(wb, BREAKDOWN_SHEET, 6, "D", 1500);
    const issues: ImportIssue[] = [];
    const items = readBreakdown(sheetOf(wb, BREAKDOWN_SHEET), BREAKDOWN_SHEET, new Map(ctxOf().owners.map((o) => [o.name, o])), issues);
    expect(issues).toEqual([]);
    expect(items[0].coaCode).toBe("1500");
  });

  it("แถวที่ผู้ถือผิดและต้นทุนผิดพร้อมกัน → รายงานทั้งสองในแถวเดียว (ไม่หยุดที่ความผิดแรก)", () => {
    const { issues } = read([row({ owner: "ใครสักคน", cost: 0 })]);
    expect(issues.length).toBe(2);
  });
});

describe("ลายนิ้วมือ: ทรัพย์รายชิ้นเป็นส่วนหนึ่งของเนื้อหา", () => {
  it("ยอดรวมเท่ากันแต่แบ่งต้นทุนคนละแบบ (3M+5M กับ 4M+4M) → รหัสตรวจต้องต่างกัน ไม่งั้นอัปโหลดแก้การแบ่งแล้วระบบเห็นว่าไม่เปลี่ยน", () => {
    const a = ok(balancedCondo(CONDOS));
    const b = ok(
      balancedCondo([
        { owner: "ธนากร", code: "CONDO-A", name: "คอนโด ลุมพินี ห้อง 1203", line: "1500", cost: 4_000_000 },
        { owner: "ธนากร", code: "CONDO-B", name: "คอนโด ลุมพินี ห้อง 1507", line: "1500", cost: 4_000_000, reno: 500_000 },
      ])
    );
    expect(fingerprintOf(a)).not.toBe(fingerprintOf(b));
  });

  it("สลับลำดับแถว / แก้หมายเหตุ / เลื่อนแถว → รหัสตรวจเดิม (เนื้อหาเหมือนเดิม)", () => {
    const a = ok(balancedCondo(CONDOS));
    const b = ok(balancedCondo([{ ...CONDOS[1], note: "แก้หมายเหตุ" }, CONDOS[0]]));
    expect(fingerprintOf(a)).toBe(fingerprintOf(b));
  });
});

describe("เทมเพลตจริง templates/SRI_OS_3_แจกแจงทรัพย์สิน.xlsx", () => {
  const TEMPLATE = path.join(__dirname, "..", "..", "..", "..", "..", "templates", "SRI_OS_3_แจกแจงทรัพย์สิน.xlsx");

  it("ตัวอ่านอ่านเทมเพลตจริงได้: แถวตัวอย่าง 2 แถวถูกจับว่าเป็นตัวอย่าง (ลืมลบแล้วไม่หลุดเข้าสมุด) · ตารางสรุปและแถวคำอธิบายไม่ถูกนับ", () => {
    const wb = readWorkbook(readFileSync(TEMPLATE));
    const issues: ImportIssue[] = [];
    const items = readBreakdown(sheetOf(wb, BREAKDOWN_SHEET), BREAKDOWN_SHEET, new Map(ctxOf().owners.map((o) => [o.name, o])), issues);
    expect(items).toEqual([]);
    expect(issues.map((i) => i.row)).toEqual([6, 7]);
    expect(issues.every((i) => /แถวนี้เป็นตัวอย่างในเทมเพลต/.test(i.message))).toBe(true);
  });

  it("เทมเพลตจริงที่ลบแถวตัวอย่างแล้วกรอกจริง (คอนโดสองห้อง) อ่านได้ครบ รวมรหัสทรัพย์ ต้นทุน รีโนเวท", () => {
    const wb = readWorkbook(readFileSync(TEMPLATE));
    setCell(wb, BREAKDOWN_SHEET, 6, "G", "");
    setCell(wb, BREAKDOWN_SHEET, 7, "G", "");
    const issues: ImportIssue[] = [];
    const items = readBreakdown(sheetOf(wb, BREAKDOWN_SHEET), BREAKDOWN_SHEET, new Map(ctxOf().owners.map((o) => [o.name, o])), issues);
    expect(issues).toEqual([]);
    expect(items.map((i) => [i.ownerName, i.assetCode, i.name, i.coaCode, i.cost, i.renovation])).toEqual([
      ["ธนากร", "CONDO-A", "คอนโด ลุมพินี ห้อง 1203", "1500", 3_000_000, 0],
      ["ธนากร", "CONDO-B", "คอนโด ลุมพินี ห้อง 1507", "1500", 5_000_000, 500_000],
    ]);
  });
});

describe("รายการบรรทัดที่ต้องแจกแจง (BREAKDOWN_CODES) ตรงกับเทมเพลต และมีหมวดทรัพย์รองรับ", () => {
  it("ตรงกับ LINES ใน scripts/make-breakdown-template.py ตัวต่อตัว — เพิ่มบรรทัดในเทมเพลตแล้วลืมที่นี่ = แดง", () => {
    const py = readFileSync(path.join(__dirname, "..", "..", "..", "..", "..", "scripts", "make-breakdown-template.py"), "utf8");
    const block = /^LINES = \[([\s\S]*?)^\]/m.exec(py);
    expect(block, "หา LINES ในสคริปต์ไม่เจอ").not.toBeNull();
    const codes = [...block![1].matchAll(/\(\s*"(\d{4})"/g)].map((m) => m[1]);
    expect(codes.length).toBeGreaterThan(0);
    expect([...BREAKDOWN_CODES].sort()).toEqual([...codes].sort());
    // บรรทัดที่รับค่ารีโนเวทสะสมก็ต้องตรงกับเทมเพลตเช่นกัน
    expect(/^RENO_LINE = "(\d{4})"/m.exec(py)?.[1]).toBe(RENOVATION_COA);
    expect(BREAKDOWN_CODES).toContain(RENOVATION_COA);
  });

  it("ทุกบรรทัดเป็นบัญชีสินทรัพย์จริงในผังบัญชี", () => {
    for (const c of BREAKDOWN_CODES) expect(COA.find((a) => a.code === c)?.type, c).toBe("asset");
  });

  it("บัญชีที่มีหมวดทรัพย์ → สร้างทรัพย์ได้ · บัญชีที่ผังหมวดทรัพย์ตั้งใจไม่จัดหมวด (1600) → null (ผู้เรียกต้องปฏิเสธ ไม่เดาหมวด)", () => {
    const withCategory = BREAKDOWN_CODES.filter((c) => assetCategoryOfCoa(c) !== null);
    const without = BREAKDOWN_CODES.filter((c) => assetCategoryOfCoa(c) === null);
    // ที่ไม่มีหมวดต้องเป็นบัญชีที่ตารางหมวดทรัพย์ระบุไว้ว่าไม่ใช่การลงทุนเท่านั้น ไม่ใช่ตกหล่น
    for (const c of without) expect(c in UNCLASSIFIED_ASSET_COA, c).toBe(true);
    expect(withCategory.length + without.length).toBe(BREAKDOWN_CODES.length);
    expect(assetCategoryOfCoa("1500")).toBe("RE_RENTAL");
    expect(assetCategoryOfCoa("1520")).toBe("RE_FOR_SALE");
    expect(assetCategoryOfCoa("1510")).toBe("RE_RENTAL");
    expect(assetCategoryOfCoa("1400")).toBe("RE_SRR");
    expect(assetCategoryOfCoa("1300")).toBe("PAPER_LOAN");
    expect(assetCategoryOfCoa("1600")).toBeNull();
    // หมวดที่อ้างต้องมีจริงในตารางหมวดทรัพย์
    const codes = new Set(ASSET_CLASSES.flatMap((c) => c.categories.map((x) => x.code)));
    for (const c of withCategory) expect(codes.has(assetCategoryOfCoa(c)!)).toBe(true);
  });
});
