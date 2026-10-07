"use client";

import * as React from "react";
import Image from "next/image";
import Link from "next/link";
import {
  monthlyFor, monthlyOf, currentValue, yieldPct, portfolioTotals, holdingMix,
  FREQUENCY_LABEL, HOLDING_LABEL, KIND_LABEL, VALUE_BASIS_LABEL,
  type AssetRef, type AssetDraft, type HoldingType,
} from "@/lib/mock/assets";
import { entityById } from "@/lib/mock/entities";
import { money, signedMoney } from "@/lib/format";
import { TableShell, Table, Th, Td } from "@/components/ui/table";
import { Pill } from "@/components/ui/pill";
import { Button } from "./tall-button";
import { Select } from "./fields";
import { Field } from "@/components/ui/field";
import { Dialog, SheetContent, DialogFooter, DialogPrimitive } from "@/components/ui/dialog";
import { AssetMap } from "./asset-map";
import { MapsLinkField } from "./maps-link-field";
import { AssetKindIcon } from "./asset-kind-icon";
import { useApp } from "@/lib/store";
import { cn } from "@/lib/utils";
import { usePermissions } from "@/components/auth/permissions-provider";
import { useAssetStore } from "./asset-store";
import { canSeeDraftQueue, registerMode, sheetActions, visibleDrafts, type Perms } from "./asset-drafts";
import { LINK_BUTTON_CLASS, SheetHeader } from "./draft-parts";
import { ProposeEditDialog } from "./propose-edit-dialog";

type Layout = "table" | "cards" | "map";
type SortKey = "name" | "value" | "net" | "yield" | "cost";

const SORTS: { key: SortKey; label: string }[] = [
  { key: "net", label: "สุทธิ/เดือน มากไปน้อย" },
  { key: "yield", label: "ผลตอบแทน มากไปน้อย" },
  { key: "value", label: "มูลค่าปัจจุบัน มากไปน้อย" },
  { key: "cost", label: "ต้นทุน มากไปน้อย" },
  { key: "name", label: "ชื่อทรัพย์ ก–ฮ" },
];

/**
 * สีประจำประเภทการถือ — ใช้ทั้งแถบสัดส่วนและจุดในคำอธิบาย ให้ตาจับคู่กันได้
 * เป็นคลาสโทเคนจาก `tailwind.config.ts` (เดิมเป็น hex ตรงๆ ซึ่งผิดกติกา) ·
 * ความหมายอ่านได้จากข้อความ+เปอร์เซ็นต์ข้างจุดเสมอ ไม่พึ่งสีอย่างเดียว
 */
const HOLDING_TONE: Record<HoldingType, string> = {
  rental: "bg-brand-600",
  srr: "bg-info",
  mortgage: "bg-pos",
  loan: "bg-warn",
  for_sale: "bg-ink-600",
  unset: "bg-ink-400",
};

/**
 * หน้าบริหารสินทรัพย์
 *
 * ตัวเลขทุกตัวเป็น**ต่อเดือน** · โครงข้อมูลอ้างอิงไฟล์ ASSET HOLDING ของลูกพี่
 * หน้านี้เป็นต้นทางของ Auto-Key (D-067) และของราคาประเมินที่ใช้ตีมูลค่าในงบดุล
 */
