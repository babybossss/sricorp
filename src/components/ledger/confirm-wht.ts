/**
 * ตรวจแถวยืนยันรับ-จ่ายที่ผู้จ่ายหักภาษี ณ ที่จ่ายไว้ — ตัวต่อกับ engine เหมือน `confirm-flow.ts`
 *
 * **ไม่มีกติกาบัญชีที่นี่** `buildClearing()` ไม่รู้จักภาษีถูกหัก (เงินสดแตกเป็นเงินสดสุทธิ + 1800) จึงทำสองขั้น:
 *   1. `checkRow()` ตรวจด้วยยอดเต็ม (gross) — ยอดค้างคงเหลือ · เลขอ้างอิง · มิติบังคับ · หลักฐานนิติบุคคล
 *   2. `buildPosting()` ของทางล้าง (ผ่าน `routePostingInput`) ประกอบบรรทัดจริง รวมด่านภาษี `rate × gross`
 * พรีวิวที่แสดงคือบรรทัดของขั้น 2 — ผู้ใช้เห็นเงินสด 95,000 + ภาษี 5,000 ไม่ใช่ 100,000 ที่ไม่ตรงกับที่จะบันทึก
 */
import { routePostingInput } from "@/lib/db/clearing-route";
import { parseAmountOrNull } from "@/lib/format";
import { buildPosting } from "@/lib/ledger/posting";
import { previewPosting } from "@/lib/ledger/preview";
import { PostingError, type LedgerResolver } from "@/lib/ledger/types";
import type { PendingCashRow } from "@/lib/db/pending-cash";
import type { WhtDraft } from "@/components/form/wht-value";
import { checkRow, clearingInputOf, type RowCheck, type RowDraft } from "./confirm-flow";

export function checkWhtRow(row: PendingCashRow, draft: RowDraft, wht: WhtDraft, resolve: LedgerResolver): RowCheck {
  const base = checkRow(row, draft, {}, resolve);
  if (!base.canConfirm) return base;

  const input = clearingInputOf(row, draft, {});
  const rate = parseAmountOrNull(wht.rate);
  const withheld = parseAmountOrNull(wht.amount);
  const blocked = (reason: string): RowCheck => ({
    preview: { ok: false, reason },
    canConfirm: false,
    blockedReason: reason,
  });
  if (rate === null || withheld === null) {
    return blocked("ระบุว่าถูกหักภาษี ณ ที่จ่ายแล้ว ต้องกรอกอัตราและยอดภาษีตามใบรับรองให้ครบ");
  }

  const post = routePostingInput({
    sourceSubCode: row.subCode,
    chosen: draft.clearingSubCode || undefined,
    ownerId: row.ownerId,
    amount: input.amount,
    bankAccountId: input.bankAccountId ?? "",
    assetId: row.assetId,
    contactId: row.contactId,
    attachments: input.attachments ?? [],
    wht: { rate, amount: withheld, certificateNo: wht.certificateNo.trim() || undefined },
  });
  if (!post) return blocked("ไม่พบทางล้างของหมวดนี้ในตารางกฎ");

  try {
    buildPosting(post, resolve); // ตัวจริง — ปุ่มยืนยันกั้นด้วยตัวนี้
  } catch (e) {
    if (e instanceof PostingError) return blocked(e.message);
    throw e;
  }
  const shown = previewPosting(post, resolve);
  return {
    preview: shown.ok
      ? {
          ok: true,
          lines: shown.lines.map((l) => ({ coaCode: l.coaCode, label: l.label, debit: l.debit, credit: l.credit, memo: l.memo })),
          summary: shown.summary,
        }
      : { ok: false, reason: shown.reason },
    canConfirm: true,
    blockedReason: null,
  };
}
