import { createClient } from "@/lib/supabase/server";
import { loadReference } from "@/lib/db/reference";
import { fetchAllPages } from "@/lib/db/paged";
import type { RefOwner } from "@/lib/db/reference-types";

/**
 * รายชื่อผู้ใช้จริงจาก `sri_os.app_users` — ใครอ่านแถวไหนได้ให้ RLS `users_read` ตัดสิน
 * (ตัวเอง · users.manage · owner.view_all) ไม่กรองสิทธิ์ใน TS · ผ่าน `fetchAllPages`
 *
 * **ไม่มี "เข้าใช้ล่าสุด"** — ข้อมูลนั้นอยู่ใน `auth.users` ซึ่งแอปอ่านไม่ได้ (ไม่แสดงค่าที่ไม่รู้จริง)
 */
type Db = Awaited<ReturnType<typeof createClient>>;

export type UserRow = {
  id: string;
  email: string;
  displayName: string;
  role: string;
  isActive: boolean;
  createdAt: string;
  /** ผู้ถือที่ผู้ใช้นี้ถูกให้เห็น (user_owner_access) */
  ownerIds: string[];
};
export type RoleRow = { key: string; label: string; rank: number };

export type UsersData =
  | { ok: true; users: UserRow[]; roles: RoleRow[]; owners: RefOwner[] }
  | { ok: false; error: string };

export async function loadUsersFrom(db: Db, owners: RefOwner[]): Promise<UsersData> {
  const users = await fetchAllPages<{ id: string; email: string; display_name: string; role: string; is_active: boolean; created_at: string }>(
    () => db.from("app_users").select("id, email, display_name, role, is_active, created_at").order("created_at", { ascending: true }).order("id", { ascending: true }) as never
  );
  if (!users.ok) return { ok: false, error: `อ่านรายชื่อผู้ใช้ไม่สำเร็จ (${users.error})` };
  const roles = await db.from("roles").select("key, label, rank_order").order("rank_order", { ascending: true });
  if (roles.error) return { ok: false, error: `อ่านระดับสิทธิ์ไม่สำเร็จ (${roles.error.message})` };
  const access = await fetchAllPages<{ user_id: string; owner_id: string }>(
    () => db.from("user_owner_access").select("user_id, owner_id").order("user_id", { ascending: true }).order("owner_id", { ascending: true }) as never
  );
  if (!access.ok) return { ok: false, error: `อ่านขอบเขตผู้ถือของผู้ใช้ไม่สำเร็จ (${access.error})` };

  const byUser = new Map<string, string[]>();
  for (const a of access.rows) byUser.set(a.user_id, [...(byUser.get(a.user_id) ?? []), a.owner_id]);
  return {
    ok: true,
    users: users.rows.map((u) => ({
      id: u.id,
      email: u.email,
      displayName: u.display_name,
      role: u.role,
      isActive: u.is_active,
      createdAt: u.created_at,
      ownerIds: byUser.get(u.id) ?? [],
    })),
    roles: ((roles.data ?? []) as { key: string; label: string; rank_order: number }[]).map((r) => ({ key: r.key, label: r.label, rank: r.rank_order })),
    owners,
  };
}

export async function loadUsers(): Promise<UsersData> {
  const ref = await loadReference();
  if (!ref.ok) return { ok: false, error: ref.error };
  let db: Db;
  try {
    db = await createClient();
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
  return loadUsersFrom(db, ref.ref.owners);
}
