/**
 * รายการสมุดบัญชี — **อ่านจาก `v_ledger_posted` เท่านั้น** ไม่ใช่ตารางฐาน `transactions` (D-107 ข้อ 1)
 *
 * ตารางฐานยัง `select` ได้อยู่ → ถ้าอ่านตรงจะดึงรายการที่ยกเลิก (void) เข้ามาเงียบๆ
 * และขัดคำสั่งลูกพี่ "ตัดออกจากงบ" · view นี้มีทั้งต้นฉบับและใบกลับรายการ (source = reverse)
 * **ห้ามกรองใบกลับรายการออก** เพราะมันคือขาที่ทำให้ยอดสุทธิเป็นศูนย์ (D-097)
 *
 * view เป็นระดับบรรทัด → ไฟล์นี้จัดกลุ่มกลับเป็นหนึ่งรายการต่อหนึ่ง transaction
 * (ส่วนจัดกลุ่มเป็นฟังก์ชันล้วนแยกไว้ เพื่อเทสต์ได้โดยไม่ต้องมี DB)
 */

import { isCashAccount } from "@/lib/rules/coa";

export type LedgerEntryLine = {
  coaCode: string;
  bankAccountId: string | null;
  assetId: string | null;
  debit: number;
  credit: number;
  cfCategory: string | null;
  memo: string | null;
};

export type LedgerEntry = {
  id: string;
  ownerId: string;
  counterOwnerId: string | null;
  intercompanyNature: string | null;
  subCode: string;
  docDate: string;
  cashDate: string | null;
  docNo: string | null;
  memo: string | null;
  contactId: string | null;
  assetId: string | null;
  attachments: string[];
  source: string;
  reversesId: string | null;
  createdAt: string;
  lines: LedgerEntryLine[];
};

/** แถวดิบจาก `v_ledger_posted` — ตั้งชื่อตามคอลัมน์ของ view (20261020000001) */
export type LedgerViewRow = {
  transaction_id: string;
  owner_id: string;
  txn_type_code: string;
  doc_date: string;
  cash_date: string | null;
  doc_no: string | null;
  txn_asset_id: string | null;
  contact_id: string | null;
  counter_owner_id: string | null;
  intercompany_nature: string | null;
  txn_memo: string | null;
  attachments: string[] | null;
  source: string;
  source_ref: string | null;
  reverses_id: string | null;
  created_at: string;
  coa_id: string;
  bank_account_id: string | null;
  debit: number | string;
  credit: number | string;
  cf_category: string | null;
  line_asset_id: string | null;
  line_memo: string | null;
};

/** ที่มาของรหัสบัญชีที่ view เก็บเป็น uuid — หาไม่เจอ = แสดงตามจริงว่าไม่รู้จัก ไม่เดา */
export type CoaCodeLookup = Record<string, string>;

export const UNKNOWN_COA = "????";

/**
 * จัดบรรทัดของ view กลับเป็นรายการ — คงลำดับที่ query ส่งมา (ใหม่ → เก่า)
 *
 * `truncated` = query ถูกตัดที่เพดานบรรทัด → รายการสุดท้ายอาจได้บรรทัดไม่ครบ
 * จึง **ทิ้งรายการสุดท้าย** แทนที่จะโชว์รายการที่เดบิตไม่เท่าเครดิต (ตัวเลขผิดเงียบๆ)
 */
export function groupLedgerRows(rows: LedgerViewRow[], coaCodeById: CoaCodeLookup, truncated = false): LedgerEntry[] {
  const byId = new Map<string, LedgerEntry>();
  for (const r of rows) {
    let e = byId.get(r.transaction_id);
    if (!e) {
      e = {
        id: r.transaction_id,
        ownerId: r.owner_id,
        counterOwnerId: r.counter_owner_id,
        intercompanyNature: r.intercompany_nature,
        subCode: r.txn_type_code,
        docDate: r.doc_date,
        cashDate: r.cash_date,
        docNo: r.doc_no,
        memo: r.txn_memo,
        contactId: r.contact_id,
        assetId: r.txn_asset_id,
        attachments: r.attachments ?? [],
        source: r.source,
        reversesId: r.reverses_id,
        createdAt: r.created_at,
        lines: [],
      };
      byId.set(r.transaction_id, e);
    }
    e.lines.push({
      coaCode: coaCodeById[r.coa_id] ?? UNKNOWN_COA,
      bankAccountId: r.bank_account_id,
      assetId: r.line_asset_id,
      debit: Number(r.debit),
      credit: Number(r.credit),
      cfCategory: r.cf_category,
      memo: r.line_memo,
    });
  }
  const list = [...byId.values()];
  if (truncated && list.length > 0) list.pop();
  return list;
}

/**
 * เงินเข้า(+)/ออก(−) ของรายการ จากบรรทัดเงินสด/เงินฝากจริง (11xx) — `null` = ไม่มีเงินเคลื่อน
 * (ค้างรับ-ค้างจ่าย หรือรายการปรับปรุง) · อ่านจากบรรทัดที่บันทึกแล้ว ไม่ได้คำนวณกฎบัญชีใหม่
 */
export function cashNet(entry: Pick<LedgerEntry, "lines">): number | null {
  const cash = entry.lines.filter((l) => isCashAccount(l.coaCode));
  if (!cash.length) return null;
  return Math.round(cash.reduce((t, l) => t + l.debit - l.credit, 0) * 100) / 100;
}

export function entryTotal(entry: Pick<LedgerEntry, "lines">): number {
  return Math.round(entry.lines.reduce((t, l) => t + l.debit, 0) * 100) / 100;
}
