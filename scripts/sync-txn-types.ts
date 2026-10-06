/**
 * สร้าง SQL seed ของตาราง `txn_types` จากตารางกฎในโค้ด
 *
 * แหล่งความจริงคือ `src/lib/rules/tx-rules.ts` — ตารางใน DB เป็นสำเนาที่ sync ตามมา
 * เพื่อให้ report ฝั่ง SQL อ้างอิงกฎเดียวกับที่หน้าจอใช้ โดยไม่ต้องเขียนกฎซ้ำสองที่
 *
 * รัน: npm run sync:rules            → เขียน migration ไฟล์ใหม่ตามวันเวลาปัจจุบัน
 *     npm run sync:rules -- --stdout → พิมพ์ออก stdout เพื่อ diff ก่อน ไม่เขียนไฟล์
 *
 * **ชื่อไฟล์ตั้งจากเวลาที่รัน ไม่ฮาร์ดโค้ด** — เคยฮาร์ดโค้ดไว้ตัวเดียว รอบถัดไป
 * จะเขียนทับ migration ที่ apply ขึ้น Supabase แล้ว คนที่ pull ไปจะได้ไฟล์ชื่อเดิม
 * ที่เนื้อในไม่เหมือนกัน แล้วฐานข้อมูลสองเครื่องจะถือกฎไม่ตรงกันโดยไม่มีใครเห็น
 *
 * ถ้าเพิ่มฟิลด์ใหม่ใน `SubCategory` ต้องเพิ่มที่นี่ด้วย —
 * มี guard `assertAllFieldsHandled()` คอยพังให้เห็นถ้าลืม เพราะการ seed
 * ตารางกฎที่ไม่ครบลง DB แปลว่ารายงานฝั่ง SQL อ้างกฎที่ต่างจากหน้าจอ
 */
import { existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  TX_TYPES,
  effectsOf,
  affectsPL,
  canAccrueFromForm,
  type SubCategory,
} from "../src/lib/rules/tx-rules";

const esc = (s: string | undefined | null) => (s == null ? "null" : `'${s.replace(/'/g, "''")}'`);
const bool = (b: boolean | undefined) => (b ? "true" : "false");

/**
 * ฟิลด์ทุกตัวของ `SubCategory` ที่ไฟล์นี้รู้จักวิธีแปลงเป็น SQL
 * เพิ่มฟิลด์ใหม่ในตารางกฎแล้วลืมเพิ่มที่นี่ = สคริปต์พัง ไม่ใช่ seed ผิดเงียบๆ
 */
const HANDLED_FIELDS: (keyof SubCategory)[] = [
  "code", "label", "en", "plain", "cash", "cashflow", "dr", "cr",
  "gainCoa", "lossCoa", "interestCoa", "accrualCoa", "requires", "caution",
];

function assertAllFieldsHandled(): void {
  const unknown = new Set<string>();
  for (const t of TX_TYPES) {
    for (const s of t.subs) {
      for (const k of Object.keys(s)) {
        if (!HANDLED_FIELDS.includes(k as keyof SubCategory)) unknown.add(k);
      }
    }
  }
  if (unknown.size) {
    throw new Error(
      `ตารางกฎมีฟิลด์ที่สคริปต์นี้ยังไม่รู้จัก: ${[...unknown].join(", ")} — ` +
        "เพิ่มคอลัมน์ใน migration แล้วเพิ่มการแปลงในไฟล์นี้ก่อน ไม่งั้นกฎใน DB จะไม่ครบ"
    );
  }
}

assertAllFieldsHandled();

const rows: string[] = [];

for (const t of TX_TYPES) {
  for (const [i, s] of t.subs.entries()) {
    const { pl } = effectsOf(s);
    const direction = s.cash === "in" ? 1 : s.cash === "out" ? -1 : 0;
    // `none` ใน TypeScript ตรงกับ enum `transfer` ฝั่ง DB (โอนภายใน ตัดออกจากงบรวม)
    const cf = s.cashflow === "none" ? "transfer" : s.cashflow;

    rows.push(
      `  (${esc(s.code)}, ${esc(t.key)}, ${esc(s.label)}, ${esc(s.en)}, ${esc(cf)}::sri_os.cf_group, ${direction}, ` +
        `${esc(s.dr)}, ${esc(s.cr)}, ${bool(affectsPL(s))}, ${esc(pl?.line ?? effectsOf(s).conditionalPl?.line)}, ` +
        `${bool(s.requires?.includes("asset"))}, ${bool(s.requires?.includes("contact"))}, ` +
        `${bool(s.requires?.includes("loanTerms"))}, ${bool(s.requires?.includes("capitalGain"))}, ` +
        `${bool(s.requires?.includes("principalInterestSplit"))}, ` +
        `${bool(s.requires?.includes("transferTarget"))}, ` +
        `${esc(s.gainCoa)}, ${esc(s.lossCoa)}, ${esc(s.interestCoa)}, ${esc(s.accrualCoa)}, ` +
        // ตั้งค้างได้จริงไหม — คำนวณจากกฎ ไม่ใช่ `accrual_coa_code is not null`
        // ไม่ส่งลงไป = SQL/automation จะเห็นแค่ว่ามีบัญชีพัก แล้วเข้าใจว่าตั้งค้างได้
        `${bool(canAccrueFromForm(s))}, ` +
        `${esc(s.plain)}, ${esc(s.caution)}, ${(TX_TYPES.indexOf(t) + 1) * 100 + i})`
    );
  }
}

