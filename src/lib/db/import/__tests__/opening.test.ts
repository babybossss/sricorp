import { describe, expect, it } from "vitest";
import { buildBalanceSheet, toStmtLines, type StatementViewRow } from "../../statements";
import { COA } from "@/lib/rules/coa";
import {
  fingerprintOf,
  parseOpeningWorkbook,
  planOpeningImport,
  type ExistingOpeningEntry,
  type ImportIssue,
  type JournalLine,
  type ParsedOpening,
} from "../opening";
import { BANKS, CUTOFF, OWNERS, ctxOf, loadFixture, setCell } from "./helpers";
import type { Workbook } from "../xlsx";

const parseOk = (wb: Workbook = loadFixture(), ctx = ctxOf()): ParsedOpening => {
  const r = parseOpeningWorkbook(wb, ctx);
  if (!r.ok) throw new Error("ควรผ่านแต่ถูกปฏิเสธ: " + r.issues.map((i) => `${i.sheet}#${i.row ?? "-"} ${i.message}`).join("\n"));
  return r.parsed;
};
const parseBad = (wb: Workbook, ctx = ctxOf()): ImportIssue[] => {
  const r = parseOpeningWorkbook(wb, ctx);
  if (r.ok) throw new Error("ควรถูกปฏิเสธแต่ผ่าน");
  return r.issues;
};

const TK = "BS-ธนากร";
const journalOf = (p: ParsedOpening, ownerId: string) => p.journals.find((j) => j.ownerId === ownerId)!;
const sumLines = (ls: JournalLine[]) => ({
  dr: Math.round(ls.reduce((t, l) => t + l.debit, 0) * 100) / 100,
  cr: Math.round(ls.reduce((t, l) => t + l.credit, 0) * 100) / 100,
});

/* ---------- จำลองสมุด (append-only) เพื่อพิสูจน์ว่าแผนให้ผลสุทธิถูกและไม่มีการลบ ---------- */
type LedgerEntry = { txnId: string; ownerId: string; docDate: string; lines: JournalLine[]; reversalOf?: string };
class FakeLedger {
  entries: LedgerEntry[] = [];
  deletes = 0;
  private n = 0;
  post(ownerId: string, docDate: string, lines: JournalLine[], reversalOf?: string) {
    this.entries.push({ txnId: `t${++this.n}`, ownerId, docDate, lines, reversalOf });
  }
  /** ใบยอดตั้งต้นที่ยังไม่ถูกกลับ — สิ่งที่ผู้เรียกจริงต้องอ่านจาก DB */
  live(): ExistingOpeningEntry[] {
    const reversed = new Set(this.entries.filter((e) => e.reversalOf).map((e) => e.reversalOf!));
    return this.entries.filter((e) => !e.reversalOf && !reversed.has(e.txnId));
  }
  apply(plan: ReturnType<typeof planOpeningImport>, cutoff: string) {
    for (const it of plan.items) {
      for (const id of it.reverse) {
        const orig = this.entries.find((e) => e.txnId === id)!;
        this.post(orig.ownerId, orig.docDate, orig.lines.map((l) => ({ ...l, debit: l.credit, credit: l.debit })), id);
      }
      if (it.post.length) this.post(it.ownerId, cutoff, it.post);
    }
  }
  /** ยอดสุทธิต่อ (ผู้ถือ, รหัสบัญชี) = เดบิต − เครดิต ของทุกใบรวมใบกลับ */
  net(): Map<string, number> {
    const m = new Map<string, number>();
    for (const e of this.entries)
      for (const l of e.lines) {
        const k = `${e.ownerId}|${l.coaCode}`;
        m.set(k, Math.round(((m.get(k) ?? 0) + l.debit - l.credit) * 100) / 100);
      }
    return new Map([...m].filter(([, v]) => v !== 0));
  }
  asStatementRows(): { rows: StatementViewRow[]; ids: Record<string, string> } {
    const ids = Object.fromEntries(COA.map((a) => [a.code, `coa-${a.code}`]));
    const rows: StatementViewRow[] = [];
    for (const e of this.entries)
      e.lines.forEach((l, i) =>
        rows.push({
          line_id: `${e.txnId}-${i}`,
          transaction_id: e.txnId,
          owner_id: e.ownerId,
          txn_type_code: "opening",
          doc_date: e.docDate,
          cash_date: null,
          source: "import",
          counter_owner_id: null,
          intercompany_nature: null,
          coa_id: ids[l.coaCode],
          debit: l.debit,
          credit: l.credit,
          cf_category: null,
          currency: "THB",
        })
      );
    return { rows, ids };
  }
}
const idToCode = (ids: Record<string, string>) => Object.fromEntries(Object.entries(ids).map(([c, id]) => [id, c]));

