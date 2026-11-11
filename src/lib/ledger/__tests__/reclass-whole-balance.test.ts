/**
 * **ย้ายวัตถุประสงค์อสังหาฯ ต้องย้าย "ทั้งก้อน" และยอดต้องมาจากสมุด ไม่ใช่จากที่พิมพ์**
 *
 * ช่องที่ผู้ตรวจวัดได้ (27/10 · BLOCK):
 *   คอนโดต้นทุน 3,000,000 อยู่ที่ 1500 · ผู้ใช้พิมพ์ 30,000,000
 *   → `adj.reclass_re_to_sale` ไหลผ่าน **เส้นทางรายการปกติสองบรรทัด** ซึ่งเชื่อยอดที่พิมพ์
 *   → Dr 1520 30,000,000 / Cr 1500 30,000,000 ด้วย `asset_id` เดิม
 *   → **ต้นทุนรวมต่อทรัพย์ไม่เปลี่ยน** (ออกข้างหนึ่ง เข้าอีกข้างหนึ่ง) จึงทั้ง
 *     `fn_assert_asset_cost_sane` และ `fn_assert_asset_whole_disposal` ข้ามไปทั้งคู่
 *     (`v_removed = 0`) · งบดุลอ่านได้ว่า "เพื่อการเช่า" = (27,000,000)
 *     และ "เพื่อการขาย" = 30,000,000 โดย **ไม่มีด่านไหนฟ้องเลย**
 *
 * ไฟล์นี้ตรึงสี่เรื่อง
 *   1. ธงในตารางกฎ (`requires: "wholeBalanceMove"`) เป็นตัวแยกสาขา
 *      **ไม่ใช่รหัสหมวด** — ตรวจสองทิศ (ธง ⇄ คู่บัญชี) เหมือน `revaluation`
 *   2. engine บังคับให้ผู้เรียกส่ง **ยอดคงเหลือของทรัพย์ชิ้นนั้นในบัญชีต้นทางที่อ่าน
 *      จากสมุด** มาคู่กับรหัสบัญชีที่อ่านมา (D-115 · รูปเดียวกับ
 *      `assetCostBefore`/`priorSurplus` ของใบขาย) · ไม่ครบคู่ = ปฏิเสธ
 *   3. **เคสที่ไม่ส่งข้อมูล** ครบทุกช่อง (บทเรียนข้อ 3: เทสต์ที่ส่งข้อมูลครบเสมอ
 *      จะไม่มีวันแตะเส้นทางที่ข้อมูลขาด ซึ่งคือเส้นทางที่บั๊กนี้อยู่)
 *   4. ด่านฝั่ง DB มีอยู่จริงในรีโป (migration) และกั้นยอดติดลบต่อ (ทรัพย์ × บัญชี)
 *      — กั้นแค่ฝั่งแอปไม่พอ (บทเรียนข้อ 6) · เคส SQL ของจริงอยู่ที่
 *      `supabase/tests/zz_asset_account_balance_nonneg_test.sql`
 */

import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import { buildPosting as buildPostingWith, buildPostingDraft, allLines, assertBalanced } from "../posting";
import { previewPosting } from "../preview";
import { PostingError, type PostingInput, type PostingLine } from "../types";
import { TEST_RESOLVER } from "./fixture-resolver";
import { coa, isCashAccount, isPropertyAccount } from "@/lib/rules/coa";
import { TX_TYPES, type SubCategory } from "@/lib/rules/tx-rules";
import { statementOf } from "@/lib/rules/statements";

const buildPosting = (input: PostingInput) => buildPostingWith(input, TEST_RESOLVER);

const allSubs = (): SubCategory[] => TX_TYPES.flatMap((t) => t.subs);

/** หมวดที่ตารางกฎบอกว่า "ย้ายยอดทั้งก้อน" — คัดด้วยธง ไม่ใช่รายชื่อรหัส */
const MOVES = allSubs().filter((s) => s.requires?.includes("wholeBalanceMove"));

