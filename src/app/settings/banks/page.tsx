import { PageShell } from "@/components/layout/page-shell";
import { SettingsLayout } from "@/components/settings/settings-nav";
import { BankSettings } from "@/components/settings/bank-settings";
import { gateRoute } from "@/lib/auth/gate";

export default async function BanksPage() {
  // กั้นตามสิทธิ์ (ความสะดวก ไม่ใช่ความปลอดภัย — RLS คือของจริง · ดู src/lib/auth/gate.tsx)
  const denied = await gateRoute("/settings", "ตั้งค่า · บัญชีธนาคาร");
  if (denied) return denied;

  return (
    <PageShell title="ตั้งค่า · บัญชีธนาคาร">
      <SettingsLayout>
        <BankSettings />
      </SettingsLayout>
    </PageShell>
  );
}
