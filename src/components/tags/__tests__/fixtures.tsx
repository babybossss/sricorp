import type { Tag, TagKind } from "../types";

export const KINDS: TagKind[] = [
  { key: "project", nameTh: "โปรเจกต์", allowsMulti: true, aggregateNoteTh: "note-project", requiresAllocation: true },
  { key: "label", nameTh: "ป้ายกำกับ", allowsMulti: true, aggregateNoteTh: "note-label" },
];

export const tag = (id: string, kind: string, nameTh: string, over: Partial<Tag> = {}): Tag => ({
  id,
  kind,
  code: id,
  nameTh,
  isActive: true,
  colorToken: null,
  ...over,
});

export const IRIS = tag("t-iris", "project", "ไอริส 235", { colorToken: "brand" });
export const RENO = tag("t-reno", "project", "รีโนเวต 2026", { colorToken: "pos" });
export const OLD = tag("t-old", "project", "โครงการเก่า", { isActive: false });
export const URGENT = tag("t-urgent", "label", "เร่งด่วน", { colorToken: "warn" });

/** ข้อความที่ผู้ใช้เห็น (ตัดแท็ก) */
export const visibleText = (html: string) => html.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim();

/** ทุก <button> ใน HTML ต้องมีข้อความที่มองเห็น/อ่านออกเสียงได้ — ห้ามปุ่มไอคอนเดี่ยว */
export function buttonLabels(html: string): string[] {
  return [...html.matchAll(/<button\b[^>]*>([\s\S]*?)<\/button>/g)].map((m) => visibleText(m[1]));
}
