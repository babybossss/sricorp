"use client";

import * as React from "react";
import { Checkbox } from "@/components/ui/checkbox";
import { cn } from "@/lib/utils";
import { toneClass } from "./tag-chip";
import type { Tag, TagKind } from "./types";

/**
 * ตัวเลือก tag = รายการติ๊กจากแค็ตตาล็อก (ADR 0002 หัวข้อ 7)
 *
 * - **ไม่มีช่องพิมพ์อิสระ** สร้าง tag ได้ที่หน้าตั้งค่าโดยสิทธิ์ `tag.catalog` เท่านั้น
 *   (พิมพ์ได้ = `ไอริส235` กับ `iris-235` กลับมา)
 * - แยกกลุ่มตามชนิด · ชื่อกลุ่มอ่านจาก `kinds` (tag_kinds) ไม่พิมพ์ในหน้าจอ
 * - tag ที่ปิดใช้งานแล้ว **ไม่โผล่ให้เลือกใหม่** แต่ถ้าถูกเลือกอยู่ ยังแสดง (พร้อมป้ายบอก) ให้เอาออกได้
 *   หายเงียบๆ = ผู้ใช้ไม่รู้ว่าใบนี้ยังติด tag นั้นอยู่
 * - id ที่เลือกไว้แต่ไม่อยู่ในแค็ตตาล็อก แสดงเป็นแถว "ไม่พบ tag" ให้เอาออกได้ ไม่ทิ้งเงียบ
 * - ชนิดที่ `allowsMulti = false` เลือกอันใหม่ = แทนอันเดิมของชนิดนั้น
 */

export type TagPickerProps = {
  catalog: readonly Tag[];
  kinds: readonly TagKind[];
  selectedIds: readonly string[];
  onChange: (next: string[]) => void;
  label?: string;
  disabled?: boolean;
  className?: string;
};

/** ผลของการติ๊ก/เอาติ๊กออก — แยกเป็นฟังก์ชันล้วนเพื่อเทสต์ได้โดยไม่ต้องมี DOM */
export function selectionAfterToggle(
  tag: Pick<Tag, "id" | "kind">,
  checked: boolean,
  selectedIds: readonly string[],
  catalog: readonly Pick<Tag, "id" | "kind">[],
  kinds: readonly Pick<TagKind, "key" | "allowsMulti">[]
): string[] {
  if (!checked) return selectedIds.filter((id) => id !== tag.id);
  if (selectedIds.includes(tag.id)) return [...selectedIds];
  const kind = kinds.find((k) => k.key === tag.kind);
  const kindOf = new Map(catalog.map((t) => [t.id, t.kind]));
  const keep = kind && !kind.allowsMulti ? selectedIds.filter((id) => kindOf.get(id) !== tag.kind) : [...selectedIds];
  return [...keep, tag.id];
}

