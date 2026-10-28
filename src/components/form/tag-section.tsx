"use client";

import * as React from "react";
import { money } from "@/lib/format";
import { TagChip, formatPercent } from "@/components/tags/tag-chip";
import { TagPicker } from "@/components/tags/tag-picker";
import { TagWeightInput } from "@/components/tags/tag-weight-input";
import { allocateLines } from "@/lib/tags/allocation";
import { centsToBaht, roundSharePairs } from "@/lib/tags/display";
import { hiddenKindsMessage } from "@/lib/tags/acceptance";
import type { TxFormApi } from "./use-tx-form";

/**
 * tag + สัดส่วนในฟอร์มบันทึกรายการ (ADR 0002 / 0003 · A6)
 *
 * - เลือกจากแค็ตตาล็อกเท่านั้น (ไม่มีช่องพิมพ์อิสระ) · ชนิดที่ต้องถ่วงน้ำหนักอ่านจากคอนฟิกของ DB ไม่ใช่ชื่อในโค้ด
 * - เลือก project อันเดียว = 100% (แสดงให้เห็น ไม่เดาเงียบ) · เลือกหลายอัน = ต้องกรอกสัดส่วนเอง
 *   ระบบ **ไม่เติมเศษให้อัตโนมัติ** — ปุ่ม "แบ่งเท่ากัน" หารไม่ลงตัวจะเหลือคำเตือนให้ผู้ใช้เลือกเอง
 * - ปุ่มบันทึกถามตัวตรวจจริง (`checkTagSelection` — ตัวเดียวกับที่ server เรียก) ผ่าน `api.canSubmit`
 */
export function TagSection({ api }: { api: TxFormApi }) {
  const { draft, patch, canTag, tagCatalog: cat, tagCheck } = api;
  if (!canTag) return null;

  const title = <div className="text-base font-semibold">tag ของรายการนี้ (ไม่บังคับ)</div>;

  if (cat.loading) {
    return (
      <div className="flex flex-col gap-2 rounded-card border border-line bg-canvas p-4">
        {title}
        <div role="status" className="text-base text-ink-600">
          กำลังโหลดรายการ tag…
        </div>
      </div>
    );
  }
  if (cat.error) {
    return (
      <div className="flex flex-col gap-2 rounded-card border border-line bg-canvas p-4">
        {title}
        <div role="alert" className="rounded border border-warn bg-warn-bg p-[12px_14px] text-base leading-7 text-warn-fg">
          ยังเลือก tag ไม่ได้: {cat.error}
          <div className="mt-1 text-sm">ลงรายการโดยไม่ติด tag ได้ตามปกติ</div>
        </div>
      </div>
    );
  }

  const chosen = cat.tags.filter((t) => draft.tagIds.includes(t.id));
  const hiddenNotice =
    cat.hiddenKinds.length > 0 ? (
      <div role="note" data-testid="tag-hidden-kinds" className="rounded border border-warn bg-warn-bg p-[12px_14px] text-base leading-7 text-warn-fg">
        {hiddenKindsMessage(cat.hiddenKinds)}
      </div>
    ) : null;
  const allocKinds = cat.kinds.filter((k) => k.requiresAllocation);

  return (
    <div className="flex flex-col gap-4 rounded-card border border-line bg-canvas p-4">
      {title}
      {/* ทุกชนิดถูกซ่อน = ไม่มีอะไรให้เลือก · ไม่โชว์ "ยังไม่มี tag" เพราะจะอ่านแล้วเข้าใจผิดว่าไม่เคยตั้ง */}
      {cat.kinds.length > 0 ? (
        <TagPicker
          catalog={cat.tags}
          kinds={cat.kinds}
          selectedIds={draft.tagIds}
          onChange={(ids) => patch({ tagIds: ids })}
          label="เลือก tag จากรายการที่ตั้งไว้"
        />
      ) : null}
      {hiddenNotice}

      {allocKinds.map((k) => {
        const ts = chosen.filter((t) => t.kind === k.key);
        if (ts.length === 0) return null;
        if (ts.length === 1) {
          return (
            <div key={k.key} className="flex flex-col gap-2 rounded border border-brand-100 bg-brand-50 p-[12px_14px] text-base leading-7">
              <span>
                เลือก{k.nameTh}เพียงอันเดียว — ส่วนแบ่งเป็น <b>100%</b> ของรายการนี้
              </span>
              <TagChip tag={ts[0]} weight={1} />
            </div>
          );
        }
        return (
          <TagWeightInput
            key={k.key}
            tags={ts}
            value={draft.tagWeights}
            onChange={(next) => patch({ tagWeights: next })}
            noteTh={k.allocationNoteTh}
            label={`สัดส่วนของแต่ละ${k.nameTh} (รวมกันต้องได้ 100% พอดี)`}
          />
        );
      })}

      {/* เหตุที่ปุ่มบันทึกถูกกั้น เพราะตัวตรวจจริงไม่ยอมรับชุด tag นี้ */}
      {!tagCheck.ok && draft.tagIds.length > 0 ? (
        <div role="alert" className="rounded border border-neg bg-neg-bg p-[12px_14px] text-base leading-7 text-neg-fg">
          <b>ยังบันทึกพร้อม tag ไม่ได้:</b>
          <ul className="m-0 mt-1 list-disc pl-6">
            {tagCheck.issues.map((m) => (
              <li key={m}>{m}</li>
            ))}
          </ul>
        </div>
      ) : null}
    </div>
  );
}

