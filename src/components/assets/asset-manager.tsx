"use client";

import * as React from "react";
import Link from "next/link";
import {
  DEFAULT_FILTER,
  FAMILY_OWNER,
  GROUP_BY_LABEL,
  allTags,
  filterAssets,
  groupAssets,
  iconKindFor,
  sumReports,
  type AssetFilter,
  type AssetView,
  type GroupBy,
  VALUE_NOT_ACCOUNTING,
} from "@/lib/db/assets-model";
import type { RegisterData } from "@/lib/db/assets-server";
import type { RefOwner } from "@/lib/db/reference-types";
import { isoToDmy, money } from "@/lib/format";
import { TableShell, Table, Th, Td } from "@/components/ui/table";
import { Field } from "@/components/ui/field";
import { Input, Select } from "./fields";
import { Button } from "./tall-button";
import { AssetKindIcon } from "./asset-kind-icon";
import { Money, NO_LEDGER_NOTE, Notice, OwnerDot, StatusChip, TagChips } from "./asset-parts";
import { LINK_BUTTON_CLASS } from "./draft-parts";
import { usePermissions } from "@/components/auth/permissions-provider";
import { canSeeDraftQueue, registerMode, type Perms } from "./asset-drafts";
import { cn } from "@/lib/utils";

type Layout = "table" | "cards";
type SortKey = "name" | "cost" | "income" | "value";

const SORTS: { key: SortKey; label: string }[] = [
  { key: "name", label: "ชื่อทรัพย์ ก–ฮ" },
  { key: "cost", label: "ต้นทุนรวม มากไปน้อย" },
  { key: "income", label: "รายได้สะสม มากไปน้อย" },
  { key: "value", label: "มูลค่าประเมิน มากไปน้อย" },
];

const STATUS_OPTIONS: { key: AssetFilter["status"]; label: string }[] = [
  { key: "all", label: "ทั้งหมด" },
  { key: "active", label: "ใช้งานอยู่" },
  { key: "inactive", label: "หยุดไว้" },
  { key: "closed", label: "ขายแล้ว / ไถ่ถอนแล้ว" },
];

/**
 * หน้าบริหารสินทรัพย์ — ข้อมูลจริงจากทะเบียนและสมุดบัญชี (ไม่มีข้อมูลจำลอง)
 *
 * **ต้นทุนแสดงรายชิ้นเท่านั้น** (ลูกพี่สั่ง 25/10) — การจัดกลุ่มมีไว้ "ดู" ส่วนหัวกลุ่มบอกแค่ชื่อกลุ่มกับจำนวนชิ้น
 * ไม่มีต้นทุนรวมหรือต้นทุนเฉลี่ยต่อกลุ่ม · แถว "รวม" ท้ายตารางเป็นผลบวกของยอดแต่ละชิ้นไว้กระทบกับงบเท่านั้น
 * **มูลค่าประเมินแยกคอลัมน์และแยกกรอบ** — ไม่ใช่ตัวเลขทางบัญชี ไม่เข้างบดุล
 */
