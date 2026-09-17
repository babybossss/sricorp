import * as React from "react";
import { cn } from "@/lib/utils";

/** label + control + ข้อความช่วย/ข้อผิดพลาด — ทุกช่องต้องมีข้อความกำกับเสมอ */
export function Field({
  label,
  hint,
  error,
  required,
  className,
  children,
}: {
  label: string;
  hint?: string;
  error?: string;
  required?: boolean;
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <label className={cn("flex flex-col gap-1.5", className)}>
      <span className={cn("text-sm", error ? "text-neg" : "text-ink-600")}>
        {label}
        {required ? <span className="text-neg"> *</span> : null}
      </span>
      {children}
      {error ? <span className="text-sm text-neg">{error}</span> : hint ? <span className="text-sm text-ink-400">{hint}</span> : null}
    </label>
  );
}
