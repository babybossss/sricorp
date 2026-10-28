import { describe, expect, it } from "vitest";
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

/**
 * ด่านกันเรียก `roundShares` (อาร์เรย์แบน) ตรงจากหน้าจอ/server
 * หน้าจอต้องใช้ `roundSharePairs` (รับเป็นคู่ dr/cr) เท่านั้น — ไม่งั้นถ้ามีใครเรียกแยกฝั่ง
 * tag เดียวจะแสดง dr 0.06 / cr 0.05 ทั้งที่ของจริงดุล (ข้อสังเกตผู้ตรวจ ADR 0003 ข้อ 4.2.1)
 * เทสต์อ่านซอร์สจริง และพังถ้าหาผู้เรียกที่ถูกต้องไม่เจอ (ไม่ผ่านด้วยชุดว่าง)
 */
const root = path.resolve(__dirname, "../../..");
const strip = (src: string) => src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:"'`])\/\/.*$/gm, "$1");

function walk(dir: string): string[] {
  return readdirSync(dir).flatMap((f) => {
    const p = path.join(dir, f);
    if (statSync(p).isDirectory()) return f === "__tests__" || f === "node_modules" ? [] : walk(p);
    return /\.(ts|tsx)$/.test(f) ? [p] : [];
  });
}

const files = walk(root).map((p) => ({ rel: path.relative(root, p), code: strip(readFileSync(p, "utf8")) }));

describe("ไม่มีใครเรียก roundShares แยกฝั่ง", () => {
  it("นอกจาก display.ts ไม่มีไฟล์ไหนเรียก roundShares( ตรงๆ", () => {
    const offenders = files.filter((f) => f.rel !== path.join("lib", "tags", "display.ts") && /\broundShares\s*\(/.test(f.code)).map((f) => f.rel);
    expect(offenders).toEqual([]);
  });

  it("พบผู้เรียก roundSharePairs ในฟอร์ม (กันผ่านด้วยชุดว่าง)", () => {
    expect(files.filter((f) => /\broundSharePairs\s*\(/.test(f.code)).map((f) => f.rel)).toContain(path.join("components", "form", "tag-section.tsx"));
  });

  it("ด่านจับได้จริง: ตัวอย่างที่เรียกแยกฝั่งต้องโดน regex", () => {
    expect(/\broundShares\s*\(/.test("roundShares(a.shares.map((s) => s.credit))")).toBe(true);
  });
});
