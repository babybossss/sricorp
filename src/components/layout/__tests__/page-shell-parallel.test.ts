import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import path from "node:path";

/**
 * PageShell ต้องถามสิทธิ์กับข้อมูลอ้างอิง **พร้อมกัน** — ไม่รอตัวแรกเสร็จก่อนค่อยเริ่มตัวที่สอง (ไม่งั้นทุกหน้าเสียเวลารอ round trip สองชั้นต่อกัน)
 * ไฟล์ .tsx import ในเทสต์แบบ node ไม่ได้ (JSX) จึงตรวจจากโค้ดต้นฉบับ: ทั้งสองต้องอยู่ใน Promise.all เดียวกัน
 */
describe("PageShell · ถามขนานกัน", () => {
  const src = readFileSync(path.join(__dirname, "..", "page-shell.tsx"), "utf8").replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");

  /** ทุกตัวที่ PageShell ต้องถาม DB — เพิ่มตัวใหม่ต้องมาต่อท้ายรายการนี้ ไม่ใช่ไป await เดี่ยว */
  const MUST_BE_PARALLEL = ["getAccess", "loadReference", "countPendingApprovals"];

  it("ทุกการถาม DB อยู่ใน Promise.all ก้อนเดียวกัน", () => {
    // จับ argument ของ Promise.all แล้วตรวจว่ามีครบ — ไม่ผูกกับลำดับ เพราะเจตนาของด่านนี้
    // คือ "ขนานกัน" ไม่ใช่ "เรียงแบบนี้" แต่ยังต้องอยู่ใน Promise.all **ก้อนเดียว** จริงๆ
    const calls = [...src.matchAll(/Promise\.all\(\s*\[([\s\S]*?)\]\s*\)/g)].map((m) => m[1]);
    expect(calls.length).toBe(1);
    for (const fn of MUST_BE_PARALLEL) expect(calls[0]).toContain(`${fn}()`);
  });

  it("ไม่มี await เดี่ยวๆ ของตัวใดต่อกัน", () => {
    for (const fn of MUST_BE_PARALLEL) expect(src).not.toMatch(new RegExp(`await\\s+${fn}\\(\\)`));
  });
});

describe("gateRoute · ตัวกั้นรันก่อน PageShell จึงต้องเริ่มโหลดข้อมูลอ้างอิงพร้อมกับตรวจสิทธิ์", () => {
  const gate = readFileSync(path.join(__dirname, "..", "..", "..", "lib", "auth", "gate.tsx"), "utf8").replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
  it("getAccess() กับ loadReference() อยู่ใน Promise.all เดียวกัน ไม่มี await getAccess() เดี่ยว", () => {
    expect(gate).toMatch(/Promise\.all\(\s*\[\s*getAccess\(\)\s*,\s*loadReference\(\)\s*\]\s*\)/);
    expect(gate).not.toMatch(/await\s+getAccess\(\)/);
  });
});
