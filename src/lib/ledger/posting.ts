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

import { findSub, isValidPair, accrualCheck, type SubCategory } from "@/lib/rules/tx-rules";
import { coa, isCashAccount, CASH_COA } from "@/lib/rules/coa";
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
  assertOwnerSelectable,
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

/** ตรวจว่ากรอกครบตามที่หมวดย่อยบังคับ ก่อนจะลงบัญชี */
function assertRequirements(sub: SubCategory, input: PostingInput): void {
  if (sub.requires?.includes("asset") && !input.assetId) {
    throw new PostingError(`หมวด "${sub.label}" ต้องผูกทรัพย์`);
  }
  if (sub.requires?.includes("contact") && !input.contactId) {
    throw new PostingError(`หมวด "${sub.label}" ต้องระบุผู้ติดต่อ`);
  }
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
 * สร้างรายการบัญชีจากสิ่งที่ผู้ใช้กรอก
 *
 * ปกติได้หนึ่ง transaction สองบรรทัดตามคู่บัญชีในตารางกฎ ยกเว้น:
 * - ขายทรัพย์ → เพิ่มบรรทัดกำไร/ขาดทุน (Backlog ข้อ 4)
 * - คืนเงินกู้ / รับคืนเงินต้น → แยกเงินต้นกับดอกเบี้ย (Backlog ข้อ 5)
 * - โอนภายในผู้ถือเดียวกัน → สองบรรทัดเงินสด คนละบัญชี
 * - โอนข้ามผู้ถือ → **สอง transaction คู่กัน** ฝ่ายละหนึ่ง (Money Invariant 3)
 */
export function buildPostingDraft(input: PostingInput, resolve: LedgerResolver): PostingResult {
  const found = findSub(input.subCode);
  if (!found) throw new PostingError(`ไม่พบหมวดย่อย ${input.subCode} ในตารางกฎ`);
  if (!isValidPair(input.typeKey, input.subCode)) {
    throw new PostingError(`หมวดย่อย "${found.sub.label}" ไม่อยู่ใต้ประเภท "${found.type.label}"`);
  }

  const { sub } = found;
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

  assertRequirements(sub, input);

  // เส้นทางพิเศษทั้งสามล้วนเป็นเรื่องของเงินที่เคลื่อนแล้ว — ตั้งค้างไม่ได้
  // โอนที่ยังไม่โอนคือยังไม่เกิดรายการ · ขายที่ยังไม่ได้รับเงินต้องบันทึกเป็นลูกหนี้ของทรัพย์แยกต่างหาก
  //
  // ถามจาก `canAccrueFromForm()` ไม่ใช่จาก `!sub.accrualCoa` — ตั้งแต่ D-069 เติมบัญชีพัก
  // ให้ทุกหมวดที่เงินเคลื่อนจริง การเช็คแค่ว่า "มีบัญชีพักไหม" จะปล่อยเส้นทางพิเศษผ่าน
  // ไปถึงสาขาที่ **ไม่สนใจ `notYetPaid` เลย** แล้วลงบรรทัดเงินสดเงียบๆ
  if (input.notYetPaid) accrualAccount(sub);

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
  } else if (sub.requires?.includes("capitalGain")) {
    // ---------- ขายทรัพย์ / ขายหลักทรัพย์ ----------
    const d = input.disposal!;
    // ตัวเลขคำนวณที่ `lib/disposal/capital-gain.ts` ที่เดียว ที่นี่แปลงเป็นบรรทัดบัญชีอย่างเดียว
    // money() ดักค่าที่คำนวณต่อไม่ได้ก่อน เพื่อให้ได้ข้อความภาษาคนแทน error ดิบ
    const r = computeDisposal({
      costBasis: money(d.costBasis, "ต้นทุน"),
      salePrice: money(d.salePrice, "ราคาขาย"),
      sellingCosts: money(d.sellingCosts ?? 0, "ค่าใช้จ่ายในการขาย"),
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
    summary.push("กำไรยังไม่รับรู้ของทรัพย์ชิ้นนี้ต้องถูกล้างออกพร้อมกัน");

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

    // เงินเข้า = รับคืนเงินต้น · เงินออก = ชำระคืนเงินกู้
    const isInflow = sub.cash === "in";
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

    transactions.push({
      ownerId: input.ownerId,
      lines: [
        line({
          coaCode: drCode,
          bankAccountId: drIsCash ? bankAccountId : undefined,
          assetId: coa(drCode).type === "asset" && !drIsCash ? input.assetId : undefined,
          debit: amount,
          cfCategory,
        }),
        line({
          coaCode: crCode,
          bankAccountId: crIsCash ? bankAccountId : undefined,
          assetId: coa(crCode).type === "asset" && !crIsCash ? input.assetId : undefined,
          credit: amount,
          cfCategory,
        }),
      ],
    });

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
