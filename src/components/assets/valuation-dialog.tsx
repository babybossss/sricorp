"use client";

import * as React from "react";
import { useRouter } from "next/navigation";
import { Dialog, DialogContent, DialogFooter, DialogPrimitive } from "@/components/ui/dialog";
import { Field } from "@/components/ui/field";
import { dmyToIso, isoToDmy, money, parseAmountOrNull, todayDmy } from "@/lib/format";
import { METHOD_LABEL, VALUATION_METHODS, VALUE_NOT_ACCOUNTING, type AssetView } from "@/lib/db/assets-model";
import { recordValuation } from "@/app/assets/actions";
import { Button } from "./tall-button";
import { Input, Select } from "./fields";
import { SheetHeader } from "./draft-parts";
import { Notice, WillSave } from "./asset-parts";

/**
 * ตีราคา — ลงเป็นประวัติใหม่เสมอ (ตารางเพิ่มได้อย่างเดียว · ไม่แก้ทับ ไม่ลบ)
 * **ไม่ลงสมุดบัญชีและไม่เข้างบดุล** — บอกชัดทั้งในกล่อง "ระบบจะบันทึกให้ดังนี้" และข้อความเตือนล่างสุด
 * ปุ่มนี้โชว์เฉพาะคนที่มี `asset.value` (ความสะดวก · ด่านจริงคือ RLS `valuations_insert`)
 */
export function ValuationDialog({ asset, onClose }: { asset: AssetView; onClose: () => void }) {
  const router = useRouter();
  const [pending, startTransition] = React.useTransition();
  const [asOf, setAsOf] = React.useState(todayDmy());
  const [value, setValue] = React.useState("");
  const [method, setMethod] = React.useState<string>("manual");
  const [note, setNote] = React.useState("");
  const [error, setError] = React.useState<{ message: string; errors?: string[] } | null>(null);
  const [done, setDone] = React.useState<string | null>(null);

  const iso = dmyToIso(asOf);
  const amount = parseAmountOrNull(value);

  function submit() {
    setError(null);
    startTransition(async () => {
      const out = await recordValuation({ assetId: asset.id, asOf, value, method, note });
      if (out.ok) {
        setDone(out.message);
        router.refresh();
      } else setError({ message: out.message, errors: out.errors });
    });
  }

  return (
    <Dialog open onOpenChange={(o) => (o ? null : onClose())}>
      <DialogContent layer={1} aria-describedby={undefined}>
        <DialogPrimitive.Title className="sr-only">ตีราคา {asset.name}</DialogPrimitive.Title>
        <SheetHeader title={`ตีราคา ${asset.name}`} onClose={onClose} />
        <div className="flex max-h-[70vh] flex-col gap-4 overflow-auto p-[20px_24px]">
          {done ? (
            <>
              <h3 className="m-0 text-h2 font-semibold">บันทึกราคาประเมินแล้ว</h3>
              <Notice tone="ok">{done}</Notice>
            </>
          ) : (
            <>
              <Notice tone="info">{VALUE_NOT_ACCOUNTING}</Notice>
              <div className="grid gap-4 sm:grid-cols-2">
                <Field label="วันที่ตีราคา (วว/ดด/ปปปป ค.ศ.)" required error={asOf && !iso ? "วันที่ไม่ถูกต้อง" : undefined}>
                  <Input value={asOf} onChange={(e) => setAsOf(e.target.value)} inputMode="numeric" autoComplete="off" />
                </Field>
                <Field label="มูลค่าที่ประเมิน (บาท)" required error={value && amount === null ? "ต้องเป็นตัวเลข" : undefined}>
                  <Input value={value} onChange={(e) => setValue(e.target.value)} inputMode="decimal" autoComplete="off" />
                </Field>
              </div>
              <Field label="ที่มาของราคา" required>
                <Select value={method} onChange={(e) => setMethod(e.target.value)}>
                  {VALUATION_METHODS.map((m) => (
                    <option key={m} value={m}>{METHOD_LABEL[m]}</option>
                  ))}
                </Select>
              </Field>
              <Field label="หมายเหตุ">
                <Input value={note} onChange={(e) => setNote(e.target.value)} autoComplete="off" />
              </Field>
              <WillSave
                items={[
                  <>
                    เพิ่มราคาประเมินของ <b>{asset.name}</b> เป็น <b>{amount !== null && amount > 0 ? money(amount) : "(ยังไม่ได้ใส่มูลค่า)"}</b> บาท
                    ณ วันที่ {iso ? isoToDmy(iso) : "(วันที่ไม่ถูกต้อง)"} · ที่มา: {METHOD_LABEL[method] ?? method}
                  </>,
                  "เก็บเป็นประวัติแถวใหม่ — ไม่ลบหรือแก้ทับราคาเดิม และราคาล่าสุดจะเป็นแถวนี้",
                  <>
                    <b>ไม่ลงสมุดบัญชี ไม่เข้างบแสดงฐานะการเงิน</b> — ต้นทุนของทรัพย์ไม่เปลี่ยน
                  </>,
                ]}
              />
              {error ? (
                <Notice tone="neg">
                  {error.message}
                  {error.errors?.length ? (
                    <ul className="m-0 mt-1 list-disc pl-5">
                      {error.errors.map((m) => (
                        <li key={m}>{m}</li>
                      ))}
                    </ul>
                  ) : null}
                </Notice>
              ) : null}
            </>
          )}
        </div>
        <DialogFooter>
          {done ? (
            <Button onClick={onClose}>ปิด</Button>
          ) : (
            <>
              <Button variant="secondary" onClick={onClose} disabled={pending}>
                ยกเลิก
              </Button>
              <Button onClick={submit} disabled={pending}>
                {pending ? "กำลังบันทึก…" : "บันทึกราคาประเมิน"}
              </Button>
            </>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
