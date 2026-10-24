import "./mocks";
import { readFileSync } from "node:fs";
import path from "node:path";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ctx, resetCtx } from "./ctx";
import { OWNER, referenceFixture, COA_BY_ID } from "./fake-db";
import { createBankAccount, moveBankAccount, setBankAccountActive, updateBankAccount } from "../bank-accounts";
import { postEntry } from "../post-entry";
import { bankChoices } from "@/components/form/bank-field";
import type { Reference } from "@/lib/db/reference-types";

/**
 * ตั้งค่าบัญชีธนาคารเขียน DB จริง — เทสต์นี้ใช้ DB จำลองที่เลียนแบบ PostgREST + ด่านที่เกี่ยวข้อง
 * (check constraint ของสกุลเงิน · RLS ที่ทำให้ INSERT ล้ม/UPDATE ไม่โดนแถว · D-092 บัญชีปิดลงรายการใหม่ไม่ได้)
 * ส่วนที่ต้องพิสูจน์กับ Postgres จริง (policy ของ settings.manage · trigger) อยู่ใน
 * `src/lib/db/__tests__/sql/bank_accounts_settings_probe.sql`
 */

const TK = OWNER.tk;
const SUTEE = OWNER.sutee;
const input = (over: Partial<Parameters<typeof createBankAccount>[0]> = {}) => ({
  ownerId: TK,
  bank: "กสิกรไทย",
  displayName: "ธนากร - KBANK 999",
  last4: "0999",
  currency: "THB",
  ...over,
});
const table = () => ctx.db.tables.bank_accounts;
const created = async (over = {}) => {
  const r = await createBankAccount(input(over));
  if (!r.ok) throw new Error(r.message);
  return r.bank;
};

/** โหลดข้อมูลอ้างอิงด้วยตัวโหลดจริง (ไม่ใช่ที่ mock) จาก DB จำลอง — เหมือนที่หน้าลงรายการเห็น */
async function realReference(): Promise<Reference> {
  const f = referenceFixture();
  ctx.db.tables.owners = f.owners.map((o) => ({ id: o.id, code: o.code, policy: o.policy, name_th: o.name, status: o.status, color: null, sort_order: o.sortOrder }));
  ctx.db.tables.chart_of_accounts = Object.entries(COA_BY_ID).map(([id, code]) => ({ id, code }));
  const actual = await vi.importActual<typeof import("@/lib/db/reference")>("@/lib/db/reference");
  const r = await actual.loadReference();
  if (!r.ok) throw new Error(r.error);
  return r.ref;
}

beforeEach(() => {
  resetCtx();
  ctx.db.tables.bank_accounts.length = 0;
});

