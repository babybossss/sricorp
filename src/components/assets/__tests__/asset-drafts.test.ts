import { describe, it, expect } from "vitest";
import { ASSETS, type AssetDraft, type AssetRef } from "@/lib/mock/assets";
import {
  BUTTON, applyPatch, canRegisterDirect, computeDiff, registerSubmitLabel, reviewActions, sheetActions,
  validateDraft, visibleDrafts, DRAFT_NOT_COUNTED,
} from "../asset-drafts";
import { STAFF, MANAGER, MANAGEMENT, SUPER_ADMIN } from "./helpers";

const rent1 = ASSETS.find((a) => a.id === "rent1") as AssetRef;

const upd = (patch: AssetDraft["patch"], over: Partial<AssetDraft> = {}): AssetDraft => ({
  id: "t", kind: "update", targetAssetId: "rent1", ownerId: "thanakorn",
  name: null, classCode: null, categoryCode: null, patch, status: "pending",
  createdBy: { id: "staff-1", name: "s" }, createdAt: "2026-10-07T10:00:00+07:00", ...over,
});
const create = (over: Partial<AssetDraft> = {}): AssetDraft => ({
  id: "t", kind: "create", targetAssetId: null, ownerId: "corp",
  name: "ที่ดินทดสอบ", classCode: "RE", categoryCode: "RE_FOR_SALE", patch: {}, status: "pending",
  createdBy: { id: "staff-1", name: "s" }, createdAt: "2026-10-07T10:00:00+07:00", ...over,
});

describe("ฐานสิทธิ์ในเทสต์ตรงกับ migration (กันเทสต์ผ่านบนสิทธิ์ที่ DB ไม่ได้ให้)", () => {
  it("ตามเอกสาร §1.2 + ข้อสั่งของลูกพี่", () => {
    expect([...STAFF].filter((p) => p.startsWith("asset.")).sort()).toEqual(["asset.draft"]);
    expect([...MANAGER].filter((p) => p.startsWith("asset.")).sort()).toEqual(["asset.draft", "asset.manage"]);
    expect(MANAGER.has("asset.value")).toBe(false); // Manager ตีราคาไม่ได้
    expect(MANAGER.has("portfolio.view_all")).toBe(false);
    expect(MANAGEMENT.has("asset.value")).toBe(true);
    expect(MANAGEMENT.has("portfolio.view_all")).toBe(true);
  });
});

describe("ปุ่มตามสิทธิ์ — ไม่โชว์ปุ่มที่กดแล้วถูกปฏิเสธ", () => {
  it("Manager ไม่เห็นปุ่มตีราคา", () => {
    expect(sheetActions(MANAGER).map((a) => a.label)).not.toContain(BUTTON.value);
    expect(sheetActions(MANAGER).map((a) => a.label)).toEqual([BUTTON.edit]);
  });
  it("Management เห็นปุ่มตีราคา", () => {
    expect(sheetActions(MANAGEMENT).map((a) => a.label)).toContain(BUTTON.value);
  });
  it("Staff ไม่เห็นปุ่มบันทึกจริง เห็นแต่ 'ส่งเป็นร่าง'", () => {
    expect(registerSubmitLabel(STAFF)).toBe(BUTTON.saveDraft);
    expect(registerSubmitLabel(STAFF)).not.toBe(BUTTON.saveDirect);
    expect(canRegisterDirect(STAFF)).toBe(false);
    expect(sheetActions(STAFF).map((a) => a.label)).toEqual([BUTTON.propose]); // แก้ตรง/ตีราคาไม่เห็น
  });
  it("Manager มี asset.manage แต่ INSERT ตรงไม่ได้ (assets_insert ต้อง portfolio.view_all) → เห็น 'ส่งเป็นร่าง'", () => {
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
    expect(visibleDrafts([create()], none, "staff-1")).toEqual([]);
  });
});

