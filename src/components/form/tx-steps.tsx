"use client";

import * as React from "react";
import { TX_TYPES, impactLines, REQUIREMENT_LABEL, findSub, type TxTypeKey } from "@/lib/rules/tx-rules";
import { useReference, useReferenceState } from "@/components/reference/reference-provider";
import type { RefBank, RefOwner, Reference } from "@/lib/db/reference-types";
import { prepareImageForUpload, uploadAttachmentFromBrowser } from "@/lib/storage/browser";
import { Field } from "@/components/ui/field";
import { Input, AmountInput } from "@/components/ui/input";
import { Select } from "@/components/ui/select";
import { Checkbox } from "@/components/ui/checkbox";
import { Pill } from "@/components/ui/pill";
import { Button } from "@/components/ui/button";
import { TYPE_PILL } from "@/lib/tone";
import { cn } from "@/lib/utils";
import { ContactPicker } from "./contact-picker";
import { bankChoices, bankDirectionLabel, showsBankField } from "./bank-field";
import { LoanTermsDialog } from "./loan-terms-dialog";
import { DisposalPanel, RepaymentPanel } from "./disposal-panel";
import { FxPanel } from "./fx-panel";
import { JournalPreview } from "./journal-preview";
import { INTERCOMPANY_RULES } from "@/lib/rules/intercompany";
import { coa } from "@/lib/rules/coa";
import { hasRealEvidence } from "@/lib/storage/evidence";
import { isAttachmentRef, safeDisplayName } from "@/lib/storage/path";
import { dmyToIso, isoToDmy, money, parseAmount } from "@/lib/format";
import type { TxDraft, TxFormApi } from "./use-tx-form";

/** ผู้ถือที่เลือกเป็นเจ้าของรายการได้ — ยังเป็น 'planned' (นิติบุคคลที่ยังไม่จดทะเบียน) ไม่โชว์ */
const selectableHolders = (ref: Reference): RefOwner[] => ref.owners.filter((o) => o.status === "active");

/** ชื่อผู้ถือ — หาไม่เจอแสดงตามจริงว่าไม่รู้จัก ไม่เดา */
const ownerName = (ref: Reference, id: string): string => ref.owners.find((o) => o.id === id)?.name ?? "ผู้ถือที่ไม่รู้จัก";

/** บัญชีเรียงตามลำดับที่ตั้งไว้ใน Config (`sort_order`) */
const orderedBanks = (ref: Reference): RefBank[] => [...ref.banks].sort((a, b) => a.sortOrder - b.sortOrder);

/** ข้อความเมื่อโหลดข้อมูลอ้างอิงจากฐานข้อมูลไม่สำเร็จ — บอกตรงๆ ไม่ซ่อนด้วยข้อมูลจำลอง */
function ReferenceProblem() {
  const state = useReferenceState();
  if (state.ok) return null;
  return (
    <div role="alert" className="rounded border border-neg bg-neg-bg p-[14px_16px] text-base leading-7 text-neg-fg">
      โหลดรายชื่อผู้ถือ บัญชี ทรัพย์ และผู้ติดต่อจากฐานข้อมูลไม่สำเร็จ จึงยังบันทึกรายการไม่ได้: {state.error}
      <div className="mt-1 text-sm">ลองโหลดหน้านี้ใหม่ ถ้ายังไม่ได้ให้แจ้งผู้ดูแลระบบ</div>
    </div>
  );
}

/** ขั้น 1 — เลือกประเภทรายการ */
export function StepType({ api, onPicked, narrow }: { api: TxFormApi; onPicked?: () => void; narrow?: boolean }) {
  return (
    <div className={cn("grid gap-3", narrow ? "grid-cols-1" : "grid-cols-1 sm:grid-cols-2")}>
      {TX_TYPES.map((t) => {
        const active = api.draft.typeKey === t.key;
        return (
          <button
            key={t.key}
            type="button"
            onClick={() => {
              api.pickType(t.key as TxTypeKey);
              onPicked?.();
            }}
            className={cn(
              "flex min-h-[96px] flex-col gap-1 rounded border p-4 text-left hover:border-brand-600",
              active ? "border-brand-600 bg-brand-50" : "border-line bg-surface"
            )}
          >
            <span className="text-base font-semibold">{t.label}</span>
            <span className="text-sm leading-[22px] text-ink-600">{t.desc}</span>
          </button>
        );
      })}
    </div>
  );
}

/** ขั้น 2 — ผู้ถือกรรมสิทธิ์ (บัญชีธนาคารอยู่ขั้นรายละเอียด เพราะขึ้นกับว่าเงินเคลื่อนจริงหรือยัง) */
export function StepHolder({ api }: { api: TxFormApi }) {
  const ref = useReference();
  const holders = selectableHolders(ref);
  const picked = holders.find((h) => h.id === api.draft.holderId);
  const isCorp = picked?.policy === "corporate_strict";

  return (
    <div className="flex flex-col gap-4">
      <ReferenceProblem />
      <div>
        <div className="mb-1.5 text-sm text-ink-600">รายการนี้อยู่ในชื่อใคร (ผู้ถือกรรมสิทธิ์)</div>
        <div className="flex flex-wrap gap-2.5">
          {holders.map((e) => {
            const active = api.draft.holderId === e.id;
            return (
              <button
                key={e.id}
                type="button"
                onClick={() => api.pickHolder(e.id)}
                className={cn(
                  "flex min-h-control items-center gap-2 rounded border px-4 text-base",
                  active ? "border-brand-600 bg-brand-50" : "border-line bg-surface"
                )}
              >
                <span className="h-2.5 w-2.5 rounded-pill bg-holder-group" style={e.color ? { background: e.color } : undefined} />
                {e.name}
              </button>
            );
          })}
        </div>
      </div>

      <div className="rounded border border-brand-100 bg-brand-50 p-[14px_16px] text-base leading-7">
        {!picked
          ? "ต้องเลือกผู้ถือกรรมสิทธิ์เอง ระบบไม่เลือกให้ — รายการจะลงในงบของคนที่เลือกเท่านั้น"
          : isCorp
          ? "ถือในชื่อนิติบุคคล: ต้องแนบหลักฐาน (ใบเสร็จ/ใบแจ้งหนี้) และระบุคู่ค้าก่อนส่งอนุมัติ"
          : "ถือในชื่อบุคคล: เงินยังเป็นกองกลางของครอบครัว แนบหลักฐานภายหลังได้ แต่ต้องระบุคู่ค้าเพื่อการติดตาม"}
      </div>
    </div>
  );
}

