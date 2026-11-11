import { describe, expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { TagSection, TagSummary } from "../tag-section";
import type { TxFormApi } from "../use-tx-form";
import type { Tag, TagKind, TagWeights } from "@/components/tags/types";
import { checkTagSelection, withSoleTagWeight, pruneWeights } from "@/lib/tags/selection";
import { buttonLabels, visibleText } from "@/components/tags/__tests__/fixtures";

const kinds: TagKind[] = [
  { key: "project", nameTh: "โปรเจกต์", allowsMulti: true, aggregateNoteTh: "x", requiresAllocation: true, allocationNoteTh: "ส่วนแบ่งตามน้ำหนัก ........" },
  { key: "label", nameTh: "ป้ายกำกับ", allowsMulti: true, aggregateNoteTh: "x", requiresAllocation: false },
];
const t = (id: string, kind: string, nameTh: string): Tag => ({ id, kind, code: id, nameTh, isActive: true, colorToken: null });
const tags = [t("p1", "project", "ไอริส 235"), t("p2", "project", "บางแสน"), t("p3", "project", "โลตัส"), t("l1", "label", "ภาษี")];

/** api จำลองเท่าที่ส่วน tag ใช้ — ตัวตรวจเป็นของจริง ไม่ใช่ของปลอม */
function fakeApi(over: { tagIds: string[]; tagWeights?: TagWeights; amount?: number; canTag?: boolean; cat?: Partial<TxFormApi["tagCatalog"]> }): TxFormApi {
  const tagWeights = over.tagWeights ?? {};
  const chosen = tags.filter((x) => over.tagIds.includes(x.id));
  const eff = withSoleTagWeight(chosen, kinds, pruneWeights(over.tagIds, tagWeights));
  const check = over.tagIds.length === 0 ? { ok: true as const, labelTagIds: [], tagWeights: {}, groups: [] } : checkTagSelection({ tagIds: over.tagIds, weights: eff }, { kinds, tags });
  return {
    draft: { tagIds: over.tagIds, tagWeights },
    patch: () => {},
    canTag: over.canTag ?? true,
    tagCatalog: { loading: false, error: null, notMigrated: false, kinds, tags, hiddenKinds: [], ...over.cat },
    tagCheck: check,
    tagWeightsEffective: eff,
    postingInput: over.amount === undefined ? null : { amount: over.amount },
  } as unknown as TxFormApi;
}

describe("TagSection · ชนิดที่ประตูบันทึกยังไม่รับ", () => {
  // แค็ตตาล็อกที่ server ส่งมาหลังกรองแล้ว: เหลือแต่ project · label ถูกซ่อน
  const onlyProject = { kinds: [kinds[0]], tags: tags.filter((x) => x.kind === "project"), hiddenKinds: [{ key: "label", nameTh: "ป้ายกำกับ", reason: "not_open" as const }] };

  it("ชนิดที่ซ่อนไม่โผล่ให้เลือก · ชนิดที่รับยังเลือกได้ · มีข้อความอธิบายเป็นภาษาคน", () => {
    const html = renderToStaticMarkup(<TagSection api={fakeApi({ tagIds: [], cat: onlyProject })} />);
    const text = visibleText(html);
    expect(text).toMatch(/ไอริส 235/);
    expect(text).not.toMatch(/ภาษี/); // tag ของ label ไม่โผล่
    expect(html).toContain('data-testid="tag-hidden-kinds"');
    expect(text).toMatch(/ป้ายกำกับ.*ยังเลือกไม่ได้/);
    expect(text).toMatch(/จะกลับมาให้เลือกเอง/);
  });

  it("อ่านรายชื่อที่ประตูรับไม่ได้ → ไม่มีอะไรให้เลือกเลย (ซ่อนหมด) แต่บอกเหตุ และไม่ขึ้น 'ยังไม่มี tag'", () => {
    const html = renderToStaticMarkup(
      <TagSection
        api={fakeApi({
          tagIds: [],
          cat: { kinds: [], tags: [], hiddenKinds: kinds.map((k) => ({ key: k.key, nameTh: k.nameTh, reason: "unreadable" as const })) },
        })}
      />
    );
    const text = visibleText(html);
    expect(html).not.toContain('type="checkbox"');
    expect(html).not.toContain("tag-picker-empty");
    expect(text).toMatch(/ตรวจไม่ได้/);
    expect(text).toMatch(/โปรเจกต์/);
  });

  it("ไม่มีอะไรซ่อน → ไม่มีกล่องข้อความ", () => {
    expect(renderToStaticMarkup(<TagSection api={fakeApi({ tagIds: [] })} />)).not.toContain("tag-hidden-kinds");
  });
});

describe("TagSection", () => {
  it("ไม่มีสิทธิ์ tag.assign → ไม่แสดงอะไรเลย", () => {
    expect(renderToStaticMarkup(<TagSection api={fakeApi({ tagIds: [], canTag: false })} />)).toBe("");
  });

  it("กำลังโหลด / โหลดไม่ได้ (ยังไม่ได้ลง migration) → บอกตรงๆ และบอกว่าลงรายการโดยไม่ติด tag ได้", () => {
    expect(visibleText(renderToStaticMarkup(<TagSection api={fakeApi({ tagIds: [], cat: { loading: true } })} />))).toMatch(/กำลังโหลดรายการ tag/);
    const html = renderToStaticMarkup(<TagSection api={fakeApi({ tagIds: [], cat: { error: "ยังไม่ได้ลง migration — ยังไม่ได้บันทึกอะไร", notMigrated: true } })} />);
    expect(visibleText(html)).toMatch(/ยังเลือก tag ไม่ได้.*ยังไม่ได้ลง migration.*ลงรายการโดยไม่ติด tag ได้/);
    expect(html).toContain('role="alert"');
  });

  it("project อันเดียว → แสดง 100% ให้เห็น ไม่มีช่องกรอก และไม่มีคำเตือน", () => {
    const html = renderToStaticMarkup(<TagSection api={fakeApi({ tagIds: ["p1"] })} />);
    expect(visibleText(html)).toMatch(/เพียงอันเดียว.*100%/);
    expect(html).not.toContain('data-testid="weight-total"');
    expect(html).not.toContain('role="alert"');
  });

  it("project สองอัน Σ = 100% → มีช่องน้ำหนัก + ปุ่มแบ่งเท่ากัน · ไม่มีคำเตือนว่าบันทึกไม่ได้", () => {
    const html = renderToStaticMarkup(<TagSection api={fakeApi({ tagIds: ["p1", "p2"], tagWeights: { p1: 0.6, p2: 0.4 } })} />);
    expect(html).toContain('data-testid="weight-total"');
    expect(html).toContain('data-complete="true"');
    expect(buttonLabels(html)).toContain("แบ่งเท่ากัน");
    expect(visibleText(html)).not.toMatch(/ยังบันทึกพร้อม tag ไม่ได้/);
  });

  it("project สองอัน Σ ≠ 100% → เตือนสดพร้อมบอกว่าขาดเท่าไร และบอกว่ายังบันทึกพร้อม tag ไม่ได้ (ตัวตรวจจริง)", () => {
    const html = renderToStaticMarkup(<TagSection api={fakeApi({ tagIds: ["p1", "p2"], tagWeights: { p1: 0.6, p2: 0.399999 } })} />);
    expect(html).toContain('data-complete="false"');
    expect(visibleText(html)).toMatch(/ขาดอีก 0\.0001%/);
    expect(visibleText(html)).toMatch(/ยังบันทึกพร้อม tag ไม่ได้/);
  });

  it("แบ่งเท่ากันสามอันยังเหลือเศษ 0.0001% → ยังเตือน ไม่เติมให้เอง", () => {
    const html = renderToStaticMarkup(
      <TagSection api={fakeApi({ tagIds: ["p1", "p2", "p3"], tagWeights: { p1: 0.333333, p2: 0.333333, p3: 0.333333 } })} />
    );
    expect(visibleText(html)).toMatch(/ขาดอีก 0\.0001%/);
  });

  it("ปุ่มทุกปุ่มมีข้อความกำกับ", () => {
    const html = renderToStaticMarkup(<TagSection api={fakeApi({ tagIds: ["p1", "p2"], tagWeights: {} })} />);
    for (const l of buttonLabels(html)) expect(l).not.toBe("");
  });
});

describe("TagSummary · 'ระบบจะบันทึก tag ให้ดังนี้'", () => {
  it("60/40 ของ 12,000 → 7,200.00 + 4,800.00 รวมเท่ายอดรายการ", () => {
    const text = visibleText(renderToStaticMarkup(<TagSummary api={fakeApi({ tagIds: ["p1", "p2", "l1"], tagWeights: { p1: 0.6, p2: 0.4 }, amount: 12000 })} />));
    expect(text).toMatch(/ระบบจะบันทึก tag ให้ดังนี้/);
    expect(text).toMatch(/ไอริส 235 · 60% ฿ 7,200\.00/);
    expect(text).toMatch(/บางแสน · 40% ฿ 4,800\.00/);
    expect(text).toMatch(/รวม ฿ 12,000\.00 = ยอดรายการ/);
    expect(text).toMatch(/ภาษี/);
  });

  it("100.00 แบ่งสาม (0.333333 / 0.333333 / 0.333334) → 33.33 + 33.33 + 33.34 รวม 100.00 พอดี", () => {
    const text = visibleText(
      renderToStaticMarkup(<TagSummary api={fakeApi({ tagIds: ["p1", "p2", "p3"], tagWeights: { p1: 0.333333, p2: 0.333333, p3: 0.333334 }, amount: 100 })} />)
    );
    expect(text).toMatch(/฿ 33\.33.*฿ 33\.33.*฿ 33\.34/);
    expect(text).toMatch(/รวม ฿ 100\.00 = ยอดรายการ/);
  });

  it("ชุดที่ตัวตรวจไม่รับ / ไม่ได้เลือก tag → ไม่แสดงอะไร (ไม่โชว์ตัวเลขของชุดที่บันทึกไม่ได้)", () => {
    expect(renderToStaticMarkup(<TagSummary api={fakeApi({ tagIds: ["p1", "p2"], tagWeights: { p1: 0.6, p2: 0.3 }, amount: 100 })} />)).toBe("");
    expect(renderToStaticMarkup(<TagSummary api={fakeApi({ tagIds: [], amount: 100 })} />)).toBe("");
  });
});
