import { Sidebar } from "./sidebar";
import { Topbar } from "./topbar";
import { Toast } from "./toast";
import { PermissionsProvider } from "@/components/auth/permissions-provider";
import { ReferenceProvider } from "@/components/reference/reference-provider";
import { getAccess } from "@/lib/auth/session";
import { loadReference } from "@/lib/db/reference";

/**
 * โครงหน้าเดียวกันทุกหน้า: sidebar 256px + top bar 72px + main 24px
 *
 * เป็น server component: ถาม DB ว่าผู้ใช้ที่ล็อกอินมีสิทธิ์อะไร (ครั้งเดียวต่อ request)
 * แล้วส่งลงไปซ่อนเมนู/ปุ่มที่กดไม่ได้ — เพื่อความสะดวก ไม่ใช่ความปลอดภัย (RLS คือของจริง)
 */
export async function PageShell({ title, children }: { title: string; children: React.ReactNode }) {
  const access = await getAccess();
  const permissions = [...access.permissions];
  // ผู้ถือ · บัญชี · ทรัพย์ · ผู้ติดต่อ จริงจาก DB (ผ่าน RLS ของผู้ใช้) — โหลดไม่ได้ = ฟอร์มบอกเหตุผล ไม่ใช้ข้อมูลจำลอง
  const reference = await loadReference();

  return (
    <PermissionsProvider permissions={permissions}>
      <ReferenceProvider state={reference}>
        <div className="flex min-h-screen items-start">
          <Sidebar />
          <div className="flex min-w-0 flex-1 flex-col">
            <Topbar
              title={title}
              user={{
                name: access.profile?.displayName ?? access.user?.email ?? "ผู้ใช้",
                role: access.profile?.roleLabel ?? access.profile?.roleKey ?? "ยังไม่ได้ลงทะเบียน",
              }}
            />
            <main className="w-full max-w-[1368px] p-6">{children}</main>
          </div>
          <Toast />
        </div>
      </ReferenceProvider>
    </PermissionsProvider>
  );
}
