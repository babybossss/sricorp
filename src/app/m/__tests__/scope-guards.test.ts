import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

/**
 * ด่านร่วมของหน้าที่ย้ายออกจากข้อมูลจำลองแล้ว (ทรัพย์ · อนุมัติ · แดชบอร์ด · /m · ผู้ใช้):
 * ไม่กลับไปอ่าน mock/store · ไม่ฝังสี hex · /m ไม่ใช้กรอบมือถือกว้างคงที่ (ต้องใช้ได้บนจอแคบจริง)
 */
const ROOT = path.resolve(__dirname, "../../../..");
const DIRS = ["src/app/assets", "src/app/approvals", "src/app/m/page.tsx", "src/app/dashboard", "src/app/settings/users", "src/components/assets", "src/components/approvals", "src/components/dashboard"];
const EXTRA = ["src/lib/db/assets-model.ts", "src/lib/db/assets-server.ts", "src/lib/db/approvals-model.ts", "src/lib/db/approvals-server.ts"];

function walk(p: string): string[] {
  const full = path.join(ROOT, p);
  if (statSync(full).isFile()) return [full];
  return readdirSync(full).flatMap((n) => (n === "__tests__" ? [] : walk(path.join(p, n))));
}
const FILES = [...DIRS.flatMap(walk), ...EXTRA.map((e) => path.join(ROOT, e))].filter((f) => /\.(ts|tsx)$/.test(f));
const strip = (s: string) => s.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:"'`])\/\/.*$/gm, "$1");

describe("หน้าที่ย้ายแล้วไม่กลับไปใช้ข้อมูลจำลอง/สีฝัง", () => {
  it("ไล่ไฟล์ได้ครบ", () => expect(FILES.length).toBeGreaterThanOrEqual(35));

  it("ไม่ import @/lib/mock หรือ @/lib/store", () => {
    const hits = FILES.filter((f) => /@\/lib\/(mock|store)\b/.test(strip(readFileSync(f, "utf8")))).map((f) => path.relative(ROOT, f));
    expect(hits).toEqual([]);
  });

  it("ไม่ฝังสี hex ในโค้ด (ใช้โทเคนใน tailwind.config.ts เท่านั้น)", () => {
    const hits = FILES.flatMap((f) =>
      strip(readFileSync(f, "utf8"))
        .split("\n")
        .map((t, i) => ({ f: path.relative(ROOT, f), line: i + 1, t: t.trim() }))
        .filter((x) => /#[0-9a-fA-F]{6}\b|#[0-9a-fA-F]{3}\b(?![\w-])/.test(x.t))
    );
    expect(hits).toEqual([]);
  });

  it("/m ไม่ใช้กรอบมือถือกว้างคงที่ และปุ่มนำทางสูงตามมาตรฐานมือถือ (56px)", () => {
    const src = readFileSync(path.join(ROOT, "src/app/m/page.tsx"), "utf8");
    expect(src).not.toMatch(/PhoneFrame|w-\[390px\]/);
    expect(src).toMatch(/max-w-\[430px\]/);
    expect(src).toMatch(/min-h-control-mobile/);
    // ไม่มีปุ่ม/ลิงก์ที่ไม่มีความสูงมาตรฐาน: ทุก <Link ... className="..."> ในหน้านี้ต้องมี min-h-control-mobile หรือกล่องข้อความ
    const linkClasses = [...src.matchAll(/<Link[^>]*className="([^"]*)"/g)].map((m) => m[1]);
    expect(linkClasses.length).toBeGreaterThan(0);
    for (const c of linkClasses) expect(c, c).toMatch(/min-h-control-mobile|LINK_BTN/);
  });
});
