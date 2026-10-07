import { describe, it, expect } from "vitest";
import { APPROVALS, type Approval } from "@/lib/mock/ledger";
import { MOCK_RESOLVER } from "@/lib/mock/resolver";
import { buildPostingDraft } from "@/lib/ledger/posting";
import { previewApproval, planBulkApproval, approvalInput } from "../approval-preview";

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

  it("canApprove เข้มกว่าพรีวิวได้ แต่ห้ามหลวมกว่า — อนุมัติได้ต้องพรีวิวได้ และ blockedReason สอดคล้อง", () => {
    for (const a of APPROVALS) {
      const r = previewApproval(a, MOCK_RESOLVER);
      if (r.canApprove) expect(r.preview.ok, a.id).toBe(true);
      expect(r.blockedReason === null, a.id).toBe(r.canApprove);
    }
  });

  it("ข้อมูลจำลองที่มีบัญชีและมีหลักฐาน (หรือเป็นฝั่งบุคคล) อนุมัติได้ ยกเว้น a4 ที่ตั้งใจไม่มีหลักฐาน", () => {
    for (const a of APPROVALS.filter((x) => x.bankAccountId && x.id !== "a4")) {
      const r = previewApproval(a, MOCK_RESOLVER);
      expect(r.blockedReason, a.id).toBeNull();
    }
  });
});

describe("previewApproval — ปุ่มอนุมัติกั้นด้วย buildPosting() ตัวจริง ไม่ใช่ draft", () => {
  const a4 = APPROVALS.find((a) => a.id === "a4")!; // นิติบุคคล · มีคู่ค้า · มีบัญชี · ไม่มีหลักฐาน

  it("ข้อมูลตัวอย่างเหลือรายการนิติบุคคลที่ไม่มีหลักฐานไว้จริง", () => {
    expect(a4.ownerId).toBe("corp");
    expect(a4.attachments).toBeUndefined();
  });

  it("นิติบุคคลไม่มีหลักฐาน → อนุมัติไม่ได้ ข้อความมาจาก engine", () => {
    const r = previewApproval(a4, MOCK_RESOLVER);
    expect(r.canApprove).toBe(false);
    expect(r.blockedReason).toContain("ต้องแนบหลักฐาน");
    // บรรทัดบัญชียังโชว์ให้อ่านได้ (ไฟล์แนบไม่เปลี่ยนคู่บัญชี)
    expect(r.preview.ok).toBe(true);
  });

  it("พิสูจน์ว่าต้องไม่ใช้ draft: draft ปล่อยรายการเดียวกันผ่าน", () => {
    expect(() => buildPostingDraft(approvalInput(a4), MOCK_RESOLVER)).not.toThrow();
  });

  it("แนบไฟล์ว่าง [] = ไม่มีหลักฐาน → อนุมัติไม่ได้", () => {
    const r = previewApproval({ ...a4, attachments: [] }, MOCK_RESOLVER);
    expect(r.canApprove).toBe(false);
    expect(r.blockedReason).toContain("ต้องแนบหลักฐาน");
  });

  it("นิติบุคคลมีหลักฐาน → อนุมัติได้", () => {
    const r = previewApproval({ ...a4, attachments: ["ใบเสร็จ.pdf"] }, MOCK_RESOLVER);
    expect(r.canApprove).toBe(true);
    expect(r.blockedReason).toBeNull();
  });

  it("นิติบุคคลมีหลักฐานแต่ไม่มีคู่ค้า → อนุมัติไม่ได้", () => {
    const r = previewApproval({ ...a4, attachments: ["ใบเสร็จ.pdf"], contactId: undefined }, MOCK_RESOLVER);
    expect(r.canApprove).toBe(false);
    expect(r.blockedReason).toContain("คู่ค้า");
  });

  it("นิติบุคคล ไม่ส่งทั้งหลักฐาน คู่ค้า และบัญชี → อนุมัติไม่ได้ ไม่ตกเส้นทางปกติ", () => {
    const r = previewApproval(
      { ...a4, attachments: undefined, contactId: undefined, bankAccountId: undefined },
      MOCK_RESOLVER
    );
    expect(r.canApprove).toBe(false);
    expect(r.blockedReason).toBeTruthy();
  });

  it("ฝั่งบุคคลไม่ถูกบังคับหลักฐาน — ไม่ส่งไฟล์แนบ ก็อนุมัติได้", () => {
    const a3 = APPROVALS.find((a) => a.id === "a3")!; // ธนากร · personal_flexible
    expect(a3.attachments).toBeUndefined();
    const r = previewApproval(a3, MOCK_RESOLVER);
    expect(r.canApprove).toBe(true);
    expect(r.blockedReason).toBeNull();
  });

  it("ฝั่งบุคคลไม่ถูกบังคับคู่ค้า (ถ้าหมวดไม่ได้ require) — ไม่ส่งไฟล์แนบ ไม่ส่งคู่ค้า", () => {
    const personal: Approval = { ...a4, ownerId: "thanakorn", bankAccountId: "b4", attachments: undefined, contactId: undefined };
    const r = previewApproval(personal, MOCK_RESOLVER);
    expect(r.blockedReason).toBeNull();
    expect(r.canApprove).toBe(true);
  });

  it("ฝั่งบุคคลที่หมวด require คู่ค้า ยังถูก engine ปฏิเสธตามกฎหมวด (ไม่เกี่ยวกับนโยบายนิติบุคคล)", () => {
    const a3 = APPROVALS.find((a) => a.id === "a3")!;
    const r = previewApproval({ ...a3, contactId: undefined }, MOCK_RESOLVER);
    expect(r.canApprove).toBe(false);
    expect(r.blockedReason).toContain("ผู้ติดต่อ");
  });
});

