"use client";

import * as React from "react";
import Link from "next/link";
import { Card, CardBody, CardLabel, CardTitle } from "@/components/ui/card";
import { TableShell, Table, Th, Td } from "@/components/ui/table";
import { usePermissions } from "@/components/auth/permissions-provider";
import { coaLabel } from "@/lib/rules/coa";
import { findSub } from "@/lib/rules/tx-rules";
import { HOLDING_NATURE_LABEL, VALUE_NOT_ACCOUNTING, iconKindFor, methodLabel, type AssetLedgerLine } from "@/lib/db/assets-model";
import type { DetailData } from "@/lib/db/assets-server";
import { isoToDmy, money } from "@/lib/format";
import { cn } from "@/lib/utils";
import { Button } from "./tall-button";
import { AssetKindIcon } from "./asset-kind-icon";
import { Money, NO_LEDGER_NOTE, Notice, OwnerDot, StatusChip, TagChips } from "./asset-parts";
import { sheetActions, type Perms } from "./asset-drafts";
import { EditAssetDialog } from "./propose-edit-dialog";
import { ValuationDialog } from "./valuation-dialog";
import { LINK_BUTTON_CLASS } from "./draft-parts";

const CONTRACT_TYPE: Record<string, string> = {
  lease: "สัญญาเช่า",
  sale_leaseback: "สัญญาขายฝาก",
  mortgage: "สัญญาจำนอง",
  loan_payable: "สัญญากู้ยืม (เราเป็นผู้กู้)",
  loan_receivable: "สัญญากู้ยืม (เราเป็นผู้ให้กู้)",
  service: "สัญญาบริการ",
};
const CONTRACT_STATUS: Record<string, string> = { draft: "ร่าง", active: "มีผลอยู่", closed: "ปิดแล้ว", defaulted: "ผิดนัด" };

/** แสดงรายการเงินล่าสุดไม่เกินเท่านี้ — ที่เหลือบอกจำนวนไว้ ไม่ตัดเงียบๆ */
const LEDGER_SHOWN = 300;

/**
 * รายงานรายทรัพย์ (D-112): ต้นทุนซื้อ · ค่าปรับปรุงสะสม · ค่าซ่อมสะสม · รายได้สะสม · มูลค่าล่าสุด
 *
 * ทุกตัวเลขของ "ต้นทุน" คำนวณใหม่จากสมุดตอนเปิดหน้า (ไม่มีช่องเก็บยอด) · **ต้นทุนเป็นของชิ้นนี้ชิ้นเดียว**
 * ไม่ถูกเฉลี่ยกับทรัพย์ชิ้นอื่น แม้อยู่ตึกเดียวกัน · มูลค่าล่าสุดแยกกรอบและบอกชัดว่าไม่ใช่ตัวเลขทางบัญชี
 */
