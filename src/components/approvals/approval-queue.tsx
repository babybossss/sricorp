"use client";

import * as React from "react";
import { useRouter } from "next/navigation";
import { getTxType, findSub } from "@/lib/rules/tx-rules";
import { FAMILY_VIEW, type RefOwner } from "@/lib/db/reference-types";
import { signedAmount, sourceLabel, type ApprovalItem } from "@/lib/db/approvals-model";
import { approveDraftEntries, rejectDraftEntries, type BulkOutcome } from "@/app/approvals/actions";
import { isoToDmy, money } from "@/lib/format";
import { Pill } from "@/components/ui/pill";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import { Select } from "@/components/ui/select";
import { Field } from "@/components/ui/field";
import { Dialog, DialogContent, DialogFooter, DialogPrimitive } from "@/components/ui/dialog";
import { useResolver } from "@/components/reference/reference-provider";
import { ReviewPanel } from "./review-panel";
import { previewApproval, planBulkApproval } from "./approval-preview";
import { TYPE_PILL } from "@/lib/tone";
import { cn } from "@/lib/utils";

type Confirm = { kind: "approve" | "reject"; items: ApprovalItem[]; skipped: { item: ApprovalItem; reason: string }[] };

/**
 * คิวอนุมัติรายการ — ร่างจริงจาก `draft_entries` (ไม่มีข้อมูลจำลอง)
 *
 * ปุ่มอนุมัติทุกจุด (ใบเดียว · ที่เลือก · ทั้งหมด · แผงตรวจ) ถาม engine ตัวเดียวกัน (`previewApproval` → `buildPosting()`)
 * การอนุมัติเขียนผ่าน server action → `postEntry()` → `fn_post_entry` · ไม่ปล่อยให้หน้าจอส่งบรรทัดบัญชีเอง
 * ไม่อนุมัติ = แก้เฉพาะแถวร่าง ไม่แตะสมุด · เหตุผลที่ไม่อนุมัติบังคับกรอก
 * กรองตามผู้ถือได้ และมีมุมมองรวม · ใช้ได้บนจอแคบ (การ์ดเรียงลง ไม่ใช่ตารางกว้าง)
 */
