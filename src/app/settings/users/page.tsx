import { PageShell } from "@/components/layout/page-shell";
import { SettingsLayout } from "@/components/settings/settings-nav";
import { Notice } from "@/components/assets/asset-parts";
import { gateRoute } from "@/lib/auth/gate";
import { getAccess } from "@/lib/auth/session";
import { UsersTable } from "./users-table";
import { loadUsers } from "./users-data";

export default async function UsersPage() {
  // กั้นตามสิทธิ์ (ความสะดวก ไม่ใช่ความปลอดภัย — RLS คือของจริง · ดู src/lib/auth/gate.tsx)
  const denied = await gateRoute("/settings/users", "ตั้งค่า · ผู้ใช้ & สิทธิ์");
  if (denied) return denied;

  const [data, access] = await Promise.all([loadUsers(), getAccess()]);

  return (
    <PageShell title="ตั้งค่า · ผู้ใช้ & สิทธิ์">
      <SettingsLayout>
        <div className="rounded-card border border-brand-100 bg-brand-50 p-[16px_18px] text-base leading-7">
          การเพิ่มผู้ใช้ใหม่ทำที่ Supabase (Authentication → Invite user) ก่อน แล้วจึงกำหนดระดับสิทธิ์ที่นี่ — ผู้ที่ล็อกอินแล้วแต่ยังไม่มีระดับ จะเข้าระบบแล้วไม่เห็นอะไร (ตั้งใจ)
          ระดับสิทธิ์แต่ละระดับทำอะไรได้ ดูจากตารางสิทธิ์ในฐานข้อมูล
        </div>
        {data.ok ? (
          <UsersTable
            users={data.users}
            roles={data.roles}
            owners={data.owners}
            currentUserId={access.user?.id ?? ""}
            canManage={access.permissions.has("users.manage")}
          />
        ) : (
          <Notice tone="neg">โหลดรายชื่อผู้ใช้จากฐานข้อมูลไม่สำเร็จ จึงไม่แสดงรายการให้: {data.error}</Notice>
        )}
      </SettingsLayout>
    </PageShell>
  );
}