describe("เพิ่มบัญชี", () => {
  it("เขียนลง DB จริง · อ่านกลับได้ · เลือกได้ในฟอร์มลงรายการ · ลงรายการเข้าบัญชีนั้นได้", async () => {
    const b = await created();
    expect(table()).toHaveLength(1);
    expect(table()[0]).toMatchObject({
      owner_id: TK,
      bank: "กสิกรไทย",
      display_name: "ธนากร - KBANK 999",
      account_name: "ธนากร - KBANK 999",
      account_no_last4: "0999",
      currency: "THB",
      is_active: true,
    });

    const ref = await realReference();
    const fromDb = ref.banks.find((x) => x.id === b.id)!;
    expect(fromDb).toMatchObject({ name: "ธนากร - KBANK 999", ownerId: TK, currency: "THB", isActive: true });

    // ช่องเลือกบัญชีของฟอร์ม (ตัวกรองเดียวกับหน้าลงรายการ) เห็นบัญชีใหม่ของผู้ถือคนนั้น และไม่เห็นในผู้ถือคนอื่น
    const off = (id: string) => !ref.banks.find((x) => x.id === id)?.isActive;
    expect(bankChoices(ref.banks, off, TK).map((x) => x.id)).toContain(b.id);
    expect(bankChoices(ref.banks, off, SUTEE).map((x) => x.id)).not.toContain(b.id);

    // ใช้ลงรายการจริงได้
    ctx.reference = { ok: true, ref };
    const posted = await postEntry({
      input: { typeKey: "income", subCode: "inc.rent", amount: 5000, ownerId: TK, bankAccountId: b.id, assetId: "bbbbbbbb-0000-4000-8000-000000000001", contactId: "cccccccc-0000-4000-8000-000000000001" },
      docDate: "20/10/2026",
      cashDate: "20/10/2026",
    });
    expect(posted.ok).toBe(true);
    expect(ctx.db.balance("1100", TK)).toBe(5000);
  });

  it("ส่งเฉพาะคอลัมน์ที่ตั้งใจ — ไม่แตะยอดยกมา/ผังบัญชี (ยอดตั้งต้นเข้าทางไฟล์นำเข้าเท่านั้น)", async () => {
    await created();
    const w = ctx.db.writes.find((x) => x.op === "insert")!;
    expect(Object.keys(w.payload as object).sort()).toEqual(
      ["account_name", "account_no_last4", "bank", "currency", "display_name", "is_active", "owner_id", "sort_order"].sort()
    );
  });

  it("บัญชี USD: สกุลเงินถูกเก็บจริง ไม่กลายเป็นบาท และโหลดกลับมาเป็น USD", async () => {
    const b = await created({ displayName: "ธนากร - FCD USD", currency: "USD" });
    expect(b.currency).toBe("USD");
    expect(table()[0].currency).toBe("USD");
    const ref = await realReference();
    expect(ref.banks.find((x) => x.id === b.id)!.currency).toBe("USD");
  });

  it.each([
    ["ไม่เลือกสกุลเงิน", { currency: "" }, "currency"],
    ["สกุลเงินที่ไม่รองรับ", { currency: "EUR" }, "currency"],
    ["ไม่เลือกผู้ถือ", { ownerId: "" }, "ownerId"],
    ["ผู้ถือที่ไม่มีอยู่จริง", { ownerId: "ffffffff-ffff-4fff-8fff-ffffffffffff" }, "ownerId"],
    ["ผู้ถือที่ยังไม่เปิดใช้ (planned)", { ownerId: OWNER.planned }, "ownerId"],
    ["ไม่ใส่ชื่อบัญชี", { displayName: "   " }, "displayName"],
    ["ไม่ใส่ธนาคาร", { bank: "" }, "bank"],
    ["เลขท้ายไม่ครบ 4 หลัก", { last4: "12" }, "last4"],
    ["เลขท้ายไม่ใช่ตัวเลข", { last4: "12ab" }, "last4"],
    ["ชื่อยาวเกิน", { displayName: "ก".repeat(61) }, "displayName"],
  ])("%s → ปฏิเสธพร้อมบอกช่อง · ไม่เขียนอะไรลง DB", async (_n, over, field) => {
    const r = await createBankAccount(input(over));
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.fieldErrors?.[field as "currency"]).toBeTruthy();
    expect(ctx.db.writes).toHaveLength(0);
    expect(table()).toHaveLength(0);
  });

  it("ชื่อซ้ำในผู้ถือเดียวกัน (ต่างแค่เว้นวรรค/ตัวพิมพ์/แม้บัญชีที่ปิดแล้ว) → ปฏิเสธ · ต่างผู้ถือใช้ชื่อเดียวกันได้", async () => {
    const a = await created({ displayName: "ธนากร - KBANK 999" });
    const dup = await createBankAccount(input({ displayName: "  ธนากร   -  kbank 999 " }));
    expect(dup.ok).toBe(false);
    if (!dup.ok) expect(dup.fieldErrors?.displayName).toMatch(/ซ้ำ/);
    await setBankAccountActive({ id: a.id, active: false });
    const dupClosed = await createBankAccount(input({ displayName: "ธนากร - KBANK 999" }));
    expect(dupClosed.ok).toBe(false);
    const other = await createBankAccount(input({ ownerId: SUTEE, displayName: "ธนากร - KBANK 999" }));
    expect(other.ok).toBe(true);
    expect(table()).toHaveLength(2);
  });

  it("ลำดับต่อท้ายสุดเสมอ", async () => {
    const a = await created({ displayName: "A" });
    const b = await created({ displayName: "B" });
    expect(b.sortOrder).toBe(a.sortOrder + 1);
  });

  it("ยังไม่ล็อกอิน → ปฏิเสธก่อนแตะ DB", async () => {
    ctx.access.user = null;
    const r = await createBankAccount(input());
    expect(r.ok).toBe(false);
    expect(ctx.db.writes).toHaveLength(0);
  });
});

