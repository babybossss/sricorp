"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getAccess } from "@/lib/auth/session";
import { loadReference } from "@/lib/db/reference";
import { humanizeDbError } from "@/lib/db/post-entry";
import { loadAssets, loadTaxonomy } from "@/lib/db/assets-server";
import { VALUATION_METHODS, toDraftView, type DraftDbRow, type DraftPatch } from "@/lib/db/assets-model";
import { dmyToIso, parseAmountOrNull, todayDmy } from "@/lib/format";
import type { Permission } from "@/lib/auth/permissions";
import { canSubmitDraft, norm, registerMode, validateDraft, type DraftContext, type DraftInput } from "@/components/assets/asset-drafts";

/**
 * เขียนทะเบียนทรัพย์จริง — ร่าง · อนุมัติ · ลงทะเบียน · แก้ · ตีราคา
 *
 * **ด่านสิทธิ์คือ RLS ไม่ใช่โค้ดนี้** (รูปเดียวกับ `actions/bank-accounts.ts`): ทุกคำสั่งไป DB ด้วย session ของผู้ใช้
 * ถ้า DB ปฏิเสธ (INSERT = 42501 · UPDATE = ไม่มีแถวถูกแก้) ก็บอกผู้ใช้ตามนั้น · สิ่งที่โค้ดนี้ตัดสินเองมีแค่
 *   (1) ข้อมูลครบไหม (ใช้กติกาชุดเดียวกับหน้าจอ: `validateDraft`) ไม่ครบ = ปฏิเสธ ไม่เดาให้
 *   (2) เลือกเส้นทาง "ลงทะเบียนตรง" หรือ "ส่งเป็นร่าง" ด้วย `registerMode()` ตัวเดียวกับที่ตัดสินปุ่มบนจอ
 *
 * **ไม่มีการลบ** ไม่ว่ากรณีใด (กฎเหล็กข้อ 1) · **ไม่แตะสมุดบัญชีเลย** — ทะเบียนทรัพย์กับ ledger แยกกัน
 * ต้นทุน/รายได้ของทรัพย์เกิดจากรายการเงินที่ลงผ่านหน้าบันทึกรายการเท่านั้น
 *
 * **ลงทะเบียนตรง = ร่าง + อนุมัติด้วย `fn_apply_asset_draft()`** (ฟังก์ชันเดียวที่ออกรหัสทรัพย์) แทนการ insert
 * `assets` เอง — รหัสทรัพย์และข้อมูลประกอบออกจากที่เดียวกับทางอนุมัติ ไม่มีสองทางที่อาจให้ผลต่างกัน
 * ถ้าอนุมัติล้มกลางทาง ร่างที่เพิ่งสร้างถูกยกเลิกทันที ไม่ทิ้งร่างค้างที่ผู้ใช้ไม่รู้จัก
 */

export type AssetOutcome = { ok: true; message: string; id?: string } | { ok: false; message: string; errors?: string[] };

type Db = Awaited<ReturnType<typeof createClient>>;
type Session = { db: Db; userId: string; permissions: ReadonlySet<Permission> };

async function open(): Promise<({ ok: true } & Session) | { ok: false; message: string }> {
  const access = await getAccess();
  if (!access.user) return { ok: false, message: "เข้าสู่ระบบหมดอายุ — ให้เข้าสู่ระบบใหม่แล้วลองอีกครั้ง" };
  try {
    return { ok: true, db: await createClient(), userId: access.user.id, permissions: access.permissions };
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : String(e) };
  }
}

const bad = (message: string, errors?: string[]): AssetOutcome => ({ ok: false, message, errors });

function refresh() {
  revalidatePath("/assets");
  revalidatePath("/assets/drafts");
  revalidatePath("/assets/new");
}