export function ApprovalQueue({
  items, owners, assetNames, contactNames, currentUserId,
}: {
  items: ApprovalItem[];
  owners: RefOwner[];
  assetNames: Record<string, string>;
  contactNames: Record<string, string>;
  currentUserId: string;
}) {
  const router = useRouter();
  const resolver = useResolver();
  const [pending, startTransition] = React.useTransition();
  const [owner, setOwner] = React.useState<string>(FAMILY_VIEW);
  const [sel, setSel] = React.useState<Record<string, boolean>>({});
  const [dialog, setDialog] = React.useState<Confirm | null>(null);
  const [reason, setReason] = React.useState("");
  const [reviewId, setReviewId] = React.useState<string | null>(null);
  const [flash, setFlash] = React.useState<{ tone: "ok" | "warn"; text: string; failed?: { id: string; message: string }[] } | null>(null);

  const rows = React.useMemo(() => items.filter((i) => owner === FAMILY_VIEW || i.ownerId === owner), [items, owner]);
  const verdict = React.useMemo(() => new Map(rows.map((a) => [a.id, previewApproval(a, resolver)])), [rows, resolver]);
  const blocked = rows.filter((a) => !verdict.get(a.id)?.canApprove);
  const selected = rows.filter((a) => sel[a.id]);
  const selectedPlan = planBulkApproval(selected, resolver);
  const allPlan = planBulkApproval(rows, resolver);
  const sum = (xs: ApprovalItem[]) => xs.reduce((t, a) => t + Math.round(a.amount * 100), 0) / 100;
  const reviewIdx = reviewId ? rows.findIndex((a) => a.id === reviewId) : -1;
  const visibleOwners = owners.filter((o) => o.status === "active" || items.some((i) => i.ownerId === o.id));
  const nameOf = (id: string) => owners.find((o) => o.id === id);

  function ask(kind: Confirm["kind"], xs: ApprovalItem[], skipped: Confirm["skipped"] = []) {
    setReason("");
    setReviewId(null);
    setDialog({ kind, items: xs, skipped });
  }

  function run() {
    if (!dialog) return;
    const d = dialog;
    if (d.kind === "reject" && !reason.trim()) return;
    startTransition(async () => {
      const ids = d.items.map((a) => a.id);
      const out: BulkOutcome = d.kind === "approve" ? await approveDraftEntries(ids) : await rejectDraftEntries(ids, reason);
      setDialog(null);
      setSel({});
      if (!out.ok) {
        setFlash({ tone: "warn", text: out.message });
        return;
      }
      const verb = d.kind === "approve" ? "อนุมัติ" : "ส่งกลับให้แก้ไข";
      setFlash({
        tone: out.failed.length ? "warn" : "ok",
        text: `${verb}แล้ว ${out.approved} รายการ` + (out.failed.length ? ` · ทำไม่สำเร็จ ${out.failed.length} รายการ (เหตุผลด้านล่าง)` : "") + (d.skipped.length ? ` · ข้าม ${d.skipped.length} รายการที่อนุมัติไม่ได้` : ""),
        failed: out.failed,
      });
      router.refresh();
    });
  }

  return (
    <div className="flex flex-col gap-4 pb-32">
      <div className="flex flex-wrap items-center gap-4 rounded-card border border-line bg-surface p-[18px_20px] shadow-card">
        <div>
          <div className="text-h1 font-semibold" data-testid="queue-count">รออนุมัติ {rows.length} รายการ</div>
          <div className="text-base text-ink-600 tabular-nums">รวม {money(sum(rows), { dash: false })} บาท (ผลบวกยอดของทุกรายการในคิว)</div>
        </div>
        <Field label="ผู้ถือ" className="min-w-[240px]">
          <Select value={owner} onChange={(e) => { setOwner(e.target.value); setSel({}); }}>
            <option value={FAMILY_VIEW}>SRI Family (รวมทุกชื่อ)</option>
            {visibleOwners.map((o) => (
              <option key={o.id} value={o.id}>{o.name}</option>
            ))}
          </Select>
        </Field>
        <div className="ml-auto flex flex-wrap gap-2.5">
          <Button variant="secondary" onClick={() => setSel(Object.fromEntries(rows.map((a) => [a.id, true])))} disabled={rows.length === 0}>
            เลือกทั้งหมด
          </Button>
          <Button disabled={allPlan.approvable.length === 0 || pending} onClick={() => ask("approve", allPlan.approvable, allPlan.skipped)}>
            {allPlan.skipped.length ? `อนุมัติที่ผ่าน ${allPlan.approvable.length} รายการ` : "อนุมัติทั้งหมด"}
          </Button>
        </div>
      </div>

      {flash ? (
        <div role="status" className={cn("rounded-card border p-[14px_18px] text-base leading-7", flash.tone === "ok" ? "border-pos bg-pos-bg text-pos-fg" : "border-warn bg-warn-bg text-warn-fg")}>
          {flash.text}
          {flash.failed?.length ? (
            <ul className="m-0 mt-1 list-disc pl-5">
              {flash.failed.map((f) => (
                <li key={f.id}>{f.message}</li>
              ))}
            </ul>
          ) : null}
        </div>
      ) : null}

      {blocked.length > 0 ? (
        <div role="alert" className="rounded-card border border-neg bg-neg-bg p-[14px_18px] text-base leading-7 text-neg-fg">
          <b>มี {blocked.length} รายการอนุมัติไม่ได้</b> — ระบบจะข้ามรายการเหล่านี้ตอนอนุมัติหมู่ ต้องให้ผู้สร้างเติมข้อมูลหรือแนบหลักฐานก่อน (กด “ตรวจรายการ” เพื่อดูเหตุผล)
        </div>
      ) : null}

      {rows.length === 0 ? (
        <div className="rounded-card border border-line bg-surface p-6 text-base text-ink-600 shadow-card" data-testid="queue-empty">
          {items.length === 0 ? "ไม่มีรายการรออนุมัติ" : "ไม่มีรายการรออนุมัติของผู้ถือที่เลือก"}
        </div>
      ) : (
        <ul className="m-0 flex list-none flex-col gap-3 p-0">
          {rows.map((a) => {
            const type = a.typeKey ? getTxType(a.typeKey) : null;
            const sub = findSub(a.subCode)?.sub;
            const holder = nameOf(a.ownerId);
            const v = verdict.get(a.id);
            const amount = signedAmount(a);
            const mine = !!a.createdBy && a.createdBy.id === currentUserId;
            return (
              <li key={a.id} data-testid={`approval-${a.id}`} className={cn("flex flex-wrap items-center gap-x-4 gap-y-3 rounded-card border border-line p-[14px_16px] shadow-card", sel[a.id] ? "bg-brand-50" : "bg-surface")}>
                <label className="flex min-h-control max-md:min-h-control-mobile items-center gap-3">
                  <Checkbox checked={!!sel[a.id]} onChange={() => setSel((s) => ({ ...s, [a.id]: !s[a.id] }))} aria-label={`เลือก ${sub?.label ?? a.subCode}`} />
                  <span className="text-base md:sr-only">เลือก</span>
                </label>
                <div className="min-w-[220px] flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    {type ? <Pill className={TYPE_PILL[type.tone]}>{type.label}</Pill> : null}
                    <span className="text-base font-semibold">{sub?.label ?? a.subCode}</span>
                  </div>
                  {a.memo ? <div className="text-base">{a.memo}</div> : null}
                  <div className="text-sm text-ink-600">
                    {sourceLabel(a.source)} · {isoToDmy(a.docDate)} · สร้างโดย {a.createdBy?.name ?? "ระบบ"}
                  </div>
                  <span className="inline-flex items-center gap-1.5 text-base">
                    <span className="h-2.5 w-2.5 rounded-pill bg-holder-group" style={holder?.color ? { background: holder.color } : undefined} />
                    {holder?.name ?? "ไม่ทราบผู้ถือ"}
                  </span>
                  <div className="mt-1 flex flex-wrap gap-2">
                    {v && !v.canApprove ? <Pill className="border-neg bg-neg-bg text-neg-fg">อนุมัติไม่ได้ — กดตรวจรายการดูเหตุผล</Pill> : null}
                    {mine ? <Pill className="border-warn bg-warn-bg text-warn-fg">คุณเป็นผู้สร้างร่างนี้เอง</Pill> : null}
                  </div>
                </div>
                <div className={cn("text-h2 font-semibold tabular-nums", amount < 0 ? "text-neg" : "text-pos")}>{money(amount, { dash: false })}</div>
                <div className="flex flex-wrap gap-2">
                  <Button variant="secondary" onClick={() => setReviewId(a.id)}>ตรวจรายการ</Button>
                  <Button variant="danger" onClick={() => ask("reject", [a])} disabled={pending}>ไม่อนุมัติ</Button>
                  <Button onClick={() => ask("approve", [a])} disabled={!v?.canApprove || pending}>อนุมัติ</Button>
                </div>
              </li>
            );
          })}
        </ul>
      )}

      <ReviewPanel
        item={reviewIdx >= 0 ? rows[reviewIdx] : null}
        owners={owners}
        assetNames={assetNames}
        contactNames={contactNames}
        currentUserId={currentUserId}
        position={{ index: Math.max(reviewIdx, 0), total: rows.length }}
        busy={pending}
        onClose={() => setReviewId(null)}
        onStep={(d) => setReviewId(rows[Math.min(rows.length - 1, Math.max(0, reviewIdx + d))]?.id ?? null)}
        onApprove={(a) => ask("approve", [a])}
        onReject={(a) => ask("reject", [a])}
      />

      <div className="rounded-card border border-brand-100 bg-brand-50 p-[14px_18px] text-base leading-7">
        ร่างที่ยังไม่อนุมัติ <b>ไม่อยู่ในสมุดบัญชีและไม่เข้างบใดๆ</b> — อนุมัติแล้วจึงลงสมุดจริง (ผู้สร้างเห็นสถานะ “รอ Management อนุมัติ” จนกว่าจะมีการอนุมัติ)
      </div>

      {selected.length ? (
        <div className="fixed bottom-4 left-4 right-4 z-40 flex flex-wrap items-center gap-4 rounded-card bg-ink-900 p-[14px_20px] text-white shadow-bar md:bottom-6 md:left-[280px] md:right-6">
          <div className="text-base font-semibold">
            เลือก {selected.length} รายการ {money(sum(selected), { dash: false })} บาท
            {selectedPlan.skipped.length ? ` · อนุมัติไม่ได้ ${selectedPlan.skipped.length} รายการ (จะถูกข้าม)` : ""}
          </div>
          <div className="ml-auto flex flex-wrap gap-2.5">
            <Button variant="ghost" className="border border-white/40 text-white hover:bg-white/10" onClick={() => ask("reject", selected)} disabled={pending}>
              ไม่อนุมัติที่เลือก
            </Button>
            <Button
              variant="secondary"
              className="border-white bg-white text-brand-600 disabled:border-line disabled:bg-canvas disabled:text-ink-400"
              disabled={selectedPlan.approvable.length === 0 || pending}
              onClick={() => ask("approve", selectedPlan.approvable, selectedPlan.skipped)}
            >
              อนุมัติที่เลือก
            </Button>
          </div>
        </div>
      ) : null}

      <Dialog open={!!dialog} onOpenChange={(v) => !v && !pending && setDialog(null)}>
        {dialog ? (
          <DialogContent width="max-w-[560px]">
            <div className="flex flex-col gap-4 p-6">
              <DialogPrimitive.Title className="text-h2 font-semibold">
                {dialog.kind === "approve" ? `ยืนยันอนุมัติ ${dialog.items.length} รายการ` : `ไม่อนุมัติ ${dialog.items.length} รายการ`}
              </DialogPrimitive.Title>
              <DialogPrimitive.Description className="sr-only">ตรวจสิ่งที่ระบบจะบันทึกก่อนกดยืนยัน</DialogPrimitive.Description>
              {/* ระบบจะบันทึกให้ดังนี้ */}
              <section data-testid="will-save" className="rounded-card border border-brand-100 bg-brand-50 p-[14px_16px]">
                <div className="text-base font-semibold">ระบบจะบันทึกให้ดังนี้</div>
                {dialog.kind === "approve" ? (
                  <ul className="m-0 mt-1.5 flex list-disc flex-col gap-1 pl-5 text-base leading-7">
                    <li>
                      ลงสมุดบัญชีจริง {dialog.items.length} รายการ รวม <b className="tabular-nums">{money(sum(dialog.items), { dash: false })}</b> บาท
                    </li>
                    <li>บรรทัดบัญชีคำนวณใหม่ตอนบันทึกโดยระบบบัญชีกลาง (ไม่ใช้บรรทัดจากหน้าจอนี้) · ร่างจะถูกปิดเป็น “อนุมัติแล้ว”</li>
                    {dialog.skipped.length ? (
                      <li>
                        ข้าม {dialog.skipped.length} รายการที่อนุมัติไม่ได้:
                        <ul className="m-0 list-disc pl-5">
                          {dialog.skipped.map((x) => (
                            <li key={x.item.id}>{x.item.memo ?? findSub(x.item.subCode)?.sub.label ?? x.item.subCode} — {x.reason}</li>
                          ))}
                        </ul>
                      </li>
                    ) : null}
                  </ul>
                ) : (
                  <ul className="m-0 mt-1.5 flex list-disc flex-col gap-1 pl-5 text-base leading-7">
                    <li>ส่งกลับ {dialog.items.length} รายการให้ผู้สร้างแก้ไข พร้อมเหตุผลด้านล่าง</li>
                    <li><b>ไม่มีอะไรถูกลงสมุดบัญชี</b> — ร่างถูกปิดเป็น “ไม่อนุมัติ” เท่านั้น</li>
                  </ul>
                )}
              </section>
              {dialog.kind === "reject" ? (
                <Field label="เหตุผลที่ไม่อนุมัติ (จำเป็น)" required error={reason.trim() ? undefined : "ต้องใส่เหตุผลก่อนจึงจะยืนยันได้"}>
                  <Input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="เช่น ยอดไม่ตรงกับใบแจ้งหนี้" autoComplete="off" />
                </Field>
              ) : null}
            </div>
            <DialogFooter className="border-t-0">
              <Button variant="secondary" onClick={() => setDialog(null)} disabled={pending}>ยกเลิก</Button>
              <Button
                variant={dialog.kind === "reject" ? "danger" : "primary"}
                className={dialog.kind === "reject" ? "border-neg bg-neg text-white hover:brightness-95" : undefined}
                disabled={pending || (dialog.kind === "reject" && !reason.trim())}
                onClick={run}
              >
                {pending ? "กำลังบันทึก…" : dialog.kind === "approve" ? `ยืนยันอนุมัติ ${dialog.items.length} รายการ` : "ยืนยันไม่อนุมัติ"}
              </Button>
            </DialogFooter>
          </DialogContent>
        ) : null}
      </Dialog>
    </div>
  );
}
