import Link from "next/link";
import { PageShell } from "@/components/layout/page-shell";
import { BalanceTree } from "@/components/balance/balance-tree";
import { Notice, m } from "@/components/reports/parts";
import { gateRoute } from "@/lib/auth/gate";
import { loadStatementData } from "@/lib/db/statements-server";
import { buildBalanceSheet, ownersInView, parseFiscalYear } from "@/lib/db/statements";
import { allocation, buildBalanceTree, hasLedgerData, navByOwner } from "@/lib/db/balance-tree";
import { todayDmy } from "@/lib/format";

/**
 * งบดุล & ทรัพย์สิน — ต้นไม้ของงบแสดงฐานะการเงินที่คำนวณสดจากสมุด (`v_ledger_posted`) ด้วย `buildBalanceSheet()` ตัวเดียวกับ /reports
 * กรองตามผู้ถือได้ · ไม่มีตัวเลขจำลอง · ข้อมูลที่สมุดยังไม่มี (ต้นทุนรายทรัพย์ ราคาตลาด Yield) ไม่แสดง
 */
export default async function BalancePage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  // กั้นตามสิทธิ์ (ความสะดวก ไม่ใช่ความปลอดภัย — RLS คือของจริง · ดู src/lib/auth/gate.tsx)
  const denied = await gateRoute("/balance", "งบดุล & ทรัพย์สิน");
  if (denied) return denied;

  const sp = await searchParams;
  const one = (k: string) => (Array.isArray(sp[k]) ? (sp[k] as string[])[0] : (sp[k] as string | undefined));
  const thisYear = Number(todayDmy().slice(6));
  const year = parseFiscalYear(one("year")) ?? thisYear;
  const ownerParam = one("owner") ?? "family";

  const data = await loadStatementData();
  if (!data.ok) {
    return (
      <PageShell title="งบดุล & ทรัพย์สิน">
        <Notice tone="neg">
          โหลดสมุดบัญชีจากฐานข้อมูลไม่สำเร็จ จึงแสดงทรัพย์สินไม่ได้: {data.error}
          <div className="mt-1 text-sm">ลองโหลดหน้านี้ใหม่ ถ้ายังไม่ได้ให้แจ้งผู้ดูแลระบบ — ระบบไม่แสดงตัวเลขจำลองแทน</div>
        </Notice>
      </PageShell>
    );
  }

  const allIds = data.owners.map((o) => o.id);
  const ownerKnown = ownerParam === "family" || allIds.includes(ownerParam);
  const view = ownerKnown ? ownerParam : "family";
  const ownerIds = ownersInView(view, allIds);
  const ownerLabel = view === "family" ? "SRI Family (รวมทุกชื่อ)" : data.owners.find((o) => o.id === view)?.name ?? view;
  const visible = data.owners.filter((o) => o.status === "active" || data.lines.some((l) => l.ownerId === o.id));

  const lastYear = data.lines.reduce((max, l) => Math.max(max, Number(l.docDate.slice(0, 4))), thisYear);
  const firstYear = data.lines.reduce((min, l) => Math.min(min, Number(l.docDate.slice(0, 4))), thisYear);
  const years = Array.from({ length: Math.max(lastYear, year) - Math.min(firstYear, year) + 1 }, (_, i) => Math.max(lastYear, year) - i);

  const bs = buildBalanceSheet(data.lines, { year, ownerIds });
  const tree = buildBalanceTree(bs);
  const nav = navByOwner(data.lines, visible.map((o) => o.id), year);
  const shares = allocation(bs);
  const has = hasLedgerData(data.lines, ownerIds, year);
  const sel =
    "min-h-control w-full rounded border border-line bg-surface px-3 text-base text-ink-900 focus-visible:outline-none focus-visible:border-brand-600 focus-visible:ring-[3px] focus-visible:ring-brand-100";

  return (
    <PageShell title="งบดุล & ทรัพย์สิน">
      <div className="flex min-w-0 flex-col gap-4">
        <form method="get" action="/balance" className="flex flex-wrap items-end gap-3 rounded-card border border-line bg-surface p-4 shadow-card">
          <label className="flex min-w-[220px] flex-1 flex-col gap-1.5">
            <span className="text-base text-ink-600">ผู้ถือกรรมสิทธิ์</span>
            <select name="owner" defaultValue={view} className={sel}>
              <option value="family">SRI Family (รวมทุกชื่อ)</option>
              {visible.map((o) => (
                <option key={o.id} value={o.id}>
                  {o.name}
                </option>
              ))}
            </select>
          </label>
          <label className="flex min-w-[160px] flex-col gap-1.5">
            <span className="text-base text-ink-600">ณ สิ้นปี</span>
            <select name="year" defaultValue={String(year)} className={sel}>
              {years.map((y) => (
                <option key={y} value={y}>
                  {y}
                </option>
              ))}
            </select>
          </label>
          <button
            type="submit"
            className="inline-flex min-h-control items-center justify-center rounded border border-brand-600 bg-brand-600 px-[22px] text-base font-semibold text-white hover:bg-brand-700 focus-visible:outline-none focus-visible:ring-[3px] focus-visible:ring-brand-600 focus-visible:ring-offset-2"
          >
            แสดงทรัพย์สิน
          </button>
          <Link href={`/reports?tab=bs&year=${year}&owner=${encodeURIComponent(view)}`} className="inline-flex min-h-control items-center text-base">
            เปิดงบแสดงฐานะการเงินฉบับเต็ม
          </Link>
        </form>

        {!ownerKnown ? <Notice tone="warn">ไม่พบผู้ถือที่เลือก จึงแสดงมุมมองรวมทุกชื่อแทน</Notice> : null}

        {!has ? (
          <Notice tone="info">
            ยังไม่มีรายการในสมุดบัญชีของ {ownerLabel} ถึงสิ้นปี {year} — ไม่มีตัวเลขให้แสดง (ไม่ใช่ว่ามียอดเป็นศูนย์) · ลงรายการหรือนำเข้ายอดตั้งต้นก่อน
          </Notice>
        ) : (
          <>
            {bs.balanced ? null : (
              <Notice tone="neg">
                <b>งบไม่ดุล</b> — สินทรัพย์ {m(bs.totalAssets)} ต่างจากหนี้สิน + ส่วนของเจ้าของ {m(bs.totalLiabilitiesAndEquity)} อยู่ {m(bs.difference)} บาท
                ห้ามใช้ตัวเลขนี้ก่อนหาสาเหตุ
              </Notice>
            )}
            {bs.anomalies.map((a) => (
              <Notice key={a} tone="warn">
                {a}
              </Notice>
            ))}
            <div className="text-base text-ink-600">
              {ownerLabel} · ณ วันที่ 31 ธ.ค. {year}
              {bs.consolidated ? " · งบรวม (ตัดรายการระหว่างกันที่หักกันได้พอดี)" : ""}
            </div>
            <div className="grid items-start gap-4 xl:[grid-template-columns:minmax(0,1fr)_340px]">
              <BalanceTree key={`${view}-${year}`} nodes={tree} />
              <div className="flex min-w-0 flex-col gap-4">
                <div className="rounded-card border border-line bg-surface p-[18px_20px] shadow-card">
                  <div className="text-lg font-semibold">มูลค่าสุทธิ (NAV)</div>
                  <div className="text-h2 font-semibold tabular-nums">฿ {m(bs.totalAssets - bs.totalLiabilities)}</div>
                  <div className="text-base text-ink-600">สินทรัพย์ {m(bs.totalAssets)} − หนี้สิน {m(bs.totalLiabilities)}</div>
                </div>
                {shares.length > 0 ? (
                  <div className="rounded-card border border-line bg-surface p-[18px_20px] shadow-card">
                    <div className="mb-2 text-lg font-semibold">สัดส่วนสินทรัพย์</div>
                    {shares.map((s) => (
                      <div key={s.name} className="border-t border-line py-2.5 text-base first:border-t-0">
                        <div className="flex items-center justify-between gap-3">
                          <span>{s.name}</span>
                          <b className="tabular-nums">{s.pct.toFixed(1)}%</b>
                        </div>
                        <div className="mt-1 h-2.5 rounded-pill bg-canvas">
                          <div className="h-2.5 rounded-pill bg-brand-600" style={{ width: `${Math.max(0, Math.min(100, s.pct))}%` }} />
                        </div>
                      </div>
                    ))}
                  </div>
                ) : null}
                <div className="rounded-card border border-line bg-surface p-[18px_20px] shadow-card">
                  <div className="mb-2 text-lg font-semibold">NAV แยกตามชื่อผู้ถือ</div>
                  {nav.map((n) => {
                    const o = data.owners.find((x) => x.id === n.ownerId);
                    return (
                      <div key={n.ownerId} className="flex items-center gap-2.5 border-t border-line py-2.5 text-base first:border-t-0">
                        <span className="h-2.5 w-2.5 rounded-pill bg-holder-group" style={o?.color ? { background: o.color } : undefined} />
                        {o?.name ?? n.ownerId}
                        <b className="ml-auto tabular-nums">{n.hasData ? m(n.nav) : <span className="font-normal text-ink-600">ไม่มีรายการ</span>}</b>
                      </div>
                    );
                  })}
                  <div className="mt-2 border-t border-line pt-2 text-base leading-7 text-ink-600">
                    ถือในชื่อบุคคลก็ยังเป็นเงินกองกลางของ SRI Family — ตัวเลขนี้บอกแค่ว่าใครถือกรรมสิทธิ์ (ผลรวมรายคนอาจไม่เท่า NAV รวม เพราะงบรวมตัดรายการระหว่างกัน)
                  </div>
                </div>
              </div>
            </div>
          </>
        )}
      </div>
    </PageShell>
  );
}
