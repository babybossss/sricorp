"use client";

import * as React from "react";
import Link from "next/link";
import type { AssetRef } from "@/lib/mock/assets";
import { Dialog, DialogContent, DialogFooter, DialogPrimitive } from "@/components/ui/dialog";
import { Button } from "./tall-button";
import { Field } from "@/components/ui/field";
import { Input } from "./fields";
import { cn } from "@/lib/utils";
import { AssetDenied, AssetInvalid, useAssetStore } from "./asset-store";
import { PATCH_FIELDS, norm, type Perms } from "./asset-drafts";
import { LINK_BUTTON_CLASS, NotCountedNotice, SheetHeader } from "./draft-parts";

/**
 * เสนอแก้ทรัพย์เป็นร่าง (kind='update') — สำหรับคนที่แก้ตรงไม่ได้ (Staff)
 *
 * ช่องที่ผู้ใช้**เคลียร์จนว่าง** (จากที่มีค่า) ส่งเป็น `null` = ลบค่าออก · ช่องที่ไม่ได้แตะไม่อยู่ใน patch
 * สองอย่างนี้ห้ามปนกัน — แผง diff ของผู้อนุมัติแยกมันด้วยกัน
 */
export function ProposeEditDialog({
  asset,
  perms,
  currentUser,
  onClose,
}: {
  asset: AssetRef;
  perms: Perms;
  currentUser: { id: string; name: string };
  onClose: () => void;
}) {
  const proposeUpdate = useAssetStore((s) => s.proposeUpdate);
  const initial = React.useMemo(
    () => Object.fromEntries(PATCH_FIELDS.map((f) => [f.key, String(norm(f.read(asset)) ?? "")])),
    [asset]
  );
  const [values, setValues] = React.useState<Record<string, string>>(initial);
  const [note, setNote] = React.useState("");
  const [error, setError] = React.useState<string | null>(null);
  const [sent, setSent] = React.useState(false);

  function submit() {
    const patch: Record<string, string | number | null> = {};
    for (const f of PATCH_FIELDS) {
      const raw = norm(values[f.key]);
      const before = norm(f.read(asset));
      let after: string | number | null = raw;
      if (raw !== null && f.key === "ownership_pct") {
        const n = Number(String(raw).replace(/,/g, ""));
        if (!Number.isFinite(n)) {
          setError(`${f.label} ต้องเป็นตัวเลข`);
          return;
        }
        after = n;
      }
      if (after !== before) patch[f.key] = after; // เคลียร์ช่อง = null (ลบค่า) · ไม่แตะ = ไม่ส่ง
    }
    try {
      proposeUpdate(asset.id, patch, { ...currentUser, permissions: perms }, note);
      setSent(true);
      setError(null);
    } catch (e) {
      if (e instanceof AssetInvalid) setError(e.errors.join(" · "));
      else if (e instanceof AssetDenied) setError(e.message);
      else throw e;
    }
  }

  return (
    <Dialog open onOpenChange={(o) => (o ? null : onClose())}>
      <DialogContent layer={1} aria-describedby={undefined}>
        <DialogPrimitive.Title className="sr-only">เสนอแก้ไขทรัพย์</DialogPrimitive.Title>
        <SheetHeader title={`เสนอแก้ไข ${asset.name}`} onClose={onClose} />
        <div className="flex max-h-[70vh] flex-col gap-4 overflow-auto p-[20px_24px]">
          {sent ? (
            <>
              <h3 className="m-0 text-h2 font-semibold">ส่งเป็นร่างแล้ว — ทะเบียนยังเป็นค่าเดิม</h3>
              <NotCountedNotice>ผู้อนุมัติจะเห็นว่าแต่ละช่องเปลี่ยนจากอะไรเป็นอะไร</NotCountedNotice>
            </>
          ) : (
            <>
              <p className="m-0 text-base text-ink-600">
                แก้เฉพาะช่องที่ต้องการ · ล้างช่องให้ว่างเท่ากับเสนอให้ <b>ลบค่าออก</b> · ของเดิมจะยังไม่เปลี่ยนจนกว่าจะมีคนอนุมัติ
              </p>
              {PATCH_FIELDS.map((f) => (
                <div key={f.key} className="flex flex-col gap-1.5">
                  <Field label={f.label}>
                    <Input
                      value={values[f.key] ?? ""}
                      onChange={(e) => setValues((v) => ({ ...v, [f.key]: e.target.value }))}
                      autoComplete="off"
                    />
                  </Field>
                  {/* hint เขียนเอง: Field hint ใช้ text-ink-400 ซึ่ง contrast 3.15:1 ไม่ผ่านเกณฑ์อ่านง่าย */}
                  {f.hint ? <span className="text-sm text-ink-600">{f.hint}</span> : null}
                </div>
              ))}
              <Field label="หมายเหตุถึงผู้อนุมัติ">
                <Input value={note} onChange={(e) => setNote(e.target.value)} autoComplete="off" />
              </Field>
              {error ? (
                <div role="alert" className="rounded border border-neg bg-neg-bg p-[12px_14px] text-base leading-7 text-neg-fg">
                  {error}
                </div>
              ) : null}
            </>
          )}
        </div>
        <DialogFooter>
          {sent ? (
            <>
              <Link href="/assets/drafts" className={cn(LINK_BUTTON_CLASS, "border-line bg-surface text-ink-900 hover:border-ink-400")}>
                ดูคิวร่าง
              </Link>
              <Button onClick={onClose}>ปิด</Button>
            </>
          ) : (
            <>
              <Button variant="secondary" onClick={onClose}>ยกเลิก</Button>
              <Button onClick={submit}>ส่งเป็นร่าง</Button>
            </>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
