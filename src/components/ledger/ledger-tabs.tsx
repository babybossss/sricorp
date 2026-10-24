"use client";

import * as React from "react";
import { cn } from "@/lib/utils";
import { TableShell, Table, Th, Td } from "@/components/ui/table";
import { Pill } from "@/components/ui/pill";
import { useApp } from "@/lib/store";
import { STATUS_PILL, TYPE_PILL } from "@/lib/tone";
import { money, signedMoney, plMoney } from "@/lib/format";
import { PL_SERIES, CF_GROUPS, CF_ACCOUNTS, CASH_GROUPS, UNASSIGNED_CASH_ROWS } from "@/lib/mock/ledger";
import { MONTHS } from "@/lib/mock/entities";
import { findSub, movesCash } from "@/lib/rules/tx-rules";
import { useReference } from "@/components/reference/reference-provider";
import { FAMILY_VIEW } from "@/lib/db/reference-types";
import { cashNet } from "@/lib/db/ledger-entries";
import type { LedgerListState } from "@/lib/db/ledger-entries-server";
import { isoToDmy } from "@/lib/format";
import { EntryDrawer } from "./entry-drawer";
import { ConfirmTab } from "./confirm-tab";
import { initialPosted, type PostedMap } from "./confirm-flow";

const TABS = [
  { key: "list", label: "รายการ" },
  { key: "confirm", label: "ยืนยันรับ-จ่าย" },
  { key: "pl", label: "กำไรขาดทุน (PL)" },
  { key: "cf", label: "กระแสเงินสด (CF)" },
] as const;

type TabKey = (typeof TABS)[number]["key"];

export function LedgerTabs({ ledger }: { ledger: LedgerListState }) {
  const [tab, setTab] = React.useState<TabKey>("list");
  // ประวัติการยืนยันเงินเข้า-ออกอยู่ที่นี่ ไม่ใช่ในแท็บ — แท็บถูกถอดเมื่อสลับ ถ้าเก็บไว้ในแท็บ
  // กลับมาแล้วประวัติหาย และกดยืนยันรายการเดิมซ้ำได้ (เงินสดเพิ่มสองเท่า)
  const [posted, setPosted] = React.useState<PostedMap>(() =>
    initialPosted([...UNASSIGNED_CASH_ROWS, ...CASH_GROUPS.flatMap((g) => g.rows)])
  );

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap gap-1 border-b border-line">
        {TABS.map((t) => (
          <button
            key={t.key}
            onClick={() => setTab(t.key)}
            className={cn(
              "min-h-control border-b-[3px] px-[18px] text-base font-semibold",
              tab === t.key ? "border-brand-600 text-brand-600" : "border-transparent text-ink-600"
            )}
          >
            {t.label}
          </button>
        ))}
      </div>

      {tab === "list" ? <ListTab ledger={ledger} /> : null}
      {tab === "confirm" ? (
        <>
          <MockNotice />
          <ConfirmTab posted={posted} onPostedChange={setPosted} />
        </>
      ) : null}
      {tab === "pl" ? (
        <>
          <MockNotice />
          <PLTab />
        </>
      ) : null}
      {tab === "cf" ? (
        <>
          <MockNotice />
          <CFTab />
        </>
      ) : null}
    </div>
  );
}

/**
 * แท็บยังใช้ข้อมูลจำลอง — บอกผู้ใช้ตรงๆ ว่าตัวเลขไม่ใช่ของจริง
 * (ตัวเลขจำลองที่หน้าตาเหมือนของจริงอันตรายกว่าหน้าที่ว่างเปล่า)
 */
function MockNotice() {
  return (
    <div className="rounded border border-warn bg-warn-bg p-[12px_16px] text-base leading-7 text-warn-fg">
      <b>ตัวอย่างข้อมูลจำลอง</b> — แท็บนี้ยังไม่ได้ต่อกับฐานข้อมูล ตัวเลขด้านล่างไม่ใช่ตัวเลขจริงของบ้าน
    </div>
  );
}

