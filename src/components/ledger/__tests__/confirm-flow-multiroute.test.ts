/**
 * บัญชีพักที่มีหลายทางล้าง — ผู้ใช้ต้องเลือก ห้ามหยิบตัวแรก
 *
 * ตารางกฎวันนี้ทุกบัญชีพักมีทางเดียว จึงจำลองวันที่ตารางกฎมีทางที่สองด้วยการ mock
 * `clearingSubsFor()` — ทั้ง engine และตัวต่อใช้ฟังก์ชันตัวนี้ตัวเดียวกัน (จึงเห็นตรงกัน)
 * เทสต์นี้อยู่แยกไฟล์เพราะ `vi.mock` มีผลทั้งไฟล์ ไม่อยากให้ไปปนกับเคสที่ใช้ตารางกฎจริง
 */

import { describe, it, expect, vi } from "vitest";

vi.mock("@/lib/rules/tx-rules", async (orig) => {
  const real = await orig<typeof import("@/lib/rules/tx-rules")>();
  return {
    ...real,
    clearingSubsFor: (account: string, cashflow: Parameters<typeof real.clearingSubsFor>[1]) => {
      const routes = real.clearingSubsFor(account, cashflow);
      // ทางที่สองสมมติ — ใช้หมวดจริงอีกหมวดที่ล้างบัญชีเดียวกันไม่ได้ จึงโคลนทางแรกเป็นอีกรหัสหนึ่ง
      return routes.length === 1 ? [...routes, { ...routes[0], code: "clr.second", label: "ล้างด้วยการหักกลบ" }] : routes;
    },
  };
});

import { CASH_GROUPS } from "@/lib/mock/ledger";
import { MOCK_RESOLVER } from "@/lib/mock/resolver";
import { checkRow, clearingChoicesOf, confirmRows, initialDraft, initialPosted } from "../confirm-flow";

const row = CASH_GROUPS[1].rows[0]; // cc4 · ธนากร · ค่าเช่า 12,000
const posted = initialPosted([row]);

describe("หลายทางล้าง", () => {
  it("หน้าจอเห็นทางล้างทั้งสองจากตารางกฎ — มีให้เลือก", () => {
    expect(clearingChoicesOf(row).length).toBe(2);
  });
  it("ไม่เลือก → ไม่ได้ (ไม่ใช่หยิบตัวแรกให้)", () => {
    const c = checkRow(row, initialDraft(row), posted, MOCK_RESOLVER);
    expect(c.canConfirm).toBe(false);
    expect(c.blockedReason).toContain("ทางล้าง");
    expect(confirmRows([row], {}, posted, MOCK_RESOLVER).ok).toBe(false);
  });
  it("เลือกทางที่ตารางกฎมี → ได้", () => {
    const [first] = clearingChoicesOf(row);
    const d = { ...initialDraft(row), clearingSubCode: first.code };
    expect(checkRow(row, d, posted, MOCK_RESOLVER).canConfirm).toBe(true);
    expect(confirmRows([row], { [row.id]: d }, posted, MOCK_RESOLVER).ok).toBe(true);
  });
  it("เลือกทางที่ไม่ใช่ของรายการนี้ → ไม่ได้", () => {
    const d = { ...initialDraft(row), clearingSubCode: "ghost.route" };
    expect(checkRow(row, d, posted, MOCK_RESOLVER).canConfirm).toBe(false);
  });
});
