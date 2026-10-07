"use client";

import * as React from "react";
import type { AssetDraft, AssetRef } from "@/lib/mock/assets";
import { findEntity } from "@/lib/mock/entities";
import { Dialog, SheetContent, DialogFooter, DialogPrimitive } from "@/components/ui/dialog";
import { Button } from "./tall-button";
import { Field } from "@/components/ui/field";
import { Input } from "./fields";
import { useApp } from "@/lib/store";
import { AssetDenied, AssetInvalid, useAssetStore } from "./asset-store";
import {
  PATCH_FIELDS, categoryNameOf, classNameOf, computeDiff, fmtDateTime, norm, reviewActions, validateDraft, type Perms,
} from "./asset-drafts";
import { DiffPanel } from "./draft-diff";
import { KindPill, NotCountedNotice, SheetHeader, StatusPill } from "./draft-parts";

/**
 * แผงตรวจร่างที่เลื่อนเข้ามาจากขอบขวา — รูปแบบเดียวกับ `approvals/review-panel.tsx`
 * (Dialog + SheetContent · หัว "ตรวจ n / N" · ก่อนหน้า/ถัดไป · ปุ่มท้ายแผง)
 *
 * ปุ่มทุกตัวมาจาก `reviewActions()` ซึ่งเดินตาม policy ใน DB — ไม่โชว์ปุ่มที่กดแล้วถูกปฏิเสธ
 * (ซ่อนปุ่ม = ความสะดวก ไม่ใช่ความปลอดภัย · RLS คือของจริง)
 */
