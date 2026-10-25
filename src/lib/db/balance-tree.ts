/**
 * โครงต้นไม้ของหน้า "งบดุล & ทรัพย์สิน" — **ทุกตัวเลขมาจาก `buildBalanceSheet()` ตัวเดียวกับหน้า /reports** ไม่คำนวณเอง
 *
 * ไฟล์นี้ไม่มีกฎบัญชี: แค่จัดรูปผลของงบ (ด้าน → กลุ่ม → บรรทัด) ให้เปิด-ปิดเป็นต้นไม้ได้ และเอาผลของงบรายผู้ถือมาเรียงเป็น NAV
 * ตัวเลขของแต่ละโหนดคือค่าที่งบคืนมาตรงๆ (`group.total` / `line.amount` / `totalAssets` …) — ไม่บวกซ้ำ ไม่ปัดซ้ำ
 *
 * ข้อมูลที่สมุดยังไม่มี (ต้นทุน ราคาตลาด แหล่งราคา Yield สถานะ) **ไม่แสดง** ดีกว่าแสดงเลขปลอม
 * มูลค่าที่เห็นที่นี่คือ **มูลค่าตามบัญชี (ราคาทุน + ส่วนตีราคาที่บันทึกแล้ว)** ไม่ใช่มูลค่าตลาดเรียลไทม์
 */

import { BS_SIDE_TH, type BsSide } from "@/lib/rules/statements";
import { buildBalanceSheet, type BalanceSheet, type StmtLine } from "./statements";

export type BalanceNode = {
  id: string;
  name: string;
  value: number;
  kind: "side" | "group" | "line";
  /** ที่มาของตัวเลข เมื่องบบอกไว้ (เช่น บรรทัดที่งบเติมให้) */
  note?: string;
  children?: BalanceNode[];
};

const SIDES: BsSide[] = ["asset", "liability", "equity"];

/** ต้นไม้จากงบ: ด้าน → กลุ่ม → บรรทัด · บรรทัด/กลุ่มที่ยอดเป็นศูนย์ทั้งก้อนไม่แสดง (ไม่ใช่ซ่อนยอด — ยอดรวมของด้านยังเท่าที่งบคืนมา) */
export function buildBalanceTree(bs: BalanceSheet): BalanceNode[] {
  const totals: Record<BsSide, number> = { asset: bs.totalAssets, liability: bs.totalLiabilities, equity: bs.totalEquity };
  return SIDES.map((side) => {
    const groups: BalanceNode[] = [];
    bs.groups
      .filter((g) => g.side === side)
      .forEach((g, gi) => {
        const lines: BalanceNode[] = g.lines
          .filter((l) => l.amount !== 0)
          .map((l, li) => ({ id: `${side}-${gi}-${li}`, name: l.line, value: l.amount, kind: "line" as const, ...(l.note ? { note: l.note } : {}) }));
        if (lines.length === 0 && g.total === 0) return;
        groups.push({ id: `${side}-${gi}`, name: g.group, value: g.total, kind: "group", children: lines });
      });
    return { id: side, name: BS_SIDE_TH[side], value: totals[side], kind: "side" as const, children: groups };
  });
}

export type OwnerNav = {
  ownerId: string;
  /** สินทรัพย์ − หนี้สิน ณ สิ้นปี ตามงบของผู้ถือคนนั้น */
  nav: number;
  totalAssets: number;
  totalLiabilities: number;
  /** มีรายการในสมุดของผู้ถือคนนี้ถึงสิ้นปีหรือไม่ — ไม่มี = ต้องแสดงว่า "ไม่มีรายการ" ไม่ใช่ 0 */
  hasData: boolean;
  balanced: boolean;
};

const cents = (n: number) => Math.round(n * 100);

/** NAV รายผู้ถือ — งบรายคนจาก `buildBalanceSheet()` แล้วลบกันที่หน่วยสตางค์ */
export function navByOwner(lines: StmtLine[], ownerIds: string[], year: number): OwnerNav[] {
  const end = `${String(year).padStart(4, "0")}-12-31`;
  return ownerIds.map((ownerId) => {
    const bs = buildBalanceSheet(lines, { year, ownerIds: [ownerId] });
    return {
      ownerId,
      nav: (cents(bs.totalAssets) - cents(bs.totalLiabilities)) / 100,
      totalAssets: bs.totalAssets,
      totalLiabilities: bs.totalLiabilities,
      hasData: lines.some((l) => l.ownerId === ownerId && l.docDate <= end),
      balanced: bs.balanced,
    };
  });
}

/** สัดส่วนสินทรัพย์ตามกลุ่ม (เปอร์เซ็นต์ของสินทรัพย์รวมในงบ) — ไม่แสดงเมื่อสินทรัพย์รวมไม่เป็นบวก (หารไม่ได้อย่างมีความหมาย) */
export function allocation(bs: BalanceSheet): { name: string; value: number; pct: number }[] {
  if (!(bs.totalAssets > 0)) return [];
  return bs.groups
    .filter((g) => g.side === "asset" && g.total > 0)
    .map((g) => ({ name: g.group, value: g.total, pct: (cents(g.total) / cents(bs.totalAssets)) * 100 }));
}

/** มีรายการในสมุดของผู้ถือที่เลือกถึงสิ้นปีหรือไม่ */
export function hasLedgerData(lines: StmtLine[], ownerIds: string[], year: number): boolean {
  const end = `${String(year).padStart(4, "0")}-12-31`;
  const set = new Set(ownerIds);
  return lines.some((l) => set.has(l.ownerId) && l.docDate <= end);
}
