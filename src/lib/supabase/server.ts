import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import { DB_SCHEMA, requireSupabaseEnv } from "./env";

/**
 * Supabase client ฝั่ง server (server component · route handler · server action)
 *
 * - `cookies()` ของ Next 15 เป็น async → ต้อง await
 * - ใช้ publishable key + session ของผู้ใช้ → ทุก query ผ่าน RLS ในฐานะผู้ใช้คนนั้น
 *   **ห้ามสร้าง client ที่ใช้สิทธิ์สูงกว่าผู้ใช้** — รวมถึงฝั่ง server ด้วย
 * - สร้างใหม่ทุก request (ห้ามเก็บเป็นตัวแปร global) ไม่งั้น session ของคนหนึ่งรั่วไปอีกคน
 */
export async function createClient() {
  // อ่าน cookie ก่อนเช็ค env เสมอ — การเรียก cookies() คือสิ่งที่บอก Next ว่าหน้านี้ขึ้นกับผู้ใช้
  // ต้อง render ตอนมี request ไม่ใช่ prerender ตอน build (ไม่งั้นหน้า "ไม่มีสิทธิ์"/หน้าที่ผ่านตัวกั้น
  // อาจถูกเก็บเป็น HTML static แล้วเสิร์ฟให้ทุกคน)
  const cookieStore = await cookies();
  const { url, key } = requireSupabaseEnv();

  return createServerClient(url, key, {
    db: { schema: DB_SCHEMA },
    cookies: {
      getAll() {
        return cookieStore.getAll();
      },
      setAll(cookiesToSet) {
        try {
          cookiesToSet.forEach(({ name, value, options }) => cookieStore.set(name, value, options));
        } catch {
          // เรียกจาก server component ซึ่งเขียน cookie ไม่ได้ — ไม่เป็นไร
          // เพราะ middleware ต่ออายุ session ให้ทุก request อยู่แล้ว
        }
      },
    },
  });
}
