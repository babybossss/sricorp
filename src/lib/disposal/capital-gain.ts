/**
 * Backlog ข้อ 4 — คำนวณกำไร/ขาดทุนจากการขาย (Capital Gain/Loss)
 *
 * เวลาขายทรัพย์หรือขายหลักทรัพย์ ระบบต้องลงบัญชีสามอย่างพร้อมกัน:
 *   1. ตัดทรัพย์ออกจากงบดุล **ตามต้นทุน** (ไม่ใช่ราคาขาย)
 *   2. รับรู้ **กำไร/ขาดทุนจากการขาย** ใน P&L = เงินที่ได้สุทธิ − ต้นทุน
 *   3. เงินเข้าเป็นกระแสเงินสดจากการลงทุน
 *
 * และ **ส่วนต่างจากการตีราคาที่เคยบันทึกไว้ ต้องถูกล้างออกพร้อมกัน**
 * ไม่งั้นจะนับซ้ำสองรอบ — รอบแรกตอนตีราคา รอบสองตอนขายจริง
 *
 * ส่วนต่างนี้ **เป็นลบได้** เพราะทรัพย์มีมูลค่าต่ำกว่าทุนได้ และขายขาดทุนก็เกิดขึ้นจริง
 * ถ้ารับแต่ค่าบวก ทรัพย์ที่ราคาตกจะไม่มีที่ลง แล้วงบจะแสดงมูลค่าสูงเกินจริงเงียบๆ
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
   * ส่วนต่างจากการตีราคาที่เคยบันทึกไว้ = มูลค่าประเมินล่าสุด − ต้นทุน
   *
   * **บวก** = เคยตีราคาขึ้น (กำไรยังไม่รับรู้)
   * **ลบ**  = เคยตีราคาลง (ขาดทุนยังไม่รับรู้ / ด้อยค่า)
   *
   * ต้องล้างออกตอนขายทั้งสองทิศทาง
   */
  unrealizedAdjustment?: number;
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
  /** ส่วนต่างจากการตีราคาที่ต้องล้างออกพร้อมกัน · บวก = เคยตีขึ้น · ลบ = เคยตีลง */
  unrealizedToReverse: number;
  /** เคยตีราคาลง (ทรัพย์ต่ำกว่าทุน) — ข้อความเตือนต้องพูดคนละแบบกับตอนตีขึ้น */
  unrealizedIsLoss: boolean;
  /** เงินสดที่เข้าบัญชีจริง */
  cashIn: number;
};

const round2 = (n: number) => Math.round(n * 100) / 100;

export function computeDisposal(input: DisposalInput): DisposalResult {
  const { costBasis, salePrice } = input;
  const sellingCosts = input.sellingCosts ?? 0;
  const unrealizedAdjustment = input.unrealizedAdjustment ?? 0;

  if (costBasis < 0) throw new Error("ต้นทุนติดลบไม่ได้");
  if (salePrice < 0) throw new Error("ราคาขายติดลบไม่ได้");
  if (sellingCosts < 0) throw new Error("ค่าใช้จ่ายในการขายติดลบไม่ได้");
  // ส่วนต่างจากการตีราคา **ไม่ห้ามติดลบ** เพราะทรัพย์ต่ำกว่าทุนได้จริง
  // แต่ต้องเป็นตัวเลขที่คำนวณต่อได้
  if (!Number.isFinite(unrealizedAdjustment)) {
    throw new Error("ส่วนต่างจากการตีราคาต้องเป็นตัวเลขที่ระบุได้");
  }

  const netProceeds = round2(salePrice - sellingCosts);
  const capitalGain = round2(netProceeds - costBasis);

  return {
    costBasis: round2(costBasis),
    salePrice: round2(salePrice),
    sellingCosts: round2(sellingCosts),
    netProceeds,
    capitalGain,
    isGain: capitalGain >= 0,
    unrealizedToReverse: round2(unrealizedAdjustment),
    unrealizedIsLoss: unrealizedAdjustment < 0,
    // เงินเข้าบัญชีคือราคาขายหักค่าใช้จ่ายที่จ่ายไปพร้อมกัน
    cashIn: netProceeds,
  };
}
