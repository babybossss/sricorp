/**
 * Ledger engine — แปลงรายการที่ผู้ใช้กรอก เป็นบรรทัดบัญชีสองด้าน
 *
 * **โค้ดที่สร้างรายการเงินอยู่ที่นี่ที่เดียว** หน้าจอเรียกผ่านฟังก์ชันที่ export ไว้
 * ห้ามมีคู่บัญชีกระจายอยู่ในคอมโพเนนต์ (CLAUDE.md กฎเหล็กข้อ 5)
 *
 * ทุกอย่างที่ออกจากที่นี่ต้องผ่าน Money Invariants ก่อนเสมอ เพราะ DB จะปฏิเสธอยู่ดี —
 * ดักที่นี่เพื่อให้ผู้ใช้เห็นข้อความที่เข้าใจได้ แทน error ดิบจากฐานข้อมูล
 *
 * หลักที่ยึด: **ข้อมูลไม่ครบให้ปฏิเสธ ห้ามเดา** เพราะเดาผิดในรายการเงิน
 * แปลว่าตัวเลขผิดเงียบๆ ซึ่งแย่กว่าการขึ้น error
 */

import {
  accrualCheck,
  movesCash,
  whtCheck,
  isFxTranslationSub,
  isFxRealisingSub,
  type SubCategory,
} from "@/lib/rules/tx-rules";
import { fxCheck, toThb, BASE_CURRENCY } from "@/lib/rules/currency";
import {
  coa,
  coaLabel,
  isCashAccount,
  isFxTranslationAccount,
  isPropertyAccount,
  CASH_COA,
  PROPERTY_COA,
  RENOVATION_COA,
  REVALUATION_SURPLUS_COA,
  FX_TRANSLATION_DIFF_COA,
} from "@/lib/rules/coa";
import { INTERCOMPANY_RULES } from "@/lib/rules/intercompany";
import { computeDisposal } from "@/lib/disposal/capital-gain";
// สมการสัดส่วนส่วนเกินทุนอยู่ที่เดียว (D-112) — ตัวเดียวกับที่ด่านฝั่ง DB ใช้
import { surplusToReverseFor } from "./average-cost";
import {
  PostingError,
  type BankInfo,
  type LedgerResolver,
  type PostingInput,
  type PostingLine,
  type PostingResult,
  type PostingTransaction,
} from "./types";
import {
  assertBalanced,
  assertBankBelongsTo,
  MISSING_BANK_MESSAGE,
  bankOf,
  bankOwner,
  assertCashAccountsActive,
  assertCashLinesHaveAccount,
  assertEvidencePolicy,
  assertLinesValid,
  assertNoProfitAndLoss,
  assertOwnerSelectable,
  assertRequiredDimensions,
  assertTypeAndSub,
  blankToUndefined,
  line,
  money,
  ownerOf,
  round2,
  totalCredit,
  totalDebit,
} from "./guards";

/**
 * ค่ารีโนเวทที่บันทึกเป็นทุน (1510) เป็นต้นทุนของ **บัญชีอสังหาริมทรัพย์ตัวใดตัวหนึ่ง**
 * ชิ้นเดียวกัน — ใบจำหน่ายอสังหาฯ ต้องตัดสองบัญชีนี้พร้อมกัน
 *
 * **ชุดบัญชี ไม่ใช่รหัสเดียว** — รายชื่ออ่านจาก `PROPERTY_COA` ใน `coa.ts` ที่เดียว
 * (เหตุผลเต็มอยู่ที่คอมเมนต์ของชุดนั้น) · เดิมที่นี่เป็น `"1500"` ตัวเดียว ทำให้
 * หมวดที่เครดิต 1520 (อสังหาฯ เพื่อการขาย) ตัดค่ารีโนเวทไม่ได้ = ขายของที่ตั้งใจขาย
 * ไม่ได้ · ด่านฝั่ง DB อ่านชุดเดียวกันจาก `fn_property_coas()` (20261027041500)
 */
const propertyCoaList = () => (PROPERTY_COA as readonly string[]).join(" / ");

/**
 * ด่านตรวจร่วมอยู่ที่ `guards.ts` — re-export ไว้เพราะหน้าจอและเทสต์เรียกจากที่นี่มาก่อน
 * และเพื่อให้ "ที่เดียวที่สร้างรายการเงิน" ยังเป็นปากทางเดียวที่ผู้เรียกต้องรู้จัก
 */
export { assertBalanced, totalDebit, totalCredit };

/**
 * ทิศของหมวด "เงินต้น + ดอกเบี้ย" — **ครบเคสของ `CashDirection` ไม่มี fallback**
 *
 * ของเดิมเป็น `const isInflow = sub.cash === "in"` → `"both"` และ `"none"`
 * **ตกไปทางเส้นทางเงินออกเงียบๆ** แล้วเงินต้นจะไปลดหนี้สินและดอกเบี้ยจะกลายเป็น
 * ค่าใช้จ่าย ทั้งที่หมวดนั้นไม่ใช่รายการจ่าย
 *
 * วันนี้ยังไม่ถึงเพราะทุกหมวดที่ `requires: principalInterestSplit` เป็น in/out
 * **แต่พึ่งลำดับการตรวจและพึ่งข้อมูลวันนี้ไม่ได้** (D-102: ค่าใหม่ใน union
 * ตกไปทาง fallback เงียบๆ และ TypeScript ไม่ฟ้องเพราะไม่มี map ครบเคส)
 *
 * ข้อมูลไม่เข้าเงื่อนไข = **ปฏิเสธ ห้ามเดา** — เดาผิดที่นี่แปลว่าดอกเบี้ยกับเงินต้น
 * สลับฝั่งกันเงียบๆ ซึ่งเป็นข้อผิดที่ผู้ตรวจจับได้มาแล้วหนึ่งรอบ
 */
export function repaymentDirection(sub: SubCategory): "in" | "out" {
  switch (sub.cash) {
    case "in":
      return "in";
    case "out":
      return "out";
    case "both":
    case "none":
      throw new PostingError(
        `หมวด "${sub.label}" แยกเงินต้นกับดอกเบี้ย แต่ตารางกฎบอกทิศเงินว่า "${sub.cash}" ` +
          `ซึ่งไม่ใช่รับหรือจ่าย — เส้นทางนี้ต้องรู้ว่าเงินต้นไปลดลูกหนี้ (รับคืน) หรือลดหนี้สิน (จ่ายคืน) ` +
          `ถ้าต้องการหมวดแบบนี้จริง ต้องออกแบบคู่บัญชีของมันในตารางกฎก่อน`
      );
  }
}

/**
 * ตรวจว่ากรอกครบตามที่หมวดย่อยบังคับ ก่อนจะลงบัญชี
 *
 * ทรัพย์/คู่ค้าใช้ด่านร่วมที่ `guards.ts` (`assertRequiredDimensions`) เพราะเส้นทาง
 * ล้างยอดค้าง (`buildClearing()`) ต้องบังคับชุดเดียวกัน — กฎเดียวกันห้ามเขียนสองที่
 * ส่วนขายทรัพย์/แยกเงินต้น-ดอกเบี้ยเป็นเรื่องของเส้นทางบันทึกอย่างเดียว จึงอยู่ที่นี่
 */
function assertRequirements(sub: SubCategory, input: PostingInput): void {
  assertRequiredDimensions(sub, input);
  if (sub.requires?.includes("capitalGain") && !input.disposal) {
    throw new PostingError(
      `หมวด "${sub.label}" ต้องระบุต้นทุนและราคาขาย ไม่งั้นจะตัดทรัพย์ผิดจำนวนและไม่รับรู้กำไร/ขาดทุน`
    );
  }
  if (sub.requires?.includes("principalInterestSplit") && !input.repayment) {
    throw new PostingError(
      `หมวด "${sub.label}" ต้องแยกเงินต้นกับดอกเบี้ย ไม่งั้นดอกเบี้ยจะปนกับเงินต้นและหายจากงบกำไรขาดทุน`
    );
  }

  /**
   * ---------- เงินตราต่างประเทศ (FCD) ----------
   *
   * ตัดสินจาก **คู่บัญชีในตารางกฎ** (`isFxTranslationSub` อ่าน 3410 ·
   * `isFxRealisingSub` อ่าน 4330/5930) ไม่ใช่รหัสหมวด — หมวดค่าเงินตัวใหม่
   * จะถูกครอบเองทันที และจะไม่ตกไปเส้นทางโอนธรรมดาที่ไม่สร้างบรรทัดผลต่างเลย
   * (ซึ่งคือสิ่งที่ผู้ตรวจจับได้: แลกที่ 36.50 ขาดทุน 5,000 แต่งบโชว์ 0)
   */
  if (isFxTranslationSub(sub) && !input.fxTranslation) {
    throw new PostingError(
      `หมวด "${sub.label}" ต้องระบุสกุลเงิน ยอดเงินตราคงเหลือ อัตราตามบัญชี และอัตราสิ้นงวด — ` +
        "การแปลงค่าที่ไม่บอกอัตราทั้งสองตัวคือยอดบาทที่ไม่มีใครตรวจย้อนได้ว่ามาจากไหน " +
        "และระบบจะไม่มีทางรู้ว่าส่วนต่างที่ลงไปถูกหรือผิด"
    );
  }
  if (isFxRealisingSub(sub) && !input.fxConversion) {
    throw new PostingError(
      `หมวด "${sub.label}" ต้องระบุจำนวนเงินตราที่แลก อัตราตามบัญชี อัตราที่แลกได้จริง ` +
        "ยอดคงเหลือก่อนแลก และผลต่างที่ค้างอยู่ — ขาดข้อใดข้อหนึ่งแปลว่าคิดกำไร/ขาดทุน " +
        "หรือยอดที่ต้องล้างออกไม่ได้ แล้วผลต่างจะค้างอยู่ในส่วนของเจ้าของและถูกนับซ้ำ"
    );
  }
  /**
   * ส่งข้อมูลเงินตรามากับหมวดที่ไม่ใช่เรื่องค่าเงิน → **ปฏิเสธ ไม่ใช่เมินทิ้ง**
   * (รูปเดียวกับ `input.wht` กับบัญชีธนาคารบนหมวดที่ไม่มีขาเงินสด)
   * เมินทิ้งแปลว่าผู้ใช้กรอกอัตรามาแล้วระบบลงยอดโดยไม่ใช้อัตรานั้นเลย
   */
  if (input.fxTranslation && !isFxTranslationSub(sub)) {
    throw new PostingError(
      `หมวด "${sub.label}" ไม่ใช่การแปลงค่าเงินฝากสกุลต่างประเทศ (ตารางกฎไม่ได้ให้แตะ ` +
        `${coaLabel(FX_TRANSLATION_DIFF_COA)}) จึงรับข้อมูลการแปลงค่าไม่ได้`
    );
  }
  if (input.fxConversion && !isFxRealisingSub(sub)) {
    throw new PostingError(
      `หมวด "${sub.label}" ไม่ใช่การแลกเงินตราเป็นบาท (ตารางกฎไม่ได้ประกาศบัญชีกำไร/ขาดทุน ` +
        "อัตราแลกเปลี่ยน) จึงรับข้อมูลการแลกเงินไม่ได้ — ถ้าเป็นการย้ายเงินตราระหว่างบัญชี " +
        "สกุลเดียวกัน ให้ใช้หมวดโอนปกติ"
    );
  }
}

/* ------------------------------------------------------------------ *
 * เงินตราต่างประเทศ — ตัวช่วยที่ใช้ร่วมกันสองเส้นทาง
 * ------------------------------------------------------------------ */

/**
 * บัญชีที่ต้องเป็น **เงินฝากสกุลต่างประเทศจริง** ของสกุลที่ระบุ
 *
 * ไม่ส่งสกุลมา = **ไม่รู้** ห้ามตีเป็นบาท (ดู `BankInfo.currency`) · บัญชีบาท
 * ลงเส้นทางค่าเงินไม่ได้เลย เพราะยอดบาทของบัญชีบาทไม่ขยับตามอัตราแลกเปลี่ยน
 * การยอมให้ลง = **สร้างเงินสดขึ้นมาจากอากาศ** (ผู้ตรวจวัดได้ +1,000,000 บาท
 * บนบัญชีบาท และยอดนั้นไปซ่อนอยู่ในบรรทัดผลกระทบอัตราแลกเปลี่ยนของงบกระแสเงินสด)
 */