describe("ปุ่มในแผงตรวจร่าง", () => {
  it("Staff: ยกเลิกร่างตัวเองได้ · อนุมัติ/ปฏิเสธไม่ได้ · ร่างคนอื่นไม่มีปุ่มเลย", () => {
    expect(reviewActions(STAFF, create(), "staff-1")).toMatchObject({ approve: false, reject: false, cancel: true });
    expect(reviewActions(STAFF, create(), "staff-2")).toMatchObject({ approve: false, reject: false, cancel: false });
  });
  it("Manager: อนุมัติร่างแก้ไขได้ · อนุมัติร่างสร้างใหม่ไม่ได้ (DB ปฏิเสธ) แต่ปฏิเสธได้ และมีคำอธิบาย", () => {
    expect(reviewActions(MANAGER, upd({ name: "x" } as never), "m")).toMatchObject({ approve: true, reject: true });
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
  it("คิว: Staff เห็นเฉพาะร่างตัวเอง · ผู้อนุมัติเห็นทั้งหมด", () => {
    const ds = [create({ id: "a" }), create({ id: "b", createdBy: { id: "staff-2", name: "t" } })];
    expect(visibleDrafts(ds, STAFF, "staff-1").map((d) => d.id)).toEqual(["a"]);
    expect(visibleDrafts(ds, MANAGEMENT, "boss").map((d) => d.id)).toEqual(["a", "b"]);
  });
});

describe("แผง diff ของร่างชนิดแก้ไข", () => {
  it("โชว์ของเดิมเทียบของใหม่ ช่องที่เปลี่ยน/เพิ่ม", () => {
    const d = computeDiff(upd({ name: "ชื่อใหม่", funding_source: "เงินสด" }), rent1);
    expect(d.rows.find((r) => r.key === "name")).toMatchObject({ before: "คอนโดตัวอย่าง C", after: "ชื่อใหม่", change: "changed" });
    expect(d.rows.find((r) => r.key === "funding_source")).toMatchObject({ before: null, after: "เงินสด", change: "added" });
  });

  it("ช่องที่ ลบค่าออก (จากมีค่าเป็นว่าง) ต้องโผล่ใน diff พร้อมของเดิม ไม่หายไป", () => {
    // rent1 มี size_note = "28 ตร.ม..." อยู่ — patch ส่ง null มา
    const before = rent1.legal?.sizeLabel;
    expect(before).toBeTruthy();
    const d = computeDiff(upd({ size_note: null }), rent1);
    expect(d.rows).toHaveLength(1);
    expect(d.rows[0]).toMatchObject({ key: "size_note", before, after: null, change: "cleared" });
  });

  it("ลบค่าด้วยสตริงว่าง/ช่องว่างล้วน ก็นับเป็นลบเหมือนกัน (ไม่ใช่ 'แก้เป็นข้อความว่าง')", () => {
    for (const empty of ["", "   "]) {
      const d = computeDiff(upd({ size_note: empty }), rent1);
      expect(d.rows[0].change).toBe("cleared");
      expect(d.rows[0].after).toBeNull();
    }
  });

  it("ลบค่าช่องที่ว่างอยู่แล้ว = ไม่เปลี่ยน (ไม่ใช่ 'ลบค่าออก')", () => {
    const d = computeDiff(upd({ funding_source: null }), rent1); // rent1 ไม่มี fundingSource
    expect(d.rows[0].change).toBe("unchanged");
  });

  it("ช่องที่ไม่อยู่ใน patch = ไม่แตะ ไม่โผล่ในแถว (แยกจาก null)", () => {
    const d = computeDiff(upd({ name: "ใหม่" }), rent1);
    expect(d.rows.map((r) => r.key)).toEqual(["name"]);
  });

  it("ค่า 0 เป็นค่าจริง ไม่ถูกมองเป็นว่าง (เช็ค truthiness จะพลาดตรงนี้)", () => {
    const a: AssetRef = { ...rent1, ownershipPct: 0.5 };
    const d = computeDiff(upd({ ownership_pct: 0 }), a);
    expect(d.rows[0]).toMatchObject({ change: "changed", after: "0.00%" });
  });

  it("เคส 'ไม่ส่งข้อมูล': patch ว่าง → isEmpty และ validate ฟ้อง", () => {
    const d = computeDiff(upd({}), rent1);
    expect(d.isEmpty).toBe(true);
    expect(d.rows).toEqual([]);
    expect(validateDraft(upd({}), ASSETS).join()).toContain("ไม่มีช่องที่เสนอแก้");
  });

  it("เคสทรัพย์ปลายทางหาไม่เจอ → targetMissing (ห้ามเดาว่าของเดิมว่าง)", () => {
    const d = computeDiff(upd({ name: "x" }, { targetAssetId: "ghost" }), undefined);
    expect(d.targetMissing).toBe(true);
  });

  it("key ที่ไม่รู้จัก ไม่หายเงียบ", () => {
    const d = computeDiff(upd({ manager_user_id: "me", name: "x" }), rent1);
    expect(d.unknownKeys).toEqual(["manager_user_id"]);
    expect(validateDraft(upd({ manager_user_id: "me" }), ASSETS).join()).toContain("manager_user_id");
  });

  it("applyPatch: ลบค่าออกจริง และไม่แตะช่องอื่น", () => {
    const out = applyPatch(rent1, { size_note: null, name: "ใหม่" });
    expect(out.legal?.sizeLabel).toBeUndefined();
    expect(out.legal?.deedNo).toBe(rent1.legal?.deedNo);
    expect(out.name).toBe("ใหม่");
    expect(out.cost).toBe(rent1.cost);
  });
  it("applyPatch: ลบชื่อไม่ได้", () => {
    expect(() => applyPatch(rent1, { name: null })).toThrow();
  });
});

describe("เคส 'ไม่ส่งข้อมูล' — ร่างสร้างใหม่ที่ขาด 4 ช่องบังคับ", () => {
  it("ร่างครบ 4 ช่อง patch ว่าง → ใช้ได้ (D-083 ข้อ 3)", () => {
    expect(validateDraft(create(), ASSETS)).toEqual([]);
  });
  for (const [label, over] of [
    ["ไม่มีชื่อ", { name: null }],
    ["ชื่อเป็นช่องว่างล้วน", { name: "   " }],
    ["ไม่มีหมวดใหญ่", { classCode: null }],
    ["ไม่มีหมวดย่อย", { categoryCode: null }],
    ["ไม่มีผู้ถือ", { ownerId: "" }],
    ["หมวดย่อยไม่อยู่ในหมวดใหญ่", { classCode: "PAPER", categoryCode: "RE_RENTAL" }],
    ["ผู้ถือที่ไม่มีในระบบ", { ownerId: "nobody" }],
  ] as [string, Partial<AssetDraft>][]) {
    it(`${label} → ปฏิเสธ`, () => {
      expect(validateDraft(create(over), ASSETS).length).toBeGreaterThan(0);
    });
  }
  it("ร่างแก้ไขที่ไม่ชี้ทรัพย์ → ปฏิเสธ", () => {
    expect(validateDraft(upd({ name: "x" }, { targetAssetId: null }), ASSETS).length).toBeGreaterThan(0);
  });
  it("ร่างแก้ไขที่ผู้ถือไม่ตรงทรัพย์ → ปฏิเสธ", () => {
    expect(validateDraft(upd({ name: "x" }, { ownerId: "corp" }), ASSETS).length).toBeGreaterThan(0);
  });
  it("ร่างแก้ไขที่ใส่ name/หมวด นอก patch → ปฏิเสธ (CHECK asset_drafts_update_uses_patch)", () => {
    expect(validateDraft(upd({ location: "x" }, { name: "x" }), ASSETS).length).toBeGreaterThan(0);
  });
  it("สัดส่วนถือครองนอกช่วง → ปฏิเสธ", () => {
    for (const v of [0, 1.5, -1]) expect(validateDraft(upd({ ownership_pct: v }), ASSETS).length).toBeGreaterThan(0);
    expect(validateDraft(upd({ ownership_pct: 0.5 }), ASSETS)).toEqual([]);
  });
});

it("ข้อความเตือนที่ลูกพี่สั่งอยู่ครบคำ", () => {
  expect(DRAFT_NOT_COUNTED).toBe("ร่างนี้ยังไม่ถูกนับในมูลค่าพอร์ต ต้องรออนุมัติ");
});

it("ตัวอ่านสิทธิ์จาก migration พังเสียงดังเมื่อหาแถวไม่เจอ (ไม่คืนชุดว่างเงียบๆ)", () => {
  // ถ้าตัวอ่านคืนชุดว่างเงียบๆ เทสต์ปุ่มข้างบนจะ "ผ่าน" บนสิทธิ์ที่ไม่มีอยู่จริง
  expect(STAFF.size).toBeGreaterThan(0);
  expect(MANAGEMENT.size).toBeGreaterThan(STAFF.size);
});
