import { PageShell } from "@/components/layout/page-shell";
import { AssetManager } from "@/components/assets/asset-manager";
import { gateRoute } from "@/lib/auth/gate";

export default async function AssetsPage() {
  // กั้นตามสิทธิ์ (ความสะดวก ไม่ใช่ความปลอดภัย — RLS คือของจริง · ดู src/lib/auth/gate.tsx)
  const denied = await gateRoute("/assets", "บริหารสินทรัพย์");
  if (denied) return denied;

  return (
    <PageShell title="บริหารสินทรัพย์">
      <AssetManager />
    </PageShell>
  );
}