export function AssetManager({ currentUser }: { currentUser: { id: string; name: string } }) {
  const perms: Perms = usePermissions();
  /*
    **ทุกยอดในหน้านี้อ่านจาก `assets` (อนุมัติแล้ว) เท่านั้น** — ร่างอยู่ใน `drafts` แยกต่างหาก
    และไม่เคยถูกส่งเข้า `portfolioTotals` / `holdingMix` (ADR 0001)
  */
  const assets = useAssetStore((s) => s.assets);
  const allDrafts = useAssetStore((s) => s.drafts);
  const [layout, setLayout] = React.useState<Layout>("table");
  const [holding, setHolding] = React.useState<HoldingType | "all">("all");
  const [status, setStatus] = React.useState<"all" | "active" | "inactive">("all");
  const [sort, setSort] = React.useState<SortKey>("net");
  const [openId, setOpenId] = React.useState<string | null>(null);

  const rows = React.useMemo(() => {
    const out = assets.filter(
      (a) => (holding === "all" || a.holding === holding) && (status === "all" || a.status === status)
    );
    const by: Record<SortKey, (a: AssetRef) => number | string> = {
      name: (a) => a.name,
      value: (a) => -currentValue(a).value,
      net: (a) => -monthlyFor(a).net,
      yield: (a) => -(yieldPct(a) ?? -Infinity),
      cost: (a) => -a.cost,
    };
    return [...out].sort((x, y) => {
      const a = by[sort](x);
      const b = by[sort](y);
      return typeof a === "string" ? a.localeCompare(b as string, "th") : (a as number) - (b as number);
    });
  }, [assets, holding, status, sort]);

  const openAsset = React.useCallback((id: string) => setOpenId(id), []);

  return (
    <div className="flex flex-col gap-4 pb-24">
      <DraftStrip perms={perms} allDrafts={allDrafts} userId={currentUser.id} />
      <Dashboard assets={assets} />

      <div className="flex flex-wrap items-end gap-3 rounded-card border border-line bg-surface p-[14px_18px] shadow-card">
        <Field label="ประเภททรัพย์" className="min-w-[220px]">
          <Select value={holding} onChange={(e) => setHolding(e.target.value as HoldingType | "all")}>
            <option value="all">ทุกประเภท ({assets.length})</option>
            {(Object.keys(HOLDING_LABEL) as HoldingType[]).map((h) => {
              const n = assets.filter((a) => a.holding === h).length;
              return (
                <option key={h} value={h} disabled={n === 0}>
                  {HOLDING_LABEL[h]} ({n})
                </option>
              );
            })}
          </Select>
        </Field>

        <Field label="สถานะ" className="min-w-[180px]">
          <Select value={status} onChange={(e) => setStatus(e.target.value as "all" | "active" | "inactive")}>
            <option value="all">ทั้งหมด</option>
            <option value="active">ใช้งานอยู่</option>
            <option value="inactive">หยุดไว้</option>
          </Select>
        </Field>

        <Field label="เรียงตาม" className="min-w-[250px]">
          <Select value={sort} onChange={(e) => setSort(e.target.value as SortKey)}>
            {SORTS.map((s) => (
              <option key={s.key} value={s.key}>{s.label}</option>
            ))}
          </Select>
        </Field>

        <div className="ml-auto flex gap-2">
          {([["table", "ตาราง"], ["cards", "การ์ด"], ["map", "แผนที่"]] as [Layout, string][]).map(([k, label]) => (
            <Button key={k} variant={layout === k ? "primary" : "secondary"} onClick={() => setLayout(k)}>
              {label}
            </Button>
          ))}
        </div>
      </div>

      {layout === "table" ? <TableLayout rows={rows} onOpen={openAsset} /> : null}
      {layout === "cards" ? <CardLayout rows={rows} onOpen={openAsset} /> : null}
      {layout === "map" ? <AssetMap rows={rows} onOpen={openAsset} /> : null}

      <AssetSheet asset={assets.find((a) => a.id === openId) ?? null} perms={perms} currentUser={currentUser} onClose={() => setOpenId(null)} />
    </div>
  );
}

/* ---------- ทางเข้าลงทะเบียน + คิวร่าง ---------- */

/**
 * ปุ่มลงทะเบียน/คิวร่าง — โชว์ตามสิทธิ์ (ความสะดวก ไม่ใช่ความปลอดภัย · RLS คือของจริง)
 * และบอกตรงนี้เลยว่ามีร่างค้างกี่รายการ **ที่ยังไม่อยู่ในตัวเลขด้านล่าง** — คนอ่านพอร์ตจะได้ไม่งง
 * ว่าทรัพย์ที่เพิ่งลงไปหายไปไหน
 */
