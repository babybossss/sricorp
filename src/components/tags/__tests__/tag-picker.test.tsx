import { describe, expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { TagPicker, selectionAfterToggle } from "../tag-picker";
import { IRIS, KINDS, OLD, RENO, URGENT, tag, visibleText } from "./fixtures";

const catalog = [IRIS, RENO, OLD, URGENT];
const render = (selectedIds: string[], over: Partial<Parameters<typeof TagPicker>[0]> = {}) =>
  renderToStaticMarkup(<TagPicker catalog={catalog} kinds={KINDS} selectedIds={selectedIds} onChange={() => {}} {...over} />);

describe("TagPicker · การแสดงผล", () => {
  it("เป็นรายการติ๊ก ไม่มีช่องพิมพ์อิสระ", () => {
    const html = render([]);
    expect(html.match(/type="checkbox"/g)?.length).toBe(3); // ไอริส รีโนเวต เร่งด่วน (โครงการเก่าปิดอยู่)
    expect(html).not.toMatch(/type="text"/);
    expect(html).not.toContain("<textarea");
    expect(html).not.toContain("<select");
    expect(html).not.toContain('type="search"');
    expect(html).not.toContain("<button");
  });

  it("แยกกลุ่มตามชนิด ชื่อกลุ่มมาจาก kinds", () => {
    const html = render([]);
    expect(html.match(/<fieldset/g)?.length).toBe(2);
    const text = visibleText(html);
    expect(text.indexOf("โปรเจกต์")).toBeGreaterThan(-1);
    expect(text.indexOf("ป้ายกำกับ")).toBeGreaterThan(text.indexOf("โปรเจกต์"));
    // ไอริส อยู่ใต้ โปรเจกต์ · เร่งด่วน อยู่ใต้ ป้ายกำกับ
    expect(text.indexOf("ไอริส 235")).toBeLessThan(text.indexOf("ป้ายกำกับ"));
    expect(text.indexOf("เร่งด่วน")).toBeGreaterThan(text.indexOf("ป้ายกำกับ"));
  });

  it("tag ที่ปิดแล้ว ไม่โผล่ให้เลือกใหม่", () => {
    expect(visibleText(render([]))).not.toContain("โครงการเก่า");
  });

  it("tag ที่ปิดแล้วแต่ถูกเลือกอยู่ ยังแสดง ติ๊กอยู่ พร้อมป้ายบอก", () => {
    const html = render([OLD.id]);
    expect(visibleText(html)).toContain("โครงการเก่า");
    expect(visibleText(html)).toContain("ปิดใช้งานแล้ว");
    expect(html.match(/checked=""/g)?.length).toBe(1);
  });

  it("ติ๊กตามที่เลือก", () => {
    const html = render([IRIS.id, URGENT.id]);
    expect(html.match(/checked=""/g)?.length).toBe(2);
  });

  it("id ที่เลือกไว้แต่ไม่อยู่ในแค็ตตาล็อก ไม่หายเงียบ", () => {
    const html = render(["ghost-id"]);
    expect(visibleText(html)).toContain("ไม่พบ tag ในแค็ตตาล็อก");
    expect(html).toContain("ghost-id");
  });

  it("แค็ตตาล็อกว่าง = บอกให้ไปตั้งที่หน้าตั้งค่า", () => {
    const html = render([], { catalog: [] });
    expect(visibleText(html)).toContain("ยังไม่มี tag — ไปตั้งที่หน้าตั้งค่า");
    expect(html).not.toContain("<input");
  });

  it("แถวเลือกสูง >= 52px (มือถือ 56px) · กล่องติ๊กมีวงแหวนโฟกัส 3px", () => {
    const html = render([]);
    expect(html).toContain("min-h-control");
    expect(html).toContain("max-sm:min-h-control-mobile");
    expect(html).toContain("focus-visible:ring-[3px]");
  });

  it("ชนิดที่ tag อยู่นอก kinds ไม่ถูกทิ้ง", () => {
    const odd = tag("t-odd", "mystery", "แปลกๆ");
    const html = render([], { catalog: [odd] });
    expect(visibleText(html)).toContain("แปลกๆ");
  });
});

describe("selectionAfterToggle", () => {
  it("ติ๊กเพิ่มได้หลายอัน (ชนิด allowsMulti)", () => {
    let sel = selectionAfterToggle(IRIS, true, [], catalog, KINDS);
    sel = selectionAfterToggle(RENO, true, sel, catalog, KINDS);
    expect(sel).toEqual([IRIS.id, RENO.id]);
  });

  it("เอาติ๊กออก", () => {
    expect(selectionAfterToggle(IRIS, false, [IRIS.id, RENO.id], catalog, KINDS)).toEqual([RENO.id]);
  });

  it("ติ๊กซ้ำไม่เพิ่ม id ซ้ำ", () => {
    expect(selectionAfterToggle(IRIS, true, [IRIS.id], catalog, KINDS)).toEqual([IRIS.id]);
  });

  it("ชนิดที่ allowsMulti = false: เลือกอันใหม่แทนอันเดิมของชนิดนั้น ไม่แตะชนิดอื่น", () => {
    const kinds = [{ ...KINDS[0], allowsMulti: false }, KINDS[1]];
    expect(selectionAfterToggle(RENO, true, [IRIS.id, URGENT.id], catalog, kinds)).toEqual([URGENT.id, RENO.id]);
  });
});
