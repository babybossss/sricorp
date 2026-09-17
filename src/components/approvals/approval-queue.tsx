"use client";

import * as React from "react";
import { APPROVALS } from "@/lib/mock/ledger";
import { getTxType, findSub } from "@/lib/rules/tx-rules";
import { entityById } from "@/lib/mock/entities";
import { money, signedMoney } from "@/lib/format";
import { TableShell, Table, Th, Td } from "@/components/ui/table";
import { Pill } from "@/components/ui/pill";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import { Field } from "@/components/ui/field";
import { Dialog, DialogContent, DialogFooter } from "@/components/ui/dialog";
import { DialogPrimitive } from "@/components/ui/dialog";
import { TYPE_PILL } from "@/lib/tone";
import { useApp } from "@/lib/store";
import { cn } from "@/lib/utils";

type Confirm = { title: string; body: string; cta: string; danger?: boolean; needReason?: boolean; onConfirm: () => void };

export function ApprovalQueue() {
  const showToast = useApp((s) => s.showToast);
  const [sel, setSel] = React.useState<Record<string, boolean>>({});
  const [dialog, setDialog] = React.useState<Confirm | null>(null);

  const selected = APPROVALS.filter((a) => sel[a.id]);
  const selSum = selected.reduce((t, a) => t + Math.abs(a.amount), 0);
  const allSum = APPROVALS.reduce((t, a) => t + Math.abs(a.amount), 0);

  const ask = (c: Confirm) => setDialog(c);

  return (
    <div className="flex flex-col gap-4 pb-24">
      <div className="flex flex-wrap items-center gap-4 rounded-card border border-line bg-surface p-[18px_20px] shadow-card">
        <div>
          <div className="text-h1 font-semibold">รออนุมัติ {APPROVALS.length} รายการ</div>
          <div className="text-base text-ink-600">รวม ฿ {allSum.toLocaleString("en-US")} · เก่าสุดรอมา 6 วัน</div>
        </div>
        <div className="ml-auto flex flex-wrap gap-2.5">
          <Button variant="secondary" onClick={() => setSel(Object.fromEntries(APPROVALS.map((a) => [a.id, true])))}>
            เลือกทั้งหมด
          </Button>
          <Button
            onClick={() =>
              ask({
                title: "ยืนยันอนุมัติทั้งหมด",
                body: `ยืนยันอนุมัติ ${APPROVALS.length} รายการ รวม ฿ ${allSum.toLocaleString("en-US")} เข้าสมุดบัญชีใช่หรือไม่`,
                cta: "ยืนยันอนุมัติ",
                onConfirm: () => {
                  setSel({});
                  showToast(`อนุมัติแล้ว ${APPROVALS.length} รายการ`);
                },
              })
            }
          >
            อนุมัติทั้งหมด
          </Button>
        </div>
      </div>

      <TableShell>
        <Table minWidth={1180}>
          <thead>
            <tr>
              <Th className="w-14" />
              <Th>ประเภท</Th>
              <Th>หมวดย่อย</Th>
              <Th>รายละเอียด</Th>
              <Th>ถือในชื่อ</Th>
              <Th align="right">ยอด</Th>
              <Th>ผู้สร้าง</Th>
              <Th>วันที่</Th>
              <Th align="right">การดำเนินการ</Th>
            </tr>
          </thead>
          <tbody>
            {APPROVALS.map((a) => {
              const type = getTxType(a.typeKey);
              const sub = findSub(a.subCode)?.sub;
              const holder = entityById(a.ownerId);
              return (
                <tr key={a.id} className={cn(sel[a.id] ? "bg-brand-50" : "bg-surface")}>
                  <Td className="p-[12px_14px]">
                    <Checkbox checked={!!sel[a.id]} onChange={() => setSel((s) => ({ ...s, [a.id]: !s[a.id] }))} />
                  </Td>
                  <Td className="whitespace-nowrap">
                    <Pill className={TYPE_PILL[type.tone]}>{type.label}</Pill>
                  </Td>
                  <Td className="whitespace-nowrap text-ink-600">{sub?.label ?? "—"}</Td>
                  <Td>
                    <div className="font-semibold">{a.detail}</div>
                    <div className="text-sm text-ink-400">{a.source}</div>
                  </Td>
                  <Td className="whitespace-nowrap">
                    <span className="inline-flex items-center gap-1.5">
                      <span className="h-2.5 w-2.5 rounded-pill" style={{ background: holder.color }} />
                      {holder.name}
                    </span>
                  </Td>
                  <Td align="right" className="whitespace-nowrap">
                    <b className={a.amount < 0 ? "text-neg" : "text-pos"}>{a.amount < 0 ? money(a.amount) : signedMoney(a.amount)}</b>
                  </Td>
                  <Td className="whitespace-nowrap text-ink-600">{a.by}</Td>
                  <Td className="whitespace-nowrap text-ink-600">{a.date}</Td>
                  <Td className="p-[12px_14px]">
                    <div className="flex justify-end gap-2">
                      <Button
                        variant="danger"
                        size="sm"
                        onClick={() =>
                          ask({
                            title: "ไม่อนุมัติรายการนี้",
                            body: `รายการ "${a.detail}" จะถูกส่งกลับให้ ${a.by} แก้ไข`,
                            cta: "ยืนยันไม่อนุมัติ",
                            danger: true,
                            needReason: true,
                            onConfirm: () => showToast("ส่งกลับให้แก้ไขแล้ว"),
                          })
                        }
                      >
                        ไม่อนุมัติ
                      </Button>
                      <Button
                        size="sm"
                        onClick={() =>
                          ask({
                            title: "ยืนยันอนุมัติรายการนี้",
                            body: `ยืนยันอนุมัติ "${a.detail}" ยอด ฿ ${Math.abs(a.amount).toLocaleString("en-US")} เข้าสมุดบัญชีใช่หรือไม่`,
                            cta: "ยืนยันอนุมัติ",
                            onConfirm: () => showToast("อนุมัติแล้ว 1 รายการ"),
                          })
                        }
                      >
                        อนุมัติ
                      </Button>
                    </div>
                  </Td>
                </tr>
              );
            })}
          </tbody>
        </Table>
      </TableShell>

      <div className="rounded-card border border-brand-100 bg-brand-50 p-[14px_18px] text-base leading-7">
        มุมมองของ User/Manager: รายการที่สร้างจะแสดงสถานะ <b>&ldquo;รอ Management อนุมัติ&rdquo;</b> จนกว่าจะมีการอนุมัติ
      </div>

      {selected.length ? (
        <div className="fixed bottom-6 left-[280px] right-6 z-40 flex flex-wrap items-center gap-4 rounded-card bg-ink-900 p-[14px_20px] text-white shadow-bar">
          <div className="text-base font-semibold">
            เลือก {selected.length} รายการ ฿ {selSum.toLocaleString("en-US")}
          </div>
          <div className="ml-auto flex gap-2.5">
            <Button
              variant="ghost"
              className="border border-white/40 text-white hover:bg-white/10"
              onClick={() =>
                ask({
                  title: "ไม่อนุมัติรายการที่เลือก",
                  body: `${selected.length} รายการจะถูกส่งกลับให้ผู้สร้างแก้ไข`,
                  cta: "ยืนยันไม่อนุมัติ",
                  danger: true,
                  needReason: true,
                  onConfirm: () => {
                    setSel({});
                    showToast("ส่งกลับให้แก้ไขแล้ว");
                  },
                })
              }
            >
              ไม่อนุมัติ
            </Button>
            <Button
              variant="secondary"
              className="border-white bg-white text-brand-600"
              onClick={() =>
                ask({
                  title: "ยืนยันอนุมัติรายการที่เลือก",
                  body: `ยืนยันอนุมัติ ${selected.length} รายการ รวม ฿ ${selSum.toLocaleString("en-US")} เข้าสมุดบัญชีใช่หรือไม่`,
                  cta: "ยืนยันอนุมัติ",
                  onConfirm: () => {
                    const n = selected.length;
                    setSel({});
                    showToast(`อนุมัติแล้ว ${n} รายการ`);
                  },
                })
              }
            >
              อนุมัติที่เลือก
            </Button>
          </div>
        </div>
      ) : null}

      <Dialog open={!!dialog} onOpenChange={(v) => !v && setDialog(null)}>
        {dialog ? (
          <DialogContent width="max-w-[520px]">
            <div className="flex flex-col gap-4 p-6">
              <DialogPrimitive.Title className="text-h2 font-semibold">{dialog.title}</DialogPrimitive.Title>
              <DialogPrimitive.Description className="text-base leading-7 text-ink-600">{dialog.body}</DialogPrimitive.Description>
              {dialog.needReason ? (
                <Field label="เหตุผลที่ไม่อนุมัติ (จำเป็น)">
                  <Input placeholder="เช่น ยอดไม่ตรงกับใบแจ้งหนี้" />
                </Field>
              ) : null}
            </div>
            <DialogFooter className="border-t-0">
              <Button variant="secondary" onClick={() => setDialog(null)}>ยกเลิก</Button>
              <Button
                variant={dialog.danger ? "danger" : "primary"}
                className={dialog.danger ? "border-neg bg-neg text-white hover:brightness-95" : undefined}
                onClick={() => {
                  dialog.onConfirm();
                  setDialog(null);
                }}
              >
                {dialog.cta}
              </Button>
            </DialogFooter>
          </DialogContent>
        ) : null}
      </Dialog>
    </div>
  );
}