function ListTab({ ledger }: { ledger: LedgerListState }) {
  const entityId = useApp((s) => s.entityId);
  const ref = useReference();
  const [openId, setOpenId] = React.useState<string | null>(null);

  if (!ledger.ok) {
    return (
      <div role="alert" className="rounded border border-neg bg-neg-bg p-[14px_16px] text-base leading-7 text-neg-fg">
        โหลดรายการสมุดบัญชีจากฐานข้อมูลไม่สำเร็จ: {ledger.error}
        <div className="mt-1 text-sm">ลองโหลดหน้านี้ใหม่ ถ้ายังไม่ได้ให้แจ้งผู้ดูแลระบบ</div>
      </div>
    );
  }

  // มุมมอง "SRI Family" คือรวมทุกชื่อ — ไม่กรอง · ผู้ถือที่เลือกกรองตามเจ้าของรายการ (หรือฝั่งคู่ของรายการข้ามผู้ถือ)
  const rows =
    entityId === FAMILY_VIEW
      ? ledger.entries
      : ledger.entries.filter((e) => e.ownerId === entityId);

  const nets = rows.map((e) => cashNet(e));
  const totalIn = nets.reduce<number>((t, n) => t + (n !== null && n > 0 ? n : 0), 0);
  const totalOut = nets.reduce<number>((t, n) => t + (n !== null && n < 0 ? -n : 0), 0);
  const openEntry = openId ? ledger.entries.find((e) => e.id === openId) ?? null : null;

  const ownerOf = (id: string) => ref.owners.find((o) => o.id === id);
  const currentOwner = entityId === FAMILY_VIEW ? undefined : ownerOf(entityId);

  const filters = [
    { label: "ช่วงวันที่", value: ledger.truncated ? "ล่าสุด (ยังมีเก่ากว่านี้)" : "ทั้งหมดที่บันทึกแล้ว" },
    { label: "ถือในชื่อ", value: currentOwner?.name ?? "รวมทุกชื่อ" },
  ];

  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-wrap items-center gap-2.5">
        {filters.map((f) => (
          <div key={f.label} className="flex min-h-[48px] items-center gap-2 rounded-pill border border-line bg-surface px-3.5 text-sm text-ink-600">
            <span className="text-ink-400">{f.label}</span>
            <b className="text-ink-900">{f.value}</b>
          </div>
        ))}
        <div className="text-sm text-ink-400">เปลี่ยนผู้ถือได้ที่ตัวสลับมุมมองด้านบน</div>
      </div>

      {ledger.truncated ? (
        <div className="rounded border border-warn bg-warn-bg p-[12px_16px] text-base leading-7 text-warn-fg">
          แสดงเฉพาะรายการล่าสุด — ในฐานข้อมูลยังมีรายการเก่ากว่านี้อีก
        </div>
      ) : null}

      <TableShell>
        <Table minWidth={1180}>
          <thead>
            <tr>
              <Th className="whitespace-nowrap">วันที่เอกสาร</Th>
              <Th className="whitespace-nowrap">วันที่เงินจริง</Th>
              <Th className="whitespace-nowrap">ประเภท</Th>
              <Th>หมวดย่อย</Th>
              <Th>รายละเอียด</Th>
              <Th>โปรเจค (ทรัพย์)</Th>
              <Th>ถือในชื่อ</Th>
              <Th align="right">เงินเข้า</Th>
              <Th align="right">เงินออก</Th>
              <Th>สถานะ</Th>
              <Th align="center">ไฟล์</Th>
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 ? (
              <tr>
                <Td colSpan={11} className="py-8 text-center text-ink-600">
                  ยังไม่มีรายการในสมุดบัญชี{currentOwner ? `ของ ${currentOwner.name}` : ""} — กด “บันทึกรายการ” ด้านบนเพื่อเริ่มลงรายการ
                </Td>
              </tr>
            ) : null}
            {rows.map((e, i) => {
              const owner = ownerOf(e.ownerId);
              const found = findSub(e.subCode);
              const asset = e.assetId ? ref.assets.find((a) => a.id === e.assetId) : undefined;
              const net = nets[i];
              const reversal = e.source === "reverse";
              // ค้างรับ-ค้างจ่าย = หมวดที่เงินต้องเคลื่อน แต่รายการนี้ยังไม่มีบรรทัดเงินสด (อ่านจากตารางกฎ + บรรทัดที่บันทึก)
              const accrued = net === null && !!found && movesCash(found.sub);
              const status = reversal ? "off" : accrued ? "late" : "saved";
              const statusLabel = reversal ? "กลับรายการ" : accrued ? "ค้างรับ/ค้างจ่าย" : "บันทึกแล้ว";
              return (
                <tr
                  key={e.id}
                  onClick={() => setOpenId(e.id)}
                  className={cn("cursor-pointer border-l-[3px] hover:bg-brand-50", i % 2 ? "bg-canvas" : "bg-surface")}
                  style={owner?.color ? { borderLeftColor: owner.color } : undefined}
                >
                  <Td className="whitespace-nowrap">{isoToDmy(e.docDate)}</Td>
                  <Td className="whitespace-nowrap text-ink-600">{e.cashDate ? isoToDmy(e.cashDate) : "—"}</Td>
                  <Td className="whitespace-nowrap">
                    {found ? <Pill className={TYPE_PILL[found.type.tone]}>{found.type.label}</Pill> : "—"}
                  </Td>
                  <Td className="whitespace-nowrap text-ink-600">{found?.sub.label ?? e.subCode}</Td>
                  <Td className="whitespace-nowrap">{e.memo ?? "—"}</Td>
                  <Td className="whitespace-nowrap text-ink-600">{asset?.name ?? "—"}</Td>
                  <Td className="whitespace-nowrap">
                    <span className="inline-flex items-center gap-1.5">
                      <span className="h-2.5 w-2.5 rounded-pill bg-holder-group" style={owner?.color ? { background: owner.color } : undefined} />
                      {owner?.name ?? "ผู้ถือที่ไม่รู้จัก"}
                    </span>
                  </Td>
                  <Td align="right" className="whitespace-nowrap font-semibold text-pos">
                    {net !== null && net > 0 ? signedMoney(net) : "–"}
                  </Td>
                  <Td align="right" className="whitespace-nowrap font-semibold text-neg">
                    {net !== null && net < 0 ? money(net) : "–"}
                  </Td>
                  <Td className="whitespace-nowrap">
                    <Pill className={STATUS_PILL[status]}>{statusLabel}</Pill>
                  </Td>
                  <Td align="center" className="text-ink-600">{e.attachments.length ? `📎 ${e.attachments.length}` : "—"}</Td>
                </tr>
              );
            })}
            {rows.length ? (
              <tr className="bg-canvas font-semibold">
                <Td colSpan={7} className="border-t border-line">รวม {rows.length} รายการ</Td>
                <Td align="right" className="border-t border-line text-pos">{signedMoney(totalIn)}</Td>
                <Td align="right" className="border-t border-line text-neg">{money(-totalOut)}</Td>
                <Td colSpan={2} className="border-t border-line" />
              </tr>
            ) : null}
          </tbody>
        </Table>
      </TableShell>
      <div className="text-sm text-ink-400">คลิกแถวเพื่อดูบรรทัดบัญชีที่ระบบบันทึกจริง</div>

      <EntryDrawer entry={openEntry} onClose={() => setOpenId(null)} />
    </div>
  );
}

