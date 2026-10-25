import { describe, it, expect } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { buildPosting } from "@/lib/ledger/posting";
import { PostingError, type PostingInput } from "@/lib/ledger/types";
import { TX_TYPES } from "@/lib/rules/tx-rules";
import { TEST_RESOLVER } from "@/lib/ledger/__tests__/fixture-resolver";
import {
  FX_TRANSLATION_DIFF_COA,
  REALISED_FX_GAIN,
  REALISED_FX_LOSS,
} from "@/lib/rules/coa";
import { PayloadError, humanizeDbError, notWiredReason, toPostEntryPayload } from "../post-entry";
import { makeResolver } from "../resolver";
import type { Reference } from "../reference-types";

/** ข้อมูลที่ครบตามกฎของ inc.rent ฝั่งบุคคล (ทรัพย์ + ผู้ติดต่อ + บัญชี) */
const rent: PostingInput = {
  typeKey: "income",
  subCode: "inc.rent",
  amount: 12000,
  ownerId: "thanakorn",
  bankAccountId: "b4",
  assetId: "asset-1",
  contactId: "contact-1",
};
const header = { docDate: "2026-10-24", cashDate: "2026-10-24" as string | null };

describe("toPostEntryPayload · แปลงผลของ engine เป็นคำขอของ fn_post_entry", () => {
  it("ส่งบรรทัดที่ engine คืนมาครบ ไม่เพิ่มไม่ตัด และใช้ชื่อช่อง snake_case", () => {
    const result = buildPosting(rent, TEST_RESOLVER);
    const p = toPostEntryPayload(rent, result, header);

    expect(p.txn_type_code).toBe("inc.rent");
    expect(p.doc_date).toBe("2026-10-24");
    expect(p.cash_date).toBe("2026-10-24");
    expect(p.source).toBe("manual");
    expect(p.asset_id).toBe("asset-1");
    expect(p.contact_id).toBe("contact-1");
    expect(p.transactions).toHaveLength(result.transactions.length);

    const sent = p.transactions[0].lines.map((l) => [l.coa_code, l.debit, l.credit]);
    const built = result.transactions[0].lines.map((l) => [l.coaCode, l.debit, l.credit]);
    expect(sent).toEqual(built);
    const dr = p.transactions[0].lines.reduce((t, l) => t + l.debit, 0);
    const cr = p.transactions[0].lines.reduce((t, l) => t + l.credit, 0);
    expect(dr).toBe(cr);
  });

  it("ข้ามผู้ถือ: engine คืนสองก้อน → ส่งครบทั้งสองก้อน พร้อมคู่และลักษณะรายการ (หนึ่ง transaction = หนึ่งผู้ถือ)", () => {
    const input: PostingInput = {
      typeKey: "transfer",
      subCode: "trf.internal",
      amount: 20000,
      ownerId: "thanakorn",
      bankAccountId: "b4",
      transferToBankAccountId: "b5",
      intercompanyNature: "loan",
    };
    const result = buildPosting(input, TEST_RESOLVER);
    expect(result.transactions.length).toBe(2);

    const p = toPostEntryPayload(input, result, header);
    expect(p.transactions).toHaveLength(2);
    expect(p.transactions.map((t) => t.owner_id)).toEqual(result.transactions.map((t) => t.ownerId));
    expect(p.transactions[0].counter_owner_id).toBe("thanawin");
    expect(p.transactions[1].counter_owner_id).toBe("thanakorn");
    expect(p.transactions.every((t) => t.intercompany_nature === "loan")).toBe(true);
  });

  it("ค้างรับ-ค้างจ่าย (ไม่มีบรรทัดเงินสด) → cash_date เป็น null แม้ฟอร์มมีวันที่ค้างอยู่", () => {
    const input: PostingInput = { ...rent, bankAccountId: undefined, notYetPaid: true };
    const result = buildPosting(input, TEST_RESOLVER);
    const p = toPostEntryPayload(input, result, header);
    expect(p.cash_date).toBeNull();
  });

  it("มีบรรทัดเงินสดแต่ไม่มี cash_date → ปฏิเสธ ไม่เดาเป็นวันที่เอกสาร", () => {
    const result = buildPosting(rent, TEST_RESOLVER);
    expect(() => toPostEntryPayload(rent, result, { docDate: "2026-10-24", cashDate: null })).toThrow(PayloadError);
  });

  it("ผลลัพธ์ว่าง → ปฏิเสธ ไม่ส่งคำขอเปล่า", () => {
    expect(() => toPostEntryPayload(rent, { transactions: [], summary: [] }, header)).toThrow(PayloadError);
  });

  it("ช่องว่างไม่ถูกส่ง (memo ว่าง · ไฟล์แนบว่าง) — RPC ถือ null กับไม่ส่งเท่ากัน", () => {
    const input = { ...rent, memo: "  ", attachments: [] };
    const p = toPostEntryPayload(input, buildPosting(input, TEST_RESOLVER), header);
    expect(p.memo).toBeUndefined();
    expect(p.attachments).toBeUndefined();
  });

  it("ทุกช่องที่ส่งต้องอยู่ในรายการที่ RPC รับ (อ่านจาก migration จริง) — ช่องที่ RPC ไม่รู้จัก = ปฏิเสธทั้งใบ", () => {
    // รุ่นล่าสุดของ fn_post_entry = ไฟล์ migration ท้ายสุด (เรียงชื่อ) ที่นิยาม c_header — ไม่ใช่ไฟล์ที่ pin ชื่อไว้
    // (เคยอ่าน 20261008000011 ทั้งที่ประตูถูกเขียนทับเพื่อรับช่อง wht_* ไปแล้ว เทสต์จึงตรวจกับสัญญาที่ตายแล้ว)
    const dir = path.join(process.cwd(), "supabase/migrations");
    const latest = readdirSync(dir)
      .filter((f) => f.endsWith(".sql"))
      .sort()
      .filter((f) => /c_header\s+constant text\[\]/.test(readFileSync(path.join(dir, f), "utf8")))
      .pop();
    if (!latest) throw new Error("หา migration ที่นิยามช่องของ fn_post_entry ไม่เจอ — เทสต์นี้ต้องไม่ผ่านด้วยชุดว่าง");
    const sql = readFileSync(path.join(dir, latest), "utf8");
    const arr = (name: string): string[] => {
      const m = new RegExp(`${name}\\s+constant text\\[\\] := array\\[([^\\]]+)\\]`).exec(sql);
      if (!m) throw new Error(`อ่านรายการช่อง ${name} จาก migration ไม่ได้ — เทสต์นี้ต้องไม่ผ่านด้วยชุดว่าง`);
      return [...m[1].matchAll(/'([a-z_]+)'/g)].map((x) => x[1]);
    };
    const header_ = arr("c_header");
    const txn_ = arr("c_txn");
    const line_ = arr("c_line");
    expect(header_.length).toBeGreaterThan(5);
    expect(header_).toContain("wht_rate"); // ประตูรุ่นล่าสุดต้องรับช่องภาษีหัก ณ ที่จ่าย

    const input: PostingInput = { ...rent, memo: "ค่าเช่า", attachments: ["a/b/c.pdf"] };
    const p = toPostEntryPayload(input, buildPosting(input, TEST_RESOLVER), header);
    for (const k of Object.keys(p)) expect(header_, `ช่องหัวรายการ ${k}`).toContain(k);
    for (const t of p.transactions) {
      for (const k of Object.keys(t)) expect(txn_, `ช่อง transaction ${k}`).toContain(k);
      for (const l of t.lines) for (const k of Object.keys(l)) expect(line_, `ช่องบรรทัด ${k}`).toContain(k);
    }
  });
});

