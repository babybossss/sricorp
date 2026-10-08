/**
 * ตัวอ่าน + ตัวเทียบ "ตารางกฎฝั่งโค้ด" กับ "สิ่งที่ migration สร้างไว้ในฐานข้อมูล"
 * — ฟังก์ชันบริสุทธิ์ ไม่แตะ fs ไม่ต่อ DB (ตัวอ่านจากโฟลเดอร์อยู่ที่ท้ายไฟล์)
 *
 * ครอบสองตารางกฎที่ `sync:rules` เคยไม่ครอบ และเป็นต้นเหตุจริงที่เคยทำให้
 * **ผังบัญชีใน DB ขาด 3 รหัส จนรายการข้ามผู้ถือถูกปฏิเสธโดยไม่มีอะไรจับได้**
 *
 *   1. `src/lib/rules/coa.ts`          → ตาราง `chart_of_accounts`
 *   2. `src/lib/rules/intercompany.ts` → ฟังก์ชัน `fn_intercompany_pairs()`
 *
 * ปรัชญาเดียวกับ `src/lib/assets/draft-whitelist.ts`:
 *   **อ่านไม่ออก = พัง** ห้ามคืนชุดว่าง เพราะชุดว่างทำให้การเทียบ "ผ่าน"
 *   โดยไม่ได้ตรวจอะไร ซึ่งแย่กว่าไม่มีเครื่องตรวจ (ให้ความมั่นใจผิดๆ)
 *
 * ไฟล์นี้อยู่ใน `scripts/` ไม่ใช่ `src/lib/` โดยตั้งใจ — มันอ่าน **ไฟล์ migration**
 * ไม่ใช่กฎบัญชี · โค้ดที่รันในเบราว์เซอร์ไม่ควร import อะไรจากที่นี่
 */

import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

import type { CoaAccount } from "../src/lib/rules/coa";
import type { IntercompanyNature, IntercompanyRule } from "../src/lib/rules/intercompany";

export class RuleSyncParseError extends Error {}

export type MigrationFile = { name: string; sql: string };

// ============================================================
// ตัวช่วยระดับ SQL
// ============================================================

/**
 * ตัด body ของ dollar-quoted ($$ … $$ / $fn$ … $fn$) ออกทิ้ง
 *
 * ทำก่อนอ่าน seed เสมอ: ตัว body ของ `fn_post_entry` และ guard ท้ายไฟล์
 * มีทั้งคำว่า `insert into ... chart_of_accounts` และรหัสบัญชีในข้อความ error
 * ถ้าไม่ตัดออก ตัวอ่านจะนับคำในคอมเมนต์/ข้อความเป็นแถว seed
 */
export function stripDollarBodies(sql: string): string {
  let out = "";
  let i = 0;
  while (i < sql.length) {
    const open = /\$([A-Za-z_][A-Za-z0-9_]*)?\$/.exec(sql.slice(i));
    if (!open) return out + sql.slice(i);
    const start = i + (open.index ?? 0);
    out += sql.slice(i, start);
    const tag = open[0];
    const close = sql.indexOf(tag, start + tag.length);
    if (close === -1)
      throw new RuleSyncParseError(`พบ ${tag} ที่ไม่มีตัวปิด — ไฟล์ migration ไม่สมบูรณ์ หรือตัวอ่านต้องแก้`);
    i = close + tag.length;
  }
  return out;
}

/** ตัดคอมเมนต์บรรทัด (--) และคอมเมนต์บล็อก โดยไม่แตะข้อความใน single quote */
export function stripSqlComments(sql: string): string {
  let out = "";
  for (let i = 0; i < sql.length; ) {
    const ch = sql[i];
    if (ch === "'") {
      const end = findQuoteEnd(sql, i);
      out += sql.slice(i, end);
      i = end;
    } else if (ch === "-" && sql[i + 1] === "-") {
      const nl = sql.indexOf("\n", i);
      i = nl === -1 ? sql.length : nl;
    } else if (ch === "/" && sql[i + 1] === "*") {
      const end = sql.indexOf("*/", i + 2);
      if (end === -1) throw new RuleSyncParseError("คอมเมนต์ /* ไม่มีตัวปิด");
      i = end + 2;
    } else {
      out += ch;
      i += 1;
    }
  }
  return out;
}

