/**
 * ตัวต่อระหว่างหน้า "ยืนยันรับ-จ่าย" กับ `lib/ledger/clearing.ts`
 *
 * **ไฟล์นี้ไม่มีกติกาบัญชี** — ประกอบ `ClearingInput` แล้วถาม engine เท่านั้น
 * (แทน `confirm-gate.ts` เดิมที่เขียนกฎ "ต้องมีบัญชี/ต้องเป็นของผู้ถือ" ไว้ในหน้าจอ
 *  กฎเดียวกันอยู่สองที่ = สิ่งที่ผู้ใช้เห็นกับสิ่งที่ระบบบันทึกแยกจากกันได้)
 *
 * สองคำถามที่ต่างกัน — **อย่าสลับ**
 * - `checkRow().preview`     → `buildClearingDraft()` โชว์บรรทัดบัญชีให้คนอ่าน ยังไม่บังคับหลักฐานนิติบุคคล
 * - `checkRow().canConfirm`  → `buildClearing()` ตัวจริง ตัดสินว่ากดยืนยันได้ไหม
 * - `confirmRows()`          → `buildClearing()` ตัวจริงอีกรอบตอนกดจริง ไม่เชื่อผลที่คำนวณไว้ตอนวาดหน้า
 *
 * สิ่งที่ห้ามทำในไฟล์นี้ (เคยพลาด/เสี่ยงพลาด):
 * - ห้ามสรุปยอด "เคยล้างแล้ว" ส่งให้ engine เอง — ส่ง `postedClearings` ตามประวัติจริงเท่านั้น
 * - ห้ามหยิบทางล้างตัวแรกเมื่อมีหลายทาง — ส่ง `clearingSubCode` เฉพาะที่ผู้ใช้เลือก
 * - ห้ามคำนวณยอดค้างคงเหลือ — engine เป็นคนบอก (ในข้อความ `summary` / `PostingError`)
 * - ห้ามละฟิลด์ที่ขาดด้วยค่าเดา (`?? []`, `?? 0`) — ปล่อยให้ engine ปฏิเสธ
 */

import { buildClearing, buildClearingDraft } from "@/lib/ledger/clearing";
import { allLines } from "@/lib/ledger/posting";
import {
  PostingError,
  type ClearingInput,
  type LedgerResolver,
  type PostedClearing,
  type PostingResult,
} from "@/lib/ledger/types";
import { coa, isCashAccount } from "@/lib/rules/coa";
import { accrualCheck, clearingSubsFor, findSub, type CashDirection } from "@/lib/rules/tx-rules";
import { money, parseAmountOrNull, signedMoney } from "@/lib/format";
import type { PendingCashRow } from "@/lib/mock/ledger";

/** สิ่งที่ผู้ใช้กรอกต่อแถว — ทุกช่องเป็นข้อความดิบ ให้ engine เป็นคนตัดสินว่าใช้ได้ไหม */
export type RowDraft = {
  amount: string;
  date: string;
  /** บัญชีที่เลือก — ใช้เฉพาะแถวที่ตัวรายการยังไม่มีบัญชี */
  bankAccountId: string;
  /** สลิปที่แนบตอนยืนยัน */
  slips: string[];
  /** ทางล้างที่ผู้ใช้เลือกเอง — ว่าง = ยังไม่เลือก (ห้ามเติมให้) */
  clearingSubCode: string;
};

/** ประวัติการยืนยันที่ post แล้ว แยกตามรหัสรายการ */
export type PostedMap = Record<string, PostedClearing[]>;

export const initialDraft = (row: PendingCashRow): RowDraft => ({
  amount: row.actual,
  date: row.date,
  bankAccountId: "",
  slips: [],
  clearingSubCode: "",
});

/** ประวัติเริ่มต้นมาจากตัวรายการ — ต่อ Supabase แล้วมาจากตารางรายการที่ post แล้วแทน */
export const initialPosted = (rows: PendingCashRow[]): PostedMap =>
  Object.fromEntries(rows.map((r) => [r.id, r.postedClearings]));

