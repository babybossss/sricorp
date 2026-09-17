import * as React from "react";
import { cn } from "@/lib/utils";

/**
 * ใช้ <select> ของเบราว์เซอร์: บนมือถือได้ native picker ที่แตะง่าย
 * และผู้สูงอายุคุ้นเคยกว่า dropdown ที่ทำเอง
 */
const Select = React.forwardRef<HTMLSelectElement, React.SelectHTMLAttributes<HTMLSelectElement>>(
  ({ className, ...props }, ref) => (
    <select
      ref={ref}
      className={cn(
        "min-h-control w-full rounded border border-line bg-surface px-3 text-base text-ink-900",
        "focus-visible:outline-none focus-visible:border-brand-600 focus-visible:ring-[3px] focus-visible:ring-brand-100",
        "disabled:bg-canvas disabled:text-ink-400",
        className
      )}
      {...props}
    />
  )
);
Select.displayName = "Select";

export { Select };
