"use client";

import * as React from "react";
import Image from "next/image";
import Link from "next/link";
import { ASSETS, monthlyFor, monthlyOf, FREQUENCY_LABEL, type AssetRef } from "@/lib/mock/assets";
import { entityById } from "@/lib/mock/entities";
import { money, signedMoney } from "@/lib/format";
import { TableShell, Table, Th, Td } from "@/components/ui/table";
import { Pill } from "@/components/ui/pill";
import { Button } from "@/components/ui/button";
import { Dialog, SheetContent, DialogHeader, DialogFooter, DialogPrimitive } from "@/components/ui/dialog";
import { useApp } from "@/lib/store";
import { cn } from "@/lib/utils";

type Filter = "all" | "active" | "inactive";
type Layout = "table" | "cards" | "rows";

const LAYOUTS: { key: Layout; label: string; note: string }[] = [
  { key: "table", label: "แบบ A · ตาราง", note: "แน่น อ่านเร็ว เทียบตัวเลขข้ามทรัพย์ง่าย" },
  { key: "cards", label: "แบบ B · การ์ด", note: "รูปใหญ่ จำทรัพย์จากภาพได้ทันที" },
  { key: "rows", label: "แบบ C · รายการ", note: "แถวโปร่ง ตัวเลขใหญ่ อ่านสบายตาที่สุด" },
];

/**
 * หน้าบริหารสินทรัพย์ — ทะเบียนทรัพย์ สถานะ และรายการประจำ
 *
 * **ตัวเลขทุกตัวเป็นต่อเดือน** (ลูกพี่สั่ง 06/10) · ค่าส่วนกลางรายปีกับค่าล้างแอร์ราย 3 เดือน
 * ถูกเฉลี่ยลงมาเป็นรายเดือนด้วย ไม่ใช่นับเฉพาะรายการรายเดือน ไม่งั้นเดือนที่ไม่มีบิลก้อนใหญ่
 * จะดูกำไรดีเกินจริง
 *
 * หน้านี้คือต้นทางของ Auto-Key (D-067): ทรัพย์ที่ active และมีรายการประจำ
 * จะถูกสร้าง draft ล่วงหน้าไปรออนุมัติเป็นชุด
 */
export function AssetManager() {
  const [filter, setFilter] = React.useState<Filter>("all");
  const [layout, setLayout] = React.useState<Layout>("table");
  const [openId, setOpenId] = React.useState<string | null>(null);

  const rows = ASSETS.filter((a) => filter === "all" || a.status === filter);
  const activeCount = ASSETS.filter((a) => a.status === "active").length;
  const sum = ASSETS.reduce(
    (t, a) => {
      const m = monthlyFor(a);
      return { income: t.income + m.income, expense: t.expense + m.expense };
    },
    { income: 0, expense: 0 }
  );

  return (
    <div className="flex flex-col gap-4 pb-24">
      <div className="flex flex-wrap items-center gap-x-8 gap-y-3 rounded-card border border-line bg-surface p-[16px_20px] shadow-card">
        <Figure label="ทรัพย์ที่สร้างรายได้" value={`${activeCount} / ${ASSETS.length}`} />
        <Figure label="รายได้ต่อเดือน" value={money(sum.income)} tone="pos" />
        <Figure label="ค่าใช้จ่ายต่อเดือน" value={money(sum.expense)} tone="neg" />
        <Figure label="สุทธิต่อเดือน" value={signedMoney(sum.income - sum.expense)} tone="pos" strong />
      </div>

      <div className="flex flex-wrap items-center gap-2.5">
        {(["all", "active", "inactive"] as Filter[]).map((f) => (
          <Button key={f} size="sm" variant={filter === f ? "primary" : "secondary"} onClick={() => setFilter(f)}>
            {f === "all" ? `ทั้งหมด (${ASSETS.length})` : f === "active" ? `ใช้งานอยู่ (${activeCount})` : `หยุดไว้ (${ASSETS.length - activeCount})`}
          </Button>
        ))}
      </div>

      {/* สลับแบบเพื่อให้ลูกพี่เลือก — ของจริงจะเหลือแบบเดียว */}
      <div className="flex flex-col gap-2 rounded-card border border-dashed border-brand-100 bg-brand-50 p-[14px_18px]">
        <div className="text-base font-semibold">เลือกแบบที่ชอบ แล้วบอกผม — ของจริงจะเหลือแบบเดียว</div>
        <div className="flex flex-wrap gap-2.5">
          {LAYOUTS.map((l) => (
            <Button key={l.key} size="sm" variant={layout === l.key ? "primary" : "secondary"} onClick={() => setLayout(l.key)}>
              {l.label}
            </Button>
          ))}
        </div>
        <div className="text-sm text-ink-600">{LAYOUTS.find((l) => l.key === layout)?.note}</div>
      </div>

      {layout === "table" ? <TableLayout rows={rows} onOpen={setOpenId} /> : null}
      {layout === "cards" ? <CardLayout rows={rows} onOpen={setOpenId} /> : null}
      {layout === "rows" ? <RowLayout rows={rows} onOpen={setOpenId} /> : null}

      <AssetSheet asset={ASSETS.find((a) => a.id === openId) ?? null} onClose={() => setOpenId(null)} />
    </div>
  );
}