/** ขั้น 3 — รายละเอียด (หมวดย่อยผูกกับประเภทตามตารางกฎ) */
export function StepDetail({ api, contactLayer = 1, narrow }: { api: TxFormApi; contactLayer?: number; narrow?: boolean }) {
  const { draft, sub, subs, requires, patch } = api;
  const ref = useReference();
  const allBanks = orderedBanks(ref);
  const bankOff = (id: string) => !ref.banks.find((b) => b.id === id)?.isActive;
  /**
   * หมวดนี้มีเงินเคลื่อนเลยไหม — ถามตารางกฎผ่าน `showsBankField()`
   *
   * `false` = รายการปรับปรุงทางบัญชี → **ไม่โชว์ทั้งช่องบัญชีและช่องติ๊กยืนยันเงินเข้า-ออก**
   * (ไม่ใช่โชว์แล้วปล่อยว่าง) เพราะทั้งสองช่องนั้นถามคำถามที่ไม่มีคำตอบสำหรับรายการนี้
   */
  const usesBank = showsBankField(sub);
  // เงินเคลื่อนจริงเมื่อติ๊กยืนยันแล้ว หรือหมวดนี้ตั้งค้างไม่ได้ (ต้องเป็นเงินสดเสมอ)
  const moneyMoved = usesBank && !(draft.notYetPaid && api.canAccrue);
  const banks = bankChoices(allBanks, bankOff, draft.holderId, draft.bankId);
  const needsContact = requires("contact");
  const needsAsset = requires("asset");
  // ขายทรัพย์: ยอดเงินมาจาก ราคาขาย − ค่าใช้จ่ายในการขาย ในแผงด้านล่าง ไม่ให้พิมพ์ทับ
  // แปลงค่า/แลกเงินตรา: ยอดบาทมาจากอัตราที่เลือกในแผงด้านล่าง ไม่ให้พิมพ์ทับ (engine ปฏิเสธยอดที่ไม่ตรงอัตราแม้สตางค์เดียว)
  const amountDerived = requires("capitalGain") || !!api.fxKind;

  return (
    <div className="flex flex-col gap-4">
      <Field
        label="จำนวนเงิน (บาท)"
        required
        hint={
          api.fxKind
            ? "ตั้งให้จากอัตราที่เลือกในแผงด้านล่าง"
            : amountDerived
              ? "คำนวณให้จาก ราคาขาย − ค่าใช้จ่ายในการขาย ในแผงคำนวณกำไร/ขาดทุน"
              : undefined
        }
      >
        <AmountInput
          value={draft.amount}
          onChange={(e) => patch({ amount: e.target.value })}
          placeholder="0.00"
          readOnly={amountDerived}
          className={amountDerived ? "bg-canvas text-ink-600" : undefined}
        />
      </Field>

      <div className={cn("grid gap-4", narrow ? "grid-cols-1" : "grid-cols-1 sm:grid-cols-2")}>
        <Field
          label="วันที่เอกสาร"
          hint="พิมพ์เป็น วว/ดด/ปปปป ปี ค.ศ. เช่น 24/10/2026"
          error={draft.docDate && !dmyToIso(draft.docDate) ? "อ่านเป็นวันที่ไม่ได้ — ต้องเป็น วว/ดด/ปปปป ปี ค.ศ." : undefined}
        >
          <Input value={draft.docDate} onChange={(e) => patch({ docDate: e.target.value })} inputMode="numeric" />
        </Field>
        {/*
          วันที่เงินเข้า-ออก **ไม่มีสำหรับรายการที่ไม่มีเงินเคลื่อน**
          `cash_date` ของรายการแบบนี้ต้องเป็น null (ด่าน trg_txn_cash_date_matches_lines
          ปฏิเสธถ้าไม่มีบรรทัด 11xx แต่มี cash_date) → ถ้ายังโชว์ช่องนี้ ผู้ใช้จะกรอก
          วันที่ที่ระบบจะทิ้งทันที ซึ่งทำให้คนอ่านงบคิดว่ามีเงินเคลื่อนวันนั้น
        */}
        {usesBank ? (
          <Field
            label={draft.notYetPaid && api.canAccrue ? "วันที่ครบกำหนด (ไม่บันทึกลงสมุด)" : "วันที่เงินเข้า/ออกจริง"}
            hint="พิมพ์เป็น วว/ดด/ปปปป ปี ค.ศ."
            error={api.moneyMoved && !dmyToIso(draft.cashDate) ? "อ่านเป็นวันที่ไม่ได้ — ต้องเป็น วว/ดด/ปปปป ปี ค.ศ." : undefined}
          >
            <Input value={draft.cashDate} onChange={(e) => patch({ cashDate: e.target.value })} inputMode="numeric" />
          </Field>
        ) : (
          <Field label="วันที่เงินเข้า/ออกจริง" hint="ไม่มี — รายการปรับปรุงทางบัญชีไม่มีเงินเคลื่อน">
            <div className="flex min-h-control items-center text-base text-ink-600">ไม่ใช้ช่องนี้</div>
          </Field>
        )}
      </div>

      {/*
        ตั้งต้นเป็น "ยังไม่ได้รับ-จ่าย" ติ๊กเพื่อยืนยันว่าเงินเคลื่อนจริง (ลูกพี่สั่ง 06/10)

        ทิศทางนี้สำคัญ: ค่าตั้งต้นที่ปลอดภัยคือยังไม่แตะเงินสด เพราะถ้าตั้งต้นว่ารับเงินแล้ว
        คนที่กดผ่านโดยไม่อ่านจะทำให้ยอดธนาคารมีเงินที่ยังไม่เข้า แล้วกระทบยอดไม่ได้
      */}
      {/*
        ช่องติ๊ก "เงินเข้า/ออกจริงแล้ว" กับช่องบัญชี เป็นเรื่องของรายการที่มีเงินเคลื่อน
        หมวด cash: "none" ไม่มีทั้งสองเรื่อง → แสดงคำอธิบายแทน ไม่ใช่ช่องเทาๆ ที่กดไม่ได้
        (ช่องเทาที่กดไม่ได้ทำให้คนคิดว่าตัวเองทำอะไรผิด)
      */}
      {!usesBank ? (
        <div className="rounded border border-line bg-canvas p-4 text-base text-ink-600">
          <div className="font-semibold text-ink-900">รายการนี้ไม่มีเงินเข้าหรือออกบัญชี</div>
          <div className="mt-1">
            ไม่ต้องเลือกบัญชีธนาคารและไม่ต้องระบุวันที่เงินเคลื่อน · ยอดธนาคารและงบกระแสเงินสดไม่ขยับ
          </div>
        </div>
      ) : null}

      {usesBank ? (
      <label className="flex min-h-control items-start gap-2.5 text-base">
        <Checkbox
          className="mt-0.5"
          checked={!draft.notYetPaid}
          disabled={!api.canAccrue}
          onChange={(e) => patch({ notYetPaid: !e.target.checked })}
        />
        <span className="leading-[26px]">
          ยืนยันว่าเงินเข้า/ออกจริงแล้ว
          {!api.canAccrue ? (
            <span className="block text-sm text-ink-400">
              หมวดนี้ตั้งค้างรับ-ค้างจ่ายไม่ได้ จึงต้องมีเงินเข้า/ออกจริงก่อนบันทึก
              {api.accrualWhy ? <span className="block">{api.accrualWhy}</span> : null}
            </span>
          ) : draft.notYetPaid && sub?.accrualCoa ? (
            <span className="block text-sm text-ink-600">
              ยังไม่ติ๊ก → ลงเป็น {coa(sub.accrualCoa).nameTh} ยอดธนาคารและกระแสเงินสดยังไม่ขยับ
            </span>
          ) : (
            <span className="block text-sm text-ink-600">
              ติ๊กแล้ว → ลงเงินเข้าบัญชีธนาคาร และกระแสเงินสดวิ่งทันที
            </span>
          )}
        </span>
      </label>
      ) : null}

      {/*
        บัญชีธนาคาร — จำเป็นเมื่อเงินเคลื่อนจริง (ติ๊กแล้ว) · ไม่จำเป็นเมื่อยังค้างรับ-ค้างจ่าย
        **ไม่แสดงเลย** เมื่อหมวดนี้ไม่มีเงินเคลื่อน (engine ปฏิเสธถ้าส่งบัญชีมา)
        ไม่เลือกให้เอง: บัญชีที่ระบบเดาให้ = ยอดธนาคารที่กระทบยอดไม่ได้ทันทีที่เดาผิด
        ว่าพอไหม engine เป็นคนตัดสินตอนกดบันทึก (ปุ่มไม่ได้ถามช่องนี้)
      */}
      {usesBank ? (
      <Field
        label={bankDirectionLabel(sub)}
        required={moneyMoved}
        hint={
          moneyMoved
            ? "เห็นเฉพาะบัญชีของผู้ถือที่เลือก ที่ยังเปิดใช้งาน · ต้องระบุ เพราะเงินเคลื่อนจริงแล้ว"
            : "ยังไม่ต้องเลือก — ค้างรับ-ค้างจ่ายยังไม่มีขาเงินสด · จะต้องระบุบัญชีตอนยืนยันว่าเงินเข้า/ออกจริง"
        }
        error={banks.length === 0 ? "ผู้ถือรายนี้ยังไม่มีบัญชีที่เปิดใช้งาน" : undefined}
      >
        <Select value={draft.bankId} onChange={(e) => api.pickBank(e.target.value)} disabled={banks.length === 0}>
          <option value="">{moneyMoved ? "— เลือกบัญชี —" : "— ยังไม่ระบุ —"}</option>
          {banks.map((b) => (
            <option key={b.id} value={b.id}>
              {b.name}
              {b.currency !== "THB" ? ` · บัญชีสกุล ${b.currency}` : ""}
              {bankOff(b.id) ? " (ปิดใช้งานแล้ว)" : ""}
            </option>
          ))}
        </Select>
      </Field>
      ) : null}

      {/* Backlog ข้อ 1 — หมวดย่อยมาจากตารางกฎของประเภทที่เลือก ไม่ใช่ dropdown อิสระ */}
      <Field
        label="หมวดย่อย"
        required
        hint={draft.typeKey ? `เลือกได้เฉพาะหมวดที่อยู่ใต้ประเภท “${TX_TYPES.find((t) => t.key === draft.typeKey)?.label}” เท่านั้น` : "เลือกประเภทรายการก่อน"}
      >
        <Select value={draft.subCode} onChange={(e) => api.pickSub(e.target.value)} disabled={!draft.typeKey}>
          {subs.map((s) => (
            <option key={s.code} value={s.code}>
              {s.label}
              {s.en ? ` · ${s.en}` : ""}
            </option>
          ))}
        </Select>
      </Field>

      <div className={cn("grid gap-4", narrow ? "grid-cols-1" : "grid-cols-1 sm:grid-cols-2")}>
        <ContactPicker
          value={draft.contactId}
          onSelect={(id) => patch({ contactId: id })}
          label={needsContact ? "ผู้ติดต่อ (คู่ค้า / ผู้เช่า / ผู้ให้กู้)" : "ผู้ติดต่อ"}
          required={needsContact}
          hint={!needsContact ? "ไม่บังคับสำหรับหมวดนี้" : undefined}
          layer={contactLayer}
        />

        <Field
          label="โปรเจค (ทรัพย์)"
          required={needsAsset}
          error={needsAsset && !draft.assetId ? "หมวดย่อยนี้ต้องระบุโปรเจค (ทรัพย์)" : undefined}
          hint={!needsAsset ? "ไม่บังคับสำหรับหมวดนี้" : undefined}
        >
          <Select value={draft.assetId} onChange={(e) => patch({ assetId: e.target.value })}>
            <option value="">— ไม่ระบุโปรเจค —</option>
            {ref.assets
              .filter((a) => a.status === "active" || a.id === draft.assetId)
              .map((a) => (
                <option key={a.id} value={a.id}>
                  {a.name} · {a.code}
                </option>
              ))}
          </Select>
        </Field>
      </div>

      {/* ลดลูกหนี้/เจ้าหนี้ → บอกว่าชำระของใบไหน (เลือกเฉพาะเมื่อมีของค้างหลายใบ) */}
      {api.clearSources.key ? <ClearSourceSection api={api} /> : null}

      {/* ผู้จ่ายหักภาษี ณ ที่จ่าย — โชว์เฉพาะหมวดที่ตารางกฎยอมให้หักได้ และเงินเคลื่อนจริง */}
      {api.whtEligible ? <WhtSection api={api} /> : null}

      {/* โอนระหว่างบัญชี — ต้องมีปลายทาง และถ้าข้ามผู้ถือต้องบอกว่าเป็นอะไร */}
      {requires("transferTarget") ? <TransferSection api={api} narrow={narrow} /> : null}

      {/* แปลงค่า / แลกเงินตรา — เลือกอัตราจากตาราง · ยอดคงเหลือและผลต่างที่ค้างอ่านจากสมุด */}
      {api.fxKind ? <FxPanel api={api} /> : null}

      {/* Backlog ข้อ 2 — เงื่อนไขสัญญากู้/ให้กู้ */}
      {requires("loanTerms") ? (
        <LoanTermsSection api={api} contactLayer={contactLayer} />
      ) : null}

      {/* Backlog ข้อ 4 — กำไร/ขาดทุนจากการขาย */}
      {requires("capitalGain") ? (
        <DisposalPanel
          value={draft.disposal}
          onChange={(v) => patch({ disposal: v })}
          result={api.disposal}
          input={api.postingInput}
          onDerivedAmount={api.setDerivedAmount}
        />
      ) : null}

      {/* Backlog ข้อ 5 — แยกเงินต้น/ดอกเบี้ย */}
      {requires("principalInterestSplit") ? (
        <RepaymentPanel
          value={draft.repayment}
          onChange={(v) => patch({ repayment: v })}
          installment={draft.loanTerms.schedule[0]}
          paid={parseAmount(draft.amount)}
          split={api.repayment.split}
          error={api.repayment.error}
          input={api.postingInput}
        />
      ) : null}

      <Field label="หมายเหตุ" hint="ไม่จำเป็นต้องกรอก">
        <Input value={draft.note} onChange={(e) => patch({ note: e.target.value })} placeholder="ไม่จำเป็นต้องกรอก" />
      </Field>

      {/* สรุปว่าจะลงบัญชีอย่างไร อยู่ล่างสุดเสมอ — อ่านหลังกรอกครบ ไม่ใช่คั่นกลางฟอร์ม */}
      {sub ? <ImpactPreview subCode={sub.code} accrued={draft.notYetPaid} /> : null}
    </div>
  );
}