/** ข้อมูลที่ใช้ตรวจร่าง: หมวด · ผู้ถือที่ใช้งานอยู่ · ทรัพย์ที่ผู้ใช้เห็น (ผ่าน RLS) */
async function context(db: Db): Promise<{ ok: true; ctx: DraftContext } | { ok: false; message: string }> {
  const ref = await loadReference();
  if (!ref.ok) return { ok: false, message: `โหลดรายชื่อผู้ถือไม่ได้ (${ref.error})` };
  const tax = await loadTaxonomy(db);
  if (!tax.ok) return { ok: false, message: tax.error };
  const assets = await loadAssets(db, tax.taxonomy);
  if (!assets.ok) return { ok: false, message: assets.error };
  return {
    ok: true,
    ctx: {
      assets: assets.assets,
      // ผู้ถือที่ยังเป็น planned ลงทะเบียนทรัพย์ไม่ได้ — เหมือนที่ฟอร์มซ่อนไว้ แต่คำขอที่แก้เองก็ต้องถูกกัน
      ownerIds: ref.ref.owners.filter((o) => o.status === "active").map((o) => o.id),
      taxonomy: tax.taxonomy,
    },
  };
}

/** ตัดช่องว่างและแปลงค่าว่างเป็น null ก่อนเข้า DB — "ไม่ส่ง" กับ "ส่งว่าง" ต้องไม่ปนกัน */
function cleanNew(patch: DraftPatch): DraftPatch {
  const out: DraftPatch = {};
  for (const [k, v] of Object.entries(patch)) {
    const n = norm(v);
    if (n !== null) out[k] = n;
  }
  return out;
}

function cleanEdit(patch: DraftPatch): DraftPatch {
  const out: DraftPatch = {};
  for (const [k, v] of Object.entries(patch)) out[k] = norm(v); // null = ลบค่าออก (ตั้งใจ)
  return out;
}

async function insertDraft(s: Session, row: Record<string, unknown>) {
  return s.db
    .from("asset_drafts")
    .insert({ ...row, created_by: s.userId })
    .select("id")
    .single();
}

async function cancelOwn(s: Session, id: string) {
  await s.db
    .from("asset_drafts")
    .update({ status: "cancelled", reviewed_by: s.userId, reviewed_at: new Date().toISOString() })
    .eq("id", id)
    .eq("status", "pending");
}

/* ------------------------------------------------------------------ *
 * ลงทะเบียนทรัพย์ใหม่ (4 ช่องบังคับ · D-083)
 * ------------------------------------------------------------------ */

export type RegisterInput = {
  name: string;
  classId: string;
  categoryId: string;
  ownerId: string;
  /** ช่องเสริม (ชื่อคอลัมน์จริงของ assets) — ช่องว่างไม่ถูกส่ง */
  patch?: DraftPatch;
  note?: string;
};

export async function registerAsset(input: RegisterInput): Promise<AssetOutcome> {
  const s = await open();
  if (!s.ok) return s;

  const mode = registerMode(s.permissions);
  if (mode === "none") return bad("บัญชีของคุณยังไม่มีสิทธิ์ลงทะเบียนหรือเสนอร่างทรัพย์ — ให้ขอผู้ดูแลระบบเปิดสิทธิ์ก่อน ยังไม่ได้บันทึกอะไร");

  const c = await context(s.db);
  if (!c.ok) return bad(c.message);

  const draft: DraftInput = {
    kind: "create",
    targetAssetId: null,
    ownerId: input.ownerId,
    name: norm(input.name) === null ? null : String(norm(input.name)),
    classId: input.classId || null,
    categoryId: input.categoryId || null,
    patch: cleanNew(input.patch ?? {}),
  };
  const errors = validateDraft(draft, c.ctx);
  if (errors.length) return bad("ข้อมูลทรัพย์ยังไม่ครบหรือไม่ถูกต้อง — ยังไม่ได้บันทึกอะไร", errors);

  const ins = await insertDraft(s, {
    kind: "create",
    owner_id: draft.ownerId,
    name: draft.name,
    class_id: draft.classId,
    category_id: draft.categoryId,
    patch: draft.patch,
    note: norm(input.note ?? "") ?? null,
  });
  if (ins.error || !ins.data) return bad(humanizeDbError(ins.error));
  const draftId = (ins.data as { id: string }).id;

  if (mode === "draft") {
    refresh();
    return { ok: true, id: draftId, message: "ส่งเป็นร่างแล้ว — ยังไม่ใช่ทรัพย์ในทะเบียนจนกว่าผู้มีสิทธิ์จะอนุมัติ" };
  }

  const applied = await s.db.rpc("fn_apply_asset_draft", { p_draft: draftId });
  if (applied.error || !applied.data) {
    await cancelOwn(s, draftId);
    return bad(`${humanizeDbError(applied.error)} · ร่างที่สร้างไว้ถูกยกเลิกแล้ว ยังไม่มีทรัพย์ใหม่ในทะเบียน`);
  }
  refresh();
  return { ok: true, id: applied.data as string, message: "บันทึกเป็นทรัพย์แล้ว — ต้นทุนและมูลค่ายังเป็น 0 จนกว่าจะลงรายการซื้อหรือตีราคา" };
}

