/**
 * `getAccess()` ถาม DB **คำขอเดียว** (`sri_os.fn_my_access`) แล้วอ่าน boolean ที่ DB ตอบ
 *
 * เทสต์นี้คุมสองเรื่องที่ต่างกัน และต้องมีทั้งคู่:
 *
 *  (1) **เชิงโครงสร้าง** — ฝั่ง TypeScript ต้องไม่มีเกณฑ์สิทธิ์ของตัวเอง
 *      (ห้ามเอ่ย `role_permissions` / `roles(` / ชื่อระดับ) · ของเดิมเคยไล่
 *      `app_users → roles → role_permissions` เองซึ่งคือ **กฎสองที่** และเป็น
 *      ความผิดพลาดที่คู่มือห้ามไว้ตรงๆ · ข้อนี้แดงทันทีถ้าใครเอากลับมา
 *      โดยไม่ต้องรอให้ผลลัพธ์เพี้ยนก่อน
 *
 *  (2) **เชิงพฤติกรรม** — คำตอบของ `fn_my_access` ต้องเท่ากับ `fn_can` ทุกสิทธิ์
 *      ทุกระดับ บน Postgres จริง ในฐานะ role `authenticated` (RLS บังคับ)
 *      รวมเคส: ผู้ใช้ปิดใช้งาน · ผู้ใช้ที่ไม่ได้ลงทะเบียน · ไม่ล็อกอิน
 */
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import path from "node:path";
import { createTestDb, pgAvailable, type TestDb } from "@/lib/db/import/__tests__/pg-harness";
import { ACCESS_RPC, accessFromPayload, type AccessPayload } from "../access-row";
import { PERMISSIONS } from "../permissions";

