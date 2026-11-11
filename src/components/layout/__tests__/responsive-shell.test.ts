import { describe, expect, it } from "vitest";
import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";

/**
 * ด่านของโครงหน้าบนจอแคบ
 *
 * วัดแล้วว่า Sidebar กว้าง 256px **ตายตัว** (`w-64 flex-none`) ที่จอ 390px
 * จึงเหลือที่ให้เนื้อหาแค่ 134px — อ่านอะไรไม่ได้เลย และลูกพี่ใช้มือถือบ่อย
 *
 * ซ่อน Sidebar เฉยๆ ไม่พอ ต้องมีเมนูแทนที่ ไม่งั้นจอแคบจะไปหน้าอื่นไม่ได้
 * และทั้งสองต้องใช้รายการเมนูชุดเดียว (`NAV`) ห้ามมีรายการที่สอง
 */
const dir = path.join(__dirname, "..");
const read = (f: string) => readFileSync(path.join(dir, f), "utf8");

describe("โครงหน้าใช้ได้บนจอแคบ", () => {
  it("Sidebar ซ่อนต่ำกว่า lg และโผล่ที่ lg ขึ้นไป", () => {
    const src = read("sidebar.tsx");
    expect(src).toMatch(/className="[^"]*\bhidden\b[^"]*\blg:flex\b[^"]*"/);
    // ห้ามกลับไปเป็น flex ตายตัวที่ทุกขนาดจอ
    expect(src).not.toMatch(/className="sticky top-0 flex min-h-screen w-64/);
  });

  it("MobileNav โผล่ต่ำกว่า lg และซ่อนที่ lg ขึ้นไป", () => {
    expect(read("mobile-nav.tsx")).toMatch(/\blg:hidden\b/);
  });

  it("PageShell ใส่ MobileNav ไว้จริง", () => {
    expect(read("page-shell.tsx")).toMatch(/<MobileNav pendingApprovals=\{pendingApprovals\} \/>/);
  });

  it("เมนูมือถือใช้รายการ NAV ชุดเดียวกับ Sidebar ไม่ได้ทำรายการที่สอง", () => {
    const src = read("mobile-nav.tsx");
    expect(src).toMatch(/import \{ NAV \} from "\.\/sidebar"/);
    expect(src).not.toMatch(/const NAV\b/);
  });

  it("เมนูมือถือกรองสิทธิ์ด้วยกติกาตัวเดียวกับ Sidebar", () => {
    for (const f of ["sidebar.tsx", "mobile-nav.tsx"]) {
      expect(read(f)).toMatch(/canOpen\(permissions, n\.href\)/);
    }
  });

  it("ปุ่มในเมนูมือถือมีข้อความกำกับ สูง ≥ 52px และมีวงแหวนโฟกัส 3px", () => {
    const src = read("mobile-nav.tsx");
    expect(src).toMatch(/min-h-control/);
    expect(src).toMatch(/focus-visible:ring-\[3px\]/);
    expect(src).toMatch(/\{n\.label\}/);
  });

  it("สวิตช์โหมดตัวใหญ่เข้าถึงได้บนจอแคบด้วย ไม่ได้อยู่แต่ใน Sidebar", () => {
    expect(read("mobile-nav.tsx")).toMatch(/toggleLargeText/);
  });
});

describe("วงแหวนโฟกัสต้องมองเห็นได้", () => {
  it("ไม่มีไฟล์ใดใน src ใช้ ring-brand-100 ซึ่งคอนทราสต์ต่ำเกินจนมองไม่เห็น", () => {
    // brand-100 (#D6E4F7) บนพื้นขาวได้ ~1.3:1 — ต่ำกว่าเกณฑ์มาก
    // และคอมโพเนนต์ยังสั่ง focus-visible:outline-none ทิ้งวงแหวนดีๆ ของ globals.css ไปด้วย
    // ข้ามโฟลเดอร์ __tests__ ไม่งั้นด่านนี้จับสตริงในตัวเองแล้วแดงเอง
    const SRC = path.join(dir, "..", "..");
    const bad: string[] = [];
    const walk = (d: string) => {
      for (const e of readdirSync(d)) {
        const full = path.join(d, e);
        if (statSync(full).isDirectory()) {
          if (e === "__tests__") continue;
          walk(full);
        } else if (/\.(ts|tsx|css)$/.test(e) && readFileSync(full, "utf8").includes("ring-brand-100")) {
          bad.push(path.relative(SRC, full));
        }
      }
    };
    walk(SRC);
    expect(bad).toEqual([]);
  });
});
