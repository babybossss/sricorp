/**
 * ตัวแทน Supabase client ที่คุยกับ Postgres ในเครื่องจริง (ผ่าน psql) — **แปลคำสั่ง PostgREST เท่าที่โค้ดของเราใช้เป็น SQL**
 *
 * ทำไมไม่ทำ mock ในหน่วยความจำ: เทสต์นี้ต้องพิสูจน์ว่า "คอลัมน์ที่โค้ดขอ" ผ่านด่านคอลัมน์ (GRANT) และ RLS ของผู้ใช้จริง
 * และ `fn_reimport_opening` ที่เรียกคือฟังก์ชันจริง ไม่ใช่สำเนาที่เขียนเอง · ทุกคำสั่งรันเป็น role `authenticated`
 * ของผู้ใช้ที่ระบุ (ธุรกรรมเดียวต่อคำสั่ง) — ไม่ใช่ superuser
 *
 * รองรับ: from(t).select(cols).eq/in/order/limit/range · rpc('fn_reimport_opening' · 'fn_post_entry' · 'fn_asset_cost_basis*')
 * อย่างอื่น = โยก error ทันที (ไม่เดา) เพื่อให้รู้ว่าโค้ดเริ่มใช้คำสั่งที่ตัวแทนนี้ยังไม่ได้พิสูจน์
 */

import { SqlError, type TestDb } from "./pg-harness";

type Result = { data: unknown; error: { message: string; code?: string } | null };

const lit = (v: unknown): string => {
  if (v === null || v === undefined) return "null";
  if (typeof v === "number") return String(v);
  if (typeof v === "boolean") return v ? "true" : "false";
  return `'${String(v).replace(/'/g, "''")}'`;
};
const ident = (s: string): string => {
  if (!/^[a-z_][a-z0-9_]*$/i.test(s)) throw new Error(`ชื่อคอลัมน์/ตารางไม่ปลอดภัย: ${s}`);
  return `"${s}"`;
};

export function pgClient(db: TestDb, uid: string) {
  function from(table: string) {
    let cols = "*";
    const where: string[] = [];
    const order: string[] = [];
    let limit: number | null = null;
    let offset = 0;

    const run = async (): Promise<Result> => {
      const select = cols === "*" ? "*" : cols.split(",").map((c) => ident(c.trim())).join(", ");
      const sql =
        `select coalesce(json_agg(t), '[]'::json) from (select ${select} from sri_os.${ident(table)}` +
        (where.length ? ` where ${where.join(" and ")}` : "") +
        (order.length ? ` order by ${order.join(", ")}` : "") +
        (limit !== null ? ` limit ${limit}` : "") +
        (offset ? ` offset ${offset}` : "") +
        `) t;`;
      try {
        return { data: JSON.parse(db.as(uid, sql) || "[]"), error: null };
      } catch (e) {
        if (e instanceof SqlError) return { data: null, error: { message: e.message } };
        throw e;
      }
    };

    const q = {
      select: (c?: string) => ((cols = c && c !== "*" ? c : "*"), q),
      eq: (c: string, v: unknown) => (where.push(`${ident(c)} = ${lit(v)}`), q),
      in: (c: string, vs: unknown[]) => (where.push(vs.length ? `${ident(c)} in (${vs.map(lit).join(", ")})` : "false"), q),
      order: (c: string, o?: { ascending?: boolean }) => (order.push(`${ident(c)} ${o?.ascending === false ? "desc" : "asc"}`), q),
      limit: (n: number) => ((limit = n), q),
      range: (a: number, b: number) => {
        offset = a;
        limit = b - a + 1;
        return run();
      },
      then: (resolve: (v: Result) => unknown, reject?: (e: unknown) => unknown) => run().then(resolve, reject),
    };
    return q;
  }

  /** rpc ที่โค้ดของเราเรียกจริง — แต่ละตัวบอกวิธีแปลงอาร์กิวเมนต์เป็น SQL (ตัวอื่น = ยังไม่พิสูจน์ จึงโยก error) */
  const jsonb = (v: unknown) => `$sri$${JSON.stringify(v)}$sri$::jsonb`;
  const RPC: Record<string, (a: Record<string, unknown>) => string> = {
    fn_reimport_opening: (a) => `sri_os.fn_reimport_opening(${lit(a.p_owner)}::uuid, ${jsonb(a.p_payload)})`,
    fn_post_entry: (a) => `sri_os.fn_post_entry(${jsonb(a.p_payload)})`,
    // ฟังก์ชันอ่านต้นทุนของทรัพย์ (คืนค่าเดี่ยว: text/numeric) — ห่อ to_json ให้ parse เป็น JSON เหมือน PostgREST
    fn_asset_cost_basis_mode: (a) => `to_json(sri_os.fn_asset_cost_basis_mode(${lit(a.p_asset)}::uuid))`,
    fn_asset_cost_basis: (a) => `to_json(sri_os.fn_asset_cost_basis(${lit(a.p_asset)}::uuid))`,
    fn_asset_revaluation_surplus: (a) => `to_json(sri_os.fn_asset_revaluation_surplus(${lit(a.p_asset)}::uuid))`,
  };

  async function rpc(fn: string, args: Record<string, unknown>): Promise<Result> {
    const build = RPC[fn];
    if (!build) throw new Error(`ตัวแทน PostgREST ยังไม่รองรับ rpc ${fn}`);
    try {
      return { data: JSON.parse(db.as(uid, `select ${build(args)}::text;`)), error: null };
    } catch (e) {
      if (e instanceof SqlError) return { data: null, error: { message: e.message, code: "P0001" } };
      throw e;
    }
  }

  return { from, rpc };
}