/**
 * ประวัติของแถว — ถ้าไม่มีทั้งในประวัติและในตัวรายการ คืน `undefined` ตรงๆ
 * (ไม่ใช่ `[]`) เพื่อให้ engine ปฏิเสธ ถ้าเดาว่าไม่เคยยืนยัน การกดซ้ำจะทำให้เงินสดเพิ่มสองเท่า
 */
export function historyOf(row: PendingCashRow, posted: PostedMap): PostedClearing[] {
  return (posted[row.id] ?? row.postedClearings) as PostedClearing[];
}

/**
 * เลขอ้างอิงของการยืนยันครั้งนี้ — เรียงตามประวัติ จึงกดซ้ำบนประวัติเดิมได้เลขเดิม
 * แล้ว engine จับซ้ำด้วยเลขอ้างอิงอีกชั้นหนึ่ง นอกเหนือจากยอดค้างคงเหลือ
 */
export const clearingRefOf = (row: PendingCashRow, posted: PostedMap): string =>
  `${row.id}-clr-${(historyOf(row, posted)?.length ?? 0) + 1}`;

/** ประกอบ input ของ engine — ทุกฟิลด์มาจากตัวรายการหรือสิ่งที่ผู้ใช้กรอก ไม่มีค่าที่หน้าจอคิดเอง */
export function clearingInputOf(row: PendingCashRow, draft: RowDraft, posted: PostedMap): ClearingInput {
  return {
    sourceId: row.id,
    typeKey: row.typeKey,
    subCode: row.subCode,
    ownerId: row.ownerId,
    accruedAmount: row.accruedAmount,
    postedClearings: historyOf(row, posted),
    // อ่านไม่ออก = NaN ให้ engine ปฏิเสธว่า "ต้องเป็นตัวเลข" ไม่ใช่ปัดเป็น 0
    amount: parseAmountOrNull(draft.amount) ?? Number.NaN,
    // บัญชีในตัวรายการชนะเสมอ — ช่องเลือกบัญชีมีไว้ให้แถวที่ยังไม่เคยระบุบัญชีเท่านั้น
    bankAccountId: row.bankAccountId || draft.bankAccountId,
    date: draft.date,
    assetId: row.assetId,
    contactId: row.contactId,
    // หลักฐานเดิมของรายการ + สลิปที่แนบตอนยืนยัน — ฝั่งนิติบุคคล engine ใช้ตัดสิน
    attachments: [...(row.attachments ?? []), ...draft.slips],
    clearingRef: clearingRefOf(row, posted),
    // ไม่เติมค่าเริ่มต้นให้ — ถ้ามีหลายทางล้างแล้วไม่เลือก engine ต้องปฏิเสธ
    clearingSubCode: draft.clearingSubCode || undefined,
  };
}

/**
 * รับหรือจ่าย — อ่านจากตารางกฎ (`cash`) ไม่ใช่จากเครื่องหมายของยอดหรือรหัสหมวด
 *
 * เขียนเป็น `switch` ครบเคสโดยตั้งใจ (แพทเทิร์นเดียวกับ `bankDirectionLabel` /
 * `movesCash`) · ของเดิมเป็น ternary ที่ **ยุบ `both` กับ `none` เป็น `null`**
 * ซึ่งทำให้ "โอนระหว่างบัญชี" "ไม่มีเงินเคลื่อน" และ "ไม่รู้จักหมวดนี้"
 * กลายเป็นคำตอบเดียวกัน แล้วหน้าจอแสดงยอด/ป้ายบัญชีของกรณีที่ไม่ใช่
 *
 * วันนี้หมวด `none` ยังมาไม่ถึงเพราะ `accrualCheck` ตัดก่อน — **แต่พึ่งลำดับ
 * การตรวจไม่ได้** (D-102: ค่าใหม่ใน union ตกไปทาง fallback เงียบๆ)
 *
 * `null` สงวนไว้สำหรับ **หมวดที่ไม่มีในตารางกฎ** เท่านั้น
 */
export function directionOf(row: Pick<PendingCashRow, "subCode">): CashDirection | null {
  const sub = findSub(row.subCode)?.sub;
  if (!sub) return null;
  switch (sub.cash) {
    case "in":
      return "in";
    case "out":
      return "out";
    case "both":
      return "both";
    case "none":
      return "none";
  }
}

