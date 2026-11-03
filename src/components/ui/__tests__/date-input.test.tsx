import { describe, expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import { DateInput } from "../date-input";

/**
 * ด่านของช่องวันที่ที่ "กดแล้วขึ้นปฏิทิน"
 *
 * ข้อสำคัญ: **ค่าที่เก็บในฟอร์มยังเป็น วว/ดด/ปปปป เหมือนเดิม**
 * คอมโพเนนต์แปลงไป-กลับที่ขอบเท่านั้น ตัวตรวจและ engine จึงไม่ต้องแก้อะไร
 * ถ้าวันหนึ่งมีคนทำให้มันเก็บเป็น ISO แทน จะมีสองมาตรฐานปนกันในฟอร์มทันที
 */
const attr = (html: string, name: string) => new RegExp(`${name}="([^"]*)"`).exec(html)?.[1] ?? null;

describe("DateInput", () => {
  it("เป็น input type=date จริง (ปฏิทินของเบราว์เซอร์) ไม่ใช่ช่องพิมพ์ธรรมดา", () => {
    expect(renderToStaticMarkup(<DateInput value="24/10/2026" onChange={() => {}} />)).toContain('type="date"');
  });

  it("แปลง วว/ดด/ปปปป → yyyy-mm-dd ให้ widget", () => {
    const html = renderToStaticMarkup(<DateInput value="24/10/2026" onChange={() => {}} />);
    expect(attr(html, "value")).toBe("2026-10-24");
  });

  it("ค่าที่อ่านเป็นวันที่ไม่ได้ → widget ว่าง แต่ไม่ถือว่าเป็นวันที่อื่น", () => {
    for (const bad of ["", "24/10", "ยี่สิบสี่", "99/99/2026"]) {
      const html = renderToStaticMarkup(<DateInput value={bad} onChange={() => {}} />);
      expect(attr(html, "value")).toBe("");
    }
  });

  it("รับค่าที่เป็น ISO อยู่แล้วได้ด้วย (dmyToIso รับทั้งสองแบบ)", () => {
    expect(attr(renderToStaticMarkup(<DateInput value="2026-10-24" onChange={() => {}} />), "value")).toBe("2026-10-24");
  });

  it("min/max รับเป็น วว/ดด/ปปปป แล้วแปลงให้ widget", () => {
    const html = renderToStaticMarkup(<DateInput value="" onChange={() => {}} min="01/01/2026" max="31/12/2026" />);
    expect(attr(html, "min")).toBe("2026-01-01");
    expect(attr(html, "max")).toBe("2026-12-31");
  });

  it("ไม่ส่ง value มา → เป็น input ที่ไม่ควบคุมค่า (ฟอร์มอ่านจาก name)", () => {
    const html = renderToStaticMarkup(<DateInput name="cutoff" />);
    expect(html).toContain('name="cutoff"');
    expect(attr(html, "value")).toBe(null);
  });

  it("สูง ≥ 52px และมีวงแหวนโฟกัส 3px ตามข้อกำหนดผู้สูงอายุ", () => {
    const html = renderToStaticMarkup(<DateInput value="" onChange={() => {}} />);
    expect(html).toContain("min-h-control");
    expect(html).toContain("focus-visible:ring-[3px]");
  });
});

describe("ช่องวันที่ทุกที่ต้องใช้ DateInput", () => {
  it("ไม่มีหน้าจอไหนเหลือช่องวันที่ที่พิมพ์เอง", () => {
    const SRC = path.join(__dirname, "..", "..", "..");
    const bad: string[] = [];
    const walk = (d: string) => {
      for (const e of readdirSync(d)) {
        const full = path.join(d, e);
        if (statSync(full).isDirectory()) {
          if (e === "__tests__") continue;
          walk(full);
        } else if (e.endsWith(".tsx")) {
          const src = readFileSync(full, "utf8");
          // ช่องที่ยังเป็น <Input> แต่ผูกกับค่าที่เป็นวันที่
          if (/<Input[^>]*value=\{[^}]*\b(docDate|cashDate|rateDate|asOf|cutoff)\b/.test(src)) bad.push(path.relative(SRC, full));
        }
      }
    };
    walk(path.join(SRC, "components"));
    walk(path.join(SRC, "app"));
    expect(bad).toEqual([]);
  });
});
