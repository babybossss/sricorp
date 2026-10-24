"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getAccess } from "@/lib/auth/session";
import { loadReference } from "@/lib/db/reference";
import { makeResolver } from "@/lib/db/resolver";
import {
  PayloadError,
  humanizeDbError,
  notWiredReason,
  readPostResult,
  refuseInactiveOwners,
  toPostEntryPayload,
} from "@/lib/db/post-entry";
import { buildPosting } from "@/lib/ledger/posting";
import { PostingError, type PostingInput } from "@/lib/ledger/types";
import { findSub } from "@/lib/rules/tx-rules";
import { dmyToIso } from "@/lib/format";

/**
 * ปุ่มบันทึก → `sri_os.fn_post_entry` (D-091) · เส้นทางเดียวที่เขียนรายการเงินลง DB จากหน้าจอ
 *
 * ลำดับที่ตั้งใจ (ห้ามสลับ):
 *   1. โหลดผู้ถือ/บัญชี **สดจาก DB ตอนนี้** — ไม่เชื่อสแนปช็อตในหน้าจอ (สถานะบัญชีที่ปิดเก่าได้)
 *   2. `buildPosting()` ตัวจริง (ไม่ใช่ `buildPostingDraft()`) บังคับกติกาเอกสารของนิติบุคคลครบ
 *      — เราไม่รับบรรทัดบัญชีจาก browser เลย รับแค่ `PostingInput` แล้วให้ engine ฝั่ง server คิดใหม่
 *      เพื่อไม่ให้ client ที่ถูกแก้ส่งคู่บัญชีเองมาได้ (DB ตรวจซ้ำอีกชั้นที่ประตู)
 *   3. ส่ง `transactions` ที่ engine คืนมา **ครบทุกก้อน** (ข้ามผู้ถือ = สองก้อน) ผ่าน RPC ครั้งเดียว
 *   4. error จาก DB ส่งกลับเป็นข้อความอ่านรู้เรื่อง · ห้ามกลืนแล้วตอบว่าสำเร็จ
 *
 * ใช้ session ของผู้ใช้เอง (RLS บังคับ) · ไม่มี service-role
 */

export type PostEntryRequest = {
  input: PostingInput;
  /** วันที่เอกสาร รูป วว/ดด/ปปปป ตามที่ผู้ใช้พิมพ์ — แปลงและตรวจที่ server */
  docDate: string;
  /** วันที่เงินเข้า/ออกจริง — ใช้เฉพาะเมื่อ engine ส่งบรรทัดเงินสดมา */
  cashDate: string;
};

export type PostEntryOutcome =
  | { ok: true; transactionIds: string[]; replayed: boolean }
  | { ok: false; message: string };

const fail = (message: string): PostEntryOutcome => ({ ok: false, message });

