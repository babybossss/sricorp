import * as React from "react";
import { Button as BaseButton, type ButtonProps } from "@/components/ui/button";
import { cn } from "@/lib/utils";

/**
 * ปุ่มของโมดูลทรัพย์ — เหมือน `ui/button` แต่บนมือถือสูง 56px ตามมาตรฐาน (เดสก์ท็อป 52px)
 * `ui/button` มีขนาด `mobile` อยู่แล้วแต่ไม่สลับตามจอเอง จึงสลับด้วย breakpoint ตรงนี้
 */
export const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(({ className, ...props }, ref) => (
  <BaseButton ref={ref} className={cn("max-md:min-h-control-mobile", className)} {...props} />
));
Button.displayName = "Button";
