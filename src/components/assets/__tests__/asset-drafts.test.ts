import { describe, it, expect } from "vitest";
import type { AssetView, DraftPatch, DraftView, Taxonomy } from "@/lib/db/assets-model";
import {
  BUTTON, canRegisterDirect, computeDiff, parseTags, patchField, registerSubmitLabel, reviewActions, sheetActions,
  validateDraft, DRAFT_NOT_COUNTED, norm, type DraftContext, type DraftInput,
} from "../asset-drafts";
import { STAFF, MANAGER, MANAGEMENT, SUPER_ADMIN } from "./helpers";

const TAX: Taxonomy = {
  classes: [
    { id: "cls-re", code: "RE", nameTh: "อสังหาริมทรัพย์", sortOrder: 1 },
    { id: "cls-paper", code: "PAPER", nameTh: "สินทรัพย์กระดาษ", sortOrder: 2 },
  ],
  categories: [
    { id: "cat-rent", classId: "cls-re", code: "RE_RENTAL", nameTh: "ปล่อยเช่า", isActive: true, sortOrder: 1 },
    { id: "cat-sale", classId: "cls-re", code: "RE_FOR_SALE", nameTh: "รอขาย", isActive: true, sortOrder: 2 },
    { id: "cat-old", classId: "cls-re", code: "RE_OLD", nameTh: "เลิกใช้", isActive: false, sortOrder: 3 },
    { id: "cat-stock", classId: "cls-paper", code: "PAPER_STOCK", nameTh: "หุ้น", isActive: true, sortOrder: 4 },
  ],
};
const rent1: AssetView = {
  id: "rent1", code: "RE-0001", name: "คอนโดตัวอย่าง C", classId: "cls-re", categoryId: "cat-rent", ownerId: "tk", holdingNature: "beneficial",
  status: "active", acquiredDate: null, disposedDate: null, location: "พหลโยธิน 24", ticker: null, currency: "THB", tags: ["คอนโด"],
  ownershipPct: 0.5, fundingSource: null, propertyType: "คอนโด", sizeNote: "28 ตร.ม.", createdAt: "2026-01-01T00:00:00Z",
  classCode: "RE", className: "อสังหาริมทรัพย์", categoryCode: "RE_RENTAL", categoryName: "ปล่อยเช่า",
};
const CTX: DraftContext = { assets: [rent1], ownerIds: ["tk", "corp"], taxonomy: TAX };

const upd = (patch: DraftPatch, over: Partial<DraftView> = {}): DraftView => ({
  id: "t", kind: "update", targetAssetId: "rent1", ownerId: "tk", name: null, classId: null, categoryId: null, patch, note: null, status: "pending",
  rejectReason: null, appliedAssetId: null, createdBy: { id: "staff-1", name: "s" }, createdAt: "2026-10-07T10:00:00+07:00", reviewedBy: null, reviewedAt: null, ...over,
});
const create = (over: Partial<DraftView> = {}): DraftView => ({
  ...upd({}), kind: "create", targetAssetId: null, ownerId: "corp", name: "ที่ดินทดสอบ", classId: "cls-re", categoryId: "cat-sale", ...over,
});
const input = (d: DraftView): DraftInput => d;

describe("ฐานสิทธิ์ในเทสต์ตรงกับ migration (กันเทสต์ผ่านบนสิทธิ์ที่ DB ไม่ได้ให้)", () => {
  it("ตามเอกสาร §1.2 + ข้อสั่งของลูกพี่", () => {
    expect([...STAFF].filter((p) => p.startsWith("asset.")).sort()).toEqual(["asset.draft"]);
    expect([...MANAGER].filter((p) => p.startsWith("asset.")).sort()).toEqual(["asset.draft", "asset.manage"]);
    expect(MANAGER.has("asset.value")).toBe(false);
    expect(MANAGER.has("portfolio.view_all")).toBe(false);
    expect(MANAGEMENT.has("asset.value")).toBe(true);
    expect(MANAGEMENT.has("portfolio.view_all")).toBe(true);
  });
});

