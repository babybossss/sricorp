import { env, mockFactories, ASSETS, CAT, CLASS, USERS, VIEW, OWNER, fresh, as, seedAssets } from "@/lib/db/__tests__/assets-test-env";
import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("@/lib/supabase/server", () => mockFactories.supabase());
vi.mock("@/lib/auth/session", () => mockFactories.session());
vi.mock("@/lib/db/reference", () => mockFactories.reference());
vi.mock("next/cache", () => mockFactories.cache());

import {
  approveAssetDraft, cancelAssetDraft, editAssetDirect, proposeAssetEdit, recordValuation, registerAsset, rejectAssetDraft,
} from "../actions";

/**
 * server action ของทะเบียนทรัพย์ — เขียน DB จริง (จำลอง) ด้วย session ของผู้ใช้ · ด่านสิทธิ์คือ RLS
 * ข้อมูลไม่ครบต้องปฏิเสธ **ก่อนเขียนอะไร** (ทุกเคสตรวจ `writes` ว่าว่าง)
 */

const base = { name: "ห้องใหม่ 301", classId: CLASS.RE, categoryId: CAT.RE_RENTAL, ownerId: OWNER.tk };
const writes = () => env.db.writes;

beforeEach(() => {
  fresh();
  seedAssets(env.db);
});

describe("ลงทะเบียนทรัพย์", () => {
  it("Management: บันทึกเป็นทรัพย์จริง ออกรหัสให้ ใส่ช่องเสริมครบ (ป้ายกำกับเป็นรายการ สัดส่วนเป็นเศษส่วน)", async () => {
    const out = await registerAsset({ ...base, patch: { location: "  พหลโยธิน  ", ownership_pct: 0.5, tags: ["ห้อง 301", "พหลโยธิน"], size_note: "" } });
    expect(out.ok).toBe(true);
    const a = env.db.tables.assets.find((x) => x.name === "ห้องใหม่ 301")!;
    expect(a).toMatchObject({ owner_id: OWNER.tk, location: "พหลโยธิน", ownership_pct: 0.5, tags: ["ห้อง 301", "พหลโยธิน"] });
    expect(a.code).toMatch(/^RE-/);
    expect("size_note" in (env.db.tables.asset_drafts[0].patch as object)).toBe(false); // ช่องว่างไม่ถูกส่ง
    expect(env.db.tables.asset_drafts[0]).toMatchObject({ status: "approved", applied_asset_id: a.id });
  });

  it("Staff: ได้แค่ร่าง ไม่มีทรัพย์ใหม่ในทะเบียน", async () => {
    as(VIEW.staff());
    const before = env.db.tables.assets.length;
    const out = await registerAsset(base);
    expect(out).toMatchObject({ ok: true });
    expect(env.db.tables.assets).toHaveLength(before);
    expect(env.db.tables.asset_drafts).toHaveLength(1);
    expect(env.db.tables.asset_drafts[0]).toMatchObject({ status: "pending", kind: "create", created_by: USERS.staff });
  });

  it("Manager: เส้นทางร่าง (INSERT ตรงไม่ได้) — ไม่ลองบันทึกตรงแล้วโดนปฏิเสธ", async () => {
    as(VIEW.manager());
    await registerAsset(base);
    expect(env.db.tables.asset_drafts[0].status).toBe("pending");
    expect(env.db.tables.assets.find((a) => a.name === base.name)).toBeUndefined();
  });

  it("ข้อมูลไม่ครบ/ผิด → ปฏิเสธก่อนเขียน (ไม่เดาค่าเริ่มต้น)", async () => {
    for (const over of [
      { name: "   " }, { classId: "" }, { categoryId: "" }, { ownerId: "" }, { ownerId: "nobody" },
      { ownerId: OWNER.planned }, // ผู้ถือที่ยังไม่จดทะเบียน
      { classId: CLASS.PAPER }, // หมวดย่อยไม่อยู่ในหมวดใหญ่
    ]) {
      const out = await registerAsset({ ...base, ...over });
      expect(out.ok).toBe(false);
    }
    expect(writes()).toHaveLength(0);
    expect(env.db.tables.asset_drafts).toHaveLength(0);
  });

  it("ช่องที่ DB ไม่อนุญาตใน patch (เช่น ผู้บริหารทรัพย์ · ชื่อซ้ำใน patch) → ปฏิเสธ", async () => {
    expect((await registerAsset({ ...base, patch: { manager_user_id: USERS.admin } })).ok).toBe(false);
    expect((await registerAsset({ ...base, patch: { name: "อีกชื่อ" } })).ok).toBe(false);
    expect((await registerAsset({ ...base, patch: { ownership_pct: 1.5 } })).ok).toBe(false);
    expect(writes()).toHaveLength(0);
  });

  it("ไม่มีสิทธิ์เสนอร่างเลย → ไม่เขียน", async () => {
    as({ id: USERS.other, owners: "all", perms: new Set(["ledger.read"]) });
    const out = await registerAsset(base);
    expect(out.ok).toBe(false);
    expect(writes()).toHaveLength(0);
  });

  it("ลงทะเบียนตรงแล้วอนุมัติล้ม → ร่างที่สร้างไว้ถูกยกเลิก ไม่ทิ้งร่างค้าง", async () => {
    const real = env.db.client.rpc;
    env.db.client.rpc = ((fn: string, a: Record<string, unknown>) =>
      fn === "fn_apply_asset_draft" ? Promise.resolve({ data: null, error: { message: "boom" } }) : real(fn, a)) as never;
    const out = await registerAsset(base);
    expect(out.ok).toBe(false);
    expect(env.db.tables.asset_drafts[0].status).toBe("cancelled");
    expect(env.db.tables.assets.find((a) => a.name === base.name)).toBeUndefined();
  });
});

