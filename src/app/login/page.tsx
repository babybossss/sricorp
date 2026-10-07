import Image from "next/image";
import { Button } from "@/components/ui/button";
import { GoogleSignInButton } from "@/components/auth/google-button";
import { readSupabaseEnv } from "@/lib/supabase/env";

// อ่าน env ตอนมีคนเปิดหน้า ไม่ใช่ตอน build — ไม่งั้นข้อความ "ตั้งค่าไม่ครบ" จะถูกฝังไว้ในหน้า static
export const dynamic = "force-dynamic";

const ERRORS: Record<string, string> = {
  oauth: "เข้าสู่ระบบด้วย Google ไม่สำเร็จ หรือถูกยกเลิก ลองกดใหม่อีกครั้ง",
  no_code: "ไม่ได้รับรหัสยืนยันจาก Google ลองกดเข้าสู่ระบบใหม่อีกครั้ง",
  exchange: "ยืนยันตัวตนไม่สำเร็จ (รหัสหมดอายุหรือถูกใช้ไปแล้ว) ลองกดเข้าสู่ระบบใหม่อีกครั้ง",
  config: "ตั้งค่า Supabase ไม่ครบ ดูรายละเอียดด้านบน",
};

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ error?: string; next?: string }> }) {
  const { error, next } = await searchParams;
  const env = readSupabaseEnv();

  return (
    <div className="flex min-h-screen flex-col items-center justify-center gap-7 bg-surface p-[48px_24px]">
      <Image src="/sri-logo.png" alt="SRI Corporation" width={132} height={132} className="h-[132px] w-[132px] object-contain" priority />
      <div className="text-center">
        <div className="text-h1 font-semibold">เข้าสู่ระบบ SRI OS</div>
        <div className="text-base text-ink-600">บริษัท เอสอาร์ไอ คอร์ปอเรชั่น จำกัด</div>
        <div className="text-sm text-ink-400">SRI Corporation Co., Ltd.</div>
      </div>
      <div className="flex w-full max-w-[380px] flex-col gap-3">
        {!env.ok ? (
          // env ไม่ครบ: บอกตรงๆ ว่าต้องตั้งอะไร — ไม่พัง ไม่ใช้ข้อมูลจำลองแทน
          <div role="alert" className="rounded-card border border-warn bg-warn-bg p-[16px_18px] text-base leading-7 text-warn-fg">
            <b>ยังเข้าสู่ระบบไม่ได้ — ตั้งค่า Supabase ยังไม่ครบ</b>
            <ul className="mt-1 list-disc pl-6 text-sm">
              {env.problems.map((p) => (
                <li key={p}>{p}</li>
              ))}
            </ul>
            <div className="mt-1 text-sm">
              ตั้งใน <code>.env.local</code> (ดูตัวอย่างที่ <code>.env.example</code>) หรือใน Vercel → Settings → Environment Variables
              แล้ว deploy ใหม่
            </div>
          </div>
        ) : (
          <>
            {error ? (
              <p role="alert" className="rounded border border-neg-bd bg-neg-bg p-[12px_16px] text-sm text-neg-fg">
                {ERRORS[error] ?? "เข้าสู่ระบบไม่สำเร็จ ลองใหม่อีกครั้ง"}
              </p>
            ) : null}
            <GoogleSignInButton next={next} />
          </>
        )}
        {/* ลิงก์เข้าอีเมลยังไม่ได้ต่อ auth จริง (รอบนี้ทำ Google อย่างเดียว) — คงหน้าตาไว้ แต่กดไม่ได้
            ดีกว่าให้กดแล้วเข้าระบบโดยไม่ล็อกอิน */}
        <Button variant="secondary" disabled>ส่งลิงก์เข้าอีเมล (เร็วๆ นี้)</Button>
      </div>
      <div className="flex flex-col items-center gap-1.5 text-center">
        <div className="text-sm text-ink-400">“ Sustainable Generational Wealth and Happiness ”</div>
        <div className="text-sm text-ink-400">Designed by Mr. LU</div>
      </div>
    </div>
  );
}