function assertFcdAccount(
  resolve: LedgerResolver,
  bankAccountId: string | undefined,
  currency: string,
  what: string
): BankInfo {
  /**
   * ยังไม่เลือกบัญชี → ใช้ **ข้อความเดียวกับด่านรวม** (`MISSING_BANK_MESSAGE`)
   * ไม่ใช่ข้อความของเส้นทางนี้เอง — ผู้ใช้ที่ยังไม่เลือกบัญชีควรเห็นประโยคเดียวกัน
   * ทุกหมวด และข้อความนี้ถูกตรึงไว้ในเทสต์ที่ไล่ทั้งตารางกฎ (accrual-no-bank)
   */
  if (!bankAccountId) throw new PostingError(MISSING_BANK_MESSAGE);
  const b = bankOf(resolve, bankAccountId);
  if (!b.currency) {
    throw new PostingError(
      `ไม่ทราบสกุลเงินของบัญชี "${b.name}" จึงลง${what}ไม่ได้ — ` +
        "บัญชีที่ไม่บอกสกุลจะถูกนับเป็นบาททั้งก้อน ซึ่งเป็นตัวเลขที่ผิดทั้งงวด · " +
        "ต้องตั้งค่าสกุลเงินของบัญชี (bank_accounts.currency) ก่อน"
    );
  }
  if (b.currency === BASE_CURRENCY) {
    throw new PostingError(
      `บัญชี "${b.name}" เป็นบัญชีบาท จึงลง${what}ไม่ได้ — ยอดบาทของบัญชีบาท ` +
        "ไม่เปลี่ยนตามอัตราแลกเปลี่ยน ถ้ายอมให้ลงเท่ากับสร้างเงินสดขึ้นมาจากอากาศ " +
        "และยอดนั้นจะไปซ่อนในบรรทัดผลกระทบของอัตราแลกเปลี่ยนในงบกระแสเงินสด"
    );
  }
  if (b.currency !== currency) {
    throw new PostingError(
      `บัญชี "${b.name}" เป็นบัญชีสกุล ${b.currency} แต่รายการระบุสกุล ${currency} — ` +
        "สกุลของรายการต้องเป็นสกุลของบัญชีที่เงินตราอยู่จริง (อ่านจากบัญชี ไม่ใช่จากช่องที่กรอก)"
    );
  }
  return b;
}

/** อัตราที่ใช้ได้จริง — ผ่านชุดสกุลเงินชุดเดียวของระบบ (`currency.ts`) */
function checkedRate(currency: string, rate: number, label: string): number {
  const fx = fxCheck({ currency, thbPerUnit: rate });
  if (!fx.ok) throw new PostingError(`${label} — ${fx.why}`);
  if (fx.rate.currency === BASE_CURRENCY) {
    throw new PostingError(
      `${label} — บาทไม่มีอัตราแลกเปลี่ยนกับตัวเอง เส้นทางนี้ใช้กับสกุลต่างประเทศเท่านั้น`
    );
  }
  return fx.rate.thbPerUnit;
}

/** วันของอัตรา — ไม่มี = ไม่รู้ว่าอัตราไหน (FK ฝั่ง DB บังคับว่าต้องมีแถวใน `fx_rates`) */
function checkedRateDate(v: string | undefined, label: string): string {
  const d = blankToUndefined(v);
  if (!d || !/^\d{4}-\d{2}-\d{2}$/.test(d)) {
    throw new PostingError(
      `${label} ต้องเป็นวันที่รูปแบบ YYYY-MM-DD ที่มีอยู่ในตารางอัตราแลกเปลี่ยน — ` +
        "อัตราที่ไม่มีวันกำกับตรวจย้อนไม่ได้ว่าใช้อัตราของวันไหน"
    );
  }
  return d;
}

/**
 * บัญชีค้างรับ/ค้างจ่ายของหมวดนี้ — อ่านจากตารางกฎ ไม่เดา
 *
 * หมวดที่ตารางกฎไม่ได้บอกไว้ แปลว่ายังไม่ได้ตัดสินใจว่าลูกหนี้/เจ้าหนี้ตัวนี้อยู่บรรทัดไหน
 * จึงต้องปฏิเสธ ไม่ใช่ยัดลง "ลูกหนี้อื่น" ให้พ้นๆ ไป
 */
function accrualAccount(sub: SubCategory): string {
  // มีบัญชีพักในตารางกฎ **ไม่พอ** ที่จะตั้งค้างได้จริง — ต้องบอกเหตุผลที่ปฏิเสธให้ตรงจุด
  // เงียบไว้แล้วปล่อยผ่านคือกรณีที่แพงที่สุด: เส้นทางพิเศษจะลงบรรทัดเงินสดตามปกติ
  // ทั้งที่ผู้ใช้ติ๊กว่าเงินยังไม่เข้า (D-068 ห้ามไว้ตรงๆ) โดยไม่มีอะไรฟ้อง
  //
  // เหตุผลมาจากตารางกฎที่เดียว (`accrualCheck()`) ไม่ได้ไล่เงื่อนไขซ้ำที่นี่ —
  // ไม่งั้นข้อความที่ผู้ใช้เห็นกับกฎที่ตัดสินจริงแยกจากกันได้ (บทเรียนข้อ 5)
  const check = accrualCheck(sub);
  if (!check.ok) {
    throw new PostingError(`หมวด "${sub.label}" ยังตั้งค้างรับ-ค้างจ่ายไม่ได้ — ${check.why}`);
  }
  return check.account;
}

/**
 * ภาษีถูกหัก ณ ที่จ่าย — ตัวเลขที่ตรวจแล้วว่า **รายได้เป็นยอดเต็ม** (D-111 ข้อ 1)
 *
 * ด่านใจกลางของทั้งเรื่องอยู่ที่นี่: `withheld` ต้องสอดคล้องกับ `rate × gross`
 * ถ้าผู้ใช้กรอก **ยอดสุทธิที่ได้รับ** ลงช่องจำนวนเงิน (ซึ่งเป็นความเข้าใจผิดที่
 * เป็นธรรมชาติที่สุด เพราะนั่นคือยอดที่เห็นใน statement) สองตัวเลขจะไม่ลงรอยกัน
 * แล้วถูกปฏิเสธพร้อมบอกยอดที่ควรเป็น — **ไม่ใช่ลงบัญชีให้เงียบๆ แล้วรายได้ขาดไป 5%**
 *
 * ยอมคลาดได้ 1 สตางค์ เพราะใบรับรองบางใบปัดเป็นบาทเต็ม · ความคลาดจากการกรอก
 * ยอดสุทธิจะใหญ่กว่านั้นเสมอ (เท่ากับ rate × ภาษีที่ถูกหัก ซึ่งต่ำสุดก็หลายสิบสตางค์)
 *
 * **ความคลาดนี้ใช้ได้เฉพาะตอนเทียบกับเอกสารภายนอกที่ปัดเศษเอง** — การเทียบกับยอดที่
 * อ่านจากสมุดของเราเอง (ดู `assertWholeBalanceMove()`) ต้องตรงเป๊ะ ไม่มีความคลาด
 */
function whtAmounts(
  sub: SubCategory,
  gross: number,
  wht: NonNullable<PostingInput["wht"]>
): { account: string; rate: number; withheld: number; net: number } {
  const check = whtCheck(sub);
  if (!check.ok) {
    throw new PostingError(
      `หมวด "${sub.label}" ถูกหักภาษี ณ ที่จ่ายไม่ได้ — ${check.why} · ` +
        "ถ้าเงินที่เข้าบัญชีไม่เต็มเพราะเหตุอื่น (ค่าธรรมเนียมโอน ฯลฯ) ต้องบันทึกเป็นค่าใช้จ่ายแยกใบ"
    );
  }

  const rate = money(wht.rate, "อัตราภาษีหัก ณ ที่จ่าย");
  if (rate <= 0 || rate >= 100) {
    throw new PostingError(
      `อัตราภาษีหัก ณ ที่จ่ายต้องมากกว่า 0 และน้อยกว่า 100 (ได้ ${rate}) — ` +
        "ไม่ระบุอัตราแล้วคำนวณจากยอดที่หักไว้ย้อนกลับคือการเดา ซึ่งทำให้ตรวจใบรับรองไม่ได้"
    );
  }

  const withheld = money(wht.amount, "ภาษีที่ถูกหักไว้");
  if (withheld <= 0) {
    throw new PostingError(
      "ต้องระบุยอดภาษีที่ถูกหักไว้ให้มากกว่า 0 — ถ้าไม่มีใครหักภาษี ให้ไม่ต้องส่งข้อมูลการหักภาษีมาเลย"
    );
  }
  if (withheld >= gross) {
    throw new PostingError(
      `ภาษีที่ถูกหัก (${withheld}) ต้องน้อยกว่ายอดรายได้เต็มจำนวน (${gross}) — ` +
        "ถ้าเท่ากันหรือมากกว่า แปลว่ากรอกยอดสลับช่องกัน"
    );
  }

  const expected = round2((gross * rate) / 100);
  if (Math.abs(round2(withheld - expected)) > 0.01) {
    throw new PostingError(
      `ยอดเงินของรายการต้องเป็น **ยอดเต็มก่อนหักภาษี** ไม่ใช่ยอดที่เข้าบัญชี — ` +
        `${rate}% ของ ${gross} ต้องเป็น ${expected} แต่ระบุว่าถูกหัก ${withheld} · ` +
        `ถ้า ${withheld} คือยอดที่ถูกหักจริง ยอดเต็มควรเป็น ${round2((withheld * 100) / rate)} ` +
        "(รายได้ต้องเป็นยอดเต็มเสมอ ไม่งั้นรายได้ต่ำกว่าจริงและเครดิตภาษีไม่ตรงใบรับรอง)"
    );
  }

  return { account: check.account, rate, withheld, net: round2(gross - withheld) };
}

/**
 * ข้อมูลการตีราคาที่ตรวจแล้ว (D-111 ข้อ 2)
 *
 * ตรวจ **ทั้งสามตัวคูณกันลงตัว** ไม่ใช่เชื่อยอดบาทที่ส่งมา: ถ้าเชื่อ ยอดบาทจะเป็น
 * ตัวเลขที่ไม่มีใครตรวจย้อนได้ว่ามาจากอัตราไหน ซึ่งเป็นสิ่งที่ลูกพี่สั่งห้ามตรงๆ
 * ("ห้ามเก็บแต่ยอดบาทสุดท้าย ไม่งั้นตรวจย้อนไม่ได้ว่าอัตราไหนถูกใช้")
 */
function checkedRevaluation(
  sub: SubCategory,
  input: PostingInput
): NonNullable<PostingInput["revaluation"]> & { label: string } {
  const rv = input.revaluation;
  if (!rv) {
    throw new PostingError(
      `หมวด "${sub.label}" ต้องระบุสกุลเงิน อัตราแลกเปลี่ยน และมูลค่าในสกุลเดิม — ` +
        "การตีราคาที่ไม่บอกอัตราแลกเปลี่ยนคือยอดบาทที่ไม่มีใครตรวจย้อนได้ว่ามาจากไหน"
    );
  }

  const fx = fxCheck({ currency: rv.currency, thbPerUnit: rv.rateToThb });
  if (!fx.ok) throw new PostingError(`หมวด "${sub.label}" — ${fx.why}`);

  const valueOriginal = money(rv.valueOriginal, "มูลค่าในสกุลเดิม");
  if (valueOriginal <= 0) {
    throw new PostingError(
      "มูลค่าตลาดในสกุลเดิมต้องมากกว่า 0 — ทรัพย์ที่มูลค่าเป็นศูนย์ต้องตัดจำหน่าย ไม่ใช่ตีราคา"
    );
  }

  const valueThb = money(rv.valueThb, "มูลค่าที่แปลงเป็นบาท");
  const computed = toThb(valueOriginal, fx.rate.thbPerUnit);
  if (computed !== valueThb) {
    throw new PostingError(
      `มูลค่าที่แปลงเป็นบาทไม่ตรงกับอัตราที่ระบุ: ${valueOriginal} ${fx.rate.currency} × ` +
        `${fx.rate.thbPerUnit} = ${computed} บาท แต่ระบุมา ${valueThb} บาท — ` +
        "ยอดบาทต้องมาจากมูลค่าสกุลเดิมคูณอัตราที่บันทึกไว้เท่านั้น ไม่ใช่ตัวเลขที่พิมพ์แยก"
    );
  }

  return {
    ...rv,
    currency: fx.rate.currency,
    rateToThb: fx.rate.thbPerUnit,
    valueOriginal,
    valueThb,
    label: `${valueOriginal.toLocaleString("en-US")} ${fx.rate.currency} × ${fx.rate.thbPerUnit} = ${valueThb.toLocaleString("en-US")} บาท`,
  };
}

/* ------------------------------------------------------------------ *
 * ย้ายยอดทั้งก้อนของทรัพย์ระหว่างบัญชี (ธง `wholeBalanceMove` · 27/10)
 * ------------------------------------------------------------------ */

const thb = (n: number) => n.toLocaleString("en-US");

/**
 * **ยอดที่ย้ายต้องเท่ากับยอดคงเหลือของทรัพย์ชิ้นนั้นในบัญชีต้นทางพอดี**
 *
 * ช่องที่ปิด (ผู้ตรวจวัดได้ 27/10): หมวดย้ายวัตถุประสงค์อสังหาฯ ไหลผ่านเส้นทาง
 * รายการปกติสองบรรทัดซึ่งรับ `amount` ที่ผู้ใช้พิมพ์มาตรงๆ → คอนโดที่สมุดมี
 * 3,000,000 ถูกย้ายด้วยยอด 30,000,000 ได้ แล้ว **ยอดรวมต่อทรัพย์ไม่เปลี่ยน**
 * (ออกบัญชีหนึ่ง เข้าบัญชีหนึ่ง เท่ากัน) จึงไม่มีด่านฝั่ง DB ตัวใดฟ้อง
 * ทั้ง `fn_assert_asset_cost_sane` และ `fn_assert_asset_whole_disposal`
 * ตัดสินจาก "ต้นทุนที่ถูกตัดออก" ซึ่งเป็น 0 ในใบนี้
 *
 * หลักที่ยึด (D-115): **เครื่องยนต์ไม่เชื่อยอดที่พิมพ์** ผู้เรียกต้องส่งยอดคงเหลือ
 * ที่อ่านจากสมุดที่ post แล้วมาคู่กับรหัสบัญชีที่อ่านมา แล้ว engine เทียบเอง
 * — รูปเดียวกับ `assetCostBefore`/`priorSurplus` ของใบขาย: ส่งไม่ครบคู่ = ปฏิเสธ
 * (ยอดลอยๆ ที่ไม่บอกว่าอ่านมาจากบัญชีไหน ตรวจไม่ได้ว่าอ่านถูกบัญชี)
 *
 * **แยกสาขาด้วยธงในตารางกฎ ไม่ใช่รหัสหมวด** (กฎเหล็กข้อ 5) และยืนยัน **รูปของ
 * คู่บัญชี** ทุกครั้งที่เข้าสาขานี้ เพื่อให้ธงที่ไปติดหมวดผิดพังเสียงดัง
 * ไม่ใช่กลายเป็นด่านที่ตรวจของผิดชนิด
 */
