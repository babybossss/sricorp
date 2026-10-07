import { createBrowserClient } from "@supabase/ssr";
import { DB_SCHEMA, requireSupabaseEnv } from "./env";

/**
 * Supabase client ฝั่ง browser — ใช้ publishable key เท่านั้น
 * ทุกอย่างที่ query ผ่านตัวนี้ถูก RLS กรองตามผู้ใช้ที่ล็อกอินอยู่
 */
export function createClient() {
  const { url, key } = requireSupabaseEnv();
  return createBrowserClient(url, key, { db: { schema: DB_SCHEMA } });
}