export function AssetManager({ data, initialOwner }: { data: RegisterData; initialOwner?: string }) {
  const perms: Perms = usePermissions();
  const { assets, owners, reports, values, drafts, ledgerAccess } = data;

  const ownerIds = owners.map((o) => o.id);
  const [filter, setFilter] = React.useState<AssetFilter>({
    ...DEFAULT_FILTER,
    owner: initialOwner && ownerIds.includes(initialOwner) ? initialOwner : FAMILY_OWNER,
  });
  const [groupBy, setGroupBy] = React.useState<GroupBy>("none");
  const [sort, setSort] = React.useState<SortKey>("name");
  const [layout, setLayout] = React.useState<Layout>("table");

  const ownerOf = React.useCallback((id: string) => owners.find((o) => o.id === id), [owners]);
  const valueOf = (a: AssetView) => values[a.id]?.value ?? null;

  const rows = React.useMemo(() => {
    const out = filterAssets(assets, filter);
    const by: Record<SortKey, (a: AssetView) => number | string> = {
      name: (a) => a.name,
      cost: (a) => -(reports?.[a.id]?.costTotal ?? -Infinity),
      income: (a) => -(reports?.[a.id]?.income ?? -Infinity),
      value: (a) => -(values[a.id]?.value ?? -Infinity),
    };
    return [...out].sort((x, y) => {
      const a = by[sort](x);
      const b = by[sort](y);
      return typeof a === "string" ? a.localeCompare(b as string, "th") : (a as number) - (b as number);
    });
  }, [assets, filter, sort, reports, values]);

  const groups = React.useMemo(() => groupAssets(rows, groupBy, (id) => ownerOf(id)?.name ?? "ไม่ทราบผู้ถือ"), [rows, groupBy, ownerOf]);
  const totals = reports ? sumReports(rows, reports) : null;
  const valued = rows.filter((a) => valueOf(a) !== null);
  const valueSum = valued.reduce((t, a) => t + Math.round((valueOf(a) ?? 0) * 100), 0) / 100;
  const tags = React.useMemo(() => allTags(assets), [assets]);

  const mode = registerMode(perms);
  const queue = canSeeDraftQueue(perms);
  const pendingDrafts = drafts.filter((d) => d.status === "pending").length;

  function setOwner(owner: string) {
    setFilter((f) => ({ ...f, owner }));
    // เก็บมุมมองไว้ใน URL ให้ส่งลิงก์/รีเฟรชแล้วได้มุมมองเดิม (รูปเดียวกับหน้างบการเงิน)
    const url = new URL(window.location.href);
    if (owner === FAMILY_OWNER) url.searchParams.delete("owner");
    else url.searchParams.set("owner", owner);
    window.history.replaceState(null, "", url);
  }

  const visibleOwners = owners.filter((o) => o.status === "active" || assets.some((a) => a.ownerId === o.id));

  return (
    <div className="flex flex-col gap-4 pb-24">
      {/* ทางเข้าลงทะเบียน + คิวร่าง — บอกตรงนี้ว่ามีร่างค้างกี่รายการที่ "ยังไม่อยู่ในตัวเลขด้านล่าง" */}
      {mode !== "none" || queue ? (
        <div className="flex flex-wrap items-center gap-3 rounded-card border border-line bg-surface p-[14px_18px] shadow-card" data-testid="draft-strip">
          {pendingDrafts > 0 ? (
            <div className="mr-auto text-base" data-testid="draft-strip-note">
              <b>มีร่างรออนุมัติ {pendingDrafts} รายการ</b>
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
              คิวร่าง ({pendingDrafts})
            </Link>
          ) : null}
        </div>
      ) : null}

      {!ledgerAccess ? <Notice tone="info">{NO_LEDGER_NOTE}</Notice> : null}
      {data.unclassifiedLines > 0 ? (
        <Notice tone="warn">
          มี {data.unclassifiedLines} บรรทัดในสมุดที่ใช้รหัสบัญชีนอกผังบัญชี จึงไม่ถูกรวมในตัวเลขรายทรัพย์ — แจ้งผู้ดูแลระบบ
        </Notice>
      ) : null}

      <div className="grid gap-3 lg:grid-cols-[1fr_1fr]">
        <section aria-label="ตัวเลขตามสมุดบัญชี" className="flex flex-col gap-2 rounded-card border border-line bg-surface p-[16px_20px] shadow-card">
          <div className="text-base font-semibold">ตัวเลขตามสมุดบัญชี (คำนวณใหม่ทุกครั้งที่เปิดหน้า)</div>
          <div className="flex flex-wrap gap-x-8 gap-y-3">
            <Figure label="จำนวนทรัพย์ที่แสดง" value={`${rows.length} ชิ้น`} sub={`จากทั้งหมด ${assets.length} ชิ้นที่คุณเห็น`} />
            <Figure label="ต้นทุนรวมของทุกชิ้น" value={totals ? money(totals.costTotal, { dash: false }) : "ไม่มีสิทธิ์ดู"} sub="ผลบวกต้นทุนของแต่ละชิ้น" />
            <Figure label="รายได้สะสมรวม" value={totals ? money(totals.income, { dash: false }) : "ไม่มีสิทธิ์ดู"} sub="ค่าเช่า ดอกเบี้ย ฯลฯ ตามสมุด" />
          </div>
        </section>

        {/* กรอบประเมิน — แยกจากตัวเลขบัญชีให้เห็นชัดว่าคนละเรื่อง */}
        <section aria-label="มูลค่าประเมิน" className="flex flex-col gap-2 rounded-card border-2 border-dashed border-warn bg-canvas p-[16px_20px]">
          <div className="text-base font-semibold">มูลค่าประเมินปัจจุบัน (ไม่ใช่ตัวเลขทางบัญชี)</div>
          <div className="flex flex-wrap gap-x-8 gap-y-3">
            <Figure label="ผลบวกราคาประเมินล่าสุด" value={money(valueSum, { dash: false })} sub={`${valued.length} จาก ${rows.length} ชิ้นมีราคาประเมิน`} />
          </div>
          <div className="text-sm leading-6 text-ink-600">{VALUE_NOT_ACCOUNTING}</div>
        </section>
      </div>

      <div className="flex flex-wrap items-end gap-3 rounded-card border border-line bg-surface p-[14px_18px] shadow-card">
        <Field label="ผู้ถือ" className="min-w-[220px]">
          <Select value={filter.owner} onChange={(e) => setOwner(e.target.value)}>
            <option value={FAMILY_OWNER}>SRI Family (รวมทุกชื่อ)</option>
            {visibleOwners.map((o) => (
              <option key={o.id} value={o.id}>{o.name}</option>
            ))}
          </Select>
        </Field>
        <Field label="หมวดใหญ่" className="min-w-[200px]">
          <Select value={filter.classCode} onChange={(e) => setFilter((f) => ({ ...f, classCode: e.target.value }))}>
            <option value="all">ทุกหมวด</option>
            {data.taxonomy.classes.map((c) => (
              <option key={c.id} value={c.code}>{c.nameTh}</option>
            ))}
          </Select>
        </Field>
        <Field label="สถานะ" className="min-w-[180px]">
          <Select value={filter.status} onChange={(e) => setFilter((f) => ({ ...f, status: e.target.value as AssetFilter["status"] }))}>
            {STATUS_OPTIONS.map((s) => (
              <option key={s.key} value={s.key}>{s.label}</option>
            ))}
          </Select>
        </Field>
        <Field label="ป้ายกำกับ (TAG)" className="min-w-[180px]">
          <Select value={filter.tag} onChange={(e) => setFilter((f) => ({ ...f, tag: e.target.value }))}>
            <option value="">ทุกป้าย</option>
            {tags.map((t) => (
              <option key={t} value={t}>{t}</option>
            ))}
          </Select>
        </Field>
        <Field label="ค้นหา (ชื่อ รหัส ที่ตั้ง)" className="min-w-[220px] flex-1">
          <Input value={filter.q} onChange={(e) => setFilter((f) => ({ ...f, q: e.target.value }))} autoComplete="off" />
        </Field>
        <Field label="จัดกลุ่มเพื่อดู" className="min-w-[230px]">
          <Select value={groupBy} onChange={(e) => setGroupBy(e.target.value as GroupBy)}>
            {(Object.keys(GROUP_BY_LABEL) as GroupBy[]).map((g) => (
              <option key={g} value={g}>{GROUP_BY_LABEL[g]}</option>
            ))}
          </Select>
        </Field>
        <Field label="เรียงตาม" className="min-w-[220px]">
          <Select value={sort} onChange={(e) => setSort(e.target.value as SortKey)}>
            {SORTS.map((s) => (
              <option key={s.key} value={s.key}>{s.label}</option>
            ))}
          </Select>
        </Field>
        <div className="ml-auto flex gap-2">
          {([["table", "ตาราง"], ["cards", "การ์ด"]] as [Layout, string][]).map(([k, label]) => (
            <Button key={k} variant={layout === k ? "primary" : "secondary"} onClick={() => setLayout(k)}>
              {label}
            </Button>
          ))}
        </div>
      </div>

      {groupBy !== "none" ? (
        <Notice tone="info" className="py-2">
          จัดกลุ่มไว้เพื่อ<b>ดู</b>เท่านั้น — ต้นทุนของแต่ละห้อง/แต่ละชิ้นยังแยกกัน ระบบไม่เอาต้นทุนของคนละชิ้นมารวมคิดกัน
        </Notice>
      ) : null}

      {rows.length === 0 ? (
        <div className="rounded-card border border-line bg-surface p-6 text-base text-ink-600 shadow-card" data-testid="no-assets">
          {assets.length === 0
            ? "ยังไม่มีทรัพย์ในทะเบียนที่คุณมีสิทธิ์เห็น"
            : "ไม่มีทรัพย์ที่ตรงกับตัวกรองนี้ — ลองเปลี่ยนผู้ถือหรือล้างคำค้นหา"}
        </div>
      ) : layout === "table" ? (
        <TableLayout groups={groups} grouped={groupBy !== "none"} reports={reports} values={values} ownerOf={ownerOf} totals={totals} valueSum={valueSum} valuedCount={valued.length} total={rows.length} />
      ) : (
        <CardLayout groups={groups} grouped={groupBy !== "none"} reports={reports} values={values} ownerOf={ownerOf} />
      )}
    </div>
  );
}

