import { env, mockFactories, ASSETS, USERS, VIEW, OWNER, BANK, CONTACT, fresh, as, seedAssets } from "./assets-test-env";
import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("@/lib/supabase/server", () => mockFactories.supabase());
vi.mock("@/lib/auth/session", () => mockFactories.session());
vi.mock("@/lib/db/reference", () => mockFactories.reference());
vi.mock("next/cache", () => mockFactories.cache());

import { postEntry } from "@/app/actions/post-entry";
import type { PostingInput } from "@/lib/ledger/types";
import { loadAssetDetail, loadAssetRegister, loadDraftPage, loadRegisterFrom } from "../assets-server";
import {
  DEFAULT_FILTER, FAMILY_OWNER, filterAssets, groupAssets, sumReports, buildAssetReports, reportAccounts, ASSET_REPORT_SUBS, type AssetLedgerLine,
} from "../assets-model";
import { coa } from "@/lib/rules/coa";
import { findSub } from "@/lib/rules/tx-rules";

/**
 * ทะเบียนทรัพย์อ่านจากสมุดจริง (ผ่านการลงรายการด้วย `postEntry` ตัวจริง ไม่ใช่แถวที่เขียนมือ)
 * เพื่อให้รูปบรรทัดตรงกับที่ระบบสร้างจริง — เช่น บรรทัดรายได้/ค่าใช้จ่าย **ไม่มี asset_id ที่บรรทัด** ผูกที่หัวรายการเท่านั้น
 */

async function post(input: Partial<PostingInput> & Pick<PostingInput, "typeKey" | "subCode" | "amount" | "assetId">, owner = OWNER.tk) {
  as(VIEW.management());
  const out = await postEntry({
    input: { ownerId: owner, bankAccountId: owner === OWNER.tk ? BANK.tk : BANK.sutee, contactId: CONTACT, ...input },
    docDate: `01/09/2026`,
    cashDate: `01/09/2026`,
  });
  if (!out.ok) throw new Error(`post ล้ม: ${out.message}`);
}
const buy = (assetId: string, amount: number, owner?: string) => post({ typeKey: "invest_buy", subCode: "inv.buy_re", amount, assetId }, owner);
const capex = (assetId: string, amount: number) => post({ typeKey: "invest_buy", subCode: "inv.capex", amount, assetId });
const repair = (assetId: string, amount: number, owner?: string) => post({ typeKey: "expense", subCode: "exp.repair", amount, assetId }, owner);
const rent = (assetId: string, amount: number) => post({ typeKey: "income", subCode: "inc.rent", amount, assetId, memo: "งวดแรก" });

/** ห้อง A: ซื้อ 3,000,000 + รีโนเวท 200,000 + ซ่อม 15,000 + ค่าเช่า 3×12,000 · ห้อง B: ซื้อ 5,000,000 + เช่า 2×20,000 · บ้าน C (สุธี): ซื้อ 1,000,000 + ซ่อม 5,000 */
async function seedLedger() {
  await buy(ASSETS.roomA, 3_000_000);
  await capex(ASSETS.roomA, 200_000);
  await repair(ASSETS.roomA, 15_000);
  for (const m of ["ก.ค.", "ส.ค.", "ก.ย."]) await post({ typeKey: "income", subCode: "inc.rent", amount: 12_000, assetId: ASSETS.roomA, memo: m });
  await buy(ASSETS.roomB, 5_000_000);
  await rent(ASSETS.roomB, 20_000);
  await post({ typeKey: "income", subCode: "inc.rent", amount: 20_000, assetId: ASSETS.roomB, memo: "งวดที่สอง" });
  await buy(ASSETS.houseC, 1_000_000, OWNER.sutee);
  await repair(ASSETS.houseC, 5_000, OWNER.sutee);
}

beforeEach(() => {
  fresh();
  seedAssets(env.db);
});

const ref = () => env.reference.ref;
const register = async () => {
  const r = await loadAssetRegister();
  if (!r.ok) throw new Error(r.error);
  return r;
};

