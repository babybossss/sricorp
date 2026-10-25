import { describe, expect, it } from "vitest";
import { buildPosting } from "@/lib/ledger/posting";
import { PostingError, type PostingInput } from "@/lib/ledger/types";
import { findSub } from "@/lib/rules/tx-rules";
import { toThb } from "@/lib/rules/currency";
import { buildFxContext, positionOf, unrealizedOf, type FxAccountContext, type FxRate } from "../fx-context";
import { fxInputFor, fxKindOf } from "../fx-input";
import { makeResolver } from "../resolver";
import type { Reference } from "../reference-types";

const sub = (code: string) => findSub(code)!.sub;
const rate = (rateDate: string, thbPerUnit: number): FxRate => ({ currency: "USD", rateDate, thbPerUnit });

const REF: Pick<Reference, "owners" | "banks"> = {
  owners: [{ id: "o1", code: "O1", name: "ธนากร", policy: "personal_flexible", status: "active", color: null, sortOrder: 1 }],
  banks: [
    { id: "fcd", ownerId: "o1", name: "FCD USD", bank: "BBL", last4: null, isActive: true, sortOrder: 1, currency: "USD" },
    { id: "thb", ownerId: "o1", name: "บาท", bank: "BBL", last4: null, isActive: true, sortOrder: 2, currency: "THB" },
  ],
};
const resolver = makeResolver(REF);

/** บริบทที่เกิดจากการฝากเงินตราครั้งเดียว: units USD @rate (ยอดบาทตั้งอยู่ที่อัตรานั้นพอดี) */
const ctxOf = (units: number, depositRate: number, rates: FxRate[], unrealized = 0): FxAccountContext =>
  buildFxContext({
    bankAccountId: "fcd",
    ownerId: "o1",
    currency: "USD",
    bankLines: [{ debit: toThb(units, depositRate), credit: 0, amount_original: units, fx_rate_date: rates[rates.length - 1]?.rateDate ?? null }],
    diffLines: unrealized === 0 ? [] : [{ debit: unrealized < 0 ? -unrealized : 0, credit: unrealized > 0 ? unrealized : 0, currency: "USD" }],
    singleCurrencyOwner: true,
    rates,
  });

describe("fxKindOf · ตัดสินจากคู่บัญชีในตารางกฎ ไม่ใช่รหัสหมวด", () => {
  it("แปลงค่าสองหมวด → translation · แลกเงิน → conversion · หมวดอื่น (รวมโอนระหว่างบัญชีตัวเองที่มีธงเดียวกับแลกเงิน) → null", () => {
    expect(fxKindOf(sub("trf.fx_translate_up"))).toBe("translation");
    expect(fxKindOf(sub("trf.fx_translate_down"))).toBe("translation");
    expect(fxKindOf(sub("trf.fx_convert"))).toBe("conversion");
    expect(sub("trf.fx_convert").requires).toEqual(sub("trf.internal").requires); // ธง requires แยกไม่ได้
    expect(fxKindOf(sub("trf.internal"))).toBeNull();
    expect(fxKindOf(sub("inc.rent"))).toBeNull();
    expect(fxKindOf(undefined)).toBeNull();
  });
});

describe("positionOf / unrealizedOf · รวมจากสมุดด้วยเลขจำนวนเต็ม", () => {
  it("เดบิต → +เงินตรา · เครดิต → −เงินตรา · บรรทัดแปลงค่า (เงินตรา 0) ขยับแต่ยอดบาท", () => {
    const p = positionOf([
      { debit: 365000, credit: 0, amount_original: 10000, fx_rate_date: "2026-10-31" },
      { debit: 5000, credit: 0, amount_original: 0, fx_rate_date: "2026-11-30" },
      { debit: 0, credit: 148000, amount_original: 4000, fx_rate_date: "2026-11-30" },
    ]);
    expect(p).toEqual({ units: 6000, bookThb: 222000 });
  });
  it("ไม่สะสมความคลาดทศนิยมลอยตัว: 0.1 บวก 0.2 ร้อยครั้งยังเป็นสตางค์ตรง", () => {
    const lines = Array.from({ length: 100 }, () => ({ debit: 0.1 + 0.2, credit: 0, amount_original: 0.1 + 0.2, fx_rate_date: null }));
    expect(positionOf(lines)).toEqual({ units: 30, bookThb: 30 });
  });
  it("3410: เครดิต − เดบิต · แยกตามป้ายสกุลเมื่อผู้ถือมีหลายสกุล", () => {
    const lines = [
      { debit: 0, credit: 5000, currency: "USD" },
      { debit: 2000, credit: 0, currency: "USD" },
      { debit: 0, credit: 700, currency: "JPY" },
    ];
    expect(unrealizedOf(lines)).toBe(3700);
    expect(unrealizedOf(lines, "USD")).toBe(3000);
  });
});

