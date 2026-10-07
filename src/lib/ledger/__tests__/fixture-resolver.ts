/**
 * resolver ขนาดเล็กสำหรับเทสต์ engine — **ห้าม import จาก `@/lib/mock`**
 *
 * เทสต์ของ engine ต้องไม่ผูกกับข้อมูลจำลองของแอป ไม่งั้นวันที่ใครแก้
 * `src/lib/mock/banks.ts` (เช่น ย้ายบัญชีไปอยู่ชื่อคนอื่น) เทสต์บัญชีจะพัง
 * ทั้งที่กฎบัญชีไม่ได้เปลี่ยนอะไรเลย — และกลับกัน เทสต์จะผ่านได้ด้วยเหตุผลผิดๆ
 *
 * ชุดนี้มีเท่าที่เคสในเทสต์ต้องใช้:
 * - `corp` นิติบุคคล (บังคับเอกสาร) · `thanakorn` / `thanawin` บุคคล
 * - `family` มุมมองรวม เลือกเป็นผู้ถือไม่ได้
 * - `b4` + `b4b` ของคนเดียวกัน (โอนในผู้ถือเดียวกัน) · `b1` corp · `b5` อีกคน
 */

import type { BankInfo, LedgerResolver, OwnerInfo } from "../types";

const OWNERS: OwnerInfo[] = [
  { id: "family", name: "SRI Family (รวมทุกชื่อ)", policy: "corporate_strict", selectableAsHolder: false },
  { id: "corp", name: "SRI Corporation", policy: "corporate_strict", selectableAsHolder: true },
  { id: "thanakorn", name: "ธนากร", policy: "personal_flexible", selectableAsHolder: true },
  { id: "thanawin", name: "ธนวินท์", policy: "personal_flexible", selectableAsHolder: true },
];

const BANK_ACCOUNTS: BankInfo[] = [
  { id: "b1", name: "SRI - SCB", ownerId: "corp" },
  { id: "b4", name: "ธนากร - BBL", ownerId: "thanakorn" },
  { id: "b4b", name: "ธนากร - SCB", ownerId: "thanakorn" },
  { id: "b5", name: "ธนวินท์ - KBANK", ownerId: "thanawin" },
];

/** resolver ปกติที่เคสส่วนใหญ่ใช้ */
export const TEST_RESOLVER: LedgerResolver = {
  owner: (id) => OWNERS.find((o) => o.id === id) ?? null,
  bankAccount: (id) => BANK_ACCOUNTS.find((b) => b.id === id) ?? null,
};

/**
 * resolver ที่ "ไม่รู้จักใครเลย" — ใช้ยืนยันว่า engine ปฏิเสธด้วย PostingError
 * ไม่ใช่ crash และไม่ใช่เดาเป็นผู้ถือ/บัญชีอื่น
 */
export const EMPTY_RESOLVER: LedgerResolver = {
  owner: () => null,
  bankAccount: () => null,
};

/** รู้จักผู้ถือ แต่ไม่รู้จักบัญชีธนาคารเลย — แยกสองสาเหตุออกจากกันในเทสต์ */
export const NO_BANK_RESOLVER: LedgerResolver = {
  owner: TEST_RESOLVER.owner,
  bankAccount: () => null,
};
