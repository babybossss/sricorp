"use server";

import { revalidatePath } from "next/cache";
import { getAccess } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";
import { readTagCatalog } from "@/lib/db/tag-catalog-server";
import { readAcceptedTagKinds } from "@/lib/db/tag-gate-server";
import { splitByAcceptance, type HiddenKind } from "@/lib/tags/acceptance";
import { NOT_MIGRATED_MESSAGE, isMissingDbObject } from "@/lib/tags/db-errors";
import { checkWeights } from "@/lib/tags/weights";
import type { Tag, TagKind } from "@/components/tags/types";

/**
 * ชั้นแอปของการถ่วงน้ำหนัก tag (ADR 0003) — **สัญญาฝั่ง DB ตาม ADR** (ฝั่ง DB สร้างแยก):
 *   - `tag_kinds.requires_allocation` / `tags` / `transaction_tags` อ่านตาม session ของผู้ใช้ (RLS)
 *   - `fn_reallocate_tags(p_transaction_id, p_kind, p_weights jsonb, p_reason) → jsonb` (ADR ข้อ 3.3 / 6)
 *   - ตอนลงรายการใหม่: `fn_post_entry` รับ `tag_ids` + `tag_weights` (อยู่ใน `post-entry.ts`)
 *
 * ของที่ DB ยังไม่มี **ต้องปฏิเสธเสียงดัง** ("ยังไม่ได้ลง migration") และไม่บันทึกอะไร — ไม่ปล่อยผ่านเงียบ
 *
 * ที่นี่ **ไม่คำนวณยอดต่อ tag** (ตัวคูณมาจากสมุด จำนวนเงินไม่เคยเดินทางมากับน้ำหนัก) และไม่ปัดอะไรเลย
 * ไฟล์นี้ตรวจแค่น้ำหนัก (Σ = 1 พอดี ฯลฯ) ผ่าน `lib/tags` ตัวเดียวกับที่ปุ่มบันทึกในฟอร์มเรียก · DB ตรวจซ้ำที่ commit
 */

export type TagCatalogState =
  | { ok: true; kinds: TagKind[]; tags: Tag[]; hiddenKinds: HiddenKind[] }
  | { ok: false; message: string; notMigrated: boolean };

/**
 * รายการ tag ที่เลือกได้ (เฉพาะที่เปิดใช้งาน) + กติกาของแต่ละชนิด สำหรับฟอร์ม
 * คืนเฉพาะชนิดที่ประตูบันทึกรับได้จริง (อ่านจาก DB) · ชนิดที่ไม่รับ/อ่านไม่ได้อยู่ใน `hiddenKinds` พร้อมเหตุ ไม่หายเงียบ
 */
export async function loadTagCatalog(): Promise<TagCatalogState> {
  const access = await getAccess();
  if (!access.user) return { ok: false, notMigrated: false, message: "เข้าสู่ระบบหมดอายุ — ให้เข้าสู่ระบบใหม่" };
  let supabase;
  try {
    supabase = await createClient();
  } catch (e) {
    return { ok: false, notMigrated: false, message: e instanceof Error ? e.message : String(e) };
  }
  const read = await readTagCatalog(supabase);
  if (!read.ok) return read;
  const split = splitByAcceptance(read.catalog, await readAcceptedTagKinds(supabase));
  return { ok: true, kinds: split.catalog.kinds, tags: split.catalog.tags, hiddenKinds: split.hidden };
}

export type ReallocateRequest = {
  transactionId: string;
  /** ชนิด tag ที่จะแก้สัดส่วน (ต้องเป็นชนิดที่ requires_allocation) */
  kind: string;
  /** {tag_id: สัดส่วน} — ต้องครอบ tag ที่ติดอยู่ของชนิดนี้ครบทุกอัน และรวมได้ 1.000000 พอดี */
  weights: Record<string, unknown>;
  /** เหตุผลที่แก้ — บังคับ (กำไรต่อ project ที่เคยรายงานคิดจากน้ำหนักชุดเดิม ต้องอธิบายได้ว่าทำไมเปลี่ยน) */
  reason: string;
};

export type ReallocateOutcome =
  | { ok: true; transactionIds: string[] }
  | { ok: false; message: string };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const fail = (message: string): ReallocateOutcome => ({ ok: false, message });

