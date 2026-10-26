/**
 * `getAccess()` อ่านสิทธิ์จากตารางในคำสั่งเดียว (แทน `fn_can` 16 ครั้ง) — เทสต์นี้พิสูจน์กับ Postgres จริง (role authenticated · RLS บังคับ)
 * ว่าได้ชุดสิทธิ์ **เท่ากับ `fn_can` ทุกสิทธิ์ ทุกระดับ**: ผู้ใช้ active ทุกระดับ · ผู้ใช้ปิดใช้งาน · ผู้ใช้ที่ไม่ได้ลงทะเบียน
 * ถ้า RLS ซ่อนแถวของตัวเอง หรือใครแก้ความหมายของ `fn_can` โดยไม่แก้ฝั่งนี้ → เทสต์แดง
 */
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, pgAvailable, type TestDb } from "@/lib/db/import/__tests__/pg-harness";
import { ACCESS_SELECT, accessFromRow, type AccessRow } from "../access-row";
import { PERMISSIONS } from "../permissions";

const uid = (n: number) => `0000000c-0000-4000-8000-${String(n).padStart(12, "0")}`;

describe.skipIf(!pgAvailable)("สิทธิ์จากตาราง = fn_can ของ DB", { timeout: 120_000 }, () => {
  let db: TestDb;
  const roles: string[] = [];

  /** ผลของคำสั่งเดียวกับที่ getAccess() ส่ง (รูป embed ของ PostgREST) — รันในฐานะผู้ใช้นั้น ผ่าน RLS */
  const rowFor = (id: string): AccessRow | null => {
    const out = db.as(
      id,
      `select row_to_json(t) from (
         select u.display_name, u.role, u.is_active,
                (select row_to_json(r) from (
                   select ro.label, (select coalesce(json_agg(json_build_object('permission_key', rp.permission_key)), '[]'::json)
                                       from sri_os.role_permissions rp where rp.role_key = ro.key) as role_permissions
                     from sri_os.roles ro where ro.key = u.role) r) as roles
           from sri_os.app_users u where u.id = '${id}') t;`
    );
    return out ? (JSON.parse(out) as AccessRow) : null;
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

  it("ทุกระดับที่ active: ชุดสิทธิ์จากตาราง = ชุดที่ fn_can ตอบ (และมีอย่างน้อยหนึ่งระดับที่ได้สิทธิ์ ไม่ใช่ว่างทั้งคู่)", () => {
    expect(roles.length).toBeGreaterThanOrEqual(4);
    let nonEmpty = 0;
    roles.forEach((r, i) => {
      const id = uid(i + 1);
      const mine = [...accessFromRow(rowFor(id)).permissions].sort();
      expect(mine, `ระดับ ${r}`).toEqual(fnCan(id));
      if (mine.length) nonEmpty++;
    });
    expect(nonEmpty).toBeGreaterThan(0);
  });

  it("ผู้ใช้ปิดใช้งาน → ทั้งสองทางว่าง · ผู้ใช้ที่ไม่ได้ลงทะเบียน → ทั้งสองทางว่างและไม่มี profile", () => {
    const off = accessFromRow(rowFor(uid(90)));
    expect(off.permissions.size).toBe(0);
    expect(fnCan(uid(90))).toEqual([]);
    expect(off.profile).not.toBeNull();
    const none = accessFromRow(rowFor(uid(91)));
    expect(none.permissions.size).toBe(0);
    expect(none.profile).toBeNull();
    expect(fnCan(uid(91))).toEqual([]);
  });

  it("แถวที่ DB ส่งมาตรงกับ select ที่ใช้จริง (กันเปลี่ยน ACCESS_SELECT แล้วเทสต์นี้ไม่รู้)", () => {
    expect(ACCESS_SELECT).toBe("display_name, role, is_active, roles(label, role_permissions(permission_key))");
  });

  it("ถอดสิทธิ์ของระดับหนึ่งใน role_permissions → ทั้งสองทางเปลี่ยนพร้อมกัน (อ่านจากตารางจริง ไม่มีสำเนาฝั่งโค้ด)", () => {
    const i = roles.indexOf("manager");
    const id = uid(i + 1);
    const before = fnCan(id);
    expect(before).toContain("ledger.approve");
    db.su(`delete from sri_os.role_permissions where role_key = 'manager' and permission_key = 'ledger.approve';`);
    const after = [...accessFromRow(rowFor(id)).permissions].sort();
    expect(after).toEqual(fnCan(id));
    expect(after).not.toContain("ledger.approve");
  });
});
