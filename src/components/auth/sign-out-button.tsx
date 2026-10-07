import { Button } from "@/components/ui/button";
import { signOut } from "@/lib/auth/actions";
import { cn } from "@/lib/utils";

/** ปุ่มออกจากระบบ — มีข้อความกำกับเสมอ · ใช้ server action จึงทำงานได้แม้ไม่มี JS */
export function SignOutButton({
  variant = "secondary",
  size,
  className,
}: {
  variant?: "primary" | "secondary" | "ghost";
  size?: "default" | "sm" | "mobile";
  className?: string;
}) {
  return (
    <form action={signOut}>
      <Button type="submit" variant={variant} size={size} className={cn("w-full", className)}>
        ออกจากระบบ
      </Button>
    </form>
  );
}