/* ------------------------------------------------------------------ *
 * เสนอแก้ (ร่างชนิด update) และแก้ตรง
 * ------------------------------------------------------------------ */

export async function proposeAssetEdit(input: { assetId: string; patch: DraftPatch; note?: string }): Promise<AssetOutcome> {
  const s = await open();
  if (!s.ok) return s;
  if (!canSubmitDraft(s.permissions)) return bad("บัญชีของคุณยังไม่มีสิทธิ์เสนอร่างทะเบียนทรัพย์ ยังไม่ได้บันทึกอะไร");
  const c = await context(s.db);
  if (!c.ok) return bad(c.message);

  const target = c.ctx.assets.find((a) => a.id === input.assetId);
  // ผู้ถือของร่างต้องตรงกับทรัพย์ (policy asset_drafts_insert) — อ่านจากทรัพย์เอง ไม่เชื่อค่าที่ฝั่งหน้าจอส่งมา
  const draft: DraftInput = {
    kind: "update",
    targetAssetId: input.assetId,
    ownerId: target?.ownerId ?? "",
    name: null,
    classId: null,
    categoryId: null,
    patch: cleanEdit(input.patch),
  };
  const errors = validateDraft(draft, c.ctx);
  if (errors.length) return bad("ข้อมูลที่เสนอแก้ยังไม่ครบหรือไม่ถูกต้อง — ยังไม่ได้บันทึกอะไร", errors);

  const ins = await insertDraft(s, {
    kind: "update",
    target_asset_id: draft.targetAssetId,
    owner_id: draft.ownerId,
    patch: draft.patch,
    note: norm(input.note ?? "") ?? null,
  });
  if (ins.error || !ins.data) return bad(humanizeDbError(ins.error));
  refresh();
  return { ok: true, id: (ins.data as { id: string }).id, message: "ส่งเป็นร่างแล้ว — ทะเบียนยังเป็นค่าเดิมจนกว่าจะมีคนอนุมัติ" };
}

export async function editAssetDirect(input: { assetId: string; patch: DraftPatch }): Promise<AssetOutcome> {
  const s = await open();
  if (!s.ok) return s;
  const c = await context(s.db);
  if (!c.ok) return bad(c.message);

  const target = c.ctx.assets.find((a) => a.id === input.assetId);
  const patch = cleanEdit(input.patch);
  const errors = validateDraft(
    { kind: "update", targetAssetId: input.assetId, ownerId: target?.ownerId ?? "", name: null, classId: null, categoryId: null, patch },
    c.ctx
  );
  if (errors.length) return bad("ข้อมูลที่แก้ยังไม่ครบหรือไม่ถูกต้อง — ยังไม่ได้บันทึกอะไร", errors);

  const { data, error } = await s.db.from("assets").update(patch).eq("id", input.assetId).select("id");
  if (error) return bad(humanizeDbError(error));
  // RLS กรองแถวออก = ไม่ error แต่ไม่มีแถวถูกแก้ (ตรงกับ PostgREST จริง)
  if (!data || data.length === 0) {
    return bad("ไม่มีสิทธิ์แก้ทรัพย์นี้ หรือไม่พบทรัพย์นี้ — ฐานข้อมูลไม่แก้ให้ (ต้องมีสิทธิ์เขียนทะเบียนและเป็นทรัพย์ที่คุณบริหาร) ยังไม่มีอะไรเปลี่ยน");
  }
  refresh();
  revalidatePath(`/assets/${input.assetId}`);
  return { ok: true, id: input.assetId, message: "แก้ทะเบียนทรัพย์แล้ว" };
}

