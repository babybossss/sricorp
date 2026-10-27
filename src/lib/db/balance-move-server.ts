import type { SupabaseClient } from "@supabase/supabase-js";
import type { SubCategory } from "@/lib/rules/tx-rules";
import { balanceMoveFor, type BalanceMoveBuild } from "./balance-move";
import type { Reference } from "./reference-types";

type Db = Pick<SupabaseClient, "rpc">;
export type BalanceMoveState = BalanceMoveBuild;

/**
 * อ่านยอดคงเหลือของทรัพย์ชิ้นหนึ่งในบัญชีต้นทางของหมวดย้าย จาก **สมุดที่ post แล้ว** (`fn_asset_account_balance`)
 *
 * - ทรัพย์ต้องเป็นของผู้ถือที่ระบุ (ตรวจกับ `Reference` ที่โหลดสด)
 * - บัญชีต้นทางมาจากตารางกฎ (`sub.cr`) ไม่ใช่จากผู้เรียก
 * - อ่านไม่สำเร็จ = ปฏิเสธ **ห้ามเดาเป็น 0** (0 ถูกแปลว่า "ไม่มีต้นทุนในบัญชีนั้น" แล้วด่านจะปฏิเสธด้วยเหตุผลผิด)
 * - ยอดไม่เป็นบวก = ปฏิเสธเป็นภาษาคน (`balanceMoveFor`)
 */
export async function readBalanceMove(
  db: Db,
  ref: Pick<Reference, "assets">,
  sub: Pick<SubCategory, "label" | "cr" | "requires">,
  req: { ownerId: string; assetId: string }
): Promise<BalanceMoveState> {
  const asset = ref.assets.find((a) => a.id === req.assetId);
  if (!asset) return { ok: false, message: "ไม่พบทรัพย์นี้ในระบบ — โหลดหน้าใหม่แล้วเลือกใหม่" };
  if (asset.ownerId !== req.ownerId) return { ok: false, message: `ทรัพย์ "${asset.name}" ไม่ใช่ของผู้ถือที่เลือก` };

  let balance: number | null = null;
  try {
    const r = await db.rpc("fn_asset_account_balance", { p_asset: req.assetId, p_coa: sub.cr });
    if (r.error) return { ok: false, message: `อ่านยอดคงเหลือของทรัพย์ "${asset.name}" จากสมุดไม่สำเร็จ (${r.error.message})` };
    const v = r.data as unknown;
    const n = typeof v === "string" && v.trim() !== "" ? Number(v) : v;
    balance = typeof n === "number" && Number.isFinite(n) ? n : null;
  } catch (e) {
    return { ok: false, message: `อ่านยอดคงเหลือของทรัพย์ "${asset.name}" จากสมุดไม่สำเร็จ (${e instanceof Error ? e.message : String(e)})` };
  }
  if (balance === null) {
    return { ok: false, message: `ฐานข้อมูลตอบยอดคงเหลือของทรัพย์ "${asset.name}" ไม่เป็นตัวเลข — ปฏิเสธแทนที่จะเดาเป็น 0` };
  }
  return balanceMoveFor(sub, balance);
}
