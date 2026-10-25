/**
 * ประกอบ `fxTranslation` / `fxConversion` ของ `PostingInput` จาก **ข้อมูลในสมุด + อัตราที่เลือกจากตาราง**
 *
 * ผู้ใช้เลือกได้แค่ 3 อย่าง (`FxChoice`): วันของอัตรา (เลือกจากตารางอัตรา ไม่พิมพ์ตัวเลข) และจำนวนเงินตราที่จะแลก
 * ที่เหลือทั้งหมดมาจาก `FxAccountContext` ซึ่งอ่านจากสมุด: ยอดเงินตราคงเหลือ · อัตราที่ยอดบาทตั้งอยู่ · ผลต่างที่ค้างใน 3410
 *
 * ไฟล์นี้ **ไม่คิดบัญชี** — ผลต่าง/กำไร/ขาดทุน/บรรทัดล้าง 3410 คิดโดย `buildPosting()` ที่เดียว
 * ที่นี่คิดเฉพาะ "ยอดบาทที่ต้องกรอกให้ตรงกับที่ engine คาดหวัง" (`amount`) เพื่อเติมช่องจำนวนเงินให้ผู้ใช้ไม่ต้องพิมพ์เอง
 * โดยใช้ `toThb()` ตัวเดียวกับ engine · ถ้าผิดไปแม้สตางค์เดียว engine ปฏิเสธ (มีเทสต์เทียบ engine จริง ไม่ใช่เทียบสูตรกับสูตร)
 *
 * ใช้ร่วมกันสองฝั่ง: ฟอร์ม (พรีวิวบรรทัดบัญชี) และ server action (ตอนบันทึกจริง — อ่านสมุดใหม่ ไม่เชื่อค่าจาก browser)
 */

import { isFxRealisingSub, isFxTranslationSub, type SubCategory } from "@/lib/rules/tx-rules";
import { toThb } from "@/lib/rules/currency";
import type { PostingInput } from "@/lib/ledger/types";
import type { FxAccountContext, FxRate } from "./fx-context";

/** สิ่งที่ผู้ใช้เลือก — ไม่มีตัวเลขอัตราและไม่มียอดคงเหลือ */
export type FxChoice = {
  /** แปลงค่า: วันของอัตราสิ้นงวดที่จะตีใหม่ (เลือกจากตารางอัตรา) */
  newRateDate?: string;
  /** แลกเงิน: วันของอัตราที่แลกได้จริง (เลือกจากตารางอัตรา) */
  dealRateDate?: string;
  /** แลกเงิน: จำนวนเงินตราที่แลกออก */
  amountOriginal?: number;
};

export type FxKind = "translation" | "conversion";

export type FxInputResult =
  | {
      ok: true;
      kind: FxKind;
      /** ยอดบาทที่ช่อง "จำนวนเงิน" ต้องเป็น (engine ตรวจซ้ำ) */
      amount: number;
      patch: Pick<PostingInput, "fxTranslation" | "fxConversion">;
    }
  | { ok: false; kind: FxKind; message: string };

/** หมวดนี้ต้องใช้ข้อมูลอัตราหรือไม่ — ถามจากคู่บัญชีในตารางกฎ (ไม่ใช่รหัสหมวด) · null = ไม่เกี่ยวกับเงินตรา */
export function fxKindOf(sub: SubCategory | undefined): FxKind | null {
  if (!sub) return null;
  if (isFxTranslationSub(sub)) return "translation";
  if (isFxRealisingSub(sub)) return "conversion";
  return null;
}

const rateOn = (rates: FxRate[], date: string | undefined): FxRate | undefined => (date ? rates.find((r) => r.rateDate === date) : undefined);