/** ต้นทุนของคอนโดในสมุด — ตัวเลขเดียวกับฉากที่ผู้ตรวจวัดได้ */
const BOOK = 3_000_000;

const move = (sub: SubCategory, over: Partial<PostingInput> = {}): PostingInput => ({
  typeKey: "adjust",
  subCode: sub.code,
  amount: BOOK,
  ownerId: "thanakorn",
  assetId: "a1",
  balanceMove: { sourceCoaCode: sub.cr, sourceBalance: BOOK },
  ...over,
});

const net = (lines: PostingLine[], code: string) =>
  lines.filter((l) => l.coaCode === code).reduce((a, l) => a + l.debit - l.credit, 0);

const rejects = (input: PostingInput, needle: RegExp, why: string): void => {
  let thrown: unknown;
  try {
    buildPosting(input);
  } catch (e) {
    thrown = e;
  }
  expect(thrown, why).toBeInstanceOf(PostingError);
  expect((thrown as Error).message, why).toMatch(needle);
  // พรีวิวต้องปฏิเสธด้วยเหตุผลเดียวกัน — ห้ามโชว์บรรทัดที่ตัวจริงจะปฏิเสธ (บทเรียนข้อ 6)
  expect(previewPosting(input, TEST_RESOLVER).ok, `พรีวิวยังผ่าน: ${why}`).toBe(false);
  expect(() => buildPostingDraft(input, TEST_RESOLVER), why).toThrow(PostingError);
};

describe("0 · ตารางกฎ — ธงกับคู่บัญชีต้องตรงกันสองทิศ", () => {
  it("มีหมวดให้ทดสอบจริง (กันเทสต์ผ่านเพราะลูปว่าง)", () => {
    expect(MOVES.map((s) => s.code).sort()).toEqual(["adj.reclass_re_to_rental", "adj.reclass_re_to_sale"]);
  });

  it("ทุกหมวดที่มีธง: สองขาเป็นบัญชีสินทรัพย์ที่ไม่ใช่เงินสด · ไม่แตะ P&L · ไม่มีเงินเคลื่อน", () => {
    for (const s of MOVES) {
      for (const code of [s.dr, s.cr]) {
        expect(coa(code).type, `${s.code} · ${code}`).toBe("asset");
        expect(isCashAccount(code), `${s.code} · ${code} เป็นบัญชีเงินสด`).toBe(false);
        expect(statementOf(code).statement, `${s.code} · ${code}`).toBe("BS");
      }
      expect(s.dr, `${s.code} ย้ายเข้าบัญชีเดียวกับที่ย้ายออก`).not.toBe(s.cr);
      expect(s.cash, s.code).toBe("none");
      expect(s.cashflow, s.code).toBe("none");
      // ตั้งค้างรับ/ค้างจ่ายไม่ได้ — ไม่มีเงินรอรับรอจ่ายในการย้ายบัญชี
      expect(s.accrualCoa, `${s.code} มีบัญชีพัก = เปิดช่องลงลูกหนี้ปลอม`).toBeUndefined();
      expect(s.requires?.includes("asset"), `${s.code} ไม่บังคับผูกทรัพย์`).toBe(true);
    }
  });

  it("ทิศกลับ: ทุกหมวดที่ย้ายระหว่างบัญชีอสังหาฯ สองตัว **ต้องมีธง** (หมวดใหม่ไม่หลุด)", () => {
    for (const s of allSubs()) {
      if (isPropertyAccount(s.dr) && isPropertyAccount(s.cr)) {
        expect(
          s.requires?.includes("wholeBalanceMove"),
          `${s.code} ย้ายระหว่างบัญชีอสังหาฯ แต่ไม่มีธง → จะเชื่อยอดที่ผู้ใช้พิมพ์`
        ).toBe(true);
      }
    }
  });
});

