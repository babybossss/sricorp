/**
 * ฐานข้อมูลจำลองในหน่วยความจำสำหรับเทสต์ server action — **ไม่ใช่ Postgres**
 *
 * จำลองเท่าที่ action ใช้: `rpc('fn_post_entry')` เขียนแถวลง "สมุด" แล้ว `from('v_ledger_posted')`
 * อ่านออกมาในรูปเดียวกับ view จริง (ระดับบรรทัด) · ใช้พิสูจน์ว่า action ต่อกันถูก (ตั้งค้าง → ล้าง → ยอดเป็นศูนย์)
 * ส่วนที่ DB จริงตอบ (trigger · RLS · คู่บัญชีตามตารางกฎ) พิสูจน์แยกกับ Postgres ในเครื่อง ไม่ใช่ที่นี่
 *
 * ที่จำลองจาก fn_post_entry จริงโดยตั้งใจ (เพื่อให้เทสต์แดงเมื่อ action ส่ง payload ที่ DB จริงจะปฏิเสธ):
 *   - ช่องที่ไม่รู้จักถูกปฏิเสธทั้งใบ · ทุกก้อนต้องสมดุล · มีบรรทัด 11xx ⟺ ต้องมี cash_date
 *   - fingerprint ซ้ำ = replay (ไม่ลงใหม่)
 */
import { COA } from "@/lib/rules/coa";
import type { LedgerViewRow } from "@/lib/db/ledger-entries";
import type { Reference, ReferenceState } from "@/lib/db/reference-types";

export const coaId = (code: string) => `coa-${code}`;
export const COA_BY_ID: Record<string, string> = Object.fromEntries(COA.map((a) => [coaId(a.code), a.code]));

export const OWNER = {
  tk: "11111111-1111-4111-8111-111111111111",
  sutee: "22222222-2222-4222-8222-222222222222",
  corp: "33333333-3333-4333-8333-333333333333",
  planned: "44444444-4444-4444-8444-444444444444",
};
export const BANK = {
  tk: "aaaaaaaa-0000-4000-8000-000000000001",
  tk2: "aaaaaaaa-0000-4000-8000-000000000002",
  sutee: "aaaaaaaa-0000-4000-8000-000000000003",
  corp: "aaaaaaaa-0000-4000-8000-000000000004",
  planned: "aaaaaaaa-0000-4000-8000-000000000005",
  tkClosed: "aaaaaaaa-0000-4000-8000-000000000006",
};
export const ASSET = "bbbbbbbb-0000-4000-8000-000000000001";
export const CONTACT = "cccccccc-0000-4000-8000-000000000001";

export function referenceFixture(): Reference {
  const o = (id: string, code: string, name: string, policy: "corporate_strict" | "personal_flexible", status = "active") => ({
    id, code, name, policy, status, color: null, sortOrder: 1,
  });
  const b = (id: string, ownerId: string, name: string, isActive = true) => ({
    id, ownerId, name, bank: "X", last4: null, isActive, sortOrder: 1,
  });
  return {
    owners: [
      o(OWNER.tk, "TK", "ธนากร", "personal_flexible"),
      o(OWNER.sutee, "SUTEE", "สุธี", "personal_flexible"),
      o(OWNER.corp, "CORP", "SRI Corporation", "corporate_strict"),
      o(OWNER.planned, "HOLD", "SRI Holding", "corporate_strict", "planned"),
    ],
    banks: [
      b(BANK.tk, OWNER.tk, "ธนากร - BBL"),
      b(BANK.tk2, OWNER.tk, "ธนากร - SCB"),
      b(BANK.sutee, OWNER.sutee, "สุธี - TTB"),
      b(BANK.corp, OWNER.corp, "SRI - SCB"),
      b(BANK.planned, OWNER.planned, "Holding - SCB"),
      b(BANK.tkClosed, OWNER.tk, "ธนากร - ปิดแล้ว", false),
    ],
    assets: [{ id: ASSET, code: "A1", name: "คอนโด", ownerId: OWNER.tk, status: "active" }],
    contacts: [{ id: CONTACT, firstName: "ผู้เช่า", lastName: "", types: ["tenant"], phone: "", lineId: "", email: "" }],
    coaCodeById: COA_BY_ID,
  };
}

