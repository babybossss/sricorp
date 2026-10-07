import type { Permission } from "@/lib/auth/permissions";
import type { AssetRef, AssetDraft, DraftPatch } from "@/lib/mock/assets";
import { ASSET_CLASSES } from "@/lib/rules/asset-classes";
import { HOLDERS } from "@/lib/mock/entities";

/**
 * กติกาของร่างทะเบียนทรัพย์ — ฟังก์ชันบริสุทธิ์ ไม่มี React ไม่มี store
 * ทั้งหน้าจอ ทั้ง store จำลอง และเทสต์เรียกที่นี่ที่เดียว
 *
 * ## การซ่อนปุ่มคือความสะดวก **ไม่ใช่ความปลอดภัย**
 * ฟังก์ชัน `canXxx` / `reviewActions` ด้านล่างมีไว้ "ไม่โชว์ปุ่มที่กดแล้วโดนปฏิเสธ"
 * เท่านั้น — ผู้ใช้ที่เปิด DevTools หรือยิง API ตรงๆ ข้ามมันได้ทั้งหมด
 * **ความปลอดภัยจริงอยู่ที่ RLS ใน DB** (`asset_drafts_*` · `assets_insert` · `assets_update` ·
 * `valuations_insert` ใน `20261008000000_asset_permissions.sql`) ซึ่งเป็นด่านเดียวที่เชื่อได้
 * เงื่อนไขในไฟล์นี้จึงต้อง **เดินตาม policy ใน DB** ไม่ใช่คิดกติกาของตัวเอง — ถ้า policy
 * เปลี่ยน ต้องแก้ที่นี่ตาม ไม่งั้นปุ่มจะโผล่ในที่ที่ DB ปฏิเสธ (หรือหายไปในที่ที่ DB อนุญาต)
 */

export type Perms = ReadonlySet<Permission>;

/** ข้อความที่ต้องไม่ถูกย่อ/ซ่อน/แก้ — ลูกพี่สั่ง: ห้ามให้ผู้ใช้เข้าใจว่าบันทึกแล้วเสร็จ */
export const DRAFT_NOT_COUNTED = "ร่างนี้ยังไม่ถูกนับในมูลค่าพอร์ต ต้องรออนุมัติ";

/* ---------- สิทธิ์ → ปุ่มที่โชว์ ---------- */

/**
 * บันทึกเป็นทรัพย์จริงได้ต้องผ่าน `assets_insert` = asset.manage **และ** portfolio.view_all
 * (Manager มี asset.manage แต่ไม่มี portfolio.view_all → INSERT ตรงไม่ได้ ต้องผ่านร่าง ตามเอกสาร §1.1)
 * ถ้าเช็คแค่ asset.manage ตามที่งานสั่งไว้ตรงๆ Manager จะเห็นปุ่มที่กดแล้วโดน RLS ปฏิเสธ
 */
export const canRegisterDirect = (p: Perms) => p.has("asset.manage") && p.has("portfolio.view_all");

export const canSubmitDraft = (p: Perms) => p.has("asset.draft");

export type RegisterMode = "direct" | "draft" | "none";
export const registerMode = (p: Perms): RegisterMode =>
  canRegisterDirect(p) ? "direct" : canSubmitDraft(p) ? "draft" : "none";

/** ปุ่ม "ตีราคา" — asset.value เท่านั้น (Manager ไม่มี · `valuations_insert`) */
export const canValueAsset = (p: Perms) => p.has("asset.value");

/** แก้ทรัพย์ตรง — asset.manage (ขอบเขตทรัพย์ที่ตนบริหารให้ RLS กรอง `fn_can_see_asset`) */
export const canEditAssetDirect = (p: Perms) => p.has("asset.manage");

/** เสนอแก้เป็นร่าง — เฉพาะคนที่แก้ตรงไม่ได้ (Staff) */
export const canProposeEdit = (p: Perms) => p.has("asset.draft") && !p.has("asset.manage");

