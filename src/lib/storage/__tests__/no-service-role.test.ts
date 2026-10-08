import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/** ชั้นไฟล์แนบต้องไม่แตะคีย์ที่ข้าม RLS ที่ใดเลย — ถ้ามีคนเพิ่มภายหลัง เทสต์นี้แดง */
function walk(dir: string): string[] {
  return readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    return statSync(p).isDirectory() ? (n === "__tests__" ? [] : walk(p)) : [p];
  });
}

describe("ไฟล์แนบ: ไม่มี service-role / secret key", () => {
  const files = [...walk(join(process.cwd(), "src/lib/storage")), ...walk(join(process.cwd(), "src/app/api/attachments"))];

  it("พบไฟล์ให้ตรวจ (กันเทสต์เปล่า)", () => {
    expect(files.length).toBeGreaterThanOrEqual(8);
  });

  it("ไม่อ้าง env ที่เป็น secret และไม่ใช้ createClient ตัวอื่นนอกจาก lib/supabase/server", () => {
    for (const f of files) {
      const code = readFileSync(f, "utf8")
        .replace(/\/\*[\s\S]*?\*\//g, "") // ตัดคอมเมนต์ (คอมเมนต์เอ่ยถึงคำว่า service-role ได้)
        .replace(/^\s*\/\/.*$/gm, "");
      expect(code, f).not.toMatch(/process\.env\.\w*(SERVICE|SECRET)/i);
      expect(code, f).not.toMatch(/SUPABASE_SERVICE|service_role|sb_secret_/i);
      expect(code, f).not.toMatch(/from\s+["']@supabase\/supabase-js["']/);
    }
  });
});
