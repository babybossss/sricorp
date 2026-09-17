"use client";

import * as React from "react";
import Link from "next/link";
import { EntitySwitcher } from "./entity-switcher";
import { MonthPicker } from "./month-picker";
import { Button } from "@/components/ui/button";
import { TxFormDialog } from "@/components/form/tx-form-dialog";
import { useApp } from "@/lib/store";

export function Topbar({ title }: { title: string }) {
  const [formOpen, setFormOpen] = React.useState(false);
  const largeText = useApp((s) => s.largeText);

  // โหมดตัวใหญ่ตั้งที่ <html> เพื่อให้มีผลทุกหน้าและทุก portal
  React.useEffect(() => {
    document.documentElement.dataset.largeText = String(largeText);
  }, [largeText]);

  return (
    <>
      <header className="sticky top-0 z-20 flex min-h-[72px] flex-wrap items-center gap-3 border-b border-line bg-surface p-[10px_20px]">
        <div className="mr-auto text-h2 font-semibold">{title}</div>

        <EntitySwitcher />
        <MonthPicker />

        <Button onClick={() => setFormOpen(true)}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" className="h-5 w-5">
            <path d="M5 12h14" />
            <path d="M12 5v14" />
          </svg>
          บันทึกรายการ
        </Button>

        <Button asChild variant="secondary">
          <Link href="/approvals" className="no-underline hover:no-underline">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" className="h-5 w-5">
              <path d="M10.268 21a2 2 0 0 0 3.464 0" />
              <path d="M3.262 15.326A1 1 0 0 0 4 17h16a1 1 0 0 0 .74-1.673C19.41 13.956 18 12.499 18 8A6 6 0 0 0 6 8c0 4.499-1.411 5.956-2.738 7.326" />
            </svg>
            แจ้งเตือน
            <span className="inline-flex h-[26px] min-w-[26px] items-center justify-center rounded-pill bg-neg px-[7px] text-sm font-bold text-white">7</span>
          </Link>
        </Button>

        <div className="flex flex-none items-center gap-2.5 pl-1">
          <div className="flex h-11 w-11 items-center justify-center rounded-pill bg-brand-50 text-base font-bold text-brand-600">ธ</div>
          <div className="text-sm leading-5">
            <div className="font-semibold">ธนากร</div>
            <div className="text-ink-400">Management</div>
          </div>
        </div>
      </header>

      <TxFormDialog open={formOpen} onOpenChange={setFormOpen} />
    </>
  );
}
