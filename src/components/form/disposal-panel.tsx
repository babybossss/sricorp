"use client";

import * as React from "react";
import { Field } from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { Pill } from "@/components/ui/pill";
import { money } from "@/lib/format";
import type { DisposalResult } from "@/lib/disposal/capital-gain";
import type { RepaymentSplit } from "@/lib/disposal/repayment";
import type { PostingInput } from "@/lib/ledger/types";
import type { DisposalContext } from "@/lib/db/disposal-context";
import type { Installment } from "@/lib/loan/schedule";
import { JournalPreview } from "./journal-preview";
import { cn } from "@/lib/utils";
import {
  EMPTY_DISPOSAL,
  EMPTY_REPAYMENT,
  isManualSplit,
  signedUnrealized,
  type DisposalValue,
  type RepaymentValue,
} from "./disposal-value";

export { EMPTY_DISPOSAL, EMPTY_REPAYMENT, isManualSplit, signedUnrealized };
export type { DisposalValue, RepaymentValue };

/**
 * แผงคำนวณกำไร/ขาดทุนจากการขายทรัพย์
 *
 * **ต้นทุน ค่ารีโนเวทสะสม และส่วนเกินทุนจากการตีราคาที่ค้างอยู่ อ่านจากสมุด** (แสดงอย่างเดียว ไม่มีช่องให้พิมพ์ · D-115)
 * ผู้ใช้กรอกได้แค่ราคาขายจริงกับค่าใช้จ่ายในการขาย — ถ้าพิมพ์ต้นทุนเองได้ จะตัดต้นทุนน้อยกว่าจริงเพื่อให้กำไรสูงขึ้นได้โดยงบดุลยังดุล
 * ตัวเลขกำไร/ขาดทุนคำนวณใน `useTxForm()` ที่เดียว แผงนี้แสดงผลอย่างเดียว
 *
 * ยอดเงินของรายการนี้ **คำนวณจากราคาขาย − ค่าใช้จ่ายในการขาย** ไม่ให้พิมพ์เอง
 */
