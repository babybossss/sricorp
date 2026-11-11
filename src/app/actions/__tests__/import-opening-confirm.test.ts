import "./mocks";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ctx, resetCtx } from "./ctx";
import { ASSET, BANK, CONTACT, OWNER, referenceFixture } from "./fake-db";
import { confirmOpeningImport, previewOpeningImport } from "../import-opening";
import { FIXTURE, loadFixture, setCell, syncBreakdown } from "@/lib/db/import/__tests__/helpers";
import { itemName, postableWorkbook, setByCode } from "@/lib/db/import/__tests__/post-helpers";
import { BLOCKED_BY_REFERENCES_MARKER } from "@/lib/db/import/opening-run";
import { fingerprintOf, parseOpeningWorkbook } from "@/lib/db/import/opening";
import type { Workbook } from "@/lib/db/import/xlsx";
import { readFileSync } from "node:fs";

/**
 * ขั้นยืนยัน: ตัวอ่านไฟล์ถูกแทนด้วย Workbook ที่เทสต์เตรียมไว้ (แก้ช่องเป็นรายเคสได้โดยไม่ต้องเขียน .xlsx กลับ)
 * ส่วนที่พิสูจน์กับ Postgres จริง (กลับรายการ · ลายนิ้วมือ · งบดุล) อยู่ที่ db-opening.pg.test.ts
 */
const state: { wb: Workbook | null; armed: boolean } = { wb: null, armed: false };
vi.mock("@/lib/db/import/xlsx", async (orig) => {
  const real = await orig<typeof import("@/lib/db/import/xlsx")>();
  // แทนที่เฉพาะตอนที่ action กำลังทำงาน (armed) — helper ของเทสต์เองใช้ตัวอ่านจริงเพื่อเตรียมไฟล์
  return { ...real, readWorkbook: (bytes: Uint8Array) => (state.armed && state.wb ? state.wb : real.readWorkbook(bytes)) };
});
async function armed<T>(fn: () => Promise<T>): Promise<T> {
  state.armed = true;
  try {
    return await fn();
  } finally {
    state.armed = false;
  }
}

const UID = "11111111-1111-4111-8111-111111111111";
const EVIDENCE = { [OWNER.corp]: { attachments: [`${OWNER.corp}/${UID}/22222222-2222-4222-8222-222222222222.pdf`], contactId: CONTACT } };

function reference() {
  const ref = referenceFixture();
  const extra = (id: string, name: string) => ({ id, code: name, name, policy: "personal_flexible" as const, status: "active", color: null, sortOrder: 9 });
  ref.owners.push(extra("o-sudjit", "สุดจิตต์"), extra("o-thanawin", "ธนวินท์"), extra("o-benjaporn", "เบ็ญจพร"));
  ref.banks.find((b) => b.id === BANK.tk)!.name = "ธนากร - BBL 888";
  return { ok: true as const, ref };
}

/** ทรัพย์ของธนากรที่ล็อตในไฟล์อ้างถึง (ชื่อ/รหัสตรงกับชีทรายล็อต) */
function seedAssets() {
  const row = (id: string, code: string, name: string) => ({ id, code, name, owner_id: OWNER.tk, status: "active", currency: "THB" });
  ctx.db.tables.assets.push(row(ASSET, "PTT", "หุ้น ปตท."), row("a-set50", "SET50", "SET50"), row("a-kfixed", "K-FIXED", "กองทุน K-FIXED"));
  seedItemAssets();
}

/** หมวดทรัพย์ในทะเบียน (id จำลอง) + ทรัพย์รายชิ้นของชีทแจกแจงที่ลงทะเบียนไว้แล้ว */
function seedCategories() {
  ctx.db.tables.asset_categories.push(
    { id: "cat-rental", class_id: "cls-re", code: "RE_RENTAL" },
    { id: "cat-srr", class_id: "cls-re", code: "RE_SRR" },
  );
}
function seedItemAssets() {
  const item = (id: string, code: string, owner: string, ownerName: string, line: string, category: string) => ({
    id, code, name: itemName(line, ownerName), owner_id: owner, status: "active", currency: "THB",
    category_id: category, class_id: "cls-re",
  });
  ctx.db.tables.assets.push(
    item("a-sri-1400", "RE-0001", OWNER.corp, "SRI Corporation", "1400", "cat-srr"),
    item("a-sri-1500", "RE-0002", OWNER.corp, "SRI Corporation", "1500", "cat-rental"),
    item("a-tk-1500", "RE-0003", OWNER.tk, "ธนากร", "1500", "cat-rental"),
  );
}

