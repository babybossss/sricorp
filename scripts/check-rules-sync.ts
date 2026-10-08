/**
 * เทียบตารางกฎฝั่งโค้ดกับสิ่งที่ฐานข้อมูลถืออยู่ — **พังทันทีถ้าไม่ตรง**
 * แบบเดียวกับ `check:permissions` / `check:draft-fields`
 *
 *   src/lib/rules/coa.ts          ↔ chart_of_accounts
 *   src/lib/rules/intercompany.ts ↔ fn_intercompany_pairs()
 *
 * ทำไมต้องมี: `sync:rules` **generate** ไฟล์ migration ให้ แต่ไม่มีอะไรบังคับว่า
 * คนจะรันมันจริง · เคยเกิดแล้วคือผังบัญชีใน DB ขาด 3 รหัส (1310/2310/1710)
 * แล้วรายการข้ามผู้ถือถูกปฏิเสธตอน**ผู้ใช้กดบันทึก** โดยไม่มีอะไรดังขึ้นก่อนเลย
 *
 * ใช้:
 *   npm run check:rules-sync -- --migrations               → เทียบกับ migration ในรีโป
 *   SRI_DB_URL=postgresql://... npm run check:rules-sync   → เทียบกับ DB จริง (SELECT อย่างเดียว ผ่าน psql)
 * ไม่ใส่ทั้งสองอย่าง = พัง (exit 1) ไม่ใช่ผ่านเฉยๆ — เช็คที่ไม่ได้เช็คอะไรห้ามรายงานว่าผ่าน
 *
 * โหมด `--migrations` ถูกเรียกจาก `npm run check:sync` และจาก vitest ด้วย
 * (src/lib/rules/__tests__/rules-db-sync.test.ts) → ไม่ต้องจำว่าต้องรันสคริปต์แยก
 */
import { execFileSync } from "node:child_process";

import { COA } from "../src/lib/rules/coa";
import { INTERCOMPANY_RULES } from "../src/lib/rules/intercompany";
import {
  coaOk,
  describeCoaDiff,
  describeIntercompanyDiff,
  diffCoa,
  diffIntercompany,
  effectiveCoa,
  effectiveIntercompanyPairs,
  intercompanyOk,
  readMigrations,
  type CoaRow,
  type PairRow,
} from "./rules-db-sync";

function psql(url: string, sql: string): string[][] {
  const out = execFileSync("psql", [url, "-v", "ON_ERROR_STOP=1", "-At", "-F", "\t", "-c", sql], {
    encoding: "utf8",
  });
  return out
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean)
    .map((l) => l.split("\t"));
}

function fromDb(url: string): { coa: Map<string, CoaRow>; pairs: PairRow[] } {
  const coa = new Map<string, CoaRow>();
  for (const [code, nameTh, nameEn, type] of psql(
    url,
    "select code, name_th, coalesce(name_en, ''), type::text from sri_os.chart_of_accounts order by code"
  ))
    coa.set(code, { code, nameTh, nameEn, type });
  const pairs = psql(
    url,
    "select nature, payer_coa, receiver_coa from sri_os.fn_intercompany_pairs() order by nature"
  ).map(([nature, payerCoa, receiverCoa]) => ({ nature, payerCoa, receiverCoa }));
  return { coa, pairs };
}

function main(): void {
  const useMigrations = process.argv.includes("--migrations");
  const dbUrl = process.env.SRI_DB_URL;
  if (!useMigrations && !dbUrl)
    throw new Error(
      "ไม่มีอะไรให้เทียบ — ตั้ง SRI_DB_URL เพื่อเทียบกับ DB จริง หรือรันด้วย `-- --migrations` เพื่อเทียบกับ migration ในรีโป"
    );

  let coa: Map<string, CoaRow>;
  let pairs: PairRow[];
  let source: string;
  if (useMigrations) {
    const files = readMigrations();
    coa = effectiveCoa(files).rows;
    const p = effectiveIntercompanyPairs(files);
    pairs = p.pairs;
    source = `migration ในรีโป (คู่บัญชีระหว่างกันจาก ${p.source})`;
  } else {
    const r = fromDb(dbUrl as string);
    coa = r.coa;
    pairs = r.pairs;
    source = "DB (chart_of_accounts · fn_intercompany_pairs)";
  }

  const cd = diffCoa(COA, coa);
  const pd = diffIntercompany(INTERCOMPANY_RULES, pairs);
  const msg = [describeCoaDiff(cd), describeIntercompanyDiff(pd)].filter(Boolean).join("\n");

  if (!coaOk(cd) || !intercompanyOk(pd))
    throw new Error(`ตารางกฎไม่ตรงกับ ${source}\n${msg}\n\nแก้ด้วย: npm run sync:rules แล้ว apply migration ที่ได้`);

  if (msg) process.stderr.write(`${msg}\n`);
  process.stdout.write(
    `ตรงกัน: ผังบัญชี ${COA.length} รหัส · คู่บัญชีระหว่างกัน ${Object.keys(INTERCOMPANY_RULES).length} ลักษณะ (TypeScript = ${source})\n`
  );
}

try {
  main();
} catch (e) {
  process.stderr.write(`${e instanceof Error ? e.message : String(e)}\n`);
  process.exit(1);
}
