import * as React from "react";
import { Pill } from "@/components/ui/pill";
import { cn } from "@/lib/utils";
import type { AssetDraft, AssetRef } from "@/lib/mock/assets";
import { computeDiff, type DiffChange } from "./asset-drafts";

const CHANGE: Record<DiffChange, { label: string; tone: string }> = {
  changed: { label: "แก้ค่า", tone: "border-brand-100 bg-brand-50 text-brand-700" },
  added: { label: "เพิ่มค่าใหม่", tone: "border-pos bg-pos-bg text-pos-fg" },
  cleared: { label: "ลบค่าออก", tone: "border-neg bg-neg-bg text-neg-fg" },
  unchanged: { label: "ไม่เปลี่ยน", tone: "border-line bg-canvas text-ink-600" },
};

const EMPTY = "(ว่าง — ไม่มีค่า)";

/**
 * แผงเทียบความต่างของร่างชนิดแก้ไข: **ช่องไหน เปลี่ยนจากอะไร เป็นอะไร**
 *
 * ผู้อนุมัติต้องเห็นของเดิมเทียบของใหม่ — ไม่งั้นเท่ากับอนุมัติโดยไม่เห็นของเดิม
 * - ของเดิมมาจากทรัพย์จริงตอนนี้ (`asset`) ไม่ใช่สำเนาในร่าง
 * - ช่องที่ **ลบค่าออก** แสดงของเดิมเต็มๆ + ป้าย "ลบค่าออก" + ฝั่งใหม่ว่าง (ไม่ซ่อนแถวนั้น)
 * - ความต่างไม่พึ่งสีอย่างเดียว: มีป้ายข้อความ + คำว่า "เดิม"/"ใหม่" ทุกแถว
 * - ช่องที่ร่างไม่ได้พูดถึง = ไม่แตะ (ไม่โชว์) · ช่องที่เสนอค่าเท่าเดิมโชว์แยกว่า "ไม่เปลี่ยน"
 */
export function DiffPanel({ draft, asset }: { draft: AssetDraft; asset: AssetRef | undefined }) {
  const diff = computeDiff(draft, asset);
  const changed = diff.rows.filter((r) => r.change !== "unchanged");
  const unchanged = diff.rows.filter((r) => r.change === "unchanged");

  return (
    <section aria-label="เทียบของเดิมกับของใหม่" data-testid="diff-panel" className="flex flex-col gap-3">
      <div className="text-base font-semibold">
        เทียบของเดิมกับของใหม่
        {asset ? <span className="font-normal text-ink-600"> · ทรัพย์ {asset.name}</span> : null}
      </div>

      {diff.targetMissing ? (
        <Alert>ไม่พบทรัพย์ที่ร่างนี้จะแก้ในทะเบียน — ไม่มีของเดิมให้เทียบ จึงอนุมัติไม่ได้</Alert>
      ) : null}
      {diff.isEmpty ? <Alert>ร่างนี้ไม่มีช่องที่เสนอแก้เลย — ไม่มีอะไรให้อนุมัติ</Alert> : null}
      {diff.unknownKeys.length ? (
        <Alert>
          ร่างนี้มีช่องที่ระบบไม่รู้จัก: <b>{diff.unknownKeys.join(", ")}</b> — ไม่แสดงในตารางเทียบ
          ตรวจกับผู้สร้างร่างก่อนอนุมัติ
        </Alert>
      ) : null}

      {changed.length ? (
        <ul className="m-0 flex list-none flex-col gap-2.5 p-0">
          {changed.map((r) => (
            <li
              key={r.key}
              data-testid={`diff-row-${r.key}`}
              data-change={r.change}
              className="flex flex-col gap-2 rounded-card border border-line bg-canvas p-[12px_14px]"
            >
              <div className="flex flex-wrap items-center gap-2">
                <span className="mr-auto text-base font-semibold">{r.label}</span>
                <Pill className={cn("whitespace-nowrap", CHANGE[r.change].tone)}>{CHANGE[r.change].label}</Pill>
              </div>
              <div className="grid gap-2 sm:grid-cols-2">
                <Side title="เดิม" value={r.before} struck={r.change === "cleared"} />
                <Side title="ใหม่" value={r.after} />
              </div>
            </li>
          ))}
        </ul>
      ) : null}

      {unchanged.length ? (
        <div className="text-base text-ink-600" data-testid="diff-unchanged">
          ร่างเสนอค่าเท่าเดิม (ไม่มีผล): {unchanged.map((r) => r.label).join(" · ")}
        </div>
      ) : null}
    </section>
  );
}

function Side({ title, value, struck }: { title: string; value: string | null; struck?: boolean }) {
  return (
    <div className="flex flex-col rounded border border-line bg-surface p-[8px_12px]">
      <span className="text-sm text-ink-600">{title}</span>
      {value === null ? (
        <span className="text-base text-ink-600">{EMPTY}</span>
      ) : (
        <span className={cn("break-words text-base font-semibold tabular-nums", struck && "line-through decoration-neg")}>
          {value}
        </span>
      )}
    </div>
  );
}

function Alert({ children }: { children: React.ReactNode }) {
  return (
    <div role="alert" className="rounded border border-neg bg-neg-bg p-[12px_14px] text-base leading-7 text-neg-fg">
      {children}
    </div>
  );
}