/** เห็นคิวร่างได้ — Staff เห็นเฉพาะของตัวเอง (`asset_drafts_read`) */
export const canSeeDraftQueue = (p: Perms) => p.has("asset.draft") || p.has("asset.manage");

/**
 * **ปุ่มที่หน้าจอวาง = ผลของฟังก์ชันสองตัวนี้ตรงๆ** — คอมโพเนนต์ไม่มีเงื่อนไขสิทธิ์ของตัวเอง
 * เทสต์จึงตรวจ "ใครเห็นปุ่มอะไร" ได้ที่นี่โดยไม่ต้อง render (และกฎไม่ถูกเขียนสองที่)
 */
export const BUTTON = {
  saveDirect: "บันทึกเป็นทรัพย์",
  saveDraft: "ส่งเป็นร่าง",
  value: "ตีราคา",
  edit: "แก้ไขทรัพย์",
  propose: "เสนอแก้ไข",
} as const;

/** ปุ่มบันทึกของฟอร์มลงทะเบียน — มีปุ่มเดียวเสมอ (ไม่มีปุ่มที่กดแล้วถูกปฏิเสธ) · ไม่มีสิทธิ์ = null */
export function registerSubmitLabel(p: Perms): string | null {
  const mode = registerMode(p);
  return mode === "direct" ? BUTTON.saveDirect : mode === "draft" ? BUTTON.saveDraft : null;
}

export type SheetAction = { id: "value" | "edit" | "propose"; label: string };

/** ปุ่มท้ายแผงรายละเอียดทรัพย์ (นอกจาก "ดูทะเบียนเต็ม" ที่ทุกคนเห็น) */
export function sheetActions(p: Perms): SheetAction[] {
  const out: SheetAction[] = [];
  if (canValueAsset(p)) out.push({ id: "value", label: BUTTON.value });
  if (canEditAssetDirect(p)) out.push({ id: "edit", label: BUTTON.edit });
  if (canProposeEdit(p)) out.push({ id: "propose", label: BUTTON.propose });
  return out;
}

export function visibleDrafts(drafts: readonly AssetDraft[], p: Perms, userId: string): AssetDraft[] {
  if (p.has("asset.manage")) return [...drafts];
  if (p.has("asset.draft")) return drafts.filter((d) => d.createdBy.id === userId);
  return [];
}

export type ReviewActions = {
  approve: boolean;
  reject: boolean;
  cancel: boolean;
  /** เหตุผลที่อนุมัติไม่ได้ทั้งที่มีสิทธิ์ตรวจ — โชว์แทนปุ่ม */
  approveNote?: string;
};

/**
 * ปุ่มในแผงตรวจร่าง ตาม policy `asset_drafts_review` / `asset_drafts_update_own`
 *
 * **Manager อนุมัติร่างชนิด `create` ไม่ได้** แม้ลูกพี่ตอบ Q3 ว่าอนุมัติของตัวเองได้ —
 * `fn_apply_asset_draft()` เป็น security invoker ต้องผ่าน `assets_insert` ที่ต้องมี
 * portfolio.view_all (ดู migration ส่วน "ข" ที่บอกไว้เอง) · อนุมัติร่างชนิด `update` ได้
 * ปุ่ม "ไม่อนุมัติ" ยังโชว์ เพราะ policy review ให้ asset.manage ปฏิเสธได้ทุกชนิด
 */
export function reviewActions(p: Perms, d: AssetDraft, userId: string): ReviewActions {
  if (d.status !== "pending") return { approve: false, reject: false, cancel: false };
  const canReview = p.has("asset.manage");
  const approve = canReview && (d.kind === "update" || p.has("portfolio.view_all"));
  return {
    approve,
    reject: canReview,
    cancel: p.has("asset.draft") && d.createdBy.id === userId,
    approveNote:
      canReview && !approve
        ? "ร่างสร้างทรัพย์ใหม่ต้องให้ผู้มีสิทธิ์เพิ่มทรัพย์ลงทะเบียน (Management ขึ้นไป) เป็นคนอนุมัติ — ตำแหน่งของคุณอนุมัติได้เฉพาะร่างแก้ไขทรัพย์ที่ตนบริหาร"
        : undefined,
  };
}

