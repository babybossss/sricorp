"use client";

import * as React from "react";
import Link from "next/link";
import { Button } from "@/components/ui/button";
import { Field } from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { Select } from "@/components/ui/select";
import { isoToDmy, money } from "@/lib/format";
import { datesForRate } from "./fx-value";
import type { TxFormApi } from "./use-tx-form";

/**
 * แผงแปลงค่า / แลกเงินตรา — **ผู้ใช้เลือกอัตราจากตารางอัตรา ไม่พิมพ์ตัวเลขอัตรา**
 *
 * ยอดเงินตราคงเหลือ · อัตราที่ยอดบาทตั้งอยู่ · ผลต่างที่ค้างใน 3410 ที่เห็นในแผงนี้ **อ่านจากสมุด** (server action)
 * ไม่ใช่ช่องกรอก (ค่าที่ผู้เรียกกรอกได้ ด่านฝั่ง DB เชื่อไม่ได้ · D-115) · ตัวเลขบรรทัดบัญชีคิดโดย engine ตัวเดียวกับที่ลงจริง
 * แผงนี้แสดงผลของ engine (`api.postingError` / พรีวิวตอนยืนยัน) ไม่คำนวณกำไร/ขาดทุนเอง
 */
export function FxPanel({ api }: { api: TxFormApi }) {
  const { draft, patch, fxKind, fxState, fxResult } = api;
  const ctx = fxState.ctx;
  if (!fxKind) return null;
  const acquisition = fxKind === "acquisition";
  const conversion = fxKind === "conversion";
  // แลก/ซื้อใช้ "อัตราที่ได้จริง" (dealRateDate) · แปลงค่าใช้อัตราสิ้นงวด (newRateDate)
  const rateKey = conversion || acquisition ? "dealRateDate" : "newRateDate";

  const pickRate = (date: string) => {
    // เลือกอัตราแล้วตั้งวันที่เอกสารและวันที่เงินเคลื่อนเป็นวันของอัตรานั้นให้ (แก้ต่อได้ในช่องวันที่ด้านบน)
    patch({ fx: { ...draft.fx, [rateKey]: date }, ...(datesForRate(date) ?? {}) });
  };

  return (
    <div className="flex flex-col gap-4 rounded-card border border-line bg-canvas p-4">
      <div className="text-base font-semibold">
        {acquisition ? "ซื้อเงินตราต่างประเทศเข้าบัญชีสกุลต่างประเทศ" : conversion ? "แลกเงินตราต่างประเทศเป็นบาท" : "ตีค่าเงินฝากสกุลต่างประเทศใหม่ตามอัตราสิ้นงวด"}
      </div>

      {acquisition && !draft.bankId ? (
        <div className="text-base leading-7 text-ink-600">
          เลือก<b>บัญชีบาทที่จ่าย</b>ด้านบนก่อน
        </div>
      ) : acquisition && !draft.transferToBankId ? (
        <div className="text-base leading-7 text-ink-600">
          เลือก<b>บัญชีสกุลต่างประเทศที่เงินตราเข้า</b>ใน “โอนเข้าบัญชี” ด้านบน — ระบบจะรู้สกุลเงินจากบัญชีนั้นเอง ไม่ต้องพิมพ์สกุลหรือยอดบาท
        </div>
      ) : !acquisition && !draft.bankId ? (
        <div className="text-base leading-7 text-ink-600">
          เลือก<b>บัญชีเงินฝากสกุลต่างประเทศ</b>ด้านบนก่อน — ระบบจะอ่านยอดเงินตราคงเหลือและอัตราตามบัญชีจากสมุดให้ ไม่ต้องพิมพ์เอง
        </div>
      ) : fxState.loading ? (
        <div role="status" className="text-base text-ink-600">
          กำลังอ่านยอดเงินตราของบัญชีนี้จากสมุด…
        </div>
      ) : fxState.error ? (
        <div role="alert" className="rounded border border-neg bg-neg-bg p-[12px_14px] text-base leading-7 text-neg-fg">
          {fxState.error}
        </div>
      ) : ctx ? (
        <>
          {acquisition ? (
            <div className="rounded border border-line bg-surface p-[14px_16px] text-base leading-7">
              เงินตราเข้าบัญชีสกุล <b>{ctx.currency}</b> · ยอดคงเหลือตามสมุดตอนนี้ {ctx.units.toLocaleString("en-US")} {ctx.currency}
              <div className="text-sm text-ink-600">สกุลเงินมาจากบัญชีปลายทาง แก้ในฟอร์มไม่ได้</div>
            </div>
          ) : (
          <dl className="grid grid-cols-1 gap-x-6 gap-y-2 rounded border border-line bg-surface p-[14px_16px] text-base sm:grid-cols-2">
            <div>
              <dt className="text-sm text-ink-600">เงินตราคงเหลือตามสมุด</dt>
              <dd className="font-semibold tabular-nums">
                {ctx.units.toLocaleString("en-US")} {ctx.currency}
              </dd>
            </div>
            <div>
              <dt className="text-sm text-ink-600">ยอดบาทตามสมุด</dt>
              <dd className="font-semibold tabular-nums">
                {money(ctx.bookThb)} บาท
                {ctx.bookRate !== null ? <span className="font-normal text-ink-600"> · อัตราตามบัญชี {ctx.bookRate}</span> : null}
              </dd>
            </div>
            <div>
              <dt className="text-sm text-ink-600">ผลต่างอัตราแลกเปลี่ยนที่ยังค้างอยู่ (ส่วนของเจ้าของ)</dt>
              <dd className="font-semibold tabular-nums">{money(ctx.unrealized)} บาท</dd>
            </div>
            <div className="text-sm leading-6 text-ink-600 sm:self-end">ตัวเลขชุดนี้อ่านจากสมุดที่บันทึกแล้ว แก้ในฟอร์มไม่ได้</div>
          </dl>
          )}

          <Field
            label={
              acquisition
                ? "อัตราที่ซื้อได้จริง (เลือกจากตารางอัตราแลกเปลี่ยน)"
                : conversion
                  ? "อัตราที่แลกได้จริง (เลือกจากตารางอัตราแลกเปลี่ยน)"
                  : "อัตราสิ้นงวดที่จะใช้ (เลือกจากตารางอัตราแลกเปลี่ยน)"
            }
            required
            hint="เลือกได้เฉพาะวันที่มีในตารางอัตรา — พิมพ์อัตราเองไม่ได้ เพราะฐานข้อมูลปฏิเสธอัตราที่ไม่ตรงกับที่ประกาศไว้ · ไม่มีอัตราที่ต้องการ ให้เพิ่มที่ “ตั้งค่า > อัตราแลกเปลี่ยน” ก่อน แล้วกลับมากดโหลดอัตราใหม่"
            error={ctx.rates.length === 0 ? `ยังไม่มีอัตรา ${ctx.currency} ในตารางอัตราแลกเปลี่ยนเลย` : undefined}
          >
            <Select value={draft.fx[rateKey]} onChange={(e) => pickRate(e.target.value)} disabled={ctx.rates.length === 0}>
              <option value="">— เลือกอัตรา —</option>
              {ctx.rates.map((r) => (
                <option key={r.rateDate} value={r.rateDate}>
                  {isoToDmy(r.rateDate)} · 1 {r.currency} = {r.thbPerUnit} บาท
                </option>
              ))}
            </Select>
          </Field>

          <div className="flex flex-wrap items-center gap-3">
            <Button type="button" variant="secondary" onClick={api.reloadFx} className="max-sm:min-h-control-mobile">
              โหลดอัตราล่าสุดอีกครั้ง
            </Button>
            <Link href="/settings/fx-rates" target="_blank" rel="noreferrer" className="text-base">
              เพิ่มอัตราที่หน้าตั้งค่า (เปิดแท็บใหม่)
            </Link>
          </div>

          {acquisition ? (
            <Field label={`จำนวน ${ctx.currency} ที่ซื้อ`} required hint="ยอดบาทที่จ่ายคิดให้เอง = จำนวนเงินตรา × อัตราที่เลือก (พิมพ์ยอดบาทเองไม่ได้)">
              <Input value={draft.fx.amountOriginal} onChange={(e) => patch({ fx: { ...draft.fx, amountOriginal: e.target.value } })} inputMode="decimal" placeholder="0.00" />
            </Field>
          ) : null}

          {conversion ? (
            <Field label={`จำนวน ${ctx.currency} ที่แลก`} required hint={`ไม่เกินยอดคงเหลือ ${ctx.units.toLocaleString("en-US")} ${ctx.currency}`}>
              <div className="flex flex-col gap-2 sm:flex-row">
                <Input
                  value={draft.fx.amountOriginal}
                  onChange={(e) => patch({ fx: { ...draft.fx, amountOriginal: e.target.value } })}
                  inputMode="decimal"
                  placeholder="0.00"
                />
                <Button
                  type="button"
                  variant="secondary"
                  onClick={() => patch({ fx: { ...draft.fx, amountOriginal: String(ctx.units) } })}
                  className="max-sm:min-h-control-mobile"
                >
                  แลกทั้งหมดที่มี
                </Button>
              </div>
            </Field>
          ) : null}

          {fxResult && !fxResult.ok ? (
            <div className="rounded border border-warn bg-warn-bg p-[12px_14px] text-base leading-7 text-warn-fg">{fxResult.message}</div>
          ) : null}

          {fxResult?.ok ? (
            <div className="rounded border border-line bg-surface p-[14px_16px] text-base leading-7">
              <div className="text-sm text-ink-600">
                {acquisition
                  ? "บาทที่ต้องจ่าย (จำนวนเงินตรา × อัตราที่ซื้อได้จริง) · เป็นต้นทุนของเงินตรา ไม่ใช่ค่าใช้จ่าย ไม่เข้างบกำไรขาดทุน"
                  : conversion
                    ? "บาทที่จะได้รับ (จำนวนที่แลก × อัตราที่แลกได้จริง)"
                    : "ผลต่างที่จะลงส่วนของเจ้าของ (ไม่เข้างบกำไรขาดทุน)"}
              </div>
              <div className="text-h2 font-semibold tabular-nums">{money(fxResult.amount)} บาท</div>
              <div className="text-sm text-ink-600">ช่องจำนวนเงินด้านบนตั้งตามนี้ให้แล้ว · ตัวเลขกำไร/ขาดทุนและบรรทัดล้างผลต่างจะแสดงในขั้นยืนยัน</div>
              {api.postingError ? <div className="mt-2 text-warn-fg">ยังบันทึกไม่ได้: {api.postingError}</div> : null}
            </div>
          ) : null}
        </>
      ) : null}
    </div>
  );
}
