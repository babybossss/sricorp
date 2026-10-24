"use client";

import * as React from "react";
import { Dialog, DialogContent, DialogHeader, DialogFooter } from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { useRouter } from "next/navigation";
import { useApp } from "@/lib/store";
import { useTxForm } from "./use-tx-form";
import { StepType, StepHolder, StepDetail, StepConfirm } from "./tx-steps";

const STEP_LABELS = ["เลือกประเภท", "ผู้ถือกรรมสิทธิ์", "รายละเอียด", "แนบไฟล์ & ยืนยัน"];

/** ฟอร์มบันทึกรายการ 4 ขั้น (Desktop) — dialog สร้างผู้ติดต่อซ้อนอยู่ชั้นบน */
export function TxFormDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (v: boolean) => void }) {
  const api = useTxForm();
  const showToast = useApp((s) => s.showToast);
  const router = useRouter();
  const { step, setStep, draft, canSubmit, reset, submitting } = api;
  // ผลจาก DB ที่ต้องให้ผู้ใช้เห็นค้างไว้จนกว่าจะแก้ — ไม่ใช่ toast ที่หายเอง
  const [submitError, setSubmitError] = React.useState<string | null>(null);

  function close() {
    // กำลังบันทึกอยู่ห้ามปิด — ปิดแล้วไม่มีใครเห็นผล (สำเร็จหรือไม่) และผู้ใช้จะกดซ้ำ
    if (submitting) return;
    onOpenChange(false);
    setSubmitError(null);
    // หน่วงไว้ให้ dialog ปิดจบก่อนค่อยล้างค่า จะได้ไม่เห็นฟอร์มกระพริบ
    setTimeout(reset, 200);
  }

  async function next() {
    if (step < 4) {
      setStep(step + 1);
      return;
    }
    if (!canSubmit) return;
    setSubmitError(null);
    const outcome = await api.submit();
    if (!outcome.ok) {
      // ไม่ปิดฟอร์ม ไม่ล้างค่า — ผู้ใช้แก้แล้วกดใหม่ได้ ไม่ต้องกรอกทั้งหมดอีกรอบ
      setSubmitError(outcome.message);
      return;
    }
    const n = outcome.transactionIds.length;
    showToast(
      outcome.replayed
        ? "รายการนี้เพิ่งบันทึกไปแล้ว ระบบไม่ได้ลงซ้ำ"
        : n > 1
        ? `บันทึกเข้าสมุดบัญชีแล้ว ${n} รายการคู่กัน`
        : "บันทึกเข้าสมุดบัญชีแล้ว 1 รายการ"
    );
    router.refresh();
    close();
  }

  const nextDisabled =
    (step === 1 && !draft.typeKey) || (step === 2 && !draft.holderId) || (step === 4 && !canSubmit);

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
          {/* อยู่ในส่วนท้ายเพื่อให้เห็นทันทีหลังกดปุ่ม — ไม่ใช่ด้านบนที่เลื่อนพ้นจอไปแล้ว */}
          {submitError ? (
            <div role="alert" className="w-full rounded border border-neg bg-neg-bg p-[14px_16px] text-base leading-7 text-neg-fg">
              <b>บันทึกไม่สำเร็จ</b> — {submitError}
            </div>
          ) : null}
          <Button variant="secondary" disabled={submitting} onClick={() => (step > 1 ? setStep(step - 1) : close())}>
            ย้อนกลับ
          </Button>
          <Button onClick={() => void next()} disabled={nextDisabled}>
            {step === 4 ? (submitting ? "กำลังบันทึก…" : "บันทึกเข้าสมุดบัญชี") : "ถัดไป"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
