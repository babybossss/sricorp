/**
 * ยอดตั้งต้นลงสมุด **กับ Postgres จริงในเครื่อง** — ทั้งเส้นทาง: action → loadReference → ตัวอ่านไฟล์ → buildPosting →
 * `fn_reimport_opening` ของ DB จริง (role `authenticated` ของผู้ใช้จริง · RLS และด่านคอลัมน์บังคับจริง)
 *
 * เป็น "เรื่องเล่าต่อเนื่อง" บน DB ชุดเดียว (ลำดับขั้นสำคัญ): ตัวเลขที่ยืนยันทุกตัวอ่านจากสมุดที่ DB บันทึกจริง ไม่ใช่จากสิ่งที่โค้ดส่งไป
 * ไม่มี Postgres ในเครื่อง → ข้ามพร้อมเหตุผล (SRI_REQUIRE_PG=1 ให้พังแทน) · DB ทดสอบถูกลบทิ้งเมื่อจบ
 */
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { createTestDb, pgAvailable, type TestDb } from "./pg-harness";
import { pgClient } from "./pg-client";
import { postableWorkbook, setByCode } from "./post-helpers";
import { setCell } from "./helpers";
import type { Workbook } from "../xlsx";
import { buildBalanceSheet } from "@/lib/db/statements";

const h = vi.hoisted(() => ({ client: null as unknown, perms: new Set<string>(), wb: null as Workbook | null, armed: false, uid: "" }));
vi.mock("next/cache", () => ({ revalidatePath: vi.fn() }));
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => h.client }));
vi.mock("@/lib/auth/session", () => ({
  getAccess: async () => ({ user: { id: h.uid, email: "imp@local" }, permissions: h.perms, profile: null, error: null }),
}));
vi.mock("@/lib/db/import/xlsx", async (orig) => {
  const real = await orig<typeof import("@/lib/db/import/xlsx")>();
  return { ...real, readWorkbook: (b: Uint8Array) => (h.armed && h.wb ? h.wb : real.readWorkbook(b)) };
});

import { confirmOpeningImport, previewOpeningImport } from "@/app/actions/import-opening";
import { loadStatementData } from "@/lib/db/statements-server";
import { fingerprintOf, parseOpeningWorkbook } from "../opening";
import { toStmtLines } from "@/lib/db/statements";

const UID = "0000000a-0000-4000-8000-0000000000a1";
const CONTACT = "0000000c-0000-4000-8000-000000000001";
const UPLOADER = "0000000b-0000-4000-8000-000000000001";
const LOTS = "พอร์ตลงทุน (รายล็อต)";
/** หมวดทรัพย์ของหุ้น — ทรัพย์ที่มีล็อตต้องเป็นหมวดที่ถัวเฉลี่ยได้ (ไม่ใช่ทรัพย์ชิ้นเดียวอย่างอสังหาฯ) */
const STOCK_CATEGORY = "select id, class_id from sri_os.asset_categories order by (code = 'PAPER_STOCK') desc, id limit 1";