/**
 * ชำระของค้างใบไหน — โชว์เมื่อรายการนี้ลดลูกหนี้/เจ้าหนี้ (ตัดสินจากบรรทัดที่ engine สร้าง)
 *   - ค้างหลายใบ: ต้องเลือก (DB ปฏิเสธถ้าไม่ระบุ — ไม่งั้นใบหนึ่งติดลบโดยอีกใบคลุมยอดรวมไว้)
 *   - ค้างใบเดียว: ไม่ต้องเลือก ระบบผูกให้เอง (บอกให้เห็นว่าผูกกับใบไหน)
 * ยอดค้างคงเหลืออ่านจาก DB ทุกครั้ง ไม่คำนวณในหน้าจอ
 */
function ClearSourceSection({ api }: { api: TxFormApi }) {
  const { draft, patch, clearSources: cs } = api;
  const ref = useReference();
  const describe = (i: (typeof cs.items)[number]) =>
    [
      findSub(i.subCode)?.sub.label ?? i.subCode,
      i.assetId ? ref.assets.find((a) => a.id === i.assetId)?.name : undefined,
      `วันที่ ${isoToDmy(i.docDate)}`,
      `ค้าง ${money(i.outstanding)} บาท`,
    ]
      .filter(Boolean)
      .join(" · ");

  if (cs.loading) return <div role="status" className="rounded border border-line bg-canvas p-4 text-base text-ink-600">กำลังดูรายการค้างของผู้ถือรายนี้…</div>;
  if (cs.error) {
    return (
      <div role="alert" className="rounded border border-warn bg-warn-bg p-4 text-base leading-7 text-warn-fg">
        โหลดรายการค้างไม่สำเร็จ ({cs.error}) — ถ้ามีของค้างหลายใบ ระบบจะไม่ยอมบันทึกจนกว่าจะเลือกใบที่ชำระ ให้โหลดหน้าใหม่แล้วลองอีกครั้ง
      </div>
    );
  }
  if (cs.items.length === 0) {
    return (
      <div role="alert" className="rounded border border-neg bg-neg-bg p-4 text-base leading-7 text-neg-fg">
        รายการนี้ลดลูกหนี้/เจ้าหนี้ แต่ผู้ถือรายนี้ไม่มีของค้างเหลืออยู่เลย จึงบันทึกไม่ได้ —
        ถ้ารับเงินที่ยังไม่เคยตั้งค้างไว้ ให้ลงเป็นรายได้ตรงๆ แทน
      </div>
    );
  }
  if (cs.items.length === 1) {
    return (
      <div className="rounded border border-brand-100 bg-brand-50 p-4 text-base leading-7">
        <b>ชำระของรายการนี้:</b> {describe(cs.items[0])}
        <div className="text-sm text-ink-600">มีของค้างใบเดียว ระบบเลือกให้เอง ไม่ต้องทำอะไรเพิ่ม</div>
      </div>
    );
  }
  return (
    <Field
      label="ชำระของรายการไหน"
      required
      error={!draft.clearsSourceId ? `มีของค้าง ${cs.items.length} ใบ ต้องเลือกว่าชำระใบไหน` : undefined}
      hint="ยอดค้างที่เห็นคือยอดคงเหลือจริงจากสมุดบัญชี"
    >
      <Select value={draft.clearsSourceId} onChange={(e) => patch({ clearsSourceId: e.target.value })}>
        <option value="">— เลือกใบค้างที่ชำระ —</option>
        {cs.items.map((i) => (
          <option key={i.id} value={i.id}>
            {describe(i)}
          </option>
        ))}
      </Select>
    </Field>
  );
}

