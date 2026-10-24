/**
 * ยอดค้างรับ-ค้างจ่ายที่ยังไม่ได้ล้าง — **อ่านจากรายการที่ post แล้วใน DB** ไม่ใช่จาก state ของหน้าจอ
 *
 * แหล่งข้อมูลเดียวคือ `v_ledger_posted` (D-107) — ไม่อ่านตาราง `transactions` ตรง
 *
 *   ต้นทาง   = รายการที่ post แล้วโดยไม่มีบรรทัดเงินสด (cash_date ว่าง) และมีบรรทัดบัญชีพักของหมวดนั้น
 *              (บัญชีพักอ่านจาก `accrualCheck()` ในตารางกฎ ไม่ได้ระบุรหัสบัญชีที่นี่)
 *   ประวัติ  = รายการที่ `source_ref` = `<id ต้นทาง>-clr-<n>` (ใบล้างที่ action สร้าง)
 *              **ยอดที่ล้าง = ยอดที่บัญชีพักลดลงในใบนั้น (ยอดเต็ม)** ไม่ใช่ขาเงินสด — ใบที่ถูกหักภาษี ณ ที่จ่าย
 *              ปิดลูกหนี้ 100,000 ด้วยเงินสด 95,000 + ภาษี 5,000 ถ้านับขาเงินสดจะเหลือ "ค้าง" 5,000 ปลอมตลอดไป
 *   ใบที่ถูกกลับรายการ ไม่นับ: ทั้งต้นทางที่ถูกกลับ และใบล้างที่ถูกกลับ (ยอดค้างจึงกลับมาให้ล้างใหม่ได้)
 *
 * **ยอดค้างคงเหลือต้องไม่เกินยอดคงเหลือจริงของบัญชีพัก** (เลขอ้างอิง `-clr-n` เป็นสิ่งที่ *เรา* ตั้ง
 * แต่ยอดคงเหลือเป็นความจริงของบัญชี) — ลูกหนี้ถูกลดได้หลายทางที่เราไม่รู้จัก: ลงใบรับชำระเอง (`inv.collect_rent`)
 * · ตัดหนี้สูญ · ปรับปรุง ถ้านับแต่ใบที่มีเลขอ้างอิง แท็บจะยังโชว์ว่าค้างทั้งที่ลูกหนี้เป็นศูนย์แล้ว
 * ผู้ใช้กดยืนยันซ้ำ → ลูกหนี้ติดลบและเงินสดเพิ่มที่ไม่เคยเข้าบัญชี
 *   - รวมยอดบัญชีพักต่อ (ผู้ถือ, บัญชีพัก) แล้วเทียบกับผลรวมยอดค้างตามเลขอ้างอิงของทุกต้นทางในกลุ่ม
 *   - ถ้ายอดจริงต่ำกว่า = มีการลดนอกแท็บ → ถือว่า **ต้นทางเก่าสุดถูกล้างก่อน** (FIFO) จนยอดรวมเท่ายอดจริง
 *   - กลุ่มรวมระดับผู้ถือ+บัญชี (ไม่แยกทรัพย์/คู่ค้า) โดยตั้งใจ: ใบรับชำระที่ผู้ใช้ลงเองอาจไม่ผูกทรัพย์
 *     เหมือนต้นทาง ถ้าแยกละเอียดกว่านี้ใบนั้นจะหลุดการนับ = ช่องเงินสดผีเดิม · ข้อแลก: ถ้าลดนอกแท็บ
 *     ของคนละคู่ค้าในกลุ่มเดียวกัน ระบบเลือกต้นทางผิดใบ (แต่ยอดรวมถูกเสมอ และลูกหนี้ไม่มีทางติดลบ)
 *
 * ไฟล์นี้เป็นฟังก์ชันล้วน (ไม่แตะ DB) เพื่อเทสต์ได้ — ตัวอ่าน DB อยู่ที่ `pending-accruals-server.ts`
 * **ไม่คำนวณคู่บัญชี**: จับคู่ "บรรทัดไหนคือยอดค้าง" ด้วยรหัสบัญชีพักจากตารางกฎเท่านั้น
 */

import { coa, isCashAccount } from "@/lib/rules/coa";
import { TX_TYPES, accrualCheck, findSub, type TxTypeKey } from "@/lib/rules/tx-rules";
import type { PostedClearing } from "@/lib/ledger/types";
import type { CoaCodeLookup, LedgerViewRow } from "./ledger-entries";

/** บัญชีพักทุกตัวที่ตารางกฎใช้ตั้งค้างได้ (อ่านจากตารางกฎ ไม่พิมพ์รหัสเอง) */
export function accrualAccountCodes(): string[] {
  const out = new Set<string>();
  for (const sub of TX_TYPES.flatMap((t) => t.subs)) {
    const c = accrualCheck(sub);
    if (c.ok) out.add(c.account);
  }
  return [...out].sort();
}

export type PendingAccrual = {
  /** id ของรายการต้นทาง (transaction) */
  id: string;
  ownerId: string;
  /** บัญชีพักที่ตั้งค้างไว้ (อ่านจากตารางกฎ) — ใช้จับคู่กับใบที่ลดบัญชีพักนี้ */
  account: string;
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
  /** การล้างที่ post แล้วจริงผ่านแท็บยืนยัน เรียงตามลำดับ — `id` คือเลขอ้างอิง (`source_ref`) ของใบล้าง */
  postedClearings: PostedClearing[];
  /**
   * ยอดที่ถูกลดไปแล้ว **นอกแท็บยืนยัน** (ลงใบรับชำระเอง · ตัดหนี้สูญ ฯลฯ) อนุมานจากยอดคงเหลือจริงของบัญชีพัก
   * ต้องส่งให้ engine เป็นประวัติเพิ่มอีกหนึ่งรายการ (`clearedOutsideEntry`) ไม่งั้นล้างซ้ำได้
   */
  clearedOutside: number;
  /** ยอดค้างคงเหลือ = ยอดตั้งค้าง − ที่ล้างผ่านแท็บ − ที่ลดนอกแท็บ */
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
  /** **ทุกบรรทัด** ที่แตะบัญชีพัก (ลูกหนี้/เจ้าหนี้) ของทุกรายการที่ post แล้ว — ใช้หายอดคงเหลือจริง */
  accountLines: LedgerViewRow[];
};

