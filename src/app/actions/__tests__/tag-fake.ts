import { ctx } from "./ctx";

/**
 * ครอบ DB จำลองด้วย "สัญญาฝั่ง DB ตาม ADR 0002/0003" — ฝั่ง DB จริงกำลังสร้างแยก จึงยังเรียกของจริงไม่ได้
 * (แบบเดียวกับที่ balance-move.test.ts ครอบ rpc)
 *
 *   ตาราง   tag_kinds · tags · transaction_tags        (อ่านตาม session)
 *   rpc     fn_reallocate_tags(p_transaction_id, p_kind, p_weights, p_reason)
 *   rpc     fn_post_entry รับ tag_ids / tag_weights เพิ่ม
 *
 * `migrated = false` จำลอง DB ที่ยังไม่ได้ลง migration: ตาราง/ฟังก์ชันหาไม่เจอ (รหัสเดียวกับ PostgREST)
 * และ fn_post_entry ปฏิเสธช่อง tag_* ด้วยข้อความ "มีช่องที่ยังไม่รู้จัก" เหมือนประตูตัวจริงที่ลงอยู่
 *
 * ด่านใน fake เขียนแยกจาก lib/tags โดยตั้งใจ (นับหน่วยไมโครด้วย Math.round ธรรมดา) เพื่อไม่ให้เทสต์วนกลับมาพิสูจน์ตัวเอง
 */
export const KIND = { project: "project", label: "label" } as const;
export const TAG = {
  p1: "10000000-0000-4000-8000-000000000001",
  p2: "10000000-0000-4000-8000-000000000002",
  p3: "10000000-0000-4000-8000-000000000003",
  pOff: "10000000-0000-4000-8000-000000000009",
  l1: "20000000-0000-4000-8000-000000000001",
  l2: "20000000-0000-4000-8000-000000000002",
  ghostKind: "30000000-0000-4000-8000-000000000001",
};
export const TXN = "99999999-0000-4000-8000-000000000001";

type Row = Record<string, unknown>;
type Err = { code?: string; message: string } | null;

