"use client";

import * as React from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Field } from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { Select } from "@/components/ui/select";
import { Notice } from "@/components/reports/parts";
import { useReference, useReferenceState } from "@/components/reference/reference-provider";
import { createBankAccount, moveBankAccount, setBankAccountActive, updateBankAccount } from "@/app/actions/bank-accounts";
import { CURRENCY_LABEL, type BankFieldErrors } from "@/lib/db/bank-accounts";
import { CURRENCIES } from "@/lib/rules/currency";
import type { RefBank } from "@/lib/db/reference-types";
import { cn } from "@/lib/utils";

/**
 * ตั้งค่าบัญชีธนาคาร — อ่าน/เขียน `sri_os.bank_accounts` จริง (ไม่ใช้ข้อมูลจำลองหรือ store)
 *
 * - ปิดใช้งาน ไม่ใช่ลบ: บัญชีที่มีรายการอ้างถึงต้องยังหาเจอ (D-092)
 * - สกุลเงินกำหนดตอนสร้าง แก้ภายหลังไม่ได้ (บัญชี FCD ที่ตั้งเป็นบาทจะทำให้ยอดผิดเงียบๆ)
 * - ปุ่มซ่อน/แสดงตามสิทธิ์เป็นความสะดวกเท่านั้น · ด่านจริงคือ RLS ของ DB (ถ้าไม่มีสิทธิ์ ข้อความจาก DB ถูกแสดงตามจริง)
 */

type Msg = { tone: "ok" | "neg"; text: string } | null;
type Mode = { kind: "none" } | { kind: "new" } | { kind: "edit"; id: string };
const EMPTY = { ownerId: "", bank: "", displayName: "", last4: "", currency: "THB" };

