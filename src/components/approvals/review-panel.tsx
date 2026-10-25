"use client";

import * as React from "react";
import { getTxType, findSub, canAccrueFromForm } from "@/lib/rules/tx-rules";
import type { ApprovalItem } from "@/lib/db/approvals-model";
import { signedAmount, sourceLabel } from "@/lib/db/approvals-model";
import type { RefOwner } from "@/lib/db/reference-types";
import { useResolver } from "@/components/reference/reference-provider";
import { previewApproval } from "./approval-preview";
import { isoToDmy, money } from "@/lib/format";
import { Dialog, SheetContent, DialogHeader, DialogFooter, DialogPrimitive } from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Pill } from "@/components/ui/pill";
import { JournalPreview } from "@/components/form/journal-preview";
import { TYPE_PILL } from "@/lib/tone";

/**
 * แผงตรวจรายการก่อนอนุมัติ — เลื่อนเข้ามาจากขอบขวา (ลูกพี่สั่ง 06/10)
 *
 * **บรรทัดบัญชีมาจาก `previewPosting()` เท่านั้น** ผ่าน <JournalPreview />
 * ห้ามคำนวณคู่บัญชีในแผงนี้เอง — ถ้าสิ่งที่คนอนุมัติเห็นมาคนละทางกับสิ่งที่ลงจริง การอนุมัติก็ไม่มีความหมาย
 * ปุ่มอนุมัติ (`canApprove`) มาจาก `buildPosting()` ตัวจริง บังคับหลักฐานของนิติบุคคลด้วย
 */
