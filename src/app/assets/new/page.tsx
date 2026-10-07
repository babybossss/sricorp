import { PageShell } from "@/components/layout/page-shell";
import { AssetRegister } from "@/components/assets/asset-register";
import { gateDraftPages } from "../_gate";

export default async function NewAssetPage() {
  const g = await gateDraftPages("ลงทะเบียนทรัพย์");
  if (g.denied) return g.denied;

  return (
    <PageShell title="ลงทะเบียนทรัพย์">
      <AssetRegister currentUser={g.user} />
    </PageShell>
  );
}
