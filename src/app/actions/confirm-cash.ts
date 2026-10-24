"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getAccess } from "@/lib/auth/session";
import { loadReference } from "@/lib/db/reference";
import { makeResolver } from "@/lib/db/resolver";
import {
  PayloadError,
  humanizeDbError,
  readPostResult,
  refuseInactiveOwners,
  toPostEntryPayload,
  type PostEntryPayload,
} from "@/lib/db/post-entry";
import { clearingRefFor } from "@/lib/db/pending-accruals";
import { readPendingAccruals } from "@/lib/db/pending-accruals-server";
import { buildClearing } from "@/lib/ledger/clearing";
import { allLines } from "@/lib/ledger/posting";
import { PostingError, type ClearingInput, type PostingInput } from "@/lib/ledger/types";
import { accrualCheck, clearingSubsFor, findSub } from "@/lib/rules/tx-rules";
import { dmyToIso, parseAmountOrNull } from "@/lib/format";

/**
 * ปุ่ม "ยืนยันเงินเข้า-ออกจริง" → ล้างยอดค้างรับ-ค้างจ่ายลง DB จริง
 *
 * รูปแบบเดียวกับ `postEntry()` และข้อห้ามเดียวกัน:
 *   - **ไม่รับบรรทัดบัญชีและไม่รับประวัติการล้างจาก browser** — รับแค่ id ของรายการต้นทาง + สิ่งที่ผู้ใช้กรอก
 *     (ยอด · วันที่ · บัญชี · สลิป) แล้วอ่านรายการต้นทางและประวัติการล้าง **สดจาก `v_ledger_posted`**
 *     ถ้าเชื่อประวัติจาก browser หน้าที่ค้างเก่าจะบอกว่า "ยังไม่เคยล้าง" แล้วเงินสดเพิ่มสองเท่า
 *   - `buildClearing()` ตัวจริง (ไม่ใช่ `buildClearingDraft()`) บังคับหลักฐานนิติบุคคลครบ
 *   - เขียนผ่าน `fn_post_entry` ตัวเดียว (D-091) ใบล้างหนึ่งใบต่อหนึ่งคำเรียก
 *
 * กันล้างซ้ำ (กดซ้ำ · เน็ตหลุดแล้วลองใหม่ · เปิดสองแท็บ) สามชั้น:
 *   1. `expectedClearedCount` — browser บอกว่าเห็นประวัติกี่ครั้ง ถ้า DB นับไม่เท่ากัน = ปฏิเสธ
 *      (ใบเดิมที่เพิ่งสำเร็จทำให้ลองซ้ำด้วยตัวเลขเดิมไม่ผ่าน)
 *   2. เลขอ้างอิง `<id ต้นทาง>-clr-<n+1>` เก็บใน `source_ref` ของใบล้าง + engine ปฏิเสธยอดเกินยอดค้างคงเหลือ
 *   3. fingerprint ของ `fn_post_entry` — คำขอเหมือนเดิมเป๊ะในหน้าต่างเวลา = replay ไม่ลงใหม่
 *
 * หลายแถวในคำขอเดียว: **ตรวจผ่าน engine ครบทุกแถวก่อน** ถ้าแถวใดไม่ผ่านจะไม่เขียนอะไรเลย แต่ตอนเขียน
 * เป็นหนึ่ง RPC ต่อแถว (RPC หนึ่งใบรับได้ประเภทรายการเดียว) → ถ้า DB ล้มกลางทางบางแถวอาจสำเร็จแล้ว
 * ผลลัพธ์จึงรายงานทีละแถว และหน้าจอโหลดยอดค้างใหม่จาก DB เสมอ
 */

export type ConfirmCashItem = {
  /** id ของรายการต้นทาง (transaction ที่ตั้งค้างไว้) */
  sourceId: string;
  /** ยอดที่ยืนยันครั้งนี้ — ข้อความดิบตามที่ผู้ใช้พิมพ์ */
  amount: string;
  /** วันที่เงินเข้า/ออกจริง วว/ดด/ปปปป */
  date: string;
  bankAccountId: string;
  /** path ของสลิปที่อัปโหลดแล้ว */
  slips: string[];
  clearingSubCode?: string;
  /** จำนวนการล้างที่ browser เห็นอยู่ตอนกด — ต้องตรงกับ DB */
  expectedClearedCount: number;
};

export type ConfirmCashResult =
  | { sourceId: string; ok: true; transactionId: string; replayed: boolean }
  | { sourceId: string; ok: false; message: string };

export type ConfirmCashOutcome =
  | { ok: true; results: ConfirmCashResult[] }
  | { ok: false; message: string; results: ConfirmCashResult[] };

