import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import path from "node:path";
import { ledgerPeriod } from "../ledger-entries";
import { periodRange, periodLabel } from "../statements";

describe("ledgerPeriod — ช่วงเวลาของสมุดบัญชี", () => {
  it("ทั้งปี = ช่วงเดียวกับ periodRange (ไม่คำนวณเอง)", () => {
    expect(ledgerPeriod(2026, null)).toEqual({ year: 2026, month: null, ...periodRange(2026, null), label: periodLabel(2026, null) });
  });
  it("รายเดือน กุมภาพันธ์ปีอธิกสุรทิน ลงท้าย 29", () => {
    const p = ledgerPeriod(2028, 2);
    expect(p.start).toBe("2028-02-01");
    expect(p.end).toBe("2028-02-29");
    expect(p.label).toBe(periodLabel(2028, 2));
  });
  it("เดือนนอกช่วงต้องดัง ไม่คืนวันที่มั่ว", () => {
    expect(() => ledgerPeriod(2026, 13)).toThrow();
  });
});

describe("หน้า /ledger", () => {
  const src = (f: string) => readFileSync(path.join(__dirname, "..", "..", "..", f), "utf8");
  it("กรองที่ query ด้วย doc_date และใช้ PeriodBar ของกลาง", () => {
    const server = src("lib/db/ledger-entries-server.ts");
    expect(server).toMatch(/\.gte\("doc_date"/);
    expect(server).toMatch(/\.lte\("doc_date"/);
    const page = src("app/ledger/page.tsx");
    expect(page).toMatch(/<PeriodBar[^>]*basePath="\/ledger"/);
    expect(page).toMatch(/parseMonth\(/);
    expect(page).toMatch(/parseFiscalYear\(/);
  });
  it("ป้ายช่วงวันที่อ่านจากช่วงที่คำนวณ ไม่ใช่ข้อความตายตัว", () => {
    const tabs = src("components/ledger/ledger-tabs.tsx");
    expect(tabs).toMatch(/period\.label/);
    expect(tabs).not.toMatch(/ทั้งหมดที่บันทึกแล้ว/);
  });
});
