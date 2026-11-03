import Image from "next/image";
import Link from "next/link";
import { Notice } from "@/components/assets/asset-parts";
import { loadDashboard } from "@/components/dashboard/dashboard-data";
import type { Todo } from "@/components/dashboard/dashboard-model";
import { gateRoute } from "@/lib/auth/gate";
import { getAccess } from "@/lib/auth/session";
import { canOpen } from "@/lib/auth/routes";
import { money } from "@/lib/format";
import { PRIORITY_PILL } from "@/lib/tone";
import { cn } from "@/lib/utils";

const m = (n: number) => money(n, { dash: false });
const LINK_BTN =
  "flex min-h-control-mobile items-center justify-center rounded border px-4 text-base font-semibold no-underline hover:no-underline focus-visible:outline-none focus-visible:ring-[3px] focus-visible:ring-brand-600 focus-visible:ring-offset-2";

/**
 * หน้าแรกมือถือ — ข้อมูลจริงจากสมุดบัญชี (ชุดเดียวกับหน้าแรกเดสก์ท็อป) ใช้ได้ตั้งแต่จอ 320px
 * กรอบกว้างไม่เกิน 430px และเต็มจอบนมือถือจริง (ไม่ใช่กรอบจำลองคงที่) · ปุ่มสูง ≥ 56px มีข้อความกำกับ
 */
