import { PageShell } from "@/components/layout/page-shell";
import { AssetManager } from "@/components/assets/asset-manager";
import { Notice } from "@/components/assets/asset-parts";
import { gateRoute } from "@/lib/auth/gate";
import { loadAssetRegister } from "@/lib/db/assets-server";

/**
 * บริหารสินทรัพย์ — ทะเบียนจริง + ตัวเลขรายชิ้นจากสมุดบัญชี (คำนวณสดทุกครั้ง)
 * แถวที่เห็นให้ RLS กรองตามผู้ใช้ ห้ามกรองสิทธิ์ใน TS · กรองตามผู้ถือด้วย `?owner=` (ไม่ใส่ = มุมมองรวม)
 */
export default async function AssetsPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  // กั้นตามสิทธิ์ (ความสะดวก ไม่ใช่ความปลอดภัย — RLS คือของจริง · ดู src/lib/auth/gate.tsx)
  const denied = await gateRoute("/assets", "บริหารสินทรัพย์");
  if (denied) return denied;

  const sp = await searchParams;
  const owner = Array.isArray(sp.owner) ? sp.owner[0] : sp.owner;
  const data = await loadAssetRegister();

  return (
    <PageShell title="บริหารสินทรัพย์">
      {data.ok ? (
        <AssetManager data={data} initialOwner={owner} />
      ) : (
        <Notice tone="neg">
          โหลดทะเบียนทรัพย์จากฐานข้อมูลไม่สำเร็จ จึงไม่แสดงตัวเลขให้ (ไม่แสดงข้อมูลครึ่งเดียว): {data.error}
          <div className="mt-1 text-sm">ลองโหลดหน้านี้ใหม่ ถ้ายังไม่ได้ให้แจ้งผู้ดูแลระบบ</div>
        </Notice>
      )}
    </PageShell>
  );
}
