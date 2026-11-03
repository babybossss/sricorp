import { PageShell } from "@/components/layout/page-shell";
import { SettingsLayout } from "@/components/settings/settings-nav";
import { FxRatesPanel } from "@/components/settings/fx-rates";
import { Notice } from "@/components/reports/parts";
import { gateRoute } from "@/lib/auth/gate";
import { listFxRates } from "@/app/actions/fx-rates";

export const dynamic = "force-dynamic";

export default async function FxRatesPage() {
  // กั้นตามสิทธิ์ (ความสะดวก ไม่ใช่ความปลอดภัย — RLS คือของจริง · ดู src/lib/auth/gate.tsx)
  const denied = await gateRoute("/settings", "ตั้งค่า · อัตราแลกเปลี่ยน");
  if (denied) return denied;

  const list = await listFxRates();
  return (
    <PageShell title="ตั้งค่า · อัตราแลกเปลี่ยน">
      <SettingsLayout>
        {list.ok ? (
          <FxRatesPanel rows={list.rows} />
        ) : (
          <Notice tone="neg">
            โหลดอัตราแลกเปลี่ยนจากฐานข้อมูลไม่สำเร็จ: {list.message}
            <div className="mt-1">ลองโหลดหน้านี้ใหม่ ถ้ายังไม่ได้ให้แจ้งผู้ดูแลระบบ — ระบบไม่แสดงอัตราจำลองแทน</div>
          </Notice>
        )}
      </SettingsLayout>
    </PageShell>
  );
}
