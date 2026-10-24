"use client";

import * as React from "react";
import { useRouter } from "next/navigation";
import { Table, Th, Td } from "@/components/ui/table";
import { Pill } from "@/components/ui/pill";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Checkbox } from "@/components/ui/checkbox";
import { Select } from "@/components/ui/select";
import { Field } from "@/components/ui/field";
import { Dialog, DialogContent, DialogFooter, DialogPrimitive } from "@/components/ui/dialog";
import { isoToDmy, money, todayDmy } from "@/lib/format";
import type { PendingCashRow } from "@/lib/mock/ledger";
import { useApp } from "@/lib/store";
import { useReference, useResolver } from "@/components/reference/reference-provider";
import { bankChoices, bankDirectionLabel } from "@/components/form/bank-field";
import { findSub } from "@/lib/rules/tx-rules";
import { confirmCash } from "@/app/actions/confirm-cash";
import type { PendingAccrual } from "@/lib/db/pending-accruals";
import type { PendingAccrualsState } from "@/lib/db/pending-accruals-server";
import { prepareImageForUpload, uploadAttachmentFromBrowser } from "@/lib/storage/browser";
import { safeDisplayName } from "@/lib/storage/path";
import { ClearingPreview } from "./clearing-preview";
import {
  accruedAmountText,
  checkRow,
  clearingChoicesOf,
  directionOf,
  initialDraft,
  type RowDraft,
} from "./confirm-flow";

/**
 * ยืนยันรับ-จ่าย — ขั้นที่ล้างยอดค้างรับ-ค้างจ่ายและทำให้งบกระแสเงินสดวิ่ง
 *
 * - **รายการค้างอ่านจาก DB** (`v_ledger_posted`) ไม่ใช่ข้อมูลจำลอง และไม่เก็บผลไว้ใน state:
 *   ยืนยันสำเร็จแล้วโหลดจาก DB ใหม่ (`router.refresh()`) รายการที่ล้างครบจึงหายไปเพราะ DB บอก
 * - พรีวิวบรรทัดบัญชี → `buildClearingDraft()` (ผ่าน `checkRow`) · เปิดปุ่มได้ก็ต่อเมื่อ `buildClearing()` ตัวจริงยอมรับ
 * - ปุ่มยืนยัน → server action `confirmCash` ซึ่งอ่านประวัติสดจาก DB แล้วเรียก `buildClearing()` ซ้ำฝั่งเซิร์ฟเวอร์
 *   (ไม่ส่งบรรทัดบัญชีจาก browser) · error จาก DB แสดงค้างไว้ ไม่กลืน
 */

/** แปลงยอดค้างจาก DB เป็นแถวที่ `confirm-flow` ใช้ — ไม่มีค่าที่หน้าจอคิดเอง (ยกเว้นค่าตั้งต้นของช่องกรอก) */
function rowOf(p: PendingAccrual, ownerName: string, assetName: string | undefined): PendingCashRow {
  const label = findSub(p.subCode)?.sub.label ?? p.subCode;
  return {
    id: p.id,
    name: p.memo ?? label,
    sub: [ownerName, assetName, label].filter(Boolean).join(" · "),
    ownerId: p.ownerId,
    due: isoToDmy(p.docDate),
    typeKey: p.typeKey,
    subCode: p.subCode,
    accruedAmount: p.accruedAmount,
    postedClearings: p.postedClearings,
    assetId: p.assetId ?? undefined,
    contactId: p.contactId ?? undefined,
    attachments: p.attachments,
    actual: p.outstanding.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 }),
    date: todayDmy(),
  };
}