/* =========================================================== 1. ไฟล์ตัวอย่างนำเข้าได้ + งบดุลลงตัว */
describe("ไฟล์ตัวอย่าง: อ่าน ตรวจ และงบดุลลงตัว", () => {
  it("ผ่านการตรวจ ได้ 3 ผู้ถือที่มียอด และทุกใบสมดุลในตัวเอง", () => {
    const p = parseOk();
    expect(p.journals.map((j) => j.ownerName).sort()).toEqual(["SRI Corporation", "ธนากร", "สุธี"].sort());
    for (const j of p.journals) {
      const { dr, cr } = sumLines(j.lines);
      expect(dr).toBe(cr);
      expect(dr).toBeGreaterThan(0);
    }
    expect(journalOf(p, "o-thanakorn").assets).toBe(4_420_000);
    expect(journalOf(p, "o-thanakorn").liabilities).toBe(500_000);
    expect(journalOf(p, "o-thanakorn").equity).toBe(3_920_000);
  });

  it("เงินสด 1100 แตกเป็นรายบัญชีธนาคารจริง ไม่มีเงินสดลอย", () => {
    const j = journalOf(parseOk(), "o-thanakorn");
    const cash = j.lines.filter((l) => l.coaCode === "1100");
    expect(cash.map((l) => [l.bankAccountId, l.debit])).toEqual([
      ["b-tk-bbl", 600_000],
      ["b-tk-scb", 400_000],
    ]);
    expect(j.lines.filter((l) => l.coaCode !== "1100").every((l) => l.bankAccountId === null)).toBe(true);
  });

  it("ล็อตหลักทรัพย์ 3 ล็อต ต้นทุนรวมเท่า 1700 (70,000 + 100,000 + 130,000 รวมค่าธรรมเนียม)", () => {
    const p = parseOk();
    expect(p.lots.map((l) => [l.name, l.cost, l.coaCode, l.boughtOn])).toEqual([
      ["PTT", 70_000, "1700", "2025-03-03"],
      ["SET50", 100_000, "1700", "2025-06-02"],
      ["K-FIXED", 130_000, "1700", "2025-09-01"],
    ]);
  });

  it("ลงเป็นรายการจริงแล้วงบดุลลงตัวทุกผู้ถือและงบรวม · กำไรสะสม 3300 มาจากไฟล์ · ลูกหนี้/เจ้าหนี้ระหว่างกันตัดกัน", () => {
    const p = parseOk();
    const led = new FakeLedger();
    led.apply(planOpeningImport(p, [], new Map()), CUTOFF);
    const { rows, ids } = led.asStatementRows();
    const lines = toStmtLines(rows, idToCode(ids));
    for (const o of [...p.journals.map((j) => j.ownerId)]) {
      const bs = buildBalanceSheet(lines, { year: 2026, ownerIds: [o] });
      expect(bs.balanced, o).toBe(true);
      expect(bs.difference, o).toBe(0);
      expect(bs.unmapped, o).toEqual([]);
    }
    const all = buildBalanceSheet(lines, { year: 2026, ownerIds: p.journals.map((j) => j.ownerId) });
    expect(all.balanced).toBe(true);
    expect(all.totalAssets).toBe(12_620_000); // 12,720,000 − ลูกหนี้ระหว่างกัน 100,000 ที่ตัดออกในงบรวม
    expect(all.eliminated).toBe(100_000);
    expect(all.retained.account).toBe(2_920_000);
    const tk = buildBalanceSheet(lines, { year: 2026, ownerIds: ["o-thanakorn"] });
    expect(tk.totalAssets).toBe(4_420_000);
    expect(tk.totalLiabilities).toBe(500_000);
    expect(tk.totalEquity).toBe(3_920_000);
  });
});

/* =========================================================== 4-5. ปฏิเสธทั้งไฟล์ พร้อมชีท/แถว */
const has = (issues: ImportIssue[], sheet: string, row: number | undefined, re: RegExp) =>
  issues.some((i) => i.sheet === sheet && (row === undefined || i.row === row) && re.test(i.message));

