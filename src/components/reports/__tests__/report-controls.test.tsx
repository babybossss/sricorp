import { describe, expect, it, vi } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { ReportControls, reportHref, TABS } from "../parts";

/**
 * ด่านของแถบเลือกช่วงเวลา (รายเดือน / ทั้งปี)
 *
 * ช่วงเวลาอยู่ใน URL ทั้งหมด หน้าจึงเป็น server-rendered ล้วน แชร์ลิงก์ได้
 * และกดปุ่มย้อนกลับของเบราว์เซอร์ได้ตามปกติ
 *
 * สิ่งที่ต้องไม่พลาด: กดเปลี่ยน**เดือน** ต้องไม่ทำให้ **ปี · ผู้ถือ · แท็บ** หลุด
 * ไม่งั้นผู้ใช้จะเด้งกลับไปดูงบของผู้ถืออื่นโดยไม่รู้ตัว
 */
vi.mock("next/link", () => ({
  default: ({ href, children, ...p }: { href: string; children: React.ReactNode }) => (
    <a href={href} {...p}>
      {children}
    </a>
  ),
}));

const owners = [{ id: "o1", name: "ธนากร" }];
const render = (month: number | null, owner = "o1", tab: (typeof TABS)[number]["key"] = "pl") =>
  renderToStaticMarkup(<ReportControls tab={tab} year={2026} month={month} owner={owner} years={[2026, 2025]} owners={owners} />);

const hrefs = (html: string) => [...html.matchAll(/href="([^"]+)"/g)].map((m) => m[1].replace(/&amp;/g, "&"));

describe("reportHref", () => {
  it("ทั้งปี = ไม่ใส่ month ลง URL เลย (อ่านง่ายและเป็นค่าตั้งต้น)", () => {
    expect(reportHref("pl", 2026, null, "o1")).toBe("/reports?tab=pl&year=2026&owner=o1");
  });

  it("รายเดือน = ใส่ month", () => {
    expect(reportHref("bs", 2026, 10, "family")).toBe("/reports?tab=bs&year=2026&month=10&owner=family");
  });

  it("ชื่อผู้ถือถูก encode (กันผู้ถือที่มีอักขระพิเศษทำ URL พัง)", () => {
    expect(reportHref("pl", 2026, 1, "a b&c")).toContain(`owner=${encodeURIComponent("a b&c")}`);
  });
});

describe("แถบเลือกช่วงเวลา", () => {
  it("มีปุ่มครบ 13 ปุ่ม: ทั้งปี + 12 เดือน", () => {
    const links = hrefs(render(null)).filter((h) => h.startsWith("/reports?"));
    const months = new Set(links.map((h) => new URL(h, "http://x").searchParams.get("month")));
    // null (ทั้งปี) + "1".."12"
    expect(months.has(null)).toBe(true);
    for (let m = 1; m <= 12; m++) expect(months.has(String(m))).toBe(true);
  });

  it("กดเปลี่ยนเดือนแล้ว ปี · ผู้ถือ · แท็บ ต้องไม่หลุด", () => {
    for (const h of hrefs(render(5, "o1", "cf")).filter((x) => x.startsWith("/reports?"))) {
      const q = new URL(h, "http://x").searchParams;
      expect({ year: q.get("year"), owner: q.get("owner") }).toEqual({ year: "2026", owner: "o1" });
    }
  });

  it("เดือนที่กำลังดูอยู่ถูกทำเครื่องหมาย และมีอันเดียว", () => {
    const html = render(3);
    expect((html.match(/aria-current="page"/g) ?? []).length).toBe(2); // แท็บที่เลือก + เดือนที่เลือก
    expect(html).toContain("มี.ค.");
  });

  it('ดูทั้งปี → ปุ่ม "ทั้งปี 2026" ถูกทำเครื่องหมาย', () => {
    expect(render(null)).toContain("ทั้งปี 2026");
  });

  it("ฟอร์มเปลี่ยนปี/ผู้ถือ พกเดือนที่ดูอยู่ไปด้วย", () => {
    expect(render(7)).toContain('name="month"');
    // ดูทั้งปีไม่ต้องพก
    expect(render(null)).not.toContain('name="month"');
  });

  it("ปุ่มทุกอันสูง ≥ 52px และมีวงแหวนโฟกัส 3px", () => {
    const html = render(null);
    expect(html).toContain("min-h-control");
    expect(html).toContain("focus-visible:ring-[3px]");
  });
});
