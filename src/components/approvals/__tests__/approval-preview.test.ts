import { describe, it, expect } from "vitest";
import { APPROVALS, type Approval } from "@/lib/mock/ledger";
import { MOCK_RESOLVER } from "@/lib/mock/resolver";
import { previewApproval } from "../approval-preview";

const base = APPROVALS.find((a) => a.id === "a1")!; // ค่าซ่อม · corp · จ่ายแล้ว (ไม่ค้าง)

const withBank = (bankAccountId: string | undefined, extra: Partial<Approval> = {}): Approval => ({
  ...base,
  ...extra,
  bankAccountId,
});

describe("previewApproval — แผงอนุมัติเลิกเดาบัญชี", () => {
  it("ใช้บัญชีที่คนคีย์เลือก ไม่ใช่บัญชีแรกที่เปิดอยู่ของผู้ถือ", () => {
    // corp มี b1 (เปิด) เป็นบัญชีแรก — เลือก b10 (เงินสดในมือ) แล้วต้องเห็น b10 ไม่ใช่ b1
    const r = previewApproval(withBank("b10"), MOCK_RESOLVER);
    expect(r.canApprove).toBe(true);
    if (!r.preview.ok) throw new Error("ต้องพรีวิวได้");
    const banks = r.preview.lines.map((l) => l.bankAccountId).filter(Boolean);
    expect(banks).toEqual(["b10"]);
  });

  it("บัญชีของคนอื่น → ปฏิเสธ ไม่แอบเปลี่ยนเป็นบัญชีของผู้ถือ", () => {
    const r = previewApproval(withBank("b4"), MOCK_RESOLVER); // b4 เป็นของธนากร แต่รายการเป็นของ corp
    expect(r.canApprove).toBe(false);
    expect(r.blockedReason).toBeTruthy();
  });

  it("ไม่มีบัญชี และรายการมีขาเงินสด → ไม่พรีวิว อนุมัติไม่ได้ พร้อมเหตุผล", () => {
    const r = previewApproval(withBank(undefined, { notYetPaid: false }), MOCK_RESOLVER);
    expect(r.preview.ok).toBe(false);
    expect(r.canApprove).toBe(false);
    expect(r.blockedReason).toContain("บัญชี");
  });

  it("บัญชีว่างเป็นสตริงเปล่า = ไม่ได้ระบุ เหมือน undefined", () => {
    const r = previewApproval(withBank(""), MOCK_RESOLVER);
    expect(r.canApprove).toBe(false);
  });

  it("บัญชีที่ไม่มีในระบบ → ปฏิเสธ ไม่ตกไปเส้นทางปกติ", () => {
    const r = previewApproval(withBank("b-ghost"), MOCK_RESOLVER);
    expect(r.canApprove).toBe(false);
    expect(r.blockedReason).toContain("b-ghost");
  });

  it("ไม่มีบัญชี แต่เป็นค้างรับ-ค้างจ่าย → ห้ามมีบรรทัดเงินสดที่ไม่รู้บัญชีหลุดออกมา", () => {
    const accrual = APPROVALS.find((a) => a.id === "a2")!; // ค้างจ่าย ไม่มีบัญชี
    expect(accrual.bankAccountId).toBeUndefined();
    expect(accrual.notYetPaid).toBe(true);

    const r = previewApproval(accrual, MOCK_RESOLVER);
    // ไม่ว่า engine จะยอมหรือปฏิเสธ: ถ้ายอม ต้องไม่มีบรรทัดเงินสดเลย (ยังไม่มีขาเงินสด)
    if (r.preview.ok) {
      expect(r.preview.lines.some((l) => l.coaCode === "1100")).toBe(false);
      expect(r.preview.lines.every((l) => l.bankAccountId === undefined)).toBe(true);
    } else {
      expect(r.canApprove).toBe(false);
      expect(r.blockedReason).toBeTruthy();
    }
  });

  it("canApprove ตรงกับผลพรีวิวของ engine เสมอ", () => {
    for (const a of APPROVALS) {
      const r = previewApproval(a, MOCK_RESOLVER);
      expect(r.canApprove).toBe(r.preview.ok);
      expect(r.blockedReason === null).toBe(r.preview.ok);
    }
  });

  it("ข้อมูลจำลองทุกรายการที่มีบัญชี พรีวิวได้", () => {
    for (const a of APPROVALS.filter((x) => x.bankAccountId)) {
      const r = previewApproval(a, MOCK_RESOLVER);
      expect(r.blockedReason, a.id).toBeNull();
    }
  });
});
