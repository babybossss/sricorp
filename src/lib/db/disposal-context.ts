/**
 * ข้อมูลต้นทุนของทรัพย์ที่ **ต้องอ่านจากสมุด** ก่อนลงรายการขาย — ผู้ใช้ไม่ได้กรอก (D-115)
 *
 * ผู้ใช้เลือกทรัพย์และกรอกได้แค่ **ราคาขายกับค่าใช้จ่ายในการขาย** ส่วนต้นทุน ค่ารีโนเวทสะสม และส่วนเกินทุนจากการตีราคาที่ค้างอยู่
 * อ่านจาก DB (`fn_asset_cost_basis` · `fn_asset_revaluation_surplus` · บรรทัด 1510 ของทรัพย์) — ค่าที่ผู้เรียกกรอกได้ ด่านฝั่ง DB เชื่อไม่ได้
 * ถ้ากรอกต้นทุนเองได้ ขายคอนโดห้องหนึ่งแล้วตัดต้นทุนน้อยกว่าจริงเพื่อให้กำไรสูงขึ้นได้ โดยงบดุลยังดุล
 *
 * ขอบเขตที่เปิดตอนนี้: **ทรัพย์ชิ้นเดียว (`whole_item`) ขายทั้งชิ้น** (อสังหาฯ · ที่ดิน · ของสะสม · สินทรัพย์ทางเลือกอื่น)
 * — ต้นทุนที่ตัด = ต้นทุนทั้งก้อนในสมุด (รวม 1510) และส่วนเกินทุนถูกล้างทั้งก้อน ไม่มีตัวเลขให้ผู้ใช้เลือกผิด
 * ทรัพย์ที่ขายบางส่วนได้ (`average` · `specific_lot`) **ยังไม่เปิด** เพราะการขายต้องตัดล็อตในทะเบียนในธุรกรรมเดียวกับใบขาย
 * ซึ่งต้องมีฟังก์ชันฝั่ง DB รองรับ (ลงสมุดกับตัดล็อตแยกสองคำสั่งจากแอปได้สภาพที่ใบขายอยู่แต่ล็อตไม่ลด)
 *
 * ไฟล์นี้เป็นฟังก์ชันล้วน ใช้ได้ทั้งฟอร์มและ server · ไม่คิดกำไร/ขาดทุน (`computeDisposal` / `buildPosting` เป็นคนคิด)
 */

import type { PostingInput } from "@/lib/ledger/types";

export type CostBasisMode = "average" | "specific_lot" | "whole_item";

export type DisposalContext = {
  assetId: string;
  mode: CostBasisMode;
  /** ต้นทุนทั้งก้อนในสมุด (รวมค่ารีโนเวท · ไม่รวมส่วนตีราคา) = `fn_asset_cost_basis` */
  costBasis: number;
  /** ค่ารีโนเวทสะสมที่บันทึกเป็นทุน (ผลรวมบรรทัด 1510 ของทรัพย์) — เป็นส่วนหนึ่งของ `costBasis` */
  renovation: number;
  /** ส่วนเกินทุนจากการตีราคา (3400) ที่ค้างอยู่ · บวก = เคยตีขึ้น · ลบ = เคยตีลง = `fn_asset_revaluation_surplus` */
  priorSurplus: number;
};

export type DisposalChoice = { salePrice: number; sellingCosts?: number };

export type DisposalBuild =
  | { ok: true; disposal: NonNullable<PostingInput["disposal"]> }
  | { ok: false; message: string };

const MODES: readonly string[] = ["average", "specific_lot", "whole_item"];
export const isCostBasisMode = (v: unknown): v is CostBasisMode => typeof v === "string" && MODES.includes(v);

const MODE_WHY: Record<Exclude<CostBasisMode, "whole_item">, string> = {
  average:
    "เป็นทรัพย์ที่ถัวเฉลี่ยต้นทุนได้ (หุ้นในตลาด · คริปโต · ทองคำ) การขายต้องตัดล็อตในทะเบียนพร้อมใบขายในธุรกรรมเดียวกัน",
  specific_lot: "เป็นทรัพย์ที่ขายได้รายล็อต (หุ้นนอกตลาด · ETF · กองทุน · พันธบัตร) การขายต้องระบุล็อตและตัดล็อตในทะเบียนพร้อมใบขายในธุรกรรมเดียวกัน",
};

/**
 * ผู้ใช้เลือกแค่ราคาขาย/ค่าใช้จ่าย → ประกอบ `disposal` ของ engine จากข้อมูลในสมุด
 * ไม่ส่งข้อมูล/ข้อมูลไม่ครบ = ปฏิเสธพร้อมเหตุผล ไม่เดา
 */
export function disposalFor(ctx: DisposalContext | null, choice: Partial<DisposalChoice> | undefined): DisposalBuild {
  if (!ctx) return { ok: false, message: "ยังอ่านต้นทุนของทรัพย์จากสมุดไม่ได้ — เลือกทรัพย์ที่ขาย" };
  if (ctx.mode !== "whole_item") {
    return {
      ok: false,
      message:
        `ขายทรัพย์ชนิดนี้ผ่านฟอร์มยังไม่ได้: ${MODE_WHY[ctx.mode]} ซึ่งต้องมีฟังก์ชันฝั่งฐานข้อมูลที่ลงใบขายและตัดล็อตพร้อมกัน — ` +
        "ยังไม่เปิดเพราะลงแยกกันแล้วล็อตกับสมุดจะต่างกันเมื่อคำสั่งหลังล้ม",
    };
  }
  if (!(ctx.costBasis > 0)) {
    return {
      ok: false,
      message: `ทรัพย์นี้ไม่มีต้นทุนในสมุด (${ctx.costBasis.toLocaleString("en-US")} บาท) จึงตัดออกไม่ได้ — ลงยอดซื้อหรือยอดยกมาของทรัพย์ชิ้นนี้ก่อน`,
    };
  }
  if (ctx.renovation < 0 || ctx.renovation > ctx.costBasis) {
    return { ok: false, message: `ค่ารีโนเวทสะสมในสมุด (${ctx.renovation}) ไม่สอดคล้องกับต้นทุนรวม (${ctx.costBasis}) — ตรวจรายการของทรัพย์ชิ้นนี้ก่อน` };
  }
  const sp = choice?.salePrice;
  if (typeof sp !== "number" || !Number.isFinite(sp) || sp <= 0) return { ok: false, message: "กรอกราคาขายจริง (มากกว่า 0)" };
  const sc = choice?.sellingCosts ?? 0;
  if (typeof sc !== "number" || !Number.isFinite(sc) || sc < 0) return { ok: false, message: "ค่าใช้จ่ายในการขายต้องเป็นตัวเลขที่ไม่ติดลบ" };
  return {
    ok: true,
    disposal: {
      costBasis: ctx.costBasis,
      salePrice: sp,
      sellingCosts: sc,
      renovationBasis: ctx.renovation,
      // ขายทั้งชิ้น: ต้นทุนที่ตัด = ต้นทุนทั้งก้อน → engine ล้างส่วนเกินทุนทั้งก้อนด้วยสมการเดียวกับด่านของ DB
      assetCostBefore: ctx.costBasis,
      priorSurplus: ctx.priorSurplus,
    },
  };
}