describe("ตรวจร่าง", () => {
  async function staffDraft() {
    as(VIEW.staff());
    const out = await registerAsset(base);
    if (!out.ok) throw new Error(out.message);
    return out.id!;
  }

  it("Management อนุมัติ → ทรัพย์เกิดจริงหนึ่งชิ้น · อนุมัติซ้ำไม่สร้างซ้ำ", async () => {
    const id = await staffDraft();
    as(VIEW.management());
    const n = env.db.tables.assets.length;
    expect((await approveAssetDraft(id)).ok).toBe(true);
    expect(env.db.tables.assets).toHaveLength(n + 1);
    const again = await approveAssetDraft(id);
    expect(again.ok).toBe(false);
    expect(env.db.tables.assets).toHaveLength(n + 1);
  });

  it("Manager อนุมัติร่างสร้างทรัพย์ไม่ได้ (DB ปฏิเสธ) — ไม่มีทรัพย์เกิด ร่างยัง pending", async () => {
    const id = await staffDraft();
    as(VIEW.manager());
    const n = env.db.tables.assets.length;
    const out = await approveAssetDraft(id);
    expect(out.ok).toBe(false);
    expect(env.db.tables.assets).toHaveLength(n);
    expect(env.db.tables.asset_drafts[0].status).toBe("pending");
  });

  it("ไม่อนุมัติต้องมีเหตุผล · Staff ไม่อนุมัติร่างของตัวเอง/คนอื่นไม่ได้", async () => {
    const id = await staffDraft();
    as(VIEW.management());
    const w = writes().length;
    expect((await rejectAssetDraft(id, "   ")).ok).toBe(false);
    expect(writes().length).toBe(w);
    as(VIEW.staff());
    const denied = await rejectAssetDraft(id, "ขอปฏิเสธเอง");
    expect(denied.ok).toBe(false);
    expect(env.db.tables.asset_drafts[0].status).toBe("pending");
    as(VIEW.management());
    expect((await rejectAssetDraft(id, "ชื่อซ้ำกับห้องเดิม")).ok).toBe(true);
    expect(env.db.tables.asset_drafts[0]).toMatchObject({ status: "rejected", reject_reason: "ชื่อซ้ำกับห้องเดิม", reviewed_by: USERS.admin });
  });

  it("ยกเลิกได้เฉพาะร่างของตัวเอง", async () => {
    const id = await staffDraft();
    as({ ...VIEW.staff(), id: USERS.other });
    expect((await cancelAssetDraft(id)).ok).toBe(false);
    expect(env.db.tables.asset_drafts[0].status).toBe("pending");
    as(VIEW.staff());
    expect((await cancelAssetDraft(id)).ok).toBe(true);
    expect(env.db.tables.asset_drafts[0]).toMatchObject({ status: "cancelled", reviewed_by: USERS.staff });
  });

  it("ร่างแก้ไข: ผู้ถือของร่างอ่านจากทรัพย์เอง · อนุมัติแล้วทะเบียนเปลี่ยน · ลบค่า (null) ลบจริง", async () => {
    env.db.tables.assets.find((a) => a.id === ASSETS.roomA)!.size_note = "28 ตร.ม.";
    as(VIEW.staff());
    const sent = await proposeAssetEdit({ assetId: ASSETS.roomA, patch: { size_note: null, name: "ห้อง A (ปรับชื่อ)" } });
    if (!sent.ok) throw new Error(sent.message);
    expect(env.db.tables.asset_drafts[0]).toMatchObject({ kind: "update", owner_id: OWNER.tk, patch: { size_note: null, name: "ห้อง A (ปรับชื่อ)" } });
    // ร่างยังไม่เปลี่ยนทะเบียน
    expect(env.db.tables.assets.find((a) => a.id === ASSETS.roomA)!.size_note).toBe("28 ตร.ม.");
    as(VIEW.management());
    expect((await approveAssetDraft(sent.id!)).ok).toBe(true);
    expect(env.db.tables.assets.find((a) => a.id === ASSETS.roomA)).toMatchObject({ size_note: null, name: "ห้อง A (ปรับชื่อ)" });
  });

  it("ร่างแก้ไขที่ patch ว่าง / ชี้ทรัพย์ที่ไม่มี → ปฏิเสธก่อนเขียน", async () => {
    as(VIEW.staff());
    expect((await proposeAssetEdit({ assetId: ASSETS.roomA, patch: {} })).ok).toBe(false);
    expect((await proposeAssetEdit({ assetId: "99999999-9999-4999-8999-999999999999", patch: { location: "x" } })).ok).toBe(false);
    expect(writes()).toHaveLength(0);
  });
});