describe("สิทธิ์: ด่านคือ RLS ของ DB ไม่ใช่ปุ่มหรือโค้ดหน้าจอ", () => {
  it("DB ปฏิเสธ INSERT (ไม่มี settings.manage) → ผู้ใช้เห็นเหตุผล · ไม่มีแถวเกิด · คำสั่งถึง DB จริง", async () => {
    ctx.access.permissions = new Set() as never;
    ctx.db.control.denyWrites.add("bank_accounts");
    const r = await createBankAccount(input());
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.message).toMatch(/ไม่มีสิทธิ์/);
    expect(table()).toHaveLength(0);
    expect(ctx.db.writes.map((w) => [w.op, w.denied])).toEqual([["insert", true]]);
  });

  it("DB ปฏิเสธ UPDATE เงียบๆ (ไม่มีแถวถูกแก้) → แอปไม่รายงานว่าสำเร็จ", async () => {
    const b = await created();
    ctx.db.control.denyWrites.add("bank_accounts");
    for (const r of [
      await setBankAccountActive({ id: b.id, active: false }),
      await updateBankAccount({ id: b.id, bank: "X", displayName: "เปลี่ยนชื่อ", last4: "" }),
      await moveBankAccount({ id: b.id, direction: 1 }),
    ]) {
      expect(r.ok).toBe(false);
    }
    expect(table()[0]).toMatchObject({ is_active: true, display_name: "ธนากร - KBANK 999" });
  });
});

describe("ปิดใช้งาน ไม่ใช่ลบ", () => {
  const rentInto = (bankAccountId: string) =>
    postEntry({
      input: { typeKey: "income", subCode: "inc.rent", amount: 1000, ownerId: TK, bankAccountId, assetId: "bbbbbbbb-0000-4000-8000-000000000001", contactId: "cccccccc-0000-4000-8000-000000000001" },
      docDate: "21/10/2026",
      cashDate: "21/10/2026",
    });

  it("ปิดบัญชีที่มีรายการ → แถวยังอยู่ รายการเดิมอ่านได้ครบ · ลงรายการใหม่เข้าบัญชีนั้นไม่ได้ · เปิดกลับแล้วลงได้", async () => {
    const b = await created();
    ctx.reference = { ok: true, ref: await realReference() };
    expect((await rentInto(b.id)).ok).toBe(true);
    const before = ctx.db.rows.length;
    expect(before).toBeGreaterThan(0);

    const off = await setBankAccountActive({ id: b.id, active: false });
    expect(off.ok && off.bank.isActive).toBe(false);
    expect(table()).toHaveLength(1);
    expect(table()[0].is_active).toBe(false);

    // รายการเดิมยังอ่านได้เหมือนเดิมผ่านวิวสมุด
    const read = ctx.db.rows.filter((r) => r.bank_account_id === b.id);
    expect(read).toHaveLength(1); // บรรทัดเงินสดของบัญชีนี้ยังอยู่ครบ
    expect(ctx.db.rows.length).toBe(before);

    // ด่านของ DB เอง (ไม่ผ่านการกรองของแอป): ส่งใบใหม่เข้าบัญชีที่ปิดตรงๆ ก็ต้องถูกปฏิเสธ
    const raw = JSON.parse(JSON.stringify(ctx.db.rpcCalls[0]));
    raw.doc_date = "2026-10-22";
    const direct = await ctx.db.client.rpc("fn_post_entry", { p_payload: raw });
    expect(direct.error?.message).toMatch(/ปิดใช้งาน/);
    expect(ctx.db.rows.length).toBe(before);

    // ลงรายการใหม่เข้าบัญชีที่ปิด → ถูกปฏิเสธ (D-092) และไม่มีแถวเพิ่ม
    ctx.reference = { ok: true, ref: await realReference() };
    const again = await rentInto(b.id);
    expect(again.ok).toBe(false);
    if (!again.ok) expect(again.message).toMatch(/ปิดใช้งาน/);
    expect(ctx.db.rows.length).toBe(before);

    const on = await setBankAccountActive({ id: b.id, active: true });
    expect(on.ok).toBe(true);
    ctx.reference = { ok: true, ref: await realReference() };
    expect((await rentInto(b.id)).ok).toBe(true);
  });

  it("ปิดแล้วหายจากตัวเลือกในฟอร์ม แต่ยังอยู่ในข้อมูลอ้างอิง (รายงานย้อนหลังหาเจอ)", async () => {
    const b = await created();
    await setBankAccountActive({ id: b.id, active: false });
    const ref = await realReference();
    const off = (id: string) => !ref.banks.find((x) => x.id === id)?.isActive;
    expect(ref.banks.map((x) => x.id)).toContain(b.id);
    expect(bankChoices(ref.banks, off, TK).map((x) => x.id)).not.toContain(b.id);
  });

  it("ทุกการกระทำของหน้านี้ไม่เคยสั่งลบ (delete = 0)", async () => {
    const a = await created({ displayName: "A" });
    const b = await created({ displayName: "B" });
    await updateBankAccount({ id: a.id, bank: "X", displayName: "A2", last4: "" });
    await setBankAccountActive({ id: a.id, active: false });
    await setBankAccountActive({ id: a.id, active: true });
    await moveBankAccount({ id: b.id, direction: -1 });
    expect(ctx.db.writes.filter((w) => w.op === "delete")).toHaveLength(0);
    expect(table()).toHaveLength(2);
  });
});

