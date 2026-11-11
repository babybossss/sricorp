"use client";

import * as React from "react";
import { useApp } from "@/lib/store";

export function Toast() {
  const toast = useApp((s) => s.toast);
  const clearToast = useApp((s) => s.clearToast);

  React.useEffect(() => {
    if (!toast) return;
    const t = setTimeout(clearToast, 5000);
    return () => clearTimeout(t);
  }, [toast, clearToast]);

  if (!toast) return null;

  return (
    <div
      role="status"
      className="fixed bottom-7 left-1/2 z-[80] flex -translate-x-1/2 animate-fadein items-center gap-4 rounded-card bg-ink-900 p-[14px_18px] text-white shadow-bar"
    >
      <span className="text-base">{toast}</span>
      <button onClick={clearToast} className="min-h-[44px] rounded-lg border border-white/35 px-3.5 text-sm font-semibold text-white">
        ปิด
      </button>
    </div>
  );
}