/**
 * ผู้จ่ายหักภาษี ณ ที่จ่ายไว้ (เช่น ผู้เช่าที่เป็นนิติบุคคลหัก 5% ของค่าเช่า)
 *
 * จำนวนเงินด้านบนต้องเป็น **ยอดเต็มก่อนหักภาษี** (เช่น 100,000) ไม่ใช่ยอดที่เข้าบัญชี (95,000) —
 * ระบบแยกให้เองเป็น เงินเข้าบัญชีสุทธิ + ภาษีรอเครดิต · รายได้ต้องรับรู้เต็มจำนวน
 */
function WhtSection({ api }: { api: TxFormApi }) {
  const { draft, patch } = api;
  const w = draft.wht;
  const set = (p: Partial<typeof w>) => patch({ wht: { ...w, ...p } });
  return (
    <div className="flex flex-col gap-3 rounded-card border border-line bg-canvas p-4">
      <label className="flex min-h-control items-start gap-2.5 text-base">
        <Checkbox className="mt-0.5" checked={w.on} onChange={(e) => set({ on: e.target.checked })} />
        <span className="leading-[26px]">
          ผู้จ่ายหักภาษี ณ ที่จ่ายไว้
          <span className="block text-sm text-ink-600">
            ติ๊กเมื่อเงินที่เข้าบัญชีน้อยกว่ายอดเต็มเพราะถูกหักภาษี · ช่อง “จำนวนเงิน” ด้านบนต้องกรอกเป็น <b>ยอดเต็มก่อนหักภาษี</b>
          </span>
        </span>
      </label>
      {w.on ? (
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <Field label="อัตราที่ถูกหัก (%)" required hint="เช่น 5">
            <Input value={w.rate} onChange={(e) => set({ rate: e.target.value })} inputMode="decimal" />
          </Field>
          <Field label="ยอดภาษีที่ถูกหัก (บาท)" required hint="ตามใบรับรองการหักภาษี">
            <AmountInput value={w.amount} onChange={(e) => set({ amount: e.target.value })} placeholder="0.00" />
          </Field>
          <Field label="เลขที่ใบรับรอง" hint="นิติบุคคลต้องมี">
            <Input value={w.certificateNo} onChange={(e) => set({ certificateNo: e.target.value })} />
          </Field>
        </div>
      ) : null}
    </div>
  );
}

