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

import { findSub, isValidPair, type SubCategory } from "@/lib/rules/tx-rules";
import { coa, isCashAccount, CASH_COA } from "@/lib/rules/coa";
import { INTERCOMPANY_RULES } from "@/lib/rules/intercompany";
import { entityById } from "@/lib/mock/entities";
import { BANKS } from "@/lib/mock/banks";
import { computeDisposal } from "@/lib/disposal/capital-gain";
import {
  PostingError,
  type PostingInput,
  type PostingLine,
  type PostingResult,
  type PostingTransaction,
} from "./types";

const round2 = (n: number) => Math.round(n * 100) / 100;

/** ตัวเลขเงินที่รับได้: จำกัด ไม่ใช่ NaN/Infinity และไม่ติดลบ */
function money(n: number, label: string): number {
  if (typeof n !== "number" || !Number.isFinite(n)) {
    throw new PostingError(`${label} ต้องเป็นตัวเลขที่ระบุได้`);
  }
  if (n < 0) throw new PostingError(`${label} ติดลบไม่ได้`);
  return round2(n);
}

export function totalDebit(lines: PostingLine[]): number {
  return round2(lines.reduce((t, l) => t + l.debit, 0));
}

export function totalCredit(lines: PostingLine[]): number {
  return round2(lines.reduce((t, l) => t + l.credit, 0));
}

/** Money Invariant 1 — โยน error ถ้าไม่สมดุล */
export function assertBalanced(lines: PostingLine[]): void {
  const dr = totalDebit(lines);
  const cr = totalCredit(lines);
  if (dr !== cr) throw new PostingError(`รายการไม่สมดุล: เดบิต ${dr} · เครดิต ${cr}`);
}

/** Money Invariant 2 — บรรทัดเงินสดต้องผูกบัญชี · และไม่มีบรรทัดศูนย์ */
function assertLinesValid(lines: PostingLine[]): void {
  for (const l of lines) {
    if (isCashAccount(l.coaCode) && !l.bankAccountId) {
      throw new PostingError(`บรรทัดเงินสด ${l.coaCode} ต้องระบุบัญชีธนาคาร`);
    }
    if (l.debit === 0 && l.credit === 0) {
      throw new PostingError(`บรรทัด ${l.coaCode} มีทั้งเดบิตและเครดิตเป็นศูนย์`);
    }
    if (l.debit > 0 && l.credit > 0) {
      throw new PostingError(`บรรทัด ${l.coaCode} เป็นได้อย่างเดียว เดบิตหรือเครดิต`);
    }
  }
}

function line(p: Omit<PostingLine, "debit" | "credit"> & { debit?: number; credit?: number }): PostingLine {
  return { debit: 0, credit: 0, ...p };
}

function bankOwner(bankAccountId: string): string {
  const b = BANKS.find((x) => x.id === bankAccountId);
  if (!b) throw new PostingError(`ไม่พบบัญชีธนาคาร: ${bankAccountId}`);
  return b.ownerId;
}

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
  if (!sub.accrualCoa) {
    throw new PostingError(
      `หมวด "${sub.label}" ยังตั้งค้างรับ-ค้างจ่ายไม่ได้ — ตารางกฎยังไม่ได้ระบุบัญชีลูกหนี้/เจ้าหนี้ของหมวดนี้`
    );
  }
  return sub.accrualCoa;
}

/**
 * ผู้ถือต้องเป็นตัวตนที่ถือทรัพย์ได้จริง — "SRI Family (รวม)" เป็นมุมมองรวม ไม่ใช่เจ้าของ
 * เป็นเงื่อนไขเชิงโครงสร้าง ไม่ใช่นโยบายเอกสาร จึงตรวจตั้งแต่ตอนสร้างบรรทัด
 */
function assertOwnerSelectable(ownerId: string): void {
  const owner = entityById(ownerId);
  if (!owner.selectableAsHolder) {
    throw new PostingError(`"${owner.name}" เป็นมุมมองรวม เลือกเป็นผู้ถือของรายการไม่ได้`);
  }
}