export function DraftReviewPanel({
  draft,
  perms,
  currentUser,
  position,
  onClose,
  onStep,
  onDone,
}: {
  draft: AssetDraft | null;
  perms: Perms;
  currentUser: { id: string; name: string };
  position: { index: number; total: number };
  onClose: () => void;
  onStep: (delta: number) => void;
  /** ตัดสินแล้ว (อนุมัติ/ปฏิเสธ/ยกเลิก) — ให้หน้าคิวเลื่อนไปรายการถัดไป */
  onDone: () => void;
}) {
  const assets = useAssetStore((s) => s.assets);
  const approveDraft = useAssetStore((s) => s.approveDraft);
  const rejectDraft = useAssetStore((s) => s.rejectDraft);
  const cancelDraft = useAssetStore((s) => s.cancelDraft);
  const showToast = useApp((s) => s.showToast);

  const [rejecting, setRejecting] = React.useState(false);
  const [reason, setReason] = React.useState("");
  const [error, setError] = React.useState<string | null>(null);

  // เปลี่ยนไปดูร่างอื่น → เคลียร์สถานะที่ค้างจากร่างก่อนหน้า
  const draftId = draft?.id;
  React.useEffect(() => {
    setRejecting(false);
    setReason("");
    setError(null);
  }, [draftId]);

  if (!draft) return null;

  const target = draft.targetAssetId ? assets.find((a) => a.id === draft.targetAssetId) : undefined;
  const holder = findEntity(draft.ownerId);
  const actions = reviewActions(perms, draft, currentUser.id);
  // ตรวจจากข้อมูลจริงของร่าง — ร่างเก่าที่เพี้ยนต้องเห็นว่าเพี้ยน ไม่ใช่ปล่อยให้กดอนุมัติแล้วค่อยพัง
  const problems = draft.status === "pending" ? validateDraft(draft, assets) : [];
  const mine = draft.createdBy.id === currentUser.id;

  const actor = { ...currentUser, permissions: perms };
  function run(fn: () => void, okMessage: string) {
    try {
      fn();
      setError(null);
      showToast(okMessage);
      onDone();
    } catch (e) {
      if (e instanceof AssetInvalid) setError(e.errors.join(" · "));
      else if (e instanceof AssetDenied) setError(e.message);
      else throw e;
    }
  }

  return (
    <Dialog open onOpenChange={(o) => (o ? null : onClose())}>
      <SheetContent aria-describedby={undefined} width="max-w-[620px]">
        <DialogPrimitive.Title className="sr-only">ตรวจร่างทะเบียนทรัพย์</DialogPrimitive.Title>
        <SheetHeader title={`ตรวจร่าง ${position.index + 1} / ${position.total}`} onClose={onClose} />

        <div className="flex flex-1 flex-col gap-5 overflow-auto p-[20px_24px]" data-testid="draft-panel">
          <div className="flex flex-col gap-2">
            <div className="flex flex-wrap items-center gap-2">
              <KindPill kind={draft.kind} />
              <StatusPill status={draft.status} />
            </div>
            <div className="text-h2 font-semibold">
              {draft.kind === "create" ? (norm(draft.name) ?? "(ยังไม่มีชื่อ)") : (target?.name ?? "(ไม่พบทรัพย์)")}
            </div>
          </div>

          {draft.status === "pending" ? <NotCountedNotice /> : null}

          <dl className="m-0 grid grid-cols-[auto_1fr] gap-x-5 gap-y-2.5 text-base">
            <Row label="ผู้สร้างร่าง">{draft.createdBy.name}{mine ? " (คุณ)" : ""}</Row>
            <Row label="สร้างเมื่อ"><span className="tabular-nums">{fmtDateTime(draft.createdAt)}</span></Row>
            <Row label="ถือในชื่อ">
              <span className="inline-flex items-center gap-1.5">
                {holder ? <span className="h-2.5 w-2.5 rounded-pill" style={{ background: holder.color }} /> : null}
                {holder?.name ?? `ไม่พบผู้ถือ (${draft.ownerId || "ว่าง"})`}
              </span>
            </Row>
            {draft.note ? <Row label="หมายเหตุ">{draft.note}</Row> : null}
          </dl>

          {/* หน้าคิวต้องบอกชัดว่าคนคีย์กับคนอนุมัติเป็นคนเดียวกัน (เอกสาร §6 ความเสี่ยงข้อ 1) */}
          {mine && actions.approve ? (
            <div role="note" data-testid="same-person" className="rounded border border-warn bg-warn-bg p-[12px_14px] text-base leading-7 text-warn-fg">
              <b>คุณเป็นทั้งคนร่างและคนอนุมัติของรายการนี้</b> — ระบบจะบันทึกชื่อคุณเป็นผู้อนุมัติ
            </div>
          ) : null}

          {draft.kind === "update" ? (
            <DiffPanel draft={draft} asset={target} />
          ) : (
            <CreateFields draft={draft} />
          )}

          {problems.length ? (
            <div role="alert" className="rounded border border-neg bg-neg-bg p-[12px_14px] text-base leading-7 text-neg-fg">
              <b>อนุมัติไม่ได้ — ข้อมูลของร่างนี้ไม่ครบหรือไม่ถูกต้อง</b>
              <ul className="m-0 mt-1 list-disc pl-5">
                {problems.map((p) => (
                  <li key={p}>{p}</li>
                ))}
              </ul>
              ต้องให้ {draft.createdBy.name} แก้ให้ครบ แล้วส่งร่างมาใหม่
            </div>
          ) : null}

          {actions.approveNote ? (
            <div role="note" className="rounded border border-line bg-canvas p-[12px_14px] text-base leading-7 text-ink-600">
              {actions.approveNote}
            </div>
          ) : null}

          {draft.status !== "pending" ? <ReviewRecord draft={draft} assets={assets} /> : null}

          {rejecting ? (
            <div className="flex flex-col gap-3 rounded-card border border-line bg-canvas p-4">
              <Field label="เหตุผลที่ไม่อนุมัติ" required hint="ผู้สร้างร่างจะเห็นข้อความนี้">
                <Input value={reason} onChange={(e) => setReason(e.target.value)} autoComplete="off" />
              </Field>
              <div className="flex flex-wrap gap-3">
                <Button variant="danger" onClick={() => run(() => rejectDraft(draft.id, reason, actor), "ไม่อนุมัติร่างแล้ว")}>
                  ยืนยันไม่อนุมัติ
                </Button>
                <Button variant="secondary" onClick={() => setRejecting(false)}>
                  กลับไปตรวจต่อ
                </Button>
              </div>
            </div>
          ) : null}

          {error ? (
            <div role="alert" className="rounded border border-neg bg-neg-bg p-[12px_14px] text-base leading-7 text-neg-fg">
              {error}
            </div>
          ) : null}
        </div>

        <DialogFooter className="justify-between">
          <div className="flex flex-wrap gap-2">
            <Button variant="secondary" onClick={() => onStep(-1)} disabled={position.index === 0}>
              ก่อนหน้า
            </Button>
            <Button variant="secondary" onClick={() => onStep(1)} disabled={position.index >= position.total - 1}>
              ถัดไป
            </Button>
          </div>
          <div className="flex flex-wrap gap-2">
            {actions.cancel ? (
              <Button variant="secondary" onClick={() => run(() => cancelDraft(draft.id, actor), "ยกเลิกร่างแล้ว")}>
                ยกเลิกร่างนี้
              </Button>
            ) : null}
            {actions.reject && !rejecting ? (
              <Button variant="danger" onClick={() => setRejecting(true)}>
                ไม่อนุมัติ
              </Button>
            ) : null}
            {actions.approve ? (
              <Button
                disabled={problems.length > 0}
                onClick={() => run(() => approveDraft(draft.id, actor), "อนุมัติแล้ว — ทรัพย์เข้าทะเบียนและนับในพอร์ตแล้ว")}
              >
                อนุมัติ
              </Button>
            ) : null}
          </div>
        </DialogFooter>
      </SheetContent>
    </Dialog>
  );
}