describe("planBulkApproval — อนุมัติหมู่รายตัว", () => {
  const a1 = APPROVALS.find((a) => a.id === "a1")!; // นิติบุคคล มีหลักฐาน
  const a3 = APPROVALS.find((a) => a.id === "a3")!; // บุคคล
  const a4 = APPROVALS.find((a) => a.id === "a4")!; // นิติบุคคล ไม่มีหลักฐาน

  it("มีทั้งผ่านและติด → ผ่านเฉพาะที่ควรผ่าน ข้ามที่ติดพร้อมเหตุผลจาก engine", () => {
    const plan = planBulkApproval([a1, a3, a4], MOCK_RESOLVER);
    expect(plan.approvable.map((a) => a.id)).toEqual(["a1", "a3"]);
    expect(plan.skipped).toHaveLength(1);
    expect(plan.skipped[0].item.id).toBe("a4");
    expect(plan.skipped[0].reason).toContain("ต้องแนบหลักฐาน");
  });

  it("รายการเดียวที่ติด ไม่ดับทั้งคิว", () => {
    const plan = planBulkApproval(APPROVALS, MOCK_RESOLVER);
    expect(plan.approvable.length).toBeGreaterThan(0);
    expect(plan.approvable.map((a) => a.id)).not.toContain("a4");
    expect(plan.approvable.length + plan.skipped.length).toBe(APPROVALS.length);
  });

  it("ทุกรายการที่ผ่านได้ต้องเป็นรายการที่ engine ตัวจริงปล่อยเท่านั้น", () => {
    const plan = planBulkApproval(APPROVALS, MOCK_RESOLVER);
    for (const a of plan.approvable) expect(previewApproval(a, MOCK_RESOLVER).canApprove, a.id).toBe(true);
    for (const x of plan.skipped) expect(previewApproval(x.item, MOCK_RESOLVER).canApprove, x.item.id).toBe(false);
  });

  it("ติดทั้งหมด → ไม่มีรายการผ่าน และข้ามครบ", () => {
    const plan = planBulkApproval([a4, { ...a4, id: "x" }], MOCK_RESOLVER);
    expect(plan.approvable).toHaveLength(0);
    expect(plan.skipped).toHaveLength(2);
  });

  it("คิวว่าง → ไม่มีอะไรผ่าน ไม่มีอะไรข้าม", () => {
    expect(planBulkApproval([], MOCK_RESOLVER)).toEqual({ approvable: [], skipped: [] });
  });
});

describe("เคสค้างรับ-ค้างจ่ายไม่มีบัญชี (รอเครื่องยนต์) — พฤติกรรมที่ถูกต้อง", () => {
  it("a2 (นิติบุคคล มีหลักฐาน ค้างจ่าย ไม่มีบัญชี) ต้องอนุมัติได้ เพราะยังไม่มีขาเงินสด", () => {
    const a2 = APPROVALS.find((a) => a.id === "a2")!;
    expect(a2.bankAccountId).toBeUndefined();
    const r = previewApproval(a2, MOCK_RESOLVER);
    expect(r.blockedReason).toBeNull();
    expect(r.canApprove).toBe(true);
  });
});