export function ConfirmTab({ pending }: { pending: PendingAccrualsState }) {
  const router = useRouter();
  const showToast = useApp((s) => s.showToast);
  const ref = useReference();
  const resolver = useResolver();

  const [drafts, setDrafts] = React.useState<Record<string, RowDraft>>({});
  const [checked, setChecked] = React.useState<Record<string, boolean>>({});
  const [reviewing, setReviewing] = React.useState(false);
  const [submitting, setSubmitting] = React.useState(false);
  const submittingRef = React.useRef(false);
  const [failure, setFailure] = React.useState<string | null>(null);
  const [uploading, setUploading] = React.useState<string | null>(null);
  const [uploadError, setUploadError] = React.useState<string | null>(null);

  const rows = React.useMemo(
    () =>
      pending.ok
        ? pending.pending.map((p) =>
            rowOf(
              p,
              ref.owners.find((o) => o.id === p.ownerId)?.name ?? "ผู้ถือที่ไม่รู้จัก",
              p.assetId ? ref.assets.find((a) => a.id === p.assetId)?.name : undefined
            )
          )
        : [],
    [pending, ref.owners, ref.assets]
  );

  if (!pending.ok) {
    return (
      <div role="alert" className="rounded border border-neg bg-neg-bg p-[14px_16px] text-base leading-7 text-neg-fg">
        โหลดรายการค้างรับ-ค้างจ่ายจากฐานข้อมูลไม่สำเร็จ จึงยืนยันรับ-จ่ายไม่ได้: {pending.error}
        <div className="mt-1 text-sm">ลองโหลดหน้านี้ใหม่ ถ้ายังไม่ได้ให้แจ้งผู้ดูแลระบบ</div>
      </div>
    );
  }

  const draftOf = (r: PendingCashRow): RowDraft => drafts[r.id] ?? initialDraft(r);
  const patch = (r: PendingCashRow, p: Partial<RowDraft>) =>
    setDrafts((m) => ({ ...m, [r.id]: { ...(m[r.id] ?? initialDraft(r)), ...p } }));

  // ประวัติว่างเสมอ — `historyOf` ใช้ประวัติที่ติดมากับแถว (ซึ่งมาจาก DB) ไม่มีประวัติที่หน้าจอสะสมเอง
  const checks = new Map(rows.map((r) => [r.id, checkRow(r, draftOf(r), {}, resolver)]));
  // ติ๊กค้างไว้แต่ engine ไม่ให้ผ่านแล้ว (เช่น บัญชีหลุด) = ไม่นับว่าเลือก
  const isOn = (r: PendingCashRow) => !!checked[r.id] && !!checks.get(r.id)?.canConfirm;
  const selected = rows.filter(isOn);

  async function onSlip(r: PendingCashRow, files: FileList | null) {
    if (!files || files.length === 0) return;
    setUploading(r.id);
    setUploadError(null);
    const added: string[] = [];
    try {
      for (const file of Array.from(files)) {
        const prepared = await prepareImageForUpload(file);
        if (!prepared.ok) {
          setUploadError(`${safeDisplayName(file.name)}: ${prepared.message}`);
          continue;
        }
        const up = await uploadAttachmentFromBrowser(prepared.file, r.ownerId);
        if (!up.ok) {
          setUploadError(`${safeDisplayName(file.name)}: ${up.message}`);
          continue;
        }
        added.push(up.ref);
      }
    } finally {
      setUploading(null);
    }
    if (added.length) patch(r, { slips: [...draftOf(r).slips, ...added] });
  }

  async function confirm() {
    if (submittingRef.current) return;
    submittingRef.current = true;
    setSubmitting(true);
    setFailure(null);
    try {
      const outcome = await confirmCash({
        items: selected.map((r) => {
          const d = draftOf(r);
          return {
            sourceId: r.id,
            amount: d.amount,
            date: d.date,
            bankAccountId: r.bankAccountId || d.bankAccountId,
            slips: d.slips,
            clearingSubCode: d.clearingSubCode || undefined,
            expectedClearedCount: r.postedClearings.length,
          };
        }),
      });
      const okIds = new Set(outcome.results.filter((x) => x.ok).map((x) => x.sourceId.toLowerCase()));
      if (okIds.size > 0) {
        // ล้างค่าที่ยืนยันแล้วออกจากฟอร์ม แล้วให้ DB เป็นคนบอกว่ารายการไหนยังค้าง
        setChecked((m) => Object.fromEntries(Object.entries(m).map(([id, v]) => [id, okIds.has(id.toLowerCase()) ? false : v])));
        setDrafts((m) => Object.fromEntries(Object.entries(m).filter(([id]) => !okIds.has(id.toLowerCase()))));
        router.refresh();
      }
      if (!outcome.ok) {
        const lines = outcome.results
          .filter((x) => !x.ok)
          .map((x) => `${rows.find((r) => r.id.toLowerCase() === x.sourceId.toLowerCase())?.name ?? x.sourceId} — ${(x as { message: string }).message}`);
        setFailure([outcome.message, ...lines].filter(Boolean).join("\n"));
        return;
      }
      setReviewing(false);
      const replayed = outcome.results.some((x) => x.ok && x.replayed);
      showToast(
        replayed
          ? "รายการนี้เพิ่งยืนยันไปแล้ว ระบบไม่ได้ลงซ้ำ"
          : `ยืนยันรับ-จ่าย ${outcome.results.length} รายการแล้ว`
      );
    } catch (e) {
      // เครือข่ายขาดกลางทาง = ไม่รู้ว่าสำเร็จหรือยัง ต้องบอกตรงๆ ไม่ใช่เดา
      console.error("confirmCash failed", e);
      setFailure(
        "ติดต่อเซิร์ฟเวอร์ไม่ได้ระหว่างยืนยัน — ยังไม่ทราบว่ารายการถูกบันทึกหรือไม่ ปิดหน้าต่างนี้แล้วโหลดหน้าใหม่ตรวจยอดค้างก่อนกดซ้ำ"
      );
    } finally {
      submittingRef.current = false;
      setSubmitting(false);
    }
  }

  const renderRow = (r: PendingCashRow) => {
    const check = checks.get(r.id)!;
    const draft = draftOf(r);
    const dir = directionOf(r);
    const choices = clearingChoicesOf(r);
    const done = r.postedClearings.length;
    const banks = ref.banks
      .filter((b) => b.isActive || b.id === draft.bankAccountId)
      .sort((a, b) => a.sortOrder - b.sortOrder);
    return (
      <tr key={r.id}>
        <Td className="p-[12px_14px]">
          <div className="font-semibold">{r.name}</div>
          <div className="text-sm text-ink-400">{r.sub}</div>
          {done > 0 ? <Pill className="mt-1 border-pos bg-pos-bg text-pos-fg">ยืนยันไปแล้ว {done} ครั้ง</Pill> : null}
          {choices.length > 1 ? (
            <Field label="ล้างยอดค้างด้วยทางไหน" required className="mt-2">
              <Select value={draft.clearingSubCode} onChange={(e) => patch(r, { clearingSubCode: e.target.value })}>
                <option value="">— เลือกทางล้าง —</option>
                {choices.map((c) => (
                  <option key={c.code} value={c.code}>
                    {c.label}
                  </option>
                ))}
              </Select>
            </Field>
          ) : null}
          {!check.canConfirm ? (
            <div className="mt-1 text-sm leading-6 text-warn-fg">ยังยืนยันไม่ได้ — {check.blockedReason}</div>
          ) : null}
        </Td>
        <Td className="whitespace-nowrap p-[12px_14px] text-ink-600">{r.due}</Td>
        <Td align="right" className="whitespace-nowrap p-[12px_14px]">
          {accruedAmountText(dir, r.accruedAmount)}
        </Td>
        <Td align="right" className="p-[12px_14px]">
          <Input
            aria-label={`ยอดที่ยืนยันครั้งนี้ ${r.name}`}
            inputMode="decimal"
            value={draft.amount}
            onChange={(e) => patch(r, { amount: e.target.value })}
            className="w-40 text-right font-semibold tabular-nums"
          />
        </Td>
        <Td className="p-[12px_14px]">
          <Input
            aria-label={`วันที่เงินเข้า-ออกจริง ${r.name}`}
            value={draft.date}
            onChange={(e) => patch(r, { date: e.target.value })}
            inputMode="numeric"
            className="w-36"
          />
        </Td>
        <Td className="p-[12px_14px]">
          <Field label={bankDirectionLabel(findSub(r.subCode)?.sub)} required>
            <Select value={draft.bankAccountId} onChange={(e) => patch(r, { bankAccountId: e.target.value })}>
              <option value="">— เลือกบัญชี —</option>
              {bankChoices(banks, (id) => !ref.banks.find((b) => b.id === id)?.isActive, r.ownerId, draft.bankAccountId).map((b) => (
                <option key={b.id} value={b.id}>
                  {b.name}
                </option>
              ))}
            </Select>
          </Field>
        </Td>
        <Td className="p-[12px_14px]">
          <div className="flex flex-col items-start gap-1">
            <label className="inline-flex">
              <input
                type="file"
                hidden
                multiple
                accept="image/jpeg,image/png,image/webp,image/heic,application/pdf"
                onChange={(e) => {
                  void onSlip(r, e.target.files);
                  e.target.value = "";
                }}
              />
              <span
                role="button"
                tabIndex={0}
                className="inline-flex min-h-control cursor-pointer items-center justify-center rounded border border-line bg-surface px-[22px] text-base font-semibold hover:border-ink-400"
                onKeyDown={(e) => {
                  if (e.key === "Enter" || e.key === " ") (e.currentTarget.previousElementSibling as HTMLInputElement | null)?.click();
                }}
              >
                {uploading === r.id ? "กำลังอัปโหลด…" : "แนบสลิป"}
              </span>
            </label>
            {draft.slips.length ? <span className="text-sm text-ink-600">แนบแล้ว {draft.slips.length} ไฟล์</span> : null}
          </div>
        </Td>
        <Td align="center" className="p-[12px_14px]">
          <label className="flex flex-col items-center gap-1 text-sm text-ink-600">
            <Checkbox
              checked={isOn(r)}
              disabled={!check.canConfirm}
              onChange={(e) => setChecked((m) => ({ ...m, [r.id]: e.target.checked }))}
            />
            {check.canConfirm ? "เลือกยืนยัน" : "ยืนยันไม่ได้"}
          </label>
        </Td>
      </tr>
    );
  };

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center gap-3">
        <div className="text-base text-ink-600">
          รายการค้างรับ-ค้างจ่ายที่ยังรอเงินเข้า-ออกจริง <b className="text-ink-900">{rows.length} รายการ</b>
        </div>
        <Button variant="success" className="ml-auto" disabled={selected.length === 0} onClick={() => { setFailure(null); setReviewing(true); }}>
          ตรวจและยืนยัน {selected.length} รายการที่เลือก
        </Button>
      </div>

      {uploadError ? (
        <div role="alert" className="rounded border border-neg bg-neg-bg p-[12px_14px] text-base leading-7 text-neg-fg">
          อัปโหลดสลิปไม่สำเร็จ: {uploadError}
        </div>
      ) : null}

      <div className="overflow-hidden rounded-card border border-line bg-surface shadow-card">
        <div className="border-b border-line bg-canvas p-[16px_20px]">
          <div className="text-lg font-semibold">รอยืนยันเงินเข้า-ออกจริง</div>
          <div className="text-sm text-ink-600">
            รายการเหล่านี้ตั้งค้างรับ-ค้างจ่ายไว้ตอนบันทึก จึงยังไม่มีบัญชี — เลือกบัญชีที่เงินเข้า/ออกจริงก่อนยืนยัน
            ยืนยันแล้วรายการจะหายจากตารางนี้ (ถ้าล้างครบยอด)
          </div>
        </div>
        <div className="overflow-auto">
          <Table minWidth={1100}>
            <thead>
              <tr>
                <Th>รายการ</Th>
                <Th>วันที่เอกสาร</Th>
                <Th align="right">ยอดค้าง</Th>
                <Th align="right">ยอดที่ยืนยันครั้งนี้ (แก้ได้)</Th>
                <Th>วันที่จริง (วว/ดด/ปปปป)</Th>
                <Th>บัญชีที่เงินเข้า/ออกจริง</Th>
                <Th>สลิป</Th>
                <Th align="center">ยืนยัน</Th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? (
                <tr>
                  <Td colSpan={8} className="py-8 text-center text-ink-600">
                    ไม่มียอดค้างรับ-ค้างจ่ายที่รอยืนยัน
                  </Td>
                </tr>
              ) : null}
              {rows.map((r) => renderRow(r))}
            </tbody>
          </Table>
        </div>
      </div>

      <Dialog open={reviewing} onOpenChange={(v) => !v && !submitting && setReviewing(false)}>
        {reviewing ? (
          <DialogContent width="max-w-[760px]">
            <div className="flex max-h-[70vh] flex-col gap-4 overflow-auto p-6">
              <DialogPrimitive.Title className="text-h2 font-semibold">
                ยืนยันว่าเงินเข้า-ออกจริง {selected.length} รายการ
              </DialogPrimitive.Title>
              <DialogPrimitive.Description className="text-base leading-7 text-ink-600">
                การยืนยันคือการลงบัญชีจริง และทำให้งบกระแสเงินสดเปลี่ยน ลบไม่ได้ — ตรวจบรรทัดด้านล่างก่อนกดยืนยัน
              </DialogPrimitive.Description>
              {failure ? (
                <div role="alert" className="whitespace-pre-line rounded-card border border-neg bg-neg-bg p-[14px_18px] text-base leading-7 text-neg-fg">
                  <b>ยืนยันไม่สำเร็จ</b>
                  {"\n"}
                  {failure}
                </div>
              ) : null}
              {selected.map((r) => {
                const d = draftOf(r);
                return (
                  <div key={r.id} className="flex flex-col gap-2 rounded-card border border-line p-4">
                    <div className="font-semibold">{r.name}</div>
                    <div className="text-sm text-ink-600">
                      {r.sub} · {ref.banks.find((b) => b.id === (r.bankAccountId || d.bankAccountId))?.name ?? "ยังไม่ได้เลือกบัญชี"} · วันที่ {d.date}
                      {" · "}ยอด {money(Number.parseFloat(d.amount.replace(/,/g, "")) || 0)}
                    </div>
                    <ClearingPreview preview={checks.get(r.id)!.preview} />
                  </div>
                );
              })}
            </div>
            <DialogFooter className="border-t-0">
              <Button variant="secondary" disabled={submitting} onClick={() => setReviewing(false)}>
                ยกเลิก
              </Button>
              <Button variant="success" disabled={submitting} onClick={() => void confirm()}>
                {submitting ? "กำลังบันทึก…" : `ยืนยันเงินเข้า-ออกจริง ${selected.length} รายการ`}
              </Button>
            </DialogFooter>
          </DialogContent>
        ) : null}
      </Dialog>
    </div>
  );
}