export const okReference = (): ReferenceState => ({ ok: true, ref: referenceFixture() });

const HEADER = [
  "txn_type_code", "doc_date", "cash_date", "doc_no", "memo", "attachments", "asset_id", "contact_id", "contract_id",
  "owner_reason", "funding_source", "source", "source_ref", "reverses_id", "wht_rate", "wht_amount",
  "wht_certificate_no", "transactions",
];
const TXN = ["owner_id", "counter_owner_id", "intercompany_nature", "lines"];
const LINE = ["coa_code", "bank_account_id", "asset_id", "debit", "credit", "cf_category", "memo"];

type Payload = Record<string, unknown> & { transactions?: Record<string, unknown>[] };

export function createFakeDb() {
  const rows: LedgerViewRow[] = [];
  const rpcCalls: Payload[] = [];
  const seen = new Map<string, string[]>();
  let seq = 0;
  /** ทำให้ rpc ล้ม — ใช้ทดสอบเส้นทาง error ของ DB */
  const control: { rpcError: { message: string; code?: string } | null; rpcData: unknown | "default" } = {
    rpcError: null,
    rpcData: "default",
  };

  const newId = () => `00000000-0000-4000-8000-${String(++seq).padStart(12, "0")}`;

  function post(p: Payload): { transaction_ids: string[]; replayed: boolean } {
    for (const k of Object.keys(p)) if (!HEADER.includes(k)) throw new Error(`ช่องที่ยังไม่รู้จัก ${k}`);
    const txns = p.transactions ?? [];
    const fp = JSON.stringify(p);
    const prev = seen.get(fp);
    if (prev) return { transaction_ids: prev, replayed: true };

    let hasCash = false;
    for (const t of txns) {
      for (const k of Object.keys(t)) if (!TXN.includes(k)) throw new Error(`ช่อง txn ที่ยังไม่รู้จัก ${k}`);
      const lines = (t.lines as Record<string, unknown>[]) ?? [];
      let dr = 0, cr = 0;
      for (const l of lines) {
        for (const k of Object.keys(l)) if (!LINE.includes(k)) throw new Error(`ช่องบรรทัดที่ยังไม่รู้จัก ${k}`);
        dr += Number(l.debit);
        cr += Number(l.credit);
        if (/^11\d\d$/.test(String(l.coa_code))) hasCash = true;
      }
      if (Math.round((dr - cr) * 100) !== 0) throw new Error("Money Invariant 1: ไม่สมดุล");
    }
    // ด่านของ DB: ใบที่มีบรรทัด 1800 (ภาษีถูกหัก) ต้องมี wht_amount/wht_rate ที่หัวรายการ และต้องส่งคู่กัน
    const has1800 = txns.some((t) => ((t.lines as Record<string, unknown>[]) ?? []).some((l) => l.coa_code === "1800"));
    if (has1800 && (p.wht_amount == null || p.wht_rate == null)) {
      throw new Error("ใบนี้มีบรรทัดภาษีถูกหัก ณ ที่จ่าย แต่หัวรายการไม่ได้บันทึก wht_amount/wht_rate");
    }
    if ((p.wht_rate == null) !== (p.wht_amount == null)) throw new Error("ต้องส่ง wht_rate และ wht_amount คู่กัน");
    if (hasCash && !p.cash_date) throw new Error("ไม่มี cash_date ทั้งที่มีบรรทัดเงินสด");
    if (!hasCash && p.cash_date) throw new Error("มี cash_date ทั้งที่ไม่มีบรรทัดเงินสด");

    const ids: string[] = [];
    for (const t of txns) {
      const id = newId();
      ids.push(id);
      for (const l of (t.lines as Record<string, unknown>[])) {
        rows.push({
          transaction_id: id,
          owner_id: t.owner_id as string,
          txn_type_code: p.txn_type_code as string,
          doc_date: p.doc_date as string,
          cash_date: (p.cash_date as string | null) ?? null,
          doc_no: null,
          txn_asset_id: (p.asset_id as string) ?? null,
          contact_id: (p.contact_id as string) ?? null,
          counter_owner_id: (t.counter_owner_id as string) ?? null,
          intercompany_nature: (t.intercompany_nature as string) ?? null,
          txn_memo: (p.memo as string) ?? null,
          attachments: (p.attachments as string[]) ?? [],
          source: (p.source as string) ?? "manual",
          source_ref: (p.source_ref as string) ?? null,
          reverses_id: (p.reverses_id as string) ?? null,
          created_at: new Date(2026, 9, 24, 12, 0, seq).toISOString(),
          coa_id: coaId(l.coa_code as string),
          bank_account_id: (l.bank_account_id as string) ?? null,
          debit: Number(l.debit),
          credit: Number(l.credit),
          cf_category: (l.cf_category as string) ?? null,
          line_asset_id: (l.asset_id as string) ?? null,
          line_memo: (l.memo as string) ?? null,
        });
      }
    }
    seen.set(fp, ids);
    return { transaction_ids: ids, replayed: false };
  }

  type Pred = (r: LedgerViewRow) => boolean;
  function from(table: string) {
    if (table !== "v_ledger_posted") throw new Error(`เทสต์นี้อ่านได้เฉพาะ v_ledger_posted ไม่ใช่ ${table} (D-107)`);
    const preds: Pred[] = [];
    let cap = Infinity;
    const q = {
      select: () => q,
      eq: (c: string, v: unknown) => (preds.push((r) => (r as never)[c] === v), q),
      is: (c: string, v: null) => (preds.push((r) => (r as never)[c] === v), q),
      like: (c: string, pat: string) => {
        const re = new RegExp("^" + pat.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/%/g, ".*") + "$");
        preds.push((r) => re.test(String((r as never)[c] ?? "")));
        return q;
      },
      not: (c: string, op: string, v: null) => {
        if (op !== "is") throw new Error("fake รองรับ not(..., 'is', null) เท่านั้น");
        preds.push((r) => (r as never)[c] !== v);
        return q;
      },
      in: (c: string, vals: unknown[]) => (preds.push((r) => vals.includes((r as never)[c])), q),
      limit: (n: number) => ((cap = n), q),
      then: (resolve: (v: { data: LedgerViewRow[]; error: null }) => unknown) =>
        resolve({ data: rows.filter((r) => preds.every((p) => p(r))).slice(0, cap), error: null }),
    };
    return q;
  }

  const client = {
    from,
    rpc: async (fn: string, args: { p_payload: Payload }) => {
      if (fn !== "fn_post_entry") throw new Error(`ไม่รู้จัก rpc ${fn}`);
      rpcCalls.push(args.p_payload);
      if (control.rpcError) return { data: null, error: control.rpcError };
      if (control.rpcData !== "default") return { data: control.rpcData, error: null };
      try {
        return { data: post(args.p_payload), error: null };
      } catch (e) {
        return { data: null, error: { message: e instanceof Error ? e.message : String(e), code: "P0001" } };
      }
    },
  };

  /** ยอดสุทธิ (เดบิต − เครดิต) ของบัญชีหนึ่งรหัส ทุกรายการในสมุด */
  const balance = (code: string, ownerId?: string) =>
    Math.round(
      rows
        .filter((r) => COA_BY_ID[r.coa_id] === code && (!ownerId || r.owner_id === ownerId))
        .reduce((t, r) => t + Number(r.debit) - Number(r.credit), 0) * 100
    ) / 100;

  return { client, rows, rpcCalls, control, balance };
}

export type FakeDb = ReturnType<typeof createFakeDb>;