export default async function MobileHomePage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  // กั้นตามสิทธิ์ (ความสะดวก ไม่ใช่ความปลอดภัย — RLS คือของจริง · ดู src/lib/auth/gate.tsx)
  const denied = await gateRoute("/m", "SRI OS");
  if (denied) return denied;

  const sp = await searchParams;
  const one = (k: string) => (Array.isArray(sp[k]) ? (sp[k] as string[])[0] : (sp[k] as string | undefined));
  const [data, access] = await Promise.all([loadDashboard({ owner: one("owner"), year: one("year") }), getAccess()]);
  const initial = (access.profile?.displayName ?? access.user?.email ?? "ผ").trim().slice(0, 1);
  // เมนูที่ผู้ใช้เปิดไม่ได้ไม่แสดง (ความสะดวก) — ความปลอดภัยจริงคือ RLS
  const can = (path: string) => canOpen(access.permissions, path);

  return (
    <div className="min-h-screen bg-canvas">
      <div className="mx-auto flex min-h-screen w-full max-w-[430px] flex-col bg-canvas">
        <div className="flex items-center gap-2.5 border-b border-line bg-surface p-[14px_16px]">
          <Image src="/sri-logo.png" alt="SRI" width={32} height={32} className="h-8 w-8 object-contain" />
          <div className="mr-auto text-lg font-bold text-brand-600">SRI OS</div>
          <div aria-label={`ผู้ใช้ ${access.profile?.displayName ?? ""}`} className="flex h-10 w-10 items-center justify-center rounded-pill bg-brand-50 text-base font-bold text-brand-600">
            {initial}
          </div>
        </div>

        <div className="flex flex-1 flex-col gap-3 p-4">
          {!data.ok ? (
            <Notice tone="neg">
              โหลดข้อมูลจากฐานข้อมูลไม่สำเร็จ จึงไม่แสดงตัวเลขให้: {data.error}
              <div className="mt-1 text-sm">ลองโหลดหน้านี้ใหม่ ถ้ายังไม่ได้ให้แจ้งผู้ดูแลระบบ</div>
            </Notice>
          ) : (
            <>
              {/* ผู้ถือ — ฟอร์ม GET ล้วน กดปุ่มแล้วโหลดหน้าใหม่ตามมุมมอง */}
              <form method="get" className="flex flex-col gap-2">
                <label htmlFor="m-owner" className="text-sm text-ink-600">ดูข้อมูลของ</label>
                <select
                  id="m-owner"
                  name="owner"
                  defaultValue={data.view}
                  className="min-h-control-mobile w-full rounded border border-line bg-surface px-3 text-base text-ink-900 focus-visible:outline-none focus-visible:border-brand-600 focus-visible:ring-[3px] focus-visible:ring-brand-600"
                >
                  <option value="family">รวมทั้งกลุ่ม (SRI Family)</option>
                  {data.owners
                    .filter((o) => o.status === "active")
                    .map((o) => (
                      <option key={o.id} value={o.id}>{o.name}</option>
                    ))}
                </select>
                <button type="submit" className={cn(LINK_BTN, "border-line bg-surface text-ink-900")}>ดูมุมมองนี้</button>
              </form>

              {!data.figures ? (
                <Notice tone="info">ตำแหน่งของคุณไม่มีสิทธิ์อ่านสมุดบัญชี จึงไม่แสดงตัวเลขการเงิน (ไม่ใช่ว่าเป็นศูนย์)</Notice>
              ) : (
                <>
                  <div className="rounded-card border border-line bg-surface p-4">
                    <div className="text-sm text-ink-600">ส่วนของเจ้าของ ปี {data.year} (ตามต้นทุนในสมุด)</div>
                    <div className={cn("text-display font-semibold tabular-nums", data.figures.bs.totalEquity < 0 && "text-neg")}>{m(data.figures.bs.totalEquity)}</div>
                    <div className="text-sm text-ink-600">สินทรัพย์ {m(data.figures.bs.totalAssets)} − หนี้สิน {m(data.figures.bs.totalLiabilities)}</div>
                  </div>
                  {!data.figures.bs.balanced ? <Notice tone="neg">งบแสดงฐานะการเงินไม่ดุล ต่างกัน {m(data.figures.bs.difference)} บาท — ห้ามใช้ตัวเลขก่อนหาสาเหตุ</Notice> : null}

                  <div className="grid grid-cols-2 gap-3">
                    <Stat label={`กำไรปี ${data.year}`} value={data.figures.pl.net} signed />
                    <Stat label="เงินสดสุทธิปีนี้" value={data.figures.cf?.net ?? null} signed missing="คำนวณไม่ได้" />
                    <Stat label="ค้างรับ" value={data.figures.receivable.total} />
                    <Stat label="ค้างจ่าย" value={data.figures.payable.total} />
                  </div>
                </>
              )}

              <div className="rounded-card border border-line bg-surface p-4">
                <div className="mb-1 text-lg font-semibold">ที่ควรทำก่อน</div>
                {data.todos.length === 0 ? (
                  <div className="py-2 text-base text-ink-600">ไม่มีงานค้างจากข้อมูลในระบบตอนนี้</div>
                ) : (
                  data.todos.slice(0, 4).map((t: Todo) => (
                    <Link key={t.title} href={t.href} className="block min-h-control-mobile border-t border-line py-2.5 no-underline hover:no-underline">
                      <div className="flex items-start gap-2">
                        <span className={cn("inline-flex h-[26px] flex-none items-center rounded-pill px-2 text-sm font-bold", PRIORITY_PILL[t.priority])}>{t.priority}</span>
                        <span className="text-base font-semibold leading-[26px] text-ink-900">{t.title}</span>
                      </div>
                      <div className="text-sm leading-6 text-ink-600">{t.why}</div>
                    </Link>
                  ))
                )}
              </div>

              {data.canSeeApprovals && can("/approvals") ? (
                <div className="flex flex-col gap-2.5 rounded-card border border-brand-100 bg-brand-50 p-4">
                  <div className="text-base font-semibold">
                    {data.pendingApprovals.count > 0
                      ? `มี ${data.pendingApprovals.count} รายการรออนุมัติ · รวม ${m(data.pendingApprovals.total)} บาท`
                      : "ไม่มีรายการรออนุมัติ"}
                  </div>
                  <Link href="/approvals" className={cn(LINK_BTN, "border-brand-600 bg-brand-600 text-white")}>
                    ไปหน้าอนุมัติ
                  </Link>
                </div>
              ) : null}
            </>
          )}
        </div>

        <nav aria-label="เมนูหลัก" className="sticky bottom-0 grid grid-cols-4 items-stretch gap-1 border-t border-line bg-surface p-[8px_8px_16px]">
          <span aria-current="page" className="flex min-h-control-mobile items-center justify-center text-base font-semibold text-brand-600">หน้าแรก</span>
          {can("/approvals") ? (
            <Link href="/approvals" className="flex min-h-control-mobile items-center justify-center gap-1 text-base text-ink-600 no-underline hover:no-underline">
              อนุมัติ
              {data.ok && data.canSeeApprovals && data.pendingApprovals.count > 0 ? (
                <span className="inline-flex h-[26px] min-w-[26px] items-center justify-center rounded-pill border border-warn bg-warn-bg px-1.5 text-sm font-bold text-warn-fg">
                  {data.pendingApprovals.count}
                </span>
              ) : null}
            </Link>
          ) : (
            <span />
          )}
          {can("/m/new") ? (
            <Link href="/m/new" className="flex min-h-control-mobile items-center justify-center rounded-2xl bg-brand-600 text-base font-bold text-white no-underline hover:no-underline">
              ＋ บันทึก
            </Link>
          ) : (
            <span />
          )}
          {can("/assets") ? (
            <Link href="/assets" className="flex min-h-control-mobile items-center justify-center text-base text-ink-600 no-underline hover:no-underline">
              ทรัพย์สิน
            </Link>
          ) : (
            <Link href="/dashboard" className="flex min-h-control-mobile items-center justify-center text-base text-ink-600 no-underline hover:no-underline">
              หน้าเต็ม
            </Link>
          )}
        </nav>
      </div>
    </div>
  );
}

function Stat({ label, value, signed, missing = "—" }: { label: string; value: number | null; signed?: boolean; missing?: string }) {
  return (
    <div className="rounded-card border border-line bg-surface p-3.5">
      <div className="text-sm text-ink-600">{label}</div>
      {value === null ? (
        <div className="text-base text-ink-600">{missing}</div>
      ) : (
        <div className={cn("text-h2 font-semibold tabular-nums", signed && value < 0 && "text-neg", signed && value > 0 && "text-pos")}>{m(value)}</div>
      )}
    </div>
  );
}