function Figure({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div>
      <div className="text-sm text-ink-600">{label}</div>
      <div className="text-h2 font-semibold tabular-nums">{value}</div>
      {sub ? <div className="text-sm text-ink-600">{sub}</div> : null}
    </div>
  );
}

type OwnerOf = (id: string) => RefOwner | undefined;

function AssetName({ a }: { a: AssetView }) {
  return (
    <span className="min-w-0">
      <span className="block font-semibold">{a.name}</span>
      <span className="block text-sm text-ink-600">
        {a.code} · {a.className} › {a.categoryName}
      </span>
      {a.location ? <span className="block text-sm text-ink-600">{a.location}</span> : null}
      <TagChips tags={a.tags} />
    </span>
  );
}

function ValueCell({ a, values }: { a: AssetView; values: RegisterData["values"] }) {
  const v = values[a.id];
  if (!v || v.value === null) return <span className="text-sm text-ink-600">ยังไม่เคยตีราคา</span>;
  return (
    <span className="whitespace-nowrap tabular-nums">
      {money(v.value, { dash: false })}
      <span className="block text-sm text-ink-600">
        ณ {isoToDmy(v.asOf)}
        {v.isStale ? " · ราคาเก่าเกิน 7 วัน" : ""}
      </span>
    </span>
  );
}

