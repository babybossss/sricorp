/** รูปแบบตัวเลขตาม Style Guide — ติดลบใช้วงเล็บ, tabular numbers ทั้งระบบ */

export function money(n: number | null | undefined, opts: { dash?: boolean } = {}): string {
  if (n === null || n === undefined) return opts.dash === false ? "" : "–";
  if (n === 0) return opts.dash === false ? "0.00" : "–";
  const abs = Math.abs(n).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  return n < 0 ? `(${abs})` : abs;
}

/** เงินเข้าแสดงเครื่องหมายบวกนำหน้า */
export function signedMoney(n: number | null | undefined): string {
  if (n === null || n === undefined || n === 0) return "–";
  const abs = Math.abs(n).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  return n < 0 ? `(${abs})` : `+${abs}`;
}

/** ตัวเลขในตาราง PL ไม่มีทศนิยม */
export function plMoney(n: number): string {
  if (n === 0) return "–";
  const abs = Math.abs(n).toLocaleString("en-US");
  return n < 0 ? `(${abs})` : abs;
}

/** ตัวเลขย่อสำหรับ KPI */
export function compactBaht(n: number): string {
  const abs = Math.abs(n);
  if (abs >= 1_000_000) return `฿ ${(n / 1_000_000).toFixed(1)}M`;
  if (abs >= 1_000) return `฿ ${Math.round(n / 1_000)}K`;
  return `฿ ${n.toLocaleString("en-US")}`;
}

export function baht(n: number): string {
  return `฿ ${Math.abs(n).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

/**
 * แปลงข้อความในช่องกรอกเงินเป็นตัวเลข · อ่านไม่ออกคืน `null`
 *
 * ต้องเข้าใจรูปแบบที่ **ระบบเองแสดงออกมา** เพราะผู้ใช้ก๊อปตัวเลขจากหน้าจอมาวางได้:
 * - `money()` แสดงติดลบเป็นวงเล็บ `(300,000.00)`
 * - หน้าจอใช้เครื่องหมายลบยูนิโคด `−` (U+2212) ไม่ใช่ยัติภังค์ ASCII
 *
 * ของเดิมตัดทุกอักขระที่ไม่ใช่ `0-9 . -` ทิ้ง ทำให้ทั้งสองแบบกลายเป็น**บวก**
 * ตีราคาลงจึงกลายเป็นตีราคาขึ้น — ผิดทิศทั้งก้อนโดยไม่มีอะไรฟ้อง
 * และข้อความที่อ่านไม่ออกอย่าง `"300000-"` คืน 0 เงียบๆ เหมือนผู้ใช้ตั้งใจใส่ศูนย์
 */
export function parseAmountOrNull(raw: string): number | null {
  const t = raw.trim();
  if (t === "") return null;

  // วงเล็บ = ติดลบ ตามที่ money() แสดง
  const wrapped = /^\((.*)\)$/.exec(t);
  const body = wrapped ? wrapped[1] : t;

  // เครื่องหมายลบทุกแบบที่หน้าจอและคีย์บอร์ดไทยผลิตได้
  const normalised = body.replace(/[\u2212\u2013\u2014]/g, "-").replace(/[,\s฿]/g, "");
  if (!/^[+-]?(\d+(\.\d*)?|\.\d+)$/.test(normalised)) return null;

  const n = Number(normalised);
  if (!Number.isFinite(n)) return null;
  return wrapped ? -Math.abs(n) : n;
}

/**
 * เหมือน `parseAmountOrNull()` แต่คืน 0 เมื่ออ่านไม่ออก
 * ใช้กับช่องที่ "ยังไม่กรอก" กับ "ศูนย์" มีความหมายเดียวกัน
 */
export function parseAmount(raw: string): number {
  return parseAmountOrNull(raw) ?? 0;
}
