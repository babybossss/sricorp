/**
 * ตีราคาทรัพย์ฝั่งลงทุนสิ้นเดือน — **วางแผนรายการ ไม่ได้สร้างบรรทัดบัญชีเอง**
 *
 * ไฟล์นี้คืน `PostingInput[]` ที่ผู้เรียกต้องส่งเข้า `buildPosting()` ต่อ
 * **โดยตั้งใจ**: "ที่เดียวที่สร้างรายการเงิน" ยังเป็น `posting.ts` อยู่
 * ถ้าไฟล์นี้ประกอบบรรทัดเองจะมีสองที่ที่รู้คู่บัญชี แล้วด่านทั้งชุดใน `posting.ts`
 * (ผู้ถือเลือกได้ไหม · ผูกทรัพย์ครบไหม · ห้ามแตะ P&L · สมดุล) จะถูกข้ามไปเงียบๆ
 *
 * ---------------------------------------------------------------------------
 * **วิธีจัดการการตีราคาซ้ำเดือนต่อเดือน — กลับรายการของเดือนก่อนแล้วลงใหม่**
 *
 * ทุกเดือนทำสองใบ: (1) ใบที่กลับส่วนเกินทุนที่ค้างอยู่ให้เป็นศูนย์
 *                  (2) ใบที่ลงส่วนเกินทุน **สะสมจากต้นทุน** ของเดือนนี้
 *
 * ทางเลือกที่ทิ้ง คือ "ลงแต่ส่วนต่างจากเดือนก่อน" (delta) ซึ่งได้ยอดปลายทางเท่ากัน
 * และเขียนน้อยกว่า แต่ **ผิดแบบที่มองไม่เห็น** ในสามกรณีที่เกิดจริง:
 *
 *   - เดือนที่ลืมตีราคา → ส่วนต่างของเดือนถัดไปคิดจากฐานที่ไม่ใช่เดือนก่อนหน้าจริง
 *     ความคลาดฝังเข้าไปในยอดสะสมและอยู่ตลอดไป
 *   - กดตีราคาซ้ำสองครั้ง → ส่วนต่างถูกลงสองรอบ ยอดบวมเป็นสองเท่าของส่วนต่าง
 *   - ลงย้อนหลัง/แก้ยอดเดือนก่อน → ทุกเดือนหลังจากนั้นผิดทั้งแถว
 *
 * แบบกลับรายการ **ตรวจได้ตลอดเวลาด้วยคำถามเดียว**: ส่วนเกินทุนที่ค้างใน 3400
 * ของทรัพย์ชิ้นนี้ ต้องเท่ากับ "มูลค่าตีราคาล่าสุด − ต้นทุน" พอดี ถ้าไม่เท่า
 * มีอะไรผิด และเห็นทันที · แบบ delta ตอบคำถามนี้ไม่ได้เลยเพราะยอดที่ค้าง
 * เป็นผลรวมของส่วนต่างหลายเดือนที่ไม่มีใครกระทบยอดได้
 *
 * และมันตรงกับกฎเหล็กข้อ 1 ของบ้านนี้อยู่แล้ว — **แก้ด้วย reverse + ลงใหม่**
 * ไม่ใช่แก้ทับของเดิม · ร่องรอยทุกเดือนอ่านได้ว่าเดือนนั้นตีราคาเท่าไร
 *
 * ต้นทุนที่ใช้เป็นฐาน **ต้องเป็นต้นทุนถัวเฉลี่ยคงเหลือ (D-112 · แทน FIFO ของ D-038)**
 * ซึ่งอ่านจาก `sri_os.fn_asset_cost_basis()` และส่วนเกินทุนที่ค้าง
 * **ต้องอ่านจากยอดที่ post แล้วจริง** (`sri_os.fn_asset_revaluation_surplus()`)
 * ไม่ใช่จาก state ของหน้าจอ — หน้าจอที่ยังไม่โหลดใหม่จะบอกว่า "ยังไม่เคยตีราคา"
 * ทั้งที่ตีไปแล้ว แล้วส่วนเกินทุนจะโตสองเท่า
 * (รูปแบบเดียวกับ `PostedClearing` ของเส้นทางยืนยันเงินเข้า-ออก)
 *
 * **หลังขายบางส่วน ต้นทุนที่ส่งมาต้องเป็นต้นทุนของหน่วยที่ยังถืออยู่** และ
 * ส่วนเกินทุนที่ค้างต้องเป็นยอดหลังล้างตามสัดส่วนแล้ว (D-112) — ถ้าส่งต้นทุน
 * ทั้งก้อนก่อนขายมา ส่วนเกินทุนเป้าหมายจะต่ำกว่าจริงเท่าต้นทุนของหน่วยที่ขายไป
 * ---------------------------------------------------------------------------
 */