/** คืนตำแหน่งถัดจาก quote ปิดของ string ที่เริ่มที่ `from` (รองรับ '' ที่หมายถึง ') */
function findQuoteEnd(sql: string, from: number): number {
  let i = from + 1;
  while (i < sql.length) {
    if (sql[i] === "'") {
      if (sql[i + 1] === "'") i += 2;
      else return i + 1;
    } else i += 1;
  }
  throw new RuleSyncParseError("string literal ไม่มี quote ปิด");
}

/**
 * แตก `('a', 'b', 3), ('c', …)` เป็นอาร์เรย์ของอาร์เรย์ค่า
 * รองรับวงเล็บและ comma ที่อยู่ **ใน** string (ชื่อบัญชีไทยมีวงเล็บจริง เช่น
 * "ค่ารีโนเวท (บันทึกเป็นทุน)") — regex ธรรมดาอ่านตรงนี้ผิดแน่
 * เจอค่าที่ไม่ใช่ literal ง่ายๆ (ฟังก์ชัน / นิพจน์) → พัง ไม่เดา
 */
export function parseValueTuples(src: string): string[][] {
  const tuples: string[][] = [];
  let i = 0;
  while (i < src.length) {
    while (i < src.length && /[\s,]/.test(src[i])) i += 1;
    if (i >= src.length) break;
    if (src[i] !== "(") break; // จบรายการ values แล้ว (เช่นเจอ `on conflict`)
    i += 1;
    const vals: string[] = [];
    let raw = "";                        // ส่วนที่อยู่นอก quote (ต้องเป็นช่องว่างถ้ามี literal)
    let lit: string | null = null;       // เนื้อใน quote (null = ค่านี้ไม่ใช่ string literal)
    let depth = 0;
    const flush = () => {
      // `'asset'::sri_os.coa_type` = literal ที่ cast ชนิด → ค่าคือ literal นั้น
      // อย่างอื่น (ต่อสตริง / เรียกฟังก์ชัน) อ่านไม่ครบ → พัง ไม่ใช่เก็บค่าครึ่งเดียว
      if (lit !== null && !/^(?:::\s*[A-Za-z_][A-Za-z0-9_.]*(?:\[\s*\])?)?$/.test(raw.trim()))
        throw new RuleSyncParseError(
          `ค่าใน values เป็นนิพจน์ที่ตัวอ่านยังไม่รองรับ ("${(lit + raw).slice(0, 40)}") — แก้ตัวอ่านแทนการเดา`
        );
      vals.push(lit !== null ? lit : raw.trim());
      raw = "";
      lit = null;
    };
    for (;;) {
      if (i >= src.length) throw new RuleSyncParseError("tuple ของ values ไม่มีวงเล็บปิด");
      const ch = src[i];
      if (ch === "'") {
        const end = findQuoteEnd(src, i);
        lit = (lit ?? "") + src.slice(i + 1, end - 1).replace(/''/g, "'");
        i = end;
        continue;
      }
      if (ch === "(") depth += 1;
      if (ch === ")" && depth > 0) depth -= 1;
      else if (ch === ")" || (ch === "," && depth === 0)) {
        flush();
        i += 1;
        if (ch === ")") break;
        continue;
      }
      raw += ch;
      i += 1;
    }
    tuples.push(vals);
  }
  return tuples;
}

// ============================================================
// 1 · ผังบัญชี — src/lib/rules/coa.ts ↔ chart_of_accounts
// ============================================================

export type CoaRow = { code: string; nameTh: string; nameEn: string; type: string };

const COA_COLS = ["code", "name_th", "name_en", "type"] as const;

