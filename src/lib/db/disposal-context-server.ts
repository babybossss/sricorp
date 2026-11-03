import type { SupabaseClient } from "@supabase/supabase-js";
import { fetchAllPages } from "./paged";
import { isCostBasisMode, type DisposalContext } from "./disposal-context";
import type { Reference } from "./reference-types";

type Db = Pick<SupabaseClient, "from" | "rpc">;
export type DisposalContextState = { ok: true; ctx: DisposalContext } | { ok: false; message: string };

const num = (v: unknown): number | null => {
  const n = typeof v === "string" ? Number(v) : v;
  return typeof n === "number" && Number.isFinite(n) ? n : null;
};

/**
 * อ่านต้นทุน · ค่ารีโนเวทสะสม · ส่วนเกินทุนที่ค้าง · วิธีคิดต้นทุนของทรัพย์ จาก **สมุดที่ post แล้ว** ผ่าน RLS ของผู้ใช้
 *
 * - ทรัพย์ต้องเป็นของผู้ถือที่ระบุและยังถืออยู่ (ตรวจกับ `Reference` ที่โหลดสด)
 * - ต้นทุน/ส่วนเกินทุนมาจากฟังก์ชันของ DB (`fn_asset_cost_basis` · `fn_asset_revaluation_surplus`) ซึ่งเป็นนิพจน์เดียวกับที่ด่านใช้ตัดสิน
 * - วิธีคิดต้นทุนมาจาก `fn_asset_cost_basis_mode` (หมวดของทรัพย์ในตารางอ้างอิง) — **ไม่อ่าน ticker ไม่ใช้รหัสบัญชี**
 * - อ่านไม่ได้/ได้ค่าที่ไม่รู้จัก = ปฏิเสธ ไม่ตกเป็นค่าตั้งต้น
 */
export async function readDisposalContext(
  db: Db,
  ref: Pick<Reference, "assets" | "coaCodeById">,
  req: { ownerId: string; assetId: string }
): Promise<DisposalContextState> {
  const asset = ref.assets.find((a) => a.id === req.assetId);
  if (!asset) return { ok: false, message: "ไม่พบทรัพย์นี้ในระบบ — โหลดหน้าใหม่แล้วเลือกใหม่" };
  if (asset.ownerId !== req.ownerId) return { ok: false, message: `ทรัพย์ "${asset.name}" ไม่ใช่ของผู้ถือที่เลือก` };
  if (asset.status !== "active") return { ok: false, message: `ทรัพย์ "${asset.name}" สถานะ "${asset.status}" ขายไม่ได้ (ไม่ได้ถืออยู่แล้ว)` };

  const id1510 = Object.entries(ref.coaCodeById).find(([, code]) => code === "1510")?.[0];
  if (!id1510) return { ok: false, message: "หา id ของบัญชีค่ารีโนเวท (1510) ในผังบัญชีไม่เจอ — ปฏิเสธแทนที่จะเดาว่าไม่มีรีโนเวท" };

  try {
    const [mode, cost, surplus, reno] = await Promise.all([
      db.rpc("fn_asset_cost_basis_mode", { p_asset: req.assetId }),
      db.rpc("fn_asset_cost_basis", { p_asset: req.assetId }),
      db.rpc("fn_asset_revaluation_surplus", { p_asset: req.assetId }),
      fetchAllPages<{ debit: number | string; credit: number | string }>(() =>
        db
          .from("v_ledger_posted")
          .select("debit, credit")
          .eq("line_asset_id", req.assetId)
          .eq("coa_id", id1510)
          .order("line_id", { ascending: true }) as never
      ),
    ]);
    for (const [what, r] of [["วิธีคิดต้นทุน", mode], ["ต้นทุน", cost], ["ส่วนเกินทุนที่ค้าง", surplus]] as const) {
      if (r.error) return { ok: false, message: `อ่าน${what}ของทรัพย์จากสมุดไม่สำเร็จ (${r.error.message})` };
    }
    if (!reno.ok) return { ok: false, message: `อ่านค่ารีโนเวทสะสมของทรัพย์ไม่สำเร็จ (${reno.error})` };
    if (!isCostBasisMode(mode.data)) {
      return { ok: false, message: `ฐานข้อมูลตอบวิธีคิดต้นทุนที่ไม่รู้จัก ("${String(mode.data)}") — ปฏิเสธแทนที่จะเดา` };
    }
    const costBasis = num(cost.data);
    const priorSurplus = num(surplus.data);
    if (costBasis === null || priorSurplus === null) {
      return { ok: false, message: "ฐานข้อมูลตอบต้นทุนหรือส่วนเกินทุนไม่ครบ — ปฏิเสธแทนที่จะเดาเป็น 0" };
    }
    const renovation = reno.rows.reduce((t, r) => t + Math.round(Number(r.debit) * 100) - Math.round(Number(r.credit) * 100), 0) / 100;
    return { ok: true, ctx: { assetId: req.assetId, mode: mode.data, costBasis, renovation, priorSurplus } };
  } catch (e) {
    return { ok: false, message: `อ่านต้นทุนของทรัพย์ไม่สำเร็จ (${e instanceof Error ? e.message : String(e)})` };
  }
}
