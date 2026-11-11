/**
 * ตารางกฎฝั่งโค้ด ↔ สิ่งที่ migration สร้างไว้ใน DB
 *
 *   coa.ts          ↔ chart_of_accounts
 *   intercompany.ts ↔ fn_intercompany_pairs()
 *
 * ทำไมต้องอยู่ใน vitest ไม่ใช่แค่สคริปต์: ของที่ต้อง "จำว่าต้องรัน" จะไม่ถูกรัน
 * ไฟล์นี้ทำให้ `npx vitest run` ดังเองถ้ามีคนเพิ่มรหัสใน coa.ts หรือเพิ่มลักษณะ
 * ใน intercompany.ts แล้วไม่ทำ migration คู่กัน (เหมือนที่ check:draft-fields ทำ)
 *
 * เคยเกิดจริง: DB ขาด 1310/2310/1710 → รายการข้ามผู้ถือถูกปฏิเสธตอนผู้ใช้กดบันทึก
 * และ **ไม่มีอะไรจับได้** เพราะ sync:rules ครอบแค่ txn_types
 */
import { describe, expect, it } from "vitest";

import { COA } from "../coa";
import { INTERCOMPANY_RULES } from "../intercompany";
import {
  RuleSyncParseError,
  coaOk,
  coaOpsFromSql,
  describeCoaDiff,
  describeIntercompanyDiff,
  diffCoa,
  diffIntercompany,
  effectiveCoa,
  effectiveIntercompanyPairs,
  intercompanyPairsFromSql,
  intercompanyOk,
  parseValueTuples,
  readMigrations,
  stripDollarBodies,
  stripSqlComments,
} from "../../../../scripts/rules-db-sync";

const files = readMigrations();

// ============================================================
// 1 · ของจริงในรีโปต้องตรงกัน — ข้อนี้คือข้อที่ต้องแดงเวลาคนลืมทำ migration
// ============================================================
describe("coa.ts เทียบกับ migration จริงในรีโป", () => {
  const db = effectiveCoa(files);
  const diff = diffCoa(COA, db.rows);

  it("ทุกรหัสใน coa.ts ถูก seed ไว้ใน migration แล้ว", () => {
    expect(describeCoaDiff(diff)).not.toMatch(/ERROR/);
    expect(diff.missingInDb).toEqual([]);
    expect(coaOk(diff)).toBe(true);
  });

  it("ประเภทบัญชีตรงกันทุกรหัส (งบจัดบรรทัดจากประเภท)", () => {
    expect(diff.mismatched.filter((m) => m.field === "type")).toEqual([]);
  });

  it("อ่านผังบัญชีออกจริง ไม่ใช่ได้ชุดว่างแล้วผ่าน", () => {
    expect(db.rows.size).toBeGreaterThanOrEqual(COA.length);
    expect(db.sources.length).toBeGreaterThan(0);
  });
});

describe("intercompany.ts เทียบกับ fn_intercompany_pairs() ใน migration", () => {
  const db = effectiveIntercompanyPairs(files);
  const diff = diffIntercompany(INTERCOMPANY_RULES, db.pairs);

  it("ทุกลักษณะและทุกคู่บัญชีตรงกัน", () => {
    expect(describeIntercompanyDiff(diff)).toBe("");
    expect(intercompanyOk(diff)).toBe(true);
  });

  it("จำนวนลักษณะเท่ากันทั้งสองฝั่ง", () => {
    expect(db.pairs.length).toBe(Object.keys(INTERCOMPANY_RULES).length);
  });
});