describe("buildFxContext · อัตราตามบัญชีต้องเป็นแถวจริงในตารางอัตรา", () => {
  const rates = [rate("2026-12-31", 37.5), rate("2026-12-15", 36.5), rate("2026-11-30", 37), rate("2026-10-31", 36.5)];

  it("ฝาก 10,000 USD @36.50 → อัตราตามบัญชีคือแถวของวันที่ฝาก (2026-10-31) ไม่ใช่แถวใหม่สุดที่อัตราบังเอิญเท่ากัน", () => {
    const c = ctxOf(10000, 36.5, rates);
    expect(c).toMatchObject({ units: 10000, bookThb: 365000, bookRate: 36.5, unrealized: 0 });
    expect(c.bookRateRow).toEqual(rate("2026-10-31", 36.5));
    expect(c.bookRateDate).toBe("2026-10-31");
  });

  it("ฝากสองอัตรา (ยอดบาทตั้งอยู่ที่ 36.75 ซึ่งไม่มีในตาราง) → ไม่มีแถว · แต่มีอัตราเฉลี่ยให้แปลงค่าได้", () => {
    const c = buildFxContext({
      bankAccountId: "fcd", ownerId: "o1", currency: "USD", singleCurrencyOwner: true, rates, diffLines: [],
      bankLines: [
        { debit: 365000, credit: 0, amount_original: 10000, fx_rate_date: "2026-10-31" },
        { debit: 370000, credit: 0, amount_original: 10000, fx_rate_date: "2026-11-30" },
      ],
    });
    expect(c).toMatchObject({ units: 20000, bookThb: 735000, bookRate: 36.75, bookRateRow: null, bookRateDate: "2026-11-30" });
  });

  it("ไม่มีเงินตราคงเหลือ → ไม่มีอัตรา ไม่มีแถว", () => {
    const c = buildFxContext({ bankAccountId: "fcd", ownerId: "o1", currency: "USD", singleCurrencyOwner: true, rates, diffLines: [], bankLines: [] });
    expect(c).toMatchObject({ units: 0, bookRate: null, bookRateRow: null, bookRateDate: null });
  });

  it("กรองอัตราเฉพาะสกุลของบัญชี และเรียงใหม่ก่อน", () => {
    const c = buildFxContext({
      bankAccountId: "fcd", ownerId: "o1", currency: "USD", singleCurrencyOwner: true, diffLines: [], bankLines: [],
      rates: [{ currency: "JPY", rateDate: "2026-12-31", thbPerUnit: 0.25 }, rate("2026-10-31", 36.5), rate("2026-12-31", 37.5)],
    });
    expect(c.rates.map((r) => r.rateDate)).toEqual(["2026-12-31", "2026-10-31"]);
  });
});

