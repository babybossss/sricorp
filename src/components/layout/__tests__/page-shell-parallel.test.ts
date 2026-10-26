import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import path from "node:path";

/**
 * PageShell ต้องถามสิทธิ์กับข้อมูลอ้างอิง **พร้อมกัน** — ไม่รอตัวแรกเสร็จก่อนค่อยเริ่มตัวที่สอง (ไม่งั้นทุกหน้าเสียเวลารอ round trip สองชั้นต่อกัน)
 * ไฟล์ .tsx import ในเทสต์แบบ node ไม่ได้ (JSX) จึงตรวจจากโค้ดต้นฉบับ: ทั้งสองต้องอยู่ใน Promise.all เดียวกัน
 */
describe("PageShell · ถามขนานกัน", () => {
  const src = readFileSync(path.join(__dirname, "..", "page-shell.tsx"), "utf8").replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");

  it("getAccess() กับ loadReference() อยู่ใน Promise.all เดียวกัน", () => {
    expect(src).toMatch(/Promise\.all\(\s*\[\s*getAccess\(\)\s*,\s*loadReference\(\)\s*\]\s*\)/);
  });

  it("ไม่มี await getAccess() / await loadReference() เดี่ยวๆ ต่อกัน", () => {
    expect(src).not.toMatch(/await\s+getAccess\(\)/);
    expect(src).not.toMatch(/await\s+loadReference\(\)/);
  });
});

describe("gateRoute · ตัวกั้นรันก่อน PageShell จึงต้องเริ่มโหลดข้อมูลอ้างอิงพร้อมกับตรวจสิทธิ์", () => {
  const gate = readFileSync(path.join(__dirname, "..", "..", "..", "lib", "auth", "gate.tsx"), "utf8").replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
  it("getAccess() กับ loadReference() อยู่ใน Promise.all เดียวกัน ไม่มี await getAccess() เดี่ยว", () => {
    expect(gate).toMatch(/Promise\.all\(\s*\[\s*getAccess\(\)\s*,\s*loadReference\(\)\s*\]\s*\)/);
    expect(gate).not.toMatch(/await\s+getAccess\(\)/);
  });
});
