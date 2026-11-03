/**
 * ยืนยันว่าเงินเข้า-ออกจริงแล้ว — ล้างลูกหนี้/เจ้าหนี้ที่ตั้งค้างไว้ ด้วยเงินสดจริง
 *
 * **การยืนยันคือการลงบัญชี** มันสร้างบรรทัดบัญชีจริง (ลดลูกหนี้/เจ้าหนี้ · เพิ่ม/ลดเงินสด)
 * และเป็นขั้นที่ทำให้งบกระแสเงินสดวิ่ง จึงต้องอยู่ที่นี่ ไม่ใช่ในหน้าจอ
 * ก่อนหน้านี้กฎของขั้นนี้ถูกเขียนไว้ใน `components/ledger/confirm-gate.ts` เพราะ
 * เครื่องยนต์ไม่มีฟังก์ชันให้เรียก — กฎเดียวกันอยู่สองที่คือทางที่สิ่งที่ผู้ใช้เห็น
 * กับสิ่งที่ระบบบันทึกแยกจากกันได้ (บทเรียน mace-windu ข้อ 5)
 *
 * **คู่บัญชีของการล้างห้ามเขียนในไฟล์นี้** ต้องมาจากตารางกฎ (`clearingSubsFor()`)
 * เหตุผลไม่ใช่ความสวยงาม: ถ้าเขียนเองที่นี่ ตารางกฎจะเลิกเป็นแหล่งความจริงเดียว
 * แล้ววันที่ใครย้ายบัญชีพักของหมวดใดหมวดหนึ่ง การล้างจะยังล้างบัญชีเดิมแบบเงียบๆ
 *
 * หมวดกระแสเงินสดของการล้าง = **หมวดของรายการต้นทาง** ไม่ใช่ของทางล้าง
 * (ซื้อทรัพย์ค้างจ่ายต้องออกที่ Investing ไม่ใช่ Operating — ดู `clearingSubsFor()`
 *  ที่คัดทางล้างด้วยหมวด CF ให้แล้ว จึงตรงกันโดยโครงสร้าง ไม่ใช่โดยความบังเอิญ)
 */

import { accrualCheck, clearingSubsFor, type SubCategory } from "@/lib/rules/tx-rules";
import { coa, isCashAccount } from "@/lib/rules/coa";
import {
  PostingError,
  type ClearingInput,
  type LedgerResolver,
  type PostingLine,
  type PostingResult,
  type PostingTransaction,
} from "./types";
import {
  assertBalanced,
  assertBankBelongsTo,
  assertCashAccountsActive,
  assertCashLinesHaveAccount,
  assertEvidencePolicy,
  assertLinesValid,
  assertOwnerSelectable,
  assertRequiredDimensions,
  assertTypeAndSub,
  blankToUndefined,
  line,
  money,
  round2,
} from "./guards";

const baht = (n: number) => n.toLocaleString("en-US", { minimumFractionDigits: 0 });

/**
 * บัญชีพักของรายการต้นทาง — เหตุผลที่ปฏิเสธมาจากตารางกฎที่เดียว (`accrualCheck()`)
 *
 * แยกสองสาเหตุที่ต่างกันให้ผู้ใช้เห็น เพราะทางแก้ต่างกันคนละเรื่อง:
 * - หมวดนี้**ไม่เคยเป็น**ค้างรับ-ค้างจ่าย (ไม่มีบัญชีพัก / เป็นเส้นทางพิเศษที่บันทึก
 *   ตอนเงินเคลื่อนจริงอยู่แล้ว) → ไม่มียอดค้างให้ยืนยัน กดผิดรายการ
 * - หมวดนี้ตั้งค้างได้แต่**ยังล้างไม่ได้** (ตารางกฎยังไม่มีหมวดสำหรับล้าง หรือมีแต่
 *   คนละหมวดกระแสเงินสด) → เป็นช่องว่างของตารางกฎ ไม่ใช่ความผิดของคนกด (D-087)
 *   ต้องบอกว่าทำไม ไม่ใช่แค่ว่าไม่ได้ ไม่งั้นไม่มีใครรู้ว่าต้องไปแก้ที่ตารางกฎ
 */