export function TagPicker({ catalog, kinds, selectedIds, onChange, label = "tag ของรายการนี้", disabled, className }: TagPickerProps) {
  const uid = React.useId();
  const selected = new Set(selectedIds);
  const byId = new Map(catalog.map((t) => [t.id, t]));

  // แถวที่แสดง: tag ที่ใช้งานอยู่ทั้งหมด + tag ที่ปิดแล้วเฉพาะที่ถูกเลือกอยู่
  const visible = catalog.filter((t) => t.isActive || selected.has(t.id));
  const unknownIds = selectedIds.filter((id) => !byId.has(id));

  // จัดกลุ่มตามลำดับของ kinds · ชนิดที่ไม่อยู่ใน kinds ต่อท้าย (ไม่ทิ้ง tag)
  const groups: { kind: TagKind | null; key: string; tags: Tag[] }[] = [];
  for (const k of kinds) {
    const tags = visible.filter((t) => t.kind === k.key);
    if (tags.length > 0) groups.push({ kind: k, key: k.key, tags });
  }
  const knownKeys = new Set(kinds.map((k) => k.key));
  for (const t of visible) {
    if (knownKeys.has(t.kind)) continue;
    const g = groups.find((x) => x.key === t.kind);
    if (g) g.tags.push(t);
    else groups.push({ kind: null, key: t.kind, tags: [t] });
  }

  function toggle(tag: Tag, checked: boolean) {
    onChange(selectionAfterToggle(tag, checked, selectedIds, catalog, kinds));
  }

  const hasActive = catalog.some((t) => t.isActive);
  if (!hasActive && visible.length === 0 && unknownIds.length === 0) {
    return (
      <div className={cn("rounded border border-line bg-canvas p-[14px_16px] text-base text-ink-600", className)} data-testid="tag-picker-empty">
        ยังไม่มี tag — ไปตั้งที่หน้าตั้งค่า
      </div>
    );
  }

  return (
    <div className={cn("flex min-w-0 flex-col gap-4", className)}>
      <span className="text-base font-semibold text-ink-900">{label}</span>

      {groups.map((g) => {
        const single = g.kind ? !g.kind.allowsMulti : false;
        return (
          <fieldset key={g.key} className="m-0 flex min-w-0 flex-col gap-2 border-0 p-0" disabled={disabled}>
            <legend className="mb-2 p-0 text-base font-semibold text-ink-900">
              {g.kind?.nameTh ?? g.key}
              <span className="ml-2 text-sm font-normal text-ink-600">{single ? "เลือกได้อันเดียว" : "เลือกได้หลายอัน"}</span>
            </legend>
            {g.tags.map((tag) => {
              const checked = selected.has(tag.id);
              const id = `${uid}-${tag.id}`;
              return (
                <label
                  key={tag.id}
                  htmlFor={id}
                  className={cn(
                    "flex min-h-control cursor-pointer items-center gap-3 rounded border p-[10px_14px] text-base max-sm:min-h-control-mobile",
                    checked ? "border-brand-600 bg-brand-50" : "border-line bg-surface hover:border-ink-400",
                    disabled && "cursor-not-allowed opacity-60"
                  )}
                >
                  <Checkbox id={id} checked={checked} disabled={disabled} onChange={(e) => toggle(tag, e.target.checked)} />
                  <span className="flex min-w-0 flex-1 flex-col">
                    <span className="flex items-start gap-2 break-words font-semibold text-ink-900">
                      {/* จุดสีประจำ tag (สีตัวอักษรของโทเคน) — ซ้ำกับชื่อเสมอ ไม่ใช้สีอย่างเดียวสื่อความหมาย */}
                      <span aria-hidden="true" className={cn("mt-2 inline-block h-3 w-3 flex-none rounded-pill border", toneClass(tag.colorToken), "bg-current")} />
                      <span className="min-w-0">{tag.nameTh}</span>
                    </span>
                    {!tag.isActive ? (
                      <span className="text-sm font-normal text-ink-600">ปิดใช้งานแล้ว — เอาออกได้ แต่เลือกกลับมาไม่ได้</span>
                    ) : null}
                  </span>
                </label>
              );
            })}
          </fieldset>
        );
      })}

      {unknownIds.length > 0 ? (
        <fieldset className="m-0 flex min-w-0 flex-col gap-2 border-0 p-0" disabled={disabled}>
          <legend className="mb-2 p-0 text-base font-semibold text-neg-fg">ไม่พบ tag ในแค็ตตาล็อก</legend>
          {unknownIds.map((uidTag) => {
            const id = `${uid}-unknown-${uidTag}`;
            return (
              <label
                key={uidTag}
                htmlFor={id}
                className="flex min-h-control cursor-pointer items-center gap-3 rounded border border-neg bg-neg-bg p-[10px_14px] text-base max-sm:min-h-control-mobile"
              >
                <Checkbox id={id} checked disabled={disabled} onChange={() => onChange(selectedIds.filter((x) => x !== uidTag))} />
                <span className="min-w-0 break-words text-neg-fg">
                  tag นี้ไม่อยู่ในแค็ตตาล็อก (<span className="tabular-nums">{uidTag}</span>) — ติ๊กออกเพื่อเอาออกจากรายการ
                </span>
              </label>
            );
          })}
        </fieldset>
      ) : null}
    </div>
  );
}
