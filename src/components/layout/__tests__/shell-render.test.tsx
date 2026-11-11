import { describe, expect, it, vi } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { PermissionsProvider } from "@/components/auth/permissions-provider";
import type { Permission } from "@/lib/auth/permissions";
import { PERMISSIONS } from "@/lib/auth/permissions";

/**
 * ด่าน "render ได้จริงไม่ crash"
 *
 * เทสต์อื่นในโฟลเดอร์นี้อ่านจากโค้ดต้นฉบับ (ตรวจว่าเขียนถูก) แต่ไม่ได้ render
 * ด่านนี้ **render จริง** เพื่อจับความผิดที่เห็นได้เฉพาะตอนทำงาน เช่น
 * - อ่านฟิลด์ที่ไม่มีใน store (`hydrateLargeText` เพิ่มใหม่)
 * - import วนกัน (MobileNav เอา `NAV` มาจาก Sidebar)
 * - prop ใหม่ (`pendingApprovals`) ที่ส่งไม่ถึงหรือชนิดไม่ตรง
 *
 * หน้าหลังล็อกอินเปิดจากเบราว์เซอร์ในกล่องนี้ไม่ได้ (ไม่มี session จริง
 * middleware เด้ง 307 ก่อน render) จึง render คอมโพเนนต์ตรงๆ แทน
 */
vi.mock("next/navigation", () => ({ usePathname: () => "/dashboard" }));

const wrap = (node: React.ReactNode, perms: Permission[]) =>
  renderToStaticMarkup(<PermissionsProvider permissions={perms}>{node}</PermissionsProvider>);

const ALL = [...PERMISSIONS] as Permission[];

describe("Sidebar render ได้", () => {
  it.each([
    ["ไม่มีของรออนุมัติ", 0],
    ["มีของรออนุมัติ 3", 3],
    ["อ่านตัวนับไม่ได้", null],
  ])("%s", async (_label, pending) => {
    const { Sidebar } = await import("../sidebar");
    const html = wrap(<Sidebar pendingApprovals={pending as number | null} />, ALL);
    expect(html).toContain("สมุดบัญชี");
    expect(html).toContain("โหมดตัวใหญ่");
    // ป้ายเลขขึ้นเฉพาะเมื่อมีของรออนุมัติจริง
    if (pending && pending > 0) expect(html).toContain(">3<");
    else expect(html).not.toMatch(/>\d+</);
  });

  it("ไม่มีสิทธิ์เลย → ไม่ crash และไม่โชว์เมนูที่กดไม่ได้", async () => {
    const { Sidebar } = await import("../sidebar");
    const html = wrap(<Sidebar pendingApprovals={5} />, []);
    expect(html).toContain("SRI OS");
    expect(html).not.toContain("คิวอนุมัติ");
  });
});

describe("MobileNav render ได้", () => {
  it("มีเมนู มีข้อความกำกับทุกปุ่ม และมีสวิตช์ตัวใหญ่", async () => {
    const { MobileNav } = await import("../mobile-nav");
    const html = wrap(<MobileNav pendingApprovals={2} />, ALL);
    expect(html).toContain("สมุดบัญชี");
    expect(html).toContain("ตัวใหญ่ +2px");
    expect(html).toContain(">2<");
    expect(html).toContain("lg:hidden");
  });

  it("อ่านตัวนับไม่ได้ (null) → ไม่โชว์ป้ายเลข", async () => {
    const { MobileNav } = await import("../mobile-nav");
    const html = wrap(<MobileNav pendingApprovals={null} />, ALL);
    expect(html).not.toMatch(/>\d+</);
  });

  it("ไม่มีสิทธิ์เลย → ไม่ crash", async () => {
    const { MobileNav } = await import("../mobile-nav");
    expect(wrap(<MobileNav pendingApprovals={null} />, [])).toContain("ตัวใหญ่ +2px");
  });
});

describe("LargeTextBoot render ได้ (เพิ่งย้ายมาอยู่ layout ราก)", () => {
  it("ไม่ render อะไรออกมา และไม่ crash เวลาไม่มี window", async () => {
    const { LargeTextBoot } = await import("../large-text-boot");
    expect(renderToStaticMarkup(<LargeTextBoot />)).toBe("");
  });
});

describe("store: ช่องที่คอมโพเนนต์เรียกต้องมีจริง", () => {
  it("useApp มี largeText · toggleLargeText · hydrateLargeText และไม่มีสถานะเดือนแล้ว", async () => {
    const { useApp } = await import("@/lib/store");
    const s = useApp.getState() as Record<string, unknown>;
    expect(typeof s.largeText).toBe("boolean");
    expect(typeof s.toggleLargeText).toBe("function");
    expect(typeof s.hydrateLargeText).toBe("function");
    expect(s.month).toBeUndefined();
    expect(s.stepMonth).toBeUndefined();
  });

  it("toggleLargeText ทำงานได้แม้ localStorage ใช้ไม่ได้ (โหมดส่วนตัว)", async () => {
    const { useApp } = await import("@/lib/store");
    const before = useApp.getState().largeText;
    // ไม่มี window ในเทสต์แบบ node → การเขียน localStorage ต้องถูก catch ไม่ใช่โยนทิ้ง
    expect(() => useApp.getState().toggleLargeText()).not.toThrow();
    expect(useApp.getState().largeText).toBe(!before);
    expect(() => useApp.getState().hydrateLargeText()).not.toThrow();
  });
});
