"use client";

import * as React from "react";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { formatPercent, TagChip } from "./tag-chip";
import type { Tag, TagWeights } from "./types";

/**
 * ช่องกรอกน้ำหนัก tag หลายอัน (ADR 0003 ข้อ 3-4)
 *
 * - รับ/คืนเป็น **สัดส่วน** (0.6) · แสดงและให้พิมพ์เป็นเปอร์เซ็นต์ (60)
 * - แสดงผลรวมสดตลอดเวลา · ≠ 100% เตือนชัดพร้อมบอกว่าขาด/เกินเท่าไร
 * - **ห้ามปัดให้ครบ 100% เอง** — ระบบเดาแทนคนแปลว่าตัวเลขเงินถูกตัดสินโดยไม่มีใครรู้
 *   ปุ่ม "แบ่งเท่ากัน" ก็เช่นกัน: หาร 100% ไม่ลงตัวจะ **เหลือเศษให้เห็นเป็นคำเตือน** ผู้ใช้เลือกเองว่าให้ใคร
 * - น้ำหนัก 0 กรอกไม่ได้ (ถ้าไม่เกี่ยวให้เอา tag ออก — มีร่องรอยชัดกว่า)
 * - ความถูกต้องจริงบังคับที่ DB (ด่าน Σ = 1 พอดี) — คอมโพเนนต์นี้แค่ไม่ให้ผู้ใช้เพิ่งมารู้ตอนกดบันทึก
 *
 * ภายในนับเป็นหน่วย "ไมโคร" (1 หน่วย = 0.000001 = 0.0001%) ตรงกับ numeric(9,6)
 * เป็นจำนวนเต็มทั้งหมด จึงไม่มีเศษทศนิยมลอยตัวมาทำให้ 0.1 + 0.2 ≠ 0.3
 */

const MICRO = 1_000_000;
/** 100% ในหน่วยไมโคร */
const FULL = MICRO;

export const toMicro = (fraction: number): number => Math.round(fraction * MICRO);
const fromMicro = (micro: number): number => micro / MICRO;

export type PercentParse =
  | { ok: true; fraction: number }
  | { ok: false; reason: "empty" | "format" | "zero" | "over" | "decimals" };

/**
 * ข้อความที่ผู้ใช้พิมพ์ (เป็นเปอร์เซ็นต์) → สัดส่วน
 * อ่านไม่ออก = ปฏิเสธพร้อมเหตุผล ไม่เดา · ทศนิยมเกิน 4 ตำแหน่งปฏิเสธ (ปัดเงียบๆ ไม่ได้)
 */
export function parsePercentInput(raw: string): PercentParse {
  const t = raw.trim().replace(/[%\s]/g, "").replace(/,/g, "");
  if (t === "") return { ok: false, reason: "empty" };
  const m = /^(\d+)(?:\.(\d*))?$/.exec(t);
  if (!m) return { ok: false, reason: "format" };
  const frac = m[2] ?? "";
  if (frac.length > 4) return { ok: false, reason: "decimals" };
  // แยกจำนวนเต็มกับทศนิยมเป็นสตริง ไม่ผ่าน float
  const micro = Number(m[1]) * 10_000 + Number(frac.padEnd(4, "0"));
  if (micro === 0) return { ok: false, reason: "zero" };
  if (micro > FULL) return { ok: false, reason: "over" };
  return { ok: true, fraction: fromMicro(micro) };
}

export type WeightsStatus = {
  /** ผลรวมของแถวที่กรอกแล้ว (สัดส่วน) */
  sum: number;
  /** 1 - sum เป็นสัดส่วน · บวก = ขาด · ลบ = เกิน */
  remaining: number;
  /** tag ที่ยังไม่ได้กรอกน้ำหนัก (null / ไม่มีคีย์) */
  missingIds: string[];
  /** ครบเมื่อ Σ = 100% พอดี **และ** ไม่มีแถวว่าง — เงื่อนไขเดียวกับด่านที่ DB */
  complete: boolean;
};