export async function postEntry(req: PostEntryRequest): Promise<PostEntryOutcome> {
  // ---- ผู้ใช้ + สิทธิ์ (ความสะดวก · ด่านจริงคือ RLS `txn_insert` ที่ต้องมี ledger.approve) ----
  const access = await getAccess();
  if (!access.user) return fail("เข้าสู่ระบบหมดอายุ — ให้เข้าสู่ระบบใหม่แล้วบันทึกอีกครั้ง");
  if (access.error) return fail(`ตรวจสิทธิ์ไม่สำเร็จ ยังไม่ได้บันทึกอะไร (${access.error})`);
  if (!access.permissions.has("ledger.approve")) {
    return fail(
      "บัญชีนี้ลงสมุดบัญชีโดยตรงไม่ได้ — ต้องมีสิทธิ์อนุมัติเข้าสมุด (ส่วนการส่งร่างให้ผู้อนุมัติยังไม่ได้ต่อกับฐานข้อมูล)"
    );
  }

  if (!req || typeof req !== "object" || !req.input) return fail("ไม่ได้รับข้อมูลรายการ — ยังไม่ได้บันทึกอะไร");

  // เส้นทางนี้คือการบันทึกรายการใหม่ (source = manual) เท่านั้น — ธง `reversal` ปลดการกันบัญชีที่ปิดใช้งาน (D-092)
  // และต้องมาจากเส้นทางกลับรายการที่ส่ง reverses_id ด้วย · browser ส่งธงนี้มาเองไม่ได้ จึงตัดทิ้งเสมอ
  const input: PostingInput = { ...req.input, reversal: undefined };

  // ---- หมวดที่เส้นทางนี้ยังต่อไม่ครบ ต้องปฏิเสธ ไม่ใช่บันทึกครึ่งเดียว ----
  const blocked = notWiredReason(findSub(input.subCode)?.sub);
  if (blocked) return fail(blocked);

  // ---- วันที่ ----
  const docDate = dmyToIso(String(req.docDate ?? ""));
  if (!docDate) return fail("วันที่เอกสารอ่านไม่ออก — ให้พิมพ์เป็น วว/ดด/ปปปป เป็นปี ค.ศ. (เช่น 24/10/2026)");
  const cashRaw = String(req.cashDate ?? "").trim();
  const cashDate = cashRaw === "" ? null : dmyToIso(cashRaw);
  if (cashRaw !== "" && !cashDate) {
    return fail("วันที่เงินเข้า/ออกจริงอ่านไม่ออก — ให้พิมพ์เป็น วว/ดด/ปปปป เป็นปี ค.ศ. (เช่น 24/10/2026)");
  }

  // ---- ข้อมูลอ้างอิงสด ----
  const refState = await loadReference();
  if (!refState.ok) return fail(`โหลดข้อมูลผู้ถือและบัญชีจากฐานข้อมูลไม่ได้ ยังไม่ได้บันทึกอะไร (${refState.error})`);

  // ---- engine ตัวจริง ----
  let payload;
  try {
    const result = buildPosting(input, makeResolver(refState.ref));
    payload = toPostEntryPayload(input, result, { docDate, cashDate });
  } catch (e) {
    if (e instanceof PostingError || e instanceof PayloadError) return fail(e.message);
    // ข้อผิดพลาดที่ไม่ได้คาดไว้ ห้ามกลืน — แต่ไม่ปล่อยข้อความดิบให้ผู้ใช้
    console.error("postEntry: unexpected error while building the posting", e);
    return fail("ระบบประกอบรายการบัญชีไม่สำเร็จด้วยเหตุที่ไม่คาดคิด ยังไม่ได้บันทึกอะไร — แจ้งผู้ดูแลระบบ");
  }

  // ---- ตั้งค้างรับ-ค้างจ่าย (cash_date ว่าง) ----
  // ปล่อยผ่านได้เพราะหน้า "ยืนยันรับ-จ่าย" อ่านยอดค้างจาก DB และล้างผ่าน `confirmCash()` แล้ว
  // (ทดสอบ: src/app/actions/__tests__/confirm-cash.test.ts — ตั้งค้าง → ล้าง → ลูกหนี้เป็นศูนย์ รายได้นับครั้งเดียว)
  // ถ้าวันหนึ่งทางล้างพัง ให้คืนด่านนี้: ปฏิเสธเมื่อ `payload.cash_date === null`

  // ---- ผู้ถือที่ยังไม่จดทะเบียนหรือปิดไปแล้ว ห้ามเป็นเจ้าของรายการ (ทั้ง owner_id และ counter_owner_id) ----
  const refused = refuseInactiveOwners(payload, refState.ref.owners);
  if (refused) return fail(refused);

  // ---- เขียนลง DB ด้วย RPC ตัวเดียว ----
  let supabase;
  try {
    supabase = await createClient();
  } catch (e) {
    return fail(e instanceof Error ? e.message : String(e));
  }
  const { data, error } = await supabase.rpc("fn_post_entry", { p_payload: payload });
  if (error) return fail(humanizeDbError(error));

  const read = readPostResult(data, payload.transactions.length);
  if (!read.ok) return fail(read.message);
  const ids = read.transactionIds;
  const out = { replayed: read.replayed };

  revalidatePath("/ledger");
  revalidatePath("/dashboard");
  return { ok: true, transactionIds: ids, replayed: out.replayed };
}
