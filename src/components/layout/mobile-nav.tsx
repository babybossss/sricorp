"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { cn } from "@/lib/utils";
import { useApp } from "@/lib/store";
import { usePermissions } from "@/components/auth/permissions-provider";
import { canOpen } from "@/lib/auth/routes";
import { NAV } from "./sidebar";

/**
 * เมนูสำหรับจอแคบกว่า lg — Sidebar ถูกซ่อนที่ขนาดนั้น
 *
 * ทำไมต้องมี: Sidebar กว้าง 256px ตายตัว ที่จอ 390px เหลือที่ให้เนื้อหาแค่ 134px
 * ซ่อน Sidebar เฉยๆ จะทำให้ไม่มีทางไปหน้าอื่นเลย จึงต้องมีเมนูแทนที่
 *
 * ใช้ **รายการเดียวกับ Sidebar** (`NAV`) และกรองสิทธิ์ด้วยกติกาตัวเดียวกัน (`canOpen`)
 * ห้ามทำรายการเมนูที่สอง ไม่งั้นวันหนึ่งสองที่จะไม่ตรงกันเงียบๆ
 *
 * ทุกปุ่มมีข้อความกำกับ (ห้ามปุ่มไอคอนเดี่ยว) · สูง ≥ 52px · วงแหวนโฟกัส 3px
 * เลื่อนตามแนวนอนได้เมื่อเมนูยาวเกินจอ
 */
export function MobileNav({ pendingApprovals }: { pendingApprovals: number | null }) {
  const pathname = usePathname();
  const permissions = usePermissions();
  const largeText = useApp((s) => s.largeText);
  const toggleLargeText = useApp((s) => s.toggleLargeText);
  const items = NAV.filter((n) => canOpen(permissions, n.href));

  return (
    <nav
      aria-label="เมนูหลัก"
      className="flex gap-2 overflow-x-auto border-b border-line bg-surface p-[10px_16px] lg:hidden"
    >
      {items.map((n) => {
        const active = n.match ? n.match(pathname) : pathname.startsWith(n.href);
        return (
          <Link
            key={n.href}
            href={n.href}
            aria-current={active ? "page" : undefined}
            className={cn(
              "flex min-h-control flex-none items-center gap-2 rounded border px-3 text-base no-underline hover:no-underline",
              "focus-visible:outline-none focus-visible:ring-[3px] focus-visible:ring-brand-600",
              active ? "border-brand-600 bg-brand-50 font-semibold text-brand-600" : "border-line text-ink-600"
            )}
          >
            {n.label}
            {/* ป้ายเลขมาจากค่าจริง · null = อ่านไม่ได้ → ไม่แสดง (ห้ามแสดง 0 แทน "ไม่รู้") */}
            {n.href === "/approvals" && pendingApprovals !== null && pendingApprovals > 0 ? (
              <span className="inline-flex h-[26px] min-w-[26px] items-center justify-center rounded-pill bg-warn px-[7px] text-sm font-bold tabular-nums text-[#3d2600]">
                {pendingApprovals}
              </span>
            ) : null}
          </Link>
        );
      })}

      {/* โหมดตัวใหญ่อยู่ใน Sidebar เท่านั้นมาก่อน — จอแคบจึงไม่มีทางเปิดเลย ทั้งที่ผู้ใช้มีผู้สูงอายุ */}
      <button
        onClick={toggleLargeText}
        aria-pressed={largeText}
        className={cn(
          "flex min-h-control flex-none items-center gap-2 rounded border px-3 text-base",
          "focus-visible:outline-none focus-visible:ring-[3px] focus-visible:ring-brand-600",
          largeText ? "border-pos bg-pos-bg font-semibold text-pos-fg" : "border-line text-ink-600"
        )}
      >
        ตัวใหญ่ +2px
      </button>
    </nav>
  );
}