/** แก้สัดส่วน tag ของใบที่ลงแล้ว: ปิดชุดเดิม + เปิดชุดใหม่ในธุรกรรมเดียว (ที่ DB) — ไม่ UPDATE น้ำหนักทับ */
export async function reallocateTags(req: ReallocateRequest): Promise<ReallocateOutcome> {
  const access = await getAccess();
  if (!access.user) return fail("เข้าสู่ระบบหมดอายุ — ให้เข้าสู่ระบบใหม่แล้วบันทึกอีกครั้ง");
  if (access.error) return fail(`ตรวจสิทธิ์ไม่สำเร็จ ยังไม่ได้บันทึกอะไร (${access.error})`);
  if (!access.permissions.has("tag.assign")) return fail("บัญชีนี้แก้ tag ของรายการไม่ได้ — ไม่มีสิทธิ์ติด/ถอด tag · ยังไม่ได้บันทึกอะไร");

  if (!req || typeof req !== "object") return fail("ไม่ได้รับข้อมูล — ยังไม่ได้บันทึกอะไร");
  if (typeof req.transactionId !== "string" || !UUID.test(req.transactionId)) return fail("ไม่ได้ระบุรายการที่จะแก้ — ยังไม่ได้บันทึกอะไร");
  if (typeof req.kind !== "string" || req.kind.trim() === "") return fail("ไม่ได้ระบุชนิดของ tag — ยังไม่ได้บันทึกอะไร");
  if (typeof req.reason !== "string" || req.reason.trim() === "") {
    return fail("ต้องใส่เหตุผลที่แก้สัดส่วน — กำไรต่อโปรเจกต์ที่เคยรายงานไปแล้วคิดจากสัดส่วนชุดเดิม ต้องอธิบายได้ว่าทำไมเปลี่ยน · ยังไม่ได้บันทึกอะไร");
  }
  if (!req.weights || typeof req.weights !== "object" || Array.isArray(req.weights)) {
    return fail("ไม่ได้ส่งสัดส่วนมา — ต้องระบุสัดส่วนของ tag ทุกอันที่ติดอยู่ ระบบไม่เดาให้ · ยังไม่ได้บันทึกอะไร");
  }

  let supabase;
  try {
    supabase = await createClient();
  } catch (e) {
    return fail(e instanceof Error ? e.message : String(e));
  }

  // กติกาของชนิดมาจากคอนฟิกใน DB
  const read = await readTagCatalog(supabase, { includeInactive: true });
  if (!read.ok) return fail(read.message);
  const kind = read.catalog.kinds.find((k) => k.key === req.kind);
  if (!kind) return fail(`ไม่รู้จักชนิด tag "${req.kind}" — ยังไม่ได้บันทึกอะไร`);
  if (!kind.requiresAllocation) {
    return fail(`ชนิด "${kind.nameTh}" ไม่มีการแบ่งสัดส่วน — ใช้ติด/ถอด tag ตามปกติ · ยังไม่ได้บันทึกอะไร`);
  }

  // tag ที่ติดอยู่บนใบนี้จริง (อ่านจาก DB ไม่เชื่อรายการที่ผู้เรียกบอก)
  let linkedIds: string[];
  try {
    const l = await supabase
      .from("transaction_tags")
      .select("tag_id")
      .eq("transaction_id", req.transactionId)
      .eq("tag_kind", req.kind)
      .is("untagged_at", null);
    if (l.error) {
      return isMissingDbObject(l.error)
        ? fail(NOT_MIGRATED_MESSAGE)
        : fail(`อ่าน tag ที่ติดอยู่บนรายการไม่สำเร็จ (${l.error.message}) — ยังไม่ได้บันทึกอะไร`);
    }
    linkedIds = ((l.data ?? []) as { tag_id?: unknown }[]).map((r) => r.tag_id).filter((x): x is string => typeof x === "string");
  } catch (e) {
    return fail(`อ่าน tag ที่ติดอยู่บนรายการไม่สำเร็จ (${e instanceof Error ? e.message : String(e)}) — ยังไม่ได้บันทึกอะไร`);
  }
  if (linkedIds.length === 0) return fail(`รายการนี้ไม่ได้ติด tag ชนิด "${kind.nameTh}" อยู่ — ไม่มีสัดส่วนให้แก้ · ยังไม่ได้บันทึกอะไร`);
  const byId = new Map(read.catalog.tags.map((t) => [t.id, t]));
  const linked: Tag[] = [];
  for (const id of linkedIds) {
    const t = byId.get(id);
    if (!t) return fail(`tag ที่ติดอยู่ (${id}) ไม่อยู่ในแค็ตตาล็อก — ไม่เดาให้ · ยังไม่ได้บันทึกอะไร`);
    linked.push(t);
  }

  // Σ = 1.000000 พอดี · ครอบทุก tag ที่ติดอยู่ · ไม่มีสัดส่วนกำพร้า
  const checked = checkWeights(linked, req.weights);
  if (!checked.ok) return fail(`${checked.issues.map((i) => i.message).join(" · ")} · ยังไม่ได้บันทึกอะไร`);

  const pWeights: Record<string, number> = {};
  for (const t of linked) pWeights[t.id] = req.weights[t.id] as number;

  let data: unknown;
  try {
    const r = await supabase.rpc("fn_reallocate_tags", {
      p_transaction_id: req.transactionId,
      p_kind: req.kind,
      p_weights: pWeights,
      p_reason: req.reason.trim(),
    });
    if (r.error) {
      if (isMissingDbObject(r.error)) return fail(NOT_MIGRATED_MESSAGE);
      const m = (r.error.message ?? "").trim();
      if (m && /[฀-๿]/.test(m)) return fail(m);
      if (r.error.code === "42501" || /row-level security|permission denied/i.test(m)) {
        return fail("บัญชีนี้แก้สัดส่วนของรายการนี้ไม่ได้ — ฐานข้อมูลปฏิเสธตามสิทธิ์ · ยังไม่ได้บันทึกอะไร");
      }
      return fail(`ฐานข้อมูลไม่รับสัดส่วนชุดนี้ ยังไม่ได้บันทึกอะไร (${[r.error.code, m].filter(Boolean).join(" · ")})`);
    }
    data = r.data;
  } catch (e) {
    return fail(
      `ติดต่อฐานข้อมูลไม่ได้ระหว่างบันทึก — ยังไม่ทราบว่าสัดส่วนถูกแก้หรือไม่ ให้เปิดรายการตรวจก่อนกดซ้ำ (${e instanceof Error ? e.message : String(e)})`
    );
  }
  if (!data || typeof data !== "object") {
    return fail("ฐานข้อมูลตอบกลับไม่ครบ — ไม่ยืนยันว่าสัดส่วนถูกแก้แล้ว ให้เปิดรายการตรวจก่อนกดซ้ำ");
  }
  const ids = (data as { transaction_ids?: unknown }).transaction_ids;
  revalidatePath("/ledger");
  revalidatePath("/dashboard");
  return { ok: true, transactionIds: Array.isArray(ids) ? ids.filter((x): x is string => typeof x === "string") : [req.transactionId] };
}
