import { Sidebar } from "./sidebar";
import { Topbar } from "./topbar";
import { MobileNav } from "./mobile-nav";
import { Toast } from "./toast";
import { PermissionsProvider } from "@/components/auth/permissions-provider";
import { ReferenceProvider } from "@/components/reference/reference-provider";
import { getAccess } from "@/lib/auth/session";
import { loadReference } from "@/lib/db/reference";
import { countPendingApprovals } from "@/lib/db/approvals-server";

/**
 * โครงหน้าเดียวกันทุกหน้า: sidebar 256px + top bar 72px + main 24px
 *
 * เป็น server component: ถาม DB ว่าผู้ใช้ที่ล็อกอินมีสิทธิ์อะไร (ครั้งเดียวต่อ request)
 * แล้วส่งลงไปซ่อนเมนู/ปุ่มที่กดไม่ได้ — เพื่อความสะดวก ไม่ใช่ความปลอดภัย (RLS คือของจริง)
 */
export async function PageShell({ title, children }: { title: string; children: React.ReactNode }) {
  // สองอย่างนี้ไม่พึ่งกัน → ถามพร้อมกัน (ต่อหน้าเสียเวลารอเท่าตัวที่ช้ากว่า ไม่ใช่รวมกัน) · ทั้งคู่แคชต่อ request อยู่แล้ว
  // ผู้ถือ · บัญชี · ทรัพย์ · ผู้ติดต่อ จริงจาก DB (ผ่าน RLS ของผู้ใช้) — โหลดไม่ได้ = ฟอร์มบอกเหตุผล ไม่ใช้ข้อมูลจำลอง
  // ตัวนับคิวอนุมัติไม่พึ่งอีกสองตัว → ถามพร้อมกัน · อ่านไม่ได้ = null และป้ายจะไม่ขึ้น
  // (ห้ามแปลงเป็น 0 เพราะ 0 แปลว่า "ไม่มีอะไรรออนุมัติ" ซึ่งคนละเรื่องกับ "ยังไม่รู้")
  const [access, reference, pendingApprovals] = await Promise.all([getAccess(), loadReference(), countPendingApprovals()]);
  const permissions = [...access.permissions];

  return (
    <PermissionsProvider permissions={permissions}>
      <ReferenceProvider state={reference}>
        <div className="flex min-h-screen items-start">
          <Sidebar pendingApprovals={pendingApprovals} />
          <div className="flex min-w-0 flex-1 flex-col">
            <Topbar
              title={title}
              pendingApprovals={pendingApprovals}
              user={{
                name: access.profile?.displayName ?? access.user?.email ?? "ผู้ใช้",
                role: access.profile?.roleLabel ?? access.profile?.roleKey ?? "ยังไม่ได้ลงทะเบียน",
              }}
            />
            {/* จอแคบกว่า lg: Sidebar ถูกซ่อน เมนูนี้แทนที่ (รายการเดียวกัน กรองสิทธิ์เดียวกัน) */}
            <MobileNav pendingApprovals={pendingApprovals} />
            <main className="w-full max-w-[1368px] p-4 sm:p-6">{children}</main>
          </div>
          <Toast />
        </div>
      </ReferenceProvider>
    </PermissionsProvider>
  );
}
