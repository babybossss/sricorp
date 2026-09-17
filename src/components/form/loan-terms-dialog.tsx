"use client";

import * as React from "react";
import { Dialog, DialogContent, DialogHeader, DialogFooter } from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Field } from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { Select } from "@/components/ui/select";
import { Pill } from "@/components/ui/pill";
import { TableShell, Table, Th, Td } from "@/components/ui/table";
import { ContactPicker } from "./contact-picker";
import { money, parseAmount } from "@/lib/format";
import {
  buildSchedule,
  summarize,
  INTEREST_METHOD_LABEL,
  INTEREST_METHOD_HINT,
  type InterestMethod,
  type LoanTerms,
  type Installment,
  type RatePeriod,
} from "@/lib/loan/schedule";

/**
 * Backlog ข้อ 2 — ฟอร์มเงื่อนไขสัญญากู้ / ให้กู้
 *
 * เปิดเมื่อหมวดย่อยที่เลือกมี `requires: ["loanTerms"]`
 * กรอกเงื่อนไขแล้วระบบสร้าง **ตารางงวดชำระ** ให้ทันที แยกเงินต้น/ดอกเบี้ยทุกงวด
 * เพื่อให้หน้า "ยืนยันรับ-จ่าย" และ "ค้างรับ/ค้างจ่าย" ดึงไปใช้ได้อัตโนมัติ
 */

export type LoanTermsValue = {
  contactId: string;
  principal: string;
  rate: string;
  ratePeriod: RatePeriod;
  method: InterestMethod;
  installments: string;
  startDate: string;
  paymentDay: string;
  collateral: string;
  fileName: string;
  /** ตารางงวดที่สร้างจากเงื่อนไขข้างบน */
  schedule: Installment[];
};

export const EMPTY_LOAN_TERMS: LoanTermsValue = {
  contactId: "",
  principal: "",
  rate: "",
  ratePeriod: "month",
  method: "interest_only",
  installments: "12",
  startDate: "2026-09-01",
  paymentDay: "",
  collateral: "",
  fileName: "",
  schedule: [],
};

/** แปลงค่าที่กรอกเป็น terms — คืน null ถ้ายังกรอกไม่พอจะคำนวณ */
function toTerms(v: LoanTermsValue): LoanTerms | null {
  const principal = parseAmount(v.principal);
  const rate = Number(v.rate);
  const installments = Number(v.installments);
  if (!principal || principal <= 0) return null;
  if (!Number.isFinite(rate) || rate < 0) return null;
  if (!installments || installments <= 0) return null;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(v.startDate)) return null;
  return {
    principal,
    // ผู้ใช้กรอกเป็นเปอร์เซ็นต์ เช่น 1.25 → 0.0125
    rate: rate / 100,
    ratePeriod: v.ratePeriod,
    method: v.method,
    installments,
    startDate: v.startDate,
    paymentDay: v.paymentDay ? Number(v.paymentDay) : undefined,
  };
}

