import "./mocks";
import { beforeEach, describe, expect, it } from "vitest";
import { ctx, resetCtx } from "./ctx";
import { ASSET, BANK, CONTACT, OWNER } from "./fake-db";
import { TAG, TXN, installTagDb } from "./tag-fake";
import { postEntry, type PostEntryRequest } from "../post-entry";
import { loadTagCatalog, reallocateTags, type ReallocateRequest } from "../tags";
import type { PostingInput } from "@/lib/ledger/types";

/**
 * ชั้นแอปของการถ่วงน้ำหนัก tag (ADR 0003) · DB ครอบด้วยสัญญาตาม ADR (ดู tag-fake.ts)
 * ทุกเคสปฏิเสธต้องพิสูจน์ว่า **ไม่เรียก DB เขียนอะไร** — ไม่ใช่แค่ตอบว่าไม่ผ่าน
 */
let db: ReturnType<typeof installTagDb>;

beforeEach(() => {
  resetCtx();
  ctx.access.permissions = new Set(["ledger.approve", "txn.create", "tag.assign"]);
  db = installTagDb();
});

describe("loadTagCatalog", () => {
  it("คืนเฉพาะ tag ที่เปิดใช้งาน + กติกาของชนิดจากคอนฟิก (requiresAllocation)", async () => {
    const out = await loadTagCatalog();
    expect(out.ok).toBe(true);
    if (!out.ok) return;
    expect(out.kinds.map((k) => [k.key, k.requiresAllocation])).toEqual([["project", true], ["label", false]]);
    expect(out.tags.map((t) => t.id).sort()).toEqual([TAG.p1, TAG.p2, TAG.p3, TAG.l1, TAG.l2].sort()); // ไม่มี pOff และ tag ของชนิดที่ไม่รู้จัก
    expect(out.tags.find((t) => t.id === TAG.p1)).toEqual({ id: TAG.p1, kind: "project", code: "iris-235", nameTh: "ไอริส 235", isActive: true, colorToken: "brand" });
  });

  it("ยังไม่ได้ลง migration → ok:false บอกตรงๆ ไม่คืนแค็ตตาล็อกว่าง", async () => {
    db.migrated = false;
    const out = await loadTagCatalog();
    expect(out).toMatchObject({ ok: false, notMigrated: true });
    if (!out.ok) expect(out.message).toMatch(/ยังไม่ได้ลง migration/);
  });

  it("requires_allocation อ่านไม่ได้ (null) → ปฏิเสธทั้งก้อน ไม่เดาเป็น false", async () => {
    db.kinds[0].requires_allocation = null;
    const out = await loadTagCatalog();
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.message).toMatch(/ไม่ครบ/);
  });

  it("ยังไม่ล็อกอิน → ok:false", async () => {
    ctx.access.user = null;
    expect((await loadTagCatalog()).ok).toBe(false);
  });
});

