import * as React from "react";
import { Slot } from "@radix-ui/react-slot";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

/**
 * ปุ่มตาม Style Guide: สูง 52px (มือถือ 56px), ตัวอักษร 18px, มีข้อความกำกับเสมอ
 * ปุ่มไอคอนเดี่ยวไม่อนุญาต — variant `icon` ต้องมี aria-label
 */
const buttonVariants = cva(
  "inline-flex items-center justify-center gap-2 whitespace-nowrap rounded font-semibold transition-colors focus-visible:outline-none focus-visible:ring-[3px] focus-visible:ring-brand-600 focus-visible:ring-offset-2 disabled:pointer-events-none disabled:border-line disabled:bg-canvas disabled:text-ink-400",
  {
    variants: {
      variant: {
        primary: "border border-brand-600 bg-brand-600 text-white hover:bg-brand-700 hover:border-brand-700",
        secondary: "border border-line bg-surface text-ink-900 hover:border-ink-400",
        success: "border border-pos bg-pos text-white hover:brightness-95",
        danger: "border border-neg bg-surface text-neg hover:bg-neg-bg",
        ghost: "border-none bg-transparent text-ink-600 hover:bg-canvas",
        link: "border-none bg-transparent text-brand-600 hover:underline",
        quiet: "border border-line bg-surface text-brand-600 hover:bg-brand-50",
      },
      size: {
        default: "min-h-control px-[22px] text-base",
        sm: "min-h-[48px] px-[14px] text-sm",
        mobile: "min-h-control-mobile px-[18px] text-base",
        icon: "h-[52px] w-[48px] px-0",
      },
    },
    defaultVariants: { variant: "primary", size: "default" },
  }
);

export interface ButtonProps
  extends React.ButtonHTMLAttributes<HTMLButtonElement>,
    VariantProps<typeof buttonVariants> {
  asChild?: boolean;
}

const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant, size, asChild = false, ...props }, ref) => {
    const Comp = asChild ? Slot : "button";
    return <Comp className={cn(buttonVariants({ variant, size }), className)} ref={ref} {...props} />;
  }
);
Button.displayName = "Button";

export { Button, buttonVariants };
