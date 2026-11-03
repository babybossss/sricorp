/**
 * แดชบอร์ด — ฟังก์ชันล้วนที่ประกอบตัวเลขหน้าแรกจากสิ่งที่ DB ให้มา
 *
 * **ไม่มีกฎบัญชี และไม่มีตัวเลขที่เก็บไว้** (D-113): ยอดสินทรัพย์/หนี้สิน/ส่วนของเจ้าของ · กำไรขาดทุน · กระแสเงินสด
 * เรียกตัวสร้างงบเดียวกับหน้า /reports (`statements.ts`) ตรงๆ → ตัวเลขสองหน้าต้องตรงกันเสมอ (เทสต์บังคับ)
 * ยอดค้างรับ/ค้างจ่ายมาจาก `derivePendingAccruals()` ตัวเดียวกับหน้ายืนยันรับ-จ่าย
 */
import { coa } from "@/lib/rules/coa";
import {
  buildBalanceSheet,
  buildCashFlowReport,
  buildProfitLoss,
  type StmtLine,
} from "@/lib/db/statements";
import type { PendingAccrual } from "@/lib/db/pending-accruals";

export type AgingBucket = { key: "d30" | "d60" | "over"; label: string; amount: number; count: number };

export type AccrualSide = { total: number; count: number; buckets: AgingBucket[] };

export type DashboardFigures = {
  year: number;
  bs: { totalAssets: number; totalLiabilities: number; totalEquity: number; difference: number; balanced: boolean; asOf: string; unmapped: number };
  pl: { revenue: number; expense: number; net: number };
  /** null เมื่อประกอบงบกระแสเงินสดไม่ได้ (ข้อมูลไม่ผ่านด่าน) — บอกเหตุผลใน `cfError` ไม่แสดงตัวเลขครึ่งเดียว */
  cf: { operating: number; investing: number; financing: number; net: number; reconciled: boolean } | null;
  cfError: string | null;
  receivable: AccrualSide;
  payable: AccrualSide;
};

const satang = (n: number) => Math.round(n * 100);
const baht = (s: number) => Math.round(s) / 100;

/** จำนวนวันจาก `from` ถึง `to` (YYYY-MM-DD) — ติดลบเมื่อ from อยู่หลัง to */
export function daysBetween(from: string, to: string): number {
  const p = (s: string) => {
    const [y, m, d] = s.split("-").map(Number);
    return Date.UTC(y, m - 1, d);
  };
  return Math.round((p(to) - p(from)) / 86_400_000);
}

const BUCKETS: { key: AgingBucket["key"]; label: string; max: number }[] = [
  { key: "d30", label: "ไม่เกิน 30 วัน", max: 30 },
  { key: "d60", label: "31–60 วัน", max: 60 },
  { key: "over", label: "เกิน 60 วัน", max: Infinity },
];

/** แบ่งยอดค้างคงเหลือตามอายุนับจากวันที่เอกสารต้นทาง ถึงวันนี้ */
export function ageAccruals(items: readonly PendingAccrual[], today: string): AccrualSide {
  const sums = new Map<AgingBucket["key"], { s: number; n: number }>(BUCKETS.map((b) => [b.key, { s: 0, n: 0 }]));
  let total = 0;
  let count = 0;
  for (const p of items) {
    if (!(p.outstanding > 0)) continue;
    const age = daysBetween(p.docDate, today);
    const b = BUCKETS.find((x) => age <= x.max) ?? BUCKETS[BUCKETS.length - 1];
    const cur = sums.get(b.key)!;
    cur.s += satang(p.outstanding);
    cur.n++;
    total += satang(p.outstanding);
    count++;
  }
  return {
    total: baht(total),
    count,
    buckets: BUCKETS.map((b) => ({ key: b.key, label: b.label, amount: baht(sums.get(b.key)!.s), count: sums.get(b.key)!.n })),
  };
}

/** ค้างรับ = บัญชีพักฝั่งสินทรัพย์ · ค้างจ่าย = ฝั่งหนี้สิน (ชนิดบัญชีอ่านจากผังบัญชี ไม่ใช่รายการรหัสในหน้าจอ) */
export function splitAccruals(items: readonly PendingAccrual[]): { receivable: PendingAccrual[]; payable: PendingAccrual[] } {
  const receivable: PendingAccrual[] = [];
  const payable: PendingAccrual[] = [];
  for (const p of items) (coa(p.account).type === "liability" ? payable : receivable).push(p);
  return { receivable, payable };
}

