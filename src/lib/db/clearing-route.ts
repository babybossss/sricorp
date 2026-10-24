/**
 * ทางล้างของยอดค้าง (หมวดรับชำระ/จ่ายชำระ) และ PostingInput ของใบล้าง — ใช้ร่วมกันระหว่างหน้าจอ (พรีวิว) กับ server action
 *
 * **ไม่มีคู่บัญชีที่นี่** — รหัสหมวดทางล้างมาจากตารางกฎ (`clearingSubsFor`) และบรรทัดบัญชีมาจาก engine ทั้งหมด
 */
import type { PostingInput } from "@/lib/ledger/types";
import { accrualCheck, clearingSubsFor, findSub, whtCheck, type TxTypeKey } from "@/lib/rules/tx-rules";

export type ClearingRoute = { code: string; typeKey: TxTypeKey };

/**
 * ประเภท/หมวดของใบล้าง — เรียกหลัง `buildClearing()` ผ่านแล้ว (engine ปฏิเสธเคสกำกวมไปก่อน)
 * จึงไม่มีการหยิบตัวแรกเมื่อมีหลายทาง · ไม่ผ่าน = `null`
 */
export function clearingRouteOf(subCode: string, chosen?: string): ClearingRoute | null {
  const sub = findSub(subCode)?.sub;
  const check = sub ? accrualCheck(sub) : undefined;
  if (!sub || !check?.ok) return null;
  const routes = clearingSubsFor(check.account, sub.cashflow);
  const route = chosen ? routes.find((r) => r.code === chosen) : routes.length === 1 ? routes[0] : undefined;
  const type = route ? findSub(route.code)?.type : undefined;
  return route && type ? { code: route.code, typeKey: type.key } : null;
}

/** ทางล้างนี้ถูกหักภาษี ณ ที่จ่ายได้ไหม — ถามตารางกฎ (`whtCheck`) ไม่ไล่ชื่อหมวด */
export function routeAllowsWht(subCode: string, chosen?: string): boolean {
  const route = clearingRouteOf(subCode, chosen);
  const sub = route ? findSub(route.code)?.sub : undefined;
  return !!sub && whtCheck(sub).ok;
}

export type RouteWht = { rate: number; amount: number; certificateNo?: string };

/**
 * `PostingInput` ของใบล้างที่ถูกหักภาษี — **`amount` คือยอดเต็ม (gross) ที่ปิดลูกหนี้เสมอ**
 * (เงินสดสุทธิ = gross − ภาษี engine คำนวณเอง) · ถ้าปิดด้วยยอดสุทธิ ลูกหนี้จะค้างเท่าภาษีตลอดไป
 */
export function routePostingInput(a: {
  sourceSubCode: string;
  chosen?: string;
  ownerId: string;
  amount: number;
  bankAccountId: string;
  assetId?: string;
  contactId?: string;
  attachments: string[];
  memo?: string;
  wht?: RouteWht;
}): PostingInput | null {
  const route = clearingRouteOf(a.sourceSubCode, a.chosen);
  if (!route) return null;
  return {
    typeKey: route.typeKey,
    subCode: route.code,
    amount: a.amount,
    ownerId: a.ownerId,
    bankAccountId: a.bankAccountId,
    assetId: a.assetId,
    contactId: a.contactId,
    memo: a.memo,
    attachments: a.attachments,
    wht: a.wht,
  };
}
