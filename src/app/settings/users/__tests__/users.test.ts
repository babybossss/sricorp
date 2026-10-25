import { env, mockFactories, USERS, VIEW, OWNER, fresh, as } from "@/lib/db/__tests__/assets-test-env";
import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("@/lib/supabase/server", () => mockFactories.supabase());
vi.mock("@/lib/auth/session", () => mockFactories.session());
vi.mock("@/lib/db/reference", () => mockFactories.reference());
vi.mock("next/cache", () => mockFactories.cache());

import { updateUserAccess } from "../actions";
import { loadUsers } from "../users-data";

/** ผู้ใช้จริงจาก app_users — สิทธิ์ให้ RLS ตัดสิน · การเปลี่ยนระดับเขียนจริงและมีกันล็อกตัวเอง */

const user = (id: string) => env.db.tables.app_users.find((u) => u.id === id)!;
const load = async () => {
  const r = await loadUsers();
  if (!r.ok) throw new Error(r.error);
  return r;
};

beforeEach(() => {
  fresh();
  as(VIEW.superAdmin());
});

describe("รายชื่อผู้ใช้ (RLS users_read)", () => {
  it("ผู้จัดการผู้ใช้เห็นทุกคน · ระดับสิทธิ์มาจากตาราง roles เรียงตามลำดับ", async () => {
    const r = await load();
    expect(r.users.map((u) => u.displayName)).toEqual(["ผู้ดูแล", "ผู้จัดการ", "พนักงาน", "คนอื่น"]);
    expect(r.roles.map((x) => x.key)).toEqual(["super_admin", "management", "manager", "staff"]);
  });

  it("คนทั่วไปเห็นแค่ตัวเอง (ไม่กรองใน TS — DB คืนมาเท่านี้)", async () => {
    as(VIEW.staff());
    const r = await load();
    expect(r.users.map((u) => u.id)).toEqual([USERS.staff]);
  });

  it("ขอบเขตผู้ถือของผู้ใช้มาจาก user_owner_access", async () => {
    env.db.tables.user_owner_access.push({ user_id: USERS.manager, owner_id: OWNER.tk }, { user_id: USERS.manager, owner_id: OWNER.corp });
    const r = await load();
    expect(r.users.find((u) => u.id === USERS.manager)!.ownerIds).toEqual([OWNER.tk, OWNER.corp]);
    expect(r.users.find((u) => u.id === USERS.staff)!.ownerIds).toEqual([]);
  });

  it("เกิน 1,000 คน (PostgREST ตัดเงียบ) ยังครบ", async () => {
    for (let i = 0; i < 1_050; i++) env.db.tables.app_users.push({ id: `bulk-${i}`, email: `b${i}@x`, display_name: `b${i}`, role: "staff", is_active: true, created_at: `2027-01-01T00:00:${String(i % 60).padStart(2, "0")}Z` });
    expect((await load()).users).toHaveLength(1_054);
  });

  it("อ่านไม่ได้ → ล้มทั้งหน้า ไม่แสดงรายชื่อครึ่งเดียว", async () => {
    env.db.client.from = (() => { throw new Error("down"); }) as never;
    await expect(loadUsers()).rejects.toThrow();
  });
});

describe("เปลี่ยนระดับ / เปิด-ปิดผู้ใช้", () => {
  it("Super Admin เปลี่ยนระดับของคนอื่นได้ · เขียนจริง", async () => {
    const out = await updateUserAccess({ userId: USERS.staff, role: "manager", isActive: true });
    expect(out.ok).toBe(true);
    expect(user(USERS.staff).role).toBe("manager");
  });

  it("ปิดใช้งาน = is_active false (ไม่ลบแถว)", async () => {
    const before = env.db.tables.app_users.length;
    expect((await updateUserAccess({ userId: USERS.other, role: "staff", isActive: false })).ok).toBe(true);
    expect(user(USERS.other).is_active).toBe(false);
    expect(env.db.tables.app_users).toHaveLength(before);
  });

  it("ผู้ไม่มี users.manage แก้ไม่ได้ — DB ไม่แก้ให้ ข้อมูลไม่เปลี่ยน", async () => {
    as(VIEW.manager());
    // Manager มองเห็นแค่ตัวเอง จึงเห็นแถวคนอื่นไม่ได้ → ไม่พบ · และแก้ตัวเองก็ไม่ได้
    expect((await updateUserAccess({ userId: USERS.staff, role: "management", isActive: true })).ok).toBe(false);
    expect(user(USERS.staff).role).toBe("staff");
    as({ ...VIEW.management(), id: USERS.manager }); // เห็นทุกคน (owner.view_all) แต่ไม่มี users.manage
    const denied = await updateUserAccess({ userId: USERS.staff, role: "management", isActive: true });
    expect(denied.ok).toBe(false);
    expect(user(USERS.staff).role).toBe("staff");
  });

  it("แก้ระดับ/ปิดบัญชีตัวเองไม่ได้ (กันล็อกตัวเอง)", async () => {
    env.db.tables.app_users.find((u) => u.id === USERS.admin)!.role = "management"; // ไม่ใช่ super_admin คนสุดท้ายจะได้ชนกฎข้อนี้ล้วนๆ
    expect((await updateUserAccess({ userId: USERS.admin, role: "staff", isActive: true })).ok).toBe(false);
    expect((await updateUserAccess({ userId: USERS.admin, role: "management", isActive: false })).ok).toBe(false);
    expect(user(USERS.admin)).toMatchObject({ role: "management", is_active: true });
  });

  it("ลดระดับ/ปิด Super Admin คนสุดท้ายไม่ได้ · มีสองคนแล้วทำได้", async () => {
    env.db.tables.app_users.push({ id: "sa2", email: "sa2@x", display_name: "SA2", role: "super_admin", is_active: true, created_at: "2026-02-01T00:00:00Z" });
    // ผู้ลงมือเป็นคนที่สาม (super_admin ผ่านสิทธิ์ แต่ role ในแถวเป็น management เพื่อให้ SA2 กับ admin ยังเหลือ 1 ตอนลด)
    env.db.tables.app_users.find((u) => u.id === USERS.admin)!.role = "management";
    as({ ...VIEW.superAdmin(), id: USERS.admin });
    const last = await updateUserAccess({ userId: "sa2", role: "staff", isActive: true });
    expect(last.ok).toBe(false);
    if (!last.ok) expect(last.message).toContain("คนสุดท้าย");
    expect(user("sa2").role).toBe("super_admin");
    env.db.tables.app_users.push({ id: "sa3", email: "sa3@x", display_name: "SA3", role: "super_admin", is_active: true, created_at: "2026-02-02T00:00:00Z" });
    expect((await updateUserAccess({ userId: "sa2", role: "staff", isActive: true })).ok).toBe(true);
  });

  it("ข้อมูลไม่ครบ/ระดับที่ไม่มี/ไม่มีอะไรเปลี่ยน/ผู้ใช้ที่ไม่มี → ปฏิเสธก่อนเขียน", async () => {
    const w = env.db.writes.length;
    for (const bad of [
      { userId: "", role: "staff", isActive: true },
      { userId: USERS.staff, role: "", isActive: true },
      { userId: USERS.staff, role: "godmode", isActive: true },
      { userId: USERS.staff, role: "staff", isActive: true },
      { userId: "ghost", role: "manager", isActive: true },
      { userId: USERS.staff, role: "manager", isActive: undefined as never },
    ])
      expect((await updateUserAccess(bad)).ok).toBe(false);
    expect(env.db.writes.length).toBe(w);
  });
});
