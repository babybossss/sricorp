import { describe, expect, it } from "vitest";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";

/**
 * ด่านกันการปัด/cast กลับเป็นสองตำแหน่งในเส้นทางคำนวณ (ADR 0003 ข้อ 4.2 + 4.2.1)
 *
 * ปัดยอดที่ปันส่วนแล้วได้ **ที่เดียว** คือ `display.ts` · ทุกไฟล์อื่นของ `src/lib/tags` และ server action
 * ที่คุยกับ DB ห้ามมีการปัด/แปลงเป็นข้อความทศนิยมคงที่/float parse เลย
 * เทสต์นี้อ่านซอร์สจริง (ไม่พึ่งความจำของคนที่แก้ครั้งถัดไป) และพังถ้าหาไฟล์ที่ต้องตรวจไม่เจอ (ไม่ผ่านด้วยชุดว่าง)
 */
const libDir = path.resolve(__dirname, "..");
const actionFile = path.resolve(__dirname, "../../../app/actions/tags.ts");
const ALLOWED_ROUNDING = new Set(["display.ts"]);

const strip = (src: string) => src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:"'`])\/\/.*$/gm, "$1");

const files = [
  ...readdirSync(libDir)
    .filter((f) => /\.ts$/.test(f))
    .map((f) => ({ name: `src/lib/tags/${f}`, base: f, code: strip(readFileSync(path.join(libDir, f), "utf8")) })),
  { name: "src/app/actions/tags.ts", base: "tags.ts", code: strip(readFileSync(actionFile, "utf8")) },
];

const ROUNDING = /\.toFixed\s*\(|\.toPrecision\s*\(|\bMath\.(round|floor|ceil|trunc)\s*\(|\.toLocaleString\s*\(|\bIntl\.|\bparseFloat\s*\(|\bNumber\.parseFloat\s*\(/;
const CAST_2DP = /numeric\s*\(\s*18\s*,\s*2\s*\)|::\s*numeric\s*\(\s*\d+\s*,\s*2\s*\)|round\s*\(\s*[^)]*,\s*2\s*\)/i;

describe("ไม่มีการปัดในเส้นทางคำนวณ", () => {
  it("พบไฟล์ที่ต้องตรวจครบ (กันผ่านด้วยชุดว่าง)", () => {
    const names = files.map((f) => f.name);
    expect(names).toEqual(expect.arrayContaining([
      "src/lib/tags/allocation.ts",
      "src/lib/tags/weights.ts",
      "src/lib/tags/decimal.ts",
      "src/lib/tags/display.ts",
      "src/lib/tags/selection.ts",
      "src/app/actions/tags.ts",
    ]));
  });

  it("ทุกไฟล์ยกเว้น display.ts ไม่มี toFixed / Math.round|floor|ceil|trunc / toLocaleString / Intl / parseFloat", () => {
    for (const f of files.filter((x) => !ALLOWED_ROUNDING.has(x.base))) {
      expect(f.code, f.name).not.toMatch(ROUNDING);
    }
  });

  it("ไม่มีไฟล์ไหนเลย cast เป็นสองตำแหน่ง (numeric(18,2) / ::numeric(n,2) / round(x,2))", () => {
    for (const f of files) expect(f.code, f.name).not.toMatch(CAST_2DP);
  });

  it("display.ts เป็นที่เดียวที่ปัด และไม่ปัดด้วย float (ใช้ bigint)", () => {
    const d = files.find((f) => f.base === "display.ts")!;
    expect(d.code).not.toMatch(/\.toFixed\s*\(|\bMath\.(round|ceil|trunc)\s*\(/);
    expect(d.code).toMatch(/bigint/);
  });

  it("ด่านจับได้จริง: ตัวอย่างซอร์สที่ปัดต้องโดน regex", () => {
    for (const bad of ["x.toFixed(2)", "Math.round(a*w*100)/100", "v::numeric(18,2)", "round(amount * w, 2)", "n.toLocaleString('en-US')"]) {
      expect(ROUNDING.test(bad) || CAST_2DP.test(bad), bad).toBe(true);
    }
  });
});
