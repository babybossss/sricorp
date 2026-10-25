/**
 * ตัวช่วยร่วมของเทสต์หน้าทรัพย์ — ตั้ง mock ของ server ให้ชี้ไป DB จำลองตัวเดียว
 * (เรียก `installAssetsMocks()` ในไฟล์เทสต์ที่ตำแหน่งบนสุดเท่านั้น เพราะ vi.mock ถูกยกขึ้นบนสุด)
 */
import { vi } from "vitest";
import { createAssetsFakeDb, ASSETS, CAT, CLASS, USERS, VIEW, type AssetsFakeDb, type Viewer } from "./assets-fake-db";
import { COA_BY_ID, OWNER, BANK, CONTACT, referenceFixture } from "@/app/actions/__tests__/fake-db";
import type { Reference } from "@/lib/db/reference-types";

export { ASSETS, CAT, CLASS, USERS, VIEW, OWNER, BANK, CONTACT };

export const env = {
  db: null as unknown as AssetsFakeDb,
  access: null as unknown as { user: { id: string; email: string } | null; permissions: Set<string>; profile: null; error: string | null },
  reference: null as unknown as { ok: true; ref: Reference },
};

/** vi.mock ต้องอยู่ในไฟล์เทสต์เอง (hoist) — ไฟล์นี้ให้ factory ที่ใช้ซ้ำ */
export const mockFactories = {
  supabase: () => ({ createClient: async () => env.db.client }),
  session: () => ({ getAccess: async () => env.access }),
  reference: () => ({ loadReference: async () => env.reference }),
  cache: () => ({ revalidatePath: vi.fn() }),
};

export function fresh(): AssetsFakeDb {
  env.db = createAssetsFakeDb();
  env.reference = { ok: true, ref: { ...referenceFixture(), coaCodeById: COA_BY_ID } };
  as(VIEW.management());
  return env.db;
}

/** เปลี่ยนผู้ใช้ที่กำลังดู — DB จำลองกับ getAccess() ต้องเปลี่ยนพร้อมกันเสมอ */
export function as(v: Viewer) {
  env.db.setViewer(v);
  env.access = { user: { id: v.id, email: "u@x" }, permissions: new Set(v.perms), profile: null, error: null };
}

/** ทรัพย์ชุดมาตรฐาน: ห้อง A/B (ธนากร ตึกเดียวกัน) · บ้าน C (สุธี) · หุ้น D (SRI Corporation) */
export function seedAssets(db: AssetsFakeDb, managerOf: Partial<Record<keyof typeof ASSETS, string>> = {}) {
  db.addAsset({ id: ASSETS.roomA, name: "คอนโด ห้อง A", owner_id: OWNER.tk, location: "คอนโดตึกสุขุมวิท", property_type: "คอนโด", tags: ["สุขุมวิท"], manager_user_id: managerOf.roomA ?? null });
  db.addAsset({ id: ASSETS.roomB, name: "คอนโด ห้อง B", owner_id: OWNER.tk, location: "คอนโดตึกสุขุมวิท", property_type: "คอนโด", manager_user_id: managerOf.roomB ?? null });
  db.addAsset({ id: ASSETS.houseC, name: "บ้านเดี่ยว C", owner_id: OWNER.sutee, location: "นนทบุรี", category_id: CAT.RE_FOR_SALE, manager_user_id: managerOf.houseC ?? null });
  db.addAsset({ id: ASSETS.stockD, name: "หุ้น D", owner_id: OWNER.corp, class_id: CLASS.PAPER, category_id: CAT.PAPER_STOCK, ticker: "AAA", manager_user_id: managerOf.stockD ?? null });
}