export function AssetDetail({ data, contactNames }: { data: DetailData; contactNames: Record<string, string> }) {
  const perms: Perms = usePermissions();
  const { asset, report, latest } = data;
  const owner = data.owners.find((o) => o.id === asset.ownerId);
  const [dialog, setDialog] = React.useState<null | "value" | "edit" | "propose">(null);
  const actions = sheetActions(perms);

  return (
    <div className="flex flex-col gap-4 pb-24">
      <div>
        <Link href="/assets" className={cn(LINK_BUTTON_CLASS, "border-line bg-surface text-ink-900 hover:border-ink-400")}>
          กลับไปทะเบียนทรัพย์
        </Link>
      </div>

      <div className="flex flex-wrap items-start gap-4 rounded-card border border-line bg-surface p-[18px_20px] shadow-card">
        <AssetKindIcon kind={iconKindFor(asset)} size={64} muted={asset.status !== "active"} />
        <div className="min-w-0 flex-1">
          <div className="text-h1 font-semibold">{asset.name}</div>
          <div className="text-base text-ink-600">
            {asset.code} · {asset.className} › {asset.categoryName}
          </div>
          <div className="mt-2 flex flex-wrap items-center gap-3">
            <OwnerDot owner={owner} />
            <StatusChip status={asset.status} />
            {asset.holdingNature ? <span className="text-sm text-ink-600">{HOLDING_NATURE_LABEL[asset.holdingNature] ?? asset.holdingNature}</span> : null}
          </div>
          {asset.tags.length ? (
            <div className="mt-2 flex flex-wrap items-center gap-2">
              <span className="text-sm text-ink-600">ป้ายกำกับ:</span>
              <TagChips tags={asset.tags} />
            </div>
          ) : null}
        </div>
        {/* ปุ่มตามสิทธิ์ — ไม่โชว์ปุ่มที่กดแล้วถูกปฏิเสธ (ความสะดวก ไม่ใช่ความปลอดภัย · RLS คือของจริง) */}
        <div className="flex flex-wrap gap-2">
          {actions.map((a) => (
            <Button key={a.id} variant={a.id === "value" ? "secondary" : "primary"} onClick={() => setDialog(a.id)}>
              {a.label}
            </Button>
          ))}
        </div>
      </div>

      {data.pendingEditDrafts > 0 ? (
        <Notice tone="warn">มีร่างแก้ไขทรัพย์นี้รออนุมัติ {data.pendingEditDrafts} รายการ — ข้อมูลข้างล่างยังเป็นค่าเดิม</Notice>
      ) : null}
      {!data.ledgerAccess ? <Notice tone="info">{NO_LEDGER_NOTE}</Notice> : null}
      {data.unclassifiedLines > 0 ? (
        <Notice tone="warn">มี {data.unclassifiedLines} บรรทัดในสมุดที่ใช้รหัสบัญชีนอกผังบัญชี จึงไม่ถูกรวมในตัวเลขด้านล่าง — แจ้งผู้ดูแลระบบ</Notice>
      ) : null}

      <section aria-label="ตัวเลขตามสมุดบัญชี" className="flex flex-col gap-3">
        <h2 className="m-0 text-h2 font-semibold">ตัวเลขตามสมุดบัญชี</h2>
        <div className="grid gap-4 [grid-template-columns:repeat(auto-fit,minmax(220px,1fr))]">
          <Stat label="ต้นทุนซื้อ" value={report?.purchase} />
          <Stat label="ค่าปรับปรุงสะสม" sub="ค่ารีโนเวทที่บันทึกเป็นทุน" value={report?.renovation} />
          <Stat label="ค่าซ่อมสะสม" sub="เป็นค่าใช้จ่าย ไม่เพิ่มต้นทุน" value={report?.repair} />
          <Stat label="รายได้สะสม" sub="ไม่รวมกำไรจากการขาย" value={report?.income} />
        </div>
        <div className="grid gap-4 [grid-template-columns:repeat(auto-fit,minmax(220px,1fr))]">
          <Stat label="ต้นทุนรวมของชิ้นนี้" sub="ต้นทุนซื้อ + ค่าปรับปรุง · เป็นของชิ้นนี้ชิ้นเดียว ไม่ปนกับชิ้นอื่น" value={report?.costTotal} strong />
          <Stat label="ค่าใช้จ่ายอื่นสะสม" sub="ค่าส่วนกลาง ค่าน้ำไฟ ภาษี ฯลฯ" value={report?.otherExpense} />
          {report && report.saleResult !== 0 ? <Stat label="กำไร (ขาดทุน) จากการขาย" value={report.saleResult} /> : null}
        </div>
        <div className="text-sm text-ink-600">คำนวณใหม่จากสมุดบัญชีทุกครั้งที่เปิดหน้านี้ ไม่มีตัวเลขที่เก็บไว้</div>
      </section>

      {/* มูลค่าประเมิน — กรอบแยก ไม่ปนกับตัวเลขบัญชี (D-112) */}
      <section aria-label="มูลค่าประเมินล่าสุด" className="flex flex-col gap-3 rounded-card border-2 border-dashed border-warn bg-canvas p-[16px_20px]" data-testid="valuation-box">
        <h2 className="m-0 text-h2 font-semibold">มูลค่าล่าสุด (ราคาประเมิน)</h2>
        <Notice tone="info">{VALUE_NOT_ACCOUNTING}</Notice>
        {latest && latest.value !== null ? (
          <div>
            <div className="text-h1 font-semibold tabular-nums">{money(latest.value, { dash: false })}</div>
            <div className="text-base text-ink-600">
              ณ วันที่ {isoToDmy(latest.asOf)} · ที่มา: {methodLabel(latest.method)}
              {latest.isStale ? " · ราคานี้เก่าเกิน 7 วันแล้ว" : ""}
            </div>
            {report ? (
              <div className="text-sm text-ink-600">
                ส่วนต่างจากต้นทุนรวม <span className="tabular-nums">{money(Math.round((latest.value - report.costTotal) * 100) / 100, { dash: false })}</span> บาท
                — เป็นผลต่างของราคาประเมินกับต้นทุน ไม่ใช่กำไรทางบัญชี
              </div>
            ) : null}
          </div>
        ) : (
          <div className="text-base text-ink-600">ยังไม่เคยตีราคาทรัพย์นี้ (หรือคุณไม่มีสิทธิ์เห็นราคาประเมิน)</div>
        )}
        {data.valuations.length > 0 ? (
          <TableShell>
            <Table minWidth={560}>
              <thead>
                <tr>
                  <Th>วันที่ประเมิน</Th>
                  <Th>ที่มา</Th>
                  <Th align="right">มูลค่า (บาท)</Th>
                  <Th>หมายเหตุ</Th>
                </tr>
              </thead>
              <tbody>
                {data.valuations.map((v) => (
                  <tr key={v.id} className="bg-surface">
                    <Td className="whitespace-nowrap tabular-nums">{isoToDmy(v.asOf)}</Td>
                    <Td>{methodLabel(v.method)}</Td>
                    <Td align="right"><Money value={v.value} /></Td>
                    <Td>{v.note ?? ""}</Td>
                  </tr>
                ))}
              </tbody>
            </Table>
          </TableShell>
        ) : null}
      </section>

      <Card>
        <CardBody>
          <CardTitle className="mb-3">ข้อมูลทะเบียน</CardTitle>
          <Rows
            items={[
              ["ที่ตั้ง", asset.location],
              ["ชนิดทรัพย์", asset.propertyType],
              ["ขนาด", asset.sizeNote],
              ["สัดส่วนถือครอง", asset.ownershipPct === null ? null : `${(asset.ownershipPct * 100).toFixed(2)}%`],
              ["แหล่งเงินทุน", asset.fundingSource],
              ["วันได้มา", asset.acquiredDate ? isoToDmy(asset.acquiredDate) : null],
              ["วันจำหน่าย", asset.disposedDate ? isoToDmy(asset.disposedDate) : null],
              ["รหัสหลักทรัพย์", asset.ticker],
              ["สกุลเงิน", asset.currency !== "THB" ? asset.currency : null],
            ]}
          />
          <CardLabel>ช่องที่ว่างอาจเป็นเพราะยังไม่ได้กรอก หรือตำแหน่งของคุณไม่มีสิทธิ์เห็นช่องนั้น</CardLabel>
        </CardBody>
      </Card>

      {data.contracts.length > 0 ? (
        <Card>
          <CardBody>
            <CardTitle className="mb-3">สัญญาที่ผูกกับทรัพย์นี้</CardTitle>
            <div className="flex flex-col gap-3">
              {data.contracts.map((c) => (
                <div key={c.id} className="rounded-card border border-line bg-canvas p-[12px_14px]">
                  <div className="mb-1 text-base font-semibold">
                    {CONTRACT_TYPE[c.type] ?? c.type}
                    {c.code ? ` · ${c.code}` : ""} <span className="font-normal text-ink-600">({CONTRACT_STATUS[c.status] ?? c.status})</span>
                  </div>
                  <Rows
                    items={[
                      ["คู่สัญญา", c.counterpartyContactId ? (contactNames[c.counterpartyContactId] ?? "ไม่ทราบชื่อ") : null],
                      ["เงินต้น", c.principal === null ? null : money(c.principal, { dash: false })],
                      ["อัตรา", c.rate === null ? null : `${c.rate}${c.ratePeriod ? ` ต่อ${{ year: "ปี", month: "เดือน", day: "วัน" }[c.ratePeriod] ?? c.ratePeriod}` : ""}`],
                      ["เริ่ม – สิ้นสุด", c.startDate ? `${isoToDmy(c.startDate)} – ${c.endDate ? isoToDmy(c.endDate) : "—"}` : null],
                      ["ช่วงส่ง Notice", c.noticeWindowStart ? `${isoToDmy(c.noticeWindowStart)} – ${c.noticeWindowEnd ? isoToDmy(c.noticeWindowEnd) : "—"}` : null],
                      ["กำหนดไถ่ถอน", c.redemptionDeadline ? isoToDmy(c.redemptionDeadline) : null],
                    ]}
                  />
                </div>
              ))}
            </div>
          </CardBody>
        </Card>
      ) : null}

      <LedgerTable lines={data.lines} ledgerAccess={data.ledgerAccess} />

      {dialog === "value" ? <ValuationDialog asset={asset} onClose={() => setDialog(null)} /> : null}
      {dialog === "edit" ? <EditAssetDialog asset={asset} mode="direct" onClose={() => setDialog(null)} /> : null}
      {dialog === "propose" ? <EditAssetDialog asset={asset} mode="propose" onClose={() => setDialog(null)} /> : null}
    </div>
  );
}