/** ผู้ใช้หลัก: ฟอร์มที่จะกั้นปุ่มบันทึก · ใช้คำนวณเดียวกับที่แสดงผล */
export function weightsStatus(tagIds: readonly string[], weights: TagWeights): WeightsStatus {
  let sumMicro = 0;
  const missingIds: string[] = [];
  for (const id of tagIds) {
    const w = weights[id];
    if (w === null || w === undefined || !(w > 0)) missingIds.push(id);
    else sumMicro += toMicro(w);
  }
  const remainingMicro = FULL - sumMicro;
  return {
    sum: fromMicro(sumMicro),
    remaining: fromMicro(remainingMicro),
    missingIds,
    complete: remainingMicro === 0 && missingIds.length === 0 && tagIds.length > 0,
  };
}

/**
 * แบ่งเท่ากัน: ทุกแถวได้เท่ากัน ปัดลง **ไม่แจกเศษ**
 * 2 → 50/50 · 3 → 33.3333 ×3 (รวม 99.9999% — ยังเตือนว่าขาด 0.0001% ให้ผู้ใช้เลือกเอง)
 */
export function splitEqually(tagIds: readonly string[]): TagWeights {
  const out: TagWeights = {};
  if (tagIds.length === 0) return out;
  const each = Math.floor(FULL / tagIds.length);
  for (const id of tagIds) out[id] = fromMicro(each);
  return out;
}

const PARSE_ERROR: Record<Exclude<PercentParse, { ok: true }>["reason"], string | null> = {
  empty: null,
  format: "ใส่ตัวเลขเปอร์เซ็นต์ เช่น 60 หรือ 33.3333",
  zero: "น้ำหนัก 0 ไม่ได้ — ถ้า tag นี้ไม่เกี่ยวกับรายการนี้ ให้กดเอา tag ออกจากรายการ",
  over: "เกิน 100% ไม่ได้",
  decimals: "ใส่ทศนิยมได้ไม่เกิน 4 ตำแหน่ง",
};

function textOf(w: number | null | undefined): string {
  return w === null || w === undefined ? "" : formatPercent(w).replace(/%$/, "");
}

export type TagWeightInputProps = {
  /** tag ที่ต้องถ่วงน้ำหนัก (ของชนิดที่ requiresAllocation) */
  tags: readonly Tag[];
  value: TagWeights;
  onChange: (next: TagWeights) => void;
  /** ประโยคกำกับของชนิดนี้ (`allocationNoteTh`) ถ้ามี */
  noteTh?: string | null;
  label?: string;
  disabled?: boolean;
  className?: string;
};

