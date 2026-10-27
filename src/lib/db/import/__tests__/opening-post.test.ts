import { describe, expect, it } from "vitest";
import { parseOpeningWorkbook, type ParsedOpening } from "../opening";
import { isPendingAssetId, openingSubByAccount, prepareOpeningPosting, type OpeningAsset, type PrepareEnv } from "../opening-post";
import { runOpeningImport } from "../opening-run";
import { CUTOFF, ctxOf, loadFixture, setBreakdown, breakdownRowsFromBs, setCell } from "./helpers";
import { ASSET_IDS, ITEM_ASSET_IDS, assetsOf, itemAssetsOf, itemName, noRates, postableWorkbook, refOf, setByCode } from "./post-helpers";
import type { Workbook } from "../xlsx";

const LOTS = "พอร์ตลงทุน (รายล็อต)";
const parse = (wb: Workbook = postableWorkbook()): ParsedOpening => {
  const r = parseOpeningWorkbook(wb, ctxOf());
  if (!r.ok) throw new Error(r.issues.map((i) => `${i.sheet}#${i.row ?? "-"} ${i.message}`).join("\n"));
  return r.parsed;
};
const env = (over: Partial<PrepareEnv> = {}): PrepareEnv => ({ ref: refOf(), assets: assetsOf(), fxRates: noRates, mode: "preview", ...over });
const ok = (p: ParsedOpening, e: PrepareEnv = env()) => {
  const r = prepareOpeningPosting(p, e);
  if (!r.ok) throw new Error(r.problems.map((x) => `${x.ownerName ?? "-"}: ${x.message}`).join("\n"));
  return r;
};
const bad = (p: ParsedOpening, e: PrepareEnv = env()) => {
  const r = prepareOpeningPosting(p, e);
  if (r.ok) throw new Error("ควรถูกปฏิเสธแต่ผ่าน");
  return r.problems;
};
const owner = (r: ReturnType<typeof ok>, id: string) => r.owners.find((o) => o.ownerId === id)!;

describe("ตารางเทียบรหัสบัญชี → หมวดยอดยกมา (อ่านจากตารางกฎ)", () => {
  it("ตรงกับตารางกฎ 29 รหัส (ทุกบัญชีงบดุลยกเว้นส่วนของเจ้าของ 3200/3300/3400/3410) — ไม่มีรหัสเพิ่มหรือขาด", () => {
    const expected: Record<string, string> = {
      "1100": "opn.cash", "1200": "opn.receivable_rent", "1210": "opn.receivable_interest", "1220": "opn.receivable_other",
      "1290": "opn.allowance", "1300": "opn.loan_principal", "1310": "opn.intercompany_receivable",
      // เงินให้กู้ยืมมีหลักประกัน (ลูกพี่สั่ง 27/10) — แยกจาก 1300
      "1320": "opn.loan_secured_principal",
      "1400": "opn.srr_principal", "1410": "opn.mortgage_principal", "1500": "opn.property", "1510": "opn.renovation",
      /**
       * **1520 อสังหาฯ เพื่อการขาย มีหมวดยอดยกมาของตัวเองแล้ว** (27/10 · ลูกพี่สั่ง)
       *
       * เดิมไม่มีโดยตั้งใจ ด้วยเหตุผลว่า "เปิดสองทางเข้าให้ทรัพย์ชิ้นเดียวกันแปลว่า
       * คนนำเข้าเลือกได้ว่าจะลงบัญชีไหน" → ทางที่เหลือคือลง 1500 แล้วย้ายอีกใบ
       * **ซึ่งแย่กว่า**: สมุดหน้าแรกของระบบบอกว่าทรัพย์ที่รอขายเป็นของให้เช่า
       * แล้วมีใบปรับปรุงตามมาแก้ทันที · ถ้าใครลืมใบที่สอง ยอดตั้งต้นของสองบัญชี
       * ผิดถาวรโดยที่งบดุลยังดุล (ไม่มีด่านไหนจับได้)
       *
       * วัตถุประสงค์ ณ วันตัดยอดเป็น **ข้อเท็จจริงของทรัพย์** ไม่ใช่ตัวเลือกของคนกรอก
       * — รูปเดียวกับ 1300 (เงินให้กู้) กับ 1320 (มีหลักประกัน) ที่เป็นสองทางเข้า
       * ของเรื่องเดียวกันโดยแยกตามข้อเท็จจริงของสัญญา
       */
      "1520": "opn.property_held_for_sale",
      "1600": "opn.deposit_paid", "1700": "opn.securities", "1710": "opn.related_investment", "1720": "opn.gold_alt",
      "1800": "opn.wht_credit",
      // บัญชีรองรับ (ลูกพี่สั่ง 26/10) — ต้องมีหมวดยอดยกมาด้วย ไม่งั้นนำเข้ายอดตั้งต้นไม่ได้
      "1900": "opn.other_current_asset", "1950": "opn.other_noncurrent_asset",
      "2100": "opn.payable", "2200": "opn.tenant_deposit", "2300": "opn.loan_director",
      "2310": "opn.intercompany_payable", "2400": "opn.loan_other", "2410": "opn.loan_bank",
      "2500": "opn.other_current_liability", "2600": "opn.other_noncurrent_liability",
      "3100": "opn.capital",
    };
    expect(Object.fromEntries([...openingSubByAccount()].map(([k, v]) => [k, v.code]))).toEqual(expected);
  });
});

