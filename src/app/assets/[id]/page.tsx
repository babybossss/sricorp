import { PageShell } from "@/components/layout/page-shell";
import { AssetDetail } from "@/components/assets/asset-detail";
import { Notice } from "@/components/assets/asset-parts";
import { gateRoute } from "@/lib/auth/gate";
import { loadAssetDetail } from "@/lib/db/assets-server";
import { loadReference } from "@/lib/db/reference";
import { contactFullName } from "@/lib/db/reference-types";

export default async function AssetPage({ params }: { params: Promise<{ id: string }> }) {
  // กั้นก่อนค้นทรัพย์ และใช้ชื่อหน้ากลางๆ — หน้า "ไม่มีสิทธิ์" ต้องไม่เผยชื่อทรัพย์
  // แถวทรัพย์ที่เห็นจริงให้ RLS กรอง (fn_assets_visible) · ห้ามกรองใน TS
  // กั้นตามสิทธิ์ (ความสะดวก ไม่ใช่ความปลอดภัย — RLS คือของจริง · ดู src/lib/auth/gate.tsx)
  const denied = await gateRoute("/assets", "บริหารสินทรัพย์");
  if (denied) return denied;

  const { id } = await params;
  const data = await loadAssetDetail(id);

  if (!data.ok) {
    return (
      <PageShell title="บริหารสินทรัพย์">
        <Notice tone="neg">โหลดข้อมูลทรัพย์จากฐานข้อมูลไม่สำเร็จ จึงไม่แสดงตัวเลขให้: {data.error}</Notice>
      </PageShell>
    );
  }
  // ไม่มีทรัพย์นี้ กับ มองไม่เห็น (RLS) ตอบเหมือนกัน — ไม่บอกว่าทรัพย์นี้มีอยู่หรือไม่
  if (data.asset === null) {
    return (
      <PageShell title="บริหารสินทรัพย์">
        <Notice tone="warn">ไม่พบทรัพย์นี้ในทะเบียนที่คุณมีสิทธิ์เห็น</Notice>
      </PageShell>
    );
  }

  const ref = await loadReference();
  const contactNames = ref.ok ? Object.fromEntries(ref.ref.contacts.map((c) => [c.id, contactFullName(c)])) : {};

  return (
    <PageShell title={data.asset.name}>
      <AssetDetail data={data} contactNames={contactNames} />
    </PageShell>
  );
}