describe("reallocateTags · แก้สัดส่วนของใบที่ลงแล้ว", () => {
  const link = (tagId: string, kind = "project") => db.links.push({ transaction_id: TXN, tag_id: tagId, tag_kind: kind, untagged_at: null });
  const R = (over: Partial<ReallocateRequest> = {}): ReallocateRequest => ({
    transactionId: TXN,
    kind: "project",
    weights: { [TAG.p1]: 0.6, [TAG.p2]: 0.4 },
    reason: "ลูกพี่ปรับสัดส่วนตามสัญญา",
    ...over,
  });
  const refused = async (r: ReallocateRequest | undefined, needle: RegExp | string) => {
    const out = await reallocateTags(r as ReallocateRequest);
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.message).toMatch(needle);
    expect(db.reallocCalls).toHaveLength(0);
  };

  beforeEach(() => {
    link(TAG.p1);
    link(TAG.p2);
  });

  it("60/40 ครบ → เรียก fn_reallocate_tags ครั้งเดียวด้วยสัดส่วนตามที่ตรวจแล้ว + เหตุผลที่ตัดช่องว่าง", async () => {
    const out = await reallocateTags(R({ reason: "  ปรับสัดส่วน  " }));
    expect(out).toEqual({ ok: true, transactionIds: [TXN] });
    expect(db.reallocCalls).toHaveLength(1);
    expect(db.reallocCalls[0].args).toEqual({
      p_transaction_id: TXN,
      p_kind: "project",
      p_weights: { [TAG.p1]: 0.6, [TAG.p2]: 0.4 },
      p_reason: "ปรับสัดส่วน",
    });
  });

  it("ไม่ส่งน้ำหนักมาเลย (undefined / null / {} / อาร์เรย์) → ปฏิเสธ ไม่เดาเป็น 100%", async () => {
    for (const w of [undefined, null, {}, []]) await refused(R({ weights: w as never }), /ยังไม่ได้ใส่สัดส่วน|ไม่ได้ส่งสัดส่วน/);
  });

  it("ใบที่ติด project อันเดียวแต่ไม่ส่งน้ำหนัก → ปฏิเสธ (server ไม่เติม 100% ให้)", async () => {
    db.links.length = 0;
    link(TAG.p1);
    await refused(R({ weights: {} }), /ยังไม่ได้ใส่สัดส่วน/);
  });

  it.each([
    ["ขาด 0.000001", { [TAG.p1]: 0.6, [TAG.p2]: 0.399999 }, /ขาดอีก 0\.0001%/],
    ["เกิน 0.000001", { [TAG.p1]: 0.6, [TAG.p2]: 0.400001 }, /เกินอยู่ 0\.0001%/],
    ["ขาดมาก", { [TAG.p1]: 0.5, [TAG.p2]: 0.3 }, /ขาดอีก 20%/],
    ["เกินมาก", { [TAG.p1]: 0.7, [TAG.p2]: 0.5 }, /เกินอยู่ 20%/],
  ])("Σ ≠ 100%: %s → ปฏิเสธ บอกยอดที่ขาด/เกิน", async (_n, weights, needle) => {
    await refused(R({ weights }), needle);
  });

  it("น้ำหนัก 0 · > 1 · ติดลบ · ทศนิยมเกิน 6 ตำแหน่ง · ไม่ใช่ตัวเลข → ปฏิเสธ", async () => {
    await refused(R({ weights: { [TAG.p1]: 1, [TAG.p2]: 0 } }), /0 ไม่ได้/);
    await refused(R({ weights: { [TAG.p1]: 1.5, [TAG.p2]: 0.4 } }), /เกิน 100%/);
    await refused(R({ weights: { [TAG.p1]: -0.2, [TAG.p2]: 1.2 } }), /ติดลบ/);
    await refused(R({ weights: { [TAG.p1]: 0.3333333, [TAG.p2]: 0.6666667 } }), /เกิน 6 ตำแหน่ง/);
    await refused(R({ weights: { [TAG.p1]: "0.6", [TAG.p2]: 0.4 } }), /ต้องเป็นตัวเลข/);
  });

  it("ครอบ tag ที่ติดอยู่ไม่ครบ / มีสัดส่วนของ tag ที่ไม่ได้ติด → ปฏิเสธ", async () => {
    await refused(R({ weights: { [TAG.p1]: 1 } }), /บางแสน.*ยังไม่ได้ใส่สัดส่วน/);
    await refused(R({ weights: { [TAG.p1]: 0.6, [TAG.p2]: 0.4, [TAG.p3]: 0.5 } }), /ไม่ได้เลือกอยู่ในรายการนี้/);
  });

  it("ใบที่ไม่ได้ติด tag ชนิดนี้ / ชนิดที่ไม่ถ่วงน้ำหนัก / ชนิดที่ไม่รู้จัก → ปฏิเสธ", async () => {
    db.links.length = 0;
    await refused(R(), /ไม่ได้ติด tag ชนิด/);
    link(TAG.l1, "label");
    await refused(R({ kind: "label", weights: { [TAG.l1]: 1 } }), /ไม่มีการแบ่งสัดส่วน/);
    await refused(R({ kind: "nope" }), /ไม่รู้จักชนิด/);
  });

  it("ไม่มีเหตุผล / ไม่ระบุรายการ / ไม่ระบุชนิด → ปฏิเสธ", async () => {
    await refused(R({ reason: "   " }), /เหตุผล/);
    await refused(R({ reason: undefined as never }), /เหตุผล/);
    await refused(R({ transactionId: "not-a-uuid" }), /ไม่ได้ระบุรายการ/);
    await refused(R({ kind: "" }), /ไม่ได้ระบุชนิด/);
    await refused(undefined, /ไม่ได้รับข้อมูล/);
  });

  it("ไม่มีสิทธิ์ tag.assign / ยังไม่ล็อกอิน / ตรวจสิทธิ์ล้มเหลว → ปฏิเสธ", async () => {
    ctx.access.permissions = new Set(["ledger.approve"]);
    await refused(R(), /ไม่มีสิทธิ์/);
    ctx.access.permissions = new Set(["tag.assign"]);
    ctx.access.error = "boom";
    await refused(R(), /ตรวจสิทธิ์ไม่สำเร็จ/);
    ctx.access.error = null;
    ctx.access.user = null;
    await refused(R(), /เข้าสู่ระบบหมดอายุ/);
  });

  it("DB ยังไม่ได้ลง migration (ตาราง) → ตอบ 'ยังไม่ได้ลง migration' ไม่เรียกฟังก์ชัน ไม่บันทึกอะไร", async () => {
    db.migrated = false;
    await refused(R(), /ยังไม่ได้ลง migration.*ยังไม่ได้บันทึกอะไร/);
  });

  it("ตารางมีแต่ฟังก์ชัน fn_reallocate_tags ยังไม่มี → ตอบ 'ยังไม่ได้ลง migration' (เรียกแล้วไม่เจอ ไม่บันทึกอะไร)", async () => {
    db.reallocReply = { data: null, error: { code: "PGRST202", message: "Could not find the function sri_os.fn_reallocate_tags(p_kind, p_reason, p_transaction_id, p_weights) in the schema cache" } };
    const out = await reallocateTags(R());
    expect(out).toMatchObject({ ok: false });
    if (!out.ok) expect(out.message).toMatch(/ยังไม่ได้ลง migration.*ยังไม่ได้บันทึกอะไร/);
    expect(db.reallocCalls).toHaveLength(1);
  });

  it("DB ปฏิเสธด้วยข้อความไทย → ส่งต่อตามเดิม · DB ล้ม (exception) → บอกว่ายังไม่ทราบผล · DB ตอบว่าง → ไม่ยืนยันว่าสำเร็จ", async () => {
    db.reallocReply = { data: null, error: { code: "P0001", message: "ปิดงวดแล้ว แก้สัดส่วนไม่ได้" } };
    expect(await reallocateTags(R())).toEqual({ ok: false, message: "ปิดงวดแล้ว แก้สัดส่วนไม่ได้" });
    db.reallocReply = "throw";
    const t = await reallocateTags(R());
    expect(t.ok).toBe(false);
    if (!t.ok) expect(t.message).toMatch(/ยังไม่ทราบว่า/);
    db.reallocReply = { data: null, error: null };
    const n = await reallocateTags(R());
    expect(n.ok).toBe(false);
    if (!n.ok) expect(n.message).toMatch(/ไม่ยืนยัน/);
  });

  it("สิทธิ์ของ DB (RLS) ปฏิเสธ → ข้อความอ่านรู้เรื่อง ไม่ใช่ error ดิบ", async () => {
    db.reallocReply = { data: null, error: { code: "42501", message: "permission denied for table x" } };
    const out = await reallocateTags(R());
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.message).toMatch(/ไม่ได้ — ฐานข้อมูลปฏิเสธตามสิทธิ์/);
  });
});

