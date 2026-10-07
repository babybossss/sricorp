import type { NextRequest } from "next/server";
import { updateSession } from "@/lib/supabase/middleware";

/** ต่ออายุ session + เช็คว่าล็อกอินหรือยัง เท่านั้น — สิทธิ์ละเอียดเช็คในหน้า (ถาม DB) */
export async function middleware(request: NextRequest) {
  return updateSession(request);
}

export const config = {
  matcher: [
    // ไม่ครอบไฟล์ static และรูปใน /public
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:png|jpg|jpeg|gif|svg|webp|ico)$).*)",
  ],
};