describe("รายงานรายทรัพย์ตรงกับสมุด", () => {
  it("ต้นทุนซื้อ · ค่าปรับปรุง · ค่าซ่อม · รายได้ ของแต่ละชิ้นเท่าที่ลงสมุดจริง", async () => {
    await seedLedger();
    const r = await register();
    const rep = r.reports!;
    expect(rep[ASSETS.roomA]).toMatchObject({ purchase: 3_000_000, renovation: 200_000, costTotal: 3_200_000, repair: 15_000, income: 36_000 });
    expect(rep[ASSETS.roomB]).toMatchObject({ purchase: 5_000_000, renovation: 0, costTotal: 5_000_000, repair: 0, income: 40_000 });
    expect(rep[ASSETS.houseC]).toMatchObject({ purchase: 1_000_000, repair: 5_000, income: 0 });
    // ทรัพย์ที่ไม่มีรายการเลย = ศูนย์จริง (ไม่ใช่ไม่มีรายงาน)
    expect(rep[ASSETS.stockD]).toMatchObject({ purchase: 0, renovation: 0, costTotal: 0, repair: 0, income: 0 });
  });

  it("ผลบวกรายชิ้นกระทบกับยอดบัญชีในสมุด (1500+1510 · 5120 · 4200)", async () => {
    await seedLedger();
    const r = await register();
    const t = sumReports(r.assets, r.reports!);
    expect(t.costTotal).toBe(env.db.base.balance("1500") + env.db.base.balance("1510"));
    expect(t.renovation).toBe(env.db.base.balance("1510"));
    expect(t.repair).toBe(env.db.base.balance("5120"));
    expect(t.income).toBe(-env.db.base.balance("4200"));
    expect(t.income).toBe(76_000);
    expect(t.costTotal).toBe(9_200_000);
  });

  it("หน้ารายชิ้นกับหน้ารวมให้ตัวเลขเดียวกันทุกชิ้น", async () => {
    await seedLedger();
    const r = await register();
    for (const a of r.assets) {
      const d = await loadAssetDetail(a.id);
      if (!d.ok || d.asset === null) throw new Error("detail");
      expect(d.report).toEqual(r.reports![a.id]);
    }
  });

  it("ค่าปรับปรุงที่กลับรายการแล้วไม่ถูกนับ (ใบกลับรายการหักล้างในสมุด)", async () => {
    await seedLedger();
    // กลับรายการ capex ของห้อง A ด้วยแถวสลับด้านเหมือนที่ DB ทำ
    const orig = env.db.base.rows.filter((x) => x.line_asset_id === ASSETS.roomA && Number(x.debit) > 0 && Number(x.credit) === 0 && x.txn_type_code === "inv.capex");
    expect(orig.length).toBe(1);
    const rev = (x: (typeof orig)[number], pair: (typeof env.db.base.rows)[number]) => ({ ...pair, transaction_id: "rev-1", source: "reverse", reverses_id: x.transaction_id, debit: pair.credit, credit: pair.debit });
    for (const row of env.db.base.rows.filter((x) => x.transaction_id === orig[0].transaction_id)) env.db.base.rows.push(rev(orig[0], row));
    const r = await register();
    expect(r.reports![ASSETS.roomA]).toMatchObject({ renovation: 0, costTotal: 3_000_000, purchase: 3_000_000 });
  });

  it("เกิน 1,000 บรรทัด (PostgREST ตัดเงียบ) ตัวเลขยังครบ", async () => {
    await buy(ASSETS.roomB, 5_000_000);
    let expected = 0;
    for (let i = 1; i <= 600; i++) {
      await post({ typeKey: "income", subCode: "inc.rent", amount: 1_000 + i, assetId: ASSETS.roomB });
      expected += 1_000 + i;
    }
    expect(env.db.base.rows.length).toBeGreaterThan(1_000);
    const r = await register();
    expect(r.reports![ASSETS.roomB].income).toBe(expected);
  });

  it("บรรทัดที่รหัสบัญชีไม่อยู่ในผัง ไม่ถูกนับเงียบๆ — แจ้งจำนวน", async () => {
    await buy(ASSETS.roomA, 3_000_000);
    env.db.base.rows.push({ ...env.db.base.rows[0], line_id: "x", coa_id: "coa-9999", debit: 777, credit: 0 } as never);
    const r = await register();
    expect(r.unclassifiedLines).toBe(1);
    expect(r.reports![ASSETS.roomA].costTotal).toBe(3_000_000);
  });

  it("ตีราคาไม่เปลี่ยนตัวเลขบัญชี — มูลค่าล่าสุดเป็นอีกก้อนหนึ่ง", async () => {
    await buy(ASSETS.roomA, 3_000_000);
    env.db.tables.asset_valuations.push({ id: "v1", asset_id: ASSETS.roomA, as_of: "2026-09-30", method: "manual", value: 3_900_000, note: null, revision: 1, created_at: "2026-10-01T00:00:00Z" });
    const r = await register();
    expect(r.values[ASSETS.roomA]).toMatchObject({ value: 3_900_000, asOf: "2026-09-30" });
    expect(r.values[ASSETS.roomB]).toMatchObject({ value: null }); // ยังไม่เคยตีราคา = null ไม่ใช่ 0
    expect(r.reports![ASSETS.roomA].costTotal).toBe(3_000_000);
    expect(env.db.base.balance("1500")).toBe(3_000_000);
  });
});

