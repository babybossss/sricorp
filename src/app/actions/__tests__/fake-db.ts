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
import { COA, coa } from "@/lib/rules/coa";
import { accrualAccountCodes } from "@/lib/db/pending-accruals";
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
    id, ownerId, name, bank: "X", last4: null, isActive, sortOrder: 1, currency: "THB",
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
  const fake = { maxRows: 1000 };
  /** `transactions.clears_id` — DB เติมจาก source_ref เท่านั้น (ผู้เรียกตั้งเองไม่ได้) */
  const clears = new Map<string, string>();
  const ACCRUAL = new Set(accrualAccountCodes());
  const REF = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})-clr-[0-9]+$/i;

  /** สำเนาของ fn_accrual_open_sources (20261025000007) — ของค้างที่ยังเปิดอยู่ของผู้ถือในบัญชีพักหนึ่ง */
  function openSources(owner: string, account: string): { src: string; remaining: number }[] {
    const mine = new Map<string, { id: string; rev: string | null; clr: string | null; net: number }>();
    for (const r of rows) {
      if (r.owner_id !== owner || COA_BY_ID[r.coa_id] !== account) continue;
      const m = mine.get(r.transaction_id) ?? { id: r.transaction_id, rev: r.reverses_id, clr: clears.get(r.transaction_id) ?? null, net: 0 };
      m.net += Number(r.debit) - Number(r.credit);
      mine.set(r.transaction_id, m);
    }
    const all = [...mine.values()];
    const isLiab = coa(account).type === "liability";
    return all
      .filter((m) => !m.rev && !m.clr && (isLiab ? m.net < -0.005 : m.net > 0.005))
      .map((s) => {
        const sg = Math.sign(s.net);
        const linked = all.filter((m) => m.clr === s.id);
        const linkedIds = new Set(linked.map((m) => m.id));
        const clr = all.filter((m) => m.clr === s.id || (m.rev && linkedIds.has(m.rev))).reduce((t, m) => t + m.net, 0);
        const rev = all.filter((m) => m.rev === s.id).reduce((t, m) => t + m.net, 0);
        return { src: s.id, remaining: Math.round((Math.abs(s.net) + sg * clr + sg * rev) * 100) / 100 };
      });
  }

  /** สำเนาของ fn_assert_clearing_not_over_for — ยิงกับใบที่ลดบัญชีพัก (ตัดสินจากบัญชี ไม่ใช่จากเลขอ้างอิง) */
  function assertClearingNotOver(newId: string, owner: string, p: Payload, lines: Record<string, unknown>[]) {
    if (p.reverses_id) return;
    const reduced = new Map<string, number>();
    for (const l of lines) {
      const code = String(l.coa_code);
      if (!ACCRUAL.has(code)) continue;
      const v = coa(code).type === "liability" ? Number(l.debit) - Number(l.credit) : Number(l.credit) - Number(l.debit);
      reduced.set(code, (reduced.get(code) ?? 0) + v);
    }
    const accounts = [...reduced].filter(([, v]) => v > 0).map(([c]) => c);
    if (accounts.length === 0) return;
    if (accounts.length > 1) throw new Error("ใบเดียวลดบัญชีพักหลายบัญชีพร้อมกัน");
    const account = accounts[0];

    const ref = (p.source_ref as string | undefined) ?? null;
    const refSrc = ref && REF.test(ref) ? ref.slice(0, 36).toLowerCase() : null;
    let src = refSrc && rows.some((r) => r.transaction_id.toLowerCase() === refSrc) ? refSrc : null;
    if (src) clears.set(newId, src);
    if (!src) {
      if (refSrc) throw new Error(`ใบนี้อ้างเลขอ้างอิงการล้าง "${ref}" แต่ไม่มีรายการต้นทาง ${refSrc} อยู่ในสมุด`);
      const open = openSources(owner, account).filter((o) => o.remaining > 0.005);
      if (open.length === 0) throw new Error(`ใบนี้ลดยอดในบัญชีพัก ${account} ของผู้ถือนี้ แต่ไม่มีรายการต้นทางที่ยังมียอดค้างเหลืออยู่เลย`);
      if (open.length > 1) {
        throw new Error(`ใบนี้ลดยอดในบัญชีพัก ${account} แต่ผู้ถือนี้มีของค้างที่ยังเปิดอยู่ ${open.length} ใบ จึงไม่มีทางรู้ว่าล้างของใบไหน — ต้องระบุเลขอ้างอิงการล้าง`);
      }
      src = open[0].src; // ผูกให้ **เฉพาะการคุมยอด** — คอลัมน์ clears_id ของใบนี้ยังเป็น null (เหมือน SQL)
    }
    const srcOwner = rows.find((r) => r.transaction_id === src)?.owner_id;
    if (srcOwner !== owner) throw new Error("ลิงก์ชี้ไปรายการต้นทางของผู้ถืออีกคน");
  }

  /** หลังใส่แถวของใบใหม่แล้ว: ยอดที่ล้างทั้งหมดของต้นทางห้ามเกินยอดตั้งค้าง (เหมือนส่วนท้ายของ SQL) */
  function assertNotOverAfter(src: string, account: string) {
    const sumOn = (pred: (r: LedgerViewRow) => boolean) =>
      rows.filter((r) => COA_BY_ID[r.coa_id] === account && pred(r)).reduce((t, r) => t + Number(r.debit) - Number(r.credit), 0);
    const accrued = sumOn((r) => r.transaction_id === src || r.reverses_id === src);
    if (Math.round(accrued * 100) === 0) throw new Error("รายการต้นทางที่ลิงก์ชี้ไปไม่มียอดค้างในบัญชีนั้นเลย");
    const linked = new Set([...clears].filter(([, s]) => s === src).map(([t]) => t));
    const cleared = sumOn((r) => linked.has(r.transaction_id) || (!!r.reverses_id && linked.has(r.reverses_id)));
    const sign = Math.sign(accrued);
    const over = -sign * cleared - Math.abs(accrued);
    if (Math.round(over * 100) > 0) {
      throw new Error(`ล้างยอดค้างเกิน: ต้นทาง ${src} ตั้งค้างไว้ ${Math.abs(accrued)} แต่ล้างรวม ${-sign * cleared}`);
    }
  }
  const rpcCalls: Payload[] = [];
  /** การเรียกประตูอัปโหลดยอดตั้งต้นใหม่ (`fn_reimport_opening`) — ตัวจริงอยู่ที่ DB (พิสูจน์กับ Postgres ในเครื่อง) ที่นี่จำลองแค่ว่าถูกเรียกด้วยอะไร */
  const reimportCalls: { p_owner: string; p_payload: { entries: Payload[]; lots: Record<string, unknown>[] } }[] = [];
  const seen = new Map<string, string[]>();
  let seq = 0;
  /** ทำให้ rpc ล้ม — ใช้ทดสอบเส้นทาง error ของ DB */
  const control: {
    rpcError: { message: string; code?: string } | null;
    rpcData: unknown | "default";
    /** ตอบแทนประตูอัปโหลดยอดตั้งต้นใหม่ — ไม่ตั้ง = ตอบว่าลงครบตามที่ส่ง */
    reimport: ((call: { p_owner: string; p_payload: { entries: Payload[]; lots: Record<string, unknown>[] } }) => { data: unknown; error: { message: string; code?: string } | null }) | null;
    /** ตารางที่ RLS ปฏิเสธการเขียน — INSERT = error 42501 · UPDATE/DELETE = ไม่มีแถวถูกแก้ (ตรงกับ PostgREST จริง) */
    denyWrites: Set<string>;
  } = {
    rpcError: null,
    rpcData: "default",
    reimport: null,
    denyWrites: new Set(),
  };
  /** ตารางทั่วไป (ไม่ใช่สมุด) — เท่าที่ action ตั้งค่า/ข้อมูลอ้างอิงใช้ */
  const tables: Record<string, Record<string, unknown>[]> = {
    owners: [], bank_accounts: [], assets: [], contacts: [], chart_of_accounts: [], fx_rates: [],
  };
  /** การเขียนที่ action ยิงมา — ไว้ตรวจว่าส่งอะไรไป (และต้องไม่มี delete) */
  const writes: { table: string; op: "insert" | "update" | "delete"; payload: unknown; denied: boolean }[] = [];
  const BANK_CCY = new Set(["THB", "USD", "JPY", "CNY"]);

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

    // D-092: บัญชีที่ปิดใช้งานแล้วลงรายการใหม่ไม่ได้ (ยกเว้นใบกลับรายการ) — จำลอง fn_assert_bank_account_open
    for (const t of txns) {
      for (const l of (t.lines as Record<string, unknown>[]) ?? []) {
        const bank = tables.bank_accounts.find((b) => b.id === l.bank_account_id);
        if (bank && bank.is_active === false && p.source !== "reverse") {
          throw new Error(`บัญชี "${bank.display_name}" ปิดใช้งานแล้ว ลงรายการใหม่เข้าบัญชีนี้ไม่ได้ (D-092)`);
        }
      }
    }

    const ids: string[] = [];
    try {
    for (const t of txns) {
      const id = newId();
      ids.push(id);
      // ด่านล้างยอดค้างของ DB — ยิงก่อนใส่แถวของใบนี้ (ใบนี้ไม่นับเป็นต้นทาง) ถ้าล้มทั้งคำขอไม่เขียนอะไร
      assertClearingNotOver(id, t.owner_id as string, p, (t.lines as Record<string, unknown>[]) ?? []);
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
    } catch (e) {
      for (let i = rows.length - 1; i >= 0; i--) if (ids.includes(rows[i].transaction_id)) rows.splice(i, 1);
      for (const id of ids) clears.delete(id);
      throw e;
    }

    // หลังใส่แถว: ตรวจเพดานยอดของต้นทางที่ถูกล้าง (ถ้าล้ม ถอนแถวของคำขอนี้ออก = ธุรกรรมถูก rollback)
    try {
      for (const id of ids) {
        const src = clears.get(id);
        if (!src) continue;
        const acct = [...ACCRUAL].find((a) => rows.some((r) => r.transaction_id === id && COA_BY_ID[r.coa_id] === a));
        if (acct) assertNotOverAfter(src, acct);
      }
    } catch (e) {
      for (let i = rows.length - 1; i >= 0; i--) if (ids.includes(rows[i].transaction_id)) rows.splice(i, 1);
      for (const id of ids) clears.delete(id);
      throw e;
    }
    seen.set(fp, ids);
    return { transaction_ids: ids, replayed: false };
  }

  type TRow = Record<string, unknown>;
  function tableFrom(table: string) {
    const store = tables[table];
    let mode: "select" | "insert" | "update" | "delete" = "select";
    let payload: unknown = null;
    const preds: ((r: TRow) => boolean)[] = [];
    const orders: { col: string; asc: boolean }[] = [];
    let cap = Infinity;
    /** คอลัมน์ที่ขอ — PostgREST คืนเฉพาะคอลัมน์ที่ select (ไม่ขอ = ไม่ได้) เทสต์จึงจับ select ที่ลืมคอลัมน์ได้ */
    let sel: string[] | null = null;
    const project = (r: TRow): TRow => (sel ? Object.fromEntries(sel.map((c) => [c, r[c]])) : { ...r });

    function run(): { data: TRow[] | null; error: { message: string; code?: string } | null } {
      const res = run0();
      return res.data ? { data: res.data.map(project), error: res.error } : res;
    }
    function run0(): { data: TRow[] | null; error: { message: string; code?: string } | null } {
      if (mode === "select") {
        const out = store.filter((r) => preds.every((p) => p(r)));
        for (const o of [...orders].reverse()) {
          out.sort((a, b) => {
            const x = a[o.col] as never, y = b[o.col] as never;
            return (x < y ? -1 : x > y ? 1 : 0) * (o.asc ? 1 : -1);
          });
        }
        return { data: out.slice(0, cap).map((r) => ({ ...r })), error: null };
      }
      const denied = control.denyWrites.has(table);
      writes.push({ table, op: mode, payload, denied });
      if (mode === "insert") {
        if (denied) return { data: null, error: { code: "42501", message: `new row violates row-level security policy for table "${table}"` } };
        const row: TRow = { id: newId(), is_active: true, sort_order: 0, currency: "THB", opening_balance: 0, ...(payload as TRow) };
        if (table === "bank_accounts") {
          for (const c of ["owner_id", "bank", "account_name", "display_name"]) {
            if (row[c] == null) return { data: null, error: { code: "23502", message: `null value in column "${c}" violates not-null constraint` } };
          }
          if (!BANK_CCY.has(String(row.currency))) {
            return { data: null, error: { code: "23514", message: 'new row violates check constraint "bank_accounts_currency_allowed"' } };
          }
        }
        store.push(row);
        return { data: [{ ...row }], error: null };
      }
      // update / delete: RLS กรองแถวออกแล้วไม่เหลือ → ไม่ error แต่ไม่มีแถวถูกแตะ
      const hit = denied ? [] : store.filter((r) => preds.every((p) => p(r)));
      if (mode === "update") for (const r of hit) Object.assign(r, payload as TRow);
      else for (const r of hit) store.splice(store.indexOf(r), 1);
      return { data: hit.map((r) => ({ ...r })), error: null };
    }

    const q = {
      select: (cols?: string) => ((sel = cols && cols !== "*" ? cols.split(",").map((c) => c.trim()) : null), q),
      insert: (row: unknown) => ((mode = "insert"), (payload = row), q),
      update: (patch: unknown) => ((mode = "update"), (payload = patch), q),
      delete: () => ((mode = "delete"), q),
      eq: (c: string, v: unknown) => (preds.push((r) => r[c] === v), q),
      in: (c: string, vals: unknown[]) => (preds.push((r) => vals.includes(r[c])), q),
      order: (col: string, o?: { ascending?: boolean }) => (orders.push({ col, asc: o?.ascending !== false }), q),
      limit: (n: number) => ((cap = n), q),
      single: async () => {
        const r = run();
        if (r.error) return { data: null, error: r.error };
        return r.data && r.data.length === 1
          ? { data: r.data[0], error: null }
          : { data: null, error: { code: "PGRST116", message: "JSON object requested, multiple (or no) rows returned" } };
      },
      then: (resolve: (v: ReturnType<typeof run>) => unknown) => resolve(run()),
    };
    return q;
  }

  type Pred = (r: LedgerViewRow) => boolean;
  function from(table: string) {
    if (table in tables) return tableFrom(table);
    if (table !== "v_ledger_posted") throw new Error(`เทสต์นี้อ่านได้เฉพาะ v_ledger_posted และตารางตั้งค่า ไม่ใช่ ${table} (D-107)`);
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
      // ลำดับในหน่วยความจำคงที่อยู่แล้ว (ลำดับที่ลงสมุด) จึงไม่ต้องเรียงจริง
      order: () => q,
      // PostgREST ตัดผลที่ 1,000 แถวต่อคำขอเงียบๆ — จำลองการแบ่งหน้าด้วย range เพื่อให้เทสต์จับโค้ดที่ไม่แบ่งหน้าได้
      range: async (from: number, to: number) => ({
        data: rows.filter((r) => preds.every((p) => p(r))).slice(from, Math.min(to, from + (fake.maxRows - 1)) + 1),
        error: null,
      }),
      limit: (n: number) => ((cap = n), q),
      then: (resolve: (v: { data: LedgerViewRow[]; error: null }) => unknown) =>
        resolve({ data: rows.filter((r) => preds.every((p) => p(r))).slice(0, Math.min(cap, fake.maxRows)), error: null }),
    };
    return q;
  }

  const client = {
    from,
    rpc: async (fn: string, args: { p_payload: Payload }) => {
      if (fn === "fn_reimport_opening") {
        const call = args as unknown as (typeof reimportCalls)[number];
        reimportCalls.push(call);
        if (control.reimport) return control.reimport(call);
        return { data: { changed: true, reversed: 0, posted: call.p_payload.entries.length, lots: call.p_payload.lots.length }, error: null };
      }
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

  return { client, rows, rpcCalls, reimportCalls, control, balance, fake, tables, writes };
}

export type FakeDb = ReturnType<typeof createFakeDb>;
