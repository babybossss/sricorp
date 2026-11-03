import Link from "next/link";
import { Card, CardBody, CardLabel, CardTitle } from "@/components/ui/card";
import { Pill } from "@/components/ui/pill";
import { Select } from "@/components/ui/select";
import { Field } from "@/components/ui/field";
import { PRIORITY_PILL } from "@/lib/tone";
import { money } from "@/lib/format";
import { cn } from "@/lib/utils";
import { Notice } from "@/components/assets/asset-parts";
import type { AccrualSide } from "./dashboard-model";
import type { DashboardData } from "./dashboard-data";

type Ok = Extract<DashboardData, { ok: true }>;

const m = (n: number) => money(n, { dash: false });
const GRID = "[grid-template-columns:repeat(auto-fit,minmax(min(100%,260px),1fr))]";
const BUCKET_TONE = { d30: "bg-pos", d60: "bg-warn", over: "bg-neg" } as const;

/**
 * หน้าแรก — ข้อมูลจริงจากสมุดบัญชีที่ผู้ใช้อ่านได้ (RLS) · คำนวณใหม่ทุกครั้ง ไม่มีตัวเลขที่เก็บไว้
 * ตัวเลขเงินทุกช่องตัวเดียวกับหน้างบการเงิน · เรียงเป็นคอลัมน์เดียวบนจอแคบ · ติดลบใช้วงเล็บ
 */
export function DashboardView({ data }: { data: Ok }) {
  const f = data.figures;
  const visible = data.owners.filter((o) => o.status === "active");
  const label = data.view === "family" ? "SRI Family (รวมทุกชื่อ)" : (data.owners.find((o) => o.id === data.view)?.name ?? data.view);

  return (
    <div className="flex flex-col gap-4">
      {/* ตัวกรองผู้ถือ/ปี — ฟอร์ม GET ล้วน ไม่ต้องพึ่ง JavaScript */}
      <form method="get" className="flex flex-wrap items-end gap-3 rounded-card border border-line bg-surface p-[14px_18px] shadow-card">
        <Field label="ผู้ถือ" className="min-w-[220px] flex-1">
          <Select name="owner" defaultValue={data.view}>
            <option value="family">SRI Family (รวมทุกชื่อ)</option>
            {visible.map((o) => (
              <option key={o.id} value={o.id}>{o.name}</option>
            ))}
          </Select>
        </Field>
        <Field label="ปีบัญชี (ม.ค.–ธ.ค.)" className="min-w-[160px]">
          <Select name="year" defaultValue={String(data.year)}>
            {data.years.map((y) => (
              <option key={y} value={y}>{y}</option>
            ))}
          </Select>
        </Field>
        <button type="submit" className="inline-flex min-h-control max-md:min-h-control-mobile items-center justify-center rounded border border-brand-600 bg-brand-600 px-[22px] text-base font-semibold text-white hover:bg-brand-700 focus-visible:outline-none focus-visible:ring-[3px] focus-visible:ring-brand-600 focus-visible:ring-offset-2">
          ดูมุมมองนี้
        </button>
      </form>

      {!data.ledgerAccess || !f ? (
        <Notice tone="info">ตำแหน่งของคุณไม่มีสิทธิ์อ่านสมุดบัญชี จึงไม่แสดงตัวเลขการเงิน (ไม่ใช่ว่าเป็นศูนย์) — ส่วนงานที่ต้องทำด้านล่างแสดงเท่าที่คุณมีสิทธิ์เห็น</Notice>
      ) : (
        <>
          <div className="text-base text-ink-600">
            {label} · ปีบัญชี {data.year} · ณ {data.today.slice(8)}/{data.today.slice(5, 7)}/{data.today.slice(0, 4)}
          </div>

          {!f.bs.balanced ? (
            <Notice tone="neg">
              <b>งบแสดงฐานะการเงินไม่ดุล</b> ต่างกัน {m(f.bs.difference)} บาท — ห้ามใช้ตัวเลขด้านล่างก่อนหาสาเหตุ (ดูหน้างบการเงิน)
            </Notice>
          ) : null}
          {f.bs.unmapped > 0 ? <Notice tone="warn">มีบัญชี {f.bs.unmapped} รหัสที่งบไม่มีบรรทัดรองรับ ยอดอาจไม่ครบ — แจ้งผู้ดูแลระบบ</Notice> : null}

          <div className={cn("grid gap-4", GRID)}>
            <Kpi label="สินทรัพย์รวม" en="Total assets" value={f.bs.totalAssets} note="ตามต้นทุนในสมุด ณ สิ้นปีบัญชี" />
            <Kpi label="หนี้สิน" en="Liabilities" value={f.bs.totalLiabilities} note="เงินกู้ เจ้าหนี้ เงินมัดจำรับ" />
            <Kpi label="ส่วนของเจ้าของ" en="Equity" value={f.bs.totalEquity} note="สินทรัพย์ − หนี้สิน" />
          </div>

          <div className={cn("grid gap-4", GRID)}>
            <Card>
              <CardBody className="flex flex-col gap-1.5">
                <CardLabel>กำไร/ขาดทุนปี {data.year} <span className="text-ink-600">P&amp;L</span></CardLabel>
                <div className={cn("text-display font-semibold tabular-nums", f.pl.net < 0 ? "text-neg" : "text-pos")}>{m(f.pl.net)}</div>
                <CardLabel>รายได้ {m(f.pl.revenue)} · ค่าใช้จ่าย {m(f.pl.expense)}</CardLabel>
                <div className="text-sm text-ink-600">ไม่รวมกำไร/ขาดทุนที่ยังไม่เกิดขึ้นจริง</div>
              </CardBody>
            </Card>
            <Card>
              <CardBody className="flex flex-col gap-1.5">
                <CardLabel>กระแสเงินสดสุทธิปี {data.year} <span className="text-ink-600">Net cash flow</span></CardLabel>
                {f.cf ? (
                  <>
                    <div className={cn("text-display font-semibold tabular-nums", f.cf.net < 0 ? "text-neg" : "text-pos")}>{m(f.cf.net)}</div>
                    <div className="flex flex-col gap-0.5 text-base text-ink-600">
                      {[
                        ["ดำเนินงาน", f.cf.operating],
                        ["ลงทุน", f.cf.investing],
                        ["จัดหาเงิน", f.cf.financing],
                      ].map(([name, v]) => (
                        <div key={name as string} className="flex justify-between gap-3">
                          <span>{name}</span>
                          <span className={cn("font-semibold tabular-nums", (v as number) < 0 ? "text-neg" : "text-pos")}>{m(v as number)}</span>
                        </div>
                      ))}
                    </div>
                    {!f.cf.reconciled ? <Notice tone="neg">งบกระแสเงินสดไม่กระทบยอด — ดูหน้างบการเงินก่อนใช้ตัวเลขนี้</Notice> : null}
                  </>
                ) : (
                  <Notice tone="neg">ประกอบงบกระแสเงินสดไม่ได้: {f.cfError}</Notice>
                )}
              </CardBody>
            </Card>
          </div>

          <div className={cn("grid gap-4", GRID)}>
            <Aging title="ค้างรับ" side={f.receivable} tone="rec" />
            <Aging title="ค้างจ่าย" side={f.payable} tone="pay" />
          </div>
        </>
      )}

      <Card>
        <CardBody>
          <CardTitle className="mb-1">งานที่ต้องทำ</CardTitle>
          {data.todos.length === 0 ? (
            <div className="py-3 text-base text-ink-600" data-testid="no-todos">ไม่มีงานค้างจากข้อมูลในระบบตอนนี้</div>
          ) : (
            data.todos.map((t) => (
              <Link key={t.title} href={t.href} className="flex min-h-control items-start gap-3 border-t border-line py-3 no-underline first:border-t-0">
                <Pill className={cn("flex-none", PRIORITY_PILL[t.priority])}>{t.priority}</Pill>
                <div className="min-w-0 flex-1">
                  <div className="text-base font-semibold text-ink-900">{t.title}</div>
                  <div className="text-sm text-ink-600">{t.why}</div>
                </div>
              </Link>
            ))
          )}
        </CardBody>
      </Card>
    </div>
  );
}