describe("prepareOpeningPosting · ประกอบรายการผ่าน buildPosting", () => {
  it("รหัสบัญชีที่ตารางกฎไม่มีหมวดยอดยกมา → ปฏิเสธ ไม่ข้ามเงียบๆ ไม่ปัดเข้าบัญชีอื่น", () => {
    // 1310/2310 มีหมวดแล้ว (opn.intercompany_*) · เหลือแต่บัญชีส่วนของเจ้าของ 3400/3410 ที่ไม่มี → ใส่เข้าไปตรงๆ (ตัวอ่านไฟล์กันไว้ก่อนแล้ว จึงต้องแก้หลังอ่าน)
    const parsed = parse();
    const swap = (ownerName: string, from: string, to: string) => {
      const j = parsed.journals.find((x) => x.ownerName === ownerName)!;
      const line = j.lines.find((l) => l.coaCode === from)!;
      line.coaCode = to;
    };
    swap("ธนากร", "1200", "3400");
    swap("สุธี", "1100", "3410");
    const problems = bad(parsed);
    expect(problems.some((p) => p.ownerName === "ธนากร" && /3400.*ยังไม่มีหมวด "ยอดยกมา"/.test(p.message) && /20,000/.test(p.message))).toBe(true);
    expect(problems.some((p) => p.ownerName === "สุธี" && /3410.*ยังไม่มีหมวด "ยอดยกมา"/.test(p.message))).toBe(true);
  });

  it("ไฟล์ตัวอย่างเดิม (มี 1310 ของธนากร · 2310 ของสุธี) ลงได้ · ได้หมวดระหว่างกัน ไม่ถูกข้าม", () => {
    const r = ok(parse(loadFixture()));
    expect(owner(r, "o-thanakorn").payload.entries.map((e) => e.txn_type_code)).toContain("opn.intercompany_receivable");
    expect(owner(r, "o-suthee").payload.entries.map((e) => e.txn_type_code)).toContain("opn.intercompany_payable");
  });

  it("ไฟล์ที่ลงได้: ธนากร 9 ใบ · ทุกใบมาจาก engine · ผูกทรัพย์ต่อใบ · ทุกใบสมดุล · source = import", () => {
    const r = ok(parse());
    const tk = owner(r, "o-thanakorn");
    const subs = tk.payload.entries.map((e) => e.txn_type_code);
    expect([...subs].sort()).toEqual(
      ["opn.capital", "opn.cash", "opn.cash", "opn.loan_bank", "opn.property", "opn.receivable_rent", "opn.securities", "opn.securities", "opn.securities"]
    );
    expect(subs.at(-1)).toBe("opn.capital"); // ใบแยกทุนเป็นใบสุดท้ายตามที่ตารางกฎกำหนด
    for (const e of tk.payload.entries) {
      expect(e.source).toBe("import");
      expect(e.doc_date).toBe(CUTOFF);
      const lines = e.transactions.flatMap((t) => t.lines);
      expect(lines.reduce((t, l) => t + Math.round(l.debit * 100) - Math.round(l.credit * 100), 0)).toBe(0);
      expect(e.transactions.map((t) => t.owner_id)).toEqual(["o-thanakorn"]); // หนึ่งใบ = หนึ่งผู้ถือ
    }
    expect(tk.lineCount).toBe(18);
  });

  it("เงินสด: ใบละบัญชีธนาคาร มี cash_date = วันตัดยอด · ใบอื่นไม่มีบัญชีและไม่มี cash_date", () => {
    const tk = owner(ok(parse()), "o-thanakorn");
    const cash = tk.payload.entries.filter((e) => e.txn_type_code === "opn.cash");
    expect(cash.map((e) => [e.transactions[0].lines.find((l) => l.coa_code === "1100")!.bank_account_id, e.cash_date, e.transactions[0].lines.find((l) => l.coa_code === "1100")!.debit].join("|")).sort()).toEqual(
      ["b-tk-bbl|2026-09-30|600000", "b-tk-scb|2026-09-30|400000"].sort()
    );
    for (const e of tk.payload.entries.filter((x) => x.txn_type_code !== "opn.cash")) {
      expect(e.cash_date).toBeNull();
      expect(e.transactions[0].lines.every((l) => !l.bank_account_id)).toBe(true);
    }
  });

  it("หุ้น/กองทุน: ลงต่อทรัพย์หนึ่งใบ — asset_id ที่หัวรายการและที่บรรทัด 1700 · ขา 3300 ไม่ผูกทรัพย์ · ยอดต่อทรัพย์ = ต้นทุนล็อต", () => {
    const tk = owner(ok(parse()), "o-thanakorn");
    const sec = tk.payload.entries.filter((e) => e.txn_type_code === "opn.securities");
    const byAsset = Object.fromEntries(
      sec.map((e) => {
        const l1700 = e.transactions[0].lines.find((l) => l.coa_code === "1700")!;
        const l3300 = e.transactions[0].lines.find((l) => l.coa_code === "3300")!;
        expect(l3300.asset_id).toBeUndefined();
        expect(l1700.asset_id).toBe(e.asset_id);
        return [e.asset_id, l1700.debit];
      })
    );
    expect(byAsset).toEqual({ [ASSET_IDS.ptt]: 70_000, [ASSET_IDS.set50]: 100_000, [ASSET_IDS.kfixed]: 130_000 });
    expect(tk.payload.lots.map((l) => [l.asset_id, l.cost_thb, l.quantity])).toEqual([
      [ASSET_IDS.ptt, 70_000, 2000],
      [ASSET_IDS.set50, 100_000, 100],
      [ASSET_IDS.kfixed, 130_000, 1299],
    ]);
    expect(tk.payload.lots.every((l) => l.currency === undefined && l.fx_rate === undefined)).toBe(true); // ล็อตบาทไม่มีชุดสกุลเงิน
  });

  it("สุทธิต่อรหัสบัญชีตรงไฟล์ทุกรหัส รวมกำไรสะสมที่ engine เติมเป็นขาคู่ (1,820,000 ของธนากร)", () => {
    const r = ok(parse());
    const net = (id: string) => {
      const m = new Map<string, number>();
      for (const e of owner(r, id).payload.entries)
        for (const l of e.transactions.flatMap((t) => t.lines)) m.set(l.coa_code, (m.get(l.coa_code) ?? 0) + Math.round(l.debit * 100) - Math.round(l.credit * 100));
      return Object.fromEntries([...m].map(([k, v]) => [k, v / 100]));
    };
    expect(net("o-thanakorn")).toEqual({
      "1100": 1_000_000, "1200": 20_000, "1500": 3_000_000, "1700": 300_000, "2410": -500_000, "3100": -2_000_000, "3300": -1_820_000,
    });
    expect(net("o-suthee")).toEqual({ "1100": 300_000, "3100": -200_000, "3300": -100_000 });
  });

  it("ผู้ถือที่ไม่มียอดในไฟล์ได้ entries ว่าง (ประตูจะกลับรายการชุดเดิมถ้าเคยนำเข้า) — ไม่ถูกข้าม", () => {
    const r = ok(parse());
    for (const id of ["o-sudjit", "o-thanawin", "o-benjaporn"]) expect(owner(r, id).payload).toEqual({ entries: [], lots: [] });
    expect(r.owners.map((o) => o.ownerId).sort()).toEqual(["o-benjaporn", "o-sri", "o-sudjit", "o-suthee", "o-thanakorn", "o-thanawin"]);
  });
});

