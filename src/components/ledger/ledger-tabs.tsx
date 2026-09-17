"use client";

import * as React from "react";
import { cn } from "@/lib/utils";
import { TableShell, Table, Th, Td } from "@/components/ui/table";
import { Pill } from "@/components/ui/pill";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Checkbox } from "@/components/ui/checkbox";
import { STATUS_PILL, TYPE_PILL } from "@/lib/tone";
import { money, signedMoney, plMoney, baht } from "@/lib/format";
import { LEDGER, STATUS_LABEL, PL_SERIES, CF_GROUPS, CF_ACCOUNTS, CASH_GROUPS } from "@/lib/mock/ledger";
import { entityById, MONTHS } from "@/lib/mock/entities";
import { findSub, getTxType } from "@/lib/rules/tx-rules";
import { useApp } from "@/lib/store";
import { LedgerDrawer } from "./ledger-drawer";

const TABS = [
  { key: "list", label: "รายการ" },
  { key: "confirm", label: "ยืนยันรับ-จ่าย" },
  { key: "pl", label: "กำไรขาดทุน (PL)" },
  { key: "cf", label: "กระแสเงินสด (CF)" },
] as const;

type TabKey = (typeof TABS)[number]["key"];

export function LedgerTabs() {
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
      </div>

      {tab === "list" ? <ListTab /> : null}
      {tab === "confirm" ? <ConfirmTab /> : null}
      {tab === "pl" ? <PLTab /> : null}
      {tab === "cf" ? <CFTab /> : null}
    </div>
  );
}

function ListTab() {
  const entityId = useApp((s) => s.entityId);
  const month = useApp((s) => s.month);
  const [openRow, setOpenRow] = React.useState<string | null>(null);

  // มุมมอง "SRI Family" คือรวมทุกชื่อ — ไม่กรอง
  const rows = entityId === "family" ? LEDGER : LEDGER.filter((r) => r.ownerId === entityId);

  const totalIn = rows.reduce((t, r) => t + (r.inAmt ?? 0), 0);
  const totalOut = rows.reduce((t, r) => t + (r.outAmt ?? 0), 0);

  const filters = [
    { label: "ช่วงวันที่", value: `${MONTHS[month]} 2026` },
    { label: "ถือในชื่อ", value: entityById(entityId).name },
    { label: "บัญชี", value: "ทุกบัญชี" },
    { label: "กลุ่มรายการ", value: "ทั้งหมด" },
    { label: "สถานะ", value: "ทั้งหมด" },
  ];

  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-wrap items-center gap-2.5">
        {filters.map((f) => (
          <button key={f.label} className="flex min-h-[48px] items-center gap-2 rounded-pill border border-line bg-surface px-3.5 text-sm text-ink-600 hover:border-ink-400">
            <span className="text-ink-400">{f.label}</span>
            <b className="text-ink-900">{f.value}</b>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" className="h-4 w-4">
              <path d="m6 9 6 6 6-6" />
            </svg>
          </button>
        ))}
        <div className="flex min-h-[48px] min-w-[220px] items-center gap-2 rounded border border-line bg-surface px-3.5">
          <svg viewBox="0 0 24 24" fill="none" stroke="#8792A2" strokeWidth="1.75" strokeLinecap="round" className="h-[18px] w-[18px]">
            <circle cx="11" cy="11" r="8" />
            <path d="m21 21-4.3-4.3" />
          </svg>
          <input placeholder="ค้นหารายละเอียด / คู่ค้า" className="w-full border-none text-sm outline-none" />
        </div>
        <div className="ml-auto flex gap-2.5">
          <Button variant="secondary" size="sm">นำเข้า Excel</Button>
          <Button variant="secondary" size="sm">ส่งออก</Button>
        </div>
      </div>

      <TableShell>
        <Table minWidth={1420}>
          <thead>
            <tr>
              <Th className="whitespace-nowrap">วันที่เอกสาร</Th>
              <Th className="whitespace-nowrap">วันที่เงินจริง</Th>
              <Th className="whitespace-nowrap">ประเภท</Th>
              <Th>หมวดย่อย</Th>
              <Th>รายละเอียด</Th>
              <Th>ทรัพย์ที่ผูก</Th>
              <Th>ถือในชื่อ</Th>
              <Th align="right">เงินเข้า</Th>
              <Th align="right">เงินออก</Th>
              <Th>สถานะ</Th>
              <Th align="center">ไฟล์</Th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r, i) => {
              const holder = entityById(r.ownerId);
              const type = getTxType(r.typeKey);
              const sub = findSub(r.subCode)?.sub;
              return (
                <tr
                  key={r.id}
                  onClick={() => setOpenRow(r.id)}
                  className={cn("cursor-pointer border-l-[3px] hover:bg-brand-50", i % 2 ? "bg-[#FCFDFE]" : "bg-surface")}
                  style={{ borderLeftColor: holder.color }}
                >
                  <Td className="whitespace-nowrap">{r.docDate}</Td>
                  <Td className="whitespace-nowrap text-ink-600">{r.cashDate}</Td>
                  <Td className="whitespace-nowrap">
                    <Pill className={TYPE_PILL[type.tone]}>{type.label}</Pill>
                  </Td>
                  <Td className="whitespace-nowrap text-ink-600">{sub?.label ?? "—"}</Td>
                  <Td className="whitespace-nowrap">{r.detail}</Td>
                  <Td className="whitespace-nowrap text-ink-600">{r.assetName}</Td>
                  <Td className="whitespace-nowrap">
                    <span className="inline-flex items-center gap-1.5">
                      <span className="h-2.5 w-2.5 rounded-pill" style={{ background: holder.color }} />
                      {holder.name}
                    </span>
                  </Td>
                  <Td align="right" className="whitespace-nowrap font-semibold text-pos">
                    {r.inAmt ? signedMoney(r.inAmt) : "–"}
                  </Td>
                  <Td align="right" className="whitespace-nowrap font-semibold text-neg">
                    {r.outAmt ? money(-r.outAmt) : "–"}
                  </Td>
                  <Td className="whitespace-nowrap">
                    <Pill className={STATUS_PILL[r.status]}>{STATUS_LABEL[r.status]}</Pill>
                  </Td>
                  <Td align="center" className="text-ink-600">{r.hasFile ? "📎" : "—"}</Td>
                </tr>
              );
            })}
            <tr className="bg-canvas font-semibold">
              <Td colSpan={7} className="border-t border-line">รวม {rows.length} รายการในเดือนนี้</Td>
              <Td align="right" className="border-t border-line text-pos">{signedMoney(totalIn)}</Td>
              <Td align="right" className="border-t border-line text-neg">{money(-totalOut)}</Td>
              <Td colSpan={2} className="border-t border-line" />
            </tr>
          </tbody>
        </Table>
      </TableShell>
      <div className="text-sm text-ink-400">คลิกแถวเพื่อดูรายละเอียดและสิ่งที่ระบบบันทึกให้</div>

      <LedgerDrawer rowId={openRow} onClose={() => setOpenRow(null)} />
    </div>
  );
}