import {
  revaluableAssetCoas,
  revaluationSubFor,
  type RevaluationDirection,
} from "@/lib/rules/tx-rules";
import { coaLabel } from "@/lib/rules/coa";
import { fxCheck, toThb } from "@/lib/rules/currency";
import { PostingError, type PostingInput } from "./types";
import { costBasisModeFor, type AssetBook } from "./average-cost";
import { money, round2 } from "./guards";

export type RevaluationPlanInput = {
  ownerId: string;
  assetId: string;
  /** บัญชีทรัพย์ที่ทรัพย์ชิ้นนี้ลงอยู่ (1700 หลักทรัพย์ · 1720 ทองคำ/คริปโต) */
  assetCoa: string;
  /** ต้นทุนคงเหลือตามบัญชีเป็นบาท (ถัวเฉลี่ย · D-112) — ฐานที่ส่วนเกินทุนวัดจาก */
  costBasisThb: number;
  /**
   * ส่วนเกินทุนของทรัพย์ชิ้นนี้ที่ **ค้างอยู่ใน 3400 ตามสมุดที่ post แล้ว**
   * บวก = เคยตีขึ้น · ลบ = เคยตีลง · 0 = ยังไม่เคยตีราคา (ต้องส่ง 0 ห้ามละไว้)
   */
  priorSurplusThb: number;
  /** สกุลเงินของทรัพย์ — มาจาก `assets.currency` */
  currency: string;
  /** อัตราของเดือนนั้นจากตาราง `fx_rates` (บาทต่อหน่วย) */
  rateToThb: number;
  /** มูลค่าตลาดในสกุลเดิม ณ วันตีราคา */
  valueOriginal: number;
  /** id ของแถวใน `asset_valuations` ที่เป็นที่มา — ติดไปใน memo เพื่อตามรอย */
  valuationRef?: string;
  memo?: string;
  attachments?: string[];
  contactId?: string;
};

export type RevaluationPlan = {
  /** ใบที่ต้องส่งเข้า `buildPosting()` ตามลำดับ — กลับรายการก่อน แล้วลงใหม่ */
  entries: PostingInput[];
  /**
   * **วิธีคิดต้นทุนของทรัพย์ชิ้นนี้** อ่านจากหมวดในข้อมูลอ้างอิง (D-115)
   * ตีราคาเองใช้สมการเดียวกันทุกโหมด (มูลค่า − ต้นทุน) — ที่ต่างคือ**ตอนขาย**
   */
  costBasisMode: ReturnType<typeof costBasisModeFor>;
  /**
   * ส่วนเกินทุนที่ต้องล้าง **ตอนขายทรัพย์ชิ้นนี้ทั้งชิ้น**
   * - `whole_item` → เท่ากับ `targetSurplusThb` **ทั้งก้อน** (ไม่มีสัดส่วนให้คิด)
   * - โหมดอื่น → `null` เพราะยอดขึ้นกับสัดส่วนต้นทุนที่ตัดในใบขาย
   *   (คิดที่ `surplusToReverseFor()` ตอนนั้น ไม่ใช่ตอนตีราคา)
   */
  surplusToClearOnWholeDisposal: number | null;
  /** มูลค่าตลาดแปลงเป็นบาทแล้ว */
  valueThb: number;
  /** ส่วนเกินทุนที่ควรค้างอยู่หลังลงครบ = valueThb − ต้นทุน */
  targetSurplusThb: number;
  /** ส่วนเกินทุนที่ค้างอยู่ก่อนหน้า (ที่ถูกกลับรายการ) */
  priorSurplusThb: number;
  summary: string[];
};

