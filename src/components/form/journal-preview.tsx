"use client";

import * as React from "react";
import { Pill } from "@/components/ui/pill";
import { money } from "@/lib/format";
import { previewPosting } from "@/lib/ledger/preview";
import type { PostingInput } from "@/lib/ledger/types";

/**
 * ตารางบรรทัดบัญชีที่ระบบจะลงให้
 *
 * ดึงจาก `previewPosting()` ซึ่งเรียก engine ตัวเดียวกับที่ใช้ลงบัญชีจริง
 * ไม่คำนวณคู่บัญชีเอง — สิ่งที่เห็นตรงนี้คือสิ่งที่จะถูกบันทึกจริง
 */
export function JournalPreview({
  input,
  showSummary = false,
}: {
  input: PostingInput | null;
  /** คำอธิบายภาษาคนใต้ตาราง — เปิดตอนยืนยัน ปิดในแผงย่อยเพราะยาวเกินไป */
  showSummary?: boolean;
}) {
  if (!input) return null;
  const preview = previewPosting(input);

  if (!preview.ok) {
    return (
      <div className="rounded border border-warn bg-warn-bg p-[12px_14px] text-sm leading-6 text-warn-fg">
        ยังแสดงบรรทัดบัญชีไม่ได้: {preview.reason}
      </div>
    );
  }

  const multi = preview.transactions.length > 1;

  return (
    <div className="flex flex-col gap-1.5">
      <div className="flex flex-wrap items-center gap-2">
        <div className="text-sm font-semibold text-ink-600">ระบบจะลงบัญชีให้ดังนี้</div>
        <Pill className="border-pos bg-pos-bg text-pos-fg">สมดุล ✓</Pill>
        {multi ? (
          <Pill className="border-brand-100 bg-brand-50 text-brand-600">
            {preview.transactions.length} รายการคู่กัน
          </Pill>
        ) : null}
      </div>

      {preview.transactions.map((t) => (
        <div key={t.ownerId} className="overflow-hidden rounded border border-line">
          {/* ข้ามผู้ถือ = คนละรายการ ต้องบอกให้ชัดว่าบรรทัดไหนอยู่ในงบของใคร */}
          {multi ? (
            <div className="border-b border-line bg-canvas p-[8px_10px] text-sm font-semibold">
              งบของ {t.ownerName}
              {t.counterOwnerName ? (
                <span className="font-normal text-ink-600"> · คู่กับ {t.counterOwnerName}</span>
              ) : null}
            </div>
          ) : null}
          <table className="w-full border-collapse text-sm">
            <thead>
              <tr className="bg-canvas">
                <th className="p-[8px_10px] text-left font-semibold text-ink-600">บัญชี</th>
                <th className="p-[8px_10px] text-right font-semibold text-ink-600">เดบิต</th>
                <th className="p-[8px_10px] text-right font-semibold text-ink-600">เครดิต</th>
              </tr>
            </thead>
            <tbody>
              {t.lines.map((l, i) => (
                <tr key={`${l.coaCode}-${i}`} className="border-t border-line">
                  <td className="p-[8px_10px]">
                    <span className="text-ink-400">{l.coaCode}</span> {l.label}
                    {l.memo ? <span className="text-ink-400"> · {l.memo}</span> : null}
                  </td>
                  <td className="p-[8px_10px] text-right tabular-nums">{l.debit ? money(l.debit) : "–"}</td>
                  <td className="p-[8px_10px] text-right tabular-nums">{l.credit ? money(l.credit) : "–"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ))}

      {showSummary ? (
        <ul className="m-0 flex list-none flex-col gap-1 p-0 text-sm leading-6 text-ink-600">
          {preview.summary.map((s, i) => (
            <li key={i}>· {s}</li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}
