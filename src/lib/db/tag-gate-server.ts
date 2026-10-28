import type { SupabaseClient } from "@supabase/supabase-js";
import { parseAcceptedKinds } from "@/lib/tags/acceptance";

type Db = Pick<SupabaseClient, "rpc">;

/**
 * ฟังก์ชันฝั่ง DB ที่คืนรายชื่อชนิด tag ที่ `fn_post_entry` รับได้จริง
 * **ชื่อชั่วคราว** — ฝั่ง DB ยังไม่ยืนยันชื่อ · เปลี่ยนที่นี่ที่เดียวเมื่อได้ชื่อจริง
 * (ถ้าชื่อนี้ยังไม่มีใน DB = อ่านไม่ได้ = ซ่อนทุกชนิด ซึ่งเป็นทางถอยที่ปลอดภัย)
 */
export const ACCEPTED_TAG_KINDS_RPC = "fn_post_entry_accepted_tag_kinds";

/**
 * อ่านรายชื่อชนิด tag ที่ประตูบันทึกรับได้ · **อ่านไม่ได้ทุกกรณีคืน `null`** (error · ฟังก์ชันไม่มี · exception · รูปคำตอบผิด)
 * ผู้เรียกต้องตีความ `null` = ซ่อนทุกชนิด ไม่ใช่ "ไม่จำกัด"
 */
export async function readAcceptedTagKinds(db: Db): Promise<ReadonlySet<string> | null> {
  try {
    const { data, error } = await db.rpc(ACCEPTED_TAG_KINDS_RPC);
    if (error) return null;
    return parseAcceptedKinds(data);
  } catch {
    return null;
  }
}
