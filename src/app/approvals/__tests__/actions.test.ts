import { env, mockFactories, ASSETS, USERS, VIEW, OWNER, CONTACT, fresh, as, seedAssets } from "@/lib/db/__tests__/assets-test-env";
import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("@/lib/supabase/server", () => mockFactories.supabase());
vi.mock("@/lib/auth/session", () => mockFactories.session());
vi.mock("@/lib/db/reference", () => mockFactories.reference());
vi.mock("next/cache", () => mockFactories.cache());

import { approveDraftEntries, approveDraftEntry, rejectDraftEntries, rejectDraftEntry } from "../actions";
import { loadApprovals, loadApprovalsFrom } from "@/lib/db/approvals-server";

/**
 * อนุมัติ/ไม่อนุมัติร่างรายการ — ร่างกลายเป็นรายการบัญชีจริงที่นี่ที่เดียว และต้องผ่าน postEntry → buildPosting → fn_post_entry
 * (DB จำลองเลียนแบบ RLS ของ draft_entries · ส่วนที่ต้องพิสูจน์กับ Postgres จริงอยู่ที่ sql/approvals-probe.sql)
 */

const evidence = (ownerId: string, n = 1) =>
  `${ownerId}/cccccccc-3333-4333-8333-cccccccccccc/dddddddd-4444-4444-8444-${String(n).padStart(12, "0")}.pdf`;

let n = 0;
function draft(over: Record<string, unknown> = {}) {
  const row = {
    id: `d0000000-0000-4000-8000-${String(++n).padStart(12, "0")}`, owner_id: OWNER.tk, txn_type_code: "inc.rent", doc_date: "2026-09-10", cash_date: null,
    amount: 12000, asset_id: ASSETS.roomA, contact_id: CONTACT, contract_id: null, memo: "ค่าเช่า ก.ย.", attachments: [], status: "pending", reject_reason: null,
    due_date: null, source: "schedule", source_ref: null, posted_txn_id: null, created_by: USERS.staff, reviewed_by: null, reviewed_at: null,
    created_at: `2026-09-10T00:00:0${n % 10}Z`, ...over,
  };
  env.db.tables.draft_entries.push(row);
  return row;
}
const ledgerRows = () => env.db.base.rows.length;
const byId = (id: unknown) => env.db.tables.draft_entries.find((d) => d.id === id)!;

beforeEach(() => {
  n = 0;
  fresh();
  seedAssets(env.db);
});

describe("คิวอนุมัติอ่านจาก draft_entries จริง", () => {
  it("เฉพาะ pending · ผู้ถือ/ชื่อผู้สร้างมาจาก DB · ไม่มียอดสรุปที่เก็บไว้", async () => {
    draft();
    draft({ status: "approved" });
    draft({ owner_id: OWNER.corp, attachments: [evidence(OWNER.corp)], created_by: USERS.manager });
    const r = await loadApprovals();
    if (!r.ok) throw new Error(r.error);
    expect(r.items).toHaveLength(2);
    expect(r.items.map((i) => i.createdBy?.name)).toEqual(["พนักงาน", "ผู้จัดการ"]);
    expect(r.items[0]).toMatchObject({ typeKey: "income", amount: 12000, cashDate: null });
  });

  it("เกิน 1,000 ร่าง (PostgREST ตัดเงียบ) ยังครบ", async () => {
    for (let i = 0; i < 1_150; i++) draft({ amount: 1 + i });
    const r = await loadApprovals();
    if (!r.ok) throw new Error(r.error);
    expect(r.items).toHaveLength(1_150);
  });

  it("สิทธิ์ให้ DB ตัดสิน: ผู้ไม่มี ledger.read/draft.read_own เห็นคิวว่าง · คนคีย์เห็นเฉพาะของตัวเอง", async () => {
    draft({ created_by: USERS.staff });
    draft({ created_by: USERS.other });
    as({ id: USERS.other, owners: "all", perms: new Set(["asset.draft"]) });
    expect(((await loadApprovals()) as { items: unknown[] }).items).toHaveLength(0);
    as({ id: USERS.staff, owners: [OWNER.tk], perms: new Set(["txn.create", "draft.read_own"]) });
    const mine = await loadApprovals();
    if (!mine.ok) throw new Error(mine.error);
    expect(mine.items.map((i) => i.createdBy?.id)).toEqual([USERS.staff]);
  });

  it("อ่านไม่ได้ → ล้มทั้งหน้า ไม่แสดงคิวครึ่งเดียว", async () => {
    const r = await loadApprovalsFrom({ from: () => { throw new Error("db down"); } } as never, env.reference.ref).catch((e) => ({ ok: false as const, error: String(e) }));
    expect(r.ok).toBe(false);
  });
});

