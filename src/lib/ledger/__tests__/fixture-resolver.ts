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
 * - **บัญชีที่ปิดใช้งานแล้วอย่างน้อยหนึ่งตัวต่อผู้ถือ** (`b4c` · `b6` · `b2`)
 *   เพื่อให้เคสเทสต์แตะได้ทั้งเส้นทางเปิดและปิด (D-092) — ถ้าไม่มีบัญชีที่ปิดในชุดนี้
 *   เทสต์จะผ่านได้ด้วยเหตุผลผิดๆ คือ "ไม่เคยมีบัญชีปิดให้ชน"
 */

import type { BankInfo, LedgerResolver, OwnerInfo } from "../types";

const OWNERS: OwnerInfo[] = [
  { id: "family", name: "SRI Family (รวมทุกชื่อ)", policy: "corporate_strict", selectableAsHolder: false },
  { id: "corp", name: "SRI Corporation", policy: "corporate_strict", selectableAsHolder: true },
  { id: "thanakorn", name: "ธนากร", policy: "personal_flexible", selectableAsHolder: true },
  { id: "thanawin", name: "ธนวินท์", policy: "personal_flexible", selectableAsHolder: true },
];

const BANK_ACCOUNTS: BankInfo[] = [
  { id: "b1", name: "SRI - SCB", ownerId: "corp", isActive: true },
  { id: "b2", name: "SRI - BBL (ปิดแล้ว)", ownerId: "corp", isActive: false },
  { id: "b4", name: "ธนากร - BBL", ownerId: "thanakorn", isActive: true },
  { id: "b4b", name: "ธนากร - SCB", ownerId: "thanakorn", isActive: true },
  { id: "b4c", name: "ธนากร - TTB (ปิดแล้ว)", ownerId: "thanakorn", isActive: false },
  { id: "b5", name: "ธนวินท์ - KBANK", ownerId: "thanawin", isActive: true },
  { id: "b6", name: "ธนวินท์ - BBL (ปิดแล้ว)", ownerId: "thanawin", isActive: false },
];

/** บัญชีที่ปิดใช้งานแล้ว — อ้างชื่อในข้อความ error ได้โดยไม่ต้องพิมพ์ซ้ำในเทสต์ */
export const CLOSED = {
  corp: BANK_ACCOUNTS.find((b) => b.id === "b2")!,
  thanakorn: BANK_ACCOUNTS.find((b) => b.id === "b4c")!,
  thanawin: BANK_ACCOUNTS.find((b) => b.id === "b6")!,
};

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

/**
 * resolver ที่ **คืนข้อมูลบัญชีไม่ครบ** — ไม่มีฟิลด์ `isActive` เลย
 *
 * จำลอง resolver รุ่นเก่า/ตัวที่อ่านจากแหล่งที่ยังไม่มีคอลัมน์นี้ (เช่น view ที่ลืม select)
 * engine ต้อง **ไม่** ตีความว่า "ไม่บอก = เปิดใช้งาน" เพราะถ้าตีความแบบนั้น
 * วันที่ resolver ตัวใดตัวหนึ่งลืมส่งฟิลด์นี้ การกันบัญชีปิดจะหายไปเงียบๆ ทั้งระบบ
 * (บทเรียน mace-windu ข้อ 1 และ ข้อ 3 — ข้อมูลไม่ครบต้องปฏิเสธ ไม่ใช่เดา)
 *
 * `as BankInfo` คือจุดที่ตั้งใจโกงชนิดข้อมูล เพราะ TypeScript กันเคสนี้ให้แล้ว
 * แต่ resolver ตัวจริงรับข้อมูลจากฐานข้อมูลตอน runtime ซึ่ง TypeScript กันไม่ถึง
 */
export const MISSING_ACTIVE_FLAG_RESOLVER: LedgerResolver = {
  owner: TEST_RESOLVER.owner,
  bankAccount: (id) => {
    const b = BANK_ACCOUNTS.find((x) => x.id === id);
    if (!b) return null;
    return { id: b.id, name: b.name, ownerId: b.ownerId } as BankInfo;
  },
};