/* ---------- ชิ้นส่วนที่ใช้ร่วมกันทั้งสามแบบ ---------- */

function Figure({ label, value, tone, strong }: { label: string; value: string; tone?: "pos" | "neg"; strong?: boolean }) {
  return (
    <div>
      <div className="text-sm text-ink-400">{label}</div>
      <div className={cn("tabular-nums font-semibold", strong ? "text-h1" : "text-h2", tone === "pos" && "text-pos", tone === "neg" && "text-neg")}>
        {value}
      </div>
    </div>
  );
}

function Photo({ asset, size }: { asset: AssetRef; size: number }) {
  return (
    <Image
      src={asset.photo ?? "/asset-photos/rent1.svg"}
      alt=""
      width={size}
      height={size}
      className={cn("flex-none rounded-card object-cover", asset.status !== "active" && "opacity-55 grayscale")}
      style={{ width: size, height: size }}
    />
  );
}

function StatusChip({ asset }: { asset: AssetRef }) {
  const stopped = asset.status !== "active";
  return (
    <Pill className={cn("whitespace-nowrap", stopped ? "border-line bg-canvas text-ink-600" : "border-pos bg-pos-bg text-pos-fg")}>
      {stopped ? "หยุดไว้" : "ใช้งานอยู่"}
    </Pill>
  );
}

function Owner({ ownerId }: { ownerId: string }) {
  const o = entityById(ownerId);
  return (
    <span className="inline-flex items-center gap-1.5 whitespace-nowrap">
      <span className="h-2.5 w-2.5 flex-none rounded-pill" style={{ background: o.color }} />
      {o.name}
    </span>
  );
}

/** ยอดสุทธิต่อเดือน — "—" เมื่อทรัพย์หยุดไว้ เพื่อไม่ให้อ่านเป็นศูนย์บาทจริง */
function Net({ asset, className }: { asset: AssetRef; className?: string }) {
  const m = monthlyFor(asset);
  if (asset.status !== "active") return <span className={cn("text-ink-400", className)}>—</span>;
  return <span className={cn("tabular-nums font-semibold", m.net < 0 ? "text-neg" : "text-pos", className)}>{signedMoney(m.net)}</span>;
}

/* ---------- แบบ A · ตาราง ---------- */

