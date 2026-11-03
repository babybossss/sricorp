import type { SupabaseClient } from "@supabase/supabase-js";
import type { Tag, TagKind } from "@/components/tags/types";
import { NOT_MIGRATED_MESSAGE, isMissingDbObject } from "@/lib/tags/db-errors";
import type { TagCatalog } from "@/lib/tags/selection";

type Db = Pick<SupabaseClient, "from">;

export type TagCatalogRead =
  | { ok: true; catalog: TagCatalog }
  | { ok: false; message: string; notMigrated: boolean };

/**
 * อ่านแค็ตตาล็อก tag (`tag_kinds` + `tags`) ตาม session ของผู้ใช้ (RLS บังคับ)
 *
 * - ชนิดที่ต้องถ่วงน้ำหนักมาจากคอนฟิก `tag_kinds.requires_allocation` — ไม่เช็คชื่อ 'project' ในโค้ด
 * - ตาราง/คอลัมน์ยังไม่มี = `notMigrated` + ข้อความ "ยังไม่ได้ลง migration" · **ไม่คืนแค็ตตาล็อกว่างแทน**
 *   (ว่าง = หน้าจอบอกว่าไม่มี tag ให้เลือก แล้วผู้ใช้ลงรายการโดยไม่ติด tag โดยไม่รู้ว่าระบบยังไม่พร้อม)
 * - แถวที่อ่านค่าไม่ครบ (เช่น requires_allocation เป็น null) = ปฏิเสธทั้งก้อน ไม่เดาเป็น false
 * - `includeInactive`: ตัวตรวจฝั่งเซิร์ฟเวอร์ต้องเห็น tag ที่ปิดแล้ว เพื่อบอกเหตุผลที่ถูก · รายการให้เลือกในฟอร์มไม่ต้อง
 */
export async function readTagCatalog(db: Db, opts: { includeInactive?: boolean } = {}): Promise<TagCatalogRead> {
  const fail = (e: { code?: string | null; message?: string | null }, what: string): TagCatalogRead =>
    isMissingDbObject(e)
      ? { ok: false, notMigrated: true, message: NOT_MIGRATED_MESSAGE }
      : { ok: false, notMigrated: false, message: `อ่าน${what}ไม่สำเร็จ (${e.message ?? "ไม่ทราบสาเหตุ"}) — ยังไม่ได้บันทึกอะไร` };

  let kindRows: unknown[] | null;
  let tagRows: unknown[] | null;
  try {
    const k = await db
      .from("tag_kinds")
      .select("key,name_th,allows_multi,aggregate_note_th,requires_allocation,allocation_note_th,sort_order,is_active")
      .eq("is_active", true)
      .order("sort_order", { ascending: true });
    if (k.error) return fail(k.error, "ชนิดของ tag");
    kindRows = k.data;

    let q = db.from("tags").select("id,kind,code,name_th,is_active,color_token");
    if (!opts.includeInactive) q = q.eq("is_active", true);
    const t = await q.order("name_th", { ascending: true });
    if (t.error) return fail(t.error, "รายการ tag");
    tagRows = t.data;
  } catch (e) {
    return { ok: false, notMigrated: false, message: `อ่านแค็ตตาล็อก tag ไม่สำเร็จ (${e instanceof Error ? e.message : String(e)}) — ยังไม่ได้บันทึกอะไร` };
  }

  const kinds: TagKind[] = [];
  for (const r of (kindRows ?? []) as Record<string, unknown>[]) {
    if (
      typeof r.key !== "string" ||
      typeof r.name_th !== "string" ||
      typeof r.allows_multi !== "boolean" ||
      typeof r.requires_allocation !== "boolean" ||
      typeof r.aggregate_note_th !== "string"
    ) {
      return {
        ok: false,
        notMigrated: false,
        message: "อ่านกติกาของชนิด tag ไม่ครบ (allows_multi / requires_allocation) — ไม่เดาให้ ยังไม่ได้บันทึกอะไร",
      };
    }
    kinds.push({
      key: r.key,
      nameTh: r.name_th,
      allowsMulti: r.allows_multi,
      aggregateNoteTh: r.aggregate_note_th,
      requiresAllocation: r.requires_allocation,
      allocationNoteTh: typeof r.allocation_note_th === "string" ? r.allocation_note_th : null,
    });
  }

  const activeKinds = new Set(kinds.map((k) => k.key));
  const tags: Tag[] = [];
  for (const r of (tagRows ?? []) as Record<string, unknown>[]) {
    if (typeof r.id !== "string" || typeof r.kind !== "string" || typeof r.name_th !== "string" || typeof r.is_active !== "boolean") {
      return { ok: false, notMigrated: false, message: "อ่านรายการ tag ไม่ครบ — ยังไม่ได้บันทึกอะไร" };
    }
    // tag ของชนิดที่ปิดแล้วไม่ให้เลือก (ตัวตรวจยังเห็นผ่าน includeInactive เพื่อบอกเหตุผล)
    if (!opts.includeInactive && !activeKinds.has(r.kind)) continue;
    tags.push({
      id: r.id,
      kind: r.kind,
      code: typeof r.code === "string" ? r.code : "",
      nameTh: r.name_th,
      isActive: r.is_active,
      colorToken: typeof r.color_token === "string" ? r.color_token : null,
    });
  }
  return { ok: true, catalog: { kinds, tags } };
}