describe.skipIf(!pgAvailable)("ยอดตั้งต้นลงสมุดกับ Postgres จริง", { timeout: 120_000 }, () => {
  let db: TestDb;
  let evidencePath = "";
  /**
   * ช่องโหว่ของ migration 20261025000009 ที่เจอเมื่อรันในฐานะผู้ใช้จริง (ดู P0b / P0c) — ใส่ตัวแก้ชั่วคราว **เฉพาะ DB ทดสอบนี้**
   * เพื่อให้ตรวจส่วนที่เหลือของโค้ดฝั่งแอปต่อได้ · migration จริงห้ามแก้จากงานนี้ (supabase/** เป็นของเจ้าของ DB)
   */
  let gateBroken = false;
  let lotReversalBlocked = false;
  const owner = (code: string) => db.su(`select id from sri_os.owners where code='${code}'`);

  /** สำเนานับของทั้งสมุด — ไว้พิสูจน์ "ไม่เกิดอะไรเลย" ด้วยตัวเลข ไม่ใช่ด้วยคำพูด */
  const counts = () => ({
    txns: db.num("select count(*) from sri_os.transactions"),
    lines: db.num("select count(*) from sri_os.transaction_lines"),
    lots: db.num("select count(*) from sri_os.asset_lots"),
    lotsLive: db.num("select count(*) from sri_os.asset_lots where reversed_by_txn_id is null"),
    reversals: db.num("select count(*) from sri_os.transactions where reverses_id is not null"),
  });
  /** ยอดสุทธิ (เดบิต − เครดิต) ของรหัสบัญชีหนึ่งของผู้ถือ จากสมุดที่ post แล้ว */
  const bal = (ownerCode: string, coaCode: string) =>
    db.num(
      `select coalesce(sum(v.debit - v.credit), 0) from sri_os.v_ledger_posted v join sri_os.chart_of_accounts c on c.id = v.coa_id
        where c.code = '${coaCode}' and v.owner_id = (select id from sri_os.owners where code = '${ownerCode}')`
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
  /** รหัสตรวจเนื้อหาเหมือนที่หน้าตัวอย่างคืนให้ผู้ใช้ (ผ่านตัวอย่างจริง) */
  const previewOf = async (wb: Workbook) => {
    const p = await run(wb, previewOpeningImport);
    if (!p.ok) throw new Error("ตัวอย่างถูกปฏิเสธ: " + p.message + JSON.stringify(p.issues));
    return p;
  };
  const confirm = async (wb: Workbook, evidence = true) => {
    const p = await previewOf(wb);
    return run(wb, confirmOpeningImport, {
      fingerprint: p.fingerprint,
      evidence: evidence ? JSON.stringify({ [owner("SRI_CORP")]: { attachments: [evidencePath], contactId: CONTACT } }) : "",
    });
  };

  beforeAll(() => {
    db = createTestDb();
    h.uid = UID;
    h.perms = new Set(["settings.manage", "ledger.approve"]);
    h.client = pgClient(db, UID);
    db.su(`
      insert into auth.users(id) values ('${UID}');
      insert into sri_os.app_users(id, email, display_name, role, is_active) values ('${UID}', 'imp@local', 'mgmt', 'management', true);
      insert into sri_os.user_owner_access(user_id, owner_id) select '${UID}', id from sri_os.owners;
      insert into sri_os.contacts(id, first_name, types) values ('${CONTACT}', 'สำนักงานบัญชี', array['vendor']);
      insert into sri_os.bank_accounts(owner_id, bank, account_name, display_name)
      select o.id, b.bank, b.nm, b.dn from sri_os.owners o join (values
        ('SRI_CORP', 'SCB', 'SRI Corporation', 'SRI - SCB'),
        ('THANAKORN', 'BBL', 'ธนากร', 'ธนากร - BBL 888'),
        ('THANAKORN', 'SCB', 'ธนากร', 'ธนากร - SCB'),
        ('SUTEE', 'TTB', 'สุธี', 'สุธี - TTB')) b(code, bank, nm, dn) on b.code = o.code;
    `);
    evidencePath = `${owner("SRI_CORP")}/${UPLOADER}/0000000e-0000-4000-8000-000000000001.pdf`;

    // (1) ประตูเรียกได้จริงในฐานะผู้ใช้ (authenticated) หรือไม่
    try {
      db.as(UID, `select sri_os.fn_reimport_opening('${owner("SUDJIT")}', '{"entries":[],"lots":[]}'::jsonb);`);
    } catch (e) {
      gateBroken = /permission denied for function/.test(String((e as Error).message));
      if (!gateBroken) throw e;
      db.su("grant execute on function sri_os.fn_opening_set(uuid), sri_os.fn_opening_fingerprint(uuid) to authenticated;");
    }
    // (2) ผู้ใช้ที่มีสิทธิ์จัดการทรัพย์ติดร่องรอยกลับรายการของล็อตได้หรือไม่ (ต้องมี policy UPDATE · ไม่มี = UPDATE ได้ 0 แถวเงียบๆ)
    lotReversalBlocked = db.num("select count(*) from pg_policy where polrelid = 'sri_os.asset_lots'::regclass and polcmd in ('w', '*')") === 0;
    if (lotReversalBlocked) {
      db.su(`create policy lots_reverse_test_workaround on sri_os.asset_lots for update to authenticated
               using (sri_os.fn_can('asset.manage') and exists (select 1 from sri_os.assets a where a.id = asset_id and sri_os.fn_can_see_owner(a.owner_id) and sri_os.fn_can_see_asset(a.id)))
               with check (true);`);
    }
  }, 240_000);

  afterAll(() => db?.drop());

  const addAsset = (code: string, name: string, currency = "THB") =>
    db.su(`insert into sri_os.assets(code, name, class_id, category_id, owner_id, currency)
           select '${code}', '${name}', cat.class_id, cat.id, (select id from sri_os.owners where code='THANAKORN'), '${currency}'
             from (${STOCK_CATEGORY}) cat;`);

  /**
   * **ช่องโหว่จริงของ migration 20261025000009 (ผู้ตรวจต้องรู้)** — `fn_reimport_opening` เป็น security invoker แต่เรียก
   * `fn_opening_set` / `fn_opening_fingerprint` ซึ่งเป็น security definer ที่ถอนสิทธิ์ execute จาก authenticated แล้ว
   * → ผู้ใช้จริงเรียกประตูไม่ได้เลย ("permission denied for function fn_opening_set") · เทสต์ SQL เดิมรันด้วย superuser จึงไม่เห็น
   * `it.fails` = เทสต์ผ่านตราบที่ยังพัง และจะ **แดงทันทีที่ DB ถูกแก้** เพื่อบังคับให้ถอด `fails` + ถอด grant ชั่วคราวใน beforeAll
   */
  it.fails("P0b · ประตูอัปโหลดยอดตั้งต้นเรียกได้จาก role authenticated โดยไม่ต้องมี grant พิเศษ", () => {
    expect(gateBroken).toBe(false);
  });

  /**
   * **ช่องโหว่ที่สอง** — `fn_reimport_opening` ติดร่องรอยกลับรายการของล็อตด้วย `update asset_lots` ในฐานะผู้เรียก
   * แต่ตารางล็อตไม่มี policy UPDATE (ตั้งใจให้ append-only) → RLS ทำให้ update ได้ **0 แถวโดยไม่มี error**
   * ล็อตเดิมจึงไม่ถูกตัดออก → ล็อตซ้ำสองชุด → ด่านลายนิ้วมือท้ายฟังก์ชันจับได้และย้อนทั้งคำสั่ง
   * ผลจริง: ผู้ถือที่มีล็อตหุ้น/ทอง **อัปโหลดแก้ไม่ได้เลย** (เคสที่ไม่มีล็อตไม่โดน)
   */
  it.fails("P0c · ผู้ใช้ที่มีสิทธิ์จัดการทรัพย์ติดร่องรอยกลับรายการของล็อตได้ (มี policy UPDATE ให้ RLS)", () => {
    expect(lotReversalBlocked).toBe(false);
  });

  it("P0 · ฐานข้อมูลทดสอบพร้อม: ผู้ถือ 6 คนที่ใช้งาน · ประตู fn_reimport_opening มีจริง · ยังไม่มียอดตั้งต้น", () => {
    expect(db.num("select count(*) from sri_os.owners where status = 'active'")).toBe(6);
    expect(db.su("select to_regprocedure('sri_os.fn_reimport_opening(uuid,jsonb)') is not null")).toBe("t");
    expect(counts()).toEqual({ txns: 0, lines: 0, lots: 0, lotsLive: 0, reversals: 0 });
  });

  it("P1 · ยังไม่มีทรัพย์ในระบบ: ตัวอย่างบอก blocker 3 ล็อต · กดยืนยันถูกปฏิเสธ · สมุดยังว่าง (ไม่ลงยอดหุ้นเป็นก้อนรวมที่ไม่ผูกทรัพย์)", async () => {
    const wb = postableWorkbook();
    const p = await previewOf(wb);
    expect(p.blockers.filter((b) => /ไม่พบทรัพย์/.test(b.message))).toHaveLength(3);
    const c = await confirm(wb);
    expect(c.ok).toBe(false);
    expect(counts()).toEqual({ txns: 0, lines: 0, lots: 0, lotsLive: 0, reversals: 0 });
  });

  it("P2 · มีทรัพย์แล้วแต่นิติบุคคลไม่แนบหลักฐาน: ปฏิเสธทั้งไฟล์ — ไม่มีผู้ถือบุคคลคนใดถูกลงก่อน", async () => {
    addAsset("PTT", "หุ้น ปตท.");
    addAsset("SET50", "SET50");
    addAsset("K-FIXED", "กองทุน K-FIXED");
    const wb = postableWorkbook();
    const p = await previewOf(wb);
    expect(p.blockers).toEqual([]);
    expect(p.evidenceOwners.map((o) => o.name)).toEqual(["SRI Corporation"]);
    expect(p.plan!.every((x) => x.action === "new" || x.ownerName === "")).toBe(true);
    const c = await confirm(wb, false);
    expect(c.ok).toBe(false);
    if (!c.ok) expect(c.problems?.some((x) => /นิติบุคคล/.test(x.message))).toBe(true);
    expect(counts().txns).toBe(0);
  });

  it("P3 · ลงจริงครั้งแรก: ธนากร 9 ใบ · SRI 5 ใบ · สุธี 2 ใบ · ทุกใบ source=import · ตัวเลขตรงไฟล์ทุกรหัส", async () => {
    // หลักฐานของนิติบุคคลต้องเป็นไฟล์ที่มีอยู่จริงใน Storage ของ SRI (DB นับจาก storage.objects ไม่ใช่ชื่อไฟล์)
    db.su(`insert into storage.buckets(id, name) values ('attachments', 'attachments') on conflict (id) do nothing;
           insert into storage.objects(bucket_id, name) values ('attachments', '${evidencePath}');`);
    const c = await confirm(postableWorkbook());
    expect(c.ok, JSON.stringify(c)).toBe(true);
    if (!c.ok) return;
    const byName = Object.fromEntries(c.results.map((r) => [r.ownerName, r]));
    expect(byName["ธนากร"]).toMatchObject({ status: "posted", reversed: 0, posted: 9, lots: 3 });
    expect(byName["SRI Corporation"]).toMatchObject({ status: "posted", reversed: 0, posted: 5, lots: 0 });
    expect(byName["สุธี"]).toMatchObject({ status: "posted", reversed: 0, posted: 2, lots: 0 });
    for (const n of ["สุดจิตต์", "ธนวินท์", "เบ็ญจพร"]) expect(byName[n].status).toBe("unchanged"); // ไม่มียอด ไม่เคยมี → ไม่เขียนอะไร

    expect(db.num("select count(*) from sri_os.transactions where source <> 'import'")).toBe(0);
    expect(db.num("select count(*) from sri_os.transactions where status <> 'posted'")).toBe(0);
    expect(counts()).toMatchObject({ txns: 16, lots: 3, lotsLive: 3, reversals: 0 });

    // ตัวเลขต่อรหัสบัญชีตรงไฟล์ (หลัง engine เติม 3300 เป็นขาคู่)
    expect(bal("THANAKORN", "1100")).toBe(1_000_000);
    expect(bal("THANAKORN", "1200")).toBe(20_000);
    expect(bal("THANAKORN", "1500")).toBe(3_000_000);
    expect(bal("THANAKORN", "1700")).toBe(300_000);
    expect(bal("THANAKORN", "2410")).toBe(-500_000);
    expect(bal("THANAKORN", "3100")).toBe(-2_000_000);
    expect(bal("THANAKORN", "3300")).toBe(-1_820_000);
    expect(bal("SRI_CORP", "3100")).toBe(-4_000_000);
    expect(bal("SRI_CORP", "3300")).toBe(-1_000_000);
    expect(bal("SUTEE", "1100")).toBe(300_000);
    // เงินสดแยกตามบัญชีธนาคารจริง
    expect(db.rows<{ n: string; s: number }>(`select b.display_name n, sum(l.debit - l.credit) s from sri_os.transaction_lines l join sri_os.bank_accounts b on b.id = l.bank_account_id group by 1 order by 1`))
      .toEqual([{ n: "SRI - SCB", s: 2_000_000 }, { n: "ธนากร - BBL 888", s: 600_000 }, { n: "ธนากร - SCB", s: 400_000 }, { n: "สุธี - TTB", s: 300_000 }]);
  });

  it("P4 · งบดุลดุลทุกผู้ถือและงบรวม (ใช้โค้ดงบจริงอ่านสมุดจริง) · ทุกใบสมดุล", async () => {
    const st = await loadStatementData();
    expect(st.ok).toBe(true);
    if (!st.ok) return;
    const ids = st.owners.map((o) => o.id);
    const expected: Record<string, [number, number, number]> = {
      THANAKORN: [4_320_000, 500_000, 3_820_000],
      SRI_CORP: [8_000_000, 3_000_000, 5_000_000],
      SUTEE: [300_000, 0, 300_000],
      SUDJIT: [0, 0, 0],
    };
    for (const [code, [a, l, e]] of Object.entries(expected)) {
      const bs = buildBalanceSheet(st.lines, { year: 2026, ownerIds: [owner(code)] });
      expect([code, bs.totalAssets, bs.totalLiabilities, bs.totalEquity, bs.balanced, bs.difference, bs.unmapped]).toEqual([code, a, l, e, true, 0, []]);
    }
    const all = buildBalanceSheet(st.lines, { year: 2026, ownerIds: ids });
    expect([all.totalAssets, all.balanced, all.difference]).toEqual([12_620_000, true, 0]);
    // และทุกใบสมดุลในตัวเอง (Money Invariant 1) นับจากสมุด
    expect(db.num("select count(*) from (select transaction_id from sri_os.v_ledger_posted group by 1 having round(sum(debit - credit), 2) <> 0) x")).toBe(0);
    void toStmtLines;
  });

  it("P5 · ยอดหุ้นผูกทรัพย์ต่อใบ: ทะเบียนล็อต = สมุดรายทรัพย์ (fn_asset_lot_mismatch ว่าง) · ล็อตผูกใบที่สร้างมัน", () => {
    expect(db.rows("select * from sri_os.fn_asset_lot_mismatch()")).toEqual([]);
    const per = db.rows<{ code: string; units: number; lot_cost: number; ledger: number }>(
      `select a.code, sri_os.fn_asset_units(a.id) units, sri_os.fn_asset_lot_cost(a.id) lot_cost, sri_os.fn_asset_cost_basis(a.id) ledger
         from sri_os.assets a order by a.code`
    );
    expect(per).toEqual([
      { code: "K-FIXED", units: 1299, lot_cost: 130_000, ledger: 130_000 },
      { code: "PTT", units: 2000, lot_cost: 70_000, ledger: 70_000 },
      { code: "SET50", units: 100, lot_cost: 100_000, ledger: 100_000 },
    ]);
    // ล็อตทุกแถวชี้ไปใบที่ asset_id ตรงกับทรัพย์ของล็อต
    expect(db.num("select count(*) from sri_os.asset_lots l join sri_os.transactions t on t.id = l.source_txn_id where t.asset_id is distinct from l.asset_id")).toBe(0);
  });

  it("P6 · อัปโหลดไฟล์เดิมซ้ำ 3 ครั้ง: ไม่เกิดใบ บรรทัด ล็อต หรือการกลับรายการแม้แต่แถวเดียว (วัดทั้งสมุด)", async () => {
    const before = counts();
    for (let k = 0; k < 3; k++) {
      const c = await confirm(postableWorkbook());
      expect(c.ok).toBe(true);
      if (c.ok) expect(c.results.map((r) => r.status)).toEqual(Array(6).fill("unchanged"));
    }
    expect(counts()).toEqual(before);
    expect(before).toMatchObject({ txns: 16, reversals: 0 });
  });

  it("P7 · ตัวอย่างหลังลงแล้วบอกว่าไม่เปลี่ยน ('unchanged') ทุกคนที่มียอด — แผนในหน้าจอตรงกับที่ DB ตัดสินจริง", async () => {
    const p = await previewOf(postableWorkbook());
    const plan = Object.fromEntries(p.plan!.map((x) => [x.ownerName, x.action]));
    expect(plan).toEqual({ "SRI Corporation": "unchanged", "สุธี": "unchanged", "ธนากร": "unchanged" });
  });

  it("P8 · แก้ตัวเลขหนึ่งตัวของธนากร (ลูกหนี้ 20,000→25,000) → กลับรายการ 9 ใบเดิมของธนากรเท่านั้น แล้วลงชุดใหม่ 9 ใบ · ไม่มีการลบ", async () => {
    const before = counts();
    const tkOld = db.rows<{ id: string }>(`select id from sri_os.transactions where owner_id = '${owner("THANAKORN")}' and reverses_id is null order by created_at, id`).map((r) => r.id);
    const othersBefore = db.su(`select string_agg(id::text, ',' order by id) from sri_os.transactions where owner_id <> '${owner("THANAKORN")}'`);
    expect(tkOld).toHaveLength(9);

    const wb = postableWorkbook();
    setByCode(wb, "BS-ธนากร", "1200", 25_000);
    setByCode(wb, "BS-ธนากร", "3300", 1_825_000);
    const c = await confirm(wb);
    expect(c.ok, JSON.stringify(c)).toBe(true);
    if (!c.ok) return;
    const r = Object.fromEntries(c.results.map((x) => [x.ownerName, x]));
    expect(r["ธนากร"]).toMatchObject({ status: "posted", reversed: 9, posted: 9, lots: 3 });
    expect(r["SRI Corporation"].status).toBe("unchanged");
    expect(r["สุธี"].status).toBe("unchanged");

    const after = counts();
    expect(after.txns).toBe(before.txns + 18); // 9 ใบกลับรายการ + 9 ใบใหม่ — ไม่มีใบไหนหาย
    expect(after.reversals).toBe(9);
    expect(after.lots).toBe(before.lots + 3);
    expect(after.lotsLive).toBe(3);
    // ใบที่ถูกกลับรายการคือ 9 ใบเดิมของธนากรพอดี (ชุดเดียวกัน ไม่เกิน ไม่ขาด) และไม่แตะใบของคนอื่น
    const reversed = db.rows<{ reverses_id: string }>(`select reverses_id from sri_os.transactions where reverses_id is not null`).map((x) => x.reverses_id).sort();
    expect(reversed).toEqual([...tkOld].sort());
    expect(db.su(`select string_agg(id::text, ',' order by id) from sri_os.transactions where owner_id <> '${owner("THANAKORN")}'`)).toBe(othersBefore);
    // ใบเดิมยังอยู่ครบ บรรทัดเดิมไม่ถูกแก้
    expect(db.num(`select count(*) from sri_os.transactions where id = any (string_to_array('${tkOld.join(",")}', ',')::uuid[])`)).toBe(9);
    // ยอดสุทธิใหม่ถูก และทะเบียนล็อตไม่นับซ้ำ (2,000 หน่วย ไม่ใช่ 4,000)
    expect(bal("THANAKORN", "1200")).toBe(25_000);
    expect(bal("THANAKORN", "3300")).toBe(-1_825_000);
    expect(bal("THANAKORN", "1100")).toBe(1_000_000);
    expect(db.num("select sri_os.fn_asset_units(id) from sri_os.assets where code = 'PTT'")).toBe(2000);
    expect(db.num("select sri_os.fn_asset_lot_cost(id) from sri_os.assets where code = 'PTT'")).toBe(70_000);
    expect(db.rows("select * from sri_os.fn_asset_lot_mismatch()")).toEqual([]);
    const st = await loadStatementData();
    if (st.ok) expect(buildBalanceSheet(st.lines, { year: 2026, ownerIds: [owner("THANAKORN")] })).toMatchObject({ balanced: true, difference: 0, totalAssets: 4_325_000 });
  });

  it("P9 · ล็อตสกุลต่างประเทศ: หุ้น USD 2,000 × อัตรา 35 → ต้นทุนบาท 70,000 · เก็บสกุล/ยอดเดิม/อัตรา/วันของอัตราครบ · สมุด = ทะเบียน", async () => {
    addAsset("AAPL", "Apple Inc.", "USD");
    db.su(`insert into sri_os.fx_rates(currency, rate_date, thb_per_unit, source, note) values ('USD', '2025-03-03', 35, 'manual', 'วันซื้อล็อต AAPL')`);
    const wb = postableWorkbook();
    setByCode(wb, "BS-ธนากร", "1200", 25_000);
    setByCode(wb, "BS-ธนากร", "3300", 1_825_000);
    // ล็อตแรก (PTT เดิม 70,000 บาท) เปลี่ยนเป็น AAPL 2,000 USD × 35 = 70,000 บาท — ยอด 1700 ไม่เปลี่ยน
    setCell(wb, LOTS, 4, "J", "อัตรา ณ วันซื้อ (บาทต่อ 1 หน่วย) *");
    setCell(wb, LOTS, 6, "C", "AAPL");
    setCell(wb, LOTS, 6, "I", "USD");
    setCell(wb, LOTS, 6, "E", 2000);
    setCell(wb, LOTS, 6, "F", 1);
    setCell(wb, LOTS, 6, "J", 35);
    const p = await previewOf(wb);
    expect(p.blockers).toEqual([]);
    expect(p.lots[0]).toMatchObject({ name: "AAPL", currency: "USD", fxRate: 35, amountOriginal: 2000, cost: 70_000, assetLabel: "AAPL · Apple Inc." });

    const c = await confirm(wb);
    expect(c.ok, JSON.stringify(c)).toBe(true);
    const lot = db.rows<Record<string, unknown>>(
      `select a.code, l.quantity, l.cost_thb, l.currency, l.amount_original, l.fx_rate, l.fx_rate_date::text fx_rate_date, l.acquired_date::text acquired_date
         from sri_os.asset_lots l join sri_os.assets a on a.id = l.asset_id where a.code = 'AAPL' and l.reversed_by_txn_id is null`
    );
    expect(lot).toEqual([{ code: "AAPL", quantity: 2000, cost_thb: 70_000, currency: "USD", amount_original: 2000, fx_rate: 35, fx_rate_date: "2025-03-03", acquired_date: "2025-03-03" }]);
    // บรรทัดสมุดเป็นบาทเสมอ: ต้นทุนในสมุดของ AAPL = 70,000 บาท = ทะเบียน
    expect(db.num("select sri_os.fn_asset_cost_basis(id) from sri_os.assets where code = 'AAPL'")).toBe(70_000);
    expect(db.rows("select * from sri_os.fn_asset_lot_mismatch()")).toEqual([]);
    // PTT ไม่เหลือยอด (ล็อตเดิมถูกกลับรายการ ไม่ค้าง)
    expect(db.num("select sri_os.fn_asset_units(id) from sri_os.assets where code = 'PTT'")).toBe(0);
    expect(db.num("select sri_os.fn_asset_cost_basis(id) from sri_os.assets where code = 'PTT'")).toBe(0);
    expect(bal("THANAKORN", "1700")).toBe(300_000);
  });

  it("P10 · ล็อต USD ที่อัตราไม่ตรงตารางอัตรา หรือไม่มีอัตรา → ตัวอย่างบอก blocker · ยืนยันไม่เขียนอะไร", async () => {
    const mk = (rate: number | null) => {
      const wb = postableWorkbook();
      setByCode(wb, "BS-ธนากร", "1200", 25_000);
      setByCode(wb, "BS-ธนากร", "3300", 1_825_000);
      setCell(wb, LOTS, 4, "J", "อัตรา ณ วันซื้อ *");
      setCell(wb, LOTS, 6, "C", "AAPL");
      setCell(wb, LOTS, 6, "I", "USD");
      setCell(wb, LOTS, 6, "E", 2000);
      setCell(wb, LOTS, 6, "F", 1);
      setCell(wb, LOTS, 6, "J", rate);
      return wb;
    };
    const before = counts();
    // อัตราต่างจากตาราง (35) → 36 ทำให้ต้นทุน 72,000 ไม่เท่า 1700 → ปฏิเสธตั้งแต่ตรวจไฟล์
    const bad = await run(mk(36), previewOpeningImport);
    expect(bad.ok).toBe(false);
    // ไม่ใส่อัตราเลย (ช่องว่าง) → ปฏิเสธทั้งไฟล์
    const none = await run(mk(null), previewOpeningImport);
    expect(none.ok).toBe(false);
    if (!none.ok) expect(none.issues.some((i) => /ต้องมีอัตรา ณ วันซื้อ/.test(i.message))).toBe(true);
    expect(counts()).toEqual(before);
  });

  it("P11 · ขายหุ้นไปแล้ว แล้วอัปโหลดใหม่ที่แก้ยอด → DB ปฏิเสธ ข้อความอ่านรู้เรื่อง บอกให้กลับรายการใบขายก่อน · ผู้ถือนั้นไม่เปลี่ยนเลย", async () => {
    // ขาย AAPL 500 หน่วย (จาก 2,000) ต้นทุนถัวเฉลี่ย 70,000 × 500/2000 = 17,500 · ได้เงิน 25,000 → กำไร 7,500
    const aapl = db.su("select id from sri_os.assets where code = 'AAPL'");
    const bbl = db.su("select id from sri_os.bank_accounts where display_name = 'ธนากร - BBL 888'");
    const out = db.su(`
      begin;
      select set_config('test.uid', '${UID}', true);
      select sri_os.fn_post_entry(jsonb_build_object(
        'txn_type_code', 'inv.sell_securities', 'doc_date', '2026-10-01', 'cash_date', '2026-10-01',
        'memo', 'ขาย AAPL 500', 'asset_id', '${aapl}', 'contact_id', '${CONTACT}',
        'transactions', jsonb_build_array(jsonb_build_object('owner_id', '${owner("THANAKORN")}', 'lines', jsonb_build_array(
          jsonb_build_object('coa_code', '1100', 'bank_account_id', '${bbl}', 'debit', 25000, 'credit', 0, 'cf_category', 'investing'),
          jsonb_build_object('coa_code', '1700', 'asset_id', '${aapl}', 'debit', 0, 'credit', 17500, 'cf_category', 'investing'),
          jsonb_build_object('coa_code', '4900', 'asset_id', '${aapl}', 'debit', 0, 'credit', 7500, 'cf_category', 'investing')))))) -> 'transaction_ids' ->> 0;
      commit;`);
    const saleTxn = out.split("\n").pop()!;
    db.su(`begin; insert into sri_os.asset_lot_consumptions(lot_id, txn_id, quantity, cost_thb)
             select l.id, '${saleTxn}', 500, 17500 from sri_os.asset_lots l where l.asset_id = '${aapl}' and l.reversed_by_txn_id is null;
           set constraints all immediate; commit;`);
    expect(db.num(`select sri_os.fn_asset_units('${aapl}')`)).toBe(1500);

    const before = counts();
    const wb = postableWorkbook();
    setByCode(wb, "BS-ธนากร", "1200", 26_000); // แก้ตัวเลขอีกตัว
    setByCode(wb, "BS-ธนากร", "3300", 1_826_000);
    setCell(wb, LOTS, 4, "J", "อัตรา ณ วันซื้อ *");
    setCell(wb, LOTS, 6, "C", "AAPL");
    setCell(wb, LOTS, 6, "I", "USD");
    setCell(wb, LOTS, 6, "E", 2000);
    setCell(wb, LOTS, 6, "F", 1);
    setCell(wb, LOTS, 6, "J", 35);
    const c = await confirm(wb);
    expect(c.ok).toBe(false);
    if (c.ok) return;
    expect(c.message).toMatch(/ธนากร: อัปโหลดยอดตั้งต้นใหม่ไม่ได้ เพราะมีการขายหรือเก็บเงิน/);
    expect(c.message).toMatch(/กลับรายการใบขาย\/ใบรับชำระ/);
    expect(c.message).toMatch(/ยังไม่ได้เปลี่ยนอะไรของผู้ถือคนนี้/);
    expect(c.message).toContain(saleTxn); // บอกว่าใบไหนอ้างอยู่ (รายละเอียดจาก DB ไม่ถูกกลืน)
    // คนก่อนหน้าในลำดับ (SRI, สุธี) เนื้อเหมือนเดิม ไม่ถูกแตะ · ธนากรล้ม · คนหลังจากนั้น "ยังไม่ได้ทำ"
    const st = Object.fromEntries((c.results ?? []).map((r) => [r.ownerName, r.status]));
    expect(st["ธนากร"]).toBe("failed");
    expect(counts()).toEqual(before); // ทั้งสมุดไม่ขยับแม้แถวเดียว
    expect(bal("THANAKORN", "1200")).toBe(25_000);
    expect(db.num(`select sri_os.fn_asset_units('${aapl}')`)).toBe(1500);
  });

  it("P12 · ตัวควบคุมเชิงลบ: ถ้าลงหุ้นโดยไม่ผูกทรัพย์ (ที่โค้ดนี้ไม่ทำ) fn_asset_lot_mismatch ต้องจับได้ — พิสูจน์ว่าเครื่องวัดใน P5 ไวพอ", async () => {
    // สุดจิตต์: ทรัพย์ + ใบยอดยกมาที่ asset_id ถูกถอดออก (จำลองโค้ดที่ลืมผูกทรัพย์) ผ่านประตูเดียวกัน
    const sj = owner("SUDJIT");
    db.su(`insert into sri_os.assets(code, name, class_id, category_id, owner_id, currency)
           select 'NEG-1', 'ทรัพย์ทดสอบ', cat.class_id, cat.id, '${sj}', 'THB' from (${STOCK_CATEGORY}) cat;`);
    const asset = db.su("select id from sri_os.assets where code = 'NEG-1'");
    const payload = {
      entries: [{
        txn_type_code: "opn.securities", doc_date: "2026-09-30", source: "import", memo: "ควบคุมเชิงลบ",
        transactions: [{ owner_id: sj, lines: [
          { coa_code: "1700", debit: 50_000, credit: 0, cf_category: "none" }, // ไม่มี asset_id
          { coa_code: "3300", debit: 0, credit: 50_000, cf_category: "none" }] }],
      }],
      lots: [{ asset_id: asset, acquired_date: "2026-01-02", quantity: 100, cost_thb: 50_000 }],
    };
    h.client = pgClient(db, UID);
    const res = await (h.client as ReturnType<typeof pgClient>).rpc("fn_reimport_opening", { p_owner: sj, p_payload: payload });
    expect(res.error).toBeNull(); // ประตูรับ — ด่านจริงอยู่ที่ตอนขาย
    expect(db.rows("select asset_id::text, lot_cost, ledger_cost, diff from sri_os.fn_asset_lot_mismatch()")).toEqual([
      { asset_id: asset, lot_cost: 50_000, ledger_cost: 0, diff: 50_000 },
    ]);
    void fingerprintOf;
    void parseOpeningWorkbook;
  });
});
