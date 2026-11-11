"use client";

import * as React from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { usePermissions } from "@/components/auth/permissions-provider";
import { reverseEntry, voidEntry } from "@/app/actions/reverse-entry";
import { initialState, nextState, panelView, type PanelEntry } from "./reverse-flow";

/**
 * แผง "แก้รายการที่ลงผิด" ในลิ้นชักรายละเอียดรายการ
 *
 * กฎเหล็กข้อ 1: รายการที่ post แล้วลบไม่ได้ — แผงนี้คือทางออกที่ถูกต้องสองทาง (D-097)
 *   **กลับรายการ** ลงใบใหม่ที่กลับข้าง (งวดปิดแล้ว) · **ยกเลิกใบ** ตัดออกจากงบ (งวดยังไม่ปิด)
 *
 * UI (ผู้ใช้มีผู้สูงอายุ): ตัวอักษรเล็กสุด 16px (`text-base`) · ปุ่มสูง ≥52px จาก `Button`
 * (`min-h-control` · มือถือ `min-h-control-mobile`) · ทุกปุ่มมีข้อความกำกับ ไม่มีปุ่มไอคอนเดี่ยว ·
 * วงแหวนโฟกัส 3px · สีจากโทเคนใน `tailwind.config.ts` เท่านั้น
 *
 * **ไม่มีตรรกะอยู่ใน JSX**: ลำดับขั้น (เลือกวิธี → เขียนเหตุผล → ยืนยัน) อยู่ใน
 * `reverse-flow.ts` ที่มีเทสต์จับ · และ **ไม่มีกติกาบัญชี** — ปุ่มถาม server action
 * ซึ่งถาม engine กับ DB ให้ ข้อความที่ผู้ใช้เห็นตอนปฏิเสธคือข้อความของ server ตรงๆ
 */
export function ReversePanel({ entry }: { entry: PanelEntry }) {
  const permissions = usePermissions();
  const router = useRouter();
  const [state, dispatch] = React.useReducer(nextState, null, initialState);
  const v = panelView(state, entry, permissions as ReadonlySet<string>);

  async function submit() {
    if (!v.canSubmit || v.mode === null) return;
    dispatch({ kind: "busy" });
    const req = { transactionId: entry.id, reason: state.reason };
    const out = v.mode === "reverse" ? await reverseEntry(req) : await voidEntry(req);
    dispatch({
      kind: "done",
      result: out.ok
        ? {
            ok: true,
            message:
              v.mode === "reverse"
                ? "ลงใบกลับรายการแล้ว — ใบเดิมยังอยู่ในสมุด และยอดรวมของสองใบเป็นศูนย์"
                : "ยกเลิกใบนี้แล้ว — ตัดออกจากงบ แต่ยังดูได้ในรายการที่ยกเลิก",
          }
        : { ok: false, message: out.message },
    });
    // สมุด/งบคำนวณสดฝั่ง server — ต้องดึงใหม่ ไม่ใช่แก้ตัวเลขในหน้าจอเอง
    if (out.ok) router.refresh();
  }

  const box = "rounded border border-line bg-canvas p-[14px_16px] text-base leading-7 text-ink-600";

  return (
    <section aria-label="แก้รายการที่ลงผิด" className="flex flex-col gap-3 rounded-card border border-line p-4">
      <h3 className="text-base font-semibold text-ink-900">รายการนี้ลงผิด?</h3>
      <p className={box}>
        รายการที่บันทึกแล้ว <strong>ลบไม่ได้</strong> ตามกฎของระบบ — แก้ได้สองทาง เลือกตามว่างบของเดือนนั้นส่งไปแล้วหรือยัง
      </p>

      {v.notice ? <p className={box}>{v.notice}</p> : null}

      {v.allowed ? (
        <div className="flex flex-wrap gap-3">
          {v.offerReverse ? (
            <Button
              type="button"
              variant={v.mode === "reverse" ? "primary" : "secondary"}
              aria-pressed={v.mode === "reverse"}
              disabled={v.busy}
              onClick={() => dispatch({ kind: "choose", mode: "reverse" })}
            >
              กลับรายการ (ลงใบใหม่กลับข้าง)
            </Button>
          ) : null}
          {v.offerVoid ? (
            <Button
              type="button"
              variant={v.mode === "void" ? "primary" : "danger"}
              aria-pressed={v.mode === "void"}
              disabled={v.busy}
              onClick={() => dispatch({ kind: "choose", mode: "void" })}
            >
              ยกเลิกใบนี้ (ตัดออกจากงบ)
            </Button>
          ) : null}
        </div>
      ) : null}

      {v.explain ? <p className={box}>{v.explain}</p> : null}

      {v.showReason ? (
        <label className="flex flex-col gap-2">
          <span className="text-base font-semibold text-ink-900">
            เหตุผล (บังคับ) — ผู้สอบบัญชีจะถามว่าทำไมตัวเลขเดือนนั้นเปลี่ยน
          </span>
          <textarea
            value={state.reason}
            rows={3}
            disabled={v.busy}
            onChange={(e) => dispatch({ kind: "reason", value: e.target.value })}
            placeholder="เช่น ลงผิดห้อง ที่ถูกคือคอนโดห้อง 2"
            className="w-full rounded border border-line bg-surface p-[12px_14px] text-base leading-7 text-ink-900 placeholder:text-ink-400 focus-visible:border-brand-600 focus-visible:outline-none focus-visible:ring-[3px] focus-visible:ring-brand-600"
          />
          {v.reasonError ? <span className="text-base text-neg">{v.reasonError}</span> : null}
        </label>
      ) : null}

      {v.step === "confirm" ? (
        <p className="rounded border border-neg bg-neg-bg p-[14px_16px] text-base leading-7 text-ink-900">
          ตรวจอีกครั้งก่อนกด — นี่คือการเขียนตัวเลขเข้าสมุดบัญชีจริง และย้อนกลับเองไม่ได้
          <br />
          เหตุผลที่จะบันทึกไว้: <strong>{state.reason.trim()}</strong>
        </p>
      ) : null}

      <div className="flex flex-wrap gap-3">
        {v.canAskConfirm ? (
          <Button type="button" variant="secondary" onClick={() => dispatch({ kind: "ask-confirm" })}>
            ตรวจทานก่อนบันทึก
          </Button>
        ) : null}
        {v.step === "confirm" ? (
          <Button type="button" variant="danger" disabled={!v.canSubmit} onClick={submit}>
            {v.busy ? "กำลังบันทึก…" : (v.confirmText ?? "ยืนยัน")}
          </Button>
        ) : null}
        {v.step !== "idle" ? (
          <Button type="button" variant="ghost" disabled={v.busy} onClick={() => dispatch({ kind: "cancel" })}>
            ไม่ทำแล้ว
          </Button>
        ) : null}
      </div>

      {v.result ? (
        <p
          role="status"
          className={
            v.result.ok
              ? "rounded border border-pos bg-canvas p-[14px_16px] text-base leading-7 text-ink-900"
              : "rounded border border-neg bg-neg-bg p-[14px_16px] text-base leading-7 text-ink-900"
          }
        >
          {v.result.message}
        </p>
      ) : null}
    </section>
  );
}
