"use client";

import * as React from "react";
import { Table, Th, Td } from "@/components/ui/table";
import { Pill } from "@/components/ui/pill";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Checkbox } from "@/components/ui/checkbox";
import { Select } from "@/components/ui/select";
import { Field } from "@/components/ui/field";
import { Dialog, DialogContent, DialogFooter, DialogPrimitive } from "@/components/ui/dialog";
import { baht } from "@/lib/format";
import { CASH_GROUPS, UNASSIGNED_CASH_ROWS, type PendingCashRow } from "@/lib/mock/ledger";
import { MOCK_RESOLVER } from "@/lib/mock/resolver";
import { useApp, useOrderedBanks } from "@/lib/store";
import { bankChoices, bankDirectionLabel } from "@/components/form/bank-field";
import { findSub } from "@/lib/rules/tx-rules";
import { ClearingPreview } from "./clearing-preview";
import {
  accruedAmountText,
  checkRow,
  clearingChoicesOf,
  confirmRows,
  directionOf,
  historyOf,
  initialDraft,
  type PostedMap,
  type RowDraft,
} from "./confirm-flow";

/** ชื่อบัญชีสำหรับ "แสดง" เท่านั้น — สิ่งที่เก็บและส่งให้ engine คือรหัสบัญชี */
const bankLabel = (id: string | undefined): string => (id ? MOCK_RESOLVER.bankAccount(id)?.name ?? `บัญชี ${id}` : "ยังไม่ได้เลือกบัญชี");

const ALL_ROWS: PendingCashRow[] = [...UNASSIGNED_CASH_ROWS, ...CASH_GROUPS.flatMap((g) => g.rows)];

/**
 * ยืนยันรับ-จ่าย — ขั้นที่ทำให้งบกระแสเงินสดวิ่ง
 *
 * - พรีวิวบรรทัดบัญชี → `buildClearingDraft()` (ผ่าน `checkRow`)
 * - **ปุ่มยืนยัน → `buildClearing()` ตัวจริง** (ผ่าน `confirmRows`) ไม่ใช่ draft และไม่ใช่เงื่อนไขที่หน้าจอคิดเอง
 * - เหตุที่ยืนยันไม่ได้ = ข้อความ `PostingError` ของ engine ตรงๆ
 * - ประวัติการยืนยัน (`posted`) อยู่ที่ตัวแม่ — สลับแท็บแล้วไม่หาย ไม่งั้นกลับมากดยืนยันซ้ำได้
 *   ตอนต่อ Supabase ประวัตินี้ต้องมาจากรายการที่ post แล้วใน DB
 */
