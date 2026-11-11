import * as React from "react";
import { Pill } from "@/components/ui/pill";
import { cn } from "@/lib/utils";
import { money } from "@/lib/format";
import { isClosedStatus, statusLabel } from "@/lib/db/assets-model";
import type { RefOwner } from "@/lib/db/reference-types";

/** จุดสีประจำผู้ถือ + ชื่อ — สีมาจากข้อมูลผู้ถือใน DB (`owners.color`) ไม่ใช่สีที่ฝังในโค้ด */
export function OwnerDot({ owner }: { owner: Pick<RefOwner, "name" | "color"> | undefined }) {
  return (
    <span className="inline-flex items-center gap-1.5 whitespace-nowrap">
      <span className="h-2.5 w-2.5 flex-none rounded-pill bg-holder-group" style={owner?.color ? { background: owner.color } : undefined} />
      {owner?.name ?? "ไม่ทราบผู้ถือ"}
    </span>
  );
}

export function StatusChip({ status }: { status: string }) {
  const tone = status === "active" ? "border-pos bg-pos-bg text-pos-fg" : isClosedStatus(status) ? "border-neg bg-neg-bg text-neg-fg" : "border-line bg-canvas text-ink-600";
  return <Pill className={cn("whitespace-nowrap", tone)}>{statusLabel(status)}</Pill>;
}

export function TagChips({ tags }: { tags: readonly string[] }) {
  if (tags.length === 0) return null;
  return (
    <span className="inline-flex flex-wrap gap-1.5">
      {tags.map((t) => (
        <Pill key={t} className="whitespace-nowrap border-brand-100 bg-brand-50 text-brand-700">
          {t}
        </Pill>
      ))}
    </span>
  );
}

export const NO_LEDGER_ACCESS = "ไม่มีสิทธิ์ดู";

/** ผู้ดูไม่มี `ledger.read` — ตัวเลขเงินทุกช่องเป็น "ไม่มีสิทธิ์ดู" ไม่ใช่ 0 */
export const NO_LEDGER_NOTE =
  "ตำแหน่งของคุณไม่มีสิทธิ์อ่านสมุดบัญชี จึงไม่แสดงตัวเลขเงินของทรัพย์ (ต้นทุน ค่าซ่อม รายได้) — ช่องที่ขึ้นว่า “ไม่มีสิทธิ์ดู” ไม่ได้แปลว่าเป็นศูนย์";

/**
 * ตัวเลขเงินของทรัพย์ — `null` (ไม่มีสิทธิ์อ่านสมุด) แสดงเป็นข้อความ ไม่ใช่ 0
 * ศูนย์จริงแสดง 0.00 · ติดลบใช้วงเล็บ (Style Guide)
 */
export function Money({ value, className }: { value: number | null | undefined; className?: string }) {
  if (value === null || value === undefined) return <span className={cn("text-sm text-ink-600", className)}>{NO_LEDGER_ACCESS}</span>;
  return <span className={cn("whitespace-nowrap tabular-nums", value < 0 && "text-neg-fg", className)}>{money(value, { dash: false })}</span>;
}

export function Notice({ tone, children, className }: { tone: "warn" | "neg" | "ok" | "info"; children: React.ReactNode; className?: string }) {
  const cls = {
    warn: "border-warn bg-warn-bg text-warn-fg",
    neg: "border-neg bg-neg-bg text-neg-fg",
    ok: "border-pos bg-pos-bg text-pos-fg",
    info: "border-brand-100 bg-brand-50 text-ink-900",
  }[tone];
  return (
    <div role={tone === "neg" || tone === "warn" ? "alert" : "note"} className={cn("rounded border p-[12px_16px] text-base leading-7", cls, className)}>
      {children}
    </div>
  );
}

/** กล่อง "ระบบจะบันทึกให้ดังนี้" — ต้องขึ้นก่อนปุ่มยืนยันทุกฟอร์ม */
export function WillSave({ title = "ระบบจะบันทึกให้ดังนี้", items }: { title?: string; items: React.ReactNode[] }) {
  return (
    <section aria-label={title} data-testid="will-save" className="rounded-card border border-brand-100 bg-brand-50 p-[14px_16px]">
      <div className="text-base font-semibold">{title}</div>
      <ul className="m-0 mt-1.5 flex list-disc flex-col gap-1 pl-5 text-base leading-7">
        {items.map((it, i) => (
          <li key={i}>{it}</li>
        ))}
      </ul>
    </section>
  );
}
