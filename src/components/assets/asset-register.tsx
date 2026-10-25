"use client";

import * as React from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { usePermissions } from "@/components/auth/permissions-provider";
import { Field } from "@/components/ui/field";
import { cn } from "@/lib/utils";
import type { RefOwner } from "@/lib/db/reference-types";
import type { DraftPatch, Taxonomy } from "@/lib/db/assets-model";
import { registerAsset, type AssetOutcome } from "@/app/assets/actions";
import { Button } from "./tall-button";
import { Input, Select } from "./fields";
import { PATCH_FIELDS, patchField, registerMode, registerSubmitLabel, type Perms } from "./asset-drafts";
import { LINK_BUTTON_CLASS, NotCountedNotice } from "./draft-parts";
import { Notice, WillSave } from "./asset-parts";

/** ช่องเสริมที่ลงทะเบียนพร้อมกันได้ (ไม่รวมชื่อ ซึ่งเป็นช่องบังคับ) — ชุดย่อยของ `PATCH_FIELDS` */
const OPTIONAL_KEYS = ["location", "property_type", "size_note", "funding_source", "ownership_pct", "tags"] as const;

type Errors = Partial<Record<"name" | "classId" | "categoryId" | "ownerId" | (typeof OPTIONAL_KEYS)[number], string>>;

/**
 * ลงทะเบียนทรัพย์ — **4 ช่องบังคับ** (D-083 ข้อ 3): ชื่อ · หมวดใหญ่ · หมวดย่อย · ผู้ถือ
 * ช่องที่เหลือไม่บังคับ เติมทีหลังได้ (ผ่านร่างแก้ไข ถ้าไม่มีสิทธิ์แก้ตรง)
 *
 * ปุ่มบันทึกขึ้นกับสิทธิ์ (`registerMode`): บันทึกเป็นทรัพย์จริง (Management ขึ้นไป) หรือส่งเป็นร่าง
 * **การซ่อนปุ่มคือความสะดวก ไม่ใช่ความปลอดภัย** — ด่านจริงคือ RLS (`assets_insert` · `asset_drafts_insert`)
 * และ server action เลือกเส้นทางด้วยฟังก์ชันเดียวกับที่เลือกปุ่ม
 */
export function AssetRegister({ taxonomy, owners }: { taxonomy: Taxonomy; owners: RefOwner[] }) {
  const perms: Perms = usePermissions();
  return <AssetRegisterView perms={perms} taxonomy={taxonomy} owners={owners} />;
}

