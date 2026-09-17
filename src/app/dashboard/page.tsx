import Link from "next/link";
import { PageShell } from "@/components/layout/page-shell";
import { Card, CardBody, CardTitle, CardLabel } from "@/components/ui/card";
import { Pill } from "@/components/ui/pill";
import { Button } from "@/components/ui/button";
import { KPIS, YIELDS, TODOS, TEAM_TASKS, EXPIRING_CONTRACTS } from "@/lib/mock/dashboard";
import { PRIORITY_PILL } from "@/lib/tone";
import { cn } from "@/lib/utils";

export default function DashboardPage() {
  return (
    <PageShell title="หน้าแรก">
      <div className="flex flex-col gap-4">
        {/* แถว KPI หลัก 4 กล่อง */}
        <div className="grid gap-4 [grid-template-columns:repeat(auto-fit,minmax(240px,1fr))]">
          {KPIS.map((k) => (
            <Card key={k.label}>
              <CardBody className="flex flex-col gap-1">
                <CardLabel className="min-h-12">
                  {k.label} <span className="text-ink-400">{k.en}</span>
                </CardLabel>
                <div className="text-display font-semibold">{k.value}</div>
                <div className="flex items-center gap-2 text-sm">
                  <span className={cn("font-semibold", k.positive ? "text-pos" : "text-neg")}>{k.delta}</span>
                  <span className="text-ink-400">{k.note}</span>
                </div>
                <svg viewBox="0 0 200 36" preserveAspectRatio="none" className="mt-1 h-9 w-full">
                  <polyline points={k.spark} fill="none" stroke={k.sparkColor} strokeWidth="2" />
                </svg>
              </CardBody>
            </Card>
          ))}
        </div>

        {/* P&L · กระแสเงินสด · Passive income */}
        <div className="grid gap-4 [grid-template-columns:repeat(auto-fit,minmax(300px,1fr))]">
          <Card>
            <CardBody className="flex flex-col gap-1.5">
              <CardLabel>
                กำไร/ขาดทุนเดือนนี้ <span className="text-ink-400">P&amp;L</span>
              </CardLabel>
              <div className="text-display font-semibold text-pos">฿ +412,300</div>
              <CardLabel>รายได้ ฿ 1.42M · ค่าใช้จ่าย ฿ 1.01M</CardLabel>
            </CardBody>
          </Card>
          <Card>
            <CardBody className="flex flex-col gap-1.5">
              <CardLabel>
                กระแสเงินสดสุทธิ <span className="text-ink-400">Net cash flow</span>
              </CardLabel>
              <div className="text-display font-semibold text-neg">฿ −1.25M</div>
              <div className="flex flex-col gap-0.5 text-sm text-ink-600">
                {[
                  ["ดำเนินงาน", "+480K", "text-pos"],
                  ["ลงทุน", "−1.8M", "text-neg"],
                  ["จัดหาเงิน", "+70K", "text-pos"],
                ].map(([label, v, tone]) => (
                  <div key={label} className="flex justify-between gap-3">
                    <span>{label}</span>
                    <span className={cn("font-semibold", tone)}>{v}</span>
                  </div>
                ))}
              </div>
            </CardBody>
          </Card>
          <Card>
            <CardBody className="flex flex-col gap-1.5">
              <CardLabel>
                รายได้ประจำต่อเดือน <span className="text-ink-400">Passive income</span>
              </CardLabel>
              <div className="text-display font-semibold">฿ 486,000</div>
              <CardLabel>48.6% ของเป้า ฿ 1M · คาดการณ์สิ้นปี ฿ 612,000</CardLabel>
              <div className="mt-1 h-2.5 overflow-hidden rounded-pill bg-line">
                <div className="h-full bg-brand-600" style={{ width: "48.6%" }} />
              </div>
              <div className="h-2.5 overflow-hidden rounded-pill bg-brand-50">
                <div
                  className="h-full"
                  style={{ width: "61.2%", background: "repeating-linear-gradient(90deg,#8792A2 0 6px,transparent 6px 12px)" }}
                />
              </div>
            </CardBody>
          </Card>
        </div>

        {/* ค้างรับ / ค้างจ่าย */}
        <div className="grid gap-4 [grid-template-columns:repeat(auto-fit,minmax(320px,1fr))]">
          <Card>
            <CardBody className="flex flex-col gap-2.5">
              <div className="flex items-baseline justify-between gap-3">
                <CardTitle>ค้างรับ</CardTitle>
                <div className="text-h2 font-semibold text-neg">฿ 131,500</div>
              </div>
              <div className="flex h-3.5 overflow-hidden rounded-pill">
                <div style={{ width: "42%", background: "#0E9F6E" }} />
                <div style={{ width: "24%", background: "#F5A524" }} />
                <div style={{ width: "19%", background: "#DF1B41" }} />
                <div style={{ width: "15%", background: "#8a0f28" }} />
              </div>
              <div className="flex flex-wrap justify-between gap-2 text-sm text-ink-600">
                <span>0–30 วัน 55,200</span>
                <span>31–60 31,500</span>
                <span>61–90 25,000</span>
                <span>90+ 19,800</span>
              </div>
            </CardBody>
          </Card>
          <Card>
            <CardBody className="flex flex-col gap-2.5">
              <div className="flex items-baseline justify-between gap-3">
                <CardTitle>ค้างจ่าย</CardTitle>
                <div className="text-h2 font-semibold">฿ 58,200</div>
              </div>
              <div className="flex h-3.5 overflow-hidden rounded-pill">
                <div style={{ width: "61%", background: "#0E9F6E" }} />
                <div style={{ width: "26%", background: "#F5A524" }} />
                <div style={{ width: "13%", background: "#DF1B41" }} />
              </div>
              <div className="flex flex-wrap justify-between gap-2 text-sm text-ink-600">
                <span>0–30 วัน 35,500</span>
                <span>31–60 15,200</span>
                <span>61–90 7,500</span>
              </div>
            </CardBody>
          </Card>
        </div>

        {/* สัดส่วน & สถานะทรัพย์สิน */}
        <div className="grid gap-4 [grid-template-columns:repeat(auto-fit,minmax(320px,1fr))]">
          <Card>
            <CardBody className="flex flex-col gap-3">
              <CardTitle>สัดส่วนทรัพย์สิน</CardTitle>
              <div className="flex flex-wrap items-center gap-[22px]">
                <div
                  className="flex h-[150px] w-[150px] flex-none items-center justify-center rounded-pill"
                  style={{ background: "conic-gradient(#004AAD 0 48%,#0E9F6E 48% 86%,#F5A524 86% 95%,#8792A2 95% 100%)" }}
                >
                  <div className="flex h-24 w-24 flex-col items-center justify-center rounded-pill bg-surface">
                    <div className="text-sm text-ink-400">รวม</div>
                    <div className="text-lg font-semibold">฿ 82.9M</div>
                  </div>
                </div>
                <div className="flex flex-col gap-2 text-base">
                  {[
                    ["Real Estate", "48%", "#004AAD"],
                    ["Finance", "38%", "#0E9F6E"],
                    ["Investment", "9%", "#F5A524"],
                    ["Cash", "5%", "#8792A2"],
                  ].map(([label, pct, color]) => (
                    <div key={label} className="flex items-center gap-2.5">
                      <span className="h-3 w-3 rounded-[3px]" style={{ background: color }} />
                      {label} <span className="ml-auto font-semibold">{pct}</span>
                    </div>
                  ))}
                </div>
              </div>
            </CardBody>
          </Card>
          <Card>
            <CardBody className="flex h-full flex-col gap-3">
              <CardTitle>สถานะทรัพย์สิน</CardTitle>
              <div className="grid grid-cols-3 gap-3">
                {[
                  ["Active", "41", "text-pos"],
                  ["Inactive", "6", "text-ink-400"],
                  ["ไม่มีรายได้", "3", "text-warn"],
                ].map(([label, n, tone]) => (
                  <div key={label} className="rounded border border-line bg-canvas p-3.5">
                    <div className="text-sm text-ink-600">{label}</div>
                    <div className={cn("text-h1 font-semibold", tone)}>{n}</div>
                  </div>
                ))}
              </div>
              <Button asChild variant="quiet" className="mt-auto">
                <Link href="/balance" className="no-underline hover:no-underline">ดูงบดุล &amp; ทรัพย์สิน</Link>
              </Button>
            </CardBody>
          </Card>
        </div>

        {/* ที่ควรทำก่อน + ตารางงาน */}
        <div className="grid items-start gap-4 lg:[grid-template-columns:2fr_1fr]">
          <div className="flex min-w-0 flex-col gap-4">
            <Card>
              <CardBody className="flex min-w-0 flex-col gap-3">
                <div className="flex items-baseline gap-2.5">
                  <CardTitle>ที่ควรทำก่อน</CardTitle>
                  <div className="text-sm text-info">✦ AI แนะนำ</div>
                </div>
                {TODOS.map((t) => (
                  <div key={t.title} className="flex items-start gap-3.5 border-t border-line py-3.5">
                    <span className={cn("inline-flex h-7 flex-none items-center rounded-pill px-2.5 text-sm font-bold", PRIORITY_PILL[t.p])}>{t.p}</span>
                    <div className="min-w-0 flex-1">
                      <div className="text-base font-semibold leading-[26px]">{t.title}</div>
                      <div className="text-sm leading-6 text-info">✦ {t.why}</div>
                    </div>
                    <Button asChild variant="quiet" size="sm" className="flex-none">
                      <Link href={t.href} className="no-underline hover:no-underline">ดูรายละเอียด</Link>
                    </Button>
                  </div>
                ))}
              </CardBody>
            </Card>
            <div className="grid gap-4 [grid-template-columns:repeat(auto-fit,minmax(240px,1fr))]">
              {YIELDS.map((y) => (
                <Card key={y.label}>
                  <CardBody>
                    <CardLabel>
                      {y.label} <span className="text-ink-400">{y.en}</span>
                    </CardLabel>
                    <div className="flex items-baseline gap-2.5">
                      <div className="text-display font-semibold" style={{ color: y.color }}>
                        {y.value}
                      </div>
                      <div className="text-sm text-ink-600">{y.target}</div>
                    </div>
                    <div className="mt-2 h-2.5 overflow-hidden rounded-pill bg-line">
                      <div className="h-full" style={{ width: y.bar, background: y.color }} />
                    </div>
                    <div className="mt-1.5 text-sm text-ink-400">{y.note}</div>
                  </CardBody>
                </Card>
              ))}
            </div>
          </div>

          <div className="flex min-w-0 flex-col gap-4">
            <Card>
              <CardBody>
                <CardTitle className="mb-2">ตารางงานทีมสัปดาห์นี้</CardTitle>
                {TEAM_TASKS.map((t) => (
                  <div key={t.what} className="flex gap-3 border-t border-line py-2.5 text-sm leading-6">
                    <div className="w-24 flex-none text-ink-600">{t.when}</div>
                    <div className="min-w-0 flex-1">
                      <div className="text-base font-semibold">{t.what}</div>
                      <div className="text-ink-400">{t.who}</div>
                    </div>
                  </div>
                ))}
              </CardBody>
            </Card>
            <Card>
              <CardBody>
                <CardTitle className="mb-2">สัญญาใกล้หมด 90 วัน</CardTitle>
                {EXPIRING_CONTRACTS.map((c) => (
                  <div key={c.name} className="flex items-center gap-3 border-t border-line py-2.5 text-sm">
                    <div className="min-w-0 flex-1">
                      <div className="text-base font-semibold">{c.name}</div>
                      <div className="text-ink-400">
                        หมด {c.date} · {c.kind}
                      </div>
                    </div>
                    <Pill
                      className={cn(
                        "flex-none border-transparent",
                        c.tone === "neg" ? "bg-neg-bg text-neg-fg" : c.tone === "warn" ? "bg-warn-bg text-warn-fg" : "bg-canvas text-ink-600"
                      )}
                    >
                      {c.left}
                    </Pill>
                  </div>
                ))}
              </CardBody>
            </Card>
          </div>
        </div>
      </div>
    </PageShell>
  );
}
