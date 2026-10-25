"use client";

import * as React from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { Field } from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { Select } from "@/components/ui/select";
import { Table, TableShell, Td, Th } from "@/components/ui/table";
import { Notice } from "@/components/reports/parts";
import { addFxRate, deleteFxRate } from "@/app/actions/fx-rates";
import { CURRENCY_LABEL } from "@/lib/db/bank-accounts";
import { FX_RATE_CURRENCIES, type FxRateFieldErrors, type FxRateRow } from "@/lib/db/fx-rates";
import { FX_RATE_SOURCE_LABEL, type FxRateSource } from "@/lib/rules/currency";
import { isoToDmy, todayDmy } from "@/lib/format";

/**
 * จัดการอัตราแลกเปลี่ยน — กรอกมือ (เรทจาก Google ได้ ไม่ต้องต่อ API) เก็บ "ที่มาของอัตรา" ไว้ตรวจย้อน
 *
 * - เพิ่มได้ · **ไม่มีปุ่มแก้ค่า** (อัตราที่มีรายการอ้างถึงแล้วแก้ไม่ได้ — รายละเอียดที่ `actions/fx-rates.ts`)
 * - ลบได้เฉพาะอัตราที่ยังไม่มีรายการอ้างถึง (ฐานข้อมูลเป็นคนตัดสิน ไม่ใช่หน้านี้)
 * - ซ่อน/แสดงปุ่มตามสิทธิ์ไม่ใช่ด่านกั้น: ด่านจริงคือ RLS ของ DB (ไม่มีสิทธิ์ → ข้อความจาก DB แสดงตามจริง)
 */

type Msg = { tone: "ok" | "neg"; text: string } | null;
const keyOf = (r: { currency: string; rateDate: string }) => `${r.currency}|${r.rateDate}`;

