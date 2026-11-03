import Link from "next/link";
import { cn } from "@/lib/utils";
import { THAI_MONTHS_SHORT } from "@/lib/format";

/**
 * แถบเลือกช่วงเวลา — ทั้งปี หรือรายเดือน
 *
 * **คอมโพเนนต์เดียวของทั้งระบบ** ห้ามทำชุดที่สอง ไม่งั้นวันหนึ่งสองหน้าจะ
 * เลือกช่วงเวลาไม่เหมือนกันเงียบๆ แล้วผู้ใช้จะเทียบงบข้ามหน้าไม่ได้
 *
 * เป็นลิงก์ล้วน (ไม่ต้องมี JavaScript ฝั่ง browser) กดครั้งเดียวเปลี่ยนทันที
 * ช่วงเวลาอยู่ใน URL ทั้งหมด จึงแชร์ลิงก์และกดย้อนกลับของเบราว์เซอร์ได้
 *
 * `params` คือค่าที่ต้องพกไปด้วยทุกครั้ง (แท็บ · ผู้ถือ) — กดเปลี่ยนเดือนแล้ว
 * ต้องไม่เด้งไปดูของผู้ถืออื่น
 */
export function PeriodBar({
  basePath,
  year,
  month,
  params = {},
}: {
  basePath: string;
  year: number;
  /** `null` = ทั้งปี */
  month: number | null;
  params?: Record<string, string>;
}) {
  const href = (m: number | null) => {
    const q = new URLSearchParams(params);
    q.set("year", String(year));
    // ทั้งปี = ไม่ใส่ month ลง URL เลย (เป็นค่าตั้งต้น และอ่านง่ายกว่า)
    if (m !== null) q.set("month", String(m));
    return `${basePath}?${q.toString()}`;
  };

  const base =
    "flex min-h-control flex-none items-center rounded border no-underline hover:no-underline focus-visible:outline-none focus-visible:ring-[3px] focus-visible:ring-brand-600";
  const on = "border-brand-600 bg-brand-50 font-semibold text-brand-600";
  const off = "border-line bg-surface text-ink-600 hover:border-ink-400";

  return (
    <nav aria-label="เลือกช่วงเวลา" className="flex gap-2 overflow-x-auto pb-1">
      <Link href={href(null)} aria-current={month === null ? "page" : undefined} className={cn(base, "px-4 text-base font-semibold", month === null ? on : off)}>
        ทั้งปี {year}
      </Link>
      {THAI_MONTHS_SHORT.map((label, i) => {
        const m = i + 1;
        return (
          <Link key={m} href={href(m)} aria-current={month === m ? "page" : undefined} className={cn(base, "px-3 text-base", month === m ? on : off)}>
            {label}
          </Link>
        );
      })}
    </nav>
  );
}
