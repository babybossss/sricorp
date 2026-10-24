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

import { accrualCheck, movesCash, whtCheck, type SubCategory } from "@/lib/rules/tx-rules";
import { fxCheck, toThb } from "@/lib/rules/currency";
import { coa, coaLabel, isCashAccount, CASH_COA, REVALUATION_SURPLUS_COA } from "@/lib/rules/coa";
import { INTERCOMPANY_RULES } from "@/lib/rules/intercompany";
import { computeDisposal } from "@/lib/disposal/capital-gain";
import {
  PostingError,
  type LedgerResolver,
  type PostingInput,
  type PostingLine,
  type PostingResult,
  type PostingTransaction,
} from "./types";
import {
  assertBalanced,
  assertBankBelongsTo,
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

  if (sub.requires?.includes("transferTarget")) {
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
    const r = computeDisposal({
      costBasis: money(d.costBasis, "ต้นทุน"),
      salePrice: money(d.salePrice, "ราคาขาย"),
      sellingCosts: money(d.sellingCosts ?? 0, "ค่าใช้จ่ายในการขาย"),
      // **ติดลบได้** จึงไม่ผ่าน money() ที่ห้ามติดลบ — เคยตีราคาลงคือเรื่องปกติ
      unrealizedAdjustment: d.unrealizedAdjustment ?? 0,
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

    const lines: PostingLine[] = [
      line({ coaCode: CASH_COA, bankAccountId, debit: netProceeds, cfCategory: sub.cashflow }),
      // ตัดทรัพย์ออก "ตามต้นทุน" ไม่ใช่ราคาขาย
      line({ coaCode: sub.cr, assetId: input.assetId, credit: costBasis, cfCategory: sub.cashflow }),
    ];

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
       * จากค่าเช่าทุกเดือน แล้วกำไรจากการขาย (FIFO · D-038) จะต่ำกว่าจริงเรื่อยๆ
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