export function fxInputFor(sub: SubCategory, ctx: FxAccountContext, choice: FxChoice): FxInputResult {
  const kind = fxKindOf(sub);
  if (!kind) throw new Error(`หมวด ${sub.code} ไม่เกี่ยวกับอัตราแลกเปลี่ยน`);
  const no = (message: string): FxInputResult => ({ ok: false, kind, message });

  if (!(ctx.units > 0)) {
    return no(`บัญชีนี้ไม่มี${ctx.currency}คงเหลือในสมุด (${ctx.units} ${ctx.currency}) จึงไม่มีอะไรให้${kind === "translation" ? "แปลงค่า" : "แลก"}`);
  }

  if (kind === "translation") {
    const newRate = rateOn(ctx.rates, choice.newRateDate);
    if (!choice.newRateDate) return no("เลือกอัตราสิ้นงวดที่จะใช้ตีใหม่จากตารางอัตราแลกเปลี่ยน");
    if (!newRate) return no(`ไม่มีอัตรา ${ctx.currency} ของวันที่ ${choice.newRateDate} ในตารางอัตรา — เลือกเฉพาะวันที่มีในตาราง`);
    if (ctx.bookRate === null || !ctx.bookRateDate) {
      return no(
        `ยอดบาทตามสมุดของบัญชีนี้ (${ctx.bookThb.toLocaleString("en-US")}) หาอัตราที่คูณกับ ${ctx.units.toLocaleString("en-US")} ${ctx.currency} ` +
          "แล้วได้ยอดตรงพอดีไม่ได้ — ตรวจรายการเงินตราของบัญชีนี้ก่อน"
      );
    }
    return {
      ok: true,
      kind,
      // ปัดเหมือน engine (`round2(thbAfter − thbBefore)`) — ลบเลขทศนิยมลอยตัวตรงๆ ได้ 4999.999999999
      amount: Math.abs(Math.round((toThb(ctx.units, newRate.thbPerUnit) - toThb(ctx.units, ctx.bookRate)) * 100) / 100),
      patch: {
        fxTranslation: {
          currency: ctx.currency,
          balanceOriginal: ctx.units,
          bookRateToThb: ctx.bookRate,
          bookRateDate: ctx.bookRateDate,
          newRateToThb: newRate.thbPerUnit,
          newRateDate: newRate.rateDate,
        },
      },
    };
  }

  // ---- แลกเป็นบาทจริง ----
  const deal = rateOn(ctx.rates, choice.dealRateDate);
  if (!choice.dealRateDate) return no("เลือกอัตราที่แลกได้จริงจากตารางอัตราแลกเปลี่ยน");
  if (!deal) return no(`ไม่มีอัตรา ${ctx.currency} ของวันที่ ${choice.dealRateDate} ในตารางอัตรา — เลือกเฉพาะวันที่มีในตาราง`);
  const ao = choice.amountOriginal;
  if (typeof ao !== "number" || !Number.isFinite(ao) || ao <= 0) return no(`กรอกจำนวน ${ctx.currency} ที่จะแลก (มากกว่า 0)`);
  if (ao > ctx.units) {
    return no(`แลก ${ao.toLocaleString("en-US")} ${ctx.currency} มากกว่ายอดคงเหลือในบัญชี ${ctx.units.toLocaleString("en-US")} ${ctx.currency}`);
  }
  if (!ctx.bookRateRow) {
    return no(
      `ยอดบาทตามสมุดของบัญชีนี้ (${ctx.bookThb.toLocaleString("en-US")} บาท ต่อ ${ctx.units.toLocaleString("en-US")} ${ctx.currency}) ` +
        "ไม่ตรงกับอัตราใดในตารางอัตรา จึงตัดเงินตราออกด้วยอัตราตามบัญชีไม่ได้ — ให้ลงรายการ “แปลงค่า” เป็นอัตราหนึ่งก่อน " +
        "(ยอดบาทของบัญชีจะตั้งอยู่ที่อัตราเดียว) แล้วจึงกลับมาแลก"
    );
  }
  return {
    ok: true,
    kind,
    amount: toThb(ao, deal.thbPerUnit),
    patch: {
      fxConversion: {
        currency: ctx.currency,
        amountOriginal: ao,
        balanceOriginalBefore: ctx.units,
        bookRateToThb: ctx.bookRateRow.thbPerUnit,
        bookRateDate: ctx.bookRateRow.rateDate,
        dealRateToThb: deal.thbPerUnit,
        dealRateDate: deal.rateDate,
        unrealizedBefore: ctx.unrealized,
      },
    },
  };
}