function DraftStrip({ perms, allDrafts, userId }: { perms: Perms; allDrafts: AssetDraft[]; userId: string }) {
  const mode = registerMode(perms);
  const queue = canSeeDraftQueue(perms);
  const pending = visibleDrafts(allDrafts, perms, userId).filter((d) => d.status === "pending").length;
  if (mode === "none" && !queue) return null;

  return (
    <div className="flex flex-wrap items-center gap-3 rounded-card border border-line bg-surface p-[14px_18px] shadow-card" data-testid="draft-strip">
      {pending > 0 ? (
        <div className="mr-auto text-base" data-testid="draft-strip-note">
          <b>มีร่างรออนุมัติ {pending} รายการ</b>
          <span className="text-ink-600"> — ยังไม่ถูกนับในตัวเลขของหน้านี้</span>
        </div>
      ) : (
        <div className="mr-auto text-base text-ink-600">ไม่มีร่างค้างอนุมัติ</div>
      )}
      {mode !== "none" ? (
        <Link href="/assets/new" className={cn(LINK_BUTTON_CLASS, "border-brand-600 bg-brand-600 text-white hover:bg-brand-700")}>
          ลงทะเบียนทรัพย์
        </Link>
      ) : null}
      {queue ? (
        <Link href="/assets/drafts" className={cn(LINK_BUTTON_CLASS, "border-line bg-surface text-ink-900 hover:border-ink-400")}>
          คิวร่าง ({pending})
        </Link>
      ) : null}
    </div>
  );
}

/* ---------- แถบสรุปข้างบน ---------- */

function Dashboard({ assets }: { assets: AssetRef[] }) {
  const t = portfolioTotals(assets);
  const totalValue = t.value;
  const totalCost = t.cost;
  const netMonth = t.netMonth;
  const netYear = t.netYear;
  const mix = holdingMix(assets);

  return (
    <div className="grid gap-3 lg:grid-cols-[1fr_auto]">
      <div className="flex flex-col gap-2.5 rounded-card border border-line bg-surface p-[16px_20px] shadow-card">
        <div className="flex flex-wrap items-baseline gap-2">
          <span className="text-base font-semibold">สัดส่วนประเภททรัพย์</span>
          <span className="text-sm text-ink-600">คิดจากมูลค่าปัจจุบัน {money(totalValue)} (ไม่รวมร่าง)</span>
        </div>
        <div className="flex h-3 overflow-hidden rounded-pill">
          {mix.map((m) => (
            <div key={m.h} className={HOLDING_TONE[m.h]} style={{ width: `${m.pct}%` }} title={HOLDING_LABEL[m.h]} />
          ))}
        </div>
        <div className="flex flex-wrap gap-x-5 gap-y-1.5">
          {mix.map((m) => (
            <span key={m.h} className="inline-flex items-center gap-1.5 text-base">
              <span className={cn("h-2.5 w-2.5 flex-none rounded-pill", HOLDING_TONE[m.h])} />
              {HOLDING_LABEL[m.h]}
              <b className="tabular-nums">{m.pct.toFixed(1)}%</b>
            </span>
          ))}
        </div>
      </div>

      <div className="flex flex-wrap items-center gap-x-8 gap-y-3 rounded-card border border-line bg-surface p-[16px_20px] shadow-card">
        <Figure label="ผลตอบแทนต่อปี" value={totalCost ? `${((netYear / totalCost) * 100).toFixed(2)}%` : "—"} tone="pos" strong
          sub="คิดจากต้นทุนรวม" />
        <Figure label="สุทธิต่อเดือน" value={signedMoney(netMonth)} tone={netMonth < 0 ? "neg" : "pos"}
          sub={`ทรัพย์ที่สร้างรายได้ ${t.activeCount} / ${t.count}`} />
      </div>
    </div>
  );
}

function Figure({ label, value, sub, tone, strong }: { label: string; value: string; sub?: string; tone?: "pos" | "neg"; strong?: boolean }) {
  return (
    <div>
      <div className="text-sm text-ink-600">{label}</div>
      <div className={cn("tabular-nums font-semibold", strong ? "text-h1" : "text-h2", tone === "pos" && "text-pos-fg", tone === "neg" && "text-neg-fg")}>
        {value}
      </div>
      {sub ? <div className="text-sm text-ink-600">{sub}</div> : null}
    </div>
  );
}

/* ---------- ชิ้นส่วนร่วม ---------- */

