import { PageShell } from "@/components/layout/page-shell";
import { AssetManager } from "@/components/assets/asset-manager";
import { gateRoute } from "@/lib/auth/gate";
import { getAccess } from "@/lib/auth/session";

export default async function AssetsPage() {
  // กั้นตามสิทธิ์ (ความสะดวก ไม่ใช่ความปลอดภัย — RLS คือของจริง · ดู src/lib/auth/gate.tsx)
  const denied = await gateRoute("/assets", "บริหารสินทรัพย์");
  if (denied) return denied;

  // ใช้แยก "ร่างของฉัน" ในคิวร่าง · ถามครั้งเดียวต่อ request (react cache เดียวกับตัวกั้น)
  const { user, profile } = await getAccess();
  const currentUser = { id: user?.id ?? "", name: profile?.displayName ?? user?.email ?? "ผู้ใช้" };

  return (
    <PageShell title="บริหารสินทรัพย์">
      <AssetManager currentUser={currentUser} />
    </PageShell>
  );
}
