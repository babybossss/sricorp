/**
 * สร้าง SQL seed ของ **ตารางกฎทั้งสามชุด** จากตารางกฎในโค้ด
 *
 *   1. `src/lib/rules/coa.ts`          → ตาราง `chart_of_accounts`
 *   2. `src/lib/rules/tx-rules.ts`     → ตาราง `txn_types`
 *   3. `src/lib/rules/intercompany.ts` → ฟังก์ชัน `fn_intercompany_pairs()`
 *
 * แหล่งความจริงคือไฟล์ในโค้ด — ของใน DB เป็นสำเนาที่ sync ตามมา
 * เพื่อให้ report/trigger ฝั่ง SQL อ้างอิงกฎเดียวกับที่หน้าจอใช้
 *
 * **สคริปต์นี้ไม่ต่อฐานข้อมูล** มันเขียนไฟล์ migration เท่านั้น (โดยตั้งใจ)
 * ตารางกฎใน DB แก้ได้ทางเดียวคือผ่าน migration ที่อยู่ใน git — เครื่องมือที่
 * เขียนทับตารางกฎในฐานข้อมูลได้โดยตรงจะทำให้ "สิ่งที่ DB ถืออยู่" ไม่มีประวัติ
 * ตัวที่ **เทียบ** โค้ดกับ migration แล้วพังถ้าไม่ตรง คือ `npm run check:sync`
 *
 * รัน: npm run sync:rules            → เขียน migration ไฟล์ใหม่ตามวันเวลาปัจจุบัน
 *     npm run sync:rules -- --stdout → พิมพ์ออก stdout เพื่อ diff ก่อน ไม่เขียนไฟล์
 *     npm run check:sync             → เทียบโค้ดกับ migration ในรีโป · ไม่ตรง = พัง
 *
 * **ชื่อไฟล์ตั้งจากเวลาที่รัน ไม่ฮาร์ดโค้ด** — เคยฮาร์ดโค้ดไว้ตัวเดียว รอบถัดไป
 * จะเขียนทับ migration ที่ apply ขึ้น Supabase แล้ว คนที่ pull ไปจะได้ไฟล์ชื่อเดิม
 * ที่เนื้อในไม่เหมือนกัน แล้วฐานข้อมูลสองเครื่องจะถือกฎไม่ตรงกันโดยไม่มีใครเห็น
 *
 * ถ้าเพิ่มฟิลด์ใหม่ใน `SubCategory` / `CoaAccount` / `IntercompanyRule`
 * ต้องเพิ่มที่นี่ด้วย — มี guard `assertAllFieldsHandled()` คอยพังให้เห็นถ้าลืม
 * เพราะการ seed ตารางกฎที่ไม่ครบลง DB แปลว่ารายงาน/trigger ฝั่ง SQL
 * อ้างกฎที่ต่างจากหน้าจอ **โดยไม่มีใครเห็น**
 */
import { existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { COA, type CoaAccount } from "../src/lib/rules/coa";
import { INTERCOMPANY_RULES, type IntercompanyRule } from "../src/lib/rules/intercompany";
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

/** ฟิลด์ของ `CoaAccount` ที่ไฟล์นี้รู้จักวิธีแปลงเป็นคอลัมน์ของ chart_of_accounts */
const HANDLED_COA_FIELDS: (keyof CoaAccount)[] = ["code", "nameTh", "nameEn", "type"];

/**
 * ฟิลด์ของ `IntercompanyRule` ที่ไฟล์นี้ตัดสินใจแล้วว่าจะทำอะไรกับมัน
 * - `payer` / `receiver` → ลงใน `fn_intercompany_pairs()` (ใช้แค่ `.coa`)
 * - `label` / `note`     → **ไม่ลง DB โดยตั้งใจ** (ข้อความสำหรับหน้าจอ ไม่ใช่กฎบัญชี)
 * ฟิลด์ใหม่ที่ไม่อยู่ในรายการนี้ = พัง เพราะอาจเป็นกฎที่ฝั่ง DB ต้องรู้ด้วย
 */
const HANDLED_INTERCO_FIELDS: (keyof IntercompanyRule)[] = ["label", "payer", "receiver", "note"];

/** ฟิลด์ของแต่ละขา — `cashflow` ไม่ลง DB (ฟังก์ชันเก็บแค่คู่บัญชี) แต่ต้องรู้จัก */
const HANDLED_SIDE_FIELDS = ["coa", "cashflow"];

function assertAllFieldsHandled(): void {
  const unknown = new Set<string>();
  for (const t of TX_TYPES) {
    for (const s of t.subs) {
      for (const k of Object.keys(s)) {
        if (!HANDLED_FIELDS.includes(k as keyof SubCategory)) unknown.add(`SubCategory.${k}`);
      }
    }
  }
  for (const c of COA) {
    for (const k of Object.keys(c)) {
      if (!HANDLED_COA_FIELDS.includes(k as keyof CoaAccount)) unknown.add(`CoaAccount.${k}`);
    }
  }
  for (const r of Object.values(INTERCOMPANY_RULES)) {
    for (const k of Object.keys(r)) {
      if (!HANDLED_INTERCO_FIELDS.includes(k as keyof IntercompanyRule)) unknown.add(`IntercompanyRule.${k}`);
    }
    for (const side of [r.payer, r.receiver]) {
      for (const k of Object.keys(side)) {
        if (!HANDLED_SIDE_FIELDS.includes(k)) unknown.add(`IntercompanySide.${k}`);
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
    /**
     * `direction` ฝั่ง DB เป็น smallint ที่มี check `in (-1, 0, 1)` มาตั้งแต่ไฟล์แรก
     * → แทน `none` (ไม่มีเงินเคลื่อน) **ไม่ได้** · มันถูกยุบรวมกับ `both` เป็น 0
     *
     * เพราะงั้นคอลัมน์ `cash_direction` (20261009000003_txn_types_cash_direction.sql)
     * จึงเป็นตัวที่ถือความจริง และมี check constraint ผูกสองคอลัมน์ให้ตรงกัน
     * **ห้ามใช้ `direction` ตัดสินว่ามีเงินเคลื่อนไหม** — 0 ตอบคำถามนั้นไม่ได้
     */
    const direction = s.cash === "in" ? 1 : s.cash === "out" ? -1 : 0;
    // `none` ใน TypeScript ตรงกับ enum `transfer` ฝั่ง DB (โอนภายใน ตัดออกจากงบรวม)
    const cf = s.cashflow === "none" ? "transfer" : s.cashflow;

    rows.push(
      `  (${esc(s.code)}, ${esc(t.key)}, ${esc(s.label)}, ${esc(s.en)}, ${esc(cf)}::sri_os.cf_group, ${direction}, ` +
        `${esc(s.cash)}, ` +
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

/**
 * แถวของผังบัญชี
 * `sort_order` **ไม่ใช่กฎในโค้ด** (coa.ts ไม่มีฟิลด์นี้) → เติมให้เฉพาะแถวที่ยังไม่มี
 * จากรหัสบัญชี และ `on conflict` จะไม่แก้ของเดิม ไม่งั้นลำดับที่คนจัดไว้ใน DB
 * จะถูกสคริปต์นี้เขียนทับทุกรอบโดยไม่มีใครขอ
 */
const coaRows = COA.map(
  (c) =>
    // ไม่ cast ชนิดที่ literal (`'asset'` พอ) — รูปเดียวกับ seed ผังบัญชีไฟล์ก่อนๆ
    `  (${esc(c.code)}, ${esc(c.nameTh)}, ${esc(c.nameEn)}, ${esc(c.type)}, ` +
    `${Math.floor(Number(c.code) / 10)})`
);

/** คู่บัญชีระหว่างกัน — เรียงตามลำดับที่ประกาศไว้ใน intercompany.ts */
const pairRows = Object.entries(INTERCOMPANY_RULES).map(
  ([nature, r]) => `         (${esc(nature)}, ${esc(r.payer.coa)}, ${esc(r.receiver.coa)})`
);

/**
 * ทุกรหัสที่กฎอื่นอ้างต้องมีในผังบัญชีฝั่งโค้ดก่อน
 * ถ้าไม่เช็คที่นี่ ไฟล์ที่ generate จะไปล้มที่ FK ตอน migrate ซึ่งอ่านยากกว่ามาก
 */
const referenced = [
  ...new Set([
    ...Object.values(INTERCOMPANY_RULES).flatMap((r) => [r.payer.coa, r.receiver.coa]),
    ...TX_TYPES.flatMap((t) => t.subs).flatMap((x) =>
      [x.dr, x.cr, x.gainCoa, x.lossCoa, x.interestCoa, x.accrualCoa].filter(
        (c): c is string => typeof c === "string" && c !== ""
      )
    ),
  ]),
];
const orphan = referenced.filter((c) => !COA.some((a) => a.code === c));
if (orphan.length) {
  throw new Error(
    `ตารางกฎอ้างรหัสบัญชีที่ไม่มีใน src/lib/rules/coa.ts: ${orphan.join(", ")} — ` +
      "เพิ่มในผังบัญชีก่อน ไม่งั้น seed จะล้มที่ FK (หรือแย่กว่า: ผู้ใช้กดบันทึกแล้วถูกปฏิเสธ)"
  );
}

const sql = `-- ============================================================
-- SRI OS · seed ตารางกฎทั้งชุด (ผังบัญชี · ประเภทรายการ · คู่บัญชีระหว่างกัน)
--
-- ไฟล์นี้ generate จาก src/lib/rules/{coa,tx-rules,intercompany}.ts — **ห้ามแก้ด้วยมือ**
-- แก้ที่ตารางกฎในโค้ดแล้วรัน \`npm run sync:rules\` ใหม่
-- ตรวจว่าตรงกันด้วย \`npm run check:sync\` (พังถ้าไม่ตรง)
--
-- ทำอะไร (เรียงตามลำดับที่จำเป็น เพราะ FK):
--   1 · ${coaRows.length} รหัสลงตาราง chart_of_accounts
--   2 · ${rows.length} หมวดย่อยลงตาราง txn_types (ในนั้น ${accruable} หมวดตั้งค้างรับ-ค้างจ่ายได้)
--   3 · ${pairRows.length} คู่บัญชีระหว่างกันลงฟังก์ชัน fn_intercompany_pairs()
--
-- ผังบัญชีต้องมาก่อน txn_types เสมอ — dr/cr/gain/loss/interest/accrual_coa_code
-- เป็น FK เข้า chart_of_accounts · ถ้าบัญชีที่กฎอ้างยังไม่มี ทั้งชุดจะ rollback
-- และต้องรันหลัง migration ที่เพิ่มคอลัมน์ can_accrue และ cash_direction ด้วย
--   (cash_direction อยู่ใน 20261009000003_txn_types_cash_direction.sql ซึ่งชื่อไฟล์
--    เรียงมาก่อนไฟล์นี้เสมอ เพราะไฟล์นี้ตั้งชื่อจากเวลาที่รัน sync:rules)
--
-- **ไม่ลบรหัสบัญชีที่หายไปจาก coa.ts** — บัญชีที่มีรายการอ้างอยู่ลบไม่ได้
-- และการลบเงียบๆ จะทำให้ยอดในรายงานเก่าหาย → รายงานเป็น warning ให้คนตัดสิน
--
-- ย้อนกลับ: ทั้งไฟล์เป็น upsert / create or replace → replay ซ้ำได้
--   ถอน txn_types ทั้งชุด: delete from sri_os.txn_types;
--     (ลบไม่ได้ถ้ามี transactions/draft_entries อ้างอยู่)
--   คืน fn_intercompany_pairs() รุ่นก่อน: รัน migration ก่อนหน้าที่ define มันซ้ำ
--   ผังบัญชี: ไฟล์นี้ไม่ลบอะไร จึงไม่มีอะไรต้องกู้
-- ============================================================

set search_path = sri_os, public;

-- ------------------------------------------------------------
-- 1 · ผังบัญชี (src/lib/rules/coa.ts)
-- ------------------------------------------------------------
insert into sri_os.chart_of_accounts (code, name_th, name_en, type, sort_order) values
${coaRows.join(",\n")}
on conflict (code) do update set
  name_th = excluded.name_th,
  name_en = excluded.name_en,
  type    = excluded.type;
  -- sort_order ไม่อยู่ในนี้โดยตั้งใจ (ดูคอมเมนต์ในสคริปต์ที่ generate ไฟล์นี้)

do $do$
declare v text;
begin
  select string_agg(c.code, ', ' order by c.code) into v
    from sri_os.chart_of_accounts c
   where c.code <> all (array[${COA.map((c) => esc(c.code)).join(", ")}]);
  if v is not null then
    raise warning 'ผังบัญชีใน DB มีรหัสที่ไม่อยู่ใน src/lib/rules/coa.ts: % — ไฟล์นี้ไม่ลบให้ (อาจมีรายการอ้างอยู่) ให้คนตัดสินว่าจะถอนหรือเพิ่มกลับในโค้ด', v;
  end if;
end $do$;

-- ------------------------------------------------------------
-- 2 · ประเภทรายการ (src/lib/rules/tx-rules.ts)
-- ------------------------------------------------------------
insert into sri_os.txn_types (
  code, group_code, name_th, name_en, cf_group, direction, cash_direction,
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
  cash_direction = excluded.cash_direction,
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

-- ------------------------------------------------------------
-- 3 · คู่บัญชีระหว่างกัน (src/lib/rules/intercompany.ts)
--
-- เป็น **ฟังก์ชัน** ไม่ใช่ตาราง: แอปแก้ไม่ได้เลย เปลี่ยนได้เฉพาะด้วย migration
-- ที่อยู่ใน git · trigger ของบรรทัดบัญชีกับประตู fn_post_entry อ่านจากที่นี่ที่เดียว
-- ------------------------------------------------------------
create or replace function fn_intercompany_pairs()
  returns table (nature text, payer_coa text, receiver_coa text)
language sql immutable as $fn$
  -- ฝ่ายจ่าย | ฝ่ายรับ — generate จาก INTERCOMPANY_RULES
  values ${pairRows.join(",\n").trimStart()}
$fn$;

comment on function fn_intercompany_pairs() is
  'สำเนาเดียวในฝั่ง DB ของคู่บัญชีระหว่างกัน · generate จาก src/lib/rules/intercompany.ts ด้วย npm run sync:rules · ตรวจว่าตรงกันด้วย npm run check:sync';

revoke all on function fn_intercompany_pairs() from public;
do $do$
begin
  execute 'revoke all on function sri_os.fn_intercompany_pairs() from anon';
  execute 'grant execute on function sri_os.fn_intercompany_pairs() to authenticated';
end $do$;

-- ------------------------------------------------------------
-- guard ท้ายไฟล์ — ดังตอน migrate ไม่ใช่ตอนผู้ใช้กดบันทึก
-- ------------------------------------------------------------
do $do$
declare v text;
begin
  -- ทุกรหัสที่คู่บัญชีระหว่างกันใช้ ต้องมีในผังบัญชี
  select string_agg(x.code, ', ' order by x.code) into v
    from (select p.payer_coa as code from sri_os.fn_intercompany_pairs() p
          union select p.receiver_coa from sri_os.fn_intercompany_pairs() p) x
   where not exists (select 1 from sri_os.chart_of_accounts c where c.code = x.code);
  if v is not null then
    raise exception 'ผังบัญชีขาดรหัสที่คู่บัญชีระหว่างกันใช้: % — รายการข้ามผู้ถือจะถูกปฏิเสธตอนผู้ใช้กดบันทึก', v;
  end if;

  -- ลักษณะที่ตาราง transactions อนุญาต ต้องมีคู่บัญชีครบ และไม่เกิน
  select pg_get_constraintdef(oid) into v from pg_constraint
   where conrelid = 'sri_os.transactions'::regclass
     and conname = 'transactions_intercompany_nature_check';
  if v is null then
    raise exception 'ไม่มี constraint transactions_intercompany_nature_check — ลักษณะข้ามผู้ถือจะรับค่าอะไรก็ได้';
  end if;
  if exists (select 1 from sri_os.fn_intercompany_pairs() p
              where position('''' || p.nature || '''' in v) = 0) then
    raise exception 'fn_intercompany_pairs() มีลักษณะที่ตาราง transactions ไม่อนุญาต (constraint: %) — เพิ่มใน constraint ด้วย migration ก่อน', v;
  end if;
  if exists (
    select 1 from (select (regexp_matches(v, '''([a-z_]+)''::text', 'g'))[1] as nature) x
     where not exists (select 1 from sri_os.fn_intercompany_pairs() p where p.nature = x.nature)) then
    raise exception 'ตาราง transactions อนุญาตลักษณะที่ไม่มีคู่บัญชีใน fn_intercompany_pairs() (constraint: %) — ผู้ใช้เลือกแล้วกดบันทึกไม่ได้', v;
  end if;

  raise notice 'seed ตารางกฎครบ: ผังบัญชี ${coaRows.length} รหัส · ประเภทรายการ ${rows.length} หมวด · คู่บัญชีระหว่างกัน ${pairRows.length} ลักษณะ';
end $do$;
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
  const outFile = join(outDir, `${stamp}_seed_rules.sql`);
  if (existsSync(outFile)) {
    throw new Error(`${outFile} มีอยู่แล้ว — รอหนึ่งวินาทีแล้วรันใหม่ ห้ามเขียนทับ`);
  }
  writeFileSync(outFile, sql);
  process.stdout.write(`เขียนแล้ว: ${outFile}\n`);
}