/* ------------------------------------------------------------------ *
 * ตรวจร่าง: อนุมัติ · ไม่อนุมัติ · ยกเลิก
 * ------------------------------------------------------------------ */

const DRAFT_COLUMNS =
  "id, kind, target_asset_id, owner_id, name, class_id, category_id, patch, note, status, reject_reason, applied_asset_id, created_by, reviewed_by, reviewed_at, created_at";

async function readDraft(db: Db, id: string) {
  const { data, error } = await db.from("asset_drafts").select(DRAFT_COLUMNS).eq("id", id).maybeSingle();
  if (error) return { ok: false as const, message: humanizeDbError(error) };
  // มองไม่เห็นกับไม่มีอยู่ตอบเหมือนกัน (RLS)
  if (!data) return { ok: false as const, message: "ไม่พบร่างนี้ หรือคุณไม่มีสิทธิ์เห็นร่างนี้" };
  return { ok: true as const, row: data as unknown as DraftDbRow };
}

export async function approveAssetDraft(draftId: string): Promise<AssetOutcome> {
  const s = await open();
  if (!s.ok) return s;
  const d = await readDraft(s.db, draftId);
  if (!d.ok) return bad(d.message);
  if (d.row.status !== "pending") return bad(`ร่างนี้อยู่สถานะ ${d.row.status} แล้ว อนุมัติซ้ำไม่ได้`);

  const c = await context(s.db);
  if (!c.ok) return bad(c.message);
  const v = toDraftView(d.row, () => "");
  // ตรวจซ้ำตอนอนุมัติ — ร่างที่ค้างมาอาจเพี้ยน (ทรัพย์ปลายทางถูกย้ายผู้ถือ ฯลฯ)
  const errors = validateDraft(v, c.ctx);
  if (errors.length) return bad("อนุมัติไม่ได้ — ข้อมูลของร่างนี้ไม่ครบหรือไม่ถูกต้อง", errors);

  const applied = await s.db.rpc("fn_apply_asset_draft", { p_draft: draftId });
  if (applied.error || !applied.data) return bad(humanizeDbError(applied.error));
  refresh();
  revalidatePath(`/assets/${applied.data as string}`);
  return { ok: true, id: applied.data as string, message: "อนุมัติแล้ว — ทรัพย์เข้าทะเบียนและนับในพอร์ตแล้ว" };
}

async function closeDraft(s: Session, id: string, status: "rejected" | "cancelled", reason?: string): Promise<AssetOutcome | { ok: true }> {
  const d = await readDraft(s.db, id);
  if (!d.ok) return bad(d.message);
  if (d.row.status !== "pending") return bad(`ร่างนี้อยู่สถานะ ${d.row.status} แล้ว`);
  const { data, error } = await s.db
    .from("asset_drafts")
    .update({
      status,
      reject_reason: status === "rejected" ? reason : null,
      reviewed_by: s.userId,
      reviewed_at: new Date().toISOString(),
    })
    .eq("id", id)
    .eq("status", "pending")
    .select("id");
  if (error) return bad(humanizeDbError(error));
  if (!data || data.length === 0) {
    return bad(
      status === "rejected"
        ? "ไม่มีสิทธิ์ไม่อนุมัติร่างนี้ — ฐานข้อมูลไม่แก้ให้ ยังไม่มีอะไรเปลี่ยน"
        : "ยกเลิกได้เฉพาะร่างของตัวเองที่ยังรออนุมัติ — ฐานข้อมูลไม่แก้ให้ ยังไม่มีอะไรเปลี่ยน"
    );
  }
  refresh();
  return { ok: true };
}

