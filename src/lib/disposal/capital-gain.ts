/**
 * Backlog ข้อ 4 — คำนวณกำไร/ขาดทุนจากการขาย (Capital Gain/Loss)
 *
 * เวลาขายทรัพย์หรือขายหลักทรัพย์ ระบบต้องลงบัญชีสามอย่างพร้อมกัน:
 *   1. ตัดทรัพย์ออกจากงบดุล **ตามต้นทุน** (ไม่ใช่ราคาขาย)
 *   2. รับรู้ **กำไร/ขาดทุนจากการขาย** ใน P&L = เงินที่ได้สุทธิ − ต้นทุน
 *   3. เงินเข้าเป็นกระแสเงินสดจากการลงทุน
 *
 * และ **กำไรยังไม่รับรู้ (unrealized) ของทรัพย์ชิ้นนั้นต้องถูกล้างออกพร้อมกัน**
 * ไม่งั้นจะนับกำไรซ้ำสองรอบ — รอบแรกตอนตีราคา รอบสองตอนขายจริง
 *
 * ไฟล์นี้คำนวณตัวเลขอย่างเดียว **ไม่ประกอบบรรทัดบัญชี** —
 * คู่บัญชีอยู่ที่ `lib/ledger/posting.ts` ที่เดียว ซึ่งเรียก `computeDisposal()` ตัวนี้ต่อ
 */

export type DisposalInput = {
  /** ต้นทุนของทรัพย์ตามบัญชี */
  costBasis: number;
  /** ราคาขายที่ตกลงกัน */
  salePrice: number;
  /** ค่าธรรมเนียม/ค่าใช้จ่ายในการขาย เช่น ค่านายหน้า ค่าโอน */
  sellingCosts?: number;
  /**
   * กำไรยังไม่รับรู้ที่เคยบันทึกไว้จากการตีราคา
   * (มูลค่าประเมินล่าสุด − ต้นทุน) — ต้องล้างออกตอนขาย
   */
  unrealizedGain?: number;
};

export type DisposalResult = {
  costBasis: number;
  salePrice: number;
  sellingCosts: number;
  /** เงินที่ได้สุทธิหลังหักค่าใช้จ่ายในการขาย */
  netProceeds: number;
  /** กำไร (+) หรือ ขาดทุน (−) จากการขาย เข้า P&L */
  capitalGain: number;
  isGain: boolean;
  /** กำไรยังไม่รับรู้ที่ต้องล้างออกพร้อมกัน */
  unrealizedToReverse: number;
  /** เงินสดที่เข้าบัญชีจริง */
  cashIn: number;
};

const round2 = (n: number) => Math.round(n * 100) / 100;

export function computeDisposal(input: DisposalInput): DisposalResult {
  const { costBasis, salePrice } = input;
  const sellingCosts = input.sellingCosts ?? 0;
  const unrealizedGain = input.unrealizedGain ?? 0;

  if (costBasis < 0) throw new Error("ต้นทุนติดลบไม่ได้");
  if (salePrice < 0) throw new Error("ราคาขายติดลบไม่ได้");
  if (sellingCosts < 0) throw new Error("ค่าใช้จ่ายในการขายติดลบไม่ได้");

  const netProceeds = round2(salePrice - sellingCosts);
  const capitalGain = round2(netProceeds - costBasis);

  return {
    costBasis: round2(costBasis),
    salePrice: round2(salePrice),
    sellingCosts: round2(sellingCosts),
    netProceeds,
    capitalGain,
    isGain: capitalGain >= 0,
    unrealizedToReverse: round2(unrealizedGain),
    // เงินเข้าบัญชีคือราคาขายหักค่าใช้จ่ายที่จ่ายไปพร้อมกัน
    cashIn: netProceeds,
  };
}
