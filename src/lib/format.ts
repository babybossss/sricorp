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

/** แปลง "12,000.00" → 12000 สำหรับช่องกรอกเงิน */
export function parseAmount(raw: string): number {
  const n = Number(raw.replace(/[^0-9.-]/g, ""));
  return Number.isFinite(n) ? n : 0;
}
