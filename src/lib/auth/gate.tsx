import * as React from "react";
import { redirect } from "next/navigation";
import { PageShell } from "@/components/layout/page-shell";
import { NoAccess, type NoAccessReason } from "@/components/auth/no-access";
import { createClient } from "@/lib/supabase/server";
import { getAccess } from "./session";
import { ROUTE_ACCESS, hasAccess, type GatedRoute } from "./routes";

/**
 * ตัวกั้นหน้าตามสิทธิ์ — เรียกบนสุดของ server component ของแต่ละหน้า
 *
 *   const denied = await gateRoute("/balance", "งบดุล & ทรัพย์สิน");
 *   if (denied) return denied;
 *
 * คืนหน้า "ไม่มีสิทธิ์" (พร้อมบอกว่าต้องขอใคร) หรือ null ถ้าผ่าน
 *
 * **นี่คือความสะดวก ไม่ใช่ความปลอดภัย**: ความปลอดภัยจริงอยู่ที่ RLS ใน DB
 * - อย่าใช้ว่า "หน้านี้กั้นแล้ว" เป็นเหตุผลให้ query ฝั่ง server ไม่กรอง
 * - query ในหน้าที่ผ่านตัวกั้นต้องใช้ `@/lib/supabase/server` (session ของผู้ใช้) เท่านั้น
 *   ห้ามใช้สิทธิ์ที่สูงกว่าผู้ใช้ ไม่งั้นการกั้นหน้าจอกลายเป็นด่านเดียวที่เหลือ
 */
export async function gateRoute(route: GatedRoute, title: string): Promise<React.ReactElement | null> {
  const access = await getAccess();

  // middleware ควรกันไว้แล้ว — กันซ้ำเผื่อ session หมดอายุระหว่างทาง
  if (!access.user && !access.error) redirect("/login");

  const rule = ROUTE_ACCESS[route];
  if (!access.error && hasAccess(access.permissions, rule)) return null;

  let reason: NoAccessReason;
  if (access.error) {
    reason = { kind: "error", detail: access.error };
  } else if (access.permissions.size === 0 && !access.profile) {
    reason = { kind: "not-registered", email: access.user?.email ?? null };
  } else {
    const anyOf: readonly string[] = ("anyOf" in rule ? rule.anyOf : undefined) ?? [];
    const allOf: readonly string[] = ("allOf" in rule ? rule.allOf : undefined) ?? [];
    // anyOf และ allOf พร้อมกัน: แสดงทั้งหมด โหมด "ครบ" ปลอดภัยกว่าบอกว่าอย่างใดอย่างหนึ่ง
    const mode = anyOf.length && !allOf.length ? "any" : "all";
    reason = { kind: "lacks", mode, needed: await labelsOf([...anyOf, ...allOf]) };
  }

  return (
    <PageShell title={title}>
      <NoAccess reason={reason} />
    </PageShell>
  );
}

/** ชื่อสิทธิ์ภาษาไทยอ่านจากตาราง `permissions` ใน DB — ไม่คัดลอกชื่อมาไว้ใน TS */
async function labelsOf(keys: string[]): Promise<{ key: string; label: string }[]> {
  const fallback = keys.map((key) => ({ key, label: key }));
  try {
    const supabase = await createClient();
    const { data, error } = await supabase.from("permissions").select("key, label").in("key", keys);
    if (error || !data) return fallback;
    const byKey = new Map(data.map((r: { key: string; label: string }) => [r.key, r.label]));
    return keys.map((key) => ({ key, label: byKey.get(key) ?? key }));
  } catch {
    return fallback;
  }
}
