import { beforeEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import path from "node:path";

/**
 * `getAccess()` ต้องถาม DB **ครั้งเดียว**ต่อ request — เดิมเรียก `fn_can` ทีละสิทธิ์ (16 ครั้ง) ก่อน render อะไรได้ ทำให้เว็บช้ามาก
 * เทสต์นี้นับการเรียก client จริง: ถ้าใครเพิ่มลูป/เรียกซ้ำกลับเข้ามา เทสต์แดงทันที
 *
 * คำขอเดียวนั้นคือ RPC `sri_os.fn_my_access(array[...])` ซึ่งคืนโปรไฟล์ + คำตอบของทุกสิทธิ์
 * **คำตอบมาจาก `fn_can` ที่เดียว** (fn_my_access → fn_can_many → fn_can) ฝั่งนี้ไม่ตัดสินสิทธิ์เอง
 * ก่อนหน้านี้เคยอ่าน `app_users → roles → role_permissions` เองในคำสั่งเดียว ซึ่งเร็วเท่ากัน
 * แต่เป็น **เกณฑ์สิทธิ์ที่สอง** (ดูเหตุผลใน access-row.ts) จึงถูกถอดออก
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
      rpc: async (fn: string) => {
        calls.rpc++;
        calls.table.push(fn);
        return { data: state.row, error: state.rowError };
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

/** คำตอบของ fn_my_access (DB ตอบ boolean มาให้แล้ว ฝั่งนี้ไม่คิดเอง) */
const row = (over: Record<string, unknown> = {}) => ({
  user_id: "u1",
  profile: { display_name: "ลูกพี่", role_key: "management", role_label: "ผู้บริหาร", is_active: true },
  permissions: { "ledger.approve": true, "settings.manage": true, "ledger.read": false },
  ...over,
});
const allowAll = (keys: readonly string[]) => Object.fromEntries(keys.map((k) => [k, true]));

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
  it("ผู้ใช้ปกติ: ตรวจตัวตน 1 ครั้ง + ถามสิทธิ์ 1 RPC (fn_my_access) · ไม่อ่านตารางสิทธิ์เอง · สิทธิ์ครบตามที่ DB ตอบ", async () => {
    const a = await getAccess();
    expect(calls).toMatchObject({ getUser: 1, from: 0, rpc: 1, table: ["fn_my_access"] });
    expect([...a.permissions].sort()).toEqual(["ledger.approve", "settings.manage"]);
    expect(a).toMatchObject({ error: null, user: { id: "u1" }, profile: { displayName: "ลูกพี่", roleKey: "management", roleLabel: "ผู้บริหาร" } });
  });

  it(`จำนวนการเรียก DB ไม่ขึ้นกับจำนวนสิทธิ์ (มี ${PERMISSIONS.length} สิทธิ์ แต่ยังเรียก DB ครั้งเดียว) — กันลูปต่อสิทธิ์กลับเข้ามา`, async () => {
    state.row = row({ permissions: allowAll(PERMISSIONS) });
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
    state.row = row({
      profile: { display_name: "ลูกพี่", role_key: "management", role_label: "ผู้บริหาร", is_active: false },
      permissions: allowAll(PERMISSIONS),   // ถึง DB พลาดตอบ true มา ฝั่งนี้ก็ต้องไม่ให้สิทธิ์
    });
    const off = await getAccess();
    expect(off.permissions.size).toBe(0);
    expect(off.profile).not.toBeNull();
    state.row = row({ profile: null, permissions: allowAll(PERMISSIONS) });
    const none = await getAccess();
    expect(none.permissions.size).toBe(0);
    expect(none.profile).toBeNull();
    expect(none.error).toBeNull();
  });

  it("สิทธิ์ที่ TS ไม่รู้จักถูกทิ้ง · ค่าที่ไม่ใช่ true ไม่ถือว่าอนุญาต · ไม่มี permissions เลย → ไม่มีสิทธิ์", async () => {
    state.row = row({ permissions: { "ledger.approve": true, "made.up": true, "txn.create": "true" } });
    expect([...(await getAccess()).permissions]).toEqual(["ledger.approve"]);
    state.row = row({ permissions: null });
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
  const src = () =>
    readFileSync(path.join(__dirname, "..", "session.ts"), "utf8")
      .replace(/\/\*[\s\S]*?\*\//g, "")
      .replace(/\/\/.*$/gm, "");

  it("ไม่มีลูปถาม DB · ยิง DB ครั้งเดียวในไฟล์ (RPC ตัวเดียว ไม่มี select ตาราง)", () => {
    expect(src()).not.toMatch(/\.map\s*\(\s*async/);
    expect(src()).not.toMatch(/Promise\.all/);
    expect((src().match(/supabase\.(rpc|from)\(/g) ?? []).length).toBe(1);
  });

  it("ไม่ไล่ตารางสิทธิ์เอง (กฎสิทธิ์ต้องอยู่ที่ fn_can ที่เดียว)", () => {
    expect(src()).not.toMatch(/role_permissions/);
    expect(src()).not.toMatch(/from\(\s*["']app_users["']\s*\)/);
  });
});
