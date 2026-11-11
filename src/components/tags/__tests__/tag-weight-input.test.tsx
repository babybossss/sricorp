import { describe, expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { TagWeightInput, parsePercentInput, splitEqually, weightsStatus } from "../tag-weight-input";
import { IRIS, RENO, buttonLabels, tag, visibleText } from "./fixtures";

const render = (value: Record<string, number | null>, tags = [IRIS, RENO], over: Partial<Parameters<typeof TagWeightInput>[0]> = {}) =>
  renderToStaticMarkup(<TagWeightInput tags={tags} value={value} onChange={() => {}} {...over} />);

describe("parsePercentInput · เปอร์เซ็นต์ที่พิมพ์ -> สัดส่วน", () => {
  it("60 และ 60% และ ' 60 ' ได้ 0.6", () => {
    for (const raw of ["60", "60%", " 60 ", "60.0", "60.0000"]) {
      expect(parsePercentInput(raw)).toEqual({ ok: true, fraction: 0.6 });
    }
  });

  it("ทศนิยมไม่เพี้ยนแบบ float", () => {
    expect(parsePercentInput("33.3333")).toEqual({ ok: true, fraction: 0.333333 });
    expect(parsePercentInput("0.0001")).toEqual({ ok: true, fraction: 0.000001 });
    expect(parsePercentInput("99.9999")).toEqual({ ok: true, fraction: 0.999999 });
    expect(parsePercentInput("100")).toEqual({ ok: true, fraction: 1 });
  });

  it("ว่าง = empty (ยังไม่กรอก ไม่ใช่ศูนย์)", () => {
    expect(parsePercentInput("")).toEqual({ ok: false, reason: "empty" });
    expect(parsePercentInput("  ")).toEqual({ ok: false, reason: "empty" });
  });

  it("0 ไม่ให้กรอก (ไม่ว่าเขียนแบบไหน)", () => {
    for (const raw of ["0", "0%", "0.0", "0.0000", "00"]) {
      expect(parsePercentInput(raw)).toEqual({ ok: false, reason: "zero" });
    }
  });

  it("เกิน 100% ปฏิเสธ", () => {
    expect(parsePercentInput("100.0001")).toEqual({ ok: false, reason: "over" });
    expect(parsePercentInput("101")).toEqual({ ok: false, reason: "over" });
  });

  it("ทศนิยมเกิน 4 ตำแหน่งปฏิเสธ ไม่ปัดเงียบ", () => {
    expect(parsePercentInput("33.33333")).toEqual({ ok: false, reason: "decimals" });
  });

  it("ติดลบ/ตัวอักษร/วงเล็บ อ่านไม่ออก = ปฏิเสธ ไม่เดา", () => {
    for (const raw of ["-10", "(10)", "abc", "6 0 x", "1e2", "−10"]) {
      expect(parsePercentInput(raw).ok).toBe(false);
    }
  });
});

describe("weightsStatus · ผลรวมและขาด/เกิน", () => {
  it("60 + 40 = ครบพอดี", () => {
    const s = weightsStatus(["a", "b"], { a: 0.6, b: 0.4 });
    expect(s.complete).toBe(true);
    expect(s.remaining).toBe(0);
    expect(s.sum).toBe(1);
  });

  it("0.1 + 0.2 + 0.7 ครบพอดี (นับเป็นจำนวนเต็ม ไม่ใช่ float)", () => {
    expect(weightsStatus(["a", "b", "c"], { a: 0.1, b: 0.2, c: 0.7 }).complete).toBe(true);
  });

  it("ขาด: 60 + 30 ขาด 10", () => {
    const s = weightsStatus(["a", "b"], { a: 0.6, b: 0.3 });
    expect(s.complete).toBe(false);
    expect(s.remaining).toBeCloseTo(0.1, 9);
  });

  it("เกิน: 70 + 50 เกิน 20 (remaining ติดลบ)", () => {
    const s = weightsStatus(["a", "b"], { a: 0.7, b: 0.5 });
    expect(s.complete).toBe(false);
    expect(s.remaining).toBeCloseTo(-0.2, 9);
  });

  it("ห่างจาก 100% แค่ 0.0001% ก็ไม่ครบ (ไม่มี tolerance เหมือนด่านที่ DB)", () => {
    expect(weightsStatus(["a", "b", "c"], { a: 0.333333, b: 0.333333, c: 0.333333 }).complete).toBe(false);
  });

  it("แถวที่ยังไม่กรอก (null/ไม่มีคีย์) ถูกนับเป็นขาด และไม่ครบแม้ผลรวมอื่น = 100%", () => {
    const s = weightsStatus(["a", "b"], { a: 1, b: null });
    expect(s.missingIds).toEqual(["b"]);
    expect(s.complete).toBe(false);
    expect(weightsStatus(["a", "b"], { a: 1 }).missingIds).toEqual(["b"]);
  });

  it("น้ำหนัก 0 ที่หลุดมาจาก parent ไม่ถูกนับว่ากรอกแล้ว", () => {
    expect(weightsStatus(["a", "b"], { a: 1, b: 0 }).complete).toBe(false);
  });

  it("ไม่มี tag = ไม่ครบ", () => {
    expect(weightsStatus([], {}).complete).toBe(false);
  });

  it("ไม่ปัดให้ครบ: ไม่ได้แตะ weights ของผู้เรียก", () => {
    const w = { a: 0.6, b: 0.3 };
    weightsStatus(["a", "b"], w);
    expect(w).toEqual({ a: 0.6, b: 0.3 });
  });
});

describe("splitEqually", () => {
  it("2 อัน = 50/50 ครบ 100%", () => {
    const w = splitEqually(["a", "b"]);
    expect(w).toEqual({ a: 0.5, b: 0.5 });
    expect(weightsStatus(["a", "b"], w).complete).toBe(true);
  });

  it("4 อัน = 25 ครบ", () => {
    expect(weightsStatus(["a", "b", "c", "d"], splitEqually(["a", "b", "c", "d"])).complete).toBe(true);
  });

  it("3 อัน หารไม่ลงตัว: ไม่แจกเศษให้ใคร -> ยังไม่ครบ ต้องให้ผู้ใช้แก้เอง", () => {
    const ids = ["a", "b", "c"];
    const w = splitEqually(ids);
    expect(w).toEqual({ a: 0.333333, b: 0.333333, c: 0.333333 });
    const s = weightsStatus(ids, w);
    expect(s.complete).toBe(false);
    expect(s.remaining).toBeCloseTo(0.000001, 9);
  });

  it("ไม่มี tag = ว่าง", () => {
    expect(splitEqually([])).toEqual({});
  });
});

describe("TagWeightInput · การแสดงผล", () => {
  it("แสดงน้ำหนักเป็นเปอร์เซ็นต์จากสัดส่วน และรวมสด", () => {
    const html = render({ [IRIS.id]: 0.6, [RENO.id]: 0.4 });
    expect(html).toContain('value="60"');
    expect(html).toContain('value="40"');
    const total = visibleText(html);
    expect(total).toContain("รวม 100% จาก 100%");
    expect(total).toContain("ครบ 100% แล้ว");
    expect(html).toContain('data-complete="true"');
  });

  it("ขาด: บอกว่าขาดเท่าไร พร้อมสถานะไม่ครบ", () => {
    const html = render({ [IRIS.id]: 0.6, [RENO.id]: 0.3 });
    const text = visibleText(html);
    expect(text).toContain("รวม 90% จาก 100%");
    expect(text).toContain("ขาดอีก 10%");
    expect(html).toContain('data-complete="false"');
    expect(html).toContain('role="status"');
    expect(html).toContain('aria-live="polite"');
  });

  it("เกิน: บอกว่าเกินเท่าไร", () => {
    const text = visibleText(render({ [IRIS.id]: 0.7, [RENO.id]: 0.5 }));
    expect(text).toContain("รวม 120% จาก 100%");
    expect(text).toContain("เกินอยู่ 20%");
  });

  it("ขาดเศษเล็กๆ จากการแบ่งเท่ากัน 3 อัน: เตือนว่าขาด 0.0001% ไม่ปัดให้", () => {
    const three = [IRIS, RENO, tag("t-3", "project", "สาม")];
    const text = visibleText(render(splitEqually(three.map((t) => t.id)), three));
    expect(text).toContain("รวม 99.9999% จาก 100%");
    expect(text).toContain("ขาดอีก 0.0001%");
  });

  it("ยังไม่กรอกเลย = รวม 0% ขาด 100% และบอกจำนวนที่กรอกแล้ว", () => {
    const text = visibleText(render({}));
    expect(text).toContain("รวม 0% จาก 100%");
    expect(text).toContain("ขาดอีก 100%");
    expect(text).toContain("กรอกแล้ว 0 จาก 2 รายการ");
  });

  it("กรอก 0 แล้วขึ้นข้อความอธิบายว่าให้เอา tag ออกแทน (และไม่นับเป็นน้ำหนัก)", () => {
    // parent ส่ง null กลับมาเมื่อพิมพ์ 0 — จำลองสถานะหลังพิมพ์: ช่องแสดงว่าง + ผลรวมไม่นับ
    const html = render({ [IRIS.id]: null, [RENO.id]: 0.4 });
    expect(visibleText(html)).toContain("ขาดอีก 60%");
  });

  it("ปุ่มทุกปุ่มมีข้อความ · มี 'แบ่งเท่ากัน' · ไม่มีปุ่มไอคอนเดี่ยว", () => {
    const html = render({});
    const labels = buttonLabels(html);
    expect(labels).toEqual(["แบ่งเท่ากัน"]);
    expect(labels.every((l) => l.length >= 2)).toBe(true);
    expect(html).toContain("min-h-control");
  });

  it("ปุ่มแบ่งเท่ากันกดไม่ได้เมื่อไม่มี tag", () => {
    const html = render({}, []);
    expect(html).toMatch(/<button[^>]*disabled/);
    expect(visibleText(html)).toContain("ยังไม่ได้เลือก tag");
  });

  it("ช่องกรอกมี label ผูกกับ input · วงแหวนโฟกัส 3px · ตัวเลข tabular · มือถือสูง 56px", () => {
    const html = render({ [IRIS.id]: 0.6, [RENO.id]: 0.4 });
    const ids = [...html.matchAll(/<input[^>]*\sid="([^"]+)"/g)].map((m) => m[1]);
    expect(ids).toHaveLength(2);
    for (const id of ids) expect(html).toContain(`for="${id}"`);
    expect(html).toContain("focus-visible:ring-[3px]");
    expect(html).toContain("tabular-nums");
    expect(html).toContain("max-sm:min-h-control-mobile");
    expect(html).toContain('inputMode="decimal"');
  });

  it("แสดงประโยคกำกับของชนิดเมื่อส่งมา", () => {
    expect(visibleText(render({}, [IRIS], { noteTh: "ยอดที่ปันส่วนแล้วบวกข้าม project ได้" }))).toContain("บวกข้าม project ได้");
  });

  it("ทุกช่องเป็นเปอร์เซ็นต์: สัดส่วนเต็ม 1 แสดง 100 ไม่ใช่ 1", () => {
    expect(render({ [IRIS.id]: 1 }, [IRIS])).toContain('value="100"');
  });
});