/**
 * Corporate strict — ดักตั้งแต่ที่นี่เพื่อให้ผู้ใช้เห็นข้อความที่เข้าใจได้
 * (DB มี trigger กันอีกชั้นอยู่แล้ว ที่นี่ไม่ได้แทนที่ แต่ช่วยให้รู้ตัวก่อนกดส่ง)
 *
 * แยกออกจากการสร้างบรรทัดโดยตั้งใจ: เอกสารหลักฐานไม่ได้เปลี่ยนคู่บัญชี
 * พรีวิวจึงแสดงบรรทัดได้ทั้งที่ยังไม่แนบไฟล์ แต่ `buildPosting()` จะไม่ยอมปล่อยผ่าน
 */
function assertEvidencePolicy(input: PostingInput, ownerId: string): void {
  const owner = entityById(ownerId);
  if (owner.policy !== "corporate_strict") return;
  if ((input.attachments?.length ?? 0) === 0) {
    throw new PostingError(
      `${owner.name} เป็นนิติบุคคล ต้องแนบหลักฐาน (ใบเสร็จ/ใบแจ้งหนี้/สัญญา) ก่อนบันทึก`
    );
  }
  if (!input.contactId) {
    throw new PostingError(`${owner.name} เป็นนิติบุคคล ต้องระบุคู่ค้าทุกรายการ`);
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
export function buildPostingDraft(input: PostingInput): PostingResult {
  const found = findSub(input.subCode);
  if (!found) throw new PostingError(`ไม่พบหมวดย่อย ${input.subCode} ในตารางกฎ`);
  if (!isValidPair(input.typeKey, input.subCode)) {
    throw new PostingError(`หมวดย่อย "${found.sub.label}" ไม่อยู่ใต้ประเภท "${found.type.label}"`);
  }

  const { sub } = found;
  const amount = money(input.amount, "จำนวนเงิน");
  if (amount === 0) throw new PostingError("จำนวนเงินต้องมากกว่า 0");
  if (!input.bankAccountId) throw new PostingError("ต้องระบุบัญชีธนาคารที่เงินเข้าหรือออก");

  // ผู้ถือต้องถือทรัพย์ได้จริงก่อน ไม่งั้นข้อความจะไปโผล่เป็น "บัญชีไม่ตรงผู้ถือ" ซึ่งชี้ผิดจุด
  assertOwnerSelectable(input.ownerId);

  // ตรวจว่าบัญชีมีอยู่จริง และเป็นของผู้ถือที่ระบุ
  const sourceOwner = bankOwner(input.bankAccountId);
  if (sourceOwner !== input.ownerId) {
    throw new PostingError(
      `บัญชีที่เลือกเป็นของ ${entityById(sourceOwner).name} แต่รายการระบุผู้ถือเป็น ${entityById(input.ownerId).name}`
    );
  }

  assertRequirements(sub, input);

  // เส้นทางพิเศษทั้งสามล้วนเป็นเรื่องของเงินที่เคลื่อนแล้ว — ตั้งค้างไม่ได้
  // โอนที่ยังไม่โอนคือยังไม่เกิดรายการ · ขายที่ยังไม่ได้รับเงินต้องบันทึกเป็นลูกหนี้ของทรัพย์แยกต่างหาก
  if (input.notYetPaid && !sub.accrualCoa) accrualAccount(sub);

  const summary: string[] = [sub.plain];
  const transactions: PostingTransaction[] = [];

  if (sub.requires?.includes("transferTarget")) {
    // ---------- โอนระหว่างบัญชี ----------
    // ดูจากธงในตารางกฎ ไม่ใช่รหัสหมวด — หมวดโอนตัวที่สองในอนาคตจะได้ไม่ตกไปเส้นทางปกติ
    // ซึ่งจะเดบิตและเครดิตบัญชีเงินสดเดียวกัน กลายเป็นรายการว่างที่สมดุลผ่านทุกด่าน
    // แล้วบัญชีปลายทางถูกทิ้งเงียบๆ
    const to = input.transferToBankAccountId;
    if (!to) throw new PostingError("โอนระหว่างบัญชีต้องระบุบัญชีปลายทาง");
    if (to === input.bankAccountId) throw new PostingError("โอนเข้าบัญชีเดียวกันไม่ได้");

    // อ่านผู้ถือจากบัญชีปลายทางเอง ไม่เชื่อฟิลด์ที่ผู้ใช้เว้นได้
    const targetOwner = bankOwner(to);
    const crossOwner = targetOwner !== input.ownerId;

    if (!crossOwner) {
      // ย้ายกระเป๋าภายในคนเดียวกัน — หนึ่งรายการ สองบรรทัด
      transactions.push({
        ownerId: input.ownerId,
        lines: [
          line({ coaCode: CASH_COA, bankAccountId: to, debit: amount, cfCategory: "none", memo: "รับโอนเข้า" }),
          line({ coaCode: CASH_COA, bankAccountId: input.bankAccountId, credit: amount, cfCategory: "none", memo: "โอนออก" }),
        ],
      });
      summary.push("ยอดรวมกองกลางไม่เปลี่ยน จึงไม่นับในงบกระแสเงินสดและไม่กระทบกำไรขาดทุน");
    } else {
      const nature = input.intercompanyNature;
      if (!nature) {
        throw new PostingError(
          `โอนไปบัญชีของ ${entityById(targetOwner).name} เป็นรายการข้ามผู้ถือ ` +
            "ต้องระบุลักษณะ (เงินทดรอง / กู้ยืม / เพิ่มทุน / ปันผล)"
        );
      }
      assertOwnerSelectable(targetOwner);

      const rule = INTERCOMPANY_RULES[nature];

      // ฝ่ายจ่ายกับฝ่ายรับอยู่คนละหมวดกระแสเงินสด — ปล่อยกู้เป็น Investing ของฝ่ายจ่าย
      // ส่วนฝ่ายที่กู้เข้ามาเป็น Financing (กฎเหล็กข้อ 8)
      transactions.push({
        ownerId: input.ownerId,
        counterOwnerId: targetOwner,
        intercompanyNature: nature,
        lines: [
          line({ coaCode: rule.payer.coa, debit: amount, cfCategory: rule.payer.cashflow, memo: rule.label }),
          line({ coaCode: CASH_COA, bankAccountId: input.bankAccountId, credit: amount, cfCategory: rule.payer.cashflow }),
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
          `${entityById(input.ownerId).name} ลง ${coa(rule.payer.coa).nameTh} · ` +
          `${entityById(targetOwner).name} ลง ${coa(rule.receiver.coa).nameTh}`
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
      line({ coaCode: CASH_COA, bankAccountId: input.bankAccountId, debit: netProceeds, cfCategory: sub.cashflow }),
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
        line({ coaCode: CASH_COA, bankAccountId: input.bankAccountId, debit: principal, cfCategory: sub.cashflow, memo: "รับคืนเงินต้น" })
      );
      lines.push(line({ coaCode: sub.cr, assetId: input.assetId, credit: principal, cfCategory: sub.cashflow, memo: "เงินต้น" }));
      if (interest > 0) {
        lines.push(
          line({ coaCode: CASH_COA, bankAccountId: input.bankAccountId, debit: interest, cfCategory: "operating", memo: "รับดอกเบี้ย" })
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
      lines.push(line({ coaCode: CASH_COA, bankAccountId: input.bankAccountId, credit: amount, cfCategory: sub.cashflow }));
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
          bankAccountId: drIsCash ? input.bankAccountId : undefined,
          assetId: coa(drCode).type === "asset" && !drIsCash ? input.assetId : undefined,
          debit: amount,
          cfCategory,
        }),
        line({
          coaCode: crCode,
          bankAccountId: crIsCash ? input.bankAccountId : undefined,
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

  // ตรวจทุกรายการก่อนส่งออก — ทีละ transaction เพราะ DB ตรวจสมดุลต่อ transaction
  for (const t of transactions) {
    assertBalanced(t.lines);
    assertLinesValid(t.lines);
  }

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
export function buildPosting(input: PostingInput): PostingResult {
  const result = buildPostingDraft(input);
  for (const t of result.transactions) assertEvidencePolicy(input, t.ownerId);
  return result;
}

/** รวมทุกบรรทัดจากทุกรายการ — ใช้ตอนแสดงผลรวมหรือทดสอบ */
export function allLines(result: PostingResult): PostingLine[] {
  return result.transactions.flatMap((t) => t.lines);
}