/* ---------- ช่องที่ร่างได้ ---------- */

/**
 * ช่องส่วนขยายที่ฟอร์ม/แผง diff รู้จัก (ใน `patch`)
 *
 * **นี่เป็นชุดย่อยของ whitelist ฝั่ง DB** (`fn_asset_draft_patch_keys()`) ที่ mock ของทะเบียนแสดงได้จริง
 * DB เป็นตัวบังคับ — **ห้ามเพิ่มช่องที่นี่ก่อน DB** (ผู้ใช้กรอกแล้วส่งไม่ได้) · มีเทสต์เทียบกับ migration จริง
 * (`src/lib/assets/__tests__/draft-whitelist.test.ts` · `npm run check:draft-fields -- --migrations`)
 * ช่องที่ DB มีแต่ฟอร์มยังไม่รองรับ ขึ้นเป็นคำเตือน ไม่ใช่ความผิดพลาด
 */
export type PatchField = {
  key: string;
  label: string;
  /** ลบค่าออกได้ไหม — ชื่อทรัพย์ลบไม่ได้ (คอลัมน์ not null) */
  clearable: boolean;
  read: (a: AssetRef) => string | number | null | undefined;
  write: (a: AssetRef, v: string | number | null) => AssetRef;
  format: (v: string | number) => string;
  hint?: string;
};

const asText = (v: string | number) => String(v);

export const PATCH_FIELDS: readonly PatchField[] = [
  {
    key: "name",
    label: "ชื่อทรัพย์",
    clearable: false,
    read: (a) => a.name,
    write: (a, v) => ({ ...a, name: String(v) }),
    format: asText,
  },
  {
    key: "location",
    label: "ที่ตั้ง",
    clearable: true,
    read: (a) => a.location?.address,
    write: (a, v) => ({ ...a, location: { ...a.location, address: v === null ? undefined : String(v) } }),
    format: asText,
  },
  {
    key: "size_note",
    label: "ขนาด",
    clearable: true,
    read: (a) => a.legal?.sizeLabel,
    write: (a, v) => ({ ...a, legal: { ...a.legal, sizeLabel: v === null ? undefined : String(v) } }),
    format: asText,
  },
  {
    key: "funding_source",
    label: "แหล่งเงินทุน",
    clearable: true,
    read: (a) => a.fundingSource,
    write: (a, v) => ({ ...a, fundingSource: v === null ? undefined : String(v) }),
    format: asText,
  },
  {
    key: "ownership_pct",
    label: "สัดส่วนถือครอง",
    clearable: true,
    read: (a) => a.ownershipPct,
    write: (a, v) => ({ ...a, ownershipPct: v === null ? undefined : Number(v) }),
    format: (v) => `${(Number(v) * 100).toFixed(2)}%`,
    hint: "ใส่เป็นเศษส่วน เช่น 0.5 = 50%",
  },
];

const FIELD_BY_KEY = new Map(PATCH_FIELDS.map((f) => [f.key, f]));
export const patchField = (key: string) => FIELD_BY_KEY.get(key);

/** ว่าง = null · ข้อความตัดช่องว่างหัวท้าย · `undefined`/`""`/"   " ถือเป็นว่างเหมือนกัน */
export function norm(v: string | number | null | undefined): string | number | null {
  if (v === undefined || v === null) return null;
  if (typeof v === "string") {
    const t = v.trim();
    return t === "" ? null : t;
  }
  return v;
}

/* ---------- แผงเทียบความต่าง ---------- */

export type DiffChange = "changed" | "added" | "cleared" | "unchanged";