const accruable = TX_TYPES.flatMap((t) => t.subs).filter(canAccrueFromForm).length;

const sql = `-- ============================================================
-- SRI OS · seed ตารางกฎประเภทรายการ
--
-- ไฟล์นี้ generate จาก src/lib/rules/tx-rules.ts — **ห้ามแก้ด้วยมือ**
-- แก้ที่ตารางกฎในโค้ดแล้วรัน \`npm run sync:rules\` ใหม่
--
-- ทำอะไร: sync ${rows.length} หมวดย่อยลงตาราง txn_types ให้ SQL อ้างกฎเดียวกับหน้าจอ
--         ในนั้น ${accruable} หมวดตั้งค้างรับ-ค้างจ่ายจากฟอร์มได้ (can_accrue = true)
--
-- ต้องรันหลัง migration ที่เพิ่มบัญชีในผังเสมอ — gain/loss/interest/accrual_coa_code
-- เป็น FK เข้า chart_of_accounts · ถ้าบัญชีที่กฎอ้างยังไม่มี ทั้งชุดจะ rollback
-- และต้องรันหลัง migration ที่เพิ่มคอลัมน์ can_accrue ด้วย
--
-- ย้อนกลับ: ไฟล์นี้เป็น upsert ทั้งหมด replay ซ้ำได้ · ถอนทั้งชุดด้วย
--   delete from sri_os.txn_types;  (ลบไม่ได้ถ้ามี transactions/draft_entries อ้างอยู่)
-- ============================================================

set search_path = sri_os, public;

insert into sri_os.txn_types (
  code, group_code, name_th, name_en, cf_group, direction,
  dr_coa_code, cr_coa_code, affects_pl, pl_line,
  requires_asset, requires_contact, requires_loan_terms,
  requires_capital_gain, requires_principal_split, requires_transfer_target,
  gain_coa_code, loss_coa_code, interest_coa_code, accrual_coa_code, can_accrue,
  plain_th, caution_th, sort_order
) values
${rows.join(",\n")}
on conflict (code) do update set
  group_code = excluded.group_code,
  name_th    = excluded.name_th,
  name_en    = excluded.name_en,
  cf_group   = excluded.cf_group,
  direction  = excluded.direction,
  dr_coa_code = excluded.dr_coa_code,
  cr_coa_code = excluded.cr_coa_code,
  affects_pl = excluded.affects_pl,
  pl_line    = excluded.pl_line,
  requires_asset = excluded.requires_asset,
  requires_contact = excluded.requires_contact,
  requires_loan_terms = excluded.requires_loan_terms,
  requires_capital_gain = excluded.requires_capital_gain,
  requires_principal_split = excluded.requires_principal_split,
  requires_transfer_target = excluded.requires_transfer_target,
  gain_coa_code     = excluded.gain_coa_code,
  loss_coa_code     = excluded.loss_coa_code,
  interest_coa_code = excluded.interest_coa_code,
  accrual_coa_code  = excluded.accrual_coa_code,
  can_accrue        = excluded.can_accrue,
  plain_th   = excluded.plain_th,
  caution_th = excluded.caution_th,
  sort_order = excluded.sort_order;

-- ลบหมวดที่ถูกเอาออกจากตารางกฎแล้ว (แต่กันไม่ให้ลบถ้ามีรายการอ้างอยู่)
delete from sri_os.txn_types
 where code not in (${TX_TYPES.flatMap((t) => t.subs.map((s) => esc(s.code))).join(", ")})
   and not exists (select 1 from sri_os.transactions x where x.txn_type_code = txn_types.code)
   and not exists (select 1 from sri_os.draft_entries d where d.txn_type_code = txn_types.code);
`;

/**
 * ชื่อไฟล์ตั้งจากเวลาที่รัน (UTC) — รอบถัดไปจึงไม่ทับ migration ที่ apply แล้ว
 * Supabase เรียง migration ตามชื่อไฟล์ ไฟล์ใหม่จึงต้องมาหลังเสมอ
 */
const stamp = new Date().toISOString().replace(/\D/g, "").slice(0, 14);
const outDir = join(process.cwd(), "supabase", "migrations");

if (process.argv.includes("--stdout")) {
  process.stdout.write(sql);
} else {
  // เขียนผิดที่แปลว่า migration หายไปเงียบๆ — ตรวจก่อนว่ารันจาก root ของโปรเจกต์จริง
  if (!existsSync(outDir)) {
    throw new Error(
      `ไม่พบโฟลเดอร์ ${outDir} — ต้องรันจาก root ของโปรเจกต์ (npm run sync:rules)`
    );
  }
  const outFile = join(outDir, `${stamp}_seed_txn_types.sql`);
  if (existsSync(outFile)) {
    throw new Error(`${outFile} มีอยู่แล้ว — รอหนึ่งวินาทีแล้วรันใหม่ ห้ามเขียนทับ`);
  }
  writeFileSync(outFile, sql);
  process.stdout.write(`เขียนแล้ว: ${outFile}\n`);
}
