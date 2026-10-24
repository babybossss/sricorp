"use client";

import * as React from "react";
import { Dialog, DialogContent, DialogHeader, DialogFooter } from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Field } from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { Select } from "@/components/ui/select";
import { useApp } from "@/lib/store";
import { useAddContact, useReference } from "@/components/reference/reference-provider";
import { CONTACT_TYPE_CHOICES, contactFullName, contactTypeLabel } from "@/lib/db/reference-types";
import { createContact } from "@/app/actions/contacts";

/**
 * Backlog ข้อ 3 — สร้าง contact ได้จากในฟอร์ม แล้วเด้งกลับมาที่ฟอร์มเดิม
 *
 * ปุ่ม "＋ สร้างผู้ติดต่อใหม่" เปิด dialog ซ้อนอีกชั้น (layer=1)
 * เมื่อบันทึก ระบบจะ:
 *   1. สร้างผู้ติดต่อลง `sri_os.contacts` จริง (server action) — id เป็น uuid ที่รายการอ้างถึงได้
 *   2. เรียก onSelect ด้วย id ใหม่ → ฟอร์มเดิมเลือกคนนั้นไว้ให้แล้ว
 *   3. ปิดเฉพาะ dialog ลูก ฟอร์มรายการยังเปิดค้างพร้อมค่าที่กรอกไว้ทั้งหมด
 * ผู้ใช้จึงไม่ต้องกรอกฟอร์มรายการใหม่ทั้งหมด
 */
export function ContactPicker({
  value,
  onSelect,
  label = "ผู้ติดต่อ",
  hint,
  required,
  /** dialog ลูกต้องซ้อนเหนือ dialog แม่ */
  layer = 1,
  suggestKind = "other",
}: {
  value: string;
  onSelect: (id: string) => void;
  label?: string;
  hint?: string;
  required?: boolean;
  layer?: number;
  /** บทบาทที่เสนอให้ตอนสร้างใหม่ (tenant · lender · borrower · vendor · other) */
  suggestKind?: string;
}) {
  const { contacts } = useReference();
  const addToList = useAddContact();
  const showToast = useApp((s) => s.showToast);
  const [open, setOpen] = React.useState(false);
  const [saving, setSaving] = React.useState(false);
  const [saveError, setSaveError] = React.useState<string | null>(null);

  const [form, setForm] = React.useState({ firstName: "", lastName: "", phone: "", lineId: "", email: "", kind: suggestKind });
  const [touched, setTouched] = React.useState(false);

  const nameMissing = !form.firstName.trim();

  async function save() {
    setTouched(true);
    if (nameMissing || saving) return;
    setSaving(true);
    setSaveError(null);
    try {
      const out = await createContact({
        firstName: form.firstName,
        lastName: form.lastName,
        phone: form.phone,
        lineId: form.lineId,
        email: form.email,
        type: form.kind,
      });
      if (!out.ok) {
        // ไม่ปิด dialog ไม่ล้างค่า — ผู้ใช้แก้แล้วกดใหม่ได้
        setSaveError(out.message);
        return;
      }
      addToList(out.contact);
      // เลือกคนที่เพิ่งสร้างไว้ให้ในฟอร์มเดิมทันที
      onSelect(out.contact.id);
      showToast(`เพิ่ม ${contactFullName(out.contact)} แล้ว และเลือกไว้ในฟอร์มให้เรียบร้อย`);
      setForm({ firstName: "", lastName: "", phone: "", lineId: "", email: "", kind: suggestKind });
      setTouched(false);
      setOpen(false);
    } catch (e) {
      console.error("createContact failed", e);
      setSaveError("ติดต่อเซิร์ฟเวอร์ไม่ได้ ยังไม่ได้สร้างผู้ติดต่อ — ลองใหม่อีกครั้ง");
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="flex flex-col gap-2">
      <Field label={label} hint={hint} required={required} error={required && !value ? "ยังไม่ได้เลือกผู้ติดต่อ" : undefined}>
        <Select value={value} onChange={(e) => onSelect(e.target.value)}>
          <option value="">— เลือกผู้ติดต่อ —</option>
          {contacts.map((c) => (
            <option key={c.id} value={c.id}>
              {contactFullName(c)} · {contactTypeLabel(c.types)}
            </option>
          ))}
        </Select>
      </Field>

      <Button type="button" variant="quiet" size="sm" className="self-start" onClick={() => setOpen(true)}>
        ＋ สร้างผู้ติดต่อใหม่
      </Button>

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent width="max-w-[560px]" layer={layer} aria-describedby={undefined}>
          <DialogHeader title="สร้างผู้ติดต่อใหม่" />
          <div className="flex flex-col gap-4 p-6">
            <div className="rounded border border-brand-100 bg-brand-50 p-[12px_14px] text-sm leading-6">
              บันทึกแล้วจะกลับมาที่ฟอร์มเดิม พร้อมเลือกผู้ติดต่อคนนี้ไว้ให้ — ข้อมูลที่กรอกค้างไว้ไม่หาย
            </div>
            <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <Field label="ชื่อ" required error={touched && nameMissing ? "กรอกชื่อก่อน" : undefined}>
                <Input value={form.firstName} onChange={(e) => setForm({ ...form, firstName: e.target.value })} placeholder="เช่น สมชาย" />
              </Field>
              <Field label="นามสกุล">
                <Input value={form.lastName} onChange={(e) => setForm({ ...form, lastName: e.target.value })} placeholder="เช่น ใจดี" />
              </Field>
              <Field label="เบอร์โทร">
                <Input value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} inputMode="tel" placeholder="08x-xxx-xxxx" />
              </Field>
              <Field label="LINE ID">
                <Input value={form.lineId} onChange={(e) => setForm({ ...form, lineId: e.target.value })} placeholder="เช่น somchai.j" />
              </Field>
              <Field label="อีเมล">
                <Input value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} inputMode="email" placeholder="name@example.com" />
              </Field>
              <Field label="ประเภทผู้ติดต่อ">
                <Select value={form.kind} onChange={(e) => setForm({ ...form, kind: e.target.value })}>
                  {CONTACT_TYPE_CHOICES.map((k) => (
                    <option key={k.value} value={k.value}>
                      {k.label}
                    </option>
                  ))}
                </Select>
              </Field>
            </div>
          </div>
          <DialogFooter>
            {saveError ? (
              <div role="alert" className="w-full rounded border border-neg bg-neg-bg p-[12px_14px] text-base leading-7 text-neg-fg">
                สร้างผู้ติดต่อไม่สำเร็จ — {saveError}
              </div>
            ) : null}
            <Button variant="secondary" onClick={() => setOpen(false)} disabled={saving}>
              ยกเลิก
            </Button>
            <Button onClick={() => void save()} disabled={saving}>
              {saving ? "กำลังบันทึก…" : "บันทึกและกลับไปที่ฟอร์ม"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