describe("1 · ย้ายทั้งก้อนด้วยยอดที่อ่านจากสมุด → ผ่าน", () => {
  for (const s of MOVES) {
    it(`${s.code} — สองบรรทัดดุลกัน · ผูกทรัพย์ทั้งสองขา · ไม่เข้า P&L · ไม่มีเงินสด`, () => {
      const lines = allLines(buildPosting(move(s)));
      assertBalanced(lines);
      expect(lines).toHaveLength(2);
      expect(net(lines, s.dr)).toBe(BOOK);
      expect(net(lines, s.cr)).toBe(-BOOK);
      expect(lines.every((l) => l.assetId === "a1"), "บรรทัดที่ไม่ผูกทรัพย์ = ต้นทุนรายชิ้นแยกไม่ออก").toBe(true);
      expect(lines.some((l) => isCashAccount(l.coaCode)), "มีบรรทัดเงินสด").toBe(false);
      expect(lines.some((l) => l.bankAccountId), "มีบัญชีธนาคารติดมา").toBe(false);
      expect(lines.every((l) => l.cfCategory === "none"), "ยังนับในงบกระแสเงินสด").toBe(true);
      expect(
        lines.filter((l) => statementOf(l.coaCode).statement === "PL"),
        "การย้ายวัตถุประสงค์ไม่ใช่การขาย จึงไม่มีกำไร/ขาดทุน"
      ).toEqual([]);
    });

    it(`${s.code} — พรีวิวแสดงบรรทัดได้ และสรุปบอกว่าย้ายทั้งก้อน`, () => {
      const r = previewPosting(move(s), TEST_RESOLVER);
      expect(r.ok, r.ok ? "" : r.reason).toBe(true);
      expect(buildPosting(move(s)).summary.join(" ")).toMatch(/ทั้งก้อน/);
    });
  }
});

describe("2 · ยอดที่พิมพ์ไม่ตรงยอดในสมุด → PostingError (ช่องที่ผู้ตรวจวัดได้)", () => {
  for (const s of MOVES) {
    it(`${s.code} — พิมพ์ 30,000,000 ขณะที่สมุดมี 3,000,000 (ยอดต้นทางจะติดลบ 27,000,000)`, () => {
      rejects(
        move(s, { amount: 30_000_000 }),
        /ทั้งก้อน/,
        `${s.code} ยอมให้ย้ายเกินยอดในสมุด = งบดุลโชว์บัญชีต้นทางติดลบโดยยอดรวมยังถูก`
      );
      // ข้อความต้องมีทั้งยอดที่พิมพ์และยอดในสมุด ไม่ใช่แค่ "ไม่ถูกต้อง"
      try {
        buildPosting(move(s, { amount: 30_000_000 }));
      } catch (e) {
        expect((e as Error).message).toContain("30,000,000");
        expect((e as Error).message).toContain("3,000,000");
      }
    });

    it(`${s.code} — ย้ายบางส่วน (1,000,000 จาก 3,000,000) ก็ปฏิเสธ ไม่ใช่ผ่านเงียบ`, () => {
      rejects(
        move(s, { amount: 1_000_000 }),
        /ทั้งก้อน/,
        `${s.code} ยอมให้ย้ายบางส่วน = ทรัพย์ชิ้นเดียวอยู่สองวัตถุประสงค์พร้อมกัน`
      );
    });

    /**
     * **ต่างกันหนึ่งสตางค์ต้องแดงที่ engine ไม่ใช่ไปแดงที่ DB** (ผู้ตรวจข้อ 3 · 27/10)
     *
     * เดิมเทียบ `Math.abs(round2(amount - balance)) > 0.01` → ต่างพอดีหนึ่งสตางค์
     * **ปล่อยผ่าน** แล้วไปถูก `trg_assert_asset_account_balance_nonneg` ปฏิเสธที่ DB
     * (ด่านนั้นเทียบ `round(...) <> 0` ตรงเป๊ะ) = ผู้ใช้เห็น error ของฐานข้อมูล
     * แทนข้อความของฟอร์ม และเราเสียด่านที่พูดเป็นภาษาคนไปเปล่าๆ
     * ความคลาดหนึ่งสตางค์มีเหตุผลเฉพาะตอนเทียบกับ **ใบรับรองภาษีที่ปัดเศษ**
     * (`whtAmounts`) ส่วนยอดนี้อ่านจาก **สมุดของเราเอง** จึงไม่มีอะไรให้คลาด
     */
    for (const [label, amount] of [
      ["น้อยกว่าสมุดหนึ่งสตางค์", BOOK - 0.01],
      ["มากกว่าสมุดหนึ่งสตางค์", BOOK + 0.01],
      ["ต่างสองสตางค์", BOOK - 0.02],
    ] as const) {
      it(`${s.code} — ${label} ก็ไม่ผ่าน (engine ต้องแดงเอง ไม่ใช่ปล่อยไปแดงที่ DB)`, () => {
        rejects(move(s, { amount }), /ทั้งก้อน/, `${s.code} ปล่อยเศษสตางค์ (${label})`);
      });
    }

    it(`${s.code} — ทรัพย์ที่ไม่มียอดในบัญชีต้นทางเลย ย้ายไม่ได้`, () => {
      rejects(
        move(s, { amount: BOOK, balanceMove: { sourceCoaCode: s.cr, sourceBalance: 0 } }),
        /ไม่มียอดคงเหลือ/,
        `${s.code} ย้ายทรัพย์ที่ไม่มีต้นทุนในบัญชีต้นทาง = สร้างต้นทุนขึ้นมาจากอากาศ`
      );
    });
  }
});