describe("ข้อมูลสกุลเงินต่อบรรทัด (FCD) ต้องไปถึง DB ครบ หรือไม่มีเลย", () => {
  /**
   * `transaction_lines_fx_shape` ยอมแค่สองรูป: **ครบทั้งสี่** หรือ **ไม่มีเลย**
   * ถ้าตัวแปลง payload ส่งคีย์ที่ค่าเป็น undefined ไปด้วย ประตูจะเห็นช่องที่
   * "ส่งมาแต่ว่าง" แล้วปฏิเสธทั้งใบ · และถ้าตัดสี่ช่องนี้ทิ้ง ข้อมูลสกุลเดิมจะหาย
   * ทั้งที่ engine สร้างมาให้ (ยอดบาทจะกลายเป็นตัวเลขที่ตรวจย้อนไม่ได้)
   */
  const fxConvert: PostingInput = {
    typeKey: "transfer",
    subCode: "trf.fx_convert",
    amount: 365_000,
    ownerId: "thanakorn",
    bankAccountId: "b4usd",
    transferToBankAccountId: "b4b",
    fxConversion: {
      currency: "USD",
      amountOriginal: 10_000,
      balanceOriginalBefore: 10_000,
      bookRateToThb: 37,
      bookRateDate: "2026-11-30",
      dealRateToThb: 36.5,
      dealRateDate: "2026-12-31",
      unrealizedBefore: 0,
    },
  };

  it("บรรทัดเงินตราส่งครบสี่ช่อง · บรรทัดบาท **ไม่มีคีย์เลย**", () => {
    const p = toPostEntryPayload(fxConvert, buildPosting(fxConvert, TEST_RESOLVER), header);
    const lines = p.transactions.flatMap((t) => t.lines);
    const fcd = lines.find((l) => l.bank_account_id === "b4usd")!;
    expect(fcd.currency).toBe("USD");
    expect(fcd.amount_original).toBe(10_000);
    expect(fcd.fx_rate).toBe(37);
    expect(fcd.fx_rate_date).toBe("2026-11-30");

    const baht = lines.find((l) => l.bank_account_id === "b4b")!;
    for (const k of ["currency", "amount_original", "fx_rate", "fx_rate_date"]) {
      expect(Object.keys(baht), `บรรทัดบาทต้องไม่มีคีย์ ${k}`).not.toContain(k);
    }
  });

  it("บรรทัดขาดทุนอัตราแลกเปลี่ยนไปถึง payload (ไม่ถูกตัดทิ้งระหว่างแปลง)", () => {
    const p = toPostEntryPayload(fxConvert, buildPosting(fxConvert, TEST_RESOLVER), header);
    const loss = p.transactions.flatMap((t) => t.lines).find((l) => l.coa_code === "5930")!;
    expect(loss.debit).toBe(5_000);
    expect(Object.keys(loss)).not.toContain("currency");
  });
});

