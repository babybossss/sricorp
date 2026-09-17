import * as React from "react";
import { cn } from "@/lib/utils";

/** กรอบการ์ดที่เลื่อนแนวนอนได้ ครอบตารางหนาแน่นแบบ Stripe */
export function TableShell({ className, children }: { className?: string; children: React.ReactNode }) {
  return <div className={cn("overflow-auto rounded-card border border-line bg-surface shadow-card", className)}>{children}</div>;
}

export function Table({ className, minWidth, ...props }: React.TableHTMLAttributes<HTMLTableElement> & { minWidth?: number }) {
  return <table className={cn("w-full border-collapse text-base", className)} style={minWidth ? { minWidth } : undefined} {...props} />;
}

export function Th({ className, align = "left", ...props }: React.ThHTMLAttributes<HTMLTableCellElement> & { align?: "left" | "right" | "center" }) {
  return (
    <th
      className={cn(
        "border-b border-line bg-canvas p-[12px_10px] text-sm font-semibold text-ink-600",
        align === "right" ? "text-right" : align === "center" ? "text-center" : "text-left",
        className
      )}
      {...props}
    />
  );
}

export function Td({ className, align = "left", ...props }: React.TdHTMLAttributes<HTMLTableCellElement> & { align?: "left" | "right" | "center" }) {
  return (
    <td
      className={cn(
        "border-b border-line p-[12px_10px]",
        align === "right" ? "text-right" : align === "center" ? "text-center" : "text-left",
        className
      )}
      {...props}
    />
  );
}
