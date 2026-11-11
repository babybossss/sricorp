/**
 * กฎการลงบัญชีของรายการข้ามผู้ถือกรรมสิทธิ์
 *
 * อยู่ในโฟลเดอร์ `rules/` เพราะเป็น**กฎบัญชี** ไม่ใช่ตรรกะของ engine —
 * engine อ่านจากที่นี่เหมือนที่อ่านคู่บัญชีจาก `tx-rules.ts`
 *
 * หลักที่ต้องถูกต้อง: ฝ่ายจ่ายกับฝ่ายรับอยู่คนละหมวดกระแสเงินสดเสมอ
 * เช่น ปล่อยกู้ = **Investing** ของฝ่ายจ่าย · กู้เข้ามา = **Financing** ของฝ่ายรับ
 */

import type { CashflowSection } from "./tx-rules";

export type IntercompanyNature = "advance" | "loan" | "capital" | "dividend";

export type IntercompanySide = {
  /** รหัสบัญชีของขาที่ไม่ใช่เงินสด */
  coa: string;
  /** หมวดกระแสเงินสดของฝ่ายนี้ */
  cashflow: CashflowSection;
};

export type IntercompanyRule = {
  label: string;
  /** ฝ่ายที่เงินออก */
  payer: IntercompanySide;
  /** ฝ่ายที่เงินเข้า */
  receiver: IntercompanySide;
  note: string;
};

export const INTERCOMPANY_RULES: Record<IntercompanyNature, IntercompanyRule> = {
  advance: {
    label: "เงินทดรอง",
    // ออกเงินแทนกันก่อน → ฝ่ายจ่ายเกิดลูกหนี้ (เป็นการเอาเงินไปวางไว้ = Investing)
    payer: { coa: "1310", cashflow: "investing" },
    receiver: { coa: "2310", cashflow: "financing" },
    note: "ออกเงินแทนกันไปก่อน ยังไม่ใช่รายได้หรือค่าใช้จ่ายของใคร",
  },
  loan: {
    label: "กู้ยืมระหว่างกัน",
    payer: { coa: "1310", cashflow: "investing" },
    receiver: { coa: "2310", cashflow: "financing" },
    note: "ฝ่ายให้กู้เกิดลูกหนี้ (Investing) · ฝ่ายกู้เกิดหนี้สิน (Financing)",
  },
  capital: {
    label: "เพิ่มทุน",
    // ลงทุนในกิจการในเครือ — แยกจากพอร์ตหลักทรัพย์ ไม่งั้นต้นทุนเฉลี่ยพอร์ตเพี้ยน
    payer: { coa: "1710", cashflow: "investing" },
    receiver: { coa: "3100", cashflow: "financing" },
    note: "ฝ่ายลงทุนได้เงินลงทุนในบริษัทในเครือ · ฝ่ายรับส่วนของเจ้าของเพิ่ม",
  },
  dividend: {
    label: "ปันผล",
    // จ่ายปันผลลดส่วนของเจ้าของ ไม่ใช่ค่าใช้จ่าย
    payer: { coa: "3200", cashflow: "financing" },
    // ปันผลรับเป็นรายได้จากการดำเนินงาน ตรงกับหมวด inc.dividend ในตารางกฎ
    receiver: { coa: "4410", cashflow: "operating" },
    note: "ฝ่ายจ่ายลดส่วนของเจ้าของ · ฝ่ายรับรับรู้เป็นเงินปันผลรับ",
  },
};

export const INTERCOMPANY_LABEL: Record<IntercompanyNature, string> = Object.fromEntries(
  Object.entries(INTERCOMPANY_RULES).map(([k, v]) => [k, v.label])
) as Record<IntercompanyNature, string>;
