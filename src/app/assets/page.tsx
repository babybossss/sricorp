import { PageShell } from "@/components/layout/page-shell";
import { AssetManager } from "@/components/assets/asset-manager";

export default function AssetsPage() {
  return (
    <PageShell title="บริหารสินทรัพย์">
      <AssetManager />
    </PageShell>
  );
}
