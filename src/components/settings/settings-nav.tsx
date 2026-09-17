"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { SETTINGS_MENU } from "@/lib/mock/dashboard";
import { cn } from "@/lib/utils";

export function SettingsNav() {
  const pathname = usePathname();

  return (
    <div className="rounded-card border border-line bg-surface p-2.5 shadow-card">
      {SETTINGS_MENU.map((m) =>
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
