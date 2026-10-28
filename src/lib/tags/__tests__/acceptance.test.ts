import { describe, expect, it } from "vitest";
import { hiddenKindsMessage, parseAcceptedKinds, refusedKinds, splitByAcceptance } from "../acceptance";
import type { Tag, TagKind } from "@/components/tags/types";

const kinds: TagKind[] = [
  { key: "project", nameTh: "โปรเจกต์", allowsMulti: true, aggregateNoteTh: "x", requiresAllocation: true },
  { key: "label", nameTh: "ป้ายกำกับ", allowsMulti: true, aggregateNoteTh: "x", requiresAllocation: false },
];
const t = (id: string, kind: string): Tag => ({ id, kind, code: id, nameTh: id, isActive: true, colorToken: null });
const tags = [t("p1", "project"), t("l1", "label")];
const cat = { kinds, tags };

describe("parseAcceptedKinds", () => {
  it("รับ array ของข้อความ และ { kinds: [...] }", () => {
    expect([...parseAcceptedKinds(["project"])!]).toEqual(["project"]);
    expect([...parseAcceptedKinds({ kinds: ["project", "label"] })!]).toEqual(["project", "label"]);
    expect(parseAcceptedKinds([])!.size).toBe(0); // อ่านได้ และไม่รับชนิดไหนเลย ≠ อ่านไม่ได้
  });
  it("รูปอื่นทั้งหมด = อ่านไม่ได้ (null) ไม่เดา", () => {
    for (const bad of [null, undefined, "project", 1, {}, { kinds: "project" }, [1], [""], ["project", null], [{ kind: "project" }]]) {
      expect(parseAcceptedKinds(bad), JSON.stringify(bad)).toBeNull();
    }
  });
});

describe("splitByAcceptance", () => {
  it("ชนิดที่ประตูไม่รับไม่โผล่ให้เลือก (ทั้งชนิดและ tag) · ชนิดที่รับยังอยู่ครบ", () => {
    const r = splitByAcceptance(cat, new Set(["project"]));
    expect(r.catalog.kinds.map((k) => k.key)).toEqual(["project"]);
    expect(r.catalog.tags.map((x) => x.id)).toEqual(["p1"]);
    expect(r.hidden).toEqual([{ key: "label", nameTh: "ป้ายกำกับ", reason: "not_open" }]);
  });
  it("รับทุกชนิด → ไม่ซ่อนอะไร", () => {
    const r = splitByAcceptance(cat, new Set(["project", "label"]));
    expect(r.catalog.tags).toHaveLength(2);
    expect(r.hidden).toEqual([]);
  });
  it("อ่านรายชื่อไม่ได้ (null) → ซ่อนทุกชนิด ไม่ใช่โชว์", () => {
    const r = splitByAcceptance(cat, null);
    expect(r.catalog.kinds).toEqual([]);
    expect(r.catalog.tags).toEqual([]);
    expect(r.hidden.map((h) => [h.key, h.reason])).toEqual([["project", "unreadable"], ["label", "unreadable"]]);
  });
  it("ชนิดที่ไม่อยู่ในรายชื่อที่รับ (เช่น ชนิดใหม่) ซ่อน ไม่เดาว่ารับ", () => {
    expect(splitByAcceptance(cat, new Set()).catalog.tags).toEqual([]);
  });
});

describe("refusedKinds · ด่านสำรองฝั่ง server", () => {
  it("คืนเฉพาะชนิดที่เลือกมาและประตูไม่รับ (ไม่ซ้ำ)", () => {
    expect(refusedKinds(["p1", "l1"], cat, new Set(["project"])).map((h) => h.key)).toEqual(["label"]);
    expect(refusedKinds(["p1"], cat, new Set(["project"]))).toEqual([]);
  });
  it("อ่านรายชื่อไม่ได้ → ปฏิเสธทุกชนิดที่เลือก", () => {
    expect(refusedKinds(["p1", "l1"], cat, null).map((h) => h.key)).toEqual(["project", "label"]);
  });
});

describe("hiddenKindsMessage · ภาษาคน", () => {
  it("บอกชื่อชนิด เหตุผล และเมื่อไรจะใช้ได้ · ไม่ใช่ศัพท์เทคนิค", () => {
    const m = hiddenKindsMessage([{ key: "label", nameTh: "ป้ายกำกับ", reason: "not_open" }]);
    expect(m).toMatch(/ป้ายกำกับ/);
    expect(m).toMatch(/ยังไม่พร้อมรับ/);
    expect(m).toMatch(/จะกลับมาให้เลือกเอง/);
    expect(m).toMatch(/ลงรายการโดยไม่ติด tag ชนิดนี้ได้ตามปกติ/);
    expect(m).not.toMatch(/migration|fn_|rpc/i);
  });
  it("อ่านไม่ได้ → อธิบายว่าตรวจไม่ได้", () => {
    expect(hiddenKindsMessage([{ key: "label", nameTh: "ป้ายกำกับ", reason: "unreadable" }])).toMatch(/ตรวจไม่ได้/);
  });
  it("ไม่มีอะไรซ่อน → ว่าง", () => {
    expect(hiddenKindsMessage([])).toBe("");
  });
});
