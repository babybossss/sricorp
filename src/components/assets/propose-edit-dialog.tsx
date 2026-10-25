"use client";

import * as React from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Dialog, DialogContent, DialogFooter, DialogPrimitive } from "@/components/ui/dialog";
import { Field } from "@/components/ui/field";
import { cn } from "@/lib/utils";
import type { AssetView, DraftPatch } from "@/lib/db/assets-model";
import { editAssetDirect, proposeAssetEdit } from "@/app/assets/actions";
import { Button } from "./tall-button";
import { Input } from "./fields";
import { PATCH_FIELDS, computeDiff, norm } from "./asset-drafts";
import { LINK_BUTTON_CLASS, NotCountedNotice, SheetHeader } from "./draft-parts";
import { Notice, WillSave } from "./asset-parts";

/**
 * แก้ทะเบียนทรัพย์ — สองโหมด ตามสิทธิ์ (ปุ่มที่เรียกมาตัดสิน ไม่ใช่ dialog นี้):
 *   - `direct`  แก้ตรง (asset.manage) → UPDATE assets · RLS `assets_update` เป็นด่าน
 *   - `propose` เสนอเป็นร่าง (คนที่แก้ตรงไม่ได้) → ร่างชนิด update รอผู้อนุมัติ
 *
 * ช่องที่ผู้ใช้**เคลียร์จนว่าง** (จากที่มีค่า) ส่งเป็น `null` = ลบค่าออก · ช่องที่ไม่ได้แตะไม่อยู่ใน patch
 * สองอย่างนี้ห้ามปนกัน — แผงเทียบของผู้อนุมัติแยกมันด้วยกัน
 * ก่อนกดยืนยันมีกล่อง "ระบบจะบันทึกให้ดังนี้" บอกว่าแต่ละช่องเปลี่ยนจากอะไรเป็นอะไร
 */
