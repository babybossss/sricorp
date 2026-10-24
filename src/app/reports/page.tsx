import { PageShell } from "@/components/layout/page-shell";
import { BalanceSheetView } from "@/components/reports/balance-sheet-view";
import { CashFlowView } from "@/components/reports/cash-flow-view";
import { ProfitLossView } from "@/components/reports/profit-loss-view";
import { Notice, ReportControls, TABS, type ReportTab } from "@/components/reports/parts";
import { gateRoute } from "@/lib/auth/gate";
import { loadStatementData } from "@/lib/db/statements-server";
import {
  buildBalanceSheet,
  buildCashFlowReport,
  buildProfitLoss,
  buildUnrealised,
  ownersInView,
  parseFiscalYear,
} from "@/lib/db/statements";
import { todayDmy } from "@/lib/format";

/**
 * งบการเงินสามใบ — คำนวณสดจาก `v_ledger_posted` ทุกครั้งที่เปิด (ไม่เก็บ ไม่มีตารางสรุป)
 * กรองตามผู้ถือได้ และมีมุมมองรวมทุกผู้ถือ · ปีบัญชี ม.ค.–ธ.ค.
 */
export default async function ReportsPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const denied = await gateRoute("/reports", "งบการเงิน");
  if (denied) return denied;

  const sp = await searchParams;
  const one = (k: string) => (Array.isArray(sp[k]) ? (sp[k] as string[])[0] : (sp[k] as string | undefined));
  const thisYear = Number(todayDmy().slice(6));
  const year = parseFiscalYear(one("year")) ?? thisYear;
  const tab: ReportTab = (TABS.find((t) => t.key === one("tab"))?.key ?? "bs") as ReportTab;
  const ownerParam = one("owner") ?? "family";

  const data = await loadStatementData();

  return (
    <PageShell title="งบการเงิน">
      {!data.ok ? (
        <Notice tone="neg">
          โหลดสมุดบัญชีจากฐานข้อมูลไม่สำเร็จ จึงทำงบไม่ได้: {data.error}
          <div className="mt-1 text-sm">ลองโหลดหน้านี้ใหม่ ถ้ายังไม่ได้ให้แจ้งผู้ดูแลระบบ</div>
        </Notice>
      ) : (
        <Statements data={data} tab={tab} year={year} ownerParam={ownerParam} thisYear={thisYear} />
      )}
    </PageShell>
  );
}

function Statements({
  data,
  tab,
  year,
  ownerParam,
  thisYear,
}: {
  data: Extract<Awaited<ReturnType<typeof loadStatementData>>, { ok: true }>;
  tab: ReportTab;
  year: number;
  ownerParam: string;
  thisYear: number;
}) {
  const visible = data.owners.filter((o) => o.status === "active" || data.lines.some((l) => l.ownerId === o.id));
  const allIds = data.owners.map((o) => o.id);
  const ownerIds = ownersInView(ownerParam, allIds);
  const ownerKnown = ownerParam === "family" || allIds.includes(ownerParam);
  const view = ownerKnown ? ownerParam : "family";
  const ownerLabel = view === "family" ? "SRI Family (รวมทุกชื่อ)" : data.owners.find((o) => o.id === view)?.name ?? view;

  const firstYear = data.lines.reduce((min, l) => Math.min(min, Number(l.docDate.slice(0, 4))), thisYear);
  const lastYear = data.lines.reduce((max, l) => Math.max(max, Number(l.docDate.slice(0, 4))), thisYear);
  const years = Array.from({ length: Math.max(lastYear, year) - Math.min(firstYear, year) + 1 }, (_, i) => Math.max(lastYear, year) - i);

  const opts = { year, ownerIds };
  const bs = buildBalanceSheet(data.lines, opts);

  return (
    <div className="flex min-w-0 flex-col gap-4">
      <ReportControls tab={tab} year={year} owner={view} years={years} owners={visible.map((o) => ({ id: o.id, name: o.name }))} />
      {!ownerKnown ? <Notice tone="warn">ไม่พบผู้ถือที่เลือก จึงแสดงมุมมองรวมทุกชื่อแทน</Notice> : null}
      {tab === "bs" ? <BalanceSheetView bs={bs} ownerLabel={ownerLabel} /> : null}
      {tab === "pl" ? (
        <ProfitLossView pl={buildProfitLoss(data.lines, opts)} unrealised={buildUnrealised(data.lines, opts)} ownerLabel={ownerLabel} />
      ) : null}
      {tab === "cf" ? <CashFlowSafe lines={data.lines} opts={opts} bs={bs} ownerLabel={ownerLabel} /> : null}
    </div>
  );
}

function CashFlowSafe({
  lines,
  opts,
  bs,
  ownerLabel,
}: {
  lines: Parameters<typeof buildCashFlowReport>[0];
  opts: { year: number; ownerIds: string[] };
  bs: ReturnType<typeof buildBalanceSheet>;
  ownerLabel: string;
}) {
  try {
    return <CashFlowView cf={buildCashFlowReport(lines, { ...opts, balanceSheet: bs })} ownerLabel={ownerLabel} />;
  } catch (e) {
    // ข้อมูลในสมุดไม่ผ่านด่านของงบกระแสเงินสด — บอกเหตุผลตรงๆ ไม่แสดงงบครึ่งเดียว
    return <Notice tone="neg">ประกอบงบกระแสเงินสดไม่ได้: {e instanceof Error ? e.message : String(e)}</Notice>;
  }
}