function Kpi({ label, en, value, note }: { label: string; en: string; value: number; note: string }) {
  return (
    <Card>
      <CardBody className="flex flex-col gap-1">
        <CardLabel>{label} <span className="text-ink-600">{en}</span></CardLabel>
        <div className={cn("text-display font-semibold tabular-nums", value < 0 && "text-neg")}>{m(value)}</div>
        <div className="text-sm text-ink-600">{note}</div>
      </CardBody>
    </Card>
  );
}

function Aging({ title, side, tone }: { title: string; side: AccrualSide; tone: "rec" | "pay" }) {
  return (
    <Card>
      <CardBody className="flex flex-col gap-2.5">
        <div className="flex items-baseline justify-between gap-3">
          <CardTitle>{title}</CardTitle>
          <div className="text-h2 font-semibold tabular-nums" data-testid={`aging-${tone}`}>{m(side.total)}</div>
        </div>
        <div className="text-sm text-ink-600">{side.count} รายการที่ยังไม่ยืนยันว่าเงินเข้า/ออกจริง</div>
        {side.total > 0 ? (
          <div className="flex h-3.5 overflow-hidden rounded-pill" role="img" aria-label={`สัดส่วนอายุของยอด${title}`}>
            {side.buckets.map((b) => (
              <div key={b.key} className={BUCKET_TONE[b.key]} style={{ width: `${(b.amount / side.total) * 100}%` }} />
            ))}
          </div>
        ) : null}
        {side.buckets.map((b) => (
          <div key={b.key} className="flex items-center justify-between gap-3 text-base">
            <span className="inline-flex items-center gap-2">
              <span className={cn("h-2.5 w-2.5 rounded-pill", BUCKET_TONE[b.key])} />
              {b.label} <span className="text-sm text-ink-600">({b.count})</span>
            </span>
            <span className="font-semibold tabular-nums">{m(b.amount)}</span>
          </div>
        ))}
      </CardBody>
    </Card>
  );
}
