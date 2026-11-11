import { env, mockFactories, ASSETS, USERS, VIEW, OWNER, BANK, CONTACT, fresh, as, seedAssets } from "@/lib/db/__tests__/assets-test-env";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("@/lib/supabase/server", () => mockFactories.supabase());
vi.mock("@/lib/auth/session", () => mockFactories.session());
vi.mock("@/lib/db/reference", () => mockFactories.reference());
vi.mock("next/cache", () => mockFactories.cache());

import { postEntry } from "@/app/actions/post-entry";
import type { PostingInput } from "@/lib/ledger/types";
import { loadDashboard, loadDashboardFrom } from "../dashboard-data";
import { ageAccruals, buildTodos, daysBetween, splitAccruals } from "../dashboard-model";
import { buildBalanceSheet, buildProfitLoss, toStmtLines, type StatementViewRow } from "@/lib/db/statements";
import { COA_BY_ID } from "@/app/actions/__tests__/fake-db";
import type { PendingAccrual } from "@/lib/db/pending-accruals";

/** หน้าแรกอ่านสมุดจริง (ลงด้วย postEntry ตัวจริง) — ตัวเลขต้องเท่าที่ลงและเท่ากับหน้างบการเงิน */

const TODAY = "2026-10-25";
// หน้าแรกอ่าน "วันนี้" จากนาฬิกาจริง (loadDashboard) ส่วนข้อมูลทดสอบเขียนเป็นวันที่จริงของเดือนนั้น → ตรึงนาฬิกาที่ TODAY
// ไม่งั้นเทสต์เขียวเฉพาะวันที่เขียน แล้วแดงเองเมื่อเวลาเดินไป (เทสต์ที่แปรผันตามปฏิทินคือเทสต์ที่หยุดทดสอบโดยไม่มีสัญญาณ)
// ตรึงเฉพาะ Date (เที่ยงวันตามเวลากรุงเทพฯ) timer อื่นเดินปกติ
beforeAll(() => {
  vi.useFakeTimers({ now: new Date(`${TODAY}T05:00:00Z`), toFake: ["Date"] });
});
afterAll(() => {
  vi.useRealTimers();
});
async function post(input: Partial<PostingInput> & Pick<PostingInput, "typeKey" | "subCode" | "amount">, docDate: string, cashDate = docDate, owner = OWNER.tk) {
  as(VIEW.management());
  const out = await postEntry({
    input: { ownerId: owner, bankAccountId: owner === OWNER.tk ? BANK.tk : BANK.sutee, contactId: CONTACT, assetId: ASSETS.roomA, ...input },
    docDate,
    cashDate,
  });
  if (!out.ok) throw new Error(out.message);
}
async function seedLedger() {
  await post({ typeKey: "invest_buy", subCode: "inv.buy_re", amount: 3_000_000 }, "01/01/2026");
  await post({ typeKey: "income", subCode: "inc.rent", amount: 12_000, memo: "paid" }, "05/09/2026");
  await post({ typeKey: "expense", subCode: "exp.repair", amount: 2_000 }, "06/09/2026");
  await post({ typeKey: "invest_buy", subCode: "inv.buy_re", amount: 1_000_000, assetId: ASSETS.houseC }, "01/02/2026", "01/02/2026", OWNER.sutee);
  // ค้างรับค่าเช่า: เก่า (เกิน 60 วัน) กับใหม่ (ไม่เกิน 30 วัน)
  await post({ typeKey: "income", subCode: "inc.rent", amount: 7_000, notYetPaid: true, memo: "old" }, "01/07/2026", "");
  await post({ typeKey: "income", subCode: "inc.rent", amount: 9_000, notYetPaid: true, memo: "new" }, "10/10/2026", "");
}
const dash = async (sp: { owner?: string; year?: string } = {}) => {
  const d = await loadDashboard(sp);
  if (!d.ok) throw new Error(d.error);
  return d;
};

beforeEach(() => {
  fresh();
  seedAssets(env.db);
});

