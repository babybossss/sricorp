import { PageShell } from "@/components/layout/page-shell";
import { OpeningImport } from "@/components/import/opening-import";
import { gateRoute } from "@/lib/auth/gate";

/** นำเข้ายอดตั้งต้นงบดุลจากไฟล์ Excel — ขั้นตรวจ + พรีวิว (ยังไม่ลงสมุด) */
export default async function ImportPage() {
  const denied = await gateRoute("/import", "นำเข้ายอดตั้งต้น");
  if (denied) return denied;
  return (
    <PageShell title="นำเข้ายอดตั้งต้น">
      <OpeningImport />
    </PageShell>
  );
}
