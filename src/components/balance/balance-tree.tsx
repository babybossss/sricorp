"use client";

import * as React from "react";
import { Table, Th, Td } from "@/components/ui/table";
import { cn } from "@/lib/utils";
import { m } from "@/components/reports/parts";
import type { BalanceNode } from "@/lib/db/balance-tree";

type Row = BalanceNode & { level: number; open: boolean; leaf: boolean };

/**
 * ต้นไม้งบดุล (ด้าน → กลุ่ม → บรรทัด) — แสดงตัวเลขที่ server คำนวณจากสมุดด้วย `buildBalanceSheet()` ตัวเดียวกับหน้า /reports
 * หน้านี้ไม่คำนวณอะไร มีแค่เปิด-ปิดโหนด
 */
export function BalanceTree({ nodes }: { nodes: BalanceNode[] }) {
  const [expanded, setExpanded] = React.useState<Record<string, boolean>>(() => Object.fromEntries(nodes.map((n) => [n.id, true])));

  const rows = React.useMemo(() => {
    const out: Row[] = [];
    const walk = (list: BalanceNode[], level: number) => {
      for (const n of list) {
        const open = expanded[n.id] ?? false;
        out.push({ ...n, level, open, leaf: !n.children || n.children.length === 0 });
        if (open && n.children) walk(n.children, level + 1);
      }
    };
    walk(nodes, 0);
    return out;
  }, [nodes, expanded]);

  const setAll = (open: boolean) => {
    const all: Record<string, boolean> = {};
    const walk = (list: BalanceNode[]) => list.forEach((n) => ((all[n.id] = open), n.children && walk(n.children)));
    walk(nodes);
    setExpanded(all);
  };

  return (
    <div className="min-w-0 overflow-hidden rounded-card border border-line bg-surface shadow-card">
      <div className="flex flex-wrap items-center gap-3 border-b border-line p-[12px_18px]">
        <button type="button" onClick={() => setAll(true)} className="min-h-control rounded border border-line bg-surface px-4 text-base font-semibold hover:border-ink-400">
          เปิดทุกหัวข้อ
        </button>
        <button type="button" onClick={() => setAll(false)} className="min-h-control rounded border border-line bg-surface px-4 text-base font-semibold hover:border-ink-400">
          ปิดทุกหัวข้อ
        </button>
        <div className="text-base text-ink-600">มูลค่าตามบัญชี (ราคาทุนรวมส่วนตีราคาที่บันทึกแล้ว) — ไม่ใช่มูลค่าตลาดเรียลไทม์</div>
      </div>
      <div className="overflow-auto">
        <Table minWidth={520}>
          <thead>
            <tr>
              <Th className="p-[12px_14px]">รายการ</Th>
              <Th align="right">มูลค่าตามบัญชี (บาท)</Th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => {
              const fw = r.level === 0 ? "font-bold" : r.level === 1 ? "font-semibold" : "font-normal";
              return (
                <tr
                  key={r.id}
                  className={cn(r.level === 0 ? "bg-canvas" : "bg-surface", !r.leaf && "cursor-pointer hover:bg-brand-50")}
                  onClick={() => {
                    if (!r.leaf) setExpanded((e) => ({ ...e, [r.id]: !r.open }));
                  }}
                >
                  <Td className="p-[12px_14px] text-base" style={{ paddingLeft: 14 + r.level * 22 }}>
                    <span className={fw}>
                      {r.leaf ? "" : r.open ? "▾ " : "▸ "}
                      {r.name}
                    </span>
                    {r.note ? <div className="text-sm font-normal text-ink-600">{r.note}</div> : null}
                  </Td>
                  <Td align="right" className={cn("whitespace-nowrap text-base tabular-nums", fw, r.value < 0 && "text-neg")}>
                    {m(r.value)}
                  </Td>
                </tr>
              );
            })}
          </tbody>
        </Table>
      </div>
    </div>
  );
}