function CreateFields({ draft }: { draft: AssetDraft }) {
  const diff = computeDiff(draft, undefined);
  const extras = PATCH_FIELDS.filter((f) => f.key in draft.patch && norm(draft.patch[f.key]) !== null);
  return (
    <section className="flex flex-col gap-2" data-testid="create-fields">
      <div className="text-base font-semibold">ข้อมูลที่เสนอ</div>
      <dl className="m-0 grid grid-cols-[auto_1fr] gap-x-5 gap-y-2 text-base">
        <Row label="ชื่อทรัพย์">{norm(draft.name) ?? <Missing />}</Row>
        <Row label="หมวดใหญ่">{classNameOf(draft.classCode) ?? <Missing />}</Row>
        <Row label="หมวดย่อย">{categoryNameOf(draft.categoryCode) ?? <Missing />}</Row>
        {extras.map((f) => (
          <Row key={f.key} label={f.label}>{f.format(norm(draft.patch[f.key]) as string | number)}</Row>
        ))}
      </dl>
      {extras.length === 0 ? <div className="text-base text-ink-600">ไม่มีข้อมูลเพิ่มเติม (ลงทะเบียนด้วย 4 ช่องบังคับ)</div> : null}
      {diff.unknownKeys.length ? (
        <div role="alert" className="rounded border border-neg bg-neg-bg p-[12px_14px] text-base leading-7 text-neg-fg">
          ร่างนี้มีช่องที่ระบบไม่รู้จัก: <b>{diff.unknownKeys.join(", ")}</b>
        </div>
      ) : null}
    </section>
  );
}

function ReviewRecord({ draft, assets }: { draft: AssetDraft; assets: AssetRef[] }) {
  const applied = draft.appliedAssetId ? assets.find((a) => a.id === draft.appliedAssetId) : undefined;
  const verb = draft.status === "approved" ? "อนุมัติโดย" : draft.status === "rejected" ? "ไม่อนุมัติโดย" : "ยกเลิกโดย";
  return (
    <div className="rounded-card border border-line bg-canvas p-[12px_14px] text-base leading-7" data-testid="review-record">
      <div>
        {verb} <b>{draft.reviewedBy?.name ?? "—"}</b>
        {draft.reviewedAt ? <span className="tabular-nums"> · {fmtDateTime(draft.reviewedAt)}</span> : null}
        {draft.reviewedBy && draft.reviewedBy.id === draft.createdBy.id && draft.status !== "cancelled" ? " (คนเดียวกับผู้สร้างร่าง)" : null}
      </div>
      {draft.rejectReason ? <div>เหตุผล: {draft.rejectReason}</div> : null}
      {applied ? <div>ทรัพย์ที่เกิดจากร่างนี้: {applied.name}</div> : null}
    </div>
  );
}

function Missing() {
  return <span className="font-semibold text-neg-fg">ไม่ได้ระบุ</span>;
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <>
      <dt className="whitespace-nowrap text-ink-600">{label}</dt>
      <dd className="m-0 min-w-0 break-words">{children}</dd>
    </>
  );
}
