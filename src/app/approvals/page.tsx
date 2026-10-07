import { PageShell } from "@/components/layout/page-shell";
import { ApprovalQueue } from "@/components/approvals/approval-queue";
import { gateRoute } from "@/lib/auth/gate";

export default async function ApprovalsPage() {
  // กั้นตามสิทธิ์ (ความสะดวก ไม่ใช่ความปลอดภัย — RLS คือของจริง · ดู src/lib/auth/gate.tsx)
  const denied = await gateRoute("/approvals", "คิวอนุมัติ");
  if (denied) return denied;

  return (
    <PageShell title="คิวอนุมัติ">
      <ApprovalQueue />
    </PageShell>
  );
}
