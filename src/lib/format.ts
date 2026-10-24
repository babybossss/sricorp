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

  // รูปแบบยุโรป "1.000,50" — ถ้าตัดจุลภาคทิ้งดื้อๆ จะกลายเป็น 1.0005 ผิดไปพันเท่าเงียบๆ
  // สังเกตจากจุลภาคที่อยู่**หลัง**จุดทศนิยม ซึ่งรูปแบบที่ระบบใช้ (en-US) ไม่มีทางเกิด
  if (body.lastIndexOf(",") > body.lastIndexOf(".") && body.includes(".")) return null;

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

/* ------------------------------------------------------------------ *
 * วันที่ในฟอร์ม — ผู้ใช้พิมพ์ วว/ดด/ปปปป (ค.ศ.) · DB รับ YYYY-MM-DD
 * ------------------------------------------------------------------ */

/** วันนี้ตามเวลากรุงเทพฯ รูป วว/ดด/ปปปป — ระบุเขตเวลาเอง ไม่ให้ server (UTC) กับ browser ได้วันต่างกัน */
export function todayDmy(now: Date = new Date()): string {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Asia/Bangkok",
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
  }).formatToParts(now);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  return `${get("day")}/${get("month")}/${get("year")}`;
}

/**
 * แปลง "วว/ดด/ปปปป" เป็น "YYYY-MM-DD" · อ่านไม่ออกหรือไม่ใช่วันที่จริง = `null` (ไม่เดา)
 *
 * - ต้องเป็นวันที่ที่มีอยู่จริงในปฏิทิน (31/02 ไม่ผ่าน)
 * - ปีต้องเป็น ค.ศ. 1900-2399 · ปี พ.ศ. (25xx) **ปฏิเสธ ไม่แปลงให้เอง** เพราะแปลงผิดทิศ = ลงบัญชีผิดปีเงียบๆ
 * - รับ YYYY-MM-DD ที่ถูกต้องด้วย (กันค่าที่ผ่านการแปลงแล้วถูกส่งซ้ำ)
 */
export function dmyToIso(raw: string): string | null {
  const t = raw.trim();
  let d: number, m: number, y: number;
  const dmy = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(t);
  const iso = /^(\d{4})-(\d{2})-(\d{2})$/.exec(t);
  if (dmy) {
    d = Number(dmy[1]);
    m = Number(dmy[2]);
    y = Number(dmy[3]);
  } else if (iso) {
    y = Number(iso[1]);
    m = Number(iso[2]);
    d = Number(iso[3]);
  } else {
    return null;
  }
  if (y < 1900 || y > 2399 || m < 1 || m > 12 || d < 1) return null;
  const dim = new Date(Date.UTC(y, m, 0)).getUTCDate();
  if (d > dim) return null;
  const p = (n: number, w = 2) => String(n).padStart(w, "0");
  return `${p(y, 4)}-${p(m)}-${p(d)}`;
}

/** "YYYY-MM-DD" → "วว/ดด/ปปปป" สำหรับแสดงผล · ไม่ใช่รูปที่คาดไว้คืนค่าเดิม */
export function isoToDmy(iso: string | null | undefined): string {
  if (!iso) return "—";
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso);
  return m ? `${m[3]}/${m[2]}/${m[1]}` : iso;
}