export function FxRatesPanel({ rows }: { rows: FxRateRow[] }) {
  const router = useRouter();
  const [msg, setMsg] = React.useState<Msg>(null);
  const [confirm, setConfirm] = React.useState<string | null>(null);
  const [busy, startBusy] = React.useTransition();

  function remove(r: FxRateRow) {
    setMsg(null);
    startBusy(async () => {
      const res = await deleteFxRate({ currency: r.currency, rateDate: r.rateDate });
      setConfirm(null);
      if (res.ok) {
        setMsg({ tone: "ok", text: `ลบอัตรา ${r.currency} ของวันที่ ${isoToDmy(r.rateDate)} แล้ว` });
        router.refresh();
      } else setMsg({ tone: "neg", text: res.message });
    });
  }

  return (
    <>
      <Notice tone="info">
        อัตรานี้คือ “บาทต่อ 1 หน่วยเงินตรา” ที่หน้าแลกเงินและหน้าตีค่าเงินใช้เลือก — กรอกเองจากแหล่งที่เชื่อถือได้ (เช่น Google หรือ ธปท.) แล้วระบุที่มาไว้ทุกครั้ง
      </Notice>

      <AddForm
        onDone={(text) => {
          setMsg({ tone: "ok", text });
          router.refresh();
        }}
      />

      {msg ? <Notice tone={msg.tone}>{msg.text}</Notice> : null}

      {rows.length === 0 ? (
        <Notice tone="warn">ยังไม่มีอัตราแลกเปลี่ยนในระบบ — เพิ่มอัตราด้านบนก่อน ไม่งั้นแลกเงินหรือตีค่าเงินไม่ได้ (ระบบไม่เดาอัตราให้)</Notice>
      ) : (
        <TableShell>
          <Table minWidth={760}>
            <thead>
              <tr>
                <Th>สกุลเงิน</Th>
                <Th>วันที่ของอัตรา</Th>
                <Th align="right">บาทต่อ 1 หน่วย</Th>
                <Th>ที่มาของอัตรา</Th>
                <Th>จัดการ</Th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <React.Fragment key={keyOf(r)}>
                  <tr>
                    <Td className="text-base font-semibold">{CURRENCY_LABEL[r.currency] ?? r.currency}</Td>
                    <Td className="text-base tabular-nums">{isoToDmy(r.rateDate)}</Td>
                    <Td align="right" className="text-base font-semibold tabular-nums">
                      {r.thbPerUnit.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 8 })}
                    </Td>
                    <Td className="text-base">
                      {r.note || <span className="text-ink-400">ไม่ได้ระบุ</span>}
                      <div className="text-base text-ink-600">{FX_RATE_SOURCE_LABEL[r.source as FxRateSource] ?? r.source}</div>
                    </Td>
                    <Td>
                      <Button
                        variant="danger"
                        disabled={busy}
                        onClick={() => setConfirm(keyOf(r))}
                        aria-label={`ลบอัตรา ${r.currency} ของวันที่ ${isoToDmy(r.rateDate)}`}
                      >
                        ลบอัตรานี้
                      </Button>
                    </Td>
                  </tr>
                  {confirm === keyOf(r) ? (
                    <tr>
                      <Td colSpan={5} className="bg-warn-bg">
                        <div role="alertdialog" aria-label="ยืนยันลบอัตรา" className="text-warn-fg">
                          <div className="font-semibold">ระบบจะทำให้ดังนี้</div>
                          <ul className="my-2 list-disc pl-6 text-base leading-7">
                            <li>
                              ลบอัตรา {r.currency} ของวันที่ {isoToDmy(r.rateDate)} ({r.thbPerUnit.toLocaleString("en-US", { maximumFractionDigits: 8 })} บาท)
                            </li>
                            <li>ถ้ามีรายการ บัญชี หรือการตีราคาอ้างถึงอัตรานี้แล้ว ฐานข้อมูลจะไม่ยอมลบ และอัตรานี้ยังอยู่ตามเดิม</li>
                          </ul>
                          <div className="flex flex-wrap gap-3">
                            <Button variant="danger" disabled={busy} onClick={() => remove(r)}>
                              ยืนยันลบอัตรานี้
                            </Button>
                            <Button variant="secondary" disabled={busy} onClick={() => setConfirm(null)}>
                              ยกเลิก ไม่ลบ
                            </Button>
                          </div>
                        </div>
                      </Td>
                    </tr>
                  ) : null}
                </React.Fragment>
              ))}
            </tbody>
          </Table>
        </TableShell>
      )}

      <Notice tone="info">
        <div className="font-semibold">พิมพ์อัตราผิดทำอย่างไร</div>
        <ul className="list-disc pl-6">
          <li>ยังไม่มีรายการใช้อัตรานั้น: กด “ลบอัตรานี้” แล้วเพิ่มใหม่</li>
          <li>
            มีรายการใช้ไปแล้ว: แก้ค่าอัตราไม่ได้ (รายการเดิมเก็บยอดบาทไว้ที่อัตราเดิม แก้แล้วจะไม่ตรงกัน) —
            ให้กลับรายการที่ใช้อัตราผิดแล้วลงใหม่ ปรึกษาผู้ดูแลระบบก่อน
          </li>
        </ul>
      </Notice>
    </>
  );
}

const EMPTY = { currency: "USD", rateDate: "", rate: "", note: "" };