export function EditAssetDialog({
  asset,
  mode,
  onClose,
}: {
  asset: AssetView;
  mode: "direct" | "propose";
  onClose: () => void;
}) {
  const router = useRouter();
  const [pending, startTransition] = React.useTransition();
  const initial = React.useMemo(() => Object.fromEntries(PATCH_FIELDS.map((f) => [f.key, f.toInput(f.read(asset))])), [asset]);
  const [values, setValues] = React.useState<Record<string, string>>(initial);
  const [note, setNote] = React.useState("");
  const [error, setError] = React.useState<{ message: string; errors?: string[] } | null>(null);
  const [sent, setSent] = React.useState<string | null>(null);

  // อ่านค่าที่กรอก → patch (เฉพาะช่องที่เปลี่ยนจริง) + ข้อผิดพลาดรายช่อง
  const read = React.useMemo(() => {
    const patch: DraftPatch = {};
    const errs: Record<string, string> = {};
    for (const f of PATCH_FIELDS) {
      const r = f.parse(values[f.key] ?? "");
      if (!r.ok) {
        errs[f.key] = r.error;
        continue;
      }
      const before = norm(f.read(asset));
      const after = norm(r.value);
      if (JSON.stringify(before) === JSON.stringify(after)) continue; // ไม่ได้แตะ = ไม่ส่ง
      if (after === null && !f.clearable) {
        errs[f.key] = `${f.label} ลบค่าออกไม่ได้`;
        continue;
      }
      patch[f.key] = after; // เคลียร์ช่อง = null (ลบค่า)
    }
    return { patch, errs };
  }, [values, asset]);

  const diff = computeDiff({ kind: "update", patch: read.patch }, asset);
  const changed = diff.rows.filter((r) => r.change !== "unchanged");
  const blocked = Object.keys(read.errs).length > 0 || changed.length === 0;

  function submit() {
    setError(null);
    startTransition(async () => {
      const out =
        mode === "direct"
          ? await editAssetDirect({ assetId: asset.id, patch: read.patch })
          : await proposeAssetEdit({ assetId: asset.id, patch: read.patch, note });
      if (out.ok) {
        setSent(out.message);
        router.refresh();
      } else setError({ message: out.message, errors: out.errors });
    });
  }

  const title = mode === "direct" ? `แก้ไข ${asset.name}` : `เสนอแก้ไข ${asset.name}`;

  return (
    <Dialog open onOpenChange={(o) => (o ? null : onClose())}>
      <DialogContent layer={1} aria-describedby={undefined}>
        <DialogPrimitive.Title className="sr-only">{title}</DialogPrimitive.Title>
        <SheetHeader title={title} onClose={onClose} />
        <div className="flex max-h-[70vh] flex-col gap-4 overflow-auto p-[20px_24px]">
          {sent ? (
            mode === "direct" ? (
              <>
                <h3 className="m-0 text-h2 font-semibold">แก้ทะเบียนแล้ว</h3>
                <Notice tone="ok">{sent}</Notice>
              </>
            ) : (
              <>
                <h3 className="m-0 text-h2 font-semibold">ส่งเป็นร่างแล้ว — ทะเบียนยังเป็นค่าเดิม</h3>
                <NotCountedNotice>ผู้อนุมัติจะเห็นว่าแต่ละช่องเปลี่ยนจากอะไรเป็นอะไร</NotCountedNotice>
              </>
            )
          ) : (
            <>
              <p className="m-0 text-base text-ink-600">
                แก้เฉพาะช่องที่ต้องการ · ล้างช่องให้ว่างเท่ากับ <b>ลบค่าออก</b>
                {mode === "propose" ? " · ของเดิมจะยังไม่เปลี่ยนจนกว่าจะมีคนอนุมัติ" : ""}
              </p>
              {PATCH_FIELDS.map((f) => (
                <div key={f.key} className="flex flex-col gap-1.5">
                  <Field label={f.label} error={read.errs[f.key]}>
                    <Input
                      value={values[f.key] ?? ""}
                      onChange={(e) => setValues((v) => ({ ...v, [f.key]: e.target.value }))}
                      aria-invalid={!!read.errs[f.key]}
                      autoComplete="off"
                    />
                  </Field>
                  {f.hint ? <span className="text-sm text-ink-600">{f.hint}</span> : null}
                </div>
              ))}
              {mode === "propose" ? (
                <Field label="หมายเหตุถึงผู้อนุมัติ">
                  <Input value={note} onChange={(e) => setNote(e.target.value)} autoComplete="off" />
                </Field>
              ) : null}

              <WillSave
                items={
                  changed.length === 0
                    ? ["ยังไม่ได้แก้อะไร — ยังไม่มีอะไรจะบันทึก"]
                    : [
                        mode === "direct" ? <>แก้ทะเบียนของ <b>{asset.name}</b> ทันที (ไม่ลงสมุดบัญชี):</> : <>ส่งเป็น <b>ร่างแก้ไข</b> ของ <b>{asset.name}</b> — ทะเบียนยังเป็นค่าเดิมจนกว่าจะอนุมัติ:</>,
                        ...changed.map((r) => (
                          <>
                            {r.label}: {r.before ?? "(ว่าง)"} → <b>{r.after ?? "ลบค่าออก"}</b>
                          </>
                        )),
                      ]
                }
              />
              {error ? (
                <Notice tone="neg">
                  {error.message}
                  {error.errors?.length ? (
                    <ul className="m-0 mt-1 list-disc pl-5">
                      {error.errors.map((m) => (
                        <li key={m}>{m}</li>
                      ))}
                    </ul>
                  ) : null}
                </Notice>
              ) : null}
            </>
          )}
        </div>
        <DialogFooter>
          {sent ? (
            <>
              {mode === "propose" ? (
                <Link href="/assets/drafts" className={cn(LINK_BUTTON_CLASS, "border-line bg-surface text-ink-900 hover:border-ink-400")}>
                  ดูคิวร่าง
                </Link>
              ) : null}
              <Button onClick={onClose}>ปิด</Button>
            </>
          ) : (
            <>
              <Button variant="secondary" onClick={onClose} disabled={pending}>
                ยกเลิก
              </Button>
              <Button onClick={submit} disabled={blocked || pending}>
                {pending ? "กำลังบันทึก…" : mode === "direct" ? "บันทึกการแก้ไข" : "ส่งเป็นร่าง"}
              </Button>
            </>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
