import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import * as model from "../assets-model";

/**
 * ลูกพี่สั่ง 25/10: ห้ามแสดงต้นทุนเฉลี่ยของทรัพย์ทุกอย่าง ยกเว้น หุ้นในตลาด · คริปโต · ทองคำ
 * (หุ้นในตลาด/นอกตลาดใช้รหัสบัญชี 1700 เดียวกัน · ทองคำ/สินทรัพย์ทางเลือกใช้ 1720 เดียวกัน → รหัสบัญชีและ ticker ตัดสินไม่ได้
 *  ตัวแยกที่อ่านจากข้อมูลอ้างอิงยังไม่พร้อม)
 *
 * หน้าทรัพย์จึง **ไม่มีค่าเฉลี่ยเลยแม้แต่ช่องเดียว** ทุกชนิดทรัพย์ — เทสต์นี้ไล่ทั้งโค้ดของหน้า (ตัดคอมเมนต์ออกแล้ว
 * เหลือแต่ข้อความที่ผู้ใช้เห็นและโค้ดที่ทำงาน) แล้วแดงทันทีถ้ามีใครเติมคำพวกนี้เข้ามา
 * ตอนตัวแยกพร้อม ให้เพิ่มข้อยกเว้นเฉพาะไฟล์ที่ตัดสินจากข้อมูลอ้างอิง ไม่ใช่ลบเทสต์นี้
 */
const ROOT = path.resolve(__dirname, "../../../..");
const FORBIDDEN = /เฉลี่ย|ถัว|average|avg|\bmean\b|ต่อหน่วย|per[\s_-]?unit|unit[\s_-]?cost|weighted/i;

function walk(dir: string): string[] {
  return readdirSync(dir).flatMap((n) => {
    const p = path.join(dir, n);
    if (n === "__tests__") return [];
    return statSync(p).isDirectory() ? walk(p) : /\.(ts|tsx)$/.test(n) ? [p] : [];
  });
}
const stripComments = (s: string) => s.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:"'`])\/\/.*$/gm, "$1");

const FILES = [
  ...walk(path.join(ROOT, "src/components/assets")),
  ...walk(path.join(ROOT, "src/app/assets")),
  path.join(ROOT, "src/lib/db/assets-model.ts"),
  path.join(ROOT, "src/lib/db/assets-server.ts"),
];

describe("หน้าทรัพย์ไม่มีต้นทุนเฉลี่ย", () => {
  it("ไล่ได้ไฟล์ครบ (กันเทสต์ว่างผ่านเงียบๆ)", () => {
    expect(FILES.length).toBeGreaterThanOrEqual(20);
    expect(FILES.some((f) => f.endsWith("asset-manager.tsx"))).toBe(true);
    expect(FILES.some((f) => f.endsWith("asset-detail.tsx"))).toBe(true);
  });

  it("ไม่มีคำว่าเฉลี่ย/ถัว/average/ต่อหน่วย ในโค้ดที่ทำงานหรือข้อความบนจอ", () => {
    const hits = FILES.flatMap((f) =>
      stripComments(readFileSync(f, "utf8"))
        .split("\n")
        .map((line, i) => ({ f: path.relative(ROOT, f), line: i + 1, text: line.trim() }))
        .filter((x) => FORBIDDEN.test(x.text))
    );
    expect(hits).toEqual([]);
  });

  it("ตัวตรวจจับของเทสต์นี้จับได้จริง (กันนิพจน์ที่ไม่จับอะไรเลย)", () => {
    for (const s of ["ต้นทุนเฉลี่ย", "ต้นทุนถัวเฉลี่ย", "avgCost", "averageCost", "ต่อหน่วย", "unitCost", "perUnit"])
      expect(FORBIDDEN.test(s)).toBe(true);
    expect(stripComments("a // ต้นทุนเฉลี่ย\nb /* average */ c")).not.toMatch(FORBIDDEN);
  });

  it("โมเดลไม่ export ฟังก์ชัน/ชนิดที่ชื่อเกี่ยวกับค่าเฉลี่ย · ผลรวมไม่มีช่องหารจำนวนชิ้น", () => {
    expect(Object.keys(model).filter((k) => FORBIDDEN.test(k))).toEqual([]);
    const totals = model.sumReports([{ id: "a" }, { id: "b" }], {
      a: { assetId: "a", costTotal: 3_000_000, renovation: 0, purchase: 3_000_000, repair: 0, otherExpense: 0, income: 0, saleResult: 0, lineCount: 1 },
      b: { assetId: "b", costTotal: 5_000_000, renovation: 0, purchase: 5_000_000, repair: 0, otherExpense: 0, income: 0, saleResult: 0, lineCount: 1 },
    });
    expect(totals.costTotal).toBe(8_000_000); // ผลบวก ไม่ใช่ 4,000,000
    expect(Object.values(totals)).not.toContain(4_000_000);
  });
});