export function LoanTermsDialog({
  open,
  onOpenChange,
  value,
  onSave,
  /** ฝั่งไหน: เรากู้เขา หรือ เราให้เขากู้ — เปลี่ยนแค่ถ้อยคำ */
  direction,
  layer = 1,
}: {
  open: boolean;
  onOpenChange: (v: boolean) => void;
  value: LoanTermsValue;
  onSave: (v: LoanTermsValue) => void;
  direction: "borrow" | "lend";
  layer?: number;
}) {
  const [form, setForm] = React.useState<LoanTermsValue>(value);
  const [touched, setTouched] = React.useState(false);

  // เปิด dialog ใหม่ทุกครั้งให้เริ่มจากค่าที่บันทึกไว้ล่าสุด
  React.useEffect(() => {
    if (open) {
      setForm(value);
      setTouched(false);
    }
  }, [open, value]);

  const patch = (p: Partial<LoanTermsValue>) => setForm((f) => ({ ...f, ...p }));

  const terms = toTerms(form);
  const schedule = React.useMemo(() => {
    if (!terms) return [];
    try {
      return buildSchedule(terms);
    } catch {
      return [];
    }
  }, [terms]);

  const total = schedule.length ? summarize(schedule) : null;

  const who = direction === "borrow" ? "ยืมจากใคร" : "ให้ใครยืม";
  const whoHint = direction === "borrow" ? "ผู้ให้กู้ / ธนาคาร" : "ผู้กู้ / ผู้ขายฝาก";

  const missing: string[] = [];
  if (!form.contactId) missing.push(who);
  if (!parseAmount(form.principal)) missing.push("วงเงิน");
  if (!form.rate.trim()) missing.push("อัตราดอกเบี้ย");
  if (!schedule.length) missing.push("เงื่อนไขที่คำนวณงวดได้");

  function save() {
    setTouched(true);
    if (missing.length) return;
    onSave({ ...form, schedule });
    onOpenChange(false);
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent width="max-w-[860px]" layer={layer} aria-describedby={undefined}>
        <DialogHeader title={direction === "borrow" ? "เงื่อนไขสัญญากู้" : "เงื่อนไขสัญญาให้กู้ / ขายฝาก"} />

        <div className="flex max-h-[70vh] flex-col gap-4 overflow-auto p-6">
          <div className="rounded border border-brand-100 bg-brand-50 p-[12px_14px] text-sm leading-6">
            กรอกเงื่อนไขแล้วระบบจะสร้าง<b>ตารางงวดชำระ</b>ให้ทันที แยกเงินต้นกับดอกเบี้ยทุกงวด
            เพื่อให้หน้า &ldquo;ยืนยันรับ-จ่าย&rdquo; และ &ldquo;ค้างรับ/ค้างจ่าย&rdquo; ดึงไปใช้ได้เอง
          </div>

          <ContactPicker
            value={form.contactId}
            onSelect={(id) => patch({ contactId: id })}
            label={`${who} (${whoHint})`}
            required
            layer={layer + 1}
            suggestKind={direction === "borrow" ? "lender" : "borrower"}
          />

          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <Field
              label="วงเงิน (บาท)"
              required
              error={touched && !parseAmount(form.principal) ? "กรอกวงเงินก่อน" : undefined}
            >
              <Input
                value={form.principal}
                onChange={(e) => patch({ principal: e.target.value })}
                inputMode="decimal"
                placeholder="เช่น 10,000,000"
              />
            </Field>
            <Field label="วันที่รับเงิน / จ่ายเงิน" required>
              <Input value={form.startDate} onChange={(e) => patch({ startDate: e.target.value })} placeholder="yyyy-mm-dd" />
            </Field>
          </div>

          <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
            <Field label="อัตราดอกเบี้ย (%)" required error={touched && !form.rate.trim() ? "กรอกอัตราดอกเบี้ย" : undefined}>
              <Input
                value={form.rate}
                onChange={(e) => patch({ rate: e.target.value })}
                inputMode="decimal"
                placeholder="เช่น 1.25"
              />
            </Field>
            <Field label="ต่อ">
              <Select value={form.ratePeriod} onChange={(e) => patch({ ratePeriod: e.target.value as RatePeriod })}>
                <option value="month">ต่อเดือน</option>
                <option value="year">ต่อปี</option>
              </Select>
            </Field>
            <Field label="จำนวนงวด" required>
              <Input value={form.installments} onChange={(e) => patch({ installments: e.target.value })} inputMode="numeric" />
            </Field>
          </div>

          <Field label="วิธีคิดดอกเบี้ย" hint={INTEREST_METHOD_HINT[form.method]}>
            <Select value={form.method} onChange={(e) => patch({ method: e.target.value as InterestMethod })}>
              {(Object.keys(INTEREST_METHOD_LABEL) as InterestMethod[]).map((m) => (
                <option key={m} value={m}>
                  {INTEREST_METHOD_LABEL[m]}
                </option>
              ))}
            </Select>
          </Field>

          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <Field label="วันชำระของแต่ละเดือน" hint="เว้นว่างไว้จะใช้วันเดียวกับวันรับเงิน">
              <Input value={form.paymentDay} onChange={(e) => patch({ paymentDay: e.target.value })} inputMode="numeric" placeholder="เช่น 5" />
            </Field>
            <Field label="หลักประกัน (ถ้ามี)">
              <Input value={form.collateral} onChange={(e) => patch({ collateral: e.target.value })} placeholder="เช่น โฉนดเลขที่ ..." />
            </Field>
          </div>

          <Field label="เอกสารสัญญาแนบ" hint="ระบบนี้เก็บข้อมูลสัญญา ไม่ใช่เครื่องมือร่างสัญญา">
            <Input value={form.fileName} onChange={(e) => patch({ fileName: e.target.value })} placeholder="เช่น loan-agreement.pdf" />
          </Field>

          {/* ตารางงวดที่ระบบสร้างให้ */}
          {total ? (
            <div className="flex flex-col gap-2">
              <div className="flex flex-wrap items-center gap-3">
                <div className="text-base font-semibold">ตารางงวดชำระที่ระบบสร้างให้</div>
                <Pill className="border-pos bg-pos-bg text-pos-fg">{total.installments} งวด</Pill>
                <span className="text-sm text-ink-600">
                  เงินต้นรวม {money(total.totalPrincipal)} · ดอกเบี้ยรวม {money(total.totalInterest)} ·
                  จ่ายจริงรวม <b className="text-ink-900">{money(total.totalPayment)}</b>
                </span>
              </div>

              <TableShell className="max-h-[280px]">
                <Table minWidth={620}>
                  <thead>
                    <tr>
                      <Th className="p-[10px_12px]">งวด</Th>
                      <Th className="p-[10px_12px]">ครบกำหนด</Th>
                      <Th align="right" className="p-[10px_12px]">เงินต้น</Th>
                      <Th align="right" className="p-[10px_12px]">ดอกเบี้ย</Th>
                      <Th align="right" className="p-[10px_12px]">รวมงวดนี้</Th>
                      <Th align="right" className="p-[10px_12px]">เงินต้นคงเหลือ</Th>
                    </tr>
                  </thead>
                  <tbody>
                    {schedule.map((r) => (
                      <tr key={r.period} className={r.period % 2 ? "bg-surface" : "bg-[#FCFDFE]"}>
                        <Td className="p-[10px_12px]">{r.period}</Td>
                        <Td className="whitespace-nowrap p-[10px_12px]">{r.dueDate}</Td>
                        <Td align="right" className="whitespace-nowrap p-[10px_12px]">{money(r.principal)}</Td>
                        <Td align="right" className="whitespace-nowrap p-[10px_12px] text-pos-fg">{money(r.interest)}</Td>
                        <Td align="right" className="whitespace-nowrap p-[10px_12px] font-semibold">{money(r.total)}</Td>
                        <Td align="right" className="whitespace-nowrap p-[10px_12px] text-ink-600">{money(r.balance)}</Td>
                      </tr>
                    ))}
                  </tbody>
                </Table>
              </TableShell>

              <div className="text-sm leading-6 text-ink-400">
                เงินต้นทุกงวดรวมกันเท่ากับวงเงินพอดี และงวดสุดท้ายเงินต้นคงเหลือเป็นศูนย์ —
                เศษจากการปัดถูกนำไปลงงวดสุดท้ายเพื่อไม่ให้ยอดคงค้างเพี้ยนทีละสตางค์
              </div>
            </div>
          ) : (
            <div className="rounded border border-line bg-canvas p-4 text-sm leading-6 text-ink-600">
              กรอกวงเงิน อัตราดอกเบี้ย จำนวนงวด และวันที่รับเงินให้ครบ แล้วตารางงวดจะขึ้นตรงนี้
            </div>
          )}

          {touched && missing.length ? (
            <div className="rounded border border-neg bg-neg-bg p-[12px_14px] text-base leading-7 text-neg-fg">
              ยังกรอกไม่ครบ: {missing.join(" · ")}
            </div>
          ) : null}
        </div>

        <DialogFooter>
          <Button variant="secondary" onClick={() => onOpenChange(false)}>
            ยกเลิก
          </Button>
          <Button onClick={save} disabled={missing.length > 0}>
            บันทึกเงื่อนไข + สร้างตารางงวด
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
