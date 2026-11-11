import { PageShell } from "@/components/layout/page-shell";
import { ApprovalQueue } from "@/components/approvals/approval-queue";
import { Notice } from "@/components/assets/asset-parts";
import { gateRoute } from "@/lib/auth/gate";
import { getAccess } from "@/lib/auth/session";
import { loadApprovals } from "@/lib/db/approvals-server";

/** คิวอนุมัติ — ร่างจริงจาก draft_entries · ใครเห็นร่างไหนให้ RLS ตัดสิน */
export default async function ApprovalsPage() {
  // กั้นตามสิทธิ์ (ความสะดวก ไม่ใช่ความปลอดภัย — RLS คือของจริง · ดู src/lib/auth/gate.tsx)
  const denied = await gateRoute("/approvals", "คิวอนุมัติ");
  if (denied) return denied;

  const [data, access] = await Promise.all([loadApprovals(), getAccess()]);

  return (
    <PageShell title="คิวอนุมัติ">
      {data.ok ? (
        <ApprovalQueue
          items={data.items}
          owners={data.owners}
          assetNames={data.assetNames}
          contactNames={data.contactNames}
          currentUserId={access.user?.id ?? ""}
        />
      ) : (
        <Notice tone="neg">
          โหลดคิวอนุมัติจากฐานข้อมูลไม่สำเร็จ จึงไม่แสดงรายการให้ (ไม่แสดงข้อมูลครึ่งเดียว): {data.error}
          <div className="mt-1 text-sm">ลองโหลดหน้านี้ใหม่ ถ้ายังไม่ได้ให้แจ้งผู้ดูแลระบบ</div>
        </Notice>
      )}
    </PageShell>
  );
}
