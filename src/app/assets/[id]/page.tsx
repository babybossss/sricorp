import { PageShell } from "@/components/layout/page-shell";
import { AssetDetail } from "@/components/assets/asset-detail";
import { ASSETS } from "@/lib/mock/assets";
import { gateRoute } from "@/lib/auth/gate";

export default async function AssetPage({ params }: { params: Promise<{ id: string }> }) {
  // กั้นก่อนค้นทรัพย์ และใช้ชื่อหน้ากลางๆ — หน้า "ไม่มีสิทธิ์" ต้องไม่เผยชื่อทรัพย์
  // แถวทรัพย์ที่เห็นจริงให้ RLS กรอง (assets.manager_user_id) · ห้ามกรองใน TS
  // กั้นตามสิทธิ์ (ความสะดวก ไม่ใช่ความปลอดภัย — RLS คือของจริง · ดู src/lib/auth/gate.tsx)
  const denied = await gateRoute("/assets", "บริหารสินทรัพย์");
  if (denied) return denied;

  const { id } = await params;
  const asset = ASSETS.find((a) => a.id === id) ?? ASSETS[0];

  return (
    <PageShell title={asset.name}>
      <AssetDetail name={asset.name} />
    </PageShell>
  );
}