function TableLayout({
  groups, grouped, reports, values, ownerOf, totals, valueSum, valuedCount, total,
}: {
  groups: ReturnType<typeof groupAssets<AssetView>>;
  grouped: boolean;
  reports: RegisterData["reports"];
  values: RegisterData["values"];
  ownerOf: OwnerOf;
  totals: ReturnType<typeof sumReports> | null;
  valueSum: number;
  valuedCount: number;
  total: number;
}) {
  return (
    <TableShell>
      <Table minWidth={1180}>
        <thead>
          <tr>
            <Th className="min-w-[280px]">ทรัพย์</Th>
            <Th>ถือในชื่อ</Th>
            <Th>สถานะ</Th>
            <Th align="right">ต้นทุนซื้อ</Th>
            <Th align="right">ค่าปรับปรุงสะสม</Th>
            <Th align="right">ค่าซ่อมสะสม</Th>
            <Th align="right">รายได้สะสม</Th>
            <Th align="right" className="border-l-2 border-dashed border-warn">มูลค่าประเมิน (ไม่ใช่ตัวเลขบัญชี)</Th>
            <Th>{""}</Th>
          </tr>
        </thead>
        <tbody>
          {groups.map((g) => (
            <React.Fragment key={g.key}>
              {grouped ? (
                <tr data-testid="group-row">
                  <Td colSpan={9} className="bg-canvas font-semibold">
                    {g.title} <span className="font-normal text-ink-600">({g.assets.length} ชิ้น)</span>
                  </Td>
                </tr>
              ) : null}
              {g.assets.map((a) => {
                const r = reports?.[a.id] ?? null;
                return (
                  <tr key={a.id} className="bg-surface" data-testid={`asset-row-${a.id}`}>
                    <Td className="p-[10px_12px]">
                      <span className="flex items-start gap-3">
                        <AssetKindIcon kind={iconKindFor(a)} size={40} muted={a.status !== "active"} />
                        <AssetName a={a} />
                      </span>
                    </Td>
                    <Td><OwnerDot owner={ownerOf(a.ownerId)} /></Td>
                    <Td className="whitespace-nowrap"><StatusChip status={a.status} /></Td>
                    <Td align="right"><Money value={r?.purchase} /></Td>
                    <Td align="right"><Money value={r?.renovation} /></Td>
                    <Td align="right"><Money value={r?.repair} /></Td>
                    <Td align="right"><Money value={r?.income} /></Td>
                    <Td align="right" className="border-l-2 border-dashed border-warn"><ValueCell a={a} values={values} /></Td>
                    <Td className="whitespace-nowrap">
                      <Link href={`/assets/${a.id}`} className={cn(LINK_BUTTON_CLASS, "border-line bg-surface text-ink-900 hover:border-ink-400")} aria-label={`ดูรายงานของ ${a.name}`}>
                        ดูรายงาน
                      </Link>
                    </Td>
                  </tr>
                );
              })}
            </React.Fragment>
          ))}
        </tbody>
        {/* รวมท้ายตาราง — ผลบวกของยอดแต่ละชิ้นที่แสดงอยู่ (ไม่ใช่ค่าเฉลี่ย) ไว้กระทบกับงบ */}
        <tfoot>
          <tr className="bg-canvas font-semibold">
            <Td>รวม {total} ชิ้น <span className="font-normal text-ink-600">(ผลบวกของแต่ละชิ้น)</span></Td>
            <Td />
            <Td />
            <Td align="right"><Money value={totals?.purchase} /></Td>
            <Td align="right"><Money value={totals?.renovation} /></Td>
            <Td align="right"><Money value={totals?.repair} /></Td>
            <Td align="right"><Money value={totals?.income} /></Td>
            <Td align="right" className="border-l-2 border-dashed border-warn whitespace-nowrap tabular-nums">
              {money(valueSum, { dash: false })}
              <span className="block text-sm font-normal text-ink-600">{valuedCount} จาก {total} ชิ้น</span>
            </Td>
            <Td />
          </tr>
        </tfoot>
      </Table>
    </TableShell>
  );
}