function ConfirmTab() {
  const showToast = useApp((s) => s.showToast);

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center gap-3">
        <div className="text-base text-ink-600">
          รายการที่ครบกำหนดรับ-จ่ายในเดือนนี้ <b className="text-ink-900">5 รายการ</b>
        </div>
        <Button variant="success" className="ml-auto" onClick={() => showToast("ยืนยันรับ-จ่าย 3 รายการแล้ว")}>
          ยืนยัน 3 รายการที่เลือก
        </Button>
      </div>

      {CASH_GROUPS.map((g) => (
        <div key={g.bank} className="overflow-hidden rounded-card border border-line bg-surface shadow-card">
          <div className="flex flex-wrap items-center gap-4 border-b border-line bg-canvas p-[16px_20px]">
            <div>
              <div className="text-lg font-semibold">{g.bank}</div>
              <div className="text-sm text-ink-600">ยอดในระบบ {baht(g.system)}</div>
            </div>
            <label className="ml-auto flex flex-col gap-1">
              <span className="text-sm text-ink-600">ยอดตาม statement</span>
              <Input defaultValue={g.stmt} className="w-[220px] text-right font-semibold" />
            </label>
            <Pill size="md" className={g.matched ? "bg-pos-bg text-pos-fg border-pos" : "bg-warn-bg text-warn-fg border-warn"}>
              {g.matched ? "✓ " : "⚠ "}
              {g.match}
            </Pill>
          </div>
          <div className="overflow-auto">
            <Table minWidth={900}>
              <thead>
                <tr>
                  <Th>รายการ</Th>
                  <Th>ครบกำหนด</Th>
                  <Th align="right">ยอดคาด</Th>
                  <Th align="right">ยอดจริง (แก้ได้)</Th>
                  <Th>วันที่จริง</Th>
                  <Th>สลิป</Th>
                  <Th align="center">ยืนยัน</Th>
                </tr>
              </thead>
              <tbody>
                {g.rows.map((r) => (
                  <tr key={r.id}>
                    <Td className="p-[12px_14px]">
                      <div className="font-semibold">{r.name}</div>
                      <div className="text-sm text-ink-400">{r.sub}</div>
                      {r.partial ? <Pill className="mt-1 border-warn bg-warn-bg text-warn-fg">{r.partial}</Pill> : null}
                    </Td>
                    <Td className="whitespace-nowrap p-[12px_14px] text-ink-600">{r.due}</Td>
                    <Td align="right" className="whitespace-nowrap p-[12px_14px]">{signedMoney(r.expect)}</Td>
                    <Td align="right" className="p-[12px_14px]">
                      <Input defaultValue={r.actual} className="w-40 text-right font-semibold" />
                    </Td>
                    <Td className="p-[12px_14px]">
                      <Input defaultValue={r.date} className="w-36" />
                    </Td>
                    <Td className="p-[12px_14px]">
                      <Button variant="secondary" size="sm">แนบสลิป</Button>
                    </Td>
                    <Td align="center" className="p-[12px_14px]">
                      <Checkbox defaultChecked={r.checked} />
                    </Td>
                  </tr>
                ))}
              </tbody>
            </Table>
          </div>
        </div>
      ))}
    </div>
  );
}

