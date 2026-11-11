"use client";

import * as React from "react";
import { cn } from "@/lib/utils";
import { dmyToIso, isoToDmy } from "@/lib/format";

/**
 * ช่องวันที่ที่ **กดแล้วขึ้นปฏิทินให้จิ้ม**
 *
 * ใช้ `<input type="date">` ของเบราว์เซอร์เอง จึงได้ปฏิทินจริงบนมือถือและเดสก์ท็อป
 * โดยไม่ต้องลงไลบรารีเพิ่ม และผู้สูงอายุไม่ต้องพิมพ์ วว/ดด/ปปปป เอง
 *
 * **ค่าที่เก็บในฟอร์มยังเป็น `วว/ดด/ปปปป` เหมือนเดิมทุกประการ**
 * คอมโพเนนต์นี้แปลงไป-กลับที่ขอบเท่านั้น ตัวตรวจและ engine จึงไม่ต้องแก้อะไรเลย
 * (`dmyToIso` รับทั้งสองรูปแบบอยู่แล้ว แต่เราคืนรูปแบบเดิมเพื่อไม่ให้มีสองมาตรฐาน)
 *
 * ค่าที่ผู้ใช้กรอกไว้แล้วแต่ยังอ่านเป็นวันที่ไม่ได้ จะ **ไม่ถูกลบทิ้ง** —
 * ส่งค่าว่างให้ input (ปฏิทินแสดงไม่ได้) แต่ค่าในฟอร์มยังอยู่ให้ตัวตรวจทักท้วงตามปกติ
 */
export const DateInput = React.forwardRef<
  HTMLInputElement,
  {
    /**
     * ค่าปัจจุบันในรูปแบบ วว/ดด/ปปปป (หรือค่าที่ยังกรอกไม่ครบ)
     *
     * เว้นไว้ได้เมื่ออยู่ในฟอร์มที่ส่งค่าด้วย `name` (ไม่ควบคุมค่าจาก React)
     * กรณีนั้นค่าที่ส่งออกไปจะเป็น `yyyy-mm-dd` ซึ่ง `dmyToIso` ฝั่ง server รับอยู่แล้ว
     */
    value?: string;
    onChange?: (dmy: string) => void;
    /** ขอบเขตที่เลือกได้ — รับเป็น วว/ดด/ปปปป เหมือนกัน (เช่น ห้ามเลือกวันในอนาคต) */
    min?: string;
    max?: string;
    className?: string;
  } & Omit<React.InputHTMLAttributes<HTMLInputElement>, "value" | "onChange" | "type" | "min" | "max">
>(({ value, onChange, min, max, className, ...props }, ref) => (
  <input
    ref={ref}
    type="date"
    // อ่านเป็นวันที่ไม่ได้ = ส่งว่างให้ widget แต่ไม่แตะค่าในฟอร์ม
    // value ไม่ถูกส่งมา = ปล่อยเป็น input ที่ไม่ควบคุมค่า (ฟอร์มอ่านจาก name เอง)
    {...(value === undefined ? {} : { value: dmyToIso(value) ?? "" })}
    min={min ? (dmyToIso(min) ?? undefined) : undefined}
    max={max ? (dmyToIso(max) ?? undefined) : undefined}
    // input คืน yyyy-mm-dd · ล้างช่อง = คืนค่าว่าง ไม่ใช่วันที่มั่ว
    onChange={onChange ? (e) => onChange(e.target.value ? isoToDmy(e.target.value) : "") : undefined}
    className={cn(
      "min-h-control w-full rounded border border-line bg-surface px-[14px] text-base text-ink-900",
      "focus-visible:outline-none focus-visible:border-brand-600 focus-visible:ring-[3px] focus-visible:ring-brand-600",
      "disabled:bg-canvas disabled:text-ink-400",
      className
    )}
    {...props}
  />
));
DateInput.displayName = "DateInput";
