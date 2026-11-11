import "./mocks";
import { readFileSync } from "node:fs";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ctx, resetCtx } from "./ctx";
import { BANK, OWNER, referenceFixture } from "./fake-db";
import { previewOpeningImport } from "../import-opening";
import { FIXTURE, syncBreakdown } from "@/lib/db/import/__tests__/helpers";
import type { Workbook } from "@/lib/db/import/xlsx";
import { ROUTE_ACCESS, canOpen } from "@/lib/auth/routes";
import type { Permission } from "@/lib/auth/permissions";

/**
 * ไฟล์ตัวอย่างดิบ (.xlsx) ยังไม่มีชีท "แจกแจงทรัพย์" ซึ่งตอนนี้บังคับ — ตัวอ่านที่ถูกแทนที่นี้เติมให้จากยอดในชีท BS-*
 * เหมือน `loadFixture()` (ไฟล์ที่ไม่ใช่ Excel ยังพังที่ตัวอ่านจริงก่อนถึงขั้นเติม) · ใส่ hook ตอนรันเทสต์ ไม่ใช่ตอนโหลดโมดูล (กัน import วน)
 */
const hook = vi.hoisted(() => ({ patch: null as null | ((wb: Workbook) => Workbook) }));
vi.mock("@/lib/db/import/xlsx", async (orig) => {
  const real = await orig<typeof import("@/lib/db/import/xlsx")>();
  return { ...real, readWorkbook: (b: Uint8Array) => { const wb = real.readWorkbook(b); return hook.patch ? hook.patch(wb) : wb; } };
});

/** ผู้ถือ/บัญชีของไฟล์ตัวอย่าง: ใช้ชุดเดียวกับ fake-db แล้วเติมสามคนที่ไฟล์มีชีทให้ */
function referenceForFixture() {
  const ref = referenceFixture();
  const extra = (id: string, name: string) => ({ id, code: name, name, policy: "personal_flexible" as const, status: "active", color: null, sortOrder: 9 });
  ref.owners.push(extra("o-sudjit", "สุดจิตต์"), extra("o-thanawin", "ธนวินท์"), extra("o-benjaporn", "เบ็ญจพร"));
  ref.banks.find((b) => b.id === BANK.tk)!.name = "ธนากร - BBL 888";
  return { ok: true as const, ref };
}

const form = (file: Uint8Array | null, cutoff: string, name = "opening.xlsx") => {
  const fd = new FormData();
  if (file) fd.set("file", new File([file as BlobPart], name));
  fd.set("cutoff", cutoff);
  return fd;
};
const fixture = () => new Uint8Array(readFileSync(FIXTURE));

beforeEach(() => {
  hook.patch = syncBreakdown;
  resetCtx();
  ctx.reference = referenceForFixture();
  ctx.access.permissions = new Set(["settings.manage"]) as never;
});

