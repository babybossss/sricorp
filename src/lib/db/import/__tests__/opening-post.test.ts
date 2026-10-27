import { describe, expect, it } from "vitest";
import { parseOpeningWorkbook, type ParsedOpening } from "../opening";
import { openingSubByAccount, prepareOpeningPosting, type OpeningAsset, type PrepareEnv } from "../opening-post";
import { CUTOFF, ctxOf, loadFixture, setCell } from "./helpers";
import { ASSET_IDS, assetsOf, noRates, postableWorkbook, refOf, setByCode } from "./post-helpers";
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
  it("ตรงกับตารางกฎ 28 รหัส (ทุกบัญชีงบดุลยกเว้นส่วนของเจ้าของ 3200/3300/3400/3410 และ 1520) — ไม่มีรหัสเพิ่มหรือขาด", () => {
    const expected: Record<string, string> = {
      "1100": "opn.cash", "1200": "opn.receivable_rent", "1210": "opn.receivable_interest", "1220": "opn.receivable_other",
      "1290": "opn.allowance", "1300": "opn.loan_principal", "1310": "opn.intercompany_receivable",
      // เงินให้กู้ยืมมีหลักประกัน (ลูกพี่สั่ง 27/10) — แยกจาก 1300
      "1320": "opn.loan_secured_principal",
      "1400": "opn.srr_principal", "1410": "opn.mortgage_principal", "1500": "opn.property", "1510": "opn.renovation",
      /**
       * **1520 อสังหาฯ เพื่อการขาย ไม่มีหมวดยอดยกมาโดยตั้งใจ** (27/10)
       *
       * ทรัพย์ทุกชิ้นนำเข้าที่ `opn.property` (1500) แล้วย้ายวัตถุประสงค์หนึ่งใบ
       * ด้วย `adj.reclass_re_to_sale` ซึ่งย้ายด้วยต้นทุนเดิมและไม่กระทบงบใดเลย
       * เปิดสองทางเข้าให้ทรัพย์ชิ้นเดียวกันแปลว่าคนนำเข้าเลือกได้ว่าจะลงบัญชีไหน
       * แล้วยอดตั้งต้นของสองบัญชีจะขึ้นกับคนกรอก ไม่ใช่ขึ้นกับความจริง
       */
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
    expect(problems[0].message).toMatch(/ต้องสร้างทรัพย์ก่อน/);
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
    return prepareOpeningPosting(parsed, env({ ref, mode, evidence }));
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
