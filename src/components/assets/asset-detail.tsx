"use client";

import * as React from "react";
import { cn } from "@/lib/utils";
import { Card, CardBody, CardLabel, CardTitle } from "@/components/ui/card";
import { Pill } from "@/components/ui/pill";
import { Button } from "@/components/ui/button";
import { Field } from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { TableShell, Table, Th, Td } from "@/components/ui/table";
import { MONTHS } from "@/lib/mock/entities";
import { ContactPicker } from "@/components/form/contact-picker";

const TABS = [
  { key: "overview", label: "ภาพรวม" },
  { key: "contract", label: "ข้อมูลสัญญา" },
  { key: "money", label: "รายการเงิน" },
  { key: "docs", label: "เอกสาร" },
] as const;

const BARS = [12, 12, 12, 12, 0, 12, 12, 12, 12, 12, 12, 12];

const ASSET_LEDGER = [
  { date: "01/09/2026", detail: "ค่าเช่า ก.ย.", in: "+12,000.00", out: "–", status: "รับแล้ว" },
  { date: "05/09/2026", detail: "ค่าส่วนกลาง Q3", in: "–", out: "(9,800.00)", status: "จ่ายแล้ว" },
  { date: "01/08/2026", detail: "ค่าเช่า ส.ค.", in: "+12,000.00", out: "–", status: "รับแล้ว" },
  { date: "12/07/2026", detail: "ค่าซ่อมเครื่องทำน้ำอุ่น", in: "–", out: "(3,200.00)", status: "จ่ายแล้ว" },
  { date: "01/07/2026", detail: "ค่าเช่า ก.ค.", in: "+12,000.00", out: "–", status: "รับแล้ว" },
];

const DOCS = [
  { kind: "PDF", name: "lease-condoC.pdf", meta: "สัญญาเช่า · 1.2 MB" },
  { kind: "PDF", name: "title-deed.pdf", meta: "โฉนด · 820 KB" },
  { kind: "รูป", name: "room-photo-01.jpg", meta: "สภาพห้อง 08/2026" },
  { kind: "PDF", name: "insurance-2026.pdf", meta: "ประกันอัคคีภัย" },
];

