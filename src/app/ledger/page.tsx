import { PageShell } from "@/components/layout/page-shell";
import { LedgerTabs } from "@/components/ledger/ledger-tabs";

export default function LedgerPage() {
  return (
    <PageShell title="สมุดบัญชี (Ledger)">
      <LedgerTabs />
    </PageShell>
  );
}
