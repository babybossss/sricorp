"use client";

import * as React from "react";
import { Button } from "@/components/ui/button";
import { Pill } from "@/components/ui/pill";
import { useReference } from "@/components/reference/reference-provider";
import { contactFullName } from "@/lib/db/reference-types";
import { cashNet, UNKNOWN_COA, type LedgerEntry } from "@/lib/db/ledger-entries";
import { coa } from "@/lib/rules/coa";
import { findSub } from "@/lib/rules/tx-rules";
import { TYPE_PILL } from "@/lib/tone";
import { isoToDmy, money, signedMoney } from "@/lib/format";

/** ชื่อบัญชี — รหัสที่ไม่อยู่ในผังบัญชีของโค้ดแสดงตามจริง ไม่เดาชื่อให้ */
function accountName(code: string): string {
  if (code === UNKNOWN_COA) return "ไม่รู้จักบัญชีนี้";
  try {
    return coa(code).nameTh;
  } catch {
    return "ไม่อยู่ในผังบัญชีของโปรแกรม";
  }
}

/**
 * Drawer รายละเอียดรายการที่ post แล้ว — อ่านจากบรรทัดที่บันทึกจริงใน DB
 * (ไม่ใช่คำอธิบายจากตารางกฎ) ผู้ใช้จึงเห็นสิ่งที่ถูกบันทึกจริง ไม่ใช่สิ่งที่ "ควรจะ" บันทึก
 */
export function EntryDrawer({ entry, onClose }: { entry: LedgerEntry | null; onClose: () => void }) {
  const ref = useReference();

  React.useEffect(() => {
    if (!entry) return;
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [entry, onClose]);

  if (!entry) return null;

  const found = findSub(entry.subCode);
  const owner = ref.owners.find((o) => o.id === entry.ownerId);
  const counter = entry.counterOwnerId ? ref.owners.find((o) => o.id === entry.counterOwnerId) : undefined;
  const contact = entry.contactId ? ref.contacts.find((c) => c.id === entry.contactId) : undefined;
  const asset = entry.assetId ? ref.assets.find((a) => a.id === entry.assetId) : undefined;
  const bankNames = [...new Set(entry.lines.map((l) => l.bankAccountId).filter((x): x is string => !!x))].map(
    (id) => ref.banks.find((b) => b.id === id)?.name ?? "บัญชีที่ไม่รู้จัก"
  );
  const net = cashNet(entry);
  const totalDr = entry.lines.reduce((t, l) => t + l.debit, 0);
  const totalCr = entry.lines.reduce((t, l) => t + l.credit, 0);

  const fields = [
    { k: "ประเภท", v: found ? `${found.type.label} · ${found.sub.label}` : entry.subCode },
    { k: "วันที่เอกสาร", v: isoToDmy(entry.docDate) },
    { k: "วันที่เงินจริง", v: entry.cashDate ? isoToDmy(entry.cashDate) : "ยังไม่มีเงินเคลื่อน" },
    { k: "ถือในชื่อ", v: owner?.name ?? "ผู้ถือที่ไม่รู้จัก" },
    ...(counter ? [{ k: "คู่กับ", v: counter.name }] : []),
    { k: "บัญชี", v: bankNames.length ? bankNames.join(" · ") : "—" },
    { k: "ผู้ติดต่อ", v: contact ? contactFullName(contact) : "—" },
    { k: "โปรเจค (ทรัพย์)", v: asset?.name ?? "—" },
    { k: "ไฟล์แนบ", v: entry.attachments.length ? `${entry.attachments.length} ไฟล์` : "ไม่มี" },
  ];

  return (
    <div className="fixed inset-0 z-50 flex justify-end bg-[rgba(10,37,64,.35)]" onClick={onClose}>
      <div
        role="dialog"
        aria-label="รายละเอียดรายการ"
        className="h-full w-[min(560px,100%)] animate-slidein overflow-auto bg-surface shadow-drawer"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center gap-3 border-b border-line p-[20px_24px]">
          <div className="mr-auto text-h2 font-semibold">รายละเอียดรายการ</div>
          <Button variant="secondary" onClick={onClose}>
            ปิด
          </Button>
        </div>

        <div className="flex flex-col gap-4 p-6">
          <div>
            <div className="flex flex-wrap items-center gap-2 text-sm text-ink-600">
              {found ? <Pill className={TYPE_PILL[found.type.tone]}>{found.type.label}</Pill> : null}
              {entry.memo ?? found?.sub.label ?? entry.subCode}
              {entry.source === "reverse" ? <Pill className="border-line bg-canvas text-ink-600">ใบกลับรายการ</Pill> : null}
            </div>
            {net === null ? (
              <div className="text-display font-semibold text-ink-600">ไม่มีเงินเคลื่อน</div>
            ) : (
              <div className={`text-display font-semibold tabular-nums ${net >= 0 ? "text-pos" : "text-neg"}`}>
                {net >= 0 ? signedMoney(net) : money(net)}
              </div>
            )}
          </div>

          <div className="overflow-hidden rounded-card border border-line">
            <div className="border-b border-line bg-canvas p-[10px_14px] text-base font-semibold">
              ระบบบันทึกให้ดังนี้ (บรรทัดที่บันทึกจริง)
            </div>
            <table className="w-full border-collapse text-sm">
              <thead>
                <tr className="bg-canvas">
                  <th className="p-[8px_12px] text-left font-semibold text-ink-600">บัญชี</th>
                  <th className="p-[8px_12px] text-right font-semibold text-ink-600">เดบิต</th>
                  <th className="p-[8px_12px] text-right font-semibold text-ink-600">เครดิต</th>
                </tr>
              </thead>
              <tbody>
                {entry.lines.map((l, i) => (
                  <tr key={`${l.coaCode}-${i}`} className="border-t border-line">
                    <td className="p-[8px_12px]">
                      <span className="text-ink-400">{l.coaCode}</span> {accountName(l.coaCode)}
                      {l.memo ? <span className="text-ink-400"> · {l.memo}</span> : null}
                    </td>
                    <td className="p-[8px_12px] text-right tabular-nums">{l.debit ? money(l.debit) : "–"}</td>
                    <td className="p-[8px_12px] text-right tabular-nums">{l.credit ? money(l.credit) : "–"}</td>
                  </tr>
                ))}
                <tr className="border-t border-line bg-canvas font-semibold">
                  <td className="p-[8px_12px]">รวม</td>
                  <td className="p-[8px_12px] text-right tabular-nums">{money(totalDr)}</td>
                  <td className="p-[8px_12px] text-right tabular-nums">{money(totalCr)}</td>
                </tr>
              </tbody>
            </table>
          </div>

          <div className="flex flex-col gap-2">
            {fields.map((f) => (
              <div key={f.k} className="flex justify-between gap-3 border-b border-line py-2 text-base">
                <span className="text-ink-600">{f.k}</span>
                <span className="text-right font-semibold">{f.v}</span>
              </div>
            ))}
          </div>

          <div className="rounded border border-line bg-canvas p-[12px_14px] text-sm leading-6 text-ink-600">
            รายการที่บันทึกแล้วลบไม่ได้ — ถ้าบันทึกผิด แก้ด้วยการกลับรายการ (ยังไม่ได้ต่อปุ่มกลับรายการกับฐานข้อมูลในรอบนี้)
          </div>
        </div>
      </div>
    </div>
  );
}