describe("แก้ไขและจัดลำดับ", () => {
  it("แก้ได้เฉพาะชื่อ/ธนาคาร/เลขท้าย — ผู้ถือและสกุลเงินไม่เปลี่ยนแม้ส่งมาเอง", async () => {
    const b = await created({ currency: "USD", displayName: "FCD" });
    const r = await updateBankAccount({ id: b.id, bank: "ใหม่", displayName: "FCD ใหม่", last4: "1234", ownerId: SUTEE, currency: "THB", is_active: false } as never);
    expect(r.ok).toBe(true);
    expect(table()[0]).toMatchObject({ owner_id: TK, currency: "USD", is_active: true, bank: "ใหม่", display_name: "FCD ใหม่", account_no_last4: "1234" });
    const w = ctx.db.writes.filter((x) => x.op === "update").at(-1)!;
    expect(Object.keys(w.payload as object).sort()).toEqual(["account_name", "account_no_last4", "bank", "display_name"]);
  });

  it("เปลี่ยนชื่อเป็นชื่อของตัวเองได้ · เป็นชื่อบัญชีอื่นของผู้ถือเดียวกันไม่ได้", async () => {
    const a = await created({ displayName: "A" });
    const b = await created({ displayName: "B" });
    expect((await updateBankAccount({ id: a.id, bank: "X", displayName: "A", last4: "" })).ok).toBe(true);
    const clash = await updateBankAccount({ id: b.id, bank: "X", displayName: "a", last4: "" });
    expect(clash.ok).toBe(false);
    expect(table().find((r) => r.id === b.id)!.display_name).toBe("B");
  });

  it("แก้บัญชีที่ไม่มี/มองไม่เห็น → ปฏิเสธ ไม่เขียน", async () => {
    const r = await updateBankAccount({ id: "ไม่มีอยู่", bank: "X", displayName: "Y", last4: "" });
    expect(r.ok).toBe(false);
    expect(ctx.db.writes).toHaveLength(0);
  });

  it("เลื่อนลำดับ: เลขลำดับซ้ำกันหมด (เป็น 0) ก็สลับได้จริง", async () => {
    const a = await created({ displayName: "A" });
    const b = await created({ displayName: "B" });
    const c = await created({ displayName: "C" });
    for (const r of table()) r.sort_order = 0; // แถวเดิมใน DB จริงเป็น 0 ทั้งหมด
    const r = await moveBankAccount({ id: c.id, direction: -1 });
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.banks.map((x) => x.name)).toEqual(["A", "C", "B"]);
    const ref = await realReference();
    expect([...ref.banks].sort((x, y) => x.sortOrder - y.sortOrder).map((x) => x.name)).toEqual(["A", "C", "B"]);
    expect(a.id).toBeTruthy();
    expect(b.id).toBeTruthy();
  });

  it("เลื่อนบัญชีแรกขึ้น/สุดท้ายลง → ปฏิเสธ ไม่เขียน", async () => {
    const a = await created({ displayName: "A" });
    const b = await created({ displayName: "B" });
    const n = ctx.db.writes.length;
    expect((await moveBankAccount({ id: a.id, direction: -1 })).ok).toBe(false);
    expect((await moveBankAccount({ id: b.id, direction: 1 })).ok).toBe(false);
    expect(ctx.db.writes.length).toBe(n);
  });
});

describe("หน้าตั้งค่าไม่อ่านข้อมูลจำลอง", () => {
  const read = (f: string) => readFileSync(path.join(process.cwd(), f), "utf8");
  it.each(["src/components/settings/bank-settings.tsx", "src/components/settings/settings-nav.tsx", "src/components/settings/menu.ts"])(
    "%s ไม่ import lib/mock หรือ lib/store",
    (f) => {
      expect(read(f)).not.toMatch(/from\s+["']@\/lib\/(mock|store)/);
    }
  );
  it("ปุ่มในหน้าตั้งค่าบัญชีไม่เรียกลบ (มีแต่ปิดใช้งาน)", () => {
    const src = read("src/components/settings/bank-settings.tsx");
    expect(src).not.toMatch(/\.delete\(|deleteBank|removeBank/);
    expect(src).toMatch(/setBankAccountActive/);
  });
});
