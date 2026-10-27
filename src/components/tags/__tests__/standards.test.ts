import { describe, expect, it } from "vitest";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";

/**
 * ข้อบังคับ UI ของ CLAUDE.md ที่ตรวจจากซอร์สได้ตรงๆ — ครอบทุกไฟล์ในโฟลเดอร์ tags (ไฟล์ใหม่ที่เพิ่มทีหลังโดนด้วย)
 */
const dir = path.resolve(__dirname, "..");
const sources = readdirSync(dir)
  .filter((f) => /\.(ts|tsx)$/.test(f))
  .map((f) => ({ f, src: readFileSync(path.join(dir, f), "utf8") }));

describe("มาตรฐาน UI ของโฟลเดอร์ tags", () => {
  it("พบไฟล์ที่ต้องตรวจ", () => {
    expect(sources.map((s) => s.f)).toEqual(expect.arrayContaining(["tag-chip.tsx", "tag-picker.tsx", "tag-weight-input.tsx", "tag-touch-table.tsx", "types.ts"]));
  });

  it("ไม่มีสี hex / rgb() ตรงๆ — สีมาจากโทเคนเท่านั้น", () => {
    for (const { f, src } of sources) {
      // ตัดคอมเมนต์ก่อน เพื่อไม่ให้ข้อความอธิบายทำให้พังโดยไม่ได้ตั้งใจ
      const code = src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:])\/\/.*$/gm, "$1");
      expect(code, f).not.toMatch(/#[0-9a-fA-F]{3,8}\b/);
      expect(code, f).not.toMatch(/\brgba?\(/);
      expect(code, f).not.toMatch(/\bhsla?\(/);
    }
  });

  it("ไม่มีขนาดตัวอักษรต่ำกว่า 16px (text-xs / text-[Npx] ที่ N<16)", () => {
    for (const { f, src } of sources) {
      expect(src, f).not.toMatch(/\btext-(xs|2xs)\b/);
      const px = [...src.matchAll(/text-\[(\d+(?:\.\d+)?)px\]/g)].map((m) => Number(m[1]));
      expect(px.filter((n) => n < 16), f).toEqual([]);
    }
  });

  it("ไม่มีคลาสสีของ Tailwind ที่นอกโทเคน (เช่น bg-red-500)", () => {
    const stock = /\b(?:bg|text|border|ring|fill|stroke)-(?:red|blue|green|gray|grey|slate|zinc|neutral|stone|orange|amber|yellow|lime|emerald|teal|cyan|sky|indigo|violet|purple|fuchsia|pink|rose)-\d{2,3}\b/;
    for (const { f, src } of sources) expect(src, f).not.toMatch(stock);
  });

  it("ไม่ใช้ Button size icon (ห้ามปุ่มไอคอนเดี่ยว) และไม่ใช้ size sm ที่เตี้ยกว่า 52px", () => {
    for (const { f, src } of sources) {
      expect(src, f).not.toMatch(/size=["']icon["']/);
      expect(src, f).not.toMatch(/size=["']sm["']/);
    }
  });

  it("ไม่ผูก Supabase / server action — รับข้อมูลทาง props อย่างเดียว", () => {
    for (const { f, src } of sources) {
      expect(src, f).not.toMatch(/@\/lib\/supabase|@supabase\/|@\/app\/actions|next\/headers/);
    }
  });

  it("ไม่เช็ครหัส/ชื่อ tag หรือชนิดตรงๆ ในโค้ด (กฎเหล็กข้อ 5 · ADR 0002 ข้อ 6)", () => {
    for (const { f, src } of sources) {
      expect(src, f).not.toMatch(/(?:kind|key)\s*===?\s*["'](?:project|label)["']/);
    }
  });
});