/**
 * ปลายทางของการโอน และลักษณะของรายการเมื่อข้ามผู้ถือ
 *
 * ผู้ถือปลายทาง**อ่านจากบัญชีที่เลือก** ไม่ให้กรอกเอง — ถ้าให้กรอก ผู้ใช้เว้นได้
 * แล้วรายการข้ามผู้ถือจะถูกลงเป็นการย้ายกระเป๋าธรรมดา เงินของอีกฝ่ายจะไปโผล่ในงบฝ่ายแรก
 */
function TransferSection({ api, narrow }: { api: TxFormApi; narrow?: boolean }) {
  const { draft, patch, pickTransferTo, transferToOwnerId, isCrossOwner } = api;
  const ref = useReference();
  const banks = orderedBanks(ref).filter((b) => b.isActive && b.id !== draft.bankId);
  const toOwner = transferToOwnerId ? ref.owners.find((o) => o.id === transferToOwnerId) ?? null : null;

  return (
    <div className="flex flex-col gap-4 rounded-card border border-line bg-canvas p-4">
      <div className="text-base font-semibold">ปลายทางของการโอน</div>

      <div className={cn("grid gap-4", narrow ? "grid-cols-1" : "grid-cols-1 sm:grid-cols-2")}>
        <Field
          label="โอนเข้าบัญชี"
          required
          error={!draft.transferToBankId ? "ต้องระบุบัญชีปลายทาง" : undefined}
          hint="เลือกบัญชีของคนอื่นได้ ระบบจะรู้เองว่าเป็นรายการข้ามผู้ถือ"
        >
          <Select value={draft.transferToBankId} onChange={(e) => pickTransferTo(e.target.value)}>
            <option value="">— เลือกบัญชีปลายทาง —</option>
            {banks.map((b) => (
              <option key={b.id} value={b.id}>
                {b.name} · {ownerName(ref, b.ownerId)}
              </option>
            ))}
          </Select>
        </Field>

        {isCrossOwner ? (
          <Field
            label="ลักษณะของรายการ"
            required
            error={!draft.intercompanyNature ? "ข้ามผู้ถือต้องระบุลักษณะ" : undefined}
            hint="ตัวนี้เป็นตัวกำหนดคู่บัญชีของทั้งสองฝ่าย"
          >
            <Select
              value={draft.intercompanyNature}
              onChange={(e) => patch({ intercompanyNature: e.target.value as TxDraft["intercompanyNature"] })}
            >
              <option value="">— เลือกลักษณะ —</option>
              {(Object.keys(INTERCOMPANY_RULES) as (keyof typeof INTERCOMPANY_RULES)[]).map((k) => (
                <option key={k} value={k}>
                  {INTERCOMPANY_RULES[k].label}
                </option>
              ))}
            </Select>
          </Field>
        ) : null}
      </div>

      {isCrossOwner ? (
        <div className="rounded border border-warn bg-warn-bg p-[12px_14px] text-sm leading-6 text-warn-fg">
          ข้ามผู้ถือ — เงินออกจากชื่อ <b>{ownerName(ref, draft.holderId)}</b> ไปเข้าชื่อ <b>{toOwner?.name ?? "ผู้ถือที่ไม่รู้จัก"}</b>{" "}
          ระบบจะสร้าง<b>สองรายการคู่กัน</b> ฝ่ายละหนึ่ง เพราะหนึ่งรายการมีผู้ถือได้คนเดียว
          {draft.intercompanyNature ? (
            <div className="mt-1 text-ink-600">{INTERCOMPANY_RULES[draft.intercompanyNature].note}</div>
          ) : null}
        </div>
      ) : draft.transferToBankId ? (
        <div className="rounded border border-brand-100 bg-brand-50 p-[12px_14px] text-sm leading-6">
          ย้ายกระเป๋าภายในชื่อเดียวกัน — ยอดรวมกองกลางไม่เปลี่ยน ไม่เข้างบกำไรขาดทุนและไม่นับในงบกระแสเงินสด
        </div>
      ) : null}
    </div>
  );
}