const bytes = () => new Uint8Array(readFileSync(FIXTURE));
const form = (extra: Record<string, string> = {}, cutoff = "30/09/2026") => {
  const fd = new FormData();
  fd.set("file", new File([bytes() as BlobPart], "opening.xlsx"));
  fd.set("cutoff", cutoff);
  for (const [k, v] of Object.entries(extra)) fd.set(k, v);
  return fd;
};

/** รหัสตรวจของไฟล์ที่เทสต์เตรียมไว้ — เหมือนที่หน้าตัวอย่างคืนให้ผู้ใช้ */
function fingerprintOfState(): string {
  const r = parseOpeningWorkbook(state.wb!, {
    owners: ctx.reference.ok ? ctx.reference.ref.owners.map((o) => ({ id: o.id, name: o.name, status: o.status })) : [],
    banks: ctx.reference.ok ? ctx.reference.ref.banks.map((b) => ({ id: b.id, ownerId: b.ownerId, name: b.name, isActive: b.isActive, currency: b.currency })) : [],
    cutoff: "2026-09-30",
  });
  if (!r.ok) throw new Error(r.issues.map((i) => i.message).join("\n"));
  return fingerprintOf(r.parsed);
}
const confirm = (extra: Record<string, string> = {}) =>
  armed(() => confirmOpeningImport(form({ fingerprint: fingerprintOfState(), evidence: JSON.stringify(EVIDENCE), ...extra })));

beforeEach(() => {
  resetCtx();
  ctx.reference = reference();
  ctx.access.permissions = new Set(["settings.manage", "ledger.approve"]) as never;
  state.wb = postableWorkbook();
  seedCategories();
  seedAssets();
});