describe("ปฏิเสธทั้งไฟล์: งบดุลไม่ลงตัว", () => {
  it("3300 ผิดไป 10,000 → ปฏิเสธ บอกชีทและผลต่าง ไม่ดัดตัวเลขอื่นให้ตรง", () => {
    const wb = loadFixture();
    setCell(wb, TK, 26, "E", 1_910_000);
    const issues = parseBad(wb);
    expect(has(issues, TK, undefined, /ไม่ลงตัว.*10,000/)).toBe(true);
    expect(issues).toHaveLength(1);
  });

  it("ผิดสองชีทพร้อมกัน → รายงานทั้งสองในครั้งเดียว (ไม่ให้แก้ทีละรอบ)", () => {
    const wb = loadFixture();
    setCell(wb, TK, 26, "E", 1_910_000);
    setCell(wb, "BS-สุธี", 11, "E", 5_000); // ชีทสุธี: แถว 2310? ใส่ยอดแปลกๆ ให้ไม่ลงตัว
    const sheets = new Set(parseBad(wb).map((i) => i.sheet));
    expect(sheets.has(TK)).toBe(true);
    expect(sheets.size).toBeGreaterThanOrEqual(2);
  });

  it("ไฟล์ที่ผิดไม่มีผลลัพธ์ที่นำไปใช้ได้เลย (ไม่มี parsed บางส่วน)", () => {
    const wb = loadFixture();
    setCell(wb, TK, 26, "E", 1);
    const r = parseOpeningWorkbook(wb, ctxOf());
    expect(r.ok).toBe(false);
    expect("parsed" in r).toBe(false);
  });
});