function entryFor(
  input: RevaluationPlanInput,
  direction: RevaluationDirection,
  amount: number,
  valueThb: number,
  memo: string
): PostingInput {
  const sub = revaluationSubFor(input.assetCoa, direction);
  if (!sub) {
    throw new PostingError(
      `ตารางกฎยังไม่มีหมวดตีราคา${direction === "up" ? "ขึ้น" : "ลง"}ของบัญชี ${coaLabel(input.assetCoa)} — ` +
        `วันนี้ตีราคาได้เฉพาะ ${revaluableAssetCoas().map(coaLabel).join(" · ")} ` +
        "(ขอบเขต D-111 คือทรัพย์ฝั่งลงทุน) · ถ้าต้องตีราคาบัญชีอื่น ต้องเพิ่มหมวดในตารางกฎก่อน"
    );
  }
  return {
    typeKey: "adjust",
    subCode: sub.code,
    amount,
    ownerId: input.ownerId,
    assetId: input.assetId,
    contactId: input.contactId,
    attachments: input.attachments,
    memo: input.memo ? `${memo} · ${input.memo}` : memo,
    revaluation: {
      currency: input.currency,
      rateToThb: input.rateToThb,
      valueOriginal: input.valueOriginal,
      valueThb,
      valuationRef: input.valuationRef,
    },
  };
}

/**
 * แผนการตีราคาของเดือนนี้ — **ข้อมูลไม่ครบให้ปฏิเสธ ห้ามเดา**
 *
 * ไม่มีอัตรา = ปฏิเสธ (ไม่ใช่ใช้อัตราเดือนก่อน ซึ่งทำให้ยอดค้างที่อัตราเก่าเงียบๆ)
 * ไม่มีสกุลเงิน = ปฏิเสธ (ไม่ใช่เดาเป็นบาท ซึ่งทำให้ทรัพย์ 40,000 USD กลายเป็น 40,000 บาท)
 */