describe("ตัวเลขการเงินตรงกับสมุดและหน้างบการเงิน", () => {
  it("สินทรัพย์/หนี้สิน/ส่วนของเจ้าของ และกำไรขาดทุน = ตัวสร้างงบเดียวกับ /reports จากบรรทัดชุดเดียวกัน", async () => {
    await seedLedger();
    const d = await dash({ year: "2026" });
    const f = d.figures!;
    const lines = toStmtLines(env.db.base.rows as unknown as StatementViewRow[], COA_BY_ID);
    const ids = env.reference.ref.owners.map((o) => o.id);
    const bs = buildBalanceSheet(lines, { year: 2026, ownerIds: ids });
    const pl = buildProfitLoss(lines, { year: 2026, ownerIds: ids });
    expect(f.bs.totalAssets).toBe(bs.totalAssets);
    expect(f.bs.totalLiabilities).toBe(bs.totalLiabilities);
    expect(f.bs.totalEquity).toBe(bs.totalEquity);
    expect(f.pl).toEqual({ revenue: pl.totalRevenue, expense: pl.totalExpense, net: pl.netProfit });
    // เทียบกับตัวเลขที่ลงจริง: รายได้ 12,000 + ค้างรับ 16,000 · ค่าซ่อม 2,000
    expect(f.pl).toEqual({ revenue: 28_000, expense: 2_000, net: 26_000 });
    expect(f.bs.balanced).toBe(true);
    // ที่ดิน/คอนโด 4,000,000 + เงินสด (12,000 − 2,000 − 4,000,000 ที่จ่ายซื้อ) + ลูกหนี้ค่าเช่า 16,000 — ปีไม่มียอดยกมา
    expect(f.bs.totalAssets).toBe(4_000_000 + 12_000 - 2_000 - 4_000_000 + 16_000);
  });

  it("กรองตามผู้ถือ: ธนากร + สุธี = มุมมองรวม และผู้ถือที่ไม่มีรายการ = 0 (ไม่ตกไปมุมมองรวม)", async () => {
    await seedLedger();
    const all = (await dash()).figures!;
    const tk = (await dash({ owner: OWNER.tk })).figures!;
    const sutee = (await dash({ owner: OWNER.sutee })).figures!;
    const corp = (await dash({ owner: OWNER.corp })).figures!;
    expect(tk.bs.totalAssets + sutee.bs.totalAssets + corp.bs.totalAssets).toBe(all.bs.totalAssets);
    expect(tk.pl.revenue).toBe(28_000);
    expect(sutee.pl.revenue).toBe(0);
    expect(corp.bs.totalAssets).toBe(0);
    // ค้างรับเป็นของธนากรทั้งก้อน — ผู้ถือคนอื่นต้องไม่เห็น
    expect([tk.receivable.total, sutee.receivable.total, corp.receivable.total]).toEqual([16_000, 0, 0]);
    expect(sutee.bs.totalAssets).toBe(1_000_000 - 1_000_000);
    // owner ที่ไม่รู้จัก → มุมมองรวม พร้อมบอก view=family (ไม่ใช่เดาเป็นอีกคน)
    expect((await dash({ owner: "ghost" })).view).toBe("family");
  });

  it("ปีอื่นที่ไม่มีรายการ: รายได้ 0 แต่ยอดสินทรัพย์ยกมาตามสมุด (ปีบัญชีม.ค.–ธ.ค.)", async () => {
    await seedLedger();
    const y = (await dash({ year: "2025" })).figures!;
    expect(y.pl.revenue).toBe(0);
    expect(y.bs.totalAssets).toBe(0);
  });
});

describe("ค้างรับ/ค้างจ่าย แบ่งตามอายุ", () => {
  it("ยอดค้างรับ = ลูกหนี้ในสมุด · เก่า 7,000 ลงถังเกิน 60 วัน · ใหม่ 9,000 ลงถังไม่เกิน 30 วัน", async () => {
    await seedLedger();
    const f = (await dash()).figures!;
    expect(f.receivable.total).toBe(16_000);
    expect(f.receivable.total).toBe(env.db.base.balance("1200"));
    expect(f.receivable.buckets.map((b) => [b.key, b.amount, b.count])).toEqual([["d30", 9_000, 1], ["d60", 0, 0], ["over", 7_000, 1]]);
    expect(f.payable.total).toBe(0);
  });

  it("ฟังก์ชันล้วน: ขอบเขตวันที่ 30/31 และ 60/61 + แยกค้างรับ/ค้างจ่ายตามชนิดบัญชี", () => {
    const mk = (docDate: string, outstanding: number, account = "1200"): PendingAccrual =>
      ({ id: docDate, ownerId: "o", account, typeKey: "income", subCode: "inc.rent", docDate, memo: null, assetId: null, contactId: null, attachments: [], accruedAmount: outstanding, postedClearings: [], clearedOutside: 0, outstanding });
    const side = ageAccruals([mk("2026-09-25", 1), mk("2026-09-24", 2), mk("2026-08-26", 4), mk("2026-08-25", 8), mk("2026-09-01", 0)], TODAY);
    expect(daysBetween("2026-09-25", TODAY)).toBe(30);
    expect(side.buckets.map((b) => b.amount)).toEqual([1, 2 + 4, 8]);
    expect(side.count).toBe(4); // ยอดค้าง 0 ไม่นับ
    const { receivable, payable } = splitAccruals([mk("2026-10-01", 5), mk("2026-10-01", 6, "2100")]);
    expect(receivable.map((p) => p.account)).toEqual(["1200"]);
    expect(payable.map((p) => p.account)).toEqual(["2100"]);
  });
});

