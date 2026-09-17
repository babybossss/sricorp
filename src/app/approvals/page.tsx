import { PageShell } from "@/components/layout/page-shell";
import { ApprovalQueue } from "@/components/approvals/approval-queue";

export default function ApprovalsPage() {
  return (
    <PageShell title="คิวอนุมัติ">
      <ApprovalQueue />
    </PageShell>
  );
}
