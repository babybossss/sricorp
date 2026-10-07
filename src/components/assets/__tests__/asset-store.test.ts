import { describe, it, expect, beforeEach } from "vitest";
import { ASSETS, ASSET_DRAFTS, portfolioTotals, holdingMix, type AssetRef } from "@/lib/mock/assets";
import { AssetDenied, AssetInvalid, resetAssetStore, useAssetStore, type NewAssetInput } from "../asset-store";
import { STAFF, MANAGER, MANAGEMENT, actor } from "./helpers";

const store = () => useAssetStore.getState();
const staff = actor("staff-1", STAFF);
const manager = actor("mgr-1", MANAGER);
const boss = actor("boss-1", MANAGEMENT);

const INPUT: NewAssetInput = {
  name: "ที่ดินทดสอบ H",
  classCode: "RE",
  categoryCode: "RE_FOR_SALE",
  ownerId: "corp",
  patch: { location: "บางนา", size_note: "1 ไร่" },
};

/** ทุกตัวเลขที่ Dashboard และยอดรวมท้ายตารางแสดง — หน้าจอเรียกฟังก์ชันชุดนี้ชุดเดียวกัน */
const measure = () => ({
  totals: portfolioTotals(store().assets),
  mix: holdingMix(store().assets),
  rowCount: store().assets.length,
});

beforeEach(() => resetAssetStore());

describe("ร่างต้องไม่ถูกนับในยอดรวม (วัดก่อน/หลังสร้างร่าง)", () => {
  it("ยอดตั้งต้นตรงกับทะเบียนที่อนุมัติแล้ว (ค่าตายตัว ไม่ใช่เทียบกับตัวเอง)", () => {
    const m = measure();
    expect(m.totals.count).toBe(5);
    expect(m.totals.cost).toBe(15_700_000);
    expect(m.totals.value).toBe(18_400_000);
    expect(m.totals.netMonth).toBeCloseTo(
      ASSETS.reduce((t, a) => t + portfolioTotals([a]).netMonth, 0),
      6
    );
    // ในสโตร์มีร่างตัวอย่างค้างอยู่แล้ว แต่ไม่อยู่ในตัวเลขเหล่านี้
    expect(store().drafts.filter((d) => d.status === "pending").length).toBe(ASSET_DRAFTS.length);
  });

  it("สร้างร่างใหม่ (create) → ยอดรวม · สัดส่วน · จำนวนแถว ไม่เปลี่ยนแม้แต่หน่วยเดียว", () => {
    const before = measure();
    const d = store().submitDraft(INPUT, staff);
    expect(store().drafts.some((x) => x.id === d.id && x.status === "pending")).toBe(true); // ร่างเข้าคิวจริง
    expect(measure()).toEqual(before);
  });

  it("สร้างร่างแก้ไข (update) → ยอดรวมไม่เปลี่ยน และทรัพย์เดิมยังเป็นค่าเดิม", () => {
    const before = measure();
    const nameBefore = store().assets.find((a) => a.id === "rent1")?.name;
    store().proposeUpdate("rent1", { name: "ชื่อใหม่", size_note: null }, staff);
    expect(measure()).toEqual(before);
    expect(store().assets.find((a) => a.id === "rent1")?.name).toBe(nameBefore);
  });

  it("ปฏิเสธ/ยกเลิกร่าง → ยอดรวมไม่เปลี่ยน", () => {
    const before = measure();
    const d = store().submitDraft(INPUT, staff);
    store().cancelDraft(d.id, staff);
    store().rejectDraft("d1", "ข้อมูลไม่ครบ", boss);
    expect(measure()).toEqual(before);
  });

  it("ผู้ใช้ที่แค่เสนอร่างหลายรอบ ทรัพย์ในทะเบียนไม่เพิ่มสักชิ้น", () => {
    for (let i = 0; i < 5; i++) store().submitDraft({ ...INPUT, name: `ร่าง ${i}` }, staff);
    expect(store().assets).toHaveLength(ASSETS.length);
  });

  it("เทียบกับ 'พอร์ตที่ผิด' : ถ้าเอาร่างไปรวมในทะเบียน การวัดนี้ต้องจับได้ (ยืนยันว่าเทสต์ไวพอ)", () => {
    // จำลองบั๊ก: ใครสักคนแปลงร่างเป็นทรัพย์แล้วยัดเข้ารวมยอด
    const before = measure();
    store().submitDraft(INPUT, staff);
    const leaked: AssetRef[] = [
      ...store().assets,
      ...store().drafts.filter((d) => d.status === "pending").map(
        (d): AssetRef => ({
          id: d.id, name: d.name ?? "", kind: "other", holding: "unset", ownerId: d.ownerId,
          cost: 0, status: "active", recurring: [],
        })
      ),
    ];
    expect(portfolioTotals(leaked)).not.toEqual(before.totals);
  });

  it("อนุมัติร่างแล้วต่างหากที่ทรัพย์เข้าทะเบียน (+1 ชิ้น) — ตัวเลขเงินยังเท่าเดิมเพราะยังไม่มีต้นทุน", () => {
    const before = measure();
    const d = store().submitDraft(INPUT, staff);
    expect(measure()).toEqual(before);
    store().approveDraft(d.id, boss);
    const after = measure();
    expect(after.totals.count).toBe(before.totals.count + 1);
    expect(after.totals.cost).toBe(before.totals.cost);
    const created = store().assets.find((a) => a.name === INPUT.name);
    expect(created).toMatchObject({ classCode: "RE", categoryCode: "RE_FOR_SALE", holding: "for_sale", ownerId: "corp" });
    expect(created?.location?.address).toBe("บางนา");
  });
});

