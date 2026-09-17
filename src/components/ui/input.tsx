import * as React from "react";
import { cn } from "@/lib/utils";

const Input = React.forwardRef<HTMLInputElement, React.InputHTMLAttributes<HTMLInputElement>>(
  ({ className, ...props }, ref) => (
    <input
      ref={ref}
      className={cn(
        "min-h-control w-full rounded border border-line bg-surface px-[14px] text-base text-ink-900 placeholder:text-ink-400",
        "focus-visible:outline-none focus-visible:border-brand-600 focus-visible:ring-[3px] focus-visible:ring-brand-100",
        className
      )}
      {...props}
    />
  )
);
Input.displayName = "Input";

/** ช่องจำนวนเงิน — ตัวใหญ่ หนา ชิดขวาได้ตามบริบท */
const AmountInput = React.forwardRef<HTMLInputElement, React.InputHTMLAttributes<HTMLInputElement>>(
  ({ className, ...props }, ref) => (
    <Input ref={ref} inputMode="decimal" className={cn("min-h-[64px] px-4 text-[28px] font-semibold", className)} {...props} />
  )
);
AmountInput.displayName = "AmountInput";

export { Input, AmountInput };