export type DiffRow = {
  key: string;
  label: string;
  /** ข้อความที่จะโชว์ · null = ว่าง (ช่องนี้ไม่มีค่า) */
  before: string | null;
  after: string | null;
  change: DiffChange;
};

export type DraftDiff = {
  rows: DiffRow[];
  /** key ที่ไม่อยู่ในช่องที่รู้จัก — ไม่โชว์เป็นแถวปกติ ผู้อนุมัติต้องเห็นว่ามีของแปลก */
  unknownKeys: string[];
  /** patch ไม่มีช่องให้แก้เลย — DB ปฏิเสธ (`asset_drafts_update_has_patch`) */
  isEmpty: boolean;
  /** ทรัพย์ปลายทางหาไม่เจอ — ไม่มีของเดิมให้เทียบ ห้ามเดาว่าของเดิมว่าง */
  targetMissing: boolean;
};

/**
 * เทียบ "ของเดิมในทะเบียนตอนนี้" กับ "ค่าที่ร่างเสนอ"
 *
 * - ของเดิมอ่านจาก**ทรัพย์จริงตอนนี้** ไม่ได้เก็บสำเนาไว้ในร่าง — ถ้าระหว่างนั้นมีคนแก้ทรัพย์
 *   ผู้อนุมัติเห็นของเดิมที่เป็นจริงตอนกดอนุมัติ ไม่ใช่ของเมื่อวาน
 * - **แยก "ไม่อยู่ใน patch" (ไม่แตะ) ออกจาก "อยู่แต่เป็น null" (ลบค่าออก)** ด้วย `in`
 *   ไม่ใช้ truthiness: เช็คแบบ `if (patch[key])` จะทำให้การลบค่าหายไปจาก diff เงียบๆ
 *   ซึ่งเป็นเคสที่ diff มักแสดงผิดที่สุด และผู้อนุมัติจะอนุมัติการลบโดยไม่เห็น
 */
export function computeDiff(draft: AssetDraft, asset: AssetRef | undefined): DraftDiff {
  const patch = draft.patch ?? {};
  const keys = Object.keys(patch);
  const rows: DiffRow[] = [];
  const unknownKeys: string[] = [];

  for (const key of keys) {
    const f = patchField(key);
    if (!f) {
      unknownKeys.push(key);
      continue;
    }
    const before = asset ? norm(f.read(asset)) : null;
    const after = norm(patch[key]);
    const change: DiffChange =
      before === after ? "unchanged" : after === null ? "cleared" : before === null ? "added" : "changed";
    rows.push({
      key,
      label: f.label,
      before: before === null ? null : f.format(before),
      after: after === null ? null : f.format(after),
      change,
    });
  }

  return {
    rows,
    unknownKeys,
    isEmpty: keys.length === 0,
    targetMissing: draft.kind === "update" && !asset,
  };
}

/** ใช้ patch กับทรัพย์ — ช่องที่ไม่อยู่ใน patch ไม่ถูกแตะ · `null` ลบค่าออก */
export function applyPatch(asset: AssetRef, patch: DraftPatch): AssetRef {
  let out = asset;
  for (const key of Object.keys(patch)) {
    const f = patchField(key);
    if (!f) throw new Error(`ช่อง ${key} ไม่อยู่ในช่องที่ร่างได้`);
    const v = norm(patch[key]);
    if (v === null && !f.clearable) throw new Error(`${f.label} ลบค่าออกไม่ได้`);
    out = f.write(out, v);
  }
  return out;
}

/* ---------- ตรวจความครบของร่าง ---------- */

export const classNameOf = (code: string | null | undefined) =>
  ASSET_CLASSES.find((c) => c.code === code)?.nameTh ?? null;

export const categoryNameOf = (code: string | null | undefined) =>
  ASSET_CLASSES.flatMap((c) => c.categories).find((c) => c.code === code)?.nameTh ?? null;

