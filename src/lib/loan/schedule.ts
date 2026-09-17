/**
 * Backlog ข้อ 2 — สร้างตารางงวดชำระจากเงื่อนไขสัญญา
 *
 * ใช้กับทั้งฝั่งที่เรากู้เขา (loan payable) และฝั่งที่เราให้เขากู้ (loan receivable /
 * ขายฝาก / จำนอง) หน้า "ยืนยันรับ-จ่าย" และ "ค้างรับ/ค้างจ่าย" ดึงตารางนี้ไปใช้
 *
 * ทุกงวดแยก **เงินต้น** กับ **ดอกเบี้ย** ตั้งแต่ตอนสร้าง เพราะสองอย่างนี้ลงบัญชีคนละที่
 * (เงินต้น = ลดหนี้สิน/ลดลูกหนี้ · ดอกเบี้ย = P&L) — ตรงกับ Backlog ข้อ 5
 */

export type InterestMethod =
  /** ดอกเบี้ยคงที่ต่องวดจากเงินต้นตั้งต้น — ที่ใช้กันในขายฝาก/จำนอง */
  | "flat"
  /** ลดต้นลดดอก — ดอกเบี้ยคิดจากเงินต้นคงเหลือ */
  | "effective"
  /** จ่ายดอกอย่างเดียวทุกงวด แล้วคืนเงินต้นก้อนเดียวงวดสุดท้าย */
  | "interest_only";

export type RatePeriod = "year" | "month";

export type LoanTerms = {
  /** เงินต้น (บาท) */
  principal: number;
  /** อัตราดอกเบี้ย เช่น 0.0125 = 1.25% ต่อ `ratePeriod` */
  rate: number;
  ratePeriod: RatePeriod;
  method: InterestMethod;
  /** จำนวนงวด */
  installments: number;
  /** วันที่รับเงิน (ISO yyyy-mm-dd) */
  startDate: string;
  /** วันชำระของแต่ละเดือน 1-31 — ถ้าไม่ระบุใช้วันเดียวกับ startDate */
  paymentDay?: number;
};

export type Installment = {
  period: number;
  dueDate: string;
  /** เงินต้นที่ชำระงวดนี้ */
  principal: number;
  /** ดอกเบี้ยงวดนี้ */
  interest: number;
  /** รวมที่ต้องจ่าย/รับงวดนี้ */
  total: number;
  /** เงินต้นคงเหลือหลังงวดนี้ */
  balance: number;
};

const round2 = (n: number) => Math.round(n * 100) / 100;

/** อัตราดอกเบี้ยต่อ 1 งวด (งวด = เดือน) */
export function monthlyRate(terms: Pick<LoanTerms, "rate" | "ratePeriod">): number {
  return terms.ratePeriod === "year" ? terms.rate / 12 : terms.rate;
}

/** บวกเดือนแบบไม่ให้วันล้นเดือน (31 ม.ค. + 1 เดือน = 28/29 ก.พ.) */
function addMonths(iso: string, months: number, paymentDay?: number): string {
  const [y, m, d] = iso.split("-").map(Number);
  const target = new Date(Date.UTC(y, m - 1 + months, 1));
  const lastDay = new Date(Date.UTC(target.getUTCFullYear(), target.getUTCMonth() + 1, 0)).getUTCDate();
  const day = Math.min(paymentDay ?? d, lastDay);
  target.setUTCDate(day);
  return target.toISOString().slice(0, 10);
}

/**
 * สร้างตารางงวดชำระ
 *
 * ปัดเศษแล้วยอดรวมต้องเท่าเงินต้นเป๊ะ — เศษที่เหลือจากการปัดไปลงงวดสุดท้าย
 * ไม่งั้นเงินต้นคงเหลือจะไม่เป็นศูนย์ และงบดุลจะเพี้ยนทีละสตางค์
 */
export function buildSchedule(terms: LoanTerms): Installment[] {
  const { principal, installments, method, startDate, paymentDay } = terms;

  if (principal <= 0) throw new Error("เงินต้นต้องมากกว่า 0");
  if (installments <= 0) throw new Error("จำนวนงวดต้องมากกว่า 0");
  if (terms.rate < 0) throw new Error("อัตราดอกเบี้ยติดลบไม่ได้");

  const r = monthlyRate(terms);
  const out: Installment[] = [];
  let balance = principal;

  for (let i = 1; i <= installments; i++) {
    const isLast = i === installments;
    let principalPart: number;
    let interestPart: number;

    switch (method) {
      case "flat": {
        // ดอกเบี้ยคิดจากเงินต้นตั้งต้นทุกงวด เงินต้นเฉลี่ยเท่ากันทุกงวด
        interestPart = round2(principal * r);
        principalPart = isLast ? balance : round2(principal / installments);
        break;
      }
      case "effective": {
        // ลดต้นลดดอก: ดอกจากเงินต้นคงเหลือ · ค่างวดเท่ากันทุกงวด
        interestPart = round2(balance * r);
        if (r === 0) {
          principalPart = isLast ? balance : round2(principal / installments);
        } else {
          const payment = (principal * r) / (1 - Math.pow(1 + r, -installments));
          principalPart = isLast ? balance : round2(payment - interestPart);
        }
        break;
      }
      case "interest_only": {
        // จ่ายดอกอย่างเดียว คืนเงินต้นทั้งก้อนงวดสุดท้าย
        interestPart = round2(balance * r);
        principalPart = isLast ? balance : 0;
        break;
      }
    }

    // กันเงินต้นงวดนี้เกินยอดคงเหลือ
    principalPart = Math.min(round2(principalPart), round2(balance));
    balance = round2(balance - principalPart);

    out.push({
      period: i,
      dueDate: addMonths(startDate, i, paymentDay),
      principal: principalPart,
      interest: interestPart,
      total: round2(principalPart + interestPart),
      balance,
    });
  }

  return out;
}

export type ScheduleSummary = {
  installments: number;
  totalPrincipal: number;
  totalInterest: number;
  totalPayment: number;
  firstDue: string;
  lastDue: string;
};

export function summarize(rows: Installment[]): ScheduleSummary {
  return {
    installments: rows.length,
    totalPrincipal: round2(rows.reduce((t, r) => t + r.principal, 0)),
    totalInterest: round2(rows.reduce((t, r) => t + r.interest, 0)),
    totalPayment: round2(rows.reduce((t, r) => t + r.total, 0)),
    firstDue: rows[0]?.dueDate ?? "",
    lastDue: rows[rows.length - 1]?.dueDate ?? "",
  };
}

export const INTEREST_METHOD_LABEL: Record<InterestMethod, string> = {
  flat: "คงที่จากเงินต้นตั้งต้น (Flat)",
  effective: "ลดต้นลดดอก (Effective)",
  interest_only: "จ่ายดอกอย่างเดียว คืนต้นงวดสุดท้าย",
};

export const INTEREST_METHOD_HINT: Record<InterestMethod, string> = {
  flat: "ดอกเบี้ยเท่ากันทุกงวด · แบบที่ใช้กันในขายฝาก/จำนอง",
  effective: "ดอกเบี้ยลดลงเรื่อยๆ ตามเงินต้นที่เหลือ · แบบที่ธนาคารใช้",
  interest_only: "เหมาะกับสัญญาที่ตกลงคืนเงินต้นทีเดียวตอนครบกำหนด",
};