describe("3 · ไม่ส่งข้อมูลมาเลย → PostingError (บทเรียนข้อ 3)", () => {
  for (const s of MOVES) {
    it(`${s.code} — ไม่ส่งยอดคงเหลือเลย = เส้นทางเดิมที่เชื่อยอดที่พิมพ์ ต้องปิด`, () => {
      const rest = move(s);
      // ลบช่องทิ้งแทนการไม่ใส่ตั้งแต่แรก เพื่อให้เคสนี้เดินเส้นทาง "ผู้เรียกไม่ส่งอะไรมาเลย"
      delete rest.balanceMove;
      rejects(
        rest,
        /ยอดคงเหลือ/,
        `${s.code} ยังลงได้โดยไม่ต้องอ่านยอดจากสมุด = บั๊กเดิมทั้งก้อน`
      );
    });

    it(`${s.code} — ส่งยอดมาแต่ไม่บอกว่าอ่านจากบัญชีไหน → ปฏิเสธ (ไม่ครบคู่)`, () => {
      rejects(
        move(s, { balanceMove: { sourceBalance: BOOK } as never }),
        /ไม่ครบคู่/,
        `${s.code} รับยอดลอยๆ ที่ตรวจไม่ได้ว่าอ่านมาจากบัญชีต้นทางจริง`
      );
    });

    it(`${s.code} — บอกบัญชีมาแต่ไม่ส่งยอด → ปฏิเสธ (ไม่ครบคู่)`, () => {
      rejects(
        move(s, { balanceMove: { sourceCoaCode: s.cr } as never }),
        /ไม่ครบคู่/,
        `${s.code} เดายอดเป็น 0 แทนการปฏิเสธ`
      );
    });

    it(`${s.code} — ยอดที่อ่านมาจาก **บัญชีอื่น** (ไม่ใช่ขาเครดิตของหมวด) → ปฏิเสธ`, () => {
      rejects(
        move(s, { balanceMove: { sourceCoaCode: s.dr, sourceBalance: BOOK } }),
        /บัญชีต้นทาง/,
        `${s.code} ยอมรับยอดของบัญชีปลายทางมาเป็นยอดต้นทาง = ตรวจไม่ได้เลย`
      );
    });

    it(`${s.code} — ยอดที่อ่านมาไม่ใช่ตัวเลข → ปฏิเสธ ไม่ใช่ NaN ไหลเข้าบรรทัด`, () => {
      rejects(
        move(s, { balanceMove: { sourceCoaCode: s.cr, sourceBalance: Number.NaN } }),
        /ยอดคงเหลือ/,
        `${s.code} ปล่อย NaN ผ่าน`
      );
    });

    it(`${s.code} — ไม่ส่ง assetId → ปฏิเสธ (ย้ายทรัพย์ชิ้นไหนต้องรู้)`, () => {
      const rest = move(s);
      delete rest.assetId;
      rejects(rest, /ทรัพย์/, `${s.code} ลงได้โดยไม่ผูกทรัพย์ = ต้นทุนรายชิ้นแยกไม่ออกหลังย้าย`);
    });

    it(`${s.code} — assetId เป็นช่องว่างล้วน ก็ถือว่าไม่ได้ระบุ`, () => {
      rejects(move(s, { assetId: "   " }), /ทรัพย์/, `${s.code} รับช่องว่างเป็นรหัสทรัพย์`);
    });
  }
});

