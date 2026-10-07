import { describe, expect, it } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { PERMISSIONS, isPermission } from "../permissions";
import { diffPermissions, isInSync, permissionKeysFromMigration } from "../permission-check";
import { ROUTE_ACCESS, canOpen, hasAccess, routeFor } from "../routes";
import { checkSupabaseEnv } from "@/lib/supabase/env";

const migrationsDir = join(process.cwd(), "supabase", "migrations");
const permissionSql = readdirSync(migrationsDir)
  .filter((f) => f.endsWith(".sql"))
  .map((f) => readFileSync(join(migrationsDir, f), "utf8"))
  .filter((sql) => /insert\s+into\s+(?:sri_os\.)?permissions\s*\(/i.test(sql));

describe("permissions: union type ตรงกับ migration ที่ seed ตาราง permissions", () => {
  it("มี migration ที่ seed permissions อย่างน้อยหนึ่งไฟล์", () => {
    expect(permissionSql.length).toBeGreaterThan(0);
  });

  it("ทุกคีย์ใน migration อยู่ใน union และทุกคีย์ใน union อยู่ใน migration", () => {
    const keys = permissionSql.flatMap(permissionKeysFromMigration);
    const diff = diffPermissions(keys);
    expect(diff).toEqual({ missingInTs: [], missingInDb: [] });
  });

  it("มี 16 สิทธิ์ รวม asset.draft · asset.manage · asset.value · asset.assign_manager ที่สะกดตรง migration", () => {
    expect(PERMISSIONS).toHaveLength(16);
    for (const k of ["asset.draft", "asset.manage", "asset.value", "asset.assign_manager"]) {
      expect(isPermission(k)).toBe(true);
      expect(permissionSql.flatMap(permissionKeysFromMigration)).toContain(k);
    }
    // ชื่อใกล้เคียงที่สะกดผิดต้องไม่ผ่าน (ตัวพิมพ์ · จุด · ขีดล่าง)
    for (const bad of ["Asset.draft", "asset_manage", "asset.values", "asset.valuation"]) {
      expect(isPermission(bad)).toBe(false);
    }
  });

  it("ไม่ถือบล็อก role_permissions เป็นรายการสิทธิ์", () => {
    const sql = `insert into permissions (key, label) values
      ('a.one', 'x'),
      ('b.two', 'y')
    on conflict (key) do nothing;
    insert into role_permissions values
      ('c.three', true, false)
    on conflict do nothing;`;
    expect(permissionKeysFromMigration(sql)).toEqual(["a.one", "b.two"]);
  });

  it("migration ที่อ่านไม่ออกต้องพัง ไม่ใช่คืนรายการว่าง", () => {
    expect(() => permissionKeysFromMigration("select 1")).toThrow();
  });

  it("diff จับทั้งสองทิศ", () => {
    const d = diffPermissions([...PERMISSIONS, "new.thing"], PERMISSIONS);
    expect(d.missingInTs).toEqual(["new.thing"]);
    expect(isInSync(d)).toBe(false);
    const e = diffPermissions(PERMISSIONS.slice(1), PERMISSIONS);
    expect(e.missingInDb).toEqual([PERMISSIONS[0]]);
  });
});

describe("routes: กติกาหน้า → สิทธิ์", () => {
  const perms = (...p: (typeof PERMISSIONS)[number][]) => new Set(p);

  it("ทุกสิทธิ์ที่ตารางหน้าอ้างถึงอยู่ใน union", () => {
    for (const a of Object.values(ROUTE_ACCESS)) {
      for (const p of [...("anyOf" in a ? a.anyOf : []), ...("allOf" in a ? a.allOf : [])]) {
        expect(PERMISSIONS).toContain(p);
      }
    }
  });

  it("เลือก rule ที่ prefix ยาวที่สุด และไม่ตรงข้าม segment", () => {
    expect(routeFor("/settings/users")).toBe("/settings/users");
    expect(routeFor("/settings/banks")).toBe("/settings");
    expect(routeFor("/assets/abc")).toBe("/assets");
    expect(routeFor("/m/new")).toBe("/m/new");
    expect(routeFor("/menu")).toBeNull();
  });

  it("/balance ต้องมี portfolio.view_all — Manager (ไม่มี) เข้าไม่ได้ แต่เข้า /assets ได้", () => {
    const manager = perms("asset.view_assigned", "ledger.read", "txn.create", "ledger.approve", "draft.read_own");
    expect(canOpen(manager, "/balance")).toBe(false);
    expect(canOpen(manager, "/assets")).toBe(true);
    expect(canOpen(manager, "/settings/banks")).toBe(false);
  });

  it("/settings/users ต้องมีทั้ง settings.manage และ users.manage", () => {
    expect(canOpen(perms("settings.manage"), "/settings/users")).toBe(false);
    expect(canOpen(perms("users.manage"), "/settings/users")).toBe(false);
    expect(canOpen(perms("settings.manage", "users.manage"), "/settings/users")).toBe(true);
    expect(canOpen(perms("settings.manage"), "/settings/banks")).toBe(true);
  });

  it("/approvals: ledger.approve หรือ cash.confirm อย่างใดอย่างหนึ่ง", () => {
    expect(hasAccess(perms("cash.confirm"), ROUTE_ACCESS["/approvals"])).toBe(true);
    expect(hasAccess(perms("ledger.approve"), ROUTE_ACCESS["/approvals"])).toBe(true);
    expect(hasAccess(perms("txn.create"), ROUTE_ACCESS["/approvals"])).toBe(false);
  });

  it("ไม่มีสิทธิ์เลย (ไม่ได้ลงทะเบียน) = เข้าหน้าที่มี rule ไม่ได้สักหน้า", () => {
    for (const r of Object.keys(ROUTE_ACCESS)) expect(canOpen(new Set(), r)).toBe(false);
  });
});

describe("supabase env", () => {
  const jwt = (role: string) =>
    ["x", Buffer.from(JSON.stringify({ role })).toString("base64url"), "y"].join(".");

  it("ขาดค่า = บอกชื่อที่ขาด", () => {
    const r = checkSupabaseEnv(undefined, undefined);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.problems.join(" ")).toMatch(/URL[\s\S]*PUBLISHABLE_KEY/);
  });

  it("ปฏิเสธคีย์ secret และ JWT ที่ role = service_role", () => {
    expect(checkSupabaseEnv("https://x.supabase.co", "sb_secret_abc").ok).toBe(false);
    expect(checkSupabaseEnv("https://x.supabase.co", jwt("service_role")).ok).toBe(false);
  });

  it("รับ publishable key และ legacy anon", () => {
    expect(checkSupabaseEnv("https://x.supabase.co", "sb_publishable_abc").ok).toBe(true);
    expect(checkSupabaseEnv("https://x.supabase.co", jwt("anon")).ok).toBe(true);
  });
});
