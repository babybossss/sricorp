import { describe, expect, it } from "vitest";
import type { Tag, TagKind } from "@/components/tags/types";
import { checkTagSelection, pruneWeights, withSoleTagWeight } from "../selection";

const kinds: TagKind[] = [
  { key: "project", nameTh: "โปรเจกต์", allowsMulti: true, aggregateNoteTh: "x", requiresAllocation: true },
  { key: "label", nameTh: "ป้ายกำกับ", allowsMulti: true, aggregateNoteTh: "x", requiresAllocation: false },
  { key: "single", nameTh: "แผนก", allowsMulti: false, aggregateNoteTh: "x", requiresAllocation: false },
];
const tag = (id: string, kind: string, over: Partial<Tag> = {}): Tag => ({ id, kind, code: id, nameTh: `N-${id}`, isActive: true, colorToken: null, ...over });
const tags = [tag("p1", "project"), tag("p2", "project"), tag("l1", "label"), tag("s1", "single"), tag("s2", "single"), tag("off", "project", { isActive: false }), tag("x1", "mystery")];
const catalog = { kinds, tags };

describe("checkTagSelection · ตัวตรวจเดียวของทั้งฟอร์มและ server", () => {
  it("project 60/40 + label → แยก tag_ids / tag_weights ถูกชนิดตามคอนฟิก", () => {
    const r = checkTagSelection({ tagIds: ["p1", "p2", "l1"], weights: { p1: 0.6, p2: 0.4 } }, catalog);
    expect(r).toMatchObject({ ok: true, labelTagIds: ["l1"], tagWeights: { p1: 0.6, p2: 0.4 } });
  });

  it("เปลี่ยนคอนฟิกให้ label ถ่วงน้ำหนักด้วย → ตัวตรวจตามทันโดยไม่แก้โค้ด (ไม่เช็คชื่อ 'project')", () => {
    const flipped = { kinds: kinds.map((k) => (k.key === "label" ? { ...k, requiresAllocation: true } : k)), tags };
    expect(checkTagSelection({ tagIds: ["l1"], weights: {} }, flipped).ok).toBe(false);
    expect(checkTagSelection({ tagIds: ["l1"], weights: { l1: 1 } }, flipped).ok).toBe(true);
  });

  it("ไม่เลือกอะไรเลย → ผ่าน (ไม่มี tag = ไม่มีอะไรต้องแบ่ง)", () => {
    expect(checkTagSelection({ tagIds: [] }, catalog)).toMatchObject({ ok: true, labelTagIds: [], tagWeights: {} });
  });

  it("project ไม่ส่งน้ำหนัก (weights ไม่มี) → ปฏิเสธ แม้ label ผ่าน", () => {
    const r = checkTagSelection({ tagIds: ["p1", "l1"] }, catalog);
    expect(r.ok).toBe(false);
  });

  it("น้ำหนักกำพร้า (ของ tag ที่ไม่ได้เลือก) → ปฏิเสธ", () => {
    expect(checkTagSelection({ tagIds: ["p1"], weights: { p1: 1, p2: 0.2 } }, catalog).ok).toBe(false);
  });

  it("ชนิดที่ติดได้อันเดียวแต่เลือกสอง → ปฏิเสธ", () => {
    const r = checkTagSelection({ tagIds: ["s1", "s2"] }, catalog);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.issues.join()).toMatch(/อันเดียว/);
  });

  it("tag ปิดแล้ว / ไม่มี / ชนิดไม่รู้จัก / ซ้ำ → ปฏิเสธ", () => {
    for (const ids of [["off"], ["nope"], ["x1"], ["p1", "p1"]]) {
      expect(checkTagSelection({ tagIds: ids, weights: { p1: 1, off: 1 } }, catalog).ok, ids.join()).toBe(false);
    }
  });
});

describe("withSoleTagWeight · เติม 100% เฉพาะ project อันเดียวที่ยังว่าง", () => {
  const sel = (...ids: string[]) => tags.filter((t) => ids.includes(t.id));
  it("อันเดียวไม่มีน้ำหนัก → 1", () => expect(withSoleTagWeight(sel("p1"), kinds, {})).toEqual({ p1: 1 }));
  it("อันเดียวมี null → 1", () => expect(withSoleTagWeight(sel("p1"), kinds, { p1: null })).toEqual({ p1: 1 }));
  it("อันเดียวที่ผู้ใช้กรอกไว้แล้ว → ไม่แตะ", () => expect(withSoleTagWeight(sel("p1"), kinds, { p1: 0.5 })).toEqual({ p1: 0.5 }));
  it("สองอัน → ไม่เติมอะไร (นั่นคือการเดา)", () => expect(withSoleTagWeight(sel("p1", "p2"), kinds, {})).toEqual({}));
  it("label อันเดียว → ไม่เติม", () => expect(withSoleTagWeight(sel("l1"), kinds, {})).toEqual({}));
});

describe("pruneWeights", () => {
  it("ตัดน้ำหนักของ tag ที่ถูกเอาออกแล้ว", () => expect(pruneWeights(["p1"], { p1: 0.5, p2: 0.5 })).toEqual({ p1: 0.5 }));
});