describe("notWiredReason · หมวดที่เส้นทางบันทึกยังต่อไม่ครบต้องถูกกั้น (ไม่บันทึกครึ่งเดียว)", () => {
  const subs = TX_TYPES.flatMap((t) => t.subs);

  it("ทุกหมวดที่ตารางกฎติดธง loanTerms หรือ capitalGain ถูกกั้น พร้อมเหตุผล", () => {
    const flagged = subs.filter((s) => s.requires?.includes("loanTerms") || s.requires?.includes("capitalGain"));
    expect(flagged.length).toBeGreaterThan(0);
    for (const s of flagged) expect(notWiredReason(s), s.code).toMatch(/ยังบันทึกจริงไม่ได้/);
  });

  /**
   * หมวดอัตราแลกเปลี่ยนแยกด้วยธง `requires` ไม่ได้ เพราะ `trf.fx_convert` ใช้ `transferTarget` เหมือนการโอนธรรมดา
   * จึงตัดสินจาก **คู่บัญชีที่ตารางกฎประกาศ** (ผ่าน `fxKindOf`)
   *
   * **เปิดแล้ว (25/10)**: ฟอร์มมีแผงเลือกอัตราจากตาราง และ `postEntry` อ่านยอดเงินตรา/อัตราตามบัญชี/ผลต่างที่ค้างจากสมุดเอง
   * พิสูจน์กับ Postgres จริงใน `fx-posting.pg.test.ts` — ด่านนี้จึงไม่กั้นอีก ส่วน "ข้อมูลไม่ครบ" ถูกกั้นที่ `postEntry`
   * (ไม่ส่งอัตรา → ปฏิเสธ · ดู post-entry.test.ts ของ actions)
   */
  const touchesFx = (s: (typeof subs)[number]) =>
    [s.dr, s.cr, s.gainCoa, s.lossCoa].some(
      (c) => c === FX_TRANSLATION_DIFF_COA || c === REALISED_FX_GAIN || c === REALISED_FX_LOSS
    );

  it("หมวดแปลงค่า/แลกเงินตราทั้งสามหมวดไม่ถูกกั้นแล้ว (และต้องมีอยู่จริง ไม่ใช่ทดสอบชุดว่าง)", () => {
    const fx = subs.filter(touchesFx);
    expect(fx.map((s) => s.code).sort()).toEqual(["trf.fx_convert", "trf.fx_translate_down", "trf.fx_translate_up"]);
    for (const s of fx) expect(notWiredReason(s), s.code).toBeNull();
  });

  it("แลกเงินยังมีธง requires เหมือนการโอนธรรมดา (จึงแยกด้วยธงไม่ได้ ต้องแยกจากคู่บัญชี) และทั้งคู่ลงได้", () => {
    const convert = subs.find((s) => s.code === "trf.fx_convert");
    const plain = subs.find((s) => s.code === "trf.internal");
    expect(convert!.requires).toEqual(plain!.requires);
    expect(notWiredReason(convert!)).toBeNull();
    expect(notWiredReason(plain!)).toBeNull();
  });

  it("หมวดอื่นไม่ถูกกั้น (เช่น ค่าเช่า) และไม่รู้จักหมวดไม่ทำให้พัง", () => {
    const free = subs.filter(
      (s) => !s.requires?.includes("loanTerms") && !s.requires?.includes("capitalGain") && !touchesFx(s)
    );
    expect(free.length).toBeGreaterThan(0);
    for (const s of free) expect(notWiredReason(s), s.code).toBeNull();
    expect(notWiredReason(undefined)).toBeNull();
  });
});

