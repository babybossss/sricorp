import { describe, it, expect } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { repaymentDirection } from "../posting";
import { PostingError } from "../types";
import { TX_TYPES, type SubCategory } from "@/lib/rules/tx-rules";

/**
 * รูที่ 3 (ส่วนรองลงมา) · `posting.ts` เคยตัดสินทิศของหมวด "เงินต้น + ดอกเบี้ย"
 * ด้วย `const isInflow = sub.cash === "in"` → `"both"` · `"none"` **ตกไปทาง else
 * คือเส้นทาง "เงินออก"** เงียบๆ แล้วเงินต้นจะไปลดหนี้สินและดอกเบี้ยจะกลายเป็น
 * ค่าใช้จ่าย ทั้งที่หมวดนั้นไม่ใช่รายการจ่ายเลย
 *
 * วันนี้ยังไม่ถึงเพราะทุกหมวดที่ `requires: principalInterestSplit` เป็น in/out
 * **แต่พึ่งลำดับและพึ่งข้อมูลวันนี้ไม่ได้** (D-102: ค่าใหม่ใน union ตกไปทาง
 * fallback เงียบๆ · TypeScript ไม่ฟ้องเพราะไม่มี map ครบเคส)
 *
 * ข้อมูลไม่ครบ/ไม่เข้าเงื่อนไข = **ปฏิเสธ ห้ามเดา** (บทเรียนข้อ 1 ของ mace-windu:
 * เคยทำให้ดอกเบี้ยถูกนับเป็นเงินต้นเพราะตกไปเส้นทางปกติ)
 */
const fakeSub = (cash: SubCategory["cash"]): SubCategory =>
  ({ code: "test.fake", label: "หมวดทดสอบ", cash } as unknown as SubCategory);

describe("repaymentDirection ตอบครบทุกค่าของ CashDirection", () => {
  it("in = รับคืนเงินต้น · out = ชำระคืนเงินกู้", () => {
    expect(repaymentDirection(fakeSub("in"))).toBe("in");
    expect(repaymentDirection(fakeSub("out"))).toBe("out");
  });

  it('"both" ไม่ตกไปเส้นทางเงินออก — ต้องปฏิเสธพร้อมเหตุผล', () => {
    expect(() => repaymentDirection(fakeSub("both"))).toThrow(PostingError);
    expect(() => repaymentDirection(fakeSub("both"))).toThrow(/เงินต้น/);
  });

  it('"none" ไม่ตกไปเส้นทางเงินออก — ต้องปฏิเสธพร้อมเหตุผล', () => {
    expect(() => repaymentDirection(fakeSub("none"))).toThrow(PostingError);
  });

  it("หมวดจริงทุกตัวที่แยกเงินต้น-ดอกเบี้ย ยังตอบ in/out เหมือนเดิม", () => {
    const subs = TX_TYPES.flatMap((t) => t.subs).filter((s) =>
      s.requires?.includes("principalInterestSplit")
    );
    expect(subs.length).toBeGreaterThan(0);
    for (const s of subs) {
      expect(repaymentDirection(s), s.code).toBe(s.cash);
    }
  });

  it("posting.ts ไม่เทียบ sub.cash === \"in\" เองอีก (mutation: คืนบรรทัดนั้น → แดง)", () => {
    const src = fs
      .readFileSync(path.resolve(__dirname, "..", "posting.ts"), "utf8")
      .replace(/\/\*[\s\S]*?\*\//g, "")
      .replace(/(^|[^:])\/\/.*$/gm, "$1");
    expect(src).not.toMatch(/sub\.cash\s*===/);
    expect(src).toContain("repaymentDirection(sub)");
  });
});
