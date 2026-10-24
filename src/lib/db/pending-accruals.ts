/**
 * ยอดค้างรับ-ค้างจ่ายที่ยังไม่ได้ล้าง — **อ่านจากรายการที่ post แล้วใน DB** ไม่ใช่จาก state ของหน้าจอ
 *
 * แหล่งข้อมูลเดียวคือ `v_ledger_posted` (D-107) — ไม่อ่านตาราง `transactions` ตรง
 *
 *   ต้นทาง   = รายการที่ post แล้วโดยไม่มีบรรทัดเงินสด (cash_date ว่าง) และมีบรรทัดบัญชีพักของหมวดนั้น
 *              (บัญชีพักอ่านจาก `accrualCheck()` ในตารางกฎ ไม่ได้ระบุรหัสบัญชีที่นี่)
 *   ประวัติ  = รายการที่ `source_ref` = `<id ต้นทาง>-clr-<n>` (ใบล้างที่ action สร้าง) ยอดอ่านจากบรรทัดเงินสดของใบนั้น
 *   ใบที่ถูกกลับรายการ ไม่นับ: ทั้งต้นทางที่ถูกกลับ และใบล้างที่ถูกกลับ (ยอดค้างจึงกลับมาให้ล้างใหม่ได้)
 *
 * ไฟล์นี้เป็นฟังก์ชันล้วน (ไม่แตะ DB) เพื่อเทสต์ได้ — ตัวอ่าน DB อยู่ที่ `pending-accruals-server.ts`
 * **ไม่คำนวณคู่บัญชี**: จับคู่ "บรรทัดไหนคือยอดค้าง" ด้วยรหัสบัญชีพักจากตารางกฎเท่านั้น
 */

import { isCashAccount } from "@/lib/rules/coa";
import { accrualCheck, findSub, type TxTypeKey } from "@/lib/rules/tx-rules";
import type { PostedClearing } from "@/lib/ledger/types";
import type { CoaCodeLookup, LedgerViewRow } from "./ledger-entries";

export type PendingAccrual = {
  /** id ของรายการต้นทาง (transaction) */
  id: string;
  ownerId: string;
  typeKey: TxTypeKey;
  subCode: string;
  docDate: string;
  memo: string | null;
  assetId: string | null;
  contactId: string | null;
  /** ไฟล์หลักฐานของรายการต้นทาง */
  attachments: string[];
  /** ยอดที่ตั้งค้างไว้ตอนบันทึกต้นทาง (บวกเสมอ) */
  accruedAmount: number;
  /** การล้างที่ post แล้วจริง เรียงตามลำดับ — `id` คือเลขอ้างอิง (`source_ref`) ของใบล้าง */
  postedClearings: PostedClearing[];
  /** ยอดค้างคงเหลือ = ยอดตั้งค้าง − ที่ล้างแล้ว (เพื่อแสดงผลเท่านั้น · engine คิดเองตอนล้าง) */
  outstanding: number;
};

const round2 = (n: number) => Math.round(n * 100) / 100;

/** `<uuid>-clr-<n>` */
const CLEARING_REF_RE = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})-clr-(\d+)$/i;

export const clearingRefFor = (sourceId: string, n: number): string => `${sourceId}-clr-${n}`;

export const parseClearingRef = (ref: string | null | undefined): { sourceId: string; n: number } | null => {
  const m = ref ? CLEARING_REF_RE.exec(ref) : null;
  return m ? { sourceId: m[1].toLowerCase(), n: Number(m[2]) } : null;
};

type Rows = {
  /** บรรทัดของรายการที่ cash_date ว่าง (ตัวเลือกรายการต้นทาง) */
  candidates: LedgerViewRow[];
  /** บรรทัดของรายการที่ source_ref เป็นเลขอ้างอิงการล้าง */
  clearings: LedgerViewRow[];
  /** บรรทัดของใบกลับรายการ (อย่างน้อยต้องมี reverses_id) */
  reversals: LedgerViewRow[];
};

const groupBy = <T,>(items: T[], key: (t: T) => string): Map<string, T[]> => {
  const m = new Map<string, T[]>();
  for (const it of items) {
    const k = key(it);
    const arr = m.get(k);
    if (arr) arr.push(it);
    else m.set(k, [it]);
  }
  return m;
};

/**
 * คัดรายการต้นทางที่มียอดค้าง พร้อมประวัติการล้างจริง
 * คืน **ทุกต้นทางที่เป็นค้างรับ-ค้างจ่าย** รวมที่ล้างครบแล้ว (`outstanding = 0`) — ผู้เรียกกรองเอง
 */
export function derivePendingAccruals(rows: Rows, coaCodeById: CoaCodeLookup): PendingAccrual[] {
  const reversedIds = new Set(rows.reversals.map((r) => r.reverses_id).filter((x): x is string => !!x));

  // ---- ประวัติการล้าง: ต่อรหัสต้นทาง ----
  const history = new Map<string, { n: number; id: string; amount: number }[]>();
  for (const [txnId, lines] of groupBy(rows.clearings, (r) => r.transaction_id)) {
    const head = lines[0];
    if (head.source === "reverse" || reversedIds.has(txnId)) continue;
    const parsed = parseClearingRef(head.source_ref);
    if (!parsed) continue;
    // ยอดอ่านจากบรรทัดเงินสดของใบล้างที่ post แล้ว (ตรงกับที่ engine ลงจริง ไม่ใช่ตัวเลขที่ผู้ใช้พิมพ์)
    const cash = lines.filter((l) => isCashAccount(coaCodeById[l.coa_id] ?? ""));
    if (!cash.length) continue;
    const amount = round2(Math.abs(cash.reduce((t, l) => t + Number(l.debit) - Number(l.credit), 0)));
    const list = history.get(parsed.sourceId) ?? [];
    list.push({ n: parsed.n, id: head.source_ref as string, amount });
    history.set(parsed.sourceId, list);
  }

  // ---- รายการต้นทาง ----
  const out: PendingAccrual[] = [];
  for (const [txnId, lines] of groupBy(rows.candidates, (r) => r.transaction_id)) {
    const head = lines[0];
    if (head.source === "reverse" || reversedIds.has(txnId) || head.cash_date) continue;
    const found = findSub(head.txn_type_code);
    if (!found) continue;
    const check = accrualCheck(found.sub);
    if (!check.ok) continue;
    const codes = lines.map((l) => ({ l, code: coaCodeById[l.coa_id] ?? "" }));
    if (codes.some((c) => isCashAccount(c.code))) continue;
    const accrualLines = codes.filter((c) => c.code === check.account);
    if (!accrualLines.length) continue;
    const accrued = round2(
      Math.abs(accrualLines.reduce((t, c) => t + Number(c.l.debit) - Number(c.l.credit), 0))
    );
    if (!(accrued > 0)) continue;

    const done = (history.get(txnId.toLowerCase()) ?? history.get(txnId) ?? []).sort((a, b) => a.n - b.n);
    const cleared = round2(done.reduce((t, c) => t + c.amount, 0));
    out.push({
      id: txnId,
      ownerId: head.owner_id,
      typeKey: found.type.key,
      subCode: head.txn_type_code,
      docDate: head.doc_date,
      memo: head.txn_memo,
      assetId: head.txn_asset_id,
      contactId: head.contact_id,
      attachments: head.attachments ?? [],
      accruedAmount: accrued,
      postedClearings: done.map((c) => ({ id: c.id, amount: c.amount })),
      outstanding: round2(accrued - cleared),
    });
  }
  return out;
}