export async function rejectAssetDraft(draftId: string, reason: string): Promise<AssetOutcome> {
  const s = await open();
  if (!s.ok) return s;
  // ปฏิเสธโดยไม่บอกเหตุผล = คนคีย์แก้ไม่ถูก (CHECK asset_drafts_reject_reason)
  const r = norm(reason);
  if (typeof r !== "string") return bad("ต้องใส่เหตุผลที่ไม่อนุมัติ — ผู้สร้างร่างจะเห็นข้อความนี้ ยังไม่ได้บันทึกอะไร");
  const out = await closeDraft(s, draftId, "rejected", r);
  return out.ok ? { ok: true, id: draftId, message: "ไม่อนุมัติร่างแล้ว" } : out;
}

export async function cancelAssetDraft(draftId: string): Promise<AssetOutcome> {
  const s = await open();
  if (!s.ok) return s;
  const out = await closeDraft(s, draftId, "cancelled");
  return out.ok ? { ok: true, id: draftId, message: "ยกเลิกร่างแล้ว" } : out;
}

/* ------------------------------------------------------------------ *
 * ตีราคา — เก็บเป็นประวัติ (append-only) **ไม่เข้าสมุด ไม่เข้างบดุล**
 * ------------------------------------------------------------------ */

export type ValuationInput = { assetId: string; asOf: string; value: string; method: string; note?: string };

export async function recordValuation(input: ValuationInput): Promise<AssetOutcome> {
  const s = await open();
  if (!s.ok) return s;

  const errors: string[] = [];
  const asOf = dmyToIso(input.asOf);
  if (!asOf) errors.push("วันที่ตีราคาไม่ถูกต้อง — ใส่เป็น วว/ดด/ปปปป (ค.ศ.)");
  else if (asOf > (dmyToIso(todayDmy()) ?? asOf)) errors.push("วันที่ตีราคาอยู่ในอนาคตไม่ได้");
  const value = parseAmountOrNull(input.value);
  if (value === null) errors.push("มูลค่าต้องเป็นตัวเลข");
  else if (!(value > 0)) errors.push("มูลค่าต้องมากกว่า 0");
  if (!(VALUATION_METHODS as readonly string[]).includes(input.method)) errors.push("เลือกที่มาของราคาให้ครบ");
  if (errors.length) return bad("ข้อมูลการตีราคายังไม่ครบหรือไม่ถูกต้อง — ยังไม่ได้บันทึกอะไร", errors);

  // ทรัพย์ต้องเป็นของที่ผู้ใช้เห็น (RLS) และเป็นเงินบาท: ทรัพย์สกุลต่างประเทศต้องเก็บยอดสกุลเดิม + อัตรา (D-111 ข้อ 2)
  // ซึ่งหน้านี้ยังไม่รองรับ → ปฏิเสธ ไม่เดาอัตราเป็น 1
  const tax = await loadTaxonomy(s.db);
  if (!tax.ok) return bad(tax.error);
  const found = await loadAssets(s.db, tax.taxonomy, input.assetId);
  if (!found.ok) return bad(found.error);
  const asset = found.assets.find((a) => a.id === input.assetId);
  if (!asset) return bad("ไม่พบทรัพย์นี้ หรือคุณไม่มีสิทธิ์เห็นทรัพย์นี้ ยังไม่ได้บันทึกอะไร");
  if (asset.currency !== "THB") {
    return bad(`ทรัพย์นี้ถือเป็นสกุล ${asset.currency} — การตีราคาสกุลต่างประเทศต้องเก็บยอดสกุลเดิมและอัตราแลกเปลี่ยนด้วย ซึ่งหน้านี้ยังไม่รองรับ จึงไม่บันทึกให้ (ไม่เดาอัตราแลกเปลี่ยน)`);
  }

  const { error } = await s.db.from("asset_valuations").insert({
    asset_id: input.assetId,
    as_of: asOf,
    method: input.method,
    value: Math.round((value as number) * 100) / 100,
    note: norm(input.note ?? "") ?? null,
    created_by: s.userId,
  });
  if (error) return bad(humanizeDbError(error));
  refresh();
  revalidatePath(`/assets/${input.assetId}`);
  return { ok: true, id: input.assetId, message: "บันทึกราคาประเมินแล้ว — เป็นตัวเลขประกอบการดู ไม่ได้ลงสมุดและไม่เข้างบดุล" };
}
