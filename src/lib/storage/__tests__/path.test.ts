import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ALLOWED_TYPES, MAX_ATTACHMENT_BYTES } from "../config";
import { ATTACHMENT_REF_RE, buildObjectPath, isAttachmentRef, isUuid, parseAttachmentRef, PathError, safeDisplayName } from "../path";
import { OTHER_OWNER, OWNER, USER } from "./helpers";

const WEIRD_NAMES = [
  "../../etc/passwd",
  "..\\..\\windows\\system32",
  "/absolute/path.jpg",
  "a".repeat(5000) + ".jpg",
  "สลิปโอนเงิน ธ.กสิกร 12/10/2569.jpg",
  "emoji 🧾💸.png",
  "null\u0000byte.jpg",
  "new\nline.jpg",
  "rtl‮gnp.exe",
  "%2e%2e%2f",
  "con.jpg",
  "",
  "   ",
  ".htaccess",
  "name;rm -rf.jpg",
  "'; drop table transactions;--.jpg",
];

describe("path ของไฟล์ — ชื่อที่ผู้ใช้ตั้งไม่เคยเป็นส่วนของ path", () => {
  it("ชื่อแปลกทุกแบบ: path ที่ได้เป็นรูปแบบเดียว ปลอดภัย และไม่มีเศษของชื่อ", () => {
    for (const name of WEIRD_NAMES) {
      // buildObjectPath ไม่รับชื่อไฟล์เลย — ทดสอบว่าไม่มีทางรั่วเข้าไปได้
      const p = buildObjectPath({ ownerId: OWNER, uploaderId: USER, ext: "jpg" });
      expect(p).toMatch(ATTACHMENT_REF_RE);
      expect(p.includes("..")).toBe(false);
      expect(p.split("/")).toHaveLength(3);
      expect(p.length).toBeLessThan(140);
      expect(name.length === 0 || !p.includes(name)).toBe(true);
    }
    expect(buildObjectPath.length).toBe(1); // รับ object เดียว ไม่มีช่องชื่อไฟล์
  });

  it("ชื่อซ้ำ/อัปโหลดพร้อมกัน ไม่ชนกัน (5,000 ครั้ง ไม่ซ้ำ)", () => {
    const s = new Set<string>();
    for (let i = 0; i < 5000; i++) s.add(buildObjectPath({ ownerId: OWNER, uploaderId: USER, ext: "png" }));
    expect(s.size).toBe(5000);
  });

  it("owner/uploader ต้องเป็น uuid — ไม่งั้นโยน PathError (กันสอดไส้ ../ ผ่านช่อง owner)", () => {
    for (const bad of ["../x", "", "not-a-uuid", `${OWNER}/..`, OWNER + "\n", "a1b2c3d4-1111-4111-8111-aabbccddeefG"]) {
      expect(() => buildObjectPath({ ownerId: bad, uploaderId: USER, ext: "jpg" })).toThrow(PathError);
      expect(() => buildObjectPath({ ownerId: OWNER, uploaderId: bad, ext: "jpg" })).toThrow(PathError);
    }
  });

  it("นามสกุลนอกรายการไม่ได้", () => {
    expect(() => buildObjectPath({ ownerId: OWNER, uploaderId: USER, ext: "exe" as never })).toThrow(PathError);
    expect(() => buildObjectPath({ ownerId: OWNER, uploaderId: USER, ext: "svg" as never })).toThrow(PathError);
  });

  it("uuid ตัวพิมพ์ใหญ่ถูกแปลงเป็นเล็ก (policy เทียบข้อความตรงกับ auth.uid()::text)", () => {
    const p = buildObjectPath({ ownerId: OWNER.toUpperCase(), uploaderId: USER.toUpperCase(), ext: "pdf" });
    expect(p.startsWith(`${OWNER}/${USER}/`)).toBe(true);
  });

  it("parse ย้อนกลับได้ · ref ที่หน้าตาไม่ใช่ path ของเรา = ไม่ใช่ไฟล์จริง", () => {
    const p = buildObjectPath({ ownerId: OWNER, uploaderId: USER, ext: "heic" });
    expect(parseAttachmentRef(p)).toMatchObject({ ownerId: OWNER, uploaderId: USER, ext: "heic" });
    for (const fake of ["สลิป.jpg", "slip.jpg", "", "../x", `${OTHER_OWNER}/x.jpg`, `${p}/..`, `${p}\n`, null, undefined, 42, {}]) {
      expect(isAttachmentRef(fake)).toBe(false);
    }
  });

  it("isUuid", () => {
    expect(isUuid(OWNER)).toBe(true);
    expect(isUuid(OWNER.toUpperCase())).toBe(false);
    expect(isUuid(undefined)).toBe(false);
  });
});

describe("safeDisplayName — ชื่อสำหรับแสดง", () => {
  it("ตัดอักขระควบคุม/ตัวคั่น path/ตัวกลับทิศ และจำกัดความยาว", () => {
    expect(safeDisplayName("../../etc/passwd")).not.toMatch(/[\\/]/);
    expect(safeDisplayName("rtl‮gnp.exe")).not.toMatch(/‮/);
    expect(safeDisplayName("a\u0000b\nc")).toBe("abc");
    expect(safeDisplayName("a".repeat(5000)).length).toBeLessThanOrEqual(80);
    expect(safeDisplayName("สลิปโอนเงิน.jpg")).toBe("สลิปโอนเงิน.jpg");
  });
  it("ว่าง/ไม่ใช่ข้อความ → ค่าเริ่มต้น", () => {
    for (const v of ["", "   ", ".", "...", null, undefined, 5]) expect(safeDisplayName(v)).toBe("ไฟล์แนบ");
  });
});

// ค่าสองฝั่ง (TS กับ SQL) ต้องตรงกัน — ถ้าแก้ฝั่งเดียว เทสต์นี้แดง
describe("ตรงกับ migration 20261008000009 (กัน drift)", () => {
  const sql = readFileSync(join(process.cwd(), "supabase/migrations/20261008000009_storage_policies.sql"), "utf8");

  it("ขนาดสูงสุดของ bucket = MAX_ATTACHMENT_BYTES", () => {
    expect(sql).toContain(`false, ${MAX_ATTACHMENT_BYTES},`);
  });

  it("ชนิดไฟล์ของ bucket = ALLOWED_TYPES (+ image/heif ที่ iOS บางรุ่นส่ง)", () => {
    const m = /allowed_mime_types\)\s*values[\s\S]*?array\[([^\]]*)\]/.exec(sql);
    const inSql = new Set([...(m?.[1] ?? "").matchAll(/'([^']+)'/g)].map((x) => x[1]));
    const inTs = new Set<string>([...Object.keys(ALLOWED_TYPES), "image/heif"]);
    expect(inSql).toEqual(inTs);
  });

  it("นามสกุลที่ policy รับ = นามสกุลใน ALLOWED_TYPES", () => {
    const m = /\\\.\(([a-z|]+)\)\$'/.exec(sql);
    expect(new Set(m?.[1].split("|"))).toEqual(new Set(Object.values(ALLOWED_TYPES)));
  });

  it("รูปแบบ uuid/uuid/uuid ของ policy ตรงกับ regex ฝั่ง TS", () => {
    const u = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
    expect(sql).toContain(`u  constant text := '${u}'`);
    expect(ATTACHMENT_REF_RE.source).toContain(u);
  });

  it("migration ไม่ทำให้ bucket public", () => {
    expect(sql).toMatch(/values \('attachments', 'attachments', false,/);
    expect(sql).not.toMatch(/public\s*=\s*true/i);
  });
});