describe("postEntry · ลงรายการพร้อม tag + น้ำหนัก (fn_post_entry: tag_ids / tag_weights)", () => {
  const rent: PostingInput = {
    typeKey: "income",
    subCode: "inc.rent",
    amount: 12000,
    ownerId: OWNER.tk,
    bankAccountId: BANK.tk,
    assetId: ASSET,
    contactId: CONTACT,
  };
  const req = (tags?: PostEntryRequest["tags"]): PostEntryRequest => ({ input: rent, docDate: "24/10/2026", cashDate: "24/10/2026", ...(tags === undefined ? {} : { tags }) });
  const refused = async (r: PostEntryRequest, needle: RegExp | string) => {
    const out = await postEntry(r);
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.message).toMatch(needle);
    expect(ctx.db.rows).toHaveLength(0);
    expect(db.postTagFields).toHaveLength(0);
    return out;
  };

  it("project 60/40 + label → project ไปที่ tag_weights (ตามที่ตรวจแล้ว) label ไปที่ tag_ids · ลงสมุดสำเร็จ", async () => {
    const out = await postEntry(req({ tagIds: [TAG.p1, TAG.p2, TAG.l1], weights: { [TAG.p1]: 0.6, [TAG.p2]: 0.4 } }));
    expect(out).toMatchObject({ ok: true, replayed: false });
    expect(db.postTagFields).toEqual([{ tag_ids: [TAG.l1], tag_weights: { [TAG.p1]: 0.6, [TAG.p2]: 0.4 } }]);
    expect(ctx.db.balance("1100")).toBe(12000);
  });

  it("project อันเดียวน้ำหนัก 1 → ผ่าน · tag_ids ไม่โผล่ถ้าไม่มี label", async () => {
    const out = await postEntry(req({ tagIds: [TAG.p1], weights: { [TAG.p1]: 1 } }));
    expect(out.ok).toBe(true);
    expect(db.postTagFields).toEqual([{ tag_weights: { [TAG.p1]: 1 } }]);
  });

  it("ไม่เลือก tag (ไม่ส่ง / ส่งว่าง) → payload ไม่มีคีย์ tag เลย พฤติกรรมเดิมไม่เปลี่ยน", async () => {
    for (const t of [undefined, { tagIds: [] as string[] }, { tagIds: [] as string[], weights: {} }]) {
      ctx.db.rpcCalls.length = 0;
      const out = await postEntry({ ...req(t), input: { ...rent, amount: 12000 + (t ? 1 : 0) } });
      expect(out.ok).toBe(true);
      const sent = ctx.db.rpcCalls.at(-1)!;
      expect(Object.keys(sent)).not.toContain("tag_ids");
      expect(Object.keys(sent)).not.toContain("tag_weights");
    }
  });

  it("ไม่ส่งน้ำหนักมาเลยสำหรับ project → ปฏิเสธ ไม่เขียนอะไร (ทั้งหนึ่งอัน และหลายอัน)", async () => {
    await refused(req({ tagIds: [TAG.p1] }), /ยังไม่ได้ใส่สัดส่วน/);
    await refused(req({ tagIds: [TAG.p1, TAG.p2] }), /ยังไม่ได้ใส่สัดส่วน/);
    await refused(req({ tagIds: [TAG.p1, TAG.p2], weights: {} }), /ยังไม่ได้ใส่สัดส่วน/);
    expect(ctx.db.rpcCalls).toHaveLength(0);
  });

  it.each([
    ["ขาด 0.000001", { [TAG.p1]: 0.6, [TAG.p2]: 0.399999 }, /ขาดอีก 0\.0001%/],
    ["เกิน 0.000001", { [TAG.p1]: 0.6, [TAG.p2]: 0.400001 }, /เกินอยู่ 0\.0001%/],
    ["น้ำหนัก 0", { [TAG.p1]: 1, [TAG.p2]: 0 }, /0 ไม่ได้/],
    ["น้ำหนัก > 1", { [TAG.p1]: 1.2, [TAG.p2]: 0.4 }, /เกิน 100%/],
  ])("Σ/ช่วงน้ำหนักผิด (%s) → ปฏิเสธก่อนเรียก DB", async (_n, weights, needle) => {
    await refused(req({ tagIds: [TAG.p1, TAG.p2], weights }), needle);
    expect(ctx.db.rpcCalls).toHaveLength(0);
  });

  it("ส่งน้ำหนักให้ tag ที่ไม่ถ่วงน้ำหนัก (label) หรือ tag ที่ไม่ได้เลือก → ปฏิเสธ", async () => {
    await refused(req({ tagIds: [TAG.p1, TAG.l1], weights: { [TAG.p1]: 1, [TAG.l1]: 0.5 } }), /ไม่ใช่ชนิดที่แบ่งสัดส่วน/);
    await refused(req({ tagIds: [TAG.p1], weights: { [TAG.p1]: 1, [TAG.p2]: 0.5 } }), /ไม่ได้เลือกอยู่ในรายการนี้/);
  });

  it("tag ที่ปิดแล้ว · ไม่มีในแค็ตตาล็อก · ชนิดที่ไม่รู้จัก · เลือกซ้ำ → ปฏิเสธ", async () => {
    await refused(req({ tagIds: [TAG.pOff], weights: { [TAG.pOff]: 1 } }), /ถูกปิดใช้งานแล้ว/);
    await refused(req({ tagIds: ["10000000-0000-4000-8000-0000000000ff"], weights: {} }), /ไม่พบ tag/);
    await refused(req({ tagIds: [TAG.ghostKind] }), /ชนิดที่ระบบไม่รู้จัก/);
    await refused(req({ tagIds: [TAG.p1, TAG.p1], weights: { [TAG.p1]: 1 } }), /ซ้ำ/);
  });

  it("ไม่มีสิทธิ์ tag.assign → ปฏิเสธ (ลงรายการธรรมดาได้เหมือนเดิม)", async () => {
    ctx.access.permissions = new Set(["ledger.approve", "txn.create"]);
    await refused(req({ tagIds: [TAG.p1], weights: { [TAG.p1]: 1 } }), /ไม่มีสิทธิ์ติด/);
    expect((await postEntry(req())).ok).toBe(true);
  });

  it("แค็ตตาล็อกยังไม่ได้ลง migration → 'ยังไม่ได้ลง migration' ไม่บันทึกรายการ (ไม่ลงโดยไม่มี tag เงียบๆ)", async () => {
    db.migrated = false;
    await refused(req({ tagIds: [TAG.p1], weights: { [TAG.p1]: 1 } }), /ยังไม่ได้ลง migration.*ยังไม่ได้บันทึกอะไร/);
    expect(ctx.db.rpcCalls).toHaveLength(0);
  });

  it("แค็ตตาล็อกมีแต่ fn_post_entry ยังไม่รู้จัก tag_* (DB ที่ลงอยู่วันนี้) → DB ปฏิเสธทั้งใบ แอปตอบ 'ยังไม่ได้ลง migration' และสมุดว่าง", async () => {
    db.postGateKnowsTags = false;
    const out = await refused(req({ tagIds: [TAG.p1], weights: { [TAG.p1]: 1 } }), /ยังไม่ได้ลง migration.*ยังไม่ได้บันทึกอะไร/);
    expect(out.ok).toBe(false);
    expect(ctx.db.rpcCalls).toHaveLength(1); // เรียกแล้วถูกปฏิเสธ — ไม่ใช่ปล่อยผ่าน
  });
});