/**
 * "ระบบจะบันทึกให้ดังนี้" ของส่วน tag — โชว์เฉพาะเมื่อชุด tag ผ่านตัวตรวจแล้ว
 * ส่วนแบ่งเป็นบาทปัดด้วย `roundSharePairs` (ฟังก์ชันปัดเพื่อแสดงผลตัวเดียวของระบบ) ให้รวมกันเท่ายอดรายการพอดี
 * ตัวเลขที่ระบบเก็บจริงแม่นตรงไม่ปัด (คิดต่อบรรทัดบัญชีที่ DB) — ที่นี่เป็นภาพให้คนอ่านเท่านั้น
 */
export function TagSummary({ api }: { api: TxFormApi }) {
  const { draft, tagCheck, tagCatalog: cat, postingInput } = api;
  if (draft.tagIds.length === 0 || !tagCheck.ok) return null;

  const label = cat.tags.filter((t) => tagCheck.labelTagIds.includes(t.id));
  const amount = postingInput?.amount;

  return (
    <div className="rounded-card border border-line bg-canvas p-4">
      <div className="mb-2 text-base font-semibold">ระบบจะบันทึก tag ให้ดังนี้</div>

      {tagCheck.groups.map((g) => {
        let rounded: ReturnType<typeof roundSharePairs> | null = null;
        if (typeof amount === "number" && Number.isFinite(amount)) {
          try {
            const a = allocateLines([{ debit: amount, credit: 0 }], g.weights);
            rounded = roundSharePairs(a.shares.map((s) => ({ debit: s.debit, credit: s.credit })));
          } catch {
            rounded = null; // ยอดมีทศนิยมเกินสองตำแหน่ง ฯลฯ — engine ฝั่งบันทึกจะปฏิเสธเอง ที่นี่แค่ไม่แสดงยอดส่วนแบ่ง
          }
        }
        return (
          <div key={g.kind} className="border-t border-line py-2 text-base">
            {g.tags.map((t, i) => (
              <div key={t.id} className="flex flex-wrap justify-between gap-x-3">
                <span className="min-w-0 break-words">
                  {t.nameTh} · <span className="tabular-nums">{formatPercent(api.tagWeightsEffective[t.id] ?? 0)}</span>
                </span>
                {rounded ? <span className="font-semibold tabular-nums">฿ {money(centsToBaht(rounded.debitCents[i]), { dash: false })}</span> : null}
              </div>
            ))}
            {rounded ? (
              <div className="mt-1 text-sm text-ink-600">
                รวม ฿ <span className="tabular-nums">{money(centsToBaht(rounded.totalCents), { dash: false })}</span> = ยอดรายการ · ตัวเลขนี้ปัดเป็นสตางค์เพื่อให้อ่านง่ายเท่านั้น
                ระบบเก็บค่าแม่นตรงไม่ปัด
              </div>
            ) : null}
          </div>
        );
      })}

      {label.length > 0 ? (
        <div className="flex flex-wrap items-center gap-2 border-t border-line py-2 text-base">
          <span className="text-ink-600">ป้ายกำกับ</span>
          {label.map((t) => (
            <TagChip key={t.id} tag={t} />
          ))}
        </div>
      ) : null}
    </div>
  );
}
