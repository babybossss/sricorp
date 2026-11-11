import * as React from "react";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import type { Tag } from "./types";

/**
 * สีของ chip มาจาก `tag.colorToken` (ชื่อโทเคนใน tailwind.config.ts)
 * Tailwind สร้างคลาสจากข้อความที่เขียนตรงๆ เท่านั้น จึงต้องมีตารางคลาสแบบเต็มที่นี่ — ไม่ประกอบชื่อคลาสจากสตริง
 * โทเคนที่ไม่รู้จัก/ว่าง = สีกลาง (ไม่ใช่สีสุ่ม และไม่ใช่ hex)
 */
const TONE: Record<string, string> = {
  brand: "border-brand-100 bg-brand-50 text-brand-700",
  pos: "border-pos-bd bg-pos-bg text-pos-fg",
  neg: "border-neg-bd bg-neg-bg text-neg-fg",
  warn: "border-warn bg-warn-bg text-warn-fg",
  info: "border-info-bd bg-info-bg text-info-fg",
};
const NEUTRAL = "border-line bg-canvas text-ink-900";
/** tag ที่ปิดแล้ว: ขอบประ + ข้อความ "ปิดใช้งานแล้ว" — ไม่พึ่งสีอย่างเดียว */
const INACTIVE = "border-dashed border-ink-400 bg-canvas text-ink-600";

export function toneClass(colorToken: string | null | undefined): string {
  return (colorToken && TONE[colorToken]) || NEUTRAL;
}

/** สัดส่วน → ข้อความเปอร์เซ็นต์ (0.6 → "60%") · ทศนิยมสูงสุด 4 ตำแหน่ง ตรงกับ numeric(9,6) */
export function formatPercent(fraction: number): string {
  const pct = (Math.round(fraction * 1_000_000) / 1_000_000) * 100;
  const text = pct.toFixed(4).replace(/\.?0+$/, "");
  return `${text === "" ? "0" : text}%`;
}

export type TagChipProps = {
  tag: Pick<Tag, "nameTh" | "isActive" | "colorToken">;
  /** ชื่อชนิด (เช่น "โปรเจกต์") — อ่านจาก tag_kinds ห้ามพิมพ์เอง */
  kindLabel?: string;
  /** น้ำหนักเป็นสัดส่วน แสดงเป็นเปอร์เซ็นต์ต่อท้ายชื่อ */
  weight?: number | null;
  /** ใส่ = มีปุ่ม "เอา tag นี้ออก" (ปุ่มมีข้อความเสมอ ไม่ใช่ ✕ เดี่ยว) */
  onRemove?: () => void;
  removeDisabled?: boolean;
  className?: string;
};

export function TagChip({ tag, kindLabel, weight, onRemove, removeDisabled, className }: TagChipProps) {
  const chip = (
    <span
      className={cn(
        "inline-flex min-h-[34px] max-w-full flex-wrap items-center gap-x-2 rounded-pill border px-[14px] py-0.5 text-sm font-semibold tabular-nums",
        tag.isActive ? toneClass(tag.colorToken) : INACTIVE,
        !onRemove && className
      )}
    >
      {kindLabel ? <span className="font-normal">{kindLabel}</span> : null}
      <span className="break-words">{tag.nameTh}</span>
      {weight !== undefined && weight !== null ? <span>· {formatPercent(weight)}</span> : null}
      {!tag.isActive ? <span className="font-normal">(ปิดใช้งานแล้ว)</span> : null}
    </span>
  );

  if (!onRemove) return chip;

  return (
    <span className={cn("inline-flex flex-wrap items-center gap-2", className)}>
      {chip}
      <Button
        type="button"
        variant="quiet"
        className="max-sm:min-h-control-mobile"
        onClick={onRemove}
        disabled={removeDisabled}
      >
        เอา tag นี้ออก
        {/* ผู้ใช้โปรแกรมอ่านจอได้ยินว่าเอาอันไหนออก — ข้อความที่เห็นอยู่ในชื่อปุ่มครบ */}
        <span className="sr-only"> ({tag.nameTh})</span>
      </Button>
    </span>
  );
}