// ============================================================
// 2 · เป้าหมายที่วัดได้ — "เพิ่มในโค้ดแล้วไม่ทำ migration ต้องมีอะไรดังขึ้น"
//     ไม่แก้ไฟล์จริงในเทสต์ (เทสต์ที่แก้ซอร์สคือเทสต์ที่ทิ้งขยะไว้ถ้ามันล้มกลางทาง)
//     แต่ส่ง "โค้ดสมมติที่มีรหัสใหม่" เข้าไปเทียบกับ migration จริง
// ============================================================
describe("เพิ่มกฎในโค้ดแล้วไม่ทำ migration คู่ = ต้องแดง", () => {
  it("รหัสบัญชีใหม่ที่ยังไม่ได้ seed → ERROR ไม่ใช่เตือน", () => {
    const db = effectiveCoa(files).rows;
    const d = diffCoa([...COA, { code: "9999", nameTh: "บัญชีปลอม", nameEn: "Fake", type: "asset" }], db);
    expect(d.missingInDb).toEqual(["9999"]);
    expect(coaOk(d)).toBe(false);
    expect(describeCoaDiff(d)).toMatch(/ERROR.*9999/);
  });

  it("ประเภทบัญชีเพี้ยนจาก migration → ERROR (งบจัดบรรทัดผิด)", () => {
    const db = effectiveCoa(files).rows;
    const d = diffCoa(
      COA.map((c) => (c.code === "4200" ? { ...c, type: "expense" as const } : c)),
      db
    );
    expect(coaOk(d)).toBe(false);
    expect(describeCoaDiff(d)).toMatch(/ประเภทบัญชีไม่ตรงกัน/);
  });

  it("ลักษณะข้ามผู้ถือใหม่ที่ฝั่ง DB ยังไม่มี → ไม่ผ่าน", () => {
    const pairs = effectiveIntercompanyPairs(files).pairs;
    const d = diffIntercompany(
      {
        ...INTERCOMPANY_RULES,
        // @ts-expect-error — จำลองลักษณะใหม่ที่ยังไม่มีใน IntercompanyNature
        gift: {
          label: "ยกให้",
          payer: { coa: "3200", cashflow: "financing" },
          receiver: { coa: "4410", cashflow: "operating" },
          note: "สมมติ",
        },
      },
      pairs
    );
    expect(d.missingInDb).toEqual(["gift"]);
    expect(intercompanyOk(d)).toBe(false);
  });

  it("คู่บัญชีของลักษณะเดิมถูกแก้ข้างเดียว → ไม่ผ่าน (งบรวมตัดระหว่างกันไม่ลง)", () => {
    const pairs = effectiveIntercompanyPairs(files).pairs;
    const d = diffIntercompany(
      { ...INTERCOMPANY_RULES, loan: { ...INTERCOMPANY_RULES.loan, payer: { coa: "1300", cashflow: "investing" } } },
      pairs
    );
    expect(intercompanyOk(d)).toBe(false);
    expect(describeIntercompanyDiff(d)).toMatch(/1300\/2310/);
  });
});

// ============================================================
// 3 · ตัวอ่าน **ต้องพังเสียงดัง** ไม่ใช่คืนชุดว่างแล้วทำให้การเทียบผ่าน
// ============================================================
describe("ตัวอ่าน SQL พังเสียงดังเมื่ออ่านไม่ออก", () => {
  it("insert ... select (ไม่มี values) → พัง", () => {
    expect(() =>
      coaOpsFromSql("insert into sri_os.chart_of_accounts (code, name_th, name_en, type) select * from x;")
    ).toThrow(RuleSyncParseError);
  });

  it("insert ที่ขาดคอลัมน์ที่ต้องเทียบ → พัง", () => {
    expect(() => coaOpsFromSql("insert into chart_of_accounts (code, name_th) values ('1100', 'ก');")).toThrow(
      /name_en|type/
    );
  });

  it("รหัสที่ไม่ใช่เลขสี่หลัก (อ่านคอลัมน์ผิดตำแหน่ง) → พัง ไม่ใช่เก็บค่าเพี้ยน", () => {
    expect(() =>
      coaOpsFromSql("insert into chart_of_accounts (code, name_th, name_en, type) values ('ก', 'ก', 'k', 'asset');")
    ).toThrow(/ไม่ใช่เลขสี่หลัก/);
  });

  it("delete ที่มี where แต่อ่านรหัสไม่ออก → พัง ไม่ใช่เดาว่าไม่ลบอะไร", () => {
    expect(() => coaOpsFromSql("delete from sri_os.chart_of_accounts where type = 'asset';")).toThrow(
      /อ่านรหัสไม่ออก/
    );
  });

  it("delete ทั้งตาราง = ล้างสภาพที่สะสมมา (ลำดับไฟล์มีความหมาย)", () => {
    const ops = coaOpsFromSql("delete from chart_of_accounts;")!;
    expect(ops).toEqual([{ kind: "deleteAll" }]);
    const eff = effectiveCoa([
      { name: "a.sql", sql: "insert into chart_of_accounts (code, name_th, name_en, type) values ('1100','ก','k','asset');" },
      { name: "b.sql", sql: "delete from chart_of_accounts; insert into chart_of_accounts (code, name_th, name_en, type) values ('2100','ข','kh','liability');" },
    ]);
    expect([...eff.rows.keys()]).toEqual(["2100"]);
  });

  it("ไฟล์ที่ไม่แตะผังบัญชีเลย → null (ไม่ใช่ชุดว่าง)", () => {
    expect(coaOpsFromSql("select 1;")).toBeNull();
  });

  it("ไม่มีไฟล์ไหน seed ผังบัญชีเลย → พัง (ชุดว่างห้ามถือว่าผ่าน)", () => {
    expect(() => effectiveCoa([{ name: "a.sql", sql: "select 1;" }])).toThrow(/0 รหัส/);
  });

  it("fn_intercompany_pairs() ที่ define แต่อ่านรูปแบบไม่ออก → พัง", () => {
    expect(() =>
      intercompanyPairsFromSql("create or replace function fn_intercompany_pairs() returns setof record language sql;")
    ).toThrow(/อ่านรูปแบบไม่ออก/);
  });

  it("fn_intercompany_pairs() ที่ไม่มี values → พัง", () => {
    expect(() =>
      intercompanyPairsFromSql(
        "create or replace function sri_os.fn_intercompany_pairs() returns table (a text) language sql as $f$ select 1 $f$;"
      )
    ).toThrow(/values/);
  });

  it("ไม่มี migration ไหน define fn_intercompany_pairs() → พัง", () => {
    expect(() => effectiveIntercompanyPairs([{ name: "a.sql", sql: "select 1;" }])).toThrow(/ไม่พบ migration/);
  });

  it("ไฟล์ท้ายสุดที่ define ชนะ (create or replace)", () => {
    const def = (payer: string) =>
      `create or replace function fn_intercompany_pairs() returns table (nature text, payer_coa text, receiver_coa text) language sql immutable as $fn$ values ('loan','${payer}','2310') $fn$;`;
    const eff = effectiveIntercompanyPairs([
      { name: "b.sql", sql: def("1710") },
      { name: "a.sql", sql: def("1310") },
    ]);
    expect(eff.source).toBe("b.sql");
    expect(eff.pairs[0].payerCoa).toBe("1710");
  });
});