/**
 * ข้อความของช่อง "ยอดค้าง" — **ครบทั้งห้าคำตอบของ `directionOf`**
 *
 * ของเดิมอยู่ใน JSX ของ `confirm-tab.tsx` เป็น ternary สองชั้น
 *   `dir === "in" ? signedMoney(+) : dir === "out" ? money(−) : money(+)`
 * → `"none"` · `"both"` · `null` ตกทาง else แล้ว **แสดงเป็นยอดบวก** คือ
 *   อ่านว่า "เงินจะเข้า" ทั้งที่ไม่มีเงินเคลื่อน / เข้าออกพร้อมกัน / ไม่รู้จักหมวดนี้
 *   (ขัดกับคอมเมนต์ข้างๆ ที่บอกว่า `dir` ตอบครบทั้งสี่ค่าแล้ว)
 *
 * ย้ายมาเป็นฟังก์ชันที่เทสต์เรียกได้โดยตั้งใจ: ตรรกะที่ฝังใน JSX
 * ไม่มีเทสต์ไหนแตะได้ (vitest ของโปรเจกต์นี้รันแต่ `.test.ts` บน environment node)
 * → mutation ที่คืน ternary กลับไปจะไม่มีใครจับได้
 *
 * ตัวเลขติดลบใช้วงเล็บ · เงินเข้าใส่เครื่องหมายบวก (กติกา UI ของโปรเจกต์)
 * `both` / `none` / `null` **ห้ามแสดงเป็นยอดบวกเฉยๆ** เพราะทั้งสามไม่ใช่เงินเข้า
 * และแถวพวกนี้ยืนยันไม่ได้อยู่แล้ว — ข้อความต้องบอกเหตุเป็นคำ ไม่ใช่ปล่อยให้เดาจากตัวเลข
 */
export function accruedAmountText(dir: CashDirection | null, amount: number): string {
  switch (dir) {
    case "in":
      return signedMoney(amount);
    case "out":
      return money(-amount);
    case "both":
      // โอนระหว่างบัญชีตัวเอง — เข้าหนึ่งออกหนึ่ง ไม่มีทิศเดียวให้ใส่เครื่องหมาย
      return `± ${money(amount)}`;
    case "none":
      return `${money(amount)} (ไม่มีเงินเคลื่อน)`;
    case null:
      return `${money(amount)} (หมวดนี้ไม่อยู่ในตารางกฎ)`;
  }
}

/**
 * ทางล้างที่ตารางกฎมีให้ — ใช้สร้างช่องเลือกเมื่อมีมากกว่าหนึ่งทาง
 * คืนรายการว่างถ้าตารางกฎไม่มีทาง (engine จะปฏิเสธเองพร้อมเหตุผล ไม่ต้องดักที่นี่)
 */
export function clearingChoicesOf(row: Pick<PendingCashRow, "subCode">): { code: string; label: string }[] {
  const sub = findSub(row.subCode)?.sub;
  if (!sub) return [];
  const check = accrualCheck(sub);
  if (!check.ok) return [];
  return clearingSubsFor(check.account, sub.cashflow).map((r) => ({ code: r.code, label: r.label }));
}

export type ClearingPreviewLine = { coaCode: string; label: string; debit: number; credit: number; memo?: string };

export type RowCheck = {
  /** บรรทัดบัญชีสำหรับ "ให้คนอ่าน" — `buildClearingDraft()` · **ห้ามใช้ตัดสินว่ายืนยันได้ไหม** */
  preview:
    | { ok: true; lines: ClearingPreviewLine[]; summary: string[] }
    | { ok: false; reason: string };
  /** ยืนยันได้ไหม — `buildClearing()` ตัวจริง ซึ่งบังคับหลักฐานของนิติบุคคลด้วย */
  canConfirm: boolean;
  /** ข้อความจาก `PostingError` ตรงๆ ไม่แต่งเอง */
  blockedReason: string | null;
};

/** รันฟังก์ชันของ engine — `PostingError` กลายเป็นข้อความ · ข้อผิดพลาดอื่นปล่อยขึ้นไปให้เห็น */
function attempt<T>(fn: () => T): { ok: true; value: T } | { ok: false; reason: string } {
  try {
    return { ok: true, value: fn() };
  } catch (e) {
    if (e instanceof PostingError) return { ok: false, reason: e.message };
    throw e;
  }
}

