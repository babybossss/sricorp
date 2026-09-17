import { cn } from "@/lib/utils";

/** กรอบมือถือ 390px สำหรับดูบน desktop — บนมือถือจริงจะเต็มจอ */
export function PhoneFrame({ className, children }: { className?: string; children: React.ReactNode }) {
  return (
    <div className="flex justify-center p-2">
      <div className={cn("w-[390px] flex-none overflow-hidden rounded-[28px] border border-line shadow-phone", className)}>{children}</div>
    </div>
  );
}