describe("ปฏิเสธทั้งไฟล์: ผู้ถือ/บัญชี/ตัวเลขที่ไม่รู้จัก", () => {
  it("ชื่อชีทผู้ถือที่ไม่มีในระบบ → ปฏิเสธ ระบุชื่อชีท", () => {
    const wb = loadFixture();
    wb.sheets.find((s) => s.name === "BS-สุธี")!.name = "BS-คนแปลกหน้า";
    const issues = parseBad(wb);
    expect(has(issues, "BS-คนแปลกหน้า", undefined, /ไม่ตรงกับผู้ถือคนใดในระบบ/)).toBe(true);
    expect(has(issues, "(ทั้งไฟล์)", undefined, /ไม่พบชีท "BS-สุธี"/)).toBe(true);
  });

  it("ล็อตถือในชื่อคนที่ไม่มี → ปฏิเสธ ระบุแถวในชีทล็อต", () => {
    const wb = loadFixture();
    setCell(wb, "พอร์ตลงทุน (รายล็อต)", 7, "A", "นายสมมติ");
    expect(has(parseBad(wb), "พอร์ตลงทุน (รายล็อต)", 7, /ไม่ตรงกับผู้ถือ/)).toBe(true);
  });

  it("ผู้ถือที่ยังไม่เปิดใช้ (planned) ลงยอดตั้งต้นไม่ได้", () => {
    const ctx = ctxOf();
    ctx.owners.find((o) => o.id === "o-thanakorn")!.status = "planned";
    expect(has(parseBad(loadFixture(), ctx), TK, undefined, /ยังไม่เปิดใช้งาน/)).toBe(true);
  });

  it("รหัสบัญชีที่ไม่มีในผัง → ปฏิเสธ ระบุชีทและแถว", () => {
    const wb = loadFixture();
    setCell(wb, TK, 8, "A", "9999");
    setCell(wb, TK, 8, "E", 50_000);
    expect(has(parseBad(wb), TK, 8, /รหัส 9999.*ไม่มีรหัสนี้ในผังบัญชี/)).toBe(true);
  });

  it("รหัสรายได้/ค่าใช้จ่ายไม่ใช่ยอดตั้งต้น → ปฏิเสธ", () => {
    const wb = loadFixture();
    setCell(wb, TK, 27, "A", "4100");
    setCell(wb, TK, 27, "E", 10);
    expect(has(parseBad(wb), TK, 27, /ไม่ใช่บัญชีงบดุล/)).toBe(true);
  });

  it.each([
    ["3200", /เงินถอน/],
    ["3400", /ยังไม่เกิดขึ้นจริง/],
    ["3410", /ยังไม่เกิดขึ้นจริง/],
  ])("รหัส %s ใส่ในยอดตั้งต้นไม่ได้", (code, re) => {
    const wb = loadFixture();
    setCell(wb, TK, 27, "A", code);
    setCell(wb, TK, 27, "E", 10);
    expect(has(parseBad(wb), TK, 27, re)).toBe(true);
  });

  it("ตัวเลขอ่านไม่ออก → ปฏิเสธ ระบุแถว (ไม่เดา ไม่ปัดเป็น 0)", () => {
    const wb = loadFixture();
    setCell(wb, TK, 7, "E", "ยี่สิบพัน");
    expect(has(parseBad(wb), TK, 7, /อ่านเป็นตัวเลขไม่ได้/)).toBe(true);
  });

  it("ตัวเลขข้อความที่มีจุลภาคอ่านได้ แต่ทศนิยมเกินสตางค์ปฏิเสธ", () => {
    const wb = loadFixture();
    setCell(wb, TK, 7, "E", "20,000");
    expect(parseOk(wb).journals.find((j) => j.ownerId === "o-thanakorn")!.assets).toBe(4_420_000);
    setCell(wb, TK, 7, "E", 20_000.005);
    expect(has(parseBad(wb), TK, 7, /ทศนิยมเกิน 2/)).toBe(true);
  });

  it("ช่องที่เป็นสูตรไม่ถูกเชื่อ", () => {
    const wb = loadFixture();
    setCell(wb, TK, 6, "E", 1_000_000, true);
    expect(has(parseBad(wb), TK, 6, /เป็นสูตร/)).toBe(true);
  });

  it("ยอดติดลบ: ปฏิเสธทุกบัญชียกเว้น 3300 (ขาดทุนสะสม → เดบิต)", () => {
    const wb = loadFixture();
    setCell(wb, TK, 7, "E", -20_000);
    expect(has(parseBad(wb), TK, 7, /ติดลบไม่ได้/)).toBe(true);
    const wb2 = loadFixture();
    setCell(wb2, TK, 26, "E", -1_000); // ขาดทุนสะสม 1,000
    setCell(wb2, TK, 25, "E", 3_921_000); // ทุน + กำไรสะสม = 3,920,000 ให้ดุล
    const l = journalOf(parseOk(wb2), "o-thanakorn").lines.find((x) => x.coaCode === "3300")!;
    expect([l.debit, l.credit]).toEqual([1_000, 0]);
  });

  it("รหัสซ้ำสองแถวในชีทเดียว → ปฏิเสธ", () => {
    const wb = loadFixture();
    setCell(wb, TK, 27, "A", "1200");
    setCell(wb, TK, 27, "E", 5);
    expect(has(parseBad(wb), TK, 27, /ซ้ำกับแถว 7/)).toBe(true);
  });
});

