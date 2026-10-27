/**
 * ชีท "แจกแจงทรัพย์" ลงสมุด **กับ Postgres จริงในเครื่อง** — ทั้งเส้นทาง: ตัวอ่านไฟล์ → กระทบยอดกับ BS-* → ลงทะเบียนทรัพย์
 * (ร่าง + `fn_apply_asset_draft` ภายใต้ RLS ของผู้ใช้จริง) → `buildPosting()` → `fn_reimport_opening` → ขายทรัพย์ชิ้นหนึ่งออก
 *
 * ปัญหาที่เทสต์นี้ปิด: เดิมยอดอสังหาฯ ลงเป็นบรรทัดรวมต่อรหัสบัญชี ไม่ผูก asset_id → ทรัพย์ไม่มีต้นทุนรายชิ้น → ขายไม่ออกตลอดไป
 * ที่นี่พิสูจน์ด้วยตัวเลขจากสมุดที่ DB บันทึกจริง: คอนโดสองห้อง 3,000,000 / 5,000,000 (+รีโนเวท 500,000) ได้ต้นทุนคนละชิ้น
 * แล้วขายห้องแรก 3,500,000 → กำไร +500,000 (ถ้าเฉลี่ยข้ามห้องจะได้ −500,000)
 *
 * ไม่มี Postgres ในเครื่อง → ข้ามพร้อมเหตุผล (SRI_REQUIRE_PG=1 ให้พังแทน) · DB ทดสอบถูกลบทิ้งเมื่อจบ
 */
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { createTestDb, pgAvailable, type TestDb } from "./pg-harness";
import { pgClient } from "./pg-client";
import { loadFixture, setBreakdown, sheetOf, type BreakdownRow } from "./helpers";
import type { Workbook } from "../xlsx";

const h = vi.hoisted(() => ({
  client: null as unknown,
  perms: new Set<string>(),
  wb: null as Workbook | null,
  /** ถ้าไม่ว่าง ตัวอ่านคืนตามลำดับ (ไฟล์แรก = ไฟล์ยอดตั้งต้น · ไฟล์ที่สอง = ไฟล์แจกแจงที่แนบแยก) */
  queue: [] as Workbook[],
  armed: false,
  uid: "",
}));
vi.mock("next/cache", () => ({ revalidatePath: vi.fn() }));
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => h.client }));
vi.mock("@/lib/auth/session", () => ({
  getAccess: async () => ({ user: { id: h.uid, email: "bd@local" }, permissions: h.perms, profile: null, error: null }),
}));
vi.mock("@/lib/db/import/xlsx", async (orig) => {
  const real = await orig<typeof import("@/lib/db/import/xlsx")>();
  return { ...real, readWorkbook: (b: Uint8Array) => (h.queue.length ? h.queue.shift()! : h.armed && h.wb ? h.wb : real.readWorkbook(b)) };
});

import { confirmOpeningImport, previewOpeningImport } from "@/app/actions/import-opening";
import { postEntry, type PostEntryRequest } from "@/app/actions/post-entry";
import { findSub } from "@/lib/rules/tx-rules";

const UID = "0000000b-0000-4000-8000-0000000000b1";
const TK = "BS-ธนากร";

/** ล้างยอดที่กรอกทุกช่องของชีทผู้ถือ (ช่องสูตรของเทมเพลตไม่แตะ — ตัวอ่านไม่เชื่อสูตรอยู่แล้ว) */
function clearAmounts(wb: Workbook, sheetName: string) {
  for (const cells of sheetOf(wb, sheetName).rows.values()) {
    const e = cells.get("E");
    if (e && typeof e.value === "number" && !e.formula) e.value = null;
  }
}
const setE = (wb: Workbook, sheetName: string, code: string, amount: number) => {
  for (const cells of sheetOf(wb, sheetName).rows.values()) {
    if (String(cells.get("A")?.value ?? "") === code) {
      cells.set("E", { value: amount, formula: false });
      return;
    }
  }
  throw new Error(`ไม่พบรหัส ${code} ในชีท ${sheetName}`);
};

