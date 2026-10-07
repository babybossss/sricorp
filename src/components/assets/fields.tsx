import * as React from "react";
import { Input as BaseInput } from "@/components/ui/input";
import { Select as BaseSelect } from "@/components/ui/select";
import { cn } from "@/lib/utils";

/**
 * ช่องกรอกของโมดูลทรัพย์ — เหมือน `ui/input` · `ui/select` แต่วงแหวนโฟกัสเป็นสีเข้ม (brand-600) หนา 3px
 * ตัวต้นฉบับใช้ ring-brand-100 (ฟ้าอ่อนบนพื้นขาว เกือบมองไม่เห็น) ซึ่งไม่ตรง "เห็นชัดทุกพื้นหลัง"
 */
const RING = "focus-visible:ring-brand-600";

export const Input = React.forwardRef<HTMLInputElement, React.InputHTMLAttributes<HTMLInputElement>>(
  ({ className, ...props }, ref) => <BaseInput ref={ref} className={cn(RING, className)} {...props} />
);
Input.displayName = "Input";

export const Select = React.forwardRef<HTMLSelectElement, React.SelectHTMLAttributes<HTMLSelectElement>>(
  ({ className, ...props }, ref) => <BaseSelect ref={ref} className={cn(RING, className)} {...props} />
);
Select.displayName = "Select";
