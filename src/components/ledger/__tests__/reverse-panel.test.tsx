/**
 * การแสดงผลของแผง "แก้รายการที่ลงผิด" — กติกา UI ของโปรเจกต์ (ผู้ใช้มีผู้สูงอายุ)
 *
 * ที่ต้องมีเทสต์จับ: **ปุ่มทุกปุ่มมีข้อความกำกับ** (ห้ามปุ่มไอคอนเดี่ยว) ·
 * ปุ่มสูง ≥52px · วงแหวนโฟกัส 3px · และ **ไม่มีปุ่มยืนยันขั้นสุดท้ายโผล่มาตั้งแต่แรก**
 * (ถ้ามี ผู้ใช้กดครั้งเดียวแล้วเงินเข้าสมุดทันทีโดยไม่ได้เขียนเหตุผล)
 */
import { describe, expect, it, vi } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { PermissionsProvider } from "@/components/auth/permissions-provider";
import type { Permission } from "@/lib/auth/permissions";

vi.mock("next/navigation", () => ({ useRouter: () => ({ refresh: () => {} }) }));
vi.mock("@/app/actions/reverse-entry", () => ({ reverseEntry: async () => ({ ok: true }), voidEntry: async () => ({ ok: true }) }));

import { ReversePanel } from "../reverse-panel";
import type { PanelEntry } from "../reverse-flow";

const entry: PanelEntry = { id: "txn-1", source: "manual", reversesId: null };
const render = (perms: Permission[], e: PanelEntry = entry) =>
  renderToStaticMarkup(
    <PermissionsProvider permissions={perms}>
      <ReversePanel entry={e} />
    </PermissionsProvider>
  );

/** ข้อความที่ผู้ใช้เห็น (ตัดแท็กออก) */
const text = (html: string) => html.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ");
/** ข้อความในปุ่มแต่ละปุ่ม */
const buttonLabels = (html: string) =>
  [...html.matchAll(/<button[^>]*>([\s\S]*?)<\/button>/g)].map((m) => text(m[1]).trim());

const ALL: Permission[] = ["ledger.approve", "txn.void"];

describe("ReversePanel · การแสดงผลขั้นแรก", () => {
  it("บอกว่าลบไม่ได้ และเสนอสองทางที่ถูก พร้อมข้อความกำกับทุกปุ่ม", () => {
    const html = render(ALL);
    const t = text(html);
    expect(t).toMatch(/ลบไม่ได้/);
    const labels = buttonLabels(html);
    expect(labels).toHaveLength(2);
    expect(labels[0]).toMatch(/กลับรายการ/);
    expect(labels[1]).toMatch(/ยกเลิกใบนี้/);
    // ห้ามปุ่มไอคอนเดี่ยว: ทุกปุ่มต้องมีตัวอักษรจริง
    for (const l of labels) expect(l.length).toBeGreaterThan(3);
  });

  it("ยังไม่มีช่องเหตุผลและไม่มีปุ่มยืนยันขั้นสุดท้ายตั้งแต่แรก", () => {
    const html = render(ALL);
    expect(html).not.toContain("<textarea");
    expect(buttonLabels(html).some((l) => /ยืนยัน/.test(l))).toBe(false);
  });

  it("ปุ่มสูง ≥52px และมีวงแหวนโฟกัส 3px (มาจากคอมโพเนนต์ Button)", () => {
    const html = render(ALL);
    expect(html).toContain("min-h-control");
    expect(html).toContain("focus-visible:ring-[3px]");
  });

  it("ไม่มีสิทธิ์ → ไม่มีปุ่มให้กด แต่บอกเหตุเป็นคำ", () => {
    const html = render(["ledger.read"]);
    expect(buttonLabels(html)).toHaveLength(0);
    expect(text(html)).toMatch(/ไม่มีสิทธิ์/);
  });

  it("มี txn.void แต่ไม่มี ledger.approve → ยกเลิกใบได้ แต่ลงใบกลับรายการไม่ได้", () => {
    const labels = buttonLabels(render(["txn.void"]));
    expect(labels).toHaveLength(1);
    expect(labels[0]).toMatch(/ยกเลิกใบนี้/);
  });

  it("ใบกลับรายการ → เสนอแต่ 'ยกเลิกใบนี้' และอธิบายว่าทำไมกลับซ้อนไม่ได้", () => {
    const html = render(ALL, { id: "rev-1", source: "reverse", reversesId: "txn-1" });
    const labels = buttonLabels(html);
    expect(labels).toHaveLength(1);
    expect(labels[0]).toMatch(/ยกเลิกใบนี้/);
    expect(text(html)).toMatch(/เป็นใบกลับรายการอยู่แล้ว/);
  });
});
