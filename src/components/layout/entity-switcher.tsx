"use client";

import * as React from "react";
import * as Popover from "@radix-ui/react-popover";
import { useApp } from "@/lib/store";
import { ENTITIES, entityById } from "@/lib/mock/entities";
import { cn } from "@/lib/utils";

/**
 * ทุกอย่างเป็นกองกลาง SRI Family — switcher นี้เลือก "ผู้ถือกรรมสิทธิ์" ที่จะกรอง
 * ไม่ใช่การแยกกระเป๋าเงินคนละใบ ค่าเริ่มต้นจึงเป็นมุมมองรวม
 */
export function EntitySwitcher() {
  const entityId = useApp((s) => s.entityId);
  const setEntityId = useApp((s) => s.setEntityId);
  const [open, setOpen] = React.useState(false);
  const current = entityById(entityId);

  return (
    <Popover.Root open={open} onOpenChange={setOpen}>
      <Popover.Trigger className="flex min-h-control items-center gap-2.5 rounded border border-line bg-surface px-[14px] text-base text-ink-900 hover:border-ink-400">
        <span className="h-3 w-3 flex-none rounded-pill" style={{ background: current.color }} />
        {current.name}
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" className="h-[18px] w-[18px] text-ink-400">
          <path d="m6 9 6 6 6-6" />
        </svg>
      </Popover.Trigger>
      <Popover.Portal>
        <Popover.Content
          align="end"
          sideOffset={6}
          className="z-[30] w-[300px] animate-fadein rounded-card border border-line bg-surface p-2 shadow-pop"
        >
          {ENTITIES.map((e) => (
            <div key={e.id}>
              {e.group ? <div className="p-[10px_12px_4px] text-sm text-ink-400">{e.group}</div> : null}
              <button
                onClick={() => {
                  setEntityId(e.id);
                  setOpen(false);
                }}
                className={cn(
                  "flex min-h-[48px] w-full items-center gap-2.5 rounded-lg px-3 text-left text-base text-ink-900 hover:bg-canvas",
                  e.id === entityId && "bg-brand-50"
                )}
              >
                <span className="h-2.5 w-2.5 flex-none rounded-pill" style={{ background: e.color }} />
                {e.name}
              </button>
            </div>
          ))}
        </Popover.Content>
      </Popover.Portal>
    </Popover.Root>
  );
}