describe("humanizeDbError · ข้อความจาก DB ต้องถึงผู้ใช้ ไม่ถูกกลืน", () => {
  it("ข้อความไทยจากด่านของ DB ส่งต่อตามเดิมทั้งก้อน", () => {
    const m = "บันทึกรายการไม่ได้: บัญชีนี้ปิดใช้งานแล้ว";
    expect(humanizeDbError({ message: m, code: "P0001" })).toBe(m);
  });

  it("RLS ปฏิเสธ → บอกเรื่องสิทธิ์ และแนบข้อความเทคนิคไว้ให้ผู้ดูแล", () => {
    const out = humanizeDbError({ message: 'new row violates row-level security policy for table "transactions"', code: "42501" });
    expect(out).toMatch(/ไม่มีสิทธิ์/);
    expect(out).toMatch(/row-level security/);
  });

  it("ขาดการเชื่อมต่อ → บอกว่ายังไม่ทราบผล ห้ามกดซ้ำโดยไม่ตรวจ", () => {
    expect(humanizeDbError({ message: "TypeError: fetch failed" })).toMatch(/ยังไม่ทราบว่ารายการถูกบันทึกหรือไม่/);
  });

  it("error ที่ไม่รู้จัก → ไม่ใช่คำว่าสำเร็จ และบอกว่ายังไม่มีรายการถูกบันทึก", () => {
    const out = humanizeDbError({ message: "something odd", code: "XX000" });
    expect(out).toMatch(/ไม่รับรายการ/);
    expect(out).not.toMatch(/สำเร็จ/);
    expect(humanizeDbError(null)).toMatch(/ไม่รับรายการ/);
  });
});

describe("makeResolver · resolver จากข้อมูลจริงใน DB กับ engine", () => {
  const ref: Pick<Reference, "owners" | "banks"> = {
    owners: [
      { id: "o-person", code: "P", name: "ธนากร", policy: "personal_flexible", status: "active", color: null, sortOrder: 1 },
      { id: "o-corp", code: "C", name: "SRI Corporation", policy: "corporate_strict", status: "active", color: null, sortOrder: 2 },
    ],
    banks: [
      { id: "b-open", ownerId: "o-person", name: "ธนากร - BBL", bank: "BBL", last4: null, isActive: true, sortOrder: 1, currency: "THB" },
      { id: "b-closed", ownerId: "o-person", name: "ธนากร - TTB (ปิด)", bank: "TTB", last4: null, isActive: false, sortOrder: 2, currency: "THB" },
    ],
  };
  const resolver = makeResolver(ref);

  it("หาไม่เจอคืน null (engine แปลงเป็น PostingError เอง)", () => {
    expect(resolver.owner("nope")).toBeNull();
    expect(resolver.bankAccount("nope")).toBeNull();
  });

  it("บัญชีที่ปิดแล้วยังหาเจอ แต่ isActive = false (D-092) และ engine ปฏิเสธการลงรายการใหม่", () => {
    expect(resolver.bankAccount("b-closed")?.isActive).toBe(false);
    const input: PostingInput = { ...rent, ownerId: "o-person", bankAccountId: "b-closed" };
    expect(() => buildPosting(input, resolver)).toThrow(PostingError);
  });

  it("ผู้ถือที่ไม่มีใน DB ถูกปฏิเสธ ไม่ถูกเดา", () => {
    const input: PostingInput = { ...rent, ownerId: "ghost", bankAccountId: "b-open" };
    expect(() => buildPosting(input, resolver)).toThrow(PostingError);
  });

  it("บัญชีเปิด + ผู้ถือตรงกัน → ลงได้ และ policy มาจาก DB (บุคคลไม่บังคับไฟล์แนบ)", () => {
    const input: PostingInput = { ...rent, ownerId: "o-person", bankAccountId: "b-open" };
    expect(buildPosting(input, resolver).transactions).toHaveLength(1);
  });
});

