/**
 * ลงยอดตั้งต้นจริง — **เรียกประตู `fn_reimport_opening` ของ DB ทีละผู้ถือ** แล้วสรุปผลให้คนอ่านรู้เรื่อง
 *
 * ไฟล์นี้ไม่ประกอบบรรทัดบัญชี (นั่นคือ `opening-post.ts` ซึ่งเรียก `buildPosting()`) และ **ไม่เขียนตารางตรงๆ**
 * ทุกการเขียนไปผ่าน RPC เดียว ซึ่งทำในธุรกรรมเดียวต่อผู้ถือ: อ่านชุดเดิมจากสมุด → เทียบลายนิ้วมือเนื้อหา →
 * กลับรายการชุดเดิม → ลงชุดใหม่ → กลับรายการล็อตเดิม · เนื้อเหมือนเดิม = ไม่เขียนอะไรเลย
 *
 * แยก "ที่เก็บข้อมูล" (`OpeningStore`) ออกจากลำดับการทำงาน เพื่อให้เทสต์รันลำดับเดียวกันนี้กับ Postgres จริงในเครื่องได้
 * โดยไม่ต้องจำลอง PostgREST — ตัวจริง (`supabaseOpeningStore`) ใช้ session ของผู้ใช้ผ่าน RLS เหมือนทุกหน้า
 *
 * ความเป็นอะตอมมีเป็น **ต่อผู้ถือ** ไม่ใช่ต่อไฟล์: ผู้ถือคนที่ 3 ล้ม คนที่ 1–2 ที่ลงไปแล้วยังอยู่ (และงบดุลของแต่ละคนดุลในตัวเอง)
 * จึงหยุดที่คนแรกที่ล้ม ไม่ไล่ต่อ แล้วบอกว่าใครลงแล้ว/ใครล้ม/ใครยังไม่ได้ทำ — แก้เหตุแล้วอัปโหลดไฟล์เดิมซ้ำได้เลย
 * (คนที่ลงแล้วเนื้อเหมือนเดิม ประตูไม่เขียนอะไรซ้ำ)
 */

import type { SupabaseClient } from "@supabase/supabase-js";
import { TX_TYPES } from "@/lib/rules/tx-rules";
import { humanizeDbError } from "@/lib/db/post-entry";
import { fetchAllPages } from "@/lib/db/paged";
import type { ExistingOpeningEntry, JournalLine } from "./opening";
import type { FxRateRow, OpeningAsset, OwnerPosting } from "./opening-post";

type DbErrorLike = { message?: string; code?: string; details?: string | null; hint?: string | null };

export type OpeningStore = {
  /** ทรัพย์ของผู้ถือเหล่านี้ + ตารางอัตราแลกเปลี่ยน — อ่านสดจาก DB */
  loadLookups(ownerIds: string[]): Promise<{ ok: true; assets: OpeningAsset[]; fxRates: FxRateRow[] } | { ok: false; error: string }>;
  /** ใบยอดตั้งต้นที่ยังมีผลอยู่ในสมุด (ยังไม่ถูกกลับรายการ) — ไว้แสดงว่าครั้งนี้จะ "ใหม่ / ไม่เปลี่ยน / แทนที่" */
  loadExisting(): Promise<{ ok: true; entries: ExistingOpeningEntry[] } | { ok: false; error: string }>;
  /** เรียก `fn_reimport_opening(p_owner, p_payload)` */
  reimport(ownerId: string, payload: unknown): Promise<{ data: unknown; error: DbErrorLike | null }>;
};

/* ---------------------------------------------------------------- ที่เก็บตัวจริง (Supabase) */

type Db = Pick<SupabaseClient, "from" | "rpc">;

/** รหัสหมวด "ยอดยกมา" ทั้งหมด — อ่านจากตารางกฎ (ประเภท opening) */
const openingCodes = (): string[] => TX_TYPES.find((t) => t.key === "opening")?.subs.map((s) => s.code) ?? [];

type ViewRow = {
  transaction_id: string;
  owner_id: string;
  doc_date: string;
  coa_id: string;
  bank_account_id: string | null;
  debit: number | string;
  credit: number | string;
  reverses_id: string | null;
};

