import { PageShell } from "@/components/layout/page-shell";
import { BalanceTree } from "@/components/balance/balance-tree";
import { gateRoute } from "@/lib/auth/gate";

export default async function BalancePage() {
  // กั้นตามสิทธิ์ (ความสะดวก ไม่ใช่ความปลอดภัย — RLS คือของจริง · ดู src/lib/auth/gate.tsx)
  const denied = await gateRoute("/balance", "งบดุล & ทรัพย์สิน");
  if (denied) return denied;

  return (
    <PageShell title="งบดุล & ทรัพย์สิน">
      <BalanceTree />
    </PageShell>
  );
}