describe("สิทธิ์ — DB ตัดสิน หน้าจอบอกตามจริง", () => {
  it("ไม่มี ledger.read → ไม่มีตัวเลขการเงินเลย (figures เป็น null ไม่ใช่ 0)", async () => {
    await seedLedger();
    as({ id: USERS.other, owners: "all", perms: new Set(["txn.create", "draft.read_own"]) });
    const d = await dash();
    expect(d.ledgerAccess).toBe(false);
    expect(d.figures).toBeNull();
  });

  it("Manager ที่เห็นเฉพาะทรัพย์ที่ตนบริหาร: รายได้ของห้องอื่นไม่มาถึงหน้าจอ", async () => {
    await seedLedger();
    await post({ typeKey: "income", subCode: "inc.rent", amount: 5_000, assetId: ASSETS.roomB, memo: "ห้อง B" }, "07/09/2026");
    expect(((await dash()).figures!).pl.revenue).toBe(33_000);
    env.db.tables.assets.find((a) => a.id === ASSETS.roomA)!.manager_user_id = USERS.manager;
    as(VIEW.manager());
    const f = (await dash()).figures!;
    expect(f.pl.revenue).toBe(28_000); // ไม่รวม 5,000 ของห้อง B ที่ตนไม่ได้บริหาร
  });

  it("อ่านสมุดไม่สำเร็จ → ล้มทั้งหน้า ไม่แสดงตัวเลขครึ่งเดียว", async () => {
    const bad = { from: (t: string) => (t === "v_ledger_posted" ? { select: () => ({ order: () => ({ range: async () => ({ data: null, error: { message: "boom" } }) }) }) } : env.db.client.from(t)) };
    const r = await loadDashboardFrom(bad as never, env.reference.ref, { ownerParam: null, year: 2026, today: TODAY, ledgerAccess: true, canSeeApprovals: false });
    expect(r.ok).toBe(false);
  });
});

describe("งานที่ต้องทำ มาจากข้อมูลจริง", () => {
  it("ร่างรออนุมัติ · สัญญาใกล้ครบ/เลยกำหนด · ราคาประเมินเก่า", async () => {
    env.db.tables.draft_entries.push(
      { id: "d1", owner_id: OWNER.tk, status: "pending", amount: 1000 },
      { id: "d2", owner_id: OWNER.tk, status: "pending", amount: 250.5 },
      { id: "d3", owner_id: OWNER.tk, status: "approved", amount: 99 }
    );
    env.db.tables.contracts.push(
      { id: "c1", type: "lease", asset_id: ASSETS.roomA, owner_id: OWNER.tk, end_date: "2026-11-14", redemption_deadline: null, status: "active" }, // เหลือ 20 วัน
      { id: "c2", type: "sale_leaseback", asset_id: ASSETS.roomB, owner_id: OWNER.tk, end_date: "2027-12-31", redemption_deadline: "2026-10-20", status: "active" }, // เลยมา 5 วัน
      { id: "c3", type: "lease", asset_id: ASSETS.roomA, owner_id: OWNER.tk, end_date: "2027-06-01", redemption_deadline: null, status: "active" }, // ไกล ไม่ขึ้น
      { id: "c4", type: "lease", asset_id: ASSETS.roomA, owner_id: OWNER.tk, end_date: "2026-11-01", redemption_deadline: null, status: "closed" } // ปิดแล้ว ไม่ขึ้น
    );
    env.db.tables.asset_valuations.push({ id: "v1", asset_id: ASSETS.roomA, as_of: "2026-09-01", method: "manual", value: 1, created_at: "2026-09-01T00:00:00Z" });
    const d = await dash();
    expect(d.contractsDue.map((c) => [c.id, c.daysLeft])).toEqual([["c2", -5], ["c1", 20]]);
    const titles = d.todos.map((t) => t.title);
    expect(titles.some((t) => t.includes("อนุมัติรายการรอ 2 รายการ"))).toBe(true);
    expect(d.todos.find((t) => t.title.includes("อนุมัติรายการรอ"))!.why).toContain("1,250.50");
    expect(titles.some((t) => t.includes("ราคาประเมินเก่า"))).toBe(true);
    expect(d.todos[0].priority).toBe("P1"); // เรียง P1 ก่อน
    expect(d.todos.find((t) => t.title.includes("ขายฝาก"))!.why).toContain("เลยกำหนด 5 วัน");
  });

  it("ผู้ไม่มี ledger.approve ไม่เห็นงานอนุมัติ (ไม่ใช่เห็น 0) · ไม่มีงาน → บอกว่าไม่มี", () => {
    const t = buildTodos({ pendingApprovals: { count: 5, total: 10 }, agedAccruals: { count: 0, total: 0 }, contractsDue: [], staleValuations: 0, canSeeApprovals: false });
    expect(t).toEqual([]);
  });

  it("กรองตามผู้ถือ: สัญญาของผู้ถือคนอื่นไม่ขึ้นในมุมมองของคนนี้", async () => {
    env.db.tables.contracts.push({ id: "c1", type: "lease", asset_id: ASSETS.houseC, owner_id: OWNER.sutee, end_date: "2026-11-14", redemption_deadline: null, status: "active" });
    expect((await dash({ owner: OWNER.tk })).contractsDue).toEqual([]);
    expect((await dash({ owner: OWNER.sutee })).contractsDue).toHaveLength(1);
  });
});