function PLTab() {
  const s = PL_SERIES;
  const sum = (...arrs: number[][]) => arrs[0].map((_, i) => arrs.reduce((a, x) => a + x[i], 0));

  const rows: { name: string; vals: number[]; kind?: "expense" | "sum" }[] = [
    { name: "รายได้ค่าเช่า", vals: s.rent },
    { name: "ดอกเบี้ยรับ", vals: s.interest },
    { name: "เงินปันผล", vals: s.dividend },
    { name: "กำไรจากการขายทรัพย์", vals: s.gain },
    { name: "รวมรายได้", vals: sum(s.rent, s.interest, s.dividend, s.gain), kind: "sum" },
    { name: "ค่าบริหารจัดการ", vals: s.admin, kind: "expense" },
    { name: "ซ่อมบำรุง", vals: s.repair, kind: "expense" },
    { name: "ดอกเบี้ยจ่าย", vals: s.interestExp, kind: "expense" },
    { name: "ภาษี & ค่าธรรมเนียม", vals: s.tax, kind: "expense" },
    { name: "รวมค่าใช้จ่าย", vals: sum(s.admin, s.repair, s.interestExp, s.tax), kind: "expense" },
    { name: "กำไรสุทธิ", vals: sum(s.rent, s.interest, s.dividend, s.gain, s.admin, s.repair, s.interestExp, s.tax), kind: "sum" },
  ];

  return (
    <TableShell>
      <Table minWidth={1240}>
        <thead>
          <tr>
            <Th className="sticky left-0 bg-canvas">หมวด</Th>
            {MONTHS.map((m) => (
              <Th key={m} align="right" className="whitespace-nowrap p-[12px_8px]">
                {m.replace(".", "")}
              </Th>
            ))}
            <Th align="right" className="text-ink-900">รวม</Th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => {
            const total = r.vals.reduce((a, b) => a + b, 0);
            const bold = r.kind === "sum";
            const tone = r.kind === "expense" ? "text-neg" : "text-ink-900";
            return (
              <tr key={r.name} className={bold ? "bg-canvas" : "bg-surface"}>
                <Td className={cn("whitespace-nowrap p-[11px_10px]", bold && "font-semibold")}>{r.name}</Td>
                {r.vals.map((v, i) => (
                  <Td key={i} align="right" className={cn("whitespace-nowrap p-[11px_8px]", tone, bold && "font-semibold")}>
                    {plMoney(v)}
                  </Td>
                ))}
                <Td align="right" className={cn("whitespace-nowrap p-[11px_10px] font-semibold", tone)}>
                  {plMoney(total)}
                </Td>
              </tr>
            );
          })}
        </tbody>
      </Table>
    </TableShell>
  );
}

function CFTab() {
  return (
    <div className="flex flex-col gap-4">
      {CF_GROUPS.map((g) => (
        <div key={g.name} className="rounded-card border border-line bg-surface p-[18px_20px] shadow-card">
          <div className="mb-2 flex items-baseline justify-between gap-3">
            <div className="text-h2 font-semibold">{g.name}</div>
            <div className={cn("text-h2 font-semibold", g.total < 0 ? "text-neg" : "text-pos")}>{signedMoney(g.total)}</div>
          </div>
          {g.items.map((i) => (
            <div key={i.name} className="flex justify-between gap-3 border-t border-line py-2.5 text-base">
              <span>{i.name}</span>
              <span className={cn("font-semibold", i.amount < 0 ? "text-neg" : "text-pos")}>{signedMoney(i.amount)}</span>
            </div>
          ))}
        </div>
      ))}

      <TableShell>
        <Table minWidth={720}>
          <thead>
            <tr>
              <Th>บัญชีธนาคาร</Th>
              <Th align="right">ยอดต้นงวด</Th>
              <Th align="right">เข้า</Th>
              <Th align="right">ออก</Th>
              <Th align="right">ยอดปลายงวด</Th>
            </tr>
          </thead>
          <tbody>
            {CF_ACCOUNTS.map((a) => (
              <tr key={a.name}>
                <Td>{a.name}</Td>
                <Td align="right">{money(a.open)}</Td>
                <Td align="right" className="font-semibold text-pos">{signedMoney(a.in)}</Td>
                <Td align="right" className="font-semibold text-neg">{money(a.out)}</Td>
                <Td align="right" className="font-semibold">{money(a.close)}</Td>
              </tr>
            ))}
          </tbody>
        </Table>
      </TableShell>
    </div>
  );
}