describe("ปฏิเสธทั้งไฟล์: โครงไฟล์/วันที่/เงินสด/ล็อต", () => {
  it("ขาดชีทผู้ถือ → ปฏิเสธ (ว่างได้แต่ต้องมีชีท)", () => {
    const wb = loadFixture();
    wb.sheets = wb.sheets.filter((s) => s.name !== "BS-ธนวินท์");
    expect(has(parseBad(wb), "(ทั้งไฟล์)", undefined, /ไม่พบชีท "BS-ธนวินท์"/)).toBe(true);
  });

  it("ขาดชีทรายล็อต → ปฏิเสธ", () => {
    const wb = loadFixture();
    wb.sheets = wb.sheets.filter((s) => !s.name.startsWith("พอร์ต"));
    expect(has(parseBad(wb), "(ทั้งไฟล์)", undefined, /ไม่พบชีท "พอร์ตลงทุน/)).toBe(true);
  });

  it("วันตัดยอดในชีทไม่ตรงกับที่ระบุตอนนำเข้า → ปฏิเสธทุกชีทที่ต่าง", () => {
    const issues = parseBad(loadFixture(), ctxOf({ cutoff: "2026-10-31" }));
    expect(issues.filter((i) => /วันตัดยอด/.test(i.message)).length).toBe(6);
  });

  it("ชีทที่ไม่มีวันตัดยอดเลย → ปฏิเสธ", () => {
    const wb = loadFixture();
    setCell(wb, TK, 2, "A", "ไม่มีวันที่");
    expect(has(parseBad(wb), TK, 2, /ไม่พบ "ณ วันที่/)).toBe(true);
  });

  it("เงินสด 1100 ไม่เท่าตารางแยกบัญชี → ปฏิเสธ บอกส่วนต่าง", () => {
    const wb = loadFixture();
    setCell(wb, TK, 38, "E", 500_000);
    expect(has(parseBad(wb), TK, 6, /ต่างกัน 100,000/)).toBe(true);
  });

  it("บัญชีธนาคารที่ไม่มีในระบบ → ปฏิเสธ ระบุแถว (ไม่สร้างให้เอง ไม่เดา)", () => {
    const wb = loadFixture();
    setCell(wb, TK, 38, "B", "ธนากร - KBANK");
    expect(has(parseBad(wb), TK, 38, /ไม่มีในระบบเป็นของ ธนากร/)).toBe(true);
  });

  it("บัญชีธนาคารของคนอื่น (ชื่อซ้ำข้ามผู้ถือ) → ปฏิเสธ ไม่ผูกเงินผิดเจ้าของ", () => {
    const wb = loadFixture();
    setCell(wb, TK, 38, "B", "สุธี - TTB");
    expect(has(parseBad(wb), TK, 38, /ไม่มีในระบบเป็นของ ธนากร/)).toBe(true);
  });

  it("บัญชีธนาคารที่ปิดแล้ว → ปฏิเสธ", () => {
    const ctx = ctxOf();
    ctx.banks.find((b) => b.id === "b-tk-scb")!.isActive = false;
    expect(has(parseBad(loadFixture(), ctx), TK, 39, /ปิดใช้งาน/)).toBe(true);
  });

  it("บัญชีสกุลต่างประเทศ (FCD) → ปฏิเสธ ไม่ลงเป็นบาทเงียบๆ", () => {
    const ctx = ctxOf();
    ctx.banks.find((b) => b.id === "b-tk-scb")!.currency = "USD";
    expect(has(parseBad(loadFixture(), ctx), TK, 39, /สกุล USD.*ไม่ได้/)).toBe(true);
  });

  it("ชื่อบัญชีซ้ำสองบัญชีของผู้ถือเดียวกัน → ปฏิเสธ (ไม่ให้ตัวหลังชนะเงียบๆ)", () => {
    const ctx = ctxOf();
    ctx.banks.push({ id: "b-tk-scb-2", ownerId: "o-thanakorn", name: "ธนากร - SCB", isActive: true, currency: "THB" });
    expect(has(parseBad(loadFixture(), ctx), TK, 39, /ชื่อซ้ำกัน/)).toBe(true);
  });

  it("เงินสดที่มียอดแต่ไม่มีชื่อบัญชี → ปฏิเสธ", () => {
    const wb = loadFixture();
    setCell(wb, TK, 40, "E", 5);
    expect(has(parseBad(wb), TK, 40, /ไม่ได้ระบุชื่อบัญชี/)).toBe(true);
  });

  it("เงินสดไม่มีตารางแยกเลยแต่ใส่ 1100 → ปฏิเสธ (เงินสดต้องผูกบัญชีทุกบาท)", () => {
    const wb = loadFixture();
    setCell(wb, TK, 38, "E", null);
    setCell(wb, TK, 39, "E", null);
    expect(has(parseBad(wb), TK, 6, /ต่างกัน 1,000,000/)).toBe(true);
  });

  it("ล็อตรวมไม่เท่า 1700 → ปฏิเสธ", () => {
    const wb = loadFixture();
    setCell(wb, "พอร์ตลงทุน (รายล็อต)", 6, "E", 2_100);
    expect(has(parseBad(wb), TK, 15, /1700.*ต่างกัน/)).toBe(true);
  });

  it("มียอด 1700 แต่ไม่มีล็อตเลย → ปฏิเสธ", () => {
    const wb = loadFixture();
    for (const r of [6, 7, 8]) setCell(wb, "พอร์ตลงทุน (รายล็อต)", r, "A", null);
    expect(parseBad(wb).some((i) => i.sheet === TK && /1700/.test(i.message))).toBe(true);
  });

  it("ล็อตสกุลเงินต่างประเทศ → ปฏิเสธ (ไม่มีอัตราแลกเปลี่ยน ไม่เดา)", () => {
    const wb = loadFixture();
    setCell(wb, "พอร์ตลงทุน (รายล็อต)", 6, "I", "USD");
    expect(has(parseBad(wb), "พอร์ตลงทุน (รายล็อต)", 6, /นำเข้าได้เฉพาะ THB/)).toBe(true);
  });

  it("ล็อตวันที่ซื้อหลังวันตัดยอด หรืออ่านวันที่ไม่ออก → ปฏิเสธ", () => {
    const wb = loadFixture();
    setCell(wb, "พอร์ตลงทุน (รายล็อต)", 6, "D", "สัปดาห์หน้า");
    expect(has(parseBad(wb), "พอร์ตลงทุน (รายล็อต)", 6, /วันที่ซื้ออ่านเป็นวันที่ไม่ได้/)).toBe(true);
    const wb2 = loadFixture();
    setCell(wb2, "พอร์ตลงทุน (รายล็อต)", 6, "D", 47000);
    expect(has(parseBad(wb2), "พอร์ตลงทุน (รายล็อต)", 6, /หลังวันตัดยอด/)).toBe(true);
  });

  it("ประเภทล็อตที่ไม่รู้จัก → ปฏิเสธ", () => {
    const wb = loadFixture();
    setCell(wb, "พอร์ตลงทุน (รายล็อต)", 6, "B", "หวย");
    expect(has(parseBad(wb), "พอร์ตลงทุน (รายล็อต)", 6, /ประเภท "หวย"/)).toBe(true);
  });
});

/* =========================================================== ลายนิ้วมือ */
describe("ลายนิ้วมือของเนื้อหา", () => {
  it("อ่านไฟล์เดิมสองครั้งได้ค่าเดิม · เปลี่ยนตัวเลขหนึ่งตัว/วัน/ล็อต ค่าเปลี่ยน", () => {
    const a = fingerprintOf(parseOk());
    expect(fingerprintOf(parseOk())).toBe(a);
    const wb = loadFixture();
    setCell(wb, TK, 7, "E", 20_001);
    setCell(wb, TK, 26, "E", 1_920_001);
    expect(fingerprintOf(parseOk(wb))).not.toBe(a);
  });
  it("ไม่ขึ้นกับลำดับผู้ถือ/บรรทัด และแยกตามวันตัดยอด", () => {
    const p = parseOk();
    const shuffled: ParsedOpening = { ...p, journals: [...p.journals].reverse().map((j) => ({ ...j, lines: [...j.lines].reverse() })) };
    expect(fingerprintOf(shuffled)).toBe(fingerprintOf(p));
    expect(fingerprintOf({ ...p, cutoff: "2026-10-31" })).not.toBe(fingerprintOf(p));
  });
});

/* =========================================================== 2-3. แผนอัปโหลดซ้ำ / แก้ไข */
describe("อัปโหลดซ้ำ: เนื้อหาเดิมไม่สร้างซ้ำ", () => {
  it("ครั้งแรก = ใหม่ทั้งหมด 3 ใบ · ลงแล้วอัปโหลดไฟล์เดิมอีกกี่ครั้งก็ไม่มีอะไรเพิ่ม", () => {
    const led = new FakeLedger();
    const first = planOpeningImport(parseOk(), led.live(), new Map());
    expect(first.items.map((i) => i.action)).toEqual(["new", "new", "new"]);
    expect(first.totals.journals).toBe(3);
    led.apply(first, CUTOFF);
    expect(led.entries).toHaveLength(3);

    for (let k = 0; k < 3; k++) {
      const again = planOpeningImport(parseOk(), led.live(), new Map());
      expect(again.nothingToDo).toBe(true);
      expect(again.items.every((i) => i.action === "unchanged" && !i.post.length && !i.reverse.length)).toBe(true);
      expect(again.totals.journals).toBe(0);
      led.apply(again, CUTOFF);
    }
    expect(led.entries).toHaveLength(3);
    expect(led.deletes).toBe(0);
  });

  it("ไฟล์ที่เนื้อหาเดิมแต่บรรทัด/ลำดับต่างกัน (บันทึกใหม่) ก็ยังนับเป็นเดิม", () => {
    const led = new FakeLedger();
    led.apply(planOpeningImport(parseOk(), [], new Map()), CUTOFF);
    const p = parseOk();
    const shuffled: ParsedOpening = { ...p, journals: [...p.journals].reverse().map((j) => ({ ...j, lines: [...j.lines].reverse() })) };
    expect(planOpeningImport(shuffled, led.live(), new Map()).nothingToDo).toBe(true);
  });
});

describe("อัปโหลดไฟล์ที่แก้แล้ว: กลับรายการชุดเดิม ลงชุดใหม่ ห้ามลบ", () => {
  const corrected = () => {
    const wb = loadFixture();
    setCell(wb, TK, 13, "E", 3_100_000); // 1500 อสังหาฯ +100,000
    setCell(wb, TK, 26, "E", 2_020_000); // 3300 +100,000 ให้ดุล
    return parseOk(wb);
  };

  it("เฉพาะผู้ถือที่เปลี่ยนถูกแตะ · ใบเดิมถูกกลับ ใบใหม่ถูกลง · ยอดสุทธิ = ไฟล์ใหม่ · ไม่มี DELETE", () => {
    const led = new FakeLedger();
    led.apply(planOpeningImport(parseOk(), [], new Map()), CUTOFF);
    const oldTk = led.live().find((e) => e.ownerId === "o-thanakorn")!;
    const before = led.entries.length;

    const plan = planOpeningImport(corrected(), led.live(), new Map());
    const byOwner = Object.fromEntries(plan.items.map((i) => [i.ownerId, i]));
    expect(byOwner["o-thanakorn"].action).toBe("replace");
    expect(byOwner["o-thanakorn"].reverse).toEqual([oldTk.txnId]);
    expect(byOwner["o-sri"].action).toBe("unchanged");
    expect(byOwner["o-suthee"].action).toBe("unchanged");

    led.apply(plan, CUTOFF);
    expect(led.entries.length).toBe(before + 2); // 1 ใบกลับ + 1 ใบใหม่ · ใบเดิมยังอยู่ครบ
    expect(led.entries.find((e) => e.txnId === oldTk.txnId)).toBeDefined();
    expect(led.deletes).toBe(0);

    const net = led.net();
    expect(net.get("o-thanakorn|1500")).toBe(3_100_000);
    expect(net.get("o-thanakorn|3300")).toBe(-2_020_000);
    expect(net.get("o-thanakorn|1100")).toBe(1_000_000);
    expect(net.get("o-sri|1500")).toBe(5_000_000); // ผู้ถือที่ไม่เปลี่ยนไม่ถูกแตะ

    // งบดุลหลังแก้: ลงตัว และใช้ชุดใหม่ (ไม่นับซ้ำ)
    const { rows, ids } = led.asStatementRows();
    const bs = buildBalanceSheet(toStmtLines(rows, idToCode(ids)), { year: 2026, ownerIds: ["o-thanakorn"] });
    expect(bs.balanced).toBe(true);
    expect(bs.totalAssets).toBe(4_520_000);
  });

  it("แก้แล้วอัปโหลดซ้ำอีกครั้ง = ไม่เปลี่ยน (ไม่ลงซ้ำ ไม่กลับซ้ำ)", () => {
    const led = new FakeLedger();
    led.apply(planOpeningImport(parseOk(), [], new Map()), CUTOFF);
    led.apply(planOpeningImport(corrected(), led.live(), new Map()), CUTOFF);
    const n = led.entries.length;
    const again = planOpeningImport(corrected(), led.live(), new Map());
    expect(again.nothingToDo).toBe(true);
    led.apply(again, CUTOFF);
    expect(led.entries.length).toBe(n);
  });

  it("แก้ไปแก้มา: กลับไปเป็นไฟล์แรก → ยอดสุทธิเท่าไฟล์แรก", () => {
    const led = new FakeLedger();
    led.apply(planOpeningImport(parseOk(), [], new Map()), CUTOFF);
    led.apply(planOpeningImport(corrected(), led.live(), new Map()), CUTOFF);
    led.apply(planOpeningImport(parseOk(), led.live(), new Map()), CUTOFF);
    expect(led.net().get("o-thanakorn|1500")).toBe(3_000_000);
    expect(led.live().filter((e) => e.ownerId === "o-thanakorn")).toHaveLength(1);
  });

  it("ใบที่ถูกกลับแล้วไม่ถูกนับว่าเป็นชุดเดิมอีก (ไม่กลับซ้ำ)", () => {
    const led = new FakeLedger();
    led.apply(planOpeningImport(parseOk(), [], new Map()), CUTOFF);
    led.apply(planOpeningImport(corrected(), led.live(), new Map()), CUTOFF);
    const plan = planOpeningImport(corrected(), led.live(), new Map());
    expect(plan.items.flatMap((i) => i.reverse)).toEqual([]);
  });

  it("วันตัดยอดเปลี่ยน → กลับชุดเดิมแล้วลงใหม่ตามวันใหม่ พร้อมหมายเหตุ", () => {
    const led = new FakeLedger();
    led.apply(planOpeningImport(parseOk(), [], new Map()), CUTOFF);
    const wb = loadFixture();
    for (const name of ["BS-SRI Corporation", "BS-สุธี", TK, "BS-ธนวินท์", "BS-เบ็ญจพร", "BS-สุดจิตต์"]) setCell(wb, name, 2, "A", "ณ วันที่ 31/10/2026");
    const plan = planOpeningImport(parseOk(wb, ctxOf({ cutoff: "2026-10-31" })), led.live(), new Map());
    expect(plan.items.every((i) => i.action === "replace" && /วันตัดยอดเปลี่ยน/.test(i.note ?? ""))).toBe(true);
  });

  it("ผู้ถือที่เคยมียอดแต่ไฟล์ใหม่ว่าง → ถอน (กลับรายการ ไม่ลบ)", () => {
    const led = new FakeLedger();
    led.apply(planOpeningImport(parseOk(), [], new Map()), CUTOFF);
    const wb = loadFixture();
    // ล้างยอดทุกบัญชีของสุธี (ในไฟล์ตัวอย่างมี 1100 / 2310 / 3100) และตารางแยกเงินสด
    const sh = wb.sheets.find((s) => s.name === "BS-สุธี")!;
    for (const [r, cols] of sh.rows) if (/^\d{4}$/.test(String(cols.get("A")?.value ?? ""))) setCell(wb, "BS-สุธี", r, "E", null);
    for (const r of [38, 39, 40]) setCell(wb, "BS-สุธี", r, "E", null);
    const plan = planOpeningImport(parseOk(wb), led.live(), new Map(OWNERS.map((o) => [o.id, o.name])));
    const st = plan.items.find((i) => i.ownerId === "o-suthee")!;
    expect(st.action).toBe("retract");
    expect(st.post).toEqual([]);
    led.apply(plan, CUTOFF);
    expect([...led.net().keys()].some((k) => k.startsWith("o-suthee|"))).toBe(false);
    expect(led.deletes).toBe(0);
  });

  it("มีใบเดิมที่ยังไม่ถูกกลับหลายใบของคนเดียว (เช่นตกค้างจากรอบก่อน) → กลับครบทุกใบ", () => {
    const led = new FakeLedger();
    const p = parseOk();
    const j = journalOf(p, "o-thanakorn");
    led.post("o-thanakorn", CUTOFF, j.lines.slice(0, 3));
    led.post("o-thanakorn", CUTOFF, j.lines.slice(3));
    const plan = planOpeningImport(p, led.live(), new Map());
    const it = plan.items.find((i) => i.ownerId === "o-thanakorn")!;
    // แยกสองใบแต่รวมกันได้ชุดเดียวกับไฟล์ → เนื้อหาเหมือนกัน ไม่ต้องทำอะไร
    expect(it.action).toBe("unchanged");
    led.post("o-thanakorn", CUTOFF, [{ coaCode: "1200", bankAccountId: null, debit: 1, credit: 0 }]);
    const plan2 = planOpeningImport(p, led.live(), new Map());
    const it2 = plan2.items.find((i) => i.ownerId === "o-thanakorn")!;
    expect(it2.action).toBe("replace");
    expect(it2.reverse).toHaveLength(3);
  });

  it("ตัวเลขรวมของแผน: สินทรัพย์ = หนี้สิน + ส่วนของเจ้าของ", () => {
    const t = planOpeningImport(parseOk(), [], new Map()).totals;
    expect(t.assets).toBe(t.liabilities + t.equity);
  });
});

describe("ข้อมูลอ้างอิงใช้ได้จริง", () => {
  it("ธนาคารในเทสต์ตรงกับที่ไฟล์ตัวอย่างใช้ (กันเทสต์ผ่านเพราะข้อมูลไม่ครบ)", () => {
    expect(BANKS.map((b) => b.name)).toContain("ธนากร - BBL 888");
  });
});
