import { PageShell } from "@/components/layout/page-shell";
import { LedgerTabs } from "@/components/ledger/ledger-tabs";
import { gateRoute } from "@/lib/auth/gate";

export default async function LedgerPage() {
  // กั้นตามสิทธิ์ (ความสะดวก ไม่ใช่ความปลอดภัย — RLS คือของจริง · ดู src/lib/auth/gate.tsx)
  const denied = await gateRoute("/ledger", "สมุดบัญชี (Ledger)");
  if (denied) return denied;

  return (
    <PageShell title="สมุดบัญชี (Ledger)">
      <LedgerTabs />
    </PageShell>
  );
}
