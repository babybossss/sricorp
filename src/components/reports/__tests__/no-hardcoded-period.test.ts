import { describe, expect, it } from "vitest";
import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";

/**
 * ด่านกัน "ป้ายงวดบนงบโกหก"
 *
 * เคยพลาดจริง: เพิ่มมุมมองรายเดือนแล้วตัวเลขถูกหมด แต่หัวงบยังเขียนตายตัวว่า
 *   งบดุล        "ณ วันที่ 31 ธ.ค. {year}"   ขณะตัวเลขเป็น ณ 28 ก.พ.
 *   งบกำไรขาดทุน "1 ม.ค. – 31 ธ.ค. {year}"
 *   งบกระแสเงินสด "เงินสดในงบ ณ 31 ธ.ค."
 * **งบดุลลงวันที่ผิด = เอกสารการเงินเท็จ** แม้ตัวเลขทุกตัวจะถูก
 *
 * ป้ายต้องอ่านจาก object ของงบเอง (`asOf` · `periodStart/End` · `periodLabel`)
 * ซึ่งมาจากการคำนวณชุดเดียวกัน ป้ายจึงหลุดจากตัวเลขไม่ได้
 */
const VIEWS = path.join(__dirname, "..");

/** คำที่บอก "งวด" แบบตายตัว — ห้ามมีในไฟล์หน้างบ */
const BANNED: { re: RegExp; why: string }[] = [
  { re: /31 ธ\.ค\./, why: "วันสิ้นปีเขียนตายตัว — ต้องใช้ asOf / periodEnd" },
  { re: /1 ม\.ค\./, why: "วันต้นปีเขียนตายตัว — ต้องใช้ periodStart" },
  { re: /สุทธิปี \$\{/, why: "ป้าย 'ปี' ตายตัว — ต้องใช้ periodLabel" },
  { re: /ต้นปี \$\{|ในปี \$\{|สิ้นปีคือ/, why: "ยกมา/เปลี่ยนแปลง/สิ้นงวด เขียนว่า 'ปี' ตายตัว" },
  { re: /อยู่คนละปี/, why: "คำอธิบายเงินสดระหว่างทางต้องเป็น 'คนละงวด'" },
];

describe("หน้างบห้ามเขียนงวดตายตัว", () => {
  const files = readdirSync(VIEWS)
    .filter((f) => f.endsWith(".tsx") && !statSync(path.join(VIEWS, f)).isDirectory())
    .map((f) => ({ f, src: readFileSync(path.join(VIEWS, f), "utf8") }));

  it("มีไฟล์หน้างบให้ตรวจจริง (กันด่านที่วนชุดว่างแล้วผ่าน)", () => {
    expect(files.map((x) => x.f)).toEqual(expect.arrayContaining(["balance-sheet-view.tsx", "profit-loss-view.tsx", "cash-flow-view.tsx"]));
  });

  it.each(BANNED)("ไม่มีไฟล์ไหนเขียน $why", ({ re }) => {
    // ตัดคอมเมนต์ก่อน ไม่งั้นคอมเมนต์ที่เล่าว่า "เคยเขียน 31 ธ.ค. ตายตัว" จะทำให้ด่านแดงเอง
    const bad = files
      .map((x) => ({ f: x.f, src: x.src.replace(/\{\/\*[\s\S]*?\*\/\}/g, "").replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "") }))
      .filter((x) => re.test(x.src))
      .map((x) => x.f);
    expect(bad).toEqual([]);
  });

  it("หน้างบทั้งสามใบอ่านงวดจาก object ของงบเอง", () => {
    const of = (f: string) => files.find((x) => x.f === f)!.src;
    expect(of("balance-sheet-view.tsx")).toMatch(/thaiDate\(bs\.asOf\)/);
    expect(of("profit-loss-view.tsx")).toMatch(/pl\.periodStart/);
    expect(of("profit-loss-view.tsx")).toMatch(/pl\.periodLabel/);
    expect(of("cash-flow-view.tsx")).toMatch(/cf\.periodStart/);
    expect(of("cash-flow-view.tsx")).toMatch(/cf\.periodEnd/);
  });
});
