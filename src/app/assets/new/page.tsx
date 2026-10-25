import { PageShell } from "@/components/layout/page-shell";
import { AssetRegister } from "@/components/assets/asset-register";
import { Notice } from "@/components/assets/asset-parts";
import { loadRegisterForm } from "@/lib/db/assets-server";
import { gateDraftPages } from "../_gate";

export default async function NewAssetPage() {
  const g = await gateDraftPages("ลงทะเบียนทรัพย์");
  if (g.denied) return g.denied;

  const form = await loadRegisterForm();

  return (
    <PageShell title="ลงทะเบียนทรัพย์">
      {form.ok ? (
        <AssetRegister taxonomy={form.taxonomy} owners={form.owners} />
      ) : (
        <Notice tone="neg">โหลดหมวดทรัพย์หรือรายชื่อผู้ถือจากฐานข้อมูลไม่สำเร็จ จึงลงทะเบียนไม่ได้: {form.error}</Notice>
      )}
    </PageShell>
  );
}