function Stat({ label, value, sub, strong }: { label: string; value: number | null | undefined; sub?: string; strong?: boolean }) {
  return (
    <Card>
      <CardBody>
        <CardLabel>{label}</CardLabel>
        <div className={cn("font-semibold", strong ? "text-h1" : "text-h2")}>
          <Money value={value} className={value === null || value === undefined ? undefined : "tabular-nums"} />
        </div>
        {sub ? <div className="text-sm text-ink-600">{sub}</div> : null}
      </CardBody>
    </Card>
  );
}

/** แสดงเฉพาะช่องที่มีค่า — ช่องว่างเปล่าเต็มหน้าทำให้หาของที่มีจริงยากขึ้น */
function Rows({ items }: { items: [string, React.ReactNode | null | undefined][] }) {
  const shown = items.filter(([, v]) => v !== undefined && v !== null && v !== "");
  if (shown.length === 0) return <div className="text-base text-ink-600">ยังไม่ได้กรอก</div>;
  return (
    <dl className="m-0 grid grid-cols-[auto_1fr] gap-x-5 gap-y-2 text-base">
      {shown.map(([k, v]) => (
        <React.Fragment key={k}>
          <dt className="whitespace-nowrap text-ink-600">{k}</dt>
          <dd className="m-0 min-w-0 break-words">{v}</dd>
        </React.Fragment>
      ))}
    </dl>
  );
}