export function planRevaluation(input: RevaluationPlanInput, assets: AssetBook): RevaluationPlan {
  /**
   * **วิธีคิดต้นทุนต้องอ่านจากข้อมูลอ้างอิงก่อนทำอะไรทั้งนั้น** (D-115)
   *
   * ไม่ส่งตัวอ่านมา หรือตัวอ่านไม่รู้จักทรัพย์ → `PostingError` **ห้ามเดา**
   * เพราะผลของการเดาไปโผล่ตอนขาย: ทรัพย์ชิ้นเดียวต้องล้างส่วนเกินทุน
   * **ทั้งก้อน** ส่วนทรัพย์ที่เฉลี่ยได้ล้างตามสัดส่วน — เดาผิดทางไหนก็
   * ทำให้ส่วนเกินทุนค้างหรือล้างเกิน แล้วกำไรของการขายครั้งถัดไปผิด
   */
  const costBasisMode = costBasisModeFor(input?.assetId, assets);

  const fx = fxCheck({ currency: input.currency, thbPerUnit: input.rateToThb });
  if (!fx.ok) throw new PostingError(fx.why);

  const valueOriginal = money(input.valueOriginal, "มูลค่าตลาดในสกุลเดิม");
  if (valueOriginal <= 0) {
    throw new PostingError(
      "มูลค่าตลาดในสกุลเดิมต้องมากกว่า 0 — ทรัพย์ที่ไม่มีมูลค่าแล้วต้องตัดจำหน่าย ไม่ใช่ตีราคาเป็นศูนย์"
    );
  }
  const costBasisThb = money(input.costBasisThb, "ต้นทุนตามบัญชี");
  if (costBasisThb <= 0) {
    throw new PostingError(
      "ต้นทุนตามบัญชีต้องมากกว่า 0 — ทรัพย์ที่ยังไม่มีต้นทุนในสมุดแปลว่ายังไม่ได้บันทึกการซื้อ ตีราคาก่อนไม่ได้"
    );
  }

  // ส่วนเกินทุนที่ค้างอยู่ **ติดลบได้** จึงไม่ผ่าน money() ที่ห้ามติดลบ
  if (!Number.isFinite(input.priorSurplusThb)) {
    throw new PostingError(
      "ต้องระบุส่วนเกินทุนจากการตีราคาที่ค้างอยู่ (ส่ง 0 ถ้ายังไม่เคยตีราคา) — " +
        "ละไว้แล้วถือว่าศูนย์คือการเดา ซึ่งทำให้ยอดของเดือนก่อนไม่ถูกกลับและส่วนเกินทุนโตสองเท่า"
    );
  }
  const prior = round2(input.priorSurplusThb);

  const valueThb = toThb(valueOriginal, fx.rate.thbPerUnit);
  const target = round2(valueThb - costBasisThb);

  const summary: string[] = [
    `มูลค่าตลาด ${valueOriginal.toLocaleString("en-US")} ${fx.rate.currency} × ${fx.rate.thbPerUnit} = ${valueThb.toLocaleString("en-US")} บาท`,
    `ต้นทุนตามบัญชี ${costBasisThb.toLocaleString("en-US")} บาท → ส่วนเกินทุนที่ควรค้าง ${target.toLocaleString("en-US")} บาท`,
  ];

  if (target === prior) {
    throw new PostingError(
      `ส่วนเกินทุนที่ควรค้าง (${target}) เท่ากับที่ค้างอยู่แล้ว ไม่มีอะไรต้องลง — ` +
        "ลงใบที่กลับรายการแล้วลงยอดเดิมซ้ำ จะได้ร่องรอยสองใบที่หักกันเป็นศูนย์ ซึ่งไม่ได้บอกอะไรเลย"
    );
  }

  const entries: PostingInput[] = [];

  if (prior !== 0) {
    // กลับรายการของเดือนก่อนให้ครบก้อน — ไม่ใช่หักกลบในใบเดียวกับยอดใหม่
    entries.push(
      entryFor(
        input,
        prior > 0 ? "down" : "up",
        Math.abs(prior),
        valueThb,
        `กลับรายการตีราคาที่ค้างอยู่ ${prior.toLocaleString("en-US")} บาท`
      )
    );
    summary.push(
      `กลับรายการส่วนเกินทุนที่ค้างอยู่ ${prior.toLocaleString("en-US")} บาทออกก่อน ` +
        "แล้วลงยอดสะสมของเดือนนี้ใหม่ทั้งก้อน (ไม่ใช่ลงส่วนต่างทับกัน)"
    );
  } else {
    summary.push("ยังไม่เคยตีราคาทรัพย์ชิ้นนี้ จึงไม่มีอะไรต้องกลับรายการ");
  }

  if (target !== 0) {
    entries.push(
      entryFor(
        input,
        target > 0 ? "up" : "down",
        Math.abs(target),
        valueThb,
        `ตีราคาสะสมจากต้นทุน ${target.toLocaleString("en-US")} บาท`
      )
    );
  } else {
    // มูลค่าตลาดกลับมาเท่าต้นทุนพอดี → กลับของเดือนก่อนอย่างเดียว ไม่มีใบที่สอง
    summary.push("มูลค่าตลาดเท่าต้นทุนพอดี จึงไม่มีส่วนเกินทุนค้างอยู่หลังกลับรายการ");
  }

  summary.push(
    "กำไร/ขาดทุนจากการตีราคาอยู่ในส่วนของเจ้าของ **ไม่เข้างบกำไรขาดทุน** · " +
      "รับรู้เข้างบกำไรขาดทุนตอนขายจริงเท่านั้น และตอนนั้นส่วนเกินทุนก้อนนี้จะถูกล้างออกพร้อมกัน"
  );

  /**
   * **สองเส้นทางของ "ตอนขาย"** — ต้องบอกตั้งแต่ตอนตีราคา เพราะคนที่ตีราคา
   * กับคนที่ขายอาจเป็นคนละคนละเดือน และยอดที่ต้องล้างต่างกันคนละแบบ
   */
  const surplusToClearOnWholeDisposal = costBasisMode === "whole_item" ? target : null;
  summary.push(
    costBasisMode === "whole_item"
      ? "ทรัพย์ชิ้นเดียว (ห้ามเฉลี่ยต้นทุน · ลูกพี่สั่ง 25/10) — ตอนขายต้องล้างส่วนเกินทุน " +
          `**ทั้งก้อน ${target.toLocaleString("en-US")} บาท** ในใบเดียวกับการขาย ` +
          "เพราะขายทั้งชิ้นจึงไม่มีสัดส่วนให้คิด และแบ่งขายบางส่วนไม่ได้"
      : costBasisMode === "average"
        ? "ทรัพย์ที่ถัวเฉลี่ยต้นทุนได้ (หุ้นในตลาด · คริปโต · ทองคำ) — ขายบางส่วนภายหลัง " +
            "ต้องล้างส่วนเกินทุน **ตามสัดส่วนของต้นทุนที่ตัดออก** (D-112) ไม่ใช่ทั้งก้อน"
        : "ทรัพย์ที่ห้ามเฉลี่ยแต่แบ่งขายรายล็อตได้ (หุ้นนอกตลาด · ETF · กองทุน · พันธบัตร) — " +
            "ตอนขายต้อง **ระบุล็อต** และล้างส่วนเกินทุนตามสัดส่วนของต้นทุนที่ตัดออก"
  );

  return {
    entries,
    costBasisMode,
    surplusToClearOnWholeDisposal,
    valueThb,
    targetSurplusThb: target,
    priorSurplusThb: prior,
    summary,
  };
}
