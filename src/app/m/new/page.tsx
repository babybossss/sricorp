import { MobileTxForm } from "@/components/mobile/mobile-tx-form";
import { ReferenceProvider } from "@/components/reference/reference-provider";
import { PermissionsProvider } from "@/components/auth/permissions-provider";
import { gateRoute } from "@/lib/auth/gate";
import { getAccess } from "@/lib/auth/session";
import { loadReference } from "@/lib/db/reference";

export default async function MobileNewPage() {
  // กั้นตามสิทธิ์ (ความสะดวก ไม่ใช่ความปลอดภัย — RLS คือของจริง · ดู src/lib/auth/gate.tsx)
  const denied = await gateRoute("/m/new", "บันทึกรายการ");
  if (denied) return denied;

  // หน้านี้ไม่ผ่าน PageShell จึงต้องส่งข้อมูลอ้างอิงจริงและสิทธิ์ลงไปเอง
  const [reference, access] = await Promise.all([loadReference(), getAccess()]);

  return (
    <PermissionsProvider permissions={[...access.permissions]}>
      <ReferenceProvider state={reference}>
        <MobileTxForm />
      </ReferenceProvider>
    </PermissionsProvider>
  );
}