describe("previewOpeningImport", () => {
  it("ไฟล์ตัวอย่างผ่าน: คืนใบของ 3 ผู้ถือ สมดุลทุกใบ และ **ไม่เขียนอะไรลง DB**", async () => {
    const r = await previewOpeningImport(form(fixture(), "30/09/2026"));
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.owners.map((o) => o.ownerName).sort()).toEqual(["SRI Corporation", "ธนากร", "สุธี"].sort());
    for (const o of r.owners) {
      const dr = o.lines.reduce((t, l) => t + l.debit, 0);
      const cr = o.lines.reduce((t, l) => t + l.credit, 0);
      expect(dr).toBe(cr);
    }
    expect(r.owners.find((o) => o.ownerName === "ธนากร")!.lines.filter((l) => l.code === "1100").map((l) => l.bank)).toEqual([
      "ธนากร - BBL 888",
      "ธนากร - SCB",
    ]);
    expect(ctx.db.rpcCalls).toHaveLength(0);
    expect(ctx.db.rows).toHaveLength(0);
  });

  it("เนื้อหาเดิมอัปโหลดซ้ำได้รหัสตรวจเดิม", async () => {
    const a = await previewOpeningImport(form(fixture(), "30/09/2026"));
    const b = await previewOpeningImport(form(fixture(), "30/09/2026"));
    expect(a.ok && b.ok && a.fingerprint === b.fingerprint).toBe(true);
  });

  it("วันตัดยอดต่างจากในไฟล์ → ปฏิเสธ พร้อมรายการจุดผิดต่อชีท ไม่มีการเขียน DB", async () => {
    const r = await previewOpeningImport(form(fixture(), "31/10/2026"));
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.issues.length).toBeGreaterThanOrEqual(6);
    expect(r.issues.every((i) => i.sheet.startsWith("BS-"))).toBe(true);
    expect(ctx.db.rpcCalls).toHaveLength(0);
  });

  it("ผู้ถือในระบบไม่ครบกับไฟล์ (ขาดสุดจิตต์) → ปฏิเสธระบุชีทที่ไม่รู้จัก", async () => {
    const ref = referenceForFixture();
    ref.ref.owners = ref.ref.owners.filter((o) => o.id !== "o-sudjit");
    ctx.reference = ref;
    const r = await previewOpeningImport(form(fixture(), "30/09/2026"));
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.issues.some((i) => i.sheet === "BS-สุดจิตต์" && /ไม่ตรงกับผู้ถือ/.test(i.message))).toBe(true);
  });

  it("บัญชีธนาคารถูกปิด → ปฏิเสธ", async () => {
    const ref = referenceForFixture();
    ref.ref.banks.find((b) => b.id === BANK.tk2)!.isActive = false;
    ctx.reference = ref;
    const r = await previewOpeningImport(form(fixture(), "30/09/2026"));
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.issues.some((i) => /ปิดใช้งาน/.test(i.message))).toBe(true);
  });

  it.each([
    ["ไม่ได้ล็อกอิน", () => (ctx.access.user = null), /เข้าสู่ระบบ/],
    ["ไม่มีสิทธิ์ตั้งค่าระบบ", () => (ctx.access.permissions = new Set(["txn.create"]) as never), /ไม่มีสิทธิ์/],
  ])("%s → ปฏิเสธก่อนอ่านไฟล์", async (_n, arrange, re) => {
    arrange();
    const r = await previewOpeningImport(form(fixture(), "30/09/2026"));
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.message).toMatch(re);
  });

  it.each([
    ["ไม่มีไฟล์", () => form(null, "30/09/2026"), /ยังไม่ได้เลือกไฟล์/],
    ["วันตัดยอดอ่านไม่ได้", () => form(fixture(), "เดือนหน้า"), /วันตัดยอดอ่านไม่ได้/],
    ["วันตัดยอดเป็น พ.ศ. (ไม่แปลงให้)", () => form(fixture(), "30/09/2569"), /วันตัดยอดอ่านไม่ได้/],
    ["นามสกุลไม่ใช่ .xlsx", () => form(fixture(), "30/09/2026", "opening.csv"), /\.xlsx/],
    ["ไฟล์ไม่ใช่ Excel จริง", () => form(new TextEncoder().encode("a,b,c\n1,2,3"), "30/09/2026"), /ไม่ใช่ไฟล์ Excel|เปิดไฟล์ไม่ได้/],
  ])("%s → ปฏิเสธด้วยข้อความอ่านออก", async (_n, make, re) => {
    const r = await previewOpeningImport(make());
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.message).toMatch(re);
  });

  it("โหลดข้อมูลอ้างอิงไม่ได้ → ปฏิเสธ ไม่เดาว่าผู้ถือคือใคร", async () => {
    ctx.reference = { ok: false, error: "db down" } as never;
    const r = await previewOpeningImport(form(fixture(), "30/09/2026"));
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.message).toMatch(/db down/);
  });
});

describe("เส้นทาง /import", () => {
  it("ต้องมีสิทธิ์ตั้งค่าระบบ · เมนูซ่อนจากคนที่ไม่มีสิทธิ์", () => {
    expect(ROUTE_ACCESS["/import"].allOf).toEqual(["settings.manage"]);
    expect(canOpen(new Set<Permission>(["txn.create"]), "/import")).toBe(false);
    expect(canOpen(new Set<Permission>(["settings.manage"]), "/import")).toBe(true);
  });
  it("owner id ของ fake-db ไม่ชนกับ id สมมติของชุดนำเข้า (กันเทสต์ผ่านเพราะ id ซ้ำ)", () => {
    expect(Object.values(OWNER)).not.toContain("o-sudjit");
  });
});
