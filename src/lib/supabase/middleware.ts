import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { DB_SCHEMA, readSupabaseEnv } from "./env";

/**
 * ต่ออายุ session + บอกว่าล็อกอินอยู่หรือยัง — **แค่นั้น**
 *
 * ห้ามเช็คสิทธิ์ละเอียดที่นี่: middleware รันบน edge และเชื่อ cookie ไม่ได้เท่าการถาม DB
 * การกั้นตามสิทธิ์อยู่ใน server component ของแต่ละหน้า (src/lib/auth/gate.tsx)
 * และความปลอดภัยจริงอยู่ที่ RLS
 */

/** เส้นทางที่เข้าได้โดยไม่ต้องล็อกอิน */
const PUBLIC_PATHS = ["/login", "/auth/callback"];

const isPublic = (path: string) => PUBLIC_PATHS.some((p) => path === p || path.startsWith(p + "/"));

export async function updateSession(request: NextRequest): Promise<NextResponse> {
  const { pathname } = request.nextUrl;
  const envCheck = readSupabaseEnv();

  // env ไม่ครบ = เช็คล็อกอินไม่ได้ → ส่งทุกอย่างไป /login ซึ่งมีข้อความบอกว่าต้องตั้งค่าอะไร
  // (ไม่ปล่อยผ่าน และไม่ใช้ข้อมูลจำลองแทน)
  if (!envCheck.ok) {
    if (pathname === "/login") return NextResponse.next({ request });
    return pathname.startsWith("/api/")
      ? NextResponse.json({ error: "ตั้งค่า Supabase ไม่ครบ" }, { status: 503 })
      : NextResponse.redirect(new URL("/login", request.url));
  }

  let response = NextResponse.next({ request });

  const supabase = createServerClient(envCheck.env.url, envCheck.env.key, {
    db: { schema: DB_SCHEMA },
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(cookiesToSet, headers) {
        cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value));
        response = NextResponse.next({ request });
        cookiesToSet.forEach(({ name, value, options }) => response.cookies.set(name, value, options));
        // header กัน CDN เก็บ response ที่มี cookie ของ session ไว้ให้คนอื่น
        Object.entries(headers).forEach(([k, v]) => response.headers.set(k, v));
      },
    },
  });

  // getClaims() ตรวจลายเซ็น JWT และต่ออายุ session — ห้ามคั่นอะไรระหว่าง createServerClient กับบรรทัดนี้
  const { data } = await supabase.auth.getClaims();
  const signedIn = Boolean(data?.claims);

  /** redirect แต่พก cookie ที่เพิ่งต่ออายุไปด้วย ไม่งั้น session หลุดกลางทาง */
  const redirectTo = (url: URL) => {
    const r = NextResponse.redirect(url);
    response.cookies.getAll().forEach((c) => r.cookies.set(c));
    response.headers.forEach((v, k) => {
      if (k === "cache-control" || k === "expires" || k === "pragma") r.headers.set(k, v);
    });
    return r;
  };

  if (!signedIn && !isPublic(pathname)) {
    if (pathname.startsWith("/api/")) {
      return NextResponse.json({ error: "ยังไม่ได้เข้าสู่ระบบ" }, { status: 401 });
    }
    const url = new URL("/login", request.url);
    // จำหน้าที่ตั้งใจจะไป เพื่อกลับมาหลังล็อกอิน (callback ตรวจอีกชั้นว่าเป็นทางภายใน)
    if (pathname !== "/") url.searchParams.set("next", pathname + request.nextUrl.search);
    return redirectTo(url);
  }

  if (signedIn && pathname === "/login") {
    return redirectTo(new URL("/dashboard", request.url));
  }

  return response;
}