export function TagWeightInput({
  tags,
  value,
  onChange,
  noteTh,
  label = "สัดส่วนของแต่ละ tag",
  disabled,
  className,
}: TagWeightInputProps) {
  const uid = React.useId();
  // ข้อความที่กำลังพิมพ์ (เช่น "33." ระหว่างพิมพ์) — คนละเรื่องกับค่าที่ส่งออก
  const [drafts, setDrafts] = React.useState<Record<string, string>>({});

  const ids = tags.map((t) => t.id);
  const status = weightsStatus(ids, value);

  function setOne(id: string, raw: string) {
    setDrafts((d) => ({ ...d, [id]: raw }));
    const parsed = parsePercentInput(raw);
    onChange({ ...value, [id]: parsed.ok ? parsed.fraction : null });
  }

  function equalSplit() {
    setDrafts({});
    onChange({ ...value, ...splitEqually(ids) });
  }

  /** ช่องแสดงสิ่งที่พิมพ์ค้างไว้ ตราบที่มันยังตรงกับค่า · ถ้า parent เปลี่ยนค่า (เช่น แบ่งเท่ากัน) แสดงค่าใหม่ */
  function shownText(id: string): string {
    const d = drafts[id];
    if (d === undefined) return textOf(value[id]);
    const p = parsePercentInput(d);
    const cur = value[id] ?? null;
    const same = p.ok ? cur !== null && toMicro(cur) === toMicro(p.fraction) : cur === null;
    return same ? d : textOf(value[id]);
  }

  const diffMicro = FULL - toMicro(status.sum);
  const diffText = formatPercent(Math.abs(diffMicro) / MICRO);
  const filled = ids.length - status.missingIds.length;

  let verdict: { tone: "ok" | "bad"; text: string };
  if (ids.length === 0) {
    verdict = { tone: "bad", text: "ยังไม่ได้เลือก tag ที่ต้องแบ่งสัดส่วน" };
  } else if (diffMicro === 0 && status.missingIds.length === 0) {
    verdict = { tone: "ok", text: "ครบ 100% แล้ว" };
  } else if (diffMicro > 0) {
    verdict = { tone: "bad", text: `ยังไม่ครบ 100% — ขาดอีก ${diffText}` };
  } else if (diffMicro < 0) {
    verdict = { tone: "bad", text: `เกิน 100% — เกินอยู่ ${diffText}` };
  } else {
    verdict = { tone: "bad", text: "ยังมี tag ที่ไม่ได้ใส่สัดส่วน" };
  }

  return (
    <fieldset className={cn("flex min-w-0 flex-col gap-3 border-0 p-0", className)} disabled={disabled}>
      <legend className="mb-1 p-0 text-base font-semibold text-ink-900">{label}</legend>

      {noteTh ? (
        <p className="rounded border border-brand-100 bg-brand-50 p-[12px_14px] text-sm leading-6 text-ink-900">{noteTh}</p>
      ) : null}

      <ul className="m-0 flex list-none flex-col gap-2 p-0">
        {tags.map((tag) => {
          const text = shownText(tag.id);
          const parsed = parsePercentInput(text);
          const err = !parsed.ok ? PARSE_ERROR[parsed.reason] : null;
          const inputId = `${uid}-w-${tag.id}`;
          const errId = `${inputId}-err`;
          return (
            <li key={tag.id} className="rounded border border-line bg-surface p-[10px_12px]">
              <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
                <label htmlFor={inputId} className="min-w-0 flex-1 basis-[180px]">
                  <TagChip tag={tag} />
                  <span className="sr-only"> สัดส่วนเป็นเปอร์เซ็นต์</span>
                </label>
                <div className="flex items-center gap-2">
                  <input
                    id={inputId}
                    type="text"
                    inputMode="decimal"
                    autoComplete="off"
                    value={text}
                    onChange={(e) => setOne(tag.id, e.target.value)}
                    aria-invalid={err ? true : undefined}
                    aria-describedby={err ? errId : undefined}
                    className={cn(
                      "min-h-control w-[120px] rounded border bg-surface px-[14px] text-right text-base tabular-nums text-ink-900 max-sm:min-h-control-mobile",
                      "focus-visible:outline-none focus-visible:ring-[3px] focus-visible:ring-brand-600 focus-visible:ring-offset-2",
                      err ? "border-neg" : "border-line"
                    )}
                  />
                  <span aria-hidden="true" className="text-base text-ink-600">
                    %
                  </span>
                </div>
              </div>
              {err ? (
                <p id={errId} className="mt-2 text-sm text-neg-fg">
                  {err}
                </p>
              ) : null}
            </li>
          );
        })}
      </ul>

      <div
        role="status"
        aria-live="polite"
        data-testid="weight-total"
        data-complete={verdict.tone === "ok" ? "true" : "false"}
        className={cn(
          "flex flex-wrap items-baseline gap-x-3 gap-y-1 rounded border-2 p-[12px_14px] text-base",
          verdict.tone === "ok" ? "border-pos-bd bg-pos-bg text-pos-fg" : "border-neg bg-neg-bg text-neg-fg"
        )}
      >
        <span className="font-semibold">
          รวม <span className="tabular-nums">{formatPercent(status.sum)}</span> จาก 100%
        </span>
        <span className="font-semibold">{verdict.text}</span>
        {ids.length > 0 && status.missingIds.length > 0 ? (
          <span className="text-sm">
            กรอกแล้ว <span className="tabular-nums">{filled}</span> จาก <span className="tabular-nums">{ids.length}</span> รายการ
          </span>
        ) : null}
      </div>

      <Button type="button" variant="quiet" className="self-start max-sm:min-h-control-mobile max-sm:w-full" onClick={equalSplit} disabled={disabled || ids.length === 0}>
        แบ่งเท่ากัน
      </Button>
    </fieldset>
  );
}
