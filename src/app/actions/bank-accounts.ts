"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getAccess } from "@/lib/auth/session";
import { loadReference } from "@/lib/db/reference";
import { humanizeDbError } from "@/lib/db/post-entry";
import { validateBank, type BankFieldErrors, type BankInput } from "@/lib/db/bank-accounts";
import type { RefBank } from "@/lib/db/reference-types";

/**
 * ตั้งค่าบัญชีธนาคาร — เขียน `sri_os.bank_accounts` จริง (เพิ่ม · แก้ชื่อ · เปิด/ปิดใช้งาน · จัดลำดับ)
 *
 * **ไม่มีการลบ** ไม่ว่ากรณีใด: บัญชีที่มีรายการอ้างถึงต้องหาเจอเสมอ (D-092) — "ปิดใช้งาน" คือ `is_active = false`
 * (ซ่อนจากตัวเลือก ลงรายการใหม่ไม่ได้ แต่รายงานย้อนหลังและการกลับรายการยังใช้ได้)
 *
 * **ด่านสิทธิ์คือ RLS ไม่ใช่โค้ดนี้**: action นี้ตั้งใจไม่เช็ค `settings.manage` เองแล้วปล่อยผ่าน
 * ทุกคำสั่งไป DB ด้วย session ของผู้ใช้ — ถ้า DB ปฏิเสธ (INSERT = error 42501 · UPDATE = ไม่มีแถวถูกแก้)
 * ก็บอกผู้ใช้ตามนั้น · หน้าจอซ่อนปุ่มได้แต่ไม่ใช่ด่านกั้น
 *
 * ช่องที่เขียนมีเท่านี้: bank · account_name · display_name · account_no_last4 · currency (ตอนสร้าง) · sort_order · is_active
 * ไม่แตะ `opening_balance` / `opening_date` (ยอดตั้งต้นของเงินสดเข้าสมุดทางหน้า "นำเข้ายอดตั้งต้น" เท่านั้น
 * ไม่งั้นมีตัวเลขเงินสดสองที่) · ไม่แตะ `owner_id` / `coa_id` (ย้ายยอดข้ามผู้ถือย้อนหลัง · มี trigger กันฝั่ง DB)
 */

export type BankOutcome =
  | { ok: true; bank: RefBank }
  | { ok: false; message: string; fieldErrors?: BankFieldErrors };

const COLS = "id, owner_id, bank, display_name, account_no_last4, is_active, sort_order, currency";
type Row = {
  id: string;
  owner_id: string;
  bank: string;
  display_name: string;
  account_no_last4: string | null;
  is_active: boolean;
  sort_order: number;
  currency: string | null;
};
const toRef = (r: Row): RefBank => ({
  id: r.id,
  ownerId: r.owner_id,
  name: r.display_name,
  bank: r.bank,
  last4: r.account_no_last4,
  isActive: r.is_active,
  sortOrder: r.sort_order,
  currency: r.currency ?? "THB",
});

const DENIED_UPDATE =
  "ไม่มีสิทธิ์แก้บัญชีนี้ หรือไม่พบบัญชีนี้ — ฐานข้อมูลไม่แก้ให้ (การตั้งค่าบัญชีธนาคารต้องมีสิทธิ์ตั้งค่าระบบและเห็นผู้ถือของบัญชีนั้น) ยังไม่มีอะไรเปลี่ยน";

type Db = Awaited<ReturnType<typeof createClient>>;
async function open(): Promise<{ ok: true; db: Db } | { ok: false; message: string }> {
  const access = await getAccess();
  if (!access.user) return { ok: false, message: "เข้าสู่ระบบหมดอายุ — ให้เข้าสู่ระบบใหม่แล้วลองอีกครั้ง" };
  try {
    return { ok: true, db: await createClient() };
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : String(e) };
  }
}

/** บัญชีทั้งหมดที่ผู้ใช้เห็น (รวมที่ปิดแล้ว) เรียงตามลำดับที่แสดง */
async function readAll(db: Db): Promise<{ ok: true; rows: Row[] } | { ok: false; message: string }> {
  const { data, error } = await db.from("bank_accounts").select(COLS).order("sort_order", { ascending: true }).order("display_name", { ascending: true });
  if (error) return { ok: false, message: humanizeDbError(error) };
  return { ok: true, rows: (data ?? []) as Row[] };
}

export async function createBankAccount(input: BankInput): Promise<BankOutcome> {
  const o = await open();
  if (!o.ok) return o;
  const ref = await loadReference();
  if (!ref.ok) return { ok: false, message: `โหลดรายชื่อผู้ถือไม่ได้ (${ref.error})` };
  const all = await readAll(o.db);
  if (!all.ok) return all;

  const v = validateBank(
    input,
    ref.ref.owners,
    all.rows.map((r) => ({ id: r.id, ownerId: r.owner_id, name: r.display_name }))
  );
  if (!v.ok) return { ok: false, message: "ข้อมูลบัญชียังไม่ครบหรือไม่ถูกต้อง — ดูข้อความใต้ช่องที่แดง ยังไม่ได้บันทึกอะไร", fieldErrors: v.errors };

  const nextSort = all.rows.reduce((m, r) => Math.max(m, r.sort_order), 0) + 1;
  const { data, error } = await o.db
    .from("bank_accounts")
    .insert({
      owner_id: v.value.ownerId,
      bank: v.value.bank,
      account_name: v.value.displayName,
      display_name: v.value.displayName,
      account_no_last4: v.value.last4,
      currency: v.value.currency,
      sort_order: nextSort,
      is_active: true,
    })
    .select(COLS)
    .single();
  if (error || !data) return { ok: false, message: humanizeDbError(error) };

  revalidatePath("/settings/banks");
  return { ok: true, bank: toRef(data as Row) };
}