describe("สิทธิ์ — ต่อให้ปุ่มถูกเรียกตรงๆ ก็ไม่ผ่าน (เลียนแบบ RLS)", () => {
  it("Staff บันทึกเป็นทรัพย์จริงตรงๆ ไม่ได้ และทะเบียนไม่เปลี่ยน", () => {
    const before = measure();
    expect(() => store().registerAsset(INPUT, staff)).toThrow(AssetDenied);
    expect(measure()).toEqual(before);
  });
  it("Manager บันทึกทรัพย์ใหม่ตรงๆ ไม่ได้ (ต้องผ่านร่าง)", () => {
    expect(() => store().registerAsset(INPUT, manager)).toThrow(AssetDenied);
  });
  it("Management บันทึกตรงได้", () => {
    store().registerAsset(INPUT, boss);
    expect(store().assets).toHaveLength(ASSETS.length + 1);
  });
  it("Staff อนุมัติ/ปฏิเสธไม่ได้ · ยกเลิกร่างคนอื่นไม่ได้", () => {
    expect(() => store().approveDraft("d1", staff)).toThrow(AssetDenied);
    expect(() => store().rejectDraft("d1", "x", staff)).toThrow(AssetDenied);
    expect(() => store().cancelDraft("d1", staff)).toThrow(AssetDenied); // d1 เป็นของ mock-staff-1
  });
  it("Manager อนุมัติร่างสร้างใหม่ไม่ได้ (assets_insert ต้อง portfolio.view_all) แต่อนุมัติร่างแก้ไขได้", () => {
    const c = store().submitDraft(INPUT, manager);
    expect(() => store().approveDraft(c.id, manager)).toThrow(AssetDenied);
    const u = store().proposeUpdate("rent1", { name: "ชื่อที่ Manager ร่างเอง" }, manager);
    store().approveDraft(u.id, manager); // อนุมัติของตัวเอง
    const done = store().drafts.find((d) => d.id === u.id);
    expect(done).toMatchObject({ status: "approved", reviewedBy: { id: "mgr-1" }, createdBy: { id: "mgr-1" } });
    expect(store().assets.find((a) => a.id === "rent1")?.name).toBe("ชื่อที่ Manager ร่างเอง");
  });
  it("ไม่มีสิทธิ์ asset.draft เสนอร่างไม่ได้", () => {
    expect(() => store().submitDraft(INPUT, actor("x", new Set()))).toThrow(AssetDenied);
    expect(() => store().proposeUpdate("rent1", { name: "x" }, actor("x", new Set()))).toThrow(AssetDenied);
  });
});