export function ReviewPanel({
  item, owners, assetNames, contactNames, currentUserId, onClose, onApprove, onReject, onStep, position, busy,
}: {
  item: ApprovalItem | null;
  owners: RefOwner[];
  assetNames: Record<string, string>;
  contactNames: Record<string, string>;
  currentUserId: string;
  onClose: () => void;
  onApprove: (a: ApprovalItem) => void;
  onReject: (a: ApprovalItem) => void;
  onStep: (delta: number) => void;
  position: { index: number; total: number };
  busy?: boolean;
}) {
  const resolver = useResolver();
  if (!item) return null;

  const type = item.typeKey ? getTxType(item.typeKey) : null;
  const sub = findSub(item.subCode)?.sub;
  const holder = owners.find((o) => o.id === item.ownerId);
  const { input, preview, canApprove, blockedReason } = previewApproval(item, resolver);
  const amount = signedAmount(item);
  const mine = !!item.createdBy && item.createdBy.id === currentUserId;

  return (
    <Dialog open onOpenChange={(o) => (o ? null : onClose())}>
      <SheetContent aria-describedby={undefined}>
        <DialogPrimitive.Title className="sr-only">ตรวจรายการก่อนอนุมัติ</DialogPrimitive.Title>
        <DialogHeader title={`ตรวจรายการ ${position.index + 1} / ${position.total}`} onClose={onClose} />

        <div className="flex flex-1 flex-col gap-5 overflow-auto p-[20px_24px]">
          <div className="flex flex-col gap-2">
            <div className="flex flex-wrap items-center gap-2">
              {type ? <Pill className={TYPE_PILL[type.tone]}>{type.label}</Pill> : null}
              <span className="text-base text-ink-600">{sub?.label ?? item.subCode}</span>
            </div>
            <div className="text-h2 font-semibold">{item.memo ?? sub?.label ?? item.subCode}</div>
            <div className={`text-h1 font-semibold tabular-nums ${amount < 0 ? "text-neg" : "text-pos"}`}>{money(amount, { dash: false })}</div>
          </div>

          <dl className="m-0 grid grid-cols-[auto_1fr] gap-x-5 gap-y-2.5 text-base">
            <Row label="ถือในชื่อ">
              <span className="inline-flex items-center gap-1.5">
                <span className="h-2.5 w-2.5 rounded-pill bg-holder-group" style={holder?.color ? { background: holder.color } : undefined} />
                {holder?.name ?? "ไม่ทราบผู้ถือ"}
              </span>
            </Row>
            <Row label="ที่มา">{sourceLabel(item.source)}</Row>
            <Row label="ผู้สร้าง">{item.createdBy?.name ?? "ไม่ทราบ (ระบบ)"}{mine ? " (คุณ)" : ""}</Row>
            <Row label="วันที่เอกสาร">{isoToDmy(item.docDate)}</Row>
            <Row label="วันที่เงินเคลื่อน">{item.cashDate ? isoToDmy(item.cashDate) : "ยังไม่ได้รับ/จ่ายเงิน — ลงเป็นลูกหนี้/เจ้าหนี้"}</Row>
            {item.assetId ? <Row label="ทรัพย์">{assetNames[item.assetId] ?? "ไม่ทราบทรัพย์"}</Row> : null}
            {item.contactId ? <Row label="คู่ค้า">{contactNames[item.contactId] ?? "ไม่ทราบผู้ติดต่อ"}</Row> : null}
            <Row label="หลักฐาน">{item.attachments.length ? `${item.attachments.length} ไฟล์` : "ไม่มีไฟล์แนบ"}</Row>
          </dl>

          {/* ธงผู้สร้างร่าง = ผู้อนุมัติ — DB ยังไม่ห้าม จึงแสดงให้เห็นชัด ไม่กั้นที่หน้าจอ */}
          {mine ? (
            <div role="note" data-testid="same-person" className="rounded border border-warn bg-warn-bg p-[12px_14px] text-base leading-7 text-warn-fg">
              <b>คุณเป็นทั้งคนสร้างร่างและคนอนุมัติของรายการนี้</b> — ระบบจะบันทึกชื่อคุณเป็นผู้อนุมัติ
            </div>
          ) : null}

          <div className="flex flex-col gap-2 rounded-card border border-line bg-canvas p-4">
            {preview.ok ? <JournalPreview input={input} showSummary /> : null}
            {!canApprove ? (
              <div role="alert" className="rounded border border-neg bg-neg-bg p-[12px_14px] text-base leading-7 text-neg-fg">
                <b>อนุมัติไม่ได้</b>
                {preview.ok ? " — บรรทัดบัญชีด้านบนยังไม่ถูกบันทึก" : " — ระบบยังไม่รู้ว่าจะลงบัญชีอย่างไร"}
                <br />
                เหตุผล: {blockedReason}
                <br />
                ต้องให้ {item.createdBy?.name ?? "ผู้สร้าง"} เติมข้อมูลให้ครบก่อน แล้วจึงส่งกลับมาอนุมัติ
              </div>
            ) : null}
            {canApprove && sub && canAccrueFromForm(sub) ? (
              <div className="text-sm leading-6 text-ink-600">
                อนุมัติแล้ว<b>ยังไม่ย้ายเงินสด</b> — ต้องยืนยันว่าเงินเข้า/ออกจริงอีกขั้นที่หน้ายืนยันรับ-จ่าย กระแสเงินสดจึงจะวิ่ง
              </div>
            ) : null}
          </div>
        </div>

        <DialogFooter className="justify-between">
          <div className="flex gap-2">
            <Button variant="secondary" onClick={() => onStep(-1)} disabled={position.index === 0 || busy}>
              ก่อนหน้า
            </Button>
            <Button variant="secondary" onClick={() => onStep(1)} disabled={position.index >= position.total - 1 || busy}>
              ถัดไป
            </Button>
          </div>
          <div className="flex gap-2">
            <Button variant="danger" onClick={() => onReject(item)} disabled={busy}>
              ไม่อนุมัติ
            </Button>
            <Button onClick={() => onApprove(item)} disabled={!canApprove || busy}>
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
      <dt className="whitespace-nowrap text-ink-600">{label}</dt>
      <dd className="m-0">{children}</dd>
    </>
  );
}
