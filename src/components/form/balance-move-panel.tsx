"use client";

import * as React from "react";
import { money } from "@/lib/format";
import { coaLabel } from "@/lib/rules/coa";
import { JournalPreview } from "./journal-preview";
import type { TxFormApi } from "./use-tx-form";

/**
 * แผงย้ายวัตถุประสงค์ทรัพย์ (ย้ายทั้งก้อน) — **ยอดอ่านจากสมุด ไม่มีช่องให้พิมพ์** (D-115)
 *
 * ผู้ใช้เลือกแค่ทรัพย์ แล้วเห็นว่าระบบจะย้ายต้นทุน "ทั้งก้อน เท่าไร" จากบัญชีไหนไปบัญชีไหน
 * บัญชีมาจากตารางกฎ (`sub.cr` / `sub.dr`) · บรรทัดบัญชีมาจาก engine ตัวเดียวกับที่ลงจริง (`JournalPreview`)
 * ตอนกดบันทึก server อ่านยอดซ้ำเอง ไม่เชื่อยอดที่แผงนี้ถือไว้
 */
export function BalanceMovePanel({ api }: { api: TxFormApi }) {
  const { draft, sub, balanceMoveState: state } = api;
  if (!sub) return null;

  return (
    <div className="flex flex-col gap-4 rounded-card border border-line bg-canvas p-4">
      <div className="text-base font-semibold">ย้ายต้นทุนของทรัพย์ทั้งก้อน</div>

      {!draft.assetId ? (
        <div className="text-base leading-7 text-ink-600">
          เลือก<b>ทรัพย์ที่จะย้าย</b>ในช่อง “โปรเจค (ทรัพย์)” ด้านบนก่อน — ระบบจะอ่านยอดต้นทุนของทรัพย์ชิ้นนั้นจากสมุดให้ ไม่ต้องพิมพ์ยอดเอง
        </div>
      ) : state.loading ? (
        <div role="status" className="text-base text-ink-600">
          กำลังอ่านยอดต้นทุนของทรัพย์จากสมุด…
        </div>
      ) : state.error ? (
        <div role="alert" className="rounded border border-neg bg-neg-bg p-[12px_14px] text-base leading-7 text-neg-fg">
          {state.error}
        </div>
      ) : state.balanceMove ? (
        <>
          <dl className="grid grid-cols-1 gap-x-6 gap-y-2 rounded border border-line bg-surface p-[14px_16px] text-base sm:grid-cols-3">
            <div>
              <dt className="text-sm text-ink-600">ย้ายออกจากบัญชี</dt>
              <dd className="font-semibold">{coaLabel(sub.cr)}</dd>
            </div>
            <div>
              <dt className="text-sm text-ink-600">ย้ายเข้าบัญชี</dt>
              <dd className="font-semibold">{coaLabel(sub.dr)}</dd>
            </div>
            <div>
              <dt className="text-sm text-ink-600">ยอดที่จะย้าย (ทั้งก้อน)</dt>
              <dd className="text-h2 font-semibold tabular-nums">{money(state.balanceMove.sourceBalance)} บาท</dd>
            </div>
          </dl>
          <div className="rounded border border-brand-100 bg-brand-50 p-[12px_14px] text-base leading-7">
            <b>ย้ายทั้งก้อนเท่านั้น</b> — ยอดนี้คือต้นทุนทั้งหมดของทรัพย์ชิ้นนี้ในบัญชีต้นทางตามสมุด แก้ในฟอร์มไม่ได้
            ถ้าไม่ถูกต้องให้แก้ที่รายการต้นทางก่อน · ไม่มีเงินเข้าออก และไม่เข้างบกำไรขาดทุน
          </div>
          <JournalPreview input={api.postingInput} />
        </>
      ) : null}
    </div>
  );
}