describe("อนุมัติ = ลงสมุดจริงผ่าน engine แล้วปิดร่าง", () => {
  it("ค่าเช่าฝั่งบุคคล (ยังไม่ได้รับเงิน) → ลูกหนี้ 12,000 / รายได้ 12,000 · ร่างปิดพร้อมชี้ transaction", async () => {
    const d = draft();
    expect(ledgerRows()).toBe(0); // ร่างยังไม่อยู่ในสมุด
    const out = await approveDraftEntry(d.id);
    expect(out.ok).toBe(true);
    expect(env.db.base.balance("1200")).toBe(12_000);
    expect(env.db.base.balance("4200")).toBe(-12_000);
    expect(env.db.base.balance("1100")).toBe(0); // ไม่มีเงินสดเคลื่อน
    const txnIds = new Set(env.db.base.rows.map((r) => r.transaction_id));
    expect(txnIds.size).toBe(1);
    expect(byId(d.id)).toMatchObject({ status: "approved", posted_txn_id: [...txnIds][0], reviewed_by: USERS.admin });
    expect(env.db.base.rows[0]).toMatchObject({ txn_asset_id: ASSETS.roomA, contact_id: CONTACT });
  });

  it("ส่งเข้า engine ที่เดียว: ไม่เขียนตาราง transactions/lines ตรงๆ ผ่าน from() (ลงได้ทาง fn_post_entry เท่านั้น)", async () => {
    const d = draft();
    await approveDraftEntry(d.id);
    expect(env.db.base.rpcCalls).toHaveLength(1);
    expect(env.db.writes.filter((w) => !["draft_entries"].includes(w.table))).toEqual([]);
  });

  it("อนุมัติซ้ำ → ปฏิเสธ ไม่ลงสมุดซ้ำ", async () => {
    const d = draft();
    await approveDraftEntry(d.id);
    const rows = ledgerRows();
    const again = await approveDraftEntry(d.id);
    expect(again.ok).toBe(false);
    expect(ledgerRows()).toBe(rows);
  });

  it("นิติบุคคลไม่มีหลักฐาน → ปฏิเสธ ไม่มีอะไรลงสมุด ร่างยัง pending", async () => {
    const d = draft({ owner_id: OWNER.corp, txn_type_code: "exp.repair", attachments: [] });
    const out = await approveDraftEntry(d.id);
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.message).toContain("ต้องแนบหลักฐาน");
    expect(ledgerRows()).toBe(0);
    expect(byId(d.id).status).toBe("pending");
  });

  it("ร่างมีวันที่เงินเคลื่อนแต่ไม่มีบัญชี / หมวดไม่รู้จัก → ปฏิเสธ ไม่เดา", async () => {
    const paid = draft({ cash_date: "2026-09-10" });
    const unknown = draft({ txn_type_code: "zzz.unknown" });
    for (const d of [paid, unknown]) expect((await approveDraftEntry(d.id as string)).ok).toBe(false);
    expect(ledgerRows()).toBe(0);
    expect([paid, unknown].map((d) => byId(d.id).status)).toEqual(["pending", "pending"]);
  });

  it("ผู้ไม่มี ledger.approve: ลงสมุดไม่ได้ และร่างไม่ถูกปิด", async () => {
    const d = draft();
    as({ id: USERS.other, owners: "all", perms: new Set(["ledger.read", "txn.create"]) }); // อ่านคิวได้แต่ไม่มี ledger.approve
    const out = await approveDraftEntry(d.id);
    expect(out.ok).toBe(false);
    expect(ledgerRows()).toBe(0);
    expect(byId(d.id).status).toBe("pending");
  });

  it("ลงสมุดแล้วแต่ปิดร่างไม่สำเร็จ → บอกตรงๆ · กดซ้ำไม่ลงสมุดซ้ำ (replay) แล้วปิดร่างได้", async () => {
    const d = draft();
    env.db.control.failDraftUpdate = true;
    const first = await approveDraftEntry(d.id);
    expect(first.ok).toBe(false);
    if (!first.ok) expect(first.message).toContain("ลงสมุดบัญชีแล้ว");
    const rows = ledgerRows();
    expect(rows).toBeGreaterThan(0);
    expect(byId(d.id).status).toBe("pending");
    env.db.control.failDraftUpdate = false;
    const retry = await approveDraftEntry(d.id);
    expect(retry.ok).toBe(true);
    expect(ledgerRows()).toBe(rows); // ไม่ลงซ้ำ
    expect(env.db.base.balance("4200")).toBe(-12_000);
    expect(byId(d.id).status).toBe("approved");
  });

  it("อนุมัติหมู่: ใบที่ติดไม่ดับทั้งคิว · ทุกใบที่ข้ามมีเหตุผล", async () => {
    const good = draft();
    const bad = draft({ owner_id: OWNER.corp, txn_type_code: "exp.repair", attachments: [] });
    const out = await approveDraftEntries([good.id, bad.id, good.id]);
    if (!out.ok) throw new Error(out.message);
    expect(out.approved).toBe(1);
    expect(out.failed).toHaveLength(1);
    expect(out.failed[0].id).toBe(bad.id);
    expect(out.failed[0].message).toContain("ต้องแนบหลักฐาน");
    expect(env.db.base.balance("4200")).toBe(-12_000);
    expect((await approveDraftEntries([])).ok).toBe(false);
  });
});