describe("confirmOpeningImport · ประตูเดียว fn_reimport_opening", () => {
  it("ลงจริง: เรียกประตูทีละผู้ถือที่ใช้งานอยู่ (6 คน) ด้วย {entries, lots} เท่านั้น · ไม่เขียนตารางตรงๆ · ไม่ใช้ fn_post_entry", async () => {
    const r = await confirm();
    expect(r.ok).toBe(true);
    const calls = ctx.db.reimportCalls;
    expect(calls).toHaveLength(6);
    expect(calls.map((c) => c.p_owner).sort()).toEqual(ctx.reference.ok ? ctx.reference.ref.owners.filter((o) => o.status === "active").map((o) => o.id).sort() : []);
    for (const c of calls) expect(Object.keys(c.p_payload).sort()).toEqual(["entries", "lots"]);
    expect(ctx.db.writes).toEqual([]);
    expect(ctx.db.rpcCalls).toEqual([]);
    expect(ctx.db.rows).toHaveLength(0);

    const tk = calls.find((c) => c.p_owner === OWNER.tk)!;
    expect(tk.p_payload.entries).toHaveLength(9);
    expect(tk.p_payload.lots).toHaveLength(3);
    expect(tk.p_payload.entries.at(-1)!.txn_type_code).toBe("opn.capital");
    expect(tk.p_payload.entries.every((e) => e.source === "import" && e.doc_date === "2026-09-30")).toBe(true);
    // ทุกใบสมดุลและเป็นของผู้ถือเดียว
    for (const c of calls)
      for (const e of c.p_payload.entries) {
        const lines = (e.transactions as { owner_id: string; lines: { debit: number; credit: number }[] }[]).flatMap((t) => t.lines);
        expect(Math.round(lines.reduce((t, l) => t + l.debit - l.credit, 0) * 100)).toBe(0);
        expect((e.transactions as { owner_id: string }[]).every((t) => t.owner_id === c.p_owner)).toBe(true);
      }
    if (r.ok) expect(r.results.map((x) => x.status)).toEqual(Array(6).fill("posted"));
  });

  it("ผู้ถือที่ไม่มียอดในไฟล์ถูกส่งเข้าประตูด้วย entries ว่าง (เพื่อให้ประตูถอนยอดเดิมถ้ามี) ไม่ถูกข้าม", async () => {
    await confirm();
    const empty = ctx.db.reimportCalls.filter((c) => c.p_payload.entries.length === 0);
    expect(empty.map((c) => c.p_owner).sort()).toEqual(["o-benjaporn", "o-sudjit", "o-thanawin"]);
    expect(empty.every((c) => c.p_payload.lots.length === 0)).toBe(true);
  });

  it("ไฟล์ตัวอย่างเดิมที่มี 1310/2310 ลงได้ทั้งไฟล์ (ตารางกฎมีหมวดยอดยกมาให้แล้ว) · ลูกหนี้/เจ้าหนี้ระหว่างกันไม่ถูกข้ามเงียบๆ", async () => {
    state.wb = loadFixture();
    const r = await confirm();
    expect(r.ok).toBe(true);
    const subsOf = (owner: string) => ctx.db.reimportCalls.find((c) => c.p_owner === owner)!.p_payload.entries.map((e) => e.txn_type_code);
    expect(subsOf(OWNER.tk)).toContain("opn.intercompany_receivable");
    expect(subsOf(OWNER.sutee)).toContain("opn.intercompany_payable");
  });

  it("ไม่มีทรัพย์ในระบบ (ไม่ส่งข้อมูลทรัพย์) → ปฏิเสธ ไม่เรียกประตู — ไม่ลงยอดหุ้นเป็นก้อนรวมที่ไม่ผูกทรัพย์", async () => {
    ctx.db.tables.assets.length = 0;
    const r = await confirm();
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.problems?.filter((p) => /ไม่พบทรัพย์/.test(p.message))).toHaveLength(3);
    expect(ctx.db.reimportCalls).toHaveLength(0);
  });

  it("นิติบุคคลไม่ส่งหลักฐาน/ผู้ติดต่อ → ปฏิเสธ ไม่เรียกประตูกับใครเลย (ไม่ลงเฉพาะคนที่ไม่ติดเงื่อนไข)", async () => {
    const r = await confirm({ evidence: "" });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.problems?.some((p) => p.ownerName === "SRI Corporation" && /นิติบุคคล/.test(p.message))).toBe(true);
    expect(ctx.db.reimportCalls).toHaveLength(0);
  });

  it("หลักฐานอ้างผู้ติดต่อที่ไม่มีในระบบ หรือรูปแบบข้อมูลผิด → ปฏิเสธก่อนทำอะไร", async () => {
    for (const evidence of ["{ไม่ใช่ json", "[]", JSON.stringify({ [OWNER.corp]: { attachments: [], contactId: "ไม่มีคนนี้" } }), JSON.stringify({ "ไม่มีผู้ถือ": {} })]) {
      const r = await confirm({ evidence });
      expect(r.ok).toBe(false);
    }
    expect(ctx.db.reimportCalls).toHaveLength(0);
  });

  it("ไม่ส่งรหัสตรวจเนื้อหา → ปฏิเสธ · รหัสไม่ตรงกับไฟล์ (เปลี่ยนวัน/แก้ตัวเลขหลังดูตัวอย่าง) → ปฏิเสธ", async () => {
    const none = await armed(() => confirmOpeningImport(form({ evidence: JSON.stringify(EVIDENCE) })));
    expect(none.ok).toBe(false);
    if (!none.ok) expect(none.message).toMatch(/รหัสตรวจเนื้อหา/);

    const stale = fingerprintOfState();
    // ผู้ใช้แก้ไฟล์หลังดูตัวอย่าง — แก้แล้วไฟล์ยังถูกต้องทุกข้อ (ดุล) จึงต้องเป็นรหัสตรวจเนื้อหาที่จับได้ ไม่ใช่ด่านตรวจไฟล์
    setByCode(state.wb!, "BS-ธนากร", "1200", 25_000);
    setByCode(state.wb!, "BS-ธนากร", "3300", 1_825_000);
    expect(fingerprintOfState()).not.toBe(stale); // ไฟล์ใหม่ถูกต้อง แต่เป็นคนละเนื้อหากับที่ผู้ใช้เห็น
    const r = await armed(() => confirmOpeningImport(form({ fingerprint: stale, evidence: JSON.stringify(EVIDENCE) })));
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.message).toMatch(/ไม่ตรงกับที่ตรวจและแสดงตัวอย่างไว้/);
    expect(ctx.db.reimportCalls).toHaveLength(0);
  });

  it.each([
    ["ไม่ได้ล็อกอิน", () => (ctx.access.user = null), /เข้าสู่ระบบ/],
    ["ไม่มีสิทธิ์ตั้งค่าระบบ", () => (ctx.access.permissions = new Set(["ledger.approve"]) as never), /ตั้งค่าระบบ/],
    ["ไม่มีสิทธิ์ลงสมุด (ledger.approve)", () => (ctx.access.permissions = new Set(["settings.manage"]) as never), /อนุมัติเข้าสมุด/],
    ["ตรวจสิทธิ์ไม่สำเร็จ", () => (ctx.access.error = "boom"), /boom/],
  ])("%s → ปฏิเสธก่อนอ่านไฟล์ ไม่เรียกประตู", async (_n, arrange, re) => {
    arrange();
    const r = await confirm();
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.message).toMatch(re);
    expect(ctx.db.reimportCalls).toHaveLength(0);
  });

  it("ผู้ถือที่ยังไม่จดทะเบียน/ไม่ได้ใช้งาน ไม่ถูกส่งเข้าประตู (ไฟล์ที่ให้ชีทของ planned ถูกปฏิเสธตั้งแต่ parse)", async () => {
    await confirm();
    expect(ctx.db.reimportCalls.some((c) => c.p_owner === OWNER.planned)).toBe(false);
  });
});