export function AssetRegisterView({ perms, taxonomy, owners }: { perms: Perms; taxonomy: Taxonomy; owners: RefOwner[] }) {
  const router = useRouter();
  const mode = registerMode(perms);
  const [pending, startTransition] = React.useTransition();

  const [name, setName] = React.useState("");
  const [classId, setClassId] = React.useState("");
  const [categoryId, setCategoryId] = React.useState("");
  const [ownerId, setOwnerId] = React.useState("");
  const [extra, setExtra] = React.useState<Record<string, string>>({});
  const [note, setNote] = React.useState("");
  const [errors, setErrors] = React.useState<Errors>({});
  const [serverError, setServerError] = React.useState<{ message: string; errors?: string[] } | null>(null);
  const [done, setDone] = React.useState<{ outcome: Extract<AssetOutcome, { ok: true }>; name: string } | null>(null);

  const categories = taxonomy.categories.filter((c) => c.classId === classId && c.isActive);
  const owner = owners.find((o) => o.id === ownerId);
  const cls = taxonomy.classes.find((c) => c.id === classId);
  const cat = taxonomy.categories.find((c) => c.id === categoryId);

  /** อ่านช่องเสริมด้วยตัวอ่านชุดเดียวกับที่ใช้ตอนแก้ — ช่องว่างไม่ถูกส่ง */
  function readExtra(): { patch: DraftPatch; errors: Errors } {
    const patch: DraftPatch = {};
    const errs: Errors = {};
    for (const key of OPTIONAL_KEYS) {
      const f = patchField(key);
      if (!f) continue;
      const r = f.parse(extra[key] ?? "");
      if (!r.ok) errs[key] = r.error;
      else if (r.value !== null) patch[key] = r.value;
    }
    return { patch, errors: errs };
  }

  const preview = readExtra();

  function reset() {
    setName(""); setClassId(""); setCategoryId(""); setOwnerId(""); setExtra({}); setNote("");
    setErrors({}); setServerError(null); setDone(null);
  }

  function submit() {
    const e: Errors = { ...preview.errors };
    if (!name.trim()) e.name = "ใส่ชื่อทรัพย์";
    if (!classId) e.classId = "เลือกหมวดใหญ่";
    if (!categoryId) e.categoryId = "เลือกหมวดย่อย";
    if (!ownerId) e.ownerId = "เลือกผู้ถือ";
    setErrors(e);
    setServerError(null);
    if (Object.keys(e).length) return;

    startTransition(async () => {
      const out = await registerAsset({ name, classId, categoryId, ownerId, patch: preview.patch, note });
      if (out.ok) {
        setDone({ outcome: out, name: name.trim() });
        router.refresh();
      } else setServerError({ message: out.message, errors: out.errors });
    });
  }

  if (mode === "none") {
    return <Notice tone="neg">บัญชีของคุณยังไม่มีสิทธิ์ลงทะเบียนหรือเสนอร่างทรัพย์ — ให้ขอผู้ดูแลระบบเปิดสิทธิ์ก่อน</Notice>;
  }

  if (done) {
    return (
      <div className="flex max-w-[720px] flex-col gap-4" data-testid="register-result">
        {mode === "draft" ? (
          <>
            {/* ร่างต้องไม่ดูเหมือน "เสร็จแล้ว": หัวข้อบอกว่าส่งแล้ว แต่กล่องเตือนบอกว่ายังไม่นับ */}
            <h2 className="m-0 text-h2 font-semibold">ส่งเป็นร่างแล้ว — ยังไม่ใช่ทรัพย์ในทะเบียน</h2>
            <NotCountedNotice>
              ร่าง &ldquo;{done.name}&rdquo; รอผู้มีสิทธิ์ตรวจและอนุมัติ ก่อนหน้านั้นจะไม่โผล่ในตารางทรัพย์
              ไม่ถูกรวมในมูลค่าพอร์ต ต้นทุน และรายงาน
            </NotCountedNotice>
          </>
        ) : (
          <>
            <h2 className="m-0 text-h2 font-semibold">บันทึกเป็นทรัพย์แล้ว</h2>
            <Notice tone="ok">
              <b>{done.name}</b> อยู่ในทะเบียนแล้ว — {done.outcome.message}
            </Notice>
          </>
        )}
        <div className="flex flex-wrap gap-3">
          <Link href={mode === "draft" ? "/assets/drafts" : done.outcome.id ? `/assets/${done.outcome.id}` : "/assets"} className={cn(LINK_BUTTON_CLASS, "border-brand-600 bg-brand-600 text-white hover:bg-brand-700")}>
            {mode === "draft" ? "ดูคิวร่าง" : "ดูทรัพย์ที่เพิ่งลงทะเบียน"}
          </Link>
          <Button variant="secondary" onClick={reset}>
            ลงทะเบียนชิ้นต่อไป
          </Button>
        </div>
      </div>
    );
  }

  const filled = PATCH_FIELDS.filter((f) => f.key in preview.patch);
  const willSave: React.ReactNode[] = [
    mode === "direct"
      ? <>สร้างทรัพย์ <b>{name.trim() || "(ยังไม่ได้ใส่ชื่อ)"}</b> ในทะเบียนทันที · ระบบออกรหัสทรัพย์ให้เอง</>
      : <>บันทึกเป็น <b>ร่าง</b> ของทรัพย์ <b>{name.trim() || "(ยังไม่ได้ใส่ชื่อ)"}</b> — ยังไม่ใช่ทรัพย์ในทะเบียนจนกว่าผู้มีสิทธิ์จะอนุมัติ</>,
    <>หมวด {cls ? `${cls.nameTh} › ${cat?.nameTh ?? "(ยังไม่ได้เลือกหมวดย่อย)"}` : "(ยังไม่ได้เลือก)"} · ถือในชื่อ {owner?.name ?? "(ยังไม่ได้เลือกผู้ถือ)"}</>,
    ...filled.map((f) => <>{f.label}: {f.format(preview.patch[f.key] as string | number | string[])}</>),
    mode === "direct"
      ? <>ต้นทุนและมูลค่าเริ่มที่ 0 — ต้นทุนเกิดจากการลงรายการซื้อในหน้าบันทึกรายการเท่านั้น (การลงทะเบียนนี้ <b>ไม่ลงสมุดบัญชี</b>)</>
      : <>ร่างนี้ <b>ไม่ถูกนับ</b>ในมูลค่าพอร์ต ต้นทุน หรือรายงาน และไม่ลงสมุดบัญชี</>,
  ];

  return (
    <form
      noValidate
      className="flex max-w-[720px] flex-col gap-5"
      onSubmit={(ev) => {
        ev.preventDefault();
        submit();
      }}
    >
      <section className="flex flex-col gap-4 rounded-card border border-line bg-surface p-[18px_20px] shadow-card">
        <h2 className="m-0 text-h2 font-semibold">ข้อมูลที่ต้องกรอก 4 ช่อง</h2>
        <Field label="ชื่อทรัพย์" required error={errors.name}>
          <Input value={name} onChange={(e) => setName(e.target.value)} aria-invalid={!!errors.name} autoComplete="off" />
        </Field>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="หมวดใหญ่" required error={errors.classId}>
            <Select
              value={classId}
              aria-invalid={!!errors.classId}
              onChange={(e) => {
                setClassId(e.target.value);
                setCategoryId("");
              }}
            >
              <option value="">เลือกหมวดใหญ่</option>
              {taxonomy.classes.map((c) => (
                <option key={c.id} value={c.id}>{c.nameTh}</option>
              ))}
            </Select>
          </Field>
          <div className="flex flex-col gap-1.5">
            <Field label="หมวดย่อย" required error={errors.categoryId}>
              <Select value={categoryId} disabled={!classId} aria-invalid={!!errors.categoryId} onChange={(e) => setCategoryId(e.target.value)}>
                <option value="">เลือกหมวดย่อย</option>
                {categories.map((c) => (
                  <option key={c.id} value={c.id}>{c.nameTh}</option>
                ))}
              </Select>
            </Field>
            {classId ? null : <span className="text-sm text-ink-600">เลือกหมวดใหญ่ก่อน</span>}
          </div>
        </div>
        <Field label="ถือในชื่อ (ผู้ถือ)" required error={errors.ownerId}>
          <Select value={ownerId} aria-invalid={!!errors.ownerId} onChange={(e) => setOwnerId(e.target.value)}>
            <option value="">เลือกผู้ถือ</option>
            {owners.map((o) => (
              <option key={o.id} value={o.id}>{o.name}</option>
            ))}
          </Select>
        </Field>
      </section>

      <section className="flex flex-col gap-4 rounded-card border border-line bg-surface p-[18px_20px] shadow-card">
        <div>
          <h2 className="m-0 text-h2 font-semibold">ข้อมูลเพิ่มเติม</h2>
          <p className="m-0 text-base text-ink-600">ไม่บังคับ — เว้นว่างไว้ได้ เติมทีหลังได้ทุกช่อง</p>
        </div>
        {OPTIONAL_KEYS.map((key) => {
          const f = patchField(key);
          if (!f) return null;
          return (
            <div key={key} className="flex flex-col gap-1.5">
              <Field label={f.label} error={errors[key]}>
                <Input
                  value={extra[key] ?? ""}
                  onChange={(e) => setExtra((v) => ({ ...v, [key]: e.target.value }))}
                  aria-invalid={!!errors[key]}
                  autoComplete="off"
                  inputMode={key === "ownership_pct" ? "decimal" : undefined}
                />
              </Field>
              {f.hint ? <span className="text-sm text-ink-600">{f.hint}</span> : null}
            </div>
          );
        })}
        <Field label="หมายเหตุถึงผู้อนุมัติ">
          <Input value={note} onChange={(e) => setNote(e.target.value)} autoComplete="off" />
        </Field>
      </section>

      <WillSave items={willSave} />

      {serverError ? (
        <Notice tone="neg">
          {serverError.message}
          {serverError.errors?.length ? (
            <ul className="m-0 mt-1 list-disc pl-5">
              {serverError.errors.map((m) => (
                <li key={m}>{m}</li>
              ))}
            </ul>
          ) : null}
        </Notice>
      ) : null}
      {Object.keys(errors).length ? <div role="alert" className="text-base text-neg-fg">กรอกช่องที่มีเครื่องหมาย * ให้ครบและถูกต้องก่อน</div> : null}

      <div className="flex flex-wrap gap-3">
        {/* ปุ่มเดียวตามสิทธิ์ (registerSubmitLabel) — ไม่มีปุ่มที่กดแล้วถูกปฏิเสธ */}
        <Button type="submit" disabled={pending}>
          {pending ? "กำลังบันทึก…" : registerSubmitLabel(perms)}
        </Button>
        <Button type="button" variant="secondary" onClick={reset} disabled={pending}>
          ล้างฟอร์ม
        </Button>
      </div>
    </form>
  );
}