describe("เคส 'ไม่ส่งข้อมูล' — store ไม่เติมค่าเริ่มต้นให้", () => {
  for (const [label, patch] of [
    ["ไม่มีชื่อ", { name: "" }],
    ["ไม่มีหมวดใหญ่", { classCode: "" }],
    ["ไม่มีหมวดย่อย", { categoryCode: "" }],
    ["ไม่มีผู้ถือ", { ownerId: "" }],
  ] as [string, Partial<NewAssetInput>][]) {
    it(`ร่างที่${label} → ปฏิเสธ และคิวไม่เพิ่ม`, () => {
      const n = store().drafts.length;
      expect(() => store().submitDraft({ ...INPUT, ...patch }, staff)).toThrow(AssetInvalid);
      expect(() => store().registerAsset({ ...INPUT, ...patch }, boss)).toThrow(AssetInvalid);
      expect(store().drafts).toHaveLength(n);
      expect(store().assets).toHaveLength(ASSETS.length);
    });
  }
  it("ร่างที่ไม่ส่ง patch เลย (undefined) ผ่านได้ — 4 ช่องพอ", () => {
    expect(() => store().submitDraft({ name: "A", classCode: "RE", categoryCode: "RE_RENTAL", ownerId: "corp" }, staff)).not.toThrow();
  });
  it("ร่างแก้ไขที่ patch ว่าง → ปฏิเสธ", () => {
    expect(() => store().proposeUpdate("rent1", {}, staff)).toThrow(AssetInvalid);
  });
  it("ร่างแก้ไขที่ชี้ทรัพย์ที่ไม่มี → ปฏิเสธ", () => {
    expect(() => store().proposeUpdate("ghost", { name: "x" }, staff)).toThrow(AssetInvalid);
  });
  it("ร่างแก้ไขที่พยายามแก้ manager_user_id / owner_id ผ่าน patch → ปฏิเสธ", () => {
    expect(() => store().proposeUpdate("rent1", { manager_user_id: "me" }, staff)).toThrow(AssetInvalid);
    expect(() => store().proposeUpdate("rent1", { owner_id: "corp" }, staff)).toThrow(AssetInvalid);
  });
  it("ปฏิเสธต้องมีเหตุผล", () => {
    expect(() => store().rejectDraft("d1", "   ", boss)).toThrow(AssetInvalid);
    expect(store().drafts.find((d) => d.id === "d1")?.status).toBe("pending");
  });
  it("อนุมัติร่างที่ตัดสินแล้วซ้ำ → ปฏิเสธ ไม่สร้างทรัพย์ซ้ำ", () => {
    store().approveDraft("d1", boss);
    const n = store().assets.length;
    expect(() => store().approveDraft("d1", boss)).toThrow(AssetInvalid);
    expect(store().assets).toHaveLength(n);
  });
  it("ร่างเก่าที่ข้อมูลเพี้ยน (ทรัพย์เป้าหมายหายไป) อนุมัติไม่ได้", () => {
    useAssetStore.setState({ assets: store().assets.filter((a) => a.id !== "rent1") });
    expect(() => store().approveDraft("d2", boss)).toThrow(AssetInvalid);
  });
});

describe("อนุมัติร่างแก้ไข — ใช้ผลตาม diff ที่ผู้อนุมัติเห็น", () => {
  it("d2: เปลี่ยนชื่อ · ลบขนาด · เพิ่มแหล่งเงินทุน ตามที่ร่างระบุ ช่องอื่นไม่ถูกแตะ", () => {
    const before = store().assets.find((a) => a.id === "rent1") as AssetRef;
    store().approveDraft("d2", boss);
    const after = store().assets.find((a) => a.id === "rent1") as AssetRef;
    expect(after.name).toBe("คอนโดตัวอย่าง C (ห้อง 12A)");
    expect(after.legal?.sizeLabel).toBeUndefined(); // ลบจริง
    expect(after.fundingSource).toBe("เงินกู้ SCB + เงินสะสม");
    expect(after.legal?.deedNo).toBe(before.legal?.deedNo);
    expect(after.cost).toBe(before.cost);
    expect(after.valuation).toEqual(before.valuation);
  });
});
