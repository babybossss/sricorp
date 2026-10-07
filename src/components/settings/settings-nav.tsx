"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { SETTINGS_MENU } from "@/lib/mock/dashboard";
import { cn } from "@/lib/utils";
import { usePermissions } from "@/components/auth/permissions-provider";
import { canOpen } from "@/lib/auth/routes";

export function SettingsNav() {
  const pathname = usePathname();
  const permissions = usePermissions();
  // ซ่อนหัวข้อที่กดแล้วเจอหน้าไม่มีสิทธิ์ (เช่น ผู้ใช้ & สิทธิ์ ต้องมี users.manage)
  const menu = SETTINGS_MENU.filter((m) => !m.href || canOpen(permissions, m.href));

  return (
    <div className="rounded-card border border-line bg-surface p-2.5 shadow-card">
      {menu.map((m) =>
        m.href ? (
          <Link
            key={m.label}
            href={m.href}
            className={cn(
              "block min-h-control rounded px-3.5 text-base leading-[52px] no-underline hover:bg-canvas hover:no-underline",
              pathname === m.href ? "bg-brand-50 font-semibold text-brand-600" : "text-ink-600"
            )}
          >
            {m.label}
          </Link>
        ) : (
          <div key={m.label} className="min-h-control px-3.5 text-base leading-[52px] text-ink-400">
            {m.label}
          </div>
        )
      )}
    </div>
  );
}

export function SettingsLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="grid items-start gap-4 lg:[grid-template-columns:260px_minmax(0,1fr)]">
      <SettingsNav />
      <div className="flex min-w-0 flex-col gap-4">{children}</div>
    </div>
  );
}
