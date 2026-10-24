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
import { clearedOutsideEntry, clearingRefFor } from "@/lib/db/pending-accruals";
import { readPendingAccruals } from "@/lib/db/pending-accruals-server";
import { routePostingInput } from "@/lib/db/clearing-route";
import { buildClearing } from "@/lib/ledger/clearing";
import { buildPosting } from "@/lib/ledger/posting";
import { PostingError, type ClearingInput } from "@/lib/ledger/types";
import { accrualCheck, findSub } from "@/lib/rules/tx-rules";
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
  /**
   * ผู้จ่ายหักภาษี ณ ที่จ่ายไว้ (ข้อความดิบตามที่ผู้ใช้พิมพ์จากใบรับรอง)
   * `amount` ของรายการต้องเป็น **ยอดเต็มก่อนหักภาษี** — ลูกหนี้ปิดด้วยยอดเต็ม = เงินสดสุทธิ + ภาษีที่ถูกหัก
   */
  wht?: { rate: string; amount: string; certificateNo?: string };
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
    const read = await readPendingAccruals(supabase, refState.ref.coaCodeById);
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

    // ลูกหนี้/เจ้าหนี้ของใบนี้เหลือศูนย์แล้ว — ไม่ว่าจะถูกล้างด้วยวิธีไหน (แท็บนี้ ลงใบรับชำระเอง ตัดหนี้สูญ)
    // กดซ้ำจะทำให้ลูกหนี้ติดลบและเงินสดเพิ่มที่ไม่เคยเข้าบัญชี → ปฏิเสธก่อนถึง engine
    if (!(src.outstanding > 0)) {
      problems.push(
        `${label} — ลูกหนี้/เจ้าหนี้ของรายการนี้ปิดครบแล้ว` +
          (src.clearedOutside > 0 ? ` (รวม ${src.clearedOutside.toLocaleString("en-US")} บาทที่ถูกลดด้วยการลงรายการเอง)` : "") +
          " — ยืนยันซ้ำจะทำให้เงินสดเพิ่มสองเท่า"
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
      // ประวัติจาก DB เท่านั้น — ห้ามใช้ที่ browser ส่งมา · รวมยอดที่ถูกลดนอกแท็บ (อนุมานจากยอดคงเหลือจริงของบัญชีพัก)
      postedClearings: [...src.postedClearings, ...clearedOutsideEntry(src)],
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
      // ตรวจยอดค้างคงเหลือ · เลขอ้างอิง · มิติบังคับ · หลักฐานนิติบุคคล — ด่านของการล้างอยู่ที่ engine ตัวนี้เสมอ
      const cleared = buildClearing(input, resolver);

      let wht: { rate: number; amount: number; certificateNo?: string } | undefined;
      if (it.wht !== undefined) {
        const rate = parseAmountOrNull(String(it.wht?.rate ?? ""));
        const withheld = parseAmountOrNull(String(it.wht?.amount ?? ""));
        if (rate === null || withheld === null) {
          throw new PostingError("ระบุว่าถูกหักภาษี ณ ที่จ่ายแต่อัตราหรือยอดภาษีอ่านไม่ออก — ต้องกรอกทั้งสองช่องจากใบรับรอง");
        }
        wht = { rate, amount: withheld, certificateNo: it.wht?.certificateNo?.trim() || undefined };
      }

      const post = routePostingInput({
        sourceSubCode: src.subCode,
        chosen: it.clearingSubCode,
        ownerId: src.ownerId,
        // ยอดเต็มที่ปิดลูกหนี้ — ไม่ใช่เงินที่เข้าบัญชี
        amount: input.amount,
        bankAccountId: it.bankAccountId,
        assetId: src.assetId ?? undefined,
        contactId: src.contactId ?? undefined,
        memo: `ยืนยันเงินเข้า-ออกจริง · ${src.memo ?? findSub(src.subCode)?.sub.label ?? src.subCode}`,
        attachments,
        wht,
      });
      if (!post) throw new PayloadError(`ไม่พบทางล้างของหมวด ${src.subCode}`);

      // ถูกหักภาษี → บรรทัดเงินสดแตกเป็น เงินสดสุทธิ + 1800 ซึ่ง buildClearing ไม่รู้จัก จึงให้ buildPosting
      // ของทางล้างประกอบบรรทัดแทน (engine ตัวจริงเช่นกัน ไม่ใช่หน้าจอ) แล้วเช็คว่า **ปิดบัญชีพักด้วยยอดเต็ม**
      // เท่ากับที่ buildClearing อนุมัติไว้ — ปิดด้วยยอดสุทธิ ลูกหนี้จะค้างเท่าภาษีตลอดไป
      const result = wht ? buildPosting(post, resolver) : cleared;
      if (wht) {
        const account = accrualCheck(findSub(src.subCode)!.sub);
        const closed = result.transactions
          .flatMap((t) => t.lines)
          .filter((l) => account.ok && l.coaCode === account.account)
          .reduce((t, l) => t + Math.abs(l.debit - l.credit), 0);
        if (Math.abs(closed - input.amount) > 0.005) {
          throw new PayloadError(
            `ใบล้างที่ถูกหักภาษีปิดบัญชีพักได้ ${closed} แต่ยอดที่อนุมัติให้ล้างคือ ${input.amount} — ยอดต้องเป็นยอดเต็มก่อนหักภาษี`
          );
        }
      }
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