describe("กรองตามผู้ถือ (กฎเหล็กข้อ 3)", () => {
  it("มุมมองรวม = ทุกชิ้น · เลือกผู้ถือ = เฉพาะของเขา · ผลบวกของแต่ละมุมมองกระทบสมุด", async () => {
    await seedLedger();
    const r = await register();
    const ids = (owner: string) => filterAssets(r.assets, { ...DEFAULT_FILTER, owner }).map((a) => a.id).sort();
    expect(ids(FAMILY_OWNER)).toEqual(Object.values(ASSETS).sort());
    expect(ids(OWNER.tk)).toEqual([ASSETS.roomA, ASSETS.roomB].sort());
    expect(ids(OWNER.sutee)).toEqual([ASSETS.houseC]);
    expect(ids(OWNER.corp)).toEqual([ASSETS.stockD]);
    const tk = sumReports(filterAssets(r.assets, { ...DEFAULT_FILTER, owner: OWNER.tk }), r.reports!);
    expect(tk.costTotal).toBe(8_200_000);
    const sutee = sumReports(filterAssets(r.assets, { ...DEFAULT_FILTER, owner: OWNER.sutee }), r.reports!);
    expect(sutee.costTotal).toBe(1_000_000);
    // ผู้ถือที่ไม่มีทรัพย์ = ว่าง ไม่ใช่ตกไปมุมมองรวม
    expect(ids("ghost")).toEqual([]);
  });

  it("กรองตามป้ายกำกับและคำค้นได้", async () => {
    const r = await register();
    expect(filterAssets(r.assets, { ...DEFAULT_FILTER, tag: "สุขุมวิท" }).map((a) => a.id)).toEqual([ASSETS.roomA]);
    expect(filterAssets(r.assets, { ...DEFAULT_FILTER, q: "นนทบุรี" }).map((a) => a.id)).toEqual([ASSETS.houseC]);
  });
});