describe("ทรัพย์ของล็อต: อ่านจากระบบ ไม่เดา ไม่สร้างให้", () => {
  it("ไม่ส่งทรัพย์มาเลย → ปฏิเสธทุกล็อตพร้อมบอกวิธีแก้ (ไม่ลงเป็นก้อนรวมที่ไม่ผูกทรัพย์)", () => {
    const problems = bad(parse(), env({ assets: [] }));
    expect(problems.filter((p) => /ไม่พบทรัพย์/.test(p.message))).toHaveLength(3);
    expect(problems.find((p) => /ไม่พบทรัพย์/.test(p.message))!.message).toMatch(/ต้องสร้างทรัพย์ก่อน/);
  });

  it("จับคู่ด้วยรหัสก่อนชื่อ · ไม่สนตัวพิมพ์ · ทรัพย์ของผู้ถือคนอื่นไม่นับ", () => {
    const assets = assetsOf().map((a) => (a.id === ASSET_IDS.ptt ? { ...a, ownerId: "o-suthee" } : a));
    const problems = bad(parse(), env({ assets }));
    expect(problems.some((p) => /"PTT".*ไม่พบทรัพย์/.test(p.message))).toBe(true);
    expect(problems.filter((p) => /ไม่พบทรัพย์/.test(p.message))).toHaveLength(1); // k-fixed จับคู่รหัสแม้ตัวพิมพ์ต่าง · SET50 จับด้วยชื่อ
  });

  it("ทรัพย์ซ้ำชื่อ/รหัส → ปฏิเสธ ไม่เลือกให้", () => {
    const assets: OpeningAsset[] = [...assetsOf(), { id: "dup", code: "PTT", name: "อีกตัว", ownerId: "o-thanakorn", status: "active", currency: "THB" }];
    expect(bad(parse(), env({ assets })).some((p) => /มีทรัพย์ 2 รายการ/.test(p.message))).toBe(true);
  });

  it("ทรัพย์ที่จำหน่ายแล้ว หรือสกุลไม่ตรงกับล็อต → ปฏิเสธ", () => {
    const sold = assetsOf().map((a) => (a.id === ASSET_IDS.ptt ? { ...a, status: "sold" } : a));
    expect(bad(parse(), env({ assets: sold })).some((p) => /สถานะ "sold"/.test(p.message))).toBe(true);
    const usd = assetsOf().map((a) => (a.id === ASSET_IDS.ptt ? { ...a, currency: "USD" } : a));
    expect(bad(parse(), env({ assets: usd })).some((p) => /เป็นสกุล USD แต่ล็อตในไฟล์เป็นสกุล THB/.test(p.message))).toBe(true);
  });

  it("ล็อตสองล็อตของทรัพย์เดียวกัน → ลงใบเดียวของทรัพย์นั้น ยอดรวมต้นทุน", () => {
    const wb = postableWorkbook();
    setCell(wb, LOTS, 7, "C", "PTT"); // SET50 (100,000) ไปเป็นล็อตที่สองของ PTT
    const tk = owner(ok(parse(wb)), "o-thanakorn");
    const ptt = tk.payload.entries.filter((e) => e.asset_id === ASSET_IDS.ptt);
    expect(ptt).toHaveLength(1);
    expect(ptt[0].transactions[0].lines.find((l) => l.coa_code === "1700")!.debit).toBe(170_000);
    expect(tk.payload.lots.filter((l) => l.asset_id === ASSET_IDS.ptt).map((l) => l.cost_thb)).toEqual([70_000, 100_000]);
  });

  it("ทรัพย์เดียวมีล็อตสองประเภทบัญชี (หุ้น 1700 กับทอง 1720) → ปฏิเสธ", () => {
    const wb = postableWorkbook();
    setCell(wb, LOTS, 7, "C", "PTT");
    setCell(wb, LOTS, 7, "B", "ทองคำ"); // 100,000 ย้ายจาก 1700 ไป 1720 → ต้องปรับยอดสองบัญชีให้ตรงล็อตก่อนถึงจะผ่าน parse
    setByCode(wb, "BS-ธนากร", "1700", 200_000);
    setByCode(wb, "BS-ธนากร", "1720", 100_000);
    expect(bad(parse(wb)).some((p) => /ลงคนละบัญชี/.test(p.message))).toBe(true);
  });
});