describe("ปุ่มตามสิทธิ์ — ไม่โชว์ปุ่มที่กดแล้วถูกปฏิเสธ", () => {
  it("Manager ไม่เห็นปุ่มตีราคา", () => {
    expect(sheetActions(MANAGER).map((a) => a.label)).toEqual([BUTTON.edit]);
  });
  it("Management เห็นปุ่มตีราคา", () => {
    expect(sheetActions(MANAGEMENT).map((a) => a.label)).toContain(BUTTON.value);
  });
  it("Staff ไม่เห็นปุ่มบันทึกจริง เห็นแต่ 'ส่งเป็นร่าง'", () => {
    expect(registerSubmitLabel(STAFF)).toBe(BUTTON.saveDraft);
    expect(canRegisterDirect(STAFF)).toBe(false);
    expect(sheetActions(STAFF).map((a) => a.label)).toEqual([BUTTON.propose]);
  });
  it("Manager มี asset.manage แต่ INSERT ตรงไม่ได้ → เห็น 'ส่งเป็นร่าง'", () => {
    expect(registerSubmitLabel(MANAGER)).toBe(BUTTON.saveDraft);
  });
  it("Management / Super Admin บันทึกจริงได้", () => {
    expect(registerSubmitLabel(MANAGEMENT)).toBe(BUTTON.saveDirect);
    expect(registerSubmitLabel(SUPER_ADMIN)).toBe(BUTTON.saveDirect);
  });
  it("ไม่มีสิทธิ์เลย (เคส 'ไม่ส่งข้อมูล') → ไม่มีปุ่ม ไม่ใช่ปุ่มเริ่มต้น", () => {
    const none = new Set<never>();
    expect(registerSubmitLabel(none)).toBeNull();
    expect(sheetActions(none)).toEqual([]);
    expect(reviewActions(none, create(), "x")).toMatchObject({ approve: false, reject: false, cancel: false });
  });
});

describe("ปุ่มในแผงตรวจร่าง", () => {
  it("Staff: ยกเลิกร่างตัวเองได้ · อนุมัติ/ปฏิเสธไม่ได้ · ร่างคนอื่นไม่มีปุ่มเลย", () => {
    expect(reviewActions(STAFF, create(), "staff-1")).toMatchObject({ approve: false, reject: false, cancel: true });
    expect(reviewActions(STAFF, create(), "staff-2")).toMatchObject({ approve: false, reject: false, cancel: false });
  });
  it("Manager: อนุมัติร่างแก้ไขได้ · อนุมัติร่างสร้างใหม่ไม่ได้ แต่ปฏิเสธได้ และมีคำอธิบาย", () => {
    expect(reviewActions(MANAGER, upd({ location: "x" }), "m")).toMatchObject({ approve: true, reject: true });
    const c = reviewActions(MANAGER, create(), "m");
    expect(c).toMatchObject({ approve: false, reject: true });
    expect(c.approveNote).toBeTruthy();
  });
  it("Management อนุมัติได้ทั้งสองชนิด", () => {
    expect(reviewActions(MANAGEMENT, create(), "m").approve).toBe(true);
    expect(reviewActions(MANAGEMENT, upd({ location: "x" }), "m").approve).toBe(true);
  });
  it("ร่างที่ตัดสินแล้ว ไม่มีปุ่มใดๆ", () => {
    for (const status of ["approved", "rejected", "cancelled"] as const)
      expect(reviewActions(MANAGEMENT, create({ status }), "m")).toMatchObject({ approve: false, reject: false, cancel: false });
  });
});