describe("สิทธิ์ — ให้ DB ตัดสิน หน้าจอไม่กรองสิทธิ์เอง", () => {
  it("Manager เห็นเฉพาะทรัพย์ที่ตนบริหาร และตัวเลขของชิ้นอื่นไม่มาถึงหน้าจอเลย", async () => {
    await seedLedger();
    env.db.tables.assets.find((a) => a.id === ASSETS.roomA)!.manager_user_id = USERS.manager;
    as(VIEW.manager());
    const r = await register();
    expect(r.assets.map((a) => a.id)).toEqual([ASSETS.roomA]);
    expect(Object.keys(r.reports!)).toEqual([ASSETS.roomA]);
    expect(r.reports![ASSETS.roomA].costTotal).toBe(3_200_000);
    // ไม่มีร่องรอยตัวเลขของห้อง B ในผลลัพธ์ทั้งก้อน
    expect(JSON.stringify(r)).not.toContain("5000000");
    // ทรัพย์ที่ยังไม่มอบหมาย (manager_user_id ว่าง) Manager ต้องไม่เห็น
    expect(r.assets.find((a) => a.id === ASSETS.roomB)).toBeUndefined();
  });

  it("Manager ที่ไม่ได้บริหารอะไรเลย เห็นทะเบียนว่าง ไม่ใช่ทั้งพอร์ต", async () => {
    await seedLedger();
    as(VIEW.manager());
    const r = await register();
    expect(r.assets).toEqual([]);
    expect(r.reports).toEqual({});
  });

  it("ไม่มี ledger.read → ไม่มีตัวเลขเงิน (null ไม่ใช่ 0) และช่องปิดของทะเบียนเป็น null", async () => {
    await seedLedger();
    as(VIEW.staff());
    const r = await register();
    expect(r.ledgerAccess).toBe(false);
    expect(r.reports).toBeNull();
    expect(r.assets).toHaveLength(4); // Staff เห็นชื่อไว้คีย์รายการ
    const a = r.assets.find((x) => x.id === ASSETS.roomA)!;
    expect(a.location).toBeNull();
    expect(a.tags).toEqual([]);
    expect(a.ownershipPct).toBeNull();
    expect(Object.values(r.values).every((v) => v.value === null)).toBe(true);
  });

  it("Staff เปิดหน้ารายชิ้นได้แต่ไม่มีรายงาน และไม่มีบรรทัดสมุด", async () => {
    await seedLedger();
    as(VIEW.staff());
    const d = await loadAssetDetail(ASSETS.roomA);
    if (!d.ok || d.asset === null) throw new Error("detail");
    expect(d.report).toBeNull();
    expect(d.lines).toEqual([]);
  });

  it("ทรัพย์ที่มองไม่เห็นกับทรัพย์ที่ไม่มีอยู่ ตอบเหมือนกัน · id ที่ไม่ใช่ uuid ไม่ถูกต่อเข้าตัวกรอง", async () => {
    await seedLedger();
    as(VIEW.manager());
    const hidden = await loadAssetDetail(ASSETS.roomB);
    const ghost = await loadAssetDetail("99999999-9999-4999-8999-999999999999");
    expect(hidden).toEqual({ ok: true, asset: null });
    expect(ghost).toEqual({ ok: true, asset: null });
    expect(await loadAssetDetail("x),line_asset_id.not.is.null,(y")).toEqual({ ok: true, asset: null });
  });

  it("อ่านต้นทุนไม่ได้สักชิ้น → ล้มทั้งหน้า ไม่แสดงตัวเลขครึ่งเดียว", async () => {
    await seedLedger();
    const real = env.db.client.rpc;
    env.db.client.rpc = ((fn: string, args: Record<string, unknown>) =>
      fn === "fn_asset_cost_basis" && args.p_asset === ASSETS.houseC
        ? Promise.resolve({ data: null, error: { message: "boom" } })
        : real(fn, args)) as never;
    const r = await loadAssetRegister();
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.error).toMatch(/ต้นทุนทรัพย์/);
  });
});

describe("ร่างไม่ถูกนับ", () => {
  it("ร่างสร้างทรัพย์ที่ค้างอยู่ไม่เพิ่มจำนวนทรัพย์หรือผลบวก", async () => {
    await seedLedger();
    const before = await register();
    env.db.tables.asset_drafts.push({
      id: "d1", kind: "create", target_asset_id: null, owner_id: OWNER.tk, name: "ห้องใหม่", class_id: "c0000000-0000-4000-8000-000000000001",
      category_id: "ca000000-0000-4000-8000-000000000001", patch: {}, note: null, status: "pending", reject_reason: null, applied_asset_id: null,
      created_by: USERS.staff, reviewed_by: null, reviewed_at: null, created_at: "2026-10-25T00:00:00Z",
    });
    const after = await register();
    expect(after.drafts).toHaveLength(1);
    expect(after.drafts[0].createdBy.name).toBe("พนักงาน");
    expect(after.assets).toHaveLength(before.assets.length);
    expect(sumReports(after.assets, after.reports!)).toEqual(sumReports(before.assets, before.reports!));
  });

  it("Staff เห็นเฉพาะร่างของตัวเอง ผู้อนุมัติเห็นในขอบเขต", async () => {
    const mk = (id: string, by: string) => ({
      id, kind: "create", target_asset_id: null, owner_id: OWNER.tk, name: id, class_id: null, category_id: null, patch: {}, note: null, status: "pending",
      reject_reason: null, applied_asset_id: null, created_by: by, reviewed_by: null, reviewed_at: null, created_at: "2026-10-25T00:00:00Z",
    });
    env.db.tables.asset_drafts.push(mk("mine", USERS.staff), mk("theirs", USERS.other));
    as(VIEW.staff());
    const page = await loadDraftPage();
    if (!page.ok) throw new Error(page.error);
    expect(page.drafts.map((d) => d.id)).toEqual(["mine"]);
    as(VIEW.management());
    const all = await loadDraftPage();
    if (!all.ok) throw new Error(all.error);
    expect(all.drafts.map((d) => d.id).sort()).toEqual(["mine", "theirs"]);
  });
});

