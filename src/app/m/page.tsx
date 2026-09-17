import Image from "next/image";
import Link from "next/link";
import { PhoneFrame } from "@/components/mobile/phone-frame";
import { TODOS } from "@/lib/mock/dashboard";
import { PRIORITY_PILL } from "@/lib/tone";
import { cn } from "@/lib/utils";

/** หน้าแรก มือถือ 390 — ปุ่มสูง 56px ตัวอักษรไม่ต่ำกว่า 16px */
export default function MobileHomePage() {
  return (
    <div className="min-h-screen bg-canvas py-6">
      <PhoneFrame className="bg-canvas">
        <div className="flex items-center gap-2.5 border-b border-line bg-surface p-[14px_16px]">
          <Image src="/sri-logo.png" alt="SRI" width={32} height={32} className="h-8 w-8 object-contain" />
          <div className="mr-auto text-lg font-bold text-brand-600">SRI OS</div>
          <div className="flex h-10 w-10 items-center justify-center rounded-pill bg-brand-50 text-sm font-bold text-brand-600">ธ</div>
        </div>

        <div className="flex flex-col gap-3 p-4">
          <div className="flex gap-2">
            <div className="flex min-h-[48px] flex-1 items-center justify-center gap-2 rounded-pill border border-line bg-surface text-sm font-semibold">
              <span className="h-2.5 w-2.5 rounded-pill bg-holder-group" />
              รวมทั้งกลุ่ม
            </div>
            <div className="flex min-h-[48px] min-w-[120px] flex-none items-center justify-center rounded-pill border border-line bg-surface text-sm font-semibold">
              ก.ย. 2026
            </div>
          </div>

          <div className="rounded-card border border-line bg-surface p-4">
            <div className="text-sm text-ink-600">มูลค่าทรัพย์สินสุทธิ (NAV)</div>
            <div className="text-display font-semibold">฿ 65.7M</div>
            <div className="text-sm font-semibold text-pos">▲ 1.8% เทียบเดือนก่อน</div>
          </div>

          <div className="grid grid-cols-2 gap-3">
            {[
              ["กำไรเดือนนี้", "+412,300", "text-pos"],
              ["เงินสดสุทธิ", "−1.25M", "text-neg"],
              ["ค้างรับ", "131,500", ""],
              ["ค้างจ่าย", "58,200", ""],
            ].map(([label, v, tone]) => (
              <div key={label} className="rounded-card border border-line bg-surface p-3.5">
                <div className="text-sm text-ink-600">{label}</div>
                <div className={cn("text-h2 font-semibold", tone)}>{v}</div>
              </div>
            ))}
          </div>

          <div className="rounded-card border border-line bg-surface p-4">
            <div className="text-sm text-ink-600">รายได้ประจำ / เดือน</div>
            <div className="text-h1 font-semibold">฿ 486,000</div>
            <div className="m-[8px_0_4px] h-2.5 overflow-hidden rounded-pill bg-line">
              <div className="h-full bg-brand-600" style={{ width: "48.6%" }} />
            </div>
            <div className="text-sm text-ink-600">48.6% ของเป้า ฿ 1M</div>
          </div>

          <div className="rounded-card border border-line bg-surface p-4">
            <div className="mb-1 text-lg font-semibold">ที่ควรทำก่อน</div>
            {TODOS.slice(0, 3).map((t) => (
              <div key={t.title} className="border-t border-line py-2.5">
                <div className="flex items-start gap-2">
                  <span className={cn("inline-flex h-[26px] flex-none items-center rounded-pill px-2 text-sm font-bold", PRIORITY_PILL[t.p])}>{t.p}</span>
                  <span className="text-base font-semibold leading-[26px]">{t.title}</span>
                </div>
                <div className="text-sm leading-6 text-info">✦ {t.why}</div>
              </div>
            ))}
          </div>

          <div className="flex flex-col gap-2.5 rounded-card border border-brand-100 bg-brand-50 p-4">
            <div className="text-base font-semibold">มี 7 รายการรออนุมัติ · รวม ฿ 186,500</div>
            <Link
              href="/approvals"
              className="flex min-h-control-mobile items-center justify-center rounded border border-brand-600 bg-brand-600 text-base font-semibold text-white no-underline hover:no-underline"
            >
              ไปอนุมัติ
            </Link>
          </div>
        </div>

        <div className="grid grid-cols-5 items-end gap-1 border-t border-line bg-surface p-[8px_8px_16px]">
          <div className="flex min-h-[56px] flex-col items-center justify-center text-sm font-semibold text-brand-600">หน้าแรก</div>
          <Link href="/approvals" className="flex min-h-[56px] flex-col items-center justify-center gap-0.5 text-sm text-ink-600 no-underline hover:no-underline">
            อนุมัติ
            <span className="inline-flex h-[22px] min-w-6 items-center justify-center rounded-pill bg-warn px-1.5 text-sm font-bold text-[#3d2600]">7</span>
          </Link>
          <Link
            href="/m/new"
            className="flex min-h-16 items-center justify-center rounded-2xl bg-brand-600 text-sm font-bold text-white no-underline hover:no-underline"
          >
            ＋ บันทึก
          </Link>
          <Link href="/balance" className="flex min-h-[56px] items-center justify-center text-sm text-ink-600 no-underline hover:no-underline">
            ทรัพย์สิน
          </Link>
          <Link href="/dashboard" className="flex min-h-[56px] items-center justify-center text-sm text-ink-600 no-underline hover:no-underline">
            เมนู
          </Link>
        </div>
      </PhoneFrame>
    </div>
  );
}
