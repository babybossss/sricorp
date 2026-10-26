import { beforeEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import path from "node:path";

/**
 * `getAccess()` ต้องถาม DB ครั้งเดียวต่อ request — เดิมเรียก `fn_can` ทีละสิทธิ์ (16 ครั้ง) ก่อน render อะไรได้ ทำให้เว็บช้ามาก
 * เทสต์นี้นับการเรียก client จริง: ถ้าใครเพิ่มลูป/เรียกซ้ำกลับเข้ามา เทสต์แดงทันที
 */
const calls = vi.hoisted(() => ({ getUser: 0, from: 0, rpc: 0, table: [] as string[] }));
const state = vi.hoisted(() => ({
  user: { id: "u1", email: "a@b.c" } as { id: string; email: string } | null,
  userError: null as unknown,
  row: null as unknown,
  rowError: null as { message: string } | null,
  createError: null as Error | null,
}));

vi.mock("next/server", () => ({ connection: async () => {} }));
vi.mock("react", async (orig) => ({ ...(await orig<typeof import("react")>()), cache: <T,>(fn: T) => fn }));
vi.mock("@/lib/supabase/server", () => ({
  createClient: async () => {
    if (state.createError) throw state.createError;
    return {
      auth: {
        getUser: async () => {
          calls.getUser++;
          return { data: { user: state.user }, error: state.userError };
        },
      },
      rpc: async () => {
        calls.rpc++;
        return { data: true, error: null };
      },
      from: (table: string) => {
        calls.from++;
        calls.table.push(table);
        const q = {
          select: () => q,
          eq: () => q,
          maybeSingle: async () => ({ data: state.row, error: state.rowError }),
        };
        return q;
      },
    };
  },
}));

import { getAccess } from "../session";
import { PERMISSIONS } from "../permissions";

const row = (over: Record<string, unknown> = {}) => ({
  display_name: "ลูกพี่",
  role: "management",
  is_active: true,
  roles: { label: "ผู้บริหาร", role_permissions: [{ permission_key: "ledger.approve" }, { permission_key: "settings.manage" }] },
  ...over,
});

beforeEach(() => {
  calls.getUser = calls.from = calls.rpc = 0;
  calls.table = [];
  state.user = { id: "u1", email: "a@b.c" };
  state.userError = null;
  state.row = row();
  state.rowError = null;
  state.createError = null;
});

describe("getAccess · ถาม DB ครั้งเดียว", () => {
  it("ผู้ใช้ปกติ: ตรวจตัวตน 1 ครั้ง + อ่านสิทธิ์ 1 query (ตาราง app_users) · ไม่เรียก fn_can เลย · สิทธิ์ครบตามระดับ", async () => {
    const a = await getAccess();
    expect(calls).toMatchObject({ getUser: 1, from: 1, rpc: 0, table: ["app_users"] });
    expect([...a.permissions].sort()).toEqual(["ledger.approve", "settings.manage"]);
    expect(a).toMatchObject({ error: null, user: { id: "u1" }, profile: { displayName: "ลูกพี่", roleKey: "management", roleLabel: "ผู้บริหาร" } });
  });

  it(`จำนวนการเรียก DB ไม่ขึ้นกับจำนวนสิทธิ์ (มี ${PERMISSIONS.length} สิทธิ์ แต่ยังเรียก DB ครั้งเดียว) — กันลูปต่อสิทธิ์กลับเข้ามา`, async () => {
    state.row = row({ roles: { label: "x", role_permissions: PERMISSIONS.map((p) => ({ permission_key: p })) } });
    const a = await getAccess();
    expect(a.permissions.size).toBe(PERMISSIONS.length);
    expect(calls.from + calls.rpc).toBe(1);
  });

  it("ล้มเหลวก็เรียกครั้งเดียว: schema ยังไม่ expose → สิทธิ์ว่าง + บอกเหตุผล (ไม่ใช่ 16 ครั้งที่ล้มทั้งหมดเหมือนเดิม)", async () => {
    state.rowError = { message: "Invalid schema: sri_os" };
    const a = await getAccess();
    expect(calls.from + calls.rpc).toBe(1);
    expect(a.permissions.size).toBe(0);
    expect(a.profile).toBeNull();
    expect(a.error).toMatch(/ตรวจสิทธิ์กับฐานข้อมูลไม่สำเร็จ.*Invalid schema/);
  });

  it("ผู้ใช้ปิดใช้งาน → ไม่มีสิทธิ์ใดเลย (แต่ยังมี profile ให้หน้าจอบอก) · ไม่ลงทะเบียน → ไม่มีทั้งสิทธิ์และ profile", async () => {
    state.row = row({ is_active: false });
    const off = await getAccess();
    expect(off.permissions.size).toBe(0);
    expect(off.profile).not.toBeNull();
    state.row = null;
    const none = await getAccess();
    expect(none.permissions.size).toBe(0);
    expect(none.profile).toBeNull();
    expect(none.error).toBeNull();
  });

  it("สิทธิ์ที่ TS ไม่รู้จักถูกทิ้ง · ระดับอ่านไม่ได้ (roles = null) → ไม่มีสิทธิ์", async () => {
    state.row = row({ roles: { label: "x", role_permissions: [{ permission_key: "ledger.approve" }, { permission_key: "made.up" }] } });
    expect([...(await getAccess()).permissions]).toEqual(["ledger.approve"]);
    state.row = row({ roles: null });
    expect((await getAccess()).permissions.size).toBe(0);
  });

  it("ไม่ล็อกอิน → ไม่ถาม DB เรื่องสิทธิ์เลย · สร้าง client ไม่ได้ → ไม่มีสิทธิ์พร้อมเหตุผล", async () => {
    state.user = null;
    const a = await getAccess();
    expect(calls.from + calls.rpc).toBe(0);
    expect(a.user).toBeNull();
    state.createError = new Error("env missing");
    expect((await getAccess()).error).toBe("env missing");
  });
});

describe("session.ts · ไม่มีการเรียก DB ในลูป (ด่านซ้อนกับเทสต์นับ)", () => {
  it("ไม่มี .rpc( และไม่มี map(async …) ใน session.ts", () => {
    const src = readFileSync(path.join(__dirname, "..", "session.ts"), "utf8").replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
    expect(src).not.toMatch(/\.rpc\s*\(/);
    expect(src).not.toMatch(/\.map\s*\(\s*async/);
    expect(src).not.toMatch(/Promise\.all/);
  });
});
