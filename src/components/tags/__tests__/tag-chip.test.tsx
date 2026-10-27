import { describe, expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { TagChip, formatPercent, toneClass } from "../tag-chip";
import { IRIS, OLD, buttonLabels, visibleText } from "./fixtures";

describe("formatPercent", () => {
  it("สัดส่วน -> เปอร์เซ็นต์ ไม่มีเศษลอยตัว", () => {
    expect(formatPercent(0.6)).toBe("60%");
    expect(formatPercent(0.4)).toBe("40%");
    expect(formatPercent(1)).toBe("100%");
    expect(formatPercent(0.5)).toBe("50%");
    expect(formatPercent(0.333333)).toBe("33.3333%");
    expect(formatPercent(0.999999)).toBe("99.9999%");
    expect(formatPercent(0.000001)).toBe("0.0001%");
    expect(formatPercent(0)).toBe("0%");
    expect(formatPercent(0.1 + 0.2)).toBe("30%");
  });
});

describe("toneClass", () => {
  it("โทเคนที่รู้จักได้คลาสของโทเคน · ไม่รู้จัก/ว่างได้สีกลาง", () => {
    expect(toneClass("brand")).toContain("bg-brand-50");
    expect(toneClass("pos")).toContain("text-pos-fg");
    expect(toneClass("#ff0000")).toBe(toneClass(null));
    expect(toneClass("nope")).toBe(toneClass(undefined));
  });
});

describe("TagChip", () => {
  it("แสดงชื่อ ชนิด และน้ำหนักเป็นเปอร์เซ็นต์", () => {
    const html = renderToStaticMarkup(<TagChip tag={IRIS} kindLabel="โปรเจกต์" weight={0.6} />);
    const text = visibleText(html);
    expect(text).toContain("โปรเจกต์");
    expect(text).toContain("ไอริส 235");
    expect(text).toContain("60%");
    expect(html).toContain("tabular-nums");
    expect(html).not.toContain("<button");
  });

  it("tag ที่ปิดแล้วบอกเป็นข้อความ ไม่พึ่งสีอย่างเดียว", () => {
    const html = renderToStaticMarkup(<TagChip tag={OLD} />);
    expect(visibleText(html)).toContain("ปิดใช้งานแล้ว");
  });

  it("ไม่ส่งน้ำหนัก = ไม่แสดงเปอร์เซ็นต์", () => {
    expect(visibleText(renderToStaticMarkup(<TagChip tag={IRIS} />))).not.toContain("%");
    expect(visibleText(renderToStaticMarkup(<TagChip tag={IRIS} weight={null} />))).not.toContain("%");
  });

  it("ปุ่มเอาออกมีข้อความ 'เอา tag นี้ออก' ไม่ใช่ ✕ เดี่ยว และสูง >= 52px", () => {
    const html = renderToStaticMarkup(<TagChip tag={IRIS} onRemove={() => {}} />);
    const labels = buttonLabels(html);
    expect(labels).toHaveLength(1);
    expect(labels[0]).toContain("เอา tag นี้ออก");
    expect(labels[0]).toContain("ไอริส 235");
    expect(labels[0]).not.toMatch(/^[✕×xX]$/);
    expect(html).toContain("min-h-control");
    expect(html).toContain("focus-visible:ring-[3px]");
  });
});