function assertWholeBalanceMove(sub: SubCategory, input: PostingInput, amount: number): void {
  if (!sub.requires?.includes("wholeBalanceMove")) {
    /**
     * ส่งยอดคงเหลือมากับหมวดที่ไม่ใช่การย้าย → **ปฏิเสธ ไม่ใช่เมินทิ้ง**
     * (รูปเดียวกับ `fxTranslation`/`fxConversion` บนหมวดที่ไม่ใช่เรื่องค่าเงิน)
     * เมินทิ้งแปลว่าผู้ใช้ส่งยอดจากสมุดมาแล้วระบบลงยอดโดยไม่ใช้ยอดนั้นเลย
     */
    if (input.balanceMove) {
      throw new PostingError(
        `หมวด "${sub.label}" ไม่ใช่การย้ายยอดทั้งก้อนระหว่างบัญชีของทรัพย์ชิ้นเดียวกัน ` +
          "(ตารางกฎไม่ได้ตั้งธงนี้ไว้) จึงรับยอดคงเหลือของบัญชีต้นทางไม่ได้"
      );
    }
    return;
  }

  // ---------- รูปของคู่บัญชีต้องเป็นการย้ายจริง ----------
  for (const [side, code] of [["ต้นทาง", sub.cr], ["ปลายทาง", sub.dr]] as const) {
    if (coa(code).type !== "asset" || isCashAccount(code)) {
      throw new PostingError(
        `ตารางกฎตั้งหมวด "${sub.label}" เป็นการย้ายยอดทั้งก้อน แต่บัญชี${side} ` +
          `${coaLabel(code)} ไม่ใช่บัญชีสินทรัพย์ที่ไม่ใช่เงินสด — การย้ายต้องเป็น ` +
          "สินทรัพย์ ↔ สินทรัพย์ ถ้ามีขาเงินสดหรือขา P&L นี่คือการซื้อ/ขาย ไม่ใช่การย้าย"
      );
    }
  }
  if (sub.dr === sub.cr) {
    throw new PostingError(`หมวด "${sub.label}" ย้ายเข้าบัญชีเดียวกับที่ย้ายออก — ไม่มีอะไรเปลี่ยน`);
  }

  const bm = input.balanceMove;
  if (!bm) {
    throw new PostingError(
      `หมวด "${sub.label}" ต้องส่ง **ยอดคงเหลือของทรัพย์ชิ้นนี้ใน ${coaLabel(sub.cr)} ที่อ่านจากสมุด** ` +
        "มาด้วย (balanceMove) — ระบบย้ายได้เฉพาะทั้งก้อน และยอดที่ผู้ใช้พิมพ์เชื่อไม่ได้: " +
        "พิมพ์เกินยอดที่ถืออยู่จะทำให้บัญชีต้นทางติดลบโดยที่ยอดรวมของทรัพย์ไม่เปลี่ยน " +
        "และไม่มีด่านไหนฟ้อง · ยอดต้องอ่านจาก fn_asset_account_balance ของสมุดที่ post แล้ว " +
        "ไม่ใช่จาก state ของหน้าจอ"
    );
  }

  // ส่งมาไม่ครบคู่ = ปฏิเสธ (D-115) — ยอดที่ไม่รู้ว่าอ่านจากบัญชีไหน ตรวจไม่ได้
  if (!blankToUndefined(bm.sourceCoaCode) || bm.sourceBalance === undefined) {
    throw new PostingError(
      `หมวด "${sub.label}" ต้องส่งรหัสบัญชีต้นทางที่อ่านยอดมา (sourceCoaCode) และยอดคงเหลือ ` +
        "(sourceBalance) **คู่กัน** — ส่งมาไม่ครบคู่ตรวจไม่ได้ว่ายอดนั้นเป็นยอดของบัญชีที่ใบนี้จะย้ายออกจริง"
    );
  }

  if (bm.sourceCoaCode !== sub.cr) {
    throw new PostingError(
      `ยอดคงเหลือที่ส่งมาอ่านจาก ${coaLabel(bm.sourceCoaCode)} แต่บัญชีต้นทางของหมวด ` +
        `"${sub.label}" คือ ${coaLabel(sub.cr)} — ยอดของบัญชีอื่นบอกไม่ได้ว่าใบนี้ย้ายออกทั้งก้อนหรือไม่`
    );
  }

  const balance = money(bm.sourceBalance, `ยอดคงเหลือใน ${coaLabel(sub.cr)} ของทรัพย์ชิ้นนี้`);
  if (balance === 0) {
    throw new PostingError(
      `ทรัพย์ชิ้นนี้ไม่มียอดคงเหลือใน ${coaLabel(sub.cr)} ตามสมุด (0 บาท) จึงไม่มีอะไรให้ย้าย — ` +
        "ลงใบซื้อหรือยอดยกมาของทรัพย์ชิ้นนี้ให้ครบก่อน ไม่ใช่ย้ายต้นทุนที่ไม่มีอยู่"
    );
  }

  /**
   * **ตรงเป๊ะ ไม่มีความคลาด** — ห้ามเอา `> 0.01` กลับมาใส่ (ผู้ตรวจข้อ 3 · 27/10)
   *
   * ความคลาดหนึ่งสตางค์มีเหตุผลตอนเทียบกับ **เอกสารภายนอกที่ปัดเศษ**
   * (ดู `checkedWithholding()` ข้างบน: ใบรับรองหัก ณ ที่จ่ายปัดยอดภาษีเอง
   * จึงต่างจาก `gross × rate` ได้โดยไม่มีใครผิด) แต่ที่นี่ `balance` คือยอดที่
   * **อ่านจากสมุดของเราเอง** (`fn_asset_account_balance`) ซึ่งเป็นผลบวกของบรรทัด
   * ที่เก็บเป็น numeric ทศนิยมสองตำแหน่ง → ไม่มีแหล่งของการปัดเศษเลย
   *
   * และยอมคลาดที่นี่ **เสียด่านที่พูดเป็นภาษาคนไปเปล่าๆ**: ต่างหนึ่งสตางค์
   * engine ปล่อยผ่าน แล้วไปถูก `trg_assert_asset_account_balance_nonneg`
   * ปฏิเสธที่ DB (ด่านนั้นเทียบ `round(...) <> 0` ตรงเป๊ะ) — ผู้ใช้จะเห็น
   * error ของฐานข้อมูลแทนข้อความของฟอร์ม และบัญชีต้นทางค้างหนึ่งสตางค์
   * ไม่ได้ถูกยอมให้เกิดอยู่ดี
   */
  if (round2(amount - balance) !== 0) {
    throw new PostingError(
      `หมวด "${sub.label}" ย้ายได้เฉพาะ **ทั้งก้อน**: ยอดคงเหลือของทรัพย์ชิ้นนี้ใน ` +
        `${coaLabel(sub.cr)} ตามสมุดคือ ${thb(balance)} บาท แต่ใบนี้ย้าย ${thb(amount)} บาท — ` +
        `ย้ายมากกว่าที่ถืออยู่ทำให้ ${coaLabel(sub.cr)} ติดลบ ${thb(round2(amount - balance))} บาท ` +
        "โดยยอดรวมของทรัพย์ไม่เปลี่ยน (ไม่มีด่านต้นทุนตัวไหนฟ้อง) · ย้ายน้อยกว่าทำให้ทรัพย์ชิ้นเดียว " +
        "ค้างอยู่สองวัตถุประสงค์พร้อมกัน ซึ่งงบดุลอ่านไม่ออกว่าถือไว้เพื่ออะไร · " +
        "ถ้าต้องการย้ายบางส่วนจริง ต้องแยกทรัพย์เป็นสองชิ้นก่อน (D-112)"
    );
  }
}


/**
 * สร้างรายการบัญชีจากสิ่งที่ผู้ใช้กรอก
 *
 * ปกติได้หนึ่ง transaction สองบรรทัดตามคู่บัญชีในตารางกฎ ยกเว้น:
 * - ขายทรัพย์ → เพิ่มบรรทัดกำไร/ขาดทุน (Backlog ข้อ 4)
 * - คืนเงินกู้ / รับคืนเงินต้น → แยกเงินต้นกับดอกเบี้ย (Backlog ข้อ 5)
 * - โอนภายในผู้ถือเดียวกัน → สองบรรทัดเงินสด คนละบัญชี
 * - โอนข้ามผู้ถือ → **สอง transaction คู่กัน** ฝ่ายละหนึ่ง (Money Invariant 3)
 */
