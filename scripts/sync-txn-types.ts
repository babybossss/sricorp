/**
 * สร้าง SQL seed ของตาราง `txn_types` จากตารางกฎในโค้ด
 *
 * แหล่งความจริงคือ `src/lib/rules/tx-rules.ts` — ตารางใน DB เป็นสำเนาที่ sync ตามมา
 * เพื่อให้ report ฝั่ง SQL อ้างอิงกฎเดียวกับที่หน้าจอใช้ โดยไม่ต้องเขียนกฎซ้ำสองที่
 *
 * รัน: npm run sync:rules
 *
 * ถ้าเพิ่มฟิลด์ใหม่ใน `SubCategory` ต้องเพิ่มที่นี่ด้วย —
 * มี guard `assertAllFieldsHandled()` คอยพังให้เห็นถ้าลืม เพราะการ seed
 * ตารางกฎที่ไม่ครบลง DB แปลว่ารายงานฝั่ง SQL อ้างกฎที่ต่างจากหน้าจอ
 */
import { TX_TYPES, effectsOf, affectsPL, type SubCategory } from "../src/lib/rules/tx-rules";

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
        `${esc(s.plain)}, ${esc(s.caution)}, ${(TX_TYPES.indexOf(t) + 1) * 100 + i})`
    );
  }
}

process.stdout.write(`-- ============================================================
-- SRI OS · seed ตารางกฎประเภทรายการ
--
-- ไฟล์นี้ generate จาก src/lib/rules/tx-rules.ts — **ห้ามแก้ด้วยมือ**
-- แก้ที่ตารางกฎในโค้ดแล้วรัน \`npm run sync:rules\` ใหม่
--
-- ทำอะไร: sync ${rows.length} หมวดย่อยลงตาราง txn_types ให้ SQL อ้างกฎเดียวกับหน้าจอ
-- ย้อนกลับ: delete from sri_os.txn_types;
-- ============================================================

set search_path = sri_os, public;

insert into sri_os.txn_types (
  code, group_code, name_th, name_en, cf_group, direction,
  dr_coa_code, cr_coa_code, affects_pl, pl_line,
  requires_asset, requires_contact, requires_loan_terms,
  requires_capital_gain, requires_principal_split, requires_transfer_target,
  gain_coa_code, loss_coa_code, interest_coa_code, accrual_coa_code,
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
  plain_th   = excluded.plain_th,
  caution_th = excluded.caution_th,
  sort_order = excluded.sort_order;

-- ลบหมวดที่ถูกเอาออกจากตารางกฎแล้ว (แต่กันไม่ให้ลบถ้ามีรายการอ้างอยู่)
delete from sri_os.txn_types
 where code not in (${TX_TYPES.flatMap((t) => t.subs.map((s) => esc(s.code))).join(", ")})
   and not exists (select 1 from sri_os.transactions x where x.txn_type_code = txn_types.code)
   and not exists (select 1 from sri_os.draft_entries d where d.txn_type_code = txn_types.code);
`);
