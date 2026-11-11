import { describe, expect, it } from "vitest";
import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";

/**
 * ด่านกัน "ตัวเลขปลอมและข้อมูลจำลองโผล่ให้ผู้ใช้เห็น"
 *
 * เคยพลาดจริงสามจุดพร้อมกัน
 * - ป้าย `badge: "7"` ฮาร์ดโค้ดบนเมนูคิวอนุมัติ และ `>7<` บนปุ่มแจ้งเตือน
 *   ขณะที่ระบบมี 0 รายการ → ผู้ใช้เห็น "7 รออนุมัติ" ที่ไม่มีอยู่จริง
 * - MonthPicker แสดง "ก.ย. 2026" ตายตัว กดเปลี่ยนได้แต่ไม่มีหน้าไหนอ่านค่า
 *   → ผู้ใช้เชื่อว่างบเปลี่ยนตามเดือนที่เลือก แต่มันไม่เปลี่ยน
 * - เมนูของจริง import รายการจาก `lib/mock/dashboard`
 *
 * ตัวเลขที่ผู้ใช้เห็นต้องมาจาก DB เสมอ · อ่านไม่ได้ = ไม่แสดง (ไม่ใช่แสดง 0)
 */

const SRC = path.join(__dirname, "..", "..", "..");

/** ไฟล์หน้าจอจริงทั้งหมด — ไม่นับเทสต์ และไม่นับหน้าโชว์ไอคอนสำหรับ dev */
function screenFiles(): string[] {
  const out: string[] = [];
  const walk = (dir: string) => {
    for (const e of readdirSync(dir)) {
      const full = path.join(dir, e);
      if (statSync(full).isDirectory()) {
        if (e === "__tests__" || full.endsWith(path.join("app", "dev"))) continue;
        walk(full);
      } else if (e.endsWith(".ts") || e.endsWith(".tsx")) out.push(full);
    }
  };
  walk(path.join(SRC, "components"));
  walk(path.join(SRC, "app"));
  return out;
}

const rel = (f: string) => path.relative(SRC, f);

describe("หน้าจอจริงห้ามอ่านข้อมูลจำลอง", () => {
  it("ไม่มีไฟล์ใดใน components/ หรือ app/ import จาก @/lib/mock", () => {
    const bad = screenFiles().filter((f) => /from\s+["']@\/lib\/mock/.test(readFileSync(f, "utf8")));
    expect(bad.map(rel)).toEqual([]);
  });

  it("ไม่มีหน้าจอใดเรียกตัวช่วยบัญชีธนาคารที่ยังผูกกับข้อมูลจำลอง", () => {
    // useOrderedBanks / isBankActive ใน lib/store ยัง seed จาก lib/mock/banks
    // ฟอร์มจริงอ่านบัญชีจาก Reference (DB) — ห้ามมีหน้าไหนหลงมาใช้สองตัวนี้
    const bad = screenFiles().filter((f) => /\b(useOrderedBanks|isBankActive)\s*\(/.test(readFileSync(f, "utf8")));
    expect(bad.map(rel)).toEqual([]);
  });
});

describe("ป้ายคิวอนุมัติต้องมาจากค่าจริง", () => {
  const read = (f: string) => readFileSync(path.join(SRC, "components", "layout", f), "utf8");

  it.each(["sidebar.tsx", "topbar.tsx"])("%s แสดงป้ายจาก pendingApprovals ไม่ใช่เลขที่เขียนไว้", (file) => {
    const src = read(file);
    expect(src).toContain("pendingApprovals");
    // ต้องกันทั้งสองเงื่อนไข: null = อ่านไม่ได้ (ซ่อน) · 0 = ไม่มีของรอ (ซ่อน)
    expect(src).toMatch(/pendingApprovals !== null && pendingApprovals > 0/);
  });

  it.each(["sidebar.tsx", "topbar.tsx"])("%s ไม่มีตัวเลขเขียนตายตัวเป็นเนื้อหาของป้าย", (file) => {
    // ตัดคอมเมนต์ก่อน ไม่งั้นคอมเมนต์ที่เล่าว่า 'เคยฮาร์ดโค้ด "7"' จะทำให้ด่านแดงเอง
    const src = read(file)
      .replace(/\/\*[\s\S]*?\*\//g, "")
      .replace(/\{\/\*[\s\S]*?\*\/\}/g, "")
      .replace(/\/\/.*$/gm, "");
    // ">7<" หรือ badge: "7" — เนื้อหา JSX ที่เป็นตัวเลขล้วน
    expect(src).not.toMatch(/>\s*\d+\s*</);
    expect(src).not.toMatch(/badge\s*:\s*["']\d+["']/);
  });
});

describe("ตัวเลือกเดือนที่ไม่ควบคุมอะไรต้องไม่กลับมา", () => {
  it("ไม่มี MonthPicker และไม่มีสถานะเดือนใน store", () => {
    const store = readFileSync(path.join(SRC, "lib", "store.ts"), "utf8");
    expect(store).not.toMatch(/\bstepMonth\b/);
    expect(store).not.toMatch(/\bsetMonth\b/);
    const users = screenFiles().filter((f) => /MonthPicker/.test(readFileSync(f, "utf8")));
    expect(users.map(rel)).toEqual([]);
  });
});