function CardLayout({
  groups, grouped, reports, values, ownerOf,
}: {
  groups: ReturnType<typeof groupAssets<AssetView>>;
  grouped: boolean;
  reports: RegisterData["reports"];
  values: RegisterData["values"];
  ownerOf: OwnerOf;
}) {
  return (
    <div className="flex flex-col gap-5">
      {groups.map((g) => (
        <section key={g.key} className="flex flex-col gap-3">
          {grouped ? (
            <h2 className="m-0 text-h2 font-semibold" data-testid="group-row">
              {g.title} <span className="text-base font-normal text-ink-600">({g.assets.length} ชิ้น)</span>
            </h2>
          ) : null}
          <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
            {g.assets.map((a) => {
              const r = reports?.[a.id] ?? null;
              return (
                <article key={a.id} className="flex flex-col gap-3 rounded-card border border-line bg-surface p-[16px_18px] shadow-card" data-testid={`asset-card-${a.id}`}>
                  <div className="flex items-start gap-3">
                    <AssetKindIcon kind={iconKindFor(a)} size={48} muted={a.status !== "active"} />
                    <div className="min-w-0 flex-1">
                      <AssetName a={a} />
                    </div>
                    <StatusChip status={a.status} />
                  </div>
                  <OwnerDot owner={ownerOf(a.ownerId)} />
                  <dl className="m-0 grid grid-cols-[1fr_auto] gap-x-4 gap-y-1 border-t border-line pt-3 text-base">
                    <dt className="text-ink-600">ต้นทุนซื้อ</dt><dd className="m-0 text-right"><Money value={r?.purchase} /></dd>
                    <dt className="text-ink-600">ค่าปรับปรุงสะสม</dt><dd className="m-0 text-right"><Money value={r?.renovation} /></dd>
                    <dt className="text-ink-600">ค่าซ่อมสะสม</dt><dd className="m-0 text-right"><Money value={r?.repair} /></dd>
                    <dt className="text-ink-600">รายได้สะสม</dt><dd className="m-0 text-right"><Money value={r?.income} /></dd>
                  </dl>
                  <div className="rounded border-2 border-dashed border-warn bg-canvas p-[8px_12px] text-base">
                    <div className="text-sm text-ink-600">มูลค่าประเมิน (ไม่ใช่ตัวเลขบัญชี)</div>
                    <ValueCell a={a} values={values} />
                  </div>
                  <Link href={`/assets/${a.id}`} className={cn(LINK_BUTTON_CLASS, "border-brand-600 bg-brand-600 text-white hover:bg-brand-700")}>
                    ดูรายงานรายชิ้น
                  </Link>
                </article>
              );
            })}
          </div>
        </section>
      ))}
    </div>
  );
}