export function BankSettings() {
  const router = useRouter();
  const state = useReferenceState();
  const ref = useReference();
  const [mode, setMode] = React.useState<Mode>({ kind: "none" });
  const [confirmOff, setConfirmOff] = React.useState<string | null>(null);
  const [msg, setMsg] = React.useState<Msg>(null);
  const [busy, startBusy] = React.useTransition();
  const [showInactive, setShowInactive] = React.useState(true);

  const banks = [...ref.banks].sort((a, b) => a.sortOrder - b.sortOrder || a.name.localeCompare(b.name, "th"));
  const visible = showInactive ? banks : banks.filter((b) => b.isActive);
  const ownerOf = (id: string) => ref.owners.find((o) => o.id === id);

  if (!state.ok) {
    return (
      <Notice tone="neg">
        โหลดบัญชีธนาคารจากฐานข้อมูลไม่สำเร็จ: {state.error}
        <div className="mt-1 text-base">ลองโหลดหน้านี้ใหม่ ถ้ายังไม่ได้ให้แจ้งผู้ดูแลระบบ — ระบบไม่แสดงข้อมูลจำลองแทน</div>
      </Notice>
    );
  }

  const done = (text: string) => {
    setMsg({ tone: "ok", text });
    setMode({ kind: "none" });
    setConfirmOff(null);
    router.refresh();
  };

  function toggle(b: RefBank, active: boolean) {
    setMsg(null);
    startBusy(async () => {
      const r = await setBankAccountActive({ id: b.id, active });
      if (r.ok) done(active ? `เปิดใช้งานบัญชี “${b.name}” แล้ว` : `ปิดใช้งานบัญชี “${b.name}” แล้ว — รายการเดิมยังอยู่ครบ ไม่มีอะไรถูกลบ`);
      else setMsg({ tone: "neg", text: r.message });
    });
  }

  function move(b: RefBank, direction: -1 | 1) {
    setMsg(null);
    startBusy(async () => {
      const r = await moveBankAccount({ id: b.id, direction });
      if (r.ok) router.refresh();
      else setMsg({ tone: "neg", text: r.message });
    });
  }

  return (
    <>
      <div className="flex flex-wrap items-center gap-4">
        <label className="flex min-h-control items-center gap-2.5 text-base">
          <Checkbox checked={showInactive} onChange={(e) => setShowInactive(e.target.checked)} className="h-6 w-6" />
          แสดงบัญชีที่ปิดใช้งาน
        </label>
        <div className="text-base text-ink-600">ลำดับนี้คือลำดับที่แสดงในตัวเลือกบัญชีทุกฟอร์ม</div>
        <Button className="ml-auto max-sm:min-h-control-mobile max-sm:w-full" onClick={() => (setMode({ kind: "new" }), setMsg(null))} disabled={mode.kind === "new"}>
          + เพิ่มบัญชี
        </Button>
      </div>

      {msg ? <Notice tone={msg.tone}>{msg.text}</Notice> : null}

      {mode.kind === "new" ? (
        <BankForm
          title="เพิ่มบัญชีใหม่"
          initial={EMPTY}
          owners={ref.owners.filter((o) => o.status === "active")}
          onCancel={() => setMode({ kind: "none" })}
          onSubmit={async (v) => {
            const r = await createBankAccount(v);
            if (r.ok) done(`เพิ่มบัญชี “${r.bank.name}” แล้ว — เลือกได้ในฟอร์มลงรายการและใช้ในไฟล์นำเข้ายอดตั้งต้นได้ทันที`);
            return r.ok ? null : r;
          }}
        />
      ) : null}

      {visible.length === 0 ? <Notice tone="info">ยังไม่มีบัญชีธนาคารในระบบ — กด “+ เพิ่มบัญชี” ด้านบน</Notice> : null}

      <div className="flex flex-col gap-3">
        {visible.map((b, i) => {
          const holder = ownerOf(b.ownerId);
          const editing = mode.kind === "edit" && mode.id === b.id;
          return (
            <div key={b.id} className="flex min-w-0 flex-col gap-3">
              <div
                className={cn(
                  "flex flex-wrap items-center gap-x-5 gap-y-3 rounded-card border border-line bg-surface p-[16px_20px] shadow-card",
                  !b.isActive && "bg-canvas"
                )}
              >
                <div className="flex-none text-right text-base text-ink-400 w-8">{i + 1}.</div>

                <div className="min-w-[200px] flex-1">
                  <div className="text-lg font-semibold">{b.name}</div>
                  <div className="text-base text-ink-600">
                    {b.bank}
                    {b.last4 ? ` · เลขท้าย ${b.last4}` : ""}
                  </div>
                </div>

                <div className="min-w-[150px]">
                  <div className="text-base text-ink-600">ถือในชื่อ</div>
                  <div className="flex items-center gap-1.5 text-base">
                    <span className="h-2.5 w-2.5 rounded-pill bg-holder-group" style={holder?.color ? { background: holder.color } : undefined} />
                    {holder?.name ?? "ไม่ทราบผู้ถือ"}
                  </div>
                </div>

                <div className="min-w-[130px]">
                  <div className="text-base text-ink-600">สกุลเงิน</div>
                  <div className="text-base font-semibold">{CURRENCY_LABEL[b.currency] ?? b.currency}</div>
                </div>

                <div className={cn("min-w-[110px] text-base font-semibold", b.isActive ? "text-pos-fg" : "text-ink-600")}>
                  {b.isActive ? "ใช้งานอยู่" : "ปิดใช้งาน"}
                </div>

                <div className="ml-auto flex flex-wrap items-center gap-2">
                  <Button variant="secondary" disabled={busy || i === 0} onClick={() => move(b, -1)} aria-label={`เลื่อน ${b.name} ขึ้น`}>
                    เลื่อนขึ้น
                  </Button>
                  <Button variant="secondary" disabled={busy || i === visible.length - 1} onClick={() => move(b, 1)} aria-label={`เลื่อน ${b.name} ลง`}>
                    เลื่อนลง
                  </Button>
                  <Button variant="secondary" disabled={busy} onClick={() => (setMode({ kind: "edit", id: b.id }), setMsg(null))}>
                    แก้ไขชื่อ
                  </Button>
                  {b.isActive ? (
                    <Button variant="danger" disabled={busy} onClick={() => setConfirmOff(b.id)}>
                      ปิดใช้งาน
                    </Button>
                  ) : (
                    <Button variant="quiet" disabled={busy} onClick={() => toggle(b, true)}>
                      เปิดใช้งานอีกครั้ง
                    </Button>
                  )}
                </div>
              </div>

              {confirmOff === b.id ? (
                <div role="alertdialog" aria-label={`ยืนยันปิดใช้งาน ${b.name}`} className="rounded-card border border-warn bg-warn-bg p-4 text-warn-fg">
                  <div className="font-semibold">ระบบจะบันทึกให้ดังนี้</div>
                  <ul className="my-2 list-disc pl-6 text-base leading-7">
                    <li>ปิดใช้งานบัญชี “{b.name}” — ซ่อนจากตัวเลือกและลงรายการใหม่เข้าบัญชีนี้ไม่ได้</li>
                    <li>รายการเดิมทั้งหมดของบัญชีนี้ยังอยู่ ยังอยู่ในรายงานย้อนหลัง และกลับรายการได้</li>
                    <li>ไม่มีการลบบัญชี เปิดใช้งานอีกครั้งได้ทุกเมื่อ</li>
                  </ul>
                  <div className="flex flex-wrap gap-3">
                    <Button variant="danger" disabled={busy} onClick={() => toggle(b, false)}>
                      ยืนยันปิดใช้งาน
                    </Button>
                    <Button variant="secondary" disabled={busy} onClick={() => setConfirmOff(null)}>
                      ยกเลิก ไม่ปิด
                    </Button>
                  </div>
                </div>
              ) : null}

              {editing ? (
                <BankForm
                  title={`แก้ไขบัญชี “${b.name}”`}
                  initial={{ ownerId: b.ownerId, bank: b.bank, displayName: b.name, last4: b.last4 ?? "", currency: b.currency }}
                  owners={ref.owners}
                  lockOwnerAndCurrency
                  onCancel={() => setMode({ kind: "none" })}
                  onSubmit={async (v) => {
                    const r = await updateBankAccount({ id: b.id, bank: v.bank, displayName: v.displayName, last4: v.last4 });
                    if (r.ok) done(`แก้ไขบัญชี “${r.bank.name}” แล้ว`);
                    return r.ok ? null : r;
                  }}
                />
              ) : null}
            </div>
          );
        })}
      </div>
    </>
  );
}