/** ประวัติสมมติที่ส่งให้ engine เพื่อให้ยอดที่ลดนอกแท็บนับเป็น "ล้างแล้ว" */
export const clearedOutsideEntry = (p: Pick<PendingAccrual, "id" | "clearedOutside">): PostedClearing[] =>
  p.clearedOutside > 0 ? [{ id: `${p.id}-outside`, amount: p.clearedOutside }] : [];

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
  const codeOf = (r: LedgerViewRow) => coaCodeById[r.coa_id] ?? "";

  // ---- รายการต้นทาง ----
  type Src = Omit<PendingAccrual, "postedClearings" | "clearedOutside" | "outstanding"> & { createdAt: string };
  const sources: Src[] = [];
  for (const [txnId, lines] of groupBy(rows.candidates, (r) => r.transaction_id)) {
    const head = lines[0];
    if (head.source === "reverse" || reversedIds.has(txnId) || head.cash_date) continue;
    const found = findSub(head.txn_type_code);
    if (!found) continue;
    const check = accrualCheck(found.sub);
    if (!check.ok) continue;
    if (lines.some((l) => isCashAccount(codeOf(l)))) continue;
    const accrualLines = lines.filter((l) => codeOf(l) === check.account);
    if (!accrualLines.length) continue;
    const accrued = round2(Math.abs(accrualLines.reduce((t, l) => t + Number(l.debit) - Number(l.credit), 0)));
    if (!(accrued > 0)) continue;
    sources.push({
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
      account: check.account,
      createdAt: head.created_at,
    });
  }
  const sourceById = new Map(sources.map((s) => [s.id.toLowerCase(), s]));

  // ---- ประวัติการล้างผ่านแท็บ: ต่อรหัสต้นทาง ----
  // ยอด = ยอดที่บัญชีพักของต้นทางลดลงในใบล้าง (ยอดเต็ม) ไม่ใช่ขาเงินสด
  const history = new Map<string, { n: number; id: string; amount: number }[]>();
  for (const [txnId, lines] of groupBy(rows.clearings, (r) => r.transaction_id)) {
    const head = lines[0];
    if (head.source === "reverse" || reversedIds.has(txnId)) continue;
    const parsed = parseClearingRef(head.source_ref);
    const src = parsed ? sourceById.get(parsed.sourceId) : undefined;
    if (!parsed || !src) continue;
    const onAccount = lines.filter((l) => codeOf(l) === src.account);
    if (!onAccount.length) continue;
    const amount = round2(Math.abs(onAccount.reduce((t, l) => t + Number(l.debit) - Number(l.credit), 0)));
    const list = history.get(parsed.sourceId) ?? [];
    list.push({ n: parsed.n, id: head.source_ref as string, amount });
    history.set(parsed.sourceId, list);
  }

  const items = sources.map((s) => {
    const done = (history.get(s.id.toLowerCase()) ?? []).sort((a, b) => a.n - b.n);
    const cleared = round2(done.reduce((t, c) => t + c.amount, 0));
    return {
      s,
      postedClearings: done.map((c) => ({ id: c.id, amount: c.amount })) as PostedClearing[],
      byRef: round2(Math.max(0, s.accruedAmount - cleared)),
      clearedByRef: cleared,
    };
  });

  // ---- เทียบกับยอดคงเหลือจริงของบัญชีพัก ต่อ (ผู้ถือ, บัญชี) ----
  const outside = new Map<string, number>();
  const groups = groupBy(items, (i) => `${i.s.ownerId}|${i.s.account}`);
  for (const [key, members] of groups) {
    const [ownerId, account] = key.split("|");
    const sign = coa(account).type === "asset" ? 1 : -1;
    const balance = Math.max(
      0,
      round2(
        rows.accountLines
          .filter((l) => l.owner_id === ownerId && codeOf(l) === account)
          .reduce((t, l) => t + sign * (Number(l.debit) - Number(l.credit)), 0)
      )
    );
    const totalByRef = round2(members.reduce((t, m) => t + m.byRef, 0));
    let deficit = round2(totalByRef - balance);
    if (deficit <= 0) continue;
    // ลดนอกแท็บ: ถือว่าต้นทางเก่าสุดถูกล้างก่อน
    const ordered = [...members].sort(
      (a, b) => a.s.docDate.localeCompare(b.s.docDate) || a.s.createdAt.localeCompare(b.s.createdAt) || a.s.id.localeCompare(b.s.id)
    );
    for (const m of ordered) {
      if (deficit <= 0) break;
      const take = round2(Math.min(m.byRef, deficit));
      if (take > 0) {
        outside.set(m.s.id, take);
        deficit = round2(deficit - take);
      }
    }
  }

  return items.map(({ s, postedClearings, byRef }) => {
    const clearedOutside = outside.get(s.id) ?? 0;
    const { account: _account, createdAt: _createdAt, ...rest } = s; // eslint-disable-line @typescript-eslint/no-unused-vars
    return { ...rest, account: _account, postedClearings, clearedOutside, outstanding: round2(byRef - clearedOutside) };
  });
}