/**
 * ไล่คำสั่งที่แตะ `chart_of_accounts` ในไฟล์เดียว แล้วคืน "ผลที่ทำกับตาราง"
 * ตามลำดับที่เจอ · `null` = ไฟล์นี้ไม่แตะผังบัญชีเลย
 */
export type CoaOp =
  | { kind: "upsert"; rows: CoaRow[] }
  | { kind: "deleteAll" }
  | { kind: "deleteCodes"; codes: string[] };

export function coaOpsFromSql(sql: string): CoaOp[] | null {
  const clean = stripSqlComments(stripDollarBodies(sql));
  const ops: CoaOp[] = [];
  const re = /(insert\s+into|delete\s+from)\s+(?:sri_os\.)?chart_of_accounts\b/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(clean))) {
    const rest = clean.slice(m.index + m[0].length);
    if (/^insert/i.test(m[1])) ops.push({ kind: "upsert", rows: parseCoaInsert(rest) });
    else ops.push(parseCoaDelete(rest));
  }
  if (ops.length === 0) {
    // ไม่มีคำสั่งที่อ่านได้ แต่มีคำว่า chart_of_accounts อยู่ในคำสั่ง DML = รูปแบบเปลี่ยน
    if (/\b(?:insert\s+into|delete\s+from)\s+(?:sri_os\.)?chart_of_accounts\b/i.test(clean))
      throw new RuleSyncParseError("พบคำสั่งที่แตะ chart_of_accounts แต่อ่านรูปแบบไม่ออก — แก้ตัวอ่าน อย่าปล่อยผ่าน");
    return null;
  }
  return ops;
}

function parseCoaInsert(rest: string): CoaRow[] {
  const head = /^\s*\(([^)]*)\)\s*values\b/i.exec(rest);
  if (!head)
    throw new RuleSyncParseError(
      "insert into chart_of_accounts ต้องระบุชื่อคอลัมน์แล้วตามด้วย values (…) — รูปแบบอื่น (insert … select) ตัวอ่านยังไม่รองรับ"
    );
  const cols = head[1].split(",").map((s) => s.trim().toLowerCase());
  for (const need of COA_COLS)
    if (!cols.includes(need))
      throw new RuleSyncParseError(`insert into chart_of_accounts ไม่มีคอลัมน์ ${need} — เทียบผังบัญชีไม่ได้`);

  const body = rest.slice((head.index ?? 0) + head[0].length);
  const tuples = parseValueTuples(body);
  if (tuples.length === 0) throw new RuleSyncParseError("insert into chart_of_accounts อ่านได้ 0 แถว");
  return tuples.map((vals) => {
    if (vals.length !== cols.length)
      throw new RuleSyncParseError(`แถวของ chart_of_accounts มี ${vals.length} ค่า แต่มี ${cols.length} คอลัมน์`);
    const pick = (c: string) => vals[cols.indexOf(c)];
    const row = { code: pick("code"), nameTh: pick("name_th"), nameEn: pick("name_en"), type: pick("type") };
    if (!/^[0-9]{4}$/.test(row.code))
      throw new RuleSyncParseError(`รหัสบัญชี "${row.code}" ไม่ใช่เลขสี่หลัก — ตัวอ่านอ่านคอลัมน์ผิดตำแหน่งหรือ seed ผิด`);
    return row;
  });
}

function parseCoaDelete(rest: string): CoaOp {
  const stmt = rest.slice(0, rest.indexOf(";") === -1 ? rest.length : rest.indexOf(";"));
  if (!/\bwhere\b/i.test(stmt)) return { kind: "deleteAll" };
  const codes = [...stmt.matchAll(/'([0-9]{4})'/g)].map((x) => x[1]);
  if (codes.length === 0)
    throw new RuleSyncParseError(
      `delete from chart_of_accounts ที่มี where แต่อ่านรหัสไม่ออก ("${stmt.trim().slice(0, 60)}") — แก้ตัวอ่าน อย่าเดาว่าไม่ลบอะไร`
    );
  return { kind: "deleteCodes", codes };
}

