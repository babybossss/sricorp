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
import { entityById } from "@/lib/mock/entities";
import { BANKS } from "@/lib/mock/banks";
import {
  PostingError,
  type IntercompanyNature,
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
 * Corporate strict — ดักตั้งแต่ที่นี่เพื่อให้ผู้ใช้เห็นข้อความที่เข้าใจได้
 * (DB มี trigger กันอีกชั้นอยู่แล้ว ที่นี่ไม่ได้แทนที่ แต่ช่วยให้รู้ตัวก่อนกดส่ง)
 */
function assertOwnerPolicy(input: PostingInput): void {
  const owner = entityById(input.ownerId);
  if (!owner.selectableAsHolder) {
    throw new PostingError(`"${owner.name}" เป็นมุมมองรวม เลือกเป็นผู้ถือของรายการไม่ได้`);
  }
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

const NATURE_TH: Record<IntercompanyNature, string> = {
  advance: "เงินทดรอง",
  loan: "กู้ยืมระหว่างกัน",
  capital: "เพิ่มทุน",
  dividend: "ปันผล",
};

/**
 * คู่บัญชีของขาที่ไม่ใช่เงินสด ในรายการข้ามผู้ถือ
 *
 * ฝ่ายจ่าย = ผู้ถือที่เงินออก · ฝ่ายรับ = ผู้ถือที่เงินเข้า
 * ทั้งสองฝ่ายต้องลงบัญชีที่สะท้อนความสัมพันธ์จริง ไม่ใช่แค่ย้ายเงินสด
 */
function intercompanyAccounts(nature: IntercompanyNature): { payer: string; receiver: string } {
  switch (nature) {
    case "advance":
      // ผู้จ่ายออกเงินแทน → เกิดลูกหนี้ · ผู้รับติดหนี้
      return { payer: "1300", receiver: "2400" };
    case "loan":
      return { payer: "1300", receiver: "2400" };
    case "capital":
      // ผู้จ่ายลงทุนเพิ่มในกิจการ → ผู้รับส่วนของเจ้าของเพิ่ม
      return { payer: "1700", receiver: "3100" };
    case "dividend":
      // ผู้จ่ายลดส่วนของเจ้าของ · ผู้รับได้เงินปันผลเป็นรายได้
      return { payer: "3200", receiver: "4410" };
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
export function buildPosting(input: PostingInput): PostingResult {
  const found = findSub(input.subCode);
  if (!found) throw new PostingError(`ไม่พบหมวดย่อย ${input.subCode} ในตารางกฎ`);
  if (!isValidPair(input.typeKey, input.subCode)) {
    throw new PostingError(`หมวดย่อย "${found.sub.label}" ไม่อยู่ใต้ประเภท "${found.type.label}"`);
  }

  const { sub } = found;
  const amount = money(input.amount, "จำนวนเงิน");
  if (amount === 0) throw new PostingError("จำนวนเงินต้องมากกว่า 0");
  if (!input.bankAccountId) throw new PostingError("ต้องระบุบัญชีธนาคารที่เงินเข้าหรือออก");

  // ตรวจว่าบัญชีมีอยู่จริง และเป็นของผู้ถือที่ระบุ
  const sourceOwner = bankOwner(input.bankAccountId);
  if (sourceOwner !== input.ownerId) {
    throw new PostingError(
      `บัญชีที่เลือกเป็นของ ${entityById(sourceOwner).name} แต่รายการระบุผู้ถือเป็น ${entityById(input.ownerId).name}`
    );
  }

  assertRequirements(sub, input);
  assertOwnerPolicy(input);

  const summary: string[] = [sub.plain];
  const transactions: PostingTransaction[] = [];

  if (sub.code === "trf.internal") {
    // ---------- โอนระหว่างบัญชี ----------
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
      const acct = intercompanyAccounts(nature);

      // ฝ่ายจ่าย: เงินสดออก · อีกขาตามลักษณะของรายการ
      transactions.push({
        ownerId: input.ownerId,
        counterOwnerId: targetOwner,
        intercompanyNature: nature,
        lines: [
          line({ coaCode: acct.payer, debit: amount, cfCategory: "financing", memo: NATURE_TH[nature] }),
          line({ coaCode: CASH_COA, bankAccountId: input.bankAccountId, credit: amount, cfCategory: "financing" }),
        ],
      });

      // ฝ่ายรับ: เงินสดเข้า · อีกขาตรงข้าม
      transactions.push({
        ownerId: targetOwner,
        counterOwnerId: input.ownerId,
        intercompanyNature: nature,
        lines: [
          line({ coaCode: CASH_COA, bankAccountId: to, debit: amount, cfCategory: "financing" }),
          line({ coaCode: acct.receiver, credit: amount, cfCategory: "financing", memo: NATURE_TH[nature] }),
        ],
      });

      summary.push(
        `ข้ามผู้ถือ (${NATURE_TH[nature]}) — สร้างสองรายการคู่กัน: ` +
          `${entityById(input.ownerId).name} ลง ${coa(acct.payer).nameTh} · ` +
          `${entityById(targetOwner).name} ลง ${coa(acct.receiver).nameTh}`
      );
      summary.push("งบรวมจะตัดรายการระหว่างกันออก ยอดกองกลางจึงไม่เปลี่ยน");
    }
  } else if (sub.requires?.includes("capitalGain")) {
    // ---------- ขายทรัพย์ / ขายหลักทรัพย์ ----------
    const d = input.disposal!;
    const costBasis = money(d.costBasis, "ต้นทุน");
    const salePrice = money(d.salePrice, "ราคาขาย");
    const sellingCosts = money(d.sellingCosts ?? 0, "ค่าใช้จ่ายในการขาย");

    if (costBasis === 0) throw new PostingError("ต้นทุนต้องมากกว่า 0 — ทรัพย์ที่ไม่มีต้นทุนตัดออกไม่ได้");

    const netProceeds = round2(salePrice - sellingCosts);
    if (!(netProceeds > 0)) {
      throw new PostingError(
        `เงินที่ได้สุทธิต้องมากกว่า 0 (ราคาขาย ${salePrice} − ค่าใช้จ่าย ${sellingCosts} = ${netProceeds})`
      );
    }
    if (netProceeds !== amount) {
      throw new PostingError(
        `ยอดที่รับจริงต้องเท่ากับ ราคาขาย − ค่าใช้จ่ายในการขาย (${netProceeds}) แต่กรอกมา ${amount}`
      );
    }

    const gain = round2(netProceeds - costBasis);
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
      // เงินสดเข้าเต็มจำนวน · เงินต้นลดลูกหนี้ · ดอกเบี้ยเป็นรายได้
      lines.push(line({ coaCode: CASH_COA, bankAccountId: input.bankAccountId, debit: amount, cfCategory: sub.cashflow }));
      if (principal > 0) {
        lines.push(line({ coaCode: sub.cr, assetId: input.assetId, credit: principal, cfCategory: sub.cashflow, memo: "เงินต้น" }));
      }
      if (interest > 0) {
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
    const drIsCash = isCashAccount(sub.dr);
    const crIsCash = isCashAccount(sub.cr);

    transactions.push({
      ownerId: input.ownerId,
      lines: [
        line({
          coaCode: sub.dr,
          bankAccountId: drIsCash ? input.bankAccountId : undefined,
          assetId: coa(sub.dr).type === "asset" && !drIsCash ? input.assetId : undefined,
          debit: amount,
          cfCategory: sub.cashflow,
        }),
        line({
          coaCode: sub.cr,
          bankAccountId: crIsCash ? input.bankAccountId : undefined,
          assetId: coa(sub.cr).type === "asset" && !crIsCash ? input.assetId : undefined,
          credit: amount,
          cfCategory: sub.cashflow,
        }),
      ],
    });
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

/** รวมทุกบรรทัดจากทุกรายการ — ใช้ตอนแสดงผลรวมหรือทดสอบ */
export function allLines(result: PostingResult): PostingLine[] {
  return result.transactions.flatMap((t) => t.lines);
}