export function installTagDb(opts: { migrated?: boolean; postGateKnowsTags?: boolean } = {}) {
  const state = {
    migrated: opts.migrated ?? true,
    postGateKnowsTags: opts.postGateKnowsTags ?? true,
    kinds: [
      { key: "project", name_th: "โปรเจกต์", allows_multi: true, aggregate_note_th: "ยอดที่แตะ tag นี้ บวกข้าม tag ไม่ได้ ........", requires_allocation: true, allocation_note_th: "ส่วนแบ่งของโปรเจกต์นี้ ........", sort_order: 10, is_active: true },
      { key: "label", name_th: "ป้ายกำกับ", allows_multi: true, aggregate_note_th: "ยอดที่แตะ tag นี้ บวกข้าม tag ไม่ได้ ........", requires_allocation: false, allocation_note_th: null, sort_order: 20, is_active: true },
    ] as Row[],
    tags: [
      { id: TAG.p1, kind: "project", code: "iris-235", name_th: "ไอริส 235", is_active: true, color_token: "brand" },
      { id: TAG.p2, kind: "project", code: "bangsaen", name_th: "บางแสน", is_active: true, color_token: null },
      { id: TAG.p3, kind: "project", code: "lotus", name_th: "โลตัส", is_active: true, color_token: null },
      { id: TAG.pOff, kind: "project", code: "old", name_th: "โครงการเก่า", is_active: false, color_token: null },
      { id: TAG.l1, kind: "label", code: "tax", name_th: "ภาษี", is_active: true, color_token: null },
      { id: TAG.l2, kind: "label", code: "audit", name_th: "ตรวจสอบ", is_active: true, color_token: null },
      { id: TAG.ghostKind, kind: "mystery", code: "x", name_th: "ไม่รู้ชนิด", is_active: true, color_token: null },
    ] as Row[],
    links: [] as Row[],
    reallocCalls: [] as { fn: string; args: Record<string, unknown> }[],
    postTagFields: [] as Row[],
    /** ทำให้ rpc/from ล้ม */
    reallocReply: null as null | { data: unknown; error: Err } | "throw",
    /** ฟังก์ชันที่คืนรายชื่อชนิดที่ fn_post_entry รับได้ · "missing" = ฟังก์ชันยังไม่มี · "throw" = ล้ม · อื่นๆ = คำตอบดิบ */
    acceptedKinds: ["project", "label"] as unknown,
    gateCalls: 0,
  };

  const missing = (what: string): { data: null; error: Err } => ({
    data: null,
    error: { code: what === "fn" ? "PGRST202" : "PGRST205", message: what === "fn" ? "Could not find the function sri_os.fn_reallocate_tags in the schema cache" : "Could not find the table 'sri_os.tags' in the schema cache" },
  });

  const origFrom = ctx.db.client.from;
  const origRpc = ctx.db.client.rpc;

  function query(rows: Row[]) {
    const preds: ((r: Row) => boolean)[] = [];
    let cols: string[] | null = null;
    const q = {
      select: (c: string) => ((cols = c.split(",").map((x) => x.trim())), q),
      eq: (c: string, v: unknown) => (preds.push((r) => r[c] === v), q),
      is: (c: string, v: null) => (preds.push((r) => (r[c] ?? null) === v), q),
      order: () => q,
      then: (resolve: (v: { data: Row[]; error: null }) => unknown) =>
        resolve({ data: rows.filter((r) => preds.every((p) => p(r))).map((r) => (cols ? Object.fromEntries(cols.map((c) => [c, r[c]])) : { ...r })), error: null }),
    };
    return q;
  }

  (ctx.db.client as { from: unknown }).from = (table: string) => {
    if (table === "tag_kinds" || table === "tags" || table === "transaction_tags") {
      if (!state.migrated) {
        const err = missing("table");
        const dead: Record<string, unknown> = {};
        for (const m of ["select", "eq", "is", "order"]) dead[m] = () => dead;
        dead.then = (resolve: (v: unknown) => unknown) => resolve(err);
        return dead;
      }
      return query(table === "tag_kinds" ? state.kinds : table === "tags" ? state.tags : state.links);
    }
    return (origFrom as (t: string) => unknown)(table);
  };

  const sumMicro = (w: Record<string, unknown>) => Object.values(w).reduce<number>((s, x) => s + Math.round(Number(x) * 1_000_000), 0);

  (ctx.db.client as { rpc: unknown }).rpc = async (fn: string, args: Record<string, unknown>) => {
    if (fn === "fn_reallocate_tags") {
      state.reallocCalls.push({ fn, args });
      if (!state.migrated) return missing("fn");
      if (state.reallocReply === "throw") throw new Error("network down");
      if (state.reallocReply) return state.reallocReply;
      const w = args.p_weights as Record<string, unknown>;
      // ด่านเดียวกับ trg_assert_tag_allocation_complete: Σ = 1 พอดี
      if (sumMicro(w) !== 1_000_000) return { data: null, error: { code: "P0001", message: "น้ำหนักรวมไม่ครบ 100% พอดี" } };
      if (!String(args.p_reason ?? "").trim()) return { data: null, error: { code: "P0001", message: "ต้องมีเหตุผล" } };
      return { data: { transaction_ids: [args.p_transaction_id] }, error: null };
    }
    if (fn === "fn_post_entry_accepted_tag_kinds") {
      state.gateCalls++;
      if (state.acceptedKinds === "throw") throw new Error("network down");
      if (state.acceptedKinds === "missing") return { data: null, error: { code: "PGRST202", message: "Could not find the function sri_os.fn_post_entry_accepted_tag_kinds in the schema cache" } };
      return { data: state.acceptedKinds, error: null };
    }
    if (fn === "fn_post_entry") {
      const p = args.p_payload as Row;
      const tagFields = Object.fromEntries(Object.entries(p).filter(([k]) => k === "tag_ids" || k === "tag_weights"));
      if (Object.keys(tagFields).length > 0) {
        if (!state.postGateKnowsTags) {
          ctx.db.rpcCalls.push(p as never);
          return { data: null, error: { code: "P0001", message: `บันทึกรายการไม่ได้: มีช่องที่ยังไม่รู้จัก (${Object.keys(tagFields).join(", ")}) — RPC ปฏิเสธทั้งใบ` } };
        }
        if (tagFields.tag_weights && sumMicro(tagFields.tag_weights as Record<string, unknown>) !== 1_000_000) {
          ctx.db.rpcCalls.push(p as never);
          return { data: null, error: { code: "P0001", message: "น้ำหนักรวมไม่ครบ 100% พอดี" } };
        }
        state.postTagFields.push(tagFields);
        const rest = Object.fromEntries(Object.entries(p).filter(([k]) => k !== "tag_ids" && k !== "tag_weights"));
        return (origRpc as (f: string, a: unknown) => Promise<unknown>)(fn, { p_payload: rest });
      }
    }
    return (origRpc as (f: string, a: unknown) => Promise<unknown>)(fn, args);
  };

  return state;
}
