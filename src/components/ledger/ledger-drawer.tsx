"use client";

import * as React from "react";
import { LEDGER, STATUS_LABEL } from "@/lib/mock/ledger";
import { findSub, getTxType, impactLines } from "@/lib/rules/tx-rules";
import { entityById } from "@/lib/mock/entities";
import { signedMoney, money } from "@/lib/format";
import { Button } from "@/components/ui/button";
import { Pill } from "@/components/ui/pill";
import { TYPE_PILL } from "@/lib/tone";
import { useApp } from "@/lib/store";
import { contactFullName } from "@/lib/mock/contacts";

/** Drawer รายละเอียดรายการ — บอกว่าระบบลงบัญชีให้อย่างไรตามตารางกฎ */
export function LedgerDrawer({ rowId, onClose }: { rowId: string | null; onClose: () => void }) {
  const contacts = useApp((s) => s.contacts);
  const row = rowId ? LEDGER.find((r) => r.id === rowId) : null;

  React.useEffect(() => {
    if (!row) return;
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [row, onClose]);

  if (!row) return null;

  const type = getTxType(row.typeKey);
  const sub = findSub(row.subCode)?.sub;
  const holder = entityById(row.ownerId);
  const contact = row.contactId ? contacts.find((c) => c.id === row.contactId) : undefined;
  const amount = row.inAmt ? signedMoney(row.inAmt) : money(row.outAmt ? -row.outAmt : 0);

  const fields = [
    { k: "ประเภท", v: `${type.label} · ${sub?.label ?? "—"}` },
    { k: "วันที่เอกสาร", v: row.docDate },
    { k: "วันที่เงินจริง", v: row.cashDate },
    { k: "ถือในชื่อ", v: holder.name },
    { k: "บัญชี", v: row.accountName },
    { k: "ผู้ติดต่อ", v: contact ? contactFullName(contact) : "—" },
    { k: "สถานะ", v: STATUS_LABEL[row.status] },
  ];

  return (
    <div className="fixed inset-0 z-50 flex justify-end bg-[rgba(10,37,64,.35)]" onClick={onClose}>
      <div
        role="dialog"
        aria-label="รายละเอียดรายการ"
        className="h-full w-[min(520px,100%)] animate-slidein overflow-auto bg-surface shadow-drawer"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center gap-3 border-b border-line p-[20px_24px]">
          <div className="mr-auto text-h2 font-semibold">รายละเอียดรายการ</div>
          <Button variant="secondary" size="sm" onClick={onClose}>ปิด</Button>
        </div>

        <div className="flex flex-col gap-4 p-6">
          <div>
            <div className="flex items-center gap-2 text-sm text-ink-600">
              <Pill className={TYPE_PILL[type.tone]}>{type.label}</Pill>
              {row.detail} · {row.assetName}
            </div>
            <div className={`text-display font-semibold ${row.inAmt ? "text-pos" : "text-neg"}`}>{amount}</div>
          </div>

          {sub ? (
            <div className="rounded-card border border-line bg-canvas p-4">
              <div className="mb-1.5 text-base font-semibold">ระบบบันทึกให้ดังนี้</div>
              <div className="mb-2 text-base leading-7 text-ink-600">{sub.plain}</div>
              <ul className="m-0 flex list-none flex-col gap-1 p-0 text-sm text-ink-600">
                {impactLines(sub).map((l) => (
                  <li key={l} className="flex gap-2">
                    <span className="text-ink-400">·</span>
                    {l}
                  </li>
                ))}
              </ul>
            </div>
          ) : null}

          <div className="flex flex-col gap-2">
            {fields.map((f) => (
              <div key={f.k} className="flex justify-between gap-3 border-b border-line py-2 text-base">
                <span className="text-ink-600">{f.k}</span>
                <span className="text-right font-semibold">{f.v}</span>
              </div>
            ))}
          </div>

          {row.hasFile ? (
            <div className="flex items-center gap-3 rounded border border-line p-[12px_14px]">
              <div className="flex h-[60px] w-12 items-center justify-center rounded-md border border-line bg-canvas text-sm text-ink-400">PDF</div>
              <div className="flex-1">
                <div className="text-base font-semibold">invoice-sep.pdf</div>
                <div className="text-sm text-ink-400">แนบเมื่อ {row.cashDate}</div>
              </div>
            </div>
          ) : (
            <div className="rounded border border-neg bg-neg-bg p-[12px_14px] text-sm leading-6 text-neg-fg">ยังไม่มีไฟล์แนบ</div>
          )}

          <div className="text-sm text-ink-400">ประวัติการแก้ไข: สร้างโดย มาวิน {row.docDate} · อนุมัติโดย ธนกร {row.cashDate}</div>

          <Button variant="danger">กลับรายการ (Reverse)</Button>
        </div>
      </div>
    </div>
  );
}