/** ไฟล์ที่ธนากรมีคอนโดสองห้อง (ห้อง B มีรีโนเวท 500,000) · ผู้ถือคนอื่นไม่มียอด · มีชีทแจกแจงเมื่อ `rows` ไม่เป็น null */
function condoWorkbook(rows: BreakdownRow[] | null, over: { c1500?: number } = {}): Workbook {
  const wb = loadFixture();
  for (const s of wb.sheets.filter((x) => x.name.startsWith("BS-"))) clearAmounts(wb, s.name);
  for (const r of [6, 7, 8]) for (const c of "ABCDEFGIJ") sheetOf(wb, "พอร์ตลงทุน (รายล็อต)").rows.get(r)?.set(c, { value: null, formula: false });
  setE(wb, TK, "1500", over.c1500 ?? 8_000_000);
  setE(wb, TK, "1510", 500_000);
  setE(wb, TK, "3100", (over.c1500 ?? 8_000_000) + 500_000);
  wb.sheets = wb.sheets.filter((s) => s.name !== "แจกแจงทรัพย์");
  if (rows) setBreakdown(wb, rows);
  return wb;
}
const CONDOS: BreakdownRow[] = [
  { owner: "ธนากร", name: "คอนโด ลุมพินี ห้อง 1203", line: "1500", cost: 3_000_000 },
  { owner: "ธนากร", name: "คอนโด ลุมพินี ห้อง 1507", line: "1500", cost: 5_000_000, reno: 500_000 },
];