/**
 * ปุ่มเปิดฟอร์มเงื่อนไขสัญญา + สรุปตารางงวดที่สร้างแล้ว
 * แยกออกมาเพราะต้องมี state ของ dialog เป็นของตัวเอง
 */
function LoanTermsSection({ api, contactLayer }: { api: TxFormApi; contactLayer: number }) {
  const [open, setOpen] = React.useState(false);
  const { draft, patch } = api;
  const terms = draft.loanTerms;
  const done = terms.schedule.length > 0;

  // ฝั่งไหน: กู้เข้า (finance_in) = เรายืมเขา · ปล่อยกู้ (invest_buy) = เราให้ยืม
  const direction = draft.typeKey === "finance_in" ? "borrow" : "lend";

  const totalInterest = terms.schedule.reduce((t, r) => t + r.interest, 0);

  return (
    <div className={cn("flex flex-col gap-3 rounded-card border p-4", done ? "border-line bg-canvas" : "border-warn bg-warn-bg")}>
      <div className="flex flex-wrap items-center gap-3">
        <div className="text-base font-semibold">เงื่อนไขสัญญา</div>
        {done ? (
          <Pill className="border-pos bg-pos-bg text-pos-fg">สร้างตารางงวดแล้ว {terms.schedule.length} งวด</Pill>
        ) : (
          <Pill className="border-warn bg-surface text-warn-fg">ยังไม่ได้กรอก</Pill>
        )}
        <Button type="button" variant={done ? "secondary" : "primary"} size="sm" className="ml-auto" onClick={() => setOpen(true)}>
          {done ? "แก้ไขเงื่อนไข" : "กรอกเงื่อนไขสัญญา"}
        </Button>
      </div>

      {done ? (
        <div className="text-sm leading-6 text-ink-600">
          วงเงิน {terms.principal} · ดอกเบี้ย {terms.rate}% ต่อ{terms.ratePeriod === "month" ? "เดือน" : "ปี"} ·{" "}
          {terms.schedule.length} งวด · งวดแรก {terms.schedule[0].dueDate} · งวดสุดท้าย{" "}
          {terms.schedule[terms.schedule.length - 1].dueDate}
          <br />
          ดอกเบี้ยรวมตลอดสัญญา <b className="text-ink-900">{money(totalInterest)}</b>
        </div>
      ) : (
        <div className="text-sm leading-6 text-warn-fg">
          หมวดย่อยนี้เป็นสัญญากู้ — ต้องกรอกเงื่อนไข (ยืมจากใคร วงเงิน กำหนดคืน ดอกเบี้ย)
          เพื่อให้ระบบสร้างตารางงวดชำระ แล้วหน้ายืนยันรับ-จ่ายจะดึงไปใช้ได้เอง
        </div>
      )}

      <LoanTermsDialog
        open={open}
        onOpenChange={setOpen}
        value={terms}
        onSave={(v) => patch({ loanTerms: v })}
        direction={direction}
        layer={contactLayer}
      />
    </div>
  );
}

/**
 * แสดงว่าระบบจะลงบัญชีให้อย่างไร ก่อนกดยืนยัน
 *
 * `accrued` = ยังไม่ติ๊กยืนยันรับ-จ่าย · ข้อความ `plain` กับ `impactLines()` ในตารางกฎ
 * เขียนไว้สำหรับเส้นทางเงินสด จึงต้องบอกให้ชัดว่าสองบรรทัดเรื่องเงินยังไม่เกิดขึ้นตอนนี้
 * ไม่งั้นผู้ใช้จะอ่านว่า "เงินเข้าบัญชีเพิ่มขึ้น" ทั้งที่ธนาคารยังไม่ขยับ
 */