function PLTab() {
  const s = PL_SERIES;
  const sum = (...arrs: number[][]) => arrs[0].map((_, i) => arrs.reduce((a, x) => a + x[i], 0));

  const rows: { name: string; vals: number[]; kind?: "expense" | "sum" }[] = [
    { name: "รายได้ค่าเช่า", vals: s.rent },
    { name: "ดอกเบี้ยรับ", vals: s.interest },
    { name: "เงินปันผล", vals: s.dividend },
    { name: "กำไรจากการขายทรัพย์", vals: s.gain },
    { name: "รวมรายได้", vals: sum(s.rent, s.interest, s.dividend, s.gain), kind: "sum" },
    { name: "ค่าบริหารจัดการ", vals: s.admin, kind: "expense" },
    { name: "ซ่อมบำรุง", vals: s.repair, kind: "expense" },
    { name: "ดอกเบี้ยจ่าย", vals: s.interestExp, kind: "expense" },
    { name: "ภาษี & ค่าธรรมเนียม", vals: s.tax, kind: "expense" },
    { name: "รวมค่าใช้จ่าย", vals: sum(s.admin, s.repair, s.interestExp, s.tax), kind: "expense" },
    { name: "กำไรสุทธิ", vals: sum(s.rent, s.interest, s.dividend, s.gain, s.admin, s.repair, s.interestExp, s.tax), kind: "sum" },
  ];

  return (
    <TableShell>
      <Table minWidth={1240}>
        <thead>
          <tr>
            <Th className="sticky left-0 bg-canvas">หมวด</Th>
            {MONTHS.map((m) => (
              <Th key={m} align="right" className="whitespace-nowrap p-[12px_8px]">
                {m.replace(".", "")}
              </Th>
            ))}
            <Th align="right" className="text-ink-900">รวม</Th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => {
            const total = r.vals.reduce((a, b) => a + b, 0);
            const bold = r.kind === "sum";
            const tone = r.kind === "expense" ? "text-neg" : "text-ink-900";
            return (
              <tr key={r.name} className={bold ? "bg-canvas" : "bg-surface"}>
                <Td className={cn("whitespace-nowrap p-[11px_10px]", bold && "font-semibold")}>{r.name}</Td>
                {r.vals.map((v, i) => (
                  <Td key={i} align="right" className={cn("whitespace-nowrap p-[11px_8px]", tone, bold && "font-semibold")}>
                    {plMoney(v)}
                  </Td>
                ))}
                <Td align="right" className={cn("whitespace-nowrap p-[11px_10px] font-semibold", tone)}>
                  {plMoney(total)}
                </Td>
              </tr>
            );
          })}
        </tbody>
      </Table>
    </TableShell>
  );
}

