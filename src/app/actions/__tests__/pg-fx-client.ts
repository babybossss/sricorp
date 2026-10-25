/**
 * ตัวแทน PostgREST สำหรับเทสต์ที่เขียน/ลบ `fx_rates` ผ่าน action ตัวจริง กับ Postgres จริง (role authenticated · RLS บังคับ)
 * select/order/limit/rpc ใช้ของกลาง (`pg-client.ts`) · insert().select().single() และ delete().eq().eq().select() เขียนที่นี่
 * รหัส error จำลองจากข้อความของ Postgres (PostgREST จริงคืน SQLSTATE มาให้ตรงๆ)
 */
import { SqlError, type TestDb } from "@/lib/db/import/__tests__/pg-harness";
import { pgClient } from "@/lib/db/import/__tests__/pg-client";

const lit = (v: unknown) => (v === null || v === undefined ? "null" : typeof v === "number" ? String(v) : `'${String(v).replace(/'/g, "''")}'`);
const codeOf = (m: string) =>
  /row-level security|permission denied/i.test(m) ? "42501" : /duplicate key/i.test(m) ? "23505" : /foreign key/i.test(m) ? "23503" : /check constraint/i.test(m) ? "23514" : undefined;

export function fxClientFor(db: TestDb, uid: string) {
  const base = pgClient(db, uid);
  return {
    ...base,
    from(table: string) {
      if (table !== "fx_rates") return base.from(table);
      const read = base.from(table);
      return Object.assign(read, {
        insert(row: Record<string, unknown>) {
          const cols = Object.keys(row);
          return {
            select: () => ({
              single: async () => {
                try {
                  const out = db.as(
                    uid,
                    `with i as (insert into sri_os.fx_rates(${cols.join(", ")}) values (${cols.map((c) => lit(row[c])).join(", ")}) returning *) select row_to_json(i) from i;`
                  );
                  return { data: JSON.parse(out), error: null };
                } catch (e) {
                  if (e instanceof SqlError) return { data: null, error: { message: e.message, code: codeOf(e.message) } };
                  throw e;
                }
              },
            }),
          };
        },
        delete() {
          const where: string[] = [];
          const q = {
            eq: (c: string, v: unknown) => (where.push(`${c} = ${lit(v)}`), q),
            select: async () => {
              try {
                const out = db.as(uid, `with d as (delete from sri_os.fx_rates where ${where.join(" and ")} returning currency) select coalesce(json_agg(d), '[]'::json) from d;`);
                return { data: JSON.parse(out), error: null };
              } catch (e) {
                if (e instanceof SqlError) return { data: null, error: { message: e.message, code: codeOf(e.message) } };
                throw e;
              }
            },
          };
          return q;
        },
      });
    },
  };
}