describe("confirmOpeningImport · ผลจากประตู", () => {
  it("ผู้ถือคนที่ 3 ล้ม → หยุดที่นั่น คนที่เหลือ 'ยังไม่ได้ทำ' · ผลบอกว่าใครลงแล้ว/ใครล้ม", async () => {
    let n = 0;
    ctx.db.control.reimport = (call) =>
      ++n === 3
        ? { data: null, error: { message: "ผู้ถือคนนี้ล้ม", code: "P0001" } }
        : { data: { changed: true, reversed: 0, posted: call.p_payload.entries.length, lots: call.p_payload.lots.length }, error: null };
    const r = await confirm();
    expect(r.ok).toBe(false);
    expect(ctx.db.reimportCalls).toHaveLength(3); // ไม่เรียกคนที่ 4-6
    if (!r.ok) {
      expect(r.results!.map((x) => x.status)).toEqual(["posted", "posted", "failed", "skipped", "skipped", "skipped"]);
      expect(r.message).toMatch(/ผู้ถือคนนี้ล้ม/);
    }
  });

  it("DB ปฏิเสธเพราะขายหุ้นไปแล้ว → ข้อความคนอ่านรู้เรื่อง บอกว่าต้องกลับรายการใบขายก่อน และบอกว่าผู้ถือคนนี้ยังไม่เปลี่ยน", async () => {
    ctx.db.control.reimport = () => ({
      data: null,
      error: { message: `อัปโหลดยอดตั้งต้นใหม่ของผู้ถือนี้ไม่ได้ ${BLOCKED_BY_REFERENCES_MARKER}: ขายล็อตของทรัพย์ x ไปแล้ว (ใบ y)`, code: "P0001" },
    });
    const r = await confirm();
    expect(r.ok).toBe(false);
    if (!r.ok) {
      expect(r.message).toMatch(/กลับรายการใบขาย\/ใบรับชำระ/);
      expect(r.message).toMatch(/ยังไม่ได้เปลี่ยนอะไรของผู้ถือคนนี้/);
      expect(r.message).toMatch(/ขายล็อตของทรัพย์ x ไปแล้ว/); // รายละเอียดจาก DB ไม่ถูกกลืน
      expect(r.results![0].status).toBe("failed");
    }
  });

  it("ข้อความของ DB ในไฟล์ migration ยังตรงกับที่โค้ดจับ (กันข้อความเปลี่ยนแล้วผู้ใช้เห็นข้อความดิบ)", () => {
    const sql = readFileSync("supabase/migrations/20261025000009_reimport_opening.sql", "utf8");
    expect(sql).toContain(BLOCKED_BY_REFERENCES_MARKER);
  });

  it("เนื้อเหมือนเดิม (changed=false) → รายงานว่า 'ไม่เปลี่ยน' ไม่ใช่ 'ลงแล้ว'", async () => {
    ctx.db.control.reimport = () => ({ data: { changed: false, reason: "เหมือนเดิม", kept: 3, reversed: 0, posted: 0, lots: 0 }, error: null });
    const r = await confirm();
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.results.every((x) => x.status === "unchanged")).toBe(true);
  });

  it.each([
    ["ไม่มี changed", { posted: 1 }],
    ["ตอบ null", null],
    ["ลงน้อยกว่าที่ส่ง", { changed: true, reversed: 0, posted: 1, lots: 0 }],
    ["ล็อตไม่ครบ", { changed: true, reversed: 0, posted: 9, lots: 1 }],
  ])("DB ตอบกลับไม่ครบ/ไม่ตรงที่ส่ง (%s) → ไม่รายงานว่าสำเร็จ ให้ตรวจสมุดก่อนอัปโหลดซ้ำ", async (_n, data) => {
    ctx.db.control.reimport = () => ({ data, error: null });
    const r = await confirm();
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.results!.some((x) => x.status === "failed")).toBe(true);
  });

  it("เน็ตหลุดกลางทาง (rpc throw) → ล้มอย่างบอกได้ ไม่เงียบ", async () => {
    ctx.db.control.reimport = () => {
      throw new Error("fetch failed");
    };
    const r = await confirm();
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.results![0].status).toBe("failed");
  });
});

