import { describe, it, expect } from "vitest";
import type { ApprovalItem } from "@/lib/db/approvals-model";
import { makeResolver } from "@/lib/db/resolver";
import { referenceFixture, OWNER, BANK, ASSET, CONTACT } from "@/app/actions/__tests__/fake-db";
import { buildPostingDraft } from "@/lib/ledger/posting";
import { previewApproval, planBulkApproval, approvalInput } from "../approval-preview";

const resolver = makeResolver(referenceFixture());

/** ไฟล์หลักฐานที่ "อัปโหลดจริง" ของผู้ถือ — path รูปแบบเดียวกับ Storage (ผ่านด่านนิติบุคคลของ engine) */
const evidence = (ownerId: string, n = 1) =>
  `${ownerId}/cccccccc-3333-4333-8333-cccccccccccc/dddddddd-4444-4444-8444-${String(n).padStart(12, "0")}.pdf`;

const item = (over: Partial<ApprovalItem> = {}): ApprovalItem => ({
  id: "d1", ownerId: OWNER.corp, subCode: "exp.repair", typeKey: "expense", docDate: "2026-09-10", cashDate: null, amount: 12400,
  assetId: ASSET, contactId: CONTACT, contractId: null, memo: "ค่าซ่อมแอร์", attachments: [evidence(OWNER.corp)], dueDate: null, source: "manual",
  createdBy: { id: "u2", name: "มาวิน" }, createdAt: "2026-09-10T00:00:00Z", ...over,
});
const corpOk = item();
const corpNoEvidence = item({ id: "d4", attachments: [] });
const personal = item({ id: "d3", ownerId: OWNER.tk, subCode: "inc.rent", typeKey: "income", attachments: [], amount: 12000 });

describe("approvalInput — ร่าง → input ของ engine โดยไม่เดา", () => {
  it("ไม่มีบัญชี → ส่ง \"\" ไม่หยิบบัญชีแรกของผู้ถือ · ไม่มี cash_date = ยังไม่ได้รับ/จ่าย", () => {
    const i = approvalInput(corpOk)!;
    expect(i.bankAccountId).toBe("");
    expect(i.notYetPaid).toBe(true);
    expect(i.attachments).toEqual(corpOk.attachments);
    expect(approvalInput(item({ cashDate: "2026-09-10" }))!.notYetPaid).toBe(false);
  });
  it("หมวดย่อยที่ไม่มีในตารางกฎ → null (ไม่เดาประเภท)", () => {
    expect(approvalInput(item({ subCode: "zzz.unknown", typeKey: null }))).toBeNull();
  });
});