export function ConfirmTab({ posted, onPostedChange }: { posted: PostedMap; onPostedChange: (next: PostedMap) => void }) {
  const showToast = useApp((s) => s.showToast);
  const bankOff = useApp((s) => s.bankOff);
  const orderedBanks = useOrderedBanks(false);

  const [drafts, setDrafts] = React.useState<Record<string, RowDraft>>({});
  const [checked, setChecked] = React.useState<Record<string, boolean>>(() =>
    Object.fromEntries(ALL_ROWS.map((r) => [r.id, !!r.checked]))
  );
  const [reviewing, setReviewing] = React.useState(false);
  const [failure, setFailure] = React.useState<string | null>(null);

  // สำเนาล่าสุดแบบซิงก์ — กดรัวก่อนหน้าจอวาดใหม่ก็ยังเห็นประวัติที่เพิ่งบันทึก (ไม่งั้นกดสองทีได้สองรายการ)
  const postedRef = React.useRef(posted);
  postedRef.current = posted;

  const draftOf = (r: PendingCashRow): RowDraft => drafts[r.id] ?? initialDraft(r);
  const patch = (r: PendingCashRow, p: Partial<RowDraft>) =>
    setDrafts((m) => ({ ...m, [r.id]: { ...(m[r.id] ?? initialDraft(r)), ...p } }));

  const checks = new Map(ALL_ROWS.map((r) => [r.id, checkRow(r, draftOf(r), posted, MOCK_RESOLVER)]));
  // ติ๊กค้างไว้แต่ engine ไม่ให้ผ่านแล้ว (เช่น บัญชีหลุด) = ไม่นับว่าเลือก
  const isOn = (r: PendingCashRow) => !!checked[r.id] && !!checks.get(r.id)?.canConfirm;
  const selected = ALL_ROWS.filter(isOn);

  const openReview = () => {
    setFailure(null);
    setReviewing(true);
  };

  const confirm = () => {
    // ถาม `buildClearing()` ตัวจริงอีกรอบบนประวัติล่าสุด ไม่เชื่อผลที่คำนวณไว้ตอนวาดหน้า
    const outcome = confirmRows(selected, drafts, postedRef.current, MOCK_RESOLVER);
    if (!outcome.ok) {
      setFailure(outcome.failures.map((f) => `${f.row.name} — ${f.reason}`).join("\n") || "ไม่มีรายการที่เลือก");
      return;
    }
    postedRef.current = outcome.posted;
    onPostedChange(outcome.posted);
    const done = new Set(outcome.confirmed.map((c) => c.row.id));
    setChecked((m) => Object.fromEntries(Object.entries(m).map(([id, v]) => [id, done.has(id) ? false : v])));
    // ยืนยันครั้งถัดไปของแถวเดิมเป็นการยืนยันใหม่ — ต้องกรอกยอดและแนบสลิปใหม่ ไม่ใช้ของครั้งก่อนซ้ำ
    setDrafts((m) => ({
      ...m,
      ...Object.fromEntries(
        outcome.confirmed.map((c) => [c.row.id, { ...(m[c.row.id] ?? initialDraft(c.row)), amount: "", slips: [] }])
      ),
    }));
    setReviewing(false);
    showToast(`ยืนยันรับ-จ่าย ${outcome.confirmed.length} รายการแล้ว`);
  };

  const renderRow = (r: PendingCashRow, pickBank: boolean) => {
    const check = checks.get(r.id)!;
    const draft = draftOf(r);
    const dir = directionOf(r);
    const choices = clearingChoicesOf(r);
    const done = historyOf(r, posted)?.length ?? 0;
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
          {/* ทิศของยอดค้างคิดที่ `accruedAmountText` (switch ครบเคส) — ของเดิมเป็น
              ternary ที่ทำให้ "none" / "both" / null ตกทาง else แล้วแสดงเป็นยอดบวก */}
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
          <Input aria-label={`วันที่เงินเข้า-ออกจริง ${r.name}`} value={draft.date} onChange={(e) => patch(r, { date: e.target.value })} className="w-36" />
        </Td>
        {pickBank ? (
          <Td className="p-[12px_14px]">
            {/* ป้ายช่องบัญชีมาจากที่เดียวกับฟอร์มบันทึกรายการ — กฎเดียวกันห้ามเขียนสองที่
                (`dir` ตอบได้ครบทั้งสี่ค่าของ CashDirection แล้ว ไม่ใช่ in/out เท่านั้น) */}
            <Field label={bankDirectionLabel(findSub(r.subCode)?.sub)} required>
              <Select value={draft.bankAccountId} onChange={(e) => patch(r, { bankAccountId: e.target.value })}>
                <option value="">— เลือกบัญชี —</option>
                {bankChoices(orderedBanks, (id) => !!bankOff[id], r.ownerId).map((b) => (
                  <option key={b.id} value={b.id}>
                    {b.name}
                  </option>
                ))}
              </Select>
            </Field>
          </Td>
        ) : null}
        <Td className="p-[12px_14px]">
          <div className="flex flex-col items-start gap-1">
            {/* รอบนี้ยังไม่มีที่เก็บไฟล์จริง — จำลองการแนบเพื่อให้เห็นว่ากติกานิติบุคคลทำงานจริง */}
            <Button
              variant="secondary"
              onClick={() => patch(r, { slips: [...draft.slips, `สลิป-${r.id}-${draft.slips.length + 1}.pdf`] })}
            >
              แนบสลิป
            </Button>
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

  const head = (pickBank: boolean) => (
    <thead>
      <tr>
        <Th>รายการ</Th>
        <Th>ครบกำหนด</Th>
        <Th align="right">ยอดค้าง</Th>
        <Th align="right">ยอดที่ยืนยันครั้งนี้ (แก้ได้)</Th>
        <Th>วันที่จริง</Th>
        {pickBank ? <Th>บัญชีที่เงินเข้า/ออกจริง</Th> : null}
        <Th>สลิป</Th>
        <Th align="center">ยืนยัน</Th>
      </tr>
    </thead>
  );

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center gap-3">
        <div className="text-base text-ink-600">
          รายการที่ครบกำหนดรับ-จ่ายในเดือนนี้ <b className="text-ink-900">{ALL_ROWS.length} รายการ</b>
        </div>
        <Button variant="success" className="ml-auto" disabled={selected.length === 0} onClick={openReview}>
          ตรวจและยืนยัน {selected.length} รายการที่เลือก
        </Button>
      </div>

      <div className="overflow-hidden rounded-card border border-line bg-surface shadow-card">
        <div className="border-b border-line bg-canvas p-[16px_20px]">
          <div className="text-lg font-semibold">ยังไม่ระบุบัญชี ({UNASSIGNED_CASH_ROWS.length} รายการ)</div>
          <div className="text-sm text-ink-600">
            รายการเหล่านี้ตั้งค้างรับ-ค้างจ่ายไว้ตอนคีย์ จึงยังไม่มีบัญชี — เลือกบัญชีที่เงินเข้า/ออกจริงก่อนยืนยัน
          </div>
        </div>
        <div className="overflow-auto">
          <Table minWidth={1100}>
            {head(true)}
            <tbody>{UNASSIGNED_CASH_ROWS.map((r) => renderRow(r, true))}</tbody>
          </Table>
        </div>
      </div>

      {CASH_GROUPS.map((g) => (
        <div key={g.bankAccountId} className="overflow-hidden rounded-card border border-line bg-surface shadow-card">
          <div className="flex flex-wrap items-center gap-4 border-b border-line bg-canvas p-[16px_20px]">
            <div>
              <div className="text-lg font-semibold">{bankLabel(g.bankAccountId)}</div>
              <div className="text-sm text-ink-600">ยอดในระบบ {baht(g.system)}</div>
            </div>
            <label className="ml-auto flex flex-col gap-1">
              <span className="text-sm text-ink-600">ยอดตาม statement</span>
              <Input defaultValue={g.stmt} className="w-[220px] text-right font-semibold" />
            </label>
            <Pill size="md" className={g.matched ? "border-pos bg-pos-bg text-pos-fg" : "border-warn bg-warn-bg text-warn-fg"}>
              {g.matched ? "✓ " : "⚠ "}
              {g.match}
            </Pill>
          </div>
          <div className="overflow-auto">
            <Table minWidth={1000}>
              {head(false)}
              <tbody>{g.rows.map((r) => renderRow(r, false))}</tbody>
            </Table>
          </div>
        </div>
      ))}

      <Dialog open={reviewing} onOpenChange={(v) => !v && setReviewing(false)}>
        {reviewing ? (
          <DialogContent width="max-w-[760px]">
            <div className="flex max-h-[70vh] flex-col gap-4 overflow-auto p-6">
              <DialogPrimitive.Title className="text-h2 font-semibold">
                ยืนยันว่าเงินเข้า-ออกจริง {selected.length} รายการ
              </DialogPrimitive.Title>
              <DialogPrimitive.Description className="text-base leading-7 text-ink-600">
                การยืนยันคือการลงบัญชีจริง และทำให้งบกระแสเงินสดเปลี่ยน — ตรวจบรรทัดด้านล่างก่อนกดยืนยัน
              </DialogPrimitive.Description>
              {failure ? (
                <div role="alert" className="whitespace-pre-line rounded-card border border-neg bg-neg-bg p-[14px_18px] text-base leading-7 text-neg-fg">
                  <b>ยืนยันไม่ได้ — ยังไม่มีอะไรถูกบันทึก</b>
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
                      {r.sub} · {bankLabel(r.bankAccountId || d.bankAccountId)} · วันที่ {d.date}
                    </div>
                    <ClearingPreview preview={checks.get(r.id)!.preview} />
                  </div>
                );
              })}
            </div>
            <DialogFooter className="border-t-0">
              <Button variant="secondary" onClick={() => setReviewing(false)}>ยกเลิก</Button>
              <Button variant="success" onClick={confirm}>
                ยืนยันเงินเข้า-ออกจริง {selected.length} รายการ
              </Button>
            </DialogFooter>
          </DialogContent>
        ) : null}
      </Dialog>
    </div>
  );
}
