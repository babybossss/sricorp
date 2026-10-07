import * as React from "react";
import { Pill } from "@/components/ui/pill";
import { DialogPrimitive } from "@/components/ui/dialog";
import { Button } from "./tall-button";
import { cn } from "@/lib/utils";
import type { AssetDraft } from "@/lib/mock/assets";
import { DRAFT_NOT_COUNTED, STATUS_LABEL } from "./asset-drafts";

/**
 * กล่องเตือนว่าร่างยังไม่นับในพอร์ต — ใช้สีเตือน (ไม่ใช่สีเขียว) โดยตั้งใจ
 * เพื่อไม่ให้หน้าตาเหมือน "บันทึกสำเร็จ" · ข้อความมาจากค่าคงที่เดียว `DRAFT_NOT_COUNTED`
 */
export function NotCountedNotice({ className, children }: { className?: string; children?: React.ReactNode }) {
  return (
    <div
      role="note"
      data-testid="draft-not-counted"
      className={cn("rounded border border-warn bg-warn-bg p-[12px_14px] text-base leading-7 text-warn-fg", className)}
    >
      <b>{DRAFT_NOT_COUNTED}</b>
      {children ? <div className="mt-1">{children}</div> : null}
    </div>
  );
}

export function KindPill({ kind }: { kind: AssetDraft["kind"] }) {
  return kind === "create" ? (
    <Pill className="whitespace-nowrap border-info bg-info-bg text-info-fg">สร้างทรัพย์ใหม่</Pill>
  ) : (
    <Pill className="whitespace-nowrap border-brand-100 bg-brand-50 text-brand-700">แก้ไขทรัพย์</Pill>
  );
}

const STATUS_TONE: Record<AssetDraft["status"], string> = {
  pending: "border-warn bg-warn-bg text-warn-fg",
  approved: "border-pos bg-pos-bg text-pos-fg",
  rejected: "border-neg bg-neg-bg text-neg-fg",
  cancelled: "border-line bg-canvas text-ink-600",
};

export function StatusPill({ status }: { status: AssetDraft["status"] }) {
  return <Pill className={cn("whitespace-nowrap", STATUS_TONE[status])}>{STATUS_LABEL[status]}</Pill>;
}

/** ลิงก์ที่หน้าตาเป็นปุ่ม — สูง ≥ 52px มีข้อความ · วงแหวนโฟกัส 3px */
export const LINK_BUTTON_CLASS =
  "inline-flex min-h-control max-md:min-h-control-mobile items-center justify-center rounded border px-[22px] text-base font-semibold no-underline hover:no-underline focus-visible:outline-none focus-visible:ring-[3px] focus-visible:ring-brand-600 focus-visible:ring-offset-2";

/**
 * หัวแผง/ป๊อปอัพ — หน้าตาเดียวกับ `DialogHeader` แต่ปุ่ม "ปิด" สูง 52px (มือถือ 56px)
 * ตัวต้นฉบับใช้ size="sm" = 48px ซึ่งต่ำกว่ามาตรฐานปุ่ม · `ui/dialog` อยู่นอกขอบเขตงานนี้ จึงไม่แก้ที่ต้นทาง
 */
export function SheetHeader({ title, onClose }: { title: string; onClose?: () => void }) {
  return (
    <div className="flex items-center gap-4 border-b border-line p-[20px_24px]">
      <DialogPrimitive.Title className="mr-auto text-h2 font-semibold">{title}</DialogPrimitive.Title>
      <DialogPrimitive.Close asChild>
        <Button variant="secondary" onClick={onClose}>
          ปิด
        </Button>
      </DialogPrimitive.Close>
    </div>
  );
}
