"use client";

import * as React from "react";
import Link from "next/link";
import { ASSET_CLASSES } from "@/lib/rules/asset-classes";
import { HOLDERS } from "@/lib/mock/entities";
import type { AssetDraft, AssetRef } from "@/lib/mock/assets";
import { usePermissions } from "@/components/auth/permissions-provider";
import { Button } from "./tall-button";
import { Field } from "@/components/ui/field";
import { Input } from "./fields";
import { Select } from "./fields";
import { cn } from "@/lib/utils";
import { AssetDenied, AssetInvalid, useAssetStore, type NewAssetInput } from "./asset-store";
import { registerMode, registerSubmitLabel, type Perms } from "./asset-drafts";
import { LINK_BUTTON_CLASS, NotCountedNotice } from "./draft-parts";

type Result = { kind: "asset"; asset: AssetRef } | { kind: "draft"; draft: AssetDraft };

type Errors = Partial<Record<"name" | "classCode" | "categoryCode" | "ownerId", string>> & { form?: string };

/**
 * ลงทะเบียนทรัพย์ — **4 ช่องบังคับ** (D-083 ข้อ 3): ชื่อ · หมวดใหญ่ · หมวดย่อย · ผู้ถือ
 * ช่องที่เหลือเป็นส่วนขยาย ไม่บังคับ เติมทีหลังได้ (ผ่านร่างแก้ไข ถ้าไม่มีสิทธิ์แก้ตรง)
 *
 * ปุ่มบันทึกขึ้นกับสิทธิ์ (ดู `registerMode`):
 * - บันทึกเป็นทรัพย์จริง → ผู้ที่ INSERT `assets` ตรงได้ (Management ขึ้นไป)
 * - ส่งเป็นร่าง → คนที่มีแค่ `asset.draft` (Staff) **และ Manager** (มี asset.manage แต่ไม่มี
 *   portfolio.view_all จึง INSERT ตรงไม่ได้)
 * ไม่โชว์ปุ่มที่กดแล้วถูกปฏิเสธ — **การซ่อนปุ่มคือความสะดวก ไม่ใช่ความปลอดภัย**
 * ความปลอดภัยจริงอยู่ที่ RLS ใน DB (`assets_insert` · `asset_drafts_insert`)
 */
export function AssetRegister({ currentUser }: { currentUser: { id: string; name: string } }) {
  const perms: Perms = usePermissions();
  return <AssetRegisterView perms={perms} currentUser={currentUser} />;
}

