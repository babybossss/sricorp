"use client";

import * as React from "react";
import type { Approval } from "@/lib/mock/ledger";
import { getTxType, findSub, canAccrueFromForm } from "@/lib/rules/tx-rules";
import { entityById } from "@/lib/mock/entities";
import { BANKS } from "@/lib/mock/banks";
import { MOCK_RESOLVER } from "@/lib/mock/resolver";
import { previewApproval } from "./approval-preview";
import { bankDirectionLabel } from "@/components/form/bank-field";
import { money } from "@/lib/format";
import { Dialog, SheetContent, DialogHeader, DialogFooter, DialogPrimitive } from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Pill } from "@/components/ui/pill";
import { JournalPreview } from "@/components/form/journal-preview";
import { TYPE_PILL } from "@/lib/tone";

/**
 * แผงตรวจรายการก่อนอนุมัติ — เลื่อนเข้ามาจากขอบขวา (ลูกพี่สั่ง 06/10)
 *
 * **บรรทัดบัญชีมาจาก `previewPosting()` เท่านั้น** ผ่าน <JournalPreview />
 * ห้ามคำนวณคู่บัญชีในแผงนี้เอง — ถ้าสิ่งที่คนอนุมัติเห็นมาคนละทางกับสิ่งที่ลงจริง
 * การอนุมัติก็ไม่มีความหมาย (บทเรียน mace-windu ข้อ 5)
 */
export function ReviewPanel({
  item,
  onClose,
  onApprove,
  onReject,
  onStep,
  position,
}: {
  item: Approval | null;
  onClose: () => void;
  onApprove: (a: Approval) => void;
  onReject: (a: Approval) => void;
  onStep: (delta: number) => void;
  position: { index: number; total: number };
}) {
  if (!item) return null;

  const type = getTxType(item.typeKey);
  const sub = findSub(item.subCode)?.sub;
  const holder = entityById(item.ownerId);
  // บัญชีที่คนคีย์เลือกไว้กับตัวรายการ — ไม่หยิบ "บัญชีแรกของผู้ถือ" มาแทน
  const bank = item.bankAccountId ? BANKS.find((b) => b.id === item.bankAccountId) : undefined;

  /*
    รออนุมัติ = ยังไม่มีใครยืนยันว่าเงินเคลื่อน จึงพรีวิวเป็นค้างรับ-ค้างจ่ายตามธงที่มากับรายการ
    ตรงกับกฎที่ตกลงกันว่า การอนุมัติไม่ย้ายเงินสด ต้องรอ Management ยืนยันอีกขั้น

    ข้อมูลพอไหม **ให้ engine ตัดสิน** ไม่ใช่แผงนี้ — แยกสองอย่าง:
    - บรรทัดบัญชีที่โชว์ให้อ่าน (`preview`) มาจาก draft ไฟล์แนบไม่เปลี่ยนคู่บัญชี
    - ปุ่มอนุมัติ (`canApprove`) มาจาก `buildPosting()` ตัวจริง บังคับหลักฐานของนิติบุคคลด้วย
    เหตุผลที่แสดงคือ `PostingError` ของ engine ตรงๆ
  */
  const { input, preview, canApprove, blockedReason } = previewApproval(item, MOCK_RESOLVER);

  return (
    <Dialog open onOpenChange={(o) => (o ? null : onClose())}>
      <SheetContent aria-describedby={undefined}>
        <DialogPrimitive.Title className="sr-only">ตรวจรายการก่อนอนุมัติ</DialogPrimitive.Title>
        <DialogHeader title={`ตรวจรายการ ${position.index + 1} / ${position.total}`} onClose={onClose} />

        <div className="flex flex-1 flex-col gap-5 overflow-auto p-[20px_24px]">
          <div className="flex flex-col gap-2">
            <div className="flex flex-wrap items-center gap-2">
              <Pill className={TYPE_PILL[type.tone]}>{type.label}</Pill>
              <span className="text-base text-ink-600">{sub?.label ?? "—"}</span>
            </div>
            <div className="text-h2 font-semibold">{item.detail}</div>
            <div className={`text-h1 font-semibold ${item.amount < 0 ? "text-neg" : "text-pos"}`}>
              {money(item.amount)}
            </div>
          </div>

          <dl className="m-0 grid grid-cols-[auto_1fr] gap-x-5 gap-y-2.5 text-base">
            <Row label="ถือในชื่อ">
              <span className="inline-flex items-center gap-1.5">
                <span className="h-2.5 w-2.5 rounded-pill" style={{ background: holder.color }} />
                {holder.name}
              </span>
            </Row>
            <Row label="ที่มา">{item.source}</Row>
            <Row label="ผู้สร้าง">{item.by}</Row>
            <Row label="วันที่เอกสาร">{item.date}</Row>
            <Row label={bankDirectionLabel(sub)}>
              {bank
                ? `${bank.name} ···${bank.last4}`
                : item.bankAccountId
                  ? `ไม่พบบัญชี (${item.bankAccountId})`
                  : item.notYetPaid
                    ? "ยังไม่ระบุ — ค้างรับ-ค้างจ่าย ยังไม่มีขาเงินสด"
                    : "ไม่ได้ระบุ"}
            </Row>
          </dl>

          <div className="flex flex-col gap-2 rounded-card border border-line bg-canvas p-4">
            {preview.ok ? <JournalPreview input={input} showSummary /> : null}
            {!canApprove ? (
              <div role="alert" className="rounded border border-neg bg-neg-bg p-[12px_14px] text-base leading-7 text-neg-fg">
                <b>อนุมัติไม่ได้</b>
                {preview.ok ? " — บรรทัดบัญชีด้านบนยังไม่ถูกบันทึก" : " — ระบบยังไม่รู้ว่าจะลงบัญชีอย่างไร"}
                <br />
                เหตุผล: {blockedReason}
                <br />
                ต้องให้ {item.by} เติมข้อมูลให้ครบก่อน แล้วจึงส่งกลับมาอนุมัติ
              </div>
            ) : null}
            {canApprove && sub && canAccrueFromForm(sub) ? (
              <div className="text-sm leading-6 text-ink-600">
                อนุมัติแล้ว<b>ยังไม่ย้ายเงินสด</b> — ต้องให้ Management ยืนยันว่าเงินเข้า/ออกจริงอีกขั้น
                กระแสเงินสดจึงจะวิ่ง
              </div>
            ) : null}
          </div>
        </div>

        <DialogFooter className="justify-between">
          <div className="flex gap-2">
            <Button variant="secondary" size="sm" onClick={() => onStep(-1)} disabled={position.index === 0}>
              ก่อนหน้า
            </Button>
            <Button
              variant="secondary"
              size="sm"
              onClick={() => onStep(1)}
              disabled={position.index >= position.total - 1}
            >
              ถัดไป
            </Button>
          </div>
          <div className="flex gap-2">
            <Button variant="danger" size="sm" onClick={() => onReject(item)}>
              ไม่อนุมัติ
            </Button>
            <Button size="sm" onClick={() => onApprove(item)} disabled={!canApprove}>
              อนุมัติ
            </Button>
          </div>
        </DialogFooter>
      </SheetContent>
    </Dialog>
  );
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <>
      <dt className="whitespace-nowrap text-ink-400">{label}</dt>
      <dd className="m-0">{children}</dd>
    </>
  );
}
