import * as React from "react";
import { cn } from "@/lib/utils";

/** Pill / Badge สูง 30px ในตาราง, 34px แบบเดี่ยว ตาม Style Guide */
export function Pill({ className, size = "sm", ...props }: React.HTMLAttributes<HTMLSpanElement> & { size?: "sm" | "md" }) {
  return (
    <span
      className={cn(
        "inline-flex items-center rounded-pill border px-[10px] text-sm font-semibold",
        size === "sm" ? "h-[30px]" : "h-[34px] px-[14px]",
        className
      )}
      {...props}
    />
  );
}
