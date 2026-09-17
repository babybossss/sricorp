import Image from "next/image";
import Link from "next/link";
import { Button } from "@/components/ui/button";

export default function LoginPage() {
  return (
    <div className="flex min-h-screen flex-col items-center justify-center gap-7 bg-surface p-[48px_24px]">
      <Image src="/sri-logo.png" alt="SRI Corporation" width={132} height={132} className="h-[132px] w-[132px] object-contain" priority />
      <div className="text-center">
        <div className="text-h1 font-semibold">เข้าสู่ระบบ SRI OS</div>
        <div className="text-base text-ink-600">บริษัท เอสอาร์ไอ คอร์ปอเรชั่น จำกัด</div>
        <div className="text-sm text-ink-400">SRI Corporation Co., Ltd.</div>
      </div>
      <div className="flex w-full max-w-[380px] flex-col gap-3">
        <Button asChild>
          <Link href="/dashboard" className="no-underline hover:no-underline">เข้าสู่ระบบด้วย Google</Link>
        </Button>
        <Button asChild variant="secondary">
          <Link href="/dashboard" className="no-underline hover:no-underline">ส่งลิงก์เข้าอีเมล</Link>
        </Button>
      </div>
      <div className="text-sm text-ink-400">Sustainable Generations Wealth</div>
    </div>
  );
}
