"use client";

import * as React from "react";
import { TX_TYPES, impactLines, REQUIREMENT_LABEL, type TxTypeKey } from "@/lib/rules/tx-rules";
import { HOLDERS, entityById } from "@/lib/mock/entities";
import { ASSETS } from "@/lib/mock/assets";
import { useOrderedBanks } from "@/lib/store";
import { Field } from "@/components/ui/field";
import { Input, AmountInput } from "@/components/ui/input";
import { Select } from "@/components/ui/select";
import { Checkbox } from "@/components/ui/checkbox";
import { Pill } from "@/components/ui/pill";
import { Button } from "@/components/ui/button";
import { TYPE_PILL } from "@/lib/tone";
import { cn } from "@/lib/utils";
import { ContactPicker } from "./contact-picker";
import { LoanTermsDialog } from "./loan-terms-dialog";
import { DisposalPanel, RepaymentPanel } from "./disposal-panel";
import { JournalPreview } from "./journal-preview";
import { INTERCOMPANY_RULES } from "@/lib/rules/intercompany";
import { coa } from "@/lib/rules/coa";
import { money, parseAmount } from "@/lib/format";
import type { TxDraft, TxFormApi } from "./use-tx-form";

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

/** ขั้น 2 — ผู้ถือกรรมสิทธิ์ & บัญชี */
export function StepHolder({ api }: { api: TxFormApi }) {
  const allBanks = useOrderedBanks(true);
  const isCorp = api.draft.holderId === "corp";

  // เห็นเฉพาะบัญชีของผู้ถือที่เลือก — บัญชีของคนอื่นเลือกไม่ได้ตั้งแต่ต้น
  const banks = allBanks.filter((b) => b.ownerId === api.draft.holderId);

  React.useEffect(() => {
    if (!api.draft.bankId && banks.length) api.patch({ bankId: banks[0].id });
  }, [api, banks]);

  return (
    <div className="flex flex-col gap-4">
      <div>
        <div className="mb-1.5 text-sm text-ink-600">รายการนี้อยู่ในชื่อใคร (ผู้ถือกรรมสิทธิ์)</div>
        <div className="flex flex-wrap gap-2.5">
          {HOLDERS.map((e) => {
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
                <span className="h-2.5 w-2.5 rounded-pill" style={{ background: e.color }} />
                {e.name}
              </button>
            );
          })}
        </div>
      </div>

      <div className="rounded border border-brand-100 bg-brand-50 p-[14px_16px] text-base leading-7">
        {isCorp
          ? "ถือในชื่อนิติบุคคล: ต้องแนบหลักฐาน (ใบเสร็จ/ใบแจ้งหนี้) และระบุคู่ค้าก่อนส่งอนุมัติ"
          : "ถือในชื่อบุคคล: เงินยังเป็นกองกลางของครอบครัว แนบหลักฐานภายหลังได้ แต่ต้องระบุคู่ค้าเพื่อการติดตาม"}
      </div>

      <Field
        label="บัญชีธนาคาร"
        required
        hint="เห็นเฉพาะบัญชีของผู้ถือที่เลือก · เรียงตามลำดับที่ตั้งไว้ใน ตั้งค่า › บัญชีธนาคาร"
        error={banks.length === 0 ? "ผู้ถือรายนี้ยังไม่มีบัญชีที่เปิดใช้งาน" : undefined}
      >
        <Select value={api.draft.bankId} onChange={(e) => api.pickBank(e.target.value)} disabled={banks.length === 0}>
          {banks.map((b) => (
            <option key={b.id} value={b.id}>
              {b.name}
            </option>
          ))}
        </Select>
      </Field>

      <Field label="เหตุผลที่เลือกผู้ถือรายนี้">
        <Select value={api.draft.holderReason} onChange={(e) => api.patch({ holderReason: e.target.value })}>
          <option value="asset_personal">ทรัพย์ถือในชื่อบุคคล</option>
          <option value="contract_corp">สัญญาทำในชื่อบริษัท</option>
          <option value="paid_personal">ใช้เงินส่วนตัวจ่ายก่อน</option>
          <option value="internal">โอนภายในกลุ่ม</option>
        </Select>
      </Field>
    </div>
  );
}