export function supabaseOpeningStore(db: Db, coaCodeById: Record<string, string>): OpeningStore {
  return {
    async loadLookups(ownerIds) {
      const [assets, rates] = await Promise.all([
        db.from("assets").select("id, code, name, owner_id, status, currency").in("owner_id", ownerIds),
        db.from("fx_rates").select("currency, rate_date, thb_per_unit"),
      ]);
      if (assets.error) return { ok: false, error: `อ่านทรัพย์ไม่สำเร็จ (${assets.error.message})` };
      if (rates.error) return { ok: false, error: `อ่านตารางอัตราแลกเปลี่ยนไม่สำเร็จ (${rates.error.message})` };
      return {
        ok: true,
        assets: ((assets.data ?? []) as { id: string; code: string; name: string; owner_id: string; status: string; currency: string }[]).map((a) => ({
          id: a.id,
          code: a.code,
          name: a.name,
          ownerId: a.owner_id,
          status: a.status,
          currency: a.currency,
        })),
        fxRates: ((rates.data ?? []) as { currency: string; rate_date: string; thb_per_unit: number | string }[]).map((r) => ({
          currency: r.currency,
          rateDate: r.rate_date,
          thbPerUnit: Number(r.thb_per_unit),
        })),
      };
    },

    async loadExisting() {
      const fetched = await fetchAllPages<ViewRow>(
        () =>
          db
            .from("v_ledger_posted")
            .select("transaction_id, owner_id, doc_date, coa_id, bank_account_id, debit, credit, reverses_id")
            .in("txn_type_code", openingCodes())
            .order("line_id", { ascending: true }) as never
      );
      if (!fetched.ok) return { ok: false, error: `อ่านยอดตั้งต้นเดิมในสมุดไม่สำเร็จ (${fetched.error})` };
      const reversed = new Set(fetched.rows.filter((r) => r.reverses_id).map((r) => r.reverses_id!));
      const byTxn = new Map<string, ExistingOpeningEntry>();
      for (const r of fetched.rows) {
        if (r.reverses_id || reversed.has(r.transaction_id)) continue;
        const code = coaCodeById[r.coa_id];
        if (!code) continue;
        const e = byTxn.get(r.transaction_id) ?? { txnId: r.transaction_id, ownerId: r.owner_id, docDate: r.doc_date, lines: [] as JournalLine[] };
        e.lines.push({ coaCode: code, bankAccountId: r.bank_account_id, debit: Number(r.debit), credit: Number(r.credit) });
        byTxn.set(r.transaction_id, e);
      }
      return { ok: true, entries: [...byTxn.values()] };
    },

    async reimport(ownerId, payload) {
      const { data, error } = await db.rpc("fn_reimport_opening", { p_owner: ownerId, p_payload: payload });
      return { data, error };
    },
  };
}

/* ---------------------------------------------------------------- ข้อความ */

/**
 * ข้อความตอนที่ DB ปฏิเสธเพราะมีรายการอื่นอ้างยอดเดิมไปแล้ว (ขาย/เก็บเงิน)
 * ต้องตรงกับ `raise exception` ใน `20261025000009_reimport_opening.sql` — เทสต์เทียบกับไฟล์ migration จริง
 */
export const BLOCKED_BY_REFERENCES_MARKER = "เพราะมีรายการที่อ้างยอดเดิมไปแล้ว";

export function humanizeOpeningError(err: DbErrorLike | null | undefined, ownerName: string): string {
  const raw = (err?.message ?? "").trim();
  if (raw.includes(BLOCKED_BY_REFERENCES_MARKER)) {
    return (
      `${ownerName}: อัปโหลดยอดตั้งต้นใหม่ไม่ได้ เพราะมีการขายหรือเก็บเงิน/จ่ายเงินที่อ้างอิงยอดเดิมไปแล้ว — ` +
      "ถ้าเปลี่ยนยอดย้อนหลัง กำไรหรือยอดค้างที่บันทึกไว้จะผิดโดยไม่มีใบไหนเปลี่ยน · " +
      "ให้ไปกลับรายการใบขาย/ใบรับชำระเหล่านั้นที่หน้าสมุดบัญชีก่อน แล้วอัปโหลดไฟล์นี้ใหม่ · ยังไม่ได้เปลี่ยนอะไรของผู้ถือคนนี้ " +
      `(รายละเอียดจากระบบ: ${raw})`
    );
  }
  return `${ownerName}: ${humanizeDbError(err)}`;
}

