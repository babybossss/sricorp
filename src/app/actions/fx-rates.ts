"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getAccess } from "@/lib/auth/session";
import { humanizeFxRateError, validateFxRate, type FxRateFieldErrors, type FxRateInput, type FxRateRow } from "@/lib/db/fx-rates";

/**
 * จัดการอัตราแลกเปลี่ยน (`sri_os.fx_rates`) — ป้อนมือ ไม่ต่อ API (ลูกพี่: "เรทจาก Google ก็ได้")
 *
 * **กฎแก้อัตรา: เพิ่มได้ · ไม่มีเส้นทางแก้ค่าของแถวเดิม · ลบได้เฉพาะแถวที่ไม่มีใครอ้างถึง**
 * เหตุผล: บรรทัดบัญชี ล็อต และการตีราคาเก็บอัตราของตัวเองไว้ และด่านของ DB เทียบอัตราของบรรทัดกับ `fx_rates` ตามวันนั้น
 * ถ้าแก้ค่าแถวที่ถูกอ้างถึง รายการเก่าจะ "ไม่ตรงตาราง" ทันที (ยอดบาทคิดที่อัตราเดิมแต่ตารางบอกอัตราใหม่)
 * และรายการใหม่ของวันเดียวกันจะต้องใช้อัตราใหม่ → วันเดียวกันมีสองอัตราในสมุด
 * การลบถูกกั้นด้วย FK ของ DB (แถวที่ถูกอ้างถึงลบไม่ได้) จึงไม่ต้องให้แอปเดาว่า "ถูกอ้างถึงหรือยัง"
 * (แอปมองไม่ครบ: RLS ซ่อนรายการของผู้ถือที่ผู้ใช้ไม่เห็น)
 * พิมพ์ผิดแล้วยังไม่มีใครใช้ → ลบแล้วเพิ่มใหม่ · พิมพ์ผิดแล้วมีรายการใช้ไปแล้ว → แก้ที่ตัวรายการ (กลับรายการแล้วลงใหม่)
 * เพราะคีย์คือ (สกุล, วันที่) จึงเพิ่ม "อัตราใหม่ของวันเดิม" ไม่ได้
 *
 * **ด่านสิทธิ์คือ RLS ไม่ใช่โค้ดนี้**: ไม่เช็ค settings.manage เองแล้วปล่อยผ่าน ส่งทุกคำสั่งไป DB ด้วย session ของผู้ใช้
 * (INSERT ไม่มีสิทธิ์ = 42501 · DELETE ไม่มีสิทธิ์ = RLS กรองแถวออก ไม่มีแถวถูกลบ) แล้วบอกผู้ใช้ตามที่ DB ตอบ
 */

export type FxRatesList = { ok: true; rows: FxRateRow[] } | { ok: false; message: string };
export type FxRateOutcome = { ok: true; row: FxRateRow } | { ok: false; message: string; fieldErrors?: FxRateFieldErrors };
export type FxRateDeleteOutcome = { ok: true } | { ok: false; message: string };

type Db = Awaited<ReturnType<typeof createClient>>;
async function open(): Promise<{ ok: true; db: Db; userId: string } | { ok: false; message: string }> {
  const access = await getAccess();
  if (!access.user) return { ok: false, message: "เข้าสู่ระบบหมดอายุ — ให้เข้าสู่ระบบใหม่แล้วลองอีกครั้ง" };
  try {
    return { ok: true, db: await createClient(), userId: access.user.id };
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : String(e) };
  }
}

type Row = { currency: string; rate_date: string; thb_per_unit: number | string; source: string; note: string | null; created_at: string | null };
const COLS = "currency, rate_date, thb_per_unit, source, note, created_at";
const toRow = (r: Row): FxRateRow => ({
  currency: r.currency,
  rateDate: r.rate_date,
  thbPerUnit: Number(r.thb_per_unit),
  source: r.source,
  note: r.note,
  createdAt: r.created_at,
});

/** อัตราทั้งหมด (ใหม่ → เก่า) — อ่านจาก DB ตามที่ฟอร์มแลกเงินเห็น ไม่มีค่าคงที่ */
export async function listFxRates(): Promise<FxRatesList> {
  const o = await open();
  if (!o.ok) return o;
  const { data, error } = await o.db
    .from("fx_rates")
    .select(COLS)
    .order("rate_date", { ascending: false })
    .order("currency", { ascending: true })
    .limit(2000);
  if (error) return { ok: false, message: `อ่านตารางอัตราแลกเปลี่ยนไม่สำเร็จ (${error.message})` };
  return { ok: true, rows: ((data ?? []) as Row[]).map(toRow) };
}

export async function addFxRate(input: FxRateInput): Promise<FxRateOutcome> {
  const o = await open();
  if (!o.ok) return o;
  const v = validateFxRate(input);
  if (!v.ok) return { ok: false, message: "ข้อมูลอัตรายังไม่ครบหรือไม่ถูกต้อง — ดูข้อความใต้ช่องที่แดง ยังไม่ได้บันทึกอะไร", fieldErrors: v.errors };

  // insert ธรรมดา ไม่ใช่ upsert: แถวเดิมต้องไม่ถูกเขียนทับ (ดูหัวไฟล์)
  const { data, error } = await o.db
    .from("fx_rates")
    .insert({ ...v.row, source: "manual", created_by: o.userId })
    .select(COLS)
    .single();
  if (error) return { ok: false, message: humanizeFxRateError(error, "add") };
  revalidatePath("/settings/fx-rates");
  return { ok: true, row: toRow(data as Row) };
}

export async function deleteFxRate(req: { currency: string; rateDate: string }): Promise<FxRateDeleteOutcome> {
  const o = await open();
  if (!o.ok) return o;
  if (!req || typeof req.currency !== "string" || typeof req.rateDate !== "string" || !req.currency || !req.rateDate) {
    return { ok: false, message: "ไม่ได้ระบุอัตราที่จะลบ" };
  }
  const { data, error } = await o.db.from("fx_rates").delete().eq("currency", req.currency).eq("rate_date", req.rateDate).select("currency");
  if (error) return { ok: false, message: humanizeFxRateError(error, "delete") };
  if (!data || data.length === 0) {
    return { ok: false, message: "ไม่มีอะไรถูกลบ — ไม่พบอัตรานี้ หรือบัญชีของคุณไม่มีสิทธิ์จัดการอัตราแลกเปลี่ยน (ฐานข้อมูลไม่ลบให้) ยังไม่มีอะไรเปลี่ยน" };
  }
  revalidatePath("/settings/fx-rates");
  return { ok: true };
}
