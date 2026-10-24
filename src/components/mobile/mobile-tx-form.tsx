"use client";

import * as React from "react";
import { useRouter } from "next/navigation";
import { PhoneFrame } from "./phone-frame";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { useApp } from "@/lib/store";
import { useTxForm } from "@/components/form/use-tx-form";
import { StepType, StepHolder, StepDetail, StepConfirm } from "@/components/form/tx-steps";
import { Toast } from "@/components/layout/toast";

const TITLES = ["เลือกประเภทรายการ", "ผู้ถือกรรมสิทธิ์", "รายละเอียด", "แนบไฟล์ & ยืนยัน"];

/**
 * ฟอร์มมือถือใช้ state hook และ step component ชุดเดียวกับ desktop
 * ตารางกฎหมวดย่อยและปุ่มสร้างผู้ติดต่อจึงทำงานเหมือนกันทั้งสองมุมมอง
 */
export function MobileTxForm() {
  const router = useRouter();
  const api = useTxForm();
  const showToast = useApp((s) => s.showToast);
  const { step, setStep, draft, canSubmit, reset, submitting } = api;
  // ผลจาก DB ที่ต้องให้ผู้ใช้เห็นค้างไว้จนกว่าจะแก้ — ไม่ใช่ toast ที่หายเอง
  const [submitError, setSubmitError] = React.useState<string | null>(null);

  async function next() {
    if (step < 4) {
      setStep(step + 1);
      return;
    }
    if (!canSubmit) return;
    setSubmitError(null);
    const outcome = await api.submit();
    if (!outcome.ok) {
      // ไม่ล้างค่า ไม่เปลี่ยนหน้า — ผู้ใช้แก้แล้วกดใหม่ได้
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
    reset();
    router.push("/m");
  }

  const nextDisabled =
    (step === 1 && !draft.typeKey) || (step === 2 && !draft.holderId) || (step === 4 && !canSubmit);

  return (
    <div className="min-h-screen bg-canvas py-6">
      <PhoneFrame className="flex flex-col bg-surface">
        <div className="flex items-center gap-3 border-b border-line p-[14px_16px]">
          <Button variant="secondary" size="sm" onClick={() => (step > 1 ? setStep(step - 1) : router.push("/m"))}>
            ย้อนกลับ
          </Button>
          <div className="text-lg font-semibold">บันทึกรายการ</div>
        </div>

        <div className="flex gap-1.5 border-b border-line p-[12px_16px]">
          {[1, 2, 3, 4].map((n) => (
            <div key={n} className="flex flex-1 flex-col items-center gap-1.5">
              <div className={cn("h-1.5 w-full rounded-pill", n <= step ? "bg-brand-600" : "bg-line")} />
              <div className={cn("text-sm font-semibold", n <= step ? "text-brand-600" : "text-ink-400")}>{n}</div>
            </div>
          ))}
        </div>

        <div className="flex min-h-[420px] flex-col gap-3 p-4">
          <div className="text-h2 font-semibold">{TITLES[step - 1]}</div>
          {step === 1 ? <StepType api={api} onPicked={() => setStep(2)} narrow /> : null}
          {step === 2 ? <StepHolder api={api} /> : null}
          {/* layer 0 เพราะฟอร์มมือถือไม่ได้อยู่ใน dialog — contact dialog จึงเป็นชั้นแรก */}
          {step === 3 ? <StepDetail api={api} contactLayer={0} narrow /> : null}
          {step === 4 ? <StepConfirm api={api} /> : null}
        </div>

        <div className="flex flex-col gap-2 border-t border-line p-[12px_16px_20px]">
          {submitError ? (
            <div role="alert" className="rounded border border-neg bg-neg-bg p-[14px_16px] text-base leading-7 text-neg-fg">
              <b>บันทึกไม่สำเร็จ</b> — {submitError}
            </div>
          ) : null}
          <Button size="mobile" onClick={() => void next()} disabled={nextDisabled}>
            {step === 4 ? (submitting ? "กำลังบันทึก…" : "บันทึกเข้าสมุดบัญชี") : "ถัดไป"}
          </Button>
          <Button size="mobile" variant="secondary" onClick={() => (step > 1 ? setStep(step - 1) : router.push("/m"))}>
            ย้อนกลับ
          </Button>
        </div>
      </PhoneFrame>
      <Toast />
    </div>
  );
}