describe("previewOpeningImport · วันตัดยอดจากไฟล์ · ตัวขัดขวาง · แผน", () => {
  const preview = (cutoff = "") => armed(() => previewOpeningImport(form({}, cutoff)));

  it("เว้นวันตัดยอด → อ่านจากหัวชีทให้ (30/09/2026) และบอกว่ามาจากไฟล์", async () => {
    const r = await preview("");
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.cutoff).toBe("2026-09-30");
      expect(r.cutoffFromFile).toBe(true);
    }
  });

  it("กรอกวันเองแล้วไม่ตรงกับในชีท → ปฏิเสธ (ไม่ถูกแทนด้วยวันในไฟล์)", async () => {
    const r = await preview("31/10/2026");
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.issues.length).toBeGreaterThanOrEqual(6);
  });

  it("เว้นวันตัดยอดแต่ชีทเขียนคนละวัน → ปฏิเสธ บอกชีท", async () => {
    setCell(state.wb!, "BS-ธนากร", 2, "A", "ณ วันที่ 31/10/2026");
    const r = await preview("");
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.issues[0].message).toMatch(/ไม่ตรงกัน/);
  });

  it("พรีวิวไฟล์เดิม: 1310/2310 ไม่เป็น blocker แล้ว · บอกผู้ถือที่ต้องแนบหลักฐาน · ล็อตเห็นทรัพย์ที่จะผูก · ไม่เขียนอะไร", async () => {
    state.wb = loadFixture(); // มี 1310/2310
    const r = await preview("");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.blockers).toEqual([]);
    expect(r.evidenceOwners.map((o) => o.name)).toEqual(["SRI Corporation"]);
    expect(r.lots.map((l) => l.assetLabel)).toEqual(["PTT · หุ้น ปตท.", "SET50 · SET50", "K-FIXED · กองทุน K-FIXED"]);
    expect(r.canPost).toBe(true);
    expect(ctx.db.reimportCalls).toHaveLength(0);
    expect(ctx.db.writes).toEqual([]);
  });

  it("ทรัพย์ไม่พบ → ล็อตแสดง assetLabel เป็น null และมี blocker", async () => {
    ctx.db.tables.assets.length = 0;
    const r = await preview("");
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.lots.every((l) => l.assetLabel === null)).toBe(true);
      expect(r.blockers.filter((b) => /ไม่พบทรัพย์/.test(b.message))).toHaveLength(3);
    }
  });

  it("ไม่มีสิทธิ์ลงสมุด → canPost = false (เห็นตัวอย่างได้ แต่ปุ่มกดไม่ได้)", async () => {
    ctx.access.permissions = new Set(["settings.manage"]) as never;
    const r = await preview("");
    expect(r.ok && r.canPost).toBe(false);
  });

  it("อ่านทรัพย์/อัตราจาก DB ไม่ได้ → ตัวอย่างยังแสดง แต่เป็น blocker (กดยืนยันไม่ได้) ไม่ใช่เดา · ขั้นยืนยันไม่เรียกประตู", async () => {
    const real = ctx.db.client.from;
    ctx.db.client.from = ((t: string) => {
      if (t === "fx_rates") throw new Error("connection reset");
      return real(t);
    }) as never;
    const r = await preview("");
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.blockers.some((b) => /อ่านข้อมูลทรัพย์\/อัตราแลกเปลี่ยนไม่ได้.*connection reset/.test(b.message))).toBe(true);
    const c = await confirm();
    expect(c.ok).toBe(false);
    expect(ctx.db.reimportCalls).toHaveLength(0);
  });

  it("แผน: ยอดตั้งต้นในสมุดเหมือนไฟล์ = ไม่เปลี่ยน · ต่างกัน = แทนที่ · ไม่มีในไฟล์แต่มีในสมุด = ถอน", async () => {
    // ลงยอดของธนากรลง "สมุดจำลอง" ด้วยใบเดียวกับที่ประตูจะได้รับ แล้วดูแผน
    await confirm();
    const tk = ctx.db.reimportCalls.find((c) => c.p_owner === OWNER.tk)!;
    for (const e of tk.p_payload.entries) await ctx.db.client.rpc("fn_post_entry", { p_payload: e });
    const same = await preview("");
    expect(same.ok && same.plan!.find((p) => p.ownerId === OWNER.tk)!.action).toBe("unchanged");
    expect(same.ok && same.plan!.find((p) => p.ownerId === OWNER.sutee)!.action).toBe("new");

    setByCode(state.wb!, "BS-ธนากร", "1200", 25_000); // ลูกหนี้ค่าเช่า 20,000 → 25,000 แล้วชดเชยกำไรสะสมให้ดุล
    setByCode(state.wb!, "BS-ธนากร", "3300", 1_825_000);
    const changed = await preview("");
    expect(changed.ok && changed.plan!.find((p) => p.ownerId === OWNER.tk)!.action).toBe("replace");

    // ธนากรไม่มียอดเลยในไฟล์ใหม่ (ชีทว่าง) แต่ในสมุดมี → ถอน
    for (const code of ["1100", "1200", "1500", "1700", "2410", "3100", "3300"]) setByCode(state.wb!, "BS-ธนากร", code, null);
    for (const r of [38, 39]) setCell(state.wb!, "BS-ธนากร", r, "E", null);
    for (const r of [6, 7, 8]) for (const c of "ABCDEFGI") setCell(state.wb!, "พอร์ตลงทุน (รายล็อต)", r, c, null);
    syncBreakdown(state.wb!); // ไม่มียอด 1500 แล้ว → ทรัพย์รายชิ้นของธนากรก็ต้องหมดด้วย ไม่งั้นกระทบยอดไม่ผ่าน
    const retract = await preview("");
    expect(retract.ok && retract.plan!.find((p) => p.ownerId === OWNER.tk)!.action).toBe("retract");
  });
});

