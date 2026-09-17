"use client";

import * as React from "react";
import { useApp, useOrderedBanks } from "@/lib/store";
import { entityById } from "@/lib/mock/entities";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { cn } from "@/lib/utils";

export function BankSettings() {
  const bankOff = useApp((s) => s.bankOff);
  const moveBank = useApp((s) => s.moveBank);
  const toggleBank = useApp((s) => s.toggleBank);
  const ordered = useOrderedBanks();

  // ช่องติ๊ก "แสดงบัญชีที่ปิดใช้งาน" เป็น state ของหน้า ไม่ใช่ config ที่ต้องจำ
  const [showInactive, setShowInactive] = React.useState(true);
  const visible = showInactive ? ordered : ordered.filter((b) => !bankOff[b.id]);

  return (
    <>
      <div className="flex flex-wrap items-center gap-4">
        <label className="flex min-h-control items-center gap-2.5 text-base">
          <Checkbox checked={showInactive} onChange={(e) => setShowInactive(e.target.checked)} className="h-6 w-6" />
          แสดงบัญชีที่ปิดใช้งาน
        </label>
        <div className="text-sm text-ink-600">ลำดับนี้คือลำดับที่แสดงในตัวเลือกบัญชีทุกฟอร์ม</div>
        <Button className="ml-auto">+ เพิ่มบัญชี</Button>
      </div>

      <div className="flex flex-col gap-3">
        {visible.map((b, i) => {
          const off = bankOff[b.id];
          const holder = entityById(b.ownerId);
          return (
            <div
              key={b.id}
              className={cn("flex flex-wrap items-center gap-4 rounded-card border border-line bg-surface p-[16px_20px] shadow-card", off && "opacity-55")}
            >
              <div className="flex flex-none items-center gap-2">
                <div className="flex flex-col">
                  <button
                    onClick={() => moveBank(b.id, -1)}
                    disabled={i === 0}
                    aria-label={`เลื่อน ${b.name} ขึ้น`}
                    className="flex h-[26px] w-9 items-center justify-center rounded-t-md border border-line bg-surface text-ink-600 hover:border-brand-600 hover:text-brand-600 disabled:opacity-40 disabled:hover:border-line disabled:hover:text-ink-600"
                  >
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="h-4 w-4">
                      <path d="m18 15-6-6-6 6" />
                    </svg>
                  </button>
                  <button
                    onClick={() => moveBank(b.id, 1)}
                    disabled={i === visible.length - 1}
                    aria-label={`เลื่อน ${b.name} ลง`}
                    className="flex h-[26px] w-9 items-center justify-center rounded-b-md border border-t-0 border-line bg-surface text-ink-600 hover:border-brand-600 hover:text-brand-600 disabled:opacity-40 disabled:hover:border-line disabled:hover:text-ink-600"
                  >
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="h-4 w-4">
                      <path d="m6 9 6 6 6-6" />
                    </svg>
                  </button>
                </div>
                <div className="w-6 text-right text-sm text-ink-400">{i + 1}.</div>
              </div>

              <div
                className="flex h-[52px] w-[52px] flex-none items-center justify-center rounded text-sm font-bold text-white"
                style={{ background: b.color }}
              >
                {b.short}
              </div>

              <div className="min-w-[180px]">
                <div className="text-lg font-semibold">{b.name}</div>
                <div className="text-sm text-ink-600">
                  {b.bank} · เลขท้าย {b.last4}
                </div>
              </div>

              <div className="min-w-[150px]">
                <div className="text-sm text-ink-400">ถือในชื่อ</div>
                <div className="flex items-center gap-1.5 text-base">
                  <span className="h-2.5 w-2.5 rounded-pill" style={{ background: holder.color }} />
                  {holder.name}
                </div>
              </div>

              <div className="min-w-[160px] text-right">
                <div className="text-sm text-ink-400">ยอดตั้งต้น</div>
                <div className="text-base font-semibold">{b.opening}</div>
              </div>

              <div className="ml-auto flex flex-wrap items-center gap-3">
                <div className="max-w-[220px] text-sm text-ink-600">{off ? "ซ่อนจากตัวเลือก ยังอยู่ในรายงานย้อนหลัง" : ""}</div>
                <button
                  onClick={() => toggleBank(b.id)}
                  aria-label={`${off ? "เปิด" : "ปิด"}ใช้งานบัญชี ${b.name}`}
                  aria-pressed={!off}
                  className={cn("relative h-9 w-16 rounded-pill", off ? "bg-line" : "bg-pos")}
                >
                  <span
                    className="absolute top-1 h-7 w-7 rounded-pill bg-white transition-[left] duration-150"
                    style={{ left: off ? 4 : 32 }}
                  />
                </button>
                <div className={cn("w-[72px] text-sm font-semibold", off ? "text-ink-400" : "text-pos-fg")}>{off ? "ปิดใช้งาน" : "ใช้งาน"}</div>
                <Button variant="secondary" size="sm">แก้ไขชื่อ</Button>
              </div>
            </div>
          );
        })}
      </div>
    </>
  );
}