function accrualAccountOf(sub: SubCategory): string {
  const check = accrualCheck(sub);
  if (check.ok) return check.account;

  if (check.reason === "noAccount" || check.reason === "specialPath") {
    throw new PostingError(
      `หมวด "${sub.label}" ไม่ใช่รายการค้างรับ-ค้างจ่าย จึงไม่มียอดค้างให้ยืนยัน — ${check.why}`
    );
  }
  throw new PostingError(`ยังล้างยอดค้างของหมวด "${sub.label}" ไม่ได้ — ${check.why}`);
}

/**
 * ทางล้างจากตารางกฎ — มีทางเดียวให้ใช้ทางนั้น · หลายทางต้องให้ผู้เรียกเลือก **ห้ามหยิบตัวแรก**
 *
 * วันนี้ทุกบัญชีพักมีทางเดียว แต่ถ้าหยิบตัวแรกไว้เลย วันที่ตารางกฎมีทางที่สอง
 * (เช่น ล้างด้วยการหักกลบ) ระบบจะเลือกให้เองเงียบๆ ซึ่งคือการเดาในรายการเงิน
 */
function clearingRouteOf(sub: SubCategory, account: string, chosen?: string): SubCategory {
  const routes = clearingSubsFor(account, sub.cashflow);
  if (routes.length === 0) {
    // ไม่ควรมาถึงบรรทัดนี้ — `accrualAccountOf()` ปฏิเสธไปก่อนแล้ว
    throw new PostingError(`ตารางกฎไม่มีหมวดสำหรับล้าง ${coa(account).nameTh}`);
  }

  const pick = blankToUndefined(chosen);
  if (pick) {
    const found = routes.find((r) => r.code === pick);
    if (!found) {
      throw new PostingError(
        `หมวด "${pick}" ไม่ใช่ทางล้าง ${coa(account).nameTh} ของรายการนี้ — ` +
          `ทางที่ใช้ได้: ${routes.map((r) => r.code).join(" / ")}`
      );
    }
    return found;
  }

  if (routes.length > 1) {
    throw new PostingError(
      `${coa(account).nameTh} มีทางล้างมากกว่าหนึ่งทาง (${routes.map((r) => r.label).join(" / ")}) ` +
        "ต้องเลือกว่าจะล้างด้วยทางไหน"
    );
  }
  return routes[0];
}

/** ยอดที่ยืนยันไปแล้วจากประวัติที่ post จริง — ไม่รับตัวเลขสรุปที่หน้าจอคิดมาให้ */
function clearedSoFar(input: ClearingInput): number {
  const history = input.postedClearings;
  if (!Array.isArray(history)) {
    throw new PostingError(
      "ต้องส่งประวัติการยืนยันที่บันทึกแล้วมาด้วย (ส่ง [] ถ้ายังไม่เคยยืนยัน) — " +
        "ถ้าเดาว่ายังไม่เคยยืนยัน การกดซ้ำจะทำให้เงินสดเพิ่มสองเท่า"
    );
  }
  return round2(
    history.reduce((t, c, i) => t + money(c?.amount, `ยอดที่ยืนยันไปแล้วรายการที่ ${i + 1}`), 0)
  );
}

/**
 * สร้างบรรทัดบัญชีของการยืนยันเงินเข้า-ออก — ยังไม่บังคับกติกาเอกสารของนิติบุคคล
 *
 * ใช้พรีวิวในหน้าจอได้ เหตุผลเดียวกับ `buildPostingDraft()`: ไฟล์แนบไม่เปลี่ยนคู่บัญชี
 * ผู้ใช้จึงควรเห็นบรรทัดก่อนไปหาสลิป **แต่ปุ่มยืนยันต้องกั้นด้วย `buildClearing()`**
 */
