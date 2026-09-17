"use client";

import { useApp } from "@/lib/store";
import { MONTHS } from "@/lib/mock/entities";

export function MonthPicker() {
  const month = useApp((s) => s.month);
  const stepMonth = useApp((s) => s.stepMonth);

  return (
    <div className="flex items-center overflow-hidden rounded border border-line bg-surface">
      <button onClick={() => stepMonth(-1)} aria-label="เดือนก่อน" className="h-[52px] w-11 text-ink-600 hover:bg-canvas">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" className="mx-auto h-5 w-5">
          <path d="m15 18-6-6 6-6" />
        </svg>
      </button>
      <div className="min-w-[104px] text-center text-base font-semibold">{MONTHS[month]} 2026</div>
      <button onClick={() => stepMonth(1)} aria-label="เดือนถัดไป" className="h-[52px] w-11 text-ink-600 hover:bg-canvas">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" className="mx-auto h-5 w-5">
          <path d="m9 18 6-6-6-6" />
        </svg>
      </button>
    </div>
  );
}
