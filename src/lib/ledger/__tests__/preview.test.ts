import { describe, it, expect } from "vitest";
import { previewPosting } from "../preview";
import { buildPostingDraft, allLines } from "../posting";
import type { PostingInput } from "../types";
import { coa } from "@/lib/rules/coa";

const sale: PostingInput = {
  typeKey: "invest_sell",
  subCode: "inv.sell_re",
  ownerId: "thanakorn",
  bankAccountId: "b4",
  assetId: "rent1",
  amount: 2_950_000,
  disposal: { costBasis: 2_450_000, salePrice: 3_000_000, sellingCosts: 50_000 },
};

/**
 * พรีวิวต้องเป็น engine ตัวเดียวกับที่บันทึกจริง ไม่ใช่การคำนวณคู่ขนาน
 * ถ้าวันหนึ่งมีใครแยกไปคำนวณเอง เทสต์ชุดนี้จะพัง
 */
describe("พรีวิวบรรทัดบัญชี", () => {
  it("บรรทัดที่โชว์ ตรงกับบรรทัดที่ engine สร้างทุกตัว", () => {
    const preview = previewPosting(sale);
    expect(preview.ok).toBe(true);
    if (!preview.ok) return;

    const engine = allLines(buildPostingDraft(sale));
    expect(preview.lines).toHaveLength(engine.length);
    preview.lines.forEach((l, i) => {
      const { label, ...line } = l;
      expect(line).toEqual(engine[i]);
      expect(label, l.coaCode).toBe(coa(l.coaCode).nameTh);
    });
  });

  it("ข้อมูลยังไม่ครบ: บอกว่าขาดอะไร ไม่โยน error ใส่หน้าจอ", () => {
    const r = previewPosting({ ...sale, disposal: undefined });
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.reason).toMatch(/ต้นทุนและราคาขาย/);
  });

  it("ยอดหัวรายการไม่ตรงเงินสุทธิ: ไม่แสดงบรรทัด", () => {
    const r = previewPosting({ ...sale, amount: 3_000_000 });
    expect(r.ok).toBe(false);
  });

  it("รายการข้ามผู้ถือ: บอกว่าเป็นสองรายการคู่กัน", () => {
    const r = previewPosting({
      typeKey: "transfer",
      subCode: "trf.internal",
      ownerId: "thanakorn",
      bankAccountId: "b4",
      amount: 100_000,
      transferToBankAccountId: "b5",
      intercompanyNature: "loan",
    });
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.transactionCount).toBe(2);
  });
});
