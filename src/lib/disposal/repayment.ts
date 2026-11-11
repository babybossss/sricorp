/**
 * Backlog ข้อ 5 — แยกเงินต้นกับดอกเบี้ยตอนคืนเงินกู้
 *
 * เงินต้น = ลดหนี้สินในงบดุล **ไม่ใช่ค่าใช้จ่าย**
 * ดอกเบี้ย = ค่าใช้จ่ายใน P&L
 *
 * ถ้ารวมเป็นก้อนเดียวแล้วลงเป็นค่าใช้จ่ายทั้งหมด จะได้กำไรต่ำกว่าจริง
 * และหนี้สินในงบดุลไม่ลดลงตามที่จ่ายไป — ผิดทั้งสองงบ
 *
 * ไฟล์นี้แยกตัวเลขอย่างเดียว **ไม่ประกอบบรรทัดบัญชี** — คู่บัญชีอยู่ที่ `lib/ledger/posting.ts`
 */

import type { Installment } from "@/lib/loan/schedule";

export type RepaymentInput = {
  /** ยอดที่จ่ายจริงงวดนี้ */
  amountPaid: number;
  /** งวดตามสัญญา ถ้ามี — ใช้ตั้งค่าเริ่มต้นให้ผู้ใช้ยืนยัน */
  installment?: Installment;
  /** ถ้าไม่มีสัญญา ผู้ใช้กรอกเองได้ */
  manualPrincipal?: number;
  manualInterest?: number;
};

export type RepaymentSplit = {
  principal: number;
  interest: number;
  total: number;
  /** มาจากตารางงวดหรือผู้ใช้กรอกเอง */
  source: "schedule" | "manual" | "interest_first";
  /** จ่ายไม่ตรงกับงวด เช่น จ่ายบางส่วนหรือจ่ายเกิน */
  isPartial: boolean;
  note?: string;
};

const round2 = (n: number) => Math.round(n * 100) / 100;

/**
 * แยกเงินต้น/ดอกเบี้ยจากยอดที่จ่าย
 *
 * ลำดับความสำคัญ:
 * 1. ผู้ใช้ระบุเอง → ใช้ตามนั้น (แต่ต้องรวมกันเท่ายอดที่จ่าย)
 * 2. มีงวดตามสัญญา และจ่ายตรงยอด → ใช้ตามงวด
 * 3. มีงวดแต่จ่ายไม่ตรง → **ตัดดอกเบี้ยก่อน แล้วที่เหลือเป็นเงินต้น**
 *    (หลักปฏิบัติมาตรฐาน เจ้าหนี้รับดอกก่อนเสมอ)
 */
export function splitRepayment(input: RepaymentInput): RepaymentSplit {
  const { amountPaid, installment } = input;

  if (amountPaid <= 0) throw new Error("ยอดที่จ่ายต้องมากกว่า 0");

  // 1. ผู้ใช้ระบุเอง
  if (input.manualPrincipal !== undefined || input.manualInterest !== undefined) {
    const principal = round2(input.manualPrincipal ?? 0);
    const interest = round2(input.manualInterest ?? 0);
    if (principal < 0 || interest < 0) throw new Error("เงินต้นและดอกเบี้ยติดลบไม่ได้");
    if (round2(principal + interest) !== round2(amountPaid)) {
      throw new Error(
        `เงินต้น (${principal}) + ดอกเบี้ย (${interest}) ต้องเท่ากับยอดที่จ่าย (${amountPaid})`
      );
    }
    return { principal, interest, total: round2(amountPaid), source: "manual", isPartial: false };
  }

  // 2. ไม่มีสัญญาอ้างอิง — ต้องให้ผู้ใช้กรอกเอง ไม่เดา
  if (!installment) {
    throw new Error("ไม่มีตารางงวดอ้างอิง ต้องระบุเงินต้นและดอกเบี้ยเอง");
  }

  // 3. จ่ายตรงตามงวด
  if (round2(amountPaid) === round2(installment.total)) {
    return {
      principal: installment.principal,
      interest: installment.interest,
      total: round2(amountPaid),
      source: "schedule",
      isPartial: false,
    };
  }

  // 4. จ่ายไม่ตรงงวด — ตัดดอกเบี้ยก่อน ที่เหลือเป็นเงินต้น
  const interest = Math.min(round2(installment.interest), round2(amountPaid));
  const principal = round2(amountPaid - interest);

  return {
    principal,
    interest,
    total: round2(amountPaid),
    source: "interest_first",
    isPartial: true,
    note:
      amountPaid < installment.total
        ? `จ่ายน้อยกว่างวด ${round2(installment.total - amountPaid)} บาท — ตัดดอกเบี้ยก่อน ที่เหลือเป็นเงินต้น`
        : `จ่ายเกินงวด ${round2(amountPaid - installment.total)} บาท — ส่วนเกินตัดเป็นเงินต้น`,
  };
}
