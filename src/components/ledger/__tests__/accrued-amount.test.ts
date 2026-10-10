import { describe, it, expect } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { TX_TYPES, type CashDirection } from "@/lib/rules/tx-rules";
import { accruedAmountText } from "../confirm-flow";

/**
 * รูที่ 3 ของผู้ตรวจรอบสอง · ช่อง "ยอดค้าง" ของแท็บยืนยันรับ-จ่าย
 *
 * ของเดิมใน `confirm-tab.tsx` เป็น ternary สองชั้น:
 *   `dir === "in" ? signedMoney(+) : dir === "out" ? money(−) : money(+)`
 * → `"none"` · `"both"` · `null` **ตกทาง else แล้วแสดงเป็นยอดบวก**
 *   ซึ่งอ่านว่า "เงินจะเข้า" ทั้งที่ไม่มีเงินเคลื่อน / เงินเข้าออกพร้อมกัน /
 *   ไม่รู้จักหมวดนี้เลย — และขัดกับคอมเมนต์ของตัวเองที่บอกว่า `dir`
 *   ตอบครบทั้งสี่ค่าแล้ว
 *
 * บทเรียน D-102: union type กันของตกหล่นได้เฉพาะที่ map ครบเคส
 *   ternary + fallback รับค่าใหม่เงียบๆ → ต้องเป็น `switch` ครบเคส
 *   และต้องอยู่ในฟังก์ชันที่เทสต์เรียกได้ ไม่ใช่ฝังใน JSX ที่ไม่มีใครทดสอบ
 */
describe("accruedAmountText ตอบครบทุกค่าของ CashDirection", () => {
  it("เงินเข้าแสดงเครื่องหมายบวก · เงินออกแสดงในวงเล็บ", () => {
    expect(accruedAmountText("in", 30000)).toBe("+30,000.00");
    expect(accruedAmountText("out", 30000)).toBe("(30,000.00)");
  });

  it("`both` ไม่ใช่ยอดบวก — โอนระหว่างบัญชีตัวเองเข้าหนึ่งออกหนึ่ง", () => {
    const text = accruedAmountText("both", 30000);
    expect(text).not.toBe("30,000.00");
    expect(text).not.toBe(accruedAmountText("in", 30000));
    expect(text).toContain("30,000.00");
  });

  it("`none` ไม่ใช่ยอดบวก และบอกเป็นคำว่าไม่มีเงินเคลื่อน", () => {
    const text = accruedAmountText("none", 30000);
    expect(text).not.toBe("30,000.00");
    expect(text).not.toBe(accruedAmountText("in", 30000));
    expect(text).toContain("ไม่มีเงินเคลื่อน");
  });

  it("`null` (หมวดไม่อยู่ในตารางกฎ) ไม่ใช่ยอดบวก และพูดว่าไม่รู้จักหมวด", () => {
    const text = accruedAmountText(null, 30000);
    expect(text).not.toBe("30,000.00");
    expect(text).not.toBe(accruedAmountText("in", 30000));
    expect(text).toContain("ตารางกฎ");
  });

  it("ทั้งห้าคำตอบแยกจากกันจริง ไม่มีสองค่าที่แสดงเหมือนกัน", () => {
    const dirs: (CashDirection | null)[] = ["in", "out", "both", "none", null];
    const texts = dirs.map((d) => accruedAmountText(d, 30000));
    expect(new Set(texts).size).toBe(dirs.length);
  });

  it("ตารางกฎมีหมวดครบทั้งสี่ค่าให้ตกหล่นได้จริง (ไม่ใช่เผอิญมีแต่ in/out)", () => {
    const seen = new Set(TX_TYPES.flatMap((t) => t.subs).map((s) => s.cash));
    for (const d of ["in", "out", "both", "none"] as CashDirection[]) {
      expect(seen, `ตารางกฎไม่มีหมวดที่ cash = ${d}`).toContain(d);
    }
  });
});

describe("หน้าจอไม่คิดทิศของยอดค้างเอง", () => {
  const dir = path.resolve(__dirname, "..");
  /** ตัดคอมเมนต์ออก — คอมเมนต์พูดถึง ternary เดิมได้ แต่โค้ดห้ามกลับไปใช้ */
  const code = (f: string) =>
    fs
      .readFileSync(path.join(dir, f), "utf8")
      .replace(/\/\*[\s\S]*?\*\//g, "")
      .replace(/\{\s*\/\*[\s\S]*?\*\/\s*\}/g, "")
      .replace(/(^|[^:])\/\/.*$/gm, "$1");

  it("confirm-tab.tsx เรียก accruedAmountText ไม่ใช่เทียบ dir เอง", () => {
    const tab = code("confirm-tab.tsx");
    expect(tab).toContain("accruedAmountText(");
    // mutation R5: คืน ternary `dir === "in" ? … : dir === "out" ? … : money(+)`
    expect(tab).not.toMatch(/dir\s*===/);
  });

  it("accruedAmountText เขียนเป็น switch ครบเคส ไม่มี fallback ที่กลืนค่าใหม่", () => {
    const flow = code("confirm-flow.ts");
    const body = flow.slice(flow.indexOf("export function accruedAmountText"));
    const fn = body.slice(0, body.indexOf("\n}") + 2);
    expect(fn).toContain("switch (dir)");
    for (const c of ['case "in"', 'case "out"', 'case "both"', 'case "none"', "case null"]) {
      expect(fn, c).toContain(c);
    }
    expect(fn).not.toContain("default:");
  });
});