import { refuseInactiveOwners, readPostResult } from "../post-entry";

describe("refuseInactiveOwners · ผู้ถือที่ payload แตะต้อง active ทั้ง owner_id และ counter_owner_id", () => {
  const owners = [
    { id: "ok1", name: "ธนากร", status: "active" },
    { id: "ok2", name: "สุธี", status: "active" },
    { id: "pl", name: "SRI Holding", status: "planned" },
    { id: "off", name: "เก่า", status: "inactive" },
  ];
  const payload = (owner_id: string, counter_owner_id?: string) => ({
    transactions: [{ owner_id, counter_owner_id, lines: [] }],
  });

  it("ผ่านเมื่อทุกฝั่ง active (และไม่มีคู่ก็ผ่าน)", () => {
    expect(refuseInactiveOwners(payload("ok1"), owners)).toBeNull();
    expect(refuseInactiveOwners(payload("ok1", "ok2"), owners)).toBeNull();
  });

  it("ทางช่อง owner_id", () => {
    expect(refuseInactiveOwners(payload("pl"), owners)).toMatch(/ยังไม่ได้จดทะเบียน/);
    expect(refuseInactiveOwners(payload("off"), owners)).toMatch(/ไม่ได้ใช้งานอยู่/);
  });

  it("ทางช่อง counter_owner_id — owner_id ปกติแต่ปลายทางเป็น planned ต้องถูกปฏิเสธ", () => {
    expect(refuseInactiveOwners(payload("ok1", "pl"), owners)).toMatch(/SRI Holding.*ยังไม่ได้จดทะเบียน/);
    expect(refuseInactiveOwners(payload("ok1", "off"), owners)).toMatch(/ไม่ได้ใช้งานอยู่/);
  });

  it("ผู้ถือที่ไม่มีในข้อมูลอ้างอิง (ทั้งสองช่อง) ถูกปฏิเสธ ไม่ถือว่าผ่าน", () => {
    expect(refuseInactiveOwners(payload("ghost"), owners)).toMatch(/ไม่รู้จักผู้ถือ/);
    expect(refuseInactiveOwners(payload("ok1", "ghost"), owners)).toMatch(/ไม่รู้จักผู้ถือ/);
  });

  it("ตรวจทุกก้อนของรายการข้ามผู้ถือ ไม่ใช่แค่ก้อนแรก", () => {
    const two = { transactions: [{ owner_id: "ok1", lines: [] }, { owner_id: "pl", lines: [] }] };
    expect(refuseInactiveOwners(two, owners)).toMatch(/ยังไม่ได้จดทะเบียน/);
  });
});

describe("readPostResult · ตอบสำเร็จได้ก็ต่อเมื่อ DB คืน id ครบ", () => {
  it("ครบ → สำเร็จ · ขาด/ว่าง/null/ชนิดผิด → ไม่สำเร็จ", () => {
    expect(readPostResult({ transaction_ids: ["a", "b"], replayed: true }, 2)).toEqual({ ok: true, transactionIds: ["a", "b"], replayed: true });
    expect(readPostResult({ transaction_ids: ["a"] }, 2).ok).toBe(false);
    expect(readPostResult({ transaction_ids: [] }, 1).ok).toBe(false);
    expect(readPostResult(null, 1).ok).toBe(false);
    expect(readPostResult({ transaction_ids: [1, 2] }, 2).ok).toBe(false);
  });
});