describe("4 · ส่งยอดคงเหลือมากับหมวดที่ไม่ใช่การย้าย → ปฏิเสธ ไม่ใช่เมินทิ้ง", () => {
  const OTHERS = allSubs().filter((s) => !s.requires?.includes("wholeBalanceMove"));

  it("มีหมวดอื่นให้ทดสอบ", () => {
    expect(OTHERS.length).toBeGreaterThan(10);
  });

  it("หมวดปรับปรุงอื่น (ตัดหนี้สูญ) + balanceMove → PostingError", () => {
    rejects(
      {
        typeKey: "adjust",
        subCode: "adj.writeoff_rent",
        amount: 5_000,
        ownerId: "thanakorn",
        assetId: "a1",
        contactId: "c1",
        balanceMove: { sourceCoaCode: "1200", sourceBalance: 5_000 },
      },
      /ไม่ใช่การย้ายยอดทั้งก้อน/,
      "เมินทิ้งแปลว่าผู้ใช้ส่งยอดมาแล้วระบบลงโดยไม่ใช้ยอดนั้นเลย"
    );
  });

  it("หมวดซื้ออสังหาฯ + balanceMove → PostingError (ซื้อไม่ใช่การย้าย)", () => {
    rejects(
      {
        typeKey: "invest_buy",
        subCode: "inv.buy_re",
        amount: BOOK,
        ownerId: "thanakorn",
        assetId: "a1",
        contactId: "c1",
        bankAccountId: "b4",
        balanceMove: { sourceCoaCode: "1500", sourceBalance: BOOK },
      },
      /ไม่ใช่การย้ายยอดทั้งก้อน/,
      "หมวดที่มีขาเงินสดรับยอดคงเหลือมาไม่ได้"
    );
  });
});

/* ================================================================== *
 * 5 · ด่านฝั่ง DB — กั้นแค่ฝั่งแอปไม่พอ (บทเรียนข้อ 6)
 * ================================================================== */

const MIGRATION_DIR = join(process.cwd(), "supabase", "migrations");

function nonnegMigration(): { name: string; sql: string } {
  const names = readdirSync(MIGRATION_DIR).filter((n) => n.includes("asset_account_balance_nonneg"));
  // อ่านไม่ออก = พัง ไม่ยอมผ่านด้วยชุดว่าง (กฎเดียวกับ check:rules-sync)
  expect(names, "ไม่พบ migration ของด่านยอดติดลบต่อ (ทรัพย์ × บัญชี)").toHaveLength(1);
  return { name: names[0], sql: readFileSync(join(MIGRATION_DIR, names[0]), "utf8") };
}