/** สภาพผังบัญชีหลัง replay migration ทุกไฟล์เรียงตามชื่อ (เก่า → ใหม่) */
export function effectiveCoa(files: readonly MigrationFile[]): { rows: Map<string, CoaRow>; sources: string[] } {
  const rows = new Map<string, CoaRow>();
  const sources: string[] = [];
  for (const f of [...files].sort((a, b) => a.name.localeCompare(b.name))) {
    let ops: CoaOp[] | null;
    try {
      ops = coaOpsFromSql(f.sql);
    } catch (e) {
      throw new RuleSyncParseError(`${f.name}: ${e instanceof Error ? e.message : String(e)}`);
    }
    if (!ops) continue;
    sources.push(f.name);
    for (const op of ops) {
      if (op.kind === "deleteAll") rows.clear();
      else if (op.kind === "deleteCodes") for (const c of op.codes) rows.delete(c);
      else for (const r of op.rows) rows.set(r.code, r);
    }
  }
  if (rows.size === 0)
    throw new RuleSyncParseError(
      `อ่าน migration ${files.length} ไฟล์แล้วได้ผังบัญชี 0 รหัส — ปฏิเสธการเทียบ (ชุดว่างทำให้ผ่านโดยไม่ตรวจอะไร)`
    );
  return { rows, sources };
}

export type CoaDiff = {
  /** โค้ดมี แต่ migration ไม่มี → **เงินพัง**: ผู้ใช้กดบันทึกแล้วถูกปฏิเสธ */
  missingInDb: string[];
  /** migration มี แต่โค้ดไม่มี → เตือน (บัญชีเก่าที่เลิกใช้แล้วแต่ยังมีรายการอ้างอยู่) */
  extraInDb: string[];
  /** มีทั้งสองที่แต่เนื้อไม่ตรง (ประเภท/ชื่อ) */
  mismatched: { code: string; field: string; ts: string; db: string }[];
};

export function diffCoa(ts: readonly CoaAccount[], db: Map<string, CoaRow>): CoaDiff {
  if (db.size === 0) throw new RuleSyncParseError("ผังบัญชีฝั่ง migration ว่าง — ปฏิเสธการเทียบ");
  const tsCodes = new Set(ts.map((c) => c.code));
  const mismatched: CoaDiff["mismatched"] = [];
  for (const c of ts) {
    const r = db.get(c.code);
    if (!r) continue;
    if (r.type !== c.type) mismatched.push({ code: c.code, field: "type", ts: c.type, db: r.type });
    if (r.nameTh !== c.nameTh) mismatched.push({ code: c.code, field: "name_th", ts: c.nameTh, db: r.nameTh });
    if (r.nameEn !== c.nameEn) mismatched.push({ code: c.code, field: "name_en", ts: c.nameEn, db: r.nameEn });
  }
  return {
    missingInDb: ts.filter((c) => !db.has(c.code)).map((c) => c.code).sort(),
    extraInDb: [...db.keys()].filter((c) => !tsCodes.has(c)).sort(),
    mismatched,
  };
}

/** ชื่อบัญชีต่างกัน = รายงานอ่านชื่อไม่ตรงกัน แต่ไม่ทำให้ตัวเลขผิด → เตือน · ที่เหลือ = พัง */
export const coaOk = (d: CoaDiff) =>
  d.missingInDb.length === 0 && d.mismatched.filter((m) => m.field === "type").length === 0;