describe("ต้นทุนรายชิ้น ไม่มีการรวมหรือถัว", () => {
  it("จัดกลุ่มตามที่ตั้งเดียวกัน: ห้อง A กับ B อยู่กลุ่มเดียวกัน แต่กลุ่มไม่มีตัวเลขใดๆ", async () => {
    await seedLedger();
    const r = await register();
    const groups = groupAssets(r.assets, "location");
    const building = groups.find((g) => g.assets.some((a) => a.id === ASSETS.roomA))!;
    expect(building.assets.map((a) => a.id).sort()).toEqual([ASSETS.roomA, ASSETS.roomB].sort());
    for (const g of groupAssets(r.assets, "class").concat(groupAssets(r.assets, "category"), groupAssets(r.assets, "owner"), groups)) {
      // รูปร่างของกลุ่มถูกล็อก: ชื่อ + รายชื่อทรัพย์ เท่านั้น — เพิ่มช่องตัวเลข (ต้นทุนกลุ่ม) = เทสต์นี้แดง
      expect(Object.keys(g).sort()).toEqual(["assets", "key", "title"]);
      expect(Object.values(g).some((v) => typeof v === "number")).toBe(false);
    }
    // ต้นทุนของแต่ละห้องยังเป็นของตัวเอง ไม่ใช่ 4,100,000 (ค่ากลางของ 3,200,000 กับ 5,000,000)
    expect(r.reports![ASSETS.roomA].costTotal).toBe(3_200_000);
    expect(r.reports![ASSETS.roomB].costTotal).toBe(5_000_000);
    expect(JSON.stringify(r.reports)).not.toContain("4100000");
  });
});

describe("กฎของรายงาน อ่านจากตารางกฎ", () => {
  it("หมวดค่ารีโนเวท/ค่าซ่อมยังชี้ไปบัญชีสินทรัพย์/ค่าใช้จ่าย (ตารางกฎเปลี่ยน = เทสต์แดง)", () => {
    const acc = reportAccounts();
    expect(coa(acc.renovation).type).toBe("asset");
    expect(coa(acc.repair).type).toBe("expense");
    expect(findSub(ASSET_REPORT_SUBS.renovation)?.sub.dr).toBe(acc.renovation);
    expect(acc.gains.size).toBeGreaterThan(0);
    expect(acc.losses.size).toBeGreaterThan(0);
  });

  it("กำไรจากการขายแยกจากรายได้ · บรรทัดไม่มีทรัพย์ไม่ถูกนับให้ใคร", () => {
    const acc = reportAccounts();
    const gain = [...acc.gains][0];
    const line = (over: Partial<AssetLedgerLine>): AssetLedgerLine => ({
      lineId: String(Math.random()), txnId: "t", ownerId: "o", subCode: "x", docDate: "2026-09-01", source: "manual",
      coaCode: "4200", debit: 0, credit: 0, lineAssetId: null, txnAssetId: null, ...over,
    });
    const { reports } = buildAssetReports({ a: 100 }, [
      line({ coaCode: "4200", credit: 50, txnAssetId: "a" }),
      line({ coaCode: gain, credit: 900, lineAssetId: "a", txnAssetId: "a" }),
      line({ coaCode: "4200", credit: 777 }), // ไม่ผูกทรัพย์
      line({ coaCode: "4200", credit: 5, txnAssetId: "b" }), // ทรัพย์ที่ไม่ได้ขอรายงาน
    ]);
    expect(reports.a).toMatchObject({ income: 50, saleResult: 900, costTotal: 100 });
    expect(reports.b).toBeUndefined();
  });
});

describe("loadRegisterFrom ส่ง client เข้าไปได้ (เทสต์ได้โดยไม่ผ่าน session)", () => {
  it("ledgerAccess=false ไม่ถามสมุดและต้นทุนเลย", async () => {
    const spy = vi.spyOn(env.db.client, "rpc");
    const r = await loadRegisterFrom(env.db.client as never, ref(), { ledgerAccess: false });
    if (!r.ok) throw new Error(r.error);
    expect(r.reports).toBeNull();
    expect(spy.mock.calls.filter(([fn]) => fn === "fn_asset_cost_basis")).toHaveLength(0);
  });
});