describe("ล็อตสกุลต่างประเทศ: อัตราต้องมีอยู่จริงและตรงตารางอัตรา", () => {
  const usdWorkbook = () => {
    const wb = postableWorkbook();
    setCell(wb, LOTS, 4, "J", "อัตรา ณ วันซื้อ *");
    setCell(wb, LOTS, 6, "I", "USD");
    setCell(wb, LOTS, 6, "E", 2000);
    setCell(wb, LOTS, 6, "F", 1);
    setCell(wb, LOTS, 6, "J", 35);
    return wb; // PTT = 2,000 USD × 35 = 70,000 บาท (เท่ายอด 1700 เดิม)
  };
  const usdAssets = () => assetsOf().map((a) => (a.id === ASSET_IDS.ptt ? { ...a, currency: "USD" } : a));
  const rate = (date: string, v: number) => ({ currency: "USD", rateDate: date, thbPerUnit: v });
  const lotOf = (r: ReturnType<typeof ok>) => owner(r, "o-thanakorn").payload.lots.find((l) => l.asset_id === ASSET_IDS.ptt)!;

  it("วันซื้อมีอัตราตรงกัน → ล็อตส่งสกุล · ยอดสกุลเดิม · อัตรา · วันของอัตราครบทั้งสี่ และต้นทุนบาทถูก", () => {
    const r = ok(parse(usdWorkbook()), env({ assets: usdAssets(), fxRates: [rate("2025-03-03", 35)] }));
    expect(lotOf(r)).toMatchObject({ currency: "USD", amount_original: 2000, fx_rate: 35, fx_rate_date: "2025-03-03", cost_thb: 70_000 });
    // ใบสมุดของทรัพย์นี้ลงเป็นบาท (ฝั่งเดบิต/เครดิตเป็นบาทเสมอ) ไม่มีชุดสกุลเงินบนบรรทัด 1700
    const e = owner(r, "o-thanakorn").payload.entries.find((x) => x.asset_id === ASSET_IDS.ptt)!;
    expect(e.transactions[0].lines.find((l) => l.coa_code === "1700")).toMatchObject({ debit: 70_000 });
  });

  it("ไม่ส่งตารางอัตรามาเลย → ปฏิเสธ (ไม่เดาว่าอัตราที่กรอกถูก)", () => {
    expect(bad(parse(usdWorkbook()), env({ assets: usdAssets(), fxRates: [] })).some((p) => /ไม่มีอัตรา USD = 35/.test(p.message))).toBe(true);
  });

  it("อัตราที่กรอกไม่ตรงอัตราที่ประกาศของวันซื้อ → ปฏิเสธ บอกอัตราที่ประกาศ", () => {
    const problems = bad(parse(usdWorkbook()), env({ assets: usdAssets(), fxRates: [rate("2025-03-03", 34.5)] }));
    expect(problems.some((p) => /ไม่ตรงกับตารางอัตรา.*ประกาศไว้ 34.5/.test(p.message))).toBe(true);
  });

  it("วันซื้อไม่มีแถวอัตรา: ใช้วันทำการก่อนหน้าไม่เกิน 10 วัน เฉพาะเมื่ออัตราเท่ากัน · เก่ากว่านั้น/ของวันหลัง/อัตราต่าง = ปฏิเสธ", () => {
    const e = (fxRates: ReturnType<typeof rate>[]) => env({ assets: usdAssets(), fxRates });
    expect(lotOf(ok(parse(usdWorkbook()), e([rate("2025-02-28", 35)]))).fx_rate_date).toBe("2025-02-28");
    expect(bad(parse(usdWorkbook()), e([rate("2025-02-20", 35)])).length).toBe(1); // 11 วันก่อน
    expect(bad(parse(usdWorkbook()), e([rate("2025-03-04", 35)])).length).toBe(1); // ของวันหลังวันซื้อ
    expect(bad(parse(usdWorkbook()), e([rate("2025-02-28", 36)])).length).toBe(1); // อัตราต่างจากที่กรอก
  });
});

