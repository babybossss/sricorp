"use client";

import * as React from "react";
import { Button } from "@/components/ui/button";
import { ContactPicker } from "@/components/form/contact-picker";
import { prepareImageForUpload, uploadAttachmentFromBrowser } from "@/lib/storage/browser";
import { hasRealEvidence } from "@/lib/storage/evidence";
import { isAttachmentRef, safeDisplayName } from "@/lib/storage/path";

/** หลักฐาน + ผู้ติดต่อของผู้ถือหนึ่งราย — รูปเดียวกับที่ server action รับ (`OwnerEvidence`) */
export type EvidenceDraft = { attachments: string[]; contactId: string };

/** ผู้ถือที่เป็นนิติบุคคลพร้อมลงสมุดหรือยัง — ถามกฎชุดเดียวกับ engine (`hasRealEvidence`) ไม่ใช่นับความยาวอาร์เรย์ */
export const evidenceReady = (ownerId: string, d: EvidenceDraft | undefined): boolean =>
  !!d && d.contactId !== "" && hasRealEvidence(d.attachments, { ownerId });

/**
 * หลักฐานของผู้ถือที่เป็นนิติบุคคล (`corporate_strict`) — ต้องมีไฟล์ที่อัปโหลดขึ้นระบบจริงของผู้ถือรายนั้น + ผู้ติดต่อ
 * ก่อนกดยืนยัน · ยอดตั้งต้นไม่มีคู่ค้าจริง ผู้ติดต่อคือผู้รับรองยอด (เช่น สำนักงานบัญชี/ผู้สอบบัญชี)
 * กติกานี้ไม่ผ่อนให้: ปุ่มยืนยันกดไม่ได้จนกว่าจะครบ และ DB ตรวจซ้ำที่ trigger
 */
export function OwnerEvidence({
  ownerId,
  ownerName,
  value,
  onChange,
}: {
  ownerId: string;
  ownerName: string;
  value: EvidenceDraft;
  onChange: (next: EvidenceDraft) => void;
}) {
  const [uploading, setUploading] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);
  const pickRef = React.useRef<HTMLInputElement>(null);

  async function onFiles(files: FileList | null) {
    if (!files || files.length === 0) return;
    setUploading(true);
    setError(null);
    const added: string[] = [];
    try {
      for (const file of Array.from(files)) {
        const prepared = await prepareImageForUpload(file);
        if (!prepared.ok) {
          setError(`${safeDisplayName(file.name)}: ${prepared.message}`);
          continue;
        }
        const up = await uploadAttachmentFromBrowser(prepared.file, ownerId);
        if (!up.ok) {
          setError(`${safeDisplayName(file.name)}: ${up.message}`);
          continue;
        }
        added.push(up.ref);
      }
    } finally {
      setUploading(false);
      if (pickRef.current) pickRef.current.value = "";
    }
    if (added.length) onChange({ ...value, attachments: [...value.attachments, ...added] });
  }

  const ready = evidenceReady(ownerId, value);
  return (
    <div className="flex flex-col gap-3 rounded-card border border-line bg-surface p-4">
      <div className="text-lg font-semibold">{ownerName} เป็นนิติบุคคล — ต้องแนบหลักฐานก่อนลงสมุด</div>
      <div className="text-base leading-7 text-ink-600">
        แนบไฟล์ที่ยืนยันยอดตั้งต้น ณ วันตัดยอด เช่น งบทดลองที่ลงนาม หรือ statement ธนาคาร (PDF / ภาพ ไม่เกิน 4 MB) —
        ต้องเป็นไฟล์ที่อัปโหลดขึ้นระบบจริง ชื่อไฟล์ที่พิมพ์เองใช้ไม่ได้
      </div>
      <input
        ref={pickRef}
        type="file"
        accept="image/jpeg,image/png,image/webp,image/heic,application/pdf"
        multiple
        hidden
        onChange={(e) => void onFiles(e.target.files)}
      />
      <div>
        <Button type="button" variant="secondary" disabled={uploading} onClick={() => pickRef.current?.click()} className="max-sm:min-h-control-mobile">
          {uploading ? "กำลังอัปโหลดไฟล์… อย่าปิดหน้านี้" : `เลือกไฟล์หลักฐานของ ${ownerName}`}
        </Button>
      </div>
      {error ? (
        <div role="alert" className="rounded border border-neg bg-neg-bg p-3 text-base leading-7 text-neg-fg">
          อัปโหลดไม่สำเร็จ: {error}
        </div>
      ) : null}
      {value.attachments.length ? (
        <div className="flex flex-wrap gap-2">
          {value.attachments.map((f, i) => (
            <Button
              key={f}
              type="button"
              variant="secondary"
              onClick={() => onChange({ ...value, attachments: value.attachments.filter((_, n) => n !== i) })}
              className="max-sm:min-h-control-mobile"
            >
              {isAttachmentRef(f) ? `ไฟล์หลักฐาน ${i + 1}` : safeDisplayName(f)} — กดเพื่อเอาออก
            </Button>
          ))}
        </div>
      ) : null}
      <ContactPicker
        value={value.contactId}
        onSelect={(id) => onChange({ ...value, contactId: id })}
        label={`ผู้ติดต่อที่รับรองยอดของ ${ownerName}`}
        hint="เช่น สำนักงานบัญชี หรือผู้สอบบัญชี — ระบบบังคับให้นิติบุคคลระบุผู้ติดต่อทุกรายการ"
        required
        layer={0}
        suggestKind="vendor"
      />
      <div className={ready ? "text-base text-pos-fg" : "text-base text-warn-fg"}>
        {ready ? "หลักฐานและผู้ติดต่อครบแล้ว" : "ยังไม่ครบ — ต้องมีไฟล์หลักฐานอย่างน้อยหนึ่งไฟล์ และเลือกผู้ติดต่อ"}
      </div>
    </div>
  );
}