type FormValues = typeof EMPTY;

function BankForm({
  title,
  initial,
  owners,
  lockOwnerAndCurrency,
  onSubmit,
  onCancel,
}: {
  title: string;
  initial: FormValues;
  owners: { id: string; name: string }[];
  lockOwnerAndCurrency?: boolean;
  onSubmit: (v: FormValues) => Promise<{ message: string; fieldErrors?: BankFieldErrors } | null>;
  onCancel: () => void;
}) {
  const [v, setV] = React.useState<FormValues>(initial);
  const [errors, setErrors] = React.useState<BankFieldErrors>({});
  const [fail, setFail] = React.useState<string | null>(null);
  const [pending, start] = React.useTransition();
  const set = (k: keyof FormValues) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setV((p) => ({ ...p, [k]: e.target.value }));
  const ownerName = owners.find((o) => o.id === v.ownerId)?.name;
  const foreign = v.currency !== "THB";

  function submit(e: React.FormEvent) {
    e.preventDefault();
    setFail(null);
    setErrors({});
    start(async () => {
      const r = await onSubmit(v);
      if (r) {
        setFail(r.message);
        setErrors(r.fieldErrors ?? {});
      }
    });
  }

  return (
    <form onSubmit={submit} className="flex min-w-0 flex-col gap-4 rounded-card border-2 border-brand-600 bg-surface p-4 shadow-card">
      <h2 className="text-h2 font-semibold">{title}</h2>
      <div className="grid gap-4 md:grid-cols-2">
        <Field label="ผู้ถือบัญชี" required error={errors.ownerId}>
          <Select value={v.ownerId} onChange={set("ownerId")} disabled={lockOwnerAndCurrency} required>
            <option value="">— เลือกผู้ถือ —</option>
            {owners.map((o) => (
              <option key={o.id} value={o.id}>
                {o.name}
              </option>
            ))}
          </Select>
        </Field>
        <Field
          label="สกุลเงินของบัญชี"
          required
          error={errors.currency}
          hint={lockOwnerAndCurrency ? "แก้สกุลเงินภายหลังไม่ได้ — ถ้าผิด ให้ปิดบัญชีนี้แล้วสร้างใหม่" : "บัญชี FCD ต้องเลือกสกุลจริง ไม่ใช่บาท · เลือกแล้วแก้ภายหลังไม่ได้"}
        >
          <Select value={v.currency} onChange={set("currency")} disabled={lockOwnerAndCurrency}>
            {CURRENCIES.map((c) => (
              <option key={c} value={c}>
                {CURRENCY_LABEL[c] ?? c}
              </option>
            ))}
          </Select>
        </Field>
        <Field label="ชื่อบัญชี (ที่แสดงในทุกฟอร์ม)" required error={errors.displayName} hint="เช่น ธนากร - BBL 888 · ต้องไม่ซ้ำกับบัญชีอื่นของผู้ถือคนเดียวกัน · ไฟล์นำเข้าจับคู่บัญชีด้วยชื่อนี้">
          <Input value={v.displayName} onChange={set("displayName")} autoComplete="off" required />
        </Field>
        <Field label="ธนาคาร / ช่องทาง" required error={errors.bank} hint="เช่น กรุงเทพ · ไทยพาณิชย์">
          <Input value={v.bank} onChange={set("bank")} autoComplete="off" required />
        </Field>
        <Field label="เลขท้ายบัญชี 4 หลัก" error={errors.last4} hint="ไม่บังคับ — ใส่เฉพาะ 4 ตัวท้าย ระบบไม่เก็บเลขเต็ม">
          <Input value={v.last4} onChange={set("last4")} inputMode="numeric" maxLength={4} autoComplete="off" />
        </Field>
      </div>

      {foreign && !lockOwnerAndCurrency ? (
        <Notice tone="warn">
          บัญชีสกุลต่างประเทศ: การลงรายการเข้าบัญชีนี้ต้องมีอัตราแลกเปลี่ยนกำกับทุกบรรทัด ซึ่งฟอร์มลงรายการยังไม่รองรับ —
          เปิดบัญชีไว้ก่อนได้ แต่จะลงยอดเข้าบัญชีนี้ผ่านฟอร์มหรือไฟล์นำเข้ายังไม่ได้จนกว่าจะเปิดส่วนอัตราแลกเปลี่ยน
        </Notice>
      ) : null}

      <div className="rounded border border-brand-100 bg-brand-50 p-[14px_16px] text-base leading-7">
        <div className="font-semibold">ระบบจะบันทึกให้ดังนี้</div>
        {lockOwnerAndCurrency ? (
          <div>แก้ชื่อ ธนาคาร และเลขท้ายของบัญชีนี้ · ผู้ถือและสกุลเงินไม่เปลี่ยน · รายการเดิมไม่ถูกแตะ</div>
        ) : (
          <div>
            เปิดบัญชีใหม่ “{v.displayName.trim() || "…"}” ({v.bank.trim() || "ธนาคาร…"}) ถือในชื่อ {ownerName ?? "…"} สกุล{" "}
            {CURRENCY_LABEL[v.currency] ?? v.currency} · สถานะใช้งานอยู่ · ยอดตั้งต้นยังเป็น 0 (ลงยอดผ่านหน้า “นำเข้ายอดตั้งต้น”)
          </div>
        )}
      </div>

      {fail ? <Notice tone="neg">{fail}</Notice> : null}

      <div className="flex flex-wrap gap-3">
        <Button type="submit" disabled={pending} className="max-sm:min-h-control-mobile max-sm:w-full">
          {pending ? "กำลังบันทึก…" : lockOwnerAndCurrency ? "บันทึกการแก้ไข" : "บันทึกบัญชีใหม่"}
        </Button>
        <Button type="button" variant="secondary" onClick={onCancel} disabled={pending} className="max-sm:min-h-control-mobile max-sm:w-full">
          ยกเลิก
        </Button>
      </div>
    </form>
  );
}
