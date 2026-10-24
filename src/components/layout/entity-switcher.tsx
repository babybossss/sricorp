"use client";

import * as React from "react";
import * as Popover from "@radix-ui/react-popover";
import { useApp } from "@/lib/store";
import { useReference } from "@/components/reference/reference-provider";
import { FAMILY_VIEW } from "@/lib/db/reference-types";
import { cn } from "@/lib/utils";

/**
 * ทุกอย่างเป็นกองกลาง SRI Family — switcher นี้เลือก "ผู้ถือกรรมสิทธิ์" ที่จะกรอง
 * ไม่ใช่การแยกกระเป๋าเงินคนละใบ ค่าเริ่มต้นจึงเป็นมุมมองรวม
 *
 * รายชื่อมาจาก `sri_os.owners` จริง · "มุมมองรวม" เป็นค่าพิเศษ (`FAMILY_VIEW`) ไม่ใช่ผู้ถือใน DB
 * ผู้ถือที่ยังเป็น 'planned' (นิติบุคคลที่ยังไม่จดทะเบียน) ไม่โชว์ — ซ่อนจากรายงานตามที่ schema ตั้งใจ
 */
export function EntitySwitcher() {
  const entityId = useApp((s) => s.entityId);
  const setEntityId = useApp((s) => s.setEntityId);
  const [open, setOpen] = React.useState(false);
  const { owners } = useReference();
  const visible = owners.filter((o) => o.status === "active");
  const family = { id: FAMILY_VIEW, name: "SRI Family (รวมทุกชื่อ)", color: null as string | null, group: "กองกลางครอบครัว" };
  const entities = [
    family,
    ...visible.map((o, i) => ({
      id: o.id,
      name: o.name,
      color: o.color,
      group:
        i === 0
          ? o.policy === "corporate_strict"
            ? "ถือในชื่อนิติบุคคล"
            : "ถือในชื่อบุคคล (ยังเป็นกองกลาง)"
          : o.policy !== visible[i - 1].policy
          ? o.policy === "corporate_strict"
            ? "ถือในชื่อนิติบุคคล"
            : "ถือในชื่อบุคคล (ยังเป็นกองกลาง)"
          : undefined,
    })),
  ];
  // ค่าที่เลือกไว้ไม่อยู่ในรายการ (เช่น ผู้ถือถูกซ่อนไปแล้ว) = กลับไปมุมมองรวม ไม่ throw
  const current = entities.find((e) => e.id === entityId) ?? family;

  return (
    <Popover.Root open={open} onOpenChange={setOpen}>
      <Popover.Trigger className="flex min-h-control items-center gap-2.5 rounded border border-line bg-surface px-[14px] text-base text-ink-900 hover:border-ink-400">
        <span className="h-3 w-3 flex-none rounded-pill bg-holder-group" style={current.color ? { background: current.color } : undefined} />
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
          {entities.map((e) => (
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
                <span className="h-2.5 w-2.5 flex-none rounded-pill bg-holder-group" style={e.color ? { background: e.color } : undefined} />
                {e.name}
              </button>
            </div>
          ))}
        </Popover.Content>
      </Popover.Portal>
    </Popover.Root>
  );
}