describe("นิติบุคคล (corporate_strict): บังคับเอกสารด้วย buildPosting ตัวจริงตอนบันทึก", () => {
  const SRI = "5a1c0000-0000-4000-8000-000000000001";
  const UID = "11111111-1111-4111-8111-111111111111";
  // รหัสผู้ถือเป็น uuid จริง เพราะหลักฐานนับได้เฉพาะไฟล์ที่ path ขึ้นต้นด้วยรหัสของผู้ถือรายนั้น
  const withUuidSri = () => {
    const ctx = ctxOf();
    ctx.owners = ctx.owners.map((o) => (o.id === "o-sri" ? { ...o, id: SRI } : o));
    ctx.banks = ctx.banks.map((b) => (b.ownerId === "o-sri" ? { ...b, ownerId: SRI } : b));
    const ref = refOf();
    ref.owners = ref.owners.map((o) => (o.id === "o-sri" ? { ...o, id: SRI, code: SRI } : o));
    ref.banks = ref.banks.map((b) => (b.ownerId === "o-sri" ? { ...b, ownerId: SRI } : b));
    const r = parseOpeningWorkbook(postableWorkbook(), ctx);
    if (!r.ok) throw new Error(r.issues.map((i) => i.message).join("\n"));
    return { parsed: r.parsed, ref };
  };
  const file = (owner: string) => `${owner}/${UID}/22222222-2222-4222-8222-222222222222.pdf`;
  const run = (mode: "preview" | "post", evidence?: PrepareEnv["evidence"]) => {
    const { parsed, ref } = withUuidSri();
    // ทรัพย์รายชิ้นของ SRI ที่ลงทะเบียนไว้ต้องตามไปอยู่ภายใต้รหัสผู้ถือ (uuid) ใหม่ด้วย
    const assets = assetsOf().map((a) => (a.ownerId === "o-sri" ? { ...a, ownerId: SRI } : a));
    return prepareOpeningPosting(parsed, env({ ref, mode, evidence, assets }));
  };

  it("พรีวิว: ยังไม่บังคับเอกสาร แต่บอกว่าผู้ถือรายนี้ต้องแนบหลักฐาน", () => {
    const r = run("preview");
    expect(r.ok).toBe(true);
    expect(r.evidenceOwners).toEqual([{ id: SRI, name: "SRI Corporation" }]);
  });

  it("บันทึกจริงโดยไม่ส่งหลักฐาน/ผู้ติดต่อ → ปฏิเสธ ข้อความเดียว (ไม่ซ้ำทุกหมวด) · ผู้ถือบุคคลไม่ถูกบังคับ", () => {
    const r = run("post");
    expect(r.ok).toBe(false);
    if (r.ok) return;
    const sri = r.problems.filter((p) => p.ownerName === "SRI Corporation");
    expect(sri).toHaveLength(1);
    expect(sri[0].message).toMatch(/นิติบุคคล ต้องแนบหลักฐาน/);
    expect(sri[0].message).toMatch(/หมวด opn\./);
    expect(r.problems.filter((p) => p.ownerName !== "SRI Corporation")).toEqual([]);
  });

  it("ส่งหลักฐานแต่ไม่ส่งผู้ติดต่อ → ปฏิเสธ (นิติบุคคลต้องระบุคู่ค้าทุกรายการ)", () => {
    const r = run("post", { [SRI]: { attachments: [file(SRI)] } });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.problems.some((p) => p.ownerName === "SRI Corporation" && /ต้องระบุคู่ค้า/.test(p.message))).toBe(true);
  });

  it("ส่งผู้ติดต่อแต่ไฟล์เป็นของผู้ถืออื่น หรือเป็นชื่อไฟล์ที่พิมพ์เอง → ปฏิเสธ", () => {
    for (const attachments of [[file("99999999-9999-4999-8999-999999999999")], ["งบทดลอง.pdf"], []]) {
      const r = run("post", { [SRI]: { attachments, contactId: "c-auditor" } });
      expect(r.ok).toBe(false);
      if (!r.ok) expect(r.problems.some((p) => /ต้องแนบหลักฐาน/.test(p.message))).toBe(true);
    }
  });

  it("ส่งครบ → ผ่าน · ทุกใบของนิติบุคคลมี attachments + contact_id · ผู้ถือบุคคลไม่ติดหลักฐาน", () => {
    const r = run("post", { [SRI]: { attachments: [file(SRI)], contactId: "c-auditor" } });
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const sri = owner(r, SRI);
    expect(sri.payload.entries.length).toBeGreaterThan(0);
    for (const e of sri.payload.entries) {
      expect(e.attachments).toEqual([file(SRI)]);
      expect(e.contact_id).toBe("c-auditor");
    }
    for (const e of owner(r, "o-thanakorn").payload.entries) {
      expect(e.attachments).toBeUndefined();
      expect(e.contact_id).toBeUndefined();
    }
  });

  it("ส่งหลักฐานของผู้ถือที่ไม่ใช่นิติบุคคลมา → ไม่ถูกแนบ (ผูกตามนโยบายของผู้ถือ ไม่ใช่ตามที่ผู้เรียกส่ง)", () => {
    const r = run("post", { [SRI]: { attachments: [file(SRI)], contactId: "c-auditor" }, "o-thanakorn": { attachments: [file("o-thanakorn")], contactId: "c-auditor" } });
    expect(r.ok).toBe(true);
    if (r.ok) expect(owner(r, "o-thanakorn").payload.entries.every((e) => e.attachments === undefined && e.contact_id === undefined)).toBe(true);
  });
});

/* ---------------------------------------------------------------- ทรัพย์รายชิ้นจากชีทแจกแจง */