export function buildPostingDraft(input: PostingInput, resolve: LedgerResolver): PostingResult {
  // ประเภท + หมวดย่อยผ่านปากทางเดียวที่แปลงข้อมูลไม่ครบเป็น PostingError (ดู guards.ts)
  const { sub } = assertTypeAndSub(input.typeKey, input.subCode);
  const amount = money(input.amount, "จำนวนเงิน");
  if (amount === 0) throw new PostingError("จำนวนเงินต้องมากกว่า 0");

  /**
   * บัญชีต้นทาง — **ยังไม่บังคับที่นี่**
   *
   * การบังคับบัญชีย้ายไปอยู่ท้ายฟังก์ชัน (`assertCashLinesHaveAccount()`) ซึ่งตัดสินจาก
   * บรรทัดที่สร้างได้จริง เพราะด่านที่เช็คช่องใน input ก่อนแยกสาขาจะ **ไม่สนใจ
   * `notYetPaid` เลย** แล้วเส้นทางค้างรับ-ค้างจ่าย (ที่ตั้งใจให้ไม่มีขาเงินสด
   * และตอนตั้งค้างยังไม่รู้ว่าเงินจะเข้าบัญชีไหน) ใช้ไม่ได้ทั้งเส้น
   *
   * `""` จากฟอร์มกับ `undefined` แปลว่า "ยังไม่เลือก" เหมือนกัน — ถ้าไม่ทำให้เท่ากัน
   * `""` จะถูกส่งต่อไปค้นหาบัญชีแล้วล้มด้วยข้อความ "ไม่พบบัญชีธนาคาร: " ซึ่งชี้ผิดจุด
   */
  const bankAccountId = blankToUndefined(input.bankAccountId);

  // ผู้ถือต้องถือทรัพย์ได้จริงก่อน ไม่งั้นข้อความจะไปโผล่เป็น "บัญชีไม่ตรงผู้ถือ" ซึ่งชี้ผิดจุด
  assertOwnerSelectable(resolve, input.ownerId);

  // ถ้าส่งบัญชีมา ต้องมีอยู่จริงและเป็นของผู้ถือที่ระบุ **เสมอ** ไม่ว่าเส้นทางไหน —
  // รวมเส้นทางค้างรับ-ค้างจ่ายที่ไม่ได้ใช้บัญชี เพราะบัญชีผิดคนที่ติดมากับรายการ
  // จะถูกใช้ตอนยืนยันเงินเข้า-ออกภายหลัง แล้วเงินไปโผล่ในงบของคนอื่น (บทเรียนข้อ 2)
  if (bankAccountId) assertBankBelongsTo(resolve, bankAccountId, input.ownerId);

  /**
   * หมวดที่ **ไม่มีเงินเคลื่อน** ส่งบัญชีมา = ปฏิเสธ ไม่ใช่เมินทิ้ง
   *
   * เมินทิ้งคือทางที่แพงที่สุด: บัญชีจะไม่ปรากฏในบรรทัดใดเลย (ไม่มีขาเงินสดให้ติด)
   * แต่ค่านั้นยังอยู่ในฟอร์ม/ใน draft แล้วถูกหยิบไปใช้ตอนขั้นยืนยันรับ-จ่ายหรือ
   * ตอนกระทบยอด → รายการที่ไม่เคยมีเงินเคลื่อนจะไปโผล่เป็นความเคลื่อนไหวของบัญชีนั้น
   * (รูปแบบเดียวกับข้อ 7 ของผู้ตรวจ: bank_account_id ติดบรรทัดที่ไม่ใช่เงินสด)
   *
   * อ่านจาก `movesCash()` ในตารางกฎ ไม่ได้ไล่ชื่อหมวด — หมวด `none` ตัวถัดไปจึงไม่หลุด
   */
  if (!movesCash(sub) && bankAccountId) {
    throw new PostingError(
      `หมวด "${sub.label}" เป็นรายการปรับปรุงทางบัญชี ไม่มีเงินเข้าหรือออกบัญชีเลย ` +
        "จึงต้องไม่ระบุบัญชีธนาคาร — บัญชีที่ติดมากับรายการที่ไม่มีขาเงินสดจะถูกนับเป็น" +
        "ความเคลื่อนไหวของบัญชีนั้นตอนกระทบยอด ทั้งที่เงินไม่ได้เข้าออก"
    );
  }

  assertRequirements(sub, input);

  /**
   * ย้ายยอดทั้งก้อน — ตรวจที่นี่ (หลัง `assertRequirements`) เพราะต้องใช้ `amount`
   * ที่ผ่าน `money()` แล้ว และต้องให้ข้อความ "ต้องผูกทรัพย์" มาก่อนเสมอ
   * (ไม่รู้ว่าย้ายทรัพย์ชิ้นไหน ก็ยังไม่มีความหมายที่จะพูดถึงยอดคงเหลือของมัน)
   *
   * ด่านนี้บังคับทั้งสองทิศ: หมวดที่มีธงต้องส่งยอดมา · หมวดที่ไม่มีธงส่งยอดมาไม่ได้
   */
  assertWholeBalanceMove(sub, input, amount);

  // เส้นทางพิเศษทั้งสามล้วนเป็นเรื่องของเงินที่เคลื่อนแล้ว — ตั้งค้างไม่ได้
  // โอนที่ยังไม่โอนคือยังไม่เกิดรายการ · ขายที่ยังไม่ได้รับเงินต้องบันทึกเป็นลูกหนี้ของทรัพย์แยกต่างหาก
  //
  // ถามจาก `canAccrueFromForm()` ไม่ใช่จาก `!sub.accrualCoa` — ตั้งแต่ D-069 เติมบัญชีพัก
  // ให้ทุกหมวดที่เงินเคลื่อนจริง การเช็คแค่ว่า "มีบัญชีพักไหม" จะปล่อยเส้นทางพิเศษผ่าน
  // ไปถึงสาขาที่ **ไม่สนใจ `notYetPaid` เลย** แล้วลงบรรทัดเงินสดเงียบๆ
  if (input.notYetPaid) accrualAccount(sub);

  /**
   * ส่งข้อมูลการถูกหักภาษีมากับหมวดที่หักไม่ได้ → **ปฏิเสธ ไม่ใช่เมินทิ้ง**
   *
   * เมินทิ้งคือทางที่แพงที่สุด (รูปแบบเดียวกับบัญชีธนาคารบนรายการที่ไม่มีขาเงินสด):
   * เส้นทางพิเศษทั้งสี่ (โอน · ขายทรัพย์ · แยกเงินต้น-ดอกเบี้ย · ตีราคา) ประกอบ
   * บรรทัดเงินสดเองและ **ไม่เคยอ่าน `input.wht` เลย** → ยอดจะถูกลงเต็มจำนวน
   * ทั้งที่เงินเข้าไม่เต็ม แล้วยอดธนาคารในระบบไม่ตรง statement (Money Invariant 5)
   * ส่วนค่า `rate`/`certificateNo` จะยังติดไปกับรายการและถูกอ่านต่อตอนทำรายงานภาษี
   *
   * ถามจาก `whtCheck()` ในตารางกฎ ไม่ได้ไล่ชื่อหมวด — หมวดใหม่จึงไม่หลุด
   */
  if (input.wht && !whtCheck(sub).ok) {
    throw new PostingError(
      `หมวด "${sub.label}" ถูกหักภาษี ณ ที่จ่ายไม่ได้ — ${(whtCheck(sub) as { ok: false; why: string }).why} · ` +
        "ภาษีหัก ณ ที่จ่ายหักจากเงินได้เท่านั้น ไม่ใช่จากการรับคืนเงินต้น เงินมัดจำ หรือการโอนเงินตัวเอง"
    );
  }

  const summary: string[] = [sub.plain];
  const transactions: PostingTransaction[] = [];

  if (isFxTranslationSub(sub)) {
    /* ---------- แปลงค่าเงินฝากสกุลต่างประเทศสิ้นงวด (FCD) ----------
     *
     * **จำนวนเงินตราไม่เปลี่ยน** เปลี่ยนแต่ยอดบาท → ผลต่างเข้าส่วนของเจ้าของ (3410)
     * ไม่เข้า P&L เลย (ลูกพี่สั่งตรงๆ: กำไรค่าเงินที่ยังไม่ได้แลกไม่ใช่กำไรจริง)
     *
     * ยอดบาทไม่ได้เชื่อจากช่องที่ผู้ใช้กรอก — engine คิดจาก
     * `ยอดเงินตรา × (อัตราใหม่ − อัตราตามบัญชี)` แล้วเทียบกับ `amount`
     * ไม่ตรง = ปฏิเสธ · ทิศอ่านจากคู่บัญชีในตารางกฎ (ขาไหนคือ 3410) ไม่ใช่รหัสหมวด
     */
    const tr = input.fxTranslation!;
    const fcd = assertFcdAccount(
      resolve,
      bankAccountId,
      tr.currency,
      "การแปลงค่าเงินฝากสกุลต่างประเทศ"
    );
    const currency = fcd.currency as string;
    const balance = money(tr.balanceOriginal, "ยอดเงินตราคงเหลือในบัญชี");
    if (balance <= 0) {
      throw new PostingError(
        "ยอดเงินตราคงเหลือต้องมากกว่า 0 — บัญชีที่ไม่มีเงินตราอยู่ไม่มีอะไรให้แปลงค่า · " +
          "ค่านี้ต้องอ่านจากสมุดที่ post แล้วจริง ไม่ใช่จากหน้าจอ"
      );
    }
    const bookRate = checkedRate(currency, tr.bookRateToThb, "อัตราตามบัญชี");
    const bookRateDate = checkedRateDate(tr.bookRateDate, "วันของอัตราตามบัญชี");
    const newRate = checkedRate(currency, tr.newRateToThb, "อัตราสิ้นงวด");
    const newRateDate = checkedRateDate(tr.newRateDate, "วันของอัตราสิ้นงวด");

    const thbBefore = toThb(balance, bookRate);
    const thbAfter = toThb(balance, newRate);
    const diff = round2(thbAfter - thbBefore);
    // ขา 3410 อยู่ฝั่งเครดิต = ยอดบาทเพิ่ม · อยู่ฝั่งเดบิต = ยอดบาทลด
    const up = isFxTranslationAccount(sub.cr);

    if (diff === 0) {
      throw new PostingError(
        `อัตรา ${bookRate} กับ ${newRate} ให้ยอดบาทเท่ากัน (${thbAfter}) จึงไม่มีผลต่างให้ลง — ` +
          "ลงรายการที่ไม่เปลี่ยนอะไรคือการเพิ่มใบเปล่าเข้าสมุด"
      );
    }
    if (up !== diff > 0) {
      throw new PostingError(
        `หมวด "${sub.label}" ใช้กับการที่ยอดบาท${up ? "เพิ่ม" : "ลด"} แต่อัตราที่ระบุทำให้ยอดบาท` +
          `${diff > 0 ? "เพิ่ม" : "ลด"} ${Math.abs(diff).toLocaleString("en-US")} บาท ` +
          `(${balance.toLocaleString("en-US")} ${currency} จาก ${bookRate} เป็น ${newRate}) — ` +
          "ต้องใช้หมวดให้ตรงทิศ ไม่ใช่กลับเครื่องหมายให้เอง เพราะผลต่างจะไปอยู่ผิดด้าน " +
          "ของส่วนของเจ้าของแล้วยอดบาทของบัญชีจะวิ่งไปทางตรงข้ามกับอัตราจริง"
      );
    }
    const magnitude = Math.abs(diff);
    if (magnitude !== amount) {
      throw new PostingError(
        `ผลต่างจากการแปลงค่าคือ ${magnitude.toLocaleString("en-US")} บาท ` +
          `(${balance.toLocaleString("en-US")} ${currency} × (${newRate} − ${bookRate})) ` +
          `แต่กรอกยอดมา ${amount.toLocaleString("en-US")} — ยอดบาทต้องมาจากอัตรา ` +
          "ไม่ใช่ตัวเลขที่พิมพ์แยกกัน (ด่านฝั่ง DB ปฏิเสธส่วนต่างแม้สตางค์เดียว)"
      );
    }

    /**
     * ทั้งสองขาแนบข้อมูลอัตราครบ — รวม **ขา 3410** (ผู้ตรวจ BLOCK ข้อ 1)
     *
     * ขา 3410 ไม่มีบัญชีธนาคารให้อ้าง (ด่าน DB ห้ามบัญชีธนาคารบนบรรทัดที่ไม่ใช่
     * เงินสด) สกุลบนบรรทัดจึงเป็นตัวเดียวที่บอกว่าผลต่างก้อนนี้เป็นของสกุลไหน
     * ถ้าปล่อยว่าง ด่าน "แลกหมดแล้วต้องล้างให้เหลือศูนย์" มองก้อนนั้นไม่เห็น
     * แล้วกำไรก้อนเดียวถูกนับสองครั้ง (วัดได้: 3410 ค้าง 5,000 พร้อม 4330 รับรู้ 5,000)
     *
     * `amountOriginal: 0` เพราะ **ไม่มีเงินตราเคลื่อน** — ไม่ใช่ `undefined`
     * เพราะ undefined แปลว่า "บรรทัดบาทตรงๆ" ซึ่งจะทำให้ข้อมูลอัตราหายทั้งใบ
     */
    const fx = { currency, amountOriginal: 0, fxRate: newRate, fxRateDate: newRateDate };
    const memo =
      `แปลงค่า ${balance.toLocaleString("en-US")} ${currency} ` +
      `จากอัตรา ${bookRate} (${bookRateDate}) เป็น ${newRate} (${newRateDate})`;

    const cashLine = line({
      coaCode: CASH_COA,
      bankAccountId: fcd.id,
      cfCategory: sub.cashflow,
      memo,
      ...fx,
      ...(up ? { debit: magnitude } : { credit: magnitude }),
    });
    const diffLine = line({
      coaCode: FX_TRANSLATION_DIFF_COA,
      cfCategory: sub.cashflow,
      memo,
      ...fx,
      ...(up ? { credit: magnitude } : { debit: magnitude }),
    });
    const lines: PostingLine[] = up ? [cashLine, diffLine] : [diffLine, cashLine];

    // ด่านเดียวกับที่รายการตีราคาใช้ — กันการ "เผลอแก้คู่บัญชีวันหลัง" ให้ไปแตะ P&L
    assertNoProfitAndLoss(lines, `การแปลงค่าเงินฝากสกุลต่างประเทศ "${sub.label}"`);

    transactions.push({ ownerId: input.ownerId, lines });
    summary.push(
      `ยอดบาทของบัญชี "${fcd.name}" ${up ? "เพิ่ม" : "ลด"} ${magnitude.toLocaleString("en-US")} บาท ` +
        `(${thbBefore.toLocaleString("en-US")} → ${thbAfter.toLocaleString("en-US")}) ` +
        `โดยจำนวนเงินตรายังเป็น ${balance.toLocaleString("en-US")} ${currency} เท่าเดิม`
    );
    summary.push(
      `ผลต่างลงที่ ${coaLabel(FX_TRANSLATION_DIFF_COA)} ในส่วนของเจ้าของ **ไม่เข้างบกำไรขาดทุน** — ` +
        "กำไร/ขาดทุนค่าเงินรับรู้ตอนแลกเป็นบาทจริงเท่านั้น และห้ามนำยอดนี้ไปจ่ายปันผล"
    );
    summary.push(
      "ไม่ใช่กระแสเงินสดของงวด — ไปอยู่บรรทัดผลกระทบของอัตราแลกเปลี่ยนต่อเงินสด (IAS 7.28)"
    );
  } else if (isFxRealisingSub(sub)) {
    /* ---------- แลกเงินตราเป็นบาทจริง — จุดที่กำไร/ขาดทุนค่าเงิน "เกิดขึ้นจริง" ----------
     *
     * ใบเดียวทำสองเรื่องพร้อมกัน (รูปเดียวกับใบขายทรัพย์ที่ล้าง 3400):
     *   1. ตัดเงินตราออกตาม **อัตราตามบัญชี** · รับบาทตาม **อัตราที่แลกได้จริง**
     *   2. **ล้างผลต่างที่ค้างใน 3410 ตามสัดส่วนที่แลกออก** แล้วรวมเข้ากำไร/ขาดทุน
     *
     * ก่อนแก้เส้นทางนี้ไม่มีอยู่: หมวดนี้มีธง `transferTarget` จึงตกไปเส้นทาง
     * โอนธรรมดาที่สร้างแค่สองบรรทัดเงินสดเท่ากัน → **ไม่มีบรรทัดกำไร/ขาดทุน
     * ไม่มีบรรทัดล้าง 3410 และไม่มีข้อมูลอัตราเลย** การแลกที่ 36.50 ซึ่งขาดทุน
     * 5,000 บาทจึงแสดงผลเป็น 0 (ผู้ตรวจ BLOCK ข้อ 3)
     */
    const cv = input.fxConversion!;
    const fcd = assertFcdAccount(resolve, bankAccountId, cv.currency, "การแลกเงินตราเป็นบาท");
    const currency = fcd.currency as string;

    const to = blankToUndefined(input.transferToBankAccountId);
    if (!to) {
      throw new PostingError("การแลกเงินตราเป็นบาทต้องระบุบัญชีบาทที่รับเงินเข้า");
    }
    if (to === fcd.id) {
      throw new PostingError("แลกเงินเข้าบัญชีเดียวกับบัญชีที่เงินตราออกไม่ได้");
    }
    // อ่านสกุลและผู้ถือ **จากบัญชีปลายทางเอง** ไม่เชื่อฟิลด์ที่ผู้ใช้เว้นได้ (บทเรียนข้อ 2)
    const dest = bankOf(resolve, to);
    if (!dest.currency) {
      throw new PostingError(
        `ไม่ทราบสกุลเงินของบัญชีปลายทาง "${dest.name}" จึงบันทึกการแลกเงินไม่ได้ — ` +
          "ปลายทางที่ไม่บอกสกุลอาจเป็นบัญชีเงินตราอีกใบ ซึ่งไม่ใช่การแลกเป็นบาท"
      );
    }
    if (dest.currency !== BASE_CURRENCY) {
      throw new PostingError(
        `บัญชีปลายทาง "${dest.name}" เป็นบัญชีสกุล ${dest.currency} ไม่ใช่บัญชีบาท — ` +
          "การย้ายเงินตราไปอีกบัญชีของสกุลเดียวกันยังไม่ใช่การแลกเงิน จึงยังไม่รับรู้กำไร/ขาดทุน " +
          "ให้ใช้หมวดโอนระหว่างบัญชีตัวเอง · กำไร/ขาดทุนค่าเงินรับรู้ตอนได้บาทจริงเท่านั้น"
      );
    }
    if (dest.ownerId !== input.ownerId) {
      throw new PostingError(
        `บัญชีปลายทาง "${dest.name}" เป็นของ ${ownerOf(resolve, dest.ownerId).name} — ` +
          "การแลกเงินตราต้องเข้าบัญชีบาทของผู้ถือเดียวกัน เพราะใบนี้ล้างผลต่างที่ค้างอยู่ " +
          "ของผู้ถือนั้นพร้อมกัน · ถ้าจะส่งเงินให้ผู้ถืออื่น ให้แลกเป็นบาทก่อน แล้วโอนเป็นอีกรายการ"
      );
    }

    const amountOriginal = money(cv.amountOriginal, "จำนวนเงินตราที่แลก");
    if (amountOriginal <= 0) {
      throw new PostingError("จำนวนเงินตราที่แลกต้องมากกว่า 0");
    }
    const before = money(cv.balanceOriginalBefore, "ยอดเงินตราคงเหลือก่อนแลก");
    if (amountOriginal > before) {
      throw new PostingError(
        `แลกออก ${amountOriginal.toLocaleString("en-US")} ${currency} มากกว่ายอดคงเหลือ ` +
          `${before.toLocaleString("en-US")} ${currency} — เงินตราติดลบไม่ได้ ` +
          "(ด่านฝั่ง DB ปฏิเสธอยู่ดี) · ถ้ามีเงินเข้าที่ยังไม่ลง ต้องลงใบนั้นก่อน"
      );
    }

    const bookRate = checkedRate(currency, cv.bookRateToThb, "อัตราตามบัญชี");
    const bookRateDate = checkedRateDate(cv.bookRateDate, "วันของอัตราตามบัญชี");
    const dealRate = checkedRate(currency, cv.dealRateToThb, "อัตราที่แลกได้จริง");
    const dealRateDate = checkedRateDate(cv.dealRateDate, "วันของอัตราที่แลกได้จริง");

    const thbOut = toThb(amountOriginal, bookRate); // ยอดตามบัญชีที่ตัดออกจากบัญชีเงินตรา
    const thbIn = toThb(amountOriginal, dealRate); // บาทที่ได้รับจริง
    if (thbIn !== amount) {
      throw new PostingError(
        `บาทที่ได้รับต้องเท่ากับ ${amountOriginal.toLocaleString("en-US")} ${currency} × ` +
          `${dealRate} = ${thbIn.toLocaleString("en-US")} บาท แต่กรอกยอดมา ` +
          `${amount.toLocaleString("en-US")} — ยอดบาทต้องมาจากอัตราที่แลกได้จริง ` +
          "ไม่ใช่ตัวเลขที่พิมพ์แยกกัน"
      );
    }

    /**
     * ผลต่างที่ต้องล้างออก = **สัดส่วนที่แลกออก × ผลต่างทั้งก้อน**
     * สมการเดียวกับ D-112 (`surplusToReverseFor()`) ที่ด่านฝั่ง DB ใช้ตัวต่อตัว
     * แลกหมด → ล้างทั้งก้อนพอดี ไม่เหลือเศษค้างใน 3410 (ด่าน DB บังคับข้อนี้)
     */
    const released = surplusToReverseFor({
      priorSurplus: cv.unrealizedBefore,
      costBefore: before,
      costRemoved: amountOriginal,
    });
    // กำไรที่รับรู้จริง = บาทที่ได้ − ยอดตามบัญชีที่ตัดออก + ผลต่างที่เคยตั้งไว้แล้ว
    const realised = round2(thbIn - thbOut + released);

    if (!sub.gainCoa || !sub.lossCoa) {
      throw new PostingError(
        `หมวด "${sub.label}" ไม่ได้ระบุบัญชีกำไรและขาดทุนอัตราแลกเปลี่ยนไว้ครบในตารางกฎ`
      );
    }

    const dealLabel = `${amountOriginal.toLocaleString("en-US")} ${currency} @ ${dealRate}`;
    const lines: PostingLine[] = [
      line({
        coaCode: CASH_COA,
        bankAccountId: dest.id,
        debit: thbIn,
        cfCategory: sub.cashflow,
        memo: `รับบาทจากการแลก ${dealLabel}`,
      }),
      line({
        coaCode: CASH_COA,
        bankAccountId: fcd.id,
        credit: thbOut,
        cfCategory: sub.cashflow,
        currency,
        amountOriginal,
        fxRate: bookRate,
        fxRateDate: bookRateDate,
        memo: `ตัดเงินตราออกตามอัตราตามบัญชี ${bookRate}`,
      }),
    ];

    if (released !== 0) {
      // ล้างผลต่างของสกุลนี้ออกจากส่วนของเจ้าของ — ขานี้ต้องมีสกุลกำกับเสมอ
      const magnitude = Math.abs(released);
      lines.push(
        line({
          coaCode: FX_TRANSLATION_DIFF_COA,
          cfCategory: sub.cashflow,
          currency,
          amountOriginal: 0,
          fxRate: dealRate,
          fxRateDate: dealRateDate,
          memo:
            released > 0
              ? "ล้างผลต่างอัตราแลกเปลี่ยนที่เคยตั้งไว้ (ยอดบาทเคยเพิ่ม)"
              : "ล้างผลต่างอัตราแลกเปลี่ยนที่เคยตั้งไว้ (ยอดบาทเคยลด)",
          ...(released > 0 ? { debit: magnitude } : { credit: magnitude }),
        })
      );
    }

    if (realised > 0) {
      lines.push(
        line({ coaCode: sub.gainCoa, credit: realised, memo: `กำไรจากอัตราแลกเปลี่ยนที่เกิดขึ้นจริง` })
      );
    } else if (realised < 0) {
      lines.push(
        line({
          coaCode: sub.lossCoa,
          debit: Math.abs(realised),
          memo: `ขาดทุนจากอัตราแลกเปลี่ยนที่เกิดขึ้นจริง`,
        })
      );
    }

    transactions.push({ ownerId: input.ownerId, lines });

    summary.push(
      `แลก ${dealLabel} ได้ ${thbIn.toLocaleString("en-US")} บาท · ` +
        `ตัดเงินตราออกตามอัตราตามบัญชี ${bookRate} = ${thbOut.toLocaleString("en-US")} บาท`
    );
    if (released !== 0) {
      summary.push(
        `ล้างผลต่างที่ค้างในส่วนของเจ้าของ ${released.toLocaleString("en-US")} บาทออกพร้อมกัน ` +
          `(${cv.unrealizedBefore.toLocaleString("en-US")} × ${amountOriginal}/${before} ` +
          "ตามสัดส่วนที่แลกออก) — ไม่ล้างคือนับซ้ำกับกำไรที่รับรู้"
      );
    }
    if (realised === 0) {
      summary.push("แลกได้เท่ากับยอดตามบัญชีพอดี ไม่มีกำไรหรือขาดทุนที่ต้องรับรู้");
    } else {
      summary.push(
        `${realised > 0 ? "กำไร" : "ขาดทุน"}จากอัตราแลกเปลี่ยนที่เกิดขึ้นจริง ` +
          `${Math.abs(realised).toLocaleString("en-US")} บาท เข้างบกำไรขาดทุนที่ ` +
          `${coaLabel(realised > 0 ? sub.gainCoa : sub.lossCoa)} — ` +
          "นี่คือจุดเดียวที่กำไร/ขาดทุนค่าเงินเป็นของจริง"
      );
    }
    summary.push(
      "เงินไม่ได้เข้าออกกิจการ แค่เปลี่ยนสกุล จึงไม่ใช่กระแสเงินสดของงวด — " +
        "ส่วนที่ทำให้ยอดบาทรวมขยับไปอยู่บรรทัดผลกระทบของอัตราแลกเปลี่ยนต่อเงินสด (IAS 7.28)"
    );
  } else if (sub.requires?.includes("fxAcquisition")) {
    /* ---------- ซื้อเงินตราต่างประเทศเข้าบัญชี FCD (บาทออก → เงินตราเข้า) ----------
     *
     * **ไม่ใช่กำไรขาดทุน และไม่แตะ 3410** — ซื้อเข้าคือการเปลี่ยนรูปสินทรัพย์
     * ยอดบาทที่จ่ายไป **คือต้นทุนของเงินตราก้อนนั้น** ซึ่งเป็นฐานที่
     * `trf.fx_translate_*` (เข้า 3410) และ `trf.fx_convert` (เข้า 4330/5930)
     * คิดต่อ · ตรงกับ `fn_fx_position()` ฝั่ง DB ที่เก็บ `cost += debit`
     * ของขาเงินตราที่มี `amount_original > 0` → `thb − cost = 0` ทันทีที่ซื้อเข้า
     * จึงไม่มีผลต่างที่ต้องตั้ง
     *
     * ต้องมีสาขาของตัวเองเพราะเส้นทางโอนธรรมดาสร้างสองบรรทัดเงินสดเท่ากัน
     * **โดยไม่พกสกุล/อัตรา** → ด่าน FCD ฝั่ง DB ปฏิเสธ (บรรทัดของบัญชีที่
     * `bank_accounts.currency` ไม่ใช่บาท ต้องพกสกุล อัตรา และยอดสกุลเดิมให้ครบ)
     *
     * **สกุลและผู้ถืออ่านจากบัญชีเอง** ไม่ใช่จากฟิลด์ที่ผู้ใช้เว้นได้ (D-115 ·
     * บทเรียน mace-windu ข้อ 2) — ฟิลด์ `currency` ที่ส่งมาใช้เป็นแค่
     * "สิ่งที่ผู้ใช้คิดว่าเป็น" แล้วเทียบกับความจริงของบัญชี ถ้าไม่ตรง = ปฏิเสธ
     */
    /**
     * **ถามเรื่องบัญชีก่อนเรื่องอื่นเสมอ** — ผู้ใช้ที่ยังไม่เลือกบัญชีต้องเห็น
     * ประโยคเดียวกับทุกเส้นทาง (`MISSING_BANK_MESSAGE`) ไม่ใช่ประโยคของสาขานี้
     * (เทสต์ `accrual-no-bank.test.ts` ไล่ทุกหมวดที่มีเงินเคลื่อนด้วยกฎข้อนี้)
     */
    if (!bankAccountId) throw new PostingError(MISSING_BANK_MESSAGE);

    const aq = input.fxAcquisition;
    if (!aq) {
      throw new PostingError(
        `หมวด "${sub.label}" ต้องระบุสกุลเงิน จำนวนเงินตราที่ซื้อเข้า อัตราที่ซื้อได้จริง ` +
          "และวันของอัตรา — ข้อมูลไม่ครบจะไม่รู้ว่ายอดบาทที่จ่ายไปเป็นต้นทุนของเงินตรากี่หน่วย " +
          "แล้วผลต่างอัตราแลกเปลี่ยนทุกเดือนหลังจากนั้นจะคิดจากฐานที่ผิด"
      );
    }

    const to = blankToUndefined(input.transferToBankAccountId);
    if (!to) {
      throw new PostingError("การซื้อเงินตราต้องระบุบัญชีสกุลต่างประเทศที่เงินตราเข้า");
    }
    if (to === bankAccountId) {
      throw new PostingError("ซื้อเงินตราเข้าบัญชีเดียวกับบัญชีที่จ่ายบาทไม่ได้");
    }

    // ปลายทางต้องเป็นบัญชี FCD จริง และสกุลที่ผู้ใช้บอกต้องตรงกับสกุลของบัญชีนั้น
    const fcd = assertFcdAccount(resolve, to, aq.currency, "การซื้อเงินตราต่างประเทศ");
    const currency = fcd.currency as string;

    // ต้นทางต้องเป็นบัญชี **บาท** ของผู้ถือเดียวกัน — อ่านจากบัญชีเอง
    const src = bankOf(resolve, bankAccountId);
    if (!src.currency) {
      throw new PostingError(
        `ไม่ทราบสกุลเงินของบัญชีที่จ่ายบาท "${src.name}" จึงบันทึกการซื้อเงินตราไม่ได้ — ` +
          "ต้นทางที่ไม่บอกสกุลอาจเป็นบัญชีเงินตราอีกใบ ซึ่งไม่ใช่การซื้อด้วยบาท"
      );
    }
    if (src.currency !== BASE_CURRENCY) {
      throw new PostingError(
        `บัญชีที่จ่าย "${src.name}" เป็นบัญชีสกุล ${src.currency} ไม่ใช่บัญชีบาท — ` +
          "หมวดนี้คือการซื้อเงินตราด้วยบาท · การย้ายเงินตราข้ามสกุลเป็นการแลกสองทอด " +
          "ต้องแลกเป็นบาทก่อนแล้วซื้อสกุลใหม่ เพื่อให้ต้นทุนของแต่ละสกุลตรวจย้อนได้"
      );
    }
    if (fcd.ownerId !== src.ownerId) {
      throw new PostingError(
        `บัญชีปลายทาง "${fcd.name}" เป็นของ ${ownerOf(resolve, fcd.ownerId).name} — ` +
          "การซื้อเงินตราต้องเข้าบัญชีของผู้ถือเดียวกัน เพราะต้นทุนของเงินตราผูกกับผู้ถือนั้น " +
          "(ถ้าจะส่งเงินให้ผู้ถืออื่น ให้โอนเป็นอีกรายการเพื่อให้ลักษณะรายการข้ามผู้ถือถูกบันทึก)"
      );
    }

    const amountOriginal = money(aq.amountOriginal, "จำนวนเงินตราที่ซื้อเข้า");
    if (amountOriginal <= 0) {
      throw new PostingError("จำนวนเงินตราที่ซื้อเข้าต้องมากกว่า 0");
    }
    const dealRate = checkedRate(currency, aq.dealRateToThb, "อัตราที่ซื้อได้จริง");
    const dealRateDate = checkedRateDate(aq.dealRateDate, "วันของอัตราที่ซื้อได้จริง");

    const thbOut = toThb(amountOriginal, dealRate);
    if (thbOut !== amount) {
      throw new PostingError(
        `บาทที่จ่ายต้องเท่ากับ ${amountOriginal.toLocaleString("en-US")} ${currency} × ` +
          `${dealRate} = ${thbOut.toLocaleString("en-US")} บาท แต่กรอกยอดมา ` +
          `${amount.toLocaleString("en-US")} — ยอดบาทต้องมาจากอัตราที่ซื้อได้จริง ` +
          "ไม่ใช่ตัวเลขที่พิมพ์แยกกัน (ด่านฝั่ง DB ไม่ยอมเศษแม้สตางค์เดียว)"
      );
    }

    const dealLabel = `${amountOriginal.toLocaleString("en-US")} ${currency} @ ${dealRate}`;
    const lines: PostingLine[] = [
      line({
        coaCode: CASH_COA,
        bankAccountId: fcd.id,
        debit: thbOut,
        cfCategory: sub.cashflow,
        currency,
        amountOriginal,
        fxRate: dealRate,
        fxRateDate: dealRateDate,
        memo: `เงินตราเข้าบัญชี ${dealLabel}`,
      }),
      line({
        coaCode: CASH_COA,
        bankAccountId: src.id,
        credit: thbOut,
        cfCategory: sub.cashflow,
        memo: `จ่ายบาทเพื่อซื้อเงินตรา ${dealLabel}`,
      }),
    ];

    /**
     * **ด่านที่ลูกพี่สั่งให้มี (25/10)** — ซื้อเข้าห้ามแตะ P&L
     * ซ้อนกับการที่ตารางกฎไม่ได้ให้บัญชีกำไร/ขาดทุนไว้เลยโดยตั้งใจ:
     * ตารางกฎกันการ "ตั้งใจ" · ด่านนี้กันการ "เผลอแก้คู่บัญชีวันหลัง"
     */
    assertNoProfitAndLoss(lines, `การซื้อเงินตรา "${sub.label}"`);

    /**
     * และห้ามแตะ **3410** ด้วย — ผลต่างที่ยังไม่เกิดจริงต้องเป็น 0 ทันทีที่ซื้อเข้า
     * (ยอดบาท = ต้นทุน) ถ้ามีบรรทัด 3410 ในใบนี้ ผลต่างจะถูกตั้งขึ้นจากอากาศ
     * แล้วด่าน invariant ฝั่ง DB (`fn_assert_fx_unrealized_cleared_for`) จะปฏิเสธ
     * — ดักที่นี่ก่อนเพื่อให้ผู้ใช้เห็นเหตุผล ไม่ใช่ข้อความของ invariant
     */
    const touchesUnrealised = lines.some((l) => l.coaCode === FX_TRANSLATION_DIFF_COA);
    if (touchesUnrealised) {
      throw new PostingError(
        `การซื้อเงินตราต้องไม่แตะ ${coaLabel(FX_TRANSLATION_DIFF_COA)} — ` +
          "ยอดบาทที่จ่ายไปคือต้นทุนของเงินตราก้อนนั้นพอดี จึงไม่มีผลต่างให้ตั้งตั้งแต่วันที่ซื้อ · " +
          "ผลต่างเกิดเมื่ออัตราขยับหลังถือไว้ (ใช้หมวดแปลงค่าสิ้นเดือน)"
      );
    }

    transactions.push({ ownerId: input.ownerId, lines });
    summary.push(
      `จ่ายบาท ${thbOut.toLocaleString("en-US")} ซื้อ ${dealLabel} เข้าบัญชี "${fcd.name}" — ` +
        "ยอดบาทที่จ่ายไปเป็น **ต้นทุน** ของเงินตราก้อนนี้"
    );
    summary.push(
      "ไม่มีกำไร/ขาดทุนและไม่มีผลต่างค้างในส่วนของเจ้าของ — ผลต่างเกิดตอนอัตราขยับหลังถือไว้ " +
        "(หมวดแปลงค่าสิ้นเดือน เข้า " + coaLabel(FX_TRANSLATION_DIFF_COA) + ") และรับรู้จริงตอนแลกกลับเป็นบาท"
    );
    summary.push(
      "ไม่ใช่กระแสเงินสดของงวด — เงินไม่ได้เข้าออกกิจการ แค่เปลี่ยนสกุล (IAS 7.28)"
    );
  } else if (sub.requires?.includes("transferTarget")) {
    // ---------- โอนระหว่างบัญชี ----------
    // ดูจากธงในตารางกฎ ไม่ใช่รหัสหมวด — หมวดโอนตัวที่สองในอนาคตจะได้ไม่ตกไปเส้นทางปกติ
    // ซึ่งจะเดบิตและเครดิตบัญชีเงินสดเดียวกัน กลายเป็นรายการว่างที่สมดุลผ่านทุกด่าน
    // แล้วบัญชีปลายทางถูกทิ้งเงียบๆ
    const to = blankToUndefined(input.transferToBankAccountId);
    if (!to) throw new PostingError("โอนระหว่างบัญชีต้องระบุบัญชีปลายทาง");
    if (to === bankAccountId) throw new PostingError("โอนเข้าบัญชีเดียวกันไม่ได้");

    // อ่านผู้ถือจากบัญชีปลายทางเอง ไม่เชื่อฟิลด์ที่ผู้ใช้เว้นได้
    const targetOwner = bankOwner(resolve, to);
    const crossOwner = targetOwner !== input.ownerId;

    if (!crossOwner) {
      // ย้ายกระเป๋าภายในคนเดียวกัน — หนึ่งรายการ สองบรรทัด
      transactions.push({
        ownerId: input.ownerId,
        lines: [
          line({ coaCode: CASH_COA, bankAccountId: to, debit: amount, cfCategory: "none", memo: "รับโอนเข้า" }),
          line({ coaCode: CASH_COA, bankAccountId, credit: amount, cfCategory: "none", memo: "โอนออก" }),
        ],
      });
      summary.push("ยอดรวมกองกลางไม่เปลี่ยน จึงไม่นับในงบกระแสเงินสดและไม่กระทบกำไรขาดทุน");
    } else {
      const nature = input.intercompanyNature;
      if (!nature) {
        throw new PostingError(
          `โอนไปบัญชีของ ${ownerOf(resolve, targetOwner).name} เป็นรายการข้ามผู้ถือ ` +
            "ต้องระบุลักษณะ (เงินทดรอง / กู้ยืม / เพิ่มทุน / ปันผล)"
        );
      }
      assertOwnerSelectable(resolve, targetOwner);

      const rule = INTERCOMPANY_RULES[nature];

      // ฝ่ายจ่ายกับฝ่ายรับอยู่คนละหมวดกระแสเงินสด — ปล่อยกู้เป็น Investing ของฝ่ายจ่าย
      // ส่วนฝ่ายที่กู้เข้ามาเป็น Financing (กฎเหล็กข้อ 8)
      transactions.push({
        ownerId: input.ownerId,
        counterOwnerId: targetOwner,
        intercompanyNature: nature,
        lines: [
          line({ coaCode: rule.payer.coa, debit: amount, cfCategory: rule.payer.cashflow, memo: rule.label }),
          line({ coaCode: CASH_COA, bankAccountId, credit: amount, cfCategory: rule.payer.cashflow }),
        ],
      });

      transactions.push({
        ownerId: targetOwner,
        counterOwnerId: input.ownerId,
        intercompanyNature: nature,
        lines: [
          line({ coaCode: CASH_COA, bankAccountId: to, debit: amount, cfCategory: rule.receiver.cashflow }),
          line({ coaCode: rule.receiver.coa, credit: amount, cfCategory: rule.receiver.cashflow, memo: rule.label }),
        ],
      });

      summary.push(
        `ข้ามผู้ถือ (${rule.label}) — สร้างสองรายการคู่กัน: ` +
          `${ownerOf(resolve, input.ownerId).name} ลง ${coa(rule.payer.coa).nameTh} · ` +
          `${ownerOf(resolve, targetOwner).name} ลง ${coa(rule.receiver.coa).nameTh}`
      );
      summary.push(rule.note);
      summary.push("งบรวมจะตัดรายการระหว่างกันออก ยอดกองกลางจึงไม่เปลี่ยน");
    }
  } else if (sub.requires?.includes("revaluation")) {
    /* ---------- ตีราคาทรัพย์ฝั่งลงทุน (D-111 ข้อ 2) ----------
     *
     * ดูจากธงในตารางกฎ ไม่ใช่รหัสหมวด (รูปเดียวกับ `transferTarget`) — หมวดตีราคา
     * ตัวใหม่จะได้ไม่ตกไปเส้นทางปกติที่ไม่ถามอัตราแลกเปลี่ยนเลย แล้วยอดบาท
     * จะกลายเป็นตัวเลขที่ไม่มีใครรู้ว่ามาจากอัตราไหน
     *
     * ต่างจากเส้นทางปกติสองอย่าง:
     *   1. บังคับข้อมูลอัตราแลกเปลี่ยนครบสามตัว และตรวจว่าคูณกันลงตัว
     *   2. **ผูกทรัพย์ทั้งสองขา** รวมขาส่วนเกินทุน (3400) ที่เป็นบัญชีทุน
     *      เส้นทางปกติผูกทรัพย์แค่ขาที่เป็นบัญชีสินทรัพย์ ซึ่งไม่พอที่นี่:
     *      ถ้าขา 3400 ไม่มี asset_id จะไม่มีทางรู้ว่าส่วนเกินทุนที่ค้างอยู่เป็นของ
     *      ทรัพย์ชิ้นไหน แล้วตอนขายจะล้างส่วนเกินของทรัพย์ชิ้นนั้นออกไม่ได้
     *      (ซึ่งคือการนับซ้ำที่ลูกพี่สั่งให้กัน)
     */
    const rv = checkedRevaluation(sub, input);
    const memo = `ตีราคา ${rv.label}${rv.valuationRef ? ` · อ้างอิง ${rv.valuationRef}` : ""}`;

    const lines: PostingLine[] = [
      line({ coaCode: sub.dr, assetId: input.assetId, debit: amount, cfCategory: "none", memo }),
      line({ coaCode: sub.cr, assetId: input.assetId, credit: amount, cfCategory: "none", memo }),
    ];

    /**
     * **ด่านที่ลูกพี่สั่งให้มี** — ต้องพังเสียงดังถ้ารายการตีราคาไปแตะ P&L
     * ซ้อนทับกับการที่ตารางกฎใช้บัญชีประเภท equity อยู่แล้วโดยตั้งใจ:
     * ตารางกฎกันการ "ตั้งใจ" · ด่านนี้กันการ "เผลอแก้คู่บัญชีวันหลัง"
     * มีเทสต์ mutation ยืนยันว่าแดงจริง (revaluation-posting.test.ts)
     */
    assertNoProfitAndLoss(lines, `รายการตีราคา "${sub.label}"`);

    transactions.push({ ownerId: input.ownerId, lines });
    summary.push(
      `มูลค่าตลาด ${rv.label} — ลงที่ ${coaLabel(REVALUATION_SURPLUS_COA)} ในส่วนของเจ้าของ ` +
        "**ไม่เข้างบกำไรขาดทุน** (กำไร/ขาดทุนรับรู้ตอนขายจริงเท่านั้น)"
    );
    summary.push(
      "เดือนถัดไปต้องกลับรายการใบนี้ก่อนลงยอดใหม่ ไม่ใช่ลงส่วนต่างทับกัน — ใช้ planRevaluation()"
    );
  } else if (sub.requires?.includes("capitalGain")) {
    // ---------- ขายทรัพย์ / ขายหลักทรัพย์ ----------
    const d = input.disposal!;
    // ตัวเลขคำนวณที่ `lib/disposal/capital-gain.ts` ที่เดียว ที่นี่แปลงเป็นบรรทัดบัญชีอย่างเดียว
    // money() ดักค่าที่คำนวณต่อไม่ได้ก่อน เพื่อให้ได้ข้อความภาษาคนแทน error ดิบ
    /**
     * **ส่วนเกินทุนที่ต้องล้าง = สัดส่วนที่ขายออก × ส่วนเกินทั้งก้อน** (D-112)
     *
     * ขายบางส่วนแล้วล้างทั้งก้อน = ต้นทุนคงเหลือต่ำกว่าจริงเท่าส่วนที่ล้างเกิน
     * แล้วการขายครั้งถัดไปโชว์ "กำไร" ที่ไม่มีอยู่จริง (ผู้ตรวจวัดได้ 460,000
     * ในฉากซื้อ 10 หน่วย 1,000,000 → ตีขึ้น 460,000 → ขาย 3 หน่วย)
     *
     * สมการอยู่ที่ `surplusToReverseFor()` **ตัวเดียวกับที่ด่านฝั่ง DB ใช้**
     * (`fn_assert_asset_cost_sane` ข้อ ข) → ยอดที่ผู้ใช้เห็นในพรีวิวกับยอดที่
     * ฐานข้อมูลจะยอมรับเป็นตัวเดียวกันเสมอ
     *
     * ส่งทั้งสองแบบมาแล้วไม่ตรงกัน → **ปฏิเสธ ไม่ใช่เลือกเอาตัวใดตัวหนึ่ง**
     * (เลือกเองคือการตัดสินใจเรื่องเงินแทนผู้ใช้โดยไม่มีใครเห็น)
     */
    let surplusToClear = d.unrealizedAdjustment ?? 0;
    if (d.priorSurplus !== undefined || d.assetCostBefore !== undefined) {
      if (d.priorSurplus === undefined || d.assetCostBefore === undefined) {
        throw new PostingError(
          "ต้องส่งทั้งต้นทุนทั้งก้อนก่อนขาย (assetCostBefore) และส่วนเกินทุนที่ค้างอยู่ (priorSurplus) คู่กัน — " +
            "มีตัวเดียวคิดสัดส่วนที่ขายออกไม่ได้ · ทั้งสองค่าต้องอ่านจากสมุดที่ post แล้วจริง " +
            "(fn_asset_cost_basis และ fn_asset_revaluation_surplus) ไม่ใช่จาก state ของหน้าจอ"
        );
      }
      const computed = surplusToReverseFor({
        priorSurplus: d.priorSurplus,
        costBefore: money(d.assetCostBefore, "ต้นทุนทั้งก้อนก่อนขาย"),
        costRemoved: money(d.costBasis, "ต้นทุน"),
      });
      if (d.unrealizedAdjustment !== undefined && Math.abs(round2(d.unrealizedAdjustment - computed)) > 0.01) {
        throw new PostingError(
          `ส่วนเกินทุนที่ต้องล้างในใบนี้คือ ${computed} บาท (${d.priorSurplus} × ` +
            `${d.costBasis}/${d.assetCostBefore} ตามสัดส่วนที่ขายออก · D-112) แต่ระบุมา ${d.unrealizedAdjustment} — ` +
            "ล้างเกินทำให้ต้นทุนคงเหลือต่ำกว่าจริงแล้วการขายครั้งถัดไปโชว์กำไรที่ไม่มีอยู่จริง · " +
            "ล้างขาดทำให้ส่วนเกินทุนของหน่วยที่ขายไปแล้วค้างในส่วนของเจ้าของตลอดไป"
        );
      }
      surplusToClear = computed;
    } else if (d.unrealizedAdjustment !== undefined && d.unrealizedAdjustment !== 0) {
      // ส่วนเกินทุนที่ระบุมาเดี่ยวๆ ไม่มีต้นทุนทั้งก้อนมาเทียบ → ตรวจสัดส่วนที่ขายออกไม่ได้ (ขายบางส่วนแล้วล้างทั้งก้อน = D-112)
      // ปฏิเสธ ไม่ใช่เชื่อตัวเลขที่ผู้เรียกกรอก (D-115) · ให้ส่ง assetCostBefore + priorSurplus ที่อ่านจากสมุดแทน
      throw new PostingError(
        "ส่วนเกินทุนที่ล้าง (unrealizedAdjustment) ส่งเดี่ยวๆ ไม่ได้ — ต้องส่งคู่กับต้นทุนทั้งก้อนก่อนขาย (assetCostBefore) " +
          "และส่วนเกินทุนที่ค้างอยู่ (priorSurplus) ที่อ่านจากสมุด เพื่อให้ระบบคิดสัดส่วนที่ขายออกเอง ไม่เชื่อตัวเลขที่กรอก"
      );
    }

    const r = computeDisposal({
      costBasis: money(d.costBasis, "ต้นทุน"),
      salePrice: money(d.salePrice, "ราคาขาย"),
      sellingCosts: money(d.sellingCosts ?? 0, "ค่าใช้จ่ายในการขาย"),
      // **ติดลบได้** จึงไม่ผ่าน money() ที่ห้ามติดลบ — เคยตีราคาลงคือเรื่องปกติ
      unrealizedAdjustment: surplusToClear,
    });
    const { costBasis, netProceeds, capitalGain: gain } = r;

    if (costBasis === 0) throw new PostingError("ต้นทุนต้องมากกว่า 0 — ทรัพย์ที่ไม่มีต้นทุนตัดออกไม่ได้");

    if (!(netProceeds > 0)) {
      throw new PostingError(
        `เงินที่ได้สุทธิต้องมากกว่า 0 (ราคาขาย ${r.salePrice} − ค่าใช้จ่าย ${r.sellingCosts} = ${netProceeds})`
      );
    }
    if (netProceeds !== amount) {
      throw new PostingError(
        `ยอดที่รับจริงต้องเท่ากับ ราคาขาย − ค่าใช้จ่ายในการขาย (${netProceeds}) แต่กรอกมา ${amount}`
      );
    }

    // ค่ารีโนเวทที่บันทึกเป็นทุน (1510) เป็นส่วนหนึ่งของต้นทุนทรัพย์ชิ้นเดียวกัน → ตัดออกในใบเดียวกันด้วยบรรทัดของมันเอง
    const renovation = money(d.renovationBasis ?? 0, "ค่ารีโนเวทสะสมที่ตัดออก");
    if (renovation > costBasis) {
      throw new PostingError(`ค่ารีโนเวทสะสม (${renovation}) มากกว่าต้นทุนทั้งหมดที่ตัดออก (${costBasis}) — ค่ารีโนเวทเป็นส่วนหนึ่งของต้นทุน ไม่ใช่ส่วนเพิ่ม`);
    }
    if (renovation > 0 && !isPropertyAccount(sub.cr)) {
      throw new PostingError(
        `หมวด "${sub.label}" ตัดค่ารีโนเวทสะสมไม่ได้ — ค่ารีโนเวท (${RENOVATION_COA}) เป็นต้นทุนของอสังหาริมทรัพย์ (${propertyCoaList()}) เท่านั้น ` +
          "(ด่านฝั่ง DB อนุญาตบรรทัดนี้เฉพาะหมวดที่เครดิตบัญชีอสังหาริมทรัพย์)"
      );
    }

    const lines: PostingLine[] = [
      line({ coaCode: CASH_COA, bankAccountId, debit: netProceeds, cfCategory: sub.cashflow }),
      // ตัดทรัพย์ออก "ตามต้นทุน" ไม่ใช่ราคาขาย
      line({ coaCode: sub.cr, assetId: input.assetId, credit: round2(costBasis - renovation), cfCategory: sub.cashflow }),
    ];
    if (renovation > 0) {
      lines.push(
        line({
          coaCode: RENOVATION_COA,
          assetId: input.assetId,
          credit: renovation,
          cfCategory: sub.cashflow,
          memo: "ตัดค่ารีโนเวทสะสมที่บันทึกเป็นทุนออกพร้อมทรัพย์",
        })
      );
      summary.push(`ตัดค่ารีโนเวทสะสม ${renovation.toLocaleString("en-US")} บาทออกพร้อมต้นทุนทรัพย์ (รวมต้นทุนที่ตัด ${costBasis.toLocaleString("en-US")} บาท)`);
    }

    if (gain > 0) {
      if (!sub.gainCoa) throw new PostingError(`หมวด "${sub.label}" ไม่ได้ระบุบัญชีรับรู้กำไรในตารางกฎ`);
      lines.push(line({ coaCode: sub.gainCoa, assetId: input.assetId, credit: gain, memo: "กำไรจากการขาย" }));
      summary.push(`รับรู้กำไรจากการขาย ${gain.toLocaleString("en-US")} บาท`);
    } else if (gain < 0) {
      if (!sub.lossCoa) throw new PostingError(`หมวด "${sub.label}" ไม่ได้ระบุบัญชีรับรู้ขาดทุนในตารางกฎ`);
      lines.push(line({ coaCode: sub.lossCoa, assetId: input.assetId, debit: Math.abs(gain), memo: "ขาดทุนจากการขาย" }));
      summary.push(`รับรู้ขาดทุนจากการขาย ${Math.abs(gain).toLocaleString("en-US")} บาท`);
    } else {
      summary.push("ขายเท่าทุนพอดี ไม่มีกำไรหรือขาดทุน");
    }

    /**
     * ล้างส่วนเกินทุนจากการตีราคาของทรัพย์ชิ้นนี้ **พร้อมกับการขาย** (D-111 ข้อ 2)
     *
     * ก่อนหน้านี้บรรทัดนี้เป็นแค่ข้อความใน `summary` ว่า "ต้องถูกล้างออกพร้อมกัน"
     * โดยที่ **ไม่มีบรรทัดบัญชีไหนล้างให้เลย** — คำเตือนที่ไม่มีใครทำตามได้
     * ผลคือสองอย่างพร้อมกัน:
     *   1. ส่วนเกินทุนค้างในส่วนของเจ้าของตลอดไป ทั้งที่ทรัพย์ไม่อยู่แล้ว
     *   2. ยอดในบัญชีทรัพย์ไม่กลับเป็นศูนย์ (เครดิตแค่ต้นทุน แต่ยอดยกมาคือ
     *      ต้นทุน + ส่วนเกิน) = ทรัพย์ผีค้างในงบดุลเท่าส่วนที่ตีราคาไว้
     *
     * ทิศทางอ่านจากเครื่องหมาย: เคยตีขึ้น (บวก) → เดบิต 3400 ล้างทุนที่เคยเพิ่ม
     * คู่กับเครดิตบัญชีทรัพย์เพื่อตัดส่วนที่ตีเพิ่มออก · เคยตีลง (ลบ) → กลับทิศ
     * ทั้งคู่หักกันในตัวเอง จึงไม่กระทบยอดสมดุลและ **ไม่แตะ P&L**
     * (กำไร/ขาดทุนจริงคิดจากต้นทุนเดิมตาม FIFO ไปแล้วข้างบน — ถ้าเอาส่วนเกิน
     *  มาคิดเป็นกำไรด้วย จะเป็นการนับซ้ำรอบที่สอง)
     */
    const surplus = r.unrealizedToReverse;
    if (surplus !== 0) {
      const magnitude = Math.abs(surplus);
      if (surplus > 0) {
        lines.push(
          line({
            coaCode: REVALUATION_SURPLUS_COA,
            assetId: input.assetId,
            debit: magnitude,
            memo: "ล้างส่วนเกินทุนจากการตีราคาที่เคยตีขึ้น",
          })
        );
        lines.push(
          line({
            coaCode: sub.cr,
            assetId: input.assetId,
            credit: magnitude,
            cfCategory: sub.cashflow,
            memo: "ตัดส่วนที่ตีราคาเพิ่มไว้ออกจากบัญชีทรัพย์",
          })
        );
      } else {
        lines.push(
          line({
            coaCode: sub.cr,
            assetId: input.assetId,
            debit: magnitude,
            cfCategory: sub.cashflow,
            memo: "กลับส่วนที่ตีราคาลดไว้ในบัญชีทรัพย์",
          })
        );
        lines.push(
          line({
            coaCode: REVALUATION_SURPLUS_COA,
            assetId: input.assetId,
            credit: magnitude,
            memo: "ล้างส่วนเกินทุนจากการตีราคาที่เคยตีลง",
          })
        );
      }
      summary.push(
        `ล้างส่วนเกินทุนจากการตีราคาของทรัพย์ชิ้นนี้ ${surplus.toLocaleString("en-US")} บาทออกพร้อมกัน — ` +
          (r.unrealizedIsLoss ? "เคยตีราคาลงไว้" : "เคยตีราคาขึ้นไว้") +
          " ยอดในส่วนของเจ้าของและในบัญชีทรัพย์จึงกลับเป็นศูนย์ ไม่นับซ้ำกับกำไรจากการขาย"
      );
    } else {
      summary.push("ทรัพย์ชิ้นนี้ไม่มีส่วนเกินทุนจากการตีราคาค้างอยู่ จึงไม่มีอะไรต้องล้าง");
    }

    transactions.push({ ownerId: input.ownerId, lines });
  } else if (sub.requires?.includes("principalInterestSplit")) {
    // ---------- คืนเงินกู้ / รับคืนเงินต้น ----------
    const r = input.repayment!;
    const principal = money(r.principal, "เงินต้น");
    const interest = money(r.interest, "ดอกเบี้ย");
    if (round2(principal + interest) !== amount) {
      throw new PostingError(
        `เงินต้น (${principal}) + ดอกเบี้ย (${interest}) ต้องเท่ากับยอดที่จ่าย/รับ (${amount})`
      );
    }
    if (!sub.interestCoa) throw new PostingError(`หมวด "${sub.label}" ไม่ได้ระบุบัญชีดอกเบี้ยในตารางกฎ`);

    // เงินเข้า = รับคืนเงินต้น · เงินออก = ชำระคืนเงินกู้ (ค่าอื่นถูกปฏิเสธ ไม่ใช่เดา)
    const isInflow = repaymentDirection(sub) === "in";
    const lines: PostingLine[] = [];

    if (isInflow) {
      if (principal === 0) {
        throw new PostingError(
          `หมวด "${sub.label}" ไว้สำหรับรับคืนเงินต้น — ถ้ารับแต่ดอกเบี้ย ให้ใช้หมวด รายได้ › ${coa(sub.interestCoa).nameTh}`
        );
      }
      // แตกบรรทัดเงินสดตามหมวดกระแสเงินสด: เงินต้นเป็น Investing · ดอกเบี้ยเป็น Operating
      // ถ้ารวมเป็นบรรทัดเดียว CF ลงทุนจะบวมเท่าดอกเบี้ย และดำเนินงานจะขาดไปเท่ากัน
      lines.push(
        line({ coaCode: CASH_COA, bankAccountId, debit: principal, cfCategory: sub.cashflow, memo: "รับคืนเงินต้น" })
      );
      lines.push(line({ coaCode: sub.cr, assetId: input.assetId, credit: principal, cfCategory: sub.cashflow, memo: "เงินต้น" }));
      if (interest > 0) {
        lines.push(
          line({ coaCode: CASH_COA, bankAccountId, debit: interest, cfCategory: "operating", memo: "รับดอกเบี้ย" })
        );
        lines.push(line({ coaCode: sub.interestCoa, credit: interest, cfCategory: "operating", memo: "ดอกเบี้ยรับ" }));
      }
      summary.push(
        `เงินต้น ${principal.toLocaleString("en-US")} ลดลูกหนี้ · ดอกเบี้ย ${interest.toLocaleString("en-US")} เป็นรายได้`
      );
    } else {
      // เงินต้นลดหนี้สิน · ดอกเบี้ยเป็นค่าใช้จ่าย · เงินสดออกเต็มจำนวน
      if (principal > 0) {
        lines.push(line({ coaCode: sub.dr, debit: principal, cfCategory: sub.cashflow, memo: "เงินต้น" }));
      }
      if (interest > 0) {
        lines.push(line({ coaCode: sub.interestCoa, debit: interest, cfCategory: sub.cashflow, memo: "ดอกเบี้ย" }));
      }
      lines.push(line({ coaCode: CASH_COA, bankAccountId, credit: amount, cfCategory: sub.cashflow }));
      summary.push(
        `เงินต้น ${principal.toLocaleString("en-US")} ลดหนี้สิน · ดอกเบี้ย ${interest.toLocaleString("en-US")} เป็นค่าใช้จ่าย`
      );
    }

    transactions.push({ ownerId: input.ownerId, lines });
  } else {
    // ---------- รายการปกติสองบรรทัด ----------
    // ยังไม่ได้รับ/จ่ายเงิน = ขาเงินสดกลายเป็นลูกหนี้/เจ้าหนี้ และไม่นับในงบกระแสเงินสด
    // เพราะเงินยังไม่เคลื่อนจริง ถ้าลงเงินสดไว้ก่อนจะกระทบยอดกับ statement ไม่ได้
    const accrual = input.notYetPaid ? accrualAccount(sub) : null;
    const cfCategory = accrual ? "none" : sub.cashflow;
    const accountFor = (code: string) => (accrual && isCashAccount(code) ? accrual : code);

    const drCode = accountFor(sub.dr);
    const crCode = accountFor(sub.cr);
    const drIsCash = isCashAccount(drCode);
    const crIsCash = isCashAccount(crCode);

    /**
     * ถูกหักภาษี ณ ที่จ่าย → ขาเงินสดแตกเป็นสองบรรทัด (D-111 ข้อ 1)
     *
     *   เงินสด            95  (dr)   ← ยอดที่เข้าบัญชีจริง ตรงกับ statement
     *   ภาษีถูกหักรอเครดิต  5  (dr)   ← สินทรัพย์ เอาไปเครดิตภาษีปลายปี
     *       รายได้               100  (cr)  ← **ยอดเต็มเสมอ**
     *
     * ตั้งค้างพร้อมกับถูกหักภาษีไม่ได้: ใบรับรองการหักออกตอน **จ่ายเงินจริง**
     * ถ้ายังไม่จ่าย ก็ยังไม่มีใครหัก · ยอมให้ทำจะได้สินทรัพย์ภาษีจากเหตุการณ์
     * ที่ยังไม่เกิด แล้วตอนเงินเข้าจริงจะหักอีกรอบ = เครดิตภาษีสองเท่า
     */
    const wht = input.wht ? whtAmounts(sub, amount, input.wht) : null;
    if (wht && accrual) {
      throw new PostingError(
        "ยังไม่ได้รับเงิน จึงยังไม่มีใครหักภาษี ณ ที่จ่าย — ใบรับรองการหักออกตอนจ่ายเงินจริง · " +
          "ให้ตั้งค้างรับยอดเต็มไว้ก่อน แล้วบันทึกการถูกหักภาษีตอนยืนยันเงินเข้าจริง"
      );
    }

    const lines: PostingLine[] = [];
    if (wht) {
      lines.push(
        line({
          coaCode: drCode,
          bankAccountId,
          debit: wht.net,
          cfCategory,
          memo: `เงินรับสุทธิหลังถูกหักภาษี ${wht.rate}%`,
        })
      );
      /**
       * **ห้ามผูก `assetId` กับบรรทัดนี้** และห้ามผูก `bankAccountId`
       *
       * `bankAccountId`: 1800 ไม่ใช่บัญชี 11xx ด่าน `fn_assert_line_bank_owner`
       * ฝั่ง DB ปฏิเสธบรรทัดที่ไม่ใช่เงินสดแต่มีบัญชีธนาคารติดมา (ข้อ 7 ของผู้ตรวจ)
       *
       * `assetId`: `fn_asset_cost_basis()` รวม **ทุกบรรทัดบัญชีสินทรัพย์ที่ผูกทรัพย์**
       * เป็นต้นทุนของทรัพย์ชิ้นนั้น → ผูกที่นี่ = ต้นทุนคอนโดบวมขึ้นเท่าภาษีที่ถูกหัก
       * จากค่าเช่าทุกเดือน แล้วกำไรจากการขาย (ถัวเฉลี่ย · D-112) จะต่ำกว่าจริงเรื่อยๆ
       * โดยที่ทุกใบสมดุลและไม่มีอะไรฟ้อง · ภาษีที่ถูกหักเป็นเครดิตระดับผู้ถือ
       * ไม่ใช่ต้นทุนของทรัพย์
       */
      lines.push(
        line({
          coaCode: wht.account,
          debit: wht.withheld,
          cfCategory,
          memo:
            `ภาษีหัก ณ ที่จ่าย ${wht.rate}%` +
            (input.wht?.certificateNo ? ` · ใบรับรองเลขที่ ${input.wht.certificateNo}` : ""),
        })
      );
    } else {
      lines.push(
        line({
          coaCode: drCode,
          bankAccountId: drIsCash ? bankAccountId : undefined,
          assetId: coa(drCode).type === "asset" && !drIsCash ? input.assetId : undefined,
          debit: amount,
          cfCategory,
        })
      );
    }

    lines.push(
      line({
        coaCode: crCode,
        bankAccountId: crIsCash ? bankAccountId : undefined,
        assetId: coa(crCode).type === "asset" && !crIsCash ? input.assetId : undefined,
        // ยอดเต็มเสมอ — ไม่ว่าจะถูกหักภาษีไว้เท่าไร
        credit: amount,
        cfCategory,
      })
    );

    transactions.push({ ownerId: input.ownerId, lines });

    if (wht) {
      summary.push(
        `ถูกหักภาษี ณ ที่จ่าย ${wht.rate}% = ${wht.withheld.toLocaleString("en-US")} บาท · ` +
          `เงินเข้าบัญชี ${wht.net.toLocaleString("en-US")} บาท แต่ ` +
          `**รายได้รับรู้เต็ม ${amount.toLocaleString("en-US")} บาท**`
      );
      summary.push(
        `ภาษีที่ถูกหักลงเป็น ${coaLabel(wht.account)} (สินทรัพย์) — ไม่ใช่ค่าใช้จ่าย · ` +
          "เอาไปเครดิตภาษีปลายปี หรือขอคืนด้วยหมวด ลงทุน (ขาย/รับคืน) › รับคืนภาษีถูกหัก ณ ที่จ่าย"
      );
    }

    if (accrual) {
      summary.push(
        `ยังไม่ได้รับ/จ่ายเงิน — ลงเป็น ${coa(accrual).nameTh} แทนเงินสด ` +
          "ยอดธนาคารยังไม่ขยับ และยังไม่นับในงบกระแสเงินสด"
      );
    }

    /**
     * หมวดย้ายยอด — บอกตรงๆ ว่ายอดนี้มาจากสมุด ไม่ใช่จากที่พิมพ์ และย้ายไปทั้งก้อน
     * (ผู้ใช้ต้องเห็นว่าบัญชีต้นทางเหลือศูนย์ ไม่ใช่เดาจากตัวเลขที่ตัวเองกรอก)
     */
    if (sub.requires?.includes("wholeBalanceMove")) {
      summary.push(
        `ย้าย **ทั้งก้อน** ${thb(amount)} บาท ตามยอดคงเหลือของทรัพย์ชิ้นนี้ในสมุด — ` +
          `${coaLabel(crCode)} ของทรัพย์ชิ้นนี้เหลือ 0 และ ${coaLabel(drCode)} รับไปเต็มจำนวน · ` +
          "ยอดสินทรัพย์รวมไม่เปลี่ยน ไม่มีเงินเข้าออก และไม่เข้างบกำไรขาดทุน"
      );
    }
  }

  if (input.memo) {
    for (const t of transactions) {
      for (const l of t.lines) l.memo = l.memo ? `${l.memo} · ${input.memo}` : input.memo;
    }
  }

  /**
   * บังคับบัญชี **ที่นี่** คือจุดที่รู้แล้วว่ามีบรรทัดเงินสดจริงหรือไม่
   *
   * เส้นทางค้างรับ-ค้างจ่ายไม่มีบรรทัดเงินสดเลย จึงผ่านด่านนี้โดยไม่ต้องมีบัญชี
   * ส่วนทุกเส้นทางที่มีขาเงินสด (รายการสองบรรทัดปกติ · โอนทั้งสองขา · ขายทรัพย์ ·
   * แยกเงินต้น-ดอกเบี้ยที่สร้างหลายบรรทัด) ถูกไล่ครบโดยไม่ต้องจำว่าสาขาไหนใช้บัญชี
   */
  assertCashLinesHaveAccount(transactions);

  // ตรวจทุกรายการก่อนส่งออก — ทีละ transaction เพราะ DB ตรวจสมดุลต่อ transaction
  for (const t of transactions) {
    assertBalanced(t.lines);
    assertLinesValid(t.lines);
  }

  // อยู่ใน draft ด้วยโดยตั้งใจ (D-092) — ต่างจาก `assertEvidencePolicy()` ที่เป็นกติกาเอกสาร
  // ซึ่งไม่เปลี่ยนคู่บัญชี จึงปล่อยให้พรีวิวแสดงบรรทัดก่อนไปหาไฟล์ได้
  // แต่บัญชีที่ปิดคือบัญชีที่ลงรายการไม่ได้เลย ถ้าพรีวิวโชว์บรรทัดสวยๆ แล้วกดบันทึกเด้ง
  // ผู้ใช้จะไม่เข้าใจว่าทำไม — บอกตั้งแต่ตอนเลือกบัญชีถูกกว่า
  assertCashAccountsActive(transactions, resolve, { reversal: input.reversal });

  return { transactions, summary };
}

/**
 * สร้างรายการบัญชีที่ **พร้อมบันทึกจริง**
 *
 * ต่างจาก `buildPostingDraft()` ตรงที่บังคับกติกาเอกสารของผู้ถือทุกฝ่ายที่รายการแตะ
 * ไล่จาก transaction ที่สร้างได้จริง ไม่ใช่จากฟิลด์ที่ผู้ใช้กรอก —
 * รายการข้ามผู้ถือจึงถูกตรวจทั้งสองขาเสมอ โดยไม่ต้องจำว่าสาขาไหนต้องเรียกเพิ่ม
 *
 * ทุกเส้นทางที่จะ post ลงฐานข้อมูลต้องผ่านฟังก์ชันนี้ ห้ามเรียก draft ตรงๆ
 */
export function buildPosting(input: PostingInput, resolve: LedgerResolver): PostingResult {
  const result = buildPostingDraft(input, resolve);
  for (const t of result.transactions) assertEvidencePolicy(input, t.ownerId, resolve);
  return result;
}

/** รวมทุกบรรทัดจากทุกรายการ — ใช้ตอนแสดงผลรวมหรือทดสอบ */
export function allLines(result: PostingResult): PostingLine[] {
  return result.transactions.flatMap((t) => t.lines);
}