describe("แผง diff ของร่างชนิดแก้ไข", () => {
  it("โชว์ของเดิมเทียบของใหม่ ช่องที่เปลี่ยน/เพิ่ม", () => {
    const d = computeDiff(upd({ name: "ชื่อใหม่", funding_source: "เงินสด" }), rent1);
    expect(d.rows.find((r) => r.key === "name")).toMatchObject({ before: "คอนโดตัวอย่าง C", after: "ชื่อใหม่", change: "changed" });
    expect(d.rows.find((r) => r.key === "funding_source")).toMatchObject({ before: null, after: "เงินสด", change: "added" });
  });

  it("ช่องที่ ลบค่าออก ต้องโผล่ใน diff พร้อมของเดิม ไม่หายไป", () => {
    const d = computeDiff(upd({ size_note: null }), rent1);
    expect(d.rows).toHaveLength(1);
    expect(d.rows[0]).toMatchObject({ key: "size_note", before: "28 ตร.ม.", after: null, change: "cleared" });
  });

  it("ลบค่าด้วยสตริงว่าง/ช่องว่างล้วน ก็นับเป็นลบเหมือนกัน", () => {
    for (const empty of ["", "   "]) {
      const d = computeDiff(upd({ size_note: empty }), rent1);
      expect(d.rows[0].change).toBe("cleared");
      expect(d.rows[0].after).toBeNull();
    }
  });

  it("ลบค่าช่องที่ว่างอยู่แล้ว = ไม่เปลี่ยน", () => {
    expect(computeDiff(upd({ funding_source: null }), rent1).rows[0].change).toBe("unchanged");
  });

  it("ช่องที่ไม่อยู่ใน patch = ไม่แตะ ไม่โผล่ในแถว (แยกจาก null)", () => {
    expect(computeDiff(upd({ name: "ใหม่" }), rent1).rows.map((r) => r.key)).toEqual(["name"]);
  });

  it("ค่า 0 เป็นค่าจริง ไม่ถูกมองเป็นว่าง (เช็ค truthiness จะพลาดตรงนี้)", () => {
    const d = computeDiff(upd({ ownership_pct: 0 }), rent1);
    expect(d.rows[0]).toMatchObject({ change: "changed", after: "0.00%", before: "50.00%" });
  });

  it("ป้ายกำกับ: เทียบเป็นรายการ ลำดับเปลี่ยนนับว่าเปลี่ยน, ชุดเท่าเดิมไม่เปลี่ยน", () => {
    expect(computeDiff(upd({ tags: ["คอนโด"] }), rent1).rows[0].change).toBe("unchanged");
    expect(computeDiff(upd({ tags: ["คอนโด", "เช่า"] }), rent1).rows[0]).toMatchObject({ change: "changed", after: "คอนโด, เช่า" });
    expect(computeDiff(upd({ tags: [] }), rent1).rows[0].change).toBe("cleared");
  });

  it("เคส 'ไม่ส่งข้อมูล': patch ว่าง → isEmpty และ validate ฟ้อง", () => {
    expect(computeDiff(upd({}), rent1).isEmpty).toBe(true);
    expect(validateDraft(input(upd({})), CTX).join()).toContain("ไม่มีช่องที่เสนอแก้");
  });

  it("ทรัพย์ปลายทางหาไม่เจอ → targetMissing (ห้ามเดาว่าของเดิมว่าง)", () => {
    expect(computeDiff(upd({ name: "x" }, { targetAssetId: "ghost" }), undefined).targetMissing).toBe(true);
  });

  it("key ที่ไม่รู้จัก ไม่หายเงียบ", () => {
    expect(computeDiff(upd({ manager_user_id: "me", name: "x" }), rent1).unknownKeys).toEqual(["manager_user_id"]);
    expect(validateDraft(input(upd({ manager_user_id: "me" })), CTX).join()).toContain("manager_user_id");
  });

  it("ช่องที่ผู้ดูไม่มีสิทธิ์เห็น (null จาก DB) ไม่ทำให้ diff เดาว่าของเดิมมีค่า", () => {
    const hidden: AssetView = { ...rent1, location: null, ownershipPct: null };
    expect(computeDiff(upd({ location: "ใหม่" }), hidden).rows[0]).toMatchObject({ before: null, change: "added" });
  });
});

