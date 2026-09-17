"use client";

import Image from "next/image";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { cn } from "@/lib/utils";
import { useApp } from "@/lib/store";
import { COMING_SOON } from "@/lib/mock/dashboard";
import { Button } from "@/components/ui/button";

type NavItem = { href: string; label: string; badge?: string; icon: React.ReactNode; match?: (p: string) => boolean };

const icon = (d: string, d2?: string) => (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" className="h-[22px] w-[22px] flex-none">
    <path d={d} />
    {d2 ? <path d={d2} /> : null}
  </svg>
);

const NAV: NavItem[] = [
  { href: "/dashboard", label: "หน้าแรก", icon: icon("m3 9 9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z", "M9 22V12h6v10") },
  { href: "/ledger", label: "สมุดบัญชี", icon: icon("M12 7v14", "M3 18a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h5a4 4 0 0 1 4 4 4 4 0 0 1 4-4h5a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1h-6a3 3 0 0 0-3 3 3 3 0 0 0-3-3z") },
  { href: "/approvals", label: "คิวอนุมัติ", badge: "7", icon: icon("M22 11.08V12a10 10 0 1 1-5.93-9.14", "m9 11 3 3L22 4") },
  { href: "/balance", label: "งบดุล & ทรัพย์สิน", icon: icon("M12 3v18", "M3 7h2c2 0 5-1 7-2 2 1 5 2 7 2h2"), match: (p) => p.startsWith("/balance") || p.startsWith("/assets") },
  { href: "/contacts", label: "ผู้ติดต่อ", icon: icon("M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2", "M9 3a4 4 0 1 0 0 8 4 4 0 0 0 0-8") },
  { href: "/settings/banks", label: "ตั้งค่า", icon: icon("M20 7h-9", "M14 17H5"), match: (p) => p.startsWith("/settings") },
];

export function Sidebar() {
  const pathname = usePathname();
  const largeText = useApp((s) => s.largeText);
  const toggleLargeText = useApp((s) => s.toggleLargeText);

  return (
    <nav className="sticky top-0 flex min-h-screen w-64 flex-none flex-col gap-1 border-r border-line bg-surface p-[16px_12px_24px]">
      <Link href="/dashboard" className="flex items-center gap-2.5 p-[8px_10px_18px] no-underline hover:no-underline">
        <Image src="/sri-logo.png" alt="SRI" width={40} height={40} className="h-10 w-10 object-contain" priority />
        <span>
          <span className="block text-lg font-bold tracking-[.02em] text-brand-600">SRI OS</span>
          <span className="block text-sm leading-[18px] text-ink-400">Company OS</span>
        </span>
      </Link>

      {NAV.map((n) => {
        const active = n.match ? n.match(pathname) : pathname.startsWith(n.href);
        return (
          <Link
            key={n.href}
            href={n.href}
            className={cn(
              "flex min-h-control items-center gap-3 rounded px-3 text-base no-underline hover:bg-canvas hover:no-underline",
              active ? "bg-brand-50 font-semibold text-brand-600" : "text-ink-600"
            )}
          >
            {n.icon}
            <span className="flex-1">{n.label}</span>
            {n.badge ? (
              <span className="inline-flex h-[26px] min-w-[28px] flex-none items-center justify-center rounded-pill bg-warn px-2 text-sm font-bold text-[#3d2600]">
                {n.badge}
              </span>
            ) : null}
          </Link>
        );
      })}

      <div className="mt-[18px] p-[0_12px_6px] text-sm text-ink-400">มุมมองมือถือ</div>
      <Link href="/m" className="flex min-h-control items-center rounded px-3 text-base text-ink-600 no-underline hover:bg-canvas hover:no-underline">
        หน้าแรก (390)
      </Link>
      <Link href="/m/new" className="flex min-h-control items-center rounded px-3 text-base text-ink-600 no-underline hover:bg-canvas hover:no-underline">
        บันทึกรายการ (390)
      </Link>

      <div className="mt-[18px] p-[0_12px_6px] text-sm text-ink-400">เร็วๆ นี้</div>
      {COMING_SOON.map((s) => (
        <div key={s} className="flex min-h-[44px] items-center px-3 text-sm text-ink-400">
          {s}
        </div>
      ))}

      {/* โหมดตัวใหญ่ +2px — ตั้งค่าได้รายผู้ใช้ ตาม Style Guide */}
      <button
        onClick={toggleLargeText}
        aria-pressed={largeText}
        className="mt-[18px] flex min-h-control items-center gap-3 rounded border border-line bg-surface px-3 text-base text-ink-600 hover:border-ink-400"
      >
        <span className="flex-1 text-left">โหมดตัวใหญ่ +2px</span>
        <span className={cn("relative h-7 w-12 flex-none rounded-pill", largeText ? "bg-pos" : "bg-line")}>
          <span className="absolute top-1 h-5 w-5 rounded-pill bg-white transition-[left] duration-150" style={{ left: largeText ? 24 : 4 }} />
        </span>
      </button>

      <Button asChild variant="secondary" size="sm" className="mt-2 font-normal text-ink-600">
        <Link href="/login" className="no-underline hover:no-underline">ดูหน้าเข้าสู่ระบบ</Link>
      </Button>
    </nav>
  );
}
