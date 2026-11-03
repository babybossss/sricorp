import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";

/** รับเฉพาะทางภายในเว็บ — กัน open redirect (`//evil.com` · `https://evil.com` · `/\evil.com`) */
function safeNext(raw: string | null): string {
  if (!raw || !raw.startsWith("/") || raw.startsWith("//") || raw.startsWith("/\\")) return "/dashboard";
  // ไม่พากลับ /login เพราะมันจะเด้งต่อเอง
  if (raw === "/login" || raw.startsWith("/login?")) return "/dashboard";
  return raw;
}

/** Google → Supabase → ที่นี่: แลก `code` เป็น session แล้วพาไปหน้าที่ตั้งใจจะไป */
export async function GET(request: NextRequest) {
  const { searchParams } = request.nextUrl;
  const code = searchParams.get("code");
  const next = safeNext(searchParams.get("next"));

  const fail = (reason: string) => {
    const url = new URL("/login", request.url);
    url.searchParams.set("error", reason);
    return NextResponse.redirect(url);
  };

  // ผู้ใช้กดยกเลิกที่หน้า Google หรือ provider ตอบ error กลับมา
  if (searchParams.get("error")) return fail("oauth");
  if (!code) return fail("no_code");

  try {
    const supabase = await createClient();
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (error) return fail("exchange");
  } catch {
    return fail("config");
  }

  return NextResponse.redirect(new URL(next, request.url));
}
