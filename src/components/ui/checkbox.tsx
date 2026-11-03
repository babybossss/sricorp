import * as React from "react";
import { cn } from "@/lib/utils";

/** กล่องติ๊ก 26px — ใหญ่พอสำหรับนิ้วและสายตาผู้สูงอายุ */
const Checkbox = React.forwardRef<HTMLInputElement, React.InputHTMLAttributes<HTMLInputElement>>(
  ({ className, ...props }, ref) => (
    <input
      ref={ref}
      type="checkbox"
      className={cn("h-[26px] w-[26px] flex-none accent-brand-600 focus-visible:outline-none focus-visible:ring-[3px] focus-visible:ring-brand-600 focus-visible:ring-offset-2", className)}
      {...props}
    />
  )
);
Checkbox.displayName = "Checkbox";

export { Checkbox };