describe.skipIf(!pgAvailable)("แจกแจงทรัพย์ → ลงสมุดเป็นรายชิ้นกับ Postgres จริง", { timeout: 120_000 }, () => {
  let db: TestDb;
  let bankId = "";
  const owner = () => db.su(`select id from sri_os.owners where code='THANAKORN'`);

  const counts = () => ({
    txns: db.num("select count(*) from sri_os.transactions"),
    lines: db.num("select count(*) from sri_os.transaction_lines"),
    assets: db.num("select count(*) from sri_os.assets"),
    drafts: db.num("select count(*) from sri_os.asset_drafts"),
  });
  const assetId = (name: string) => db.su(`select id from sri_os.assets where name = '${name}'`);
  /** ต้นทุนของทรัพย์ชิ้นหนึ่งตามสมุด (fn_asset_cost_basis = ผลรวมบรรทัดสินทรัพย์ที่ผูก asset_id นั้น) */
  const cost = (name: string) => db.num(`select sri_os.fn_asset_cost_basis('${assetId(name)}')`);
  const net = (coa: string, name?: string) =>
    db.num(
      `select coalesce(sum(v.debit - v.credit), 0) from sri_os.v_ledger_posted v join sri_os.chart_of_accounts c on c.id = v.coa_id
        where c.code = '${coa}' and v.owner_id = '${owner()}' ${name ? `and v.line_asset_id = '${assetId(name)}'` : ""}`
    );
  const pl = () =>
    db.num(
      `select coalesce(sum(v.credit - v.debit), 0) from sri_os.v_ledger_posted v join sri_os.chart_of_accounts c on c.id = v.coa_id
        where c.type::text in ('income', 'expense') and v.owner_id = '${owner()}'`
    );

  const run = async <T,>(wb: Workbook, fn: (fd: FormData) => Promise<T>, extra: Record<string, string> = {}): Promise<T> => {
    h.wb = wb;
    h.armed = true;
    try {
      const fd = new FormData();
      fd.set("file", new File([new Uint8Array([0x50, 0x4b, 3, 4]) as BlobPart], "opening.xlsx"));
      fd.set("cutoff", "");
      for (const [k, v] of Object.entries(extra)) fd.set(k, v);
      return await fn(fd);
    } finally {
      h.armed = false;
    }
  };
  const preview = (wb: Workbook) => run(wb, previewOpeningImport);
  const confirm = async (wb: Workbook) => {
    const p = await preview(wb);
    if (!p.ok) throw new Error("ตัวอย่างถูกปฏิเสธ: " + p.message + JSON.stringify(p.issues));
    return run(wb, confirmOpeningImport, { fingerprint: p.fingerprint });
  };

  beforeAll(() => {
    db = createTestDb();
    h.uid = UID;
    h.perms = new Set(["settings.manage", "ledger.approve", "asset.manage", "portfolio.view_all", "txn.create"]);
    h.client = pgClient(db, UID);
    db.su(`
      insert into auth.users(id) values ('${UID}');
      insert into sri_os.app_users(id, email, display_name, role, is_active) values ('${UID}', 'bd@local', 'mgmt', 'management', true);
      insert into sri_os.user_owner_access(user_id, owner_id) select '${UID}', id from sri_os.owners;
      insert into sri_os.bank_accounts(owner_id, bank, account_name, display_name)
        select id, 'BBL', 'ธนากร', 'ธนากร - BBL 888' from sri_os.owners where code = 'THANAKORN';
    `);
    bankId = db.su(`select id from sri_os.bank_accounts where display_name = 'ธนากร - BBL 888'`);
  }, 240_000);

  afterAll(() => db?.drop());

  it("B0 · ไม่มีชีท 'แจกแจงทรัพย์' เลย → ปฏิเสธทั้งไฟล์ ไม่ลงเป็นยอดรวม · ไม่มีทรัพย์ ไม่มีรายการ", async () => {
    const before = counts();
    const r = await preview(condoWorkbook(null));
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.issues.some((i) => /ไม่พบชีท "แจกแจงทรัพย์"/.test(i.message))).toBe(true);
    expect(counts()).toEqual(before);
  });

  it("B1 · ยอดไม่กระทบ (BS 1500 = 8,000,001 แต่ทรัพย์รวม 8,000,000) → ปฏิเสธ บอกช่องและผลต่าง · ไม่เขียนอะไร", async () => {
    const before = counts();
    const r = await preview(condoWorkbook(CONDOS, { c1500: 8_000_001 }));
    expect(r.ok).toBe(false);
    if (!r.ok) {
      const issue = r.issues.find((i) => i.sheet === TK && /1500/.test(i.message));
      expect(issue?.message).toMatch(/8,000,001/);
      expect(issue?.message).toMatch(/8,000,000/);
      expect(issue?.message).toMatch(/ต่างกัน 1/);
    }
    expect(counts()).toEqual(before);
  });

  it("B2 · ตัวอย่าง: ทรัพย์ 2 ชิ้นจะลงทะเบียนใหม่ · ยังไม่เขียนอะไรลง DB", async () => {
    const before = counts();
    const p = await preview(condoWorkbook(CONDOS));
    expect(p.ok, JSON.stringify(p)).toBe(true);
    if (!p.ok) return;
    expect(p.blockers).toEqual([]);
    expect(p.assets).toHaveLength(2);
    expect(p.assets.every((a) => a.existing === null)).toBe(true);
    expect(counts()).toEqual(before);
  });

  it("B3 · ยืนยัน: ลงทะเบียนทรัพย์ 2 ชิ้น (หมวดปล่อยเช่า) · ต้นทุนรายชิ้น 3,000,000 / 5,500,000 · ทุกบรรทัดผูก asset_id", async () => {
    const c = await confirm(condoWorkbook(CONDOS));
    expect(c.ok, JSON.stringify(c)).toBe(true);
    expect(db.num("select count(*) from sri_os.assets")).toBe(2);
    expect(db.rows<{ code: string }>("select ct.code from sri_os.assets a join sri_os.asset_categories ct on ct.id = a.category_id").map((r) => r.code)).toEqual(["RE_RENTAL", "RE_RENTAL"]);

    expect(cost("คอนโด ลุมพินี ห้อง 1203")).toBe(3_000_000);
    expect(cost("คอนโด ลุมพินี ห้อง 1507")).toBe(5_500_000); // 5,000,000 + รีโนเวท 500,000 (บัญชี 1510 ผูกห้องเดิม)
    // ยอดรวมต่อรหัสบัญชีตรงงบดุล และไม่มีบรรทัด 1500/1510 ที่ไม่ผูกทรัพย์ (นี่คือบั๊กที่แก้)
    expect(net("1500")).toBe(8_000_000);
    expect(net("1510")).toBe(500_000);
    expect(net("1510", "คอนโด ลุมพินี ห้อง 1507")).toBe(500_000);
    expect(
      db.num(
        `select count(*) from sri_os.transaction_lines l join sri_os.chart_of_accounts c on c.id = l.coa_id
          where c.code in ('1500', '1510') and l.asset_id is null`
      )
    ).toBe(0);
    // ทรัพย์ชิ้นเดียว แบ่งไม่ได้ (ห้ามเฉลี่ย)
    expect(db.su(`select sri_os.fn_asset_cost_basis_mode('${assetId("คอนโด ลุมพินี ห้อง 1203")}')`)).toBe("whole_item");
    // ทุกใบสมดุล
    expect(db.num("select count(*) from (select transaction_id from sri_os.v_ledger_posted group by 1 having round(sum(debit - credit), 2) <> 0) x")).toBe(0);
  });

  it("B4 · อัปโหลดไฟล์เดิมซ้ำ: ไม่เกิดรายการ ไม่เกิดทรัพย์ ไม่เกิดร่างใหม่แม้แต่แถวเดียว (จับคู่ทรัพย์ด้วยชื่อ ไม่สร้างซ้ำ)", async () => {
    const before = counts();
    for (let k = 0; k < 2; k++) {
      const c = await confirm(condoWorkbook(CONDOS));
      expect(c.ok, JSON.stringify(c)).toBe(true);
      if (c.ok) expect(c.results.every((r) => r.status === "unchanged")).toBe(true);
    }
    expect(counts()).toEqual(before);
    const p = await preview(condoWorkbook(CONDOS));
    expect(p.ok && p.assets.every((a) => a.existing !== null)).toBe(true);
  });

  it("B5 · ขายห้องแรก 3,500,000 → กำไร +500,000 (ต้นทุนของห้องนั้นเอง 3,000,000 ไม่ใช่ถัวเฉลี่ย 4,000,000 ที่จะให้ −500,000) · ห้องที่สองไม่ถูกแตะ", async () => {
    const sell: PostEntryRequest = {
      input: {
        typeKey: findSub("inv.sell_re")!.type.key,
        subCode: "inv.sell_re",
        amount: 3_500_000,
        ownerId: owner(),
        bankAccountId: bankId,
        assetId: assetId("คอนโด ลุมพินี ห้อง 1203"),
        disposal: { costBasis: 0, salePrice: 3_500_000, sellingCosts: 0 },
      },
      docDate: "30/11/2026",
      cashDate: "30/11/2026",
    };
    const before = { pl: pl(), cash: net("1100") };
    const out = await postEntry(sell);
    expect(out.ok, JSON.stringify(out)).toBe(true);
    expect(pl() - before.pl).toBe(500_000);
    expect(net("1100") - before.cash).toBe(3_500_000);
    expect(cost("คอนโด ลุมพินี ห้อง 1203")).toBe(0);
    expect(cost("คอนโด ลุมพินี ห้อง 1507")).toBe(5_500_000);
  });

  it("B6 · ชีทแจกแจงมาจากไฟล์แยก (breakdownFile) ก็ได้ผลเดียวกัน · แต่มีทั้งสองทาง = ปฏิเสธ (ไม่เลือกข้างให้)", async () => {
    const only = (w: Workbook) => ((w.sheets = w.sheets.filter((s) => s.name === "แจกแจงทรัพย์")), w);
    const upload = async () => {
      const fd = new FormData();
      fd.set("file", new File([new Uint8Array([0x50, 0x4b, 3, 4]) as BlobPart], "opening.xlsx"));
      fd.set("breakdownFile", new File([new Uint8Array([0x50, 0x4b, 3, 4]) as BlobPart], "breakdown.xlsx"));
      fd.set("cutoff", "");
      return previewOpeningImport(fd);
    };

    // ไฟล์ยอดตั้งต้นไม่มีชีทแจกแจง + ไฟล์แจกแจงแนบแยก → ใช้ได้ ได้ทรัพย์ชุดเดิม (ตรงกับที่ลงไปแล้ว)
    h.queue = [condoWorkbook(null), only(condoWorkbook(CONDOS))];
    const r = await upload();
    expect(r.ok, JSON.stringify(r)).toBe(true);
    if (r.ok) {
      expect(r.assets.map((a) => a.name)).toEqual(["คอนโด ลุมพินี ห้อง 1203", "คอนโด ลุมพินี ห้อง 1507"]);
      expect(r.assets.every((a) => a.existing !== null)).toBe(true);
    }

    // มีชีทนี้ทั้งในไฟล์ยอดตั้งต้นและในไฟล์แยก → ปฏิเสธ
    h.queue = [condoWorkbook(CONDOS), only(condoWorkbook(CONDOS))];
    const both = await upload();
    expect(both.ok).toBe(false);
    if (!both.ok) expect(both.issues.some((i) => /ทั้งในไฟล์ยอดตั้งต้นและในไฟล์แจกแจง/.test(i.message))).toBe(true);

    // ไฟล์แยกที่ไม่มีชีทแจกแจง → ปฏิเสธ
    h.queue = [condoWorkbook(null), condoWorkbook(null)];
    const none = await upload();
    expect(none.ok).toBe(false);
    h.queue = [];
  });
});
