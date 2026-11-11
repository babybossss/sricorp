import { PageShell } from "@/components/layout/page-shell";
import { LedgerTabs } from "@/components/ledger/ledger-tabs";
import { gateRoute } from "@/lib/auth/gate";
import { loadLedgerEntries } from "@/lib/db/ledger-entries-server";
import { loadPendingAccruals } from "@/lib/db/pending-accruals-server";

export default async function LedgerPage() {
  // กั้นตามสิทธิ์ (ความสะดวก ไม่ใช่ความปลอดภัย — RLS คือของจริง · ดู src/lib/auth/gate.tsx)
  const denied = await gateRoute("/ledger", "สมุดบัญชี (Ledger)");
  if (denied) return denied;

  // รายการสมุดอ่านจาก v_ledger_posted เท่านั้น (D-107) — ห้ามอ่านตาราง transactions ตรง
  const [ledger, pending] = await Promise.all([loadLedgerEntries(), loadPendingAccruals()]);

  return (
    <PageShell title="สมุดบัญชี (Ledger)">
      <LedgerTabs ledger={ledger} pending={pending} />
    </PageShell>
  );
}
