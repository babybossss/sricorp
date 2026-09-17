import { PageShell } from "@/components/layout/page-shell";
import { BalanceTree } from "@/components/balance/balance-tree";

export default function BalancePage() {
  return (
    <PageShell title="งบดุล & ทรัพย์สิน">
      <BalanceTree />
    </PageShell>
  );
}