describe("ไม่อนุมัติ = แก้เฉพาะแถวร่าง ไม่แตะสมุด (I3)", () => {
  it("ต้องมีเหตุผล · ปิดเป็น rejected · สมุดไม่เปลี่ยนแม้แต่แถวเดียว", async () => {
    const d = draft();
    const w = env.db.writes.length;
    expect((await rejectDraftEntry(d.id, "   ")).ok).toBe(false);
    expect(env.db.writes.length).toBe(w);
    const out = await rejectDraftEntry(d.id, "ยอดไม่ตรงใบแจ้งหนี้");
    expect(out.ok).toBe(true);
    expect(byId(d.id)).toMatchObject({ status: "rejected", reject_reason: "ยอดไม่ตรงใบแจ้งหนี้", reviewed_by: USERS.admin, posted_txn_id: null });
    expect(ledgerRows()).toBe(0);
    expect(env.db.base.rpcCalls).toHaveLength(0);
    expect(env.db.writes.every((x) => x.table === "draft_entries")).toBe(true);
  });

  it("ปฏิเสธซ้ำ/ปฏิเสธใบที่อนุมัติแล้วไม่ได้ · ผู้ไม่มีสิทธิ์ปฏิเสธไม่ได้ (DB ไม่แก้ให้)", async () => {
    const done = draft();
    await approveDraftEntry(done.id);
    expect((await rejectDraftEntry(done.id, "เปลี่ยนใจ")).ok).toBe(false);
    expect(byId(done.id).status).toBe("approved");
    const d = draft();
    as(VIEW.staff());
    env.db.tables.draft_entries.forEach((x) => (x.created_by = USERS.staff));
    as({ id: USERS.staff, owners: [OWNER.tk], perms: new Set(["txn.create", "draft.read_own"]) });
    const denied = await rejectDraftEntry(d.id, "แอบปฏิเสธ");
    expect(denied.ok).toBe(false);
    expect(byId(d.id).status).toBe("pending");
  });

  it("ปฏิเสธหมู่: ทุกใบถูกปิดด้วยเหตุผลเดียวกัน สมุดว่าง", async () => {
    const a = draft();
    const b = draft();
    const out = await rejectDraftEntries([a.id, b.id], "ซ้ำกับรายการเดิม");
    expect(out).toMatchObject({ ok: true, approved: 2, failed: [] });
    expect(ledgerRows()).toBe(0);
    expect((await rejectDraftEntries([a.id], "")).ok).toBe(false); // ไม่มีเหตุผล = ไม่ทำอะไรเลย
    const again = await rejectDraftEntries([a.id], "ซ้ำ");
    expect(again).toMatchObject({ ok: true, approved: 0 }); // ใบที่ปิดแล้วถูกรายงานใน failed ไม่ใช่เงียบ
    if (again.ok) expect(again.failed).toHaveLength(1);
  });
});