function CFTab() {
  return (
    <div className="flex flex-col gap-4">
      {CF_GROUPS.map((g) => (
        <div key={g.name} className="rounded-card border border-line bg-surface p-[18px_20px] shadow-card">
          <div className="mb-2 flex items-baseline justify-between gap-3">
            <div className="text-h2 font-semibold">{g.name}</div>
            <div className={cn("text-h2 font-semibold", g.total < 0 ? "text-neg" : "text-pos")}>{signedMoney(g.total)}</div>
          </div>
          {g.items.map((i) => (
            <div key={i.name} className="flex justify-between gap-3 border-t border-line py-2.5 text-base">
              <span>{i.name}</span>
              <span className={cn("font-semibold", i.amount < 0 ? "text-neg" : "text-pos")}>{signedMoney(i.amount)}</span>
            </div>
          ))}
        </div>
      ))}

      <TableShell>
        <Table minWidth={720}>
          <thead>
            <tr>
              <Th>บัญชีธนาคาร</Th>
              <Th align="right">ยอดต้นงวด</Th>
              <Th align="right">เข้า</Th>
              <Th align="right">ออก</Th>
              <Th align="right">ยอดปลายงวด</Th>
            </tr>
          </thead>
          <tbody>
            {CF_ACCOUNTS.map((a) => (
              <tr key={a.name}>
                <Td>{a.name}</Td>
                <Td align="right">{money(a.open)}</Td>
                <Td align="right" className="font-semibold text-pos">{signedMoney(a.in)}</Td>
                <Td align="right" className="font-semibold text-neg">{money(a.out)}</Td>
                <Td align="right" className="font-semibold">{money(a.close)}</Td>
              </tr>
            ))}
          </tbody>
        </Table>
      </TableShell>
    </div>
  );
}