export function describeCoaDiff(d: CoaDiff): string {
  const out: string[] = [];
  if (d.missingInDb.length)
    out.push(
      `ERROR: coa.ts มีรหัสที่ migration ยังไม่ได้ seed: ${d.missingInDb.join(", ")} → ` +
        "รายการที่ใช้รหัสนี้จะถูกปฏิเสธตอนผู้ใช้กดบันทึก · สร้าง migration ด้วย `npm run sync:rules`"
    );
  const types = d.mismatched.filter((m) => m.field === "type");
  if (types.length)
    out.push(
      `ERROR: ประเภทบัญชีไม่ตรงกัน: ${types
        .map((m) => `${m.code} (โค้ด=${m.ts} · migration=${m.db})`)
        .join(", ")} → งบดุล/งบกำไรขาดทุนจัดบรรทัดผิด`
    );
  const names = d.mismatched.filter((m) => m.field !== "type");
  if (names.length)
    out.push(
      `WARN: ชื่อบัญชีไม่ตรงกัน ${names.length} ช่อง: ${names
        .slice(0, 5)
        .map((m) => `${m.code}.${m.field}`)
        .join(", ")}${names.length > 5 ? " …" : ""}`
    );
  if (d.extraInDb.length) out.push(`WARN: migration มีรหัสที่ coa.ts ไม่มี: ${d.extraInDb.join(", ")}`);
  return out.join("\n");
}

// ============================================================
// 2 · คู่บัญชีระหว่างกัน — intercompany.ts ↔ fn_intercompany_pairs()
// ============================================================

export type PairRow = { nature: string; payerCoa: string; receiverCoa: string };

const PAIRS_FN = "fn_intercompany_pairs";

/**
 * อ่าน `values (nature, payer, receiver)` จาก body ของ `fn_intercompany_pairs()`
 * `null` = ไฟล์นี้ไม่ได้ define ฟังก์ชัน · define แต่อ่านไม่ออก = พัง
 */
export function intercompanyPairsFromSql(sql: string): PairRow[] | null {
  const def = new RegExp(
    `create\\s+(?:or\\s+replace\\s+)?function\\s+(?:sri_os\\.)?${PAIRS_FN}\\s*\\(\\s*\\)[\\s\\S]*?(\\$(\\w*)\\$)([\\s\\S]*?)\\$\\2\\$`,
    "i"
  ).exec(sql);
  if (!def) {
    if (new RegExp(`create\\s+(?:or\\s+replace\\s+)?function\\s+(?:sri_os\\.)?${PAIRS_FN}\\b`, "i").test(sql))
      throw new RuleSyncParseError(
        `พบการ define ${PAIRS_FN}() แต่อ่านรูปแบบไม่ออก (ต้องเป็น $tag$ … $tag$) — แก้ตัวอ่านที่ scripts/rules-db-sync.ts`
      );
    return null;
  }
  const body = stripSqlComments(def[3]);
  const vi = body.toLowerCase().indexOf("values");
  if (vi === -1) throw new RuleSyncParseError(`${PAIRS_FN}() ไม่มี values (…) ให้อ่าน — รูปแบบเปลี่ยน ต้องแก้ตัวอ่าน`);
  const tuples = parseValueTuples(body.slice(vi + "values".length));
  if (tuples.length === 0) throw new RuleSyncParseError(`${PAIRS_FN}() อ่านได้ 0 คู่ — ชุดว่างทำให้การเทียบผ่านโดยไม่ตรวจอะไร`);
  return tuples.map((v) => {
    if (v.length !== 3) throw new RuleSyncParseError(`${PAIRS_FN}() มีแถวที่มี ${v.length} ค่า (ต้องเป็น 3: nature, payer, receiver)`);
    if (!/^[a-z_]+$/.test(v[0]) || !/^[0-9]{4}$/.test(v[1]) || !/^[0-9]{4}$/.test(v[2]))
      throw new RuleSyncParseError(`${PAIRS_FN}() มีแถวที่รูปไม่ถูก: (${v.join(", ")})`);
    return { nature: v[0], payerCoa: v[1], receiverCoa: v[2] };
  });
}

/** ไฟล์ท้ายสุดที่ define ฟังก์ชันชนะ (create or replace) · ไม่มีเลย = พัง */
export function effectiveIntercompanyPairs(files: readonly MigrationFile[]): { pairs: PairRow[]; source: string } {
  let found: { pairs: PairRow[]; source: string } | null = null;
  for (const f of [...files].sort((a, b) => a.name.localeCompare(b.name))) {
    let pairs: PairRow[] | null;
    try {
      pairs = intercompanyPairsFromSql(f.sql);
    } catch (e) {
      throw new RuleSyncParseError(`${f.name}: ${e instanceof Error ? e.message : String(e)}`);
    }
    if (pairs) found = { pairs, source: f.name };
  }
  if (!found)
    throw new RuleSyncParseError(`ไม่พบ migration ที่ define ${PAIRS_FN}() เลย (ค้นจาก ${files.length} ไฟล์)`);
  return found;
}