export function checkRow(
  row: PendingCashRow,
  draft: RowDraft,
  posted: PostedMap,
  resolve: LedgerResolver
): RowCheck {
  const input = clearingInputOf(row, draft, posted);
  const drafted = attempt(() => buildClearingDraft(input, resolve));
  const real = attempt(() => buildClearing(input, resolve));
  return {
    preview: drafted.ok
      ? {
          ok: true,
          lines: allLines(drafted.value).map((l) => ({
            coaCode: l.coaCode,
            label: coa(l.coaCode).nameTh,
            debit: l.debit,
            credit: l.credit,
            memo: l.memo,
          })),
          summary: drafted.value.summary,
        }
      : { ok: false, reason: drafted.reason },
    canConfirm: real.ok,
    blockedReason: real.ok ? null : real.reason,
  };
}

export type ConfirmedRow = {
  row: PendingCashRow;
  /** ผลของ engine ที่พร้อมบันทึก — ตอนต่อ Supabase เขียนก้อนนี้ลง DB ไม่ใช่ค่าที่ฟอร์มรู้จัก */
  result: PostingResult;
};

export type ConfirmOutcome =
  | { ok: true; confirmed: ConfirmedRow[]; posted: PostedMap }
  | { ok: false; failures: { row: PendingCashRow; reason: string }[]; posted: PostedMap };

/**
 * ยืนยันหลายแถวพร้อมกัน — **ทั้งหมดหรือไม่มีเลย**
 *
 * แต่ละแถวต้องผ่าน `buildClearing()` ตัวจริงก่อน ถ้าแถวใดไม่ผ่านจะไม่บันทึกอะไรเลย
 * (ไม่ปล่อยให้เงินเข้า 2 จาก 3 รายการเงียบๆ) คืนประวัติใหม่ที่ **ต่อจากประวัติที่ส่งเข้ามา**
 * ยอดที่ลงประวัติอ่านจากบรรทัดเงินสดที่ engine สร้าง ไม่ใช่ตัวเลขที่ผู้ใช้พิมพ์
 * (engine ปัดสองตำแหน่ง ถ้าเก็บตัวเลขดิบ ประวัติจะเพี้ยนจากที่ลงบัญชีจริง)
 */
export function confirmRows(
  rows: PendingCashRow[],
  drafts: Record<string, RowDraft>,
  posted: PostedMap,
  resolve: LedgerResolver
): ConfirmOutcome {
  // ไล่ทีละแถวบนประวัติที่ต่อสะสมไป — แถวซ้ำในชุดเดียวกันจึงเห็นการยืนยันของตัวเองก่อนหน้า
  // และถูก engine ปฏิเสธว่าล้างเกิน/ยืนยันซ้ำ ไม่ใช่ผ่านสองรอบเพราะต่างก็เห็นประวัติเก่า
  const next: PostedMap = { ...posted };
  const confirmed: ConfirmedRow[] = [];
  const failures: { row: PendingCashRow; reason: string }[] = [];

  for (const row of rows) {
    const input = clearingInputOf(row, drafts[row.id] ?? initialDraft(row), next);
    const built = attempt(() => buildClearing(input, resolve));
    if (!built.ok) {
      failures.push({ row, reason: built.reason });
      continue;
    }
    // ยอดลงประวัติอ่านจากบรรทัดเงินสดที่ engine สร้าง ไม่ใช่ตัวเลขที่ผู้ใช้พิมพ์
    const cash = allLines(built.value).find((l) => isCashAccount(l.coaCode));
    if (!cash) throw new Error("engine ไม่คืนบรรทัดเงินสดของการยืนยัน");
    next[row.id] = [...historyOf(row, next), { id: input.clearingRef ?? "", amount: cash.debit || cash.credit }];
    confirmed.push({ row, result: built.value });
  }

  // ทั้งหมดหรือไม่มีเลย — แถวใดไม่ผ่าน ไม่คืนประวัติใหม่ของแถวไหนทั้งสิ้น
  if (failures.length > 0 || confirmed.length === 0) return { ok: false, failures, posted };
  return { ok: true, confirmed, posted: next };
}
