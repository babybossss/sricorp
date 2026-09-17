"use client";

import * as React from "react";
import { Field } from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { Pill } from "@/components/ui/pill";
import { money, parseAmount } from "@/lib/format";
import { computeDisposal } from "@/lib/disposal/capital-gain";
import { splitRepayment } from "@/lib/disposal/repayment";
import { previewPosting } from "@/lib/ledger/preview";
import type { PostingContext, PostingInput } from "@/lib/ledger/types";
import type { Installment } from "@/lib/loan/schedule";
import { cn } from "@/lib/utils";

/**
 * ตารางบรรทัดบัญชีที่ระบบจะลงให้
 *
 * ดึงจาก `previewPosting()` ซึ่งเรียก engine ตัวเดียวกับที่ใช้ลงบัญชีจริง
 * ไม่คำนวณคู่บัญชีเอง — สิ่งที่เห็นตรงนี้คือสิ่งที่จะถูกบันทึกจริง
 */
function JournalPreview({ input }: { input: PostingInput | null }) {
  const preview = input ? previewPosting(input) : null;

  if (!preview) return null;

  if (!preview.ok) {
    return (
      <div className="rounded border border-warn bg-warn-bg p-[12px_14px] text-sm leading-6 text-warn-fg">
        ยังแสดงบรรทัดบัญชีไม่ได้: {preview.reason}
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-1.5">
      <div className="flex flex-wrap items-center gap-2">
        <div className="text-sm font-semibold text-ink-600">ระบบจะลงบัญชีให้ดังนี้</div>
        <Pill className="border-pos bg-pos-bg text-pos-fg">สมดุล ✓</Pill>
        {preview.transactionCount > 1 ? (
          <Pill className="border-brand-100 bg-brand-50 text-brand-600">
            {preview.transactionCount} รายการคู่กัน
          </Pill>
        ) : null}
      </div>
      <div className="overflow-hidden rounded border border-line">
        <table className="w-full border-collapse text-sm">
          <thead>
            <tr className="bg-canvas">
              <th className="p-[8px_10px] text-left font-semibold text-ink-600">บัญชี</th>
              <th className="p-[8px_10px] text-right font-semibold text-ink-600">เดบิต</th>
              <th className="p-[8px_10px] text-right font-semibold text-ink-600">เครดิต</th>
            </tr>
          </thead>
          <tbody>
            {preview.lines.map((l, i) => (
              <tr key={`${l.coaCode}-${i}`} className="border-t border-line">
                <td className="p-[8px_10px]">
                  <span className="text-ink-400">{l.coaCode}</span> {l.label}
                  {l.memo ? <span className="text-ink-400"> · {l.memo}</span> : null}
                </td>
                <td className="p-[8px_10px] text-right">{l.debit ? money(l.debit) : "–"}</td>
                <td className="p-[8px_10px] text-right">{l.credit ? money(l.credit) : "–"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

export type DisposalValue = {
  costBasis: string;
  salePrice: string;
  sellingCosts: string;
  unrealizedGain: string;
};

export const EMPTY_DISPOSAL: DisposalValue = {
  costBasis: "",
  salePrice: "",
  sellingCosts: "",
  unrealizedGain: "",
};

/**
 * Backlog ข้อ 4 — แผงคำนวณกำไร/ขาดทุนจากการขาย
 * ต้นทุนดึงมาให้ (ในระบบจริงมาจาก ledger) แก้ค่าธรรมเนียมได้ก่อนยืนยัน
 *
 * ยอดเงินของรายการนี้ **คำนวณจากราคาขาย − ค่าใช้จ่ายในการขาย** ไม่ให้พิมพ์เอง
 * เพราะถ้าพิมพ์เองได้ ช่องจำนวนเงินกับตัวเลขในแผงนี้จะขัดกันเมื่อไรก็ได้
 */
export function DisposalPanel({
  value,
  onChange,
  context,
  onDerivedAmount,
}: {
  value: DisposalValue;
  onChange: (v: DisposalValue) => void;
  /** ข้อมูลรายการที่ฟอร์มรู้แล้ว — ใช้เรียก engine ตัวจริงมาพรีวิว */
  context: PostingContext | null;
  /** ส่งยอดสุทธิที่คำนวณได้กลับไปให้ฟอร์ม เพื่อให้ช่องจำนวนเงินตรงกันเสมอ */
  onDerivedAmount: (amount: number) => void;
}) {
  const patch = (p: Partial<DisposalValue>) => onChange({ ...value, ...p });

  const cost = parseAmount(value.costBasis);
  const price = parseAmount(value.salePrice);
  const ready = cost > 0 && price > 0;

  const result = ready
    ? computeDisposal({
        costBasis: cost,
        salePrice: price,
        sellingCosts: parseAmount(value.sellingCosts),
        unrealizedGain: parseAmount(value.unrealizedGain),
      })
    : null;

  // ยอดสุทธิเปลี่ยนเมื่อไร ช่องจำนวนเงินของฟอร์มต้องตามทันที
  const netProceeds = result?.netProceeds ?? null;
  React.useEffect(() => {
    if (netProceeds !== null && context && context.amount !== netProceeds) {
      onDerivedAmount(netProceeds);
    }
  }, [netProceeds, context, onDerivedAmount]);

  const input: PostingInput | null =
    context && result
      ? {
          ...context,
          amount: result.netProceeds,
          disposal: {
            costBasis: result.costBasis,
            salePrice: result.salePrice,
            sellingCosts: result.sellingCosts,
          },
        }
      : null;

  return (
    <div className="flex flex-col gap-4 rounded-card border border-line bg-canvas p-4">
      <div className="text-base font-semibold">คำนวณกำไร/ขาดทุนจากการขาย</div>

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <Field label="ต้นทุนตามบัญชี" hint="ดึงจากรายการซื้อและค่ารีโนเวทที่บันทึกไว้">
          <Input value={value.costBasis} onChange={(e) => patch({ costBasis: e.target.value })} inputMode="decimal" />
        </Field>
        <Field label="ราคาขายจริง" required>
          <Input value={value.salePrice} onChange={(e) => patch({ salePrice: e.target.value })} inputMode="decimal" />
        </Field>
        <Field label="ค่าธรรมเนียม / ค่าใช้จ่ายในการขาย" hint="ค่านายหน้า ค่าโอน ภาษีธุรกิจเฉพาะ">
          <Input value={value.sellingCosts} onChange={(e) => patch({ sellingCosts: e.target.value })} inputMode="decimal" />
        </Field>
        <Field label="กำไรยังไม่รับรู้ที่เคยบันทึกไว้" hint="จากการตีราคา — ต้องล้างออกพร้อมการขาย">
          <Input value={value.unrealizedGain} onChange={(e) => patch({ unrealizedGain: e.target.value })} inputMode="decimal" />
        </Field>
      </div>

      {result ? (
        <>
          <div className="flex flex-wrap items-center gap-4 rounded border border-line bg-surface p-[14px_16px]">
            <div>
              <div className="text-sm text-ink-600">เงินที่ได้สุทธิ</div>
              <div className="text-h2 font-semibold">{money(result.netProceeds)}</div>
            </div>
            <div>
              <div className="text-sm text-ink-600">
                {result.isGain ? "กำไรจากการขาย" : "ขาดทุนจากการขาย"}{" "}
                <span className="text-ink-400">Capital {result.isGain ? "gain" : "loss"}</span>
              </div>
              <div className={cn("text-h2 font-semibold", result.isGain ? "text-pos" : "text-neg")}>
                {result.isGain ? "+" : "−"}
                {money(Math.abs(result.capitalGain))}
              </div>
            </div>
            <div className="ml-auto text-sm leading-6 text-ink-600">
              ราคาขาย {money(result.salePrice)} − ค่าใช้จ่าย {money(result.sellingCosts)} − ต้นทุน {money(result.costBasis)}
            </div>
          </div>

          {result.unrealizedToReverse > 0 ? (
            <div className="rounded border border-warn bg-warn-bg p-[12px_14px] text-sm leading-6 text-warn-fg">
              ⚠ กำไรยังไม่รับรู้ {money(result.unrealizedToReverse)} ของทรัพย์ชิ้นนี้ต้องถูก<b>ล้างออกด้วยรายการปรับปรุงแยกต่างหาก</b> —
              ไม่งั้นจะนับกำไรซ้ำสองรอบ (รอบแรกตอนตีราคา รอบสองตอนขายจริง)
              <div className="mt-1 text-ink-600">
                รายการตีราคายังไม่มีในระบบรอบนี้ ตัวเลขนี้จึงยังไม่ถูกลงบัญชีให้อัตโนมัติ
              </div>
            </div>
          ) : null}

          <JournalPreview input={input} />
        </>
      ) : (
        <div className="text-sm leading-6 text-ink-600">กรอกต้นทุนและราคาขายเพื่อดูกำไร/ขาดทุนก่อนยืนยัน</div>
      )}
    </div>
  );
}

export type RepaymentValue = {
  manualPrincipal: string;
  manualInterest: string;
  useManual: boolean;
};

export const EMPTY_REPAYMENT: RepaymentValue = {
  manualPrincipal: "",
  manualInterest: "",
  useManual: false,
};

/**
 * ต้องกรอกเงินต้น/ดอกเบี้ยเองหรือไม่
 *
 * ไม่มีตารางงวดอ้างอิง = บังคับกรอกเสมอ ไม่ว่าจะติ๊กช่องหรือไม่ — ระบบไม่เดาให้
 * กฎนี้ต้องใช้ชุดเดียวกันทั้งในแผงและในรายการช่องที่ยังขาด ไม่งั้นจะปล่อยให้กดถัดไปทั้งที่ยังไม่ครบ
 */
export function isManualSplit(value: RepaymentValue, hasSchedule: boolean): boolean {
  return value.useManual || !hasSchedule;
}

/**
 * Backlog ข้อ 5 — แผงแยกเงินต้น/ดอกเบี้ย
 * ดึงงวดที่ค้างจากสัญญามาตั้งค่าให้ แล้วให้ผู้ใช้ยืนยันหรือแก้ได้
 *
 * ยอดที่จ่ายใช้ช่อง "จำนวนเงิน" ของฟอร์มตัวเดียว ไม่มีช่องซ้ำในแผงนี้
 */
export function RepaymentPanel({
  value,
  onChange,
  installment,
  context,
}: {
  value: RepaymentValue;
  onChange: (v: RepaymentValue) => void;
  /** งวดที่ค้างตามสัญญา ถ้ามี */
  installment?: Installment;
  context: PostingContext | null;
}) {
  const patch = (p: Partial<RepaymentValue>) => onChange({ ...value, ...p });

  const paid = context?.amount ?? 0;

  const manualMode = isManualSplit(value, !!installment);
  // ยังไม่กรอกอะไรเลยก็อย่าเพิ่งขึ้น error ให้ตกใจ
  const manualTouched = value.manualPrincipal.trim() !== "" || value.manualInterest.trim() !== "";

  let split: ReturnType<typeof splitRepayment> | null = null;
  let error: string | null = null;

  if (paid > 0 && (!manualMode || manualTouched)) {
    try {
      split = splitRepayment({
        amountPaid: paid,
        installment,
        manualPrincipal: manualMode ? parseAmount(value.manualPrincipal) : undefined,
        manualInterest: manualMode ? parseAmount(value.manualInterest) : undefined,
      });
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    }
  }

  const input: PostingInput | null =
    context && split
      ? { ...context, repayment: { principal: split.principal, interest: split.interest } }
      : null;

  return (
    <div className="flex flex-col gap-4 rounded-card border border-line bg-canvas p-4">
      <div className="text-base font-semibold">แยกเงินต้น / ดอกเบี้ย</div>

      {installment ? (
        <div className="rounded border border-brand-100 bg-brand-50 p-[12px_14px] text-sm leading-6">
          งวดที่ {installment.period} ครบกำหนด {installment.dueDate} · ตามสัญญาต้องจ่าย{" "}
          <b>{money(installment.total)}</b> (เงินต้น {money(installment.principal)} + ดอกเบี้ย {money(installment.interest)})
        </div>
      ) : (
        <div className="rounded border border-warn bg-warn-bg p-[12px_14px] text-sm leading-6 text-warn-fg">
          ไม่มีตารางงวดอ้างอิง — ต้องระบุเงินต้นและดอกเบี้ยเอง ระบบจะไม่เดาให้
        </div>
      )}

      <div className="rounded border border-line bg-surface p-[12px_14px] text-sm leading-6 text-ink-600">
        ยอดที่จ่ายจริง <b className="text-ink-900">{money(paid)}</b> — ใช้ตัวเลขจากช่อง “จำนวนเงิน” ด้านบน
        {paid <= 0 ? <span className="text-warn-fg"> · ยังไม่ได้กรอก</span> : null}
      </div>

      <label className="flex min-h-control items-center gap-2.5 text-base">
        <input
          type="checkbox"
          checked={manualMode}
          disabled={!installment}
          onChange={(e) => patch({ useManual: e.target.checked })}
          className="h-[26px] w-[26px] accent-brand-600"
        />
        ระบุเงินต้น/ดอกเบี้ยเอง
        {!installment ? <span className="text-sm text-ink-400">(บังคับ เพราะไม่มีตารางงวด)</span> : null}
      </label>

      {manualMode ? (
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <Field label="เงินต้น" hint="ลดหนี้สินในงบดุล ไม่ใช่ค่าใช้จ่าย">
            <Input value={value.manualPrincipal} onChange={(e) => patch({ manualPrincipal: e.target.value })} inputMode="decimal" />
          </Field>
          <Field label="ดอกเบี้ย" hint="เป็นค่าใช้จ่ายใน P&L">
            <Input value={value.manualInterest} onChange={(e) => patch({ manualInterest: e.target.value })} inputMode="decimal" />
          </Field>
        </div>
      ) : null}

      {error ? (
        <div className="rounded border border-neg bg-neg-bg p-[12px_14px] text-sm leading-6 text-neg-fg">{error}</div>
      ) : null}

      {split ? (
        <>
          <div className="flex flex-wrap items-center gap-6 rounded border border-line bg-surface p-[14px_16px]">
            <div>
              <div className="text-sm text-ink-600">เงินต้น <span className="text-ink-400">ลดหนี้สิน</span></div>
              <div className="text-h2 font-semibold">{money(split.principal)}</div>
            </div>
            <div>
              <div className="text-sm text-ink-600">ดอกเบี้ย <span className="text-ink-400">ค่าใช้จ่าย</span></div>
              <div className="text-h2 font-semibold text-neg">{money(split.interest)}</div>
            </div>
            {split.isPartial ? (
              <Pill className="border-warn bg-warn-bg text-warn-fg">ไม่ตรงงวด</Pill>
            ) : (
              <Pill className="border-pos bg-pos-bg text-pos-fg">ตรงตามงวด</Pill>
            )}
          </div>

          {split.note ? (
            <div className="rounded border border-warn bg-warn-bg p-[12px_14px] text-sm leading-6 text-warn-fg">
              {split.note}
            </div>
          ) : null}

          <JournalPreview input={input} />
        </>
      ) : null}
    </div>
  );
}