const refuse = (message: string): ConfirmCashOutcome => ({ ok: false, message, results: [] });

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function confirmCash(req: { items: ConfirmCashItem[] }): Promise<ConfirmCashOutcome> {
  const access = await getAccess();
  if (!access.user) return refuse("เข้าสู่ระบบหมดอายุ — ให้เข้าสู่ระบบใหม่แล้วยืนยันอีกครั้ง");
  if (access.error) return refuse(`ตรวจสิทธิ์ไม่สำเร็จ ยังไม่ได้บันทึกอะไร (${access.error})`);
  if (!access.permissions.has("ledger.approve")) {
    return refuse("บัญชีนี้ลงสมุดบัญชีโดยตรงไม่ได้ — การยืนยันเงินเข้า-ออกต้องมีสิทธิ์อนุมัติเข้าสมุด");
  }

  // ---- ข้อมูลที่ส่งมาไม่ครบ = ปฏิเสธ ไม่เดา ----
  const items = req?.items;
  if (!Array.isArray(items) || items.length === 0) return refuse("ไม่ได้เลือกรายการที่จะยืนยัน — ยังไม่ได้บันทึกอะไร");
  const seen = new Set<string>();
  for (const it of items) {
    if (!it || typeof it.sourceId !== "string" || !UUID.test(it.sourceId)) {
      return refuse("ระบุรายการต้นทางไม่ถูกต้อง — ยังไม่ได้บันทึกอะไร");
    }
    const key = it.sourceId.toLowerCase();
    if (seen.has(key)) return refuse("มีรายการเดียวกันซ้ำในคำขอเดียว — ยืนยันซ้ำจะทำให้เงินสดเพิ่มสองเท่า ยังไม่ได้บันทึกอะไร");
    seen.add(key);
    if (!Number.isInteger(it.expectedClearedCount) || it.expectedClearedCount < 0) {
      return refuse("ไม่ได้ระบุจำนวนครั้งที่เคยยืนยันของรายการนี้ — โหลดหน้าใหม่แล้วลองอีกครั้ง ยังไม่ได้บันทึกอะไร");
    }
  }

  const refState = await loadReference();
  if (!refState.ok) return refuse(`โหลดข้อมูลผู้ถือและบัญชีจากฐานข้อมูลไม่ได้ ยังไม่ได้บันทึกอะไร (${refState.error})`);
  const resolver = makeResolver(refState.ref);

  let supabase;
  try {
    supabase = await createClient();
  } catch (e) {
    return refuse(e instanceof Error ? e.message : String(e));
  }

  // ---- ตรวจทุกแถวก่อนเขียนแถวไหน ----
  const prepared: { sourceId: string; payload: PostEntryPayload }[] = [];
  const problems: string[] = [];
  for (const it of items) {
    const sourceId = it.sourceId.toLowerCase();
    const read = await readPendingAccruals(supabase, refState.ref.coaCodeById, sourceId);
    if (!read.ok) return refuse(`${read.error} — ยังไม่ได้บันทึกอะไร`);
    const src = read.items.find((p) => p.id.toLowerCase() === sourceId);
    const label = src?.memo ?? sourceId;
    if (!src) {
      problems.push(`${label} — ไม่พบยอดค้างของรายการนี้ (อาจถูกกลับรายการ หรือไม่ใช่รายการค้างรับ-ค้างจ่าย)`);
      continue;
    }
    if (src.postedClearings.length !== it.expectedClearedCount) {
      problems.push(
        `${label} — ข้อมูลเปลี่ยนไปแล้ว (ฐานข้อมูลมีการยืนยันแล้ว ${src.postedClearings.length} ครั้ง แต่หน้าจอเห็น ${it.expectedClearedCount} ครั้ง) ` +
          "รายการนี้อาจถูกยืนยันไปแล้ว — โหลดหน้าใหม่ตรวจก่อน ห้ามกดซ้ำ"
      );
      continue;
    }

    const dateIso = dmyToIso(String(it.date ?? ""));
    if (!dateIso) {
      problems.push(`${label} — วันที่เงินเข้า/ออกจริงอ่านไม่ออก ให้พิมพ์เป็น วว/ดด/ปปปป เป็นปี ค.ศ.`);
      continue;
    }

    const attachments = [...new Set([...src.attachments, ...(Array.isArray(it.slips) ? it.slips : [])])];
    const input: ClearingInput = {
      sourceId,
      typeKey: src.typeKey,
      subCode: src.subCode,
      ownerId: src.ownerId,
      accruedAmount: src.accruedAmount,
      // ประวัติจาก DB เท่านั้น — ห้ามใช้ที่ browser ส่งมา
      postedClearings: src.postedClearings,
      // อ่านไม่ออก = NaN ให้ engine ปฏิเสธ ไม่ปัดเป็น 0
      amount: parseAmountOrNull(String(it.amount ?? "")) ?? Number.NaN,
      bankAccountId: it.bankAccountId,
      date: dateIso,
      assetId: src.assetId ?? undefined,
      contactId: src.contactId ?? undefined,
      attachments,
      clearingRef: clearingRefFor(sourceId, src.postedClearings.length + 1),
      clearingSubCode: it.clearingSubCode || undefined,
    };

    try {
      const result = buildClearing(input, resolver);
      const route = clearingRouteOf(src.subCode, it.clearingSubCode);
      const cash = allLines(result).find((l) => l.bankAccountId);
      const post: PostingInput = {
        typeKey: route.typeKey,
        subCode: route.code,
        amount: cash ? cash.debit || cash.credit : input.amount,
        ownerId: src.ownerId,
        bankAccountId: it.bankAccountId,
        assetId: src.assetId ?? undefined,
        contactId: src.contactId ?? undefined,
        memo: `ยืนยันเงินเข้า-ออกจริง · ${src.memo ?? findSub(src.subCode)?.sub.label ?? src.subCode}`,
        attachments,
      };
      const payload = toPostEntryPayload(post, result, {
        docDate: dateIso,
        cashDate: dateIso,
        sourceRef: input.clearingRef,
      });
      prepared.push({ sourceId, payload });
    } catch (e) {
      if (e instanceof PostingError || e instanceof PayloadError) {
        problems.push(`${label} — ${e.message}`);
        continue;
      }
      console.error("confirmCash: unexpected error while building the clearing", e);
      problems.push(`${label} — ระบบประกอบรายการบัญชีไม่สำเร็จด้วยเหตุที่ไม่คาดคิด`);
    }
  }
  if (problems.length) return refuse(`${problems.join("\n")}\nยังไม่ได้บันทึกอะไร`);

  for (const p of prepared) {
    const refused = refuseInactiveOwners(p.payload, refState.ref.owners);
    if (refused) return refuse(refused);
  }

  // ---- เขียนทีละแถว ----
  const results: ConfirmCashResult[] = [];
  for (const p of prepared) {
    const { data, error } = await supabase.rpc("fn_post_entry", { p_payload: p.payload });
    if (error) {
      results.push({ sourceId: p.sourceId, ok: false, message: humanizeDbError(error) });
      continue;
    }
    const read = readPostResult(data, p.payload.transactions.length);
    results.push(
      read.ok
        ? { sourceId: p.sourceId, ok: true, transactionId: read.transactionIds[0], replayed: read.replayed }
        : { sourceId: p.sourceId, ok: false, message: read.message }
    );
  }

  revalidatePath("/ledger");
  revalidatePath("/dashboard");
  const failed = results.filter((r) => !r.ok);
  if (failed.length) {
    return {
      ok: false,
      message:
        results.some((r) => r.ok)
          ? "บางรายการบันทึกแล้ว บางรายการไม่สำเร็จ — ดูผลทีละรายการ และโหลดหน้าใหม่ก่อนลองอีกครั้ง"
          : "ไม่มีรายการใดถูกบันทึก",
      results,
    };
  }
  return { ok: true, results };
}

/**
 * ประเภท/หมวดของใบล้าง — อ่านจากตารางกฎ (`clearingSubsFor`) ไม่เขียนรหัสหมวดเอง
 * เรียกหลัง `buildClearing()` ผ่านแล้วเท่านั้น (engine ปฏิเสธเคสกำกวมไปก่อนแล้ว) จึงไม่มีการหยิบตัวแรกเมื่อมีหลายทาง
 */
function clearingRouteOf(subCode: string, chosen?: string) {
  const sub = findSub(subCode)?.sub;
  const check = sub ? accrualCheck(sub) : undefined;
  if (!sub || !check?.ok) throw new PayloadError(`ไม่พบทางล้างของหมวด ${subCode}`);
  const routes = clearingSubsFor(check.account, sub.cashflow);
  const route = chosen ? routes.find((r) => r.code === chosen) : routes.length === 1 ? routes[0] : undefined;
  if (!route) throw new PayloadError(`เลือกทางล้างของหมวด ${subCode} ไม่ได้`);
  const type = findSub(route.code)?.type;
  if (!type) throw new PayloadError(`ไม่พบประเภทของทางล้าง ${route.code}`);
  return { code: route.code, typeKey: type.key };
}