describe("fxInputFor · ไม่ส่งข้อมูล / ข้อมูลไม่ครบ → ปฏิเสธพร้อมบอกวิธีแก้ (ไม่เดา)", () => {
  const rates = [rate("2026-12-31", 37.5), rate("2026-11-30", 37), rate("2026-10-31", 36.5)];
  const ctx = ctxOf(10000, 36.5, rates);

  it("แปลงค่า: ไม่เลือกอัตรา · เลือกวันที่ไม่มีในตาราง → ไม่ผ่าน", () => {
    expect(fxInputFor(sub("trf.fx_translate_up"), ctx, {})).toMatchObject({ ok: false, message: expect.stringMatching(/เลือกอัตราสิ้นงวด/) });
    expect(fxInputFor(sub("trf.fx_translate_up"), ctx, { newRateDate: "2026-11-29" })).toMatchObject({ ok: false, message: expect.stringMatching(/ไม่มีอัตรา USD ของวันที่ 2026-11-29/) });
  });

  it("แลกเงิน: ไม่เลือกอัตรา · ไม่ใส่จำนวน · จำนวน ≤ 0 · เกินยอดคงเหลือ → ไม่ผ่านทุกกรณี", () => {
    const s = sub("trf.fx_convert");
    const no = (c: Parameters<typeof fxInputFor>[2], re: RegExp) => expect(fxInputFor(s, ctx, c)).toMatchObject({ ok: false, message: expect.stringMatching(re) });
    no({}, /เลือกอัตราที่แลกได้จริง/);
    no({ dealRateDate: "2026-12-31" }, /กรอกจำนวน USD/);
    no({ dealRateDate: "2026-12-31", amountOriginal: 0 }, /กรอกจำนวน USD/);
    no({ dealRateDate: "2026-12-31", amountOriginal: -1 }, /กรอกจำนวน USD/);
    no({ dealRateDate: "2026-12-31", amountOriginal: Number.NaN }, /กรอกจำนวน USD/);
    no({ dealRateDate: "2026-12-31", amountOriginal: 10001 }, /มากกว่ายอดคงเหลือ/);
    no({ dealRateDate: "2026-09-09", amountOriginal: 1 }, /ไม่มีอัตรา USD/);
  });

  it("ไม่มีเงินตราคงเหลือ → ไม่ผ่านทั้งสองหมวด", () => {
    const empty = buildFxContext({ bankAccountId: "fcd", ownerId: "o1", currency: "USD", singleCurrencyOwner: true, rates, diffLines: [], bankLines: [] });
    expect(fxInputFor(sub("trf.fx_translate_up"), empty, { newRateDate: "2026-12-31" }).ok).toBe(false);
    expect(fxInputFor(sub("trf.fx_convert"), empty, { dealRateDate: "2026-12-31", amountOriginal: 1 }).ok).toBe(false);
  });

  it("แลกเงินเมื่อยอดบาทไม่ตั้งอยู่ที่อัตราใดในตาราง → ไม่ผ่าน และบอกให้แปลงค่าก่อน", () => {
    const mixed = buildFxContext({
      bankAccountId: "fcd", ownerId: "o1", currency: "USD", singleCurrencyOwner: true, rates, diffLines: [],
      bankLines: [
        { debit: 365000, credit: 0, amount_original: 10000, fx_rate_date: "2026-10-31" },
        { debit: 370000, credit: 0, amount_original: 10000, fx_rate_date: "2026-11-30" },
      ],
    });
    const r = fxInputFor(sub("trf.fx_convert"), mixed, { dealRateDate: "2026-12-31", amountOriginal: 100 });
    expect(r).toMatchObject({ ok: false, message: expect.stringMatching(/แปลงค่า” เป็นอัตราหนึ่งก่อน/) });
    // แปลงค่ายังทำได้ (ใช้อัตราเฉลี่ย 36.75 เป็นอัตราตามบัญชี)
    expect(fxInputFor(sub("trf.fx_translate_up"), mixed, { newRateDate: "2026-12-31" }).ok).toBe(true);
  });

  it("เรียกกับหมวดที่ไม่เกี่ยวกับเงินตรา → โยก error (ผู้เรียกผิด ไม่ใช่ข้อมูลผู้ใช้ผิด)", () => {
    expect(() => fxInputFor(sub("inc.rent"), ctx, {})).toThrow();
  });
});