export function buildClearingDraft(input: ClearingInput, resolve: LedgerResolver): PostingResult {
  // ประเภท + หมวดย่อยผ่านปากทางเดียวกับ `buildPosting()` (ดู guards.ts)
  const { sub } = assertTypeAndSub(input.typeKey, input.subCode);

  if (!blankToUndefined(input.sourceId)) {
    throw new PostingError("ต้องระบุรายการค้างที่จะยืนยัน");
  }
  if (!blankToUndefined(input.date)) {
    throw new PostingError("ต้องระบุวันที่ที่เงินเข้า-ออกจริง เพราะเป็นวันที่ที่งบกระแสเงินสดใช้");
  }

  // ผู้ถือก่อนบัญชี ไม่งั้นข้อความจะไปโผล่เป็น "บัญชีไม่ตรงผู้ถือ" ซึ่งชี้ผิดจุด
  assertOwnerSelectable(resolve, input.ownerId);

  const account = accrualAccountOf(sub);
  const route = clearingRouteOf(sub, account, input.clearingSubCode);

  /**
   * มิติบังคับของหมวดย่อย **ต้นทาง** — อ่านจากตารางกฎ (`requires`) ด่านเดียวกับ
   * `buildPosting()` เพราะการยืนยันคือ transaction จริงอีกใบของเหตุการณ์เดียวกัน
   * ถ้าใบที่ตั้งยอดผูกทรัพย์ไว้ แต่ใบที่ล้างไม่ผูก บัญชีย่อยรายทรัพย์จะไม่หักกลบกัน
   * และลูกหนี้/เจ้าหนี้ของทรัพย์ชิ้นนั้นจะค้างอยู่ตลอดไปทั้งที่เงินเข้าแล้ว
   *
   * อยู่ **หลัง** การหาบัญชีพัก/ทางล้างโดยตั้งใจ: หมวดที่ล้างไม่ได้เลยต้องได้ข้อความว่า
   * "ไม่มียอดค้างให้ยืนยัน" ซึ่งชี้ตรงจุดกว่า "ต้องผูกทรัพย์"
   */
  assertRequiredDimensions(sub, input);

  const accrued = money(input.accruedAmount, "ยอดค้าง");
  if (accrued === 0) {
    throw new PostingError(
      `รายการนี้ไม่มียอดค้างให้ยืนยัน — ถ้าเงินเข้า-ออกไปแล้วตอนบันทึก ไม่ต้องยืนยันอีก`
    );
  }

  const cleared = clearedSoFar(input);
  if (cleared > accrued) {
    throw new PostingError(
      `ยอดที่ยืนยันไปแล้ว (${baht(cleared)}) มากกว่ายอดค้าง (${baht(accrued)}) — ` +
        "ข้อมูลไม่ตรงกัน ต้องตรวจรายการเดิมก่อน ยืนยันต่อไม่ได้"
    );
  }

  const ref = blankToUndefined(input.clearingRef);
  if (ref && input.postedClearings.some((c) => c?.id === ref)) {
    throw new PostingError(
      `การยืนยันเลขอ้างอิง "${ref}" บันทึกไปแล้ว — ยืนยันซ้ำจะทำให้เงินสดเพิ่มสองเท่า`
    );
  }

  const outstanding = round2(accrued - cleared);
  if (outstanding === 0) {
    throw new PostingError(
      `รายการนี้ยืนยันเงินเข้า-ออกครบแล้ว (${baht(accrued)}) — ` +
        "ยืนยันซ้ำจะทำให้เงินสดเพิ่มสองเท่าและลูกหนี้/เจ้าหนี้ติดลบ"
    );
  }

  const amount = money(input.amount, "ยอดที่ยืนยัน");
  if (amount === 0) throw new PostingError("ยอดที่ยืนยันต้องมากกว่า 0");
  if (amount > outstanding) {
    throw new PostingError(
      `ยอดที่ยืนยัน (${baht(amount)}) เกินยอดค้างคงเหลือ (${baht(outstanding)}) — ` +
        "ล้างเกินจะทำให้ลูกหนี้/เจ้าหนี้ติดลบและเงินสดไม่ตรงกับ statement"
    );
  }

  // ขั้นนี้มีบรรทัดเงินสดเสมอ จึงต้องมีบัญชีเสมอ — แต่ยังตัดสินจากบรรทัดที่สร้างได้จริง
  // ด้านล่างอีกชั้น (`assertCashLinesHaveAccount`) เพื่อไม่ให้มีด่านที่เชื่อแค่ช่องใน input
  const bankAccountId = blankToUndefined(input.bankAccountId);
  if (!bankAccountId) {
    throw new PostingError(
      "ต้องเลือกบัญชีที่เงินเข้า-ออกจริงก่อนยืนยัน เพราะขั้นนี้ทำให้เงินสดเพิ่ม-ลด"
    );
  }
  assertBankBelongsTo(resolve, bankAccountId, input.ownerId);

  if (route.dr !== account && route.cr !== account) {
    throw new PostingError(
      `ทางล้าง "${route.label}" ไม่ได้แตะ ${coa(account).nameTh} — ตารางกฎไม่สอดคล้องกัน`
    );
  }

  const memo = `ยืนยันเงิน${coa(account).type === "asset" ? "เข้า" : "ออก"}จริง · อ้างรายการ ${input.sourceId}`;

  /** บรรทัดเงินสดผูกบัญชี · บรรทัดบัญชีพักที่เป็นสินทรัพย์ผูกทรัพย์ (เหมือน `buildPostingDraft()`) */
  const leg = (code: string, side: "debit" | "credit"): PostingLine => {
    const cashLeg = isCashAccount(code);
    return line({
      coaCode: code,
      bankAccountId: cashLeg ? bankAccountId : undefined,
      assetId: coa(code).type === "asset" && !cashLeg ? input.assetId : undefined,
      [side]: amount,
      // หมวดของ **รายการต้นทาง** — `clearingSubsFor()` คัดทางล้างด้วยหมวดนี้มาแล้ว
      cfCategory: sub.cashflow,
      memo: input.memo ? `${memo} · ${input.memo}` : memo,
    });
  };

  const transactions: PostingTransaction[] = [
    { ownerId: input.ownerId, lines: [leg(route.dr, "debit"), leg(route.cr, "credit")] },
  ];

  assertCashLinesHaveAccount(transactions);
  for (const t of transactions) {
    assertBalanced(t.lines);
    assertLinesValid(t.lines);
  }
  // บัญชีที่ปิดแล้วห้ามรับรายการใหม่ (D-092) — **จุดนี้คือจุดที่ตั้งใจให้กัน**
  // เส้นทางตั้งค้างปล่อยผ่านได้เพราะไม่มีบรรทัดเงินสด แต่การยืนยันมีเงินสดจริง
  assertCashAccountsActive(transactions, resolve);

  const remaining = round2(outstanding - amount);
  const summary = [
    `ล้าง${coa(account).nameTh} ${baht(amount)} บาท และเงินสด` +
      `${coa(account).type === "asset" ? "เพิ่ม" : "ลด"}เท่ากัน`,
    `ลงกระแสเงินสดหมวดเดียวกับรายการต้นทาง (${sub.label})`,
    remaining > 0
      ? `ยืนยันบางส่วน — ยังค้างอีก ${baht(remaining)} บาท`
      : "ยืนยันครบยอดค้างแล้ว ยอดลูกหนี้/เจ้าหนี้ของรายการนี้เป็นศูนย์",
  ];

  return { transactions, summary };
}

/**
 * บรรทัดบัญชีของการยืนยันเงินเข้า-ออก ที่ **พร้อมบันทึกจริง**
 *
 * ต่างจาก draft ตรงที่บังคับกติกาเอกสารของผู้ถือ — การยืนยันเงินออกของนิติบุคคล
 * คือการบันทึกจริง จึงต้องผ่านด่านเดียวกับที่ `buildPosting()` บังคับ ไม่มีทางลัด
 *
 * ปุ่ม "ยืนยันเงินเข้า-ออกแล้ว" ต้องกั้นด้วยฟังก์ชันนี้ ไม่ใช่ด้วยรายการช่องที่หน้าจอรู้จัก
 */
export function buildClearing(input: ClearingInput, resolve: LedgerResolver): PostingResult {
  const result = buildClearingDraft(input, resolve);
  for (const t of result.transactions) assertEvidencePolicy(input, t.ownerId, resolve);
  return result;
}
