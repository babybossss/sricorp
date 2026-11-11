"use client";

import * as React from "react";
import Link from "next/link";
import { cn } from "@/lib/utils";
import { TableShell, Table, Th, Td } from "@/components/ui/table";
import { Pill } from "@/components/ui/pill";
import { useApp } from "@/lib/store";
import { STATUS_PILL, TYPE_PILL } from "@/lib/tone";
import { money, signedMoney } from "@/lib/format";
import { findSub } from "@/lib/rules/tx-rules";
import { useReference } from "@/components/reference/reference-provider";
import { FAMILY_VIEW } from "@/lib/db/reference-types";
import { cashNet } from "@/lib/db/ledger-entries";
import type { LedgerListState } from "@/lib/db/ledger-entries-server";
import { isoToDmy } from "@/lib/format";
import { EntryDrawer } from "./entry-drawer";
import { ConfirmTab } from "./confirm-tab";
import type { PendingAccrualsState } from "@/lib/db/pending-accruals-server";

const TABS = [
  { key: "list", label: "รายการ" },
  { key: "confirm", label: "ยืนยันรับ-จ่าย" },
] as const;

type TabKey = (typeof TABS)[number]["key"];

export function LedgerTabs({ ledger, pending }: { ledger: LedgerListState; pending: PendingAccrualsState }) {
  const [tab, setTab] = React.useState<TabKey>("list");
  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap gap-1 border-b border-line">
        {TABS.map((t) => (
          <button
            key={t.key}
            onClick={() => setTab(t.key)}
            className={cn(
              "min-h-control border-b-[3px] px-[18px] text-base font-semibold",
              tab === t.key ? "border-brand-600 text-brand-600" : "border-transparent text-ink-600"
            )}
          >
            {t.label}
          </button>
        ))}
        <Link
          href="/reports"
          className="ml-auto inline-flex min-h-control items-center px-[18px] text-base font-semibold text-brand-600 no-underline hover:underline focus-visible:outline-none focus-visible:ring-[3px] focus-visible:ring-brand-600"
        >
          ดูงบการเงิน (ฐานะ · กำไรขาดทุน · กระแสเงินสด)
        </Link>
      </div>

      {tab === "list" ? <ListTab ledger={ledger} pending={pending} /> : null}
      {tab === "confirm" ? <ConfirmTab pending={pending} /> : null}
    </div>
  );
}