function TableLayout({ rows, onOpen }: { rows: AssetRef[]; onOpen: (id: string) => void }) {
  return (
    <TableShell>
      <Table minWidth={980}>
        <thead>
          <tr>
            <Th className="min-w-[280px]">ทรัพย์</Th>
            <Th>ถือในชื่อ</Th>
            <Th>สถานะ</Th>
            <Th align="right">รายได้/เดือน</Th>
            <Th align="right">ค่าใช้จ่าย/เดือน</Th>
            <Th align="right">สุทธิ/เดือน</Th>
          </tr>
        </thead>
        <tbody>
          {rows.map((a) => {
            const m = monthlyFor(a);
            return (
              <tr key={a.id} className="bg-surface">
                <Td className="p-0">
                  <button
                    type="button"
                    className="flex min-h-control w-full items-center gap-3 p-[10px_16px] text-left hover:bg-brand-50"
                    onClick={() => onOpen(a.id)}
                  >
                    <Photo asset={a} size={40} />
                    <span className="min-w-0">
                      <span className="block whitespace-nowrap font-semibold">{a.name}</span>
                      <span className="block text-sm text-ink-400">{a.category}</span>
                    </span>
                  </button>
                </Td>
                <Td><Owner ownerId={a.ownerId} /></Td>
                <Td className="whitespace-nowrap"><StatusChip asset={a} /></Td>
                <Td align="right" className="whitespace-nowrap tabular-nums text-pos">{a.status === "active" && m.income ? money(m.income) : "—"}</Td>
                <Td align="right" className="whitespace-nowrap tabular-nums text-neg">{a.status === "active" && m.expense ? money(m.expense) : "—"}</Td>
                <Td align="right" className="whitespace-nowrap"><Net asset={a} /></Td>
              </tr>
            );
          })}
        </tbody>
      </Table>
    </TableShell>
  );
}

/* ---------- แบบ B · การ์ด ---------- */

function CardLayout({ rows, onOpen }: { rows: AssetRef[]; onOpen: (id: string) => void }) {
  return (
    <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
      {rows.map((a) => {
        const m = monthlyFor(a);
        return (
          <button
            key={a.id}
            type="button"
            onClick={() => onOpen(a.id)}
            className="flex flex-col overflow-hidden rounded-card border border-line bg-surface text-left shadow-card hover:border-brand-100"
          >
            <Image
              src={a.photo ?? "/asset-photos/rent1.svg"}
              alt=""
              width={480}
              height={200}
              className={cn("h-[140px] w-full object-cover", a.status !== "active" && "opacity-55 grayscale")}
            />
            <div className="flex flex-1 flex-col gap-2.5 p-[16px_18px]">
              <div className="flex items-start gap-2">
                <div className="mr-auto min-w-0">
                  <div className="font-semibold">{a.name}</div>
                  <div className="text-sm text-ink-400">{a.category}</div>
                </div>
                <StatusChip asset={a} />
              </div>
              <Owner ownerId={a.ownerId} />
              <div className="mt-auto flex items-end justify-between border-t border-line pt-2.5">
                <div className="text-sm text-ink-400">
                  <div>รับ {a.status === "active" && m.income ? money(m.income) : "—"}</div>
                  <div>จ่าย {a.status === "active" && m.expense ? money(m.expense) : "—"}</div>
                </div>
                <div className="text-right">
                  <div className="text-sm text-ink-400">สุทธิ/เดือน</div>
                  <Net asset={a} className="text-h2" />
                </div>
              </div>
            </div>
          </button>
        );
      })}
    </div>
  );
}

/* ---------- แบบ C · รายการ ---------- */

function RowLayout({ rows, onOpen }: { rows: AssetRef[]; onOpen: (id: string) => void }) {
  const m0 = monthlyFor;
  return (
    <div className="overflow-hidden rounded-card border border-line bg-surface shadow-card">
      {rows.map((a, i) => {
        const m = m0(a);
        return (
          <button
            key={a.id}
            type="button"
            onClick={() => onOpen(a.id)}
            className={cn(
              "flex w-full flex-wrap items-center gap-4 p-[16px_20px] text-left hover:bg-brand-50",
              i > 0 && "border-t border-line"
            )}
          >
            <Photo asset={a} size={56} />
            <div className="min-w-0 flex-1">
              <div className="flex flex-wrap items-center gap-2">
                <span className="text-h2 font-semibold">{a.name}</span>
                <StatusChip asset={a} />
              </div>
              <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-base text-ink-600">
                <span>{a.category}</span>
                <span className="text-ink-400">·</span>
                <Owner ownerId={a.ownerId} />
              </div>
              {a.statusNote ? <div className="text-sm text-ink-400">{a.statusNote}</div> : null}
            </div>
            <div className="ml-auto text-right">
              <Net asset={a} className="text-h1" />
              <div className="text-sm text-ink-400">
                สุทธิ/เดือน
                {a.status === "active" ? ` · รับ ${money(m.income)} · จ่าย ${money(m.expense)}` : ""}
              </div>
            </div>
          </button>
        );
      })}
    </div>
  );
}

