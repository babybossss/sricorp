import { PageShell } from "@/components/layout/page-shell";
import { DashboardView } from "@/components/dashboard/dashboard-view";
import { loadDashboard } from "@/components/dashboard/dashboard-data";
import { Notice } from "@/components/assets/asset-parts";
import { gateRoute } from "@/lib/auth/gate";

/** หน้าแรก — ข้อมูลจริงจากสมุดบัญชี (RLS กรองตามผู้ใช้) · กรองตามผู้ถือด้วย ?owner= และปีด้วย ?year= */
export default async function DashboardPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  // กั้นตามสิทธิ์ (ความสะดวก ไม่ใช่ความปลอดภัย — RLS คือของจริง · ดู src/lib/auth/gate.tsx)
  const denied = await gateRoute("/dashboard", "หน้าแรก");
  if (denied) return denied;

  const sp = await searchParams;
  const one = (k: string) => (Array.isArray(sp[k]) ? (sp[k] as string[])[0] : (sp[k] as string | undefined));
  const data = await loadDashboard({ owner: one("owner"), year: one("year") });

  return (
    <PageShell title="หน้าแรก">
      {data.ok ? (
        <DashboardView data={data} />
      ) : (
        <Notice tone="neg">
          โหลดข้อมูลหน้าแรกจากฐานข้อมูลไม่สำเร็จ จึงไม่แสดงตัวเลขให้ (ไม่แสดงข้อมูลครึ่งเดียว): {data.error}
          <div className="mt-1 text-sm">ลองโหลดหน้านี้ใหม่ ถ้ายังไม่ได้ให้แจ้งผู้ดูแลระบบ</div>
        </Notice>
      )}
    </PageShell>
  );
}
