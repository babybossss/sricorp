import type { Tag, TagKind, TagWeights } from "@/components/tags/types";
import { checkWeights, type CheckedWeights } from "./weights";

/**
 * ตรวจ "ชุด tag + น้ำหนัก" ที่ผู้ใช้เลือกบนใบหนึ่ง กับแค็ตตาล็อกจริง — ตรรกะบริสุทธิ์ ไม่แตะ DB
 *
 * ที่เดียวที่ตัดสินว่าชุดนี้ "บันทึกได้ไหม" — ทั้งปุ่มบันทึกในฟอร์ม และ server action เรียกฟังก์ชันเดียวกันนี้
 * (บทเรียนข้อ 5-6: ปุ่มต้องถามตัวตรวจจริง ไม่ใช่ถามรายการช่องที่ฟอร์มรู้จัก)
 *
 * ชนิดไหนต้องถ่วงน้ำหนักอ่านจาก `kind.requiresAllocation` (config) — **ห้ามเช็คชื่อ 'project' ตรงๆ**
 */

export type TagCatalog = { kinds: readonly TagKind[]; tags: readonly Tag[] };

export type TagSelection = {
  tagIds: readonly string[];
  weights?: Record<string, unknown> | null;
};

export type AllocationGroup = { kind: string; tags: Tag[]; weights: CheckedWeights };

export type SelectionCheck =
  | {
      ok: true;
      /** ชนิดที่ไม่ถ่วงน้ำหนัก → `fn_post_entry.tag_ids` */
      labelTagIds: string[];
      /** ชนิดที่ถ่วงน้ำหนัก → `fn_post_entry.tag_weights` ({tag_id: น้ำหนัก}) */
      tagWeights: Record<string, number>;
      groups: AllocationGroup[];
    }
  | { ok: false; issues: string[] };

export function checkTagSelection(sel: TagSelection, catalog: TagCatalog): SelectionCheck {
  const issues: string[] = [];
  const byId = new Map(catalog.tags.map((t) => [t.id, t]));
  const kindOf = new Map(catalog.kinds.map((k) => [k.key, k]));

  const seen = new Set<string>();
  const chosen: Tag[] = [];
  for (const id of sel.tagIds) {
    if (seen.has(id)) {
      issues.push(`เลือก tag ซ้ำ (${byId.get(id)?.nameTh ?? id})`);
      continue;
    }
    seen.add(id);
    const tag = byId.get(id);
    if (!tag) {
      issues.push(`ไม่พบ tag ในแค็ตตาล็อก (${id}) — โหลดหน้าใหม่แล้วเลือกใหม่`);
      continue;
    }
    if (!tag.isActive) {
      issues.push(`tag "${tag.nameTh}" ถูกปิดใช้งานแล้ว ติดกับรายการใหม่ไม่ได้`);
      continue;
    }
    if (!kindOf.has(tag.kind)) {
      issues.push(`tag "${tag.nameTh}" เป็นชนิดที่ระบบไม่รู้จัก (${tag.kind}) — อ่านกติกาของชนิดนี้ไม่ได้ จึงไม่เดาให้`);
      continue;
    }
    chosen.push(tag);
  }

  // ชนิดที่ติดได้อันเดียว
  const perKind = new Map<string, Tag[]>();
  for (const t of chosen) perKind.set(t.kind, [...(perKind.get(t.kind) ?? []), t]);
  for (const [key, ts] of perKind) {
    const k = kindOf.get(key)!;
    if (!k.allowsMulti && ts.length > 1) issues.push(`ชนิด "${k.nameTh}" ติดได้ครั้งละอันเดียว แต่เลือกมา ${ts.length} อัน`);
  }

  const w = sel.weights && typeof sel.weights === "object" ? sel.weights : {};
  const covered = new Set<string>();
  const groups: AllocationGroup[] = [];
  const tagWeights: Record<string, number> = {};
  const labelTagIds: string[] = [];

  for (const [key, ts] of perKind) {
    const k = kindOf.get(key)!;
    if (!k.requiresAllocation) {
      labelTagIds.push(...ts.map((t) => t.id));
      continue;
    }
    // ชนิดที่ต้องถ่วงน้ำหนัก: ทุก tag ต้องมีน้ำหนัก และ Σ = 100% พอดี
    const c = checkWeights(ts, w);
    for (const t of ts) covered.add(t.id);
    if (!c.ok) {
      for (const i of c.issues) issues.push(`${k.nameTh}: ${i.message}`);
      continue;
    }
    groups.push({ kind: key, tags: ts, weights: c.weights });
    for (const t of ts) tagWeights[t.id] = w[t.id] as number;
  }

  // น้ำหนักที่ส่งมาให้ tag ที่ไม่ได้ถ่วงน้ำหนัก / ไม่ได้เลือก → ปฏิเสธ (ไม่ทิ้งเงียบ)
  for (const key of Object.keys(w)) {
    if (w[key] === undefined || covered.has(key)) continue;
    const t = byId.get(key);
    issues.push(
      t && seen.has(key)
        ? `tag "${t.nameTh}" ไม่ใช่ชนิดที่แบ่งสัดส่วน — ส่งสัดส่วนมาไม่ได้`
        : `มีสัดส่วนของ tag ที่ไม่ได้เลือกอยู่ในรายการนี้ (${t?.nameTh ?? key})`
    );
  }

  if (issues.length > 0) return { ok: false, issues };
  return { ok: true, labelTagIds, tagWeights, groups };
}

/**
 * ชนิดที่ถ่วงน้ำหนัก และเลือกมา **อันเดียว** = คำตอบที่ถูกมีได้คำตอบเดียวคือ 100% (ADR 0003 ข้อ 4.1)
 * ฟอร์มเรียกก่อนตรวจ เพื่อใส่ 100% ให้ **อย่างเปิดเผย** (ช่องแสดง 100%) — ตัวตรวจ/เซิร์ฟเวอร์ยังต้องได้น้ำหนักที่ส่งมาตรงๆ
 * ไม่แตะแถวที่ผู้ใช้กรอกไว้แล้ว และไม่เติมให้ชนิดที่เลือกมากกว่าหนึ่งอัน (นั่นคือการเดา)
 */
export function withSoleTagWeight(selectedTags: readonly Tag[], kinds: readonly TagKind[], weights: TagWeights): TagWeights {
  const out: TagWeights = { ...weights };
  for (const k of kinds) {
    if (!k.requiresAllocation) continue;
    const ts = selectedTags.filter((t) => t.kind === k.key);
    if (ts.length === 1 && (out[ts[0].id] === undefined || out[ts[0].id] === null)) out[ts[0].id] = 1;
  }
  return out;
}

/** ตัด key ของ weights ที่ tag ไม่ได้ถูกเลือกอยู่แล้ว (ผู้ใช้เอา tag ออกแต่น้ำหนักค้าง) — ก่อนส่งตรวจ */
export function pruneWeights(tagIds: readonly string[], weights: TagWeights): TagWeights {
  const keep = new Set(tagIds);
  return Object.fromEntries(Object.entries(weights).filter(([id]) => keep.has(id)));
}
