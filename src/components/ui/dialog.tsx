"use client";

import * as React from "react";
import * as DialogPrimitive from "@radix-ui/react-dialog";
import { cn } from "@/lib/utils";
import { Button } from "./button";

const Dialog = DialogPrimitive.Root;
const DialogTrigger = DialogPrimitive.Trigger;
const DialogClose = DialogPrimitive.Close;

const DialogOverlay = React.forwardRef<
  React.ElementRef<typeof DialogPrimitive.Overlay>,
  React.ComponentPropsWithoutRef<typeof DialogPrimitive.Overlay>
>(({ className, ...props }, ref) => (
  <DialogPrimitive.Overlay
    ref={ref}
    className={cn("fixed inset-0 z-[60] animate-fadein bg-[rgba(10,37,64,.45)]", className)}
    {...props}
  />
));
DialogOverlay.displayName = "DialogOverlay";

/**
 * ซ้อน dialog ได้ (ฟอร์มบันทึกรายการ → สร้างผู้ติดต่อ) โดยตัวลูกรับ zIndex สูงกว่า
 * ปิดตัวลูกแล้วต้องกลับมาที่ฟอร์มเดิมพร้อมค่าที่กรอกไว้ครบ (Backlog ข้อ 3)
 */
const DialogContent = React.forwardRef<
  React.ElementRef<typeof DialogPrimitive.Content>,
  React.ComponentPropsWithoutRef<typeof DialogPrimitive.Content> & {
    /** ความกว้างสูงสุด เช่น "max-w-[720px]" */
    width?: string;
    layer?: number;
  }
>(({ className, children, width = "max-w-[720px]", layer = 0, ...props }, ref) => (
  <DialogPrimitive.Portal>
    <DialogOverlay style={{ zIndex: 60 + layer * 10 }} />
    <div
      className="fixed inset-0 flex items-start justify-center overflow-auto p-4 md:p-10"
      style={{ zIndex: 61 + layer * 10 }}
    >
      <DialogPrimitive.Content
        ref={ref}
        className={cn("w-full overflow-hidden rounded-card bg-surface shadow-modal", width, className)}
        {...props}
      >
        {children}
      </DialogPrimitive.Content>
    </div>
  </DialogPrimitive.Portal>
));
DialogContent.displayName = "DialogContent";

function DialogHeader({ title, onClose }: { title: string; onClose?: () => void }) {
  return (
    <div className="flex items-center gap-4 border-b border-line p-[20px_24px]">
      <DialogPrimitive.Title className="mr-auto text-h2 font-semibold">{title}</DialogPrimitive.Title>
      <DialogPrimitive.Close asChild>
        <Button variant="secondary" size="sm" onClick={onClose}>
          ปิด
        </Button>
      </DialogPrimitive.Close>
    </div>
  );
}

const DialogDescription = DialogPrimitive.Description;

function DialogFooter({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn("flex flex-wrap justify-end gap-3 border-t border-line bg-surface p-[16px_24px]", className)} {...props} />;
}

export { Dialog, DialogTrigger, DialogClose, DialogContent, DialogHeader, DialogFooter, DialogDescription, DialogPrimitive };
