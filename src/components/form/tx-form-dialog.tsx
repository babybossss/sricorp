"use client";

import * as React from "react";
import { Dialog, DialogContent, DialogHeader, DialogFooter } from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { useApp } from "@/lib/store";
import { useTxForm } from "./use-tx-form";
import { StepType, StepHolder, StepDetail, StepConfirm } from "./tx-steps";

const STEP_LABELS = ["เลือกประเภท", "ผู้ถือ & บัญชี", "รายละเอียด", "แนบไฟล์ & ยืนยัน"];

/** ฟอร์มบันทึกรายการ 4 ขั้น (Desktop) — dialog สร้างผู้ติดต่อซ้อนอยู่ชั้นบน */
export function TxFormDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (v: boolean) => void }) {
  const api = useTxForm();
  const showToast = useApp((s) => s.showToast);
  const { step, setStep, draft, missing, reset } = api;

  function close() {
    onOpenChange(false);
    // หน่วงไว้ให้ dialog ปิดจบก่อนค่อยล้างค่า จะได้ไม่เห็นฟอร์มกระพริบ
    setTimeout(reset, 200);
  }

  function next() {
    if (step < 4) {
      setStep(step + 1);
      return;
    }
    if (missing.length) return;
    showToast(draft.skipApproval ? "บันทึกเข้าสมุดบัญชีแล้ว 1 รายการ" : "ส่งอนุมัติแล้ว 1 รายการ");
    close();
  }

  const nextDisabled = (step === 1 && !draft.typeKey) || (step === 4 && missing.length > 0);

  return (
    <Dialog open={open} onOpenChange={(v) => (v ? onOpenChange(true) : close())}>
      <DialogContent aria-describedby={undefined}>
        <DialogHeader title="บันทึกรายการ" onClose={close} />

        <div className="flex flex-wrap gap-2 border-b border-line p-[16px_24px]">
          {STEP_LABELS.map((label, i) => {
            const n = i + 1;
            return (
              <div key={label} className="flex min-w-[120px] flex-1 items-center gap-2">
                <span
                  className={cn(
                    "flex h-8 w-8 flex-none items-center justify-center rounded-pill border text-sm font-bold",
                    n === step ? "border-brand-600 bg-brand-600 text-white" : n < step ? "border-brand-600 bg-brand-50 text-brand-600" : "border-line bg-surface text-ink-400"
                  )}
                >
                  {n}
                </span>
                <span className={cn("text-sm", n === step ? "text-ink-900" : "text-ink-400")}>{label}</span>
              </div>
            );
          })}
        </div>

        <div className="flex min-h-[280px] flex-col gap-4 p-6">
          {step === 1 ? <StepType api={api} onPicked={() => setStep(2)} /> : null}
          {step === 2 ? <StepHolder api={api} /> : null}
          {step === 3 ? <StepDetail api={api} contactLayer={1} /> : null}
          {step === 4 ? <StepConfirm api={api} /> : null}
        </div>

        <DialogFooter>
          <Button variant="secondary" onClick={() => (step > 1 ? setStep(step - 1) : close())}>
            ย้อนกลับ
          </Button>
          <Button onClick={next} disabled={nextDisabled}>
            {step === 4 ? (draft.skipApproval ? "บันทึกเข้าสมุดบัญชี" : "ส่งอนุมัติ") : "ถัดไป"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
