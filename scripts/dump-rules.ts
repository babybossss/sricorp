/**
 * ส่งผังบัญชี โครงงบ และตารางกฎ ออกเป็น JSON ให้สคริปต์สร้างไฟล์ Excel อ่าน
 *
 * ทำแบบนี้เพราะ **แหล่งความจริงอยู่ใน TypeScript** (`src/lib/rules/`)
 * ถ้าให้ Python ไปพาร์ส .ts เอง วันหนึ่งมันจะอ่านพลาดแบบเงียบๆ
 * แล้วไฟล์ที่ส่งให้ลูกพี่กรอกจะไม่ตรงกับกฎที่ระบบใช้จริง
 *
 * รัน: npx tsx scripts/dump-rules.ts > <ไฟล์>.json  (หรือผ่าน npm run build:import)
 */
import { COA } from "../src/lib/rules/coa";
import { TX_TYPES, effectsOf, affectsPL, impactLines } from "../src/lib/rules/tx-rules";
import {
  BS_LAYOUT,
  PL_LAYOUT,
  findLayoutGaps,
  statementOf,
  isBalanceSheetType,
} from "../src/lib/rules/statements";
import { ENTITIES, HOLDERS } from "../src/lib/mock/entities";
import { BANKS } from "../src/lib/mock/banks";

// กันไม่ให้ export ไฟล์ที่ผังบัญชีกับโครงงบไม่ตรงกัน
const gaps = findLayoutGaps();
if (gaps.missing.length || gaps.duplicated.length || gaps.unknown.length) {
  throw new Error(
    "โครงงบไม่ครอบคลุมผังบัญชี — แก้ statements.ts ก่อน: " + JSON.stringify(gaps)
  );
}

const accounts = COA.map((a) => {
  const where = statementOf(a.code);
  return {
    ...a,
    statement: where.statement,
    group: where.group,
    line: where.line,
    isBs: isBalanceSheetType(a.type),
  };
});

const subs = TX_TYPES.flatMap((t) =>
  t.subs.map((s) => ({
    typeKey: t.key,
    typeLabel: t.label,
    code: s.code,
    label: s.label,
    en: s.en ?? "",
    plain: s.plain,
    cash: s.cash,
    cashflow: s.cashflow,
    dr: s.dr,
    cr: s.cr,
    gainCoa: s.gainCoa ?? "",
    lossCoa: s.lossCoa ?? "",
    interestCoa: s.interestCoa ?? "",
    accrualCoa: s.accrualCoa ?? "",
    requires: (s.requires ?? []).join(", "),
    affectsPl: affectsPL(s),
    plLine: effectsOf(s).pl?.line ?? effectsOf(s).conditionalPl?.line ?? "",
    impact: impactLines(s).join(" · "),
    caution: s.caution ?? "",
  }))
);

process.stdout.write(
  JSON.stringify(
    {
      accounts,
      bsLayout: BS_LAYOUT,
      plLayout: PL_LAYOUT,
      subs,
      owners: HOLDERS.map((o) => ({ id: o.id, name: o.name, policy: o.policy })),
      consolidatedName: ENTITIES.find((e) => !e.selectableAsHolder)?.name ?? "รวมทุกชื่อ",
      banks: BANKS.filter((b) => !b.off).map((b) => ({
        id: b.id,
        name: b.name,
        bank: b.bank,
        last4: b.last4,
        ownerId: b.ownerId,
      })),
    },
    null,
    2
  )
);
