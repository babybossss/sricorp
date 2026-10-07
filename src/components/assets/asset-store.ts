"use client";

import { create } from "zustand";
import {
  ASSETS, ASSET_DRAFTS, HOLDING_BY_CATEGORY,
  type AssetRef, type AssetDraft, type DraftPatch,
} from "@/lib/mock/assets";
import {
  applyPatch, canRegisterDirect, canSubmitDraft, norm, reviewActions, validateDraft, type Perms,
} from "./asset-drafts";

/**
 * ทะเบียนทรัพย์ + คิวร่าง (จำลองในหน่วยความจำ — ยังไม่ต่อ DB)
 *
 * **สองก้อนแยกกันเด็ดขาด** เหมือน `assets` กับ `asset_drafts` ใน DB (ADR 0001):
 * - `assets`  = ทรัพย์ที่อนุมัติแล้ว → **ทุกยอดรวมในหน้าบริหารสินทรัพย์อ่านจากก้อนนี้ก้อนเดียว**
 * - `drafts`  = ร่าง → ไม่เคยถูกส่งเข้า `portfolioTotals()` / `holdingMix()`
 * ร่างย้ายเข้า `assets` ได้ทางเดียวคือ `approveDraft()` (= `fn_apply_asset_draft()` ใน DB)
 *
 * action ทุกตัวรับสิทธิ์ของผู้กระทำและ **throw เมื่อไม่มีสิทธิ์** เลียนแบบที่ RLS ปฏิเสธ
 * เพื่อให้เทสต์พิสูจน์ได้ว่า "ปุ่มที่ซ่อนไว้ ต่อให้ถูกเรียกตรงๆ ก็ไม่ผ่าน" — แต่นี่ยังเป็นของจำลอง
 * ความปลอดภัยจริงคือ RLS ใน DB (ดู `asset-drafts.ts`)
 */

export type Actor = { id: string; name: string; permissions: Perms };

/** ไม่มีสิทธิ์ทำสิ่งนี้ (เทียบเท่า `violates row-level security policy`) */
export class AssetDenied extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AssetDenied";
  }
}

/** ข้อมูลไม่ครบ/ไม่ถูกต้อง — `errors` คือรายการที่แก้ได้ทีละข้อ */
export class AssetInvalid extends Error {
  constructor(public readonly errors: string[]) {
    super(errors.join(" · "));
    this.name = "AssetInvalid";
  }
}

export type NewAssetInput = {
  /** 4 ช่องบังคับ (D-083) */
  name: string;
  classCode: string;
  categoryCode: string;
  ownerId: string;
  /** ส่วนขยาย — ไม่บังคับ */
  patch?: DraftPatch;
  note?: string;
};

type AssetStore = {
  assets: AssetRef[];
  drafts: AssetDraft[];
  registerAsset: (input: NewAssetInput, actor: Actor) => AssetRef;
  submitDraft: (input: NewAssetInput, actor: Actor) => AssetDraft;
  proposeUpdate: (targetAssetId: string, patch: DraftPatch, actor: Actor, note?: string) => AssetDraft;
  approveDraft: (id: string, actor: Actor) => AssetDraft;
  rejectDraft: (id: string, reason: string, actor: Actor) => AssetDraft;
  cancelDraft: (id: string, actor: Actor) => AssetDraft;
};

let seq = 100;
const nextId = (prefix: string) => `${prefix}${++seq}`;
const nowIso = () => new Date().toISOString();

function seedState() {
  return { assets: [...ASSETS], drafts: ASSET_DRAFTS.map((d) => ({ ...d })) };
}

function toDraft(input: NewAssetInput, actor: Actor): AssetDraft {
  return {
    id: nextId("d"),
    kind: "create",
    targetAssetId: null,
    ownerId: input.ownerId,
    name: norm(input.name) === null ? null : String(norm(input.name)),
    classCode: input.classCode || null,
    categoryCode: input.categoryCode || null,
    patch: stripEmpty(input.patch ?? {}),
    note: input.note?.trim() || undefined,
    status: "pending",
    createdBy: { id: actor.id, name: actor.name },
    createdAt: nowIso(),
  };
}

/**
 * ฟอร์มสร้างใหม่: ช่องส่วนขยายที่เว้นว่าง = ไม่ส่ง (ทรัพย์ใหม่ไม่มีของเดิมให้ "ลบ")
 * ฟอร์มแก้ไขไม่ผ่านฟังก์ชันนี้ — ช่องที่ผู้ใช้เคลียร์ต้องคง null ไว้ให้ diff เห็นว่าลบ
 */
function stripEmpty(patch: DraftPatch): DraftPatch {
  const out: DraftPatch = {};
  for (const [k, v] of Object.entries(patch)) if (norm(v) !== null) out[k] = norm(v);
  return out;
}

function assetFromDraft(d: AssetDraft): AssetRef {
  const base: AssetRef = {
    id: nextId("a"),
    name: String(norm(d.name)),
    // ชนิดทรัพย์/ประเภทการถือ: 4 ช่องไม่บอก → ไม่เดา (ดู HOLDING_BY_CATEGORY)
    kind: "other",
    holding: HOLDING_BY_CATEGORY[d.categoryCode ?? ""] ?? "unset",
    ownerId: d.ownerId,
    cost: 0,
    status: "active",
    recurring: [],
    classCode: d.classCode ?? undefined,
    categoryCode: d.categoryCode ?? undefined,
  };
  return applyPatch(base, d.patch);
}

