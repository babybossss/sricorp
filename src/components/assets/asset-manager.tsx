"use client";

import * as React from "react";
import Link from "next/link";
import { ASSETS, yearlyFor, FREQUENCY_LABEL, PER_YEAR, type AssetRef } from "@/lib/mock/assets";
import { entityById } from "@/lib/mock/entities";
import { money, signedMoney } from "@/lib/format";
import { TableShell, Table, Th, Td } from "@/components/ui/table";
import { Pill } from "@/components/ui/pill";
import { Button } from "@/components/ui/button";
import { Dialog, SheetContent, DialogHeader, DialogFooter, DialogPrimitive } from "@/components/ui/dialog";
import { useApp } from "@/lib/store";
import { cn } from "@/lib/utils";

type Filter = "all" | "active" | "inactive";

/**
 * หน้าบริหารสินทรัพย์ — ทะเบียนทรัพย์พร้อมสถานะและรายการประจำ
 *
 * หน้านี้คือต้นทางของ Auto-Key (D-067): ทรัพย์ที่ `active` และมีรายการประจำ
 * จะถูก cron สร้าง draft ให้ล่วงหน้า แล้วไปรออนุมัติเป็นชุด
 *
 * **ทรัพย์ที่ไม่ active ไม่นับในยอดคาดการณ์และไม่ออกรายการประจำ** — ห้องที่ไม่มี
 * คนเช่าแต่ยังออกใบค่าเช่าทุกเดือน คือรายได้ปลอมที่ค้างเป็นลูกหนี้ไปตลอด
 */
export function AssetManager() {
  const showToast = useApp((s) => s.showToast);
  const [filter, setFilter] = React.useState<Filter>("all");
  const [openId, setOpenId] = React.useState<string | null>(null);

  const rows = ASSETS.filter((a) => filter === "all" || a.status === filter);
  const active = ASSETS.filter((a) => a.status === "active");
  const total = ASSETS.reduce(
    (t, a) => {
      const y = yearlyFor(a);
      return { cost: t.cost + a.cost, income: t.income + y.income, expense: t.expense + y.expense };
    },
    { cost: 0, income: 0, expense: 0 }
  );
  const open = ASSETS.find((a) => a.id === openId) ?? null;

  return (
    <div className="flex flex-col gap-4 pb-24">
      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <Stat label="ทรัพย์ทั้งหมด" value={`${ASSETS.length} ชิ้น`} sub={`ปล่อยเช่า/สร้างรายได้อยู่ ${active.length} ชิ้น`} />
        <Stat label="ต้นทุนรวม" value={money(total.cost)} sub="ราคาที่ได้มา ยังไม่รวมราคาประเมิน" />
        <Stat label="รายได้คาดต่อปี" value={money(total.income)} tone="pos" sub="นับเฉพาะทรัพย์ที่ยัง active" />
        <Stat
          label="สุทธิคาดต่อปี"
          value={signedMoney(total.income - total.expense)}
          tone={total.income - total.expense < 0 ? "neg" : "pos"}
          sub={`หักค่าใช้จ่ายประจำ ${money(total.expense)}`}
        />
      </div>

      <div className="flex flex-wrap items-center gap-2.5 rounded-card border border-line bg-surface p-[14px_18px] shadow-card">
        <span className="text-base text-ink-600">แสดง</span>
        {(["all", "active", "inactive"] as Filter[]).map((f) => (
          <Button key={f} size="sm" variant={filter === f ? "primary" : "secondary"} onClick={() => setFilter(f)}>
            {f === "all" ? `ทั้งหมด (${ASSETS.length})` : f === "active" ? `ใช้งานอยู่ (${active.length})` : `หยุดไว้ (${ASSETS.length - active.length})`}
          </Button>
        ))}
        <Button className="ml-auto" size="sm" onClick={() => showToast("ยังเป็นตัวอย่างหน้าจอ ยังไม่เขียนลงฐานข้อมูล")}>
          + เพิ่มทรัพย์
        </Button>
      </div>

      <TableShell>
        <Table minWidth={1340}>
          <thead>
            <tr>
              <Th className="min-w-[230px]">ทรัพย์</Th>
              <Th>หมวด</Th>
              <Th>ถือในชื่อ</Th>
              <Th>สถานะ</Th>
              <Th align="right">ต้นทุน</Th>
              <Th align="right">รายได้/ปี</Th>
              <Th align="right">ค่าใช้จ่าย/ปี</Th>
              <Th align="right">สุทธิ/ปี</Th>
              <Th>รายการประจำ</Th>
            </tr>
          </thead>
          <tbody>
            {rows.map((a) => {
              const y = yearlyFor(a);
              const holder = entityById(a.ownerId);
              const stopped = a.status !== "active";
              return (
                <tr key={a.id} className={cn("bg-surface", stopped && "bg-canvas")}>
                  <Td className="p-0">
                    <button
                      type="button"
                      className="flex min-h-control w-full flex-col items-start gap-0.5 p-[14px_16px] text-left hover:bg-brand-50"
                      onClick={() => setOpenId(a.id)}
                    >
                      <span className="whitespace-nowrap font-semibold underline decoration-line underline-offset-4">{a.name}</span>
                      {a.statusNote ? <span className="text-sm text-ink-400">{a.statusNote}</span> : null}
                    </button>
                  </Td>
                  <Td className="whitespace-nowrap text-ink-600">{a.category}</Td>
                  <Td className="whitespace-nowrap">
                    <span className="inline-flex items-center gap-1.5">
                      <span className="h-2.5 w-2.5 rounded-pill" style={{ background: holder.color }} />
                      {holder.name}
                    </span>
                  </Td>
                  <Td className="whitespace-nowrap">
                    <Pill className={cn("whitespace-nowrap", stopped ? "border-line bg-canvas text-ink-600" : "border-pos bg-pos-bg text-pos-fg")}>
                      {stopped ? "หยุดไว้" : "ใช้งานอยู่"}
                    </Pill>
                  </Td>
                  <Td align="right" className="whitespace-nowrap tabular-nums">{money(a.cost)}</Td>
                  <Td align="right" className="whitespace-nowrap tabular-nums text-pos">{y.income ? money(y.income) : "—"}</Td>
                  <Td align="right" className="whitespace-nowrap tabular-nums text-neg">{y.expense ? money(y.expense) : "—"}</Td>
                  <Td align="right" className="whitespace-nowrap tabular-nums">
                    <b className={y.net < 0 ? "text-neg" : "text-pos"}>{y.net ? signedMoney(y.net) : "—"}</b>
                  </Td>
                  <Td className="whitespace-nowrap text-ink-600">
                    {a.recurring.length} รายการ
                    {stopped && a.recurring.length ? <span className="block text-sm text-ink-400">หยุดออกอัตโนมัติ</span> : null}
                  </Td>
                </tr>
              );
            })}
          </tbody>
        </Table>
      </TableShell>

      <div className="rounded-card border border-brand-100 bg-brand-50 p-[14px_18px] text-base leading-7">
        ทรัพย์ที่ <b>ใช้งานอยู่</b> และมีรายการประจำ ระบบจะสร้างรายการล่วงหน้าให้เป็นชุด
        แล้วส่งเข้าคิวอนุมัติ — <b>สร้างได้แค่ร่าง ไม่ลงบัญชีเอง</b> ·
        ทรัพย์ที่หยุดไว้จะไม่ออกรายการใดเลย
      </div>

      <AssetSheet asset={open} onClose={() => setOpenId(null)} />
    </div>
  );
}