/** ขั้น 3 — รายละเอียด (หมวดย่อยผูกกับประเภทตามตารางกฎ) */
export function StepDetail({ api, contactLayer = 1, narrow }: { api: TxFormApi; contactLayer?: number; narrow?: boolean }) {
  const { draft, sub, subs, requires, patch } = api;
  const needsContact = requires("contact");
  const needsAsset = requires("asset");
  // ขายทรัพย์: ยอดเงินมาจาก ราคาขาย − ค่าใช้จ่ายในการขาย ในแผงด้านล่าง ไม่ให้พิมพ์ทับ
  const amountDerived = requires("capitalGain");

  return (
    <div className="flex flex-col gap-4">
      <Field
        label="จำนวนเงิน (บาท)"
        required
        hint={amountDerived ? "คำนวณให้จาก ราคาขาย − ค่าใช้จ่ายในการขาย ในแผงคำนวณกำไร/ขาดทุน" : undefined}
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
        <Field label="วันที่เอกสาร">
          <Input value={draft.docDate} onChange={(e) => patch({ docDate: e.target.value })} />
        </Field>
        <Field label={draft.notYetPaid ? "วันที่ครบกำหนด" : "วันที่เงินเข้า/ออกจริง"}>
          <Input value={draft.cashDate} onChange={(e) => patch({ cashDate: e.target.value })} />
        </Field>
      </div>

      <label className="flex min-h-control items-start gap-2.5 text-base">
        <Checkbox
          className="mt-0.5"
          checked={draft.notYetPaid && api.canAccrue}
          disabled={!api.canAccrue}
          onChange={(e) => patch({ notYetPaid: e.target.checked })}
        />
        <span className={cn("leading-[26px]", !api.canAccrue && "text-ink-400")}>
          ยังไม่ได้รับ/จ่ายเงิน (บันทึกเป็นค้างรับ-ค้างจ่าย)
          {api.canAccrue && sub?.accrualCoa ? (
            <span className="block text-sm text-ink-600">
              จะลงเป็น {coa(sub.accrualCoa).nameTh} แทนเงินสด ยอดธนาคารยังไม่ขยับ
            </span>
          ) : (
            <span className="block text-sm">หมวดนี้ตั้งค้างไม่ได้ — ต้องมีเงินเข้า/ออกจริง</span>
          )}
        </span>
      </label>

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

      {sub ? <ImpactPreview subCode={sub.code} /> : null}

      <div className={cn("grid gap-4", narrow ? "grid-cols-1" : "grid-cols-1 sm:grid-cols-2")}>
        <Field
          label="ทรัพย์ที่ผูก"
          required={needsAsset}
          error={needsAsset && !draft.assetId ? "หมวดย่อยนี้ต้องผูกทรัพย์" : undefined}
          hint={!needsAsset ? "ไม่บังคับสำหรับหมวดนี้" : undefined}
        >
          <Select value={draft.assetId} onChange={(e) => patch({ assetId: e.target.value })}>
            <option value="">— ไม่ผูกทรัพย์ —</option>
            {ASSETS.map((a) => (
              <option key={a.id} value={a.id}>
                {a.name}
              </option>
            ))}
          </Select>
        </Field>

        <ContactPicker
          value={draft.contactId}
          onSelect={(id) => patch({ contactId: id })}
          label={needsContact ? "ผู้ติดต่อ (คู่ค้า / ผู้เช่า / ผู้ให้กู้)" : "ผู้ติดต่อ"}
          required={needsContact}
          hint={!needsContact ? "ไม่บังคับสำหรับหมวดนี้" : undefined}
          layer={contactLayer}
        />
      </div>

      {/* โอนระหว่างบัญชี — ต้องมีปลายทาง และถ้าข้ามผู้ถือต้องบอกว่าเป็นอะไร */}
      {requires("transferTarget") ? <TransferSection api={api} narrow={narrow} /> : null}

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
  const banks = useOrderedBanks(true).filter((b) => b.id !== draft.bankId);
  const toOwner = transferToOwnerId ? entityById(transferToOwnerId) : null;

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
                {b.name} · {entityById(b.ownerId).name}
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
          ข้ามผู้ถือ — เงินออกจากชื่อ <b>{entityById(draft.holderId).name}</b> ไปเข้าชื่อ <b>{toOwner?.name}</b>{" "}
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

/** แสดงว่าระบบจะลงบัญชีให้อย่างไร ก่อนกดยืนยัน */
export function ImpactPreview({ subCode }: { subCode: string }) {
  const found = React.useMemo(() => TX_TYPES.flatMap((t) => t.subs).find((s) => s.code === subCode), [subCode]);
  if (!found) return null;

  return (
    <div className="flex flex-col gap-2 rounded-card border border-line bg-canvas p-4">
      <div className="text-base font-semibold">ระบบจะบันทึกให้ดังนี้</div>
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
  const banks = useOrderedBanks(true);
  const holder = HOLDERS.find((h) => h.id === draft.holderId);
  const bank = banks.find((b) => b.id === draft.bankId);
  const asset = ASSETS.find((a) => a.id === draft.assetId);
  const typeLabel = TX_TYPES.find((t) => t.key === draft.typeKey);
  const isCorp = holder?.policy === "corporate_strict";

  const summary = [
    { k: "ประเภท", v: typeLabel ? `${typeLabel.label} · ${sub?.label ?? "—"}` : "—" },
    { k: "ถือในชื่อ", v: holder?.name ?? "—" },
    { k: "บัญชี", v: bank?.name ?? "—" },
    { k: "จำนวนเงิน", v: draft.amount ? `฿ ${draft.amount}` : "—" },
    { k: "วันที่เอกสาร / เงินจริง", v: `${draft.docDate} · ${draft.notYetPaid ? "ยังไม่ได้รับ-จ่าย" : draft.cashDate}` },
    { k: "ทรัพย์ที่ผูก", v: asset?.name ?? "—" },
  ];

  // รอบนี้ยังไม่มีที่เก็บไฟล์จริง — จำลองการแนบเพื่อให้เห็นว่ากติกานิติบุคคลทำงานจริง
  const addMockFile = () =>
    patch({ attachments: [...draft.attachments, `หลักฐาน-${draft.attachments.length + 1}.pdf`] });
  const removeFile = (i: number) =>
    patch({ attachments: draft.attachments.filter((_, n) => n !== i) });

  return (
    <div className="flex flex-col gap-4">
      <div className="rounded-card border-2 border-dashed border-line bg-canvas p-6 text-center">
        <div className="text-base font-semibold">ลากไฟล์มาวาง หรือเลือกไฟล์</div>
        <div className="m-[4px_0_12px] text-sm text-ink-600">สลิปโอนเงิน · ใบเสร็จ · ใบแจ้งหนี้ (PDF/JPG)</div>
        <div className="flex flex-wrap justify-center gap-2.5">
          <button
            type="button"
            onClick={addMockFile}
            className="min-h-control rounded border border-line bg-surface px-[18px] text-base font-semibold"
          >
            เลือกไฟล์
          </button>
          <button
            type="button"
            onClick={addMockFile}
            className="min-h-control rounded border border-line bg-surface px-[18px] text-base font-semibold"
          >
            ถ่ายรูป
          </button>
        </div>
        {draft.attachments.length ? (
          <div className="mt-3 flex flex-wrap justify-center gap-2">
            {draft.attachments.map((f, i) => (
              <button
                key={f}
                type="button"
                onClick={() => removeFile(i)}
                className="flex min-h-[44px] items-center gap-2 rounded border border-line bg-surface px-3 text-sm"
              >
                📎 {f} <span className="text-ink-400">เอาออก</span>
              </button>
            ))}
          </div>
        ) : null}
        {isCorp && draft.attachments.length === 0 ? (
          <div className="mt-3 text-sm leading-6 text-warn-fg">
            {holder?.name} เป็นนิติบุคคล — ต้องมีไฟล์หลักฐานอย่างน้อยหนึ่งไฟล์ก่อนบันทึก
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

      <label className="flex items-start gap-3 rounded border border-brand-100 bg-brand-50 p-3.5 text-base leading-[26px]">
        <Checkbox className="mt-0.5 h-6 w-6" checked={draft.skipApproval} onChange={(e) => patch({ skipApproval: e.target.checked })} />
        <span>บันทึกเข้าสมุดบัญชีทันที (ข้ามการอนุมัติ) — เฉพาะ Management</span>
      </label>
    </div>
  );
}

export function TypePill({ tone, children }: { tone: string; children: React.ReactNode }) {
  return <Pill className={TYPE_PILL[tone] ?? TYPE_PILL.trf}>{children}</Pill>;
}