describe("previewApproval — ปุ่มอนุมัติกั้นด้วย buildPosting() ตัวจริง ไม่ใช่ draft", () => {
  it("นิติบุคคลมีหลักฐาน+คู่ค้า ค้างจ่าย (ไม่มีขาเงินสด) → อนุมัติได้ และไม่มีบรรทัดเงินสดหลุดมา", () => {
    const r = previewApproval(corpOk, resolver);
    expect(r.blockedReason).toBeNull();
    expect(r.canApprove).toBe(true);
    if (!r.preview.ok) throw new Error("ต้องพรีวิวได้");
    expect(r.preview.lines.some((l) => l.coaCode === "1100")).toBe(false);
  });

  it("นิติบุคคลไม่มีหลักฐาน → อนุมัติไม่ได้ ข้อความมาจาก engine · บรรทัดบัญชียังโชว์ให้อ่านได้", () => {
    const r = previewApproval(corpNoEvidence, resolver);
    expect(r.canApprove).toBe(false);
    expect(r.blockedReason).toContain("ต้องแนบหลักฐาน");
    expect(r.preview.ok).toBe(true);
  });

  it("พิสูจน์ว่าต้องไม่ใช้ draft: draft ปล่อยรายการเดียวกันผ่าน", () => {
    expect(() => buildPostingDraft(approvalInput(corpNoEvidence)!, resolver)).not.toThrow();
  });

  it("นิติบุคคลมีหลักฐานแต่ไม่มีคู่ค้า → อนุมัติไม่ได้", () => {
    const r = previewApproval(item({ contactId: null }), resolver);
    expect(r.canApprove).toBe(false);
    expect(r.blockedReason).toContain("คู่ค้า");
  });

  it("ฝั่งบุคคลไม่ถูกบังคับหลักฐาน — ไม่แนบไฟล์ก็อนุมัติได้", () => {
    const r = previewApproval(personal, resolver);
    expect(r.blockedReason).toBeNull();
    expect(r.canApprove).toBe(true);
  });

  it("มีวันที่เงินเคลื่อนแต่ร่างไม่มีบัญชีธนาคาร → อนุมัติไม่ได้ พร้อมเหตุผลเรื่องบัญชี (ไม่เดาบัญชีให้)", () => {
    const r = previewApproval(item({ cashDate: "2026-09-10" }), resolver);
    expect(r.canApprove).toBe(false);
    expect(r.blockedReason).toContain("บัญชี");
    expect(BANK.corp).toBeTruthy(); // บัญชี corp มีอยู่จริงในระบบ แต่ห้ามถูกหยิบมาแทน
  });

  it("หมวดย่อยที่ไม่รู้จัก → อนุมัติไม่ได้ ไม่มีพรีวิว input เป็น null", () => {
    const r = previewApproval(item({ subCode: "zzz.unknown", typeKey: null }), resolver);
    expect(r.canApprove).toBe(false);
    expect(r.input).toBeNull();
    expect(r.preview.ok).toBe(false);
    expect(r.blockedReason).toContain("zzz.unknown");
  });

  it("ผู้ถือที่ไม่มีในระบบ → อนุมัติไม่ได้ (engine ปฏิเสธ ไม่ตกเส้นทางปกติ)", () => {
    expect(previewApproval(item({ ownerId: "ghost" }), resolver).canApprove).toBe(false);
  });

  it("canApprove เข้มกว่าพรีวิวได้ แต่ห้ามหลวมกว่า — blockedReason สอดคล้องเสมอ", () => {
    for (const a of [corpOk, corpNoEvidence, personal, item({ contactId: null }), item({ cashDate: "2026-09-10" })]) {
      const r = previewApproval(a, resolver);
      if (r.canApprove) expect(r.preview.ok).toBe(true);
      expect(r.blockedReason === null).toBe(r.canApprove);
    }
  });
});

describe("planBulkApproval — อนุมัติหมู่รายตัว", () => {
  it("มีทั้งผ่านและติด → ผ่านเฉพาะที่ควรผ่าน ข้ามที่ติดพร้อมเหตุผลจาก engine", () => {
    const plan = planBulkApproval([corpOk, personal, corpNoEvidence], resolver);
    expect(plan.approvable.map((a) => a.id)).toEqual(["d1", "d3"]);
    expect(plan.skipped).toHaveLength(1);
    expect(plan.skipped[0].item.id).toBe("d4");
    expect(plan.skipped[0].reason).toContain("ต้องแนบหลักฐาน");
  });
  it("ทุกรายการที่ผ่านต้องเป็นของที่ engine ปล่อย · ผ่าน+ข้าม = ทั้งหมด", () => {
    const all = [corpOk, personal, corpNoEvidence, item({ id: "x", contactId: null })];
    const plan = planBulkApproval(all, resolver);
    expect(plan.approvable.length + plan.skipped.length).toBe(all.length);
    for (const a of plan.approvable) expect(previewApproval(a, resolver).canApprove).toBe(true);
    for (const x of plan.skipped) expect(previewApproval(x.item, resolver).canApprove).toBe(false);
  });
  it("คิวว่าง → ไม่มีอะไรผ่าน ไม่มีอะไรข้าม · ติดทั้งหมด → ข้ามครบ", () => {
    expect(planBulkApproval([], resolver)).toEqual({ approvable: [], skipped: [] });
    expect(planBulkApproval([corpNoEvidence, { ...corpNoEvidence, id: "y" }], resolver).skipped).toHaveLength(2);
  });
});