/**
 * คืนรายการสิ่งที่ผิด (ว่าง = ใช้ได้) · **ไม่เติมค่าเริ่มต้นให้** ข้อมูลไม่ครบ = ปฏิเสธ
 * (เอกสาร §9 ข้อ 17–19 · บทเรียน mace-windu ข้อ 1) — เป็นแนวเดียวกับ CHECK ของ `asset_drafts`
 * ใช้ทั้งตอนสร้างร่าง ตอนอนุมัติ และตอนแสดงร่างที่ค้างมา (ร่างเก่าที่ข้อมูลเพี้ยนต้องเห็นว่าเพี้ยน)
 */
export function validateDraft(draft: AssetDraft, assets: readonly AssetRef[]): string[] {
  const errors: string[] = [];
  const patch = draft.patch ?? {};

  const owner = HOLDERS.find((h) => h.id === draft.ownerId);
  if (!owner) errors.push("ยังไม่ได้เลือกผู้ถือ หรือผู้ถือไม่อยู่ในรายการ");

  if (draft.kind === "create") {
    if (draft.targetAssetId !== null) errors.push("ร่างสร้างทรัพย์ใหม่ต้องไม่ชี้ทรัพย์เดิม");
    if (norm(draft.name) === null) errors.push("ยังไม่ได้ใส่ชื่อทรัพย์");
    const cls = ASSET_CLASSES.find((c) => c.code === draft.classCode);
    if (!cls) errors.push("ยังไม่ได้เลือกหมวดใหญ่");
    if (!draft.categoryCode) errors.push("ยังไม่ได้เลือกหมวดย่อย");
    else if (cls && !cls.categories.some((c) => c.code === draft.categoryCode))
      errors.push("หมวดย่อยไม่อยู่ในหมวดใหญ่ที่เลือก");
  } else {
    if (!draft.targetAssetId) errors.push("ร่างแก้ไขต้องระบุทรัพย์ที่จะแก้");
    else {
      const target = assets.find((a) => a.id === draft.targetAssetId);
      if (!target) errors.push("ไม่พบทรัพย์ที่ร่างนี้จะแก้ในทะเบียน");
      else if (target.ownerId !== draft.ownerId) errors.push("ผู้ถือของร่างไม่ตรงกับผู้ถือของทรัพย์");
    }
    if (draft.name !== null || draft.classCode !== null || draft.categoryCode !== null)
      errors.push("ร่างแก้ไขต้องส่งช่องที่แก้ผ่าน patch เท่านั้น");
    if (Object.keys(patch).length === 0) errors.push("ร่างแก้ไขนี้ไม่มีช่องที่เสนอแก้เลย");
  }

  for (const key of Object.keys(patch)) {
    const f = patchField(key);
    if (!f) {
      errors.push(`ช่อง "${key}" ไม่อยู่ในช่องที่ร่างได้`);
      continue;
    }
    const v = norm(patch[key]);
    if (v === null && !f.clearable) errors.push(`${f.label} ลบค่าออกไม่ได้`);
    if (key === "ownership_pct" && v !== null && !(typeof v === "number" && v > 0 && v <= 1))
      errors.push("สัดส่วนถือครองต้องมากกว่า 0 และไม่เกิน 1 (เช่น 0.5 = 50%)");
  }

  return errors;
}

export function fmtDateTime(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  // ใช้เขตเวลาไทยตายตัว — เซิร์ฟเวอร์ (UTC) กับเบราว์เซอร์ต้องแสดงตรงกัน ไม่งั้น hydration เพี้ยน
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Asia/Bangkok",
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).formatToParts(d);
  const g = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  return `${g("day")}/${g("month")}/${g("year")} ${g("hour")}:${g("minute")}`;
}

export const STATUS_LABEL: Record<AssetDraft["status"], string> = {
  pending: "รออนุมัติ",
  approved: "อนุมัติแล้ว",
  rejected: "ไม่อนุมัติ",
  cancelled: "ยกเลิกแล้ว",
};