export function DisposalPanel({
  value,
  onChange,
  result,
  input,
  onDerivedAmount,
  assetChosen,
  state,
}: {
  value: DisposalValue;
  onChange: (v: DisposalValue) => void;
  /** ผลคำนวณจาก `useTxForm()` — แผงไม่คิดเลขเอง */
  result: DisposalResult | null;
  /** input ที่จะส่งเข้า engine จริง ใช้พรีวิวบรรทัดบัญชี */
  input: PostingInput | null;
  /** ส่งยอดสุทธิที่คำนวณได้กลับไปให้ฟอร์ม เพื่อให้ช่องจำนวนเงินตรงกันเสมอ */
  onDerivedAmount: (amount: number) => void;
  /** เลือกทรัพย์แล้วหรือยัง */
  assetChosen: boolean;
  /** ข้อมูลต้นทุนที่อ่านจากสมุด (`useTxForm().disposalState`) */
  state: { loading: boolean; error: string | null; ctx: DisposalContext | null; buildError: string | null };
}) {
  const patch = (p: Partial<DisposalValue>) => onChange({ ...value, ...p });

  // ยอดสุทธิเปลี่ยนเมื่อไร ช่องจำนวนเงินของฟอร์มต้องตามทันที
  const netProceeds = result?.netProceeds ?? null;
  React.useEffect(() => {
    if (netProceeds !== null) onDerivedAmount(netProceeds);
  }, [netProceeds, onDerivedAmount]);

  const ctx = state.ctx;
  return (
    <div className="flex flex-col gap-4 rounded-card border border-line bg-canvas p-4">
      <div className="text-base font-semibold">คำนวณกำไร/ขาดทุนจากการขาย</div>

      {!assetChosen ? (
        <div className="text-base leading-7 text-ink-600">
          เลือก<b>ทรัพย์ที่ขาย</b>ในช่อง “โปรเจค (ทรัพย์)” ด้านบนก่อน — ระบบจะอ่านต้นทุนและค่ารีโนเวทของทรัพย์ชิ้นนั้นจากสมุดให้ ไม่ต้องพิมพ์เอง
        </div>
      ) : state.loading ? (
        <div role="status" className="text-base text-ink-600">
          กำลังอ่านต้นทุนของทรัพย์จากสมุด…
        </div>
      ) : state.error ? (
        <div role="alert" className="rounded border border-neg bg-neg-bg p-[12px_14px] text-base leading-7 text-neg-fg">
          {state.error}
        </div>
      ) : ctx ? (
        <dl className="grid grid-cols-1 gap-x-6 gap-y-2 rounded border border-line bg-surface p-[14px_16px] text-base sm:grid-cols-3">
          <div>
            <dt className="text-sm text-ink-600">ต้นทุนรวมตามสมุด</dt>
            <dd className="font-semibold tabular-nums">{money(ctx.costBasis)} บาท</dd>
          </div>
          <div>
            <dt className="text-sm text-ink-600">ในนั้นเป็นค่ารีโนเวทสะสม</dt>
            <dd className="font-semibold tabular-nums">{money(ctx.renovation)} บาท</dd>
          </div>
          <div>
            <dt className="text-sm text-ink-600">{ctx.priorSurplus < 0 ? "ตีราคาลงที่ค้างอยู่" : "ตีราคาขึ้นที่ค้างอยู่"}</dt>
            <dd className="font-semibold tabular-nums">{money(Math.abs(ctx.priorSurplus))} บาท</dd>
          </div>
          <div className="text-sm leading-6 text-ink-600 sm:col-span-3">
            ตัวเลขสามช่องนี้อ่านจากสมุดที่บันทึกแล้ว แก้ในฟอร์มไม่ได้ · ถ้าไม่ถูกต้องให้แก้ที่รายการต้นทางก่อน
          </div>
        </dl>
      ) : null}

      {state.buildError && !state.loading && !state.error ? (
        <div role="alert" className="rounded border border-warn bg-warn-bg p-[12px_14px] text-base leading-7 text-warn-fg">
          {state.buildError}
        </div>
      ) : null}

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <Field label="ราคาขายจริง" required>
          <Input value={value.salePrice} onChange={(e) => patch({ salePrice: e.target.value })} inputMode="decimal" />
        </Field>
        <Field label="ค่าธรรมเนียม / ค่าใช้จ่ายในการขาย" hint="ค่านายหน้า ค่าโอน ภาษีธุรกิจเฉพาะ">
          <Input value={value.sellingCosts} onChange={(e) => patch({ sellingCosts: e.target.value })} inputMode="decimal" />
        </Field>
      </div>

      {result ? (
        <>
          <div className="flex flex-wrap items-center gap-4 rounded border border-line bg-surface p-[14px_16px]">
            <div>
              <div className="text-sm text-ink-600">เงินที่ได้สุทธิ</div>
              <div className="text-h2 font-semibold tabular-nums">{money(result.netProceeds)}</div>
            </div>
            <div>
              <div className="text-sm text-ink-600">
                {result.isGain ? "กำไรจากการขาย" : "ขาดทุนจากการขาย"}{" "}
                <span className="text-ink-400">Capital {result.isGain ? "gain" : "loss"}</span>
              </div>
              <div className={cn("text-h2 font-semibold tabular-nums", result.isGain ? "text-pos" : "text-neg")}>
                {result.isGain ? "+" : "−"}
                {money(Math.abs(result.capitalGain))}
              </div>
            </div>
            <div className="ml-auto text-sm leading-6 text-ink-600">
              ราคาขาย {money(result.salePrice)} − ค่าใช้จ่าย {money(result.sellingCosts)} − ต้นทุนตามสมุด {money(result.costBasis)}
            </div>
          </div>

          {result.unrealizedToReverse !== 0 ? (
            <div className="rounded border border-line bg-surface p-[12px_14px] text-base leading-7">
              ส่วนเกินทุนจากการตีราคาที่ค้างอยู่ {money(Math.abs(result.unrealizedToReverse))} บาท
              ระบบ<b>ล้างออกให้ในรายการนี้</b>ทั้งก้อน ไม่เข้ากำไรจากการขาย (กันนับซ้ำ: รอบแรกตอนตีราคา รอบสองตอนขายจริง)
            </div>
          ) : null}

          <JournalPreview input={input} />
        </>
      ) : (
        <div className="text-sm leading-6 text-ink-600">กรอกราคาขายเพื่อดูกำไร/ขาดทุนก่อนยืนยัน</div>
      )}
    </div>
  );
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
  paid,
  split,
  error,
  input,
}: {
  value: RepaymentValue;
  onChange: (v: RepaymentValue) => void;
  /** งวดที่ค้างตามสัญญา ถ้ามี */
  installment?: Installment;
  /** ยอดที่จ่ายจริง มาจากช่อง "จำนวนเงิน" ของฟอร์ม ไม่มีช่องซ้ำในแผงนี้ */
  paid: number;
  /** ผลการแยกจาก `useTxForm()` — แผงไม่แยกเอง */
  split: RepaymentSplit | null;
  error: string | null;
  input: PostingInput | null;
}) {
  const patch = (p: Partial<RepaymentValue>) => onChange({ ...value, ...p });
  const manualMode = isManualSplit(value, !!installment);

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
        ยอดที่จ่ายจริง <b className="tabular-nums text-ink-900">{money(paid)}</b> — ใช้ตัวเลขจากช่อง “จำนวนเงิน” ด้านบน
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
              <div className="text-h2 font-semibold tabular-nums">{money(split.principal)}</div>
            </div>
            <div>
              <div className="text-sm text-ink-600">ดอกเบี้ย <span className="text-ink-400">ค่าใช้จ่าย</span></div>
              <div className="text-h2 font-semibold tabular-nums text-neg">{money(split.interest)}</div>
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