const uid = (n: number) => `0000000c-0000-4000-8000-${String(n).padStart(12, "0")}`;
const SRC = (f: string) => readFileSync(path.join(process.cwd(), "src/lib/auth", f), "utf8");
/** ตัดคอมเมนต์ออกก่อนค้นหา — คำอธิบาย ("ห้ามอ่าน role_permissions") ไม่ใช่การใช้งานจริง */
const code = (f: string) =>
  SRC(f)
    .replace(/\/\*[\s\S]*?\*\//g, " ")
    .replace(/\/\/[^\n]*/g, " ");

describe("ฝั่ง TypeScript ต้องไม่มีเกณฑ์สิทธิ์ของตัวเอง (กันกฎสองที่กลับมา)", () => {
  for (const file of ["access-row.ts", "session.ts", "permission-check.ts", "gate.tsx", "actions.ts"]) {
    it(`${file} ไม่ไล่ตารางสิทธิ์เอง`, () => {
      const src = code(file);
      expect(src, `${file} อ่าน role_permissions เอง = เกณฑ์สิทธิ์ที่สอง`).not.toMatch(/role_permissions/);
      expect(src, `${file} embed roles(...) = เกณฑ์สิทธิ์ที่สอง`).not.toMatch(/roles\s*\(/);
      // ห้ามตัดสินจาก "ชื่อระดับ" (D-073) — สิทธิ์มาจากตารางสิทธิ์เท่านั้น
      expect(src, `${file} ตัดสินจากชื่อระดับ`).not.toMatch(/["'](super_admin|management|manager|staff)["']/);
    });
  }

  it("getAccess() เรียก RPC ตัวเดียว และไม่ select app_users เอง", () => {
    const src = code("session.ts");
    expect(src).toMatch(new RegExp(`rpc\\(\\s*ACCESS_RPC`));
    expect(src, "ยังอ่านตาราง app_users เอง (โปรไฟล์ต้องมาจาก fn_my_access ในคำขอเดียวกัน)").not.toMatch(
      /from\(\s*["']app_users["']\s*\)/
    );
    // **หนึ่ง round trip**: ต้องมีการยิง DB ครั้งเดียวในฟังก์ชันนี้ (นอกจาก auth.getUser())
    const calls = (src.match(/supabase\.(rpc|from)\(/g) ?? []).length;
    expect(calls, `ยิง DB ${calls} ครั้งต่อหนึ่งหน้า — ต้องเป็น 1`).toBe(1);
  });

  it("ชื่อ RPC ตรงกับฟังก์ชันที่ migration สร้างไว้จริง", () => {
    const sql = readFileSync(
      path.join(process.cwd(), "supabase/migrations/20261025000023_fn_my_access.sql"),
      "utf8"
    );
    expect(sql).toMatch(new RegExp(`create or replace function ${ACCESS_RPC}\\(`));
  });
});

describe("ตัวแปลงคำตอบ: ล้มเหลว = ไม่มีสิทธิ์ (fail closed)", () => {
  const full = (over: Partial<AccessPayload> = {}): AccessPayload => ({
    user_id: uid(1),
    profile: { display_name: "ก", role_key: "management", role_label: "ผู้บริหาร", is_active: true },
    permissions: Object.fromEntries(PERMISSIONS.map((p) => [p, true])),
    ...over,
  });

  it("ไม่มีคำตอบ (null/undefined) → ไม่มีสิทธิ์และไม่มีโปรไฟล์", () => {
    for (const v of [null, undefined]) {
      const a = accessFromPayload(v);
      expect(a.permissions.size).toBe(0);
      expect(a.profile).toBeNull();
    }
  });

  it("ไม่มีแถวใน app_users (profile = null) → ไม่มีสิทธิ์", () => {
    const a = accessFromPayload(full({ profile: null }));
    expect(a.profile).toBeNull();
    expect(a.permissions.size).toBe(0);
  });

  it("is_active = false → มีโปรไฟล์ไว้อธิบาย แต่ไม่มีสิทธิ์เลย", () => {
    const a = accessFromPayload(
      full({ profile: { display_name: "ก", role_key: "management", role_label: null, is_active: false } })
    );
    expect(a.profile?.displayName).toBe("ก");
    expect(a.permissions.size).toBe(0);
  });

  it("รับเฉพาะ true จริงๆ · ชื่อที่ไม่รู้จักถูกทิ้ง", () => {
    const a = accessFromPayload(
      full({
        permissions: {
          "ledger.read": true,
          "ledger.approve": false,
          "txn.create": "true" as unknown as boolean,
          "cash.confirm": 1 as unknown as boolean,
          "users.manage": null as unknown as boolean,
          "สิทธิ์ที่ไม่มีอยู่จริง": true,
        },
      })
    );
    expect([...a.permissions]).toEqual(["ledger.read"]);
  });

  it("permissions หายไปทั้งก้อน → ไม่มีสิทธิ์ (ไม่ใช่ทุกสิทธิ์)", () => {
    expect(accessFromPayload(full({ permissions: null })).permissions.size).toBe(0);
  });
});

describe.skipIf(!pgAvailable)("fn_my_access = fn_can ทุกระดับ ทุกสิทธิ์ (Postgres จริง)", { timeout: 120_000 }, () => {
  let db: TestDb;
  const roles: string[] = [];

  /** คำตอบของคำขอเดียวกับที่ getAccess() ยิง — รันในฐานะผู้ใช้นั้น ผ่าน RLS */
  const payloadFor = (id: string): AccessPayload | null => {
    const list = PERMISSIONS.map((p) => `'${p}'`).join(", ");
    const out = db.as(id, `select sri_os.fn_my_access(array[${list}]::text[]);`);
    return out ? (JSON.parse(out) as AccessPayload) : null;
  };
  const fnCan = (id: string) =>
    PERMISSIONS.filter((p) => db.as(id, `select sri_os.fn_can('${p}');`) === "t").sort();

  beforeAll(() => {
    db = createTestDb();
    roles.push(...db.rows<{ key: string }>("select key from sri_os.roles order by key").map((r) => r.key));
    roles.forEach((r, i) => {
      db.su(`insert into auth.users(id) values ('${uid(i + 1)}');
             insert into sri_os.app_users(id, email, display_name, role, is_active) values ('${uid(i + 1)}', 'r${i}@local', 'ผู้ใช้ ${r}', '${r}', true);`);
    });
    // ผู้ใช้ปิดใช้งาน (ระดับสูงสุดก็ตาม) และผู้ใช้ที่ล็อกอินได้แต่ไม่ได้ลงทะเบียน
    db.su(`insert into auth.users(id) values ('${uid(90)}'), ('${uid(91)}');
           insert into sri_os.app_users(id, email, display_name, role, is_active) values ('${uid(90)}', 'off@local', 'ปิดใช้งาน', '${roles[0]}', false);`);
  }, 240_000);

  afterAll(() => db?.drop());

  it("ทุกระดับที่ active: ชุดสิทธิ์จาก RPC = ชุดที่ fn_can ตอบ (และต้องมีระดับที่ได้สิทธิ์ ไม่ใช่ว่างทั้งคู่)", () => {
    expect(roles.length).toBeGreaterThanOrEqual(4);
    let nonEmpty = 0;
    roles.forEach((r, i) => {
      const id = uid(i + 1);
      const mine = [...accessFromPayload(payloadFor(id)).permissions].sort();
      expect(mine, `ระดับ ${r}`).toEqual(fnCan(id));
      if (mine.length) nonEmpty++;
    });
    expect(nonEmpty).toBeGreaterThan(0);
  });

  it("RPC ตอบครบทุกสิทธิ์ที่ถาม (ตัวที่หายไปจะทำให้ฝั่งแอปต้องเดา)", () => {
    const p = payloadFor(uid(1));
    expect(Object.keys(p?.permissions ?? {}).sort()).toEqual([...PERMISSIONS].sort());
  });

  it("ผู้ใช้ปิดใช้งาน → ไม่มีสิทธิ์แต่ยังมีโปรไฟล์ · ผู้ใช้ที่ไม่ได้ลงทะเบียน → ไม่มีทั้งสองอย่าง", () => {
    const off = accessFromPayload(payloadFor(uid(90)));
    expect(off.permissions.size).toBe(0);
    expect(fnCan(uid(90))).toEqual([]);
    expect(off.profile).not.toBeNull();

    const none = accessFromPayload(payloadFor(uid(91)));
    expect(none.permissions.size).toBe(0);
    expect(none.profile).toBeNull();
    expect(fnCan(uid(91))).toEqual([]);
  });

  it("ไม่ล็อกอิน → ไม่มีสิทธิ์และไม่มีโปรไฟล์", () => {
    const list = PERMISSIONS.map((p) => `'${p}'`).join(", ");
    const out = db.as("", `select sri_os.fn_my_access(array[${list}]::text[]);`);
    const a = accessFromPayload(out ? (JSON.parse(out) as AccessPayload) : null);
    expect(a.permissions.size).toBe(0);
    expect(a.profile).toBeNull();
  });

  it("โปรไฟล์ของคนอื่นถามไม่ได้ (RPC เป็น invoker · RLS ของ app_users ทำงาน)", () => {
    const mine = payloadFor(uid(1));
    expect(mine?.profile?.role_key).toBe(roles[0]);
    // ผู้ใช้ที่สองต้องได้โปรไฟล์ของตัวเอง ไม่ใช่ของคนแรก
    expect(payloadFor(uid(2))?.profile?.role_key).toBe(roles[1]);
  });

  it("ถอดสิทธิ์ของระดับหนึ่งใน role_permissions → ทั้งสองทางเปลี่ยนพร้อมกัน (ไม่มีสำเนาฝั่งโค้ด)", () => {
    const i = roles.indexOf("manager");
    const id = uid(i + 1);
    expect(fnCan(id)).toContain("ledger.approve");
    db.su(`delete from sri_os.role_permissions where role_key = 'manager' and permission_key = 'ledger.approve';`);
    const after = [...accessFromPayload(payloadFor(id)).permissions].sort();
    expect(after).toEqual(fnCan(id));
    expect(after).not.toContain("ledger.approve");
  });
});