function AddForm({ onDone }: { onDone: (text: string) => void }) {
  const [v, setV] = React.useState({ ...EMPTY });
  const [errors, setErrors] = React.useState<FxRateFieldErrors>({});
  const [fail, setFail] = React.useState<string | null>(null);
  const [pending, start] = React.useTransition();
  // วันนี้ตามเวลากรุงเทพฯ ใส่ให้หลังโหลด (ไม่ใส่ตอน render ฝั่ง server กัน hydration ไม่ตรงกันข้ามเที่ยงคืน)
  React.useEffect(() => setV((p) => (p.rateDate ? p : { ...p, rateDate: todayDmy() })), []);
  const set = (k: keyof typeof EMPTY) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setV((p) => ({ ...p, [k]: e.target.value }));

  function submit(e: React.FormEvent) {
    e.preventDefault();
    setFail(null);
    setErrors({});
    start(async () => {
      const r = await addFxRate(v);
      if (r.ok) {
        setV({ ...EMPTY, currency: v.currency, rateDate: todayDmy() });
        onDone(
          `เพิ่มอัตรา ${r.row.currency} ของวันที่ ${isoToDmy(r.row.rateDate)} = ${r.row.thbPerUnit.toLocaleString("en-US", { maximumFractionDigits: 8 })} บาท แล้ว — เลือกได้ในหน้าแลกเงินและตีค่าเงินทันที`
        );
      } else {
        setFail(r.message);
        setErrors(r.fieldErrors ?? {});
      }
    });
  }

  return (
    <form onSubmit={submit} className="flex min-w-0 flex-col gap-4 rounded-card border-2 border-brand-600 bg-surface p-4 shadow-card">
      <h2 className="text-h2 font-semibold">เพิ่มอัตราแลกเปลี่ยน</h2>
      <div className="grid gap-4 md:grid-cols-2">
        <Field label="สกุลเงิน" required error={errors.currency}>
          <Select value={v.currency} onChange={set("currency")}>
            {FX_RATE_CURRENCIES.map((c) => (
              <option key={c} value={c}>
                {CURRENCY_LABEL[c] ?? c}
              </option>
            ))}
          </Select>
        </Field>
        <Field label="วันที่ของอัตรา (วว/ดด/ปปปป ปี ค.ศ.)" required error={errors.rateDate} hint="เป็นวันที่เกิดขึ้นแล้วเท่านั้น (วันในอนาคตใช้ไม่ได้) · ใช้ได้ทีละสกุลต่อวัน">
          <Input value={v.rateDate} onChange={set("rateDate")} inputMode="numeric" placeholder="30/11/2026" autoComplete="off" />
        </Field>
        <Field label="อัตรา (บาทต่อ 1 หน่วยเงินตรา)" required error={errors.rate} hint="เช่น ดอลลาร์ 36.50 บาท พิมพ์ 36.50 · เยนมักต่ำกว่า 1 เช่น 0.2350 · ทศนิยมได้ไม่เกิน 8 ตำแหน่ง">
          <Input value={v.rate} onChange={set("rate")} inputMode="decimal" className="tabular-nums" autoComplete="off" />
        </Field>
        <Field label="ที่มาของอัตรา" required error={errors.note} hint="ข้อความสั้นๆ เช่น Google Finance 30/11/2026 หรือ ธปท. อัตราขายถัวเฉลี่ย">
          <Input value={v.note} onChange={set("note")} maxLength={200} autoComplete="off" />
        </Field>
      </div>

      <div className="rounded border border-brand-100 bg-brand-50 p-[14px_16px] text-base leading-7">
        <div className="font-semibold">ระบบจะบันทึกให้ดังนี้</div>
        <div>
          เพิ่มอัตรา {v.currency} ของวันที่ {v.rateDate.trim() || "…"} = {v.rate.trim() || "…"} บาทต่อ 1 {v.currency} · ที่มา “{v.note.trim() || "…"}” · ประเภท “ป้อนมือ”
        </div>
        <div className="text-ink-600">บันทึกแล้วแก้ค่าไม่ได้ (กันรายการเดิมไม่ตรงกับตาราง) — ถ้ายังไม่มีรายการใช้ ลบแล้วเพิ่มใหม่ได้</div>
      </div>

      {fail ? <Notice tone="neg">{fail}</Notice> : null}

      <div className="flex flex-wrap gap-3">
        <Button type="submit" disabled={pending} className="max-sm:min-h-control-mobile max-sm:w-full">
          {pending ? "กำลังบันทึก…" : "บันทึกอัตรา"}
        </Button>
      </div>
    </form>
  );
}