export function buildDashboard(args: {
  lines: StmtLine[];
  ownerIds: string[];
  year: number;
  pending: readonly PendingAccrual[];
  today: string;
}): DashboardFigures {
  const { lines, ownerIds, year, today } = args;
  const bs = buildBalanceSheet(lines, { year, ownerIds });
  const pl = buildProfitLoss(lines, { year, ownerIds });

  let cf: DashboardFigures["cf"] = null;
  let cfError: string | null = null;
  try {
    const r = buildCashFlowReport(lines, { year, ownerIds, balanceSheet: bs });
    const sec = (k: string) => r.statement.sections.find((s) => s.section === k)?.total ?? 0;
    cf = {
      operating: sec("operating"),
      investing: sec("investing"),
      financing: sec("financing"),
      net: r.statement.netChange,
      reconciled: r.statement.reconciled,
    };
  } catch (e) {
    cfError = e instanceof Error ? e.message : String(e);
  }

  const owners = new Set(ownerIds);
  const scoped = args.pending.filter((p) => owners.has(p.ownerId));
  const { receivable, payable } = splitAccruals(scoped);

  return {
    year,
    bs: {
      totalAssets: bs.totalAssets,
      totalLiabilities: bs.totalLiabilities,
      totalEquity: bs.totalEquity,
      difference: bs.difference,
      balanced: bs.balanced,
      asOf: bs.asOf,
      unmapped: bs.unmapped.length,
    },
    pl: { revenue: pl.totalRevenue, expense: pl.totalExpense, net: pl.netProfit },
    cf,
    cfError,
    receivable: ageAccruals(receivable, today),
    payable: ageAccruals(payable, today),
  };
}

/* ------------------------------------------------------------------ *
 * งานที่ต้องทำ — ทุกข้อมาจากข้อมูลจริง ไม่มีรายการที่พิมพ์ไว้
 * ------------------------------------------------------------------ */

export type ContractDue = {
  id: string;
  kind: string;
  assetName: string | null;
  date: string;
  daysLeft: number;
};

export type Todo = { priority: "P1" | "P2" | "P3"; title: string; why: string; href: string };

export type TodoInputs = {
  pendingApprovals: { count: number; total: number };
  agedAccruals: { count: number; total: number };
  contractsDue: ContractDue[];
  staleValuations: number;
  /** ผู้ดูอ่านคิวอนุมัติได้ไหม — ไม่ได้ก็ไม่แสดงงานนี้ (ไม่ใช่แสดง 0) */
  canSeeApprovals: boolean;
};

const fmt = (n: number) => n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

export function buildTodos(i: TodoInputs): Todo[] {
  const out: Todo[] = [];
  for (const c of i.contractsDue) {
    const overdue = c.daysLeft < 0;
    out.push({
      priority: overdue || c.daysLeft <= 30 ? "P1" : "P2",
      title: `${c.kind}${c.assetName ? ` — ${c.assetName}` : ""}`,
      why: overdue ? `เลยกำหนด ${-c.daysLeft} วันแล้ว (${c.date}) แต่สัญญายังเปิดอยู่` : `ครบกำหนด ${c.date} · เหลือ ${c.daysLeft} วัน`,
      href: "/assets",
    });
  }
  if (i.agedAccruals.count > 0)
    out.push({
      priority: "P1",
      title: `ค้างรับ-ค้างจ่ายเกิน 30 วัน ${i.agedAccruals.count} รายการ`,
      why: `รวม ${fmt(i.agedAccruals.total)} บาท · ยังไม่ได้ยืนยันว่าเงินเข้า/ออกจริง`,
      href: "/ledger",
    });
  if (i.canSeeApprovals && i.pendingApprovals.count > 0)
    out.push({
      priority: "P2",
      title: `อนุมัติรายการรอ ${i.pendingApprovals.count} รายการ`,
      why: `รวม ${fmt(i.pendingApprovals.total)} บาท`,
      href: "/approvals",
    });
  if (i.staleValuations > 0)
    out.push({
      priority: "P3",
      title: `ราคาประเมินเก่าเกิน 7 วัน ${i.staleValuations} ทรัพย์`,
      why: "ตัวเลขมูลค่าล่าสุดอาจไม่ทันสมัย (ไม่กระทบตัวเลขบัญชี)",
      href: "/assets",
    });
  const rank = { P1: 0, P2: 1, P3: 2 } as const;
  return out.sort((a, b) => rank[a.priority] - rank[b.priority]);
}