export type UpdateBankInput = { id: string; bank: string; displayName: string; last4: string };

/** แก้ชื่อ/ธนาคาร/เลขท้าย — **ไม่แก้ผู้ถือและสกุลเงิน** (ดูหัวไฟล์ `lib/db/bank-accounts.ts`) */
export async function updateBankAccount(input: UpdateBankInput): Promise<BankOutcome> {
  const o = await open();
  if (!o.ok) return o;
  if (typeof input?.id !== "string" || !input.id) return { ok: false, message: "ไม่ได้ระบุบัญชีที่จะแก้" };
  const all = await readAll(o.db);
  if (!all.ok) return all;
  const cur = all.rows.find((r) => r.id === input.id);
  if (!cur) return { ok: false, message: DENIED_UPDATE };

  const v = validateBank(
    { ownerId: cur.owner_id, bank: input.bank, displayName: input.displayName, last4: input.last4, currency: cur.currency ?? "THB" },
    [],
    all.rows.map((r) => ({ id: r.id, ownerId: r.owner_id, name: r.display_name })),
    { editingId: cur.id, skipOwnerAndCurrency: true }
  );
  if (!v.ok) return { ok: false, message: "ข้อมูลบัญชียังไม่ครบหรือไม่ถูกต้อง — ดูข้อความใต้ช่องที่แดง ยังไม่ได้บันทึกอะไร", fieldErrors: v.errors };

  const { data, error } = await o.db
    .from("bank_accounts")
    .update({ bank: v.value.bank, account_name: v.value.displayName, display_name: v.value.displayName, account_no_last4: v.value.last4 })
    .eq("id", cur.id)
    .select(COLS);
  if (error) return { ok: false, message: humanizeDbError(error) };
  const row = (data as Row[] | null)?.[0];
  if (!row) return { ok: false, message: DENIED_UPDATE };

  revalidatePath("/settings/banks");
  return { ok: true, bank: toRef(row) };
}

/** ปิด/เปิดใช้งาน — ไม่ใช่การลบ · รายการเดิมของบัญชีที่ปิดยังอ่านได้ และกลับรายการได้ */
export async function setBankAccountActive(input: { id: string; active: boolean }): Promise<BankOutcome> {
  const o = await open();
  if (!o.ok) return o;
  if (typeof input?.id !== "string" || !input.id || typeof input.active !== "boolean") {
    return { ok: false, message: "คำขอเปิด/ปิดบัญชีไม่ครบ — ยังไม่มีอะไรเปลี่ยน" };
  }
  const { data, error } = await o.db.from("bank_accounts").update({ is_active: input.active }).eq("id", input.id).select(COLS);
  if (error) return { ok: false, message: humanizeDbError(error) };
  const row = (data as Row[] | null)?.[0];
  if (!row) return { ok: false, message: DENIED_UPDATE };

  revalidatePath("/settings/banks");
  return { ok: true, bank: toRef(row) };
}

/**
 * เลื่อนลำดับขึ้น/ลง (ลำดับนี้คือลำดับในตัวเลือกบัญชีทุกฟอร์ม)
 * เลขลำดับซ้ำกัน (เช่นแถวเดิมที่เป็น 0 ทั้งหมด) → เรียงเลขใหม่ 1..n ก่อนสลับ ไม่งั้นสลับแล้วไม่เกิดอะไร
 */
export async function moveBankAccount(input: { id: string; direction: -1 | 1 }): Promise<{ ok: true; banks: RefBank[] } | { ok: false; message: string }> {
  const o = await open();
  if (!o.ok) return o;
  if (input?.direction !== -1 && input?.direction !== 1) return { ok: false, message: "ทิศทางการเลื่อนไม่ถูกต้อง" };
  const all = await readAll(o.db);
  if (!all.ok) return all;

  const order = [...all.rows];
  const i = order.findIndex((r) => r.id === input.id);
  if (i < 0) return { ok: false, message: DENIED_UPDATE };
  const j = i + input.direction;
  if (j < 0 || j >= order.length) return { ok: false, message: "บัญชีนี้อยู่ปลายสุดของรายการแล้ว" };
  [order[i], order[j]] = [order[j], order[i]];

  const changed: Row[] = [];
  for (let k = 0; k < order.length; k++) {
    const want = k + 1;
    if (order[k].sort_order === want) continue;
    const { data, error } = await o.db.from("bank_accounts").update({ sort_order: want }).eq("id", order[k].id).select(COLS);
    const row = (data as Row[] | null)?.[0];
    if (error || !row) {
      return {
        ok: false,
        message: `${error ? humanizeDbError(error) : DENIED_UPDATE} · เรียงลำดับได้ไม่ครบ ให้โหลดหน้าใหม่เพื่อดูลำดับปัจจุบัน`,
      };
    }
    changed.push(row);
  }
  revalidatePath("/settings/banks");
  const byId = new Map(changed.map((r) => [r.id, r]));
  return { ok: true, banks: order.map((r) => toRef(byId.get(r.id) ?? { ...r, sort_order: order.indexOf(r) + 1 })) };
}
