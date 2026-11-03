import type { Tag, TagKind } from "@/components/tags/types";
import type { TagCatalog } from "./selection";

/**
 * ชนิด tag ไหน "ประตูบันทึก (fn_post_entry) รับได้จริงตอนนี้" — ตรรกะบริสุทธิ์ ไม่แตะ DB
 *
 * รายชื่อชนิดที่รับได้ **อ่านจากเซิร์ฟเวอร์** (ดู `src/lib/db/tag-gate-server.ts`) ห้ามเขียนรายชื่อตายตัวไว้ที่นี่หรือในฟอร์ม
 * ไม่งั้นวันที่ประตูรับชนิดใหม่ได้ ฟอร์มจะยังซ่อนอยู่โดยไม่มีใครรู้
 *
 * ทางถอยที่ปลอดภัย: อ่านรายชื่อไม่ได้ (`accepted = null`) = **ซ่อนทุกชนิด** ไม่ใช่โชว์แล้วไปตายตอนกดบันทึก
 * (ประตูปฏิเสธทั้งใบ = ผู้ใช้เสียงานที่กรอกมาทั้งใบ — เปิดครึ่งเดียวอันตรายกว่าไม่เปิด)
 */

export type HiddenKindReason =
  /** อ่านรายชื่อชนิดที่ประตูรับไม่ได้ จึงไม่รู้ว่ารับหรือยัง */
  | "unreadable"
  /** อ่านได้ และประตูยังไม่รับชนิดนี้ */
  | "not_open";

export type HiddenKind = { key: string; nameTh: string; reason: HiddenKindReason };

/**
 * แปลงคำตอบดิบของ DB เป็นเซตของรหัสชนิด · รูปที่รับ: `["project", ...]` หรือ `{ kinds: ["project", ...] }`
 * รูปอื่น/ค่าที่ไม่ใช่ข้อความ/ข้อความว่าง = อ่านไม่ได้ (`null`) · **ไม่เดา** และไม่คืนเซตว่างแทน
 * (เซตว่างที่ "อ่านได้" หมายถึงประตูยังไม่รับชนิดไหนเลย ซึ่งต่างจาก "อ่านไม่ได้" ในข้อความที่บอกผู้ใช้)
 */
export function parseAcceptedKinds(data: unknown): ReadonlySet<string> | null {
  const list = Array.isArray(data)
    ? data
    : data && typeof data === "object" && Array.isArray((data as { kinds?: unknown }).kinds)
      ? (data as { kinds: unknown[] }).kinds
      : null;
  if (!list) return null;
  const out = new Set<string>();
  for (const k of list) {
    if (typeof k !== "string" || k.trim() === "") return null;
    out.add(k);
  }
  return out;
}

/** แยกแค็ตตาล็อกเป็น "ชนิดที่เลือกได้" กับ "ชนิดที่ซ่อน (พร้อมเหตุ)" */
export function splitByAcceptance(
  catalog: TagCatalog,
  accepted: ReadonlySet<string> | null
): { catalog: { kinds: TagKind[]; tags: Tag[] }; hidden: HiddenKind[] } {
  const open = (key: string) => accepted !== null && accepted.has(key);
  const kinds = catalog.kinds.filter((k) => open(k.key));
  const tags = catalog.tags.filter((t) => open(t.kind));
  const hidden: HiddenKind[] = catalog.kinds
    .filter((k) => !open(k.key))
    .map((k) => ({ key: k.key, nameTh: k.nameTh, reason: accepted === null ? "unreadable" : "not_open" }));
  return { catalog: { kinds: [...kinds], tags: [...tags] }, hidden };
}

/** ชนิดของ tag ที่เลือกมา ซึ่งประตูไม่รับ (ใช้ที่ server ก่อนส่งเข้า fn_post_entry) */
export function refusedKinds(tagIds: readonly string[], catalog: TagCatalog, accepted: ReadonlySet<string> | null): HiddenKind[] {
  const byId = new Map(catalog.tags.map((t) => [t.id, t]));
  const nameOf = new Map(catalog.kinds.map((k) => [k.key, k.nameTh]));
  const seen = new Set<string>();
  const out: HiddenKind[] = [];
  for (const id of tagIds) {
    const t = byId.get(id);
    if (!t || seen.has(t.kind)) continue;
    seen.add(t.kind);
    if (accepted !== null && accepted.has(t.kind)) continue;
    out.push({ key: t.kind, nameTh: nameOf.get(t.kind) ?? t.kind, reason: accepted === null ? "unreadable" : "not_open" });
  }
  return out;
}

/** ข้อความภาษาคนบอกว่าทำไมยังใช้ไม่ได้ และจะใช้ได้เมื่อไร (ฟอร์มกับ server ใช้ข้อความชุดเดียวกัน) */
export function hiddenKindsMessage(hidden: readonly HiddenKind[]): string {
  if (hidden.length === 0) return "";
  const names = hidden.map((h) => `"${h.nameTh}"`).join(" และ ");
  const unreadable = hidden.some((h) => h.reason === "unreadable");
  const why = unreadable
    ? "ตอนนี้ระบบตรวจไม่ได้ว่าฐานข้อมูลพร้อมรับ tag ชนิดนี้แล้วหรือยัง จึงปิดไว้ก่อน เพื่อไม่ให้กรอกมาทั้งใบแล้วบันทึกไม่ผ่าน"
    : "ฐานข้อมูลยังไม่พร้อมรับ tag ชนิดนี้ (อยู่ระหว่างอัปเดตระบบ) จึงปิดไว้ก่อน เพื่อไม่ให้กรอกมาทั้งใบแล้วบันทึกไม่ผ่าน";
  return `tag ชนิด ${names} ยังเลือกไม่ได้ในตอนนี้ — ${why} · จะกลับมาให้เลือกเองเมื่อผู้ดูแลระบบอัปเดตฐานข้อมูลเสร็จ ไม่ต้องทำอะไรเพิ่ม · ลงรายการโดยไม่ติด tag ชนิดนี้ได้ตามปกติ`;
}
