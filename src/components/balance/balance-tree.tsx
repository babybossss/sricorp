"use client";

import * as React from "react";
import Link from "next/link";
import { TREE, NAV_BY_HOLDER, type TreeNode } from "@/lib/mock/balance";
import { money, plMoney } from "@/lib/format";
import { Table, Th, Td } from "@/components/ui/table";
import { Pill } from "@/components/ui/pill";
import { Button } from "@/components/ui/button";
import { STATUS_PILL } from "@/lib/tone";
import { cn } from "@/lib/utils";

const VIEWS = [
  { key: "consol", label: "รวมกองกลาง (ตัดรายการระหว่างกัน)" },
  { key: "class", label: "ตามหมวด" },
  { key: "owner", label: "ตามชื่อผู้ถือ" },
] as const;

type Row = TreeNode & { level: number; open: boolean; leaf: boolean };

export function BalanceTree() {
  const [view, setView] = React.useState<(typeof VIEWS)[number]["key"]>("consol");
  const [expanded, setExpanded] = React.useState<Record<string, boolean>>({
    assets: true,
    cash: true,
    re: true,
    rent: true,
    liab: true,
    eq: true,
  });

  const rows = React.useMemo(() => {
    const out: Row[] = [];
    const walk = (nodes: TreeNode[], level: number) => {
      for (const n of nodes) {
        const open = expanded[n.id] ?? false;
        out.push({ ...n, level, open, leaf: !n.children });
        if (open && n.children) walk(n.children, level + 1);
      }
    };
    walk(TREE, 0);
    return out;
  }, [expanded]);

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center gap-3">
        <div className="flex overflow-hidden rounded border border-line bg-surface">
          {VIEWS.map((v) => (
            <button
              key={v.key}
              onClick={() => setView(v.key)}
              className={cn("min-h-control px-[18px] text-base font-semibold", view === v.key ? "bg-brand-600 text-white" : "bg-surface text-ink-600")}
            >
              {v.label}
            </button>
          ))}
        </div>
        <div className="ml-auto flex flex-wrap gap-2.5">
          <Button variant="secondary">อัปเดตราคาตอนนี้</Button>
          <Button>+ เพิ่มทรัพย์</Button>
        </div>
      </div>

      <div className="grid items-start gap-4 xl:[grid-template-columns:minmax(0,1fr)_320px]">
        <div className="min-w-0 overflow-hidden rounded-card border border-line bg-surface shadow-card">
          <div className="border-b border-warn bg-warn-bg p-[12px_18px] text-sm leading-6 text-warn-fg">
            มูลค่าตลาดใช้เพื่อการบริหาร ไม่ใช่งบการเงินตามกฎหมาย
          </div>
          <div className="overflow-auto">
            <Table minWidth={1080}>
              <thead>
                <tr>
                  <Th className="p-[12px_14px]">รายการ</Th>
                  <Th>ถือในชื่อ</Th>
                  <Th align="right">ต้นทุน</Th>
                  <Th align="right">มูลค่าปัจจุบัน</Th>
                  <Th>แหล่งราคา</Th>
                  <Th align="right">กำไรยังไม่รับรู้</Th>
                  <Th align="right">Yield/ปี</Th>
                  <Th className="p-[12px_14px]">สถานะ</Th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => {
                  const bg = r.level === 0 ? "bg-canvas" : r.level === 1 ? "bg-[#FCFDFE]" : "bg-surface";
                  const fw = r.level === 0 ? "font-bold" : r.level === 1 ? "font-semibold" : "font-normal";
                  const clickable = !r.leaf || !!r.assetId;
                  const nameCell = (
                    <span className={fw}>
                      {r.leaf ? "" : r.open ? "▾ " : "▸ "}
                      {r.name}
                    </span>
                  );
                  return (
                    <tr
                      key={r.id}
                      className={cn(bg, clickable && "cursor-pointer hover:bg-brand-50")}
                      onClick={() => {
                        if (!r.leaf) setExpanded((e) => ({ ...e, [r.id]: !r.open }));
                      }}
                    >
                      <Td className="whitespace-nowrap p-[12px_14px]" style={{ paddingLeft: 14 + r.level * 22 }}>
                        {r.assetId ? (
                          <Link href={`/assets/${r.assetId}`} className="no-underline hover:underline">
                            {nameCell}
                          </Link>
                        ) : (
                          nameCell
                        )}
                      </Td>
                      <Td className="whitespace-nowrap text-ink-600">{r.ownerLabel ?? ""}</Td>
                      <Td align="right" className={cn("whitespace-nowrap", fw)}>{r.cost == null ? "–" : money(r.cost)}</Td>
                      <Td align="right" className={cn("whitespace-nowrap", fw)}>{money(r.value)}</Td>
                      <Td className="whitespace-nowrap text-sm text-ink-600">{r.src ?? ""}</Td>
                      <Td align="right" className={cn("whitespace-nowrap", fw, (r.gl ?? 0) < 0 ? "text-neg" : "text-pos")}>
                        {r.gl == null ? "" : plMoney(r.gl)}
                      </Td>
                      <Td align="right" className="whitespace-nowrap">{r.yield ?? ""}</Td>
                      <Td className="whitespace-nowrap p-[12px_14px]">
                        {r.status ? <Pill className={STATUS_PILL[r.statusTone ?? "off"]}>{r.status}</Pill> : null}
                      </Td>
                    </tr>
                  );
                })}
              </tbody>
            </Table>
          </div>
        </div>

        <div className="flex min-w-0 flex-col gap-4">
          <div className="flex flex-col items-center gap-3 rounded-card border border-line bg-surface p-[18px_20px] shadow-card">
            <div className="self-start text-lg font-semibold">สัดส่วนทรัพย์สิน</div>
            <div
              className="flex h-[150px] w-[150px] items-center justify-center rounded-pill"
              style={{ background: "conic-gradient(#004AAD 0 48%,#0E9F6E 48% 86%,#F5A524 86% 95%,#8792A2 95% 100%)" }}
            >
              <div className="flex h-24 w-24 flex-col items-center justify-center rounded-pill bg-surface">
                <div className="text-sm text-ink-400">NAV</div>
                <div className="text-lg font-semibold">฿ 65.7M</div>
              </div>
            </div>
          </div>
          <div className="rounded-card border border-line bg-surface p-[18px_20px] shadow-card">
            <div className="mb-2 text-lg font-semibold">NAV แยกตามชื่อผู้ถือ</div>
            {NAV_BY_HOLDER.map((n) => (
              <div key={n.name} className="flex items-center gap-2.5 border-t border-line py-2.5 text-base">
                <span className="h-2.5 w-2.5 rounded-pill" style={{ background: n.color }} />
                {n.name}
                <b className="ml-auto">{n.value}</b>
              </div>
            ))}
            <div className="mt-2 border-t border-line pt-2 text-sm leading-6 text-ink-400">
              ถือในชื่อบุคคลก็ยังเป็นเงินกองกลางของ SRI Family — ตัวเลขนี้บอกแค่ว่าใครถือกรรมสิทธิ์
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
