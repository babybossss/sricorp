import { describe, expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { TagTouchTable } from "../tag-touch-table";
import type { TagTouchRow } from "../types";
import { IRIS, RENO, URGENT, visibleText } from "./fixtures";

const NOTE = "ยอดที่แตะ tag นี้ · ใบที่ติดหลาย tag ถูกนับในทุก tag ที่ติด — เอายอดของแต่ละ tag มาบวกกันไม่ได้";

const rows: TagTouchRow[] = [
  { tag: IRIS, touchedDebit: 10_000_000, touchedCredit: 0, touchedTxnCount: 3, overlapTxnCount: 1, overlapDebit: 10_000_000 },
  { tag: RENO, touchedDebit: 10_000_000, touchedCredit: -250.5, touchedTxnCount: 2, overlapTxnCount: 1, overlapDebit: 10_000_000 },
];
const owners = ["SRI Corporation", "สุธี"];

const render = (over: Partial<Parameters<typeof TagTouchTable>[0]> = {}) =>
  renderToStaticMarkup(<TagTouchTable aggregateNoteTh={NOTE} rows={rows} visibleOwnerNamesTh={owners} {...over} />);

describe("TagTouchTable · ประโยคกำกับบังคับ (ADR 0002 ชั้น 3)", () => {
  it("ไม่ส่ง aggregateNoteTh = throw", () => {
    // @ts-expect-error จงใจลืมส่ง — TypeScript ก็ต้องจับได้
    expect(() => renderToStaticMarkup(<TagTouchTable rows={rows} visibleOwnerNamesTh={owners} />)).toThrow(/aggregateNoteTh/);
  });

  it("ส่งสตริงว่าง/ช่องว่าง = throw (note ว่างคือเลขเปลือย)", () => {
    expect(() => render({ aggregateNoteTh: "" })).toThrow(/aggregateNoteTh/);
    expect(() => render({ aggregateNoteTh: "   \n " })).toThrow(/aggregateNoteTh/);
  });

  it("ส่ง null/undefined/ไม่ใช่สตริง = throw", () => {
    expect(() => render({ aggregateNoteTh: null as unknown as string })).toThrow(/aggregateNoteTh/);
    expect(() => render({ aggregateNoteTh: undefined as unknown as string })).toThrow(/aggregateNoteTh/);
    expect(() => render({ aggregateNoteTh: 42 as unknown as string })).toThrow(/aggregateNoteTh/);
  });

  it("แม้ไม่มีแถวเลย ก็ต้องมี note (ตารางว่างยังต้อง throw ถ้าลืม)", () => {
    expect(() => render({ aggregateNoteTh: "", rows: [] })).toThrow(/aggregateNoteTh/);
  });

  it("แสดงประโยคเต็มเหนือตารางเสมอ", () => {
    const html = render();
    expect(html).toContain(NOTE);
    expect(html.indexOf(NOTE)).toBeLessThan(html.indexOf("<table"));
    expect(html).toContain('role="note"');
  });

  it("แสดงประโยคเหนือตารางแม้ไม่มีแถว", () => {
    const html = render({ rows: [] });
    expect(html.indexOf(NOTE)).toBeGreaterThan(-1);
    expect(html.indexOf(NOTE)).toBeLessThan(html.indexOf("<table"));
    expect(visibleText(html)).toContain("ไม่มีรายการที่แตะ tag");
  });
});

describe("TagTouchTable · ตัวเลขไม่ให้เข้าใจผิด (ADR 0002 ข้อ 4.4)", () => {
  it("ไม่มีแถวรวม (ผลบวกข้าม tag ไม่มีความหมาย)", () => {
    const html = render();
    expect(html.match(/<tr/g)?.length).toBe(1 + rows.length); // หัว + 2 แถว
    expect(visibleText(html)).not.toMatch(/รวมทั้งหมด|ยอดรวม|Total/i);
    expect(html).not.toContain("<tfoot");
  });

  it("หัวคอลัมน์พูดว่า 'แตะ tag นี้' ไม่ใช่ 'ยอด' เปล่าๆ และมีคอลัมน์ใบที่ซ้อน", () => {
    const heads = [...render().matchAll(/<th[^>]*>([\s\S]*?)<\/th>/g)].map((m) => visibleText(m[1]));
    expect(heads).toContain("เดบิตที่แตะ tag นี้ (บาท)");
    expect(heads).toContain("เครดิตที่แตะ tag นี้ (บาท)");
    expect(heads).toContain("ใบที่ติดหลาย tag ชนิดเดียวกัน");
    expect(heads.every((h) => h !== "ยอด" && h !== "จำนวนเงิน" && h !== "Total")).toBe(true);
  });

  it("แสดง Entity ที่ผู้ใช้เห็น", () => {
    expect(visibleText(render())).toContain("คิดจาก Entity ที่คุณมีสิทธิ์เห็น: SRI Corporation · สุธี");
    expect(visibleText(render({ visibleOwnerNamesTh: [] }))).toContain("คิดจาก Entity ที่คุณมีสิทธิ์เห็น: ไม่มี");
  });

  it("ติดลบใช้วงเล็บ · ตัวเลขชิดขวาแบบ tabular · ตัวคั่นหลักพัน", () => {
    const html = render();
    expect(html).toContain("(250.50)");
    expect(html).not.toContain("-250.5");
    expect(html).toContain("10,000,000.00");
    expect(html).toContain("tabular-nums");
    expect(html).toContain("text-right");
  });

  it("แถวละหนึ่ง tag และแสดงชื่อ tag", () => {
    const text = visibleText(render());
    expect(text).toContain("ไอริส 235");
    expect(text).toContain("รีโนเวต 2026");
    expect(text).not.toContain(URGENT.nameTh);
  });

  it("ตารางกว้างเลื่อนแนวนอนได้ ไม่บีบ: ขอบเลื่อนโฟกัสคีย์บอร์ดได้ + minWidth", () => {
    const html = render();
    expect(html).toContain("overflow-auto");
    expect(html).toContain('tabindex="0"');
    expect(html).toContain("min-width:860px");
    expect(html).toContain("focus-visible:ring-[3px]");
  });
});