export function ImpactPreview({ subCode, accrued }: { subCode: string; accrued?: boolean }) {
  const found = React.useMemo(() => TX_TYPES.flatMap((t) => t.subs).find((s) => s.code === subCode), [subCode]);
  if (!found) return null;

  return (
    <div className="flex flex-col gap-2 rounded-card border border-line bg-canvas p-4">
      <div className="text-base font-semibold">ระบบจะบันทึกให้ดังนี้</div>
      {accrued && found.accrualCoa ? (
        <div className="rounded border border-warn bg-warn-bg p-[10px_12px] text-sm leading-6 text-warn-fg">
          ยังไม่ได้ติ๊กยืนยันรับ-จ่าย → รายการนี้ลงเป็น <b>{coa(found.accrualCoa).nameTh}</b> แทนเงินสด
          <span className="block">สองบรรทัดล่างที่พูดถึงเงินสดและกระแสเงินสด <b>ยังไม่เกิดขึ้นตอนนี้</b></span>
        </div>
      ) : null}
      <div className="text-base leading-7 text-ink-600">{found.plain}</div>
      <ul className="m-0 flex list-none flex-col gap-1 p-0 text-sm text-ink-600">
        {impactLines(found).map((l) => (
          <li key={l} className="flex gap-2">
            <span className="text-ink-400">·</span>
            {l}
          </li>
        ))}
      </ul>
      {found.caution ? (
        <div className="rounded border border-warn bg-warn-bg p-[10px_12px] text-sm leading-6 text-warn-fg">⚠ {found.caution}</div>
      ) : null}
      {found.requires?.length ? (
        <div className="flex flex-wrap gap-2 pt-1">
          {found.requires.map((r) => (
            <Pill key={r} className="border-brand-100 bg-brand-50 text-brand-600">
              {REQUIREMENT_LABEL[r]}
            </Pill>
          ))}
        </div>
      ) : null}
    </div>
  );
}

