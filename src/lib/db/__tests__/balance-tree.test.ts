import { describe, expect, it } from "vitest";
import { allocation, buildBalanceTree, hasLedgerData, navByOwner, type BalanceNode } from "../balance-tree";
import { buildBalanceSheet, type StmtLine } from "../statements";

let n = 0;
/** ใบเดียวสองบรรทัด (เดบิต/เครดิต) ของผู้ถือหนึ่งคน */
const entry = (ownerId: string, docDate: string, dr: [string, number][], cr: [string, number][]): StmtLine[] => {
  const txnId = `t${++n}`;
  const mk = (coaCode: string, debit: number, credit: number): StmtLine => ({
    txnId, ownerId, subCode: "x", docDate, cashDate: null, source: "manual", counterOwnerId: null, intercompanyNature: null, coaCode, debit, credit, cfCategory: null, currency: null,
  });
  return [...dr.map(([c, a]) => mk(c, a, 0)), ...cr.map(([c, a]) => mk(c, 0, a))];
};

const LINES: StmtLine[] = [
  // ธนากร: ทุน 5,000,000 เป็นเงินสด · ซื้อคอนโด 3,000,000 + รีโนเวท 500,000 · กู้ธนาคาร 1,000,000 เข้าเงินสด
  ...entry("tk", "2026-01-05", [["1100", 5_000_000]], [["3100", 5_000_000]]),
  ...entry("tk", "2026-02-01", [["1500", 3_000_000]], [["1100", 3_000_000]]),
  ...entry("tk", "2026-02-10", [["1510", 500_000]], [["1100", 500_000]]),
  ...entry("tk", "2026-03-01", [["1100", 1_000_000]], [["2410", 1_000_000]]),
  // สุธี: เงินสด 300,000 จากทุน
  ...entry("st", "2026-01-05", [["1100", 300_000]], [["3100", 300_000]]),
  // รายการของปีถัดไป (ต้องไม่เข้างบปี 2026)
  ...entry("tk", "2027-01-05", [["1100", 777_000]], [["3100", 777_000]]),
];

const flat = (nodes: BalanceNode[]): BalanceNode[] => nodes.flatMap((x) => [x, ...flat(x.children ?? [])]);

describe("buildBalanceTree · ตัวเลขทุกโหนดตรงกับงบ (buildBalanceSheet) ตัวต่อตัว", () => {
  it("ยอดด้านสินทรัพย์/หนี้สิน/ส่วนของเจ้าของตรงกับงบ · ธนากร 2026: 5,000,000 + 1,000,000 − 3,500,000 → สินทรัพย์ 6,000,000 · หนี้สิน 1,000,000", () => {
    const bs = buildBalanceSheet(LINES, { year: 2026, ownerIds: ["tk"] });
    const tree = buildBalanceTree(bs);
    expect(tree.map((t) => [t.id, t.value])).toEqual([["asset", 6_000_000], ["liability", 1_000_000], ["equity", 5_000_000]]);
    expect(bs.totalAssets).toBe(6_000_000);
    expect(bs.balanced).toBe(true);
  });

  it("ทุกโหนดกลุ่ม/บรรทัดมีค่าเท่าที่งบคืนมา และบรรทัดที่มียอดทุกบรรทัดของงบอยู่ในต้นไม้ (ไม่หาย ไม่เพิ่ม)", () => {
    const bs = buildBalanceSheet(LINES, { year: 2026, ownerIds: ["tk", "st"] });
    const tree = buildBalanceTree(bs);
    const fromBs = bs.groups.flatMap((g) => g.lines).filter((l) => l.amount !== 0).map((l) => [l.line, l.amount]);
    const fromTree = flat(tree).filter((x) => x.kind === "line").map((x) => [x.name, x.value]);
    expect(fromTree).toEqual(fromBs);
    for (const g of flat(tree).filter((x) => x.kind === "group")) {
      expect(bs.groups.find((x) => x.group === g.name)?.total).toBe(g.value);
    }
    // ผลรวมบรรทัดของแต่ละด้านเท่ายอดด้านนั้น
    for (const side of tree) {
      const sum = Math.round(flat([side]).filter((x) => x.kind === "line").reduce((t, x) => t + x.value * 100, 0)) / 100;
      expect(sum, side.id).toBe(side.value);
    }
  });

  it("รายการของปีถัดไปไม่เข้างบปีนี้ · เข้างบปีถัดไป (ธนากร 2027 สินทรัพย์ 6,777,000)", () => {
    expect(buildBalanceSheet(LINES, { year: 2026, ownerIds: ["tk"] }).totalAssets).toBe(6_000_000);
    expect(buildBalanceSheet(LINES, { year: 2027, ownerIds: ["tk"] }).totalAssets).toBe(6_777_000);
  });

  it("บรรทัดที่ยอดเป็นศูนย์ไม่แสดง แต่ยอดรวมของด้านไม่หาย", () => {
    const bs = buildBalanceSheet(LINES, { year: 2026, ownerIds: ["st"] });
    const tree = buildBalanceTree(bs);
    expect(flat(tree).filter((x) => x.kind === "line").every((x) => x.value !== 0)).toBe(true);
    expect(tree[0].value).toBe(300_000);
  });
});

describe("navByOwner · NAV รายผู้ถือ", () => {
  it("ธนากร 5,000,000 (6,000,000 − 1,000,000) · สุธี 300,000 · รวมรายคนเท่า NAV รวม (ไม่มีรายการระหว่างกัน)", () => {
    const nav = navByOwner(LINES, ["tk", "st"], 2026);
    expect(nav.map((x) => [x.ownerId, x.nav, x.hasData, x.balanced])).toEqual([["tk", 5_000_000, true, true], ["st", 300_000, true, true]]);
    const family = buildBalanceSheet(LINES, { year: 2026, ownerIds: ["tk", "st"] });
    expect(nav.reduce((t, x) => t + x.nav, 0)).toBe(family.totalAssets - family.totalLiabilities);
  });

  it("ผู้ถือที่ไม่มีรายการเลย → hasData = false (ต้องแสดง 'ไม่มีรายการ' ไม่ใช่ 0) · ปีก่อนมีรายการแรก → ก็ไม่มี", () => {
    expect(navByOwner(LINES, ["nobody"], 2026)[0]).toMatchObject({ hasData: false, nav: 0 });
    expect(navByOwner(LINES, ["tk"], 2025)[0].hasData).toBe(false);
    expect(hasLedgerData(LINES, ["tk"], 2026)).toBe(true);
    expect(hasLedgerData(LINES, ["nobody"], 2026)).toBe(false);
    expect(hasLedgerData([], ["tk"], 2026)).toBe(false);
  });
});

describe("allocation · สัดส่วนสินทรัพย์", () => {
  it("เปอร์เซ็นต์รวม 100 และคิดจากยอดกลุ่มในงบ · ไม่มีสินทรัพย์ → ว่าง (ไม่หารศูนย์)", () => {
    const bs = buildBalanceSheet(LINES, { year: 2026, ownerIds: ["tk"] });
    const a = allocation(bs);
    expect(a.reduce((t, x) => t + x.value, 0)).toBe(bs.totalAssets);
    expect(Math.round(a.reduce((t, x) => t + x.pct, 0) * 1e6) / 1e6).toBe(100);
    expect(allocation(buildBalanceSheet([], { year: 2026, ownerIds: ["tk"] }))).toEqual([]);
  });
});