describe("เคส 'ไม่ส่งข้อมูล' — ร่างสร้างใหม่ที่ขาด 4 ช่องบังคับ", () => {
  it("ร่างครบ 4 ช่อง patch ว่าง → ใช้ได้ (D-083 ข้อ 3)", () => {
    expect(validateDraft(input(create()), CTX)).toEqual([]);
  });
  for (const [label, over] of [
    ["ไม่มีชื่อ", { name: null }],
    ["ชื่อเป็นช่องว่างล้วน", { name: "   " }],
    ["ไม่มีหมวดใหญ่", { classId: null }],
    ["ไม่มีหมวดย่อย", { categoryId: null }],
    ["ไม่มีผู้ถือ", { ownerId: "" }],
    ["หมวดย่อยไม่อยู่ในหมวดใหญ่", { classId: "cls-paper", categoryId: "cat-rent" }],
    ["หมวดย่อยที่เลิกใช้แล้ว", { categoryId: "cat-old" }],
    ["ผู้ถือที่ไม่มีในระบบ", { ownerId: "nobody" }],
    ["ชื่อซ้ำใน patch", { patch: { name: "x" } }],
    ["ชี้ทรัพย์เดิม", { targetAssetId: "rent1" }],
  ] as [string, Partial<DraftView>][]) {
    it(`${label} → ปฏิเสธ`, () => {
      expect(validateDraft(input(create(over)), CTX).length).toBeGreaterThan(0);
    });
  }
  it("ร่างแก้ไขที่ไม่ชี้ทรัพย์ → ปฏิเสธ", () => {
    expect(validateDraft(input(upd({ name: "x" }, { targetAssetId: null })), CTX).length).toBeGreaterThan(0);
  });
  it("ร่างแก้ไขที่ผู้ถือไม่ตรงทรัพย์ → ปฏิเสธ", () => {
    expect(validateDraft(input(upd({ name: "x" }, { ownerId: "corp" })), CTX).length).toBeGreaterThan(0);
  });
  it("ร่างแก้ไขที่ใส่ name/หมวด นอก patch → ปฏิเสธ", () => {
    expect(validateDraft(input(upd({ location: "x" }, { name: "x" })), CTX).length).toBeGreaterThan(0);
  });
  it("ลบชื่อไม่ได้ · สัดส่วนถือครองนอกช่วง → ปฏิเสธ", () => {
    expect(validateDraft(input(upd({ name: null })), CTX).length).toBeGreaterThan(0);
    for (const v of [0, 1.5, -1]) expect(validateDraft(input(upd({ ownership_pct: v })), CTX).length).toBeGreaterThan(0);
    expect(validateDraft(input(upd({ ownership_pct: 0.5 })), CTX)).toEqual([]);
  });
});

describe("ช่องกรอก: แปลงข้อความ ↔ ค่าใน patch", () => {
  const pct = patchField("ownership_pct")!;
  it("สัดส่วนถือครองกรอกเป็นเปอร์เซ็นต์ เก็บเป็นเศษส่วน", () => {
    expect(pct.parse("50")).toEqual({ ok: true, value: 0.5 });
    expect(pct.parse("33.33")).toEqual({ ok: true, value: 0.3333 });
    expect(pct.parse("")).toEqual({ ok: true, value: null });
    for (const bad of ["abc", "0", "101", "-5"]) expect(pct.parse(bad).ok).toBe(false);
    expect(pct.toInput(0.5)).toBe("50");
  });
  it("ป้ายกำกับ: แยกด้วยจุลภาค ตัดซ้ำ ตัดช่องว่าง ว่าง=null", () => {
    expect(parseTags(" คอนโด, ห้อง 12A ,คอนโด,, ")).toEqual({ ok: true, value: ["คอนโด", "ห้อง 12A"] });
    expect(parseTags("  ")).toEqual({ ok: true, value: null });
    expect(parseTags("x".repeat(41)).ok).toBe(false);
    expect(parseTags(Array.from({ length: 21 }, (_, i) => `t${i}`).join(",")).ok).toBe(false);
  });
  it("norm แยก 0 / ว่าง / อาร์เรย์ว่าง", () => {
    expect(norm(0)).toBe(0);
    expect(norm("  ")).toBeNull();
    expect(norm([])).toBeNull();
    expect(norm([" a ", ""])).toEqual(["a"]);
  });
});

it("ข้อความเตือนที่ลูกพี่สั่งอยู่ครบคำ", () => {
  expect(DRAFT_NOT_COUNTED).toBe("ร่างนี้ยังไม่ถูกนับในมูลค่าพอร์ต ต้องรออนุมัติ");
});

it("ตัวอ่านสิทธิ์จาก migration พังเสียงดังเมื่อหาแถวไม่เจอ (ไม่คืนชุดว่างเงียบๆ)", () => {
  expect(STAFF.size).toBeGreaterThan(0);
  expect(MANAGEMENT.size).toBeGreaterThan(STAFF.size);
});