function ListTab({ ledger, pending }: { ledger: LedgerListState; pending: PendingAccrualsState }) {
  const entityId = useApp((s) => s.entityId);
  const ref = useReference();
  const [openId, setOpenId] = React.useState<string | null>(null);

  if (!ledger.ok) {
    return (
      <div role="alert" className="rounded border border-neg bg-neg-bg p-[14px_16px] text-base leading-7 text-neg-fg">
        โหลดรายการสมุดบัญชีจากฐานข้อมูลไม่สำเร็จ: {ledger.error}
        <div className="mt-1 text-sm">ลองโหลดหน้านี้ใหม่ ถ้ายังไม่ได้ให้แจ้งผู้ดูแลระบบ</div>
      </div>
    );
  }

  // มุมมอง "SRI Family" คือรวมทุกชื่อ — ไม่กรอง · ผู้ถือที่เลือกกรองตามเจ้าของรายการ (หรือฝั่งคู่ของรายการข้ามผู้ถือ)
  const rows =
    entityId === FAMILY_VIEW
      ? ledger.entries
      : ledger.entries.filter((e) => e.ownerId === entityId);

  const nets = rows.map((e) => cashNet(e));
  const totalIn = nets.reduce<number>((t, n) => t + (n !== null && n > 0 ? n : 0), 0);
  const totalOut = nets.reduce<number>((t, n) => t + (n !== null && n < 0 ? -n : 0), 0);
  const openEntry = openId ? ledger.entries.find((e) => e.id === openId) ?? null : null;

  const ownerOf = (id: string) => ref.owners.find((o) => o.id === id);
  const currentOwner = entityId === FAMILY_VIEW ? undefined : ownerOf(entityId);

  const filters = [
    { label: "ช่วงวันที่", value: ledger.truncated ? "ล่าสุด (ยังมีเก่ากว่านี้)" : "ทั้งหมดที่บันทึกแล้ว" },
    { label: "ถือในชื่อ", value: currentOwner?.name ?? "รวมทุกชื่อ" },
  ];

  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-wrap items-center gap-2.5">
        {filters.map((f) => (
          <div key={f.label} className="flex min-h-[48px] items-center gap-2 rounded-pill border border-line bg-surface px-3.5 text-sm text-ink-600">
            <span className="text-ink-400">{f.label}</span>
            <b className="text-ink-900">{f.value}</b>
          </div>
        ))}
        <div className="text-sm text-ink-400">เปลี่ยนผู้ถือได้ที่ตัวสลับมุมมองด้านบน</div>
      </div>

      {ledger.truncated ? (
        <div className="rounded border border-warn bg-warn-bg p-[12px_16px] text-base leading-7 text-warn-fg">
          แสดงเฉพาะรายการล่าสุด — ในฐานข้อมูลยังมีรายการเก่ากว่านี้อีก
        </div>
      ) : null}

      <TableShell>
        <Table minWidth={1180}>
          <thead>
            <tr>
              <Th className="whitespace-nowrap">วันที่เอกสาร</Th>
              <Th className="whitespace-nowrap">วันที่เงินจริง</Th>
              <Th className="whitespace-nowrap">ประเภท</Th>
              <Th>หมวดย่อย</Th>
              <Th>รายละเอียด</Th>
              <Th>โปรเจค (ทรัพย์)</Th>
              <Th>ถือในชื่อ</Th>
              <Th align="right">เงินเข้า</Th>
              <Th align="right">เงินออก</Th>
              <Th>สถานะ</Th>
              <Th align="center">ไฟล์</Th>
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 ? (
              <tr>
                <Td colSpan={11} className="py-8 text-center text-ink-600">
                  ยังไม่มีรายการในสมุดบัญชี{currentOwner ? `ของ ${currentOwner.name}` : ""} — กด “บันทึกรายการ” ด้านบนเพื่อเริ่มลงรายการ
                </Td>
              </tr>
            ) : null}
            {rows.map((e, i) => {
              const owner = ownerOf(e.ownerId);
              const found = findSub(e.subCode);
              const asset = e.assetId ? ref.assets.find((a) => a.id === e.assetId) : undefined;
              const net = nets[i];
              const reversal = e.source === "reverse";
              // สถานะค้าง/ล้างแล้วมาจากยอดค้างที่อ่านจาก DB (ประวัติการล้างจริง) ไม่ได้เดาจากหน้าจอ
              // ไม่รู้สถานะ (โหลดยอดค้างไม่สำเร็จ) = ไม่ติดป้ายว่าล้างแล้ว
              const accrued = pending.ok && pending.pending.some((p) => p.id === e.id);
              const cleared = pending.ok && pending.clearedIds.includes(e.id);
              const status = reversal ? "off" : accrued ? "late" : cleared ? "done" : "saved";
              const statusLabel = reversal ? "กลับรายการ" : accrued ? "ค้างรับ/ค้างจ่าย" : cleared ? "ล้างยอดค้างแล้ว" : "บันทึกแล้ว";
              return (
                <tr
                  key={e.id}
                  onClick={() => setOpenId(e.id)}
                  className={cn("cursor-pointer border-l-[3px] hover:bg-brand-50", i % 2 ? "bg-canvas" : "bg-surface")}
                  style={owner?.color ? { borderLeftColor: owner.color } : undefined}
                >
                  <Td className="whitespace-nowrap">{isoToDmy(e.docDate)}</Td>
                  <Td className="whitespace-nowrap text-ink-600">{e.cashDate ? isoToDmy(e.cashDate) : "—"}</Td>
                  <Td className="whitespace-nowrap">
                    {found ? <Pill className={TYPE_PILL[found.type.tone]}>{found.type.label}</Pill> : "—"}
                  </Td>
                  <Td className="whitespace-nowrap text-ink-600">{found?.sub.label ?? e.subCode}</Td>
                  <Td className="whitespace-nowrap">{e.memo ?? "—"}</Td>
                  <Td className="whitespace-nowrap text-ink-600">{asset?.name ?? "—"}</Td>
                  <Td className="whitespace-nowrap">
                    <span className="inline-flex items-center gap-1.5">
                      <span className="h-2.5 w-2.5 rounded-pill bg-holder-group" style={owner?.color ? { background: owner.color } : undefined} />
                      {owner?.name ?? "ผู้ถือที่ไม่รู้จัก"}
                    </span>
                  </Td>
                  <Td align="right" className="whitespace-nowrap font-semibold text-pos">
                    {net !== null && net > 0 ? signedMoney(net) : "–"}
                  </Td>
                  <Td align="right" className="whitespace-nowrap font-semibold text-neg">
                    {net !== null && net < 0 ? money(net) : "–"}
                  </Td>
                  <Td className="whitespace-nowrap">
                    <Pill className={STATUS_PILL[status]}>{statusLabel}</Pill>
                  </Td>
                  <Td align="center" className="text-ink-600">{e.attachments.length ? `📎 ${e.attachments.length}` : "—"}</Td>
                </tr>
              );
            })}
            {rows.length ? (
              <tr className="bg-canvas font-semibold">
                <Td colSpan={7} className="border-t border-line">รวม {rows.length} รายการ</Td>
                <Td align="right" className="border-t border-line text-pos">{signedMoney(totalIn)}</Td>
                <Td align="right" className="border-t border-line text-neg">{money(-totalOut)}</Td>
                <Td colSpan={2} className="border-t border-line" />
              </tr>
            ) : null}
          </tbody>
        </Table>
      </TableShell>
      <div className="text-sm text-ink-400">คลิกแถวเพื่อดูบรรทัดบัญชีที่ระบบบันทึกจริง</div>

      <EntryDrawer entry={openEntry} onClose={() => setOpenId(null)} />
    </div>
  );
}