describe("แก้ตรง", () => {
  it("Management แก้ได้ · ช่องว่างลบค่า · ผู้ถือ/ผู้บริหาร/รหัสแก้ผ่านทางนี้ไม่ได้", async () => {
    expect((await editAssetDirect({ assetId: ASSETS.roomA, patch: { location: " สุขุมวิท 24 ", tags: ["a", "a ", "b"] } })).ok).toBe(true);
    const a = env.db.tables.assets.find((x) => x.id === ASSETS.roomA)!;
    expect(a.location).toBe("สุขุมวิท 24");
    for (const bad of [{ owner_id: OWNER.sutee }, { manager_user_id: USERS.admin }, { code: "X-1" }, { status: "sold" }]) {
      expect((await editAssetDirect({ assetId: ASSETS.roomA, patch: bad as never })).ok).toBe(false);
    }
    expect(a.owner_id).toBe(OWNER.tk);
    expect((await editAssetDirect({ assetId: ASSETS.roomA, patch: { name: null } })).ok).toBe(false);
  });

  it("Staff แก้ตรงไม่ได้ — DB ไม่แก้ให้ (0 แถว) และทะเบียนไม่เปลี่ยน", async () => {
    as(VIEW.staff());
    const out = await editAssetDirect({ assetId: ASSETS.roomA, patch: { location: "แก้เอง" } });
    expect(out.ok).toBe(false);
    expect(env.db.tables.assets.find((a) => a.id === ASSETS.roomA)!.location).toBe("คอนโดตึกสุขุมวิท");
  });

  it("Manager แก้ได้เฉพาะทรัพย์ที่ตนบริหาร", async () => {
    env.db.tables.assets.find((a) => a.id === ASSETS.roomA)!.manager_user_id = USERS.manager;
    as(VIEW.manager());
    expect((await editAssetDirect({ assetId: ASSETS.roomA, patch: { location: "ใหม่" } })).ok).toBe(true);
    const other = await editAssetDirect({ assetId: ASSETS.roomB, patch: { location: "ใหม่" } });
    expect(other.ok).toBe(false);
    expect(env.db.tables.assets.find((a) => a.id === ASSETS.roomB)!.location).toBe("คอนโดตึกสุขุมวิท");
  });
});

describe("ตีราคา", () => {
  const val = { assetId: ASSETS.roomA, asOf: "30/09/2026", value: "3,900,000", method: "manual" };

  it("Management: เพิ่มประวัติใหม่ ไม่ลงสมุด · ครั้งที่สองไม่ทับครั้งแรก", async () => {
    expect((await recordValuation(val)).ok).toBe(true);
    expect((await recordValuation({ ...val, asOf: "24/10/2026", value: "4000000" })).ok).toBe(true);
    expect(env.db.tables.asset_valuations).toHaveLength(2);
    expect(env.db.tables.asset_valuations[0]).toMatchObject({ value: 3_900_000, as_of: "2026-09-30", created_by: USERS.admin });
    expect(env.db.base.rows).toHaveLength(0); // ไม่แตะสมุด
  });

  it("Manager ตีราคาไม่ได้ (asset.value) — DB ปฏิเสธ ไม่มีแถว", async () => {
    env.db.tables.assets.find((a) => a.id === ASSETS.roomA)!.manager_user_id = USERS.manager;
    as(VIEW.manager());
    const out = await recordValuation(val);
    expect(out.ok).toBe(false);
    expect(env.db.tables.asset_valuations).toHaveLength(0);
  });

  it("ข้อมูลไม่ครบ/ไม่ถูกต้อง · ทรัพย์สกุลต่างประเทศ → ปฏิเสธก่อนเขียน", async () => {
    for (const over of [{ asOf: "" }, { asOf: "31/02/2026" }, { asOf: "01/01/2999" }, { asOf: "30/09/2569" }, { value: "" }, { value: "abc" }, { value: "0" }, { value: "-5" }, { method: "market_api" }, { method: "" }, { assetId: "99999999-9999-4999-8999-999999999999" }]) {
      expect((await recordValuation({ ...val, ...over })).ok).toBe(false);
    }
    env.db.tables.assets.find((a) => a.id === ASSETS.roomA)!.currency = "USD";
    const usd = await recordValuation(val);
    expect(usd.ok).toBe(false);
    if (!usd.ok) expect(usd.message).toMatch(/USD/);
    expect(writes()).toHaveLength(0);
  });
});

it("ไม่มีเส้นทางลบข้อมูลทะเบียนในโค้ด action", async () => {
  const { readFileSync } = await import("node:fs");
  const src = readFileSync(new URL("../actions.ts", import.meta.url), "utf8");
  expect(src).not.toMatch(/\.delete\(/);
});
