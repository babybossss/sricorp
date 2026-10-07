import { MobileTxForm } from "@/components/mobile/mobile-tx-form";
import { gateRoute } from "@/lib/auth/gate";

export default async function MobileNewPage() {
  // กั้นตามสิทธิ์ (ความสะดวก ไม่ใช่ความปลอดภัย — RLS คือของจริง · ดู src/lib/auth/gate.tsx)
  const denied = await gateRoute("/m/new", "บันทึกรายการ");
  if (denied) return denied;

  return <MobileTxForm />;
}