export type PairDiff = {
  /** ลักษณะที่โค้ดมีแต่ DB ไม่มี → ผู้ใช้เลือกแล้วกดบันทึกไม่ได้ */
  missingInDb: string[];
  /** ลักษณะที่ DB มีแต่โค้ดไม่มี → DB ยอมรับสิ่งที่ฟอร์มไม่มีทางสร้าง */
  extraInDb: string[];
  /** มีทั้งสองที่แต่คู่บัญชีต่างกัน → **อันตรายที่สุด** งบรวมตัดรายการระหว่างกันไม่ลง */
  mismatched: { nature: string; ts: string; db: string }[];
};

export function diffIntercompany(
  ts: Record<IntercompanyNature, IntercompanyRule>,
  db: readonly PairRow[]
): PairDiff {
  if (db.length === 0) throw new RuleSyncParseError("คู่บัญชีระหว่างกันฝั่ง migration ว่าง — ปฏิเสธการเทียบ");
  const dbMap = new Map(db.map((p) => [p.nature, p]));
  const mismatched: PairDiff["mismatched"] = [];
  for (const [nature, rule] of Object.entries(ts)) {
    const row = dbMap.get(nature);
    if (!row) continue;
    const a = `${rule.payer.coa}/${rule.receiver.coa}`;
    const b = `${row.payerCoa}/${row.receiverCoa}`;
    if (a !== b) mismatched.push({ nature, ts: a, db: b });
  }
  return {
    missingInDb: Object.keys(ts).filter((n) => !dbMap.has(n)).sort(),
    extraInDb: db.map((p) => p.nature).filter((n) => !(n in ts)).sort(),
    mismatched,
  };
}

export const intercompanyOk = (d: PairDiff) =>
  d.missingInDb.length === 0 && d.extraInDb.length === 0 && d.mismatched.length === 0;

export function describeIntercompanyDiff(d: PairDiff): string {
  const out: string[] = [];
  if (d.missingInDb.length)
    out.push(
      `ERROR: intercompany.ts มีลักษณะที่ ${PAIRS_FN}() ยังไม่มี: ${d.missingInDb.join(", ")} → ` +
        "ผู้ใช้เลือกลักษณะนั้นแล้วกดบันทึกไม่ได้ · สร้าง migration ด้วย `npm run sync:rules`"
    );
  if (d.extraInDb.length)
    out.push(`ERROR: ${PAIRS_FN}() มีลักษณะที่ intercompany.ts ไม่มี: ${d.extraInDb.join(", ")} → สำเนาฝั่ง DB ล้าสมัย`);
  if (d.mismatched.length)
    out.push(
      `ERROR: คู่บัญชีระหว่างกันไม่ตรงกัน: ${d.mismatched
        .map((m) => `${m.nature} (โค้ด=${m.ts} · migration=${m.db})`)
        .join(", ")} → งบรวมตัดรายการระหว่างกันไม่ลง`
    );
  return out.join("\n");
}

// ============================================================
// ตัวอ่านจากโฟลเดอร์ — ใช้เฉพาะสคริปต์/เทสต์ (node) ไม่ใช่โค้ดฝั่งเบราว์เซอร์
// ============================================================

export function readMigrations(dir = join(process.cwd(), "supabase", "migrations")): MigrationFile[] {
  const files = readdirSync(dir)
    .filter((f) => f.endsWith(".sql"))
    .sort()
    .map((name) => ({ name, sql: readFileSync(join(dir, name), "utf8") }));
  if (files.length === 0) throw new RuleSyncParseError(`ไม่พบไฟล์ .sql ใน ${dir}`);
  return files;
}