/** ขั้น 4 — แนบไฟล์ & ยืนยัน */
export function StepConfirm({ api }: { api: TxFormApi }) {
  const { draft, sub, missing, patch } = api;
  const ref = useReference();
  const bank = ref.banks.find((b) => b.id === draft.bankId);
  const holder = ref.owners.find((h) => h.id === draft.holderId);
  const asset = ref.assets.find((a) => a.id === draft.assetId);
  const typeLabel = TX_TYPES.find((t) => t.key === draft.typeKey);
  const isCorp = holder?.policy === "corporate_strict";

  const summary = [
    { k: "ประเภท", v: typeLabel ? `${typeLabel.label} · ${sub?.label ?? "—"}` : "—" },
    { k: "ถือในชื่อ", v: holder?.name ?? "—" },
    {
      k: bankDirectionLabel(sub),
      // หมวดที่ไม่มีเงินเคลื่อนต้องอ่านว่า "ไม่ใช้" ไม่ใช่ "ยังไม่ได้เลือก" ซึ่งอ่านเหมือนกรอกไม่ครบ
      v: !showsBankField(sub)
        ? "ไม่ใช้ — รายการนี้ไม่มีเงินเข้าออกบัญชี"
        : bank?.name ?? (draft.notYetPaid && api.canAccrue ? "ยังไม่ระบุ (ค้างรับ-ค้างจ่าย)" : "ยังไม่ได้เลือก"),
    },
    { k: "จำนวนเงิน", v: draft.amount ? `฿ ${draft.amount}` : "—" },
    {
      k: "วันที่เอกสาร / เงินจริง",
      v: !showsBankField(sub)
        ? `${draft.docDate} · ไม่มีวันที่เงินเคลื่อน`
        : `${draft.docDate} · ${draft.notYetPaid && api.canAccrue ? "ยังไม่ได้รับ-จ่าย" : draft.cashDate}`,
    },
    { k: "โปรเจค (ทรัพย์)", v: asset?.name ?? "—" },
  ];

  // ---- อัปโหลดไฟล์หลักฐานขึ้น Storage จริง (D-095 · D-104) ----
  // ได้ path กลับมาเก็บใน draft.attachments · ล้มเหลว = บอกเหตุผลตรงๆ ไม่สร้างไฟล์จำลองให้ผ่านด่าน
  const [uploading, setUploading] = React.useState(false);
  const [uploadError, setUploadError] = React.useState<string | null>(null);
  const pickRef = React.useRef<HTMLInputElement>(null);
  const cameraRef = React.useRef<HTMLInputElement>(null);

  async function onFiles(files: FileList | null) {
    if (!files || files.length === 0) return;
    if (!draft.holderId) {
      setUploadError("เลือกผู้ถือกรรมสิทธิ์ก่อน — ไฟล์หลักฐานเก็บแยกตามผู้ถือ");
      return;
    }
    setUploading(true);
    setUploadError(null);
    const added: string[] = [];
    try {
      for (const file of Array.from(files)) {
        const prepared = await prepareImageForUpload(file);
        if (!prepared.ok) {
          setUploadError(`${safeDisplayName(file.name)}: ${prepared.message}`);
          continue;
        }
        const up = await uploadAttachmentFromBrowser(prepared.file, draft.holderId);
        if (!up.ok) {
          setUploadError(`${safeDisplayName(file.name)}: ${up.message}`);
          continue;
        }
        added.push(up.ref);
      }
    } finally {
      setUploading(false);
      if (pickRef.current) pickRef.current.value = "";
      if (cameraRef.current) cameraRef.current.value = "";
    }
    if (added.length) patch({ attachments: [...draft.attachments, ...added] });
  }

  const removeFile = (i: number) => patch({ attachments: draft.attachments.filter((_, n) => n !== i) });

  return (
    <div className="flex flex-col gap-4">
      <ReferenceProblem />

      <div className="rounded-card border-2 border-dashed border-line bg-canvas p-6 text-center">
        <div className="text-base font-semibold">แนบไฟล์หลักฐาน</div>
        <div className="m-[4px_0_12px] text-sm text-ink-600">สลิปโอนเงิน · ใบเสร็จ · ใบแจ้งหนี้ (PDF/JPG/PNG) · ไฟล์ละไม่เกิน 4 MB</div>
        <input
          ref={pickRef}
          type="file"
          accept="image/jpeg,image/png,image/webp,image/heic,application/pdf"
          multiple
          hidden
          onChange={(e) => void onFiles(e.target.files)}
        />
        <input
          ref={cameraRef}
          type="file"
          accept="image/*"
          capture="environment"
          hidden
          onChange={(e) => void onFiles(e.target.files)}
        />
        <div className="flex flex-wrap justify-center gap-2.5">
          <button
            type="button"
            disabled={uploading}
            onClick={() => pickRef.current?.click()}
            className="min-h-control rounded border border-line bg-surface px-[18px] text-base font-semibold disabled:opacity-60"
          >
            เลือกไฟล์
          </button>
          <button
            type="button"
            disabled={uploading}
            onClick={() => cameraRef.current?.click()}
            className="min-h-control rounded border border-line bg-surface px-[18px] text-base font-semibold disabled:opacity-60"
          >
            ถ่ายรูป
          </button>
        </div>
        {uploading ? <div role="status" className="mt-3 text-base text-ink-600">กำลังอัปโหลดไฟล์… อย่าปิดหน้านี้</div> : null}
        {uploadError ? (
          <div role="alert" className="mt-3 rounded border border-neg bg-neg-bg p-[10px_12px] text-sm leading-6 text-neg-fg">
            อัปโหลดไม่สำเร็จ: {uploadError}
          </div>
        ) : null}
        {draft.attachments.length ? (
          <div className="mt-3 flex flex-wrap justify-center gap-2">
            {draft.attachments.map((f, i) => (
              <button
                key={f}
                type="button"
                onClick={() => removeFile(i)}
                className="flex min-h-control items-center gap-2 rounded border border-line bg-surface px-3 text-sm"
              >
                📎 {isAttachmentRef(f) ? `ไฟล์หลักฐาน ${i + 1}` : safeDisplayName(f)}{" "}
                <span className="text-ink-400">เอาออกจากรายการนี้</span>
              </button>
            ))}
          </div>
        ) : null}
        {/* ถามกฎชุดเดียวกับ engine (hasRealEvidence) ไม่ใช่นับความยาวอาร์เรย์ */}
        {isCorp && !hasRealEvidence(draft.attachments, { ownerId: draft.holderId }) ? (
          <div className="mt-3 text-sm leading-6 text-warn-fg">
            {holder?.name} เป็นนิติบุคคล — ต้องมี <b>ไฟล์ที่อัปโหลดขึ้นระบบจริง</b> อย่างน้อยหนึ่งไฟล์ก่อนบันทึก
          </div>
        ) : null}
      </div>

      {sub ? <ImpactPreview subCode={sub.code} /> : null}

      <div className="rounded-card border border-line bg-canvas p-4">
        <div className="mb-2 text-base font-semibold">สรุปรายการ</div>
        {summary.map((s) => (
          <div key={s.k} className="flex justify-between gap-3 border-t border-line py-2 text-base">
            <span className="text-ink-600">{s.k}</span>
            <span className="text-right font-semibold">{s.v}</span>
          </div>
        ))}
      </div>

      {/* บรรทัดบัญชีที่จะถูกบันทึกจริง — มาจาก engine ตัวเดียวกับที่ post */}
      <JournalPreview input={api.postingInput} showSummary />

      {missing.length ? (
        <div className="rounded border border-neg bg-neg-bg p-[14px_16px] text-base leading-7 text-neg-fg">
          ยังกรอกไม่ครบตามกฎของหมวดย่อยนี้: {missing.join(" · ")}
        </div>
      ) : null}

      {/* เหตุที่ระบบจะไม่รับ ถึงกรอกครบแล้วก็ตาม — เช่น นิติบุคคลยังไม่แนบหลักฐาน */}
      {api.postingError ? (
        <div className="rounded border border-neg bg-neg-bg p-[14px_16px] text-base leading-7 text-neg-fg">
          ยังบันทึกไม่ได้: {api.postingError}
        </div>
      ) : null}

      {/* หมวดที่เส้นทางบันทึกจริงยังต่อไม่ครบ — บอกก่อนกด ไม่ใช่ให้กดแล้วเจอ error */}
      {api.notWired ? (
        <div className="rounded border border-warn bg-warn-bg p-[14px_16px] text-base leading-7 text-warn-fg">
          ยังบันทึกไม่ได้: {api.notWired}
        </div>
      ) : null}

      {!api.canPost ? (
        <div className="rounded border border-warn bg-warn-bg p-[14px_16px] text-base leading-7 text-warn-fg">
          บัญชีของคุณลงสมุดบัญชีโดยตรงไม่ได้ (ต้องมีสิทธิ์อนุมัติเข้าสมุด) — การส่งร่างให้ผู้อนุมัติยังไม่ได้ต่อกับฐานข้อมูล
          จึงยังบันทึกจากหน้านี้ไม่ได้
        </div>
      ) : (
        <div className="rounded border border-brand-100 bg-brand-50 p-[14px_16px] text-base leading-7">
          กด “บันทึกเข้าสมุดบัญชี” แล้วรายการจะถูกลงสมุดทันที — ลบไม่ได้ แก้ได้ด้วยการกลับรายการเท่านั้น
        </div>
      )}
    </div>
  );
}

export function TypePill({ tone, children }: { tone: string; children: React.ReactNode }) {
  return <Pill className={TYPE_PILL[tone] ?? TYPE_PILL.trf}>{children}</Pill>;
}