describe("ทรัพย์รายชิ้น (แจกแจงทรัพย์): หนึ่งบรรทัดต่อหนึ่งชิ้น พร้อม asset_id", () => {
  const TK = "o-thanakorn";
  const lines = (r: ReturnType<typeof ok>, ownerId: string) => owner(r, ownerId).payload.entries.flatMap((e) => e.transactions.flatMap((t) => t.lines.map((l) => ({ ...l, entry: e }))));

  it("ทุกบรรทัดของบัญชีที่ต้องแจกแจง (1400/1500/1510) ผูก asset_id · ไม่มีบรรทัดรวมที่ไม่ผูกทรัพย์เหลืออยู่", () => {
    const r = ok(parse());
    for (const id of ["o-sri", TK]) {
      const rows = lines(r, id).filter((l) => ["1400", "1500", "1510"].includes(l.coa_code));
      expect(rows.length).toBeGreaterThan(0);
      expect(rows.every((l) => !!l.asset_id)).toBe(true);
      expect(rows.every((l) => l.entry.asset_id === l.asset_id)).toBe(true); // หัวรายการผูกทรัพย์เดียวกับบรรทัด
    }
    // ธนากร: คอนโดชิ้นเดียว 3,000,000 ผูกทรัพย์ที่ลงทะเบียนไว้
    const condo = lines(r, TK).filter((l) => l.coa_code === "1500");
    expect(condo).toHaveLength(1);
    expect(condo[0]).toMatchObject({ asset_id: ITEM_ASSET_IDS.tkRental, debit: 3_000_000 });
    // ขา 3300 ที่ engine เติมไม่ผูกทรัพย์ (ต้นทุนทรัพย์นับจากบรรทัดสินทรัพย์เท่านั้น)
    expect(lines(r, TK).filter((l) => l.coa_code === "3300").every((l) => !l.asset_id)).toBe(true);
  });

  it("คอนโดสองห้อง 3,000,000 + 5,000,000 (+รีโนเวท 500,000) → สองทรัพย์ สองใบ 1500 · ค่ารีโนเวทลง 1510 ผูกห้องที่สอง", () => {
    const wb = postableWorkbook();
    // ธนากร: 1500 = 8,000,000 · 1510 = 500,000 (ดุลด้วยกำไรสะสม 3300)
    setByCode(wb, "BS-ธนากร", "1500", 8_000_000);
    setByCode(wb, "BS-ธนากร", "1510", 500_000);
    setByCode(wb, "BS-ธนากร", "3300", 1_820_000 + 5_000_000 + 500_000);
    setBreakdown(wb, [
      ...breakdownRowsFromBs(wb).filter((x) => x.owner !== "ธนากร"),
      { owner: "ธนากร", name: "คอนโด ห้อง 1203", line: "1500", cost: 3_000_000 },
      { owner: "ธนากร", name: "คอนโด ห้อง 1507", line: "1500", cost: 5_000_000, reno: 500_000 },
    ]);
    const assets: OpeningAsset[] = [
      ...assetsOf().filter((a) => a.id !== ITEM_ASSET_IDS.tkRental),
      { id: "a-1203", code: "RE-1203", name: "คอนโด ห้อง 1203", ownerId: TK, status: "active", currency: "THB", categoryCode: "RE_RENTAL" },
      { id: "a-1507", code: "RE-1507", name: "คอนโด ห้อง 1507", ownerId: TK, status: "active", currency: "THB", categoryCode: "RE_RENTAL" },
    ];
    const r = ok(parse(wb), env({ assets }));
    const rows = lines(r, TK);
    const net = (asset: string, coaCode: string) => rows.filter((l) => l.asset_id === asset && l.coa_code === coaCode).reduce((t, l) => t + l.debit - l.credit, 0);
    expect(net("a-1203", "1500")).toBe(3_000_000);
    expect(net("a-1507", "1500")).toBe(5_000_000);
    expect(net("a-1507", "1510")).toBe(500_000); // รีโนเวทผูกทรัพย์ชิ้นเดิม ไม่ผูกห้องอื่น
    expect(net("a-1203", "1510")).toBe(0);
    // บัญชี 1510 เป็นบัญชีร่วมของผู้ถือ แต่ทุกบาทมีเจ้าของเป็นรายชิ้น
    expect(rows.filter((l) => l.coa_code === "1510").every((l) => !!l.asset_id)).toBe(true);
    expect(rows.filter((l) => l.coa_code === "1500" || l.coa_code === "1510").reduce((t, l) => t + l.debit - l.credit, 0)).toBe(8_500_000);
    // ยอดต่อทรัพย์ในสมุด (นับแบบเดียวกับ fn_asset_cost_basis: บรรทัดสินทรัพย์ที่ผูก asset_id) แยกกัน ไม่เฉลี่ย
    expect(r.itemAssets.size).toBe(parse(wb).assetItems.length);
  });

  it("ค่ารีโนเวทของบรรทัดที่เลือก 1510 เอง รวมกับต้นทุนเป็นบรรทัดเดียวของชิ้นนั้น (ไม่ลง 1510 ซ้ำสองใบ)", () => {
    const wb = postableWorkbook();
    setByCode(wb, "BS-ธนากร", "1510", 150_000);
    setByCode(wb, "BS-ธนากร", "3300", 1_820_000 + 150_000);
    setBreakdown(wb, [...breakdownRowsFromBs(wb).filter((x) => !(x.owner === "ธนากร" && x.line === "1510")), { owner: "ธนากร", name: "ห้องรีโนเวทเก่า", line: "1510", cost: 100_000, reno: 50_000 }]);
    const assets = [...assetsOf(), { id: "a-old", code: "RE-OLD", name: "ห้องรีโนเวทเก่า", ownerId: TK, status: "active", currency: "THB", categoryCode: "RE_RENTAL" }];
    const r = ok(parse(wb), env({ assets }));
    const reno = lines(r, TK).filter((l) => l.coa_code === "1510");
    expect(reno).toHaveLength(1);
    expect(reno[0]).toMatchObject({ asset_id: "a-old", debit: 150_000 });
  });

  it("ทรัพย์ยังไม่อยู่ในทะเบียน + ไม่ได้สั่งสร้าง → ปฏิเสธ ไม่ลงเป็นยอดรวมแทน (บอกว่าชิ้นไหน แถวไหน)", () => {
    const problems = bad(parse(), env({ assets: assetsOf().filter((a) => a.id !== ITEM_ASSET_IDS.tkRental) }));
    const p = problems.find((x) => x.ownerName === "ธนากร" && /ยังไม่มีทรัพย์ชิ้นนี้ในทะเบียน/.test(x.message))!;
    expect(p).toBeDefined();
    expect(p.message).toMatch(/แถว \d+ ของชีทแจกแจงทรัพย์/);
    expect(p.message).toMatch(/ไม่ลงเป็นยอดรวมแทน/);
  });

  it("ทรัพย์ยังไม่อยู่ในทะเบียน + createMissing → ผ่านการตรวจเต็มด้วยทรัพย์ชั่วคราว · รายงานว่าต้องสร้างอะไร หมวดอะไร · รหัสชั่วคราวชัดเจน", () => {
    const r = ok(parse(), env({ createMissing: true, assets: assetsOf().filter((a) => !Object.values(ITEM_ASSET_IDS).includes(a.id)) }));
    expect(r.toCreate.map((t) => [t.item.ownerName, t.item.coaCode, t.categoryCode]).sort()).toEqual(
      [
        ["SRI Corporation", "1400", "RE_SRR"],
        ["SRI Corporation", "1500", "RE_RENTAL"],
        ["ธนากร", "1500", "RE_RENTAL"],
      ].sort()
    );
    const pendings = [...r.itemAssets.values()].filter((a) => isPendingAssetId(a.id));
    expect(pendings).toHaveLength(3);
    expect(new Set(pendings.map((a) => a.id)).size).toBe(3);
  });

  it("ทรัพย์ในทะเบียนอยู่ผิดหมวด (คอนโดที่เป็นหมวดเงินให้กู้) → ปฏิเสธ ไม่ลงต้นทุนเข้าทรัพย์ผิดหมวด", () => {
    const assets = assetsOf().map((a) => (a.id === ITEM_ASSET_IDS.tkRental ? { ...a, categoryCode: "PAPER_LOAN" } : a));
    const p = bad(parse(), env({ assets })).find((x) => /ผิดหมวด|ต้องเป็นหมวด/.test(x.message))!;
    expect(p.message).toMatch(/PAPER_LOAN/);
    expect(p.message).toMatch(/RE_RENTAL/);
  });

  it("ไม่ทราบหมวดของทรัพย์ที่มีอยู่ (อ่านหมวดไม่ได้) → ปฏิเสธ ไม่เดาว่าตรง", () => {
    const assets = assetsOf().map((a) => (a.id === ITEM_ASSET_IDS.tkRental ? { ...a, categoryCode: undefined } : a));
    expect(bad(parse(), env({ assets })).some((x) => /ไม่ทราบ/.test(x.message))).toBe(true);
  });

  it.each([
    ["ทรัพย์ที่จำหน่ายแล้ว", { status: "sold" }, /สถานะ "sold"/],
    ["ทรัพย์สกุลต่างประเทศ", { currency: "USD" }, /สกุล USD/],
  ])("%s → ปฏิเสธ", (_n, patch, re) => {
    const assets = assetsOf().map((a) => (a.id === ITEM_ASSET_IDS.tkRental ? { ...a, ...patch } : a));
    expect(bad(parse(), env({ assets })).some((x) => re.test(x.message))).toBe(true);
  });

  it("ชื่อทรัพย์ตรงกับในทะเบียนสองรายการ → ปฏิเสธ ไม่เลือกให้ (เลือกผิดแปลว่าต้นทุนไปอยู่ผิดชิ้น)", () => {
    const dup: OpeningAsset = { ...itemAssetsOf().find((a) => a.id === ITEM_ASSET_IDS.tkRental)!, id: "a-dup", code: "RE-DUP" };
    expect(bad(parse(), env({ assets: [...assetsOf(), dup] })).some((x) => /ตรงกัน \(.*RE-0003.*RE-DUP|RE-DUP.*RE-0003/.test(x.message))).toBe(true);
  });

  it("สองแถวของชีทแจกแจงชี้ทรัพย์ในทะเบียนชิ้นเดียวกัน (ด้วยรหัสทรัพย์) → ปฏิเสธ ต้นทุนจะซ้อนกัน", () => {
    const wb = postableWorkbook();
    setByCode(wb, "BS-ธนากร", "1500", 6_000_000);
    setByCode(wb, "BS-ธนากร", "3300", 1_820_000 + 3_000_000);
    setBreakdown(wb, [
      ...breakdownRowsFromBs(wb).filter((x) => !(x.owner === "ธนากร" && x.line === "1500")),
      { owner: "ธนากร", code: "RE-0003", name: "ห้อง ก", line: "1500", cost: 3_000_000 },
      { owner: "ธนากร", code: "RE-0003", name: "ห้อง ข", line: "1500", cost: 3_000_000 },
    ]);
    // ตัวอ่านกันรหัสซ้ำตั้งแต่แรก → ไม่ถึงขั้นประกอบรายการ
    const r = parseOpeningWorkbook(wb, ctxOf());
    expect(r.ok).toBe(false);
    // ถ้าเป็นคนละรหัสที่จับคู่ทรัพย์เดียวกัน (รหัสหนึ่ง ชื่ออีกอัน) → ด่านฝั่งประกอบรายการจับ
    setBreakdown(wb, [
      ...breakdownRowsFromBs(wb).filter((x) => !(x.owner === "ธนากร" && x.line === "1500")),
      { owner: "ธนากร", code: "RE-0003", name: "ห้อง ก", line: "1500", cost: 3_000_000 },
      { owner: "ธนากร", name: itemName("1500", "ธนากร"), line: "1500", cost: 3_000_000 },
    ]);
    const p = bad(parse(wb));
    expect(p.some((x) => /ถูกอ้างโดยสองแถว/.test(x.message))).toBe(true);
  });

  it("1600 เงินมัดจำจ่าย (ไม่มีหมวดทรัพย์) → ลงบรรทัดรวมต่อบัญชี ไม่มี asset_id · ไม่ขอสร้างทรัพย์ · ชื่อรายการต่อใน memo", () => {
    const wb = postableWorkbook();
    setByCode(wb, "BS-ธนากร", "1600", 50_000);
    setByCode(wb, "BS-ธนากร", "3300", 1_820_000 + 50_000);
    setBreakdown(wb, [
      ...breakdownRowsFromBs(wb).filter((x) => !(x.owner === "ธนากร" && x.line === "1600")),
      { owner: "ธนากร", name: "ค่ามัดจำสำนักงาน", line: "1600", cost: 30_000 },
      { owner: "ธนากร", name: "ค่ามัดจำไฟฟ้า", line: "1600", cost: 20_000 },
    ]);
    const r = ok(parse(wb), env({ createMissing: true }));
    expect(r.toCreate).toEqual([]);
    const entries = owner(r, TK).payload.entries.filter((e) => e.transactions.some((t) => t.lines.some((l) => l.coa_code === "1600")));
    expect(entries).toHaveLength(1);
    const l1600 = entries[0].transactions.flatMap((t) => t.lines).filter((l) => l.coa_code === "1600");
    expect(l1600).toHaveLength(1);
    expect(l1600[0]).toMatchObject({ debit: 50_000 });
    expect(l1600[0].asset_id).toBeUndefined();
    expect(entries[0].asset_id).toBeUndefined();
    expect(entries[0].memo).toContain("ค่ามัดจำสำนักงาน 30,000");
    expect(entries[0].memo).toContain("ค่ามัดจำไฟฟ้า 20,000");
  });

  it("1600 หลายรายการจน memo ยาวเกิน → ตัดแล้วบอกจำนวนที่เหลือ · ยอดรวมยังครบ", () => {
    const wb = postableWorkbook();
    setByCode(wb, "BS-ธนากร", "1600", 1_000);
    setByCode(wb, "BS-ธนากร", "3300", 1_820_000 + 1_000);
    const rows = Array.from({ length: 100 }, (_, k) => ({ owner: "ธนากร", name: `เงินมัดจำรายการที่ ${k + 1} ของสัญญาเช่า`, line: "1600", cost: 10 }));
    setBreakdown(wb, [...breakdownRowsFromBs(wb).filter((x) => !(x.owner === "ธนากร" && x.line === "1600")), ...rows]);
    const r = ok(parse(wb), env());
    const e = owner(r, TK).payload.entries.find((x) => x.transactions.some((t) => t.lines.some((l) => l.coa_code === "1600")))!;
    expect(e.memo!.length).toBeLessThan(560);
    expect(e.memo).toMatch(/และอีก \d+ รายการ/);
    expect(e.transactions.flatMap((t) => t.lines).find((l) => l.coa_code === "1600")!.debit).toBe(1_000);
  });

  it("ผู้ถือไม่มียอดงบดุลเลยแต่ชีทแจกแจงมีทรัพย์ของเขา → ปฏิเสธ (ยอดจะหายเงียบๆ) แม้ผ่านตัวอ่านมาแล้ว", () => {
    const parsed = parse();
    parsed.assetItems.push({ ownerId: "o-benjaporn", ownerName: "เบ็ญจพร", assetCode: null, name: "ห้องลอย", coaCode: "1500", cost: 1_000_000, renovation: 0, note: "", row: 99 });
    expect(bad(parsed, env({ createMissing: true })).some((x) => x.ownerName === "เบ็ญจพร" && /ไม่มียอดในงบดุล/.test(x.message))).toBe(true);
  });

  it("ยอดที่ผูกทรัพย์ในรายการที่ประกอบได้ ต้องเท่าชีทแจกแจงทุกชิ้น (ด่านท้ายสุดกันบรรทัดหลุด asset_id)", () => {
    const r = ok(parse());
    for (const [item, asset] of r.itemAssets) {
      const net = lines(r, item.ownerId)
        .filter((l) => l.asset_id === asset.id && ["1400", "1500", "1510"].includes(l.coa_code))
        .reduce((t, l) => t + l.debit - l.credit, 0);
      expect(net).toBe(item.cost + item.renovation);
    }
  });
});

describe("runOpeningImport · ไม่ส่งทรัพย์ชั่วคราวเข้า DB", () => {
  it("payload ที่ยังมีรหัสทรัพย์ pending-asset: → ไม่เรียกประตูกับใครเลย · ผู้ถือที่มีปัญหา failed ที่เหลือ skipped", async () => {
    const r = ok(parse(), { ...env({ createMissing: true }), assets: assetsOf().filter((a) => a.id !== ITEM_ASSET_IDS.tkRental) });
    let called = 0;
    const store = { reimport: async () => ((called += 1), { data: { changed: true }, error: null }) } as unknown as Parameters<typeof runOpeningImport>[1];
    const run = await runOpeningImport(r.owners, store);
    expect(called).toBe(0);
    expect(run.allOk).toBe(false);
    expect(run.results.filter((x) => x.status === "failed").map((x) => x.ownerName)).toEqual(["ธนากร"]);
    expect(run.results.filter((x) => x.status === "skipped").length).toBe(run.results.length - 1);
  });
});