/** รูปถ่ายถ้ามี ไม่มีก็ไอคอนประจำชนิดทรัพย์ — คอลัมน์นี้ห้ามว่าง */
function Photo({ asset, size }: { asset: AssetRef; size: number }) {
  const muted = asset.status !== "active";
  if (!asset.photo) return <AssetKindIcon kind={asset.kind} size={size} muted={muted} />;
  return (
    <Image
      src={asset.photo}
      alt=""
      width={size}
      height={size}
      className={cn("flex-none rounded-card object-cover", muted && "opacity-55 grayscale")}
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

function Net({ asset, className }: { asset: AssetRef; className?: string }) {
  const m = monthlyFor(asset);
  if (asset.status !== "active") return <span className={cn("text-ink-600", className)}>—</span>;
  return <span className={cn("tabular-nums font-semibold", m.net < 0 ? "text-neg-fg" : "text-pos-fg", className)}>{signedMoney(m.net)}</span>;
}

function AssetName({ asset }: { asset: AssetRef }) {
  return (
    <span className="min-w-0">
      <span className="block whitespace-nowrap font-semibold">{asset.name}</span>
      <span className="block text-sm text-ink-600">
        {KIND_LABEL[asset.kind]} · {HOLDING_LABEL[asset.holding]}
      </span>
    </span>
  );
}

/* ---------- แบบ A · ตาราง ---------- */

function TableLayout({ rows, onOpen }: { rows: AssetRef[]; onOpen: (id: string) => void }) {
  const pt = portfolioTotals(rows);
  const totals = { cost: pt.cost, value: pt.value, net: pt.netMonth };

  return (
    <TableShell>
      <Table minWidth={1040}>
        <thead>
          <tr>
            <Th className="min-w-[280px]">ทรัพย์</Th>
            <Th>ถือในชื่อ</Th>
            <Th>สถานะ</Th>
            <Th align="right">ต้นทุนมูลค่า</Th>
            <Th align="right">มูลค่าปัจจุบัน</Th>
            <Th align="right">สุทธิ/เดือน</Th>
            <Th align="right">ผลตอบแทน/ปี</Th>
          </tr>
        </thead>
        <tbody>
          {rows.map((a) => {
            const cv = currentValue(a);
            const y = yieldPct(a);
            return (
              <tr key={a.id} className="bg-surface">
                <Td className="p-0">
                  <button
                    type="button"
                    className="flex min-h-control w-full items-center gap-3 p-[10px_16px] text-left hover:bg-brand-50"
                    onClick={() => onOpen(a.id)}
                  >
                    <Photo asset={a} size={40} />
                    <AssetName asset={a} />
                  </button>
                </Td>
                <Td><Owner ownerId={a.ownerId} /></Td>
                <Td className="whitespace-nowrap"><StatusChip asset={a} /></Td>
                <Td align="right" className="whitespace-nowrap tabular-nums">{money(a.cost)}</Td>
                <Td align="right" className="whitespace-nowrap tabular-nums">
                  {money(cv.value)}
                  {cv.basis === "cost" ? <span className="block text-sm text-ink-600">ยังไม่ประเมิน</span> : null}
                </Td>
                <Td align="right" className="whitespace-nowrap"><Net asset={a} /></Td>
                <Td align="right" className="whitespace-nowrap tabular-nums">
                  {y === null ? <span className="text-ink-600">—</span> : <b className={y < 0 ? "text-neg-fg" : "text-pos-fg"}>{y.toFixed(2)}%</b>}
                </Td>
              </tr>
            );
          })}
        </tbody>
        {/* รวมท้ายตาราง — รวมเฉพาะแถวที่กรองอยู่ ไม่ใช่ทั้งทะเบียน */}
        <tfoot>
          <tr className="bg-canvas">
            <Td className="font-semibold">รวม {rows.length} รายการ</Td>
            <Td />
            <Td />
            <Td align="right" className="whitespace-nowrap tabular-nums font-semibold">{money(totals.cost)}</Td>
            <Td align="right" className="whitespace-nowrap tabular-nums font-semibold">{money(totals.value)}</Td>
            <Td align="right" className="whitespace-nowrap tabular-nums font-semibold">
              <span className={totals.net < 0 ? "text-neg-fg" : "text-pos-fg"}>{signedMoney(totals.net)}</span>
            </Td>
            <Td align="right" className="whitespace-nowrap tabular-nums font-semibold">
              {totals.cost ? `${(((totals.net * 12) / totals.cost) * 100).toFixed(2)}%` : "—"}
            </Td>
          </tr>
        </tfoot>
      </Table>
    </TableShell>
  );
}

/* ---------- แบบ B · การ์ด ---------- */

function CardLayout({ rows, onOpen }: { rows: AssetRef[]; onOpen: (id: string) => void }) {
  return (
    <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
      {rows.map((a) => {
        const cv = currentValue(a);
        return (
          <button
            key={a.id}
            type="button"
            onClick={() => onOpen(a.id)}
            className="flex flex-col overflow-hidden rounded-card border border-line bg-surface text-left shadow-card hover:border-brand-100"
          >
            {a.photo ? (
              <Image
                src={a.photo}
                alt=""
                width={480}
                height={200}
                className={cn("h-[140px] w-full object-cover", a.status !== "active" && "opacity-55 grayscale")}
              />
            ) : (
              <div className={cn("flex h-[140px] w-full items-center justify-center border-b border-line", a.status !== "active" ? "bg-canvas" : "bg-brand-50")}>
                <AssetKindIcon kind={a.kind} size={88} muted={a.status !== "active"} className="border-0 bg-transparent" />
              </div>
            )}
            <div className="flex flex-1 flex-col gap-2.5 p-[16px_18px]">
              <div className="flex items-start gap-2">
                <div className="mr-auto min-w-0">
                  <div className="font-semibold">{a.name}</div>
                  <div className="text-sm text-ink-600">{KIND_LABEL[a.kind]} · {HOLDING_LABEL[a.holding]}</div>
                </div>
                <StatusChip asset={a} />
              </div>
              <Owner ownerId={a.ownerId} />
              <div className="mt-auto flex items-end justify-between border-t border-line pt-2.5">
                <div className="text-sm text-ink-600">
                  <div>ต้นทุน {money(a.cost)}</div>
                  <div>มูลค่า {money(cv.value)}</div>
                </div>
                <div className="text-right">
                  <div className="text-sm text-ink-600">สุทธิ/เดือน</div>
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

/* ---------- แผงขวา ---------- */

function AssetSheet({
  asset,
  perms,
  currentUser,
  onClose,
}: {
  asset: AssetRef | null;
  perms: Perms;
  currentUser: { id: string; name: string };
  onClose: () => void;
}) {
  const showToast = useApp((s) => s.showToast);
  const drafts = useAssetStore((s) => s.drafts);
  const [proposing, setProposing] = React.useState(false);
  if (!asset) return null;

  // ร่างแก้ไขที่ค้างของทรัพย์นี้ (เฉพาะที่ผู้ใช้มีสิทธิ์เห็น) — บอกไว้ว่ายังไม่มีผลกับตัวเลขข้างบน
  const pendingEdits = visibleDrafts(drafts, perms, currentUser.id).filter(
    (d) => d.status === "pending" && d.kind === "update" && d.targetAssetId === asset.id
  ).length;

  const m = monthlyFor(asset);
  const cv = currentValue(asset);
  const y = yieldPct(asset);
  const stopped = asset.status !== "active";

  return (
    <Dialog open onOpenChange={(o) => (o ? null : onClose())}>
      <SheetContent aria-describedby={undefined} width="max-w-[620px]">
        <DialogPrimitive.Title className="sr-only">รายละเอียดทรัพย์</DialogPrimitive.Title>
        <SheetHeader title={asset.name} onClose={onClose} />

        <div className="flex flex-1 flex-col gap-5 overflow-auto p-[20px_24px]">
          <div className="flex gap-4">
            <Photo asset={asset} size={96} />
            <div className="flex flex-col items-start gap-2">
              <StatusChip asset={asset} />
              <div className="text-base text-ink-600">{KIND_LABEL[asset.kind]} · {HOLDING_LABEL[asset.holding]}</div>
              <Owner ownerId={asset.ownerId} />
              <Button variant="secondary" onClick={() => showToast("ตัวอย่างหน้าจอ — ต่อ Supabase Storage แล้วจะอัพรูปได้จริง")}>
                เปลี่ยนรูป
              </Button>
            </div>
          </div>
          {asset.statusNote ? <div className="text-base text-ink-600">{asset.statusNote}</div> : null}
          {pendingEdits > 0 ? (
            <div role="note" className="rounded border border-warn bg-warn-bg p-[10px_12px] text-base leading-7 text-warn-fg">
              มีร่างแก้ไขทรัพย์นี้รออนุมัติ {pendingEdits} รายการ — ข้อมูลข้างล่างยังเป็นค่าเดิม
            </div>
          ) : null}

          <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
            <Mini label="ต้นทุน" value={money(asset.cost)} />
            <Mini label="มูลค่าปัจจุบัน" value={money(cv.value)} sub={VALUE_BASIS_LABEL[cv.basis]} />
            <Mini label="สุทธิ/เดือน" value={stopped ? "—" : signedMoney(m.net)} />
            <Mini label="ผลตอบแทน/ปี" value={y === null ? "—" : `${y.toFixed(2)}%`} sub="จากต้นทุน" />
          </div>

          <Section title="ทำเล">
            <Rows
              items={[
                ["จังหวัด", asset.location?.province],
                ["ที่ตั้ง", asset.location?.address],
              ]}
            />
            <MapsLinkField
              key={asset.id}
              value={asset.location?.mapsUrl ?? ""}
              lat={asset.location?.lat}
              lng={asset.location?.lng}
            />
          </Section>

          <Section title="เอกสารสิทธิ์">
            <Rows
              items={[
                ["ชื่อหลังโฉนด", asset.legal?.titleDeedName],
                ["สำนักงานที่ดิน", asset.legal?.landOffice],
                ["ขนาด", asset.legal?.sizeLabel],
                ["เลขที่โฉนด", asset.legal?.deedNo],
              ]}
            />
            {asset.legal?.titleDeedName && asset.legal.titleDeedName !== entityById(asset.ownerId).name ? (
              <div className="rounded border border-warn bg-warn-bg p-[10px_12px] text-sm leading-6 text-warn-fg">
                ⚠ ชื่อหลังโฉนดเป็น <b>{asset.legal.titleDeedName}</b> แต่ผู้ถือตามบัญชีคือ{" "}
                <b>{entityById(asset.ownerId).name}</b> — ถือแทน ต้องมีเอกสารรองรับ
              </div>
            ) : null}
          </Section>

          <Section title="ราคาประเมิน">
            <Rows
              items={[
                ["ราคาประเมินกรมที่ดิน", asset.valuation?.appraised ? money(asset.valuation.appraised) : undefined],
                ["ราคาตลาด", asset.valuation?.market ? money(asset.valuation.market) : undefined],
                ["ประเมินเมื่อ", asset.valuation?.asOf],
              ]}
            />
          </Section>

          {asset.bank ? (
            <Section title="ภาระกับธนาคาร">
              <Rows
                items={[
                  ["ธนาคาร", asset.bank.lender],
                  ["ยอดค้าง", asset.bank.outstanding ? money(asset.bank.outstanding) : undefined],
                  ["ผ่อนต่อเดือน", asset.bank.instalmentPerMonth ? money(asset.bank.instalmentPerMonth) : undefined],
                ]}
              />
              <div className="text-sm leading-6 text-ink-600">
                ยอดค้างเป็น<b>หนี้สินในงบดุล</b> ไม่ได้เอาไปหักมูลค่าทรัพย์ — ทรัพย์กับหนี้อยู่คนละฝั่งของงบ
              </div>
            </Section>
          ) : null}

          {asset.tenancy ? (
            <Section title="ผู้เช่า">
              <Rows
                items={[
                  ["ชื่อผู้เช่า", asset.tenancy.tenantName],
                  ["เบอร์ติดต่อ", asset.tenancy.tenantPhone],
                  ["เงินมัดจำ", asset.tenancy.depositAmount ? money(asset.tenancy.depositAmount) : undefined],
                  ["สัญญา", asset.tenancy.contractStart ? `${asset.tenancy.contractStart} – ${asset.tenancy.contractEnd ?? "—"}` : undefined],
                ]}
              />
            </Section>
          ) : null}

          {asset.contract ? (
            <Section title="สัญญา">
              <Rows
                items={[
                  ["คู่สัญญา", asset.contract.counterparty],
                  ["รับมาจาก", asset.contract.referredBy],
                  ["เงินต้นที่ปล่อย", asset.contract.principal ? money(asset.contract.principal) : undefined],
                  ["ดอกเบี้ย/เดือน", asset.contract.ratePerMonth ? `${(asset.contract.ratePerMonth * 100).toFixed(2)}%` : undefined],
                  ["หักล่วงหน้า", asset.contract.prepaidMonths ? `${asset.contract.prepaidMonths} เดือน` : undefined],
                  ["สินไถ่", asset.contract.redemptionValue ? money(asset.contract.redemptionValue) : undefined],
                  ["อายุสัญญา", asset.contract.startDate ? `${asset.contract.startDate} – ${asset.contract.endDate ?? "—"}` : undefined],
                  ["งวดถัดไป", asset.contract.nextDueDate],
                  ["ช่วงส่ง Notice", asset.contract.noticeWindow],
                ]}
              />
              {asset.contract.noticeWindow ? (
                <div
                  className={cn(
                    "rounded border p-[10px_12px] text-sm leading-6",
                    asset.contract.noticeSent ? "border-pos bg-pos-bg text-pos-fg" : "border-warn bg-warn-bg text-warn-fg"
                  )}
                >
                  {asset.contract.noticeSent ? "✓ ส่ง Notice แล้ว" : "⚠ ยังไม่ได้ส่ง Notice — พ้นช่วงแล้วบังคับตามสัญญาไม่ได้"}
                </div>
              ) : null}
            </Section>
          ) : null}

          <Section title="รายการประจำ">
            {asset.recurring.length === 0 ? (
              <div className="text-base text-ink-600">ยังไม่มีรายการประจำ</div>
            ) : (
              <ul className="m-0 flex list-none flex-col gap-2 p-0">
                {asset.recurring.map((r) => (
                  <li key={r.id} className="flex flex-wrap items-center gap-2 rounded-card border border-line bg-canvas p-[12px_14px]">
                    <div className="mr-auto">
                      <div className="text-base font-semibold">{r.label}</div>
                      <div className="text-sm text-ink-600">
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
          </Section>
        </div>

        {/*
          ปุ่มตามสิทธิ์ — ไม่โชว์ปุ่มที่กดแล้วถูกปฏิเสธ
          **ซ่อนปุ่มคือความสะดวก ไม่ใช่ความปลอดภัย** ความปลอดภัยจริงอยู่ที่ RLS ใน DB
          (`assets_update` · `asset_drafts_insert` · `valuations_insert`)
          - ตีราคา: asset.value เท่านั้น (Manager ไม่มี)
          - แก้ตรง: asset.manage · เสนอแก้เป็นร่าง: คนที่แก้ตรงไม่ได้ (Staff)
        */}
        <DialogFooter className="justify-between">
          <Button variant="secondary" asChild>
            <Link href={`/assets/${asset.id}`} className="no-underline hover:no-underline">
              ดูทะเบียนเต็ม
            </Link>
          </Button>
          <div className="flex flex-wrap gap-2">
            {sheetActions(perms).map((a) => (
              <Button
                key={a.id}
                variant={a.id === "value" ? "secondary" : "primary"}
                onClick={() => (a.id === "propose" ? setProposing(true) : showToast("ตัวอย่างหน้าจอ ยังไม่เขียนลงฐานข้อมูล"))}
              >
                {a.label}
              </Button>
            ))}
          </div>
        </DialogFooter>
      </SheetContent>
      {proposing ? (
        <ProposeEditDialog asset={asset} perms={perms} currentUser={currentUser} onClose={() => setProposing(false)} />
      ) : null}
    </Dialog>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-2">
      <div className="text-base font-semibold">{title}</div>
      {children}
    </div>
  );
}

/** แสดงเฉพาะช่องที่มีค่า — ช่องว่างเปล่าเต็มหน้าทำให้หาของที่มีจริงยากขึ้น */
function Rows({ items }: { items: [string, React.ReactNode | undefined][] }) {
  const shown = items.filter(([, v]) => v !== undefined && v !== null && v !== "");
  if (shown.length === 0) return <div className="text-base text-ink-600">ยังไม่ได้กรอก</div>;
  return (
    <dl className="m-0 grid grid-cols-[auto_1fr] gap-x-5 gap-y-2 text-base">
      {shown.map(([k, v]) => (
        <React.Fragment key={k}>
          <dt className="whitespace-nowrap text-ink-600">{k}</dt>
          <dd className="m-0">{v}</dd>
        </React.Fragment>
      ))}
    </dl>
  );
}

function Mini({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div className="rounded-card border border-line bg-canvas p-[12px_14px]">
      <div className="text-sm text-ink-600">{label}</div>
      <div className="text-base font-semibold tabular-nums">{value}</div>
      {sub ? <div className="text-sm text-ink-600">{sub}</div> : null}
    </div>
  );
}
