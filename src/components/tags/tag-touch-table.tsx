import * as React from "react";
import { Table, Td, Th } from "@/components/ui/table";
import { money } from "@/lib/format";
import { cn } from "@/lib/utils";
import { TagChip } from "./tag-chip";
import type { TagTouchRow } from "./types";

/**
 * ตารางยอดต่อ tag แบบ "touch" (ADR 0002 ชั้น 1-3) — ยอดที่แตะ tag นี้ ไม่ใช่ส่วนแบ่ง
 * ใบที่ติดหลาย tag ถูกนับในทุก tag ที่ติด จึง **บวกข้ามแถวไม่ได้** → ตารางนี้ไม่มีแถวรวม
 *
 * `aggregateNoteTh` (จาก `tag_kinds.aggregate_note_th`) **บังคับ** และแสดงเหนือตารางเสมอ
 * ลืมส่ง = throw ให้หน้าแดงตอน dev ไม่ใช่ปล่อยเลขเปลือยให้ผู้ใช้อ่านแล้วเอาไปบวกกัน
 *
 * ไม่ใช้กับชนิดที่ถ่วงน้ำหนัก (project) — นั่นคือ "allocated" อีกความหมายหนึ่ง (ADR 0003 ข้อ 5)
 */

export type TagTouchTableProps = {
  aggregateNoteTh: string;
  rows: readonly TagTouchRow[];
  /** ชื่อ Entity ที่ผู้ใช้เห็นอยู่ — ยอดต่อ tag ของคนละสิทธิ์ไม่เท่ากันโดยเจตนา (ADR 0002 ข้อ 5.2) */
  visibleOwnerNamesTh: readonly string[];
  caption?: string;
  className?: string;
};

export function TagTouchTable({ aggregateNoteTh, rows, visibleOwnerNamesTh, caption = "ยอดที่แตะแต่ละ tag", className }: TagTouchTableProps) {
  if (typeof aggregateNoteTh !== "string" || aggregateNoteTh.trim() === "") {
    throw new Error(
      "TagTouchTable: ต้องส่ง aggregateNoteTh (จาก tag_kinds.aggregate_note_th) — ตารางยอดต่อ tag ห้ามแสดงโดยไม่มีประโยคกำกับว่าบวกข้าม tag ไม่ได้ (ADR 0002 ชั้น 3)"
    );
  }

  return (
    <div className={cn("flex min-w-0 flex-col gap-3", className)}>
      <p role="note" data-testid="aggregate-note" className="m-0 rounded border border-brand-100 bg-brand-50 p-[12px_14px] text-base leading-7 text-ink-900">
        {aggregateNoteTh}
      </p>
      <p data-testid="owner-scope" className="m-0 text-sm text-ink-600">
        คิดจาก Entity ที่คุณมีสิทธิ์เห็น: {visibleOwnerNamesTh.length > 0 ? visibleOwnerNamesTh.join(" · ") : "ไม่มี"}
      </p>

      {/* เลื่อนแนวนอนได้เมื่อจอแคบ — ไม่บีบคอลัมน์จนอ่านไม่ออก · โฟกัสด้วยคีย์บอร์ดเพื่อเลื่อนได้ */}
      <div
        role="region"
        aria-label={caption}
        tabIndex={0}
        className="overflow-auto rounded-card border border-line bg-surface shadow-card focus-visible:outline-none focus-visible:ring-[3px] focus-visible:ring-brand-600 focus-visible:ring-offset-2"
      >
        <Table minWidth={860}>
          <caption className="sr-only">{caption}</caption>
          <thead>
            <tr>
              <Th>tag</Th>
              <Th align="right">เดบิตที่แตะ tag นี้ (บาท)</Th>
              <Th align="right">เครดิตที่แตะ tag นี้ (บาท)</Th>
              <Th align="right">จำนวนใบที่แตะ</Th>
              <Th align="right">ใบที่ติดหลาย tag ชนิดเดียวกัน</Th>
              <Th align="right">เดบิตของใบที่ซ้อน (บาท)</Th>
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 ? (
              <tr>
                <Td colSpan={6} className="text-ink-600">
                  ไม่มีรายการที่แตะ tag ในชุดที่กรองอยู่
                </Td>
              </tr>
            ) : (
              rows.map((r) => (
                <tr key={r.tag.id}>
                  <Td>
                    <TagChip tag={r.tag} />
                  </Td>
                  <Td align="right" className="whitespace-nowrap tabular-nums">
                    {money(r.touchedDebit)}
                  </Td>
                  <Td align="right" className="whitespace-nowrap tabular-nums">
                    {money(r.touchedCredit)}
                  </Td>
                  <Td align="right" className="whitespace-nowrap tabular-nums">
                    {r.touchedTxnCount.toLocaleString("en-US")}
                  </Td>
                  <Td align="right" className="whitespace-nowrap tabular-nums">
                    {r.overlapTxnCount.toLocaleString("en-US")}
                  </Td>
                  <Td align="right" className="whitespace-nowrap tabular-nums">
                    {money(r.overlapDebit)}
                  </Td>
                </tr>
              ))
            )}
          </tbody>
        </Table>
      </div>
    </div>
  );
}
