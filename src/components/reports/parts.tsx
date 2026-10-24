import * as React from "react";
import Link from "next/link";
import { cn } from "@/lib/utils";
import { money } from "@/lib/format";

/** ตัวเลขในงบ: tabular · ติดลบใช้วงเล็บ · ศูนย์แสดง 0.00 (ไม่ใช่ขีด — งบต้องเห็นว่าเป็นศูนย์จริง) */
export const m = (n: number) => money(n, { dash: false });

export function Amount({ value, className }: { value: number; className?: string }) {
  return <span className={cn("whitespace-nowrap text-right tabular-nums", value < 0 && "text-neg", className)}>{m(value)}</span>;
}

/** การ์ดหนึ่งส่วนของงบ — เต็มความกว้างและไม่ล้นจอมือถือ (แถวพับบรรทัดได้ ไม่มีความกว้างตายตัว) */
export function Section({ title, children, tone = "plain" }: { title: string; children: React.ReactNode; tone?: "plain" | "separate" }) {
  return (
    <section
      className={cn(
        "min-w-0 rounded-card border bg-surface shadow-card",
        tone === "separate" ? "border-2 border-dashed border-warn bg-canvas" : "border-line"
      )}
    >
      <h2 className="border-b border-line p-[14px_16px] text-h2 font-semibold">{title}</h2>
      <div className="px-4 pb-2">{children}</div>
    </section>
  );
}

export function Row({
  label,
  value,
  note,
  strong,
  indent,
}: {
  label: React.ReactNode;
  value: number;
  note?: React.ReactNode;
  strong?: boolean;
  indent?: boolean;
}) {
  return (
    <div className={cn("flex items-start justify-between gap-3 border-t border-line py-3 first:border-t-0", strong && "font-semibold")}>
      <div className={cn("min-w-0 flex-1 text-base", indent && "pl-4")}>
        {label}
        {note ? <div className="text-sm font-normal text-ink-600">{note}</div> : null}
      </div>
      <Amount value={value} className="flex-none text-base" />
    </div>
  );
}

export function Notice({ tone, children }: { tone: "warn" | "neg" | "ok" | "info"; children: React.ReactNode }) {
  const cls = {
    warn: "border-warn bg-warn-bg text-warn-fg",
    neg: "border-neg bg-neg-bg text-neg-fg",
    ok: "border-pos bg-pos-bg text-pos-fg",
    info: "border-brand-100 bg-brand-50 text-ink-900",
  }[tone];
  return (
    <div role={tone === "neg" || tone === "warn" ? "alert" : undefined} className={cn("rounded border p-[12px_16px] text-base leading-7", cls)}>
      {children}
    </div>
  );
}

export const TABS = [
  { key: "bs", label: "งบแสดงฐานะการเงิน" },
  { key: "pl", label: "งบกำไรขาดทุน" },
  { key: "cf", label: "งบกระแสเงินสด" },
] as const;
export type ReportTab = (typeof TABS)[number]["key"];

export function tabHref(tab: ReportTab, year: number, owner: string) {
  return `/reports?tab=${tab}&year=${year}&owner=${encodeURIComponent(owner)}`;
}

/** แท็บ + ตัวเลือกผู้ถือ/ปี — เป็นลิงก์และฟอร์ม GET ล้วน ไม่ต้องมี JavaScript ฝั่ง browser */
export function ReportControls({
  tab,
  year,
  owner,
  years,
  owners,
}: {
  tab: ReportTab;
  year: number;
  owner: string;
  years: number[];
  owners: { id: string; name: string }[];
}) {
  const sel =
    "min-h-control w-full rounded border border-line bg-surface px-3 text-base text-ink-900 focus-visible:outline-none focus-visible:border-brand-600 focus-visible:ring-[3px] focus-visible:ring-brand-100";
  return (
    <div className="flex flex-col gap-4">
      <nav aria-label="เลือกงบ" className="flex flex-wrap gap-2">
        {TABS.map((t) => (
          <Link
            key={t.key}
            href={tabHref(t.key, year, owner)}
            aria-current={tab === t.key ? "page" : undefined}
            className={cn(
              "inline-flex min-h-control items-center rounded border px-4 text-base font-semibold no-underline hover:no-underline",
              "focus-visible:outline-none focus-visible:ring-[3px] focus-visible:ring-brand-600",
              tab === t.key ? "border-brand-600 bg-brand-600 text-white" : "border-line bg-surface text-ink-900 hover:border-ink-400"
            )}
          >
            {t.label}
          </Link>
        ))}
      </nav>
      <form method="get" action="/reports" className="flex flex-wrap items-end gap-3 rounded-card border border-line bg-surface p-4 shadow-card">
        <input type="hidden" name="tab" value={tab} />
        <label className="flex min-w-[220px] flex-1 flex-col gap-1.5">
          <span className="text-sm text-ink-600">ผู้ถือกรรมสิทธิ์</span>
          <select name="owner" defaultValue={owner} className={sel}>
            <option value="family">SRI Family (รวมทุกชื่อ)</option>
            {owners.map((o) => (
              <option key={o.id} value={o.id}>
                {o.name}
              </option>
            ))}
          </select>
        </label>
        <label className="flex min-w-[160px] flex-col gap-1.5">
          <span className="text-sm text-ink-600">ปีบัญชี (ม.ค.–ธ.ค.)</span>
          <select name="year" defaultValue={String(year)} className={sel}>
            {years.map((y) => (
              <option key={y} value={y}>
                {y}
              </option>
            ))}
          </select>
        </label>
        <button
          type="submit"
          className="inline-flex min-h-control items-center justify-center rounded border border-brand-600 bg-brand-600 px-[22px] text-base font-semibold text-white hover:bg-brand-700 focus-visible:outline-none focus-visible:ring-[3px] focus-visible:ring-brand-600 focus-visible:ring-offset-2"
        >
          แสดงงบ
        </button>
      </form>
    </div>
  );
}