describe("fxInputFor ↔ buildPosting · ยอดที่ฟอร์มคำนวณให้ต้องเป็นยอดที่ engine ยอมรับ (ไม่ใช่สูตรเทียบกับสูตรตัวเอง)", () => {
  /** สุ่มแบบกำหนดผลได้ (LCG) — เทสต์ซ้ำได้เสมอ */
  const rng = (seed: number) => () => ((seed = (seed * 1664525 + 1013904223) % 4294967296) / 4294967296);
  const ACCEPT = (e: unknown) => !(e instanceof PostingError && /ผลต่างจากการแปลงค่าคือ|บาทที่ได้รับต้องเท่ากับ/.test(e.message));

  const post = (code: string, amount: number, patch: Pick<PostingInput, "fxTranslation" | "fxConversion">) =>
    buildPosting(
      {
        typeKey: "transfer",
        subCode: code,
        amount,
        ownerId: "o1",
        bankAccountId: "fcd",
        ...(code === "trf.fx_convert" ? { transferToBankAccountId: "thb" } : {}),
        ...patch,
      },
      resolver
    );

  it("แปลงค่า: 300 กรณีสุ่ม — ยอดที่คำนวณผ่านเรื่องยอด · ยอดคลาด 1 สตางค์ถูกปฏิเสธเรื่องยอด · หมวดทิศตรงผ่านเต็ม", () => {
    const next = rng(20261025);
    let full = 0;
    for (let i = 0; i < 300; i++) {
      const units = Math.round((1 + next() * 99999) * 100) / 100;
      const depositRate = Math.round((20 + next() * 30) * 10000) / 10000;
      const newRate = Math.round((20 + next() * 30) * 10000) / 10000;
      const rates = [rate("2026-12-31", newRate), rate("2026-10-31", depositRate)];
      const ctx = ctxOf(units, depositRate, rates);
      const up = toThb(units, newRate) > toThb(units, depositRate);
      if (toThb(units, newRate) === toThb(units, depositRate)) continue;
      const code = up ? "trf.fx_translate_up" : "trf.fx_translate_down";
      const built = fxInputFor(sub(code), ctx, { newRateDate: "2026-12-31" });
      expect(built.ok, `${units} @${depositRate}→${newRate}`).toBe(true);
      if (!built.ok) continue;
      // ยอดที่คำนวณ: engine ต้องไม่ปฏิเสธเรื่องยอด (ผ่านเต็มหรือล้มเรื่องอื่น เช่นทิศ — แต่ที่นี่เลือกหมวดทิศตรงแล้ว จึงต้องผ่านเต็ม)
      expect(() => post(code, built.amount, built.patch), `${units} @${depositRate}→${newRate} = ${built.amount}`).not.toThrow();
      full++;
      // คลาด 1 สตางค์ในสองทิศ → ต้องถูกปฏิเสธเรื่องยอด
      for (const bad of [Math.round((built.amount + 0.01) * 100) / 100, Math.round((built.amount - 0.01) * 100) / 100]) {
        if (bad <= 0) continue;
        let thrown: unknown;
        try {
          post(code, bad, built.patch);
        } catch (e) {
          thrown = e;
        }
        expect(thrown, `ยอดคลาด ${bad} ควรถูกปฏิเสธ`).toBeInstanceOf(PostingError);
        expect(ACCEPT(thrown)).toBe(false);
      }
    }
    expect(full).toBeGreaterThan(250);
  });

  it("แลกเงิน: 300 กรณีสุ่ม (รวมแลกบางส่วน · มีผลต่างค้างทั้งบวกและลบ) — ยอดบาทที่ได้รับตรงกับ engine และผิด 1 สตางค์ถูกปฏิเสธ", () => {
    const next = rng(25102026);
    let n = 0;
    for (let i = 0; i < 300; i++) {
      const units = Math.round((10 + next() * 99990) * 100) / 100;
      const bookRate = Math.round((20 + next() * 30) * 10000) / 10000;
      const dealRate = Math.round((20 + next() * 30) * 10000) / 10000;
      const unrealized = Math.round((next() - 0.5) * 2 * 50000 * 100) / 100;
      const ao = Math.round((1 + next() * (units - 1)) * 100) / 100;
      const rates = [rate("2026-12-31", dealRate), rate("2026-10-31", bookRate)];
      const ctx = ctxOf(units, bookRate, rates, unrealized);
      if (!ctx.bookRateRow) continue; // ยอดบาทปัดจนไม่ตรงอัตราใด — เป็นเคสที่ฟอร์มปฏิเสธ (มีเทสต์แยก)
      const built = fxInputFor(sub("trf.fx_convert"), ctx, { dealRateDate: "2026-12-31", amountOriginal: ao });
      expect(built.ok).toBe(true);
      if (!built.ok) continue;
      let outcome: unknown = null;
      try {
        post("trf.fx_convert", built.amount, built.patch);
      } catch (e) {
        outcome = e;
      }
      // ผ่านเต็ม หรือมีเหตุอื่นที่ไม่ใช่ยอดบาทที่ได้รับ (เช่น ผลต่างค้างขัดกับสัดส่วน) — แต่ต้องไม่ใช่ "บาทที่ได้รับต้องเท่ากับ"
      expect(ACCEPT(outcome), `${ao}/${units} USD @book ${bookRate} deal ${dealRate} → ${built.amount}`).toBe(true);
      n++;
      let thrown: unknown;
      try {
        post("trf.fx_convert", Math.round((built.amount + 0.01) * 100) / 100, built.patch);
      } catch (e) {
        thrown = e;
      }
      expect(thrown).toBeInstanceOf(PostingError);
      expect((thrown as PostingError).message).toMatch(/บาทที่ได้รับต้องเท่ากับ/);
    }
    expect(n).toBeGreaterThan(200);
  });

  it("ตัวเลขของลูกพี่: ถือ 10,000 USD ที่ 37.00 แลกออกที่ 36.50 → ขาดทุน 5,000 (5930) ผ่าน engine ครบ ไม่มีบรรทัดล้าง 3410 เมื่อไม่มีผลต่างค้าง", () => {
    const rates = [rate("2026-12-15", 36.5), rate("2026-11-30", 37)];
    const ctx = ctxOf(10000, 37, rates);
    const built = fxInputFor(sub("trf.fx_convert"), ctx, { dealRateDate: "2026-12-15", amountOriginal: 10000 });
    expect(built).toMatchObject({ ok: true, amount: 365000 });
    if (!built.ok) return;
    const out = post("trf.fx_convert", built.amount, built.patch);
    const lines = out.transactions[0].lines;
    expect(lines.find((l) => l.coaCode === "5930")).toMatchObject({ debit: 5000 });
    expect(lines.some((l) => l.coaCode === "3410")).toBe(false);
    expect(lines.reduce((t, l) => t + l.debit - l.credit, 0)).toBe(0);
  });
});