/* ---------------------------------------------------------------- ลำดับการลง */

export type OwnerOutcome = {
  ownerId: string;
  ownerName: string;
  /** posted = ลง/แทนที่แล้ว · unchanged = เนื้อเหมือนเดิม ไม่เขียนอะไร · failed = ล้ม (ผู้ถือคนนี้ไม่เปลี่ยน) · skipped = ยังไม่ได้ทำ */
  status: "posted" | "unchanged" | "failed" | "skipped";
  reversed: number;
  posted: number;
  lots: number;
  message?: string;
};

export type OpeningRunResult = { results: OwnerOutcome[]; allOk: boolean };

const num = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) ? v : NaN);

export async function runOpeningImport(owners: OwnerPosting[], store: OpeningStore): Promise<OpeningRunResult> {
  const results: OwnerOutcome[] = [];
  let stopped = false;
  for (const o of owners) {
    const base = { ownerId: o.ownerId, ownerName: o.ownerName, reversed: 0, posted: 0, lots: 0 };
    if (stopped) {
      results.push({ ...base, status: "skipped", message: "ยังไม่ได้ทำ — หยุดไว้เพราะผู้ถือก่อนหน้าล้ม (แก้เหตุแล้วอัปโหลดไฟล์เดิมซ้ำได้ คนที่ลงแล้วจะไม่ถูกลงซ้ำ)" });
      continue;
    }
    let out;
    try {
      out = await store.reimport(o.ownerId, o.payload);
    } catch (e) {
      out = { data: null, error: { message: e instanceof Error ? e.message : String(e) } };
    }
    if (out.error) {
      results.push({ ...base, status: "failed", message: humanizeOpeningError(out.error, o.ownerName) });
      stopped = true;
      continue;
    }
    const d = out.data as { changed?: unknown; reversed?: unknown; posted?: unknown; lots?: unknown } | null;
    if (!d || typeof d.changed !== "boolean") {
      results.push({
        ...base,
        status: "failed",
        message: `${o.ownerName}: ฐานข้อมูลตอบกลับไม่ครบ — ยังยืนยันไม่ได้ว่าลงสมุดแล้วหรือไม่ ให้เปิดหน้าสมุดบัญชีตรวจก่อนอัปโหลดซ้ำ`,
      });
      stopped = true;
      continue;
    }
    if (!d.changed) {
      results.push({ ...base, status: "unchanged", message: `${o.ownerName}: เนื้อหาเหมือนเดิมทุกตัวเลข — ไม่ได้ลงรายการใหม่และไม่ได้กลับรายการอะไร` });
      continue;
    }
    const posted = num(d.posted);
    const lots = num(d.lots);
    // ตอบว่าเปลี่ยนแล้ว ต้องลงครบตามที่ส่งไป — ไม่ครบ = บอกตรงๆ ไม่ใช่รายงานว่าสำเร็จ
    if (posted !== o.payload.entries.length || lots !== o.payload.lots.length) {
      results.push({
        ...base,
        status: "failed",
        message: `${o.ownerName}: ฐานข้อมูลบอกว่าลง ${d.posted} ใบ ${d.lots} ล็อต แต่ส่งไป ${o.payload.entries.length} ใบ ${o.payload.lots.length} ล็อต — ให้ตรวจสมุดบัญชีก่อนอัปโหลดซ้ำ`,
      });
      stopped = true;
      continue;
    }
    results.push({ ...base, status: "posted", reversed: num(d.reversed) || 0, posted, lots });
  }
  return { results, allOk: results.every((r) => r.status === "posted" || r.status === "unchanged") };
}