/** แยกส่วนที่รับสิทธิ์เป็น prop ไว้ให้เทสต์/พรีวิวส่งสิทธิ์ตรงๆ ได้ */
export function AssetRegisterView({
  perms,
  currentUser,
}: {
  perms: Perms;
  currentUser: { id: string; name: string };
}) {
  const mode = registerMode(perms);
  const registerAsset = useAssetStore((s) => s.registerAsset);
  const submitDraft = useAssetStore((s) => s.submitDraft);

  const [name, setName] = React.useState("");
  const [classCode, setClassCode] = React.useState("");
  const [categoryCode, setCategoryCode] = React.useState("");
  const [ownerId, setOwnerId] = React.useState("");
  const [location, setLocation] = React.useState("");
  const [sizeNote, setSizeNote] = React.useState("");
  const [fundingSource, setFundingSource] = React.useState("");
  const [errors, setErrors] = React.useState<Errors>({});
  const [result, setResult] = React.useState<Result | null>(null);

  const categories = ASSET_CLASSES.find((c) => c.code === classCode)?.categories ?? [];

  function reset() {
    setName(""); setClassCode(""); setCategoryCode(""); setOwnerId("");
    setLocation(""); setSizeNote(""); setFundingSource("");
    setErrors({}); setResult(null);
  }

  function submit(as: "direct" | "draft") {
    const input: NewAssetInput = {
      name, classCode, categoryCode, ownerId,
      patch: { location, size_note: sizeNote, funding_source: fundingSource },
    };
    // ชี้ช่องที่ขาดทีละช่อง — ปุ่มไม่ถูก disable เพราะปุ่มที่กดไม่ได้โดยไม่บอกเหตุผลอ่านยากกว่า
    const e: Errors = {};
    if (!name.trim()) e.name = "ใส่ชื่อทรัพย์";
    if (!classCode) e.classCode = "เลือกหมวดใหญ่";
    if (!categoryCode) e.categoryCode = "เลือกหมวดย่อย";
    if (!ownerId) e.ownerId = "เลือกผู้ถือ";
    if (Object.keys(e).length) {
      setErrors(e);
      return;
    }
    try {
      const actor = { ...currentUser, permissions: perms };
      setResult(
        as === "direct"
          ? { kind: "asset", asset: registerAsset(input, actor) }
          : { kind: "draft", draft: submitDraft(input, actor) }
      );
      setErrors({});
    } catch (err) {
      if (err instanceof AssetInvalid) setErrors({ form: err.errors.join(" · ") });
      else if (err instanceof AssetDenied) setErrors({ form: err.message });
      else throw err;
    }
  }

  if (mode === "none") {
    return (
      <div role="alert" className="rounded border border-neg bg-neg-bg p-[14px_16px] text-base leading-7 text-neg-fg">
        บัญชีของคุณยังไม่มีสิทธิ์ลงทะเบียนหรือเสนอร่างทรัพย์ — ให้ขอผู้ดูแลระบบเปิดสิทธิ์ก่อน
      </div>
    );
  }

  if (result) {
    return (
      <div className="flex max-w-[720px] flex-col gap-4" data-testid="register-result">
        {result.kind === "draft" ? (
          <>
            {/* ร่างต้องไม่ดูเหมือน "เสร็จแล้ว": หัวข้อบอกว่าส่งแล้ว แต่กล่องเตือนบอกว่ายังไม่นับ */}
            <h2 className="m-0 text-h2 font-semibold">ส่งเป็นร่างแล้ว — ยังไม่ใช่ทรัพย์ในทะเบียน</h2>
            <NotCountedNotice>
              ร่าง &ldquo;{result.draft.name}&rdquo; รอผู้มีสิทธิ์ตรวจและอนุมัติ ก่อนหน้านั้นจะไม่โผล่ในตารางทรัพย์
              ไม่ถูกรวมในมูลค่าพอร์ต ต้นทุน และผลตอบแทน
            </NotCountedNotice>
          </>
        ) : (
          <>
            <h2 className="m-0 text-h2 font-semibold">บันทึกเป็นทรัพย์แล้ว</h2>
            <div className="rounded border border-pos bg-pos-bg p-[12px_14px] text-base leading-7 text-pos-fg">
              <b>{result.asset.name}</b> อยู่ในทะเบียนแล้ว ต้นทุนและมูลค่ายังเป็น 0 จนกว่าจะลงรายการซื้อหรือตีราคา
            </div>
          </>
        )}
        <div className="flex flex-wrap gap-3">
          <Link href={result.kind === "draft" ? "/assets/drafts" : "/assets"} className={cn(LINK_BUTTON_CLASS, "border-brand-600 bg-brand-600 text-white hover:bg-brand-700")}>
            {result.kind === "draft" ? "ดูคิวร่าง" : "ไปหน้าบริหารสินทรัพย์"}
          </Link>
          <Button variant="secondary" onClick={reset}>
            ลงทะเบียนชิ้นต่อไป
          </Button>
        </div>
      </div>
    );
  }

  return (
    <form
      noValidate
      className="flex max-w-[720px] flex-col gap-5"
      onSubmit={(ev) => {
        ev.preventDefault();
        submit(mode);
      }}
    >
      <section className="flex flex-col gap-4 rounded-card border border-line bg-surface p-[18px_20px] shadow-card">
        <h2 className="m-0 text-h2 font-semibold">ข้อมูลที่ต้องกรอก 4 ช่อง</h2>
        <Field label="ชื่อทรัพย์" required error={errors.name}>
          <Input value={name} onChange={(e) => setName(e.target.value)} aria-invalid={!!errors.name} autoComplete="off" />
        </Field>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="หมวดใหญ่" required error={errors.classCode}>
            <Select
              value={classCode}
              aria-invalid={!!errors.classCode}
              onChange={(e) => {
                setClassCode(e.target.value);
                setCategoryCode("");
              }}
            >
              <option value="">เลือกหมวดใหญ่</option>
              {ASSET_CLASSES.map((c) => (
                <option key={c.code} value={c.code}>{c.nameTh} ({c.name})</option>
              ))}
            </Select>
          </Field>
          <div className="flex flex-col gap-1.5">
            <Field label="หมวดย่อย" required error={errors.categoryCode}>
              <Select
                value={categoryCode}
                disabled={!classCode}
                aria-invalid={!!errors.categoryCode}
                onChange={(e) => setCategoryCode(e.target.value)}
              >
                <option value="">เลือกหมวดย่อย</option>
                {categories.map((c) => (
                  <option key={c.code} value={c.code}>{c.nameTh}</option>
                ))}
              </Select>
            </Field>
            {/* ข้อความช่วยอยู่นอก <label> (ไม่ปนในชื่อช่อง) และใช้ ink-600 — Field hint ใช้ ink-400 ซึ่ง contrast 3.15:1 */}
            {classCode ? null : <span className="text-sm text-ink-600">เลือกหมวดใหญ่ก่อน</span>}
          </div>
        </div>
        <Field label="ถือในชื่อ (ผู้ถือ)" required error={errors.ownerId}>
          <Select value={ownerId} aria-invalid={!!errors.ownerId} onChange={(e) => setOwnerId(e.target.value)}>
            <option value="">เลือกผู้ถือ</option>
            {HOLDERS.map((h) => (
              <option key={h.id} value={h.id}>{h.name}</option>
            ))}
          </Select>
        </Field>
      </section>

      <section className="flex flex-col gap-4 rounded-card border border-line bg-surface p-[18px_20px] shadow-card">
        <div>
          <h2 className="m-0 text-h2 font-semibold">ข้อมูลเพิ่มเติม</h2>
          <p className="m-0 text-base text-ink-600">ไม่บังคับ — เว้นว่างไว้ได้ เติมทีหลังได้ทุกช่อง</p>
        </div>
        <Field label="ที่ตั้ง">
          <Input value={location} onChange={(e) => setLocation(e.target.value)} autoComplete="off" />
        </Field>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="ขนาด">
            <Input value={sizeNote} onChange={(e) => setSizeNote(e.target.value)} autoComplete="off" />
          </Field>
          <Field label="แหล่งเงินทุน">
            <Input value={fundingSource} onChange={(e) => setFundingSource(e.target.value)} autoComplete="off" />
          </Field>
        </div>
      </section>

      {mode === "draft" ? (
        <NotCountedNotice>
          คุณส่งได้เฉพาะ<b>ร่าง</b> — ยังไม่ใช่ทรัพย์ในทะเบียนจนกว่าผู้มีสิทธิ์จะอนุมัติ
        </NotCountedNotice>
      ) : null}

      {errors.form ? (
        <div role="alert" className="rounded border border-neg bg-neg-bg p-[12px_14px] text-base leading-7 text-neg-fg">
          {errors.form}
        </div>
      ) : null}
      {Object.keys(errors).filter((k) => k !== "form").length ? (
        <div role="alert" className="text-base text-neg-fg">กรอกช่องที่มีเครื่องหมาย * ให้ครบก่อน</div>
      ) : null}

      <div className="flex flex-wrap gap-3">
        {/* ปุ่มเดียวตามสิทธิ์ (registerSubmitLabel) — ไม่มีปุ่มที่กดแล้วถูกปฏิเสธ */}
        <Button type="submit">{registerSubmitLabel(perms)}</Button>
        <Button type="button" variant="secondary" onClick={reset}>
          ล้างฟอร์ม
        </Button>
      </div>
    </form>
  );
}