function LedgerTable({ lines, ledgerAccess }: { lines: AssetLedgerLine[]; ledgerAccess: boolean }) {
  if (!ledgerAccess) return null;
  const sorted = [...lines].sort((a, b) => (a.docDate < b.docDate ? 1 : a.docDate > b.docDate ? -1 : a.lineId < b.lineId ? 1 : -1));
  const shown = sorted.slice(0, LEDGER_SHOWN);
  return (
    <section aria-label="รายการเงินของทรัพย์" className="flex flex-col gap-2">
      <h2 className="m-0 text-h2 font-semibold">รายการในสมุดบัญชีที่ผูกกับทรัพย์นี้</h2>
      {lines.length === 0 ? (
        <div className="rounded-card border border-line bg-surface p-5 text-base text-ink-600 shadow-card">
          ยังไม่มีรายการในสมุดที่ผูกกับทรัพย์นี้ — ต้นทุน รายได้ และค่าใช้จ่ายจะเกิดเมื่อลงรายการในหน้าบันทึกรายการแล้วเลือกทรัพย์ชิ้นนี้
        </div>
      ) : (
        <TableShell>
          <Table minWidth={760}>
            <thead>
              <tr>
                <Th>วันที่</Th>
                <Th>รายการ</Th>
                <Th>บัญชี</Th>
                <Th align="right">เดบิต</Th>
                <Th align="right">เครดิต</Th>
              </tr>
            </thead>
            <tbody>
              {shown.map((l) => (
                <tr key={l.lineId} className="bg-surface">
                  <Td className="whitespace-nowrap tabular-nums">{isoToDmy(l.docDate)}</Td>
                  <Td>
                    {findSub(l.subCode)?.sub.label ?? l.subCode}
                    {l.source === "reverse" ? <span className="text-sm text-ink-600"> · กลับรายการ</span> : null}
                  </Td>
                  <Td>{l.coaCode} {safeLabel(l.coaCode)}</Td>
                  <Td align="right" className="tabular-nums">{l.debit ? money(l.debit, { dash: false }) : ""}</Td>
                  <Td align="right" className="tabular-nums">{l.credit ? money(l.credit, { dash: false }) : ""}</Td>
                </tr>
              ))}
            </tbody>
          </Table>
        </TableShell>
      )}
      {lines.length > shown.length ? (
        <div className="text-sm text-ink-600">แสดงล่าสุด {shown.length} จาก {lines.length} บรรทัด — ตัวเลขด้านบนรวมครบทุกบรรทัด</div>
      ) : null}
    </section>
  );
}

function safeLabel(code: string): string {
  try {
    return coaLabel(code).replace(/^\d+\s*[·-]?\s*/, "");
  } catch {
    return "(ไม่อยู่ในผังบัญชี)";
  }
}