export function AssetDetail({ name }: { name: string }) {
  const [tab, setTab] = React.useState<(typeof TABS)[number]["key"]>("overview");
  const [editMode, setEditMode] = React.useState(false);
  const [tenantId, setTenantId] = React.useState("c1");

  return (
    <div className="flex flex-col gap-4">
      {editMode ? (
        <div className="rounded border border-warn bg-warn-bg p-[14px_18px] text-base text-warn-fg">
          กำลังอยู่ในโหมดแก้ไข — การเปลี่ยนแปลงจะบันทึกเมื่อกดปุ่มบันทึก
        </div>
      ) : null}

      <div className="flex flex-wrap items-center gap-4 rounded-card border border-line bg-surface p-[18px_20px] shadow-card">
        <div>
          <div className="text-h1 font-semibold">{name}</div>
          <div className="mt-1.5 flex flex-wrap items-center gap-2.5">
            <Pill size="md" className="border-brand-100 bg-brand-50 text-brand-600">Real Estate · ปล่อยเช่า</Pill>
            <span className="inline-flex items-center gap-1.5 text-sm text-ink-600">
              <span className="h-2.5 w-2.5 rounded-pill bg-holder-person" />ธนากร
            </span>
            <Pill size="md" className="border-pos bg-pos-bg text-pos-fg">Active</Pill>
          </div>
        </div>
        <div className="ml-auto flex overflow-hidden rounded border border-line">
          <button
            onClick={() => setEditMode(false)}
            className={cn("min-h-control px-[18px] text-base font-semibold", editMode ? "bg-surface text-ink-600" : "bg-brand-600 text-white")}
          >
            โหมดดู
          </button>
          <button
            onClick={() => setEditMode(true)}
            className={cn("min-h-control px-[18px] text-base font-semibold", editMode ? "bg-warn text-[#3d2600]" : "bg-surface text-ink-600")}
          >
            แก้ไข
          </button>
        </div>
      </div>

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

      {tab === "overview" ? (
        <div className="flex flex-col gap-4">
          <div className="grid gap-4 [grid-template-columns:repeat(auto-fit,minmax(220px,1fr))]">
            <Card>
              <CardBody>
                <CardLabel>ต้นทุน</CardLabel>
                <div className="text-h1 font-semibold">฿ 2,450,000</div>
              </CardBody>
            </Card>
            <Card>
              <CardBody>
                <CardLabel>มูลค่าปัจจุบัน</CardLabel>
                <div className="text-h1 font-semibold">฿ 2,780,000</div>
                <div className="text-sm font-semibold text-pos">▲ กำไรยังไม่รับรู้ 330,000</div>
              </CardBody>
            </Card>
            <Card>
              <CardBody>
                <CardLabel>Yield จริง</CardLabel>
                <div className="flex items-baseline gap-2">
                  <div className="text-h1 font-semibold text-warn">5.2%</div>
                  <div className="text-sm text-ink-600">เป้า 6.5%</div>
                </div>
                <div className="mt-2 h-2.5 overflow-hidden rounded-pill bg-line">
                  <div className="h-full bg-warn" style={{ width: "80%" }} />
                </div>
              </CardBody>
            </Card>
            <Card>
              <CardBody>
                <CardLabel>รายรับ 12 เดือน</CardLabel>
                <div className="text-h1 font-semibold">฿ 144,000</div>
              </CardBody>
            </Card>
          </div>

          <Card>
            <CardBody>
              <CardTitle className="mb-3">รายรับรายเดือน</CardTitle>
              <div className="flex h-40 items-end gap-2.5">
                {BARS.map((v, i) => (
                  <div key={i} className="flex min-w-0 flex-1 flex-col items-center gap-1.5">
                    <div
                      className={cn("w-full rounded-t-md", v ? "bg-brand-600" : "bg-line")}
                      style={{ height: v ? `${Math.round((v / 12) * 130)}px` : "4px" }}
                    />
                    <div className="text-sm text-ink-400">{MONTHS[i].replace(".", "")}</div>
                  </div>
                ))}
              </div>
              <div className="mt-2 text-sm text-ink-400">เดือน พ.ค. ไม่มีรายรับ — ห้องว่างระหว่างเปลี่ยนผู้เช่า</div>
            </CardBody>
          </Card>

          <Card>
            <CardBody className="flex flex-wrap items-center gap-4">
              <div>
                <CardLabel>ผู้เช่าปัจจุบัน</CardLabel>
                <div className="text-h2 font-semibold">คุณสมชาย ใจดี</div>
                <CardLabel>฿ 12,000 / เดือน · ชำระทุกวันที่ 1 · สัญญาหมด 29/09/2026</CardLabel>
              </div>
              <Button variant="quiet" className="ml-auto">ดูข้อมูลผู้เช่า</Button>
            </CardBody>
          </Card>
        </div>
      ) : null}

      {tab === "contract" ? (
        <div className="grid items-start gap-4 xl:[grid-template-columns:minmax(0,1fr)_300px]">
          <div className="grid gap-4 rounded-card border border-line bg-surface p-5 shadow-card [grid-template-columns:repeat(auto-fit,minmax(240px,1fr))]">
            {/* ผู้เช่าผูกกับ contact — สร้างใหม่ได้จากตรงนี้เหมือนในฟอร์มบันทึกรายการ */}
            <ContactPicker value={tenantId} onSelect={setTenantId} label="คู่สัญญา (ผู้เช่า)" layer={1} suggestKind="tenant" />
            <Field label="ค่าเช่า / เดือน">
              <Input defaultValue="12,000.00" readOnly={!editMode} />
            </Field>
            <Field label="วันเริ่มสัญญา">
              <Input defaultValue="30/09/2025" readOnly={!editMode} />
            </Field>
            <Field label="วันสิ้นสุดสัญญา">
              <Input defaultValue="29/09/2026" readOnly={!editMode} />
            </Field>
            <Field label="วันชำระทุกเดือน">
              <Input defaultValue="วันที่ 1" readOnly={!editMode} />
            </Field>
            <Field label="เงินมัดจำ">
              <Input defaultValue="24,000.00" readOnly={!editMode} />
            </Field>
            <Field label="ช่วงส่ง Notice ต่อสัญญา" error="ยังไม่ได้กรอก">
              <Input placeholder="ยังไม่ได้กรอก" className="border-neg" readOnly={!editMode} />
            </Field>
            <Field label="ผู้ค้ำประกัน" error="ยังไม่ได้กรอก">
              <Input placeholder="ยังไม่ได้กรอก" className="border-neg" readOnly={!editMode} />
            </Field>
          </div>
          <div className="flex flex-col gap-4">
            <Card>
              <CardBody>
                <Pill size="md" className="border-warn bg-warn-bg text-warn-fg">ขาด 2 ช่อง</Pill>
                <div className="mt-2 text-sm text-ink-600">ระบบนี้เก็บข้อมูลสัญญา ไม่ใช่เครื่องมือร่างสัญญา</div>
              </CardBody>
            </Card>
            <Card>
              <CardBody>
                <div className="mb-2 text-base font-semibold">ไฟล์สัญญา (บังคับ)</div>
                <div className="flex items-center gap-3 rounded border border-line p-3">
                  <div className="flex h-16 w-[52px] items-center justify-center rounded-md border border-line bg-canvas text-sm text-ink-400">PDF</div>
                  <div className="min-w-0 flex-1">
                    <div className="text-base font-semibold">lease-condoC.pdf</div>
                    <div className="text-sm text-ink-400">4 หน้า · 1.2 MB</div>
                  </div>
                </div>
              </CardBody>
            </Card>
          </div>
        </div>
      ) : null}

      {tab === "money" ? (
        <TableShell>
          <Table minWidth={720}>
            <thead>
              <tr>
                <Th className="p-[12px_14px]">วันที่</Th>
                <Th className="p-[12px_14px]">รายละเอียด</Th>
                <Th align="right" className="p-[12px_14px]">เงินเข้า</Th>
                <Th align="right" className="p-[12px_14px]">เงินออก</Th>
                <Th className="p-[12px_14px]">สถานะ</Th>
              </tr>
            </thead>
            <tbody>
              {ASSET_LEDGER.map((r) => (
                <tr key={r.date + r.detail}>
                  <Td className="whitespace-nowrap p-[12px_14px]">{r.date}</Td>
                  <Td className="p-[12px_14px]">{r.detail}</Td>
                  <Td align="right" className="p-[12px_14px] font-semibold text-pos">{r.in}</Td>
                  <Td align="right" className="p-[12px_14px] font-semibold text-neg">{r.out}</Td>
                  <Td className="p-[12px_14px]">{r.status}</Td>
                </tr>
              ))}
            </tbody>
          </Table>
        </TableShell>
      ) : null}

      {tab === "docs" ? (
        <div className="grid gap-4 rounded-card border border-line bg-surface p-5 shadow-card [grid-template-columns:repeat(auto-fill,minmax(200px,1fr))]">
          {DOCS.map((d) => (
            <div key={d.name} className="flex flex-col gap-2 rounded border border-line p-3.5">
              <div className="flex h-[120px] items-center justify-center rounded-lg border border-line bg-canvas text-base text-ink-400">{d.kind}</div>
              <div className="text-base font-semibold">{d.name}</div>
              <div className="text-sm text-ink-400">{d.meta}</div>
            </div>
          ))}
        </div>
      ) : null}
    </div>
  );
}