function Stat({ label, value, sub, tone }: { label: string; value: string; sub?: string; tone?: "pos" | "neg" }) {
  return (
    <div className="flex flex-col gap-1 rounded-card border border-line bg-surface p-[16px_18px] shadow-card">
      <div className="text-base text-ink-600">{label}</div>
      <div className={cn("text-h1 font-semibold tabular-nums", tone === "pos" && "text-pos", tone === "neg" && "text-neg")}>{value}</div>
      {sub ? <div className="text-sm text-ink-400">{sub}</div> : null}
    </div>
  );
}

/** แผงขวา — รายการประจำของทรัพย์ชิ้นเดียว */
function AssetSheet({ asset, onClose }: { asset: AssetRef | null; onClose: () => void }) {
  const showToast = useApp((s) => s.showToast);
  if (!asset) return null;

  const y = yearlyFor(asset);
  const stopped = asset.status !== "active";

  return (
    <Dialog open onOpenChange={(o) => (o ? null : onClose())}>
      <SheetContent aria-describedby={undefined}>
        <DialogPrimitive.Title className="sr-only">รายละเอียดทรัพย์</DialogPrimitive.Title>
        <DialogHeader title={asset.name} onClose={onClose} />

        <div className="flex flex-1 flex-col gap-5 overflow-auto p-[20px_24px]">
          <div className="flex flex-wrap items-center gap-2">
            <Pill className={stopped ? "border-line bg-canvas text-ink-600" : "border-pos bg-pos-bg text-pos-fg"}>
              {stopped ? "หยุดไว้" : "ใช้งานอยู่"}
            </Pill>
            <span className="text-base text-ink-600">{asset.category}</span>
          </div>
          {asset.statusNote ? <div className="text-base text-ink-600">{asset.statusNote}</div> : null}

          <div className="grid grid-cols-3 gap-3">
            <Mini label="ต้นทุน" value={money(asset.cost)} />
            <Mini label="รายได้/ปี" value={y.income ? money(y.income) : "—"} />
            <Mini label="สุทธิ/ปี" value={y.net ? signedMoney(y.net) : "—"} />
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
                        {FREQUENCY_LABEL[r.frequency]} · {money(r.amount)} ต่องวด · {money(r.amount * PER_YEAR[r.frequency])} ต่อปี
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
          <Button size="sm" onClick={() => showToast("ยังเป็นตัวอย่างหน้าจอ ยังไม่เขียนลงฐานข้อมูล")}>
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