describe("5 · migration ของด่านฝั่ง DB", () => {
  it("มีไฟล์เดียว ชื่อขึ้นต้นด้วยวันที่ 20261027", () => {
    expect(nonnegMigration().name).toMatch(/^20261027\d{6}_asset_account_balance_nonneg\.sql$/);
  });

  it("ผูกเป็น constraint trigger แบบ deferred (ต้องอ่านทุกบรรทัดของใบ)", () => {
    const { sql } = nonnegMigration();
    expect(sql).toMatch(/create constraint trigger trg_assert_asset_account_balance_nonneg/);
    expect(sql).toMatch(/deferrable initially deferred/);
    expect(sql).toMatch(/create or replace function fn_assert_asset_account_balance_nonneg\(\)/);
  });

  it("อ่านสมุดผ่าน v_ledger_posted (ไม่นับใบที่ยกเลิกแล้ว · D-098)", () => {
    expect(nonnegMigration().sql).toMatch(/v_ledger_posted/);
  });

  it('ไม่มีคำว่า "drop" ทั้งไฟล์ แม้ในคอมเมนต์ (MCP apply_migration จะ timeout)', () => {
    expect(nonnegMigration().sql.toLowerCase()).not.toContain("drop");
  });

  it("มีหมายเหตุวิธีย้อนกลับที่หัวไฟล์", () => {
    expect(nonnegMigration().sql).toMatch(/ย้อนกลับ/);
  });

  it("ชุดบัญชีที่ด่านตรวจเป็นชุดเดียวกับ is_cost_account ของ fn_asset_ledger_parts", () => {
    const { sql } = nonnegMigration();
    // ถ้าด่านสองตัวคิดคนละชุด อันหนึ่งยอม อันหนึ่งไม่ยอม แล้วไม่มีใครรู้ว่าอันไหนถูก
    expect(sql).toMatch(/create or replace function fn_asset_cost_coa\(p_code text\)/);
    for (const rule of [/\^11\[0-9\]\[0-9\]\$/, /c\.code <> '1800'/, /accrual_coa_code = c\.code/]) {
      expect(sql, `ชุดบัญชีขาดเงื่อนไข ${String(rule)}`).toMatch(rule);
    }
  });

  /**
   * ช่องที่สองของผู้ตรวจ (27/10): ด่านเดิมบังคับแค่ "บัญชีต้นทางเหลือศูนย์"
   * ต่อ (ทรัพย์ × บัญชี) → ใบ `Cr 1500 ของทรัพย์ A` / `Dr 1520 ของทรัพย์ B`
   * ผ่าน DB ได้ แล้วต้นทุนของ A หายทั้งก้อนไปโป่งที่ B โดยต้นทุนรวมเท่าเดิม
   * เคสของจริงวัดที่ `supabase/tests/zz_asset_account_balance_nonneg_test.sql` (N8/M3)
   */
  it("ข้อ (ข) บังคับว่าทุกบรรทัดของใบย้ายต้องเป็นทรัพย์ชิ้นเดียวกัน", () => {
    const { sql } = nonnegMigration();
    expect(sql).toMatch(/count\(distinct lx\.asset_id\)/);
    expect(sql, "ข้อความต้องบอกว่าทำไมผิด ไม่ใช่แค่ว่าผิด").toMatch(/ชิ้นเดียวกันทุกบรรทัด/);
    expect(sql).toMatch(/หายไปทั้งก้อนและไปโป่งที่ชิ้นที่สอง/);
  });

  it("ฟังก์ชันอ่านยอดต้นทางเปิดให้ authenticated เรียกได้ (ฟอร์มต้องใช้)", () => {
    expect(nonnegMigration().sql).toMatch(
      /grant execute on function sri_os\.fn_asset_account_balance\(uuid, text, uuid\) to authenticated/
    );
  });
});