export const useAssetStore = create<AssetStore>((set, get) => ({
  ...seedState(),

  registerAsset(input, actor) {
    if (!canRegisterDirect(actor.permissions))
      throw new AssetDenied("ไม่มีสิทธิ์บันทึกเป็นทรัพย์จริง — ต้องส่งเป็นร่างให้ผู้มีสิทธิ์อนุมัติ");
    const draft = toDraft(input, actor);
    const errors = validateDraft(draft, get().assets);
    if (errors.length) throw new AssetInvalid(errors);
    const asset = assetFromDraft(draft);
    set((s) => ({ assets: [...s.assets, asset] }));
    return asset;
  },

  submitDraft(input, actor) {
    if (!canSubmitDraft(actor.permissions)) throw new AssetDenied("ไม่มีสิทธิ์เสนอร่างทะเบียนทรัพย์");
    const draft = toDraft(input, actor);
    const errors = validateDraft(draft, get().assets);
    if (errors.length) throw new AssetInvalid(errors);
    set((s) => ({ drafts: [...s.drafts, draft] }));
    return draft;
  },

  proposeUpdate(targetAssetId, patch, actor, note) {
    if (!canSubmitDraft(actor.permissions)) throw new AssetDenied("ไม่มีสิทธิ์เสนอร่างทะเบียนทรัพย์");
    const target = get().assets.find((a) => a.id === targetAssetId);
    const draft: AssetDraft = {
      id: nextId("d"),
      kind: "update",
      targetAssetId,
      // ผู้ถือของร่างต้องตรงกับทรัพย์ (policy asset_drafts_insert) · ไม่มีทรัพย์ → ว่าง ให้ validate ฟ้อง
      ownerId: target?.ownerId ?? "",
      name: null,
      classCode: null,
      categoryCode: null,
      patch,
      note: note?.trim() || undefined,
      status: "pending",
      createdBy: { id: actor.id, name: actor.name },
      createdAt: nowIso(),
    };
    const errors = validateDraft(draft, get().assets);
    if (errors.length) throw new AssetInvalid(errors);
    set((s) => ({ drafts: [...s.drafts, draft] }));
    return draft;
  },

  approveDraft(id, actor) {
    const d = get().drafts.find((x) => x.id === id);
    if (!d) throw new AssetInvalid([`ไม่พบร่าง ${id}`]);
    if (d.status !== "pending") throw new AssetInvalid([`ร่างนี้อยู่สถานะ ${d.status} แล้ว อนุมัติซ้ำไม่ได้`]);
    if (!reviewActions(actor.permissions, d, actor.id).approve)
      throw new AssetDenied("ไม่มีสิทธิ์อนุมัติร่างนี้");
    // ตรวจซ้ำตอนอนุมัติ — ร่างที่ค้างมาอาจเพี้ยน (ทรัพย์ปลายทางถูกย้ายผู้ถือ ฯลฯ)
    const errors = validateDraft(d, get().assets);
    if (errors.length) throw new AssetInvalid(errors);

    let appliedId: string;
    let assets: AssetRef[];
    if (d.kind === "create") {
      const created = assetFromDraft(d);
      appliedId = created.id;
      assets = [...get().assets, created];
    } else {
      appliedId = d.targetAssetId as string;
      assets = get().assets.map((a) => (a.id === appliedId ? applyPatch(a, d.patch) : a));
    }
    const done: AssetDraft = {
      ...d,
      status: "approved",
      appliedAssetId: appliedId,
      reviewedBy: { id: actor.id, name: actor.name },
      reviewedAt: nowIso(),
    };
    set((s) => ({ assets, drafts: s.drafts.map((x) => (x.id === id ? done : x)) }));
    return done;
  },

  rejectDraft(id, reason, actor) {
    const d = get().drafts.find((x) => x.id === id);
    if (!d) throw new AssetInvalid([`ไม่พบร่าง ${id}`]);
    if (d.status !== "pending") throw new AssetInvalid([`ร่างนี้อยู่สถานะ ${d.status} แล้ว`]);
    if (!reviewActions(actor.permissions, d, actor.id).reject) throw new AssetDenied("ไม่มีสิทธิ์ปฏิเสธร่างนี้");
    // ปฏิเสธโดยไม่บอกเหตุผล = คนคีย์แก้ไม่ถูก (CHECK asset_drafts_reject_reason)
    if (norm(reason) === null) throw new AssetInvalid(["ต้องใส่เหตุผลที่ไม่อนุมัติ"]);
    const done: AssetDraft = {
      ...d,
      status: "rejected",
      rejectReason: String(norm(reason)),
      reviewedBy: { id: actor.id, name: actor.name },
      reviewedAt: nowIso(),
    };
    set((s) => ({ drafts: s.drafts.map((x) => (x.id === id ? done : x)) }));
    return done;
  },

  cancelDraft(id, actor) {
    const d = get().drafts.find((x) => x.id === id);
    if (!d) throw new AssetInvalid([`ไม่พบร่าง ${id}`]);
    if (d.status !== "pending") throw new AssetInvalid([`ร่างนี้อยู่สถานะ ${d.status} แล้ว`]);
    if (!reviewActions(actor.permissions, d, actor.id).cancel)
      throw new AssetDenied("ยกเลิกได้เฉพาะร่างของตัวเองที่ยังรออนุมัติ");
    // CHECK asset_drafts_reviewed_pair: ออกจาก pending แล้ว reviewed_by/at ต้องไม่ว่าง — ยกเลิกเองก็เช่นกัน
    const done: AssetDraft = {
      ...d,
      status: "cancelled",
      reviewedBy: { id: actor.id, name: actor.name },
      reviewedAt: nowIso(),
    };
    set((s) => ({ drafts: s.drafts.map((x) => (x.id === id ? done : x)) }));
    return done;
  },
}));

/** คืนสถานะเริ่มต้น — ให้เทสต์ใช้ */
export function resetAssetStore() {
  useAssetStore.setState(seedState());
}
