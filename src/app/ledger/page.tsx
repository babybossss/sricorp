import { PageShell } from "@/components/layout/page-shell";
import { LedgerTabs } from "@/components/ledger/ledger-tabs";
import { PeriodBar } from "@/components/reports/period-bar";
import { gateRoute } from "@/lib/auth/gate";
import { ledgerPeriod } from "@/lib/db/ledger-entries";
import { loadLedgerEntries } from "@/lib/db/ledger-entries-server";
import { loadPendingAccruals } from "@/lib/db/pending-accruals-server";
import { parseFiscalYear, parseMonth } from "@/lib/db/statements";
import { todayDmy } from "@/lib/format";

export default async function LedgerPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  // กั้นตามสิทธิ์ (ความสะดวก ไม่ใช่ความปลอดภัย — RLS คือของจริง · ดู src/lib/auth/gate.tsx)
  const denied = await gateRoute("/ledger", "สมุดบัญชี (Ledger)");
  if (denied) return denied;

  // ?year= ?month= เหมือน /reports และ /balance — ค่าเสียถือเป็น "ปีนี้ / ทั้งปี" ไม่ใช่วันที่มั่ว
  const sp = await searchParams;
  const one = (k: string) => (Array.isArray(sp[k]) ? (sp[k] as string[])[0] : (sp[k] as string | undefined));
  const year = parseFiscalYear(one("year")) ?? Number(todayDmy().slice(6));
  const month = parseMonth(one("month"));
  const period = ledgerPeriod(year, month);

  // รายการสมุดอ่านจาก v_ledger_posted เท่านั้น (D-107) — ห้ามอ่านตาราง transactions ตรง
  // รายการค้างรับ-ค้างจ่ายไม่กรองตามงวด: ต้องเห็นทุกใบที่ยังไม่ล้าง ไม่งั้นลูกหนี้ข้ามปีหายจากหน้ายืนยัน
  const [ledger, pending] = await Promise.all([loadLedgerEntries(period), loadPendingAccruals()]);

  const sel =
    "min-h-control rounded border border-line bg-surface px-3 text-base text-ink-900 focus-visible:outline-none focus-visible:border-brand-600 focus-visible:ring-[3px] focus-visible:ring-brand-600";
  const thisYear = Number(todayDmy().slice(6));
  const lo = Math.min(year, thisYear - 5);
  const hi = Math.max(year, thisYear + 1);
  const years = Array.from({ length: hi - lo + 1 }, (_, i) => hi - i);

  return (
    <PageShell title="สมุดบัญชี (Ledger)">
      <div className="flex min-w-0 flex-col gap-4">
        {/* ผู้ถือเก็บในตัวสลับมุมมอง (ไม่อยู่ใน URL) จึงไม่หลุดเวลาเปลี่ยนเดือน */}
        <PeriodBar basePath="/ledger" year={year} month={month} />
        <form method="get" action="/ledger" className="flex flex-wrap items-end gap-3 rounded-card border border-line bg-surface p-4 shadow-card">
          {month === null ? null : <input type="hidden" name="month" value={month} />}
          <label className="flex min-w-[160px] flex-col gap-1.5">
            <span className="text-base text-ink-600">ปี</span>
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
            แสดงรายการของปีนี้
          </button>
        </form>
        <LedgerTabs ledger={ledger} pending={pending} period={period} />
      </div>
    </PageShell>
  );
}