describe("ตัวแยกค่าใน values — ชื่อบัญชีไทยมีวงเล็บและ comma จริง", () => {
  it("วงเล็บในข้อความไม่ทำให้แตก tuple ผิด", () => {
    expect(parseValueTuples("('1510', 'ค่ารีโนเวท (บันทึกเป็นทุน)', 'Renovation, capitalised', 'asset', 151)")).toEqual([
      ["1510", "ค่ารีโนเวท (บันทึกเป็นทุน)", "Renovation, capitalised", "asset", "151"],
    ]);
  });

  it("'' ในข้อความอ่านเป็น ' ตัวเดียว", () => {
    expect(parseValueTuples("('x', 'a''b')")).toEqual([["x", "a'b"]]);
  });

  it("นิพจน์ต่อสตริง (ตัวอ่านไม่รองรับ) → พัง ไม่ใช่เก็บค่าครึ่งเดียว", () => {
    expect(() => parseValueTuples("('x', 'a' || 'b')")).toThrow(RuleSyncParseError);
  });

  it("หยุดเมื่อเจอ on conflict ไม่ใช่กินต่อไปเรื่อยๆ", () => {
    expect(parseValueTuples("('1100','ก') on conflict (code) do nothing;")).toEqual([["1100", "ก"]]);
  });

  it("tuple ที่ไม่ปิดวงเล็บ → พัง", () => {
    expect(() => parseValueTuples("('1100','ก'")).toThrow(RuleSyncParseError);
  });
});

describe("ตัวตัดคอมเมนต์/body ของฟังก์ชัน", () => {
  it("คอมเมนต์ที่พูดถึง insert into chart_of_accounts ไม่ถูกนับเป็น seed", () => {
    expect(coaOpsFromSql("-- insert into chart_of_accounts (code) values ('9999')\nselect 1;")).toBeNull();
  });

  it("body ของฟังก์ชันที่พูดถึงรหัสบัญชีไม่ถูกนับเป็น seed", () => {
    expect(
      coaOpsFromSql("create function f() returns void language plpgsql as $x$ begin delete from chart_of_accounts; end $x$;")
    ).toBeNull();
  });

  it("ข้อความใน single quote ที่มี -- ไม่ถูกตัด", () => {
    expect(stripSqlComments("select 'a -- b';")).toBe("select 'a -- b';");
  });

  it("$tag$ ที่ไม่มีตัวปิด → พัง", () => {
    expect(() => stripDollarBodies("$fn$ begin")).toThrow(RuleSyncParseError);
  });
});
