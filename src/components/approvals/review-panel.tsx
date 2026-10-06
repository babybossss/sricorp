"use client";

import * as React from "react";
import type { Approval } from "@/lib/mock/ledger";
import { getTxType, findSub, canAccrueFromForm } from "@/lib/rules/tx-rules";
import { entityById } from "@/lib/mock/entities";
import { BANKS } from "@/lib/mock/banks";
import { money } from "@/lib/format";
import { Dialog, SheetContent, DialogHeader, DialogFooter, DialogPrimitive } from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Pill } from "@/components/ui/pill";
import { JournalPreview } from "@/components/form/journal-preview";
import type { PostingInput } from "@/lib/ledger/types";
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
  const bank = BANKS.find((b) => b.ownerId === item.ownerId && !b.off);

  /*
    รออนุมัติ = ยังไม่มีใครยืนยันว่าเงินเคลื่อน จึงพรีวิวเป็นค้างรับ-ค้างจ่าย
    ตรงกับกฎที่ตกลงกันว่า การอนุมัติไม่ย้ายเงินสด ต้องรอ Management ยืนยันอีกขั้น
  */
  const input: PostingInput | null =
    bank && sub
      ? {
          typeKey: item.typeKey,
          subCode: item.subCode,
          amount: Math.abs(item.amount),
          ownerId: item.ownerId,
          bankAccountId: bank.id,
          assetId: item.assetId,
          contactId: item.contactId,
          // ร่างที่ยังไม่ยืนยันเงินเข้า-ออก — ถามฟังก์ชันเดียวกับ engine
          // ไม่ใช่ `!!sub.accrualCoa` ซึ่งจะเปิดธงนี้ให้หมวดที่ engine ปฏิเสธด้วย
          notYetPaid: !!item.notYetPaid,
        }
      : null;

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
            <Row label="บัญชีที่คาดว่าจะใช้">{bank ? `${bank.name} ···${bank.last4}` : "— ยังไม่ระบุ —"}</Row>
          </dl>

          <div className="flex flex-col gap-2 rounded-card border border-line bg-canvas p-4">
            <JournalPreview input={input} showSummary />
            {sub && canAccrueFromForm(sub) ? (
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
            <Button size="sm" onClick={() => onApprove(item)}>
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
