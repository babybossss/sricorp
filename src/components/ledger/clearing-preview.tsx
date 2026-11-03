import { money } from "@/lib/format";
import type { RowCheck } from "./confirm-flow";

/**
 * "ระบบจะบันทึกให้ดังนี้" ของการยืนยันเงินเข้า-ออก
 *
 * บรรทัดมาจาก `buildClearingDraft()` ผ่าน `checkRow()` — ไม่คำนวณคู่บัญชีหรือยอดเอง
 * สิ่งที่เห็นตรงนี้คือสิ่งที่จะถูกบันทึกจริง (ปุ่มยืนยันถามอีกรอบด้วย `buildClearing()`)
 */
export function ClearingPreview({ preview }: { preview: RowCheck["preview"] }) {
  if (!preview.ok) {
    return (
      <div className="rounded border border-warn bg-warn-bg p-[12px_14px] text-sm leading-6 text-warn-fg">
        ยังแสดงบรรทัดบัญชีไม่ได้: {preview.reason}
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-1.5">
      <div className="text-sm font-semibold text-ink-600">ระบบจะบันทึกให้ดังนี้</div>
      <div className="overflow-hidden rounded border border-line">
        <table className="w-full border-collapse text-sm">
          <thead>
            <tr className="bg-canvas">
              <th className="p-[8px_10px] text-left font-semibold text-ink-600">บัญชี</th>
              <th className="p-[8px_10px] text-right font-semibold text-ink-600">เดบิต</th>
              <th className="p-[8px_10px] text-right font-semibold text-ink-600">เครดิต</th>
            </tr>
          </thead>
          <tbody>
            {preview.lines.map((l, i) => (
              <tr key={`${l.coaCode}-${i}`} className="border-t border-line">
                <td className="p-[8px_10px]">
                  <span className="text-ink-400">{l.coaCode}</span> {l.label}
                </td>
                <td className="p-[8px_10px] text-right tabular-nums">{l.debit ? money(l.debit) : "–"}</td>
                <td className="p-[8px_10px] text-right tabular-nums">{l.credit ? money(l.credit) : "–"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <ul className="m-0 flex list-none flex-col gap-1 p-0 text-sm leading-6 text-ink-600">
        {preview.summary.map((s, i) => (
          <li key={i}>· {s}</li>
        ))}
      </ul>
    </div>
  );
}