/* ---------- แผงขวา ---------- */

function AssetSheet({ asset, onClose }: { asset: AssetRef | null; onClose: () => void }) {
  const showToast = useApp((s) => s.showToast);
  if (!asset) return null;

  const m = monthlyFor(asset);
  const stopped = asset.status !== "active";

  return (
    <Dialog open onOpenChange={(o) => (o ? null : onClose())}>
      <SheetContent aria-describedby={undefined}>
        <DialogPrimitive.Title className="sr-only">รายละเอียดทรัพย์</DialogPrimitive.Title>
        <DialogHeader title={asset.name} onClose={onClose} />

        <div className="flex flex-1 flex-col gap-5 overflow-auto p-[20px_24px]">
          <div className="flex gap-4">
            <Photo asset={asset} size={96} />
            <div className="flex flex-col gap-2">
              <StatusChip asset={asset} />
              <div className="text-base text-ink-600">{asset.category}</div>
              <Owner ownerId={asset.ownerId} />
              <Button variant="secondary" size="sm" onClick={() => showToast("ตัวอย่างหน้าจอ — ต่อ Supabase Storage แล้วจะอัพรูปได้จริง")}>
                เปลี่ยนรูป
              </Button>
            </div>
          </div>
          {asset.statusNote ? <div className="text-base text-ink-600">{asset.statusNote}</div> : null}

          <div className="grid grid-cols-3 gap-3">
            <Mini label="รับ/เดือน" value={stopped ? "—" : money(m.income)} />
            <Mini label="จ่าย/เดือน" value={stopped ? "—" : money(m.expense)} />
            <Mini label="สุทธิ/เดือน" value={stopped ? "—" : signedMoney(m.net)} />
          </div>

          <div className="flex flex-col gap-2">
            <div className="text-base font-semibold">รายการประจำ</div>
            {asset.recurring.length === 0 ? (
              <div className="text-base text-ink-600">ยังไม่มีรายการประจำ</div>
            ) : (
              <ul className="m-0 flex list-none flex-col gap-2 p-0">
                {asset.recurring.map((r) => (
                  <li key={r.id} className="flex flex-wrap items-center gap-2 rounded-card border border-line bg-canvas p-[12px_14px]">
                    <div className="mr-auto">
                      <div className="text-base font-semibold">{r.label}</div>
                      <div className="text-sm text-ink-400">
                        {FREQUENCY_LABEL[r.frequency]} · {money(r.amount)} ต่องวด · เฉลี่ย {money(monthlyOf(r))} ต่อเดือน
                      </div>
                    </div>
                    <Pill className={r.direction === "income" ? "border-pos bg-pos-bg text-pos-fg" : "border-neg bg-neg-bg text-neg-fg"}>
                      {r.direction === "income" ? "รายได้" : "ค่าใช้จ่าย"}
                    </Pill>
                  </li>
                ))}
              </ul>
            )}
            {stopped && asset.recurring.length ? (
              <div className="rounded border border-warn bg-warn-bg p-[10px_12px] text-sm leading-6 text-warn-fg">
                ⚠ ทรัพย์หยุดไว้ — รายการประจำข้างบนจะ<b>ไม่ถูกสร้างอัตโนมัติ</b>จนกว่าจะกลับมาใช้งาน
              </div>
            ) : null}
          </div>
        </div>

        <DialogFooter className="justify-between">
          <Button variant="secondary" size="sm" asChild>
            <Link href={`/assets/${asset.id}`} className="no-underline hover:no-underline">
              ดูทะเบียนเต็ม
            </Link>
          </Button>
          <Button size="sm" onClick={() => showToast("ตัวอย่างหน้าจอ ยังไม่เขียนลงฐานข้อมูล")}>
            + เพิ่มรายการประจำ
          </Button>
        </DialogFooter>
      </SheetContent>
    </Dialog>
  );
}

function Mini({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-card border border-line bg-canvas p-[12px_14px]">
      <div className="text-sm text-ink-400">{label}</div>
      <div className="text-base font-semibold tabular-nums">{value}</div>
    </div>
  );
}