/* ---------------------------------------------------------------- ทรัพย์รายชิ้นจากชีทแจกแจง */

describe("confirmOpeningImport · ทรัพย์รายชิ้นจากชีทแจกแจง", () => {
  const CAN_REGISTER = ["settings.manage", "ledger.approve", "asset.manage", "portfolio.view_all"];
  const preview = (cutoff = "") => armed(() => previewOpeningImport(form({}, cutoff)));
  /** ทะเบียนมีแต่ทรัพย์ของล็อตหุ้น — ทรัพย์รายชิ้น 3 ชิ้น (SRI 2 · ธนากร 1) ยังไม่ได้ลงทะเบียน */
  const unregisterItems = () => {
    ctx.db.tables.assets.splice(0, ctx.db.tables.assets.length, ...ctx.db.tables.assets.filter((a) => !String(a.id).startsWith("a-sri-") && a.id !== "a-tk-1500"));
  };
  const linesOf = (ownerId: string) =>
    ctx.db.reimportCalls.find((c) => c.p_owner === ownerId)!.p_payload.entries.flatMap((e) => (e.transactions as { lines: Record<string, unknown>[] }[]).flatMap((t) => t.lines));

  it("ทรัพย์ในทะเบียนครบ: ส่งเข้าประตูเป็นหนึ่งบรรทัดต่อชิ้น ผูก asset_id · ไม่ลงทะเบียนทรัพย์ซ้ำ · ไม่มีบรรทัด 1500 ที่ไม่ผูกทรัพย์", async () => {
    const r = await confirm();
    expect(r.ok, JSON.stringify(r)).toBe(true);
    expect(ctx.db.applyDraftCalls).toEqual([]);
    expect(ctx.db.writes).toEqual([]);
    const l1500 = linesOf(OWNER.tk).filter((l) => l.coa_code === "1500");
    expect(l1500).toHaveLength(1);
    expect(l1500[0]).toMatchObject({ asset_id: "a-tk-1500", debit: 3_000_000 });
    expect(linesOf(OWNER.corp).filter((l) => ["1400", "1500"].includes(String(l.coa_code))).every((l) => l.asset_id)).toBe(true);
  });

  it("ทรัพย์ยังไม่ลงทะเบียน + มีสิทธิ์ลงทะเบียนตรง → ลงทะเบียน 3 ชิ้นก่อน (ร่าง + fn_apply_asset_draft) แล้วส่งบรรทัดผูกรหัสทรัพย์ที่เพิ่งออก · ไม่มี delete", async () => {
    ctx.access.permissions = new Set(CAN_REGISTER) as never;
    unregisterItems();
    const before = ctx.db.tables.assets.length;
    const r = await confirm();
    expect(r.ok, JSON.stringify(r)).toBe(true);
    expect(ctx.db.applyDraftCalls).toHaveLength(3);
    expect(ctx.db.tables.assets).toHaveLength(before + 3);
    expect(ctx.db.writes.map((w) => `${w.table}:${w.op}`)).toEqual([...Array(3).fill("asset_drafts:insert")]);
    // ร่างแต่ละใบเป็นชนิด create ของผู้ถือถูกคน หมวดถูก และสร้างโดยผู้ใช้ที่ยืนยัน
    const drafts = ctx.db.tables.asset_drafts;
    expect(drafts.map((d) => [d.kind, d.owner_id, d.category_id]).sort()).toEqual(
      [["create", OWNER.corp, "cat-rental"], ["create", OWNER.corp, "cat-srr"], ["create", OWNER.tk, "cat-rental"]].sort()
    );
    expect(drafts.every((d) => d.created_by === ctx.access.user!.id && d.class_id === "cls-re")).toBe(true);
    // บรรทัดในสมุดผูกรหัสทรัพย์ที่เพิ่งออก (ไม่ใช่รหัสชั่วคราว) ทุกบรรทัด
    const created = new Set(ctx.db.tables.assets.slice(before).map((a) => a.id));
    const l1500 = linesOf(OWNER.tk).filter((l) => l.coa_code === "1500");
    expect(l1500).toHaveLength(1);
    expect(created.has(String(l1500[0].asset_id))).toBe(true);
    expect(JSON.stringify(ctx.db.reimportCalls)).not.toContain("pending-asset:");
  });

  it("อัปโหลดซ้ำหลังลงทะเบียนแล้ว → จับคู่ด้วยชื่อ ไม่สร้างทรัพย์ซ้ำ", async () => {
    ctx.access.permissions = new Set(CAN_REGISTER) as never;
    unregisterItems();
    await confirm();
    const after = ctx.db.tables.assets.length;
    ctx.db.reimportCalls.length = 0;
    const again = await confirm();
    expect(again.ok).toBe(true);
    expect(ctx.db.tables.assets).toHaveLength(after);
    expect(ctx.db.applyDraftCalls).toHaveLength(3); // ครั้งแรกเท่านั้น
  });

  it("ไม่มีสิทธิ์ลงทะเบียนทรัพย์ตรง (มีแค่ settings.manage + ledger.approve) → ปฏิเสธก่อนเขียนอะไร · ไม่เรียกประตู", async () => {
    unregisterItems();
    const r = await confirm();
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.message).toMatch(/ลงทะเบียนทรัพย์ตรงไม่ได้/);
    expect(ctx.db.writes).toEqual([]);
    expect(ctx.db.applyDraftCalls).toEqual([]);
    expect(ctx.db.reimportCalls).toHaveLength(0);
  });

  it("ปัญหาที่รู้ล่วงหน้า (นิติบุคคลไม่ส่งหลักฐาน) → ไม่ลงทะเบียนทรัพย์เลย (ไม่ทิ้งทรัพย์เปล่าไว้ในทะเบียน)", async () => {
    ctx.access.permissions = new Set(CAN_REGISTER) as never;
    unregisterItems();
    const r = await confirm({ evidence: "" });
    expect(r.ok).toBe(false);
    expect(ctx.db.writes).toEqual([]);
    expect(ctx.db.applyDraftCalls).toEqual([]);
    expect(ctx.db.reimportCalls).toHaveLength(0);
  });

  it("fn_apply_asset_draft ล้ม → ไม่ลงสมุด · ร่างที่สร้างถูกยกเลิก (ไม่ค้าง pending) · บอกจำนวนที่ลงทะเบียนไปแล้ว · อัปโหลดซ้ำได้", async () => {
    ctx.access.permissions = new Set(CAN_REGISTER) as never;
    unregisterItems();
    ctx.db.control.applyDraftError = { message: "permission denied for table assets" };
    const r = await confirm();
    expect(r.ok).toBe(false);
    if (!r.ok) {
      expect(r.message).toMatch(/ลงทะเบียนทรัพย์ไปแล้ว 0 จาก 3 ชิ้น/);
      expect(r.message).toMatch(/ยังไม่ได้ลงสมุดบัญชี/);
      expect(r.message).toMatch(/ไม่สร้างซ้ำ/);
    }
    expect(ctx.db.reimportCalls).toHaveLength(0);
    expect(ctx.db.tables.asset_drafts.every((d) => d.status === "cancelled")).toBe(true);
    expect(ctx.db.writes.some((w) => w.op === "delete")).toBe(false);
  });

  it("ไฟล์ไม่มีชีทแจกแจง → ขั้นยืนยันปฏิเสธ ไม่เขียนอะไร (ไม่ตกไปลงบรรทัดรวม)", async () => {
    state.wb!.sheets = state.wb!.sheets.filter((s) => s.name !== "แจกแจงทรัพย์");
    const r = await armed(() => confirmOpeningImport(form({ fingerprint: "x", evidence: JSON.stringify(EVIDENCE) })));
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.issues?.some((i) => /ไม่พบชีท "แจกแจงทรัพย์"/.test(i.message))).toBe(true);
    expect(ctx.db.reimportCalls).toHaveLength(0);
    expect(ctx.db.writes).toEqual([]);
  });

  it("ยอดไม่กระทบ → ตัวอย่างปฏิเสธพร้อมช่องและผลต่าง · ไม่ถึงขั้นประกอบรายการ", async () => {
    setByCode(state.wb!, "BS-ธนากร", "1500", 3_000_001);
    setByCode(state.wb!, "BS-ธนากร", "3300", 1_820_001);
    const r = await preview("");
    expect(r.ok).toBe(false);
    if (!r.ok) {
      const i = r.issues.find((x) => x.sheet === "BS-ธนากร" && /1500/.test(x.message))!;
      expect(i.message).toMatch(/3,000,001/);
      expect(i.message).toMatch(/ต่างกัน 1/);
    }
    expect(ctx.db.reimportCalls).toHaveLength(0);
  });

  it("ตัวอย่าง: รายการทรัพย์รายชิ้น บอกว่าชิ้นไหนผูกทรัพย์เดิม ชิ้นไหนจะลงทะเบียนใหม่ · ไม่สิทธิ์ลงทะเบียน = blocker · ไม่เขียนอะไร", async () => {
    const ok1 = await preview("");
    expect(ok1.ok && ok1.assets.every((a) => a.existing !== null)).toBe(true);
    expect(ok1.ok && ok1.blockers).toEqual([]);

    unregisterItems();
    const noPerm = await preview("");
    expect(noPerm.ok).toBe(true);
    if (noPerm.ok) {
      expect(noPerm.assets).toHaveLength(3);
      expect(noPerm.assets.every((a) => a.existing === null)).toBe(true);
      expect(noPerm.blockers.some((b) => /ลงทะเบียนทรัพย์ตรงไม่ได้/.test(b.message))).toBe(true);
    }
    ctx.access.permissions = new Set(CAN_REGISTER) as never;
    const withPerm = await preview("");
    expect(withPerm.ok && withPerm.blockers).toEqual([]);
    expect(ctx.db.writes).toEqual([]);
    expect(ctx.db.applyDraftCalls).toEqual([]);
  });
});
