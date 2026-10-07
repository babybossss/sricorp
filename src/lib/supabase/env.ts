/**
 * อ่าน env ของ Supabase ที่เดียว
 *
 * - **publishable key เท่านั้น** (ชื่อเดิม anon key) — ไฟล์นี้ปฏิเสธคีย์ชนิด secret / service role
 *   ถ้าเผลอใส่มา เพราะคีย์พวกนั้นข้าม RLS ทั้งหมด = เห็นเงินทุกคนในบ้าน
 * - env ไม่ครบ → คืนรายการชื่อที่ขาด เพื่อให้หน้าจอบอกว่าต้องตั้งอะไร
 *   **ห้ามตกกลับไปใช้ข้อมูลจำลองเงียบๆ**
 * - ต้องอ้าง `process.env.NEXT_PUBLIC_*` แบบสะกดเต็ม ไม่งั้น Next ไม่ inline ให้ฝั่ง browser
 */

export type SupabaseEnv = { url: string; key: string };

export type EnvCheck =
  | { ok: true; env: SupabaseEnv }
  | { ok: false; problems: string[] };

/** schema ที่ตารางของ SRI OS อยู่ — ไม่ใช่ public */
export const DB_SCHEMA = "sri_os" as const;

/** ถอด payload ของ JWT (legacy key) โดยไม่ตรวจลายเซ็น — ใช้แค่ดูว่าเป็น role อะไร */
function jwtRole(key: string): string | null {
  const parts = key.split(".");
  if (parts.length !== 3) return null;
  try {
    const b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const json = atob(b64.padEnd(Math.ceil(b64.length / 4) * 4, "="));
    const role = (JSON.parse(json) as { role?: unknown }).role;
    return typeof role === "string" ? role : null;
  } catch {
    return null;
  }
}

export function checkSupabaseEnv(
  url: string | undefined,
  key: string | undefined
): EnvCheck {
  const problems: string[] = [];

  if (!url) problems.push("NEXT_PUBLIC_SUPABASE_URL");
  else if (!/^https?:\/\//.test(url)) problems.push("NEXT_PUBLIC_SUPABASE_URL (ต้องขึ้นต้นด้วย https://)");

  if (!key) {
    problems.push("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY");
  } else if (key.startsWith("sb_secret_") || jwtRole(key) === "service_role") {
    problems.push(
      "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY (เป็นคีย์ชนิด secret/service role — ห้ามใช้ ให้ใส่ publishable key)"
    );
  }

  if (problems.length || !url || !key) return { ok: false, problems };
  return { ok: true, env: { url, key } };
}

/**
 * ชื่อ `..._ANON_KEY` ยังรับไว้เป็นชื่อสำรอง เพราะโปรเจกต์ Supabase รุ่นเก่าเรียกคีย์เดียวกันนี้ว่า anon
 */
export function readSupabaseEnv(): EnvCheck {
  return checkSupabaseEnv(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY
  );
}

/** ใช้ในที่ที่ต้องการ client จริง — env ผิดแล้วโยน error ที่บอกชื่อที่ขาด */
export function requireSupabaseEnv(): SupabaseEnv {
  const r = readSupabaseEnv();
  if (!r.ok) {
    throw new Error(
      `ตั้งค่า Supabase ไม่ครบ: ${r.problems.join(", ")} — ดู .env.example แล้วตั้งใน .env.local (และใน Vercel → Settings → Environment Variables)`
    );
  }
  return r.env;
}
